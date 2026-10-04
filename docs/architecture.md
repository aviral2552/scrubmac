# Architecture

About 7,800 lines of bash 3.2-compatible shell (and one node script, the registry resolver), structured as a thin
dispatcher, a small set of libraries, and independent cleaner processes.

```
bin/scrubmac ──sources──▶ lib/common.sh     helpers shared with every cleaner
      │        ──sources──▶ lib/dispatch.sh   settings, discovery, state, locks, the run loop
      │        ──on demand─▶ lib/wizard.sh     configure / first run
      │                      lib/schedule.sh   schedule (launchd)
      │                      lib/update.sh     update (release tags, signatures)
      │                      lib/doctor.sh     doctor
      │        (lib/registry.cjs  the cooldown resolver, run with node by the
      │                           npm, pnpm and bun cleaners)
      │
      ├─ discovers ▶ cleaners/NN-name.sh                    (built-in)
      │              ~/.config/scrubmac/cleaners.d/*.sh     (yours; shadows built-ins by name)
      │
      └─ executes each cleaner as a child process (cwd $HOME, stdin </dev/null,
             fd 3 closed, TIMEOUT watchdog); built-ins run from a per-run snapshot
             child sources lib/common.sh via $CMM_LIB, reports back via $CMM_REPORT_FILE
```

## Execution flow (`scrubmac [names…]`)

1. **Self-locate** — resolve `${BASH_SOURCE[0]}` through symlinks; everything
   is relative to that root. No state files point at the install.
2. **Refuse root**, set `LC_ALL=C`, parse arguments (options that would be
   ignored by the command are errors), point stdout at stderr for `--json`
   (fd 3 keeps the JSON document), then migrate a pre-rename config dir — so
   its note never lands in the JSON — except for `list --names` and `config
   keys`, which shell completion calls and which must have no side effects.
3. **Resolve settings** — every key in the registry (`CMM_SETTINGS` in
   `lib/dispatch.sh`) is resolved *flag → environment (`CMM_<KEY>`) →
   config file → default*, validated by type, normalized (`08` → `8`), and
   exported as `CMM_<KEY>`. Config lines the grammar ignores are reported.
   The user's environment is snapshotted first, so values the dispatcher
   exports never masquerade as user overrides (e.g. after the wizard writes
   a new config).
4. **First-run offer** — no config + interactive TTY → offer the wizard;
   decline writes defaults; non-TTY uses defaults with a hint line.
5. **Scheduled guards** (`--scheduled` only) — `ON_BATTERY=skip` on battery,
   or a successful full run within `MIN_HOURS_BETWEEN_RUNS`, ends the run
   early (exit 0, logged).
6. **Lock** — `$STATE_DIR/run.lock` is a symlink whose target names the
   holder, `PID:START` (its pid, and its start time: on Linux the start tick
   since boot, elsewhere `ps -o lstart` in UTC and the C locale — never local
   time, which differs between a launchd job and a shell with `TZ` set):
   `ln -sn` creates it atomically, with its content. A lock whose pid is dead,
   or alive with a different start time (pid reuse after a reboot), is stale.
   Breakers take turns under a mutex (`run.lock.breaking`, a symlink naming
   its holder the same way): under it the lock is re-read and removed only
   while it still names the stale holder, so a lock that a racing run just
   created is never removed (a mutex whose holder died mid-break is broken
   the same way a stale lock is). Then every contender races to create the
   lock again — exactly one wins. A holder whose start time
   cannot be read is assumed alive. A state dir that cannot be written is
   reported as such (exit 2), not as "already in progress". The lock never lives in `$TMPDIR`, which
   differs between cron, launchd and terminal sessions. (A transitional
   second lock in `${TMPDIR:-/tmp}`, exactly as 2.x takes it, keeps an
   untouched 2.x copy and 3.x apart when they share a `TMPDIR` — honored only
   when it is a real directory you own; it goes in v4.)
7. **Probe** — offline = no default network route (`route -n get default`'s
   output on macOS, `ip route` on Linux; no traffic is sent).
8. **Discover** — executable `*.sh` regular files, user dir first, deduped by
   cleaner *name* (`10-homebrew.sh` → `homebrew`), ordered by basename.
   Names are restricted to `A-Za-z0-9._+@-`. One awk pass reads each file's
   metadata headers (`# gate:`, `# group:`, `# default:`, `# summary:`); the
   result is cached for the rest of the process.
