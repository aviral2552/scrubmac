# Changelog

All notable changes to this project are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versions follow
[semver](https://semver.org).

## [3.1.0] - 2026-10-04

The "unattended runs" release: everything a scheduled run needs to be
trustworthy, a supply-chain cooldown that is on by default and actually
enforced, ten new cleaners, and a pile of correctness fixes — each with a
regression test, and every external command checked against its tool's
official documentation.

**Upgrading from 3.0:** if you declined the first-run setup wizard in 2.x or
3.0 (or chose "Off" in it), your config file contains `COOLDOWN_DAYS=0`, so
the new 7-day default does not apply until you change it — check with
`scrubmac config get COOLDOWN_DAYS`, then `scrubmac config set COOLDOWN_DAYS
7` or `scrubmac configure`. Installs without a config file get 7 days
automatically. Options that a command would ignore are now errors (for
example `scrubmac -n update` — use `scrubmac update --check`); check scripts
that pass extra flags.

### Fixed

- A cleaner that read stdin silently consumed the rest of the run: the run
  loop fed the cleaner list through stdin, so the next cleaner vanished from
  the run *and* the summary while the run reported success. Cleaners now get
  `/dev/null` as stdin (which also guarantees no prompt can be answered for
  them).
- `CMM_COOLDOWN_DAYS` / `CMM_DERIVEDDATA_AGE_DAYS` (and `CMM_COLOR`) in the
  environment were overwritten by the config file, contrary to the
  documented precedence. Every setting now resolves flag → environment →
  config → default, with type validation.
- A cleaner refused by the execution-safety guard disappeared and the run
  exited 0. It is now reported as `REFUSED` and fails the run (exit 1).
- Cron and terminal runs did not exclude each other: the lock lived in
  `$TMPDIR`, which cron does not set. The lock now lives in
  `~/.local/state/scrubmac`, is created atomically (a symlink naming the
  holder's pid and start time, so pid reuse cannot fake a live holder), and
  cannot be stolen by a racing run.
- `uninstall.sh` deleted whatever `CMM_PREFIX`/`CMM_OLD_PREFIX` named — even
  `$HOME`. It now removes only directories that hold a scrubmac install
  (compared as canonical paths, never `/`, your home or a parent of it), a
  compat symlink only when it points at the install, and with `--purge`
  only config/state dirs named `scrubmac`/`cleanmymac`; a refusal exits 1.
  It checks the install dir before touching anything (a mistyped
  `CMM_PREFIX` no longer costs the real install its links and schedule —
  nor, with `--purge`, your configuration), and handles a symlinked install
  path: the link goes, and its target too when install.sh created it. A git
  checkout install.sh did not make is never deleted while it holds local
  work (uncommitted, untracked, stashed or unpushed).
- A Homebrew upgrade of scrubmac itself during a run (by the homebrew
  cleaner) deleted the files later cleaners were about to run. Built-in
  cleaners now run from a private copy made at the start of the run.
- The documented crontab line skipped nearly every cleaner (cron's PATH is
  `/usr/bin:/bin`) and still reported success. scrubmac now warns when every
  cleaner skipped, `doctor` flags a crontab without `PATH`, and
  `scrubmac schedule` replaces cron with a launchd agent that carries your
  PATH.
- `scrubmac configure` reset every answer — including `DERIVEDDATA_AGE_DAYS`,
  which it overwrote with 30 — instead of starting from the current config.
  It now seeds every screen from the config on disk and preserves every key
  it does not manage.
- The xcode cleaner judged DerivedData age by the folder's own mtime, which
  does not change during builds, so it could delete caches of projects in
  active use. It now reads Xcode's own `LastAccessedDate` (and purges folders
  whose project is gone — but never treats a project it merely cannot see,
  in a privacy-protected folder or on an unmounted volume, as gone), and
  leaves everything alone while Xcode runs.
- On a Mac without the Command Line Tools, probing `/usr/bin/python3` (or
  git, swift, …) popped the "install developer tools" dialog — even from a
  scheduled run. Apple's inert developer-tool shims now count as absent, and
  `xcodebuild` requires a full Xcode.
- `install.sh` moved whatever directory sat at `~/.cleanmymac` (or
  `CMM_OLD_PREFIX`) to `~/.scrubmac` during the rename migration, then
  mirrored over it with `rsync --delete` — erasing it if it was not a
  cleanmymac install. Only a real install is migrated now.
- `install.sh` could overwrite a Homebrew-installed `scrubmac` link, and its
  `rsync --delete` would mirror into any `CMM_PREFIX` (even `$HOME`). It now
  mirrors only into an empty directory or an existing scrubmac install (real
  files, not just a launcher link — so not `~/.local`), compares canonical
  paths (`$HOME/.` and symlinked parents cannot slip past), refuses `$HOME`,
  `/`, a parent of your home, and source/destination nesting, replaces only
  links that are its own, and says when two installs now exist. It never
  mirrors over a working clone either: an install path that links to a
  copy install.sh did not create (the dev-clone setup), or a git checkout
  with uncommitted, untracked, stashed or unpushed work — mirroring would
  have erased it, `.git` and all.
- Self-updaters ran on copies a version manager owns: tools reached through
  mise/asdf/volta/nodenv/rbenv/pyenv shims were "standalone", so their own
  updaters overwrote the manager's copy (and `uv self update` failed every
  run on a mise- or asdf-managed uv); on Intel Macs any standalone binary in
  `/usr/local` was taken for Homebrew's. Version-manager copies are now left
  to their manager, and only Homebrew's own Cellar/Caskroom/opt links count
  as Homebrew-managed.
