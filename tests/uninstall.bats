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

@test "removes the app dir and launcher, keeps config by default" {
  install_first
  run "$UNINSTALL"
  [ "$status" -eq 0 ]
  [ ! -d "$CMM_PREFIX" ]
  [ ! -e "$CMM_BIN_DIR/scrubmac" ]
  [ -f "$XDG_CONFIG_HOME/scrubmac/disabled" ]
  [[ "$output" == *"Kept your configuration"* ]]
}

@test "--purge also removes the configuration" {
  install_first
  run "$UNINSTALL" --purge
  [ "$status" -eq 0 ]
  [ ! -d "$XDG_CONFIG_HOME/scrubmac" ]
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
