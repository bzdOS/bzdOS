# Карта выноса из монорепо bsdOS → org `github.com/bzdOS`

Снято 2026-10-01: `gh repo list bzdOS` + `git log -1 -- <dir>` по монорепо.
Дата в скобках = последний коммит в каталоге монорепо / последний push в репо.
План разнесения по хостам — [`PLAN-host-split.md`](../PLAN-host-split.md).

**Обновление 2026-10-01 (вечер):** большая часть каталогов физически ушла из
`/srv/bsdos` по хостам (таблица в §0 плана). Где каталог лежит теперь:

| Каталоги | Сейчас |
|---|---|
| `hal/*` (кроме `darling-freebsd`), `sys-daemon-zig`, `mali-uio`, `infra/u-boot`, `bsdos-core`, `bsdos-pkgd`, `bsdos-run`, `lifecycled`, `jpk-*`, `guest-agent`, `wayland-tunnel`, `ui*`, сервисы, `proto`, приватность | workstation `/srv/board-from-buildhost/` |
| `couplingd`, `hubd-queue-repl`, `ipa-runtime`, `zenoh-util-freebsd` | dev-vm `/opt/bsdos-src/` |
| `hal/darling-freebsd` | bundle на workstation `/srv/bsdos-archive/darling-freebsd/`; источник — репо `darling` |
| `infra/` (кроме `u-boot`), `docs/`, `mac-companion/`, `freebsd-patches/`, `cluster/`, `cloud-init/`, `certs/`, `tests/`, `specs/` | по-прежнему buildhost `/srv/bsdos` |

Удаления в монорепо не закоммичены; таблицы ниже описывают состояние истории
git (HEAD a8f73f9).

## 1. Вынесено

| Каталог монорепо | Репо в org | Кто источник истины |
|---|---|---|
| `bsdos-core`, `bsdos-pkgd`, `bsdos-run`, `lifecycled`, `jpk-manager`, `jpk-recipes`, `ipa-runtime/machotool`, wlstream | `bzdOS` — публичный **релизный снимок** v0.1.3 (3 коммита, 06-26 + README 08-21) | **монорепо**: `bsdos-core` (07-27) и `lifecycled` (07-23) ушли вперёд, в снимке этого нет |
| `sys-daemon-zig` | `bzdOS/hal/` (был `bsdos-hal`, влит 01.10) | синхронно (монорепо 06-26) |
| `wayland-tunnel` | `WLTunnel` (06-26) | **монорепо** (07-11) |
| `mac-companion/metal-viewer` | `metal-viewer` (06-26) | **монорепо** (07-27) |
| wire-формат стрима (бывш. `wlstream/`) | `WLStream` (07-10) | **репо**: `bsdos-core` тянет его git-зависимостью (`bsdos-core/Cargo.toml:32`, rev 925b8f7); `wayland-tunnel` (Zig) wire-формат по спеке ещё не реализует (по памяти от 06-23, не перепроверено) |
| `matrix-hs/` | `mrgd` (09-30), локально `/opt/mrgd` | **репо**; из монорепо удалён |
| `hal/lima` | `lima-freebsd` (08-22) | **репо** (монорепо 06-23) |
| `hal/darling-freebsd` | `darling` (+ `darlingserver`, `darling-dyld`) | **репо**; ⚠ см. §3 |
| `infra/opencode-freebsd` | `opencode-freebsd` (08-27) | синхронно (README зеркалируется) |
| `hubd/` (2 файла) | `hubd` (09-30) | **репо** |

Не из монорепо, но в той же org: `bzdk` (EL2-гипервизор, микроядро с workstation),
`freebsd-brcmfmac-sdio` (WiFi BPI-M64), `jailrun`, `zenoh` (форк), `SeMa`,
`BareChat` (приватный).

## 2. Не вынесено

**Живой код, менялся после июня:**
- `couplingd` — CRDT + мост hubd↔Matrix
- `hubd-queue-repl` — Zenoh-репликация очередей hubd
- `guest-agent` — агент virtio-console (07-24)
- `zenoh-util-freebsd` (08-20)
- `mac-companion/`: `wayland-client`, `zenoh-link-obfs`, `zenoh-link-patched`,
  `zenoh-link-commons-patched`, `zenoh-link-tls-patched` (кандидаты: патчи → в форк `zenoh`)

**Прототипы, без движения с июня 2026:**
- `proto/` — broker, app, contacts, calendar, clipper, greeter, media
- `ipa-runtime/` (кроме machotool) — UIKit, CoreText, CoreGraphics, Metal,
  libdispatch, mach_stubs, vchroot, sigsys_handler
- UI: `ui-plasma-qml`, `ui`, `ui-backend-rust`
- сервисы: `telemetry-client`, `push-daemon`, `zfs-snapd`, `matrix-voice`
- приватность: `crypto-sleep`, `audio-decoy`, `ghost-radio`, `dopamine-brake`, `pf-adblock`
- GPU: `mali-uio`, `hal/gpu.zig`, `hal/mali_uio.*`, `hal/darling-fbsd-overlay`

