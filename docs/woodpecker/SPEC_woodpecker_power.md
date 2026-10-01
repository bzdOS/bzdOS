# SPEC_woodpecker_power.md — Comprehensive Power Management (PinePhone)

**Original plan:** 2026-06-06  
**Promoted to SPEC:** 2026-06-15 (from `docs/archive/2026-06-15-plans/PLAN-power-management.md`)  
**Status:** Active specification (Woodpecker v0.3)  
**Target hardware:** PinePhone (Allwinner A64, 3000 mAh @ 3.7V = 11.1 Wh)  
**OS:** oBzdOS (OpenBSD aarch64) — TODO: OpenBSD power management API audit needed (was FreeBSD 15.1)

**See also:**
- `docs/specs/SPEC_woodpecker_thermal.md` — companion spec (thermal throttling 70°C, emergency > 90°C)
- `docs/specs/SPEC_squirrel_lifecycled.md` (planned) — bsdos_lifecycled SIGSTOP/SIGCONT + ZSTD
- `docs/archive/2026-10-01-monorepo/PLAN-lifecycle-v2.md` — current lifecycled design
- `ROADMAP.md` — Q3 stream E + Woodpecker stage

---

## 0. Energy Budget Summary

### PinePhone 3000mAh @ 3.7V = 11.1Wh

#### Режимы потребления:

| Режим | Состояние | Мощность | Время батареи |
|---|---|---|---|
| **Active** | экран вкл, 1 jail, kern.hz=100 | 200mW | 55.5h = 2.3d |
| **Standby** | экран выкл, frozen jails | 50mW | 222h = 9.25d |
| **Ghost burst** | 3сек каждые 15мин (RF wake) | +500mW × 3s = +0.42mWh | see below |
| **Deep sleep** | C4 + все frozen, HZ=1 | 10mW | 1110h = 46d |

#### Ghost Radio коммунальность:

```
Burst: 500mW × 3 сек = 1500mJ
Интервал: 15 мин = 900 сек
Средняя прибавка: 1500mJ / 900s ≈ 1.67mW
Итого в режиме Standby: 50mW + 1.67mW = 51.67mW
```

#### Сценарии использования:

| Сценарий | Схема | Батарея |
|---|---|---|
| Heavy use (дневной сценарий) | Active 6h, Standby 18h | 200mW × 6h + 50mW × 18h = 1.2Wh + 0.9Wh = 2.1Wh (5 дней без зарядки) |
| Normal use (работа + ждущ) | Active 3h, Standby 21h | 200mW × 3h + 50mW × 21h = 0.6Wh + 1.05Wh = 1.65Wh (6.7 дней) |
| Low use (очень редко) | Standby 24h + Ghost bursts | 50mW × 24h + 0.04mWh × 96 bursts = 1.2Wh + 0.004Wh = 1.204Wh (9 дней) |
| Idle with Ghost Radio | Deep sleep + bursts | 10mW × 24h + 0.04mWh × 96 = 0.24Wh + 0.004Wh = 0.244Wh (45 дней) |

---

## 1. Архитектура Power Manager

```
power-mgrd daemon (Rust, lifecycle):
  ├─ Battery monitor (ACPI / HAL get_battery_percent)
  │  ├─ 100-20%: нормальная работа
  │  ├─ 20-10%: снизить подсветку, уведомление
  │  ├─ 10-5%:  FREEZE background jails, тёмный режим
  │  └─ < 5%:   prepare graceful shutdown
  │
  ├─ Thermal monitor (HAL get_temperature)
  │  ├─ < 60°C:  Normal (HZ=100, all jails active)
  │  ├─ 60–70°C: Warm (HZ=50)
  │  ├─ 70–80°C: Hot (FREEZE appB)
  │  ├─ 80–90°C: Critical (FREEZE appA + appB, HZ=30)
  │  └─ > 90°C:  Emergency (HZ=10, graceful shutdown)
  │
  ├─ Tickless scheduler (NOHZ)
  │  ├─ Читает kern.hz из sysctl
  │  ├─ Dynamically adjusts с dopamine-brake
  │  └─ Publishes HZ changes → bsdos/power/hz
  │
  ├─ Ghost Radio handler (при incoming call/message)
  │  ├─ Пробудить CPU из C3 на 3 сек для RF
  │  ├─ Вернуться в C3 после обработки
  │  └─ Минимизировать jitter через predictable wakeup
  │
  └─ Zenoh publisher
     ├─ bsdos/power/battery    {"pct": 45, "status": "normal"}
     ├─ bsdos/power/thermal    {"cpu_c": 42, "state": "normal"}
     ├─ bsdos/power/hz         {"kern_hz": 100, "mode": "Normal"}
     └─ bsdos/power/mode       {"current": "Normal", "available": [...]}
```

