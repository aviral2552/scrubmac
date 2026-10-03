#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# Commands beyond a plain run: list, enable/disable (and the state model and
# its ≤3.0 migration), config, status, last, --json, run logs and rotation,
# notifications, and the --scheduled guards.

load helpers/setup

setup() { setup_sandbox; }
teardown() { teardown_sandbox; }

CFGDIR() { printf '%s\n' "$XDG_CONFIG_HOME/scrubmac"; }

valid_json() {
  if [ -n "$REAL_PYTHON" ]; then
    "$REAL_PYTHON" -c 'import json, sys; json.load(sys.stdin)' <"$1"
  elif [ -n "$REAL_NODE" ]; then
    "$REAL_NODE" -e 'JSON.parse(require("fs").readFileSync(0, "utf8"))' <"$1"
  else
    skip "no JSON validator (python3 or node) available"
  fi
}

# ---------- list ----------

@test "list shows name, state, default, tool, source and summary" {
  make_cleaner 10-alpha.sh '# gate: sometool' '# summary: does alpha things' 'echo hi'
  make_cleaner 20-beta.sh '# default: off' 'echo hi'
  mkdir -p "$(CFGDIR)"
  echo alpha >"$(CFGDIR)/disabled"
  : >"$(CFGDIR)/enabled"
  run "$CMM" list
  [ "$status" -eq 0 ]
  [[ "$output" == *"alpha            disabled  on      -     builtin  does alpha things"* ]] || false
  [[ "$output" == *"beta             disabled  off     ?     builtin"* ]] || false
}

@test "list --names prints one name per line (for shell completion)" {
  make_cleaner 10-alpha.sh 'echo hi'
  make_cleaner 20-beta.sh 'echo hi'
  run "$CMM" list --names
  [ "$status" -eq 0 ]
  [ "$output" = $'alpha\nbeta' ]
}

# ---------- enable / disable & state ----------

@test "enable/disable record explicit choices; defaults apply otherwise" {
  make_cleaner 10-alpha.sh 'echo ALPHA'
  make_cleaner 60-docker.sh '# default: off' 'echo DOCKER'
  run "$CMM" disable alpha
  [ "$status" -eq 0 ]
  grep -Fxq alpha "$(CFGDIR)/disabled"
  run "$CMM" enable docker
  [ "$status" -eq 0 ]
  grep -Fxq docker "$(CFGDIR)/enabled"
  refute grep -Fxq docker "$(CFGDIR)/disabled"
  run "$CMM"
  [[ "$output" != *ALPHA* ]] && [[ "$output" == *DOCKER* ]] || false
  run "$CMM" disable docker
  grep -Fxq docker "$(CFGDIR)/disabled"
  refute grep -Fxq docker "$(CFGDIR)/enabled"
  run "$CMM" enable no-such-cleaner
  [ "$status" -eq 2 ]
  run "$CMM" enable
  [ "$status" -eq 2 ]
}

@test "enable takes several names and says when the tool is not installed" {
  make_cleaner 10-alpha.sh '# gate: definitely_missing_tool_xyz' 'echo hi'
  make_cleaner 20-beta.sh '# gate: sh' 'echo hi'
  run "$CMM" enable alpha beta
  [ "$status" -eq 0 ]
  [[ "$output" == *"enabled: alpha (its tool is not installed yet"* ]] || false
  [[ "$output" == *"enabled: beta"* ]] || false
}

@test "≤3.0 state migrates: earlier opt-ins and go stay enabled, exactly once" {
  make_cleaner 52-go.sh '# default: off' 'echo GO-RAN'
  make_cleaner 60-docker.sh '# default: off' 'echo DOCKER-RAN'
  make_cleaner 70-xcode.sh '# default: off' 'echo XCODE-RAN'
  mkdir -p "$(CFGDIR)"
  printf 'xcode\n' >"$(CFGDIR)/disabled" # 3.0 user who had opted into docker
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept your earlier choices enabled"* ]] || false
  [[ "$output" == *GO-RAN* ]] && [[ "$output" == *DOCKER-RAN* ]] && [[ "$output" != *XCODE-RAN* ]] || false
  [ "$(state_names "$(CFGDIR)/enabled")" = "docker go" ]
  head -n 1 "$(CFGDIR)/enabled" | grep -q '^# scrubmac:'
  run "$CMM"
  [[ "$output" != *"kept your earlier choices"* ]] || false
}

