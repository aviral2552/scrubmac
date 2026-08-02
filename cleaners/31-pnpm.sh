#!/usr/bin/env bash
# gate: pnpm
# pnpm: drop unreferenced packages from the content-addressable store.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless pnpm

run pnpm store prune
