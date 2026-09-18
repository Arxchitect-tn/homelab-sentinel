#!/usr/bin/env bash
# sentinel — scheduled verification checks for homelab.
# Deterministic checks only; the analysis/reporting layer is Hermes reading this output.
# Exit code: 0 = all clear, 1 = warnings, 2 = failures.
# Usage: sentinel.sh [--quiet]

set -uo pipefail

QUIET=0
[ "${1:-}" = "--quiet" ] && QUIET=1

OUT_DIR="/var/log/sentinel"
mkdir -p "$OUT_DIR" 2>/dev/null || true
STAMP="$(date +%Y%m%d-%H%M%S)"
REPORT="$OUT_DIR/report-$STAMP.txt"
LINKS="$OUT_DIR/state-listeners.txt"

FAIL=0
WARN=0
declare -a FINDINGS=()

fail() { FAIL=$((FAIL+1)); FINDINGS+=("FAIL  $*"); }
warn() { WARN=$((WARN+1)); FINDINGS+=("WARN  $*"); }
ok()   { FINDINGS+=("ok    $*"); }

{
echo "sentinel report — $(hostname) — $(date)"
echo "==============================================================="

# ---------------------------------------------------------------- identity
echo
echo "## host"
uptime | sed 's/^/  /'
echo "  clock: $(date '+%Y-%m-%d %H:%M:%S %Z')  sync: $(timedatectl show -p NTPSynchronized --value 2>/dev/null)"
CLOCK_SYNC=$(timedatectl show -p NTPSynchronized --value 2>/dev/null)
[ "$CLOCK_SYNC" = "yes" ] || fail "clock not NTP-synchronised — TLS validation will fail (this is what broke DNS/browsing before)"

# ---------------------------------------------------------------- containers
echo
echo "## containers (docker)"
RUNNING=$(docker ps -q 2>/dev/null | wc -l)
EXITED=$(docker ps -aq --filter "status=exited" 2>/dev/null | wc -l)
UNHEALTHY=$(docker ps --filter "health=unhealthy" --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
RESTARTING=$(docker ps --filter "status=restarting" --format '{{.Names}}' 2>/dev/null | tr '\n' ' ')
echo "  running=$RUNNING exited=$EXITED"
docker ps --format '  {{.Names}}\t{{.Status}}' 2>/dev/null
[ -n "$UNHEALTHY" ] && fail "unhealthy containers: $UNHEALTHY"
[ -n "$RESTARTING" ] && fail "restart-looping containers: $RESTARTING"

# expected services must be up (media stack + dns)
for c in pihole jellyfin qbittorrent prowlarr jackett jellyseerr filebrowser; do
  if ! docker ps --format '{{.Names}}' 2>/dev/null | grep -qx "$c"; then
    # parked-on-purpose containers are only a warning
    case "$c" in
      sonarr|radarr) warn "$c is not running (expected while the media drive is absent)";;
      *) fail "$c is not running";;
    esac
  fi
done

# ---------------------------------------------------------------- resources
echo
echo "## resources"
df -h / | tail -1 | sed 's/^/  disk: /'
DISK_PCT=$(df --output=pcent / | tail -1 | tr -dc '0-9')
[ "$DISK_PCT" -ge 90 ] && fail "root filesystem ${DISK_PCT}% full" || { [ "$DISK_PCT" -ge 80 ] && warn "root filesystem ${DISK_PCT}% full"; }
free -m | awk '/^Mem:/ {printf "  memory: used=%sMB available=%sMB\n", $3, $7}'
AVAIL_MB=$(free -m | awk '/^Mem:/ {print $7}')
[ "$AVAIL_MB" -lt 1024 ] && warn "less than 1GB RAM available (${AVAIL_MB}MB)"
echo "  load: $(cut -d' ' -f1-3 /proc/loadavg)"
JR=$(journalctl --disk-usage 2>/dev/null | grep -oE '[0-9.]+[GM]' | head -1)
echo "  journal: ${JR:-unknown}"
case "$JR" in *G) JRN=${JR%G}; awk -v j="$JRN" 'BEGIN{exit !(j>=1.0)}' && warn "journal is ${JR} — consider vacuuming";; esac

