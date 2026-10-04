#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
#
# 2026 rename migration (cleanmymac → scrubmac): config-dir migration, the
# install-dir move (external and self-hosted), the compat shim, old-name
# link retirement, and the legacy lock. The literal "cleanmymac" strings in
# this file are the POINT of these tests (completeness-gate whitelisted).

load helpers/setup

setup_file() { build_src_cache; }

setup() {
  setup_sandbox
  export CMM_PREFIX="$SANDBOX/app"
  export CMM_OLD_PREFIX="$SANDBOX/oldapp"
  export CMM_BIN_DIR="$SANDBOX/bindir"
  INSTALL="$(make_src_tree)/install.sh"
  NEWCFG="$XDG_CONFIG_HOME/scrubmac"
  OLDCFG="$XDG_CONFIG_HOME/cleanmymac"
}
teardown() { teardown_sandbox; }

lib() { bash -c ". '$CMM_LIB_PATH'; $1"; }

seed_old_config() {
  mkdir -p "$OLDCFG/cleaners.d"
  printf 'COOLDOWN_DAYS=7\nQUIET=0\nCOLOR=never\nDERIVEDDATA_AGE_DAYS=30\n' >"$OLDCFG/config"
  printf 'docker\nxcode\nnpm\n' >"$OLDCFG/disabled"
  printf '#!/usr/bin/env bash\necho CUSTOM-RAN\n' >"$OLDCFG/cleaners.d/90-custom.sh"
  chmod 755 "$OLDCFG/cleaners.d/90-custom.sh"
}

# ---------- config-dir migration (§3.1) ----------

@test "config migration: old dir is moved, symlinked, and values are honored" {
  seed_old_config
  make_cleaner 10-env.sh 'echo "COOL=${CMM_COOLDOWN_DAYS:-unset}"'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"migrated config"* ]] || false
  [ -d "$NEWCFG" ] && [ ! -L "$NEWCFG" ] || false
  [ -L "$OLDCFG" ] # compat symlink
  [[ "$output" == *"COOL=7"* ]] || false
  grep -Fxq npm "$NEWCFG/disabled"
}

@test "config migration: custom cleaners in old cleaners.d are discovered after migration" {
  seed_old_config
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *CUSTOM-RAN* ]] || false
}

@test "config migration: both dirs existing warns and prefers the new one" {
  seed_old_config
  mkdir -p "$NEWCFG"
  printf 'COOLDOWN_DAYS=3\n' >"$NEWCFG/config"
  make_cleaner 10-env.sh 'echo "COOL=${CMM_COOLDOWN_DAYS:-unset}"'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"both"*"exist"* ]] || false
  [[ "$output" == *"COOL=3"* ]] || false
  [ -d "$OLDCFG" ] # never deleted
}

@test "config migration: a dotfiles-manager symlink is warned about, never silently lost" {
  mkdir -p "$SANDBOX/dotfiles/cleanmymac" "$XDG_CONFIG_HOME"
  printf 'COOLDOWN_DAYS=7\n' >"$SANDBOX/dotfiles/cleanmymac/config"
  ln -s "$SANDBOX/dotfiles/cleanmymac" "$OLDCFG"
  make_cleaner 10-alpha.sh 'echo hi'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"repoint your dotfiles symlink"* ]] || false
  [ -L "$OLDCFG" ] # untouched
  [ -f "$SANDBOX/dotfiles/cleanmymac/config" ]
}

@test "config migration: already-migrated state is silent and stable" {
  seed_old_config
  run "$CMM" list
  run "$CMM" list
  [ "$status" -eq 0 ]
  [[ "$output" != *"migrated config"* ]] || false
  [[ "$output" != *warning* ]] || false
}

@test "config migration is concurrency-tolerant (racing loser survives)" {
  seed_old_config
  run lib "cmm_migrate_config_dir; cmm_migrate_config_dir; echo SURVIVED"
  [ "$status" -eq 0 ]
  [[ "$output" == *SURVIVED* ]] || false
}

@test "losing the config-migration race (mv fails) never aborts the caller" {
  seed_old_config
  printf '#!/bin/sh\nexit 1\n' >"$STUB_BIN/mv" # the other run moved it first
  chmod 755 "$STUB_BIN/mv"
  run lib "set -e; cmm_migrate_config_dir; echo SURVIVED"
  [ "$status" -eq 0 ]
  [[ "$output" == *SURVIVED* ]] || false
}

# ---------- install-dir migration (§3.2) ----------

