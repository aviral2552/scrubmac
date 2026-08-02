# cleanmymac

[![CI](https://github.com/aviral2552/cleanmymac/actions/workflows/ci.yml/badge.svg)](https://github.com/aviral2552/cleanmymac/actions/workflows/ci.yml)
[![License: GPL-3.0](https://img.shields.io/badge/license-GPL--3.0-blue.svg)](LICENSE)

One command that updates and cleans the dev tools on your Mac — Homebrew,
npm/pnpm/yarn/bun, Python (uv/pipx/conda), Rust, Go, Composer, mise, the Mac
App Store, your AI coding CLIs (Claude Code, Codex, Gemini, Cursor, Copilot
via gh), and opt-in cache pruners for Docker and Xcode.

> Not affiliated with MacPaw's CleanMyMac products. This is an independent,
> open-source shell tool that predates any resemblance.

```
$ cleanmymac

cleanmymac 2.0.0 — starting up the cleaning engines

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
- **Preview everything.** `cleanmymac --dry-run` prints every command that
  would run, runs nothing.
- **One failure never stops the rest.** Each cleaner runs in its own process;
  the summary tells you exactly what happened.
- **Auditable.** ~1,500 lines of shellcheck-clean bash you can read in one
  sitting, with a [threat model](docs/security.md) and a test suite pinning
  the safety properties.

## Install

**Homebrew** (once the tap is published — see [RELEASING.md](RELEASING.md)):

```bash
brew tap aviral2552/tap && brew install cleanmymac
```

**From source** (installs to `~/.cleanmymac`, links into your PATH, no sudo):

```bash
git clone https://github.com/aviral2552/cleanmymac.git && cd cleanmymac && ./install.sh
```

There is deliberately no `curl | bash` one-liner — an installer you can't
read before running it would contradict [the security posture](docs/security.md).
Release tarballs ship sha256 checksums.

## First run

The first interactive run offers a powerlevel10k-style setup wizard:

```
$ cleanmymac
No configuration found. Run the setup wizard now? [Y/n]
```

The wizard walks through service selection (grouped: package managers, JS,
Python, AI tools, languages, heavy pruners), the **update cooldown** — skip
package versions younger than N days as a supply-chain guard (it also delays
security patches; the wizard says so) — and output preferences. Nothing is
written until you confirm the summary; re-run anytime with
`cleanmymac configure`. Decline and sensible defaults are written instead.
Non-interactive runs (cron) never prompt.

## Usage

```
cleanmymac                  run every enabled cleaner
cleanmymac --dry-run        preview every command, execute nothing
cleanmymac -q               quiet: banners + summary; failures still dump output
cleanmymac homebrew npm     run exactly these cleaners (even if disabled)
cleanmymac list             all cleaners: state, tool present, source
cleanmymac doctor           environment + security report
cleanmymac configure        (re)run the wizard
cleanmymac enable docker    opt in to a disabled cleaner
cleanmymac disable xcode    opt out of a cleaner
cleanmymac update           update cleanmymac itself (git pull --ff-only / brew)
```

Exit codes: `0` all ok/skipped · `1` something failed · `2` usage error ·
`130` interrupted. See `man cleanmymac`.

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
itself, the old core cleaner died fighting SIP, and a tool that refuses sudo
can't (and shouldn't) do it. [docs/security.md](docs/security.md) explains.

## Configuration

Lives in `~/.config/cleanmymac/` — a strict `KEY=value` `config` file
(parsed, never executed), a `disabled` list, and `cleaners.d/` for your own
cleaners (a same-named cleaner overrides a built-in). Details:
[docs/configuration.md](docs/configuration.md).

## Writing your own cleaner

A cleaner is a ~10-line executable script dropped into
`~/.config/cleanmymac/cleaners.d/`. Template and contract:
[docs/writing-cleaners.md](docs/writing-cleaners.md).

## Migrating from 1.x

2.x is a full rework; the visible changes:

- `cleanmymac update` actually works now (installs keep their `.git`)
- cleaner selection moved from "delete files in `~/.cleanmymac/cleaners`" to
  `cleanmymac enable/disable` + `~/.config/cleanmymac/`
- the installer no longer sudo-links into `/usr/local/bin` and no longer
  deletes its source directory; re-running `./install.sh` migrates a 1.x
  layout automatically
- Atom cleaners are gone (Atom sunset in 2022); the always-commented-out
  "macOS core cleaner" is gone on purpose
- uninstall: `~/.cleanmymac/uninstall.sh` (add `--purge` to also remove config)

## Documentation

| | |
|---|---|
| [docs/architecture.md](docs/architecture.md) | how the dispatcher, lib, and cleaners fit together |
| [docs/cleaners.md](docs/cleaners.md) | every cleaner, every command it runs |
| [docs/configuration.md](docs/configuration.md) | wizard, config keys, env vars, cron usage |
| [docs/security.md](docs/security.md) | threat model, S1–S7, residual risks |
| [docs/writing-cleaners.md](docs/writing-cleaners.md) | cleaner contract + annotated template |
| [docs/troubleshooting.md](docs/troubleshooting.md) | common questions and failure modes |
| [CONTRIBUTING.md](CONTRIBUTING.md) | dev setup, tests, PR checklist |
| [SECURITY.md](SECURITY.md) | reporting vulnerabilities |

## Uninstall

```bash
~/.cleanmymac/uninstall.sh
```

Keeps your config by default; `--purge` removes that too. Homebrew installs:
`brew uninstall cleanmymac`.

## License

[GPL-3.0](LICENSE)
