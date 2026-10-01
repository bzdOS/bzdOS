# Dev/Build VM — авторитетный справочник (`bsdos-x86`)

> Зафиксировано 2026-06-24 после многочасового разбора. Цель: чтобы НИКОГДА больше не гадать «как поднять VM / почему agent_exec молчит».

## TL;DR

- **Сборочная dev-VM = персистентный libvirt-домен `bsdos-x86`** (amd64, KVM). Диск `/srv/bsdos/freebsd-x86-15.1.qcow2`. Это и есть «дев VM $BSDOS_DEV_IP» из операционной модели.
- Управление **ТОЛЬКО через `virsh`**: `virsh start bsdos-x86` / `virsh shutdown bsdos-x86`. ⛔ НЕ `make vm-x86-*`, ⛔ НЕ `pkill qemu`.
- Три канала к гостю:
  1. **SSH (setup)** — `ssh -i $BSDOS_SSH_KEY freebsd@$BSDOS_DEV_IP` (bridged NIC vtnet1 → br0). root: `su -m root -c '...'`. Легитимно для setup (pkg/sysrc/старт агента), НЕ для runtime.
  2. **9p/virtiofs (файлы)** — был `$BSDOS_ROOT` (хост) == `/mnt/bsdos` (гость); **выключен в госте с 2026-10-01**, файлы — через `agent_put`/`agent_get`.
  3. **virtio-console агент (runtime)** — хост-сокет `/tmp/bsdos-agent-vport-x86.sock` ↔ гостевой **`/dev/ttyV0.2`**. Команды: `cd /srv/bsdos && . infra/scripts/_agent.sh && agent_exec "cmd"`.

## Сеть домена (восстановлена 2026-06-24)

`bsdos-x86` имеет два NIC (порядок важен — задаёт vtnetN):
- `<interface type='user'>` → **vtnet0** (slirp, для localhost-форвардов).
- `<interface type='bridge'><source bridge='br0'/><mac 52:54:00:be:17:85></interface>` → **vtnet1** = **$BSDOS_DEV_IP** (статик в guest rc.conf, default route через .177).

Если домен потерял сеть (нет `<interface>` в `virsh dumpxml bsdos-x86`) — добавить персистентно:
```bash
virsh attach-device bsdos-x86 iface-user.xml   --config   # vtnet0 (type=user, virtio)
virsh attach-device bsdos-x86 iface-bridge.xml --config   # vtnet1 (bridge br0, mac 52:54:00:be:17:85, virtio)
virsh start bsdos-x86
```
(Порядок attach = порядок PCI = vtnet0,vtnet1. dev-vm должен быть на vtnet1, иначе guest-конфиг не применится.)

## ⚠️ КОРНЕВОЙ БАГ чардева (был причиной «сломанной VM» 2026-06-24)

В guest `/etc/rc.conf` стоял `bsdos_agent_chardev="/dev/ttyV1.1"` — **такого устройства НЕТ**. Реальные порты virtio-serial:
- **port 1 → `/dev/ttyV0.1` = SPICE** (`com.redhat.spice.0`).
- **port 2 → `/dev/ttyV0.2` = `bsdos.agent`** (мост к host `/tmp/bsdos-agent-vport-x86.sock`).

Агент годами запускался по rc.d, но открывал мёртвый `/dev/ttyV1.1` → канал `bsdos.agent` = `disconnected` → `agent_exec` пуст, хотя процесс агента жив. **Правильно:**
```
bsdos_agent_enable="YES"
bsdos_agent_chardev="/dev/ttyV0.2"
```
Исправлено перманентно через `sysrc bsdos_agent_chardev=/dev/ttyV0.2` → авто-старт на каждом boot теперь правильный.

## Диагностика «agent_exec молчит»

```bash
virsh domstate bsdos-x86                                          # running?
virsh dumpxml bsdos-x86 | grep -A1 'bsdos.agent' | grep state     # connected = ОК; disconnected = чардев/агент
ping -c1 $BSDOS_DEV_IP ; nc -z $BSDOS_DEV_IP 22 || true         # сеть/SSH живы?
. infra/scripts/_agent.sh && agent_exec "echo UP"                 # пусто = канал disconnected
```
Если `disconnected`: проверить `pgrep bsdos-agent` + `sysrc bsdos_agent_chardev` (должно быть `/dev/ttyV0.2`), при нужде `sysrc bsdos_agent_chardev=/dev/ttyV0.2; service bsdos_agent restart` (или `daemon -f env BSDOS_CHARDEV_PATH=/dev/ttyV0.2 /usr/local/bin/bsdos-agent`). Подтвердить: `bsdos.agent` → `state='connected'`. (Для setup можно зайти по ssh — но не для runtime; см. ниже про ужесточение транспорта.)

