#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: mas
# group: Package managers
# default: on
# summary: report pending Mac App Store updates (installing them needs sudo, which scrubmac never uses)
# Mac App Store: list pending app updates. mas installs updates as root —
# it re-runs itself through sudo — so scrubmac, which never escalates, only
# reports them and leaves `mas update` to you.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless mas

report mas outdated
skip_unless_updating

printf '%s+ %s%s\n' "$CMM_DIM" "mas outdated" "$CMM_RESET"
pending="$(mas outdated 2>/dev/null)" || pending=''
if [ -n "$pending" ]; then
  printf '%s\n' "$pending"
  count="$(printf '%s\n' "$pending" | awk 'NF { n++ } END { print n + 0 }')"
  note "- App Store updates need administrator rights (mas uses sudo), so scrubmac only reports them: run 'mas update' yourself"
  summary_note "$count App Store update(s) pending — run 'mas update' yourself"
else
  note "- no App Store updates pending"
fi
