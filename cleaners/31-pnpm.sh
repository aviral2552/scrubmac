#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: pnpm
# group: JavaScript
# default: on
# summary: update global packages within their ranges (cooldown via minimumReleaseAge), self-update standalone pnpm, prune the store
# pnpm: update global packages within the ranges they were installed with —
# the supply-chain cooldown is passed as pnpm's own minimumReleaseAge
# (minutes; enforced by pnpm >= 10.16) — self-update standalone installs,
# and drop unreferenced packages from the content-addressable store.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless pnpm

cache_dir_cmd pnpm store path
report pnpm outdated -g

if updating; then
  days="$(cooldown_days)"
  age=()
  if [ "$days" -gt 0 ]; then
    age=("--config.minimum-release-age=$((days * 1440))")
  fi
  ai_self_update pnpm pnpm self-update ${age[@]+"${age[@]}"}
  step pnpm update -g ${age[@]+"${age[@]}"}
fi

if cleaning; then
  step pnpm store prune
fi
