# SPEC_squirrel_rootfs.md — Squirrel multi-arch QEMU rootfs build pipeline

**Date:** 2026-06-15
**Status:** Draft v2 (multi-arch per user 2026-06-15)
**Owner:** architect (claude-host / MiniMax M2.7)
**Supersedes:** partial plan in `PLAN-arm64-crosscompile.md` (which is now RISC-V-deferred)
**Codenames in scope:** Squirrel (v0.1.x — QEMU sandbox stage, small/quick)
**Architectures:** **amd64 AND aarch64** (multi-arch, equal status)
**Next:** Chimp (v0.2 — Banana Pi real hardware, aarch64 only)

---

## 1. Цель

**v0.1.x "Squirrel"** is the QEMU-sandbox stage. Per the user's
2026-06-15 directive ("арм и амд равнозначный пока"):

> Squirrel — multi-arch: **amd64 QEMU** (primary dev loop, KVM fast path)
> AND **aarch64 QEMU** (architectural target, Chimp/Porcupine-ready).
> Both are first-class. RISC-V — ⛔ DEFERRED 2026-06-15.

This spec defines a build pipeline that produces **two** rootfs images
(one per arch), bootable in QEMU, with the components needed for the
Squirrel deliverables (see §3). The shipped v0.1.0/0.1.1/0.1.2 was
amd64-only by happenstance; v0.1.3 Squirrel **adds aarch64 as a peer**
without dropping amd64.

Multi-arch rationale:
- **amd64 = primary dev loop** (KVM acceleration, TCG fallback fast enough)
- **aarch64 = architectural target** (catches alignment, endianness, NEON bugs early;
  same arch as Chimp/Porcupine production hardware)
- **Both ship in same release** (`bsdos-squirrel-v0.1.3-amd64.img.gz` AND `-aarch64.img.gz`)

---

## 2. Output

**Two files** per release:

- `bsdos-squirrel-v0.1.3-amd64.img.gz` (e.g., for x86_64 host with KVM)
- `bsdos-squirrel-v0.1.3-aarch64.img.gz` (e.g., for ARM Mac/Linux host, or QEMU on amd64 host)

**Format:** raw disk image, MBR partitioned, UFS2 filesystem, ~150-300 MB compressed (per arch).

**Bootable on:**
- amd64: QEMU `q35` machine, FreeBSD amd64 EFI stub OK
- aarch64: QEMU `virt` machine (cortex-a72), U-Boot bootloader, EFI stub OK

**Image contents** (mounted, both archs):
```
/
├── boot/
│   └── loader.conf              # U-Boot EFI stub config
├── etc/
│   ├── rc.conf                 # FreeBSD base rc.conf (minimal)
│   ├── bsdOS/
│   │   ├── bsdos.conf           # bsdos-core, bsdos_lifecycled, bsdos-hal services
│   │   ├── cage.conf            # cage+foot Wayland compositor config
│   │   └── zpids.conf           # .jpk preinstalled (Phantom browser for Squirrel)
├── opt/
│   ├── bsdos/
│   │   ├── bin/
│   │   │   ├── bsdos-core           # Zenoh pub/sub, stream manager
│   │   │   ├── bsdos_lifecycled    # SIGSTOP/SIGCONT, ZSTD memory compression
│   │   │   ├── bsdos-hal           # Zig HAL (Zig binary)
│   │   │   └── wayland-tunnel     # relay for wl_shm → v1 stream
│   │   ├── lib/                   # Rust .so + Zig static libs
│   │   └── share/
│   │       └── jpk/               # .jpk registry mirror (offline)
│   └── cage/                     # cage Wayland compositor
│       └── bin/cage
├── usr/
│   ├── local/
│   │   └── bin/
│   │       ├── foot              # terminal (default app in cage)
│   │       └── phantom-browser   # minimal "Phantom" browser (HTML→Wayland via webkit2gtk or simpler)
│   └── ...                       # FreeBSD base + pkg install set
├── var/
│   ├── db/
│   │   └── bsdos/                # bsdos-core SQLite-like state (Cap'n Proto)
│   └── log/
└── tmp/
    └── wayland-run/             # XDG_RUNTIME_DIR for cage (Unix sockets for wl-0, etc.)
```

