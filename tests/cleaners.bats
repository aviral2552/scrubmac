#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# Per-cleaner tests against PATH stubs: exact argv sequences, skip-when-absent,
# modes (update/clean/status/dry-run), offline behavior, install-kind
# deferral (D4), the supply-chain cooldown (S4) and its resolver
# (lib/registry.cjs), and the regression pins (F4–F8, D3). Commands and flags
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

# reg ARGS… — run lib/registry.cjs directly (resolver unit tests).
reg() { "$REAL_NODE" "$REPO_ROOT/lib/registry.cjs" "$@"; }

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
# <pkg> time versions dist-tags --json`, and the `versions dist-tags` form;
# an "error" object there makes it exit 1, as npm does on E404),
# meta-<pkg>.json (`npm view "<pkg>@<v1> || …" name version deprecated
# engines --json`) and config-<key> (`npm config get <key>`; "null" when
# absent; `npm --version` prints $NPM_VER, 11.0.0); "/" and "@" in names
# become "__" and "AT". `npm root -g` is
# $SANDBOX/npmfx/root. The stub lives inside a fake npm package
# ($SANDBOX/npmpkg, linked from the stub dir) so the resolver finds a semver
# there when a test plants one.
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
  --version) echo "${NPM_VER:-11.0.0}"; exit 0 ;;
  config) [ -f "$fx/config-$3" ] && cat "$fx/config-$3" || echo null; exit 0 ;;
  view)
    case "$3" in
      time | versions) f="$fx/view-$(key "$2").json" ;;
      *) f="$fx/meta-$(key "${2%@*}").json" ;;
    esac
    [ -f "$f" ] || exit 1
    cat "$f"
    grep -q '"error"' "$f" && exit 1
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

# ---------- registry resolver (lib/registry.cjs) ----------

@test "registry pick: a prerelease moves to its own stable release once that is old enough" {
  need_node
  run reg pick x 2.0.0-beta.1 "$(ago 7)" latest <<<"$(view_json 2.0.0 1.0.0:90 2.0.0-beta.1:60 2.0.0-beta.2:50 2.0.0:30)"
  [ "$status" -eq 0 ]
  [ "$output" = $'pick\t2.0.0\t2.0.0-beta.2' ]
}

@test "registry pick: prereleases only for an installed prerelease of the same version" {
  need_node
  # 2.0.0 and latest (2.2.0) are too fresh: beta.2 of the same version — never
  # 2.1.0-beta.1, which only the same-version rule keeps out (it is mature
  # and below latest)
  run reg pick x 2.0.0-beta.1 "$(ago 7)" latest <<<"$(view_json 2.2.0 2.0.0-beta.1:60 2.0.0-beta.2:50 2.0.0:1 2.1.0-beta.1:40 2.2.0:1)"
  [ "$output" = $'pick\t2.0.0-beta.2' ]
  # a stable install never moves to a prerelease
  run reg pick x 1.0.0 "$(ago 7)" latest <<<"$(view_json 1.0.0 1.0.0:90 1.1.0-rc.1:60)"
  [ "$output" = none ]
}

