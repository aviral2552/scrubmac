#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# Wizard: stdin-driven full passes; screens built from cleaner metadata;
# seeding from the current configuration (Enter keeps it); preserving keys
# the wizard does not manage; state recording; restart/quit; first-run
# flows. CMM_WIZARD_ASSUME_TTY=1 lets tests drive the interactive path.

load helpers/setup

setup() {
  setup_sandbox
  export CMM_WIZARD_ASSUME_TTY=1
  CFG="$XDG_CONFIG_HOME/scrubmac/config"
  DIS="$XDG_CONFIG_HOME/scrubmac/disabled"
  EN="$XDG_CONFIG_HOME/scrubmac/enabled"
  make_cleaner 10-alpha.sh '# gate: sh' '# group: Package managers' '# summary: alpha does package things' 'echo ALPHA-RAN'
  make_cleaner 20-beta.sh '# gate: definitely_missing_xyz' '# group: JavaScript' 'echo BETA-RAN'
  make_cleaner 60-heavy.sh '# group: Developer tools' '# default: off' '# summary: prunes heavy things' 'echo HEAVY-RAN'
}
teardown() { teardown_sandbox; }

# welcome, 3 group screens, cooldown, app updates, output, color, summary
KEEP_ALL=$'\n\n\n\n\n\n\n\ny\n'

@test "configure: a default pass on a fresh setup writes the recommended config" {
  run "$CMM" configure <<<"$KEEP_ALL"
  [ "$status" -eq 0 ]
  grep -Fxq 'COOLDOWN_DAYS=7' "$CFG"
  grep -Fxq 'APP_UPDATES=interactive' "$CFG"
  grep -Fxq 'QUIET=0' "$CFG"
  grep -Fxq 'COLOR=auto' "$CFG"
  [ -f "$EN" ] # nothing differs from the defaults
  [ -z "$(state_names "$EN")" ]
  [ -f "$DIS" ]
  [ -z "$(state_names "$DIS")" ]
  run "$CMM"
  [[ "$output" == *ALPHA-RAN* ]] && [[ "$output" != *HEAVY-RAN* ]] || false
}

@test "configure keeps your comments in the state files (and each kept name's own line)" {
  mkdir -p "$XDG_CONFIG_HOME/scrubmac"
  printf '# scrubmac: disabled cleaners\n# off since the work VM needs it:\nalpha   # see ticket 42\n' >"$DIS"
  printf '# scrubmac: enabled cleaners\n# my note\nheavy\n' >"$EN"
  run "$CMM" configure <<<"$KEEP_ALL"
  [ "$status" -eq 0 ]
  grep -Fxq '# off since the work VM needs it:' "$DIS"
  grep -Fxq 'alpha   # see ticket 42' "$DIS"
  grep -Fxq '# my note' "$EN"
  grep -Fxq 'heavy' "$EN"
  [ "$(grep -c '^# scrubmac:' "$DIS")" -eq 1 ]
}

@test "configure: screens come from metadata, with summaries, tool marks and opt-in flags" {
  run "$CMM" configure <<<"$KEEP_ALL"
  [[ "$output" == *"Package managers"* ]] || false
  [[ "$output" == *"JavaScript"* ]] || false
  [[ "$output" == *"Developer tools"* ]] || false
  [[ "$output" == *"alpha does package things"* ]] || false
  [[ "$output" == *"alpha        (found)"* ]] || false
  [[ "$output" == *"beta         (not found — auto-skips)"* ]] || false
  [[ "$output" == *"[ ] heavy"*"opt-in"* ]] || false
  [[ "$output" == *"security PATCHES are also"* ]] || false
  [[ "$output" == *"quit it while it is open"* ]] || false
}

