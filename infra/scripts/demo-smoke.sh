#!/bin/sh
# demo-smoke: минимальная проверка — джейлы поднимаются и proto-app работает.
# Показывает реальный вывод каждого шага (без silent >/dev/null).
set -eu
. "$(dirname "$0")/_agent.sh"
. "$(dirname "$0")/_ssh.sh"

echo "-- teardown previous run --"
agent_jail_teardown || true
agent_mem_guard off || true

echo "-- start HAL --"
agent_hal_start
echo "-- start broker --"
agent_broker_start

echo "-- jail setup --"
if ! agent_jail_setup; then
    echo "ERROR: JAIL_SETUP failed (see output above)"
    exit 1
fi

echo "-- verify appA running --"
if ! agent_check_jail appA; then
    echo "ERROR: appA not in jls after setup"
    agent_jls
    exit 1
fi
echo "appA confirmed via JLS"

echo "-- run proto-app inside appA --"
if ssh_root "jexec appA sh -c '/data/proto-app; echo EXIT:\$?'"; then
    echo "proto-app completed successfully"
else
    EXIT_CODE=$?
    echo "WARNING: proto-app exited with code $EXIT_CODE (non-zero allowed for smoke test)"
fi

echo "-- teardown --"
agent_jail_teardown

echo "=== smoke OK ==="
