#!/usr/bin/env bash
# install.sh — install cleanmymac into ~/.cleanmymac and link it onto PATH.
#
# Safety properties (see docs/security.md):
#   - never runs sudo, refuses to run as root
#   - resolves its own location from BASH_SOURCE, never from $PWD
#   - never deletes the directory it was run from (the 1.x installer did)
#   - idempotent: re-running refreshes the install in place
#
# Overrides (mainly for tests): CMM_PREFIX (install dir), CMM_BIN_DIR
# (symlink dir).
set -euo pipefail

if [ "${EUID:-$(id -u)}" -eq 0 ]; then
  printf 'error: install.sh must not run as root — cleanmymac is a per-user tool\n' >&2
  exit 2
fi

SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEST_DIR="${CMM_PREFIX:-$HOME/.cleanmymac}"

# Sanity: make sure we are running from a real cleanmymac source tree.
if [ ! -x "$SRC_DIR/bin/cleanmymac" ] || [ ! -f "$SRC_DIR/lib/common.sh" ]; then
  printf 'error: %s does not look like a cleanmymac source tree\n' "$SRC_DIR" >&2
  exit 2
fi

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

echo "Installing cleanmymac $(cat "$SRC_DIR/VERSION" 2>/dev/null || echo '') into $DEST_DIR"

if [ "$SRC_DIR" = "$DEST_DIR" ]; then
  echo "(already running from $DEST_DIR — refreshing links only)"
else
  mkdir -p "$DEST_DIR"
  # --delete keeps the app dir an exact mirror: files removed upstream (and
  # the whole 1.x layout: cleanmymac.sh, path, setup/, 0*_*.sh) disappear.
  # User state is never here — it lives in ~/.config/cleanmymac.
  rsync -a --delete "$SRC_DIR/" "$DEST_DIR/"
fi

BREW_BIN=""
if command -v brew >/dev/null 2>&1; then
  BREW_BIN="$(brew --prefix 2>/dev/null)/bin"
fi
BIN_DIR="$(choose_bin_dir "$BREW_BIN" /usr/local/bin)"

if [ -n "$BIN_DIR" ]; then
  ln -fs "$DEST_DIR/bin/cleanmymac" "$BIN_DIR/cleanmymac"
  echo "Linked: $BIN_DIR/cleanmymac -> $DEST_DIR/bin/cleanmymac"
  case ":$PATH:" in
    *":$BIN_DIR:"*) ;;
    *)
      echo "note: $BIN_DIR is not on your PATH — add this to your shell profile:"
      echo "  export PATH=\"$BIN_DIR:\$PATH\""
      ;;
  esac
else
  echo "note: no writable bin directory found; run it directly:"
  echo "  $DEST_DIR/bin/cleanmymac"
fi

# Link the man page into brew's manpath when possible (never sudo) — but
# only when the launcher itself went into brew's bin, so overridden installs
# (CMM_BIN_DIR sandboxes, tests) never write outside their own tree.
if [ -n "$BREW_BIN" ] && [ "$BIN_DIR" = "$BREW_BIN" ] && [ -f "$DEST_DIR/man/cleanmymac.1" ]; then
  MAN_DIR="${BREW_BIN%/bin}/share/man/man1"
  if [ -d "$MAN_DIR" ] && [ -w "$MAN_DIR" ]; then
    ln -fs "$DEST_DIR/man/cleanmymac.1" "$MAN_DIR/cleanmymac.1"
    echo "Linked man page into $MAN_DIR"
  fi
fi

# Seed the opt-in default for heavy pruners (docker, xcode) so the state is
# visible and editable — only on a truly fresh setup (D3).
CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/cleanmymac"
if [ ! -f "$CONFIG_DIR/config" ] && [ ! -f "$CONFIG_DIR/disabled" ]; then
  mkdir -p "$CONFIG_DIR"
  printf 'docker\nxcode\n' >"$CONFIG_DIR/disabled"
  echo "Heavy pruners (docker, xcode) start disabled — 'cleanmymac enable docker' or the wizard opts in."
fi

echo
echo "Done. Run 'cleanmymac' to start (the setup wizard offers itself on first run),"
echo "or 'cleanmymac help' for the command reference."