@test "configure: toggles are recorded relative to each cleaner's default" {
  # welcome, alpha screen: toggle 1 (off), beta screen: keep, heavy: toggle 1 (on)
  run "$CMM" configure <<<$'\n1\n\n\n1\n\n\n\n\n\ny\n'
  [ "$status" -eq 0 ]
  [ "$(state_names "$DIS")" = alpha ]
  [ "$(state_names "$EN")" = heavy ]
  run "$CMM"
  [[ "$output" != *ALPHA-RAN* ]] && [[ "$output" == *BETA-RAN* ]] && [[ "$output" == *HEAVY-RAN* ]] || false
}

@test "configure: answers change cooldown, app updates, output and color" {
  run "$CMM" configure <<<$'\n\n\n\n1\n2\n2\n3\ny\n'
  [ "$status" -eq 0 ]
  grep -Fxq 'COOLDOWN_DAYS=0' "$CFG"
  grep -Fxq 'APP_UPDATES=always' "$CFG"
  grep -Fxq 'QUIET=1' "$CFG"
  grep -Fxq 'COLOR=never' "$CFG"
}

@test "configure: re-running starts from the current config and keeps what it does not manage" {
  mkdir -p "$XDG_CONFIG_HOME/scrubmac"
  printf '# hand-written note\nCOOLDOWN_DAYS=14\nQUIET=1\nCOLOR=never\nAPP_UPDATES=always\nDERIVEDDATA_AGE_DAYS=45\nMY_CUSTOM_KEY=hello\n' >"$CFG"
  printf 'beta\n' >"$DIS"
  printf 'heavy\n' >"$EN"
  run "$CMM" configure <<<"$KEEP_ALL"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Enter keeps 14 day(s)"* ]] || false
  grep -Fxq 'COOLDOWN_DAYS=14' "$CFG"
  grep -Fxq 'QUIET=1' "$CFG"
  grep -Fxq 'COLOR=never' "$CFG"
  grep -Fxq 'APP_UPDATES=always' "$CFG"
  grep -Fxq 'DERIVEDDATA_AGE_DAYS=45' "$CFG" # regression: was reset to 30
  grep -Fxq 'MY_CUSTOM_KEY=hello' "$CFG"
  grep -Fxq '# hand-written note' "$CFG"
  [ "$(grep -c '^COOLDOWN_DAYS=' "$CFG")" -eq 1 ]
  [ "$(state_names "$DIS")" = beta ]
  [ "$(state_names "$EN")" = heavy ]
}

@test "configure: state for cleaners that are not installed right now is kept" {
  mkdir -p "$XDG_CONFIG_HOME/scrubmac"
  printf 'uninstalled-thing\n' >"$DIS"
  printf 'another-gone\n' >"$EN"
  run "$CMM" configure <<<"$KEEP_ALL"
  [ "$status" -eq 0 ]
  grep -Fxq uninstalled-thing "$DIS"
  grep -Fxq another-gone "$EN"
}

@test "configure: quitting mid-way writes nothing" {
  run "$CMM" configure <<<$'\n\n\nq\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing was written"* ]] || false
  [ ! -f "$CFG" ] && [ ! -f "$DIS" ] && [ ! -f "$EN" ] || false
}

@test "configure: running out of input aborts without writing (EOF = quit)" {
  run "$CMM" configure <<<$'\n\n'
  [ "$status" -eq 0 ]
  [ ! -f "$CFG" ]
}

@test "configure: restart returns to the top with the starting answers" {
  # toggle heavy on, restart at the cooldown screen, then keep everything
  run "$CMM" configure <<<$'\n\n\n1\n\nr\n'"$KEEP_ALL"
  [ "$status" -eq 0 ]
  [ -z "$(state_names "$EN")" ] # the toggle did not survive the restart
  grep -Fxq 'COOLDOWN_DAYS=7' "$CFG"
}

@test "configure: an unknown answer at the summary asks again; q aborts without writing" {
  run "$CMM" configure <<<$'\n\n\n\n\n\n\n\nx\nq'
  [ "$status" -eq 0 ]
  [[ "$output" == *"(enter y, r, or q)"* ]] || false
  [[ "$output" == *"nothing was written"* ]] || false
  [ ! -f "$CFG" ]
}

