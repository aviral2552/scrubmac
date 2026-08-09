#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: brew
# Homebrew: update, upgrade formulae + casks, drop unneeded deps, health
# checks, and scrub the download cache.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless brew

export HOMEBREW_NO_ENV_HINTS=1
run brew update
run brew upgrade
try brew autoremove
try brew doctor # advisory: non-zero just means "it has opinions"
try brew missing
run brew cleanup -s --prune=all