---

## 2. Power Modes (User-Visible)

| Режим | kern.hz | Jails | Screen | Throttle | Typical drain | When |
|---|---|---|---|---|---|---|
| **Performance** | 1000 | all active | full brightness | none | 400mW | active call |
| **Normal** | 100 | 1 active | adaptive | none | 200mW | default |
| **Power Save** | 15 | frozen | dim 30% | kern.hz=50 | 80mW | low battery |
| **Ultra Save** | 1 | all frozen | off | kern.hz=10 | 15mW | <5% battery |
| **Ghost Mode** | 100 burst | all frozen | off | 5mW + burst | 5mW baseline | idle with incoming calls |

**User-selectable через UI or Settings:**
- Normal / Power Save / Ghost Mode
- Auto-select: Normal (>50%), Power Save (20-50%), Ultra Save (<20%)

---

## 3. Component Integration

### 3.1 Tickless Scheduler (PLAN-tickless-scheduler.md)

**Status:** Foundation.

Что уже есть:
- `dopamine-brake` daemon снижает kern.hz при doomscroll
- lifecycled может замораживать jails via SIGSTOP

Что нужно:
1. **FreeBSD 15.1 NOHZ**: kern.hz dynamically → CPU enters C-states
2. **C-state support на Allwinner A64**: WFI (C1), WFI+clock gate (C2), power gate (C3), deep sleep (C4)
3. **Integration**: lifecycled монитор HZ + thermal → Zenoh

| Threshold | kern.hz | Action | C-states |
|---|---|---|---|
| Screen on, user input | 100 | normal | C1/C2 |
| Screen on, idle scrolling | 15 | dopamine-brake | C2/C3 |
| Screen off, locked | 1 | automatic FREEZE | C3/C4 |
| Ghost Radio burst (3s) | 100 | brief wakeup | C1 |

### 3.2 ZFS Swap (PLAN-zfs-swap.md)

**Status:** Ready to implement.

```sh
# Create 2GB zvol with ZSTD-3 compression
zfs create -V 2G \
    -o compression=zstd-3 \
    -o logbias=throughput \
    -o sync=disabled \
    bsdos/swap

# Activate
swapon /dev/zvol/bsdos/swap
echo '/dev/zvol/bsdos/swap none swap sw 0 0' >> /etc/fstab
```

**Benefit:** 2GB zvol физически занимает ~600-700MB (3:1 ratio на типичных данных).

**Integration:**
- lifecycle monitor: `swapinfo` → Zenoh `bsdos/power/swap_used`
- oBsdOS: encrypted zvol + `crypto-sleep` unload key при screen lock

### 3.3 RCTL Jail Budgets (PLAN-jail-memory-budget.md)

**Status:** Kernel support есть (RCTL в BSDOS-arm64).

Что нужно:
1. lifecycled применяет rctl limits при jail start:
   ```sh
   rctl -a jail:appA:memoryuse:deny=200m
   rctl -a jail:appB:memoryuse:deny=150m
   ```

2. HAL команда `get_jail_memory <name>` → JSON

3. Eliminate WakeLock API полностью (no `prevent_freeze()` call)

**Impact на energy:**
- Jail не может занять весь RAM → no emergency OOM kills
- Freeze по бюджету → jails freeze gracefully → CPU C3/C4 deeper

### 3.4 Thermal Management (PLAN-thermal-management.md)

**Status:** Foundation + integration.

HAL команда `get_temperature`:
```json
{
  "ok": true,
  "values": {
    "cpu_c": 42,
    "gpu_c": 45,
    "board_c": 38
  },
  "throttle_state": "normal"
}
```

lifecycled ThermalMonitor:
- Reads every 5 sec
- Applies policy: throttle HZ, FREEZE jails, emergency shutdown
- Publishes `bsdos/thermal/cpu` + `bsdos/thermal/alert` via Zenoh

Policy:
```
< 60°C:   Normal (HZ=100, all active)
60-70°C:  Warm (HZ=50)
70-80°C:  Hot (FREEZE appB)
80-90°C:  Critical (FREEZE appA+appB, HZ=30)
> 90°C:   Emergency (HZ=10, graceful shutdown)
```

### 3.5 Ghost Radio Integration

