#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"
ssh_guest "cat /tmp/lifecycle.log"