@test "a disabled file written by 3.1 (it has the header) is never migrated, even with the state dir gone" {
  make_cleaner 60-docker.sh '# default: off' 'echo DOCKER-RAN'
  make_cleaner 10-alpha.sh 'echo ALPHA'
  run "$CMM" disable alpha
  [ "$status" -eq 0 ]
  rm -f "$(CFGDIR)/enabled"
  rm -rf "$STATE_DIR" # e.g. a new Mac with dotfile-synced ~/.config
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" != *"kept your earlier choices"* ]] || false
  [[ "$output" != *DOCKER-RAN* ]] || false
}

@test "state files keep their header, your comments and one line per name" {
  make_cleaner 10-alpha.sh 'echo ALPHA'
  make_cleaner 20-beta.sh 'echo BETA'
  make_cleaner 60-docker.sh '# default: off' 'echo DOCKER'
  run "$CMM" list # 3.1 state from the start
  mkdir -p "$(CFGDIR)"
  printf '# my note\n  alpha  \nalpha\n' >"$(CFGDIR)/disabled"
  run "$CMM" disable beta
  [ "$status" -eq 0 ]
  head -n 1 "$(CFGDIR)/disabled" | grep -q '^# scrubmac:'
  grep -Fxq '# my note' "$(CFGDIR)/disabled"
  [ "$(state_names "$(CFGDIR)/disabled")" = "alpha beta" ]
  run "$CMM" enable alpha,beta alpha
  [ "$status" -eq 0 ]
  [ -z "$(state_names "$(CFGDIR)/disabled")" ]
  [ "$(state_names "$(CFGDIR)/enabled")" = "alpha beta" ]
}

@test "a hand-edited state line with spaces still counts" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  mkdir -p "$(CFGDIR)"
  printf '  alpha \t\n' >"$(CFGDIR)/disabled"
  : >"$(CFGDIR)/enabled"
  run "$CMM"
  [[ "$output" != *ALPHA-RAN* ]] || false
}

@test "an unreadable state file is never rewritten (its choices would be lost)" {
  make_cleaner 10-alpha.sh 'echo ALPHA'
  mkdir -p "$(CFGDIR)"
  printf 'alpha\n' >"$(CFGDIR)/disabled"
  chmod 000 "$(CFGDIR)/disabled"
  run "$CMM" enable alpha
  chmod 644 "$(CFGDIR)/disabled"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot read"* ]] || false
  grep -Fxq alpha "$(CFGDIR)/disabled"
}

@test "a fresh 3.1 install never mistakes a hand-made disabled file for ≤3.0 state" {
  make_cleaner 60-docker.sh '# default: off' 'echo DOCKER-RAN'
  make_cleaner 10-alpha.sh 'echo ALPHA'
  run "$CMM" list # first contact records the state version
  mkdir -p "$(CFGDIR)"
  printf 'alpha\n' >"$(CFGDIR)/disabled"
  run "$CMM"
  [[ "$output" != *DOCKER-RAN* ]] || false
  [ ! -s "$(CFGDIR)/enabled" ]
}

# ---------- config ----------

@test "config lists every setting with its value and source" {
  mkdir -p "$(CFGDIR)"
  printf 'COOLDOWN_DAYS=3\nMY_CUSTOM_KEY=hello\n' >"$(CFGDIR)/config"
  CMM_TIMEOUT=600 run "$CMM" config
  [ "$status" -eq 0 ]
  [[ "$output" == *"COOLDOWN_DAYS            3            config"* ]] || false
  [[ "$output" == *"TIMEOUT                  600          env"* ]] || false
  [[ "$output" == *"QUIET                    0            default"* ]] || false
  [[ "$output" == *"MY_CUSTOM_KEY            hello        custom"* ]] || false
}