**Status:** Design (PLAN-telephony.md reference).

Ghost Radio: minimal RF activity каждые 15 мин (3 сек window) для incoming calls/messages.

**Power implication:**
- RF device wakes CPU из C3/C4
- 500mW × 3s = 1500mJ per burst
- 96 bursts/day = 144mJ average

**Integration in power-mgrd:**
1. Listen on Zenoh: `bsdos/radio/incoming_call`
2. Unfreeze 1 jail (telephony), allow RF
3. Process (ring tone, notification)
4. Refreeze, return to C3/C4

**Wakeup timing:**
- Must be predictable (not random jitter)
- Use HAL timer (not kernel tick) для precise 3sec window
- Minimize tail energy (avoid cascading app wakeups)

---

## 4. Detailed Phases

### Phase 0: Foundation (1–2 weeks)

| Task | Gate | Owner |
|---|---|---|
| **HAL thermal.zig** | stub returns 40°C, JSON OK | HAL team |
| **lifecycled ThermalMonitor** (Rust) | compiles, thread spawns | lifecycle team |
| **ZFS swap zvol** | swapon works, swapinfo shows | VM setup |
| **RCTL in KERNCONF** | already present (✅) | — |
| **Zenoh schemas** | `bsdos/power/*`, `bsdos/thermal/*` | broker team |
| **Gate: demo-smoke passes** | no compilation, no crashes | all |

### Phase 1: Dynamic HZ + Jail Freeze (2–3 weeks)

| Task | Gate | Owner |
|---|---|---|
| **kern.hz dynamic** | sysctl kern.hz=100/50/15/1 works | lifecycle |
| **lifecycled applies HZ** | during thermal transitions | thermal monitor |
| **Jail freeze via SIGSTOP** | appA/appB freeze/thaw works | lifecycle |
| **Thermal throttling policy** | <60→HZ=100, 70–80→FREEZE appB | ThermalMonitor |
| **Battery monitor loop** | reads battery%, publishes to Zenoh | lifecycle |
| **Gate: real hardware (QEMU)** | sysctl HZ changes live | all |

### Phase 2: C-states on ARM (2–3 weeks)

| Task | Gate | Owner |
|---|---|---|
| **FreeBSD 15.1 arm64 NOHZ** | kern.hz=1 → CPU enters C states | FreeBSD config |
| **Allwinner PSCI support** | check `dev.cpu.0.cx_usage` non-zero | bsdOS kernel |
| **WFI instruction** | CPU halts when no runnable, drains drop | arch |
| **Measure idle power** | QEMU: 40mW baseline (estimate) | testing |
| **Gate: C3 visible in dmesg** | boot log shows C-state entries | benchmarking |

### Phase 3: Ghost Radio + Full Integration (2–3 weeks)

| Task | Gate | Owner |
|---|---|---|
| **Ghost Radio wakeup handler** | listen `bsdos/radio/incoming_call` | telephony |
| **Unfreeze 1 jail on RF** | modem jail unfrozen, RF enabled | lifecycle |
| **3-sec RF window** | HAL timer accurate | HAL |
| **Minimize tail energy** | jails refreeze quickly, C3 resumed | lifecycle |
| **UI power indicator** | Status bar shows battery%, mode | UI team |
| **Zenoh telemetry** | bsdos-core subscribes, real-time gauge | UI |
| **Gate: real PinePhone test** | battery drain < 50mW idle with Ghost | all |

### Phase 4: oBsdOS + Encrypted Swap (1–2 weeks)

| Task | Gate | Owner |
|---|---|---|
| **ZFS encryption on swap** | `zfs create ... encryption=aes-256-gcm` | oBsdOS |
| **crypto-sleep unload key** | screen lock → swap not readable | security |
| **SEALED mode policy** | no keylogging possible via swap | paranoid mode |
| **Gate: oBsdOS smoke test** | crashes go to encrypted swap, unreadable | security team |

---

## 5. Implementation Details

### 5.1 Battery Monitor in lifecycled

