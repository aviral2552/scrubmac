# Security Policy

## Supported versions

| Version | Supported |
|---------|-----------|
| 3.x     | yes       |
| 2.x (cleanmymac) | security fixes only until v4 — please upgrade |
| 1.x     | no — please upgrade |

## Reporting a vulnerability

Please report vulnerabilities **privately** via GitHub's private vulnerability
reporting on this repository (Security tab → *Report a vulnerability*). Do not
open a public issue for anything you believe is exploitable.

You can expect an acknowledgement within a week. Fixes ship as a patch release
with credit in the changelog (unless you prefer otherwise).

## Verifying a release

Release tarballs carry a sha256 checksum (`SHA256SUMS`) and a GitHub
build-provenance attestation:

```bash
gh attestation verify scrubmac-X.Y.Z.tar.gz -R aviral2552/scrubmac
```

## Security model in one paragraph

scrubmac is a user-level bash tool that shells out to the package managers
you already trust. It never runs `sudo` itself and skips tools that always
escalate (Homebrew may ask for your password to upgrade a pkg-based cask,
by default only in runs you start in a terminal), refuses to run as root,
never deletes user data (regenerable caches, plus Homebrew's removal of
unneeded dependencies and old formula versions), executes only cleaner
files that are owned by you and not writable
by anyone else (a refusal fails the run), gives cleaners no stdin, parses
(never sources) its config file, applies a supply-chain cooldown by default,
self-updates only by fast-forwarding — to a release tag by default
(signature-checked against keys pinned in your installed copy, once releases
are signed), to the tracked branch with `UPDATE_CHANNEL=branch` or when a
copy that pins no keys finds no release tags — or via Homebrew, installs and
uninstalls only into directories that hold a scrubmac install (never over a
git checkout holding local work), and makes no network calls of its own
except one: under the cooldown, the bun cleaner reads Bun's release feed to
learn a release's age. The full threat model,
including accepted residual risks, lives in [docs/security.md](docs/security.md).
