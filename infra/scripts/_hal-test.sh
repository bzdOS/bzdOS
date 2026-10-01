#!/bin/sh
# Runs inside FreeBSD guest as root — tests bsdos-hal Unix socket
set -eu
SOCK=/var/run/bsdos-hal.sock

[ -S "$SOCK" ] || { echo "FAIL: $SOCK not found — run 'make run-zig-hal' first"; exit 1; }

send_cmd() {
    cmd=$1
    # timeout exits 124 when killed — capture output separately from exit code
    result=$(printf '{"cmd":"%s"}\n' "$cmd" | timeout 2 nc -U "$SOCK" 2>/dev/null) || true
    [ -n "$result" ] || result='{"ok":false,"error":"no_response"}'
    echo "  $cmd -> $result"
}

echo "=== HAL test ==="
send_cmd "get_uptime"
send_cmd "get_hostname"
send_cmd "get_battery"
send_cmd "get_memory"
send_cmd "get_cpu_usage"
send_cmd "hal_version"
send_cmd "unknown_cmd"
echo "=== done ==="
