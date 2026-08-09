# scrubmac

[![CI](https://github.com/aviral2552/scrubmac/actions/workflows/ci.yml/badge.svg)](https://github.com/aviral2552/scrubmac/actions/workflows/ci.yml)
[![License: GPL-3.0-only](https://img.shields.io/badge/license-GPL--3.0--only-blue.svg)](#license)

One command that updates and cleans the dev tools on your Mac — Homebrew,
npm/pnpm/yarn/bun, Python (uv/pipx/conda), Rust, Go, Composer, mise, the Mac
App Store, your AI coding CLIs (Claude Code, Codex, Gemini, Cursor, Copilot
via gh), and opt-in cache pruners for Docker and Xcode.

> **Formerly `cleanmymac` (2018–2026).** Renamed to end the collision and
> confusion with MacPaw's unrelated commercial products of that name. Not
> affiliated with MacPaw. Migration from 2.x is automatic — see
> [Migrating](#migrating-from-cleanmymac-2x).

```
$ scrubmac

scrubmac 3.0.0 — starting up the cleaning engines

homebrew
========
+ brew update
...

Summary
=======
  ok    homebrew          41s
  skip  mas                0s
  ok    npm                 8s
  skip  conda               0s
  ok    python              6s
  ok    claude              2s
  ...

15 ok, 4 skipped, 0 failed
approx. disk space freed: 1.24 GB
```

## Why you can trust it

- **Never `sudo`.** Refuses to run as root. No system files, no SIP fights.
- **Never your data.** Only updates and regenerable caches. AI tool state
  (`~/.claude`, `~/.codex`, `~/.cursor`) is never touched — those tools get
  updated, nothing more. No Trash, no `~/Library/Caches` sweeps, no Docker
  containers or volumes.
- **Preview everything.** `scrubmac --dry-run` prints every command that
  would run, runs nothing.
- **One failure never stops the rest.** Each cleaner runs in its own process;
  the summary tells you exactly what happened.
- **Auditable.** ~1,700 lines of shellcheck-clean bash you can read in one
  sitting, with a [threat model](docs/security.md) and a test suite pinning
  the safety properties.

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
Release tarballs ship sha256 checksums.

## First run

The first interactive run offers a powerlevel10k-style setup wizard:

```
$ scrubmac
No configuration found. Run the setup wizard now? [Y/n]
```

The wizard walks through service selection (grouped: package managers, JS,
Python, AI tools, languages, heavy pruners), the **update cooldown** — skip
package versions younger than N days as a supply-chain guard (it also delays
security patches; the wizard says so) — and output preferences. Nothing is
written until you confirm the summary; re-run anytime with
`scrubmac configure`. Decline and sensible defaults are written instead.
Non-interactive runs (cron) never prompt.

## Usage

```
scrubmac                  run every enabled cleaner
scrubmac --dry-run        preview every command, execute nothing
scrubmac -q               quiet: banners + summary; failures still dump output
scrubmac homebrew npm     run exactly these cleaners (even if disabled)
scrubmac list             all cleaners: state, tool present, source
scrubmac doctor           environment + security report
scrubmac configure        (re)run the wizard
scrubmac enable docker    opt in to a disabled cleaner
scrubmac disable xcode    opt out of a cleaner
scrubmac update           update scrubmac itself (git pull --ff-only / brew)
```

Exit codes: `0` all ok/skipped · `1` something failed · `2` usage error ·
`130` interrupted. See `man scrubmac`.

## What it cleans

Every cleaner is presence-gated — absent tools skip harmlessly, so the full
set is safe on any machine. The exact commands each cleaner runs are
documented (and CI-enforced) in **[docs/cleaners.md](docs/cleaners.md)**:

| Group | Cleaners |
|---|---|
| Package managers | homebrew, mas |
| JavaScript | npm, pnpm, yarn, bun |
| Python | python (uv/pipx/pip), conda |
| AI dev tools | claude, codex, gemini, gh (extensions/Copilot), cursor |
| Languages | rustup, composer, go, mise |
| Heavy pruners (opt-in, **disabled by default**) | docker, xcode |

There is intentionally **no** "macOS deep clean": modern macOS maintains
itself, and a tool that refuses sudo can't (and shouldn't) do it.
[docs/security.md](docs/security.md) explains.

## Configuration

Lives in `~/.config/scrubmac/` — a strict `KEY=value` `config` file
(parsed, never executed), a `disabled` list, and `cleaners.d/` for your own
cleaners (a same-named cleaner overrides a built-in). Details:
[docs/configuration.md](docs/configuration.md).

## Writing your own cleaner

A cleaner is a ~10-line executable script dropped into
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
  compat symlink keeps old hardcoded cron paths working, and a transitional
  `cleanmymac` shim (removed in v4) keeps old PATH links alive — nagging you
  to switch.
- **Crontabs/aliases**: update them to `scrubmac`. Note: `cleanmymac` on
  PATH may eventually resolve to MacPaw's unrelated CLI once our shim is
  gone.

## Documentation

| | |
|---|---|
| [docs/architecture.md](docs/architecture.md) | how the dispatcher, lib, and cleaners fit together |
| [docs/cleaners.md](docs/cleaners.md) | every cleaner, every command it runs |
| [docs/configuration.md](docs/configuration.md) | wizard, config keys, env vars, cron usage |
| [docs/security.md](docs/security.md) | threat model, S1–S7, residual risks |
| [docs/writing-cleaners.md](docs/writing-cleaners.md) | cleaner contract + annotated template |
| [docs/troubleshooting.md](docs/troubleshooting.md) | common questions and failure modes |
| [docs/renaming.md](docs/renaming.md) | the cleanmymac → scrubmac rename record |
| [CONTRIBUTING.md](CONTRIBUTING.md) | dev setup, tests, PR checklist |
| [SECURITY.md](SECURITY.md) | reporting vulnerabilities |

## Uninstall

```bash
~/.scrubmac/uninstall.sh
```

Keeps your config by default; `--purge` removes that too. Homebrew installs:
`brew uninstall scrubmac`.

## License

[GPL-3.0-only](LICENSE) with one additional term under GPLv3 §7(b): works
based on this code must preserve attribution to the original project — see
[NOTICE](NOTICE). Free and open source, copyleft intact; credit required.
