#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: kubectl-krew
# group: Developer tools
# default: on
# summary: upgrade kubectl plugins installed with krew
# krew: refresh the plugin index and upgrade every kubectl plugin installed
# with krew (and krew itself, when krew manages it). krew exits 0 even when
# plugins fail to upgrade, so its output decides.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless kubectl-krew
skip_unless kubectl

# krew_upgrade — `kubectl krew upgrade`, announced like `step` (and not run
# under --dry-run); a plugin that fails to upgrade is only a "WARNING: failed
# to upgrade plugin …" line (plus "WARNING: Some plugins failed to upgrade")
# with exit 0, so the output is checked too.
krew_upgrade() {
  local out rc=0
  [ "${CMM_MODE:-run}" = status ] && return 0
  printf '%s+ %s%s\n' "$CMM_DIM" "kubectl krew upgrade" "$CMM_RESET"
  [ "${CMM_DRY_RUN:-0}" = 1 ] && return 0
  out="$(kubectl krew upgrade 2>&1)" || rc=$?
  [ -n "$out" ] && printf '%s\n' "$out"
  if [ "$rc" -ne 0 ]; then
    warn "'kubectl' exited $rc — continuing with the remaining steps"
    cmm_fail_later
    return 0
  fi
  case "$out" in
    *"failed to upgrade plugin"* | *"Some plugins failed to upgrade"*)
      warn "kubectl krew upgrade: some plugins failed to upgrade (see above)"
      cmm_fail_later
      ;;
  esac
  return 0
}

report kubectl krew list
skip_unless_updating

krew_upgrade
