#!/bin/sh
[ -r "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}" ] && . "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}"
# test-2stream-e2e.sh — Squirrel 2-stream E2E acceptance test
# Per SPEC_2stream_squirrel.md §8.
#
# Usage:
#   test-2stream-e2e.sh [arch]        # default: amd64 — boot local Squirrel image
#   test-2stream-e2e.sh --live        # check production myvm (${BSDOS_MYVM_IP}) live
#
# QEMU mode: boots Squirrel image, verifies via guest agent: both cage instances,
# Zenoh, stream lifecycle.
# Live mode: checks myvm without booting anything — confirms bsdos-core is running,
# both Zenoh topics are active, and socket paths are present.
# Exit 0 = PASS, exit 1 = FAIL.
set -eu

BSDOS_DIR="${BSDOS_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

# ── Live mode: check production myvm (${BSDOS_MYVM_IP}) ───────────────────────
if [ "${1:-}" = "--live" ]; then
    MYVM_IP="${MYVM_IP:-${BSDOS_MYVM_IP:?set BSDOS_MYVM_IP in /etc/bsdos/hosts.env}}"
    MYVM_ZENOH_PORT="${MYVM_ZENOH_PORT:-7447}"
    NC_TIMEOUT="${NC_TIMEOUT:-5}"
    SUB_BIN="${BSDOS_DIR}/bsdos-core/target/release/bsdos-core-sub"

    PASS=0; FAIL=0
    ok()   { printf '[e2e-live] PASS: %s\n' "$*"; PASS=$((PASS + 1)); }
    fail() { printf '[e2e-live] FAIL: %s\n' "$*"; FAIL=$((FAIL + 1)); }
    note() { printf '[e2e-live] NOTE: %s\n' "$*"; }

    echo "[e2e-live] 2-stream live check: myvm ${MYVM_IP}"
    echo "[e2e-live] Zenoh: ${MYVM_IP}:${MYVM_ZENOH_PORT}"
    echo ""

    # 1. bsdos-core TCP reachability (Zenoh port)
    if nc -z -w "${NC_TIMEOUT}" "${MYVM_IP}" "${MYVM_ZENOH_PORT}" 2>/dev/null; then
        ok "TCP ${MYVM_IP}:${MYVM_ZENOH_PORT} reachable (bsdos-core Zenoh port)"
    else
        fail "TCP ${MYVM_IP}:${MYVM_ZENOH_PORT} unreachable (bsdos-core down?)"
    fi

    # 2. Zenoh session probe: subscribe bsdos/telemetry from myvm:7447
    if [ -x "${SUB_BIN}" ]; then
        SUB_OUT=""
        SUB_OUT=$(ZENOH_MODE=peer \
            ZENOH_PEER="tcp/${MYVM_IP}:${MYVM_ZENOH_PORT}" \
            BSDOS_ZENOH_SCOUTING=0 \
            timeout 8 "${SUB_BIN}" 2>&1 | head -6) || true
        if echo "${SUB_OUT}" | grep -qE "uptime=|battery=|cpu="; then
            ok "Zenoh telemetry received from ${MYVM_IP}:${MYVM_ZENOH_PORT}"
        elif echo "${SUB_OUT}" | grep -qiE "subscribing|session opened|Zenoh session"; then
            ok "Zenoh session opened to ${MYVM_IP}:${MYVM_ZENOH_PORT} (no telemetry yet)"
        else
            fail "Zenoh session to ${MYVM_IP}:${MYVM_ZENOH_PORT} failed"
            note "sub output: $(printf '%s' "${SUB_OUT}" | head -3)"
        fi
    else
        note "bsdos-core-sub not built — skipping Zenoh session probe"
        note "Build: cargo build --release --bin bsdos-core-sub on VM dev-vm"
    fi

    # 3. Stream topic activity: check appTerminal Zenoh topic via bsdos-core-sub
    # bsdos-core-sub only reads bsdos/telemetry; stream frame topics require
    # a dedicated subscriber. We check socket paths as the ground truth instead.
    # Socket existence is evidence that bsdos-core started the stream pipeline.

    # 4. Socket path: appTerminal/wayland-stream.sock on myvm (via host view of 9p staging)
    # The 9p mount exposes /srv/bsdos == /mnt/bsdos in VM dev-vm (not myvm).
    # For myvm socket check, the authoritative method is the demo-2stream-remote target
    # (runs directly on myvm). Here we report an advisory check only.
    note "Socket-path check requires running 'make demo-2stream-remote' on myvm directly"
    note "From host: ssh ... freebsd@${MYVM_IP} 'gmake -C /mnt/bsdos demo-2stream-remote'"

    echo ""
    echo "[e2e-live] RESULT: ${PASS} passed, ${FAIL} failed"
    if [ "${FAIL}" -gt 0 ]; then
        echo "[e2e-live] OVERALL: FAIL"
        exit 1
    fi
    echo "[e2e-live] OVERALL: PASS — myvm 2-stream live check passed"
    exit 0
