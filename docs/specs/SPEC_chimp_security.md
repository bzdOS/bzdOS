# SPEC_chimp_security.md — Security Stack (Capsicum, Permissions, Threat Model)

**Synthesized:** 2026-06-15 (architect, claude-host / MiniMax M2.7)
**Status:** Active specification (Chimp v0.2, with extensions to Woodpecker v0.3)
**Synthesizes:** 7 legacy `PLAN-*.md` files (capsicum, app-permissions, sandbox-escape, security-profiles, rctl-wakelock, acoustic-privacy, dpi-transport)

> **Phase target:** Chimp v0.2 brings Capsicum + per-app permissions + sandbox threat model. Woodpecker v0.3 extends with duress biometrics + acoustic privacy.

**See also:**
- `docs/specs/SPEC_chimp_jail_networking.md` — VNET jails (network isolation layer)
- `docs/specs/SPEC_zenoh_security.md` — Zenoh mTLS (transport encryption)
- `docs/specs/SPEC_jpk_descriptor_v1.md` — `.jpk` permission declarations
- `docs/specs/SPEC_woodpecker_mobile.md` §2.5, §2.6, §2.9 (biometric, IMSI, emergency)
- `PLAN-jail-prototype.md` — current ip4=inherit jail model (pre-Chimp)

---

## 0. Stack overview

| Layer | Mechanism | Source PLAN | Phase |
|---|---|---|---|
| **Jail isolation** | FreeBSD jails (VNET for Chimp) | `PLAN-jail-prototype.md` (root) | Squirrel+ |
| **Capsicum capabilities** | FreeBSD Capsicum framework | `PLAN-capsicum.md` | Chimp |
| **App permissions** | jail.conf + devfs + pf | `PLAN-app-permissions.md` | Chimp |
| **RCTL resource limits** | `rctl -a jail:<id>:...` | `PLAN-rctl-wakelock.md` | Chimp |
| **Threat model** | Honest sandbox-escape analysis | `PLAN-sandbox-escape.md` | Chimp |
| **Security profiles** | ZFS multi-key profiles + disposable jails | `PLAN-security-profiles.md` | Woodpecker |
| **Acoustic privacy** | Ambient noise masking daemon | `PLAN-acoustic-privacy.md` | Woodpecker |
| **DPI-resistant transport** | In-product AEAD layer (ТСПУ bypass) | `PLAN-dpi-transport.md` | Active (mac side) |

---

## 1. Capsicum (capability mode)

**Source:** `docs/archive/2026-06-15-plans/PLAN-capsicum.md` (15 KB, full)

**Goal:** Capability-based security for bsdOS daemons. Apps in capability mode can only access resources explicitly granted via file descriptors.

**Mechanism:** FreeBSD Capsicum (analogous to Linux seccomp-bpf, but more powerful). Apps enter capability mode after init; can only operate on pre-opened FDs.

**Phase 2 (Chimp):**
- All bsdOS daemons (`bsdos-core`, `bsdos_lifecycled`, `bsdos-hal`) run in capability mode
- `CAP_IOCTL`, `CAP_READ`, `CAP_WRITE`, `CAP_FSYNC`, `CAP_EVENT` per device
- App jails also run in capability mode (inherits from jail)

---

## 2. App permissions (Android-style)

**Source:** `docs/archive/2026-06-15-plans/PLAN-app-permissions.md` (13 KB, full)

**Permission model** — categories and mechanisms:

| Permission | Mechanism | FreeBSD | Granularity |
|---|---|---|---|
| Network | `ip4=inherit` / `ip4=disable` / VNET | jail.conf | per-jail |
| Camera | `/dev/video*` in devfs | devfs ruleset | per-device |
| Microphone | `/dev/dsp*` in devfs | devfs ruleset | per-device |
| Location | `/dev/ucom*` (GPS UART) | devfs ruleset | per-serial |
| Bluetooth | `/dev/uhid*` | devfs ruleset | per-device |
| Storage | per-jail `/data/<app>/` | ZFS dataset | per-app |
| Notifications | Zenoh pub rights | `bsdos/notifications/*` topic | per-app |

**`.jpk` declaration** (per `SPEC_jpk_descriptor_v1.md`):
```toml
[permissions]
network = "vnet"  # or "none", "inherit"
camera = false
microphone = true
location = false
bluetooth = false
storage = "private"  # or "shared"
notifications = true
```

**Phase 2 (Chimp):** Apps declare permissions in `.jpk`; broker enforces at jail start.

---

## 3. Sandbox threat model

**Source:** `docs/archive/2026-06-15-plans/PLAN-sandbox-escape.md` (14 KB, full)

**Goal:** Honest threat model. What can a malicious or compromised app do to break out?

**Jail architecture:**
- Process isolation: `PROC_INHERIT=0`
- Filesystem: ro base (nullfs), per-app rw datasets at `/data`
- Network: `ip4=disable` (Zenoh-only transport)
- Capabilities: Capsicum mode

**Threats analyzed:**
- Kernel exploits
- Side channels (timing, cache, power)
- Covert channels between jails
- Supply chain (.jpk signing)
- Social engineering (user grants perm)

**Mitigations:**
- Kernel exploit: minimize attack surface, `securelevel=3`
- Side channels: ZFS `primarycache=metadata` per-jail, isolated CPU cpuset
- Covert channels: rate-limit Zenoh pub, no shared cache
- Supply chain: Ed25519 signing (per `SPEC_jpk_descriptor_v1.md`)
- Social: explicit per-permission prompts (no batch grant)

**Phase 2 (Chimp):** Initial threat model + mitigations. Re-evaluate quarterly.

---

## 4. RCTL + WakeLock elimination

