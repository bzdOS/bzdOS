#!/bin/sh
[ -r "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}" ] && . "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}"
# Добавить ${BSDOS_DEV_IP} как alias на br0 для bsdOS Zenoh TLS endpoint.
# Запускать после каждой перезагрузки хоста (или добавить в /etc/network/interfaces).
set -eu

ZENOH_IP="${BSDOS_DEV_IP:?set BSDOS_DEV_IP in /etc/bsdos/hosts.env}"
IFACE="br0"

if ip addr show "$IFACE" | grep -q "$ZENOH_IP"; then
    echo "$ZENOH_IP already configured on $IFACE"
else
    ip addr add "${ZENOH_IP}/28" dev "$IFACE"
    echo "Added $ZENOH_IP to $IFACE"
fi

echo "bsdOS Zenoh TLS endpoint: tls/$ZENOH_IP:7447"
