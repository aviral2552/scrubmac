#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: poetry
# group: Python
# default: on
# summary: self-update standalone Poetry; clear its repository caches
# Poetry: self-update installs made by the official installer (pipx- and
# Homebrew-managed copies are left to those managers — `poetry self update`
# would modify their environments behind their backs), and clear every
# repository cache listed by `poetry cache list` (-n: it asks otherwise).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless poetry

cache_dir_cmd poetry config cache-dir

if updating; then
  ai_self_update poetry poetry self update
fi

if cleaning; then
  caches="$(poetry cache list 2>/dev/null | awk '/^[A-Za-z0-9_.-]+$/ { print }')" || caches=''
  if [ -z "$caches" ]; then
    note "- no Poetry caches to clear"
  fi
  for c in $caches; do
    step poetry cache clear "$c" --all -n
  done
fi
