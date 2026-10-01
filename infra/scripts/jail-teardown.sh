#!/bin/sh
set -eu

. "$(dirname "$0")/_ssh.sh"

echo "Tearing down jails..."
ssh_root "/opt/proto/jailmgr.sh teardown-all"
echo "Jails removed"
