#!/usr/bin/env bash
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# lib/wizard.sh — the powerlevel10k-style setup wizard.
#
# Sourced by bin/scrubmac (never executed directly), so discovery, state,
# settings and the lib helpers are all in scope. Bash 3.2 compatible.
# Every screen starts from your CURRENT configuration (Enter keeps it);
# nothing is written until the summary screen is confirmed; (r) restarts
# from the top and (q) quits without writing, on every screen. Settings the
# wizard does not manage are preserved untouched.

# Screen order for the built-in groups; groups declared by your own cleaners
# follow, then "Other" for cleaners without a "# group:" header.
W_GROUP_ORDER='Package managers|JavaScript|Python|AI tools|Languages|Apple development|Developer tools'

W_RESTART=0
W_ANSWER=''
W_ON=''
W_COOLDOWN=7
W_APP=interactive
W_QUIET=0
W_CHOSEN_COLOR=auto

# ---------- small helpers ----------
w_header() { banner "$*"; }

# w_ask PROMPT — read one line into W_ANSWER; q quits (no writes), r restarts.
w_ask() {
  printf '%s' "$1"
  IFS= read -r W_ANSWER || W_ANSWER=q
  case "$W_ANSWER" in
    q | Q)
      note ''
      note 'Wizard aborted — nothing was written.'
      exit 0
      ;;
    r | R)
      W_RESTART=1
      ;;
  esac
}

w_is_on() {
  case " $W_ON " in
    *" $1 "*) return 0 ;;
  esac
  return 1
}

w_on() { w_is_on "$1" || W_ON="$W_ON $1"; }

w_off() {
  local out='' n
  for n in $W_ON; do
    [ "$n" = "$1" ] || out="$out $n"
  done
  W_ON="$out"
}

w_valid_or() { # w_valid_or KEY FALLBACK — the configured value of KEY if valid
  local v
  v="$(config_get "$1" "")"
  cmm_setting_info "$1" || true
  if [ -n "$v" ] && cmm_setting_valid "$CMM__S_TYPE" "$v"; then
    printf '%s\n' "$v"
  else
    printf '%s\n' "$2"
  fi
}

# w_seed — start every screen from the configuration on disk.
w_seed() {
  local name def
  W_RESTART=0
  W_ON=''
  while IFS="$TAB" read -r name _ _ _ _ _ def _; do
    [ -n "$name" ] || continue
    cmm_is_enabled "$name" "$def" && W_ON="$W_ON $name"
  done <<EOF
$CMM_DISCOVERED
EOF
  W_COOLDOWN="$(w_valid_or COOLDOWN_DAYS 7)"
  W_APP="$(w_valid_or APP_UPDATES interactive)"
  W_QUIET="$(w_valid_or QUIET 0)"
  W_CHOSEN_COLOR="$(w_valid_or COLOR auto)"
}

# w_group_names — groups present among discovered cleaners, in screen order:
# the built-in order, then other groups alphabetically, then "Other".
w_group_names() {
  printf '%s\n' "$CMM_DISCOVERED" | awk -F '\t' -v order="$W_GROUP_ORDER" '
    NF { present[$6] = 1 }
    END {
      n = split(order, o, "|")
      for (i = 1; i <= n; i++) if (o[i] in present) { print o[i]; known[o[i]] = 1 }
      known["Other"] = 1
      for (g in present) if (!(g in known)) extra[++m] = g
      for (i = 1; i <= m; i++) for (j = i + 1; j <= m; j++) if (extra[j] < extra[i]) { t = extra[i]; extra[i] = extra[j]; extra[j] = t }
      for (i = 1; i <= m; i++) print extra[i]
      if ("Other" in present) print "Other"
    }'
}

# w_group_members GROUP — cleaner names in GROUP, in run order.
w_group_members() {
  printf '%s\n' "$CMM_DISCOVERED" | awk -F '\t' -v g="$1" '$6 == g { printf "%s ", $1 }'
}

# w_tool_mark GATE — "found" / "not found — auto-skips".
w_tool_mark() {
  case "$(cmm_tool_present "$1")" in
    yes) printf 'found\n' ;;
    '?') printf '?\n' ;;
    *) printf 'not found — auto-skips\n' ;;
  esac
}

