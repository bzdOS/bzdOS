#!/bin/sh
set -eu

. "$(dirname "$0")/_ssh.sh"

echo "Setting up jails..."
ssh_root "/opt/proto/jailmgr.sh setup-all"
echo "Jails ready"
