# bsdOS Roadmap → Production

> **Status legend:** ✅ done · 🟡 in progress · ⚠️ partial · ❌ not started · ⛔ deprecated
>
> **Single source of truth.** This file is the canonical status for bsdOS phases.
> `docs/archive/2026-10-01-monorepo/PLAN-bsdos-roadmap.md` (4-quarter view) and `docs/archive/2026-10-01-monorepo/PLAN-bsdos-vision.md` (2026-2029+) are
> ⛔ DEPRECATED as status trackers; keep them only as historical/extended reference.
> See `DOCS_INDEX.md` for the new docs map.
>
> **Roadmap = forward plan (фазы).** For a reality-snapshot inventory — что код
> физически есть прямо сейчас, включая неподключённые спайки и ось
> «компилируется ≠ работает на железе» — see [docs/archive/2026-10-01-monorepo/STATUS.md](docs/archive/2026-10-01-monorepo/STATUS.md).

## Текущее состояние (Phase 0.2 — v0.1 "Squirrel" Release)

**Tag:** ✅ `v0.1.0` released 2026-06-13, `v0.1.1` (damage rect), `v0.1.2` (zenoh-peer test infra)
**Status:** ✅ **v0.1.0/0.1.1/0.1.2 = amd64 QEMU (primary dev loop)** · ⚠️ **v0.1.3 Squirrel = multi-arch (amd64 + aarch64) per user 2026-06-15**

> Per user 2026-06-15 ("арм и амд равнозначный пока"), **Squirrel is multi-arch**:
> - **amd64 QEMU = primary dev loop** (KVM fast, TCG fallback, dev VM $BSDOS_DEV_IP)
> - **aarch64 QEMU = architectural target** (catches alignment/endianness/NEON bugs early, same arch as Chimp/Woodpecker production hardware)
> - Both ship in same release: `bsdos-squirrel-v0.1.3-amd64.img.gz` AND `bsdos-squirrel-v0.1.3-aarch64.img.gz`. No "primary" or "secondary".
> - CI tests both archs. Build pipeline produces both. Acceptance fails if either arch breaks.
> - amd64 is **not a throwaway** — many dev hosts are amd64, and the KVM-accelerated dev loop is essential for fast iteration. Forcing aarch64-only would slow the inner loop unnecessarily.
> - Only the **aarch64** Squirrel pipeline feeds Chimp/Woodpecker; the amd64 pipeline is for Squirrel dev loop only.
> See `docs/specs/SPEC_squirrel_rootfs.md` for the multi-arch build pipeline.

✅ Работает (amd64 QEMU, current v0.1.2):
- FreeBSD 15.1 в QEMU/KVM, virtio-console agent
- Wayland Protocol Forwarding v1 (POOL_DATA 0x03 + SURFACE_COMMIT 0x04)
- LZ4 сжатие POOL_DATA (x10-50 для терминала)
- Pool hash caching — не шлёт одинаковый буфер дважды
- Zenoh TLS на $BSDOS_DEV_IP:7447, token auth
- pf firewall, rc.d autostart
- bsdos/health heartbeat, bsdos/logs/* remote logging
- Input forwarding: Mac NSEvent → Zenoh → bsdos-core → tunnel → wl_keyboard
- FreeBSD jails: appBrowser(Firefox+Chromium), appTerminal(foot), appMatrix
- demo-wayland: полный pipeline (cage + foot + tunnel + bsdos-core + metal-viewer)
- Mac viewer: handle_pool_data + handle_surface_commit → MTLTexture → render
- E2E input test: `make test-input-e2e`
- P0 test coverage: 30 (bsdos-core) + 18 (metal-viewer) + 14 (wayland-tunnel) + sensors
- Stream manager monitor_loop (commit 1a95431): per-stream health check + auto-restart
- Topic migration to `bsdos/app/{app_id}/*` (commit 1a95431)
- Legacy scripts removed (3 deleted)
- Semmarkup: 97/97 source files with full contracts (commit 23f14c9)
- Damage rect: implemented (commit 276f864) — protocol.rs, Compositor damage tracking, Metal partial upload, 27 tests total
- **Runtime stream_manager: Cap'n Proto schema (stream.capnp) + state persistence + Zenoh control plane** (commits 2d7c74e, 8feb9be, bf89f5e) — proper reaping via Child handles, control plane for stream lifecycle
- **Tier 1 extractions published 2026-06-13** by orchestrator: `github.com/bzdOS/sema` v1.0.0 (methodology) + `github.com/bzdOS/WLStream` v1.0.0 (full Rust crate, 43 tests + 2 doc-tests, clippy + rustfmt clean). bsdOS now depends on these externally; cleanup tracked in internal task.
- **Doc refactor 2026-06-15**: 122 unreferenced PLAN-*.md moved to `docs/archive/2026-06-15-plans/`. Reprocess pass 1: 5 promoted to `docs/specs/SPEC_*.md` (zenoh_keyspace, zenoh_security, chimp_jail_networking, woodpecker_thermal, woodpecker_power). **Reprocess pass 2: 73 PLAN files synthesized into 8 new `docs/specs/SPEC_*.md`** (woodpecker_mobile 10 files, woodpecker_hal 15 files, woodpecker_apps 9 files, woodpecker_matrix 5 files, chimp_security 7 files, chimp_zenoh 6 files, woodpecker_vision 11 files, chimp_release 10 files). **13 truly obsoleted files deleted** (work done in code: runtime-stream-manager, script-cleanup, wayland-pipeline/tunnel-impl/eof-*/mac-metal-renderer/mac-display-stream extracted to github.com/bzdOS/WLStream; superseded by spec: phantom-browser/minimal-browser → SPEC_2stream, cross-compilation → SPEC_squirrel_rootfs, zfs-jail-packages → SPEC_jpk_descriptor_v1, implementation-v0.1 DEPRECATED). **31 PLAN files retained** as reference designs (niche, individual). **Net: 13 SPECs from 117 originals synthesized; ⛔ 0 net loss of design rationale.**

