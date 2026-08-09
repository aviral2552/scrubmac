#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# Per-cleaner tests against PATH stubs: exact argv sequences, skip-when-absent,
# and the regression pins from the plan (F4–F8, S4, D3, D4).

load helpers/setup

setup() { setup_sandbox; }
teardown() { teardown_sandbox; }

run_cleaner() {
  local c="$1"
  shift
  CMM_LIB="$CMM_LIB_PATH" "$REPO_ROOT/cleaners/$c" "$@"
}

@test "homebrew: full maintenance sequence, in order (F8: no cask dance)" {
  make_stub brew
  run run_cleaner 10-homebrew.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
brew update
brew upgrade
brew autoremove
brew doctor
brew missing
brew cleanup -s --prune=all
EOF
}

@test "homebrew: advisory doctor/missing failures do not fail the cleaner" {
  cat >"$STUB_BIN/brew" <<'EOF'
#!/bin/sh
printf '%s %s\n' brew "$*" >>"$CALL_LOG"
case "$1" in doctor | missing) exit 1 ;; esac
exit 0
EOF
  chmod 755 "$STUB_BIN/brew"
  run run_cleaner 10-homebrew.sh
  [ "$status" -eq 0 ]
  grep -q '^brew cleanup -s --prune=all$' "$CALL_LOG" # still ran after doctor failed
}

@test "mas: outdated report then upgrade" {
  make_stub mas
  run run_cleaner 20-mas.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
mas outdated
mas upgrade
EOF
}

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
  ! grep -q -- --depth "$CALL_LOG"
}

@test "npm: brew-managed npm skips self-update (F5, D4)" {
  local pfx="$SANDBOX/brewpfx"
  mkdir -p "$pfx/bin"
  cat >"$pfx/bin/npm" <<'EOF'
#!/bin/sh
printf '%s %s\n' npm "$*" >>"$CALL_LOG"
exit 0
EOF
  chmod 755 "$pfx/bin/npm"
  export PATH="$pfx/bin:$PATH" CMM_BREW_PREFIX="$pfx"
  run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *brew-managed* ]]
  ! grep -q '^npm install -g npm@latest$' "$CALL_LOG"
  grep -q '^npm update -g$' "$CALL_LOG"
}

@test "npm: outdated exiting 1 is tolerated (F1 root cause)" {
  cat >"$STUB_BIN/npm" <<'EOF'
#!/bin/sh
printf '%s %s\n' npm "$*" >>"$CALL_LOG"
case "$1" in outdated) exit 1 ;; esac
exit 0
EOF
  chmod 755 "$STUB_BIN/npm"
  run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  grep -q '^npm cache verify$' "$CALL_LOG"
}

@test "npm: cooldown holds automatic updates and never passes --before (S4 downgrade guard)" {
  make_stub npm
  CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"cooldown active"* ]]
  ! grep -q '^npm update' "$CALL_LOG"
  ! grep -q -- --before "$CALL_LOG"
  grep -q '^npm cache verify$' "$CALL_LOG"
}

@test "pnpm: store prune" {
  make_stub pnpm
  run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
pnpm store prune
EOF
}

@test "yarn v1: global upgrade and cache clean (F6)" {
  make_stub yarn 0 "1.22.22"
  run run_cleaner 32-yarn.sh
  [ "$status" -eq 0 ]
  grep -q '^yarn global upgrade -s$' "$CALL_LOG"
  grep -q '^yarn cache clean$' "$CALL_LOG"
}

@test "yarn berry: no global commands are attempted (F6)" {
  make_stub yarn 0 "4.5.1"
  run run_cleaner 32-yarn.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *berry* ]]
  ! grep -q '^yarn global' "$CALL_LOG"
  ! grep -q '^yarn cache clean$' "$CALL_LOG"
}

@test "bun: cache rm" {
  make_stub bun
  run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
bun pm cache rm
EOF
}

# pgrep must be stubbed in python-cleaner tests: the REAL pgrep would report
# whatever uv processes happen to live on the host (nondeterministic). The
# stub is silent (no call-log line) to keep exact-sequence diffs stable.
stub_pgrep() {
  printf '#!/bin/sh\nexit %s\n' "$1" >"$STUB_BIN/pgrep"
  chmod 755 "$STUB_BIN/pgrep"
}

