#!/usr/bin/env bats
# Dispatcher behavior: continue-on-failure, exit codes, selection, disabling,
# shadowing, dry-run, quiet buffering, locking, summary.

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
  make_lib_cleaner 10-canary.sh 'run touch "$HOME/pwned"'
  run "$CMM" --dry-run
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/pwned" ]
  [[ "$output" == *"+ touch"* ]]
  run "$CMM"
  [ -e "$HOME/pwned" ]
}

@test "naming cleaners runs exactly those, even when disabled" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  make_cleaner 20-beta.sh 'echo BETA-RAN'
  mkdir -p "$XDG_CONFIG_HOME/cleanmymac"
  echo beta >"$XDG_CONFIG_HOME/cleanmymac/disabled"
  run "$CMM" beta
  [ "$status" -eq 0 ]
  [[ "$output" != *ALPHA-RAN* ]]
  [[ "$output" == *BETA-RAN* ]]
}

@test "unknown cleaner name exits 2 with a hint" {
  make_cleaner 10-alpha.sh 'echo hi'
  run "$CMM" nonexistent
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown cleaner"* ]]
}

@test "disabled file is respected on full runs" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  make_cleaner 20-beta.sh 'echo BETA-RAN'
  mkdir -p "$XDG_CONFIG_HOME/cleanmymac"
  echo alpha >"$XDG_CONFIG_HOME/cleanmymac/disabled"
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" != *ALPHA-RAN* ]]
  [[ "$output" == *BETA-RAN* ]]
}

@test "docker and xcode are disabled by default when no config exists (D3)" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  make_cleaner 60-docker.sh 'echo DOCKER-RAN'
  make_cleaner 70-xcode.sh 'echo XCODE-RAN'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *ALPHA-RAN* ]]
  [[ "$output" != *DOCKER-RAN* ]]
  [[ "$output" != *XCODE-RAN* ]]
}

@test "user cleaners.d is merged and shadows a same-named builtin" {
  make_cleaner 10-alpha.sh 'echo BUILTIN-ALPHA'
  local userdir="$XDG_CONFIG_HOME/cleanmymac/cleaners.d"
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

@test "second concurrent run is refused while the lock is held" {
  mkdir -p "$TMPDIR/cleanmymac.$(id -u).lock"
  echo $$ >"$TMPDIR/cleanmymac.$(id -u).lock/pid" # our own live pid
  make_cleaner 10-alpha.sh 'echo hi'
  run "$CMM"
  [ "$status" -eq 2 ]
  [[ "$output" == *"already in progress"* ]]
}

@test "stale lock from a dead process is recovered" {
  local deadpid
  deadpid="$(sh -c 'echo $$')" # that shell has already exited
  mkdir -p "$TMPDIR/cleanmymac.$(id -u).lock"
  echo "$deadpid" >"$TMPDIR/cleanmymac.$(id -u).lock/pid"
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"stale lock"* ]]
  [[ "$output" == *ALPHA-RAN* ]]
}

@test "summary lists each cleaner with its status" {
  make_cleaner 10-alpha.sh 'echo hi'
  make_cleaner 20-beta.sh 'exit 1'
  make_cleaner 30-gamma.sh 'exit 75'
  run "$CMM"
  [[ "$output" == *Summary* ]]
  [[ "$output" == *"ok    alpha"* || "$output" == *"ok  "* ]]
  [[ "$output" == *FAIL* ]]
  [[ "$output" == *skip* ]]
  [[ "$output" == *"1 ok, 1 skipped, 1 failed"* ]]
}

@test "non-interactive run without config prints the defaults hint (no prompt)" {
  make_cleaner 10-alpha.sh 'echo hi'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"using defaults"* ]]
}

@test "cleaner environment receives CMM_DRY_RUN and CMM_COOLDOWN_DAYS" {
  make_cleaner 10-env.sh 'echo "DRY=${CMM_DRY_RUN:-unset} COOL=${CMM_COOLDOWN_DAYS:-unset}"'
  mkdir -p "$XDG_CONFIG_HOME/cleanmymac"
  printf 'COOLDOWN_DAYS=7\n' >"$XDG_CONFIG_HOME/cleanmymac/config"
  run "$CMM" -n
  [[ "$output" == *"DRY=1 COOL=7"* ]]
}

@test "list shows name, state, and source" {
  make_cleaner 10-alpha.sh '# gate: sometool' 'echo hi'
  mkdir -p "$XDG_CONFIG_HOME/cleanmymac"
  echo alpha >"$XDG_CONFIG_HOME/cleanmymac/disabled"
  run "$CMM" list
  [ "$status" -eq 0 ]
  [[ "$output" == *alpha* ]]
  [[ "$output" == *disabled* ]]
  [[ "$output" == *builtin* ]]
}

@test "enable and disable manage the disabled file" {
  make_cleaner 10-alpha.sh 'echo hi'
  make_cleaner 60-docker.sh 'echo docker'
  run "$CMM" disable alpha
  [ "$status" -eq 0 ]
  grep -Fxq alpha "$XDG_CONFIG_HOME/cleanmymac/disabled"
  # materializing preserved the baked default-disabled entries
  grep -Fxq docker "$XDG_CONFIG_HOME/cleanmymac/disabled"
  run "$CMM" enable docker
  [ "$status" -eq 0 ]
  ! grep -Fxq docker "$XDG_CONFIG_HOME/cleanmymac/disabled"
  run "$CMM" enable no-such-cleaner
  [ "$status" -eq 2 ]
}

@test "usage error for unknown option" {
  run "$CMM" --bogus
  [ "$status" -eq 2 ]
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
  ln -s "$keg/libexec/bin/cleanmymac" "$pfx/bin/$token"
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

@test "version prints the VERSION file value" {
  run "$CMM" version
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(cat "$REPO_ROOT/VERSION")"* ]]
}
