#!/bin/sh
# bsdOS doctor — одношаговый снимок состояния системы.
# Источники: хостовые файлы + агент через virtio-console (НЕ SSH).
#
# Проверяет:
# - VM running?
# - Agent responding через virtio-console?
# - Jails состояние
# - Memory status
# - QMP доступность
# - p9fs mounting

set -eu

AGENT_VPORT_SOCK=${AGENT_VPORT_SOCK:-/tmp/bsdos-agent-vport.sock}
QMP_SOCK=${QMP_SOCK:-/tmp/bsdos-qmp.sock}

echo "=== bsdOS doctor ==="

# ── VM running? ────────────────────────────────────────────────────────────────

VM_PID=""
if pgrep -af "qemu-system-aarch64.*freebsd" >/dev/null 2>&1; then
    VM_PID=$(pgrep -af "qemu-system-aarch64.*freebsd" | awk '{print $1}' | head -1)
    printf 'VM:\t\tUP  (qemu pid %s)\n' "$VM_PID"
elif pgrep -af "qemu-system-x86_64.*freebsd" >/dev/null 2>&1; then
    VM_PID=$(pgrep -af "qemu-system-x86_64.*freebsd" | awk '{print $1}' | head -1)
    printf 'VM:\t\tUP  (qemu pid %s)\n' "$VM_PID"
else
    printf 'VM:\t\tSTOPPED\n'
fi

# ── Agent responding? ──────────────────────────────────────────────────────────

if [ -z "$VM_PID" ]; then
    printf 'Agent:\t\tUNAVAILABLE (VM not running)\n'
else
    AGENT_OK=0
    if [ -S "$AGENT_VPORT_SOCK" ]; then
        if printf 'STATUS\n' | nc -w3 -U "$AGENT_VPORT_SOCK" 2>/dev/null | grep -q '^+OK'; then
            AGENT_OK=1
        fi
    fi

    if [ "$AGENT_OK" -eq 1 ]; then
        printf 'Agent:\t\tOK  (virtio-console %s)\n' "$AGENT_VPORT_SOCK"

        # ── Jails status (через агент) ────────────────────────────────────────
        # Jails: strip "+OK N" header, show only running jails
        JAILS=$(printf 'JLS\n' | nc -w3 -U "$AGENT_VPORT_SOCK" 2>/dev/null \
            | awk '/^\.$/{exit} /^\+OK/{next} /JID/{next} /^$/{next} {gsub(/^[[:space:]]+/,""); print $2}' \
            | tr '\n' ' ')
        printf 'Jails:\t\t%s\n' "${JAILS:-none}"

        # Memory: show free% from v_free_count / v_page_count
        MEM_FREE=$(printf 'MEM_STATUS\n' | nc -w3 -U "$AGENT_VPORT_SOCK" 2>/dev/null \
            | awk '/v_free_count/{f=$2} /v_page_count/{p=$2} END{if(p>0) printf "%d%% free (%d pages)", int(f*100/p), f}')
        printf 'Mem:\t\t%s\n' "${MEM_FREE:-unavailable}"
    else
        printf 'Agent:\t\tNOT RESPONDING (check: tail -f artefacts/logs/serial.log)\n'
    fi
fi

# ── QMP доступность ───────────────────────────────────────────────────────────

if [ -S "$QMP_SOCK" ]; then
    printf 'QMP:\t\tOK  (%s)\n' "$QMP_SOCK"
else
    printf 'QMP:\t\tMISSING\n'
fi

# ── p9fs mounted? ──────────────────────────────────────────────────────────────
# Проверяем ФАКТ монтирования p9fs через агента (mount | grep p9fs),
# а не наличие virtio-console сокета (сокет есть всегда, когда VM запущена —
# это не значит, что shared FS примонтирована).

if [ -z "$VM_PID" ] || [ ! -S "$AGENT_VPORT_SOCK" ]; then
    printf 'p9fs:\t\tUNKNOWN (agent unavailable)\n'
else
    # EXEC mount → агент выполняет `mount` в госте, ответ между +OK и '.'.
    # FreeBSD p9fs показывается в mount как тип "p9fs".
    P9FS_LINE=$(printf 'EXEC mount\n' | nc -w5 -U "$AGENT_VPORT_SOCK" 2>/dev/null \
        | awk '/^\.$/{exit} /^\+OK/{next} {print}' \
        | grep -i 'p9fs' | head -1 | tr -d '\r')
    if [ -n "$P9FS_LINE" ]; then
        # Показать точку монтирования, если она извлекается (формат: "src on /mnt (p9fs, ...)").
        P9FS_MNT=$(printf '%s\n' "$P9FS_LINE" | sed -n 's/.* on \([^ ]*\) .*/\1/p')
        printf 'p9fs:\t\tMOUNTED (%s)\n' "${P9FS_MNT:-p9fs present}"
    else
        printf 'p9fs:\t\tUNMOUNTED\n'
    fi
fi

# ── HAL/broker/lifecycled (примечание) ─────────────────────────────────────────

printf 'HAL/broker:\tunknown (use: make logs)\n'

echo "===================="
