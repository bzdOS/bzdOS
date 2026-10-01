# SPEC_woodpecker_thermal.md — Thermal Management на ARM (CPU temp + throttling)

**Original plan:** 2026-06-06  
**Promoted to SPEC:** 2026-06-15 (from `docs/archive/2026-06-15-plans/PLAN-thermal-management.md`)  
**Status:** Active specification (Woodpecker v0.3)  
**Target hardware:** PinePhone (Allwinner A64, Cortex-A53, 3000 mAh, no active cooling) — oBzdOS (OpenBSD)

**See also:**
- `docs/specs/SPEC_woodpecker_power.md` — companion spec (power budget 200mW active, 50mW standby)
- `docs/specs/SPEC_squirrel_lifecycled.md` (planned) — bsdos_lifecycled SIGSTOP/SIGCONT + ZSTD
- `docs/archive/2026-10-01-monorepo/PLAN-lifecycle-v2.md` — current lifecycled design (deferred → spec)
- `ROADMAP.md` — Q3 stream E (multi-agent) + Woodpecker stage

---

## 0. Что делаем и что НЕ делаем

### Делаем
1. **HAL get_temperature команда** — чтение датчиков CPU/GPU/board через SoC тепловой регистр или `/dev/iic0`.
2. **lifecycled thermal monitor** — каждые 5 сек получать температуру, применять throttling policy.
3. **Throttling policy** — снижение kern.hz, FREEZE jails при 70°C, emergency shutdown > 90°C.
4. **Zenoh thermal events** — публикация `bsdos/thermal/cpu`, `bsdos/thermal/alert` для UI.
5. **QEMU stub** — на VM возвращаем сымитированные значения (40°C нормальная, 95°C для теста).

### НЕ делаем (отложено)
- **Активное охлаждение** (вентилятор управление) — для PinePhone нет официального вентилятора.
- **Frequency scaling через cpufreq(4)** — сложная в FreeBSD, вместо этого снижаем kern.hz.
- **GPU thermal zone** — на Allwinner есть, но MVP только CPU.
- **Voltage reduction** — требует PMIC регулировки, будет в phase 3.
- **Hibernation** — freeze jails может использовать ZFS snapshots (уже есть в lifecycle).

---

## 1. FreeBSD thermal API (Allwinner A64)

### 1.1 Датчики на SoC

**Путь:** через sysctl (если ACPI thermal zone) или через `/dev/iic0` (прямой читай регистра).

На Allwinner A64 встроен thermal sensor, обычно доступный через:
```sh
# Метод 1: sysctl (если ACPI инициирован)
sysctl -n dev.cpu.0.temperature
# → 42.0 (в °C)

# Метод 2: hwmon (Linux-style, может отсутствовать на FreeBSD)
# /sys/class/hwmon/hwmon0/temp*   (НЕ ИСПОЛЬЗУЕТСЯ в FreeBSD, только на Linux)

# Метод 3: Прямой ввод-вывод через /dev/iic0 (Allwinner A64 thermal PMIC)
# Адрес датчика: обычно встроен в AXP803 @ 0x34 или отдельный THM @ 0x70
```

### 1.2 Allwinner A64 thermal sensor

**Регистры на AXP803 (при наличии):**
```
0x5E:  INTERNAL_TEMP_H   (биты 15:8)
0x5F:  INTERNAL_TEMP_L   (биты  7:0)
→ Температура = (TEMP_H << 4 | (TEMP_L >> 4)) — 1437 / 8   (из datasheet)
```

**На QEMU:** датчика нет → fallback на stub (40°C по умолчанию).

### 1.3 Проверка при загрузке

```bash
freebsd# sysctl dev.cpu
# Ищем temperature в выводе

freebsd# i2cdetect -y 0
# Ищем адреса, где 34 = AXP803, 70 может быть отдельный thermal IC
```

---

## 2. HAL команда get_temperature

### 2.1 JSON RPC

```json
Запрос:  {"cmd":"get_temperature"}

Ответ (успешно):
{
  "ok": true,
  "values": {
    "cpu_c": 42,
    "gpu_c": 45,
    "board_c": 38
  },
  "throttle_state": "normal"
}

Ответ (ошибка):
{
  "ok": false,
  "error": "thermal_sensor_unavailable"
}
```

### 2.2 Реализация в `src/thermal.zig`

