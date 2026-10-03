#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# Per-cleaner tests against PATH stubs: exact argv sequences, skip-when-absent,
# modes (update/clean/status/dry-run), offline behavior, install-kind
# deferral (D4), the supply-chain cooldown (S4) and its resolver
# (lib/registry.js), and the regression pins (F4–F8, D3). Commands and flags
# are validated against each tool's official documentation (see
# docs/cleaners.md); tests pin that exact usage.
#
# Conventions: on macOS's bash 3.2 a failing `[[ … ]]` that is not a test's
# last command does not fail the test, so every one ends in `|| false`; and
# one assertion per line (of two tests chained with &&, only the last is enforced).

load helpers/setup

setup() {
  setup_sandbox
  export CMM_COOLDOWN_DAYS=0 # most sequences are pinned without the cooldown
  export CMM_INTERACTIVE=0
}
# Some tests make a folder unreadable (chmod 000) to stand in for macOS
# privacy protection; hand everything back before the sandbox goes.
teardown() {
  chmod -R u+rwx "$SANDBOX" 2>/dev/null || true
  teardown_sandbox
}

run_cleaner() {
  local c="$1"
  shift
  CMM_LIB="$CMM_LIB_PATH" "$REPO_ROOT/cleaners/$c" "$@"
}

# A brew prefix with TOOL installed as a formula (bin/TOOL -> ../Cellar/…).
brew_formula_tool() {
  local pfx="$SANDBOX/brewpfx"
  mkdir -p "$pfx/bin" "$pfx/Cellar/$1/1.0.0/bin"
  printf '#!/bin/sh\nprintf "%%s %%s\\n" %s "$*" >>"$CALL_LOG"\n' "$1" >"$pfx/Cellar/$1/1.0.0/bin/$1"
  chmod 755 "$pfx/Cellar/$1/1.0.0/bin/$1"
  ln -s "../Cellar/$1/1.0.0/bin/$1" "$pfx/bin/$1"
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

# need_node — link the real node in: the registry resolver runs on it.
need_node() {
  [ -n "$REAL_NODE" ] || skip "node is required for the registry resolver"
  ln -sf "$REAL_NODE" "$STUB_BIN/node"
}

# reg ARGS… — run lib/registry.js directly (resolver unit tests).
reg() { "$REAL_NODE" "$REPO_ROOT/lib/registry.js" "$@"; }

# ago DAYS — an npm-style publish time DAYS days ago.
ago() { date -u -v-"$1"d '+%Y-%m-%dT%H:%M:%S.000Z' 2>/dev/null || date -u -d "$1 days ago" '+%Y-%m-%dT%H:%M:%S.000Z'; }

# view_json LATEST VERSION:DAYS_AGO… — `npm view … time versions dist-tags
# --json` for releases published DAYS_AGO days ago ("-": no publish time).
view_json() {
  local latest="$1" e v t vs='' ts=''
  shift
  for e in "$@"; do
    v="${e%%:*}"
    t="${e#*:}"
    vs="$vs${vs:+,}\"$v\""
    [ "$t" = - ] || ts="$ts${ts:+,}\"$v\":\"$(ago "$t")\""
  done
  printf '{"time":{%s},"versions":[%s],"dist-tags":{"latest":"%s"}}' "$ts" "$vs" "$latest"
}

# want LINE… / got — compare $output with exact lines ($'…\t…' for tabs).
want() { printf '%s\n' "$@" >"$SANDBOX/want"; }
got() {
  printf '%s\n' "$output" >"$SANDBOX/got"
  diff "$SANDBOX/got" "$SANDBOX/want"
}

# fake_semver DIR — DIR/node_modules/semver: a stand-in for npm's semver in
# which ">=999" is never satisfied and "garbage" is not a valid range.
fake_semver() {
  mkdir -p "$1/node_modules/semver"
  cat >"$1/node_modules/semver/index.js" <<'EOF'
module.exports = {
  validRange: (r) => (typeof r === 'string' && r.trim() !== '' && r !== 'garbage' ? r : null),
  satisfies: (v, r) => !/>=\s*999/.test(r)
}
EOF
}

# The npm stub for registry lookups (npm, pnpm and bun cleaners), driven by
# files in $SANDBOX/npmfx: outdated.json, ls.json, view-<pkg>.json (`npm view
# <pkg> time versions dist-tags --json`) and meta-<pkg>.json (`npm view
# "<pkg>@<v1> || …" name version deprecated engines --json`); "/" and "@" in
# names become "__" and "AT". `npm root -g` is $SANDBOX/npmfx/root. The stub
# lives inside a fake npm package ($SANDBOX/npmpkg, linked from the stub dir)
# so the resolver finds a semver there when a test plants one.
npm_fixture() {
  mkdir -p "$SANDBOX/npmfx/root" "$SANDBOX/npmpkg/bin"
  printf '{"name":"npm","version":"11.0.0"}\n' >"$SANDBOX/npmpkg/package.json"
  cat >"$SANDBOX/npmpkg/bin/npm-cli.js" <<'EOF'
#!/bin/sh
printf '%s %s\n' npm "$*" >>"$CALL_LOG"
fx="$SANDBOX/npmfx"
key() { printf '%s' "$1" | sed 's#/#__#g; s#@#AT#g'; }
case "$1" in
  outdated) [ "$3" = --json ] && cat "$fx/outdated.json" 2>/dev/null; exit 1 ;;
  ls) cat "$fx/ls.json" 2>/dev/null; exit 0 ;;
  root) echo "$fx/root"; exit 0 ;;
  view)
    if [ "$3" = time ]; then f="$fx/view-$(key "$2").json"; else f="$fx/meta-$(key "${2%@*}").json"; fi
    [ -f "$f" ] || exit 1
    cat "$f"
    exit 0 ;;
esac
exit 0
EOF
  chmod 755 "$SANDBOX/npmpkg/bin/npm-cli.js"
  ln -sf "$SANDBOX/npmpkg/bin/npm-cli.js" "$STUB_BIN/npm"
}
fxkey() { printf '%s' "$1" | sed 's#/#__#g; s#@#AT#g'; }
npm_view() { # npm_view NAME LATEST VERSION:DAYS_AGO…
  local name="$1"
  shift
  view_json "$@" >"$SANDBOX/npmfx/view-$(fxkey "$name").json"
}
npm_meta() { printf '%s' "$2" >"$SANDBOX/npmfx/meta-$(fxkey "$1").json"; }
# npm_globals NAME:CURRENT:LATEST… — outdated + ls fixtures for plain
# registry installs (edit ls.json afterwards for other kinds).
npm_globals() {
  local e name cur latest o='' l=''
  for e in "$@"; do
    name="${e%%:*}"
    e="${e#*:}"
    cur="${e%%:*}"
    latest="${e#*:}"
    o="$o${o:+,}\"$name\":{\"current\":\"$cur\",\"wanted\":\"$latest\",\"latest\":\"$latest\",\"dependent\":\"global\"}"
    l="$l${l:+,}\"$name\":{\"version\":\"$cur\",\"name\":\"$name\"}"
  done
  printf '{%s}' "$o" >"$SANDBOX/npmfx/outdated.json"
  printf '{"name":"lib","dependencies":{%s}}' "$l" >"$SANDBOX/npmfx/ls.json"
}

# ---------- homebrew ----------

@test "homebrew: unattended run upgrades formulae, not casks, then cleans up" {
  make_stub brew
  run run_cleaner 10-homebrew.sh
  [ "$status" -eq 0 ]
  diff "$CALL_LOG" - <<'EOF'
brew update
brew upgrade --formula
brew doctor
brew missing
brew autoremove
brew cleanup -s --prune=all
EOF
  [[ "$output" == *"casks not upgraded: unattended run"* ]] || false
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

@test "homebrew: the cask note gives the real reason (APP_UPDATES=never vs. an unattended run)" {
  make_stub brew
  CMM_INTERACTIVE=1 CMM_APP_UPDATES=never CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 10-homebrew.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"- casks not upgraded: APP_UPDATES=never"* ]] || false
  [[ "$output" != *"unattended run"* ]] || false
  grep -qx $'note\tcasks not upgraded (APP_UPDATES=never)' "$SANDBOX/report"
  : >"$SANDBOX/report"
  CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 10-homebrew.sh # interactive setting, nobody watching
  [[ "$output" == *"- casks not upgraded: unattended run (APP_UPDATES=interactive)"* ]] || false
  grep -qx $'note\tcasks not upgraded (unattended run; APP_UPDATES=interactive)' "$SANDBOX/report"
}

@test "homebrew: never waits on Homebrew's confirmation prompt; no auto-update after the explicit one" {
  make_stub_script brew <<'EOF'
echo "env NO_ASK=${HOMEBREW_NO_ASK:-} NO_AUTO=${HOMEBREW_NO_AUTO_UPDATE:-}" >>"$CALL_LOG"
EOF
  run run_cleaner 10-homebrew.sh
  [ "$status" -eq 0 ]
  # each call logged its argv, then its environment: pair them up
  awk 'NR % 2 == 1 { cmd = $0; next } { print cmd " | " $0 }' "$CALL_LOG" >"$SANDBOX/pairs"
  [ "$(wc -l <"$SANDBOX/pairs")" -ge 5 ]
  grep -qx 'brew update | env NO_ASK=1 NO_AUTO=' "$SANDBOX/pairs" # brew update itself may auto-update
  refute grep -q 'NO_ASK= ' "$SANDBOX/pairs"                      # never a prompt
  # every call after `brew update` runs with HOMEBREW_NO_AUTO_UPDATE=1
  awk 'seen && $0 !~ /NO_AUTO=1$/ { bad = 1 } /^brew update \|/ { seen = 1 } END { exit (bad || !seen) }' "$SANDBOX/pairs"
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
  diff "$CALL_LOG" - <<'EOF'
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
  diff "$CALL_LOG" - <<'EOF'
brew upgrade --formula --dry-run [auto=1]
brew cleanup -s --prune=all --dry-run [auto=]
EOF
  [[ "$output" == *"+ brew upgrade --formula"* ]] || false
}

