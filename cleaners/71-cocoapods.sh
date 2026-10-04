#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: pod
# group: Apple development
# default: on
# summary: clear the CocoaPods download cache (spec repos are kept)
# CocoaPods: clear the downloaded-pod cache (~/Library/Caches/CocoaPods/
# Pods). Spec repos are left alone; the next `pod install` re-downloads what
# a project needs.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless pod

cache_dir "${CP_CACHE_DIR:-$HOME/Library/Caches/CocoaPods}/Pods"
skip_unless_cleaning

step pod cache clean --all
