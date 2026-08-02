# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[semver](https://semver.org).

## [Unreleased]

### Fixed

- `cleanmymac update` on Homebrew installs now derives its own formula name
  (tap + token) from the install receipt and Cellar path instead of
  hardcoding the personal tap — works unchanged for any tap or a future
  homebrew-core name.
- README: removed an incorrect claim that this project predates MacPaw's
  CleanMyMac (it does not — this repo is from 2018, MacPaw's product from
  2008/2009). The disclaimer now states the facts.

## [2.0.1] - 2026-08-02

### Fixed

- Homebrew name collision with MacPaw's unrelated `cleanmymac` cask: install
  docs now use the fully-qualified `brew install aviral2552/tap/cleanmymac`
  (a bare `brew install cleanmymac` installs the cask!), README documents the
  `brew trust` step for third-party taps, and `cleanmymac update` upgrades
  via the fully-qualified formula name.

## [2.0.0] - 2026-08-02

Full rework ("the 2026 rebirth"). Everything below is relative to 1.x.

### Breaking

- Cleaner selection moved from "delete files in `~/.cleanmymac/cleaners/`" to
  `cleanmymac enable|disable` + `~/.config/cleanmymac/` (config, `disabled`,
  `cleaners.d/`). Re-running `./install.sh` migrates a 1.x layout.
- `~/.cleanmymac/setup/uninstall.sh` → `~/.cleanmymac/uninstall.sh`
  (`--purge` also removes config).
- Atom cleaners removed (Atom sunset 2022). The fully-commented-out
  "macOS core cleaner" removed on purpose (see docs/security.md).
- Exit codes are now meaningful: 0 ok · 1 a cleaner failed · 2 usage ·
  130 interrupted.

### Fixed

- One failing cleaner no longer aborts the whole run — `npm outdated`
  exiting 1 used to kill everything after it (F1).
- `cleanmymac update` works: installs keep `.git`; updates are
  `git pull --ff-only` with a diffstat, or `brew upgrade` (F2, S3).
- The installer no longer `rm -rf`s the directory it was run from (F3) and
  no longer uses sudo (S1).
- `conda update` no longer hangs on its confirmation prompt (F4).
- npm: removed the npm-7-incompatible `--depth 9999`; self-update is skipped
  for brew/npm-managed installs (F5).
- Yarn berry no longer errors on `yarn global` (F6).
- Empty/stray files in the cleaners directory no longer break the run (F9).

### Added

- 19 presence-gated cleaners, including **AI dev CLIs** (Claude Code, Codex,
  Gemini, gh extensions/Copilot, Cursor — update-only, never their state
  dirs), pnpm, bun, uv/pipx/pip, mas, go, mise, and opt-in docker/xcode
  cache pruners (disabled by default).
- **Setup wizard** (`cleanmymac configure`, offered on first run):
  grouped service selection, supply-chain **update cooldown** (mechanical
  for uv; hold-and-advise for npm — npm's `--before` verifiably downgrades),
  output preferences.
- `--dry-run`, `--quiet` (buffer, dump on failure), per-cleaner runs,
  `list`, `doctor` (with security audit), `enable`/`disable`, summary table
  with durations and disk-freed estimate, run lock, clean Ctrl-C behavior.
- Security hardening (S1–S7): root-refusal, execution-safety guards on
  cleaner files/dirs, parse-never-source config, PATH audit, no-eval/no-sudo
  CI tripwires, threat model (docs/security.md), SECURITY.md.
- Tooling: shellcheck/shfmt/bats (108 tests), GitHub Actions CI
  (macOS + Linux + bash 3.2 smoke), release workflow with sha256 checksums,
  Homebrew formula template, man page, full docs set with drift-checked
  cleaner reference.

## [1.x]

Historical releases: see git history before this tag.