@test "registry pick: a prerelease of another version is never a candidate, even far below latest" {
  need_node
  # latest (3.0.0) is above everything, so only the same-version rule keeps 2.1.0-beta.1 out
  run reg pick x 2.0.0-beta.1 "$(ago 7)" latest <<<"$(view_json 3.0.0 2.0.0-beta.1:60 2.0.0-beta.2:50 2.1.0-beta.1:40 3.0.0:30)"
  [ "$status" -eq 0 ]
  [ "$output" = $'pick\t3.0.0\t2.0.0-beta.2' ]
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

@test "registry pick: an installed version the registry never had is foreign; an unknown package is missing" {
  need_node
  run reg pick x 0.9.0 "$(ago 7)" latest <<<"$(view_json 1.1.0 1.0.0:90 1.1.0:60)"
  [ "$status" -eq 0 ]
  [ "$output" = foreign ]
  run reg pick x 1.0.0 "$(ago 7)" latest <<<'{"error":{"code":"E404","summary":"Not Found"}}'
  [ "$status" -eq 0 ]
  [ "$output" = missing ]
}

@test "registry pick: other npm errors, no input, unreadable input, a bad mode or cutoff exit 3" {
  need_node
  run reg pick x 1.0.0 "$(ago 7)" latest <<<'{"error":{"code":"ENOTFOUND"}}'
  [ "$status" -eq 3 ]
  run reg pick x 1.0.0 "$(ago 7)" latest </dev/null # npm printed nothing (no network)
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

@test "registry verify: when the installed release is deprecated too, the newest compatible release of the line is accepted" {
  need_node
  run reg verify 1.3.0,1.2.0 --current 1.0.0 <<<'[{"name":"x","version":"1.3.0","deprecated":"use y"},{"name":"x","version":"1.2.0","deprecated":"use y"},{"name":"x","version":"1.0.0","deprecated":"use y"}]'
  [ "$output" = $'ok\t1.3.0\tdeprecated, like the installed 1.0.0' ]
  # a supported installed release never moves onto a deprecated one
  run reg verify 1.3.0 --current 1.0.0 <<<'[{"name":"x","version":"1.3.0","deprecated":"broken"},{"name":"x","version":"1.0.0"}]'
  want $'skip\t1.3.0\tdeprecated: broken' unsuitable
  got
  # engines still count on a deprecated line
  fake_semver "$SANDBOX/npmpkg"
  run reg verify 1.3.0,1.2.0 --current 1.0.0 --semver-dir "$SANDBOX/npmpkg" <<<'[{"name":"x","version":"1.3.0","deprecated":"d","engines":{"node":">=999"}},{"name":"x","version":"1.2.0","deprecated":"d"},{"name":"x","version":"1.0.0","deprecated":"d"}]'
  [ "$output" = $'ok\t1.2.0\tdeprecated, like the installed 1.0.0' ]
}

@test "registry verify: a prerelease Node satisfies plain engine ranges (npm's semver, includePrerelease)" {
  need_node
  local meta='[{"name":"x","version":"1.0.0","engines":{"node":">=18"}}]'
  run reg verify 1.0.0 --node v10.0.0 <<<"$meta"
  [[ "$output" == *"needs node >=18"* ]] || skip "npm's semver is not installed next to this node"
  run reg verify 1.0.0 --node v99.0.0-pre.1 <<<"$meta"
  [ "$output" = $'ok\t1.0.0' ]
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

@test "registry cutoff: the earliest of the ages and dates given; none when nothing applies" {
  need_node
  run reg cutoff --days 0 --minutes '' --before null --seconds 0
  [ "$output" = none ]
  run reg cutoff --days 7 --before 2026-09-01T00:00:00Z
  [ "$output" = 2026-09-01T00:00:00Z ]
  # npm prints its `before` setting as Date#toString()
  run reg cutoff --days 7 --before 'Tue Sep 01 2026 05:30:00 GMT+0530 (India Standard Time)'
  [ "$output" = 2026-09-01T00:00:00Z ]
  local want14
  want14="$("$REAL_NODE" -e 'console.log(new Date(Date.now() - 14 * 864e5).toISOString().slice(0, 13))')"
  run reg cutoff --days 7 --days 14
  [ "${output:0:13}" = "$want14" ]
  run reg cutoff --minutes 1440 --seconds 1209600
  [ "${output:0:13}" = "$want14" ]
}

@test "registry npm-outdated: npm/corepack, linked, aliased, unlisted and ahead-of-latest globals are skipped" {
  need_node
  mkdir -p "$SANDBOX/root/plain" "$SANDBOX/root/aliased" "$SANDBOX/fork"
  printf '{"name":"plain","version":"1.0.0"}' >"$SANDBOX/root/plain/package.json"
  printf '{"name":"kleur","version":"4.0.0"}' >"$SANDBOX/root/aliased/package.json"
  ln -s "$SANDBOX/fork" "$SANDBOX/root/linked"
  # npm 11/12 record no "resolved" for registry, tarball or git globals —
  # only file: for directory installs; "git+…" here is the defensive case
  run reg npm-outdated "$SANDBOX/root" <<'EOF'
{"outdated": {
  "npm": {"current": "11.0.0", "latest": "12.0.0"},
  "corepack": {"current": "0.30.0", "latest": "0.36.0"},
  "plain": {"current": "1.0.0", "wanted": "1.2.0", "latest": "1.2.0"},
  "@scope/pkg": {"current": "2.0.0", "latest": "2.1.0"},
  "ghpkg": {"current": "1.0.0", "latest": "1.1.0"},
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
  "@scope/pkg": {"version": "2.0.0", "name": "@scope/pkg"},
  "ghpkg": {"version": "1.0.0", "resolved": "https://npm.pkg.github.com/download/@o/ghpkg/1.0.0/abc123"},
  "linked": {"version": "6.0.0", "name": "linked"},
  "dirinstall": {"version": "1.0.0", "resolved": "file:../../../dir"},
  "aliased": {"version": "4.0.0"},
  "fromgit": {"version": "1.0.0", "resolved": "git+ssh://git@github.com/u/fromgit.git#abc"},
  "ahead": {"version": "3.0.0"}, "odd": {"version": "1.0.0"}}}}
EOF
  [ "$status" -eq 0 ]
  want $'skip\tnpm\t11.0.0\tself' $'skip\tcorepack\t0.30.0\tself' $'update\tplain\t1.0.0\t1.2.0' \
    $'update\t@scope/pkg\t2.0.0\t2.1.0' $'update\tghpkg\t1.0.0\t1.1.0' $'skip\tlinked\t6.0.0\tlinked' \
    $'skip\tdirinstall\t1.0.0\tlinked' $'skip\taliased\t4.0.0\talias' $'skip\tfromgit\t1.0.0\tsource' \
    $'skip\tunlisted\t1.0.0\tunknown' $'skip\tahead\t3.0.0\tahead' $'skip\todd\tlinked\tversion'
  got
}

@test "registry npm-outdated: an npm error or unreadable input exits 3" {
  need_node
  run reg npm-outdated "$SANDBOX" <<<'{"outdated":{"error":{"code":"ENOTFOUND"}},"ls":{}}'
  [ "$status" -eq 3 ]
  run reg npm-outdated "$SANDBOX" <<<'{"outdated":'
  [ "$status" -eq 3 ]
}

@test "registry pnpm-globals: pnpm >= 11 install groups with their saved ranges; aliases, local installs, pnpm itself" {
  need_node
  local g="$SANDBOX/pnhome/global/v11"
  mkdir -p "$g/g1" "$g/g2" "$g/g3" "$g/g4" "$g/g5" "$g/g6"
  printf '{"dependencies":{"@types/node":"^26.6.2","ms":"2.1.1"}}' >"$g/g1/package.json"
  printf '{"dependencies":{"is-number":"~6.0.0"}}' >"$g/g2/package.json"
  printf '{"dependencies":{"mytool":"link:../../src/mytool","kleur":"^4.0.0"}}' >"$g/g3/package.json"
  printf '{"dependencies":{"kleur-alias":"npm:kleur@4.0.0"}}' >"$g/g4/package.json"
  printf '{"dependencies":{"pnpm":"12.8.1","@pnpm/exe":"12.8.1"}}' >"$g/g5/package.json"
  printf '{"dependencies":{"fromgh":"github:u/fromgh"}}' >"$g/g6/package.json"
  run reg pnpm-globals <<EOF
[{"path": "$g", "private": true, "dependencies": {
  "@types/node": {"from": "@types/node", "version": "26.6.2", "path": "$g/g1/node_modules/@types/node"},
  "ms": {"from": "ms", "version": "2.1.1", "path": "$g/g1/node_modules/ms"},
  "is-number": {"from": "is-number", "version": "6.0.0", "path": "$g/g2/node_modules/is-number"},
  "mytool": {"from": "mytool", "version": "1.0.0", "path": "$g/g3/node_modules/mytool"},
  "kleur": {"from": "kleur", "version": "4.0.0", "path": "$g/g3/node_modules/kleur"},
  "kleur-alias": {"from": "kleur", "version": "4.0.0", "path": "$g/g4/node_modules/kleur-alias"},
  "pnpm": {"from": "pnpm", "version": "12.8.1", "path": "$g/g5/node_modules/pnpm"},
  "@pnpm/exe": {"from": "@pnpm/exe", "version": "12.8.1", "path": "$g/g5/node_modules/@pnpm/exe"},
  "fromgh": {"from": "fromgh", "version": "1.0.0", "path": "$g/g6/node_modules/fromgh"}}}]
EOF
  [ "$status" -eq 0 ]
  want $'skip\tmytool\tlocal' $'skip\tkleur-alias\talias' $'skip\tpnpm\tself' $'skip\t@pnpm/exe\tself' $'skip\tfromgh\tlocal' \
    $'member\t'"$g/g1"$'\t@types/node\t26.6.2\tcaret\t^26.6.2' \
    $'member\t'"$g/g1"$'\tms\t2.1.1\tpinned\t2.1.1' \
    $'member\t'"$g/g2"$'\tis-number\t6.0.0\ttilde\t~6.0.0' \
    $'skip\tkleur\tgroup:mytool'
  got
}

@test "registry pnpm-globals: pnpm 10's single global project — every package on its own (isolated or hoisted)" {
  need_node
  local g="$SANDBOX/pnhome/global/5"
  mkdir -p "$g"
  printf '{"dependencies":{"ms":"^2.1.1","is-number":"6.0.0","hoisted":"^1.0.0","cmm":"link:../../../src/cmm","tarball":"file:../tarball-1.0.0.tgz","ghp":"^1.0.0"}}' >"$g/package.json"
  run reg pnpm-globals <<EOF
[{"path": "$g", "private": false, "dependencies": {
  "ms": {"from": "ms", "version": "2.1.1", "resolved": "https://registry.npmjs.org/ms/-/ms-2.1.1.tgz", "path": "$g/.pnpm/ms@2.1.1/node_modules/ms"},
  "is-number": {"from": "is-number", "version": "6.0.0", "resolved": "https://registry.npmjs.org/is-number/-/is-number-6.0.0.tgz", "path": "$g/.pnpm/is-number@6.0.0/node_modules/is-number"},
  "hoisted": {"from": "hoisted", "version": "1.0.0", "path": "$g/node_modules/hoisted"},
  "ghp": {"from": "ghp", "version": "1.0.0", "resolved": "https://npm.pkg.github.com/download/@o/ghp/1.0.0/abc", "path": "$g/node_modules/ghp"},
  "tarball": {"from": "tarball", "version": "1.0.0", "resolved": "file:../tarball-1.0.0.tgz", "path": "$g/.pnpm/tarball@file+tarball/node_modules/tarball"},
  "cmm": {"from": "cmm", "version": "link:../../../src/cmm", "path": "$SANDBOX/src/cmm"},
  "kleur-alias": {"from": "kleur", "version": "4.1.4", "path": "$g/.pnpm/kleur@4.1.4/node_modules/kleur"}}}]
EOF
  [ "$status" -eq 0 ]
  want $'skip\ttarball\tlocal' $'skip\tcmm\tlocal' $'skip\tkleur-alias\talias' \
    $'member\tsolo:ms\tms\t2.1.1\tcaret\t^2.1.1' $'member\tsolo:is-number\tis-number\t6.0.0\tpinned\t6.0.0' \
    $'member\tsolo:hoisted\thoisted\t1.0.0\tcaret\t^1.0.0' $'member\tsolo:ghp\tghp\t1.0.0\tcaret\t^1.0.0'
  got
  run reg pnpm-globals <<<"[{\"path\": \"$g\", \"private\": false}]" # no globals at all
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "registry pnpm-globals: pnpm >= 11 groups wherever globalDir puts them; --major 10 keeps pnpm 10's single project" {
  need_node
  local g="$SANDBOX/my-global-dir/v11" # global-dir set: no /global/ in the paths
  mkdir -p "$g/grp1" "$g/grp2"
  printf '{"dependencies":{"ms":"^2.1.1","kleur":"4.1.4"}}' >"$g/grp1/package.json"
  printf '{"dependencies":{"@types/node":"~26.6.0"}}' >"$g/grp2/package.json"
  local json
  json="[{\"path\": \"$g\", \"dependencies\": {
    \"ms\": {\"from\": \"ms\", \"version\": \"2.1.1\", \"path\": \"$g/grp1/node_modules/ms\"},
    \"kleur\": {\"from\": \"kleur\", \"version\": \"4.1.4\", \"path\": \"$g/grp1/node_modules/kleur\"},
    \"@types/node\": {\"from\": \"@types/node\", \"version\": \"26.6.0\", \"path\": \"$g/grp2/node_modules/@types/node\"}}}]"
  run reg pnpm-globals --major 11 <<<"$json"
  [ "$status" -eq 0 ]
  want $'member\t'"$g/grp1"$'\tms\t2.1.1\tcaret\t^2.1.1' $'member\t'"$g/grp1"$'\tkleur\t4.1.4\tpinned\t4.1.4' \
    $'member\t'"$g/grp2"$'\t@types/node\t26.6.0\ttilde\t~26.6.0'
  got
  run reg pnpm-globals <<<"$json" # no --major: a vN root means pnpm >= 11
  got
  local p10="$SANDBOX/g10/5"
  mkdir -p "$p10"
  printf '{"dependencies":{"ms":"^2.1.1","kleur":"4.1.4"}}' >"$p10/package.json"
  run reg pnpm-globals --major 10 <<EOF
[{"path": "$p10", "dependencies": {
  "ms": {"from": "ms", "version": "2.1.1", "path": "$p10/node_modules/ms"},
  "kleur": {"from": "kleur", "version": "4.1.4", "path": "$p10/node_modules/kleur"}}}]
EOF
  want $'member\tsolo:ms\tms\t2.1.1\tcaret\t^2.1.1' $'member\tsolo:kleur\tkleur\t4.1.4\tpinned\t4.1.4'
  got
}

@test "registry pnpm-legacy: the packages left in pnpm 10's global project beside pnpm 11's root" {
  need_node
  mkdir -p "$SANDBOX/glob/v11" "$SANDBOX/glob/5"
  run reg pnpm-legacy "$SANDBOX/glob/v11"
  [ -z "$output" ]
  printf '{"dependencies":{"ms":"2.1.1","is-odd":"^2.0.0"}}' >"$SANDBOX/glob/5/package.json"
  run reg pnpm-legacy "$SANDBOX/glob/v11"
  want ms is-odd
  got
}

@test "registry pnpm-outdated: the globals whose latest release is not the installed one" {
  need_node
  # pnpm's "wanted" for globals is the locked version, so it cannot tell
  run reg pnpm-outdated <<<'{"ms":{"current":"2.1.1","latest":"2.1.3","wanted":"2.1.1"},"globby":{"current":"16.2.4","latest":"16.2.4","wanted":"16.2.4"}}'
  [ "$status" -eq 0 ]
  [ "$output" = ms ]
  run reg pnpm-outdated <<<'oops'
  [ "$status" -eq 3 ]
}

@test "registry bun-globals: the saved range decides; pinned, local, linked and aliased are skipped" {
  need_node
  local g="$SANDBOX/bunglobal"
  mkdir -p "$g/node_modules/ms" "$g/node_modules/@types/node" "$g/node_modules/is-number" \
    "$g/node_modules/kleur-alias" "$g/node_modules/tool" "$g/node_modules/anything" \
    "$g/node_modules/ranged" "$SANDBOX/src"
  printf '{"dependencies":{"ms":"^2.1.1","@types/node":"~26.5.0","is-number":"6.0.0","kleur-alias":"npm:kleur@4.0.0","local":"/abs/local","tool":"^1.0.0","anything":"*","ranged":">=1 <3","weird":">=1 <3","gone":"^1.0.0"}}' >"$g/package.json"
  printf '{"name":"ranged","version":"1.5.0"}' >"$g/node_modules/ranged/package.json"
  printf '{"name":"ms","version":"2.1.1"}' >"$g/node_modules/ms/package.json"
  printf '{"name":"@types/node","version":"26.5.0"}' >"$g/node_modules/@types/node/package.json"
  printf '{"name":"is-number","version":"6.0.0"}' >"$g/node_modules/is-number/package.json"
  printf '{"name":"kleur","version":"4.0.0"}' >"$g/node_modules/kleur-alias/package.json"
  printf '{"name":"anything","version":"1.0.0"}' >"$g/node_modules/anything/package.json"
  rmdir "$g/node_modules/tool"
  ln -s "$SANDBOX/src" "$g/node_modules/tool"
  run reg bun-globals "$g"
  [ "$status" -eq 0 ]
  want $'pkg\tms\t2.1.1\tcaret\t^2.1.1' $'pkg\t@types/node\t26.5.0\ttilde\t~26.5.0' $'skip\tis-number\tpinned:6.0.0' \
    $'skip\tkleur-alias\talias' $'skip\tlocal\tlocal' $'skip\ttool\tlinked' $'skip\tanything\trange:*' \
    $'skip\tranged\trange:>=1 <3' $'skip\tweird\tmissing' $'skip\tgone\tmissing'
  got
  run reg bun-globals "$SANDBOX/nowhere" # no global packages yet
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "registry bun-globals: Bun's isolated linker (node_modules/NAME -> .bun/…) is a registry install, not a link" {
  need_node
  local g="$SANDBOX/bunglobal"
  mkdir -p "$g/node_modules/.bun/ms@2.1.1/node_modules/ms" "$g/node_modules/.bun/@types+node@26.6.2/node_modules/@types/node" \
    "$g/node_modules/@types" "$SANDBOX/src/mytool"
  printf '{"name":"ms","version":"2.1.1"}' >"$g/node_modules/.bun/ms@2.1.1/node_modules/ms/package.json"
  printf '{"name":"@types/node","version":"26.6.2"}' >"$g/node_modules/.bun/@types+node@26.6.2/node_modules/@types/node/package.json"
  printf '{"name":"mytool","version":"1.0.0"}' >"$SANDBOX/src/mytool/package.json"
  ln -s .bun/ms@2.1.1/node_modules/ms "$g/node_modules/ms"
  ln -s ../.bun/@types+node@26.6.2/node_modules/@types/node "$g/node_modules/@types/node"
  ln -s "$SANDBOX/src/mytool" "$g/node_modules/mytool" # bun link: a real link
  printf '{"dependencies":{"ms":"^2.1.1","@types/node":"^26.6.2","mytool":"^1.0.0"}}' >"$g/package.json"
  run reg bun-globals "$g"
  [ "$status" -eq 0 ]
  want $'pkg\tms\t2.1.1\tcaret\t^2.1.1' $'pkg\t@types/node\t26.6.2\tcaret\t^26.6.2' $'skip\tmytool\tlinked'
  got
}

@test "registry: ranges a versioned update would narrow or pin (~1, ^0, ^0.0, *, latest) are not moved; ^1, ^0.3, ~1.2 are" {
  need_node
  local g="$SANDBOX/specs" spec
  for spec in '^1' '^1.2' '^0.3' '^0.0.4' '~1.2' '~1.2.3' '~1' '~0' '^0' '^0.0' '*' 'latest' '1.x'; do
    rm -rf "$g"
    mkdir -p "$g/node_modules/p"
    printf '{"name":"p","version":"1.2.3"}' >"$g/node_modules/p/package.json"
    printf '{"dependencies":{"p":"%s"}}' "$spec" >"$g/package.json"
    printf '%s => ' "$spec" >>"$SANDBOX/modes"
    reg bun-globals "$g" | cut -f1,4,3 >>"$SANDBOX/modes"
  done
  diff "$SANDBOX/modes" - <<'EOF'
^1 => pkg	1.2.3	caret
^1.2 => pkg	1.2.3	caret
^0.3 => pkg	1.2.3	caret
^0.0.4 => pkg	1.2.3	caret
~1.2 => pkg	1.2.3	tilde
~1.2.3 => pkg	1.2.3	tilde
~1 => skip	range:~1
~0 => skip	range:~0
^0 => skip	range:^0
^0.0 => skip	range:^0.0
* => skip	range:*
latest => skip	range:latest
1.x => skip	range:1.x
EOF
}

@test "registry pick: a saved range's own bounds apply (^0 allows 0.3.0, ~1 allows 1.5.0, ^0.0 allows 0.0.9)" {
  need_node
  run reg pick x 0.2.5 "$(ago 7)" '^0' <<<"$(view_json 1.0.0 0.2.5:90 0.3.0:60 1.0.0:50)"
  [ "$output" = $'pick\t0.3.0' ] # caret of the installed 0.2.5 would allow nothing
  run reg pick x 1.2.3 "$(ago 7)" '~1' <<<"$(view_json 2.0.0 1.2.3:90 1.2.4:80 1.5.0:60 2.0.0:50)"
  [ "$output" = $'pick\t1.5.0\t1.2.4' ]
  run reg pick x 0.0.3 "$(ago 7)" '^0.0' <<<"$(view_json 0.1.0 0.0.3:90 0.0.9:60 0.1.0:50)"
  [ "$output" = $'pick\t0.0.9' ]
  run reg pick x 1.2.3 "$(ago 7)" '~1.2' <<<"$(view_json 2.0.0 1.2.3:90 1.2.4:80 1.5.0:60 2.0.0:50)"
  [ "$output" = $'pick\t1.2.4' ]
  run reg pick x 1.2.3 "$(ago 7)" '>=1 <2' <<<'{}' # not a ^/~ range: not a mode
  [ "$status" -eq 3 ]
}

@test "registry bunfig-age: floats, inline tables, exponents and hex count too (a smaller reading would relax yours)" {
  need_node
  printf '[install]\nminimumReleaseAge = 1209600.0\n' >"$SANDBOX/float.toml"
  printf 'install = { linker = "isolated", minimumReleaseAge = 1_209_600 }\n' >"$SANDBOX/inline.toml"
  printf '[install]\nminimumReleaseAge = 1.2096e6\n' >"$SANDBOX/exp.toml"
  printf '[install]\nminimumReleaseAge = 0x127500\n' >"$SANDBOX/hex.toml"
  printf '[install]\nminimumReleaseAge = 1209599.5\n' >"$SANDBOX/half.toml"
  local f
  for f in float inline exp hex; do
    run reg bunfig-age "$SANDBOX/$f.toml"
    [ "$output" = 1209600 ] || {
      echo "$f: $output"
      false
    }
  done
  run reg bunfig-age "$SANDBOX/half.toml"
  [ "$output" = 1209600 ] # rounded up: never relaxed
}

@test "registry npm-min-release-age: an npmrc read the way npm's ini reads it (each one checked against npm 11.13)" {
  need_node
  export npm_config_prefix="$SANDBOX/noprefix" # (no global npmrc of the host's)
  local rc="$SANDBOX/userrc" v want
  # file contents and what npm 11.13 applies
  while IFS='|' read -r v want; do
    printf '%b' "$v" >"$rc"
    run reg npm-min-release-age --user "$rc" --global /nonexistent
    [ "$status" -eq 0 ]
    [ "$output" = "$want" ] || {
      echo "$v: $output (npm: $want)"
      false
    }
  done <<'EOF'
min-release-age=7 \n|7
min-release-age=7\r\n|7
\xef\xbb\xbfmin-release-age=7\n|7
min-release-age[]=7\n|7
min-release-age[]=7\nmin-release-age[]=14\n|NaN
  [x]\nmin-release-age=7\n|7
min-release-age=7\nmin-release-age=14\n|14
min-release-age=7 ; mine\n|7
min-release-age=7 # mine\n|7
 min-release-age = " 7 " \n|7
"min-release-age"='7'\n|7
min-release-age=1.4e1\n|14
min-release-age=0x7\n|7
min-release-age=\n|0
min-release-age\n|1
; min-release-age=7\n|
[x]\nmin-release-age=7\n|
EOF
  printf 'min-release-age=${MRA_DAYS}\n' >"$rc"
  MRA_DAYS=5 run reg npm-min-release-age --user "$rc" --global /nonexistent
  [ "$output" = 5 ]
}

@test "registry npm-min-release-age: the environment in any case (the last one wins), then the user npmrc, then the global one wherever npm keeps it" {
  need_node
  printf 'min-release-age=7\n' >"$SANDBOX/userrc"
  printf 'min-release-age=9\n' >"$SANDBOX/globalrc"
  run reg npm-min-release-age --user "$SANDBOX/userrc" --global "$SANDBOX/globalrc"
  [ "$output" = 7 ] # the user's beats the global one
  run env NPM_CONFIG_min_release_age=14 "$REAL_NODE" "$REPO_ROOT/lib/registry.cjs" npm-min-release-age --user "$SANDBOX/userrc"
  [ "$output" = 14 ]
  run env npm_config_min_release_age=3 NPM_CONFIG_MIN_RELEASE_AGE=14 "$REAL_NODE" "$REPO_ROOT/lib/registry.cjs" npm-min-release-age
  [ "$output" = 14 ]
  run env NPM_CONFIG_MIN_RELEASE_AGE=14 npm_config_min_release_age=3 "$REAL_NODE" "$REPO_ROOT/lib/registry.cjs" npm-min-release-age
  [ "$output" = 3 ]
  run env npm_config_min_release_age= Npm_Config_Min_Release_Age=abc "$REAL_NODE" "$REPO_ROOT/lib/registry.cjs" npm-min-release-age --user "$SANDBOX/userrc"
  [ "$output" = NaN ] # an empty one is passed over; an invalid one is npm's undoing
  printf '[sec]\nmin-release-age=7\n' >"$SANDBOX/userrc" # a [section]: not the top level
  run reg npm-min-release-age --user "$SANDBOX/userrc" --global "$SANDBOX/globalrc"
  [ "$output" = 9 ]
  # no global path from npm: the environment's, the user npmrc's, or PREFIX/etc/npmrc
  run env npm_config_globalconfig="$SANDBOX/globalrc" "$REAL_NODE" "$REPO_ROOT/lib/registry.cjs" npm-min-release-age --user "$SANDBOX/userrc" --global ''
  [ "$output" = 9 ]
  printf 'globalconfig=%s\n' "$SANDBOX/globalrc" >"$SANDBOX/named"
  run reg npm-min-release-age --user "$SANDBOX/named" --global null
  [ "$output" = 9 ]
  mkdir -p "$SANDBOX/pfx/etc" "$SANDBOX/builtin/etc"
  printf 'min-release-age=11\n' >"$SANDBOX/pfx/etc/npmrc"
  run env NPM_CONFIG_PREFIX="$SANDBOX/pfx" "$REAL_NODE" "$REPO_ROOT/lib/registry.cjs" npm-min-release-age --user /nonexistent
  [ "$output" = 11 ]
  printf 'prefix=%s\n' "$SANDBOX/pfx" >"$SANDBOX/named"
  run reg npm-min-release-age --user "$SANDBOX/named"
  [ "$output" = 11 ]
  npm_fixture # npm's own npmrc, beside its package.json, names the prefix
  printf 'prefix=%s\n' "$SANDBOX/pfx" >"$SANDBOX/npmpkg/npmrc"
  run reg npm-min-release-age --user /nonexistent --npm "$STUB_BIN/npm"
  [ "$output" = 11 ]
}

@test "registry npm-min-release-age: a null level lets the ones below show through (0 when all say null); npm's own npmrc comes last; an invalid value is NaN" {
  need_node
  export npm_config_prefix="$SANDBOX/noprefix" # (no global npmrc of the host's)
  local u="$SANDBOX/userrc" g="$SANDBOX/globalrc"
  printf 'min-release-age=null\n' >"$u"
  printf 'min-release-age=14\n' >"$g"
  run reg npm-min-release-age --user "$u" --global "$g"
  [ "$output" = 14 ] # what npm 11.13 applies
  run reg npm-min-release-age --user "$u" --global /nonexistent
  [ "$output" = 0 ] # set, to null: npm applies none, yet refuses --before
  npm_fixture # npm's own npmrc, beside its package.json: the last level
  printf 'min-release-age=3\n' >"$SANDBOX/npmpkg/npmrc"
  run reg npm-min-release-age --user "$u" --global /nonexistent --npm "$STUB_BIN/npm"
  [ "$output" = 3 ]
  printf 'min-release-age=5\n' >"$u"
  run reg npm-min-release-age --user "$u" --global /nonexistent --npm "$STUB_BIN/npm"
  [ "$output" = 5 ]
  mkdir -p "$SANDBOX/g2"
  printf 'min-release-age=9\n' >"$SANDBOX/g2/npmrc"
  printf 'globalconfig=%s\n' "$SANDBOX/g2/npmrc" >"$SANDBOX/npmpkg/npmrc" # it can name the global one too
  run reg npm-min-release-age --user /nonexistent --global '' --npm "$STUB_BIN/npm"
  [ "$output" = 9 ]
  # an invalid value at the highest level that sets it: npm's cutoff is an
  # Invalid Date and every install fails — the levels below do not help
  printf 'min-release-age=7d\n' >"$u"
  printf 'min-release-age=1\n' >"$g"
  run reg npm-min-release-age --user "$u" --global "$g"
  [ "$output" = NaN ]
  printf 'min-release-age=7\n' >"$u"
  npm_config_min_release_age=null run reg npm-min-release-age --user "$u" --global "$g"
  [ "$output" = NaN ] # the string "null" from the environment is no null
  # a key[] list is multiplied as it stands (no ${X} expansion): only a
  # one-element list of a number is a number
  printf 'min-release-age[]=12\n' >"$u"
  run reg npm-min-release-age --user "$u" --global /nonexistent
  [ "$output" = 12 ]
  local v
  for v in 'min-release-age[]=${HOME}' 'min-release-age[]' 'min-release-age[]=false'; do
    printf '%s\n' "$v" >"$u"
    run reg npm-min-release-age --user "$u" --global /nonexistent
    [ "$output" = NaN ]
  done
  printf 'min-release-age=${JUNK}\n' >"$u"
  JUNK=abc run reg npm-min-release-age --user "$u" --global "$g"
  [ "$output" = NaN ]
  # ini unescapes \\ (and \; \#): a path with a backslash in it
  mkdir -p "$SANDBOX/g\\b"
  printf 'min-release-age=14\n' >"$SANDBOX/g\\b/npmrc"
  printf '%s\n' "globalconfig=$SANDBOX/g\\\\b/npmrc" >"$u"
  run reg npm-min-release-age --user "$u" --global ''
  [ "$output" = 14 ]
  printf "%s\n" "'7'=x" 'min-release-age=7' >"$u" # a quoted key ini reads as a number
  run reg npm-min-release-age --user "$u" --global /nonexistent
  [ "$status" -eq 0 ]
  [ "$output" = 7 ]
}

@test "registry cutoff: an age past the earliest date a Date can hold stops there — never a crash" {
  need_node
  run reg cutoff --seconds 20000000000000 --days 7
  [ "$status" -eq 0 ]
  [ "$output" = -271821-04-20T00:00:00Z ]
  run reg cutoff --minutes 1000000000000000
  [ "$status" -eq 0 ]
  [ "$output" = -271821-04-20T00:00:00Z ]
}

@test "registry cutoff --ceil-days: whole days back, rounded up" {
  need_node
  run reg cutoff --days 7 --ceil-days
  [ "$output" = 7 ]
  run reg cutoff --days 0 --ceil-days
  [ "$output" = 0 ]
  run reg cutoff --days 7 --before "$("$REAL_NODE" -e 'console.log(new Date(Date.now() - 9.5 * 864e5).toISOString())')" --ceil-days
  [ "$output" = 10 ]
}

@test "registry bun-outdated: Latest vs Current; Bun's banner alone means up to date; anything else is unreadable" {
  need_node
  run reg bun-outdated <<'EOF'
bun outdated v1.4.2 (744846f84)
|--------------------------------------|
| Package     | Current | Update | Latest |
|-------------|---------|--------|--------|
| ms          | 2.1.1   | 2.1.1  | 2.1.3  |
| is-number   | 7.0.0   | 7.0.0  | 7.0.0  |
|--------------------------------------|
EOF
  [ "$status" -eq 0 ]
  [ "$output" = ms ] # Update follows the lockfile, so it cannot tell
  run reg bun-outdated <<<'bun outdated v1.4.2 (744846f84)'
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run reg bun-outdated <<<'error: something else'
  [ "$status" -eq 3 ]
}

@test "registry bunfig-age: inline tables over several lines, and a # inside a string, are read as Bun reads them" {
  need_node
  # each one Bun 1.4.2 holds to 1209600 seconds
  printf 'install = {\n  minimumReleaseAge = 1209600\n}\n' >"$SANDBOX/multi.toml"
  printf 'install = { linker = "hoisted",\n  minimumReleaseAge = 1209600 } # done\n' >"$SANDBOX/multi2.toml"
  printf 'install = {\n  scopes = { "@x" = "https://example.com/" },\n  minimumReleaseAge = 1209600,\n}\n' >"$SANDBOX/nested.toml"
  printf 'install = { registry = "https://registry.example/#x", minimumReleaseAge = 1209600 }\n' >"$SANDBOX/hash.toml"
  printf '%s\n' "install = { registry = 'https://registry.example/#x', token = \"a,b\", minimumReleaseAge = 1209600 }" >"$SANDBOX/literal.toml"
  printf 'install = { registry = "https://registry.example/#{", # a { in a comment\n  minimumReleaseAge = 1209600\n}\n' >"$SANDBOX/both.toml"
  printf 'install = { registry = "https://registry.example/?a, minimumReleaseAge = 99999999, b", minimumReleaseAge = 1209600 }\n' >"$SANDBOX/comma.toml"
  local f
  for f in multi multi2 nested hash literal both comma; do
    run reg bunfig-age "$SANDBOX/$f.toml"
    [ "$output" = 1209600 ] || {
      echo "$f: $output"
      false
    }
  done
  printf 'test = { root = "./{" }\n[install]\nminimumReleaseAge = 1209600\n' >"$SANDBOX/brace.toml"
  run reg bunfig-age "$SANDBOX/brace.toml" # a { in a string opens no table
  [ "$output" = 1209600 ]
  printf 'install = {\n  linker = "isolated"\n}\n[run]\nminimumReleaseAge = 99999999\n' >"$SANDBOX/closed.toml"
  run reg bunfig-age "$SANDBOX/closed.toml" # the table ends where its braces balance
  [ "$output" = 0 ]
}

@test "registry bunfig-age: multi-line strings and arrays are read as Bun reads them; no trustworthy integer says 'unsure'" {
  need_node
  # each one Bun 1.4.2 holds to 1209600 seconds
  printf '[install]\nfoo = """\n[bar]\n"""\nminimumReleaseAge = 1209600\n' >"$SANDBOX/ml-basic.toml"
  printf "[install]\nfoo = '''\n[bar]\n'''\nminimumReleaseAge = 1209600\n" >"$SANDBOX/ml-literal.toml"
  printf 'x = { y = """a"b""" }\n[install]\nminimumReleaseAge = 1209600\n' >"$SANDBOX/ml-quote.toml"
  printf "x = { y = '''it's''' }\n[install]\nminimumReleaseAge = 1209600\n" >"$SANDBOX/ml-apostrophe.toml"
  printf '[install]\nfoo = [\n  [ "a" ]\n]\nminimumReleaseAge = 1209600\n' >"$SANDBOX/nested-array.toml"
  printf 'x = {y="""a""}"""}\n[install]\nminimumReleaseAge = 1209600\n' >"$SANDBOX/ml-brace.toml"
  printf 'x = """a""""\n[install]\nminimumReleaseAge = 1209600\n' >"$SANDBOX/ml-quote-last.toml" # a" then the close
  printf "x = 'C:\\\\'\n[install]\nminimumReleaseAge = 1209600\n" >"$SANDBOX/literal-backslash.toml" # no escapes in ''
  printf '\xef\xbb\xbfinstall = {\r\n  minimumReleaseAge = 1209600, # c\r\n}\r\n' >"$SANDBOX/bom-crlf.toml"
  local f
  for f in ml-basic ml-literal ml-quote ml-apostrophe nested-array ml-brace ml-quote-last literal-backslash bom-crlf; do
    run reg bunfig-age "$SANDBOX/$f.toml"
    [ "$output" = 1209600 ] || {
      echo "$f: $output"
      false
    }
  done
  printf '[install]\nfoo = """\nminimumReleaseAge = 5\n"""\n' >"$SANDBOX/in-string.toml"
  run reg bunfig-age "$SANDBOX/in-string.toml" # a key inside a string sets nothing
  [ "$output" = 0 ]
  printf '[install]\nminimumReleaseAge = nan\n' >"$SANDBOX/nan.toml"
  run reg bunfig-age "$SANDBOX/nan.toml" # Bun holds nothing back for nan
  [ "$output" = 0 ]
  # inf (Bun: never old enough), past 1e12 (no cutoff date), not a number,
  # and a file that stops making sense before the key: no integer to trust
  printf '[install]\nminimumReleaseAge = inf\n' >"$SANDBOX/inf.toml"
  printf '[install]\nminimumReleaseAge = 1e400\n' >"$SANDBOX/e400.toml"
  printf '[install]\nminimumReleaseAge = 20_000_000_000_000\n' >"$SANDBOX/huge.toml"
  printf '[install]\nminimumReleaseAge = "1209600"\n' >"$SANDBOX/string.toml"
  printf 'x = {\n[install]\nminimumReleaseAge = 1209600\n' >"$SANDBOX/unbalanced.toml"
  for f in inf e400 huge string unbalanced; do
    run reg bunfig-age "$SANDBOX/$f.toml"
    [ "$output" = unsure ] || {
      echo "$f: $output"
      false
    }
  done
  run reg bunfig-age "$SANDBOX/ml-basic.toml" "$SANDBOX/inf.toml" # one is enough
  [ "$output" = unsure ]
}

@test "registry bunfig-age: escapes in quoted keys are decoded as Bun decodes them; one Bun rejects is 'unsure'" {
  need_node
  local f
  # each one Bun 1.4.2 holds to 1209600 seconds
  printf '%s\n' '[install]' '"minimumReleaseAge" = 1209600' >"$SANDBOX/u4.toml"
  printf '%s\n' '[install]' '"\U0000006dinimumReleaseAge" = 1209600' >"$SANDBOX/u8.toml"
  printf '%s\n' 'install = { "minimum\x52eleaseAge" = 1209600 }' >"$SANDBOX/x2.toml"
  printf '%s\n' '"install".minimumReleaseAge = 1209600' >"$SANDBOX/dotted.toml"
  printf '%s\n' '[ "install" ]' 'minimumReleaseAge = 1209600' >"$SANDBOX/header.toml"
  for f in u4 u8 x2 dotted header; do
    run reg bunfig-age "$SANDBOX/$f.toml"
    [ "$output" = 1209600 ] || {
      echo "$f: $output"
      false
    }
  done
  printf '%s\n' '[install]' "'minimum\\u0052eleaseAge' = 1209600" >"$SANDBOX/literal.toml"
  run reg bunfig-age "$SANDBOX/literal.toml" # no escapes in a 'literal' key: another key
  [ "$output" = 0 ]
  # escapes Bun rejects (and with them the file)
  printf '%s\n' '[install]' '"minimum\qReleaseAge" = 1209600' >"$SANDBOX/bad.toml"
  printf '%s\n' '[install]' '"minimum\u00ZZReleaseAge" = 1209600' >"$SANDBOX/badhex.toml"
  printf '%s\n' '[install]' '"minimum\uD800ReleaseAge" = 1209600' >"$SANDBOX/surrogate.toml"
  printf '%s\n' 'x = {' '[install]' '"minimum\u0052eleaseAge" = 1209600' >"$SANDBOX/after-break.toml" # read no further
  for f in bad badhex surrogate after-break; do
    run reg bunfig-age "$SANDBOX/$f.toml"
    [ "$output" = unsure ] || {
      echo "$f: $output"
      false
    }
  done
}

@test "registry bunfig-age: the largest install.minimumReleaseAge of the bunfig files given" {
  need_node
  printf '[install]\nminimumReleaseAge = 1_209_600 # two weeks\n' >"$SANDBOX/a.toml"
  printf 'install.minimumReleaseAge = 259200\n[run]\nminimumReleaseAge = 99999999\n' >"$SANDBOX/b.toml"
  run reg bunfig-age "$SANDBOX/a.toml" "$SANDBOX/b.toml" "$SANDBOX/missing.toml"
  [ "$output" = 1209600 ]
  run reg bunfig-age "$SANDBOX/missing.toml"
  [ "$output" = 0 ]
}

@test "registry bun-release: upgrade when Bun's newest release is old enough; held while too fresh" {
  need_node
  local rel='{"tag_name":"bun-v1.4.2","published_at":"2026-09-05T05:56:24Z"}'
  run reg bun-release 1.4.1 2026-09-27T00:00:00Z <<<"$rel"
  [ "$output" = $'upgrade\t1.4.2' ]
  run reg bun-release 1.4.1 2026-09-01T00:00:00Z <<<"$rel"
  [ "$output" = $'held\t1.4.2' ]
  run reg bun-release 1.4.2 2026-09-27T00:00:00Z <<<"$rel"
  [ "$output" = none ]
  run reg bun-release 1.5.0-canary.20261003.1 2026-09-27T00:00:00Z <<<"$rel"
  [ "$output" = canary ]
  run reg bun-release 1.4.1 2026-09-27T00:00:00Z <<<'{"message":"API rate limit exceeded"}'
  [ "$status" -eq 3 ]
}

# ---------- npm ----------

@test "npm: without a cooldown, 'npm update -g' gets exactly the globals it may touch" {
  need_node
  npm_fixture
  npm_globals npm:11.0.0:12.0.0 corepack:0.30.0:0.36.0 plain:1.0.0:1.2.0 @scope/pkg:2.0.0:2.1.0 \
    linked:6.0.0:7.0.0 aliased:4.0.0:4.1.5 ahead:3.0.0:2.0.0
  npm_view plain 1.2.0 1.0.0:90 1.2.0:60
  npm_view @scope/pkg 2.1.0 2.0.0:90 2.1.0:60
  ln -s "$SANDBOX/fork" "$SANDBOX/npmfx/root/linked"
  sed -i.bak 's/"name":"aliased"/"name":"kleur"/' "$SANDBOX/npmfx/ls.json"
  run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  grep -Ev '^npm (--version|outdated|ls|root|view|config)( |$)' "$CALL_LOG" >"$SANDBOX/mutating"
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
  refute grep -q -- --before "$CALL_LOG"
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
  [[ "$output" == *"no global packages to update"* ]] || false
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
  [[ "$output" == *"node (or scrubmac's lib/registry.cjs) not found"* ]] || false
  refute grep -q '^npm update' "$CALL_LOG"
  grep -qx 'npm cache verify' "$CALL_LOG"
}

@test "npm and pnpm: 'outdated' exiting 1 (something is outdated) is an answer, not a warning, in status and dry-run" {
  make_stub_script npm <<'EOF'
case "$1" in outdated) echo "ms 2.1.1 2.1.3 2.1.3"; exit "${OUTDATED_RC:-1}" ;; esac
exit 0
EOF
  make_stub_script pnpm <<'EOF'
case "$1" in outdated) exit "${OUTDATED_RC:-1}" ;; esac
exit 0
EOF
  CMM_MODE=status run run_cleaner 30-npm.sh
  [[ "$output" == *"~ npm outdated -g"* ]] || false
  [[ "$output" != *"exited"* ]] || false
  CMM_DRY_RUN=1 run run_cleaner 30-npm.sh
  [[ "$output" == *"~ npm outdated -g"* ]] || false
  [[ "$output" != *"exited"* ]] || false
  CMM_MODE=status run run_cleaner 31-pnpm.sh
  [[ "$output" != *"exited"* ]] || false
  OUTDATED_RC=2 CMM_MODE=status run run_cleaner 30-npm.sh # any other exit still warns
  [[ "$output" == *"report 'npm' exited 2"* ]] || false
  OUTDATED_RC=2 CMM_MODE=status run run_cleaner 31-pnpm.sh
  [[ "$output" == *"report 'pnpm' exited 2"* ]] || false
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

# installed_with_before PKG@VERSION — the install line, and that its
# --before is the cutoff the cleaner announced.
installed_with_before() {
  local cut
  cut="$(sed -n 's/.*published before \([0-9TZ:-]*\) (.*/\1/p' <<<"$output" | head -n 1)"
  [ -n "$cut" ]
  grep -qx "npm install -g $1 --before=$cut" "$CALL_LOG"
}

@test "npm: cooldown installs the newest release old enough, its dependencies held to the same cutoff (S4)" {
  cooldown_fixture
  CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  installed_with_before seasoned@2.1.0 # 2.2.0 is too fresh; the beta never
  refute grep -q 'npm install -g @scope/fresh' "$CALL_LOG"
  [[ "$output" == *"@scope/fresh 1.0.0: every newer release is too fresh"* ]] || false
  grep -qx $'note\t1 global update(s) held by the cooldown (the 7-day cooldown)' "$SANDBOX/report"
  refute grep -q '^npm update' "$CALL_LOG" # never the downgrade-prone path
  refute grep -q -- '--min-release-age' "$CALL_LOG" # only the read-only 'npm config get'
  grep -qx 'npm cache verify' "$CALL_LOG"
}

@test "npm: cooldown never downgrades a package newer than every eligible release" {
  cooldown_fixture
  sed -i.bak 's/"current":"2.0.0"/"current":"2.1.5"/' "$SANDBOX/npmfx/outdated.json"
  sed -i.bak 's/"2.0.0","2.1.0"/"2.0.0","2.1.0","2.1.5"/' "$SANDBOX/npmfx/view-seasoned.json"
  CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  refute grep -q 'npm install -g seasoned' "$CALL_LOG"
}

@test "npm: cooldown under dry-run prints the exact versions it would install" {
  cooldown_fixture
  CMM_COOLDOWN_DAYS=7 CMM_DRY_RUN=1 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ npm install -g seasoned@2.1.0 --before="* ]] || false
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
  grep -Ev '^npm (--version|outdated|ls|root|view|config)( |$)' "$CALL_LOG" >"$SANDBOX/mutating"
  [ "$(wc -l <"$SANDBOX/mutating")" -eq 2 ]
  installed_with_before plain@1.1.0
  [[ "$output" == *"skipping forked: linked/local install"* ]] || false
}

@test "npm: a global installed from git or a tarball (no release of that name on the registry) is never replaced" {
  need_node
  npm_fixture
  # npm records no source for such globals: they look like registry installs,
  # but their version is not one the registry ever published
  npm_globals gitmade:1.0.1-dev:1.1.0 plain:1.0.0:1.1.0
  npm_view gitmade 1.1.0 1.0.0:900 1.1.0:90
  npm_view plain 1.1.0 1.0.0:900 1.1.0:90
  run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  grep -qx 'npm update -g plain' "$CALL_LOG"
  [[ "$output" == *"skipping gitmade 1.0.1-dev: not a release of gitmade on the registry"* ]] || false
  : >"$CALL_LOG"
  CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  refute grep -q 'npm install -g gitmade' "$CALL_LOG"
  installed_with_before plain@1.1.0
}

@test "npm: a package npm's registry does not know (E404) is skipped with a note, not a failure" {
  need_node
  npm_fixture
  npm_globals private-tool:1.0.0:1.1.0
  printf '{"error":{"code":"E404","summary":"Not Found"}}' >"$SANDBOX/npmfx/view-private-tool.json"
  CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping private-tool: not found on npm's configured registry"* ]] || false
  run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  refute grep -q '^npm update' "$CALL_LOG"
}

@test "npm: your stricter npm min-release-age (or before) wins over the cooldown — never relaxed by --before" {
  need_node
  npm_fixture
  npm_globals tool:1.0.0:1.3.0
  npm_view tool 1.3.0 1.0.0:90 1.1.0:30 1.2.0:10 1.3.0:1
  echo 14 >"$SANDBOX/npmfx/config-min-release-age" # ~/.npmrc: min-release-age=14
  CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  installed_with_before tool@1.1.0 # 1.2.0 is old enough for 7 days, not for 14
  [[ "$output" == *"(the 7-day cooldown; npm min-release-age=14)"* ]] || false
  rm "$SANDBOX/npmfx/config-min-release-age"
  echo 'Tue Sep 01 2026 05:30:00 GMT+0530 (India Standard Time)' >"$SANDBOX/npmfx/config-before"
  : >"$CALL_LOG"
  CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [[ "$output" == *"published before 2026-09-01T00:00:00Z"* ]] || false
}

@test "npm: with your min-release-age set, npm >= 11.10 gets --min-release-age=DAYS (11.10–11.14 refuse --before next to it)" {
  need_node
  npm_fixture
  npm_globals tool:1.0.0:1.3.0
  npm_view tool 1.3.0 1.0.0:90 1.1.0:30 1.2.0:10 1.3.0:1
  echo 3 >"$SANDBOX/npmfx/config-min-release-age"
  NPM_VER=11.14.1 CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  grep -qx 'npm install -g tool@1.2.0 --min-release-age=7' "$CALL_LOG" # the stricter: the cooldown's 7 days
  refute grep -q -- '--before' "$CALL_LOG"
  : >"$CALL_LOG"
  echo 14 >"$SANDBOX/npmfx/config-min-release-age"
  NPM_VER=11.15.0 CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  grep -qx 'npm install -g tool@1.1.0 --min-release-age=14' "$CALL_LOG"
  : >"$CALL_LOG"
  NPM_VER=11.9.0 CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh # no min-release-age in this npm
  installed_with_before tool@1.1.0
  : >"$CALL_LOG"
  rm "$SANDBOX/npmfx/config-min-release-age"
  NPM_VER=11.14.1 CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh # none set: --before
  installed_with_before tool@1.2.0
}

@test "npm: the before npm 11.10–11.14 make up from min-release-age is not yours — no day stricter than asked; 11.15+'s is" {
  need_node
  npm_fixture
  npm_globals tool:1.0.0:1.3.0
  npm_view tool 1.3.0 1.0.0:90 1.1.0:30 1.2.0:10 1.3.0:1
  echo 7 >"$SANDBOX/npmfx/config-min-release-age"
  # npm 11.14's `npm config get before`: now minus 7 days, cut to the second
  node -e 'console.log(new Date(Date.now() - 7 * 864e5 - 2000).toString())' >"$SANDBOX/npmfx/config-before"
  NPM_VER=11.14.1 CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  grep -qx 'npm install -g tool@1.2.0 --min-release-age=7' "$CALL_LOG"
  [[ "$output" == *"(the 7-day cooldown; npm min-release-age=7)"* ]] || false
  : >"$CALL_LOG"
  # npm 11.15+ report only a before of your own: twenty days ago, it wins
  node -e 'console.log(new Date(Date.now() - 20 * 864e5 + 36e5).toString())' >"$SANDBOX/npmfx/config-before"
  NPM_VER=11.15.0 CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  grep -qx 'npm install -g tool@1.1.0 --min-release-age=20' "$CALL_LOG"
  [[ "$output" == *"npm min-release-age=7; npm before="* ]] || false
  : >"$CALL_LOG"
  NPM_VER=11.9.0 CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh # no min-release-age yet: the before is yours
  [ "$status" -eq 0 ]
  installed_with_before tool@1.1.0
}

@test "npm: 11.10–11.13 hide your min-release-age behind the before they make of it — found where npm reads it, it gates as --min-release-age" {
  need_node
  npm_fixture
  npm_globals tool:1.0.0:1.3.0
  npm_view tool 1.3.0 1.0.0:90 1.1.0:30 1.2.0:10 1.3.0:1
  # what npm 11.13 reports when min-release-age=7 is set anywhere: no
  # min-release-age, and a before 7 days back (cut to the second)
  node -e 'console.log(new Date(Date.now() - 7 * 864e5 - 2000).toString())' >"$SANDBOX/npmfx/config-before"
  printf 'registry=https://registry.npmjs.org/\nmin-release-age = 7 ; mine\n' >"$SANDBOX/userrc"
  echo "$SANDBOX/userrc" >"$SANDBOX/npmfx/config-userconfig"
  NPM_VER=11.13.0 CMM_COOLDOWN_DAYS=3 run run_cleaner 30-npm.sh # the npmrc npm names
  [ "$status" -eq 0 ]
  grep -qx 'npm install -g tool@1.2.0 --min-release-age=7' "$CALL_LOG"
  refute grep -q -- '--before' "$CALL_LOG" # which these npms refuse next to it
  [[ "$output" == *"(the 3-day cooldown; npm min-release-age=7)"* ]] || false
  : >"$CALL_LOG"
  NPM_VER=11.10.0 run run_cleaner 30-npm.sh # the cooldown off: yours still gates
  grep -qx 'npm install -g tool@1.2.0 --min-release-age=7' "$CALL_LOG"
  : >"$CALL_LOG"
  printf '\xef\xbb\xbfmin-release-age=7 \r\n' >"$SANDBOX/userrc" # a BOM, a blank, CRLF: npm's ini reads 7
  NPM_VER=11.13.0 CMM_COOLDOWN_DAYS=3 run run_cleaner 30-npm.sh
  grep -qx 'npm install -g tool@1.2.0 --min-release-age=7' "$CALL_LOG"
  refute grep -q -- '--before' "$CALL_LOG"
  : >"$CALL_LOG"
  rm "$SANDBOX/npmfx/config-userconfig" "$SANDBOX/userrc" # no path from npm …
  printf 'min-release-age=14\n' >"$HOME/.npmrc"                # … ~/.npmrc it is
  NPM_VER=11.13.0 CMM_COOLDOWN_DAYS=3 run run_cleaner 30-npm.sh
  grep -qx 'npm install -g tool@1.1.0 --min-release-age=14' "$CALL_LOG"
  : >"$CALL_LOG"
  rm "$HOME/.npmrc"
  printf 'min-release-age=7.5\n' >"$SANDBOX/globalrc" # the global npmrc, a fraction
  echo "$SANDBOX/globalrc" >"$SANDBOX/npmfx/config-globalconfig"
  NPM_VER=11.13.0 CMM_COOLDOWN_DAYS=3 run run_cleaner 30-npm.sh
  grep -qx 'npm install -g tool@1.2.0 --min-release-age=8' "$CALL_LOG"
  : >"$CALL_LOG"
  NPM_CONFIG_MIN_RELEASE_AGE=14 NPM_VER=11.13.0 CMM_COOLDOWN_DAYS=3 run run_cleaner 30-npm.sh # the environment beats the files
  grep -qx 'npm install -g tool@1.1.0 --min-release-age=14' "$CALL_LOG"
  : >"$CALL_LOG"
  NPM_CONFIG_min_release_age=14 NPM_VER=11.13.0 CMM_COOLDOWN_DAYS=3 run run_cleaner 30-npm.sh # in any case
  grep -qx 'npm install -g tool@1.1.0 --min-release-age=14' "$CALL_LOG"
  : >"$CALL_LOG"
  npm_config_min_release_age=4 NPM_VER=11.13.0 CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  grep -qx 'npm install -g tool@1.2.0 --min-release-age=7' "$CALL_LOG" # the cooldown's 7 days, stricter
  : >"$CALL_LOG"
  rm "$SANDBOX/npmfx/config-globalconfig" "$SANDBOX/globalrc"
  # no min-release-age anywhere: the before is yours, and --before it is
  node -e 'console.log(new Date(Date.now() - 20 * 864e5 + 36e5).toString())' >"$SANDBOX/npmfx/config-before"
  NPM_VER=11.13.0 CMM_COOLDOWN_DAYS=3 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  installed_with_before tool@1.1.0
  refute grep -q -- '--min-release-age' "$CALL_LOG"
}

@test "npm: a min-release-age of 0 still rules out --before on npm 11.10–11.14; one that is no finite number of days holds global updates" {
  need_node
  npm_fixture
  npm_globals tool:1.0.0:1.3.0
  npm_view tool 1.3.0 1.0.0:90 1.1.0:30 1.2.0:10 1.3.0:1
  echo 0 >"$SANDBOX/npmfx/config-min-release-age" # npm 11.14 shows the 0 …
  node -e 'console.log(new Date().toString())' >"$SANDBOX/npmfx/config-before" # … and a before of now
  NPM_VER=11.14.1 CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  grep -qx 'npm install -g tool@1.2.0 --min-release-age=7' "$CALL_LOG"
  refute grep -q -- '--before' "$CALL_LOG"
  : >"$CALL_LOG"
  rm "$SANDBOX/npmfx/config-min-release-age" # npm 11.13 hides it
  printf 'min-release-age=0\n' >"$HOME/.npmrc"
  NPM_VER=11.13.0 CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  grep -qx 'npm install -g tool@1.2.0 --min-release-age=7' "$CALL_LOG"
  refute grep -q -- '--before' "$CALL_LOG"
  : >"$CALL_LOG"
  printf 'min-release-age=1.4e1\n' >"$HOME/.npmrc" # npm reads 14
  NPM_VER=11.13.0 CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  grep -qx 'npm install -g tool@1.1.0 --min-release-age=14' "$CALL_LOG"
  : >"$CALL_LOG"
  printf 'min-release-age=Infinity\n' >"$HOME/.npmrc" # npm reads it, but it makes no date
  echo 'Invalid Date' >"$SANDBOX/npmfx/config-before"
  NPM_VER=11.13.0 CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  refute grep -q '^npm install' "$CALL_LOG"
  [[ "$output" == *"global updates held: your npm min-release-age ('Infinity') is not a plain number of days"* ]] || false
  grep -qx $'note\tglobal updates held: npm min-release-age \'Infinity\' could not be read' "$SANDBOX/report"
}

@test "npm: a min-release-age set to null still rules out --before on npm 11.10–11.14, and a level below it still applies (on 11.15+ too)" {
  need_node
  npm_fixture
  npm_globals tool:1.0.0:1.3.0
  npm_view tool 1.3.0 1.0.0:90 1.1.0:30 1.2.0:10 1.3.0:1
  printf 'min-release-age=null\n' >"$HOME/.npmrc" # npm reports null, and no before
  NPM_VER=11.13.0 CMM_COOLDOWN_DAYS=3 run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  grep -qx 'npm install -g tool@1.2.0 --min-release-age=3' "$CALL_LOG"
  refute grep -q -- '--before' "$CALL_LOG"
  : >"$CALL_LOG"
  NPM_VER=11.14.1 CMM_COOLDOWN_DAYS=3 run run_cleaner 30-npm.sh
  grep -qx 'npm install -g tool@1.2.0 --min-release-age=3' "$CALL_LOG"
  : >"$CALL_LOG"
  printf 'min-release-age=14\n' >"$SANDBOX/globalrc" # … but the global npmrc's 14 shows through
  echo "$SANDBOX/globalrc" >"$SANDBOX/npmfx/config-globalconfig"
  node -e 'console.log(new Date(Date.now() - 14 * 864e5 - 2000).toString())' >"$SANDBOX/npmfx/config-before"
  NPM_VER=11.13.0 CMM_COOLDOWN_DAYS=3 run run_cleaner 30-npm.sh
  grep -qx 'npm install -g tool@1.1.0 --min-release-age=14' "$CALL_LOG"
  : >"$CALL_LOG"
  rm "$SANDBOX/npmfx/config-globalconfig" "$SANDBOX/globalrc" "$SANDBOX/npmfx/config-before" "$HOME/.npmrc"
  printf 'min-release-age=14\n' >"$SANDBOX/npmpkg/npmrc" # npm's own npmrc
  node -e 'console.log(new Date(Date.now() - 14 * 864e5 - 2000).toString())' >"$SANDBOX/npmfx/config-before"
  NPM_VER=11.10.0 CMM_COOLDOWN_DAYS=3 run run_cleaner 30-npm.sh
  grep -qx 'npm install -g tool@1.1.0 --min-release-age=14' "$CALL_LOG"
  : >"$CALL_LOG"
  # npm 11.15+ no longer refuse --before, but a null level still hides the
  # global npmrc's 14 from `npm config get` — and a --before would override it
  rm "$SANDBOX/npmpkg/npmrc"
  printf 'min-release-age=null\n' >"$HOME/.npmrc"
  printf 'min-release-age=14\n' >"$SANDBOX/globalrc"
  echo "$SANDBOX/globalrc" >"$SANDBOX/npmfx/config-globalconfig"
  rm -f "$SANDBOX/npmfx/config-before" # (11.15 reports no before)
  NPM_VER=11.15.0 CMM_COOLDOWN_DAYS=3 run run_cleaner 30-npm.sh
  grep -qx 'npm install -g tool@1.1.0 --min-release-age=14' "$CALL_LOG"
  refute grep -q -- '--before' "$CALL_LOG"
  : >"$CALL_LOG"
  rm "$SANDBOX/npmfx/config-globalconfig" "$SANDBOX/globalrc"
  printf 'min-release-age=7d\n' >"$HOME/.npmrc" # npm itself refuses every install on it
  echo 'Invalid Date' >"$SANDBOX/npmfx/config-before"
  NPM_VER=11.13.0 CMM_COOLDOWN_DAYS=3 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  refute grep -q '^npm install' "$CALL_LOG"
  grep -qx $'note\tglobal updates held: npm min-release-age \'NaN\' could not be read' "$SANDBOX/report"
}

@test "npm: with the cooldown off, your own npm min-release-age still goes through the resolver (never npm update -g)" {
  need_node
  npm_fixture
  npm_globals tool:1.0.0:1.3.0
  npm_view tool 1.3.0 1.0.0:90 1.1.0:30 1.2.0:10 1.3.0:1
  echo 14 >"$SANDBOX/npmfx/config-min-release-age"
  run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  installed_with_before tool@1.1.0
  refute grep -q '^npm update' "$CALL_LOG"
}

@test "npm: cooldown steps over deprecated releases and ones that need a newer node" {
  need_node
  npm_fixture
  fake_semver "$SANDBOX/npmpkg"
  npm_globals tool:1.0.0:1.3.0
  npm_view tool 1.3.0 1.0.0:90 1.1.0:60 1.2.0:50 1.3.0:40
  npm_meta tool '[{"name":"tool","version":"1.3.0","deprecated":"critical bug"},{"name":"tool","version":"1.2.0","engines":{"node":">=999"}},{"name":"tool","version":"1.1.0","engines":{"node":">=18"}},{"name":"tool","version":"1.0.0"}]'
  CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  grep -qx 'npm view tool@1.3.0 || 1.2.0 || 1.1.0 || 1.0.0 name version deprecated engines --json' "$CALL_LOG"
  installed_with_before tool@1.1.0
  [[ "$output" == *"tool 1.3.0: deprecated: critical bug — trying the next release"* ]] || false
  [[ "$output" == *"tool 1.2.0: needs node >=999"* ]] || false
  refute grep -q 'held by the' "$SANDBOX/report"
}

@test "npm: when nothing old enough is suitable it says so — not 'held by the cooldown'" {
  need_node
  npm_fixture
  npm_globals tool:1.0.0:1.3.0
  npm_view tool 1.3.0 1.0.0:90 1.3.0:40
  npm_meta tool '[{"name":"tool","version":"1.3.0","deprecated":"broken"},{"name":"tool","version":"1.0.0"}]'
  CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 30-npm.sh
  [ "$status" -eq 0 ]
  refute grep -q '^npm install' "$CALL_LOG"
  [[ "$output" == *"tool 1.0.0: not suitable"* ]] || false
  grep -qx $'note\t1 global update(s) not suitable (deprecated, or need a newer Node.js)' "$SANDBOX/report"
  refute grep -q 'held by the' "$SANDBOX/report"
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
  npm_view plain 1.1.0 1.0.0:90 1.1.0:60 # no fixture for "broken": npm view prints nothing
  CMM_COOLDOWN_DAYS=7 run run_cleaner 30-npm.sh
  [ "$status" -eq 1 ]
  [[ "$output" == *"registry lookup failed for broken"* ]] || false
  installed_with_before plain@1.1.0
}

# ---------- pnpm ----------

# pnpm_fixture — a pnpm stub: `--version` prints $PNPM_VER (12.8.1), `config
# get minimumReleaseAge` $PNPM_MRA (undefined; FAIL: it fails, as pnpm 12 does
# on a config it cannot load), `ls -g --depth=0 --json`
# $SANDBOX/pnpm-ls.json (pnpm_globals writes it; none by default), `outdated
# -g --format json` $SANDBOX/pnpm-outdated.json (unreadable when absent:
# every global is looked up), `bin -g` its global bin directory. Every call
# is logged; mutating ones also log their working directory to
# $SANDBOX/pnpm-cwd. With the npm fixture, the registry knows pnpm (the
# running version is the newest) unless a test says otherwise.
# PNPM_BIN_OFF=1: that directory is not on PATH, and pnpm refuses global
# commands as the real ones do (on stderr) — pnpm 11 all of them, pnpm 12 all
# but ls and outdated (wrapped, with a code), pnpm 9/10 all (PNPM_HOME set).
# PNPM_NO_GLOBAL_BIN=1: there is none (pnpm <= 10 without PNPM_HOME) — `bin
# -g` prints nothing, and `add -g` fails (on stdout, as pnpm 10 does).
pnpm_fixture() {
  [ -f "$SANDBOX/pnpm-ls.json" ] || printf '[{"path":"%s","private":true,"dependencies":{}}]' "$SANDBOX/pnhome/global/v11" >"$SANDBOX/pnpm-ls.json"
  if [ -d "$SANDBOX/npmfx" ]; then
    [ -f "$SANDBOX/npmfx/view-pnpm.json" ] || npm_view pnpm "${PNPM_VER:-12.8.1}" "${PNPM_VER:-12.8.1}:90"
  fi
  cat >"$STUB_BIN/pnpm" <<'EOF'
#!/bin/sh
printf '%s %s\n' pnpm "$*" >>"$CALL_LOG"
case " $* " in
  *" -g "*)
    if [ -n "${PNPM_BIN_OFF:-}" ]; then
      case "${PNPM_VER:-12.8.1}:$1" in
        12.*:ls | 12.*:outdated) ;;
        11.*)
          printf '[ERROR] The configured global bin directory "%s" is not in PATH\nRun "pnpm setup" to update your shell configuration.\n' "$HOME/Library/pnpm/bin" >&2
          exit 1
          ;;
        12.*)
          printf 'Error: ERR_PNPM_GLOBAL_BIN_DIR_NOT_IN_PATH\n\n  x The configured global bin directory "%s" is not in\n  | PATH\n  help: Run "pnpm setup" to update your shell configuration.\n' "$HOME/Library/pnpm/bin" >&2
          exit 1
          ;;
        *)
          printf ' ERROR  The configured global bin directory "%s" is not in PATH\nFor help, run: pnpm help %s\n' "$HOME/Library/pnpm" "$1" >&2
          exit 1
          ;;
      esac
    elif [ -n "${PNPM_NO_GLOBAL_BIN:-}" ] && [ "$1" = add ]; then
      printf ' ERR_PNPM_NO_GLOBAL_BIN_DIR  Unable to find the global bin directory\n'
      exit 1
    fi
    ;;
