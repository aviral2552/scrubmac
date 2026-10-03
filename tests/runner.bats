#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# Dispatcher run semantics: continue-on-failure, exit codes, selection and
# --skip, modes, stdin isolation, settings precedence, timeouts, refusals,
# locking, quiet buffering, interrupts, and the summary.

load helpers/setup

setup() { setup_sandbox; }
teardown() { teardown_sandbox; }

@test "runs every cleaner and continues past a failure (F1)" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  make_cleaner 20-beta.sh 'echo BETA-RAN' 'exit 1'
  make_cleaner 30-gamma.sh 'echo GAMMA-RAN'
  run "$CMM"
  [ "$status" -eq 1 ]
  [[ "$output" == *ALPHA-RAN* ]] || false
  [[ "$output" == *BETA-RAN* ]] || false
  [[ "$output" == *GAMMA-RAN* ]] || false
  [[ "$output" == *"1 failed"* ]] || false
}

@test "exits 0 when everything succeeds or skips" {
  make_cleaner 10-alpha.sh 'echo ok'
  make_cleaner 20-beta.sh 'echo skipping' 'exit 75'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 ok, 1 skipped, 0 failed"* ]] || false
}

@test "exit code 75 is reported as skip in the summary" {
  make_lib_cleaner 10-ghost.sh 'skip_unless definitely_not_a_real_tool_xyz'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]] || false
  [[ "$output" == *"0 ok, 1 skipped, 0 failed"* ]] || false
}

@test "dry-run executes nothing (canary survives)" {
  make_lib_cleaner 10-canary.sh 'run touch "$HOME/pwned"' 'step touch "$HOME/pwned2"'
  run "$CMM" --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/pwned" ]
  [ ! -e "$HOME/pwned2" ]
  [[ "$output" == *"+ touch"* ]] || false
  run "$CMM"
  [ -e "$HOME/pwned" ]
  [ -e "$HOME/pwned2" ]
}

@test "naming cleaners runs exactly those, even when disabled" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  make_cleaner 20-beta.sh 'echo BETA-RAN'
  mkdir -p "$XDG_CONFIG_HOME/scrubmac"
  echo beta >"$XDG_CONFIG_HOME/scrubmac/disabled"
  run "$CMM" beta
  [ "$status" -eq 0 ]
  [[ "$output" != *ALPHA-RAN* ]] || false
  [[ "$output" == *BETA-RAN* ]] || false
}

@test "unknown cleaner name exits 2 with a did-you-mean hint" {
  make_cleaner 10-homebrew.sh 'echo hi'
  run "$CMM" hombrew
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown cleaner"* ]] || false
  [[ "$output" == *"did you mean 'homebrew'"* ]] || false
  run "$CMM" lsit
  [ "$status" -eq 2 ]
  [[ "$output" == *"did you mean 'list'"* ]] || false
  run "$CMM" zzzzzzzz
  [ "$status" -eq 2 ]
  [[ "$output" != *"did you mean"* ]] || false
}

@test "disabled file is respected on full runs" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  make_cleaner 20-beta.sh 'echo BETA-RAN'
  mkdir -p "$XDG_CONFIG_HOME/scrubmac"
  echo alpha >"$XDG_CONFIG_HOME/scrubmac/disabled"
  : >"$XDG_CONFIG_HOME/scrubmac/enabled"
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" != *ALPHA-RAN* ]] || false
  [[ "$output" == *BETA-RAN* ]] || false
}

@test "'# default: off' cleaners stay off until enabled (D3)" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  make_cleaner 60-docker.sh '# default: off' 'echo DOCKER-RAN'
  make_cleaner 70-xcode.sh '# default: off' 'echo XCODE-RAN'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *ALPHA-RAN* ]] || false
  [[ "$output" != *DOCKER-RAN* ]] || false
  [[ "$output" != *XCODE-RAN* ]] || false
  run "$CMM" enable docker
  [ "$status" -eq 0 ]
  run "$CMM"
  [[ "$output" == *DOCKER-RAN* ]] || false
  [[ "$output" != *XCODE-RAN* ]] || false
}

@test "user cleaners.d is merged and shadows a same-named builtin" {
  make_cleaner 10-alpha.sh 'echo BUILTIN-ALPHA'
  local userdir="$XDG_CONFIG_HOME/scrubmac/cleaners.d"
  mkdir -p "$userdir"
  printf '#!/usr/bin/env bash\necho USER-ALPHA\n' >"$userdir/10-alpha.sh"
  printf '#!/usr/bin/env bash\necho USER-EXTRA\n' >"$userdir/50-extra.sh"
  chmod 755 "$userdir/10-alpha.sh" "$userdir/50-extra.sh"
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *USER-ALPHA* ]] || false
  [[ "$output" != *BUILTIN-ALPHA* ]] || false
  [[ "$output" == *USER-EXTRA* ]] || false
}

