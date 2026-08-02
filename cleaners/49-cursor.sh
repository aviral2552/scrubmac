#!/usr/bin/env bash
# gate: cursor-agent
# Cursor CLI agent: usually a standalone (curl) install with its own
# updater. Never touches ~/.cursor — it holds sessions and auth (D3).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless cursor-agent

ai_self_update cursor-agent cursor-agent update
