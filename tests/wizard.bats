#!/usr/bin/env bats
# Wizard: stdin-driven full passes, toggling, restart/quit, first-run flows.
# CMM_WIZARD_ASSUME_TTY=1 lets tests drive the interactive path via stdin.

load helpers/setup

setup() {
  setup_sandbox
  export CMM_CLEANERS_DIR="$REPO_ROOT/cleaners" # real cleaners → 6 group screens
  export CMM_WIZARD_ASSUME_TTY=1
  CFG="$XDG_CONFIG_HOME/cleanmymac/config"
  DIS="$XDG_CONFIG_HOME/cleanmymac/disabled"
}
teardown() { teardown_sandbox; }

# Full pass, all defaults: welcome, 6 group screens, cooldown=3 (7d),
# output=1 (full), color=1 (auto), summary=y.
ALL_DEFAULTS=$'\n\n\n\n\n\n\n3\n1\n1\ny\n'

@test "configure: default pass writes recommended config and keeps heavy pruners disabled" {
  run "$CMM" configure <<<"$ALL_DEFAULTS"
  [ "$status" -eq 0 ]
  [ -f "$CFG" ]
  grep -Fxq 'COOLDOWN_DAYS=7' "$CFG"
  grep -Fxq 'QUIET=0' "$CFG"
  grep -Fxq 'COLOR=auto' "$CFG"
  grep -Fxq 'DERIVEDDATA_AGE_DAYS=30' "$CFG"
  diff "$DIS" - <<'EOF'
docker
xcode
EOF
}

@test "configure: toggling docker on the heavy-pruner screen enables it" {
  # welcome, 5 groups, heavy screen: toggle #1 (docker) then accept,
  # cooldown=1 (off), output=2 (quiet), color=3 (never), y.
  run "$CMM" configure <<<$'\n\n\n\n\n\n1\n\n1\n2\n3\ny\n'
  [ "$status" -eq 0 ]
  grep -Fxq 'COOLDOWN_DAYS=0' "$CFG"
  grep -Fxq 'QUIET=1' "$CFG"
  grep -Fxq 'COLOR=never' "$CFG"
  diff "$DIS" - <<'EOF'
xcode
EOF
}

@test "configure: the heavy-pruner screen says exactly what would be deleted" {
  run "$CMM" configure <<<"$ALL_DEFAULTS"
  [[ "$output" == *"never containers/volumes"* ]]
  [[ "$output" == *DerivedData* ]]
}

@test "configure: cooldown screen states the patch-delay trade-off" {
  run "$CMM" configure <<<"$ALL_DEFAULTS"
  [[ "$output" == *"security PATCHES are also"* ]]
}

@test "configure: quitting mid-way writes nothing" {
  run "$CMM" configure <<<$'\n\n\n\n\n\n\nq\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing was written"* ]]
  [ ! -f "$CFG" ]
  [ ! -f "$DIS" ]
}

@test "configure: running out of input aborts without writing (EOF = quit)" {
  run "$CMM" configure <<<$'\n\n'
  [ "$status" -eq 0 ]
  [ ! -f "$CFG" ]
}

@test "configure: restart returns to the top and answers reset" {
  # toggle docker on heavy screen, then restart at cooldown, then a clean
  # default pass — the earlier toggle must NOT survive the restart.
  run "$CMM" configure <<<$'\n\n\n\n\n\n1\n\nr\n'"$ALL_DEFAULTS"
  [ "$status" -eq 0 ]
  grep -Fxq docker "$DIS"
  grep -Fxq 'COOLDOWN_DAYS=7' "$CFG"
}

@test "configure: summary answering anything but y aborts without writing" {
  run "$CMM" configure <<<$'\n\n\n\n\n\n\n3\n1\n1\nx\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"nothing was written"* ]]
  [ ! -f "$CFG" ]
}

@test "configure: refuses without a TTY" {
  unset CMM_WIZARD_ASSUME_TTY
  run "$CMM" configure </dev/null
  [ "$status" -eq 2 ]
  [[ "$output" == *"interactive terminal"* ]]
}

@test "first run: accepting the offer runs the wizard, then the run continues with the new config" {
  export CMM_CLEANERS_DIR="$FIXTURES" # fixture cleaners → single 'Other' screen
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  # offer=y, welcome, Other screen accept, cooldown=3, output=1, color=1, y
  run "$CMM" <<<$'y\n\n\n3\n1\n1\ny\n'
  [ "$status" -eq 0 ]
  [ -f "$CFG" ]
  [[ "$output" == *"continuing with this run"* ]]
  [[ "$output" == *ALPHA-RAN* ]]
}

@test "first run: declining the offer writes defaults and continues" {
  export CMM_CLEANERS_DIR="$FIXTURES"
  make_cleaner 10-alpha.sh 'echo ALPHA-RAN'
  run "$CMM" <<<$'n\n'
  [ "$status" -eq 0 ]
  [ -f "$CFG" ]
  grep -Fxq 'COOLDOWN_DAYS=0' "$CFG"
  [[ "$output" == *ALPHA-RAN* ]]
}

@test "wizard-written cooldown reaches the cleaners on the continued run" {
  export CMM_CLEANERS_DIR="$FIXTURES"
  make_cleaner 10-env.sh 'echo "COOL=${CMM_COOLDOWN_DAYS:-unset}"'
  run "$CMM" <<<$'y\n\n\n3\n1\n1\ny\n'
  [ "$status" -eq 0 ]
  [[ "$output" == *"COOL=7"* ]]
}
