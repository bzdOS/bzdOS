# wlstream ROADMAP

## Current state (v1.0.0)

- ✅ Wire format spec (7 event types)
- ✅ JSON Schema (machine-readable)
- ✅ Rust crate: parser, sender, compositor, LZ4, damage rects
- ✅ 40+ unit tests (encode/decode round-trips, compositor lifecycle)
- ✅ CI (cargo test + clippy + fmt)
- ✅ Design doc (rationale, alternatives, threat model)

## Roadmap

### v1.1.0 — Hardening

- Property-based tests (`proptest`: random bytes → no panic)
- Fuzz targets (`cargo-fuzz`: parser + decompressor)
- `no_std` support for parser + sender (embedded targets)
- Benchmark suite (encode/decode/composite throughput)
- `examples/sender.rs` + `examples/receiver.rs` (minimal binaries)

### v1.2.0 — Zig module

Transport-agnostic encode functions (no socket deps):

```zig
pub fn encodePoolData(allocator: Allocator, ...) ![]u8 { ... }
pub fn encodeSurfaceCommit(allocator: Allocator, ...) ![]u8 { ... }
```

- `zig/src/stream.zig` — event encoders
- `zig/tests/stream.zig` — round-trip tests
- `build.zig` — module + test target

### v1.3.0 — Reference sender

Minimal Wayland client that captures `wl_surface`/`wl_shm` events and
emits wlstream wire bytes. Standalone binary (`wlstream-sender`).

### v1.4.0 — Reference receiver

CLI viewer that reads wlstream from a socket/stdin and renders to
terminal ASCII or PNG. Proves the crate works independent of any
specific display backend.

### v2.0.0 — Protocol v2

- Multi-region damage (array of rects)
- Buffer scale (`u16`)
- Transform matrix (`wl_output.transform`)
- Optional input events
- Backward-compat negotiation (v1 receivers ignore v2 events)

## Decision log

| Date | Decision | Rationale |
|---|---|---|
| 2026-06-13 | Rust crate included in v1.0.0 | Code proves the spec is implementable |
| 2026-06-13 | `lz4_flex` over raw `liblz4` | No C dependency, no_std compatible |
| 2026-06-13 | Single crate, not workspace | <5k LOC, simpler for consumers |
| 2026-06-13 | Damage rect in `protocol.rs`, not `parser.rs` | Usable without the full parser |
