# SPEC_chimp_release.md — Chimp v0.2 Release Infrastructure

**Synthesized:** 2026-06-15 (architect, claude-host / MiniMax M2.7)
**Status:** Active specification (Chimp v0.2 infrastructure)
**Synthesizes:** 10 legacy `PLAN-*.md` files (deployment, devfs-advanced, rc-services, kqueue-events, kernel-modules, watchdog, build-system, devloop-refactor, freebsd-local-build, device-bringup)

> **Phase target:** Chimp v0.2 needs deployment + devops + kernel + build infrastructure for the first real-hardware (Banana Pi) release. These plans cover the operational layer.

**See also:**
- `docs/v0.2-release-plan.md` — Chimp release plan (uses this infrastructure)
- `docs/specs/SPEC_squirrel_rootfs.md` — build pipeline (Squirrel precedent)
- `docs/specs/SPEC_chimp_jail_networking.md` — VNET jails (depends on this devops)
- `PLAN-jail-prototype.md` — current Squirrel jail model

---

## 0. Stack overview

| Component | Source PLAN | Phase |
|---|---|---|
| **Build system unification** | `PLAN-build-system.md` (22 KB) | Active (Q3) |
| **Dev-loop refactor** | `PLAN-devloop-refactor.md` (15 KB) | Active |
| **rc.d service management** | `PLAN-rc-services.md` (16 KB) | Chimp |
| **kqueue event-driven** | `PLAN-kqueue-events.md` (16 KB) | Woodpecker |
| **Kernel modules** | `PLAN-kernel-modules.md` (7.4 KB) | Active |
| **Hardware watchdog** | `PLAN-watchdog.md` (4 KB) | Chimp |
| **FreeBSD local build** | `PLAN-freebsd-local-build.md` (14 KB) | Active |
| **Per-app devfs advanced** | `PLAN-devfs-advanced.md` (6.1 KB) | Chimp |
| **Device bring-up** | `PLAN-device-bringup.md` (17 KB) | Chimp |
| **Deployment to hardware** | `PLAN-deployment.md` (21 KB) | Chimp |

---

## 1. Build system unification (Q3 2026)

**Source:** `docs/archive/2026-06-15-plans/PLAN-build-system.md` (22 KB, full)

**Goal:** Consolidate 13+ separate Rust projects (broker, app, bsdos-core, etc.) into one workspace. Eliminate dependency duplication, enable incremental build on-host and in-guest in one command.

**Current state (verified 2026-06-06):** 13 separate `make build-X` calls, each pulling its own vendor, fragmented cargo-cache.

**Solution:** Cargo workspace + `build.zig.zon` per Zig package. Single root `Cargo.toml` workspace, single root `build.zig`.

**Phase Q3 2026:** Migration to workspace

---

## 2. Dev-loop refactor (Active)

**Source:** `docs/archive/2026-06-15-plans/PLAN-devloop-refactor.md` (15 KB, full)

**Goal:** Shrink inner loop (edit→build→deploy→run→observe) from ~10-15s to single-digit seconds. One-step debug.

**5 levers (ranked by impact):**
1. **Incremental build** — only changed component rebuilds
2. **9p file sharing** — host↔guest FS without scp (already done)
3. **virtio-console transport** — observable agent (already done)
4. **kqueue-driven** — no polling
5. **sema-check pre-commit** — no format/lint surprises

**Phase 0-2:** Active (uses 9p + virtio-console from base; kqueue partial)

**Verified limits:** 9p до FreeBSD 15, vsock до custom kernel. Both deferred.

---

## 3. rc.d service management (Chimp)

**Source:** `docs/archive/2026-06-15-plans/PLAN-rc-services.md` (16 KB, full)

**Goal:** Standardize daemon lifecycle via FreeBSD rc.d (native service framework).

**Provides:**
- `service <name> start|stop|status|restart`
- Boot sequence ordering via `REQUIRE=` / `BEFORE=`
- Auto-restart on failure (via watchdog or external monitor)
- Logs to `/var/log/<service>.log` (audit trails)

**Current state:** Daemons started ad-hoc via `nohup ... &` in test scripts.

