#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# lib/update.sh — `scrubmac update [--check]` (S3: constrained self-update).
#
# git installs follow release tags by default (UPDATE_CHANNEL=release): fetch
# (pruning tags withdrawn upstream), then take the newest vX.Y.Z tag that is
# a fast-forward from this copy and — when the INSTALLED copy pins signing
# keys in share/allowed_signers — signed by one of them (trust on first use:
# the pinned keys come from the copy you already have, never from what was
# just fetched). Tags that fail either test are skipped with a warning.
# UPDATE_CHANNEL=branch follows the checked-out branch instead.
# Homebrew installs delegate to `brew upgrade`.
#
# Sourced by bin/scrubmac on demand; bash 3.2 compatible.

# cmm__git ARGS… — git in the install dir, ignoring a GIT_DIR/GIT_WORK_TREE
# inherited from the environment (a git hook, say), which would point it at
# another repository.
cmm__git() {
  (
    unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR GIT_OBJECT_DIRECTORY \
      GIT_ALTERNATE_OBJECT_DIRECTORIES GIT_NAMESPACE
    git -C "$CMM_ROOT" "$@"
  )
}

# Release tags are mirrored into this private namespace, never into your own
# refs/tags: tags withdrawn upstream disappear from it, a moved tag is
# updated in it (and then has to pass the checks like any other), and a
# developer clone's own tags are never pruned or clobbered.
CMM__TAG_NS=refs/scrubmac/release-tags
# What each release tag pointed at when this copy first saw it: a published
# release tag never moves, so one that does is skipped (S3).
CMM__SEEN_NS=refs/scrubmac/seen-tags

