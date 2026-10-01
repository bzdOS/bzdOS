#!/bin/sh
set -eu
cd "$(dirname "$0")/../.."

IMG="freebsd-x86.qcow2"
XZ="freebsd-x86.qcow2.xz"

[ -f "$IMG" ] && { echo "Image already unpacked: $IMG"; exit 0; }
[ -f "$XZ" ]  || { echo "ERROR: $XZ not found — run: make image-download-x86" >&2; exit 1; }

echo "Unpacking..."
xz -dk "$XZ"
# Версионно-нейтрально: имя файла зависит от REL (14.4/15.1-RC2/...).
mv FreeBSD-*-amd64-BASIC-CLOUDINIT-ufs.qcow2 "$IMG" 2>/dev/null || \
mv *.qcow2 "$IMG" 2>/dev/null || true
# Билдеру нужно место под src (~4G) + obj world+kernel (~25G). Для чистого dev/runtime хватит меньше.
qemu-img resize "$IMG" "+${IMG_GROW:-40G}"
echo "Ready: $IMG ($(qemu-img info $IMG | grep 'virtual size'))"
