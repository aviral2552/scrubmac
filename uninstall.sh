#!/usr/bin/env bash
# uninstall.sh — remove cleanmymac. Never sudo.
#
#   ./uninstall.sh            removes the app dir + PATH/man symlinks;
#                             keeps ~/.config/cleanmymac (your choices)
#   ./uninstall.sh --purge    also removes ~/.config/cleanmymac
#
# Overrides (mainly for tests): CMM_PREFIX (install dir).
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

DEST_DIR="${CMM_PREFIX:-$HOME/.cleanmymac}"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cleanmymac"

# points_into LINK DIR — true when LINK is a symlink whose target lives in
# DIR (including dangling links, e.g. left by a 1.x layout).
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
  link="$d/cleanmymac"
  if points_into "$link" "$DEST_DIR"; then
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
# Catch-all: whatever `command -v` still finds, if it is ours.
link="$(command -v cleanmymac 2>/dev/null || true)"
if [ -n "$link" ] && points_into "$link" "$DEST_DIR" && [ -w "$(dirname "$link")" ]; then
  rm -f "$link"
  echo "removed $link"
  FOUND=1
fi
[ "$FOUND" -eq 0 ] && echo "no launcher symlink found (nothing to do)"

if [ -n "$BREW_BIN" ]; then
  manlink="${BREW_BIN%/bin}/share/man/man1/cleanmymac.1"
  if points_into "$manlink" "$DEST_DIR" && [ -w "$(dirname "$manlink")" ]; then
    rm -f "$manlink"
    echo "removed $manlink"
  fi
fi

echo "Removing $DEST_DIR…"
if [ -d "$DEST_DIR" ]; then
  rm -rf "$DEST_DIR"
else
  echo "$DEST_DIR not present — nothing to remove"
fi

if [ "$PURGE" -eq 1 ]; then
  echo "Removing configuration $CONFIG_DIR…"
  rm -rf "$CONFIG_DIR"
else
  if [ -d "$CONFIG_DIR" ]; then
    echo "Kept your configuration at $CONFIG_DIR (remove with: uninstall.sh --purge)"
  fi
fi

echo "cleanmymac has been uninstalled."
