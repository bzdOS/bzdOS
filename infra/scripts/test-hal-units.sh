#!/bin/sh
# Run HAL Zig unit tests (compile-time + runtime)
# Can run natively or in guest via SSH
set -eu

SCRIPT_DIR="$(dirname "$0")"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Check if we're in the guest (FreeBSD) or host (Linux)
if [ -f /etc/os-release ] && grep -q FreeBSD /etc/os-release; then
    # Running in guest
    echo "=== Running HAL unit tests (FreeBSD guest) ==="
    cd "$PROJECT_ROOT/sys-daemon-zig"
    zig build test 2>&1
    echo "=== HAL unit tests completed ==="
else
    # Running on host — upload and execute in guest via SSH
    if [ -z "${SSH_KEY:-}" ] || [ -z "${VM_SSH_PORT:-}" ]; then
        echo "ERROR: SSH_KEY and VM_SSH_PORT not set"
        echo "Usage: make test-hal-units"
        exit 1
    fi

    . "$SCRIPT_DIR/_ssh.sh"

    echo "=== Uploading test script to guest ==="
    scp -P "$VM_SSH_PORT" -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
        "$SCRIPT_DIR/test-hal-units.sh" \
        freebsd@localhost:/tmp/test-hal-units.sh

    echo "=== Running HAL unit tests in guest ==="
    ssh_guest "sh /tmp/test-hal-units.sh"

    echo "=== HAL unit tests completed ==="
fi
