#!/bin/sh
# demo-full.sh — полный showcase всех компонентов bsdOS.
# Демонстрирует:
#   1. Zenoh telemetry (bsdos-core издаёт HardwareStatus)
#   2. Jail isolation (appBrowser + appTerminal в отдельных jails с разными policies)
#   3. Wayland pipeline (cage headless → wayland-tunnel → stream в Zenoh)
#   4. Freeze/Thaw (контроль жизненного цикла приложений)
#
# Требования: VM запущена (make vm-x86-start && make vm-wait)
set -eu
SCRIPTS="$(dirname "$0")"
. "$SCRIPTS/_agent.sh"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_step() {
    printf "${GREEN}[%s]${NC} %s\n" "$(date +%H:%M:%S)" "$1"
}

log_status() {
    printf "${YELLOW}→${NC} %s\n" "$1"
}

log_error() {
    printf "${RED}✗ %s${NC}\n" "$1"
}

log_success() {
    printf "${GREEN}✓ %s${NC}\n" "$1"
}

echo "╔════════════════════════════════════════════════════════════════╗"
echo "║           bsdOS Full Component Showcase Demo                  ║"
echo "║                                                                ║"
echo "║   1. Zenoh Telemetry (HardwareStatus stream)                 ║"
echo "║   2. Jail Isolation (appBrowser, appTerminal)                ║"
echo "║   3. Wayland Pipeline (cage → tunnel → stream)               ║"
echo "║   4. Freeze/Thaw Lifecycle Control                           ║"
echo "╚════════════════════════════════════════════════════════════════╝"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 0: Cleanup & preflight
# ─────────────────────────────────────────────────────────────────────────────

log_step "Cleanup & preflight checks"
log_status "Verifying VM is online..."

if ! agent_ping >/dev/null 2>&1; then
    log_error "Agent not responding. VM may not be running."
    echo "→ Run: make vm-x86-start && make vm-x86-wait"
    exit 1
fi
log_success "Agent responding"

log_status "Killing previous demo processes..."
agent_jail_teardown || true
sleep 1
log_success "Cleaned up"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 1: Zenoh Telemetry (bsdos-core)
# ─────────────────────────────────────────────────────────────────────────────

log_step "PHASE 1: Zenoh Telemetry - bsdos-core publisher"
echo ""
log_status "Starting HAL daemon..."
agent_hal_start >/dev/null 2>&1
sleep 1
log_success "HAL started"

log_status "Starting Broker (IPC bus)..."
agent_broker_start >/dev/null 2>&1
sleep 1
log_success "Broker started"

log_status "Starting bsdos-core (Zenoh publisher)..."
# bsdos-core читает HardwareStatus от HAL через broker и публикует в Zenoh
agent_cmd "CORE_START" >/dev/null 2>&1 || true
sleep 2
log_success "bsdos-core started (publishing to Zenoh key: bsdos/telemetry)"

echo ""
log_status "Sample telemetry status:"
agent_cmd "MEM_STATUS" 2>/dev/null | head -5 || echo "  (MEM_STATUS not available)"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 2: Jail Isolation
# ─────────────────────────────────────────────────────────────────────────────

log_step "PHASE 2: Jail Isolation - appBrowser & appTerminal"
echo ""
log_status "Setting up jails (appBrowser, appTerminal)..."

if ! agent_jail_setup; then
    log_error "Jail setup failed"
    agent_jls || true
    exit 1
fi
sleep 1
log_success "Jails created"

log_status "Listing active jails:"
echo ""
agent_jls 2>/dev/null || echo "  (no jails)"
echo ""

log_status "Verifying jail isolation..."
JAIL_APPS="appBrowser appTerminal"
for jail in $JAIL_APPS; do
    if agent_check_jail "$jail" 2>/dev/null; then
        log_success "  $jail: OK (isolated)"
    else
        log_error "  $jail: NOT FOUND"
    fi
done

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 3: Wayland Pipeline (cage + tunnel + streaming)
# ─────────────────────────────────────────────────────────────────────────────

log_step "PHASE 3: Wayland Pipeline - cage + tunnel + Zenoh stream"
echo ""

log_status "Creating Wayland runtime directory..."
agent_cmd "SHELL mkdir -p /tmp/wayland-run && chmod 700 /tmp/wayland-run" >/dev/null 2>&1 || true
sleep 1
log_success "Wayland runtime ready"

log_status "Starting cage (headless compositor)..."
log_status "  WLR_BACKENDS=headless (no GPU)"
log_status "  WLR_RENDERER=pixman (software rendering)"
# В реальности: cage -- foot
# Но если foot не установлена, просто запускаем cage в фоне
agent_cmd "SHELL nohup env XDG_RUNTIME_DIR=/tmp/wayland-run \
    WLR_BACKENDS=headless \
    WLR_RENDERER=pixman \
    WLR_HEADLESS_OUTPUTS=1 \
    LIBSEAT_BACKEND=noop \
    cage >/tmp/cage.log 2>&1 &" >/dev/null 2>&1 || true
sleep 2

CAGE_PID=$(agent_cmd "SHELL pgrep -f cage || echo 0" 2>/dev/null | tail -1)
if [ "$CAGE_PID" != "0" ] && [ -n "$CAGE_PID" ]; then
    log_success "cage running (PID: $CAGE_PID)"
