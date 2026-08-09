#!/usr/bin/env bash
# Part of cleanmymac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: conda
# Conda: upgrade all packages and clean caches. -y is mandatory — without it
# conda prompts and a non-interactive run would hang forever (F4).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless conda

run conda update --all -y
run conda clean --all -y
