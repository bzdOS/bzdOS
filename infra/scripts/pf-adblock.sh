#!/bin/sh
# bsdOS PF-based adblock for tracker/ad filtering.
# Usage: pf-adblock.sh {setup|update|enable|disable|status}
#
# MAKE-TARGETS ##
# pf-adblock-setup:   $(SCRIPTS)/pf-adblock.sh setup
# pf-adblock-update:  $(SCRIPTS)/pf-adblock.sh update
# pf-adblock-enable:  $(SCRIPTS)/pf-adblock.sh enable
# pf-adblock-disable: $(SCRIPTS)/pf-adblock.sh disable
# pf-adblock-status:  $(SCRIPTS)/pf-adblock.sh status
# END-MAKE-TARGETS ##

set -eu

SCRIPTS_DIR="$(dirname "$0")"
. "$SCRIPTS_DIR/_agent.sh"

# Paths inside VM
ADBLOCK_IPS="/tmp/adblock-ips.txt"
ADBLOCK_HOSTS="/etc/adblock-hosts.txt"
ADBLOCK_TIMESTAMP="/var/lib/bsdos/adblock.timestamp"

# Sources
FIREHOL_BLOCKLIST="https://raw.githubusercontent.com/firehol/blocklist-ipsets/master/firehol_level1.netset"
STEVEN_BLACK_HOSTS="https://raw.githubusercontent.com/StevenBlack/hosts/master/hosts"

# ============================================================================
# Helper: Execute command in VM as root via agent
# ============================================================================
run_in_vm() {
    agent_exec "$@" || return 1
}

# ============================================================================
# Step 1: Download blocklist (IP-based from FireHOL)
# ============================================================================
pf_adblock_setup() {
    echo "[pf-adblock] Setting up PF adblock..."

    # Create directories inside VM
    run_in_vm "mkdir -p /var/lib/bsdos /tmp"

    # Download FireHOL level1 blocklist (already in CIDR/IP format)
    echo "[pf-adblock] Downloading FireHOL blocklist..."
    run_in_vm "curl -sSL '$FIREHOL_BLOCKLIST' -o /tmp/firehol-raw.netset"

    # Parse: skip comments, extract valid IPs/CIDR, ignore private ranges
    # Format: one IP or CIDR per line
    run_in_vm "cat > '$ADBLOCK_IPS' << 'EOFIPS'
# bsdOS PF adblock table - generated from FireHOL level1
# Do not edit manually; use pf-adblock.sh update
EOFIPS"

    run_in_vm "grep -vE '^#|^[[:space:]]*$|^127\.|^10\.|^172\.1[6-9]\.|^172\.2[0-9]\.|^172\.3[01]\.|^192\.168\.' /tmp/firehol-raw.netset >> '$ADBLOCK_IPS'"

    # Load into PF table
    run_in_vm "pfctl -t adblock -T flush 2>/dev/null || true"
    run_in_vm "pfctl -t adblock -T replace -f '$ADBLOCK_IPS'"

    # Record timestamp
    run_in_vm "date > '$ADBLOCK_TIMESTAMP'"

    local count
    count=$(run_in_vm "wc -l < '$ADBLOCK_IPS'" | tr -d ' ')
    echo "[pf-adblock] Setup complete. Loaded $count rules."
}

# ============================================================================
# Step 2: Update blocklist (re-download and reload)
# ============================================================================
pf_adblock_update() {
    echo "[pf-adblock] Updating blocklist..."

    run_in_vm "curl -sSL '$FIREHOL_BLOCKLIST' -o /tmp/firehol-raw.netset"

    # Re-parse and rebuild
    run_in_vm "cat > '$ADBLOCK_IPS' << 'EOFIPS'
# bsdOS PF adblock table - updated $(date)
EOFIPS"

    run_in_vm "grep -vE '^#|^[[:space:]]*$|^127\.|^10\.|^172\.1[6-9]\.|^172\.2[0-9]\.|^172\.3[01]\.|^192\.168\.' /tmp/firehol-raw.netset >> '$ADBLOCK_IPS'"

    # Reload PF table
    run_in_vm "pfctl -t adblock -T replace -f '$ADBLOCK_IPS'"

    run_in_vm "date > '$ADBLOCK_TIMESTAMP'"

    local count
    count=$(run_in_vm "wc -l < '$ADBLOCK_IPS'" | tr -d ' ')
    echo "[pf-adblock] Update complete. Loaded $count rules."
}

# ============================================================================
# Step 3: Enable adblock (add rules to active PF)
# ============================================================================
pf_adblock_enable() {
    echo "[pf-adblock] Enabling adblock rules..."

    # Ensure table exists with current data
    run_in_vm "pfctl -t adblock -T replace -f '$ADBLOCK_IPS' 2>/dev/null || {
        echo 'WARN: Could not replace table; assuming already loaded'
    }"

    echo "[pf-adblock] Adblock enabled."
}

# ============================================================================
# Step 4: Disable adblock (flush PF table)
# ============================================================================
pf_adblock_disable() {
    echo "[pf-adblock] Disabling adblock rules..."

    run_in_vm "pfctl -t adblock -T flush"

    echo "[pf-adblock] Adblock disabled (table flushed)."
}

# ============================================================================
# Step 5: Status (show rule count + last update)
# ============================================================================
pf_adblock_status() {
    echo "[pf-adblock] Status:"

    local count
    count=$(run_in_vm "pfctl -t adblock -T show | wc -l" 2>/dev/null || echo "0")
    count=$(echo "$count" | tr -d ' ')
    echo "  Active rules in PF table: $count"

    local timestamp
    timestamp=$(run_in_vm "test -f '$ADBLOCK_TIMESTAMP' && cat '$ADBLOCK_TIMESTAMP' || echo 'Never'" 2>/dev/null)
    echo "  Last update: $timestamp"

    local file_count
    file_count=$(run_in_vm "test -f '$ADBLOCK_IPS' && wc -l < '$ADBLOCK_IPS' || echo '0'" 2>/dev/null | tr -d ' ')
    echo "  Rules in file: $file_count"
}

# ============================================================================
# Main
# ============================================================================
cmd="${1:-status}"

case "$cmd" in
    setup)
        pf_adblock_setup
        ;;
    update)
        pf_adblock_update
        ;;
    enable)
        pf_adblock_enable
        ;;
    disable)
        pf_adblock_disable
        ;;
    status)
        pf_adblock_status
        ;;
    *)
        echo "Usage: $0 {setup|update|enable|disable|status}" >&2
        exit 1
        ;;
esac