@test "configure: the summary lists what will be disabled and which opt-ins are on" {
  run "$CMM" configure <<<$'\n1\n\n\n1\n\n\n\n\n\nq'
  [[ "$output" == *"disabled cleaners:    alpha"* ]] || false
  [[ "$output" == *"opt-in cleaners on:   heavy"* ]] || false
}

@test "configure: a config dir it cannot write to is an error (exit 2), not a silent loss" {
  mkdir -p "$(dirname "$CFG")"
  chmod 500 "$(dirname "$CFG")"
  run "$CMM" configure <<<$'\n\n\n\n\n\n\n\n'
  chmod 700 "$(dirname "$CFG")"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot write"* ]] || false
}

@test "configure refuses to overwrite a config or state file it cannot read" {
  mkdir -p "$(dirname "$CFG")"
  printf 'COOLDOWN_DAYS=14\nMY_CUSTOM=1\n' >"$CFG"
  chmod 000 "$CFG"
  run "$CMM" configure <<<$'\n\n\n\n\n\n\n\n'
  chmod 644 "$CFG"
  [ "$status" -eq 2 ]
  [[ "$output" == *"cannot read $CFG"* ]] || false
  grep -qx 'MY_CUSTOM=1' "$CFG"
}

@test "configure: Enter at the summary writes (the prompt's default is yes)" {
  run "$CMM" configure <<<$'\n\n\n\n\n\n\n\n'
  [ "$status" -eq 0 ]
  [ -f "$CFG" ]
  head -n 1 "$EN" | grep -q '^# scrubmac:'
  head -n 1 "$DIS" | grep -q '^# scrubmac:'
}

@test "configure: refuses without a TTY" {
  unset CMM_WIZARD_ASSUME_TTY
  run "$CMM" configure </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"interactive terminal"* ]] || false
}

@test "configure: cleaners without a group get their own 'Other' screen, last" {
  make_cleaner 90-mine.sh 'echo MINE'
  run "$CMM" configure <<<$'\n\n\n\n\n\n\n\n\ny\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"Other (your cleaners)"* ]] || false
}

@test "configure with the real cleaners: one screen per group, then the policy screens" {
  export CMM_CLEANERS_DIR="$REPO_ROOT/cleaners"
  local groups input i
  groups="$(sed -n 's/^# group: //p' "$REPO_ROOT"/cleaners/*.sh | sort -u | wc -l | tr -d ' ')"
  input=$'\n'
  for ((i = 0; i < groups; i++)); do input="$input"$'\n'; done
  input="$input"$'\n\n\n\ny\n'
  run "$CMM" configure <<<"$input"
  [ "$status" -eq 0 ]
  [[ "$output" == *"All set."* ]] || false
  grep -Fxq 'COOLDOWN_DAYS=7' "$CFG"
  [ -z "$(state_names "$EN")" ]
  [ -z "$(state_names "$DIS")" ]
}

@test "first run: accepting the offer runs the wizard, then the run continues with the new config" {
  run "$CMM" <<<$'y\n'"$KEEP_ALL"
  [ "$status" -eq 0 ]
  [ -f "$CFG" ]
  [[ "$output" == *"continuing with this run"* ]] || false
  [[ "$output" == *ALPHA-RAN* ]] || false
}

@test "first run: declining the offer writes defaults (7-day cooldown) and continues" {
  run "$CMM" <<<$'n\n'
  [ "$status" -eq 0 ]
  [ -f "$CFG" ]
  grep -Fxq 'COOLDOWN_DAYS=7' "$CFG"
  [[ "$output" == *ALPHA-RAN* ]] || false
}

@test "wizard-written settings reach the cleaners on the continued run" {
  make_cleaner 30-env.sh '# group: JavaScript' 'echo "COOL=${CMM_COOLDOWN_DAYS:-unset} APPS=${CMM_APP_UPDATES:-unset}"'
  run "$CMM" <<<$'y\n\n\n\n\n2\n2\n\n\ny\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"COOL=3 APPS=always"* ]] || false
}
