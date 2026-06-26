# Chimp (v0.2) Readiness — Banana Pi BPI-M64

> **One-line status:** software infrastructure for Chimp is **ready**; the critical
> path is now **hardware**. The board (hubd **T-36**, deadline **2026-06-27**) gates
> every claim marked 🔒 below — nothing on real silicon has been validated yet.
>
> **Date:** 2026-06-24 · **Codename:** Chimp (v0.2, first real hardware) ·
> **Target:** Banana Pi BPI-M64 (Allwinner **A64**, 4× Cortex-A53, aarch64, FreeBSD 15.1)

## Status legend

| Mark | Meaning |
|---|---|
| ✅ | Done and verified (compiles / runs in the dev loop) |
| 🔄 | In progress / partial |
| ⬜ | Not started |
| 🔒 | **Hardware-blocked** — code/recipe exists but cannot be validated until the board arrives (T-36) |
| ⛔ | Out of scope for Chimp (deferred to a later codename) |

---

## 1. Cross-compile toolchain

| Item | Status | Notes |
|---|---|---|
| aarch64 Rust cross (`aarch64-unknown-freebsd`) | ✅ | `make cross-squirrel-aarch64` — nightly + `-Z build-std=std,panic_abort`, clang+lld cross-linker via `infra/scripts/mk-cross-cc.sh` |
| aarch64 Zig cross (`-Dtarget=aarch64-freebsd`) | ✅ | HAL (`bsdos-hal`) + `wayland-tunnel` + `bsdos-agent` build with `-Dsysroot`. **Fix 2026-06-25 (commit 048d0ca):** added `--libc zig-bsdos-aarch64-libc.txt` + `ZIG_TARGET=aarch64-freebsd.15.1` (versioned) — without these, Zig silently cross-compiles for wrong ABI. All 9 aarch64 binaries now confirmed good. |
| All Chimp crates build under one target | ✅ | `bsdos-core` + `bsdos-lifecycled` (Rust), `bsdos-hal` + `wayland-tunnel` + `bsdos-agent` (Zig) → `artefacts/squirrel/aarch64/bin/`. Test suite (Linux host + FreeBSD VM dev-vm): **0 failures** as of 2026-06-25. F3 coverage: **62.06%** (target ≥60%) as of 2026-06-25. Squirrel aarch64 image built: **`bsdos-squirrel-v0.1.3-aarch64.img.gz` (362 MB)** — all 7 binaries staged, tag `v0.1.3`. |
| Platform flag wired through cross build | ✅ | `BSDOS_PLATFORM=bpi_m64` (Rust `build.rs` → rustc-cfg) and `-Dplatform=bpi_m64` (Zig `build_options`) — see §4 |
| Zig 0.15.2 migration | 🔄 | HAL builds; accelerometer / magnetometer / audio / ghost-radio / watchdog threads commented out pending migration (QEMU-irrelevant, phone-relevant — see §4) |

**Note:** the aarch64 cross output is the same artifact set used by the Squirrel
aarch64 QEMU target — the BPI-M64 build differs only in the **platform flag**
(`bpi_m64`) and the **image step** (§2, §3), not in the compilers or crates.

---

## 2. Build pipeline (machine abstraction)

| Item | Status | Notes |
|---|---|---|
| `infra/machines.conf` → `bpi-m64` row | ✅ | `arch=aarch64`, `kernconf=GENERIC`, `platform=bpi_m64`, `pkgset=bpi-headless` |
| `infra/pkgsets/bpi-headless.txt` | ✅ | Minimal first-boot set: `zenoh`, `liblz4`, `pcre2`. GUI deliberately excluded (headless first boot) |
| `squirrel-build.sh bpi-m64` Stages 1-5 | ✅ | base fetch → pkg install → cross build → config stage → slim/verify, all driven by `machine_resolve bpi-m64` |
| `squirrel-build.sh` Stage 6 (image) for bpi-m64 | 🔒 ⚠️ | **GAP:** the orchestrator's Stage 6 only knows amd64 (BIOS/`gptboot`) and aarch64-UEFI (`loader.efi` ESP). The BPI-M64 needs the **separate sunxi raw-SPL recipe** in `infra/scripts/bpi-image.sh` (see §3), run against `squirrel-build.sh`'s staged `$WORK/rootfs`. Wiring Stage 6 to dispatch to `bpi-image.sh` for `bpi-m64` is a small follow-up; today it is a manual two-step. |
| `infra/scripts/bpi-image.sh` (SD image recipe) | 🔒 | U-Boot@8KiB + GPT + UFS root + swap; raw `dd` of `u-boot-sunxi-with-spl.bin`. **UNTESTED — needs the board.** |

---

## 3. Boot chain

Full chain: `BROM → SPL(@8 KiB) → U-Boot → loader.efi/ubldr → FreeBSD aarch64 kernel`.
Detailed analysis + per-milestone validation in [`docs/BPI-M64-BOOT.md`](BPI-M64-BOOT.md).

