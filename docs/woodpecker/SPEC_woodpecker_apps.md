# SPEC_woodpecker_apps.md — bsdOS MVP App Suite (Woodpecker v0.3+)

**Synthesized:** 2026-06-15 (architect, claude-host / MiniMax M2.7)
**Status:** Active specification (Woodpecker v0.3+)
**Synthesizes:** 9 legacy `PLAN-*.md` files (clipper, calendar, contacts, file-manager, media-player, notification-center, app-gallery, app-store, update-system)

> **Phase target:** These apps are MVP suite. Some ship with Squirrel (Phase 0/1 of acceptance); others land in Chimp/Woodpecker. Each is independently packaged as `.jpk`.

**See also:**
- `docs/specs/SPEC_jpk_descriptor_v1.md` — `.jpk` format (each app is a `.jpk`)
- `docs/specs/SPEC_chimp_jail_networking.md` — per-app network policy
- `docs/specs/SPEC_zenoh_keyspace.md` — Zenoh topics used by these apps
- `docs/specs/SPEC_woodpecker_mobile.md` — mobile-only apps (telephony, SMS, etc.)
- `docs/archive/2026-10-01-monorepo/PLAN-lifecycle-v2.md` — `bsdos_lifecycled` for app suspend/resume

---

## 0. Suite overview

| App | .jpk | Per-jail path | Data | Sync | Phase |
|---|---|---|---|---|---|
| **clipper** | `clipper@1.0.0.jpk` | `/data/clipboard` | RAM only | Zenoh (Liquid Workspace) | Squirrel P0 |
| **calendar** | `calendar@1.0.0.jpk` | `/data/calendar/` | iCalendar (.ics) | CalDAV (LTE-gated) | Squirrel P1 |
| **contacts** | `contacts@1.0.0.jpk` | `/data/contacts/` | vCard | Matrix @handle | Squirrel P0 |
| **file-manager** | `file-manager@1.0.0.jpk` | (read-only) | n/a | n/a | Squirrel P1 |
| **media-player** | `media-player@1.0.0.jpk` | `/data/media/` | MP3/FLAC/OGG/MP4 | n/a | Squirrel P1 |
| **notification-center** | `notification-center@1.0.0.jpk` | (event-driven) | n/a | n/a | Squirrel P0 |
| **app-gallery** | meta | n/a | app catalog | Zenoh | Chimp |
| **app-store** | meta | n/a | package distribution | Zenoh mesh | Chimp |
| **update-system** | meta | n/a | OS + apps updates | Zenoh OTA | Chimp+ |

**Each app = 1 FreeBSD jail** (sandboxed, resource-limited, network-declared).

---

## 1. clipper (clipboard manager)

**Source:** `docs/archive/2026-06-15-plans/PLAN-clipper.md` (6.9 KB, full)

**Goal:** Multi-jail clipboard daemon. In-memory only, no disk writes. Privacy-first.

**Architecture:**
- Centralized clipboard buffer for jailed apps
- **RAM only** (cleared on screen lock)
- Multi-device sync via Zenoh (trusted bsdOS instances only)

**Phase 0 (Squirrel):** single-device clipboard, clear on screen lock
**Phase 1 (Woodpecker):** multi-device sync via Liquid Workspace

---

## 2. calendar (iCalendar manager)

**Source:** `docs/archive/2026-06-15-plans/PLAN-calendar-app.md` (8.7 KB, full)

**Goal:** iCalendar (.ics) manager with lifecycle integration and optional CalDAV sync.

**Architecture:**
- Per-jail `/data/calendar/` (iCalendar files)
- Events trigger jail lifecycle (THAW reminder jails, suspend after event)
- Optional CalDAV sync (LTE-gated to save battery)
- All event data stays in jail unless explicitly shared

**Lifecycle integration:**
- Calendar event in 5min → THAW notification jail
- Calendar event ends → SIGSTOP (suspend jail)
- Background sync only when on WiFi (not LTE)

