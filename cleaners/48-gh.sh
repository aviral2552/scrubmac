#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: gh
# group: AI tools
# default: on
# summary: upgrade GitHub CLI extensions (gh itself is updated by its manager)
# GitHub CLI: upgrade every installed extension. gh itself is usually
# brew-managed and updated by the homebrew cleaner.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless gh

report gh extension list
skip_unless_updating

step gh extension upgrade --all # exits 0 when there is nothing to upgrade