| Item | Status | Notes |
|---|---|---|
| SD-card layout (U-Boot raw @ 8 KiB, GPT after reserve gap) | 🔒 | `bpi-image.sh` reserves an 8 MiB `freebsd-boot` gap, then `dd`s the SPL+U-Boot blob into the BROM-mandated 8 KiB offset. **ASSUMPTION** that mkimg leaves the reserve partition zeroed — verify post-build with `gpart show -p`. |
| U-Boot source | 🔒 | Defaults to FreeBSD port `sysutils/u-boot-pine64-lts` (closest in-tree A64 build). **#1 risk:** DRAM/PHY/regulator wiring may differ from BPI-M64 → fallback is mainline `bananapi_m64_defconfig` via `UBOOT_BIN=`. |
| Kernel = stock `GENERIC` arm64 (not custom KERNCONF) | ✅ (decision) / 🔒 (boot) | Decision locked in `machines.conf` and BPI-M64-BOOT §3: GENERIC isolates the layout variable. Carries all Allwinner drivers (`aw_mmc`, `aw_gpio`, `aw_ccu`, `uart`, `axp8xx`). A slim Chimp KERNCONF is a phase-2 optimization, NOT a bring-up requirement. |
| DTB = `sun50i-a64-bananapi-m64.dtb` from FreeBSD base | 🔒 | No custom DTS needed. `bpi-image.sh` writes `fdt_name=/boot/dtb/allwinner/...` into the loader.conf fragment. **TODO(hardware):** confirm the DTB ships in 15.1 base arm64. |
| Serial console (UART0, 115200 8N1) | 🔒 | `console=comconsole`, `comconsole_speed=115200`. **TODO(hardware):** confirm A64 debug-UART device name. |
| Root device `/dev/mmcsd0p2` | 🔒 | Assumed SD via `aw_mmc`. May enumerate differently (USB reader / eMMC). |
| SMP / PSCI via ATF (BL31) | 🔒 | **ASSUMPTION:** the Pine64-LTS port bundles BL31 into the FIT image. Verify `hw.ncpu == 4`. |

---

## 4. HAL (sys-daemon-zig)

| Item | Status | Notes |
|---|---|---|
| Comptime platform flags resolve `bpi_m64` | ✅ | `platform.zig` — `-Dplatform=bpi_m64` → `Platform.bpi_m64`; dead phone-only branches eliminated at compile time |
| BPI-M64 board constants | ✅ | `bpi_m64.zig` — SoC `Allwinner A64`, 4 cores, `i2c_buses` (`/dev/iic0..2`), `gpio0`, eth `awg0`, audio `/dev/dsp0` |
| `has_i2c` true on BPI (A64 TWI) | ✅ | `i2c_sensor_bus = /dev/iic0`; `has_audio`/`has_backlight` also true on BPI |
| Phone-only caps (`has_modem`/`has_sim`/`has_sms`/`has_gps`/sensors/`has_ghost_radio`/`has_predictive_touch`) | ⛔ (false on BPI) | Comptime-false for `bpi_m64` — these are Woodpecker features; the M64 has none of that hardware. Code paths are eliminated, not stubbed-at-runtime. |
| `cpu_stats` / battery / memory / uptime / hostname | ✅ | via `sysctl` (`kern.cp_time`, `vm.stats`, `kern.boottime`, `hw.acpi.*`) — arch-agnostic, work on A64 |
| `telemetry` / `watchdog` | 🔄 | Modules present; `watchdog` text commands disabled pending Zig 0.15.2 migration (`processTextCmd` TODO) |
| HAL command socket `/var/run/bsdos-hal.sock` (text protocol) | ✅ | tickless `accept()` loop; `hal_version` advertises implemented features |
| HAL runs on the board | 🔒 | Cross-compiles for aarch64; never executed on A64 silicon yet. `sysctl` reads (battery/cpu) unverified against the AXP803 PMIC nodes. |

---

## 5. rc.d / init (autostart)

The headless first-boot service set (the only services Chimp needs to prove the
board + transport):

| Service (`infra/rc.d/`) | Role on Chimp | Status |
|---|---|---|
| `bsdos_mount` | mount 9p share (dev only — not on real SD boot) | ✅ (dev) / n/a on board |
| `bsdos_core` | Wayland stream manager + Zenoh node | ✅ (script) / 🔒 (on board) |
| `bsdos_lifecycled` | jail FREEZE/THAW lifecycle daemon | ✅ (script) / 🔒 (on board) |
| `bsdos_agent` | guest agent (virtio-console — dev transport) | ✅ (dev) / n/a on board |
| `bsdos_display`, `bsdos_cage*`, `bsdos_tunnel*`, `bsdos_firefox` | GUI/stream pipeline | ⛔ phase-2 Chimp (see §6) |

