# SPEC_woodpecker_hal.md — HAL, Sensors, Display, Scheduler, GPU (Woodpecker v0.3)

**Synthesized:** 2026-06-15 (architect, claude-host / MiniMax M2.7)
**Status:** Active specification (Woodpecker v0.3 — PinePhone)
**Target hardware:** PinePhone (Allwinner A64, Cortex-A53, Mali-400)
**OS:** oBzdOS (OpenBSD aarch64) — TODO: OpenBSD driver audit needed
**Synthesizes:** 15 legacy `PLAN-*.md` files (HAL contract, v2, testing, sensors, display, brightness, screen-timeout, battery-health, scheduler tuning, tickless, GPU paths, etc.)

> **Codename:** Woodpecker v0.3 — mobile stage. See `ROADMAP.md` for full codename scheme.

**See also:**
- `docs/specs/SPEC_woodpecker_mobile.md` — mobile subsystems (uses this HAL)
- `docs/specs/SPEC_woodpecker_thermal.md` — thermal throttling (HZ reduction)
- `docs/specs/SPEC_woodpecker_power.md` — power management (C-states, Ghost Radio)
- `docs/specs/SPEC_squirrel_rootfs.md` — HAL stub on QEMU (Phase 0)
- `docs/archive/2026-10-01-monorepo/PLAN-gpu-bringup.md` — GPU bring-up roadmap (Mali-400)

---

## 0. Scope

The HAL is the **Zig daemon** (`hal/`) that exposes hardware to oBzdOS jails. On Woodpecker, the HAL becomes the **system integration point** for:

1. **HAL contract** (v1 → v2 evolution): JSON socket + Cap'n Proto stream + kqueue events
2. **I2C drivers:** battery (AXP803), sensors (LIS3MDL, MXC6655, LIS2DE12)
3. **Display pipeline:** fbdev (Phase 1) → Lima/Mali-400 via UIO (Phase 2)
4. **GPU paths:** UIO userspace (4-week MVP) vs DRM full-stack (6+ month stretch)
5. **Scheduler tuning:** ULE tuning, tickless for ARM C-states
6. **Power management hooks:** screen timeout, brightness, battery health

---

## 1. HAL v2 — dual transport + kqueue

**Source:** `docs/archive/2026-06-15-plans/PLAN-hal-v2.md` (17 KB, full)
**Current state:** v1 = JSON text socket `/var/run/bsdos-hal.sock`, blocking, 15+ modules (most stubs).
**v2 target:** Hybrid architecture with kqueue events, Cap'n Proto stream telemetry, direct Zenoh pub.

**Why v2:** JSON serialization is overhead for high-frequency data (touch @ 240Hz, telemetry @ 1Hz). Polling threads with `sleep()` waste CPU and lack accurate timing.

**v2 architecture:**
```
┌──────────────────────────────────────────┐
│ JSON Control Plane (legacy compat)       │
│  Unix socket /var/run/bsdos-hal.sock     │
│  Text: {"cmd":"get_battery"}\n → JSON    │
│  For: one-shot commands, admin tools     │
├──────────────────────────────────────────┤
│ Cap'n Proto Data Plane (NEW)             │
│  Stream socket (separate path)           │
│  HardwareStatus, TouchEvent, etc.        │
│  For: high-freq telemetry                │
├──────────────────────────────────────────┤
│ kqueue Event Loop (NEW)                  │
│  /dev/iic* (I2C), /dev/spi* (SPI),       │
│  /dev/cuaU* (UART), GPIO sysfs           │
│  Async push to Zenoh: bsdos/hal/*        │
├──────────────────────────────────────────┤
│ Zenoh Direct Pub (NEW)                   │
│  HAL → Zenoh (bypass broker)             │
│  For: hot path (battery low alerts)      │
└──────────────────────────────────────────┘
```

**Phase plan:**
- **Phase 1 (Q3 2026):** kqueue loop + I2C drivers (battery, sensors)
- **Phase 2 (Q4 2026):** Cap'n Proto stream + direct Zenoh pub
- **Phase 3 (Woodpecker v0.3):** kqueue for all async I/O, full Zenoh integration

---

## 2. HAL contract (v1, stable)

**Source:** `docs/archive/2026-06-15-plans/PLAN-hal-interface.md` (23 KB, full)

**Transport:**
- **Path:** `/var/run/bsdos-hal.sock`
- **Mode:** `0o777` (broker filters security-sensitive commands)
- **Protocol:** Line-oriented text JSON
  - Request: `{"cmd":"X"}\n`
  - Response: `{"ok":true,"value":...}\n` (or `{"ok":false,"error":"..."}\n`)
- **Connection model:** 1 request → 1 response → close (MVP); thread pool in Phase 2

**Timeout contract:**

