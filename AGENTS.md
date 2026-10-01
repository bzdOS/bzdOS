# AGENTS.md — bsdOS

*Прочитать `~/.hubd/AGENTS.md` (хаб-конституцию) ПЕРВЫМ. Этот файл — проектные правила поверх неё.*

> `hubd/` в этом репо — Rust-демон Feature 5 (координация агентов ВНУТРИ bsdOS).
> Этот файл — про координацию dev-сессий, работающих НАД bsdOS, через hubd-трекер.

<!-- START_HUBD_RULES -->
## Правила hubd (обязательны для ВСЕХ агентов)

Эти правила **НЕ опциональны**. Агент, нарушивший правило, портит работу
параллельным сессиям. Хозяин (OWNER) видит нарушения через `hub doctor`,
журнал и git log.

### R1: Старт — hub brief ПЕРВЫМ
```sh
hub brief                    # дедлайны, overdue, журнал, locks
git log --oneline -10        # что закоммичено
```
Без `hub brief` в начале сессии — агент не знает о локами, дедлайнах,
заблокированных задачах. **MUST**: первый tool call после чтения AGENTS.md.

### R2: Claim перед записью
```sh
hub claim bsdos "bsdos-core/src/main.rs"   # ПЕРЕД правкой файла
# ... работа ...
hub release <id>                             # ПОСЛЕ коммита
```
Без claim — два агента правят один файл → конфликт. **MUST**: перед любым
`edit`/`write` вызовом. TTL 240 мин, после — auto-release.

### R3: Report на каждое значимое действие
```sh
hub report "Fix Zenoh timeout in QEMU" -p bsdos -k done
```
Без report — параллельные сессии не знают что произошло. **MUST**: после
каждого коммита. `-k done|broken|blocked|note` — тип события.

### R4: Sync карточки в конце сессии
```sh
hub sync <клон bzdOS> -m "Squirrel smoke 5/5, Zenoh decoupled, agent in image"
```
Без sync — карточка проекта устарела, следующий агент видит дубовый digest.
**MUST**: перед завершением сессии.

### R5: Task add для любой работы >30 минут
```sh
hub task add "Fix font rendering on Retina" -p bsdos -i high
```
Без task — работа невидима в канбане. **MUST**: если задача не в трекере,
создать перед началом. Закрыть — `hub task done <id>`.

### R6: Никогда не закрывай чужую задачу
`hub task done <id>` только для задач, которые **ты** выполнял. Чужие —
комментируй в журнале, закрывает owner.

### R7: Queue для адресных заданий
```sh
hub queue send claude-guest "Build bsdos-agent for aarch64" --from claude-host
hub queue wait claude-guest --timeout 10
```
Не оставляй задания в чатах или INBOX без queue-записи. **MUST**: адресная
работа — через queue.

### R8: Конфликт — STOP и журнал
Claim уже активен на нужном ресурсе? **НЕ ПИШИ**. Запиши в журнал:
```sh
hub report "Blocked: bsdos-core/main.rs claimed by claude-guest" -p bsdos -k blocked
```
Жди release или возьми другую задачу.
<!-- END_HUBD_RULES -->

