# Troubleshooting & FAQ

Start with `scrubmac doctor` — it reports the install, settings that differ
from their defaults, every tool and how it was installed, the schedule and
crontab, the last run, the launcher on your PATH, and PATH problems.
`scrubmac last` shows the newest run's log; a failing step is also named in
the summary (`failed: brew upgrade --formula (exit 1)`).

## "Every cleaner skipped" (cron)

cron runs jobs with `PATH=/usr/bin:/bin`, so Homebrew, npm, uv and friends
are "not found" and every cleaner skips — the run looks successful and does
nothing. scrubmac warns when this happens — and, earlier, when Homebrew is
installed but missing from the run's PATH — and `scrubmac doctor` flags a
crontab entry that gets no `PATH`. Either add one:

```
PATH=/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin
0 9 * * 1  $HOME/.scrubmac/bin/scrubmac --scheduled --quiet
```

or replace the crontab line with `scrubmac schedule weekly`, which carries
your PATH into a launchd agent (and runs missed schedules after sleep).

## "TIMEOUT" in the summary

A cleaner ran longer than `TIMEOUT` (default 3600 seconds) and was stopped
together with the processes it started (`TERM`, then `KILL` up to five
seconds later for anything that ignored it; a process that detached into a
session of its own, as daemons do, is out of reach). The rest of the run
continued. If a
tool legitimately needs longer (a huge cask download, a from-source build),
raise it: `scrubmac config set TIMEOUT 7200`, or `CMM_TIMEOUT=0 scrubmac`
for one unbounded run.

## "REFUSED" in the summary / "a cleaner was refused"

The execution-safety guard (S2). Cleaner files must be owned by you and not
writable by group/others, their directory likewise; symlinked cleaners are
never run. A refusal fails the run on purpose; `scrubmac doctor` says which
condition failed. Fix: `chmod 755 file` / `chown` it, or delete it if you
don't recognize it — that's the guard doing its job.

## "the cleaner file disappeared during the run"

One of your own cleaners (in `cleaners.d`) was deleted while the run was
going. Built-in cleaners cannot hit this: they run from a private copy made
at the start of the run, so even a Homebrew upgrade of scrubmac itself in
the middle of the run (the homebrew cleaner can do that) leaves them alone.

## "brew doctor said something scary but the run shows ok"

`brew doctor` and `brew missing` are *advisory* — brew exits non-zero
whenever it has opinions, which is most machines. scrubmac reports what
they said and moves on; only failures of the mutating commands (`brew
update`, `brew upgrade`, `brew cleanup`) fail the homebrew cleaner — and the
summary names which one. `HOMEBREW_DOCTOR=0` skips the advisory pair.

## "casks not upgraded (unattended run)"

