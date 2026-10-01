#!/bin/sh
# vm-backup.sh — create ZFS snapshot + send to local file
#
# Usage:
#   make vm-backup NAME=daily
#   make vm-backup NAME=appA-20260606
#
# Output:
#   /tmp/bsdos-backup-${TIMESTAMP}.zfs
#   /tmp/bsdos-backup-${TIMESTAMP}.metadata.json
#
# Prerequisites:
#   - Guest must be running (make vm-wait)
#   - Dataset: bsdos/data must exist
#
set -eu

. "$(dirname "$0")/_ssh.sh"

: "${NAME:=daily}"

# Logging
log_info() {
    echo "[backup] $(date +'%Y-%m-%d %H:%M:%S') $*"
}

log_err() {
    echo "[backup:ERR] $(date +'%Y-%m-%d %H:%M:%S') $*" >&2
}

# Verify guest is reachable
log_info "Verifying SSH connection to guest..."
if ! ssh_guest "echo ok" >/dev/null 2>&1; then
    log_err "Cannot reach guest at localhost:${VM_SSH_PORT}"
    log_err "Run: make vm-wait"
    exit 1
fi
log_info "SSH connection OK"

# Verify ZFS dataset exists
log_info "Checking ZFS dataset bsdos/data..."
if ! ssh_root "zfs list -H bsdos/data" >/dev/null 2>&1; then
    log_err "Dataset bsdos/data not found"
    log_err "Run: make vm-setup-jail"
    exit 1
fi
log_info "ZFS dataset OK"

# Generate snapshot name
TIMESTAMP=$(date +%s)
SNAP_NAME="backup-${NAME}-${TIMESTAMP}"
SNAP_PATH="bsdos/data@${SNAP_NAME}"
BACKUP_FILE="/tmp/bsdos-backup-${TIMESTAMP}.zfs"
METADATA_FILE="/tmp/bsdos-backup-${TIMESTAMP}.metadata.json"

log_info "Creating snapshot: ${SNAP_PATH}"

# Create recursive snapshot (all datasets under bsdos/data)
if ! ssh_root "zfs snapshot -r '${SNAP_PATH}'" >/dev/null 2>&1; then
    log_err "Failed to create snapshot ${SNAP_PATH}"
    exit 1
fi
log_info "Snapshot created: ${SNAP_PATH}"

# Get snapshot size estimate
log_info "Calculating snapshot size..."
SNAP_SIZE=$(ssh_root "zfs list -H -o used '${SNAP_PATH}'" | awk '{print $1}')
log_info "Snapshot size: ${SNAP_SIZE}"

# Send snapshot to local file
log_info "Sending snapshot to ${BACKUP_FILE}..."
log_info "(This may take several seconds for large datasets)"

if ! ssh_root "zfs send -R '${SNAP_PATH}'" 2>/dev/null > "${BACKUP_FILE}"; then
    log_err "Failed to send snapshot"
    rm -f "${BACKUP_FILE}"
    exit 1
fi

BACKUP_SIZE=$(ls -lh "${BACKUP_FILE}" | awk '{print $5}')
log_info "Backup written: ${BACKUP_FILE} (${BACKUP_SIZE})"

# Create metadata file
log_info "Writing metadata..."
cat > "${METADATA_FILE}" <<EOF
{
  "name": "${NAME}",
  "timestamp": ${TIMESTAMP},
  "snapshot": "${SNAP_PATH}",
  "dataset": "bsdos/data",
  "size_bytes": $(stat -f%z "${BACKUP_FILE}" 2>/dev/null || echo 0),
  "size_human": "${BACKUP_SIZE}",
  "hostname": "$(ssh_guest hostname)",
  "date": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')",
  "backup_file": "${BACKUP_FILE}",
  "restore_cmd": "zfs recv -F bsdos/data < ${BACKUP_FILE}"
}
EOF

log_info "Metadata written: ${METADATA_FILE}"

# List recent snapshots on guest
log_info "Recent snapshots on guest:"
ssh_root "zfs list -H -t snapshot -r bsdos/data | sort -k4 -r | head -5" | sed 's/^/  /'

# Cleanup old snapshots (keep last 7)
log_info "Cleaning up snapshots (keeping last 7)..."
SNAPS_TO_KEEP=7
SNAP_COUNT=$(ssh_root "zfs list -H -t snapshot -r bsdos/data | wc -l")

if [ "$SNAP_COUNT" -gt "$SNAPS_TO_KEEP" ]; then
    SNAPS_TO_DELETE=$((SNAP_COUNT - SNAPS_TO_KEEP))
    log_info "Removing ${SNAPS_TO_DELETE} old snapshots (${SNAP_COUNT} total, keeping ${SNAPS_TO_KEEP})"

    ssh_root "zfs list -H -t snapshot -r bsdos/data | sort -k4 | head -${SNAPS_TO_DELETE} | awk '{print \$1}' | xargs -I {} zfs destroy {}" || {
        log_err "Warning: failed to cleanup some snapshots (non-fatal)"
    }
    log_info "Cleanup complete"
else
    log_info "Snapshot count OK (${SNAP_COUNT}/${SNAPS_TO_KEEP})"
fi

# Final verification
log_info "Verifying backup file..."
if [ ! -f "${BACKUP_FILE}" ] || [ ! -f "${METADATA_FILE}" ]; then
    log_err "Backup or metadata file missing"
    exit 1
fi

log_info "=== Backup completed successfully ==="
log_info "Backup file: ${BACKUP_FILE}"
log_info "Metadata:    ${METADATA_FILE}"
log_info ""
log_info "To restore (on guest or another host):"
log_info "  zfs recv -F bsdos/data < ${BACKUP_FILE}"
log_info ""
log_info "To view metadata:"
log_info "  cat ${METADATA_FILE} | jq ."
log_info ""
