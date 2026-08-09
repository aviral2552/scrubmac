# Rename execution plan: cleanmymac → scrubmac (v3.0.0) — rev 2

**Status: LOCKED & PLANNED — not yet executed.**
Decision locked 2026-08-09. GitHub name reserved (private placeholder at
`aviral2552/scrubmac`; delete it in Phase 2 immediately before the real
rename). Availability verified 2026-08-09: brew formula 404, cask 404,
GitHub exact-name zero, npm 404, PyPI 404, no product hits.
Supersedes the candidate table in [renaming.md](renaming.md).
*Rev 2 integrates a 20-finding adversarial review (4 blockers): shim
symlink resolution, sed/worktree corruption, installer config-seeding vs
migration ordering, self-hosted install.sh re-run, tap rename mechanics
verified against Homebrew 6 source, and 15 more — inline throughout.*

---

## 0. Decisions (deliberate — do not relitigate during execution)

| Decision | Choice | Rationale |
|---|---|---|
| New name, binary, formula token, repo | `scrubmac` | verified-empty namespace; owner's pick |
| Version | **3.0.0** | binary + both user dirs change = breaking |
| `CMM_*` env vars, `cmm_*`/`w_*` internals | **KEEP** | cron/CI users set `CMM_COOLDOWN_DAYS`; zero surface value in renaming. Documented as historical initials |
| Config dir | `~/.config/cleanmymac` → `~/.config/scrubmac`, auto-migrated by **both** the binary and install.sh | §3.1 — installer must migrate BEFORE its config seeding or it defeats the binary's migration forever |
| Install dir (git installs) | `~/.cleanmymac` → `~/.scrubmac`, migrated by install.sh, **compat symlink left at the old path** | §3.2 — the project itself published cron lines hardcoding `~/.cleanmymac/bin/…` |
| Old binary name | in-tree deprecation **shim** at `bin/cleanmymac` with full symlink resolution; never PATH-linked by installer/formula; removed in v4 | §3.3 |
| Old lock name | 3.x also holds the legacy `cleanmymac.$uid.lock` for the shim's lifetime | a 2.x cron copy and 3.x must still mutually exclude (remove in v4) |
| Tap migration | **`formula_renames.json` + DELETE old formula** (primary); deprecate!-only is the mutually-exclusive fallback | verified in Homebrew 6 `formulary.rb`: the renames entry shadows the old formula file unconditionally — keeping both makes the deprecation dead code and violates brew's rename docs |
| History/identity | README keeps: "formerly `cleanmymac` (2018–2026), renamed to end confusion with MacPaw's unrelated products" | honest provenance; MacPaw's *CleanMyMac* product name legitimately remains in docs |
| homebrew-core | deferred until ≥225 stars / ≥90 forks / ≥90 watchers | §7; token becomes `scrubmac` |

## 1. Inventory (ground truth 2026-08-09: 33 files, 306 occurrences)

**Mechanical rename** (explicit include-list — this list IS the §5 sed target):
`tests/runner.bats`(17) `tests/install.bats`(14) `tests/uninstall.bats`(9)
`tests/security.bats`(7) `tests/wizard.bats`(2) `tests/helpers/setup.bash`(1)
`.github/workflows/release.yml`(5) `.github/workflows/ci.yml`(4)
`Makefile`(1) `.shellcheckrc`(1)
`lib/common.sh`(2 — **1 comment, 1 FUNCTIONAL: `cmm_config_dir` line 105, the
path §3.1 pivots on; a test must pin both old and new literals**)
`lib/wizard.sh`(4 — UI strings) `docs/cleaners.md`(5 — enable-hint command
strings) `cleaners/60-docker.sh`(1) `cleaners/70-xcode.sh`(1)
`.github/ISSUE_TEMPLATE/*`(3) `SECURITY.md`(1) `CONTRIBUTING.md`(1)

**File renames + content**: `bin/cleanmymac`(29)→`bin/scrubmac` (+ new shim),
`man/cleanmymac.1`(14)→`man/scrubmac.1` (`.TH SCRUBMAC`; `Cleanmymac` formula
class → `Scrubmac`), `packaging/homebrew/cleanmymac.rb`(9)→`…/scrubmac.rb`.