```zig
const std = @import("std");
const i2c = @import("i2c.zig");

const ThermalError = error{
    SensorNotFound,
    ReadError,
    InvalidValue,
};

pub const TemperatureReading = struct {
    cpu_c: i16,
    gpu_c: i16,
    board_c: i16,
    throttle_state: []const u8,  // "normal", "warm", "hot", "critical"
};

const AXP803_ADDR: u8 = 0x34;
const AXP803_TEMP_H: u8 = 0x5E;
const AXP803_TEMP_L: u8 = 0x5F;

/// Преобразование регистров в °C
fn rawToC(temp_h: u8, temp_l: u8) i16 {
    const raw = (@as(i16, temp_h) << 4) | (@as(i16, temp_l >> 4));
    // Формула из datasheet: (raw - 1437) / 8
    return @divExact(raw - 1437, 8);
}

/// Прочитать CPU temperature через AXP803 I2C
pub fn readCpuTemp(allocator: std.mem.Allocator) ThermalError!i16 {
    var i2c_dev = i2c.I2CDevice.open(allocator, "/dev/iic0", AXP803_ADDR) catch {
        return ThermalError.SensorNotFound;
    };
    defer i2c_dev.close();

    var temp_h_buf: [1]u8 = undefined;
    var temp_l_buf: [1]u8 = undefined;

    _ = i2c_dev.readReg(AXP803_TEMP_H, &temp_h_buf) catch {
        return ThermalError.ReadError;
    };

    _ = i2c_dev.readReg(AXP803_TEMP_L, &temp_l_buf) catch {
        return ThermalError.ReadError;
    };

    return rawToC(temp_h_buf[0], temp_l_buf[0]);
}

/// QEMU stub (датчика нет)
pub fn readCpuTempStub() i16 {
    return 40;  // 40°C при нормальной работе
}

/// Получить полное показание (CPU, GPU, board)
pub fn getTemperature(allocator: std.mem.Allocator) TemperatureReading {
    // На PinePhone: CPU и GPU обычно на одном датчике
    var cpu_c: i16 = undefined;
    var gpu_c: i16 = undefined;
    var board_c: i16 = undefined;

    cpu_c = readCpuTemp(allocator) catch |_| readCpuTempStub();

    // GPU = CPU (одна кристалл на A64)
    gpu_c = cpu_c;

    // Board sensor (опционально, для MVP просто на 3°C ниже)
    board_c = if (cpu_c > 3) cpu_c - 3 else 37;

    // Определить throttle state
    const throttle_state = if (cpu_c > 90)
        "critical"
    else if (cpu_c > 80)
        "hot"
    else if (cpu_c > 70)
        "warm"
    else
        "normal";

    return TemperatureReading{
        .cpu_c = cpu_c,
        .gpu_c = gpu_c,
        .board_c = board_c,
        .throttle_state = throttle_state,
    };
}
```

### 2.3 Интеграция в main.zig

```zig
const thermal = @import("thermal.zig");

pub fn handleCommand(allocator: std.mem.Allocator, cmd_str: []const u8) !void {
    if (std.mem.eql(u8, cmd_str, "get_temperature")) {
        const reading = thermal.getTemperature(allocator);

        var response_buf: [512]u8 = undefined;
        const len = try std.fmt.bufPrint(
            &response_buf,
            "{{\"ok\":true,\"values\":{{\"cpu_c\":{d},\"gpu_c\":{d},\"board_c\":{d}}},\"throttle_state\":\"{s}\"}}\n",
            .{ reading.cpu_c, reading.gpu_c, reading.board_c, reading.throttle_state },
        );

        _ = try socket.write(response_buf[0..len]);
    }
}
```

---

## 3. lifecycled thermal monitor

### 3.1 Thermal throttling policy

```
Диапазон °C    | Действие                            | kern.hz
═══════════════════════════════════════════════════════════════
< 60           | Нормальная работа                   | 100 (default)
60–70          | Снизить HZ на 50%                   | 50
70–80          | FREEZE appB (фоновые jails)         | 50
80–90          | FREEZE appA + appB + warning event  | 30
> 90           | Emergency shutdown (graceful)       | 10

Гистерезис: при охлаждении ниже порога - 5°C, вернуться к предыдущему состоянию
```

### 3.2 Структура в lifecycled/src/main.rs

