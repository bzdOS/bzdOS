# SPEC_zenoh_keyspace.md — Zenoh Key Space for bsdOS

**Original plan:** 2026-06-05  
**Promoted to SPEC:** 2026-06-15 (from `docs/archive/2026-06-15-plans/PLAN-zenoh-topics.md`)  
**Status:** Active specification  
**Audience:** Rust broker, Zig HAL, jail supervisors, hubd agents

> **⛔ Topic migration 2026-06-13 (commit 1a95431):** `bsdos/wayland/{stream,input}` →
> per-app_id topics `bsdos/app/{app_id}/{stream,input,health}`. Examples in this
> spec use the new structure; see `bsdos-core/src/stream_manager.rs` for impl.

**See also:**
- `docs/specs/SPEC_zenoh_security.md` — Zenoh mTLS design (Chimp F2)
- `docs/specs/SPEC_2stream_squirrel.md` — per-app_id stream multiplexing
- `docs/specs/SPEC_squirrel_rootfs.md` — Squirrel build pipeline (uses Zenoh on :7447)
- `ROADMAP.md` — Q3 stream A (Wayland + Zenoh)


---

## Overview

This document defines the complete Zenoh key namespace for bsdOS peer-to-peer mesh.
All data flows through Zenoh (no broker required, peer mode only).

**Key principles:**
- **Hierarchical naming:** `bsdos/<category>/<resource>/<metric>`
- **Binary payloads:** Cap'n Proto for data-plane (telemetry, sensors, state)
- **Text payloads:** JSON for control-plane (commands, AI requests, config)
- **No wildcards in publish:** only in subscriber filters
- **Persistence:** each key is fire-and-forget unless explicitly replicated

---

## Key Hierarchy

```
bsdos/
├── telemetry              ← HardwareStatus (uptime/battery/cpu/temp) @ 1Hz
├── device/
│   ├── <uuid>/
│   │   ├── telemetry         ← device-local HardwareStatus
│   │   ├── liquid/
│   │   │   ├── context       ← LiquidContext (clipboard/url/active window)
│   │   │   ├── tab-transfer  ← URL + metadata for tab mobility
│   │   │   └── notify        ← notification origin
│   │   ├── wayland/
│   │   │   ├── stream        ← WaylandPacket (display pixels)
│   │   │   └── input         ← WaylandPacket (keyboard/mouse events)
│   │   └── status            ← DeviceStatus (online/offline/rssi)
├── jail/
│   ├── <name>/
│   │   ├── status            ← JailStatus (jid/frozen/memUsed/cpu)
│   │   ├── ready             ← bool (hotswap signal)
│   │   ├── killed            ← event on RCTL OOM kill
│   │   └── log               ← jail stderr stream
│   └── request               ← {action: "create"|"destroy", name, config}
├── cmd/
│   ├── <jail>/
│   │   ├── freeze            ← empty payload = SIGSTOP signal
│   │   ├── thaw              ← empty payload = SIGCONT signal
│   │   └── kill              ← {signal: 9|15, reason}
│   └── supervisor/
│       └── reload            ← empty = HUP to jail supervisor
├── sensors/
│   ├── accel                 ← AccelData (ax/ay/az) @ up to 240Hz
│   ├── gyro                  ← GyroData (wx/wy/wz) @ 240Hz
│   ├── touch                 ← TouchEvent (x/y/pressure/finger_id) @ 240Hz
│   ├── gps                   ← GpsData (lat/lon/alt/accuracy) @ 1Hz
│   ├── proximity             ← ProximityData (distance_mm) @ 5Hz
│   └── compass               ← CompassData (heading_deg/accuracy)
├── input/
│   ├── touch                 ← TouchEvent (alias subscriber = sensors/touch)
│   ├── keyboard              ← KeyboardEvent (keycode/modifiers)
│   └── pointer               ← PointerEvent (x/y/button)
├── power/
│   ├── battery               ← {capacity_pct, charging: bool, voltage_mv}
│   ├── thermal               ← {temp_c, state: "ok"|"warm"|"critical"}
│   ├── hz                    ← {value: kern.hz (FreeBSD sysctl)}
│   ├── mode                  ← {mode: "normal"|"powersave"|"charger"}
│   └── sleep                 ← {command: "suspend"|"hibernate", delay_ms}
├── ai/
│   ├── request               ← {prompt, max_tokens, context_id, model}
│   ├── response              ← {text, latency_ms, tokens_used}
│   └── models                ← {available: ["model-a", "model-b"]}
├── hubd/
│   ├── claims                ← claims.jsonl (current state, replicated)
│   ├── agents                ← agents.jsonl (agent status list)
│   ├── events                ← {type: "CLAIM"|"RELEASE"|"KILL", agent_id, ts}
│   └── heartbeat             ← {agent_id, ts, uptime_sec}
├── audit/
│   ├── <app>/access          ← {principal, operation, ts, allowed: bool}
│   └── <app>/error           ← {error, stack, ts}
├── notifications             ← {title, body, urgency: "low"|"high", ts}
├── store/
│   ├── <app>/<version>       ← .jpk binary (app package)
│   ├── search/<query>        ← search index entry (replicated)
│   └── index                 ← {version, updated_ms}
├── thermal/
│   ├── cpu                   ← {temp_c, state, throttle_active}
│   ├── gpu                   ← {temp_c, state}
│   └── alert                 ← {temp_c, action: "throttle"|"shutdown"}
├── network/
│   ├── wifi                  ← {ssid, rssi_dbm, freq_ghz, state}
│   ├── cellular              ← {signal_bars, network_type, roaming}
│   └── connectivity          ← {has_ipv4, has_ipv6, dns_ok}
├── display/
│   ├── brightness            ← {value: 0..255}
│   ├── orientation           ← {mode: "portrait"|"landscape", angle}
│   └── fps                   ← {target: 30|60|120}
└── global/
    └── config                ← {boot_time_ms, timezone, locale}
```