```rust
// In lifecycled/src/main.rs

struct BatteryMonitor {
    last_pct: u8,
    last_check_ts: u64,
    low_battery_warned: bool,
    critical_threshold: u8,  // 10%
}

impl BatteryMonitor {
    pub fn update(&mut self) -> Option<PowerAction> {
        let pct = get_battery_percent_from_hal()?;
        self.last_pct = pct;

        // Publish to Zenoh
        publish_battery_event(pct);

        // Check thresholds
        if pct < 5 {
            return Some(PowerAction::PrepareShutdown);
        }
        if pct < 10 && !self.low_battery_warned {
            self.low_battery_warned = true;
            return Some(PowerAction::CriticalAlert);
        }
        if pct < 20 {
            return Some(PowerAction::DimScreen);
        }
        if pct > 50 {
            self.low_battery_warned = false;
        }

        None
    }
}

fn get_battery_percent_from_hal() -> Result<u8, Box<dyn std::error::Error>> {
    // Query HAL: {"cmd":"get_battery_percent"}
    // Parse JSON, return value
    todo!()
}

fn publish_battery_event(pct: u8) {
    // Zenoh: bsdos/power/battery
    // {"pct": pct, "status": status_str(), "timestamp": now_secs()}
}
```

### 5.2 ThermalMonitor Integration

Already detailed in PLAN-thermal-management.md §3. Excerpt:

```rust
let thermal_monitor = Arc::new(Mutex::new(ThermalMonitor::new()));

// Spawn monitor thread
std::thread::spawn(move || {
    loop {
        std::thread::sleep(Duration::from_secs(5));
        if let Ok(temp) = get_temperature_from_hal() {
            let mut monitor = thermal_monitor.lock().unwrap();
            if let Some(action) = monitor.update(temp) {
                apply_thermal_action(&action);
                publish_thermal_alert(&action, temp);
            }
        }
    }
});
```

Actions:
- **ClearThrottle**: sysctl kern.hz=100
- **SetHz(hz)**: sysctl kern.hz=hz (50, 30, etc.)
- **FreezeAppB**: kill -STOP appB init
- **FreezeAppAandB**: both
- **EmergencyShutdown**: sleep 2s, then `shutdown -h now`

### 5.3 Jail Freeze/Thaw via lifecycled

```rust
fn freeze_jail(name: &str) -> Result<(), Box<dyn std::error::Error>> {
    // Get jail ID
    let jid = get_jail_id(name)?;
    
    // Send SIGSTOP to jail init
    unsafe {
        libc::kill(jid as i32, libc::SIGSTOP);
    }
    
    eprintln!("[lifecycle] Froze jail {}", name);
    Ok(())
}

fn thaw_jail(name: &str) -> Result<(), Box<dyn std::error::Error>> {
    let jid = get_jail_id(name)?;
    unsafe {
        libc::kill(jid as i32, libc::SIGCONT);
    }
    eprintln!("[lifecycle] Thawed jail {}", name);
    Ok(())
}
```

### 5.4 Ghost Radio Wakeup Handler

```rust
// Subscribe to incoming call event
zenoh_subscriber("bsdos/radio/incoming_call", |payload| {
    eprintln!("[power] Incoming call, unfreezing telephony jail");
    
    // Unfreeze modem/telephony jail for 3 seconds
    let _ = thaw_jail("appTelephony");
    
    // Allow RF device to wake (minimal power draw during window)
    set_rf_active(true);
    
    // Wait 3 seconds (or until call processing done)
    std::thread::sleep(Duration::from_secs(3));
    
    // Refreeze
    let _ = freeze_jail("appTelephony");
    set_rf_active(false);
    
    eprintln!("[power] Returning to deep sleep after RF window");
});
```

### 5.5 Power Mode Selection

```rust
pub enum PowerMode {
    Performance,  // HZ=1000, all jails, full brightness
    Normal,       // HZ=100, 1-2 jails, adaptive screen
    PowerSave,    // HZ=15, frozen jails, dim screen
    UltraSave,    // HZ=1, all frozen, screen off
    GhostMode,    // HZ=100 burst, all frozen, minimal RF
}

impl PowerMode {
    pub fn from_battery_pct(pct: u8) -> Self {
        match pct {
            80..=100 => PowerMode::Performance,  // User plugged in charger
            51..=79  => PowerMode::Normal,        // Normal use
            21..=50  => PowerMode::PowerSave,     // Battery warning
            6..=20   => PowerMode::UltraSave,     // Critical
            0..=5    => PowerMode::UltraSave,     // Emergency
        }
    }

    pub fn apply(&self) -> Result<(), Box<dyn std::error::Error>> {
        match self {
            PowerMode::Performance => {
                sysctl_set("kern.hz", "1000")?;
                thaw_all_jails()?;
                set_screen_brightness(100)?;
            }
            PowerMode::Normal => {
                sysctl_set("kern.hz", "100")?;
                thaw_jails(&["appA"])?;  // one active
                set_screen_brightness(adaptive)?;
            }
            PowerMode::PowerSave => {
                sysctl_set("kern.hz", "15")?;
                freeze_all_jails()?;
                set_screen_brightness(30)?;
            }
            PowerMode::UltraSave => {
                sysctl_set("kern.hz", "1")?;
                freeze_all_jails()?;
                set_screen_brightness(0)?;
            }
            PowerMode::GhostMode => {
                sysctl_set("kern.hz", "1")?;  // baseline
                freeze_all_jails()?;
                set_screen_brightness(0)?;
                // RF bursts handled by separate wakeup handler
            }
        }
        Ok(())
    }
}
```

