#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# shellcheck disable=SC2016  # single-quoted $-expressions here are deliberate: they expand later, in generated scripts
# tests/helpers/setup.bash — sandbox + stub factory shared by every suite.
#
# Each test gets a throwaway HOME/XDG_CONFIG_HOME/TMPDIR, a stub bin dir that
# shadows real tools, and a call log for exact-argv assertions. PATH keeps the
# system utility dirs so the code under test can use grep/sed/awk/df, but
# drops Homebrew so no real package manager is ever reachable from tests.

REPO_ROOT="$(cd "$(dirname "$BATS_TEST_FILENAME")/.." && pwd)"
export REPO_ROOT
export CMM="$REPO_ROOT/bin/scrubmac"
export CMM_LIB_PATH="$REPO_ROOT/lib/common.sh"
# Captured before setup_sandbox strips PATH: suites that exercise logic
# implemented in node (the npm cooldown resolver) link the real binary in.
REAL_NODE="${REAL_NODE:-$(command -v node 2>/dev/null || true)}"
export REAL_NODE

setup_sandbox() {
  SANDBOX="$(mktemp -d)"
  SANDBOX="$(cd "$SANDBOX" && pwd -P)"
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
  # Determinism: never probe the real network/power state or show desktop
  # notifications, and never treat the host's /usr/bin as Apple shims —
  # tests opt into each of these explicitly.
  export CMM_OFFLINE=0
  export CMM_NOTIFY=never
  export CMM_APPLE_STUB_DIR="$SANDBOX/applestubs"
  export STATE_DIR="$HOME/.local/state/scrubmac"
  export LOCK="$STATE_DIR/run.lock"
  # Safety net: no test may ever reach the host's launchd, notification
  # center or crontab. These silent defaults (no call-log lines) answer
  # "not loaded" / "no crontab"; tests that assert on them install logging
  # stubs over the top with make_stub.
  printf '#!/bin/sh\n[ "$1" = print ] && exit 113\nexit 0\n' >"$STUB_BIN/launchctl"
  printf '#!/bin/sh\ncat >/dev/null 2>&1\nexit 0\n' >"$STUB_BIN/osascript"
  printf '#!/bin/sh\nexit 1\n' >"$STUB_BIN/crontab"
  chmod 755 "$STUB_BIN/launchctl" "$STUB_BIN/osascript" "$STUB_BIN/crontab"
  unset CMM_DRY_RUN CMM_QUIET CMM_COOLDOWN_DAYS CMM_DERIVEDDATA_AGE_DAYS CMM_CONFIG_FILE \
    CMM_TIMEOUT CMM_APP_UPDATES CMM_STATE_DIR CMM_MEASURE CMM_ON_BATTERY \
    CMM_MIN_HOURS_BETWEEN_RUNS CMM_LOG_KEEP CMM_UPDATE_CHANNEL CMM_INTERACTIVE \
    CMM_ASSUME_INTERACTIVE CMM_WIZARD_ASSUME_TTY CMM_MODE CMM_SCHEDULED \
    CMM_REPORT_FILE CMM_DEVICESUPPORT_AGE_DAYS CMM_HOMEBREW_DOCTOR \
    CMM_DOCKER_KEEP_HOURS CMM_MISE_PRUNE CMM_COLOR XDG_STATE_HOME 2>/dev/null || true
  HOLDER_PIDS=''
}

teardown_sandbox() {
  local p
  for p in ${HOLDER_PIDS:-}; do
    kill "$p" 2>/dev/null || true
  done
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

# make_stub_script NAME — a fake tool whose body (POSIX sh) is read from
# stdin; the argv is logged first, like make_stub.
make_stub_script() {
  local name="$1"
  {
    printf '#!/bin/sh\n'
    printf 'printf '\''%%s %%s\\n'\'' "%s" "$*" >>"$CALL_LOG"\n' "$name"
    cat
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

# refute CMD… — assert that CMD fails. Never write `! cmd` in a test: bash's
# errexit ignores negated commands, so in Bats `! grep …` can NEVER fail a
# test (ShellCheck SC2314). Pipelines go through `refute_sh 'a | b'`.
refute() {
  if "$@"; then
    echo "expected to fail: $*" >&2
    return 1
  fi
  return 0
}

# refute_sh SCRIPT — like refute, for a shell snippet (pipelines etc.).
refute_sh() {
  if bash -c "$1"; then
    echo "expected to fail: $1" >&2
    return 1
  fi
  return 0
}

# start_holder NAME — a live background process whose command line contains
# NAME (lock-holder stand-in). Sets HOLDER_PID (call it directly, not in
# $(…)); teardown kills it.
start_holder() {
  local dir="$SANDBOX/holders/$1"
  mkdir -p "$dir"
  # no exec: the shell itself must stay alive under the NAME-bearing path
  printf '#!/bin/sh\ntrap '\''kill $c 2>/dev/null; exit 0'\'' TERM\nsleep 300 &\nc=$!\nwait $c\n' >"$dir/$1-holder"
  chmod 755 "$dir/$1-holder"
  "$dir/$1-holder" >/dev/null 2>&1 </dev/null 3>&- &
  HOLDER_PID=$!
  HOLDER_PIDS="${HOLDER_PIDS:-} $HOLDER_PID"
}

# dead_pid — a pid that is guaranteed not to be running.
dead_pid() { sh -c 'echo $$'; }

# hold_lock PID — plant the run lock as held by PID.
hold_lock() {
  mkdir -p "$STATE_DIR"
  ln -s "$1" "$LOCK"
}

# json_get FILE KEY — a top-level scalar from scrubmac's JSON (no jq needed).
json_get() {
  sed -n "s/^  \"$2\": \"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}\$/\1/p" "$1" | head -n 1
}
