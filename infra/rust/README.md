# bsdOS Rust platform cfg infrastructure

Compile-time platform selection for Rust crates, symmetric with the Zig side
(`-Dplatform=<str>` → `sys-daemon-zig/src/platform.zig`). One source of truth:
the `BSDOS_PLATFORM` env var.

We deliberately do **not** use cargo features for platform choice: features are
additive and unified across the workspace, so a mutually-exclusive selection
would need `compile_error!` guards. Instead, `BSDOS_PLATFORM` → `build.rs` →
`cargo::rustc-cfg`.

## How it works

`platform_build.rs` exposes `emit_platform_cfg()`. A crate's `build.rs` does:

```rust
include!("../infra/rust/platform_build.rs");
fn main() { emit_platform_cfg(); }
```

At build time it reads `BSDOS_PLATFORM` (default `qemu_amd64`; unknown → falls
back to `qemu_aarch64`, mirroring `platform.zig`) and emits:

- `bsdos_platform="<p>"` — the selected platform string.
- one capability cfg per enabled `has_*` flag, kept 1:1 with `platform.zig`.

Every possible value and cfg name is declared via `cargo::rustc-check-cfg`, so
no `unexpected_cfgs` warnings appear regardless of selection.

## Platforms

`qemu_amd64` · `qemu_aarch64` · `bpi_m64` · `pinephone`

## Capability cfgs (mirror `platform.zig` `has_*`)

| cfg | enabled on |
|---|---|
| `bsdos_has_modem` / `_sim` / `_sms` / `_haptic` / `_battery` / `_gps` / `_accelerometer` / `_magnetometer` / `_proximity` / `_predictive_touch` / `_ghost_radio` | `pinephone` |
| `bsdos_has_i2c` / `_audio` / `_backlight` | `bpi_m64`, `pinephone` |

## Using cfgs in code

```rust
#[cfg(bsdos_platform = "bpi_m64")]
fn init_twi() { /* Allwinner A64 TWI0 */ }

#[cfg(bsdos_has_i2c)]
fn read_sensor_bus() { /* /dev/iic* present */ }

#[cfg(not(bsdos_has_i2c))]
fn read_sensor_bus() { /* QEMU stub */ }
```

## Where BSDOS_PLATFORM is set

The `cross-squirrel-amd64` / `cross-squirrel-aarch64` Makefile targets (invoked
by `infra/scripts/bsdos-build.sh <arch>`) set `BSDOS_PLATFORM` on the `cargo`
line — `qemu_amd64` for amd64, `qemu_aarch64` for aarch64. For local builds
targeting real hardware, export it explicitly, e.g.
`BSDOS_PLATFORM=pinephone cargo build -p bsdos-lifecycled`.