@test "homebrew: status reports outdated packages and the cache size, changes nothing" {
  mkdir -p "$SANDBOX/brewcache"
  make_stub_script brew <<EOF
[ "\$1" = "--cache" ] && echo "$SANDBOX/brewcache"
exit 0
EOF
  CMM_MODE=status run run_cleaner 10-homebrew.sh
  [ "$status" -eq 0 ]
  diff "$CALL_LOG" - <<'EOF'
brew --cache
brew outdated
EOF
  [[ "$output" == *"cache $SANDBOX/brewcache"* ]] || false
}

# ---------- mas ----------

@test "mas: reports pending App Store updates and never runs mas update (it needs sudo)" {
  make_stub_script mas <<'EOF'
[ "$1" = outdated ] && printf '497799835 Xcode (16.0 -> 16.1)\n409183694 Keynote (14.1 -> 14.2)\n'
exit 0
EOF
  CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 20-mas.sh
  [ "$status" -eq 0 ]
  diff "$CALL_LOG" - <<'EOF'
mas outdated
EOF
  [[ "$output" == *"Keynote"* ]] || false
  [[ "$output" == *"run 'mas update' yourself"* ]] || false
  grep -qx $'note\t2 App Store update(s) pending — run \'mas update\' yourself' "$SANDBOX/report"
}

@test "mas: nothing pending; offline skips" {
  make_stub mas
  run run_cleaner 20-mas.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"no App Store updates pending"* ]] || false
  CMM_OFFLINE=1 run run_cleaner 20-mas.sh
  [ "$status" -eq 75 ]
}

@test "mas: a failing 'mas outdated' is reported, never read as 'nothing pending'" {
  make_stub_script mas <<'EOF'
echo 'Error: Error Domain=NSURLErrorDomain Code=-1001 "The request timed out."' >&2
exit 23
EOF
  CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 20-mas.sh
  [ "$status" -eq 0 ] # a report: it never fails the run
  [[ "$output" == *"'mas outdated' exited 23"* ]] || false
  [[ "$output" != *"no App Store updates pending"* ]] || false
  grep -qx $'note\tcould not check the App Store (mas outdated exited 23)' "$SANDBOX/report"
}

@test "mas: a partial answer still counts what was printed, and notes the failure" {
  make_stub_script mas <<'EOF'
echo '497799835 Xcode (16.0 -> 16.1)'
exit 1
EOF
  CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 20-mas.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"Xcode (16.0 -> 16.1)"* ]] || false
  grep -qx $'note\t1 App Store update(s) pending — run \'mas update\' yourself' "$SANDBOX/report"
  grep -qx $'note\tcould not check the App Store (mas outdated exited 1)' "$SANDBOX/report"
}

# ---------- registry resolver (lib/registry.js) ----------

@test "registry pick: a prerelease moves to its own stable release once that is old enough" {
  need_node
  run reg pick x 2.0.0-beta.1 "$(ago 7)" latest <<<"$(view_json 2.0.0 1.0.0:90 2.0.0-beta.1:60 2.0.0-beta.2:50 2.0.0:30)"
  [ "$status" -eq 0 ]
  [ "$output" = $'pick\t2.0.0\t2.0.0-beta.2' ]
}

@test "registry pick: prereleases only for an installed prerelease of the same version" {
  need_node
  # the stable 2.0.0 is too fresh: beta.2 of the same version (never 2.1.0-beta.1)
  run reg pick x 2.0.0-beta.1 "$(ago 7)" latest <<<"$(view_json 2.0.0 2.0.0-beta.1:60 2.0.0-beta.2:50 2.0.0:1 2.1.0-beta.1:40)"
  [ "$output" = $'pick\t2.0.0-beta.2' ]
  # a stable install never moves to a prerelease
  run reg pick x 1.0.0 "$(ago 7)" latest <<<"$(view_json 1.0.0 1.0.0:90 1.1.0-rc.1:60)"
  [ "$output" = none ]
}

@test "registry pick: never past the latest dist-tag, even for an older stable release" {
  need_node
  run reg pick x 1.0.0 "$(ago 7)" latest <<<"$(view_json 2.0.0 1.0.0:90 2.0.0:60 3.0.0:50)"
  [ "$status" -eq 0 ]
  [ "$output" = $'pick\t2.0.0' ] # 3.0.0 (on "next") is mature too, but past "latest"
}

@test "registry pick: never a downgrade; fresh releases are held (naming the newest)" {
  need_node
  run reg pick x 1.5.0 "$(ago 7)" latest <<<"$(view_json 1.6.0 1.4.0:60 1.5.0:2 1.6.0:1)"
  [ "$output" = $'held\t1.6.0' ]
  run reg pick x 1.0.0 "$(ago 7)" latest <<<"$(view_json 1.2.0 1.0.0:90 1.1.0:2 1.2.0:1)"
  [ "$output" = $'held\t1.2.0' ]
  run reg pick x 1.2.0 "$(ago 7)" latest <<<"$(view_json 1.2.0 1.0.0:90 1.2.0:60)"
  [ "$output" = none ]
}

@test "registry pick: caret stays in the major (0.x: the minor; 0.0.x: nothing), tilde in the minor" {
  need_node
  local json
  json="$(view_json 2.0.0 1.2.0:90 1.2.9:80 1.3.0:70 2.0.0:60)"
  run reg pick x 1.2.0 "$(ago 7)" latest <<<"$json"
  [ "$output" = $'pick\t2.0.0\t1.3.0\t1.2.9' ]
  run reg pick x 1.2.0 "$(ago 7)" caret <<<"$json"
  [ "$output" = $'pick\t1.3.0\t1.2.9' ]
  run reg pick x 1.2.0 "$(ago 7)" tilde <<<"$json"
  [ "$output" = $'pick\t1.2.9' ]
  run reg pick x 0.2.1 "$(ago 7)" caret <<<"$(view_json 0.3.0 0.2.1:90 0.2.5:80 0.3.0:70)"
  [ "$output" = $'pick\t0.2.5' ]
  run reg pick x 0.0.3 "$(ago 7)" caret <<<"$(view_json 0.0.4 0.0.3:90 0.0.4:80)"
  [ "$output" = none ]
}

@test "registry pick: a release without a publish time counts as too fresh" {
  need_node
  run reg pick x 1.0.0 "$(ago 7)" latest <<<"$(view_json 1.1.0 1.0.0:90 1.1.0:-)"
  [ "$output" = $'held\t1.1.0' ]
}

@test "registry pick: reads npm 12's array-wrapped output; at most four candidates, best first" {
  need_node
  run reg pick x 1.0.0 "$(ago 7)" latest <<<"[$(view_json 1.5.0 1.0.0:90 1.1.0:80 1.2.0:70 1.3.0:60 1.4.0:50 1.5.0:40)]"
  [ "$status" -eq 0 ]
  [ "$output" = $'pick\t1.5.0\t1.4.0\t1.3.0\t1.2.0' ]
}

@test "registry pick: an npm error, unreadable input, a bad mode or cutoff exit 3" {
  need_node
  run reg pick x 1.0.0 "$(ago 7)" latest <<<'[{"error":{"code":"E404"}}]'
  [ "$status" -eq 3 ]
  run reg pick x 1.0.0 "$(ago 7)" latest <<<'not json'
  [ "$status" -eq 3 ]
  run reg pick x 1.0.0 "$(ago 7)" sideways <<<'{}'
  [ "$status" -eq 3 ]
  run reg pick x 1.0.0 yesterday latest <<<'{}'
  [ "$status" -eq 3 ]
}

@test "registry verify: deprecated and engine-incompatible releases are stepped over in order" {
  need_node
  fake_semver "$SANDBOX/npmpkg"
  run reg verify 1.3.0,1.2.0,1.1.0 --semver-dir "$SANDBOX/npmpkg" <<<'[[{"name":"x","version":"1.3.0","deprecated":"broken, use 1.3.1"},{"name":"x","version":"1.2.0","engines":{"node":">=999"}},{"name":"x","version":"1.1.0","engines":{"node":">=18"}}]]'
  [ "$status" -eq 0 ]
  [ "${#lines[@]}" -eq 3 ]
  [ "${lines[0]}" = $'skip\t1.3.0\tdeprecated: broken, use 1.3.1' ]
  [[ "${lines[1]}" == $'skip\t1.2.0\tneeds node >=999 (this is v'* ]] || false
  [ "${lines[2]}" = $'ok\t1.1.0' ]
}

@test "registry verify: without npm's semver the engines are not checked — never a failure" {
  need_node
  mkdir -p "$SANDBOX/no-semver"
  run reg verify 1.2.0 --semver-dir "$SANDBOX/no-semver" <<<'[{"name":"x","version":"1.2.0","engines":{"node":">=999"}}]'
  [ "$status" -eq 0 ]
  [ "$output" = $'ok\t1.2.0' ]
  fake_semver "$SANDBOX/npmpkg"
  run reg verify 1.2.0 --no-engines --semver-dir "$SANDBOX/npmpkg" <<<'[{"name":"x","version":"1.2.0","engines":{"node":">=999"}}]'
  [ "$output" = $'ok\t1.2.0' ]
  run reg verify 1.2.0 --semver-dir "$SANDBOX/npmpkg" <<<'[{"name":"x","version":"1.2.0","engines":{"node":"garbage"}}]'
  [ "$output" = $'ok\t1.2.0' ] # an invalid range is not held against a release
}

@test "registry verify: npm 11's single object; unknown candidates and empty input are accepted unchecked" {
  need_node
  run reg verify 1.1.0,1.0.0 <<<'{"name":"x","version":"1.1.0","deprecated":"no"}'
  want $'skip\t1.1.0\tdeprecated: no' $'ok\t1.0.0'
  got
  run reg verify 1.1.0,1.0.0 </dev/null
  [ "$output" = $'ok\t1.1.0' ]
  run reg verify 1.1.0,1.0.0 <<<'[{"name":"x","version":"1.1.0","deprecated":"a"},{"name":"x","version":"1.0.0","deprecated":"b"}]'
  want $'skip\t1.1.0\tdeprecated: a' $'skip\t1.0.0\tdeprecated: b' unsuitable
  got
}

