#!/bin/sh
# demo-wayland.sh — запуск полного Wayland пайплайна через агент (один round-trip).
# cage (headless) → wayland-tunnel → bsdos-core → Zenoh → metal-viewer (Mac)
# Требования: VM запущена (make vm-x86-start && make vm-x86-wait)
set -eu
SCRIPTS="$(dirname "$0")"
. "$SCRIPTS/_agent.sh"

echo "=== bsdOS Wayland Pipeline ==="
echo "Starting stack via agent (WAYLAND_START)..."
agent_wayland_start
echo ""
echo "Mac viewer:"
echo "  ./mac-companion/metal-viewer/target/release/bsdos-metal-viewer"
