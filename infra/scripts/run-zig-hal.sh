#!/bin/sh
set -eu

SCRIPT_DIR="$(dirname "$0")"
. "$SCRIPT_DIR/_ssh.sh"

echo "Starting HAL daemon in guest..."

# Kill any existing HAL process
ssh_root "pkill -f bsdos-hal 2>/dev/null || true"

# Start daemon in background
ssh_root "nohup /usr/local/bin/bsdos-hal >/tmp/hal.log 2>&1 &"

# Give it a moment to start
sleep 2

# Show startup log and verify socket exists
ssh_guest "cat /tmp/hal.log 2>/dev/null || echo '(no log yet)'"
ssh_root "ls -la /var/run/bsdos-hal.sock 2>/dev/null || echo 'WARN: socket not created'"
ssh_root "pgrep -l bsdos-hal 2>/dev/null || echo 'WARN: process not running'"
