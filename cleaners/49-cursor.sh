#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: cursor-agent
# group: AI tools
# default: on
# summary: Cursor CLI agent: self-update (never touches ~/.cursor)
# Cursor CLI agent (installed as `agent`, with `cursor-agent` kept as an
# alias): self-update standalone installs, upgrade the binary-only Homebrew
# cask. Never touches ~/.cursor — it holds sessions and auth (D3).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless cursor-agent
skip_unless_updating

case "$(install_kind cursor-agent)" in
  brew)
    brew_cask_upgrade_self cursor-agent ||
      note "- cursor-agent is Homebrew-managed; the homebrew cleaner keeps it updated"
    ;;
  *) ai_self_update cursor-agent cursor-agent update ;;
esac
