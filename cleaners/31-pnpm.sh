#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: pnpm
# group: JavaScript
# default: on
# summary: update global packages within their saved ranges (cooldown-aware), self-update standalone pnpm, prune the store
# pnpm: update global packages within the ranges they were saved with, and
# self-update standalone installs. Under the supply-chain cooldown (or your
# own stricter minimumReleaseAge), each global moves to the newest release
# of its range that is old enough — never backwards — re-added with the same
# range operator and pnpm's own minimumReleaseAge, which holds every
# dependency to the cutoff too; pnpm itself self-updates to the newest
# release old enough. Without either, plain `pnpm update -g` and
# `pnpm self-update`. Then drop unreferenced packages from the store.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

TAB=$'\t'
# lib/registry.cjs (the registry resolver) sits next to the lib/common.sh above
REGISTRY_CJS="${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"
REGISTRY_CJS="${REGISTRY_CJS%/*}/registry.cjs"

# reg_resolve NAME CURRENT CUTOFF MODE [--no-engines] — the registry verdict
# for NAME (the rules are in lib/registry.cjs) in REG_VERDICT — pick, held,
# none, unsuitable, foreign (CURRENT is no release of NAME there), missing
# (the registry does not know NAME), or error when it could not be read —
# and REG_VERSION. Releases that are deprecated, or whose engines.node
# excludes this node, are passed over (at most three times) with a note;
# REG_STEPPED says whether that happened.
reg_resolve() {
  local name="$1" cur="$2" info out cands kind v why
  REG_VERDICT=error
  REG_VERSION=''
  REG_STEPPED=0
  # npm prints an E404 as a JSON error object (exit 1): pick tells it apart
  info="$(npm view "$name" time versions dist-tags --json 2>/dev/null)" || true
  out="$(printf '%s' "$info" | node "$REGISTRY_CJS" pick "$name" "$cur" "$3" "$4")" || return 0
  case "$out" in
    pick"$TAB"*) cands="${out#pick"$TAB"}" ;;
    held"$TAB"*)
      REG_VERDICT=held
      REG_VERSION="${out#held"$TAB"}"
      return 0
      ;;
    none | foreign | missing)
      REG_VERDICT="$out"
      return 0
      ;;
    *) return 0 ;;
  esac
  info="$(npm view "$name@${cands//$TAB/ || } || $cur" name version deprecated engines --json 2>/dev/null)" || info=''
  out="$(printf '%s' "$info" | node "$REGISTRY_CJS" verify "${cands//$TAB/,}" --current "$cur" ${5+"$5"} --npm "$(command -v npm)")" ||
    out="ok$TAB${cands%%"$TAB"*}"
  REG_VERDICT=unsuitable
  while IFS="$TAB" read -r kind v why; do
    case "$kind" in
      skip)
        REG_STEPPED=1
        note "- $name $v: $why — trying the next release"
        ;;
      ok)
        REG_VERDICT=pick
        REG_VERSION="$v"
        [ -z "$why" ] || note "- $name $v: $why"
        ;;
    esac
  done <<EOF
$out
EOF
  return 0
}

# can_resolve — node, npm and lib/registry.cjs are there for registry lookups.
can_resolve() { have node && have npm && [ -f "$REGISTRY_CJS" ]; }

# pnpm_policy DAYS — PNPM_VER/PNPM_MAJOR; PNPM_POLICY: the minimum release
# age (minutes) asked for — the cooldown, or your own minimumReleaseAge when
# stricter (passing a smaller value on the command line would relax it);
# PNPM_GATE: that, but at least pnpm's built-in default (1440 since pnpm 11);
# PNPM_WHY: where it comes from.
pnpm_policy() {
  local cfg
  PNPM_VER="$(pnpm --version 2>/dev/null)" || PNPM_VER=0
  PNPM_MAJOR="${PNPM_VER%%.*}"
  case "$PNPM_MAJOR" in '' | *[!0-9]*) PNPM_MAJOR=0 ;; esac
  cfg="$(pnpm config get minimumReleaseAge 2>/dev/null | tail -n 1)" || cfg=''
  case "$cfg" in '' | *[!0-9]*) cfg=0 ;; esac
  PNPM_POLICY=$(($1 * 1440))
  PNPM_WHY=''
  [ "$1" -gt 0 ] && PNPM_WHY="the ${1}-day cooldown"
  if [ "$cfg" -gt 0 ]; then
    PNPM_WHY="${PNPM_WHY:+$PNPM_WHY; }pnpm minimumReleaseAge=$cfg"
    [ "$cfg" -gt "$PNPM_POLICY" ] && PNPM_POLICY="$cfg"
  fi
  PNPM_GATE="$PNPM_POLICY"
  if [ "$PNPM_MAJOR" -ge 11 ] && [ "$PNPM_GATE" -lt 1440 ]; then
    PNPM_GATE=1440
  fi
  return 0
}

