# bsdOS Project Rules

## РАБОЧИЙ СТИЛЬ

- **Явные баги и проблемы — чинить сразу, без вопросов.** Нашёл очевидный баг, опечатку, вредную команду (напр. `conv=sync` в `gunzip|dd` — раздувает флеш нулями), протухший путь/флаг — исправляй немедленно, не «предлагать и ждать». Делать.
- **Чинить в корне, а не симптом.** Один баг → `grep` по репо → поправить ВСЕ вхождения (скрипты, доки, Makefile), чтобы никто не наступил снова.
- Исключение — необратимое/наружу (деплой, удаление, сеть, коммиты, рестарт прод-листенеров): там сперва подтверждение (см. HARD RULES).

## ТЕХНИЧЕСКИЕ РЕШЕНИЯ (не переспрашивать, не предлагать альтернативы)

| Задача | Решение | Запрещено |
|---|---|---|
| Сериализация data-plane | **Cap'n Proto** (zero-copy, hand-rolled) | JSON, protobuf, msgpack |
| Межузловой транспорт | **Zenoh** peer mode (no broker) | gRPC, HTTP/2, MQTT |
| IPC control-plane | Простой текст `CMD ARG\n` / `+OK\n` | JSON в агенте |
| IPC data-plane | Cap'n Proto length-prefixed binary | JSON events |
| Guest Agent | Текстовый `CMD ARG\n` / `+OK\n.\n` через virtio-console `/dev/ttyV0.2` | бинарный протокол для оркестрации, JSON |
| SSH инфраструктура | ControlMaster=auto (в _ssh.sh) | sleep-heavy scripts |
| Rust | без `unsafe` вне libc FFI, без `unwrap()`, Result | panic, unwrap |
| Zig | явный allocator, `@cImport` для FreeBSD, packed/extern structs 64-byte aligned | скрытые аллокации, динамический heap в hot paths |
| shell | Command + Vec args | sh -c "string" (injection) |
| OS syscalls | прямые через `libc` crate (jail_get, sysctl, kill) | fork/exec для kernel ops |
| Platform | **bzdOS FreeBSD 15.1**: amd64 QEMU (Squirrel v0.1.x, primary dev loop, KVM) + aarch64 QEMU (Squirrel v0.1.x, architectural target) → Banana Pi aarch64 (Chimp v0.2), kqueue, OSS audio, devfs. Squirrel = **multi-arch** per user 2026-06-15. RISC-V — ⛔ DEFERRED 2026-06-15. **oBzdOS OpenBSD**: PinePhone aarch64 (Woodpecker v0.3, A64+Mali-400) — separate OS base, pledge/unveil, different pkg system. | Linux-specific (epoll, glibc, systemd) |
| dev VM transport | **virtio-console** (агент без SSH; файлы — `agent_put`/`agent_get`) + 9p/virtiofs (shared FS без scp; ⚠ выключен в госте с 2026-10-01) | ssh для операций агента |
| GPU/Display | QEMU: QXL/virtio-gpu через SPICE; Device: fbdev MVP (weston) → Lima (свой порт, `bzdOS/lima-freebsd`), база drm-subtree+DRMKPI | drm-kmod/LinuxKPI для ARM-SoC (это для PCIe GPU) |
| Cap'n Proto Schema | HardwareStatus + JailStatus + TouchEvent + WaylandPacket | отдельные схемы для каждого компонента |

## КОД GАЙДЛАЙНЫ (зафиксировано 2026-06-06)

### Zig (HAL, telephony, predictive touch, ghost radio)
- Нет `std.mem.Allocator` в hot paths — только стек и compile-time буферы `[N]u8`
- Все structs `packed` или `extern`, явно выровнены по 64 байт (cache line Cortex-A53)
- `comptime` для lookup-таблиц, state machine layouts, конфигураций
- Ошибки обрабатывать явно, не игнорировать результаты

