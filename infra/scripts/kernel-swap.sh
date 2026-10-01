#!/bin/sh
set -eu

. "$(dirname "$0")/_ssh.sh"

KERNCONF="${KERNCONF:-BSDOS-amd64}"

echo "[kernel-swap] Installing kernel from KERNCONF=$KERNCONF"
echo ""

echo "[kernel-swap] Running installkernel..."
ssh_root "env MAKEOBJDIRPREFIX=/usr/obj make -C /usr/src installkernel KERNCONF=$KERNCONF DESTDIR=/ KODIR=/boot/kernel.bsdos"

echo ""
echo "[kernel-swap] Configuring nextboot to use kernel.bsdos..."
ssh_root "nextboot -k kernel.bsdos"

echo ""
echo "[kernel-swap] Kernel installed successfully!"
echo ""
echo "To test the new kernel, restart the VM:"
echo "  make vm-stop && make vm-start && make vm-wait"
echo ""
echo "The VM will boot with kernel.bsdos once. Check dmesg or uname -a to verify."