**Source:** `docs/archive/2026-06-15-plans/PLAN-rctl-wakelock.md` (24 KB, full)

**Goal:** Per-jail memory, CPU, process limits via RCTL. **No WakeLock API** — apps cannot prevent SIGKILL via kernel-level limit.

**RCTL rules:**
```
# Memory limit per jail
rctl -a jail:<jail_id>:memoryuse:deny=2G

# CPU limit
rctl -a jail:<jail_id>:pcpu:deny=80

# Process limit
rctl -a jail:<jail_id>:maxproc:deny=64

# Open files
rctl -a jail:<jail_id>:openfiles:deny=512
```

**WakeLock elimination:** RCTL enforces hard limit; app cannot request more memory/CPU than allowed. If app exceeds → SIGKILL by kernel.

**Phase 2 (Chimp):** RCTL on all app jails; bsdos_lifecycled configures per-app from `.jpk`.

---

## 5. ZFS security profiles (Woodpecker)

**Source:** `docs/archive/2026-06-15-plans/PLAN-security-profiles.md` (18 KB, full)

**Goal:** Multi-profile ZFS encryption with separate keys, disposable jails, memory freeze on screen lock, panic biometrics.

**4 pillars:**
1. **Multi-profile ZFS encryption** — each user profile on its own AES-256-GCM key; on profile exit, `zfs unload-key` → data inaccessible even with root
2. **Disposable sandbox** — `.jpk` flag `disposable=true` → on app exit, jail self-destructs (ZFS mirror destroyed), zero persistent state
3. **Memory freeze** — on screen lock, dump jail memory to encrypted swap, unload keys
4. **Panic biometrics** — `panic_fingerprint` (different from normal unlock) → trigger `emergency_erase` (see `SPEC_woodpecker_mobile.md` §2.9)

**Phase 3 (Woodpecker):** All 4 pillars integrated

---

## 6. Acoustic privacy (Woodpecker)

**Source:** `docs/archive/2026-06-15-plans/PLAN-acoustic-privacy.md` (4.3 KB, full)

**Threat:** Microphone in jail = ambient audio recording. Malicious app records speech, keystrokes, environmental sound.

**Defense:** Ambient noise masking daemon that blends human speech into noise floor. Daemon runs at kernel priority, generates pink noise at low volume when mic is active.

**Phase 3 (Woodpecker):** Masking daemon + per-jail mic policy

---

## 7. DPI-resistant transport (in-product AEAD)

**Source:** `docs/archive/2026-06-15-plans/PLAN-dpi-transport.md` (21 KB, full)

**Goal:** Pass Zenoh stream (remote desktop) through **ТСПУ** (Russian TSPU/DPI) without external proxy daemons. Obfuscation built into `bsdos-core` and `metal-viewer` as custom Zenoh link.

**Why current ALPN approach insufficient:** Adds `alpn_protocols = ["h2","http/1.1"]` to rustls — DPI can still fingerprint.

**v2 approach:** Custom AEAD layer with rolling key, randomized padding, traffic shape mimicry (HTTPS-like bursts). Active obfuscation, not passive.

**Phase:** Active (mac side per `mac-companion/zenoh-link-tls-patched/`)

---

## 8. Defense in depth (synthesis)

```
Layer 1: Network           → VNET jail (per-jail IP), PF firewall, WireGuard
Layer 2: Process           → FreeBSD jail, Capsicum capability mode
Layer 3: Filesystem        → ZFS per-jail dataset, ro base, key unloading
Layer 4: Resource          → RCTL memory/CPU/process limits
Layer 5: Application       → .jpk permission declaration, broker enforcement
Layer 6: Supply chain      → Ed25519 .jpk signing, app store trust chain
Layer 7: Identity          → Matrix @handle (no phone number), IMSI protection
Layer 8: Audit             → Zenoh immutable topics (emergency, audit)
Layer 9: Recovery          → ZFS snapshots + rollback, emergency erase
Layer 10: Transport        → mTLS / WireGuard / DPI-resistant AEAD
```

**Each layer is independent** — compromise of one does not bypass the others.

---

## 9. Source files (preserved for full detail)

```
docs/archive/2026-06-15-plans/
├── PLAN-capsicum.md              (15 KB) — §1 capability mode
├── PLAN-app-permissions.md       (13 KB) — §2 permission model
├── PLAN-sandbox-escape.md        (14 KB) — §3 threat model
├── PLAN-security-profiles.md     (18 KB) — §5 ZFS profiles
├── PLAN-rctl-wakelock.md         (24 KB) — §4 RCTL limits
├── PLAN-acoustic-privacy.md      (4.3 KB)— §6 mic masking
└── PLAN-dpi-transport.md         (21 KB) — §7 DPI bypass
```

---

## 10. Open questions

1. **Capsicum adoption:** All daemons or only security-sensitive ones? (HAL? broker? daemons yes; UI no)
2. **Permission UX:** Per-permission prompts (Android-style) or batch grant (iOS-style)?
3. **RCTL vs cgroup:** FreeBSD has RCTL; should we also use cgroup-equivalent (`net_addrs`, etc.)?
4. **Disposable jails:** Auto-destruct on every app exit, or only opt-in per `.jpk`?
5. **Memory freeze overhead:** Dump to swap on every screen lock = slow; is that acceptable?
6. **Acoustic masking battery cost:** Continuous pink noise = +20mW; worth it?
7. **DPI-resistant transport:** Operationally complex — can it be opt-in per deployment?

---

**Synthesized:** 2026-06-15, architect (claude-host / MiniMax M2.7).
**Source:** 7 PLAN files (~110 KB), reprocessed into ~9 KB synthesis.
**Replaces:** 7 standalone plans in archive.