esac
case "$1" in
  --version) echo "${PNPM_VER:-12.8.1}" ;;
  config)
    [ "${PNPM_MRA:-}" = FAIL ] && { echo 'Error: invalid u64' >&2; exit 1; }
    echo "${PNPM_MRA:-undefined}"
    ;;
  bin) [ -n "${PNPM_NO_GLOBAL_BIN:-}" ] || echo "$HOME/Library/pnpm/bin" ;;
  ls) cat "$SANDBOX/pnpm-ls.json" ;;
  root) echo "${PNPM_GLOBAL_ROOT:-$SANDBOX/pnhome/global/v11}" ;;
  outdated) cat "$SANDBOX/pnpm-outdated.json" 2>/dev/null || exit 1 ;;
  add | update | self-update) pwd -P >>"$SANDBOX/pnpm-cwd" ;;
esac
exit 0
EOF
  chmod 755 "$STUB_BIN/pnpm"
}

# pnpm_globals GROUP=MEMBER[,MEMBER]… — pnpm >= 11 globals: each GROUP an
# install group whose MEMBERs are NAME@VERSION[=SPEC] (SPEC defaults to
# ^VERSION, pnpm's default), under $PNPM_GLOBAL_ROOT (pnpm's global root,
# <globalDir>/v11; $SANDBOX/pnhome/global/v11 by default).
pnpm_globals() {
  local arg gid m name ver spec dir deps='' specs members root="${PNPM_GLOBAL_ROOT:-$SANDBOX/pnhome/global/v11}"
  for arg in "$@"; do
    gid="${arg%%=*}"
    dir="$root/$gid"
    mkdir -p "$dir"
    specs=''
    IFS=, read -r -a members <<<"${arg#*=}"
    for m in "${members[@]}"; do
      spec=''
      case "$m" in *=*) spec="${m#*=}" m="${m%%=*}" ;; esac
      name="${m%@*}"
      ver="${m##*@}"
      deps="$deps${deps:+,}\"$name\":{\"from\":\"$name\",\"version\":\"$ver\",\"path\":\"$dir/node_modules/$name\"}"
      specs="$specs${specs:+,}\"$name\":\"${spec:-^$ver}\""
    done
    printf '{"dependencies":{%s}}' "$specs" >"$dir/package.json"
  done
  printf '[{"path":"%s","private":true,"dependencies":{%s}}]' "$root" "$deps" >"$SANDBOX/pnpm-ls.json"
}

