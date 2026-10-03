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
  [[ "$output" == *"Kept your configuration"* ]] || false
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
  [[ "$output" == *"kept the launchd schedule"* ]] || false
  refute grep -q bootout "$CALL_LOG"
}

@test "removes a dangling legacy 1.x launcher symlink" {
  mkdir -p "$CMM_BIN_DIR" "$CMM_PREFIX"
  ln -s "$CMM_PREFIX/scrubmac.sh" "$CMM_BIN_DIR/scrubmac" # dangling: 1.x target
  export PATH="$CMM_BIN_DIR:$PATH"
  run "$UNINSTALL"
  [ "$status" -eq 0 ]
  [ ! -e "$CMM_BIN_DIR/scrubmac" ] && [ ! -L "$CMM_BIN_DIR/scrubmac" ] || false
}

@test "is graceful when nothing is installed" {
  run "$UNINSTALL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no launcher symlink found"* ]] || false
  [[ "$output" == *"nothing to remove"* ]] || false
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

@test "refuses \$HOME, / or a parent of home as the install dir — nothing is deleted" {
  touch "$HOME/keep-me"
  CMM_PREFIX="$HOME" run "$UNINSTALL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"refusing to remove $HOME"* ]] || false
  [ -f "$HOME/keep-me" ]
  CMM_PREFIX="$SANDBOX" run "$UNINSTALL"
  [ "$status" -eq 1 ]
  [ -f "$HOME/keep-me" ]
  CMM_PREFIX=/ run "$UNINSTALL"
  [ "$status" -eq 2 ]
  CMM_PREFIX="$HOME/." run "$UNINSTALL"
  [ "$status" -eq 2 ]
  [ -f "$HOME/keep-me" ]
}

@test "leaves a directory that is not a scrubmac install alone" {
  mkdir -p "$SANDBOX/notmine"
  printf 'precious\n' >"$SANDBOX/notmine/thesis.tex"
  CMM_PREFIX="$SANDBOX/notmine" run "$UNINSTALL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not look like a scrubmac install"* ]] || false
  [ -f "$SANDBOX/notmine/thesis.tex" ]
}

@test "a trailing slash on the install dir still finds and removes it" {
  install_first
  CMM_PREFIX="$CMM_PREFIX/" run "$UNINSTALL"
  [ "$status" -eq 0 ]
  [ ! -e "$CMM_PREFIX" ]
}

@test "a legacy-path symlink that points elsewhere is kept" {
  install_first
  export CMM_OLD_PREFIX="$SANDBOX/oldapp"
  mkdir -p "$SANDBOX/someone-else"
  ln -s "$SANDBOX/someone-else" "$CMM_OLD_PREFIX"
  run "$UNINSTALL"
  [ "$status" -eq 0 ]
  [ -L "$CMM_OLD_PREFIX" ]
  [[ "$output" == *"left $CMM_OLD_PREFIX alone"* ]] || false
}

@test "--purge never deletes a state dir override that is not named scrubmac" {
  install_first
  export CMM_STATE_DIR="$SANDBOX/mystuff"
  mkdir -p "$CMM_STATE_DIR"
  touch "$CMM_STATE_DIR/important"
  run "$UNINSTALL" --purge
  [ "$status" -eq 1 ]
  [ -f "$CMM_STATE_DIR/important" ]
  [[ "$output" == *"not a scrubmac config or state directory"* ]] || false
}

@test "--purge removes only the link when the config dir is a dotfiles symlink" {
  install_first
  mkdir -p "$SANDBOX/dotfiles/scrubmac" "$XDG_CONFIG_HOME"
  printf 'QUIET=1\n' >"$SANDBOX/dotfiles/scrubmac/config"
  ln -s "$SANDBOX/dotfiles/scrubmac" "$XDG_CONFIG_HOME/scrubmac"
  run "$UNINSTALL" --purge
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_CONFIG_HOME/scrubmac" ]
  [ -f "$SANDBOX/dotfiles/scrubmac/config" ]
}

@test "the installed copy uninstalling itself does not suggest re-running it" {
  install_first
  mkdir -p "$XDG_CONFIG_HOME/scrubmac"
  run "$CMM_PREFIX/uninstall.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$CMM_PREFIX" ]
  [[ "$output" == *"remove with: rm -rf"* ]] || false
  [[ "$output" != *"--purge"* ]] || false
}

@test "warns about a crontab line that still runs scrubmac" {
  install_first
  printf '#!/bin/sh\necho "0 9 * * 1 $HOME/.scrubmac/bin/scrubmac -q"\n' >"$STUB_BIN/crontab"
  chmod 755 "$STUB_BIN/crontab"
  run "$UNINSTALL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"your crontab still runs scrubmac"* ]] || false
}

@test "rejects unknown flags" {
  run "$UNINSTALL" --force-everything
  [ "$status" -eq 2 ]
}
