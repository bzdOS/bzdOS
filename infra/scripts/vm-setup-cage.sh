#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"

echo "Installing Wayland compositor (cage) + capture tools..."
ssh_root "pkg install -y cage wf-recorder grim sway wlr-randr"
echo "=== cage installation complete ==="
