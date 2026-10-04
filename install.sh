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
#     scrubmac install — never into a directory that holds anything else,
#     nor into someone's working clone (a symlinked install path whose
#     target install.sh did not create, or a git checkout with local work)
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
# (legacy dir), CMM_BIN_DIR (symlink dir), CMM_LINK_DIRS (where else
# launcher links may live; default /usr/local/bin:~/.local/bin).
set -euo pipefail
unset CDPATH # (cd would search it, and print where it went)

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

# ours LINK — a symlink into this install (or the legacy one), dangling ok;
# the paths as given count too (an older installer wrote them unresolved).
RAW_DEST="${CMM_PREFIX:-$HOME/.scrubmac}"
RAW_OLD="${CMM_OLD_PREFIX:-$HOME/.cleanmymac}"
ours() {
  points_into "$1" "$DEST_DIR" || points_into "$1" "$OLD_DEST" ||
    points_into "$1" "${RAW_DEST%/}" || points_into "$1" "${RAW_OLD%/}"
}

# link_ours TARGET LINK LABEL — create LINK -> TARGET unless something that
# is not ours already sits at LINK. A dangling link is nobody's working
# install, so it is replaced.
FOREIGN_LAUNCHER=''
link_ours() {
  local target="$1" link="$2" label="$3"
  if [ -e "$link" ] || [ -L "$link" ]; then
    if [ -L "$link" ] && [ ! -e "$link" ] && ! ours "$link"; then
      echo "note: replaced the dangling $label link $link (it pointed to $(readlink "$link"))"
    elif ! ours "$link"; then
      echo "note: $link already exists and is not from this installer (Homebrew's scrubmac?) — left alone; skipped the $label link"
      [ "$label" = launcher ] && FOREIGN_LAUNCHER="$link"
      return 1
    fi
  fi
  ln -fsn "$target" "$link"
}

die() {
  printf 'error: %s\n' "$1" >&2
  exit 2
}

# Canonical paths only: "$HOME/." or a symlinked parent must not slip past
# the guards below (rsync --delete erases whatever is in the way).
if [ -L "$DEST_DIR" ] && [ ! -e "$DEST_DIR" ]; then
  die "$DEST_DIR is a symlink to $(readlink "$DEST_DIR"), which does not exist — create that directory first, or remove the link"
fi
DEST_LINK=''
[ -L "${DEST_DIR%/}" ] && DEST_LINK="${DEST_DIR%/}"
DEST_DIR="$(cmm_canon_path "$DEST_DIR")" || die "unusable install dir '${CMM_PREFIX:-$HOME/.scrubmac}' (no . or .. components, and it must not be a file)"
OLD_DEST="$(cmm_canon_parent "$OLD_DEST")" || die "unusable legacy dir '${CMM_OLD_PREFIX:-$HOME/.cleanmymac}'"
SRC_DIR="$(cmm_canon_path "$SRC_DIR")" || die "cannot resolve the source tree"
if cmm_unsafe_target "$DEST_DIR"; then
  die "refusing to install into $DEST_DIR — that is /, your home, or a parent of it; choose a dedicated directory"
fi

echo "Installing scrubmac $(cat "$SRC_DIR/VERSION" 2>/dev/null || echo '') into $DEST_DIR"

# --- rename migration step 1: config dir ---
cmm_migrate_config_dir

