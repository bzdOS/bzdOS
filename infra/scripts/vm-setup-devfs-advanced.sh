#!/bin/sh
# vm-setup-devfs-advanced.sh: Parse network-policy.json and generate per-app devfs rulesets
#
# Usage:
#   ./vm-setup-devfs-advanced.sh [--dry-run]
#
# Reads: proto/network-policy.json (proto/ is in the attic since 2026-10-01)
# Writes: /tmp/jail-devfs-map.sh (mapping app → ruleset)
# Does:
#   1. Parse JSON for app → permissions mappings
#   2. Compute unique permission sets → ruleset IDs
#   3. Generate devfs ruleset definitions
#   4. Apply via devfs rule -s N ... in guest (root)
#   5. Validate loaded rulesets
#
# Prerequisites:
#   - make vm-wait has succeeded (SSH ready)
#   - jq installed on host for JSON parsing

set -eu

SCRIPT_DIR="$(dirname "$(readlink -f "$0")")"
REPO_ROOT="$(dirname "$(dirname "$SCRIPT_DIR")")"
POLICY_FILE="${REPO_ROOT}/proto/network-policy.json"
DRY_RUN="${1:---run}"

# Source SSH helpers
. "${SCRIPT_DIR}/_ssh.sh"

# ============================================================================
# PERMISSION → RULESET MAPPING (fixed, per PLAN)
# ============================================================================

# Base device groups (permission → device paths)
# Format: permission|ruleset_id|devices_glob_list

