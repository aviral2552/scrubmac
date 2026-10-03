#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# lib/dispatch.sh — the dispatcher's internals: settings, cleaner discovery
# and metadata, enable/disable state, run locking, environment probes, the run
# loop (timeouts, output capture, logs, JSON, notifications) and the summary.
#
# Sourced by bin/scrubmac after lib/common.sh, never executed. bash 3.2
# compatible: indexed arrays only, no associative arrays or mapfile.

TAB=$'\t'
CMM_US=$'\037' # unit separator: joins a cleaner's notes inside one array slot

# ---------- settings ----------
# One line per setting: KEY|default|type|description. Types: int (whole
# number), bool (0/1), or a comma-separated list of allowed words. Each key
# can be overridden for a single run as CMM_<KEY> in the environment; the
# effective (validated) value is exported to cleaners as CMM_<KEY>.
CMM_SETTINGS='COOLDOWN_DAYS|7|int|supply-chain cooldown: skip package versions younger than N days (0 = off)
QUIET|0|bool|1 = hide cleaner output unless the cleaner fails
COLOR|auto|auto,always,never|colored output
TIMEOUT|3600|int|per-cleaner time limit in seconds (0 = none)
APP_UPDATES|interactive|interactive,always,never|GUI app upgrades (Homebrew casks): interactive = only when you run scrubmac yourself
NOTIFY|failures|failures,always,never|desktop notification after unattended runs
ON_BATTERY|run|run,skip|scheduled runs while on battery power
MIN_HOURS_BETWEEN_RUNS|0|int|scheduled runs skip when a full run succeeded within N hours (0 = off)
LOG_KEEP|20|int|run logs to keep (at least 1 is always kept)
MEASURE|0|bool|1 = measure the space each cleaner frees (slower: du before/after)
UPDATE_CHANNEL|release|release,branch|what scrubmac update follows on git installs (release tags, or the branch)
DERIVEDDATA_AGE_DAYS|30|int|xcode: purge DerivedData not used for N days
DEVICESUPPORT_AGE_DAYS|90|int|xcode: purge device-support folders older than N days (the newest per platform is kept)
HOMEBREW_DOCTOR|1|bool|homebrew: run the advisory brew doctor and brew missing
DOCKER_KEEP_HOURS|168|int|docker: keep build cache used within N hours
MISE_PRUNE|0|bool|mise: also remove tool versions no config file uses'

cmm_setting_keys() {
  local key _rest
  while IFS='|' read -r key _rest; do
    [ -n "$key" ] && printf '%s\n' "$key"
  done <<EOF
$CMM_SETTINGS
EOF
}

# cmm_setting_info KEY — sets CMM__S_DEF, CMM__S_TYPE, CMM__S_DESC; fails for
# keys that are not built-in settings.
cmm_setting_info() {
  local key def type desc
  while IFS='|' read -r key def type desc; do
    if [ "$key" = "$1" ]; then
      CMM__S_DEF="$def"
      CMM__S_TYPE="$type"
      # shellcheck disable=SC2034  # read by bin/scrubmac and lib/doctor.sh
      CMM__S_DESC="$desc"
      return 0
    fi
  done <<EOF
$CMM_SETTINGS
EOF
  return 1
}

# cmm_setting_valid TYPE VALUE
cmm_setting_valid() {
  local v
  case "$1" in
    int)
      case "$2" in '' | *[!0-9]*) return 1 ;; esac
      v="${2#"${2%%[!0]*}"}" # leading zeros don't count toward the length
      [ "${#v}" -le 9 ]
      ;;
    bool)
      case "$2" in 0 | 1) return 0 ;; esac
      return 1
      ;;
    *)
      case "$2" in '' | *,*) return 1 ;; esac
      case ",$1," in
        *",$2,"*) return 0 ;;
      esac
      return 1
      ;;
  esac
}

# cmm_setting_norm TYPE VALUE — print a valid VALUE in canonical form (ints
# lose leading zeros, so "08" never reaches shell arithmetic as octal).
cmm_setting_norm() {
  if [ "$1" = int ]; then
    printf '%s\n' "$((10#$2))"
  else
    printf '%s\n' "$2"
  fi
}

cmm_type_hint() {
  case "$1" in
    int) printf 'a whole number' ;;
    bool) printf '0 or 1' ;;
    *) printf 'one of: %s' "${1//,/, }" ;;
  esac
}

CMM__WARNED=' '
cmm__warn_once() {
  case "$CMM__WARNED" in *" $1 "*) return 0 ;; esac
  CMM__WARNED="$CMM__WARNED$1 "
  warn "$2"
}

# Remember which CMM_<KEY> values came from the user's environment before
# the dispatcher starts exporting its own resolved values under those names.
cmm_settings_snapshot_env() {
  local key ev
  for key in $(cmm_setting_keys); do
    ev="CMM_$key"
    printf -v "CMM__ENV_$key" '%s' "${!ev:-}"
  done
}

# cmm_setting_resolve KEY — sets CMM__S_VAL and CMM__S_SRC (flag, env,
# config, or default). Invalid values are reported once and ignored.
cmm_setting_resolve() {
  local key="$1" v fv ev
  if ! cmm_setting_info "$key"; then
    CMM__S_VAL="$(config_get "$key" "")"
    CMM__S_SRC='custom'
    return 1
  fi
  fv="CMM__FLAG_$key"
  if [ -n "${!fv:-}" ]; then
    CMM__S_VAL="${!fv}"
    CMM__S_SRC='flag'
    return 0
  fi
  ev="CMM__ENV_$key"
  v="${!ev:-}"
  if [ -n "$v" ]; then
    if cmm_setting_valid "$CMM__S_TYPE" "$v"; then
      CMM__S_VAL="$(cmm_setting_norm "$CMM__S_TYPE" "$v")"
      CMM__S_SRC='env'
      return 0
    fi
    cmm__warn_once "env:$key" "ignoring CMM_$key=$v (expected $(cmm_type_hint "$CMM__S_TYPE"))"
  fi
  v="$(config_get "$key" "")"
  if [ -n "$v" ]; then
    if cmm_setting_valid "$CMM__S_TYPE" "$v"; then
      CMM__S_VAL="$(cmm_setting_norm "$CMM__S_TYPE" "$v")"
      CMM__S_SRC='config'
      return 0
    fi
    cmm__warn_once "cfg:$key" "ignoring $key=$v in $CMM_CONFIG_FILE (expected $(cmm_type_hint "$CMM__S_TYPE"))"
  fi
  CMM__S_VAL="$CMM__S_DEF"
  # shellcheck disable=SC2034  # read by callers
  CMM__S_SRC='default'
  return 0
}

# cmm_settings_export — resolve every built-in setting and export it as
# CMM_<KEY> for this process and every cleaner. Re-run after config changes.
cmm_settings_export() {
  local key
  for key in $(cmm_setting_keys); do
    cmm_setting_resolve "$key" || true
    export "CMM_$key=$CMM__S_VAL"
  done
}

# cmm_config_lint — warn about config lines the strict KEY=value grammar
# ignores, and about keys one typo away from a built-in setting (either
# would otherwise be silently dropped), and about a config file that cannot
# be read. CRLF line ends and a byte-order mark are fine (config_get reads
# through them). Once per process.
cmm_config_lint() {
  [ -n "${CMM__LINTED:-}" ] && return 0
  CMM__LINTED=1
  local f="$CMM_CONFIG_FILE" line n=0 bad key hint
  [ -e "$f" ] || return 0
  if [ ! -r "$f" ] || [ -d "$f" ]; then
    warn "cannot read $f — using the default settings"
    return 0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    n=$((n + 1))
    line="${line%$'\r'}"
    [ "$n" = 1 ] && line="${line#$'\357\273\277'}"
    case "${line#"${line%%[![:space:]]*}"}" in
      '' | '#'*) continue ;;
    esac
    bad=0
    case "$line" in
      *=*)
        case "${line%%=*}" in '' | [!A-Z]* | *[!A-Z0-9_]*) bad=1 ;; esac
        case "${line#*=}" in *[!A-Za-z0-9._/-]*) bad=1 ;; esac
        ;;
      *) bad=1 ;;
    esac
    if [ "$bad" = 1 ]; then
      warn "ignoring line $n of $f: '$line' (expected KEY=value; values may use only A-Z a-z 0-9 . _ / -)"
      continue
    fi
    key="${line%%=*}"
    cmm_setting_info "$key" && continue
    # shellcheck disable=SC2046  # keys never contain whitespace
    hint="$(CMM__SUGGEST_MAX=1 cmm_suggest "$key" $(cmm_setting_keys))"
    if [ -n "$hint" ]; then
      warn "line $n of $f: $key is not a setting — did you mean $hint? (as written, it is ignored)"
    fi
  done <"$f"
  return 0
}

