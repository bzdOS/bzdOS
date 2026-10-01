#!/bin/sh
set -eu

SCRIPT_DIR="$(dirname "$0")"
. "$SCRIPT_DIR/_ssh.sh"

# Write test script to guest and execute — avoids nested quote hell
echo "Uploading HAL test script..."
scp -P "$VM_SSH_PORT" -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$SCRIPT_DIR/_hal-test.sh" \
    freebsd@localhost:/tmp/_hal-test.sh

echo "Running HAL tests..."
ssh_root "sh /tmp/_hal-test.sh"
