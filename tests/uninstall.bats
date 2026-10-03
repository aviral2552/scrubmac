#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# uninstall.sh: sandboxed removal — symlinks (incl. dangling legacy ones),
# app dir, config keep-vs-purge, graceful when nothing is installed.

load helpers/setup

setup_file() { build_src_cache; }

setup() {
  setup_sandbox
  export CMM_PREFIX="$SANDBOX/app"
  export CMM_BIN_DIR="$SANDBOX/bindir"
  INSTALL="$(make_src_tree)/install.sh"
  UNINSTALL="$SANDBOX/src/uninstall.sh"
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

@test "a wrong CMM_PREFIX is refused before anything is touched (the real install keeps its launcher and schedule)" {
  install_first
  mkdir -p "$HOME/Library/LaunchAgents"
  printf '<plist><dict><key>ProgramArguments</key><array><string>%s/bin/scrubmac</string></array></dict></plist>\n' "$CMM_PREFIX" \
    >"$HOME/Library/LaunchAgents/com.github.aviral2552.scrubmac.plist"
  CMM_PREFIX="$HOME" run "$UNINSTALL"
  [ "$status" -eq 1 ]
  [ -L "$CMM_BIN_DIR/scrubmac" ]
  [ -f "$HOME/Library/LaunchAgents/com.github.aviral2552.scrubmac.plist" ]
  mkdir -p "$SANDBOX/notmine"
  touch "$SANDBOX/notmine/file"
  CMM_PREFIX="$SANDBOX/notmine" run "$UNINSTALL"
  [ "$status" -eq 1 ]
  [ -L "$CMM_BIN_DIR/scrubmac" ]
}

@test "a wrong CMM_PREFIX inside the real install is refused before its launcher or schedule is touched" {
  install_first
  make_stub launchctl
  write_plist "$CMM_PREFIX/bin/scrubmac"
  CMM_PREFIX="$CMM_PREFIX/bin" run "$UNINSTALL"
  [ "$status" -eq 1 ]
  [[ "$output" == *"does not look like a scrubmac install (nothing was removed)"* ]] || false
  [ -L "$CMM_BIN_DIR/scrubmac" ]
  [ -f "$HOME/Library/LaunchAgents/com.github.aviral2552.scrubmac.plist" ]
  refute grep -q bootout "$CALL_LOG"
  [ -x "$CMM_PREFIX/bin/scrubmac" ]
}

@test "--purge with a mistyped CMM_PREFIX removes nothing — not even the configuration" {
  install_first
  CMM_CLEANERS_DIR="" "$CMM_BIN_DIR/scrubmac" disable npm >/dev/null
  CMM_PREFIX="$CMM_PREFIX-typo" run "$UNINSTALL" --purge
  [ "$status" -eq 1 ]
  [[ "$output" == *"nothing at $CMM_PREFIX-typo — check CMM_PREFIX"* ]] || false
  [ -f "$XDG_CONFIG_HOME/scrubmac/disabled" ]
  [ -x "$CMM_PREFIX/bin/scrubmac" ]
  [ -L "$CMM_BIN_DIR/scrubmac" ]
}

@test "nothing installed at all: says so (and still exits 0)" {
  run "$UNINSTALL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing to uninstall"* ]] || false
  [[ "$output" != *"has been uninstalled"* ]] || false
}

@test "an install path linked to another copy that is not an install: only the link goes" {
  mkdir -p "$SANDBOX/other/bin" "$CMM_BIN_DIR"
  printf '#!/bin/sh\necho other\n' >"$SANDBOX/other/bin/scrubmac"
  chmod 755 "$SANDBOX/other/bin/scrubmac"
  ln -s "$SANDBOX/other/bin/scrubmac" "$CMM_BIN_DIR/scrubmac"
  ln -s "$SANDBOX/other" "$CMM_PREFIX"
  make_stub launchctl
  write_plist "$SANDBOX/other/bin/scrubmac"
  run "$UNINSTALL"
  [[ "$output" == *"which is not a scrubmac install — only the link will be removed"* ]] || false
  [ ! -L "$CMM_PREFIX" ]
  [ -x "$SANDBOX/other/bin/scrubmac" ]
  [ -L "$CMM_BIN_DIR/scrubmac" ]
  [ -f "$HOME/Library/LaunchAgents/com.github.aviral2552.scrubmac.plist" ]
  refute grep -q bootout "$CALL_LOG"
}

