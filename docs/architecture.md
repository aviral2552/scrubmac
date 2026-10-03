# Architecture

About 5,000 lines of bash 3.2-compatible shell, structured as a thin
dispatcher, a small set of libraries, and independent cleaner processes.

```
bin/scrubmac ──sources──▶ lib/common.sh     helpers shared with every cleaner
      │        ──sources──▶ lib/dispatch.sh   settings, discovery, state, locks, the run loop
      │        ──on demand─▶ lib/wizard.sh     configure / first run
      │                      lib/schedule.sh   schedule (launchd)
      │                      lib/update.sh     update (release tags, signatures)
      │                      lib/doctor.sh     doctor
      │
      ├─ discovers ▶ cleaners/NN-name.sh                    (built-in)
      │              ~/.config/scrubmac/cleaners.d/*.sh     (yours; shadows built-ins by name)
      │
      └─ executes each cleaner as a child process (stdin </dev/null, TIMEOUT watchdog)
             child sources lib/common.sh via $CMM_LIB, reports back via $CMM_REPORT_FILE
```

## Execution flow (`scrubmac [names…]`)

1. **Self-locate** — resolve `${BASH_SOURCE[0]}` through symlinks; everything
   is relative to that root. No state files point at the install.
2. **Refuse root**, set `LC_ALL=C`, migrate a pre-rename config dir.
3. **Resolve settings** — every key in the registry (`CMM_SETTINGS` in
   `lib/dispatch.sh`) is resolved *flag → environment (`CMM_<KEY>`) →
   config file → default*, validated by type, and exported as `CMM_<KEY>`.
   The user's environment is snapshotted first, so values the dispatcher
   exports never masquerade as user overrides (e.g. after the wizard writes
   a new config).
4. **First-run offer** — no config + interactive TTY → offer the wizard;
   decline writes defaults; non-TTY uses defaults with a hint line.
5. **Scheduled guards** (`--scheduled` only) — `ON_BATTERY=skip` on battery,
   or a successful full run within `MIN_HOURS_BETWEEN_RUNS`, ends the run
   early (exit 0, logged).
6. **Lock** — `$STATE_DIR/run.lock` is a symlink whose target is the holder's
   pid: `ln -s` creates it atomically, with its content. A lock whose pid is
   dead — or alive but not a scrubmac process (pid reuse after a reboot) — is
   stale and broken by an atomic rename that is verified, so a racing run's
   fresh lock is never stolen. The lock never lives in `$TMPDIR`, which
   differs between cron, launchd and terminal sessions. (A transitional
   second lock in `$TMPDIR`, exactly as 2.x takes it, keeps an untouched 2.x
   copy and 3.x apart; it goes in v4.)
7. **Probe** — offline = no default network route (`route -n get default`'s
   output on macOS, `ip route` on Linux; no traffic is sent).
8. **Discover** — executable `*.sh` regular files, user dir first, deduped by
   cleaner *name* (`10-homebrew.sh` → `homebrew`), ordered by basename.
   Names are restricted to `A-Za-z0-9._+@-`. One awk pass reads each file's
   metadata headers (`# gate:`, `# group:`, `# default:`, `# summary:`); the
   result is cached for the rest of the process.
9. **Run loop** — per cleaner: state filter (explicit `disabled`/`enabled`
   choices, else the header default) and `--skip` → execution-safety guard
   (refused = a failure) → banner → child process with the `CMM_*`
   environment, stdin from `/dev/null`, and a watchdog that stops the
   cleaner *and its descendants* after `TIMEOUT` → record status, duration,
   and the cleaner's report (notes, skip reason, cache size, freed space) →
   **continue regardless**. Output goes straight to a terminal (tools keep
   their TTY behavior); otherwise it is captured for the log (and streamed
   unless quiet). INT/TERM stops the current cleaner, prints a partial
   summary, exits 130.
10. **Summary** — ok/skip/FAIL/TIMEOUT/REFUSED/STOPPED per cleaner with
    notes, totals and total time, approximate disk freed (df delta) and, with
    `--measure`, what each cleaner freed. Then: the log, `last-run.json`,
    `last-success` (successful full real runs), log rotation, `--json` on
    stdout, and a notification for unattended runs. Exit 1 if anything
    failed.

## The cleaner contract

A cleaner is an executable script that:

- declares its metadata in header lines — `# gate: cmd…` (used by `list`,
  `doctor`, the wizard), `# group:` (wizard screen), `# default: on|off`,
  `# summary:` (one line for `list` and the wizard)
