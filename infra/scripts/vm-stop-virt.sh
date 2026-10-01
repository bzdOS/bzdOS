#!/bin/sh
set -eu

# Graceful shutdown first, then destroy if still running
echo "Sending shutdown signal to bsdos-dev..."
virsh shutdown bsdos-dev 2>/dev/null || true
sleep 5

if virsh domstate bsdos-dev 2>/dev/null | grep -q "running"; then
    echo "Still running — destroying..."
    virsh destroy bsdos-dev 2>/dev/null || true
fi

echo "VM stopped."
