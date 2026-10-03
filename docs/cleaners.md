# Cleaner reference

The single source of truth for what each cleaner does. CI (`make docs-check`)
fails if a cleaner runs a command this file does not name, if a section's
default disagrees with the cleaner's `# default:` header, or if a cleaner
and its section drift apart. Every command and flag below was checked
against the tool's official documentation or source (and, where it could be
done safely, run live) when it was added; the tests pin that exact usage.

## Shared contract

- **Presence-gated.** A missing tool means skip (exit 75), never an error.
- **Non-interactive.** Cleaners run with stdin from `/dev/null`, and every
  command that could prompt gets its `-y`/`--no-interaction`-style flag.
- **No sudo, no user data.** Updates and regenerable caches only — see
  [security.md](security.md#what-scrubmac-will-never-do).
- **Dry-run aware.** Mutating commands go through `run`/`step`, so
  `scrubmac --dry-run` prints them without executing; read-only *previews*
  (e.g. `brew upgrade --dry-run`) do execute under `--dry-run`, to show the
  real impact.
- **Modes.** `--update-only` skips cache cleanup; `--clean-only` changes no
  versions; offline (no default network route) skips updates but still
  cleans; `scrubmac status` runs only read-only *reports* and measures each
  cleaner's cache directories.
- **One failure never stops the rest** — and, inside a cleaner, a failed
  `step` does not stop the remaining independent steps (the cleaner still
  reports FAIL).
- **Package-manager awareness (D4).** A tool installed by Homebrew, npm,
  pipx or uv is updated by *that* manager's cleaner, and one that runs
  through a version manager (mise, asdf, Volta, nodenv, rbenv, pyenv) is left
  to it — never updated by its own self-updater (which would fight the
  manager). npm and corepack belong to the Node.js install. CLIs shipped as
  binary-only Homebrew casks (Claude Code, Codex, Copilot, Cursor) are
  upgraded by name.
- **Supply-chain cooldown (S4).** With `COOLDOWN_DAYS` > 0 (default 7),
  updates are limited to releases at least that old wherever it can be
  enforced: npm, pnpm and Bun global packages and pnpm's self-update
  (scrubmac's own resolver, `lib/registry.js`, picks each version from the
  registry's publish times), uv and pipx (their native settings). Yarn
  classic global upgrades and `bun upgrade` (which cannot be told a version)
  are held. Nothing is ever downgraded. The cooldown covers what these
  managers install — not other tools' own self-updaters (`uv self update`,
  `deno upgrade`, `rustup update`, `mise self-update`, the AI CLIs'
  `update` commands, …), which install their newest release.

| Group | Cleaner | Default |
|---|---|---|
| Package managers | homebrew, mas | on |
| JavaScript | npm, pnpm, yarn, bun, deno | on |
| Python | python, conda, poetry | on |
| AI tools | copilot, claude, codex, gemini, gh, cursor | on |
| Languages | rustup, composer, cargo, mise | on |
| Languages | go, rubygems | **off** (opt-in) |
| Developer tools | krew, vscode, pre-commit | on |
| Developer tools | docker | **off** (opt-in) |
| Apple development | cocoapods, swiftpm | on |
| Apple development | xcode | **off** (opt-in) |

Disable any cleaner with `scrubmac disable <name>`; enable an opt-in one
with `scrubmac enable <name>`.

### homebrew

`cleaners/10-homebrew.sh` — gate: `brew` — default: **on**

| Runs | When / why |
|---|---|
| `brew update` | refresh the formulae index (once; later commands run with `HOMEBREW_NO_AUTO_UPDATE=1`) |
| `brew upgrade --formula` | upgrade formulae |
| `brew upgrade --cask` | upgrade casks — **only when a person is watching** (`APP_UPDATES=interactive`, the default) or with `APP_UPDATES=always`: Homebrew 6 quits (and reopens) a running app whose cask declares `uninstall quit:`, and pkg-based casks stop for a sudo password |
| `brew doctor` *(advisory)* | health report — non-zero just means it has opinions (`HOMEBREW_DOCTOR=0` skips) |
| `brew missing` *(advisory)* | report missing dependencies (skipped with `brew doctor`) |
| `brew autoremove` *(advisory)* | drop dependencies nothing needs anymore |
| `brew cleanup -s --prune=all` | scrub downloads and old versions — runs even when an upgrade failed |
| `env HOMEBREW_NO_AUTO_UPDATE=1 brew outdated` | `scrubmac status` report (`brew outdated` would otherwise auto-update) |
| `env HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --formula --dry-run` | `--dry-run` preview |
| `env HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --cask --dry-run` | `--dry-run` preview (when casks would be upgraded) |
| `brew cleanup -s --prune=all --dry-run` | `--dry-run` preview |

`HOMEBREW_NO_ASK=1` is exported: Homebrew 6 otherwise asks "proceed?" on
a TTY.

### mas

`cleaners/20-mas.sh` — gate: `mas` — default: **on**

Reports pending Mac App Store updates with `mas outdated` (also the
`scrubmac status` report) and names how many in the summary. It never runs
`mas update`: mas installs updates as root by re-running itself through
`sudo`, and scrubmac never escalates — run `mas update` yourself. When
`mas outdated` itself fails (App Store lookups that time out make it exit
non-zero), the cleaner warns and notes "could not check the App Store" in
the summary instead of claiming nothing is pending; being a report, it does
not fail the run.

### npm

`cleaners/30-npm.sh` — gate: `npm` — default: **on**

- `npm outdated -g` — the `scrubmac status` report and the `--dry-run`
  preview *(exits 1 whenever anything is outdated)*.
- Which globals may be updated: `npm outdated -g --json` lists the outdated
  ones and `npm ls -g --long --json` tells how each was installed (`npm root
  -g` adds an on-disk check). Never touched: **npm and corepack** — they
  belong to the Node.js install and update with it (D4); **linked or local
  installs** (`npm link`, `npm i -g ./dir`) and **aliases**
  (`npm i -g x@npm:y`) — updating those by name would install an unrelated
  registry package of the same name in their place; and packages already
  newer than their `latest` tag (never downgraded). npm records no source for
  globals installed from a tarball or a git URL, so those look like registry
  installs.
- `npm update -g <pkg>…` — without a cooldown, for exactly those globals
  (not run when there are none). npm moves globals to the `latest`
  dist-tag, which can cross major versions.
- **With the cooldown:** for each of them, `npm view <pkg> time versions dist-tags --json`
  feeds scrubmac's resolver (`lib/registry.js`, run with node). It picks the
  newest release that is newer than the installed one, not past the
  `latest` tag, and published before the cutoff — a stable release, or a
  prerelease of the installed prerelease's own version (2.0.0-beta.1 may move
  to 2.0.0-beta.2, and to 2.0.0 as soon as that is old enough). Then
  `npm view "<pkg>@<v1> || <v2> …" name version deprecated engines --json`
  rules out deprecated releases and ones whose `engines.node` excludes this
  node (checked with npm's own semver; not checked when that cannot be
  loaded), stepping down at most three times, and scrubmac runs
  `npm install -g <pkg>@<version>`. Packages whose newer releases are all too
  fresh are held and counted in the summary. npm's own `--before`/
  `min-release-age` are deliberately not used: with `npm update -g` they
  *downgrade* globals newer than the cutoff.