## Ещё причина «agent молчит»: переполнение диска гостя (2026-07-04)

Даже при ПРАВИЛЬНОМ чардеве (`/dev/ttyV0.2`, канал `connected`) агент **висит/умирает, когда гостевой rootfs `/` забит под 100%**. Сборки (esp-idf/platformio → `/tmp`, `pkg` → `/usr/local`, порты → `/usr/obj`) на маленьком системном диске (82G) добивают его до отказа — процессам, включая агента, некуда писать → `agent_exec` молчит, vport отваливается. **Это было настоящей причиной «мёртвого транспорта» в июле — не чардев** (он уже был починен).

Лечение — держать ВСЮ тяжёлую запись на отдельном пуле (у jailrun это пул `jailrun` на `/dev/vtbd1`, смонтирован `/jailrun`):
- симлинки `~/.platformio`, `~/.espressif` → `/jailrun/cache/*`;
- экспорт `TMPDIR=/jailrun/tmp`, `PLATFORMIO_CORE_DIR`, `IDF_TOOLS_PATH`, `WRKDIRPREFIX=/jailrun/obj`;
- следить `df -h /`, при >90% — стоп сборки.

Диагностика первым делом, если транспорт странный: `agent_exec "df -h /"`.

## ⚠️ КОРНЕВОЙ БАГ: fstab virtiofs → boot abort → single-user НА ВИДЕО-консоли (был причиной «зависшей» VM 2026-07-23)

`dev-vm` показывала `running` в `virsh`, agent_exec молчал (`vport transport unavailable`), сеть не пинговалась — выглядело как зависший kernel. На самом деле VM **не висела, а каждый раз чисто падала в single-user shell** и стояла там вечно, ожидая ввода.

Причина: `/etc/fstab` содержал `bsdos /mnt/bsdos virtiofs rw 0 0`. Модуль `/boot/modules/virtiofs.ko` был собран под несовместимую версию fusefs (не экспортировал символ `fuse_body_audit`, нужный virtiofs.ko) → `kldload` падал с `unsupported file type`. Сама по себе загрузка модуля некритична (кернел просто логирует и идёт дальше) — но **`/etc/rc` считает провал ЛЮБОЙ строки в fstab фатальным**: `mount -a` падал → `ERROR: ABORTING BOOT` → `Enter full pathname of shell or RETURN for /bin/sh:` и вечное ожидание ввода.

**Почему это не было видно ни в serial-логе, ни через `virsh console`:** домен сконфигурирован `Dual Console: Video Primary, Serial Secondary` — single-user prompt печатается на ВИДЕО (SPICE framebuffer) консоли, не на serial. Serial-лог (`artefacts/logs/serial-x86.log`) обрывался в полной тишине сразу после `uhub0: 8 ports...` — выглядело как настоящий kernel hang, хотя машина спокойно ждала ответа на другом экране.

**Диагностика (когда serial-лог "молчит" без причины):**
```bash
virsh domstate bsdos-x86                                    # running — не значит "живая"
virsh screenshot bsdos-x86 /tmp/screen.png                  # СМОТРЕТЬ ВИДЕО-КОНСОЛЬ, не только serial!
```
Если на скриншоте `Enter full pathname of shell` — машина в single-user, ждёт ввода на видео-консоли. Интерактивный ввод туда — `virsh send-key bsdos-x86 KEY_ENTER KEY_A ...` (по одной клавише за вызов; serial `virsh console` эту консоль не видит и не пишет в неё).

**Первый (промежуточный) фикс** был откат на `p9fs,trans=virtio` вместо virtiofs — VM переставала падать, но virtiofs оставался сломан. Это НЕПРАВИЛЬНО как финальное решение: явно требовалось реально починить virtiofs, а не обойти. Финальный фикс ниже — virtiofs реально работает, живой на `dev-vm` с 2026-07-23.

