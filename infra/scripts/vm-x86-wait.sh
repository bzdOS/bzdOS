#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"

LOG="${LOG:-${BSDOS_ROOT:?set BSDOS_ROOT in /etc/bsdos/hosts.env}/artefacts/logs/serial-x86.log}"
# Max seconds to wait for "login:" before giving up. TCG on x86 can take 2-5 min.
MAX_WAIT="${MAX_WAIT:-360}"
# QEMU process pattern used only to detect that the (single) x86 VM died mid-boot.
# Default matches any qemu-system-x86_64 (this script targets the one x86 VM anyway);
# the previous '.*freebsd-x86' suffix gave a false "VM died" if VM_X86_IMG was
# overridden to a filename without that substring. Override if multiple x86 QEMUs run:
#   QEMU_PATTERN='qemu-system-x86_64.*myimage' make vm-x86-wait
QEMU_PATTERN="${QEMU_PATTERN:-qemu-system-x86_64}"

echo "Waiting for x86 VM boot (KVM — should be fast, ~30-60s; max ${MAX_WAIT}s)..."
_elapsed=0
until grep -q "login:" "$LOG" 2>/dev/null; do
    # If QEMU has died, the login prompt will never appear — fail fast.
    if ! pgrep -f "$QEMU_PATTERN" >/dev/null 2>&1; then
        echo "ERROR: QEMU process ($QEMU_PATTERN) is not running — VM died during boot." >&2
        echo "       Check: tail -f $LOG ; make vm-status" >&2
        exit 1
    fi
    if [ "$_elapsed" -ge "$MAX_WAIT" ]; then
        echo "ERROR: timed out after ${MAX_WAIT}s waiting for 'login:' in $LOG" >&2
        echo "       Check: tail -f $LOG ; make vm-status" >&2
        exit 1
    fi
    sleep 3
    _elapsed=$((_elapsed + 3))
done
echo "x86 VM booted"

# Открыть ControlMaster
ssh_master_open
echo "SSH ControlMaster established"