# ---------------------------------------------------------------- thermals
echo
echo "## thermals"
HOT=""
for z in /sys/class/thermal/thermal_zone*/; do
  t=$(awk '{printf "%d", $1/1000}' "$z/temp" 2>/dev/null)
  n=$(cat "$z/type" 2>/dev/null)
  [ -n "${t:-}" ] && { printf "  %-20s %sC\n" "$n" "$t"; [ "$t" -ge 90 ] && HOT="$HOT $n(${t}C)"; }
done
[ -n "$HOT" ] && fail "thermal zone over 90C:$HOT"

# ---------------------------------------------------------------- network
echo
echo "## network"
IFACE=$(ip -4 route | awk '/^default/ {print $5; exit}')
echo "  default via $(ip -4 route | awk '/^default/ {print $3" on "$5}')"
if [[ "$IFACE" == wl* ]]; then
  SIG=$(iw dev "$IFACE" link 2>/dev/null | awk '/signal/ {print $2}')
  RATE=$(iw dev "$IFACE" link 2>/dev/null | awk '/bitrate/ {print $2" "$3}')
  echo "  wifi: $IFACE signal=${SIG:-?}dBm rate=${RATE:-?}"
  if [ -n "${SIG:-}" ]; then
    printf '%s\n' "$SIG" | awk '{v=$1; if (v<0) v=-v; exit !(v>70)}' && warn "wifi signal weak (${SIG}dBm)"
  fi
fi
if getent hosts www.google.com >/dev/null 2>&1; then ok "DNS resolves"; else fail "DNS resolution failing"; fi
if curl -fsS -m 8 -o /dev/null https://www.google.com 2>/dev/null; then ok "HTTPS/TLS validates (clock + trust store sane)"; else fail "HTTPS to google.com failed — TLS/clock/network problem"; fi
TS=$(tailscale status 2>&1 | head -1 | awk '{print $2}')
if tailscale status >/dev/null 2>&1; then ok "tailscale up as ${TS:-?}"; else warn "tailscale not reporting healthy"; fi

# ---------------------------------------------------------------- dns service
echo
echo "## dns (pi-hole)"
if dig +short +time=3 +tries=1 @127.0.0.1 cloudflare.com >/dev/null 2>&1; then ok "pi-hole answering on 127.0.0.1"; else fail "pi-hole not answering locally"; fi

# ---------------------------------------------------------------- exposure
echo
echo "## exposure — listeners on all interfaces"
ss -tlnpH 2>/dev/null | awk '{print $4}' | grep -E '^0\.0\.0\.0:|^\[::\]:' | sed 's/^/    /' | sort -u
ss -tlnpH 2>/dev/null | awk '{print $4}' | grep -E '^0\.0\.0\.0:|^\[::\]:' | grep -vE ':22$|:53$|:80$|:443$|:5055$|:6881$|:8081$|:8082$|:8096$|:9117$|:9696$|:8080$|:2222$' | sort -u > /tmp/sentinel-listeners.new
if [ -f "$LINKS" ]; then
  NEW=$(comm -13 "$LINKS" /tmp/sentinel-listeners.new | tr '\n' ' ')
  [ -n "$NEW" ] && warn "new listener(s) since last run: $NEW"
fi
mv /tmp/sentinel-listeners.new "$LINKS" 2>/dev/null || true

# ---------------------------------------------------------------- services
echo
echo "## failed systemd units"
FU=$(systemctl --failed --no-legend 2>/dev/null | wc -l)
[ "$FU" -gt 0 ] && { systemctl --failed --no-legend 2>/dev/null | sed 's/^/    /'; fail "$FU failed systemd unit(s)"; } || ok "no failed units"

# ---------------------------------------------------------------- media drive
echo
echo "## storage mounts"
if mountpoint -q /mnt/nas; then ok "/mnt/nas mounted"; else warn "/mnt/nas NOT mounted (1TB data drive absent — expected until it is seated)"; fi

# ---------------------------------------------------------------- summary
echo
echo "==============================================================="
echo "SUMMARY: ${FAIL} failure(s), ${WARN} warning(s)"
for f in "${FINDINGS[@]}"; do echo "  $f"; done
} > "$REPORT" 2>&1

[ "$QUIET" -eq 0 ] && cat "$REPORT"
ln -sfn "$REPORT" "$OUT_DIR/latest.txt" 2>/dev/null || true

[ "$FAIL" -gt 0 ] && exit 2
[ "$WARN" -gt 0 ] && exit 1
exit 0