**Корень поломки модуля:** `/boot/modules/virtiofs.ko` был собран под несовместимую версию fusefs (не экспортировал символ `fuse_body_audit`). Простой дроп рабочего `fusefs.ko` в `/boot/modules/` НЕ помогал — loader ищет модули сначала в `/boot/kernel/` (там уже штатно лежит СВОЙ `fusefs.ko`, который и находится первым и грузится вместо любого файла в `/boot/modules/` с тем же именем). Настоящий фикс — заменить сам `/boot/kernel/fusefs.ko`:
```bash
cp /boot/kernel/fusefs.ko /boot/kernel/fusefs.ko.stock-orig   # бэкап
cp <рабочий fusefs.ko> /boot/kernel/fusefs.ko                 # тот же kernel build, что и dev-vm
kldunload fusefs; kldload fusefs; kldload virtiofs             # живой тест без ребута
```
Рабочие `fusefs.ko`/`vtfs.ko`/`virtiofs.ko`/`mount_virtiofs` — собраны под тот же kernel build (`releng/15.1-n283544-f841f71deade GENERIC amd64`), взяты живьём с `myvm` (`myvm`, идентичный kernel, были уже загружены и рабочие там) и застейджены на хосте: `artefacts/virtiofs_scratch/built-modules/` (видно из обеих VM через 9p).

**Вторая ловушка: `mount -t virtiofs` не работает вообще, даже с рабочими модулями.** Base FreeBSD `mount(8)` не знает fstype `virtiofs` как tag-based (в отличие от `p9fs`, который знает) — генерик-фронтенд пытается резолвить `bsdos` как файловый путь и падает `mount: bsdos: No such file or directory` ДО вызова `/sbin/mount_virtiofs`. Это значит: **`virtiofs` в `/etc/fstab` НИКОГДА не сработает через штатный `mount -a`** (то же самое `mount -a`, что валило весь boot 2026-07-23) — только прямой вызов помощника работает:
```bash
/sbin/mount_virtiofs <tag> <mountpoint>   # работает
mount -t virtiofs <tag> <mountpoint>      # падает "No such file or directory", даже с рабочим модулем
```

**Финальная архитектура (два девайса, две задачи):**
- `bsdos9p` (9p, `driver type='path'`) → `/mnt/bsdos-9p-fallback` — **boot-critical**, живёт в `/etc/fstab`, никогда не трогать этот путь, это единственная гарантия что VM всегда стартует.
- `bsdos` (**настоящий virtiofs**, `driver type='virtiofs'`, требует `memoryBacking source='memfd' access mode='shared'` — уже стоит в домене) → `/mnt/bsdos` — реальный путь, которым пользуется весь остальной тулинг. Монтируется НЕ через fstab (см. ловушку выше), а через кастомный `/usr/local/etc/rc.d/bsdos_virtiofs` (`REQUIRE: mountlate`, `sysrc bsdos_virtiofs_enable=YES`), который вызывает `/sbin/mount_virtiofs bsdos /mnt/bsdos` напрямую и **никогда не считается фатальным** для `/etc/rc` (обычный rc.d-сервис, а не запись в fstab).

`/boot/loader.conf` дополнен: `virtio_p9fs_load="YES"` (транспорт для 9p-fallback, без него `mount -t p9fs` → EINVAL).

Итог: `bsdos on /mnt/bsdos (virtiofs.virtio)` — реальный virtiofs, автоматически на каждом boot, verified через полный чистый ребут.

**Хрупкость, которую стоит помнить:** один битый optional-share НАПРЯМУЮ В FSTAB валит ВЕСЬ boot (agent, сеть, kolkhoz-стек) — там нет `noauto`/graceful degradation у `/etc/rc`'s `mount -a`. Поэтому virtiofs специально вынесен из fstab в отдельный non-fatal rc.d-сервис — это и есть защита от повторения инцидента, а не просто дополнительная функция. Новую fstab-строку для шары — сначала проверять `kldload <модуль>` вручную и test-мount через штатный `mount -t <fstype>` (не только через type-specific helper), ПЕРЕД тем как прописывать её в fstab постоянно.

### ⚠️ Апдейт того же дня: 9p-fallback (`bsdos9p`) САМ оказался источником повторного инцидента

