#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# uninstall.sh: sandboxed removal — symlinks (incl. dangling legacy ones),
# app dir, config keep-vs-purge, graceful when nothing is installed.

load helpers/setup

setup() {
  setup_sandbox
  export CMM_PREFIX="$SANDBOX/app"
  export CMM_BIN_DIR="$SANDBOX/bindir"
  INSTALL="$REPO_ROOT/install.sh"
  UNINSTALL="$REPO_ROOT/uninstall.sh"
}
teardown() { teardown_sandbox; }

install_first() {
  "$INSTALL" >/dev/null
  # uninstall.sh searches brew-bin, /usr/local/bin, ~/.local/bin and the
  # `command -v` catch-all; in the sandbox the link lives in CMM_BIN_DIR,
  # so make it reachable via PATH for the catch-all.
  export PATH="$CMM_BIN_DIR:$PATH"
}

@test "removes the app dir and launcher, keeps config and logs by default" {
  install_first
  CMM_CLEANERS_DIR="" "$CMM_BIN_DIR/scrubmac" disable npm >/dev/null
  mkdir -p "$STATE_DIR/logs"
  touch "$STATE_DIR/logs/run-20260101T000000Z-1.log"
  run "$UNINSTALL"
  [ "$status" -eq 0 ]
  [ ! -d "$CMM_PREFIX" ]
  [ ! -e "$CMM_BIN_DIR/scrubmac" ]
  [ -f "$XDG_CONFIG_HOME/scrubmac/disabled" ]
  [ -d "$STATE_DIR/logs" ]
  [[ "$output" == *"Kept your configuration"* ]]
}

@test "--purge also removes the configuration and the state dir" {
  install_first
  CMM_CLEANERS_DIR="" "$CMM_BIN_DIR/scrubmac" disable npm >/dev/null
  mkdir -p "$STATE_DIR/logs"
  run "$UNINSTALL" --purge
  [ "$status" -eq 0 ]
  [ ! -d "$XDG_CONFIG_HOME/scrubmac" ]
  [ ! -d "$STATE_DIR" ]
}

write_plist() { # write_plist PROGRAM
  mkdir -p "$HOME/Library/LaunchAgents"
  cat >"$HOME/Library/LaunchAgents/com.github.aviral2552.scrubmac.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>com.github.aviral2552.scrubmac</string>
  <key>ProgramArguments</key>
  <array>
    <string>$1</string>
    <string>--scheduled</string>
  </array>
</dict>
</plist>
EOF
}

@test "removes a launchd schedule that runs this install" {
  install_first
  make_stub launchctl
  write_plist "$CMM_PREFIX/bin/scrubmac"
  run "$UNINSTALL"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/Library/LaunchAgents/com.github.aviral2552.scrubmac.plist" ]
  grep -q "^launchctl bootout gui/$(id -u)/com.github.aviral2552.scrubmac$" "$CALL_LOG"
}

@test "keeps a launchd schedule that runs a different install (e.g. Homebrew's)" {
  install_first
  make_stub launchctl
  write_plist "/opt/homebrew/opt/scrubmac/bin/scrubmac"
  run "$UNINSTALL"
  [ "$status" -eq 0 ]
  [ -f "$HOME/Library/LaunchAgents/com.github.aviral2552.scrubmac.plist" ]
  [[ "$output" == *"kept the launchd schedule"* ]]
  refute grep -q bootout "$CALL_LOG"
}

@test "removes a dangling legacy 1.x launcher symlink" {
  mkdir -p "$CMM_BIN_DIR" "$CMM_PREFIX"
  ln -s "$CMM_PREFIX/scrubmac.sh" "$CMM_BIN_DIR/scrubmac" # dangling: 1.x target
  export PATH="$CMM_BIN_DIR:$PATH"
  run "$UNINSTALL"
  [ "$status" -eq 0 ]
  [ ! -e "$CMM_BIN_DIR/scrubmac" ] && [ ! -L "$CMM_BIN_DIR/scrubmac" ]
}

@test "is graceful when nothing is installed" {
  run "$UNINSTALL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no launcher symlink found"* ]]
  [[ "$output" == *"nothing to remove"* ]]
}

@test "a foreign scrubmac binary on PATH is left alone" {
  mkdir -p "$CMM_BIN_DIR"
  printf '#!/bin/sh\necho other tool\n' >"$CMM_BIN_DIR/scrubmac" # real file, not ours
  chmod 755 "$CMM_BIN_DIR/scrubmac"
  export PATH="$CMM_BIN_DIR:$PATH"
  run "$UNINSTALL"
  [ "$status" -eq 0 ]
  [ -x "$CMM_BIN_DIR/scrubmac" ]
}

@test "rejects unknown flags" {
  run "$UNINSTALL" --force-everything
  [ "$status" -eq 2 ]
}
