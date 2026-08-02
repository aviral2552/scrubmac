# Configuration

Everything lives in `~/.config/cleanmymac/` (respects `$XDG_CONFIG_HOME`):

| File | Purpose |
|---|---|
| `config` | `KEY=value` settings — parsed with a strict grammar, **never executed** |
| `disabled` | disabled cleaner names, one per line |
| `cleaners.d/` | your own cleaners; a same-named file overrides a built-in |

## The wizard

`cleanmymac configure` (offered automatically on the first interactive run):

1. **Welcome** — the safety doctrine, and the rules: `(r)` restarts, `(q)`
   quits, nothing is written until the summary is confirmed.
2. **Services** — one screen per group (package managers · JavaScript ·
   Python · AI tools · languages · heavy pruners), each item marked
   `found` / `not found (auto-skips)`. Toggle by number, `a` = all on,
   `n` = none. The heavy-pruner screen spells out exactly what docker/xcode
   would delete. Your `cleaners.d/` cleaners appear in an "Other" screen.
3. **Update cooldown** — skip package versions younger than 0/3/7/14 days
   (7 recommended). The screen states the trade-off: security patches are
   also delayed. Scope: mechanical for uv, hold-and-advise for npm,
   not applicable to Homebrew ([why](security.md#s4--supply-chain-cooldown)).
4. **Output** — full vs quiet; color auto/always/never.
5. **Summary** — confirm with `y`, restart with `r`, quit with `q`.

Declining the first-run offer writes defaults so you are never nagged again.

## Config keys

| Key | Default | Meaning |
|---|---|---|
| `COOLDOWN_DAYS` | `0` | supply-chain cooldown in days (0 = off) |
| `QUIET` | `0` | `1` = hide cleaner output unless it fails |
| `COLOR` | `auto` | `auto` / `always` / `never` |
| `DERIVEDDATA_AGE_DAYS` | `30` | xcode cleaner's DerivedData age gate |

Values may contain only `A-Za-z0-9._/-`; malformed lines are ignored (this is
a security property — see [security.md](security.md#s5--config-cannot-execute-code)).

## Environment variables

| Variable | Effect |
|---|---|
| `CMM_COOLDOWN_DAYS`, `CMM_DERIVEDDATA_AGE_DAYS` | override config for one run |
| `NO_COLOR` | disable color (standard) |
| `CMM_CLEANERS_DIR` | override the built-in cleaners directory (used by tests) |
| `CMM_PREFIX`, `CMM_BIN_DIR` | install/uninstall location overrides (tests) |

Flags beat environment beats config beats defaults.

## Enabling and disabling cleaners

```bash
cleanmymac list             # see states
cleanmymac disable npm
cleanmymac enable docker    # heavy pruners start disabled
```

Naming cleaners explicitly (`cleanmymac docker`) runs them even when
disabled — explicit intent wins.

## Cron / non-interactive use

Non-TTY runs never prompt: with no config they use the defaults (heavy
pruners off) and print a one-line hint. A sensible crontab entry:

```
0 9 * * 1  $HOME/.cleanmymac/bin/cleanmymac -q
```

Exit code is 1 if any cleaner failed, so cron mail / your monitor sees it.
A concurrent manual run is excluded by the lock (the second run exits 2).
