#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"

PROJECT="$(dirname "$0")/../.."

echo "Syncing guest-agent Zig sources to guest..."
ssh_root "mkdir -p /opt/guest-agent/src && chown -R freebsd /opt/guest-agent"
scp -P "$VM_SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$PROJECT/guest-agent/build.zig" \
    freebsd@localhost:/opt/guest-agent/
scp -P "$VM_SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$PROJECT/guest-agent/src/main.zig" \
    "$PROJECT/guest-agent/src/svc_id.zig" \
    freebsd@localhost:/opt/guest-agent/src/

echo "Building bsdos-agent (Zig, text protocol via virtio-console)..."
ssh_guest "cd /opt/guest-agent && zig build -Doptimize=ReleaseFast"
ssh_root "install -m 755 /opt/guest-agent/zig-out/bin/bsdos-agent /usr/local/bin/bsdos-agent"
echo "Built: /usr/local/bin/bsdos-agent (Zig, text protocol CMD\\n/+OK\\n via /dev/ttyV1.1)"
