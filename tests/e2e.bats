#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# End-to-end journeys through the real entry points (install.sh, the
# installed launcher, the launchd agent's command line, uninstall.sh) with
# the real cleaners against a fake toolchain that behaves like the real
# tools (prints, exit codes, slowness). Hermetic: nothing outside the
# sandbox is touched. The live counterpart is .github/workflows/e2e-live.yml.

load helpers/setup

setup() {
  setup_sandbox
  export CMM_PREFIX="$SANDBOX/app"
  export CMM_BIN_DIR="$SANDBOX/bindir"
  unset CMM_CLEANERS_DIR # the installed copy's real cleaners
  export CMM_COOLDOWN_DAYS=0
  SM="$CMM_BIN_DIR/scrubmac"
  fake_toolchain
}
teardown() { teardown_sandbox; }

# fake_toolchain — stubs that act like brew, npm, uv, pipx, gh, claude,
# docker, mise and rustup: they log argv, print plausible output, and exit
# like the real tools (npm outdated exits 1 when something is outdated).
fake_toolchain() {
  make_stub_script brew <<'EOF'
case "$1" in
  --prefix) echo /nonexistent/brewpfx ;;
  --cache) echo "$HOME/Library/Caches/Homebrew" ;;
  update) echo "Updated 2 taps." ;;
  upgrade) [ "${BREW_UPGRADE_FAILS:-0}" = 1 ] && { echo "Error: git: failed to build" >&2; exit 1; }; echo "==> Upgrading 1 outdated package" ;;
  outdated) echo "git (2.55.0) < 2.56.0" ;;
esac
exit 0
EOF
  make_stub_script npm <<'EOF'
case "$1" in
  outdated) echo "Package  Current  Wanted  Latest"; exit 1 ;;
  config) echo "$HOME/.npm" ;;
esac
exit 0
EOF
  make_stub_script uv <<'EOF'
case "$1 $2" in
  "--version "*) echo "uv 0.12.22" ;;
  "cache dir") echo "$HOME/.cache/uv" ;;
  "tool dir") echo "$HOME/.local/share/uv/tools" ;;
esac
exit 0
EOF
  make_stub_script pipx <<'EOF'
[ "$2" = --help ] && echo "usage: pipx upgrade-all [--cooldown DAYS]"
exit 0
EOF
  make_stub_script gh <<'EOF'
case "$1 ${2:-}" in
  "auth status") echo "github.com: Logged in to github.com account tester" ;;
  "extension list") printf 'gh dash\tdlvhdr/gh-dash\tv4.12.0\n' ;;
esac
exit 0
EOF
  make_stub claude 0 "Claude Code is up to date"
  make_stub mise
  make_stub rustup
  make_stub docker
}

install_scrubmac() {
  run "$REPO_ROOT/install.sh"
  [ "$status" -eq 0 ]
  [ -x "$SM" ]
}

