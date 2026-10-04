# scrubmac

[![CI](https://github.com/aviral2552/scrubmac/actions/workflows/ci.yml/badge.svg)](https://github.com/aviral2552/scrubmac/actions/workflows/ci.yml)
[![Live E2E](https://github.com/aviral2552/scrubmac/actions/workflows/e2e-live.yml/badge.svg)](https://github.com/aviral2552/scrubmac/actions/workflows/e2e-live.yml)
[![OpenSSF Scorecard](https://api.scorecard.dev/projects/github.com/aviral2552/scrubmac/badge)](https://scorecard.dev/viewer/?uri=github.com/aviral2552/scrubmac)
[![License: GPL-3.0-only](https://img.shields.io/badge/license-GPL--3.0--only-blue.svg)](#license)

One command that updates and cleans the dev tools on your Mac — Homebrew,
npm/pnpm/yarn/bun/deno, Python (uv/pipx/conda/poetry), Rust, Go, Ruby,
Composer, mise, your AI coding CLIs (Claude Code, Codex, Copilot, Gemini,
Cursor), editor extensions, Xcode and Docker caches — safely, on a schedule
if you like.

> **Formerly `cleanmymac` (2018–2026).** Renamed to end the collision and
> confusion with MacPaw's unrelated commercial products of that name. Not
> affiliated with MacPaw. Migration from 2.x is automatic — see
> [Migrating](#migrating-from-cleanmymac-2x).

![A scrubmac run: per-cleaner results and a summary](docs/demo.svg)

<sub>Illustrative run, recorded against a sandboxed toolchain by
[`scripts/render-demo.sh`](scripts/render-demo.sh).</sub>

## Why you can trust it

- **Never runs `sudo` itself.** Refuses to run as root, no system files, no
  SIP fights — and it skips tools that always escalate (`mas update`). The
  one exception is Homebrew: upgrading a pkg-based cask makes Homebrew run
  that installer through `sudo`, asking for your password — by default only
  in runs you start in a terminal; `APP_UPDATES=never` rules it out.
- **Never your data.** Updates and regenerable caches, plus Homebrew's own
  housekeeping (`brew autoremove` of dependencies nothing needs any more,
  `brew cleanup` of old formula versions). AI tool state (`~/.claude`,
  `~/.codex`, `~/.cursor`, `~/.copilot`) is never touched. No Trash, no
  `~/Library/Caches` sweeps, no Docker containers or volumes.
- **A supply-chain cooldown, on by default.** Updates skip releases younger
  than 7 days wherever that can be enforced (npm, uv, pipx, pnpm, Bun) — the
  window in which worms like the 2025 npm compromises were caught — and the
  cooldown never downgrades anything. One setting turns it off.
- **Preview everything.** `scrubmac --dry-run` prints every command that
  would change something and runs none of them; `scrubmac status` shows cache
  sizes and pending updates without touching your tools. (A dry run still
  does scrubmac's own first-run setup; both do its one-time migrations.)
- **One failure never stops the rest.** Each cleaner runs in its own
  process, with a time limit (a hung tool is stopped together with the
  processes it started) and no stdin; the summary says exactly what
  happened, and every real run leaves a log.
- **Auditable.** About 7,900 lines of shellcheck-clean bash (about 6,000
  without comments and blank lines) plus an 850-line dependency-free node
  resolver for the cooldown, a [threat model](docs/security.md), and a test
  suite of ~630 hermetic tests plus a live end-to-end run on real macOS —
  every command checked against its tool's documentation.

## Install

**Homebrew:**

```bash
brew tap aviral2552/tap
brew trust aviral2552/tap
brew install aviral2552/tap/scrubmac
```

(`brew trust` is Homebrew's standard confirmation for third-party taps.)

**From source** (installs to `~/.scrubmac`, links into your PATH, no sudo):

```bash
git clone https://github.com/aviral2552/scrubmac.git && cd scrubmac && ./install.sh
```

There is deliberately no `curl | bash` one-liner — an installer you can't
read before running it would contradict [the security posture](docs/security.md).
Release tarballs ship sha256 checksums and GitHub build-provenance
attestations (`gh attestation verify scrubmac-X.Y.Z.tar.gz -R aviral2552/scrubmac`).

## First run

The first interactive run offers a setup wizard:

```
$ scrubmac
No configuration found. Run the setup wizard now? [Y/n]
```

It walks through the cleaners (grouped, each with a one-line summary and
whether its tool is installed), the **update cooldown** (it also delays
security patches; the wizard says so), whether GUI apps may be upgraded in
unattended runs, and output preferences. Nothing is written until you
confirm, and re-running `scrubmac configure` starts from your current
answers. Decline, and sensible defaults are written instead. Non-interactive
runs never prompt.

## Usage

```
scrubmac                     run every enabled cleaner
scrubmac --dry-run           preview: print every command, change none of your tools
scrubmac -q                  quiet: one line per cleaner + summary; failures still show output
scrubmac homebrew npm        run exactly these cleaners (even if disabled; also: scrubmac run …)
scrubmac --skip docker,go    leave cleaners out of this run
scrubmac --update-only       update tools, leave caches alone
scrubmac --clean-only        free space, change no versions
scrubmac --measure           report the space each cleaner frees
scrubmac --json              machine-readable summary on stdout

scrubmac status              read-only: cache sizes and outdated packages
scrubmac list                every cleaner: state, default, tool found, summary
scrubmac doctor              environment, configuration, scheduling, security report
scrubmac configure           (re)run the wizard
scrubmac enable docker xcode opt in to cleaners
scrubmac disable npm         opt out of a cleaner
scrubmac config              show settings; config set COOLDOWN_DAYS 14 changes one
scrubmac schedule weekly     run every Monday 09:00 via launchd (daily / off / status)
scrubmac last                show the newest run's log
scrubmac update              update scrubmac itself (release tags / brew)
scrubmac version             print the version
scrubmac help                full command reference
```

Exit codes: `0` all ok/skipped · `1` something failed, timed out, or was
refused · `2` usage or environment error, or a concurrent run · `130`
interrupted. See `man scrubmac` (Homebrew installs link it; for a git
install without Homebrew, `man ~/.scrubmac/man/scrubmac.1`). Shell
completions for bash, zsh, and fish are included.

## Unattended runs

```bash
scrubmac schedule weekly fri 18:30
```

writes a per-user launchd agent that carries your `PATH` (cron's is just
`/usr/bin:/bin`, which silently skips almost every cleaner) and runs a
missed schedule at the next wake. Scheduled runs never prompt, skip GUI app
upgrades unless you allow them, can skip on battery or when a run succeeded
recently, notify you when something fails, and stop any cleaner that hangs
— together with the processes it started (`TIMEOUT`, default an hour).
Offline, updates are skipped and cleanup still runs. Details: [docs/configuration.md](docs/configuration.md#scheduling).

## What it cleans

Every cleaner is presence-gated — absent tools skip harmlessly, so the full
set is safe on any machine. The exact commands each cleaner runs are
documented — and checked against the code in CI — in
**[docs/cleaners.md](docs/cleaners.md)**:

| Group | Cleaners |
|---|---|
| Package managers | homebrew, mas (reports App Store updates; installing them needs sudo) |
| JavaScript | npm, pnpm, yarn, bun, deno |
| Python | python (uv/pipx/pip), conda (+ micromamba), poetry |
| AI tools | claude, codex, copilot, gemini, cursor, gh (extensions) |
| Languages | rustup, cargo (cargo-update), composer, mise; *opt-in:* go, rubygems |
| Developer tools | krew, vscode (extensions), pre-commit; *opt-in:* docker |
| Apple development | cocoapods, swiftpm; *opt-in:* xcode |

Opt-in cleaners delete more than an obvious cache (or, for go, mostly force
rebuilds) and start disabled. There is intentionally **no** "macOS deep
clean": modern macOS maintains itself, and a tool that refuses sudo can't
(and shouldn't) do it. [docs/security.md](docs/security.md) explains.

## How it compares

[topgrade](https://github.com/topgrade-rs/topgrade) is the well-known
"update everything" tool, and a good one. They make different trade-offs:

| | scrubmac | topgrade |
|---|---|---|
| Scope | dev tooling on a Mac (29 cleaners) | ~180 steps across systems, including OS package managers and firmware |
| Platforms | macOS | Linux, macOS, Windows, BSDs, Termux |
| `sudo` | never; refuses to run as root | runs `sudo` for system steps by design |
| Cache cleanup | part of every run, age-gated where it matters | optional (`--cleanup`), per step |
| Supply-chain cooldown | yes, on by default | no |
| Written in | bash you can read | Rust |

If you want one tool to update everything on any OS, the OS included, use
topgrade. scrubmac is narrower on purpose: it keeps a Mac's developer
toolchain current and trim without ever escalating.

## Configuration

`~/.config/scrubmac/config` holds a handful of `KEY=value` settings (parsed,
never executed) — `scrubmac config` lists them all, with where each value
comes from. Cleaner choices live in `enabled`/`disabled` next to it, and
your own cleaners in `cleaners.d/` (a same-named cleaner overrides a
built-in). Details: [docs/configuration.md](docs/configuration.md).

## Writing your own cleaner

A cleaner is a short executable script dropped into
`~/.config/scrubmac/cleaners.d/`. Template and contract:
[docs/writing-cleaners.md](docs/writing-cleaners.md).

## Migrating from cleanmymac 2.x

Automatic, whichever way you installed:

- **Homebrew**: `brew update && brew upgrade` — the formula rename is handled
  natively; you end up on `scrubmac`. If you pinned the old formula, `brew
  unpin cleanmymac` first. If you trusted the formula individually (not the
  tap), run `brew trust aviral2552/tap` once.
- **Git install**: run `cleanmymac update` one last time, then re-run
  `install.sh` (the old command tells you this too). Your install dir,
  config, disabled list, and custom cleaners are migrated automatically; a
  compat symlink plus a transitional `cleanmymac` shim (removed in v4) keep
  hardcoded `~/.cleanmymac/bin/cleanmymac` paths working, with a nag.
  `install.sh` retires old `cleanmymac` links on your PATH — unless your
  crontab still calls cleanmymac, in which case they stay until you update
  it — so a bare `cleanmymac` stops working (or finds MacPaw's CLI): update
  aliases and scripts.
- **Crontabs/aliases**: update them to `scrubmac` — or replace the crontab
  line with `scrubmac schedule weekly`. Note: `cleanmymac` on PATH may
  eventually resolve to MacPaw's unrelated CLI once our shim is gone.

## Documentation

| | |
|---|---|
| [docs/architecture.md](docs/architecture.md) | how the dispatcher, library, and cleaners fit together |
| [docs/cleaners.md](docs/cleaners.md) | every cleaner, every command it runs |
| [docs/configuration.md](docs/configuration.md) | wizard, settings, scheduling, logs, JSON |
| [docs/security.md](docs/security.md) | threat model, S1–S7, residual risks |
| [docs/writing-cleaners.md](docs/writing-cleaners.md) | cleaner contract + annotated template |
| [docs/troubleshooting.md](docs/troubleshooting.md) | common questions and failure modes |
| [docs/roadmap.md](docs/roadmap.md) | what's next, and what v4 removes |
| [docs/renaming.md](docs/renaming.md) | the cleanmymac → scrubmac rename record |
| [CONTRIBUTING.md](CONTRIBUTING.md) | dev setup, tests, PR checklist |
| [SECURITY.md](SECURITY.md) | reporting vulnerabilities |

## Uninstall

```bash
scrubmac schedule off        # if you set a schedule
~/.scrubmac/uninstall.sh     # git installs; --purge also removes ~/.config/scrubmac
                             # (settings, choices, your own cleaners) and the logs
brew uninstall scrubmac      # Homebrew installs
```

`uninstall.sh` also removes a schedule that points at the install it
removes, and refuses to delete any directory that does not hold a scrubmac
install.

## License

[GPL-3.0-only](LICENSE) with one additional term under GPLv3 §7(b): works
based on this code must preserve attribution to the original project — see
[NOTICE](NOTICE). Free and open source, copyleft intact; credit required.
