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
# (legacy dir), CMM_BIN_DIR (symlink dir), CMM_LINK_DIRS (where else
# launcher links may live; default /usr/local/bin:~/.local/bin).
set -euo pipefail
unset CDPATH # (cd would search it, and print where it went)

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
REMOVED=0

# Validate before touching anything: a mistyped CMM_PREFIX must not cost the
# real install its launcher links and schedule on the way to a refusal — nor
# your configuration (--purge would remove it while the install stays).
if [ "$PURGE" -eq 1 ] && [ -n "${CMM_PREFIX:-}" ] && [ ! -e "$DEST_DIR" ] && [ ! -L "$DEST_DIR" ]; then
  printf 'error: nothing at %s — check CMM_PREFIX (nothing was removed; without CMM_PREFIX, --purge removes the configuration and logs on their own)\n' "$DEST_DIR" >&2
  exit 1
fi
if cmm_unsafe_target "$DEST_DIR"; then
  printf 'error: refusing to remove %s — that is /, your home, or a parent of it\n' "$DEST_DIR" >&2
  exit 1
fi
if [ -e "$DEST_DIR" ] && [ ! -L "$DEST_DIR" ] && { [ ! -d "$DEST_DIR" ] || ! cmm_is_install_dir "$DEST_DIR"; }; then
  printf 'error: left %s alone — it does not look like a scrubmac install (nothing was removed)\n' "$DEST_DIR" >&2
  exit 1
fi
# A symlink at the install path (install.sh follows one and installs into its
# target): links and the schedule are matched against the target too.
DEST_TARGET=''
if [ -L "$DEST_DIR" ]; then
  DEST_TARGET="$(cmm_canon_path "$DEST_DIR" 2>/dev/null || true)"
  if [ -n "$DEST_TARGET" ] && { cmm_unsafe_target "$DEST_TARGET" || ! cmm_is_install_dir "$DEST_TARGET"; }; then
    echo "note: $DEST_DIR is a symlink to $DEST_TARGET, which is not a scrubmac install — only the link will be removed"
    DEST_TARGET=''
  fi
fi
# The legacy path counts only when it is the compat link or a real install.
OLD_OURS=0
if [ -L "$OLD_DEST" ] || { [ -d "$OLD_DEST" ] && ! cmm_unsafe_target "$OLD_DEST" && cmm_is_install_dir "$OLD_DEST"; }; then
  OLD_OURS=1
fi

# ours LINK — a symlink into this install or the legacy one (dangling ok).
ours() {
  points_into "$1" "$DEST_DIR" || points_into "$1" "$RAW_DEST" && return 0
  [ -n "$DEST_TARGET" ] && points_into "$1" "$DEST_TARGET" && return 0
  [ "$OLD_OURS" = 1 ] && { points_into "$1" "$OLD_DEST" || points_into "$1" "$RAW_OLD"; }
}

echo "Removing launcher symlinks…"
BREW_PREFIX=""
if command -v brew >/dev/null 2>&1; then
  BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
fi
BREW_BIN=""
[ -n "$BREW_PREFIX" ] && BREW_BIN="$BREW_PREFIX/bin"
FOUND=0
while IFS= read -r d; do
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
done <<EOF
$(cmm_launcher_dirs "${CMM_BIN_DIR:-}" "$BREW_BIN")
EOF
# Catch-all: whatever `command -v` still finds, if it is ours.
for name in scrubmac cleanmymac; do
  link="$(command -v "$name" 2>/dev/null || true)"
  if [ -n "$link" ] && ours "$link" && [ -w "$(dirname "$link")" ]; then
    rm -f "$link"
    echo "removed $link"
    FOUND=1
  fi
done
if [ "$FOUND" -eq 0 ]; then
  echo "no launcher symlink found (nothing to do)"
else
  REMOVED=1
fi

if [ -n "$BREW_PREFIX" ]; then
  for link in "$BREW_PREFIX/share/man/man1/scrubmac.1" "$BREW_PREFIX/share/man/man1/cleanmymac.1" \
    "$BREW_PREFIX/share/zsh/site-functions/_scrubmac" "$BREW_PREFIX/etc/bash_completion.d/scrubmac" \
    "$BREW_PREFIX/share/fish/vendor_completions.d/scrubmac.fish"; do
    if ours "$link" && [ -w "$(dirname "$link")" ]; then
      rm -f "$link"
      echo "removed $link"
      REMOVED=1
    fi
  done
fi

