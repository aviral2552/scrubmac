#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# lib/common.sh — shared helpers for scrubmac and its cleaners.
#
# Sourced, never executed. Compatible with the bash 3.2 that ships with macOS:
# no associative arrays, no mapfile, no ${var,,}.
#
# Cleaner exit-code contract:
#   0             ok
#   75            skipped (tool absent / not applicable) — use skip/skip_unless
#   anything else failed
#
# Cleaner helper vocabulary (see docs/writing-cleaners.md):
#   run CMD…        mutating command; a failure fails the cleaner immediately
#   step CMD…       mutating command; a failure is recorded, the cleaner carries
#                   on, and it reports FAIL when it exits
#   try CMD…        advisory command; a failure is reported and tolerated
#   preview CMD…    read-only preview, executed only under --dry-run
#   report CMD…     read-only report, executed only by `scrubmac status`
#   cache_dir DIR…  declare the cache dirs this cleaner trims (status sizes,
#                   MEASURE=1 before/after)
#   updating / cleaning / interactive / app_updates_allowed — predicates
#   summary_note TEXT — a line shown under this cleaner in the run summary

[ -n "${CMM_COMMON_LOADED:-}" ] && return 0
CMM_COMMON_LOADED=1

# bash ≥ 5.2 expands "&" in a ${var//pattern/replacement} replacement to the
# matched text (patsub_replacement, on by default); keep 3.2's literal "&".
shopt -u patsub_replacement 2>/dev/null || true
# A CDPATH makes `cd DIR` search elsewhere and print where it went.
unset CDPATH

CMM_EXIT_SKIP=75
CMM_OS="${CMM_OS:-$(uname -s 2>/dev/null || echo unknown)}"

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

# cmm_human_kb KB — "512 KB" / "1.5 MB" / "2.25 GB".
cmm_human_kb() {
  awk -v k="${1:-0}" 'BEGIN { if (k < 1024) printf "%d KB", k; else if (k < 1048576) printf "%.1f MB", k / 1024; else printf "%.2f GB", k / 1048576 }'
}

# ---------- detection ----------
# Apple's /usr/bin developer-tool shims exist on every Mac, but running one
# without a developer directory pops the "install Command Line Tools" dialog
# — which a scheduled run must never do. have() treats them as absent then.
CMM_APPLE_STUBS=' git python3 pip3 swift swiftc xcodebuild xcrun clang make '

# Populate CMM__DEVDIR once per process ('' when none is selected). Call it
# directly, never inside $(…): the cache must land in this shell.
cmm__load_devdir() {
  [ -n "${CMM__DEVDIR_LOADED:-}" ] && return 0
  CMM__DEVDIR_LOADED=1
  CMM__DEVDIR=''
  if command -v xcode-select >/dev/null 2>&1; then
    CMM__DEVDIR="$(xcode-select -p 2>/dev/null)" || CMM__DEVDIR=''
  fi
  return 0
}

# cmm_full_xcode — a full Xcode (not just the Command Line Tools) is selected.
cmm_full_xcode() {
  cmm__load_devdir
  case "$CMM__DEVDIR" in
    '' | */CommandLineTools | */CommandLineTools/) return 1 ;;
  esac
  [ -d "$CMM__DEVDIR" ]
}

have() {
  command -v "$1" >/dev/null 2>&1 || return 1
  case "$CMM_APPLE_STUBS" in
    *" $1 "*) ;;
    *) return 0 ;;
  esac
  local p sdir="${CMM_APPLE_STUB_DIR:-}"
  if [ -z "$sdir" ]; then
    [ "$CMM_OS" = Darwin ] || return 0
    sdir=/usr/bin
  fi
  p="$(command -v "$1")"
  [ "$p" = "$sdir/$1" ] || return 0 # a real install elsewhere on PATH
  cmm__load_devdir
  if [ -z "$CMM__DEVDIR" ] || [ ! -d "$CMM__DEVDIR" ]; then
    return 1 # inert shim: running it would pop the CLT install dialog
  fi
  if [ "$1" = xcodebuild ]; then
    cmm_full_xcode # the xcodebuild shim errors out without a full Xcode
    return
  fi
  return 0
}

# skip [message] — end this cleaner as "skipped" (exit 75).
skip() {
  local msg="${*:-skipping}"
  note "- $msg"
  cmm__report_line skip "$msg"
  exit "$CMM_EXIT_SKIP"
}

skip_unless() {
  have "$1" || skip "skipping: '$1' not found"
}

# ---------- modes & context ----------
# CMM_MODE is run (default), update, clean, or status; the dispatcher sets it
# from --update-only / --clean-only / `scrubmac status`.

