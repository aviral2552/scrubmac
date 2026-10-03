#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# Per-cleaner tests against PATH stubs: exact argv sequences, skip-when-absent,
# modes (update/clean/status/dry-run), offline behavior, install-kind
# deferral (D4), the supply-chain cooldown (S4), and the regression pins
# (F4–F8, D3). Commands and flags are validated against each tool's official
# documentation (see docs/cleaners.md); tests pin that exact usage.

load helpers/setup

setup() {
  setup_sandbox
  export CMM_COOLDOWN_DAYS=0 # most sequences are pinned without the cooldown
  export CMM_INTERACTIVE=0
}
teardown() { teardown_sandbox; }

run_cleaner() {
  local c="$1"
  shift
  CMM_LIB="$CMM_LIB_PATH" "$REPO_ROOT/cleaners/$c" "$@"
}

# A brew prefix with TOOL as a plain (formula-style) binary.
brew_formula_tool() {
  local pfx="$SANDBOX/brewpfx"
  mkdir -p "$pfx/bin"
  printf '#!/bin/sh\nprintf "%%s %%s\\n" %s "$*" >>"$CALL_LOG"\n' "$1" >"$pfx/bin/$1"
  chmod 755 "$pfx/bin/$1"
  export PATH="$pfx/bin:$PATH" CMM_BREW_PREFIX="$pfx"
}

# A brew prefix with TOOL installed from cask TOKEN (bin -> Caskroom).
brew_cask_tool() {
  local tool="$1" token="$2" pfx="$SANDBOX/brewpfx"
  mkdir -p "$pfx/bin" "$pfx/Caskroom/$token/1.0.0/bin"
  printf '#!/bin/sh\nprintf "%%s %%s\\n" %s "$*" >>"$CALL_LOG"\n' "$tool" >"$pfx/Caskroom/$token/1.0.0/bin/$tool"
  chmod 755 "$pfx/Caskroom/$token/1.0.0/bin/$tool"
  ln -s "../Caskroom/$token/1.0.0/bin/$tool" "$pfx/bin/$tool"
  make_stub brew
  export PATH="$pfx/bin:$PATH" CMM_BREW_PREFIX="$pfx"
}

# A brew prefix with TOOL as an npm global (bin -> lib/node_modules/…).
npm_global_tool() {
  local tool="$1" pkg="$2" pfx="$SANDBOX/brewpfx"
  mkdir -p "$pfx/bin" "$pfx/lib/node_modules/$pkg"
  printf '#!/bin/sh\nprintf "%%s %%s\\n" %s "$*" >>"$CALL_LOG"\n' "$tool" >"$pfx/lib/node_modules/$pkg/cli.js"
  chmod 755 "$pfx/lib/node_modules/$pkg/cli.js"
  ln -s "../lib/node_modules/$pkg/cli.js" "$pfx/bin/$tool"
  export PATH="$pfx/bin:$PATH" CMM_BREW_PREFIX="$pfx"
}

# ---------- homebrew ----------

@test "homebrew: unattended run upgrades formulae, not casks, then cleans up" {
  make_stub brew
  run run_cleaner 10-homebrew.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
brew update
brew upgrade --formula
brew doctor
brew missing
brew autoremove
brew cleanup -s --prune=all
EOF
  [[ "$output" == *"casks not upgraded: unattended run"* ]]
}

@test "homebrew: casks are upgraded when a person is watching, or with APP_UPDATES=always" {
  make_stub brew
  CMM_INTERACTIVE=1 run run_cleaner 10-homebrew.sh
  [ "$status" -eq 0 ]
  grep -qx 'brew upgrade --cask' "$CALL_LOG"
  : >"$CALL_LOG"
  CMM_APP_UPDATES=always run run_cleaner 10-homebrew.sh
  grep -qx 'brew upgrade --cask' "$CALL_LOG"
  : >"$CALL_LOG"
  CMM_INTERACTIVE=1 CMM_APP_UPDATES=never run run_cleaner 10-homebrew.sh
  refute grep -q 'upgrade --cask' "$CALL_LOG"
}

@test "homebrew: never waits on Homebrew's confirmation prompt; no auto-update after the explicit one" {
  make_stub_script brew <<'EOF'
echo "env NO_ASK=${HOMEBREW_NO_ASK:-} NO_AUTO=${HOMEBREW_NO_AUTO_UPDATE:-}" >>"$CALL_LOG"
EOF
  run run_cleaner 10-homebrew.sh
  [ "$status" -eq 0 ]
  grep -q '^env NO_ASK=1 NO_AUTO=$' "$CALL_LOG"  # brew update itself may auto-update
  grep -q '^env NO_ASK=1 NO_AUTO=1$' "$CALL_LOG" # everything after it must not
}

@test "homebrew: a failed upgrade still cleans up, and fails the cleaner" {
  make_stub_script brew <<'EOF'
[ "$1 $2" = "upgrade --formula" ] && exit 1
exit 0
EOF
  run run_cleaner 10-homebrew.sh
  [ "$status" -eq 1 ]
  grep -qx 'brew cleanup -s --prune=all' "$CALL_LOG"
}

@test "homebrew: advisory doctor/missing failures do not fail the cleaner" {
  make_stub_script brew <<'EOF'
case "$1" in doctor | missing) exit 1 ;; esac
exit 0
EOF
  run run_cleaner 10-homebrew.sh
  [ "$status" -eq 0 ]
  grep -qx 'brew cleanup -s --prune=all' "$CALL_LOG"
}

@test "homebrew: HOMEBREW_DOCTOR=0 skips the health checks" {
  make_stub brew
  CMM_HOMEBREW_DOCTOR=0 run run_cleaner 10-homebrew.sh
  [ "$status" -eq 0 ]
  refute grep -q 'brew doctor' "$CALL_LOG"
  refute grep -q 'brew missing' "$CALL_LOG"
}

