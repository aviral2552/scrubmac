#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# install.sh: sandboxed installs — layout, symlink, idempotence, legacy
# purge via --delete, .git preservation, seeded defaults, no sudo ever.

load helpers/setup

setup_file() { build_src_cache; }

setup() {
  setup_sandbox
  export CMM_PREFIX="$SANDBOX/app"
  export CMM_BIN_DIR="$SANDBOX/bindir"
  INSTALL="$(make_src_tree)/install.sh"
}
teardown() { teardown_sandbox; }

@test "installs the full layout and links the launcher" {
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -x "$CMM_PREFIX/bin/scrubmac" ]
  [ -f "$CMM_PREFIX/lib/common.sh" ]
  [ -f "$CMM_PREFIX/lib/wizard.sh" ]
  [ -x "$CMM_PREFIX/cleaners/10-homebrew.sh" ]
  [ -L "$CMM_BIN_DIR/scrubmac" ]
  [ "$(readlink "$CMM_BIN_DIR/scrubmac")" = "$CMM_PREFIX/bin/scrubmac" ]
}

@test "the linked launcher actually runs from the installed copy" {
  run "$INSTALL"
  run "$CMM_BIN_DIR/scrubmac" version
  [ "$status" -eq 0 ]
  [[ "$output" == *"$(cat "$REPO_ROOT/VERSION")"* ]] || false
}

@test "re-running the installer is idempotent" {
  run "$INSTALL"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -x "$CMM_PREFIX/bin/scrubmac" ]
  [ -L "$CMM_BIN_DIR/scrubmac" ]
}

@test "legacy 1.x layout is purged by the mirror copy (F10)" {
  mkdir -p "$CMM_PREFIX/cleaners" "$CMM_PREFIX/setup"
  printf 'old\n' >"$CMM_PREFIX/scrubmac.sh"
  printf '%s\n' "$CMM_PREFIX" >"$CMM_PREFIX/path"
  printf 'old\n' >"$CMM_PREFIX/cleaners/02_homebrew.sh"
  printf 'old\n' >"$CMM_PREFIX/setup/install.sh"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ ! -e "$CMM_PREFIX/scrubmac.sh" ]
  [ ! -e "$CMM_PREFIX/path" ]
  [ ! -e "$CMM_PREFIX/cleaners/02_homebrew.sh" ]
  [ ! -e "$CMM_PREFIX/setup" ]
}

@test "the install carries install.sh's marker, ignored by git" {
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -f "$CMM_PREFIX/.scrubmac-install" ]
  [ -d "$CMM_PREFIX/.git" ]
  [ -z "$(git -C "$CMM_PREFIX" status --porcelain -- .scrubmac-install)" ]
}

@test "the .git metadata is preserved so 'scrubmac update' can work (F2)" {
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -e "$CMM_PREFIX/.git" ]
}

@test "seeds no cleaner state; names the opt-in cleaners instead" {
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ ! -e "$XDG_CONFIG_HOME/scrubmac/disabled" ]
  [ ! -e "$XDG_CONFIG_HOME/scrubmac/enabled" ]
  [[ "$output" == *"Opt-in cleaners (off unless you turn them on):"*docker*xcode* ]] || false
  # existing choices are never touched
  mkdir -p "$XDG_CONFIG_HOME/scrubmac"
  printf 'npm\n' >"$XDG_CONFIG_HOME/scrubmac/disabled"
  run "$INSTALL"
  diff "$XDG_CONFIG_HOME/scrubmac/disabled" - <<'EOF'
npm
EOF
}

@test "refuses to mirror into a directory that holds anything but scrubmac" {
  mkdir -p "$CMM_PREFIX"
  printf 'precious\n' >"$CMM_PREFIX/thesis.tex"
  run "$INSTALL"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a scrubmac install"* ]] || false
  [ -f "$CMM_PREFIX/thesis.tex" ]
}

@test "refuses \$HOME or / as the install dir" {
  CMM_PREFIX="$HOME" run "$INSTALL"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to install into"* ]] || false
  CMM_PREFIX=/ run "$INSTALL"
  [ "$status" -eq 2 ]
}

