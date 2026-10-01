#!/bin/sh
set -eu

if pkill -f qemu-system-aarch64; then
    sleep 1
else
    echo "VM not running"
fi
