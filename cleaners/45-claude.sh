#!/usr/bin/env bash
# gate: claude
# Claude Code: self-update standalone installs only (npm/brew installs are
# updated by those cleaners). Never touches ~/.claude — it holds sessions,
# memory, and auth (D3).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless claude

ai_self_update claude claude update