**Semantic rewrite** (individually, never sed): `README.md`(33)
`docs/troubleshooting.md`(20 — MacPaw entry becomes historical)
`install.sh`(18 — migration logic §3.2) `docs/security.md`(14)
`RELEASING.md`(13 — old-formula references survive) `docs/renaming.md`(12 —
mark executed) `CHANGELOG.md`(11 — add 3.0.0, never rewrite history)
`uninstall.sh`(9 — must handle BOTH names) `docs/architecture.md`(9)
`docs/configuration.md`(7 — cron section gets the new path + migration note)
`docs/writing-cleaners.md`(2).

**Completeness gate** (two-sided):
```
grep -ri cleanmymac --exclude-dir=.git --exclude-dir=.claude .
```
must return ONLY these whitelisted survivors: the shim; migration code in
`bin/scrubmac` + `install.sh` + `uninstall.sh` (old literals reintroduced on
purpose); legacy lock name in `acquire_lock`; CHANGELOG history; README
"formerly" line + MacPaw disclaimer; `docs/renaming.md`;
`docs/rename-plan-scrubmac.md` (this file); `docs/troubleshooting.md`
historical MacPaw entry; RELEASING/tap old-formula references; case-insensitive
hits on MacPaw's product name "CleanMyMac". Anything else is a miss.

## 2. What stays untouched

Exit-code + cleaner contracts, all 19 cleaners' behavior, `CMM_*` env
interface, config grammar/keys, `disabled`/`cleaners.d` mechanics, test
architecture, LICENSE, git history. **Exception now flagged**: the runtime
lock additionally holds the legacy name (see §0); the stale leftover
worktree directory `.claude/worktrees/project-codebase-overview-ea6fe9/`
must be deleted in P1 prep (it contains a `.git` pointer file that a naive
sed would corrupt — see §5).

## 3. Migration design

### 3.1 Config dir — shared logic, used by BOTH `bin/scrubmac` (pre-config-read) and `install.sh` (pre-seeding)
```
new=~/.config/scrubmac   old=~/.config/cleanmymac        # XDG-aware
if [ -L old ]:                                            # dotfiles managers (stow/chezmoi)
    if resolve(old) == resolve(new): done                 # already migrated
    else: warn once "config symlink points elsewhere — repoint/rename it to
          ~/.config/scrubmac (contents NOT auto-migrated)"; still use new
elif [ ! -e new ] && [ -d old ]:
    if mv old new 2>/dev/null; then ln -s new old; note "(migrated config; symlink left)"
    fi                                                    # tolerant: concurrent loser re-evaluates,
                                                          # never aborts when new now exists (set -e safe)
elif [ -e new ] && [ -d old ] && [ ! -L old ]:
    warn once "both config dirs exist; using new — merge/remove old manually"
```
Race note: this runs before `acquire_lock`, so a post-upgrade cron and an
interactive run can race — hence the tolerant `mv`, guarded so migration can
never abort an invocation when the new dir ends up present.

### 3.2 Install dir & links — `install.sh`
Ordered steps (order is load-bearing):
1. **Config migration first** (§3.1 logic) — BEFORE the fresh-config seeding
   block, which would otherwise create `~/.config/scrubmac` and permanently
   defeat migration (verified failure mode: settings, disabled list, and
   `cleaners.d/` silently orphaned + wizard re-offers).
2. Dir migration: if `~/.cleanmymac` exists (not a symlink) and `~/.scrubmac`
   doesn't: `mv`, then `ln -s ~/.scrubmac ~/.cleanmymac` — the compat symlink
   keeps the project's own previously-documented cron line
   (`$HOME/.cleanmymac/bin/cleanmymac -q`) alive via the shim.
3. **Self-hosted re-run case** (the normal case — the shim tells users to
   re-run `install.sh`, and theirs lives IN the old dir): if `SRC_DIR` is the
   old install dir (or already `~/.scrubmac`), after the `mv` treat it as
   "running from DEST_DIR": refresh links only, **skip the rsync** (whose
   source path just moved — otherwise `set -e` aborts mid-migration with no
   working command under either name).