# pnpm10_globals NAME@VERSION[=SPEC][:hoisted]… — pnpm 10's single global
# project (global/5), each package isolated (.pnpm/…) or hoisted.
pnpm10_globals() {
  local m name ver spec path g="$SANDBOX/pnhome/global/5" deps='' specs=''
  mkdir -p "$g"
  for m in "$@"; do
    path=''
    case "$m" in *:hoisted) m="${m%:hoisted}" path=hoisted ;; esac
    spec=''
    case "$m" in *=*) spec="${m#*=}" m="${m%%=*}" ;; esac
    name="${m%@*}"
    ver="${m##*@}"
    if [ "$path" = hoisted ]; then path="$g/node_modules/$name"; else path="$g/.pnpm/$name@$ver/node_modules/$name"; fi
    deps="$deps${deps:+,}\"$name\":{\"from\":\"$name\",\"version\":\"$ver\",\"path\":\"$path\"}"
    specs="$specs${specs:+,}\"$name\":\"${spec:-^$ver}\""
  done
  printf '{"dependencies":{%s}}' "$specs" >"$g/package.json"
  printf '[{"path":"%s","private":false,"dependencies":{%s}}]' "$g" "$deps" >"$SANDBOX/pnpm-ls.json"
}

# pnpm_outdated NAME:CURRENT:LATEST… — what `pnpm outdated -g` reports.
pnpm_outdated() {
  local e name cur o=''
  for e in "$@"; do
    name="${e%%:*}"
    e="${e#*:}"
    cur="${e%%:*}"
    o="$o${o:+,}\"$name\":{\"current\":\"$cur\",\"latest\":\"${e#*:}\",\"wanted\":\"$cur\"}"
  done
  printf '{%s}' "$o" >"$SANDBOX/pnpm-outdated.json"
}

