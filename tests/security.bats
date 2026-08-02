#!/usr/bin/env bats
# Security guarantees (S1–S7): execution-safety guards at the dispatcher
# level, config-injection inertness end to end, ff-only self-update, and
# code-level pins (no eval, root guards present).

load helpers/setup

setup() { setup_sandbox; }
teardown() { teardown_sandbox; }

@test "S2: a group-writable cleaner is refused and never executed" {
  make_cleaner 10-evil.sh 'echo EVIL-RAN'
  chmod 775 "$FIXTURES/10-evil.sh"
  make_cleaner 20-good.sh 'echo GOOD-RAN'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"group/world-writable"* ]]
  [[ "$output" != *EVIL-RAN* ]]
  [[ "$output" == *GOOD-RAN* ]]
}

@test "S2: a symlinked cleaner is refused" {
  make_cleaner 10-target.sh 'echo TARGET-RAN'
  mv "$FIXTURES/10-target.sh" "$SANDBOX/elsewhere.sh"
  ln -s "$SANDBOX/elsewhere.sh" "$FIXTURES/10-evil.sh"
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"symlinked cleaners are not run"* ]]
  [[ "$output" != *TARGET-RAN* ]]
}

@test "S2: a world-writable cleaners directory refuses everything in it" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  chmod 777 "$FIXTURES"
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"directory must be owned by you"* ]]
  [[ "$output" != *ALPHA-RAN* ]]
  chmod 755 "$FIXTURES"
}

@test "S5: shell syntax in the config file is inert through the dispatcher" {
  make_cleaner 10-alpha.sh 'echo hi'
  mkdir -p "$XDG_CONFIG_HOME/cleanmymac"
  cat >"$XDG_CONFIG_HOME/cleanmymac/config" <<EOF
COLOR=\$(touch $SANDBOX/pwned)
QUIET=0; touch $SANDBOX/pwned2
COOLDOWN_DAYS=7
EOF
  run "$CMM" list
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/pwned" ]
  [ ! -e "$SANDBOX/pwned2" ]
}

@test "S3: update fast-forwards from a clean remote and shows what changed" {
  local origin="$SANDBOX/origin" inst="$SANDBOX/inst"
  mkdir -p "$origin"
  cp -R "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$origin/"
  cp "$REPO_ROOT/VERSION" "$origin/"
  mkdir -p "$origin/cleaners"
  git -C "$origin" init -q
  git -C "$origin" -c user.email=t@t -c user.name=t add -A
  git -C "$origin" -c user.email=t@t -c user.name=t commit -qm one
  git clone -q "$origin" "$inst"
  run "$inst/bin/cleanmymac" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already up to date."* ]]
  echo change >"$origin/NEWFILE"
  git -C "$origin" -c user.email=t@t -c user.name=t add -A
  git -C "$origin" -c user.email=t@t -c user.name=t commit -qm two
  run "$inst/bin/cleanmymac" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Changes pulled:"* ]]
  [[ "$output" == *NEWFILE* ]]
  [ -f "$inst/NEWFILE" ]
}

@test "S3: update refuses when local history has diverged (no forced rewrites)" {
  local origin="$SANDBOX/origin" inst="$SANDBOX/inst"
  mkdir -p "$origin"
  cp -R "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$origin/"
  cp "$REPO_ROOT/VERSION" "$origin/"
  mkdir -p "$origin/cleaners"
  git -C "$origin" init -q
  git -C "$origin" -c user.email=t@t -c user.name=t add -A
  git -C "$origin" -c user.email=t@t -c user.name=t commit -qm one
  git clone -q "$origin" "$inst"
  echo local >"$inst/LOCALFILE"
  git -C "$inst" -c user.email=t@t -c user.name=t add -A
  git -C "$inst" -c user.email=t@t -c user.name=t commit -qm local
  echo remote >"$origin/REMOTEFILE"
  git -C "$origin" -c user.email=t@t -c user.name=t add -A
  git -C "$origin" -c user.email=t@t -c user.name=t commit -qm remote
  run "$inst/bin/cleanmymac" update
  [ "$status" -eq 1 ]
  [[ "$output" == *diverged* ]]
}

@test "S6: doctor flags '.' and world-writable directories on PATH" {
  local wwdir="$SANDBOX/ww"
  mkdir -p "$wwdir"
  chmod 777 "$wwdir"
  PATH="$STUB_BIN:$wwdir:.:/usr/bin:/bin:/usr/sbin:/sbin" run "$CMM" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"PATH contains '.'"* ]]
  [[ "$output" == *"world-writable: $wwdir"* ]]
}

@test "S6: doctor reports a clean PATH when there is nothing to flag" {
  run "$CMM" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"no PATH issues found"* ]]
}

@test "S1: every entry point carries the root-refusal guard" {
  grep -q 'EUID' "$REPO_ROOT/bin/cleanmymac"
  grep -q 'must not run as root' "$REPO_ROOT/bin/cleanmymac"
  grep -q 'must not run as root' "$REPO_ROOT/install.sh"
  grep -q 'must not run as root' "$REPO_ROOT/uninstall.sh"
}

# Tripwires: eval/sudo in command position (start of a command, after ;|&,
# inside $( ), or as a run/try argument). Mentions in comments and messages
# are fine; invocations are not.
@test "no eval invoked anywhere in product code" {
  ! grep -rnE '(^|[;|&]|\$\()[[:space:]]*eval[[:space:]]' \
    "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/cleaners" \
    "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh"
  ! grep -rnE '(run|try)[[:space:]]+eval[[:space:]]' \
    "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/cleaners"
}

@test "no sudo invoked anywhere in product code (S1)" {
  ! grep -rnE '(^|[;|&]|\$\()[[:space:]]*sudo[[:space:]]' \
    "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/cleaners" \
    "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh"
  ! grep -rnE '(run|try)[[:space:]]+sudo[[:space:]]' \
    "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/cleaners"
}