@test "empty cleaners dir is handled gracefully (F9)" {
  run "$CMM"
  [ "$status" -eq 0 ]
}

@test "non-executable and non-.sh files are ignored (F9)" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  printf 'junk\n' >"$FIXTURES/README.md"
  printf '#!/usr/bin/env bash\necho NOEXEC\n' >"$FIXTURES/20-noexec.sh"
  chmod 644 "$FIXTURES/20-noexec.sh"
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *ALPHA-RAN* ]] || false
  [[ "$output" != *NOEXEC* ]] || false
}

@test "quiet mode hides success output but dumps output of a failing cleaner" {
  make_cleaner 10-chatty.sh 'echo CHATTY-NOISE'
  make_cleaner 20-broken.sh 'echo BROKEN-EVIDENCE' 'exit 3'
  run "$CMM" --quiet
  [ "$status" -eq 1 ]
  [[ "$output" != *CHATTY-NOISE* ]] || false
  [[ "$output" == *BROKEN-EVIDENCE* ]] || false
}

@test "quiet mode surfaces the skip reason" {
  make_lib_cleaner 10-ghost.sh 'skip "skipping: ghost tool absent"'
  run "$CMM" -q
  [ "$status" -eq 0 ]
  [[ "$output" == *"ghost tool absent"* ]] || false
}

# ---------- stdin isolation (regression: a reader swallowed the next cleaner) ----------

@test "a cleaner that reads stdin cannot swallow the rest of the run" {
  make_cleaner 10-reader.sh 'read -r line || line="<eof>"' 'echo "READER GOT [$line]"'
  make_cleaner 20-second.sh 'echo SECOND-RAN'
  make_cleaner 30-third.sh 'echo THIRD-RAN'
  run "$CMM" <<<$'typed-input\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"READER GOT [<eof>]"* ]] || false
  [[ "$output" == *SECOND-RAN* ]] || false
  [[ "$output" == *THIRD-RAN* ]] || false
  [[ "$output" == *"3 ok, 0 skipped, 0 failed"* ]] || false
}

# ---------- settings precedence (regression: env was overwritten by config) ----------

@test "environment beats the config file (CMM_<KEY>)" {
  make_cleaner 10-env.sh 'echo "COOL=${CMM_COOLDOWN_DAYS} AGE=${CMM_DERIVEDDATA_AGE_DAYS}"'
  mkdir -p "$XDG_CONFIG_HOME/scrubmac"
  printf 'COOLDOWN_DAYS=0\nDERIVEDDATA_AGE_DAYS=45\n' >"$XDG_CONFIG_HOME/scrubmac/config"
  CMM_COOLDOWN_DAYS=7 run "$CMM"
  [[ "$output" == *"COOL=7 AGE=45"* ]] || false
  run "$CMM"
  [[ "$output" == *"COOL=0 AGE=45"* ]] || false
}

@test "a flag beats the environment (-q over CMM_QUIET=0)" {
  make_cleaner 10-chatty.sh 'echo CHATTY-NOISE'
  CMM_QUIET=0 run "$CMM" -q
  [[ "$output" != *CHATTY-NOISE* ]] || false
  CMM_QUIET=1 run "$CMM"
  [[ "$output" != *CHATTY-NOISE* ]] || false
}

@test "invalid environment and config values warn and fall back" {
  make_cleaner 10-env.sh 'echo "COOL=${CMM_COOLDOWN_DAYS} TO=${CMM_TIMEOUT}"'
  mkdir -p "$XDG_CONFIG_HOME/scrubmac"
  printf 'TIMEOUT=abc\n' >"$XDG_CONFIG_HOME/scrubmac/config"
  CMM_COOLDOWN_DAYS=lots run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring CMM_COOLDOWN_DAYS=lots"* ]] || false
  [[ "$output" == *"COOL=7 TO=3600"* ]] || false
}

@test "the cooldown defaults to 7 days when nothing sets it" {
  make_cleaner 10-env.sh 'echo "COOL=${CMM_COOLDOWN_DAYS}"'
  run "$CMM"
  [[ "$output" == *"COOL=7"* ]] || false
}