# updating — true when this run may change installed versions: the mode
# allows updates and the machine is online. Offline, it explains itself once.
updating() {
  case "${CMM_MODE:-run}" in
    run | update) ;;
    *) return 1 ;;
  esac
  if [ "${CMM_OFFLINE:-0}" = 1 ]; then
    if [ -z "${CMM__OFFLINE_NOTED:-}" ]; then
      CMM__OFFLINE_NOTED=1
      note "- offline (no network route): skipping updates"
      summary_note "offline — updates skipped"
    fi
    return 1
  fi
  return 0
}

# cleaning — true when this run may trim caches.
cleaning() {
  case "${CMM_MODE:-run}" in
    run | clean) return 0 ;;
  esac
  return 1
}

# skip_unless_updating — for cleaners that only update (nothing to clean).
# In `scrubmac status` the cleaner ends here successfully: put its report
# commands before this call.
skip_unless_updating() {
  case "${CMM_MODE:-run}" in
    clean) skip "skipping: nothing to clean (update-only cleaner)" ;;
    status) exit 0 ;;
  esac
  if [ "${CMM_OFFLINE:-0}" = 1 ]; then
    skip "skipping: offline (updates need the network)"
  fi
  return 0
}

# skip_unless_cleaning — for cleaners that only clean (nothing to update).
skip_unless_cleaning() {
  case "${CMM_MODE:-run}" in
    update) skip "skipping: nothing to update (cleanup-only cleaner)" ;;
  esac
  return 0
}

interactive() { [ "${CMM_INTERACTIVE:-0}" = 1 ]; }

# app_updates_allowed — GUI app upgrades (Homebrew casks, App Store) can quit
# running apps or ask for a password, so by default they only happen when a
# person is watching (APP_UPDATES=interactive|always|never).
app_updates_allowed() {
  case "${CMM_APP_UPDATES:-interactive}" in
    always) return 0 ;;
    never) return 1 ;;
  esac
  interactive
}

# ---------- reporting back to the dispatcher ----------
# Cleaners report notes, skip reasons, cache sizes and freed space as
# "key<TAB>value" lines in CMM_REPORT_FILE (set per cleaner by the dispatcher;
# unset when a cleaner runs standalone, which makes these no-ops).
cmm__report_line() {
  [ -n "${CMM_REPORT_FILE:-}" ] || return 0
  local v="$2"
  v="${v//$'\t'/ }"
  v="${v//$'\n'/ }"
  { printf '%s\t%s\n' "$1" "$v" >>"$CMM_REPORT_FILE"; } 2>/dev/null || true
}

# summary_note TEXT — shown under this cleaner in the run summary and JSON.
summary_note() { cmm__report_line note "$*"; }

# ---------- command execution ----------
# cmm__exec CMD ARGS… — announce and execute (the core of run/step/try).
# Returns the command's status, except that 75 (the "skipped" exit code)
# becomes 1: a tool that happens to exit 75 has failed, not skipped.
cmm__exec() {
  [ "${CMM_MODE:-run}" = status ] && return 0
  printf '%s+ %s%s\n' "$CMM_DIM" "$*" "$CMM_RESET"
  [ "${CMM_DRY_RUN:-0}" = "1" ] && return 0
  local rc=0
  "$@" || rc=$?
  [ "$rc" -eq "$CMM_EXIT_SKIP" ] && rc=1
  return "$rc"
}

# cmm__failed_note RC CMD ARGS… — name the failing command in the summary.
# (LC_ALL=C cuts bytes: a character split at the cut is dropped.)
cmm__failed_note() {
  local rc="$1" cmd
  shift
  cmd="$*"
  [ "${#cmd}" -le 80 ] || cmd="$(printf '%s' "${cmd:0:77}" | cmm__valid_utf8)..."
  summary_note "failed: $cmd (exit $rc)"
}

# run CMD ARGS… — announce and execute a mutating command. Honors dry-run.
# Failures propagate (cleaners run under `set -e`, so a failed `run` fails the
# cleaner). Takes an argument vector only — no strings, no eval, no pipelines.
# `scrubmac status` never mutates: run/step/try are silent no-ops there.
run() {
  local rc=0
  cmm__exec "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    cmm__failed_note "$rc" "$@"
    return "$rc"
  fi
  return 0
}

# try CMD ARGS… — like run, but a non-zero exit is reported and tolerated.
# For advisory commands (brew doctor, npm outdated) whose non-zero exits are
# informational, not failures.
try() {
  local rc=0
  cmm__exec "$@" || rc=$?
  [ "$rc" -ne 0 ] && warn "'$1' exited $rc (continuing)"
  return 0
}

