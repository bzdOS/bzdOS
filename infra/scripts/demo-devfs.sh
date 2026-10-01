#!/bin/sh
set -eu

. "$(dirname "$0")/_ssh.sh"

echo "=== devfs demo: kernel-enforced device visibility ==="
echo ""

# Show that devfs rules are installed
echo "-- devfs rules in guest --"
ssh_root "grep -A5 'bsdos_jail' /etc/devfs.rules 2>/dev/null || echo 'rules not installed — run: make setup-devfs'"
echo ""

# Show the difference inside jails
echo "-- /dev/bpf visibility per jail --"
echo "appA (ruleset=privileged):"
ssh_root "jexec appA ls /dev/bpf 2>/dev/null && echo '  ✓ EXISTS' || echo '  ✗ HIDDEN'" || true
echo ""
echo "appB (ruleset=restricted):"
ssh_root "jexec appB ls /dev/bpf 2>/dev/null && echo '  ✓ EXISTS' || echo '  ✗ HIDDEN'" || true
echo ""
echo "=== devfs demo complete ==="
