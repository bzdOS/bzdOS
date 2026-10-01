#!/bin/sh
set -eu

# Kill direct QEMU if running (migrate to libvirt)
pkill -f "qemu-system-aarch64.*freebsd14" 2>/dev/null && echo "Stopped direct QEMU process" || true
sleep 1

echo "Starting bsdos-dev via libvirt..."
virsh start bsdos-dev
echo ""
echo "  Serial console:  virsh console bsdos-dev"
echo "  SPICE display:   make vm-spice"
echo "  SSH:             make vm-wait && make vm-ssh"
