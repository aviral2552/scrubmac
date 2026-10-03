#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: composer
# group: Languages
# default: on
# summary: upgrade global Composer packages and clear the download cache
# Composer: upgrade global packages (non-interactively) and clear the
# download cache.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless composer

# `composer global …` runs in the global Composer home; without a
# composer.json there (no global packages) update/outdated just error out.
global_home="$(composer config --global home 2>/dev/null || true)"
has_globals=0
[ -n "$global_home" ] && [ -f "$global_home/composer.json" ] && has_globals=1

cache_dir_cmd composer config --global cache-dir
if [ "$has_globals" = 1 ]; then
  report composer global outdated
fi

if updating; then
  if [ "$has_globals" = 1 ]; then
    step composer global update --no-interaction
  else
    note "- no global Composer packages (no composer.json in ${global_home:-the global Composer home})"
  fi
fi

if cleaning; then
  step composer clear-cache
fi
