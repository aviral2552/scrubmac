# Releasing scrubmac

## Cutting a release

1. Update `VERSION` (semver) and add a `## [x.y.z] - YYYY-MM-DD` section to
   `CHANGELOG.md`. Update the version/date in `man/scrubmac.1`'s `.TH` line.
2. `make lint test docs-check` — everything green.
3. Commit, then tag and push:

   ```
   git tag v$(cat VERSION)
   git push origin master --tags
   ```

4. The `Release` workflow verifies tag == VERSION and the CHANGELOG section,
   re-runs the full check, and publishes a GitHub release with
   `scrubmac-x.y.z.tar.gz` + `SHA256SUMS`.

## Updating the Homebrew tap

The tap lives in a separate repo: `aviral2552/homebrew-tap` (create it once —
a plain public repo named `homebrew-tap` with a `Formula/` directory).

1. Copy `packaging/homebrew/scrubmac.rb` to the tap as
   `Formula/scrubmac.rb`.
2. Set `url` to the new release's **uploaded asset**
   (`releases/download/vX.Y.Z/scrubmac-X.Y.Z.tar.gz`) and `sha256` from the
   same release's `SHA256SUMS` — the checksum describes that asset, not
   GitHub's auto-generated `/archive/` tarball.
3. Test locally, then push:

   ```
   brew install --build-from-source ./Formula/scrubmac.rb
   brew test scrubmac
   brew audit --strict scrubmac
   ```

Users then install with (`brew trust` is Homebrew's third-party-tap gate):

```
brew tap aviral2552/tap
brew trust aviral2552/tap
brew install aviral2552/tap/scrubmac
```

## Post-release checklist

- `brew upgrade scrubmac` works from a machine with the previous version
- `scrubmac update` fast-forwards a git install to the tag
- README badges still point at the right workflows
