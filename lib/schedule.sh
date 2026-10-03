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

cmm__xml_escape() {
  local s="$1"
  s="${s//&/&amp;}"
  s="${s//</&lt;}"
  s="${s//>/&gt;}"
  s="${s//\"/&quot;}"
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

# cmm__weekday DAY — launchd Weekday number (0 = Sunday … 6 = Saturday).
cmm__weekday() {
  case "$(printf '%s' "$1" | tr '[:upper:]' '[:lower:]')" in
    sun | sunday | 0 | 7) echo 0 ;;
    mon | monday | 1) echo 1 ;;
    tue | tues | tuesday | 2) echo 2 ;;
    wed | wednesday | 3) echo 3 ;;
    thu | thur | thurs | thursday | 4) echo 4 ;;
    fri | friday | 5) echo 5 ;;
    sat | saturday | 6) echo 6 ;;
    *) return 1 ;;
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

cmm__plist_value() { # cmm__plist_value FILE KEY — the integer/string after <key>KEY</key>
  awk -v k="<key>$2</key>" '
    index($0, k) { found = 1; next }
    found { gsub(/^[ \t]*<(integer|string)>|<\/(integer|string)>[ \t]*$/, ""); print; exit }
  ' "$1" 2>/dev/null
}

cmm__plist_program() { # first ProgramArguments entry
  awk '
    /<key>ProgramArguments<\/key>/ { found = 1; next }
    found && /<string>/ { s = $0; sub(/^[ \t]*<string>/, "", s); sub(/<\/string>[ \t]*$/, "", s); print s; exit }
  ' "$1" 2>/dev/null
}

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

cmm_schedule_loaded() {
  have launchctl || return 1
  launchctl print "$(cmm__launchd_domain)/$CMM_SCHEDULE_LABEL" >/dev/null 2>&1
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
    # carry location overrides so the agent reads the same config and state
    for key in XDG_CONFIG_HOME XDG_STATE_HOME CMM_STATE_DIR; do
      val="${!key:-}"
      [ -n "$val" ] || continue
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
  local kind="$1" wd='' arg hour=9 minute=0 plist domain
  shift
  [ "$kind" = weekly ] && wd=1
  for arg in "$@"; do
    if cmm__parse_time "$arg"; then
      hour="$CMM__HOUR"
      minute="$CMM__MINUTE"
    elif [ "$kind" = weekly ] && cmm__weekday "$arg" >/dev/null; then
      wd="$(cmm__weekday "$arg")"
    else
      usage_err "usage: scrubmac schedule daily [HH:MM] | weekly [DAY] [HH:MM]   (got '$arg')"
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
  # replace any loaded copy, then load the new definition
  launchctl bootout "$domain/$CMM_SCHEDULE_LABEL" >/dev/null 2>&1 || true
  if ! launchctl bootstrap "$domain" "$plist"; then
    err "launchctl could not load $plist"
    note "try: launchctl bootstrap $domain '$plist'"
    exit 1
  fi
  note "scheduled: $(cmm_schedule_describe) — runs '$(cmm_stable_launcher) --scheduled --quiet'"
  note "  agent:  $plist"
  note "  PATH:   captured from this shell (re-run this command after changing your PATH)"
  note "  logs:   $CMM_LOG_DIR  (or 'scrubmac last')"
  note "launchd runs a schedule missed during sleep at the next wake; a Mac that is off skips it."
}

cmm_schedule_off() {
  local plist
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
    warn "the agent is not loaded — re-run 'scrubmac schedule ${desc%% *}' to load it"
  fi
  if [ -n "$program" ] && [ ! -x "$program" ]; then
    warn "the scheduled launcher no longer exists: $program — re-run 'scrubmac schedule' or 'scrubmac schedule off'"
  fi
  if [ -f "$CMM_LAST_RUN_FILE" ]; then
    note "last run: $(sed -n 's/^  "finished_at": "\(.*\)",$/\1/p' "$CMM_LAST_RUN_FILE") (exit $(sed -n 's/^  "exit_code": \([0-9]*\),$/\1/p' "$CMM_LAST_RUN_FILE"))"
  fi
}

cmd_schedule() {
  local sub="${1:-status}"
  [ "$#" -gt 0 ] && shift
  case "$sub" in
    status) cmm_schedule_status ;;
    daily | weekly) cmm_schedule_set "$sub" "$@" ;;
    off | remove) cmm_schedule_off ;;
    *) usage_err "usage: scrubmac schedule [status | daily [HH:MM] | weekly [DAY] [HH:MM] | off]" ;;
  esac
}
