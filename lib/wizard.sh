#!/usr/bin/env bash
# lib/wizard.sh — the powerlevel10k-style setup wizard.
#
# Sourced by bin/cleanmymac (never executed directly), so discover(),
# config paths, and the lib helpers are all in scope. Bash 3.2 compatible.
# Nothing is written until the summary screen is confirmed; (r) restarts
# from the top and (q) quits without writing, on every screen.

# Display-name:cleaner-names groups, in screen order. Underscores become
# spaces for display. Discovered cleaners not listed here land in "Other".
W_GROUPS='Package_managers:homebrew mas|JavaScript:npm pnpm yarn bun|Python:python conda|AI_tools:claude codex gemini gh cursor|Languages:rustup composer go mise|Heavy_pruners:docker xcode'

W_RESTART=0
W_ANSWER=''
W_DISABLED=''
W_COOLDOWN=0
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

w_is_off() {
  case " $W_DISABLED " in
    *" $1 "*) return 0 ;;
    *) return 1 ;;
  esac
}

w_off() { w_is_off "$1" || W_DISABLED="$W_DISABLED $1"; }

w_on() {
  local out='' n
  for n in $W_DISABLED; do
    [ "$n" = "$1" ] || out="$out $n"
  done
  W_DISABLED="${out# }"
}

# w_cleaner_path NAME — path of a discovered cleaner ('' if unknown).
w_cleaner_path() {
  discover | awk -F '\t' -v n="$1" '$1 == n { print $3; exit }'
}

# w_tool_mark NAME — "found" / "not found (auto-skips)" from the gate header.
w_tool_mark() {
  local path gate g
  path="$(w_cleaner_path "$1")"
  [ -n "$path" ] || {
    printf 'unknown\n'
    return 0
  }
  gate="$(sed -n 's/^# gate: //p' "$path" | head -n 1)"
  [ -n "$gate" ] || {
    printf '?\n'
    return 0
  }
  for g in $gate; do
    if have "$g"; then
      printf 'found\n'
      return 0
    fi
  done
  printf 'not found (auto-skips)\n'
}

# ---------- screens ----------
w_welcome() {
  w_header 'Welcome to cleanmymac'
  note 'This wizard picks which services to maintain and sets security policy.'
  note 'Safety doctrine: never sudo, never your data — only updates and'
  note 'regenerable caches. Every screen accepts (r)estart and (q)uit;'
  note 'nothing is written until you confirm the summary.'
  note ''
  w_ask 'Press Enter to begin: '
}

# w_services_screen TITLE NAMES…
w_services_screen() {
  local title="$1" state
  shift
  local items="$*"
  while :; do
    w_header "$title"
    local i=1 n
    for n in $items; do
      state='[x]'
      w_is_off "$n" && state='[ ]'
      printf '  %d) %s %-12s %s\n' "$i" "$state" "$n" "($(w_tool_mark "$n"))"
      i=$((i + 1))
    done
    case "$title" in
      *pruners*)
        note ''
        note '  docker: prunes build cache + dangling images only (never containers/volumes)'
        note '  xcode:  deletes stale simulators + DerivedData older than 30 days'
        ;;
    esac
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
          if w_is_off "$hit"; then w_on "$hit"; else w_off "$hit"; fi
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
    note '  Applies mechanically to uv (--exclude-newer). For npm, automatic'
    note '  global updates are held while a cooldown is set (npm offers no'
    note '  safe equivalent). Homebrew is a curated registry: not applicable.'
    note ''
    note '  1) Off'
    note '  2) 3 days'
    note '  3) 7 days (recommended)'
    note '  4) 14 days'
    note ''
    w_ask 'Choice [3]: '
    [ "$W_RESTART" -eq 1 ] && return 0
    case "$W_ANSWER" in
      1) W_COOLDOWN=0 ;;
      2) W_COOLDOWN=3 ;;
      3 | '') W_COOLDOWN=7 ;;
      4) W_COOLDOWN=14 ;;
      *)
        note '  (enter 1-4)'
        continue
        ;;
    esac
    return 0
  done
}

