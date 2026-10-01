#!/bin/sh
set -eu

. "$(dirname "$0")/_ssh.sh"

echo "[builder-up] Checking FreeBSD builder prerequisites..."

# Check git
echo -n "  git: "
if ssh_guest "which git >/dev/null 2>&1"; then
    echo "OK"
else
    echo "MISSING — installing..."
    ssh_root "pkg install -y git"
fi

# Check /obj directory
echo -n "  /obj: "
ssh_root "mkdir -p /obj && df /obj" | tail -1
echo "    OK"

# Check /usr/src
echo -n "  /usr/src: "
if ssh_guest "test -d /usr/src/.git"; then
    echo "FOUND"
else
    echo "MISSING"
    echo ""
    echo "[!] /usr/src not found. Run: make src-fetch"
    exit 1
fi

echo ""
echo "[builder-up] Status: ready for buildkernel"