pnpm_mutating() { grep -E '^pnpm (add|update|self-update|store)' "$CALL_LOG" || true; }

@test "pnpm: without a cooldown (or a minimumReleaseAge of your own): plain self-update, update -g, store prune" {
  need_node # even with the resolver available
  npm_fixture
  pnpm_globals g1=ms@2.1.1
  pnpm_fixture
  run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  pnpm_mutating >"$SANDBOX/mutating"
  diff "$SANDBOX/mutating" - <<'EOF'
pnpm self-update
pnpm update -g
pnpm store prune
EOF
  refute grep -q '^npm view' "$CALL_LOG"
}

@test "pnpm: without a cooldown and without global packages, no 'pnpm update -g' (it fails when 'pnpm setup' never ran)" {
  need_node
  npm_fixture
  pnpm_fixture # (no global packages)
  run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"no global packages"* ]] || false
  refute grep -q '^pnpm update' "$CALL_LOG"
  grep -qx 'pnpm store prune' "$CALL_LOG"
}

@test "pnpm: pnpm 11 refuses global commands while its global bin directory is not on PATH — globals skipped with the cure, not failed" {
  need_node
  npm_fixture
  PNPM_VER=11.28.2 pnpm_fixture
  export PNPM_VER=11.28.2 PNPM_BIN_OFF=1 # e.g. Homebrew's pnpm, no `pnpm setup`
  CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  refute grep -Eq '^pnpm (update|add)' "$CALL_LOG"
  [[ "$output" == *"global packages skipped: pnpm's global bin directory is not on PATH"*"run 'pnpm setup', then, from a new shell, 'scrubmac schedule' again"* ]] || false
  grep -qx 'pnpm self-update' "$CALL_LOG" # needs no global bin directory
  grep -qx 'pnpm store prune' "$CALL_LOG"
  refute grep -q 'global packages skipped' "$SANDBOX/report" # no globals anywhere: nothing to report
  : >"$CALL_LOG"
  CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  refute grep -Eq '^pnpm (update|add)' "$CALL_LOG"
  [[ "$output" != *"could not read"* ]] || false
  [[ "$output" == *"global packages skipped: pnpm's global bin directory is not on PATH"* ]] || false
  [[ "$output" == *"pnpm 11.28.2 is up to date"* ]] || false
  refute grep -q 'global packages skipped' "$SANDBOX/report"
  mkdir -p "$HOME/Library/pnpm/global/v11/g1/node_modules/ms" # but globals there are
  CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  grep -qx $'note\tglobal packages skipped: pnpm\'s global bin directory is not on PATH — run \'pnpm setup\', then \'scrubmac schedule\' again' "$SANDBOX/report"
}

