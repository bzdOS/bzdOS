#!/bin/sh
# Deploy TLS сертификаты в FreeBSD VM
set -eu

. "$(dirname "$0")/_ssh.sh"

CERTS_DIR="${CERTS_DIR:-$(dirname "$0")/../../certs}"

if [ ! -d "$CERTS_DIR" ]; then
    echo "ERROR: $CERTS_DIR not found. Run 'make gen-tls-certs' first."
    exit 1
fi

if [ ! -f "$CERTS_DIR/ca.pem" ] || [ ! -f "$CERTS_DIR/server.pem" ] || [ ! -f "$CERTS_DIR/server.key" ]; then
    echo "ERROR: Missing cert files. Run 'make gen-tls-certs' first."
    exit 1
fi

echo "Deploying TLS certs to VM /etc/bsdos/..."

# Create directory on VM
ssh_root "mkdir -p /etc/bsdos && chmod 755 /etc/bsdos"

# Copy certs via SCP (using freebsd user, then move to /etc/bsdos as root)
_SCP="scp -P $VM_SSH_PORT -i $SSH_KEY -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null"

echo "Copying CA certificate..."
$_SCP "$CERTS_DIR/ca.pem" freebsd@localhost:/tmp/ca.pem 2>/dev/null

echo "Copying server certificate..."
$_SCP "$CERTS_DIR/server.pem" freebsd@localhost:/tmp/server.pem 2>/dev/null

echo "Copying server key..."
$_SCP "$CERTS_DIR/server.key" freebsd@localhost:/tmp/server.key 2>/dev/null

# Install with proper permissions
echo "Installing certificates..."
ssh_root "install -m 644 /tmp/ca.pem /etc/bsdos/ca.pem"
ssh_root "install -m 644 /tmp/server.pem /etc/bsdos/server.pem"
ssh_root "install -m 600 /tmp/server.key /etc/bsdos/server.key"

# Cleanup temp files
ssh_root "rm -f /tmp/ca.pem /tmp/server.pem /tmp/server.key"

# Deploy Zenoh server config (plain TCP for Zenoh 1.9 compatibility)
echo ""
echo "Copying Zenoh server config (plain TCP on port 7447)..."
# Use zenoh-server-plain-config.json5 for Zenoh 1.9 (doesn't support TLS via config)
# TODO: Upgrade to Zenoh 0.11 or add programmatic TLS config in bsdos-core
CONFIG_FILE="$CERTS_DIR/zenoh-server-plain-config.json5"
if [ ! -f "$CONFIG_FILE" ]; then
    echo "WARNING: Plain config not found, attempting fallback..."
    CONFIG_FILE="$CERTS_DIR/zenoh-server-config.json5"
fi

$_SCP "$CONFIG_FILE" freebsd@localhost:/tmp/zenoh-server.json5 2>/dev/null

echo "Installing Zenoh config..."
ssh_root "install -m 644 /tmp/zenoh-server.json5 /etc/bsdos/zenoh-server.json5"
ssh_root "rm -f /tmp/zenoh-server.json5"

echo "✓ Certs and config deployed to VM /etc/bsdos/"
ls -lh "$CERTS_DIR/"