@test "cleaner environment receives CMM_DRY_RUN, CMM_MODE and CMM_COOLDOWN_DAYS" {
  make_cleaner 10-env.sh 'echo "DRY=${CMM_DRY_RUN:-unset} MODE=${CMM_MODE} COOL=${CMM_COOLDOWN_DAYS:-unset}"'
  mkdir -p "$XDG_CONFIG_HOME/scrubmac"
  printf 'COOLDOWN_DAYS=3\n' >"$XDG_CONFIG_HOME/scrubmac/config"
  run "$CMM" -n
  [[ "$output" == *"DRY=1 MODE=run COOL=3"* ]] || false
}

# ---------- execution-safety refusals are failures (regression: exit 0) ----------

@test "a refused cleaner is reported as REFUSED and fails the run" {
  make_cleaner 10-good.sh 'echo GOOD-RAN'
  make_cleaner 20-evil.sh 'echo EVIL-RAN'
  chmod 775 "$FIXTURES/20-evil.sh"
  run "$CMM"
  [ "$status" -eq 1 ]
  [[ "$output" == *GOOD-RAN* ]] || false
  [[ "$output" != *EVIL-RAN* ]] || false
  [[ "$output" == *REFUSED* ]] || false
  [[ "$output" == *"1 ok, 0 skipped, 1 failed"* ]] || false
}

@test "naming a refused cleaner explicitly also exits 1" {
  make_cleaner 20-evil.sh 'echo EVIL-RAN'
  chmod 775 "$FIXTURES/20-evil.sh"
  run "$CMM" evil
  [ "$status" -eq 1 ]
  [[ "$output" == *REFUSED* ]] || false
  [[ "$output" != *EVIL-RAN* ]] || false
}

# ---------- timeouts ----------

@test "TIMEOUT stops a hung cleaner and its child processes; the run continues" {
  hang_child
  make_cleaner 10-hang.sh 'echo HANG-START' "\"$SANDBOX/hangchild\" &" 'wait' 'echo NEVER'
  make_cleaner 20-next.sh 'echo NEXT-RAN'
  local group start
  for group in 0 1; do
    start=$SECONDS
    CMM__PGRP=$group CMM_TIMEOUT=1 run "$CMM"
    [ "$status" -eq 1 ]
    [ $((SECONDS - start)) -lt 20 ]
    [[ "$output" == *HANG-START* ]] || false
    [[ "$output" != *NEVER* ]] || false
    [[ "$output" == *NEXT-RAN* ]] || false
    [[ "$output" == *"TIMEOUT 10-hang"* || "$output" == *"TIMEOUT hang"* ]] || false
    [[ "$output" == *"stopped after 1s"* ]] || false
    [[ "$output" != *"Terminated"* ]] || false # no job-control noise
    no_hang_child
  done
}

@test "TIMEOUT: a process that ignores TERM is KILLed after the grace period" {
  hang_child "trap '' TERM"
  make_cleaner 10-hang.sh "trap '' TERM" "\"$SANDBOX/hangchild\" &" 'wait'
  local group start
  for group in 0 1; do
    start=$SECONDS
    CMM__PGRP=$group CMM__KILL_GRACE=1 CMM_TIMEOUT=1 run "$CMM"
    [ "$status" -eq 1 ]
    [ $((SECONDS - start)) -lt 15 ]
    [[ "$output" == *"stopped after 1s"* ]] || false
    no_hang_child
  done
}

@test "TIMEOUT in an unattended run also stops an orphaned grandchild (its process group)" {
  hang_child
  # the middle shell exits at once: the hang child is orphaned (re-parented),
  # out of reach of a process-tree walk — but still in the cleaner's group
  make_cleaner 10-hang.sh "sh -c '\"$SANDBOX/hangchild\" & exit 0'" 'sleep 60'
  CMM__PGRP=1 CMM_TIMEOUT=1 run "$CMM"
  [ "$status" -eq 1 ]
  no_hang_child
}

@test "unattended runs start each cleaner in its own process group; interactive runs share the terminal's" {
  make_cleaner 10-pg.sh 'echo "PGID=$(ps -o pgid= -p $$ | tr -d " ") PID=$$"'
  CMM__PGRP=1 run "$CMM"
  [[ "$output" =~ PGID=([0-9]+)\ PID=([0-9]+) ]] || false
  [ "${BASH_REMATCH[1]}" = "${BASH_REMATCH[2]}" ]
  CMM_ASSUME_INTERACTIVE=1 run "$CMM" pg
  [[ "$output" =~ PGID=([0-9]+)\ PID=([0-9]+) ]] || false
  [ "${BASH_REMATCH[1]}" != "${BASH_REMATCH[2]}" ]
}

