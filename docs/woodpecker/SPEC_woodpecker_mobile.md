# SPEC_woodpecker_mobile.md — PinePhone Mobile Subsystems (Woodpecker v0.3)

**Synthesized:** 2026-06-15 (architect, claude-host / MiniMax M2.7)
**Status:** Active specification (Woodpecker v0.3 — PinePhone)
**Target hardware:** PinePhone (Allwinner A64, Cortex-A53, 2 GB RAM, 3000 mAh)
**OS:** oBzdOS (OpenBSD aarch64) — TODO: OpenBSD driver audit needed (was FreeBSD 15.1)
**Synthesizes:** 10 legacy `PLAN-*.md` files (see §"Source files" below for full citation)

> **Codename:** Woodpecker (Дятел) — oBzdOS v0.3, paranoid mobile stage.
> Squirrel v0.1.x = QEMU sandbox (bsdOS/FreeBSD), Chimp v0.2 = Banana Pi (bsdOS/FreeBSD), Woodpecker v0.3 = PinePhone (**oBzdOS/OpenBSD**).
> See `ROADMAP.md` for full codename scheme.

**See also:**
- `docs/specs/SPEC_woodpecker_thermal.md` — thermal throttling (mobile hotspot)
- `docs/specs/SPEC_woodpecker_power.md` — power management (Ghost Radio, C-states)
- `docs/specs/SPEC_woodpecker_hal.md` — HAL contract (Zig interfaces)
- `docs/specs/SPEC_zenoh_keyspace.md` — Zenoh topic namespace (mobile uses `bsdos/sensors/*`, `bsdos/hal/*`)
- `docs/archive/2026-10-01-monorepo/PLAN-gpu-bringup.md` — Mali-400 GPU (display acceleration)
- `docs/specs/SPEC_chimp_jail_networking.md` — VNET jails (per-app network isolation)

---

## 0. Scope

Woodpecker v0.3 adds **mobile phone capabilities** to **oBzdOS** (OpenBSD) on PinePhone (Allwinner A64):

1. **Wireless I/O:** Bluetooth (audio + HID), GPS, NFC, USB Gadget (tethering)
2. **Imaging:** Camera (5MP OV5640, USB UVC for Phase 0)
3. **Identity:** Biometric (fingerprint FPC1145), IMSI protection (Ghost Radio)
4. **Telephony:** Modem AT commands, voice (Matrix E2EE), SMS, emergency data destruction
5. **USB device mode:** CDC-ECM (tethering), mass storage (ZFS export), CDC-ACM (serial console)

All subsystems are exposed through the **Zig HAL** (HAL contract in `SPEC_woodpecker_hal.md`) and gated by **per-jail permissions** (Capsicum + devfs rulesets, see `SPEC_chimp_jail_networking.md`).

**Critical design constraint:** every mobile subsystem has an **OpenBSD reality gap** that requires either porting, custom drivers, or fallback to a simpler implementation. Each subsystem is phased accordingly. (TODO: full OpenBSD driver availability audit needed.)

---

## 1. Architecture (Woodpecker mobile)

```
PinePhone (Allwinner A64 / oBzdOS — OpenBSD aarch64)
┌─────────────────────────────────────────────────────────────┐
│ QML UI (matrix room, dialer, settings)                        │
│   ├─ Phone app: dialer, contacts (Matrix @handle)             │
│   ├─ Settings: airplane mode (GPIO write), perms             │
│   └─ Emergency: 5× power / SMS code → ZFS unload-key         │
│      ↑ Zenoh: matrix/user/<id>/presence, sensors/*           │
├─────────────────────────────────────────────────────────────┤
│ appTelephony jail (VNET, ip4=disable by default)             │
│   ├─ Matrix client: E2EE voice (Opus/RTP via Zenoh)          │
│   ├─ sms daemon: AT+CMGS, AT+CMGR, AT+CNMI listener          │
│   └─ EG25-G modem: /dev/cuaU0 (115200 baud, AT commands)     │
│      ↑ Zenoh: bsdos/sensors/radio_state, bsdos/telephony/*    │
├─────────────────────────────────────────────────────────────┤
│ appSensors jail (VNET, ip4=disable)                          │
│   ├─ Zig HAL: GPS (NMEA 0183 from /dev/ttyU1)                │
│   ├─ Zig HAL: NFC (PN532 I2C, NDEF parser)                   │
│   ├─ Zig HAL: Biometric (FPC1145 SPI, libfprint fallback)    │
│   ├─ Zig HAL: Camera (OV5640 MIPI CSI-2 native or UVC)       │
│   └─ Zig HAL: Battery (AXP803 I2C, see SPEC_woodpecker_hal)   │
│      ↑ Zenoh: bsdos/sensors/{gps,nfc,camera,battery}         │
├─────────────────────────────────────────────────────────────┤
│ Kernel: FreeBSD 15.1 + bsdOS patches                         │
│   ├─ Allwinner A64 SoC drivers (aw_gpio, aw_thermal)         │
│   ├─ I2C/SPI/GPIO via /dev/iic*, /dev/spi*, GPIO sysfs       │
│   ├─ Custom: RTW88 (RTL8723CS WiFi/BT), V4L2 equivalent     │
│   └─ devfs rulesets: 31=camera, 100=gps, 110=nfc, ...       │
└─────────────────────────────────────────────────────────────┘
                            │ Zenoh peer mode
                            ▼
                  Mac/Linux (metal-viewer) +
                  other bsdOS nodes (Liquid Workspace)
```

