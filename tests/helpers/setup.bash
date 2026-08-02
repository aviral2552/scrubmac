#!/usr/bin/env bash
# shellcheck disable=SC2016  # single-quoted $-expressions here are deliberate: they expand later, in generated scripts
# tests/helpers/setup.bash — sandbox + stub factory shared by every suite.
#
# Each test gets a throwaway HOME/XDG_CONFIG_HOME/TMPDIR, a stub bin dir that
# shadows real tools, and a call log for exact-argv assertions. PATH keeps the
# system utility dirs so the code under test can use grep/sed/awk/df, but
# drops Homebrew so no real package manager is ever reachable from tests.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
export REPO_ROOT
export CMM="$REPO_ROOT/bin/cleanmymac"
export CMM_LIB_PATH="$REPO_ROOT/lib/common.sh"

setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  export SANDBOX
  export HOME="$SANDBOX/home"
  export XDG_CONFIG_HOME="$HOME/.config"
  export TMPDIR="$SANDBOX/tmp"
  export STUB_BIN="$SANDBOX/stubbin"
  export CALL_LOG="$SANDBOX/calls.log"
  export FIXTURES="$SANDBOX/cleaners"
  mkdir -p "$HOME" "$TMPDIR" "$STUB_BIN" "$FIXTURES"
  : >"$CALL_LOG"
  export PATH="$STUB_BIN:/usr/bin:/bin:/usr/sbin:/sbin"
  # MINI_BIN holds only bash: with PATH="$STUB_BIN:$MINI_BIN" a test proves a
  # cleaner skips when NO real tool is reachable (portable — on Linux /bin
  # carries python3 etc., so stripping to /bin is not enough).
  export MINI_BIN="$SANDBOX/minibin"
  mkdir -p "$MINI_BIN"
  ln -s "$(command -v bash)" "$MINI_BIN/bash"
  export CMM_BREW_PREFIX="" # pre-seed the memo: no brew classification unless a test opts in
  export CMM_CLEANERS_DIR="$FIXTURES"
  export NO_COLOR=1
  unset CMM_DRY_RUN CMM_QUIET CMM_COOLDOWN_DAYS CMM_DERIVEDDATA_AGE_DAYS CMM_CONFIG_FILE 2>/dev/null || true
}

teardown_sandbox() {
  [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
}

# make_stub NAME [EXIT_CODE] [OUTPUT] — a fake tool that records its argv.
make_stub() {
  local name="$1" rc="${2:-0}" out="${3:-}"
  {
    printf '#!/bin/sh\n'
    printf 'printf '\''%%s %%s\\n'\'' "%s" "$*" >>"$CALL_LOG"\n' "$name"
    [ -n "$out" ] && printf 'printf '\''%%s\\n'\'' %s\n' "'$out'"
    printf 'exit %s\n' "$rc"
  } >"$STUB_BIN/$name"
  chmod 755 "$STUB_BIN/$name"
}

# make_cleaner FILENAME LINE... — a fixture cleaner in $FIXTURES.
make_cleaner() {
  local file="$FIXTURES/$1"
  shift
  {
    printf '#!/usr/bin/env bash\nset -euo pipefail\n'
    printf '%s\n' "$@"
  } >"$file"
  chmod 755 "$file"
}

# make_lib_cleaner FILENAME LINE... — fixture cleaner that sources the real lib.
make_lib_cleaner() {
  local file="$1"
  shift
  make_cleaner "$file" '. "$CMM_LIB"' "$@"
}

calls() { cat "$CALL_LOG"; }
