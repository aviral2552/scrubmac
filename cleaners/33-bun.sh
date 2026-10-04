#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: bun
# group: JavaScript
# default: on
# summary: self-update standalone Bun and update global packages within their saved ranges (cooldown-aware), clear the cache
# Bun: self-update standalone installs (`bun upgrade` replaces the binary in
# place, so Homebrew/npm-managed copies are left to their managers), update
# global packages, and clear the global cache. Under the supply-chain
# cooldown (or your own stricter bunfig install.minimumReleaseAge), each
# global moves to the newest release its saved range allows that is old
# enough — never backwards — with `bun update -g NAME@VERSION
# --minimum-release-age`, which holds its dependencies to the cutoff too;
# `bun upgrade` (which cannot be told a version) runs only when Bun's newest
# release is itself old enough. Without either, plain `bun update -g`.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

TAB=$'\t'
# lib/registry.cjs (the registry resolver) sits next to the lib/common.sh above
REGISTRY_CJS="${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"
REGISTRY_CJS="${REGISTRY_CJS%/*}/registry.cjs"

# reg_resolve NAME CURRENT CUTOFF MODE — the registry verdict for NAME (the
# rules are in lib/registry.cjs) in REG_VERDICT — pick, held, none,
# unsuitable, foreign (CURRENT is no release of NAME there), missing (the
# registry does not know NAME), or error when it could not be read — and
# REG_VERSION. Releases that are deprecated, or whose engines.node excludes
# this node, are passed over (at most three times) with a note.
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
  out="$(printf '%s' "$info" | node "$REGISTRY_CJS" verify "${cands//$TAB/,}" --current "$cur" --npm "$(command -v npm)")" ||
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

# can_resolve — node, npm and lib/registry.cjs are there for registry lookups.
can_resolve() { have node && have npm && [ -f "$REGISTRY_CJS" ]; }

# bun_policy DAYS GLOBAL_DIR — BUN_VER; BUN_POLICY: the minimum release age
# (seconds) asked for — the cooldown, or install.minimumReleaseAge from the
# bunfig files Bun reads for `bun add/update -g` when stricter (passing a
# smaller value on the command line would relax it); BUN_WHY: where it
# comes from. Those files: your global bunfig — $XDG_CONFIG_HOME/.bunfig.toml
# when XDG_CONFIG_HOME is set (then ~/.bunfig.toml is ignored),
# ~/.bunfig.toml otherwise — and GLOBAL_DIR/bunfig.toml. BUN_UNSURE=1 when
# no number of seconds can be trusted (inf, too large, not a number, a
# file the reader cannot follow): then nothing may relax it.
bun_policy() {
  local cfg=0
  BUN_VER="$(bun --version 2>/dev/null)" || BUN_VER=0
  BUN_UNSURE=0
  if have node && [ -f "$REGISTRY_CJS" ]; then
    cfg="$(node "$REGISTRY_CJS" bunfig-age "${XDG_CONFIG_HOME:-$HOME}/.bunfig.toml" "$2/bunfig.toml")" || cfg=unsure
  fi
  case "$cfg" in
    '' | *[!0-9]* | ??????????????*) # no integer, or one past registry.cjs's cap
      BUN_UNSURE=1
      cfg=0
      ;;
  esac
  BUN_POLICY=$(($1 * 86400))
  BUN_WHY=''
  [ "$1" -gt 0 ] && BUN_WHY="the ${1}-day cooldown"
  if [ "$cfg" -gt 0 ]; then
    BUN_WHY="${BUN_WHY:+$BUN_WHY; }bunfig minimumReleaseAge=$cfg"
    [ "$cfg" -gt "$BUN_POLICY" ] && BUN_POLICY="$cfg"
  fi
  return 0
}

# bun_release_feed — the GitHub release `bun upgrade` installs, read the
# way Bun reads it (GITHUB_API_DOMAIN, and GITHUB_TOKEN or
# GITHUB_ACCESS_TOKEN as a bearer token — which lifts GitHub's 60-an-hour
# anonymous limit). The token goes to curl as a config file on stdin, never
# on its command line.
bun_release_feed() {
  local token="${GITHUB_TOKEN:-${GITHUB_ACCESS_TOKEN:-}}"
  token="${token//\\/\\\\}"
  token="${token//\"/\\\"}"
  {
    if [ -n "$token" ]; then
      printf 'header = "Authorization: Bearer %s"\n' "$token"
    fi
  } | curl -fsSL --max-time 30 -K - -H 'Accept: application/vnd.github.v3+json' \
    "https://${GITHUB_API_DOMAIN:-api.github.com}/repos/Jarred-Sumner/bun-releases-for-updater/releases/latest" 2>/dev/null
}