@test "homebrew: offline still cleans up; update-only and clean-only split the work" {
  make_stub brew
  CMM_OFFLINE=1 run run_cleaner 10-homebrew.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
brew autoremove
brew cleanup -s --prune=all
EOF
  : >"$CALL_LOG"
  CMM_MODE=update run run_cleaner 10-homebrew.sh
  refute grep -q cleanup "$CALL_LOG"
  grep -qx 'brew upgrade --formula' "$CALL_LOG"
  : >"$CALL_LOG"
  CMM_MODE=clean run run_cleaner 10-homebrew.sh
  refute grep -q upgrade "$CALL_LOG"
  grep -qx 'brew cleanup -s --prune=all' "$CALL_LOG"
}

@test "homebrew: dry-run executes only read-only previews (upgrade previews never auto-update)" {
  # one log line per call: argv plus the auto-update setting it saw
  printf '#!/bin/sh\necho "brew $* [auto=${HOMEBREW_NO_AUTO_UPDATE:-}]" >>"$CALL_LOG"\n' >"$STUB_BIN/brew"
  chmod 755 "$STUB_BIN/brew"
  CMM_DRY_RUN=1 run run_cleaner 10-homebrew.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
brew upgrade --formula --dry-run [auto=1]
brew cleanup -s --prune=all --dry-run [auto=]
EOF
  [[ "$output" == *"+ brew upgrade --formula"* ]]
}

@test "homebrew: status reports outdated packages and the cache size, changes nothing" {
  mkdir -p "$SANDBOX/brewcache"
  make_stub_script brew <<EOF
[ "\$1" = "--cache" ] && echo "$SANDBOX/brewcache"
exit 0
EOF
  CMM_MODE=status run run_cleaner 10-homebrew.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
brew --cache
brew outdated
EOF
  [[ "$output" == *"cache $SANDBOX/brewcache"* ]]
}

# ---------- mas ----------

@test "mas: reports pending App Store updates and never runs mas update (it needs sudo)" {
  make_stub_script mas <<'EOF'
[ "$1" = outdated ] && printf '497799835 Xcode (16.0 -> 16.1)\n409183694 Keynote (14.1 -> 14.2)\n'
exit 0
EOF
  run run_cleaner 20-mas.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
mas outdated
EOF
  [[ "$output" == *"Keynote"* ]]
  [[ "$output" == *"run 'mas update' yourself"* ]]
}

@test "mas: nothing pending; offline skips" {
  make_stub mas
  run run_cleaner 20-mas.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"no App Store updates pending"* ]]
  CMM_OFFLINE=1 run run_cleaner 20-mas.sh
  [ "$status" -eq 75 ]
}

# ---------- npm ----------

@test "npm: standalone install self-updates, updates globals, verifies cache (F5: no --depth)" {
  make_stub npm
  run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
npm install -g npm@latest
npm outdated -g
npm update -g
npm cache verify
EOF
  refute grep -q -- --depth "$CALL_LOG"
}

@test "npm: brew-managed npm skips self-update (F5, D4)" {
  brew_formula_tool npm
  run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *brew-managed* ]]
  refute grep -q '^npm install -g npm@latest$' "$CALL_LOG"
  grep -q '^npm update -g$' "$CALL_LOG"
}

@test "npm: outdated exiting 1 is tolerated (F1 root cause)" {
  make_stub_script npm <<'EOF'
case "$1" in outdated) exit 1 ;; esac
exit 0
EOF
  run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  grep -q '^npm cache verify$' "$CALL_LOG"
}

# Registry fixture for the cooldown resolver: "fresh" has only releases from
# yesterday; "seasoned" has an old 2.1.0 and a fresh 2.2.0; the npm 12 shape
# (array-wrapped) is used for "seasoned" on purpose.
cooldown_fixture() {
  [ -n "$REAL_NODE" ] || skip "node is required for the cooldown resolver tests"
  ln -s "$REAL_NODE" "$STUB_BIN/node"
  local old new
  old="$(date -u -v-60d '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null || date -u -d '60 days ago' '+%Y-%m-%dT%H:%M:%S.000Z')"
  new="$(date -u -v-1d '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null || date -u -d '1 day ago' '+%Y-%m-%dT%H:%M:%S.000Z')"
  brew_formula_tool npm # bundled npm: no self-update in these tests
  cat >"$SANDBOX/brewpfx/bin/npm" <<EOF
#!/bin/sh
printf '%s %s\n' npm "\$*" >>"\$CALL_LOG"
case "\$1 \$2" in
  "outdated -g")
    [ "\$3" = --json ] && printf '%s\n' '{"seasoned":{"current":"2.0.0","wanted":"2.2.0","latest":"2.2.0","dependent":"global","location":"/x"},"@scope/fresh":{"current":"1.0.0","wanted":"1.1.0","latest":"1.1.0","dependent":"global","location":"/y"}}'
    exit 1 ;;
  "view seasoned")
    printf '%s\n' '[{"time":{"created":"$old","2.0.0":"$old","2.1.0":"$old","2.2.0":"$new","3.0.0-beta.1":"$old"},"versions":["2.0.0","2.1.0","2.2.0","3.0.0-beta.1"],"dist-tags":{"latest":"2.2.0"}}]' ;;
  "view @scope/fresh")
    printf '%s\n' '{"time":{"1.0.0":"$old","1.1.0":"$new"},"versions":["1.0.0","1.1.0"],"dist-tags":{"latest":"1.1.0"}}' ;;
esac
exit 0
EOF
}

