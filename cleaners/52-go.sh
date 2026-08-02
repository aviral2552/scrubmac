#!/usr/bin/env bash
# gate: go
# Go: clear the build cache. The module cache is left alone on purpose —
# purging it forces a re-download of every dependency of every project.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless go

run go clean -cache