**Phase 1 (Squirrel):** local-only, no sync
**Phase 2 (Chimp):** CalDAV sync on WiFi

---

## 3. contacts (vCard manager)

**Source:** `docs/archive/2026-06-15-plans/PLAN-contacts-app.md` (7 KB, full)

**Goal:** First real jail-sandboxed app. Privacy-first.

**Architecture:**
- Per-jail vCard manager at `/data/contacts/`
- Simple broker-protocol interface for CRUD
- All data stays in jail unless explicitly shared
- Contact sharing: future share tokens, Matrix federation hints

**Identity integration:** Matrix @handle (from `SPEC_woodpecker_mobile.md` §2.7) — contact entry = `@handle` or vCard with optional phone number.

**Phase 0 (Squirrel):** local vCard only
**Phase 1 (Chimp):** Matrix @handle integration

---

## 4. file-manager (browse + share)

**Source:** `docs/archive/2026-06-15-plans/PLAN-file-manager.md` (8.9 KB, full)

**Goal:** Lightweight file manager (`appFiles` jail) for browsing and **sharing data between jails**. All FS access mediated through broker.

**Architecture:**
- Per-jail read-only mount of shared data
- No direct jail-to-jail mounts (broker mediates)
- File operations: copy between jails (broker-mediated), share via Matrix

**Phase 1 (Squirrel):** browse only
**Phase 2 (Chimp):** copy/share between jails via broker

---

## 5. media-player (mpv in jail)

**Source:** `docs/archive/2026-06-15-plans/PLAN-media-player.md` (8.1 KB, full)

**Goal:** Privacy-preserving audio/video playback via **mpv** in sandboxed jail. **No cloud streaming, no DRM.** Local files only.

**Formats:** MP3, FLAC, OGG, MP4, MKV
**Control:** broker IPC
**Telemetry:** volume/position tracking via Zenoh (`bsdos/media/<app_id>/state`)

**Privacy contracts:**
- No network (jail `ip4=disable`)
- No telemetry to outside
- Local file access only via `appData` jail (read-only mount)

**Phase 1 (Squirrel):** mpv + Zenoh state
**Phase 2 (Chimp):** hardware-accelerated decoding via Lima/Mali-400

---

## 6. notification-center (event-driven)

**Source:** `docs/archive/2026-06-15-plans/PLAN-notification-center.md` (5.7 KB, full)

**Goal:** Real-time, privacy-preserving notifications. **No external cloud** (FCM, APNs). Events from jails and system telemetry surface as UI banners on the host.

**Architecture:**
- Subscribes to Zenoh topics: `bsdos/notifications/*`, `bsdos/hal/*` (low battery, etc.)
- Aggregates and dedupes (5min window)
- Presents to QML UI on Mac (cross-device) or local QML (PinePhone)

**Privacy:**
- All notifications **local** by default
- Cross-device sync only via Liquid Workspace (trusted devices)
- No analytics on notification patterns

**Phase 0 (Squirrel):** local notifications only
**Phase 1 (Chimp):** cross-device via Liquid Workspace

---

## 7. app-gallery (default + optional apps catalog)

**Source:** `docs/archive/2026-06-15-plans/PLAN-app-gallery.md` (8.8 KB, full)

**Goal:** Default application suite (8 core apps as `.jpk` jail packages) + extensible app store for optional apps.

**Default suite (Squirrel):**
1. clipper
2. contacts
3. calendar
4. file-manager
5. media-player
6. notification-center
7. terminal (foot in cage)
8. browser (Firefox or wpewebkit-fdo in cage)

**Phase 1 (Chimp):** App Gallery UI to browse + install

---

## 8. app-store (decentralized)

**Source:** `docs/archive/2026-06-15-plans/PLAN-app-store.md` (8.4 KB, full)

**Goal:** Decentralized package distribution. **No centralized server.** Peer-to-peer via Zenoh mesh.

**Trust model:**
- Each `.jpk` signed with Ed25519 (per `SPEC_jpk_descriptor_v1.md`)
- Trust: chain of custody from developer key → user
- No central authority (Apple/Google/F-Droid pattern)

