#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"

echo "Installing Zig 0.15.2 in guest via pkg..."
ssh_root "pkg install -y zig"
ssh_guest "zig version"
echo "Zig installed"
