#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: npm
# group: JavaScript
# default: on
# summary: update global packages (cooldown-aware; never npm/corepack or linked globals), verify the cache
# npm: update global packages — under the supply-chain cooldown, each to the
# newest release that is at least COOLDOWN_DAYS old and never to anything
# older than what is installed (npm's own --before/min-release-age would
# downgrade newer globals) — and garbage-collect the cache. npm itself and
# corepack belong to the Node.js install (D4) and are never touched, and
# neither are linked (npm link, npm i -g ./dir) or aliased globals: updating
# those by name would install an unrelated registry package in their place.
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

# npm_globals — the outdated globals, classified by lib/registry.js
# (npm-outdated), into NPM_ROWS; fails when npm's answer is unreadable.
# `npm ls -g --long --json` tells linked and aliased installs apart (its
# "resolved" and "name" fields); the global root, when npm prints a usable
# one, adds an on-disk check (npm masks UUID-like path segments as ***).
npm_globals() {
  local out list root
  out="$(npm outdated -g --json 2>/dev/null)" || true   # exits 1 whenever anything is outdated
  list="$(npm ls -g --long --json 2>/dev/null)" || true # exits 1 on tree problems, still prints JSON
  root="$(npm root -g 2>/dev/null)" || root=''
  NPM_ROWS="$(printf '{"outdated":%s,"ls":%s}' "${out:-"{}"}" "${list:-"{}"}" | node "$REGISTRY_JS" npm-outdated "$root")"
}

# npm_skip_note NAME CURRENT REASON — why a global is left alone.
npm_skip_note() {
  case "$3" in
    self) note "- $1 $2 is outdated, but it belongs to your Node.js install and updates with it (D4)" ;;
    linked) note "- skipping $1: linked/local install (npm link or a local directory)" ;;
    alias) note "- skipping $1: an aliased install (npm:…) — updating it by name would install a different package" ;;
    source) note "- skipping $1: installed from git or a URL, not the registry" ;;
    unknown) note "- skipping $1: not listed by 'npm ls -g', so its source cannot be checked" ;;
    ahead) note "- skipping $1 $2: newer than its \"latest\" release — never downgraded" ;;
    *) note "- skipping $1: '$2' is not a registry release" ;;
  esac
}

# npm_cooldown_update DAYS — move each outdated global package to the newest
# release at least DAYS old (and never backwards).
npm_cooldown_update() {
  local days="$1" cutoff kind pkg cur extra held=0 outdated=0
  cutoff="$(date_days_ago "$days")"
  note "- cooldown: updating global packages only to releases published before $cutoff (${days}d)"
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
    reg_resolve "$pkg" "$cur" "$cutoff" latest
    case "$REG_VERDICT" in
      pick) step npm install -g "$pkg@$REG_VERSION" ;;
      held)
        held=$((held + 1))
        note "- $pkg $cur: every newer release is under ${days} days old — held"
        ;;
      unsuitable)
        held=$((held + 1))
        note "- $pkg $cur: the newest releases old enough are deprecated or need a newer Node.js — left as is"
        ;;
      error)
        warn "registry lookup failed for $pkg"
        cmm_fail_later
        ;;
    esac
  done 3<<EOF
$NPM_ROWS
EOF
  [ "$outdated" -eq 0 ] && note "- global packages are up to date"
  [ "$held" -gt 0 ] && summary_note "$held global update(s) held by the ${days}-day cooldown"
  return 0
}

# npm_plain_update — `npm update -g` for exactly the outdated globals it may
# touch (never npm/corepack, linked or aliased packages, or a downgrade).
npm_plain_update() {
  local kind pkg cur extra names=()
  while IFS="$TAB" read -r kind pkg cur extra; do
    case "$kind" in
      skip) npm_skip_note "$pkg" "$cur" "$extra" ;;
      update) names+=("$pkg") ;;
    esac
  done <<EOF
$NPM_ROWS
EOF
  if [ "${#names[@]}" -eq 0 ]; then
    note "- global packages are up to date"
    return 0
  fi
  step npm update -g "${names[@]}"
}

skip_unless npm

cache_dir_cmd npm config get cache
report npm outdated -g
preview npm outdated -g

if updating; then
  days="$(cooldown_days)"
  if ! have node || [ ! -f "$REGISTRY_JS" ]; then
    note "- node (or scrubmac's lib/registry.js) not found: global updates are held — they need it to leave npm, corepack and linked packages alone"
    summary_note "global updates held (node not found)"
  elif ! npm_globals; then
    warn "could not read 'npm outdated -g --json'"
    cmm_fail_later
  elif [ "$days" -gt 0 ]; then
    npm_cooldown_update "$days"
  else
    npm_plain_update
  fi
fi

if cleaning; then
  step npm cache verify
fi
