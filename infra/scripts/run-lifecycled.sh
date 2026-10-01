#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"
echo "Starting lifecycle daemon..."
ssh_root "pkill -f bsdos-lifecycled 2>/dev/null || true"
ssh_root "nohup /usr/local/bin/bsdos-lifecycled >/tmp/lifecycle.log 2>&1 &"
sleep 1
ssh_guest "cat /tmp/lifecycle.log"
echo "Daemon on /var/run/bsdos-lifecycle.sock"
echo "  printf 'STATUS appA\n' | nc -w2 localhost 2222... (via ssh_root nc -U)"
