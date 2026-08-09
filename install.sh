#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
#
# install.sh — install scrubmac into ~/.scrubmac and link it onto PATH.
#
# Safety properties (see docs/security.md):
#   - never runs sudo, refuses to run as root
#   - resolves its own location from BASH_SOURCE, never from $PWD
#   - never deletes the directory it was run from
#   - idempotent: re-running refreshes the install in place
#
# 2026 rename migration (cleanmymac → scrubmac), in this order:
#   1. config dir migrated BEFORE the fresh-config seeding below — otherwise
#      seeding would create ~/.config/scrubmac and block the migration forever
#   2. ~/.cleanmymac moved to ~/.scrubmac with a compat symlink left behind
#      (old hardcoded cron paths keep working through the in-tree shim)
#   3. handles being re-run from INSIDE the old install dir (the normal case:
#      the shim tells users to re-run install.sh, which lives right there)
#
# Overrides (mainly for tests): CMM_PREFIX (install dir), CMM_OLD_PREFIX
# (legacy dir), CMM_BIN_DIR (symlink dir).
set -euo pipefail

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  printf 'error: install.sh must not run as root — scrubmac is a per-user tool\n' >&2
  exit 2
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${CMM_PREFIX:-$HOME/.scrubmac}"
OLD_DEST="${CMM_OLD_PREFIX:-$HOME/.cleanmymac}"

# Sanity: make sure we are running from a real scrubmac source tree.
if [ ! -x "$SRC_DIR/bin/scrubmac" ] || [ ! -f "$SRC_DIR/lib/common.sh" ]; then
  printf 'error: %s does not look like a scrubmac source tree\n' "$SRC_DIR" >&2
  exit 2
fi

# shellcheck source=lib/common.sh
. "$SRC_DIR/lib/common.sh"

# choose_bin_dir CANDIDATE… — first user-writable candidate dir, falling
# back to ~/.local/bin (created if needed). CMM_BIN_DIR overrides everything.
# Pure function; unit-tested. Prints nothing when no candidate is usable.
choose_bin_dir() {
  local d
  if [ -n "${CMM_BIN_DIR:-}" ]; then
    mkdir -p "$CMM_BIN_DIR" 2>/dev/null || true
    [ -d "$CMM_BIN_DIR" ] && [ -w "$CMM_BIN_DIR" ] && printf '%s\n' "$CMM_BIN_DIR"
    return 0
  fi
  for d in "$@"; do
    if [ -n "$d" ] && [ -d "$d" ] && [ -w "$d" ]; then
      printf '%s\n' "$d"
      return 0
    fi
  done
  d="$HOME/.local/bin"
  if mkdir -p "$d" 2>/dev/null && [ -w "$d" ]; then
    printf '%s\n' "$d"
  fi
  return 0
}