# A launchd schedule that runs THIS install goes with it.
if [ -f "$PLIST" ]; then
  # the first <string> after <key>ProgramArguments</key>, XML-unescaped (a
  # plist saved in binary form is read through plutil)
  program="$(cmm_plist_xml "$PLIST" | awk '
    { buf = buf $0 "\n" }
    END {
      i = index(buf, "<key>ProgramArguments</key>")
      if (!i) exit
      rest = substr(buf, i)
      if (!match(rest, /<string>[^<]*<\/string>/)) exit
      v = substr(rest, RSTART + 8, RLENGTH - 17)
      gsub(/&lt;/, "<", v); gsub(/&gt;/, ">", v); gsub(/&quot;/, "\"", v); gsub(/&amp;/, "\\&", v)
      print v
    }' 2>/dev/null || true)"
  mine=0
  case "$program" in
    "$DEST_DIR"/* | "$RAW_DEST"/*) mine=1 ;;
    "$OLD_DEST"/* | "$RAW_OLD"/*) [ "$OLD_OURS" = 1 ] && mine=1 ;;
  esac
  if [ -n "$DEST_TARGET" ]; then
    case "$program" in "$DEST_TARGET"/*) mine=1 ;; esac
  fi
  case "$mine" in
    1)
      if command -v launchctl >/dev/null 2>&1; then
        launchctl bootout "gui/$(id -u)/$LABEL" >/dev/null 2>&1 || true
      fi
      rm -f "$PLIST"
      echo "removed the launchd schedule ($PLIST)"
      REMOVED=1
      ;;
    *)
      if [ -n "$program" ]; then
        echo "note: kept the launchd schedule — it runs $program, not this install ('scrubmac schedule off' removes it)"
      else
        echo "note: kept $PLIST — could not tell which program it runs; if it ran this install, remove it:"
        echo "  launchctl bootout gui/$(id -u)/$LABEL; rm \"$PLIST\""
      fi
      ;;
  esac
fi

# The rename migration leaves a compat symlink at the old install path.
if [ -L "$OLD_DEST" ]; then
  if points_into "$OLD_DEST" "$DEST_DIR" || points_into "$OLD_DEST" "$RAW_DEST"; then
    rm -f "$OLD_DEST"
    echo "removed compat symlink $OLD_DEST"
    REMOVED=1
  else
    echo "note: left $OLD_DEST alone — it is a symlink to $(readlink "$OLD_DEST"), not to this install"
  fi
fi

# remove_install DIR — delete DIR only when it is a real directory holding
# a scrubmac/cleanmymac install (or nothing at all).
remove_install() {
  local dir="$1"
  echo "Removing ${dir}…"
  if [ ! -e "$dir" ] && [ ! -L "$dir" ]; then
    echo "$dir not present — nothing to remove"
    return 0
  fi
  if [ -L "$dir" ]; then
    rm -f "$dir"
    echo "removed the symlink $dir"
    REMOVED=1
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
  # a clone install.sh did not make may hold someone's work (see install.sh)
  if [ ! -f "$dir/.scrubmac-install" ] && why="$(cmm_local_work "$dir")"; then
    echo "error: left $dir alone — it is a git checkout with $why (delete it yourself once nothing in it is needed)" >&2
    REFUSED=1
    return 0
  fi
  rm -rf "${dir:?}"
  REMOVED=1
}
remove_install "$DEST_DIR"
# The target of a symlinked install path goes too when install.sh made it
# (its marker file); anything else — a dev clone the path linked to is a
# supported setup — is kept.
if [ -n "$DEST_TARGET" ] && [ -d "$DEST_TARGET" ]; then
  if [ -f "$DEST_TARGET/.scrubmac-install" ]; then
    remove_install "$DEST_TARGET"
  else
    echo "note: kept $DEST_TARGET (the install path pointed there, and install.sh did not create it — a dev clone?) — delete it yourself if you no longer need it"
    REFUSED=1
  fi
fi
if [ "$OLD_DEST" != "$DEST_DIR" ] && [ "$OLD_OURS" = 1 ] && [ ! -L "$OLD_DEST" ]; then
  remove_install "$OLD_DEST"
fi

# purge_dir DIR — the config and state dirs, which must be named scrubmac or
# cleanmymac; a symlink there (a dotfiles manager's) loses only the link.
purge_dir() {
  local dir="$1" canon
  if [ -L "$dir" ]; then
    rm -f "$dir"
    echo "removed link $dir (its target was kept)"
    REMOVED=1
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
  REMOVED=1
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

if { crontab -l 2>/dev/null || true; } | grep -v '^[[:space:]]*#' |
  grep -Eq '(^|[/[:space:]"'"'"'(;&|`])scrubmac([[:space:]"'"'"';&|<>)`]|$)' ||
  cmm_cron_old_name "$DEST_DIR" "$OLD_DEST" "${RAW_DEST%/}" "${RAW_OLD%/}" ${DEST_TARGET:+"$DEST_TARGET"}; then
  echo "warning: your crontab still runs scrubmac/cleanmymac — remove that line ('crontab -e')"
fi

if [ ! -e "$DEST_DIR" ] && [ "$SELF_DIR" != "$DEST_DIR" ] && [ -d "$SELF_DIR" ] &&
  [ ! -e "$SELF_DIR/.git" ] && cmm_is_install_dir "$SELF_DIR"; then
  echo "note: this script lives in $SELF_DIR, which was not removed; if that is the"
  echo "      install you meant, run: CMM_PREFIX=\"$SELF_DIR\" \"$SELF_DIR/uninstall.sh\""
fi

if [ "$REFUSED" -eq 1 ]; then
  echo "scrubmac was partly uninstalled — see the errors above."
  exit 1
fi
if [ "$REMOVED" -eq 0 ]; then
  echo "nothing to uninstall — no scrubmac install, link or schedule was found here."
  exit 0
fi
echo "scrubmac has been uninstalled."