@test "npm: cooldown installs the newest release old enough, holds fresher ones (S4)" {
  cooldown_fixture
  CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  grep -qx 'npm install -g seasoned@2.1.0' "$CALL_LOG"      # 2.2.0 is too fresh; beta never
  refute grep -q 'npm install -g @scope/fresh' "$CALL_LOG"        # only fresh releases: held
  [[ "$output" == *"@scope/fresh 1.0.0: every newer release is under 7 days old"* ]]
  refute grep -q '^npm update' "$CALL_LOG"                        # never the downgrade-prone path
  refute grep -Eq -- '--before|min-release-age' "$CALL_LOG"
  grep -qx 'npm cache verify' "$CALL_LOG"
}

@test "npm: cooldown never downgrades a package newer than every eligible release" {
  cooldown_fixture
  sed -i.bak 's/"current":"2.0.0"/"current":"2.1.5"/' "$SANDBOX/brewpfx/bin/npm"
  CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  refute grep -q 'npm install -g seasoned' "$CALL_LOG"
}

@test "npm: cooldown under dry-run prints the exact versions it would install" {
  cooldown_fixture
  CMM_COOLDOWN_DAYS=7 CMM_DRY_RUN=1 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ npm install -g seasoned@2.1.0"* ]]
  refute grep -q 'npm install' "$CALL_LOG"
}

@test "npm: an npm error from 'outdated --json' fails the cleaner instead of passing silently" {
  [ -n "$REAL_NODE" ] || skip "node is required"
  ln -s "$REAL_NODE" "$STUB_BIN/node"
  brew_formula_tool npm
  cat >"$SANDBOX/brewpfx/bin/npm" <<'EOF'
#!/bin/sh
printf '%s %s\n' npm "$*" >>"$CALL_LOG"
[ "$1" = outdated ] && { echo '{"error":{"code":"ENOTFOUND","summary":"offline"}}'; exit 1; }
exit 0
EOF
  CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 1 ]
  grep -qx 'npm cache verify' "$CALL_LOG" # cleanup still happened
}

@test "npm: cooldown without node holds updates (never falls back to npm update -g)" {
  brew_formula_tool npm
  command -v node >/dev/null && skip "node is installed in a system directory on this host"
  CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"node not found"* ]]
  refute grep -q '^npm update' "$CALL_LOG"
}

# ---------- pnpm / yarn / bun / deno ----------

@test "pnpm: standalone self-update, global update, store prune" {
  make_stub pnpm
  run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
pnpm self-update
pnpm update -g
pnpm store prune
EOF
}

@test "pnpm: the cooldown becomes pnpm's minimumReleaseAge (minutes) (S4)" {
  make_stub pnpm
  CMM_COOLDOWN_DAYS=7 run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  grep -qx 'pnpm self-update --config.minimum-release-age=10080' "$CALL_LOG"
  grep -qx 'pnpm update -g --config.minimum-release-age=10080' "$CALL_LOG"
}

@test "pnpm: a brew-managed pnpm is not self-updated (D4)" {
  brew_formula_tool pnpm
  run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  refute grep -q 'self-update' "$CALL_LOG"
  grep -qx 'pnpm update -g' "$CALL_LOG"
}

@test "yarn v1: global upgrade and cache clean (F6)" {
  make_stub yarn 0 "1.22.22"
  run run_cleaner 32-yarn.sh
  [ "$status" -eq 0 ]
  grep -q '^yarn global upgrade -s$' "$CALL_LOG"
  grep -q '^yarn cache clean$' "$CALL_LOG"
}

@test "yarn v1: the cooldown holds global upgrades (no age filter exists) (S4)" {
  make_stub yarn 0 "1.22.22"
  CMM_COOLDOWN_DAYS=7 run run_cleaner 32-yarn.sh
  [ "$status" -eq 0 ]
  refute grep -q '^yarn global' "$CALL_LOG"
  grep -q '^yarn cache clean$' "$CALL_LOG"
  [[ "$output" == *"global upgrades are held"* ]]
}

@test "yarn berry: no global commands are attempted (F6)" {
  make_stub yarn 0 "4.5.1"
  run run_cleaner 32-yarn.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *berry* ]]
  refute grep -q '^yarn global' "$CALL_LOG"
  refute grep -q '^yarn cache clean$' "$CALL_LOG"
}

@test "bun: standalone upgrade, global update, cache rm" {
  make_stub bun 0 "1.4.2"
  run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
bun upgrade
bun update -g
bun pm cache rm
EOF
}

@test "bun: the cooldown becomes --minimum-release-age (seconds) on Bun >= 1.3, held before" {
  make_stub bun 0 "1.4.2"
  CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh
  grep -qx 'bun update -g --minimum-release-age 604800' "$CALL_LOG"
  : >"$CALL_LOG"
  make_stub bun 0 "1.2.21"
  CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  refute grep -q 'bun update' "$CALL_LOG"
  [[ "$output" == *"predates --minimum-release-age"* ]]
}

@test "bun and deno: managed installs are never self-upgraded in place (D4)" {
  brew_formula_tool bun
  brew_formula_tool deno
  run run_cleaner 33-bun.sh
  refute grep -q '^bun upgrade' "$CALL_LOG"
  run run_cleaner 34-deno.sh
  [ "$status" -eq 0 ]
  refute grep -q '^deno upgrade' "$CALL_LOG"
  [[ "$output" == *Homebrew-managed* ]]
}

@test "deno: standalone runs deno upgrade; clean-only skips" {
  make_stub deno
  run run_cleaner 34-deno.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
deno upgrade
EOF
  CMM_MODE=clean run run_cleaner 34-deno.sh
  [ "$status" -eq 75 ]
}

# ---------- AI tools ----------

@test "claude: standalone install runs 'claude update'; nothing is ever deleted (D3)" {
  make_stub claude
  run run_cleaner 45-claude.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
claude update
EOF
}

@test "claude: a brew formula-style install is deferred to the homebrew cleaner (D4)" {
  brew_formula_tool claude
  run run_cleaner 45-claude.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *Homebrew-managed* ]]
  [ ! -s "$CALL_LOG" ]
}