---

## 6. Zenoh Schema

### 6.1 Topics

```
bsdos/power/battery
  {"pct": 45, "status": "normal|low|critical", "timestamp": 1717689600}

bsdos/power/thermal
  {"cpu_c": 42, "gpu_c": 45, "board_c": 38, "state": "normal|warm|hot|critical", "timestamp": ...}

bsdos/power/hz
  {"kern_hz": 100, "mode": "Normal", "timestamp": ...}

bsdos/power/mode
  {"current": "Normal", "available": ["Performance", "Normal", "PowerSave", "UltraSave", "GhostMode"], "auto_select": true, "timestamp": ...}

bsdos/power/jails
  {"appA": {"frozen": false, "mem_mb": 150}, "appB": {"frozen": true, "mem_mb": 50}, "timestamp": ...}

bsdos/thermal/alert
  (при пороге)
  {"temp_c": 82, "action": "freezing_jails", "jails_frozen": ["appA", "appB"], "timestamp": ...}
```

### 6.2 UI Subscription

bsdos-core (Rust) subscribes to all topics, updates StatusBar:
```
[🔋45%] [🌡️42°C] [⚡Normal] [🔇Ghost]
```

Click mode → modal to select PowerMode.

---

## 7. Lifecycle Daemon Command Additions

Add to lifecycled IPC command set:

```
power_mode get
  ← {"ok":true,"current":"Normal","available":[...]}

power_mode set <mode>
  ← {"ok":true,"new_mode":"PowerSave"}

battery_status
  ← {"ok":true,"pct":45,"status":"normal"}

thermal_status
  ← {"ok":true,"cpu_c":42,"state":"normal"}

jail_freeze <name>
  ← {"ok":true}

jail_thaw <name>
  ← {"ok":true}

sysctl_hz <hz>
  ← {"ok":true,"new_hz":100}
```

---

## 8. Testing & Validation

### 8.1 Unit Tests (Rust)

```rust
#[test]
fn test_battery_threshold_actions() {
    let mut monitor = BatteryMonitor::new();
    assert_eq!(monitor.update(45), None);           // Normal
    assert!(monitor.update(15).is_some());          // CriticalAlert
    assert_eq!(monitor.update(2), Some(PrepareShutdown));
}

#[test]
fn test_thermal_hysteresis() {
    let mut monitor = ThermalMonitor::new();
    assert_eq!(monitor.update(65), Some(SetHz(50)));    // 60–70
    assert_eq!(monitor.update(68), None);               // Same state
    assert_eq!(monitor.update(72), Some(FreezeAppB));   // 70–80
    assert_eq!(monitor.update(65), None);               // Hysteresis (margin=5)
}

#[test]
fn test_power_mode_auto_select() {
    assert_eq!(PowerMode::from_battery_pct(90), PowerMode::Performance);
    assert_eq!(PowerMode::from_battery_pct(50), PowerMode::Normal);
    assert_eq!(PowerMode::from_battery_pct(15), PowerMode::UltraSave);
}
```

### 8.2 QEMU Integration Tests

```bash
# Boot QEMU
make vm-start && make vm-wait

# Test 1: Battery query
ssh freebsd@localhost -p 2222 \
  'echo "{\"cmd\":\"get_battery_percent\"}" | nc -U /var/run/bsdos-hal.sock'

# Test 2: Thermal query
ssh freebsd@localhost -p 2222 \
  'echo "{\"cmd\":\"get_temperature\"}" | nc -U /var/run/bsdos-hal.sock'

# Test 3: HZ change
ssh freebsd@localhost -p 2222 \
  'sysctl kern.hz=100 && sysctl -n kern.hz'

# Test 4: Jail freeze
ssh freebsd@localhost -p 2222 \
  'jls && kill -STOP $(jls -j appA -p)'  # Freeze appA

# Test 5: Power mode set
ssh freebsd@localhost -p 2222 \
  'nc -U /tmp/lifecycled.sock <<< "power_mode set PowerSave"'
```