# bun_self_update — `bun upgrade` for standalone installs. It cannot be told
# a version: it installs the newest release from the GitHub feed it reads
# itself (api.github.com/repos/Jarred-Sumner/bun-releases-for-updater), so
# under the cooldown that feed decides — upgrade when the newest release is
# old enough, hold while it is too fresh (or cannot be read), and always
# with BUN_CANARY=1 set (then `bun upgrade` installs the newest canary).
bun_self_update() {
  local json verdict
  if [ "$BUN_POLICY" -eq 0 ] || [ "$(install_kind bun)" != standalone ]; then
    ai_self_update bun bun upgrade
    return 0
  fi
  if [ "${BUN_CANARY:-}" = 1 ]; then
    note "- bun upgrade held: BUN_CANARY=1 makes it install the newest canary build, never old enough for the cooldown ($BUN_WHY)"
    summary_note "bun upgrade held (BUN_CANARY=1, $BUN_WHY)"
    return 0
  fi
  verdict=''
  if have curl && can_resolve; then
    json="$(bun_release_feed)" || json=''
    verdict="$(printf '%s' "$json" | node "$REGISTRY_CJS" bun-release "$BUN_VER" "$BUN_CUTOFF" 2>/dev/null)" || verdict=''
  fi
  case "$verdict" in
    upgrade"$TAB"*) ai_self_update bun bun upgrade ;;
    held"$TAB"*)
      note "- bun upgrade held: Bun ${verdict#held"$TAB"} is too fresh ($BUN_WHY)"
      summary_note "bun upgrade held by the cooldown ($BUN_WHY)"
      ;;
    none) note "- bun $BUN_VER is up to date" ;;
    canary)
      note "- bun $BUN_VER is a canary build: 'bun upgrade' would install the newest canary, never old enough for the cooldown — held"
      summary_note "bun upgrade held (canary build, $BUN_WHY)"
      ;;
    *)
      note "- bun upgrade held: could not check the age of Bun's newest release (needs curl, node and GitHub's API)"
      summary_note "bun upgrade held (newest release could not be checked)"
      ;;
  esac
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
    range:*) note "- $1: its saved range '${2#range:}' would be rewritten by a versioned update (into an exact pin, or narrowed) — left to 'bun update -g'" ;;
    alias) note "- skipping $1: an aliased install (npm:…) — updating it by name would install a different package" ;;
    local | linked) note "- skipping $1: linked/local install (bun link, a path, file:, git)" ;;
    foreign) note "- skipping $1: its version is not a release of $1 on the registry (installed from git, a tarball, a fork or another registry?)" ;;
    missing) note "- skipping $1: not found on npm's configured registry (a registry set only in bunfig?)" ;;
    *) note "- skipping $1 ($2)" ;;
  esac
}

# bun_update_gated NAME@VERSION — `bun update -g NAME@VERSION
# --minimum-release-age N`, announced like `step`. Bun 1.3 re-checks every
# global's saved range against the age gate and fails ("blocked by
# minimum-release-age") while one of them has no release old enough; that
# holds the remaining updates (BUN_BLOCKED) instead of failing the run.
bun_update_gated() {
  local out rc=0
  if cmm_version_ge "$BUN_VER" 1.4; then
    step bun update -g "$1" --minimum-release-age "$BUN_POLICY"
    return 0
  fi
  [ "${CMM_MODE:-run}" = status ] && return 0
  printf '%s+ %s%s\n' "$CMM_DIM" "bun update -g $1 --minimum-release-age $BUN_POLICY" "$CMM_RESET"
  [ "${CMM_DRY_RUN:-0}" = 1 ] && return 0
  out="$(bun update -g "$1" --minimum-release-age "$BUN_POLICY" 2>&1)" || rc=$?
  [ -n "$out" ] && printf '%s\n' "$out"
  [ "$rc" -eq 0 ] && return 0
  case "$out" in
    *"blocked by minimum-release-age"*)
      BUN_BLOCKED=1
      note "- this Bun ($BUN_VER) checks every global against the age gate, and one of them has no release old enough yet: the remaining global updates are held (Bun 1.4 checks only the package being updated)"
      summary_note "global updates held: Bun < 1.4 blocks them while any global is newer than the cooldown"
      ;;
    *)
      warn "'bun' exited $rc — continuing with the remaining steps"
      cmm_fail_later
      ;;
  esac
}

# bun_outdated_filter — BUN_OUTDATED: the globals `bun outdated -g` shows a
# newer release for (" name … "), or "" when it could not be read (then
# every global is looked up).
bun_outdated_filter() {
  local text names
  BUN_OUTDATED=''
  text="$(bun outdated -g 2>/dev/null)" || return 0
  names="$(printf '%s\n' "$text" | node "$REGISTRY_CJS" bun-outdated 2>/dev/null)" || return 0
  BUN_OUTDATED=" $(printf '%s\n' "$names" | tr '\n' ' ')"
}