@test "the guards see through \$HOME/., trailing slashes and symlinked parents" {
  touch "$HOME/keep-me"
  CMM_PREFIX="$HOME/." run "$INSTALL"
  [ "$status" -eq 2 ]
  CMM_PREFIX="$HOME/" run "$INSTALL"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to install into"* ]] || false
  ln -s "$HOME" "$SANDBOX/homelink"
  CMM_PREFIX="$SANDBOX/homelink" run "$INSTALL"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to install into"* ]] || false
  CMM_PREFIX="$SANDBOX/app/../home" run "$INSTALL"
  [ "$status" -eq 2 ]
  [ -f "$HOME/keep-me" ]
}

@test "a directory that merely holds a scrubmac launcher link is not an install (no mirror into ~/.local)" {
  export CMM_BIN_DIR="$HOME/.local/bin"
  run "$INSTALL" # first install: links ~/.local/bin/scrubmac
  [ "$status" -eq 0 ]
  [ -L "$HOME/.local/bin/scrubmac" ]
  mkdir -p "$HOME/.local/share/precious"
  touch "$HOME/.local/share/precious/data"
  CMM_PREFIX="$HOME/.local" run "$INSTALL"
  [ "$status" -eq 2 ]
  [[ "$output" == *"not a scrubmac install"* ]] || false
  [ -f "$HOME/.local/share/precious/data" ]
}

@test "a legacy path that is not a cleanmymac install is never moved or mirrored over" {
  export CMM_OLD_PREFIX="$SANDBOX/oldapp"
  mkdir -p "$CMM_OLD_PREFIX/precious"
  printf 'data\n' >"$CMM_OLD_PREFIX/important.db"
  printf 'notes\n' >"$CMM_OLD_PREFIX/precious/notes.txt"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not a cleanmymac install — left alone"* ]] || false
  [ -f "$CMM_OLD_PREFIX/important.db" ]
  [ -f "$CMM_OLD_PREFIX/precious/notes.txt" ]
  [ ! -L "$CMM_OLD_PREFIX" ]
  [ -x "$CMM_PREFIX/bin/scrubmac" ] # the install itself went ahead
  [ ! -e "$CMM_PREFIX/important.db" ]
}

@test "the legacy-path guard also refuses \$HOME and its parents" {
  touch "$HOME/keep-me"
  CMM_OLD_PREFIX="$HOME" run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -f "$HOME/keep-me" ]
  [ ! -L "$HOME" ]
}

@test "a dangling symlink at the install path gets a clear message" {
  ln -s "$SANDBOX/not-there" "$CMM_PREFIX"
  run "$INSTALL"
  [ "$status" -eq 2 ]
  [[ "$output" == *"is a symlink to $SANDBOX/not-there, which does not exist"* ]] || false
}

@test "refuses an install dir inside the source tree" {
  local src="$SANDBOX/src"
  mkdir -p "$src"
  rsync -a --exclude=.git "$REPO_ROOT/" "$src/"
  CMM_PREFIX="$src/inner" run "$src/install.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"is inside the source tree"* ]] || false
}

@test "refuses a parent of \$HOME with the safety message (not just 'not an install')" {
  CMM_PREFIX="$(dirname "$HOME")" run "$INSTALL"
  [ "$status" -eq 2 ]
  [[ "$output" == *"refusing to install into"*"parent of it"* ]] || false
}

@test "a directory whose 'install' files are symlinks is not an install" {
  mkdir -p "$CMM_PREFIX/lib" "$CMM_PREFIX/bin" "$SANDBOX/elsewhere"
  touch "$SANDBOX/elsewhere/f"
  ln -s "$SANDBOX/elsewhere/f" "$CMM_PREFIX/lib/common.sh"
  ln -s "$SANDBOX/elsewhere/f" "$CMM_PREFIX/VERSION"
  ln -s "$SANDBOX/elsewhere/f" "$CMM_PREFIX/bin/scrubmac"
  printf 'precious\n' >"$CMM_PREFIX/thesis.tex"
  run "$INSTALL"
  [ "$status" -eq 2 ]
  [ -f "$CMM_PREFIX/thesis.tex" ]
}

