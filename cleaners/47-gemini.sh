#!/usr/bin/env bash
# gate: gemini
# Gemini CLI: almost always npm- or brew-managed, in which case those
# cleaners update it; standalone installs get a pointer, not a guess.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless gemini

ai_self_update gemini
