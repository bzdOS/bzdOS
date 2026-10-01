#!/bin/sh
# Записать startup.nsh в EFI раздел образа qcow2.
# Делает образ самозагружаемым при любом сбросе OVMF VARS.
# Образ должен быть ОСТАНОВЛЕН перед вызовом.
set -eu

IMG="${VM_X86_IMG:?set VM_X86_IMG}"
NBD="${NBD_DEV:-/dev/nbd0}"
MNT=/mnt/bsdos-efi-tmp

pgrep -af "qemu.*$(basename "$IMG")" >/dev/null 2>&1 && {
    echo "ERROR: VM с образом $IMG запущена. Сначала make vm-x86-stop"
    exit 1
}

echo "Подключаю $IMG через NBD ($NBD)..."
modprobe nbd max_part=8 2>/dev/null || true
qemu-nbd --connect="$NBD" "$IMG"
sleep 1
partprobe "$NBD" 2>/dev/null || true
sleep 1

# Найти EFI раздел (FAT32 с меткой EFISYS)
EFI_PART=""
for p in "${NBD}p1" "${NBD}p2" "${NBD}p3"; do
    if file -s "$p" 2>/dev/null | grep -qi "fat\|EFISYS"; then
        EFI_PART="$p"
        break
    fi
done

if [ -z "$EFI_PART" ]; then
    echo "ERROR: EFI раздел не найден в $IMG"
    qemu-nbd --disconnect "$NBD"
    exit 1
fi

echo "EFI раздел: $EFI_PART"
mkdir -p "$MNT"
mount "$EFI_PART" "$MNT"

# Записать startup.nsh — OVMF выполнит его вместо интерактивного Shell
EFI_APP=$(find "$MNT/EFI" -iname "*.efi" 2>/dev/null | head -1 \
    | sed "s|$MNT/||" | tr '/' '\\')
printf 'FS0:\\%s\n' "$EFI_APP" > "$MNT/startup.nsh"
echo "startup.nsh → FS0:\\$EFI_APP"

umount "$MNT"
qemu-nbd --disconnect "$NBD"
rmdir "$MNT" 2>/dev/null || true

echo "OK: $IMG теперь загружается без VARS"