@test "a cleanmymac link that is not ours (MacPaw's CLI) is never removed" {
  mkdir -p "$CMM_BIN_DIR" "$SANDBOX/macpaw/bin"
  printf '#!/bin/sh\n' >"$SANDBOX/macpaw/bin/cleanmymac"
  chmod 755 "$SANDBOX/macpaw/bin/cleanmymac"
  ln -s "$SANDBOX/macpaw/bin/cleanmymac" "$CMM_BIN_DIR/cleanmymac"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -L "$CMM_BIN_DIR/cleanmymac" ]
  export PATH="$CMM_BIN_DIR:$PATH"
  run "$REPO_ROOT/uninstall.sh"
  [ -L "$CMM_BIN_DIR/cleanmymac" ]
}

@test "never mirrors an older copy over a newer install" {
  run "$INSTALL"
  [ "$status" -eq 0 ]
  echo 99.0.0 >"$CMM_PREFIX/VERSION" # the install was updated past this copy
  run "$INSTALL"
  [ "$status" -eq 2 ]
  [[ "$output" == *"has scrubmac 99.0.0, newer than this copy"* ]] || false
  [ "$(cat "$CMM_PREFIX/VERSION")" = 99.0.0 ]
}

@test "installing from a git worktree leaves its git metadata behind (no shared repository)" {
  local src="$SANDBOX/wt"
  mkdir -p "$src"
  rsync -a --exclude=.git "$REPO_ROOT/" "$src/"
  printf 'gitdir: /somewhere/main/.git/worktrees/wt\n' >"$src/.git"
  run "$src/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"git worktree or submodule"* ]] || false
  [ ! -e "$CMM_PREFIX/.git" ]
  [ -x "$CMM_PREFIX/bin/scrubmac" ]
}

@test "a dangling launcher link is replaced (it is nobody's working install)" {
  mkdir -p "$CMM_BIN_DIR"
  ln -s "$SANDBOX/removed-keg/bin/scrubmac" "$CMM_BIN_DIR/scrubmac"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"replaced the dangling launcher link"* ]] || false
  [[ "$output" != *"two installs"* ]] || false
  [ "$(readlink "$CMM_BIN_DIR/scrubmac")" = "$CMM_PREFIX/bin/scrubmac" ]
}

@test "an old cleanmymac link stays while the crontab still calls cleanmymac" {
  run "$INSTALL"
  ln -s "$CMM_PREFIX/bin/cleanmymac" "$CMM_BIN_DIR/cleanmymac"
  printf '#!/bin/sh\necho "0 9 * * 1 cleanmymac -q"\n' >"$STUB_BIN/crontab"
  chmod 755 "$STUB_BIN/crontab"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -L "$CMM_BIN_DIR/cleanmymac" ]
  [[ "$output" == *"kept old-name link"* ]] || false
  printf '#!/bin/sh\nexit 1\n' >"$STUB_BIN/crontab"
  run "$INSTALL"
  [ ! -e "$CMM_BIN_DIR/cleanmymac" ]
}

@test "an old-name link of ours is announced once — never as MacPaw's command" {
  run "$INSTALL"
  mkdir -p "$HOME/.local/bin"
  ln -s "$CMM_PREFIX/bin/cleanmymac" "$HOME/.local/bin/cleanmymac"
  printf '#!/bin/sh\necho "0 9 * * 1 cleanmymac -q"\n' >"$STUB_BIN/crontab"
  chmod 755 "$STUB_BIN/crontab"
  CMM_BIN_DIR="$HOME/.local/bin" PATH="$HOME/.local/bin:$PATH" run "$INSTALL"
  [ "$status" -eq 0 ]
  [ "$(printf '%s\n' "$output" | grep -c 'kept old-name link')" -eq 1 ]
  [[ "$output" != *MacPaw* ]] || false
}

@test "a crontab entry running MacPaw's cleanmymac does not keep our old-name link" {
  run "$INSTALL"
  ln -s "$CMM_PREFIX/bin/cleanmymac" "$CMM_BIN_DIR/cleanmymac"
  printf '#!/bin/sh\necho "0 9 * * 1 /Applications/CleanMyMac.app/Contents/MacOS/cleanmymac --scan"\n' >"$STUB_BIN/crontab"
  chmod 755 "$STUB_BIN/crontab"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ ! -e "$CMM_BIN_DIR/cleanmymac" ]
  [[ "$output" != *"crontab still references"* ]] || false
}