📋 Outstanding (v0.1.x "Squirrel", aarch64 QEMU build):
- **Squirrel ARM64 QEMU rootfs build pipeline** — spec drafted (`docs/specs/SPEC_squirrel_rootfs.md` 2026-06-15). Implementation: infra/scripts/bsdos-build.sh (runner) + cross-compile (system) + mkimg (runner) + QEMU smoke (system) + CI (sre). **~6 weeks total**, see §11 of spec.
- **2-stream demo (browser + terminal)** — moved from v0.2 "Chimp" / Phase 0.3 to v0.1.x Squirrel per user 2026-06-15. Spec drafted (`docs/specs/SPEC_2stream_squirrel.md` 2026-06-15). Infrastructure already in v0.1.0 (HashMap<String, StreamInstance>, BSDOS_AUTOSTREAM, per-stream monitor_loop, per-app_id topics, Mac multi-NSWindow). Gap: E2E test `make test-2stream-e2e` (runner, 2d) + `make demo-2stream` (runner, 1d) + cage+firefox aarch64 cross (system, 1 wk) + Zenoh routing verify (system, 1-2 d) + 2-window layout (frontend, 1d) + CI gate (sre, 1d). **~3 weeks** after rootfs build lands.
- bsdos_lifecycled Rust daemon (SIGSTOP/SIGCONT + ZSTD memory compression) — design in `docs/archive/2026-10-01-monorepo/PLAN-lifecycle-v2.md`, target Squirrel image
- Phantom browser .jpk recipe + preinstall — target Squirrel image
- bsdOS cleanup: `git rm` the moved-out files — **internal task, DONE (2026-06-15)**
- Damage rect bench verification (`make bench-wayland-mac-cpu`): confirm <5% Mac CPU on idle terminal — **F5 in `docs/archive/2026-10-01-monorepo/v0.2-release-plan.md`**
- ~~2-stream demo (Phase 0.3)~~ — **moved to v0.1.x Squirrel per user 2026-06-15**, see above
- mTLS prototype (v0.2 F2)
- 60% coverage on critical paths
- streams.conf declarative autostart — **closed as task #21 by orchestrator**
- Q3 streams — see `docs/archive/2026-10-01-monorepo/q3-architecture.md` (was `docs/followup-plan-q3.md`, split 44f48a1)

---

## Phase 0.3 — Второй поток (Browser) 🟡 current

**Цель:** два окна на Mac — терминал и браузер.

