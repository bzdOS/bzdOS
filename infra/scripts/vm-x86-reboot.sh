#!/bin/sh
[ -r "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}" ] && . "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}"
# Graceful reboot of x86 FreeBSD VM with virtio-console hot-load fixup.
# Problem: virtio_console module loaded but /dev/ttyV* not created until full reboot.
# Solution: shutdown -r now via SSH, wait for return.
set -eu

: "${SSH_KEY:=${BSDOS_SSH_KEY:?set BSDOS_SSH_KEY in /etc/bsdos/hosts.env}}"
: "${VM_SSH_PORT:=2222}"

_SSH_CONTROL="/tmp/bsdos-ssh-ctl-%r@%h:%p"
_SSH_OPTS="-p $VM_SSH_PORT -i $SSH_KEY \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ControlMaster=auto \
    -o ControlPath=$_SSH_CONTROL \
    -o ControlPersist=120"

ssh_root() {
    # shellcheck disable=SC2086
    ssh $_SSH_OPTS freebsd@localhost "su -m root -c \"$1\""
}

ssh_master_close() {
    # shellcheck disable=SC2086
    ssh $_SSH_OPTS -O exit freebsd@localhost 2>/dev/null || true
}

echo "=== FreeBSD VM Reboot ==="
echo "Initiating graceful reboot..."
ssh_root "shutdown -r now 2>/dev/null" || true

# Close SSH master to force reconnect after reboot
ssh_master_close

# Short wait for shutdown to propagate
sleep 3

echo "Rebooting... please run: make vm-x86-wait"
