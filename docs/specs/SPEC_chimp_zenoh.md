# SPEC_chimp_zenoh.md — Zenoh Infrastructure (Discovery, Mesh, Zero-Copy, VPN)

**Synthesized:** 2026-06-15 (architect, claude-host / MiniMax M2.7)
**Status:** Active specification (Chimp v0.2+)
**Synthesizes:** 6 legacy `PLAN-*.md` files (zenoh-discovery, zenoh-mesh, zenoh-upgrade, zenoh-qml-bridge, vpn-mesh, zero-copy-pipeline)

> **Phase target:** All Chimp/Woodpecker infrastructure runs on Zenoh peer mode. These plans cover the operational concerns: discovery, mesh, zero-copy, VPN bridging.

**See also:**
- `docs/specs/SPEC_zenoh_keyspace.md` — full key namespace (companion)
- `docs/specs/SPEC_zenoh_security.md` — mTLS / WireGuard (companion)
- `docs/specs/SPEC_squirrel_rootfs.md` §4 — Zenoh on port 443 (Squirrel build)

---

## 0. Stack overview

| Component | Source PLAN | Phase |
|---|---|---|
| **Discovery (QEMU SLIRP fix)** | `PLAN-zenoh-discovery.md` | Squirrel |
| **Mesh topology (HAL→broker→bsdos-core)** | `PLAN-zenoh-mesh.md` | Active |
| **Zenoh 0.11 → 1.x upgrade** | `PLAN-zenoh-upgrade.md` | Q3 2026 |
| **Zenoh → QML bridge** | `PLAN-zenoh-qml-bridge.md` | Chimp |
| **WireGuard VPN mesh (3-node)** | `PLAN-vpn-mesh.md` | Chimp |
| **Zero-Copy Cap'n Proto pipeline** | `PLAN-zero-copy-pipeline.md` | Woodpecker (touch @ 240Hz) |

---

## 1. Discovery (QEMU SLIRP gap fix)

**Source:** `docs/archive/2026-06-15-plans/PLAN-zenoh-discovery.md` (11 KB, full)

**Problem:** QEMU user-net (SLIRP) doesn't support multicast (UDP 224.0.0.224:7447). Zenoh peer mode discovery doesn't work automatically between host and VM.

**Solution:** Explicit TCP peer endpoint or QEMU hostfwd for Zenoh port.

**Architecture:**
```
Host (Linux)                      QEMU (FreeBSD)
┌──────────────────┐              ┌──────────────────┐
│ bsdOS daemon     │  ───────►   │ bsdos-core        │
│ Zenoh peer       │  TCP :7447   │ Zenoh peer        │
│ 192.0.2.1   │  (hostfwd)   │ 192.0.2.10    │
└──────────────────┘              └──────────────────┘
```

**Phase 0 (Squirrel — already implemented):** hostfwd `tcp::7447-:7447` in QEMU launch.

---

## 2. Mesh topology (HAL→broker→bsdos-core)

**Source:** `docs/archive/2026-06-15-plans/PLAN-zenoh-mesh.md` (6 KB, full)

**Goal:** Connect HAL → broker → bsdos-core → external clients via Zenoh peer mesh.

**Topics:**
- `bsdos/telemetry` — HAL hardware status (1Hz)
- `bsdos/jail/<name>/status` — per-jail state
- `bsdos/cmd/<name>` — control commands

**Phase 0 (Squirrel):** Basic mesh, host VM only
**Phase 1 (Chimp):** Multi-host mesh (PinePhone + Mac + server)

---

## 3. Zenoh 0.11 → 1.x upgrade

**Source:** `docs/archive/2026-06-15-plans/PLAN-zenoh-upgrade.md` (6 KB, full)

**Status:** Ready for implementation
**Scope:** Core runtime, config, I/O, FreeBSD compatibility

**API changes** (from source — full table in PLAN):
- 0.11: manual `Session::open().await` + builder pattern
- 1.x: simplified `zenoh::open(config).await` + structured config

**Breaking changes:**
- Config struct: `.with_xxx()` → typed config
- Subscriber callback: closure → `Handler` trait
- Query: `get()` → `get(selector, options)`

**Phase Q3 2026:** Upgrade during Q3 stream A work (Wayland pipeline stabilization)

---

## 4. Zenoh → QML bridge (Chimp)

**Source:** `docs/archive/2026-06-15-plans/PLAN-zenoh-qml-bridge.md` (10 KB, full)

**Goal:** Real-time hardware telemetry (CPU, battery, uptime) from Zenoh (`bsdos/telemetry`) into QML UI via C++ `ZenohBridge` class.