- [ ] make vm-start-browser-stream (tunnel-2 + core-2 для Chromium)
- [ ] bsdos/app/appBrowser/stream работает (топик мигрирован, нужна интеграция)
- [ ] Mac viewer: выбор потока через аргумент --stream KEY
- [ ] SESSION_RESET при переключении приложений

**Готово когда:** открываешь два окна viewer с разными --stream, видишь разные приложения.

---

## IPA Runtime — параллельный трек 🔄 (2026-06-23)

**Цель:** запускать iOS/macOS приложения на FreeBSD. Целевое приложение: iSH (GitHub releases, незашифрованный IPA).  
**Подход:** on-demand — берём конкретный IPA, смотрим что падает, реализуем только это.  
**Детали:** `docs/archive/2026-10-01-monorepo/PLAN-ipa-runtime.md`

| Milestone | Статус |
|---|---|
| M0: darling-freebsd x86-64 статик + SIGSYS | ✅ |
| M0: aarch64 SIGSYS handler | ✅ (2026-06-23) |
| M0: Mach трапы + mach_msg stack args | ✅ (2026-06-23) |
| M0: dyld реальный запуск (PREFIX готов) | 🔄 тестируется |
| M1: libobjc2 objc-hello на VM | 🔄 тестируется |
| M2: CoreGraphics (libCoreGraphics.a, draw_rect) | ✅ собирается на FreeBSD 15.1 |
| M3: Metal stub (llvmpipe/EGL, triangle test) | ✅ собирается на FreeBSD 15.1 |
| M4: UIKit базовый (UIView/UILabel/UIButton/UIViewController) | ✅ |
| M4: Auto Layout + UITableView | 🔄 добавляется |
| M5: iSH IPA запускается | ⬜ |

**darling-freebsd OSS:** branch `pr-arm64` готов к публикации на github.com/bzdOS/darling-freebsd.

---

## Phase 0.4 — Matrix / Комms

**Цель:** базовая коммуникация встроена.

- [ ] Conduit Matrix в appMatrix jail (pkg: conduit v0.10.12)
- [ ] Matrix клиент в appTerminal (Element или nheko из pkg)
- [ ] Настроить server_name, federation=false для локальной сети
- [ ] Wayland stream Matrix клиента через tunnel

**Готово когда:** можно написать сообщение через Matrix и получить его на другом устройстве.

---

## Chimp v0.2 — Banana Pi BPI-M64 (first real hardware) 📋 software-ready, ждёт железо T-36

**Цель:** bsdOS загружается на **реальной плате** Banana Pi BPI-M64 (Allwinner A64,
aarch64) — headless first boot, доказывающий «board + transport».

