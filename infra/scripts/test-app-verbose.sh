#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"
SCRIPTS="$(dirname "$0")"

echo "=== proto-app jail test (verbose) ==="

# Чистый старт
"$SCRIPTS/jail-teardown.sh" >/dev/null 2>&1 || true
ssh_root "pkill -f broker 2>/dev/null; pkill -f bsdos-hal 2>/dev/null; true"

# HAL + broker + nc listener
ssh_root "nohup /usr/local/bin/bsdos-hal >/tmp/hal.log 2>&1 &"
ssh_guest "nohup /opt/proto-src/broker/target/release/broker >/tmp/broker.log 2>&1 &"
ssh_guest "nohup sh -c 'while true; do nc -l 9997 </dev/null; done' >/dev/null 2>&1 &"
sleep 1

# Поднять jails
"$SCRIPTS/jail-setup.sh" >/dev/null 2>&1

# Убедиться что jails запущены
"$SCRIPTS/verify-jails.sh"

# Дополнительная диагностика
echo "-- Data directory listing --"
ssh_root "ls -la /opt/proto/data/appA/"

# Запуск
echo "-- appA --"
ssh_root "jexec appA sh -c 'ls /data/ && /data/proto-app > /tmp/app.out 2>&1; echo EXIT:\$?; cat /tmp/app.out'"

echo "-- broker log --"
ssh_guest "head -5 /tmp/broker.log 2>/dev/null"

# Cleanup
"$SCRIPTS/jail-teardown.sh" >/dev/null 2>&1 || true
ssh_guest "pkill nc 2>/dev/null; pkill -f broker 2>/dev/null; true"
echo "=== done ==="