---

## Data Types and Serialization

### Cap'n Proto (Binary, Zero-Copy) — Data-Plane

| Key | Type | Frequency | Typical Size | Notes |
|---|---|---|---|---|
| `bsdos/telemetry` | HardwareStatus | 1 Hz | 32 bytes | uptime_sec, battery_pct, cpu_usage, temp_c |
| `bsdos/sensors/touch` | TouchEvent | 240 Hz | 16 bytes | x, y, pressure, finger_id |
| `bsdos/sensors/accel` | AccelData | 240 Hz | 12 bytes | x, y, z (int16 mG) |
| `bsdos/sensors/gps` | GpsData | 1 Hz | 24 bytes | lat, lon, alt, accuracy |
| `bsdos/jail/*/status` | JailStatus | 5 Hz | 64 bytes | jid, frozen, mem_used, cpu_usage, state |
| `bsdos/power/battery` | BatteryStatus | 1 Hz | 8 bytes | capacity_pct, charging, voltage_mv |
| `bsdos/device/*/status` | DeviceStatus | 5 Hz | 48 bytes | uuid, online, rssi, last_seen |
| `bsdos/input/touch` | TouchEvent | 240 Hz | 16 bytes | same schema as sensors/touch |

### JSON (Text, Control-Plane) — Commands & Requests

| Key | Type | Frequency | Typical Size | Notes |
|---|---|---|---|---|
| `bsdos/ai/request` | JSON | on-demand | <1 KB | `{prompt, max_tokens, context_id, model}` |
| `bsdos/ai/response` | JSON | on-demand | <10 KB | `{text, latency_ms, tokens_used, error?}` |
| `bsdos/cmd/*/freeze` | empty or JSON | on-demand | 0–256 B | empty = SIGSTOP; JSON = `{reason}` |
| `bsdos/jail/request` | JSON | on-demand | <512 B | `{action, name, config_blob}` |
| `bsdos/hubd/events` | JSON | on-demand | <256 B | `{type, agent_id, ts, details}` |
| `bsdos/notifications` | JSON | on-demand | <512 B | `{title, body, urgency, ts, icon_id?}` |
| `bsdos/device/*/liquid/context` | JSON | 1 Hz | <256 B | `{clipboard, url, active_window, cursor_x, cursor_y}` |