# pnpm_self_update — standalone installs only (Corepack/Homebrew/npm/
# version-manager copies are left to their managers): the newest release
# published before PNPM_CUTOFF, named explicitly. pnpm before 9.13 takes no
# version (`pnpm self-update X` installs the newest release anyway), so its
# self-update is held.
pnpm_self_update() {
  local cur
  if [ "$(install_kind pnpm)" != standalone ]; then
    ai_self_update pnpm # explains which manager owns it
    return 0
  fi
  cur="$PNPM_VER"
  if ! cmm_version_ge "$cur" 9.13; then
    note "- pnpm $cur cannot be told which release to self-update to (before 9.13 it always installs the newest): self-update held — run 'pnpm self-update' yourself"
    summary_note "pnpm self-update held: pnpm < 9.13 cannot self-update to a release old enough"
    return 0
  fi
  reg_resolve pnpm "$cur" "$PNPM_CUTOFF" latest --no-engines
  case "$REG_VERDICT" in
    pick) ai_self_update pnpm pnpm self-update "$REG_VERSION" ;;
    held)
      note "- pnpm $cur: pnpm $REG_VERSION is too fresh ($PNPM_WHY) — self-update held"
      summary_note "pnpm self-update held by the cooldown ($PNPM_WHY)"
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
    foreign) note "- skipping $1: its version is not a release of $1 on the registry (installed from git, a tarball, a fork or another registry?)" ;;
    missing) note "- skipping $1: not found on npm's configured registry (a registry set only in pnpm's own config?)" ;;
    *) note "- skipping $1 ($2)" ;;
  esac
}

# pnpm_outdated_filter — PNPM_OUTDATED: the globals `pnpm outdated -g`
# reports a newer in-range release for (" name name … "), or "" when it could
# not be read (then every global is looked up).
pnpm_outdated_filter() {
  local json names
  PNPM_OUTDATED=''
  json="$(pnpm outdated -g --format json 2>/dev/null)" || true # exits 1 whenever anything is outdated
  names="$(printf '%s' "$json" | node "$REGISTRY_CJS" pnpm-outdated 2>/dev/null)" || return 0
  PNPM_OUTDATED=" $(printf '%s\n' "$names" | tr '\n' ' ')"
}