@test "pnpm: pnpm 12 (lists globals, refuses to change them) and pnpm 10 with PNPM_HOME set skip globals while that directory is not on PATH" {
  need_node
  npm_fixture
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700
  local v
  for v in 12.8.1 10.34.6; do
    pnpm_globals g1=ms@2.1.1
    PNPM_VER=$v pnpm_fixture
    npm_view pnpm "$v" "$v:90"
    mkdir -p "$SANDBOX/pnhome/global/v11/g1/node_modules/ms"
    PNPM_HOME="$SANDBOX/pnhome" PNPM_VER=$v PNPM_BIN_OFF=1 CMM_REPORT_FILE="$SANDBOX/report-$v" run run_cleaner 31-pnpm.sh
    [ "$status" -eq 0 ]
    PNPM_HOME="$SANDBOX/pnhome" PNPM_VER=$v PNPM_BIN_OFF=1 CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report-$v" run run_cleaner 31-pnpm.sh
    [ "$status" -eq 0 ]
    refute grep -Eq '^pnpm (update|add)' "$CALL_LOG"
    [ "$(grep -c "global packages skipped: pnpm's global bin directory is not on PATH" "$SANDBOX/report-$v")" -eq 2 ]
    : >"$CALL_LOG"
  done
}

@test "pnpm: pnpm 10 with no global bin directory (no PNPM_HOME, as in an older schedule) cannot 'pnpm add -g': re-adds held, 'pnpm update -g' runs" {
  need_node
  npm_fixture
  pnpm10_globals ms@2.1.1
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700
  PNPM_VER=10.34.6 pnpm_fixture
  export PNPM_VER=10.34.6 PNPM_NO_GLOBAL_BIN=1
  CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  refute grep -q '^pnpm add' "$CALL_LOG"
  [[ "$output" == *"not re-adding ms@2.1.3: pnpm has no global bin directory here (PNPM_HOME is not set here)"*"run 'scrubmac schedule' again from a shell where PNPM_HOME is set"* ]] || false
  grep -qx $'note\t1 global update(s) held: PNPM_HOME is not set here, so pnpm has no global bin directory — run \'scrubmac schedule\' again from a shell where it is' "$SANDBOX/report"
  : >"$CALL_LOG"
  run run_cleaner 31-pnpm.sh # no cooldown: `pnpm update -g` needs no global bin directory
  [ "$status" -eq 0 ]
  grep -qx 'pnpm update -g' "$CALL_LOG"
}

@test "pnpm: the cooldown re-adds globals within their saved ranges, pnpm's own age gate holding their dependencies (S4)" {
  need_node
  npm_fixture
  pnpm_globals g1=@types/node@26.6.4,ms@2.1.1 g2=globby@16.2.3 g3=semver@7.0.0=7.0.0 g4=is-odd@2.0.0=~2.0.0
  pnpm_fixture
  npm_view @types/node 26.6.4 26.6.2:60 26.6.3:30 26.6.4:1
  npm_view ms 2.1.3 2.1.1:900 2.1.2:800 2.1.3:700 3.0.0-canary.1:600
  npm_view globby 16.2.4 16.2.3:58 16.2.4:46 17.0.0:1
  npm_view semver 7.8.5 7.0.0:900 7.8.5:60
  npm_view is-odd 3.0.1 2.0.0:900 2.0.1:800 3.0.1:700
  CMM_COOLDOWN_DAYS=7 run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  pnpm_mutating >"$SANDBOX/mutating"
  diff "$SANDBOX/mutating" - <<'EOF'
pnpm add -g @types/node@^26.6.4,ms@^2.1.3 --config.minimum-release-age=10080 --config.minimum-release-age-exclude=@types/node@26.6.4
pnpm add -g globby@^16.2.4 --config.minimum-release-age=10080
pnpm add -g is-odd@~2.0.1 --config.minimum-release-age=10080
pnpm store prune
EOF
  refute grep -q 'semver' "$SANDBOX/mutating" # an exact pin is left where it is
  refute grep -q '^pnpm update' "$CALL_LOG"
}

@test "pnpm: pnpm 10 gets one add per package — its single global project has no a,b groups (isolated or hoisted)" {
  need_node
  npm_fixture
  pnpm10_globals ms@2.1.1 globby@16.2.3:hoisted @types/node@26.6.4:hoisted
  PNPM_VER=10.34.6 pnpm_fixture
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700
  npm_view globby 16.2.4 16.2.3:58 16.2.4:46
  npm_view @types/node 26.6.4 26.6.3:30 26.6.4:1
  PNPM_VER=10.34.6 CMM_COOLDOWN_DAYS=7 run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  pnpm_mutating >"$SANDBOX/mutating"
  diff "$SANDBOX/mutating" - <<'EOF'
pnpm add -g ms@^2.1.3 --config.minimum-release-age=10080
pnpm add -g globby@^16.2.4 --config.minimum-release-age=10080
pnpm store prune
EOF
}

@test "pnpm: a pnpm without minimumReleaseAge (< 10.16) cannot hold dependencies back: global updates are held" {
  need_node
  npm_fixture
  pnpm10_globals ms@2.1.1
  PNPM_VER=10.10.0 pnpm_fixture
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700
  PNPM_VER=10.10.0 CMM_COOLDOWN_DAYS=7 run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  refute grep -q '^pnpm add' "$CALL_LOG"
  [[ "$output" == *"predates minimumReleaseAge (10.16)"* ]] || false
}

@test "pnpm: your stricter minimumReleaseAge wins over the cooldown — and is the gate even with the cooldown off" {
  need_node
  npm_fixture
  pnpm_globals g1=tool@1.0.0
  pnpm_fixture
  npm_view tool 1.3.0 1.0.0:90 1.1.0:30 1.2.0:10 1.3.0:1
  PNPM_MRA=20160 CMM_COOLDOWN_DAYS=7 run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  grep -qx 'pnpm add -g tool@^1.1.0 --config.minimum-release-age=20160' "$CALL_LOG"
  [[ "$output" == *"(the 7-day cooldown; pnpm minimumReleaseAge=20160)"* ]] || false
  : >"$CALL_LOG"
  PNPM_MRA=20160 run run_cleaner 31-pnpm.sh # cooldown off: still never a plain update
  grep -qx 'pnpm add -g tool@^1.1.0 --config.minimum-release-age=20160' "$CALL_LOG"
  refute grep -q '^pnpm update' "$CALL_LOG"
}

@test "pnpm: a minimumReleaseAge that is no number of minutes holds the self-update and global updates; a fraction counts, rounded up" {
  need_node
  npm_fixture
  pnpm_globals g1=tool@1.0.0
  npm_view tool 1.3.0 1.0.0:90 1.1.0:30 1.2.0:10 1.3.0:1
  pnpm_fixture
  local v
  # pnpm 10 and 11 fail every update on these; pnpm 12 cannot load them at all (FAIL)
  for v in Infinity 1e+21 99999999999999999999 two-weeks FAIL; do
    : >"$CALL_LOG"
    PNPM_MRA="$v" CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report-$v" run run_cleaner 31-pnpm.sh
    [ "$status" -eq 0 ]
    refute grep -Eq '^pnpm (add|update|self-update)' "$CALL_LOG" # --config.minimum-release-age=10080 would relax it
    grep -qx 'pnpm store prune' "$CALL_LOG"
    grep -qx $'note\tpnpm updates held: pnpm minimumReleaseAge could not be read' "$SANDBOX/report-$v"
  done
  [[ "$output" == *"pnpm self-update and global updates held: pnpm's minimumReleaseAge cannot be read as a number of minutes ('pnpm config get minimumReleaseAge' failed)"* ]] || false
  : >"$CALL_LOG"
  PNPM_MRA=Infinity run run_cleaner 31-pnpm.sh # the cooldown off too: a plain 'pnpm update -g' fails on it
  [ "$status" -eq 0 ]
  refute grep -Eq '^pnpm (add|update|self-update)' "$CALL_LOG"
  [[ "$output" == *"cannot be read as a number of minutes (it is 'Infinity')"* ]] || false
  : >"$CALL_LOG"
  PNPM_MRA=20160.5 CMM_COOLDOWN_DAYS=7 run run_cleaner 31-pnpm.sh # pnpm 10 and 11 honor a fraction
  [ "$status" -eq 0 ]
  grep -qx 'pnpm add -g tool@^1.1.0 --config.minimum-release-age=20161' "$CALL_LOG"
}

@test "pnpm: pnpm 11's built-in one-day minimumReleaseAge is the floor of the gate" {
  need_node
  npm_fixture
  pnpm_globals g1=tool@1.0.0
  pnpm_fixture
  npm_view tool 1.1.0 1.0.0:90 1.1.0:3
  PNPM_MRA=60 run run_cleaner 31-pnpm.sh # your own hour, no cooldown
  grep -qx 'pnpm add -g tool@^1.1.0 --config.minimum-release-age=1440' "$CALL_LOG"
  : >"$CALL_LOG"
  PNPM_VER=10.34.6 PNPM_MRA=60 run run_cleaner 31-pnpm.sh # pnpm 10 has no built-in default
  grep -qx 'pnpm add -g tool@^1.1.0 --config.minimum-release-age=60' "$CALL_LOG"
}

@test "pnpm: a group whose lookup fails is not re-added — re-adding it without that member would uninstall it" {
  need_node
  npm_fixture
  pnpm_globals g1=ms@2.1.1,unknown-to-npm@1.0.0
  pnpm_fixture
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700 # nothing for the other member: npm view prints nothing
  CMM_COOLDOWN_DAYS=7 run run_cleaner 31-pnpm.sh
  [ "$status" -eq 1 ]
  refute grep -q '^pnpm add' "$CALL_LOG"
  [[ "$output" == *"not re-adding ms@2.1.3 this run: it shares an install group with unknown-to-npm"* ]] || false
}

@test "pnpm: a group with a member pnpm would move onto an unsuitable release is not re-added" {
  need_node
  npm_fixture
  pnpm_globals g1=ms@2.1.1,tool@1.0.0
  pnpm_fixture
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700
  npm_view tool 1.1.0 1.0.0:90 1.1.0:30
  npm_meta tool '[{"name":"tool","version":"1.1.0","deprecated":"broken"},{"name":"tool","version":"1.0.0"}]'
  CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  refute grep -q '^pnpm add' "$CALL_LOG"
  [[ "$output" == *"tool 1.0.0: not suitable"* ]] || false
  grep -qx $'note\t1 global update(s) not suitable (deprecated, or need a newer Node.js)' "$SANDBOX/report"
}

@test "pnpm: when the best release is deprecated, the package is left as is (pnpm resolves ranges itself)" {
  need_node
  npm_fixture
  pnpm_globals g1=tool@1.0.0
  pnpm_fixture
  npm_view tool 1.2.0 1.0.0:90 1.1.0:40 1.2.0:30
  npm_meta tool '[{"name":"tool","version":"1.2.0","deprecated":"broken"},{"name":"tool","version":"1.1.0"},{"name":"tool","version":"1.0.0"}]'
  CMM_COOLDOWN_DAYS=7 run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  refute grep -q '^pnpm add' "$CALL_LOG"
  [[ "$output" == *"tool 1.0.0: not suitable — the newest release old enough is deprecated"* ]] || false
}

@test "pnpm: globals pnpm reports at their latest release are not looked up" {
  need_node
  npm_fixture
  pnpm_globals g1=ms@2.1.1 g2=globby@16.2.4
  pnpm_fixture
  pnpm_outdated ms:2.1.1:2.1.3 globby:16.2.4:16.2.4
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700
  CMM_COOLDOWN_DAYS=7 run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  grep -qx 'pnpm add -g ms@^2.1.3 --config.minimum-release-age=10080' "$CALL_LOG"
  refute grep -q '^npm view globby' "$CALL_LOG"
}

@test "pnpm: groups are found wherever globalDir puts them — a group is re-added whole, its exact pin kept exact" {
  need_node
  npm_fixture
  export PNPM_GLOBAL_ROOT="$SANDBOX/my-global-dir/v11" # pnpm config set global-dir …
  pnpm_globals grp=ms@2.1.1,kleur@4.1.4=4.1.4
  pnpm_fixture
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700
  npm_view kleur 4.1.5 4.1.4:900 4.1.5:800
  CMM_COOLDOWN_DAYS=7 run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  pnpm_mutating >"$SANDBOX/mutating"
  diff "$SANDBOX/mutating" - <<'EOF'
pnpm add -g ms@^2.1.3,kleur@4.1.4 --config.minimum-release-age=10080 --config.minimum-release-age-exclude=kleur@4.1.4
pnpm store prune
EOF
}

@test "pnpm: a group with a range a re-add would rewrite (*, latest, 7.x, >=…, ~1, ^0) is not re-added" {
  need_node
  npm_fixture
  pnpm_globals grp=ms@2.1.1,kleur@4.1.0='>=4.1.0 <4.2.0' solo=semver@7.0.0='7.x'
  pnpm_fixture
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700
  npm_view kleur 4.1.5 4.1.0:900 4.1.5:800
  npm_view semver 7.8.5 7.0.0:900 7.8.5:60
  CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  refute grep -q '^pnpm add' "$CALL_LOG"
  [[ "$output" == *"kleur: its saved range '>=4.1.0 <4.2.0' would be rewritten by a re-add"* ]] || false
  [[ "$output" == *"not re-adding ms@2.1.3 this run: it shares an install group with kleur"* ]] || false
  [[ "$output" == *"semver: its saved range '7.x' would be rewritten by a re-add"* ]] || false
  grep -qx $'note\t1 global update(s) held: their install group (pnpm add -g a,b) cannot be re-added this run' "$SANDBOX/report"
}

@test "pnpm: a group with a member that is not a registry release (foreign) is not re-added" {
  need_node
  npm_fixture
  pnpm_globals grp=ms@2.1.1,gitmade@1.0.1-dev
  pnpm_fixture
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700
  npm_view gitmade 1.1.0 1.0.0:900 1.1.0:90 # 1.0.1-dev was never published
  CMM_COOLDOWN_DAYS=7 run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  refute grep -q '^pnpm add' "$CALL_LOG"
  [[ "$output" == *"skipping gitmade: its version is not a release of gitmade"* ]] || false
  [[ "$output" == *"not re-adding ms@2.1.3 this run: it shares an install group with gitmade, and it is not a registry release"* ]] || false
}

@test "pnpm: pnpm 10's global packages, which pnpm 11 no longer lists, are migrated by 'pnpm update -g' — or pointed out under the cooldown" {
  need_node
  npm_fixture
  pnpm_fixture # pnpm 12, nothing in global/v11 …
  mkdir -p "$SANDBOX/pnhome/global/5"
  printf '{"dependencies":{"ms":"2.1.1","is-odd":"^2.0.0"}}' >"$SANDBOX/pnhome/global/5/package.json" # … but pnpm 10's are there
  run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  grep -qx 'pnpm update -g' "$CALL_LOG" # migrates them
  : >"$CALL_LOG"
  CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  refute grep -q '^pnpm update' "$CALL_LOG"
  [[ "$output" == *"2 global package(s) are still in pnpm 10's global directory"* ]] || false
  grep -qx $'note\tpnpm 10 global packages not migrated — run \'pnpm update -g\' once' "$SANDBOX/report"
  : >"$CALL_LOG"
  PNPM_VER=10.34.6 run run_cleaner 31-pnpm.sh # pnpm 10 itself: its global/5 is not "legacy"
  refute grep -q '^pnpm root' "$CALL_LOG"
}

@test "pnpm: a pnpm older than 9.13 cannot be told a version, so its self-update is held under the cooldown" {
  need_node
  npm_fixture
  npm_view pnpm 9.15.9 9.12.3:400 9.13.0:350 9.15.9:300
  pnpm_fixture
  PNPM_VER=9.12.3 CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  refute grep -q '^pnpm self-update' "$CALL_LOG"
  [[ "$output" == *"pnpm 9.12.3 cannot be told which release to self-update to"* ]] || false
  grep -qx $'note\tpnpm self-update held: pnpm < 9.13 cannot self-update to a release old enough' "$SANDBOX/report"
  : >"$CALL_LOG"
  PNPM_VER=9.13.0 CMM_COOLDOWN_DAYS=7 run run_cleaner 31-pnpm.sh
  grep -qx 'pnpm self-update 9.15.9' "$CALL_LOG"
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
  grep -qx 'pnpm add -g ms@^2.1.3 --config.minimum-release-age=10080' "$CALL_LOG"
  grep -qx 'pnpm add -g is-odd@^2.1.0 --config.minimum-release-age=10080' "$CALL_LOG"
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

@test "pnpm: the self-update names the newest release old enough, and is held while every newer one is too fresh" {
  need_node
  npm_fixture
  npm_view pnpm 12.8.1 12.6.0:90 12.7.0:9 12.8.0:5 12.8.1:1
  pnpm_fixture
  PNPM_VER=12.6.0 CMM_COOLDOWN_DAYS=7 run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  grep -qx 'pnpm self-update 12.7.0' "$CALL_LOG"
  : >"$CALL_LOG"
  PNPM_VER=12.7.0 CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 31-pnpm.sh
  [ "$status" -eq 0 ]
  refute grep -q '^pnpm self-update' "$CALL_LOG"
  [[ "$output" == *"pnpm 12.7.0: pnpm 12.8.1 is too fresh"* ]] || false
  grep -qx $'note\tpnpm self-update held by the cooldown (the 7-day cooldown)' "$SANDBOX/report"
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

# bun_fixture [no-globals] — a bun stub that fails the way Bun 1.1–1.4 do:
# `bun pm cache [rm]` needs a package.json in the current directory, their
# -g forms and `bun update -g`/`bun outdated -g`/`bun pm ls -g` one in the
# global directory ($SANDBOX/bunglobal, which `bun pm ls -g` names, as Bun
# does). `--version` prints $BUN_VER (1.4.2); with BUN_BLOCK set, a gated
# update fails like Bun 1.3 blocked by another global's fresh range; `bun
# outdated -g` prints Bun's banner and $SANDBOX/bun-outdated.txt (an empty
# file: all up to date), and fails when that file is absent (then every
# global is looked up). The working directory of each cache command is
# logged to $SANDBOX/bun-cwd. bun_dep NAME SPEC VERSION [REALNAME] adds a
# global package.
bun_fixture() {
  mkdir -p "$SANDBOX/bunglobal/node_modules" "$SANDBOX/buncache"
  [ "${1:-}" = no-globals ] || printf '{"dependencies":{}}' >"$SANDBOX/bunglobal/package.json"
  cat >"$STUB_BIN/bun" <<'EOF'
#!/bin/sh
printf '%s %s\n' bun "$*" >>"$CALL_LOG"
g="$SANDBOX/bunglobal"
nopkg() { echo "error: No package.json was found for directory \"$1\"" >&2; exit 1; }
case "$1 $2" in
  "--version "*) echo "${BUN_VER:-1.4.2}" ;;
  "pm ls")
    [ -f "$g/package.json" ] || nopkg "$g"
    echo "$g node_modules (1)" ;;
  "pm cache")
    pwd -P >>"$SANDBOX/bun-cwd"
    case " $* " in
      *" -g "*) [ -f "$g/package.json" ] || nopkg "$g" ;;
      *) [ -f package.json ] || nopkg "$PWD" ;;
    esac
    [ "$3" = rm ] && { rm -rf "$SANDBOX/buncache"; echo "Cleared 'bun install' cache"; exit 0; }
    echo "$SANDBOX/buncache" ;;
  "update -g")
    [ -f "$g/package.json" ] || { echo "No package.json, so nothing to update" >&2; exit 1; }
    case "$*" in
      *--minimum-release-age*)
        if [ -n "${BUN_BLOCK:-}" ]; then
          echo 'error: No version matching "@types/node" found for specifier "^26.6.4" (blocked by minimum-release-age: 604800 seconds)' >&2
          exit 1
        fi ;;
    esac ;;
  "outdated -g")
    [ -f "$g/package.json" ] || { echo "error: missing package.json, nothing outdated" >&2; exit 1; }
    [ -f "$SANDBOX/bun-outdated.txt" ] || exit 1
    echo "bun outdated v${BUN_VER:-1.4.2} (744846f84)"
    cat "$SANDBOX/bun-outdated.txt" ;;
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

# bun_release VERSION DAYS_AGO — what GitHub's release feed (the one `bun
# upgrade` reads) answers; "fail" for no answer at all.
bun_release() {
  if [ "$1" = fail ]; then
    make_stub curl 22
    return 0
  fi
  local when
  when="$(date -u -v-"$2"d '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null || date -u -d "$2 days ago" '+%Y-%m-%dT%H:%M:%SZ')"
  make_stub curl 0 "{\"tag_name\":\"bun-v$1\",\"published_at\":\"$when\"}"
}

bun_mutating() { grep -E '^bun (update|upgrade|pm cache rm)' "$CALL_LOG" || true; }

@test "bun: without a cooldown: standalone upgrade, global update, cache rm from a scratch dir holding {} (F, finding 2)" {
  bun_fixture
  mkdir -p "$SANDBOX/somewhere"
  cd "$SANDBOX/somewhere"
  run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  bun_mutating >"$SANDBOX/mutating"
  diff "$SANDBOX/mutating" - <<'EOF'
bun upgrade
bun update -g
bun pm cache rm
EOF
  local cwd
  cwd="$(tail -n 1 "$SANDBOX/bun-cwd")"
  [ "$cwd" != "$SANDBOX/somewhere" ]
  [[ "$cwd" == "$TMPDIR"/scrubmac-* ]] || false
  [ ! -e "$cwd" ] # removed again
  [ ! -e "$SANDBOX/somewhere/package.json" ]
}

@test "bun: no global packages is not a failure — no 'bun update -g', the cache is still cleared (finding 2)" {
  bun_fixture no-globals
  run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  refute grep -q '^bun update' "$CALL_LOG"
  [[ "$output" == *"no global Bun packages"* ]] || false
  grep -qx 'bun pm cache rm' "$CALL_LOG"
  [ ! -d "$SANDBOX/buncache" ]
  : >"$CALL_LOG"
  mkdir -p "$SANDBOX/buncache"
  CMM_MODE=status run run_cleaner 33-bun.sh # the size query works without globals too
  [ "$status" -eq 0 ]
  [[ "$output" == *"cache $SANDBOX/buncache"* ]] || false
}

@test "bun: the cooldown moves each global within its saved range, --minimum-release-age holding its dependencies (S4)" {
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
  bun_release 1.4.2 30
  CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  bun_mutating >"$SANDBOX/mutating"
  diff "$SANDBOX/mutating" - <<'EOF'
bun update -g ms@2.1.3 --minimum-release-age 604800
bun update -g @types/node@26.5.1 --minimum-release-age 604800
bun pm cache rm
EOF
  [[ "$output" == *"is-number: pinned to 6.0.0 — left alone"* ]] || false
  [[ "$output" == *"skipping kleur-alias: an aliased install"* ]] || false
}

@test "bun: a release the saved range allows but younger than the cooldown is held — by its age alone" {
  need_node
  npm_fixture
  bun_fixture
  bun_dep ms '^2.1.1' 2.1.1
  npm_view ms 2.1.3 2.1.1:900 2.1.3:1 # inside ^2.1.1; only its age stops it
  bun_release 1.4.2 30
  CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  refute grep -q '^bun update -g ms' "$CALL_LOG"
  refute grep -q '^bun add' "$CALL_LOG"
  [[ "$output" == *"ms 2.1.1: every newer release its range allows is too fresh (ms 2.1.3) — held"* ]] || false
  grep -qx $'note\t1 global update(s) held by the cooldown (the 7-day cooldown)' "$SANDBOX/report"
  : >"$CALL_LOG"
  run run_cleaner 33-bun.sh # without the cooldown it goes through
  grep -qx 'bun update -g' "$CALL_LOG"
}