# step CMD ARGS… — like run, but a failure does not stop the cleaner: the
# remaining (independent) steps still run, and the cleaner exits non-zero at
# the end so the summary says FAIL. Use run instead when later commands must
# not happen after a failure.
step() {
  local rc=0
  cmm__exec "$@" || rc=$?
  if [ "$rc" -ne 0 ]; then
    warn "'$1' exited $rc — continuing with the remaining steps"
    cmm__failed_note "$rc" "$@"
    cmm_fail_later
  fi
  return 0
}

# cmm_fail_later — make this cleaner exit non-zero when it finishes.
cmm_fail_later() {
  CMM__STEP_FAILED=1
  cmm__arm_exit
}

cmm__arm_exit() {
  [ -n "${CMM__EXIT_ARMED:-}" ] && return 0
  CMM__EXIT_ARMED=1
  trap cmm__on_exit EXIT
}

cmm__on_exit() {
  local rc=$?
  cmm__finish_measure
  if [ "${CMM__STEP_FAILED:-0}" = 1 ]; then
    if [ "$rc" -eq 0 ] || [ "$rc" -eq "$CMM_EXIT_SKIP" ]; then
      rc=1
    fi
  fi
  exit "$rc"
}

# cmm__readonly KIND [--ok=N] CMD ARGS… — show and execute a read-only
# command (the core of preview/report). A non-zero exit is a warning, never
# a failure; with --ok=N, exit N is an answer rather than an error (`npm
# outdated` exits 1 whenever something is outdated).
cmm__readonly() {
  local kind="$1" ok='' rc=0
  shift
  case "${1:-}" in
    --ok=*)
      ok="${1#--ok=}"
      shift
      ;;
  esac
  printf '%s~ %s%s\n' "$CMM_DIM" "$*" "$CMM_RESET"
  "$@" || rc=$?
  if [ "$rc" -ne 0 ] && [ "$rc" != "$ok" ]; then
    warn "$kind '$1' exited $rc (continuing)"
  fi
  return 0
}

# preview [--ok=N] CMD ARGS… — a READ-ONLY command that shows what a run
# would change (e.g. `brew upgrade --dry-run`). Executed only under
# --dry-run.
preview() {
  [ "${CMM_DRY_RUN:-0}" = 1 ] || return 0
  [ "${CMM_MODE:-run}" = status ] && return 0
  cmm__readonly preview "$@"
}

# report [--ok=N] CMD ARGS… — a READ-ONLY command for `scrubmac status`
# (e.g. `brew outdated`). Executed only in status mode.
report() {
  [ "${CMM_MODE:-run}" = status ] || return 0
  cmm__readonly report "$@"
}

# cmm_scratch_dir — a private directory for this cleaner's temporary files:
# one the dispatcher creates per cleaner and removes after the run (even when
# the cleaner is stopped by TIMEOUT), or a fresh mktemp dir when the cleaner
# runs standalone. Prints nothing and fails when none can be made.
cmm_scratch_dir() {
  if [ -n "${CMM_SCRATCH_DIR:-}" ] && [ -d "$CMM_SCRATCH_DIR" ]; then
    printf '%s\n' "$CMM_SCRATCH_DIR"
    return 0
  fi
  mktemp -d "${TMPDIR:-/tmp}/scrubmac-${CMM_CLEANER_NAME:-cleaner}.XXXXXX" 2>/dev/null
}

# ---------- cache accounting ----------
# cmm_du_kb PATH — disk usage in KB (0 when absent or unreadable).
cmm_du_kb() {
  local out=''
  if [ -e "$1" ]; then
    out="$(du -sk "$1" 2>/dev/null | awk 'NR == 1 { print $1 + 0 }')" || out=''
  fi
  printf '%s\n' "${out:-0}"
}

# cache_dir DIR… — declare the regenerable cache directories this cleaner
# trims: `scrubmac status` reports their size, and with MEASURE=1 a run
# measures them before and after to report space freed per cleaner.
cache_dir() {
  local d kb
  for d in "$@"; do
    [ -n "$d" ] || continue
    if [ "${CMM_MODE:-run}" = status ]; then
      kb="$(cmm_du_kb "$d")"
      printf '  cache %s: %s\n' "$d" "$(cmm_human_kb "$kb")"
      cmm__report_line cache_kb "$kb"
    elif [ "${CMM_MEASURE:-0}" = 1 ] && [ "${CMM_DRY_RUN:-0}" != 1 ]; then
      kb="$(cmm_du_kb "$d")"
      CMM__MEASURE_DIRS="${CMM__MEASURE_DIRS:-}$d"$'\n'
      CMM__MEASURE_BEFORE=$((${CMM__MEASURE_BEFORE:-0} + kb))
      cmm__arm_exit
    fi
  done
  return 0
}

