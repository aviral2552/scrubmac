#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: pre-commit
# group: Developer tools
# default: on
# summary: drop cached hook environments no recorded config uses (pre-commit gc)
# pre-commit: garbage-collect cached hook repositories and environments
# that no recorded .pre-commit-config.yaml still uses. The worst case is a
# re-install of a hook environment on the next commit. gc treats a config it
# cannot read as deleted, so it is skipped while a recorded config sits where
# this run cannot see it (a privacy-protected folder, an unmounted volume).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless pre-commit

pc_home="${PRE_COMMIT_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/pre-commit}"

# unlistable DIR — DIR exists, but this process cannot list it. Scheduled
# runs (launchd agents) get "Operation not permitted" for ~/Desktop,
# ~/Documents, ~/Downloads and iCloud Drive unless granted access.
unlistable() {
  [ -d "$1" ] || return 1
  if ls "$1" >/dev/null 2>&1; then
    return 1
  fi
  return 0
}

# pc_sql DB QUERY — one plain value per line, whatever your sqliterc says
# (-init /dev/null: no ~/.sqliterc or $XDG_CONFIG_HOME/sqlite3/sqliterc,
# whose .mode box/json/… would garble the paths), read-only, waiting up to
# 5 s for a lock pre-commit holds.
pc_sql() {
  sqlite3 -init /dev/null -batch -list -noheader -readonly -cmd '.timeout 5000' "$1" "$2" 2>/dev/null
}

# pc_blind_spot — print why `pre-commit gc` must not run now (and succeed),
# or fail when it may. gc counts every recorded config it cannot read as
# deleted (cfgv's isfile() is false on EPERM) and removes the hook
# environments only those configs use. With sqlite3, the configs recorded in
# pre-commit's db.db are checked: one that is missing while its nearest
# existing folder cannot be listed, or that lives on an unmounted volume, is
# unknown rather than deleted — and a db that cannot be read (pre-commit
# holding a lock past the 5 s busy timeout) blocks gc too. Without sqlite3,
# any unreadable privacy-protected folder blocks gc.
pc_blind_spot() {
  local db="$pc_home/db.db" paths p a vol n
  [ -f "$db" ] || return 1 # nothing recorded: gc has nothing to misjudge
  if have sqlite3; then
    if ! paths="$(pc_sql "$db" 'SELECT path FROM configs')"; then
      # a store that has never recorded a config has no configs table yet
      n="$(pc_sql "$db" "SELECT count(*) FROM sqlite_master WHERE type = 'table' AND name = 'configs'")" || n=''
      [ "$n" = 0 ] && return 1
      printf '%s\n' "pre-commit's database ($db) could not be read"
      return 0
    fi
    while IFS= read -r p; do
      case "$p" in /?*) ;; *) continue ;; esac
      [ -e "$p" ] && continue
      case "$p" in
        /Volumes/?*/*)
          vol="${p#/Volumes/}"
          vol="/Volumes/${vol%%/*}"
          if [ ! -d "$vol" ]; then
            printf '%s\n' "a recorded config is on $vol, which is not mounted"
            return 0
          fi
          ;;
      esac
      a="${p%/*}"
      while [ -n "$a" ] && [ ! -d "$a" ]; do a="${a%/*}"; done
      if unlistable "${a:-/}"; then
        printf '%s\n' "a recorded config is inside ${a:-/}, which this run cannot read"
        return 0
      fi
    done <<EOF
$paths
EOF
    return 1
  fi
  for a in "$HOME/Desktop" "$HOME/Documents" "$HOME/Downloads" "$HOME/Library/Mobile Documents"; do
    if unlistable "$a"; then
      printf '%s\n' "$a cannot be read by this run"
      return 0
    fi
  done
  return 1
}

cache_dir "$pc_home"
skip_unless_cleaning

if cleaning; then # (not in `scrubmac status`)
  if why="$(pc_blind_spot)"; then
    note "- skipping 'pre-commit gc': $why — gc would count its configs as deleted and remove their hook environments; run 'pre-commit gc' yourself from a terminal that can read it"
    summary_note "pre-commit gc skipped: $why"
  else
    step pre-commit gc
  fi
fi
