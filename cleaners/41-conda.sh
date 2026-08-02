#!/usr/bin/env bash
# gate: conda
# Conda: upgrade all packages and clean caches. -y is mandatory — without it
# conda prompts and a non-interactive run would hang forever (F4).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless conda

run conda update --all -y
run conda clean --all -y
