# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# bash completion for scrubmac. Cleaner names come from `scrubmac list --names`.
# shellcheck shell=bash disable=SC2207  # COMPREPLY=($(compgen …)) is the idiom; mapfile is not bash 3.2

_scrubmac() {
  local cur prev cmd i ci=0
  COMPREPLY=()
  cur="${COMP_WORDS[COMP_CWORD]}"
  prev="${COMP_WORDS[COMP_CWORD - 1]}"
  local commands="run list status doctor configure enable disable config schedule last update version help"
  local options="--dry-run --quiet --update-only --clean-only --skip --measure --json --scheduled --help --version"

  # the command word, and the arguments typed after it (before the cursor)
  cmd=""
  for ((i = 1; i < COMP_CWORD; i++)); do
    case "${COMP_WORDS[i]}" in
      -*) ;;
      *)
        [ "${COMP_WORDS[i - 1]}" = --skip ] && continue
        cmd="${COMP_WORDS[i]}"
        ci=$i
        break
        ;;
    esac
  done
  local nargs=0 first=""
  if [ -n "$cmd" ]; then
    nargs=$((COMP_CWORD - ci - 1))
    [ "$nargs" -gt 0 ] && first="${COMP_WORDS[ci + 1]}"
  fi

  if [ "$prev" = "--skip" ]; then
    COMPREPLY=($(compgen -W "$(scrubmac list --names 2>/dev/null)" -- "$cur"))
    return 0
  fi

  case "$cmd" in
    run | enable | disable | status)
      COMPREPLY=($(compgen -W "$(scrubmac list --names 2>/dev/null)" -- "$cur"))
      ;;
    config)
      if [ "$nargs" -eq 0 ]; then
        COMPREPLY=($(compgen -W "list get set unset path" -- "$cur"))
      elif [ "$nargs" -eq 1 ]; then
        case "$first" in
          get | set | unset)
            COMPREPLY=($(compgen -W "$(scrubmac config list 2>/dev/null | awk 'NR > 1 && $1 ~ /^[A-Z][A-Z0-9_]*$/ { print $1 }')" -- "$cur"))
            ;;
        esac
      fi
      ;;
    schedule)
      if [ "$nargs" -eq 0 ]; then
        COMPREPLY=($(compgen -W "status daily weekly off" -- "$cur"))
      elif [ "$nargs" -eq 1 ] && [ "$first" = weekly ]; then
        COMPREPLY=($(compgen -W "mon tue wed thu fri sat sun" -- "$cur"))
      fi
      ;;
    list) [ "$nargs" -eq 0 ] && COMPREPLY=($(compgen -W "--names" -- "$cur")) ;;
    update) [ "$nargs" -eq 0 ] && COMPREPLY=($(compgen -W "--check" -- "$cur")) ;;
    last) [ "$nargs" -eq 0 ] && COMPREPLY=($(compgen -W "--json" -- "$cur")) ;;
    doctor | configure | version | help) ;;
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
