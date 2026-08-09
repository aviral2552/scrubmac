#!/usr/bin/env bash
# Part of cleanmymac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: uv pipx python3
# Python tooling: uv self-update (standalone only) + tool upgrades + cache
# prune, pipx package upgrades, and pip cache purge. The uv upgrade honors
# the supply-chain cooldown natively via --exclude-newer (S4).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

if ! have uv && ! have pipx && ! have python3; then
  skip "skipping: no python tooling found (uv, pipx, python3)"
fi

if have uv; then
  ai_self_update uv uv self update
  if [ "${CMM_COOLDOWN_DAYS:-0}" -gt 0 ] 2>/dev/null; then
    try uv tool upgrade --all --exclude-newer "$(date_days_ago "$CMM_COOLDOWN_DAYS")"
  else
    try uv tool upgrade --all
  fi
  run uv cache prune
fi

if have pipx; then
  try pipx upgrade-all
fi

if have python3 && python3 -m pip --version >/dev/null 2>&1; then
  try python3 -m pip cache purge
fi
