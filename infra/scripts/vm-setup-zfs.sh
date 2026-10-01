#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"

echo "Setting up ZFS pool in guest..."
# Проверить есть ли уже пул bsdos
if ssh_guest "zpool list bsdos 2>/dev/null"; then
    echo "ZFS pool 'bsdos' already exists"
else
    # Создать виртуальный диск для ZFS если нет физического
    ssh_root "truncate -s 4G /var/bsdos-zpool.img 2>/dev/null || true"
    ssh_root "zpool create -f bsdos /var/bsdos-zpool.img"
    echo "Created ZFS pool: bsdos"
fi

# Создать датасеты
ssh_root "zfs list bsdos/apps 2>/dev/null || zfs create bsdos/apps"
ssh_root "zfs list bsdos/swap 2>/dev/null || zfs create -V 2G -o compression=zstd-3 -o logbias=throughput -o sync=disabled bsdos/swap"
ssh_root "zfs list bsdos/jpk  2>/dev/null || zfs create bsdos/jpk"

echo "ZFS datasets: bsdos/{apps,swap,jpk}"

# Активировать ZFS swap
echo "Activating ZFS swap..."
ssh_root "swapon /dev/zvol/bsdos/swap 2>/dev/null || echo 'swap already active'"
ssh_root "swapinfo"

# Создать директории для jails
echo "Creating jail directories..."
ssh_root "mkdir -p /opt/proto/jails/appMatrix /opt/proto/data/appMatrix"

echo "=== ZFS setup complete ==="
