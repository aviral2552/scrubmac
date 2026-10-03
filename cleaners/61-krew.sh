#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: kubectl-krew
# group: Developer tools
# default: on
# summary: upgrade kubectl plugins installed with krew
# krew: refresh the plugin index and upgrade every kubectl plugin installed
# with krew (and krew itself, when krew manages it).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless kubectl-krew
skip_unless kubectl

report kubectl krew list
skip_unless_updating

step kubectl krew upgrade
