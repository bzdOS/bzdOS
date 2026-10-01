#!/bin/sh
set -eu

VM_IMG="${VM_IMG:?VM_IMG not set}"
SEED_ISO="${SEED_ISO:?SEED_ISO not set}"
FW="${FW:-/usr/share/AAVMF/AAVMF_CODE.no-secboot.fd}"
LOG="${LOG:-/tmp/bsdos-serial.log}"
VM_SSH_PORT="${VM_SSH_PORT:-2222}"
VM_IPC_PORT="${VM_IPC_PORT:-9999}"
AGENT_VPORT_SOCK="${AGENT_VPORT_SOCK:-/tmp/bsdos-agent-vport.sock}"
QMP_SOCK="${QMP_SOCK:-/tmp/bsdos-qmp.sock}"

[ -f "$VM_IMG" ]  || { echo "ERROR: $VM_IMG not found — run: make image-unpack" >&2; exit 1; }
[ -f "$SEED_ISO" ] || { echo "ERROR: $SEED_ISO not found" >&2; exit 1; }
[ -f "$FW" ]      || { echo "ERROR: EFI firmware not found: $FW" >&2; exit 1; }

if pgrep -x qemu-system-aarch64 >/dev/null 2>&1; then
    echo "VM already running (pid=$(pgrep -x qemu-system-aarch64))"
    exit 0
fi

# Remove stale sockets so QEMU can bind
rm -f "$AGENT_VPORT_SOCK" "$QMP_SOCK"

echo "Starting FreeBSD 14.4 aarch64 VM..."
echo "  serial log: $LOG"
echo "  SSH:   ssh -p $VM_SSH_PORT -i bsdos-key freebsd@localhost"
echo "  agent: $AGENT_VPORT_SOCK (virtio-console)"
echo "  QMP:   $QMP_SOCK (snapshots)"

nohup qemu-system-aarch64 \
    -machine virt \
    -cpu cortex-a72 \
    -smp 2 \
    -m 4096 \
    -bios "$FW" \
    -drive "file=$VM_IMG,format=qcow2,if=virtio,cache=writeback" \
    -drive "file=$SEED_ISO,format=raw,if=virtio,readonly=on" \
    -netdev "user,id=n0,hostfwd=tcp::${VM_SSH_PORT}-:22,hostfwd=tcp::${VM_IPC_PORT}-:${VM_IPC_PORT},hostfwd=tcp::9222-:9222" \
    -device virtio-net-device,netdev=n0 \
    -fsdev "local,security_model=passthrough,id=fsdev0,path=$(pwd)" \
    -device "virtio-9p-pci,fsdev=fsdev0,mount_tag=bsdos" \
    -device virtio-serial-pci,id=vser-agent \
    -chardev "socket,id=agentch,path=${AGENT_VPORT_SOCK},server=on,wait=off" \
    -device virtserialport,bus=vser-agent.0,chardev=agentch,name=bsdos.agent \
    -qmp "unix:${QMP_SOCK},server=on,wait=off" \
    -serial "file:$LOG" \
    -display none \
    -pidfile /tmp/bsdos-qemu.pid \
    >/tmp/bsdos-qemu-err.log 2>&1 &

echo "QEMU PID=$!"
echo "  run 'make vm-wait' to block until SSH is ready"
