## What changed (for users)

## Checklist

- [ ] `make lint test docs-check` green locally
- [ ] bash 3.2 compatible (no associative arrays / mapfile / `${var,,}`)
- [ ] mutations via `run`/`step`, advisories via `try`, read-only via `preview`/`report`; non-interactive; no sudo; no eval
- [ ] new/changed cleaner: metadata headers; stub tests pin exact argv, skip-when-absent, modes/offline
- [ ] new/changed cleaner: `### name` section updated in docs/cleaners.md (every command, the default)
- [ ] external commands/flags checked against official docs (links below)
- [ ] anything deleting more than an obvious cache is `# default: off`
- [ ] CHANGELOG.md updated

## Documentation consulted