@test "config set/get/unset round-trip, preserving comments and other lines" {
  mkdir -p "$(CFGDIR)"
  printf '# my notes\nQUIET=1\nCOOLDOWN_DAYS=3\n' >"$(CFGDIR)/config"
  run "$CMM" config set COOLDOWN_DAYS 14
  [ "$status" -eq 0 ]
  run "$CMM" config get COOLDOWN_DAYS
  [ "$output" = 14 ]
  grep -Fxq '# my notes' "$(CFGDIR)/config"
  grep -Fxq 'QUIET=1' "$(CFGDIR)/config"
  [ "$(grep -c '^COOLDOWN_DAYS=' "$(CFGDIR)/config")" -eq 1 ]
  run "$CMM" config unset COOLDOWN_DAYS
  run "$CMM" config get COOLDOWN_DAYS
  [ "$output" = 7 ] # back to the default
  run "$CMM" config path
  [ "$output" = "$(CFGDIR)/config" ]
}

@test "config set validates keys, values and types" {
  run "$CMM" config set COOLDOWN_DAYS lots
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected a whole number"* ]] || false
  run "$CMM" config set APP_UPDATES sometimes
  [ "$status" -eq 2 ]
  [[ "$output" == *"one of: interactive, always, never"* ]] || false
  run "$CMM" config set lower_case 1
  [ "$status" -eq 2 ]
  run "$CMM" config set QUIET '1;touch /tmp/x'
  [ "$status" -eq 2 ]
  run "$CMM" config set MY_KEY 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a built-in setting"* ]] || false
  run "$CMM" config frobnicate
  [ "$status" -eq 2 ]
}

@test "config: a near-miss of a built-in key is refused with a suggestion; get of an unknown key exits 1" {
  run "$CMM" config set COOLDOWN_DAY 3
  [ "$status" -eq 2 ]
  [[ "$output" == *"did you mean 'COOLDOWN_DAYS'?"* ]] || false
  refute grep -q COOLDOWN_DAY "$(CFGDIR)/config"
  run "$CMM" config get TIMEOTU
  [ "$status" -eq 1 ]
  [[ "$output" == *"did you mean 'TIMEOUT'?"* ]] || false
  run "$CMM" config set MY_KEY hello
  run "$CMM" config get MY_KEY
  [ "$status" -eq 0 ]
  [ "$output" = hello ]
}

@test "config: values pass through as given (a value may start with -), numbers are stored canonically" {
  run "$CMM" config set MY_FLAG -x
  [ "$status" -eq 0 ]
  grep -qx 'MY_FLAG=-x' "$(CFGDIR)/config"
  run "$CMM" config set TIMEOUT -1
  [ "$status" -eq 2 ]
  [[ "$output" == *"expected a whole number"* ]] || false
  run "$CMM" config set MIN_HOURS_BETWEEN_RUNS 08
  [ "$status" -eq 0 ]
  grep -qx 'MIN_HOURS_BETWEEN_RUNS=8' "$(CFGDIR)/config"
}

@test "settings: leading zeros never reach arithmetic as octal; list values must be exactly one word" {
  make_cleaner 10-alpha.sh 'echo "MIN=$CMM_MIN_HOURS_BETWEEN_RUNS TIMEOUT=$CMM_TIMEOUT"'
  CMM_MIN_HOURS_BETWEEN_RUNS=08 CMM_TIMEOUT=0090 run "$CMM" --scheduled
  [ "$status" -eq 0 ]
  [[ "$output" == *"MIN=8 TIMEOUT=90"* ]] || false
  CMM_NOTIFY=always,never run "$CMM"
  [[ "$output" == *"ignoring CMM_NOTIFY=always,never"* ]] || false
}

