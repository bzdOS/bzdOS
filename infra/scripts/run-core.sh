#!/bin/sh
[ -r "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}" ] && . "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}"
set -eu
. "$(dirname "$0")/_ssh.sh"

echo "Starting bsdos-core (Zenoh telemetry publisher)..."
# TLS имеет приоритет над JSON5 файлом.
# ZENOH_TLS=1 → программный TLS (zenoh 1.x, работает на FreeBSD)
# ZENOH_CONFIG → файловая конфигурация (только если нет TLS сертификатов)
# Zenoh слушает строго на ${BSDOS_DEV_IP}:7447 (TLS only, no plaintext)
# ZENOH_LISTEN_IP — конкретный IP, не 0.0.0.0
ssh_root "pkill -f bsdos-core 2>/dev/null || true"
ssh_root "nohup env ZENOH_TLS=1 \
    ZENOH_LISTEN_IP=${BSDOS_DEV_IP:?set BSDOS_DEV_IP in /etc/bsdos/hosts.env} \
    ZENOH_LISTEN_PORT=443 \
    RUST_LOG=zenoh=trace,zenoh_link_tls=trace,zenoh_transport=trace,rustls=trace \
    /usr/local/bin/bsdos-core >/tmp/core.log 2>&1 &"
echo "  Mode: TLS (ZENOH_TLS=1, bind: ${BSDOS_DEV_IP:?set BSDOS_DEV_IP in /etc/bsdos/hosts.env}:443)"
sleep 1

echo "Verifying bsdos-core is running..."
if ssh_guest "pgrep -f bsdos-core >/dev/null 2>&1"; then
    echo "bsdos-core confirmed running"
    ssh_guest "tail -3 /tmp/core.log"
    echo "Log location: /tmp/core.log"
else
    echo "ERROR: bsdos-core failed to start"
    ssh_guest "tail -10 /tmp/core.log 2>/dev/null" || echo "(no log output)"
    exit 1
fi
