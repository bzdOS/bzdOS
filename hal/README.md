# bsdos-hal

> **Hardware Abstraction Layer for bsdOS — FreeBSD/aarch64 Zig daemon.**
> Tickless single-binary that exposes hardware telemetry and control over a
> Unix socket with a line-oriented text protocol. Platform capabilities are
> resolved at compile time — unused subsystems produce zero code.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.15%2B-orange.svg)](https://ziglang.org)
[![FreeBSD](https://img.shields.io/badge/FreeBSD-15.1-red.svg)](https://www.freebsd.org)

---

## Why?

Mobile hardware (PinePhone, Banana Pi) exposes sensors, modems, and
backlight controllers through a mix of `sysctl`, `ioctl`, AT commands, and
I2C. Polling them from multiple processes means repeated syscalls, open/close
churn, and racy reads.

`bsdos-hal` solves this with a single daemon:

| Property | Without HAL | With bsdos-hal |
|---|---|---|
| CPU wake rate | Per-process polling | **0 — blocks in `accept()`** |
| ARM C-states | Prevented by busy-loops | **WFI automatically via kqueue** |
| Platform gating | `#ifdef` scattered in callers | **Comptime flags — dead code eliminated** |
| Sensor access | Every process opens `/dev/iic*` | **One owner, one file descriptor** |
| QEMU builds | Stub code manually maintained | **Platform flags → zero stub code compiled in** |

The main thread blocks in `accept()`. FreeBSD's cpuidle puts the Cortex-A53
into WFI automatically — the daemon adds no measurable idle load.

## Supported platforms

| Platform | `-Dplatform=` | Codename | Target hardware |
|---|---|---|---|
| QEMU amd64 | `qemu_amd64` | Squirrel v0.1.x | QEMU KVM (primary dev loop) |
| QEMU aarch64 | `qemu_aarch64` | Squirrel v0.1.x | QEMU aarch64 (architectural target) |
| Banana Pi BPI-M64 | `bpi_m64` | Chimp v0.2 | Allwinner A64, real hardware |
| PinePhone | `pinephone` | Porcupine v0.3 | Allwinner A64 + Mali-400 |

## Protocol

The daemon listens on `/var/run/bsdos-hal.sock` (AF_UNIX, SOCK_STREAM).
Send a newline-terminated command; receive a newline-terminated JSON response.

```
echo "hal_version" | nc -U /var/run/bsdos-hal.sock
{"ok":true,"value":{"version":"0.2.3","features":[...]}}
```

### Commands

| Command | Arguments | Response `value` | Notes |
|---|---|---|---|
| `hal_version` | — | `{"version":"<semver>","features":[...]}` | Always available |
| `get_uptime` | — | `{"value":<secs>}` | `kern.boottime` on FreeBSD |
| `get_hostname` | — | `{"value":"<name>"}` | `gethostname(2)` |
| `get_cpu_usage` | — | `{"pct":<0-100>}` | Single-sample `kern.cp_time` |
| `get_memory` | — | `{"free_pages":<n>,"total_pages":<n>,"free_pct":<n>}` | `vm.stats.vm.*` |
| `get_battery` | — | `{"pct":<0-100>,"charging":<bool>,"source":"ac"\|"battery"}` | ACPI; returns 100%/ac on QEMU |
| `get_touch_zone` | `X Y` | `{"value":"<jail>"\|null}` | Comptime zone table lookup |
| `get_sim_status` | — | IMSI/PIN/CSQ/COPS/CREG JSON | `pinephone` only |
| `get_orientation` | — | `{"roll":<f>,"pitch":<f>,"yaw":<f>}` | `pinephone` only |
| `get_location` | — | `{"lat":<f>,"lon":<f>,"alt":<f>}` | `pinephone` only |
| `get_proximity` | — | `{"near":<bool>,"lux":<n>}` | `pinephone` only (STK3311) |
| `get_compass` | — | `{"heading":<deg>}` | `pinephone` only (LIS3MDL) |
| `get_haptic` | `<pattern>` | `{"ok":true}` | `pinephone` only; patterns: `short`, `long`, `double` |
| `sms_send` | `<number> <text>` | `{"value":"sent"}` | `pinephone` only; AT+CMGS |
| `sms_list` | — | `{"value":[<idx>, ...]}` | `pinephone` only; AT+CMGL |
| `backlight_set` | `<0-100>` | `{"level":<n>}` | `bpi_m64` + `pinephone` |
| `backlight_get` | — | `{"level":<n>,"enabled":<bool>}` | `bpi_m64` + `pinephone` |

All responses follow `{"ok":true,"value":...}` on success and
`{"ok":false,"error":"<message>"}` on failure.

## Capability flags

All flags are `comptime bool` constants resolved from `-Dplatform=`. The
compiler eliminates every branch that depends on a `false` flag — QEMU builds
contain no modem, GPS, or sensor code at all.

| Flag | `qemu_amd64` | `qemu_aarch64` | `bpi_m64` | `pinephone` | Hardware |
|---|---|---|---|---|---|
| `has_modem` | false | false | false | **true** | EC25 modem (`/dev/cuaU0`) |
| `has_sim` | false | false | false | **true** | SIM card slot |
| `has_sms` | false | false | false | **true** | AT+CMGS / AT+CMGL |
| `has_gps` | false | false | false | **true** | GNSS UART (`/dev/ttyu1`) |
| `has_accelerometer` | false | false | false | **true** | LIS2DE12 (I2C) |
| `has_magnetometer` | false | false | false | **true** | LIS3MDL (I2C) |
| `has_proximity` | false | false | false | **true** | STK3311 (I2C) |
| `has_haptic` | false | false | false | **true** | GPIO/PWM vibration motor |
| `has_ghost_radio` | false | false | false | **true** | Stealth scan thread |
| `has_predictive_touch` | false | false | false | **true** | Touch pre-warping pipeline |
| `has_i2c` | false | false | **true** | **true** | `/dev/iic0` (BPI) / `/dev/iic1` (PPP) |
| `has_audio` | false | false | **true** | **true** | OSS `/dev/dsp0` (sun4i-codec) |
| `has_backlight` | false | false | **true** | **true** | `/dev/backlight/backlight0` |

## Build

Requires Zig 0.15+ and a FreeBSD 15.1 cross-toolchain or a native FreeBSD host.

```sh
# QEMU dev loop (default)
zig build

# Banana Pi BPI-M64 (Chimp v0.2)
zig build -Dtarget=aarch64-freebsd.15.1 -Dplatform=bpi_m64

# PinePhone (Porcupine v0.3)
zig build -Dtarget=aarch64-freebsd.15.1 -Dplatform=pinephone

# Run tests
zig build test
```

The resulting binary is `zig-out/bin/bsdos-hal`.

## Run

```sh
# Start the daemon (requires root for /var/run/)
./bsdos-hal

# Query version
echo "hal_version" | nc -U /var/run/bsdos-hal.sock

# Query battery
echo "get_battery" | nc -U /var/run/bsdos-hal.sock

# Touch zone lookup (pixel coordinates)
echo "get_touch_zone 360 400" | nc -U /var/run/bsdos-hal.sock

# Set backlight to 70% (bpi_m64 / pinephone only)
echo "backlight_set 70" | nc -U /var/run/bsdos-hal.sock
```

## What's in this repo?

- **[`src/main.zig`](src/main.zig)** — entry point, socket server, command dispatch
- **[`src/platform.zig`](src/platform.zig)** — comptime capability flags
- **[`src/backlight.zig`](src/backlight.zig)** — `/dev/backlight/*` ioctl
- **[`src/modem.zig`](src/modem.zig)** / **[`src/sim.zig`](src/sim.zig)** / **[`src/sms.zig`](src/sms.zig)** — AT command layer
- **[`src/gps.zig`](src/gps.zig)** — NMEA UART reader
- **[`src/proximity.zig`](src/proximity.zig)** — STK3311 ambient-light + proximity (I2C)
- **[`src/magnetometer.zig`](src/magnetometer.zig)** — LIS3MDL compass (I2C)
- **[`src/accelerometer.zig`](src/accelerometer.zig)** — LIS2DE12 orientation (I2C)
- **[`src/haptic.zig`](src/haptic.zig)** — GPIO/PWM vibration patterns
- **[`src/touch_zones.zig`](src/touch_zones.zig)** — comptime jail-to-screen zone table
- **[`src/predictive_touch.zig`](src/predictive_touch.zig)** — touch pre-warping pipeline
- **[`src/ghost_radio.zig`](src/ghost_radio.zig)** — stealth scan thread
- **[`src/audio_bridge.zig`](src/audio_bridge.zig)** — Cap'n Proto → OSS zero-copy bridge
- **[`src/telemetry.zig`](src/telemetry.zig)** — Zenoh telemetry publisher
- **[`build.zig`](build.zig)** — build definition

## License

MIT. See [`LICENSE`](LICENSE).

## Origin

Developed as part of [bsdOS](https://github.com/bzdOS) — a privacy-first
mobile OS on FreeBSD. Extracted as a standalone HAL daemon in June 2026.