# The remote the current branch tracks (falls back to origin).
cmm__git_remote() {
  local up
  up="$(cmm__git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  up="${up%%/*}"
  printf '%s\n' "${up:-origin}"
}

# cmm__pins_keys — this installed copy pins release-signing keys.
cmm__pins_keys() {
  local signers="$CMM_ROOT/share/allowed_signers"
  [ -f "$signers" ] && grep -Eq '^[^#[:space:]]' "$signers" 2>/dev/null
}

# cmm__tag_signed REF — REF is a tag object with an SSH signature by a key
# pinned in the installed copy. git picks the verifier from the signature's
# armor, so the OpenPGP and X.509 backends are switched off: they would ask
# your own keyrings, which the pinned keys say nothing about.
cmm__tag_signed() {
  [ "$(cmm__git cat-file -t "$1" 2>/dev/null)" = tag ] || return 1
  cmm__git -c gpg.openpgp.program=false -c gpg.x509.program=false \
    -c gpg.ssh.allowedSignersFile="$CMM_ROOT/share/allowed_signers" verify-tag "$1" >/dev/null 2>&1
}

# cmm__fetch ARGS… — git fetch, exiting with git's own explanation on failure.
cmm__fetch() {
  local out
  if out="$(cmm__git fetch "$@" 2>&1)"; then
    return 0
  fi
  err "fetch failed — cannot check for updates (network down, or the remote is unreachable):"
  [ -n "$out" ] && printf '%s\n' "$out" >&2
  exit 1
}

cmm__update_branch() {
  local check="$1" before after behind up
  if ! up="$(cmm__git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null)" || [ -z "$up" ]; then
    err "this copy is not on a branch that tracks a remote (detached HEAD?) — check out a branch, e.g. git -C '$CMM_ROOT' checkout master, or set UPDATE_CHANNEL=release"
    exit 1
  fi
  cmm__fetch --no-tags "${up%%/*}"
  if cmm__pins_keys; then
    note "(branch updates are not signature-checked; UPDATE_CHANNEL=release follows signed releases)"
  fi
  if ! cmm__git merge-base --is-ancestor HEAD '@{u}' 2>/dev/null; then
    err "update refused — this copy has diverged from $up (S3: only fast-forward updates)"
    note "inspect with: git -C '$CMM_ROOT' status ; local edits belong in $CMM_USER_CLEANERS_DIR"
    exit 1
  fi
  behind="$(cmm__git rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)"
  if [ "$behind" = 0 ]; then
    note "Already up to date."
    return 0
  fi
  note "$behind new commit(s) available on $up:"
  cmm__git --no-pager log --oneline --no-decorate -n 20 'HEAD..@{u}'
  if [ "$check" = 1 ]; then
    note "(run 'scrubmac update' to apply)"
    return 0
  fi
  before="$(cmm__git rev-parse HEAD)"
  if ! cmm__git merge --ff-only --quiet '@{u}'; then
    err "update failed — could not fast-forward (local changes in the way?) — see: git -C '$CMM_ROOT' status"
    exit 1
  fi
  after="$(cmm__git rev-parse HEAD)"
  note "Updated. Changes pulled:"
  cmm__git --no-pager diff --stat "$before" "$after"
}

# cmm__release_tags — the remote's release tags (exactly vX.Y.Z), newest
# first, from the private mirror.
cmm__release_tags() {
  cmm__git for-each-ref --sort=-v:refname --format='%(refname:lstrip=3)' "$CMM__TAG_NS/" |
    grep -E '^v[0-9]+\.[0-9]+\.[0-9]+$' || true
}

# cmm__tag_moved TAG — TAG now points somewhere else than when this copy first
# saw it. The first sighting is recorded (create-only) from the clone's own
# tag of that name when there is one, else from the mirror.
cmm__tag_moved() {
  local now seen
  now="$(cmm__git rev-parse -q --verify "$CMM__TAG_NS/$1" 2>/dev/null)" || return 1
  if ! seen="$(cmm__git rev-parse -q --verify "$CMM__SEEN_NS/$1" 2>/dev/null)"; then
    seen="$(cmm__git rev-parse -q --verify "refs/tags/$1" 2>/dev/null)" || seen="$now"
    cmm__git update-ref "$CMM__SEEN_NS/$1" "$seen" "" >/dev/null 2>&1 || true
  fi
  [ "$now" != "$seen" ]
}

# cmm__tag_names_itself TAG — an annotated tag's own name matches its ref (a
# genuine signed v1.1.0 republished as v9.9.9 must not pose as 9.9.9).
# Lightweight tags carry no name and pass.
cmm__tag_names_itself() {
  local ref="$CMM__TAG_NS/$1" name
  [ "$(cmm__git cat-file -t "$ref" 2>/dev/null)" = tag ] || return 0
  name="$(cmm__git cat-file tag "$ref" 2>/dev/null | sed -n 's/^tag //p' | sed -n 1p)"
  [ "$name" = "$1" ]
}

cmm__update_release() {
  local check="$1" remote tags tag ref target='' current before after skipped=0
  remote="$(cmm__git_remote)"
  note "Checking $remote for a newer release…"
  cmm__fetch --no-tags --prune "$remote" "+refs/tags/*:$CMM__TAG_NS/*"
  current="v$CMM_VERSION"
  tags="$(cmm__release_tags)"
  # Newest first: the first tag that is a fast-forward from here (and signed,
  # when this copy pins keys) wins. Tags this copy already contains are
  # passed over, not a reason to stop: versions order the tags, not history,
  # so one stray high-numbered tag on an old commit must not hide a newer
  # release.
  for tag in $tags; do
    ref="$CMM__TAG_NS/$tag"
    if cmm__git merge-base --is-ancestor "$ref^{commit}" HEAD 2>/dev/null; then
      continue
    fi
    if cmm__tag_moved "$tag"; then
      warn "skipping release $tag — it was re-pointed upstream after this copy first saw it (S3; if that was legitimate: git -C '$CMM_ROOT' update-ref -d $CMM__SEEN_NS/$tag)"
      skipped=1
      continue
    fi
    if ! cmm__tag_names_itself "$tag"; then
      warn "skipping release $tag — the tag object names a different release (S3)"
      skipped=1
      continue
    fi
    if ! cmm__git merge-base --is-ancestor HEAD "$ref^{commit}" 2>/dev/null; then
      warn "skipping release $tag — this copy has diverged from it (S3: only fast-forward updates)"
      skipped=1
      continue
    fi
    if cmm__pins_keys && ! cmm__tag_signed "$ref"; then
      warn "skipping release $tag — not signed by a key pinned in $CMM_ROOT/share/allowed_signers (S3)"
      skipped=1
      continue
    fi
    target="$tag"
    break
  done
  if [ -z "$tags" ]; then
    # (deleting every tag upstream must not turn signed releases into an
    # unsigned branch pull)
    if cmm__pins_keys; then
      err "update refused — $remote has no release tags, and this copy pins signing keys: it will not follow the unsigned branch (S3)"
      exit 1
    fi
    note "no release tags found — following the branch instead"
    cmm__update_branch "$check"
    return 0
  fi
  if [ -z "$target" ]; then
    if [ "$skipped" = 1 ]; then
      err "update refused — no newer release could be verified (see the warnings above)"
      note "inspect with: git -C '$CMM_ROOT' status ; local edits belong in $CMM_USER_CLEANERS_DIR"
      exit 1
    fi
    note "Already up to date (this copy: $current; no newer release)."
    return 0
  fi
  if cmm__pins_keys; then
    note "release $target: signature verified against $CMM_ROOT/share/allowed_signers"
  else
    note "(release signatures are not checked: this install pins no signing keys)"
  fi
  note "Update available: $current -> $target"
  cmm__git --no-pager log --oneline --no-decorate -n 20 "HEAD..$CMM__TAG_NS/$target^{commit}"
  if [ "$check" = 1 ]; then
    note "(run 'scrubmac update' to apply)"
    return 0
  fi
  before="$(cmm__git rev-parse HEAD)"
  # the commit, not the tag: merging a signed tag makes git try (noisily) to
  # verify it again without the pinned keys
  if ! cmm__git merge --ff-only --quiet "$CMM__TAG_NS/$target^{commit}"; then
    err "update failed — could not fast-forward to $target (local changes in the way?) — see: git -C '$CMM_ROOT' status"
    exit 1
  fi
  after="$(cmm__git rev-parse HEAD)"
  note "Updated to $target. Changes:"
  cmm__git --no-pager diff --stat "$before" "$after"
}

cmm__update_brew() {
  local check="$1" keg token tap="" fq out
  # Derive our own fully-qualified formula name from the keg instead of
  # hardcoding it: the token comes from the Cellar path
  # (…/Cellar/<token>/<version>/libexec) and the tap from the install
  # receipt. Fully qualified because a bare name could resolve to an
  # unrelated cask of the same name.
  keg="${CMM_ROOT%/libexec}"
  token="$(cmm_brew_token)"
  if [ -f "$keg/INSTALL_RECEIPT.json" ]; then
    tap="$(sed -n 's/.*"tap":[[:space:]]*"\([^"]*\)".*/\1/p' "$keg/INSTALL_RECEIPT.json" | head -n 1)"
  fi
  fq="$token"
  [ -n "$tap" ] && fq="$tap/$token"
  if [ "$check" = 1 ]; then
    note "Checking Homebrew for a newer ${fq}…"
    out="$(brew outdated --verbose "$fq" 2>/dev/null || true)"
    if [ -n "$out" ]; then
      note "Update available: $out"
      note "(run 'scrubmac update' to apply)"
    else
      note "Already up to date."
    fi
    return 0
  fi
  note "This install is managed by Homebrew — updating via brew…"
  brew upgrade "$fq"
}

cmd_update() {
  local check=0
  case "${1:-}" in
    --check) check=1 ;;
    '') ;;
    *) usage_err "usage: scrubmac update [--check]" ;;
  esac
  case "$(install_mode)" in
    git)
      have git || {
        err "git not found"
        exit 2
      }
      if [ "${CMM_UPDATE_CHANNEL:-release}" = branch ]; then
        cmm__update_branch "$check"
      else
        cmm__update_release "$check"
      fi
      ;;
    brew) cmm__update_brew "$check" ;;
    *)
      err "cannot self-update: this copy has no .git directory and is not Homebrew-managed"
      note "Reinstall from source:  git clone https://github.com/aviral2552/scrubmac && cd scrubmac && ./install.sh"
      exit 1
      ;;
  esac
}
