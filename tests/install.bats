#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# install.sh: sandboxed installs — layout, symlink, idempotence, legacy
# purge via --delete, .git preservation, seeded defaults, no sudo ever.

load helpers/setup

setup() {
  setup_sandbox
  export CMM_PREFIX="$SANDBOX/app"
  export CMM_BIN_DIR="$SANDBOX/bindir"
  INSTALL="$REPO_ROOT/install.sh"
}
teardown() { teardown_sandbox; }

@test "installs the full layout and links the launcher" {
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -x "$CMM_PREFIX/bin/scrubmac" ]
  [ -f "$CMM_PREFIX/lib/common.sh" ]
  [ -f "$CMM_PREFIX/lib/wizard.sh" ]
  [ -x "$CMM_PREFIX/cleaners/10-homebrew.sh" ]
  [ -L "$CMM_BIN_DIR/scrubmac" ]
  [ "$(readlink "$CMM_BIN_DIR/scrubmac")" = "$CMM_PREFIX/bin/scrubmac" ]
}

@test "the linked launcher actually runs from the installed copy" {
  run "$INSTALL"
  run "$CMM_BIN_DIR/scrubmac" version
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(cat "$REPO_ROOT/VERSION")"* ]]
}

@test "re-running the installer is idempotent" {
  run "$INSTALL"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -x "$CMM_PREFIX/bin/scrubmac" ]
  [ -L "$CMM_BIN_DIR/scrubmac" ]
}

@test "legacy 1.x layout is purged by the mirror copy (F10)" {
  mkdir -p "$CMM_PREFIX/cleaners" "$CMM_PREFIX/setup"
  printf 'old\n' >"$CMM_PREFIX/scrubmac.sh"
  printf '%s\n' "$CMM_PREFIX" >"$CMM_PREFIX/path"
  printf 'old\n' >"$CMM_PREFIX/cleaners/02_homebrew.sh"
  printf 'old\n' >"$CMM_PREFIX/setup/install.sh"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ ! -e "$CMM_PREFIX/scrubmac.sh" ]
  [ ! -e "$CMM_PREFIX/path" ]
  [ ! -e "$CMM_PREFIX/cleaners/02_homebrew.sh" ]
  [ ! -e "$CMM_PREFIX/setup" ]
}

@test "the .git metadata is preserved so 'scrubmac update' can work (F2)" {
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -e "$CMM_PREFIX/.git" ]
}

@test "seeds no cleaner state; names the opt-in cleaners instead" {
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_CONFIG_HOME/scrubmac/disabled" ]
  [ ! -e "$XDG_CONFIG_HOME/scrubmac/enabled" ]
  [[ "$output" == *"Opt-in cleaners (off until you enable them):"*docker*xcode* ]]
  # existing choices are never touched
  mkdir -p "$XDG_CONFIG_HOME/scrubmac"
  printf 'npm\n' >"$XDG_CONFIG_HOME/scrubmac/disabled"
  run "$INSTALL"
  diff "$XDG_CONFIG_HOME/scrubmac/disabled" - <<'EOF'
npm
EOF
}

@test "refuses to mirror into a directory that holds anything but scrubmac" {
  mkdir -p "$CMM_PREFIX"
  printf 'precious\n' >"$CMM_PREFIX/thesis.tex"
  run "$INSTALL"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a scrubmac install"* ]]
  [ -f "$CMM_PREFIX/thesis.tex" ]
}

@test "refuses \$HOME or / as the install dir" {
  CMM_PREFIX="$HOME" run "$INSTALL"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to install into"* ]]
  CMM_PREFIX=/ run "$INSTALL"
  [ "$status" -eq 2 ]
}

@test "refuses when the source tree sits inside the install dir (the mirror would delete it)" {
  mkdir -p "$CMM_PREFIX/bin"
  touch "$CMM_PREFIX/bin/scrubmac"
  rsync -a --exclude=.git "$REPO_ROOT/" "$CMM_PREFIX/src/"
  run "$CMM_PREFIX/src/install.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"inside the install dir"* ]]
  [ -x "$CMM_PREFIX/src/install.sh" ]
}

@test "leaves a launcher that is not ours alone (e.g. Homebrew's scrubmac)" {
  mkdir -p "$CMM_BIN_DIR" "$SANDBOX/Cellar/scrubmac/9/bin"
  printf '#!/bin/sh\necho brew-scrubmac\n' >"$SANDBOX/Cellar/scrubmac/9/bin/scrubmac"
  chmod 755 "$SANDBOX/Cellar/scrubmac/9/bin/scrubmac"
  ln -s "$SANDBOX/Cellar/scrubmac/9/bin/scrubmac" "$CMM_BIN_DIR/scrubmac"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not from this installer"* ]]
  [ "$(readlink "$CMM_BIN_DIR/scrubmac")" = "$SANDBOX/Cellar/scrubmac/9/bin/scrubmac" ]
}

