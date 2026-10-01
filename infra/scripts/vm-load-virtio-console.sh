#!/bin/sh
# Load virtio_console kernel module and persist in loader.conf.
# Purpose: enable /dev/ttyV1.1 chardev for fast agent transport.
set -eu
. "$(dirname "$0")/_ssh.sh"

echo "[virtio_console] Loading module..."
ssh_root "kldload virtio_console 2>/dev/null || echo 'Module already loaded or unavailable'"

echo "[virtio_console] Checking module status..."
LOADED=$(ssh_root "kldstat | grep -c virtio_console 2>/dev/null || echo 0")
if [ "$LOADED" -ge 1 ]; then
    echo "✓ virtio_console module LOADED"
else
    echo "✗ virtio_console module FAILED to load"
    exit 1
fi

echo "[virtio_console] Checking /dev/ttyV* chardev..."
CHARDEV=$(ssh_guest "ls /dev/ttyV* 2>/dev/null | head -1 || echo 'none'")
if [ "$CHARDEV" != "none" ]; then
    echo "✓ Chardev available: $CHARDEV"
else
    echo "✗ No /dev/ttyV* chardev found yet (may need VM restart)"
fi

echo "[virtio_console] Persisting in /boot/loader.conf..."
ssh_root "grep -q 'virtio_console_load' /boot/loader.conf 2>/dev/null || echo 'virtio_console_load=\"YES\"' >> /boot/loader.conf"

echo "[virtio_console] Verifying loader.conf entry..."
ssh_root "grep virtio_console /boot/loader.conf"

echo ""
echo "=== Setup complete ==="
echo "Next: make run-agent (start agent on chardev)"
echo "Then:  make vconsole-check (test chardev connectivity)"