**Key Zenoh topics** (see `SPEC_zenoh_keyspace.md` for full namespace):
- `bsdos/sensors/{gps,nfc,camera,battery,radio_state,biometric}`
- `bsdos/telephony/{sms,call_state,signal_strength}`
- `bsdos/hal/airplane_mode` (read: state, write: set)
- `bsdos/emergency/{level1_soft_erase,level2_destroy,level3_physical}` (audit log)

---

## 2. Subsystem specs

Each subsection summarizes the legacy PLAN's content, FreeBSD reality check, and phase plan.

### 2.1 Bluetooth (RTL8723CS)

**Source:** `docs/archive/2026-06-15-plans/PLAN-bluetooth.md` (16 KB, full)
**Hardware:** Realtek RTL8723CS (WiFi 802.11 b/g/n + Bluetooth 4.0, combo chip)
**Interface:** SDIO (WiFi) + UART (BT firmware)
**FreeBSD reality:** NO driver in base; ng_bt(4) stack exists; A2DP may not have analog

**Phases:**
- **Phase 0:** Check chip detection (`usbconfig list`, `dmesg | grep realtek`)
- **Phase 1:** Firmware (`rtlwifi/rtl8723cs_nic.bin` + `rtl_bt/rtl8723cs_bt.bin`)
- **Phase 2:** WiFi driver port from Linux `morrownr/rtl8723cs` (~3k LOC C)
- **Phase 3:** BT stack + HID (keyboard, mouse), A2DP if analog available

**HAL contract:**
```zig
// get_bluetooth_state → {power, devices[], a2dp_active}
pub fn getBluetoothState(allocator) ![]u8;
// set_bluetooth_power → {ok}
pub fn setBluetoothPower(enabled: bool) ![]u8;
```

**Risk:** RTL8723CS in FreeBSD = unknown territory. Budget: months, not days.

### 2.2 GPS (Quectel L96)

**Source:** `docs/archive/2026-06-15-plans/PLAN-gps.md` (5 KB, full)
**Hardware:** Quectel L96 GNSS module
**Transport:** UART `/dev/ttyu1` or `/dev/ucom0`
**Protocol:** NMEA 0183 (RMC, GGA, GSA, GSV)
**Precision:** ~5m A-GPS, 10m worst-case
**Update rate:** 1 Hz (configurable to 10 Hz)

**Privacy contract:** GPS location **NEVER** leaves the device. Available only to jails with explicit permission. No network broadcast, no telemetry.

**devfs ruleset:**
```
rule 100 path ttyU1 unhide
rule 100 path ucom0 unhide
```

**HAL contract:**
```zig
// get_location → {lat, lon, accuracy_m, valid}
pub fn getLocation(allocator) ![]u8;
```

**QEMU stub:** Return mock location `{lat: 59.9139, lon: 10.7522, accuracy_m: 5}`.

### 2.3 Camera (OV5640)

**Source:** `docs/archive/2026-06-15-plans/PLAN-camera.md` (5 KB, full)
**Hardware:** OV5640 5MP, MIPI CSI-2
**FreeBSD reality:** NO MIPI CSI-2 driver in base; V4L2 doesn't exist; `video(4)` is USB UVC only

**Decision (locked):** Phase 0 uses **USB UVC camera** (external) via `webcamd`; native OV5640 deferred to Phase 2.