# ---------- paths ----------
# cmm__abs PATH — PATH made absolute against the starting directory (runs
# change into $HOME before starting cleaners).
cmm__abs() {
  case "$1" in
    /*) printf '%s\n' "$1" ;;
    *) printf '%s/%s\n' "$PWD" "$1" ;;
  esac
}

cmm_init_paths() {
  CMM_CONFIG_DIR="$(cmm__abs "$(cmm_config_dir)")"
  CMM_CONFIG_FILE="$CMM_CONFIG_DIR/config"
  CMM_DISABLED_FILE="$CMM_CONFIG_DIR/disabled"
  CMM_ENABLED_FILE="$CMM_CONFIG_DIR/enabled"
  CMM_USER_CLEANERS_DIR="$CMM_CONFIG_DIR/cleaners.d"
  CMM_BUILTIN_CLEANERS_DIR="$(cmm__abs "${CMM_CLEANERS_DIR:-$CMM_ROOT/cleaners}")"
  # State (logs, last run, the run lock) lives under XDG_STATE_HOME — never
  # under TMPDIR, which differs between cron, launchd and terminal sessions.
  CMM_STATE_DIR="$(cmm__abs "${CMM_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/scrubmac}")"
  CMM_LOG_DIR="$CMM_STATE_DIR/logs"
  CMM_LAST_RUN_FILE="$CMM_STATE_DIR/last-run.json"
  CMM_LAST_SUCCESS_FILE="$CMM_STATE_DIR/last-success"
  CMM_LOCK="$CMM_STATE_DIR/run.lock"
  export CMM_CONFIG_FILE
}

# ---------- install mode ----------
# git (clone or install.sh copy with .git) · brew (a keg under the Homebrew
# prefix) · copy (anything else).
install_mode() {
  if [ -e "$CMM_ROOT/.git" ]; then
    printf 'git\n'
  elif [ -n "${CMM_BREW_PREFIX:-}" ]; then
    case "$CMM_ROOT" in
      "$CMM_BREW_PREFIX"/*) printf 'brew\n' ;;
      *) printf 'copy\n' ;;
    esac
  else
    printf 'copy\n'
  fi
}

# cmm_brew_token — the formula token of a Homebrew install, from the keg path
# (…/Cellar/<token>/<version>/libexec).
cmm_brew_token() {
  local keg="${CMM_ROOT%/libexec}"
  basename "${keg%/*}"
}

# cmm_stable_launcher — a launcher path that survives upgrades (for launchd):
# the formula's opt/ link for Homebrew installs, the install dir otherwise.
cmm_stable_launcher() {
  local token
  if [ "$(install_mode)" = brew ]; then
    token="$(cmm_brew_token)"
    if [ -x "$CMM_BREW_PREFIX/opt/$token/bin/scrubmac" ]; then
      printf '%s\n' "$CMM_BREW_PREFIX/opt/$token/bin/scrubmac"
      return 0
    fi
    if [ -x "$CMM_BREW_PREFIX/bin/scrubmac" ]; then
      printf '%s\n' "$CMM_BREW_PREFIX/bin/scrubmac"
      return 0
    fi
  fi
  printf '%s\n' "$CMM_ROOT/bin/scrubmac"
}

# cmm_write_file_atomic FILE — write stdin to FILE via a temp file + rename,
# so readers never see a half-written file. A symlinked FILE (a dotfiles
# manager's) is written through: its target is replaced and the link kept.
# Fails with an error message when the directory is not writable.
cmm_write_file_atomic() {
  local f="$1" t tmp hops=0
  while [ -L "$f" ] && [ "$hops" -lt 20 ]; do
    t="$(readlink "$f")" || break
    case "$t" in
      /*) f="$t" ;;
      *) f="$(dirname "$f")/$t" ;;
    esac
    hops=$((hops + 1))
  done
  tmp="$f.tmp.$$"
  if mkdir -p "$(dirname "$f")" 2>/dev/null && { cat >"$tmp"; } 2>/dev/null && mv -f "$tmp" "$f" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null || true
  err "cannot write $f — check that $(dirname "$f") is writable"
  return 1
}

# cmm_require_readable FILE — refuse (exit 2) to rewrite a file that exists
# but cannot be read: rewriting it would silently drop its contents.
cmm_require_readable() {
  if [ -e "$1" ] && { [ ! -r "$1" ] || [ -d "$1" ]; }; then
    err "cannot read $1 — fix its permissions first (nothing was changed)"
    exit 2
  fi
  return 0
}

# ---------- cleaner discovery ----------
# A cleaner's name is its basename without the NN- ordering prefix and .sh
# suffix: cleaners/10-homebrew.sh -> homebrew.
cleaner_name() {
  local b="${1##*/}" pre
  b="${b%.sh}"
  case "$b" in
    [0-9]*-*)
      pre="${b%%-*}"
      case "$pre" in
        *[!0-9]*) ;;
        *) b="${b#*-}" ;;
      esac
      ;;
  esac
  printf '%s\n' "$b"
}

cmm__emit_dir() {
  local d="$1" src="$2" f name
  [ -d "$d" ] || return 0
  for f in "$d"/*.sh; do
    [ -e "$f" ] || continue # unmatched glob (or a dangling link)
    if [ ! -f "$f" ] || [ ! -x "$f" ]; then
      continue
    fi
    name="$(cleaner_name "$f")"
    case "$name" in
      '' | *[!A-Za-z0-9._+@-]*)
        warn "ignoring cleaner with an unusable name: $f"
        continue
        ;;
    esac
    printf '%s\t%s\t%s\t%s\n' "$name" "${f##*/}" "$f" "$src"
  done
}

# cmm_discover — populate CMM_DISCOVERED once per process with one row per
# cleaner, ordered by basename (the NN- prefix):
#   name, basename, path, source, gate, group, default (on|off), summary
# A user cleaner shadows a built-in of the same name. Metadata comes from the
# "# gate:", "# group:", "# default:" and "# summary:" header lines; empty
# values are stored as "-" (bash's read collapses empty tab-separated fields).
cmm_discover() {
  [ -n "${CMM__DISCOVERED_DONE:-}" ] && return 0
  CMM__DISCOVERED_DONE=1
  CMM_DISCOVERED=''
  local rows
  rows="$({
    cmm__emit_dir "$CMM_USER_CLEANERS_DIR" user
    cmm__emit_dir "$CMM_BUILTIN_CLEANERS_DIR" builtin
  } | awk -F '\t' '!seen[$1]++' | sort -t "$TAB" -k2,2)"
  [ -n "$rows" ] || return 0
  CMM_DISCOVERED="$(printf '%s\n' "$rows" | awk -F '\t' '
    {
      path = $3; gate = ""; group = ""; def = "on"; sum = ""; n = 0
      while ((getline line < path) > 0) {
        if (++n > 60) break
        if (line ~ /^# gate: /)         { if (gate == "") gate = substr(line, 9) }
        else if (line ~ /^# group: /)   { if (group == "") group = substr(line, 10) }
        else if (line ~ /^# default: /) { if (substr(line, 12) ~ /^off/) def = "off" }
        else if (line ~ /^# summary: /) { if (sum == "") sum = substr(line, 12) }
      }
      close(path)
      gsub(/\t/, " ", gate); gsub(/\t/, " ", group); gsub(/\t/, " ", sum)
      if (gate == "") gate = "-"
      if (group == "") group = "Other"
      if (sum == "") sum = "-"
      print $1 "\t" $2 "\t" $3 "\t" $4 "\t" gate "\t" group "\t" def "\t" sum
    }')"
}

# cmm_cleaner_field NAME N — field N of NAME's discovery row ('' if unknown).
cmm_cleaner_field() {
  cmm_discover
  printf '%s\n' "$CMM_DISCOVERED" | awk -F '\t' -v n="$1" -v f="$2" '$1 == n { print $f; exit }'
}

known_cleaner() {
  cmm_discover
  printf '%s\n' "$CMM_DISCOVERED" | awk -F '\t' -v n="$1" 'BEGIN { rc = 1 } $1 == n { rc = 0; exit } END { exit rc }'
}

cmm_cleaner_names() {
  cmm_discover
  [ -n "$CMM_DISCOVERED" ] || return 0
  printf '%s\n' "$CMM_DISCOVERED" | awk -F '\t' '{ print $1 }'
}

# cmm_tool_present GATE — "yes" when any gate entry is present, "-" when
# none is, "?" for cleaners without a gate header. Entries are commands, or
# paths ("~/…" or "/…") that count when they exist.
cmm_tool_present() {
  local g gates=()
  [ "$1" = - ] && {
    printf '?\n'
    return 0
  }
  read -r -a gates <<EOF
$1
EOF
  for g in ${gates[@]+"${gates[@]}"}; do
    # shellcheck disable=SC2088  # a literal "~/" prefix in the header
    case "$g" in
      '~/'*) [ -e "$HOME/${g#\~/}" ] || continue ;;
      /*) [ -e "$g" ] || continue ;;
      *) have "$g" || continue ;;
    esac
    printf 'yes\n'
    return 0
  done
  printf -- '-\n'
}

# cmm__split_names ARG… — the names in ARGs split on commas and whitespace,
# one per line, duplicates dropped; never glob-expanded ("--skip '*'" is the
# name "*", which then fails as unknown).
cmm__split_names() {
  local a n seen=' ' IFS=$', \t\n'
  set -f
  for a in "$@"; do
    for n in $a; do
      case "$seen" in *" $n "*) continue ;; esac
      seen="$seen$n "
      printf '%s\n' "$n"
    done
  done
  set +f
}

# ---------- did-you-mean ----------
# cmm_suggest WORD CANDIDATE… — print the closest candidate (edit distance,
# with a swap of two adjacent letters counting as one edit, ≤ max(1,
# len/3)), or nothing. CMM__SUGGEST_MAX=N tightens the limit to N edits.
cmm_suggest() {
  local word="$1"
  shift
  [ "$#" -gt 0 ] || return 0
  printf '%s\n' "$@" | awk -v w="$word" -v max="${CMM__SUGGEST_MAX:-0}" '
    function min3(a, b, c) { m = a; if (b < m) m = b; if (c < m) m = c; return m }
    function dist(s, t,    i, j, ls, lt, d, cost) {
      ls = length(s); lt = length(t)
      for (i = 0; i <= ls; i++) d[i, 0] = i
      for (j = 0; j <= lt; j++) d[0, j] = j
      for (i = 1; i <= ls; i++)
        for (j = 1; j <= lt; j++) {
          cost = (substr(s, i, 1) == substr(t, j, 1)) ? 0 : 1
          d[i, j] = min3(d[i - 1, j] + 1, d[i, j - 1] + 1, d[i - 1, j - 1] + cost)
          if (i > 1 && j > 1 && substr(s, i, 1) == substr(t, j - 1, 1) && substr(s, i - 1, 1) == substr(t, j, 1) && d[i - 2, j - 2] + 1 < d[i, j])
            d[i, j] = d[i - 2, j - 2] + 1
        }
      return d[ls, lt]
    }
    BEGIN { best = ""; bd = 1000 }
    { dd = dist(w, $0); if (dd < bd) { bd = dd; best = $0 } }
    END {
      lim = int(length(w) / 3); if (lim < 1) lim = 1
      if (max > 0) lim = max
      if (best != "" && bd <= lim) print best
    }'
}

CMM_COMMANDS='list doctor status configure enable disable config schedule last update version help run'

# cmm_unknown_cleaner NAME — the standard "unknown cleaner" error (exit 2).
# Commands are offered first, so a tie goes to the command.
cmm_unknown_cleaner() {
  local hint extra=''
  # shellcheck disable=SC2046,SC2086  # names and commands never contain whitespace
  hint="$(cmm_suggest "$1" $CMM_COMMANDS $(cmm_cleaner_names))"
  if [ -f "$CMM_USER_CLEANERS_DIR/$1.sh" ] || ls "$CMM_USER_CLEANERS_DIR"/[0-9]*-"$1".sh >/dev/null 2>&1; then
    extra=" ($CMM_USER_CLEANERS_DIR has a file for it — is it executable? chmod +x it)"
  fi
  if [ -n "$hint" ]; then
    err "unknown cleaner or command '$1' — did you mean '$hint'?$extra (see 'scrubmac list')"
  else
    err "unknown cleaner or command '$1'$extra — see 'scrubmac list' and 'scrubmac help'"
  fi
  exit 2
}

# ---------- enable/disable state ----------
# `disabled` lists cleaners you turned off, `enabled` lists cleaners you
# turned on; anything unlisted follows its header default. Explicit choices
# survive future default changes; new opt-in cleaners stay off.

# Both files start with a "# scrubmac:" header line; names are read with
# comments and surrounding whitespace ignored, so hand edits keep working.
CMM__HDR_OFF="# scrubmac: cleaners you turned off, one per line ('scrubmac enable NAME' removes a line)"
CMM__HDR_ON="# scrubmac: cleaners you turned on, one per line ('scrubmac disable NAME' removes a line)"

# One-time migration from ≤3.0 state, where every cleaner without a line in
# `disabled` ran: docker and xcode absent from it had been opted into, and go
# was on by default — keep all three running for those installs. Only a
# headerless `disabled` (3.0 never wrote the header) with no `enabled` beside
# it is converted, so a lost state dir can't re-run it on 3.1 choices.
cmm_state_migrate() {
  [ -e "$CMM_ENABLED_FILE" ] && return 0
  local marker="$CMM_STATE_DIR/state-v2"
  [ -e "$marker" ] && return 0
  if [ -f "$CMM_DISABLED_FILE" ] && [ -r "$CMM_DISABLED_FILE" ] &&
    ! grep -q '^# scrubmac:' "$CMM_DISABLED_FILE" 2>/dev/null; then
    local n kept=''
    for n in docker xcode go; do
      known_cleaner "$n" || continue
      cmm_listed "$CMM_DISABLED_FILE" "$n" || kept="$kept$n"$'\n'
    done
    {
      printf '%s\n' "$CMM__HDR_ON"
      printf '%s' "$kept"
    } | cmm_write_file_atomic "$CMM_ENABLED_FILE" || return 0
    if [ -n "$kept" ]; then
      printf '%s\n' "(kept your earlier choices enabled: $(printf '%s' "$kept" | tr '\n' ' ')— see 'scrubmac list')" >&2
    fi
  fi
  if mkdir -p "$CMM_STATE_DIR" 2>/dev/null; then
    { : >"$marker"; } 2>/dev/null || true
  fi
  return 0
}

# cmm_state_names FILE — the names listed in a state file, one per line.
cmm_state_names() {
  [ -f "$1" ] || return 0
  awk '{ sub(/#.*/, ""); gsub(/^[ \t]+|[ \t\r]+$/, "") } $0 != "" { print }' "$1" 2>/dev/null || true
}

