#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# `scrubmac schedule`: the launchd agent it writes (validated against
# launchd.plist(5)), how it loads/unloads it with launchctl(1), PATH capture
# and sanitizing (S6), XML escaping, status, and the no-launchd fallback.
# launchctl is stubbed; the live E2E workflow loads a real agent on macOS.

load helpers/setup

setup() {
  setup_sandbox
  PLIST="$HOME/Library/LaunchAgents/com.github.aviral2552.scrubmac.plist"
  UID_="$(id -u)"
  launchd_stub
}

# launchd_stub — a logging launchctl that models the agent's state: bootstrap
# loads it, bootout unloads it, print answers 113 ("not found") when unloaded.
launchd_stub() {
  make_stub_script launchctl <<EOF
case "\$1" in
  bootstrap) : >"$SANDBOX/loaded" ;;
  bootout) rm -f "$SANDBOX/loaded" ;;
  print) [ -e "$SANDBOX/loaded" ] || exit 113 ;;
esac
exit 0
EOF
}
teardown() { teardown_sandbox; }

plist_value() { # plist_value KEY — the value line after <key>KEY</key>
  awk -v k="<key>$1</key>" 'index($0, k) { f = 1; next } f { gsub(/^[ \t]*<[a-z]+>|<\/[a-z]+>[ \t]*$/, ""); print; exit }' "$PLIST"
}

@test "schedule weekly writes a Monday 09:00 agent and loads it into the GUI domain" {
  run "$CMM" schedule weekly
  [ "$status" -eq 0 ]
  [ -f "$PLIST" ]
  [ "$(plist_value Label)" = com.github.aviral2552.scrubmac ]
  [ "$(plist_value Weekday)" = 1 ]
  [ "$(plist_value Hour)" = 9 ]
  [ "$(plist_value Minute)" = 0 ]
  grep -q "<string>$REPO_ROOT/bin/scrubmac</string>" "$PLIST"
  grep -q '<string>--scheduled</string>' "$PLIST"
  grep -q '<string>--quiet</string>' "$PLIST"
  grep -q '<key>RunAtLoad</key>' "$PLIST"
  diff "$CALL_LOG" - <<EOF
launchctl bootout gui/$UID_/com.github.aviral2552.scrubmac
launchctl print gui/$UID_/com.github.aviral2552.scrubmac
launchctl enable gui/$UID_/com.github.aviral2552.scrubmac
launchctl bootstrap gui/$UID_ $PLIST
EOF
  [[ "$output" == *"scheduled: weekly on Monday at 09:00"* ]] || false
}

@test "re-scheduling waits for the old agent to unload, and retries a transient bootstrap failure" {
  make_stub_script launchctl <<EOF
case "\$1" in
  print)
    n=\$(cat "$SANDBOX/prints" 2>/dev/null || echo 0); echo \$((n + 1)) >"$SANDBOX/prints"
    [ "\$n" -lt 2 ] || exit 113 ;; # still unloading for two polls
  bootstrap)
    [ -e "$SANDBOX/tried" ] || { : >"$SANDBOX/tried"; echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; } ;;
esac
exit 0
EOF
  run "$CMM" schedule weekly
  [ "$status" -eq 0 ]
  [ "$(grep -c '^launchctl print ' "$CALL_LOG")" -eq 3 ]
  [ "$(grep -c '^launchctl bootstrap ' "$CALL_LOG")" -eq 2 ]
  [[ "$output" == *"scheduled: weekly on Monday at 09:00"* ]] || false
}

@test "schedule daily HH:MM omits Weekday" {
  run "$CMM" schedule daily 18:30
  [ "$status" -eq 0 ]
  refute grep -q '<key>Weekday</key>' "$PLIST"
  [ "$(plist_value Hour)" = 18 ]
  [ "$(plist_value Minute)" = 30 ]
  [[ "$output" == *"daily at 18:30"* ]] || false
}