**HAL contract:**
```zig
// capture_frame → {frame_id, width, height, format, jpeg_bytes}
pub fn captureFrame(allocator) ![]u8;
```

**Zenoh pub:** `bsdos/sensors/camera` (raw frame batch, configurable rate).

### 2.4 NFC (PN532)

**Source:** `docs/archive/2026-06-15-plans/PLAN-nfc.md` (6.5 KB, full)
**Hardware:** NXP PN532, I2C
**FreeBSD reality:** NO native driver; `libnfc` partial (USB HID PN532 only); I2C subsystem OK (`iic(4)`, `/dev/iic*`)

**Use cases:** Contactless payments, device pairing, smart tags, physical keys (jail unlock).

**Decision (locked):** Phase 0 = USB PN532 + libnfc POC; Phase 1+ = native I2C Zig driver.

**HAL contract:**
```zig
// nfc_read_tag → {uid, ndef_records[]}
pub fn nfcReadTag(allocator) ![]u8;
```

**Zenoh pub:** `bsdos/sensors/nfc/tag_detected` (UID, NDEF records).

### 2.5 Biometric (FPC1145)

**Source:** `docs/archive/2026-06-15-plans/PLAN-biometric.md` (8 KB, full)
**Hardware:** FPC1145 fingerprint sensor, SPI @ 4-5 MHz
**Resolution:** 160×160 px
**Latency:** ~100ms capture, ~500ms template match
**FreeBSD reality:** NO FPC1145 driver; libfprint Linux-only; USB fallback via libusb

**Use cases:** Screen unlock, app permission grant, SSH key unlock (all fallback to PIN).

**HAL contract:**
```zig
// biometric_capture → {template_id, match_score}
pub fn biometricCapture(allocator) ![]u8;
```

**Integration:** Custom PAM module (`pam_bsdos_bio.so`) wraps HAL; falls back to `pam_unix` on error.

### 2.6 IMSI Protection (Ghost Radio)

**Source:** `docs/archive/2026-06-15-plans/PLAN-imsi-protection.md` (2.9 KB, full)
**Threat:** IMSI Catcher (StingRay, RCIED) — rogue base station forces phone to reveal IMSI every 2-5 min on network attach.

**bsdOS design:** Minimize IMSI leakage window to <3 sec via **burst-mode radio**.

**Architecture (4 layers):**
1. **Ghost Radio Burst Mode** — `crypto-sleep → wake RTC timer → radio ON 3 sec → attach → radio OFF`
   - EG25-G `AT+CFUN=1` (radio on), wait attach, `AT+CFUN=0` (radio off)
   - `/dev/cuaU0` (FreeBSD UART) driven by Zig async task
   - Zenoh pub: `bsdos/hal/radio_state {on, duration_ms, imsi_visible}`
2. **IMSI Randomization** — if EG25-G v2+ supports fake IMSI via Quectel custom cmd; fallback: disable IMSI in 3GPP register (network assigns temp TMSI only)
3. **SIM PIN Auto-Lock** — `bsdos-sim-init` reads encrypted `/opt/proto/data/sim.pin`, `AT+CPIN=PIN` on every boot
4. **Matrix @handle Mode** — replace phone number with Matrix @handle (no PII in calls)

### 2.7 Telephony (Matrix E2EE voice + PF ad-blocking)

**Source:** `docs/archive/2026-06-15-plans/PLAN-telephony.md` (14 KB, full)
**Critical gate:** HAL Phase 2c (modem AT commands) + 2d (GPIO airplane mode) — see `SPEC_woodpecker_hal.md`.

**Stack:**
- **Plasma Mobile UI** (QML) — phone app, settings (airplane mode toggle → GPIO write)
- **Matrix client** — E2EE voice (Opus/RTP over Zenoh), text messaging, identity = @handle
- **EG25-G modem** (FreeBSD UART `/dev/cuaU0`, 115200 baud)
- **PF firewall** — AD-blocking rules (host-side, BSD-side; mirrored to Mac for app-level filtering)
- **GPIO airplane mode** — write to `aw_gpio0` pin for RF kill

**Privacy contracts:**
- Phone number optional; @handle is primary identity
- AD-blocking via PF + DNS-over-TLS (DoT) resolver
- Modem firmware updates via signed images (no MITM)