@test "install.sh migrates an external legacy dir: move, git kept, compat symlink, links swapped" {
  mkdir -p "$CMM_OLD_PREFIX/.git" "$CMM_OLD_PREFIX/lib" "$CMM_OLD_PREFIX/bin" "$SANDBOX/bindir"
  printf 'gitstate\n' >"$CMM_OLD_PREFIX/.git/HEAD"
  printf '2.0.1\n' >"$CMM_OLD_PREFIX/VERSION" # a minimal 2.x layout
  printf '# lib\n' >"$CMM_OLD_PREFIX/lib/common.sh"
  printf '#!/bin/sh\n' >"$CMM_OLD_PREFIX/bin/cleanmymac"
  ln -s "$CMM_OLD_PREFIX/bin/cleanmymac" "$SANDBOX/bindir/cleanmymac"
  run "$INSTALL"
  [ "$status" -eq 0 ]
  [ -d "$CMM_PREFIX" ]
  [ -f "$CMM_PREFIX/.git/HEAD" ]        # .git preserved through the move
  [ -L "$CMM_OLD_PREFIX" ]              # compat symlink
  [ -L "$CMM_BIN_DIR/scrubmac" ]
  [ ! -e "$SANDBOX/bindir/cleanmymac" ] # old-name link retired
  [[ "$output" == *"the command is now 'scrubmac'"* ]] || false
}

@test "install.sh self-hosted re-run from inside the old dir completes (no rsync self-destruct)" {
  # Build a fake old install that IS a source tree, then run ITS install.sh.
  mkdir -p "$CMM_OLD_PREFIX"
  rsync -a --exclude=.git "$REPO_ROOT/" "$CMM_OLD_PREFIX/"
  run "$CMM_OLD_PREFIX/install.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"refreshing links only"* ]] || false
  [ -x "$CMM_PREFIX/bin/scrubmac" ]
  [ -L "$CMM_OLD_PREFIX" ]
  [ -L "$CMM_BIN_DIR/scrubmac" ]
}

@test "install.sh: seeded old config survives an install.sh-first migration (seeding-order pin)" {
  seed_old_config
  mkdir -p "$SANDBOX/repo-copy"
  rsync -a --exclude=.git "$REPO_ROOT/" "$SANDBOX/repo-copy/"
  run "$SANDBOX/repo-copy/install.sh"
  [ "$status" -eq 0 ]
  grep -Fxq 'COOLDOWN_DAYS=7' "$NEWCFG/config" # migrated, not shadowed by seeding
  grep -Fxq npm "$NEWCFG/disabled"             # curated list intact
}

# ---------- the shim (§3.3) ----------

@test "shim: direct invocation nags on stderr and execs scrubmac with argv intact" {
  run bash -c "\"$REPO_ROOT/bin/cleanmymac\" version 2>\"$SANDBOX/err\""
  [ "$status" -eq 0 ]
  [[ "$output" == *"scrubmac 3"* ]] || false
  grep -q "cleanmymac is now scrubmac" "$SANDBOX/err"
}

@test "shim: invocation through a PATH symlink in a foreign bin dir still finds scrubmac" {
  mkdir -p "$SANDBOX/foreignbin"
  ln -s "$REPO_ROOT/bin/cleanmymac" "$SANDBOX/foreignbin/cleanmymac"
  run bash -c "\"$SANDBOX/foreignbin/cleanmymac\" version 2>/dev/null"
  [ "$status" -eq 0 ]
  [[ "$output" == *"scrubmac 3"* ]] || false
}

@test "shim: from a migrated install it says to call scrubmac; from an unmigrated dir, which install.sh to run" {
  mkdir -p "$SANDBOX/x/.scrubmac" "$SANDBOX/y/.cleanmymac"
  rsync -a --exclude=.git "$REPO_ROOT/" "$SANDBOX/x/.scrubmac/"
  rsync -a --exclude=.git "$REPO_ROOT/" "$SANDBOX/y/.cleanmymac/"
  ln -s "$SANDBOX/x/.scrubmac" "$SANDBOX/x/.cleanmymac" # the compat link
  run bash -c "\"$SANDBOX/x/.cleanmymac/bin/cleanmymac\" version 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"call 'scrubmac' instead"* ]] || false
  [[ "$output" != *"install.sh"* ]] || false
  run bash -c "\"$SANDBOX/y/.cleanmymac/bin/cleanmymac\" version 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"finish migrating: run $SANDBOX/y/.cleanmymac/install.sh"* ]] || false
}

@test "shim: an old copy next to an existing ~/.scrubmac is told to step aside, not to run its install.sh" {
  mkdir -p "$HOME/.scrubmac" "$HOME/.cleanmymac"
  rsync -a --exclude=.git "$REPO_ROOT/" "$HOME/.cleanmymac/"
  run bash -c "\"$HOME/.cleanmymac/bin/cleanmymac\" version 2>&1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"this is an old copy; scrubmac is installed at ~/.scrubmac"* ]] || false
  [[ "$output" != *"run $HOME/.cleanmymac/install.sh"* ]] || false
}

@test "shim: exit code passes through" {
  run bash -c "\"$REPO_ROOT/bin/cleanmymac\" definitely-not-a-cleaner 2>/dev/null"
  [ "$status" -eq 2 ]
}

# ---------- legacy lock (§0) ----------

