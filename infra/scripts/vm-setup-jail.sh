#!/bin/sh
set -eu

. "$(dirname "$0")/_ssh.sh"

# ============================================================================
# Phase 1: ZFS detection & conditional bootstrap
# ============================================================================

ZFS_MODE=0
if ssh_root "zpool list bsdos >/dev/null 2>&1"; then
    ZFS_MODE=1
    echo "[ZFS] Pool 'bsdos' detected — using ZFS clone mode"
else
    echo "[nullfs] No ZFS pool — using bind mount mode"
fi

echo "Setting up jail runtime directories..."

if [ "$ZFS_MODE" -eq 1 ]; then
    # ZFS mode: create datasets and extract base to ZFS filesystem
    echo "Creating ZFS datasets..."
    ssh_root "
        zfs create -p bsdos/apps 2>/dev/null || true
        zfs create -p bsdos/data 2>/dev/null || true
        zfs create -p bsdos/bus 2>/dev/null || true
        zfs list -H -o name | grep -q '^bsdos/base$' || zfs create bsdos/base
    "
    ZFS_BASE_PATH="/bsdos/base"
    ssh_root "mkdir -p /opt/proto/app"  # staging dir for proto-app binary inside guest
else
    # nullfs mode: traditional directory layout
    ssh_root "mkdir -p /opt/proto/base /opt/proto/app /opt/proto/data /opt/proto/bus"
    ZFS_BASE_PATH="/opt/proto/base"
fi

echo "Downloading base.txz..."
# Определяем архитектуру и скачиваем нужный base.txz
ssh_root 'REL=$(freebsd-version -u | sed "s/-p.*//")
ARCH=$(uname -m)
case "$ARCH" in
  amd64)   URL="https://download.freebsd.org/releases/amd64/amd64/${REL}/base.txz" ;;
  aarch64) URL="https://download.freebsd.org/releases/arm64/aarch64/${REL}/base.txz" ;;
  riscv64) URL="https://download.freebsd.org/releases/riscv/riscv64/${REL}/base.txz" ;;
  *)       URL="https://download.freebsd.org/releases/amd64/amd64/${REL}/base.txz" ;;
esac
echo "Fetching $URL"
fetch -o /tmp/base.txz "$URL"'

echo "Extracting base.txz (as root for setuid files)..."
# tar с флагом -p (preserve permissions) требует root
if [ "$ZFS_MODE" -eq 1 ]; then
    ssh_root "tar xpf /tmp/base.txz -C /bsdos/base/ 2>/dev/null || tar xf /tmp/base.txz -C /bsdos/base/ 2>/dev/null; true"
else
    ssh_root "cd /opt/proto && tar xpf /tmp/base.txz -C base/ 2>/dev/null || tar xf /tmp/base.txz -C base/ 2>/dev/null; true"
fi

echo "Creating jail directories..."

if [ "$ZFS_MODE" -eq 1 ]; then
    # ZFS mode: create base mount points + data/bus datasets
    ssh_root "mkdir -p /bsdos/base/data /bsdos/base/bus"
    ssh_root "
        zfs create -p bsdos/data/appA 2>/dev/null || true
        zfs create -p bsdos/data/appB 2>/dev/null || true
        zfs create -p bsdos/bus/appA 2>/dev/null || true
        zfs create -p bsdos/bus/appB 2>/dev/null || true
    "
    # Create clone snapshots if base snapshot doesn't exist
    ssh_root "
        zfs list -H -o name | grep -q 'bsdos/base@' || \
        zfs snapshot bsdos/base@v15.1
    "
    # Set freebsd ownership where applicable
    ssh_root "chown -R freebsd /bsdos/data /bsdos/bus 2>/dev/null || true"
else
    # nullfs mode: traditional directory layout
    ssh_root "mkdir -p /opt/proto/base/data /opt/proto/base/bus"
    ssh_root "mkdir -p /opt/proto/data/appA /opt/proto/data/appB"
    ssh_root "mkdir -p /opt/proto/bus/appA /opt/proto/bus/appB"
    ssh_root "mkdir -p /opt/proto/jails/appA /opt/proto/jails/appB"
    ssh_root "mkdir -p /opt/proto/app"
    ssh_root "chown -R freebsd /opt/proto/data /opt/proto/bus /opt/proto/jails /opt/proto/app"
fi

echo "Copying jail configuration..."
ssh_guest "cp /opt/proto-src/jail.conf /opt/proto/ && cp /opt/proto-src/jailmgr.sh /opt/proto/ && chmod +x /opt/proto/jailmgr.sh"

# Явно скопировать proto-app если он есть (на случай если jailmgr не скопировал)
if ssh_guest "test -f /opt/proto-src/app/target/release/proto-app" 2>/dev/null; then
    ssh_root "cp /opt/proto-src/app/target/release/proto-app /opt/proto/app/proto-app 2>/dev/null || true"
    echo "proto-app pre-staged in /opt/proto/app/"
fi

echo "Jail setup complete"