@test "schedule weekly accepts a day and a time in any order" {
  run "$CMM" schedule weekly 07:05 fri
  [ "$status" -eq 0 ]
  [ "$(plist_value Weekday)" = 5 ]
  [ "$(plist_value Hour)" = 7 ]
  [ "$(plist_value Minute)" = 5 ]
  run "$CMM" schedule weekly Sunday
  [ "$(plist_value Weekday)" = 0 ]
}

@test "schedule rejects bad days, times and subcommands" {
  run "$CMM" schedule weekly funday
  [ "$status" -eq 2 ]
  run "$CMM" schedule weekly 5 # numbers are ambiguous (is 0 Sunday?)
  [ "$status" -eq 2 ]
  run "$CMM" schedule weekly mon fri
  [ "$status" -eq 2 ]
  [[ "$output" == *"two days given"* ]] || false
  run "$CMM" schedule daily 09:00 10:00
  [ "$status" -eq 2 ]
  [[ "$output" == *"two times given"* ]] || false
  run "$CMM" schedule daily mon
  [ "$status" -eq 2 ]
  run "$CMM" schedule off now
  [ "$status" -eq 2 ]
  run "$CMM" schedule status please
  [ "$status" -eq 2 ]
  run "$CMM" schedule daily 25:00
  [ "$status" -eq 2 ]
  run "$CMM" schedule daily 9:7
  [ "$status" -eq 2 ]
  run "$CMM" schedule hourly
  [ "$status" -eq 2 ]
  [ ! -f "$PLIST" ]
}

@test "the agent carries the current PATH minus '.', empty and relative entries (S6)" {
  PATH="$STUB_BIN::.:relative/bin:/usr/bin:/bin:/usr/bin" run "$CMM" schedule weekly
  [ "$status" -eq 0 ]
  [ "$(plist_value PATH)" = "$STUB_BIN:/usr/bin:/bin" ]
}

@test "XDG and state-dir overrides travel with the agent; values are XML-escaped" {
  mkdir -p "$SANDBOX/a&b<c>"
  XDG_STATE_HOME="$SANDBOX/a&b<c>" run "$CMM" schedule weekly
  [ "$status" -eq 0 ]
  grep -q '<key>XDG_CONFIG_HOME</key>' "$PLIST"
  grep -q '<key>XDG_STATE_HOME</key>' "$PLIST"
  grep -q 'a&amp;b&lt;c&gt;' "$PLIST"
  refute grep -q 'a&b<c>' "$PLIST"
}

@test "the generated plist is valid (plutil -lint, macOS only)" {
  [ -x /usr/bin/plutil ] || skip "plutil is macOS-only"
  run "$CMM" schedule weekly
  [ "$status" -eq 0 ]
  /usr/bin/plutil -lint "$PLIST"
}

@test "a launchctl bootstrap failure is reported with a hint (exit 1)" {
  make_stub_script launchctl <<'EOF'
[ "$1" = bootstrap ] && { echo "Bootstrap failed: 5: Input/output error" >&2; exit 5; }
exit 0
EOF
  run "$CMM" schedule weekly
  [ "$status" -eq 1 ]
  [[ "$output" == *"could not load"* ]] || false
}

@test "schedule status: none, loaded, not loaded, launcher gone" {
  run "$CMM" schedule
  [ "$status" -eq 0 ]
  [[ "$output" == *"no schedule set"* ]] || false
  run "$CMM" schedule weekly
  run "$CMM" schedule status
  [ "$status" -eq 0 ]
  [[ "$output" == *"weekly on Monday at 09:00"* ]] || false
  [[ "$output" == *"state:    loaded"* ]] || false
  rm -f "$SANDBOX/loaded" # launchd lost it (e.g. after a manual bootout)
  run "$CMM" schedule status
  [[ "$output" == *"not loaded"* ]] || false
  [[ "$output" != *"state:    loaded"* ]] || false
  sed -i.bak "s|$REPO_ROOT/bin/scrubmac|/nonexistent/bin/scrubmac|" "$PLIST"
  run "$CMM" schedule status
  [[ "$output" == *"no longer exists"* ]] || false
}