# points_into LINK DIR — symlink whose target lives under DIR (incl. dangling).
points_into() {
  local target
  [ -L "$1" ] || return 1
  target="$(readlink "$1")"
  case "$target" in
    "$2"/*) return 0 ;;
    *) return 1 ;;
  esac
}

echo "Installing scrubmac $(cat "$SRC_DIR/VERSION" 2>/dev/null || echo '') into $DEST_DIR"

# --- rename migration step 1: config dir (BEFORE any seeding) ---
cmm_migrate_config_dir

# --- rename migration steps 2+3: install dir, incl. self-hosted re-run ---
if [ -d "$OLD_DEST" ] && [ ! -L "$OLD_DEST" ] && [ ! -e "$DEST_DIR" ]; then
  mv "$OLD_DEST" "$DEST_DIR"
  ln -s "$DEST_DIR" "$OLD_DEST"
  echo "Migrated $OLD_DEST -> $DEST_DIR (compat symlink left for old cron paths)"
  case "$SRC_DIR" in
    "$OLD_DEST" | "$OLD_DEST"/*) SRC_DIR="$DEST_DIR${SRC_DIR#"$OLD_DEST"}" ;;
  esac
fi

if [ "$SRC_DIR" = "$DEST_DIR" ]; then
  echo "(already running from $DEST_DIR — refreshing links only)"
else
  mkdir -p "$DEST_DIR"
  # --delete keeps the app dir an exact mirror: files removed upstream (and
  # legacy layouts) disappear. User state is never here — it lives in
  # ~/.config/scrubmac.
  rsync -a --delete "$SRC_DIR/" "$DEST_DIR/"
fi

BREW_BIN=""
if command -v brew >/dev/null 2>&1; then
  BREW_BIN="$(brew --prefix 2>/dev/null)/bin"
fi
BIN_DIR="$(choose_bin_dir "$BREW_BIN" /usr/local/bin)"

if [ -n "$BIN_DIR" ]; then
  ln -fs "$DEST_DIR/bin/scrubmac" "$BIN_DIR/scrubmac"
  echo "Linked: $BIN_DIR/scrubmac -> $DEST_DIR/bin/scrubmac"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
      echo "note: $BIN_DIR is not on your PATH — add this to your shell profile:"
      echo "  export PATH=\"$BIN_DIR:\$PATH\""
      ;;
  esac
else
  echo "note: no writable bin directory found; run it directly:"
  echo "  $DEST_DIR/bin/scrubmac"
fi

# --- rename migration step 4: retire old-name links (bin + man) ---
for d in "${CMM_BIN_DIR:-}" "$BREW_BIN" /usr/local/bin "$HOME/.local/bin"; do
  [ -n "$d" ] || continue
  link="$d/cleanmymac"
  if { points_into "$link" "$DEST_DIR" || points_into "$link" "$OLD_DEST"; } && [ -w "$d" ]; then
    rm -f "$link"
    echo "removed old-name link $link (the command is now 'scrubmac')"
  fi
done

# Link the man page into brew's manpath when possible (never sudo) — only
# when the launcher itself went into brew's bin, so overridden installs
# (CMM_BIN_DIR sandboxes, tests) never write outside their own tree.
if [ -n "$BREW_BIN" ] && [ "$BIN_DIR" = "$BREW_BIN" ] && [ -f "$DEST_DIR/man/scrubmac.1" ]; then
  MAN_DIR="${BREW_BIN%/bin}/share/man/man1"
  if [ -d "$MAN_DIR" ] && [ -w "$MAN_DIR" ]; then
    ln -fs "$DEST_DIR/man/scrubmac.1" "$MAN_DIR/scrubmac.1"
    echo "Linked man page into $MAN_DIR"
    oldman="$MAN_DIR/cleanmymac.1"
    if points_into "$oldman" "$DEST_DIR" || points_into "$oldman" "$OLD_DEST"; then
      rm -f "$oldman"
    fi
  fi
fi

# --- rename migration step 5: tell the user about anything left behind ---
if crontab -l 2>/dev/null | grep -q cleanmymac; then
  echo "warning: your crontab still references 'cleanmymac' — old paths keep"
  echo "         working via the compat shim, but update them to 'scrubmac'."
fi
leftover="$(command -v cleanmymac 2>/dev/null || true)"
if [ -n "$leftover" ]; then
  case "$leftover" in
    "$DEST_DIR"/* | "$OLD_DEST"/*) ;;
    *)
      echo "note: 'cleanmymac' on your PATH is now $leftover (MacPaw's CLI),"
      echo "      not this tool — update crontabs/aliases to 'scrubmac'."
      ;;
  esac
fi

# Seed the opt-in default for heavy pruners (docker, xcode) so the state is
# visible and editable — only on a truly fresh setup (D3). Runs AFTER the
# config migration above, so an existing cleanmymac config is never shadowed.
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/scrubmac"
if [ ! -f "$CONFIG_DIR/config" ] && [ ! -f "$CONFIG_DIR/disabled" ]; then
  mkdir -p "$CONFIG_DIR"
  printf 'docker\nxcode\n' >"$CONFIG_DIR/disabled"
  echo "Heavy pruners (docker, xcode) start disabled — 'scrubmac enable docker' or the wizard opts in."
fi

echo
echo "Done. The command is 'scrubmac' (alias cleanmymac=scrubmac if your fingers insist)."
echo "Run 'scrubmac' to start, or 'scrubmac help' for the command reference."