@test "registry npm-outdated: npm/corepack, linked, aliased, git, unlisted and ahead-of-latest globals are skipped" {
  need_node
  mkdir -p "$SANDBOX/root/plain" "$SANDBOX/root/aliased" "$SANDBOX/fork"
  printf '{"name":"plain","version":"1.0.0"}' >"$SANDBOX/root/plain/package.json"
  printf '{"name":"kleur","version":"4.0.0"}' >"$SANDBOX/root/aliased/package.json"
  ln -s "$SANDBOX/fork" "$SANDBOX/root/linked"
  run reg npm-outdated "$SANDBOX/root" <<'EOF'
{"outdated": {
  "npm": {"current": "11.0.0", "latest": "12.0.0"},
  "corepack": {"current": "0.30.0", "latest": "0.36.0"},
  "plain": {"current": "1.0.0", "wanted": "1.2.0", "latest": "1.2.0"},
  "@scope/pkg": {"current": "2.0.0", "latest": "2.1.0"},
  "linked": {"current": "6.0.0", "latest": "7.0.0"},
  "dirinstall": {"current": "1.0.0", "latest": "2.0.0"},
  "aliased": {"current": "4.0.0", "latest": "4.1.5"},
  "fromgit": {"current": "1.0.0", "latest": "1.1.0"},
  "unlisted": {"current": "1.0.0", "latest": "1.1.0"},
  "ahead": {"current": "3.0.0", "latest": "2.0.0"},
  "odd": {"current": "linked", "latest": "1.0.0"}},
 "ls": {"dependencies": {
  "npm": {"version": "11.0.0"}, "corepack": {"version": "0.30.0"},
  "plain": {"version": "1.0.0", "name": "plain"},
  "@scope/pkg": {"version": "2.0.0", "name": "@scope/pkg", "resolved": "https://registry.npmjs.org/@scope/pkg/-/pkg-2.0.0.tgz"},
  "linked": {"version": "6.0.0", "name": "linked"},
  "dirinstall": {"version": "1.0.0", "resolved": "file:../../../dir"},
  "aliased": {"version": "4.0.0"},
  "fromgit": {"version": "1.0.0", "resolved": "git+ssh://git@github.com/u/fromgit.git#abc"},
  "ahead": {"version": "3.0.0"}, "odd": {"version": "1.0.0"}}}}
EOF
  [ "$status" -eq 0 ]
  want $'skip\tnpm\t11.0.0\tself' $'skip\tcorepack\t0.30.0\tself' $'update\tplain\t1.0.0\t1.2.0' \
    $'update\t@scope/pkg\t2.0.0\t2.1.0' $'skip\tlinked\t6.0.0\tlinked' $'skip\tdirinstall\t1.0.0\tlinked' \
    $'skip\taliased\t4.0.0\talias' $'skip\tfromgit\t1.0.0\tsource' $'skip\tunlisted\t1.0.0\tunknown' \
    $'skip\tahead\t3.0.0\tahead' $'skip\todd\tlinked\tversion'
  got
}

@test "registry npm-outdated: an npm error or unreadable input exits 3" {
  need_node
  run reg npm-outdated "$SANDBOX" <<<'{"outdated":{"error":{"code":"ENOTFOUND"}},"ls":{}}'
  [ "$status" -eq 3 ]
  run reg npm-outdated "$SANDBOX" <<<'{"outdated":'
  [ "$status" -eq 3 ]
}

@test "registry pnpm-globals: pnpm >= 11 install groups, aliases, local installs and pnpm itself" {
  need_node
  local g="$SANDBOX/pnhome/global/v11"
  mkdir -p "$g/g1" "$g/g2" "$g/g3" "$g/g4" "$g/g5"
  printf '{"dependencies":{"@types/node":"26.6.2","ms":"2.1.1"}}' >"$g/g1/package.json"
  printf '{"dependencies":{"is-number":"6.0.0"}}' >"$g/g2/package.json"
  printf '{"dependencies":{"mytool":"link:../../src/mytool","kleur":"4.0.0"}}' >"$g/g3/package.json"
  printf '{"dependencies":{"kleur-alias":"npm:kleur@4.0.0"}}' >"$g/g4/package.json"
  printf '{"dependencies":{"pnpm":"12.8.1"}}' >"$g/g5/package.json"
  run reg pnpm-globals <<EOF
[{"path": "$g", "private": true, "dependencies": {
  "@types/node": {"from": "@types/node", "version": "26.6.2", "path": "$g/g1/node_modules/@types/node"},
  "ms": {"from": "ms", "version": "2.1.1", "path": "$g/g1/node_modules/ms"},
  "is-number": {"from": "is-number", "version": "6.0.0", "path": "$g/g2/node_modules/is-number"},
  "mytool": {"from": "mytool", "version": "1.0.0", "path": "$g/g3/node_modules/mytool"},
  "kleur": {"from": "kleur", "version": "4.0.0", "path": "$g/g3/node_modules/kleur"},
  "kleur-alias": {"from": "kleur", "version": "4.0.0", "path": "$g/g4/node_modules/kleur-alias"},
  "pnpm": {"from": "pnpm", "version": "12.8.1", "path": "$g/g5/node_modules/pnpm"}}}]
EOF
  [ "$status" -eq 0 ]
  want $'skip\tmytool\tlocal' $'skip\tkleur-alias\talias' $'skip\tpnpm\tself' \
    $'group\t@types/node@26.6.2\tms@2.1.1' $'group\tis-number@6.0.0' $'skip\tkleur\tgroup:mytool'
  got
}

