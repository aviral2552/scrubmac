#!/usr/bin/env bash
# gate: mas
# Mac App Store: upgrade installed apps via the mas CLI.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless mas

try mas outdated
run mas upgrade