@test "never mirrors over a working clone the install path links to (that would erase it, .git and all)" {
  local clone="$SANDBOX/devclone"
  git clone -q "$BATS_FILE_TMPDIR/src-cache/origin.git" "$clone"
  printf 'notes\n' >"$clone/MY_NOTES.txt"
  ln -s "$clone" "$CMM_PREFIX"
  run "$INSTALL"
  [ "$status" -eq 2 ]
  [[ "$output" == *"which install.sh did not create"* ]] || false
  [ -f "$clone/MY_NOTES.txt" ]
  [ -d "$clone/.git" ]
  [ ! -e "$clone/.scrubmac-install" ]
}

@test "never mirrors over a git checkout at the install path that holds local work" {
  local why
  for why in untracked dirty stash unpushed tagged; do
    rm -rf "$CMM_PREFIX"
    git clone -q "$BATS_FILE_TMPDIR/src-cache/origin.git" "$CMM_PREFIX"
    case "$why" in
      untracked) printf 'notes\n' >"$CMM_PREFIX/MY_NOTES.txt" ;;
      dirty) printf '# my tweak\n' >>"$CMM_PREFIX/README.md" ;;
      stash)
        printf '# wip\n' >>"$CMM_PREFIX/README.md"
        git -C "$CMM_PREFIX" -c user.email=t@example.invalid -c user.name=t stash -q
        ;;
      unpushed) git -C "$CMM_PREFIX" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m WIP ;;
      tagged) # a tag of your own does not make a commit published
        git -C "$CMM_PREFIX" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m WIP
        git -C "$CMM_PREFIX" tag before-refactor
        ;;
    esac
    run "$INSTALL"
    [ "$status" -eq 2 ]
    [[ "$output" == *"is a git checkout with"* ]] || false
    [ -d "$CMM_PREFIX/.git" ]
    [ ! -e "$CMM_PREFIX/.scrubmac-install" ]
  done
}

@test "never mirrors over files that only your own git ignore rules hide (or a hidden untracked view)" {
  git clone -q "$BATS_FILE_TMPDIR/src-cache/origin.git" "$CMM_PREFIX"
  printf '*.local.md\n' >"$SANDBOX/global-excludes"
  git -C "$CMM_PREFIX" config core.excludesFile "$SANDBOX/global-excludes"
  printf 'my notes\n' >"$CMM_PREFIX/NOTES.local.md"
  run "$INSTALL"
  [ "$status" -eq 2 ]
  [[ "$output" == *"untracked files that only your own git ignore rules hide"* ]] || false
  [ -f "$CMM_PREFIX/NOTES.local.md" ]
  rm -f "$CMM_PREFIX/NOTES.local.md"
  git -C "$CMM_PREFIX" config status.showUntrackedFiles no
  printf '#!/usr/bin/env bash\n' >"$CMM_PREFIX/cleaners/95-wip.sh"
  run "$INSTALL"
  [ "$status" -eq 2 ]
  [ -f "$CMM_PREFIX/cleaners/95-wip.sh" ]
}

@test "a git install that took release updates (its origin/* lagging behind) is still upgraded" {
  git clone -q "$BATS_FILE_TMPDIR/src-cache/origin.git" "$CMM_PREFIX"
  # what 'scrubmac update' does on the release channel: tags into a private
  # namespace, then a fast-forward — origin/master never moves
  git -C "$CMM_PREFIX" -c user.email=t@example.invalid -c user.name=t commit -q --allow-empty -m "release 9.9.9"
  git -C "$CMM_PREFIX" update-ref refs/scrubmac/release-tags/v9.9.9 HEAD
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -f "$CMM_PREFIX/.scrubmac-install" ]
}

@test "a shallow clone of a release tag (no remote branches at all) is upgraded" {
  git clone -q --bare "$BATS_FILE_TMPDIR/src-cache/origin.git" "$SANDBOX/origin.git"
  git -C "$SANDBOX/origin.git" tag v0.0.1-test HEAD
  git clone -q --depth 1 --branch v0.0.1-test "file://$SANDBOX/origin.git" "$CMM_PREFIX" 2>/dev/null
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -f "$CMM_PREFIX/.scrubmac-install" ]
}

