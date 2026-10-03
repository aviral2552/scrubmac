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
  [[ "$output" == *ALPHA-RAN* ]]
  [[ "$output" == *BETA-RAN* ]]
  [[ "$output" == *GAMMA-RAN* ]]
  [[ "$output" == *"1 failed"* ]]
}

@test "exits 0 when everything succeeds or skips" {
  make_cleaner 10-alpha.sh 'echo ok'
  make_cleaner 20-beta.sh 'echo skipping' 'exit 75'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 ok, 1 skipped, 0 failed"* ]]
}

@test "exit code 75 is reported as skip in the summary" {
  make_lib_cleaner 10-ghost.sh 'skip_unless definitely_not_a_real_tool_xyz'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"skip"* ]]
  [[ "$output" == *"0 ok, 1 skipped, 0 failed"* ]]
}

@test "dry-run executes nothing (canary survives)" {
  make_lib_cleaner 10-canary.sh 'run touch "$HOME/pwned"' 'step touch "$HOME/pwned2"'
  run "$CMM" --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/pwned" ]
  [ ! -e "$HOME/pwned2" ]
  [[ "$output" == *"+ touch"* ]]
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
  [[ "$output" != *ALPHA-RAN* ]]
  [[ "$output" == *BETA-RAN* ]]
}

@test "unknown cleaner name exits 2 with a did-you-mean hint" {
  make_cleaner 10-homebrew.sh 'echo hi'
  run "$CMM" hombrew
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown cleaner"* ]]
  [[ "$output" == *"did you mean 'homebrew'"* ]]
  run "$CMM" lsit
  [ "$status" -eq 2 ]
  [[ "$output" == *"did you mean 'list'"* ]]
  run "$CMM" zzzzzzzz
  [ "$status" -eq 2 ]
  [[ "$output" != *"did you mean"* ]]
}

@test "disabled file is respected on full runs" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  make_cleaner 20-beta.sh 'echo BETA-RAN'
  mkdir -p "$XDG_CONFIG_HOME/scrubmac"
  echo alpha >"$XDG_CONFIG_HOME/scrubmac/disabled"
  : >"$XDG_CONFIG_HOME/scrubmac/enabled"
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" != *ALPHA-RAN* ]]
  [[ "$output" == *BETA-RAN* ]]
}

@test "'# default: off' cleaners stay off until enabled (D3)" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  make_cleaner 60-docker.sh '# default: off' 'echo DOCKER-RAN'
  make_cleaner 70-xcode.sh '# default: off' 'echo XCODE-RAN'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *ALPHA-RAN* ]]
  [[ "$output" != *DOCKER-RAN* ]]
  [[ "$output" != *XCODE-RAN* ]]
  run "$CMM" enable docker
  [ "$status" -eq 0 ]
  run "$CMM"
  [[ "$output" == *DOCKER-RAN* ]]
  [[ "$output" != *XCODE-RAN* ]]
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
  [[ "$output" == *USER-ALPHA* ]]
  [[ "$output" != *BUILTIN-ALPHA* ]]
  [[ "$output" == *USER-EXTRA* ]]
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
  [[ "$output" == *ALPHA-RAN* ]]
  [[ "$output" != *NOEXEC* ]]
}

@test "quiet mode hides success output but dumps output of a failing cleaner" {
  make_cleaner 10-chatty.sh 'echo CHATTY-NOISE'
  make_cleaner 20-broken.sh 'echo BROKEN-EVIDENCE' 'exit 3'
  run "$CMM" --quiet
  [ "$status" -eq 1 ]
  [[ "$output" != *CHATTY-NOISE* ]]
  [[ "$output" == *BROKEN-EVIDENCE* ]]
}

@test "quiet mode surfaces the skip reason" {
  make_lib_cleaner 10-ghost.sh 'skip "skipping: ghost tool absent"'
  run "$CMM" -q
  [ "$status" -eq 0 ]
  [[ "$output" == *"ghost tool absent"* ]]
}

# ---------- stdin isolation (regression: a reader swallowed the next cleaner) ----------

@test "a cleaner that reads stdin cannot swallow the rest of the run" {
  make_cleaner 10-reader.sh 'read -r line || line="<eof>"' 'echo "READER GOT [$line]"'
  make_cleaner 20-second.sh 'echo SECOND-RAN'
  make_cleaner 30-third.sh 'echo THIRD-RAN'
  run "$CMM" <<<$'typed-input\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"READER GOT [<eof>]"* ]]
  [[ "$output" == *SECOND-RAN* ]]
  [[ "$output" == *THIRD-RAN* ]]
  [[ "$output" == *"3 ok, 0 skipped, 0 failed"* ]]
}

# ---------- settings precedence (regression: env was overwritten by config) ----------

