#!/usr/bin/env bash
# gate: rustup
# Rust: update toolchains (and rustup itself, unless manager-managed —
# rustup handles that distinction internally).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless rustup

run rustup update