@test "cleaners run from a private snapshot: deleting scrubmac's files mid-run (a brew self-upgrade) breaks nothing" {
  make_lib_cleaner 10-upgrader.sh "rm -f '$FIXTURES/20-later.sh'" 'echo "LIB=$CMM_LIB"'
  make_lib_cleaner 20-later.sh 'echo LATER-RAN'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *LATER-RAN* ]] || false
  [[ "$output" == *"LIB="*"/snapshot/lib/common.sh"* ]] || false
  [ ! -e "$FIXTURES/20-later.sh" ]
}

@test "a cleaner's scratch dir is removed after the run, even when the cleaner timed out" {
  make_lib_cleaner 10-scratch.sh 'd="$(cmm_scratch_dir)"' 'echo "SCRATCH=$d"' 'touch "$d/junk"' 'sleep 60'
  CMM_TIMEOUT=1 CMM__KILL_GRACE=1 run "$CMM"
  [ "$status" -eq 1 ]
  [[ "$output" =~ SCRATCH=([^[:space:]]+) ]] || false
  local d="${BASH_REMATCH[1]}"
  [[ "$d" == "$TMPDIR"/scrubmac.run.*/scratch-scratch ]] || false
  [ ! -e "$d" ]
}

@test "your own cleaner that disappears mid-run is a failure, not a refusal" {
  local ud="$XDG_CONFIG_HOME/scrubmac/cleaners.d"
  mkdir -p "$ud"
  printf '#!/usr/bin/env bash\necho MINE\n' >"$ud/20-mine.sh"
  chmod 755 "$ud/20-mine.sh"
  make_cleaner 10-remover.sh "rm -f '$ud/20-mine.sh'"
  run "$CMM"
  [ "$status" -eq 1 ]
  [[ "$output" == *"disappeared during the run"* ]] || false
  [[ "$output" == *"FAIL    mine"* ]] || false
  [[ "$output" != *REFUSED* ]] || false
}

@test "cleaners start in \$HOME, wherever scrubmac was started" {
  make_cleaner 10-cwd.sh 'echo "CWD=$(pwd -P)"'
  mkdir -p "$SANDBOX/elsewhere"
  run bash -c 'cd "$SANDBOX/elsewhere" && "$CMM"'
  [ "$status" -eq 0 ]
  [[ "$output" == *"CWD=$HOME"* ]] || false
}

@test "relative directory overrides are resolved against where scrubmac started, not \$HOME" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  mkdir -p "$SANDBOX/rel-tmp"
  run bash -c 'cd "$SANDBOX" && CMM_CLEANERS_DIR=cleaners CMM_STATE_DIR=rel-state TMPDIR=rel-tmp "$CMM"'
  [ "$status" -eq 0 ]
  [[ "$output" == *ALPHA-RAN* ]] || false
  [ -f "$SANDBOX/rel-state/last-run.json" ]
}

@test "with --json, a cleaner writing to fd 3 cannot corrupt the JSON document" {
  make_cleaner 10-fd3.sh 'echo GARBAGE >&3 || echo FD3-CLOSED'
  "$CMM" --json >"$SANDBOX/out.json" 2>"$SANDBOX/err" 3>&-
  [ -n "$REAL_PYTHON" ] || skip "no python3 to validate JSON"
  "$REAL_PYTHON" -c 'import json, sys; json.load(open(sys.argv[1]))' "$SANDBOX/out.json"
  refute grep -q GARBAGE "$SANDBOX/out.json"
  grep -q FD3-CLOSED "$SANDBOX/err"
}

@test "piped (non-terminal) output is streamed and logged in full" {
  make_cleaner 10-chatty.sh 'i=0; while [ $i -lt 300 ]; do echo "line $i"; i=$((i + 1)); done' 'echo LAST-LINE'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *LAST-LINE* ]] || false
  grep -q '^LAST-LINE$' "$STATE_DIR"/logs/run-*.log
  [ "$(grep -c '^line ' "$STATE_DIR"/logs/run-*.log)" -eq 300 ]
}

@test "quiet mode prints one line per cleaner instead of banners" {
  make_cleaner 10-alpha.sh 'echo ALPHA-OUT'
  make_lib_cleaner 20-beta.sh 'skip "skipping: beta not here"'
  run "$CMM" -q
  [ "$status" -eq 0 ]
  [[ "$output" == *"ok      alpha ("*"s)"* ]] || false
  [[ "$output" == *"skip    beta ("*"s) — skipping: beta not here"* ]] || false
  [[ "$output" != *ALPHA-OUT* ]] || false
  [[ "$output" != *$'alpha\n====='* ]] || false
}

