#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"
SCRIPTS="$(dirname "$0")"

echo "=== check data mounts ==="
echo "--- /opt/proto/data/appA/ contents ---"
ssh_root "ls -la /opt/proto/data/appA/ 2>/dev/null || echo EMPTY"

echo "--- active mounts with appA ---"
ssh_root "mount | grep appA 2>/dev/null || echo NO_MOUNTS"

echo "--- /opt/proto/base/data exists? ---"
ssh_root "test -d /opt/proto/base/data && echo EXISTS || echo MISSING"

echo "--- jailmgr.sh cp step ---"
ssh_root "grep -n 'cp.*proto-app' /opt/proto/jailmgr.sh 2>/dev/null"

echo "--- fix: force copy binary to data/appA ---"
ssh_root "cp /opt/proto/app/proto-app /opt/proto/data/appA/proto-app 2>&1 && echo COPIED || echo COPY_FAILED"

echo "--- verify copy ---"
ssh_root "ls -la /opt/proto/data/appA/proto-app 2>/dev/null || echo STILL_MISSING"

echo "--- check inside jail after copy ---"
ssh_root "jexec appA ls /data/ 2>&1 || echo JEXEC_FAILED"
echo "=== done ==="