@test "claude: a binary-only Homebrew cask is upgraded by name (claude update would no-op)" {
  brew_cask_tool claude claude-code
  run run_cleaner 45-claude.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
brew upgrade --cask claude-code
EOF
}

@test "claude: npm-managed install (under brew prefix!) is deferred to the npm cleaner (D4 ordering)" {
  npm_global_tool claude @anthropic-ai/claude-code
  run run_cleaner 45-claude.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *npm-managed* ]]
  [ ! -s "$CALL_LOG" ]
}

@test "codex: 'codex update' only when the CLI lists it; old releases are never fed 'update'" {
  make_stub_script codex <<'EOF'
[ "$1" = --help ] && printf 'Commands:\n  exec      Run non-interactively\n  update    Update Codex to the latest version\n'
exit 0
EOF
  run run_cleaner 46-codex.sh
  [ "$status" -eq 0 ]
  grep -qx 'codex update' "$CALL_LOG"
  : >"$CALL_LOG"
  make_stub_script codex <<'EOF'
[ "$1" = --help ] && printf 'Commands:\n  exec      Run non-interactively\n'
exit 0
EOF
  run run_cleaner 46-codex.sh
  [ "$status" -eq 0 ]
  refute grep -q 'codex update' "$CALL_LOG"
  [[ "$output" == *"predates 'codex update'"* ]]
}

@test "codex: npm installs are left to the npm cleaner (cooldown applies there)" {
  npm_global_tool codex @openai/codex
  run run_cleaner 46-codex.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *npm-managed* ]]
  [ ! -s "$CALL_LOG" ]
}

@test "copilot: standalone self-updates; cask installs upgrade the cask" {
  make_stub_script copilot <<'EOF'
[ "$1" = --help ] && printf 'Commands:\n  update    Update the CLI\n'
exit 0
EOF
  run run_cleaner 44-copilot.sh
  [ "$status" -eq 0 ]
  grep -qx 'copilot update' "$CALL_LOG"
  rm -f "$STUB_BIN/copilot"
  : >"$CALL_LOG"
  brew_cask_tool copilot copilot-cli
  run run_cleaner 44-copilot.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
brew upgrade --cask copilot-cli
EOF
}

@test "gemini: no command is ever run (no self-update exists)" {
  make_stub gemini
  run run_cleaner 47-gemini.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"no self-update command"* ]]
  [ ! -s "$CALL_LOG" ]
  rm -f "$STUB_BIN/gemini"
  brew_formula_tool gemini
  run run_cleaner 47-gemini.sh
  [[ "$output" == *"deprecated"* ]]
  [ ! -s "$CALL_LOG" ]
}

@test "gh: upgrades all extensions; a real failure fails the cleaner" {
  make_stub gh
  run run_cleaner 48-gh.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
gh extension upgrade --all
EOF
  make_stub gh 1
  run run_cleaner 48-gh.sh
  [ "$status" -eq 1 ]
}

@test "cursor: standalone runs 'cursor-agent update'; cask installs upgrade the cask" {
  make_stub cursor-agent
  run run_cleaner 49-cursor.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
cursor-agent update
EOF
  rm -f "$STUB_BIN/cursor-agent"
  : >"$CALL_LOG"
  brew_cask_tool cursor-agent cursor-cli
  run run_cleaner 49-cursor.sh
  grep -qx 'brew upgrade --cask cursor-cli' "$CALL_LOG"
}

# ---------- languages ----------

@test "rustup: update; status runs rustup check" {
  make_stub rustup
  run run_cleaner 50-rustup.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
rustup update
EOF
  : >"$CALL_LOG"
  CMM_MODE=status run run_cleaner 50-rustup.sh
  diff <(calls) - <<'EOF'
rustup check
EOF
}

composer_stub() { # composer_stub — global home in the sandbox
  mkdir -p "$SANDBOX/composer-home"
  cat >"$STUB_BIN/composer" <<EOF
#!/bin/sh
printf '%s %s\n' composer "\$*" >>"\$CALL_LOG"
[ "\$1 \$2 \$3" = "config --global home" ] && echo "$SANDBOX/composer-home"
exit 0
EOF
  chmod 755 "$STUB_BIN/composer"
}

@test "composer: non-interactive global update and cache clear; clean-only clears only" {
  composer_stub
  printf '{"require":{}}\n' >"$SANDBOX/composer-home/composer.json"
  run run_cleaner 51-composer.sh
  [ "$status" -eq 0 ]
  diff <(grep -v 'config --global home' "$CALL_LOG") - <<'EOF'
composer global update --no-interaction
composer clear-cache
EOF
  : >"$CALL_LOG"
  CMM_MODE=clean run run_cleaner 51-composer.sh
  diff <(grep -v 'config --global home' "$CALL_LOG") - <<'EOF'
composer clear-cache
EOF
}

@test "composer: without global packages, no 'global update' is attempted (it would error)" {
  composer_stub
  run run_cleaner 51-composer.sh
  [ "$status" -eq 0 ]
  refute grep -q 'global update' "$CALL_LOG"
  grep -qx 'composer clear-cache' "$CALL_LOG"
  [[ "$output" == *"no global Composer packages"* ]]
}

@test "go: build cache only — never the module cache; opt-in by default" {
  make_stub go
  run run_cleaner 52-go.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
go clean -cache
EOF
  refute grep -q -- -modcache "$CALL_LOG"
  grep -qx '# default: off' "$REPO_ROOT/cleaners/52-go.sh"
  CMM_MODE=update run run_cleaner 52-go.sh
  [ "$status" -eq 75 ]
}

@test "cargo: upgrades cargo-installed binaries via cargo-update" {
  make_stub cargo
  make_stub cargo-install-update
  run run_cleaner 53-cargo.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
cargo install-update -a
EOF
}

