# BPI-M64 Boot Chain — U-Boot + SD image layout (UNTESTED)

> **STATUS: UNTESTED.** The entire layout below is **theory until a physical
> Banana Pi M64 validates it** (a hub task, deadline 2026-06-27). Every claim that
> hasn't been checked on hardware is tagged **ASSUMPTION** or **TODO(hardware)**.
> Recipe: [`infra/scripts/bpi-image.sh`](../infra/scripts/bpi-image.sh).
> Date drafted: 2026-06-24. Codename: **Chimp** (v0.2, first real hardware).

This is the **riskiest** part of Chimp bring-up. QEMU (Squirrel) boots via UEFI
firmware (OVMF/edk2). The Banana Pi M64 (Allwinner **A64** SoC) has **no UEFI
firmware on the board** — it boots through Allwinner's mask-ROM (BROM) and a
raw SPL at a fixed byte offset. That makes the SD-card layout fundamentally
different from the amd64/aarch64 QEMU images, and **it cannot be tested without
the board** (the BROM and DRAM controller are not modelled by QEMU's `virt`).

---

## 1. Full boot chain: BROM → SPL → U-Boot → ubldr → kernel

```
[ Power on ]
     │
     ▼
[ BROM — Allwinner A64 mask ROM (on-die, immutable) ]
     • Probes boot media in fixed order (SD card first if present).
     • Reads a small header at a FIXED byte offset 8 KiB (sector 16 @ 512B)
       looking for the eGON/sunxi SPL magic.
     • Loads the SPL into SRAM and jumps to it.
     │
     ▼
[ SPL — secondary program loader (front of u-boot-sunxi-with-spl.bin) ]
     • Initialises DRAM (the board-specific DRAM timing lives HERE — this is
       why the U-Boot build must match the board's RAM).      ← #1 RISK
     • Loads the full U-Boot proper into DRAM, jumps to it.
     │
     ▼
[ U-Boot proper ]
     • Brings up MMC/SD, console UART, env.
     • Runs its distro-boot / EFI sequence: provides an EFI environment and
       chainloads an EFI payload from the boot partition.
     │
     ▼
[ ubldr.efi / loader.efi — FreeBSD EFI loader ]
     • Loaded by U-Boot's EFI support (U-Boot acts as the "firmware").
     • Reads /boot/loader.conf, picks the DTB, loads the kernel + modules.
     • ASSUMPTION: FreeBSD's arm64 EFI loader is happy under U-Boot's EFI impl
       (this is the documented FreeBSD-on-sunxi path, but UNVERIFIED for BPI-M64).
     │
     ▼
[ FreeBSD aarch64 kernel (GENERIC for bring-up) ]
     • DTB = sun50i-a64-bananapi-m64.dtb (from base — see §4).
     • Mounts root from /dev/mmcsd0p2 (UFS), runs /sbin/init → rc(8).
```

**Key insight:** the SPL+U-Boot blob is **raw data at a fixed byte offset**, NOT
a file in a partition and NOT pointed to by the GPT. The BROM does not parse the
partition table at all — it reads offset 8 KiB directly. The GPT and all
FreeBSD partitions must therefore live **after** the U-Boot region.

---

## 2. Why the layout differs from UEFI (QEMU) — comparison

| Aspect | QEMU amd64 (Squirrel) | QEMU aarch64 (Squirrel) | **BPI-M64 (Chimp)** |
|---|---|---|---|
| Firmware | SeaBIOS (BIOS/CSM) | OVMF / edk2 (UEFI) | **Allwinner BROM (mask ROM)** |
| First-stage loader | `pmbr` + `gptboot` in `freebsd-boot` part | `loader.efi` in EFI ESP (FAT32) | **sunxi SPL raw @ 8 KiB** |
| Bootloader source | FreeBSD base | FreeBSD base | **U-Boot port (out-of-tree blob)** |
| How firmware finds it | MBR → GPT → freebsd-boot | UEFI → ESP `/EFI/BOOT/BOOTAA64.EFI` | **fixed byte offset, no part. table** |
| Front-of-disk reserve | none (part starts ~sector 40) | none | **~8 MiB raw gap before partitions** |
| Root device node | `/dev/vtbd0p2` (virtio-blk) | `/dev/vtbd0p2` (virtio-blk) | **`/dev/mmcsd0p2`** (SD/eMMC) |
| Console | `comconsole` ttyu0 (QEMU -serial) | `comconsole` (QEMU -serial) | **UART0 on GPIO header, 115200** |
| mkimg recipe | `-b pmbr -p freebsd-boot:=gptboot ...` | `-p efi/esp:=esp.img ...` | `-p freebsd-boot::8M` (reserve) **+ raw `dd` of SPL** |
| Testable without HW? | yes (KVM) | yes (TCG) | **NO — needs the board** |

The amd64 and aarch64 recipes both live in `infra/scripts/squirrel-build.sh`
Stage 6. The BPI recipe is `infra/scripts/bpi-image.sh` and is deliberately a
separate script because of the raw-SPL step.

---

## 3. GENERIC kernel for bring-up (not a custom KERNCONF)

**Decision: use the stock FreeBSD `GENERIC` arm64 kernel for the first boot,
not `BSDOS-SQUIRREL-aarch64` or any custom config.**

Rationale — **isolate the variable**: the layout (U-Boot offset, GPT geometry,
DTB selection, root device) is the unknown we are testing. If we also swap in a
custom kernel that strips drivers, a boot failure becomes ambiguous (layout bug?
missing MMC/UART/regulator driver in the trimmed config?). GENERIC carries every
Allwinner driver (`aw_mmc`, `aw_gpio`, `aw_ccu`, `uart`, `axp8xx`, …), so a clean
boot proves the **layout** works. Only after a GENERIC boot succeeds do we
consider a slimmed Chimp KERNCONF.

This matches open question §13.5 in `docs/specs/SPEC_chimp_release.md`
("GENERIC + kldload vs custom KERNCONF") — for bring-up the answer is GENERIC.

---

## 4. Device tree (DTB)

- **Use `sun50i-a64-bananapi-m64.dtb` from FreeBSD base** (arm64 base ships
  Allwinner DTBs under `/boot/dtb/allwinner/`).
- **No custom DTS is needed for bring-up.** The upstream BPI-M64 device tree
  describes the SoC peripherals (MMC, UART, GIC, CCU, AXP803 PMIC, GMAC). That
  is sufficient to reach a login prompt.
- `bpi-image.sh` writes `fdt_name="/boot/dtb/allwinner/sun50i-a64-bananapi-m64.dtb"`
  into the loader.conf fragment so the FreeBSD loader overrides whatever DT
  U-Boot might hand it with the known-good base copy.

- **ASSUMPTION:** the DTB filename and `/boot/dtb/allwinner/` location are
  correct for FreeBSD 15.1 base arm64.
  **TODO(hardware):** confirm with `ls /boot/dtb/allwinner/ | grep bananapi`
  on the staged rootfs (or on a running 15.1 arm64 system) before flashing.

---

## 5. SD-card image layout produced by `bpi-image.sh`

```
byte offset
0          ┌────────────────────────────┐
           │ protective MBR + GPT header │  (written by mkimg)
512        │ GPT partition table         │
...        │                             │
8 KiB ─────┤ sunxi SPL  ◄── BROM reads HERE (raw dd, conv=notrunc)
           │ U-Boot proper               │  ← lives inside the reserved gap
...        │ (u-boot-sunxi-with-spl.bin) │
           ├────────────────────────────┤
~8 MiB     │ p1: freebsd-boot (RESERVE)  │  empty — exists only to push p2 past U-Boot
           ├────────────────────────────┤
           │ p2: freebsd-ufs  (rootfs)   │  ← vfs.root.mountfrom=ufs:/dev/mmcsd0p2
           ├────────────────────────────┤
           │ p3: freebsd-swap (1 GiB)     │
           ├────────────────────────────┤
end-1MiB   │ secondary GPT header        │
           └────────────────────────────┘
```

Build steps (see script for the annotated version):
1. `makefs -B little -o version=2` → UFS2 image from the staged rootfs.
2. `fsck_ufs -p -f` → mark the makefs image clean (skip forced first-boot fsck).
3. `mkimg -s gpt` with a leading empty `freebsd-boot` reservation partition +
   `freebsd-ufs` root + `freebsd-swap`.
4. `dd if=u-boot-sunxi-with-spl.bin of=img bs=1024 seek=8 conv=notrunc` — writes
   the SPL+U-Boot raw at the 8 KiB BROM offset, inside the reserved gap, without
   touching the GPT or partitions.

**ASSUMPTION:** the empty `freebsd-boot` reservation partition is never written
by mkimg, so it is safe to `dd` the U-Boot blob over its space. **TODO(hardware):**
after building, `gpart show -p <md>` (or re-read the GPT) to confirm the table
survived the `dd`.

---

## 6. Open questions

1. **Which U-Boot board target?** The script defaults to the FreeBSD port
   `sysutils/u-boot-pine64-lts` (closest in-tree A64 build).
   - **Risk:** DRAM init, GMAC PHY, and regulator wiring may differ between the
     Pine64 and the BPI-M64. If the Pine64-LTS SPL fails to init the BPI-M64's
     DRAM, the board hangs in the SPL with no console output past the BROM.
   - **Fallback:** build **mainline U-Boot** with `bananapi_m64_defconfig`
     (mainline has a dedicated BPI-M64 target + ATF/BL31) and pass the resulting
     `u-boot-sunxi-with-spl.bin` via `UBOOT_BIN=`. **TODO(hardware).**
   - **Check first:** `pkg search u-boot-bananapi` on the build host — if a
     `u-boot-bananapi-m64` port exists, prefer it over pine64-lts.

2. **ATF / BL31.** The A64 is ARMv8; a proper boot needs ARM Trusted Firmware
   (BL31) for PSCI/secure-world. The FreeBSD u-boot-pine64-lts port **ASSUMPTION:**
   already bundles BL31 into `u-boot-sunxi-with-spl.bin` (FIT image). If it does
   not, SMP / power management will misbehave. **TODO(hardware):** verify SMP
   comes up (`sysctl hw.ncpu` == 4 on A64).

3. **Console UART device name.** The fragment uses `comconsole` @ 115200.
   **TODO(hardware):** confirm the FreeBSD loader/kernel name for the A64 debug
   UART (UART0 on the GPIO header) and that 115200 8N1 is the SPL/U-Boot default.

4. **Root device enumeration.** Assumed `/dev/mmcsd0p2` (SD via `aw_mmc`).
   **TODO(hardware):** if booting from a USB reader vs the SD slot vs eMMC, the
   device may enumerate differently (`mmcsd1`, `da0`). Adjust `vfs.root.mountfrom`.

5. **Does U-Boot find loader.efi automatically?** We rely on U-Boot's distro/EFI
   boot to chainload FreeBSD's `loader.efi`. **TODO(hardware):** may need a
   `boot.scr` / `uEnv.txt` or an explicit EFI System Partition. Current script
   has **no ESP** — if U-Boot's EFI fallback path doesn't locate the loader on
   the UFS/boot partition, add a small FAT ESP with `EFI/BOOT/BOOTAA64.EFI`
   (reuse the ESP recipe from `squirrel-build.sh` Stage 6 aarch64 branch).

---

## 7. Validation checklist (run when the board arrives — a hub task, due 2026-06-27)

Prep (on the FreeBSD build host / dev-vm):
- [ ] `pkg install u-boot-pine64-lts` (or build mainline `bananapi_m64_defconfig`).
- [ ] `pkg info -l u-boot-pine64-lts | grep u-boot-sunxi-with-spl.bin` — confirm blob path.
- [ ] Stage the loader.conf + fstab fragments (printed by `bpi-image.sh` Steps 4-5) into the rootfs **before** building the image.
- [ ] `ls <rootfs>/boot/dtb/allwinner/ | grep bananapi` — confirm the DTB exists in base.
- [ ] Build: `bpi-image.sh <rootfs> bsdos-chimp-bpi-m64.img`.
- [ ] Sanity-inspect: `gpart show -p` (via md) shows p1 reserve / p2 ufs / p3 swap, GPT intact.

Flash + boot (hardware):
- [ ] Flash a real SD card: `dd if=bsdos-chimp-bpi-m64.img of=/dev/daX bs=1m conv=sync` (X = card reader).
- [ ] Wire a **3.3V USB-UART** to the BPI-M64 GPIO debug header (GND / TX / RX). **Never** feed 5V — A64 GPIO is 3.3V.
- [ ] Open the serial console at **115200 8N1** (`cu -l /dev/cuaU0 -s 115200` or `tio`).
- [ ] Insert SD, power on. **Milestone 1:** SPL/U-Boot banner on UART (proves layout + DRAM init).
- [ ] **Milestone 2:** reach the **U-Boot prompt** (interrupt autoboot) — confirms U-Boot proper runs.
- [ ] **Milestone 3:** U-Boot chainloads FreeBSD `loader.efi`, beastie/loader menu appears.
- [ ] **Milestone 4:** kernel boots with the BPI-M64 DTB; `dmesg` shows `aw_mmc`, 4 CPUs, AXP803.
- [ ] **Milestone 5:** mounts `/dev/mmcsd0p2`, reaches **login / rc** prompt.
- [ ] **Milestone 6:** `sysctl hw.ncpu` == 4 (SMP via BL31/PSCI), network up if GMAC wired.

If it hangs **before Milestone 1** → U-Boot/SPL is wrong for this board (DRAM
init) → switch to mainline `bananapi_m64_defconfig` (Open question §6.1).
If it hangs **between Milestones 3 and 5** → layout/DTB/root-device issue, not
the bootloader → revisit §4 (DTB) and §6.4 (root device).

---

*Related:* `infra/scripts/bpi-image.sh` (recipe), `infra/scripts/squirrel-build.sh`
(QEMU UEFI precedent, Stage 6), `docs/specs/SPEC_chimp_release.md` §9 (device
bring-up phases), `docs/v0.2-release-plan.md` (Chimp / BPI-M64 target),
`PLAN-arm64-crosscompile.md` (aarch64 toolchain), `DESIGN-boot-sequence.md`
(post-kernel init chain).
