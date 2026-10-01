#!/bin/sh
# QMP restore: мгновенный возврат VM к ранее сохранённому снапшоту.
# Использование: NAME=good make vm-restore
# Восстановление занимает секунды (живое состояние RAM + диска).
set -eu

QMP_SOCK="${QMP_SOCK:-/tmp/bsdos-qmp.sock}"
NAME="${NAME:-baseline}"

[ -S "$QMP_SOCK" ] || { echo "ERROR: QMP socket not found: $QMP_SOCK"; echo "VM running? make vm-x86-start"; exit 1; }

echo "Restoring snapshot '$NAME' via QMP..."

printf '{"execute":"qmp_capabilities"}\n{"execute":"human-monitor-command","arguments":{"command-line":"loadvm %s"}}\n' "$NAME" \
    | socat -T10 - "UNIX-CONNECT:$QMP_SOCK" | tr '{' '\n' | grep -v '^$'

echo "Snapshot '$NAME' restored."
