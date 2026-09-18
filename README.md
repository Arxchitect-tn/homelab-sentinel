# homelab-sentinel

An hourly health monitor for a self-hosted Linux box, written as a single dependency-free
bash script and driven by a systemd timer. It writes a timestamped report to disk and exits
with a **graded** status code.

## What it checks

- container state (running vs exited, per-container health)
- disk, memory, load average, journal size
- default route, interface link quality (signal, negotiated rate)
- DNS resolution end to end
- clock sync and TLS trust store sanity
- listening sockets on all interfaces (exposure review)
- failed systemd units
- expected storage mounts

## Why graded exit codes

A missing media drive is a warning, not a failure — so the script exits `0` (clean),
`1` (warnings) or `2` (failures) rather than a flat pass/fail. The systemd unit is configured
with `SuccessExitStatus=0 1`, which keeps the graded codes readable by other tooling while
stopping an *expected* warning from marking the monitor itself as a failed unit.

That detail matters more than it sounds: without it, the monitor's own "no failed units" check
would trip every hour and blind itself.

## Design notes

- no external dependencies beyond coreutils and docker
- one report file per run, with a `latest` symlink for convenience
- report artefacts are plain text, so they diff and grep cleanly

## Install sketch

    sudo install -m 755 sentinel.sh /opt/sentinel/sentinel.sh
    sudo install -m 644 sentinel.service sentinel.timer /etc/systemd/system/
    sudo systemctl enable --now sentinel.timer

Adapt the paths and the checks to your own environment.
