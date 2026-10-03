# Roadmap

## v4 — removing the rename scaffolding

The 2026 rename (cleanmymac → scrubmac) left transitional code that v4
deletes. Each item is small and self-contained; all of it is covered by
`tests/migration.bats` today, so the removal PR deletes tests alongside.

| Goes away | Where | Why it exists today |
|---|---|---|
| `bin/cleanmymac` shim | `bin/` | keeps pre-rename PATH links and cron paths working, with a nag |
| the legacy `$TMPDIR/cleanmymac.<uid>.lock` | `cmm_legacy_lock_acquire` in `lib/dispatch.sh` | lets an untouched 2.x copy and 3.x exclude each other |
| `~/.config/cleanmymac` adoption | `cmm_migrate_config_dir` in `lib/common.sh` | one-time config migration |
| `~/.cleanmymac` → `~/.scrubmac` move + compat symlink | `install.sh`, `uninstall.sh` | one-time install-dir migration |
| ≤ 3.0 cleaner-state conversion | `cmm_state_migrate` in `lib/dispatch.sh` | the `enabled` list arrived in 3.1 |
| `u` / `h` shorthands | `bin/scrubmac` | 1.x muscle memory |

Open question for v4: rename the `CMM_*` environment variables to
`SCRUBMAC_*` (reading `CMM_*` as a fallback for one major version), so the
names stop carrying the old initials.

## Next

- **Signed releases.** The verification side ships in 3.1 (`share/allowed_signers`
  in the installed copy, checked by `scrubmac update`); it turns on with the
  first release whose tag is signed and which ships the file — see
  [RELEASING.md](../RELEASING.md#signing-release-tags-enables-update-verification).
- **Homebrew core.** Self-submission needs ≥ 225 stars (or 90 forks/watchers);
  until then the tap is the supported Homebrew path.
- **More cleaners, on request** — the [cleaner request template](../.github/ISSUE_TEMPLATE/cleaner_request.md)
  asks for exactly what a cleaner needs (non-interactive commands, docs
  links, what it must never touch, whether updates can be age-filtered).

## Deliberately not planned

- **Linux support.** Most cleaners would work, and CI already runs the test
  suite on Linux, but the product is named and designed for the Mac
  (Homebrew casks, Xcode, launchd); a Linux story would need its own
  scheduling and notification answers. Revisit if there is demand.
- **System "deep cleaning"**, Trash emptying, `~/Library/Caches` sweeps —
  see [security.md](security.md#what-scrubmac-will-never-do).