9. **Select and snapshot** — state filter (explicit `disabled`/`enabled`
   choices, else the header default) and `--skip`; then the built-in
   cleaners pass the execution-safety guard and are copied, with `lib/`, into
   the run's scratch dir (`$CMM_LIB` points at the copy). The homebrew
   cleaner can upgrade scrubmac itself, and Homebrew deletes the old keg —
   later cleaners must not be running from it. Your own cleaners run in place
   (checked just before they run; one that vanished mid-run is a failure).
10. **Run loop** — per cleaner: banner (or, in quiet mode, one result line
    afterwards) → child process started in `$HOME` with the `CMM_*`
    environment, stdin from `/dev/null`, fd 3 closed, a private scratch dir
    (`cmm_scratch_dir`) and a watchdog → record status, duration, and the
    cleaner's report (notes, skip reason, cache size, freed space) →
    **continue regardless**. Output goes straight to a terminal (tools keep
    their TTY behavior); otherwise it is captured for the log (and streamed
    unless quiet; `status` always streams) — through a `tee` the dispatcher
    starts on fd 9 before the cleaner, so stopping the cleaner never stops
    the logging. After `TIMEOUT` (if the cleaner is still running) the
    watchdog sends `TERM`, waits up to 5 s, then sends `KILL` — to the
    cleaner's own process group in runs without a terminal (monitor mode
    gives each cleaner one, which reaches orphaned descendants too; a
    process that `setsid`s away does not), or to a snapshot of its process
    tree in runs attached to a terminal, where a `sudo` or `git` prompt must
    still be able to read it. In group mode, anything a cleaner leaves
    running after it finishes is stopped too (launchd would stop it at the
    end of the job). INT/TERM/HUP stops the current cleaner the same way,
    prints a partial summary, records the run and exits 130 — ignoring
    further signals and failed writes (a closed terminal, a dead pipe)
    meanwhile.
11. **Summary** — ok/skip/FAIL/TIMEOUT/REFUSED/STOPPED per cleaner with
    notes, totals and total time, approximate disk freed (df delta, shown
    from 1 MB up — smaller deltas are noise from other processes) and, with
    `--measure`, what each cleaner freed; "nothing to run" when no cleaner
    was selected at all (every one disabled or `--skip`ped). Then: the log, `last-run.json`, `last-success`
    (the start time of a successful, full, online run in which something
    ran), log rotation, `--json` on fd 3, and a notification for unattended
    runs. Exit 1 if anything failed.

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
| `run CMD…` | mutating; a failure fails the cleaner immediately (`set -e`) and names the command in the summary |
| `step CMD…` | mutating; a failure is recorded (and named in the summary), the remaining independent steps still run, the cleaner exits 1 at the end |
| `try CMD…` | advisory; a failure is reported and tolerated |
| `preview [--ok=N] CMD…` | read-only; executed only under `--dry-run` (a failure is a warning; `--ok=N`: exit N is an answer, e.g. `npm outdated` exits 1 when something is outdated) |
| `report [--ok=N] CMD…` | read-only; executed only by `scrubmac status` (same rules as `preview`) |
| `cache_dir DIR…` / `cache_dir_cmd CMD…` | declare cache dirs: sized by `status`, measured with `--measure` |
| `updating` / `cleaning` | predicates for the current mode (and offline) |
| `skip_unless_updating` / `skip_unless_cleaning` | for update-only / clean-only cleaners (in `status`, `skip_unless_updating` ends the cleaner as ok — put `report` lines before it) |
| `interactive` / `app_updates_allowed` | is a person watching? may GUI apps be upgraded? |
| `summary_note TEXT` | a line under this cleaner in the summary and JSON |
| `ai_self_update TOOL CMD…` | run a self-updater only for standalone installs — never for npm/pipx/uv/Homebrew installs or version-manager shims (mise, asdf, volta, nodenv, rbenv, pyenv) (D4) |
| `brew_cask_upgrade_self TOOL` | upgrade a binary-only Homebrew cask by name |
| `has_subcommand TOOL SUB` | does `TOOL --help` list `SUB`? |
| `setting KEY DEFAULT` | read a setting (environment, then config) |
| `cooldown_days` | the validated supply-chain cooldown |

- never prompts (stdin is `/dev/null`), never runs sudo, never touches user
  data, never puts secrets in argv

