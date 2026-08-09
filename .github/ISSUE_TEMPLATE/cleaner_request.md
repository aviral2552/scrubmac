---
name: Cleaner request
about: Propose a new tool for scrubmac to maintain
labels: cleaner
---

**Tool**: (name + link)

**Gate command**: (what `command -v` proves it's installed)

**Update command(s)**: (must be non-interactive)

**Cache/cleanup command(s)**: (regenerable caches only — no user data)

**Does it self-update?** If yes: how does a brew/npm install differ from a
standalone one?

**Anything it must never touch** (state dirs, auth, models, …):

Willing to send a PR? The contract is ~15 lines:
docs/writing-cleaners.md