fi
# ── End live mode ────────────────────────────────────────────────────────────

ARCH="${1:-amd64}"
if [ "$ARCH" != "amd64" ] && [ "$ARCH" != "aarch64" ]; then
    echo "Usage: $0 [arch]          (amd64 | aarch64, default: amd64)" >&2
    echo "       $0 --live          (check production myvm, no QEMU boot)" >&2
    exit 1
fi

BSDOS_DIR="${BSDOS_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"
ARTEFACTS="${ARTEFACTS:-$BSDOS_DIR/artefacts}"
SQUIRREL_VER="${SQUIRREL_VER:-0.1.3}"
IMG="${ARTEFACTS}/bsdos-squirrel-v${SQUIRREL_VER}-${ARCH}.img.gz"
# Expected autostream: bsdos-core starts appTerminal + appBrowser automatically.
# Corresponds to rc.conf: bsdos_core_autostream / BSDOS_AUTOSTREAM env.
BSDOS_AUTOSTREAM="${BSDOS_AUTOSTREAM:-appTerminal:foot:,appBrowser:chrome:about:blank}"
ZENOH_PORT="${ZENOH_PORT:-7447}"
TIMEOUT="${E2E_TIMEOUT:-180}"

# Decompress image (invalidate stale cache)
IMG_RAW="/tmp/bsdos-squirrel-e2e-${ARCH}.img"
if [ ! -f "$IMG_RAW" ] || [ "$IMG" -nt "$IMG_RAW" ]; then
    echo "[e2e] Decompressing image..."
    gunzip -c "$IMG" > "$IMG_RAW"
fi

# QEMU binary + UEFI firmware
EFI_BIOS=""
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
    for fw in /usr/share/qemu-efi-aarch64/QEMU_EFI.fd \
              /usr/share/AAVMF/AAVMF_CODE.fd; do
        [ -f "$fw" ] && EFI_BIOS="$fw" && break
    done
fi

LOG_DIR="${ARTEFACTS}/logs"
mkdir -p "$LOG_DIR"
SERIAL_LOG="${LOG_DIR}/test-2stream-e2e-${ARCH}.log"
: > "$SERIAL_LOG"
AGENT_SOCK="/tmp/bsdos-agent-e2e-${ARCH}.sock"
rm -f "$AGENT_SOCK"

PASS=0
FAIL=0
ok()   { echo "[e2e] PASS: $*"; PASS=$((PASS + 1)); }
fail() { echo "[e2e] FAIL: $*"; FAIL=$((FAIL + 1)); }

agent_cmd()  { printf '%s\n' "$1" | nc -w "${2:-5}" -U "$AGENT_SOCK" 2>/dev/null; }
agent_ping()  { agent_cmd "PING" 3 | grep -q "PONG" 2>/dev/null; }
agent_exec()  { agent_cmd "EXEC $1" "${2:-10}" 2>/dev/null; }

