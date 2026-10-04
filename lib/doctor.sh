#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# lib/doctor.sh — `scrubmac doctor`: environment, configuration, scheduling
# and security report (S6). Read-only; exits 0 even when it warns.
#
# Sourced by bin/scrubmac on demand; bash 3.2 compatible.

# shellcheck source=lib/schedule.sh
. "$CMM_ROOT/lib/schedule.sh"

cmm__json_field() { # cmm__json_field FILE KEY — a top-level scalar from our own JSON
  sed -n "s/^  \"$2\": \"\{0,1\}\([^\",]*\)\"\{0,1\},\{0,1\}\$/\1/p" "$1" 2>/dev/null | head -n 1
}

cmm__doctor_settings() {
  local key changed=0
  for key in $(cmm_setting_keys); do
    cmm_setting_resolve "$key" || true
    # a value spelled out in the config but equal to the default is no change
    if [ "$CMM__S_VAL" != "$CMM__S_DEF" ]; then
      printf '  %-24s %-12s (%s)\n' "$key" "$CMM__S_VAL" "$CMM__S_SRC"
      changed=1
    fi
  done
  [ "$changed" -eq 0 ] && note "  (all settings at their defaults — 'scrubmac config' lists them)"
  return 0
}

# cmm__unquote VALUE — VALUE without one pair of surrounding quotes.
cmm__unquote() {
  local v="$1"
  case "$v" in
    \"*\") v="${v#\"}" v="${v%\"}" ;;
    \'*\') v="${v#\'}" v="${v%\'}" ;;
  esac
  printf '%s\n' "$v"
}

# cmm__rtrim TEXT — TEXT without trailing whitespace.
cmm__rtrim() { printf '%s\n' "${1%"${1##*[![:space:]]}"}"; }

# cmm__path_has DIR PATHVALUE — the colon-separated PATHVALUE lists DIR
# (trailing slashes aside).
cmm__path_has() {
  local rest="$2" e
  while :; do
    e="${rest%%:*}"
    while [ "${#e}" -gt 1 ] && [ "${e%/}" != "$e" ]; do e="${e%/}"; done
    [ "$e" = "$1" ] && return 0
    case "$rest" in
      *:*) rest="${rest#*:}" ;;
      *) return 1 ;;
    esac
  done
}

# cmm__doctor_cron — crontab entries that run scrubmac: do they get a PATH
# with the tools in it (a PATH= line, an inline PATH=… on the entry, or a
# login shell that reads your profile), and is scrubmac also on launchd?
# An entry is a schedule (five time fields or @word) whose command runs
# scrubmac (or the old cleanmymac name, when it leads here) as a word — not
# a line that merely mentions it.
cmm__doctor_cron() {
  local tab line cmd refs=0 env_path='' env_set=0 brewbin='' entry_path ok_path missing=0 lacks=0 old=0 tok
  local sched='^(@[a-z]+|[0-9*/,A-Za-z-]+([[:space:]]+[0-9*/,A-Za-z-]+){4})[[:space:]]+'
  # a command word: between shell separators, quotes, redirections, parens
  local pre='(^|[/[:space:]"'"'"'(;&|`])' post='([[:space:]"'"'"';&|<>)`]|$)'
  local login='(^|[[:space:]/])(ba|z|k|da|fi|tc|c)?sh([[:space:]]+-[A-Za-z]+)*[[:space:]]+(-[A-Za-z]*l[A-Za-z]*|--login)([[:space:]]|$)'
  have crontab || return 0
  tab="$(crontab -l 2>/dev/null || true)"
  [ -n "$tab" ] || return 0
  [ -n "${CMM_BREW_PREFIX:-}" ] && brewbin="$CMM_BREW_PREFIX/bin"
  while IFS= read -r line; do
    line="${line#"${line%%[![:space:]]*}"}"
    case "$line" in
      '' | '#'*) continue ;;
    esac
    # environment line (applies to the entries below it): PATH = "…"
    if printf '%s\n' "$line" | grep -Eq '^PATH[[:space:]]*='; then
      env_path="$(printf '%s\n' "$line" | sed -E 's/^PATH[[:space:]]*=[[:space:]]*//')"
      env_path="$(cmm__unquote "$(cmm__rtrim "$env_path")")"
      env_set=1
      continue
    fi
    printf '%s\n' "$line" | grep -Eq "$sched" || continue
    cmd="$(printf '%s\n' "$line" | sed -E "s/$sched//")"
    if ! printf '%s\n' "$cmd" | grep -Eq "${pre}scrubmac${post}"; then
      printf '%s\n' "$cmd" | grep -Eq "${pre}cleanmymac${post}" || continue
      tok="$(printf '%s\n' "$cmd" | grep -oE '[^[:space:]"'"'"'(;&|<>`]*cleanmymac' | sed -n 1p)"
      cmm_old_name_ours "$tok" "$CMM_ROOT" "$HOME/.cleanmymac" || continue
      old=1
    fi
    refs=$((refs + 1))
    # an inline PATH=… (the last one wins, as in the shell), quotes honored
    entry_path="$(printf '%s\n' "$cmd" | sed -nE 's/^(.*[[:space:]])?PATH=("([^"]*)"|'"'"'([^'"'"']*)'"'"'|([^[:space:]"'"'"']*)).*/\3\4\5/p' | sed -n 1p)"
    ok_path="$env_set"
    if [ -n "$entry_path" ]; then
      ok_path=1
    elif printf '%s\n' "$cmd" | grep -Eq "$login"; then
      ok_path=login # the login shell reads your profile's PATH
    fi
    if [ "$ok_path" = 0 ]; then
      missing=1
    elif [ "$ok_path" = 1 ] && [ -n "$brewbin" ] && ! cmm__path_has "$brewbin" "${entry_path:-$env_path}"; then
      lacks=1
    fi
  done <<EOF
$tab
EOF
  [ "$refs" -gt 0 ] || return 0
  if [ "$refs" -eq 1 ]; then
    note "crontab:        1 entry runs scrubmac"
  else
    note "crontab:        $refs entries run scrubmac"
  fi
  if [ "$missing" = 1 ]; then
    warn "your crontab sets no PATH for scrubmac — cron's default PATH is /usr/bin:/bin, so most cleaners will skip; add a PATH= line or use 'scrubmac schedule'"
  fi
  if [ "$lacks" = 1 ]; then
    warn "your crontab's PATH lacks $brewbin — Homebrew-installed tools will be skipped"
  fi
  if [ "$old" = 1 ]; then
    warn "your crontab still references 'cleanmymac' — update it to 'scrubmac'"
  fi
  if [ -f "$(cmm_schedule_plist)" ]; then
    warn "scrubmac is scheduled twice — by launchd and by cron; keep one ('scrubmac schedule off', or remove the crontab line)"
  fi
  return 0
}

