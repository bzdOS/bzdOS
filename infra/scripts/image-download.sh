#!/bin/sh
set -eu

: "${CURDIR:=$(pwd)}"

image_file="$CURDIR/freebsd14.qcow2.xz"

if [ -f "$image_file" ]; then
    echo "Image already exists: $image_file"
    exit 0
fi

echo "Downloading FreeBSD 14.4 aarch64..."
cd "$CURDIR"
fetch "https://download.freebsd.org/releases/VM-IMAGES/14.4-RELEASE/aarch64/Latest/FreeBSD-14.4-RELEASE-arm64-aarch64-BASIC-CLOUDINIT-ufs.qcow2.xz"

echo "Download complete"