# cmm_listed FILE NAME — NAME has a line of its own in FILE.
cmm_listed() {
  [ -f "$1" ] || return 1
  awk -v n="$2" '{ sub(/#.*/, ""); gsub(/^[ \t]+|[ \t\r]+$/, "") } $0 == n { f = 1; exit } END { exit !f }' "$1" 2>/dev/null
}

# cmm_require_state_readable — refuse (exit 2) to guess which cleaners are
# on when a state file is there but cannot be read — its permissions, or a
# symlink into a folder this process may not open (launchd jobs cannot read
# ~/Documents, say): falling back to the defaults would silently re-enable
# what you turned off.
cmm_require_state_readable() {
  local f
  for f in "$CMM_DISABLED_FILE" "$CMM_ENABLED_FILE"; do
    [ -e "$f" ] || [ -L "$f" ] || continue
    if [ ! -f "$f" ] || ! { : <"$f"; } 2>/dev/null; then
      err "cannot read $f — refusing to guess which cleaners you turned on or off; fix its permissions (or remove it)"
      exit 2
    fi
  done
  return 0
}

# cmm_is_enabled NAME DEFAULT
cmm_is_enabled() {
  cmm_listed "$CMM_DISABLED_FILE" "$1" && return 1
  cmm_listed "$CMM_ENABLED_FILE" "$1" && return 0
  [ "$2" != off ]
}

# cmm_state_write FILE HEADER NAME… — rewrite a state file so that it lists
# exactly NAME…, keeping what you wrote: comment lines stay where they are,
# a name that stays keeps its own line (inline comment and all, surrounding
# whitespace trimmed), and new names are appended. Fails when the file cannot be written; exits 2 when it
# exists but cannot be read (rewriting it would lose its contents).
cmm_state_write() {
  local f="$1" hdr="$2" src=/dev/null
  shift 2
  cmm_require_readable "$f"
  [ -f "$f" ] && src="$f"
  {
    printf '%s\n' "$hdr"
    awk -v names="$*" '
      BEGIN { n = split(names, want, " "); for (i = 1; i <= n; i++) keep[want[i]] = 1 }
      /^# scrubmac:/ { next }
      /^[ \t]*#/ { sub(/\r$/, ""); print; next }
      { k = $0; sub(/#.*/, "", k); gsub(/^[ \t]+|[ \t\r]+$/, "", k) }
      k == "" || !(k in keep) || done[k]++ { next }
      { gsub(/^[ \t]+|[ \t\r]+$/, ""); print }
      END { for (i = 1; i <= n; i++) if (want[i] != "" && !done[want[i]]++) print want[i] }' "$src"
  } | cmm_write_file_atomic "$f"
}

# cmm__state_rewrite FILE HEADER DROP [ADD] — FILE's names without DROP,
# with ADD (see cmm_state_write: comments are kept).
cmm__state_rewrite() {
  local f="$1" hdr="$2" drop="$3" add="${4:-}" n names=''
  cmm_require_readable "$f"
  while IFS= read -r n; do
    [ -n "$n" ] && [ "$n" != "$drop" ] && names="$names $n"
  done <<EOF
$(cmm_state_names "$f")
EOF
  [ -n "$add" ] && names="$names $add"
  # shellcheck disable=SC2086  # cleaner names never contain whitespace
  cmm_state_write "$f" "$hdr" $names
}

# cmm_set_state NAME on|off — record an explicit choice (exit 2 when the
# state files cannot be written).
cmm_set_state() {
  if [ "$2" = on ]; then
    cmm__state_rewrite "$CMM_DISABLED_FILE" "$CMM__HDR_OFF" "$1" &&
      cmm__state_rewrite "$CMM_ENABLED_FILE" "$CMM__HDR_ON" "$1" "$1"
  else
    cmm__state_rewrite "$CMM_ENABLED_FILE" "$CMM__HDR_ON" "$1" &&
      cmm__state_rewrite "$CMM_DISABLED_FILE" "$CMM__HDR_OFF" "$1" "$1"
  fi || exit 2
}

# ---------- locking ----------
# cmm_pid_is_ours PID — a live process (not us) that is a scrubmac (or
# pre-rename cleanmymac) run. Checking the command line, not just the pid,
# makes locks that outlive a reboot (pid reuse) harmless.
cmm_pid_is_ours() {
  case "${1:-}" in '' | *[!0-9]*) return 1 ;; esac
  [ "$1" != "$$" ] || return 1
  kill -0 "$1" 2>/dev/null || return 1
  local cmd
  cmd="$(ps -p "$1" -o command= 2>/dev/null)" || return 1
  case "$cmd" in
    *scrubmac* | *cleanmymac*) return 0 ;;
  esac
  return 1
}

