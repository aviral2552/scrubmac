#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: xcodebuild
# group: Apple development
# default: off
# summary: delete unavailable simulators; purge unused DerivedData and old device-support symbols (age-gated)
# Xcode (disabled by default — enable with `scrubmac enable xcode`):
# delete simulators for runtimes that are no longer installed; purge
# DerivedData folders whose project is gone or that Xcode has not used for
# DERIVEDDATA_AGE_DAYS (default 30), read from Xcode's own LastAccessedDate;
# and purge device-support symbol folders older than DEVICESUPPORT_AGE_DAYS
# (default 90), always keeping the newest per platform. All of it is
# regenerable; the age gates avoid forcing rebuilds of active projects and
# re-copying symbols for devices still in use. Nothing is touched while Xcode
# is running.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

dev="$HOME/Library/Developer/Xcode"
dd_dir="$dev/DerivedData"
ds_dirs=()
for platform in iOS watchOS tvOS visionOS macOS; do
  [ -d "$dev/$platform DeviceSupport" ] && ds_dirs+=("$dev/$platform DeviceSupport")
done
full_xcode=0
cmm_full_xcode && full_xcode=1

if [ "$full_xcode" = 0 ] && [ ! -d "$dd_dir" ] && [ "${#ds_dirs[@]}" -eq 0 ]; then
  skip "skipping: Xcode not found (no full Xcode selected, no DerivedData or device support)"
fi

cache_dir "$dd_dir" ${ds_dirs[@]+"${ds_dirs[@]}"}
skip_unless_cleaning

# dd_last_used DIR — epoch of Xcode's LastAccessedDate for DIR, if recorded.
dd_last_used() {
  local iso
  [ -f "$1/info.plist" ] && have plutil || return 1
  iso="$(plutil -extract LastAccessedDate raw -o - "$1/info.plist" 2>/dev/null)" || return 1
  cmm_iso_to_epoch "$iso"
}

# dd_workspace DIR — the project/workspace path Xcode recorded for DIR.
dd_workspace() {
  [ -f "$1/info.plist" ] && have plutil || return 0
  plutil -extract WorkspacePath raw -o - "$1/info.plist" 2>/dev/null || true
}

# recently_touched DIR DAYS — anything within two levels changed in DAYS.
recently_touched() {
  [ -n "$(find "$1" -maxdepth 2 -mtime "-$2" -print -quit 2>/dev/null)" ]
}

if [ "$full_xcode" = 1 ]; then
  try xcrun simctl delete unavailable
else
  note "- simulator cleanup needs a full Xcode (the active developer dir is ${CMM__DEVDIR:-not set})"
fi

if pgrep -x Xcode >/dev/null 2>&1; then
  note "- Xcode is running: DerivedData and device support are left alone this run"
  summary_note "Xcode was running — DerivedData and device support untouched"
  exit 0
fi

dd_age="${CMM_DERIVEDDATA_AGE_DAYS:-30}"
ds_age="${CMM_DEVICESUPPORT_AGE_DAYS:-90}"
case "$dd_age" in '' | *[!0-9]*) dd_age=30 ;; esac
case "$ds_age" in '' | *[!0-9]*) ds_age=90 ;; esac
now="$(date '+%s')"

if [ -d "$dd_dir" ]; then
  purged=0
  for d in "$dd_dir"/*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    reason=''
    ws="$(dd_workspace "$d")"
    if [ -n "$ws" ] && [ "${ws#/}" != "$ws" ] && [ ! -e "$ws" ]; then
      reason="its project no longer exists ($ws)"
    elif last="$(dd_last_used "$d")"; then
      if [ $((now - last)) -gt $((dd_age * 86400)) ]; then
        reason="not opened in Xcode for $(((now - last) / 86400)) days"
      fi
    elif ! recently_touched "$d" "$dd_age"; then
      reason="unchanged for over $dd_age days"
    fi
    [ -n "$reason" ] || continue
    note "- DerivedData/${d##*/}: $reason"
    step rm -rf "$d"
    purged=$((purged + 1))
  done
  [ "$purged" -eq 0 ] && note "- no DerivedData unused for $dd_age+ days"
else
  note "- no DerivedData directory"
fi

for ds in ${ds_dirs[@]+"${ds_dirs[@]}"}; do
  newest=''
  newest_m=0
  for d in "$ds"/*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    m="$(cmm_mtime "$d")"
    if [ "${m:-0}" -gt "$newest_m" ]; then
      newest_m="${m:-0}"
      newest="$d"
    fi
  done
  for d in "$ds"/*; do
    [ -d "$d" ] && [ ! -L "$d" ] || continue
    [ "$d" = "$newest" ] && continue # the current OS version stays
    recently_touched "$d" "$ds_age" && continue
    note "- ${ds##*/}/${d##*/}: older than $ds_age days"
    step rm -rf "$d"
  done
done