@test "registry pnpm-globals: pnpm 10's single global project — every package on its own" {
  need_node
  local g="$SANDBOX/pnhome/global/5"
  mkdir -p "$g"
  printf '{"dependencies":{"ms":"2.1.1","is-number":"6.0.0","cmm":"link:../../../src/cmm"}}' >"$g/package.json"
  run reg pnpm-globals <<EOF
[{"path": "$g", "private": false, "dependencies": {
  "ms": {"from": "ms", "version": "2.1.1", "resolved": "https://registry.npmjs.org/ms/-/ms-2.1.1.tgz", "path": "$g/.pnpm/ms@2.1.1/node_modules/ms"},
  "is-number": {"from": "is-number", "version": "6.0.0", "resolved": "https://registry.npmjs.org/is-number/-/is-number-6.0.0.tgz", "path": "$g/.pnpm/is-number@6.0.0/node_modules/is-number"},
  "tarball": {"from": "tarball", "version": "1.0.0", "resolved": "file:../tarball-1.0.0.tgz", "path": "$g/.pnpm/tarball@file+tarball/node_modules/tarball"},
  "cmm": {"from": "cmm", "version": "link:../../../src/cmm", "path": "$SANDBOX/src/cmm"},
  "kleur-alias": {"from": "kleur", "version": "4.1.4", "path": "$g/.pnpm/kleur@4.1.4/node_modules/kleur"}}}]
EOF
  [ "$status" -eq 0 ]
  want $'skip\ttarball\tlocal' $'skip\tcmm\tlocal' $'skip\tkleur-alias\talias' $'group\tms@2.1.1' $'group\tis-number@6.0.0'
  got
  run reg pnpm-globals <<<"[{\"path\": \"$g\", \"private\": false}]" # no globals at all
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "registry bun-globals: the saved range decides; pinned, local, linked and aliased are skipped" {
  need_node
  local g="$SANDBOX/bunglobal"
  mkdir -p "$g/node_modules/ms" "$g/node_modules/@types/node" "$g/node_modules/is-number" \
    "$g/node_modules/kleur-alias" "$g/node_modules/tool" "$g/node_modules/anything" "$SANDBOX/src"
  printf '{"dependencies":{"ms":"^2.1.1","@types/node":"~26.5.0","is-number":"6.0.0","kleur-alias":"npm:kleur@4.0.0","local":"/abs/local","tool":"^1.0.0","anything":"*","weird":">=1 <3","gone":"^1.0.0"}}' >"$g/package.json"
  printf '{"name":"ms","version":"2.1.1"}' >"$g/node_modules/ms/package.json"
  printf '{"name":"@types/node","version":"26.5.0"}' >"$g/node_modules/@types/node/package.json"
  printf '{"name":"is-number","version":"6.0.0"}' >"$g/node_modules/is-number/package.json"
  printf '{"name":"kleur","version":"4.0.0"}' >"$g/node_modules/kleur-alias/package.json"
  printf '{"name":"anything","version":"1.0.0"}' >"$g/node_modules/anything/package.json"
  rmdir "$g/node_modules/tool"
  ln -s "$SANDBOX/src" "$g/node_modules/tool"
  run reg bun-globals "$g"
  [ "$status" -eq 0 ]
  want $'pkg\tms\t2.1.1\tcaret' $'pkg\t@types/node\t26.5.0\ttilde' $'skip\tis-number\tpinned:6.0.0' \
    $'skip\tkleur-alias\talias' $'skip\tlocal\tlocal' $'skip\ttool\tlinked' $'pkg\tanything\t1.0.0\tlatest' \
    $'skip\tweird\tmissing' $'skip\tgone\tmissing'
  got
  run reg bun-globals "$SANDBOX/nowhere" # no global packages yet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

# ---------- npm ----------

@test "npm: without a cooldown, 'npm update -g' gets exactly the globals it may touch" {
  need_node
  npm_fixture
  npm_globals npm:11.0.0:12.0.0 corepack:0.30.0:0.36.0 plain:1.0.0:1.2.0 @scope/pkg:2.0.0:2.1.0 \
    linked:6.0.0:7.0.0 aliased:4.0.0:4.1.5 ahead:3.0.0:2.0.0
  ln -s "$SANDBOX/fork" "$SANDBOX/npmfx/root/linked"
  sed -i.bak 's/"name":"aliased"/"name":"kleur"/' "$SANDBOX/npmfx/ls.json"
  run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  grep -Ev '^npm (outdated|ls|root|view) ' "$CALL_LOG" >"$SANDBOX/mutating"
  diff "$SANDBOX/mutating" - <<'EOF'
npm update -g plain @scope/pkg
npm cache verify
EOF
  [[ "$output" == *"npm 11.0.0 is outdated, but it belongs to your Node.js install"* ]] || false
  [[ "$output" == *"corepack 0.30.0 is outdated, but it belongs to your Node.js install"* ]] || false
  [[ "$output" == *"skipping linked: linked/local install"* ]] || false
  [[ "$output" == *"skipping aliased: an aliased install"* ]] || false
  [[ "$output" == *"skipping ahead 3.0.0: newer than its \"latest\" release"* ]] || false
  refute grep -q -- --depth "$CALL_LOG" # F5
}

@test "npm: nothing to update means no 'npm update -g' at all" {
  need_node
  npm_fixture
  npm_globals npm:11.0.0:12.0.0
  run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  refute grep -q '^npm update' "$CALL_LOG"
  refute grep -q '^npm install' "$CALL_LOG"
  grep -qx 'npm cache verify' "$CALL_LOG"
  [[ "$output" == *"global packages are up to date"* ]] || false
}

@test "npm: npm itself is never self-updated, whatever installed it (D4)" {
  need_node
  npm_fixture # a "standalone" npm on PATH
  npm_globals npm:11.0.0:12.0.0 corepack:0.30.0:0.36.0
  npm_view npm 12.0.0 11.0.0:90 12.0.0:30
  run run_cleaner 30-npm.sh
  refute grep -q 'npm@' "$CALL_LOG"
  CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  refute grep -Eq '^npm install -g (npm|corepack)@' "$CALL_LOG"
  refute grep -q '^npm update' "$CALL_LOG"
}

@test "npm: without node, global updates are held — never a blind 'npm update -g'" {
  npm_fixture
  npm_globals plain:1.0.0:1.2.0
  [ ! -e "$STUB_BIN/node" ]
  run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"node (or scrubmac's lib/registry.js) not found"* ]] || false
  refute grep -q '^npm update' "$CALL_LOG"
  grep -qx 'npm cache verify' "$CALL_LOG"
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

# The cooldown fixture: "seasoned" has an old 2.1.0 and a fresh 2.2.0 (and a
# mature 3.0.0-beta.1 that must never be picked; npm 12's array shape on
# purpose); "@scope/fresh" has only a fresh newer release.
cooldown_fixture() {
  need_node
  npm_fixture
  npm_globals seasoned:2.0.0:2.2.0 @scope/fresh:1.0.0:1.1.0
  printf '[%s]' "$(view_json 2.2.0 2.0.0:60 2.1.0:60 2.2.0:1 3.0.0-beta.1:60)" >"$SANDBOX/npmfx/view-seasoned.json"
  npm_view @scope/fresh 1.1.0 1.0.0:60 1.1.0:1
}

@test "npm: cooldown installs the newest release old enough, holds fresher ones (S4)" {
  cooldown_fixture
  CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  grep -qx 'npm install -g seasoned@2.1.0' "$CALL_LOG" # 2.2.0 is too fresh; the beta never
  refute grep -q 'npm install -g @scope/fresh' "$CALL_LOG"
  [[ "$output" == *"@scope/fresh 1.0.0: every newer release is under 7 days old"* ]] || false
  grep -qx $'note\t1 global update(s) held by the 7-day cooldown' "$SANDBOX/report"
  refute grep -q '^npm update' "$CALL_LOG" # never the downgrade-prone path
  refute grep -Eq -- '--before|min-release-age' "$CALL_LOG"
  grep -qx 'npm cache verify' "$CALL_LOG"
}

@test "npm: cooldown never downgrades a package newer than every eligible release" {
  cooldown_fixture
  sed -i.bak 's/"current":"2.0.0"/"current":"2.1.5"/' "$SANDBOX/npmfx/outdated.json"
  CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  refute grep -q 'npm install -g seasoned' "$CALL_LOG"
}

@test "npm: cooldown under dry-run prints the exact versions it would install" {
  cooldown_fixture
  CMM_COOLDOWN_DAYS=7 CMM_DRY_RUN=1 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ npm install -g seasoned@2.1.0"* ]] || false
  refute grep -q 'npm install' "$CALL_LOG"
}

@test "npm: cooldown never installs over npm, corepack, linked or aliased globals (dependency confusion)" {
  need_node
  npm_fixture
  npm_globals npm:11.0.0:12.0.0 corepack:0.30.0:0.36.0 forked:6.0.0:7.0.0 aliased:4.0.0:4.1.5 plain:1.0.0:1.1.0
  ln -s "$SANDBOX/fork" "$SANDBOX/npmfx/root/forked"
  sed -i.bak 's/"name":"aliased"/"name":"kleur"/' "$SANDBOX/npmfx/ls.json"
  npm_view npm 12.0.0 11.0.0:900 12.0.0:90
  npm_view corepack 0.36.0 0.30.0:900 0.36.0:90
  npm_view forked 7.0.0 6.0.0:900 7.0.0:90
  npm_view aliased 4.1.5 4.0.0:900 4.1.5:90
  npm_view plain 1.1.0 1.0.0:900 1.1.0:90
  CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  grep -Ev '^npm (outdated|ls|root|view) ' "$CALL_LOG" >"$SANDBOX/mutating"
  diff "$SANDBOX/mutating" - <<'EOF'
npm install -g plain@1.1.0
npm cache verify
EOF
  [[ "$output" == *"skipping forked: linked/local install"* ]] || false
}

@test "npm: cooldown steps over deprecated releases and ones that need a newer node" {
  need_node
  npm_fixture
  fake_semver "$SANDBOX/npmpkg"
  npm_globals tool:1.0.0:1.3.0
  npm_view tool 1.3.0 1.0.0:90 1.1.0:60 1.2.0:50 1.3.0:40
  npm_meta tool '[{"name":"tool","version":"1.3.0","deprecated":"critical bug"},{"name":"tool","version":"1.2.0","engines":{"node":">=999"}},{"name":"tool","version":"1.1.0","engines":{"node":">=18"}}]'
  CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  grep -qx 'npm view tool@1.3.0 || 1.2.0 || 1.1.0 name version deprecated engines --json' "$CALL_LOG"
  grep -qx 'npm install -g tool@1.1.0' "$CALL_LOG"
  [[ "$output" == *"tool 1.3.0: deprecated: critical bug — trying the next release"* ]] || false
  [[ "$output" == *"tool 1.2.0: needs node >=999"* ]] || false
}

@test "npm: an npm error from 'outdated --json' fails the cleaner instead of passing silently" {
  need_node
  make_stub_script npm <<'EOF'
case "$1" in
  outdated) echo '{"error":{"code":"ENOTFOUND","summary":"offline"}}'; exit 1 ;;
  ls) echo '{}' ;;
esac
exit 0
EOF
  CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 1 ]
  grep -qx 'npm cache verify' "$CALL_LOG" # cleanup still happened
  CMM_COOLDOWN_DAYS=0 run run_cleaner 30-npm.sh
  [ "$status" -eq 1 ]
  refute grep -q '^npm update' "$CALL_LOG"
}

@test "npm: a failed registry lookup fails the cleaner but leaves the other packages alone" {
  need_node
  npm_fixture
  npm_globals broken:1.0.0:1.1.0 plain:1.0.0:1.1.0
  npm_view plain 1.1.0 1.0.0:90 1.1.0:60 # no fixture for "broken": npm view fails
  CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"registry lookup failed for broken"* ]] || false
  grep -qx 'npm install -g plain@1.1.0' "$CALL_LOG"
}

# ---------- pnpm ----------

# pnpm_fixture — a pnpm stub: `--version` prints $PNPM_VER (12.8.1), `ls -g
# --depth=0 --json` prints $SANDBOX/pnpm-ls.json (pnpm_globals writes it;
# none by default). Every call is logged; mutating ones also log their
# working directory to $SANDBOX/pnpm-cwd. With the npm fixture, the registry
# knows pnpm (the running version is the newest) unless a test says otherwise.
pnpm_fixture() {
  [ -f "$SANDBOX/pnpm-ls.json" ] || printf '[{"path":"%s","private":true,"dependencies":{}}]' "$SANDBOX/pnhome/global/v11" >"$SANDBOX/pnpm-ls.json"
  if [ -d "$SANDBOX/npmfx" ]; then
    [ -f "$SANDBOX/npmfx/view-pnpm.json" ] || npm_view pnpm "${PNPM_VER:-12.8.1}" "${PNPM_VER:-12.8.1}:90"
  fi
  cat >"$STUB_BIN/pnpm" <<'EOF'
#!/bin/sh
printf '%s %s\n' pnpm "$*" >>"$CALL_LOG"
case "$1" in
  --version) echo "${PNPM_VER:-12.8.1}" ;;
  ls) cat "$SANDBOX/pnpm-ls.json" ;;
  add | update | self-update) pwd -P >>"$SANDBOX/pnpm-cwd" ;;
esac
exit 0
EOF
  chmod 755 "$STUB_BIN/pnpm"
}

# pnpm_globals GROUP=MEMBER[,MEMBER]… — pnpm >= 11 globals: each GROUP an
# install group whose MEMBERs are NAME@VERSION[=SPEC] (SPEC defaults to the
# exact version, as `pnpm add -g` records it).
pnpm_globals() {
  local arg gid m name ver spec dir deps='' specs members
  for arg in "$@"; do
    gid="${arg%%=*}"
    dir="$SANDBOX/pnhome/global/v11/$gid"
    mkdir -p "$dir"
    specs=''
    IFS=, read -r -a members <<<"${arg#*=}"
    for m in "${members[@]}"; do
      spec=''
      case "$m" in *=*) spec="${m#*=}" m="${m%%=*}" ;; esac
      name="${m%@*}"
      ver="${m##*@}"
      deps="$deps${deps:+,}\"$name\":{\"from\":\"$name\",\"version\":\"$ver\",\"path\":\"$dir/node_modules/$name\"}"
      specs="$specs${specs:+,}\"$name\":\"${spec:-$ver}\""
    done
    printf '{"dependencies":{%s}}' "$specs" >"$dir/package.json"
  done
  printf '[{"path":"%s","private":true,"dependencies":{%s}}]' "$SANDBOX/pnhome/global/v11" "$deps" >"$SANDBOX/pnpm-ls.json"
}

@test "pnpm: without node/npm and no cooldown: standalone self-update, pnpm update -g, store prune" {
  pnpm_fixture
  run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  diff "$CALL_LOG" - <<'EOF'
pnpm self-update
pnpm update -g
pnpm store prune
EOF
}

