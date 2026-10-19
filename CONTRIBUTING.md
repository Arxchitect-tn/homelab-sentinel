# Contributing

Linux host checks, graded exit codes, and plain-text reports.

[Project overview](README.md)

## Proposing a change

For a bug report, include the expected and actual behavior, the relevant command,
runtime or OS versions, and a small sanitized reproduction. For larger changes,
open an issue first to discuss the approach.

Keep pull requests focused. Explain observable behavior changes, update the README
when instructions or defaults change, and state exactly what you tested and what
remains unverified. Preserve existing interfaces unless the change explicitly
addresses them. There is currently no automated test suite in this repository.

## Local checks

```sh
bash -n sentinel.sh
```

For behavioral changes, use a disposable Linux VM with systemd and a known test
container set. The script writes reports and listener state and makes network
requests. Do not stop services or unmount storage on a production host to create
a failure fixture. Verify clean, warning, and failure outcomes against the report
summary, including `--quiet` and the `latest.txt` symlink.

## Sensitive information

Never publish API keys, SSH private keys, credentials, private hostnames, or raw
production diagnostics. Reports can reveal usernames, paths, addresses, model
names, and service details. Redact them before sharing. Do not attach crash dumps
or full event-log exports to a public issue.

If a report would disclose an exploitable vulnerability or a secret, do not post
the sensitive details publicly. Establish a private reporting channel with the
maintainer first; no response-time commitment is implied here.

## License

No license file is currently included. Clarify licensing with the maintainer
before relying on public availability as permission to reuse or redistribute.
