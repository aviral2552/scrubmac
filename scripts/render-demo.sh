#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# render-demo.sh — regenerate docs/demo.svg: a real scrubmac run against a
# sandboxed, fake toolchain (stub brew/npm/uv/… that print plausible output),
# rendered as an animated terminal. Reproducible and leaks nothing about the
# machine it runs on. Usage: scripts/render-demo.sh [OUTPUT.svg]
# shellcheck disable=SC2016  # the stub bodies are literal sh, expanded when they run
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
OUT="${1:-$ROOT/docs/demo.svg}"
SB="$(mktemp -d "${TMPDIR:-/tmp}/scrubmac-demo.XXXXXX")"
trap 'rm -rf "$SB"' EXIT
mkdir -p "$SB/home" "$SB/bin" "$SB/tmp"

# stub NAME BODY — a fake tool (POSIX sh) in the sandbox bin dir.
stub() {
  printf '#!/bin/sh\n%s\n' "$2" >"$SB/bin/$1"
  chmod 755 "$SB/bin/$1"
}
stub brew 'case "$1" in
  --prefix) echo /opt/homebrew ;;
  update) sleep 2; echo "Updated 2 taps (homebrew/core and homebrew/cask)." ;;
  upgrade) sleep 3; echo "==> Upgrading 3 outdated packages:"; echo "git 2.55.0 -> 2.56.0"; echo "node 24.19.0 -> 24.20.0"; echo "uv 0.12.21 -> 0.12.22" ;;
  cleanup) echo "Removing: ~/Library/Caches/Homebrew/node--24.19.0.tar.gz... (21.4MB)" ;;
  doctor) echo "Your system is ready to brew." ;;
esac
exit 0'
stub npm 'case "$1" in
  --version) echo 11.19.1 ;;
  update) sleep 1; echo "changed 3 packages in 2s" ;;
  cache) echo "Cache verified and compressed (~/.npm/_cacache)" ;;
esac
exit 0'
stub node 'exit 0'
stub uv 'case "$1 $2" in
  "--version "*) echo "uv 0.12.22 (Homebrew)" ;;
  "tool upgrade") sleep 1; echo "Updated ruff v0.16.9 -> v0.16.10" ;;
  "cache prune") echo "Removed 1,284 files (412.3MiB)" ;;
esac
exit 0'
stub pipx 'echo "No packages upgraded after running '"'"'pipx upgrade-all'"'"'"; exit 0'
stub claude 'sleep 1; echo "Successfully updated from 2.1.287 to version 2.1.288"; exit 0'
stub gh 'exit 0'
stub rustup 'sleep 2; echo "  stable-aarch64-apple-darwin unchanged - rustc 1.98.1"; exit 0'

export HOME="$SB/home" XDG_CONFIG_HOME="$SB/home/.config" TMPDIR="$SB/tmp"
export PATH="$SB/bin:/usr/bin:/bin:/usr/sbin:/sbin" NO_COLOR=1 CMM_OFFLINE=0 CMM_NOTIFY=never
export CMM_COOLDOWN_DAYS=0 CMM_BREW_PREFIX=/opt/homebrew CMM_ASSUME_INTERACTIVE=0
mkdir -p "$XDG_CONFIG_HOME/scrubmac"
printf 'QUIET=1\n' >"$XDG_CONFIG_HOME/scrubmac/config"

run_out="$("$ROOT/bin/scrubmac" homebrew npm python claude gh rustup 2>&1 || true)"

# Keep the opening line and the summary; tidy sandbox paths for display.
lines="$(printf '%s\n' "$run_out" | awk '
  NR == 1 { print; print ""; next }
  /^Summary$/ { on = 1 }
  on && !/^log: / { print }
' | sed "s|$SB/home|~|g")"
lines="\$ scrubmac -q homebrew npm python claude gh rustup"$'\n'"$lines"$'\n'"log: ~/.local/state/scrubmac/logs/run-…log"

printf '%s\n' "$lines" | awk -v out="$OUT" '
  function esc(s) { gsub(/&/, "\\&amp;", s); gsub(/</, "\\&lt;", s); gsub(/>/, "\\&gt;", s); return s }
  { line[++n] = $0 }
  END {
    lh = 20; top = 52; w = 760; h = top + n * lh + 24
    printf "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"%d\" height=\"%d\" viewBox=\"0 0 %d %d\" role=\"img\" aria-label=\"scrubmac run summary\">\n", w, h, w, h > out
    printf "<style>\n" > out
    printf "text{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:14px;fill:#d4d4d4;white-space:pre}\n" > out
    printf ".l{opacity:0;animation:in .25s ease forwards}.ok{fill:#7ee787}.skip{fill:#8b949e}.fail{fill:#ff7b72}.dim{fill:#8b949e}.cmd{fill:#79c0ff}.hd{font-weight:bold}\n" > out
    printf "@keyframes in{to{opacity:1}}\n</style>\n" > out
    printf "<rect width=\"%d\" height=\"%d\" rx=\"10\" fill=\"#0d1117\"/>\n", w, h > out
    printf "<circle cx=\"20\" cy=\"18\" r=\"6\" fill=\"#ff5f57\"/><circle cx=\"40\" cy=\"18\" r=\"6\" fill=\"#febc2e\"/><circle cx=\"60\" cy=\"18\" r=\"6\" fill=\"#28c840\"/>\n" > out
    for (i = 1; i <= n; i++) {
      s = line[i]; cls = ""
      if (i == 1) cls = " cmd"
      else if (s ~ /^  ok /) cls = " ok"
      else if (s ~ /^  skip /) cls = " skip"
      else if (s ~ /^  (FAIL|TIMEOUT|REFUSED) /) cls = " fail"
      else if (s ~ /^ +· / || s ~ /^log: / || s ~ /^=+$/) cls = " dim"
      else if (s == "Summary") cls = " hd"
      delay = (i - 1) * 0.12
      printf "<text class=\"l%s\" x=\"20\" y=\"%d\" style=\"animation-delay:%.2fs\" xml:space=\"preserve\">%s</text>\n", cls, top + (i - 1) * lh, delay, esc(s) > out
    }
    printf "</svg>\n" > out
  }'
echo "wrote $OUT"