# pnpm_flush_group — update the install group collected in G_NAMES, G_VERS,
# G_MODES and G_SPECS. Every member keeps its saved range: ^ and ~ move to
# the newest release the range allows that is old enough (or stay on the
# installed version) and keep their operator, exact pins stay exact. pnpm
# >= 11 re-adds the group as a whole (one member alone would uninstall the
# rest), with the installed version of each member that does not move
# excluded from the age gate — without that, a group-mate installed recently
# fails the gate. A group is not re-added at all when a member could not be
# checked, is not a registry release (foreign, missing), would land on an
# unsuitable release, or has a range a re-add would rewrite (*, latest,
# 7.x, >=1 <2, ~1, ^0 — pnpm saves them as ^/~ of a version).
pnpm_flush_group() {
  local i name ver mode spec target joined sel changed=0 blocked='' why='' sels=() excl=() movers=() moved=()
  [ "${#G_NAMES[@]}" -gt 0 ] || return 0
  i=0
  while [ "$i" -lt "${#G_NAMES[@]}" ]; do
    name="${G_NAMES[$i]}"
    ver="${G_VERS[$i]}"
    mode="${G_MODES[$i]}"
    spec="${G_SPECS[$i]}"
    i=$((i + 1))
    target="$ver"
    case "$mode" in
      latest | range)
        note "- $name: its saved range '$spec' would be rewritten by a re-add — left to 'pnpm update -g'"
        blocked="${blocked:-$name}"
        why="${why:-its saved range ($spec) would be rewritten}"
        ;;
      caret | tilde)
        if [ -n "$PNPM_OUTDATED" ] && [ "${PNPM_OUTDATED#* "$name" }" = "$PNPM_OUTDATED" ]; then
          REG_VERDICT=none
        else
          reg_resolve "$name" "$ver" "$PNPM_CUTOFF" "$spec" # within the saved range's own bounds
        fi
        case "$REG_VERDICT" in
          pick)
            if [ "$REG_STEPPED" = 1 ]; then
              # pnpm resolves ranges itself and would land on the newer release
              PNPM_UNSUITABLE=$((PNPM_UNSUITABLE + 1))
              note "- $name $ver: not suitable — the newest release old enough is deprecated or needs a newer Node.js; left as is"
              blocked="$name"
              why='pnpm would move it onto an unsuitable release'
            else
              target="$REG_VERSION"
              changed=1
              movers+=("$name@$target")
            fi
            ;;
          held)
            PNPM_HELD=$((PNPM_HELD + 1))
            note "- $name $ver: every newer release its range allows is too fresh ($name $REG_VERSION) — held"
            ;;
          unsuitable)
            PNPM_UNSUITABLE=$((PNPM_UNSUITABLE + 1))
            note "- $name $ver: not suitable — the newer releases old enough are deprecated or need a newer Node.js; left as is"
            blocked="$name"
            why='pnpm would move it onto an unsuitable release'
            ;;
          foreign | missing)
            pnpm_skip_note "$name" "$REG_VERDICT"
            blocked="$name"
            why='it is not a registry release'
            ;;
          none) ;;
          *)
            warn "registry lookup failed for $name"
            cmm_fail_later
            blocked="$name"
            why='it could not be checked'
            ;;
        esac
        ;;
    esac
    case "$mode" in
      caret) sel="$name@^$target" ;;
      tilde) sel="$name@~$target" ;;
      *) sel="$name@$spec" ;; # exact pins and other ranges stay as saved
    esac
    sels+=("$sel")
    if [ "$target" = "$ver" ]; then
      moved+=(0)
      excl+=("--config.minimum-release-age-exclude=$name@$ver")
    else
      moved+=(1)
    fi
  done
  G_NAMES=() G_VERS=() G_MODES=() G_SPECS=()
  [ "$changed" -eq 1 ] || return 0
  if [ -n "$blocked" ] && [ "${#sels[@]}" -gt 1 ]; then
    note "- not re-adding ${movers[*]} this run: it shares an install group with $blocked, and $why"
    PNPM_GROUPHELD=$((PNPM_GROUPHELD + ${#movers[@]}))
    return 0
  fi
  if [ "$PNPM_MAJOR" -ge 11 ]; then
    joined="$(
      IFS=,
      printf '%s' "${sels[*]}"
    )"
    step pnpm add -g "$joined" --config.minimum-release-age="$PNPM_GATE" ${excl[@]+"${excl[@]}"}
  else
    i=0 # pnpm 10: one global project, no a,b groups: one add per package
    while [ "$i" -lt "${#sels[@]}" ]; do
      [ "${moved[$i]}" = 1 ] && step pnpm add -g "${sels[$i]}" --config.minimum-release-age="$PNPM_GATE"
      i=$((i + 1))
    done
  fi
}

# pnpm_update_globals — every global package to its pick (see the header).
pnpm_update_globals() {
  local json rows line kind group name ver mode spec prev='' legacy
  legacy="$(pnpm_legacy_globals)"
  if [ -n "$legacy" ]; then
    note "- $(printf '%s\n' "$legacy" | awk 'NF { n++ } END { print n + 0 }') global package(s) are still in pnpm 10's global directory, which this pnpm ($PNPM_VER) no longer lists: only 'pnpm update -g' moves them over (it updates them too, without the cooldown) — run it once yourself"
    summary_note "pnpm 10 global packages not migrated — run 'pnpm update -g' once"
  fi
  if ! json="$(pnpm ls -g --depth=0 --json 2>/dev/null)" ||
    ! rows="$(printf '%s' "$json" | node "$REGISTRY_CJS" pnpm-globals --major "$PNPM_MAJOR")"; then
    warn "could not read 'pnpm ls -g --depth=0 --json'"
    cmm_fail_later
    return 0
  fi
  if [ -z "$rows" ]; then
    note "- no global packages"
    return 0
  fi
  note "- cooldown: updating global packages only to releases published before $PNPM_CUTOFF ($PNPM_WHY)"
  pnpm_outdated_filter
  PNPM_HELD=0
  PNPM_UNSUITABLE=0
  PNPM_GROUPHELD=0
  G_NAMES=() G_VERS=() G_MODES=() G_SPECS=()
  while IFS= read -r line <&3; do
    kind="${line%%"$TAB"*}"
    case "$kind" in
      skip)
        line="${line#skip"$TAB"}"
        pnpm_skip_note "${line%%"$TAB"*}" "${line#*"$TAB"}"
        ;;
      member)
        IFS="$TAB" read -r kind group name ver mode spec <<<"$line"
        if [ "$group" != "$prev" ]; then
          pnpm_flush_group
          prev="$group"
        fi
        G_NAMES+=("$name")
        G_VERS+=("$ver")
        G_MODES+=("$mode")
        G_SPECS+=("$spec")
        ;;
    esac
  done 3<<EOF
