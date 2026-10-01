#!/bin/sh
# Update PF ad-block list in guest from Steven Black hosts list

set -eu

. "$(dirname "$0")/_ssh.sh"

echo "=== Updating PF ad-block list ==="

# Copy update script to guest
ssh_guest "mkdir -p /tmp/bsdos-scripts"
scp -P "$VM_SSH_PORT" -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$(dirname "$0")/../pf-adblock/update-adblock.sh" \
    "freebsd@localhost:/tmp/bsdos-scripts/update-adblock.sh"

# Run as root
ssh_root "sh /tmp/bsdos-scripts/update-adblock.sh"

echo "=== Ad-block update complete ==="
