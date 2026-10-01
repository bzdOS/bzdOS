#!/bin/sh
# vm-start-sway.sh — Start Sway compositor in background
set -eu

. "$(dirname "$0")/_ssh.sh"

echo "=== Starting Sway Compositor ==="
echo ""

echo "[1/2] Setting up Wayland display and permissions..."
ssh_root "chmod o+rw /dev/fb0 /dev/mem 2>/dev/null || echo 'Warning: fbdev device may need manual permission setup'"

echo ""
echo "[2/2] Starting Sway (via login shell for environment)..."
ssh_guest "WAYLAND_DISPLAY=wayland-0 nohup sway >/tmp/sway.log 2>&1 &"

echo ""
echo "Waiting for Sway to initialize..."
sleep 3

echo ""
echo "=== Sway Log (last 5 lines) ==="
ssh_guest "tail -5 /tmp/sway.log 2>/dev/null || echo 'Log not available yet'"

echo ""
echo "=== Sway started ==="
echo "Check status: make vm-sway-log"
echo "Stop:         make vm-stop-sway"
