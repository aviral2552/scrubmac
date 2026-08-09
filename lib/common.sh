#!/usr/bin/env bash
# Part of cleanmymac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# lib/common.sh — shared helpers for cleanmymac and its cleaners.
#
# Sourced, never executed. Compatible with the bash 3.2 that ships with macOS:
# no associative arrays, no mapfile, no ${var,,}.
#
# Cleaner exit-code contract:
#   0             ok
#   75            skipped (tool absent / not applicable) — use skip/skip_unless
#   anything else failed

[ -n "${CMM_COMMON_LOADED:-}" ] && return 0
CMM_COMMON_LOADED=1

CMM_EXIT_SKIP=75

# ---------- colors ----------
# Color iff stdout is a TTY, NO_COLOR is unset, and CMM_COLOR is not "never"
# (CMM_COLOR=always forces color). Callable again after config is read.
cmm_init_colors() {
  local on=0
  case "${CMM_COLOR:-auto}" in
    always) on=1 ;;
    never) on=0 ;;
    *) if [ -t 1 ] && [ -z "${NO_COLOR:-}" ]; then on=1; fi ;;
  esac
  # shellcheck disable=SC2034  # consumed by sourcing scripts
  if [ "$on" -eq 1 ]; then
    CMM_BOLD=$'\033[1m' CMM_DIM=$'\033[2m' CMM_RED=$'\033[31m'
    CMM_GREEN=$'\033[32m' CMM_YELLOW=$'\033[33m' CMM_RESET=$'\033[0m'
  else
    CMM_BOLD='' CMM_DIM='' CMM_RED='' CMM_GREEN='' CMM_YELLOW='' CMM_RESET=''
  fi
}
cmm_init_colors

# ---------- output ----------
note() { printf '%s\n' "$*"; }
warn() { printf '%swarning:%s %s\n' "$CMM_YELLOW" "$CMM_RESET" "$*" >&2; }
err() { printf '%serror:%s %s\n' "$CMM_RED" "$CMM_RESET" "$*" >&2; }

banner() {
  local s="$*"
  printf '\n%s%s%s\n%s\n' "$CMM_BOLD" "$s" "$CMM_RESET" "${s//?/=}"
}

# ---------- detection ----------
have() { command -v "$1" >/dev/null 2>&1; }

# skip [message] — end this cleaner as "skipped" (exit 75).
skip() {
  note "- ${*:-skipping}"
  exit "$CMM_EXIT_SKIP"
}

skip_unless() {
  have "$1" || skip "skipping: '$1' not found"
}

# ---------- command execution ----------
# run CMD ARGS… — announce and execute a mutating command. Honors dry-run.
# Failures propagate (cleaners run under `set -e`, so a failed `run` fails the
# cleaner). Takes an argument vector only — no strings, no eval, no pipelines.
run() {
  printf '%s+ %s%s\n' "$CMM_DIM" "$*" "$CMM_RESET"
  [ "${CMM_DRY_RUN:-0}" = "1" ] && return 0
  "$@"
}

# try CMD ARGS… — like run, but a non-zero exit is reported and tolerated.
# For advisory commands (brew doctor, npm outdated) whose non-zero exits are
# informational, not failures.
try() {
  local rc=0
  run "$@" || rc=$?
  [ "$rc" -ne 0 ] && warn "'$1' exited $rc (continuing)"
  return 0
}

