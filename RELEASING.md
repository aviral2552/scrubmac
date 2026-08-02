# Releasing cleanmymac

## Cutting a release

1. Update `VERSION` (semver) and add a `## [x.y.z] - YYYY-MM-DD` section to
   `CHANGELOG.md`. Update the version/date in `man/cleanmymac.1`'s `.TH` line.
2. `make lint test docs-check` — everything green.
3. Commit, then tag and push:

   ```
   git tag v$(cat VERSION)
   git push origin master --tags
   ```

4. The `Release` workflow verifies tag == VERSION and the CHANGELOG section,
   re-runs the full check, and publishes a GitHub release with
   `cleanmymac-x.y.z.tar.gz` + `SHA256SUMS`.

## Updating the Homebrew tap

The tap lives in a separate repo: `aviral2552/homebrew-tap` (create it once —
a plain public repo named `homebrew-tap` with a `Formula/` directory).

1. Copy `packaging/homebrew/cleanmymac.rb` to the tap as
   `Formula/cleanmymac.rb`.
2. Set `url` to the new release's **uploaded asset**
   (`releases/download/vX.Y.Z/cleanmymac-X.Y.Z.tar.gz`) and `sha256` from the
   same release's `SHA256SUMS` — the checksum describes that asset, not
   GitHub's auto-generated `/archive/` tarball.
3. Test locally, then push:

   ```
   brew install --build-from-source ./Formula/cleanmymac.rb
   brew test cleanmymac
   brew audit --strict cleanmymac
   ```

Users then install with:

```
brew tap aviral2552/tap
brew install cleanmymac
```

## Post-release checklist

- `brew upgrade cleanmymac` works from a machine with the previous version
- `cleanmymac update` fast-forwards a git install to the tag
- README badges still point at the right workflows