- Without node (needed to read npm's JSON) global updates are held.
- `npm cache verify` — garbage-collect and verify the cache.

### pnpm

`cleaners/31-pnpm.sh` — gate: `pnpm` — default: **on**

- Global packages: `pnpm ls -g --depth=0 --json` lists them, and each moves
  to the newest release of its current major (what `pnpm update -g` does for
  the `^` ranges pnpm saves) — under the cooldown only to releases at least
  `COOLDOWN_DAYS` old — picked with `npm view` and scrubmac's resolver
  exactly as for npm (deprecated and engine-incompatible releases are
  stepped over), then installed with `pnpm add -g <pkg>@<version>`. Packages
  installed together (`pnpm add -g a,b` — one install group in pnpm ≥ 11)
  are re-added together, `pnpm add -g a@x,b@y`: re-adding one member alone
  would uninstall the others. pnpm records these as exact versions, so your
  own `pnpm update -g` leaves them where scrubmac put them (use
  `pnpm update -g --latest`). Never touched: pnpm itself, linked/local
  installs (`link:`, `file:`, git) and aliases (`npm:`). The lookups need
  node and npm; without them, `pnpm update -g` runs when the cooldown is off
  and global updates are held when it is on.
- `pnpm self-update` — standalone installs only (Corepack/Homebrew/npm/
  version-manager copies are left to their managers). Under the cooldown,
  `pnpm self-update <version>` names the newest release at least
  `COOLDOWN_DAYS` old (held, with a note, while every newer one is fresher).
- Updates run from an empty scratch directory: inside a project that pins
  pnpm (`packageManager`), `pnpm self-update` would rewrite that pin
  instead, and pnpm reads project settings from the working directory.
- pnpm's own `minimumReleaseAge` is deliberately not used: with it,
  `pnpm update -g` and `pnpm self-update` fail outright
  (`ERR_PNPM_NO_MATURE_MATCHING_VERSION`) whenever an installed release is
  newer than the cutoff, and pnpm 10's self-update ignores it.
- `pnpm store prune` — drop unreferenced packages from the
  content-addressable store.
- `pnpm outdated -g` — `scrubmac status` report.

### yarn

`cleaners/32-yarn.sh` — gate: `yarn` — default: **on**

Yarn 1 (classic): `yarn global upgrade -s` + `yarn cache clean`. Yarn
classic cannot filter by release age, so global upgrades are **held** while
the cooldown is on (the cache is still cleaned). Yarn 2+ (berry): caches are
per-project and `yarn global` no longer exists; the cleaner notes that and
does nothing.

### bun

`cleaners/33-bun.sh` — gate: `bun` — default: **on**

- `bun upgrade` — standalone installs only: it replaces the running binary
  in place, so Homebrew/npm/version-manager copies are left to their
  managers. It cannot be told a version — it always installs the newest
  release — so while the cooldown is on it is **held**, with a note when a
  newer Bun exists (`npm view bun …` tells): run `bun upgrade` yourself.
- `bun update -g` — global packages, within their saved ranges, without a
  cooldown.
- **With the cooldown:** the global packages are read from Bun's global
  directory (named by the `bun pm ls -g` header: its `package.json` and each
  package's installed version), each is resolved like npm's (`npm view` and
  scrubmac's resolver) within what its saved range allows (`^`: the same
  major, `~`: the same minor), and updated with
  `bun update -g <pkg>@<version>`, which keeps the range's operator. Exact
  pins (`bun update -g` leaves those too), linked/local installs and aliases
  are never touched. Bun's own `--minimum-release-age` is deliberately not
  used: `bun update -g` with it fails whenever an installed release is newer
  than the cutoff, and downgrades packages when a range allows it. The
  lookups need node and npm; without them global updates are held.
- `bun pm cache rm -g` — clear the global package cache (`-g`: without it,
  Bun 1.1–1.4 refuse to run outside a directory with a `package.json`);
  `bun pm cache -g` names it for `scrubmac status`.

### deno

`cleaners/34-deno.sh` — gate: `deno` — default: **on**

`deno upgrade` for standalone installs only (it replaces the running
executable; Homebrew/npm copies are updated by those cleaners). The module
cache is left alone: `deno clean` would wipe all of it.

### python

`cleaners/40-python.sh` — gate: `uv pipx python3` — default: **on**

| Runs | When / why |
|---|---|
| `uv self update` | only the uv that uv's standalone installer manages: its install receipt (`uv-receipt.json` in `$XDG_CONFIG_HOME/uv` or `~/.config/uv`, looked up the way uv does) must exist and name this uv's directory. uv from pip, cargo, conda, Homebrew or a version manager refuses (exit 2) — those get a note instead |
| `uv tool upgrade --all` | upgrade uv-managed tools |
| `uv tool upgrade --all --exclude-newer "N days"` | under the cooldown (uv ≥ 0.11.4 keeps the span relative in tool receipts; older uv gets an absolute RFC 3339 date) |
| `uv tool upgrade <tool> --exclude-newer false` | cooldown off, uv ≥ 0.11.24, before the upgrade above: for each tool whose receipt still carries a cutoff from an earlier cooldown (uv remembers it, so plain upgrades keep honoring it) — unless your own uv settings (`UV_EXCLUDE_NEWER`, `uv.toml`) set `exclude-newer`. Older uv: a summary note says how many tools stay held back |
| `pipx upgrade-all` | upgrade pipx-managed packages |
| `pipx upgrade-all --cooldown N` | under the cooldown (pipx ≥ 1.16; older pipx holds its upgrades) |
| `pipx upgrade-all --cooldown 0` | cooldown off, pipx ≥ 1.16: pipx remembers an earlier `--cooldown` per package, and 0 is its opt-out (plain `pipx upgrade-all` when `PIPX_COOLDOWN` is set) |
| `uv cache prune` | with `UV_LOCK_TIMEOUT=15` (uv ≥ 0.9.16): a cache held by running uv/uvx processes (e.g. MCP servers) is skipped with a note instead of waited on — and never `--force`d, which would delete environments those processes run from. Older uv: skipped up front when a uv process or anything executing from the cache is running |
| `python3 -m pip cache purge` *(advisory)* | exits 1 when pip's cache is disabled |
| `uv tool list --outdated` | `scrubmac status` report (uv ≥ 0.10.10) |

`uv self update` installs the newest uv: the cooldown covers the tools uv
and pipx install, not uv's own self-update.

### conda

`cleaners/41-conda.sh` — gate: `conda micromamba` — default: **on**

- `conda update -n base conda -y` — conda itself, the documented way;
  never `conda update --all`, which would churn every package in base. A
  frozen base environment (`conda-meta/frozen`, CEP 22) is left alone.
- `conda clean --all -y` — index cache, unused packages, tarballs.
- `micromamba self-update` (standalone installs only) and
  `micromamba clean --all -y`.
- `conda update -n base conda --dry-run` — `scrubmac status` report.

`-y` everywhere: without it conda prompts, and a non-interactive run would
hang (F4).

### poetry

`cleaners/42-poetry.sh` — gate: `poetry` — default: **on**

- `poetry self update` — only for the official installer's Poetry;
  pipx- and Homebrew-managed copies are left to those managers.
- `poetry cache clear <name> --all -n` — for every cache `poetry cache list`
  shows (`-n`: it asks otherwise).

### copilot

`cleaners/44-copilot.sh` — gate: `copilot` — default: **on**

GitHub Copilot CLI (the standalone `copilot`; the old `gh copilot` extension
is retired). Standalone installs run `copilot update` (when `copilot --help`
lists it); the binary-only Homebrew cask is upgraded with
`brew upgrade --cask copilot-cli`; npm installs are left to the npm cleaner.
Never touches `~/.copilot`.

### claude

`cleaners/45-claude.sh` — gate: `claude` — default: **on**

Native installs run `claude update`; the binary-only Homebrew cask is
upgraded by name (`brew upgrade --cask claude-code` — `claude update` does
nothing there); npm installs are left to the npm cleaner. Never touches
`~/.claude` — it holds sessions, memory, and auth (D3).

### codex

`cleaners/46-codex.sh` — gate: `codex` — default: **on**

`codex update` (Codex 0.128+) detects how Codex was installed and runs the
matching updater (Homebrew cask, standalone installer). It is only run when
`codex --help` lists it: older releases would take "update" as a chat
prompt. npm installs are left to the npm cleaner (which applies the
cooldown). Never touches `~/.codex`.

### gemini

`cleaners/47-gemini.sh` — gate: `gemini` — default: **on**

Gemini CLI has no self-update command — `gemini update` would start a chat —
so nothing is ever run: npm installs are updated by the npm cleaner, and
Homebrew installs get a note that the `gemini-cli` formula is deprecated
and no longer follows releases (reinstall with npm).

### gh

`cleaners/48-gh.sh` — gate: `gh` — default: **on**

`gh extension upgrade --all` — exits 0 when there is nothing to upgrade, so a
non-zero exit is a real failure. Extension commands need a logged-in gh
(they exit 4 otherwise), so the cleaner is skipped, with the reason, when
`gh auth status` fails (exit 1: no host logged in, or a token that no longer
works) or `gh extension list` shows no extensions. gh itself is usually
Homebrew-managed. `gh extension list` is the `scrubmac status` report (when
logged in).

### cursor

`cleaners/49-cursor.sh` — gate: `cursor-agent` — default: **on**

The Cursor CLI agent (installed as `agent`, with `cursor-agent` kept as an
alias): `cursor-agent update` for standalone installs; the binary-only
Homebrew cask is upgraded by name. Never touches `~/.cursor`.

### rustup

`cleaners/50-rustup.sh` — gate: `rustup` — default: **on**

`rustup update` — toolchains, plus rustup itself unless a package manager
owns it (Homebrew's rustup is built without self-update and says so).
`rustup check` is the `scrubmac status` report (rustup ≥ 1.29 exits 100 when
updates are available — news, not a failure).

### composer

`cleaners/51-composer.sh` — gate: `composer` — default: **on**

`composer global update --no-interaction` + `composer clear-cache`. The
global update (and the `composer global outdated` status report) only runs
when the global Composer home has a `composer.json` — without global
packages those commands just error out.

### go

`cleaners/52-go.sh` — gate: `go` — default: **off**

`go clean -cache` clears the build cache. Opt-in, because Go already deletes
build-cache entries it has not used recently — clearing everything mostly
forces cold rebuilds. The module cache is never touched.

### cargo

`cleaners/53-cargo.sh` — gate: `cargo-install-update` — default: **on**

`cargo install-update -a` upgrades every binary installed with
`cargo install`, via the [cargo-update](https://github.com/nabijaczleweli/cargo-update)
extension (`cargo install cargo-update` enables this cleaner).
`cargo install-update -l` is the `scrubmac status` report.

### rubygems

`cleaners/54-rubygems.sh` — gate: `gem` — default: **off**

`gem cleanup` uninstalls superseded versions of installed gems that nothing
requires (`gem cleanup -d` is the `--dry-run` preview: RubyGems < 3.2
rejects `--dry-run`). Opt-in, because those are installed software rather
than a cache. macOS's system Ruby is never touched — its gems belong to the
OS.

### mise

`cleaners/55-mise.sh` — gate: `mise` — default: **on**

- `mise self-update -y` — standalone installs only (`-y`: it asks
  otherwise; Homebrew's mise refuses to self-update).
- `mise outdated` *(advisory; also the `scrubmac status` report)*
- `mise cache clear`
- `mise prune --yes` — only with `MISE_PRUNE=1`: removes installed tool
  versions no tracked config uses (it asks otherwise).

`mise upgrade` is deliberately NOT run: bumping pinned tool versions is a
per-project decision.

### docker

`cleaners/60-docker.sh` — gate: `docker` — default: **off**

Requires a running daemon (skips otherwise).

- `docker system df` — usage report (also `status`/`--dry-run`)
- `docker builder prune -f --filter until=<DOCKER_KEEP_HOURS>h` — build
  cache not used within the window (default 168h = a week)
- `docker image prune -f` — dangling images only

Never touches containers, volumes, or tagged images (D3). Docker Desktop's
disk image is sparse and hands freed space back to macOS gradually, so the
disk-freed figure can lag.

### krew

`cleaners/61-krew.sh` — gate: `kubectl-krew` — default: **on**

`kubectl krew upgrade` refreshes the plugin index and upgrades every kubectl
plugin installed with krew. krew exits 0 even when a plugin fails to upgrade
(it only prints `WARNING: failed to upgrade plugin …`), so its output is
checked and such a run reports FAIL. `kubectl krew list` is the
`scrubmac status` report.

### vscode

`cleaners/62-vscode.sh` — gate: `code` — default: **on**

`code --update-extensions` (VS Code 1.86+) updates installed extensions from
the command line; no window opens. VS Code itself updates through its own
updater or package manager.

### pre-commit

`cleaners/63-pre-commit.sh` — gate: `pre-commit` — default: **on**

`pre-commit gc` deletes cached hook repositories and environments that no
recorded `.pre-commit-config.yaml` still uses. gc counts a recorded config
it cannot read as deleted, so it is **skipped** (with a summary note) while
one sits where this run cannot see it: inside a folder macOS keeps from
scheduled jobs (`~/Desktop`, `~/Documents`, `~/Downloads`, iCloud Drive) or
on an unmounted volume. The recorded configs come from pre-commit's `db.db`
(`sqlite3 -readonly`); without sqlite3, any unreadable protected folder
blocks gc.

### xcode

`cleaners/70-xcode.sh` — gate: `xcodebuild`, `~/Library/Developer/Xcode/DerivedData` — default: **off**

- Nothing is touched while Xcode is running (checked first).
- `xcrun simctl delete unavailable` *(advisory)* — simulators for runtimes
  no longer installed; needs a full Xcode (not just the Command Line Tools).
- DerivedData: each `~/Library/Developer/Xcode/DerivedData/<Project>-<hash>`
  is removed with `rm -rf` when its project (Xcode's recorded
  `WorkspacePath`) verifiably no longer exists — missing while its parent
  folder exists and can be listed — or when Xcode's own `LastAccessedDate`
  is older than `DERIVEDDATA_AGE_DAYS` (default 30). A scheduled run cannot
  read `~/Desktop`, `~/Documents`, `~/Downloads` or iCloud Drive, and
  volumes come and go: such projects are unknown, never "gone", and only
  the age rule applies. Folders without Xcode's record are kept if anything
  inside changed within the window.
- Device support: each `~/Library/Developer/Xcode/<platform> DeviceSupport/<version>`
  folder older than `DEVICESUPPORT_AGE_DAYS` (default 90) is removed with
  `rm -rf` — except the newest per platform, which the device you use is
  most likely to need. Xcode re-copies symbols when a device reconnects.

### cocoapods

`cleaners/71-cocoapods.sh` — gate: `pod` — default: **on**

`pod cache clean --all` clears the downloaded-pod cache
(`~/Library/Caches/CocoaPods/Pods`); spec repos are kept.

### swiftpm

`cleaners/72-swiftpm.sh` — gate: `swift` — default: **on**

`swift package purge-cache` purges SwiftPM's global dependency cache
(repository clones, registry downloads, manifests). It writes a `.build`
directory into the current directory, so it runs from a throwaway one.

## Considered and declined

- **Dart / Flutter** (`dart pub cache clean`): it wipes the whole pub cache,
  *including every globally activated tool* (`dart pub global activate`) —
  installed software, not a cache.
- **Gradle**: Gradle already deletes version-specific caches unused for 30
  days (and its build cache after 7), so a cleaner adds little but risk.
- **`deno clean`**: removes the entire Deno cache; Deno projects re-download
  everything.
- **`mas update`**: requires root (mas re-runs itself through sudo).
- **Model caches** (Ollama, Hugging Face): multi-gigabyte downloads you
  chose — user data by this project's own rules.
- **`brew upgrade --greedy`**: `auto_updates` casks update themselves.