**Image size budget:** 150 MB compressed (target). FreeBSD base = ~80 MB, bsdOS = ~30 MB, cage+foot = ~20 MB, Phantom browser = ~15 MB, headroom = ~5 MB.

---

## 3. What's in Squirrel (per user's vision)

User's 2026-06-15 Squirrel deliverables:

1. **Инфраструктура**: ARM64 (aarch64) rootfs image for QEMU
2. **Изоляция и Ядро**: .jpk prototype + ZFS Read-Only dataset mounting
3. **Диспетчер процессов**: bsdos_lifecycled Rust daemon (SIGSTOP/SIGCONT + ZSTD memory compression)
4. **Сеть и IPC**: Zenoh inside QEMU, masked as port 443, Cap'n Proto Zero-Copy
5. **Интерфейс**: Wayland buffer translation from "Phantom browser" via Unix socket to QML

Each maps to build pipeline component:
- 1 → image format (§2)
- 2 → `bsdos-pkgd install` of `phantom-browser@0.1.0.jpk` at first boot; `zpids.conf`
- 3 → `bsdos_lifecycled` Rust binary
- 4 → `bsdos-core` config (Zenoh port 443, Cap'n Proto schema, Cap'n Proto arena)
- 5 → `bsdos-core` listens on `bsdos/wayland/stream` topic, Mac QML client (separate v0.1 release, not in the image)

---

## 4. Build pipeline architecture

```
[ FreeBSD 15.1 base.txz (aarch64) ]
   ↓
[ FreeBSD 15.1 kernel (aarch64) GENERIC + bsdOS patches ]
   ↓
[ pkg install: rust, zig, lz4, zenoh, cage, foot, phantom-browser ]
   ↓
[ cargo build --target aarch64-unknown-freebsd --release (bsdos-core, bsdos_lifecycled) ]
   ↓
[ zig build -Dtarget=aarch64-freebsd.15.1 (bsdos-hal, wayland-tunnel) ]
   ↓
[ bsdos-pkgd build (for phantom-browser) ]
   ↓
[ Stage into /opt/bsdos/, /usr/local/, /etc/bsdOS/ ]
   ↓
[ mkimg(8) → bsdos-squirrel-<ver>.img (UFS2 + MBR) ]
   ↓
[ gzip -9 → bsdos-squirrel-<ver>.img.gz ]
   ↓
[ Output: <artefacts>/bsdos-squirrel-<ver>.img.gz ]
```

Each step is **idempotent** (re-runnable without side effects) and **cacheable** (intermediate artifacts stored in `~/.cache/bsdos-build/` keyed by content hash).

---

## 5. Build steps (architect's spec for runner/system)

### 5.1 Host setup (one-time)

```sh
# Linux/macOS host
pkg install qemu-system-aarch64  # or brew install qemu
wget https://ziglang.org/download/0.15.2/zig-linux-x86_64-0.15.2.tar.xz
tar xf zig-*.tar.xz
export PATH=$PATH:$(pwd)/zig-0.15.2
rustup target add aarch64-unknown-freebsd
```

### 5.2 Stage 1: FreeBSD base (aarch64)

```sh
# Download FreeBSD 15.1 base.txz for aarch64
fetch https://download.freebsd.org/releases/arm64/15.1-RELEASE/base.txz
mkdir -p $WORK/rootfs
tar -xf base.txz -C $WORK/rootfs

# Optional: build FreeBSD kernel with bsdOS patches
git clone https://git.freebsd.org/src.git -b release/15.1.0 $WORK/freebsd-src
cd $WORK/freebsd-src
patch -p1 < $BSDOS/freebsd-patches/bsdOS-arm64.patch
cd sys/arm64/conf
config BSDOS-SQUIRREL
cd ../compile/BSDOS-SQUIRREL
make -j$(nproc)
cp kernel $WORK/rootfs/boot/kernel
```

