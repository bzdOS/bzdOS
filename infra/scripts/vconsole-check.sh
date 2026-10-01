#!/bin/sh
# Phase 0: проверить готовность virtio-console канала host↔guest.
# Запускать после make vm-x86-start && make vm-x86-wait.
set -eu
. "$(dirname "$0")/_ssh.sh"

AGENT_VPORT_SOCK="${AGENT_VPORT_SOCK:-/tmp/bsdos-agent-vport.sock}"

echo "=== vconsole-check: virtio-console channel ==="
echo ""

echo "-- [HOST] QEMU agent chardev socket --"
if [ -S "$AGENT_VPORT_SOCK" ]; then
    echo "PASS: $AGENT_VPORT_SOCK exists"
else
    echo "FAIL: $AGENT_VPORT_SOCK missing"
    echo "  Check QEMU started with virtio-serial-pci + virtserialport"
    echo "  QEMU errors: cat /tmp/bsdos-x86-qemu-err.log"
    exit 1
fi

echo ""
echo "-- [GUEST] virtio_console driver + ttyV nodes (via agent) --"
# Используем агент вместо SSH для проверки состояния гостя.
AGENT_VPORT_SOCK="${AGENT_VPORT_SOCK:-/tmp/bsdos-agent-vport.sock}"
STATUS=$(printf 'STATUS\n' | nc -w3 -U "$AGENT_VPORT_SOCK" 2>/dev/null \
    | awk '/^\.$/{exit} {print}')
if echo "$STATUS" | grep -q '+OK'; then
    echo "agent: alive via virtio-console"
else
    echo "agent: NOT responding (run: make run-agent)"
fi

echo ""
echo "-- [HOST→GUEST] echo round-trip via nc --"
# Use nc -U: waits for server to close connection; with .\n terminator agent closes cleanly.
RESULT=$(printf 'PING\n' | nc -w5 -U "$AGENT_VPORT_SOCK" 2>/dev/null || echo "NC_FAIL")
if echo "$RESULT" | grep -q '+OK PONG'; then
    echo "PASS: PING → PONG"
elif echo "$RESULT" | grep -q 'NC_FAIL'; then
    echo "FAIL: nc could not connect to $AGENT_VPORT_SOCK"
    echo "  Agent may not be running. Run: make run-agent"
    exit 1
else
    echo "UNEXPECTED response: '$RESULT'"
    echo "  socat test (may work better):"
    printf 'PING\n' | socat -T5 -,shut-null "UNIX-CONNECT:$AGENT_VPORT_SOCK" 2>/dev/null || true
    exit 1
fi

echo ""
echo "=== vconsole-check: PASS — virtio-console channel is ready ==="
echo "  Transport: $AGENT_VPORT_SOCK → /dev/ttyV?.? → bsdos-agent"