# ---------- screens ----------
w_welcome() {
  w_header 'Welcome to scrubmac'
  note 'This wizard picks which services to maintain and sets security policy.'
  note 'Safety doctrine: scrubmac never runs sudo itself and never touches'
  note 'your data — only updates and regenerable caches. Each screen starts'
  note 'from your current choices (Enter keeps them) and accepts (r)estart'
  note 'and (q)uit; nothing is written until you confirm the summary.'
  note ''
  w_ask 'Press Enter to begin: '
}

# w_services_screen TITLE NAMES…
w_services_screen() {
  local title="$1" items i n row gate def summary state
  shift
  items="$*"
  while :; do
    w_header "$title"
    i=1
    for n in $items; do
      row="$(printf '%s\n' "$CMM_DISCOVERED" | awk -F '\t' -v n="$n" '$1 == n { print; exit }')"
      gate="$(printf '%s' "$row" | cut -f 5)"
      def="$(printf '%s' "$row" | cut -f 7)"
      summary="$(printf '%s' "$row" | cut -f 8)"
      [ "$summary" = - ] && summary=''
      state='[ ]'
      w_is_on "$n" && state='[x]'
      printf '  %2d) %s %-12s %s%s\n' "$i" "$state" "$n" "($(w_tool_mark "$gate"))" "$([ "$def" = off ] && printf ' · opt-in')"
      [ -n "$summary" ] && printf '         %s\n' "$summary"
      i=$((i + 1))
    done
    note ''
    w_ask 'Toggle a number, (a)ll on, (n)one, Enter to continue: '
    [ "$W_RESTART" -eq 1 ] && return 0
    case "$W_ANSWER" in
      '')
        return 0 # accepted; move on
        ;;
      a | A)
        for n in $items; do w_on "$n"; done
        ;;
      n | N)
        for n in $items; do w_off "$n"; done
        ;;
      *[!0-9]*)
        note '  (enter a number, a, n, r, or q)'
        ;;
      *)
        local idx=1 hit=''
        for n in $items; do
          if [ "$idx" -eq "$W_ANSWER" ] 2>/dev/null; then
            hit="$n"
            break
          fi
          idx=$((idx + 1))
        done
        if [ -n "$hit" ]; then
          if w_is_on "$hit"; then w_off "$hit"; else w_on "$hit"; fi
        else
          note '  (number out of range)'
        fi
        ;;
    esac
  done
}

w_cooldown_screen() {
  while :; do
    w_header 'Update cooldown (supply-chain guard)'
    note 'Skip package versions younger than N days? Fresh releases are where'
    note 'npm-worm-style supply-chain attacks live — a cooldown buys the'
    note 'ecosystem time to catch them. Trade-off: security PATCHES are also'
    note 'delayed by N days.'
    note ''
    note '  Enforced for npm, pnpm and Bun (scrubmac picks the newest version at'
    note '  least N days old), uv (--exclude-newer) and pipx (--cooldown); Yarn'
    note '  classic global upgrades are held. Homebrew is a curated registry:'
    note '  not applicable. See docs/security.md (S4).'
    note ''
    note '  1) Off'
    note '  2) 3 days'
    note '  3) 7 days (recommended)'
    note '  4) 14 days'
    note ''
    w_ask "Choice [Enter keeps ${W_COOLDOWN} day(s)]: "
    [ "$W_RESTART" -eq 1 ] && return 0
    case "$W_ANSWER" in
      '') ;;
      1) W_COOLDOWN=0 ;;
      2) W_COOLDOWN=3 ;;
      3) W_COOLDOWN=7 ;;
      4) W_COOLDOWN=14 ;;
      *)
        note '  (enter 1-4)'
        continue
        ;;
    esac
    return 0
  done
}

