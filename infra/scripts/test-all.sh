#!/bin/sh
# bsdOS інтеграційний тест-suite
# Запускати: make test-all
# Виводить: PASS/FAIL для кожного тесту
# ⛔ НЕ використовує ssh freebsd@! Тільки IPC + sockets

set -eu
. "$(dirname "$0")/_agent.sh"

PASS=0
FAIL=0
ok()   { echo "  ✓ $1"; PASS=$((PASS+1)); }
fail() { echo "  ✗ $1: $2"; FAIL=$((FAIL+1)); }

echo "=== bsdOS test suite ==="

# 1. Agent PING
echo "-- Agent IPC --"
if printf 'PING\n' | nc -w3 -U "${AGENT_VPORT_SOCK:-/tmp/bsdos-agent-vport.sock}" 2>/dev/null \
    | grep -q '+OK PONG'; then
    ok "agent-ping"
else
    fail "agent-ping" "no response from vport socket"
fi

# 2. Agent STATUS
if printf 'STATUS\n' | nc -w3 -U "${AGENT_VPORT_SOCK:-/tmp/bsdos-agent-vport.sock}" 2>/dev/null \
    | grep -q '+OK'; then
    ok "agent-status"
else
    fail "agent-status" "not responding"
fi

# 3. HAL reachable (через agent)
echo "-- HAL --"
if printf 'STATUS\n' | nc -w3 -U "${AGENT_VPORT_SOCK:-/tmp/bsdos-agent-vport.sock}" 2>/dev/null \
    | grep -q '+OK'; then
    ok "hal-reachable"
else
    fail "hal-reachable" "agent not responding"
fi

# 4. JLS command (jails list)
echo "-- Jails --"
if JLS=$(printf 'JLS\n' | nc -w3 -U "${AGENT_VPORT_SOCK:-/tmp/bsdos-agent-vport.sock}" 2>/dev/null); then
    if echo "$JLS" | grep -q '+OK'; then
        ok "jls-command"
    else
        fail "jls-command" "no +OK response"
    fi
else
    fail "jls-command" "socket error"
fi

# 5. MEM_STATUS
echo "-- Memory --"
if MEM=$(printf 'MEM_STATUS\n' | nc -w3 -U "${AGENT_VPORT_SOCK:-/tmp/bsdos-agent-vport.sock}" 2>/dev/null); then
    if echo "$MEM" | grep -q '+OK'; then
        ok "mem-status"
    else
        fail "mem-status" "no +OK response"
    fi
else
    fail "mem-status" "socket error"
fi

# 6. vport socket exists
echo "-- Sockets --"
if [ -S "${AGENT_VPORT_SOCK:-/tmp/bsdos-agent-vport.sock}" ]; then
    ok "vport-sock-exists"
else
    fail "vport-sock-exists" "socket missing at ${AGENT_VPORT_SOCK:-/tmp/bsdos-agent-vport.sock}"
fi

# 7. QMP socket exists
if [ -S "/tmp/bsdos-qmp.sock" ]; then
    ok "qmp-sock-exists"
else
    fail "qmp-sock-exists" "QMP socket missing"
fi

# 8. demo-smoke integration test
echo "-- Integration --"
MAKEDIR=$(dirname "$0")/../..
if (cd "$MAKEDIR" && make demo-smoke >/dev/null 2>&1); then
    ok "demo-smoke"
else
    fail "demo-smoke" "see: make demo-smoke"
fi

# 9. vconsole connectivity
echo "-- VM connectivity --"
if [ -S "${AGENT_VPORT_SOCK:-/tmp/bsdos-agent-vport.sock}" ] && \
   printf 'STATUS\n' | nc -w3 -U "${AGENT_VPORT_SOCK:-/tmp/bsdos-agent-vport.sock}" 2>/dev/null \
   | grep -q '+OK'; then
    ok "vm-alive"
else
    fail "vm-alive" "VM not responding to agent"
fi

# 10. 9p filesystem (optional, fast check)
echo "-- 9p --"
if (cd "$MAKEDIR" && make vm-setup-p9fs >/dev/null 2>&1); then
    ok "p9fs-mount"
else
    fail "p9fs-mount" "9p not mounted (optional)"
fi

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ $FAIL -eq 0 ] && echo "✓ ALL PASS" && exit 0 || exit 1
