## What changed (for users)

## Checklist

- [ ] `make lint test docs-check` green locally
- [ ] bash 3.2 compatible (no associative arrays / mapfile / `${var,,}`)
- [ ] mutations via `run`, advisories via `try`; non-interactive; no sudo; no eval
- [ ] new/changed cleaner: stub tests pin exact argv + skip-when-absent
- [ ] new/changed cleaner: `### name` section updated in docs/cleaners.md
- [ ] anything deleting more than an obvious cache is default-disabled