$rows
EOF
  pnpm_flush_group
  [ "$PNPM_HELD" -gt 0 ] && summary_note "$PNPM_HELD global update(s) held by the cooldown ($PNPM_WHY)"
  [ "$PNPM_UNSUITABLE" -gt 0 ] && summary_note "$PNPM_UNSUITABLE global update(s) not suitable (deprecated, or need a newer Node.js)"
  [ "$PNPM_GROUPHELD" -gt 0 ] && summary_note "$PNPM_GROUPHELD global update(s) held: their install group (pnpm add -g a,b) cannot be re-added this run"
  return 0
}

# pnpm_legacy_globals — on pnpm >= 11, the packages still in pnpm 10's global
# project (<globalDir>/5, beside the vN root `pnpm root -g` names): pnpm 11
# no longer lists them, and only `pnpm update -g` migrates them.
pnpm_legacy_globals() {
  local root
  [ "$PNPM_MAJOR" -ge 11 ] || return 0
  { have node && [ -f "$REGISTRY_CJS" ]; } || return 0
  root="$(pnpm root -g 2>/dev/null)" || return 0
  [ -n "$root" ] || return 0
  node "$REGISTRY_CJS" pnpm-legacy "$root" 2>/dev/null || true
}

# pnpm_has_globals — pnpm has global packages, so `pnpm update -g` has work:
# with none, and no `pnpm setup` ever run (pnpm from Homebrew or Corepack,
# used for projects only), it fails outright — its global bin directory is
# not on PATH. pnpm 10's leftovers count (`pnpm update -g` migrates them).
# Without node to read pnpm's list, assume it has.
pnpm_has_globals() {
  local json rows
  { have node && [ -f "$REGISTRY_CJS" ]; } || return 0
  [ -n "$(pnpm_legacy_globals)" ] && return 0
  json="$(pnpm ls -g --depth=0 --json 2>/dev/null)" || return 0
  rows="$(printf '%s' "$json" | node "$REGISTRY_CJS" pnpm-globals --major "$PNPM_MAJOR" 2>/dev/null)" || return 0
  [ -n "$rows" ]
}

skip_unless pnpm

cache_dir_cmd pnpm store path
report --ok=1 pnpm outdated -g # exits 1 whenever anything is outdated

if updating; then
  days="$(cooldown_days)"
  # From an empty scratch directory: inside a project that pins pnpm
  # (packageManager), `pnpm self-update` rewrites that pin instead, and
  # pnpm reads project settings (.npmrc, pnpm-workspace.yaml) from here.
  here="$PWD"
  scratch="$(cmm_scratch_dir)" || scratch=''
  [ -n "$scratch" ] && cd "$scratch"
  pnpm_policy "$days"
  if [ "$PNPM_POLICY" -eq 0 ]; then
    ai_self_update pnpm pnpm self-update
    if pnpm_has_globals; then
      step pnpm update -g
    else
      note "- no global packages"
    fi
  elif ! can_resolve; then
    note "- cooldown active ($PNPM_WHY) but node/npm (needed for registry lookups) not found: global updates and the self-update are held"
    summary_note "global updates held (node/npm not found for the cooldown)"
  else
    PNPM_CUTOFF="$(node "$REGISTRY_CJS" cutoff --minutes "$PNPM_GATE")"
    pnpm_self_update
    if cmm_version_ge "$PNPM_VER" 10.16; then
      pnpm_update_globals
    else
      note "- this pnpm ($PNPM_VER) predates minimumReleaseAge (10.16), so the cooldown cannot hold dependencies back: global updates are held"
      summary_note "global updates held by the cooldown (pnpm < 10.16)"
    fi
  fi
  if [ -n "$scratch" ]; then
    cd "$here" 2>/dev/null || cd /
    rm -rf "$scratch" # step never aborts, so this always runs
  fi
fi

if cleaning; then
  step pnpm store prune
fi