# cache_dir_cmd CMD… — cache_dir with the directory printed by CMD (e.g.
# `uv cache dir`); CMD only runs when the size is actually needed.
cache_dir_cmd() {
  case "${CMM_MODE:-run}" in
    status) ;;
    *)
      [ "${CMM_MEASURE:-0}" = 1 ] && [ "${CMM_DRY_RUN:-0}" != 1 ] || return 0
      ;;
  esac
  local d=''
  d="$("$@" 2>/dev/null)" || d=''
  d="${d%%$'\n'*}"
  [ -n "$d" ] && cache_dir "$d"
  return 0
}

cmm__finish_measure() {
  [ -n "${CMM__MEASURE_DIRS:-}" ] || return 0
  local d kb after=0 freed
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    kb="$(cmm_du_kb "$d")"
    after=$((after + kb))
  done <<EOF
$CMM__MEASURE_DIRS
EOF
  freed=$((${CMM__MEASURE_BEFORE:-0} - after))
  [ "$freed" -lt 0 ] && freed=0
  cmm__report_line freed_kb "$freed"
  CMM__MEASURE_DIRS=''
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

# cmm_canon_path PATH — PATH made absolute with symlinks resolved, for
# comparisons that must not be fooled by "$HOME/." or a symlinked parent.
# Components that do not exist yet are appended as given. Fails (prints
# nothing) for paths with "." or ".." components, or whose existing prefix
# ends in a dangling symlink or a non-directory.
cmm_canon_path() {
  local p="$1" rest='' out
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  case "$p/" in
    */./* | */../*) return 1 ;;
  esac
  while [ "$p" != "/" ] && [ ! -d "$p" ]; do
    if [ -L "$p" ] || [ -e "$p" ]; then
      return 1
    fi
    rest="/${p##*/}$rest"
    p="${p%/*}"
    [ -n "$p" ] || p="/"
  done
  p="$(cd -P "$p" 2>/dev/null && pwd -P)" || return 1
  # a symlink to / can leave a leading "//" (POSIX keeps it distinct)
  while [ "${p#//}" != "$p" ]; do p="${p#/}"; done
  [ "$p" = "/" ] && p=''
  out="$p$rest"
  printf '%s\n' "${out:-/}"
}

# cmm_canon_parent PATH — like cmm_canon_path, but the last component is kept
# as given (not resolved), so "is this path itself a symlink?" still works.
cmm_canon_parent() {
  local p="$1" dir base
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  base="${p##*/}"
  dir="${p%/*}"
  [ -n "$dir" ] || dir=/
  case "$base" in '' | . | ..) return 1 ;; esac
  dir="$(cmm_canon_path "$dir")" || return 1
  [ "$dir" = / ] && dir=''
  printf '%s/%s\n' "$dir" "$base"
}

cmm__regular_file() { [ -f "$1" ] && [ ! -L "$1" ]; }

