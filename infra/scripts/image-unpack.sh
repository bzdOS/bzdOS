#!/bin/sh
set -eu

: "${CURDIR:=$(pwd)}"
: "${VM_IMG:=$CURDIR/freebsd14.qcow2}"

if [ -f "$VM_IMG" ]; then
    echo "Image already unpacked: $VM_IMG"
    exit 0
fi

cd "$CURDIR"
echo "Unpacking FreeBSD image..."
xz -dk freebsd14.qcow2.xz

echo "Moving image..."
mv freebsd14.qcow2 "$VM_IMG"

echo "Resizing image..."
qemu-img resize "$VM_IMG" +12G

echo "Image ready: $VM_IMG"
