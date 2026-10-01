#!/bin/sh
# Deploy the full bsdos-core + wayland-tunnel stream pipeline to dev VM (dev-vm)
# via guest-agent (no SSH inside recipe). Transport: virtio-console, host side.
#
# bsdos-core and wayland-tunnel share a private env-var contract
# (WLSTREAM_COMPOSITOR_SOCK/WAYLAND_SOCK/STREAM_SOCK/INPUT_SOCK, see
# https://github.com/bzdOS/bzdOS/blob/main/docs/STREAM-DEPLOY-CONTRACT.md) that is NOT checked at compile time on
# either side — a rename on one side silently falls back to hardcoded
# defaults on a stale binary of the other. This script always builds and
# installs BOTH halves together so they can never drift independently.
set -eu

SCRIPTS="$(dirname "$(realpath "$0")")"
. "$SCRIPTS/_agent.sh"

die() { echo "FAIL: $*" >&2; exit 1; }
step() { echo; echo "=== $* ==="; }

# Smoke: agent alive
agent_ping >/dev/null 2>&1 || die "agent not responding — is VM running?"

step "1/6 build bsdos-core (cargo build --release --features with-bridge)"
AGENT_EXEC_TIMEOUT=600 agent_exec \
    "export HOME=/home/freebsd PATH=/home/freebsd/.cargo/bin:/usr/local/bin:/usr/bin:/bin; \
     cd /mnt/bsdos/bsdos-core && \
     cargo build --release --features with-bridge 2>&1 | tail -20; \
     echo BUILD_OK"

step "2/6 build wayland-tunnel (+ wl-keepalive, stream-reader; zig build -Doptimize=ReleaseSafe)"
"$SCRIPTS/build-wayland-tunnel.sh"

step "3/6 install bsdos-core binary + rc.d"
AGENT_EXEC_TIMEOUT=30 agent_exec \
    "install -m 755 /mnt/bsdos/target/release/bsdos-core /usr/local/bin/bsdos-core && \
     install -m 755 /mnt/bsdos/infra/rc.d/bsdos_core /usr/local/etc/rc.d/bsdos_core && \
     echo INSTALL_OK"
# wayland-tunnel/wl-keepalive/stream-reader were already installed by
# build-wayland-tunnel.sh in step 2/6 — kept as a separate script since it's
# also invoked standalone (make wayland-tunnel-build), not duplicated here.

step "4/6 stop old processes"
AGENT_EXEC_TIMEOUT=15 agent_exec \
    "service bsdos_core stop 2>/dev/null || pkill -f bsdos-core 2>/dev/null || true; \
     sleep 2; \
     pkill -9 cage 2>/dev/null || true; \
     pkill -9 wayland-tunnel 2>/dev/null || true; \
     pkill -9 -f 'chrome.*ozone' 2>/dev/null || true; \
     rm -rf /tmp/bsdos/streams/* 2>/dev/null || true; \
     echo STOP_OK"

step "5/6 start via rc.d"
AGENT_EXEC_TIMEOUT=10 agent_exec \
    "service bsdos_core start && echo START_OK"

step "6/6 smoke-check (wait up to 30s for READY)"
i=0
ready=0
while [ "$i" -lt 30 ]; do
    result=$(AGENT_EXEC_TIMEOUT=5 agent_exec \
        "grep -q 'READY:\|Zenoh session\|sm\].*started' /var/log/bsdos-core.log 2>/dev/null && echo READY || true" \
        2>/dev/null || true)
    if echo "$result" | grep -q READY; then
        echo "OK: bsdos-core READY in ${i}s"
        ready=1
        break
    fi
    sleep 1
    i=$((i+1))
done
[ "$ready" -eq 1 ] || echo "WARN: READY not seen in 30s — check log"

echo
AGENT_EXEC_TIMEOUT=10 agent_exec \
    "sockstat -4l 2>/dev/null | grep 443 && echo 'OK: :443 listening' || echo 'WARN: :443 not listening'"
AGENT_EXEC_TIMEOUT=10 agent_exec \
    "grep 'appBrowser:input.*listen' /var/log/bsdos-core.log 2>/dev/null | tail -2 \
     && echo 'OK: input handler active' || echo 'WARN: input handler not confirmed'"
echo "--- last 5 log lines ---"
AGENT_EXEC_TIMEOUT=5 agent_exec \
    "tail -5 /var/log/bsdos-core.log 2>/dev/null || echo '(no log)'"

echo
echo "=== deploy-dev-vm done ==="
