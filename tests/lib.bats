#!/usr/bin/env bats
# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# lib/common.sh unit tests: run/try/dry-run, skip contract, config parsing,
# dates, install-kind classification, safety guards.

load helpers/setup

setup() { setup_sandbox; }
teardown() { teardown_sandbox; }

lib() { bash -c ". '$CMM_LIB_PATH'; $1"; }

@test "run executes its argv" {
  run lib "run touch '$SANDBOX/made'"
  [ "$status" -eq 0 ]
  [ -e "$SANDBOX/made" ]
  [[ "$output" == *"+ touch"* ]] || false
}

@test "run does not execute under CMM_DRY_RUN=1" {
  run lib "CMM_DRY_RUN=1 run touch '$SANDBOX/made'"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/made" ]
  [[ "$output" == *"+ touch"* ]] || false
}

@test "run propagates failure; try tolerates it" {
  run lib "run false"
  [ "$status" -ne 0 ]
  run lib "try false && echo SURVIVED"
  [ "$status" -eq 0 ]
  [[ "$output" == *SURVIVED* ]] || false
  [[ "$output" == *"exited 1"* ]] || false
}

@test "skip_unless exits 75 for a missing tool and 0-continues for a present one" {
  run lib "skip_unless definitely_not_a_real_tool_xyz"
  [ "$status" -eq 75 ]
  [[ "$output" == *"not found"* ]] || false
  run lib "skip_unless sh; echo CONTINUED"
  [ "$status" -eq 0 ]
  [[ "$output" == *CONTINUED* ]] || false
}

@test "config_get returns value, default, and last occurrence" {
  export CMM_CONFIG_FILE="$SANDBOX/config"
  printf 'COOLDOWN_DAYS=3\nCOOLDOWN_DAYS=9\n' >"$CMM_CONFIG_FILE"
  [ "$(lib 'config_get COOLDOWN_DAYS 0')" = "9" ]
  [ "$(lib 'config_get MISSING_KEY fallback')" = "fallback" ]
}

