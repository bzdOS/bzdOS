# SPEC_jpk_descriptor_v1.md — `.jpk` package descriptor format

**Date:** 2026-06-15
**Status:** Draft v1 (architect design)
**Owner:** architect (claude-host / MiniMax M2.7)
**Supersedes:** partial design in `PLAN-app-store.md` § Package Flow
**Targets:** bsdOS codenames "Squirrel / sQuirrel" (v0.1.x, QEMU) → "Chimp" (v0.2, Allwinner H616/H618/A523 on Banana Pi) → "Porcupine" (v0.3, Allwinner A64 + Mali-400 + Mesa Lima on PinePhone) — per the animal-progression naming scheme in `ROADMAP.md`.

---

## 1. Цель

`.jpk` (Jail Package) — single-file archive containing:
- A **TOML descriptor** (`jpk.toml`) declaring metadata, deps, runtime topology, permissions
- A **payload tarball** with the actual application code + resources
- A **signature block** (Ed25519, detached) for trust

Цель — единый формат который:
- Задекларированно говорит "что эта программа хочет" (caps, RAM, GPU, audio, network)
- Самодостаточен (можно установить без сетевого доступа к реестру, если уже скачан)
- Подписан (доверенный автор → доверенный пакет)
- Поддерживает **bsdOS codename ladder** (sQuirrel/Banana Pi/PinePhone) как поле совместимости
- Поддерживает **Mesa Lima acceleration** как first-class (apps могут декларировать Mali-400/450 GLES requirements)

---

## 2. Файловая структура `.jpk`

`.jpk` — это **tar+gzip** archive с **JSON sidecar** (для tooling) и **TOML descriptor** (canonical):

```
app.jpk
├── jpk.toml             # canonical descriptor (TOML, see §3)
├── jpk.json             # mirror of jpk.toml for tooling that doesn't grok TOML
├── payload.tar          # the actual application files (untarred to /opt/proto/data/<app_id>/)
├── signature.ed25519    # detached Ed25519 signature over (jpk.toml + payload.tar) SHA-256 hash
├── cert.pem             # developer's Ed25519 public key (PEM format)
├── manifest.json        # { "files": [{"name": "jpk.toml", "sha256": "..."}, ...] }
└── build-info.txt       # { "build_host": "...", "freebsd_version": "...", "bsdos_codename": "...", "build_timestamp": "..." }
```

**Archive command** (per `bsdos-pkgd build`):
```sh
$ bsdos-pkgd build app/         # creates the tar + metadata
$ bsdos-pkgd sign --key ~/.bsdos/dev.key app.jpk   # adds signature
```

**Archive inspection** (per `bsdos-pkgd inspect`):
```sh
$ bsdos-pkgd inspect app.jpk     # prints jpk.toml + signature status
$ bsdos-pkgd verify app.jpk     # checks signature + manifest hashes
$ tar -tzf app.jpk              # raw archive listing
```

---

## 3. Descriptor (`jpk.toml`) schema

