#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# Shell completions: bash is exercised directly (COMP_WORDS → COMPREPLY);
# zsh is syntax-checked; fish is exercised with `complete -C` where fish is
# installed (CI installs it on Linux). Completions are position-aware: days
# only after `schedule weekly`, setting keys only after `config get|set|unset`.

load helpers/setup

# resolved before setup_sandbox narrows PATH
REAL_ZSH="$(command -v zsh 2>/dev/null || true)"
REAL_FISH="$(command -v fish 2>/dev/null || true)"

setup() {
  setup_sandbox
  ln -s "$CMM" "$STUB_BIN/scrubmac" # the completions call `scrubmac`
  make_cleaner 10-alpha.sh 'echo hi'
  make_cleaner 20-beta.sh 'echo hi'
  # shellcheck source=../completions/scrubmac.bash
  . "$REPO_ROOT/completions/scrubmac.bash"
}
teardown() { teardown_sandbox; }

# completions WORD… — what bash offers for the last WORD (sorted, one line)
completions() {
  COMP_WORDS=("$@")
  COMP_CWORD=$(($# - 1))
  COMPREPLY=()
  _scrubmac
  printf '%s\n' ${COMPREPLY[@]+"${COMPREPLY[@]}"} | sort | tr '\n' ' ' | sed 's/ $//'
}

@test "bash: the first word offers commands and cleaners; options after a dash" {
  [[ " $(completions scrubmac '') " == *" run "* ]] || false
  [[ " $(completions scrubmac '') " == *" schedule "* ]] || false
  [[ " $(completions scrubmac '') " == *" alpha "* ]] || false
  [[ " $(completions scrubmac --) " == *" --dry-run "* ]] || false
}

@test "bash: schedule offers subcommands first, day names only after weekly" {
  [ "$(completions scrubmac schedule '')" = "daily off status weekly" ]
  [ "$(completions scrubmac schedule weekly '')" = "fri mon sat sun thu tue wed" ]
  [ -z "$(completions scrubmac schedule daily '')" ]
  [ -z "$(completions scrubmac schedule weekly fri '')" ]
  [ -z "$(completions scrubmac schedule off '')" ]
}

@test "bash: config offers subcommands first, keys only after get/set/unset" {
  [ "$(completions scrubmac config '')" = "get keys list path set unset" ]
  [[ " $(completions scrubmac config set '') " == *" COOLDOWN_DAYS "* ]] || false
  [[ " $(completions scrubmac config get T) " == *" TIMEOUT "* ]] || false
  [ -z "$(completions scrubmac config list '')" ]
  [ -z "$(completions scrubmac config set COOLDOWN_DAYS '')" ]
}

@test "bash: cleaner names after run/enable/disable/status and --skip" {
  [ "$(completions scrubmac enable '')" = "alpha beta" ]
  [ "$(completions scrubmac run a)" = "alpha" ]
  [ "$(completions scrubmac --skip '')" = "alpha beta" ]
  [[ " $(completions scrubmac --skip alpha '') " == *" run "* ]] || false # a command may follow
  [[ " $(completions scrubmac --skip alpha '') " == *" beta "* ]] || false
}

@test "completion's key list has no side effects (no config-dir migration)" {
  mkdir -p "$XDG_CONFIG_HOME/cleanmymac"
  printf 'MY_KEY=1\n' >"$XDG_CONFIG_HOME/cleanmymac/config"
  [[ " $(completions scrubmac config get '') " == *" TIMEOUT "* ]] || false
  [ -d "$XDG_CONFIG_HOME/cleanmymac" ]
  [ ! -L "$XDG_CONFIG_HOME/cleanmymac" ]
  [ ! -e "$XDG_CONFIG_HOME/scrubmac" ]
}

@test "zsh completion parses" {
  [ -n "$REAL_ZSH" ] || skip "zsh not installed"
  "$REAL_ZSH" -n "$REPO_ROOT/completions/_scrubmac"
}

@test "fish completion parses and is position-aware" {
  [ -n "$REAL_FISH" ] || skip "fish not installed"
  "$REAL_FISH" -n "$REPO_ROOT/completions/scrubmac.fish"
  run "$REAL_FISH" -c "source '$REPO_ROOT/completions/scrubmac.fish'; complete -C 'scrubmac schedule '"
  [[ "$output" == *weekly* ]] || false
  [[ "$output" != *mon* ]] || false
  run "$REAL_FISH" -c "source '$REPO_ROOT/completions/scrubmac.fish'; complete -C 'scrubmac schedule weekly '"
  [[ "$output" == *mon* ]] || false
  [[ "$output" != *daily* ]] || false
  run "$REAL_FISH" -c "source '$REPO_ROOT/completions/scrubmac.fish'; complete -C 'scrubmac config set '"
  [[ "$output" == *COOLDOWN_DAYS* ]] || false
}
