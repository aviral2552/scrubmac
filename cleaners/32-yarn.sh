#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: yarn
# Yarn: classic (v1) global upgrades + cache clean. Berry (v2+) keeps its
# caches per-project, so there is nothing global to do.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless yarn

major="$(yarn --version 2>/dev/null | cut -d. -f1)"
if [ "$major" = "1" ]; then
  run yarn global upgrade -s
  run yarn cache clean
else
  note "- yarn ${major:-?}.x (berry) keeps caches per-project; nothing global to clean"
fi