@test "pnpm: the cooldown picks each global within its major and installs it with pnpm add -g (S4)" {
  need_node
  npm_fixture
  pnpm_globals g1=is-number@6.0.0 g2=ms@2.1.1 g3=@types/node@26.6.2
  pnpm_fixture
  npm_view is-number 7.0.0 6.0.0:900 7.0.0:800
  npm_view ms 2.1.3 2.1.1:900 2.1.2:800 2.1.3:700 3.0.0-canary.1:600
  npm_view @types/node 27.0.0 26.6.2:60 26.6.3:30 26.6.4:1 27.0.0:40
  PNPM_VER=12.6.0 npm_view pnpm 12.8.1 12.6.0:40 12.7.0:9 12.8.0:5 12.8.1:1
  PNPM_VER=12.6.0 CMM_COOLDOWN_DAYS=7 run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  grep -E '^pnpm (add|update|self-update|store)' "$CALL_LOG" >"$SANDBOX/mutating"
  diff "$SANDBOX/mutating" - <<'EOF'
pnpm self-update 12.7.0
pnpm add -g ms@2.1.3
pnpm add -g @types/node@26.6.3
pnpm store prune
EOF
  refute grep -q 'minimum-release-age' "$CALL_LOG" # pnpm's own setting fails outright
  [[ "$output" != *"is-number"* ]] || false        # no newer 6.x: nothing to say
}

@test "pnpm: an install group is re-added whole — re-adding one member alone would drop the rest" {
  need_node
  npm_fixture
  pnpm_globals g1=@types/node@26.6.2,ms@2.1.1,is-number@6.0.0
  pnpm_fixture
  npm_view @types/node 26.6.4 26.6.2:60 26.6.3:30 26.6.4:1
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700
  npm_view is-number 7.0.0 6.0.0:900 7.0.0:800
  CMM_COOLDOWN_DAYS=7 run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  grep -qx 'pnpm add -g @types/node@26.6.3,ms@2.1.3,is-number@6.0.0' "$CALL_LOG"
  [ "$(grep -c '^pnpm add' "$CALL_LOG")" -eq 1 ]
}

@test "pnpm: a pnpm that reads stdin cannot swallow the remaining packages" {
  need_node
  npm_fixture
  pnpm_globals g1=ms@2.1.1 g2=is-odd@2.0.0
  pnpm_fixture
  sed -i.bak 's/^  add | update | self-update) pwd -P >>"$SANDBOX\/pnpm-cwd" ;;$/  add) cat >\/dev\/null ;;/' "$STUB_BIN/pnpm"
  grep -q 'cat >/dev/null' "$STUB_BIN/pnpm"
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700
  npm_view is-odd 2.1.0 2.0.0:900 2.1.0:700
  CMM_COOLDOWN_DAYS=7 run run_cleaner 31-pnpm.sh </dev/null
  [ "$status" -eq 0 ]
  grep -qx 'pnpm add -g ms@2.1.3' "$CALL_LOG"
  grep -qx 'pnpm add -g is-odd@2.1.0' "$CALL_LOG"
}

@test "pnpm: linked/local, aliased and pnpm itself are never re-added (nor their group-mates)" {
  need_node
  npm_fixture
  pnpm_globals g1=mytool@1.0.0=link:../../src/mytool,kleur@4.0.0 g2=kleur-alias@4.0.0=npm:kleur@4.0.0 g3=pnpm@12.6.0
  pnpm_fixture
  npm_view kleur 4.1.5 4.0.0:900 4.1.5:800
  npm_view mytool 9.0.0 1.0.0:900 9.0.0:800
  CMM_COOLDOWN_DAYS=7 run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  refute grep -q '^pnpm add' "$CALL_LOG"
  [[ "$output" == *"skipping mytool: linked/local install"* ]] || false
  [[ "$output" == *"skipping kleur: installed together with mytool"* ]] || false
  [[ "$output" == *"skipping kleur-alias: an aliased install"* ]] || false
}

@test "pnpm: the self-update is held while every newer pnpm is fresher than the cooldown" {
  need_node
  npm_fixture
  pnpm_fixture
  npm_view pnpm 12.8.1 12.8.0:30 12.8.1:1
  PNPM_VER=12.8.0 CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  refute grep -q '^pnpm self-update' "$CALL_LOG"
  [[ "$output" == *"pnpm 12.8.0: pnpm 12.8.1 is under 7 days old"* ]] || false
  grep -qx $'note\tpnpm self-update held by the 7-day cooldown' "$SANDBOX/report"
}

@test "pnpm: a brew-managed pnpm is not self-updated (D4)" {
  brew_formula_tool pnpm
  run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  refute grep -q 'self-update' "$CALL_LOG"
  grep -qx 'pnpm update -g' "$CALL_LOG"
  [[ "$output" == *"pnpm is Homebrew-managed"* ]] || false
}

@test "pnpm: updates run from an empty scratch directory, removed afterwards" {
  need_node
  npm_fixture
  pnpm_globals g1=ms@2.1.1
  pnpm_fixture
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700
  npm_view pnpm 12.8.1 12.8.0:30 12.8.1:20
  mkdir -p "$SANDBOX/project"
  printf '{"packageManager":"pnpm@9.0.0"}\n' >"$SANDBOX/project/package.json"
  cd "$SANDBOX/project"
  PNPM_VER=12.8.0 CMM_COOLDOWN_DAYS=7 run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$SANDBOX/pnpm-cwd")" -eq 2 ] # self-update + add
  [ "$(sort -u "$SANDBOX/pnpm-cwd" | wc -l)" -eq 1 ]
  local scratch
  scratch="$(head -n 1 "$SANDBOX/pnpm-cwd")"
  [[ "$scratch" == "$TMPDIR"/scrubmac-* ]] || false # standalone: cmm_scratch_dir's own mktemp dir
  [ ! -e "$scratch" ]
  refute grep -qx "$SANDBOX/project" "$SANDBOX/pnpm-cwd"
}

@test "pnpm: with the cooldown on but no node/npm, everything is held" {
  pnpm_fixture
  CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  refute grep -Eq '^pnpm (add|update|self-update)' "$CALL_LOG"
  grep -qx 'pnpm store prune' "$CALL_LOG"
  grep -qx $'note\tglobal updates held (node/npm not found for the cooldown)' "$SANDBOX/report"
}

@test "pnpm: no global packages ('No global packages found') is fine" {
  need_node
  npm_fixture
  pnpm_fixture
  npm_view pnpm 12.8.1 12.8.1:30
  CMM_COOLDOWN_DAYS=7 run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"no global packages"* ]] || false
  [[ "$output" == *"pnpm 12.8.1 is up to date"* ]] || false
  refute grep -q '^pnpm add' "$CALL_LOG"
}

@test "pnpm: with the cooldown off (and node/npm present) each global moves to its newest in-major release" {
  need_node
  npm_fixture
  pnpm_globals g1=@types/node@26.6.2,ms@2.1.1
  pnpm_fixture
  npm_view @types/node 27.0.0 26.6.2:60 26.6.4:1 27.0.0:40
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700
  run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  grep -qx 'pnpm add -g @types/node@26.6.4,ms@2.1.3' "$CALL_LOG"
  refute grep -q '^pnpm update' "$CALL_LOG"
}

# ---------- yarn / bun / deno ----------

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
  [[ "$output" == *"global upgrades are held"* ]] || false
}

@test "yarn berry: no global commands are attempted (F6)" {
  make_stub yarn 0 "4.5.1"
  run run_cleaner 32-yarn.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *berry* ]] || false
  refute grep -q '^yarn global' "$CALL_LOG"
  refute grep -q '^yarn cache clean$' "$CALL_LOG"
}

# bun_fixture — a bun stub (`--version`: $BUN_VER, 1.4.2) whose global
# directory is $SANDBOX/bunglobal (named by `bun pm ls -g`, as Bun does);
# bun_dep NAME SPEC VERSION [REALNAME] adds a global package.
bun_fixture() {
  mkdir -p "$SANDBOX/bunglobal/node_modules"
  printf '{"dependencies":{}}' >"$SANDBOX/bunglobal/package.json"
  cat >"$STUB_BIN/bun" <<'EOF'
#!/bin/sh
printf '%s %s\n' bun "$*" >>"$CALL_LOG"
case "$1 $2" in
  "--version "*) echo "${BUN_VER:-1.4.2}" ;;
  "pm ls") echo "$SANDBOX/bunglobal node_modules (1)" ;;
  "pm cache") [ "$3" = rm ] || echo "$SANDBOX/buncache" ;;
esac
exit 0
EOF
  chmod 755 "$STUB_BIN/bun"
}
bun_dep() {
  local g="$SANDBOX/bunglobal" deps
  deps="$(sed -e 's/^{"dependencies":{//' -e 's/}}$//' "$g/package.json")"
  printf '{"dependencies":{%s"%s":"%s"}}' "${deps:+$deps,}" "$1" "$2" >"$g/package.json"
  mkdir -p "$g/node_modules/$1"
  printf '{"name":"%s","version":"%s"}' "${4:-$1}" "$3" >"$g/node_modules/$1/package.json"
}

@test "bun: without a cooldown: standalone upgrade, global update, cache rm -g" {
  bun_fixture
  run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  diff "$CALL_LOG" - <<'EOF'
bun upgrade
bun update -g
bun pm cache rm -g
EOF
}

@test "bun: the cooldown moves each global within its saved range with bun update -g NAME@VERSION (S4)" {
  need_node
  npm_fixture
  bun_fixture
  bun_dep ms '^2.1.1' 2.1.1
  bun_dep @types/node '~26.5.0' 26.5.0
  bun_dep is-number 6.0.0 6.0.0
  bun_dep kleur-alias 'npm:kleur@4.0.0' 4.0.0 kleur
  npm_view ms 2.1.3 2.1.1:900 2.1.2:800 2.1.3:700
  npm_view @types/node 26.6.4 26.5.0:60 26.5.1:50 26.6.0:40 26.6.4:1
  npm_view is-number 7.0.0 6.0.0:900 7.0.0:800
  npm_view bun 1.4.2 1.4.2:30
  CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  grep -E '^bun (update|upgrade|pm cache rm)' "$CALL_LOG" >"$SANDBOX/mutating"
  diff "$SANDBOX/mutating" - <<'EOF'
bun update -g ms@2.1.3
bun update -g @types/node@26.5.1
bun pm cache rm -g
EOF
  refute grep -q 'minimum-release-age' "$CALL_LOG" # Bun's own flag fails and downgrades
  [[ "$output" == *"is-number: pinned to 6.0.0 — left alone"* ]] || false
  [[ "$output" == *"skipping kleur-alias: an aliased install"* ]] || false
}