@test "mise: non-interactive self-update (-y), outdated report, cache clear" {
  make_stub mise
  run run_cleaner 55-mise.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
mise self-update -y
mise outdated
mise cache clear
EOF
}

@test "mise: MISE_PRUNE=1 adds a non-interactive prune (--yes: it asks otherwise)" {
  make_stub mise
  CMM_MISE_PRUNE=1 run run_cleaner 55-mise.sh
  [ "$status" -eq 0 ]
  grep -qx 'mise prune --yes' "$CALL_LOG"
}

@test "mise: brew-managed mise is not self-updated (Homebrew's build refuses)" {
  brew_formula_tool mise
  run run_cleaner 55-mise.sh
  [ "$status" -eq 0 ]
  refute grep -q 'self-update' "$CALL_LOG"
}

# ---------- developer tools ----------

@test "docker: daemon up — prunes old build cache and dangling images only (D3)" {
  make_stub docker
  run run_cleaner 60-docker.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
docker info
docker system df
docker builder prune -f --filter until=168h
docker image prune -f
EOF
  refute grep -Eq 'docker (container|volume|system) prune' "$CALL_LOG"
  refute grep -q -- ' -a' "$CALL_LOG"
}

@test "docker: DOCKER_KEEP_HOURS sets the build-cache filter" {
  make_stub docker
  CMM_DOCKER_KEEP_HOURS=24 run run_cleaner 60-docker.sh
  grep -qx 'docker builder prune -f --filter until=24h' "$CALL_LOG"
}

@test "docker: daemon down — skips (exit 75)" {
  make_stub_script docker <<'EOF'
case "$1" in info) exit 1 ;; esac
exit 0
EOF
  run run_cleaner 60-docker.sh
  [ "$status" -eq 75 ]
  refute grep -q prune "$CALL_LOG"
}

@test "krew: upgrades plugins through kubectl" {
  make_stub kubectl
  make_stub kubectl-krew
  run run_cleaner 61-krew.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
kubectl krew upgrade
EOF
}

@test "vscode: updates extensions from the CLI" {
  make_stub code
  run run_cleaner 62-vscode.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
code --update-extensions
EOF
}

# ---------- xcode ----------

# A full-Xcode developer dir, a plutil that reads "KEY=VALUE" fixture plists
# (portable to Linux CI), and an idle pgrep (Xcode not running).
xcode_env() {
  mkdir -p "$SANDBOX/Xcode.app/Contents/Developer"
  make_stub_script xcode-select <<EOF
echo "$SANDBOX/Xcode.app/Contents/Developer"
EOF
  make_stub xcrun
  make_stub_script plutil <<'EOF'
key="$2"; file=""
for a in "$@"; do file="$a"; done
v="$(sed -n "s/^$key=//p" "$file")"
[ -n "$v" ] || exit 1
echo "$v"
EOF
  printf '#!/bin/sh\nexit 1\n' >"$STUB_BIN/pgrep"
  chmod 755 "$STUB_BIN/pgrep"
  DD="$HOME/Library/Developer/Xcode/DerivedData"
  mkdir -p "$DD"
}

ago_iso() { date -u -v-"$1"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "$1 days ago" '+%Y-%m-%dT%H:%M:%SZ'; }

@test "xcode: deletes unavailable simulators; DerivedData age comes from Xcode's LastAccessedDate" {
  xcode_env
  mkdir -p "$DD/Stale-abc" "$DD/Active-def" "$SANDBOX/proj"
  printf 'LastAccessedDate=%s\nWorkspacePath=%s\n' "$(ago_iso 45)" "$SANDBOX/proj" >"$DD/Stale-abc/info.plist"
  printf 'LastAccessedDate=%s\nWorkspacePath=%s\n' "$(ago_iso 2)" "$SANDBOX/proj" >"$DD/Active-def/info.plist"
  # the active folder's own mtime is ancient — the old -mtime test got this wrong
  touch -t 202001010000 "$DD/Active-def"
  run run_cleaner 70-xcode.sh
  [ "$status" -eq 0 ]
  grep -q '^xcrun simctl delete unavailable$' "$CALL_LOG"
  [ ! -d "$DD/Stale-abc" ]
  [ -d "$DD/Active-def" ]
  [[ "$output" == *"not opened in Xcode for 45 days"* ]]
}

@test "xcode: DerivedData for a project that no longer exists is purged regardless of age" {
  xcode_env
  mkdir -p "$DD/Gone-xyz"
  printf 'LastAccessedDate=%s\nWorkspacePath=%s\n' "$(ago_iso 1)" "$SANDBOX/deleted/Proj.xcodeproj" >"$DD/Gone-xyz/info.plist"
  run run_cleaner 70-xcode.sh
  [ "$status" -eq 0 ]
  [ ! -d "$DD/Gone-xyz" ]
  [[ "$output" == *"no longer exists"* ]]
}

@test "xcode: without an info.plist, recent activity anywhere inside keeps a folder" {
  xcode_env
  mkdir -p "$DD/NoPlistOld/Build" "$DD/NoPlistBusy/Build"
  touch -t 202001010000 "$DD/NoPlistOld/Build" "$DD/NoPlistOld" "$DD/NoPlistBusy"
  touch "$DD/NoPlistBusy/Build/fresh.o" # nested activity only
  touch -t 202001010000 "$DD/NoPlistBusy"
  run run_cleaner 70-xcode.sh
  [ "$status" -eq 0 ]
  [ ! -d "$DD/NoPlistOld" ]
  [ -d "$DD/NoPlistBusy" ]
}

