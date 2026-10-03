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
# Safety (see docs/security.md): a directory is deleted only when it holds a
# scrubmac/cleanmymac install — never "/", your home or a parent of it, never
# a directory with anything else in it — and a link only when it points into
# one. Paths are compared in canonical form, so "$HOME/." or a symlinked
# parent cannot slip past the checks.
#
# Overrides (mainly for tests): CMM_PREFIX (install dir), CMM_OLD_PREFIX
# (legacy dir), CMM_BIN_DIR (symlink dir).
set -euo pipefail

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  printf 'error: uninstall.sh must not run as root\n' >&2
  exit 2
fi

usage() { printf 'usage: uninstall.sh [--purge]\n'; }

PURGE=0
case "${1:-}" in
  --purge) PURGE=1 ;;
  '') ;;
  -h | --help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac
if [ "$#" -gt 1 ]; then
  usage >&2
  exit 2
fi

SELF_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [ ! -f "$SELF_DIR/lib/common.sh" ]; then
  printf 'error: run uninstall.sh from a scrubmac install or source tree (no lib/common.sh next to it)\n' >&2
  exit 2
fi
# shellcheck source=lib/common.sh
. "$SELF_DIR/lib/common.sh"

die() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

RAW_DEST="${CMM_PREFIX:-$HOME/.scrubmac}"
RAW_OLD="${CMM_OLD_PREFIX:-$HOME/.cleanmymac}"
# The last component stays unresolved: a symlink at either path is a link
# to remove, not a directory to follow.
DEST_DIR="$(cmm_canon_parent "$RAW_DEST")" || die "unusable install dir '$RAW_DEST'"
OLD_DEST="$(cmm_canon_parent "$RAW_OLD")" || die "unusable legacy dir '$RAW_OLD'"
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/scrubmac"
OLD_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cleanmymac"
STATE_DIR="${CMM_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/scrubmac}"
LABEL='com.github.aviral2552.scrubmac'
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
REFUSED=0

# ours LINK — a symlink into this install or the legacy one (dangling ok).
ours() {
  points_into "$1" "$DEST_DIR" || points_into "$1" "$RAW_DEST" ||
    points_into "$1" "$OLD_DEST" || points_into "$1" "$RAW_OLD"
}

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
    "$DEST_DIR"/* | "$RAW_DEST"/* | "$OLD_DEST"/* | "$RAW_OLD"/*)
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
  if points_into "$OLD_DEST" "$DEST_DIR" || points_into "$OLD_DEST" "$RAW_DEST"; then
    rm -f "$OLD_DEST"
    echo "removed compat symlink $OLD_DEST"
  else
    echo "note: left $OLD_DEST alone — it is a symlink to $(readlink "$OLD_DEST"), not to this install"
  fi
fi

# remove_install DIR — delete DIR only when it is a real directory holding
# a scrubmac/cleanmymac install (or nothing at all).
remove_install() {
  local dir="$1"
  echo "Removing ${dir}…"
  if [ -L "$dir" ] || [ ! -e "$dir" ]; then
    echo "$dir not present — nothing to remove"
    return 0
  fi
  if cmm_unsafe_target "$dir"; then
    echo "error: refusing to remove $dir — that is /, your home, or a parent of it" >&2
    REFUSED=1
    return 0
  fi
  if [ ! -d "$dir" ] || ! cmm_is_install_dir "$dir"; then
    echo "error: left $dir alone — it does not look like a scrubmac install (delete it yourself if it is one)" >&2
    REFUSED=1
    return 0
  fi
  rm -rf "${dir:?}"
}
remove_install "$DEST_DIR"
[ "$OLD_DEST" = "$DEST_DIR" ] || remove_install "$OLD_DEST"

# purge_dir DIR — the config and state dirs, which must be named scrubmac or
# cleanmymac; a symlink there (a dotfiles manager's) loses only the link.
purge_dir() {
  local dir="$1" canon
  if [ -L "$dir" ]; then
    rm -f "$dir"
    echo "removed link $dir (its target was kept)"
    return 0
  fi
  [ -e "$dir" ] || return 0
  canon="$(cmm_canon_path "$dir")" || canon=''
  case "${canon##*/}" in
    scrubmac | cleanmymac) ;;
    *) canon='' ;;
  esac
  if [ -z "$canon" ] || cmm_unsafe_target "$canon"; then
    echo "error: left $dir alone — not a scrubmac config or state directory" >&2
    REFUSED=1
    return 0
  fi
  rm -rf "${canon:?}"
  echo "removed $dir"
}

# keep_note WHAT DIR — say what was kept and how to remove it; this script
# may itself be gone by now, so --purge is offered only while it exists.
keep_note() {
  if [ -d "$SELF_DIR" ]; then
    echo "Kept $1 at $2 (re-run with --purge to remove)"
  else
    echo "Kept $1 at $2 (remove with: rm -rf \"$2\")"
  fi
}

if [ "$PURGE" -eq 1 ]; then
  echo "Removing configuration and state…"
  purge_dir "$OLD_CONFIG_DIR"
  purge_dir "$CONFIG_DIR"
  purge_dir "$STATE_DIR"
else
  if [ -d "$CONFIG_DIR" ]; then
    keep_note "your configuration" "$CONFIG_DIR"
  fi
  if [ -d "$STATE_DIR" ]; then
    keep_note "run logs" "$STATE_DIR"
  fi
fi

crontab_text="$(crontab -l 2>/dev/null || true)"
case "$crontab_text" in
  *scrubmac* | *cleanmymac*)
    echo "warning: your crontab still runs scrubmac/cleanmymac — remove that line ('crontab -e')"
    ;;
esac

if [ ! -e "$DEST_DIR" ] && [ "$SELF_DIR" != "$DEST_DIR" ] && [ -d "$SELF_DIR" ] &&
  [ ! -e "$SELF_DIR/.git" ] && cmm_is_install_dir "$SELF_DIR"; then
  echo "note: this script lives in $SELF_DIR, which was not removed; if that is the"
  echo "      install you meant, run: CMM_PREFIX=\"$SELF_DIR\" \"$SELF_DIR/uninstall.sh\""
fi

if [ "$REFUSED" -eq 1 ]; then
  echo "scrubmac was partly uninstalled — see the errors above."
  exit 1
fi
echo "scrubmac has been uninstalled."
