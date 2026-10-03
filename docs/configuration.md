# Configuration

## Where things live

| Path | Purpose |
|---|---|
| `~/.config/scrubmac/config` | settings, `KEY=value` — parsed with a strict grammar, **never executed** |
| `~/.config/scrubmac/disabled` | cleaners you turned off, one name per line |
| `~/.config/scrubmac/enabled` | opt-in cleaners you turned on, one name per line |
| `~/.config/scrubmac/cleaners.d/` | your own cleaners; a same-named file overrides a built-in |
| `~/.local/state/scrubmac/logs/` | one log per run (`scrubmac last` shows the newest) |
| `~/.local/state/scrubmac/last-run.json` | machine-readable record of the last real run |
| `~/.local/state/scrubmac/run.lock` | the run lock (a symlink naming the holder's pid) |
| `~/Library/LaunchAgents/com.github.aviral2552.scrubmac.plist` | the schedule, if you set one |

`$XDG_CONFIG_HOME` and `$XDG_STATE_HOME` are respected. Nothing lives in
`$TMPDIR`: it differs between cron, launchd, and terminal sessions, which
would let them miss each other's lock.

## The wizard

`scrubmac configure` (offered automatically on the first interactive run)
starts every screen from your **current** configuration — Enter keeps it:

1. **Welcome** — the safety doctrine and the rules: `(r)` restarts, `(q)`
   quits, nothing is written until the summary is confirmed.
2. **Services** — one screen per group (package managers · JavaScript ·
   Python · AI tools · languages · Apple development · developer tools, then
   your own cleaners), each line showing the cleaner's summary, `found` /
   `not found (auto-skips)`, and `opt-in` for cleaners that are off by
   default. Toggle by number, `a` = all on, `n` = none.
3. **Update cooldown** — skip package versions younger than 0/3/7/14 days
   (7 recommended and the default). The screen states the trade-off:
   security patches are delayed too.
4. **App updates** — whether Homebrew casks may be upgraded in runs nobody
   is watching ([why](#app-updates)).
5. **Output** — full vs quiet; **color** — auto/always/never.
6. **Summary** — confirm with `y`, restart with `r`, quit with `q`.

It rewrites only the four keys it manages (`COOLDOWN_DAYS`, `APP_UPDATES`,
`QUIET`, `COLOR`); every other line in the config file — comments, other
settings, keys your own cleaners read — is kept. Declining the first-run
offer writes the defaults, so you are never asked again.

## Settings

| Key | Default | Meaning |
|---|---|---|
| `COOLDOWN_DAYS` | `7` | supply-chain cooldown: skip package versions younger than N days (`0` = off) — [S4](security.md#s4--supply-chain-cooldown) |
| `QUIET` | `0` | `1` = hide cleaner output unless the cleaner fails |
| `COLOR` | `auto` | `auto` / `always` / `never` (`NO_COLOR` is honored) |
| `TIMEOUT` | `3600` | per-cleaner time limit in seconds (`0` = none); a cleaner that exceeds it is stopped — with its child processes — and reported as `TIMEOUT` |
| `APP_UPDATES` | `interactive` | GUI app upgrades (Homebrew casks): `interactive` = only when you run scrubmac yourself, `always`, or `never` |
| `NOTIFY` | `failures` | desktop notification after unattended runs: `failures`, `always`, `never` |
| `ON_BATTERY` | `run` | scheduled runs on battery power: `run` or `skip` |
| `MIN_HOURS_BETWEEN_RUNS` | `0` | scheduled runs skip when a full run succeeded within N hours (`0` = off) |
| `LOG_KEEP` | `20` | number of run logs to keep |
| `MEASURE` | `0` | `1` = measure the space each cleaner frees (slower: `du` before/after) — same as `--measure` |
| `UPDATE_CHANNEL` | `release` | what `scrubmac update` follows on git installs: `release` (tags) or `branch` |
| `DERIVEDDATA_AGE_DAYS` | `30` | xcode: purge DerivedData Xcode has not used for N days |
| `DEVICESUPPORT_AGE_DAYS` | `90` | xcode: purge device-support folders older than N days (the newest per platform is kept) |
| `HOMEBREW_DOCTOR` | `1` | homebrew: run the advisory `brew doctor` + `brew missing` |
| `DOCKER_KEEP_HOURS` | `168` | docker: keep build cache used within N hours |
| `MISE_PRUNE` | `0` | mise: also remove tool versions no config file uses |

Values may contain only `A-Za-z0-9._/-`; lines that do not match the grammar
are ignored, and a value of the wrong type is reported and replaced by the
default (a security property — see
[security.md](security.md#s5--config-cannot-execute-code)).

### `scrubmac config`

```bash
scrubmac config                       # every setting: value, source (flag/env/config/default), meaning
scrubmac config get COOLDOWN_DAYS     # the effective value
scrubmac config set COOLDOWN_DAYS 14  # validated, written atomically; comments kept
scrubmac config unset COOLDOWN_DAYS   # back to the default
scrubmac config path                  # where the file is
```

Keys that are not built-in settings can be stored too (with a warning), for
your own cleaners to read with `setting KEY default`.

### Precedence

**flags beat environment beats config beats defaults.** Every setting can be
overridden for one run as `CMM_<KEY>` in the environment, e.g.
`CMM_COOLDOWN_DAYS=0 scrubmac npm` or `CMM_TIMEOUT=600 scrubmac`. The
effective, validated values are exported to cleaners under the same names.

Other environment variables:

| Variable | Effect |
|---|---|
| `NO_COLOR` | disable color (standard) |
| `CMM_OFFLINE=1` / `0` | force offline/online instead of probing the routing table |
| `CMM_STATE_DIR` | relocate logs, last-run record, and the lock |
| `CMM_CLEANERS_DIR` | override the built-in cleaners directory (used by tests) |
| `CMM_PREFIX`, `CMM_BIN_DIR`, `CMM_OLD_PREFIX` | install/uninstall location overrides (tests) |

## Enabling and disabling cleaners

```bash
scrubmac list                    # name, state, default, tool found?, source, summary
scrubmac disable npm
scrubmac enable docker xcode     # several at once; opt-in cleaners start disabled
```

`disabled` and `enabled` record *explicit* choices; every other cleaner
follows its default (`# default: on|off` in its header). Explicit choices
survive future default changes, and new opt-in cleaners stay off until you
enable them. (Upgrading from ≤ 3.0 converts the old disabled-list-only
format once and says so: docker/xcode you had enabled — and the go cleaner,
which used to run by default — stay enabled.)

Naming cleaners explicitly (`scrubmac docker`) runs them even when
disabled — explicit intent wins. `--skip <name>` leaves a cleaner out of one
run.

## Modes

| Flag | Effect |
|---|---|
| `--dry-run` / `-n` | print every mutating command, execute none; read-only previews (`brew upgrade --dry-run`, `npm outdated`, …) do run |
| `--update-only` | update tools; leave caches alone |
| `--clean-only` | clean caches; change no versions |
| `--measure` | report the space each cleaner frees |
| `--json` | the run's summary as JSON on stdout; all other output goes to stderr |
| `scrubmac status` | read-only: each cleaner's cache sizes and outdated packages |

Offline (no default network route — scrubmac sends no traffic to check),
updates are skipped and cleanup still runs.

## App updates

Upgrading a GUI app is different from upgrading a CLI tool: Homebrew 6
quits a running app (and reopens it afterwards) when its cask asks for that,
and pkg-based casks stop to ask for your password. That is fine while you
watch, and a surprise at 9 a.m. on a Monday. So by default
(`APP_UPDATES=interactive`) casks are upgraded only when you run scrubmac
in a terminal yourself; scheduled and piped runs skip them and say so in
the summary. `always` lifts that (pkg casks will still fail without a
password); `never` leaves GUI apps entirely to you. CLI tools that ship as
binary-only casks (Claude Code, Codex, Copilot, Cursor) are not GUI apps and
are upgraded by their own cleaners in every run.

## Scheduling

### launchd (recommended)

```bash
scrubmac schedule weekly            # Mondays 09:00
scrubmac schedule weekly fri 18:30
scrubmac schedule daily 07:00
scrubmac schedule                   # status
scrubmac schedule off
```

This writes a per-user LaunchAgent that runs `scrubmac --scheduled --quiet`.
Unlike cron, launchd runs a job missed while the Mac slept as soon as it
wakes (a Mac that is powered off skips it). The agent carries the `PATH`
of the shell you scheduled from (minus `.` and relative entries), so your
tools are found — re-run the command after changing your `PATH`. It runs
with background priority.

`--scheduled` runs are unattended: never interactive (no casks unless
`APP_UPDATES=always`), they honor `ON_BATTERY=skip` and
`MIN_HOURS_BETWEEN_RUNS`, and with `NOTIFY=failures` (the default) a failure
raises a desktop notification. Every run leaves a log — `scrubmac last`.

### cron

cron's `PATH` is only `/usr/bin:/bin`, so without a `PATH=` line almost
every cleaner skips (scrubmac warns when every cleaner skipped, and
`scrubmac doctor` flags a crontab without `PATH`). A working crontab:

```
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
0 9 * * 1  $HOME/.scrubmac/bin/scrubmac --scheduled --quiet
```

Notifications from cron jobs are unreliable on macOS (cron runs outside your
login session); launchd agents get them.

Non-TTY runs never prompt: with no config they use the defaults and print a
one-line hint. A concurrent run — manual, cron, or launchd — is excluded by
the lock (the second exits 2).

## Logs and the JSON record

Each real run writes `~/.local/state/scrubmac/logs/run-<UTC timestamp>-<pid>.log`:
a header, one `== name: status (seconds, exit code)` line per cleaner with
its captured output (unattended and quiet runs capture everything; an
interactive run streams to your terminal and logs the statuses), the
summary, and the exit code. The newest `LOG_KEEP` logs are kept.

`last-run.json` (and `--json`) look like:

```json
{
  "version": "3.1.0",
  "started_at": "2026-10-05T09:00:00Z",
  "finished_at": "2026-10-05T09:03:12Z",
  "duration_seconds": 192,
  "mode": "run",
  "dry_run": false,
  "scheduled": true,
  "interactive": false,
  "offline": false,
  "interrupted": false,
  "exit_code": 1,
  "totals": {"ok": 14, "skipped": 12, "failed": 1},
  "disk_freed_kb": 1300000,
  "log_file": "/Users/you/.local/state/scrubmac/logs/run-20261005T090000Z-4242.log",
  "cleaners": [
    {"name": "homebrew", "status": "ok", "exit_code": 0, "seconds": 41, "source": "builtin", "freed_kb": null, "cache_kb": null, "notes": ["casks not upgraded (unattended run; APP_UPDATES=interactive)"]}
  ]
}
```

Statuses: `ok`, `skip`, `fail`, `timeout`, `refused` (execution-safety
guard), `stopped` (interrupted).
