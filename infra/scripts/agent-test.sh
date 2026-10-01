#!/bin/sh
# Test bsdos-agent connectivity and latency.
# Supports both chardev (/dev/ttyV1.1) and unix socket (/var/run/bsdos-agent.sock) transports.
set -eu
. "$(dirname "$0")/_ssh.sh"

AGENT_VPORT_SOCK="${AGENT_VPORT_SOCK:-/tmp/bsdos-agent-vport.sock}"
AGENT_SOCK_GUEST="${AGENT_SOCK_GUEST:-/var/run/bsdos-agent.sock}"

echo "=== Agent Transport Test ==="
echo ""

# Detect transport: chardev or unix socket
if [ -S "$AGENT_VPORT_SOCK" ]; then
    echo "✓ Chardev socket available: $AGENT_VPORT_SOCK"
    TRANSPORT="chardev"
else
    echo "⚠ Chardev socket not found: $AGENT_VPORT_SOCK"
    echo "  Falling back to unix socket test"
    TRANSPORT="unix"
fi

echo ""
echo "-- Connectivity Test --"

# Test via chardev (host socket)
if [ "$TRANSPORT" = "chardev" ]; then
    echo "Testing chardev transport..."
    RESULT=$(printf 'PING\n' | nc -w3 -U "$AGENT_VPORT_SOCK" 2>/dev/null || echo "FAIL")
    if echo "$RESULT" | grep -q '+OK PONG'; then
        echo "✓ CHARDEV: Agent responding (PING → PONG)"
    else
        echo "✗ CHARDEV: Agent not responding"
        echo "  Response: $RESULT"
        exit 1
    fi
fi

# Test via unix socket (guest socket)
if [ "$TRANSPORT" = "unix" ]; then
    echo "Testing unix socket transport (via SSH)..."
    RESULT=$(ssh_guest "printf 'PING\n' | nc -w3 -U $AGENT_SOCK_GUEST 2>/dev/null || echo 'FAIL'")
    if echo "$RESULT" | grep -q '+OK PONG'; then
        echo "✓ UNIX-SOCKET: Agent responding (PING → PONG)"
    else
        echo "✗ UNIX-SOCKET: Agent not responding"
        echo "  Response: $RESULT"
        exit 1
    fi
fi

echo ""
echo "-- Latency Benchmark (3 PINGs) --"

if [ "$TRANSPORT" = "chardev" ]; then
    # Chardev latency (host-side measurement)
    for i in 1 2 3; do
        START=$(date +%s%N 2>/dev/null | cut -c1-13)
        RESULT=$(printf 'PING\n' | nc -w3 -U "$AGENT_VPORT_SOCK" 2>/dev/null || echo "FAIL")
        END=$(date +%s%N 2>/dev/null | cut -c1-13)
        LATENCY=$((END - START))
        LATENCY_MS=$((LATENCY / 1000000))
        if echo "$RESULT" | grep -q '+OK PONG'; then
            echo "  PING $i: ${LATENCY_MS}ms"
        else
            echo "  PING $i: FAILED"
        fi
    done
else
    # Unix socket latency (via SSH round-trip)
    for i in 1 2 3; do
        START=$(date +%s%N 2>/dev/null | cut -c1-13)
        RESULT=$(ssh_guest "printf 'PING\n' | nc -w3 -U $AGENT_SOCK_GUEST 2>/dev/null || echo 'FAIL'")
        END=$(date +%s%N 2>/dev/null | cut -c1-13)
        LATENCY=$((END - START))
        LATENCY_MS=$((LATENCY / 1000000))
        if echo "$RESULT" | grep -q '+OK PONG'; then
            echo "  PING $i: ${LATENCY_MS}ms (includes SSH round-trip)"
        else
            echo "  PING $i: FAILED"
        fi
    done
fi

echo ""
echo "=== Test Complete ==="
echo "Transport: $TRANSPORT"
