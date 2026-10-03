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
# logged-in gh (without one they exit 4), so a gh that is not logged in, or
# has no extensions, is skipped.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless gh

# gh_logged_in — `gh auth status` exits 1 when no host is logged in or a
# token no longer works.
gh_logged_in() { gh auth status >/dev/null 2>&1; }

if [ "${CMM_MODE:-run}" = status ]; then
  if gh_logged_in; then
    report gh extension list
  else
    note "- gh is not logged in: run 'gh auth login'"
  fi
fi
skip_unless_updating

gh_logged_in || skip "skipping: gh is not logged in ('gh auth status' failed) — extension upgrades need 'gh auth login'"
if exts="$(gh extension list 2>/dev/null)" && [ -z "$exts" ]; then
  skip "skipping: no gh extensions installed"
fi

step gh extension upgrade --all # exits 0 when there is nothing to upgrade
