# SPEC_woodpecker_vision.md — Long-term Vision (UX, Storage, HA, Multi-device, oBsdOS)

**Synthesized:** 2026-06-15 (architect, claude-host / MiniMax M2.7)
**Status:** Active specification (v0.3+ roadmap items)
**Synthesizes:** 11 legacy `PLAN-*.md` files covering long-term vision, UX, multi-device sync, HA, oBsdOS paranoid edition

> **Phase target:** These are v0.3+ roadmap items and Phase 1+ direction. Most are not on critical path for Squirrel/Chimp but inform the longer arc.

**See also:**
- `ROADMAP.md` — full roadmap including Phase 1-4
- `docs/specs/SPEC_chimp_security.md` §5 — security profiles (subset of oBsdOS)
- `docs/archive/2026-10-01-monorepo/specs/SPEC_woodpecker_matrix.md` §4 — real-time collab (CRDT)
- `docs/specs/SPEC_woodpecker_apps.md` — MVP app suite (overlaps with UX)

---

## 0. Stack overview

| Vision | Source PLAN | Target |
|---|---|---|
| **UX system** (Live cards, Dopamine brake, Beastie) | `PLAN-ux.md` (29 KB) | Woodpecker v0.3 |
| **UI design system** (Tactile Neo-Brutalism, 85KB cache) | `PLAN-ui-design-system.md` (13 KB) | Chimp v0.2 |
| **Predictive touch** (240Hz, 50ms pre-thaw) | `PLAN-predictive-touch.md` (5 KB) | Woodpecker |
| **Intent detection** (predictive UI) | `PLAN-intent-detection.md` (7.6 KB) | Woodpecker+ |
| **Liquid Workspace** (cross-device context) | `PLAN-liquid-workspace.md` (15 KB) | Woodpecker |
| **Multi-device sync** (Zenoh mesh) | `PLAN-multi-device-sync.md` (22 KB) | Woodpecker |
| **HA redundancy** (failover) | `PLAN-ha-redundancy.md` (9 KB) | Phase 1+ |
| **Storage architecture** (ZFS design) | `PLAN-storage-architecture.md` (19 KB) | All releases |
| **Crypto key management** | `PLAN-crypto-keys.md` (5.3 KB) | All releases |
| **PaaS productization** (sandboxes-as-an-API) | `PLAN-paas-mpp.md` (12 KB) | Phase 2 (revenue) |
| **oBsdOS paranoid edition** | `PLAN-obsdos.md` (44 KB) | Phase 4 (oBsdOS) |

---

## 1. UX system (Live cards, Dopamine brake, Beastie)

**Source:** `docs/archive/2026-06-15-plans/PLAN-ux.md` (29 KB, full)

**3 pillars:**
1. **Live app-cards multitasking** — each running jail visualized as a card with live preview (Wayland stream via Zenoh); freeze (SIGSTOP) / thaw (SIGCONT) from UI; "MeeGo spirit"
2. **Dopamine brake** — Zig HAL monitors scroll events in real-time (frequency, direction, duration); on doom-scroll detection → reduce compositor FPS (60→15); after 30 min continuous scrolling → notification with break suggestion
3. **Beastie Tamagotchi** — system monitor as BSD daemon character (visual feedback for system state)

**Phase 3 (Woodpecker):** Live cards first (visible value), then Dopamine brake (behavioral), Beastie (polish)

---

## 2. UI design system (Tactile Neo-Brutalism)

**Source:** `docs/archive/2026-06-15-plans/PLAN-ui-design-system.md` (13 KB, full)

**Constraint:** 85KB hot-path core (L1/L2 cache, SpacemiT K1 / Mali-400)

**Philosophy: "Constraint as Style"**
- PinePhone: 2GB RAM, Mali-400 with 85KB in-flight L1/L2 cache
- Reject blur, shadow, antialiasing as "nice-to-have waste"
- Embrace: bold colors, sharp edges, monospace fonts, 2-3px borders

**Target:** 85KB total hot-path QML (fits L1/L2 cache, no RAM fetches)

