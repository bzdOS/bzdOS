#!/bin/sh
# Смонтировать /tmp/wayland-run в джейлы через nullfs.
# Вызывается после vm-start-wayland и до vm-launch-app.
# Джейлы должны быть запущены (jail -f jail.conf -c JAIL).
set -eu
. "$(dirname "$0")/_ssh.sh"

WAYLAND_RUN="/tmp/wayland-run"
JAIL_ROOT="/opt/proto/jails"

JAILS="appBrowser appTerminal appFiles appMedia appLLM appContacts"

echo "Mounting wayland-run into jails..."
for jail in $JAILS; do
    JAIL_PATH="$JAIL_ROOT/$jail"
    MOUNT_POINT="$JAIL_PATH/tmp/wayland-run"
    # Проверить что jail существует
    if ! ssh_guest "test -d '$JAIL_PATH' 2>/dev/null"; then
        echo "  $jail: root not found, skipping"
        continue
    fi
    # Создать точку монтирования
    ssh_root "mkdir -p '$MOUNT_POINT'"
    # Примонтировать через nullfs (только если ещё не смонтировано)
    ALREADY=$(ssh_guest "mount | grep '$MOUNT_POINT' | wc -l" 2>/dev/null || echo 0)
    if [ "$ALREADY" -gt 0 ]; then
        echo "  $jail: already mounted"
    else
        ssh_root "mount -t nullfs '$WAYLAND_RUN' '$MOUNT_POINT' 2>/dev/null && echo '  $jail: mounted' || echo '  $jail: mount failed (jail may not be running)'"
    fi
done
echo "Done."
