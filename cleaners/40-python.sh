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
# and pipx's --cooldown DAYS (pipx >= 1.16). Both remember the cutoff (uv in
# each tool receipt, pipx in pipx_metadata.json), so with the cooldown off
# the cutoffs are cleared explicitly (uv >= 0.11.24: --exclude-newer false;
# pipx: --cooldown 0) — unless your own uv/pipx settings define one.
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
# Mirrors uv/axoupdater's lookup: $AXOUPDATER_CONFIG_PATH, else
# $XDG_CONFIG_HOME/uv then ~/.config/uv (macOS included), and the receipt's
# install_prefix must be where this uv runs from (minus a trailing bin/).
uv_receipt_ok() {
  local f exe dir root prefix
  exe="$(command -v uv)" || return 1
  exe="$(resolve_self "$exe")"
  dir="$(cd "${exe%/*}" && pwd -P)" || return 1
  if [ -n "${AXOUPDATER_CONFIG_PATH:-}" ]; then
    set -- "$AXOUPDATER_CONFIG_PATH/uv-receipt.json"
  else
    set -- "$HOME/.config/uv/uv-receipt.json"
    if [ -n "${XDG_CONFIG_HOME:-}" ]; then
      set -- "$XDG_CONFIG_HOME/uv/uv-receipt.json" "$@"
    fi
  fi
  for f in "$@"; do
    [ -f "$f" ] || continue
    prefix="$(awk 'match($0, /"install_prefix"[[:space:]]*:[[:space:]]*"[^"]*"/) {
      s = substr($0, RSTART, RLENGTH); sub(/^"install_prefix"[[:space:]]*:[[:space:]]*"/, "", s)
      sub(/"$/, "", s); print s; exit }' "$f")" || prefix=''
    [ -n "$prefix" ] || continue
    root="$(cd "$prefix" 2>/dev/null && pwd -P)" || continue
    if [ "${dir##*/}" = bin ] && [ "${root##*/}" != bin ]; then
      [ "${dir%/*}" = "$root" ] && return 0
    elif [ "$dir" = "$root" ]; then
      return 0
    fi
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

# uv_own_cutoff — your own uv configuration sets exclude-newer (then
# scrubmac leaves the receipts' cutoffs alone).
uv_own_cutoff() {
  [ -n "${UV_EXCLUDE_NEWER:-}" ] && return 0
  grep -Eqs '^[[:space:]]*exclude-newer[[:space:]]*=' \
    "${XDG_CONFIG_HOME:-$HOME/.config}/uv/uv.toml" /etc/uv/uv.toml
}

# uv_upgrade_uncooled — upgrade uv tools with the cooldown off: first clear
# the cutoffs an earlier cooldown left in tool receipts (uv >= 0.11.24),
# then upgrade everything.
uv_upgrade_uncooled() {
  local tools n t
  tools="$(uv_cutoff_tools)"
  if [ -n "$tools" ]; then
    n="$(printf '%s\n' "$tools" | awk 'NF { c++ } END { print c + 0 }')"
    if uv_own_cutoff; then
      note "- $n uv tool(s) keep an exclude-newer cutoff in their receipts; your uv settings define exclude-newer, so they are left as they are"
    elif cmm_version_ge "$(uv_version)" 0.11.24; then
      note "- clearing the exclude-newer cutoff an earlier cooldown left in $n uv tool receipt(s)"
      while IFS= read -r t <&3; do
        [ -n "$t" ] && step uv tool upgrade "$t" --exclude-newer false
      done 3<<EOF
$tools
EOF
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
      if cmm_version_ge "$(uv_version)" 0.11.4; then
        step uv tool upgrade --all --exclude-newer "$days days"
      else
        step uv tool upgrade --all --exclude-newer "$(date_days_ago "$days")"
      fi
    else
      uv_upgrade_uncooled
    fi
  fi
  if have pipx; then
    if [ "$days" -gt 0 ]; then
      if pipx_has_cooldown; then
        step pipx upgrade-all --cooldown "$days"
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