# cmm_proc_start PID — when the process started, as one word, or nothing
# when that cannot be read; with the pid it identifies a process across pid
# reuse. It must read the same from any run: on Linux the start tick since
# boot (immune to clock steps, which shift ps's computed start time),
# elsewhere ps's start time in UTC and the C locale ("Sat_Oct_4_09:00:01_
# 2026") — never local time, which differs between a launchd job and a shell
# with TZ set.
cmm_proc_start() {
  local s
  if [ -r "/proc/$1/stat" ]; then
    s="$(awk '{ sub(/.*\) /, ""); print $20 }' "/proc/$1/stat" 2>/dev/null)" || s=''
    [ -n "$s" ] && printf 't%s\n' "$s"
    return 0
  fi
  s="$(TZ=UTC0 LC_ALL=C ps -o lstart= -p "$1" 2>/dev/null)" || s=''
  s="$(printf '%s' "$s" | tr -s ' \t\n' '___')"
  s="${s#_}"
  printf '%s\n' "${s%_}"
}

# cmm_lock_holder_alive TARGET — the run lock's target ("PID:START") names a
# live process: same pid, same start time. A holder whose start time cannot
# be read counts as alive (never break a lock on a guess).
cmm_lock_holder_alive() {
  local pid="${1%%:*}" start now
  case "$1" in
    *:*) start="${1#*:}" ;;
    *)
      cmm_pid_is_ours "$1" # pre-release locks held a bare pid
      return
      ;;
  esac
  case "$pid" in '' | *[!0-9]*) return 1 ;; esac
  [ "$pid" != "$$" ] || return 1 # our own pid in a lock we never took: a previous boot's
  kill -0 "$pid" 2>/dev/null || return 1
  [ -n "$start" ] || return 0
  now="$(cmm_proc_start "$pid")"
  [ -z "$now" ] || [ "$now" = "$start" ]
}

# The run lock is a symlink whose target identifies the holder ("PID:START"):
# creating it is a single atomic syscall that fails when the lock exists, and
# the content arrives with it. A stale lock is broken by one run at a time
# (a mkdir mutex), which re-reads it first, so a lock that a racing run just
# created is never removed; then every contender races to create it again,
# and exactly one wins.
cmm_lock_acquire() {
  local held again me
  if ! mkdir -p "$CMM_STATE_DIR" 2>/dev/null || [ ! -w "$CMM_STATE_DIR" ]; then
    err "cannot write to $CMM_STATE_DIR (the run lock and logs live there) — check its ownership and permissions"
    exit 2
  fi
  me="$$:$(cmm_proc_start "$$")"
  # (ln -s into an existing directory would create the link INSIDE it and
  # report success; -n keeps a symlink to a directory from being followed)
  if [ -d "$CMM_LOCK" ] && [ ! -L "$CMM_LOCK" ]; then
    err "$CMM_LOCK is not a scrubmac lock (expected a symlink) — remove it"
    exit 2
  fi
  if ln -sn "$me" "$CMM_LOCK" 2>/dev/null; then
    CMM__LOCK_HELD="$me"
    return 0
  fi
  if [ ! -L "$CMM_LOCK" ]; then
    if [ -e "$CMM_LOCK" ]; then
      err "$CMM_LOCK is not a scrubmac lock (expected a symlink) — remove it"
    else
      err "cannot create the run lock $CMM_LOCK"
    fi
    exit 2
  fi
  held="$(readlink "$CMM_LOCK" 2>/dev/null || true)"
  if cmm_lock_holder_alive "$held"; then
    err "another scrubmac run is already in progress (pid ${held%%:*})"
    exit 2
  fi
  # Break the stale lock by moving it aside, then look at what moved: when
  # a run raced in and took the lock since the check above, it is that run's
  # lock that moved — put back, never removed. (Only one mover can win a
  # given lock, so two runs breaking the same stale lock cannot both pass.)
  if mv "$CMM_LOCK" "$CMM_LOCK.stale.$$" 2>/dev/null; then
    again="$(readlink "$CMM_LOCK.stale.$$" 2>/dev/null || true)"
    if [ -n "$again" ] && [ "$again" != "$held" ]; then
      ln -sn "$again" "$CMM_LOCK" 2>/dev/null || true
    else
      warn "removed a stale lock left by pid ${held%%:*}"
    fi
    rm -f "$CMM_LOCK.stale.$$"
  fi
  if ln -sn "$me" "$CMM_LOCK" 2>/dev/null; then
    CMM__LOCK_HELD="$me"
    return 0
  fi
  held="$(readlink "$CMM_LOCK" 2>/dev/null || true)"
  err "another scrubmac run is already in progress (pid ${held%%:*})"
  exit 2
}

# Transitional (remove in v4 with the cleanmymac shim): also hold the
# pre-rename lock — a mkdir lock in TMPDIR, exactly as 2.x takes it — so a
# not-yet-migrated cleanmymac 2.x copy (e.g. an untouched cron install) and
# scrubmac still exclude each other. Best effort: a lock dir we don't own
# (someone else's, in a shared /tmp) is ignored, never fatal — the scrubmac
# lock above already protects this run.
cmm_legacy_lock_acquire() {
  local base lock pid
  base="$(cmm__abs "${TMPDIR:-/tmp}")" # absolute: runs cd to $HOME before releasing it
  base="${base%/}"
  CMM__LEGACY_LOCK=''
  [ -d "$base" ] && [ -w "$base" ] || return 0
  lock="$base/cleanmymac.$(id -u).lock"
  if ! mkdir "$lock" 2>/dev/null; then
    [ -d "$lock" ] && [ ! -L "$lock" ] && [ -O "$lock" ] || return 0
    pid="$(cat "$lock/pid" 2>/dev/null || true)"
    if cmm_pid_is_ours "$pid"; then
      err "a pre-rename cleanmymac run is in progress (pid $pid)"
      exit 2
    fi
    warn "removing a stale legacy lock left by pid ${pid:-unknown}"
    rm -rf "$lock" 2>/dev/null || true
    mkdir "$lock" 2>/dev/null || return 0
  fi
  CMM__LEGACY_LOCK="$lock"
  { printf '%s\n' "$$" >"$lock/pid"; } 2>/dev/null || true
  return 0
}

cmm_locks_release() {
  if [ -n "${CMM__LOCK_HELD:-}" ]; then
    if [ "$(readlink "$CMM_LOCK" 2>/dev/null || true)" = "$CMM__LOCK_HELD" ]; then
      rm -f "$CMM_LOCK" 2>/dev/null || true
    fi
    CMM__LOCK_HELD=''
  fi
  if [ -n "${CMM__LEGACY_LOCK:-}" ]; then
    rm -rf "$CMM__LEGACY_LOCK" 2>/dev/null || true
    CMM__LEGACY_LOCK=''
  fi
  return 0
}

# ---------- processes ----------
# A cleaner that times out, or is running when the run is interrupted, is
# stopped with TERM, given a grace period, then KILLed — together with every
# process it started. Unattended runs without a terminal start each cleaner
# in a process group of its own (bash's monitor mode), so even descendants
# that were orphaned or daemonized are reached with one signal to the group.
# Runs attached to a terminal keep the cleaner in the terminal's foreground
# group (a sudo or git prompt must still be able to read the terminal), and
# fall back to signalling a snapshot of the process tree.
CMM_KILL_GRACE="${CMM__KILL_GRACE:-5}"

# cmm_tree_pids PID — PID and all its descendants, parents first.
cmm_tree_pids() {
  local kid
  printf '%s\n' "$1"
  for kid in $(pgrep -P "$1" 2>/dev/null || true); do
    cmm_tree_pids "$kid"
  done
}

# cmm__alive PGID|- PID… — true while any process in group PGID ("-" for
# none) or any listed PID is still running (zombies count as gone).
cmm__alive() {
  local g="$1" p st
  shift
  if [ "$g" != - ]; then
    ps -A -o pgid=,stat= 2>/dev/null | awk -v g="$g" '$1 == g && $2 !~ /^Z/ { f = 1 } END { exit !f }' && return 0
  fi
  for p in "$@"; do
    st="$(ps -o stat= -p "$p" 2>/dev/null)" || continue
    case "$st" in '' | *Z*) ;; *) return 0 ;; esac
  done
  return 1
}

# cmm_stop_cleaner PID GROUP(0|1) — TERM (and CONT, so stopped processes see
# it), wait up to CMM_KILL_GRACE seconds, then KILL whatever is left.
cmm_stop_cleaner() {
  local pid="$1" group="$2" pids ticks=0 g=-
  if [ "$group" = 1 ]; then
    g="$pid"
    pids=''
    kill -TERM -- "-$pid" 2>/dev/null || true
    kill -CONT -- "-$pid" 2>/dev/null || true
  else
    pids="$(cmm_tree_pids "$pid")"
    # shellcheck disable=SC2086  # a list of pids
    kill -TERM $pids 2>/dev/null || true
    # shellcheck disable=SC2086
    kill -CONT $pids 2>/dev/null || true
  fi
  # shellcheck disable=SC2086
  while cmm__alive "$g" $pids; do
    [ "$ticks" -lt $((CMM_KILL_GRACE * 10)) ] || break
    sleep 0.1
    ticks=$((ticks + 1))
  done
  if [ "$group" = 1 ]; then
    kill -KILL -- "-$pid" 2>/dev/null || true
  else
    # shellcheck disable=SC2086,SC2046  # pids, plus any started during the grace
    kill -KILL $pids $(cmm_tree_pids "$pid" | sed 1d) 2>/dev/null || true
  fi
  return 0
}