@test "config lint: malformed lines are reported (once), comments and blank lines are not" {
  make_cleaner 10-alpha.sh 'echo hi'
  mkdir -p "$(CFGDIR)"
  printf '# notes\n\n  # indented note\nQUIET = 1\nCOOLDOWN_DAYS=3 # three\nTIMEOUT=60\n' >"$(CFGDIR)/config"
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring line 4 of $(CFGDIR)/config: 'QUIET = 1'"* ]] || false
  [[ "$output" == *"ignoring line 5"* ]] || false
  [[ "$output" != *"ignoring line 1 "* ]] || false
  [[ "$output" != *"ignoring line 6"* ]] || false
  [ "$(printf '%s\n' "$output" | grep -c 'ignoring line 4')" -eq 1 ]
}

@test "an unreadable config is reported, and never rewritten" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  mkdir -p "$(CFGDIR)"
  printf 'QUIET=1\n' >"$(CFGDIR)/config"
  chmod 000 "$(CFGDIR)/config"
  run "$CMM"
  [[ "$output" == *"cannot read $(CFGDIR)/config"* ]] || false
  [[ "$output" == *ALPHA-RAN* ]] || false
  run "$CMM" config set COOLDOWN_DAYS 3
  chmod 644 "$(CFGDIR)/config"
  [ "$status" -eq 2 ]
  grep -qx 'QUIET=1' "$(CFGDIR)/config"
}

@test "config set writes through a dotfiles symlink, keeping the link" {
  mkdir -p "$SANDBOX/dotfiles" "$(CFGDIR)"
  printf 'QUIET=1\n' >"$SANDBOX/dotfiles/scrubmac.conf"
  ln -s "$SANDBOX/dotfiles/scrubmac.conf" "$(CFGDIR)/config"
  run "$CMM" config set COOLDOWN_DAYS 3
  [ "$status" -eq 0 ]
  [ -L "$(CFGDIR)/config" ]
  grep -qx 'COOLDOWN_DAYS=3' "$SANDBOX/dotfiles/scrubmac.conf"
  grep -qx 'QUIET=1' "$SANDBOX/dotfiles/scrubmac.conf"
}

@test "config set into an unwritable config dir is an error (exit 2), not a crash" {
  mkdir -p "$(CFGDIR)"
  chmod 500 "$(CFGDIR)"
  run "$CMM" config set COOLDOWN_DAYS 3
  chmod 700 "$(CFGDIR)"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot write"* ]] || false
}

@test "options that would be ignored are errors instead" {
  run "$(plain_copy)" -n update
  [ "$status" -eq 2 ]
  [[ "$output" == *"update --check"* ]] || false
  run "$CMM" --dry-run enable alpha
  [ "$status" -eq 2 ]
  run "$CMM" -n schedule weekly
  [ "$status" -eq 2 ]
  run "$CMM" -n config set QUIET 1
  [ "$status" -eq 2 ]
  run "$CMM" --json list
  [ "$status" -eq 2 ]
  [[ "$output" == *"--json does not apply to 'scrubmac list'"* ]] || false
  run "$CMM" --scheduled status
  [ "$status" -eq 2 ]
  run "$CMM" --measure doctor
  [ "$status" -eq 2 ]
  run "$CMM" --skip alpha list
  [ "$status" -eq 2 ]
  [ ! -f "$(CFGDIR)/config" ]
}

@test "--skip and enable take comma lists and never glob" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  make_cleaner 20-beta.sh 'echo BETA-RAN'
  make_cleaner 30-gamma.sh 'echo GAMMA-RAN'
  touch "$HOME/alpha" # a glob would expand '*' to files in the cwd
  run "$CMM" --skip 'alpha,beta'
  [ "$status" -eq 0 ]
  [[ "$output" != *ALPHA-RAN* ]] || false
  [[ "$output" != *BETA-RAN* ]] || false
  [[ "$output" == *GAMMA-RAN* ]] || false
  run bash -c 'cd "$HOME" && "$CMM" --skip "*"'
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown cleaner or command '*'"* ]] || false
  run "$CMM" disable 'alpha, beta' gamma alpha
  [ "$status" -eq 0 ]
  [ "$(state_names "$(CFGDIR)/disabled")" = "alpha beta gamma" ]
}

