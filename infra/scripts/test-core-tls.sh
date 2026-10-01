#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"

echo "=== Testing bsdos-core with TLS configuration ==="

# Step 1: Verify certs are in place
echo "Step 1: Verifying TLS certificates..."
ssh_root "ls -la /etc/bsdos/ | grep -E '\.pem|\.key|\.json5' || echo 'MISSING CERTS'"

# Step 2: Verify config file
echo ""
echo "Step 2: Verifying Zenoh TLS config..."
ssh_root "cat /etc/bsdos/zenoh-server.json5 | tail -8"

# Step 3: Stop any running core
echo ""
echo "Step 3: Stopping any existing core process..."
ssh_root "pkill -f bsdos-core 2>/dev/null || true"
sleep 1

# Step 4: Start core with TLS config using explicit env export
echo ""
echo "Step 4: Starting bsdos-core with TLS (ZENOH_CONFIG=/etc/bsdos/zenoh-server.json5)..."
ssh_root "sh -c 'export ZENOH_CONFIG=/etc/bsdos/zenoh-server.json5; nohup /usr/local/bin/bsdos-core >/tmp/core-tls.log 2>&1 &'"
sleep 3

# Step 5: Verify process is running
echo ""
echo "Step 5: Verifying core is running..."
if ssh_guest "pgrep -f bsdos-core >/dev/null 2>&1"; then
    echo "✓ bsdos-core is running"
    ssh_guest "pgrep -a bsdos-core | grep -v grep"
else
    echo "✗ bsdos-core failed to start"
    exit 1
fi

# Step 6: Check logs for TLS confirmation
echo ""
echo "Step 6: Checking startup logs..."
ssh_guest "head -20 /tmp/core-tls.log"

# Step 7: Check if port 7447 is listening
echo ""
echo "Step 7: Checking TLS endpoint (port 7447)..."
ssh_root "sockstat -l 2>/dev/null | grep 7447" || echo "  (sockstat not available or port not listening)"

# Step 8: Verify telemetry is being published
echo ""
echo "Step 8: Checking telemetry publication..."
ssh_guest "tail -5 /tmp/core-tls.log | grep uptime || echo '  (waiting for telemetry...'"

echo ""
echo "=== TLS Configuration Test Complete ==="
