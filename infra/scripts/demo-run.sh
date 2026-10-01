#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"

echo "-- teardown any previous run --"
ssh_root "/opt/proto/jailmgr.sh teardown-all 2>/dev/null || true"
ssh_root "pkill -f bsdos-hal 2>/dev/null || true"
ssh_guest "pkill -f broker 2>/dev/null || true"
ssh_guest "pkill nc 2>/dev/null || true"
# Free port 9999 if anything else holds it (stale process from prev run)
ssh_root "pkill -f 'nc.*9999' 2>/dev/null || true"
sleep 1

echo "-- start HAL daemon (needs root for /var/run) --"
ssh_root "nohup /usr/local/bin/bsdos-hal >/tmp/hal.log 2>&1 &"
sleep 1

echo "-- start broker (binds TCP :9999, forwards get_hal_* to HAL) --"
ssh_guest "nohup /opt/proto-src/broker/target/release/broker >/tmp/broker.log 2>&1 &"
sleep 1

echo "-- start tcp listener on :9997 (NET test target for jail apps) --"
ssh_guest "nohup sh -c 'while true; do nc -l 9997 </dev/null; done' >/dev/null 2>&1 &"

echo "-- jail setup --"
ssh_root "/opt/proto/jailmgr.sh setup-all"

echo ""
echo "===== appA (ip4=inherit — network ALLOWED by kernel) ====="
ssh_root "jexec appA env NET_TARGET=127.0.0.1:9997 /data/proto-app"

echo ""
echo "===== appB (ip4=disable — network BLOCKED by kernel) ====="
ssh_root "jexec appB env NET_TARGET=127.0.0.1:9997 /data/proto-app"

echo ""
echo "===== broker log (identity per socket) ====="
ssh_guest "cat /tmp/broker.log"

echo "===== HAL log ====="
ssh_guest "cat /tmp/hal.log"

echo ""
echo "-- teardown --"
ssh_root "/opt/proto/jailmgr.sh teardown-all"
ssh_guest "pkill -f broker 2>/dev/null || true"
ssh_guest "pkill nc 2>/dev/null || true"

echo ""
echo "=== demo complete ==="