| Side | Timeout | Action |
|---|---|---|
| Client | 5s (configurable) | `Err(HalTimeout)` |
| HAL | 1s per I/O syscall | retry or `-ERR` |

**Command categories:**
- `get_*` (read-only): uptime, hostname, memory, cpu, battery, location, sensors
- `set_*` (write): airplane_mode, backlight, charging_limit, screen_off
- `action_*` (side-effect): emergency_erase, biometric_capture, nfc_read

**Platform support matrix:**

| Command | QEMU (Squirrel) | PinePhone (Woodpecker) |
|---|---|---|
| `get_uptime` | ✅ real | ✅ real |
| `get_hostname` | ✅ real | ✅ real |
| `get_memory` | ✅ real | ✅ real |
| `get_cpu` | ✅ real | ✅ real |
| `get_battery` | stub (50%) | ✅ AXP803 I2C |
| `get_charging` | stub (false) | ✅ AXP803 I2C |
| `get_location` | mock | ✅ Quectel L96 |
| `get_sensors` | mock | ✅ I2C sensors |
| `set_backlight` | noop | ✅ ioctl |
| `set_airplane_mode` | noop | ✅ GPIO write |

---

## 3. Sensors (I2C bus 1)

**Source:** `docs/archive/2026-06-15-plans/PLAN-sensor-fusion.md` (36 KB, full)

**Hardware:** PinePhone has I2C bus 1 with:
- **LIS3MDL** — magnetometer (3-axis, ±4/±8/±12/±16 gauss)
- **MXC6655** or **LIS2DE12** — accelerometer (3-axis, ±2/±4/±8/±16 g)
- **MXC6631** — proximity + light sensor

**Modules:**
```
src/
├── sensors_i2c.zig       # I2C API wrapper
├── magnetometer.zig      # LIS3MDL driver
├── accelerometer.zig     # MXC6655 / LIS2DE12 driver
├── proximity.zig         # MXC6631 driver
└── gesture.zig           # shake, tilt (future)
```

