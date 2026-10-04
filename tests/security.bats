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
  local f
  for f in bin/scrubmac install.sh uninstall.sh; do
    # (the exact test, so a weakened comparison is caught — running the
    # scripts as root is not something a test suite should do)
    grep -Fqx 'if [ "${EUID:-$(id -u)}" -eq 0 ]; then' "$REPO_ROOT/$f"
    grep -q 'must not run as root' "$REPO_ROOT/$f"
  done
}

@test "S1: the run lock lives in your state dir; only the transitional 2.x lock is in TMPDIR, and only as your own dir" {
  make_cleaner 10-peek.sh 'echo "LOCK=$(readlink "$HOME/.local/state/scrubmac/run.lock")"' \
    'ls -ld "$TMPDIR/cleanmymac.$(id -u).lock"'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" =~ LOCK=[0-9]+: ]] || false
  [[ "$output" == *"$(id -un)"* ]] || false # the 2.x-compatible lock dir is ours
  [ -z "$(find "$TMPDIR" -maxdepth 1 -name 'scrubmac*.lock' 2>/dev/null)" ]
  [ ! -e "$TMPDIR/cleanmymac.$(id -u).lock" ] # released after the run
}

@test "S5: a cleaner's stdin is /dev/null — it can never read or answer prompts" {
  make_cleaner 10-stdin.sh 'if [ -t 0 ]; then echo STDIN-TTY; elif read -r x; then echo "STDIN-DATA[$x]"; else echo STDIN-EMPTY; fi'
  run "$CMM" <<<"secret-typed-input"
  [[ "$output" == *STDIN-EMPTY* ]] || false
  [[ "$output" != *secret-typed-input* ]] || false
}

# Tripwires: eval/sudo in command position — at a line start, after
# ; | & ( { ! or a backtick, inside $( ), after a keyword (if then do else
# elif while until) or a case arm's ")", or as the command of a helper or
# wrapper (run step try preview report exec command builtin env xargs nohup
# nice time coproc) even after its options or VAR=value assignments — quoted,
# backslash-escaped or path-qualified ("sudo", \sudo, /usr/bin/sudo) too. A heuristic backed by review:
# mentions in comments and messages are fine; invocations are not.
cmd_position_hits() { # cmd_position_hits WORD [FILE…]
  local word="$1"
  shift
  [ "$#" -gt 0 ] || set -- "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/cleaners" \
    "$REPO_ROOT/install.sh" "$REPO_ROOT/uninstall.sh"
  local n
  n="$(find "$@" -type f \( -name '*.sh' -o -name 'scrubmac' -o -name 'cleanmymac' -o -name '*.bash' \) | wc -l)"
  [ "$n" -gt 0 ] || {
    echo "tripwire scanned no files"
    return 0
  }
  find "$@" -type f \( -name '*.sh' -o -name 'scrubmac' -o -name 'cleanmymac' -o -name '*.bash' \) -print0 |
    xargs -0 perl -ne '
      BEGIN { $w = shift @ARGV }
      next if /^\s*#/;
      my $pre  = qr/(?:^|[;&|({!`]|\$\(|\b(?:if|then|do|else|elif|while|until|coproc)\b|\)\s)/;
      my $wrap = qr/\b(?:run|step|try|preview|report|exec|command|builtin|env|xargs|nohup|nice|time|coproc)\b(?:\s+(?:-a\s+\S+|-\S*|\w+=\S*|\d+))*/;
      print "$ARGV:$.: $_" if /(?:$pre|$wrap)\s*\\?["\x27]?(?:[\w.\/-]*\/)?$w["\x27]?(?=\s|$|[;&|)])/;
      close ARGV if eof;
    ' "$word"
}

@test "no eval invoked anywhere in product code" {
  [ -z "$(cmd_position_hits eval)" ]
}

@test "no sudo invoked anywhere in product code (S1)" {
  [ -z "$(cmd_position_hits sudo)" ]
}

@test "the tripwires catch the forms that used to slip past them" {
  local f="$SANDBOX/mutant.sh" form
  while IFS= read -r form; do
    printf '%s\n' "$form" >"$f"
    [ -n "$(cmd_position_hits sudo "$f")" ] || {
      echo "not caught: $form"
      false
    }
  done <<'EOF'
step sudo -n mas upgrade
x=`sudo id`
if true; then :; else sudo id; fi
case x in x) sudo id ;; esac
env FOO=1 sudo id
nice -n 5 sudo id
find . -print0 | xargs -0 sudo rm
run "sudo" id
step /usr/bin/sudo id
( sudo id )
\sudo id
exec -a x sudo id
coproc sudo id
EOF
  printf 'if eval "true"; then :; fi\n' >"$f"
  [ -n "$(cmd_position_hits eval "$f")" ]
  printf 'note "never uses sudo, ever"\n# sudo in a comment\necho "  sudo rm $link"\n' >"$f"
  [ -z "$(cmd_position_hits sudo "$f")" ]
}