**Phases:**
- **Phase 0:** HAL modem AT (`AT+CIMI`, `AT+CFUN`, `AT+CPIN`)
- **Phase 1:** Matrix client + E2EE voice
- **Phase 2:** PF AD-blocking, DoT
- **Phase 3:** Modem firmware signing, IMSI protection (from §2.6)

### 2.8 SMS

**Source:** `docs/archive/2026-06-15-plans/PLAN-sms.md` (3.9 KB, full)
**Transport:** `/dev/cuaU0`, 115200 baud, text mode (`AT+CMGF=1`)

**AT commands (full table in source):**
| Command | Function |
|---|---|
| `AT+CMGF=1` | Text mode |
| `AT+CMGS="+1234567890"` | Send SMS |
| `AT+CMGL="ALL"` | List all |
| `AT+CMGR=1` | Read #1 |
| `AT+CMGD=1` | Delete #1 |
| `AT+CNMI=3,1,0,1` | Incoming notifications (URC) |

**Phases:**
- **Phase 1:** `sms_send`, `sms_list` (send only)
- **Phase 2:** `sms_read`, `sms_delete` (parse message store)
- **Phase 3:** Incoming daemon (`AT+CNMI` async reader → broker → Matrix bridge)

**JSON shape:** `{"ok":true,"value":{"from":"+1234","body":"Hello","timestamp":"2024-01-01 10:00"}}`

### 2.9 Emergency Mode (data destruction)

**Source:** `docs/archive/2026-06-15-plans/PLAN-emergency-mode.md` (5 KB, full)

**Triggers (3 levels):**
- **Level 1 (Soft Erase):** 5× rapid power press (within 2s), panic fingerprint, battery < 3%
- **Level 2 (Data Destroy):** SMS to device with pre-shared rotating code (e.g., `NUKE:xyz123abc`); hold power+vol-down 10s
- **Level 3 (Physical Destroy):** PIN + specialized GPIO to eMMC; **TODO** awaits oBsdOS enclosure design

**Level 1 actions:**
```sh
zfs unload-key -r bsdos
# All keys under bsdos pool unloaded
# Profiles, messages, keys locked behind encryption
# Recovery possible only with master key

/opt/proto/sbin/crypto-sleep
# Wipe /tmp, /var/tmp, buffers
# SIGUSR1 to running daemons → flush caches
```

**Audit:** All emergency events logged to `bsdos/emergency/*` (immutable Zenoh topic).

### 2.10 USB Gadget (tethering, mass storage, serial)

**Source:** `docs/archive/2026-06-15-plans/PLAN-usb-gadget.md` (13 KB, full)
**Hardware:** PinePhone USB-C OTG, Allwinner A64 USB 2.0 PHY

**Modes (3 of 5):**
- **Phase 0: CDC-ECM (ethernet tethering)** — phone as USB ethernet → internet sharing
- **Phase 1: Mass storage** — ZFS dataset as USB flash (FAT32/exFAT for host)
- **Phase 2: CDC-ACM (serial console)** — UART over USB-C, no separate adapter
- **Auto-switching:** env var or sysctl selects mode
- **Diagnostics:** `dmesg` shows mode; ready via `/dev/ttyU*` or `/dev/daX`

**NOT in scope:** DFU (U-Boot required), MTP (Windows-specific), USB HID (BT HID sufficient), hot-swap (Phase 0 simplification).

---

## 3. Per-jail devfs rulesets (synthesis)

| Ruleset | Path | Jail |
|---|---|---|
| 31 | `unhide /dev/video0` | appCamera |
| 100 | `unhide /dev/ttyU1 ucom0` | appGPS |
| 110 | `unhide /dev/iic0` | appNFC |
| 120 | `unhide /dev/spi0` | appBiometric |
| 130 | `unhide /dev/cuaU0` | appTelephony |
| 140 | `unhide /dev/uhid*` | appBluetooth (HID) |

**Capsicum capabilities** (see `SPEC_chimp_security.md` — chimp-side spec for v0.2; on Woodpecker this is mandatory):
- `CAP_IOCTL` for all `/dev/*` access
- `CAP_READ` / `CAP_WRITE` per device
- `CAP_FSYNC` for atomic state updates
- `CAP_EVENT` for Zenoh pub

---

## 4. Privacy & Security invariants (cross-cutting)

