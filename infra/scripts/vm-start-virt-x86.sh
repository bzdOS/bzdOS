#!/bin/sh
set -eu

echo "Starting bsdos-x86 VM..."

# Ensure NVRAM directory exists
mkdir -p /var/lib/libvirt/qemu/nvram

# Start VM
virsh start bsdos-x86 2>/dev/null || {
  echo "Failed to start VM. Check if domain exists:"
  echo "  make vm-define-x86"
  exit 1
}

echo "✓ VM started"
echo ""
echo "Access:"
echo "  SSH (when ready):    ssh -p 2222 freebsd@127.0.0.1"
echo "  SPICE VirGL display: spice://127.0.0.1:5910"
echo "  Serial console:      virsh console bsdos-x86"
echo ""
echo "Monitor:"
echo "  make vm-logs-x86     # Tail serial log"
echo "  make vm-status-virt-x86"
