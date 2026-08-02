# Architecture

~1,500 lines of bash 3.2-compatible shell, structured as a dispatcher, a
shared library, and independent cleaner processes.

```
bin/cleanmymac ──sources──▶ lib/common.sh          (helpers, guards, config)
      │        ──sources──▶ lib/wizard.sh          (configure / first run only)
      │
      ├─ discovers ▶ cleaners/NN-name.sh           (built-in)
      │              ~/.config/cleanmymac/cleaners.d/*.sh   (yours; shadows built-ins by name)
      │
      └─ executes each cleaner as a child process
             child sources lib/common.sh via $CMM_LIB
```

## Execution flow (`cleanmymac [names…]`)

1. **Self-locate** — resolve `${BASH_SOURCE[0]}` through symlinks; everything
   is relative to that root. No state files (the 1.x `~/.cleanmymac/path`
   indirection is gone).
2. **Refuse root**, set `LC_ALL=C`, read config (strict parser — see
   [security.md](security.md)).
3. **First-run offer** — no config + interactive TTY → offer the wizard;
   decline writes defaults; non-TTY uses defaults with a hint line.
4. **Lock** — atomic `mkdir` in `$TMPDIR` with a pid file; a live concurrent
   run exits 2, a stale lock (dead pid) is recovered.
5. **Discover** — executable `*.sh` regular files, user dir first, deduped by
   cleaner *name* (`10-homebrew.sh` → `homebrew`), ordered by basename, minus
   the `disabled` list. Every file must pass the execution-safety guard
   (owner, permissions, no symlinks) or it is refused with a warning.
6. **Run loop** — per cleaner: banner → child process with the `CMM_*`
   environment → record exit code + duration → **continue regardless**.
   Quiet mode buffers child output and dumps it only on failure. INT/TERM
   kills the child, prints a partial summary, exits 130.
7. **Summary** — ok/skip/FAIL per cleaner, totals, approximate disk freed
   (df delta). Exit 1 if anything failed.

## The cleaner contract

A cleaner is an executable script that:

- declares its gating command(s) in a `# gate: cmd…` header line (used by
  `list`, `doctor`, and the wizard's found/not-found markers)
- sources `$CMM_LIB` (with a relative fallback so it also runs standalone)
- gates on tool presence: `skip_unless brew` → prints a note and exits **75**
- runs every mutating command via `run …` (dry-run aware, failure = cleaner
  fails) and advisory commands via `try …` (failure tolerated)
- never prompts (a prompt is a hang in cron), never sudo, never user data,
  never secrets in argv

Exit codes: `0` ok · `75` skipped · anything else failed. The dispatcher maps
these to the summary; the CLI itself exits `0/1/2/130`.

## Configuration precedence

flags (`-n`, `-q`) → environment (`CMM_*`) → config file → built-in defaults.
The dispatcher resolves this once and exports `CMM_DRY_RUN`, `CMM_QUIET`,
`CMM_COOLDOWN_DAYS`, `CMM_DERIVEDDATA_AGE_DAYS`, `CMM_BREW_PREFIX`,
`CMM_COLOR`, `CMM_LIB` to every cleaner.

## Install modes

| Mode | Detected by | `cleanmymac update` does |
|---|---|---|
| git (`install.sh` or clone) | `.git` present at root | `git pull --ff-only` + diffstat |
| Homebrew formula | root under `brew --prefix` | `brew upgrade cleanmymac` |
| bare copy | neither | prints reinstall guidance |

`install.sh` mirrors the source tree into `~/.cleanmymac` with
`rsync -a --delete` — the app dir is wholly owned by the tool (user state
lives in `~/.config/cleanmymac`), which is also what auto-purges a legacy 1.x
layout on upgrade.

## bash 3.2 compatibility

macOS still ships bash 3.2.57 and cleanmymac runs on it natively (CI smokes
every script with `/bin/bash -n` plus a live `--dry-run`). Consequences: no
associative arrays, no `mapfile`, no `${var,,}`; indexed arrays are accessed
by position (`set -u`-safe on 3.2); `set -euo pipefail` throughout.

## Testing strategy

bats-core, fully hermetic: every test gets a sandbox HOME/XDG/TMPDIR and a
stub PATH factory that records exact argv into a call log — no real package
manager is ever reachable. Suites: `runner` (dispatcher semantics), `lib`
(helpers + guards), `cleaners` (per-cleaner argv pins), `wizard` (stdin-driven
full passes), `install`/`uninstall` (sandboxed cycles), `security` (S1–S7
pins). `make docs-check` keeps [cleaners.md](cleaners.md) honest.