```rust
use std::sync::{Arc, Mutex};

#[derive(Clone, Debug)]
pub enum ThermalState {
    Normal,      // < 60°C
    Warm,        // 60-70°C, HZ=50
    Hot,         // 70-80°C, FREEZE appB
    Critical,    // 80-90°C, FREEZE appA + appB
    Emergency,   // > 90°C, emergency shutdown
}

pub struct ThermalMonitor {
    current_state: ThermalState,
    cpu_temp: i16,
    last_transition_ts: u64,
    hysteresis_margin: i16,  // 5°C
}

impl ThermalMonitor {
    pub fn new() -> Self {
        ThermalMonitor {
            current_state: ThermalState::Normal,
            cpu_temp: 40,
            last_transition_ts: now_secs(),
            hysteresis_margin: 5,
        }
    }

    pub fn update(&mut self, new_temp: i16) -> Option<ThermalAction> {
        self.cpu_temp = new_temp;
        self.evaluate_state()
    }

    fn evaluate_state(&mut self) -> Option<ThermalAction> {
        let next_state = match self.cpu_temp {
            0..=59 => ThermalState::Normal,
            60..=69 => ThermalState::Warm,
            70..=79 => ThermalState::Hot,
            80..=89 => ThermalState::Critical,
            _ => ThermalState::Emergency,
        };

        if self.state_changed(&next_state) {
            self.current_state = next_state;
            return Some(self.action_for_state());
        }
        None
    }

    fn action_for_state(&self) -> ThermalAction {
        match self.current_state {
            ThermalState::Normal => ThermalAction::ClearThrottle,
            ThermalState::Warm => ThermalAction::SetHz(50),
            ThermalState::Hot => ThermalAction::FreezeAppB,
            ThermalState::Critical => ThermalAction::FreezeAppAandB,
            ThermalState::Emergency => ThermalAction::EmergencyShutdown,
        }
    }
}

#[derive(Debug)]
pub enum ThermalAction {
    ClearThrottle,
    SetHz(u32),
    FreezeAppB,
    FreezeAppAandB,
    EmergencyShutdown,
}
```

### 3.3 Интеграция монитора в main.rs

```rust
// В main() после инициализации:

let thermal_monitor = Arc::new(Mutex::new(ThermalMonitor::new()));
let monitor_clone = thermal_monitor.clone();

// Spawn thermal monitor thread
std::thread::spawn(move || {
    loop {
        std::thread::sleep(std::time::Duration::from_secs(5));

        // Получить текущую температуру из HAL
        if let Ok(temp) = get_temperature_from_hal() {
            let mut monitor = monitor_clone.lock().unwrap();
            if let Some(action) = monitor.update(temp) {
                apply_thermal_action(&action);
                // Публиковать событие в Zenoh
                publish_thermal_alert(&action, temp);
            }
        }
    }
});

fn apply_thermal_action(action: &ThermalAction) {
    match action {
        ThermalAction::ClearThrottle => {
            let _ = sysctl_set("kern.hz", "100");
            eprintln!("[thermal] Cleared throttle, returning to normal operation");
        }
        ThermalAction::SetHz(hz) => {
            let hz_str = hz.to_string();
            let _ = sysctl_set("kern.hz", &hz_str);
            eprintln!("[thermal] Throttling: kern.hz = {}", hz);
        }
        ThermalAction::FreezeAppB => {
            freeze_jail("appB");
            eprintln!("[thermal] FREEZE appB (70°C threshold)");
        }
        ThermalAction::FreezeAppAandB => {
            freeze_jail("appA");
            freeze_jail("appB");
            eprintln!("[thermal] FREEZE appA + appB (80°C threshold)");
        }
        ThermalAction::EmergencyShutdown => {
            eprintln!("[thermal] EMERGENCY SHUTDOWN (>90°C)");
            let _ = sysctl_set("kern.hz", "10");
            std::thread::sleep(std::time::Duration::from_secs(2));
            let _ = std::process::Command::new("shutdown")
                .args(&["-h", "now", "Thermal emergency"])
                .status();
        }
    }
}

fn publish_thermal_alert(action: &ThermalAction, temp: i16) {
    // Отправить в Zenoh: bsdos/thermal/alert
    // Пример JSON:
    // {"temp_c": 82, "action": "freezing_jails", "timestamp": 1717689600}
}

fn get_temperature_from_hal() -> Result<i16, Box<dyn std::error::Error>> {
    // Отправить JSON команду `{"cmd":"get_temperature"}` в HAL через Unix socket
    // Распарсить JSON ответ, вернуть cpu_c
    todo!()
}
```

---

## 4. Zenoh thermal events

### 4.1 Event schema

```
Ключ: bsdos/thermal/cpu
Payload:
{
  "temp_c": 42,
  "state": "normal",
  "timestamp": 1717689600
}

Ключ: bsdos/thermal/alert
Payload (только при пороге):
{
  "temp_c": 82,
  "action": "freezing_jails",
  "jails_frozen": ["appA", "appB"],
  "timestamp": 1717689600
}
```