**Phase 2 (Chimp):** Initial design system + components
**Phase 3 (Woodpecker):** Refinement + PinePhone-specific optimizations

---

## 3. Predictive touch (240Hz HAL)

**Source:** `docs/archive/2026-06-15-plans/PLAN-predictive-touch.md` (5 KB, full)

**Goal:** On touch detect, HAL sends pre-thaw signal 50ms before jail wake.

**Hardware:** Goodix GT917S on PinePhone, FreeBSD 15.1 ARM64
**Frequency:** 240Hz touch sampling

**Phase 3 (Woodpecker):** HAL predictive pre-thaw

---

## 4. Intent detection (predictive UI)

**Source:** `docs/archive/2026-06-15-plans/PLAN-intent-detection.md` (7.6 KB, full)

**Goal:** Predict user's intent BEFORE interaction via context + ML classification.

**Examples:**
- 08:00 → likely appEmail (69%)
- Last was appPhone → quickly return (75%)
- Zone by clock → appClock (82%)
- Active call in Zenoh → appPhone (98%)

**Without intent:** UI shows generic launcher
**With intent:** UI shows predicted app prominently

**Phase 3+:** ML model + Zenoh signals (active app, time, location)

---

## 5. Liquid Workspace (cross-device context)

**Source:** `docs/archive/2026-06-15-plans/PLAN-liquid-workspace.md` (15 KB, full)

**Goal:** Transparent sync of context (open files, clipboard, browser tabs, cursor position) between PinePhone (FreeBSD) and Mac/Linux via Zenoh.

**User experience:** Lift phone from pocket → context ready, browser on right tab, code open on right line.

**Topics (per `SPEC_zenoh_keyspace.md`):**
- `bsdos/liquid/<device>/context` — open files, active app
- `bsdos/liquid/<device>/clipboard` — clipboard (per `clipper` app)
- `bsdos/liquid/<device>/tab-transfer` — URL + metadata for tab mobility
- `bsdos/liquid/<device>/notify` — notification origin

**Phase 3 (Woodpecker):** Initial Liquid Workspace

---

## 6. Multi-device sync (Zenoh mesh)

**Source:** `docs/archive/2026-06-15-plans/PLAN-multi-device-sync.md` (22 KB, full)

**Scope:** PinePhone A/B + BPI-F3 tablet + Mac/Linux Claude Code editor
**Transport:** Zenoh peer mode (no broker), mDNS discovery
**Sync unit:** Device context, clipboard, tab transfer, ZFS file handles

**Phase 1 (Liquid Workspace):** Single-direction sync
**Phase 2 (CRDT):** Bidirectional with conflict resolution (per `SPEC_woodpecker_matrix.md` §4)

---

## 7. HA redundancy (failover)

**Source:** `docs/archive/2026-06-15-plans/PLAN-ha-redundancy.md` (9 KB, full)

**Scope:** Failover & mesh sync for PinePhone + BPI-F3 pair

**Phase 1+:** Hot standby with ZFS replication

---

## 8. Storage architecture (ZFS design)

**Source:** `docs/archive/2026-06-15-plans/PLAN-storage-architecture.md` (19 KB, full)

**Scope:** ZFS on FreeBSD 14.x ARM64 (PinePhone + larger platforms)

**Components:**
- Boot pool (eMMC / nvme)
- Read-only base templates for jail cloning
- Per-app data isolation via ZFS datasets
- Snapshot strategy (instant thaw / app versioning)
- Encrypted profiles (oBsdOS duress mode)
- Sizing: 16GB eMMC (PinePhone) → larger platforms

**Already implemented (per `SPEC_jpk_descriptor_v1.md`):** per-jail ZFS datasets, .jpk clone from ro template.

---

## 9. Crypto key management

**Source:** `docs/archive/2026-06-15-plans/PLAN-crypto-keys.md` (5.3 KB, full)