```toml
# === Metadata (required) ===
[meta]
schema_version    = "1.0"
id                = "org.bsdos.firefox"   # reverse-DNS, unique per package
version           = "0.1.0"              # semver
name              = "Firefox"            # human-readable
description       = "Web browser for bsdOS"
homepage          = "https://firefox.bsdos.org"
license           = "MPL-2.0"
authors           = ["Mozilla Foundation", "bsdOS port team"]
maintainer        = "ports@bsdos.org"

# === Codename compatibility (required) ===
# Which bsdOS release-lines this .jpk supports. Gate for v0.2/v0.3
# hardware port. bsdOS-codename field mirrors ROADMAP.md scheme.
[compatibility]
bsdos_codename_min  = "Squirrel"   # earliest line supported (v0.1.x); sQuirrel alias accepted
bsdos_codename_max  = "Porcupine"  # latest line tested (v0.3)
freebsd_min         = "15.1"       # FreeBSD version floor
freebsd_max         = "16.0"       # ceiling (exclusive)
arch                = ["aarch64", "amd64"]   # supported CPU arches

# === Runtime topology (required) ===
[runtime]
type            = "jail"          # only "jail" in v1; future: "vm", "container"
jail_name       = "appBrowser"    # FreeBSD jail(2) name
needs_wayland   = true            # declares Wayland stream subscriber
needs_input     = true            # declares input event subscriber
needs_gpu       = true            # declares Mesa Lima GLES requirements
needs_audio     = false           # for v0.3 only (audio_bridge.zig)
needs_modem     = false           # for v0.3 only (LTE modem)

# === GPU (Mesa Lima) requirements ===
# If needs_gpu = true, this section is required.
# For v0.2 Banana Pi (Allwinner H616/H618/A523 with Mali-G31) and
# v0.3 PinePhone (Allwinner A64 with Mali-400), Lima provides GLES
# acceleration. Apps declare GLES version + extensions required.
[gpu]
gles_major      = 2               # GLES major version
gles_minor      = 0               # GLES minor version
extensions     = ["GL_OES_element_index_uint", "GL_EXT_texture_format_BGRA8888"]
max_texture_size = 4096
needs_shaders   = true            # if false, app uses GLES fixed-pipeline only
prefer_arm_neon = true            # hint: app uses NEON SIMD (ARM only)

# === Hardware features (v0.2+ Allwinner) ===
# Apps can declare CPU feature requirements. Allwinner H6/H616/H618/A64
# all have NEON + VFPv4. Apps that use SIMD should declare.
[hw]
features        = ["neon", "vfpv4", "crc32"]   # required CPU features
big_endian      = false                          # all Allwinner is LE

# === Dependencies (required, may be empty) ===
[dependencies]
# Either exact version or semver range
firefox_runtime = ">=0.1.0, <1.0.0"
bsdos_hal       = ">=0.1.0"        # HAL Zig module
bsdos_compositor = ">=0.1.0"      # cage/weston integration
optional_jpks   = ["org.bsdos.webextensions@^0.2.0"]

# === Permissions / sandboxing (required) ===
[permissions]
# FreeBSD Capsicum capability rights, applied via cap_enter() after fork
capabilities    = ["CAP_READ", "CAP_WRITE", "CAP_EVENT", "CAP_FSYNC"]
network         = "inet"          # "none" | "inet" | "inet6" | "unix-only"
filesystem      = "ro"            # "ro" | "rw" | "private-tmpfs"
max_open_files  = 1024
max_memory_mb   = 512
max_cpu_percent = 50              # soft cap; rctl(8) enforcement
max_disk_mb     = 1024            # ZFS dataset quota
network_ingress = false           # outgoing only? (privacy mode for browsers)
network_egress  = true

# === Lifecycle hooks (optional) ===
[hooks]
pre_install     = "echo 'Installing Firefox...'"
post_install    = "ldconfig /opt/proto/data/appBrowser/lib"
pre_run         = "/opt/proto/data/appBrowser/bin/wrapper --init"
post_run        = "/opt/proto/data/appBrowser/bin/wrapper --cleanup"
on_signal       = "SIGTERM: graceful-shutdown, SIGKILL: immediate"

# === Build provenance (required) ===
[build]
source_url      = "https://github.com/bsdos/firefox-port"
source_commit   = "abc123def456"          # git SHA
build_host      = "freebsd-builder-01.bsdos.local"
build_timestamp = "2026-06-15T14:00:00Z"
build_user      = "builder"
reproducible    = true                       # if true, build script available
build_script_url = "https://github.com/bsdos/firefox-port/blob/abc123/build.sh"
freebsd_version = "15.1-RELEASE"
cargo_lock_sha256 = "..."                   # for Rust dependencies
zig_version    = "0.15.2"                   # for Zig HAL deps

# === Update / lifecycle ===
[update]
channel         = "stable"        # "stable" | "beta" | "nightly" | "frozen"
auto_update     = false           # if true, bsdos-pkgd pulls without user
deprecates      = []              # list of old version strings this supersedes
security_advisories = ["https://bsdos.org/security/firefox"]

# === Metadata for discovery ===
[discovery]
keywords        = ["browser", "web", "firefox", "rendering"]
category        = "Network"       # "Network" | "Media" | "Productivity" | "System" | "Game" | "Dev"
screenshot      = "preview.png"  # path inside payload.tar
icon            = "icon.svg"      # path inside payload.tar
localized_names = { "ru" = "Firefox", "en" = "Firefox" }
```

---

## 4. Архитектурные решения (decisions log)

### 4.1 Почему TOML, не JSON/YAML/CBOR?

| Format | Pros | Cons | Verdict |
|--------|------|------|---------|
| **TOML** | Строгие типы, комментарии, стандарт de-facto (Cargo, Spacewalk) | Чуть многословнее | ✅ **chosen** |
| JSON | Универсально, инструменты | Нет комментариев, числа → strings | ❌ |
| YAML | Читаемо, комментарии | Indentation-trap, медленнее парсинг | ❌ |
| CBOR | Бинарный, быстрый | Нет human-readable слоя | ❌ |

**Decision:** TOML canonical + JSON mirror в архиве (для tooling).
Обоснование: bsdOS уже использует TOML (например для `BSDOS_AUTOSTREAM`-like configs). Зеркало в JSON даёт fast-path для tooling.

### 4.2 Почему "codename_min/max", не "version: 0.2.x"?