@test "status shows cleaner output even with QUIET=1 (it is a report)" {
  make_lib_cleaner 10-rep.sh 'report echo REPORT-LINE'
  CMM_QUIET=1 run "$CMM" status
  [ "$status" -eq 0 ]
  [[ "$output" == *REPORT-LINE* ]] || false
}

@test "an empty selection says there was nothing to run" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  run "$CMM" --skip alpha
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to run"* ]] || false
}

@test "a tool that exits 75 fails its cleaner (75 means skipped only from the cleaner itself)" {
  make_lib_cleaner 10-tool75.sh 'run sh -c "exit 75"'
  run "$CMM"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL    tool75"* ]] || false
  [[ "$output" == *"failed: sh -c exit 75 (exit 1)"* ]] || false
}

@test "TIMEOUT=0 disables the watchdog" {
  make_cleaner 10-quick.sh 'sleep 1' 'echo QUICK-DONE'
  CMM_TIMEOUT=0 run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *QUICK-DONE* ]] || false
}

# ---------- selection: --skip ----------

@test "--skip leaves cleaners out of full and named runs" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  make_cleaner 20-beta.sh 'echo BETA-RAN'
  make_cleaner 30-gamma.sh 'echo GAMMA-RAN'
  run "$CMM" --skip beta
  [[ "$output" == *ALPHA-RAN* ]] && [[ "$output" != *BETA-RAN* ]] && [[ "$output" == *GAMMA-RAN* ]] || false
  run "$CMM" --skip=alpha,gamma
  [[ "$output" != *ALPHA-RAN* ]] && [[ "$output" == *BETA-RAN* ]] && [[ "$output" != *GAMMA-RAN* ]] || false
  run "$CMM" alpha beta --skip alpha
  [[ "$output" != *ALPHA-RAN* ]] && [[ "$output" == *BETA-RAN* ]] || false
  run "$CMM" --skip nosuch
  [ "$status" -eq 2 ]
  run "$CMM" --skip
  [ "$status" -eq 2 ]
}

# ---------- modes ----------

@test "--update-only and --clean-only drive the updating/cleaning predicates" {
  make_lib_cleaner 10-modes.sh \
    'if updating; then echo DID-UPDATE; fi' \
    'if cleaning; then echo DID-CLEAN; fi' \
    'echo "MODE=$CMM_MODE"'
  run "$CMM"
  [[ "$output" == *DID-UPDATE* ]] && [[ "$output" == *DID-CLEAN* ]] || false
  run "$CMM" --update-only
  [[ "$output" == *DID-UPDATE* ]] && [[ "$output" != *DID-CLEAN* ]] && [[ "$output" == *MODE=update* ]] || false
  run "$CMM" --clean-only
  [[ "$output" != *DID-UPDATE* ]] && [[ "$output" == *DID-CLEAN* ]] && [[ "$output" == *MODE=clean* ]] || false
  run "$CMM" --update-only --clean-only
  [ "$status" -eq 2 ]
  run "$CMM" list --clean-only
  [ "$status" -eq 2 ]
}

@test "skip_unless_updating / skip_unless_cleaning skip in the other mode" {
  make_lib_cleaner 10-upd.sh 'skip_unless_updating' 'echo UPD-RAN'
  make_lib_cleaner 20-cln.sh 'skip_unless_cleaning' 'echo CLN-RAN'
  run "$CMM" --clean-only
  [[ "$output" != *UPD-RAN* ]] && [[ "$output" == *CLN-RAN* ]] || false
  run "$CMM" --update-only
  [[ "$output" == *UPD-RAN* ]] && [[ "$output" != *CLN-RAN* ]] || false
}

# ---------- offline ----------

@test "offline: updates are skipped with a note, cleanup still runs" {
  make_lib_cleaner 10-mixed.sh \
    'if updating; then step echo UPDATE-STEP; fi' \
    'if cleaning; then step echo CLEAN-STEP; fi'
  make_lib_cleaner 20-updonly.sh 'skip_unless_updating' 'echo UPDONLY-RAN'
  CMM_OFFLINE=1 run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"offline"* ]] || false
  [[ "$output" != *"+ echo UPDATE-STEP"* ]] || false
  [[ "$output" == *"+ echo CLEAN-STEP"* ]] || false
  [[ "$output" != *UPDONLY-RAN* ]] || false
  [[ "$output" == *"offline — updates skipped"* ]] || false
}