# ---------- environment probes ----------
# cmm_detect_offline — CMM_OFFLINE=1 when the machine has no default network
# route (no traffic is sent: scrubmac makes no network calls of its own).
# CMM_OFFLINE=0/1 in the environment overrides the probe.
cmm_detect_offline() {
  case "${CMM__USER_OFFLINE:-}" in
    0 | 1)
      CMM_OFFLINE="$CMM__USER_OFFLINE"
      return 0
      ;;
  esac
  CMM_OFFLINE=0
  # shellcheck disable=SC2153  # CMM_OS is set by lib/common.sh
  case "$CMM_OS" in
    Darwin)
      # `route get` exits 0 even without a route; it prints the route's
      # gateway/interface when one exists, and only a warning otherwise.
      if have route; then
        local r4 r6
        r4="$(route -n get default 2>/dev/null || true)"
        r6="$(route -n get -inet6 default 2>/dev/null || true)"
        case "$r4$r6" in
          *interface:* | *gateway:*) ;;
          *) CMM_OFFLINE=1 ;;
        esac
      fi
      ;;
    Linux)
      if have ip; then
        local v4 v6
        v4="$(ip route show default 2>/dev/null || true)"
        v6="$(ip -6 route show default 2>/dev/null || true)"
        if [ -z "$v4" ] && [ -z "$v6" ]; then
          CMM_OFFLINE=1
        fi
      fi
      ;;
  esac
  return 0
}

# cmm_on_battery — true when running on battery power.
cmm_on_battery() {
  local out f found=0
  case "$CMM_OS" in
    Darwin)
      have pmset || return 1
      out="$(pmset -g batt 2>/dev/null)" || return 1
      case "${out%%$'\n'*}" in
        *"'Battery Power'"*) return 0 ;;
      esac
      return 1
      ;;
    Linux)
      for f in /sys/class/power_supply/*/online; do
        [ -r "$f" ] || continue
        found=1
        [ "$(cat "$f" 2>/dev/null)" = 1 ] && return 1
      done
      [ "$found" = 1 ]
      ;;
    *) return 1 ;;
  esac
}

# ---------- notifications ----------
# cmm_notify TITLE MESSAGE — a macOS notification via osascript; the text is
# passed as argv to the script, never spliced into AppleScript source.
cmm_notify() {
  have osascript || return 0
  osascript - "$1" "$2" >/dev/null 2>&1 <<'EOF' || true
on run argv
  display notification (item 2 of argv) with title (item 1 of argv)
end run
EOF
}

# ---------- time formatting ----------
cmm_human_secs() {
  local s="${1:-0}"
  if [ "$s" -lt 60 ]; then
    printf '%ss' "$s"
  elif [ "$s" -lt 3600 ]; then
    printf '%dm%02ds' $((s / 60)) $((s % 60))
  else
    printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
  fi
}

# ---------- the run loop ----------
# Result arrays are globals so the interrupt handler can print a partial
# summary. Indexed access only (bash 3.2 + set -u safe).
R_NAMES=()
R_STATUS=()
R_SECS=()
R_RC=()
R_SRC=()
R_NOTES=()
R_FREED=()
R_CACHE=()
CMM_TMP=''
CMM_LOG_FILE=''
CMM__CUR_PID=''
CMM__CUR_EXITED=0
CMM__WD_PID=''
CMM__CUR_NAME=''
CMM__SKIPPED=''
CMM__CUR_SRC=''
CMM__CUR_START=0
CMM__RUN_STARTED=''
CMM__RUN_START_EPOCH=0
CMM__RUN_START_SECS=0
CMM__INTERRUPTED=0
CMM__GROUP=0
CMM__LEFTOVERS=0
CMM__SNAP=''

cmm_log() {
  [ -n "$CMM_LOG_FILE" ] || return 0
  { printf '%s\n' "$*" >>"$CMM_LOG_FILE"; } 2>/dev/null || true
}

# cmm__mk_tmp — the per-run scratch dir: $TMPDIR, else /tmp, else the state
# dir (a TMPDIR that does not exist must not abort an unattended run).
cmm__mk_tmp() {
  local d
  for d in "${TMPDIR:-}" /tmp "$CMM_STATE_DIR"; do
    [ -n "$d" ] && [ -d "$d" ] && [ -w "$d" ] || continue
    CMM_TMP="$(mktemp -d "${d%/}/scrubmac.run.XXXXXX" 2>/dev/null)" && [ -n "$CMM_TMP" ] &&
      CMM_TMP="$(cd "$CMM_TMP" && pwd -P)" && return 0
  done
  CMM_TMP=''
  err "cannot create a temporary directory (tried \$TMPDIR, /tmp and $CMM_STATE_DIR)"
  return 1
}

# cmm__snapshot_lib — copy lib/ into the run's scratch dir and point CMM_LIB
# at the copy. Built-in cleaners are copied there too (cmm__snapshot_cleaner)
# and run from the copies: the homebrew cleaner can upgrade scrubmac itself
# mid-run, and Homebrew then deletes the old keg — files a later cleaner
# would still need.
cmm__snapshot_lib() {
  CMM__SNAP=''
  if mkdir -p "$CMM_TMP/snapshot/cleaners" 2>/dev/null &&
    cp -pR "$CMM_ROOT/lib" "$CMM_TMP/snapshot/lib" 2>/dev/null; then
    CMM__SNAP="$CMM_TMP/snapshot"
    CMM_LIB="$CMM__SNAP/lib/common.sh"
    export CMM_LIB
  else
    warn "could not copy scrubmac's own files for this run — running them in place"
  fi
  return 0
}

# cmm__snapshot_cleaner PATH — print the path to run PATH from: a private
# copy (made after the safety check), or PATH itself when there is no
# snapshot. Prints nothing when PATH is missing or refused.
cmm__snapshot_cleaner() {
  local path="$1" copy
  [ -e "$path" ] || [ -L "$path" ] || return 0
  assert_safe_to_execute "$path" || return 0
  if [ -z "$CMM__SNAP" ]; then
    printf '%s\n' "$path"
    return 0
  fi
  copy="$CMM__SNAP/cleaners/${path##*/}"
  if cp -p "$path" "$copy" 2>/dev/null; then
    printf '%s\n' "$copy"
  else
    printf '%s\n' "$path"
  fi
}

# cmm__watchdog_fire PID GROUP MARKER — the TIMEOUT watchdog's deadline: a
# cleaner still running is marked (MARKER) and stopped; one that finished
# right at the deadline is not a timeout and is left alone. Once marked, the
# stop ignores TERM: it must run through to the KILL stage.
cmm__watchdog_fire() {
  cmm__alive - "$1" || return 0
  : >"$3"
  trap '' TERM
  cmm_stop_cleaner "$1" "$2"
}

# cmm__exec_cleaner PATH NAME — run one cleaner as a child process with stdin
# from /dev/null (a cleaner must never read the dispatcher's input or wait for
# a prompt answer), fd 3 closed (it carries --json output, and a daemon that
# inherited it would hold a consumer's pipe open), output routed per
# CMM__OUTMODE, and the TIMEOUT watchdog. Sets CMM__RC and CMM__TIMED_OUT.
cmm__exec_cleaner() {
  local path="$1" name="$2" i=0
  local out="$CMM_TMP/$name.out" tomark="$CMM_TMP/$name.timeout"
  rm -f "${out:?}" "${out:?}.done" "${tomark:?}"
  CMM__LEFTOVERS=0
  CMM__CUR_EXITED=0
  # tee is started by the dispatcher, on fd 9, before the cleaner exists: as
  # the cleaner's own process substitution it would be the cleaner's child
  # (bash forks before it expands redirections), stopped along with it.
  if [ "$CMM__OUTMODE" = tee ]; then
    exec 9> >(
      exec 3>&-
      tee "$out"
      # (a daemon the cleaner left behind can keep tee alive past the run)
      { : >"$out.done"; } 2>/dev/null
    )
  fi
  [ "$CMM__GROUP" = 1 ] && set -m # its own process group (see cmm_stop_cleaner)
  case "$CMM__OUTMODE" in
    direct) "$path" </dev/null 3>&- 9>&- & ;;
    capture) "$path" </dev/null >"$out" 2>&1 3>&- 9>&- & ;;
    *) "$path" </dev/null >&9 2>&1 3>&- 9>&- & ;;
  esac
  CMM__CUR_PID=$!
  set +m
  [ "$CMM__OUTMODE" = tee ] && exec 9>&-
  CMM__WD_PID=''
  if [ "${CMM_TIMEOUT:-0}" -gt 0 ]; then
    # The watchdog sleeps in the background and waits on it, so a TERM from
    # the dispatcher (cleaner done) interrupts the wait at once and the trap
    # takes its sleep down with it. Once the time is up it writes the marker
    # and then ignores TERM: the stop must run through to the KILL stage.
    (
      trap 'kill $(jobs -p) 2>/dev/null; exit 0' TERM
      sleep "$CMM_TIMEOUT" &
      wait $!
      cmm__watchdog_fire "$CMM__CUR_PID" "$CMM__GROUP" "$tomark"
    ) </dev/null >/dev/null 2>&1 3>&- 9>&- &
    CMM__WD_PID=$!
  fi
  CMM__RC=0
  wait "$CMM__CUR_PID" 2>/dev/null || CMM__RC=$?
  CMM__CUR_EXITED=1 # (an interrupt from here on must not call it "stopped")
  if [ -n "$CMM__WD_PID" ]; then
    # timed out: let the watchdog finish the stop instead of cutting it short
    [ -e "$tomark" ] || kill -TERM "$CMM__WD_PID" 2>/dev/null || true
    wait "$CMM__WD_PID" 2>/dev/null || true
  fi
  # In its own process group, what a cleaner leaves running would escape
  # launchd's end-of-job cleanup (launchd stops only the job's own group):
  # stop it here, as launchd would have.
  if [ "$CMM__GROUP" = 1 ] && [ ! -e "$tomark" ] && cmm__alive "$CMM__CUR_PID"; then
    CMM__LEFTOVERS=1
    cmm_stop_cleaner "$CMM__CUR_PID" 1
  fi
  if [ "$CMM__OUTMODE" = tee ]; then
    # tee exits once every writer is gone; give it a moment to flush
    while [ ! -e "$out.done" ] && [ "$i" -lt 20 ]; do
      sleep 0.1
      i=$((i + 1))
    done
  fi
  CMM__CUR_PID=''
  CMM__WD_PID=''
  CMM__CUR_EXITED=0
  CMM__TIMED_OUT=0
  [ -e "$tomark" ] && CMM__TIMED_OUT=1
  return 0
}