### Protocol Buffers / Cap'n Proto Schema Location

**File:** `schema.capnp`

**Key structs:**
```capnp
struct HardwareStatus {
  uptimeSec @0 : UInt64;
  batteryPct @1 : UInt8;
  cpuUsage @2 : UInt16;  # permille (0–1000)
  tempC @3 : Int16;
  charging @4 : Bool;
}

struct TouchEvent {
  x @0 : UInt16;
  y @1 : UInt16;
  pressure @2 : UInt16;  # 0–4095
  fingerId @3 : UInt8;
}

struct JailStatus {
  jid @0 : UInt32;
  frozen @1 : Bool;
  memUsed @2 : UInt64;
  cpuUsage @3 : UInt16;
  state @4 : UInt8;  # enum: Running, Stopped, etc.
}
```

---

## Naming Conventions

### Global system keys
```
bsdos/<category>/<metric>
```
Example: `bsdos/telemetry`, `bsdos/power/battery`

### Device-scoped keys
```
bsdos/device/<uuid>/<category>/<metric>
```
Example: `bsdos/device/550e8400-e29b-41d4-a716-446655440000/telemetry`

### Jail-scoped keys
```
bsdos/jail/<name>/<metric>
```
Example: `bsdos/jail/appA/status`, `bsdos/jail/appB/log`

### Commands (one-way, JSON or empty)
```
bsdos/cmd/<target>/<action>
```
Example: `bsdos/cmd/appA/freeze`, `bsdos/cmd/supervisor/reload`

### Category prefixes
- `bsdos/` — bsdOS subsystems
- `bsdos/device/` — device-specific (multi-device mesh support)
- `bsdos/jail/` — jail-specific (app sandbox state)
- `bsdos/cmd/` — imperative commands (one-shot actions)
- `bsdos/sensors/` — hardware sensors (high-frequency)
- `bsdos/power/` — power management
- `bsdos/ai/` — LLM inference
- `bsdos/hubd/` — distributed orchestration
- `bsdos/audit/` — access logs
- `bsdos/global/` — shared global state

---

## Subscription Patterns

### Single key
```rust
session.declare_subscriber("bsdos/telemetry").res()?
```

### Wildcard: all jails
```rust
session.declare_subscriber("bsdos/jail/*/status").res()?
```

### Wildcard: all devices
```rust
session.declare_subscriber("bsdos/device/+/telemetry").res()?
```

### Wildcard: all sensors
```rust
session.declare_subscriber("bsdos/sensors/*").res()?
```

### Multi-level wildcard (deprecated — avoid)
```rust
// NOT recommended; be explicit instead
session.declare_subscriber("bsdos/**/status").res()?
```

---

## Publishing Rules

### Frequency

| Category | Max Frequency | Rationale |
|---|---|---|
| telemetry | 1 Hz | battery + uptime updates |
| sensors (touch, accel) | 240 Hz | phone input sampling |
| sensors (gps, proximity) | 1–5 Hz | low energy |
| jail status | 5 Hz | monitoring + throttling |
| power (battery, thermal) | 1 Hz | slow state changes |
| AI request/response | on-demand | user-initiated |
| commands | on-demand | administrator-initiated |

### Payload limits