@test "upgrades a clean, fully pushed git install that predates the marker (a 3.0 install)" {
  git clone -q "$BATS_FILE_TMPDIR/src-cache/origin.git" "$CMM_PREFIX"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -f "$CMM_PREFIX/.scrubmac-install" ]
  [ -x "$CMM_PREFIX/bin/scrubmac" ]
}

@test "an exported CDPATH never confuses where install.sh and scrubmac find themselves" {
  local src
  src="$(make_src_tree)"
  mkdir -p "$SANDBOX/cdp/src" "$SANDBOX/cdp/bin" # decoys a CDPATH search would pick
  cd "$SANDBOX"
  CDPATH="$SANDBOX/cdp" run bash src/install.sh
  [ "$status" -eq 0 ]
  [ -x "$CMM_PREFIX/bin/scrubmac" ]
  cd "$src"
  CDPATH="$SANDBOX/cdp" run bash bin/scrubmac version
  [ "$status" -eq 0 ]
  [[ "$output" == *"scrubmac $(cat "$src/VERSION")"* ]] || false
}

@test "installs through a symlinked parent dir into the real location" {
  mkdir -p "$SANDBOX/real"
  ln -s "$SANDBOX/real" "$SANDBOX/via"
  CMM_PREFIX="$SANDBOX/via/app" run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -x "$SANDBOX/real/app/bin/scrubmac" ]
  [ "$(readlink "$CMM_BIN_DIR/scrubmac")" = "$SANDBOX/real/app/bin/scrubmac" ]
}

@test "an old 2.x install that cannot be moved (both dirs exist) is called out, not touched" {
  export CMM_OLD_PREFIX="$SANDBOX/oldapp"
  "$INSTALL" >/dev/null # the new install exists first
  mkdir -p "$CMM_OLD_PREFIX"
  rsync -a --exclude=.git "$REPO_ROOT/" "$CMM_OLD_PREFIX/"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -d "$CMM_OLD_PREFIX" ]
  [ ! -L "$CMM_OLD_PREFIX" ]
  [[ "$output" == *"an old cleanmymac install is still at $CMM_OLD_PREFIX"* ]] || false
}

@test "refuses when the source tree sits inside the install dir (the mirror would delete it)" {
  mkdir -p "$CMM_PREFIX/bin"
  touch "$CMM_PREFIX/bin/scrubmac"
  rsync -a --exclude=.git "$REPO_ROOT/" "$CMM_PREFIX/src/"
  run "$CMM_PREFIX/src/install.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"inside the install dir"* ]] || false
  [ -x "$CMM_PREFIX/src/install.sh" ]
}

@test "leaves a launcher that is not ours alone (e.g. Homebrew's scrubmac)" {
  mkdir -p "$CMM_BIN_DIR" "$SANDBOX/Cellar/scrubmac/9/bin"
  printf '#!/bin/sh\necho brew-scrubmac\n' >"$SANDBOX/Cellar/scrubmac/9/bin/scrubmac"
  chmod 755 "$SANDBOX/Cellar/scrubmac/9/bin/scrubmac"
  ln -s "$SANDBOX/Cellar/scrubmac/9/bin/scrubmac" "$CMM_BIN_DIR/scrubmac"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"is not from this installer"* ]] || false
  [[ "$output" == *"two installs now exist — $CMM_BIN_DIR/scrubmac"* ]] || false
  [ "$(readlink "$CMM_BIN_DIR/scrubmac")" = "$SANDBOX/Cellar/scrubmac/9/bin/scrubmac" ]
}

@test "replaces its own (even dangling) launcher link" {
  mkdir -p "$CMM_BIN_DIR"
  ln -s "$CMM_PREFIX/bin/old-name" "$CMM_BIN_DIR/scrubmac" # dangling, but ours
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ "$(readlink "$CMM_BIN_DIR/scrubmac")" = "$CMM_PREFIX/bin/scrubmac" ]
}

