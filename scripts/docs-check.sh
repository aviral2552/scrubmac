#!/usr/bin/env bash
# docs-check.sh — fail when cleaners/ and docs/cleaners.md drift apart (D9).
# Every cleaners/NN-name.sh must have a "### name" heading in the reference,
# and every "### name" heading must correspond to a shipped cleaner.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOC="$ROOT/docs/cleaners.md"
fail=0

if [ ! -f "$DOC" ]; then
  echo "docs-check: docs/cleaners.md is missing" >&2
  exit 1
fi

for f in "$ROOT"/cleaners/*.sh; do
  [ -e "$f" ] || continue
  b="$(basename "$f")"
  name="${b%.sh}"
  name="$(printf '%s\n' "$name" | sed 's/^[0-9][0-9]*-//')"
  if ! grep -q "^### $name\$" "$DOC"; then
    echo "docs-check: no '### $name' section in docs/cleaners.md (for $b)" >&2
    fail=1
  fi
done

while IFS= read -r heading; do
  name="${heading#\#\#\# }"
  found=0
  for f in "$ROOT"/cleaners/*-"$name".sh; do
    [ -e "$f" ] && found=1
  done
  if [ "$found" -eq 0 ]; then
    echo "docs-check: '### $name' in docs/cleaners.md has no cleaners/NN-$name.sh" >&2
    fail=1
  fi
done <<EOF
$(grep '^### ' "$DOC")
EOF

if [ "$fail" -eq 0 ]; then
  echo "docs-check: cleaners/ and docs/cleaners.md are in sync"
fi
exit "$fail"