# --- rename migration steps 2+3: install dir, incl. self-hosted re-run ---
# Only a directory that really holds a cleanmymac install is moved: it is
# mirrored over right after (rsync --delete), so anything else must be left
# exactly where it is.
MIGRATED=0
if [ -d "$OLD_DEST" ] && [ ! -L "$OLD_DEST" ] && [ ! -e "$DEST_DIR" ]; then
  if cmm_unsafe_target "$OLD_DEST" || ! cmm_is_install_dir "$OLD_DEST"; then
    echo "note: $OLD_DEST is not a cleanmymac install — left alone (nothing migrated from it)"
  elif why="$(cmm_local_work "$OLD_DEST")"; then
    die "$OLD_DEST is a git checkout with $why — refusing to migrate it (the mirror that follows would erase that); commit and push, or move it away, first"
  else
    MIGRATED=1
    mv "$OLD_DEST" "$DEST_DIR"
    ln -s "$DEST_DIR" "$OLD_DEST"
    echo "Migrated $OLD_DEST -> $DEST_DIR (compat symlink left for old cron paths)"
    case "$SRC_DIR" in
      "$OLD_DEST" | "$OLD_DEST"/*) SRC_DIR="$DEST_DIR${SRC_DIR#"$OLD_DEST"}" ;;
    esac
  fi
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
  if [ "$MIGRATED" = 0 ] && ! cmm_is_install_dir "$DEST_DIR"; then
    die "$DEST_DIR exists and is not a scrubmac install — refusing to mirror into it (that would delete its contents)"
  fi
  # A copy this installer did not make (no marker) may be a working clone:
  # the install path linked to one is a supported setup, and a clone placed
  # there directly may hold work. Mirroring would erase both, .git and all.
  if [ "$MIGRATED" = 0 ] && [ -n "$(ls -A "$DEST_DIR" 2>/dev/null)" ] && [ ! -f "$DEST_DIR/.scrubmac-install" ]; then
    if [ -n "$DEST_LINK" ]; then
      die "$DEST_LINK links to $DEST_DIR, which install.sh did not create (a working clone?) — run that copy's own install.sh, or remove the link first"
    fi
    if why="$(cmm_local_work "$DEST_DIR")"; then
      die "$DEST_DIR is a git checkout with $why — refusing to mirror over it (that would delete it); commit and push, or move it away, first"
    fi
  fi
  # Never mirror an older copy over a newer one: re-running a stale clone's
  # (or an unmigrated ~/.cleanmymac's) install.sh would downgrade silently.
  if [ "$MIGRATED" = 0 ] && [ -f "$DEST_DIR/VERSION" ]; then
    new_ver="$(cat "$SRC_DIR/VERSION" 2>/dev/null || echo 0)"
    cur_ver="$(cat "$DEST_DIR/VERSION" 2>/dev/null || echo 0)"
    if [ "$new_ver" != "$cur_ver" ] && cmm_version_ge "$cur_ver" "$new_ver"; then
      die "$DEST_DIR has scrubmac $cur_ver, newer than this copy ($new_ver) — run the newer copy's install.sh, or remove $DEST_DIR first to go back"
    fi
  fi
  mkdir -p "$DEST_DIR"
  # --delete keeps the app dir an exact mirror: files removed upstream (and
  # legacy layouts) disappear. User state is never here — it lives in
  # ~/.config/scrubmac and ~/.local/state/scrubmac. A source whose .git is
  # a file (a git worktree or submodule) points into another repository;
  # sharing it would let `scrubmac update` move that repository's branches.
  if [ -f "$SRC_DIR/.git" ]; then
    echo "note: $SRC_DIR is a git worktree or submodule — installing without its git metadata ('scrubmac update' will not work for this copy)"
    rsync -a --delete --exclude=/.git "$SRC_DIR/" "$DEST_DIR/"
  else
    rsync -a --delete "$SRC_DIR/" "$DEST_DIR/"
  fi
  # Marks a copy this installer made (uninstall.sh deletes the target of a
  # symlinked install path only when it carries this; a dev clone does not).
  { printf 'installed by install.sh from %s\n' "$SRC_DIR" >"$DEST_DIR/.scrubmac-install"; } 2>/dev/null || true
  if [ -d "$DEST_DIR/.git/info" ] && ! grep -qx '/.scrubmac-install' "$DEST_DIR/.git/info/exclude" 2>/dev/null; then
    { printf '/.scrubmac-install\n' >>"$DEST_DIR/.git/info/exclude"; } 2>/dev/null || true
  fi
fi

BREW_PREFIX=""
if command -v brew >/dev/null 2>&1; then
  BREW_PREFIX="$(brew --prefix 2>/dev/null || true)"
fi
BREW_BIN=""
[ -n "$BREW_PREFIX" ] && BREW_BIN="$BREW_PREFIX/bin"
LINK_DIRS=()
while IFS= read -r d; do
  LINK_DIRS+=("$d")
done <<EOF
$(cmm_link_dirs)
EOF
BIN_DIR="$(choose_bin_dir "$BREW_BIN" ${LINK_DIRS[@]+"${LINK_DIRS[@]}"})"

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
# ...unless a crontab line still calls cleanmymac: the link keeps that job
# running (through the shim) until the crontab is updated.
CRON_OLD=0
cmm_cron_old_name "$DEST_DIR" "$OLD_DEST" "${RAW_DEST%/}" "${RAW_OLD%/}" && CRON_OLD=1
while IFS= read -r d; do
  [ -n "$d" ] || continue
  link="$d/cleanmymac"
  if ours "$link" && [ -w "$d" ]; then
    if [ "$CRON_OLD" = 1 ]; then
      echo "kept old-name link $link — your crontab still calls cleanmymac; update it to 'scrubmac', then re-run install.sh"
    else
      rm -f "$link"
      echo "removed old-name link $link (the command is now 'scrubmac')"
    fi
  fi
done <<EOF
$(cmm_launcher_dirs "${CMM_BIN_DIR:-}" "$BREW_BIN")
EOF

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
if [ "$CRON_OLD" = 1 ]; then
  echo "warning: your crontab still references 'cleanmymac' — it keeps working"
  echo "         through the compat shim for now; update it to 'scrubmac'."
fi
leftover="$(command -v cleanmymac 2>/dev/null || true)"
if [ -n "$leftover" ] && ! ours "$leftover"; then
  case "$leftover" in
    "$DEST_DIR"/* | "$OLD_DEST"/*) ;;
    *)
      echo "note: 'cleanmymac' on your PATH is now $leftover — not this tool"
      echo "      (MacPaw's CleanMyMac has a command of that name); update"
      echo "      crontabs/aliases to 'scrubmac'."
      ;;
  esac
fi

# A 2.x install that could not be moved (both dirs existed) is left alone.
if [ -d "$OLD_DEST" ] && [ ! -L "$OLD_DEST" ] && [ "$OLD_DEST" != "$DEST_DIR" ] &&
  [ -n "$(ls -A "$OLD_DEST" 2>/dev/null)" ] && cmm_is_install_dir "$OLD_DEST"; then
  echo "note: an old cleanmymac install is still at $OLD_DEST (not migrated, because"
  echo "      $DEST_DIR already existed) — delete it once nothing runs it any more."
fi

# Opt-in cleaners (heavier pruners) start disabled; name them so the state is
# never a surprise (an earlier version's choices are kept: 'scrubmac list').
optin="$({ grep -l '^# default: off' "$DEST_DIR"/cleaners/*.sh 2>/dev/null || true; } | sed 's|.*/||; s/^[0-9]*-//; s/\.sh$//' | tr '\n' ' ')"
echo
[ -n "$optin" ] && echo "Opt-in cleaners (off unless you turn them on): ${optin}— 'scrubmac enable <name>' or the wizard; 'scrubmac list' shows what is on."
if [ -n "$FOREIGN_LAUNCHER" ]; then
  uninst="$DEST_DIR/uninstall.sh"
  [ "$DEST_DIR" = "$(cmm_canon_path "$HOME/.scrubmac" 2>/dev/null || echo "$HOME/.scrubmac")" ] ||
    uninst="CMM_PREFIX=\"$DEST_DIR\" $uninst"
  echo "note: two installs now exist — $FOREIGN_LAUNCHER (not from this installer;"
  echo "      probably Homebrew's) and this copy at $DEST_DIR. 'scrubmac' runs the"
  echo "      first one on your PATH; keep one: 'brew uninstall scrubmac', or"
  echo "      $uninst"
fi
echo "Done. Run 'scrubmac' to start, 'scrubmac help' for the command reference,"
echo "and 'scrubmac schedule weekly' to keep things tidy automatically."
