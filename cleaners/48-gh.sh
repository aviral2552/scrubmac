#!/usr/bin/env bash
# gate: gh
# GitHub CLI: upgrade every installed extension (including Copilot). gh
# itself is usually brew-managed and updated by the homebrew cleaner.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless gh

try gh extension upgrade --all # advisory: exits non-zero when none installed
