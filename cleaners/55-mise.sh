#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: mise
# group: Languages
# default: on
# summary: self-update standalone mise, report outdated tools, clear the cache (MISE_PRUNE=1 also prunes)
# mise: self-update standalone installs (-y: it asks otherwise; Homebrew's
# mise refuses self-update and is left to brew), report outdated tool
# versions, and clear its cache. `mise upgrade` is deliberately NOT run:
# bumping pinned tool versions is a per-project decision. MISE_PRUNE=1 also
# removes installed versions no tracked config uses.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless mise

report mise outdated

if updating; then
  ai_self_update mise mise self-update -y
  try mise outdated
fi

if cleaning; then
  step mise cache clear
  if [ "$(setting MISE_PRUNE 0)" = 1 ]; then
    step mise prune --yes
  fi
fi