- `uv self update` failed every run for a uv not installed by uv's own
  installer (pip, cargo, conda…); it now runs only for that installer's copy.
- The `cleanmymac` compat shim told every user to re-run install.sh, even on
  an already-migrated install; it now says which install.sh to run only when
  migration is unfinished, and otherwise just to call `scrubmac`.
- `uv cache prune` could still wait up to uv's 5-minute lock timeout on a
  cache held by uvx-served tools; it now gives up after 15 s and says so.
- `conda update --all -y` churned every package in the base environment; the
  conda cleaner now updates conda itself (`conda update -n base conda`), the
  documented way, and leaves a frozen base alone.
- The bun cleaner failed every run on a machine with no global Bun packages
  (`bun update -g` and `bun pm cache rm -g` need the global `package.json`);
  it now works from a scratch directory and says there is nothing to update.
- A `disabled` (or `enabled`) file that could not be read — its permissions,
  or a dotfiles symlink into a folder a launchd job may not open — was
  treated as empty, so cleaners you had turned off ran. Runs and `list` now
  stop (exit 2) and say which file to fix; `doctor` reports it.
- A config file saved with CRLF line ends (or a byte-order mark) was
  silently ignored line by line; it is now read as written. A hand-edited
  key one typo away from a built-in setting is reported.
- Interrupting scrubmac before the first cleaner started, or during the
  final summary, exited 143 or 129 and could leave the run record
  contradicting the exit code; it now exits 130 (or finishes the summary
  first), and a cleaner that had already finished keeps its own result.
- An exported `CDPATH` broke running scrubmac, `install.sh` or
  `uninstall.sh` by a relative path.

### Added

- **Timeouts:** every cleaner runs under a watchdog (`TIMEOUT`, default 3600 s)
  that stops it together with the processes it started (`TERM`, then `KILL`
  after up to 5 s; in runs without a terminal via the cleaner's own process
  group, which also reaches orphaned descendants — though not a process that
  detaches with `setsid` — and stops what a cleaner leaves running, as
  launchd would); the summary says `TIMEOUT`.
- **`scrubmac schedule daily [HH:MM] | weekly [DAY] [HH:MM] | status | off`**
  — a per-user launchd agent (runs missed schedules after sleep), with
  `--scheduled` guards: `ON_BATTERY`, `MIN_HOURS_BETWEEN_RUNS`. Status and
  `doctor` print the exact command that recreates a broken schedule.
- **Run logs** (`~/.local/state/scrubmac/logs`, rotated to `LOG_KEEP`),
  **`scrubmac last [--json]`**, a `last-run.json` record, and **`--json`**
  output for monitoring.
- **Desktop notifications** after unattended runs (`NOTIFY=failures`).
- **`scrubmac status`** — read-only cache sizes and outdated packages.
- **`--update-only` / `--clean-only`**, **`--skip <cleaner>`**, and
  **`--measure`** (space freed per cleaner).
- **Offline detection** from the routing table: updates are skipped, cleanup
  still runs.
