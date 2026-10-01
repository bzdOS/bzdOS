# SESSION_RULES.md — bsdOS Session Bootstrap

Загружать в начало каждой сессии. Содержит operational rules, hard constraints, и текущий контекст.

---

## 1. Обязательное чтение перед работой

1. `CLAUDE.md` — hard rules, tech choices, VM access model
2. `AGENTS.md` — multi-agent protocol, Zenoh topics, claims; ПЕРВАЯ секция — координация
   dev-команды через hubd-трекер (ритуал сессии, INBOX, очереди)
3. `github.com/bzdOS/sema` — разметка: синтаксис, минимум полей, golden sample
4. `AppGraph.xml` — модули, сценарии, связи
5. `INBOX.md` — шапка (~40 строк, новые сверху): журнал команды; затем
   `hub queue wait <твоя-роль> --timeout 10` — адресные задания
6. `DOCS_INDEX.md` — карта всех активных документов + `docs/archive/2026-06-15-plans/README.md`
7. `ROADMAP.md` — **canonical status**, включая animal-codename scheme (Squirrel/Chimp/Woodpecker)

## 2. Hard Rules (нарушение = критический провал)

- **НИКОГДА** не трогать сеть/маршруты (`ifconfig`, `route`, `iptables`)
- **НИКОГДА** не менять `/etc/rc.conf` на VM
- **НИКОГДА** `ifconfig vtnet1 delete/re-add`
- **НИКОГДА** ssh внутри make-рецептов
- **НИКОГДА** не рестартить `bsdos-core` не в obfs-режиме
- Rust: без `unsafe` вне FFI, без `unwrap()`
- Zig: явный allocator, нет скрытых аллокаций в hot paths
- IPC: Cap'n Proto (data), text protocol (control)
- Все операции через `make <target>`

## 3. Операционная модель

```
Mac (obfs-client) → host $BSDOS_HOST_IP (libvirt/QEMU, данные $BSDOS_ROOT)
                      → VM $BSDOS_DEV_IP (FreeBSD: bsdos-core, cage, wayland-tunnel)
```

- Истина кода: репо org github.com/bzdOS (с 2026-10-01; карта — docs/EXTRACTION-MAP.md)
- 9p/virtiofs-шара `/mnt/bsdos` == host `$BSDOS_ROOT` выключена в госте с 2026-10-01
- SSH: `./ssh-guest.sh` (freebsd), `./ssh-guest.sh root` (root)
- Build wayland-tunnel: `/tmp/wayland-tunnel-build/` (не в 9p — root-owned, нет write perms)
- Build bsdos-core: `cd /mnt/bsdos && cargo build --release -p bsdos-core` → `/mnt/bsdos/target/release/bsdos-core`

### Animal codename scheme (locked 2026-06-13, multi-arch updated 2026-06-15)

| Codename | Version | Stage | Target |
|---|---|---|---|
| **Squirrel** (Белка) | v0.1.x | QEMU sandbox (small/quick) | QEMU **amd64 + aarch64** (multi-arch, equal status) |
| **Chimp** (Шимпанзе) | v0.2 | First tool-user (real hardware) | Banana Pi (BPI-M64/M2, Allwinner H616/H618/A523, aarch64 only) |
| **Woodpecker** (Дятел) | v0.3 | oBzdOS — paranoid mobile | PinePhone (A64, Mali-400, aarch64) — **oBzdOS (OpenBSD base)**, отдельный проект от bsdOS |

**⛔ RISC-V DEFERRED 2026-06-15**: BPI-F3 (SpacemiT K1) shelved indefinitely.
Allwinner A64 (aarch64): v0.2 (BPI-M64/Chimp, FreeBSD); v0.3 (PinePhone/Woodpecker, **OpenBSD** — разные OS, разные драйверы). See `docs/archive/2026-10-01-monorepo/PLAN-bpi-f3-bringup.md`.