1. **No silent exfiltration:** Mobile data (GPS, camera, biometric, telephony) is **never** published to a topic that's not jail-scoped + permission-checked
2. **Local-only by default:** GPS, NFC, biometric, IMSI are local-only; only triggered by explicit app request
3. **IMSI minimal exposure:** Ghost Radio limits IMSI visibility to <3 sec/burst (see §2.6)
4. **Audit trail:** Emergency events (Level 1+) published to immutable Zenoh topic
5. **Capsicum enforcement:** All mobile daemons run in capability mode (no `root` after init)
6. **No PII in topic names:** Topics use UUIDs or opaque handles, not phone numbers

---

## 5. Phase plan (synthesis)

| Phase | Subsystems | Pre-req |
|---|---|---|
| **Phase 0** | USB camera (UVC), GPS (QEMU stub), SMS send, Emergency L1 | HAL stub (QEMU) |
| **Phase 1** | GPS (real hw), SMS full, Bluetooth detection, USB Gadget CDC-ECM | HAL I2C/UART on real hw |
| **Phase 2** | NFC (USB libnfc), Camera native (OV5640 driver), Telephony Matrix, IMSI protection | HAL Phase 2c/2d, Modem driver |
| **Phase 3** | Biometric (FPC1145 SPI), Bluetooth audio, Emergency L2, USB Gadget mass storage | libfprint port, FPC1145 driver |
| **Phase 4** | Emergency L3 (physical destroy), USB Gadget CDC-ACM | oBsdOS enclosure design |

**Critical dependency tree:**
- §2.7 Telephony ← HAL modem AT (Phase 2c)
- §2.6 IMSI protection ← HAL modem AT (Phase 2c)
- §2.4 NFC ← HAL I2C
- §2.5 Biometric ← HAL SPI
- §2.10 USB Gadget ← Allwinner USB OTG driver (in base, verify)

---

## 6. Source files (preserved for full detail)

This SPEC is a synthesis. For the **full per-subsystem design** (registers, AT commands, devfs rules, Phases 0-3+), see:

```
docs/archive/2026-06-15-plans/
├── PLAN-bluetooth.md         (16 KB) — §2.1
├── PLAN-gps.md              (5 KB)  — §2.2
├── PLAN-camera.md           (5 KB)  — §2.3
├── PLAN-nfc.md              (6.5 KB)— §2.4
├── PLAN-biometric.md        (8 KB)  — §2.5
├── PLAN-imsi-protection.md  (2.9 KB)— §2.6
├── PLAN-telephony.md        (14 KB) — §2.7
├── PLAN-sms.md              (3.9 KB)— §2.8
├── PLAN-emergency-mode.md   (5 KB)  — §2.9
└── PLAN-usb-gadget.md       (13 KB) — §2.10
```

These files are **kept** (not deleted) per 2026-06-15 user feedback —
they contain detailed register maps, AT command sequences, devfs rules,
and Phase 0-3+ rollouts that this synthesis summarizes.

---

## 7. Open questions

1. **Bluetooth A2DP analog:** If ng_bt(4) has no A2DP, do we accept "no audio" or write a custom A2DP layer (months of work)?
2. **Camera driver port:** Is there a Linux MIPI CSI-2 driver we can adapt, or do we write from scratch? (Estimate: 6+ months)
3. **EG25-G IMSI randomization:** Does the modem firmware support fake IMSI? If not, do we accept TMSI-only fallback or flash custom firmware?
4. **Matrix @handle vs phone number:** Is @handle the **only** identity (Apple/Google-style), or do we keep phone number as legacy fallback?
5. **Emergency L3 hardware:** Who designs the oBsdOS enclosure with the GPIO wire to eMMC?
6. **РЕШЕНО 2026-06-24 — целевой девайс = оригинальный PinePhone (A64), НЕ Pro.** Причина: A64 + Mali-400 — тот же SoC что BPI-M64 (Chimp v0.2), драйверы/HAL переносятся 1:1. (Реальный PinePhone Pro — RK3399/Mali-T860/EG25-G — это ДРУГОЙ SoC и НЕ наш таргет; см. `SPEC_chimp_release.md`. Pine64 к тому же сворачивает Pro в пользу RISC-V — ещё один довод за A64.) Остаётся отслеживать доступность самого оригинального PinePhone (или PinePhone 2 на том же/совместимом A-классе) в 2026.

---

**Synthesized:** 2026-06-15, architect (claude-host / MiniMax M2.7).
**Source:** 10 PLAN files (78 KB), reprocessed into ~17 KB synthesis.
**Replaces:** 10 standalone plans in archive.
