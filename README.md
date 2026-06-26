# bsdOS

> Privacy-first FreeBSD OS for ARM64 — jailed applications, Zenoh mesh transport, zero-copy Wayland streaming.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![FreeBSD](https://img.shields.io/badge/FreeBSD-15.1-red.svg)](https://www.freebsd.org)
[![Rust](https://img.shields.io/badge/Rust-nightly-orange.svg)](https://www.rust-lang.org)
[![Zig](https://img.shields.io/badge/Zig-0.13-yellow.svg)](https://ziglang.org)
[![Zenoh](https://img.shields.io/badge/Zenoh-1.x-blue.svg)](https://zenoh.io)

---

## What is bsdOS?

bsdOS is a FreeBSD-based operating system built for privacy-first, ARM64 hardware. Applications run in
isolated FreeBSD jails — each app gets its own file system view, network policy, and entitlements.
Wayland sessions are streamed over Zenoh peer mesh using a zero-copy wire format (wlstream), so a Mac
or Linux client can view any jail's UI without SPICE or VNC. The primary targets are QEMU-based dev
environments (Squirrel), Banana Pi BPI-M64 (Chimp), and PinePhone (Porcupine).

---

## Architecture

```
Mac / Linux viewer (metal-viewer)
        |  Zenoh / obfs-TLS :443
        v
  bsdos-core  (FreeBSD VM or board)
  |-- StreamManager ------> cage  (headless Wayland compositor)
  |                              |
  |                              +-> WLTunnel -----> Zenoh stream
  |                              +-> app (foot / chromium / electron)
  |
  |-- LifecycleManager ---> jail FREEZE / THAW  (SIGSTOP / SIGCONT)
  |
  +-- PackageManager -----> .jpk  (ZFS jail datasets + entitlements)
```

Cap'n Proto is used for data-plane serialization (HardwareStatus, JailStatus, TouchEvent,
WaylandPacket). All inter-node transport goes over Zenoh in peer mode — no broker required.
The control plane uses a simple text protocol (`CMD ARG\n` / `+OK\n`) over virtio-console.

---

## Components

| Component | Language | Description | Location |
|---|---|---|---|
| bsdos-core | Rust | Stream manager + Zenoh node + lifecycle RPC | this repo |
| bsdos-lifecycled | Rust | Jail FREEZE/THAW daemon | this repo |
| bsdos-pkgd | Rust | .jpk package installer | this repo |
| bsdos-run | Rust | IPA runner + entitlements to jail policy | this repo |
| machotool | Rust | Mach-O / fat binary parser | this repo |
| WLTunnel | Zig | Wayland session streaming tunnel | [github.com/bzdOS/WLTunnel](https://github.com/bzdOS/WLTunnel) |
| bsdos-hal | Zig | Hardware abstraction layer (aarch64) | [github.com/bzdOS/bsdos-hal](https://github.com/bzdOS/bsdos-hal) |
| metal-viewer | Rust | macOS Metal stream viewer | [github.com/bzdOS/metal-viewer](https://github.com/bzdOS/metal-viewer) |
| WLStream | Rust | Wayland stream wire format | [github.com/bzdOS/WLStream](https://github.com/bzdOS/WLStream) |

---

## Platforms

| Codename | Target | Status |
|---|---|---|
| Squirrel | QEMU amd64 + aarch64 | v0.1.3 done |
| Chimp | Banana Pi BPI-M64 (A64) | bring-up |
| Porcupine | PinePhone (A64) | planned |

Both amd64 and aarch64 QEMU images are built from the same source tree. The aarch64 image is
structurally identical to the Chimp and Porcupine targets (same A64 SoC family, same drivers).

---

## Quick start

```sh
# Requires: Rust nightly, FreeBSD 15.1 (or cross-compile from Linux/macOS)
cargo build --release -p bsdos-core

# Full rootfs image — amd64 or aarch64:
./infra/scripts/bsdos-build.sh amd64
./infra/scripts/bsdos-build.sh aarch64

# Cross-compile toolchain setup (Zig sysroot + LLVM linker):
./infra/scripts/mk-cross-cc.sh aarch64-unknown-freebsd15.1
```

### Deploy to a running VM

```sh
# Set your VM IPs, then:
DEV_IP=<dev-vm-ip> MYVM_IP=<myvm-ip> \
  infra/scripts/deploy-bsdos-myvm.sh --all
```

### Smoke test

```sh
infra/scripts/bsdos-smoke.sh
```

---

## JPK packages

`.jpk` is bsdOS's jail package format. Each package is a ZFS dataset snapshot bundling:
- a FreeBSD jail root (base system + app binaries)
- an entitlements manifest (network policy, device access, display isolation)
- optional overlay layers (shared read-only libs, fonts, locales)

The `bsdos-pkgd` crate handles build / inspect / verify / install. Recipes live in
[`jpk-recipes/`](jpk-recipes/) — see `foot`, `phantom-browser`, `cage`, `wpewebkit-fdo`.

---

## Zenoh key space

| Key | Publisher | Description |
|---|---|---|
| `bsdos/telemetry` | bsdos-core | Core uptime / battery / CPU heartbeat |
| `bsdos/jail/<name>/status` | lifecycled | Jail lifecycle events |
| `bsdos/app/<id>/stream` | WLTunnel | Per-stream wl_shm frames (v1 length-prefixed) |
| `bsdos/app/<id>/input/keyboard` | bsdos-core | Keyboard events to stream |
| `bsdos/app/<id>/input/pointer` | bsdos-core | Pointer events to stream |
| `bsdos/app/<id>/viewer/size` | viewer | Viewer resize notification |
| `bsdos/ctl/stream/start` | client | Start stream command |
| `bsdos/ctl/stream/stop` | client | Stop stream command |

---

## License

MIT — see [LICENSE](LICENSE).
