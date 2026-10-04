#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# docs-check.sh — fail when the code and the docs drift apart (D9):
#   1. every cleaners/NN-name.sh has a "### name" section in docs/cleaners.md
#      and every such section has a cleaner;
#   2. every built-in cleaner carries valid gate/group/default/summary
#      headers, and its section states the same default;
#   3. every command a cleaner runs through run/try/step/preview/report/
#      cache_dir_cmd — at a line start or after ; && || then do else — and
#      every self-updater it hands to ai_self_update, appears (up to its
#      first variable or quote) in that cleaner's section, as does "brew
#      upgrade --cask" for brew_cask_upgrade_self (cleaner-specific wrappers
#      are left to review);
#   4. every built-in setting is documented in docs/configuration.md and has
#      a ".B KEY" entry in the man page, both stating its current default;
#   5. every subcommand bin/scrubmac dispatches is documented in README.md
#      and in the man page.
set -euo pipefail
unset CDPATH

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

# helper_commands FILE — the commands FILE runs through the helper
# vocabulary, one per line, cut at the first quote, variable or backslash.
# Quoted strings are masked first, so prose in messages never matches.
helper_commands() {
  perl -ne '
    next if /^\s*#/;
    chomp(my $l = $_);
    $l =~ s/\s+#.*$//;
    (my $m = $l) =~ s/"(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27/\x01/g;
    my @found;
    while ($m =~ /(?:^|[;&|]|(?:^|[;&|])\s*(?:then|do|else))\s*(?:run|try|step|cache_dir_cmd|(?:preview|report)(?:\s+--ok=\d+)?)\s+([^;&|\x01]*)/g) { push @found, $1 }
    while ($m =~ /(?:^|[;&|]|(?:^|[;&|])\s*(?:then|do|else))\s*ai_self_update\s+\S+\s+([^;&|\x01]*)/g) { push @found, $1 }
    for my $c (@found) {
      $c =~ s/[\$\\].*$//; $c =~ s/\s+$//; $c =~ s/\s+/ /g;
      print "$c\n" if $c =~ m{^[A-Za-z0-9_./]};
    }
    print "brew upgrade --cask\n" if $m =~ /(?:^|[;&|]|then|do|else|\|\|)\s*brew_cask_upgrade_self\s/;
  ' "$1"
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
$(helper_commands "$f")
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
  def="$(sed -n "s/^CMM_SETTINGS='//; s/^$key|\([^|]*\)|.*/\1/p" "$ROOT/lib/dispatch.sh" | head -n 1)"
  # (column alignment in the table, and how the man entry wraps, do not matter)
  grep -Eq "^\|[[:space:]]*\`$key\`[[:space:]]*\|[[:space:]]*\`$def\`[[:space:]]*\|" "$CONF" ||
    problem "setting $key is not in docs/configuration.md's table with its default ($def)"
  grep -Fxq ".B $key" "$MAN" || problem "setting $key has no '.B $key' entry in man/scrubmac.1"
  awk -v k=".B $key" -v d="(default $def)" '
    $0 == k { f = 1; next }
    f && /^\.(TP|SH)/ { exit }
    f { b = b " " $0 }
    END { gsub(/[ \t]+/, " ", b); exit !index(b, d) }' "$MAN" ||
    problem "man/scrubmac.1's '.B $key' entry does not say '(default $def)'"
done

# 5: subcommands — the arms of bin/scrubmac's final dispatch
cmds="$(awk '/^case "\$CMD" in$/ { on = 1; next } on && /^esac/ { exit } on && /^  [a-z][a-z-]*\)/ { sub(/^  /, ""); sub(/\).*/, ""); print }' "$ROOT/bin/scrubmac")"
[ -n "$cmds" ] || problem "could not read the subcommands from bin/scrubmac"
for cmd in $cmds; do
  grep -Eq "scrubmac $cmd([^a-z-]|\$)" "$README" || problem "README.md never shows 'scrubmac $cmd'"
  # an entry of its own in COMMANDS (.TP, then .B CMD), not a mention elsewhere
  awk -v c="$cmd" '/^\.SH / { s = $2 } s == "COMMANDS" && p == ".TP" && /^\.B / && $2 == c { f = 1 } { p = $0 } END { exit !f }' "$MAN" ||
    problem "man/scrubmac.1 has no '.B $cmd' entry under COMMANDS"
done

if [ "$fail" -eq 0 ]; then
  echo "docs-check: cleaners, settings, and commands are documented consistently"
fi
exit "$fail"
