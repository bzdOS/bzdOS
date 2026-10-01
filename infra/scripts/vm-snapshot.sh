#!/bin/sh
# QMP snapshot: сохранить живое состояние VM (RAM + диск) под именем NAME.
# Использование: NAME=good make vm-snapshot
# После: make vm-restore NAME=good  →  возврат к baseline за секунды.
set -eu

QMP_SOCK="${QMP_SOCK:-/tmp/bsdos-qmp.sock}"
NAME="${NAME:-baseline}"

[ -S "$QMP_SOCK" ] || { echo "ERROR: QMP socket not found: $QMP_SOCK"; echo "VM running? make vm-x86-start"; exit 1; }

echo "Saving snapshot '$NAME' via QMP..."

# QMP handshake + execute savevm: send capabilities negotiation then command.
printf '{"execute":"qmp_capabilities"}\n{"execute":"human-monitor-command","arguments":{"command-line":"savevm %s"}}\n' "$NAME" \
    | socat -T10 - "UNIX-CONNECT:$QMP_SOCK" | tr '{' '\n' | grep -v '^$'

echo "Snapshot '$NAME' saved."
echo "Restore with: NAME=$NAME make vm-restore"
