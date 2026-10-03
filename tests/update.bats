#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# `scrubmac update` on git installs (S3): release tags by default, fast-
# forward only, --check, UPDATE_CHANNEL=branch, and SSH tag signatures
# verified against keys pinned in the INSTALLED copy (trust on first use).
# Signatures use throwaway keys generated in the sandbox (git >= 2.34).

load helpers/setup

setup() {
  setup_sandbox
  ORIGIN="$SANDBOX/origin"
  INST="$SANDBOX/inst"
  export GIT_CONFIG_NOSYSTEM=1 GIT_CONFIG_GLOBAL="$SANDBOX/gitconfig"
  git config --file "$GIT_CONFIG_GLOBAL" user.email t@example.invalid
  git config --file "$GIT_CONFIG_GLOBAL" user.name tester
  git config --file "$GIT_CONFIG_GLOBAL" init.defaultBranch master
  git config --file "$GIT_CONFIG_GLOBAL" tag.gpgSign false
  git config --file "$GIT_CONFIG_GLOBAL" commit.gpgSign false
}
teardown() { teardown_sandbox; }

# make_origin — a repo with the real bin/lib and an empty cleaners dir.
make_origin() {
  mkdir -p "$ORIGIN/cleaners"
  cp -R "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$ORIGIN/"
  echo "1.0.0" >"$ORIGIN/VERSION"
  git -C "$ORIGIN" init -q
  git -C "$ORIGIN" add -A
  git -C "$ORIGIN" commit -qm "1.0.0"
}

commit_version() { # commit_version VERSION — bump VERSION and commit
  echo "$1" >"$ORIGIN/VERSION"
  echo "$1" >"$ORIGIN/CHANGE-$1"
  git -C "$ORIGIN" add -A
  git -C "$ORIGIN" commit -qm "$1"
}

tag() { git -C "$ORIGIN" tag -a "$1" -m "$1"; }

ssh_key() { # ssh_key NAME — generate an ed25519 key pair in the sandbox
  ssh-keygen -q -t ed25519 -N '' -C "$1" -f "$SANDBOX/$1" >/dev/null
}

signed_tag() { # signed_tag TAG KEYNAME
  git -C "$ORIGIN" -c gpg.format=ssh -c user.signingkey="$SANDBOX/$2" tag -s "$1" -m "$1"
}

pin_key() { # pin_key KEYNAME — pin KEYNAME in the INSTALLED copy only
  mkdir -p "$INST/share"
  printf 'release@scrubmac.invalid namespaces="git" %s\n' "$(cat "$SANDBOX/$1.pub")" >"$INST/share/allowed_signers"
}

require_ssh_signing() {
  command -v ssh-keygen >/dev/null 2>&1 || skip "ssh-keygen not available"
  ssh_key probe
  git init -q "$SANDBOX/probe-repo"
  git -C "$SANDBOX/probe-repo" commit -q --allow-empty -m probe
  git -C "$SANDBOX/probe-repo" -c gpg.format=ssh -c user.signingkey="$SANDBOX/probe" tag -s probe -m probe >/dev/null 2>&1 ||
    skip "this git cannot create SSH-signed tags (needs git >= 2.34)"
}

@test "release channel: --check reports the newer tag without moving; update fast-forwards to it" {
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  commit_version 1.1.0
  tag v1.1.0
  commit_version 1.2.0-dev # untagged work past the release is not taken
  run "$INST/bin/scrubmac" update --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Update available: v1.0.0 -> v1.1.0"* ]]
  [ "$(cat "$INST/VERSION")" = 1.0.0 ]
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updated to v1.1.0"* ]]
  [ "$(cat "$INST/VERSION")" = 1.1.0 ]
  [ ! -e "$INST/CHANGE-1.2.0-dev" ]
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already up to date (latest release: v1.1.0"* ]]
}

@test "release channel: the highest version wins, not the newest tag" {
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  commit_version 1.10.0
  tag v1.10.0
  run "$INST/bin/scrubmac" update --check
  [[ "$output" == *"-> v1.10.0"* ]]
}

@test "release channel refuses a copy that diverged from the release (S3)" {
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  echo local >"$INST/LOCAL"
  git -C "$INST" add -A
  git -C "$INST" commit -qm local
  commit_version 1.1.0
  tag v1.1.0
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 1 ]
  [[ "$output" == *"diverged from release v1.1.0"* ]]
  [ "$(cat "$INST/VERSION")" = 1.0.0 ]
}

@test "UPDATE_CHANNEL=branch follows the branch tip even when tags exist" {
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  commit_version 1.2.0-dev
  CMM_UPDATE_CHANNEL=branch run "$INST/bin/scrubmac" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Changes pulled:"* ]]
  [ "$(cat "$INST/VERSION")" = 1.2.0-dev ]
}

@test "branch channel --check counts new commits without pulling" {
  make_origin
  git clone -q "$ORIGIN" "$INST"
  commit_version 1.0.1
  CMM_UPDATE_CHANNEL=branch run "$INST/bin/scrubmac" update --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 new commit(s) available"* ]]
  [ "$(cat "$INST/VERSION")" = 1.0.0 ]
}

@test "without pinned keys, signatures are not checked (and it says so)" {
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  commit_version 1.1.0
  tag v1.1.0
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"release signatures are not checked"* ]]
}

@test "with pinned keys, a release signed by the pinned key is accepted" {
  require_ssh_signing
  ssh_key release
  make_origin
  signed_tag v1.0.0 release
  git clone -q "$ORIGIN" "$INST"
  pin_key release
  commit_version 1.1.0
  signed_tag v1.1.0 release
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"signature verified"* ]]
  [ "$(cat "$INST/VERSION")" = 1.1.0 ]
}

@test "with pinned keys, an unsigned release is refused" {
  require_ssh_signing
  ssh_key release
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  pin_key release
  commit_version 1.1.0
  tag v1.1.0
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 1 ]
  [[ "$output" == *"not signed by a key pinned"* ]]
  [ "$(cat "$INST/VERSION")" = 1.0.0 ]
}

@test "with pinned keys, a release signed by another key is refused — even one the release itself pins" {
  require_ssh_signing
  ssh_key release
  ssh_key attacker
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  pin_key release
  # the new release swaps in its own allowed_signers and signs with that key
  mkdir -p "$ORIGIN/share"
  printf 'x namespaces="git" %s\n' "$(cat "$SANDBOX/attacker.pub")" >"$ORIGIN/share/allowed_signers"
  commit_version 1.1.0
  signed_tag v1.1.0 attacker
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 1 ]
  [[ "$output" == *"not signed by a key pinned"* ]]
  [ "$(cat "$INST/VERSION")" = 1.0.0 ]
}

@test "a copy with neither .git nor a Homebrew keg cannot self-update" {
  mkdir -p "$SANDBOX/copy/cleaners"
  cp -R "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/VERSION" "$SANDBOX/copy/"
  run "$SANDBOX/copy/bin/scrubmac" update
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot self-update"* ]]
  run "$SANDBOX/copy/bin/scrubmac" update --bogus
  [ "$status" -eq 2 ]
}