@test "replaces its own (even dangling) launcher link" {
  mkdir -p "$CMM_BIN_DIR"
  ln -s "$CMM_PREFIX/bin/old-name" "$CMM_BIN_DIR/scrubmac" # dangling, but ours
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ "$(readlink "$CMM_BIN_DIR/scrubmac")" = "$CMM_PREFIX/bin/scrubmac" ]
}

@test "links the man page and shell completions into a writable brew prefix" {
  local pfx="$SANDBOX/brewpfx"
  mkdir -p "$pfx/bin" "$pfx/share/man/man1" "$pfx/share/zsh/site-functions" \
    "$pfx/etc/bash_completion.d" "$pfx/share/fish/vendor_completions.d"
  printf '#!/bin/sh\n[ "$1" = --prefix ] && echo "%s"\nexit 0\n' "$pfx" >"$STUB_BIN/brew"
  chmod 755 "$STUB_BIN/brew"
  printf 'foreign\n' >"$pfx/share/fish/vendor_completions.d/scrubmac.fish" # not ours: kept
  unset CMM_BIN_DIR
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ "$(readlink "$pfx/bin/scrubmac")" = "$CMM_PREFIX/bin/scrubmac" ]
  [ "$(readlink "$pfx/share/man/man1/scrubmac.1")" = "$CMM_PREFIX/man/scrubmac.1" ]
  [ "$(readlink "$pfx/share/zsh/site-functions/_scrubmac")" = "$CMM_PREFIX/completions/_scrubmac" ]
  [ "$(readlink "$pfx/etc/bash_completion.d/scrubmac")" = "$CMM_PREFIX/completions/scrubmac.bash" ]
  [ ! -L "$pfx/share/fish/vendor_completions.d/scrubmac.fish" ]
  grep -qx foreign "$pfx/share/fish/vendor_completions.d/scrubmac.fish"
}

@test "a sandboxed install never writes outside its sandbox (man-link leak regression)" {
  # The man page links into brew's manpath ONLY when the launcher itself went
  # into brew's bin; with CMM_BIN_DIR overridden, nothing may touch the real
  # brew tree.
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [[ "$output" != *"Linked man page"* ]]
}

@test "never invokes sudo, even when no bin dir is writable (S1)" {
  make_stub sudo 99 "SUDO-WAS-CALLED"
  export CMM_BIN_DIR="/nonexistent-root-owned/bin"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no writable bin directory"* ]]
  refute grep -q sudo "$CALL_LOG"
}

@test "refuses to run from a directory that is not a scrubmac source tree" {
  local fake="$SANDBOX/fake"
  mkdir -p "$fake"
  cp "$INSTALL" "$fake/install.sh"
  chmod 755 "$fake/install.sh"
  run "$fake/install.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not look like a scrubmac source tree"* ]]
}

@test "installer never self-destructs its source directory (F3)" {
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -d "$REPO_ROOT" ]
  [ -x "$REPO_ROOT/install.sh" ]
  refute grep -q 'rm -rf.*SRC_DIR' "$REPO_ROOT/install.sh"
  refute grep -Eq 'trap.*rm' "$REPO_ROOT/install.sh"
}

@test "choose_bin_dir walks candidates in order, then falls back to ~/.local/bin" {
  # extract the pure function and probe its ordering with sandbox dirs
  local fn brewbin="$SANDBOX/brew/bin" usrlocal="$SANDBOX/usrlocal/bin"
  fn="$(sed -n '/^choose_bin_dir()/,/^}$/p' "$INSTALL")"
  mkdir -p "$brewbin" "$usrlocal"
  unset CMM_BIN_DIR
  run bash -c "$fn; choose_bin_dir '$brewbin' '$usrlocal'"
  [ "$output" = "$brewbin" ]
  chmod 555 "$brewbin"
  run bash -c "$fn; choose_bin_dir '$brewbin' '$usrlocal'"
  [ "$output" = "$usrlocal" ]
  chmod 555 "$usrlocal"
  run bash -c "$fn; choose_bin_dir '$brewbin' '$usrlocal'"
  [ "$output" = "$HOME/.local/bin" ]
  chmod 755 "$brewbin" "$usrlocal"
}
