#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"

echo "=== Setting up DRM (virtio_gpu) for Chromium ==="

# Загрузить virtio_gpu драйвер
ssh_root "kldload virtio_gpu 2>/dev/null || echo 'virtio_gpu already loaded or not available'"

# Проверить наличие DRM устройства
ssh_guest "ls /dev/dri/ 2>/dev/null || echo 'no DRM devices'"

# Добавить в loader.conf для автозагрузки
ssh_root "grep -q virtio_gpu /boot/loader.conf 2>/dev/null || \
    echo 'virtio_gpu_load=\"YES\"' >> /boot/loader.conf"

# Дать права на DRM устройства для jail пользователей
ssh_root "chmod 666 /dev/dri/* 2>/dev/null || true"

echo "DRM setup complete"
ssh_guest "ls -la /dev/dri/ 2>/dev/null || echo 'DRM devices not yet available (requires VM restart)'"