@test "xcode: honors CMM_DERIVEDDATA_AGE_DAYS" {
  xcode_env
  mkdir -p "$DD/MidProj-xyz" "$SANDBOX/proj"
  printf 'LastAccessedDate=%s\nWorkspacePath=%s\n' "$(ago_iso 10)" "$SANDBOX/proj" >"$DD/MidProj-xyz/info.plist"
  CMM_DERIVEDDATA_AGE_DAYS=60 run run_cleaner 70-xcode.sh
  [ -d "$DD/MidProj-xyz" ] # 10 days old, gate is 60 — kept
  CMM_DERIVEDDATA_AGE_DAYS=5 run run_cleaner 70-xcode.sh
  [ ! -d "$DD/MidProj-xyz" ] # gate lowered to 5 — purged
}

@test "xcode: device support keeps the newest per platform and purges old folders" {
  xcode_env
  local ds="$HOME/Library/Developer/Xcode/iOS DeviceSupport"
  mkdir -p "$ds/17.0 (21A329)" "$ds/17.1 (21B80)" "$ds/18.0 (22A3354)"
  touch -t 202301010000 "$ds/17.0 (21A329)"
  touch -t 202302010000 "$ds/17.1 (21B80)"
  touch -t 202303010000 "$ds/18.0 (22A3354)" # newest, though also old
  run run_cleaner 70-xcode.sh
  [ "$status" -eq 0 ]
  [ ! -d "$ds/17.0 (21A329)" ]
  [ ! -d "$ds/17.1 (21B80)" ]
  [ -d "$ds/18.0 (22A3354)" ]
}

@test "xcode: nothing is touched while Xcode is running" {
  xcode_env
  printf '#!/bin/sh\nexit 0\n' >"$STUB_BIN/pgrep" # Xcode is running
  mkdir -p "$DD/Stale-abc"
  printf 'LastAccessedDate=%s\n' "$(ago_iso 99)" >"$DD/Stale-abc/info.plist"
  run run_cleaner 70-xcode.sh
  [ "$status" -eq 0 ]
  [ -d "$DD/Stale-abc" ]
  [[ "$output" == *"Xcode is running"* ]]
}

@test "xcode: with only the Command Line Tools, simulators are left alone (simctl needs Xcode)" {
  xcode_env
  mkdir -p "$SANDBOX/CommandLineTools"
  make_stub_script xcode-select <<EOF
echo "$SANDBOX/CommandLineTools"
EOF
  run run_cleaner 70-xcode.sh
  [ "$status" -eq 0 ]
  refute grep -q simctl "$CALL_LOG"
  [[ "$output" == *"needs a full Xcode"* ]]
}

@test "xcode: dry-run lists what would go and deletes nothing" {
  xcode_env
  mkdir -p "$DD/Stale-abc"
  printf 'LastAccessedDate=%s\n' "$(ago_iso 99)" >"$DD/Stale-abc/info.plist"
  CMM_DRY_RUN=1 run run_cleaner 70-xcode.sh
  [ "$status" -eq 0 ]
  [ -d "$DD/Stale-abc" ]
  [[ "$output" == *"+ rm -rf $DD/Stale-abc"* ]]
}

@test "xcode: no Xcode and no leftovers — skips" {
  run run_cleaner 70-xcode.sh
  [ "$status" -eq 75 ]
}

# ---------- python ----------

# uv stub: a modern uv by default (UV_VER overrides); `cache prune` behavior
# via PRUNE_MODE (ok | busy | broken); `tool dir` points into the sandbox.
uv_stub() {
  cat >"$STUB_BIN/uv" <<EOF
#!/bin/sh
printf '%s %s\n' uv "\$*" >>"\$CALL_LOG"
case "\$1 \$2" in
  "--version "*) echo "uv \${UV_VER:-0.12.22} (Homebrew)"; exit 0 ;;
  "cache dir") echo "$SANDBOX/uvcache"; exit 0 ;;
  "tool dir") echo "$SANDBOX/uvtools"; exit 0 ;;
  "cache prune")
    case "\${PRUNE_MODE:-ok}" in
      busy) echo "Cache is currently in-use, waiting for other uv processes to finish (use \\\`--force\\\` to override)" >&2
            echo "error: Timeout (15s) when waiting for lock on \\\`/c\\\` at \\\`/c/.lock\\\`, is another uv process running?" >&2; exit 2 ;;
      broken) echo "error: permission denied" >&2; exit 2 ;;
    esac ;;
esac
exit 0
EOF
  chmod 755 "$STUB_BIN/uv"
  mkdir -p "$SANDBOX/uvtools"
}

pipx_stub() { # pipx_stub [with-cooldown]
  if [ "${1:-}" = with-cooldown ]; then
    make_stub_script pipx <<'EOF'
[ "$2" = --help ] && echo "usage: pipx upgrade-all [--cooldown DAYS]"
exit 0
EOF
  else
    make_stub_script pipx <<'EOF'
[ "$2" = --help ] && echo "usage: pipx upgrade-all [--skip SKIP]"
exit 0
EOF
  fi
}

@test "python: uv self-update (standalone), tool upgrades, pipx, prune, pip purge" {
  uv_stub
  pipx_stub
  make_stub python3
  run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  grep -qx 'uv self update' "$CALL_LOG"
  grep -qx 'uv tool upgrade --all' "$CALL_LOG"
  grep -qx 'pipx upgrade-all' "$CALL_LOG"
  grep -qx 'uv cache prune' "$CALL_LOG"
  grep -qx 'python3 -m pip cache purge' "$CALL_LOG"
  # upgrades happen before the cache is pruned
  [ "$(grep -n 'uv tool upgrade' "$CALL_LOG" | cut -d: -f1)" -lt "$(grep -n 'uv cache prune' "$CALL_LOG" | cut -d: -f1)" ]
}

