#!/bin/sh
# bsdOS logs — показать последние строки всех логов в госте.
# Использование: make logs [LINES=20]
# Дефолт: LINES=10

set -eu

. "$(dirname "$0")/_ssh.sh"

LINES=${LINES:-10}
LOGS="hal.log broker.log core.log agent.log lifecycle.log buildkernel.log"

echo "=== bsdOS logs (last $LINES lines) ==="

for LOG in $LOGS; do
    printf '\n─── /tmp/%s ───\n' "$LOG"
    ssh_guest "tail -$LINES /tmp/$LOG 2>/dev/null || echo '(empty)'" || true
done

echo ""