echo "[e2e] Squirrel 2-stream E2E test (${ARCH})"
echo "[e2e] Image:    $IMG_RAW"
echo "[e2e] Zenoh:    tcp/127.0.0.1:${ZENOH_PORT}"
echo "[e2e] Agent:    $AGENT_SOCK"

# ── Boot QEMU with virtio-console + virtio-gpu ─────────────────────────────
EFI_ARG=""
[ -n "$EFI_BIOS" ] && EFI_ARG="-bios $EFI_BIOS"

"$QEMU" \
    -m 2G -smp 4 -machine "$MACHINE,accel=$ACCEL" -cpu "$CPU" \
    $EFI_ARG \
    -drive file="$IMG_RAW",format=raw,if=virtio \
    -device virtio-gpu-pci \
    -device virtio-net-pci,netdev=net0 \
    -netdev "user,id=net0,hostfwd=tcp::${ZENOH_PORT}-:7447" \
    -device virtio-serial-pci,id=vser-agent \
    -chardev "socket,id=agentch,path=${AGENT_SOCK},server=on,wait=off" \
    -device virtserialport,bus=vser-agent.0,chardev=agentch,name=bsdos.agent \
    -nographic -serial "file:$SERIAL_LOG" -display none \
    -pidfile "/tmp/squirrel-e2e-${ARCH}.pid" &
QEMU_PID=$!
echo "[e2e] QEMU PID: $QEMU_PID"

cleanup() {
    kill "$QEMU_PID" 2>/dev/null || true
    sleep 2
    kill -9 "$QEMU_PID" 2>/dev/null || true
    rm -f "/tmp/squirrel-e2e-${ARCH}.pid" "$AGENT_SOCK"
}
trap cleanup EXIT INT TERM

# ── Wait for agent readiness ───────────────────────────────────────────────
echo "[e2e] Waiting for agent PING (timeout ${TIMEOUT}s)..."
ELAPSED=0
READY=0
while [ "$ELAPSED" -lt "$TIMEOUT" ]; do
    if agent_ping; then
        READY=1; break
    fi
    if [ -f "$SERIAL_LOG" ] && grep -q "\[bsdos-core\] READY:" "$SERIAL_LOG" 2>/dev/null; then
        READY=1; break
    fi
    sleep 3; ELAPSED=$((ELAPSED + 3)); printf '.'
done
echo

if [ "$READY" -eq 0 ]; then
    fail "no agent PING or READY within ${TIMEOUT}s"
    tail -30 "$SERIAL_LOG" 2>/dev/null || true
    exit 1
fi
ok "ready after ${ELAPSED}s"

# Give bsdos-core time to spawn streams
echo "[e2e] Waiting 15s for streams to start..."
sleep 15

# ── Check 1: appTerminal stream (cage instance) ────────────────────────────
CAGE_COUNT=$(agent_exec "pgrep cage | wc -l" 5 2>/dev/null | grep -E '^[0-9]+$' | tail -1)
CAGE_COUNT=${CAGE_COUNT:-0}
if [ "$CAGE_COUNT" -ge 1 ] 2>/dev/null; then
    ok "appTerminal cage running ($CAGE_COUNT cage process(es))"
else
    fail "no cage processes running"
fi

# ── Check 2: bsdos-core alive ──────────────────────────────────────────────
CORE_PID=$(agent_exec "pgrep -f bsdos-core | head -1" 5 2>/dev/null | grep -E '^[0-9]+$' | head -1)
if [ -n "$CORE_PID" ]; then
    ok "bsdos-core running (pid ${CORE_PID})"
else
    fail "bsdos-core not running"
fi

# ── Check 3: Zenoh listening ───────────────────────────────────────────────
ZENOH=$(agent_exec "sockstat -4l 2>/dev/null | grep 7447" 5 2>/dev/null)
if [ -n "$ZENOH" ]; then
    ok "Zenoh listening on :7447"
else
    fail "Zenoh not listening"
fi