@test "bun: Bun 1.3 blocked by another global's fresh range holds the rest — not a failure" {
  need_node
  npm_fixture
  bun_fixture
  bun_dep ms '^2.1.1' 2.1.1
  bun_dep is-odd '^2.0.0' 2.0.0
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700
  npm_view is-odd 2.1.0 2.0.0:900 2.1.0:700
  BUN_VER=1.3.13 BUN_BLOCK=1 CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  [ "$(grep -c '^bun update -g' "$CALL_LOG")" -eq 1 ] # the second pick is held, not tried
  [[ "$output" == *"blocked by minimum-release-age"* ]] || false # Bun's own message is shown
  grep -q $'^note\tglobal updates held: Bun < 1.4 blocks them' "$SANDBOX/report"
  : >"$CALL_LOG"
  BUN_VER=1.3.13 CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh # not blocked: both go through
  [ "$(grep -c '^bun update -g' "$CALL_LOG")" -eq 2 ]
  : >"$CALL_LOG"
  BUN_VER=1.3.13 CMM_COOLDOWN_DAYS=7 CMM_DRY_RUN=1 run run_cleaner 33-bun.sh
  [[ "$output" == *"+ bun update -g ms@2.1.3 --minimum-release-age 604800"* ]] || false
  refute grep -q '^bun update' "$CALL_LOG"
}

@test "bun: Bun < 1.3 (no --minimum-release-age) holds global updates under the cooldown" {
  need_node
  npm_fixture
  bun_fixture
  bun_dep ms '^2.1.1' 2.1.1
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700
  BUN_VER=1.2.21 CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  refute grep -q '^bun update' "$CALL_LOG"
  [[ "$output" == *"predates --minimum-release-age (1.3)"* ]] || false
}

@test "bun: your stricter bunfig minimumReleaseAge wins over the cooldown — and applies with it off" {
  need_node
  npm_fixture
  bun_fixture
  bun_dep tool '^1.0.0' 1.0.0
  npm_view tool 1.3.0 1.0.0:90 1.1.0:30 1.2.0:10 1.3.0:1
  # the global bunfig Bun reads: $XDG_CONFIG_HOME/.bunfig.toml when that is set
  mkdir -p "$XDG_CONFIG_HOME"
  printf '[install]\nminimumReleaseAge = 1209600.0 # a float\n' >"$XDG_CONFIG_HOME/.bunfig.toml"
  CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  grep -qx 'bun update -g tool@1.1.0 --minimum-release-age 1209600' "$CALL_LOG"
  [[ "$output" == *"(the 7-day cooldown; bunfig minimumReleaseAge=1209600)"* ]] || false
  : >"$CALL_LOG"
  run run_cleaner 33-bun.sh # cooldown off: never a plain update that would relax nothing
  grep -qx 'bun update -g tool@1.1.0 --minimum-release-age 1209600' "$CALL_LOG"
  refute grep -qx 'bun update -g' "$CALL_LOG"
}

@test "bun: a bunfig.toml in Bun's global directory counts too — Bun reads it for every -g command" {
  need_node
  npm_fixture
  bun_fixture
  bun_dep tool '^1.0.0' 1.0.0
  npm_view tool 1.3.0 1.0.0:90 1.1.0:30 1.2.0:10 1.3.0:1
  printf '[install]\nminimumReleaseAge = 1209600\n' >"$SANDBOX/bunglobal/bunfig.toml"
  CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  grep -qx 'bun update -g tool@1.1.0 --minimum-release-age 1209600' "$CALL_LOG"
  [[ "$output" == *"(the 7-day cooldown; bunfig minimumReleaseAge=1209600)"* ]] || false
}

@test "bun: a bunfig minimumReleaseAge with no integer to trust (inf, too large, unreadable) holds bun upgrade and global updates" {
  need_node
  npm_fixture
  bun_fixture
  bun_dep tool '^1.0.0' 1.0.0
  npm_view tool 1.3.0 1.0.0:90 1.1.0:30 1.2.0:10 1.3.0:1
  bun_release 1.4.2 30
  mkdir -p "$XDG_CONFIG_HOME"
  printf '[install]\nminimumReleaseAge = inf # never old enough\n' >"$XDG_CONFIG_HOME/.bunfig.toml"
  CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  refute grep -Eq '^bun (update|upgrade)' "$CALL_LOG" # --minimum-release-age 604800 would relax it
  [[ "$output" == *"bun upgrade and global updates held: your bunfig's install.minimumReleaseAge cannot be read as a number of seconds here"* ]] || false
  grep -qx $'note\tBun updates held: bunfig install.minimumReleaseAge could not be read' "$SANDBOX/report"
  grep -qx 'bun pm cache rm' "$CALL_LOG" # cleaning is unaffected
  : >"$CALL_LOG"
  printf 'x = {\n[install]\nminimumReleaseAge = 1209600\n' >"$SANDBOX/bunglobal/bunfig.toml" # the global dir's, unbalanced
  rm "$XDG_CONFIG_HOME/.bunfig.toml"
  run run_cleaner 33-bun.sh # the cooldown off: a plain 'bun update -g' would fail on it
  [ "$status" -eq 0 ]
  refute grep -Eq '^bun (update|upgrade)' "$CALL_LOG"
}

@test "bun: the global bunfig is the one Bun reads — ~/.bunfig.toml only without XDG_CONFIG_HOME" {
  need_node
  npm_fixture
  bun_fixture
  bun_dep tool '^1.0.0' 1.0.0
  npm_view tool 1.3.0 1.0.0:90 1.1.0:30 1.2.0:10 1.3.0:1
  printf '[install]\nminimumReleaseAge = 1209600\n' >"$HOME/.bunfig.toml"
  CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh # XDG_CONFIG_HOME is set: Bun ignores ~/.bunfig.toml
  grep -qx 'bun update -g tool@1.2.0 --minimum-release-age 604800' "$CALL_LOG"
  : >"$CALL_LOG"
  env -u XDG_CONFIG_HOME CMM_COOLDOWN_DAYS=7 CMM_LIB="$CMM_LIB_PATH" "$REPO_ROOT/cleaners/33-bun.sh" >/dev/null 2>&1 </dev/null
  grep -qx 'bun update -g tool@1.1.0 --minimum-release-age 1209600' "$CALL_LOG"
}

@test "bun: under the cooldown a * or latest global is left alone — Bun would rewrite it into an exact pin" {
  need_node
  npm_fixture
  bun_fixture
  bun_dep ms '*' 2.1.1
  bun_dep semver 'latest' 7.0.0
  bun_dep is-odd '~2' 2.0.0
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700
  npm_view semver 7.8.5 7.0.0:900 7.8.5:60
  bun_release 1.4.2 30
  CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  refute grep -q '^bun update -g' "$CALL_LOG"
  [[ "$output" == *"ms: its saved range '*' would be rewritten by a versioned update"* ]] || false
  [[ "$output" == *"semver: its saved range 'latest' would be rewritten"* ]] || false
  [[ "$output" == *"is-odd: its saved range '~2' would be rewritten"* ]] || false
}

@test "bun: globals Bun's isolated linker links in from node_modules/.bun are updated like any other" {
  need_node
  npm_fixture
  bun_fixture
  local g="$SANDBOX/bunglobal"
  mkdir -p "$g/node_modules/.bun/ms@2.1.1/node_modules/ms"
  printf '{"name":"ms","version":"2.1.1"}' >"$g/node_modules/.bun/ms@2.1.1/node_modules/ms/package.json"
  ln -s .bun/ms@2.1.1/node_modules/ms "$g/node_modules/ms"
  printf '{"dependencies":{"ms":"^2.1.1"}}' >"$g/package.json"
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700
  bun_release 1.4.2 30
  CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  grep -qx 'bun update -g ms@2.1.3 --minimum-release-age 604800' "$CALL_LOG"
}

@test "bun: under the cooldown 'bun upgrade' runs when Bun's newest release is old enough, and is held otherwise" {
  need_node
  npm_fixture
  bun_fixture
  bun_release 1.4.2 30
  BUN_VER=1.3.13 CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  grep -qx 'bun upgrade' "$CALL_LOG"
  grep -q '^curl .*api.github.com/repos/Jarred-Sumner/bun-releases-for-updater/releases/latest$' "$CALL_LOG"
  : >"$CALL_LOG"
  bun_release 1.4.2 2
  BUN_VER=1.3.13 CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 33-bun.sh
  refute grep -q '^bun upgrade' "$CALL_LOG"
  [[ "$output" == *"bun upgrade held: Bun 1.4.2 is too fresh"* ]] || false
  grep -qx $'note\tbun upgrade held by the cooldown (the 7-day cooldown)' "$SANDBOX/report"
  : >"$CALL_LOG"
  BUN_VER=1.4.2 CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh
  [[ "$output" == *"bun 1.4.2 is up to date"* ]] || false
  BUN_VER=1.5.0-canary.20261003.1 CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh
  [[ "$output" == *"is a canary build"* ]] || false
  refute grep -q '^bun upgrade' "$CALL_LOG"
  bun_release fail
  BUN_VER=1.3.13 CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh
  [[ "$output" == *"could not check the age of Bun's newest release"* ]] || false
  refute grep -q '^bun upgrade' "$CALL_LOG"
}

@test "bun: BUN_CANARY=1 holds 'bun upgrade' under the cooldown (it would install the newest canary)" {
  need_node
  npm_fixture
  bun_fixture
  bun_release 1.4.2 30
  BUN_CANARY=1 BUN_VER=1.3.13 CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  refute grep -q '^bun upgrade' "$CALL_LOG"
  [[ "$output" == *"BUN_CANARY=1 makes it install the newest canary"* ]] || false
  grep -qx $'note\tbun upgrade held (BUN_CANARY=1, the 7-day cooldown)' "$SANDBOX/report"
}

@test "bun: the release check sends GITHUB_TOKEN (or GITHUB_ACCESS_TOKEN) as Bun does — on stdin, never in argv" {
  need_node
  npm_fixture
  bun_fixture
  local when
  when="$(ago 30)"
  make_stub_script curl <<EOF
cat >"\$SANDBOX/curl-stdin"
echo '{"tag_name":"bun-v1.4.2","published_at":"$when"}'
EOF
  GITHUB_TOKEN='ghp_s3cret"x' BUN_VER=1.3.13 CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  grep -qx 'bun upgrade' "$CALL_LOG"
  grep -qx 'header = "Authorization: Bearer ghp_s3cret\\"x"' "$SANDBOX/curl-stdin"
  refute grep -q 's3cret' "$CALL_LOG" # never on a command line
  grep -q '^curl .* -K - ' "$CALL_LOG"
  GITHUB_ACCESS_TOKEN=gho_other BUN_VER=1.3.13 CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh
  grep -qx 'header = "Authorization: Bearer gho_other"' "$SANDBOX/curl-stdin"
  BUN_VER=1.3.13 CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh # no token: nothing sent
  [ ! -s "$SANDBOX/curl-stdin" ]
}

@test "bun: with the cooldown on but no node/npm, global updates and the upgrade are held" {
  bun_fixture
  bun_dep ms '^2.1.1' 2.1.1
  CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  refute grep -Eq '^bun (update|upgrade)' "$CALL_LOG"
  grep -qx 'bun pm cache rm' "$CALL_LOG"
  [[ "$output" == *"global updates are held"* ]] || false
  [[ "$output" == *"bun upgrade held"* ]] || false
}

@test "bun: globals Bun reports at their latest release are not looked up" {
  need_node
  npm_fixture
  bun_fixture
  bun_dep ms '^2.1.1' 2.1.1
  bun_dep globby '^16.2.4' 16.2.4
  printf '| Package | Current | Update | Latest |\n|---------|---------|--------|--------|\n| ms      | 2.1.1   | 2.1.1  | 2.1.3  |\n' >"$SANDBOX/bun-outdated.txt"
  npm_view ms 2.1.3 2.1.1:900 2.1.3:700
  bun_release 1.4.2 30
  CMM_COOLDOWN_DAYS=7 run run_cleaner 33-bun.sh
  [ "$status" -eq 0 ]
  grep -qx 'bun update -g ms@2.1.3 --minimum-release-age 604800' "$CALL_LOG"
  refute grep -q '^npm view globby' "$CALL_LOG"
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

@test "codex: a copy a version manager owns is left to it (codex update would overwrite it)" {
  local mise="$HOME/.local/share/mise"
  mkdir -p "$mise/installs/codex/0.130.0/bin"
  cat >"$mise/installs/codex/0.130.0/bin/codex" <<'EOF'
#!/bin/sh
printf '%s %s\n' codex "$*" >>"$CALL_LOG"
[ "$1" = --help ] && printf 'Commands:\n  update    Update Codex to the latest version\n'
exit 0
EOF
  chmod 755 "$mise/installs/codex/0.130.0/bin/codex"
  export PATH="$mise/installs/codex/0.130.0/bin:$PATH"
  run run_cleaner 46-codex.sh
  [ "$status" -eq 0 ]
  [[ "$output" == *"codex runs through mise"* ]] || false
  refute grep -q 'codex update' "$CALL_LOG"
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

# gh_stub LIST_RC EXTENSIONS [UPGRADE_RC] — `gh extension list` prints
# EXTENSIONS (one per line, no quotes) and exits LIST_RC (4 is gh's "not
# logged in"); `gh auth status` exits 1, as it does whenever any account on
# any host has a problem, so the cleaner must not depend on it.
gh_stub() {
  cat >"$STUB_BIN/gh" <<EOF
#!/bin/sh
printf '%s %s\n' gh "\$*" >>"\$CALL_LOG"
case "\$1 \$2" in
  "auth status") exit 1 ;;
  "extension list") printf '%s' "$2"; exit $1 ;;
  "extension upgrade") exit ${3:-0} ;;
esac
exit 0
EOF
  chmod 755 "$STUB_BIN/gh"
}

@test "gh: logged in with extensions — upgrades them all, even when another account has auth problems" {
  gh_stub 0 'dlvhdr/gh-dash'
  run run_cleaner 48-gh.sh
  [ "$status" -eq 0 ]
  diff "$CALL_LOG" - <<'EOF'
gh extension list
gh extension upgrade --all
EOF
  gh_stub 0 'dlvhdr/gh-dash' 1
  run run_cleaner 48-gh.sh
  [ "$status" -eq 1 ] # a real upgrade failure fails the cleaner
}

@test "gh: not logged in ('gh extension list' exits 4) — skipped with the reason; no upgrade" {
  gh_stub 4 ''
  run run_cleaner 48-gh.sh
  [ "$status" -eq 75 ]
  [[ "$output" == *"gh is not logged in"* ]] || false
  diff "$CALL_LOG" - <<'EOF'
gh extension list
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
  [ "$(grep -c '^gh extension list$' "$CALL_LOG")" -eq 2 ] # the probe, then the report
  : >"$CALL_LOG"
  gh_stub 4 ''
  CMM_MODE=status run run_cleaner 48-gh.sh
  [ "$(grep -c '^gh extension list$' "$CALL_LOG")" -eq 1 ]
  [[ "$output" == *"gh is not logged in"* ]] || false
  [[ "$output" != *"exited 4"* ]] || false
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

@test "xcode: a project directly inside a folder this run cannot list is unknown, not gone" {
  xcode_env
  mkdir -p "$SANDBOX/Desktop" "$DD/Desk-abc"
  # the parent exists but cannot be listed: only the listability check
  # (not the existence of the parent) can tell this apart from "gone"
  printf 'LastAccessedDate=%s\nWorkspacePath=%s\n' "$(ago_iso 1)" "$SANDBOX/Desktop/Proj.xcodeproj" >"$DD/Desk-abc/info.plist"
  unreadable "$SANDBOX/Desktop"
  run run_cleaner 70-xcode.sh
  chmod 755 "$SANDBOX/Desktop"
  [ "$status" -eq 0 ]
  [ -d "$DD/Desk-abc" ]
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
# via PRUNE_MODE (ok | busy | broken); `tool dir` points into the sandbox;
# `tool list --outdated` prints $SANDBOX/uv-outdated.txt. uv_stub DIR puts
# it in DIR instead of the stub dir (DIR goes first on PATH).
uv_stub() {
  local dir="${1:-$STUB_BIN}"
  mkdir -p "$dir"
  [ "$dir" = "$STUB_BIN" ] || export PATH="$dir:$PATH"
  cat >"$dir/uv" <<EOF
#!/bin/sh
printf '%s %s\n' uv "\$*" >>"\$CALL_LOG"
case "\$1 \$2" in
  "--version "*) echo "uv \${UV_VER:-0.12.22} (Homebrew)"; exit 0 ;;
  "cache dir") echo "$SANDBOX/uvcache"; exit 0 ;;
  "tool dir") echo "$SANDBOX/uvtools"; exit 0 ;;
  "tool list") cat "$SANDBOX/uv-outdated.txt" 2>/dev/null; exit 0 ;;
  "cache prune")
    case "\${PRUNE_MODE:-ok}" in
      busy) echo "Cache is currently in-use, waiting for other uv processes to finish (use \\\`--force\\\` to override)" >&2
            echo "error: Timeout (15s) when waiting for lock on \\\`/c\\\` at \\\`/c/.lock\\\`, is another uv process running?" >&2; exit 2 ;;
      broken) echo "error: permission denied" >&2; exit 2 ;;
    esac ;;
