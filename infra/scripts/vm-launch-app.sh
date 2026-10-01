#!/bin/sh
# Запустить приложение из pkg в правильном jail.
# Использование: APP=firefox make vm-launch-app
# Или: APP=thunar JAIL=appFiles make vm-launch-app
set -eu
. "$(dirname "$0")/_ssh.sh"

APP="${APP:?usage: APP=firefox make vm-launch-app}"
JAIL="${JAIL:-appBrowser}"

echo "Launching $APP in jail $JAIL..."

# Bootstrap pkg если нужно
ssh_root "ASSUME_ALWAYS_YES=yes pkg -j $JAIL bootstrap -f 2>&1 | tail -1"

# Установить если не установлено
ssh_root "jexec $JAIL which $APP 2>/dev/null || pkg -j $JAIL install -y $APP 2>&1 | tail -3"

# Определить: через tunnel (wayland-ghost-0) или напрямую к cage (wayland-0)
TUNNEL_SOCK="/tmp/wayland-run/wayland-ghost-0"
USE_TUNNEL=$(ssh_guest "test -S '$TUNNEL_SOCK' && echo 1 || echo 0" 2>/dev/null || echo 0)
if [ "$USE_TUNNEL" = "1" ]; then
    WL_DISPLAY="wayland-ghost-0"
    echo "  mode: via wayland-tunnel (frames captured → Zenoh)"
else
    WL_DISPLAY="wayland-0"
    echo "  mode: direct cage (no frame capture)"
fi

ssh_root "jexec $JAIL env \
    XDG_RUNTIME_DIR=/tmp/wayland-run \
    WAYLAND_DISPLAY=$WL_DISPLAY \
    DISPLAY=:0 \
    nohup $APP >/tmp/${APP}.log 2>&1 &"

sleep 1
ssh_guest "tail -3 /tmp/${APP}.log 2>/dev/null || echo 'starting...'"
echo "$APP launched in jail $JAIL"