- **`scrubmac config [get|set|unset|path|keys]`** (a key one typo away from
  a built-in key is refused), did-you-mean suggestions for mistyped cleaners
  and commands, total run time and per-cleaner notes in the summary (a
  failing step names its command), warnings for config lines the parser
  ignores and for a Homebrew that is installed but not on the run's PATH,
  and a much richer `doctor` (settings, install kinds, schedule, crontab
  PATH and double scheduling, refusal reasons, unwritable dirs, last run,
  network and power, dangling launcher links).
- **`scrubmac update --check`**; git installs follow **release tags** by
  default (`UPDATE_CHANNEL=release|branch`) — the newest `vX.Y.Z` that is a
  fast-forward, mirrored into a private ref namespace so your own tags are
  never touched — and verify **SSH tag signatures** against keys pinned in
  the installed copy once releases ship `share/allowed_signers`. A newer
  release that fails a check (unsigned, re-pointed upstream, misnamed,
  diverged) is skipped with a warning; with pinned keys, a remote without
  release tags is refused instead of followed as an unsigned branch.
- **New cleaners:** deno, poetry, copilot (the new standalone GitHub Copilot
  CLI), cargo (cargo-update), krew, vscode (extensions), pre-commit,
  cocoapods, swiftpm, micromamba (in the conda cleaner), and opt-in rubygems.
- **Shell completions** for bash, zsh, and fish (installed by the formula and
  linked by `install.sh` into a writable Homebrew prefix): days only after
  `schedule weekly`, setting keys only after `config get|set|unset`.
- **`scrubmac run [cleaner …]`** as an explicit spelling of the default
  command; `--skip` and `enable`/`disable` take comma-separated lists.
- Cleaner **metadata headers** (`# group:`, `# default:`, `# summary:`) drive
  `list`, the wizard's screens, and defaults; cleaners report notes, cache
  sizes, and freed space back to the dispatcher.