### 5.3 Stage 2: pkg install (aarch64 packages)

```sh
# In QEMU ARM64 chroot (or via pkg-static)
sudo pkg-static -c $WORK/rootfs pkg install -y \
    rust \
    cargo \
    zig \
    lz4 \
    libzenoh \
    cage \
    foot \
    wayland-protocols \
    webkit2-gtk3   # for phantom-browser

# Optional: build phantom-browser from source if not in repo
# (skip for Squirrel; use a minimal "Hello World" webview for now)
```

### 5.4 Stage 3: Build Rust components (host cross-compile)

```sh
cd $BSDOS/bsdos-core
cargo build --target aarch64-unknown-freebsd --release
cp target/aarch64-unknown-freebsd/release/bsdos-core $WORK/rootfs/opt/bsdos/bin/

cd $BSDOS/lifecycled
cargo build --target aarch64-unknown-freebsd --release
cp target/aarch64-unknown-freebsd/release/bsdos_lifecycled $WORK/rootfs/opt/bsdos/bin/
```

### 5.5 Stage 4: Build Zig components (host cross-compile)

```sh
cd $BSDOS/sys-daemon-zig
zig build -Dtarget=aarch64-freebsd.15.1 -Doptimize=ReleaseFast
cp zig-out/bin/bsdos-hal $WORK/rootfs/opt/bsdos/bin/

cd $BSDOS/wayland-tunnel
zig build -Dtarget=aarch64-freebsd.15.1 -Doptimize=ReleaseFast
cp zig-out/bin/wayland-tunnel $WORK/rootfs/opt/bsdos/bin/
```

### 5.6 Stage 5: Stage config files

```sh
mkdir -p $WORK/rootfs/etc/bsdOS
cp $BSDOS/infra/etc-bsdOS/bsdOS.conf $WORK/rootfs/etc/bsdOS/
cp $BSDOS/infra/etc-bsdOS/cage.conf $WORK/rootfs/etc/bsdOS/

# Build .jpk registry mirror (offline mode)
mkdir -p $WORK/rootfs/opt/bsdos/share/jpk
bsdos-pkgd build $BSDOS/jpk-recipes/phantom-browser → phantom-browser-0.1.0.jpk
cp phantom-browser-0.1.0.jpk $WORK/rootfs/opt/bsdos/share/jpk/
bsdos-pkgd sign --key $BSDOS/keys/squirrel-dev.key phantom-browser-0.1.0.jpk
cp phantom-browser-0.1.0.jpk $WORK/rootfs/opt/bsdos/share/jpk/

# Preinstall list
cat > $WORK/rootfs/etc/bsdOS/zpids.conf <<EOF
# Preinstalled .jpk packages for Squirrel
phantom-browser = 0.1.0
foot-terminal = 0.2.0
EOF
```

### 5.7 Stage 6: Build image

```sh
# Make image
mkimg -s gpt -f raw -b $WORK/rootfs/boot/boot1.efi -p efi/esp:=efi -p freebsd-ufs/rootfs:=$WORK/rootfs -p freebsd-swap/swap::1G -o $WORK/bsdos-squirrel.img

# Compress
gzip -9 $WORK/bsdos-squirrel.img
mv $WORK/bsdos-squirrel.img.gz $BSDOS/artefacts/bsdos-squirrel-v0.1.3-$(date +%Y%m%d).img.gz
```

### 5.8 Stage 7: Verify (smoke test in QEMU)