> **Полный чеклист готовности:** [`docs/archive/2026-10-01-monorepo/CHIMP-READINESS.md`](docs/archive/2026-10-01-monorepo/CHIMP-READINESS.md).
> **Boot chain:** [`BPI-M64-BOOT.md`](https://github.com/bzdOS/bzdOS/blob/main/docs/BPI-M64-BOOT.md). **Release plan:**
> `docs/specs/SPEC_chimp_release.md` + `docs/archive/2026-10-01-monorepo/v0.2-release-plan.md`.

### Software-инфраструктура к Chimp — ГОТОВА ✅ (компилируется в dev-loop)
- ✅ **Cross-compile** aarch64: `make cross-squirrel-aarch64` — Rust (`bsdos-core` + `bsdos-lifecycled`) + Zig (`bsdos-hal` + `wayland-tunnel` + `bsdos-agent`)
- ✅ **Machine abstraction**: `infra/machines.conf` → `bpi-m64` (arch=aarch64, kernconf=GENERIC, platform=bpi_m64, pkgset=bpi-headless)
- ✅ **pkgset** `infra/pkgsets/bpi-headless.txt` — минимальный headless first-boot набор (zenoh + liblz4 + pcre2; GUI исключён намеренно)
- ✅ **HAL platform-флаги**: `hal/src/platform.zig` (`-Dplatform=bpi_m64`) + board-константы `bpi_m64.zig` (A64, 4 ядра, iic0..2, awg0, dsp0); phone-only caps comptime-false
- ✅ **rc.d autostart**: headless-набор `bsdos_core` + `bsdos_lifecycled` (скрипты есть; GUI-pipeline отключён)
- ✅ **SD-image recipe** `infra/scripts/bpi-image.sh` — sunxi U-Boot@8KiB + GPT + UFS layout (написан, см. ниже)

### Критический путь = ЖЕЛЕЗО 🔒 (плата, internal task, дедлайн 2026-06-27)
Всё ниже **UNTESTED** — кода/рецепт есть, но валидация невозможна без платы:
- 🔒 **U-Boot/SPL boot**: `bpi-image.sh` собирает образ, но DRAM init / BL31 / UART / root-device — все ASSUMPTION (см. BPI-M64-BOOT §6 open questions, #1 риск = DRAM init у pine64-lts U-Boot vs BPI-M64)
- 🔒 **Image-step gap**: `squirrel-build.sh` Stage 6 знает только amd64-BIOS и aarch64-UEFI; для bpi-m64 нужен отдельный прогон `bpi-image.sh` против staged rootfs (Stages 1-5 работают через `machine_resolve`). Wiring Stage 6 → bpi-image.sh = маленький follow-up.
- 🔒 **First-boot acceptance**: GENERIC ядро + DTB `sun50i-a64-bananapi-m64` из base → login prompt → `hw.ncpu==4` → bsdos-core/HAL/lifecycled поднимаются над `awg0`

**Разблокируется по приезду платы:** реальная прошивка SD → UART boot (M1-M6 в BPI-M64-BOOT §7) → first-boot acceptance bsdOS-сервисов. Триаж: hang до M1 → mainline `bananapi_m64_defconfig`; hang M3-M5 → layout/DTB/root-device.

**Готово когда:** плата грузится с SD, доходит до login, `bsdos-core` отвечает по Zenoh с реального IP, `bsdos-hal` отдаёт реальные A64 sysctl-метрики.

**НЕ в scope Chimp bring-up:** GUI/weston (Chimp phase 2), Lima/Mali (Woodpecker stretch), modem/SIM/sensors (нет на плате), custom KERNCONF (phase-2 оптимизация). См. CHIMP-READINESS §6.

---

## Phase 1 — Real Hardware (PinePhone / Woodpecker)

> **Note:** первая реальная плата — **Chimp / BPI-M64** (см. секцию выше). Этот
> Phase 1 = мобильный трек **Woodpecker** (oBzdOS, PinePhone, Allwinner A64 + Mali-400).
> **База ОС: OpenBSD** (не FreeBSD — oBzdOS это отдельный проект). HAL/драйверы для
> OpenBSD on PinePhone требуют отдельной разработки. **BPI-F3 / SpacemiT K1 —
> ⛔ DEFERRED 2026-06-15** (`docs/archive/2026-10-01-monorepo/PLAN-bpi-f3-bringup.md`).

**Цель:** bsdOS загружается на реальном железе.

### 1.1 Boot
- [ ] OpenBSD arm64 на SD карте (PinePhone, A64) — oBzdOS base
- [ ] U-Boot для PinePhone (A64; BPI-F3 / SpacemiT K1 — ⛔ deferred)
- [ ] UART debug cable подключён, serial console работает
- [ ] SSH по USB networking (CDC Ethernet)

### 1.2 Display
- [ ] weston --backend=fbdev-backend.so (без DRM/KMS, без GPU)
- [ ] wayland-tunnel на реальном железе
- [ ] bsdos-core слушает на реальном IP устройства

### 1.3 Network
- [ ] vtnet → реальный WiFi/LTE
- [ ] pf rules для устройства
- [ ] Zenoh TLS на реальном IP

**Готово когда:** телефон загружается, Wayland stream идёт на Mac.

---

## Phase 2 — HAL + Telephony

**Цель:** устройство работает как телефон.

- [ ] HAL: battery (hw.acpi.battery), CPU (kern.cp_time), память (vm.stats)
- [ ] Modem: AT команды через /dev/cuaU0 (Quectel EG25-G на PinePhone)
- [ ] SMS/Calls: bsdos/telephony/call_state, bsdos/telephony/sms
- [ ] Zenoh mesh между несколькими устройствами (peer mode)
- [ ] Ghost Radio: экстренные сообщения при критическом заряде

---

## Phase 3 — Production Security

**Цель:** можно использовать в реальной жизни.

- [ ] mTLS (mutual TLS) вместо usrpwd для Zenoh
- [ ] Token expiry (24h по умолчанию, cron ротация уже есть)
- [ ] Audit log: все Zenoh publishes логируются с timestamp
- [ ] Jail secureflags: noexec, nosuid для appBrowser
- [ ] ZFS encryption для data partition
- [ ] Remote wipe через Zenoh команду

---

## Phase 4 — PRaaS Product

**Цель:** продукт который можно продать.

- [ ] bsd-cli: `bsd deploy app.jpk` — деплой приложения в jail
- [ ] App store (.jpk формат уже есть: bsdos-pkgd)
- [ ] Billing API: учёт CPU/memory времени по jail
- [ ] Multi-tenant: несколько пользователей, изолированные Zenoh keyspaces
- [ ] Web dashboard: React/Vue, Zenoh WebSocket bridge

---

## Критический путь

```
Сейчас → 0.2 (v0.1.0 tag) → 0.3 (browser stream) → 0.4 (Matrix) →
Chimp v0.2 (BPI-M64 first boot — software ready, ждёт железо T-36) →
1.1 (Woodpecker real hardware boot) → 1.2 (display on device) → 2 (telephony) →
3 (security hardening) → 4 (PRaaS product)
```

Самое важное прямо сейчас: **закрыть v0.1 DOF** (damage rect, contracts batch 2, legacy scripts). См. `docs/archive/2026-10-01-monorepo/PLAN-damage-rect-v0.1.md` и `docs/followup-plan-q3.md`.

**Chimp gate:** вся software-инфраструктура к BPI-M64 готова (cross-compile, machines.conf, bpi-headless pkgset, bpi-image.sh, HAL platform-флаги, rc.d). Критический путь теперь — **приезд платы (internal task, 2026-06-27)**: реальная прошивка SD + UART boot + first-boot acceptance. См. [`docs/archive/2026-10-01-monorepo/CHIMP-READINESS.md`](docs/archive/2026-10-01-monorepo/CHIMP-READINESS.md).

## Release codenames (animal-themed, BSD-style)

bsdOS releases follow an **animal-progression naming scheme** (similar to
Debian's Buzz→Rex→Bo→...→Bookworm or Ubuntu's Warty→Hoary→...→Yakkety Yak,
but with each animal chosen to evoke the release's role). Codenames are
**semantic, not hardware-bound** — the animal tells you what the release
*does*, not what it *runs on*. Each release ALSO has a hardware-target
column so the role/animal pair is unambiguous.

| Release | Codename (animal) | Russian | Target hardware | Role | Status |
|---------|-------------------|---------|-----------------|------|--------|
| v0.1.x | **Squirrel** (sQuirrel) | Белка | QEMU/KVM dev VM (amd64) | Sandbox, fast iteration, prototype | ✅ Released (v0.1.0/0.1.1/0.1.2) |
| v0.2 | **Chimp** | Шимпанзе | Banana Pi BPI-M64 (Allwinner A64, aarch64) | First real hardware; first "tool-user" — Allwinner HAL, headless first boot (Lima/GLES = Woodpecker stretch) | 📋 **software-ready, ждёт железо T-36** (see [docs/archive/2026-10-01-monorepo/CHIMP-READINESS.md](docs/archive/2026-10-01-monorepo/CHIMP-READINESS.md)) |
| v0.3 | **Woodpecker** | Дятел | PinePhone (Allwinner A64 + Mali-400) | **oBzdOS** (OpenBSD-based): paranoid mobile — tickless C-states, isolated modem for LTE, DePIN micropayments, crypto-defenses | 📋 Stretch (Q3 W7, post-v0.2) |

**Rationale for the ladder (small → tool-using → paranoid):**
- **Squirrel** = small, fast, cautious. Perfect for the dev/prototype stage.
- **Chimp** = primate, first tool-user. Perfect for first real hardware where
  the project learns to use Allwinner-specific tools (HAL, Lima, NEON).
- **Woodpecker** = persistent, precise, drilling through defenses. Perfect for
  the oBzdOS mobile stage (OpenBSD base) where the project has to defend against
  physical attack (lost device, hostile networks) and stand alone (battery, modem).

**Internal marketing codename** (separate track): the v0.1.0
release was tagged "Beastie Awakens" (per bsdOS mascot tradition).
This lives in `docs/archive/2026-10-01-monorepo/RELEASE-NOTES-v0.1.0.md` and is independent of the
animal scheme.
