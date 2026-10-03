# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# bash completion for scrubmac. Cleaner names come from `scrubmac list --names`.
# shellcheck shell=bash disable=SC2207  # COMPREPLY=($(compgen …)) is the idiom; mapfile is not bash 3.2

_scrubmac() {
  local cur prev cmd i
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD - 1]}"
  local commands="list status doctor configure enable disable config schedule last update version help"
  local options="--dry-run --quiet --update-only --clean-only --skip --measure --json --scheduled --help --version"

  cmd=""
  for ((i = 1; i < COMP_CWORD; i++)); do
    case "${COMP_WORDS[i]}" in
      -*) ;;
      *)
        cmd="${COMP_WORDS[i]}"
        break
        ;;
    esac
  done

  if [ "$prev" = "--skip" ]; then
    COMPREPLY=($(compgen -W "$(scrubmac list --names 2>/dev/null)" -- "$cur"))
    return 0
  fi

  case "$cmd" in
    enable | disable | status)
      COMPREPLY=($(compgen -W "$(scrubmac list --names 2>/dev/null)" -- "$cur"))
      ;;
    config)
      COMPREPLY=($(compgen -W "list get set unset path $(scrubmac config 2>/dev/null | awk 'NR > 1 && $1 ~ /^[A-Z]/ { print $1 }')" -- "$cur"))
      ;;
    schedule)
      COMPREPLY=($(compgen -W "status daily weekly off mon tue wed thu fri sat sun" -- "$cur"))
      ;;
    list) COMPREPLY=($(compgen -W "--names" -- "$cur")) ;;
    update) COMPREPLY=($(compgen -W "--check" -- "$cur")) ;;
    last) COMPREPLY=($(compgen -W "--json" -- "$cur")) ;;
    "")
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "$options" -- "$cur"))
      else
        COMPREPLY=($(compgen -W "$commands $(scrubmac list --names 2>/dev/null)" -- "$cur"))
      fi
      ;;
    *)
      # a run naming cleaners
      if [[ "$cur" == -* ]]; then
        COMPREPLY=($(compgen -W "$options" -- "$cur"))
      else
        COMPREPLY=($(compgen -W "$(scrubmac list --names 2>/dev/null)" -- "$cur"))
      fi
      ;;
  esac
  return 0
}
complete -F _scrubmac scrubmac
