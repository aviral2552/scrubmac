#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# lib/schedule.sh — `scrubmac schedule`: unattended runs via a per-user
# launchd agent (~/Library/LaunchAgents). Unlike cron, launchd runs a job
# that was missed while the Mac slept as soon as it wakes, and the agent
# carries the PATH captured when you set the schedule — so your tools are
# found (cron's PATH is just /usr/bin:/bin).
#
# Sourced by bin/scrubmac on demand; bash 3.2 compatible.

CMM_SCHEDULE_LABEL='com.github.aviral2552.scrubmac'

cmm_schedule_plist() {
  printf '%s/Library/LaunchAgents/%s.plist\n' "$HOME" "$CMM_SCHEDULE_LABEL"
}

# cmm__xml_escape TEXT — the replacements are quoted and the assignments
# unquoted: the one form whose "&" is literal on bash 3.2 and 5.2 alike.
cmm__xml_escape() {
  local s="$1"
  s=${s//&/"&amp;"}
  s=${s//</"&lt;"}
  s=${s//>/"&gt;"}
  s=${s//\"/"&quot;"}
  printf '%s' "$s"
}

# cmm__schedule_path — the current PATH minus empty, "." and relative
# entries (S6: a scheduled job must not search the working directory).
cmm__schedule_path() {
  local out='' dir old_ifs="$IFS"
  set -f
  IFS=':'
  for dir in $PATH; do
    case "$dir" in
      /*) ;;
      *) continue ;;
    esac
    case ":$out:" in *":$dir:"*) continue ;; esac
    out="${out:+$out:}$dir"
  done
  IFS="$old_ifs"
  set +f
  printf '%s\n' "${out:-/usr/bin:/bin:/usr/sbin:/sbin}"
}

# cmm__weekday DAY — launchd Weekday number (0 = Sunday … 6 = Saturday) for
# a day name. Numbers are not accepted: is 0 Sunday or Monday, is 7 valid?
cmm__weekday() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    sun | sunday) echo 0 ;;
    mon | monday) echo 1 ;;
    tue | tues | tuesday) echo 2 ;;
    wed | wednesday) echo 3 ;;
    thu | thur | thurs | thursday) echo 4 ;;
    fri | friday) echo 5 ;;
    sat | saturday) echo 6 ;;
    *) return 1 ;;
  esac
}

cmm__day_abbrev() {
  case "$1" in
    0) echo sun ;; 1) echo mon ;; 2) echo tue ;; 3) echo wed ;;
    4) echo thu ;; 5) echo fri ;; 6) echo sat ;; *) echo mon ;;
  esac
}

cmm__day_name() {
  case "$1" in
    0) echo Sunday ;; 1) echo Monday ;; 2) echo Tuesday ;; 3) echo Wednesday ;;
    4) echo Thursday ;; 5) echo Friday ;; 6) echo Saturday ;; *) echo "day $1" ;;
  esac
}

# cmm__parse_time HH:MM — sets CMM__HOUR and CMM__MINUTE.
cmm__parse_time() {
  local h m
  case "$1" in
    [0-9]:[0-5][0-9] | [01][0-9]:[0-5][0-9] | 2[0-3]:[0-5][0-9]) ;;
    *) return 1 ;;
  esac
  h="${1%%:*}"
  m="${1#*:}"
  CMM__HOUR=$((10#$h))
  CMM__MINUTE=$((10#$m))
}

cmm__launchd_domain() { printf 'gui/%s\n' "$(id -u)"; }

# cmm__plist_value FILE KEY — the first integer or string after <key>KEY</key>
# (on the same line or a later one), XML-unescaped. KEY=ProgramArguments
# gives the program path. A plist saved in binary form is read through
# plutil.
cmm__plist_value() {
  cmm_plist_xml "$1" | awk -v k="<key>$2</key>" '
    { buf = buf $0 "\n" }
    END {
      i = index(buf, k)
      if (!i) exit
      rest = substr(buf, i + length(k))
      if (!match(rest, /<(integer|string)>[^<]*<\/(integer|string)>/)) exit
      v = substr(rest, RSTART, RLENGTH)
      gsub(/<[^>]*>/, "", v)
      gsub(/&lt;/, "<", v); gsub(/&gt;/, ">", v); gsub(/&quot;/, "\"", v); gsub(/&amp;/, "\\&", v)
      print v
    }' 2>/dev/null
}

cmm__plist_program() { cmm__plist_value "$1" ProgramArguments; }

cmm_schedule_describe() { # one line describing the installed schedule
  local plist hour minute wd
  plist="$(cmm_schedule_plist)"
  [ -f "$plist" ] || return 1
  hour="$(cmm__plist_value "$plist" Hour)"
  minute="$(cmm__plist_value "$plist" Minute)"
  wd="$(cmm__plist_value "$plist" Weekday)"
  if [ -n "$wd" ]; then
    printf 'weekly on %s at %02d:%02d\n' "$(cmm__day_name "$wd")" "${hour:-0}" "${minute:-0}"
  else
    printf 'daily at %02d:%02d\n' "${hour:-0}" "${minute:-0}"
  fi
}

# cmm_schedule_command — the `scrubmac schedule …` command that recreates
# the installed schedule exactly (for repair hints).
cmm_schedule_command() {
  local plist hour minute wd
  plist="$(cmm_schedule_plist)"
  hour="$(cmm__plist_value "$plist" Hour)"
  minute="$(cmm__plist_value "$plist" Minute)"
  wd="$(cmm__plist_value "$plist" Weekday)"
  if [ -n "$wd" ]; then
    printf 'scrubmac schedule weekly %s %02d:%02d\n' "$(cmm__day_abbrev "$wd")" "${hour:-9}" "${minute:-0}"
  else
    printf 'scrubmac schedule daily %02d:%02d\n' "${hour:-9}" "${minute:-0}"
  fi
}

cmm_schedule_loaded() {
  have launchctl || return 1
  launchctl print "$(cmm__launchd_domain)/$CMM_SCHEDULE_LABEL" >/dev/null 2>&1
}

# What a launchd job would not know that this shell does (launchd starts
# jobs with a bare environment): where scrubmac keeps its config and state,
# and where your tools were installed — carried when set here (absolute
# values only), so a scheduled run finds the same tools in the same places.
CMM__SCHEDULE_ENV='XDG_CONFIG_HOME XDG_STATE_HOME XDG_DATA_HOME XDG_CACHE_HOME CMM_STATE_DIR
  PNPM_HOME BUN_INSTALL DENO_INSTALL VOLTA_HOME NVM_DIR CARGO_HOME RUSTUP_HOME GOPATH
  PIPX_HOME PIPX_BIN_DIR UV_TOOL_DIR UV_TOOL_BIN_DIR MISE_DATA_DIR ASDF_DATA_DIR
  PYENV_ROOT RBENV_ROOT NODENV_ROOT GEM_HOME NPM_CONFIG_PREFIX npm_config_prefix'

# cmm__schedule_env [local] — the CMM__SCHEDULE_ENV variables to carry, one
# KEY per line: set here to an absolute path, and not inside the directory
# you schedule from (unless that is your home, or one of its parents) —
# such a value is a project's own (direnv's GEM_HOME, a project
# CARGO_HOME), which `local` lists instead. Paths compare in canonical form
# (a symlinked home).
cmm__schedule_env() {
  local key val canon here home inside project=1 want=0
  [ "${1:-}" = local ] && want=1
  here="$(pwd -P 2>/dev/null || pwd)"
  home="$(cmm_canon_path "$HOME" 2>/dev/null || printf '%s' "$HOME")"
  case "$home/" in "${here%/}"/*) project=0 ;; esac
  case "${HOME%/}/" in "${PWD%/}"/*) project=0 ;; esac # (a symlinked home's logical parent)
  for key in $CMM__SCHEDULE_ENV; do
    val="${!key:-}"
    case "$val" in /*) ;; *) continue ;; esac
    inside=0
    if [ "$project" = 1 ]; then
      canon="$(cmm_canon_path "$val" 2>/dev/null || printf '%s' "$val")"
      case "$canon/" in "$here"/*) inside=1 ;; esac
      case "$val/" in "$PWD"/*) inside=1 ;; esac
    fi
    [ "$inside" = "$want" ] && printf '%s\n' "$key"
  done
  return 0
}

cmm__write_plist() { # cmm__write_plist FILE WEEKDAY(''=daily) HOUR MINUTE
  local plist="$1" wd="$2" hour="$3" minute="$4" launcher path_env key val
  launcher="$(cmm_stable_launcher)"
  path_env="$(cmm__schedule_path)"
  mkdir -p "$(dirname "$plist")" "$CMM_STATE_DIR"
  {
    cat <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key>
  <string>$CMM_SCHEDULE_LABEL</string>
  <key>ProgramArguments</key>
  <array>
    <string>$(cmm__xml_escape "$launcher")</string>
    <string>--scheduled</string>
    <string>--quiet</string>
  </array>
  <key>StartCalendarInterval</key>
  <dict>
EOF
    if [ -n "$wd" ]; then
      printf '    <key>Weekday</key>\n    <integer>%s</integer>\n' "$wd"
    fi
    printf '    <key>Hour</key>\n    <integer>%s</integer>\n' "$hour"
    printf '    <key>Minute</key>\n    <integer>%s</integer>\n' "$minute"
    printf '  </dict>\n  <key>EnvironmentVariables</key>\n  <dict>\n'
    printf '    <key>PATH</key>\n    <string>%s</string>\n' "$(cmm__xml_escape "$path_env")"
    for key in $(cmm__schedule_env); do
      val="${!key}"
      printf '    <key>%s</key>\n    <string>%s</string>\n' "$key" "$(cmm__xml_escape "$val")"
    done
    cat <<EOF
  </dict>
  <key>StandardOutPath</key>
  <string>$(cmm__xml_escape "$CMM_STATE_DIR/launchd.log")</string>
  <key>StandardErrorPath</key>
  <string>$(cmm__xml_escape "$CMM_STATE_DIR/launchd.log")</string>
  <key>ProcessType</key>
  <string>Background</string>
  <key>LowPriorityIO</key>
  <true/>
  <key>Nice</key>
  <integer>10</integer>
  <key>RunAtLoad</key>
  <false/>
</dict>
</plist>
EOF
  } | cmm_write_file_atomic "$plist"
}

cmm_schedule_set() {
  local kind="$1" wd='' arg hour=9 minute=0 plist domain got_day=0 got_time=0 i=0 also
  local usage="usage: scrubmac schedule daily [HH:MM] | weekly [DAY] [HH:MM]   (DAY: mon … sun)"
  shift
  [ "$kind" = weekly ] && wd=1
  for arg in "$@"; do
    if cmm__parse_time "$arg"; then
      [ "$got_time" = 0 ] || usage_err "two times given ('$arg') — $usage"
      got_time=1
      hour="$CMM__HOUR"
      minute="$CMM__MINUTE"
    elif [ "$kind" = weekly ] && cmm__weekday "$arg" >/dev/null; then
      [ "$got_day" = 0 ] || usage_err "two days given ('$arg') — $usage"
      got_day=1
      wd="$(cmm__weekday "$arg")"
    else
      usage_err "unexpected '$arg' — $usage"
    fi
  done
  have launchctl || {
    err "scheduling uses launchd, which this system does not have"
    note "with cron, set PATH explicitly — e.g.:"
    note "  PATH=$(cmm__schedule_path)"
    note "  0 9 * * 1  $(cmm_stable_launcher) --scheduled --quiet"
    exit 2
  }
  plist="$(cmm_schedule_plist)"
  domain="$(cmm__launchd_domain)"
  cmm__write_plist "$plist" "$wd" "$hour" "$minute"
  if have plutil && ! plutil -lint "$plist" >/dev/null 2>&1; then
    err "generated an invalid plist at $plist — please report this"
    exit 1
  fi
  # Replace any loaded copy, then load the new definition. bootout returns
  # before the job is gone, and an immediate bootstrap can fail ("5:
  # Input/output error"), so wait for it to unload and retry briefly.
  launchctl bootout "$domain/$CMM_SCHEDULE_LABEL" >/dev/null 2>&1 || true
  while cmm_schedule_loaded && [ "$i" -lt 20 ]; do
    sleep 0.25
    i=$((i + 1))
  done
  # a service you once disabled (launchctl disable) would refuse to load
  launchctl enable "$domain/$CMM_SCHEDULE_LABEL" >/dev/null 2>&1 || true
  i=0
  until launchctl bootstrap "$domain" "$plist" 2>/dev/null; do
    i=$((i + 1))
    if [ "$i" -ge 3 ]; then
      err "launchctl could not load $plist"
      note "try: launchctl bootstrap $domain '$plist'"
      exit 1
    fi
    sleep 1
  done
  note "scheduled: $(cmm_schedule_describe) — runs '$(cmm_stable_launcher) --scheduled --quiet'"
  note "  agent:  $plist"
  note "  PATH:   captured from this shell (re-run this command after changing your PATH)"
  also="$(cmm__schedule_env | { grep -vx CMM_STATE_DIR || true; } | tr '\n' ' ')"
  [ -n "$also" ] && note "  also:   $also(from this shell, likewise)"
  also="$(cmm__schedule_env local | tr '\n' ' ')"
  [ -n "$also" ] && note "  not carried (inside this directory — a project's own?): $also"
  if [ -n "${DIRENV_DIR:-}" ]; then
    warn "this shell has direnv settings for ${DIRENV_DIR#-} — the schedule took its PATH and tool homes; unless that is what you want, run 'scrubmac schedule' again from a plain shell"
  fi
  note "  logs:   $CMM_LOG_DIR  (or 'scrubmac last')"
  note "launchd runs a schedule missed during sleep at the next wake; a Mac that is off skips it."
}

cmm_schedule_off() {
  local plist
  [ "$#" -eq 0 ] || usage_err "usage: scrubmac schedule off"
  plist="$(cmm_schedule_plist)"
  if have launchctl; then
    launchctl bootout "$(cmm__launchd_domain)/$CMM_SCHEDULE_LABEL" >/dev/null 2>&1 || true
  fi
  if [ -f "$plist" ]; then
    rm -f "$plist"
    note "schedule removed ($plist)"
  else
    note "no schedule was set"
  fi
}

cmm_schedule_status() {
  local plist desc program
  [ "$#" -eq 0 ] || usage_err "usage: scrubmac schedule status"
  plist="$(cmm_schedule_plist)"
  if [ ! -f "$plist" ]; then
    note "no schedule set — create one with: scrubmac schedule weekly   (or: daily)"
    return 0
  fi
  desc="$(cmm_schedule_describe)"
  program="$(cmm__plist_program "$plist")"
  note "schedule: $desc"
  note "agent:    $plist"
  if cmm_schedule_loaded; then
    note "state:    loaded"
  else
    warn "the agent is not loaded — reload it with: $(cmm_schedule_command)"
  fi
  if [ -n "$program" ] && [ ! -x "$program" ]; then
    warn "the scheduled launcher no longer exists: $program — recreate the schedule with '$(cmm_schedule_command)', or remove it with 'scrubmac schedule off'"
  fi
  if [ -f "$CMM_LAST_RUN_FILE" ]; then
    note "last run: $(sed -n 's/^  "finished_at": "\(.*\)",$/\1/p' "$CMM_LAST_RUN_FILE") (exit $(sed -n 's/^  "exit_code": \([0-9]*\),$/\1/p' "$CMM_LAST_RUN_FILE"))"
  fi
}

cmd_schedule() {
  local sub="${1:-status}"
  [ "$#" -gt 0 ] && shift
  case "$sub" in
    status) cmm_schedule_status "$@" ;;
    daily | weekly) cmm_schedule_set "$sub" "$@" ;;
    off | remove) cmm_schedule_off "$@" ;;
    *) usage_err "usage: scrubmac schedule [status | daily [HH:MM] | weekly [DAY] [HH:MM] | off]" ;;
  esac
}