Codename scheme (sQuirrel/Banana Pi/PinePhone) — это **release-line** abstraction.
Версия "0.2.0" — это **patch-level**. App может работать на sQuirrel (v0.1.x), Banana Pi (v0.2), PinePhone (v0.3), но не на pre-sQuirrel. `version` field (semver) описывает app version, `bsdos_codename_min/max` описывает bsdOS compatibility.

Pattern: semver для app, codename ladder для platform.

### 4.3 Почему `needs_gpu` / `needs_wayland` / `needs_audio`?

Apps могут декларировать **что они хотят от runtime**. Это позволяет:
- `bsdos-core` принимать решения о placement (CPU vs GPU jail, sandbox level)
- power-management знать какие jails можно останавливать в sleep mode
- dependencies-resolver не ставить app без нужного runtime component

Пример: `bsdos-firefox` говорит `needs_gpu = true` + `gles_major = 2` → install pathway проверяет что bsdOS-codename ≥ Banana Pi (Lima mandatory) и FreeBSD 15.1+ (Mesa package available).

### 4.4 Почему "build_info.reproducible"?

Reproducible builds — long-term goal bsdOS. Если `reproducible = true`, то `bsdos-pkgd verify` может пересобрать из source_url + source_commit + build_script_url и сравнить SHA-256. Это анти-typosquatting measure.

### 4.5 Permissions / sandboxing model

bsdOS уже имеет Capsicum support (per `PLAN-capsicum.md`). `.jpk` декларирует required capabilities; bsdos-core при install применяет `cap_enter()` после fork. Это **defense in depth**: даже если app скомпрометирован, capabilities ограничивают damage.

Field-level rationale:
- `capabilities`: какие cap_rights_t биты нужны (READ, WRITE, EVENT, FSYNC, ...)
- `network`: "none" | "inet" | "inet6" | "unix-only" — а не просто bool
- `filesystem`: "ro" | "rw" | "private-tmpfs" — ZFS snapshot semantics
- `max_*`: rctl(8) limits (FreeBSD resource control)
- `network_ingress/egress`: для privacy-mode apps (browser: in only)

### 4.6 Почему Ed25519?

- Быстрый (≈ 100x быстрее RSA при verify)
- Маленькие подписи (64 байта vs 256 для RSA)
- Deterministic (тот же ключ + message → та же подпись; важно для reproducible)
- Stdlib в Go/Rust/Zig
- Уже в PLAN-app-store.md; менять не нужно

### 4.7 Почему не tuf / sigstore / cosign?

TUF и in-toto/TUF — для ОЧЕНЬ больших экосистем (PyPI, npm). Overkill для bsdOS. Cosign требует OIDC infrastructure (Rekor, Fulcio). bsdOS — peer-to-peer, no central server → no OIDC.

Простой Ed25519 — best fit. Future v2 может добавить transparency log (类似 Sigstore Rekor, но на Zenoh peer-to-peer).

---

## 5. Сценарии использования

### 5.1 Install flow (developer → user)

```
Developer:                                User:
                                                
1. bsdos-pkgd build app/                   
2. → app.jpk (tar + manifest + 
3.   jpk.toml + signature)                 
4. bsdos-pkgd sign --key ~/.bsdos/dev.key 
5. → adds Ed25519 signature               
6. bsdos-pkgd publish app.jpk              
7. → Zenoh PUT bsdos/store/<id>/<ver>     
                                          
                                          8. bsdos-pkgd search browser
                                          9. → GET bsdos/store/search → list
                                          10. bsdos-pkgd install firefox
                                          11. → GET bsdos/store/org.bsdos.firefox/0.1.0
                                          12. → verify signature, manifest, hashes
                                          13. → check bsdos_codename_min/max compat
                                          14. → if compat, mount payload.tar to /opt/proto/data/appBrowser/
                                          15. → create ZFS dataset, apply cap_enter with declared capabilities
                                          16. → spawn jail with pre_run hook
                                          17. → ready: app running, sandboxed
```

### 5.2 Upgrade flow

```
$ bsdos-pkgd update
→ checks Zenoh bsdos/store/<id>/<latest> for new versions
→ for each upgrade:
  - download new .jpk
  - verify signature matches previous (same author key)
  - check [update].deprecates — refuses to install if user is on a deprecated version
  - if channel = "stable", auto-apply; if "beta", prompt
  - atomic swap: mount new dataset, swap jail to new image
```

### 5.3 Mesa Lima verification (v0.2+)

```
$ bsdos-pkgd inspect firefox | grep gpu
needs_gpu = true
gles_major = 2
prefer_arm_neon = true

# On Banana Pi (v0.2 'Banana Pi'):
$ lima-check firefox
✓ Lima driver loaded
✓ GLES2 context created
✓ NEON instructions available
✓ App can use GPU acceleration

# On QEMU sQuirrel (v0.1):
$ lima-check firefox
✗ Lima driver not available (CPU emulation)
⚠ App will fall back to CPU rendering (slow but works)
```

