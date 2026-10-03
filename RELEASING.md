# Releasing scrubmac

## Cutting a release

1. Update `VERSION` (semver), add a `## [x.y.z] - YYYY-MM-DD` section to
   `CHANGELOG.md`, and update the version/date in `man/scrubmac.1`'s `.TH`
   line.
2. `make lint test docs-check` — everything green — and the latest live E2E
   run on `master` is green.
3. Commit, then tag and push. Sign the tag (see below) once signing is set
   up:

   ```
   git tag -s v$(cat VERSION) -m "scrubmac $(cat VERSION)"   # or: git tag v$(cat VERSION)
   git push origin master --tags
   ```

4. The `Release` workflow verifies tag == VERSION and the CHANGELOG section,
   re-runs the full check (lint with the same pinned, checksum-verified
   linters as CI; the test suite on macOS and Linux), and only then builds
   `scrubmac-x.y.z.tar.gz` with `git archive`
   (`.gitattributes` keeps tests and CI config out of it), writes
   `SHA256SUMS`, records a **build-provenance attestation** for the tarball,
   and publishes the GitHub release.
5. If the `HOMEBREW_TAP_TOKEN` secret is set, the workflow then bumps
   `Formula/scrubmac.rb` in `aviral2552/homebrew-tap` to the new asset and
   checksum. Without it, the job prints the two lines to change by hand.

Consumers verify a tarball with:

```bash
gh attestation verify scrubmac-x.y.z.tar.gz -R aviral2552/scrubmac
```

## Signing release tags (enables update verification)

`scrubmac update` on git installs verifies release tags against keys in the
**installed** copy's `share/allowed_signers`, once that file exists. To turn
it on:

1. Pick (or create) an SSH key for releases:
   `ssh-keygen -t ed25519 -C "scrubmac releases" -f ~/.ssh/scrubmac_release`
2. Commit `share/allowed_signers` with one line:

   ```
   releases@scrubmac namespaces="git" ssh-ed25519 AAAA…   # the .pub contents
   ```

3. Sign every release tag from then on:

   ```
   git -c gpg.format=ssh -c user.signingkey=~/.ssh/scrubmac_release.pub tag -s vX.Y.Z -m "scrubmac X.Y.Z"
   ```

   (or set `gpg.format ssh`, `user.signingkey` and `tag.gpgSign true` in the
   repo config). Check with
   `git -c gpg.ssh.allowedSignersFile=share/allowed_signers verify-tag vX.Y.Z`.

Installs that already have the file skip unsigned or wrongly-signed tags
(with a warning; they take the newest release that verifies, and refuse to
update if none newer does); installs from before it existed pick it up with
their next update. Rotating the key means shipping the new key in a release
signed by the old one. Never move or delete a published release tag:
installs refuse a tag that moved, and prune one that was deleted.

## The Homebrew tap

The tap lives in a separate repo: `aviral2552/homebrew-tap`, with the
formula at `Formula/scrubmac.rb`; `packaging/homebrew/scrubmac.rb` is the
in-repo template.

**Automatic bump (recommended):** create a fine-grained personal access
token limited to *only* `aviral2552/homebrew-tap` with **Contents: Read and
write** (nothing else), and store it as the `HOMEBREW_TAP_TOKEN` Actions
secret of this repository. The release workflow's `bump-tap` job then
rewrites `url` and `sha256` and pushes the commit; it holds no other
permissions.

**Manual bump:** copy the template to the tap, set `url` to the release's
**uploaded asset** (`releases/download/vX.Y.Z/scrubmac-X.Y.Z.tar.gz`) and
`sha256` from the same release's `SHA256SUMS` — the checksum describes that
asset, not GitHub's auto-generated `/archive/` tarball. Then test:

```
brew install --build-from-source aviral2552/tap/scrubmac
brew test aviral2552/tap/scrubmac
brew audit --strict aviral2552/tap/scrubmac
```

Users install with (`brew trust` is Homebrew's third-party-tap gate):

```
brew tap aviral2552/tap
brew trust aviral2552/tap
brew install aviral2552/tap/scrubmac
```

## Post-release checklist

- `brew upgrade scrubmac` works from a machine with the previous version
- `scrubmac update` fast-forwards a git install to the tag (and, once tags
  are signed, says "signature verified")
- `gh attestation verify` succeeds for the uploaded tarball
- README badges still point at the right workflows
