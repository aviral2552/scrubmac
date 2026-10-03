# Threat model & security design

scrubmac runs with your user's full privileges and executes other programs
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
| Built-in cleaners shipped in the install dir | conditionally | execution-safety guard (S2) |
| User cleaners in `~/.config/scrubmac/cleaners.d/` | conditionally | same guard; name validation |
| Config file `~/.config/scrubmac/config` | no | parsed with a strict grammar, never sourced (S5) |
| The git remote used by `scrubmac update` | partially | release tags, fast-forward only, signatures checked against keys pinned by the installed copy (S3) |
| The package managers scrubmac invokes (brew, npm, uv, …) | yes, by necessity | you already run these yourself; scrubmac adds no new trust |
| Registries those managers talk to | no | supply-chain cooldown, on by default (S4) |
| Other local users | no | per-user lock in your state dir; safety guard on cleaners (S2) |

## Defenses (S1–S7)

### S1 — No privilege escalation, ever
scrubmac never invokes `sudo` — tripwire tests in `tests/security.bats` fail
on `sudo` or `eval` in any command position (a line start, after `;`, `|`,
`&`, `(`, `{`, `!` or a backtick, inside `$( )`, after a keyword such as
`if`/`then`/`do`, or as the argument of `run`, `step`, `try`, `preview`,
`report`, `exec`, `command`, `env`, `xargs`, `nohup`, `nice` or `time`); the
only mention is advice uninstall.sh prints for you to run yourself. Every
entry point (`scrubmac`, `install.sh`, `uninstall.sh`) refuses to run as
root. The 1.x installer escalated to write `/usr/local/bin`; 2.x and
later fall back to `~/.local/bin` and tell you about PATH. scrubmac also
refuses to run tools that escalate *on their own*: mas installs App Store
updates as root by re-running itself through `sudo`, so the mas cleaner only
reports pending updates. And Homebrew casks — which may stop for a sudo
password — are only upgraded when a person is at the terminal (by default).

### S2 — Execution-safety guard on every cleaner
Cleaners are code. Before executing one, the dispatcher requires:
- a regular file, **not a symlink** (a symlink can silently retarget)
- owned by the invoking user
- neither the file nor its parent directory group- or world-writable
A cleaner file whose name is not made only of `A-Za-z0-9._+@-` (anything
that could smuggle markup into a notification or options into a command
line) is never discovered at all: it is ignored with a warning.

A cleaner failing the check is refused with a warning and **reported as
`REFUSED`, which fails the run** (exit 1) — a refusal is a security event,
and a scheduled run must not report success while silently skipping it.
`scrubmac doctor` audits the same conditions on demand and says which one
failed.

Built-in cleaners are checked, then copied — with scrubmac's own `lib/` — into
a private per-run directory, and run from those copies: the homebrew cleaner
can upgrade scrubmac itself mid-run, and Homebrew then deletes the old keg.

**Accepted residual risk (TOCTOU):** the check and the execution are separate
syscalls; a process able to swap the file in between already runs as you, at
which point it does not need scrubmac. The guard is against *persistence
mistakes* (a lazily-permissioned shared machine, a bad `chmod -R`), not
against an attacker who already owns your account.

### S3 — Constrained self-update
`scrubmac update` on a git install fetches tags — pruning any tag withdrawn
upstream, and refusing a tag that moved after you fetched it — and
fast-forwards to the newest release: a tag of exactly the form `vX.Y.Z`
(pre-release and other tags are never taken), never unreleased work on the
branch, and never across diverged history (a force-pushed or tampered
remote is refused). It prints what will change, and `scrubmac update
--check` only reports. When the **installed** copy contains
`share/allowed_signers`, the release tag must carry a valid SSH signature by
one of those keys (`git verify-tag`). Candidates are tried newest first: a
release that is unsigned, or not a fast-forward, is skipped with a warning
in favor of the newest one that passes, and if none newer passes the update
is refused. The keys come from the copy you already have — never from what
was just fetched — so a compromised remote cannot swap in its own key (trust
on first use). With no release tags at all, or with `UPDATE_CHANNEL=branch`,
updates follow the branch (fast-forward only) and are not
signature-checked; scrubmac says so. Homebrew installs delegate to `brew
upgrade`. There is no custom download-and-execute path, and no curl|bash
install is offered anywhere.