@test "bun: under the cooldown 'bun upgrade' is held (it cannot be told a version), noted when a newer Bun exists" {
  need_node
  npm_fixture
  bun_fixture
  npm_view bun 1.5.0 1.4.2:60 1.5.0:20
  CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  refute grep -q '^bun upgrade' "$CALL_LOG"
  [[ "$output" == *"bun upgrade skipped during the 7-day cooldown"* ]] || false
  grep -qx $'note\tbun upgrade held by the 7-day cooldown — run \'bun upgrade\' yourself' "$SANDBOX/report"
  : >"$SANDBOX/report"
  npm_view bun 1.4.2 1.4.2:60 # already the newest: nothing to hold
  CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 33-bun.sh
  [[ "$output" == *"bun 1.4.2 is up to date"* ]] || false
  [ ! -s "$SANDBOX/report" ]
}

@test "bun: with the cooldown on but no node/npm, global updates and the upgrade are held" {
  bun_fixture
  bun_dep ms '^2.1.1' 2.1.1
  CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  refute grep -Eq '^bun (update|upgrade)' "$CALL_LOG"
  grep -qx 'bun pm cache rm -g' "$CALL_LOG"
  [[ "$output" == *"global updates are held"* ]] || false
}

@test "bun and deno: managed installs are never self-upgraded in place (D4)" {
  brew_formula_tool bun
  brew_formula_tool deno
  run run_cleaner 33-bun.sh
  refute grep -q '^bun upgrade' "$CALL_LOG"
  run run_cleaner 34-deno.sh
  [ "$status" -eq 0 ]
  refute grep -q '^deno upgrade' "$CALL_LOG"
  [[ "$output" == *Homebrew-managed* ]] || false
}

@test "deno: standalone runs deno upgrade; clean-only skips" {
  make_stub deno
  run run_cleaner 34-deno.sh
  [ "$status" -eq 0 ]
  diff "$CALL_LOG" - <<'EOF'
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
  diff "$CALL_LOG" - <<'EOF'
claude update
EOF
}

@test "claude: a brew formula-style install is deferred to the homebrew cleaner (D4)" {
  brew_formula_tool claude
  run run_cleaner 45-claude.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *Homebrew-managed* ]] || false
  [ ! -s "$CALL_LOG" ]
}

@test "claude: a binary-only Homebrew cask is upgraded by name (claude update would no-op)" {
  brew_cask_tool claude claude-code
  run run_cleaner 45-claude.sh
  [ "$status" -eq 0 ]
  diff "$CALL_LOG" - <<'EOF'
brew upgrade --cask claude-code
EOF
}

@test "claude: npm-managed install (under brew prefix!) is deferred to the npm cleaner (D4 ordering)" {
  npm_global_tool claude @anthropic-ai/claude-code
  run run_cleaner 45-claude.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *npm-managed* ]] || false
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
  [[ "$output" == *"predates 'codex update'"* ]] || false
}

@test "codex: npm installs are left to the npm cleaner (cooldown applies there)" {
  npm_global_tool codex @openai/codex
  run run_cleaner 46-codex.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *npm-managed* ]] || false
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
  diff "$CALL_LOG" - <<'EOF'
brew upgrade --cask copilot-cli
EOF
}

@test "gemini: no command is ever run (no self-update exists)" {
  make_stub gemini
  run run_cleaner 47-gemini.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"no self-update command"* ]] || false
  [ ! -s "$CALL_LOG" ]
  rm -f "$STUB_BIN/gemini"
  brew_formula_tool gemini
  run run_cleaner 47-gemini.sh
  [[ "$output" == *"deprecated"* ]] || false
  [ ! -s "$CALL_LOG" ]
}

# gh_stub AUTH_RC EXTENSIONS [UPGRADE_RC] — `gh auth status` exits AUTH_RC,
# `gh extension list` prints EXTENSIONS (one per line, no quotes).
gh_stub() {
  cat >"$STUB_BIN/gh" <<EOF
#!/bin/sh
printf '%s %s\n' gh "\$*" >>"\$CALL_LOG"
case "\$1 \$2" in
  "auth status") exit $1 ;;
  "extension list") printf '%s' "$2" ;;
  "extension upgrade") exit ${3:-0} ;;
esac
exit 0
EOF
  chmod 755 "$STUB_BIN/gh"
}

@test "gh: logged in with extensions — upgrades them all; a real failure fails the cleaner" {
  gh_stub 0 'dlvhdr/gh-dash'
  run run_cleaner 48-gh.sh
  [ "$status" -eq 0 ]
  diff "$CALL_LOG" - <<'EOF'
gh auth status
gh extension list
gh extension upgrade --all
EOF
  gh_stub 0 'dlvhdr/gh-dash' 1
  run run_cleaner 48-gh.sh
  [ "$status" -eq 1 ]
}

@test "gh: not logged in — skipped with the reason; no extension command runs (they would exit 4)" {
  gh_stub 1 'dlvhdr/gh-dash'
  run run_cleaner 48-gh.sh
  [ "$status" -eq 75 ]
  [[ "$output" == *"gh is not logged in"* ]] || false
  diff "$CALL_LOG" - <<'EOF'
gh auth status
EOF
}

@test "gh: no extensions installed — skipped" {
  gh_stub 0 ''
  run run_cleaner 48-gh.sh
  [ "$status" -eq 75 ]
  [[ "$output" == *"no gh extensions installed"* ]] || false
  refute grep -q 'extension upgrade' "$CALL_LOG"
}

@test "gh: status reports extensions only when logged in" {
  gh_stub 0 'dlvhdr/gh-dash'
  CMM_MODE=status run run_cleaner 48-gh.sh
  grep -qx 'gh extension list' "$CALL_LOG"
  : >"$CALL_LOG"
  gh_stub 1 ''
  CMM_MODE=status run run_cleaner 48-gh.sh
  refute grep -q 'gh extension' "$CALL_LOG"
  [[ "$output" == *"gh is not logged in"* ]] || false
}

@test "cursor: standalone runs 'cursor-agent update'; cask installs upgrade the cask" {
  make_stub cursor-agent
  run run_cleaner 49-cursor.sh
  [ "$status" -eq 0 ]
  diff "$CALL_LOG" - <<'EOF'
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
  diff "$CALL_LOG" - <<'EOF'
rustup update
EOF
  : >"$CALL_LOG"
  CMM_MODE=status run run_cleaner 50-rustup.sh
  diff "$CALL_LOG" - <<'EOF'
rustup check
EOF
}

@test "rustup: 'rustup check' exiting 100 (updates available, rustup >= 1.29) is not a warning" {
  make_stub_script rustup <<'EOF'
[ "$1" = check ] && { echo "stable-aarch64-apple-darwin - Update available : 1.90.0 -> 1.91.0"; exit 100; }
exit 0
EOF
  CMM_MODE=status run run_cleaner 50-rustup.sh
  [[ "$output" == *"Update available"* ]] || false
  [[ "$output" != *"exited 100"* ]] || false
  make_stub_script rustup <<'EOF'
[ "$1" = check ] && exit 1
exit 0
EOF
  CMM_MODE=status run run_cleaner 50-rustup.sh
  [[ "$output" == *"report 'rustup' exited 1"* ]] || false
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
  grep -v 'config --global home' "$CALL_LOG" >"$SANDBOX/calls"
  diff "$SANDBOX/calls" - <<'EOF'
composer global update --no-interaction
composer clear-cache
EOF
  : >"$CALL_LOG"
  CMM_MODE=clean run run_cleaner 51-composer.sh
  grep -v 'config --global home' "$CALL_LOG" >"$SANDBOX/calls"
  diff "$SANDBOX/calls" - <<'EOF'
composer clear-cache
EOF
}

@test "composer: without global packages, no 'global update' is attempted (it would error)" {
  composer_stub
  run run_cleaner 51-composer.sh
  [ "$status" -eq 0 ]
  refute grep -q 'global update' "$CALL_LOG"
  grep -qx 'composer clear-cache' "$CALL_LOG"
  [[ "$output" == *"no global Composer packages"* ]] || false
}

@test "go: build cache only — never the module cache; opt-in by default" {
  make_stub go
  run run_cleaner 52-go.sh
  [ "$status" -eq 0 ]
  diff "$CALL_LOG" - <<'EOF'
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
  diff "$CALL_LOG" - <<'EOF'
cargo install-update -a
EOF
}

@test "mise: non-interactive self-update (-y), outdated report, cache clear" {
  make_stub mise
  run run_cleaner 55-mise.sh
  [ "$status" -eq 0 ]
  diff "$CALL_LOG" - <<'EOF'
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
  diff "$CALL_LOG" - <<'EOF'
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
  diff "$CALL_LOG" - <<'EOF'
kubectl krew upgrade
EOF
  [[ "$output" == *"+ kubectl krew upgrade"* ]] || false
}

@test "krew: a plugin that fails to upgrade fails the cleaner, though krew exits 0" {
  make_stub kubectl-krew
  make_stub_script kubectl <<'EOF'
if [ "$1 $2" = "krew upgrade" ]; then
  echo 'Upgrading plugin: ctx' >&2
  echo 'WARNING: failed to upgrade plugin "ctx", skipping (error: download failed)' >&2
  echo 'WARNING: Some plugins failed to upgrade, check logs above.' >&2
fi
exit 0
EOF
  run run_cleaner 61-krew.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *'failed to upgrade plugin "ctx"'* ]] || false # krew's own output is shown
  [[ "$output" == *"some plugins failed to upgrade"* ]] || false
}

@test "krew: a failing 'kubectl krew upgrade' fails the cleaner; dry-run runs nothing" {
  make_stub kubectl-krew
  make_stub kubectl 1
  run run_cleaner 61-krew.sh
  [ "$status" -eq 1 ]
  : >"$CALL_LOG"
  make_stub kubectl
  CMM_DRY_RUN=1 run run_cleaner 61-krew.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ kubectl krew upgrade"* ]] || false
  [ ! -s "$CALL_LOG" ]
}

@test "vscode: updates extensions from the CLI" {
  make_stub code
  run run_cleaner 62-vscode.sh
  [ "$status" -eq 0 ]
  diff "$CALL_LOG" - <<'EOF'
code --update-extensions
EOF
}

# ---------- xcode ----------

# A full-Xcode developer dir, a plutil that reads "KEY=VALUE" fixture plists
# (portable to Linux CI), an idle pgrep (Xcode not running) and a logging
# xcrun: no xcode test may ever reach the host's real Xcode tools.
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

