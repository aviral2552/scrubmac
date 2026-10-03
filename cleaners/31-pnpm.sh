#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: pnpm
# group: JavaScript
# default: on
# summary: update global packages within their major (cooldown-aware), self-update standalone pnpm, prune the store
# pnpm: move each global package to the newest release of its current major
# (what `pnpm update -g` does for the ^ ranges pnpm saves) — under the
# supply-chain cooldown, only to releases at least COOLDOWN_DAYS old, never
# backwards — self-update standalone installs (to the newest release old
# enough), and drop unreferenced packages from the content-addressable store.
# pnpm's own minimumReleaseAge is deliberately not used: with it, `pnpm
# update -g` and `pnpm self-update` fail outright whenever an installed
# release is newer than the cutoff, and pnpm 10's self-update ignores it.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

TAB=$'\t'
# lib/registry.js (the registry resolver) sits next to the lib/common.sh above
REGISTRY_JS="${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"
REGISTRY_JS="${REGISTRY_JS%/*}/registry.js"

# reg_resolve NAME CURRENT CUTOFF MODE [VERIFY-FLAG] — the registry verdict
# for NAME (the rules are in lib/registry.js) in REG_VERDICT — pick, held,
# none, unsuitable, or error when the registry could not be read — and
# REG_VERSION. Releases that are deprecated, or whose engines.node excludes
# this node (unless VERIFY-FLAG is --no-engines), are passed over (at most
# three times) with a note.
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
  out="$(printf '%s' "$info" | node "$REGISTRY_JS" verify "${cands//$TAB/,}" ${5+"$5"} --npm "$(command -v npm)")" ||
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

# pnpm_self_update DAYS — standalone installs only (Corepack/Homebrew/npm
# copies are left to their managers); under the cooldown, to the newest
# release at least DAYS old, named explicitly.
pnpm_self_update() {
  local days="$1" cur
  if [ "$(install_kind pnpm)" != standalone ]; then
    ai_self_update pnpm # explains which manager owns it
    return 0
  fi
  if [ "$days" -eq 0 ]; then
    ai_self_update pnpm pnpm self-update
    return 0
  fi
  if ! can_resolve; then
    note "- pnpm self-update held by the ${days}-day cooldown: node/npm (needed to pick a release) not found"
    summary_note "pnpm self-update held (node/npm not found for the cooldown)"
    return 0
  fi
  cur="$(pnpm --version 2>/dev/null)" || cur=''
  reg_resolve pnpm "$cur" "$(date_days_ago "$days")" latest --no-engines
  case "$REG_VERDICT" in
    pick) ai_self_update pnpm pnpm self-update "$REG_VERSION" ;;
    held)
      note "- pnpm $cur: pnpm $REG_VERSION is under ${days} days old — self-update held"
      summary_note "pnpm self-update held by the ${days}-day cooldown"
      ;;
    unsuitable) note "- pnpm $cur: the newer releases old enough are deprecated — not self-updated" ;;
    none) note "- pnpm $cur is up to date" ;;
    *)
      warn "registry lookup failed for pnpm"
      cmm_fail_later
      ;;
  esac
}

# pnpm_skip_note NAME REASON — why a global package is left alone.
pnpm_skip_note() {
  case "$2" in
    self) ;; # pnpm itself: pnpm self-update handles it
    alias) note "- skipping $1: an aliased install (npm:…) — updating it by name would install a different package" ;;
    local) note "- skipping $1: linked/local install (link:, file: or git)" ;;
    group:*) note "- skipping $1: installed together with ${2#group:} (pnpm add -g a,b), which cannot be reinstalled by version" ;;
    *) note "- skipping $1 ($2)" ;;
  esac
}

