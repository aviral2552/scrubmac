#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: yarn
# group: JavaScript
# default: on
# summary: Yarn classic: upgrade global packages (held during a cooldown) and clean the cache
# Yarn: classic (v1) global upgrades + cache clean. Yarn classic has no
# release-age filter, so global upgrades are held while the supply-chain
# cooldown is on. Berry (v2+) keeps its caches per-project, so there is
# nothing global to do.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless yarn

major="$(yarn --version 2>/dev/null | cut -d. -f1)" || major=''
if [ "$major" != "1" ]; then
  note "- yarn ${major:-?}.x (berry) keeps caches per-project; nothing global to clean"
  exit 0
fi

cache_dir_cmd yarn cache dir

if updating; then
  days="$(cooldown_days)"
  if [ "$days" -gt 0 ]; then
    note "- cooldown active (${days}d): Yarn classic cannot filter by release age, so global upgrades are held"
    summary_note "global upgrades held by the ${days}-day cooldown"
  else
    step yarn global upgrade -s
  fi
fi

if cleaning; then
  step yarn cache clean
fi