@test "links the man page and shell completions into a writable brew prefix" {
  local pfx="$SANDBOX/brewpfx"
  mkdir -p "$pfx/bin" "$pfx/share/man/man1" "$pfx/share/zsh/site-functions" \
    "$pfx/etc/bash_completion.d" "$pfx/share/fish/vendor_completions.d"
  printf '#!/bin/sh\n[ "$1" = --prefix ] && echo "%s"\nexit 0\n' "$pfx" >"$STUB_BIN/brew"
  chmod 755 "$STUB_BIN/brew"
  printf 'foreign\n' >"$pfx/share/fish/vendor_completions.d/scrubmac.fish" # not ours: kept
  unset CMM_BIN_DIR
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ "$(readlink "$pfx/bin/scrubmac")" = "$CMM_PREFIX/bin/scrubmac" ]
  [ "$(readlink "$pfx/share/man/man1/scrubmac.1")" = "$CMM_PREFIX/man/scrubmac.1" ]
  [ "$(readlink "$pfx/share/zsh/site-functions/_scrubmac")" = "$CMM_PREFIX/completions/_scrubmac" ]
  [ "$(readlink "$pfx/etc/bash_completion.d/scrubmac")" = "$CMM_PREFIX/completions/scrubmac.bash" ]
  [ ! -L "$pfx/share/fish/vendor_completions.d/scrubmac.fish" ]
  grep -qx foreign "$pfx/share/fish/vendor_completions.d/scrubmac.fish"
}

@test "a sandboxed install never writes outside its sandbox (man-link leak regression)" {
  # The man page and completions link into brew's tree ONLY when the
  # launcher itself went into brew's bin; with CMM_BIN_DIR elsewhere, a
  # writable brew prefix must stay untouched.
  local pfx="$SANDBOX/brewpfx"
  mkdir -p "$pfx/bin" "$pfx/share/man/man1" "$pfx/share/zsh/site-functions" \
    "$pfx/etc/bash_completion.d" "$pfx/share/fish/vendor_completions.d"
  printf '#!/bin/sh\n[ "$1" = --prefix ] && echo "%s"\nexit 0\n' "$pfx" >"$STUB_BIN/brew"
  chmod 755 "$STUB_BIN/brew"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -L "$CMM_BIN_DIR/scrubmac" ]
  [[ "$output" != *"Linked man page"* ]] || false
  [ -z "$(find "$pfx" -type l)" ]
}

@test "never invokes sudo, even when no bin dir is writable (S1)" {
  make_stub sudo 99 "SUDO-WAS-CALLED"
  export CMM_BIN_DIR="/nonexistent-root-owned/bin"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"no writable bin directory"* ]] || false
  refute grep -q sudo "$CALL_LOG"
}

@test "refuses to run from a directory that is not a scrubmac source tree" {
  local fake="$SANDBOX/fake"
  mkdir -p "$fake"
  cp "$INSTALL" "$fake/install.sh"
  chmod 755 "$fake/install.sh"
  run "$fake/install.sh"
  [ "$status" -eq 2 ]
  [[ "$output" == *"does not look like a scrubmac source tree"* ]] || false
}

@test "installer never self-destructs its source directory (F3)" {
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -d "$REPO_ROOT" ]
  [ -x "$REPO_ROOT/install.sh" ]
  refute grep -q 'rm -rf.*SRC_DIR' "$REPO_ROOT/install.sh"
  refute grep -Eq 'trap.*rm' "$REPO_ROOT/install.sh"
}

@test "choose_bin_dir walks candidates in order, then falls back to ~/.local/bin" {
  # extract the pure function and probe its ordering with sandbox dirs
  local fn brewbin="$SANDBOX/brew/bin" usrlocal="$SANDBOX/usrlocal/bin"
  fn="$(sed -n '/^choose_bin_dir()/,/^}$/p' "$INSTALL")"
  mkdir -p "$brewbin" "$usrlocal"
  unset CMM_BIN_DIR
  run bash -c "$fn; choose_bin_dir '$brewbin' '$usrlocal'"
  [ "$output" = "$brewbin" ]
  chmod 555 "$brewbin"
  run bash -c "$fn; choose_bin_dir '$brewbin' '$usrlocal'"
  [ "$output" = "$usrlocal" ]
  chmod 555 "$usrlocal"
  run bash -c "$fn; choose_bin_dir '$brewbin' '$usrlocal'"
  [ "$output" = "$HOME/.local/bin" ]
  chmod 755 "$brewbin" "$usrlocal"
}