@test "repair hints recreate the exact schedule (day and time), not a default one" {
  run "$CMM" schedule weekly fri 18:30
  [ "$status" -eq 0 ]
  rm -f "$SANDBOX/loaded"
  run "$CMM" schedule status
  [[ "$output" == *"reload it with: scrubmac schedule weekly fri 18:30"* ]] || false
  run "$CMM" schedule daily 07:05
  rm -f "$SANDBOX/loaded"
  run "$CMM" schedule status
  [[ "$output" == *"reload it with: scrubmac schedule daily 07:05"* ]] || false
}

@test "a schedule saved as a binary plist reads back the same (status and repair hint)" {
  command -v plutil >/dev/null || skip "plutil (macOS) converts the plist"
  run "$CMM" schedule weekly fri 18:30
  [ "$status" -eq 0 ]
  plutil -convert binary1 "$PLIST"
  run "$CMM" schedule status
  [ "$status" -eq 0 ]
  [[ "$output" == *"weekly on Friday at 18:30"* ]] || false
  rm -f "$SANDBOX/loaded" # unloaded: status offers the command that recreates it
  run "$CMM" schedule status
  [[ "$output" == *"scrubmac schedule weekly fri 18:30"* ]] || false
}

@test "schedule off unloads and removes the agent; idempotent" {
  run "$CMM" schedule weekly
  : >"$CALL_LOG"
  run "$CMM" schedule off
  [ "$status" -eq 0 ]
  [ ! -f "$PLIST" ]
  grep -q "^launchctl bootout gui/$UID_/com.github.aviral2552.scrubmac$" "$CALL_LOG"
  run "$CMM" schedule off
  [ "$status" -eq 0 ]
  [[ "$output" == *"no schedule was set"* ]] || false
}

@test "without launchd, schedule explains the cron alternative with an explicit PATH" {
  # Never reach a real launchctl: on macOS this test must not run at all
  # (it would load a real agent into the user's GUI session).
  if [ -e /bin/launchctl ] || [ -e /usr/bin/launchctl ] || [ -e /sbin/launchctl ]; then
    skip "this system has launchd"
  fi
  rm -f "$STUB_BIN/launchctl"
  run "$CMM" schedule weekly
  [ "$status" -eq 2 ]
  [[ "$output" == *"PATH="* ]] || false
  [[ "$output" == *"--scheduled --quiet"* ]] || false
  [ ! -f "$PLIST" ]
}

@test "a Homebrew install schedules the stable opt/ launcher, not the versioned Cellar path" {
  local pfx="$SANDBOX/brewpfx" keg
  keg="$pfx/Cellar/scrubmac/9.9.9"
  mkdir -p "$keg/libexec" "$keg/bin" "$pfx/opt"
  cp -R "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/VERSION" "$keg/libexec/"
  mkdir -p "$keg/libexec/cleaners"
  ln -s ../libexec/bin/scrubmac "$keg/bin/scrubmac"
  ln -s ../Cellar/scrubmac/9.9.9 "$pfx/opt/scrubmac"
  printf '#!/bin/sh\n[ "$1" = --prefix ] && echo "%s"\nexit 0\n' "$pfx" >"$STUB_BIN/brew"
  chmod 755 "$STUB_BIN/brew"
  unset CMM_BREW_PREFIX
  run "$keg/bin/scrubmac" schedule weekly
  [ "$status" -eq 0 ]
  grep -q "<string>$pfx/opt/scrubmac/bin/scrubmac</string>" "$PLIST"
}

@test "doctor reports the schedule" {
  run "$CMM" schedule daily 06:00
  run "$CMM" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"launchd agent:  daily at 06:00"* ]] || false
}
