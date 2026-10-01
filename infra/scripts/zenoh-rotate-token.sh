#!/bin/sh
[ -r "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}" ] && . "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}"
set -eu
. "$(dirname "$0")/_ssh.sh"

echo "Rotating Zenoh access token..."
ssh_root "rm -f /run/bsdos-access.token /run/bsdos-users.conf"
ssh_root "pkill -f bsdos-core 2>/dev/null || true"
sleep 1
ssh_root "nohup env ZENOH_TLS=1 ZENOH_LISTEN_IP=${BSDOS_DEV_IP:?set BSDOS_DEV_IP in /etc/bsdos/hosts.env} \
    /usr/local/bin/bsdos-core >/tmp/core.log 2>&1 &"
sleep 2
NEW_TOKEN=$(ssh_root "cat /run/bsdos-access.token 2>/dev/null" || echo "error")
echo "New token: $NEW_TOKEN"
echo "Update Mac client: BSDOS_TOKEN=$NEW_TOKEN"