@test "did-you-mean prefers a command over an equally close cleaner" {
  make_cleaner 10-lisp.sh 'echo hi'
  run "$CMM" lis
  [ "$status" -eq 2 ]
  [[ "$output" == *"did you mean 'list'?"* ]] || false
}

@test "an unknown name that matches a non-executable file of yours says so" {
  local ud
  ud="$(CFGDIR)/cleaners.d"
  mkdir -p "$ud"
  printf '#!/usr/bin/env bash\necho mine\n' >"$ud/50-mine.sh" # not executable
  run "$CMM" mine
  [ "$status" -eq 2 ]
  [[ "$output" == *"is it executable? chmod +x"* ]] || false
}

@test "list --names has no side effects (no migration, no state written)" {
  mkdir -p "$XDG_CONFIG_HOME/cleanmymac"
  printf 'QUIET=1\n' >"$XDG_CONFIG_HOME/cleanmymac/config"
  make_cleaner 10-alpha.sh 'echo hi'
  run "$CMM" list --names
  [ "$status" -eq 0 ]
  [ "$output" = alpha ]
  [ -d "$XDG_CONFIG_HOME/cleanmymac" ]
  [ ! -L "$XDG_CONFIG_HOME/cleanmymac" ]
  [ ! -e "$XDG_CONFIG_HOME/scrubmac" ]
  [ ! -e "$STATE_DIR/state-v2" ]
}

@test "--json keeps stdout pure even when the config dir is migrated on this run" {
  mkdir -p "$XDG_CONFIG_HOME/cleanmymac"
  printf 'QUIET=0\n' >"$XDG_CONFIG_HOME/cleanmymac/config"
  make_cleaner 10-alpha.sh 'echo hi'
  "$CMM" --json >"$SANDBOX/out.json" 2>"$SANDBOX/err" 3>&-
  valid_json "$SANDBOX/out.json"
  grep -q 'migrated config' "$SANDBOX/err"
}

@test "Homebrew installed but missing from this run's PATH is called out" {
  mkdir -p "$SANDBOX/fakebrew/bin"
  printf '#!/bin/sh\nexit 0\n' >"$SANDBOX/fakebrew/bin/brew"
  chmod 755 "$SANDBOX/fakebrew/bin/brew"
  make_cleaner 10-alpha.sh 'echo hi'
  CMM_BREW_LOCATIONS="$SANDBOX/fakebrew/bin/brew" run "$CMM"
  [[ "$output" == *"Homebrew is installed ($SANDBOX/fakebrew/bin) but not on this run's PATH"* ]] || false
  make_stub brew
  CMM_BREW_LOCATIONS="$SANDBOX/fakebrew/bin/brew" run "$CMM"
  [[ "$output" != *"not on this run's PATH"* ]] || false
}

@test "the first-run question accepts any n… answer as no" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  CMM_WIZARD_ASSUME_TTY=1 run "$CMM" <<<'Nope'
  [ "$status" -eq 0 ]
  [ -f "$(CFGDIR)/config" ]
  [[ "$output" == *ALPHA-RAN* ]] || false
}

# ---------- status ----------

@test "status runs reports and cache sizes only — nothing mutates, no lock" {
  mkdir -p "$SANDBOX/cache"
  dd if=/dev/zero of="$SANDBOX/cache/blob" bs=1024 count=1024 2>/dev/null
  make_lib_cleaner 10-alpha.sh \
    "cache_dir '$SANDBOX/cache'" \
    "report echo REPORT-LINE" \
    "step touch '$HOME/pwned'" \
    "run touch '$HOME/pwned2'"
  start_holder scrubmac
  hold_lock "$HOLDER_PID" # a run in progress does not block status
  run "$CMM" status
  [ "$status" -eq 0 ]
  [[ "$output" == *REPORT-LINE* ]] || false
  [[ "$output" == *"Cache sizes"* ]] || false
  # the table row itself (not the line the cleaner prints for its cache dir)
  printf '%s\n' "$output" | sed -n '/^Cache sizes$/,$p' | grep -Eq '^  alpha +1\.0 MB$'
  printf '%s\n' "$output" | sed -n '/^Cache sizes$/,$p' | grep -Eq '^  total +1\.0 MB$'
  [ ! -e "$HOME/pwned" ]
  [ ! -e "$HOME/pwned2" ]
}

