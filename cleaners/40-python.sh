#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: uv pipx python3
# group: Python
# default: on
# summary: uv self-update, tool upgrades and cache prune; pipx upgrades; pip cache purge (cooldown-aware)
# Python tooling: uv self-update (standalone installs only), uv tool upgrades,
# pipx package upgrades, uv cache prune, and pip cache purge. The supply-chain
# cooldown is passed natively: uv's --exclude-newer as a relative "N days"
# span (uv >= 0.11.4 stores it as a span in tool receipts, so it never goes
# stale; neither uv nor pipx downgrades an installed tool) and pipx's
# --cooldown DAYS (pipx >= 1.16).
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

# uv_stale_receipts — tools whose receipt pins an ABSOLUTE exclude-newer
# date (written by a cooldown on older uv/scrubmac): plain upgrades of
# those tools stay frozen at that date.
uv_stale_receipts() {
  local dir f n=0
  dir="$(uv tool dir --color never 2>/dev/null)" || {
    echo 0
    return 0
  }
  for f in "$dir"/*/uv-receipt.toml; do
    [ -f "$f" ] || continue
    if grep -q '^exclude-newer = ' "$f" && ! grep -q '^exclude-newer-span' "$f"; then
      n=$((n + 1))
    fi
  done
  echo "$n"
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
    ai_self_update uv uv self update
    if [ "$days" -gt 0 ]; then
      if cmm_version_ge "$(uv_version)" 0.11.4; then
        step uv tool upgrade --all --exclude-newer "$days days"
      else
        step uv tool upgrade --all --exclude-newer "$(date_days_ago "$days")"
      fi
    else
      step uv tool upgrade --all
      stale="$(uv_stale_receipts)"
      if [ "${stale:-0}" -gt 0 ]; then
        note "- $stale uv tool(s) are pinned to a past --exclude-newer date in their receipts (from an earlier cooldown); 'uv tool upgrade --all --exclude-newer false' (uv >= 0.11.24) releases them"
        summary_note "$stale uv tool(s) pinned by a stale exclude-newer date"
      fi
    fi
  fi
  if have pipx; then
    if [ "$days" -eq 0 ]; then
      step pipx upgrade-all
    elif pipx_has_cooldown; then
      step pipx upgrade-all --cooldown "$days"
    else
      note "- cooldown active (${days}d) but this pipx predates --cooldown (1.16): pipx upgrades are held"
      summary_note "pipx upgrades held by the ${days}-day cooldown (pipx < 1.16)"
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
