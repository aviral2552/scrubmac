#!/usr/bin/env bash
# Part of cleanmymac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: codex
# OpenAI Codex CLI: self-update standalone installs only. Never touches
# ~/.codex — it holds sessions and auth (D3).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless codex

ai_self_update codex codex update
