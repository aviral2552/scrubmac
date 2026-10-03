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
#   - mirrors (rsync --delete) only into an empty directory or an existing
#     scrubmac install — never into a directory that holds anything else
#   - replaces a launcher, man page or completion link only when it is ours;
#     anything else at those paths (e.g. Homebrew's scrubmac) is left alone
#   - idempotent: re-running refreshes the install in place
#
# 2026 rename migration (cleanmymac → scrubmac), in this order:
#   1. config dir migrated first, so ~/.config/cleanmymac is adopted
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

# abs_dir PATH — PATH made absolute without requiring it to exist.
abs_dir() {
  local p="$1"
  case "$p" in /*) ;; *) p="$PWD/$p" ;; esac
  while [ "${#p}" -gt 1 ] && [ "${p%/}" != "$p" ]; do p="${p%/}"; done
  printf '%s\n' "$p"
}

# is_install_dir DIR — DIR is empty, or is (or was) a scrubmac/cleanmymac
# install: safe to mirror into with --delete.
is_install_dir() {
  local d="$1" entry
  [ -d "$d" ] || return 0
  for entry in "$d"/* "$d"/.[!.]*; do
    [ -e "$entry" ] || [ -L "$entry" ] || continue
    # non-empty: it must carry a scrubmac (or legacy cleanmymac) marker
    [ -e "$d/bin/scrubmac" ] || [ -e "$d/bin/cleanmymac" ] ||
      [ -e "$d/cleanmymac.sh" ] || [ -e "$d/scrubmac.sh" ] || [ -e "$d/setup/install.sh" ]
    return
  done
  return 0
}

# ours LINK — a symlink into this install (or the legacy one), dangling ok.
ours() { points_into "$1" "$DEST_DIR" || points_into "$1" "$OLD_DEST"; }

# link_ours TARGET LINK LABEL — create LINK -> TARGET unless something that
# is not ours already sits at LINK.
link_ours() {
  local target="$1" link="$2" label="$3"
  if [ -e "$link" ] || [ -L "$link" ]; then
    if ! ours "$link"; then
      echo "note: $link already exists and is not from this installer (Homebrew's scrubmac?) — left alone; skipped the $label link"
      return 1
    fi
  fi
  ln -fs "$target" "$link"
}

DEST_DIR="$(abs_dir "$DEST_DIR")"
OLD_DEST="$(abs_dir "$OLD_DEST")"
case "$DEST_DIR" in
  / | "$(abs_dir "$HOME")")
    printf 'error: refusing to install into %s — choose a dedicated directory\n' "$DEST_DIR" >&2
    exit 2
    ;;
esac

echo "Installing scrubmac $(cat "$SRC_DIR/VERSION" 2>/dev/null || echo '') into $DEST_DIR"

# --- rename migration step 1: config dir ---
cmm_migrate_config_dir

# --- rename migration steps 2+3: install dir, incl. self-hosted re-run ---
MIGRATED=0
if [ -d "$OLD_DEST" ] && [ ! -L "$OLD_DEST" ] && [ ! -e "$DEST_DIR" ]; then
  MIGRATED=1
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
  case "$SRC_DIR/" in
    "$DEST_DIR"/*)
      printf 'error: the source tree %s is inside the install dir %s — the mirror would delete it\n' "$SRC_DIR" "$DEST_DIR" >&2
      exit 2
      ;;
  esac
  case "$DEST_DIR/" in
    "$SRC_DIR"/*)
      printf 'error: the install dir %s is inside the source tree %s\n' "$DEST_DIR" "$SRC_DIR" >&2
      exit 2
      ;;
  esac
  # (a dir just moved here from the legacy install path is ours by definition)
  if [ "$MIGRATED" = 0 ] && ! is_install_dir "$DEST_DIR"; then
    printf 'error: %s exists and is not a scrubmac install — refusing to mirror into it (that would delete its contents)\n' "$DEST_DIR" >&2
    exit 2
  fi
  mkdir -p "$DEST_DIR"
  # --delete keeps the app dir an exact mirror: files removed upstream (and
  # legacy layouts) disappear. User state is never here — it lives in
  # ~/.config/scrubmac and ~/.local/state/scrubmac.
  rsync -a --delete "$SRC_DIR/" "$DEST_DIR/"
fi

BREW_PREFIX=""
if command -v brew >/dev/null 2>&1; then
  BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
fi
BREW_BIN=""
[ -n "$BREW_PREFIX" ] && BREW_BIN="$BREW_PREFIX/bin"
BIN_DIR="$(choose_bin_dir "$BREW_BIN" /usr/local/bin)"

if [ -z "$BIN_DIR" ]; then
  echo "note: no writable bin directory found; run it directly:"
  echo "  $DEST_DIR/bin/scrubmac"
elif link_ours "$DEST_DIR/bin/scrubmac" "$BIN_DIR/scrubmac" launcher; then
  echo "Linked: $BIN_DIR/scrubmac -> $DEST_DIR/bin/scrubmac"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
      echo "note: $BIN_DIR is not on your PATH — add this to your shell profile:"
      echo "  export PATH=\"$BIN_DIR:\$PATH\""
      ;;
  esac
else
  echo "  run this copy directly: $DEST_DIR/bin/scrubmac"
fi

# --- rename migration step 4: retire old-name links (bin + man) ---
for d in "${CMM_BIN_DIR:-}" "$BREW_BIN" /usr/local/bin "$HOME/.local/bin"; do
  [ -n "$d" ] || continue
  link="$d/cleanmymac"
  if ours "$link" && [ -w "$d" ]; then
    rm -f "$link"
    echo "removed old-name link $link (the command is now 'scrubmac')"
  fi
done

# Link the man page and shell completions into brew's tree when possible
# (never sudo) — only when the launcher itself went into brew's bin, so
# overridden installs (CMM_BIN_DIR sandboxes, tests) never write outside
# their own tree.
if [ -n "$BREW_BIN" ] && [ "$BIN_DIR" = "$BREW_BIN" ]; then
  MAN_DIR="$BREW_PREFIX/share/man/man1"
  if [ -f "$DEST_DIR/man/scrubmac.1" ] && [ -d "$MAN_DIR" ] && [ -w "$MAN_DIR" ]; then
    link_ours "$DEST_DIR/man/scrubmac.1" "$MAN_DIR/scrubmac.1" "man page" &&
      echo "Linked man page into $MAN_DIR"
    oldman="$MAN_DIR/cleanmymac.1"
    ours "$oldman" && rm -f "$oldman"
  fi
  for spec in "share/zsh/site-functions:_scrubmac" "etc/bash_completion.d:scrubmac.bash" "share/fish/vendor_completions.d:scrubmac.fish"; do
    cdir="$BREW_PREFIX/${spec%%:*}"
    file="${spec##*:}"
    name="$file"
    [ "$file" = scrubmac.bash ] && name=scrubmac
    if [ -f "$DEST_DIR/completions/$file" ] && [ -d "$cdir" ] && [ -w "$cdir" ]; then
      link_ours "$DEST_DIR/completions/$file" "$cdir/$name" "completion" &&
        echo "Linked shell completion into $cdir"
    fi
  done
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

# Opt-in cleaners (heavier pruners) are off until enabled; name them so the
# state is never a surprise.
optin="$({ grep -l '^# default: off' "$DEST_DIR"/cleaners/*.sh 2>/dev/null || true; } | sed 's|.*/||; s/^[0-9]*-//; s/\.sh$//' | tr '\n' ' ')"
echo
[ -n "$optin" ] && echo "Opt-in cleaners (off until you enable them): ${optin}— 'scrubmac enable <name>' or the wizard."
echo "Done. Run 'scrubmac' to start, 'scrubmac help' for the command reference,"
echo "and 'scrubmac schedule weekly' to keep things tidy automatically."