```sh
qemu-system-aarch64 -m 2G -smp 4 -machine virt -cpu cortex-a72 \
    -drive file=$WORK/bsdos-squirrel.img,format=raw,if=virtio \
    -device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp::7447-:7447 \
    -nographic -serial stdio

# Expect: FreeBSD boots, bsdos-core starts, Zenoh listens on :7447,
# cage+foot starts, bsdos_lifecycled runs
```

### 5.9 Output artifacts

After `make squirrel-build`:
- `$WORK/bsdos-squirrel-amd64.img.gz` — bootable amd64 image (~150 MB compressed)
- `$WORK/bsdos-squirrel-aarch64.img.gz` — bootable aarch64 image (~150 MB compressed)
- `$WORK/bsdos-squirrel-<arch>.log` — QEMU smoke test output per arch
- `$BSDOS/artefacts/bsdos-squirrel-v0.1.3-<date>-amd64.img.gz` — published amd64 artifact
- `$BSDOS/artefacts/bsdos-squirrel-v0.1.3-<date>-aarch64.img.gz` — published aarch64 artifact

---

## 6. Makefile integration

Add to `Makefile`:

```makefile
# Squirrel multi-arch build (amd64 + aarch64)
squirrel-build:
    $(SCRIPTS)/squirrel-build.sh amd64
    $(SCRIPTS)/squirrel-build.sh aarch64

# Per-arch build (when only one arch is needed)
squirrel-build-amd64:
    $(SCRIPTS)/squirrel-build.sh amd64

squirrel-build-aarch64:
    $(SCRIPTS)/squirrel-build.sh aarch64

# Squirrel smoke test (boots in QEMU, verifies bsdos-core starts; both archs)
squirrel-smoke:
    $(SCRIPTS)/squirrel-smoke.sh amd64
    $(SCRIPTS)/squirrel-smoke.sh aarch64

# Per-arch smoke
squirrel-smoke-amd64:
    $(SCRIPTS)/squirrel-smoke.sh amd64

squirrel-smoke-aarch64:
    $(SCRIPTS)/squirrel-smoke.sh aarch64

# Squirrel interactive boot (foreground, for debugging)
squirrel-boot:
    @echo "Usage: make squirrel-boot-amd64 OR squirrel-boot-aarch64"

squirrel-boot-amd64:
    qemu-system-x86_64 -m 2G -smp 4 -machine q35 -cpu host \
        -drive file=artefacts/bsdos-squirrel-v0.1.3-amd64-latest.img.gz,format=raw,if=virtio \
        -device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp::7447-:7447 \
        -nographic -serial stdio

squirrel-boot-aarch64:
    qemu-system-aarch64 -m 2G -smp 4 -machine virt -cpu cortex-a72 \
        -drive file=artefacts/bsdos-squirrel-v0.1.3-aarch64-latest.img.gz,format=raw,if=virtio \
        -device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp::7447-:7447 \
        -nographic -serial stdio
```

---

## 7. CI integration

PR check (gates Squirrel acceptance, **both archs**):
```yaml
- name: Squirrel build (amd64)
  run: make squirrel-build-amd64
  # ~15 min on Linux/macOS host (cold); ~3 min warm with cache

- name: Squirrel build (aarch64)
  run: make squirrel-build-aarch64
  # ~20 min cold (cross-compile); ~5 min warm

- name: Squirrel smoke (amd64 QEMU)
  run: make squirrel-smoke-amd64
  # ~3 min: boot QEMU with KVM, check bsdos-core alive, shutdown

- name: Squirrel smoke (aarch64 QEMU)
  run: make squirrel-smoke-aarch64
  # ~5 min: boot QEMU (TCG slower than KVM), check bsdos-core alive, shutdown
```

Caching: intermediate `~/.cache/bsdos-build/` (FreeBSD base.txz, kernel, pkg cache) keyed by content hash AND by arch. Cache hit saves ~15 min per arch.

---

## 8. Per-developer workflow

