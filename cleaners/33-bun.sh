#!/usr/bin/env bash
# gate: bun
# Bun: clear the global package cache.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless bun

run bun pm cache rm
