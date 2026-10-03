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
APP_UPDATES|interactive|interactive,always,never|GUI app upgrades (Homebrew casks, App Store): interactive = only when you run scrubmac yourself
NOTIFY|failures|failures,always,never|desktop notification after unattended runs
ON_BATTERY|run|run,skip|scheduled runs while on battery power
MIN_HOURS_BETWEEN_RUNS|0|int|scheduled runs skip when a full run succeeded within N hours (0 = off)
LOG_KEEP|20|int|run logs to keep
MEASURE|0|bool|1 = measure the space each cleaner frees (slower: du before/after)
UPDATE_CHANNEL|release|release,branch|what scrubmac update follows on git installs (release tags, or the branch)
DERIVEDDATA_AGE_DAYS|30|int|xcode: purge DerivedData not used for N days
DEVICESUPPORT_AGE_DAYS|90|int|xcode: purge device-support folders older than N days (the newest per platform is kept)
HOMEBREW_DOCTOR|1|bool|homebrew: run the advisory brew doctor
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
  case "$1" in
    int)
      case "$2" in '' | *[!0-9]*) return 1 ;; esac
      [ "${#2}" -le 9 ]
      ;;
    bool)
      case "$2" in 0 | 1) return 0 ;; esac
      return 1
      ;;
    *)
      [ -n "$2" ] || return 1
      case ",$1," in
        *",$2,"*) return 0 ;;
      esac
      return 1
      ;;
  esac
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
      CMM__S_VAL="$v"
      CMM__S_SRC='env'
      return 0
    fi
    cmm__warn_once "env:$key" "ignoring CMM_$key=$v (expected $(cmm_type_hint "$CMM__S_TYPE"))"
  fi
  v="$(config_get "$key" "")"
  if [ -n "$v" ]; then
    if cmm_setting_valid "$CMM__S_TYPE" "$v"; then
      CMM__S_VAL="$v"
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

