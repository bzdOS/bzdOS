#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"
SCRIPTS="$(dirname "$0")"

echo "=== verify binary copy into jail ==="

# Проверить исходный бинарь
echo "--- source binary ---"
ssh_root "ls -la /opt/proto/app/proto-app 2>/dev/null || echo SOURCE MISSING"

# Запустить teardown + setup
echo "--- tearing down existing jails ---"
"$SCRIPTS/jail-teardown.sh" >/dev/null 2>&1 || true
sleep 1

echo "--- setting up jails ---"
"$SCRIPTS/jail-setup.sh" >/dev/null 2>&1

# Запустить jails
echo "--- starting jails ---"
ssh_root "cd /opt/proto && ./jailmgr.sh setup-all 2>&1" | head -30 || true
sleep 2

# Проверить статус jail
echo "--- jail status ---"
ssh_root "jls" 2>&1 || true

# Проверить копию в data/appA
echo "--- data/appA contents ---"
ssh_root "ls -la /opt/proto/data/appA/ 2>/dev/null || echo EMPTY"

# Проверить файл внутри jail через mount path
echo "--- file via mount path ---"
ssh_root "ls -la /opt/proto/jails/appA/data/ 2>/dev/null || echo EMPTY"

# Проверить файл и его свойства
echo "--- binary properties ---"
ssh_root "file /opt/proto/data/appA/proto-app" 2>&1 || true
ssh_root "file /opt/proto/jails/appA/data/proto-app" 2>&1 || true

# Проверить внутри jail через jexec (используя имя jail вместо JID)
echo "--- inside jail (jexec test) ---"
ssh_root "jexec appA pwd 2>&1 || echo jexec pwd failed" || true
ssh_root "jexec appA ls /data 2>&1 || echo jexec ls /data failed" || true
ssh_root "jexec appA file /data/proto-app 2>&1 || echo file cmd failed" || true

# ldd внутри jail
echo "--- ldd test ---"
ssh_root "jexec appA ldd /data/proto-app 2>&1 || echo ldd failed"  || true

# Проверить архитектуру VM и binaries
echo "--- architecture check ---"
ssh_root "uname -m" 2>&1 || true
ssh_root "file /bin/sh | grep -o '[^ ]*bit'" 2>&1 || true

# Проверить что файл скопировался в data/appA (основная цель)
echo "--- binary copy verification ---"
if ssh_root "test -f /opt/proto/data/appA/proto-app"; then
    echo "✓ Binary copied to /opt/proto/data/appA/proto-app"
    ssh_root "ls -lh /opt/proto/data/appA/proto-app" 2>&1 | sed 's/^/  /'
else
    echo "✗ Binary NOT in /opt/proto/data/appA/"
    echo "FIXING: manual copy"
    ssh_root "cp /opt/proto/app/proto-app /opt/proto/data/appA/proto-app && chmod +x /opt/proto/data/appA/proto-app"
    ssh_root "ls -lh /opt/proto/data/appA/proto-app 2>&1 || echo COPY FAILED" | sed 's/^/  /'
fi

"$SCRIPTS/jail-teardown.sh" >/dev/null 2>&1 || true
echo "=== DIAGNOSTICS COMPLETE ==="
echo "Note: jexec abort may indicate architecture mismatch (binary x86-64 vs VM aarch64)"