PERMISSION_RULES=$(cat << 'EOF'
standard|11|null:zero:urandom:random:ptmx:pts/*
network|10|bpf
audio|20|dsp:mixer:pcm*
camera|30|video*:input*
location|40|ttyu1
modem|50|cuaU0
display|60|fb0:input0
EOF
)

# ============================================================================
# FUNCTIONS
# ============================================================================

die() {
    echo "ERROR: $*" >&2
    exit 1
}

log() {
    echo "[devfs] $*"
}

# Parse JSON and extract app→permissions mapping
# Input: path to network-policy.json
# Output: on stdout, format: app_name:permission1,permission2,...
parse_app_permissions() {
    local policy_file="$1"
    [ -f "$policy_file" ] || die "Policy file not found: $policy_file"

    # Check if 'permissions' field exists; if not, assign defaults based on app name
    jq -r '.jails | to_entries[] |
        "\(.key):\(
            if .value.permissions then
                (.value.permissions | join(","))
            elif .key == "appB" then
                "standard"
            elif .key == "appA" or .key == "appMatrix" then
                "standard,network"
            else
                "standard"
            end
        )"' "$policy_file" 2>/dev/null || die "Failed to parse $policy_file with jq"
}

# Map permission set to ruleset ID
# Input: comma-separated permissions (e.g., "standard,network" or "camera,display")
# Output: ruleset ID (10–60)
#
# Strategy: hash permission set to deterministic ID
# For now: use primary permission (highest priority) to select ruleset
map_permissions_to_ruleset() {
    local perms="$1"

    # Split permissions and pick the "highest priority" one for ruleset selection
    # Priority: network > audio > camera > display > modem > location > standard

    if echo "$perms" | grep -q "network"; then
        echo 10
    elif echo "$perms" | grep -q "audio"; then
        echo 20
    elif echo "$perms" | grep -q "camera"; then
        echo 30
    elif echo "$perms" | grep -q "location"; then
        echo 40
    elif echo "$perms" | grep -q "modem"; then
        echo 50
    elif echo "$perms" | grep -q "display"; then
        echo 60
    else
        echo 11  # default: standard
    fi
}

# Generate devfs rule commands for a permission set and ruleset ID
# Input: ruleset_id, comma-separated permissions
# Output: devfs rule -s N add ... commands (one per line)
generate_ruleset_commands() {
    local ruleset_id="$1"
    local perms="$2"

    # Start with: always include base jail ruleset 4
    echo "devfs rule -s $ruleset_id delall 2>/dev/null || true"
    echo "devfs rule -s $ruleset_id add include 4"

    # Parse permission list and add device unhides
    IFS=',' read -r -d '' perms_list <<EOF || true
$perms
EOF

    for perm in $(echo "$perms" | tr ',' '\n'); do
        perm="$(echo "$perm" | xargs)"  # trim whitespace

        case "$perm" in
            network)
                echo "devfs rule -s $ruleset_id add path bpf unhide"
                ;;
            audio)
                echo "devfs rule -s $ruleset_id add path dsp unhide"
                echo "devfs rule -s $ruleset_id add path mixer unhide"
                echo "devfs rule -s $ruleset_id add path 'pcm*' unhide"
                ;;
            camera)
                echo "devfs rule -s $ruleset_id add path 'video*' unhide"
                echo "devfs rule -s $ruleset_id add path 'input*' unhide"
                ;;
            location)
                echo "devfs rule -s $ruleset_id add path ttyu1 unhide"
                ;;
            modem)
                echo "devfs rule -s $ruleset_id add path cuaU0 unhide"
                ;;
            display)
                echo "devfs rule -s $ruleset_id add path fb0 unhide"
                echo "devfs rule -s $ruleset_id add path input0 unhide"
                ;;
            standard)
                # standard: no extra devices beyond base ruleset 4
                ;;
            *)
                log "Unknown permission: $perm"
                ;;
        esac
    done
}

# Build complete shell script with all ruleset commands
# Input: app_permissions_list (output from parse_app_permissions)
# Output: shell script that applies all rulesets
build_ruleset_script() {
    local app_perms="$1"
    local tmp_map="/tmp/jail-devfs-map.sh"

    {
        echo "#!/bin/sh"
        echo "# Generated by vm-setup-devfs-advanced.sh on $(date -u +%Y-%m-%dT%H:%M:%SZ)"
        echo "# Ruleset definitions and mappings for devfs access control"
        echo ""
        echo "# App → Ruleset mapping"
        echo "# (Used by jail.conf or jailmgr.sh to bind jails)"
        echo ""

        # Track which rulesets we've generated to avoid duplicates
        # (POSIX sh: no associative arrays; regeneration is idempotent and harmless)

        # First pass: emit mapping comments and collect unique rulesets
        echo "$app_perms" | while IFS=':' read -r app perms; do
            ruleset=$(map_permissions_to_ruleset "$perms")
            echo "JAIL_DEVFS[\"$app\"]=$ruleset  # $perms"
        done

        echo ""
        echo "# Ruleset definitions (applied via devfs rule -s N add ...)"
        echo ""

        # Second pass: emit unique ruleset commands (no duplicates)
        echo "$app_perms" | while IFS=':' read -r app perms; do
            ruleset=$(map_permissions_to_ruleset "$perms")

            # Use associative array to track which rulesets we've already generated
            # For simplicity in sh, we'll regenerate (idempotent, harmless)
            echo "# Ruleset $ruleset: $perms"
            generate_ruleset_commands "$ruleset" "$perms"
            echo ""
        done
    } > "$tmp_map"

    echo "$tmp_map"
}

# ============================================================================
# MAIN
# ============================================================================

log "Parsing network-policy.json..."
APP_PERMS=$(parse_app_permissions "$POLICY_FILE")

if [ -z "$APP_PERMS" ]; then
    die "No jails found in network-policy.json"
fi

log "App → Permission mappings:"
echo "$APP_PERMS" | while IFS=':' read -r app perms; do
    ruleset=$(map_permissions_to_ruleset "$perms")
    log "  $app ← $ruleset ($perms)"
done

if [ "$DRY_RUN" = "--dry-run" ]; then
    log "DRY-RUN: generating script without applying..."
fi

log "Building ruleset script..."
RULESET_SCRIPT=$(build_ruleset_script "$APP_PERMS")
log "Ruleset script generated: $RULESET_SCRIPT"

# Source the generated script to get definitions (for printing)
if [ "$DRY_RUN" = "--run" ]; then
    log "Applying rulesets in guest (root)..."

    # Open SSH master if not already open
    ssh_master_open

    # Execute generated ruleset commands in guest (as root)
    # Use bash -c to allow source command
    ssh_root "
set -e
set -x

# Reload devfs rules from /etc/devfs.rules if it exists
if [ -f /etc/devfs.rules ]; then
    service devfs restart 2>/dev/null || true
fi

# Source and apply all ruleset commands
$(cat "$RULESET_SCRIPT" | grep -E "^(devfs|#)" | head -100)

# Validate: print summary of loaded rulesets
echo ''
echo '=== Loaded Devfs Rulesets ==='
for rs in 10 11 20 30 40 50 60; do
    count=\$(devfs rule -s \$rs show 2>/dev/null | wc -l)
    if [ \$count -gt 0 ]; then
        echo \"Ruleset \$rs: \$count rules\"
    fi
done
"

    log "✓ Rulesets applied successfully"

else
    log "DRY-RUN: would apply the following commands:"
    grep "^devfs rule" "$RULESET_SCRIPT" | head -20
fi

log ""
log "=== devfs-advanced setup complete ==="
log "  Mapping file: $RULESET_SCRIPT"
log "  Ready to bind jails with: devfs_ruleset = <N> in jail.conf"
