#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: pre-commit
# group: Developer tools
# default: on
# summary: drop cached hook environments no recorded config uses (pre-commit gc)
# pre-commit: garbage-collect cached hook repositories and environments
# that no recorded .pre-commit-config.yaml still uses. The worst case is a
# re-install of a hook environment on the next commit.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless pre-commit

cache_dir "${PRE_COMMIT_HOME:-${XDG_CACHE_HOME:-$HOME/.cache}/pre-commit}"
skip_unless_cleaning

step pre-commit gc