### Rust (supervisor, lifecycle, packaging)
- Нет `String`/`Vec`/`Box` в core tracking loops — fixed-size arrays, `&str` slices
- `unsafe` только для FreeBSD C FFI (`libc` / `ioctl`)
- Zero-Copy через `capnp` и `zenoh` crates
- Нет `unwrap()` / `panic!` — только `Result<T, E>`

### Semantic Markup (для всех языков)
- **Annotation-first:** контракт пишется ДО реализации. При правках — сначала обновить контракт, потом код.
- **Обязательные поля функции:** `purpose`, `input`, `output`, `sideEffects`.
- **См.:** [github.com/bzdOS/sema](https://github.com/bzdOS/sema) — полная методология + bsdOS профиль + валидатор

### Multi-agent (hubd)
- Перед редактированием файла: `hubd claim [file_path]`
- Статус задач в `.hubd/tasks.jsonl`

**Schema:** `schema.capnp` (корень этого репо) — HardwareStatus + JailStatus + TouchEvent + WaylandPacket.  
**Zenoh keys:**
- `bsdos/telemetry` — core uptime/battery/cpu heartbeat
- `bsdos/jail/<name>/status` — jail lifecycle events
- `bsdos/app/{app_id}/stream` — per-stream wl_shm frames (v1 length-prefixed)
- `bsdos/app/{app_id}/input/keyboard` — keyboard events → stream
- `bsdos/app/{app_id}/input/pointer` — pointer events → stream
- `bsdos/app/{app_id}/viewer/size` — viewer resize → stream
- `bsdos/ctl/stream/start` — start stream command
- `bsdos/ctl/stream/stop` — stop stream command  
**Guest agent:** virtio-console transport `/dev/ttyV0.2` (port 2; port 1 = SPICE), text protocol. Сокет хоста: `/tmp/bsdos-agent-vport-x86.sock`.

## Animal codenames (зафиксировано 2026-06-13)

| Codename | Версия | Stage | Target | Status |
|---|---|---|---|---|
| **Squirrel** (Белка) | v0.1.x | QEMU sandbox (small/quick) | QEMU amd64 (primary dev loop) + QEMU aarch64 (architectural target), **multi-arch** per user 2026-06-15 | 🟡 **active** — spec drafted 2026-06-15 (8f2ddc7, 2bed0cb), hubd tasks #38 (rootfs) + #39 (2-stream) |
| **Chimp** (Шимпанзе) | v0.2 | First tool-user (real hardware) | Banana Pi BPI-M64 (Allwinner A64) | 🟡 **железо в работе**: плата с 2026-07-02 (a hub task); FreeBSD-гость под гипервизором EL2 [bzdk](https://github.com/bzdOS/bzdk) доходит до userland (a hub task, 2026-08-20); GPU — [lima-freebsd](https://github.com/bzdOS/lima-freebsd). Владение железом — `bsdos-hal: docs/SPEC_chimp_hal.md`. Загрузка — `bzdOS/bzdOS: docs/BPI-M64-BOOT.md`. Уроки бринг-апа — `docs/LESSONS.md` |
| **Woodpecker** (Дятел) | v0.3 | oBzdOS — paranoid mobile | PinePhone (A64, Mali-400) | 📋 planned |

**⛔ RISC-V / BPI-F3: DEFERRED 2026-06-15** (SpacemiT K1 shelved indefinitely, see `docs/archive/2026-10-01-monorepo/PLAN-bpi-f3-bringup.md`).
**Squirrel multi-arch (locked 2026-06-15):** amd64 QEMU = primary dev loop (KVM fast); aarch64 QEMU = architectural target (Chimp/Woodpecker-ready). Both ship in same release, both tested in CI. Specs: [bzdOS/bzdOS](https://github.com/bzdOS/bzdOS) `docs/specs/SPEC_squirrel_rootfs.md`, `SPEC_2stream_squirrel.md`.

**Squirrel deliverables** (per user 2026-06-15 vision): ARM64 rootfs image + 2-stream demo + bsdos_lifecycled + .jpk prototype + Zenoh on port 443 + QML Wayland translator. Specs (в репо bzdOS/bzdOS): `docs/specs/SPEC_squirrel_rootfs.md`, `SPEC_2stream_squirrel.md`, `SPEC_jpk_descriptor_v1.md`.

## CRITICAL: Операционная модель (КАНОН — отменяет любые противоречащие правила ниже)

Топология: **Mac** (за ТСПУ, только obfs-клиент `metal-viewer`) → **host** buildhost `$BSDOS_HOST_IP` (QEMU; диски VM и данные — `$BSDOS_ROOT`, ключ VM `$BSDOS_SSH_KEY`) → **dev VM** `$BSDOS_DEV_IP` (FreeBSD: build machine, obfs gateway, `bsdos_pipeline`) → **myvm** `$BSDOS_MYVM_IP` (FreeBSD: production runtime, streams, `bsdos_core_server`).

- **Дев — на сервере (host+VM).** Вся разработка по роадмапу идёт там, локально. Mac — только запуск obfs-клиента (временно, для obfs-дебага). НЕ плодить Mac-only обёртки.
- **Истина кода — репо org `github.com/bzdOS` (с 2026-10-01).** Монорепо bsdOS растворён: каждый компонент в своём репо, карта — `docs/EXTRACTION-MAP.md`. **Этот репо (bzdOS)** = дистрибутив + dev loop (dev-VM, guest-agent, деплой дистрибутива) + процесс команды (этот файл, `AGENTS.md`, `SESSION_RULES.md`). Агенты работают из клона bzdOS. Деплой mesh/matrix-hs — `bzdOS/mrgd: deploy/bsdos/`, мост hubd→Matrix — `bzdOS/hubd: contrib/bsdos/`. Неперспективный код — локальный attic без remote.
- **Значения хостов — не в git.** IP, ключ, каталог данных buildhost: `/etc/bsdos/hosts.env` (`BSDOS_HOST_IP`, `BSDOS_DEV_IP`, `BSDOS_MYVM_IP`, `BSDOS_GW_IP`, `BSDOS_OBFS_LISTEN_IP`, `BSDOS_SSH_KEY`, `BSDOS_ROOT`, `BSDOS_CERTS`). Там же сертификаты Zenoh, env-файлы юнитов, cloud-init. Скрипты читают этот файл сами и падают, если значения нет; `$BSDOS_*` в тексте ниже — оттуда. Новое значение для хоста — строка в hosts.env, не литерал в коде.
- **⚠ Переходное состояние (проверено 2026-10-02):** исходники на dev-vm — git-checkout bzdOS в `/opt/bsdos-src` (tar-копии там больше нет). На dev-vm и myvm лежит `/etc/bsdos/hosts.env`. Шара `/mnt/bsdos` на dev-vm **отключена** (`bsdos_virtiofs_enable=NO`, ничего не смонтировано; `/mnt/bsdos` там — локальный каталог); myvm её по-прежнему монтирует (rc.d гостевого агента берёт оттуда `guest-agent/`). Не решено, как бинарники с dev-vm попадают в стейджинг для myvm, поэтому deploy pipeline ниже пока **не работает**. План переезда — `docs/ops/PLAN-host-split.md`.
- **СБОРКА — только на dev VM (dev-vm).** Rust (`cargo build`), ports (`make install`), любые компиляторы — только на dev-vm. myvm (myvm) = runtime only, никаких компиляторов/портов.
- **Deploy pipeline (до 2026-10-01; сейчас не работает, см. выше):** build on dev-vm → stage to `/mnt/bsdos/artefacts/myvm-bin/` → install on myvm via `install -m 755`. Скрипт: `infra/scripts/deploy-bsdos-myvm.sh --all`. Новый транспорт стейджинга — решение D3 в `PLAN-host-split.md`.
- **electron42 build:** `make install` на dev-vm, затем `pkg create electron42` → stage .pkg → `pkg add` на myvm.
- **ssh — транспорт СНАРУЖИ, не внутри рецептов.** Запуск: `ssh <box> 'cd <repo> && <make-цель>'`. Никаких `make → script → nested-ssh` обёрток.
- **Makefile один, GNU.** Таргеты = локальные команды. `make` на host/Mac, `gmake` на FreeBSD (нужен `pkg install gmake` — bmake не понимает GNU-синтаксис `$(shell)`/`$(or)`).
- **Граница ТСПУ:** obfs/транспорт тестируется ТОЛЬКО Mac↔сервер (DPI лежит на этом пути; локально DPI нет — тестировать нечего). Всё остальное (wayland, tunnel↔core, jails) — локально на сервере.

ssh-доступ:
- host: `ssh root@$BSDOS_HOST_IP`
- host→VM: `ssh -i $BSDOS_SSH_KEY freebsd@$BSDOS_DEV_IP` (dev-vm:22, мост). root в VM: `su -m root -c '...'`. (slirp `freebsd@localhost:2222` — fallback.)

Новая операция: добавь локальную цель в Makefile (или скрипт в `infra/scripts/` — без ssh внутри), запускай её там, где она исполняется.

## СУБАГЕНТЫ — обязательный шаблон промпта

**ЛЮБОЙ** субагент — независимо от того, трогает он VM или нет — **должен** начинаться с этого блока:

```
⛔ НИКОГДА не запускать рекурсивный поиск от корня ФС: ни `grep -r /`, ни
   `find / ...`, ни обход /usr, /var, /home целиком. Искать только внутри
   своего рабочего корня и названных в задании подкаталогов. Не знаешь, где
   лежит — сузь и отметь вопрос в отчёте, а не сканируй всё подряд.
⛔ НИКОГДА не вызывать ssh, scp, _ssh.sh в Bash tool.
⛔ socat напрямую к /tmp/bsdos-agent-vport.sock — запрещён.
✅ VM команды ТОЛЬКО через: (в корне клона bzdOS) . infra/scripts/_agent.sh && agent_exec "cmd"
✅ Долгие команды: AGENT_EXEC_TIMEOUT=600 agent_exec_bg "cmd"
✅ Файлы VM: шара $BSDOS_ROOT ↔ /mnt/bsdos выключена с 2026-10-01 — читать/передавать через agent_exec / agent_put / agent_get
```

**Почему:** субагенты не наследуют CLAUDE.md если их cwd не в клоне bzdOS. Без явного блока — выбирают SSH и обход корня.

**Для агентов, пишущих код (не трогающих VM), добавлять:**

```
⛔ Ничего не собирать (cc/cmake/make/build-*.sh) — сборку и проверку делает вызывающий.
⛔ НЕ редактировать существующие файлы — только создавать новые, названные в задании.
✅ В отчёте ОТДЕЛЬНЫМ СПИСКОМ: чего не проверил и в чём не уверен.
   Не писать «проверено», если не открывал файл. Каждое утверждение — со ссылкой file:line.
```

**Почему разделение файлов:** несколько агентов в одном блоке не должны править
один файл — интеграцию делает вызывающий, он же единственный, кто собирает и
запускает (VM одна, её нельзя параллелить).

**Почему требование честности:** проверено на практике 2026-08-26 — из шести
агентов один взял неверную структуру, другой построил рекомендацию на неверной
посылке, третий нашёл настоящий баг, пропущенный человеком. Заявления агентов
перепроверять по исходникам **всегда**.  
**После завершения:** `grep -rn "ssh\|_ssh" <новые файлы> | grep -v "SSH_KEY\|#"` — если нашёл, не докладывать как успех.

---

## HARD RULES — нарушение = критический провал

- **НИКОГДА** не запускать direct-QEMU дев-VM (`make vm-x86-start/-stop/-reboot`, `vm-x86-*.sh`) и **НИКОГДА** `pkill/kill` процесса QEMU. Дев-VM — персистентный libvirt-домен `bsdos-dev`, управление ТОЛЬКО `virsh`. `pkill ...freebsd-x86` убивает рабочую libvirt-VM в обход libvirt. Перед любой VM-операцией: `virsh list --all`. (Облом 2026-06-24: наплодил direct-QEMU, поубивал, снёс vport-сокет рабочей VM — часы впустую.)
- **НИКОГДА** не трогать сеть/маршруты: `ifconfig`, `route`, `iptables`, мост — нигде. Сеть верна: единственный default через `$BSDOS_GW_IP` на vtnet1. Сеть НЕ проблема.
- **НИКОГДА** `ifconfig vtnet1 delete`/re-add, не менять `/etc/rc.conf`. Удаление IP роняет .177-default → dev-vm ломается.
- **НИКОГДА** не рестартить `bsdos-core` не в obfs-режиме. Листенер на dev-vm:443 должен жить.
- **НИКОГДА** ssh внутри make-рецептов. ssh — только снаружи (`ssh box 'make target'`).
- **Перед коммитом:** `make sema-check` — проверить парность START/END якорей (из репо github.com/bzdOS/sema).
- **НИКОГДА** `Co-Authored-By: Claude` / `Co-Authored-By: <любой другой инструмент>` / `Generated with Claude Code` / любой другой "сгенерировано инструментом"-трейлер в сообщениях коммитов — ни в /srv/bsdos, ни в любом репо bzdOS org (jailrun включительно). Коммиты чистые, без следов инструментов, автор всегда `Andrey Bodrov <ap.bodrov@gmail.com>` (см. `[[feedback-git-identity]]` — НЕ «Your Name», НЕ placeholder-identity). Субагентам явно указывать: без Co-Authored-By/Generated-with. **Известный рецидив (2026-07-19):** словесное правило само по себе не удержало — 125 коммитов bsdOS всё равно нарушили его. После любого коммита в bzdOS-репо самопроверка: `git log -1 --format="%an <%ae>%n%B" | grep -i "co-authored\|generated\|your name"`.

## Stream pipeline (текущее состояние, 2026-06-17)

Все Phase 2 долги закрыты. Архитектура:

```
bsdos-core StreamManager
  └─ start_stream(cfg) → spawn_processes() [async, tokio::time::sleep]
       ├─ cage --headless (WLR_BACKENDS=headless, WLR_RENDERER=pixman)
       ├─ wayland-tunnel (WLSTREAM_STREAM_SOCK=/tmp/bsdos/streams/<app_id>/wayland-stream.sock)
       ├─ app (foot / chrome / electron42 / cog)
       └─ tokio tasks: wayland_forwarder + stream_input_handler + stream_resize_handler
```

- **Socket path**: per-stream `/tmp/bsdos/streams/<app_id>/wayland-stream.sock` через `WLSTREAM_STREAM_SOCK` env (закрыто).
- **Protocol**: wayland_forwarder.rs читает v1 length-prefixed `[u32 LE size][payload]` (закрыто).
- **Real apps**: foot (terminal) + chromium (browser) streaming на myvm (закрыто).
- **Дубли**: stop_stream() делает SIGKILL+wait всех child; новый start не запустится если app_id в registry (закрыто).

**myvm ($BSDOS_MYVM_IP) AUTOSTREAM:** `appTerminal:foot:,appBrowser:chrome:about:blank`
(appCowork:cowork: ждёт electron42. Причина: electron39 несовместим — pty.node скомпилирован под electron42 Node ABI; rebuild невозможен без node-addon-api в node_modules.)

**electron42 build (pending):** нужен full FreeBSD ports tree (`git clone` без sparse) + rust >= 1.96.0 (в pkg сейчас 1.94.0) + ~30-40GB WRKDIR. До готовности electron42: 2-stream setup (Terminal+Browser).

**Relay topology (2026-06-18):** Mac viewer (client) → obfs/$BSDOS_DEV_IP:443 → dev-vm (router, bsdos_pipeline, ZENOH_MODE=router) → TCP $BSDOS_MYVM_IP:7447 → myvm (bsdos_core_server, router mode, publishes streams). TCP dev-vm→myvm:7447 подтверждён. dev-vm registry пустой (только relay, нет локальных стримов).

**electron39 на myvm** установлен (pkg install electron39), claude-cowork скопирован в /opt/claude-cowork. Можно включить appCowork после electron42 или rebuild node-pty для electron39.

## CRITICAL: dev/build VM = персистентный libvirt-домен `bsdos-x86` (см. `docs/DEV-VM.md`)

**Сборочная dev-VM (amd64 + aarch64 cross) — это персистентный libvirt-домен `bsdos-x86`. Управление ТОЛЬКО через `virsh`. Полная модель доступа и восстановления: `docs/DEV-VM.md`.**

```bash
virsh list --all                 # ПЕРВЫМ ДЕЛОМ: посмотреть что уже крутится
virsh domstate bsdos-x86         # running? (персистентная, не гасить просто так)
virsh start bsdos-x86            # поднять если shut off (НЕ make vm-x86-start!)
```

**Топология `bsdos-x86` (3 канала):**
- **SSH (setup)**: `ssh -i $BSDOS_SSH_KEY freebsd@$BSDOS_DEV_IP` (bridged NIC vtnet1→br0, это «дев VM dev-vm»). root: `su -m root -c '...'`. Легитимно ТОЛЬКО для setup (pkg/sysrc/старт агента), НЕ для runtime.
- **virtiofs/9p (файлы)**: был `$BSDOS_ROOT` (хост) == `/mnt/bsdos` (гость). **Отключён в госте 2026-10-01** (см. «Переходное состояние» выше); `<filesystem>` в XML домена ещё стоит, 9p-строка в fstab гостя boot-critical — снимать только по `PLAN-host-split.md` этап 6.
- **virtio-console агент (runtime)**: хост-сокет `/tmp/bsdos-agent-vport-x86.sock` (суффикс `-x86`!) ↔ гостевой chardev **`/dev/ttyV0.2`** (port 2 = `bsdos.agent`; port 1 = `/dev/ttyV0.1` = SPICE). Команды: `cd /srv/bsdos && . infra/scripts/_agent.sh && agent_exec "cmd"`.
- `bsdos-dev` (aarch64, диск `freebsd14.qcow2`) — ДРУГАЯ VM, НЕ сборочная. Не путать.

### Если `agent_exec` молчит — проверь чардев (корневой баг 2026-06-24)
Канал `bsdos.agent` = `disconnected` обычно значит: агент в госте жив, но открыл НЕ ТОТ чардев. Реальный порт агента — `/dev/ttyV0.2` (НЕ дефолтный `/dev/ttyV1.1`, которого вообще нет!). Фикс (через SSH dev-vm, перманентно): `sysrc bsdos_agent_chardev=/dev/ttyV0.2; service bsdos_agent restart`. Проверка: `virsh dumpxml bsdos-x86 | grep -A1 bsdos.agent | grep state` → `connected`. Полная диагностика — `docs/DEV-VM.md`.

### ⛔ HARD RULE (облом 2026-06-24, чтобы не повторять)
- **НИКОГДА** `make vm-x86-start/-stop/-reboot`, `vm-x86-*.sh` — это direct-QEMU, поднимает ЛИШНИЙ инстанс на том же `freebsd-x86-15.1.qcow2` (риск двойного писателя в qcow2). Слот vport у direct-QEMU = `/tmp/bsdos-agent-vport.sock` (БЕЗ `-x86`) — не путать с libvirt-сокетом.
- **НИКОГДА** `pkill -f qemu` / `...freebsd-x86` / `kill` процесса QEMU — паттерн матчит процесс libvirt-домена `bsdos-x86`, убьёшь рабочую VM в обход libvirt. Остановка ТОЛЬКО `virsh shutdown/destroy bsdos-x86`.
- **НИКОГДА** socat напрямую к vport/serial сокету — fragile, заблокировано guardrail. Только `agent_exec`.
- **Перед ЛЮБОЙ операцией с VM:** `virsh list --all`. Не гадать, не плодить инстансы.
- **Почему:** 2026-06-24 — пошёл по устаревшей секции с direct-QEMU, наплодил инстансов, `pkill`-нул рабочую VM, снёс vport, потратил часы. Реальная build-VM всё это время была `bsdos-x86` под libvirt.

Логи boot: `tail artefacts/logs/serial-x86.log` (libvirt пишет serial туда, read-only).

## CRITICAL: Guest access model

- **SSH user:** `freebsd` (key: `bsdos-key`) — this is the only SSH-accessible account.
- **Root:** via `su -m root -c '...'` from freebsd (wheel group, PAM allows without password).
- **DO NOT** try to SSH directly as root — key is installed only for freebsd user.
- **host→VM напрямую (основной путь дев-работы):** `ssh -i $BSDOS_SSH_KEY freebsd@$BSDOS_DEV_IP` (dev-vm:22, мост). См. Операционную модель выше.
- `make vm-ssh` → interactive freebsd shell. For root commands see `infra/scripts/_ssh.sh`.

## CRITICAL: Jail operations require root

`jailmgr.sh`, `jail -c`, `mount`, `umount` — all need root. The scripts in `infra/scripts/`
handle this via `su -m root`. Never run them bare.

## Guest paths (VM dev-vm, FreeBSD 15.1)

⚠ Строки с `/mnt/bsdos` описывают состояние до 2026-10-01: шара отключена, это локальный каталог dev-vm, а не host `$BSDOS_ROOT`.

| What | Path |
|---|---|
| Sources | git-checkout bzdOS: `/opt/bsdos-src/` |
| Per-host values | `/etc/bsdos/hosts.env` (+ Zenoh certs в `/etc/bsdos/`) |
| bsdos-core binary | `/mnt/bsdos/artefacts/myvm-bin/bsdos-core` |
| wayland-tunnel binary | `/mnt/bsdos/artefacts/myvm-bin/wayland-tunnel` |
| Logs | `/mnt/bsdos/artefacts/logs/` |
| Streams runtime dir | `/tmp/bsdos/streams/<app_id>/` |
| Agent vport socket | `/tmp/bsdos-agent-vport.sock` |
| Darling build dir | `/var/darling-build/` |
| IPA runtime overlay | `/mnt/bsdos/artefacts/darling-overlay/` |

## Source code rules

**Rust (broker + app):**
- No `unsafe` outside FFI
- No `.unwrap()` — use `?` or explicit `match`/`map_err`
- Контракт функции (`/// purpose/input/output/sideEffects`) перед телом — обязательно (см. github.com/bzdOS/sema)
- Errors propagate via `Result`; `fn main()` returns `Result` or prints and exits cleanly

**Zig (HAL — future):**
- No hidden allocations — pass `allocator: std.mem.Allocator` explicitly
- `@cImport` for FreeBSD C headers; isolate behind `if (builtin.os.tag == .freebsd)` guards
- Target: `aarch64-freebsd.15.1` (QEMU Squirrel dev / Banana Pi Chimp). Woodpecker (PinePhone) = oBzdOS on OpenBSD — separate base OS. RISC-V — ⛔ DEFERRED 2026-06-15.

**QML (UI — future):**
- Zero business logic in QML — display only
- All logic lives in Rust backend; QML calls IPC

## Quick start (FreeBSD 15.1 dev VM)

```bash
# Bootstrap — сборочная дев-VM это персистентный libvirt-домен bsdos-x86 (см. секцию выше).
virsh list --all              # что уже запущено (ВСЕГДА первым)
virsh start bsdos-x86         # поднять дев-VM если shut off (НЕ make vm-x86-start!)
# ⛔ make vm-x86-start / vm-x86-stop / vm-inject-startup — DEPRECATED (direct-QEMU, запрещено)
# ⛔ bsdos-dev — ДРУГАЯ VM (aarch64, freebsd14.qcow2), не сборочная

# Guest setup
make vm-setup-pkg             # pkg install rust zig cmake
make vm-setup-jail            # jail dirs + base.txz extract
make build-agent              # guest agent binary
make run-agent                # start agent on virtio-console

# Verify
make vconsole-check           # agent protocol test (should PASS)
make demo-smoke               # integration tests
```
(`make vm-setup-p9fs` монтирует шару, которая с 2026-10-01 выключена — см. «Переходное состояние».)

---

## Architecture quick-ref

```
Mac: metal-viewer ──Zenoh / obfs :443──► dev-vm bsdos_pipeline (router) ──TCP 7447──► myvm bsdos-core
                                                                                  │ StreamManager
                                                                                  ├─ cage --headless
                                                                                  ├─ WLTunnel ──► Zenoh stream
                                                                                  └─ app (foot / chromium)
FreeBSD 15.1 guest:  bsdos-core · lifecycled (jail FREEZE/THAW) · bsdos-pkgd (.jpk)  — repo bzdOS/bzdOS
                     jails: devfs ruleset + ip4=inherit|disable, kernel-enforced
BPI-M64 (Chimp):     bzdk EL2 hypervisor owns the hardware → FreeBSD guest (bsdos-hal, lima-freebsd)
```
Компоненты и их репо — `docs/EXTRACTION-MAP.md`; что было в монорепо до 2026-10-01 — `docs/archive/`.

**Key ports:** 443 → obfs вход на dev-vm, 7447 → Zenoh dev-vm↔myvm, 2222 → SSH (slirp fallback), 5900 → SPICE GUI

**Display:** QEMU QXL/virtio-gpu (Squirrel). Real device: fbdev + weston → Lima (`bzdOS/lima-freebsd`). Почему drm-subtree+DRMKPI и чего не хватает (MIPI-DSI для PinePhone) — `docs/LESSONS.md` §Display and GPU.

## Makefile variables

| Var | Default | Override |
|---|---|---|
| `VM_X86_IMG` | `./freebsd-x86-15.1.qcow2` | `make vm-x86-start VM_X86_IMG=/path/to/img` |
| `SSH_KEY` | `./bsdos-key` | — |
| `VM_SSH_PORT` | `2222` | — |
| `VM_IPC_PORT` | `9999` | — |
| `FW_X86` | `/usr/share/OVMF/OVMF_CODE_4M.fd` | — |

## Troubleshooting

| Symptom | Fix |
|---|---|
| `vm-wait` never completes | Check `tail -f artefacts/logs/serial.log`; if empty, QEMU may have died — check `make vm-status` |
| SSH rejected | Guest uses `freebsd` user only; `bsdos-key` must match `seed.iso` public key |
| `jail -c` fails | Ensure jailmgr runs as root; `make jail-teardown` before `jail-setup` if jails stuck |
| `nc -U` in smoke test fails | Unix socket didn't mount through nullfs — see fallback in docs/archive/2026-10-01-monorepo/PLAN-jail-prototype.md §10 |
| KVM slow on TCG | Normal on x86 TCG host; use native ARM (Hetzner CAX) for speed |
| QEMU crash on shutdown | Always use `make vm-stop` (graceful shutdown) — don't kill QEMU process directly |