@test "python: the cooldown is a relative span for uv >= 0.11.4 and --cooldown for pipx (S4)" {
  uv_stub
  pipx_stub with-cooldown
  CMM_COOLDOWN_DAYS=7 run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  grep -qx 'uv tool upgrade --all --exclude-newer 7 days' "$CALL_LOG"
  grep -qx 'pipx upgrade-all --cooldown 7' "$CALL_LOG"
}

@test "python: older uv gets an absolute RFC 3339 cutoff; older pipx is held" {
  uv_stub
  pipx_stub
  UV_VER=0.10.2 CMM_COOLDOWN_DAYS=7 run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  grep -Eq '^uv tool upgrade --all --exclude-newer [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$CALL_LOG"
  refute grep -Eq '^pipx upgrade-all($| --cooldown)' "$CALL_LOG" # only the --help probe ran
  grep -qx 'pipx upgrade-all --help' "$CALL_LOG"
  [[ "$output" == *"pipx predates --cooldown"* ]]
}

@test "python: a busy uv cache is skipped with a note — never hung on, never --force'd" {
  uv_stub
  PRUNE_MODE=busy run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"uv cache is in use"* ]]
  refute grep -q -- '--force' "$CALL_LOG"
  grep -qx 'uv tool upgrade --all' "$CALL_LOG" # upgrades unaffected
}

@test "python: any other prune failure fails the cleaner" {
  uv_stub
  PRUNE_MODE=broken run run_cleaner 40-python.sh
  [ "$status" -eq 1 ]
}

@test "python: uv < 0.9.16 (no lock timeout) checks for a busy cache before pruning" {
  uv_stub
  printf '#!/bin/sh\nexit 0\n' >"$STUB_BIN/pgrep" # a uv process holds the cache
  chmod 755 "$STUB_BIN/pgrep"
  UV_VER=0.9.10 run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping 'uv cache prune'"* ]]
  refute grep -q '^uv cache prune' "$CALL_LOG"
}

@test "python: tools pinned by a stale absolute exclude-newer receipt are pointed out" {
  uv_stub
  mkdir -p "$SANDBOX/uvtools/ruff" "$SANDBOX/uvtools/black"
  printf '[tool.options]\nexclude-newer = "2025-01-01T00:00:00Z"\n' >"$SANDBOX/uvtools/ruff/uv-receipt.toml"
  printf '[tool.options]\nexclude-newer = "2025-01-01T00:00:00Z"\nexclude-newer-span = "P7D"\n' >"$SANDBOX/uvtools/black/uv-receipt.toml"
  run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 uv tool(s) are pinned to a past --exclude-newer date"* ]]
}

@test "python: a Homebrew-managed uv is not self-updated (its build refuses)" {
  brew_formula_tool uv
  cat >"$SANDBOX/brewpfx/bin/uv" <<'EOF'
#!/bin/sh
printf '%s %s\n' uv "$*" >>"$CALL_LOG"
[ "$1" = --version ] && echo "uv 0.12.22 (Homebrew)"
exit 0
EOF
  run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  refute grep -q '^uv self update' "$CALL_LOG"
  [[ "$output" == *"uv is Homebrew-managed"* ]]
}

@test "python: skips when no python tooling exists at all" {
  PATH="$STUB_BIN:$MINI_BIN" run run_cleaner 40-python.sh
  [ "$status" -eq 75 ]
}

# ---------- conda ----------

@test "conda: updates conda itself in base (never --all) and cleans caches (-y: F4)" {
  make_stub_script conda <<EOF
[ "\$1 \$2" = "info --base" ] && echo "$SANDBOX/miniforge"
exit 0
EOF
  run run_cleaner 41-conda.sh
  [ "$status" -eq 0 ]
  grep -qx 'conda update -n base conda -y' "$CALL_LOG"
  grep -qx 'conda clean --all -y' "$CALL_LOG"
  refute grep -q 'update --all' "$CALL_LOG"
}

@test "conda: a frozen base environment is left alone (CEP 22)" {
  mkdir -p "$SANDBOX/miniforge/conda-meta"
  touch "$SANDBOX/miniforge/conda-meta/frozen"
  make_stub_script conda <<EOF
[ "\$1 \$2" = "info --base" ] && echo "$SANDBOX/miniforge"
exit 0
EOF
  run run_cleaner 41-conda.sh
  [ "$status" -eq 0 ]
  refute grep -q '^conda update' "$CALL_LOG"
  grep -qx 'conda clean --all -y' "$CALL_LOG"
  [[ "$output" == *"frozen"* ]]
}

@test "conda: standalone micromamba self-updates and cleans" {
  make_stub micromamba
  run run_cleaner 41-conda.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
micromamba self-update
micromamba clean --all -y
EOF
}

# ---------- poetry ----------

@test "poetry: standalone self-update; every listed cache cleared non-interactively" {
  make_stub_script poetry <<'EOF'
[ "$1 $2" = "cache list" ] && printf 'PyPI\n_default_cache\n'
exit 0
EOF
  run run_cleaner 42-poetry.sh
  [ "$status" -eq 0 ]
  grep -qx 'poetry self update' "$CALL_LOG"
  grep -qx 'poetry cache clear PyPI --all -n' "$CALL_LOG"
  grep -qx 'poetry cache clear _default_cache --all -n' "$CALL_LOG"
}

@test "poetry: a pipx-managed Poetry is not self-updated (pipx owns its venv)" {
  mkdir -p "$SANDBOX/pipx/venvs/poetry/bin" "$SANDBOX/bin"
  printf '#!/bin/sh\nprintf "%%s %%s\\n" poetry "$*" >>"$CALL_LOG"\n[ "$1 $2" = "cache list" ] && echo "No caches found"\nexit 0\n' >"$SANDBOX/pipx/venvs/poetry/bin/poetry"
  chmod 755 "$SANDBOX/pipx/venvs/poetry/bin/poetry"
  ln -s "$SANDBOX/pipx/venvs/poetry/bin/poetry" "$SANDBOX/bin/poetry"
  PATH="$SANDBOX/bin:$PATH" run run_cleaner 42-poetry.sh
  [ "$status" -eq 0 ]
  refute grep -q 'self update' "$CALL_LOG"
  refute grep -q 'cache clear' "$CALL_LOG"
  [[ "$output" == *"no Poetry caches to clear"* ]]
}