# cmm__read_report FILE — sets CMM__NOTES, CMM__SKIPMSG, CMM__FREED,
# CMM__CACHE from a cleaner's report lines.
cmm__read_report() {
  local k v
  CMM__NOTES=''
  CMM__SKIPMSG=''
  CMM__FREED=''
  CMM__CACHE=''
  [ -f "$1" ] || return 0
  while IFS="$TAB" read -r k v; do
    case "$k" in
      note) [ -n "$v" ] && CMM__NOTES="$CMM__NOTES$v$CMM_US" ;;
      skip) CMM__SKIPMSG="$v" ;;
      freed_kb)
        case "$v" in '' | *[!0-9]*) ;; *) CMM__FREED="$v" ;; esac
        ;;
      cache_kb)
        case "$v" in '' | *[!0-9]*) ;; *) CMM__CACHE=$((${CMM__CACHE:-0} + v)) ;; esac
        ;;
    esac
  done <"$1"
  return 0
}

# cmm__next_note — pop the first note off $notes into $note (callers'
# locals); notes are joined by CMM_US, the last one with or without it.
cmm__next_note() {
  case "$notes" in
    *"$CMM_US"*)
      note="${notes%%"$CMM_US"*}"
      notes="${notes#*"$CMM_US"}"
      ;;
    *)
      note="$notes"
      notes=''
      ;;
  esac
}

cmm__record() { # cmm__record NAME STATUS SECS RC SRC NOTES FREED CACHE
  R_NAMES+=("$1")
  R_STATUS+=("$2")
  R_SECS+=("$3")
  R_RC+=("$4")
  R_SRC+=("$5")
  R_NOTES+=("$6")
  R_FREED+=("$7")
  R_CACHE+=("$8")
}

cmm__counts() { # sets CMM__N_OK, CMM__N_SKIP, CMM__N_FAIL, CMM__N_FREED_SUM
  local i=0
  CMM__N_OK=0
  CMM__N_SKIP=0
  CMM__N_FAIL=0
  CMM__N_FREED_SUM=''
  while [ "$i" -lt "${#R_NAMES[@]}" ]; do
    case "${R_STATUS[$i]}" in
      ok) CMM__N_OK=$((CMM__N_OK + 1)) ;;
      skip) CMM__N_SKIP=$((CMM__N_SKIP + 1)) ;;
      *) CMM__N_FAIL=$((CMM__N_FAIL + 1)) ;;
    esac
    if [ -n "${R_FREED[$i]}" ]; then
      CMM__N_FREED_SUM=$((${CMM__N_FREED_SUM:-0} + ${R_FREED[$i]}))
    fi
    i=$((i + 1))
  done
}

# cmm__label STATUS — sets CMM__LABEL and CMM__COLOR for a result status.
cmm__label() {
  case "$1" in
    ok) CMM__LABEL=ok CMM__COLOR="$CMM_GREEN" ;;
    skip) CMM__LABEL=skip CMM__COLOR="$CMM_DIM" ;;
    timeout) CMM__LABEL=TIMEOUT CMM__COLOR="$CMM_RED" ;;
    refused) CMM__LABEL=REFUSED CMM__COLOR="$CMM_RED" ;;
    stopped) CMM__LABEL=STOPPED CMM__COLOR="$CMM_YELLOW" ;;
    *) CMM__LABEL=FAIL CMM__COLOR="$CMM_RED" ;;
  esac
}

# print_summary [plain] — the per-cleaner table. "plain" drops colors (logs).
print_summary() {
  [ "${#R_NAMES[@]}" -eq 0 ] && return 0
  local plain="${1:-}" i=0 color reset freed note notes c_dim="$CMM_DIM" c_rst="$CMM_RESET"
  if [ -n "$plain" ]; then
    c_dim='' c_rst=''
    printf '\nSummary\n=======\n'
  else
    banner "Summary"
  fi
  while [ "$i" -lt "${#R_NAMES[@]}" ]; do
    cmm__label "${R_STATUS[$i]}"
    color="$CMM__COLOR"
    reset="$CMM_RESET"
    [ -n "$plain" ] && color='' reset=''
    freed=''
    if [ -n "${R_FREED[$i]}" ]; then
      freed="  freed $(cmm_human_kb "${R_FREED[$i]}")"
    fi
    printf '  %s%-7s%s %-16s %6s%s\n' "$color" "$CMM__LABEL" "$reset" "${R_NAMES[$i]}" "$(cmm_human_secs "${R_SECS[$i]}")" "$freed"
    if [ "${R_STATUS[$i]}" != skip ] && [ -n "${R_NOTES[$i]}" ]; then
      notes="${R_NOTES[$i]}"
      while [ -n "$notes" ]; do
        cmm__next_note
        printf '          %s· %s%s\n' "$c_dim" "$note" "$c_rst"
      done
    fi
    i=$((i + 1))
  done
  cmm__counts
  printf '\n%s ok, %s skipped, %s failed — %s\n' "$CMM__N_OK" "$CMM__N_SKIP" "$CMM__N_FAIL" \
    "$(cmm_human_secs $((SECONDS - CMM__RUN_START_SECS)))"
}

# cmm__json_run EXIT_CODE FREED_KB — the machine-readable record of a run.
cmm__json_run() {
  local rc="$1" freed="${2:-}" i=0 sep='' notes note nsep
  cmm__counts
  printf '{\n'
  printf '  "version": %s,\n' "$(cmm_json_str "$CMM_VERSION")"
  printf '  "started_at": %s,\n' "$(cmm_json_str "$CMM__RUN_STARTED")"
  printf '  "finished_at": %s,\n' "$(cmm_json_str "$(cmm_now_iso)")"
  printf '  "duration_seconds": %s,\n' "$((SECONDS - CMM__RUN_START_SECS))"
  printf '  "mode": %s,\n' "$(cmm_json_str "$CMM_MODE")"
  printf '  "dry_run": %s,\n' "$([ "$CMM_DRY_RUN" = 1 ] && echo true || echo false)"
  printf '  "scheduled": %s,\n' "$([ "${CMM_SCHEDULED:-0}" = 1 ] && echo true || echo false)"
  printf '  "interactive": %s,\n' "$([ "${CMM_INTERACTIVE:-0}" = 1 ] && echo true || echo false)"
  printf '  "offline": %s,\n' "$([ "${CMM_OFFLINE:-0}" = 1 ] && echo true || echo false)"
  printf '  "interrupted": %s,\n' "$([ "$CMM__INTERRUPTED" = 1 ] && echo true || echo false)"
  if [ -n "$CMM__SKIPPED" ]; then
    printf '  "skipped": %s,\n' "$(cmm_json_str "$CMM__SKIPPED")"
  else
    printf '  "skipped": null,\n'
  fi
  printf '  "exit_code": %s,\n' "$rc"
  printf '  "totals": {"ok": %s, "skipped": %s, "failed": %s},\n' "$CMM__N_OK" "$CMM__N_SKIP" "$CMM__N_FAIL"
  printf '  "disk_freed_kb": %s,\n' "${freed:-null}"
  if [ -n "$CMM_LOG_FILE" ]; then
    printf '  "log_file": %s,\n' "$(cmm_json_str "$CMM_LOG_FILE")"
  else
    printf '  "log_file": null,\n'
  fi
  printf '  "cleaners": ['
  while [ "$i" -lt "${#R_NAMES[@]}" ]; do
    printf '%s\n    {"name": %s, "status": %s, "exit_code": %s, "seconds": %s, "source": %s, "freed_kb": %s, "cache_kb": %s, "notes": [' \
      "$sep" "$(cmm_json_str "${R_NAMES[$i]}")" "$(cmm_json_str "${R_STATUS[$i]}")" \
      "${R_RC[$i]:-null}" "${R_SECS[$i]}" "$(cmm_json_str "${R_SRC[$i]}")" \
      "${R_FREED[$i]:-null}" "${R_CACHE[$i]:-null}"
    notes="${R_NOTES[$i]}"
    nsep=''
    while [ -n "$notes" ]; do
      cmm__next_note
      printf '%s%s' "$nsep" "$(cmm_json_str "$note")"
      nsep=', '
    done
    printf ']}'
    sep=','
    i=$((i + 1))
  done
  [ -n "$sep" ] && printf '\n  '
  printf ']\n}\n'
}

# cmm__log_files — run-log basenames, newest first (names embed a UTC
# timestamp, so a reverse lexical sort is chronological).
cmm__log_files() {
  local f
  [ -d "$CMM_LOG_DIR" ] || return 0
  for f in "$CMM_LOG_DIR"/run-*.log; do
    [ -f "$f" ] || continue
    f="${f##*/}"
    case "$f" in
      run-*[!0-9TZ-]*.log) ;;
      *) printf '%s\n' "$f" ;;
    esac
  done | sort -r
}