- sources `$CMM_LIB` (with a relative fallback so it also runs standalone)
- gates on tool presence: `skip_unless brew` → prints a note and exits **75**
- runs every mutating command through the helper vocabulary:

| Helper | Meaning |
|---|---|
| `run CMD…` | mutating; a failure fails the cleaner immediately (`set -e`) |
| `step CMD…` | mutating; a failure is recorded, the remaining independent steps still run, the cleaner exits 1 at the end |
| `try CMD…` | advisory; a failure is reported and tolerated |
| `preview CMD…` | read-only; executed only under `--dry-run` |
| `report CMD…` | read-only; executed only by `scrubmac status` |
| `cache_dir DIR…` / `cache_dir_cmd CMD…` | declare cache dirs: sized by `status`, measured with `--measure` |
| `updating` / `cleaning` | predicates for the current mode (and offline) |
| `skip_unless_updating` / `skip_unless_cleaning` | for update-only / clean-only cleaners |
| `interactive` / `app_updates_allowed` | is a person watching? may GUI apps be upgraded? |
| `summary_note TEXT` | a line under this cleaner in the summary and JSON |
| `ai_self_update TOOL CMD…` | run a self-updater only for standalone installs (D4) |
| `brew_cask_upgrade_self TOOL` | upgrade a binary-only Homebrew cask by name |
| `has_subcommand TOOL SUB` | does `TOOL --help` list `SUB`? |
| `setting KEY DEFAULT` | read a setting (environment, then config) |
| `cooldown_days` | the validated supply-chain cooldown |

- never prompts (stdin is `/dev/null`), never sudo, never user data, never
  secrets in argv

Exit codes: `0` ok · `75` skipped · anything else failed. The dispatcher maps
these to the summary; the CLI itself exits `0/1/2/130`.

In `status` mode `run`/`step`/`try` are silent no-ops, so a cleaner that
follows the contract cannot change anything there — the same trust model as
`--dry-run`.

## Enable/disable state

`~/.config/scrubmac/disabled` and `enabled` hold *explicit* choices; every
other cleaner follows its `# default:` header. That way new opt-in cleaners
stay off for existing installs, and explicit choices survive default
changes. A one-time migration converts the ≤ 3.0 format (a `disabled`
list only, where absence meant enabled); a marker in the state dir keeps it
from ever re-running.

## Install modes

| Mode | Detected by | `scrubmac update` does |
|---|---|---|
| git (`install.sh` or clone) | `.git` present at root | fetch tags; fast-forward to the highest `vX.Y.Z` (or follow the branch with `UPDATE_CHANNEL=branch`); verify the tag signature when `share/allowed_signers` pins keys |
| Homebrew formula | root under `brew --prefix` | `brew upgrade <tap>/<token>` |
| bare copy | neither | prints reinstall guidance |

`install.sh` mirrors the source tree into `~/.scrubmac` with
`rsync -a --delete` — only into an empty directory or an existing scrubmac
install — so the app dir is wholly owned by the tool (user state lives in
`~/.config/scrubmac` and `~/.local/state/scrubmac`).

## bash 3.2 compatibility

macOS still ships bash 3.2.57 and scrubmac runs on it natively (CI smokes
every script with `/bin/bash -n` plus live runs, and the test suite runs
under `/bin/bash` on macOS). Consequences: no associative arrays, no
`mapfile`, no `${var,,}`; indexed arrays are accessed by position
(`set -u`-safe on 3.2); `set -euo pipefail` throughout — which also means no
`cmd | head` (SIGPIPE) where the status matters.

## Testing strategy

bats-core, fully hermetic: every test gets a sandbox HOME/XDG/TMPDIR and a
stub PATH factory that records exact argv into a call log — no real package
manager, launchd, notification center or network is ever reachable (silent
default stubs guard `launchctl`, `osascript` and `crontab`). Suites:
`runner` (dispatcher semantics), `commands` (list/config/status/last/JSON/
logs/notifications/scheduled guards), `lib` (helpers and guards),
`cleaners` (per-cleaner argv pins, modes, deferral, cooldown — the npm
resolver runs on real node), `wizard`, `schedule`, `update` (real SSH tag
signatures), `install`/`uninstall`/`migration`, `security` (S1–S7 pins),
`cron` (cron-like minimal environments), and `e2e` (whole user journeys
through the real entry points). On top of that, the **live E2E** workflow
runs scrubmac for real on GitHub's macOS and Ubuntu runners against real
tools — including loading a real launchd agent — to catch upstream CLI drift
that stubs cannot. `make docs-check` keeps the docs honest.