# unreadable DIR — chmod 000 DIR, or skip when that cannot hide it (root).
unreadable() {
  chmod 000 "$1"
  if ls "$1" >/dev/null 2>&1; then
    chmod 755 "$1"
    skip "chmod 000 does not hide a folder from this user (root?)"
  fi
}

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
  [[ "$output" == *"not opened in Xcode for 45 days"* ]] || false
}

@test "xcode: DerivedData whose project is verifiably gone is purged regardless of age" {
  xcode_env
  mkdir -p "$DD/Gone-xyz" "$SANDBOX/projects"
  printf 'LastAccessedDate=%s\nWorkspacePath=%s\n' "$(ago_iso 1)" "$SANDBOX/projects/Proj.xcodeproj" >"$DD/Gone-xyz/info.plist"
  run run_cleaner 70-xcode.sh
  [ "$status" -eq 0 ]
  [ ! -d "$DD/Gone-xyz" ]
  [[ "$output" == *"no longer exists"* ]] || false
}

@test "xcode: a project in a folder this run cannot read is unknown, not gone (macOS privacy protection)" {
  xcode_env
  mkdir -p "$SANDBOX/Documents/Proj" "$DD/Locked-abc"
  printf 'LastAccessedDate=%s\nWorkspacePath=%s\n' "$(ago_iso 1)" "$SANDBOX/Documents/Proj/Proj.xcodeproj" >"$DD/Locked-abc/info.plist"
  unreadable "$SANDBOX/Documents"
  run run_cleaner 70-xcode.sh
  chmod 755 "$SANDBOX/Documents"
  [ "$status" -eq 0 ]
  [ -d "$DD/Locked-abc" ] # recently used, project state unknown: kept
  [[ "$output" != *"no longer exists"* ]] || false
}

@test "xcode: a project whose folder is missing too (an unmounted volume) is unknown, not gone" {
  xcode_env
  mkdir -p "$DD/External-abc" "$DD/OldExternal-def"
  printf 'LastAccessedDate=%s\nWorkspacePath=%s\n' "$(ago_iso 1)" "$SANDBOX/Volumes/USB/Proj/Proj.xcodeproj" >"$DD/External-abc/info.plist"
  printf 'LastAccessedDate=%s\nWorkspacePath=%s\n' "$(ago_iso 40)" "$SANDBOX/Volumes/USB/Old/Old.xcodeproj" >"$DD/OldExternal-def/info.plist"
  run run_cleaner 70-xcode.sh
  [ "$status" -eq 0 ]
  [ -d "$DD/External-abc" ]     # unknown project, recently used: kept
  [ ! -d "$DD/OldExternal-def" ] # the age rule still applies
  [[ "$output" == *"not opened in Xcode for 40 days"* ]] || false
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

@test "xcode: nothing is touched while Xcode is running — not even simulators" {
  xcode_env
  printf '#!/bin/sh\nexit 0\n' >"$STUB_BIN/pgrep" # Xcode is running
  mkdir -p "$DD/Stale-abc"
  printf 'LastAccessedDate=%s\n' "$(ago_iso 99)" >"$DD/Stale-abc/info.plist"
  run run_cleaner 70-xcode.sh
  [ "$status" -eq 0 ]
  [ -d "$DD/Stale-abc" ]
  refute grep -q simctl "$CALL_LOG"
  [[ "$output" == *"Xcode is running"* ]] || false
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
  [[ "$output" == *"needs a full Xcode"* ]] || false
}

@test "xcode: dry-run lists what would go and deletes nothing" {
  xcode_env
  mkdir -p "$DD/Stale-abc"
  printf 'LastAccessedDate=%s\n' "$(ago_iso 99)" >"$DD/Stale-abc/info.plist"
  CMM_DRY_RUN=1 run run_cleaner 70-xcode.sh
  [ "$status" -eq 0 ]
  [ -d "$DD/Stale-abc" ]
  [[ "$output" == *"+ rm -rf $DD/Stale-abc"* ]] || false
  refute grep -q simctl "$CALL_LOG"
}

@test "xcode: no Xcode and no leftovers — skips, never reaching the host's xcrun" {
  printf '#!/bin/sh\nexit 2\n' >"$STUB_BIN/xcode-select" # no developer dir selected
  chmod 755 "$STUB_BIN/xcode-select"
  make_stub xcrun
  run run_cleaner 70-xcode.sh
  [ "$status" -eq 75 ]
  [ ! -s "$CALL_LOG" ]
}

@test "xcode: the gate names DerivedData too, so 'scrubmac list' sees leftovers without Xcode" {
  grep -qx '# gate: xcodebuild ~/Library/Developer/Xcode/DerivedData' "$REPO_ROOT/cleaners/70-xcode.sh"
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

# uv_receipt DIR PREFIX — the standalone installer's receipt in DIR, for a
# uv installed into PREFIX.
uv_receipt() {
  mkdir -p "$1"
  printf '{"binaries":["uv","uvx"],"install_layout":"flat","install_prefix":"%s","modify_path":true,"source":{"app_name":"uv","name":"uv","owner":"astral-sh","release_type":"github"},"version":"0.12.22"}\n' "$2" >"$1/uv-receipt.json"
}

# uv_tool NAME [RECEIPT-OPTION-LINE…] — an installed uv tool and its receipt.
uv_tool() {
  local name="$1"
  shift
  mkdir -p "$SANDBOX/uvtools/$name"
  {
    printf '[tool]\nrequirements = [{ name = "%s" }]\n\n[tool.options]\n' "$name"
    if [ "$#" -gt 0 ]; then
      printf '%s\n' "$@"
    fi
  } >"$SANDBOX/uvtools/$name/uv-receipt.toml"
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

@test "python: uv self-update (installer receipt), tool upgrades, pipx, prune, pip purge" {
  uv_stub
  uv_receipt "$XDG_CONFIG_HOME/uv" "$STUB_BIN"
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

@test "python: 'uv self update' only runs for the uv the standalone installer manages (it exits 2 otherwise)" {
  uv_stub
  run run_cleaner 40-python.sh # pip/cargo/conda… uv: no receipt
  [ "$status" -eq 0 ]
  refute grep -q '^uv self update' "$CALL_LOG"
  [[ "$output" == *"uv was not installed by its standalone installer"* ]] || false
  uv_receipt "$XDG_CONFIG_HOME/uv" "$SANDBOX/elsewhere/bin" # the installer's copy is another one
  mkdir -p "$SANDBOX/elsewhere/bin"
  : >"$CALL_LOG"
  run run_cleaner 40-python.sh
  refute grep -q '^uv self update' "$CALL_LOG"
  rm -rf "$XDG_CONFIG_HOME/uv"
  uv_receipt "$SANDBOX/axo" "$STUB_BIN" # AXOUPDATER_CONFIG_PATH wins, as in uv
  : >"$CALL_LOG"
  AXOUPDATER_CONFIG_PATH="$SANDBOX/axo" run run_cleaner 40-python.sh
  grep -qx 'uv self update' "$CALL_LOG"
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
  [[ "$output" == *"pipx predates --cooldown"* ]] || false
}

@test "python: with the cooldown off, cutoffs remembered in uv receipts are cleared per tool; pipx gets --cooldown 0" {
  uv_stub
  pipx_stub with-cooldown
  uv_tool ruff 'exclude-newer = "2025-01-01T00:00:00Z"'
  uv_tool black 'exclude-newer = "2026-09-27T00:00:00Z"' 'exclude-newer-span = "P7D"'
  uv_tool mypy 'exclude-newer = false'
  uv_tool httpie
  run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  grep -E '^(uv tool upgrade|pipx upgrade-all)( |$)' "$CALL_LOG" | grep -v -- --help >"$SANDBOX/upgrades"
  diff "$SANDBOX/upgrades" - <<'EOF'
uv tool upgrade black --exclude-newer false
uv tool upgrade ruff --exclude-newer false
uv tool upgrade --all
pipx upgrade-all --cooldown 0
EOF
}

@test "python: uv < 0.11.24 cannot clear receipt cutoffs — a summary note says so" {
  uv_stub
  uv_tool black 'exclude-newer = "2026-09-27T00:00:00Z"' 'exclude-newer-span = "P7D"'
  UV_VER=0.11.10 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  refute grep -q -- '--exclude-newer false' "$CALL_LOG"
  grep -qx 'uv tool upgrade --all' "$CALL_LOG"
  grep -qx $'note\t1 uv tool(s) still held back by an exclude-newer cutoff in their receipts' "$SANDBOX/report"
}

@test "python: your own exclude-newer (uv.toml or UV_EXCLUDE_NEWER) and PIPX_COOLDOWN are respected" {
  uv_stub
  pipx_stub with-cooldown
  uv_tool black 'exclude-newer-span = "P7D"' 'exclude-newer = "2026-09-27T00:00:00Z"'
  mkdir -p "$XDG_CONFIG_HOME/uv"
  printf 'exclude-newer = "3 days"\n' >"$XDG_CONFIG_HOME/uv/uv.toml"
  PIPX_COOLDOWN=3 run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  refute grep -q -- '--exclude-newer false' "$CALL_LOG"
  [[ "$output" == *"your uv settings define exclude-newer"* ]] || false
  grep -qx 'pipx upgrade-all' "$CALL_LOG"
  rm "$XDG_CONFIG_HOME/uv/uv.toml"
  : >"$CALL_LOG"
  UV_EXCLUDE_NEWER='5 days' run run_cleaner 40-python.sh
  refute grep -q -- '--exclude-newer false' "$CALL_LOG"
}

@test "python: a busy uv cache is skipped with a note — never hung on, never --force'd" {
  uv_stub
  PRUNE_MODE=busy run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"uv cache is in use"* ]] || false
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
  [[ "$output" == *"skipping 'uv cache prune'"* ]] || false
  refute grep -q '^uv cache prune' "$CALL_LOG"
}

@test "python: a Homebrew-managed uv is not self-updated (its build refuses)" {
  brew_formula_tool uv
  cat >"$SANDBOX/brewpfx/Cellar/uv/1.0.0/bin/uv" <<'EOF'
#!/bin/sh
printf '%s %s\n' uv "$*" >>"$CALL_LOG"
[ "$1" = --version ] && echo "uv 0.12.22 (Homebrew)"
exit 0
EOF
  uv_receipt "$XDG_CONFIG_HOME/uv" "$SANDBOX/brewpfx/bin" # even with a stray receipt
  run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  refute grep -q '^uv self update' "$CALL_LOG"
  [[ "$output" == *"uv is Homebrew-managed"* ]] || false
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
  [[ "$output" == *"frozen"* ]] || false
}

@test "conda: standalone micromamba self-updates and cleans" {
  make_stub micromamba
  run run_cleaner 41-conda.sh
  [ "$status" -eq 0 ]
  diff "$CALL_LOG" - <<'EOF'
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
  [[ "$output" == *"no Poetry caches to clear"* ]] || false
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
  [[ "$output" == *"system Ruby"* ]] || false
  refute grep -q 'cleanup' "$CALL_LOG"
}

# ---------- pre-commit / cocoapods / swiftpm ----------

# pc_env CONFIG… — pre-commit with a store whose db records CONFIGs (as the
# sqlite3 stub reports them).
pc_env() {
  make_stub pre-commit
  mkdir -p "$HOME/.cache/pre-commit"
  : >"$HOME/.cache/pre-commit/db.db"
  printf '%s\n' "$@" >"$SANDBOX/pc-configs"
  make_stub_script sqlite3 <<'EOF'
cat "$SANDBOX/pc-configs"
EOF
}

@test "pre-commit: garbage-collects unused hook environments" {
  make_stub pre-commit
  run run_cleaner 63-pre-commit.sh
  [ "$status" -eq 0 ]
  diff "$CALL_LOG" - <<'EOF'
pre-commit gc
EOF
}

@test "pre-commit: a recorded config that is really gone does not block gc" {
  mkdir -p "$SANDBOX/code" "$SANDBOX/code/live"
  : >"$SANDBOX/code/live/.pre-commit-config.yaml"
  pc_env "$SANDBOX/code/old/.pre-commit-config.yaml" "$SANDBOX/code/live/.pre-commit-config.yaml"
  run run_cleaner 63-pre-commit.sh
  [ "$status" -eq 0 ]
  grep -qx "sqlite3 -readonly $HOME/.cache/pre-commit/db.db SELECT path FROM configs" "$CALL_LOG"
  grep -qx 'pre-commit gc' "$CALL_LOG"
}

@test "pre-commit: a recorded config inside a folder this run cannot read skips gc (macOS privacy protection)" {
  mkdir -p "$HOME/Documents/proj"
  pc_env "$HOME/Documents/proj/.pre-commit-config.yaml"
  unreadable "$HOME/Documents"
  CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 63-pre-commit.sh
  chmod 755 "$HOME/Documents"
  [ "$status" -eq 0 ]
  refute grep -q 'pre-commit gc' "$CALL_LOG"
  [[ "$output" == *"skipping 'pre-commit gc'"* ]] || false
  grep -q $'^note\tpre-commit gc skipped: a recorded config is inside '"$HOME/Documents" "$SANDBOX/report"
}

@test "pre-commit: a recorded config on an unmounted volume skips gc" {
  pc_env "/Volumes/scrubmac-test-absent-$$/proj/.pre-commit-config.yaml"
  run run_cleaner 63-pre-commit.sh
  [ "$status" -eq 0 ]
  refute grep -q 'pre-commit gc' "$CALL_LOG"
  [[ "$output" == *"/Volumes/scrubmac-test-absent-$$, which is not mounted"* ]] || false
}

@test "pre-commit: without sqlite3, an unreadable protected folder blocks gc; readable ones do not" {
  make_stub pre-commit
  mkdir -p "$HOME/.cache/pre-commit" "$HOME/Documents"
  : >"$HOME/.cache/pre-commit/db.db"
  run run_cleaner 63-pre-commit.sh # no sqlite3 on PATH
  grep -qx 'pre-commit gc' "$CALL_LOG"
  : >"$CALL_LOG"
  unreadable "$HOME/Documents"
  run run_cleaner 63-pre-commit.sh
  chmod 755 "$HOME/Documents"
  [ "$status" -eq 0 ]
  refute grep -q 'pre-commit gc' "$CALL_LOG"
  [[ "$output" == *"$HOME/Documents cannot be read by this run"* ]] || false
}

@test "cocoapods: clears the pod download cache (--all: no prompt)" {
  make_stub pod
  run run_cleaner 71-cocoapods.sh
  [ "$status" -eq 0 ]
  diff "$CALL_LOG" - <<'EOF'
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
kubectl-krew code pre-commit xcode-select xcrun pod swift"

# sweep_stubs — a stub for every tool, answering like current releases so
# the version-gated branches run (yarn 1.22, bun 1.3, uv 0.12, pipx with
# --cooldown, pnpm 12, a full Xcode, a logged-in gh with an extension), with
# something to act on (an outdated npm global, pnpm and bun globals, a uv
# receipt cutoff, a global Composer project) and node for the resolver.
sweep_stubs() {
  local t
  need_node
  for t in $ALL_TOOLS; do make_stub "$t"; done
  make_stub yarn 0 1.22.22
  make_stub bun 0 1.3.13
  make_stub pnpm 0 12.6.0
  make_stub_script uv <<EOF
case "\$1 \$2" in
  "--version "*) echo "uv 0.12.22" ;;
  "tool dir") echo "$SANDBOX/uvtools" ;;
  "cache dir") echo "$SANDBOX/uvcache" ;;
esac
exit 0
EOF
  uv_tool black 'exclude-newer-span = "P7D"' 'exclude-newer = "2026-09-27T00:00:00Z"'
  uv_receipt "$XDG_CONFIG_HOME/uv" "$STUB_BIN"
  pipx_stub with-cooldown
  gh_stub 0 'dlvhdr/gh-dash'
  make_stub_script codex <<'EOF'
[ "$1" = --help ] && printf 'Commands:\n  update    Update Codex\n'
exit 0
EOF
  make_stub_script copilot <<'EOF'
[ "$1" = --help ] && printf 'Commands:\n  update    Update the CLI\n'
exit 0
EOF
  mkdir -p "$SANDBOX/Xcode.app/Contents/Developer" "$SANDBOX/composer-home"
  make_stub_script xcode-select <<EOF
echo "$SANDBOX/Xcode.app/Contents/Developer"
EOF
  printf '{"require":{}}\n' >"$SANDBOX/composer-home/composer.json"
  make_stub_script composer <<EOF
[ "\$1 \$2 \$3" = "config --global home" ] && echo "$SANDBOX/composer-home"
exit 0
EOF
  make_stub_script gem <<EOF
[ "\$1 \$2" = "env gemdir" ] && echo "$SANDBOX/gems"
exit 0
EOF
  npm_fixture
  npm_globals plain:1.0.0:1.1.0
  npm_view plain 1.1.0 1.0.0:90 1.1.0:60
  npm_view pnpm 12.7.0 12.6.0:90 12.7.0:60
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700
  pnpm_globals g1=ms@2.1.1
  make_stub_script pnpm <<'EOF'
case "$1" in
  --version) echo 12.6.0 ;;
  ls) cat "$SANDBOX/pnpm-ls.json" ;;
