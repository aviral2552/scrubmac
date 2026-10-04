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
  (scrubmac's own resolver, `lib/registry.cjs`, picks each version from the
  registry's publish times, and the manager's own age gate — npm
  `--before`, pnpm `minimumReleaseAge`, Bun `--minimum-release-age` — holds
  the package's **dependencies** to the same cutoff), `bun upgrade` (only
  when Bun's newest release is itself old enough), uv and pipx (their native
  settings). Yarn classic global upgrades, and pnpm/Bun releases too old to
  gate dependencies (pnpm < 10.16, Bun < 1.3), are held. A release-age
  policy of your own (npm `min-release-age`/`before`, pnpm
  `minimumReleaseAge`, bunfig `install.minimumReleaseAge`, uv
  `exclude-newer`, `PIPX_COOLDOWN`) is never relaxed: the stricter one wins,
  and applies even with the cooldown off. Nothing is ever downgraded. The
  cooldown covers what these managers install — not other tools' own
  self-updaters (`uv self update`, `deno upgrade`, `rustup update`,
  `mise self-update`, the AI CLIs' `update` commands, …), which install
  their newest release.

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
| `brew --cache` | where the download cache is, for its size in `scrubmac status` (and `--measure`) |

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
  registry package of the same name in their place; packages already newer
  than their `latest` tag (never downgraded); and packages whose installed
  version is **not a release of that name on the registry**. npm records no
  source at all for globals installed from a tarball or a git URL (verified
  with npm 11/12), so that last check is what catches them — unless their
  version happens to be a published one, in which case they look exactly
  like registry installs (use `npm link` for a private tool). A package the
  configured registry does not know (E404) is skipped with a note.
- The cutoff: `COOLDOWN_DAYS`, or your own `min-release-age` / `before`
  (read with `npm config get min-release-age` and `npm config get before`)
  when stricter — a cutoff on the command line would override, and so
  relax, those settings, so scrubmac passes the stricter one itself: as
  `--before=<cutoff>`, or, when your npm config sets `min-release-age`
  (npm ≥ 11.10), as `--min-release-age=<days, rounded up>` — npm
  11.10–11.14 refuse a `--before` next to it ("--min-release-age cannot be
  provided when using --before"; fixed in 11.15.0). Those npms also report
  a `before` of their own making while `min-release-age` is set (now minus
  those days, cut to the second): it is not counted as yours — rounded up,
  it would make the gate a day stricter than asked for.
- `npm update -g <pkg>…` — when there is no cutoff (cooldown off, no npm
  setting of your own), for exactly those globals after a
  `npm view <pkg> versions dist-tags --json` registry check (not run when
  there are none). npm moves globals to the `latest` dist-tag, which can
  cross major versions.
- **With a cutoff:** for each of them, `npm view <pkg> time versions dist-tags --json`
  feeds scrubmac's resolver (`lib/registry.cjs`, run with node). It picks
  the newest release that is newer than the installed one, not past the
  `latest` tag, and published before the cutoff — a stable release, or a
  prerelease of the installed prerelease's own version (2.0.0-beta.1 may move
  to 2.0.0-beta.2, and to 2.0.0 as soon as that is old enough). Then
  `npm view "<pkg>@<v1> || <v2> … || <installed>" name version deprecated engines --json`
  rules out deprecated releases and ones whose `engines.node` excludes this
  node (checked with npm's own semver; not checked when that cannot be
  loaded), stepping down at most three times — when the installed release
  is deprecated too (the whole line is), the newest compatible one is taken
  anyway — and scrubmac runs `npm install -g <pkg>@<version>
  --before=<cutoff>` (or `--min-release-age=<days>`, see above): that holds
  the package's dependencies to the same cutoff. Packages whose newer releases are all too fresh are held, and
  ones whose releases old enough are all deprecated or need a newer Node.js
  are reported as not suitable — each counted in the summary. npm's own
  `min-release-age` (and a `--before` with `npm update -g`) are deliberately
  not used: they *downgrade* globals newer than the cutoff.
- Without node (needed to read npm's JSON) global updates are held.
- `npm cache verify` — garbage-collect and verify the cache
  (`npm config get cache` locates it for its size in `scrubmac status`).

### pnpm

`cleaners/31-pnpm.sh` — gate: `pnpm` — default: **on**

- Without a cooldown or a `minimumReleaseAge` of your own:
  `pnpm self-update` (standalone installs only — Corepack/Homebrew/npm/
  version-manager copies are left to their managers) and `pnpm update -g`,
  which updates global packages within the ranges they were saved with —
  only when there are some (`pnpm ls -g --depth=0 --json`, plus, on
  pnpm ≥ 11, what is left in pnpm 10's global project beside `pnpm root -g`:
  `pnpm update -g` is what migrates those): with none, and `pnpm setup`
  never run, pnpm fails for want of a global bin directory.
- **With one** (the stricter of `COOLDOWN_DAYS` and your own
  `minimumReleaseAge`, read with `pnpm config get minimumReleaseAge` — and
  at least pnpm 11's built-in day): global packages are listed with
  `pnpm ls -g --depth=0 --json` and resolved like npm's (`npm view` and
  scrubmac's resolver; deprecated or engine-incompatible picks are left as
  they are, since pnpm resolves ranges itself) **within the range each was
  saved with**, by that range's own bounds: `^` — the same major (for 0.x
  the same minor), `~1.2` — the same minor. Exact pins are never moved.
  Ranges a re-add would rewrite are never moved either, and are left to
  `pnpm update -g`: pnpm saves every re-added package as `^`/`~` of a
  version, which turns `*`, `latest`, `7.x` or `>=4.1.0 <4.2.0` into
  something else and narrows `~1`, `^0` and `^0.0`. A package that moves is
  re-added with its operator,
  `pnpm add -g <pkg>@^<version> --config.minimum-release-age=<minutes>` —
  pnpm records `^<version>` again, and its own age gate holds every
  dependency to the cutoff too.
  - pnpm ≥ 11 installs `pnpm add -g a,b` as **one install group**, and
    re-adding one member alone would uninstall the others, so a group is
    re-added whole (`pnpm add -g a@^x,b@^y …`), each member that stays
    where it is excluded from the gate by version
    (`--config.minimum-release-age-exclude=<name>@<installed>`, repeated;
    pnpm ≥ 10.19) — without that, a group-mate installed recently would
    fail the gate. An exact pin in the group is re-added as the same exact
    version. A group is not re-added at all while one of its members could
    not be looked up, is not a registry release (foreign or unknown to
    npm's registry), would land on an unsuitable release, or has a range a
    re-add would rewrite. A group-mate installed so recently that its own
    dependencies are fresh still fails the gate
    (`ERR_PNPM_NO_MATURE_MATCHING_VERSION`): that clears once they mature.
    Groups are found wherever pnpm keeps them (`<globalDir>/v11/<group>/`,
    also with a custom `globalDir`).
  - pnpm 10 keeps every global in one project with no `a,b` groups: one
    `pnpm add -g` per package, no excludes needed.
  - pnpm < 10.16 has no `minimumReleaseAge`, so dependencies could not be
    held back: global updates are held.
  - pnpm ≥ 11 no longer lists the packages still in pnpm 10's global
    project (`<globalDir>/5`), and only `pnpm update -g` migrates them —
    which also updates them, outside the cooldown — so a summary note asks
    you to run it once.
  - Globals that `pnpm outdated -g --format json` shows at their `latest`
    release are not looked up (its `wanted` follows the lockfile, so it
    cannot tell what a range allows).
  - Never touched: pnpm itself, linked/local installs (`link:`, `file:`,
    git) and aliases (`npm:`), nor their group-mates.
  - The self-update names the newest release old enough:
    `pnpm self-update <version>` (held, with a note, while every newer one
    is too fresh). pnpm before 9.13 ignores the version it is given and
    installs the newest release, so its self-update is held.
  - The lookups need node and npm; without them, updates and the
    self-update are held.
- pnpm's `minimumReleaseAge` is never passed to `pnpm update -g` or
  `pnpm self-update`: they fail outright (`ERR_PNPM_NO_MATURE_MATCHING_VERSION`)
  whenever an installed release is newer than the cutoff, and pnpm 10's
  self-update ignores it. Its `minimumReleaseAgeStrict=false` is not used
  either: pnpm then writes excludes into your global `pnpm-workspace.yaml`.
- Updates run from an empty scratch directory: inside a project that pins
  pnpm (`packageManager`), `pnpm self-update` would rewrite that pin
  instead, and pnpm reads project settings from the working directory.
- **No global bin directory on `PATH`**: pnpm then refuses global commands
  — pnpm 11 every one (even `pnpm ls -g`), pnpm 12 all but `ls`/`outdated`,
  pnpm 9/10 all when `PNPM_HOME` names that directory. That is pnpm from
  Homebrew or Corepack with no `pnpm setup`, or a scheduled run whose `PATH`
  was captured before it. `pnpm bin -g` tells; global packages are then
  skipped, not failed, with a note on the cure — `pnpm setup`, then
  `scrubmac schedule` again from a new shell, so scheduled runs get the new
  `PATH` — and a summary note when global packages evidently exist
  (`<data dir>/global`, the data dir being `$PNPM_HOME`, else
  `$XDG_DATA_HOME/pnpm`, else `~/Library/pnpm`; `~/.local/share/pnpm` is
  checked too). pnpm ≤ 10 without `PNPM_HOME` (a scheduled run never sees
  your shell's) has no global bin directory at all: `pnpm update -g` still
  works, but `pnpm add -g` fails, so cooldown re-adds are held with a note —
  `pnpm config set global-bin-dir "$PNPM_HOME"`, once, cures that. The
  self-update needs no global bin directory.
- `pnpm store prune` — drop unreferenced packages from the
  content-addressable store (`pnpm store path` locates it for its size in
  `scrubmac status`).
- `pnpm outdated -g` — `scrubmac status` report (exit 1 just means something
  is outdated).

### yarn

`cleaners/32-yarn.sh` — gate: `yarn` — default: **on**

Yarn 1 (classic): `yarn global upgrade -s` + `yarn cache clean`
(`yarn cache dir` locates the cache for its size in `scrubmac status`). Yarn
classic cannot filter by release age, so global upgrades are **held** while
the cooldown is on (the cache is still cleaned). Yarn 2+ (berry): caches are
per-project and `yarn global` no longer exists; the cleaner notes that and
does nothing.

### bun

`cleaners/33-bun.sh` — gate: `bun` — default: **on**

The cleaner works from a scratch directory holding an empty `{}`
`package.json`: Bun's cache commands refuse to run without one in the
current directory, and their `-g` forms (like `bun update -g`) fail until a
global package exists.

- Without a cooldown or a bunfig `install.minimumReleaseAge` of your own
  (in the bunfig files Bun reads for `-g` commands: the global one —
  `$XDG_CONFIG_HOME/.bunfig.toml` when `XDG_CONFIG_HOME` is set,
  `~/.bunfig.toml` then ignored, else `~/.bunfig.toml` — and `bunfig.toml`
  in Bun's global directory; integers, floats and inline tables all count,
  also inline tables spread over several lines, and a `#` inside a quoted
  string starts no comment):
  `bun upgrade` —
  standalone installs only (it replaces the running binary in place, so
  Homebrew/npm/version-manager copies are left to their managers) — and
  `bun update -g`, within the saved ranges. No global packages: nothing to
  update, and no failure.
- **With one** (the stricter of the two; passing a smaller value on the
  command line would relax yours): the global packages are read from Bun's
  global directory (named by the `bun pm ls -g` header: its `package.json`
  and each package's installed version), each is resolved like npm's
  (`npm view` and scrubmac's resolver) within what its saved range allows,
  by that range's own bounds (`^`: the same major, for 0.x the same minor;
  `~1.2`: the same minor), and updated with
  `bun update -g <pkg>@<version> --minimum-release-age <seconds>` — the
  update keeps the range's operator, and the age gate holds the package's
  dependencies to the cutoff too (Bun ≥ 1.3; older Bun holds global
  updates). Bun 1.3 re-checks every global's range against the gate and
  fails ("blocked by minimum-release-age") while one of them has no release
  old enough: the remaining updates are then held with a note, not failed
  (Bun ≥ 1.4 checks only the package being updated). Exact pins
  (`bun update -g` leaves those too), linked/local installs and aliases are
  never touched, nor ranges such an update would rewrite: Bun turns `*`,
  `latest` and `~2` into an exact pin and narrows `^0`/`^0.0` — those are
  left to `bun update -g`. A package Bun's isolated linker
  (`install.linker = "isolated"`) links in from `node_modules/.bun/` is a
  registry install like any other. Globals `bun outdated -g` shows at their
  latest release are not looked up. Bun's `--minimum-release-age` is never given to a
  plain `bun update -g`: that fails whenever an installed release is newer
  than the cutoff, and downgrades packages when a range allows it. The
  lookups need node and npm; without them global updates are held.
- `bun upgrade` cannot be told a version: it installs the newest release of
  the GitHub feed it reads itself
  (`api.github.com/repos/Jarred-Sumner/bun-releases-for-updater`, read with
  `curl`). Under the cooldown it runs only when that release is old enough
  — held, with a note, while it is too fresh, when the feed cannot be read,
  on a canary build, or with `BUN_CANARY=1` set (either way it would move to
  the newest canary). Like Bun, the check sends `GITHUB_TOKEN` (or
  `GITHUB_ACCESS_TOKEN`) when set, lifting GitHub's anonymous rate limit —
  passed to curl on stdin (`curl -K -`), never on its command line.
- `bun pm cache rm` — clear the global package cache (from the scratch
  directory; `bun pm cache rm -g` if none could be made, which needs a
  global package); `bun pm cache` (or `bun pm cache -g`) locates it for its
  size in `scrubmac status`.

### deno

`cleaners/34-deno.sh` — gate: `deno` — default: **on**

`deno upgrade` for standalone installs only (it replaces the running
executable; Homebrew/npm copies are updated by those cleaners). The module
cache is left alone: `deno clean` would wipe all of it.

### python

`cleaners/40-python.sh` — gate: `uv pipx python3` — default: **on**

| Runs | When / why |
|---|---|
| `uv self update` | only the uv that uv's standalone installer manages: its install receipt must name this uv's directory — the first `uv-receipt.json` that exists decides, looked up the way uv does (`$AXOUPDATER_CONFIG_PATH`, else `$XDG_CONFIG_HOME/uv` then `~/.config/uv`). uv from pip, cargo, conda, Homebrew or a version manager refuses (exit 2) — those get a note instead |
| `uv tool upgrade --all` | upgrade uv-managed tools |
| `uv tool upgrade --all --exclude-newer "N days"` | under the cooldown (uv ≥ 0.11.4 keeps the span relative in tool receipts; older uv gets an absolute RFC 3339 date). Your own `exclude-newer` (`UV_EXCLUDE_NEWER`, or `uv.toml`: `UV_CONFIG_FILE`, `${XDG_CONFIG_HOME:-~/.config}/uv/uv.toml`, `/etc/uv/uv.toml`) is passed instead, as written, when it reaches further back — the flag overrides both your settings and the tool receipts. Read as uv reads it: a date — and a date and time *without* an offset, which uv takes as that date — is the *end* of that day in local time; a timestamp's offset counts (`Z`, `±hh:mm`, `±hhmm`, `±hh`; a space for the `T`, lowercase `t`/`z` and missing seconds are fine); spans may say `ago`. When its value cannot be read (an ISO 8601 basic-format timestamp, say), tool upgrades are held, with a note and a summary note: passing either value could relax the other |
| `uv tool upgrade <tool> --exclude-newer false` | cooldown off, uv ≥ 0.11.24, before the upgrade above: for each tool whose receipt still carries a cutoff from an earlier cooldown (uv remembers it, so plain upgrades keep honoring it) *and* that the cutoff is holding back — `uv tool list --outdated --exclude-newer false` names those; uv rewrites a receipt only when its tool upgrades. Not when your own uv settings set `exclude-newer`. Older uv: a summary note says how many tools stay held back |
| `pipx upgrade-all` | upgrade pipx-managed packages |
| `pipx upgrade-all --cooldown N` | under the cooldown (pipx ≥ 1.16; older pipx holds its upgrades) — or your `PIPX_COOLDOWN` when larger |
| `pipx upgrade-all --cooldown 0` | cooldown off, pipx ≥ 1.16: pipx remembers an earlier `--cooldown` per package, and 0 is its opt-out (plain `pipx upgrade-all` when `PIPX_COOLDOWN` is set) |
| `uv cache prune` | with `UV_LOCK_TIMEOUT=15` (uv ≥ 0.9.16): a cache held by running uv/uvx processes (e.g. MCP servers) is skipped with a note instead of waited on — and never `--force`d, which would delete environments those processes run from. Older uv: skipped up front when a uv process or anything executing from the cache is running |
| `python3 -m pip cache purge` *(advisory)* | exits 1 when pip's cache is disabled |
| `uv tool list --outdated` | `scrubmac status` report (uv ≥ 0.10.10) |
| `uv cache dir --color never`, `python3 -m pip cache dir` | where the caches are, for their sizes in `scrubmac status` (and `--measure`) |

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
  shows (`-n`: it asks otherwise). `poetry config cache-dir` locates the
  caches for their size in `scrubmac status`.

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
prompt — an older Codex from the binary-only Homebrew cask is upgraded by
name instead (`brew upgrade --cask codex`). npm installs are left to the npm
cleaner (which applies the cooldown), and copies a version manager (mise,
asdf, …), pipx or uv owns to that manager — `codex update` would overwrite
them. Never touches `~/.codex`.

### gemini

`cleaners/47-gemini.sh` — gate: `gemini` — default: **on**

Gemini CLI has no self-update command — `gemini update` would start a chat —
so nothing is ever run: npm installs are updated by the npm cleaner, and
Homebrew installs get a note that the `gemini-cli` formula is deprecated
and no longer follows releases (reinstall with npm).

### gh

`cleaners/48-gh.sh` — gate: `gh` — default: **on**

`gh extension upgrade --all` — exits 0 when there is nothing to upgrade, so a
non-zero exit is a real failure. Extension commands need a logged-in gh:
`gh extension list` exits 4 without one, and then the cleaner is skipped,
with the reason — as it is when that list is empty. (`gh auth status` is not
the test: it exits 1 when *any* account on any host has a problem, such as
an inactive account or an Enterprise host off the VPN.) gh itself is usually
Homebrew-managed. `gh extension list` is the `scrubmac status` report (when
logged in).

### cursor

`cleaners/49-cursor.sh` — gate: `cursor-agent` — default: **on**

The Cursor CLI agent (installed as `agent`, with `cursor-agent` kept as an
alias): `cursor-agent update` for standalone installs; the binary-only
Homebrew cask is upgraded by name (`brew upgrade --cask <token>`, with the
cask token read from where the binary lives). Never touches `~/.cursor`.

### rustup

`cleaners/50-rustup.sh` — gate: `rustup` — default: **on**

`rustup update` — toolchains, plus rustup itself unless a package manager
owns it (Homebrew's rustup is built without self-update and says so).
`rustup check` is the `scrubmac status` report (rustup ≥ 1.29 exits 100 when
updates are available — news, not a failure).

### composer

`cleaners/51-composer.sh` — gate: `composer` — default: **on**

`composer global update --no-interaction` + `composer clear-cache`
(`composer config --global cache-dir` locates the cache for its size in
`scrubmac status`). The
global update (and the `composer global outdated` status report) only runs
when the global Composer home has a `composer.json` — without global
packages those commands just error out.

### go

`cleaners/52-go.sh` — gate: `go` — default: **off**

`go clean -cache` clears the build cache (`go env GOCACHE` locates it for its
size in `scrubmac status`). Opt-in, because Go already deletes
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
(`sqlite3 -init /dev/null -batch -list -noheader -readonly -cmd '.timeout 5000'`
— `-init /dev/null` so a `.mode` in your `sqliterc` cannot change how the
paths print); a database that cannot be read
(pre-commit holding a lock past the 5-second busy timeout) skips gc too,
while a store that has never recorded a config (no `configs` table) does
not. Without sqlite3, any unreadable protected folder blocks gc.

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
(repository clones, registry downloads, manifests). It works on the package
in the current directory — it writes a `.build` there, and SwiftPM before
6.3 (Xcode 16's Swift 6.1/6.2) refuses to run without a `Package.swift`
("Could not find Package.swift in this directory or any of its parent
directories") — so it runs from a throwaway directory holding a placeholder
`Package.swift`, never inside or under a real package.

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