@test "environment beats the config file (CMM_<KEY>)" {
  make_cleaner 10-env.sh 'echo "COOL=${CMM_COOLDOWN_DAYS} AGE=${CMM_DERIVEDDATA_AGE_DAYS}"'
  mkdir -p "$XDG_CONFIG_HOME/scrubmac"
  printf 'COOLDOWN_DAYS=0\nDERIVEDDATA_AGE_DAYS=45\n' >"$XDG_CONFIG_HOME/scrubmac/config"
  CMM_COOLDOWN_DAYS=7 run "$CMM"
  [[ "$output" == *"COOL=7 AGE=45"* ]]
  run "$CMM"
  [[ "$output" == *"COOL=0 AGE=45"* ]]
}

@test "a flag beats the environment (-q over CMM_QUIET=0)" {
  make_cleaner 10-chatty.sh 'echo CHATTY-NOISE'
  CMM_QUIET=0 run "$CMM" -q
  [[ "$output" != *CHATTY-NOISE* ]]
  CMM_QUIET=1 run "$CMM"
  [[ "$output" != *CHATTY-NOISE* ]]
}

@test "invalid environment and config values warn and fall back" {
  make_cleaner 10-env.sh 'echo "COOL=${CMM_COOLDOWN_DAYS} TO=${CMM_TIMEOUT}"'
  mkdir -p "$XDG_CONFIG_HOME/scrubmac"
  printf 'TIMEOUT=abc\n' >"$XDG_CONFIG_HOME/scrubmac/config"
  CMM_COOLDOWN_DAYS=lots run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignoring CMM_COOLDOWN_DAYS=lots"* ]]
  [[ "$output" == *"COOL=7 TO=3600"* ]]
}

@test "the cooldown defaults to 7 days when nothing sets it" {
  make_cleaner 10-env.sh 'echo "COOL=${CMM_COOLDOWN_DAYS}"'
  run "$CMM"
  [[ "$output" == *"COOL=7"* ]]
}

@test "cleaner environment receives CMM_DRY_RUN, CMM_MODE and CMM_COOLDOWN_DAYS" {
  make_cleaner 10-env.sh 'echo "DRY=${CMM_DRY_RUN:-unset} MODE=${CMM_MODE} COOL=${CMM_COOLDOWN_DAYS:-unset}"'
  mkdir -p "$XDG_CONFIG_HOME/scrubmac"
  printf 'COOLDOWN_DAYS=3\n' >"$XDG_CONFIG_HOME/scrubmac/config"
  run "$CMM" -n
  [[ "$output" == *"DRY=1 MODE=run COOL=3"* ]]
}

# ---------- execution-safety refusals are failures (regression: exit 0) ----------

@test "a refused cleaner is reported as REFUSED and fails the run" {
  make_cleaner 10-good.sh 'echo GOOD-RAN'
  make_cleaner 20-evil.sh 'echo EVIL-RAN'
  chmod 775 "$FIXTURES/20-evil.sh"
  run "$CMM"
  [ "$status" -eq 1 ]
  [[ "$output" == *GOOD-RAN* ]]
  [[ "$output" != *EVIL-RAN* ]]
  [[ "$output" == *REFUSED* ]]
  [[ "$output" == *"1 ok, 0 skipped, 1 failed"* ]]
}

@test "naming a refused cleaner explicitly also exits 1" {
  make_cleaner 20-evil.sh 'echo EVIL-RAN'
  chmod 775 "$FIXTURES/20-evil.sh"
  run "$CMM" evil
  [ "$status" -eq 1 ]
  [[ "$output" == *REFUSED* ]]
  [[ "$output" != *EVIL-RAN* ]]
}

# ---------- timeouts ----------

@test "TIMEOUT stops a hung cleaner (and its children); the run continues" {
  make_cleaner 10-hang.sh 'echo HANG-START' 'sleep 60' 'echo NEVER'
  make_cleaner 20-next.sh 'echo NEXT-RAN'
  local start=$SECONDS
  CMM_TIMEOUT=1 run "$CMM"
  [ "$status" -eq 1 ]
  [ $((SECONDS - start)) -lt 20 ]
  [[ "$output" == *HANG-START* ]]
  [[ "$output" != *NEVER* ]]
  [[ "$output" == *NEXT-RAN* ]]
  [[ "$output" == *TIMEOUT* ]]
  [[ "$output" == *"stopped after 1s"* ]]
  refute pgrep -f "$FIXTURES/10-hang.sh" >/dev/null
}

@test "TIMEOUT=0 disables the watchdog" {
  make_cleaner 10-quick.sh 'sleep 1' 'echo QUICK-DONE'
  CMM_TIMEOUT=0 run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *QUICK-DONE* ]]
}

