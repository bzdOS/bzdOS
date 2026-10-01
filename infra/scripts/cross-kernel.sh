#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"
CROSS_ARCH="${CROSS_ARCH:-aarch64}"
KERNCONF="${KERNCONF:-BSDOS-arm64}"
echo "=== cross-kernel: $CROSS_ARCH ==="
echo "Building kernel inside FreeBSD VM for $CROSS_ARCH..."
case "$CROSS_ARCH" in
    aarch64) TARGET=arm64; TARGET_ARCH=aarch64 ;;
    riscv64) TARGET=riscv; TARGET_ARCH=riscv64 ;;
    *) echo "ERROR: unsupported CROSS_ARCH=$CROSS_ARCH"; exit 1 ;;
esac
ssh_root "env MAKEOBJDIRPREFIX=/usr/obj make -C /usr/src -j$JOBS \
    TARGET=$TARGET TARGET_ARCH=$TARGET_ARCH \
    buildworld buildkernel KERNCONF=$KERNCONF NO_CLEAN=yes \
    > /tmp/crossbuild.log 2>&1"
echo "Cross-build log: /tmp/crossbuild.log"
ssh_root "tail -5 /tmp/crossbuild.log"
