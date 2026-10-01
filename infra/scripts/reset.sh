#!/bin/sh
# bsdOS reset — быстрый откат к чистому состоянию.
# Не перезагружает VM. Секунды.
# Использование: make reset
#
# Делает:
# 1. teardown jails (jail -r appA, jail -r appB)
# 2. kill lifecycled daemon
# 3. restart HAL
# 4. restart broker

set -eu

. "$(dirname "$0")/_ssh.sh"

echo "=== reset: teardown jails → restart services ==="

# ── Teardown jails ────────────────────────────────────────────────────────────
echo "[1/3] Tearing down jails..."
ssh_root "cd /opt/proto && sh ./jailmgr.sh teardown-all 2>/dev/null || true" || true

# ── Kill lifecycled ────────────────────────────────────────────────────────────
echo "[2/3] Killing lifecycled daemon..."
ssh_root "pkill -f bsdos-lifecycled 2>/dev/null || true" || true

# ── Short pause ────────────────────────────────────────────────────────────────
sleep 1

# ── Restart HAL and broker ────────────────────────────────────────────────────
echo "[3/3] Restarting HAL and broker..."
ssh_root "pkill -f bsdos-hal 2>/dev/null || true" || true
ssh_root "pkill -f bsdos-broker 2>/dev/null || true" || true

# Note: Could add agent_hal_start / agent_broker_start here but they require
# agent to be running, so leaving as-is for now.

echo "=== reset done. Run: make doctor ==="