@test "offline is detected from the routing table when not forced" {
  make_lib_cleaner 10-net.sh 'echo "OFFLINE=$CMM_OFFLINE"'
  # macOS route(8) exits 0 either way: no route = only a warning on stderr
  make_stub_script route <<'EOF'
echo "route: writing to routing socket: not in table" >&2
exit 0
EOF
  unset CMM_OFFLINE
  CMM_OS=Darwin run "$CMM"
  [[ "$output" == *"OFFLINE=1"* ]] || false
  make_stub_script route <<'EOF'
printf '   route to: default\ndestination: default\n    gateway: 192.168.1.1\n  interface: en0\n'
EOF
  CMM_OS=Darwin run "$CMM"
  [[ "$output" == *"OFFLINE=0"* ]] || false
  CMM_OFFLINE=1 CMM_OS=Darwin run "$CMM" # the environment override wins
  [[ "$output" == *"OFFLINE=1"* ]] || false
}

# ---------- interactive vs unattended ----------

@test "app_updates_allowed follows APP_UPDATES and whether a person is watching" {
  make_lib_cleaner 10-apps.sh 'if app_updates_allowed; then echo APPS-YES; else echo APPS-NO; fi'
  run "$CMM"
  [[ "$output" == *APPS-NO* ]] || false # tests are unattended (no TTY)
  CMM_ASSUME_INTERACTIVE=1 run "$CMM"
  [[ "$output" == *APPS-YES* ]] || false
  CMM_ASSUME_INTERACTIVE=1 run "$CMM" --scheduled
  [[ "$output" == *APPS-NO* ]] || false # --scheduled is never interactive
  CMM_APP_UPDATES=always run "$CMM"
  [[ "$output" == *APPS-YES* ]] || false
  CMM_ASSUME_INTERACTIVE=1 CMM_APP_UPDATES=never run "$CMM"
  [[ "$output" == *APPS-NO* ]] || false
}

# ---------- step semantics through the dispatcher ----------

@test "a failed step lets later steps run and fails the cleaner" {
  make_lib_cleaner 10-steps.sh 'step false' 'step echo AFTER-FAILED-STEP'
  run "$CMM"
  [ "$status" -eq 1 ]
  [[ "$output" == *AFTER-FAILED-STEP* ]] || false
  [[ "$output" == *FAIL* ]] || false
}

@test "summary notes appear under their cleaner" {
  make_lib_cleaner 10-noted.sh 'summary_note "casks not upgraded (unattended run)"'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"· casks not upgraded (unattended run)"* ]] || false
}

@test "--measure reports the space a cleaner frees" {
  mkdir -p "$SANDBOX/cache"
  dd if=/dev/zero of="$SANDBOX/cache/blob" bs=1024 count=2048 2>/dev/null
  make_lib_cleaner 10-cache.sh "cache_dir '$SANDBOX/cache'" "step rm -f '$SANDBOX/cache/blob'"
  run "$CMM" --measure
  [ "$status" -eq 0 ]
  [[ "$output" == *"freed 2.0 MB"* || "$output" == *"freed 2.1 MB"* ]] || false
  [[ "$output" == *"measured by cleaners"* ]] || false
}

# ---------- locking ----------

@test "second concurrent run is refused while a live run holds the lock" {
  start_holder scrubmac
  hold_lock "$HOLDER_PID"
  local held
  held="$(readlink "$LOCK")"
  make_cleaner 10-alpha.sh 'echo hi'
  run "$CMM"
  [ "$status" -eq 2 ]
  [[ "$output" == *"already in progress (pid $HOLDER_PID)"* ]] || false
  [ "$(readlink "$LOCK")" = "$held" ] # the holder's lock is untouched
}

@test "the run lock names the holder by pid and start time" {
  make_cleaner 10-peek.sh 'readlink "$HOME/.local/state/scrubmac/run.lock"'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" =~ [0-9]+:[A-Z][a-z][a-z]_[A-Z][a-z][a-z]_[0-9]+_[0-9:]+_[0-9]{4} ]] || false
}

@test "a holder whose start time cannot be read still holds the lock" {
  start_holder scrubmac
  hold_lock "$HOLDER_PID" ''
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  run "$CMM"
  [ "$status" -eq 2 ]
  [[ "$output" != *ALPHA-RAN* ]] || false
}

@test "a pre-release lock (a bare pid) of a live scrubmac still blocks" {
  start_holder scrubmac
  mkdir -p "$STATE_DIR"
  ln -s "$HOLDER_PID" "$LOCK"
  make_cleaner 10-alpha.sh 'echo hi'
  run "$CMM"
  [ "$status" -eq 2 ]
  [[ "$output" == *"already in progress (pid $HOLDER_PID)"* ]] || false
}

