#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# lib/update.sh — `scrubmac update [--check]` (S3: constrained self-update).
#
# git installs follow release tags by default (UPDATE_CHANNEL=release): fetch,
# pick the highest vX.Y.Z tag, refuse anything that is not a fast-forward, and
# — when the INSTALLED copy pins signing keys in share/allowed_signers —
# refuse tags that are not signed by one of them (trust on first use: the
# pinned keys come from the copy you already have, never from what was just
# fetched). UPDATE_CHANNEL=branch follows the checked-out branch instead.
# Homebrew installs delegate to `brew upgrade`.
#
# Sourced by bin/scrubmac on demand; bash 3.2 compatible.

cmm__git() { git -C "$CMM_ROOT" "$@"; }

# The remote the current branch tracks (falls back to origin).
cmm__git_remote() {
  local up
  up="$(cmm__git rev-parse --abbrev-ref --symbolic-full-name '@{u}' 2>/dev/null || true)"
  up="${up%%/*}"
  printf '%s\n' "${up:-origin}"
}

# cmm__verify_tag TAG — enforce the pinned signing keys, if this copy has any.
cmm__verify_tag() {
  local signers="$CMM_ROOT/share/allowed_signers"
  if [ ! -f "$signers" ] || ! grep -Eq '^[^#[:space:]]' "$signers" 2>/dev/null; then
    note "(release signatures are not checked: this install pins no signing keys)"
    return 0
  fi
  if cmm__git -c gpg.ssh.allowedSignersFile="$signers" verify-tag "$1" >/dev/null 2>&1; then
    note "release $1: signature verified against $signers"
    return 0
  fi
  err "update refused — release $1 is not signed by a key pinned in $signers (S3)"
  return 1
}

cmm__update_branch() {
  local check="$1" before after behind
  if [ "$check" = 1 ]; then
    if ! cmm__git fetch --quiet; then
      err "fetch failed — cannot check for updates"
      exit 1
    fi
    behind="$(cmm__git rev-list --count 'HEAD..@{u}' 2>/dev/null || echo 0)"
    if [ "$behind" = 0 ]; then
      note "Already up to date."
    else
      note "$behind new commit(s) available:"
      cmm__git --no-pager log --oneline --no-decorate -n 20 'HEAD..@{u}'
      note "(run 'scrubmac update' to apply)"
    fi
    return 0
  fi
  note "Updating via git (fast-forward only)…"
  before="$(cmm__git rev-parse HEAD)"
  if ! cmm__git pull --ff-only; then
    err "update failed — local history has diverged from the remote (S3: non-fast-forward pulls are refused)"
    exit 1
  fi
  after="$(cmm__git rev-parse HEAD)"
  if [ "$before" = "$after" ]; then
    note "Already up to date."
  else
    note "Updated. Changes pulled:"
    cmm__git --no-pager diff --stat "$before" "$after"
  fi
}

cmm__update_release() {
  local check="$1" remote target current before after
  remote="$(cmm__git_remote)"
  note "Checking $remote for a newer release…"
  if ! cmm__git fetch --quiet --tags "$remote"; then
    err "fetch failed — cannot check for updates"
    exit 1
  fi
  target="$(cmm__git tag -l 'v[0-9]*' --sort=-v:refname | awk 'NR == 1')"
  if [ -z "$target" ]; then
    note "no release tags found — following the branch instead"
    cmm__update_branch "$check"
    return 0
  fi
  current="v$CMM_VERSION"
  if cmm__git merge-base --is-ancestor "$target" HEAD 2>/dev/null; then
    note "Already up to date (latest release: $target; this copy: $current)."
    return 0
  fi
  if ! cmm__git merge-base --is-ancestor HEAD "$target" 2>/dev/null; then
    err "update refused — this copy has diverged from release $target (S3: only fast-forward updates)"
    note "inspect with: git -C '$CMM_ROOT' status ; local edits belong in $CMM_USER_CLEANERS_DIR"
    exit 1
  fi
  cmm__verify_tag "$target" || exit 1
  note "Update available: $current -> $target"
  cmm__git --no-pager log --oneline --no-decorate -n 20 "HEAD..$target"
  if [ "$check" = 1 ]; then
    note "(run 'scrubmac update' to apply)"
    return 0
  fi
  before="$(cmm__git rev-parse HEAD)"
  if ! cmm__git merge --ff-only --quiet "$target"; then
    err "update failed — could not fast-forward to $target"
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
