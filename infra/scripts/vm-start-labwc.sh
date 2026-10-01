#!/bin/sh
# vm-start-labwc.sh — Start labwc compositor in background
set -eu

. "$(dirname "$0")/_ssh.sh"

echo "=== Starting labwc Compositor ==="
echo ""

echo "[1/2] Ensuring /dev/fb0 is accessible..."
ssh_root "chmod o+rw /dev/fb0 /dev/mem 2>/dev/null || echo 'Warning: fbdev may need manual setup'"

echo ""
echo "[2/2] Starting labwc in background..."
ssh_guest "nohup labwc >/tmp/labwc.log 2>&1 &"

echo ""
echo "Waiting for labwc to initialize..."
sleep 2

echo ""
echo "=== labwc Log (last 5 lines) ==="
ssh_guest "tail -5 /tmp/labwc.log 2>/dev/null || echo 'Log not available yet'"

echo ""
echo "=== labwc started ==="
echo "Check status: make vm-labwc-log"
echo "Stop:         make vm-stop-labwc"