Изначальный план держал `bsdos9p` (9p, `driver type='path'`, target `bsdos9p` → `/mnt/bsdos-9p-fallback`) как единственную строку в fstab — «boot-critical safety net». Через ~15 минут после verified-рабочего состояния `dev-vm` **сама отвалилась** (VM ушла в тот же `ERROR: ABORTING BOOT` / single-user cycle, теперь уже с `mount: bsdos9p: Invalid argument`), хотя я не трогал домен руками. Диагностика: `virsh dumpxml --inactive` показал, что PERSISTENT-конфиг домена потерял `filesystem`-девайс с target `bsdos9p` целиком (остались только `bsdos`-virtiofs и `jailrun`) — не ошибка монтирования, девайса физически не было в PCI. Точная причина потери девайса из persistent XML НЕ установлена (не cron, не systemd-таймер, не `make vm-define-x86`/`vm-define-x86.sh` — эти не запускались; возможно артефакт `<on_reboot>restart</on_reboot>` при живом vhost-user-fs девайсе на соседнем target, не подтверждено).

**Итоговое решение (проще и надёжнее, живое на `dev-vm`):** `bsdos9p`/9p-fallback ПОЛНОСТЬЮ убран — ни из домена, ни из fstab. `/etc/fstab` теперь содержит ТОЛЬКО реальные локальные устройства (rootfs/swap/efiboot), НИ ОДНОЙ share-строки. Единственный путь к `/mnt/bsdos` — non-fatal `bsdos_virtiofs` rc.d (см. выше). Если когда-нибудь и виртиофс-девайс `bsdos` исчезнет так же необъяснимо — `/mnt/bsdos` будет просто отсутствовать (rc.d проглотит ошибку), но **boot никогда больше не упадёт из-за отсутствующей/сломанной шары**, потому что в fstab с 2026-07-23 нет вообще ни одной non-local записи.

**Урок:** второй уровень "safety net" через fstab оказался ЧАСТЬЮ проблемы, не решением — сам класс бага (fstab-запись для чего угодно non-local = риск для всего boot) закрывается только полным отсутствием таких записей в fstab, а не количеством fallback-уровней внутри него.

**Побочная находка (не связана с virtiofs, но всплыла в процессе):** диск `vdb` (`/mnt/storage/jailrun/zpool.qcow2`, ZFS-пул `jailrun` для kolkhoz-стека) временно отсоединялся для проверки другой гипотезы (не подтвердилась) и был возвращён (`virsh attach-disk ... --persistent --live`); `zpool import jailrun` + ручной рестарт `kolkhoz_doora`/`kolkhoz_doorb`/`clickhouse`/`nginx` после ребута — все датасеты целы, данные не пострадали.

## Транспорт ужесточён (2026-07-04)

- `_agent.sh` больше **не падает молча в ssh** при мёртвом vport: ssh-fallback теперь opt-in
  (`AGENT_ALLOW_SSH=1`), по умолчанию только vport, иначе громкий `-ERR vport transport
  unavailable`. Смысл — чтобы мёртвый vport не маскировался ssh-туннелем (агенты рантайма ssh не используют).
- `agent-run.sh` сериализует доступ через `flock` (`/tmp/bsdos-agent-vport-x86.lock`): один
  virtio-console сокет = один клиент за раз; параллельные вызовы встают в очередь. Реальный
  параллелизм — фоновыми задачами НА госте (`nohup … &`) + редкий опрос.

## ⛔ Direct-QEMU — НЕ ТРОГАТЬ (яма 2026-06-24)

Параллельный путь `make vm-x86-start` / `vm-x86-start.sh` / `run-agent.sh` (slirp localhost:2222) запускает ОТДЕЛЬНЫЙ qemu на том же qcow2 → двойной писатель (corruption); его vport = `/tmp/bsdos-agent-vport.sock` (БЕЗ `-x86`). `pkill -f "qemu...freebsd-x86"` матчит И процесс libvirt-домена → убивает рабочую VM в обход libvirt. **Стоп VM только `virsh shutdown/destroy bsdos-x86`.** Облом 2026-06-24: пошёл по direct-QEMU, pkill-нул рабочую VM, снёс сеть (пришлось пересоздавать NIC) — часы впустую.

## Сборка на VM (агент жив)

