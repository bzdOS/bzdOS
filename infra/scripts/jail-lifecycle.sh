#!/bin/sh
# Jail lifecycle management: freeze, thaw, status, list-frozen
# Commands: freeze JAIL, thaw JAIL, status JAIL, list-frozen
# Integrates with agent_freeze/agent_thaw from _agent.sh

## MAKE-TARGETS ##
# jail-freeze: JAIL=$(JAIL) $(SCRIPTS)/jail-lifecycle.sh freeze $(JAIL)
# jail-thaw:   JAIL=$(JAIL) $(SCRIPTS)/jail-lifecycle.sh thaw $(JAIL)
# jail-lifecycle-status: JAIL=$(JAIL) $(SCRIPTS)/jail-lifecycle.sh status $(JAIL)
## END-MAKE-TARGETS ##

set -eu
. "$(dirname "$0")/_agent.sh"

# Print usage and exit with error code
usage() {
    cat >&2 <<EOF
Usage: $(basename "$0") <command> [args]

Commands:
  freeze JAIL            Freeze all processes in JAIL (SIGSTOP)
  thaw JAIL              Thaw all processes in JAIL (SIGCONT)
  status JAIL            Show jail status and count of frozen processes
  list-frozen            List all jails with frozen processes

EOF
    exit 1
}

# Freeze a jail: send SIGSTOP to all processes
cmd_freeze() {
    local jail="${1:?}"
    echo "Freezing jail: $jail"
    if ! agent_check_jail "$jail"; then
        echo "ERROR: jail '$jail' not found"
        exit 1
    fi
    agent_freeze "$jail"
    echo "Jail $jail frozen"
}

# Thaw a jail: send SIGCONT to all processes
cmd_thaw() {
    local jail="${1:?}"
    echo "Thawing jail: $jail"
    if ! agent_check_jail "$jail"; then
        echo "ERROR: jail '$jail' not found"
        exit 1
    fi
    agent_thaw "$jail"
    echo "Jail $jail thawed"
}

# Show status: jail exists + count T-state (stopped) processes
cmd_status() {
    local jail="${1:?}"

    echo "Status for jail: $jail"

    if ! agent_check_jail "$jail"; then
        echo "ERROR: jail '$jail' not found"
        exit 1
    fi

    echo "Jail exists: yes"

    # Count T-state processes via agent_exec
    # ps -J jail_name outputs processes, grep T counts stopped ones
    local frozen_count
    frozen_count=$(agent_exec "ps -J '$jail' 2>/dev/null | awk 'NR>1' | awk '{print \$2}' | xargs -I {} ps -p {} -o state= 2>/dev/null | grep -c T || echo 0" 30)

    # Extract the number (last line of agent output)
    frozen_count=$(printf '%s\n' "$frozen_count" | tail -1 | tr -d ' ')

    echo "Frozen processes: $frozen_count"
}

# List all jails with at least one T-state process
cmd_list_frozen() {
    echo "Jails with frozen processes:"

    # Get all jails via agent_jls
    local jails_output
    jails_output=$(agent_jls 2>/dev/null || echo "")

    if [ -z "$jails_output" ]; then
        echo "  (no jails found)"
        return 0
    fi

    # For each jail name, check if it has T-state processes
    printf '%s\n' "$jails_output" | while read -r line; do
        # Extract jail name (appears after whitespace in jls output)
        local jail_name
        jail_name=$(printf '%s\n' "$line" | awk '{for(i=1;i<=NF;i++) if($i ~ /^[a-zA-Z0-9_-]+$/) {print $i; exit}}')

        if [ -z "$jail_name" ]; then
            continue
        fi

        # Count frozen processes for this jail
        local frozen_count
        frozen_count=$(agent_exec "ps -J '$jail_name' 2>/dev/null | awk 'NR>1' | awk '{print \$2}' | xargs -I {} ps -p {} -o state= 2>/dev/null | grep -c T || echo 0" 30)
        frozen_count=$(printf '%s\n' "$frozen_count" | tail -1 | tr -d ' ')

        # Only show if count > 0
        if [ "$frozen_count" -gt 0 ] 2>/dev/null; then
            printf '  %s: %d frozen\n' "$jail_name" "$frozen_count"
        fi
    done
}

# Main dispatcher
main() {
    if [ $# -lt 1 ]; then
        usage
    fi

    local cmd="$1"
    shift

    case "$cmd" in
        freeze)
            if [ $# -lt 1 ]; then usage; fi
            cmd_freeze "$@"
            ;;
        thaw)
            if [ $# -lt 1 ]; then usage; fi
            cmd_thaw "$@"
            ;;
        status)
            if [ $# -lt 1 ]; then usage; fi
            cmd_status "$@"
            ;;
        list-frozen)
            cmd_list_frozen
            ;;
        *)
            echo "ERROR: unknown command '$cmd'"
            usage
            ;;
    esac
}

main "$@"
