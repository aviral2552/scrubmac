# Writing your own cleaner

A cleaner is one executable bash script. Drop it in
`~/.config/cleanmymac/cleaners.d/` and it joins the run; name it the same as
a built-in (`10-homebrew.sh`) and yours **replaces** it.

## Annotated template

```bash
#!/usr/bin/env bash
# gate: mytool                                  ← the command(s) that gate this
# mytool: one line saying what this cleans.       cleaner; `list`/`doctor`/wizard
set -euo pipefail                              #  read this header
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless mytool          # absent tool → note + exit 75 ("skipped" in summary)

run mytool update           # mutating command: dry-run aware; failure fails the cleaner
try mytool doctor           # advisory command: failure is reported and tolerated
run mytool cache clean
```

Make it executable (`chmod 755`) — non-executable files are ignored, and files
that are group/world-writable, foreign-owned, or symlinked are **refused**
(see [security.md](security.md#s2--execution-safety-guard-on-every-cleaner)).

## The contract

1. **Gate on presence.** `skip_unless CMD`, or `skip "reason"` for compound
   gates. Exit 75 means "skipped", 0 means "ok", anything else means "failed".
2. **Every mutation goes through `run`.** That is what makes `--dry-run`
   trustworthy. Advisory/reporting commands use `try`.
3. **Non-interactive, always.** A prompt is a hang in cron. If a tool prompts,
   find its `-y`/`--no-interaction` flag or don't run it.
4. **No sudo. No user data.** Updates and regenerable caches only. When in
   doubt whether something is "cache", it isn't.
5. **No secrets in argv.** `run` echoes every command line.
6. **Package-manager awareness for self-updaters.** Use
   `ai_self_update TOOL CMD…` — it runs `CMD` only for standalone installs
   and defers brew/npm-managed ones to those cleaners.
7. **bash 3.2.** No associative arrays, `mapfile`, or `${var,,}`.

## Useful lib helpers

| Helper | Does |
|---|---|
| `have CMD` | silent `command -v` test |
| `skip_unless CMD` / `skip MSG` | exit 75 with a note |
| `run CMD…` / `try CMD…` | announce + execute (dry-run aware) |
| `note` / `warn` / `err` | output with consistent formatting |
| `install_kind CMD` | `npm` / `brew` / `standalone` / `none` |
| `ai_self_update TOOL CMD…` | managed-aware self-update |
| `date_days_ago N` | RFC 3339 UTC timestamp (BSD + GNU date) |
| `config_get KEY DEFAULT` | read a config value (strict parser) |

Environment available to every cleaner: `CMM_DRY_RUN`, `CMM_COOLDOWN_DAYS`,
`CMM_DERIVEDDATA_AGE_DAYS`, `CMM_BREW_PREFIX`, `CMM_LIB`.

## Numbering

`NN-name.sh` — NN orders the run. Package managers early (they update the
runtimes everything else uses), heavy pruners last. Built-ins use 10–70;
pick anything that reads sensibly next to `cleanmymac list`.

## Contributing a cleaner upstream

PRs welcome. A built-in cleaner additionally needs:

- a stub-based bats test in `tests/cleaners.bats` pinning its exact argv,
  its skip-when-absent behavior, and any `-y`-style non-interactivity flags
- a `### name` section in [docs/cleaners.md](cleaners.md) — CI's
  `make docs-check` fails without it
- `make lint test docs-check` green

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the full checklist.