**Zenoh pub:** `bsdos/sensors/{accel,compass,proximity,light}` (Cap'n Proto)
**QEMU stub:** Synthetic events on a timer (e.g., 1Hz accel oscillating)

**Use cases:**
- **Auto-rotation** (portrait/landscape)
- **Shake gesture** (dismiss notification, wake screen)
- **Proximity** (screen off during call)
- **Light sensor** (auto-brightness — see §6)

**Phase plan:**
- **Phase 0 (Squirrel):** Mock events from QEMU
- **Phase 1 (Chimp):** I2C API layer + accelerometer (PinePhone)
- **Phase 2 (Woodpecker):** All sensors, gesture detection

---

## 4. Battery (AXP803 PMIC, I2C bus 0)

**Source:** `docs/archive/2026-06-15-plans/PLAN-hal-battery-i2c.md` (24 KB) + `PLAN-hal-battery-charging.md` (10 KB)

**HAL commands:**
- `get_battery` → `{"pct":85,"charging":true}`
- `get_charging_status` → `{"charging":true,"current_ma":1000,"voltage_mv":4200}`
- `get_battery_health` → `{"cycle_count":247,"design_capacity_mah":3000,"real_capacity_mah":2750,"degradation_pct":8.3,"temp_c":34}`

**AXP803 I2C bus:** `/dev/iic0`, slave address `0x34`
**ioctl:** `I2CRDWR` with `iic_msg` struct (read/write register)

**Charging registers:**
| Reg | Name | Bits | Value |
|---|---|---|---|
| 0x01 | Charging Status | [6] | CHARGING flag |
| 0x82 | Input Current Limit | [6:0] | 100–2500mA, step 100mA |
| 0x83 | Charging Voltage Limit | [6:5] | 4.1V/4.15V/4.2V/4.36V |
| 0x84 | Charging Current Limit | [6:0] | 300–2000mA, step 100mA |

**Smart charging:**
- 80% charge limit (extends battery life 2-3×)
- Thermal throttle: reduce current if T > 45°C
- Coulomb counter (cycle tracking) → `/data/battery/cycles.jsonl`

**Phase plan:**
- **Phase 0 (Squirrel):** stub returns 50% / not charging
- **Phase 1 (Chimp):** I2C read on PinePhone, AXP803 driver
- **Phase 2 (Woodpecker):** Smart charging + thermal protection

---

## 5. Display pipeline (fbdev → Lima/Mali)

**Source:** `docs/archive/2026-06-15-plans/PLAN-display-pipeline.md` (22 KB) + `docs/archive/2026-10-01-monorepo/PLAN-gpu-bringup.md` (kept at root)

**Critical constraint:** FreeBSD 14.x ARM64 lacks native MIPI-DSI support. Phase 1 bridges this via **fbdev-backend** (U-Boot framebuffer passthrough). Phase 2 uses **Lima/Mali-400 via UIO** for GPU acceleration.

**Phases:**

### Phase 0: QEMU QXL/SPICE (current)
- x86_64 dev, ARM64 QEMU
- QXL device + SPICE client (gtk/Qt)
- Early feature validation

### Phase 1: Software-rendered fbdev (Chimp/PinePhone MVP)
- U-Boot framebuffer passthrough
- `weston --backend=fbdev-backend.so`
- Qt6 via Weston Wayland socket
- No GPU acceleration; CPU rendering

### Phase 2: Lima/Mali-400 via UIO (Woodpecker target)
**Source:** `docs/archive/2026-06-15-plans/PLAN-mali-uio.md` (4.9 KB) + `PLAN-drm-kmod-update.md` (15 KB)

**Two paths evaluated:**
- **Path A (DRM full-stack):** Update drm-kmod to v5.15+, port Lima — **6+ months**
- **Path B (UIO userspace):** Mini kernel module + Mesa Lima UIO backend — **4 weeks**

**Recommendation:** Path B (UIO) for 2026 MVP. Path A is 2027 stretch.

**Path B architecture:**
```
Mali-400 registers → mali_uio.ko (250 LOC C, FreeBSD) → /dev/uio0
Lima (userspace) → mmap /dev/uio0 → registers/memory
Lima outputs → /dev/fb0 (framebuffer)
Weston → weston --backend=fbdev-backend.so
Qt6 → через Weston Wayland socket
```

**Insight (from PLAN-mali-uio.md):** For bsdOS (one screen, no hotplug, no Vulkan yet), drm-kmod is NOT needed. UIO bypasses the entire DRM stack.

### Phase 3: DRM full-stack (stretch)
- Update drm-kmod to v5.15+
- Port Lima to FreeBSD
- Enable Vulkan, KMS hotplug, multi-display

---

## 6. Backlight & screen timeout

**Source:** `docs/archive/2026-06-15-plans/PLAN-display-brightness.md` (13 KB) + `PLAN-screen-timeout.md` (3.1 KB)

**Backlight API:**
```sh
ioctl /dev/backlight/backlight0 BACKLIGHTSETSTATE → brightness 0-100%
sysctl hw.acpi.video.lcd0.brightness (fallback)
```

**HAL commands:**
- `backlight_get` → `{"brightness_pct":75}`
- `backlight_set` (input: 0-100) → `{"ok":true}`
- `backlight_off` / `backlight_on`
- `backlight_auto` (input: enable bool) → light sensor drives brightness

**Screen timeout state machine:**
```
[Active]  ← touch, button press (reset timer)
    ↓ (30s idle)
[Dimmed]  ← backlight 50%
    ↓ (30s more)
[Off]     ← backlight 0%, no refresh
    ↓ (proximity < 5cm OR timeout reached)
[Locked]  ← suspend discretionary jails (SIGSTOP)
    ↑ (touch, button, alarm) → wake + SIGCONT
```

**Power savings:** Backlight ~500mW @ max → save ~400mW/min when off.
**SIGSTOP jails:** Coordinate with `bsdos_lifecycled` (see `SPEC_woodpecker_power.md`).

**Phase plan:**
- **Phase 0 (Squirrel):** noop on QEMU
- **Phase 1 (Chimp):** ioctl on PinePhone, manual brightness only
- **Phase 2 (Woodpecker):** Auto-brightness (light sensor), screen timeout

---

## 7. Scheduler tuning (ULE + tickless)

**Source:** `docs/archive/2026-06-15-plans/PLAN-scheduler-ule.md` (7.4 KB) + `PLAN-tickless-scheduler.md` (4.6 KB)

**Problem:** FreeBSD default ULE optimizes for server (HZ=1000, fair scheduling, max throughput). On mobile:
- Battery drain: 1000 timer interrupts/sec wake CPU constantly
- Thermal stress: unnecessary context switches
- Wasted power: treat 100ms idle same as UI responsiveness

**Goals:**
| Scenario | Target | Mechanism |
|---|---|---|
| Screen on, active | <10ms UI latency | HZ=1000, high preemption |
| Normal idle | <1mW system idle | HZ=100, batch mode |
| Sleep (screen off) | <500μW average | HZ=15, SIGSTOP background jails |
| Thermal load | Graceful degrade | HZ→50, cap jail cpuset |

**Tickless (NOHZ) target:** ARM CPU fully stops when idle. ARM C-states:
- C1/WFI: ~50mW
- C2/WFI+clock gate: ~20mW
- C3/power gate: ~5mW
- C4/deep sleep: ~1mW

**Without tickless:** HZ=1000 → CPU never in C3+ → drain ~200mW → 5h battery
**With tickless:** idle jail → C3+ → drain ~50mW → 24h+ battery

**Phase plan:**
- **Phase 0 (Squirrel):** default ULE on QEMU
- **Phase 1 (Chimp):** HZ tuning per scenario (sysctl)
- **Phase 2 (Woodpecker):** NOHZ in custom kernel, full C-state support

---

## 8. Testing framework

**Source:** `docs/archive/2026-06-15-plans/PLAN-hal-testing.md` (10 KB, full)

**Testing pyramid:**
1. **Unit tests** (Zig `test` blocks): per-module
2. **Integration tests** (QEMU): HAL against real FreeBSD
3. **Fuzz tests** (libFuzzer-compatible): malformed input

**Coverage requirements:**
- Each `get_*` command: valid input → valid JSON, never crash
- Each `set_*` command: invalid input → `-ERR` or JSON error
- Zero-copy contract: stack-only execution, no surprise heap allocations
- Compile-time verification: type safety, layout assumptions
- Fuzzing readiness: overflow, null bytes, truncation

**QEMU stub pattern:**
```zig
const has_i2c = std.fs.openFileAbsolute("/dev/iic0", .{}) catch null;
if (has_i2c == null) {
    return stubValue();  // mock for QEMU
}
return readAxp803();  // real on PinePhone
```

---

## 9. Battery health monitoring

**Source:** `docs/archive/2026-06-15-plans/PLAN-battery-health.md` (2.3 KB, full)

**Metrics:**
| Metric | Source | Update freq | Storage |
|---|---|---|---|
| Charge cycles | AXP803 coulomb counter | per full cycle | `/data/battery/cycles.jsonl` |
| Real capacity % | AXP max/design capacity | per charge | in-memory |
| Temp history | AXP803 ADC + 5-min rolling | per minute | `/data/battery/temp_history.bin` (ring buffer) |

**Use cases:**
1. Display battery age (cycle count = degradation proxy)
2. Enforce 80% charge cap (extends lifespan 2-3×)
3. Thermal throttle during charging (T > 45°C)
4. Archive cycle logs for long-term analysis

**HAL command:** `get_battery_health` → `{"cycle_count":247,"design_capacity_mah":3000,"real_capacity_mah":2750,"degradation_pct":8.3,"temp_c":34}`

---

## 10. Source files (preserved for full detail)

```
docs/archive/2026-06-15-plans/
├── PLAN-hal-interface.md          (23 KB) — §2 HAL v1 contract
├── PLAN-hal-v2.md                 (17 KB) — §1 HAL v2 dual transport
├── PLAN-hal-testing.md            (10 KB) — §8 testing framework
├── PLAN-hal-battery-i2c.md        (24 KB) — §4 I2C + AXP803 driver
├── PLAN-hal-battery-charging.md   (10 KB) — §4 charging control
├── PLAN-sensor-fusion.md          (36 KB) — §3 I2C sensors (LIS3MDL, MXC6655, LIS2DE12)
├── PLAN-zig-hal-bringup.md        (5 KB)  — §2 command list
├── PLAN-display-pipeline.md       (22 KB) — §5 display pipeline phases
├── PLAN-display-brightness.md     (13 KB) — §6 backlight
├── PLAN-battery-health.md         (2.3 KB)— §9 health metrics
├── PLAN-screen-timeout.md         (3.1 KB)— §6 timeout state machine
├── PLAN-scheduler-ule.md          (7.4 KB)— §7 ULE tuning
├── PLAN-tickless-scheduler.md     (4.6 KB)— §7 NOHZ
├── PLAN-drm-kmod-update.md        (15 KB) — §5 GPU DRM full-stack
└── PLAN-mali-uio.md               (4.9 KB)— §5 GPU UIO MVP
```

---

## 11. Open questions

1. **Cap'n Proto schema for HAL stream:** Use existing `HardwareStatus`, `TouchEvent` from `schema.capnp`, or define new HAL-specific types?
2. **kqueue for SPI:** Is kqueue supported on FreeBSD SPI? (Yes for I2C, unclear for SPI)
3. **AXP803 I2C read latency:** 5ms per register read OK for 1Hz telemetry? (Should be)
4. **fbdev-backend on PinePhone:** Does U-Boot expose framebuffer as `/dev/fb0` directly, or do we need a custom kernel module?
5. **Mali-400 UIO module:** Is `/dev/uio0` the right interface, or do we need custom `mali_uio.ko`?
6. **Tickless on Cortex-A53:** Does FreeBSD 15.1 have NOHZ support for AArch64? (Need to verify)
7. **80% charge cap UX:** Hard limit (user can't override) or soft limit (user can disable)?

---

**Synthesized:** 2026-06-15, architect (claude-host / MiniMax M2.7).
**Source:** 15 PLAN files (~190 KB), reprocessed into ~17 KB synthesis.
**Replaces:** 15 standalone plans in archive.
