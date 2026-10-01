#!/bin/sh
# make bench — measure bsdOS development-loop performance.
# Run on warm VM after make vm-setup.
#
# Uses: _ssh.sh (SSH wrapper), _agent.sh (agent socket paths)
#
# Measures (per docs/archive/2026-10-01-monorepo/PLAN-benchmarks.md):
#   1. Agent PING latency (IPC round-trip, target < 5ms)
#   2. demo-smoke wall-time (agent startup, target < 2s)
#   3. cargo build broker incremental (target < 60s)
#   4. build-kernel GENERIC (target < 10 min on x86)
#   5. Memory footprint via agent MEM_STATUS (target < 700MB with 2 jails)
#   6. Zenoh publish latency (future, requires telemetry integration)

set -eu

SCRIPTS="$(cd "$(dirname "$0")" && pwd)"
CURDIR="$(cd "$SCRIPTS/../.." && pwd)"

# Source helpers
. "$SCRIPTS/_ssh.sh"
. "$SCRIPTS/_agent.sh"

# Config
RUNS="${RUNS:-5}"
TIMEOUT_SEC="${TIMEOUT_SEC:-10}"

# Ensure VM is reachable
if ! ssh_guest "echo OK" >/dev/null 2>&1; then
    echo "ERROR: Guest not reachable. Run: make vm-start && make vm-wait" >&2
    exit 1
fi

printf '=== bsdOS bench (%d runs) ===\n\n' "$RUNS"

# Benchmark 1: Agent PING latency (milliseconds)
printf '-- Agent PING latency (ms) --\n'
AGENT_SOCK="${AGENT_VPORT_SOCK:-/tmp/bsdos-agent-vport.sock}"

# Check if agent socket exists; skip if not
if ! ssh_guest "test -S '$AGENT_SOCK'" >/dev/null 2>&1; then
    printf 'SKIP: Agent not running. Run: make build-agent run-agent\n'
else
    for i in $(seq 1 "$RUNS"); do
        start_ms=$(date +%s%3N)

        # Send PING via netcat over Unix socket, measure round-trip
        # Timeout: 3 seconds (fail gracefully if agent hangs)
        if timeout 3 ssh_guest \
            "printf 'PING\n' | nc -w${TIMEOUT_SEC} -U '$AGENT_SOCK' 2>/dev/null" \
            | grep -q '\.'; then
            end_ms=$(date +%s%3N)
            latency=$((end_ms - start_ms))
            echo "${latency}ms"
        else
            echo "TIMEOUT"
        fi
    done
fi

printf '\n'

# Benchmark 2: demo-smoke wall-time (milliseconds)
printf '-- demo-smoke wall-time (ms) --\n'

for i in $(seq 1 "$RUNS"); do
    start_ms=$(date +%s%3N)

    # Run demo-smoke; capture return code but don't fail on error
    if timeout 30 "$SCRIPTS/demo-smoke.sh" >/dev/null 2>&1; then
        end_ms=$(date +%s%3N)
        elapsed=$((end_ms - start_ms))
        echo "${elapsed}ms"
    else
        echo "FAIL (timeout or error)"
    fi
done

printf '\n'

# Benchmark 3: cargo build broker (incremental, if sources are present)
printf '-- cargo build broker (incremental, ms) --\n'

if ssh_guest "test -d /opt/proto-src/broker" 2>/dev/null; then
    for i in $(seq 1 "$RUNS"); do
        start_ms=$(date +%s%3N)

        # Touch one file to force recompile without cache
        # Then build (incremental should be fast if no changes)
        if timeout 120 ssh_guest \
            "cd /opt/proto-src/broker && cargo build --release 2>&1 | tail -1" \
            >/dev/null 2>&1; then
            end_ms=$(date +%s%3N)
            elapsed=$((end_ms - start_ms))
            echo "${elapsed}ms"
        else
            echo "FAIL (timeout or error)"
        fi
    done
else
    printf 'SKIP: Sources not deployed. Run: make scp-sources\n'
fi

printf '\n'

# Benchmark 4: build-kernel (one run only, expensive)
printf '-- build-kernel (GENERIC, seconds) --\n'

if ssh_guest "test -d /usr/src" 2>/dev/null; then
    printf 'NOTE: Running ONE kernel build (expensive, ~8 min). Ctrl+C to skip.\n'
    sleep 2

    start_sec=$(date +%s)

    # Run buildkernel with timeout (20 min)
    if timeout 1200 ssh_guest \
        "cd /usr/src && make -j16 buildkernel 2>&1 | tail -5" \
        >/dev/null 2>&1; then
        end_sec=$(date +%s)
        elapsed=$((end_sec - start_sec))
        echo "${elapsed}s (~$((elapsed / 60)) min)"
    else
        echo "TIMEOUT or error"
    fi
else
    printf 'SKIP: /usr/src not fetched. Run: make src-fetch\n'
fi

printf '\n'

# Benchmark 5: Memory footprint
printf '-- Memory footprint (MB) --\n'

if ssh_guest "test -S '$AGENT_SOCK'" >/dev/null 2>&1; then
    # Try to get MEM_STATUS from agent
    mem_output=$(timeout 5 ssh_guest \
        "printf 'MEM_STATUS\n' | nc -w3 -U '$AGENT_SOCK' 2>/dev/null" \
        | awk '/^\.$/{exit} {print}')

    if [ -n "$mem_output" ]; then
        # Parse vmstat output if available
        # Expected format: "Active   Inactive   Wired    Free" (headers)
        #                 "150      80         120      350"
        mem_lines=$(printf '%s\n' "$mem_output" | grep -E '^[0-9]' | head -1)
        if [ -n "$mem_lines" ]; then
            active=$(printf '%s\n' "$mem_lines" | awk '{print $1}')
            inactive=$(printf '%s\n' "$mem_lines" | awk '{print $2}')
            wired=$(printf '%s\n' "$mem_lines" | awk '{print $3}')
            free=$(printf '%s\n' "$mem_lines" | awk '{print $4}')

            # Calculate used = (active + inactive + wired)
            if [ -n "$active" ] && [ -n "$inactive" ] && [ -n "$wired" ]; then
                used=$((active + inactive + wired))
                echo "Used: ${used}MB (active=${active}MB, inactive=${inactive}MB, wired=${wired}MB, free=${free}MB)"
            else
                echo "SKIP: Could not parse memory output"
            fi
        else
            echo "SKIP: No numeric output from MEM_STATUS"
        fi
    else
        echo "SKIP: Agent MEM_STATUS command timed out"
    fi
else
    printf 'SKIP: Agent not running\n'
fi

printf '\n'

# Benchmark 6: Zenoh publish latency (if core is running)
printf '-- Zenoh publish latency (ms, future) --\n'
printf 'NOTE: Requires make run-core and timestamp injection (not yet implemented)\n'
printf 'SKIP: Awaiting telemetry integration\n'

printf '\n'

echo "=== bench done ==="
