#!/bin/sh
set -eu

echo "Defining bsdos-x86 domain in libvirt..."

# Check if domain already exists
if virsh dominfo bsdos-x86 >/dev/null 2>&1; then
  echo "Domain bsdos-x86 already exists. Undefining..."
  virsh undefine bsdos-x86 --nvram 2>/dev/null || true
fi

virsh define "$(dirname "$0")/../vm-templates/bsdos-x86-kvm.xml"

echo "✓ Domain defined successfully"
echo ""
echo "Next steps:"
echo "  make vm-start-virt-x86      # Start the VM"
echo "  make vm-status-virt-x86     # Check status"
echo "  make vm-spice-x86           # Connect SPICE viewer"
