#!/usr/bin/env bash
# Part of cleanmymac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: xcodebuild
# Xcode (disabled by default — enable with `cleanmymac enable xcode`):
# delete simulators for runtimes that are no longer installed, and purge
# DerivedData folders untouched for CMM_DERIVEDDATA_AGE_DAYS (default 30).
# DerivedData is a regenerable build cache; the age gate avoids forcing
# rebuilds of projects you are actively working on.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless xcodebuild

try xcrun simctl delete unavailable

dd_dir="$HOME/Library/Developer/Xcode/DerivedData"
age="${CMM_DERIVEDDATA_AGE_DAYS:-30}"
if [ -d "$dd_dir" ]; then
  found=0
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    found=1
    run rm -rf "$d"
  done <<EOF
$(find "$dd_dir" -mindepth 1 -maxdepth 1 -type d -mtime "+$age" 2>/dev/null)
EOF
  if [ "$found" -eq 0 ]; then
    note "- no DerivedData older than $age days"
  fi
else
  note "- no DerivedData directory"
fi