# cmm__rotate_logs — keep the newest LOG_KEEP logs (at least one: the run
# that just finished points at its own log).
cmm__rotate_logs() {
  local keep="${CMM_LOG_KEEP:-20}" f n=0 cur=''
  [ "$keep" -ge 1 ] 2>/dev/null || keep=1
  # this run's own log always stays, and counts as one: after a clock change
  # older logs can carry "newer" names
  if [ -n "${CMM_LOG_FILE:-}" ] && [ -f "$CMM_LOG_FILE" ]; then
    cur="${CMM_LOG_FILE##*/}"
    n=1
  fi
  for f in $(cmm__log_files); do
    [ "$f" = "$cur" ] && continue
    n=$((n + 1))
    [ "$n" -gt "$keep" ] && rm -f "${CMM_LOG_DIR:?}/${f:?}"
  done
  return 0
}

# cmm__df_free — free KB on $HOME's filesystem, or nothing. -P: one line per
# filesystem even when the device name is long (GNU df wraps otherwise).
cmm__df_free() {
  local kb
  kb="$(df -Pk "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
  case "$kb" in '' | *[!0-9]*) ;; *) printf '%s\n' "$kb" ;; esac
  return 0
}

cmm__open_log() {
  CMM_LOG_FILE=''
  if mkdir -p "$CMM_LOG_DIR" 2>/dev/null; then
    CMM_LOG_FILE="$CMM_LOG_DIR/run-$(date -u '+%Y%m%dT%H%M%SZ')-$$.log"
    if { : >"$CMM_LOG_FILE"; } 2>/dev/null; then
      return 0
    fi
  fi
  CMM_LOG_FILE=''
  warn "cannot write run logs to $CMM_LOG_DIR — this run is not logged"
  return 0
}

# cmm__finish_run EXIT_CODE — summary, disk delta, logs, JSON, notification.
# What it prints goes through subshells (see cmm__on_int): the run record
# and the log must still be written when the terminal is gone.
cmm__finish_run() {
  local rc="$1" freed='' df_after
  cmm__counts
  if [ "${#R_NAMES[@]}" -eq 0 ] && [ "$CMM__INTERRUPTED" != 1 ]; then
    (note "nothing to run — every cleaner is disabled or left out ('scrubmac list' shows them)") || true
  fi
  (print_summary) || true
  if [ -n "${CMM__DF_BEFORE:-}" ] && [ "$CMM_DRY_RUN" != 1 ] && [ "$CMM_MODE" != status ]; then
    df_after="$(cmm__df_free)"
    # other processes move free space too: below 1 MB the delta is noise
    if [ -n "$df_after" ] && [ "$df_after" -ge $((CMM__DF_BEFORE + 1024)) ]; then
      freed=$((df_after - CMM__DF_BEFORE))
      (note "approx. disk space freed: $(cmm_human_kb "$freed")") || true
    fi
  fi
  if [ -n "${CMM__N_FREED_SUM:-}" ]; then
    (note "measured by cleaners: $(cmm_human_kb "$CMM__N_FREED_SUM") freed") || true
  fi
  if [ "${#R_NAMES[@]}" -ge 3 ] && [ "$CMM__N_OK" -eq 0 ] && [ "$CMM__N_FAIL" -eq 0 ]; then
    (warn "every cleaner skipped — if this was a scheduled run, its PATH may be missing your tools (cron's default PATH is /usr/bin:/bin); run 'scrubmac doctor'") || true
  fi
  if [ -n "$CMM_LOG_FILE" ]; then
    { print_summary plain >>"$CMM_LOG_FILE"; } 2>/dev/null || true
    [ -n "$freed" ] && cmm_log "approx. disk space freed: $(cmm_human_kb "$freed")"
    cmm_log "exit $rc"
    (note "log: $CMM_LOG_FILE") || true
  fi
  if [ "$CMM_DRY_RUN" != 1 ] && [ "$CMM_MODE" != status ]; then
    cmm__json_run "$rc" "$freed" | cmm_write_file_atomic "$CMM_LAST_RUN_FILE" || true
    # MIN_HOURS_BETWEEN_RUNS counts from the start of the last clean, full,
    # online run in which something actually ran.
    if [ "$rc" -eq 0 ] && [ "$CMM__FULL_RUN" = 1 ] && [ "$CMM_MODE" = run ] &&
      [ "${CMM_OFFLINE:-0}" != 1 ] && [ "$CMM__N_OK" -gt 0 ]; then
      printf '%s\n' "$CMM__RUN_START_EPOCH" | cmm_write_file_atomic "$CMM_LAST_SUCCESS_FILE" || true
    fi
    cmm__rotate_logs
  fi
  if [ "$CMM_JSON" = 1 ]; then
    cmm__json_run "$rc" "$freed" >&3
  fi
  if [ "${CMM_INTERACTIVE:-0}" != 1 ] && [ "$CMM_DRY_RUN" != 1 ] && [ "$CMM_MODE" != status ]; then
    local failed_names='' i=0
    while [ "$i" -lt "${#R_NAMES[@]}" ]; do
      case "${R_STATUS[$i]}" in
        ok | skip) ;;
        *) failed_names="$failed_names ${R_NAMES[$i]}" ;;
      esac
      i=$((i + 1))
    done
    case "${CMM_NOTIFY:-failures}" in
      always)
        cmm_notify scrubmac "$CMM__N_OK ok, $CMM__N_SKIP skipped, $CMM__N_FAIL failed${failed_names:+ —$failed_names}"
        ;;
      failures)
        [ -n "$failed_names" ] && cmm_notify "scrubmac: $CMM__N_FAIL failed" "Failed:$failed_names — run 'scrubmac last' for details"
        ;;
    esac
  fi
  return 0
}

# The interrupt handler must finish whatever happens around it: a second
# Ctrl-C during the stop, a closed terminal (writes fail with EIO), a pipe
# reader that is gone (EPIPE). So further signals are ignored, errexit is
# off, and everything printed goes through subshells — a failed write then
# leaves nothing stuck in this shell's output buffer.
cmm__on_int() {
  trap '' INT TERM HUP PIPE
  set +e
  local st
  CMM__INTERRUPTED=1
  # stop the watchdog first, so it cannot fire while we stop the cleaner
  if [ -n "$CMM__WD_PID" ]; then
    kill -TERM "$CMM__WD_PID" 2>/dev/null
  fi
  (
    echo
    warn "interrupted — stopping ${CMM__CUR_NAME:-the run}; partial summary follows"
  )
  if [ -n "$CMM__CUR_PID" ]; then
    cmm_stop_cleaner "$CMM__CUR_PID" "$CMM__GROUP"
    # reap it, so bash prints no "Terminated" job notice later (only when it
    # is gone: a process stuck in the kernel would hang the wait)
    cmm__alive - "$CMM__CUR_PID" || wait "$CMM__CUR_PID" 2>/dev/null
  fi
  # (unless the signal came just after it was recorded)
  if [ -n "$CMM__CUR_NAME" ] && { [ "${#R_NAMES[@]}" -eq 0 ] || [ "${R_NAMES[$((${#R_NAMES[@]} - 1))]}" != "$CMM__CUR_NAME" ]; }; then
    if [ "$CMM__CUR_EXITED" = 1 ]; then
      # it had already finished (the signal came while what it left running
      # was being stopped): its own result stands
      cmm__read_report "$CMM_TMP/$CMM__CUR_NAME.report"
      if [ -e "$CMM_TMP/$CMM__CUR_NAME.timeout" ]; then
        st=timeout
      elif [ "$CMM__RC" -eq 0 ]; then
        st=ok
      elif [ "$CMM__RC" -eq "$CMM_EXIT_SKIP" ]; then
        st=skip
        [ -n "$CMM__SKIPMSG" ] && CMM__NOTES="$CMM__SKIPMSG$CMM_US$CMM__NOTES"
      else
        st=fail
      fi
      cmm__record "$CMM__CUR_NAME" "$st" $((SECONDS - CMM__CUR_START)) "$CMM__RC" "$CMM__CUR_SRC" "$CMM__NOTES" "$CMM__FREED" "$CMM__CACHE"
    else
      cmm__record "$CMM__CUR_NAME" stopped $((SECONDS - CMM__CUR_START)) 130 "$CMM__CUR_SRC" '' '' ''
    fi
    cmm__label "${R_STATUS[$((${#R_STATUS[@]} - 1))]}"
    cmm_log "== $CMM__CUR_NAME: $CMM__LABEL (interrupted)"
    if [ -n "$CMM_LOG_FILE" ] && [ -s "$CMM_TMP/$CMM__CUR_NAME.out" ]; then
      { cat "$CMM_TMP/$CMM__CUR_NAME.out" >>"$CMM_LOG_FILE"; } 2>/dev/null
    fi
  fi
  cmm__finish_run 130
  exit 130
}

# cmm__quiet_line STATUS NAME SECS [DETAIL] — the one line quiet mode prints
# per cleaner, instead of a banner over output it hides.
cmm__quiet_line() {
  cmm__label "$1"
  printf '%s%-7s%s %s (%s)%s\n' "$CMM__COLOR" "$CMM__LABEL" "$CMM_RESET" "$2" "$(cmm_human_secs "$3")" "${4:+ — $4}"
}

