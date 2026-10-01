# bsdOS x86 KVM VM (libvirt + VirGL)

Этот шаблон определяет FreeBSD 15.1 x86_64 VM с:
- **Нативная скорость**: KVM на x86_64 хосте (в 10x быстрее ARM TCG)
- **VirGL GPU acceleration**: SPICE + virtio-gpu с /dev/dri/card0
- **Shared FS**: virtiofs (реальный, `/mnt/bsdos`, через rc.d `bsdos_virtiofs`, НЕ через fstab) + 9p (`bsdos9p`, `/mnt/bsdos-9p-fallback`, boot-critical fstab safety net) — см. ниже
- **Agent channel**: virtio-console для бинарного протокола агента
- **Port forwarding**: SSH (2222), IPC (9999), Zenoh (7447), CDP (9222)

## Быстрый старт

```bash
# 1. Зарегистрировать домен в libvirt (один раз)
make vm-define-x86

# 2. Запустить VM
make vm-start-virt-x86

# 3. Подождать загрузки (смотреть логи)
make vm-logs-x86

# 4. Подключиться к SPICE дисплею (когда готов)
make vm-spice-x86

# 5. SSH когда готов (freebsd@127.0.0.1 с ключом bsdos-key)
ssh -p 2222 -i bsdos-key freebsd@127.0.0.1
```

## Управление VM

| Команда | Действие |
|---------|----------|
| `make vm-define-x86` | Зарегистрировать домен bsdos-x86 |
| `make vm-start-virt-x86` | Запустить VM |
| `make vm-stop-virt-x86` | Остановить VM (graceful → force destroy) |
| `make vm-spice-x86` | Открыть SPICE дисплей в virt-viewer |
| `make vm-status-virt-x86` | Показать статус, порты, сетевую конфигурацию |
| `make vm-logs-x86` | Tail -f серийной консоли |

## Особенности конфигурации

### CPU & Memory
```xml
<memory unit='MiB'>4096</memory>
<vcpu placement='static'>16</vcpu>
<cpu mode='host-passthrough' check='none'>
  <topology sockets='1' cores='16' threads='1'/>
</cpu>
```

### Display (SPICE + VirGL)
```xml
<graphics type='spice' port='5910' listen='127.0.0.1'>
  <listen type='address' address='127.0.0.1'/>
  <gl enable='yes'/>
</graphics>
<video>
  <model type='virtio' heads='1' primary='yes'>
    <acceleration accel3d='yes'/>
  </model>
</video>
```

### Network (user-mode + port forwarding)
```
127.0.0.1:2222  → :22   (SSH)
127.0.0.1:9999  → :9999 (IPC broker)
127.0.0.1:7447  → :7447 (Zenoh mesh)
127.0.0.1:9222  → :9222 (CDP tunnel)
127.0.0.1:5901  → :5901 (VNC fallback)
```

### Shared FS — virtiofs (реальный) + 9p (boot-critical fallback), см. `docs/DEV-VM.md` §«КОРНЕВОЙ БАГ: fstab virtiofs»

Два отдельных filesystem-девайса в домене:
```xml
<!-- реальный virtiofs, target 'bsdos' → /mnt/bsdos в госте -->
<filesystem type='mount' accessmode='passthrough'>
  <driver type='virtiofs'/>
  <source dir='/srv/bsdos'/>
  <target dir='bsdos'/>
</filesystem>
<!-- 9p safety net, target 'bsdos9p' → /mnt/bsdos-9p-fallback в госте -->
<filesystem type='mount' accessmode='mapped'>
  <driver type='path'/>
  <source dir='/srv/bsdos'/>
  <target dir='bsdos9p'/>
</filesystem>
```
Требует `<memoryBacking><source type='memfd'/><access mode='shared'/></memoryBacking>` в домене (для virtiofs).

⛔ **`virtiofs` fstype НИКОГДА не прописывать в `/etc/fstab`** — base FreeBSD `mount(8)` не знает `virtiofs` как tag-based fstype и падает `No such file or directory` ДО вызова `mount_virtiofs`, а `/etc/rc` считает провал ЛЮБОЙ fstab-строки фатальным (это и уронило весь boot `dev-vm` 2026-07-23). Правильно: `bsdos9p` (9p) — единственная строка в fstab, boot-critical; реальный virtiofs монтируется отдельным non-fatal `/usr/local/etc/rc.d/bsdos_virtiofs` (`mount_virtiofs bsdos /mnt/bsdos` напрямую, минуя generic `mount -t`). Полная история и рабочие modules — `docs/DEV-VM.md`.

### Agent channel (virtio-console)
```xml
<channel type='unix'>
  <source mode='bind' path='/tmp/bsdos-agent-vport-x86.sock'/>
  <target type='virtio' name='bsdos.agent'/>
</channel>
```

Хост может читать/писать в `/tmp/bsdos-agent-vport-x86.sock` для управления агентом без SSH.

### Boot (OVMF EFI + qcow2 disk)
```xml
<loader readonly='yes' type='pflash'>/usr/share/OVMF/OVMF_CODE_4M.fd</loader>
<nvram template='/usr/share/OVMF/OVMF_VARS_4M.fd'>
  /var/lib/libvirt/qemu/nvram/bsdos-x86_VARS.fd
</nvram>
```

Требует:
- `freebsd-x86-15.1.qcow2` (загрузить: `make image-download-x86; make image-unpack-x86`)
- `seed.iso` для cloud-init

## Troubleshooting

| Симптом | Диагностика |
|---------|-------------|
| `virsh start bsdos-x86` fails | `virsh list --all` — домен существует? `make vm-define-x86` |
| SPICE doesn't connect | `virsh dumpxml bsdos-x86 \| grep port` — какой порт? `virt-viewer spice://127.0.0.1:5910` |
| Serial log empty | `tail -f /srv/bsdos/artefacts/logs/serial-x86.log` — QEMU может быть мертв |
| No /dev/dri/card0 in guest | SPICE GL или QEMU VirGL не поддерживаются хостом; fallback на virtio-vga (без акселерации) |
| SSH timeout | `make vm-logs-x86` — дождаться загрузки; проверить seed.iso конфигурацию |

## Архитектура vs ARM (bsdos-dev)

| Аспект | x86 (bsdos-x86) | ARM (bsdos-dev) |
|--------|-----------------|-----------------|
| Архитектура | x86_64 (host-passthrough) | aarch64 (cortex-a72 TCG) |
| Скорость | Нативная (~10x быстрее) | TCG эмуляция |
| Display | SPICE VirGL | SPICE framebuffer |
| GPU | virtio-gpu accel3d | VGA framebuffer |
| CPU | 16 ядер реальных | 2 виртуальных |
| Use case | Разработка, тесты | Целевая платформа testing |
| Image | freebsd-x86-15.1.qcow2 | freebsd14.qcow2 |

## Дополнительно

- **NVRAM directory**: libvirt требует `/var/lib/libvirt/qemu/nvram/` (создаёт скрипт)
- **Permissions**: `virsh` требует `libvirt` группу или `sudo`
- **QMP**: Serial + QMP for savevm/loadvm (см. PLAN-virtio-console.md)
- **Cloud-init**: seed.iso содержит конфигурацию сети + пользователя freebsd
