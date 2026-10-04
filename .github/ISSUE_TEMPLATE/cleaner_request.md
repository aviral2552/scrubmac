---
name: Cleaner request
about: Propose a new tool for scrubmac to maintain
labels: cleaner
---

**Tool**: (name + link)

**Gate command**: (what `command -v` proves it's installed)

**Update command(s)**: (must be non-interactive — link the official docs)

**Cache/cleanup command(s)**: (regenerable caches only — no user data; link the docs)

**Does it self-update?** If yes: how does a brew/npm/pipx install differ from
a standalone one?

**Can updates be limited by release age?** (for the supply-chain cooldown)

**Anything it must never touch** (state dirs, auth, models, globally installed tools, …):

**Should it be opt-in?** (anything deleting more than an obvious cache is)

Willing to send a PR? See docs/writing-cleaners.md.
