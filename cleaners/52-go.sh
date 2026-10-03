#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: go
# group: Languages
# default: off
# summary: clear the Go build cache (opt-in: Go already trims unused entries itself)
# Go (disabled by default — enable with `scrubmac enable go`): clear the
# build cache. Go already deletes build-cache entries it has not used
# recently, so clearing everything mostly forces cold rebuilds — hence
# opt-in. The module cache is never touched.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless go

cache_dir_cmd go env GOCACHE
skip_unless_cleaning

if cleaning; then
  step go clean -cache
fi
