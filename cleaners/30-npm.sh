#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: npm
# group: JavaScript
# default: on
# summary: update global packages (cooldown-aware; never npm/corepack or linked globals), verify the cache
# npm: update global packages — under the supply-chain cooldown (or your own
# npm min-release-age/before, whichever is stricter), each to the newest
# release old enough and never to anything older than what is installed,
# with its dependencies held to the same cutoff (--before) — and garbage-
# collect the cache. npm itself and corepack belong to the Node.js install
# (D4) and are never touched, and neither are linked (npm link, npm i -g
# ./dir), aliased or non-registry globals: updating those by name would
# install an unrelated registry package in their place.
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
# excludes this node, are passed over (at most three times) with a note.
reg_resolve() {
  local name="$1" cur="$2" info out cands kind v why
  REG_VERDICT=error
  REG_VERSION=''
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
      skip) note "- $name $v: $why — trying the next release" ;;
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

# npm_globals — the outdated globals, classified by lib/registry.cjs
# (npm-outdated), into NPM_ROWS; fails when npm's answer is unreadable.
# `npm ls -g --long --json` tells linked and aliased installs apart (its
# "resolved" and "name" fields); the global root, when npm prints a usable
# one, adds an on-disk check (npm masks UUID-like path segments as ***).
npm_globals() {
  local out list root
  out="$(npm outdated -g --json 2>/dev/null)" || true   # exits 1 whenever anything is outdated
  list="$(npm ls -g --long --json 2>/dev/null)" || true # exits 1 on tree problems, still prints JSON
  root="$(npm root -g 2>/dev/null)" || root=''
  NPM_ROWS="$(printf '{"outdated":%s,"ls":%s}' "${out:-"{}"}" "${list:-"{}"}" | node "$REGISTRY_CJS" npm-outdated "$root")"
}

# npm_skip_note NAME CURRENT REASON — why a global is left alone.
npm_skip_note() {
  case "$3" in
    self) note "- $1 $2 is outdated, but it belongs to your Node.js install and updates with it (D4)" ;;
    linked) note "- skipping $1: linked/local install (npm link or a local directory)" ;;
    alias) note "- skipping $1: an aliased install (npm:…) — updating it by name would install a different package" ;;
    source) note "- skipping $1: installed from git or a URL, not the registry" ;;
    foreign) note "- skipping $1 $2: not a release of $1 on the registry (installed from git, a tarball, a fork or another registry?) — updating it by name would replace it" ;;
    missing) note "- skipping $1: not found on npm's configured registry" ;;
    unknown) note "- skipping $1: not listed by 'npm ls -g', so its source cannot be checked" ;;
    ahead) note "- skipping $1 $2: newer than its \"latest\" release — never downgraded" ;;
    *) note "- skipping $1: '$2' is not a registry release" ;;
  esac
}

# npm_policy DAYS — the cutoff to hold updates to (NPM_CUTOFF, an ISO date,
# or "none") and why (NPM_WHY): the cooldown, or your own npm min-release-age
# or before setting when stricter. A --before on the command line would
# override (relax) those settings, so the stricter one is passed explicitly.
npm_policy() {
  local mra before why=''
  mra="$(npm config get min-release-age 2>/dev/null)" || mra=''
  before="$(npm config get before 2>/dev/null)" || before=''
  NPM_CUTOFF="$(node "$REGISTRY_CJS" cutoff --days "$1" --days "$mra" --before "$before")" || NPM_CUTOFF=none
  [ "$1" -gt 0 ] && why="the ${1}-day cooldown"
  case "$mra" in '' | null | 0 | *[!0-9]*) ;; *) why="${why:+$why; }npm min-release-age=$mra" ;; esac
  case "$before" in '' | null | undefined) ;; *) why="${why:+$why; }npm before=$before" ;; esac
  NPM_WHY="$why"
}