# ---------- paths ----------
# resolve_self PATH — print PATH with every symlink in the final component
# resolved and the directory part made absolute. No readlink -f (portability).
resolve_self() {
  local target="$1" dir
  while [ -L "$target" ]; do
    dir="$(cd "$(dirname "$target")" && pwd)"
    target="$(readlink "$target")"
    case "$target" in
      /*) ;;
      *) target="$dir/$target" ;;
    esac
  done
  dir="$(cd "$(dirname "$target")" && pwd)"
  printf '%s/%s\n' "$dir" "$(basename "$target")"
}

# ---------- dates ----------
# date_days_ago N — RFC 3339 UTC timestamp N days in the past (BSD, then GNU).
date_days_ago() {
  date -u -v "-${1}d" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
    date -u -d "$1 days ago" '+%Y-%m-%dT%H:%M:%SZ'
}

# ---------- configuration (S5: parsed, never sourced) ----------
cmm_config_dir() { printf '%s/cleanmymac\n' "${XDG_CONFIG_HOME:-$HOME/.config}"; }

# config_get KEY DEFAULT — read KEY from the config file. Only lines matching
# the strict KEY=value grammar are honored; anything else (shell syntax,
# command substitution, spaces) is ignored, so the config file can never
# execute code. Last valid occurrence wins.
config_get() {
  local file="${CMM_CONFIG_FILE:-$(cmm_config_dir)/config}" line
  line="$({ grep -E "^$1=[A-Za-z0-9._/-]*$" "$file" 2>/dev/null || true; } | tail -n 1)"
  if [ -n "$line" ]; then
    printf '%s\n' "${line#*=}"
  else
    printf '%s\n' "${2:-}"
  fi
}

# ---------- install-kind classification (D4) ----------
# install_kind CMD — print npm | brew | standalone | none.
# The node_modules test must precede the brew-prefix test: npm globals on a
# brew-managed node live under the brew prefix but inside node_modules/.
install_kind() {
  local path
  path="$(command -v "$1" 2>/dev/null)" || {
    printf 'none\n'
    return 0
  }
  path="$(resolve_self "$path")"
  case "$path" in
    */node_modules/*)
      printf 'npm\n'
      return 0
      ;;
  esac
  if [ -z "${CMM_BREW_PREFIX+x}" ]; then
    CMM_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  fi
  if [ -n "$CMM_BREW_PREFIX" ]; then
    case "$path" in
      "$CMM_BREW_PREFIX"/*)
        printf 'brew\n'
        return 0
        ;;
    esac
  fi
  case "$path" in
    */Cellar/* | */Caskroom/*)
      printf 'brew\n'
      return 0
      ;;
  esac
  printf 'standalone\n'
}

# ai_self_update TOOL [CMD…] — run TOOL's own updater only when it is a
# standalone install; package-manager-managed installs are updated by the
# npm/homebrew cleaners instead (self-updating them fights the manager).
ai_self_update() {
  local tool="$1"
  shift
  case "$(install_kind "$tool")" in
    npm) note "- $tool is npm-managed; the npm cleaner keeps it updated" ;;
    brew) note "- $tool is Homebrew-managed; the homebrew cleaner keeps it updated" ;;
    none) note "- $tool not found" ;;
    *)
      if [ "$#" -gt 0 ]; then
        try "$@"
      else
        note "- $tool is installed standalone; update it via its own installer"
      fi
      ;;
  esac
}

# ---------- execution-safety guards (S2) ----------
# Prints "<octal-mode> <uid>". GNU form first, BSD fallback — the order
# matters: BSD `stat -c` fails cleanly on GNU-isms, but GNU `stat -f` does
# NOT fail on the BSD form (it means "filesystem status" there and exits 0
# with garbage output).
cmm_mode_uid() {
  # -L dereferences: on merged-usr Linux, /bin is a symlink whose own mode is
  # 777 — the permissions that matter are the target's. Symlinked *cleaners*
  # are rejected before any mode check (assert_safe_to_execute), so
  # dereferencing here is always the right reading.
  stat -L -c '%a %u' "$1" 2>/dev/null || stat -L -f '%Lp %u' "$1" 2>/dev/null
}

# cmm_path_is_safe PATH — owned by the current user and not group/world-writable.
cmm_path_is_safe() {
  local out mode uid
  out="$(cmm_mode_uid "$1")" || return 1
  mode="${out%% *}"
  uid="${out##* }"
  case "$mode" in '' | *[!0-9]*) return 1 ;; esac
  [ "$uid" = "${EUID:-$(id -u)}" ] || return 1
  # shellcheck disable=SC2004
  [ $((0$mode & 022)) -eq 0 ]
}

# assert_safe_to_execute FILE — refuse files another local user could have
# tampered with: symlinks, files not owned by us, and files or parent
# directories that are group/world-writable. The check-then-execute gap
# (TOCTOU) is a documented residual risk — see docs/security.md.
assert_safe_to_execute() {
  local f="$1"
  if [ -L "$f" ]; then
    warn "skipping '$f': symlinked cleaners are not run (see docs/security.md)"
    return 1
  fi
  [ -f "$f" ] || return 1
  if ! cmm_path_is_safe "$f"; then
    warn "skipping '$f': cleaner files must be owned by you and not group/world-writable"
    return 1
  fi
  if ! cmm_path_is_safe "$(dirname "$f")"; then
    warn "skipping '$f': its directory must be owned by you and not group/world-writable"
    return 1
  fi
}
