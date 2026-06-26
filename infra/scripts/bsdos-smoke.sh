#!/bin/sh
# squirrel-smoke.sh — Squirrel QEMU smoke test wrapper
# Per SPEC_squirrel_rootfs.md §5.8 + §11.5 (internal task).
#
# Usage:  squirrel-smoke.sh <arch>   # arch ∈ {amd64, aarch64}
#
# Boots the Squirrel image in QEMU with virtio-console agent channel,
# waits for bsdos-agent PING (primary) or bsdos-core READY (fallback),
# verifies Zenoh session + stream activity, then shuts down.
# Exit 0 = pass, exit 1 = fail.
set -eu

ARCH="${1:-}"
if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "aarch64" ]; then
    echo "Usage: $0 <arch>  (amd64 | aarch64)" >&2
    exit 1
fi

BSDOS_DIR="${BSDOS_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
ARTEFACTS="${ARTEFACTS:-$BSDOS_DIR/artefacts}"
SQUIRREL_VER="${SQUIRREL_VER:-0.1.3}"
IMG="${ARTEFACTS}/bsdos-squirrel-v${SQUIRREL_VER}-${ARCH}.img.gz"

# Verify image integrity before decompressing (guards against race with gzip -9)
if ! gzip -t "$IMG" 2>/dev/null; then
    echo "[ smoke ] ERROR: $IMG failed integrity check (still being written?)" >&2
    exit 1
fi

# Decompress .img.gz → /tmp/*.img for QEMU. Invalidate if .img.gz is newer.
IMG_RAW="/tmp/bsdos-squirrel-smoke-${ARCH}.img"
if [ ! -f "$IMG_RAW" ] || [ "$IMG" -nt "$IMG_RAW" ]; then
    echo "[ smoke ] Decompressing image (cache miss or stale)..."
    gunzip -c "$IMG" > "$IMG_RAW"
fi

# QEMU binary per arch
if [ "$ARCH" = "amd64" ]; then
    QEMU="qemu-system-x86_64"
    MACHINE="q35"
    CPU="host"
    ACCEL="kvm:tcg"
else
    QEMU="qemu-system-aarch64"
    MACHINE="virt"
    CPU="cortex-a72"
    ACCEL="tcg"
fi

# UEFI firmware for aarch64 boot
UEFI_BIOS=""
if [ "$ARCH" = "aarch64" ]; then
    for fw in /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
              /usr/share/AAVMF/AAVMF_CODE.fd; do
        if [ -f "$fw" ]; then
            UEFI_BIOS="$fw"
            break
        fi
    done
    if [ -z "$UEFI_BIOS" ]; then
        echo "[ smoke ] ERROR: no aarch64 UEFI firmware found" >&2
        echo "[ smoke ] Install: apt install qemu-efi-aarch64" >&2
        exit 1
    fi
fi

# Check QEMU is available
if ! command -v "$QEMU" >/dev/null 2>&1; then
    echo "[ smoke ] ERROR: $QEMU not found. Install: apt install qemu-system-$ARCH" >&2
    exit 1
fi

if [ ! -f "$IMG" ] && [ ! -f "$IMG_RAW" ]; then
    echo "[ smoke ] ERROR: image not found at $IMG" >&2
    echo "[ smoke ] Run: make bsdos-build-$ARCH" >&2
    exit 1
fi

# Serial log
LOG_DIR="${BSDOS_DIR}/artefacts/logs"
mkdir -p "$LOG_DIR"
SERIAL_LOG="$LOG_DIR/squirrel-smoke-${ARCH}.log"
: > "$SERIAL_LOG"   # truncate stale markers from a previous run
ZENOH_PORT="${ZENOH_PORT:-7447}"
TIMEOUT="${SMOKE_TIMEOUT:-120}"  # seconds to wait for boot

# Agent virtio-console socket (host side)
AGENT_SOCK="/tmp/bsdos-agent-smoke-${ARCH}.sock"
rm -f "$AGENT_SOCK"  # clean stale socket

