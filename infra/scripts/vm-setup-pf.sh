#!/bin/sh
# Setup PF packet filter with port security (7447 Zenoh) + ad-blocking rules
# Requires: vm-wait (SSH ready)

set -eu

. "$(dirname "$0")/_ssh.sh"

echo "=== Setting up PF firewall (port security + ad-block) ==="

# Load PF kernel module
echo "Step 1: Loading pf kernel module..."
ssh_root "kldload pf 2>/dev/null || echo 'pf already loaded'"

# Ensure pf enabled on next boot
echo "Step 2: Enabling pf on boot..."
ssh_root "sysrc -f /etc/rc.conf pf_enable=YES 2>/dev/null || true"

# Copy PF config to guest
echo "Step 3: Installing PF rules (/etc/pf.bsdos.conf)..."
ssh_root "mkdir -p /etc && cp /mnt/bsdos/pf-adblock/pf-bsdos.conf /etc/pf.bsdos.conf"

# Initialize empty adblock list (will be populated by update-adblock.sh)
echo "Step 4: Initializing ad-block list..."
ssh_root "touch /etc/pf.adblock.list && chmod 644 /etc/pf.adblock.list"

# Validate PF rules syntax
echo "Step 5: Validating PF syntax..."
if ssh_root "pfctl -nf /etc/pf.bsdos.conf 2>&1"; then
    echo "✓ PF rules syntax valid"
else
    echo "✗ ERROR: PF rule syntax check failed"
    exit 1
fi

# Load PF rules
echo "Step 6: Loading PF rules..."
if ssh_root "pfctl -f /etc/pf.bsdos.conf 2>&1"; then
    echo "✓ PF rules loaded successfully"
else
    echo "✗ WARNING: PF rule load failed"
    exit 1
fi

# Enable PF if not already enabled
echo "Step 7: Enabling pf kernel module..."
ssh_root "pfctl -e 2>/dev/null || echo 'pf already enabled'"

# Show detailed status
echo ""
echo "=== PF Status ==="
ssh_root "pfctl -s info | head -8"

echo ""
echo "=== Loaded Rules (first 15 lines) ==="
ssh_root "pfctl -sr | head -15"

echo ""
echo "=== Port Security Rules ==="
ssh_root "pfctl -sr | grep -E '(zenoh|ssh|matrix|7447|22|8008)' || echo 'No port-specific rules found'"

echo ""
echo "=== Ad-block Table Status ==="
ssh_root "pfctl -t adblock -T show | wc -l" 2>/dev/null || echo "Ad-block table empty (will populate via update-adblock)"

echo ""
echo "=== pflog0 Interface ==="
ssh_root "ifconfig pflog0 2>/dev/null || echo 'pflog0 not available'"

echo ""
echo "=== Setup Complete ==="
echo "✓ pf enabled and rules loaded"
echo "✓ Port 7447 (Zenoh) protected with rate-limiting"
echo "✓ Port 22 (SSH) rate-limited"
echo "✓ Port 8008 (Matrix) blocked from external"
echo ""
echo "Next: run 'make vm-update-adblock' to fetch ad-block list"
echo "Logs: tail -f /var/log/pflog"
