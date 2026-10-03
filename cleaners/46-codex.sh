#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: codex
# group: AI tools
# default: on
# summary: OpenAI Codex CLI: self-update (never touches ~/.codex)
# OpenAI Codex CLI: `codex update` (0.128+) detects how Codex was installed
# and runs the matching updater (Homebrew cask, standalone installer); older
# releases have no update command — and would take "update" as a prompt — so
# it is only run when `codex --help` lists it. npm installs are left to the
# npm cleaner (which applies the cooldown). Never touches ~/.codex (D3).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless codex
skip_unless_updating

kind="$(install_kind codex)"
if [ "$kind" = npm ]; then
  note "- codex is npm-managed; the npm cleaner keeps it updated"
elif has_subcommand codex update; then
  step codex update
elif [ "$kind" = brew ]; then
  brew_cask_upgrade_self codex ||
    note "- codex is Homebrew-managed; the homebrew cleaner keeps it updated"
else
  note "- this codex predates 'codex update' (0.128); update it the way you installed it"
fi