### 8.3 Real Hardware Tests (PinePhone)

```bash
# Boot PinePhone with image
freebsd# sysctl kern.hz
# → kern.hz: 100

# Set low value
freebsd# sysctl kern.hz=1
# → kern.hz: 1 → 100 (changed)

# Measure idle power draw
freebsd# powertop          # or custom meter if available
# Normal: ~200mW
# HZ=1:   ~80mW
# HZ=1 + all jails frozen: ~50mW
# HZ=1 + all frozen + C3: ~15mW

# Monitor thermal
freebsd# while true; do \
  echo '{"cmd":"get_temperature"}' | nc -U /var/run/bsdos-hal.sock | jq '.values.cpu_c'; \
  sleep 5; done

# Trigger thermal throttling (stress test)
freebsd# stress-ng --cpu 4 --timeout 60s
# Expect: kern.hz drops, appB freezes at 70°C, emergency shutdown at 90°C
```

---

## 9. Risk Mitigation

| Risk | Likelihood | Impact | Mitigation |
|---|---|---|---|
| C-states break GPIO wakeup (Ghost Radio) | Medium | Critical | Test wakeup timing on real hardware, fallback to HZ=15 |
| HZ=1 causes timing skew in VoIP | Low | High | Don't use HZ=1 during active calls, switch to HZ=100 |
| Jail freeze race with syscall | Low | Medium | Use posix_spawn guard, test with stress-ng |
| ZFS swap performance degrades | Medium | Medium | Monitor swap usage in Zenoh, alert at 80% full |
| Battery monitor hangs (I2C timeout) | Low | Medium | Add 2-sec timeout, fallback to cached value |
| Thermal sensor absent on QEMU | High | Low | Implement stub returning 40°C, THERMAL_TEST_TEMP env var |

---

## 10. Integration Checklist

Before each phase gate:

- [ ] All components compile (Rust, Zig)
- [ ] No unwrap() in error paths
- [ ] Zenoh topics publish correctly
- [ ] HAL commands respond to JSON queries
- [ ] sysctl values change live
- [ ] Jail freeze/thaw doesn't deadlock
- [ ] No log spam (debug only in test mode)
- [ ] Demo smoke test passes
- [ ] Real hardware (QEMU) boots and runs

---

## 11. Related Plans

- **[PLAN-tickless-scheduler.md](PLAN-tickless-scheduler.md)** — kern.hz dynamics, ARM C-states
- **[PLAN-zfs-swap.md](PLAN-zfs-swap.md)** — ZFS zvol swap, ZSTD compression
- **[PLAN-jail-memory-budget.md](PLAN-jail-memory-budget.md)** — RCTL budgets, WakeLock elimination
- **[PLAN-thermal-management.md](PLAN-thermal-management.md)** — detailed thermal policy, HAL integration
- **[PLAN-telephony.md](PLAN-telephony.md)** — Ghost Radio implementation
- **[docs/archive/2026-10-01-monorepo/PLAN-lifecycle-v2.md](docs/archive/2026-10-01-monorepo/PLAN-lifecycle-v2.md)** — lifecycled FREEZE/THAW commands
- **[PLAN-zig-hal-bringup.md](PLAN-zig-hal-bringup.md)** — HAL thermal.zig, battery.zig

---

## 12. Success Metrics

| Metric | Target | Measurement |
|---|---|---|
| Idle power (screen off, all frozen, C3+) | < 50mW | powertop / ammeter |
| Deep sleep (C4, HZ=1) | < 15mW | 46+ days battery |
| Standby battery life (9 days) | 9d @ Ghost bursts | real-world drain test |
| Thermal safety margin | 90°C emergency | stress-ng + dmesg |
| Zero WakeLock API | 100% removed | codebase grep |
| Zenoh telemetry latency | < 100ms | broker timestamps |
| Jail freeze latency | < 500ms | SIGSTOP → frozen state |

---

*Дата: 2026-06-06. Статус: Roadmap (4 фазы, 8–12 недель).
Зависит: FreeBSD 15.1, Allwinner PSCI support, Zenoh broker ready.*

**Связано:** [docs/archive/2026-10-01-monorepo/PLAN-lifecycle-v2.md](docs/archive/2026-10-01-monorepo/PLAN-lifecycle-v2.md), [PLAN-telephony.md](PLAN-telephony.md), [schema.capnp](schema.capnp).

**Авторы:** bsdOS power team (HAL, lifecycle, thermal).