@test "an unwritable state dir is an environment error, not 'already in progress'" {
  mkdir -p "$STATE_DIR"
  chmod 500 "$STATE_DIR"
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  run "$CMM"
  chmod 700 "$STATE_DIR"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot write to $STATE_DIR"* ]] || false
  [[ "$output" != *"already in progress"* ]] || false
  [[ "$output" != *ALPHA-RAN* ]] || false
}

@test "something that is not a lock at the lock path is reported, not broken" {
  mkdir -p "$LOCK"
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  run "$CMM"
  [ "$status" -eq 2 ]
  [[ "$output" == *"is not a scrubmac lock"* ]] || false
  [ -d "$LOCK" ]
}

@test "stale lock from a dead process is recovered" {
  hold_lock "$(dead_pid)"
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale lock"* ]] || false
  [[ "$output" == *ALPHA-RAN* ]] || false
  [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ] || false # released after the run
}

@test "a lock whose pid now belongs to another process is stale (pid reuse)" {
  start_holder scrubmac # even one named like scrubmac: its start time differs
  hold_lock "$HOLDER_PID" "Thu_Jan_1_00:00:00_1970"
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale lock"* ]] || false
  [[ "$output" == *ALPHA-RAN* ]] || false
}

@test "the lock lives in the state dir, independent of TMPDIR (cron vs terminal)" {
  make_cleaner 10-peek.sh 'readlink "$HOME/.local/state/scrubmac/run.lock" >/dev/null && echo LOCK-IN-STATE-DIR'
  TMPDIR="$SANDBOX/other-tmp" run bash -c 'mkdir -p "$TMPDIR" && "$CMM"'
  [ "$status" -eq 0 ]
  [[ "$output" == *LOCK-IN-STATE-DIR* ]] || false
}

# ---------- interrupts ----------

@test "SIGINT stops the current cleaner, prints a partial summary, exits 130" {
  hang_child
  make_cleaner 10-first.sh 'echo FIRST-RAN'
  make_cleaner 20-slow.sh 'echo SLOW-START' "\"$SANDBOX/hangchild\" &" 'wait'
  make_cleaner 30-never.sh 'echo NEVER-RAN'
  # A background job inherits SIGINT as ignored (and bash cannot trap a
  # signal ignored at entry); a real Ctrl-C hits a foreground run. perl
  # restores the default disposition before exec'ing the dispatcher.
  perl -e '$SIG{INT} = "DEFAULT"; exec @ARGV or die' "$CMM" >"$SANDBOX/out" 2>&1 3>&- &
  local pid=$! i=0
  while ! grep -q SLOW-START "$SANDBOX/out" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 100 ] || break
    sleep 0.1
  done
  kill -INT "$pid"
  local rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 130 ]
  grep -q "interrupted" "$SANDBOX/out"
  grep -q "STOPPED" "$SANDBOX/out"
  refute grep -q NEVER-RAN "$SANDBOX/out"
  refute pgrep -f "$SANDBOX/hangchild" >/dev/null
  [ ! -L "$LOCK" ]
}

@test "SIGTERM (e.g. launchd stopping the job) is handled like an interrupt" {
  hang_child
  make_cleaner 10-slow.sh 'echo SLOW-START' "\"$SANDBOX/hangchild\" &" 'wait'
  "$CMM" >"$SANDBOX/out" 2>&1 3>&- &
  local pid=$! i=0
  while ! grep -q SLOW-START "$SANDBOX/out" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 100 ] || break
    sleep 0.1
  done
  kill -TERM "$pid"
  local rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 130 ]
  grep -q "STOPPED" "$SANDBOX/out"
  no_hang_child
}

@test "SIGHUP (the terminal went away) is handled like an interrupt" {
  hang_child
  make_cleaner 10-slow.sh 'echo SLOW-START' "\"$SANDBOX/hangchild\" &" 'wait'
  "$CMM" >"$SANDBOX/out" 2>&1 3>&- &
  local pid=$! i=0
  while ! grep -q SLOW-START "$SANDBOX/out" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 100 ] || break
    sleep 0.1
  done
  kill -HUP "$pid"
  local rc=0
  wait "$pid" || rc=$?
  [ "$rc" -eq 130 ]
  grep -q "STOPPED" "$SANDBOX/out"
  no_hang_child
  [ ! -L "$LOCK" ]
}

# ---------- summary & misc ----------

@test "summary lists each cleaner with its status and the total time" {
  make_cleaner 10-alpha.sh 'echo hi'
  make_cleaner 20-beta.sh 'exit 1'
  make_cleaner 30-gamma.sh 'exit 75'
  run "$CMM"
  [[ "$output" == *Summary* ]] || false
  [[ "$output" == *"ok      alpha"* ]] || false
  [[ "$output" == *"FAIL    beta"* ]] || false
  [[ "$output" == *"skip    gamma"* ]] || false
  [[ "$output" == *"1 ok, 1 skipped, 1 failed — "* ]] || false
}

