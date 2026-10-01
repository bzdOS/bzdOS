#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"
SCRIPTS="$(dirname "$0")"

echo "=== jail environment check ==="

# Чистый старт
"$SCRIPTS/jail-teardown.sh" >/dev/null 2>&1 || true

# Запустить HAL и broker
ssh_root "pkill -f bsdos-hal 2>/dev/null; true"
ssh_root "nohup /usr/local/bin/bsdos-hal >/tmp/hal.log 2>&1 &"
ssh_guest "pkill -f broker 2>/dev/null; true"
ssh_guest "nohup /opt/proto-src/broker/target/release/broker >/tmp/broker.log 2>&1 &"
sleep 1

# Поднять jails
"$SCRIPTS/jail-setup.sh" >/dev/null 2>&1

echo "--- active jails ---"
ssh_root "jls -q name"

echo "--- mounts inside appA context ---"
ssh_root "mount | grep appA"

echo "--- /data inside jail appA ---"
ssh_root "jexec appA ls -la /data/ 2>&1"

echo "--- ldd inside jail ---"
ssh_root "jexec appA ldd /data/proto-app 2>&1 | head -8"

echo "--- run echo test ---"
ssh_root "jexec appA /bin/sh -c 'echo JAIL_WORKS && hostname'"

echo "--- run binary (quick) ---"
ssh_root "jexec appA env NET_TARGET=127.0.0.1:9999 /data/proto-app 2>&1 | head -20"

"$SCRIPTS/jail-teardown.sh" >/dev/null 2>&1 || true
ssh_guest "pkill -f broker 2>/dev/null; true"
echo "=== check done ==="
