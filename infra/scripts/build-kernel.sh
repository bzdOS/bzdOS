#!/bin/sh

. "$(dirname "$0")/_ssh.sh"

KERNCONF="${KERNCONF:-BSDOS-amd64}"
JOBS="${JOBS:-4}"

echo "[build-kernel] KERNCONF=$KERNCONF, JOBS=$JOBS"
echo ""

# Verify KERNCONF exists
KERNARCH=$(echo "$KERNCONF" | sed 's/BSDOS-//')
case "$KERNARCH" in
    amd64)
        KERNCONF_PATH="/usr/src/sys/amd64/conf/$KERNCONF"
        ;;
    arm64)
        KERNCONF_PATH="/usr/src/sys/arm64/conf/$KERNCONF"
        ;;
    *)
        echo "[build-kernel] ERROR: unknown architecture in $KERNCONF"
        exit 1
        ;;
esac

echo "[build-kernel] Verifying $KERNCONF_PATH exists..."
ssh_guest "test -f $KERNCONF_PATH" || {
    echo "[build-kernel] ERROR: $KERNCONF_PATH not found"
    exit 1
}

echo "[build-kernel] Starting buildkernel (log: /tmp/buildkernel.log)..."
# Прямое перенаправление — exit code make доходит до SSH без посредников.
# rm старого лога чтобы избежать permission denied от предыдущего freebsd-user файла.
ssh_root "rm -f /tmp/buildkernel.log"
ssh_root "env MAKEOBJDIRPREFIX=/usr/obj make -C /usr/src -j$JOBS buildkernel KERNCONF=$KERNCONF NO_CLEAN=yes > /tmp/buildkernel.log 2>&1"
echo ""
echo "[build-kernel] Last 10 lines of build log:"
ssh_root "tail -10 /tmp/buildkernel.log"
echo ""
echo "[build-kernel] Objects: /usr/obj/usr/src/amd64.amd64/sys/$KERNCONF"
