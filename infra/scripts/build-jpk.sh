#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"
PROJECT="$(dirname "$0")/../.."

echo "Syncing jpk-manager sources..."
ssh_guest "mkdir -p /opt/jpk-manager/src"
scp -P "$VM_SSH_PORT" -i "$SSH_KEY" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -r "$PROJECT/jpk-manager/src" "$PROJECT/jpk-manager/Cargo.toml" \
    freebsd@localhost:/opt/jpk-manager/
echo "Building bsdos-pkgd..."
ssh_guest "cd /opt/jpk-manager && cargo build --release"
ssh_root "cp /opt/jpk-manager/target/release/bsdos-pkgd /usr/local/bin/ && chmod +x /usr/local/bin/bsdos-pkgd"
echo "Built: /usr/local/bin/bsdos-pkgd"
