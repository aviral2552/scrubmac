#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# lib/common.sh unit tests: run/try/dry-run, skip contract, config parsing,
# dates, install-kind classification, safety guards.

load helpers/setup

setup() { setup_sandbox; }
teardown() { teardown_sandbox; }

lib() { bash -c ". '$CMM_LIB_PATH'; $1"; }

@test "run executes its argv" {
  run lib "run touch '$SANDBOX/made'"
  [ "$status" -eq 0 ]
  [ -e "$SANDBOX/made" ]
  [[ "$output" == *"+ touch"* ]]
}

@test "run does not execute under CMM_DRY_RUN=1" {
  run lib "CMM_DRY_RUN=1 run touch '$SANDBOX/made'"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/made" ]
  [[ "$output" == *"+ touch"* ]]
}

@test "run propagates failure; try tolerates it" {
  run lib "run false"
  [ "$status" -ne 0 ]
  run lib "try false && echo SURVIVED"
  [ "$status" -eq 0 ]
  [[ "$output" == *SURVIVED* ]]
  [[ "$output" == *"exited 1"* ]]
}

@test "skip_unless exits 75 for a missing tool and 0-continues for a present one" {
  run lib "skip_unless definitely_not_a_real_tool_xyz"
  [ "$status" -eq 75 ]
  [[ "$output" == *"not found"* ]]
  run lib "skip_unless sh; echo CONTINUED"
  [ "$status" -eq 0 ]
  [[ "$output" == *CONTINUED* ]]
}

@test "config_get returns value, default, and last occurrence" {
  export CMM_CONFIG_FILE="$SANDBOX/config"
  printf 'COOLDOWN_DAYS=3\nCOOLDOWN_DAYS=9\n' >"$CMM_CONFIG_FILE"
  [ "$(lib 'config_get COOLDOWN_DAYS 0')" = "9" ]
  [ "$(lib 'config_get MISSING_KEY fallback')" = "fallback" ]
}

@test "config_get ignores shell syntax — config can never execute code (S5)" {
  export CMM_CONFIG_FILE="$SANDBOX/config"
  cat >"$CMM_CONFIG_FILE" <<EOF
COOLDOWN_DAYS=\$(touch $SANDBOX/pwned)
QUIET=1; touch $SANDBOX/pwned2
COLOR=\`touch $SANDBOX/pwned3\`
DERIVEDDATA_AGE_DAYS=45
EOF
  [ "$(lib 'config_get COOLDOWN_DAYS 0')" = "0" ]
  [ "$(lib 'config_get QUIET 0')" = "0" ]
  [ "$(lib 'config_get COLOR auto')" = "auto" ]
  [ "$(lib 'config_get DERIVEDDATA_AGE_DAYS 30')" = "45" ]
  [ ! -e "$SANDBOX/pwned" ]
  [ ! -e "$SANDBOX/pwned2" ]
  [ ! -e "$SANDBOX/pwned3" ]
}

@test "date_days_ago emits RFC 3339 UTC on both BSD and GNU date" {
  local out
  out="$(lib 'date_days_ago 7')"
  [[ "$out" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]]
}

@test "install_kind: node_modules wins over brew prefix (D4 ordering)" {
  local pfx="$SANDBOX/brewpfx"
  mkdir -p "$pfx/bin" "$pfx/lib/node_modules/@anthropic-ai/claude-code"
  printf '#!/bin/sh\n' >"$pfx/lib/node_modules/@anthropic-ai/claude-code/cli.js"
  chmod 755 "$pfx/lib/node_modules/@anthropic-ai/claude-code/cli.js"
  ln -s "../lib/node_modules/@anthropic-ai/claude-code/cli.js" "$pfx/bin/claude"
  export PATH="$pfx/bin:$PATH" CMM_BREW_PREFIX="$pfx"
  [ "$(lib 'install_kind claude')" = "npm" ]
}

@test "install_kind: plain binary under brew prefix is brew" {
  local pfx="$SANDBOX/brewpfx"
  mkdir -p "$pfx/bin"
  printf '#!/bin/sh\n' >"$pfx/bin/codex"
  chmod 755 "$pfx/bin/codex"
  export PATH="$pfx/bin:$PATH" CMM_BREW_PREFIX="$pfx"
  [ "$(lib 'install_kind codex')" = "brew" ]
}

@test "install_kind: standalone and none" {
  make_stub sometool
  [ "$(lib 'install_kind sometool')" = "standalone" ]
  [ "$(lib 'install_kind not_installed_xyz')" = "none" ]
}

@test "ai_self_update runs the updater only for standalone installs" {
  make_stub sometool
  make_stub sometool-updater
  run lib "ai_self_update sometool sometool-updater update"
  [ "$status" -eq 0 ]
  grep -q '^sometool-updater update$' "$CALL_LOG"
  : >"$CALL_LOG"
  local pfx="$SANDBOX/brewpfx"
  mkdir -p "$pfx/bin"
  printf '#!/bin/sh\n' >"$pfx/bin/brewtool"
  chmod 755 "$pfx/bin/brewtool"
  export PATH="$pfx/bin:$PATH" CMM_BREW_PREFIX="$pfx"
  run lib "ai_self_update brewtool sometool-updater update"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Homebrew-managed"* ]]
  ! grep -q sometool-updater "$CALL_LOG"
}

@test "cmm_path_is_safe rejects group/world-writable and foreign-owned paths" {
  local f="$SANDBOX/file"
  touch "$f"
  chmod 644 "$f"
  lib "cmm_path_is_safe '$f'"
  chmod 664 "$f"
  ! lib "cmm_path_is_safe '$f'"
  chmod 646 "$f"
  ! lib "cmm_path_is_safe '$f'"
}

@test "assert_safe_to_execute refuses symlinks and unsafe parents (S2)" {
  local d="$SANDBOX/safe"
  mkdir -p "$d"
  chmod 755 "$d"
  printf '#!/bin/sh\n' >"$d/real.sh"
  chmod 755 "$d/real.sh"
  lib "assert_safe_to_execute '$d/real.sh'"
  ln -s "$d/real.sh" "$d/link.sh"
  run lib "assert_safe_to_execute '$d/link.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *symlink* ]]
  chmod 775 "$d"
  run lib "assert_safe_to_execute '$d/real.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *directory* ]]
}

@test "colors: CMM_COLOR=always emits escapes, never does not" {
  run bash -c "CMM_COLOR=always . '$CMM_LIB_PATH'; banner hello"
  [[ "$output" == *$'\033['* ]]
  run bash -c "CMM_COLOR=never . '$CMM_LIB_PATH'; banner hello"
  [[ "$output" != *$'\033['* ]]
}

@test "resolve_self follows relative symlink chains" {
  mkdir -p "$SANDBOX/a/b" "$SANDBOX/real"
  printf 'x\n' >"$SANDBOX/real/target"
  ln -s ../../real/target "$SANDBOX/a/b/link1"
  ln -s link1 "$SANDBOX/a/b/link2"
  [ "$(lib "resolve_self '$SANDBOX/a/b/link2'")" = "$SANDBOX/real/target" ]
}