---

## 6. Validation rules

`bsdos-pkgd install` проверяет перед mounting:

1. **Signature valid** (Ed25519 over `jpk.toml + payload.tar` SHA-256)
2. **Manifest matches** (every file's SHA-256 matches manifest.json)
3. **Schema version** (`schema_version = "1.0"`)
4. **ID format** (reverse-DNS, lowercase, no special chars)
5. **Version format** (semver 2.0)
6. **Codename ladder** (`bsdos_codename_min ≤ current_codename ≤ bsdos_codename_max`)
7. **FreeBSD version** (`freebsd_min ≤ current_version < freebsd_max`)
8. **Architecture** (`arch` includes current_arch)
9. **Dependencies** (all declared deps already installed at compatible versions)
10. **Hardware features** (current CPU has all `features`; if `prefer_arm_neon = true` and CPU is x86, warning not error)
11. **GPU requirement** (if `needs_gpu = true`, Lima or other GLES backend must be available; if v0.1 codename, warning not error)

Если любая проверка fails — refuse to install, show error.

---

## 7. Backward compatibility & versioning

- `schema_version = "1.0"` (in jpk.toml): required. Future `1.1` / `2.0` добавляют новые fields, не ломая старые
- `bsdos-pkgd` должен читать schema v1.0 minimum; v1.1+ fields — ignore (forward compat)
- `bsdos-pkgd` пишет v1.0 minimum, добавляет new fields по мере need
- Cross-codename install: `bsdos_codename_min ≤ current_codename` is the only check. Например, app с `bsdos_codename_min = "sQuirrel"` может быть установлен на любой codename ≥ sQuirrel

---

## 8. Implementation plan (для runner/system)

| Step | Owner | Estimate | Output |
|------|-------|----------|--------|
| 8.1 Write `bsdos-pkgd` Rust crate: parser for jpk.toml | system (Qwen 3.7) | 1 wk | `bsdos_pkgd::parse::descriptor()` |
| 8.2 Ed25519 sign/verify wrapper | system | 2 d | `bsdos_pkgd::crypto::ed25519` |
| 8.3 Archive builder (tar+jpk.toml+signature) | system | 3 d | `bsdos_pkgd::build` |
| 8.4 Install path: Zenoh fetch + verify + extract to /opt/proto/data/ | system | 1 wk | `bsdos_pkgd::install` |
| 8.5 Permission enforcement: cap_enter + rctl on spawn | system | 3 d | uses `bsdOS-jail-prototype` |
| 8.6 CLI subcommands: build, sign, publish, search, install, inspect, verify, update, lima-check | runner (cheap) | 2 d | `bsdos-pkgd` binary |
| 8.7 Hub registry: Zenoh keyspace `bsdos/store/<id>/<ver>` | system | 1 wk | publish + search endpoints |
| 8.8 Tests: unit + integration (in-process Zenoh peer) | qa | 1 wk | ≥30 unit tests |
| **Total** | | **~7 weeks** | full v1.0 implementation |

---

## 9. Open questions

1. **Reproducible builds** — can we achieve this in practice? Allwinner cross-compile has nondeterminism from kernel headers, build path, locale. Open until v0.2 close.
2. **Multiple signatures** — v1.0 has single Ed25519. v2.0 might add cosign-style transparency log or multi-sig (e.g., 2-of-3 developer keys for high-security apps like bsdos-firefox).
3. **Differential updates** — currently full payload.tar replaced. v2.0 could support bsdiff-style binary diffs.
4. **Hardware attestation** — PinePhone has a secure element. Should `bsdos-pkgd install` require TPM/SE attestation? Defer to v0.3.

---

## 10. Cross-references

- `PLAN-app-store.md` — overall app store architecture (partial, needs update to reference this spec)
- `bsdos-pkgd/src/main.rs` — current skeleton
- `jpk-manager/src/manager.rs` — current skeleton
- `PLAN-bpi-f3-bringup.md` — **⛔ deferred per user 2026-06-15** (RISC-V SpacemiT K1 shelved to "best-by"); Allwinner (H616/H618/A523) is the v0.2/v0.3 target
- `PLAN-mali-uio.md` — companion plan; v0.2/v0.3 use **Mesa Lima** (open-source reverse-engineered driver) instead of Mali UIO proprietary blob
- `PLAN-cross-compilation.md` — Allwinner aarch64 cross-build (replaces BPI-F3/RISC-V)

---

**Status:** Draft v1. Architect deliverable. Next: spec → implementation plan (system) → v1.0 `bsdos-pkgd` (runner + system) → qa acceptance.