# cmm_is_install_dir DIR — DIR is absent or empty, or carries the files of a
# scrubmac/cleanmymac install (3.x/2.x: regular lib/common.sh + VERSION +
# bin/scrubmac or bin/cleanmymac; 1.x: setup/install.sh + the old script).
# Symlinks never count: an installer-made launcher link is not an install.
cmm_is_install_dir() {
  local d="$1" entry
  [ -e "$d" ] || [ -L "$d" ] || return 0
  [ -d "$d" ] && [ ! -L "$d" ] || return 1
  for entry in "$d"/* "$d"/.[!.]* "$d"/..?*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    if cmm__regular_file "$d/lib/common.sh" && cmm__regular_file "$d/VERSION" &&
      { cmm__regular_file "$d/bin/scrubmac" || cmm__regular_file "$d/bin/cleanmymac"; }; then
      return 0
    fi
    if cmm__regular_file "$d/setup/install.sh" &&
      { cmm__regular_file "$d/cleanmymac.sh" || cmm__regular_file "$d/scrubmac.sh"; }; then
      return 0
    fi
    return 1
  done
  return 0 # empty
}

# cmm_local_work DIR — DIR is a git checkout holding work that mirroring over
# it or deleting it would destroy: prints what (uncommitted or untracked
# files — also ones that only your own ignore rules hide, whatever
# status.showUntrackedFiles says — a stash, or commits that are on no remote
# and in no release tag) and succeeds. Git's environment is ignored (a
# GIT_DIR from a hook would point it at another repository).
cmm_local_work() {
  local d="$1" out rel
  [ -e "$d/.git" ] || return 1
  if ! have git; then
    printf 'a .git (and no git here to check it for local work)'
    return 0
  fi
  lw_git() (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE GIT_CEILING_DIRECTORIES
    git -C "$d" "$@"
  )
  # published: on a remote, or in a release tag (exactly vX.Y.Z, as releases
  # are named — a tag of your own is not), mirrored or not
  rel="$(lw_git for-each-ref --format='%(refname)' refs/tags 2>/dev/null |
    grep -E '^refs/tags/v[0-9]+\.[0-9]+\.[0-9]+$' || true)"
  # shellcheck disable=SC2086  # (rel: tag refnames never contain whitespace)
  if ! out="$(lw_git status --porcelain --untracked-files=all 2>/dev/null)"; then
    printf 'a .git that git cannot read'
  elif [ -n "$out" ]; then
    printf 'uncommitted or untracked files'
  elif [ -n "$(lw_git ls-files --others --exclude-per-directory=.gitignore 2>/dev/null | sed -n 1p)" ]; then
    printf 'untracked files that only your own git ignore rules hide'
  elif lw_git rev-parse -q --verify refs/stash >/dev/null 2>&1; then
    printf 'a stash'
  elif [ -n "$(lw_git rev-list --max-count=1 HEAD --branches --not --remotes $rel \
    --glob='refs/scrubmac/release-tags/*' --glob='refs/scrubmac/seen-tags/*' 2>/dev/null || echo unknown)" ]; then
    # (a release update fetches tags only, so origin/* may lag behind HEAD)
    printf 'commits that are on no remote'
  else
    return 1
  fi
  return 0
}

# cmm_unsafe_target DIR — DIR (canonical) is "/", $HOME, or an ancestor of
# $HOME: never a place to install into or remove.
cmm_unsafe_target() {
  local d="$1" home
  home="$(cmm_canon_path "$HOME")" || home="$HOME"
  case "$d" in
    '' | / | "$home") return 0 ;;
  esac
  case "$home/" in
    "$d"/*) return 0 ;;
  esac
  return 1
}

# cmm_link_dirs — where launcher links may live besides Homebrew's bin, one
# per line: /usr/local/bin and ~/.local/bin, or the colon-separated
# CMM_LINK_DIRS (tests: never the host's /usr/local/bin).
cmm_link_dirs() {
  local rest="${CMM_LINK_DIRS-/usr/local/bin:$HOME/.local/bin}" d
  while [ -n "$rest" ]; do
    d="${rest%%:*}"
    case "$rest" in
      *:*) rest="${rest#*:}" ;;
      *) rest='' ;;
    esac
    [ -n "$d" ] && printf '%s\n' "$d"
  done
  return 0
}

# cmm_launcher_dirs DIR… — DIR… (empty ones dropped), then cmm_link_dirs,
# each once, one per line: every place a launcher link may be.
cmm_launcher_dirs() {
  {
    [ "$#" -gt 0 ] && printf '%s\n' "$@"
    cmm_link_dirs
  } | awk 'NF && !seen[$0]++'
}

# points_into LINK DIR — LINK is a symlink whose target lives under DIR
# (including dangling links left by older layouts).
points_into() {
  local target
  [ -L "$1" ] || return 1
  target="$(readlink "$1")"
  case "$target" in
    "$2" | "$2"/*) return 0 ;;
  esac
  return 1
}

# cmm_old_name_ours TOKEN DIR… — TOKEN (how a crontab entry calls
# cleanmymac) reaches one of DIR… — a path under one, or a link into one —
# rather than MacPaw's CleanMyMac command of the same name. A bare name
# counts unless your PATH resolves it to something else.
cmm_old_name_ours() {
  local p="$1" real d
  shift
  # shellcheck disable=SC2016,SC2088  # the literal text of a crontab entry
  case "$p" in
    '~/'*) p="$HOME/${p#\~/}" ;;
    '$HOME/'*) p="$HOME/${p#\$HOME/}" ;;
    '${HOME}/'*) p="$HOME/${p#\$\{HOME\}/}" ;;
  esac
  case "$p" in
    */*) ;;
    *) p="$(command -v "$p" 2>/dev/null)" || return 0 ;;
  esac
  real="$(resolve_self "$p" 2>/dev/null)" || real="$p"
  for d in "$@"; do
    [ -n "$d" ] || continue
    case "$p" in "$d"/*) return 0 ;; esac
    case "$real" in "$d"/*) return 0 ;; esac
  done
  return 1
}

# cmm_cron_old_name DIR… — your crontab still runs cleanmymac (as a command
# word, in an entry that is not commented out) in a way that leads to one of
# DIR… (see cmm_old_name_ours).
cmm_cron_old_name() {
  local tok
  have crontab || return 1
  while IFS= read -r tok; do
    [ -n "$tok" ] && cmm_old_name_ours "$tok" "$@" && return 0
  done <<EOF
$({ crontab -l 2>/dev/null || true; } | grep -v '^[[:space:]]*#' |
    grep -oE '(^|[[:space:]"'"'"'(;&|`])[^[:space:]"'"'"'(;&|<>`]*cleanmymac([[:space:]"'"'"';&|<>)`]|$)' |
    sed -E 's/^[[:space:]"'"'"'(;&|`]+//; s/[[:space:]"'"'"';&|<>)`]+$//')
EOF
  return 1
}

# cmm_plist_xml FILE — FILE as XML text; a property list saved in binary
# (or JSON) form is converted with plutil, where there is one.
cmm_plist_xml() {
  if command -v plutil >/dev/null 2>&1 && plutil -convert xml1 -o - "$1" 2>/dev/null; then
    return 0
  fi
  cat "$1" 2>/dev/null
}

# ---------- dates ----------
# date_days_ago N — RFC 3339 UTC timestamp N days in the past (BSD, then GNU).
date_days_ago() {
  date -u -v "-${1}d" '+%Y-%m-%dT%H:%M:%SZ' 2>/dev/null ||
    date -u -d "$1 days ago" '+%Y-%m-%dT%H:%M:%SZ'
}

cmm_now_iso() { date -u '+%Y-%m-%dT%H:%M:%SZ'; }

# cmm_iso_to_epoch 2026-01-02T03:04:05Z — seconds since the epoch (BSD, then
# GNU date); fractional seconds are ignored, and a +hh:mm / -hhmm / +hh
# offset is honored (Z or none: UTC). Fails on unparseable input.
cmm_iso_to_epoch() {
  local s="$1" tz='' off=0 e
  case "$s" in
    *T*[+-][0-9][0-9]:[0-9][0-9]) tz="${s#"${s%??????}"}" s="${s%??????}" ;;
    *T*[+-][0-9][0-9][0-9][0-9]) tz="${s#"${s%?????}"}" s="${s%?????}" ;;
    *T*[+-][0-9][0-9]) tz="${s#"${s%???}"}00" s="${s%???}" ;;
  esac
  s="${s%%.*}"
  s="${s%Z}"
  case "$s" in # (BSD date ignores whatever follows: an offset it was not given)
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]) ;;
    *) return 1 ;;
  esac
  if [ -n "$tz" ]; then
    tz="${tz/:/}"
    off=$(((10#${tz:1:2} * 60 + 10#${tz:3:2}) * 60))
    [ "${tz:0:1}" = - ] && off=$((-off))
  fi
  e="$(date -j -u -f '%Y-%m-%dT%H:%M:%S' "$s" '+%s' 2>/dev/null ||
    date -u -d "${s}Z" '+%s' 2>/dev/null)" || return 1
  printf '%s\n' "$((e - off))"
}

# cmm_mtime PATH — modification time in epoch seconds (GNU stat first; see
# cmm_mode_uid for why the order matters).
cmm_mtime() {
  stat -c '%Y' "$1" 2>/dev/null || stat -f '%m' "$1" 2>/dev/null
}

# ---------- configuration (S5: parsed, never sourced) ----------
cmm_config_dir() { printf '%s/scrubmac\n' "${XDG_CONFIG_HOME:-$HOME/.config}"; }

# One-time config-dir migration (2026 rename): cleanmymac ≤2.x used
# ~/.config/cleanmymac. Shared by the dispatcher and install.sh; runs before
# any config read. Tolerant of concurrent callers — never aborts the caller
# when the new dir ends up present (a racing cron and interactive run may
# both attempt the mv).
cmm_migrate_config_dir() {
  local base new old
  base="${XDG_CONFIG_HOME:-$HOME/.config}"
  new="$base/scrubmac"
  old="$base/cleanmymac"
  if [ -L "$old" ]; then
    # Ours (post-migration) or a dotfiles manager's. Only warn when it does
    # not resolve to the new dir — contents are never auto-migrated through
    # someone's stow/chezmoi symlink.
    local tgt_old tgt_new
    tgt_old="$(cd "$old" 2>/dev/null && pwd -P)" || tgt_old=""
    tgt_new="$(cd "$new" 2>/dev/null && pwd -P)" || tgt_new=""
    if [ -z "$tgt_new" ] || [ "$tgt_old" != "$tgt_new" ]; then
      warn "config symlink $old does not point at $new — repoint your dotfiles symlink (contents were not auto-migrated)"
    fi
    return 0
  fi
  if [ -d "$old" ]; then
    if [ ! -e "$new" ] && mv "$old" "$new" 2>/dev/null; then
      ln -s "$new" "$old" 2>/dev/null || true
      printf '%s\n' "(migrated config to $new; a symlink covers the old path)" >&2
      return 0
    fi
    if [ -e "$new" ] && [ -d "$old" ] && [ ! -L "$old" ]; then
      warn "both $new and $old exist; using the new one — merge or remove the old dir manually"
    fi
  fi
  return 0
}

# config_get KEY DEFAULT — read KEY from the config file. Only lines matching
# the strict KEY=value grammar are honored; anything else (shell syntax,
# command substitution, spaces) is ignored, so the config file can never
# execute code. Last valid occurrence wins.
config_get() {
  local v
  case "$1" in '' | *[!A-Za-z0-9_]*) printf '%s\n' "${2:-}" && return 0 ;; esac
  if v="$(cmm_config_lines | LC_ALL=C awk -v k="$1=" '
    index($0, k) == 1 && substr($0, length(k) + 1) ~ /^[A-Za-z0-9._\/-]*$/ { v = substr($0, length(k) + 1); f = 1 }
    END { if (f) print v; else exit 1 }')"; then
    printf '%s\n' "$v"
  else
    printf '%s\n' "${2:-}"
  fi
}

# cmm_config_lines [FILE] — the config file's lines as you wrote them, minus
# what an editor may add around them: a byte-order mark, CRLF line ends.
# Every reader and writer of the file goes through this.
cmm_config_lines() {
  local file="${1:-${CMM_CONFIG_FILE:-$(cmm_config_dir)/config}}"
  [ -f "$file" ] || return 0
  LC_ALL=C awk 'NR == 1 { sub(/^\357\273\277/, "") } { sub(/\r$/, ""); print }' "$file" 2>/dev/null || true
}

# setting KEY DEFAULT — the effective value of a setting for a cleaner:
# CMM_KEY from the environment (the dispatcher exports validated values for
# every built-in key), else the config file, else DEFAULT. Custom cleaners can
# use their own keys the same way.
setting() {
  case "$1" in
    '' | [!A-Z]* | *[!A-Z0-9_]*) printf '%s\n' "${2:-}" && return 0 ;;
  esac
  local v="CMM_$1"
  if [ -n "${!v:-}" ]; then
    printf '%s\n' "${!v}"
  else
    config_get "$1" "${2:-}"
  fi
}

# ---------- install-kind classification (D4) ----------
# cmm__version_manager PATH — print the version manager (mise, asdf, volta,
# nodenv, rbenv, pyenv) whose shims or installs PATH lives in.
cmm__version_manager() {
  case "$1" in
    */mise/shims/* | */mise/installs/*) printf 'mise\n' ;;
    */.asdf/shims/* | */.asdf/installs/* | */asdf/shims/* | */asdf/installs/*) printf 'asdf\n' ;;
    */.volta/*) printf 'volta\n' ;;
    */.nodenv/shims/* | */.nodenv/versions/*) printf 'nodenv\n' ;;
    */.rbenv/shims/* | */.rbenv/versions/*) printf 'rbenv\n' ;;
    */.pyenv/shims/* | */.pyenv/versions/*) printf 'pyenv\n' ;;
    *) return 1 ;;
  esac
}

# cmm_version_manager CMD — the version manager CMD runs through ('' if none).
cmm_version_manager() {
  local path
  path="$(command -v "$1" 2>/dev/null)" || return 0
  cmm__version_manager "$path" || cmm__version_manager "$(resolve_self "$path")" || true
}

# install_kind CMD — print npm | pipx | uv | manager | brew | standalone |
# none. The node_modules test comes first: npm globals on a brew- or
# mise-managed node live under that prefix but inside node_modules/. A
# version manager's shim resolves to the manager's own binary, so the PATH
# entry itself is classified before symlinks are followed. Homebrew owns
# what resolves into its Cellar, Caskroom or opt/ links — not everything
# under its prefix (on Intel Macs that is all of /usr/local).
install_kind() {
  local path real
  path="$(command -v "$1" 2>/dev/null)" || {
    printf 'none\n'
    return 0
  }
  real="$(resolve_self "$path")"
  case "$real" in
    */node_modules/*)
      printf 'npm\n'
      return 0
      ;;
    */pipx/venvs/*)
      printf 'pipx\n'
      return 0
      ;;
    */uv/tools/*)
      printf 'uv\n'
      return 0
      ;;
  esac
  if cmm__version_manager "$path" >/dev/null || cmm__version_manager "$real" >/dev/null; then
    printf 'manager\n'
    return 0
  fi
  case "$real" in
    */Cellar/* | */Caskroom/*)
      printf 'brew\n'
      return 0
      ;;
  esac
  if [ -z "${CMM_BREW_PREFIX+x}" ]; then
    CMM_BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
  fi
  if [ -n "$CMM_BREW_PREFIX" ]; then
    case "$real" in
      "$CMM_BREW_PREFIX"/opt/*)
        printf 'brew\n'
        return 0
        ;;
    esac
  fi
  printf 'standalone\n'
}

# ai_self_update TOOL [CMD…] — run TOOL's own updater only when it is a
# standalone install; package-manager-managed installs are updated by the
# npm/python/homebrew cleaners instead (self-updating them fights the manager).
ai_self_update() {
  local tool="$1"
  shift
  [ "${CMM_MODE:-run}" = status ] && return 0
  case "$(install_kind "$tool")" in
    npm) note "- $tool is npm-managed; the npm cleaner keeps it updated" ;;
    pipx) note "- $tool is pipx-managed; the python cleaner keeps it updated" ;;
    uv) note "- $tool is a uv tool; the python cleaner keeps it updated" ;;
    brew) note "- $tool is Homebrew-managed; the homebrew cleaner keeps it updated" ;;
    manager) note "- $tool runs through $(cmm_version_manager "$tool"); update it with that tool (not self-updated)" ;;
    none) note "- $tool not found" ;;
    *)
      if [ "$#" -gt 0 ]; then
        step "$@"
      else
        note "- $tool is installed standalone; update it via its own installer"
      fi
      ;;
  esac
}

# cmm_version_ge A B — true when dotted version A >= B (numeric fields
# compared left to right; a leading "v" or other prefix text is ignored).
cmm_version_ge() {
  awk -v a="$1" -v b="$2" 'BEGIN {
    sub(/^[^0-9]+/, "", a); sub(/^[^0-9]+/, "", b)
    na = split(a, x, /[^0-9]+/); nb = split(b, y, /[^0-9]+/)
    n = (na > nb) ? na : nb
    for (i = 1; i <= n; i++) {
      xi = x[i] + 0; yi = y[i] + 0
      if (xi > yi) exit 0
      if (xi < yi) exit 1
    }
    exit 0
  }'
}

# brew_cask_token TOOL — the Homebrew cask TOOL was installed from
# (…/Caskroom/<token>/<version>/…); prints nothing when it is not a cask.
brew_cask_token() {
  local path
  path="$(command -v "$1" 2>/dev/null)" || return 0
  path="$(resolve_self "$path")"
  case "$path" in
    */Caskroom/*/*)
      path="${path#*/Caskroom/}"
      printf '%s\n' "${path%%/*}"
      ;;
  esac
  return 0
}