# bun_cooldown_update GLOBAL_DIR — each global package to the newest release
# its saved range allows that is published before BUN_CUTOFF.
bun_cooldown_update() {
  local rows kind name cur spec held=0 unsuitable=0
  note "- cooldown: updating global packages only to releases published before $BUN_CUTOFF ($BUN_WHY)"
  if ! rows="$(node "$REGISTRY_CJS" bun-globals "$1")"; then
    warn "could not read Bun's global packages"
    cmm_fail_later
    return 0
  fi
  bun_outdated_filter
  BUN_BLOCKED=0
  while IFS="$TAB" read -r kind name cur _ spec <&3; do # pkg NAME VERSION MODE SPEC
    case "$kind" in
      skip)
        bun_skip_note "$name" "$cur"
        continue
        ;;
      pkg) ;;
      *) continue ;;
    esac
    if [ -n "$BUN_OUTDATED" ] && [ "${BUN_OUTDATED#* "$name" }" = "$BUN_OUTDATED" ]; then
      continue # already the newest release
    fi
    reg_resolve "$name" "$cur" "$BUN_CUTOFF" "$spec" # within the saved range's own bounds
    case "$REG_VERDICT" in
      pick)
        if [ "$BUN_BLOCKED" = 1 ]; then
          held=$((held + 1))
        else
          bun_update_gated "$name@$REG_VERSION"
        fi
        ;;
      held)
        held=$((held + 1))
        note "- $name $cur: every newer release its range allows is too fresh ($name $REG_VERSION) — held"
        ;;
      unsuitable)
        unsuitable=$((unsuitable + 1))
        note "- $name $cur: not suitable — the newer releases old enough are deprecated or need a newer Node.js; left as is"
        ;;
      foreign | missing) bun_skip_note "$name" "$REG_VERDICT" ;;
      none) ;;
      *)
        warn "registry lookup failed for $name"
        cmm_fail_later
        ;;
    esac
  done 3<<EOF
$rows
EOF
  [ "$held" -gt 0 ] && summary_note "$held global update(s) held by the cooldown ($BUN_WHY)"
  [ "$unsuitable" -gt 0 ] && summary_note "$unsuitable global update(s) not suitable (deprecated, or need a newer Node.js)"
  return 0
}

skip_unless bun

# Bun's cache commands want a package.json in the current directory (and
# their -g forms one in the global directory, which is missing until a
# global package is installed), so the cleaner works from a scratch
# directory holding an empty {} package.json — no project settings either.
here="$PWD"
scratch="$(cmm_scratch_dir)" || scratch=''
if [ -n "$scratch" ] && printf '{}\n' >"$scratch/package.json" 2>/dev/null; then
  cd "$scratch"
else
  scratch=''
fi

if [ -n "$scratch" ]; then
  cache_dir_cmd bun pm cache
else
  cache_dir_cmd bun pm cache -g
fi

gdir="$(bun_global_dir)"
if updating; then
  days="$(cooldown_days)"
  bun_policy "$days" "$gdir"
  if [ "$BUN_UNSURE" = 1 ]; then
    note "- bun upgrade and global updates held: your bunfig's install.minimumReleaseAge cannot be read as a number of seconds here (inf, too large, not a number, or in a part of the file this reader cannot follow), and a --minimum-release-age passed instead could relax it"
    summary_note "Bun updates held: bunfig install.minimumReleaseAge could not be read"
  else
    if [ "$BUN_POLICY" -gt 0 ] && can_resolve; then
      BUN_CUTOFF="$(node "$REGISTRY_CJS" cutoff --seconds "$BUN_POLICY")"
    fi
    bun_self_update
    if [ ! -f "$gdir/package.json" ]; then
      note "- no global Bun packages ($gdir has no package.json)"
    elif [ "$BUN_POLICY" -eq 0 ]; then
      step bun update -g
    elif ! can_resolve; then
      note "- cooldown active ($BUN_WHY) but node/npm (needed for registry lookups) not found: global updates are held"
      summary_note "global updates held (node/npm not found for the cooldown)"
    elif ! cmm_version_ge "$BUN_VER" 1.3; then
      note "- this Bun ($BUN_VER) predates --minimum-release-age (1.3), so the cooldown cannot hold dependencies back: global updates are held"
      summary_note "global updates held by the cooldown (Bun < 1.3)"
    else
      bun_cooldown_update "$gdir"
    fi
  fi
fi

if cleaning; then
  if [ -n "$scratch" ]; then
    step bun pm cache rm # from the scratch directory: needs no global package.json
  elif [ -f "$gdir/package.json" ]; then
    step bun pm cache rm -g
  else
    note "- the cache was not cleared: no scratch directory, and 'bun pm cache rm -g' needs a global package"
  fi
fi

if [ -n "$scratch" ]; then
  cd "$here" 2>/dev/null || cd /
  rm -rf "$scratch"
fi
