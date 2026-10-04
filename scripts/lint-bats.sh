#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# lint-bats.sh FILE… — reject bats assertions that can never fail:
#   - `! cmd` in a test body, also inside an && list (errexit ignores a
#     negated command — use refute/refute_sh);
#   - a `[[ … ]]` or `(( … ))` assertion that does not end in `|| false`
#     (bash < 4.1, i.e. macOS's bash, ignores a failing one unless it is the
#     test's last command) — at a line start, and after `;`, `{`, `then`,
#     `do` or `else` on the same line;
#   - a chain of assertions (`[ … ] && [ … ]`, `test … && grep …`,
#     `refute … && refute …`, `diff … && diff …`) that does not end in
#     `|| false` (errexit ignores every member of an && list but the last),
#     and an && list continued on the next line;
#   - a `[[` assertion split over several lines.
# Quoted strings (fixture scripts passed as arguments) and heredoc bodies
# (stub scripts) are not checked; neither are the conditions of if/while.
set -euo pipefail

perl -ne '
  BEGIN { $bad = 0 }
  if (defined $term) { $term = undef if /^\s*\Q$term\E\s*$/; next }
  my $l = $_;
  chomp $l;
  $term = $2 if $l =~ /(?<!<)<<(?!<)-?\s*(["\x27]?)([A-Za-z_][A-Za-z0-9_]*)\1/;
  if ($l =~ /^\@test\s/) { $in_test = 1 }
  elsif ($l =~ /^\}/) { $in_test = 0 }
  next if $l =~ /^\s*#/;
  (my $code = $l) =~ s/\s+#[^"\x27]*$//;
  $code =~ s/"(?:[^"\\]|\\.)*"|\x27[^\x27]*\x27/\x01/g;
  my $why;
  my $cond = $code =~ /^\s*(?:if|elif|while|until)\b/;
  my $test = qr/(?:\[\[?\s|\(\(|test\s|grep\s|refute\s|refute_sh\s|diff\s|cmp\s)/;
  my $ends_false = qr/\|\|\s*false\s*(?:;\s*(?:\}|fi|done))?\s*$/;
  if ($in_test && $code =~ /^\s*!\s/) { $why = "use refute/refute_sh, not ! cmd" }
  elsif ($in_test && !$cond && $code =~ /&&\s*!\s/) { $why = "a ! inside an && list never fails the test: use refute" }
  elsif ($code =~ /^\s*(\[\[|\(\()/ && $code !~ /(\]\]|\)\))/) { $why = "keep a [[ / (( assertion on one line" }
  elsif ($code =~ /^\s*(\[\[|\(\().*(\]\]|\)\))\s*;?\s*$/) { $why = "end this assertion with || false" }
  elsif ($code =~ /(?:;|\{|\bthen|\bdo|\belse)\s*(?:\[\[|\(\()(?:(?!\]\]|\)\)).)*(?:\]\]|\)\))(?!\s*\|\|\s*false)/) {
    $why = "end this assertion with || false";
  }
  elsif (!$cond && $code =~ /^\s*$test.*&&\s*$/) {
    $why = "an && list continued on the next line: only its last member is enforced";
  }
  elsif ($code =~ /^\s*$test.*&&\s*$test/ && $code !~ $ends_false && $code !~ /&&\s*(?:\{|echo|printf|return|exit|break|continue)/) {
    $why = "an && chain of tests: end it with || false (or one assertion per line)";
  }
  if ($why) { print "$ARGV:$.: $why: $l\n"; $bad = 1 }
  if (eof) { close ARGV; $term = undef; $in_test = 0 }
  END { exit $bad }
' "$@"
