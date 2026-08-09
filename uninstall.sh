#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
#
# uninstall.sh — remove scrubmac (and any pre-rename cleanmymac remnants).
# Never sudo.
#
#   ./uninstall.sh            removes the app dir(s) + PATH/man symlinks;
#                             keeps ~/.config/scrubmac (your choices)
#   ./uninstall.sh --purge    also removes the config dir(s)
#
# Overrides (mainly for tests): CMM_PREFIX (install dir), CMM_OLD_PREFIX
# (legacy dir).
set -euo pipefail

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  printf 'error: uninstall.sh must not run as root\n' >&2
  exit 2
fi

PURGE=0
case "${1:-}" in
  --purge) PURGE=1 ;;
  '') ;;
  *)
    printf 'usage: uninstall.sh [--purge]\n' >&2
    exit 2
    ;;
esac

DEST_DIR="${CMM_PREFIX:-$HOME/.scrubmac}"
OLD_DEST="${CMM_OLD_PREFIX:-$HOME/.cleanmymac}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/scrubmac"
OLD_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cleanmymac"

# points_into LINK DIR — true when LINK is a symlink whose target lives in
# DIR (including dangling links left by older layouts).
points_into() {
  local target
  [ -L "$1" ] || return 1
  target="$(readlink "$1")"
  case "$target" in
    "$2"/*) return 0 ;;
    *) return 1 ;;
  esac
}

echo "Removing launcher symlinks…"
BREW_BIN=""
if command -v brew >/dev/null 2>&1; then
  BREW_BIN="$(brew --prefix 2>/dev/null)/bin"
fi
FOUND=0
for d in "${CMM_BIN_DIR:-}" "$BREW_BIN" /usr/local/bin "$HOME/.local/bin"; do
  [ -n "$d" ] || continue
  for name in scrubmac cleanmymac; do
    link="$d/$name"
    if points_into "$link" "$DEST_DIR" || points_into "$link" "$OLD_DEST"; then
      if [ -w "$d" ]; then
        rm -f "$link"
        echo "removed $link"
        FOUND=1
      else
        echo "cannot remove $link (no write access) — remove it yourself:"
        echo "  sudo rm $link"
      fi
    fi
  done
done
# Catch-all: whatever `command -v` still finds, if it is ours.
for name in scrubmac cleanmymac; do
  link="$(command -v "$name" 2>/dev/null || true)"
  if [ -n "$link" ] && { points_into "$link" "$DEST_DIR" || points_into "$link" "$OLD_DEST"; } && [ -w "$(dirname "$link")" ]; then
    rm -f "$link"
    echo "removed $link"
    FOUND=1
  fi
done
[ "$FOUND" -eq 0 ] && echo "no launcher symlink found (nothing to do)"

if [ -n "$BREW_BIN" ]; then
  for name in scrubmac cleanmymac; do
    manlink="${BREW_BIN%/bin}/share/man/man1/$name.1"
    if { points_into "$manlink" "$DEST_DIR" || points_into "$manlink" "$OLD_DEST"; } && [ -w "$(dirname "$manlink")" ]; then
      rm -f "$manlink"
      echo "removed $manlink"
    fi
  done
fi

# The rename migration leaves a compat symlink at the old install path.
if [ -L "$OLD_DEST" ]; then
  rm -f "$OLD_DEST"
  echo "removed compat symlink $OLD_DEST"
fi

for dir in "$DEST_DIR" "$OLD_DEST"; do
  echo "Removing ${dir}…"
  if [ -d "$dir" ] && [ ! -L "$dir" ]; then
    rm -rf "$dir"
  else
    echo "$dir not present — nothing to remove"
  fi
done

if [ "$PURGE" -eq 1 ]; then
  echo "Removing configuration…"
  [ -L "$OLD_CONFIG_DIR" ] && rm -f "$OLD_CONFIG_DIR"
  rm -rf "$CONFIG_DIR" "$OLD_CONFIG_DIR"
else
  if [ -d "$CONFIG_DIR" ]; then
    echo "Kept your configuration at $CONFIG_DIR (remove with: uninstall.sh --purge)"
  fi
fi

echo "scrubmac has been uninstalled."