```bash
. infra/scripts/_agent.sh   # из корня клона bzdOS
agent_exec "cd /mnt/bsdos && cargo build --workspace"           # amd64 нативно
agent_exec "cd /mnt/bsdos && gmake cross-squirrel-aarch64"       # aarch64 cross (clang+lld+sysroot)
AGENT_EXEC_TIMEOUT=600 agent_exec_bg "sh /mnt/bsdos/infra/scripts/squirrel-build.sh qemu-amd64"
```
myvm (myvm, отдельная VM с сетью) = runtime-only; бинарники через 9p staging + `install`. Деплой: `infra/scripts/deploy-bsdos-myvm.sh`.

## ⚠️ `virsh destroy` бьёт UFS → single-user (2026-08-26)

`virsh destroy` — это выдёргивание питания, и корневой UFS его переживает плохо.
Один такой destroy закончился отказом авто-fsck и загрузкой в single-user:

```
/dev/gpt/rootfs: INVALID INDIRECT BLOCK
/dev/gpt/rootfs: UNEXPECTED SOFT UPDATE INCONSISTENCY; RUN fsck MANUALLY.
Automatic file system check failed; help!
ERROR: ABORTING BOOT
```

Лечение целиком через `virsh send-key` (интерактивной консоли у домена нет, см.
секцию выше): RETURN → `mount -u -r /` → `fsck -y /dev/gpt/rootfs` → `reboot`.
На 154G это ~5 минут. В тот раз повреждённым оказался чужой файл
(`OWNER=clickhouse`), то есть пострадать может что угодно на диске.

**Гасить VM только изнутри:** `shutdown -p now`. Если `virsh shutdown` (ACPI) не
отрабатывает — не эскалировать в destroy, а зайти через `send-key` и выключить
командой. Тот же порядок для `bsdos-dev`.

## ⚠️ Чужой mount поверх `/mnt` прячет шару (2026-08-27)

Симптом: `/mnt/bsdos` смонтирована (`mount` её показывает), но `ls /mnt/bsdos`
отвечает `No such file or directory`, и все артефакты «пропали».

Причина: поверх `/mnt` кто-то смонтировал ещё одну ФС — в тот раз
`/dev/md9p2` (vnode-образ `/tmp/sq.img`, Squirrel rootfs). Она перекрыла
`/mnt/bsdos` целиком, потому что точка монтирования шары лежит ВНУТРИ `/mnt`.
Данные при этом целы, их просто не видно.

Диагностика — `mount | grep -E "bsdos|md"`: если в списке есть и `/mnt/bsdos`,
и что-то на самом `/mnt`, это оно. Лечение: `fstat -f /mnt` (убедиться, что
никто не держит файлы) → `umount /mnt` → перемонтировать образ в
непересекающуюся точку, например `/mnt/sq`.

## Сборка darling: локально, не через шару (2026-08-27)

Шара исторически подводит: перекрытие монтированием (выше), `Operation not
permitted` и `Input/output error` на части путей из-под пользователя `freebsd`,
сломанный `readlink()`. Поэтому darling собирается **с локального диска гостя**:

```
/opt/darling/src        # исходники (rsync-копия hal/darling-freebsd, без .git)
/opt/darling/overlay    # артефакты (libSystem.B.dylib, usr/lib/system/, libz, шимы, IOKit)
/opt/darling/build      # scratch

export DARLING_SRC_DIR=/opt/darling/src
export DARLING_OVERLAY=/opt/darling/overlay
export DARLING_BUILD_DIR=/opt/darling/build
cd /opt/darling/src && sh build-freebsd/build-gui.sh
```

Это **копия**: правки обратно в git сами не едут, синхронизировать `rsync`.
Контекст для агента — `/opt/darling/AGENTS.md` и
`/opt/darling/src/docs/CONTEXT-build-dev-vm.md`.

Своп поднят с 1 ГБ до 17 ГБ (`/swap1` через `md99`, прописан в `/etc/fstab`) —
на 1 ГБ линковка Onyx2D ловила OOM-killer (`Killed`, exit 137), и это выглядело
как загадочная поломка сборки.

## Связанное
- `infra/scripts/_agent.sh` — транспорт (автодетект `-x86.sock`).
- `docs/archive/2026-06-15-plans/PLAN-agent-no-ssh.md` — «SSH только для setup, runtime через агент».
