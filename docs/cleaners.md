# Cleaner reference

The single source of truth for what each cleaner does. CI fails if this file
and `cleaners/` drift apart (`make docs-check`).

Shared contract: every cleaner is presence-gated (missing tool → skip, exit
75), non-interactive, sudo-free, and routes every mutating command through the
dry-run-aware `run` wrapper — `scrubmac --dry-run` previews everything.
Advisory commands (`try …`) may exit non-zero without failing the cleaner.
Disable any cleaner with `scrubmac disable <name>`.

### homebrew

`cleaners/10-homebrew.sh` — gate: `brew`

| Runs | Why |
|---|---|
| `brew update` | refresh the formulae index |
| `brew upgrade` | upgrade formulae **and** casks (modern brew handles both) |
| `brew autoremove` *(advisory)* | drop dependencies nothing needs anymore |
| `brew doctor` *(advisory)* | health report — non-zero just means it has opinions |
| `brew missing` *(advisory)* | report broken dependency links |
| `brew cleanup -s --prune=all` | scrub caches and old versions |

### mas

`cleaners/20-mas.sh` — gate: `mas`

Reports outdated Mac App Store apps (`mas outdated`, advisory), then
`mas upgrade`.

### npm

`cleaners/30-npm.sh` — gate: `npm`

- `npm install -g npm@latest` — **only** when npm is a standalone install;
  brew/npm-managed copies are updated by their manager (D4)
- `npm outdated -g` *(advisory — exits 1 whenever anything is outdated)*
- `npm update -g` — **held with a printed advisory while a cooldown is set**:
  npm's `--before` flag would *downgrade* globals installed more recently than
  the cutoff (verified), so scrubmac refuses to automate it
- `npm cache verify` — garbage-collect and verify the cache

### pnpm

`cleaners/31-pnpm.sh` — gate: `pnpm`

`pnpm store prune` — drop unreferenced packages from the content-addressable
store.

### yarn

`cleaners/32-yarn.sh` — gate: `yarn`

Yarn 1 (classic): `yarn global upgrade -s` + `yarn cache clean`.
Yarn 2+ (berry): caches are per-project; the cleaner notes that and does
nothing.

### bun

`cleaners/33-bun.sh` — gate: `bun`

`bun pm cache rm` — clear the global package cache.

### python

`cleaners/40-python.sh` — gate: any of `uv`, `pipx`, `python3`

- uv: `uv self update` (standalone installs only), `uv tool upgrade --all`
  (with `--exclude-newer <cutoff>` when a cooldown is set — the native
  mechanical cooldown), `uv cache prune`
- pipx: `pipx upgrade-all` *(advisory)*
- pip: `python3 -m pip cache purge` *(advisory, only when pip exists)*

### conda

`cleaners/41-conda.sh` — gate: `conda`

`conda update --all -y` + `conda clean --all -y`. The `-y` flags are
regression-pinned: without them conda prompts and a cron run hangs forever.

### claude

`cleaners/45-claude.sh` — gate: `claude`

Claude Code. Standalone installs: `claude update`. npm/brew-managed installs
are updated by those cleaners (the note tells you which). **Never touches
`~/.claude`** — sessions, memory, and auth live there.

### codex

`cleaners/46-codex.sh` — gate: `codex`

OpenAI Codex CLI. Standalone installs: `codex update`. Managed installs defer
to npm/homebrew. **Never touches `~/.codex`.**

### gemini

`cleaners/47-gemini.sh` — gate: `gemini`

Gemini CLI is almost always npm- or brew-managed — those cleaners update it.
A standalone install gets a pointer to its own installer rather than a
guessed command.

### gh

`cleaners/48-gh.sh` — gate: `gh`

`gh extension upgrade --all` *(advisory)* — upgrades every gh extension,
including GitHub Copilot's. gh itself is usually brew-managed. The npm
`@github/copilot` CLI is covered by the npm cleaner.

### cursor

`cleaners/49-cursor.sh` — gate: `cursor-agent`

Cursor's CLI agent, usually a standalone (curl) install: `cursor-agent
update`. **Never touches `~/.cursor`.**

### rustup

`cleaners/50-rustup.sh` — gate: `rustup`

`rustup update` — toolchains, and rustup itself where appropriate (rustup
handles the managed-install distinction internally).

### composer

`cleaners/51-composer.sh` — gate: `composer`

`composer global update --no-interaction` + `composer clear-cache`.

### go

`cleaners/52-go.sh` — gate: `go`

`go clean -cache` — the build cache only. The module cache is deliberately
left alone: purging it forces a re-download of every dependency of every
project.

### mise

`cleaners/55-mise.sh` — gate: `mise`

`mise self-update -y` (standalone installs only; `-y` because it prompts
otherwise), `mise outdated` *(advisory report)*, `mise cache clear`.
`mise upgrade` is deliberately **not** run — bumping pinned tool versions is
a per-project decision.

### docker

`cleaners/60-docker.sh` — gate: `docker` **· disabled by default**

Skips (75) when the daemon is not running. Otherwise: `docker system df`
*(advisory)*, `docker builder prune -f`, `docker image prune -f` (dangling
images only). **Never** containers, volumes, or tagged images. Opt in with
`scrubmac enable docker`.

### xcode

`cleaners/70-xcode.sh` — gate: `xcodebuild` **· disabled by default**

`xcrun simctl delete unavailable` *(advisory)* — removes simulators for
runtimes no longer installed — then deletes DerivedData subdirectories
untouched for `DERIVEDDATA_AGE_DAYS` (default 30). DerivedData is a
regenerable build cache; the age gate keeps active projects' builds warm.
Opt in with `scrubmac enable xcode`.
