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
    if [ "$CMM__S_SRC" != default ]; then
      printf '  %-24s %-12s (%s)\n' "$key" "$CMM__S_VAL" "$CMM__S_SRC"
      changed=1
    fi
  done
  [ "$changed" -eq 0 ] && note "  (all settings at their defaults — 'scrubmac config' lists them)"
  return 0
}

cmm__doctor_cron() {
  local tab line refs=0 has_path=0 path_line='' brewbin=''
  have crontab || return 0
  tab="$(crontab -l 2>/dev/null || true)"
  [ -n "$tab" ] || return 0
  while IFS= read -r line; do
    case "$line" in
      '#'*) continue ;;
      PATH=*)
        has_path=1
        path_line="${line#PATH=}"
        ;;
      *scrubmac* | *cleanmymac*) refs=$((refs + 1)) ;;
    esac
  done <<EOF
$tab
EOF
  [ "$refs" -gt 0 ] || return 0
  note "crontab:        $refs entr$([ "$refs" -eq 1 ] && echo y || echo ies) run scrubmac"
  [ -n "${CMM_BREW_PREFIX:-}" ] && brewbin="$CMM_BREW_PREFIX/bin"
  if [ "$has_path" -eq 0 ]; then
    warn "your crontab sets no PATH — cron's default PATH is /usr/bin:/bin, so most cleaners will skip; add a PATH= line or use 'scrubmac schedule'"
  elif [ -n "$brewbin" ]; then
    case ":$path_line:" in
      *":$brewbin:"*) ;;
      *) warn "your crontab's PATH lacks $brewbin — Homebrew-installed tools will be skipped" ;;
    esac
  fi
  if printf '%s\n' "$tab" | grep -v '^#' | grep -q cleanmymac; then
    warn "your crontab still references 'cleanmymac' — update it to 'scrubmac'"
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
  note "settings changed from their defaults:"
  cmm__doctor_settings

  banner "Cleaners"
  local name path gate def ok=0 bad=0 on=0 off=0 desc
  cmm_state_migrate
  cmm_discover
  while IFS="$TAB" read -r name _ path _ _ _ def _; do
    [ -n "$name" ] || continue
    if cmm_is_enabled "$name" "$def"; then on=$((on + 1)); else off=$((off + 1)); fi
    if assert_safe_to_execute "$path" >/dev/null 2>&1; then
      ok=$((ok + 1))
    else
      bad=$((bad + 1))
      warn "unsafe cleaner (would be refused): $path"
    fi
  done <<EOF
$CMM_DISCOVERED
EOF
  note "$on enabled, $off disabled; $ok pass the execution-safety check, $bad refused"

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
      warn "the launchd agent is not loaded — re-run 'scrubmac schedule ${desc%% *}'"
    fi
    local program
    program="$(cmm__plist_program "$(cmm_schedule_plist)")"
    if [ -n "$program" ] && [ ! -x "$program" ]; then
      warn "the scheduled launcher no longer exists: $program"
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
    if cmm_pid_is_ours "$holder"; then
      note "run lock:       held by pid $holder (a run is in progress)"
    else
      note "run lock:       stale (pid ${holder:-?}); the next run removes it"
    fi
  fi

  banner "Network & power"
  cmm_detect_offline
  if [ "$CMM_OFFLINE" = 1 ]; then
    warn "no default network route — a run now would skip updates (cleanup still runs)"
  else
    note "network:        default route present"
  fi
  if cmm_on_battery; then
    note "power:          on battery (scheduled runs follow ON_BATTERY=${CMM_ON_BATTERY:-run})"
  else
    note "power:          AC or no battery"
  fi

  banner "PATH audit (S6)"
  local dir warned=0 old_ifs="$IFS"
  set -f # no pathname expansion while splitting $PATH
  IFS=':'
  for dir in $PATH; do
    IFS="$old_ifs"
    case "$dir" in
      '' | .)
        warn "PATH contains '.' (current directory) — a classic hijack vector"
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

  local link
  link="$(command -v scrubmac 2>/dev/null || true)"
  if [ -n "$link" ] && [ -L "$link" ] && [ ! -e "$link" ]; then
    warn "dangling scrubmac symlink: $link"
  fi
  if [ -e "$HOME/.cleanmymac" ] || [ -L "$HOME/.cleanmymac" ]; then
    note "legacy:         ~/.cleanmymac still exists (a compat link for pre-rename cron paths; removed by uninstall.sh)"
  fi
  note ""
}
