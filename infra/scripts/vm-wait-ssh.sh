#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"

attempt=0
while [ $attempt -lt 120 ]; do
    if ssh_guest exit 0 2>/dev/null; then
        echo "SSH ready"
        # Открываем мастер-соединение сразу — все последующие команды быстрые
        ssh_master_open
        exit 0
    fi
    attempt=$((attempt + 1))
    sleep 5
done

echo "SSH timeout after 120 attempts"
exit 1
