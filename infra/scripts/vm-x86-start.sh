#!/bin/sh
set -eu

echo "ERROR: vm-x86-start.sh is OUTDATED! Use 'virsh start bsdos-x86' (or 'make vm-start-virt-x86') instead." >&2
exit 1

VM_IMG="${VM_X86_IMG:-/srv/bsdos/freebsd-x86.qcow2}"
SEED_ISO="${SEED_ISO:-/srv/bsdos/seed.iso}"
FW="${FW_X86:-/usr/share/OVMF/OVMF_CODE_4M.fd}"
# Writable VARS file — OVMF needs this to store boot entries; without it, boots to EFI Shell.
VARS="${FW_X86_VARS:-/srv/bsdos/freebsd-x86-vars.fd}"
# Create writable copy if missing.
if [ ! -f "$VARS" ]; then
    cp /usr/share/OVMF/OVMF_VARS_4M.fd "$VARS"
    echo "Created OVMF VARS: $VARS"
fi
LOG="${LOG:-/srv/bsdos/artefacts/logs/serial-x86.log}"
VM_SSH_PORT="${VM_SSH_PORT:-2222}"
VM_IPC_PORT="${VM_IPC_PORT:-9999}"

[ -f "$VM_IMG" ]  || { echo "ERROR: $VM_IMG not found — run: make image-download-x86 && make image-unpack-x86" >&2; exit 1; }
[ -f "$FW" ]      || { echo "ERROR: OVMF not found: $FW" >&2; exit 1; }

if pgrep -f "qemu-system-x86_64.*freebsd-x86" >/dev/null 2>&1; then
    echo "x86 VM already running"
    exit 0
fi

SPICE_PORT="${SPICE_PORT:-5910}"

AGENT_VPORT_SOCK="${AGENT_VPORT_SOCK:-/tmp/bsdos-agent-vport.sock}"
QMP_SOCK="${QMP_SOCK:-/tmp/bsdos-qmp.sock}"

echo "Starting FreeBSD x86_64 VM (KVM + SPICE display)..."
echo "  serial log: $LOG"
echo "  SSH:   ssh -p $VM_SSH_PORT freebsd@localhost"
echo "  SPICE: spice://127.0.0.1:$SPICE_PORT  (make vm-x86-spice)"
echo "  agent: $AGENT_VPORT_SOCK (virtio-console)"
echo "  QMP:   $QMP_SOCK (snapshots)"

# Remove stale sockets so QEMU can bind
rm -f "$AGENT_VPORT_SOCK" "$QMP_SOCK"

nohup qemu-system-x86_64 \
    -enable-kvm \
    -cpu host \
    -smp 16 \
    -m "${VM_MEM:-8192}" \
    -boot order=c \
    -drive "if=pflash,format=raw,readonly=on,file=$FW" \
    -drive "if=pflash,format=raw,file=$VARS" \
    -drive "file=$VM_IMG,format=qcow2,if=virtio,cache=writeback" \
    -drive "file=$SEED_ISO,format=raw,if=virtio,readonly=on" \
    -netdev "user,id=n0,hostfwd=tcp:127.0.0.1:${VM_SSH_PORT}-:22,hostfwd=tcp:127.0.0.1:${VM_IPC_PORT}-:${VM_IPC_PORT},hostfwd=tcp:127.0.0.1:9222-:9222,hostfwd=tcp:127.0.0.1:${SPICE_GUEST_FWD:-5902}-:5901" \
    -device virtio-net-pci,netdev=n0 \
    -netdev "tap,id=n1,ifname=tap-bsdos,script=no,downscript=no" \
    -device virtio-net-pci,netdev=n1,mac=52:54:00:be:17:85 \
    -device qxl-vga,vgamem_mb=64 \
    -device virtio-gpu-pci,addr=0x0b \
    -spice "port=${SPICE_PORT},addr=127.0.0.1,disable-ticketing=on,image-compression=off" \
    -device virtio-serial-pci,id=vser-spice \
    -device virtserialport,bus=vser-spice.0,chardev=spice0,name=com.redhat.spice.0 \
    -chardev spicevmc,id=spice0,name=vdagent \
    -device virtio-serial-pci,id=vser-agent \
    -chardev "socket,id=agentch,path=${AGENT_VPORT_SOCK},server=on,wait=off" \
    -device virtserialport,bus=vser-agent.0,chardev=agentch,name=bsdos.agent \
    -qmp "unix:${QMP_SOCK},server=on,wait=off" \
    -fsdev "local,id=hostshare,path=${BSDOS_HOST_SHARE:-/srv/bsdos},security_model=mapped-file" \
    -device "virtio-9p-pci,fsdev=hostshare,mount_tag=bsdos" \
    -serial "file:$LOG" \
    -display none \
    -pidfile /tmp/bsdos-x86-qemu.pid \
    >/tmp/bsdos-x86-qemu-err.log 2>&1 &

echo "QEMU x86_64 PID=$!"
