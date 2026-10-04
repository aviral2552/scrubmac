#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: brew
# group: Package managers
# default: on
# summary: update Homebrew, upgrade formulae (casks per APP_UPDATES), autoremove, clean up
# Homebrew: refresh the index, upgrade formulae — and casks when a person is
# watching (APP_UPDATES: a cask upgrade can quit a running app or stop for a
# password) — run the advisory health checks, drop unneeded dependencies, and
# scrub the download cache. A failed upgrade does not stop the cleanup.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless brew

export HOMEBREW_NO_ENV_HINTS=1
# Never wait for a "proceed? [y/n]" answer (Homebrew 6 asks on a TTY).
export HOMEBREW_NO_ASK=1

cache_dir_cmd brew --cache
# Reports and previews must not change brew's own state: no auto-update.
report env HOMEBREW_NO_AUTO_UPDATE=1 brew outdated
preview env HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --formula --dry-run
if app_updates_allowed; then
  preview env HOMEBREW_NO_AUTO_UPDATE=1 brew upgrade --cask --dry-run
fi
preview brew cleanup -s --prune=all --dry-run

if updating; then
  step brew update
  export HOMEBREW_NO_AUTO_UPDATE=1 # just refreshed; don't re-check per command
  step brew upgrade --formula
  if app_updates_allowed; then
    step brew upgrade --cask
  elif [ "${CMM_APP_UPDATES:-interactive}" = never ]; then
    note "- casks not upgraded: APP_UPDATES=never"
    summary_note "casks not upgraded (APP_UPDATES=never)"
  else
    note "- casks not upgraded: unattended run (APP_UPDATES=${CMM_APP_UPDATES:-interactive})"
    summary_note "casks not upgraded (unattended run; APP_UPDATES=${CMM_APP_UPDATES:-interactive})"
  fi
  if [ "$(setting HOMEBREW_DOCTOR 1)" = 1 ]; then
    try brew doctor # advisory: non-zero just means "it has opinions"
    try brew missing
  fi
fi

if cleaning; then
  try brew autoremove
  step brew cleanup -s --prune=all
fi
