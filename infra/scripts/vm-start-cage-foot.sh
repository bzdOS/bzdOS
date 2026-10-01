#!/bin/sh
# vm-start-cage-foot.sh — Start cage compositor with foot terminal instead of wl-keepalive
#
# START_AI_HEADER
# MODULE: infra/scripts/vm-start-cage-foot.sh
# PURPOSE: Start cage compositor with foot terminal as the client app
# INTENT: Replace wl-keepalive (empty frames) with foot (real terminal frames)
#         so the Wayland stream contains actual pixel data from a real app.
# DEPENDENCIES: _ssh.sh, foot (pkg installed via vm-setup-phantom.sh or manually)
# PUBLIC_API: shell script (no exports)
# END_AI_HEADER

set -eu
. "$(dirname "$0")/_ssh.sh"

echo "Starting cage with foot terminal..."

# Stop existing cage
ssh_root "service bsdos_cage stop 2>/dev/null || true"
sleep 1

# Clean runtime dir
ssh_root "rm -rf /tmp/wayland-run; mkdir -p /tmp/wayland-run && chmod 777 /tmp/wayland-run"

# Check if foot is installed
if ! ssh_guest "test -x /usr/local/bin/foot"; then
    echo "ERROR: foot not installed. Run: ssh root@VM 'pkg install -y foot'" >&2
    exit 1
fi

# Start cage with foot
# cage -- foot: foot runs as embedded client, generates real frames
ssh_root "env XDG_RUNTIME_DIR=/tmp/wayland-run \
    WLR_BACKENDS=headless \
    WLR_RENDERER=pixman \
    WLR_HEADLESS_OUTPUTS=1 \
    LIBSEAT_BACKEND=noop \
    /usr/local/bin/cage -- /usr/local/bin/foot --server &"

# Wait for socket
echo "Waiting for wayland-0 socket..."
for i in $(seq 1 30); do
    if ssh_guest "[ -S /tmp/wayland-run/wayland-0 ]" 2>/dev/null; then
        ssh_root "chmod 777 /tmp/wayland-run/wayland-0"
        echo "cage + foot started, socket: /tmp/wayland-run/wayland-0"
        
        # Verify foot is running
        if ssh_guest "pgrep -x foot >/dev/null 2>&1"; then
            echo "foot is running (pid: $(ssh_guest 'pgrep -x foot'))"
        else
            echo "WARNING: foot not detected, check /tmp/wayland-run/cage.log" >&2
        fi
        
        exit 0
    fi
    sleep 0.5
done

echo "ERROR: wayland-0 socket not created" >&2
ssh_guest "tail -20 /tmp/wayland-run/cage.log 2>/dev/null" >&2 || true
exit 1