# ---------- selection: --skip ----------

@test "--skip leaves cleaners out of full and named runs" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  make_cleaner 20-beta.sh 'echo BETA-RAN'
  make_cleaner 30-gamma.sh 'echo GAMMA-RAN'
  run "$CMM" --skip beta
  [[ "$output" == *ALPHA-RAN* ]] && [[ "$output" != *BETA-RAN* ]] && [[ "$output" == *GAMMA-RAN* ]]
  run "$CMM" --skip=alpha,gamma
  [[ "$output" != *ALPHA-RAN* ]] && [[ "$output" == *BETA-RAN* ]] && [[ "$output" != *GAMMA-RAN* ]]
  run "$CMM" alpha beta --skip alpha
  [[ "$output" != *ALPHA-RAN* ]] && [[ "$output" == *BETA-RAN* ]]
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
  [[ "$output" == *DID-UPDATE* ]] && [[ "$output" == *DID-CLEAN* ]]
  run "$CMM" --update-only
  [[ "$output" == *DID-UPDATE* ]] && [[ "$output" != *DID-CLEAN* ]] && [[ "$output" == *MODE=update* ]]
  run "$CMM" --clean-only
  [[ "$output" != *DID-UPDATE* ]] && [[ "$output" == *DID-CLEAN* ]] && [[ "$output" == *MODE=clean* ]]
  run "$CMM" --update-only --clean-only
  [ "$status" -eq 2 ]
  run "$CMM" list --clean-only
  [ "$status" -eq 2 ]
}

@test "skip_unless_updating / skip_unless_cleaning skip in the other mode" {
  make_lib_cleaner 10-upd.sh 'skip_unless_updating' 'echo UPD-RAN'
  make_lib_cleaner 20-cln.sh 'skip_unless_cleaning' 'echo CLN-RAN'
  run "$CMM" --clean-only
  [[ "$output" != *UPD-RAN* ]] && [[ "$output" == *CLN-RAN* ]]
  run "$CMM" --update-only
  [[ "$output" == *UPD-RAN* ]] && [[ "$output" != *CLN-RAN* ]]
}

# ---------- offline ----------

@test "offline: updates are skipped with a note, cleanup still runs" {
  make_lib_cleaner 10-mixed.sh \
    'if updating; then step echo UPDATE-STEP; fi' \
    'if cleaning; then step echo CLEAN-STEP; fi'
  make_lib_cleaner 20-updonly.sh 'skip_unless_updating' 'echo UPDONLY-RAN'
  CMM_OFFLINE=1 run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"offline"* ]]
  [[ "$output" != *"+ echo UPDATE-STEP"* ]]
  [[ "$output" == *"+ echo CLEAN-STEP"* ]]
  [[ "$output" != *UPDONLY-RAN* ]]
  [[ "$output" == *"offline — updates skipped"* ]]
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
  [[ "$output" == *"OFFLINE=1"* ]]
  make_stub_script route <<'EOF'
printf '   route to: default\ndestination: default\n    gateway: 192.168.1.1\n  interface: en0\n'
EOF
  CMM_OS=Darwin run "$CMM"
  [[ "$output" == *"OFFLINE=0"* ]]
  CMM_OFFLINE=1 CMM_OS=Darwin run "$CMM" # the environment override wins
  [[ "$output" == *"OFFLINE=1"* ]]
}

# ---------- interactive vs unattended ----------

@test "app_updates_allowed follows APP_UPDATES and whether a person is watching" {
  make_lib_cleaner 10-apps.sh 'if app_updates_allowed; then echo APPS-YES; else echo APPS-NO; fi'
  run "$CMM"
  [[ "$output" == *APPS-NO* ]] # tests are unattended (no TTY)
  CMM_ASSUME_INTERACTIVE=1 run "$CMM"
  [[ "$output" == *APPS-YES* ]]
  CMM_ASSUME_INTERACTIVE=1 run "$CMM" --scheduled
  [[ "$output" == *APPS-NO* ]] # --scheduled is never interactive
  CMM_APP_UPDATES=always run "$CMM"
  [[ "$output" == *APPS-YES* ]]
  CMM_ASSUME_INTERACTIVE=1 CMM_APP_UPDATES=never run "$CMM"
  [[ "$output" == *APPS-NO* ]]
}

# ---------- step semantics through the dispatcher ----------

@test "a failed step lets later steps run and fails the cleaner" {
  make_lib_cleaner 10-steps.sh 'step false' 'step echo AFTER-FAILED-STEP'
  run "$CMM"
  [ "$status" -eq 1 ]
  [[ "$output" == *AFTER-FAILED-STEP* ]]
  [[ "$output" == *FAIL* ]]
}

