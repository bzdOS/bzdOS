#!/bin/sh
set -eu

PORT=$(virsh dumpxml bsdos-x86 2>/dev/null | grep -o "port='5910'" | head -1)

if [ -z "$PORT" ]; then
  echo "Error: Could not find SPICE port. Domain may not be defined."
  exit 1
fi

SPICE_URI="spice://127.0.0.1:5910"

echo "Connecting to bsdOS x86 SPICE display..."
echo "URI: $SPICE_URI"
echo ""
echo "Attempting to launch virt-viewer..."

# Try virt-viewer first (if available)
if command -v virt-viewer >/dev/null 2>&1; then
  virt-viewer "$SPICE_URI" 2>/dev/null &
  echo "✓ virt-viewer launched"
  exit 0
fi

# Fallback: print connection info
echo "virt-viewer not available. Use manual connection:"
echo "  virt-viewer '$SPICE_URI'"
echo ""
echo "Or with remote-viewer:"
echo "  remote-viewer '$SPICE_URI'"
