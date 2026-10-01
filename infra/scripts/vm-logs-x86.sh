#!/bin/sh
set -eu

LOGFILE="${BSDOS_ROOT:?set BSDOS_ROOT in /etc/bsdos/hosts.env}/artefacts/logs/serial-x86.log"

if [ ! -f "$LOGFILE" ]; then
  echo "Log file not found: $LOGFILE"
  echo "Start the VM first: make vm-start-virt-x86"
  exit 1
fi

echo "Tailing serial console logs for bsdos-x86..."
echo "(Ctrl+C to exit)"
echo ""

tail -f "$LOGFILE"