@test "--purge never deletes your home, even when it is the state dir and named scrubmac" {
  install_first
  export HOME="$SANDBOX/scrubmac"
  mkdir -p "$HOME"
  touch "$HOME/precious"
  export CMM_STATE_DIR="$HOME"
  run "$UNINSTALL" --purge
  [ "$status" -eq 1 ]
  [ -f "$HOME/precious" ]
  [[ "$output" == *"not a scrubmac config or state directory"* ]] || false
}

@test "a schedule saved as a binary plist is still recognized as this install's, and removed" {
  command -v plutil >/dev/null || skip "plutil (macOS) converts the plist"
  install_first
  make_stub launchctl
  write_plist "$CMM_PREFIX/bin/scrubmac"
  plutil -convert binary1 "$HOME/Library/LaunchAgents/com.github.aviral2552.scrubmac.plist"
  run "$UNINSTALL"
  [ "$status" -eq 0 ]
  [ ! -e "$HOME/Library/LaunchAgents/com.github.aviral2552.scrubmac.plist" ]
  grep -q "^launchctl bootout gui/$(id -u)/com.github.aviral2552.scrubmac$" "$CALL_LOG"
}

@test "a schedule whose program cannot be read is kept, with a note on removing it" {
  install_first
  make_stub launchctl
  mkdir -p "$HOME/Library/LaunchAgents"
  printf 'not a plist\n' >"$HOME/Library/LaunchAgents/com.github.aviral2552.scrubmac.plist"
  run "$UNINSTALL"
  [ -f "$HOME/Library/LaunchAgents/com.github.aviral2552.scrubmac.plist" ]
  [[ "$output" == *"could not tell which program it runs"* ]] || false
}

@test "a symlinked install path: launcher, schedule and link go; the target goes unless it is a git checkout" {
  local real="$SANDBOX/vol/scrubmac"
  mkdir -p "$real"
  ln -s "$real" "$CMM_PREFIX"
  install_first # install.sh follows the link and installs into $real
  [ -x "$real/bin/scrubmac" ]
  mkdir -p "$HOME/Library/LaunchAgents"
  printf '<plist><dict><key>ProgramArguments</key><array><string>%s/bin/scrubmac</string></array></dict></plist>\n' "$real" \
    >"$HOME/Library/LaunchAgents/com.github.aviral2552.scrubmac.plist"
  run "$UNINSTALL"
  [ "$status" -eq 0 ]
  [ ! -L "$CMM_PREFIX" ]
  [ ! -e "$real" ]
  [ ! -e "$CMM_BIN_DIR/scrubmac" ]
  [ ! -f "$HOME/Library/LaunchAgents/com.github.aviral2552.scrubmac.plist" ]
  # a link to a dev clone: the clone is kept
  mkdir -p "$real"
  rsync -a "$SANDBOX/src/" "$real/" # a clone, .git included
  ln -s "$real" "$CMM_PREFIX"
  run "$UNINSTALL"
  [ "$status" -eq 1 ]
  [ ! -L "$CMM_PREFIX" ]
  [ -d "$real/.git" ]
  [[ "$output" == *"install.sh did not create it"* ]] || false
}

@test "a legacy dir that is not a cleanmymac install is not ours: left alone, and links into it are kept" {
  install_first
  export CMM_OLD_PREFIX="$SANDBOX/oldthing"
  mkdir -p "$CMM_OLD_PREFIX/bin"
  printf '#!/bin/sh\n' >"$CMM_OLD_PREFIX/bin/cleanmymac"
  chmod 755 "$CMM_OLD_PREFIX/bin/cleanmymac"
  ln -s "$CMM_OLD_PREFIX/bin/cleanmymac" "$CMM_BIN_DIR/cleanmymac"
  run "$UNINSTALL"
  [ "$status" -eq 0 ]
  [ -d "$CMM_OLD_PREFIX" ]
  [ -L "$CMM_BIN_DIR/cleanmymac" ]
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
