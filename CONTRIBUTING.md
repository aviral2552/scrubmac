# Contributing

Cleaner PRs are the most welcome kind — the plugin contract makes them small,
self-contained changes.

## Dev setup

```bash
brew install shellcheck shfmt bats-core
git clone https://github.com/aviral2552/scrubmac.git && cd scrubmac
make            # lint + test + docs-check
```

`make fmt` applies shfmt (2-space, indented case). `make demo` regenerates
`docs/demo.svg`. CI pins shellcheck and shfmt to exact versions (see
`.github/workflows/ci.yml`); if your local copies are newer and flag
something new, fix it anyway.

## Ground rules (enforced by CI and review)

- bash 3.2 compatible (`/bin/bash` on macOS): no associative arrays,
  `mapfile`, `${var,,}`; CI smokes every script under `/bin/bash`
- `set -euo pipefail`; no `eval`; no `sudo` (all CI tripwires); no
  `cmd | head` where the exit status matters
- every mutating command goes through `run`/`step`, advisory ones through
  `try`, read-only previews through `preview`/`report`
- non-interactive always — cleaners get `/dev/null` as stdin; pin `-y`-style
  flags with a test
- never user data; caches and updates only; no secrets in argv
- shellcheck + shfmt clean
- every external command and flag checked against the tool's official
  documentation — name the source in the PR

## Adding a cleaner (checklist)

- [ ] `cleaners/NN-name.sh`, executable, with `# gate:`, `# group:`,
      `# default: on|off` and `# summary:` headers — follow the template in
      [docs/writing-cleaners.md](docs/writing-cleaners.md)
- [ ] gates with `skip_unless`/`skip` (exit 75 when not applicable)
- [ ] updates inside `if updating`, cleanup inside `if cleaning`
- [ ] stub tests in `tests/cleaners.bats`: exact argv sequence,
      skip-when-absent, modes/offline, and any behavior branches
      (managed-vs-standalone, version branches, daemon-down, …)
- [ ] a `### name` section in [docs/cleaners.md](docs/cleaners.md) naming
      every command it runs and its default (`make docs-check` enforces it)
- [ ] self-updating tools use `ai_self_update` (package-manager awareness)
- [ ] anything that deletes more than an obvious cache: propose it
      `# default: off`, like docker/xcode
- [ ] `make lint test docs-check` green

## Tests

Hermetic bats — a sandboxed HOME plus a stub PATH factory that records argv;
no test may reach a real package manager, launchd, the notification center,
or the network. `tests/helpers/setup.bash` has the factory; any
`tests/*.bats` file shows the pattern. `tests/e2e.bats` drives whole user
journeys through the real entry points; `tests/cron.bats` runs under
cron-like minimal environments.

The **live E2E** workflow (`.github/workflows/e2e-live.yml`) runs scrubmac
for real on GitHub's macOS and Ubuntu runners against real tools on every PR
that touches code, and weekly — it is what catches an upstream CLI changing
under us.

## Commit / PR conventions

Small, focused PRs against `master`. Describe *what changed for users* in the
first line; reference the flaw/decision IDs (F*, S*, D*) from the docs where
relevant. CI must be green: lint, docs-check, macOS + Linux test jobs, the
bash 3.2 smoke, and the live E2E run.

## Security issues

Not in public PRs/issues — see [SECURITY.md](SECURITY.md).
