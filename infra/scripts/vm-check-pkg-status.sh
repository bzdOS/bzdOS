#!/bin/sh
# Check what's actually installed in the jail
set -eu
. "$(dirname "$0")/_ssh.sh"

echo "=== Package Status Check ==="
echo ""

echo "[1] Can we run pkg commands in jail?"
RES=$(ssh_root "jexec appMatrix pkg --version 2>&1 || echo 'PKG_FAILED'")
echo "Result: $RES"

echo ""
echo "[2] List all installed packages..."
ssh_root "jexec appMatrix pkg list 2>/dev/null | head -20 || echo 'pkg list failed'"

echo ""
echo "[3] Check for any matrix/conduit related files..."
ssh_root "
jexec appMatrix find /opt /usr /var -name '*conduit*' -o -name '*matrix*' 2>/dev/null | grep -v '.distfiles' | head -10 || echo 'No files found'
"

echo ""
echo "[4] Check jail filesystem..."
ssh_root "jexec appMatrix ls -la / | head -20"

exit 0
