#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# `scrubmac doctor` (S6): what it reports and what it flags — settings that
# really differ from their defaults, crontab entries without a usable PATH,
# double scheduling, refused cleaners and why, unwritable dirs, relative
# PATH entries, dangling launcher links, the run lock and the network probe.
# Doctor is read-only and exits 0 even when it warns.

load helpers/setup

setup() { setup_sandbox; }
teardown() { teardown_sandbox; }

crontab_with() { # crontab_with LINE… — a crontab stub listing these lines
  {
    printf '#!/bin/sh\n'
    printf "printf '%%s\\\\n' "
    printf "'%s' " "$@"
    printf '\n'
  } >"$STUB_BIN/crontab"
  chmod 755 "$STUB_BIN/crontab"
}

@test "a setting spelled out in the config but equal to its default is not 'changed'" {
  mkdir -p "$XDG_CONFIG_HOME/scrubmac"
  printf 'COOLDOWN_DAYS=7\nAPP_UPDATES=interactive\nTIMEOUT=600\n' >"$XDG_CONFIG_HOME/scrubmac/config"
  run "$CMM" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"TIMEOUT                  600          (config)"* ]] || false
  [[ "$output" != *"COOLDOWN_DAYS            7"* ]] || false
  [[ "$output" != *"APP_UPDATES              interactive"* ]] || false
}

@test "crontab: an inline PATH=… on the entry counts, and the grammar is right" {
  crontab_with '0 9 * * 1 PATH=/opt/homebrew/bin:/usr/bin:/bin scrubmac --scheduled'
  CMM_BREW_PREFIX=/opt/homebrew run "$CMM" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"crontab:        1 entry runs scrubmac"* ]] || false
  [[ "$output" != *"sets no PATH"* ]] || false
  [[ "$output" != *"lacks /opt/homebrew/bin"* ]] || false
}

@test "crontab: a quoted PATH line is understood; a second entry pluralizes" {
  crontab_with 'PATH = "/opt/homebrew/bin:/usr/bin:/bin"' '0 9 * * 1 scrubmac -q' '0 18 * * 5 scrubmac -q'
  CMM_BREW_PREFIX=/opt/homebrew run "$CMM" doctor
  [[ "$output" == *"crontab:        2 entries run scrubmac"* ]] || false
  [[ "$output" != *"sets no PATH"* ]] || false
  [[ "$output" != *"lacks /opt/homebrew/bin"* ]] || false
}

@test "crontab: an entry run through a login shell gets your profile's PATH" {
  crontab_with "0 9 * * 1 /bin/zsh -lc 'scrubmac --scheduled'"
  run "$CMM" doctor
  [[ "$output" == *"1 entry runs scrubmac"* ]] || false
  [[ "$output" != *"sets no PATH"* ]] || false
}

@test "crontab plus a launchd agent is flagged as scheduling twice" {
  crontab_with 'PATH=/usr/bin:/bin' '0 9 * * 1 scrubmac -q'
  mkdir -p "$HOME/Library/LaunchAgents"
  printf '<plist><dict><key>ProgramArguments</key><array><string>/x/scrubmac</string></array></dict></plist>\n' \
    >"$HOME/Library/LaunchAgents/com.github.aviral2552.scrubmac.plist"
  run "$CMM" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"scheduled twice"* ]] || false
}

@test "a refused cleaner is reported with the reason it would be refused" {
  make_cleaner 10-alpha.sh 'echo hi'
  chmod 775 "$FIXTURES/10-alpha.sh"
  run "$CMM" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"unsafe cleaner (would be refused):"*"not group/world-writable"* ]] || false
  [[ "$output" == *"1 refused"* ]] || false
}

@test "a non-executable file in cleaners.d is called out with the fix" {
  mkdir -p "$XDG_CONFIG_HOME/scrubmac/cleaners.d"
  printf '#!/usr/bin/env bash\necho mine\n' >"$XDG_CONFIG_HOME/scrubmac/cleaners.d/50-mine.sh"
  run "$CMM" doctor
  [[ "$output" == *"not executable, so ignored: $XDG_CONFIG_HOME/scrubmac/cleaners.d/50-mine.sh — chmod +x"* ]] || false
}

@test "an unwritable state dir is flagged" {
  mkdir -p "$STATE_DIR"
  chmod 500 "$STATE_DIR"
  run "$CMM" doctor
  chmod 700 "$STATE_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"the state dir is not writable: $STATE_DIR"* ]] || false
}

@test "relative PATH entries are flagged like '.'" {
  PATH="$STUB_BIN:node_modules/.bin:$SYSBIN" run "$CMM" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"PATH has a relative entry 'node_modules/.bin'"* ]] || false
}

@test "a dangling launcher link where installers put them is found" {
  mkdir -p "$HOME/.local/bin"
  ln -s "$SANDBOX/gone/bin/scrubmac" "$HOME/.local/bin/scrubmac"
  run "$CMM" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"dangling scrubmac symlink: $HOME/.local/bin/scrubmac"* ]] || false
}

@test "a live run's lock is shown as held, a dead one's as stale" {
  start_holder scrubmac
  hold_lock "$HOLDER_PID"
  run "$CMM" doctor
  [[ "$output" == *"run lock:       held by pid $HOLDER_PID"* ]] || false
  rm -f "$LOCK"
  hold_lock "$(dead_pid)"
  run "$CMM" doctor
  [[ "$output" == *"run lock:       stale"* ]] || false
}

@test "network: a forced value is reported as such; without a probe tool the state is 'unknown'" {
  run "$CMM" doctor
  [[ "$output" == *"network:        set by CMM_OFFLINE=0 (not probed)"* ]] || false
  unset CMM_OFFLINE
  CMM_OS=Darwin run "$CMM" doctor # the sandbox PATH has no route(8)
  [[ "$output" == *"network:        unknown"* ]] || false
}

@test "a leftover 2.x install dir is flagged; the compat link is just noted" {
  mkdir -p "$HOME/.cleanmymac"
  run "$CMM" doctor
  [[ "$output" == *"an old cleanmymac 2.x install is still at ~/.cleanmymac"* ]] || false
  rmdir "$HOME/.cleanmymac"
  ln -s "$HOME/.scrubmac" "$HOME/.cleanmymac"
  run "$CMM" doctor
  [[ "$output" == *"~/.cleanmymac is a compat link"* ]] || false
}
