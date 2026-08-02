#!/usr/bin/env bash
# gate: docker
# Docker (disabled by default — enable with `cleanmymac enable docker`):
# prune the build cache and dangling images ONLY. Containers, volumes, and
# tagged images are never touched (D3).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless docker

if ! docker info >/dev/null 2>&1; then
  skip "skipping: docker daemon is not running"
fi

try docker system df
run docker builder prune -f
run docker image prune -f
