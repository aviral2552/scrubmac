#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: docker
# group: Developer tools
# default: off
# summary: prune build cache unused for DOCKER_KEEP_HOURS and dangling images (never containers/volumes)
# Docker (disabled by default — enable with `scrubmac enable docker`):
# prune build cache not used within DOCKER_KEEP_HOURS (default 168 = a week)
# and dangling images ONLY. Containers, volumes, and tagged images are never
# touched (D3). Docker Desktop's disk image is sparse and returns freed space
# to macOS gradually, so the disk-freed figure can lag.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless docker

if ! docker info >/dev/null 2>&1; then
  skip "skipping: docker daemon is not running"
fi

report docker system df
skip_unless_cleaning

hours="$(setting DOCKER_KEEP_HOURS 168)"
case "$hours" in '' | *[!0-9]*) hours=168 ;; esac

preview docker system df
try docker system df
step docker builder prune -f --filter "until=${hours}h"
step docker image prune -f