### 4.2 Публикация в lifecycled

```rust
use zenoh::prelude::*;

pub fn publish_thermal_event(temp: i16, state: &str, alert: Option<&str>) {
    let rt = tokio::runtime::Handle::current();
    rt.block_on(async {
        if let Ok(session) = zenoh::open(zenoh::config::Config::default()).await {
            let cpu_payload = serde_json::json!({
                "temp_c": temp,
                "state": state,
                "timestamp": now_secs(),
            }).to_string();

            let _ = session
                .put("bsdos/thermal/cpu", cpu_payload)
                .await;

            if let Some(action) = alert {
                let alert_payload = serde_json::json!({
                    "temp_c": temp,
                    "action": action,
                    "timestamp": now_secs(),
                }).to_string();

                let _ = session
                    .put("bsdos/thermal/alert", alert_payload)
                    .await;
            }
        }
    });
}
```

---

## 5. QEMU stub поведение

На QEMU `/dev/iic0` может быть недоступен → fallback на сымитированные значения.

### 5.1 Тестирование throttling

```bash
# Тест 1: Normal (40°C)
make vm-start && make vm-wait

# В QEMU консоли:
echo '{"cmd":"get_temperature"}' | nc -U /var/run/bsdos-hal.sock
# Ожидаем: {"ok":true,...,"cpu_c":40,"throttle_state":"normal"}

# Тест 2: Warm (65°C)
# Модифицировать thermal.zig stub для теста:
//   return 65;  // вместо 40

# Тест 3: Emergency (95°C)
//   return 95;
# Ожидаем: {"throttle_state":"critical"}
```

### 5.2 Mock модифицирование для теста

```zig
// В thermal.zig (верхний уровень)
const FORCE_TEMP = @import("builtin").mode == .Debug;  // или env var
const OVERRIDE_TEMP: i16 = std.os.getenv("THERMAL_TEST_TEMP") orelse 40;

pub fn readCpuTempStub() i16 {
    if (FORCE_TEMP) {
        return OVERRIDE_TEMP;
    }
    return 40;
}
```

Запуск с переопределением:
```bash
THERMAL_TEST_TEMP=95 ./bsdos-hal  # Аварийное состояние
```

---

## 6. Фазовый план

### Phase 0: Foundation (Week 1)

| Задача | Гейт | Зависит |
|---|---|---|
| Написать `src/thermal.zig` (чтение датчика + policy) | компилится без ошибок | i2c.zig |
| Интегрировать HAL команду `get_temperature` | stub возвращает 40°C | thermal.zig |
| Проверить на QEMU | JSON ответ корректен | smoke test |
| **Гейт: QEMU возвращает température** | THERMAL_TEST_TEMP работает | все выше |

### Phase 1: lifecycled integration (Week 2)

| Задача | Гейт | Зависит |
|---|---|---|
| Добавить ThermalMonitor в lifecycled | компилится | thermal.zig phase 0 |
| Spawn monitor thread (каждые 5 сек) | монитор работает в фоне | ThermalMonitor |
| Реализовать throttling (kern.hz) | sysctl изменяется | monitor thread |
| Freeze/unfreeze jails при пороге | appB замораживается при 70°C | sysctl + jail control |
| **Гейт: demo-smoke проходит без race** | no memory-monitor kills | все выше |

### Phase 2: Zenoh integration (Week 3)

| Задача | Гейт | Зависит |
|---|---|---|
| Добавить Zenoh publisher в lifecycled | компилится, зависит zenoh crate | broker готов |
| Публиковать события `bsdos/thermal/*` | Zenoh events видны | publisher работает |
| UI показывает temperature gauge | dashboard обновляется live | Zenoh integration |
| **Гейт: Status bar отображает °C** | real-time indicator | all |

---

## 7. Архитектура и зависимости

```
┌──────────────────────────────────────┐
│ bsdos-core (UI)                      │
│  └─ StatusBar: Temperature gauge     │
│     └─ Zenoh subscriber: bsdos/thermal/*
└──────────────────────────────────────┘

┌──────────────────────────────────────┐
│ lifecycled (FreeBSD)                 │
│  └─ ThermalMonitor (thread)          │
│     └─ get_temperature_from_hal()    │
│        └─ evaluate_state()           │
│           ├─ sysctl kern.hz          │
│           ├─ FREEZE jails            │
│           └─ publish_thermal_alert() │
└──────────────────────────────────────┘

┌──────────────────────────────────────┐
│ bsdos-hal (guest-agent)              │
│  └─ thermal.zig                      │
│     ├─ readCpuTemp() (/dev/iic0)     │
│     └─ readCpuTempStub()             │
└──────────────────────────────────────┘
```