**Architecture:**
- App developer publishes `.jpk` to Zenoh topic `bsdos/app-store/<handle>/<app>/<version>`
- Other bsdOS instances discover via Zenoh discovery
- Auto-fetch on opt-in, manual review for first install

**Phase 2 (Chimp):** initial app store UI + signing flow

---

## 9. update-system (atomic OS + apps)

**Source:** `docs/archive/2026-06-15-plans/PLAN-update-system.md` (24 KB, full)

**Goal:** Update kernel, base OS, apps, daemons **atomically and safely** via ZFS snapshots + rollback.

**Three phases:**
1. **Phase 1 (Squirrel):** manual + `freebsd-update` (official FreeBSD releases)
2. **Phase 2 (Chimp):** `bsdos-pkgd` with Ed25519 verification, atomic ZFS clone swap
3. **Phase 3 (Woodpecker):** OTA via Zenoh mesh, auto-discovery

**Per-component:**
- **Kernel + FreeBSD base:** `freebsd-update` (official) or ZFS snapshot/swap (custom)
- **.jpk apps:** `bsdos-pkgd` with Ed25519 sig, atomic ZFS clone swap
- **Daemons + HAL:** `make` targets, deploy via `/opt/proto/` scripts

**Rollback:** ZFS snapshot before update; on failure, rollback to snapshot.

---

## 10. Common patterns (cross-app)

| Pattern | Description |
|---|---|
| **Per-jail data** | Each app has `/data/<app>/` for its data; broker-mediated only |
| **Per-jail devfs** | Apps only see devices they need (e.g., appCamera sees `/dev/video0` only) |
| **Zenoh pub** | Apps publish state to `bsdos/<app>/<id>/<state>` topics |
| **Capsicum** | Apps run with capabilities (no `root` after init) |
| **Lifecycle** | Apps suspend via SIGSTOP, resume via SIGCONT (see `docs/archive/2026-10-01-monorepo/PLAN-lifecycle-v2.md`) |
| **No network by default** | Apps declare network policy in `.jpk` descriptor (see `SPEC_jpk_descriptor_v1.md`) |

---

## 11. Source files (preserved for full detail)

```
docs/archive/2026-06-15-plans/
├── PLAN-clipper.md             (6.9 KB)  — §1
├── PLAN-calendar-app.md        (8.7 KB)  — §2
├── PLAN-contacts-app.md        (7 KB)    — §3
├── PLAN-file-manager.md        (8.9 KB)  — §4
├── PLAN-media-player.md        (8.1 KB)  — §5
├── PLAN-notification-center.md (5.7 KB)  — §6
├── PLAN-app-gallery.md         (8.8 KB)  — §7
├── PLAN-app-store.md           (8.4 KB)  — §8
└── PLAN-update-system.md       (24 KB)   — §9
```

---

## 12. Open questions

1. **clipper memory only:** When does it clear? (Screen lock? Jail suspend? Both?)
2. **calendar CalDAV:** Server-side encryption? Plaintext over WireGuard (per `SPEC_zenoh_security.md`)?
3. **contacts Matrix @handle:** Is the @handle the only identity, or do we keep phone number legacy?
4. **file-manager sandbox:** Can the user accidentally leak data by sharing from the wrong directory?
5. **media-player formats:** DRM content (Netflix, etc.) — explicitly out of scope, right?
6. **notification-center dedup:** Per-app or global? (e.g., 5 SMS from same sender = 1 notif or 5?)
7. **app-store trust chain:** Who is the root CA? (Developer self-sign + user opt-in?)
8. **update-system rollback:** ZFS snapshot before every update = disk overhead; do we snapshot only on major versions?

---

**Synthesized:** 2026-06-15, architect (claude-host / MiniMax M2.7).
**Source:** 9 PLAN files (~95 KB), reprocessed into ~10 KB synthesis.
**Replaces:** 9 standalone plans in archive.