# brew_cask_upgrade_self TOOL — for CLIs shipped as binary-only casks (no
# app to quit, no installer that wants a password), upgrading just that cask
# is safe even unattended. Returns 1 when TOOL is not a cask.
brew_cask_upgrade_self() {
  local token
  token="$(brew_cask_token "$1")"
  [ -n "$token" ] || return 1
  step brew upgrade --cask "$token"
}

# has_subcommand TOOL SUB — `TOOL --help` lists SUB as a command. Guards CLIs
# whose older releases would take an unknown word as a prompt and start an
# interactive session instead of failing.
has_subcommand() {
  local out
  out="$("$1" --help 2>&1 </dev/null || true)"
  awk -v s="$2" '$1 == s { f = 1 } END { exit !f }' <<EOF
$out
EOF
}

# ---------- supply-chain cooldown (S4) ----------
# cooldown_days — validated CMM_COOLDOWN_DAYS (0 when unset or invalid).
cooldown_days() {
  case "${CMM_COOLDOWN_DAYS:-0}" in
    '' | *[!0-9]*) printf '0\n' ;;
    *) printf '%s\n' "$((10#${CMM_COOLDOWN_DAYS:-0}))" ;;
  esac
}

# ---------- JSON ----------
# cmm__valid_utf8 — stdin with invalid UTF-8 dropped (JSON must be valid
# UTF-8; a cleaner's note may not be). By way of UTF-16, which has no room
# for code points past U+10FFFF: macOS's iconv lets those through a UTF-8 to
# UTF-8 pass. Unchanged where iconv is missing.
cmm__valid_utf8() {
  if command -v iconv >/dev/null 2>&1; then
    { iconv -c -f UTF-8 -t UTF-16LE | iconv -c -f UTF-16LE -t UTF-8; } 2>/dev/null || true
  else
    cat
  fi
}

# cmm_json_str STRING — print STRING as a JSON string literal.
cmm_json_str() {
  local s="$1"
  s="${s//\\/\\\\}"
  s="${s//\"/\\\"}"
  s="${s//$'\n'/\\n}"
  s="${s//$'\r'/\\r}"
  s="${s//$'\t'/\\t}"
  s="$(printf '%s' "$s" | LC_ALL=C tr -d '\000-\010\013\014\016-\037\177' | cmm__valid_utf8)"
  printf '"%s"' "$s"
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