@test "every cleaner skipping triggers the PATH hint (cron's minimal PATH)" {
  make_cleaner 10-a.sh 'exit 75'
  make_cleaner 20-b.sh 'exit 75'
  make_cleaner 30-c.sh 'exit 75'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"every cleaner skipped"* ]] || false
  [[ "$output" == *"/usr/bin:/bin"* ]] || false
}

@test "non-interactive run without config prints the defaults hint (no prompt)" {
  make_cleaner 10-alpha.sh 'echo hi'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"using defaults"* ]] || false
}

@test "usage error for unknown option" {
  run "$CMM" --bogus
  [ "$status" -eq 2 ]
}

@test "the 1.x shorthands still work: u = update, h = help" {
  run "$CMM" h
  [ "$status" -eq 0 ]
  [[ "$output" == *"USAGE"* ]] || false
  run "$CMM" H
  [ "$status" -eq 0 ]
  [[ "$output" == *"USAGE"* ]] || false
  local copy
  copy="$(plain_copy)" # never `update` the developer's own checkout
  run "$copy" u
  [[ "$output" == *"cannot self-update"* ]] || false
  run "$copy" U --check
  [[ "$output" == *"cannot self-update"* ]] || false
}

@test "help lists the commands and options" {
  run "$CMM" help
  [ "$status" -eq 0 ]
  local w
  for w in run list status doctor configure enable disable config schedule last update version \
    --dry-run --quiet --update-only --clean-only --skip --measure --json --scheduled --help --version; do
    [[ "$output" == *"$w"* ]] || {
      echo "help is missing: $w"
      false
    }
  done
}

@test "version prints the VERSION file value" {
  run "$CMM" version
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(cat "$REPO_ROOT/VERSION")"* ]] || false
}

# Build a realistic brew keg (Cellar/<token>/<ver>/libexec) around the real
# bin+lib, with a stub brew answering --prefix, and return the launcher path.
make_fake_keg() {
  local token="$1" tap="$2" pfx="$SANDBOX/brewpfx"
  local keg="$pfx/Cellar/$token/9.9.9"
  mkdir -p "$keg/libexec" "$pfx/bin"
  cp -R "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/VERSION" "$keg/libexec/"
  mkdir -p "$keg/libexec/cleaners"
  [ -n "$tap" ] && printf '{"source":{"spec":"stable","tap":"%s"}}' "$tap" >"$keg/INSTALL_RECEIPT.json"
  ln -s "$keg/libexec/bin/scrubmac" "$pfx/bin/$token"
  cat >"$STUB_BIN/brew" <<EOF
#!/bin/sh
[ "\$1" = "--prefix" ] && { echo "$pfx"; exit 0; }
printf '%s %s\n' brew "\$*" >>"\$CALL_LOG"
exit 0
EOF
  chmod 755 "$STUB_BIN/brew"
  printf '%s\n' "$pfx/bin/$token"
}

@test "update on a brew install upgrades its own fully-qualified formula (tap derived from receipt)" {
  local launcher
  launcher="$(make_fake_keg mytool someuser/tap)"
  unset CMM_BREW_PREFIX
  run "$launcher" update
  [ "$status" -eq 0 ]
  grep -q '^brew upgrade someuser/tap/mytool$' "$CALL_LOG"
}

@test "update on a core-installed keg uses the core-qualified name" {
  local launcher
  launcher="$(make_fake_keg coretool homebrew/core)"
  unset CMM_BREW_PREFIX
  run "$launcher" update
  [ "$status" -eq 0 ]
  grep -q '^brew upgrade homebrew/core/coretool$' "$CALL_LOG"
}

@test "update without an install receipt falls back to the bare Cellar token" {
  local launcher
  launcher="$(make_fake_keg baretool "")"
  unset CMM_BREW_PREFIX
  run "$launcher" update
  [ "$status" -eq 0 ]
  grep -q '^brew upgrade baretool$' "$CALL_LOG"
}

@test "update --check on a brew install only asks brew outdated" {
  local launcher
  launcher="$(make_fake_keg mytool someuser/tap)"
  unset CMM_BREW_PREFIX
  run "$launcher" update --check
  [ "$status" -eq 0 ]
  grep -q '^brew outdated --verbose someuser/tap/mytool$' "$CALL_LOG"
  refute grep -q '^brew upgrade' "$CALL_LOG"
}
