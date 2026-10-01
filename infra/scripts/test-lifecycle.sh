#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"
SCRIPTS="$(dirname "$0")"

echo "=== bsdOS lifecycle test ==="

# Загружаем тест-скрипт в гостя и запускаем там
# Это единственный способ избежать quoting hell в ssh_root
scp -P "$VM_SSH_PORT" -i "$SSH_KEY" \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    "$(dirname "$0")/_lifecycle-test.sh" \
    freebsd@localhost:/tmp/_lifecycle-test.sh

ssh_root "sh /tmp/_lifecycle-test.sh"
