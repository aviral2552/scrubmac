#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# Cron-like environments (env -i: no XDG, PATH=/usr/bin:/bin, no TTY): the
# run still works, its lock is the same one a terminal run takes, a PATH that
# hides every tool is called out, and doctor flags a crontab without PATH.
# TMPDIR is passed through (the sandbox's): without it the transitional 2.x
# lock would land in the host's shared /tmp and collide with real runs. A
# TMPDIR that does not exist is covered in migration.bats.

load helpers/setup

setup() { setup_sandbox; }
teardown() { teardown_sandbox; }

# cron_run ARGS… — run scrubmac the way cron would (plus the fixture dir).
# cron's PATH is /usr/bin:/bin; the sandbox's own utility dir stands in for
# it, so no host tool (python3, git shims, osascript…) is reachable.
cron_run() {
  env -i HOME="$HOME" TMPDIR="$TMPDIR" LOGNAME=tester SHELL=/bin/sh PATH="$SYSBIN" \
    CMM_CLEANERS_DIR="$FIXTURES" CMM_NOTIFY=never CMM_OFFLINE=0 \
    CMM_BREW_LOCATIONS="$CMM_BREW_LOCATIONS" CMM_LINK_DIRS="$CMM_LINK_DIRS" \
    "$CMM" "$@"
}

@test "a cron-like run works without TMPDIR/XDG and warns when every cleaner skipped" {
  make_lib_cleaner 10-brewish.sh 'skip_unless definitely_not_on_cron_path_xyz'
  make_lib_cleaner 20-npmish.sh 'skip_unless another_missing_tool_xyz'
  make_lib_cleaner 30-uvish.sh 'skip_unless third_missing_tool_xyz'
  run cron_run --scheduled --quiet
  [ "$status" -eq 0 ]
  [[ "$output" == *"every cleaner skipped"* ]] || false
  [[ "$output" == *"cron's default PATH is /usr/bin:/bin"* ]] || false
  [ -f "$HOME/.local/state/scrubmac/last-run.json" ]
  ls "$HOME"/.local/state/scrubmac/logs/run-*.log >/dev/null
  [ ! -L "$HOME/.local/state/scrubmac/run.lock" ] # released
}

@test "cron and terminal runs exclude each other (regression: the lock lived in TMPDIR)" {
  make_cleaner 10-slow.sh 'echo SLOW-START' 'sleep 30'
  # a "terminal" run, with a per-user TMPDIR like macOS sets for login sessions
  TMPDIR="$SANDBOX/terminal-tmp" bash -c 'mkdir -p "$TMPDIR" && exec "$CMM_BG"' >"$SANDBOX/term.out" 2>&1 3>&- &
  local pid=$! i=0
  while ! grep -q SLOW-START "$SANDBOX/term.out" 2>/dev/null; do
    i=$((i + 1))
    [ "$i" -lt 100 ] || break
    sleep 0.1
  done
  run cron_run
  [ "$status" -eq 2 ]
  [[ "$output" == *"already in progress (pid $pid)"* ]] || false
  kill -TERM "$pid" 2>/dev/null || true
  wait "$pid" 2>/dev/null || true
}

@test "doctor flags a crontab that runs scrubmac without a PATH line" {
  make_stub_script crontab <<'EOF'
printf '# m h dom mon dow command\n0 9 * * 1 $HOME/.scrubmac/bin/scrubmac -q\n'
EOF
  run "$CMM" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"your crontab sets no PATH"* ]] || false
}

@test "doctor flags a crontab PATH without Homebrew's bin, and is quiet when it has it" {
  make_stub_script crontab <<'EOF'
printf 'PATH=/usr/bin:/bin\n0 9 * * 1 scrubmac --scheduled\n'
EOF
  CMM_BREW_PREFIX=/opt/homebrew run "$CMM" doctor
  [[ "$output" == *"crontab's PATH lacks /opt/homebrew/bin"* ]] || false
  make_stub_script crontab <<'EOF'
printf 'PATH=/opt/homebrew/bin:/usr/bin:/bin\n0 9 * * 1 scrubmac --scheduled\n'
EOF
  CMM_BREW_PREFIX=/opt/homebrew run "$CMM" doctor
  [[ "$output" != *"crontab's PATH lacks"* ]] || false
  [[ "$output" != *"sets no PATH"* ]] || false
}

@test "doctor reminds about a crontab that still calls cleanmymac" {
  make_stub_script crontab <<'EOF'
printf 'PATH=/opt/homebrew/bin:/usr/bin:/bin\n0 9 * * 1 cleanmymac -q\n'
EOF
  run "$CMM" doctor
  [[ "$output" == *"still references 'cleanmymac'"* ]] || false
}

@test "a cron-like run never prompts, even with no config" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  run cron_run
  [ "$status" -eq 0 ]
  [[ "$output" == *"using defaults"* ]] || false
  [[ "$output" == *ALPHA-RAN* ]] || false
  [ ! -f "$HOME/.config/scrubmac/config" ] # nothing written behind your back
}
