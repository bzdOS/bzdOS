#!/bin/sh
set -eu

SCRIPT_DIR="$(dirname "$0")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
BIN="$PROJECT_DIR/sys-daemon-zig/zig-out/bin/bsdos-hal"

if [ ! -f "$BIN" ]; then
    echo "✗ No binary at $BIN"
    echo "  Run: make build-zig"
    exit 1
fi

. "$SCRIPT_DIR/_ssh.sh"

echo "Deploying bsdos-hal to guest..."

# Copy to guest temp
scp -P "$VM_SSH_PORT" -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    "$BIN" freebsd@localhost:/tmp/bsdos-hal

# Copy to /usr/local/bin as root
ssh_root "cp /tmp/bsdos-hal /usr/local/bin/bsdos-hal && chmod +x /usr/local/bin/bsdos-hal && rm /tmp/bsdos-hal"

echo "✓ Deployed bsdos-hal to /usr/local/bin/bsdos-hal"
