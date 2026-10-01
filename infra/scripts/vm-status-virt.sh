#!/bin/sh
set -eu
echo "=== bsdos-dev status ==="
virsh domstate bsdos-dev 2>/dev/null || echo "Domain not defined — run: make vm-define"
echo ""
echo "=== SPICE port ==="
virsh domdisplay bsdos-dev 2>/dev/null || echo "(not running)"
echo ""
echo "=== Network ==="
virsh domifaddr bsdos-dev 2>/dev/null | head -5 || echo "(not running)"