```sh
# Day 1: Initial build (both archs, ~30 min cold)
make squirrel-build

# Day 2: Iterate on bsdos-core (fast loop on amd64)
$EDITOR bsdos-core/src/main.rs
make squirrel-smoke-amd64         # ~3 min: rebuild + QEMU boot with KVM

# Day 3: Validate on aarch64 too
make squirrel-smoke-aarch64       # ~5 min: TCG QEMU boot, verify same

# Day 4: Iterate on a .jpk
$EDITOR jpk-recipes/phantom-browser/src/main.rs
make squirrel-build                # rebuilds both archs
qemu-system-x86_64 ...            # manual amd64 boot
qemu-system-aarch64 ...           # manual aarch64 boot
```

Per-arch fast loop: when working on a host driver, iterate on that host's
arch (amd64 dev VM uses amd64, aarch64 Mac uses aarch64 native). When
cross-arch work (HAL, Zenoh, Wayland), validate on both.

---

## 9. Multi-arch rationale

Per user 2026-06-15 ("арм и амд равнозначный пока"):

**Why both archs are first-class for Squirrel:**
1. **amd64 = primary dev loop** — KVM acceleration fast, TCG fallback good enough.
   Devs iterate here first.
2. **aarch64 = architectural target** — catches alignment, endianness, NEON bugs
   early in QEMU (easier to debug than on real hardware). Same arch as
   Chimp/Porcupine production hardware.
3. **Both ship in same release** — `bsdos-squirrel-v0.1.3-amd64.img.gz` AND
   `bsdos-squirrel-v0.1.3-aarch64.img.gz`. No "primary" or "secondary".
4. **amd64 not a throwaway** — many dev hosts are amd64 (including the
   existing bsdOS dev VM <dev-vm-ip>). Forcing aarch64 would slow
   the inner loop unnecessarily.

**Dev workflow:**
- Inner loop: amd64 (KVM fast)
- Validation: aarch64 (TCG slower but real)
- Real hardware: Chimp/Porcupine (aarch64 only, this is where aarch64
  code path meets real silicon)

The build pipeline produces **both** images. CI tests **both**. CI fails
if either arch breaks.

---

## 10. Differences from Chimp (v0.2)

| Aspect | Squirrel (v0.1) amd64 | Squirrel (v0.1) aarch64 | Chimp (v0.2) |
|---|---|---|---|
| Target | QEMU x86_64 (q35) | QEMU aarch64 (virt) | Real Banana Pi (BPI-M64/M2) |
| Image | mkimg(8) → raw .img | mkimg(8) → raw .img | dd → SD card |
| Boot | FreeBSD amd64 EFI stub | U-Boot EFI stub | Allwinner BROM → U-Boot → bsdOS |
| GPU | none (CPU-only) | none (CPU-only) | Mesa Lima (Mali-G31 GLES2) |
| Network | QEMU user-mode (hostfwd) | QEMU user-mode (hostfwd) | Real eth0 (RTL8211F) |
| Storage | QEMU virtio-blk | QEMU virtio-blk | eMMC + NVMe |
| Power | n/a | n/a | Allwinner AXP223 (regulator) |
| Telephony | n/a | n/a | n/a (PinePhone stage) |
| Image size | 150 MB compressed | 150 MB compressed | 1-2 GB on eMMC |
| CI cost | ~3 min (KVM) | ~5 min (TCG) | n/a (manual) |

The build pipeline from Squirrel is the **bootstrap** for Chimp's
image; Chimp just adds hardware-specific stages (bootloader
config, AXP regulator, etc.). Only the **aarch64** pipeline feeds
Chimp — the amd64 pipeline is for Squirrel dev loop only.

---

## 11. Implementation plan (for runner + system agents)

