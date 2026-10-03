#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
#
# uninstall.sh — remove scrubmac (and any pre-rename cleanmymac remnants).
# Never sudo.
#
#   ./uninstall.sh            removes the app dir(s), PATH/man/completion
#                             links, and a schedule pointing at this install;
#                             keeps ~/.config/scrubmac (your choices)
#   ./uninstall.sh --purge    also removes the config and state dirs (logs)
#
# Overrides (mainly for tests): CMM_PREFIX (install dir), CMM_OLD_PREFIX
# (legacy dir), CMM_BIN_DIR (symlink dir).
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
STATE_DIR="${CMM_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/scrubmac}"
LABEL='com.github.aviral2552.scrubmac'
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"

# points_into LINK DIR — true when LINK is a symlink whose target lives in
# DIR (including dangling links left by older layouts).
points_into() {
  local target
  [ -L "$1" ] || return 1
  target="$(readlink "$1")"
  case "$target" in
    "$2" | "$2"/*) return 0 ;;
  esac
  return 1
}
ours() { points_into "$1" "$DEST_DIR" || points_into "$1" "$OLD_DEST"; }

echo "Removing launcher symlinks…"
BREW_PREFIX=""
if command -v brew >/dev/null 2>&1; then
  BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
fi
BREW_BIN=""
[ -n "$BREW_PREFIX" ] && BREW_BIN="$BREW_PREFIX/bin"
FOUND=0
for d in "${CMM_BIN_DIR:-}" "$BREW_BIN" /usr/local/bin "$HOME/.local/bin"; do
  [ -n "$d" ] || continue
  for name in scrubmac cleanmymac; do
    link="$d/$name"
    if ours "$link"; then
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
  if [ -n "$link" ] && ours "$link" && [ -w "$(dirname "$link")" ]; then
    rm -f "$link"
    echo "removed $link"
    FOUND=1
  fi
done
[ "$FOUND" -eq 0 ] && echo "no launcher symlink found (nothing to do)"

if [ -n "$BREW_PREFIX" ]; then
  for link in "$BREW_PREFIX/share/man/man1/scrubmac.1" "$BREW_PREFIX/share/man/man1/cleanmymac.1" \
    "$BREW_PREFIX/share/zsh/site-functions/_scrubmac" "$BREW_PREFIX/etc/bash_completion.d/scrubmac" \
    "$BREW_PREFIX/share/fish/vendor_completions.d/scrubmac.fish"; do
    if ours "$link" && [ -w "$(dirname "$link")" ]; then
      rm -f "$link"
      echo "removed $link"
    fi
  done
fi

# A launchd schedule that runs THIS install goes with it.
if [ -f "$PLIST" ]; then
  program="$(awk '
    /<key>ProgramArguments<\/key>/ { found = 1; next }
    found && /<string>/ { s = $0; sub(/^[ \t]*<string>/, "", s); sub(/<\/string>[ \t]*$/, "", s); print s; exit }
  ' "$PLIST" 2>/dev/null || true)"
  case "$program" in
    "$DEST_DIR"/* | "$OLD_DEST"/*)
      if command -v launchctl >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
      fi
      rm -f "$PLIST"
      echo "removed the launchd schedule ($PLIST)"
      ;;
    *)
      if [ -n "$program" ]; then
        echo "note: kept the launchd schedule — it runs $program, not this install ('scrubmac schedule off' removes it)"
      fi
      ;;
  esac
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
  echo "Removing configuration and state…"
  if [ -L "$OLD_CONFIG_DIR" ]; then rm -f "$OLD_CONFIG_DIR"; fi
  rm -rf "$CONFIG_DIR" "$OLD_CONFIG_DIR" "$STATE_DIR"
else
  if [ -d "$CONFIG_DIR" ]; then
    echo "Kept your configuration at $CONFIG_DIR (remove with: uninstall.sh --purge)"
  fi
  if [ -d "$STATE_DIR" ]; then
    echo "Kept run logs at $STATE_DIR (removed by --purge)"
  fi
fi

echo "scrubmac has been uninstalled."
