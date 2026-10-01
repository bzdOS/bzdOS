#!/bin/sh
set -eu
# Retrieve current Zenoh access token from guest

. "$(dirname "$0")/_ssh.sh"

TOKEN=$(ssh_root "cat /run/bsdos-access.token 2>/dev/null || echo 'token not found'")
echo "$TOKEN"