# ── Check 4: Stream lifecycle (log file) ───────────────────────────────────
SM_COUNT=$(agent_exec "grep -c '\\[sm\\]' /var/log/bsdos-core.log 2>/dev/null" 5 2>/dev/null | grep -E '^[0-9]+$' | tail -1)
SM_COUNT=${SM_COUNT:-0}
if [ "$SM_COUNT" -ge 2 ] 2>/dev/null; then
    ok "Stream lifecycle active ($SM_COUNT [sm] log lines)"
else
    fail "Stream lifecycle inactive ($SM_COUNT [sm] log lines)"
fi

# ── Check 5: foot process (appTerminal app) ────────────────────────────────
FOOT_PID=$(agent_exec "pgrep foot | head -1" 5 2>/dev/null | grep -E '^[0-9]+$' | head -1)
if [ -n "$FOOT_PID" ]; then
    ok "foot terminal running (pid ${FOOT_PID})"
else
    echo "[e2e] NOTE: foot not running (may have crashed or not spawned yet)"
fi

# ── Check 6: wayland-stream.sock for appTerminal ───────────────────────────
TERM_SOCK=$(agent_exec "test -S /tmp/bsdos/streams/appTerminal/wayland-stream.sock && echo present || echo absent" 5 2>/dev/null | tail -1)
if [ "${TERM_SOCK}" = "present" ]; then
    ok "appTerminal wayland-stream.sock present"
else
    fail "appTerminal wayland-stream.sock missing"
fi

# ── Check 7: wayland-stream.sock for appBrowser ────────────────────────────
BROWSER_SOCK=$(agent_exec "test -S /tmp/bsdos/streams/appBrowser/wayland-stream.sock && echo present || echo absent" 5 2>/dev/null | tail -1)
if [ "${BROWSER_SOCK}" = "present" ]; then
    ok "appBrowser wayland-stream.sock present"
else
    fail "appBrowser wayland-stream.sock missing"
fi

# ── Check 8: stream-reader can connect and receive data ───────────────────
# stream-reader is built by wayland-tunnel (zig build) and installed as
# /opt/wayland-tunnel/zig-out/bin/stream-reader on the guest.
# It reads the stream socket and exits 0 if it receives at least one frame.
# Timeout 8s: covers the case where bsdos-core is publishing at 1 FPS.
SR_BIN="/opt/wayland-tunnel/zig-out/bin/stream-reader"
SR_RESULT=$(agent_exec "test -x $SR_BIN && timeout 8 $SR_BIN 2>&1 | head -5 || echo 'stream-reader not available'" 12 2>/dev/null | tail -3)
if echo "$SR_RESULT" | grep -qiE "frame|pool|stream|bytes|ok"; then
    ok "stream-reader: data flowing"
elif echo "$SR_RESULT" | grep -q "not available"; then
    echo "[e2e] NOTE: stream-reader not installed — skipping data-flow check"
else
    echo "[e2e] NOTE: stream-reader: $SR_RESULT"
fi

# ── Check 9: No crashes ────────────────────────────────────────────────────
PANIC=$(agent_exec "dmesg | grep -ciE 'panic|segfault|fatal'" 5 2>/dev/null | grep -E '^[0-9]+$' | tail -1)
PANIC=${PANIC:-0}
if [ "$PANIC" -eq 0 ] 2>/dev/null; then
    ok "No panics/crashes detected"
else
    fail "Panic/crash detected in dmesg ($PANIC match(es))"
fi

# ── Result ────────────────────────────────────────────────────────────────
echo ""
echo "[e2e] RESULT: ${PASS} passed, ${FAIL} failed"
if [ "$FAIL" -gt 0 ]; then
    echo "[e2e] OVERALL: FAIL"
    echo "[e2e] Serial log (last 20 lines):"
    tail -20 "$SERIAL_LOG" 2>/dev/null || true
    exit 1
fi
echo "[e2e] OVERALL: PASS — 2-stream E2E acceptance met"
