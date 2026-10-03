#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# Security guarantees (S1–S7): execution-safety guards at the dispatcher
# level, config-injection inertness end to end, ff-only self-update, and
# code-level pins (no eval, root guards present).

load helpers/setup

setup() { setup_sandbox; }
teardown() { teardown_sandbox; }

@test "S2: a group-writable cleaner is refused, never executed, and fails the run" {
  make_cleaner 10-evil.sh 'echo EVIL-RAN'
  chmod 775 "$FIXTURES/10-evil.sh"
  make_cleaner 20-good.sh 'echo GOOD-RAN'
  run "$CMM"
  [ "$status" -eq 1 ]
  [[ "$output" == *"group/world-writable"* ]] || false
  [[ "$output" != *EVIL-RAN* ]] || false
  [[ "$output" == *GOOD-RAN* ]] || false
}

@test "S2: a symlinked cleaner is refused" {
  make_cleaner 10-target.sh 'echo TARGET-RAN'
  mv "$FIXTURES/10-target.sh" "$SANDBOX/elsewhere.sh"
  ln -s "$SANDBOX/elsewhere.sh" "$FIXTURES/10-evil.sh"
  run "$CMM"
  [ "$status" -eq 1 ]
  [[ "$output" == *"symlinked cleaners are not run"* ]] || false
  [[ "$output" != *TARGET-RAN* ]] || false
}

@test "S2: a world-writable cleaners directory refuses everything in it" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  chmod 777 "$FIXTURES"
  run "$CMM"
  [ "$status" -eq 1 ]
  [[ "$output" == *"directory must be owned by you"* ]] || false
  [[ "$output" != *ALPHA-RAN* ]] || false
  chmod 755 "$FIXTURES"
}

@test "S5: shell syntax in the config file is inert through the dispatcher" {
  make_cleaner 10-alpha.sh 'echo hi'
  mkdir -p "$XDG_CONFIG_HOME/scrubmac"
  cat >"$XDG_CONFIG_HOME/scrubmac/config" <<EOF
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
  run "$inst/bin/scrubmac" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already up to date."* ]] || false
  echo change >"$origin/NEWFILE"
  git -C "$origin" -c user.email=t@t -c user.name=t add -A
  git -C "$origin" -c user.email=t@t -c user.name=t commit -qm two
  run "$inst/bin/scrubmac" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Changes pulled:"* ]] || false
  [[ "$output" == *NEWFILE* ]] || false
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
  run "$inst/bin/scrubmac" update
  [ "$status" -eq 1 ]
  [[ "$output" == *diverged* ]] || false
}

@test "S6: doctor flags '.' and world-writable directories on PATH" {
  local wwdir="$SANDBOX/ww"
  mkdir -p "$wwdir"
  chmod 777 "$wwdir"
  PATH="$STUB_BIN:$wwdir:.:/usr/bin:/bin:/usr/sbin:/sbin" run "$CMM" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"PATH contains '.'"* ]] || false
  [[ "$output" == *"world-writable: $wwdir"* ]] || false
}

@test "S6: doctor reports a clean PATH when there is nothing to flag" {
  run "$CMM" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"no PATH issues found"* ]] || false
}

@test "S1: every entry point carries the root-refusal guard" {
  grep -q 'EUID' "$REPO_ROOT/bin/scrubmac"
  grep -q 'must not run as root' "$REPO_ROOT/bin/scrubmac"
  grep -q 'must not run as root' "$REPO_ROOT/install.sh"
  grep -q 'must not run as root' "$REPO_ROOT/uninstall.sh"
}

@test "S1: the run lock never lives in a shared world-writable directory" {
  make_cleaner 10-peek.sh 'echo "LOCK=$(readlink "$HOME/.local/state/scrubmac/run.lock")"'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"LOCK="[0-9]* ]] || false
  [ ! -e "/tmp/scrubmac.$(id -u).lock" ] || ! [ -O "/tmp/scrubmac.$(id -u).lock" ]
}

@test "S5: a cleaner's stdin is /dev/null — it can never read or answer prompts" {
  make_cleaner 10-stdin.sh 'if [ -t 0 ]; then echo STDIN-TTY; elif read -r x; then echo "STDIN-DATA[$x]"; else echo STDIN-EMPTY; fi'
  run "$CMM" <<<"secret-typed-input"
  [[ "$output" == *STDIN-EMPTY* ]] || false
  [[ "$output" != *secret-typed-input* ]] || false
}

# Tripwires: eval/sudo in command position — at the start of a command,
# after ; | & ( { ! or a backtick, inside $( ), after a keyword (if then do
# …), or as the argument of a helper or wrapper (run step try preview report
# exec command env xargs nohup nice time). Mentions in comments and messages
# are fine; invocations are not.
cmd_position_hits() { # cmd_position_hits WORD [FILE…]
  local word="$1"
  shift
  [ "$#" -gt 0 ] || set -- "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/cleaners" \
    "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh"
  { grep -rnE "(^|[;|&({\`!]|\\\$\(|(^|[[:space:]])(run|try|step|preview|report|then|do|if|elif|while|until|exec|command|builtin|env|xargs|nohup|nice|time))[[:space:]]*$word([[:space:]]|\$)" "$@" || true; } |
    grep -vE '^([^:]+:)?[0-9]+:[[:space:]]*#' || true
}

@test "no eval invoked anywhere in product code" {
  [ -z "$(cmd_position_hits eval)" ]
}

@test "no sudo invoked anywhere in product code (S1)" {
  [ -z "$(cmd_position_hits sudo)" ]
}

@test "the tripwires catch the forms that used to slip past them" {
  local f="$SANDBOX/mutant.sh"
  printf 'step sudo -n mas upgrade\n' >"$f"
  [ -n "$(cmd_position_hits sudo "$f")" ]
  printf 'if eval "true"; then :; fi\n' >"$f"
  [ -n "$(cmd_position_hits eval "$f")" ]
  printf 'x=`sudo id`\n' >"$f"
  [ -n "$(cmd_position_hits sudo "$f")" ]
  printf 'note "never uses sudo, ever"\n# sudo in a comment\n' >"$f"
  [ -z "$(cmd_position_hits sudo "$f")" ]
}