# ---------- paths ----------
cmm_init_paths() {
  CMM_CONFIG_DIR="$(cmm_config_dir)"
  CMM_CONFIG_FILE="$CMM_CONFIG_DIR/config"
  CMM_DISABLED_FILE="$CMM_CONFIG_DIR/disabled"
  CMM_ENABLED_FILE="$CMM_CONFIG_DIR/enabled"
  CMM_USER_CLEANERS_DIR="$CMM_CONFIG_DIR/cleaners.d"
  CMM_BUILTIN_CLEANERS_DIR="${CMM_CLEANERS_DIR:-$CMM_ROOT/cleaners}"
  # State (logs, last run, the run lock) lives under XDG_STATE_HOME — never
  # under TMPDIR, which differs between cron, launchd and terminal sessions.
  CMM_STATE_DIR="${CMM_STATE_DIR:-${XDG_STATE_HOME:-$HOME/.local/state}/scrubmac}"
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

# cmm_write_file_atomic FILE — write stdin to FILE via a temp file + rename.
cmm_write_file_atomic() {
  local f="$1" tmp
  mkdir -p "$(dirname "$f")"
  tmp="$f.tmp.$$"
  cat >"$tmp"
  mv -f "$tmp" "$f"
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

# cmm_tool_present GATE — "yes" when any gate command is installed, "-" when
# none is, "?" for cleaners without a gate header.
cmm_tool_present() {
  local g
  [ "$1" = - ] && {
    printf '?\n'
    return 0
  }
  for g in $1; do
    if have "$g"; then
      printf 'yes\n'
      return 0
    fi
  done
  printf -- '-\n'
}

# ---------- did-you-mean ----------
# cmm_suggest WORD CANDIDATE… — print the closest candidate (edit distance,
# with a swap of two adjacent letters counting as one edit, ≤ max(1,
# len/3)), or nothing.
cmm_suggest() {
  local word="$1"
  shift
  [ "$#" -gt 0 ] || return 0
  printf '%s\n' "$@" | awk -v w="$word" '
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
      if (best != "" && bd <= lim) print best
    }'
}

# cmm_unknown_cleaner NAME — the standard "unknown cleaner" error (exit 2).
cmm_unknown_cleaner() {
  local hint
  # shellcheck disable=SC2046  # cleaner names never contain whitespace
  hint="$(cmm_suggest "$1" $(cmm_cleaner_names) list doctor status configure enable disable config schedule last update version help)"
  if [ -n "$hint" ]; then
    err "unknown cleaner or command '$1' — did you mean '$hint'? (see 'scrubmac list')"
  else
    err "unknown cleaner or command '$1' — see 'scrubmac list' and 'scrubmac help'"
  fi
  exit 2
}

# ---------- enable/disable state ----------
# `disabled` lists cleaners you turned off, `enabled` lists cleaners you
# turned on; anything unlisted follows its header default. Explicit choices
# survive future default changes; new opt-in cleaners stay off.

# One-time migration from ≤3.0 state, where every cleaner without a line in
# `disabled` ran: docker and xcode absent from it had been opted into, and go
# was on by default — keep all three running for those installs.
cmm_state_migrate() {
  [ -e "$CMM_ENABLED_FILE" ] && return 0
  local marker="$CMM_STATE_DIR/state-v2"
  [ -e "$marker" ] && return 0
  if [ -f "$CMM_DISABLED_FILE" ]; then
    local n kept=''
    for n in docker xcode go; do
      grep -Fxq "$n" "$CMM_DISABLED_FILE" 2>/dev/null || kept="$kept$n"$'\n'
    done
    printf '%s' "$kept" | cmm_write_file_atomic "$CMM_ENABLED_FILE"
    if [ -n "$kept" ]; then
      note "(kept your earlier choices enabled: $(printf '%s' "$kept" | tr '\n' ' ')— see 'scrubmac list')"
    fi
  fi
  mkdir -p "$CMM_STATE_DIR" 2>/dev/null && : >"$marker" 2>/dev/null || true
}

cmm_listed() { [ -f "$1" ] && grep -Fxq -- "$2" "$1" 2>/dev/null; }

# cmm_is_enabled NAME DEFAULT
cmm_is_enabled() {
  cmm_listed "$CMM_DISABLED_FILE" "$1" && return 1
  cmm_listed "$CMM_ENABLED_FILE" "$1" && return 0
  [ "$2" != off ]
}

cmm__drop_line() { # cmm__drop_line FILE NAME
  [ -f "$1" ] || return 0
  { grep -Fvx -- "$2" "$1" || true; } | cmm_write_file_atomic "$1"
}

# cmm_set_state NAME on|off — record an explicit choice.
cmm_set_state() {
  mkdir -p "$CMM_CONFIG_DIR"
  cmm__drop_line "$CMM_DISABLED_FILE" "$1"
  cmm__drop_line "$CMM_ENABLED_FILE" "$1"
  if [ "$2" = on ]; then
    printf '%s\n' "$1" >>"$CMM_ENABLED_FILE"
  else
    printf '%s\n' "$1" >>"$CMM_DISABLED_FILE"
  fi
  [ -e "$CMM_ENABLED_FILE" ] || : >"$CMM_ENABLED_FILE"
  [ -e "$CMM_DISABLED_FILE" ] || : >"$CMM_DISABLED_FILE"
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

# The run lock is a symlink whose target is the holder's pid: creating it is
# a single atomic syscall that fails when the lock exists, and the content
# arrives with it. A stale lock is broken by an atomic rename, and the
# renamed link is checked so a racing run's fresh lock is never stolen.
cmm_lock_acquire() {
  local pid moved
  mkdir -p "$CMM_STATE_DIR"
  if ln -s "$$" "$CMM_LOCK" 2>/dev/null; then
    CMM__LOCK_HELD=1
    return 0
  fi
  pid="$(readlink "$CMM_LOCK" 2>/dev/null || true)"
  if cmm_pid_is_ours "$pid"; then
    err "another scrubmac run is already in progress (pid $pid)"
    exit 2
  fi
  if mv "$CMM_LOCK" "$CMM_LOCK.stale.$$" 2>/dev/null; then
    moved="$(readlink "$CMM_LOCK.stale.$$" 2>/dev/null || true)"
    if [ "$moved" != "$pid" ]; then
      # we grabbed a racing run's fresh lock: hand it back and stand down
      ln -s "$moved" "$CMM_LOCK" 2>/dev/null || true
      rm -rf "$CMM_LOCK.stale.$$"
      err "another scrubmac run is already in progress (pid ${moved:-unknown})"
      exit 2
    fi
    rm -rf "$CMM_LOCK.stale.$$"
    warn "removed a stale lock left by pid ${pid:-unknown}"
  fi
  if ln -s "$$" "$CMM_LOCK" 2>/dev/null; then
    CMM__LOCK_HELD=1
    return 0
  fi
  pid="$(readlink "$CMM_LOCK" 2>/dev/null || true)"
  err "another scrubmac run is already in progress (pid ${pid:-unknown})"
  exit 2
}

# Transitional (remove in v4 with the cleanmymac shim): also hold the
# pre-rename lock — a mkdir lock in TMPDIR, exactly as 2.x takes it — so a
# not-yet-migrated cleanmymac 2.x copy (e.g. an untouched cron install) and
# scrubmac still exclude each other.
cmm_legacy_lock_acquire() {
  local base="${TMPDIR:-/tmp}" pid
  CMM__LEGACY_LOCK="${base%/}/cleanmymac.$(id -u).lock"
  if mkdir "$CMM__LEGACY_LOCK" 2>/dev/null; then
    printf '%s\n' "$$" >"$CMM__LEGACY_LOCK/pid"
    return 0
  fi
  pid="$(cat "$CMM__LEGACY_LOCK/pid" 2>/dev/null || true)"
  if cmm_pid_is_ours "$pid"; then
    err "a pre-rename cleanmymac run is in progress (pid $pid)"
    CMM__LEGACY_LOCK='' # not ours — don't remove it on exit
    exit 2
  fi
  warn "removing stale legacy lock left by pid ${pid:-unknown}"
  rm -rf "$CMM__LEGACY_LOCK"
  if ! mkdir "$CMM__LEGACY_LOCK" 2>/dev/null; then
    err "cannot acquire legacy lock at $CMM__LEGACY_LOCK"
    CMM__LEGACY_LOCK=''
    exit 2
  fi
  printf '%s\n' "$$" >"$CMM__LEGACY_LOCK/pid"
}

cmm_locks_release() {
  if [ -n "${CMM__LOCK_HELD:-}" ]; then
    if [ "$(readlink "$CMM_LOCK" 2>/dev/null || true)" = "$$" ]; then
      rm -f "$CMM_LOCK"
    fi
    CMM__LOCK_HELD=''
  fi
  if [ -n "${CMM__LEGACY_LOCK:-}" ]; then
    rm -rf "$CMM__LEGACY_LOCK"
    CMM__LEGACY_LOCK=''
  fi
}

# ---------- processes ----------
# cmm_kill_tree PID [SIGNAL] — signal PID and all its descendants (children
# first), so a timed-out cleaner cannot leave a hung tool behind.
cmm_kill_tree() {
  local pid="$1" sig="${2:-TERM}" kid kids
  kids="$(pgrep -P "$pid" 2>/dev/null || true)"
  for kid in $kids; do
    cmm_kill_tree "$kid" "$sig"
  done
  kill "-$sig" "$pid" 2>/dev/null || true
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
CMM__WD_PID=''
CMM__CUR_NAME=''
CMM__CUR_SRC=''
CMM__CUR_START=0
CMM__RUN_STARTED=''
CMM__RUN_START_SECS=0
CMM__INTERRUPTED=0

cmm_log() {
  [ -n "$CMM_LOG_FILE" ] || return 0
  printf '%s\n' "$*" >>"$CMM_LOG_FILE" 2>/dev/null || true
}

# cmm__exec_cleaner PATH NAME — run one cleaner as a child process with stdin
# from /dev/null (a cleaner must never read the dispatcher's input or wait for
# a prompt answer), output routed per CMM__OUTMODE, and the TIMEOUT watchdog.
# Sets CMM__RC and CMM__TIMED_OUT.
cmm__exec_cleaner() {
  local path="$1" name="$2"
  local out="$CMM_TMP/$name.out" tomark="$CMM_TMP/$name.timeout"
  rm -f "$out" "$tomark"
  case "$CMM__OUTMODE" in
    direct) "$path" </dev/null & ;;
    capture) "$path" </dev/null >"$out" 2>&1 & ;;
    *) (
      "$path" </dev/null 2>&1 | tee "$out"
      exit "${PIPESTATUS[0]}"
    ) & ;;
  esac
  CMM__CUR_PID=$!
  CMM__WD_PID=''
  if [ "${CMM_TIMEOUT:-0}" -gt 0 ]; then
    # The watchdog sleeps in the background and waits on it, so a TERM from
    # the dispatcher (cleaner done) interrupts the wait at once and the trap
    # takes its sleep down with it — no process-table walk on the happy path.
    (
      wd_sleep=''
      trap 'kill "$wd_sleep" 2>/dev/null; exit 0' TERM
      trap - INT
      sleep "$CMM_TIMEOUT" &
      wd_sleep=$!
      wait "$wd_sleep"
      : >"$tomark"
      cmm_kill_tree "$CMM__CUR_PID" TERM
      sleep 5 &
      wd_sleep=$!
      wait "$wd_sleep"
      cmm_kill_tree "$CMM__CUR_PID" KILL
    ) </dev/null >/dev/null 2>&1 &
    CMM__WD_PID=$!
  fi
  CMM__RC=0
  wait "$CMM__CUR_PID" || CMM__RC=$?
  if [ -n "$CMM__WD_PID" ]; then
    kill -TERM "$CMM__WD_PID" 2>/dev/null || true
    wait "$CMM__WD_PID" 2>/dev/null || true
  fi
  CMM__CUR_PID=''
  CMM__WD_PID=''
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

# print_summary [plain] — the per-cleaner table. "plain" drops colors (logs).
print_summary() {
  [ "${#R_NAMES[@]}" -eq 0 ] && return 0
  local plain="${1:-}" i=0 label color reset freed note notes
  local c_ok="$CMM_GREEN" c_dim="$CMM_DIM" c_red="$CMM_RED" c_yel="$CMM_YELLOW" c_rst="$CMM_RESET"
  if [ -n "$plain" ]; then
    c_ok='' c_dim='' c_red='' c_yel='' c_rst=''
    printf '\nSummary\n=======\n'
  else
    banner "Summary"
  fi
  while [ "$i" -lt "${#R_NAMES[@]}" ]; do
    case "${R_STATUS[$i]}" in
      ok) label=ok color="$c_ok" ;;
      skip) label=skip color="$c_dim" ;;
      timeout) label=TIMEOUT color="$c_red" ;;
      refused) label=REFUSED color="$c_red" ;;
      stopped) label=STOPPED color="$c_yel" ;;
      *) label=FAIL color="$c_red" ;;
    esac
    reset="$c_rst"
    freed=''
    if [ -n "${R_FREED[$i]}" ]; then
      freed="  freed $(cmm_human_kb "${R_FREED[$i]}")"
    fi
    printf '  %s%-7s%s %-16s %6s%s\n' "$color" "$label" "$reset" "${R_NAMES[$i]}" "$(cmm_human_secs "${R_SECS[$i]}")" "$freed"
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

