#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: mise
# mise: self-update standalone installs (-y — it prompts otherwise), report
# outdated tool versions, and clear its cache. `mise upgrade` is deliberately
# NOT run: bumping pinned tool versions is a per-project decision.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless mise

ai_self_update mise mise self-update -y
try mise outdated
run mise cache clear