@test "python: uv + pipx + pip sequence (standalone uv self-updates)" {
  make_stub uv
  make_stub pipx
  make_stub python3
  stub_pgrep 1 # cache idle
  run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
uv self update
uv tool upgrade --all
uv cache dir
uv cache prune
pipx upgrade-all
python3 -m pip --version
python3 -m pip cache purge
EOF
}

@test "python: cache prune is skipped, not hung, while the uv cache is in use" {
  make_stub uv
  stub_pgrep 0 # a resident uv/uvx process holds the cache
  run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping 'uv cache prune'"* ]]
  ! grep -q '^uv cache prune$' "$CALL_LOG"
  grep -q '^uv tool upgrade --all$' "$CALL_LOG" # upgrades unaffected
}

@test "python: cooldown adds --exclude-newer with an RFC 3339 date to uv (S4)" {
  make_stub uv
  stub_pgrep 1
  CMM_COOLDOWN_DAYS=7 run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  grep -Eq '^uv tool upgrade --all --exclude-newer [0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$' "$CALL_LOG"
}

@test "python: skips when no python tooling exists at all" {
  PATH="$STUB_BIN:$MINI_BIN" run run_cleaner 40-python.sh
  [ "$status" -eq 75 ]
}

@test "conda: -y on both update and clean (F4 hang regression)" {
  make_stub conda
  run run_cleaner 41-conda.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
conda update --all -y
conda clean --all -y
EOF
}

@test "claude: standalone install runs 'claude update'; nothing is ever deleted (D3)" {
  make_stub claude
  run run_cleaner 45-claude.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
claude update
EOF
}

@test "claude: brew-managed install is deferred to the homebrew cleaner (D4)" {
  local pfx="$SANDBOX/brewpfx"
  mkdir -p "$pfx/bin"
  cat >"$pfx/bin/claude" <<'EOF'
#!/bin/sh
printf '%s %s\n' claude "$*" >>"$CALL_LOG"
exit 0
EOF
  chmod 755 "$pfx/bin/claude"
  export PATH="$pfx/bin:$PATH" CMM_BREW_PREFIX="$pfx"
  run run_cleaner 45-claude.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *Homebrew-managed* ]]
  [ ! -s "$CALL_LOG" ] # claude itself was never invoked
}

@test "claude: npm-managed install (under brew prefix!) is deferred to the npm cleaner (D4 ordering)" {
  local pfx="$SANDBOX/brewpfx"
  mkdir -p "$pfx/bin" "$pfx/lib/node_modules/@anthropic-ai/claude-code"
  cat >"$pfx/lib/node_modules/@anthropic-ai/claude-code/cli.js" <<'EOF'
#!/bin/sh
printf '%s %s\n' claude "$*" >>"$CALL_LOG"
exit 0
EOF
  chmod 755 "$pfx/lib/node_modules/@anthropic-ai/claude-code/cli.js"
  ln -s "../lib/node_modules/@anthropic-ai/claude-code/cli.js" "$pfx/bin/claude"
  export PATH="$pfx/bin:$PATH" CMM_BREW_PREFIX="$pfx"
  run run_cleaner 45-claude.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *npm-managed* ]]
  [ ! -s "$CALL_LOG" ]
}

@test "codex: standalone runs 'codex update'" {
  make_stub codex
  run run_cleaner 46-codex.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
codex update
EOF
}

@test "gemini: standalone install gets a pointer, no guessed update command" {
  make_stub gemini
  run run_cleaner 47-gemini.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"via its own installer"* ]]
  [ ! -s "$CALL_LOG" ]
}

@test "gh: upgrades all extensions; tolerates 'no extensions installed'" {
  make_stub gh 1
  run run_cleaner 48-gh.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
gh extension upgrade --all
EOF
}

@test "cursor: standalone runs 'cursor-agent update'" {
  make_stub cursor-agent
  run run_cleaner 49-cursor.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
cursor-agent update
EOF
}

