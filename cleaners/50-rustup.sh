#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: rustup
# group: Languages
# default: on
# summary: update Rust toolchains (and rustup itself, unless manager-managed)
# Rust: update toolchains — and rustup itself, unless a package manager
# owns it (Homebrew's rustup is built without self-update and says so).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless rustup

# rustup >= 1.29 exits 100 from `rustup check` when updates are available
# (0 when there are none): for the status report that is news, not an error.
report --ok=100 rustup check
skip_unless_updating

step rustup update
