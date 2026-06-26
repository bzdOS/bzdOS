# Changelog

All notable changes to `bsdos-hal` are documented here.
Dates are ISO 8601. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [0.1.3] — 2026-06-26

### Added

- **Text protocol socket** (`/var/run/bsdos-hal.sock`, AF_UNIX SOCK_STREAM):
  line-oriented `CMD\n` → JSON response, single-connection MVP.
- **Cross-platform commands** (available on all platforms):
  `hal_version`, `get_uptime`, `get_hostname`, `get_cpu_usage`,
  `get_memory`, `get_battery`, `get_touch_zone`.
- **Comptime platform flags** (`src/platform.zig`): `Platform` enum
  (`qemu_amd64`, `qemu_aarch64`, `bpi_m64`, `pinephone`); `has_*` boolean
  constants resolved at build time from `-Dplatform=<str>`; dead branches
  eliminated by the compiler.
- **Backlight control** (`src/backlight.zig`): `backlight_set/get/on/off/auto`
  via `BACKLIGHTSETSTATE`/`BACKLIGHTGETSTATUS` ioctl on FreeBSD;
  available on `bpi_m64` and `pinephone`.
- **Modem / SIM / SMS layer** (`src/modem.zig`, `src/sim.zig`, `src/sms.zig`):
  AT command transport over `/dev/cuaU0`; `get_sim_status`, `sms_send`,
  `sms_list`; `pinephone` only.
- **GPS stub** (`src/gps.zig`): `get_location` returns a QEMU stub;
  NMEA UART reader planned for Phase 2.
- **I2C sensors** (`src/proximity.zig`, `src/accelerometer.zig`,
  `src/magnetometer.zig`): STK3311 proximity+light, LIS2DE12 accelerometer,
  LIS3MDL compass; `pinephone` only.
- **Haptic patterns** (`src/haptic.zig`): `short`, `long`, `double`;
  `pinephone` only.
- **Comptime touch-zone table** (`src/touch_zones.zig`): maps pixel coordinates
  to jail names; `get_touch_zone X Y` dispatch.
- **Predictive touch pipeline** (`src/predictive_touch.zig`): touch
  pre-warping stub; `pinephone` only.
- **Ghost radio thread** (`src/ghost_radio.zig`): stealth scan stub;
  `pinephone` only.
- **Audio bridge** (`src/audio_bridge.zig`): Cap'n Proto → OSS zero-copy;
  `bpi_m64` + `pinephone`; thread disabled pending Zig 0.15.2 migration.
- **Telemetry publisher** (`src/telemetry.zig`): Zenoh heartbeat stub.
- **Tickless idle**: main thread blocks in `accept()` → ARM WFI via FreeBSD
  cpuidle; no busy-loops.
- **25+ unit tests** covering: command dispatch, JSON well-formedness, touch
  zone detection, SysCmd frame size, buffer overflow guard.
- **`build.zig`**: `-Dplatform=` option; `zig build test` step; `libc` linkage
  for FreeBSD syscalls.

### Platform support

| Platform | Status |
|---|---|
| `qemu_amd64` | Full cross-platform command set |
| `qemu_aarch64` | Full cross-platform command set |
| `bpi_m64` | + backlight, I2C, audio |
| `pinephone` | All capabilities |

### Origin

Extracted from [bsdOS](https://github.com/bzdOS) (privacy-first FreeBSD
mobile OS). The daemon has been in use on Squirrel v0.1.x since June 2026.

[0.1.3]: https://github.com/bzdOS/bsdos-hal/releases/tag/v0.1.3