**For Chimp first boot the `bpi-headless` image is intentionally headless:** enable
`bsdos_core` + `bsdos_lifecycled` (and `bsdos_agent` only if a console transport is
wired). The display/compositor stack stays disabled. **TODO(hardware):** confirm the
rc.d scripts and `rc.conf` knobs are staged into the `bpi-headless` rootfs by the
config stage and that `bsdos_core` comes up over the board's real network
(`awg0`) — neither is validated without the board.

---

## 6. Explicitly NOT in scope for Chimp bring-up

| Excluded | Why | Lands in |
|---|---|---|
| GUI / weston / cage / wayland-tunnel pipeline | First boot is headless on purpose — prove board + Zenoh transport first | Chimp **phase 2** (after first boot) |
| Lima / Mali GLES acceleration | Major kernel work; not needed to reach a login prompt or stream headless | Woodpecker **stretch** (oBzdOS/OpenBSD — needs separate OpenBSD Lima/weston audit) |
| Modem / SIM / SMS / GPS / sensors / haptic / ghost-radio | The BPI-M64 has none of this hardware (`has_*` comptime-false) | Woodpecker (PinePhone, oBzdOS) |
| Custom slim KERNCONF | GENERIC isolates the layout variable for bring-up | Chimp phase 2 (optimization) |
| 2-stream demo (browser + terminal) | Moved to Squirrel (v0.1.x); depends on the GUI pipeline | Squirrel / Chimp phase 2 |

---

## 7. Hardware-gated checklist — run when the board arrives (T-36, due 2026-06-27)

This is the acceptance gate. The authoritative, milestone-by-milestone version is
[`docs/BPI-M64-BOOT.md` §7 (Validation checklist)](BPI-M64-BOOT.md#7-validation-checklist-run-when-the-board-arrives--hubd-36-due-2026-06-27).
Summary:

**Prep (on FreeBSD build host / dev-vm):**
- [ ] `pkg install u-boot-pine64-lts` (or build mainline `bananapi_m64_defconfig`); confirm `u-boot-sunxi-with-spl.bin` path.
- [ ] Stage `loader.conf` + `fstab` fragments (printed by `bpi-image.sh`) **and** the headless rc.d set + `rc.conf` knobs into the rootfs **before** the image step.
- [ ] `ls <rootfs>/boot/dtb/allwinner/ | grep bananapi` — confirm DTB exists in base.
- [ ] Build: `squirrel-build.sh bpi-m64` (Stages 1-5) → then `bpi-image.sh <rootfs> bsdos-chimp-bpi-m64.img` (Stage 6 substitute, §2 gap).
- [ ] `gpart show -p` (via `md`) — confirm p1 reserve / p2 ufs / p3 swap, GPT intact post-`dd`.

**Flash + boot (hardware):**
- [ ] Flash SD: `dd if=bsdos-chimp-bpi-m64.img of=/dev/daX bs=1m conv=sync`.
- [ ] Wire a **3.3V** USB-UART to the GPIO debug header (never 5V). Open at 115200 8N1.
- [ ] **M1:** SPL/U-Boot banner on UART (proves layout + DRAM init).
- [ ] **M2:** U-Boot prompt (U-Boot proper runs).
- [ ] **M3:** U-Boot chainloads `loader.efi`, loader menu appears.
- [ ] **M4:** kernel boots with BPI-M64 DTB; `dmesg` shows `aw_mmc`, 4 CPUs, AXP803.
- [ ] **M5:** mounts `/dev/mmcsd0p2`, reaches login / rc prompt.
- [ ] **M6:** `sysctl hw.ncpu == 4` (SMP via BL31/PSCI); network up if GMAC wired.

**bsdOS acceptance (after a clean boot):**
- [ ] `bsdos-hal` starts; `hal_version` over `/var/run/bsdos-hal.sock` returns features; `get_cpu_usage` / `get_memory` reflect real A64 sysctls.
- [ ] `bsdos_core` comes up over `awg0`; Zenoh node reachable from dev-vm/myvm.
- [ ] `bsdos_lifecycled` socket present; FREEZE/THAW on a test jail works.

**Triage hints:** hang before M1 → wrong U-Boot/DRAM init → mainline `bananapi_m64_defconfig`.
Hang M3–M5 → layout/DTB/root-device → revisit BPI-M64-BOOT §4 / §6.

---

*Related:* [`docs/BPI-M64-BOOT.md`](BPI-M64-BOOT.md) (boot chain + validation),
`infra/scripts/bpi-image.sh` (SD image recipe), `infra/machines.conf` (machine table),
`infra/pkgsets/bpi-headless.txt` (first-boot pkg set),
`sys-daemon-zig/src/platform.zig` + `bpi_m64.zig` (HAL platform flags + board constants),
`docs/specs/SPEC_chimp_release.md` (release plan), `docs/v0.2-release-plan.md`,
[`ROADMAP.md`](../ROADMAP.md) (Chimp v0.2 section), [`PLAN-gpu-bringup.md`](../PLAN-gpu-bringup.md) (display phasing).