# cmm__doctor_writable LABEL DIR — DIR (or the nearest parent that exists)
# must be writable for scrubmac to work.
cmm__doctor_writable() {
  local d="$2"
  while [ ! -e "$d" ] && [ "$d" != / ]; do d="$(dirname "$d")"; done
  if [ ! -w "$d" ]; then
    warn "the $1 is not writable: $d — scrubmac cannot save there"
  fi
  return 0
}

cmd_doctor() {
  banner "scrubmac doctor"
  note "version:        $CMM_VERSION"
  note "install mode:   $(install_mode)"
  note "root:           $CMM_ROOT"
  note "bash:           $BASH_VERSION"
  note "system:         $CMM_OS"
  if [ -n "${CMM_BREW_PREFIX:-}" ]; then
    note "brew prefix:    $CMM_BREW_PREFIX"
  else
    note "brew prefix:    (homebrew not found)"
  fi
  if [ "$CMM_OS" = Darwin ]; then
    cmm__load_devdir
    if [ -z "$CMM__DEVDIR" ]; then
      note "developer dir:  (none — Apple's git/python3/swift shims are treated as absent)"
    elif cmm_full_xcode; then
      note "developer dir:  $CMM__DEVDIR (full Xcode)"
    else
      note "developer dir:  $CMM__DEVDIR (Command Line Tools only)"
    fi
  fi

  banner "Configuration"
  note "config dir:     $CMM_CONFIG_DIR"
  if [ -f "$CMM_CONFIG_FILE" ]; then
    note "config file:    $CMM_CONFIG_FILE"
  else
    note "config file:    (none — using defaults; run 'scrubmac configure')"
  fi
  note "state dir:      $CMM_STATE_DIR"
  cmm__doctor_writable "config dir" "$CMM_CONFIG_DIR"
  cmm__doctor_writable "state dir" "$CMM_STATE_DIR"
  if [ -e "$CMM_CONFIG_FILE" ] && [ ! -r "$CMM_CONFIG_FILE" ]; then
    warn "the config file is not readable: $CMM_CONFIG_FILE — defaults are used"
  fi
  note "settings changed from their defaults:"
  cmm__doctor_settings

  banner "Cleaners"
  local name path gate def ok=0 bad=0 on=0 off=0 desc reason f
  cmm_state_migrate
  for f in "$CMM_DISABLED_FILE" "$CMM_ENABLED_FILE"; do
    if { [ -e "$f" ] || [ -L "$f" ]; } && { [ ! -f "$f" ] || ! { : <"$f"; } 2>/dev/null; }; then
      warn "cannot read $f — runs refuse to start until it is readable again (fix its permissions, or remove it)"
    fi
  done
  cmm_discover
  while IFS="$TAB" read -r name _ path _ _ _ def _; do
    [ -n "$name" ] || continue
    if cmm_is_enabled "$name" "$def"; then on=$((on + 1)); else off=$((off + 1)); fi
    if reason="$(assert_safe_to_execute "$path" 2>&1 >/dev/null)"; then
      ok=$((ok + 1))
    else
      bad=$((bad + 1))
      reason="${reason#*warning:* }"
      warn "unsafe cleaner (would be refused): ${reason:-$path}"
    fi
  done <<EOF
$CMM_DISCOVERED
EOF
  note "$on enabled, $off disabled; $ok pass the execution-safety check, $bad refused"
  for f in "$CMM_USER_CLEANERS_DIR"/*.sh; do
    if [ -f "$f" ] && [ ! -x "$f" ]; then
      warn "not executable, so ignored: $f — chmod +x it to use it"
    fi
  done

  banner "Tools"
  local g seen=" " kind
  while IFS="$TAB" read -r name _ _ _ gate _ _ _; do
    [ -n "$name" ] || continue
    [ "$gate" = - ] && continue
    for g in $gate; do
      case "$seen" in *" $g "*) continue ;; esac
      seen="$seen$g "
      if have "$g"; then
        kind="$(install_kind "$g")"
        printf '  %-20s %-10s %s\n' "$g" "$kind" "$(command -v "$g")"
      else
        printf '  %-20s -\n' "$g"
      fi
    done
  done <<EOF
$CMM_DISCOVERED
EOF

  banner "Scheduling"
  if desc="$(cmm_schedule_describe)"; then
    note "launchd agent:  $desc ($(cmm_schedule_plist))"
    if cmm_schedule_loaded; then
      note "                loaded"
    else
      warn "the launchd agent is not loaded — reload it with: $(cmm_schedule_command)"
    fi
    local program
    program="$(cmm__plist_program "$(cmm_schedule_plist)")"
    if [ -n "$program" ] && [ ! -x "$program" ]; then
      warn "the scheduled launcher no longer exists: $program — recreate the schedule with: $(cmm_schedule_command)"
    fi
  else
    note "launchd agent:  none ('scrubmac schedule weekly' sets one up)"
  fi
  cmm__doctor_cron
  if [ -f "$CMM_LAST_RUN_FILE" ]; then
    note "last run:       $(cmm__json_field "$CMM_LAST_RUN_FILE" finished_at), exit $(cmm__json_field "$CMM_LAST_RUN_FILE" exit_code) — 'scrubmac last' shows the log"
  else
    note "last run:       (none recorded)"
  fi
  if [ -L "$CMM_LOCK" ]; then
    local holder
    holder="$(readlink "$CMM_LOCK" 2>/dev/null || true)"
    if cmm_lock_holder_alive "$holder"; then
      note "run lock:       held by pid ${holder%%:*} (a run is in progress)"
    else
      note "run lock:       stale (pid ${holder%%:*}); the next run removes it"
    fi
  fi

  banner "Network & power"
  cmm_detect_offline
  case "${CMM__USER_OFFLINE:-}" in
    0 | 1) note "network:        set by CMM_OFFLINE=$CMM__USER_OFFLINE (not probed)" ;;
    *)
      if [ "$CMM_OFFLINE" = 1 ]; then
        warn "no default network route — a run now would skip updates (cleanup still runs)"
      elif { [ "$CMM_OS" = Darwin ] && ! have route; } || { [ "$CMM_OS" = Linux ] && ! have ip; }; then
        note "network:        unknown (no route/ip command to ask) — runs assume online"
      else
        note "network:        default route present"
      fi
      ;;
  esac
  if cmm_on_battery; then
    note "power:          on battery (scheduled runs follow ON_BATTERY=${CMM_ON_BATTERY:-run})"
  else
    note "power:          AC or no battery"
  fi

  banner "PATH audit (S6)"
  local dir warned=0 old_ifs="$IFS"
  case ":$PATH:" in
    *::*)
      warn "PATH has an empty entry (a leading, trailing or doubled ':') — it searches the current directory, like '.'"
      warned=1
      ;;
  esac
  set -f # no pathname expansion while splitting $PATH
  IFS=':'
  for dir in $PATH; do
    IFS="$old_ifs"
    case "$dir" in
      '')
        IFS=':' # (reported above)
        continue
        ;;
      .)
        warn "PATH contains '.' (current directory) — a classic hijack vector"
        warned=1
        IFS=':'
        continue
        ;;
      /*) ;;
      *)
        warn "PATH has a relative entry '$dir' — it resolves against whatever directory you are in"
        warned=1
        IFS=':'
        continue
        ;;
    esac
    if [ -d "$dir" ]; then
      local out mode
      out="$(cmm_mode_uid "$dir")" || {
        IFS=':'
        continue
      }
      mode="${out%% *}"
      case "$mode" in '' | *[!0-9]*) ;;
      *)
        # shellcheck disable=SC2004
        if [ $((0$mode & 002)) -ne 0 ]; then
          warn "PATH dir is world-writable: $dir"
          warned=1
        fi
        ;;
      esac
    fi
    IFS=':'
  done
  IFS="$old_ifs"
  set +f
  [ "$warned" -eq 0 ] && note "no PATH issues found"

  local link d n
  link="$(command -v scrubmac 2>/dev/null || true)"
  if [ -n "$link" ]; then
    if [ -L "$link" ]; then
      note "launcher:       $link -> $(readlink "$link")"
    else
      note "launcher:       $link"
    fi
  else
    note "launcher:       (scrubmac is not on PATH)"
  fi
  # command -v never returns a dangling link (it is not executable): look
  # where installers put launchers instead
  while IFS= read -r d; do
    [ -n "$d" ] || continue
    for n in scrubmac cleanmymac; do
      if [ -L "$d/$n" ] && [ ! -e "$d/$n" ]; then
        warn "dangling $n symlink: $d/$n -> $(readlink "$d/$n")"
      fi
    done
  done <<EOF
$(cmm_launcher_dirs "${CMM_BREW_PREFIX:+$CMM_BREW_PREFIX/bin}")
EOF
  if [ -L "$HOME/.cleanmymac" ]; then
    note "legacy:         ~/.cleanmymac is a compat link -> $(readlink "$HOME/.cleanmymac") (for pre-rename cron paths; uninstall.sh removes it)"
  elif [ -d "$HOME/.cleanmymac" ]; then
    if [ -d "$HOME/.scrubmac" ]; then
      warn "an old cleanmymac 2.x copy is still at ~/.cleanmymac — scrubmac is installed at ~/.scrubmac, so delete the old copy (its install.sh would downgrade you)"
    else
      warn "an old cleanmymac 2.x install is still at ~/.cleanmymac — run ~/.cleanmymac/install.sh to migrate it, or delete it"
    fi
  fi
  note ""
}
