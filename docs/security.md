# Threat model & security design

cleanmymac runs with your user's full privileges and executes other programs
by design. This document says exactly what it trusts, what it refuses to do,
which attacks it defends against, and which residual risks it accepts.

## Assets

- Your files and `$HOME` (the 1.x installer could `rm -rf` the directory it
  was run from — the class of bug this design exists to prevent)
- Your development toolchains and their global package sets
- Your shell environment (PATH, env vars) and anything reachable from it
- Credentials held by AI dev tools (`~/.claude`, `~/.codex`, `~/.cursor`,
  `~/.copilot` contain sessions, memory, and auth tokens)

## Trust boundaries

| Boundary | Trusted? | Enforcement |
|---|---|---|
| The user at an interactive terminal | yes | — |
| Built-in cleaners shipped in the install dir | conditionally | execution-safety guard (below) |
| User cleaners in `~/.config/cleanmymac/cleaners.d/` | conditionally | same guard |
| Config file `~/.config/cleanmymac/config` | no | parsed with a strict grammar, never sourced |
| The git remote used by `cleanmymac update` | partially | `--ff-only`, changes displayed after pull |
| The package managers cleanmymac invokes (brew, npm, uv, …) | yes, by necessity | you already run these yourself; cleanmymac adds no new trust |
| Registries those managers talk to | no | cooldown option (S4) |

## Defenses (S1–S7)

### S1 — No privilege escalation, ever
No `sudo` anywhere in the codebase (CI-pinned by `tests/security.bats`), and
every entry point (`cleanmymac`, `install.sh`, `uninstall.sh`) refuses to run
as root. The 1.x installer escalated to write `/usr/local/bin`; 2.x instead
falls back to `~/.local/bin` and tells you about PATH.

### S2 — Execution-safety guard on every cleaner
Cleaners are code. Before executing one, the dispatcher requires:
- a regular file, **not a symlink** (a symlink can silently retarget)
- owned by the invoking user
- neither the file nor its parent directory group- or world-writable

Anything failing the check is refused with a warning and skipped. `cleanmymac
doctor` audits the same conditions on demand.

**Accepted residual risk (TOCTOU):** the check and the execution are separate
syscalls; a process able to swap the file in between already runs as you, at
which point it does not need cleanmymac. The guard is against *persistence
mistakes* (a lazily-permissioned shared machine, a bad `chmod -R`), not
against an attacker who already owns your account.

### S3 — Constrained self-update
`cleanmymac update` uses `git pull --ff-only` (a diverged or force-pushed
remote is refused) and prints the diffstat of exactly what arrived. Homebrew
installs delegate to `brew upgrade`. There is no custom download-and-execute
path, and no curl|bash install is offered anywhere.

### S4 — Supply-chain cooldown
Optional, wizard-configured: skip package versions younger than N days, on
the theory that npm-worm-style attacks are usually caught within days of
publication. Support is per-manager and honest about limits:

| Manager | Mechanism | Notes |
|---|---|---|
| uv | `--exclude-newer <RFC3339>` | native, mechanical |
| npm | updates **held** while cooldown active | npm's `--before` *downgrades* globals installed more recently than the cutoff (verified empirically), so cleanmymac refuses to automate it; it prints the outdated report and defers to you |
| Homebrew | not applicable | curated registry, different threat profile |
| pipx, others | not applicable | no version-date filtering upstream |

**Trade-off, stated plainly:** a cooldown also delays security *patches* by N
days. The wizard says this on the same screen where you enable it.

### S5 — Config cannot execute code
`~/.config/cleanmymac/config` is read with a strict `KEY=value` grammar
(`^[A-Z_]+=[A-Za-z0-9._/-]*$`); any line containing shell metacharacters is
ignored. The file is never `source`d. Pinned by tests that plant `$(…)`,
backticks, and `;` payloads and assert nothing runs.

### S6 — Environment audit
`cleanmymac doctor` warns about `.` on PATH, world-writable PATH directories,
unsafe cleaner files/dirs, and dangling launcher symlinks. cleanmymac invokes
tools through PATH exactly as you would — it neither curates nor sanitizes
your PATH, it just tells you when something looks hijackable.

### S7 — Verifiable distribution
Install paths are git clone + `install.sh`, or Homebrew. Releases attach
sha256 checksums for the tarball. There is deliberately no curl|bash
one-liner: an installer you cannot read before running contradicts the rest
of this document.

## What cleanmymac will never do

- run `sudo`, or anything as root
- delete user data: no Trash, no `~/Library/Caches` sweeps, no Docker
  containers/volumes/tagged images, no AI-tool state dirs (`~/.claude`,
  `~/.codex`, `~/.cursor` hold your sessions and auth — cleaners update those
  tools, nothing more)
- fight SIP or modify system state (the 1.x "macOS core cleaner" died trying;
  its absence in 2.x is a feature, not a gap)
- make network calls of its own (everything network-touching is a package
  manager you chose to run; `update` is plain git/brew)
- put secrets in command argv (the `run` wrapper echoes every command; the
  contract in CONTRIBUTING.md forbids secret-bearing arguments)

## Hardening in the codebase

- `set -euo pipefail` everywhere; no `eval` (CI-pinned); argv-array execution
  only — no string-built commands
- shellcheck + shfmt clean, enforced by CI
- every mutating command goes through the dry-run-aware `run` wrapper, so
  `--dry-run` shows the full blast radius before you commit to it
- non-interactive by contract: no cleaner may prompt (a prompt is a hang in
  cron); `-y`/`--no-interaction` flags are pinned by tests
- concurrent runs are excluded by a lock; interrupts produce a partial
  summary rather than silent half-done state
