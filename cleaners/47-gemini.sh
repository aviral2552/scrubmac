#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: gemini
# group: AI tools
# default: on
# summary: Gemini CLI: managed installs are updated by their cleaners; no self-update exists
# Gemini CLI has no self-update command (`gemini update` would start a chat
# with "update" as the prompt, so it is never run). npm installs are updated
# by the npm cleaner; Homebrew's gemini-cli formula is deprecated and no
# longer follows upstream releases, so the cleaner says so.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless gemini
skip_unless_updating

case "$(install_kind gemini)" in
  npm) note "- gemini is npm-managed; the npm cleaner keeps it updated" ;;
  brew)
    note "- gemini is Homebrew-managed, but Homebrew's gemini-cli formula is deprecated and no longer tracks releases — reinstall with: npm install -g @google/gemini-cli"
    summary_note "Homebrew's gemini-cli formula is deprecated — consider the npm package"
    ;;
  *) note "- gemini has no self-update command; update it the way you installed it" ;;
esac
