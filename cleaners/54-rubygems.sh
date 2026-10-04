#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: gem
# group: Languages
# default: off
# summary: remove superseded versions of installed gems (opt-in; never macOS's system Ruby)
# RubyGems (disabled by default — enable with `scrubmac enable rubygems`):
# `gem cleanup` uninstalls OLD versions of installed gems that nothing still
# requires. They are installed software rather than a cache (a project
# pinned to an old version reinstalls it), hence opt-in. macOS's system Ruby
# is never touched: its gems belong to the OS and live in a root-owned
# directory.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless gem

gem_bin="$(resolve_self "$(command -v gem)")"
case "$gem_bin" in
  /usr/bin/* | /System/*)
    skip "skipping: this is macOS's system Ruby — use a Ruby from Homebrew, rbenv, asdf or mise"
    ;;
esac
gemdir="$(gem env gemdir 2>/dev/null || true)"
case "$gemdir" in
  /Library/Ruby/* | /System/*)
    skip "skipping: gems live in macOS's system Ruby directory ($gemdir)"
    ;;
esac

skip_unless_cleaning
preview gem cleanup -d # -d: RubyGems < 3.2 rejects --dry-run
step gem cleanup
