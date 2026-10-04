#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: deno
# group: JavaScript
# default: on
# summary: self-update standalone Deno installs (deno upgrade)
# Deno: `deno upgrade` replaces the running executable, so it only runs for
# standalone installs; Homebrew/npm-managed copies are updated by those
# cleaners. The module cache is left alone (`deno clean` would wipe all of it).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless deno
skip_unless_updating

ai_self_update deno deno upgrade
