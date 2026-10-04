#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: swift
# group: Apple development
# default: on
# summary: purge the global Swift Package Manager repository cache
# Swift Package Manager: purge the global dependency cache (repository
# clones, registry downloads, manifests); packages re-fetch on the next
# resolve. purge-cache works on the package in the current directory — it
# writes .build there, and SwiftPM before 6.3 refuses to run without a
# Package.swift ("Could not find Package.swift in this directory or any of
# its parent directories") — so it runs from a throwaway directory holding a
# placeholder manifest, never inside (or under) a real package.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless swift

cache_dir "$HOME/Library/Caches/org.swift.swiftpm"
skip_unless_cleaning

scratch="$(cmm_scratch_dir)"
cd "$scratch"
printf '%s\n' '// swift-tools-version:5.3' 'import PackageDescription' \
  'let package = Package(name: "scrubmac-purge-cache")' >Package.swift
step swift package purge-cache # step never aborts, so the cleanup below always runs
cd /
rm -rf "$scratch"