w_output_screen() {
  while :; do
    w_header 'Output'
    note '  1) Full — stream every command and its output (recommended)'
    note '  2) Quiet — banners and summary only; failures still dump their output'
    note ''
    w_ask 'Choice [1]: '
    [ "$W_RESTART" -eq 1 ] && return 0
    case "$W_ANSWER" in
      1 | '') W_QUIET=0 ;;
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
    note '  1) Auto — color when the output is a terminal (recommended)'
    note '  2) Always'
    note '  3) Never'
    note ''
    w_ask 'Choice [1]: '
    [ "$W_RESTART" -eq 1 ] && return 0
    case "$W_ANSWER" in
      1 | '') W_CHOSEN_COLOR=auto ;;
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
  w_header 'Summary'
  if [ -n "$W_DISABLED" ]; then
    note "disabled cleaners:    $W_DISABLED"
  else
    note 'disabled cleaners:    (none — everything runs)'
  fi
  note "update cooldown:      ${W_COOLDOWN} day(s)"
  note "quiet mode:           $W_QUIET"
  note "color:                $W_CHOSEN_COLOR"
  note ''
  note "Writes to: $CMM_CONFIG_FILE"
  note ''
  w_ask 'Write this configuration? (y)es / (r)estart / (q)uit: '
  [ "$W_RESTART" -eq 1 ] && return 0
  case "$W_ANSWER" in
    y | Y) return 0 ;;
    *)
      note ''
      note 'Wizard aborted — nothing was written.'
      exit 0
      ;;
  esac
}

w_write() {
  mkdir -p "$CMM_CONFIG_DIR"
  cat >"$CMM_CONFIG_FILE" <<EOF
# cleanmymac configuration — written by 'cleanmymac configure'.
# KEY=value, one per line; values restricted to A-Za-z0-9._/- .
# This file is parsed, never executed.
COOLDOWN_DAYS=$W_COOLDOWN
QUIET=$W_QUIET
COLOR=$W_CHOSEN_COLOR
DERIVEDDATA_AGE_DAYS=30
EOF
  local n
  for n in $W_DISABLED; do
    printf '%s\n' "$n"
  done | sort >"$CMM_DISABLED_FILE"
  note ''
  note "Wrote $CMM_CONFIG_FILE"
  note "Wrote $CMM_DISABLED_FILE"
}

# ---------- driver ----------
w_reset() {
  W_RESTART=0
  W_DISABLED="$CMM_DEFAULT_DISABLED"
  W_COOLDOWN=0
  W_QUIET=0
  W_CHOSEN_COLOR=auto
}

# w_groups_screens — one services screen per non-empty group, then "Other"
# for discovered cleaners (e.g. yours in cleaners.d) not covered by a group.
w_groups_screens() {
  local group title names known='' name filtered
  local old_ifs="$IFS"
  IFS='|'
  set -f
  # shellcheck disable=SC2086
  set -- $W_GROUPS
  set +f
  IFS="$old_ifs"
  for group in "$@"; do
    title="$(printf '%s' "${group%%:*}" | tr '_' ' ')"
    names="${group#*:}"
    filtered=''
    for name in $names; do
      known="$known $name"
      [ -n "$(w_cleaner_path "$name")" ] && filtered="$filtered $name"
    done
    # shellcheck disable=SC2086
    [ -n "$filtered" ] && w_services_screen "$title" $filtered
    [ "$W_RESTART" -eq 1 ] && return 0
  done
  local extras=''
  while IFS="$TAB" read -r name _rest; do
    [ -n "$name" ] || continue
    case " $known " in
      *" $name "*) ;;
      *) extras="$extras $name" ;;
    esac
  done <<EOF
$(discover)
EOF
  # shellcheck disable=SC2086
  [ -n "$extras" ] && w_services_screen 'Other (your cleaners)' $extras
  return 0
}

# wizard_main [firstrun]
wizard_main() {
  local mode="${1:-configure}"
  if [ "${CMM_WIZARD_ASSUME_TTY:-0}" != "1" ] && ! { [ -t 0 ] && [ -t 1 ]; }; then
    err 'the setup wizard needs an interactive terminal'
    note "non-interactive setups can write $CMM_CONFIG_FILE directly (see docs/configuration.md)"
    exit 2
  fi
  while :; do
    w_reset
    w_welcome
    if [ "$W_RESTART" -eq 1 ]; then continue; fi
    w_groups_screens
    if [ "$W_RESTART" -eq 1 ]; then continue; fi
    w_cooldown_screen
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
    note "All set. Preview anytime with: cleanmymac --dry-run"
  fi
}
