#!/bin/sh
. "$(dirname "$0")/_ssh.sh"
ssh_root "cd /mnt/bsdos/wayland-tunnel && zig build 2>&1"