**Phase 2 (Chimp):** All daemons (`bsdos-core`, `bsdos_lifecycled`, `bsdos-hal`, `bsdos_pipelined`) wrapped in rc.d

---

## 4. kqueue event-driven (Woodpecker)

**Source:** `docs/archive/2026-06-15-plans/PLAN-kqueue-events.md` (16 KB, full)

**Goal:** Replace polling threads and sleep-heavy sync with FreeBSD's native `kqueue` multiplexing.

**Benefits:** CPU efficiency (extended C-states), no signal races, unified event API for network I/O, timers, process lifecycle, hardware interrupts.

**Phase 0:** status quo (polling)
**Phase 1-2:** HAL kqueue
**Phase 3 (Woodpecker):** All daemons kqueue-driven

**Already partial:** HAL v2 (per `SPEC_woodpecker_hal.md` §1) has kqueue loop for I2C/SPI/UART

---

## 5. Kernel modules (Active)

**Source:** `docs/archive/2026-06-15-plans/PLAN-kernel-modules.md` (7.4 KB, full)

**Goal:** Custom kernel modules for boot sequence + securelevel lockdown.

**Modules planned:**
- `bsdos_securelevel.ko` — enhanced securelevel (e.g., `securelevel=4` blocks even root from ZFS key reload)
- `bsdos_jail_audit.ko` — jail event audit log
- `bsdos_dpi.ko` — DPI-resistant transport hooks (per `SPEC_chimp_security.md` §7)

**Phase 0 prep:** Module skeleton, build system integration

---

## 6. Hardware watchdog (Chimp)

**Source:** `docs/archive/2026-06-15-plans/PLAN-watchdog.md` (4 KB, full)

**Goal:** Reboot system if it hangs (deadlock, infinite loop, HAL no-response).

**Mechanism:** `/dev/watchdog` character device. Kernel resets if no heartbeat in N sec.

**Config:**
```sh
sysrc watchdogd_enable=YES
sysrc watchdogd_flags="-t 30"  # 30 second heartbeat
```

**Phase 2 (Chimp):** Hardware watchdog on Banana Pi (A64/A523 SoC watchdog)

---

## 7. FreeBSD local build (Active)

**Source:** `docs/archive/2026-06-15-plans/PLAN-freebsd-local-build.md` (14 KB, full)

**Goal:** Own the base OS — build FreeBSD from source locally, keep bsdOS patches as versioned overlay, emit images for dev (amd64) AND device (aarch64) from one tree.

**Why:** vsock, custom devfs/jail options, kernel module hooks, HAL in-kernel — all are patches to FreeBSD. For an OS project, local build is capability, not cost.

**Phase:** Active (since 2026-06-06)

---

## 8. Per-app devfs advanced (Chimp)

**Source:** `docs/archive/2026-06-15-plans/PLAN-devfs-advanced.md` (6.1 KB, full)

**Goal:** Extend devfs ruleset system beyond binary (bpf hidden/shown) to **fine-grained per-app device access control** based on application permissions (audio, camera, GPS, modem, display).

**Per-app rulesets:**
```
appCamera:  ruleset 31   (unhide /dev/video0)
appGPS:     ruleset 100  (unhide /dev/ttyU1, ucom0)
appNFC:     ruleset 110  (unhide /dev/iic0)
appBiometric: ruleset 120 (unhide /dev/spi0)
appTelephony: ruleset 130 (unhide /dev/cuaU0)
appBluetooth: ruleset 140 (unhide /dev/uhid*)
```

**Phase 2 (Chimp):** Per-app devfs from `.jpk` declarations (per `SPEC_woodpecker_mobile.md` §3)

---

## 9. Device bring-up (Chimp)

**Source:** `docs/archive/2026-06-15-plans/PLAN-device-bringup.md` (17 KB, full)