@test "journey: install → first run → enable → dry-run → status → last → schedule → doctor → uninstall" {
  install_scrubmac

  # first contact: list shows defaults, opt-in cleaners off
  run "$SM" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"homebrew         enabled   on      yes"* ]] || false
  [[ "$output" == *"docker           disabled  off     yes"* ]] || false

  # a first, non-interactive run uses the defaults and records everything
  run "$SM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"using defaults"* ]] || false
  [[ "$output" == *"ok      homebrew"* ]] || false
  [[ "$output" == *"casks not upgraded (unattended run"* ]] || false
  [[ "$output" == *"skip    mas"* ]] || false
  grep -qx 'brew upgrade --formula' "$CALL_LOG"
  refute grep -q 'brew upgrade --cask' "$CALL_LOG"
  refute grep -q '^docker ' "$CALL_LOG" # opt-in: not run
  [ -f "$STATE_DIR/last-run.json" ]

  # opt in to docker; preview it
  run "$SM" enable docker
  [ "$status" -eq 0 ]
  : >"$CALL_LOG"
  run "$SM" docker --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"+ docker builder prune -f --filter until=168h"* ]] || false
  refute grep -q 'prune' "$CALL_LOG"

  # status changes nothing: every tool call it makes is a read-only query
  : >"$CALL_LOG"
  run "$SM" status
  [ "$status" -eq 0 ]
  [[ "$output" == *"Cache sizes"* ]] || false
  [ -s "$CALL_LOG" ]
  refute grep -Evx '(brew (--prefix|--cache|outdated( .*)?|config)|npm (outdated -g( .*)?|config get cache|ls -g.*|root -g|view .*)|uv (--version|cache dir.*|tool dir|tool list.*|python dir)|pipx (--version|list.*|.* --help|--help)|gh (auth status|extension list|--version)|mise (outdated.*|--version|cache dir)|rustup (check|--version)|claude (--version)?|docker (info|system df|--version)) ?' "$CALL_LOG"

  # the newest log is readable
  run "$SM" last
  [ "$status" -eq 0 ]
  [[ "$output" == *"== homebrew: ok"* ]] || false

  # schedule it, then run exactly what launchd would run, in a launchd-like env
  make_stub launchctl
  run "$SM" schedule weekly
  [ "$status" -eq 0 ]
  local plist="$HOME/Library/LaunchAgents/com.github.aviral2552.scrubmac.plist" agent_path program
  agent_path="$(awk '/<key>PATH<\/key>/ { f = 1; next } f { gsub(/^[ \t]*<string>|<\/string>[ \t]*$/, ""); print; exit }' "$plist")"
  program="$(awk '/<key>ProgramArguments<\/key>/ { f = 1; next } f && /<string>/ { gsub(/^[ \t]*<string>|<\/string>[ \t]*$/, ""); print; exit }' "$plist")"
  [ "$program" = "$CMM_PREFIX/bin/scrubmac" ]
  run env -i HOME="$HOME" TMPDIR="$TMPDIR" PATH="$agent_path" CMM_OFFLINE=0 "$program" --scheduled --quiet
  [ "$status" -eq 0 ]
  [ "$(json_get "$STATE_DIR/last-run.json" scheduled)" = true ]

  # doctor sees the schedule and the last run
  run "$SM" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"launchd agent:  weekly on Monday at 09:00"* ]] || false
  [[ "$output" == *"last run:       $(json_get "$STATE_DIR/last-run.json" finished_at), exit 0"* ]] || false

  # uninstall --purge removes the install, the link, the schedule, config and state
  export PATH="$CMM_BIN_DIR:$PATH"
  run "$CMM_PREFIX/uninstall.sh" --purge
  [ "$status" -eq 0 ]
  [ ! -e "$CMM_PREFIX" ] && [ ! -e "$SM" ] && [ ! -e "$plist" ] || false
  [ ! -d "$XDG_CONFIG_HOME/scrubmac" ] && [ ! -d "$STATE_DIR" ] || false
  grep -q "^launchctl bootout gui/$(id -u)/com.github.aviral2552.scrubmac$" "$CALL_LOG"
}

@test "journey: an unattended failure is logged, summarized, notified — and the rest still runs" {
  install_scrubmac
  make_stub_script osascript <<'EOF'
cat >/dev/null
EOF
  export BREW_UPGRADE_FAILS=1
  run env -i HOME="$HOME" TMPDIR="$TMPDIR" PATH="$PATH" BREW_UPGRADE_FAILS=1 CMM_OFFLINE=0 CALL_LOG="$CALL_LOG" "$SM" --scheduled --quiet
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL    homebrew"* ]] || false
  [[ "$output" == *"failed to build"* ]] || false             # quiet mode still dumps a failure
  grep -qx 'brew cleanup -s --prune=all' "$CALL_LOG" # cleanup ran despite the failed upgrade
  grep -qx 'gh extension upgrade --all' "$CALL_LOG"  # later cleaners ran
  grep -q '^osascript - scrubmac: 1 failed Failed: homebrew' "$CALL_LOG"
  grep -q '== homebrew: FAIL' "$STATE_DIR"/logs/run-*.log
}

