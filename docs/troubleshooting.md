# Troubleshooting & FAQ

## "brew doctor said something scary but the run shows ok"

`brew doctor` and `brew missing` are *advisory* — brew exits non-zero
whenever it has opinions, which is most machines. cleanmymac reports what
they said and moves on; only failures of mutating commands (`brew upgrade`,
`brew cleanup`) fail the homebrew cleaner.

## "why did my cleaner say 'skipped self-update'?"

The tool is managed by a package manager. Self-updating a brew- or
npm-managed binary writes into the manager's territory and gets clobbered on
its next upgrade, so cleanmymac defers: the note names the cleaner that owns
the update (homebrew or npm). This is by design (D4).

## "npm updates are 'held' — why?"

You enabled the supply-chain cooldown. npm has no safe way to say "latest
version at least N days old" — its `--before` flag would *downgrade* globals
installed more recently than the cutoff — so cleanmymac holds automatic npm
updates while a cooldown is set and shows you `npm outdated -g` instead.
Details: [security.md](security.md#s4--supply-chain-cooldown).

## "another cleanmymac run is already in progress"

Two runs at once would fight over package-manager locks, so a lock excludes
them. If the pid in the message is dead, the next run recovers the stale lock
automatically. Exit code 2 identifies this case for scripts.

## "cleanmymac: command not found" after install

The installer links into the first user-writable of brew's bin,
`/usr/local/bin`, `~/.local/bin` — and tells you if that directory is not on
your PATH. Run `~/.cleanmymac/bin/cleanmymac doctor` directly; it reports the
link and PATH state.

## "a cleaner was refused: group/world-writable"

The execution-safety guard (S2). Cleaner files must be owned by you and not
writable by group/others; symlinked cleaners are never run. Fix:
`chmod 755 file` / `chown` it, or delete it if you don't recognize it —
that's the guard doing its job.

## "docker/xcode never run"

They're heavy pruners, disabled by default. `cleanmymac enable docker`, the
wizard's heavy-pruner screen, or run one explicitly: `cleanmymac docker`.

## Why no sudo? Why no "deep clean"? Why is my Trash still full?

Doctrine: cleanmymac never escalates, never deletes user data, never fights
SIP. macOS maintains itself; most "deep cleaning" of system caches is
regression-prone theater. The old 1.x "macOS core cleaner" shipped fully
commented out for exactly this reason — 2.x deleted it and wrote the
reasoning down: [security.md](security.md#what-cleanmymac-will-never-do).

## The wizard won't start over SSH/cron

It requires an interactive TTY. Either run it from a terminal, or write
`~/.config/cleanmymac/config` directly — the whole format is four keys
([configuration.md](configuration.md#config-keys)).

## Yarn berry does nothing

Correct: Yarn 2+ keeps caches per-project and removed `yarn global`. The
cleaner explains and moves on; classic Yarn 1 still gets a global upgrade +
cache clean.

## Update says my history has diverged

`cleanmymac update` refuses non-fast-forward pulls (S3) — you edited the
installed copy, or the remote was force-pushed. Inspect with
`git -C ~/.cleanmymac status`, stash/reset your changes deliberately, and run
update again. Local edits belong in `~/.config/cleanmymac/cleaners.d/`
instead — they survive updates.
