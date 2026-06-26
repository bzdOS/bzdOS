# Changelog

All notable changes to `wlstream` are documented here.
Dates are ISO 8601. Format: [Keep a Changelog](https://keepachangelog.com/en/1.1.0/).

## [1.0.0] — 2026-06-13

### Added

- **Wire format spec** (`spec/WAYLAND_STREAM_PROTOCOL.md`): 7 event types
  (SURFACE_CREATE/DESTROY, POOL_DATA, SURFACE_COMMIT, CURSOR_MOVE,
  SESSION_RESET, ERROR), little-endian binary, LZ4 compression, damage rects.
- **JSON Schema** (`spec/wlstream.schema.json`): machine-readable event
  definitions for code generation.
- **Rust crate** (`src/`):
  - `parser` — zero-copy event decoder (`parse_events`, `is_v1_protocol`)
  - `sender` — event encoder (`Encoder` builder)
  - `compositor` — state machine producing RGBA frames from events
  - `protocol` — damage rect primitives (`Rect`, `clamp_damage`, `merge_damage`)
  - `lz4` — thin wrapper over `lz4_flex`
- **40+ unit tests**: encode/decode round-trips for all event types,
  compositor lifecycle, damage clamping, LZ4 compress/decompress.
- **CI** (`.github/workflows/ci.yml`): cargo test + clippy + fmt.
- **Design doc** (`docs/DESIGN.md`): rationale, alternatives rejected
  (VNC, SPICE, Xpra, H.264), performance characteristics, threat model.
- **CONTRIBUTING.md**.

### Origin

Extracted from [bsdOS](https://github.com/bzdOS/wlstream) (privacy-first
FreeBSD mobile OS). The protocol has been in production since June 2026.

[1.0.0]: https://github.com/bzdOS/wlstream/releases/tag/v1.0.0