esac
exit 0
EOF
  chmod 755 "$dir/uv"
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

@test "python: only the first receipt uv would read counts (XDG_CONFIG_HOME/uv before ~/.config/uv)" {
  uv_stub
  mkdir -p "$SANDBOX/another-copy"
  export XDG_CONFIG_HOME="$SANDBOX/xdg"
  uv_receipt "$XDG_CONFIG_HOME/uv" "$SANDBOX/another-copy" # what uv reads first: another copy
  uv_receipt "$HOME/.config/uv" "$STUB_BIN"                # a matching one further down the list
  run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  refute grep -q '^uv self update' "$CALL_LOG"
  rm -rf "$XDG_CONFIG_HOME/uv" # now ~/.config/uv is the first one
  : >"$CALL_LOG"
  run run_cleaner 40-python.sh
  grep -qx 'uv self update' "$CALL_LOG"
}

@test "python: a uv in PREFIX/bin matches a receipt for PREFIX — and only that PREFIX" {
  uv_stub "$SANDBOX/inst/bin"
  uv_receipt "$XDG_CONFIG_HOME/uv" "$SANDBOX/inst"
  run run_cleaner 40-python.sh
  grep -qx 'uv self update' "$CALL_LOG"
  mkdir -p "$SANDBOX/other"
  uv_receipt "$XDG_CONFIG_HOME/uv" "$SANDBOX/other"
  : >"$CALL_LOG"
  run run_cleaner 40-python.sh
  refute grep -q '^uv self update' "$CALL_LOG"
}

@test "python: the cooldown is a relative span for uv >= 0.11.4 and --cooldown for pipx (S4)" {
  uv_stub
  pipx_stub with-cooldown
  CMM_COOLDOWN_DAYS=7 run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  grep -qx 'uv tool upgrade --all --exclude-newer 7 days' "$CALL_LOG"
  grep -qx 'pipx upgrade-all --cooldown 7' "$CALL_LOG"
}

@test "python: under the cooldown your stricter exclude-newer and PIPX_COOLDOWN win — the flags would override them" {
  uv_stub
  pipx_stub with-cooldown
  mkdir -p "$XDG_CONFIG_HOME/uv"
  printf '# mine\nexclude-newer = "2023-09-01"\n\n[pip]\nexclude-newer = "1 day"\n' >"$XDG_CONFIG_HOME/uv/uv.toml"
  PIPX_COOLDOWN=36500 CMM_COOLDOWN_DAYS=7 run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  grep -qx 'uv tool upgrade --all --exclude-newer 2023-09-01' "$CALL_LOG"
  grep -qx 'pipx upgrade-all --cooldown 36500' "$CALL_LOG"
  : >"$CALL_LOG"
  printf "exclude-newer = '3 weeks'\n" >"$XDG_CONFIG_HOME/uv/uv.toml" # a stricter span stays a span
  CMM_COOLDOWN_DAYS=7 run run_cleaner 40-python.sh
  grep -qx 'uv tool upgrade --all --exclude-newer 3 weeks' "$CALL_LOG"
  : >"$CALL_LOG"
  printf 'exclude-newer = "P2D"\n' >"$XDG_CONFIG_HOME/uv/uv.toml" # looser: the cooldown's
  PIPX_COOLDOWN=2 CMM_COOLDOWN_DAYS=7 run run_cleaner 40-python.sh
  grep -qx 'uv tool upgrade --all --exclude-newer 7 days' "$CALL_LOG"
  grep -qx 'pipx upgrade-all --cooldown 7' "$CALL_LOG"
  : >"$CALL_LOG"
  UV_EXCLUDE_NEWER='30 days' CMM_COOLDOWN_DAYS=7 run run_cleaner 40-python.sh # the variable beats the file
  grep -qx 'uv tool upgrade --all --exclude-newer 30 days' "$CALL_LOG"
}

@test "python: an exclude-newer of yours that cannot be read holds uv tool upgrades — passing either value might relax the other" {
  uv_stub
  pipx_stub with-cooldown
  UV_EXCLUDE_NEWER='a fortnight-ish' CMM_COOLDOWN_DAYS=7 CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  refute grep -q '^uv tool upgrade' "$CALL_LOG"
  [[ "$output" == *"uv tool upgrades held: your exclude-newer ('a fortnight-ish') cannot be read here"* ]] || false
  grep -qx $'note\tuv tool upgrades held: your exclude-newer could not be read' "$SANDBOX/report"
  grep -qx 'pipx upgrade-all --cooldown 7' "$CALL_LOG" # pipx unaffected
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

@test "python: with the cooldown off, the receipt cutoffs holding tools back are cleared; pipx gets --cooldown 0" {
  uv_stub
  pipx_stub with-cooldown
  uv_tool ruff 'exclude-newer = "2025-01-01T00:00:00Z"'
  uv_tool black 'exclude-newer = "2026-09-27T00:00:00Z"' 'exclude-newer-span = "P7D"'
  uv_tool mypy 'exclude-newer = false'
  uv_tool httpie
  # without the cutoffs, ruff and black would upgrade (uv rewrites a receipt
  # only when its tool upgrades, so clearing the others would repeat forever)
  printf 'black v24.1.0 [latest: 24.10.0]\n- black\nruff v0.1.0 [latest: 0.9.0]\n- ruff\n' >"$SANDBOX/uv-outdated.txt"
  run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  grep -qx 'uv tool list --outdated --exclude-newer false --color never' "$CALL_LOG"
  grep -E '^(uv tool upgrade|pipx upgrade-all)( |$)' "$CALL_LOG" | grep -v -- --help >"$SANDBOX/upgrades"
  diff "$SANDBOX/upgrades" - <<'EOF'
uv tool upgrade black --exclude-newer false
uv tool upgrade ruff --exclude-newer false
uv tool upgrade --all
pipx upgrade-all --cooldown 0
EOF
  [[ "$output" == *"cleared the exclude-newer cutoff an earlier cooldown left in 2 uv tool receipt(s)"* ]] || false
}

@test "python: a receipt cutoff on a tool already at its newest release is left alone (no repeated work)" {
  uv_stub
  uv_tool black 'exclude-newer = "2026-09-27T00:00:00Z"' 'exclude-newer-span = "P7D"'
  : >"$SANDBOX/uv-outdated.txt" # nothing would upgrade even without the cutoff
  run run_cleaner 40-python.sh
  [ "$status" -eq 0 ]
  refute grep -q -- 'upgrade black' "$CALL_LOG"
  [[ "$output" != *"cleared the exclude-newer"* ]] || false
  grep -qx 'uv tool upgrade --all' "$CALL_LOG"
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

@test "python: a date in your exclude-newer means the end of that day, and timestamp offsets count — as uv reads them" {
  uv_stub
  mkdir -p "$XDG_CONFIG_HOME/uv"
  export TZ=UTC
  local d stamp
  # the day that holds "7 days ago": uv's cutoff is its END (the next local
  # midnight), later than the cooldown's — so the cooldown is the stricter
  d="$(date -u -v-7d '+%Y-%m-%d' 2>/dev/null || date -u -d '7 days ago' '+%Y-%m-%d')"
  printf 'exclude-newer = "%s"\n' "$d" >"$XDG_CONFIG_HOME/uv/uv.toml"
  CMM_COOLDOWN_DAYS=7 run run_cleaner 40-python.sh
  grep -qx 'uv tool upgrade --all --exclude-newer 7 days' "$CALL_LOG"
  : >"$CALL_LOG"
  # 6 hours further back on the clock, but at UTC-12: 6 hours LESS far back
  stamp="$(date -u -v-7d -v-6H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -d '7 days ago 6 hours ago' '+%Y-%m-%dT%H:%M:%S')"
  printf 'exclude-newer = "%s-12:00"\n' "$stamp" >"$XDG_CONFIG_HOME/uv/uv.toml"
  CMM_COOLDOWN_DAYS=7 run run_cleaner 40-python.sh
  grep -qx 'uv tool upgrade --all --exclude-newer 7 days' "$CALL_LOG"
  : >"$CALL_LOG"
  printf 'exclude-newer = "%sZ"\n' "$stamp" >"$XDG_CONFIG_HOME/uv/uv.toml" # the same clock in UTC: stricter
  CMM_COOLDOWN_DAYS=7 run run_cleaner 40-python.sh
  grep -qx "uv tool upgrade --all --exclude-newer ${stamp}Z" "$CALL_LOG"
}

@test "python: exclude-newer is read as uv reads it — a date and time without an offset is that date's end; ±hh, a space, t/z, no seconds, 'ago'" {
  uv_stub
  export TZ=UTC
  local d stamp fresh over hour v
  d="$(date -u -v-7d '+%Y-%m-%d' 2>/dev/null || date -u -d '7 days ago' '+%Y-%m-%d')"
  stamp="$(date -u -v-7d -v-6H '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -d '7 days ago 6 hours ago' '+%Y-%m-%dT%H:%M:%S')"
  fresh="$(date -u -v-6d '+%Y-%m-%d %H:%M' 2>/dev/null || date -u -d '6 days ago' '+%Y-%m-%d %H:%M')"
  over="$(date -u -v-7d -v-1M '+%Y-%m-%dT%H:%M:%S' 2>/dev/null || date -u -d '7 days ago 1 minute ago' '+%Y-%m-%dT%H:%M:%S')"
  hour="$(date -u -v-8d '+%Y-%m-%d %H' 2>/dev/null || date -u -d '8 days ago' '+%Y-%m-%d %H')"
  # each reaches less far back than the 7-day cooldown, as uv reads it: a
  # date and time with no offset is a date to uv (its END), the -12 offset
  # puts the stamp 12 hours later, and the rest are 6 and 3 days back
  for v in "${d}T00:00:01" "${stamp/T/t}-12" "${fresh}z" "3 days ago"; do
    : >"$CALL_LOG"
    UV_EXCLUDE_NEWER="$v" CMM_COOLDOWN_DAYS=7 run run_cleaner 40-python.sh
    [ "$status" -eq 0 ]
    grep -qx 'uv tool upgrade --all --exclude-newer 7 days' "$CALL_LOG" || {
      echo "$v: $(grep '^uv tool upgrade' "$CALL_LOG")"
      false
    }
  done
  # and each of these further back: yours, as written
  for v in "${stamp}+00" "${over}z" "${hour}Z"; do
    : >"$CALL_LOG"
    UV_EXCLUDE_NEWER="$v" CMM_COOLDOWN_DAYS=7 run run_cleaner 40-python.sh
    [ "$status" -eq 0 ]
    grep -qx "uv tool upgrade --all --exclude-newer $v" "$CALL_LOG" || {
      echo "$v: $(grep '^uv tool upgrade' "$CALL_LOG")"
      false
    }
  done
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
# sqlite3 stub reports them; PC_DB=locked makes it fail like a database
# held past the busy timeout, PC_DB=new like a store with no configs table).
pc_env() {
  make_stub pre-commit
  mkdir -p "$HOME/.cache/pre-commit"
  : >"$HOME/.cache/pre-commit/db.db"
  printf '%s\n' "$@" >"$SANDBOX/pc-configs"
  make_stub_script sqlite3 <<'EOF'
case "${PC_DB:-ok}" in
  locked) echo "Error: database is locked" >&2; exit 5 ;;
  new)
    case "$*" in
      *sqlite_master*) echo 0 ;;
      *) echo "Parse error: no such table: configs" >&2; exit 1 ;;
    esac ;;
  *) cat "$SANDBOX/pc-configs" ;;
esac
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
  grep -qx "sqlite3 -init /dev/null -batch -list -noheader -readonly -cmd .timeout 5000 $HOME/.cache/pre-commit/db.db SELECT path FROM configs" "$CALL_LOG"
  grep -qx 'pre-commit gc' "$CALL_LOG"
}

@test "pre-commit: a database that cannot be read (locked past the busy timeout) skips gc; a store with no configs table does not" {
  pc_env "/Volumes/scrubmac-test-absent-$$/proj/.pre-commit-config.yaml"
  PC_DB=locked CMM_REPORT_FILE="$SANDBOX/report" run run_cleaner 63-pre-commit.sh
  [ "$status" -eq 0 ]
  refute grep -q 'pre-commit gc' "$CALL_LOG"
  [[ "$output" == *"pre-commit's database ($HOME/.cache/pre-commit/db.db) could not be read"* ]] || false
  : >"$CALL_LOG"
  PC_DB=new run run_cleaner 63-pre-commit.sh # nothing recorded yet: gc has nothing to misjudge
  [ "$status" -eq 0 ]
  grep -qx 'pre-commit gc' "$CALL_LOG"
}

@test "pre-commit: your sqliterc's output mode cannot garble the recorded paths (the blind spot is still seen)" {
  pc_env "/Volumes/scrubmac-test-absent-$$/proj/.pre-commit-config.yaml"
  # like a ~/.sqliterc or $XDG_CONFIG_HOME/sqlite3/sqliterc with ".mode json"
  # — which only -init /dev/null keeps from loading
  make_stub_script sqlite3 <<'EOF'
case " $* " in
  *" -init /dev/null "*) cat "$SANDBOX/pc-configs" ;;
  *) sed 's/.*/[{"path":"&"}]/' "$SANDBOX/pc-configs" ;;
esac
EOF
  run run_cleaner 63-pre-commit.sh
  [ "$status" -eq 0 ]
  refute grep -q 'pre-commit gc' "$CALL_LOG"
  [[ "$output" == *"/Volumes/scrubmac-test-absent-$$, which is not mounted"* ]] || false
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

@test "swiftpm: purges the global cache from a throwaway directory holding a placeholder manifest (SwiftPM < 6.3 needs one)" {
  # like SwiftPM 6.1/6.2: purge-cache needs a package root in the current
  # directory (or a parent) and writes .build there
  make_stub_script swift <<EOF
pwd >"$SANDBOX/swift-cwd"
if [ ! -f Package.swift ]; then
  echo "error: Could not find Package.swift in this directory or any of its parent directories." >&2
  exit 1
fi
cp Package.swift "$SANDBOX/swift-manifest"
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
  [ ! -e "$SANDBOX/workdir/Package.swift" ]
  [ ! -d "$(cat "$SANDBOX/swift-cwd")" ] # the scratch dir is removed again
  grep -qx '// swift-tools-version:5.3' "$SANDBOX/swift-manifest"
  grep -qx 'let package = Package(name: "scrubmac-purge-cache")' "$SANDBOX/swift-manifest"
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
# --cooldown, pnpm 12, a full Xcode, a logged-in gh with an extension, a
# pre-commit store with a recorded config), with something to act on (an
# outdated npm global, pnpm and bun globals, a uv receipt cutoff, a global
# Composer project, Bun's release feed) and node for the resolver.
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
  config) echo undefined ;;
  ls) cat "$SANDBOX/pnpm-ls.json" ;;
  outdated) exit 1 ;;
esac
exit 0
EOF
  bun_fixture
  export BUN_VER=1.3.13
  bun_dep ms '^2.1.1' 2.1.1
  bun_release 1.4.2 30
  mkdir -p "$HOME/.cache/pre-commit"
  : >"$HOME/.cache/pre-commit/db.db"
  make_stub sqlite3 0 "$SANDBOX/gone/.pre-commit-config.yaml"
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
^bun pm (cache|cache -g|ls -g)$
^uv (--version|cache dir --color never|tool list --outdated)$
^python3 -m pip cache dir$
^poetry config cache-dir$
^conda update -n base conda --dry-run$
^gh extension list$
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
^npm (outdated -g --json|ls -g --long --json|root -g|view .+|config get (min-release-age|before|userconfig|globalconfig) -g)$
^pnpm (--version|ls -g --depth=0 --json|outdated -g --format json|config get minimumReleaseAge|root -g|bin -g)$
^bun (--version|outdated -g)$
^curl -fsSL --max-time 30 -K - -H Accept: application/vnd\.github\.v3\+json https://api\.github\.com/repos/Jarred-Sumner/bun-releases-for-updater/releases/latest$
^uv tool (dir --color never|list --outdated --exclude-newer false --color never)$
^sqlite3 -init /dev/null -batch -list -noheader -readonly -cmd \.timeout 5000 
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
  grep -q '^curl ' "$CALL_LOG"           # Bun's release feed
  grep -q '^sqlite3 -init /dev/null ' "$CALL_LOG" # pre-commit's recorded configs
  grep -qx 'uv tool list --outdated --exclude-newer false --color never' "$CALL_LOG"
}