**Target platforms (per 2026-06-15 update — RISC-V DEFERRED):**
- **PinePhone Pro**: Rockchip RK3399, ARM64 (aarch64), 4GB RAM, Mali-T860 GPU, Quectel EG25-G modem — *(факт о реальном Pro; **НЕ наш таргет** — мы целим оригинальный PinePhone A64, см. §13 вопрос 7)*
- ~~BPI-F3: SpacemiT K1, RISC-V~~ — **⛔ DEFERRED 2026-06-15**
- **BPI-M64 / BPI-M2 (Chimp)**: Allwinner H616/H618/A523, aarch64
- **PinePhone (Woodpecker, oBzdOS)**: Allwinner A64, aarch64, 2GB RAM, Mali-400 — **OpenBSD base** (не FreeBSD; драйверы/HAL требуют отдельного аудита)

**Phases:**
- **Phase 1:** Boot & firmware (no display)
- **Phase 2:** Console + network
- **Phase 3:** Display + GPU
- **Phase 4:** Telephony + sensors

**Already started (Squirrel):** QEMU aarch64 boot works

---

## 10. Deployment to hardware (Chimp)

**Source:** `docs/archive/2026-06-15-plans/PLAN-deployment.md` (21 KB, full)

**Path:** image → flash → first boot → software kit → demo

**Phase 0 (Squirrel):** QEMU aarch64 image (per `SPEC_squirrel_rootfs.md`)
**Phase 1 (Chimp):** SD card image for Banana Pi
**Phase 2 (Chimp):** Boot, install, verify
**Phase 3 (Woodpecker):** eMMC + NVMe for PinePhone

---

## 11. Operations checklist (synthesis)

**For Chimp v0.2 release:**
- [ ] All daemons in rc.d
- [ ] Hardware watchdog enabled
- [ ] Per-app devfs rulesets from `.jpk`
- [ ] Build system unified (single workspace)
- [ ] FreeBSD local build pipeline
- [ ] SD card image builder
- [ ] First-boot verification script
- [ ] Banana Pi boots to login prompt
- [ ] bsdos-core starts in rc.d
- [ ] bsdos_lifecycled running
- [ ] mTLS prototype (per `SPEC_zenoh_security.md`)

---

## 12. Source files (preserved for full detail)

```
docs/archive/2026-06-15-plans/
├── PLAN-build-system.md              (22 KB) — §1
├── PLAN-devloop-refactor.md          (15 KB) — §2
├── PLAN-rc-services.md               (16 KB) — §3
├── PLAN-kqueue-events.md             (16 KB) — §4
├── PLAN-kernel-modules.md            (7.4 KB)— §5
├── PLAN-watchdog.md                  (4 KB)  — §6
├── PLAN-freebsd-local-build.md       (14 KB) — §7
├── PLAN-devfs-advanced.md            (6.1 KB)— §8
├── PLAN-device-bringup.md            (17 KB) — §9
└── PLAN-deployment.md                (21 KB) — §10
```

---

## 13. Open questions

1. **Workspace migration timing:** Q3 2026 too aggressive? (Depends on Qwen3.7 quota)
2. **rc.d vs runit:** FreeBSD native is fine for v0.2; revisit for Woodpecker
3. **kqueue vs epoll:** kqueue is BSD-native; do we need epoll shim for Linux dev VMs?
4. **Watchdog on QEMU:** QEMU can simulate watchdog; do we test it in Squirrel?
5. **Custom kernel:** Is `KERNCONF=BSDOS-SQUIRREL` viable, or do we use `GENERIC` + kldload for modules?
6. **BPI-M64 vs BPI-M2:** H616 (newer) or H618/A523 (newer still)? (Sourcing TBD — a hub task)
7. **PinePhone vs PinePhone Pro: РЕШЕНО 2026-06-24** — целевой девайс = **оригинальный PinePhone (Allwinner A64, Mali-400)**, тот же SoC что BPI-M64 (Chimp v0.2), драйверы/HAL переносятся 1:1. Реальный PinePhone **Pro** (RK3399/Mali-T860/EG25-G, см. §9) — это ДРУГОЙ SoC и **НЕ наш таргет** (вдобавок Pine64 сворачивает Pro).

---

**Synthesized:** 2026-06-15, architect (claude-host / MiniMax M2.7).
**Source:** 10 PLAN files (~140 KB), reprocessed into ~10 KB synthesis.
**Replaces:** 10 standalone plans in archive.
