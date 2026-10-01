#!/bin/sh
set -eu
SCRIPTS="$(dirname "$0")"
XML="$SCRIPTS/../vm-templates/bsdos-dev.xml"

echo "Defining bsdos-dev domain in libvirt..."
virsh define "$XML"
echo "Done. Run 'make vm-start' to boot."