4. Links: link `scrubmac` only; remove `cleanmymac` bin links pointing into
   either install dir (all candidate dirs); same for the **man-page link**
   (`man1/cleanmymac.1` → remove if it points into either dir, link
   `scrubmac.1`).
5. Post-checks: (a) `crontab -l 2>/dev/null | grep cleanmymac` → specific
   warning to update cron lines; (b) `command -v cleanmymac` — if it now
   resolves OUTSIDE both install dirs, print: *"note: 'cleanmymac' on your
   PATH is now <path> (MacPaw's CLI), not this tool — update crontabs and
   aliases to 'scrubmac'"*.
6. `uninstall.sh`: handle BOTH dir names, the compat dir-symlink, BOTH bin
   link names (incl. dangling), both man links.

### 3.3 The shim — `bin/cleanmymac` (in-tree, ~15 lines)
One stderr line — `cleanmymac is now scrubmac; this alias will be removed in
v4 — re-run install.sh to finish migrating` — then exec the sibling
`scrubmac`. **Must carry the same symlink-resolution loop as the real binary**
(`bin/cleanmymac:11-19` today): its primary audience invokes it through a
PATH symlink (`/usr/local/bin/cleanmymac → ~/.cleanmymac/bin/cleanmymac`),
where a naive `dirname "$0"` points at the bin dir — which has no `scrubmac`
link yet for exactly this pre-migration audience — and would exit 127, the
precise failure the shim exists to prevent. Never PATH-linked by installer or
formula; removed in v4 together with the legacy lock name.

### 3.4 Homebrew tap migration — two mutually exclusive paths
**Primary**: add `Formula/scrubmac.rb` (v3.0.0 asset + sha256) + tap-root
`formula_renames.json` `{"cleanmymac": "scrubmac"}` + **git rm
`Formula/cleanmymac.rb`** (Homebrew 6 resolves the rename BEFORE looking for
the old file — a kept old formula is unreachable dead code and violates
brew's Rename-A-Formula rules). Verify live in P4 on this machine (it has tap
cleanmymac 2.0.1 installed — the perfect guinea pig).
**Fallback** (only if the live verify fails in third-party taps): no renames
file; keep `Formula/cleanmymac.rb` with
`deprecate! date: "<exec date>", because: "was renamed to scrubmac",
replacement_formula: "scrubmac"` (exact grammar matters: brew renders
"…because it <reason>!", and it auto-announces a disable date 12 months out —
schedule `disable!` with the v4 shim removal or accept the discrepancy).
**Fallback caveat, verified**: deprecation messaging shows only on `brew
info`/fresh install — a formula pinned at 2.0.1 never participates in
`brew upgrade`, so existing users get **zero signal** and `cleanmymac update`
no-ops forever. If the fallback is exercised, ship one final old-formula
release (2.0.2) whose only change announces the rename in caveats +
post-install — a version bump is the only channel guaranteed to reach them.

### 3.5 Who experiences what (corrected per review)
| User | Experience |
|---|---|
| brew user, `brew upgrade` (primary path) | rename resolves natively; keg **migrated in place** (Cellar rack moved, compat symlink left, receipt+pin carried over; old version removed by normal upgrade cleanup); ends on scrubmac 3.0.0 |
| brew user with `cleanmymac` **pinned** | never upgrades or migrates until `brew unpin` — release notes must say so |
| brew user with `cleanmymac -q` in cron / an alias | after migration: bare `command not found` (shim is deliberately not on PATH) — announced in formula caveats + release notes; `scrubmac doctor` gains a stale-crontab check |
| git user, runs `cleanmymac update` | pull works via GitHub redirect; next invocation hits the shim (through their PATH symlink — §3.3 handles it) → nag + exec scrubmac; re-running install.sh completes migration |
| git user, re-runs `install.sh` (incl. from inside `~/.cleanmymac`) | full migration: config first, dir moved with `.git` intact, compat dir-symlink left, links + man links swapped, cron/PATH warnings printed |
| cron `~/.cleanmymac/bin/cleanmymac -q` | works before AND after install.sh re-run (compat dir-symlink + shim); shim nag lands in cron mail |
| user who also installs MacPaw's `cleanmymac-cli` | after we release the name, `cleanmymac` may resolve to MacPaw's binary — install.sh's §3.2(5b) check + tap caveat call it out explicitly |
| user with `~/.config/cleanmymac` as a dotfiles symlink | warned to repoint; nothing auto-migrated, nothing silently lost |
| fresh user | installs `scrubmac`; never sees the old name |

## 4. Phased execution

**P0 — Lock-in. DONE 2026-08-09** (placeholder repo; this plan).

**P1 — Code rename on a branch** (~3–4h; tests dominate). Prep: delete the
stale leftover worktree dir (§2). Mechanical pass per §5 → `git mv` the three
renamed files → shim (§3.3) → migration code (§3.1/3.2 incl. seeding order,
self-hosted re-run, compat symlink, man links, cron/PATH checks, legacy lock)
→ semantic rewrites → CHANGELOG 3.0.0 + VERSION + man retitle → **new
tests**: config migration ×4 branches (+symlinked-old case), install-dir
migration external fixture AND self-hosted re-run fixture, seeded-old-config
→ install.sh-first → values honored + custom cleaner discovered, shim direct
AND through-a-PATH-symlink, installer link+man-link swap, both-dirs
uninstall, legacy lock mutual exclusion, `cmm_config_dir` old+new literal
pins. DoD: `make lint test docs-check` green (~130 tests), two-sided §1 gate
clean, §6 matrix green. PR → CI → merge. *Rollback: don't merge.*

**P2 — GitHub rename** (minutes). `gh repo delete aviral2552/scrubmac`
(placeholder) → `gh api -X PATCH repos/aviral2552/cleanmymac -f name=scrubmac`
→ update local remotes + tap README → verify old URL still answers via
redirect. **Hard rule forever: never create a new repo named `cleanmymac`
— it would sever the redirect.** *Rollback: rename back.*

**P3 — Release 3.0.0.** Tag → workflow publishes `scrubmac-3.0.0.tar.gz` +
`SHA256SUMS` → verify independently. Release notes = §3.5 table + the honest
story + pinned-formula note + per-formula-trust note (§4-P4). *Rollback:
delete tag+release only before anyone consumes it.*

**P4 — Tap migration** (§3.4 primary) + live verification on this machine:
(a) `brew update && brew upgrade` with installed cleanmymac 2.0.1 → lands on
scrubmac 3.0.0, keg migrated; (b) `scrubmac version|list|doctor`; (c) fresh
sandbox: `brew trust aviral2552/tap` (Homebrew 6 trust store is empty in a
clean prefix — and **per-formula trust grants for `…/cleanmymac` do NOT
carry to `…/scrubmac`**, tap-level grants do) then
`brew install aviral2552/tap/scrubmac`; (d) uninstall cleanliness;
(e) `brew audit --strict scrubmac`. If (a) fails → switch to fallback path
(§3.4) including the 2.0.2 announcement release. *Rollback: revert tap
commits.*

**P5 — Comms & bookkeeping.** Repo description/topics; README pins new URLs;
`docs/renaming.md` → EXECUTED; memory notes; release-notes announcement.
Within days: reserve `scrubmac` on npm/PyPI only as functional pointer
packages (both registries prohibit pure squatting).

**P6 — homebrew-core (unchanged trigger: ≥225★/90 forks/90 watchers).**
`Formula/s/scrubmac.rb`, meaningful `test do` (dry-run vs stubbed HOME),
local gate (`HOMEBREW_NO_INSTALL_FROM_API=1 brew install
--build-from-source`, `brew test`, `brew audit --strict --new --online`,
`brew style --fix`, `brew lgtm --online`), commit `scrubmac 3.x.y (new
formula)`, PR with the truthful case; AI-disclosure box checked; the author
personally answers review.

## 5. P1 mechanical pass (corrected)

```bash
git checkout -b rename/scrubmac origin/master
git worktree prune && rm -rf .claude/worktrees/project-codebase-overview-ea6fe9  # §2 — its .git POINTER FILE contains the repo path; a tree-wide sed would sever it
# Explicit include-list = §1's mechanical files ONLY (semantic files get eyes, per file):
git grep -l cleanmymac -- tests/ .github/ Makefile .shellcheckrc \
  lib/common.sh lib/wizard.sh docs/cleaners.md cleaners/60-docker.sh cleaners/70-xcode.sh \
  SECURITY.md CONTRIBUTING.md | xargs sed -i '' 's/cleanmymac/scrubmac/g'
git mv bin/cleanmymac bin/scrubmac
git mv man/cleanmymac.1 man/scrubmac.1
git mv packaging/homebrew/cleanmymac.rb packaging/homebrew/scrubmac.rb
# then by hand: shim, migration code, semantic rewrites, Scrubmac class, CLEANMYMAC man header
```
`git grep -l` (tracked files only) is immune to the worktree pointer file;
review every hunk regardless. The sed never touches README, RELEASING.md,
install.sh, uninstall.sh, CHANGELOG.md, or docs/ other than cleaners.md.

## 6. Verification matrix (all green before P3 tags)

| # | Check |
|---|---|
| 1 | `make lint test docs-check` (~130 tests incl. the new migration suite) |
| 2 | two-sided completeness gate (§1 whitelist exact) |
| 3 | sandbox fresh install → `scrubmac` runs; `cleanmymac` NOT on PATH |
| 4a | legacy external fixture → install.sh migrates (dir, git, links, man link, notes) |
| 4b | **self-hosted re-run**: `cd ~/.cleanmymac && ./install.sh` fixture → completes, links swapped, `.git` intact |
| 4c | seeded old config → install.sh FIRST → scrubmac run → values honored, custom cleaner discovered, no wizard re-offer |
| 5 | config migration live: moved + symlink + honored; both-exist warns; **symlinked-old warns without data loss** |
| 6 | shim at real path AND **through a PATH symlink in a foreign bin dir** → nags on stderr, execs scrubmac, preserves argv + exit code |
| 7 | `/bin/bash` 3.2 smoke on every script |
| 8 | dry-run full pass: 19 cleaners, summary intact |
| 9 | uninstall fixtures: both layouts, both link names, compat dir-symlink, man links |
| 10 | man page renders; `scrubmac help/version/doctor` |
| 11 | legacy lock: fixture 2.x holding `cleanmymac.$uid.lock` blocks a 3.x run |

## 7. Risk register (corrected)

| Risk | Mitigation |
|---|---|
| formula_renames.json misbehaves in third-party taps | P4(a) live verify before announcing; documented fallback **including the 2.0.2 announcement release** (deprecation alone is invisible to existing users — verified in brew's upgrade.rb) |
| someone claims `scrubmac` elsewhere pre-execution | GitHub reserved; npm/PyPI functional pointers in P5; don't sit on the plan for months |
| GitHub redirect severed later | never re-create a `cleanmymac` repo |
| sed over/under-reach | explicit include-list from tracked files only (§5); two-sided gate (§1); hunk review |
| users with both config dirs / symlinked config | §3.1 branches: prefer new, warn, never delete, never silently lose a dotfiles symlink |
| old name captured by MacPaw's CLI on user machines | by design (name released); §3.2(5b) check + caveat + release notes say it out loud |
| concurrent 2.x cron vs 3.x during transition | legacy lock name held by 3.x (§0) |
| MacPaw cask leftover on this machine skews P4 | remove first (owner: `brew uninstall --cask cleanmymac`) or use the clean-prefix sandbox with `brew trust` |
| stars reset fear | false: GitHub renames preserve stars/forks/watchers + redirect |

## 8. Effort estimate

P1 ≈ 3–4 focused hours (tests + semantic rewrites dominate) · P2 ≈ 10 min ·
P3 ≈ 20 min · P4 ≈ 45 min incl. live verifications · P5 ≈ 30 min.
Total: a solid afternoon.