PASS=0
FAIL=0
ok()   { echo "[ smoke ] PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "[ smoke ] FAIL: $*"; FAIL=$((FAIL + 1)); }

# Agent RPC helper — send command, read response
agent_cmd() {
    printf '%s\n' "$1" | nc -w "${2:-5}" -U "$AGENT_SOCK" 2>/dev/null
}

agent_ping() {
    agent_cmd "PING" 3 | grep -q "PONG" 2>/dev/null
}

agent_exec() {
    agent_cmd "EXEC $1" "${2:-10}" 2>/dev/null
}

echo "[ smoke ] Squirrel ${ARCH} smoke test"
echo "[ smoke ] Image:  $IMG_RAW"
echo "[ smoke ] Serial: $SERIAL_LOG"
echo "[ smoke ] Zenoh:  tcp/127.0.0.1:${ZENOH_PORT}"
echo "[ smoke ] Agent:  $AGENT_SOCK"

# Boot QEMU in background
EFI_ARG=""
[ -n "$UEFI_BIOS" ] && EFI_ARG="-bios $UEFI_BIOS"

"$QEMU" \
    -m 2G -smp 4 -machine "$MACHINE,accel=$ACCEL" -cpu "$CPU" \
    $EFI_ARG \
    -drive file="$IMG_RAW",format=raw,if=virtio \
    -device virtio-net-pci,netdev=net0 \
    -netdev "user,id=net0,hostfwd=tcp::${ZENOH_PORT}-:7447" \
    -device virtio-serial-pci,id=vser-agent \
    -chardev "socket,id=agentch,path=${AGENT_SOCK},server=on,wait=off" \
    -device virtserialport,bus=vser-agent.0,chardev=agentch,name=bsdos.agent \
    -nographic -serial "file:$SERIAL_LOG" \
    -display none \
    -pidfile "/tmp/squirrel-smoke-${ARCH}.pid" &
QEMU_PID=$!
echo "[ smoke ] QEMU PID: $QEMU_PID"

# Cleanup on exit
cleanup() {
    if kill -0 "$QEMU_PID" 2>/dev/null; then
        kill "$QEMU_PID" 2>/dev/null || true
        sleep 2
        kill -9 "$QEMU_PID" 2>/dev/null || true
    fi
    rm -f "/tmp/squirrel-smoke-${ARCH}.pid" "$AGENT_SOCK"
}
trap cleanup EXIT INT TERM

# ── Readiness: try agent PING (primary), fall back to serial READY ────────
echo "[ smoke ] Waiting for agent PING or READY (timeout ${TIMEOUT}s)..."
ELAPSED=0
READY=0
READY_VIA=""
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    # Primary: agent PING over virtio-console
    if agent_ping; then
        READY=1
        READY_VIA="agent"
        break
    fi
    # Fallback: bsdos-core READY marker in serial log
    if [ -f "$SERIAL_LOG" ] && grep -q "\[bsdos-core\] READY:" "$SERIAL_LOG" 2>/dev/null; then
        READY=1
        READY_VIA="serial"
        break
    fi
    sleep 3
    ELAPSED=$((ELAPSED + 3))
    printf '.'
done
echo

if [ "$READY" -eq 0 ]; then
    fail "neither agent PING nor bsdos-core READY within ${TIMEOUT}s"
    echo "[ smoke ] Serial log (last 40 lines):"
    tail -40 "$SERIAL_LOG" 2>/dev/null || echo "(no log)"
    exit 1
fi

ok "ready after ${ELAPSED}s (via ${READY_VIA})"

echo "[ smoke ] Boot trace (last 15 lines):"
tail -15 "$SERIAL_LOG" 2>/dev/null || true

# ── Diagnostics via agent (if available) ──────────────────────────────────
if [ "$READY_VIA" = "agent" ]; then
    # Give bsdos-core time to start (rc.d → daemon → Zenoh → streams)
    # aarch64 TCG emulation is much slower than amd64 KVM
    BOOT_WAIT=10
    [ "$ARCH" = "aarch64" ] && BOOT_WAIT=20
    echo "[ smoke ] Waiting ${BOOT_WAIT}s for bsdos-core to initialize..."
    sleep $BOOT_WAIT

    echo "[ smoke ] Agent diagnostics:"

    # Check bsdos-core process (retry 3x)
    CORE_PID=""
    for i in 1 2 3; do
        CORE_PID=$(agent_exec "pgrep -f bsdos-core | head -1" 5 2>/dev/null | grep -E '^[0-9]+$' | head -1)
        [ -n "$CORE_PID" ] && break
        sleep 3
    done
    if [ -n "$CORE_PID" ]; then
        ok "bsdos-core running (pid ${CORE_PID})"
    else
        fail "bsdos-core not running"
    fi

    # Check Zenoh port
    ZENOH_LISTEN=$(agent_exec "sockstat -4l 2>/dev/null | grep 7447" 5 2>/dev/null)
    if [ -n "$ZENOH_LISTEN" ]; then
        ok "Zenoh listening on :7447"
    else
        fail "Zenoh not listening on :7447"
    fi

    # Check cage
    CAGE_PID=$(agent_exec "pgrep cage | head -1" 5 2>/dev/null | grep -E '^[0-9]+$' | head -1)
    if [ -n "$CAGE_PID" ]; then
        ok "cage running (pid ${CAGE_PID})"
    else
        echo "[ smoke ] NOTE: cage not running (stream may not have started yet)"
    fi

    # Check bsdos-core log for READY + stream markers
    LOG_READY=$(agent_exec "grep -c READY /var/log/bsdos-core.log 2>/dev/null || echo 0" 5 2>/dev/null | grep -E '^[0-9]+$' | tail -1)
    echo "[ smoke ] bsdos-core READY markers in log: ${LOG_READY:-0}"

else
    # Serial-only mode — verify via serial log
    if grep -q "Zenoh session opened" "$SERIAL_LOG" 2>/dev/null; then
        ok "Zenoh session opened (serial)"
    else
        fail "Zenoh session not opened (serial)"
    fi
fi

# Verify stream manager activity (via agent log file or serial log)
if [ "$READY_VIA" = "agent" ]; then
    SM_COUNT=$(agent_exec "grep -c '\\[sm\\]' /var/log/bsdos-core.log 2>/dev/null" 5 2>/dev/null | grep -E '^[0-9]+$' | tail -1)
else
    SM_COUNT=$(grep -c "\[sm\]" "$SERIAL_LOG" 2>/dev/null || true)
fi
SM_COUNT=${SM_COUNT:-0}
if [ "$SM_COUNT" -gt 0 ] 2>/dev/null; then
    ok "stream manager active ($SM_COUNT [sm] log lines)"
else
    fail "stream manager not active (no [sm] log lines)"
fi

echo ""
echo "[ smoke ] RESULT: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -gt 0 ]; then
    echo "[ smoke ] OVERALL: FAIL"
    exit 1
fi

echo "[ smoke ] Squirrel ${ARCH} smoke: ALL CHECKS PASSED"
exit 0