@test "rustup: update" {
  make_stub rustup
  run run_cleaner 50-rustup.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
rustup update
EOF
}

@test "composer: non-interactive global update and cache clear" {
  make_stub composer
  run run_cleaner 51-composer.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
composer global update --no-interaction
composer clear-cache
EOF
}

@test "go: build cache only — never the module cache" {
  make_stub go
  run run_cleaner 52-go.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
go clean -cache
EOF
  ! grep -q -- -modcache "$CALL_LOG"
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

@test "docker: daemon up — prunes build cache and dangling images only (D3)" {
  make_stub docker
  run run_cleaner 60-docker.sh
  [ "$status" -eq 0 ]
  diff <(calls) - <<'EOF'
docker info
docker system df
docker builder prune -f
docker image prune -f
EOF
  ! grep -Eq 'docker (container|volume|system) prune' "$CALL_LOG"
}

@test "docker: daemon down — skips (exit 75)" {
  cat >"$STUB_BIN/docker" <<'EOF'
#!/bin/sh
printf '%s %s\n' docker "$*" >>"$CALL_LOG"
case "$1" in info) exit 1 ;; esac
exit 0
EOF
  chmod 755 "$STUB_BIN/docker"
  run run_cleaner 60-docker.sh
  [ "$status" -eq 75 ]
  ! grep -q prune "$CALL_LOG"
}

@test "xcode: deletes unavailable simulators; purges only DerivedData older than the age gate" {
  make_stub xcodebuild
  make_stub xcrun
  local dd="$HOME/Library/Developer/Xcode/DerivedData"
  mkdir -p "$dd/OldProj-abc" "$dd/FreshProj-def"
  touch -t 202001010000 "$dd/OldProj-abc"
  run run_cleaner 70-xcode.sh
  [ "$status" -eq 0 ]
  grep -q '^xcrun simctl delete unavailable$' "$CALL_LOG"
  [ ! -d "$dd/OldProj-abc" ]
  [ -d "$dd/FreshProj-def" ]
}

@test "xcode: missing DerivedData directory is not an error (guard pin)" {
  make_stub xcodebuild
  make_stub xcrun
  run run_cleaner 70-xcode.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"no DerivedData directory"* ]]
}

@test "xcode: honors CMM_DERIVEDDATA_AGE_DAYS" {
  make_stub xcodebuild
  make_stub xcrun
  local dd="$HOME/Library/Developer/Xcode/DerivedData"
  mkdir -p "$dd/MidProj-xyz"
  touch -t "$(date -v-10d +%Y%m%d0000 2>/dev/null || date -d '10 days ago' +%Y%m%d0000)" "$dd/MidProj-xyz"
  CMM_DERIVEDDATA_AGE_DAYS=60 run run_cleaner 70-xcode.sh
  [ -d "$dd/MidProj-xyz" ] # 10 days old, gate is 60 — kept
  CMM_DERIVEDDATA_AGE_DAYS=5 run run_cleaner 70-xcode.sh
  [ ! -d "$dd/MidProj-xyz" ] # gate lowered to 5 — purged
}

@test "every single-gate cleaner skips with 75 when its tool is absent" {
  local c
  for c in 10-homebrew.sh 20-mas.sh 30-npm.sh 31-pnpm.sh 32-yarn.sh 33-bun.sh \
    41-conda.sh 45-claude.sh 46-codex.sh 47-gemini.sh 48-gh.sh 49-cursor.sh \
    50-rustup.sh 51-composer.sh 52-go.sh 55-mise.sh 60-docker.sh 70-xcode.sh; do
    PATH="$STUB_BIN:$MINI_BIN" run run_cleaner "$c"
    [ "$status" -eq 75 ] || {
      echo "expected 75 from $c, got $status"
      false
    }
  done
}

@test "all cleaners run under dry-run without invoking any tool" {
  make_stub brew
  make_stub npm
  CMM_DRY_RUN=1 run run_cleaner 10-homebrew.sh
  [ "$status" -eq 0 ]
  CMM_DRY_RUN=1 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  [ ! -s "$CALL_LOG" ] # announced but never executed
}