@test "status --json reports cache sizes per cleaner" {
  mkdir -p "$SANDBOX/cache"
  dd if=/dev/zero of="$SANDBOX/cache/blob" bs=1024 count=1024 2>/dev/null
  make_lib_cleaner 10-alpha.sh "cache_dir '$SANDBOX/cache'"
  "$CMM" status --json >"$SANDBOX/out.json" 2>/dev/null
  valid_json "$SANDBOX/out.json"
  grep -q '"mode": "status"' "$SANDBOX/out.json"
  grep -Eq '"name": "alpha".*"cache_kb": 10[0-9][0-9]' "$SANDBOX/out.json"
}

# ---------- --json and last-run records ----------

@test "--json: stdout is only the JSON document; human output goes to stderr" {
  make_lib_cleaner 10-alpha.sh 'echo ALPHA-OUT' 'summary_note "a \"quoted\" note \\ with backslash"'
  make_cleaner 20-beta.sh 'exit 1'
  make_cleaner 30-gamma.sh 'exit 75'
  local rc=0
  "$CMM" --json >"$SANDBOX/out.json" 2>"$SANDBOX/err" || rc=$?
  [ "$rc" -eq 1 ]
  valid_json "$SANDBOX/out.json"
  refute grep -q ALPHA-OUT "$SANDBOX/out.json"
  grep -q ALPHA-OUT "$SANDBOX/err"
  [ "$(json_get "$SANDBOX/out.json" exit_code)" = 1 ]
  grep -q '"totals": {"ok": 1, "skipped": 1, "failed": 1}' "$SANDBOX/out.json"
  grep -Fq '"notes": ["a \"quoted\" note \\ with backslash"]' "$SANDBOX/out.json"
  grep -q '"name": "beta", "status": "fail", "exit_code": 1' "$SANDBOX/out.json"
}

@test "every real run leaves last-run.json; dry runs do not" {
  make_cleaner 10-alpha.sh 'echo hi'
  run "$CMM" --dry-run
  [ ! -e "$STATE_DIR/last-run.json" ]
  run "$CMM"
  [ -f "$STATE_DIR/last-run.json" ]
  valid_json "$STATE_DIR/last-run.json"
  [ "$(json_get "$STATE_DIR/last-run.json" exit_code)" = 0 ]
  run "$CMM" last --json
  [ "$status" -eq 0 ]
  [[ "$output" == *'"version"'* ]] || false
}

# ---------- logs ----------

@test "an unattended run logs each cleaner's output; 'last' shows it" {
  make_cleaner 10-alpha.sh 'echo ALPHA-LOGGED'
  make_cleaner 20-beta.sh 'echo BETA-EVIDENCE' 'exit 4'
  run "$CMM" -q
  [ "$status" -eq 1 ]
  local log
  log="$(ls "$STATE_DIR"/logs/run-*.log)"
  grep -q '== alpha: ok' "$log"
  grep -q ALPHA-LOGGED "$log" # captured even though -q hid it on screen
  grep -q '== beta: FAIL' "$log"
  grep -q BETA-EVIDENCE "$log"
  grep -q '^exit 1$' "$log"
  run "$CMM" last
  [ "$status" -eq 0 ]
  [[ "$output" == *ALPHA-LOGGED* ]] || false
}

