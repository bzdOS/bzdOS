#!/bin/sh
# vm-restore-backup.sh — restore ZFS backup to guest
#
# Usage:
#   make vm-restore-backup BACKUP_FILE=/tmp/bsdos-backup-1234567890.zfs [FORCE=1]
#
# Environment:
#   BACKUP_FILE — path to .zfs file (required)
#   FORCE       — if 1, use zfs recv -F (destructive, overwrites existing)
#
# Notes:
#   - Restores entire bsdos/data tree (all jails + system datasets)
#   - If dataset already exists, use FORCE=1 to replace
#   - After restore, run: make jail-setup to reconfigure app environments
#
set -eu

. "$(dirname "$0")/_ssh.sh"

: "${BACKUP_FILE:=}"
: "${FORCE:=0}"

# Logging
log_info() {
    echo "[restore] $(date +'%Y-%m-%d %H:%M:%S') $*"
}

log_err() {
    echo "[restore:ERR] $(date +'%Y-%m-%d %H:%M:%S') $*" >&2
}

log_warn() {
    echo "[restore:WARN] $(date +'%Y-%m-%d %H:%M:%S') $*" >&2
}

# Validate input
if [ -z "${BACKUP_FILE}" ]; then
    log_err "BACKUP_FILE not specified"
    log_err "Usage: make vm-restore-backup BACKUP_FILE=/tmp/bsdos-backup-*.zfs"
    exit 1
fi

if [ ! -f "${BACKUP_FILE}" ]; then
    log_err "Backup file not found: ${BACKUP_FILE}"
    exit 1
fi

BACKUP_SIZE=$(ls -lh "${BACKUP_FILE}" | awk '{print $5}')
log_info "Backup file: ${BACKUP_FILE} (${BACKUP_SIZE})"

# Verify guest is reachable
log_info "Verifying SSH connection to guest..."
if ! ssh_guest "echo ok" >/dev/null 2>&1; then
    log_err "Cannot reach guest at localhost:${VM_SSH_PORT}"
    log_err "Run: make vm-wait"
    exit 1
fi
log_info "SSH connection OK"

# Check if bsdos/data already exists
log_info "Checking existing datasets..."
if ssh_root "zfs list -H bsdos/data" >/dev/null 2>&1; then
    if [ "${FORCE}" = "1" ]; then
        log_warn "Dataset bsdos/data exists, FORCE=1 — will overwrite (DESTRUCTIVE!)"
        RECV_OPTS="-F"
    else
        log_err "Dataset bsdos/data already exists"
        log_err "To replace it, use: make vm-restore-backup BACKUP_FILE=... FORCE=1"
        log_err "(Warning: this destroys existing data)"
        exit 1
    fi
else
    log_info "Dataset bsdos/data does not exist, will create new"
    RECV_OPTS=""
fi

# Prepare backup stream
log_info "Streaming backup to guest (this may take several minutes)..."
log_info "Please be patient..."

# Use ssh to pipe backup file to zfs recv on guest
if cat "${BACKUP_FILE}" | ssh_root "zfs recv ${RECV_OPTS} bsdos/data"; then
    log_info "Backup restored successfully"
else
    log_err "Failed to restore backup"
    exit 1
fi

# Verify restored datasets
log_info "Verifying restored datasets..."
log_info "Datasets in bsdos/data:"
ssh_root "zfs list -r bsdos/data | grep -v '^NAME'" | sed 's/^/  /'

# List snapshots
log_info "Snapshots in restored backup:"
ssh_root "zfs list -H -t snapshot -r bsdos/data | head -5" | sed 's/^/  /'

log_info ""
log_info "=== Restore completed ==="
log_info ""
log_info "Next steps:"
log_info "1. Verify data integrity:"
log_info "   make vm-ssh"
log_info "   zfs check bsdos/data"
log_info ""
log_info "2. Reconfigure jails:"
log_info "   make jail-setup"
log_info ""
log_info "3. Start jail services:"
log_info "   make demo"
log_info ""
