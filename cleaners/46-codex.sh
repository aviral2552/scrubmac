#!/usr/bin/env bash
# gate: codex
# OpenAI Codex CLI: self-update standalone installs only. Never touches
# ~/.codex — it holds sessions and auth (D3).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless codex

ai_self_update codex codex update