@test "a live pre-rename cleanmymac lock blocks a scrubmac run" {
  start_holder cleanmymac
  mkdir -p "$TMPDIR/cleanmymac.$(id -u).lock"
  echo "$HOLDER_PID" >"$TMPDIR/cleanmymac.$(id -u).lock/pid"
  make_cleaner 10-alpha.sh 'echo hi'
  run "$CMM"
  [ "$status" -eq 2 ]
  [[ "$output" == *"pre-rename cleanmymac run is in progress"* ]] || false
}

@test "a stale legacy lock is recovered and both locks are released after the run" {
  local deadpid
  deadpid="$(sh -c 'echo $$')"
  mkdir -p "$TMPDIR/cleanmymac.$(id -u).lock"
  echo "$deadpid" >"$TMPDIR/cleanmymac.$(id -u).lock/pid"
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *ALPHA-RAN* ]] || false
  [ ! -d "$TMPDIR/cleanmymac.$(id -u).lock" ]
  [ ! -L "$LOCK" ] # the run lock (in the state dir) is released too
}

@test "a legacy lock path that is not ours (a planted symlink) is ignored, never followed" {
  mkdir -p "$SANDBOX/elsewhere"
  ln -s "$SANDBOX/elsewhere" "$TMPDIR/cleanmymac.$(id -u).lock"
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *ALPHA-RAN* ]] || false
  [ -L "$TMPDIR/cleanmymac.$(id -u).lock" ] # left alone
  [ -d "$SANDBOX/elsewhere" ]
  [ ! -e "$SANDBOX/elsewhere/pid" ]
}

@test "a 3.0 disabled file that cannot be read now is converted once it can be" {
  [ "$(id -u)" -ne 0 ] || skip "root reads any file"
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  make_cleaner 60-docker.sh '# default: off' 'echo DOCKER-RAN'
  mkdir -p "$NEWCFG"
  printf 'alpha\n' >"$NEWCFG/disabled" # 3.0 format: no header, no enabled file
  chmod 000 "$NEWCFG/disabled"
  run "$CMM" list
  chmod 644 "$NEWCFG/disabled"
  [ "$status" -eq 2 ]
  run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *"kept your earlier choices enabled: docker"* ]] || false
  [[ "$output" == *DOCKER-RAN* ]] || false
  [[ "$output" != *ALPHA-RAN* ]] || false
}

@test "no legacy lock is taken when TMPDIR points nowhere (and the run still works)" {
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  # the run's scratch dir falls back to /tmp: keep that inside the sandbox
  mkdir -p "$SANDBOX/fake-tmp"
  make_stub_script mktemp <<EOF
case "\$*" in *" /tmp/scrubmac.run."*) exec "$SYSBIN/mktemp" -d "$SANDBOX/fake-tmp/scrubmac.run.XXXXXX" ;; esac
exec "$SYSBIN/mktemp" "\$@"
EOF
  TMPDIR="$SANDBOX/does-not-exist" run "$CMM"
  [ "$status" -eq 0 ]
  [[ "$output" == *ALPHA-RAN* ]] || false
  [ ! -e "$SANDBOX/does-not-exist" ]
  grep -q '^mktemp -d /tmp/scrubmac.run.' "$CALL_LOG" # (the fallback was taken, in the sandbox)
}

# ---------- uninstall (both names) ----------

@test "uninstall removes both dirs, the compat symlink, and both link names" {
  mkdir -p "$CMM_OLD_PREFIX"
  rsync -a --exclude=.git "$REPO_ROOT/" "$CMM_OLD_PREFIX/"
  "$CMM_OLD_PREFIX/install.sh" >/dev/null
  ln -s "$CMM_PREFIX/bin/cleanmymac" "$CMM_BIN_DIR/cleanmymac" # simulate a leftover old link
  run "$CMM_PREFIX/uninstall.sh"
  [ "$status" -eq 0 ]
  [ ! -e "$CMM_PREFIX" ]
  [ ! -e "$CMM_OLD_PREFIX" ] && [ ! -L "$CMM_OLD_PREFIX" ] || false
  [ ! -L "$CMM_BIN_DIR/scrubmac" ]
  [ ! -L "$CMM_BIN_DIR/cleanmymac" ]
}

# ---------- lib literal pins (§1) ----------

@test "cmm_config_dir points at scrubmac; the migration adopts the old cleanmymac dir" {
  [ "$(lib 'cmm_config_dir')" = "$XDG_CONFIG_HOME/scrubmac" ]
  mkdir -p "$XDG_CONFIG_HOME/cleanmymac"
  printf 'QUIET=1\n' >"$XDG_CONFIG_HOME/cleanmymac/config"
  lib 'cmm_migrate_config_dir' 2>/dev/null
  [ -f "$XDG_CONFIG_HOME/scrubmac/config" ]
  [ -L "$XDG_CONFIG_HOME/cleanmymac" ]
}