## Каналы (по убыванию авторитета)
1. **git** — единственная правда про код. Done = закоммичено.
2. **specs/SPEC_\*.md** — задания: исполнитель дописывает `## Report`, ревью — `## Acceptance`.
3. **INBOX.md** — журнал команды: append-only, новые записи СВЕРХУ.
4. **queues/** — адресная доставка (`hub queue send <role> "<text>"` / `hub queue wait <role>`).
5. **MCP** — инструменты `hub_brief`, `hub_report`, `hub_task_*`, `hub_claim`, `hub_release`, `hub_sync`, `hub_search`.

## Ритуал старта сессии
1. `~/.hubd/AGENTS.md` → этот файл (включая **R1-R8** выше) → `SESSION_RULES.md`.
2. **R1**: `hub brief` — дедлайны, overdue, журнал, locks.
3. `git log --oneline -10` + верх `INBOX.md` — что изменилось.
4. `hub queue wait <твоя-роль> --timeout 10` — есть ли адресное задание.
5. **R2**: Перед крупным куском — `hub claim bsdos <area>`.

## Ритуал конца
1. Коммит (формат `<scope>: <что>`).
2. **R3**: `hub report "<дайджест>" -p bsdos -k done|note|blocked`.
3. **R4**: `hub sync <клон bzdOS> -m "<дайджест>"`.
4. Запись в `INBOX.md` СВЕРХУ: `## YYYY-MM-DD HH:MM · <роль>` + Статус.

## Роли агентов

| Агент | Среда | Роль |
|---|---|---|
| `claude-host` | MacBook / Linux dev box | UI-разработка, QML, deploy скрипты, smoke тесты |
| `claude-guest` | FreeBSD QEMU (Squirrel v0.1.x) | Системный код, Zig HAL, FreeBSD-специфика |
| `hubd-local` | Banana Pi M64 (Chimp v0.2 target) | Выполнение задач, file I/O, builds |
| `llama-phone` | Cortex-A53 NEON (Woodpecker v0.3 target) | Offline inference, Qwen 0.5B |

> **Animal codename scheme** (locked 2026-06-13): Squirrel (v0.1.x QEMU **amd64 + aarch64**, bsdOS/FreeBSD) → Chimp (v0.2 Banana Pi BPI-M64, A64, aarch64, bsdOS/FreeBSD) → Woodpecker (v0.3 PinePhone, A64 + Mali-400, **oBzdOS/OpenBSD**). ⛔ RISC-V DEFERRED. See `docs/specs/SPEC_squirrel_rootfs.md`.

## Правила кода
- Rust: без unsafe, без unwrap()
- Zig: явный allocator, @cImport для FreeBSD
- IPC: Cap'n Proto (data), text protocol (control)
- Транспорт: Zenoh (межузловой), Unix sockets (внутри устройства)
- Все операции через `make <target>`, no ad-hoc bash
- **Не предлагать миграцию на mainstream стек** (Linux, Rust, gRPC, Docker) — см. `DESIGN-agent-driven-stack.md`

## Правила документации
- Карта документов: `DOCS_INDEX.md`.
- Канонический статус: `ROADMAP.md`.
- Спеки: `docs/specs/SPEC_*.md` (Squirrel rootfs, 2-stream, jpk descriptor).
- **После значимого изменения**: обновить `docs/specs/SPEC_*.md` или `SESSION_RULES.md`.
- Annotation-first: контракт в коде перед реализацией (см. github.com/bzdOS/sema).

## Zenoh топики (текущие — Squirrel 2-stream)

| Топик | Направление | Содержимое |
|---|---|---|
| `bsdos/telemetry` | guest → host | Cap'n Proto HardwareStatus (32 bytes) |
| `bsdos/app/{app_id}/stream` | guest → host | Wayland frame packets (v1 length-prefixed) |
| `bsdos/app/{app_id}/input/{keyboard,pointer}` | host → guest | InputEvent (7/18 bytes) |
| `bsdos/app/{app_id}/viewer/size` | host → guest | Resize request "WxH@S" |
| `bsdos/ctl/stream/{start,stop,list}` | host → guest | Stream control (JSON) |

> LEGACY browser control topics (`bsdos/browser/*`, `hubd/browser/task`) — superseded per 2026-06-15.

## Distributed Lock Protocol (claims.jsonl)

Внутри устройства (bsdos-core ↔ agents). Не путать с `hub claim` (трекер).

```json
{"agent": "claude-host", "resource": "ui-backend-rust/src/telephony.rs", "action": "write", "ts": 1720000000, "id": "abc123"}
```
1. Перед записью — проверить active lock того же resource.
2. При завершении — `{"id": "abc123", "released": true, "ts": ...}`.
3. Locks старше 300s — auto-released. Конфликт → ждать 5s, max 3 попытки.

## Текущий статус (2026-06-17)

```
make demo             ✅ 5 тестов зелёные
make unit-tests       ✅ 103 теста
squirrel-smoke amd64  ✅ 5/5 PASS (agent PING + bsdos-core + Zenoh + cage + streams)
squirrel-smoke aarch64  ⏳ needs rebuild with latest fixes
Теги: v0.1.0–v0.1.2
Следующий релиз: v0.1.3 (Squirrel image + 2-stream demo) — a hub task

Ключевые коммиты:
  668e2b0  fix(arch): eliminate fragility — guest agent, cache invalidation, Zenoh decoupling
  6693f0e  Zenoh multicast fix + readiness probe + manifest check
```

## Squirrel build + smoke

```sh
# Build (на FreeBSD VM через ./ssh-guest.sh):
make squirrel-build-amd64      # ~5 min warm
make squirrel-build-aarch64    # ~10 min

# Smoke (на Linux host с QEMU):
make squirrel-smoke-amd64      # boots QEMU, agent PING, 5/5 checks
make squirrel-smoke-aarch64    # needs UEFI firmware

# 2 streams:
BSDOS_AUTOSTREAM="appTerminal:foot,appBrowser:wpewebkit-fdo" make squirrel-boot-amd64
make test-2stream-e2e          # gates v0.1.x acceptance

# Mac viewer:
mac-companion/metal-viewer --subscribe "bsdos/app/+/stream" --window-count 2
```

## Tier 1 Extractions

- **github.com/bzdOS/sema** v1.0.0 — semantic markup methodology
- **github.com/bzdOS/WLStream** v1.0.0 — Wayland stream protocol v1 (Rust crate)
