#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"

JAIL="${1:-appMatrix}"
JAIL_ROOT="/opt/proto/jails/$JAIL"

echo "=== Fixing DNS in jail $JAIL ==="
echo ""

# Phase 1: Create resolv.conf in jail
echo "[1/4] Setting up DNS configuration in jail..."
ssh_root "mkdir -p $JAIL_ROOT/etc"

# Copy resolv.conf from host (or create with default nameservers)
ssh_root "
    if [ -f /etc/resolv.conf ]; then
        cp /etc/resolv.conf $JAIL_ROOT/etc/resolv.conf
        echo '[DNS] Copied from host /etc/resolv.conf'
    else
        cat > $JAIL_ROOT/etc/resolv.conf << 'EOF'
nameserver 8.8.8.8
nameserver 8.8.4.4
EOF
        echo '[DNS] Created with Google nameservers'
    fi
"

# Verify resolv.conf
echo "[2/4] Verifying resolv.conf in jail..."
ssh_root "cat $JAIL_ROOT/etc/resolv.conf | head -3"

# Phase 3: Ensure jail is running (if not already)
echo "[3/4] Ensuring jail is running..."
ssh_root "jail -f /opt/proto/jail.conf -c $JAIL 2>/dev/null || echo '[jail] Already running'"
sleep 1

# Phase 4: Test DNS inside jail
echo "[4/4] Testing DNS resolution inside jail..."
PING_TEST=$(ssh_root "jexec $JAIL ping -c 1 -W 2 8.8.8.8 2>&1 | grep -q 'bytes from' && echo 'YES' || echo 'NO'" || echo "NO")

if [ "$PING_TEST" = "YES" ]; then
    echo "✓ DNS resolution: WORKING"
    DNS_OK="YES"
else
    echo "✗ DNS resolution: FAILED"
    DNS_OK="NO"
    echo "  (DNS might still work for pkg install — testing with ping is just a check)"
fi

echo ""
echo "=== DNS fix complete ==="
echo "Jail: $JAIL"
echo "DNS Config: $JAIL_ROOT/etc/resolv.conf"
echo "DNS Status: $DNS_OK"