@test "logs rotate to LOG_KEEP" {
  make_cleaner 10-alpha.sh 'echo hi'
  local _
  for _ in 1 2 3 4; do
    CMM_LOG_KEEP=2 "$CMM" >/dev/null 2>&1
    sleep 1 # distinct timestamps
  done
  [ "$(find "$STATE_DIR/logs" -name 'run-*.log' | wc -l | tr -d ' ')" -eq 2 ]
}

@test "last with no runs says so" {
  run "$CMM" last
  [ "$status" -eq 0 ]
  [[ "$output" == *"no runs recorded yet"* ]] || false
  run "$CMM" last --json
  [ "$status" -eq 1 ]
}

# ---------- notifications ----------

notify_stub() {
  make_stub_script osascript <<EOF
cat >>"$SANDBOX/applescript" # the AppleScript source arrives on stdin
EOF
}

@test "an unattended run with a failure sends a notification (argv, never spliced into AppleScript)" {
  notify_stub
  make_cleaner 10-ok.sh 'echo hi'
  make_cleaner 30-broken.sh 'exit 1'
  CMM_NOTIFY=failures run "$CMM"
  [ "$status" -eq 1 ]
  grep -q "^osascript - scrubmac: 1 failed Failed: broken — run 'scrubmac last' for details$" "$CALL_LOG"
  # the script source is the fixed template: the text only ever travels in argv
  diff "$SANDBOX/applescript" - <<'EOF'
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
EOF
}

@test "cleaners whose names could smuggle markup or options are ignored" {
  make_cleaner '20-bad"name.sh' 'echo QUOTE-RAN'
  make_cleaner '30-bad name.sh' 'echo SPACE-RAN'
  make_cleaner 40-fine.sh 'echo FINE-RAN'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring cleaner with an unusable name"* ]] || false
  [[ "$output" != *QUOTE-RAN* ]] && [[ "$output" != *SPACE-RAN* ]] && [[ "$output" == *FINE-RAN* ]] || false
}

@test "no notification on success (NOTIFY=failures), when NOTIFY=never, or when interactive" {
  notify_stub
  make_cleaner 10-ok.sh 'echo hi'
  CMM_NOTIFY=failures run "$CMM"
  [ ! -s "$CALL_LOG" ]
  make_cleaner 20-bad.sh 'exit 1'
  CMM_NOTIFY=never run "$CMM"
  [ ! -s "$CALL_LOG" ]
  CMM_NOTIFY=failures CMM_ASSUME_INTERACTIVE=1 run "$CMM"
  [ ! -s "$CALL_LOG" ]
  CMM_NOTIFY=always run "$CMM"
  grep -q '^osascript - scrubmac ' "$CALL_LOG"
}

# ---------- --scheduled guards ----------

@test "--scheduled with ON_BATTERY=skip skips while on battery, runs on AC" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  make_stub_script pmset <<'EOF'
printf "Now drawing from 'Battery Power'\n -InternalBattery-0 (id=1)\t80%%; discharging\n"
EOF
  CMM_OS=Darwin CMM_ON_BATTERY=skip run "$CMM" --scheduled
  [ "$status" -eq 0 ]
  [[ "$output" == *"scheduled run skipped: on battery power"* ]] || false
  [[ "$output" != *ALPHA-RAN* ]] || false
  grep -q 'scheduled run skipped' "$STATE_DIR"/logs/run-*.log
  CMM_OS=Darwin run "$CMM" --scheduled # ON_BATTERY=run (default)
  [[ "$output" == *ALPHA-RAN* ]] || false
  make_stub_script pmset <<'EOF'
printf "Now drawing from 'AC Power'\n"
EOF
  CMM_OS=Darwin CMM_ON_BATTERY=skip run "$CMM" --scheduled
  [[ "$output" == *ALPHA-RAN* ]] || false
  CMM_OS=Darwin CMM_ON_BATTERY=skip run "$CMM" # not scheduled: no guard
  [[ "$output" == *ALPHA-RAN* ]] || false
}

