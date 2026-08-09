#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: npm
# npm: self-update (standalone installs only), report + update global
# packages, and garbage-collect the cache.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless npm

kind="$(install_kind npm)"
case "$kind" in
  standalone) run npm install -g npm@latest ;;
  npm) note "- npm is bundled with its node install; updating node updates npm" ;;
  *) note "- npm is ${kind}-managed; that manager updates it" ;;
esac

try npm outdated -g # advisory: exits 1 whenever anything is outdated

if [ "${CMM_COOLDOWN_DAYS:-0}" -gt 0 ] 2>/dev/null; then
  # Cooldown (S4): npm's --before flag DOWNGRADES globals installed more
  # recently than the cutoff (verified), so automatic updates are held
  # instead — review the outdated report above and update deliberately.
  note "- cooldown active (${CMM_COOLDOWN_DAYS}d): global npm updates are held;"
  note "  review 'npm outdated -g' above and update chosen packages manually"
else
  run npm update -g
fi

run npm cache verify
