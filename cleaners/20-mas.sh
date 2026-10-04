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
rc=0
pending="$(mas outdated 2>/dev/null)" || rc=$? # stderr: one NSError dump per failed lookup
count=0
if [ -n "$pending" ]; then
  printf '%s\n' "$pending"
  count="$(printf '%s\n' "$pending" | awk 'NF { n++ } END { print n + 0 }')"
fi
if [ "$rc" -ne 0 ]; then
  # a report, not an update: say so loudly, but do not fail the run
  warn "'mas outdated' exited $rc — the App Store could not be checked (fully); run 'mas outdated' to see why"
  summary_note "could not check the App Store (mas outdated exited $rc)"
fi
if [ "$count" -gt 0 ]; then
  note "- App Store updates need administrator rights (mas uses sudo), so scrubmac only reports them: run 'mas update' yourself"
  summary_note "$count App Store update(s) pending — run 'mas update' yourself"
elif [ "$rc" -eq 0 ]; then
  note "- no App Store updates pending"
fi
