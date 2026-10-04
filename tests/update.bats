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

# vouching_gpg — gpg and gpgsm stubs that report a good, ultimately trusted
# signature for anything: your own keyrings vouching for a tag must count
# for nothing when the installed copy pins SSH keys.
vouching_gpg() {
  local t
  for t in gpg gpgsm; do
    make_stub_script "$t" <<'EOF'
cat >/dev/null 2>&1
echo "[GNUPG:] NEWSIG"
echo "[GNUPG:] GOODSIG 0123456789ABCDEF Release <release@example.invalid>"
echo "[GNUPG:] VALIDSIG 0123456789ABCDEF0123456789ABCDEF01234567 2026-10-04 1791000000 0 4 0 22 10 00 0123456789ABCDEF0123456789ABCDEF01234567"
echo "[GNUPG:] TRUST_ULTIMATE 0 pgp"
exit 0
EOF
  done
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
  [[ "$output" == *"Update available: v1.0.0 -> v1.1.0"* ]] || false
  [ "$(cat "$INST/VERSION")" = 1.0.0 ]
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updated to v1.1.0"* ]] || false
  [ "$(cat "$INST/VERSION")" = 1.1.0 ]
  [ ! -e "$INST/CHANGE-1.2.0-dev" ]
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already up to date (this copy: v1.1.0; no newer release)"* ]] || false
}

@test "release channel: the highest version wins, not the newest tag" {
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  commit_version 1.10.0
  tag v1.10.0
  run "$INST/bin/scrubmac" update --check
  [[ "$output" == *"-> v1.10.0"* ]] || false
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
  [[ "$output" == *"skipping release v1.1.0 — this copy has diverged from it"* ]] || false
  [[ "$output" == *"update refused"* ]] || false
  [ "$(cat "$INST/VERSION")" = 1.0.0 ]
}

@test "release channel: pre-release and odd tags are never taken" {
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  commit_version 1.1.0
  tag v1.1.0
  commit_version 2.0.0-rc1
  tag v2.0.0-rc1
  tag v9-evil
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updated to v1.1.0"* ]] || false
  [ "$(cat "$INST/VERSION")" = 1.1.0 ]
}

@test "release channel: a release withdrawn upstream (tag deleted) is pruned, not taken" {
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  commit_version 1.1.0
  tag v1.1.0
  run "$INST/bin/scrubmac" update --check
  [[ "$output" == *"v1.0.0 -> v1.1.0"* || "$output" == *"-> v1.1.0"* ]] || false
  git -C "$ORIGIN" tag -d v1.1.0 >/dev/null
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already up to date"* ]] || false
  [ "$(cat "$INST/VERSION")" = 1.0.0 ]
  refute git -C "$INST" rev-parse -q --verify refs/tags/v1.1.0
}

@test "update --check never deletes or moves your own tags (a dev clone's)" {
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  git -C "$INST" tag wip-bisect-good
  git -C "$INST" tag -a v1.1.0 -m "my unpushed release tag"
  run "$INST/bin/scrubmac" update --check
  [ "$status" -eq 0 ]
  git -C "$INST" rev-parse -q --verify refs/tags/wip-bisect-good >/dev/null
  git -C "$INST" rev-parse -q --verify refs/tags/v1.1.0 >/dev/null
}

@test "an inherited GIT_DIR (e.g. from a git hook) never redirects the update" {
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  commit_version 1.1.0
  tag v1.1.0
  git init -q "$SANDBOX/other"
  GIT_DIR="$SANDBOX/other/.git" GIT_WORK_TREE="$SANDBOX/other" run "$INST/bin/scrubmac" update
  [ "$status" -eq 0 ]
  [ "$(cat "$INST/VERSION")" = 1.1.0 ]
  [ -z "$(git -C "$SANDBOX/other" for-each-ref)" ]
}

@test "release channel: a release tag re-pointed upstream after this copy saw it is refused" {
  make_origin
  tag v1.0.0
  commit_version 1.1.0
  tag v1.1.0
  git clone -q "$ORIGIN" "$INST"
  git -C "$INST" reset -q --hard v1.0.0 # this copy is still on 1.0.0
  echo evil >"$ORIGIN/EVIL"
  git -C "$ORIGIN" add -A
  git -C "$ORIGIN" commit -qm evil
  git -C "$ORIGIN" tag -f -a v1.1.0 -m 1.1.0 >/dev/null # re-pointed at the evil commit
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 1 ]
  [[ "$output" == *"skipping release v1.1.0 — it was re-pointed upstream"* ]] || false
  [ ! -e "$INST/EVIL" ]
  [ "$(cat "$INST/VERSION")" = 1.0.0 ]
  run "$INST/bin/scrubmac" update # and it stays refused on the next run
  [ "$status" -eq 1 ]
  [ ! -e "$INST/EVIL" ]
}

