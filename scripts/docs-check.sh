#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# docs-check.sh — fail when the code and the docs drift apart (D9):
#   1. every cleaners/NN-name.sh has a "### name" section in docs/cleaners.md
#      and every such section has a cleaner;
#   2. every built-in cleaner carries valid gate/group/default/summary
#      headers, and its section states the same default;
#   3. every command a cleaner runs through run/try/step/preview/report
#      appears (up to its first variable or quote) in that cleaner's section;
#   4. every built-in setting is documented in docs/configuration.md and in
#      the man page;
#   5. every subcommand is documented in README.md and in the man page.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$ROOT/docs/cleaners.md"
CONF="$ROOT/docs/configuration.md"
MAN="$ROOT/man/scrubmac.1"
README="$ROOT/README.md"
fail=0

problem() {
  echo "docs-check: $*" >&2
  fail=1
}

for f in "$DOC" "$CONF" "$MAN" "$README"; do
  [ -f "$f" ] || {
    echo "docs-check: missing $f" >&2
    exit 1
  }
done

# section NAME — the text of "### NAME" up to the next ##/### heading.
section() {
  awk -v h="### $1" '
    $0 == h { on = 1; next }
    on && /^##/ { exit }
    on { print }
  ' "$DOC"
}

# 1 + 2 + 3: per-cleaner checks
for f in "$ROOT"/cleaners/*.sh; do
  [ -e "$f" ] || continue
  b="${f##*/}"
  name="${b%.sh}"
  name="$(printf '%s\n' "$name" | sed 's/^[0-9][0-9]*-//')"
  if ! grep -q "^### $name\$" "$DOC"; then
    problem "no '### $name' section in docs/cleaners.md (for $b)"
    continue
  fi
  for key in gate group summary; do
    grep -Eq "^# $key: .+" "$f" || problem "$b has no '# $key:' header"
  done
  def="$(sed -n 's/^# default: //p' "$f" | head -n 1)"
  case "$def" in
    on | off) ;;
    *) problem "$b needs '# default: on' or '# default: off' (has '${def:-nothing}')" ;;
  esac
  text="$(section "$name")"
  if ! printf '%s\n' "$text" | grep -Eqi "default: \*\*$def\*\*"; then
    problem "docs/cleaners.md '### $name' does not state 'default: **$def**'"
  fi
  # commands run through the helper vocabulary
  while IFS= read -r cmd; do
    [ -n "$cmd" ] || continue
    if ! printf '%s\n' "$text" | grep -Fq -- "$cmd"; then
      problem "docs/cleaners.md '### $name' never mentions \`$cmd\` (run by $b)"
    fi
  done <<EOF
$(sed -n -E 's/^[[:space:]]*(run|try|step|preview|report)[[:space:]]+([A-Za-z0-9_./][^[:space:]]*.*)$/\2/p' "$f" |
    sed -E 's/[[:space:]]+#.*$//; s/["$'"'"'\\].*$//; s/[[:space:]]+$//')
EOF
done

while IFS= read -r heading; do
  [ -n "$heading" ] || continue
  name="${heading#\#\#\# }"
  found=0
  for f in "$ROOT"/cleaners/*-"$name".sh; do
    [ -e "$f" ] && found=1
  done
  [ "$found" -eq 1 ] || problem "'### $name' in docs/cleaners.md has no cleaners/NN-$name.sh"
done <<EOF
$(grep '^### ' "$DOC" | sed -n '/^### [a-z0-9-]*$/p')
EOF

# 4: settings
keys="$(sed -n '/^CMM_SETTINGS=/,/^[^A-Z]/p' "$ROOT/lib/dispatch.sh" |
  sed -E "s/^CMM_SETTINGS='//" | awk -F '|' 'NF >= 4 { print $1 }')"
[ -n "$keys" ] || problem "could not read the settings registry from lib/dispatch.sh"
for key in $keys; do
  grep -Fq "\`$key\`" "$CONF" || problem "setting $key is not documented in docs/configuration.md"
  grep -Fq "$key" "$MAN" || problem "setting $key is not documented in man/scrubmac.1"
done

# 5: subcommands
for cmd in list status doctor configure enable disable config schedule last update version help; do
  grep -Eq "scrubmac $cmd" "$README" || problem "README.md never shows 'scrubmac $cmd'"
  awk -v c="$cmd" '/^\.B / && $2 == c { f = 1 } END { exit !f }' "$MAN" ||
    problem "man/scrubmac.1 has no '.B $cmd' entry"
done

if [ "$fail" -eq 0 ]; then
  echo "docs-check: cleaners, settings, and commands are documented consistently"
fi
exit "$fail"
