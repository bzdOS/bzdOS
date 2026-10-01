#!/bin/sh
# vm-start-weston.sh — Start Weston compositor in background
set -eu

. "$(dirname "$0")/_ssh.sh"

echo "=== Starting Weston Compositor ==="
echo ""

echo "[1/2] Ensuring /dev/fb0 is world-writable..."
ssh_root "chmod o+rw /dev/fb0 /dev/mem 2>/dev/null || echo 'Warning: Device access may need manual setup'"

echo ""
echo "[2/2] Starting Weston (fbdev backend) in background..."
ssh_root "nohup weston --backend=fbdev-backend.so >/tmp/weston.log 2>&1 &"

echo ""
echo "Waiting for Weston to initialize..."
sleep 2

echo ""
echo "=== Weston Log (last 5 lines) ==="
ssh_guest "tail -5 /tmp/weston.log 2>/dev/null || echo 'Log not available yet'"

echo ""
echo "=== Weston started ==="
echo "Check status: make vm-weston-log"
echo "Stop:         make vm-stop-weston"
