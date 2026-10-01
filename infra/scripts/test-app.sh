#!/bin/sh
set -eu
. "$(dirname "$0")/_agent.sh"
. "$(dirname "$0")/_ssh.sh"
SCRIPTS="$(dirname "$0")"

echo "=== proto-app jail test ==="

# Чистый старт
agent_jail_teardown >/dev/null 2>&1 || true

# HAL + broker + nc listener
agent_hal_start
agent_broker_start
ssh_guest "nohup sh -c 'while true; do nc -l 9997 </dev/null; done' >/dev/null 2>&1 &"
sleep 1

# Поднять jails
agent_jail_setup >/dev/null 2>&1

# Убедиться что jails запущены
"$SCRIPTS/verify-jails.sh"

# Запуск
echo "-- appA --"
ssh_root "jexec appA env NET_TARGET=127.0.0.1:9997 /data/proto-app 2>&1" || echo "exit: $?"

echo "-- broker log --"
ssh_guest "head -5 /tmp/broker.log 2>/dev/null"

# Cleanup
agent_jail_teardown >/dev/null 2>&1 || true
ssh_guest "pkill nc 2>/dev/null; pkill -f broker 2>/dev/null; true"
echo "=== done ==="
