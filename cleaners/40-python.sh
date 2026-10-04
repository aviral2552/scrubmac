#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: uv pipx python3
# group: Python
# default: on
# summary: uv self-update (standalone installer only), tool upgrades and cache prune; pipx upgrades; pip cache purge (cooldown-aware)
# Python tooling: uv self-update (only for the copy uv's standalone installer
# manages: it has an install receipt — other installs refuse and exit 2), uv
# tool upgrades, pipx package upgrades, uv cache prune, and pip cache purge.
# The supply-chain cooldown is passed natively: uv's --exclude-newer as a
# relative "N days" span (uv >= 0.11.4 stores it as a span in tool receipts,
# so it never goes stale; neither uv nor pipx downgrades an installed tool)
# and pipx's --cooldown DAYS (pipx >= 1.16) — or your own exclude-newer /
# PIPX_COOLDOWN when stricter, since the flags override both. uv and pipx
# remember the cutoff (uv in each tool receipt, pipx in pipx_metadata.json),
# so with the cooldown off the cutoffs are cleared explicitly (uv >= 0.11.24:
# --exclude-newer false; pipx: --cooldown 0) — unless your own uv/pipx
# settings define one.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

if ! have uv && ! have pipx && ! have python3; then
  skip "skipping: no python tooling found (uv, pipx, python3)"
fi

uv_version() { uv --version 2>/dev/null | awk '{ print $2; exit }'; }

# pipx_has_cooldown — pipx >= 1.16 understands --cooldown DAYS.
pipx_has_cooldown() {
  local h
  h="$(pipx upgrade-all --help 2>&1 || true)"
  case "$h" in *--cooldown*) return 0 ;; esac
  return 1
}

# uv_cache_busy — heuristic for uv releases without UV_LOCK_TIMEOUT
# (< 0.9.16), where `uv cache prune` waits for a busy cache INDEFINITELY:
# a uv process, or anything executing from inside the cache (uvx-served
# tools such as MCP servers run straight out of it and never exit).
uv_cache_busy() {
  pgrep -x uv >/dev/null 2>&1 && return 0
  local cdir
  cdir="$(uv cache dir --color never 2>/dev/null)" || return 1
  [ -n "$cdir" ] && pgrep -f "$cdir/" >/dev/null 2>&1
}

# uv_prune — prune the cache without ever hanging on a busy one. uv >=
# 0.9.16 waits at most UV_LOCK_TIMEOUT seconds, then exits 2 with
# "Timeout"; a busy cache is skipped with a note, never --force'd (that
# would delete environments running processes execute from).
uv_prune() {
  local out rc=0
  if ! cmm_version_ge "$(uv_version)" 0.9.16; then
    if uv_cache_busy; then
      note "- uv cache is in use by running processes (uvx-served tools?) — skipping 'uv cache prune' this run"
      summary_note "uv cache in use — prune skipped"
      return 0
    fi
    step uv cache prune
    return 0
  fi
  printf '%s+ %s%s\n' "$CMM_DIM" "uv cache prune" "$CMM_RESET"
  [ "${CMM_DRY_RUN:-0}" = 1 ] && return 0
  out="$(UV_LOCK_TIMEOUT=15 uv cache prune 2>&1)" || rc=$?
  [ -n "$out" ] && printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then
    case "$out" in
      *"Timeout ("*"waiting for lock"* | *"is another uv process running"*)
        note "- uv cache is in use by running processes (uvx-served tools?) — prune skipped this run"
        summary_note "uv cache in use — prune skipped"
        ;;
      *)
        warn "'uv cache prune' exited $rc — continuing with the remaining steps"
        cmm_fail_later
        ;;
    esac
  fi
}