@test "release channel: the highest version wins even when an older-version tag is newer (v1.9.0 vs v1.10.0)" {
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  commit_version 1.9.0
  local c19
  c19="$(git -C "$ORIGIN" rev-parse HEAD)"
  commit_version 1.10.0
  tag v1.10.0
  sleep 1
  git -C "$ORIGIN" tag -a v1.9.0 -m 1.9.0 "$c19" # created after v1.10.0
  run "$INST/bin/scrubmac" update --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"-> v1.10.0"* ]] || false
}

@test "branch channel on a detached HEAD says what to do instead of failing obscurely" {
  make_origin
  git clone -q "$ORIGIN" "$INST"
  git -C "$INST" checkout -q --detach
  CMM_UPDATE_CHANNEL=branch run "$INST/bin/scrubmac" update
  [ "$status" -eq 1 ]
  [[ "$output" == *"not on a branch that tracks a remote"* ]] || false
}

@test "an unreachable remote is reported as a fetch failure" {
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  git -C "$INST" remote set-url origin "$SANDBOX/no-such-remote"
  run "$INST/bin/scrubmac" update --check
  [ "$status" -eq 1 ]
  [[ "$output" == *"fetch failed"* ]] || false
}

@test "UPDATE_CHANNEL=branch follows the branch tip even when tags exist" {
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  commit_version 1.2.0-dev
  CMM_UPDATE_CHANNEL=branch run "$INST/bin/scrubmac" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Changes pulled:"* ]] || false
  [ "$(cat "$INST/VERSION")" = 1.2.0-dev ]
}

@test "branch channel --check counts new commits without pulling" {
  make_origin
  git clone -q "$ORIGIN" "$INST"
  commit_version 1.0.1
  CMM_UPDATE_CHANNEL=branch run "$INST/bin/scrubmac" update --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"1 new commit(s) available"* ]] || false
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
  [[ "$output" == *"release signatures are not checked"* ]] || false
}

@test "an allowed_signers file holding only comments pins no keys" {
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  mkdir -p "$INST/share"
  printf '# release signing keys go here\n\n' >"$INST/share/allowed_signers"
  commit_version 1.1.0
  tag v1.1.0
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"release signatures are not checked"* ]] || false
  [ "$(cat "$INST/VERSION")" = 1.1.0 ]
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
  [[ "$output" == *"signature verified"* ]] || false
  [ "$(cat "$INST/VERSION")" = 1.1.0 ]
}

@test "with pinned keys, an unsigned newer release is skipped for the newest signed one" {
  require_ssh_signing
  ssh_key release
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  pin_key release
  commit_version 1.1.0
  signed_tag v1.1.0 release
  commit_version 1.2.0
  tag v1.2.0
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping release v1.2.0 — not signed by a key pinned"* ]] || false
  [[ "$output" == *"Updated to v1.1.0"* ]] || false
  [ "$(cat "$INST/VERSION")" = 1.1.0 ]
}

@test "release channel: a stray high-numbered tag on an old commit never hides a newer release" {
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  commit_version 1.1.0
  tag v1.1.0
  git -C "$ORIGIN" tag v9.9.9 "$(git -C "$ORIGIN" rev-list --max-parents=0 HEAD)"
  run "$INST/bin/scrubmac" update --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Update available: v1.0.0 -> v1.1.0"* ]] || false
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"Updated to v1.1.0"* ]] || false
  [ "$(cat "$INST/VERSION")" = 1.1.0 ]
}

@test "a release of this copy's own version that is a fast-forward is still taken (-dev, -rc, a copy taken before its tag)" {
  local v
  for v in 1.1.0 1.1.0-dev 1.1.0-rc.1; do
    rm -rf "$ORIGIN" "$INST"
    make_origin
    tag v1.0.0
    commit_version "$v"
    git clone -q "$ORIGIN" "$INST"
    echo fix >"$ORIGIN/FIX"
    echo 1.1.0 >"$ORIGIN/VERSION"
    git -C "$ORIGIN" add -A
    git -C "$ORIGIN" commit -qm "1.1.0"
    tag v1.1.0
    run "$INST/bin/scrubmac" update --check
    [ "$status" -eq 0 ]
    [[ "$output" == *"Update available: v$v -> v1.1.0"* ]] || false
  done
}

