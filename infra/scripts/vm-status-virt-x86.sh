#!/bin/sh
set -eu

echo "=== bsdos-x86 Domain Status ==="
virsh dominfo bsdos-x86 2>/dev/null || {
  echo "Domain not found. Define it first:"
  echo "  make vm-define-x86"
  exit 1
}

echo ""
echo "=== Network Forwarding ==="
echo "SSH:         127.0.0.1:2222 → :22"
echo "Broker IPC:  127.0.0.1:9999 → :9999"
echo "Zenoh mesh:  127.0.0.1:7447 → :7447"
echo "CDP tunnel:  127.0.0.1:9222 → :9222"
echo "SPICE VirGL: 127.0.0.1:5910"

echo ""
if virsh list | grep -q bsdos-x86; then
  echo "✓ VM is running"
else
  echo "○ VM is stopped"
fi