---

## 8. Тестирование

### 8.1 Unit тесты (Zig)

```zig
test "temperature stub returns reasonable value" {
    const temp = thermal.readCpuTempStub();
    try std.testing.expect(temp >= 30);
    try std.testing.expect(temp <= 100);
}

test "throttle state changes at thresholds" {
    // 40°C → normal
    var reading = thermal.TemperatureReading{ .cpu_c = 40, ... };
    try std.testing.expectEqualStrings(reading.throttle_state, "normal");

    // 75°C → warm
    reading.cpu_c = 75;
    try std.testing.expectEqualStrings(reading.throttle_state, "warm");

    // 95°C → critical
    reading.cpu_c = 95;
    try std.testing.expectEqualStrings(reading.throttle_state, "critical");
}
```

### 8.2 Integration test на QEMU

```bash
# Запустить с THERMAL_TEST_TEMP=95 для эмуляции аварийного состояния
make vm-start
make vm-wait

THERMAL_TEST_TEMP=95 ssh freebsd@localhost -p 2222 \
  'echo "{\"cmd\":\"get_temperature\"}" | nc -U /var/run/bsdos-hal.sock'

# Ожидаем: "critical" state
```

### 8.3 Real hardware test (PinePhone)

```bash
freebsd# echo '{"cmd":"get_temperature"}' | nc -U /var/run/bsdos-hal.sock | jq '.values'
# Ожидаем реальные значения при разной нагрузке

# Нагрузить CPU:
freebsd# stress-ng --cpu 4 --timeout 60s

# Повторить запрос:
# Должны видеть рост cpu_c (50-80°C в зависимости от теплоотвода)
```

---

## 9. Глоссарий

| Термин | Определение |
|---|---|
| **Thermal zone** | область SoC с собственным датчиком temperature (CPU, GPU, board) |
| **Throttling** | снижение тактовой частоты для контроля температуры |
| **kern.hz** | FreeBSD kernel timer frequency (100 = default, 1000 = gaming) |
| **sysctl** | FreeBSD утилита для изменения kernel parameters в runtime |
| **Hysteresis** | задержка перед возвратом в нормальное состояние (избежать oscillation) |
| **Emergency shutdown** | graceful перезагрузка при критической температуре |
| **PMIC** | Power Management IC, может содержать thermal sensor |

---

## 10. Checklist: ready to implement

- [ ] **AXP803 datasheet** доступен (thermal register layout)
- [ ] **FreeBSD I2C support** есть (ioctl I2CRDWR работает)
- [ ] **sysctl kern.hz** изменяется в runtime (через `sysctlbyname()`)
- [ ] **jail(2) API** известен для FREEZE/THAW
- [ ] **Zenoh version** согласована с broker
- [ ] **QEMU образ** может быть запущен с THERMAL_TEST_TEMP env var

---

## 11. Дополнительные ресурсы

### Документация
- **FreeBSD sysctl(8)**: kern.hz документация
- **AXP803 Datasheet**: X-Powers регистры thermal
- **PinePhone hardware**: https://wiki.pine64.org/wiki/PinePhone
- **Allwinner A64 SoC**: A64 User Manual (thermal sensor specifications)

### Related PLAN files
- [PLAN-hal-battery-i2c.md](PLAN-hal-battery-i2c.md) — I2C API в Zig
- [docs/archive/2026-10-01-monorepo/PLAN-lifecycle-v2.md](docs/archive/2026-10-01-monorepo/PLAN-lifecycle-v2.md) — lifecycled FREEZE/THAW команды
- [PLAN-zig-hal-bringup.md](PLAN-zig-hal-bringup.md) — полный HAL bring-up

---

*Статус:* Roadmap. Исполнитель реализует по фазам (foundation → integration → Zenoh).

**Связано:** [PLAN-zig-hal-bringup.md](PLAN-zig-hal-bringup.md), [docs/archive/2026-10-01-monorepo/PLAN-lifecycle-v2.md](docs/archive/2026-10-01-monorepo/PLAN-lifecycle-v2.md), [PLAN-hal-battery-i2c.md](PLAN-hal-battery-i2c.md).

**Автор:** bsdOS team. **Дата:** 2026-06-06.
