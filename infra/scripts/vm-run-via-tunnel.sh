#!/bin/sh
# Запустить приложение через wayland-tunnel (захват пикселей).
# Использование: APP=xterm make vm-run-via-tunnel
# Приложение подключится к wayland-ghost-0 (tunnel proxy),
# который выполняет screencopy с cage и отправляет пиксели в логи.
set -eu
. "$(dirname "$0")/_ssh.sh"

APP="${APP:-xterm}"

echo "Running $APP via wayland-tunnel socket..."

# Установить если не установлено
ssh_root "which $APP 2>/dev/null || pkg install -y $APP 2>&1 | tail -3"

# Запустить приложение через tunnel socket
# WAYLAND_DISPLAY=wayland-ghost-0 → подключается к tunnel proxy
# tunnel перехватывает screencopy requests от cage и захватывает пиксели
ssh_root "nohup env \
    XDG_RUNTIME_DIR=/tmp/wayland-run \
    WAYLAND_DISPLAY=wayland-ghost-0 \
    $APP >/tmp/${APP}-tunnel.log 2>&1 &"

sleep 2
ssh_guest "tail -5 /tmp/${APP}-tunnel.log 2>/dev/null || echo 'starting...'"
echo "$APP started via tunnel socket"
echo ""
echo "Checking tunnel logs for frame_ready..."
printf 'LOG_TAIL wayland-tunnel\n' | nc -w3 -U /tmp/bsdos-agent-vport.sock 2>/dev/null | awk '/^\.$/{exit} {print}' | grep -E "frame|pixel|connect|ready" | head -10 || echo "No tunnel events captured yet"