**Residual risk:** until the maintainer starts signing release tags and
ships `share/allowed_signers` (see RELEASING.md), updates are only as
trustworthy as the GitHub repository; `scrubmac update` says when signatures
are not being checked.

### S4 — Supply-chain cooldown
On by default (`COOLDOWN_DAYS=7`): skip package versions younger than N
days, on the evidence that npm-worm-style compromises are usually caught and
pulled within days. Enforcement is per-manager and honest about its limits —
and **nothing is ever downgraded**:

| Manager | Mechanism |
|---|---|
| npm | scrubmac's resolver (`lib/registry.js`): for each outdated global, the newest release that is newer than the installed one, not past `latest`, and older than the cutoff, installed explicitly — stepping over releases that are deprecated or need a newer Node. npm itself, corepack, and linked, local or aliased globals are never touched. npm's `--before`/`min-release-age` are not used: with `npm update -g` they downgrade globals newer than the cutoff |
| pnpm | the same resolver, within each global's major: `pnpm add -g <pkg>@<version>` (install groups re-added whole); a standalone pnpm self-updates to a named release old enough. pnpm's `minimumReleaseAge` is not used: it makes `update -g` and `self-update` fail whenever an installed release is fresher than the cutoff |
| Bun | the same resolver, within each global's saved range: `bun update -g <pkg>@<version>`; `bun upgrade` cannot be pinned to a version, so it is held while the cooldown is on |
| uv | `uv tool upgrade --exclude-newer "N days"` — a relative span (uv ≥ 0.11.4 stores it as such in tool receipts, so it never freezes into a stale date) |
| pipx | `pipx upgrade-all --cooldown N` (pipx ≥ 1.16; older pipx holds its upgrades) |
| Yarn classic | no age filter exists: global upgrades are **held** while the cooldown is on |
| Homebrew | not applicable: a curated registry with its own review |
| Self-updaters (`uv self update`, `deno upgrade`, `mise self-update`, the AI CLIs' own updaters), rustup, Composer, cargo, gems, gh/krew/VS Code extensions | no upstream age filter; not covered |

With `COOLDOWN_DAYS=0`, the cutoffs that uv receipts and pipx metadata
remember from earlier runs are cleared (`--exclude-newer false` with uv ≥
0.11.24; `--cooldown 0`), so turning the cooldown off really turns it off —
also for your own `uv tool upgrade`/`pipx upgrade` runs.

**Trade-off, stated plainly:** a cooldown also delays security *patches* by N
days. The wizard says this on the same screen where you choose it; set
`COOLDOWN_DAYS=0` to opt out.

### S5 — Config cannot execute code
`~/.config/scrubmac/config` is read with a strict `KEY=value` grammar
(`^[A-Z][A-Z0-9_]*=[A-Za-z0-9._/-]*$`); any other line — shell
metacharacters included — is ignored and reported, and a value of the wrong
type for a built-in setting is reported and replaced by its default. The
file is never `source`d, and `scrubmac config set` refuses keys and values
outside the grammar. Pinned by tests that plant `$(…)`, backticks, and `;`
payloads and assert nothing runs.

Cleaners get `/dev/null` as stdin, so no cleaner — and no tool it runs — can
read what you type through stdin or have a prompt answered for it. (A tool
that opens the terminal itself, the way `sudo` and `ssh` do, can still ask
you in a run you started at a terminal; runs nobody watches — launchd, cron
— have no terminal for it to open.)

### S6 — Environment audit
`scrubmac doctor` warns about `.` and relative entries on PATH,
world-writable PATH directories, unsafe cleaner files/dirs (with the reason),
non-executable files in `cleaners.d`, dangling `scrubmac`/`cleanmymac`
symlinks in the directories installers link into, unwritable config/state
dirs, a crontab entry that runs scrubmac without a usable `PATH` (it
understands `PATH=` lines, inline `PATH=… scrubmac`, and login shells),
scrubmac scheduled by both cron and launchd, and a schedule whose launcher
has gone.
scrubmac invokes tools through PATH exactly as you would — it neither curates
nor sanitizes your PATH, it just tells you when something looks hijackable.
The one PATH it writes, into the launchd agent, has `.`, empty and relative
entries removed.

### S7 — Verifiable distribution
Install paths are git clone + `install.sh`, or Homebrew. Releases attach
sha256 checksums **and GitHub build-provenance attestations** for the
tarball (`gh attestation verify scrubmac-X.Y.Z.tar.gz -R aviral2552/scrubmac`).
The CI that builds them pins every third-party action to a full commit SHA
(kept current by Dependabot), runs with read-only tokens except where a job
must write, uses pinned linters whose checksums it verifies — the release
workflow included, with the full suite on macOS and Linux gating every
release — and is scored by OpenSSF Scorecard. There is deliberately no curl|bash one-liner:
an installer you cannot read before running contradicts the rest of this
document.

## What scrubmac will never do

- run `sudo`, or anything as root — or a tool that escalates by itself
- delete user data: no Trash, no `~/Library/Caches` sweeps, no Docker
  containers/volumes/tagged images, no AI-tool state dirs (`~/.claude`,
  `~/.codex`, `~/.cursor`, `~/.copilot` hold your sessions and auth —
  cleaners update those tools, nothing more), no globally installed tools
  (which is why `dart pub cache clean` is not a cleaner). The only removals
  of installed *versions* happen where you opt in: the opt-in rubygems
  cleaner's `gem cleanup` (old versions of gems you have newer versions of)
  and `MISE_PRUNE=1` (tool versions no config file uses)
- delete a directory it did not create: install.sh mirrors only into an
  empty directory or an existing scrubmac install, and uninstall.sh removes
  only directories that hold one — compared as canonical paths, and never
  `/`, your home, or a parent of it
- fight SIP or modify system state (the 1.x "macOS core cleaner" died trying;
  its absence is a feature, not a gap)
- make network calls of its own (everything network-touching is a package
  manager you chose to run; `update` is plain git/brew; offline detection
  reads the local routing table)
- put secrets in command argv (the `run` wrapper echoes every command; the
  contract in CONTRIBUTING.md forbids secret-bearing arguments)

## Hardening in the codebase

- `set -euo pipefail` everywhere; no `eval` (CI-pinned); argv-array execution
  only — no string-built commands
- shellcheck + shfmt clean (pinned versions in CI)
- every mutating command goes through the dry-run-aware `run`/`step`
  helpers, so `--dry-run` shows the full blast radius before you commit to
  it; `status` never mutates. (One exception: `uv cache prune` runs through
  the python cleaner's own wrapper — it must read uv's lock-timeout exit — and
  that wrapper prints the command and honors `--dry-run` the same way.)
- non-interactive by contract: stdin is `/dev/null`, and `-y`/`--yes`/
  `--no-interaction`/`HOMEBREW_NO_ASK` flags are pinned by tests
- every cleaner runs under a watchdog (`TIMEOUT`) that stops it and every
  process it started — `TERM`, then `KILL` after a 5-second grace — so one
  hung tool cannot wedge a scheduled run; runs without a terminal give each
  cleaner its own process group, so even orphaned or daemonized descendants
  are reached
- cleaners start in your home directory with fd 3 closed (it carries
  `--json` output; a daemon that inherited it would hold the reader's pipe
  open)
- concurrent runs are excluded by a per-user lock in the state dir; it
  records the holder's pid *and start time*, so a reused pid never fakes a
  live holder, and stale locks are broken atomically. Until v4 a second,
  transitional lock is also taken in `${TMPDIR:-/tmp}`, exactly as
  cleanmymac 2.x takes it, so an unmigrated 2.x copy and scrubmac still
  exclude each other — best effort: in a shared `/tmp` it is honored only
  when it is a real directory owned by you, so another user can neither
  hold it against you nor point it elsewhere
- desktop notifications pass their text to `osascript` as arguments, never
  spliced into AppleScript source
- interrupts produce a partial summary rather than silent half-done state
