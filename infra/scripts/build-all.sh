#!/bin/sh
# bsdOS workspace build-all — Rust components via workspace + Zig HAL
# Dependencies: SSH access to guest (make vm-wait), Zig 0.15.2 in guest (make vm-setup-zig)
set -eu

. "$(dirname "$0")/_ssh.sh"

SCRIPTS="$(dirname "$0")"

echo "=== build-all: Rust workspace (broker, app, core, pkgd, etc.) ==="
ssh_guest "cd /mnt/bsdos && cargo build --workspace --release 2>&1 | grep -E '(Compiling|Finished|error)' || true"

echo ""
echo "=== build-all: Zig HAL (FreeBSD native) ==="
ssh_guest "cd /opt/proto-src/sys-daemon-zig && zig build -Doptimize=ReleaseFast 2>&1 | tail -5"

echo ""
echo "=== build-all: Done ==="
