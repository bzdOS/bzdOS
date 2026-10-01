#!/bin/sh
# bsdOS Beastie Tamagotchi system monitor
# Real-time ASCII-art Beastie with live system metrics from FreeBSD VM
# Runs on host, fetches metrics via agent_exec
#
## MAKE-TARGETS ##
# beastie: $(SCRIPTS)/beastie.sh
## END-MAKE-TARGETS ##

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
. "$SCRIPT_DIR/_agent.sh"

# Defaults and constants
UPDATE_INTERVAL=2
AGENT_EXEC_TIMEOUT=3
VM_OFFLINE_MARKER="VM_OFFLINE"

# ASCII Beastie art (10 lines)
beastie_art() {
    cat << 'EOF'
   ,        ,
  /(        )`
  \ \___   / |
  /- _  `-/  '
 (/\/ \ \   /\
 / /   | `    \
 O O   ) /    |
 `-^--'`<     '
(_.)  _  )   /
 `.___/`    /
EOF
}

# Fetch CPU load average (three values)
get_cpu_load() {
    agent_exec sysctl -n vm.loadavg 2>/dev/null | \
        awk '{print $1, $2, $3}' || echo "$VM_OFFLINE_MARKER"
}

# Fetch RAM: total and free (in bytes, convert to GB)
get_ram_status() {
    total_bytes=$(agent_exec sysctl -n hw.physmem 2>/dev/null || echo "$VM_OFFLINE_MARKER")
    if [ "$total_bytes" = "$VM_OFFLINE_MARKER" ]; then
        echo "$VM_OFFLINE_MARKER"
        return
    fi

    free_pages=$(agent_exec vmstat -s 2>/dev/null | grep "pages free" | awk '{print $1}' || echo "0")

    # Convert to GB (1 page = 4096 bytes on most systems)
    if [ "$free_pages" -eq 0 ] 2>/dev/null || [ "$free_pages" = "0" ]; then
        free_bytes=0
    else
        free_bytes=$((free_pages * 4096))
    fi

    total_gb=$((total_bytes / 1073741824))
    free_gb=$((free_bytes / 1073741824))
    used_gb=$((total_gb - free_gb))

    printf "%d.%dG / %d.%dG" "$used_gb" $((used_bytes=total_bytes/1073741824; (total_bytes - free_bytes) % 1073741824 / 107374182)) "$total_gb" 0
}

# Simpler RAM status (used / total in GB)
get_ram_status_simple() {
    local result
    result=$(agent_exec sysctl -n hw.physmem 2>/dev/null || echo "$VM_OFFLINE_MARKER")
    if [ "$result" = "$VM_OFFLINE_MARKER" ]; then
        echo "$VM_OFFLINE_MARKER"
        return
    fi

    # Extract total in bytes
    total_bytes="$result"
    total_gb=$((total_bytes / 1073741824))

    # Get free pages
    free_pages=$(agent_exec vmstat -s 2>/dev/null | grep "pages free" | awk '{print $1}' || echo "0")
    free_bytes=$((free_pages * 4096))
    used_bytes=$((total_bytes - free_bytes))
    used_gb=$((used_bytes / 1073741824))
    used_decimal=$(((used_bytes % 1073741824) / 107374182))

    if [ "$used_decimal" -lt 10 ]; then
        printf "%d.%dG / %d.0G" "$used_gb" "$used_decimal" "$total_gb"
    else
        printf "%d.%dG / %d.0G" "$used_gb" "$used_decimal" "$total_gb"
    fi
}

# Fetch jail count
get_jail_count() {
    agent_exec jls 2>/dev/null | wc -l || echo "$VM_OFFLINE_MARKER"
}

# Fetch uptime
get_uptime() {
    agent_exec uptime 2>/dev/null | sed 's/.*up //' | sed 's/,.*//' || echo "$VM_OFFLINE_MARKER"
}

# Check Wayland stack status
get_wayland_status() {
    agent_exec pgrep -q cage 2>/dev/null && echo "UP" || echo "DOWN"
}

# Render the display
render_display() {
    local cpu_load="$1"
    local ram_status="$2"
    local jail_count="$3"
    local uptime="$4"
    local wayland="$5"

    # Handle offline VM
    if [ "$cpu_load" = "$VM_OFFLINE_MARKER" ]; then
        cpu_load="offline"
        ram_status="offline"
        jail_count="offline"
        uptime="offline"
        wayland="offline"
    fi

    # Format CPU load with padding
    cpu_display="$cpu_load     "
    cpu_display="${cpu_display%     }"  # trim right

    # Format jail count with padding
    jail_display="$jail_count running     "
    jail_display="${jail_display%     }"

    cat << EOF
╔══════════════════════════════════════╗
║  bsdOS Beastie v0.1                  ║
╠══════════════════════════════════════╣
║   ,        ,    CPU:  $cpu_display║
║  /(        )\`   RAM:  $ram_status║
║  \ \___   / |   Jails: $jail_display║
║  /- _  \`-/  '   Wayland: $wayland║
║ (/\/ \ \   /\   Uptime: $uptime║
║ / /   | \`    \  │
║ O O   ) /    |  │
║ \`-^--'\`<     '  │
║(_.)  _  )   /   │
║ \`.___/\`    /    │
╚══════════════════════════════════════╝
EOF
}

# Main loop
main() {
    # Hide cursor
    tput civis 2>/dev/null || true

    # Trap for cleanup
    trap 'tput cnorm 2>/dev/null || true; exit' INT TERM EXIT

    while true; do
        # Collect metrics (with timeout)
        cpu_load=$(get_cpu_load)
        ram_status=$(get_ram_status_simple)
        jail_count=$(get_jail_count)
        uptime=$(get_uptime)
        wayland=$(get_wayland_status)

        # Clear screen and render
        clear
        render_display "$cpu_load" "$ram_status" "$jail_count" "$uptime" "$wayland"

        # Sleep before next update
        sleep "$UPDATE_INTERVAL"
    done
}

main
