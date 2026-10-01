#!/bin/sh
set -eu

# Launch virt-viewer for SPICE display
# virt-viewer auto-discovers the SPICE URI from the domain
echo "Opening SPICE display for bsdos-dev..."
echo "(Tip: use virsh console bsdos-dev for serial console)"

if ! virsh domstate bsdos-dev 2>/dev/null | grep -q "running"; then
    echo "ERROR: bsdos-dev is not running. Run 'make vm-start' first." >&2
    exit 1
fi

virt-viewer --connect qemu:///system bsdos-dev &
echo "virt-viewer launched (PID=$!)"