# npm_cooldown_update — move each outdated global package to the newest
# release published before NPM_CUTOFF (and never backwards).
npm_cooldown_update() {
  local kind pkg cur extra held=0 unsuitable=0 outdated=0
  note "- cooldown: updating global packages only to releases published before $NPM_CUTOFF ($NPM_WHY)"
  while IFS="$TAB" read -r kind pkg cur extra <&3; do
    case "$kind" in
      skip)
        npm_skip_note "$pkg" "$cur" "$extra"
        continue
        ;;
      update) ;;
      *) continue ;;
    esac
    outdated=$((outdated + 1))
    reg_resolve "$pkg" "$cur" "$NPM_CUTOFF" latest
    case "$REG_VERDICT" in
      pick) step npm install -g "$pkg@$REG_VERSION" --before="$NPM_CUTOFF" ;;
      held)
        held=$((held + 1))
        note "- $pkg $cur: every newer release is too fresh ($pkg $REG_VERSION is newer than $NPM_CUTOFF) — held"
        ;;
      unsuitable)
        unsuitable=$((unsuitable + 1))
        note "- $pkg $cur: not suitable — the newer releases old enough are deprecated or need a newer Node.js; left as is"
        ;;
      foreign | missing) npm_skip_note "$pkg" "$cur" "$REG_VERDICT" ;;
      none) ;;
      *)
        warn "registry lookup failed for $pkg"
        cmm_fail_later
        ;;
    esac
  done 3<<EOF
$NPM_ROWS
EOF
  [ "$outdated" -eq 0 ] && note "- global packages are up to date"
  [ "$held" -gt 0 ] && summary_note "$held global update(s) held by the cooldown ($NPM_WHY)"
  [ "$unsuitable" -gt 0 ] && summary_note "$unsuitable global update(s) not suitable (deprecated, or need a newer Node.js)"
  return 0
}

# npm_registry_check NAME CURRENT — foreign or missing (see reg_resolve) when
# CURRENT is not a release of NAME on the registry; ok otherwise.
npm_registry_check() {
  local info verdict
  info="$(npm view "$1" versions dist-tags --json 2>/dev/null)" || true # two fields: an object, not a bare list
  verdict="$(printf '%s' "$info" | node "$REGISTRY_CJS" pick "$1" "$2" "$(cmm_now_iso)" latest 2>/dev/null)" || verdict=error
  case "$verdict" in
    foreign | missing | error) printf '%s\n' "$verdict" ;;
    *) printf 'ok\n' ;;
  esac
}

# npm_plain_update — `npm update -g` for exactly the outdated globals it may
# touch (never npm/corepack, linked, aliased or non-registry packages, or a
# downgrade).
npm_plain_update() {
  local kind pkg cur extra check names=()
  while IFS="$TAB" read -r kind pkg cur extra <&3; do
    case "$kind" in
      skip) npm_skip_note "$pkg" "$cur" "$extra" ;;
      update)
        check="$(npm_registry_check "$pkg" "$cur")"
        case "$check" in
          ok) names+=("$pkg") ;;
          error)
            warn "registry lookup failed for $pkg"
            cmm_fail_later
            ;;
          *) npm_skip_note "$pkg" "$cur" "$check" ;;
        esac
        ;;
    esac
  done 3<<EOF
$NPM_ROWS
EOF
  if [ "${#names[@]}" -eq 0 ]; then
    note "- no global packages to update"
    return 0
  fi
  step npm update -g "${names[@]}"
}

skip_unless npm

cache_dir_cmd npm config get cache
report --ok=1 npm outdated -g # npm outdated exits 1 whenever anything is outdated
preview --ok=1 npm outdated -g

if updating; then
  days="$(cooldown_days)"
  if ! have node || [ ! -f "$REGISTRY_CJS" ]; then
    note "- node (or scrubmac's lib/registry.cjs) not found: global updates are held — they need it to leave npm, corepack and linked packages alone"
    summary_note "global updates held (node not found)"
  elif ! npm_globals; then
    warn "could not read 'npm outdated -g --json'"
    cmm_fail_later
  else
    npm_policy "$days"
    if [ "$NPM_CUTOFF" != none ]; then
      npm_cooldown_update
    else
      npm_plain_update
    fi
  fi
fi

if cleaning; then
  step npm cache verify
fi