@test "config_get ignores shell syntax — config can never execute code (S5)" {
  export CMM_CONFIG_FILE="$SANDBOX/config"
  cat >"$CMM_CONFIG_FILE" <<EOF
COOLDOWN_DAYS=\$(touch $SANDBOX/pwned)
QUIET=1; touch $SANDBOX/pwned2
COLOR=\`touch $SANDBOX/pwned3\`
DERIVEDDATA_AGE_DAYS=45
EOF
  [ "$(lib 'config_get COOLDOWN_DAYS 0')" = "0" ]
  [ "$(lib 'config_get QUIET 0')" = "0" ]
  [ "$(lib 'config_get COLOR auto')" = "auto" ]
  [ "$(lib 'config_get DERIVEDDATA_AGE_DAYS 30')" = "45" ]
  [ ! -e "$SANDBOX/pwned" ]
  [ ! -e "$SANDBOX/pwned2" ]
  [ ! -e "$SANDBOX/pwned3" ]
}

@test "date_days_ago emits RFC 3339 UTC on both BSD and GNU date" {
  local out
  out="$(lib 'date_days_ago 7')"
  [[ "$out" =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}T[0-9]{2}:[0-9]{2}:[0-9]{2}Z$ ]] || false
}

@test "install_kind: node_modules wins over brew prefix (D4 ordering)" {
  local pfx="$SANDBOX/brewpfx"
  mkdir -p "$pfx/bin" "$pfx/lib/node_modules/@anthropic-ai/claude-code"
  printf '#!/bin/sh\n' >"$pfx/lib/node_modules/@anthropic-ai/claude-code/cli.js"
  chmod 755 "$pfx/lib/node_modules/@anthropic-ai/claude-code/cli.js"
  ln -s "../lib/node_modules/@anthropic-ai/claude-code/cli.js" "$pfx/bin/claude"
  export PATH="$pfx/bin:$PATH" CMM_BREW_PREFIX="$pfx"
  [ "$(lib 'install_kind claude')" = "npm" ]
}

@test "install_kind: a link into the Cellar, Caskroom or opt/ is brew" {
  local pfx="$SANDBOX/brewpfx"
  mkdir -p "$pfx/bin" "$pfx/Cellar/codex/1.0/bin" "$pfx/Caskroom/claude-code/2.0" "$pfx/opt/gh/bin"
  printf '#!/bin/sh\n' >"$pfx/Cellar/codex/1.0/bin/codex"
  printf '#!/bin/sh\n' >"$pfx/Caskroom/claude-code/2.0/claude"
  printf '#!/bin/sh\n' >"$pfx/opt/gh/bin/gh"
  chmod 755 "$pfx/Cellar/codex/1.0/bin/codex" "$pfx/Caskroom/claude-code/2.0/claude" "$pfx/opt/gh/bin/gh"
  ln -s ../Cellar/codex/1.0/bin/codex "$pfx/bin/codex"
  ln -s ../Caskroom/claude-code/2.0/claude "$pfx/bin/claude"
  export PATH="$pfx/bin:$pfx/opt/gh/bin:$PATH" CMM_BREW_PREFIX="$pfx"
  [ "$(lib 'install_kind codex')" = "brew" ]
  [ "$(lib 'install_kind claude')" = "brew" ]
  [ "$(lib 'install_kind gh')" = "brew" ]
}

@test "install_kind: a plain binary under the brew prefix is not brew's (Intel /usr/local)" {
  local pfx="$SANDBOX/usrlocal"
  mkdir -p "$pfx/bin"
  printf '#!/bin/sh\n' >"$pfx/bin/codex"
  chmod 755 "$pfx/bin/codex"
  export PATH="$pfx/bin:$PATH" CMM_BREW_PREFIX="$pfx"
  [ "$(lib 'install_kind codex')" = "standalone" ]
}

@test "install_kind: version-manager shims and installs are 'manager', never self-updated" {
  local mise="$HOME/.local/share/mise" asdf="$HOME/.asdf" volta="$HOME/.volta"
  mkdir -p "$HOME/.local/bin" "$mise/shims" "$mise/installs/deno/2.5/bin" "$asdf/shims" "$volta/bin"
  printf '#!/bin/sh\n' >"$HOME/.local/bin/mise"
  printf '#!/bin/sh\n' >"$mise/installs/deno/2.5/bin/deno"
  printf '#!/bin/sh\n' >"$asdf/shims/uv"
  printf '#!/bin/sh\n' >"$volta/bin/claude"
  chmod 755 "$HOME/.local/bin/mise" "$mise/installs/deno/2.5/bin/deno" "$asdf/shims/uv" "$volta/bin/claude"
  ln -s "$HOME/.local/bin/mise" "$mise/shims/bun" # mise shims are links to mise itself
  export PATH="$mise/shims:$mise/installs/deno/2.5/bin:$asdf/shims:$volta/bin:$PATH"
  [ "$(lib 'install_kind bun')" = "manager" ]
  [ "$(lib 'install_kind deno')" = "manager" ]
  [ "$(lib 'install_kind uv')" = "manager" ]
  [ "$(lib 'install_kind claude')" = "manager" ]
  make_stub bun-updater
  run lib "ai_self_update bun bun-updater upgrade"
  [ "$status" -eq 0 ]
  [[ "$output" == *"bun runs through mise"* ]] || false
  refute grep -q bun-updater "$CALL_LOG"
}

@test "install_kind: an npm global inside a mise-managed node is npm's" {
  local inst="$HOME/.local/share/mise/installs/node/22/bin"
  mkdir -p "$inst" "$inst/../lib/node_modules/@anthropic-ai/claude-code"
  printf '#!/bin/sh\n' >"$inst/../lib/node_modules/@anthropic-ai/claude-code/cli.js"
  chmod 755 "$inst/../lib/node_modules/@anthropic-ai/claude-code/cli.js"
  ln -s ../lib/node_modules/@anthropic-ai/claude-code/cli.js "$inst/claude"
  export PATH="$inst:$PATH"
  [ "$(lib 'install_kind claude')" = "npm" ]
}

@test "install_kind: standalone and none" {
  make_stub sometool
  [ "$(lib 'install_kind sometool')" = "standalone" ]
  [ "$(lib 'install_kind not_installed_xyz')" = "none" ]
}

@test "ai_self_update runs the updater only for standalone installs" {
  make_stub sometool
  make_stub sometool-updater
  run lib "ai_self_update sometool sometool-updater update"
  [ "$status" -eq 0 ]
  grep -q '^sometool-updater update$' "$CALL_LOG"
  : >"$CALL_LOG"
  local pfx="$SANDBOX/brewpfx"
  mkdir -p "$pfx/bin" "$pfx/Cellar/brewtool/1.0/bin"
  printf '#!/bin/sh\n' >"$pfx/Cellar/brewtool/1.0/bin/brewtool"
  chmod 755 "$pfx/Cellar/brewtool/1.0/bin/brewtool"
  ln -s ../Cellar/brewtool/1.0/bin/brewtool "$pfx/bin/brewtool"
  export PATH="$pfx/bin:$PATH" CMM_BREW_PREFIX="$pfx"
  run lib "ai_self_update brewtool sometool-updater update"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Homebrew-managed"* ]] || false
  refute grep -q sometool-updater "$CALL_LOG"
}

@test "cmm_canon_path never returns a leading // (a symlink to /)" {
  ln -s / "$SANDBOX/rootlink"
  run lib "cmm_canon_path '$SANDBOX/rootlink/usr'"
  [ "$status" -eq 0 ]
  [ "$output" = /usr ]
  run lib "cmm_unsafe_target \"\$(cmm_canon_parent '$SANDBOX/rootlink$HOME')\" && echo UNSAFE"
  [[ "$output" == *UNSAFE* ]] || false
}

@test "cmm_scratch_dir: the dispatcher's per-cleaner dir, or a fresh one when standalone" {
  mkdir -p "$SANDBOX/given"
  run lib "CMM_SCRATCH_DIR='$SANDBOX/given' cmm_scratch_dir"
  [ "$status" -eq 0 ]
  [ "$output" = "$SANDBOX/given" ]
  run lib "unset CMM_SCRATCH_DIR; cmm_scratch_dir"
  [ "$status" -eq 0 ]
  [ -d "$output" ]
  [[ "$output" == "$TMPDIR"/scrubmac-* ]] || false
}

@test "S2: a cleaner owned by another user is refused" {
  local f="$SANDBOX/cleaner.sh"
  printf '#!/bin/sh\n' >"$f"
  chmod 755 "$f"
  # stat reports the file as someone else's, in both the GNU and BSD forms
  make_stub_script stat <<'EOF'
case "$*" in
  *"%a %u"* | *"%Lp %u"*) echo "755 99999" ;;
  *) exec /usr/bin/stat "$@" ;;
esac
EOF
  run lib "cmm_path_is_safe '$f'"
  [ "$status" -ne 0 ]
  run lib "assert_safe_to_execute '$f'"
  [ "$status" -ne 0 ]
  [[ "$output" == *"must be owned by you"* ]] || false
}

@test "cmm_path_is_safe rejects group/world-writable and foreign-owned paths" {
  local f="$SANDBOX/file"
  touch "$f"
  chmod 644 "$f"
  lib "cmm_path_is_safe '$f'"
  chmod 664 "$f"
  refute lib "cmm_path_is_safe '$f'"
  chmod 646 "$f"
  refute lib "cmm_path_is_safe '$f'"
}

@test "assert_safe_to_execute refuses symlinks and unsafe parents (S2)" {
  local d="$SANDBOX/safe"
  mkdir -p "$d"
  chmod 755 "$d"
  printf '#!/bin/sh\n' >"$d/real.sh"
  chmod 755 "$d/real.sh"
  lib "assert_safe_to_execute '$d/real.sh'"
  ln -s "$d/real.sh" "$d/link.sh"
  run lib "assert_safe_to_execute '$d/link.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *symlink* ]] || false
  chmod 775 "$d"
  run lib "assert_safe_to_execute '$d/real.sh'"
  [ "$status" -ne 0 ]
  [[ "$output" == *directory* ]] || false
}

@test "colors: CMM_COLOR=always emits escapes, never does not" {
  run bash -c "CMM_COLOR=always . '$CMM_LIB_PATH'; banner hello"
  [[ "$output" == *$'\033['* ]] || false
  run bash -c "CMM_COLOR=never . '$CMM_LIB_PATH'; banner hello"
  [[ "$output" != *$'\033['* ]] || false
}

@test "resolve_self follows relative symlink chains" {
  mkdir -p "$SANDBOX/a/b" "$SANDBOX/real"
  printf 'x\n' >"$SANDBOX/real/target"
  ln -s ../../real/target "$SANDBOX/a/b/link1"
  ln -s link1 "$SANDBOX/a/b/link2"
  [ "$(lib "resolve_self '$SANDBOX/a/b/link2'")" = "$SANDBOX/real/target" ]
}

# ---------- step / failure accounting ----------

@test "step records a failure, keeps going, and the cleaner exits 1 at the end" {
  run lib "step false; step echo SECOND; echo END"
  [ "$status" -eq 1 ]
  [[ "$output" == *SECOND* ]] || false
  [[ "$output" == *END* ]] || false
  [[ "$output" == *"continuing with the remaining steps"* ]] || false
}

@test "a failed step also overrides a later skip (exit 75 becomes 1)" {
  run lib "step false; skip 'nothing else to do'"
  [ "$status" -eq 1 ]
}

@test "step under dry-run never executes and never fails" {
  run lib "CMM_DRY_RUN=1 step touch '$SANDBOX/made'; CMM_DRY_RUN=1 step false"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/made" ]
}

@test "cmm_launcher_dirs: the given dirs, then CMM_LINK_DIRS, each once, empty ones dropped" {
  [ "$(CMM_LINK_DIRS="/a:/b::/a" lib 'cmm_launcher_dirs "" /b /c' | tr '\n' ' ')" = "/b /c /a " ]
  [ -z "$(CMM_LINK_DIRS='' lib 'cmm_link_dirs')" ]
  [ "$(env -u CMM_LINK_DIRS HOME=/h bash -c ". '$CMM_LIB_PATH'; cmm_link_dirs" | tr '\n' ' ')" = "/usr/local/bin /h/.local/bin " ]
}

@test "cmm_old_name_ours: a cleanmymac that leads into the given dirs, not MacPaw's" {
  mkdir -p "$SANDBOX/inst/bin" "$SANDBOX/links"
  printf '#!/bin/sh\n' >"$SANDBOX/inst/bin/cleanmymac"
  ln -s "$SANDBOX/inst/bin/cleanmymac" "$SANDBOX/links/cleanmymac"
  lib "cmm_old_name_ours '$SANDBOX/inst/bin/cleanmymac' '$SANDBOX/inst'"
  lib "cmm_old_name_ours '$SANDBOX/links/cleanmymac' '$SANDBOX/inst'"
  refute lib "cmm_old_name_ours /Applications/CleanMyMac.app/Contents/MacOS/cleanmymac '$SANDBOX/inst'"
  PATH="$SANDBOX/links:$PATH" lib "cmm_old_name_ours cleanmymac '$SANDBOX/inst'"
  lib "cmm_old_name_ours cleanmymac '$SANDBOX/inst'" # not on PATH: the old docs' bare name
}

@test "config_get reads through CRLF line ends and a byte-order mark" {
  mkdir -p "$XDG_CONFIG_HOME/scrubmac"
  printf '\357\273\277TIMEOUT=600\r\nQUIET=1\r\nBAD=a b\r\n' >"$XDG_CONFIG_HOME/scrubmac/config"
  [ "$(lib 'config_get TIMEOUT x')" = 600 ]
  [ "$(lib 'config_get QUIET x')" = 1 ]
  [ "$(lib 'config_get BAD dflt')" = dflt ]
  [ "$(lib 'config_get MISSING dflt')" = dflt ]
}

# ---------- modes, previews, reports ----------

@test "status mode: run/try/step are silent no-ops; report runs" {
  run lib "export CMM_MODE=status; run touch '$SANDBOX/a'; try touch '$SANDBOX/b'; step touch '$SANDBOX/c'; report echo REPORTED"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/a" ] && [ ! -e "$SANDBOX/b" ] && [ ! -e "$SANDBOX/c" ] || false
  [[ "$output" == *REPORTED* ]] || false
  [[ "$output" != *"+ touch"* ]] || false
}

@test "preview runs only under dry-run; report runs only in status mode" {
  run lib "preview echo PREVIEW-RAN; report echo REPORT-RAN"
  [[ "$output" != *PREVIEW-RAN* ]] && [[ "$output" != *REPORT-RAN* ]] || false
  run lib "export CMM_DRY_RUN=1; preview echo PREVIEW-RAN; report echo REPORT-RAN"
  [[ "$output" == *PREVIEW-RAN* ]] && [[ "$output" != *REPORT-RAN* ]] || false
  run lib "export CMM_MODE=status; preview echo PREVIEW-RAN; report echo REPORT-RAN"
  [[ "$output" != *PREVIEW-RAN* ]] && [[ "$output" == *REPORT-RAN* ]] || false
  run lib "export CMM_DRY_RUN=1; preview false; echo SURVIVED"
  [ "$status" -eq 0 ]
  [[ "$output" == *SURVIVED* ]] || false
}

@test "preview/report --ok=N: exit N is an answer (npm outdated exits 1), any other failure still warns" {
  run lib "export CMM_MODE=status; report --ok=1 sh -c 'echo LISTED; exit 1'; echo SURVIVED"
  [ "$status" -eq 0 ]
  [[ "$output" == *"~ sh -c"* ]] || false
  [[ "$output" != *"--ok"* ]] || false
  [[ "$output" == *LISTED*SURVIVED* ]] || false
  [[ "$output" != *"exited"* ]] || false
  run lib "export CMM_MODE=status; report --ok=1 sh -c 'exit 2'"
  [[ "$output" == *"report 'sh' exited 2 (continuing)"* ]] || false
  run lib "export CMM_MODE=status; report sh -c 'exit 1'"
  [[ "$output" == *"report 'sh' exited 1 (continuing)"* ]] || false
  run lib "export CMM_DRY_RUN=1; preview --ok=1 sh -c 'exit 1'; preview --ok=1 sh -c 'exit 3'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"preview 'sh' exited 3 (continuing)"* ]] || false
  [[ "$output" != *"exited 1"* ]] || false
}

@test "updating/cleaning follow CMM_MODE; offline explains itself once" {
  [ "$(lib 'updating && echo U; cleaning && echo C' | tr '\n' ' ')" = "U C " ]
  [ "$(lib 'export CMM_MODE=update; updating && echo U; cleaning && echo C' | tr '\n' ' ')" = "U " ]
  [ "$(lib 'export CMM_MODE=clean; updating && echo U; cleaning && echo C' | tr '\n' ' ')" = "C " ]
  [ "$(lib 'export CMM_MODE=status; updating && echo U; cleaning && echo C; echo .' | tr '\n' ' ')" = ". " ]
  run lib "export CMM_OFFLINE=1; updating || true; updating || echo NOT-UPDATING"
  [ "$(printf '%s\n' "$output" | grep -c 'offline')" -eq 1 ]
  [[ "$output" == *NOT-UPDATING* ]] || false
}

@test "skip_unless_updating / skip_unless_cleaning exit 75 in the other modes" {
  run lib "export CMM_MODE=clean; skip_unless_updating; echo RAN"
  [ "$status" -eq 75 ]
  run lib "export CMM_OFFLINE=1; skip_unless_updating; echo RAN"
  [ "$status" -eq 75 ]
  run lib "export CMM_MODE=update; skip_unless_cleaning; echo RAN"
  [ "$status" -eq 75 ]
  run lib "skip_unless_updating; skip_unless_cleaning; echo RAN"
  [ "$status" -eq 0 ]
}

@test "app_updates_allowed: interactive default, always, never" {
  run lib "app_updates_allowed"
  [ "$status" -eq 1 ]
  run lib "export CMM_INTERACTIVE=1; app_updates_allowed"
  [ "$status" -eq 0 ]
  run lib "export CMM_APP_UPDATES=always; app_updates_allowed"
  [ "$status" -eq 0 ]
  run lib "export CMM_INTERACTIVE=1 CMM_APP_UPDATES=never; app_updates_allowed"
  [ "$status" -eq 1 ]
}

@test "summary_note, skip reasons and cache sizes are reported to the dispatcher" {
  mkdir -p "$SANDBOX/c"
  dd if=/dev/zero of="$SANDBOX/c/f" bs=1024 count=64 2>/dev/null
  export CMM_REPORT_FILE="$SANDBOX/report"
  : >"$CMM_REPORT_FILE"
  run lib "export CMM_MODE=status; summary_note 'tab	in note'; cache_dir '$SANDBOX/c'; skip 'gone fishing'"
  [ "$status" -eq 75 ]
  grep -q $'^note\ttab in note$' "$CMM_REPORT_FILE"
  grep -Eq $'^cache_kb\t6[0-9]$' "$CMM_REPORT_FILE"
  grep -q $'^skip\tgone fishing$' "$CMM_REPORT_FILE"
}

@test "cache_dir with MEASURE=1 reports the space freed" {
  mkdir -p "$SANDBOX/c"
  dd if=/dev/zero of="$SANDBOX/c/f" bs=1024 count=512 2>/dev/null
  export CMM_REPORT_FILE="$SANDBOX/report"
  : >"$CMM_REPORT_FILE"
  run lib "export CMM_MEASURE=1; cache_dir '$SANDBOX/c'; rm -f '$SANDBOX/c/f'"
  [ "$status" -eq 0 ]
  grep -Eq $'^freed_kb\t5[0-9][0-9]$' "$CMM_REPORT_FILE"
}

@test "cache_dir_cmd only runs its command when a size is needed" {
  make_stub cachetool 0 "$SANDBOX"
  run lib "cache_dir_cmd cachetool dir"
  [ ! -s "$CALL_LOG" ]
  run lib "export CMM_MODE=status; cache_dir_cmd cachetool dir"
  grep -q '^cachetool dir$' "$CALL_LOG"
  [[ "$output" == *"cache $SANDBOX:"* ]] || false
}

# ---------- detection ----------

@test "have treats Apple's developer-tool shims as absent without a developer dir" {
  mkdir -p "$CMM_APPLE_STUB_DIR"
  printf '#!/bin/sh\necho SHIM-RAN\n' >"$CMM_APPLE_STUB_DIR/python3"
  chmod 755 "$CMM_APPLE_STUB_DIR/python3"
  export PATH="$CMM_APPLE_STUB_DIR:$PATH"
  printf '#!/bin/sh\necho "xcode-select: error: Unable to get active developer directory" >&2\nexit 2\n' >"$STUB_BIN/xcode-select"
  chmod 755 "$STUB_BIN/xcode-select"
  run lib "have python3 && echo PRESENT || echo ABSENT"
  [[ "$output" == *ABSENT* ]] || false
  [[ "$output" != *SHIM-RAN* ]] || false # never executed while probing
  mkdir -p "$SANDBOX/CLT"
  make_stub xcode-select 0 "$SANDBOX/CLT"
  run lib "have python3 && echo PRESENT || echo ABSENT"
  [[ "$output" == *PRESENT* ]] || false
}

@test "have: a bogus developer dir (xcode-select -p echoes DEVELOPER_DIR unchecked) counts as none" {
  mkdir -p "$CMM_APPLE_STUB_DIR"
  printf '#!/bin/sh\n' >"$CMM_APPLE_STUB_DIR/git"
  chmod 755 "$CMM_APPLE_STUB_DIR/git"
  export PATH="$CMM_APPLE_STUB_DIR:$PATH"
  make_stub xcode-select 0 "/nonexistent/Developer"
  run lib "have git && echo PRESENT || echo ABSENT"
  [[ "$output" == *ABSENT* ]] || false
}

@test "have xcodebuild needs a full Xcode, not just the Command Line Tools" {
  mkdir -p "$CMM_APPLE_STUB_DIR" "$SANDBOX/CommandLineTools" "$SANDBOX/Xcode.app/Contents/Developer"
  printf '#!/bin/sh\n' >"$CMM_APPLE_STUB_DIR/xcodebuild"
  chmod 755 "$CMM_APPLE_STUB_DIR/xcodebuild"
  export PATH="$CMM_APPLE_STUB_DIR:$PATH"
  make_stub xcode-select 0 "$SANDBOX/CommandLineTools"
  run lib "have xcodebuild && echo PRESENT || echo ABSENT"
  [[ "$output" == *ABSENT* ]] || false
  make_stub xcode-select 0 "$SANDBOX/Xcode.app/Contents/Developer"
  run lib "have xcodebuild && echo PRESENT || echo ABSENT"
  [[ "$output" == *PRESENT* ]] || false
}

@test "have: real installs elsewhere on PATH are never second-guessed" {
  make_stub python3
  run lib "have python3 && echo PRESENT"
  [[ "$output" == *PRESENT* ]] || false
}

@test "install_kind recognizes pipx and uv tool installs" {
  mkdir -p "$SANDBOX/pipx/venvs/poetry/bin" "$SANDBOX/uv/tools/ruff/bin" "$SANDBOX/bin"
  printf '#!/bin/sh\n' >"$SANDBOX/pipx/venvs/poetry/bin/poetry"
  printf '#!/bin/sh\n' >"$SANDBOX/uv/tools/ruff/bin/ruff"
  chmod 755 "$SANDBOX/pipx/venvs/poetry/bin/poetry" "$SANDBOX/uv/tools/ruff/bin/ruff"
  ln -s "$SANDBOX/pipx/venvs/poetry/bin/poetry" "$SANDBOX/bin/poetry"
  ln -s "$SANDBOX/uv/tools/ruff/bin/ruff" "$SANDBOX/bin/ruff"
  export PATH="$SANDBOX/bin:$PATH"
  [ "$(lib 'install_kind poetry')" = "pipx" ]
  [ "$(lib 'install_kind ruff')" = "uv" ]
  run lib "ai_self_update poetry poetry self update"
  [[ "$output" == *pipx-managed* ]] || false
}

@test "brew_cask_token finds the cask a CLI came from" {
  local pfx="$SANDBOX/brewpfx"
  mkdir -p "$pfx/bin" "$pfx/Caskroom/codex/0.160.0/bin"
  printf '#!/bin/sh\n' >"$pfx/Caskroom/codex/0.160.0/bin/codex"
  chmod 755 "$pfx/Caskroom/codex/0.160.0/bin/codex"
  ln -s ../Caskroom/codex/0.160.0/bin/codex "$pfx/bin/codex"
  export PATH="$pfx/bin:$PATH"
  [ "$(lib 'brew_cask_token codex')" = "codex" ]
  make_stub plain
  [ -z "$(lib 'brew_cask_token plain')" ]
}

@test "has_subcommand reads the CLI's help, never runs the subcommand" {
  printf '#!/bin/sh\nprintf "%%s %%s\\n" tool "$*" >>"$CALL_LOG"\n[ "$1" = --help ] && printf "Usage: tool [OPTIONS]\\nCommands:\\n  update    Update the tool\\n  exec      Run\\n"\nexit 0\n' >"$STUB_BIN/tool"
  chmod 755 "$STUB_BIN/tool"
  run lib "has_subcommand tool update && echo YES"
  [[ "$output" == *YES* ]] || false
  run lib "has_subcommand tool upgrade || echo NO"
  [[ "$output" == *NO* ]] || false
  refute grep -q '^tool update' "$CALL_LOG"
}

# ---------- settings & small utilities ----------

@test "setting: CMM_<KEY> beats the config file beats the default" {
  export CMM_CONFIG_FILE="$SANDBOX/config"
  printf 'MY_KEY=fromconfig\n' >"$CMM_CONFIG_FILE"
  [ "$(lib 'setting MY_KEY dflt')" = fromconfig ]
  [ "$(CMM_MY_KEY=fromenv lib 'setting MY_KEY dflt')" = fromenv ]
  [ "$(lib 'setting OTHER_KEY dflt')" = dflt ]
  [ "$(lib 'setting bad-key dflt')" = dflt ]
}

@test "cooldown_days sanitizes its input" {
  [ "$(CMM_COOLDOWN_DAYS=14 lib cooldown_days)" = 14 ]
  [ "$(CMM_COOLDOWN_DAYS=08 lib cooldown_days)" = 8 ]
  [ "$(CMM_COOLDOWN_DAYS=abc lib cooldown_days)" = 0 ]
  [ "$(lib cooldown_days)" = 0 ]
}

@test "cmm_json_str escapes quotes, backslashes and control characters" {
  [ "$(lib "cmm_json_str 'plain'")" = '"plain"' ]
  [ "$(lib "cmm_json_str 'a\"b\\c'")" = '"a\"b\\c"' ]
  [ "$(lib "cmm_json_str \"\$(printf 'x\\ty\\nz')\"")" = '"x\ty\nz"' ]
  [ "$(lib "cmm_json_str \"\$(printf 'bell\\007')\"")" = '"bell"' ]
}

@test "cmm_version_ge compares dotted versions numerically" {
  lib 'cmm_version_ge 1.3.0 1.3'
  lib 'cmm_version_ge 1.10.0 1.9.9'
  lib 'cmm_version_ge v2.0 1.99'
  refute lib 'cmm_version_ge 1.2.21 1.3'
  refute lib 'cmm_version_ge 0.0.396 0.1'
}

@test "cmm_iso_to_epoch parses RFC 3339 (with or without fractions)" {
  [ "$(lib 'cmm_iso_to_epoch 2026-01-02T03:04:05Z')" = 1767323045 ]
  [ "$(lib 'cmm_iso_to_epoch 2026-01-02T03:04:05.789Z')" = 1767323045 ]
  refute lib 'cmm_iso_to_epoch not-a-date'
}

@test "cmm_mtime and cmm_du_kb work on GNU and BSD userlands" {
  touch -t 202001020304 "$SANDBOX/old"
  local m
  m="$(lib "cmm_mtime '$SANDBOX/old'")"
  [[ "$m" =~ ^[0-9]+$ ]] || false
  [ "$m" -lt 1600000000 ]
  [ "$(lib "cmm_du_kb '$SANDBOX/missing'")" = 0 ]
}

@test "points_into matches links into a dir (incl. dangling and exact)" {
  mkdir -p "$SANDBOX/d"
  ln -s "$SANDBOX/d/gone" "$SANDBOX/l1"
  ln -s "$SANDBOX/d" "$SANDBOX/l2"
  ln -s "$SANDBOX/elsewhere" "$SANDBOX/l3"
  lib "points_into '$SANDBOX/l1' '$SANDBOX/d'"
  lib "points_into '$SANDBOX/l2' '$SANDBOX/d'"
  refute lib "points_into '$SANDBOX/l3' '$SANDBOX/d'"
  refute lib "points_into '$SANDBOX/d' '$SANDBOX/d'" # not a symlink
}

# ---------- dispatcher internals (lib/dispatch.sh) ----------

dlib() { bash -c ". '$CMM_LIB_PATH'; . '$REPO_ROOT/lib/dispatch.sh'; $1"; }

@test "the watchdog's deadline leaves a cleaner that already finished alone (no TIMEOUT marker)" {
  run dlib "cmm__watchdog_fire $(dead_pid) 0 '$SANDBOX/marker'"
  [ "$status" -eq 0 ]
  [ ! -e "$SANDBOX/marker" ]
}

@test "the watchdog's deadline marks a cleaner that is still running, and stops it" {
  hang_child
  "$SANDBOX/hangchild" >/dev/null 2>&1 3>&- &
  local pid=$!
  wait_for test -e "$SANDBOX/hangchild.ready"
  CMM__KILL_GRACE=1 run dlib "cmm__watchdog_fire $pid 0 '$SANDBOX/marker'"
  [ "$status" -eq 0 ]
  [ -e "$SANDBOX/marker" ]
  no_hang_child
}

@test "cleaner_name strips only an all-digit NN- prefix and the .sh suffix" {
  [ "$(dlib 'cleaner_name /x/10-homebrew.sh')" = homebrew ]
  [ "$(dlib 'cleaner_name /x/63-pre-commit.sh')" = pre-commit ]
  [ "$(dlib 'cleaner_name /x/1x-odd.sh')" = 1x-odd ]
  [ "$(dlib 'cleaner_name /x/plain.sh')" = plain ]
}

@test "cmm_suggest offers the closest name within a small edit distance" {
  [ "$(dlib 'cmm_suggest hombrew homebrew npm mise')" = homebrew ]
  [ "$(dlib 'cmm_suggest nmp homebrew npm mise')" = npm ]
  [ -z "$(dlib 'cmm_suggest xyzzyq homebrew npm mise')" ]
}

@test "cmm_setting_valid enforces each setting type" {
  dlib 'cmm_setting_valid int 42'
  refute dlib 'cmm_setting_valid int 4x'
  refute dlib 'cmm_setting_valid int 1234567890'
  dlib 'cmm_setting_valid bool 1'
  refute dlib 'cmm_setting_valid bool 2'
  dlib 'cmm_setting_valid interactive,always,never always'
  refute dlib 'cmm_setting_valid interactive,always,never sometimes'
  refute dlib 'cmm_setting_valid interactive,always,never ""'
}

@test "every built-in setting has a valid default" {
  run dlib 'for k in $(cmm_setting_keys); do cmm_setting_info "$k"; cmm_setting_valid "$CMM__S_TYPE" "$CMM__S_DEF" || echo "BAD $k"; done'
  [ "$status" -eq 0 ]
  [[ "$output" != *BAD* ]] || false
}