**Keys in system:**
| Key type | Purpose | Algorithm | Storage |
|---|---|---|---|
| ZFS master key | Dataset encryption | AES-256-GCM | Encrypted ZFS + RAM |
| SSH host keys | Remote access | Ed25519 | `/opt/proto/etc/ssh/ssh_host_*` |
| SSH user keys | Agent login | Ed25519 | User home `.ssh/` |
| Matrix Olm session keys | E2EE room | ChaCha20-Poly1305 | `/opt/proto/data/matrix/pickled_sessions` |
| .jpk signing keys | App store | Ed25519 | Per-developer |
| Zenoh peer auth | mTLS | Ed25519 | Per-device |

**Duress mode:** Profile-specific keys can be unloaded (`zfs unload-key`) without root access (see `SPEC_chimp_security.md` §5)

---

## 10. PaaS productization (Phase 2 revenue)

**Source:** `docs/archive/2026-06-15-plans/PLAN-paas-mpp.md` (12 KB, full)

**Goal:** Turn bsdOS's kernel-enforced jail capability into a billable product on ARM servers.

**Key insight:** The product is **NOT** "sandbox" — it's `manifest + attestation`:
> "Run this code in a jail with exactly these permissions — get signed proof it couldn't have escaped."

**Use cases:** Multi-tenant SaaS, regulated workloads (HIPAA, financial), research sandboxes.

**Why bsdOS has a wedge:** Linux seccomp/AppArmor are weaker; FreeBSD Capsicum + jail + VNET is a complete capability story.

**Phase 2 (post-Chimp):** Initial PaaS launch

---

## 11. oBsdOS paranoid edition (Phase 4)

**Source:** `docs/archive/2026-06-15-plans/PLAN-obsdos.md` (44 KB, full)

**Honest statement:** oBsdOS is **NOT** nation-state protection. It's a privacy layer against commercial and intermediate-state surveillance tools.

**5 threat vectors addressed:**
1. Ghost Radio (IMSI catcher mitigation) — per `SPEC_woodpecker_mobile.md` §2.6
2. RAM crypto-sleep (cold-boot protection)
3. Duress biometric (coercion-resistant auth) — per `SPEC_chimp_security.md` §5
4. Acoustic counter-surveillance (mic isolation) — per `SPEC_chimp_security.md` §6
5. Emergency burn (physical seizure) — per `SPEC_woodpecker_mobile.md` §2.9

**Phase 4:** Full oBsdOS edition for activists/journalists/vulnerable groups

---

## 12. Source files (preserved for full detail)

```
docs/archive/2026-06-15-plans/
├── PLAN-ux.md                       (29 KB) — §1
├── PLAN-ui-design-system.md         (13 KB) — §2
├── PLAN-predictive-touch.md         (5 KB)  — §3
├── PLAN-intent-detection.md         (7.6 KB)— §4
├── PLAN-liquid-workspace.md         (15 KB) — §5
├── PLAN-multi-device-sync.md        (22 KB) — §6
├── PLAN-ha-redundancy.md            (9 KB)  — §7
├── PLAN-storage-architecture.md     (19 KB) — §8
├── PLAN-crypto-keys.md              (5.3 KB)— §9
├── PLAN-paas-mpp.md                 (12 KB) — §10
└── PLAN-obsdos.md                   (44 KB) — §11
```

---

## 13. Open questions

1. **UX direction:** Neo-Brutalism aesthetic — is this the right call, or do users want "soft" UI?
2. **Dopamine brake paternalism:** Is it opt-in or default-on? (Opt-in for v0.3.1, evaluate v0.3.2)
3. **Predictive touch 240Hz:** Hardware (Goodix) supports it, but does FreeBSD driver?
4. **Intent detection:** Local ML or cloud? (Local-only for privacy)
5. **Liquid Workspace conflicts:** Who wins if 2 devices edit same file?
6. **PaaS pricing:** Per-jail-hour, per-app, per-tenant? (TBD Phase 2)
7. **oBsdOS scope:** Bundled with bsdOS or separate distribution?

---

**Synthesized:** 2026-06-15, architect (claude-host / MiniMax M2.7).
**Source:** 11 PLAN files (~180 KB), reprocessed into ~12 KB synthesis.
**Replaces:** 11 standalone plans in archive.