# ---------- rubygems ----------

@test "rubygems: opt-in; cleans a user Ruby's old gem versions; dry-run uses -d" {
  grep -qx '# default: off' "$REPO_ROOT/cleaners/54-rubygems.sh"
  make_stub_script gem <<EOF
[ "\$1 \$2" = "env gemdir" ] && echo "$SANDBOX/gems"
exit 0
EOF
  run run_cleaner 54-rubygems.sh
  [ "$status" -eq 0 ]
  grep -qx 'gem cleanup' "$CALL_LOG"
  : >"$CALL_LOG"
  CMM_DRY_RUN=1 run run_cleaner 54-rubygems.sh
  grep -qx 'gem cleanup -d' "$CALL_LOG"
  refute grep -qx 'gem cleanup' "$CALL_LOG"
}

@test "rubygems: never touches macOS's system Ruby" {
  make_stub_script gem <<'EOF'
[ "$1 $2" = "env gemdir" ] && echo "/Library/Ruby/Gems/2.6.0"
exit 0
EOF
  run run_cleaner 54-rubygems.sh
  [ "$status" -eq 75 ]
  [[ "$output" == *"system Ruby"* ]]
  refute grep -q 'cleanup' "$CALL_LOG"
}

# ---------- pre-commit / cocoapods / swiftpm ----------

@test "pre-commit: garbage-collects unused hook environments" {
  make_stub pre-commit
  run run_cleaner 63-pre-commit.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
pre-commit gc
EOF
}

@test "cocoapods: clears the pod download cache (--all: no prompt)" {
  make_stub pod
  run run_cleaner 71-cocoapods.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
pod cache clean --all
EOF
}

@test "swiftpm: purges the global cache from a throwaway directory (no stray .build here)" {
  make_stub_script swift <<EOF
pwd >"$SANDBOX/swift-cwd"
mkdir -p .build
exit 0
EOF
  mkdir -p "$SANDBOX/workdir"
  cd "$SANDBOX/workdir"
  run run_cleaner 72-swiftpm.sh
  [ "$status" -eq 0 ]
  grep -qx 'swift package purge-cache' "$CALL_LOG"
  [ "$(cat "$SANDBOX/swift-cwd")" != "$SANDBOX/workdir" ]
  [ ! -e "$SANDBOX/workdir/.build" ]
  [ ! -d "$(cat "$SANDBOX/swift-cwd")" ] # the scratch dir is removed again
}

# ---------- cross-cutting ----------

@test "every single-gate cleaner skips with 75 when its tool is absent" {
  local c
  for c in 10-homebrew.sh 20-mas.sh 30-npm.sh 31-pnpm.sh 32-yarn.sh 33-bun.sh 34-deno.sh \
    41-conda.sh 42-poetry.sh 44-copilot.sh 45-claude.sh 46-codex.sh 47-gemini.sh 48-gh.sh \
    49-cursor.sh 50-rustup.sh 51-composer.sh 52-go.sh 53-cargo.sh 54-rubygems.sh 55-mise.sh \
    60-docker.sh 61-krew.sh 62-vscode.sh 63-pre-commit.sh 70-xcode.sh 71-cocoapods.sh \
    72-swiftpm.sh; do
    PATH="$STUB_BIN:$MINI_BIN" run run_cleaner "$c"
    [ "$status" -eq 75 ] || {
      echo "expected 75 from $c, got $status"
      false
    }
  done
}

@test "every built-in cleaner declares gate, group, default and summary headers" {
  local f k
  for f in "$REPO_ROOT"/cleaners/*.sh; do
    for k in gate group default summary; do
      grep -Eq "^# $k: .+" "$f" || {
        echo "$f lacks '# $k:'"
        false
      }
    done
    grep -Eq '^# default: (on|off)$' "$f"
  done
}

ALL_TOOLS="brew mas npm pnpm yarn bun deno uv pipx python3 conda micromamba poetry copilot claude \
codex gemini gh cursor-agent rustup composer go cargo cargo-install-update gem mise docker kubectl \
kubectl-krew code pre-commit xcrun pod swift"

@test "status mode never executes a mutating command in any built-in cleaner" {
  local t c
  for t in $ALL_TOOLS; do make_stub "$t"; done
  for c in "$REPO_ROOT"/cleaners/*.sh; do
    CMM_MODE=status run run_cleaner "${c##*/}"
  done
  if grep -v -- '--dry-run' "$CALL_LOG" |
    grep -Eq ' (update|upgrade|prune|clean|cache rm|cache clear|cache verify|install|clear-cache|gc|self-update|self update|purge-cache)( |$)'; then
    echo "status mode executed a mutating command:" >&2
    cat "$CALL_LOG" >&2
    false
  fi
}

@test "dry-run invokes no mutating command in any built-in cleaner" {
  local t c
  for t in $ALL_TOOLS; do make_stub "$t"; done
  for c in "$REPO_ROOT"/cleaners/*.sh; do
    CMM_DRY_RUN=1 run run_cleaner "${c##*/}"
  done
  # only read-only queries and previews may have executed
  refute grep -Ev -- '--dry-run| -d$|outdated|^docker (info|system df)$|--version|--help|^mas outdated$|cache dir|--cache|store path|config get|env GOCACHE|cache-dir|tool dir|info --base|env gemdir|cache list|-m pip --version|config --global home' "$CALL_LOG"
}