**Инфраструктура и доки (по смыслу привязаны к хостам, не отдельные продукты):**
`infra/` (333 файла), `docs/`, `freebsd-patches/`, `cluster/`, `cloud-init/`,
`certs/`, `tests/`, `specs/`, `schema.capnp`.

## 3. Известные проблемы

- **`hal/darling-freebsd` — gitlink без `.gitmodules`.** В индексе это
  сабмодуль (сейчас 7d45407, рабочая копия на 951bcfb + незакоммиченные правки),
  но URL нигде не записан. После клона с remote каталог окажется пустым, и
  восстановить его будет неоткуда. Нужно одно из двух: добавить `.gitmodules` →
  `bzdOS/darling` или убрать gitlink. Блокер этапа 0 `PLAN-host-split.md`.
  *01.10:* каталог вынесен bundle'ом. Первый bundle (`--all`) не взял
  сабмодули — 3 коммита (cocotron, darlingserver, foundation) восстановлены из
  копии на dev-vm и влиты в `pr-arm64`. Gitlink в индексе остался — убрать.
- **Вынесенные компоненты отстают от монорепо** (`WLTunnel`, `metal-viewer`,
  снимок `bzdOS`) — правки шли в монорепо. Перед следующим релизом решить:
  либо репо становится источником, а каталог в монорепо удаляется (как
  `matrix-hs`), либо репо остаётся снимком и это написано в его README.
- **Identity:** 2026-10-01 в `bzdOS`, `bsdos-hal`, `WLTunnel` и `metal-viewer`
  «Alexey Bodrov» переписан на «Andrey Bodrov» (filter-repo + force-push `main`
  и `v0.1.3`). Остальные свои репо org чистые. Монолит не переписывается, чистка
  при выносе — свежим коммитом (плейбук jailrun).

## 4. Распил по компонентам (2026-10-01, вечер)

Источник — git HEAD монорепо, не копии на хостах. Репо подготовлены локально в
`/srv/split/`, **не запушены** (hubd `a hub task`), **не собирались**
(`a hub task`).

| Репо | Что положено | Коммит |
|---|---|---|
| `zenoh-freebsd` (**новый, публичный**) | `zenoh-util-freebsd` + `mac-companion/zenoh-link-{commons,tls}-patched`, `zenoh-link-patched`, `zenoh-link-obfs` | `cc23ff7` |
| `bzdOS` — **репо дистрибутива** | базовые сервисы и модель приложений (`bsdos-core`, `lifecycled`, `bsdos-pkgd`, `jpk-*`, `schema.capnp`) + сборка образа: `kernel/` ← `freebsd-patches/conf`, `infra/scripts` (bsdos-build, bpi-image, kernel, cross-cc, smoke), `infra/{machines.conf,pkgsets,rc.d,etc,etc-bsdOS,config,conf/devfs-rules.conf,u-boot,rust}`. Убраны: vendored `wlstream/`, deploy под конкретные хосты (`deploy-bsdos-myvm.sh`, `build-core.sh`, `hubd_mcp`), прод-IP | `5689441`, `24234d5` |
| `WLTunnel` | `wayland-tunnel` (07-11) | `1741f54` |
| `metal-viewer` | `metal-viewer` (07-27) + `mac-companion/wayland-client`; корень стал workspace | `6dbcd23` |
| `bsdos-hal` | `sys-daemon-zig`; `gpu/` ← `hal/{gpu.zig,build.zig,mali_uio.*}`; `gpu/kmod/` ← `mali-uio/` | влит в `bzdOS/hal/` (01.10, с историей) |
| `ipa-runtime` (**новый**, видимость не решена) | `ipa-runtime/*` + `hal/darling-fbsd-overlay` + `bsdos-run`, `machotool` (из `bzdOS`) | `cafdfc2`, `b727b67` |
| `attic` (**локальный, без remote**) | `proto`, `ui*`, приватность ×5, `telemetry-client`, `push-daemon`, `zfs-snapd`, `matrix-voice`, `cluster`, `couplingd`, `hubd-queue-repl` | `8b9c2a6` |

Не тронуто, потому что в org уже новее: `hal/lima` → `lima-freebsd`.
Остаётся в монорепо (будущий `bsdos-infra`): `infra/` (вкл. `u-boot`), `guest-agent`,
`docs/`, `freebsd-patches/`, `cloud-init/`, `certs/`, `tests/`, `specs/`,
заметки `mac-companion/*.md`.

Хвосты — hubd `a hub task`…`a hub task`, `a hub task` (прод-IP и obfs-вход в публичной истории `bzdOS`), `a hub task` (дефолт `listen_ip` в rc.d): push, сборка, правка `lifecycled` из
`uncommitted.diff`, коммит удалений в монорепо, клоны вместо tar-копий на хостах,
пути `/mnt/bsdos`, CLAUDE.md.