- New cleaner helpers: `step` (record a failure, keep going), `preview` and
  `report` (with `--ok=N` for tools whose exit N is an answer, like `npm
  outdated`'s 1), `cache_dir`, `updating`/`cleaning`, `app_updates_allowed`,
  `summary_note`, `brew_cask_upgrade_self`, `has_subcommand`, `setting`.

### Changed

- **The supply-chain cooldown is on by default (7 days)** and enforced —
  dependencies included, never downgrading:
  - npm, pnpm and Bun: a shared resolver installs the newest release old
    enough (within each global's saved range for pnpm and Bun, whose `^`/`~`
    is kept — exact pins and other ranges never move), stepping over
    deprecated releases and ones that need a newer Node, and each manager's
    own age gate holds the dependencies (`npm install --before` or
    `--min-release-age`, pnpm's `minimum-release-age`, Bun's
    `--minimum-release-age`); pnpm < 10.16 and Bun < 1.3, which have no
    gate, hold global updates. `bun upgrade` runs only when the release it
    would install is old enough.
  - uv: a relative `--exclude-newer` span; pipx: `--cooldown`; Yarn classic:
    global upgrades are held.
  - A stricter policy of your own (npm `min-release-age`/`before`, pnpm
    `minimumReleaseAge`, a bunfig `minimumReleaseAge`, uv `exclude-newer`,
    `PIPX_COOLDOWN`) is never relaxed.
  - `COOLDOWN_DAYS=0` opts out — and also clears the cutoffs earlier runs
    left in uv receipts and pipx metadata.
- **Homebrew casks are upgraded only when a person is watching**
  (`APP_UPDATES=interactive`; Homebrew 6 quits running apps and pkg casks ask
  for a password). `brew upgrade` is split into `--formula` and `--cask`, a
  failed upgrade no longer skips `brew cleanup`, and Homebrew's confirmation
  prompt is disabled explicitly.
- **mas only reports App Store updates**: mas installs them as root via
  sudo, which scrubmac never triggers.
- **The go cleaner is opt-in** (Go already trims its build cache); existing
  installs keep it enabled when 3.0 wrote a `disabled` file (it did as soon
  as you made any choice) — otherwise run `scrubmac enable go`.
- New cleaner state model: `enabled` + `disabled` lists of explicit choices
  (with a header line; your comments are kept when scrubmac rewrites them),
  header defaults otherwise —
  converted once from the ≤ 3.0 format.
- **The npm cleaner leaves the npm (and corepack) bundled with Node alone**
  — they update with your Node install (Homebrew re-pins npm on every node
  upgrade, and a newer npm major can refuse an older Node) — and never
  replaces a global you installed with `npm link` or from a local path.
- `--quiet` prints one line per cleaner instead of a banner over hidden
  output; `status` always shows output; the wizard's summary screen takes
  Enter as yes and asks again on anything it does not understand.
- Cleaners start in your home directory, whatever directory scrubmac was
  started from (launchd starts its jobs in `/`).
- AI CLIs: `codex update` runs only when the installed Codex has it (older
  releases would take "update" as a prompt); binary-only casks (Claude Code,
  Codex, Copilot, Cursor) are upgraded by name, so they update in scheduled
  runs too.
- uv tool and pipx upgrade failures now fail the python cleaner (3.0 ran
  them as advisory commands).
- docker prunes build cache older than `DOCKER_KEEP_HOURS` (default a week)
  instead of all of it; `gh extension upgrade --all` failures now fail the
  cleaner (it exits 0 when there is nothing to do), and a gh that is not
  logged in (`gh extension list` exits 4), or has no extensions, is
  skipped; `mise prune` is
  available behind `MISE_PRUNE=1`; xcode also prunes old device-support
  symbols (`DEVICESUPPORT_AGE_DAYS`, newest kept).
- `install.sh` no longer seeds a `disabled` file and no longer suggests a
  `cleanmymac` alias; `uninstall.sh` also removes a schedule that runs the
  install it removes, completion links, and (with `--purge`) the state dir.

### Security

- Release workflow: build-provenance attestations for the tarball, and the
  same gates as CI — pinned, checksum-verified linters and the full test
  suite on macOS and Linux — before anything is published; CI actions
  pinned to commit SHAs (Dependabot keeps them current), read-only tokens by
  default, OpenSSF Scorecard.
- Notifications pass text to `osascript` as arguments; cleaner names are
  restricted to a safe character set; the launchd agent's PATH drops `.`
  and relative entries.

### Documentation

- Every cleaner's commands, defaults, and rationale in docs/cleaners.md —
  now checked against the code in CI (every command a cleaner runs through
  scrubmac's helpers, and every self-updater it hands off, must be named
  there), along with every setting and command in the configuration docs,
  README, and man page. New: a demo, a topgrade comparison, a
  roadmap (docs/roadmap.md), and a "considered and declined" list. The
  executed rename plan moved to docs/history/.

## [3.0.1] - 2026-08-10

### Fixed

- python cleaner: `uv cache prune` no longer waits indefinitely when the uv
  cache is in use (resident uvx-served tools — e.g. MCP servers — run out of
  the cache and never exit). The prune is skipped with a note instead;
  upgrades are unaffected. `--force` is deliberately not used: it would
  delete environments that running processes are executing from.

## [3.0.0] - 2026-08-09

**The project is now `scrubmac`** (formerly cleanmymac, 2018–2026) — renamed
to end the collision and confusion with MacPaw's unrelated commercial
products, including their official `cleanmymac-cli`, which claims the
`bin/cleanmymac` name in Homebrew.

### Breaking / renamed

- Binary: `cleanmymac` → `scrubmac`. A transitional shim keeps old PATH
  links and cron paths working (never PATH-linked for new installs;
  removed in v4).
- Install dir: `~/.cleanmymac` → `~/.scrubmac`; config:
  `~/.config/cleanmymac` → `~/.config/scrubmac`. Both migrate automatically
  (config on first run or install; install dir on `install.sh` re-run, with
  a compat symlink left at the old path). Dotfiles-manager symlinks are
  detected and warned about, never silently lost.
- Homebrew formula: `aviral2552/tap/cleanmymac` → `aviral2552/tap/scrubmac`
  (`brew upgrade` follows the rename automatically).
- `CMM_*` environment variables and config keys are unchanged.

### Changed

- License: still GPL-3.0-only, now with a GPLv3 §7(b) additional term
  requiring preservation of attribution to the original project in
  derivative works (new NOTICE file, license pointers in every source
  file). Releases ≤ 2.0.1 remain plain GPL-3.0 as published.
- The transitional scrubmac also holds the legacy `cleanmymac` run lock so
  an untouched 2.x cron copy and 3.x still exclude each other.

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
