# Writing your own cleaner

A cleaner is one executable bash script. Drop it in
`~/.config/scrubmac/cleaners.d/` and it joins the run; name it the same as
a built-in (`10-homebrew.sh`) and yours **replaces** it.

## Annotated template

```bash
#!/usr/bin/env bash
# gate: mytool                    ← command(s) whose presence enables this cleaner
# group: Developer tools          ← wizard screen (omit: "Other (your cleaners)")
# default: on                     ← "off" makes it opt-in (scrubmac enable mytool)
# summary: update mytool and clear its download cache   ← one line for list/wizard
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

skip_unless mytool                # absent tool → note + exit 75 ("skipped")

cache_dir "$HOME/.cache/mytool"   # sized by `scrubmac status`, measured by --measure
report mytool outdated            # read-only: runs only in `scrubmac status`

if updating; then                 # false for --clean-only, status, and offline
  step mytool self-update --yes   # mutating; a failure is recorded, later steps still run
fi

if cleaning; then                 # false for --update-only and status
  preview mytool cache clean --dry-run   # read-only: runs only under --dry-run
  step mytool cache clean
fi
```

Make it executable (`chmod 755`) — non-executable files are ignored, and files
that are group/world-writable, foreign-owned, or symlinked are **refused**
(see [security.md](security.md#s2--execution-safety-guard-on-every-cleaner)).
File names may use only `A-Za-z0-9._+@-`.

## The contract

1. **Gate on presence.** `skip_unless CMD`, or `skip "reason"` for compound
   gates. Exit 75 means "skipped", 0 means "ok", anything else means "failed".
2. **Every mutation goes through `run` or `step`.** That is what makes
   `--dry-run` trustworthy and keeps `scrubmac status` read-only. Use
   `step` for independent steps (a failure is recorded and the cleaner keeps
   going, then reports FAIL); use `run` when later commands must not happen
   after a failure. Advisory/reporting commands use `try`.
3. **Non-interactive, always.** Your stdin is `/dev/null`. If a tool prompts,
   find its `-y`/`--no-interaction` flag or don't run it.
4. **No sudo. No user data.** Updates and regenerable caches only. When in
   doubt whether something is "cache", it isn't.
5. **No secrets in argv.** `run` echoes every command line.
6. **Package-manager awareness for self-updaters.** Use
   `ai_self_update TOOL CMD…` — it runs `CMD` only for standalone installs
   and defers Homebrew/npm/pipx/uv-managed ones to those cleaners.
7. **Respect the modes.** Wrap updates in `if updating` and cleanup in
   `if cleaning` (or start with `skip_unless_updating` /
   `skip_unless_cleaning` if a cleaner only does one). Cleaners that don't
   use these predicates run their steps in every mode except `status`.
8. **Stay inside your TIMEOUT.** Long downloads are fine; hangs are stopped.
9. **bash 3.2.** No associative arrays, `mapfile`, or `${var,,}`; no
   `cmd | head` where the exit status matters (`pipefail` + SIGPIPE).

## Useful lib helpers

| Helper | Does |
|---|---|
| `have CMD` | silent presence test (treats Apple's inert developer-tool shims as absent) |
| `skip_unless CMD` / `skip MSG` | exit 75 with a note |
| `run` / `step` / `try CMD…` | announce + execute (dry-run aware) — see the contract |
| `preview` / `report CMD…` | read-only commands for `--dry-run` / `status` |
| `cache_dir DIR…` / `cache_dir_cmd CMD…` | declare cache dirs (status sizes, `--measure`) |
| `updating` / `cleaning` | mode (and offline) predicates |
| `skip_unless_updating` / `skip_unless_cleaning` | for single-purpose cleaners |
| `interactive` / `app_updates_allowed` | is a person watching? may GUI apps be upgraded? |
| `summary_note TEXT` | a line under your cleaner in the summary and JSON |
| `note` / `warn` / `err` | output with consistent formatting |
| `install_kind CMD` | `npm` / `pipx` / `uv` / `brew` / `standalone` / `none` |
| `ai_self_update TOOL CMD…` | managed-aware self-update |
| `brew_cask_upgrade_self TOOL` | upgrade the binary-only Homebrew cask TOOL came from |
| `has_subcommand TOOL SUB` | does `TOOL --help` list `SUB`? |
| `cooldown_days` | the supply-chain cooldown in days (0 = off) |
| `date_days_ago N` | RFC 3339 UTC timestamp (BSD + GNU date) |
| `setting KEY DEFAULT` | read a setting: `CMM_KEY` from the environment, then the config file |
| `cmm_version_ge A B` | dotted version comparison |

Environment available to every cleaner: `CMM_DRY_RUN`, `CMM_MODE`
(`run`/`update`/`clean`/`status`), `CMM_OFFLINE`, `CMM_INTERACTIVE`,
`CMM_SCHEDULED`, `CMM_BREW_PREFIX`, `CMM_LIB`, `CMM_OS`, and every setting
as `CMM_<KEY>` (`CMM_COOLDOWN_DAYS`, `CMM_APP_UPDATES`, …). Your own keys
work too: `scrubmac config set MYTOOL_FLAG 1`, then `setting MYTOOL_FLAG 0`.

## Numbering

`NN-name.sh` — NN orders the run. Package managers early (they update the
runtimes everything else uses), heavy pruners last. Built-ins use 10–72;
pick anything that reads sensibly next to `scrubmac list`.

## Contributing a cleaner upstream

PRs welcome. A built-in cleaner additionally needs:

- the four metadata headers (CI checks them)
- stub-based bats tests in `tests/cleaners.bats` pinning its exact argv,
  its skip-when-absent behavior, its mode/offline behavior, and any
  `-y`-style non-interactivity flags
- a `### name` section in [docs/cleaners.md](cleaners.md) naming every
  command it runs and its default — `make docs-check` fails otherwise
- the commands and flags checked against the tool's official documentation
  (say which in the PR)
- `make lint test docs-check` green

See [CONTRIBUTING.md](../CONTRIBUTING.md) for the full checklist.
