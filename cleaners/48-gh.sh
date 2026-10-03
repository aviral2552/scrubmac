#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: gh
# group: AI tools
# default: on
# summary: upgrade GitHub CLI extensions (gh itself is updated by its manager)
# GitHub CLI: upgrade every installed extension. gh itself is usually
# brew-managed and updated by the homebrew cleaner. Extension commands need a
# logged-in gh: `gh extension list` exits 4 without one (then the cleaner is
# skipped, as it is when no extension is installed). `gh auth status` is not
# the test: it exits 1 when ANY account on any host has a problem (an
# inactive account, an Enterprise host off the VPN), even with github.com
# logged in.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless gh

# gh_extensions — GH_EXTS (the installed extensions) and GH_RC (the exit
# status of `gh extension list`: 4 when gh is not logged in).
gh_extensions() {
  GH_RC=0
  GH_EXTS="$(gh extension list 2>/dev/null)" || GH_RC=$?
}

if [ "${CMM_MODE:-run}" = status ]; then
  gh_extensions
  case "$GH_RC" in
    0) [ -n "$GH_EXTS" ] && report gh extension list ;;
    4) note "- gh is not logged in: run 'gh auth login'" ;;
    *) note "- 'gh extension list' exited $GH_RC" ;;
  esac
fi
skip_unless_updating

gh_extensions
case "$GH_RC" in
  4) skip "skipping: gh is not logged in ('gh extension list' exited 4) — extension upgrades need 'gh auth login'" ;;
  0) [ -n "$GH_EXTS" ] || skip "skipping: no gh extensions installed" ;;
esac

step gh extension upgrade --all # exits 0 when there is nothing to upgrade
