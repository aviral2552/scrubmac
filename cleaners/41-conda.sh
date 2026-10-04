#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: conda micromamba
# group: Python
# default: on
# summary: update conda itself in the base env (never --all), self-update standalone micromamba, clean package caches
# Conda: update conda itself in the base environment — the documented
# `conda update -n base conda`, never `--all`, which would churn every
# package in base — unless base is frozen (CEP 22), then clean caches and
# unused packages. micromamba: self-update standalone installs and clean its
# caches. -y everywhere: without it conda prompts and a non-interactive run
# would hang forever (F4).
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

if ! have conda && ! have micromamba; then
  skip "skipping: no conda tooling found (conda, micromamba)"
fi

if have conda; then
  report conda update -n base conda --dry-run
  if updating; then
    base="$(conda info --base 2>/dev/null || true)"
    if [ -n "$base" ] && [ -e "$base/conda-meta/frozen" ]; then
      note "- the base environment is frozen (conda-meta/frozen): leaving conda's version alone"
      summary_note "base environment is frozen — conda not updated"
    else
      step conda update -n base conda -y
    fi
  fi
  if cleaning; then
    step conda clean --all -y
  fi
fi

if have micromamba; then
  if updating; then
    ai_self_update micromamba micromamba self-update
  fi
  if cleaning; then
    step micromamba clean --all -y
  fi
fi