@test "--scheduled honors MIN_HOURS_BETWEEN_RUNS after a successful full run" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  run "$CMM" # a successful full run records last-success
  [ -f "$STATE_DIR/last-success" ]
  CMM_MIN_HOURS_BETWEEN_RUNS=12 run "$CMM" --scheduled
  [ "$status" -eq 0 ]
  [[ "$output" == *"a full run succeeded 0h ago"* ]] || false
  [[ "$output" != *ALPHA-RAN* ]] || false
  echo $(($(date +%s) - 13 * 3600)) >"$STATE_DIR/last-success"
  CMM_MIN_HOURS_BETWEEN_RUNS=12 run "$CMM" --scheduled
  [[ "$output" == *ALPHA-RAN* ]] || false
}

@test "last-success only follows successful, full, real runs" {
  make_cleaner 10-alpha.sh 'echo hi'
  make_cleaner 20-beta.sh 'exit 1'
  run "$CMM"
  [ ! -e "$STATE_DIR/last-success" ] # a failure
  run "$CMM" alpha
  [ ! -e "$STATE_DIR/last-success" ] # not a full run
  run "$CMM" --skip beta
  [ ! -e "$STATE_DIR/last-success" ] # still not a full run
  run "$CMM" disable beta
  run "$CMM" --dry-run
  [ ! -e "$STATE_DIR/last-success" ] # dry run
  CMM_OFFLINE=1 run "$CMM"
  [ ! -e "$STATE_DIR/last-success" ] # offline: the updates did not happen
  local before
  before="$(date +%s)"
  run "$CMM"
  [ -f "$STATE_DIR/last-success" ]
  [ "$(cat "$STATE_DIR/last-success")" -ge "$before" ]
  [ "$(cat "$STATE_DIR/last-success")" -le "$(date +%s)" ] # the run's start, not its end
}

@test "XDG_STATE_HOME moves logs, last-run and the lock; CMM_STATE_DIR overrides it" {
  make_cleaner 10-peek.sh 'if readlink "$XDG_STATE_HOME/scrubmac/run.lock" >/dev/null; then echo LOCK-AT-XDG; fi'
  XDG_STATE_HOME="$SANDBOX/xdgstate" run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *LOCK-AT-XDG* ]] || false
  [ -f "$SANDBOX/xdgstate/scrubmac/last-run.json" ]
  ls "$SANDBOX/xdgstate/scrubmac/logs/"run-*.log >/dev/null
  [ ! -e "$STATE_DIR" ]
  CMM_STATE_DIR="$SANDBOX/custom" XDG_STATE_HOME="$SANDBOX/xdgstate2" run "$CMM"
  [ "$status" -eq 0 ]
  [ -f "$SANDBOX/custom/last-run.json" ]
  [ ! -e "$SANDBOX/xdgstate2/scrubmac" ]
}

@test "last-success is not written when every cleaner skipped (nothing was maintained)" {
  make_lib_cleaner 10-gone.sh 'skip "skipping: not installed"'
  run "$CMM"
  [ "$status" -eq 0 ]
  [ ! -e "$STATE_DIR/last-success" ]
}

@test "a last-success stamp from the future (clock change) never suppresses a run" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  mkdir -p "$STATE_DIR"
  echo $(($(date +%s) + 86400)) >"$STATE_DIR/last-success"
  CMM_MIN_HOURS_BETWEEN_RUNS=12 run "$CMM" --scheduled
  [ "$status" -eq 0 ]
  [[ "$output" == *ALPHA-RAN* ]] || false
}

@test "--scheduled is never interactive and still prompts nothing" {
  make_lib_cleaner 10-ctx.sh 'echo "INTERACTIVE=$CMM_INTERACTIVE SCHEDULED=$CMM_SCHEDULED"'
  CMM_ASSUME_INTERACTIVE=1 CMM_WIZARD_ASSUME_TTY=1 run "$CMM" --scheduled </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"INTERACTIVE=0 SCHEDULED=1"* ]] || false
  [[ "$output" != *"Run the setup wizard"* ]] || false
}
