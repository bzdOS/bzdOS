#!/bin/sh
# Запустить агента внутри гостя.
# Транспорт: virtio-console /dev/ttyV1.1 (text protocol CMD\n/+OK\n).
# После запуска: make vconsole-check (проверить host↔guest канал).
set -eu
. "$(dirname "$0")/_ssh.sh"

echo "Deploying and starting bsdos-agent..."

# Убить старый агент перед заменой бинаря.
ssh_root "pkill -KILL -f bsdos-agent 2>/dev/null || true"
sleep 1

# Деплой бинаря атомарно (install избегает "Text file busy").
ssh_root "install -m 755 /opt/guest-agent/zig-out/bin/bsdos-agent /usr/local/bin/bsdos-agent"

# Запустить с auto-transport: chardev если /dev/ttyV1.0 есть, иначе unix socket.
# BSDOS_CHARDEV_PATH можно переопределить если ttyV путь отличается (см. make vconsole-check).
# Auto-detect chardev: last /dev/ttyV*.1 = named port on the last virtio-serial adapter (agent bus).
# With SPICE on adapter 0 and agent on adapter 1 this is ttyV1.1.
# BSDOS_CHARDEV_PATH overrides detection.
CHARDEV="${BSDOS_CHARDEV_PATH:-/dev/ttyV1.1}"
ssh_root "nohup env BSDOS_CHARDEV_PATH=$CHARDEV /usr/local/bin/bsdos-agent >/tmp/agent.log 2>&1 &"
sleep 1
echo "--- agent.log ---"
ssh_guest "cat /tmp/agent.log"
echo "---"
echo "Transport check: make vconsole-check"