Upgrading a GUI app can quit it (Homebrew 6 quits and reopens apps whose
cask asks for it) or stop for your password (pkg installers), so casks are
only upgraded when you run scrubmac in a terminal yourself. Run `scrubmac
homebrew` interactively, or `scrubmac config set APP_UPDATES always` if you
accept that in scheduled runs. See
[configuration.md](configuration.md#app-updates).

## "App Store updates pending — run 'mas update' yourself"

mas installs App Store updates as root (it re-runs itself through `sudo`),
and scrubmac never runs `sudo` itself, so it only reports them.

## "why did my cleaner say 'X is Homebrew-managed / npm-managed'?"

The tool is managed by a package manager. Self-updating a brew-, npm-,
pipx- or uv-managed binary writes into the manager's territory and gets
clobbered on its next upgrade, so scrubmac defers: the note names the
cleaner that owns the update. This is by design (D4). CLIs installed as
binary-only Homebrew casks (Claude Code, Codex, Copilot, Cursor) are
upgraded by name instead.

## "updates are held" / "N global update(s) held by the cooldown"

The supply-chain cooldown (`COOLDOWN_DAYS`, default 7) only installs
releases at least that old. A package whose newer releases are all younger
is held until one matures — nothing is downgraded. Yarn classic and old
pipx/Bun cannot filter by age at all, so their global upgrades are held
while the cooldown is on. To opt out: `scrubmac config set COOLDOWN_DAYS 0`;
for one run: `CMM_COOLDOWN_DAYS=0 scrubmac`. Details:
[security.md](security.md#s4--supply-chain-cooldown).

## "N uv tool(s) still held back by an exclude-newer cutoff in their receipts"

uv stores `--exclude-newer` in each tool's receipt. scrubmac before 3.1 —
and 3.1 with a uv older than 0.11.4, which cannot store a relative span —
passed an absolute date, which keeps plain upgrades of those tools frozen at
that date. With uv ≥ 0.11.24, `uv tool upgrade --all --exclude-newer false`
releases them (scrubmac does this itself when the cooldown is off); or
reinstall the tools (`uv tool install --force <tool>`).

## "global packages skipped: pnpm's global bin directory is not on PATH"

pnpm refuses global commands (pnpm 11 all of them, pnpm 12 every change)
while the directory it links global binaries into is not on `PATH` —
typically `pnpm setup` was never run (pnpm from Homebrew or Corepack), or a
schedule was made before it was. scrubmac skips global packages instead of
failing every run. Run `pnpm setup`, open a new shell, and run `scrubmac
schedule …` again so scheduled runs get the new `PATH` (and `PNPM_HOME`).
The summary mentions it only when you have global packages.

## "global update(s) held: … PNPM_HOME is not set here"

pnpm ≤ 10 can update global packages without knowing its global bin
directory, but cannot re-add them (`ERR_PNPM_NO_GLOBAL_BIN_DIR`) — usually
because `PNPM_HOME` is not set in that run (a schedule made before scrubmac
carried it, or a shell without it). Run `scrubmac schedule …` again from a
shell that sets it, or tell pnpm once:
`pnpm config set global-bin-dir "$PNPM_HOME"`.

## "global updates held: npm min-release-age '…' could not be read"

Your npm `min-release-age` is not a plain number of days (`1e1`, `${VAR}`,
`Infinity`), so scrubmac cannot tell how far back it reaches — passing its
own cutoff could relax yours. Write it as a plain number:
`min-release-age=7`.

## "pnpm updates held: pnpm minimumReleaseAge could not be read"

Your pnpm `minimumReleaseAge` is not a number of minutes (`Infinity`,
`1e21`, a word) — or pnpm cannot load its own configuration at all (pnpm 12
refuses such a value) — so a plain `pnpm update -g` would fail on it, and
passing scrubmac's cutoff could relax it. The self-update and global updates
are held; the store is still pruned. Set a whole number of minutes:
`pnpm config set minimumReleaseAge 20160` (two weeks).

## "Bun updates held: bunfig install.minimumReleaseAge could not be read"

Your bunfig's `minimumReleaseAge` has no number of seconds scrubmac can trust
(`inf`, more than 10¹², not a number, or a file it cannot follow), so it
holds `bun upgrade` and global updates rather than risk relaxing it. Make it
a plain number of seconds, and check that Bun loads the file (`bun pm ls -g`
complains when it cannot).

## "uv tool upgrades held: your exclude-newer could not be read"

Your `UV_EXCLUDE_NEWER`, or `exclude-newer` in a `uv.toml`, is in a form
scrubmac does not read, so it cannot tell which of it and the cooldown is
stricter — passing either one might relax the other. Use a date, an RFC 3339
timestamp, or a duration (`7 days`, `P7D`).

## "offline — updates skipped"

There was no default network route when the run started, so updates were
skipped and cleanup ran anyway. A captive-portal Wi-Fi still has a route;
those updates fail instead, which the summary shows.

## "another scrubmac run is already in progress"

Two runs at once would fight over package-manager locks, so a lock excludes
them — manual, cron and launchd runs alike. The lock records the holder's
pid and start time: if that process is gone (or the pid now belongs to a
different process), the next run recovers the lock automatically. Exit code
2 identifies this case for scripts. (`cannot write to …/state/scrubmac` is
a different problem — the state dir's ownership or permissions — and
`doctor` flags it too.)

## "uv cache in use — prune skipped"

Long-running `uvx`/`uv run` processes (MCP servers, for example) hold uv's
cache lock for as long as they live, and pruning would delete environments
they run from. scrubmac waits briefly, then skips the prune and says so;
upgrades are unaffected.

## "scrubmac: command not found" after install

The installer links into the first user-writable of brew's bin,
`/usr/local/bin`, `~/.local/bin` — and tells you if that directory is not on
your PATH. Run `~/.scrubmac/bin/scrubmac doctor` directly; it reports which
launcher your PATH finds and any dangling links. If a `scrubmac` that is not
ours (e.g. Homebrew's) already sits there, the installer leaves it alone
and says two installs now exist — keep one.

## "docker/xcode/go/rubygems never run"

They are opt-in. `scrubmac enable docker`, the wizard, or run one explicitly:
`scrubmac docker`.

## The schedule did not run

`scrubmac schedule status` (or `doctor`) says whether the agent is loaded and
whether its launcher still exists — and prints the exact `scrubmac schedule
…` command that recreates your schedule. launchd runs a schedule missed
during sleep at the next wake, but skips it while the Mac is off.
`ON_BATTERY=skip` and `MIN_HOURS_BETWEEN_RUNS` make scheduled runs skip on
purpose — the log (`scrubmac last`) says why. After moving the install or
changing your PATH, re-run your `scrubmac schedule` command. If cron also
runs scrubmac, `doctor` warns that you are scheduled twice.

## "ignoring line N of …/config" / "… is not a setting — did you mean …?"

That line does not match the strict `KEY=value` grammar (no spaces around
`=`, no quotes, no trailing comments; values only `A-Za-z0-9._/-`), so it is
ignored — and the warning says so instead of letting a typo pass silently.
The same goes for a key one edit away from a built-in setting
(`APP_UPDATE=never`): no setting reads it. Keys of your own cleaners that
are not near a built-in name pass quietly. `scrubmac config set KEY VALUE`
always writes a valid line.

## "nothing to run"

Every cleaner is disabled or left out by `--skip`. `scrubmac list` shows
each cleaner's state.

## Why no sudo? Why no "deep clean"? Why is my Trash still full?

Doctrine: scrubmac never runs `sudo` itself (the one exception: Homebrew
asks for your password to upgrade a pkg-based cask, in a run you start at a
terminal — `APP_UPDATES=never` rules it out), never deletes user data, never
fights SIP. macOS maintains itself; most "deep cleaning" of system caches is
regression-prone theater. The old 1.x "macOS core cleaner" shipped fully
commented out for exactly this reason — 2.x deleted it and wrote the
reasoning down: [security.md](security.md#what-scrubmac-will-never-do).

## The wizard won't start over SSH/cron

It requires an interactive TTY. Either run it from a terminal, or use
`scrubmac config set KEY VALUE` — see
[configuration.md](configuration.md#settings).

## Yarn berry does nothing

Correct: Yarn 2+ keeps caches per-project and removed `yarn global`. The
cleaner explains and moves on; classic Yarn 1 still gets a cache clean, and
a global upgrade with `COOLDOWN_DAYS=0` (the cooldown holds it otherwise:
Yarn 1 cannot filter by release age).

## Update says my copy has diverged

`scrubmac update` only fast-forwards (S3) — you edited the installed copy,
or the remote was force-pushed. A newer release it cannot take this way is
skipped with a warning (and an older one it can take is used instead); if
none can be taken, the update is refused. The same goes for a release tag
that was re-pointed upstream after your copy first saw it, or whose tag
object names a different release — published release tags never move. If
the maintainer did fix a tag on purpose, the warning shows the one command
that accepts it. Inspect with `git -C ~/.scrubmac
status`, stash/reset your changes deliberately, and run update again. Local
edits belong in `~/.config/scrubmac/cleaners.d/` instead — they survive
updates. A failed fetch (network, unreachable remote) and a detached HEAD
(with `UPDATE_CHANNEL=branch`) each get their own message.

## "release signatures are not checked"

Your install pins no signing keys yet (`share/allowed_signers`), so the
update trusts the GitHub repository. Once releases are signed and the file
ships, updates verify every release tag against the keys in your installed
copy, and skip (with a warning) a release that is not signed by one of
them. Branch updates (`UPDATE_CHANNEL=branch`, or a repository with no
release tags) are never signature-checked; scrubmac says so.

## uninstall.sh "left … alone"

uninstall.sh deletes a directory only when it holds a scrubmac install, and
never `/`, your home or a parent of it — compared as canonical paths, so
`$HOME/.` or a symlinked parent cannot trick it. It checks the install dir
before it touches anything, so a mistyped `CMM_PREFIX` costs nothing (with
`--purge`, a `CMM_PREFIX` that names nothing at all is refused before your
configuration is touched). When
the install path is a symlink, the link goes, and its target too if
install.sh created it (a link to a dev clone is kept, with a note). When it
refuses, it exits 1 and names the directory; delete it yourself if it really
is yours to delete.

## install.sh "… which install.sh did not create" / "is a git checkout with …"

install.sh makes the install dir an exact mirror of the copy you run it
from, deleting whatever is not in it. It therefore refuses to mirror over a
copy it did not create itself (no `.scrubmac-install` marker) when that copy
may be someone's working clone:

- the install path is a symlink to it (the dev-clone setup): run that
  clone's own install.sh, which refreshes the links in place, or remove the
  link first;
- it is a git checkout with uncommitted or untracked files (also ones that
  only your own global or `.git/info/exclude` ignore rules hide), a stash,
  or commits that are on no remote and in no release tag: commit and push,
  or move it away, first.

A clean git install from before 3.1 (everything pushed, nothing edited) is
upgraded as usual.

## "cannot read …/disabled — refusing to guess"

Your `enabled` or `disabled` file exists but cannot be read — its
permissions, or it is a dotfiles symlink into a folder this process may not
open (a launchd job cannot read `~/Documents` or an unmounted volume).
Running with the defaults instead would silently re-enable the cleaners you
turned off, so runs and `scrubmac list` stop with exit 2 until it is
readable again (fix the permissions or the link, or remove the file to go
back to the defaults). Running cleaners by name still works: it does not
consult those files.

## install.sh "newer than this copy"

The install at `~/.scrubmac` was updated past the copy whose install.sh you
ran (a stale clone, or the old `~/.cleanmymac`): mirroring it would
downgrade you. Run the newer copy's install.sh, or remove `~/.scrubmac`
first if you really mean to go back.

## (historical) the cleanmymac name conflict — resolved by the rename

Until 3.0.0 this project was named `cleanmymac` and its binary collided with
MacPaw's official `cleanmymac-cli` cask, which symlinks
`$(brew --prefix)/bin/cleanmymac` **and** `bin/cmm` — the two could not be
brew-linked side by side. The 2026 rename to `scrubmac` ended that conflict.
One echo remains during the transition: git installs ship a `cleanmymac`
compat shim (never PATH-linked; removed in v4), and once your old PATH links
are retired, a `cleanmymac` command on your machine is MacPaw's tool, not
this one. Full history: [renaming.md](renaming.md).