# cmm_run_cleaners NAME… — the run loop shared by `scrubmac` (run, update,
# clean modes) and `scrubmac status`. With names, exactly those cleaners run
# (even disabled ones); without, every enabled cleaner. CMM_SKIP_NAMES drops
# cleaners either way.
cmm_run_cleaners() {
  local sel=" $* " name path src def run_path i=0 n
  local status secs sel_names=() sel_paths=() sel_srcs=() sel_runs=()

  cmm__mk_tmp || exit 2
  CMM__RUN_STARTED="$(cmm_now_iso)"
  CMM__RUN_START_EPOCH="$(date '+%s')"
  CMM__RUN_START_SECS=$SECONDS
  local skips="${CMM_SKIP_NAMES:-}"
  CMM__FULL_RUN=0
  if [ "$#" -eq 0 ] && [ -z "${skips// /}" ]; then
    CMM__FULL_RUN=1
  fi
  # Output routing: stream straight to a terminal (tools keep their TTY
  # behavior); otherwise capture each cleaner's output for the log — and
  # stream it too unless quiet. `status` is a report: it always shows output.
  if [ "$CMM_QUIET" = 1 ] && [ "$CMM_MODE" != status ]; then
    CMM__OUTMODE=capture
  elif [ "${CMM__TTY_OUT:-0}" = 1 ] && [ "$CMM_JSON" != 1 ]; then
    CMM__OUTMODE=direct
  else
    CMM__OUTMODE='tee'
  fi
  # Process groups (see cmm_stop_cleaner): only for runs no terminal can
  # interact with. CMM__PGRP=0|1 forces the choice (tests).
  CMM__GROUP=0
  case "${CMM__PGRP:-auto}" in
    0 | 1) CMM__GROUP="$CMM__PGRP" ;;
    *)
      if [ "${CMM_INTERACTIVE:-0}" != 1 ] && ! (: </dev/tty) 2>/dev/null; then
        CMM__GROUP=1
      fi
      ;;
  esac

  if [ "$CMM_DRY_RUN" != 1 ] && [ "$CMM_MODE" != status ]; then
    cmm__open_log
    CMM__DF_BEFORE="$(cmm__df_free)"
  else
    CMM__DF_BEFORE=''
  fi
  cmm_log "scrubmac $CMM_VERSION — $CMM__RUN_STARTED — mode=$CMM_MODE scheduled=${CMM_SCHEDULED:-0} interactive=${CMM_INTERACTIVE:-0} offline=${CMM_OFFLINE:-0} quiet=$CMM_QUIET"
  cmm_log "PATH=$PATH"

  # Select, then snapshot the built-ins (see cmm__snapshot_lib).
  [ "$#" -gt 0 ] || cmm_require_state_readable
  cmm_discover
  while IFS="$TAB" read -r name _ path src _ _ def _; do
    [ -n "$name" ] || continue
    case " ${CMM_SKIP_NAMES:-} " in *" $name "*) continue ;; esac
    if [ "$#" -gt 0 ]; then
      case "$sel" in
        *" $name "*) ;;
        *) continue ;;
      esac
    else
      cmm_is_enabled "$name" "$def" || continue
    fi
    sel_names+=("$name")
    sel_paths+=("$path")
    sel_srcs+=("$src")
  done <<EOF
$CMM_DISCOVERED
EOF
  n="${#sel_names[@]}"
  cmm__snapshot_lib
  while [ "$i" -lt "$n" ]; do
    run_path=''
    if [ "${sel_srcs[$i]}" = builtin ]; then
      run_path="$(cmm__snapshot_cleaner "${sel_paths[$i]}")"
    fi
    sel_runs+=("${run_path:--}")
    i=$((i + 1))
  done

  # Cleaners start in $HOME whatever directory scrubmac was started from
  # (launchd starts jobs in /, where tools like pnpm try to write). Every
  # path from here on is absolute.
  cd "$HOME" 2>/dev/null || cd /

  trap cmm__on_int INT TERM HUP

  i=0
  while [ "$i" -lt "$n" ]; do
    name="${sel_names[$i]}"
    path="${sel_paths[$i]}"
    src="${sel_srcs[$i]}"
    run_path="${sel_runs[$i]}"
    i=$((i + 1))
    if [ "$src" != builtin ]; then # your own cleaners run in place
      run_path=-
      if [ -e "$path" ] || [ -L "$path" ]; then
        assert_safe_to_execute "$path" && run_path="$path"
      fi
    fi
    if [ "$run_path" = - ]; then
      if [ -e "$path" ] || [ -L "$path" ]; then
        cmm__record "$name" refused 0 '' "$src" "refused by the execution-safety guard (see 'scrubmac doctor')$CMM_US" '' ''
        cmm_log "== $name: REFUSED (execution-safety guard: $path)"
      else
        warn "$name: $path disappeared during the run"
        cmm__record "$name" fail 0 '' "$src" "the cleaner file disappeared during the run$CMM_US" '' ''
        cmm_log "== $name: FAIL ($path disappeared)"
      fi
      continue
    fi

    [ "$CMM__OUTMODE" != capture ] && banner "$name"
    CMM__CUR_NAME="$name"
    CMM__CUR_SRC="$src"
    CMM__CUR_START=$SECONDS
    export CMM_REPORT_FILE="$CMM_TMP/$name.report"
    export CMM_CLEANER_NAME="$name"
    export CMM_SCRATCH_DIR="$CMM_TMP/scratch-$name"
    : >"$CMM_REPORT_FILE"
    mkdir -p "$CMM_SCRATCH_DIR" 2>/dev/null || unset CMM_SCRATCH_DIR
    cmm__exec_cleaner "$run_path" "$name"
    secs=$((SECONDS - CMM__CUR_START))
    cmm__read_report "$CMM_REPORT_FILE"

    if [ "$CMM__LEFTOVERS" = 1 ]; then
      CMM__NOTES="${CMM__NOTES}left processes running after it finished — stopped them$CMM_US"
    fi
    if [ "$CMM__TIMED_OUT" = 1 ]; then
      status=timeout
      CMM__NOTES="stopped after ${CMM_TIMEOUT}s (TIMEOUT)$CMM_US$CMM__NOTES"
    elif [ "$CMM__RC" -eq 0 ]; then
      status=ok
    elif [ "$CMM__RC" -eq "$CMM_EXIT_SKIP" ]; then
      status=skip
      [ -n "$CMM__SKIPMSG" ] && CMM__NOTES="$CMM__SKIPMSG$CMM_US$CMM__NOTES"
    else
      status=fail
    fi

    if [ "$CMM__OUTMODE" = capture ]; then
      case "$status" in
        fail | timeout)
          cmm__quiet_line "$status" "$name" "$secs"
          cat "$CMM_TMP/$name.out" 2>/dev/null || true
          ;;
        skip)
          if [ -z "$CMM__SKIPMSG" ]; then # surface the cleaner's own last line
            CMM__SKIPMSG="$(tail -n 1 "$CMM_TMP/$name.out" 2>/dev/null || true)"
            CMM__SKIPMSG="${CMM__SKIPMSG#- }"
          fi
          cmm__quiet_line skip "$name" "$secs" "$CMM__SKIPMSG"
          ;;
        *) cmm__quiet_line "$status" "$name" "$secs" ;;
      esac
    fi
    case "$status" in
      fail) warn "$name failed (exit $CMM__RC) — continuing with the remaining cleaners" ;;
      timeout) warn "$name exceeded the ${CMM_TIMEOUT}s TIMEOUT and was stopped — continuing" ;;
    esac

    cmm__record "$name" "$status" "$secs" "$CMM__RC" "$src" "$CMM__NOTES" "$CMM__FREED" "$CMM__CACHE"
    CMM__CUR_NAME=''
    cmm__label "$status"
    cmm_log "== $name: $CMM__LABEL (${secs}s, exit $CMM__RC)"
    if [ -n "$CMM_LOG_FILE" ] && [ -s "$CMM_TMP/$name.out" ]; then
      { cat "$CMM_TMP/$name.out" >>"$CMM_LOG_FILE"; } 2>/dev/null || true
    fi
  done

  # Every cleaner is done: a signal now must not cut the summary and the run
  # record short, nor leave them saying one exit code while the process
  # dies with another. (A no-op trap, not an ignored signal: commands run
  # from here — the notification — can still be interrupted themselves.)
  trap : INT TERM HUP
  unset CMM_REPORT_FILE CMM_CLEANER_NAME CMM_SCRATCH_DIR
  cmm__counts
  local rc=0
  [ "$CMM__N_FAIL" -gt 0 ] && rc=1
  if [ "$CMM_MODE" = status ]; then
    cmm__status_table
    [ "$CMM_JSON" = 1 ] && cmm__json_run "$rc" '' >&3
    return "$rc"
  fi
  cmm__finish_run "$rc"
  return "$rc"
}

# cmm__status_table — cache sizes collected by `scrubmac status`.
cmm__status_table() {
  local i=0 total=0 any=0
  banner "Cache sizes"
  while [ "$i" -lt "${#R_NAMES[@]}" ]; do
    if [ -n "${R_CACHE[$i]}" ]; then
      any=1
      printf '  %-16s %10s\n' "${R_NAMES[$i]}" "$(cmm_human_kb "${R_CACHE[$i]}")"
      total=$((total + R_CACHE[i]))
    fi
    i=$((i + 1))
  done
  if [ "$any" -eq 1 ]; then
    printf '  %-16s %10s\n' total "$(cmm_human_kb "$total")"
  else
    note "  (no cache directories reported)"
  fi
}