cmm__rotate_logs() {
  local keep="${CMM_LOG_KEEP:-20}" f n=0
  for f in $(cmm__log_files); do
    n=$((n + 1))
    [ "$n" -gt "$keep" ] && rm -f "$CMM_LOG_DIR/$f"
  done
  return 0
}

cmm__open_log() {
  CMM_LOG_FILE=''
  mkdir -p "$CMM_LOG_DIR" 2>/dev/null || return 0
  CMM_LOG_FILE="$CMM_LOG_DIR/run-$(date -u '+%Y%m%dT%H%M%SZ')-$$.log"
  : >"$CMM_LOG_FILE" 2>/dev/null || CMM_LOG_FILE=''
}

# cmm__finish_run EXIT_CODE — summary, disk delta, logs, JSON, notification.
cmm__finish_run() {
  local rc="$1" freed='' df_after
  cmm__counts
  print_summary
  if [ -n "${CMM__DF_BEFORE:-}" ] && [ "$CMM_DRY_RUN" != 1 ] && [ "$CMM_MODE" != status ]; then
    df_after="$(df -k "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
    if [ -n "$df_after" ] && [ "$df_after" -gt "$CMM__DF_BEFORE" ] 2>/dev/null; then
      freed=$((df_after - CMM__DF_BEFORE))
      note "approx. disk space freed: $(cmm_human_kb "$freed")"
    fi
  fi
  if [ -n "${CMM__N_FREED_SUM:-}" ]; then
    note "measured by cleaners: $(cmm_human_kb "$CMM__N_FREED_SUM") freed"
  fi
  if [ "${#R_NAMES[@]}" -ge 3 ] && [ "$CMM__N_OK" -eq 0 ] && [ "$CMM__N_FAIL" -eq 0 ]; then
    warn "every cleaner skipped — if this was a scheduled run, its PATH may be missing your tools (cron's default PATH is /usr/bin:/bin); run 'scrubmac doctor'"
  fi
  if [ -n "$CMM_LOG_FILE" ]; then
    print_summary plain >>"$CMM_LOG_FILE" 2>/dev/null || true
    [ -n "$freed" ] && cmm_log "approx. disk space freed: $(cmm_human_kb "$freed")"
    cmm_log "exit $rc"
    note "log: $CMM_LOG_FILE"
  fi
  if [ "$CMM_DRY_RUN" != 1 ] && [ "$CMM_MODE" != status ]; then
    cmm__json_run "$rc" "$freed" | cmm_write_file_atomic "$CMM_LAST_RUN_FILE" 2>/dev/null || true
    if [ "$rc" -eq 0 ] && [ "$CMM__FULL_RUN" = 1 ] && [ "$CMM_MODE" = run ]; then
      date '+%s' | cmm_write_file_atomic "$CMM_LAST_SUCCESS_FILE" 2>/dev/null || true
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

cmm__on_int() {
  trap - INT TERM
  CMM__INTERRUPTED=1
  if [ -n "$CMM__CUR_PID" ]; then
    cmm_kill_tree "$CMM__CUR_PID" TERM
  fi
  if [ -n "$CMM__WD_PID" ]; then
    cmm_kill_tree "$CMM__WD_PID" TERM
  fi
  echo
  warn "interrupted — partial summary follows"
  if [ -n "$CMM__CUR_NAME" ]; then
    cmm__record "$CMM__CUR_NAME" stopped $((SECONDS - CMM__CUR_START)) 130 "$CMM__CUR_SRC" '' '' ''
    cmm_log "== $CMM__CUR_NAME: STOPPED (interrupted)"
  fi
  cmm__finish_run 130
  exit 130
}

# cmm_run_cleaners NAME… — the run loop shared by `scrubmac` (run, update,
# clean modes) and `scrubmac status`. With names, exactly those cleaners run
# (even disabled ones); without, every enabled cleaner. CMM_SKIP_NAMES drops
# cleaners either way.
cmm_run_cleaners() {
  local sel=" $* " name path src def
  local status secs label

  CMM_TMP="$(mktemp -d "${TMPDIR:-/tmp}/scrubmac.run.XXXXXX")"
  CMM__RUN_STARTED="$(cmm_now_iso)"
  CMM__RUN_START_SECS=$SECONDS
  local skips="${CMM_SKIP_NAMES:-}"
  CMM__FULL_RUN=0
  if [ "$#" -eq 0 ] && [ -z "${skips// /}" ]; then
    CMM__FULL_RUN=1
  fi

  # Output routing: stream straight to a terminal (tools keep their TTY
  # behavior); otherwise capture each cleaner's output for the log — and
  # stream it too unless quiet.
  if [ "$CMM_QUIET" = 1 ]; then
    CMM__OUTMODE=capture
  elif [ "${CMM__TTY_OUT:-0}" = 1 ] && [ "$CMM_JSON" != 1 ]; then
    CMM__OUTMODE=direct
  else
    CMM__OUTMODE='tee'
  fi

  if [ "$CMM_DRY_RUN" != 1 ] && [ "$CMM_MODE" != status ]; then
    cmm__open_log
    CMM__DF_BEFORE="$(df -k "$HOME" 2>/dev/null | awk 'NR == 2 { print $4 }' || true)"
  else
    CMM__DF_BEFORE=''
  fi
  cmm_log "scrubmac $CMM_VERSION — $CMM__RUN_STARTED — mode=$CMM_MODE scheduled=${CMM_SCHEDULED:-0} interactive=${CMM_INTERACTIVE:-0} offline=${CMM_OFFLINE:-0} quiet=$CMM_QUIET"
  cmm_log "PATH=$PATH"

  trap cmm__on_int INT TERM

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

    if ! assert_safe_to_execute "$path"; then
      cmm__record "$name" refused 0 '' "$src" "refused by the execution-safety guard (see 'scrubmac doctor')$CMM_US" '' ''
      cmm_log "== $name: REFUSED (execution-safety guard: $path)"
      continue
    fi

    banner "$name"
    CMM__CUR_NAME="$name"
    CMM__CUR_SRC="$src"
    CMM__CUR_START=$SECONDS
    export CMM_REPORT_FILE="$CMM_TMP/$name.report"
    export CMM_CLEANER_NAME="$name"
    : >"$CMM_REPORT_FILE"
    cmm__exec_cleaner "$path" "$name"
    secs=$((SECONDS - CMM__CUR_START))
    cmm__read_report "$CMM_REPORT_FILE"

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
        fail | timeout) cat "$CMM_TMP/$name.out" 2>/dev/null || true ;;
        skip)
          if [ -n "$CMM__SKIPMSG" ]; then
            note "- $CMM__SKIPMSG"
          else
            tail -n 1 "$CMM_TMP/$name.out" 2>/dev/null || true # surface the skip note
          fi
          ;;
      esac
    fi
    case "$status" in
      fail) warn "$name failed (exit $CMM__RC) — continuing with the remaining cleaners" ;;
      timeout) warn "$name exceeded the ${CMM_TIMEOUT}s TIMEOUT and was stopped — continuing" ;;
    esac

    cmm__record "$name" "$status" "$secs" "$CMM__RC" "$src" "$CMM__NOTES" "$CMM__FREED" "$CMM__CACHE"
    CMM__CUR_NAME=''
    case "$status" in
      ok) label=ok ;; skip) label=skip ;; timeout) label=TIMEOUT ;; *) label=FAIL ;;
    esac
    cmm_log "== $name: $label (${secs}s, exit $CMM__RC)"
    if [ -n "$CMM_LOG_FILE" ] && [ -s "$CMM_TMP/$name.out" ]; then
      cat "$CMM_TMP/$name.out" >>"$CMM_LOG_FILE" 2>/dev/null || true
    fi
  done <<EOF
$CMM_DISCOVERED
EOF

  trap - INT TERM
  unset CMM_REPORT_FILE CMM_CLEANER_NAME
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
