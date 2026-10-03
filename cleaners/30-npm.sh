#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# gate: npm
# group: JavaScript
# default: on
# summary: update global packages (cooldown-aware), self-update standalone npm, verify the cache
# npm: update global packages — under the supply-chain cooldown, each to the
# newest release that is at least COOLDOWN_DAYS old and never to anything
# older than what is installed (npm's own --before/min-release-age would
# downgrade newer globals) — self-update standalone npm installs, and
# garbage-collect the cache.
set -euo pipefail
# shellcheck source=../lib/common.sh
. "${CMM_LIB:-"$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/lib/common.sh"}"

TAB=$'\t'

# Reads `npm outdated -g --json` on stdin; prints "name<TAB>current" per
# outdated global package. Exits 3 on unreadable input or an npm error.
NPM_OUTDATED_JS='
  const fs = require("fs");
  let d;
  try { d = JSON.parse(fs.readFileSync(0, "utf8").trim() || "{}"); } catch (e) { process.exit(3); }
  if (!d || typeof d !== "object" || Array.isArray(d) || d.error) process.exit(3);
  for (const [name, info] of Object.entries(d)) {
    const list = Array.isArray(info) ? info : [info];
    for (const i of list) {
      if (i && typeof i.current === "string" && name[0] !== "-") { console.log(name + "\t" + i.current); break; }
    }
  }'

# Reads `npm view PKG time versions dist-tags --json` on stdin (npm 12 wraps
# it in an array); argv: CURRENT CUTOFF. Prints "pick<TAB>VERSION" for the
# newest stable release newer than CURRENT, not past the "latest" tag, and
# published at or before CUTOFF; "held" when newer releases exist but are
# all too fresh; "none" otherwise. Exits 3 on unreadable input.
NPM_PICK_JS='
  const fs = require("fs");
  const [cur, cutoff] = process.argv.slice(1);
  let d;
  try { d = JSON.parse(fs.readFileSync(0, "utf8").trim() || "{}"); } catch (e) { process.exit(3); }
  if (Array.isArray(d) && d.length && d[0] && typeof d[0] === "object" && !Array.isArray(d[0])) d = d[0];
  if (!d || typeof d !== "object" || d.error) process.exit(3);
  const time = d.time && typeof d.time === "object" ? d.time : {};
  let versions = d.versions;
  if (typeof versions === "string") versions = [versions];
  if (!Array.isArray(versions)) versions = [];
  if (versions.length && Array.isArray(versions[0])) versions = versions[0];
  let tags = d["dist-tags"];
  if (Array.isArray(tags)) tags = tags[0];
  const parse = (v) => {
    const m = /^v?(\d+)\.(\d+)\.(\d+)(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$/.exec(String(v));
    return m ? [+m[1], +m[2], +m[3], m[4] || ""] : null;
  };
  const cmp = (a, b) => (a[0] - b[0]) || (a[1] - b[1]) || (a[2] - b[2]);
  const c = parse(cur);
  if (!c) { console.log("none"); process.exit(0); }
  const latest = tags && typeof tags.latest === "string" ? parse(tags.latest) : null;
  const cut = Date.parse(cutoff);
  let best = null, newer = false;
  for (const v of versions) {
    const p = parse(v);
    if (!p || p[3]) continue;
    if (cmp(p, c) <= 0) continue;
    if (latest && !latest[3] && cmp(p, latest) > 0) continue;
    newer = true;
    const t = Date.parse(time[v]);
    if (!(t <= cut)) continue;
    if (!best || cmp(p, best.p) > 0) best = { v: v, p: p };
  }
  console.log(best ? "pick\t" + best.v : (newer ? "held" : "none"));'

# npm_cooldown_pick PKG CURRENT CUTOFF — the resolver's verdict (see above).
npm_cooldown_pick() {
  local info
  info="$(npm view "$1" time versions dist-tags --json 2>/dev/null)" || return 1
  printf '%s' "$info" | node -e "$NPM_PICK_JS" "$2" "$3"
}

# npm_cooldown_update DAYS — move each outdated global package to the newest
# release at least DAYS old (and never backwards).
npm_cooldown_update() {
  local days="$1" cutoff out pairs pkg cur verdict held=0
  cutoff="$(date_days_ago "$days")"
  note "- cooldown: updating global packages only to releases published before $cutoff (${days}d)"
  if ! have node; then
    note "- node not found, so the cooldown cannot be applied: global updates are held"
    summary_note "global updates held (node not found for the cooldown resolver)"
    return 0
  fi
  out="$(npm outdated -g --json 2>/dev/null)" || true # exits 1 whenever anything is outdated
  if ! pairs="$(printf '%s' "$out" | node -e "$NPM_OUTDATED_JS")"; then
    warn "could not read 'npm outdated -g --json'"
    cmm_fail_later
    return 0
  fi
  if [ -z "$pairs" ]; then
    note "- global packages are up to date"
    return 0
  fi
  while IFS="$TAB" read -r pkg cur; do
    [ -n "$pkg" ] || continue
    if ! verdict="$(npm_cooldown_pick "$pkg" "$cur" "$cutoff")"; then
      warn "registry lookup failed for $pkg"
      cmm_fail_later
      continue
    fi
    case "$verdict" in
      pick"$TAB"*) step npm install -g "$pkg@${verdict#pick"$TAB"}" ;;
      held)
        held=$((held + 1))
        note "- $pkg $cur: every newer release is under ${days} days old — held"
        ;;
    esac
  done <<EOF
$pairs
EOF
  [ "$held" -gt 0 ] && summary_note "$held global update(s) held by the ${days}-day cooldown"
  return 0
}

skip_unless npm

cache_dir_cmd npm config get cache
report npm outdated -g
preview npm outdated -g

if updating; then
  days="$(cooldown_days)"
  kind="$(install_kind npm)"
  case "$kind" in
    standalone)
      if [ "$days" -gt 0 ] && have node; then
        verdict="$(npm_cooldown_pick npm "$(npm --version 2>/dev/null)" "$(date_days_ago "$days")" || true)"
        case "$verdict" in
          pick"$TAB"*) step npm install -g "npm@${verdict#pick"$TAB"}" ;;
          *) note "- npm: no newer release outside the ${days}-day cooldown" ;;
        esac
      elif [ "$days" -gt 0 ]; then
        note "- npm self-update held: node not found for the cooldown resolver"
      else
        step npm install -g npm@latest
      fi
      ;;
    npm) note "- npm is bundled with its node install; updating node updates npm" ;;
    *) note "- npm is ${kind}-managed; that manager updates it" ;;
  esac
  if [ "$days" -gt 0 ]; then
    npm_cooldown_update "$days"
  else
    try npm outdated -g # advisory: exits 1 whenever anything is outdated
    step npm update -g
  fi
fi

if cleaning; then
  step npm cache verify
fi
