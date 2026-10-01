#!/bin/sh
[ -r "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}" ] && . "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}"
# Настроить Zenoh NIC (vtnet1) в VM на статический IP ${BSDOS_DEV_IP}/28.
# Запускать после vm-x86-wait когда VM уже загружена.
set -eu
. "$(dirname "$0")/_ssh.sh"

ZENOH_IP="${ZENOH_LISTEN_IP:-${BSDOS_DEV_IP:?set BSDOS_DEV_IP in /etc/bsdos/hosts.env}}"
ZENOH_MASK="28"
ZENOH_GW="${BSDOS_GW_IP:?set BSDOS_GW_IP in /etc/bsdos/hosts.env}"
IFACE="vtnet1"

echo "=== Configuring Zenoh NIC ($IFACE) in FreeBSD VM ==="

# Определить второй интерфейс (vtnet1 = второй virtio-net)
ssh_guest "ifconfig $IFACE 2>/dev/null | head -3 || echo 'vtnet1 not found'"

# Назначить статический IP
ssh_root "ifconfig $IFACE ${ZENOH_IP}/${ZENOH_MASK}"
ssh_root "route add -net 0.0.0.0 $ZENOH_GW 2>/dev/null || true"

# Прописать в rc.conf для persistent конфигурации
if ! ssh_guest "grep -q 'ifconfig_vtnet1' /etc/rc.conf 2>/dev/null"; then
    ssh_root "sh -c 'echo ifconfig_vtnet1=\\\"inet ${ZENOH_IP}/${ZENOH_MASK}\\\" >> /etc/rc.conf'"
fi

echo "Verifying..."
ssh_guest "ifconfig $IFACE | grep 'inet '"
ssh_guest "ping -c1 -W1 ${ZENOH_GW} 2>&1 | head -2"

echo ""
echo "=== Zenoh endpoint ready: tls/${ZENOH_IP}:7447 ==="
echo "  Mac: ZENOH_TLS_CA=certs/ca.pem bsdos-metal-viewer"
echo "  Peer: tls/${ZENOH_IP}:7447"
