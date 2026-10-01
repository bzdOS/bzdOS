#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"

# Проверить что jails appA и appB запущены
for jail in appA appB; do
    if ! ssh_root "jls -j $jail >/dev/null 2>&1"; then
        echo "ERROR: jail $jail not running" >&2
        exit 1
    fi
done
echo "jails OK: appA appB"
