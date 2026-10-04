#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: cargo-install-update
# group: Languages
# default: on
# summary: upgrade binaries installed with cargo install (requires cargo-update)
# Cargo: upgrade every binary installed with `cargo install`, via the
# cargo-update extension (`cargo install-update`; install it with
# `cargo install cargo-update` to enable this cleaner).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless cargo-install-update
skip_unless cargo

report cargo install-update -l
skip_unless_updating

step cargo install-update -a
