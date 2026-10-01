#!/bin/sh
[ -r "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}" ] && . "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}"
# Start bsdos-core in obfs (DPI-bypass) mode.
# Required: BSDOS_OBFS_PSK  (base64 32-byte PSK, same on client and server)
# Optional: ZENOH_LISTEN_IP  (default: ${BSDOS_DEV_IP})
#           ZENOH_LISTEN_PORT (default: 443)
set -eu
. "$(dirname "$0")/_ssh.sh"

PSK="${BSDOS_OBFS_PSK:-}"
if [ -z "$PSK" ]; then
    echo "ERROR: BSDOS_OBFS_PSK is not set" >&2
    exit 1
fi

LISTEN_IP="${ZENOH_LISTEN_IP:-${BSDOS_DEV_IP:?set BSDOS_DEV_IP in /etc/bsdos/hosts.env}}"
LISTEN_PORT="${ZENOH_LISTEN_PORT:-443}"

echo "Starting bsdos-core in obfs mode (${LISTEN_IP}:${LISTEN_PORT})..."
ssh_root "pkill -f bsdos-core 2>/dev/null || true"
ssh_root "nohup env ZENOH_OBFS=1 \
    BSDOS_OBFS_PSK='${PSK}' \
    ZENOH_LISTEN_IP=${LISTEN_IP} \
    ZENOH_LISTEN_PORT=${LISTEN_PORT} \
    RUST_LOG=zenoh=info,zenoh_link_obfs=debug,bsdos_core=info \
    /usr/local/bin/bsdos-core >/tmp/core.log 2>&1 &"
echo "  Mode: obfs (ZENOH_OBFS=1, bind: ${LISTEN_IP}:${LISTEN_PORT})"
sleep 1

echo "Verifying bsdos-core is running..."
if ssh_guest "pgrep -f bsdos-core >/dev/null 2>&1"; then
    echo "bsdos-core confirmed running"
    ssh_guest "tail -5 /tmp/core.log"
else
    echo "ERROR: bsdos-core failed to start"
    ssh_guest "tail -10 /tmp/core.log 2>/dev/null" || echo "(no log output)"
    exit 1
fi