Exit codes: `0` ok · `75` skipped · anything else failed. The dispatcher maps
these to the summary; the CLI itself exits `0/1/2/130`. A *tool* that exits
75 under `run`/`step` is reported as a failure (exit 1), never mistaken for
a skip.

In `status` mode `run`/`step`/`try` are silent no-ops, so a cleaner that
follows the contract cannot change anything there — the same trust model as
`--dry-run`.

## Enable/disable state

`~/.config/scrubmac/disabled` and `enabled` hold *explicit* choices; every
other cleaner follows its `# default:` header. That way new opt-in cleaners
stay off for existing installs, and explicit choices survive default
changes. Both files carry a `# scrubmac:` header line and are read with
comments and whitespace ignored. A one-time migration converts the ≤ 3.0
format (a `disabled` list only, where absence meant enabled): it runs only
for a headerless `disabled` with no `enabled` beside it, and a marker in the
state dir keeps it from ever re-running.

## Install modes

| Mode | Detected by | `scrubmac update` does |
|---|---|---|
| git (`install.sh` or clone) | `.git` present at root | fetch tags (pruning withdrawn ones); fast-forward to the newest `vX.Y.Z` that is a fast-forward and — when `share/allowed_signers` pins keys — signed (or follow the branch with `UPDATE_CHANNEL=branch`) |
| Homebrew formula | root under `brew --prefix` | `brew upgrade <tap>/<token>` |
| bare copy | neither | prints reinstall guidance |

`install.sh` mirrors the source tree into `~/.scrubmac` with
`rsync -a --delete` — only into an empty directory or an existing scrubmac
install (real `lib/common.sh`, `VERSION` and launcher files, not just links
to them), compared as canonical paths and never `/`, `$HOME` or a parent of
it — so the app dir is wholly owned by the tool (user state lives in
`~/.config/scrubmac` and `~/.local/state/scrubmac`). `uninstall.sh` applies
the same tests before it deletes anything.

## bash 3.2 compatibility

macOS still ships bash 3.2.57 and scrubmac runs on it natively (CI smokes
every script with `/bin/bash -n` plus live runs, and the test suite runs
under `/bin/bash` on macOS). Consequences: no associative arrays, no
`mapfile`, no `${var,,}`; indexed arrays are accessed by position
(`set -u`-safe on 3.2); `set -euo pipefail` throughout — which also means no
`cmd | head` (SIGPIPE) where the status matters.

## Testing strategy

bats-core, hermetic: every test gets a sandbox HOME/XDG dirs/TMPDIR and a
PATH of its stub dir plus a curated dir of basic system utilities (grep,
sed, awk, ps, git… — bash is the system's, 3.2 on macOS), so no real package
manager or language runtime is reachable — not even `/usr/bin`'s python3,
swift, conda or composer — and neither are launchd, the notification center
or the network (silent default stubs guard `launchctl`, `osascript` and
`crontab`). Stubs record exact argv into a call log. Because bash < 4.1
ignores a failing `[[ ]]` that is not a test's last command, and errexit
ignores every member of an `&&` chain but the last, such assertions end in
`|| false` (`scripts/lint-bats.sh`, run by `make lint`, enforces it, along
with the no-`! cmd` rule). The sandbox clears inherited `GIT_*`/`CMM_*`
variables and `BASH_ENV`, and never searches the host's `/usr/local/bin`
for launcher links (`CMM_LINK_DIRS`). Interrupt behavior is tested on a real
pty (`tests/helpers/ptyrun.py`): Ctrl-C, a second Ctrl-C, a closed terminal.
Suites: `runner` (dispatcher semantics: timeouts in both process-group
modes, snapshots, interrupts), `commands` (list/config/status/last/JSON/
logs/notifications/scheduled guards), `lib` (helpers and guards),
`cleaners` (per-cleaner argv pins, modes, deferral, cooldown — the shared
registry resolver runs on real node), `wizard`, `schedule`, `update` (real
SSH tag signatures), `install`/`uninstall`/`migration`, `doctor`,
`completions`, `security` (S1–S7 pins), `cron` (cron-like minimal
environments), and `e2e` (whole user journeys through the real entry
points). On top of that, the **live E2E** workflow
runs scrubmac for real on GitHub's macOS and Ubuntu runners against real
tools — including loading a real launchd agent — to catch upstream CLI drift
that stubs cannot. `make docs-check` keeps the docs honest.