# uv_receipt_ok — uv's standalone installer left an install receipt for
# THIS uv. `uv self update` refuses (exit 2) otherwise: for uv from pip,
# cargo, conda, mise/asdf…, and when the receipt belongs to another copy.
# Mirrors uv/axoupdater: the FIRST receipt file that exists decides — in
# the current directory with $AXOUPDATER_CONFIG_WORKING_DIR, else in
# $AXOUPDATER_CONFIG_PATH, else $XDG_CONFIG_HOME/uv then ~/.config/uv (macOS
# included) — and its install_prefix must be where this uv runs from (minus
# a trailing bin/).
uv_receipt_ok() {
  local f exe dir root prefix
  exe="$(command -v uv)" || return 1
  exe="$(resolve_self "$exe")"
  dir="$(cd "${exe%/*}" && pwd -P)" || return 1
  if [ -n "${AXOUPDATER_CONFIG_WORKING_DIR+x}" ]; then
    set -- "$PWD/uv-receipt.json"
  elif [ -n "${AXOUPDATER_CONFIG_PATH:-}" ]; then
    set -- "$AXOUPDATER_CONFIG_PATH/uv-receipt.json"
  else
    set -- "$HOME/.config/uv/uv-receipt.json"
    if [ -n "${XDG_CONFIG_HOME:-}" ] && [ -d "$XDG_CONFIG_HOME/uv" ]; then
      set -- "$XDG_CONFIG_HOME/uv/uv-receipt.json" "$@"
    fi
  fi
  for f in "$@"; do
    [ -f "$f" ] || continue
    prefix="$(awk 'match($0, /"install_prefix"[[:space:]]*:[[:space:]]*"[^"]*"/) {
      s = substr($0, RSTART, RLENGTH); sub(/^"install_prefix"[[:space:]]*:[[:space:]]*"/, "", s)
      sub(/"$/, "", s); print s; exit }' "$f")" || prefix=''
    [ -n "$prefix" ] || return 1 # unreadable: uv refuses too
    root="$(cd "$prefix" 2>/dev/null && pwd -P)" || return 1
    if [ "${dir##*/}" = bin ] && [ "${root##*/}" != bin ]; then
      [ "${dir%/*}" = "$root" ]
      return
    fi
    [ "$dir" = "$root" ]
    return
  done
  return 1
}

# uv_self_update — `uv self update` for the standalone installer's uv only.
uv_self_update() {
  case "$(install_kind uv)" in
    standalone)
      if uv_receipt_ok; then
        ai_self_update uv uv self update
      else
        note "- uv was not installed by its standalone installer (no install receipt for this copy) — not self-updated; update it with the tool that installed it"
      fi
      ;;
    *) ai_self_update uv ;; # explains which manager owns it
  esac
}

# uv_cutoff_tools — tools whose receipts still carry an exclude-newer cutoff
# (an absolute date and/or a relative span) from an earlier cooldown: a plain
# `uv tool upgrade` keeps honoring it.
uv_cutoff_tools() {
  local dir f
  dir="$(uv tool dir --color never 2>/dev/null)" || return 0
  for f in "$dir"/*/uv-receipt.toml; do
    [ -f "$f" ] || continue
    if grep -Eq '^exclude-newer(-span)? = "' "$f"; then
      f="${f%/uv-receipt.toml}"
      printf '%s\n' "${f##*/}"
    fi
  done
}

