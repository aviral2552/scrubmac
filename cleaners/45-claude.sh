#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: claude
# group: AI tools
# default: on
# summary: Claude Code: self-update (never touches ~/.claude)
# Claude Code: self-update native installs (`claude update`), upgrade the
# binary-only Homebrew cask (where `claude update` does nothing), defer npm
# installs to the npm cleaner. Never touches ~/.claude — it holds sessions,
# memory, and auth (D3).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless claude
skip_unless_updating

case "$(install_kind claude)" in
  brew)
    brew_cask_upgrade_self claude ||
      note "- claude is Homebrew-managed; the homebrew cleaner keeps it updated"
    ;;
  *) ai_self_update claude claude update ;;
esac
