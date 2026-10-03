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
  if command -v python3 >/dev/null 2>&1; then
    python3 -c 'import json, sys; json.load(sys.stdin)' <"$1"
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
  [[ "$output" == *"alpha            disabled  on      -     builtin  does alpha things"* ]]
  [[ "$output" == *"beta             disabled  off     ?     builtin"* ]]
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
  [[ "$output" != *ALPHA* ]] && [[ "$output" == *DOCKER* ]]
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
  [[ "$output" == *"enabled: alpha (its tool is not installed yet"* ]]
  [[ "$output" == *"enabled: beta"* ]]
}

@test "≤3.0 state migrates: earlier opt-ins and go stay enabled, exactly once" {
  make_cleaner 52-go.sh '# default: off' 'echo GO-RAN'
  make_cleaner 60-docker.sh '# default: off' 'echo DOCKER-RAN'
  make_cleaner 70-xcode.sh '# default: off' 'echo XCODE-RAN'
  mkdir -p "$(CFGDIR)"
  printf 'xcode\n' >"$(CFGDIR)/disabled" # 3.0 user who had opted into docker
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept your earlier choices enabled"* ]]
  [[ "$output" == *GO-RAN* ]] && [[ "$output" == *DOCKER-RAN* ]] && [[ "$output" != *XCODE-RAN* ]]
  diff <(sort "$(CFGDIR)/enabled") - <<'EOF'
docker
go
EOF
  run "$CMM"
  [[ "$output" != *"kept your earlier choices"* ]]
}

@test "a fresh 3.1 install never mistakes a hand-made disabled file for ≤3.0 state" {
  make_cleaner 60-docker.sh '# default: off' 'echo DOCKER-RAN'
  make_cleaner 10-alpha.sh 'echo ALPHA'
  run "$CMM" list # first contact records the state version
  mkdir -p "$(CFGDIR)"
  printf 'alpha\n' >"$(CFGDIR)/disabled"
  run "$CMM"
  [[ "$output" != *DOCKER-RAN* ]]
  [ ! -s "$(CFGDIR)/enabled" ]
}

# ---------- config ----------

@test "config lists every setting with its value and source" {
  mkdir -p "$(CFGDIR)"
  printf 'COOLDOWN_DAYS=3\nMY_CUSTOM_KEY=hello\n' >"$(CFGDIR)/config"
  CMM_TIMEOUT=600 run "$CMM" config
  [ "$status" -eq 0 ]
  [[ "$output" == *"COOLDOWN_DAYS            3            config"* ]]
  [[ "$output" == *"TIMEOUT                  600          env"* ]]
  [[ "$output" == *"QUIET                    0            default"* ]]
  [[ "$output" == *"MY_CUSTOM_KEY            hello        custom"* ]]
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
  [[ "$output" == *"expected a whole number"* ]]
  run "$CMM" config set APP_UPDATES sometimes
  [ "$status" -eq 2 ]
  [[ "$output" == *"one of: interactive, always, never"* ]]
  run "$CMM" config set lower_case 1
  [ "$status" -eq 2 ]
  run "$CMM" config set QUIET '1;touch /tmp/x'
  [ "$status" -eq 2 ]
  run "$CMM" config set MY_KEY 1
  [ "$status" -eq 0 ]
  [[ "$output" == *"not a built-in setting"* ]]
  run "$CMM" config frobnicate
  [ "$status" -eq 2 ]
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
  [[ "$output" == *REPORT-LINE* ]]
  [[ "$output" == *"Cache sizes"* ]]
  [[ "$output" == *"alpha"*"1.0 MB"* ]]
  [ ! -e "$HOME/pwned" ] && [ ! -e "$HOME/pwned2" ]
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
  [[ "$output" == *'"version"'* ]]
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
  [[ "$output" == *ALPHA-LOGGED* ]]
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
  [[ "$output" == *"no runs recorded yet"* ]]
  run "$CMM" last --json
  [ "$status" -eq 1 ]
}

# ---------- notifications ----------

notify_stub() {
  make_stub_script osascript <<'EOF'
cat >/dev/null # the AppleScript source arrives on stdin
EOF
}

@test "an unattended run with a failure sends a notification (argv, never spliced into AppleScript)" {
  notify_stub
  make_cleaner 10-ok.sh 'echo hi'
  make_cleaner 30-broken.sh 'exit 1'
  CMM_NOTIFY=failures run "$CMM"
  [ "$status" -eq 1 ]
  grep -q "^osascript - scrubmac: 1 failed Failed: broken — run 'scrubmac last' for details$" "$CALL_LOG"
}

@test "cleaners whose names could smuggle markup or options are ignored" {
  make_cleaner '20-bad"name.sh' 'echo QUOTE-RAN'
  make_cleaner '30-bad name.sh' 'echo SPACE-RAN'
  make_cleaner 40-fine.sh 'echo FINE-RAN'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring cleaner with an unusable name"* ]]
  [[ "$output" != *QUOTE-RAN* ]] && [[ "$output" != *SPACE-RAN* ]] && [[ "$output" == *FINE-RAN* ]]
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
  [[ "$output" == *"scheduled run skipped: on battery power"* ]]
  [[ "$output" != *ALPHA-RAN* ]]
  grep -q 'scheduled run skipped' "$STATE_DIR"/logs/run-*.log
  CMM_OS=Darwin run "$CMM" --scheduled # ON_BATTERY=run (default)
  [[ "$output" == *ALPHA-RAN* ]]
  make_stub_script pmset <<'EOF'
printf "Now drawing from 'AC Power'\n"
EOF
  CMM_OS=Darwin CMM_ON_BATTERY=skip run "$CMM" --scheduled
  [[ "$output" == *ALPHA-RAN* ]]
  CMM_OS=Darwin CMM_ON_BATTERY=skip run "$CMM" # not scheduled: no guard
  [[ "$output" == *ALPHA-RAN* ]]
}

@test "--scheduled honors MIN_HOURS_BETWEEN_RUNS after a successful full run" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  run "$CMM" # a successful full run records last-success
  [ -f "$STATE_DIR/last-success" ]
  CMM_MIN_HOURS_BETWEEN_RUNS=12 run "$CMM" --scheduled
  [ "$status" -eq 0 ]
  [[ "$output" == *"a full run succeeded 0h ago"* ]]
  [[ "$output" != *ALPHA-RAN* ]]
  echo $(($(date +%s) - 13 * 3600)) >"$STATE_DIR/last-success"
  CMM_MIN_HOURS_BETWEEN_RUNS=12 run "$CMM" --scheduled
  [[ "$output" == *ALPHA-RAN* ]]
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
  run "$CMM"
  [ -f "$STATE_DIR/last-success" ]
}

@test "--scheduled is never interactive and still prompts nothing" {
  make_lib_cleaner 10-ctx.sh 'echo "INTERACTIVE=$CMM_INTERACTIVE SCHEDULED=$CMM_SCHEDULED"'
  CMM_ASSUME_INTERACTIVE=1 CMM_WIZARD_ASSUME_TTY=1 run "$CMM" --scheduled </dev/null
  [ "$status" -eq 0 ]
  [[ "$output" == *"INTERACTIVE=0 SCHEDULED=1"* ]]
  [[ "$output" != *"Run the setup wizard"* ]]
}