@test "an older maintenance release on its own branch is not a failed update" {
  make_origin
  tag v1.0.0
  git -C "$ORIGIN" checkout -q -b release-0.9 HEAD
  echo "0.9.1" >"$ORIGIN/VERSION"
  git -C "$ORIGIN" commit -qam "0.9.1"
  tag v0.9.1
  git -C "$ORIGIN" checkout -q master
  git clone -q "$ORIGIN" "$INST"
  run "$INST/bin/scrubmac" update --check
  [ "$status" -eq 0 ]
  [[ "$output" == *"Already up to date"* ]] || false
  [[ "$output" != *"skipping release v0.9.1"* ]] || false
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 0 ]
}

@test "with pinned keys, an unsigned tag on an old commit never freezes updates" {
  require_ssh_signing
  ssh_key release
  make_origin
  signed_tag v1.0.0 release
  git clone -q "$ORIGIN" "$INST"
  pin_key release
  commit_version 1.1.0
  signed_tag v1.1.0 release
  git -C "$ORIGIN" tag v9.9.9 "$(git -C "$ORIGIN" rev-list --max-parents=0 HEAD)"
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"signature verified"* ]] || false
  [[ "$output" == *"Updated to v1.1.0"* ]] || false
  [ "$(cat "$INST/VERSION")" = 1.1.0 ]
}

@test "with pinned keys, only an SSH signature counts (a PGP-looking tag is not 'signed')" {
  require_ssh_signing
  ssh_key release
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  pin_key release
  vouching_gpg
  commit_version 1.1.0
  git -C "$ORIGIN" tag -a v1.1.0 -m $'1.1.0\n-----BEGIN PGP SIGNATURE-----\n\niQEz\n-----END PGP SIGNATURE-----'
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 1 ]
  [[ "$output" == *"skipping release v1.1.0 — not signed by a key pinned"* ]] || false
  [ "$(cat "$INST/VERSION")" = 1.0.0 ]
}

@test "with pinned keys, deleting every tag upstream never turns into an unsigned branch pull" {
  require_ssh_signing
  ssh_key release
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  pin_key release
  git -C "$ORIGIN" tag -d v1.0.0 >/dev/null
  commit_version 6.6.6 # the attacker's unsigned commit on the branch
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 1 ]
  [[ "$output" == *"will not follow the unsigned branch"* ]] || false
  [ "$(cat "$INST/VERSION")" = 1.0.0 ]
}

@test "with pinned keys, an SSH armor line quoted in a PGP-signed tag's message does not count" {
  require_ssh_signing
  ssh_key release
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  pin_key release
  vouching_gpg
  commit_version 1.1.0
  git -C "$ORIGIN" tag -a v1.1.0 -m $'1.1.0\n-----BEGIN SSH SIGNATURE-----\nquoted\n-----END SSH SIGNATURE-----\n-----BEGIN PGP SIGNATURE-----\n\niQEz\n-----END PGP SIGNATURE-----'
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 1 ]
  [[ "$output" == *"skipping release v1.1.0 — not signed by a key pinned"* ]] || false
  [ "$(cat "$INST/VERSION")" = 1.0.0 ]
}

@test "with pinned keys, a genuine signed tag republished under a higher name is skipped" {
  require_ssh_signing
  ssh_key release
  make_origin
  tag v1.0.0
  git clone -q "$ORIGIN" "$INST"
  pin_key release
  commit_version 1.1.0
  signed_tag v1.1.0 release
  git -C "$ORIGIN" update-ref refs/tags/v9.9.9 "$(git -C "$ORIGIN" rev-parse refs/tags/v1.1.0)"
  run "$INST/bin/scrubmac" update
  [ "$status" -eq 0 ]
  [[ "$output" == *"skipping release v9.9.9 — the tag object names a different release"* ]] || false
  [[ "$output" == *"Updated to v1.1.0"* ]] || false
  [[ "$output" != *"error:"* ]] || false # merging the commit, not the signed tag: no gpg noise
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
  [[ "$output" == *"not signed by a key pinned"* ]] || false
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
  [[ "$output" == *"not signed by a key pinned"* ]] || false
  [ "$(cat "$INST/VERSION")" = 1.0.0 ]
}

@test "a copy with neither .git nor a Homebrew keg cannot self-update" {
  mkdir -p "$SANDBOX/copy/cleaners"
  cp -R "$REPO_ROOT/bin" "$REPO_ROOT/lib" "$REPO_ROOT/VERSION" "$SANDBOX/copy/"
  run "$SANDBOX/copy/bin/scrubmac" update
  [ "$status" -eq 1 ]
  [[ "$output" == *"cannot self-update"* ]] || false
  run "$SANDBOX/copy/bin/scrubmac" update --bogus
  [ "$status" -eq 2 ]
}
