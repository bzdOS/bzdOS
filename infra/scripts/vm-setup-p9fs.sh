#!/bin/sh
# Подмонтировать хостовую директорию /srv/bsdos в VM через 9p (virtio_p9fs).
# Требует FreeBSD 15.x и QEMU с -fsdev/virtio-9p-pci (уже в vm-x86-start.sh).
# После монтирования: /mnt/bsdos → /srv/bsdos на хосте (живая синхронизация).
set -eu
. "$(dirname "$0")/_ssh.sh"

MOUNTPOINT="${P9FS_MOUNTPOINT:-/mnt/bsdos}"
MOUNT_TAG="${P9FS_TAG:-bsdos}"

echo "=== p9fs setup: host /srv/bsdos → guest $MOUNTPOINT ==="

echo "Loading virtio_p9fs module..."
ssh_root "kldload virtio_p9fs 2>/dev/null; kldstat | grep -q p9 && echo 'module: OK' || echo 'module: FAIL'"

echo "Creating mount point..."
ssh_root "mkdir -p $MOUNTPOINT"

echo "Mounting 9p share (p9fs, FreeBSD 15)..."
# FreeBSD 15 filesystem type = p9fs (не 9p как на Linux)
ssh_root "mount -t p9fs -o trans=virtio $MOUNT_TAG $MOUNTPOINT"

echo "Verifying..."
ssh_guest "ls $MOUNTPOINT | head -5"

echo ""
echo "=== p9fs mounted: $MOUNTPOINT ==="
echo "  Guest sees host /srv/bsdos directly — no scp needed."
echo "  agent sources: $MOUNTPOINT/guest-agent/"
echo "  proto sources: $MOUNTPOINT/proto/"