esac
exit 0
EOF
  bun_fixture
  BUN_VER=1.3.13 bun_dep ms '^2.1.1' 2.1.1
  printf '#!/bin/sh\nexit 1\n' >"$STUB_BIN/pgrep" # Xcode not running
  chmod 755 "$STUB_BIN/pgrep"
}

# The read-only commands `scrubmac status` may execute: reports, cache
# lookups and the probes they depend on.
STATUS_ALLOW='^brew (--cache|outdated)$
^mas outdated$
^npm (config get cache|outdated -g)$
^pnpm (store path|outdated -g)$
^yarn (--version|cache dir)$
^bun pm cache -g$
^uv (--version|cache dir --color never|tool list --outdated)$
^python3 -m pip cache dir$
^poetry config cache-dir$
^conda update -n base conda --dry-run$
^gh (auth status|extension list)$
^rustup check$
^composer (config --global (home|cache-dir)|global outdated)$
^go env GOCACHE$
^cargo install-update -l$
^gem env gemdir$
^mise outdated$
^docker (info|system df)$
^kubectl krew list$
^xcode-select -p$'

# …and those a --dry-run may execute: also previews, version/help probes and
# the read-only queries an update plan is computed from.
DRYRUN_ALLOW="$STATUS_ALLOW"'
 --dry-run( |$)
^gem cleanup -d$
^[a-z-]+ (--version|--help)$
^npm (outdated -g --json|ls -g --long --json|root -g|view .+)$
^pnpm (--version|ls -g --depth=0 --json)$
^bun (--version|pm ls -g)$
^uv tool dir --color never$
^pipx upgrade-all --help$
^python3 -m pip --version$
^conda info --base$
^poetry cache list$'

# sweep MODE-ENV ALLOWLIST — run every built-in cleaner with and without the
# cooldown under MODE-ENV, then check each executed command is allowlisted.
sweep() {
  local c days
  sweep_stubs
  for days in 0 7; do
    for c in "$REPO_ROOT"/cleaners/*.sh; do
      env "$1" CMM_COOLDOWN_DAYS="$days" CMM_LIB="$CMM_LIB_PATH" "$c" >/dev/null 2>&1 </dev/null || true
    done
  done
  printf '%s\n' "$2" >"$SANDBOX/allow"
  [ -s "$CALL_LOG" ]
  if grep -Ev -f "$SANDBOX/allow" "$CALL_LOG" >"$SANDBOX/unexpected"; then
    echo "not allowlisted:" >&2
    cat "$SANDBOX/unexpected" >&2
    return 1
  fi
}

@test "status mode only ever executes allowlisted read-only commands, in every built-in cleaner" {
  sweep CMM_MODE=status "$STATUS_ALLOW"
  grep -qx 'gh extension list' "$CALL_LOG" # the sweep reached the gated reports
  grep -qx 'uv tool list --outdated' "$CALL_LOG"
}

@test "dry-run only ever executes allowlisted read-only commands, in every built-in cleaner" {
  sweep CMM_DRY_RUN=1 "$DRYRUN_ALLOW"
  grep -q '^npm view plain ' "$CALL_LOG" # the sweep reached the cooldown resolver
  grep -qx 'pnpm ls -g --depth=0 --json' "$CALL_LOG"
  grep -qx 'yarn --version' "$CALL_LOG"
}
