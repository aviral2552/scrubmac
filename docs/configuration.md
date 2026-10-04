# Configuration

## Where things live

| Path | Purpose |
|---|---|
| `~/.config/scrubmac/config` | settings, `KEY=value` — parsed with a strict grammar, **never executed** |
| `~/.config/scrubmac/disabled` | cleaners you turned off, one name per line |
| `~/.config/scrubmac/enabled` | cleaners you turned on (opt-ins, or defaults you re-enabled), one name per line |
| `~/.config/scrubmac/cleaners.d/` | your own cleaners; a same-named file overrides a built-in |
| `~/.local/state/scrubmac/logs/` | one log per run (`scrubmac last` shows the newest) |
| `~/.local/state/scrubmac/last-run.json` | machine-readable record of the last real run |
| `~/.local/state/scrubmac/last-success` | when the last successful full run started (for `MIN_HOURS_BETWEEN_RUNS`) |
| `~/.local/state/scrubmac/launchd.log` | what scheduled runs printed (launchd appends; kept to about 512 KB, plus one `.old` generation) |
| `~/.local/state/scrubmac/run.lock` | the run lock (a symlink naming the holder's pid and start time) |
| `~/Library/LaunchAgents/com.github.aviral2552.scrubmac.plist` | the schedule, if you set one |

`$XDG_CONFIG_HOME` and `$XDG_STATE_HOME` are respected. Nothing that must
outlive a run lives in `$TMPDIR`: it differs between cron, launchd, and
terminal sessions, which would let them miss each other's lock. Only the
per-run scratch directory goes there (falling back to `/tmp`, then the state
dir, when `$TMPDIR` is unset or missing), plus — until v4 — a second,
transitional lock taken exactly where cleanmymac 2.x takes it, so an
unmigrated 2.x copy and scrubmac still exclude each other when both run with
the same `TMPDIR` (a 2.x cron job and a 3.x terminal run still do not see
each other's — see [Hardening in the codebase](security.md#hardening-in-the-codebase)).

## The wizard

`scrubmac configure` (offered automatically on the first interactive run)
starts every screen from your **current** configuration — Enter keeps it:

1. **Welcome** — the safety doctrine and the rules: `(r)` restarts, `(q)`
   quits, nothing is written until the summary is confirmed.
2. **Services** — one screen per group (package managers · JavaScript ·
   Python · AI tools · languages · Apple development · developer tools, then
   your own cleaners), each line showing the cleaner's summary, `found` /
   `not found — auto-skips`, and `opt-in` for cleaners that are off by
   default. Toggle by number, `a` = all on, `n` = none.
3. **Update cooldown** — skip package versions younger than 0/3/7/14 days
   (7 recommended and the default). The screen states the trade-off:
   security patches are delayed too.
4. **App updates** — whether Homebrew casks may be upgraded in runs nobody
   is watching ([why](#app-updates)).
5. **Output** — full vs quiet; **color** — auto/always/never.
6. **Summary** — Enter or `y` writes, `r` restarts, `q` quits; anything
   else asks again.

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
| `TIMEOUT` | `3600` | per-cleaner time limit in seconds (`0` = none); a cleaner that exceeds it is stopped together with the processes it started — `TERM`, then `KILL` after up to 5 s, sent to its process group in runs without a terminal (which reaches orphans too) and to its process tree otherwise — and reported as `TIMEOUT`. A process that detaches into a session of its own (`setsid`, as daemons do) is not reached |
| `APP_UPDATES` | `interactive` | GUI app upgrades (Homebrew casks): `interactive` = only when you run scrubmac yourself, `always`, or `never` |
| `NOTIFY` | `failures` | desktop notification after unattended runs: `failures`, `always`, `never` |
| `ON_BATTERY` | `run` | scheduled runs on battery power: `run` or `skip` |
| `MIN_HOURS_BETWEEN_RUNS` | `0` | scheduled runs skip when a full run succeeded within N hours (`0` = off) |
| `LOG_KEEP` | `20` | number of run logs to keep (at least 1 is always kept) |
| `MEASURE` | `0` | `1` = measure the space each cleaner frees (slower: `du` before/after) — same as `--measure` |
| `UPDATE_CHANNEL` | `release` | what `scrubmac update` follows on git installs: `release` (tags) or `branch` |
| `DERIVEDDATA_AGE_DAYS` | `30` | xcode: purge DerivedData Xcode has not used for N days |
| `DEVICESUPPORT_AGE_DAYS` | `90` | xcode: purge device-support folders older than N days (the newest per platform is kept) |
| `HOMEBREW_DOCTOR` | `1` | homebrew: run the advisory `brew doctor` + `brew missing` |
| `DOCKER_KEEP_HOURS` | `168` | docker: keep build cache used within N hours |
| `MISE_PRUNE` | `0` | mise: also remove tool versions no config file uses |

Values may contain only `A-Za-z0-9._/-`. A line that does not match the
`KEY=value` grammar is ignored and reported (comments and blank lines are
fine); a value of the wrong type is reported and replaced by the default —
a security property, see
[security.md](security.md#s5--config-cannot-execute-code). Whole numbers may
have leading zeros (`08` is 8, never octal); a list setting takes exactly
one of its words.

### `scrubmac config`

```bash
scrubmac config                       # every setting: value, source (flag/env/config/default), meaning
scrubmac config get COOLDOWN_DAYS     # the effective value
scrubmac config set COOLDOWN_DAYS 14  # validated, written atomically; comments kept
scrubmac config unset COOLDOWN_DAYS   # back to the default
scrubmac config path                  # where the file is
scrubmac config keys                  # every key name (shell completion)
```

Keys that are not built-in settings can be stored too (with a warning), for
your own cleaners to read with `setting KEY default` — except a key one typo
(one edit) away from a built-in one (`COOLDOWN_DAY`, `COLORS`), which is
refused with a suggestion; `LOG_LEVEL` or `MY_TIMEOUT` are fine. `config
get` of a key that is neither a setting nor in the file exits 1. `config
keys` prints every key name — built-in, then your own — for shell
completion (it has no side effects). Values pass through as given (`config set
MY_FLAG -x` works); numbers are stored canonically (`08` → `8`). `config
set` writes through a symlinked config file (a dotfiles manager's), keeping
the link, and refuses to touch a config file it cannot read.

A hand-edited file is checked on every run: a line outside the `KEY=value`
grammar is reported and ignored, and so is a key one edit away from a
built-in setting (`APP_UPDATE=never` — "did you mean APP_UPDATES?").
Windows (CRLF) line ends and a byte-order mark are fine.

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
| `XDG_STATE_HOME` | logs, last-run record and the lock go to `$XDG_STATE_HOME/scrubmac` |
| `CMM_STATE_DIR` | relocate logs, last-run record, and the lock (beats `XDG_STATE_HOME`) |
| `CMM_CLEANERS_DIR` | override the built-in cleaners directory (used by tests) |
| `CMM_PREFIX`, `CMM_BIN_DIR`, `CMM_OLD_PREFIX` | install/uninstall location overrides (tests) |
| `CMM_BREW_LOCATIONS` | where to look for a Homebrew that is installed but not on `PATH` (tests) |
| `CMM_LINK_DIRS` | where else launcher links may live, colon-separated (default `/usr/local/bin:~/.local/bin`; tests keep away from the host's `/usr/local/bin`) |

## Enabling and disabling cleaners

```bash
scrubmac list                    # name, state, default, tool found?, source, summary
scrubmac disable npm
scrubmac enable docker xcode     # several at once (or docker,xcode); opt-in cleaners start disabled
```

`disabled` and `enabled` record *explicit* choices; every other cleaner
follows its default (`# default: on|off` in its header). Explicit choices
survive future default changes, and new opt-in cleaners stay off until you
enable them. Both files start with a `# scrubmac:` header line; you may edit
them by hand — comments and stray whitespace are ignored, and your comments
are kept when scrubmac rewrites them. A file scrubmac cannot read is never
rewritten (`enable`/`disable` exit 2 instead of dropping its contents).

Upgrading from ≤ 3.0 converts the old disabled-list-only format once and
says so: docker/xcode you had enabled — and the go cleaner, which used to
run by default — stay enabled. That needs the `disabled` file 3.0 wrote when
you made a choice (the wizard, `enable`/`disable`, or declining the setup
offer); a 3.0 install that never had one — run only unattended, say — looks
like a fresh install, so run `scrubmac enable go` if you want go back. The
conversion only touches a `disabled` file without the header and with no
`enabled` file beside it, so a 3.1 setup whose state dir was wiped (a new
Mac with synced dotfiles) is never mistaken for a 3.0 one.

Naming cleaners explicitly (`scrubmac docker`, or `scrubmac run docker`)
runs them even when disabled — explicit intent wins. `--skip <name>` (or a
comma-separated list) leaves cleaners out of one run. Names are never
glob-expanded.

## Modes

| Flag | Effect |
|---|---|
| `--dry-run` / `-n` | print every mutating command, execute none; read-only previews (`brew upgrade --dry-run`, `npm outdated`, …) do run, and so do scrubmac's own first-run setup and one-time migrations |
| `--update-only` | update tools; leave caches alone |
| `--clean-only` | clean caches; change no versions (Homebrew's `brew autoremove` may still uninstall dependencies nothing needs any more) |
| `--measure` | report the space each cleaner frees |
| `--json` | the run's summary as JSON on stdout; all other output goes to stderr (for runs, `status` and `last` only) |
| `--quiet` / `-q` | one line per cleaner instead of its output; a failing cleaner's output is still shown |
| `scrubmac status` | read-only: each cleaner's cache sizes and outdated packages (always shows output, even with `QUIET=1`) |

Options that would change what a command does — or that it cannot honor —
are errors rather than silently ignored: `--dry-run` is refused for
`update` (use `update --check`), `schedule`, `enable`, `disable`,
`configure` and `config set|unset`; `--json` works only for runs, `status`
and `last`; `--scheduled`, `--measure` and the mode flags only for runs;
`--skip` only for runs and `status`. `-q` and `-n` are accepted (and
ignored) by read-only commands.

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
scrubmac schedule weekly fri 18:30  # day names: mon … sun (or monday …)
scrubmac schedule daily 07:00
scrubmac schedule                   # status
scrubmac schedule off
```

This writes a per-user LaunchAgent that runs `scrubmac --scheduled --quiet`.
Unlike cron, launchd runs a job missed while the Mac slept as soon as it
wakes (a Mac that is powered off skips it). The agent carries the `PATH`
of the shell you scheduled from (minus `.` and relative entries), so your
tools are found — re-run the command after changing your `PATH`. It also
carries scrubmac's state dir and the locations launchd would not know, when
your shell sets them: the XDG directories, and tool homes such as
`PNPM_HOME`, `BUN_INSTALL`, `CARGO_HOME`, `RUSTUP_HOME`, `GOPATH`,
`VOLTA_HOME`, `PIPX_HOME`, `UV_TOOL_DIR` or `PYENV_ROOT` (the full list is
`CMM__SCHEDULE_ENV` in `lib/schedule.sh`) — absolute values only, and not
one inside the directory you schedule from (a project's own, like direnv's
`GEM_HOME`) unless that is your home or one of its parents. Schedule from a plain shell: a shell with direnv settings gets
a warning, since its `PATH` is the project's too. It runs
with background priority, and each cleaner starts in your home directory
(launchd itself starts jobs in `/`). Re-scheduling replaces the old agent
(waiting for launchd to unload it first), and re-enables an agent you had
disabled with `launchctl disable`. When the agent is not loaded or its
launcher is gone, `scrubmac schedule status` and `scrubmac doctor` print the
exact command that recreates it. In these unattended runs each cleaner gets
a process group of its own, so anything a cleaner leaves running after it
finishes is stopped (and noted) — launchd would have stopped it at the end
of the job.

`--scheduled` runs are unattended: never interactive (no casks unless
`APP_UPDATES=always`), they honor `ON_BATTERY=skip` and
`MIN_HOURS_BETWEEN_RUNS`, and with `NOTIFY=failures` (the default) a failure
raises a desktop notification. Every real run leaves a log (dry runs and
`status` do not) — `scrubmac last`.

### cron

cron's `PATH` is only `/usr/bin:/bin`, so without a `PATH=` line almost
every cleaner skips (scrubmac warns when every cleaner skipped, or when
Homebrew is installed but not on the run's `PATH`, and `scrubmac doctor`
flags a crontab entry that gets no `PATH` — it understands a `PATH=` line, an
inline `PATH=… scrubmac`, and entries run through a login shell such as
`zsh -lc`). A working crontab:

```
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
0 9 * * 1  $HOME/.scrubmac/bin/scrubmac --scheduled --quiet
```

Notifications from cron jobs are unreliable on macOS (cron runs outside your
login session); launchd agents get them.

Non-TTY runs never prompt: with no config they use the defaults and print a
one-line hint. A concurrent run — manual, cron, or launchd — is excluded by
the lock (the second exits 2). Scheduling the same Mac with both cron and
launchd runs scrubmac twice; `doctor` warns about that.

## Logs and the JSON record

Each real run writes `~/.local/state/scrubmac/logs/run-<UTC timestamp>-<pid>.log`:
a header, one `== name: status (seconds, exit code)` line per cleaner with
its captured output (unattended and quiet runs capture everything; an
interactive run streams to your terminal and logs the statuses), the
summary, and the exit code. The newest `LOG_KEEP` logs are kept (at least
one).

`MIN_HOURS_BETWEEN_RUNS` counts from the start of the last successful full
run: no cleaner names, no `--skip`, not a dry run or a mode run, online, exit
0, and at least one cleaner actually ran (`ok`). A stamp from the future (a
clock change) is ignored.

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
  "skipped": null,
  "exit_code": 1,
  "totals": {"ok": 14, "skipped": 12, "failed": 1},
  "disk_freed_kb": 1300000,
  "log_file": "/Users/you/.local/state/scrubmac/logs/run-20261005T090000Z-4242.log",
  "cleaners": [
    {"name": "homebrew", "status": "ok", "exit_code": 0, "seconds": 41, "source": "builtin", "freed_kb": null, "cache_kb": null, "notes": ["casks not upgraded (unattended run; APP_UPDATES=interactive)"]}
  ]
}
```

Statuses: `ok`, `skip`, `fail` (including a cleaner file that disappeared
mid-run), `timeout`, `refused` (execution-safety guard), `stopped`
(interrupted). `skipped` is `null`, except in the `--json` output of a
`--scheduled` run that chose not to run (on battery, or too soon after the
last one): then it gives the reason, and `cleaners` is empty. Such a run
does not replace `last-run.json`. Notes name what went wrong — e.g. `failed: brew upgrade
--formula (exit 1)` for a command run through `run` or `step`.
