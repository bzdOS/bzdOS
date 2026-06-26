# wlstream

> **Wire format for streaming remote Wayland sessions.**
> Ship semantic events (surface create/destroy, pool data, commits, cursor),
> not pixels. LZ4-compressed, damage-aware, transport-agnostic.

[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](LICENSE)
[![Spec: v1.0](https://img.shields.io/badge/spec-v1.0-blue.svg)](spec/WAYLAND_STREAM_PROTOCOL.md)
[![Rust](https://img.shields.io/badge/Rust-1.70%2B-orange.svg)](https://www.rust-lang.org)

---

## Why?

Pixel streaming (VNC, SPICE, MJPEG) sends pre-rendered frames. For
text-heavy UIs (terminals, editors, file managers), this wastes 50–100×
the bandwidth. wlstream ships the same events the compositor uses
internally — the client re-renders locally.

| Scenario | Pixel streaming | wlstream |
|---|---|---|
| Idle terminal | ~250 MB/s | **0** (no event sent) |
| Cursor blink | ~250 MB/s | **~130 B** |
| Text typed | ~250 MB/s | **~50 KB** |
| Full redraw | ~250 MB/s | **~4 MB** (LZ4-compressed) |
| Video (1080p 60fps) | ~250 MB/s | ~250 MB/s (no win) |

## Comparison with alternatives

| Feature | VNC | SPICE | Xpra | **wlstream** |
|---|---|---|---|---|
| Display server | Any | QEMU | X11 | **Wayland** |
| Approach | Pixel copy | Pixel copy | X11 forward | **Event streaming** |
| Bandwidth (terminal) | High | High | Medium | **Very low** |
| Client re-rendering | No | No | Limited | **Full** |
| Damage tracking | Region-based | Region-based | Region-based | **Rect in COMMIT** |
| Compression | Tight/ZRLE | Quic/GLZ | LZ4/zstd | **LZ4** |
| Scale at render time | No | No | Partial | **Yes** |
| Text accessibility | Lost | Lost | Preserved | **Preserved** |
| Transport | RDP | SPICE | SSH/TCP | **Any** (socket/TCP/Zenoh) |

## What's in this repo?

- **[`spec/WAYLAND_STREAM_PROTOCOL.md`](spec/WAYLAND_STREAM_PROTOCOL.md)** — wire format specification (7 event types)
- **[`spec/wlstream.schema.json`](spec/wlstream.schema.json)** — machine-readable JSON Schema
- **[`src/`](src/)** — Rust crate (`wlstream`):
  - `parser` — decode wire bytes into typed events
  - `sender` — encode events into wire bytes
  - `compositor` — state machine: events → RGBA frame
  - `protocol` — damage rect primitives (`Rect`, `clamp_damage`, `merge_damage`)
  - `lz4` — thin wrapper over `lz4_flex`
- **[`docs/DESIGN.md`](docs/DESIGN.md)** — design rationale, alternatives rejected, threat model
- **[`docs/ROADMAP.md`](docs/ROADMAP.md)** — v1.1+ plans (Zig module, reference sender/receiver, v2 protocol)

## Quick start

### As a Rust dependency

```toml
[dependencies]
wlstream = "1.0"
```

```rust
use wlstream::{Encoder, Compositor, parse_events, StreamEvent};

// Sender side: encode events
let mut enc = Encoder::new();
enc.surface_create(1);
enc.pool_data(1, 800, 600, 3200, 0, 1920000, &lz4_compressed_bytes);
enc.surface_commit(1, 1, 0, 800, 600, 3200, 0, 0, 0, 800, 600);
let wire_bytes = enc.finish();

// Receiver side: decode + composite
let mut comp = Compositor::new();
for event in parse_events(&wire_bytes) {
    match event.unwrap() {
        StreamEvent::PoolData { pool_id, width, height, stride, format, raw_len, lz4_data } => {
            comp.handle_pool_data(pool_id, width, height, stride, format, raw_len, lz4_data);
        }
        StreamEvent::SurfaceCommit { surface_id, pool_id, offset, buf_width, buf_height,
            buf_stride, format, damage_x, damage_y, damage_w, damage_h } => {
            comp.handle_surface_commit(surface_id, pool_id, offset, buf_width, buf_height,
                buf_stride, format, damage_x, damage_y, damage_w, damage_h);
        }
        _ => {}
    }
}

if comp.dirty {
    println!("frame: {}x{} ({} bytes, damage: {:?})",
        comp.frame.width, comp.frame.height,
        comp.frame.data.len(), comp.last_damage);
}
```

### Running tests

```sh
git clone https://github.com/bzdOS/wlstream
cd wlstream
cargo test
```

## Event types

| ID | Event | Purpose |
|---|---|---|
| `0x01` | `SURFACE_CREATE` | New `wl_surface` |
| `0x02` | `SURFACE_DESTROY` | Surface removed |
| `0x03` | `POOL_DATA` | SHM pool contents (LZ4-compressed) |
| `0x04` | `SURFACE_COMMIT` | Attach pool region + damage rect |
| `0x05` | `CURSOR_MOVE` | Cursor position update |
| `0xFE` | `SESSION_RESET` | Clear all caches (compositor restart) |
| `0xFF` | `ERROR` | Non-fatal error with code + message |

## License

MIT. See [`LICENSE`](LICENSE).

## Origin

Developed as part of [bsdOS](https://github.com/bzdOS/wlstream) — a
privacy-first mobile OS on FreeBSD. Extracted as a standalone protocol
+ crate in June 2026.
