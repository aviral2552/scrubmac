# Contributing

Cleaner PRs are the most welcome kind — the plugin contract makes them
~15-line changes.

## Dev setup

```bash
brew install shellcheck shfmt bats-core
git clone https://github.com/aviral2552/scrubmac.git && cd scrubmac
make            # lint + test + docs-check
```

`make fmt` applies shfmt (2-space, indented case).

## Ground rules (enforced by CI and review)

- bash 3.2 compatible (`/bin/bash` on macOS): no associative arrays,
  `mapfile`, `${var,,}`; CI smokes every script under `/bin/bash`
- `set -euo pipefail`; no `eval`; no `sudo` (both are CI tripwires)
- every mutating command goes through `run`, advisory ones through `try`
- non-interactive always — pin `-y`-style flags with a test
- never user data; caches and updates only; no secrets in argv
- shellcheck + shfmt clean

## Adding a cleaner (checklist)

- [ ] `cleaners/NN-name.sh`, executable, with a `# gate: cmd…` header —
      follow the template in [docs/writing-cleaners.md](docs/writing-cleaners.md)
- [ ] gates with `skip_unless`/`skip` (exit 75 when not applicable)
- [ ] stub tests in `tests/cleaners.bats`: exact argv sequence,
      skip-when-absent, and any behavior branches (managed-vs-standalone,
      version branches, daemon-down, …)
- [ ] a `### name` section in [docs/cleaners.md](docs/cleaners.md) listing
      every command it runs and what it never touches (`make docs-check`)
- [ ] self-updating tools use `ai_self_update` (package-manager awareness)
- [ ] anything that deletes more than an obvious cache: propose it
      default-disabled, like docker/xcode
- [ ] `make lint test docs-check` green

## Tests

Hermetic bats — a sandboxed HOME plus a stub PATH factory that records argv;
no test may reach a real package manager or the network. `tests/helpers/setup.bash`
has the factory; any `tests/*.bats` file shows the pattern.

## Commit / PR conventions

Small, focused PRs against `master`. Describe *what changed for users* in the
first line; reference the flaw/decision IDs (F*, S*, D*) from the docs where
relevant. CI must be green: lint, docs-check, macOS + Linux test jobs, and
the bash 3.2 smoke.

## Security issues

Not in public PRs/issues — see [SECURITY.md](SECURITY.md).