# uv_user_exclude_newer — your own exclude-newer, as uv reads it for tool
# commands: UV_EXCLUDE_NEWER, else the top-level key of UV_CONFIG_FILE, or of
# the user config (${XDG_CONFIG_HOME:-~/.config}/uv/uv.toml) and then the
# system one (/etc/uv/uv.toml). Prints nothing when none is set.
uv_user_exclude_newer() {
  local f v
  if [ -n "${UV_EXCLUDE_NEWER:-}" ]; then
    printf '%s\n' "$UV_EXCLUDE_NEWER"
    return 0
  fi
  case "${UV_NO_CONFIG:-}" in 1 | true | yes) return 0 ;; esac
  if [ -n "${UV_CONFIG_FILE:-}" ]; then
    set -- "$UV_CONFIG_FILE"
  else
    set -- "${XDG_CONFIG_HOME:-$HOME/.config}/uv/uv.toml" /etc/uv/uv.toml
  fi
  for f in "$@"; do
    [ -f "$f" ] || continue
    v="$(awk '/^[[:space:]]*\[/ { exit }
      /^[[:space:]]*exclude-newer[[:space:]]*=/ {
        sub(/^[^=]*=[[:space:]]*/, ""); sub(/[[:space:]]*(#.*)?$/, "")
        gsub(/^["\047]|["\047]$/, ""); print; exit }' "$f")"
    if [ -n "$v" ]; then
      printf '%s\n' "$v"
      return 0
    fi
  done
  return 0
}

# uv_age_seconds VALUE — how far back an exclude-newer VALUE reaches, in
# seconds: an RFC 3339 timestamp (its offset honored), a date — which uv
# reads as the END of that day in local time, i.e. the next local midnight
# (2026-09-27 in UTC+5:30 is 2026-09-27T18:30:00Z) —, a "friendly" duration
# (24 hours, 1 week, 30 days) or an ISO 8601 one (P7D, PT24H). 0 for false;
# nothing when it cannot be read.
uv_age_seconds() {
  local v="$1" ep now
  case "$v" in
    false) echo 0 ;;
    [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] | [0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T*)
      case "$v" in
        *T*) ep="$(cmm_iso_to_epoch "$v")" || return 0 ;;
        *)
          ep="$(date -j -v+1d -f '%Y-%m-%d %H:%M:%S' "$v 00:00:00" '+%s' 2>/dev/null ||
            date -d "$v 1 day" '+%s' 2>/dev/null)" || return 0
          ;;
      esac
      now="$(date -u '+%s')"
      echo $((now > ep ? now - ep : 0))
      ;;
    *)
      awk -v v="$v" 'BEGIN {
        s = tolower(v); gsub(/,/, " ", s); gsub(/^ +| +$/, "", s); total = 0; ok = 0
        if (s ~ /^p/) {
          t = 0; rest = substr(s, 2)
          while (rest != "") {
            if (rest ~ /^t/) { t = 1; rest = substr(rest, 2); continue }
            if (!match(rest, /^[0-9]+(\.[0-9]+)?[ymwdhs]/)) { ok = 0; break }
            n = substr(rest, 1, RLENGTH - 1) + 0; u = substr(rest, RLENGTH, 1); rest = substr(rest, RLENGTH + 1)
            if (u == "y") total += n * 31536000
            else if (u == "m") total += (t ? n * 60 : n * 2592000)
            else if (u == "w") total += n * 604800
            else if (u == "d") total += n * 86400
            else if (u == "h") total += n * 3600
            else total += n
            ok = 1
          }
        } else {
          while (s != "") {
            if (!match(s, /^[0-9]+(\.[0-9]+)? *[a-z]+ */)) { ok = 0; break }
            tok = substr(s, 1, RLENGTH); s = substr(s, RLENGTH + 1)
            match(tok, /^[0-9]+(\.[0-9]+)?/); n = substr(tok, 1, RLENGTH) + 0
            u = substr(tok, RLENGTH + 1); gsub(/ /, "", u)
            if (u ~ /^(s|secs?|seconds?)$/) total += n
            else if (u ~ /^(m|mins?|minutes?)$/) total += n * 60
            else if (u ~ /^(h|hrs?|hours?)$/) total += n * 3600
            else if (u ~ /^(d|days?)$/) total += n * 86400
            else if (u ~ /^(w|wks?|weeks?)$/) total += n * 604800
            else if (u ~ /^(mos?|months?)$/) total += n * 2592000
            else if (u ~ /^(y|yrs?|years?)$/) total += n * 31536000
            else { ok = 0; break }
            ok = 1
          }
        }
        if (ok) printf "%d\n", total
      }'
      ;;
  esac
}

# uv_cooldown_value DAYS — the --exclude-newer to pass under the cooldown:
# DAYS as a relative span (uv >= 0.11.4; older uv an absolute date) — or
# your own exclude-newer, verbatim, when it reaches further back (the flag
# beats both your settings and the tool receipts, so it must not relax
# them), or when it cannot be read.
uv_cooldown_value() {
  local user age
  user="$(uv_user_exclude_newer)"
  if [ -n "$user" ] && [ "$user" != false ]; then
    age="$(uv_age_seconds "$user")"
    if [ -z "$age" ] || [ "$age" -gt $(($1 * 86400)) ]; then
      printf '%s\n' "$user"
      return 0
    fi
  fi
  if cmm_version_ge "$(uv_version)" 0.11.4; then
    printf '%s days\n' "$1"
  else
    date_days_ago "$1"
  fi
}

