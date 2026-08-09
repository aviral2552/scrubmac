# Renaming: decision record & future runbook

**Status (2026-08-09): name LOCKED — `scrubmac`.** The GitHub name is
reserved (private placeholder at `aviral2552/scrubmac`); the detailed
execution plan lives in **[rename-plan-scrubmac.md](rename-plan-scrubmac.md)**
and supersedes the generic checklist and candidate table below. Execution
timing remains the maintainer's call; homebrew-core submission stays gated on
the self-submission notability bar.

*(Historical record below — 2026-08-03 research that led here.)*

## Why a rename may eventually be needed

All facts below were verified against primary sources on 2026-08-03.

1. **Trademark reality.** MacPaw's CleanMyMac (2008/2009) predates this repo
   (created 2018-10-30). This project claims no precedence — the README says
   so — and the `cleanmymac*` Homebrew token family is MacPaw territory:
   `cleanmymac` (their app cask), `cleanmymac-cli` (their official CLI cask),
   `cleanmymac-zh` (localized variant).
2. **Hard file conflict.** MacPaw's official cask stanzas:
   `binary …, target: "cleanmymac"` **and** `target: "cmm"` — their CLI
   symlinks `$(brew --prefix)/bin/cleanmymac`. Our formula links the same
   path. Users installing both hit brew link failures (see
   [troubleshooting](troubleshooting.md#brew-link-conflict-with-macpaws-cleanmymac-cli)).
3. **homebrew-core is name-blocked and notability-blocked.**
   `brew audit --new` enforces token uniqueness across core formulae AND
   cask tokens — `cleanmymac` is hard-blocked. Separately,
   `shared_audits.rb` applies `SELF_SUBMISSION_THRESHOLD_MULTIPLIER = 3` to
   self-submitted PRs: **≥225 stars or ≥90 forks or ≥90 watchers
   (subscribers)** required. Repo stood at 90 / 17 / 2 — passes the standard
   bar (75/30/30), fails the self-submission bar.

## Vetted name candidates (as of 2026-08-03 — RE-VERIFY before use)

Checks run per candidate: core formula token (`formulae.brew.sh/api/formula/<t>.json` 404),
cask token 404, `github.com/aviral2552/<t>` free, npm/PyPI free, product-name web search.

| Candidate | Verdict then | Notes |
|---|---|---|
| **devgroom** | clean on every check | recommended: no `mac`/`clean` morphemes, honest ("grooms your dev toolchain"), cross-platform story intact |
| **macgroom** | clean (surname/Instagram noise only) | keeps explicit macOS identity; reintroduces the `mac` morpheme |
| uptidy | registries clean; **caveat** | multiple commercial "Uptidy" cleaning-sector marks (services, an LLC, cleaning software) — usable but same-semantic-field risk |
| ~~sweepkit~~ | disqualified | active Rust dev-cleaning CLI already uses it |
| ~~devsweep, devtidy~~ | disqualified | existing same-function tools |

## Rename checklist (the actual runbook)

1. Re-verify the chosen token: formula + cask APIs, `brew search`, GitHub,
   npm/PyPI, product web search, open homebrew-core PRs.
2. GitHub repo rename (Settings → rename): **preserves stars/forks and
   redirects** old URLs and `git` remotes. Update local remotes anyway.
3. In-repo: `bin/cleanmymac` → `bin/<name>` (and every `cleanmymac` string:
   usage text, lock file name, `~/.config/cleanmymac` — ship a config-dir
   migration: prefer new path, fall back to old, offer to move), man page
   file + `.TH`, README, docs/, CHANGELOG, Makefile `SH_FILES`, workflows,
   `packaging/homebrew/<name>.rb`, install/uninstall (symlink names incl.
   legacy-cleanup for the old name), tests.
4. Release: bump minor (rename = user-visible), tag, let the release
   workflow ship `<name>-x.y.z.tar.gz` + SHA256SUMS with **no residual
   "cleanmymac" string in the artifact**.
5. Tap: add `Formula/<name>.rb`; keep the old formula one release as a
   deprecation shim (`deprecate!` + caveat pointing at the new name).
6. Only then consider homebrew-core (below).

## homebrew-core submission mechanics (when the bar is met)

- Bar: ≥225 stars or ≥90 forks or ≥90 watchers for a self-submitted PR
  (standard 75/30/30 applies only when someone unaffiliated submits — do not
  launder submissions; maintainers read provenance).
- Formula at `Formula/<first-letter>/<name>.rb`; `license` stanza mandatory;
  meaningful `test do` (dry-run against a stubbed HOME — **not**
  `--version`, which the Cookbook calls a bad test); pure-shell formulae
  bottle as `cellar: :any_skip_relocation, all:` (precedent: `bats-core`);
  macOS-only is fine via `depends_on :macos` (precedent: `mas`); category
  precedent: `topgrade`. Self-update must stay disabled under brew — already
  true (`cleanmymac update` delegates to brew).
- Local gate before the PR: `HOMEBREW_NO_INSTALL_FROM_API=1 brew install
  --build-from-source <name>` · `brew test <name>` · `brew audit --strict
  --new --online <name>` · `brew style --fix --formula <name>` ·
  `brew lgtm --online`. Commit message: `<name> x.y.z (new formula)`.
- 2026 AI policy: disclose AI/LLM assistance in the PR, personally review
  everything, answer all review comments yourself (no AI), max one open
  AI-assisted PR for non-maintainers.