w_app_screen() {
  while :; do
    w_header 'App updates (Homebrew casks)'
    note 'Upgrading a GUI app can quit it while it is open, or stop to ask'
    note 'for your password — fine when you are watching, surprising in a'
    note 'scheduled run.'
    note ''
    note '  1) Only when I run scrubmac myself (recommended)'
    note '  2) Always — scheduled runs too'
    note '  3) Never — scrubmac leaves GUI apps alone'
    note ''
    w_ask "Choice [Enter keeps '${W_APP}']: "
    [ "$W_RESTART" -eq 1 ] && return 0
    case "$W_ANSWER" in
      '') ;;
      1) W_APP=interactive ;;
      2) W_APP=always ;;
      3) W_APP=never ;;
      *)
        note '  (enter 1-3)'
        continue
        ;;
    esac
    return 0
  done
}

w_output_screen() {
  while :; do
    w_header 'Output'
    note '  1) Full — stream every command and its output'
    note '  2) Quiet — one line per cleaner, then the summary; a failing'
    note '     cleaner still shows its output'
    note ''
    w_ask "Choice [Enter keeps $([ "$W_QUIET" = 1 ] && echo quiet || echo full)]: "
    [ "$W_RESTART" -eq 1 ] && return 0
    case "$W_ANSWER" in
      '') ;;
      1) W_QUIET=0 ;;
      2) W_QUIET=1 ;;
      *)
        note '  (enter 1 or 2)'
        continue
        ;;
    esac
    return 0
  done
}

w_color_screen() {
  while :; do
    w_header 'Color'
    note '  1) Auto — color when the output is a terminal'
    note '  2) Always'
    note '  3) Never'
    note ''
    w_ask "Choice [Enter keeps ${W_CHOSEN_COLOR}]: "
    [ "$W_RESTART" -eq 1 ] && return 0
    case "$W_ANSWER" in
      '') ;;
      1) W_CHOSEN_COLOR=auto ;;
      2) W_CHOSEN_COLOR=always ;;
      3) W_CHOSEN_COLOR=never ;;
      *)
        note '  (enter 1-3)'
        continue
        ;;
    esac
    return 0
  done
}

w_summary_screen() {
  local name def on_list='' off_list=''
  while IFS="$TAB" read -r name _ _ _ _ _ def _; do
    [ -n "$name" ] || continue
    if w_is_on "$name"; then
      [ "$def" = off ] && on_list="$on_list $name"
    else
      off_list="$off_list $name"
    fi
  done <<EOF
$CMM_DISCOVERED
EOF
  w_header 'Summary'
  note "disabled cleaners:    ${off_list# }"
  [ -z "$off_list" ] && note '                      (none — everything runs)'
  [ -n "$on_list" ] && note "opt-in cleaners on:   ${on_list# }"
  note "update cooldown:      ${W_COOLDOWN} day(s)"
  note "app updates:          $W_APP"
  note "quiet mode:           $W_QUIET"
  note "color:                $W_CHOSEN_COLOR"
  note ''
  note "Writes to: $CMM_CONFIG_FILE (other settings there are kept)"
  note ''
  while :; do
    w_ask 'Write this configuration? [Y]es / (r)estart / (q)uit: '
    [ "$W_RESTART" -eq 1 ] && return 0
    case "$W_ANSWER" in
      '' | [yY] | [yY][eE][sS]) return 0 ;;
      *) note '  (enter y, r, or q)' ;;
    esac
  done
}

