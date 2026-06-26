#!/bin/sh
# Build bsdos-core directly from 9p shared filesystem (/mnt/bsdos).
# Run on the FreeBSD VM: gmake build-core
# Or from host: ssh root@<host-ip> 'ssh -i <ssh-key> freebsd@<dev-vm-ip> "cd /mnt/bsdos && gmake build-core"'
set -eu
. "$(dirname "$0")/_ssh.sh"

echo "=== build-core (from /mnt/bsdos) ==="

# Ensure 9p shared filesystem is mounted
ssh_guest "mount | grep -q /mnt/bsdos || \
    (su -m root -c 'mount -t virtfs -o trans=virtio,version=9p2000.L bsdos /mnt/bsdos' && \
     echo 'mounted 9p shared filesystem')"

echo "Building bsdos-core with obfs transport..."
ssh_guest "cd /mnt/bsdos && \
    . ~/.cargo/env 2>/dev/null || true && \
    cargo build --release -p bsdos-core 2>&1 | tail -50"

ssh_root "install -m 755 /mnt/bsdos/target/release/bsdos-core /usr/local/bin/bsdos-core"
ssh_root "install -m 755 /mnt/bsdos/target/release/bsdos-core-sub /usr/local/bin/bsdos-core-sub 2>/dev/null || true"

echo "Installed: /usr/local/bin/bsdos-core"
echo "=== build-core OK ==="