**Current state:** `TelemetryBackend.qml` generates synthetic sine-wave data. In production, replace with real-time Zenoh reads.

**Architecture:**
```
QML UI (TelemetryBackend.qml)
   ↑ Qt property bindings
C++ ZenohBridge (QObject)
   ↑ Zenoh subscriber (bsdos/telemetry)
Zenoh peer → bsdOS daemon
```

**Phase 2 (Chimp):** Bridge implemented, real data flowing

---

## 5. WireGuard VPN mesh (3-node)

**Source:** `docs/archive/2026-06-15-plans/PLAN-vpn-mesh.md` (7.7 KB, full)

**Goal:** Enable Zenoh peer discovery across WAN (PinePhone ↔ Mac ↔ VPS) via WireGuard tunnels. Single virtual L2 network — Zenoh multicast works as if collocated.

**Topology (3-node):**
```
PinePhone (mobile, LTE NAT)        MacBook (WiFi NAT)
       │                                  │
       └─────── WireGuard ────────────────┤
                                            │
                                       VPS (hub)
```

**Why WireGuard:** Lightweight (~4k LOC), kernel-mode fast path, simple key management, no certificate infrastructure.

**Phase 2 (Chimp):** Initial 3-node mesh (PinePhone + Mac + VPS)
**Phase 3 (Woodpecker):** Multi-node mesh with hub-and-spoke

---

## 6. Zero-Copy Cap'n Proto pipeline

**Source:** `docs/archive/2026-06-15-plans/PLAN-zero-copy-pipeline.md` (26 KB, full)

**Goal:** Zero-Copy IPC: Cap'n Proto + Unix sockets (NO JSON).

**Rationale:** Touch latency at 120 Hz critical; JSON parsing overhead (10–30 μs per event) prevents 240+ Hz capability. Zero-copy Cap'n Proto reduces HAL → broker → compositor to <1 μs per event = 30× speedup.

**Current state:** JSON → parsing bottleneck
**Phase 1:** Cap'n Proto for HAL data plane (replace JSON)
**Phase 2:** Cap'n Proto for control plane (replace JSON text)
**Phase 3:** Cap'n Proto for telemetry (high-freq 240Hz touch)

**Touch latency target:** <1ms end-to-end (HAL → broker → compositor)

**Phase 4+ (Woodpecker):** Full zero-copy implementation

---

## 7. Cross-cutting concerns

**Performance:**
- Touch @ 240Hz requires zero-copy (Cap'n Proto, no JSON)
- Telemetry @ 1Hz is fine with JSON
- Voice Opus @ ~10ms latency budget per frame

**Reliability:**
- WireGuard mesh: if VPS hub down, local LAN still works
- Zenoh: peer mode = no single point of failure
- Cap'n Proto: schema versioning for backward compat

**Operations:**
- mTLS for cross-internet (per `SPEC_zenoh_security.md`)
- WireGuard for cross-NAT (per §5)
- Plain UDP for local LAN (assumed trusted)

---

## 8. Source files (preserved for full detail)

```
docs/archive/2026-06-15-plans/
├── PLAN-zenoh-discovery.md        (11 KB) — §1 SLIRP fix
├── PLAN-zenoh-mesh.md             (6 KB)  — §2 mesh topology
├── PLAN-zenoh-upgrade.md          (6 KB)  — §3 0.11→1.x
├── PLAN-zenoh-qml-bridge.md       (10 KB) — §4 QML bridge
├── PLAN-vpn-mesh.md               (7.7 KB)— §5 WireGuard mesh
└── PLAN-zero-copy-pipeline.md     (26 KB) — §6 zero-copy
```

---

## 9. Open questions

1. **Discovery bootstrap:** Static config or mDNS-like? (QEMU can't multicast, but real LAN can)
2. **Mesh routing:** Spanning tree, or hub-and-spoke with VPS?
3. **Zenoh 1.x timeline:** Q3 2026 too late? Block Chimp if needed?
4. **QML bridge:** C++ binding or alternative (e.g., QML native + zenoh Rust crate)?
5. **WireGuard key management:** Per-device or central (VPS issues certs)?
6. **Zero-copy breaking:** Cap'n Proto adoption = requires ALL components upgrade simultaneously?

---

**Synthesized:** 2026-06-15, architect (claude-host / MiniMax M2.7).
**Source:** 6 PLAN files (~67 KB), reprocessed into ~7 KB synthesis.
**Replaces:** 6 standalone plans in archive.
