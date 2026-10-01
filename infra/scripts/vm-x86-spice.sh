#!/bin/sh
set -eu
SPICE_PORT="${SPICE_PORT:-5910}"

if ! pgrep -f "qemu-system-x86_64.*freebsd-x86" >/dev/null 2>&1; then
    echo "ERROR: x86 VM not running — run: make vm-x86-start" >&2
    exit 1
fi

echo "Opening SPICE display (spice://127.0.0.1:$SPICE_PORT)..."
# virt-viewer умеет SPICE нативно
if command -v virt-viewer >/dev/null 2>&1; then
    virt-viewer "spice://127.0.0.1:$SPICE_PORT" &
elif command -v spicy >/dev/null 2>&1; then
    spicy -h 127.0.0.1 -p "$SPICE_PORT" &
elif command -v remote-viewer >/dev/null 2>&1; then
    remote-viewer "spice://127.0.0.1:$SPICE_PORT" &
else
    echo "No SPICE client found. Install: apt install virt-viewer"
    echo "Or connect manually to: spice://127.0.0.1:$SPICE_PORT"
fi