@test "summary notes appear under their cleaner" {
  make_lib_cleaner 10-noted.sh 'summary_note "casks not upgraded (unattended run)"'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"· casks not upgraded (unattended run)"* ]]
}

@test "--measure reports the space a cleaner frees" {
  mkdir -p "$SANDBOX/cache"
  dd if=/dev/zero of="$SANDBOX/cache/blob" bs=1024 count=2048 2>/dev/null
  make_lib_cleaner 10-cache.sh "cache_dir '$SANDBOX/cache'" "step rm -f '$SANDBOX/cache/blob'"
  run "$CMM" --measure
  [ "$status" -eq 0 ]
  [[ "$output" == *"freed 2.0 MB"* || "$output" == *"freed 2.1 MB"* ]]
  [[ "$output" == *"measured by cleaners"* ]]
}

# ---------- locking ----------

@test "second concurrent run is refused while a live run holds the lock" {
  start_holder scrubmac
  hold_lock "$HOLDER_PID"
  make_cleaner 10-alpha.sh 'echo hi'
  run "$CMM"
  [ "$status" -eq 2 ]
  [[ "$output" == *"already in progress (pid $HOLDER_PID)"* ]]
  [ "$(readlink "$LOCK")" = "$HOLDER_PID" ] # the holder's lock is untouched
}

@test "stale lock from a dead process is recovered" {
  hold_lock "$(dead_pid)"
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale lock"* ]]
  [[ "$output" == *ALPHA-RAN* ]]
  [ ! -e "$LOCK" ] && [ ! -L "$LOCK" ] # released after the run
}

@test "a lock whose pid now belongs to an unrelated process is stale (pid reuse)" {
  start_holder unrelated
  hold_lock "$HOLDER_PID"
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *ALPHA-RAN* ]]
}

@test "the lock lives in the state dir, independent of TMPDIR (cron vs terminal)" {
  make_cleaner 10-peek.sh 'readlink "$HOME/.local/state/scrubmac/run.lock" >/dev/null && echo LOCK-IN-STATE-DIR'
  TMPDIR="$SANDBOX/other-tmp" run bash -c 'mkdir -p "$TMPDIR" && "$CMM"'
  [ "$status" -eq 0 ]
  [[ "$output" == *LOCK-IN-STATE-DIR* ]]
}

# ---------- interrupts ----------

@test "SIGINT stops the current cleaner, prints a partial summary, exits 130" {
  make_cleaner 10-first.sh 'echo FIRST-RAN'
  make_cleaner 20-slow.sh 'echo SLOW-START' 'sleep 60'
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
  refute pgrep -f "$FIXTURES/20-slow.sh" >/dev/null
  [ ! -L "$LOCK" ]
}

@test "SIGTERM (e.g. launchd stopping the job) is handled like an interrupt" {
  make_cleaner 10-slow.sh 'echo SLOW-START' 'sleep 60'
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
  refute pgrep -f "$FIXTURES/10-slow.sh" >/dev/null
}

# ---------- summary & misc ----------

@test "summary lists each cleaner with its status and the total time" {
  make_cleaner 10-alpha.sh 'echo hi'
  make_cleaner 20-beta.sh 'exit 1'
  make_cleaner 30-gamma.sh 'exit 75'
  run "$CMM"
  [[ "$output" == *Summary* ]]
  [[ "$output" == *"ok      alpha"* ]]
  [[ "$output" == *"FAIL    beta"* ]]
  [[ "$output" == *"skip    gamma"* ]]
  [[ "$output" == *"1 ok, 1 skipped, 1 failed — "* ]]
}

@test "every cleaner skipping triggers the PATH hint (cron's minimal PATH)" {
  make_cleaner 10-a.sh 'exit 75'
  make_cleaner 20-b.sh 'exit 75'
  make_cleaner 30-c.sh 'exit 75'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"every cleaner skipped"* ]]
  [[ "$output" == *"/usr/bin:/bin"* ]]
}

@test "non-interactive run without config prints the defaults hint (no prompt)" {
  make_cleaner 10-alpha.sh 'echo hi'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"using defaults"* ]]
}

@test "usage error for unknown option" {
  run "$CMM" --bogus
  [ "$status" -eq 2 ]
}

@test "help lists the commands and options" {
  run "$CMM" help
  [ "$status" -eq 0 ]
  local w
  for w in list status doctor configure enable disable config schedule last update version \
    --dry-run --quiet --update-only --clean-only --skip --measure --json --scheduled; do
    [[ "$output" == *"$w"* ]] || {
      echo "help is missing: $w"
      false
    }
  done
}

@test "version prints the VERSION file value" {
  run "$CMM" version
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(cat "$REPO_ROOT/VERSION")"* ]]
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