| Payload Type | Max Size | Strategy if exceeded |
|---|---|---|
| Binary (Cap'n Proto) | 16 KB | chunking or streaming |
| JSON (control) | 1 KB | reject with error |
| Sensor data (touch) | 16 bytes | inlined, no fragmentation |
| Jail logs | 4 KB per message | line buffering + rolling file |

### Latency expectations

- **Real-time:** sensors, input (< 10 ms)
- **Near real-time:** telemetry, jail status (< 100 ms)
- **Best effort:** AI responses, audit logs (< 1 sec)

---

## Authorization & Isolation

| Key Category | Publisher | Subscriber | Access Control |
|---|---|---|---|
| `bsdos/telemetry` | HAL/supervisor | all apps | public |
| `bsdos/sensors/*` | HAL | apps with permission | per-app ACL |
| `bsdos/jail/*/status` | jail supervisor | broker + all jails | public |
| `bsdos/cmd/*/freeze` | broker only | supervisor | admin-only |
| `bsdos/ai/request` | any app | broker | logged + ACL |
| `bsdos/audit/*` | broker | external audit system | append-only |
| `bsdos/hubd/*` | hubd daemon | agents | HMAC-signed |

**Enforcement:** Broker validates principal on `declare_publisher()` and `declare_subscriber()`.

---

## Lifecycle & Cleanup

### Transient keys (publish once, forget)
- `bsdos/cmd/*` (commands)
- `bsdos/ai/request` (user prompt)
- `bsdos/notifications` (alert)

### Replicated keys (sticky, replicated to new peers)
- `bsdos/hubd/claims` (job assignment)
- `bsdos/hubd/agents` (roster)
- `bsdos/store/*` (app packages)

### Ephemeral keys (deleted on peer disconnect)
- `bsdos/device/*/status` (device online/offline)
- `bsdos/jail/*/status` (jail supervisor heartbeat)

**Implementation:** Use Zenoh storage plugin to replicate claims; use session affinity for ephemeral keys.

---

## Example Flows

### Flow 1: Battery Alert

```
Supervisor publishes:
  bsdos/power/battery = {capacity_pct: 5, charging: false}

UI subscriber receives & shows warning
  
UI requests:
  bsdos/cmd/supervisor/reload (to reload power config)
```

### Flow 2: Jail Hotswap

```
Broker publishes:
  bsdos/jail/appA/request = {action: "destroy"}

Jail supervisor receives → kills appA
  
Supervisor publishes:
  bsdos/jail/appA/status = {state: Stopped}

Broker publishes:
  bsdos/jail/appA/ready = false

(Client starts new appA)

Supervisor publishes:
  bsdos/jail/appA/ready = true
```

### Flow 3: Sensor-Driven Input

```
HAL samples touch @ 240 Hz:
  bsdos/sensors/touch = TouchEvent{x, y, pressure, finger_id}

Wayland server (in UI jails) subscribes:
  bsdos/sensors/touch → transforms to pointer events
```

### Flow 4: AI Inference

```
App publishes:
  bsdos/ai/request = {prompt: "...", model: "llama2"}

Broker forwards to inference service
  
Service publishes:
  bsdos/ai/response = {text: "...", latency_ms: 245}

App receives & displays
```

---

## Migration & Versioning

**Current version:** 1.0 (2026-06-05)

**Forward compatibility:**
- New keys added under existing prefixes (e.g., `bsdos/power/solar`) do not break old subscribers.
- Schema changes in Cap'n Proto use new field indices; old payloads remain readable.
- Control-plane JSON adds optional fields; old JSON ignored by new code.

**Deprecation path (if needed):**
1. Announce new key under new prefix (e.g., `bsdos/v2/telemetry`)
2. Publish to both old and new keys for 2 releases
3. Sunset old key in v3

---

## Diagnostics & Monitoring

### Query all active keys
```bash
zenoh-query --selector "bsdos/*"
```

### Monitor telemetry @ 1 Hz
```bash
zenoh-sub --selector "bsdos/telemetry" --mode realtime
```

### Inspect jail state
```bash
zenoh-query --selector "bsdos/jail/*/status"
```

### Audit trail
```bash
tail -f /var/log/bsdos/audit.log | jq '.[] | select(.key | startswith("bsdos/audit"))'
```

---

## Checklist for Implementation

- [ ] Define all Cap'n Proto structs in `schema.capnp`
- [ ] Update Rust broker to publish global `bsdos/telemetry` every 1 sec
- [ ] Implement Zenoh storage plugin for `bsdos/hubd/claims` replication
- [ ] Add ACL enforcement in broker `declare_subscriber()` handler
- [ ] Test 240 Hz touch sampling on actual hardware (or simulator)
- [ ] Document jail supervisor → broker pub/sub integration
- [ ] Add monitoring script (zenoh-query loop) to artefacts/
- [ ] Performance test: can broker handle 1000 msgs/sec @ 16 bytes each?

---

**End of specification. Ownership: Rust broker team + Zig HAL team.**
