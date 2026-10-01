#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"

SCRIPTS="$(dirname "$0")"
PROJECT="$SCRIPTS/../.."

echo "Preparing /opt/sys-daemon-zig in guest..."
ssh_root "mkdir -p /opt/sys-daemon-zig && chown freebsd /opt/sys-daemon-zig"

echo "Syncing sys-daemon-zig sources to guest..."
scp -P "$VM_SSH_PORT" -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -r "$PROJECT/hal/src" \
       "$PROJECT/hal/build.zig" \
       "$PROJECT/hal/build.zig.zon" \
    freebsd@localhost:/opt/sys-daemon-zig/ 2>/dev/null || \
scp -P "$VM_SSH_PORT" -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -r "$PROJECT/hal/src" \
       "$PROJECT/hal/build.zig" \
    freebsd@localhost:/opt/sys-daemon-zig/

echo "Building bsdos-hal in guest (Zig 0.15.2 native)..."
ssh_guest "cd /opt/sys-daemon-zig && zig build -Doptimize=ReleaseSmall"

echo "Deploying binary..."
ssh_root "pkill -f bsdos-hal || true; sleep 0.5"
ssh_root "cp /opt/sys-daemon-zig/zig-out/bin/bsdos-hal /usr/local/bin/bsdos-hal && chmod +x /usr/local/bin/bsdos-hal"

echo "Built: /usr/local/bin/bsdos-hal"
ssh_guest "zig version && /usr/local/bin/bsdos-hal --version 2>/dev/null || echo 'binary OK (no --version flag)'"
