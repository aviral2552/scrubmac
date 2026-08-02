#!/usr/bin/env bash
# gate: composer
# Composer: upgrade global packages and clear the download cache.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless composer

run composer global update --no-interaction
run composer clear-cache