**Squirrel multi-arch (locked 2026-06-15 per user "арм и амд равнозначный пока"):**
amd64 QEMU = primary dev loop (KVM fast, TCG fallback good); aarch64 QEMU =
architectural target (catches alignment/endianness/NEON bugs early, same arch
as Chimp). Both ship in same release
(`bsdos-squirrel-v0.1.3-amd64.img.gz` + `-aarch64.img.gz`). CI tests both.
See `docs/specs/SPEC_squirrel_rootfs.md` for the build pipeline (hubd task
#38, deadline 2026-07-31).

**Squirrel build pipeline STATUS (2026-06-17, commits 8690c2b→dddaacb):**
- amd64: `make squirrel-smoke-amd64` → PASS (18s KVM boot, bsdos-core + Zenoh + login)
- aarch64: `make squirrel-smoke-aarch64` → PASS (66s TCG boot, FreeBSD/arm64 login)
- cage (55KB) + foot (504KB) installed in both images via pkg
- aarch64 cross-compile: `cargo +nightly -Z build-std=std,panic_abort` + clang
  cross-linker (`--target=aarch64-unknown-freebsd14.1 --sysroot=$WORK/rootfs -fuse-ld=lld`)
- Zig target: `aarch64-freebsd-none` (NOT `.15.1` — Zig bundled libc 1.7.0 < 1.8.0)
- Cross-arch pkg: `ABI=FreeBSD:15:aarch64` (capital F!) + `OSVERSION=1500000`, individual install
- FAT32 ESP: `newfs_msdos -F 32 -c 2 -h 255 -u 63` (makefs -t msdos produces invalid FAT)
- E2E 2-stream: boot works (~35s with GPU), autostream needs tuning (cage+foot spawn)
- Open tasks: #68 (image size 1.3-1.4G → 150MB), #69 (CI sync)

### VM управление (libvirt)

**VM `bsdos-dev` управляется через libvirt**, НЕ через `infra/scripts/vm-x86-start.sh`.

```bash
virsh list --all              # статус
virsh dominfo bsdos-dev       # память, CPU, state
virsh shutdown bsdos-dev      # graceful
virsh destroy bsdos-dev       # force kill (graceful не всегда работает)
virsh start bsdos-dev         # запуск

# Смена памяти (VM должна быть shut off):
virsh setmaxmem bsdos-dev 8388608 --config   # max 8GB
virsh setmem bsdos-dev 8388608 --config       # current 8GB
virsh start bsdos-dev
```

- libvirt автоперезапускает VM при падении (scope: `machine-qemu\x2d1\x2dbsdos\x2ddev.scope`)
- OVMF VARS: `/var/lib/libvirt/qemu/nvram/bsdos-x86_VARS.fd` (libvirt управляет, не трогать руками)
- Disk: `freebsd-x86-15.1.qcow2` (НЕ `freebsd-x86.qcow2` — тот старый)
- Port forwards: 2222→22, 9999→9999, 9222→9222, 5902→5901

## 4. Wayland Pipeline Architecture

```
Firefox → compositor → relay thread (poll fds[0..2])
  ↓ frame callback
  tracker.getLatestFrame() → pixels
  ↓ pool_reset_gen check (gen: atomic u32, main()-only increment)
  sendPoolData() → stream_clients[0..N] (bsdos-core, stream-reader, ...)
  sendSurfaceCommit() → stream_clients[0..N]
```

### Late-join resend (2026-06-12 fix)

**Баг:** Когда stream-клиент подключался после рендера Firefox (about:blank),
relay не отправлял существующий кадр — ждёт нового `wl_surface.commit`,
которого нет. poll() висит с timeout=-1.

**Решение (relay.zig):**
1. poll timeout изменён с -1 на 500ms — periodic wakeup
2. `last_frame_info` кэширует метаданные последнего кадра (surface_id, pool_id,
   dimensions, pixel_len) после каждого successful send в FRAME_CAPTURE
3. `START_LATE_JOIN_RESEND` блок (вне POLLIN) проверяет `pool_reset_generation`:
   при изменении → сброс pool_hashes + resend `buffers.pixel_buf` через
   sendPoolData + sendSurfaceCommit

### bsdos-core stream read timeout (2026-06-12 fix)

`wayland_bridge` обёрнут в `tokio::time::timeout(10s, read_exact)`.
При таймауте → break → reconnect (outer loop).

### Pipeline health check (2026-06-12)

Supervisor (`bsdos-pipeline`) после старта ждёт до 15s:
1. `grep 'Stream client connected' /tmp/wayland-tunnel.log`
2. `grep 'POOL_DATA received' /tmp/bsdos-core.log`
Если нет → restart pipeline.

### Ключевые решения (rationale)

- **Единственная точка stream accept** — только main() принимает stream-клиентов.
  Relay threads НЕ опрашивают stream_server_fd. Устраняет race condition на accept().

- **pool_reset_generation (atomic u32)** — инкрементируется ТОЛЬКО из main() при
  добавлении нового stream-клиента. Каждый relay thread отслеживает last_pool_reset_gen
  локально и сбрасывает pool_hashes.sent при изменении.

- **pool_hashes per relay thread** — дедупликация кадров локальна для каждого треда.

- **Relay thread poll: [3]fds** — client_fd, compositor_fd, input_fd.
  Раньше было [4] — stream_server_fd убран (был race condition).

### Сокеты на VM

| What | Path | Кто server | Кто client |
|---|---|---|---|
| Wayland | `/tmp/wayland-run/wayland-ghost-0` | tunnel | cage/Firefox |
| Stream | `/tmp/wayland-run/wayland-stream.sock` | tunnel (main()) | bsdos-core, stream-reader |
| Input | `/tmp/wayland-run/input.sock` | bsdos-core | tunnel (relay thread) |

### Stream Protocol v1

```
[payload_size: u32 LE][event_type: u8][data]

EV_POOL_DATA      = 0x03  → pool_id(4) w(2) h(2) stride(4) fmt(4) raw_len(4) lz4_len(4) pixels
EV_SURFACE_COMMIT = 0x04  → surface_id(4) pool_id(4) offset(4) w(2) h(2) stride(4) fmt(4) damage(8)
EV_SESSION_RESET  = 0xFE  → reason(1) msg_len(1) msg
EV_ERROR          = 0xFF  → code(2) msg_len(1) msg
EV_CURSOR_MOVE    = 0x05  → x(4) y(4)
```

## 5. Текущие модули wayland-tunnel

```
src/
  main.zig    — entry, socket creation, main poll, ЕДИНСТВЕННЫЙ stream accept (~164 строки)
  relay.zig   — relay thread: poll[3], frame processing, hash dedup (~330 строк)
  stream.zig  — sendPoolData, sendSurfaceCommit, stream_clients[], mutex, pool_reset_gen (~264 строки)
  protocol.zig — Wayland message parsing + interception (~400 строк)
  input.zig   — keyboard/pointer injection (~150 строк)
  socket.zig  — createStreamSocket, createWaylandSocket, connectToCompositor, recvWithFds (~250 строк)
  c.zig       — единый @cImport (wayland-client, lz4, sys/socket)
  wl_shm.zig  — WlShmTracker (shm pool tracking)
  wl_registry.zig — WlRegistry (interface lookup)
```

## 6. Семантическая разметка — минимум для работы

### Состояние на 2026-06-12

- **105/105 source файлов** с `START_AI_HEADER` / `END_AI_HEADER` (Rust + Zig + module headers, build configs)
- **~918 function-region markers** (`name:start` / `name:end`)
- **hal/ наполнен реальными контрактами** (17 файлов, 268 region markers, 0 TODO-плейсхолдеров)
- `make sema-check` → OK (валидатор в github.com/bzdOS/sema)
- Скрипт разметки: `/tmp/audit-markup.py` (idempotent, brace-matching для `:end` placement)

### Module contract (начало файла)
```
// START_AI_HEADER
// MODULE: filename.ext
// PURPOSE: кратко что делает
// INTENT: зачем существует
// DEPENDENCIES: что использует
// PUBLIC_API: публичные функции
// END_AI_HEADER
```

### Function contract (перед телом)
```
// blockName:start
//   purpose: что делает
//   input: параметры
//   output: что возвращает
//   sideEffects: none | список
// blockName:end
```

### Правила
- Annotation-first: сначала контракт, потом код
- Уникальные имена якорей: `START_PARSE_INPUT`, не `START_PARSE`
- Только `//` комментарии в Zig/Rust/C
- Не масс-аннотировать — разметка где следующая правка

### Выбор уровня детализации

| Триггер | Форма |
|---|---|
| Функция >30 строк / public API / есть sideEffects | Полная (purpose/input/output/sideEffects) |
| Приватный helper, очевидная сигнатура | Сжатая (`// CONTRACT: parse → validate → store`) |
| Тривиальная <10 строк, без эффектов | Однострочная |

Однострочная форма **запрещена** если тело вызывает `set/create/write/send/emit`.

### Ключевые правила (trigger → action)

1. Новая функция → контракт + `TODO: IMPLEMENT ME`, потом тело
2. Правка существующего кода → сначала обновить контракт
3. Вызов `set/create/write/send` → эффект в `sideEffects`
4. Блок >200 токенов → разбить на регионы `START_X/END_X`
5. Блок <40 токенов с полным контрактом → сжатая/однострочная форма
6. «Странное» решение (отключенная фича, костыль) → `intent` или `rationale` обязательны

### Анти-паттерны (НЕ делать)

- Родовые теги (`<module name="X">`) → использовать `<X_module>`
- Контракт после тела → всегда перед
- Масс-аннотирование → разметка где следующая правка
- Подразумеваемые связи → явно через `usedBy`/`references`
- Многострочный контракт на тривиальной функции → однострочная форма

Полная методология: [github.com/bzdOS/sema](https://github.com/bzdOS/sema) §7 (правила), §11 (гранулярность), §13 (анти-паттерны).

## 7. Build & Deploy Workflow

```bash
# Wayland tunnel (на VM)
./ssh-guest.sh "cp /mnt/bsdos/wayland-tunnel/src/*.zig /tmp/wayland-tunnel-build/src/"
./ssh-guest.sh "cd /tmp/wayland-tunnel-build && rm -rf .zig-cache zig-out && /usr/local/bin/zig build -Doptimize=Debug"
./ssh-guest.sh root 'install -m 755 /tmp/wayland-tunnel-build/zig-out/bin/wayland-tunnel /usr/local/bin/wayland-tunnel && service bsdos_pipeline restart'

# bsdos-core (на VM)
./ssh-guest.sh "cd /mnt/bsdos && cargo build --release -p bsdos-core"
./ssh-guest.sh root 'install -m 755 /mnt/bsdos/target/release/bsdos-core /usr/local/bin/bsdos-core && service bsdos_pipeline restart'

# Тест
./ssh-guest.sh "timeout 8 /usr/local/bin/stream-reader 2>&1 | head -10"
```

### Timing
- Pipeline restart: ~6-8 секунд до стабилизации
- `sleep 8` после restart перед тестами
- Tunnel log: `/tmp/wayland-tunnel.log`
- bsdos-core log: `/tmp/bsdos-core.log`

### Известные нюансы
- `service bsdos_pipeline restart` спамит `/etc/rc.conf: $BSDOS_DEV_IP/28: not found` — harmless
- Stale `thiserror_impl` .so в target/deps → E0786 — удалить и rebuild
- Zig 0.15.2 на VM: нет `std.c.getErrno` → `std.posix.errno`; нет `.WOULDBLOCK` на FreeBSD
- 9p mount root-owned → chown для target/ иногда нужен
- **STREAM_TOPIC**: bsdos-core default topic = `bsdos/global/wayland/stream`, Mac слушает
  `bsdos/jail/appBrowser/stream`. Pipeline supervisor ДОЛЖЕН передавать
  `BSDOS_STREAM_TOPIC=bsdos/jail/appBrowser/stream` в env bsdos-core.
  Без этого — core публикует в пустоту, Mac не получает кадры.
- **bsdos-core binary**: workspace target → `/mnt/bsdos/target/release/bsdos-core`
  (НЕ `/mnt/bsdos/bsdos-core/target/release/bsdos-core`)

## 8. Debugging Checklist

1. Проверить что pipeline жив: `./ssh-guest.sh "service bsdos_pipeline status"`
2. Проверить процесс: `./ssh-guest.sh "pgrep -la wayland-tunnel"`
3. Лог туннеля: `./ssh-guest.sh "tail -30 /tmp/wayland-tunnel.log"`
4. Лог core: `./ssh-guest.sh "tail -30 /tmp/bsdos-core.log"`
5. Stream-reader: `./ssh-guest.sh "timeout 6 /usr/local/bin/stream-reader 2>&1 | head -5"`
6. Сокеты: `./ssh-guest.sh "ls -la /tmp/wayland-run/"`

## 9. Input Pipeline Status

### Текущее состояние (2026-06-12)

**Серверная сторона (VM) — РАБОТАЕТ:**
- input.sock reconnect — работает (relay threads подключаются с backoff)
- wl_keyboard.enter opcode — исправлен (0→1)
- input.zig frame buffer + handleInputEvent — реализовано

**Deferred caps injection + ID gap fill — РАБОТАЕТ:**
- relay НЕ патчит caps в-лёту (вызывает ID конфликты при бандлировании)
- после первого wl_surface.commit → inject синтетический `wl_seat.capabilities(3)` клиенту
- `get_pointer(N)` и `get_keyboard(N+1)` → relay захватывает ID, но дропает, вместо этого
  отправляет cage `create_region(N)+destroy(N)` для заполнения ID-пробела в wl_map
- ptr_id и kb_id корректно захватываются для input injection

**НЕ реализовано:**
1. ~~`wl_keyboard.keymap` synthetic response~~ — **СДЕЛАНО** (2026-06-12): XKB_V1 через mkstemp+SCM_RIGHTS, `focused_surface_id` для enter, `wl_keyboard.modifiers` после enter
2. ~~Mac NSEvent capture~~ — **СДЕЛАНО** (main.rs:795-1019): addLocalMonitorForEventsMatchingMask + KeyDown/KeyUp/FlagsChanged/Mouse*/ScrollWheel → push_key_event/push_pointer_event/push_scroll_event → Zenoh → bsdos-core → input.sock

### Архитектура виртуального ввода (Virtual Input Objects)

```
cage headless (caps=0) → relay intercepts → client sees caps=3
client sends get_pointer(N) → relay: DROP + send create_region(N)+destroy(N) to cage
client sends get_keyboard(N+1) → relay: DROP + send create_region(N+1)+destroy(N+1) to cage
relay captures ptr_id=N, kb_id=N+1
input events → input.zig → inject directly to client_fd using captured IDs
```

### Mac сторона

- input.rs publisher thread — реализован, но нет NSEvent capture hook
- Нужен `NSEvent.addLocalMonitorForEventsMatchingMask_handler()` или override keyDown:/mouseDown:

## 9.1 Unit-test инфраструктура (добавлено Kimi K2.7, 2026-06-13)

Хост-билдабельные unit-тесты собираются через `make unit-tests`. Каждый подтаргет
изолирован от bridge runtime (zenoh + tokio) feature-флагом, чтобы запускаться
на stable rust без nightly `freeze` (zenoh тянет stabby-abi → нужен nightly).

| Target | Файл / шаг | Тестов |
|---|---|---|
| `make bsdos-core-test` | `bsdos-core/src/protocol.rs` (extract чистой логики из `main.rs`) | 30 |
| `make metal-viewer-test` | `mac-companion/metal-viewer/src/wayland_stream.rs::tests` | 18 |
| `make wayland-tunnel-test` | `wayland-tunnel/src/test_wayland_parse.zig` | 6 |
| `make wayland-input-test` | `wayland-tunnel/src/input.zig` (нужен libc + sys/mman.h) | 3 |
| `make wayland-stream-test` | `wayland-tunnel/src/test_stream.zig` (header encoding) | 14 |
| `make sensor-test` | `hal/src/test_sensors.zig` | n/a |

**Изменения архитектуры:**
- `bsdos-core` — добавлен `src/protocol.rs` (helpers: `parse_size_request`,
  `compute_logical_size`, `payload_event_type`, `extract_pool_id_from_*`,
  `should_republish_pool`, `format_keyboard_payload`, `format_pointer_payload`,
  `is_valid_pool_payload_size`). `Cargo.toml`: zenoh/futures стали optional
  под feature `with-bridge`; bin-таргеты — `required-features = ["with-bridge"]`.
- `mac-companion/metal-viewer` — добавлен `[lib]` с именем `bsdos_metal_viewer`.
  `src/lib.rs` реэкспортит `wayland_stream`. Снят `#[cfg(target_os = "macos")]`
  с `pub mod stream_parser` и `pub mod compositor` (они std-only).
  `Cargo.toml`: zenoh/tokio/pico-args → optional; bin — `required-features`.
  `main.rs` импортит `bsdos_metal_viewer::wayland_stream::...` вместо локального
  `crate::wayland_stream::...`. Локальный `mod wayland_stream;` удалён.

**Результат:** `make unit-tests` зелёный на host Linux.

## 10. Правила работы с документацией

- **Проектная документация живёт в репо bzdOS** (CLAUDE.md, AGENTS.md, SESSION_RULES.md,
  AppGraph.xml, PLAN-*.md, docs/).
- `/tmp/*.md` — временные файлы для черновиков и заметок. НЕ являются документацией проекта.
- **Обновлять документацию после каждого значимого изменения:**
  - Триггер: commit или deploy завершён успешно → обновить соответствующий PLAN-*.md
  - Триггер: изменена архитектура → обновить SESSION_RULES.md, AppGraph.xml
  - Триггер: найден и пофиксен баг → обновить /tmp/pool-data-bug.md или等效
  - Триггер: конец сессии → обновить SESSION_RULES.md разделы 4-9 если что-то менялось
- Если /tmp/ файл содержит актуальную информацию → скопировать в проект перед концом сессии.
- Annotation-first (github.com/bzdOS/sema): сначала контракт в коде, потом реализация.

### Структура docs/ (refactored 2026-06-15)

```
docs/
├── q3-architecture.md       # Q3 streams A-G, risk register
├── risk-register.md         # A/B/C-grade risk register
├── v0.1.2-release-plan.md   # v0.1.2 (zenoh-peer test infra) — SHIPPED
├── v0.2-release-plan.md     # v0.2 "Chimp" Beta (F2-F5)
├── specs/                   # architect-level specs (16 files as of 2026-06-15)
│   ├── SPEC_squirrel_rootfs.md
│   ├── SPEC_2stream_squirrel.md
│   ├── SPEC_jpk_descriptor_v1.md
│   ├── SPEC_zenoh_keyspace.md
│   ├── SPEC_zenoh_security.md
│   ├── SPEC_chimp_jail_networking.md
│   ├── SPEC_woodpecker_thermal.md
│   ├── SPEC_woodpecker_power.md
│   ├── SPEC_woodpecker_mobile.md       # NEW: 10 PLAN files synthesized
│   ├── SPEC_woodpecker_hal.md          # NEW: 15 PLAN files synthesized
│   ├── SPEC_woodpecker_apps.md         # NEW: 9 PLAN files synthesized
│   ├── SPEC_woodpecker_matrix.md       # NEW: 5 PLAN files synthesized
│   ├── SPEC_chimp_security.md         # NEW: 7 PLAN files synthesized
│   ├── SPEC_chimp_zenoh.md            # NEW: 6 PLAN files synthesized
│   ├── SPEC_woodpecker_vision.md       # NEW: 11 PLAN files synthesized
│   └── SPEC_chimp_release.md          # NEW: 10 PLAN files synthesized
└── archive/
    └── 2026-06-15-plans/    # 31 residual PLAN-*.md, 73 synthesized into 8 SPECs, 13 deleted as obsoleted
```

**Где что искать:**
- "Что сейчас активно?" → `ROADMAP.md` (canonical status)
- "Какие спеки?" → `docs/specs/SPEC_*.md` (16 файлов: 3 Squirrel + 13 Woodpecker/Chimp)
- "Где план v0.2 Chimp?" → `docs/archive/2026-10-01-monorepo/v0.2-release-plan.md`
- "Где документация по Wayland pipeline?" → `SESSION_RULES.md` §4-5 + `docs/archive/2026-10-01-monorepo/DEV-GUIDE.md` + `github.com/bzdOS/WLStream`
- "Где legacy/архивный план?" → `docs/archive/2026-06-15-plans/<PLAN-name>.md` (31 файл, niche/individual). **Не удалять массово** — каждая группа coherent SPEC уже синтезирована. Философия: **reprocess on triage pass, keep until explicitly retired**.
