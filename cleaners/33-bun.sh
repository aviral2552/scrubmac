#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: bun
# group: JavaScript
# default: on
# summary: self-update standalone Bun (held during a cooldown), update global packages (cooldown-aware), clear the cache
# Bun: self-update standalone installs (`bun upgrade` replaces the binary in
# place, so Homebrew/npm-managed copies are left to their managers; it can
# only install the newest release, so it is held while the supply-chain
# cooldown is on), update global packages — under the cooldown each to the
# newest release its saved range allows that is at least COOLDOWN_DAYS old,
# never backwards — and clear the global cache. Bun's own
# --minimum-release-age is deliberately not used: `bun update -g` with it
# fails whenever an installed release is newer than the cutoff, and
# downgrades packages when a range allows it.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

TAB=$'\t'
# lib/registry.js (the registry resolver) sits next to the lib/common.sh above
REGISTRY_JS="${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"
REGISTRY_JS="${REGISTRY_JS%/*}/registry.js"

# reg_resolve NAME CURRENT CUTOFF MODE — the registry verdict for NAME (the
# rules are in lib/registry.js) in REG_VERDICT — pick, held, none, unsuitable,
# or error when the registry could not be read — and REG_VERSION. Releases
# that are deprecated, or whose engines.node excludes this node, are passed
# over (at most three times) with a note.
reg_resolve() {
  local name="$1" info out cands kind v why
  REG_VERDICT=error
  REG_VERSION=''
  info="$(npm view "$name" time versions dist-tags --json 2>/dev/null)" || return 0
  out="$(printf '%s' "$info" | node "$REGISTRY_JS" pick "$name" "$2" "$3" "$4")" || return 0
  case "$out" in
    pick"$TAB"*) cands="${out#pick"$TAB"}" ;;
    held"$TAB"*)
      REG_VERDICT=held
      REG_VERSION="${out#held"$TAB"}"
      return 0
      ;;
    *)
      REG_VERDICT=none
      return 0
      ;;
  esac
  info="$(npm view "$name@${cands//$TAB/ || }" name version deprecated engines --json 2>/dev/null)" || info=''
  out="$(printf '%s' "$info" | node "$REGISTRY_JS" verify "${cands//$TAB/,}" --npm "$(command -v npm)")" ||
    out="ok$TAB${cands%%"$TAB"*}"
  REG_VERDICT=unsuitable
  while IFS="$TAB" read -r kind v why; do
    case "$kind" in
      skip) note "- $name $v: $why — trying the next release" ;;
      ok)
        REG_VERDICT=pick
        REG_VERSION="$v"
        ;;
    esac
  done <<EOF
$out
EOF
  return 0
}

# can_resolve — node, npm and lib/registry.js are there for registry lookups.
can_resolve() { have node && have npm && [ -f "$REGISTRY_JS" ]; }

# bun_self_update DAYS — `bun upgrade` (standalone installs only) cannot be
# told a version: it always installs the newest release, so while the
# cooldown is on it is held — with a note only when a newer Bun exists.
bun_self_update() {
  local days="$1" cur info verdict
  if [ "$days" -eq 0 ] || [ "$(install_kind bun)" != standalone ]; then
    ai_self_update bun bun upgrade
    return 0
  fi
  cur="$(bun --version 2>/dev/null)" || cur=''
  if [ -n "$cur" ] && can_resolve; then
    info="$(npm view bun time versions dist-tags --json 2>/dev/null)" || info=''
    verdict="$(printf '%s' "$info" | node "$REGISTRY_JS" pick bun "$cur" "$(cmm_now_iso)" latest 2>/dev/null)" || verdict=''
    if [ "$verdict" = none ]; then
      note "- bun $cur is up to date"
      return 0
    fi
  fi
  note "- bun upgrade skipped during the ${days}-day cooldown: it always installs the newest release — run 'bun upgrade' yourself"
  summary_note "bun upgrade held by the ${days}-day cooldown — run 'bun upgrade' yourself"
}

# bun_global_dir — where `bun add -g` installs (the header of `bun pm ls -g`
# honors bunfig's globalDir; the fallback is Bun's default layout).
bun_global_dir() {
  local d
  d="$(bun pm ls -g 2>/dev/null | sed -n '1s/ node_modules (.*$//p')" || d=''
  printf '%s\n' "${d:-${BUN_INSTALL_GLOBAL_DIR:-${BUN_INSTALL:-$HOME/.bun}/install/global}}"
}

# bun_skip_note NAME REASON — why a global package is left alone.
bun_skip_note() {
  case "$2" in
    pinned:*) note "- $1: pinned to ${2#pinned:} — left alone, as 'bun update -g' would" ;;
    range:*) note "- $1: its saved range '${2#range:}' cannot be moved by version — left to 'bun update -g'" ;;
    alias) note "- skipping $1: an aliased install (npm:…) — updating it by name would install a different package" ;;
    local | linked) note "- skipping $1: linked/local install (bun link, a path, file:, git)" ;;
    *) note "- skipping $1 ($2)" ;;
  esac
}

# bun_cooldown_update DAYS — each global package to the newest release its
# saved range allows that is at least DAYS old, via `bun update -g
# NAME@VERSION` (which keeps the range's ^ or ~ operator).
bun_cooldown_update() {
  local days="$1" cutoff rows kind name cur mode held=0
  if ! can_resolve; then
    note "- cooldown active (${days}d) but node/npm (needed for registry lookups) not found: global updates are held"
    summary_note "global updates held (node/npm not found for the cooldown)"
    return 0
  fi
  cutoff="$(date_days_ago "$days")"
  note "- cooldown: updating global packages only to releases published before $cutoff (${days}d)"
  if ! rows="$(node "$REGISTRY_JS" bun-globals "$(bun_global_dir)")"; then
    warn "could not read Bun's global packages"
    cmm_fail_later
    return 0
  fi
  while IFS="$TAB" read -r kind name cur mode <&3; do
    case "$kind" in
      skip)
        bun_skip_note "$name" "$cur"
        continue
        ;;
      pkg) ;;
      *) continue ;;
    esac
    reg_resolve "$name" "$cur" "$cutoff" "$mode"
    case "$REG_VERDICT" in
      pick) step bun update -g "$name@$REG_VERSION" ;;
      held)
        held=$((held + 1))
        note "- $name $cur: every newer release its range allows is under ${days} days old — held"
        ;;
      unsuitable)
        held=$((held + 1))
        note "- $name $cur: the newest releases old enough are deprecated or need a newer Node.js — left as is"
        ;;
      error)
        warn "registry lookup failed for $name"
        cmm_fail_later
        ;;
    esac
  done 3<<EOF
$rows
EOF
  [ "$held" -gt 0 ] && summary_note "$held global update(s) held by the ${days}-day cooldown"
  return 0
}

skip_unless bun

cache_dir_cmd bun pm cache -g

if updating; then
  days="$(cooldown_days)"
  bun_self_update "$days"
  if [ "$days" -eq 0 ]; then
    step bun update -g
  else
    bun_cooldown_update "$days"
  fi
fi

if cleaning; then
  # -g: without it Bun wants a package.json in the current directory
  step bun pm cache rm -g
fi
