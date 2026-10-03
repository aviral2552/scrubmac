# Part of scrubmac — Copyright (C) 2018-2026 Aviral Sharma.
# Licensed GPL-3.0-only with an additional attribution term under
# GPLv3 section 7(b) — see the LICENSE and NOTICE files at the project root.
# fish completion for scrubmac. Cleaner names come from `scrubmac list --names`.

set -l commands list status doctor configure enable disable config schedule last update version help

function __scrubmac_cleaners
    scrubmac list --names 2>/dev/null
end

complete -c scrubmac -f
complete -c scrubmac -s n -l dry-run -d 'print every command; change nothing'
complete -c scrubmac -s q -l quiet -d 'hide cleaner output unless it fails'
complete -c scrubmac -l update-only -d 'only update tools'
complete -c scrubmac -l clean-only -d 'only clean caches'
complete -c scrubmac -l skip -x -a '(__scrubmac_cleaners)' -d 'leave a cleaner out of this run'
complete -c scrubmac -l measure -d 'report the space each cleaner frees'
complete -c scrubmac -l json -d 'machine-readable summary on stdout'
complete -c scrubmac -l scheduled -d 'unattended run'
complete -c scrubmac -s h -l help -d 'show help'
complete -c scrubmac -s V -l version -d 'print the version'

complete -c scrubmac -n "not __fish_seen_subcommand_from $commands" -a "$commands"
complete -c scrubmac -n "not __fish_seen_subcommand_from $commands" -a '(__scrubmac_cleaners)'
complete -c scrubmac -n '__fish_seen_subcommand_from enable disable status' -a '(__scrubmac_cleaners)'
complete -c scrubmac -n '__fish_seen_subcommand_from config' -a 'list get set unset path'
complete -c scrubmac -n '__fish_seen_subcommand_from schedule' -a 'status daily weekly off mon tue wed thu fri sat sun'
complete -c scrubmac -n '__fish_seen_subcommand_from list' -a '--names'
complete -c scrubmac -n '__fish_seen_subcommand_from update' -a '--check'
complete -c scrubmac -n '__fish_seen_subcommand_from last' -a '--json'
