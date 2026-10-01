#!/bin/sh
# Тест wayland-tunnel без джейла: запускает foot напрямую через tunnel socket.
# Pipeline: foot → tunnel (wayland-ghost-0) → cage (wayland-0)
# Tunnel захватывает wl_shm фреймы и публикует в /tmp/wayland-run/wayland-stream.sock
set -eu
. "$(dirname "$0")/_ssh.sh"

echo "=== wayland-tunnel smoke test ==="

# 1. Проверить cage
CAGE_PID=$(ssh_guest "pgrep cage 2>/dev/null || echo 0")
if [ "$CAGE_PID" = "0" ]; then
    echo "ERROR: cage not running. Run: make vm-start-cage"
    exit 1
fi
echo "  cage: running (pid $CAGE_PID)"

# 2. Проверить socket
CAGE_SOCK=$(ssh_guest "test -S /tmp/wayland-run/wayland-0 && echo yes || echo no")
if [ "$CAGE_SOCK" = "no" ]; then
    echo "ERROR: cage socket /tmp/wayland-run/wayland-0 not found"
    ssh_guest "ls -la /tmp/wayland-run/ 2>/dev/null || echo '(no wayland-run dir)'"
    exit 1
fi
echo "  cage socket: /tmp/wayland-run/wayland-0 OK"

# 3. Проверить tunnel
TUNNEL_PID=$(ssh_guest "pgrep wayland-tunnel 2>/dev/null || echo 0")
if [ "$TUNNEL_PID" = "0" ]; then
    echo "ERROR: wayland-tunnel not running. Run: make wayland-tunnel-start"
    exit 1
fi
echo "  tunnel: running (pid $TUNNEL_PID)"

GHOST_SOCK=$(ssh_guest "test -S /tmp/wayland-run/wayland-ghost-0 && echo yes || echo no")
if [ "$GHOST_SOCK" = "no" ]; then
    echo "ERROR: tunnel socket /tmp/wayland-run/wayland-ghost-0 not found"
    exit 1
fi
echo "  tunnel socket: /tmp/wayland-run/wayland-ghost-0 OK"

# 4. Запустить foot через tunnel (без джейла, напрямую)
echo "  launching foot via tunnel..."
ssh_guest "pkill -f 'foot.*ghost' 2>/dev/null || true"
ssh_guest "nohup env \
    XDG_RUNTIME_DIR=/tmp/wayland-run \
    WAYLAND_DISPLAY=wayland-ghost-0 \
    foot >/tmp/foot-tunnel.log 2>&1 &"
sleep 2

echo "  foot log:"
ssh_guest "tail -5 /tmp/foot-tunnel.log 2>/dev/null || echo '(no log)'"

echo ""
echo "  tunnel log (frame capture):"
ssh_guest "tail -10 /tmp/wayland-tunnel.log 2>/dev/null || echo '(no log)'"

echo ""
FRAMES=$(ssh_guest "grep -c 'pixel frame\|commit\|create_pool' /tmp/wayland-tunnel.log 2>/dev/null || echo 0")
echo "  frames/events captured: $FRAMES"

echo ""
echo "=== smoke test done ==="