@test "journey: a hung tool is stopped by TIMEOUT and the run moves on" {
  install_scrubmac
  hang_child
  make_stub_script brew <<EOF
[ "\$1" = update ] && exec "$SANDBOX/hangchild"
exit 0
EOF
  local start=$SECONDS
  CMM_TIMEOUT=2 run "$SM" homebrew gh
  [ "$status" -eq 1 ]
  [ $((SECONDS - start)) -lt 30 ]
  [[ "$output" == *"TIMEOUT homebrew"* ]] || false
  [[ "$output" == *"ok      gh"* ]] || false
  no_hang_child
}

@test "journey: offline — updates are skipped, caches still cleaned" {
  install_scrubmac
  unset CMM_OFFLINE
  make_stub_script route <<'EOF'
echo "route: writing to routing socket: not in table" >&2
EOF
  CMM_OS=Darwin run "$SM" homebrew npm claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"offline: no default network route"* ]] || false
  refute grep -Eq '^brew (update|upgrade)' "$CALL_LOG"
  grep -qx 'brew cleanup -s --prune=all' "$CALL_LOG"
  grep -qx 'npm cache verify' "$CALL_LOG"
  refute grep -q '^claude' "$CALL_LOG"
  [[ "$output" == *"skip    claude"* ]] || false
}

@test "journey: upgrading a 3.0 setup keeps its choices (go stays on, opt-ins stay off)" {
  install_scrubmac
  make_stub go
  mkdir -p "$XDG_CONFIG_HOME/scrubmac"
  printf 'COOLDOWN_DAYS=0\nQUIET=1\nCOLOR=auto\nDERIVEDDATA_AGE_DAYS=30\n' >"$XDG_CONFIG_HOME/scrubmac/config"
  printf 'docker\nxcode\n' >"$XDG_CONFIG_HOME/scrubmac/disabled" # what 3.0's installer seeded
  run "$SM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept your earlier choices enabled: go"* ]] || false
  grep -qx 'go clean -cache' "$CALL_LOG"
  refute grep -q '^docker ' "$CALL_LOG"
}

@test "journey: a 2.x git install migrates on install.sh, and the old name still works (with a nag)" {
  export CMM_OLD_PREFIX="$SANDBOX/oldapp"
  mkdir -p "$CMM_OLD_PREFIX" "$XDG_CONFIG_HOME/cleanmymac"
  rsync -a --exclude=.git "$REPO_ROOT/" "$CMM_OLD_PREFIX/"
  printf 'COOLDOWN_DAYS=0\n' >"$XDG_CONFIG_HOME/cleanmymac/config"
  printf 'docker\nxcode\nnpm\n' >"$XDG_CONFIG_HOME/cleanmymac/disabled"
  run "$CMM_OLD_PREFIX/install.sh" # what the shim tells 2.x users to do
  [ "$status" -eq 0 ]
  [ -L "$CMM_OLD_PREFIX" ] && [ -x "$SM" ] || false
  run "$SM" list
  [[ "$output" == *"npm              disabled"* ]] || false
  run bash -c "\"$CMM_OLD_PREFIX/bin/cleanmymac\" version 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"cleanmymac is now scrubmac"* ]] || false
  [[ "$output" == *"scrubmac $(cat "$REPO_ROOT/VERSION")"* ]] || false
}

@test "journey: --json for monitoring, --update-only, --clean-only, --skip" {
  install_scrubmac
  "$SM" --json --skip claude >"$SANDBOX/run.json" 2>/dev/null
  [ "$(json_get "$SANDBOX/run.json" exit_code)" = 0 ]
  refute grep -q '"name": "claude"' "$SANDBOX/run.json"
  : >"$CALL_LOG"
  run "$SM" --update-only homebrew
  grep -qx 'brew upgrade --formula' "$CALL_LOG"
  refute grep -q 'cleanup' "$CALL_LOG"
  : >"$CALL_LOG"
  run "$SM" --clean-only homebrew
  grep -qx 'brew cleanup -s --prune=all' "$CALL_LOG"
  refute grep -q 'upgrade' "$CALL_LOG"
}
