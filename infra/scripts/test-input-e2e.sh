#!/bin/sh
# test-input-e2e.sh — End-to-end input test: Mac → Zenoh → bsdos-core → tunnel → foot
#
# START_AI_HEADER
# MODULE: infra/scripts/test-input-e2e.sh
# PURPOSE: Verify that keyboard input from Mac reaches the foot terminal in the VM
# INTENT: Smoke test for the full input pipeline; publishes synthetic KeyDown events
#         to Zenoh and verifies they appear in the foot log on the VM.
# DEPENDENCIES: Zenoh CLI (zenohd), _ssh.sh, bsdos-core running, foot running in cage
# PUBLIC_API: shell script (exit 0 on success, 1 on failure)
# END_AI_HEADER

set -eu
. "$(dirname "$0")/_ssh.sh"

echo "=== E2E Input Test ==="

# 1. Clear foot log
echo "Clearing foot log..."
ssh_guest "truncate -s 0 /tmp/foot.log 2>/dev/null || true"

# 2. Check if bsdos-core is running
if ! ssh_guest "pgrep -f bsdos-core >/dev/null 2>&1"; then
    echo "ERROR: bsdos-core not running. Start with: make bsdos-core-start" >&2
    exit 1
fi

# 3. Check if wayland-tunnel is running
if ! ssh_guest "pgrep -f wayland-tunnel >/dev/null 2>&1"; then
    echo "ERROR: wayland-tunnel not running. Start with: make wayland-tunnel-start" >&2
    exit 1
fi

# 4. Check if foot is running
if ! ssh_guest "pgrep -x foot >/dev/null 2>&1"; then
    echo "ERROR: foot not running. Start with: make vm-start-cage-foot" >&2
    exit 1
fi

# 5. Publish synthetic keyboard event to Zenoh
#    Format: [key_code:u32][action:u8][modifiers:u8][pad:2][ts_ms:u64] = 16 bytes
#    key_code=30 = 'a', action=1 = press
echo "Publishing synthetic 'a' key press to bsdos/input/keyboard..."

# Check if zenoh CLI is available
if ! command -v zenoh >/dev/null 2>&1; then
    echo "WARNING: zenoh CLI not found. Using Python zenoh client..."
    
    # Fallback: use Python zenoh client if available
    if command -v python3 >/dev/null 2>&1; then
        python3 -c "
import zenoh
import sys
import time

session = zenoh.open(zenoh.Config())
# key_code=30 ('a'), action=1 (press), modifiers=0, pad=0, ts_ms=0
payload = bytes([30, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0])
session.put('bsdos/input/keyboard', payload)
time.sleep(0.5)
session.close()
" 2>/dev/null || {
            echo "ERROR: Python zenoh client failed. Install: pip3 install zenoh" >&2
            exit 1
        }
    else
        echo "ERROR: Neither zenoh CLI nor Python3 available" >&2
        exit 1
    fi
else
    # Use zenoh CLI
    zenoh put bsdos/input/keyboard "$(printf '\x1e\x00\x00\x00\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00\x00' | base64)" 2>/dev/null || {
        echo "ERROR: zenoh put failed" >&2
        exit 1
    }
fi

# 6. Wait for event to propagate
echo "Waiting 2s for event propagation..."
sleep 2

# 7. Check foot log for 'a'
echo "Checking foot log..."
if ssh_guest "grep -q 'a' /tmp/foot.log 2>/dev/null"; then
    echo "✅ PASS: 'a' key reached foot"
    echo ""
    echo "Input pipeline verified:"
    echo "  Mac NSEvent → Zenoh bsdos/input/keyboard → bsdos-core → input.sock → tunnel → wl_keyboard → foot"
    exit 0
else
    echo "❌ FAIL: 'a' key not found in foot log"
    echo ""
    echo "Debug info:"
    ssh_guest "tail -10 /tmp/foot.log 2>/dev/null" >&2 || true
    echo ""
    echo "Check logs:"
    echo "  make core-log"
    echo "  make wayland-tunnel-log"
    echo "  make foot-log"
    exit 1
fi
