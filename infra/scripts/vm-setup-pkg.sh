#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"
ssh_root "pkg install -y rust tmux"