# pnpm_update_group CUTOFF MEMBER… — move one install group's packages
# (NAME@VERSION each) to their picks. pnpm >= 11 replaces a whole group when
# any member is re-added, so a group is re-added as a whole, comma-joined;
# `pnpm add -g` with an explicit version records it as an exact pin.
pnpm_update_group() {
  local cutoff="$1" m name cur joined specs=() changed=0
  shift
  for m in "$@"; do
    name="${m%@*}"
    cur="${m##*@}"
    reg_resolve "$name" "$cur" "$cutoff" caret
    case "$REG_VERDICT" in
      pick)
        specs+=("$name@$REG_VERSION")
        changed=1
        continue
        ;;
      held)
        PNPM_HELD=$((PNPM_HELD + 1))
        note "- $name $cur: every newer release in its major is under ${PNPM_DAYS} days old — held"
        ;;
      unsuitable)
        PNPM_HELD=$((PNPM_HELD + 1))
        note "- $name $cur: the newest releases old enough are deprecated or need a newer Node.js — left as is"
        ;;
      error)
        warn "registry lookup failed for $name"
        cmm_fail_later
        ;;
    esac
    specs+=("$m")
  done
  [ "$changed" -eq 1 ] || return 0
  joined="$(
    IFS=,
    printf '%s' "${specs[*]}"
  )"
  step pnpm add -g "$joined"
}

# pnpm_update_globals DAYS — every global package to its pick (cutoff: DAYS
# ago, or now without a cooldown).
pnpm_update_globals() {
  local days="$1" cutoff json rows line members
  if ! can_resolve; then
    if [ "$days" -eq 0 ]; then
      step pnpm update -g
    else
      note "- cooldown active (${days}d) but node/npm (needed for registry lookups) not found: global updates are held"
      summary_note "global updates held (node/npm not found for the cooldown)"
    fi
    return 0
  fi
  if [ "$days" -gt 0 ]; then
    cutoff="$(date_days_ago "$days")"
    note "- cooldown: updating global packages only to releases published before $cutoff (${days}d)"
  else
    cutoff="$(cmm_now_iso)"
  fi
  if ! json="$(pnpm ls -g --depth=0 --json 2>/dev/null)" ||
    ! rows="$(printf '%s' "$json" | node "$REGISTRY_JS" pnpm-globals)"; then
    warn "could not read 'pnpm ls -g --depth=0 --json'"
    cmm_fail_later
    return 0
  fi
  if [ -z "$rows" ]; then
    note "- no global packages"
    return 0
  fi
  PNPM_HELD=0
  PNPM_DAYS="$days"
  while IFS= read -r line <&3; do
    case "$line" in
      skip"$TAB"*)
        line="${line#skip"$TAB"}"
        pnpm_skip_note "${line%%"$TAB"*}" "${line#*"$TAB"}"
        ;;
      group"$TAB"*)
        members=()
        IFS="$TAB" read -r -a members <<<"${line#group"$TAB"}"
        pnpm_update_group "$cutoff" "${members[@]}"
        ;;
    esac
  done 3<<EOF
$rows
EOF
  [ "$PNPM_HELD" -gt 0 ] && summary_note "$PNPM_HELD global update(s) held by the ${days}-day cooldown"
  return 0
}

skip_unless pnpm

cache_dir_cmd pnpm store path
report pnpm outdated -g

if updating; then
  days="$(cooldown_days)"
  # From an empty scratch directory: inside a project that pins pnpm
  # (packageManager), `pnpm self-update` rewrites that pin instead, and
  # pnpm reads project settings (.npmrc, pnpm-workspace.yaml) from here.
  here="$PWD"
  scratch="$(cmm_scratch_dir)" || scratch=''
  [ -n "$scratch" ] && cd "$scratch"
  pnpm_self_update "$days"
  pnpm_update_globals "$days"
  if [ -n "$scratch" ]; then
    cd "$here" 2>/dev/null || cd /
    rm -rf "$scratch" # step never aborts, so this always runs
  fi
fi

if cleaning; then
  step pnpm store prune
fi
