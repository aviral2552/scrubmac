#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: bun
# group: JavaScript
# default: on
# summary: self-update standalone Bun, update global packages (cooldown via --minimum-release-age), clear the cache
# Bun: self-update standalone installs (`bun upgrade` replaces the binary in
# place, so Homebrew/npm-managed copies are left to their managers), update
# global packages — the supply-chain cooldown is passed as Bun's own
# --minimum-release-age (seconds; Bun >= 1.3) — and clear the global cache.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless bun

cache_dir_cmd bun pm cache

if updating; then
  ai_self_update bun bun upgrade
  days="$(cooldown_days)"
  if [ "$days" -eq 0 ]; then
    step bun update -g
  elif cmm_version_ge "$(bun --version 2>/dev/null || echo 0)" 1.3; then
    step bun update -g --minimum-release-age "$((days * 86400))"
  else
    note "- cooldown active (${days}d) but this Bun predates --minimum-release-age (1.3): global updates are held"
    summary_note "global updates held by the ${days}-day cooldown (Bun < 1.3)"
  fi
fi

if cleaning; then
  step bun pm cache rm
fi
