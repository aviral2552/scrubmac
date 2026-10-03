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
  make_stub launchctl
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
  diff <(calls) - <<EOF
launchctl bootout gui/$UID_/com.github.aviral2552.scrubmac
launchctl bootstrap gui/$UID_ $PLIST
EOF
  [[ "$output" == *"scheduled: weekly on Monday at 09:00"* ]]
}

@test "schedule daily HH:MM omits Weekday" {
  run "$CMM" schedule daily 18:30
  [ "$status" -eq 0 ]
  refute grep -q '<key>Weekday</key>' "$PLIST"
  [ "$(plist_value Hour)" = 18 ]
  [ "$(plist_value Minute)" = 30 ]
  [[ "$output" == *"daily at 18:30"* ]]
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
  [[ "$output" == *"could not load"* ]]
}

@test "schedule status: none, loaded, not loaded, launcher gone" {
  run "$CMM" schedule
  [ "$status" -eq 0 ]
  [[ "$output" == *"no schedule set"* ]]
  run "$CMM" schedule weekly
  run "$CMM" schedule status
  [ "$status" -eq 0 ]
  [[ "$output" == *"weekly on Monday at 09:00"* ]]
  [[ "$output" == *"loaded"* ]]
  make_stub launchctl 113 # print: service not found
  run "$CMM" schedule status
  [[ "$output" == *"not loaded"* ]]
  sed -i.bak "s|$REPO_ROOT/bin/scrubmac|/nonexistent/bin/scrubmac|" "$PLIST"
  run "$CMM" schedule status
  [[ "$output" == *"no longer exists"* ]]
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
  [[ "$output" == *"no schedule was set"* ]]
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
  [[ "$output" == *"PATH="* ]]
  [[ "$output" == *"--scheduled --quiet"* ]]
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
  [[ "$output" == *"launchd agent:  daily at 06:00"* ]]
}