w_write() {
  local name def en='' dis='' n
  # config: rewrite only the wizard's keys; keep every other line
  {
    if [ -f "$CMM_CONFIG_FILE" ]; then
      grep -v -E '^[[:space:]]*(COOLDOWN_DAYS|APP_UPDATES|QUIET|COLOR)[[:space:]]*=' "$CMM_CONFIG_FILE" || true
    else
      printf '%s\n' "# scrubmac configuration — written by 'scrubmac configure'." \
        "# KEY=value, one per line; values restricted to A-Za-z0-9._/- ." \
        "# This file is parsed, never executed. 'scrubmac config' lists every setting."
    fi
    printf 'COOLDOWN_DAYS=%s\nAPP_UPDATES=%s\nQUIET=%s\nCOLOR=%s\n' \
      "$W_COOLDOWN" "$W_APP" "$W_QUIET" "$W_CHOSEN_COLOR"
  } | cmm_write_file_atomic "$CMM_CONFIG_FILE" || exit 2

  # state: record choices that differ from a cleaner's default, keep earlier
  # explicit choices that still hold, and keep entries for cleaners that are
  # not installed right now.
  while IFS="$TAB" read -r name _ _ _ _ _ def _; do
    [ -n "$name" ] || continue
    if w_is_on "$name"; then
      if [ "$def" = off ] || cmm_listed "$CMM_ENABLED_FILE" "$name"; then
        en="$en$name"$'\n'
      fi
    else
      if [ "$def" != off ] || cmm_listed "$CMM_DISABLED_FILE" "$name"; then
        dis="$dis$name"$'\n'
      fi
    fi
  done <<EOF
$CMM_DISCOVERED
EOF
  while IFS= read -r n; do
    if [ -n "$n" ] && ! known_cleaner "$n"; then en="$en$n"$'\n'; fi
  done <<EOF
$(cmm_state_names "$CMM_ENABLED_FILE")
EOF
  while IFS= read -r n; do
    if [ -n "$n" ] && ! known_cleaner "$n"; then dis="$dis$n"$'\n'; fi
  done <<EOF
$(cmm_state_names "$CMM_DISABLED_FILE")
EOF
  # (your comments in both files are kept — see cmm_state_write)
  # shellcheck disable=SC2046  # cleaner names never contain whitespace
  cmm_state_write "$CMM_ENABLED_FILE" "$CMM__HDR_ON" $(printf '%s' "$en" | awk 'NF' | sort -u) || exit 2
  # shellcheck disable=SC2046
  cmm_state_write "$CMM_DISABLED_FILE" "$CMM__HDR_OFF" $(printf '%s' "$dis" | awk 'NF' | sort -u) || exit 2
  note ''
  note "Wrote $CMM_CONFIG_FILE"
  note "Wrote $CMM_ENABLED_FILE and $CMM_DISABLED_FILE"
}

# w_groups_screens — one services screen per group, in screen order. The
# group list arrives on fd 3: the screens read their answers from stdin,
# which must stay the user's terminal (a heredoc on stdin would answer for
# them).
w_groups_screens() {
  local group members title
  while IFS= read -r group <&3; do
    [ -n "$group" ] || continue
    members="$(w_group_members "$group")"
    [ -n "${members// /}" ] || continue
    title="$group"
    [ "$group" = Other ] && title='Other (your cleaners)'
    # shellcheck disable=SC2086
    w_services_screen "$title" $members
    [ "$W_RESTART" -eq 1 ] && return 0
  done 3<<EOF
$(w_group_names)
EOF
  return 0
}

# wizard_main [firstrun]
wizard_main() {
  local mode="${1:-configure}"
  if [ "${CMM_WIZARD_ASSUME_TTY:-0}" != "1" ] && ! { [ -t 0 ] && [ -t 1 ]; }; then
    err 'the setup wizard needs an interactive terminal'
    note "non-interactive setups can use 'scrubmac config set KEY VALUE' (see docs/configuration.md)"
    exit 2
  fi
  # nothing it cannot read may be overwritten: its contents would be lost
  cmm_require_readable "$CMM_CONFIG_FILE"
  cmm_require_state_readable
  cmm_discover
  while :; do
    w_seed
    w_welcome
    if [ "$W_RESTART" -eq 1 ]; then continue; fi
    w_groups_screens
    if [ "$W_RESTART" -eq 1 ]; then continue; fi
    w_cooldown_screen
    if [ "$W_RESTART" -eq 1 ]; then continue; fi
    w_app_screen
    if [ "$W_RESTART" -eq 1 ]; then continue; fi
    w_output_screen
    if [ "$W_RESTART" -eq 1 ]; then continue; fi
    w_color_screen
    if [ "$W_RESTART" -eq 1 ]; then continue; fi
    w_summary_screen
    if [ "$W_RESTART" -eq 1 ]; then continue; fi
    break
  done
  w_write
  if [ "$mode" = "firstrun" ]; then
    note ''
    note 'Configuration saved — continuing with this run.'
  else
    note ''
    note "All set. Preview anytime with: scrubmac --dry-run"
  fi
}