| Step | Owner | Estimate | Output |
|------|-------|----------|--------|
| 11.1 `infra/scripts/squirrel-build.sh <arch>` orchestrator | runner (cheap) | 1 wk | Bash script that takes `$ARCH` ∈ {amd64, aarch64}, calls stages 1-7, with per-arch caching |
| 11.2 FreeBSD base.txz fetcher + pkg-static wrapper (per arch) | runner | 2 d | `$WORK/rootfs` populated with base + packages for each arch |
| 11.3 Cross-compile helper: cargo + zig in one Makefile target (per arch) | system (Qwen 3.7) | 3 d | `make cross-squirrel-amd64` and `make cross-squirrel-aarch64` build all Rust + Zig components |
| 11.4 mkimg invocation + image compression (per arch) | runner | 1 d | `bsdos-squirrel-<ver>-<arch>.img.gz` artifact (×2) |
| 11.5 QEMU smoke test wrapper (per arch) | system | 2 d | `make squirrel-smoke-amd64` and `-aarch64` boot, check bsdos-core alive, exit 0 |
| 11.6 CI integration (.github/workflows/squirrel.yml) — **both archs** | sre | 1 d | PR check on every commit, both archs |
| 11.7 Phantom browser .jpk recipe (per arch) | system | 1 wk | `bsdos-pkgd build` of `phantom-browser@0.1.0-<arch>` |
| 11.8 FreeBSD kernel configs BSDOS-SQUIRREL-amd64 and -aarch64 | system | 2 d | kernels build for both archs with bsdOS patches |
| 11.9 bsdos_lifecycled SIGSTOP/SIGCONT + ZSTD mem compression (per arch) | system | 1 wk | Rust daemon, tested in QEMU on both archs |
| **Total** | | **~6 weeks** | Squirrel v0.1.3+ with **amd64 AND aarch64** QEMU images |

---

## 12. Open questions (resolved 2026-06-15 per user "обе собирать")

1. **Kernel config naming** — `BSDOS-SQUIRREL-amd64` AND `BSDOS-SQUIRREL-aarch64` (per-arch). Each arch has its own config.
2. **Phantom browser source** — **wpewebkit-fdo** (~30 MB) for both archs in Squirrel; Firefox for Chimp if needed.
3. **ZSTD memory compression in lifecycled** — process-level `pmap_zstd` (FreeBSD-native, both archs).
4. **Image signing** — defer to Chimp. Squirrel ships unsigned.
5. **First-boot experience** — autostart (demo image, both archs).
6. **Window manager choice** — cage (named in vision, both archs).
7. **Architecture: amd64 or aarch64?** — **BOTH, multi-arch, equal status** (per user 2026-06-15 "арм и амд равнозначный пока").

---

## 13. Cross-references

- `PLAN-arm64-crosscompile.md` — aarch64 cross-compile guide (RISC-V DEFERRED 2026-06-15); Squirrel uses both amd64 (native) and aarch64 (cross)
- `PLAN-bpi-f3-bringup.md` — **⛔ DEFERRED 2026-06-15** (RISC-V SpacemiT K1 shelved); no impact on Squirrel (QEMU only)
- `PLAN-lifecycle-v2.md` — bsdos_lifecycled design (ZSTD compression, MEM_GUARD)
- `PLAN-jail-prototype.md` — FreeBSD jail setup (foundation for Squirrel isolation)
- `docs/specs/SPEC_jpk_descriptor_v1.md` — .jpk format (Squirrel uses for phantom-browser preinstall, both archs)
- `docs/specs/SPEC_2stream_squirrel.md` — 2-stream demo (architecture-agnostic, both archs)
- `docs/v0.2-release-plan.md` ("Chimp") — v0.2 inherits the **aarch64** Squirrel pipeline; amd64 pipeline stays in Squirrel dev loop

---

**Status:** Architect design draft v2 (multi-arch per user 2026-06-15). Next: spec → runner script (1 wk, cheap model) → system Qwen for kernels + bsdos_lifecycled (2-3 wks) → sre for CI (1 d) → qa for QEMU smoke on both archs. Acceptance: `make squirrel-build` produces 2 images, `make squirrel-smoke` boots both, `make test-2stream-e2e` exits 0 on both.