# uv_upgrade_uncooled — upgrade uv tools with the cooldown off: first clear
# the cutoff an earlier cooldown left in the receipts of the tools it is
# holding back (uv >= 0.11.24; `uv tool list --outdated --exclude-newer false`
# names them — uv rewrites a receipt only when its tool upgrades), unless
# your own uv settings set exclude-newer; then upgrade everything.
uv_upgrade_uncooled() {
  local tools n outdated t cleared=0
  tools="$(uv_cutoff_tools)"
  if [ -n "$tools" ]; then
    n="$(printf '%s\n' "$tools" | awk 'NF { c++ } END { print c + 0 }')"
    if [ -n "$(uv_user_exclude_newer)" ]; then
      note "- $n uv tool(s) keep an exclude-newer cutoff in their receipts; your uv settings define exclude-newer, so they are left as they are"
    elif cmm_version_ge "$(uv_version)" 0.11.24; then
      outdated=" $(uv tool list --outdated --exclude-newer false --color never 2>/dev/null |
        awk '/^[^ -][^ ]* v[0-9]/ { printf "%s ", $1 }')" || outdated=' '
      while IFS= read -r t <&3; do
        [ -n "$t" ] || continue
        case "$outdated" in
          *" $t "*)
            step uv tool upgrade "$t" --exclude-newer false
            cleared=$((cleared + 1))
            ;;
        esac
      done 3<<EOF
$tools
EOF
      [ "$cleared" -gt 0 ] && note "- cleared the exclude-newer cutoff an earlier cooldown left in $cleared uv tool receipt(s)"
    else
      note "- $n uv tool(s) keep an exclude-newer cutoff from an earlier cooldown in their receipts, and this uv (< 0.11.24) cannot clear it: plain upgrades of them stay held back — upgrade uv, or reinstall them with 'uv tool install --force'"
      summary_note "$n uv tool(s) still held back by an exclude-newer cutoff in their receipts"
    fi
  fi
  step uv tool upgrade --all
}

if have uv; then
  cache_dir_cmd uv cache dir --color never
  if cmm_version_ge "$(uv_version)" 0.10.10; then
    report uv tool list --outdated
  fi
fi
if have python3; then
  cache_dir_cmd python3 -m pip cache dir
fi

if updating; then
  days="$(cooldown_days)"
  if have uv; then
    uv_self_update
    if [ "$days" -gt 0 ]; then
      step uv tool upgrade --all --exclude-newer "$(uv_cooldown_value "$days")"
    else
      uv_upgrade_uncooled
    fi
  fi
  if have pipx; then
    if [ "$days" -gt 0 ]; then
      if pipx_has_cooldown; then
        # PIPX_COOLDOWN is pipx's own default: never pass a smaller value
        pc="${PIPX_COOLDOWN:-0}"
        case "$pc" in '' | *[!0-9]*) pc=0 ;; esac
        [ "$pc" -gt "$days" ] || pc="$days"
        step pipx upgrade-all --cooldown "$pc"
      else
        note "- cooldown active (${days}d) but this pipx predates --cooldown (1.16): pipx upgrades are held"
        summary_note "pipx upgrades held by the ${days}-day cooldown (pipx < 1.16)"
      fi
    elif [ -z "${PIPX_COOLDOWN:-}" ] && pipx_has_cooldown; then
      step pipx upgrade-all --cooldown 0 # pipx remembers an earlier --cooldown; 0 is its opt-out
    else
      step pipx upgrade-all
    fi
  fi
fi

if cleaning; then
  if have uv; then
    uv_prune
  fi
  if have python3 && python3 -m pip --version >/dev/null 2>&1; then
    try python3 -m pip cache purge # exits 1 when pip's cache is disabled
  fi
fi
