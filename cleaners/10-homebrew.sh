#!/usr/bin/env bash
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
