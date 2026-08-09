# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| 2.x     | yes       |
| 1.x     | no — please upgrade |

## Reporting a vulnerability

Please report vulnerabilities **privately** via GitHub's private vulnerability
reporting on this repository (Security tab → *Report a vulnerability*). Do not
open a public issue for anything you believe is exploitable.

You can expect an acknowledgement within a week. Fixes ship as a patch release
with credit in the changelog (unless you prefer otherwise).

## Security model in one paragraph

scrubmac is a user-level bash tool that shells out to the package managers
you already trust. It never runs `sudo`, refuses to run as root, never deletes
user data (only regenerable caches), executes only cleaner files that are
owned by you and not writable by anyone else, parses (never sources) its
config file, self-updates only by fast-forward `git pull` or Homebrew, and
makes no network calls of its own. The full threat model, including accepted
residual risks, lives in [docs/security.md](docs/security.md).
