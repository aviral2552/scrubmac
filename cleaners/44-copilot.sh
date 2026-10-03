#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: copilot
# group: AI tools
# default: on
# summary: GitHub Copilot CLI: self-update (never touches ~/.copilot)
# GitHub Copilot CLI (the standalone `copilot`; the old `gh copilot`
# extension is retired): self-update standalone installs, upgrade the
# binary-only Homebrew cask, defer npm installs to the npm cleaner. Never
# touches ~/.copilot — it holds sessions and auth (D3).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless copilot
skip_unless_updating

case "$(install_kind copilot)" in
  brew)
    brew_cask_upgrade_self copilot ||
      note "- copilot is Homebrew-managed; the homebrew cleaner keeps it updated"
    ;;
  standalone)
    if has_subcommand copilot update; then
      step copilot update
    else
      note "- this copilot predates 'copilot update'; reinstall it from https://gh.io/copilot-install"
    fi
    ;;
  *) ai_self_update copilot ;;
esac
