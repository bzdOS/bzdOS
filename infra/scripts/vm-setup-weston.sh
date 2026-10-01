#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"
echo "Installing Wayland compositor (cage, sway, wf-recorder, grim)..."
ssh_root "pkg install -y cage sway wf-recorder grim"
echo "Done. Start: make vm-start-cage"