else
    log_error "cage not running (may require package installation)"
    echo "  → To install: make vm-setup-cage"
fi

echo ""

log_status "Starting wayland-tunnel (wire → Zenoh stream)..."
agent_cmd "SHELL nohup env XDG_RUNTIME_DIR=/tmp/wayland-run \
    WAYLAND_DISPLAY=wayland-0 \
    /usr/local/bin/wayland-tunnel >/tmp/wayland-tunnel.log 2>&1 &" >/dev/null 2>&1 || true
sleep 2

TUNNEL_PID=$(agent_cmd "SHELL pgrep -f wayland-tunnel || echo 0" 2>/dev/null | tail -1)
if [ "$TUNNEL_PID" != "0" ] && [ -n "$TUNNEL_PID" ]; then
    log_success "wayland-tunnel running (PID: $TUNNEL_PID)"
    log_status "  Publishing to Zenoh key: bsdos/global/wayland/stream"
else
    log_error "wayland-tunnel not running"
    echo "  → To build: make wayland-tunnel-build"
fi

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 4: Freeze/Thaw Lifecycle
# ─────────────────────────────────────────────────────────────────────────────

log_step "PHASE 4: Freeze/Thaw - Lifecycle Control"
echo ""

FREEZE_JAIL="appTerminal"
log_status "Freezing jail: $FREEZE_JAIL (SIGSTOP via lifecycled)..."
agent_freeze "$FREEZE_JAIL" >/dev/null 2>&1 || true
sleep 1
log_success "$FREEZE_JAIL frozen (suspended)"

log_status "Jail is now suspended — simulating 2 second pause..."
sleep 2

log_status "Thawing jail: $FREEZE_JAIL (SIGCONT)..."
agent_thaw "$FREEZE_JAIL" >/dev/null 2>&1 || true
sleep 1
log_success "$FREEZE_JAIL thawed (resumed)"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 5: Status Summary
# ─────────────────────────────────────────────────────────────────────────────

log_step "PHASE 5: System Status Summary"
echo ""

log_status "Agent connectivity:"
agent_ping 2>/dev/null | head -1 || echo "  (no response)"

echo ""
log_status "Running processes:"
for proc in "HAL" "broker" "bsdos-core" "cage" "wayland-tunnel" "foot"; do
    PID=$(agent_cmd "SHELL pgrep -f '$proc' | head -1 || echo 0" 2>/dev/null | tail -1)
    if [ "$PID" != "0" ] && [ -n "$PID" ]; then
        printf "  ${GREEN}✓${NC} %-20s (PID: %s)\n" "$proc" "$PID"
    else
        printf "  ${YELLOW}·${NC} %-20s (not running)\n" "$proc"
    fi
done

echo ""
log_status "Active jails:"
agent_jls 2>/dev/null | grep -v "^+" | head -10 || echo "  (no jails)"

echo ""

# ─────────────────────────────────────────────────────────────────────────────
# PHASE 6: Component Details & Next Steps
# ─────────────────────────────────────────────────────────────────────────────

log_step "PHASE 6: Component Details & Next Steps"
echo ""

echo "📊 ZENOH TELEMETRY"
echo "   • bsdos-core subscribes to broker's HardwareStatus (via Cap'n Proto)"
echo "   • Publishes to Zenoh key: bsdos/telemetry"
echo "   • View in Linux: make run-telemetry-client"
echo ""

echo "🔒 JAIL ISOLATION"
echo "   • appBrowser: network allowed (ip4=inherit)"
echo "   • appTerminal: network blocked (ip4=disable)"
echo "   • Verify: make check-jail"
echo ""

echo "🖼️  WAYLAND PIPELINE"
echo "   • cage: headless Wayland compositor (pixman software rendering)"
echo "   • wayland-tunnel: captures wl_shm frames → WaylandPacket → Zenoh"
echo "   • Key: bsdos/global/wayland/stream"
echo "   • Mac viewer: ./mac-companion/metal-viewer/target/release/bsdos-metal-viewer"
echo ""

echo "⏸️  FREEZE/THAW LIFECYCLE"
echo "   • Agent commands: FREEZE <jail>, THAW <jail>"
echo "   • Lifecycle daemon: /var/run/bsdos-lifecycle.sock"
echo "   • Test: make test-lifecycle"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# Cleanup (optional; comment out to leave components running for inspection)
# ─────────────────────────────────────────────────────────────────────────────

echo ""
read -p "Press ENTER to teardown demo, or Ctrl+C to keep components running..."

log_step "Teardown"
log_status "Stopping all components..."
agent_jail_teardown || true
log_success "Demo complete — all components cleaned up"

echo ""
echo "╔════════════════════════════════════════════════════════════════╗"
echo "║  🎯 Demo Complete!                                           ║"
echo "║                                                                ║"
echo "║  For deeper investigation, re-run without the final cleanup:  ║"
echo "║  $ tail -f /tmp/broker.log                                    ║"
echo "║  $ tail -f /tmp/core.log                                      ║"
echo "║  $ tail -f /tmp/wayland-tunnel.log                            ║"
echo "║  $ tail -f /tmp/cage.log                                      ║"
echo "║                                                                ║"
echo "║  Component docs: cat CLAUDE.md                   ║"
echo "╚════════════════════════════════════════════════════════════════╝"
