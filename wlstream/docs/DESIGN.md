# wlstream DESIGN

> **Why wlstream exists, what design decisions shaped it, and what alternatives were rejected.**

## 1. The problem

A remote-display system has to ship a graphical desktop from a host
(compositor + apps) to a client (renderer). The naive approach is to
ship pixels. The approach is to ship semantic events.

### 1.1 Why not pixel streaming?

| Property | Pixel streaming (MJPEG, H.264) | Event streaming (wlstream) |
|----------|-------------------------------|------------------------------|
| Bandwidth (1080p, 60fps, terminal) | 250 MB/s | 5-50 MB/s |
| Bandwidth (1080p, 60fps, video) | 250 MB/s | 250 MB/s (no win) |
| Re-rendering flexibility | None — pre-rendered | Full — client runs compositor logic |
| Text accessibility | Lost | Preserved (text is just a SHM buffer) |
| Scale on client | Pre-rendered at server scale | Re-scaled at render time |
| Mobile GPU feasibility | Tight (decode + display) | Viable (render small damage rect) |
| Latency | Server render time + encode + network + decode | Network + client render |
| CPU on server | Render + encode | Render only |

For text-heavy UIs (terminals, code editors, file managers), event
streaming is a 50-100× bandwidth win. For video, it's a wash.

the origin project chose event streaming because the primary use case is
terminal/UI remote display, not video. Video is a stretch goal (Phase
0.3-0.4 in the origin project roadmap), and when video is needed, a different
mechanism (H.264 over the same Zenoh pub/sub bus) can be added
alongside.

### 1.2 Why Wayland events, not a custom protocol?

Wayland's wl_surface and wl_shm protocols already define the events
a compositor cares about: surface lifecycle, buffer attachment, damage
regions, frame callbacks. Re-encoding these is conceptually clean —
the same events the server's compositor would feed to its own
renderer, now sent to a remote renderer.

A custom protocol would need to define equivalent concepts anyway.
The cost of "non-Wayland" is zero (no Wayland clients on the wire),
and the benefit is using the well-understood semantics of wl_surface
damage regions, wl_shm pool sharing, wl_buffer scale, etc.

## 2. The wire format

### 2.1 Why length-prefixed binary, not JSON/CBOR?

| Format | Bandwidth overhead | Parse cost | Streaming-friendly |
|--------|-------------------|------------|---------------------|
| JSON | 2-3× | Low (but slow on hot path) | Token-by-token |
| CBOR | 1.1-1.3× | Medium | Length-prefixed |
| Protocol Buffers | 1.0-1.1× | Medium | Length-prefixed |
| Cap'n Proto | 1.0× (zero-copy) | Low | Frame-based |
| Length-prefixed binary (this) | 1.0× | Very low | Byte-by-byte |

For a hot-path protocol shipping 250 MB/s of pixel data, every
byte of overhead matters. JSON's 2-3× overhead is unacceptable. Cap'n
Proto would be ideal (zero-copy) but the schema generation step is
extra work for what is fundamentally a fixed schema (8 event types
with fixed payload shapes). Plain length-prefixed binary is the
right tradeoff.

### 2.2 Why LZ4, not zstd/brotli?

| Codec | Speed (compress) | Speed (decompress) | Ratio (text) | Ratio (video) |
|-------|-------------------|---------------------|--------------|---------------|
| LZ4 | 500 MB/s | 2 GB/s | 2-3× | 1.05× |
| zstd -3 | 200 MB/s | 600 MB/s | 3-4× | 1.1× |
| brotli -5 | 50 MB/s | 200 MB/s | 4-5× | 1.2× |
| gzip -6 | 30 MB/s | 200 MB/s | 3× | 1.1× |

LZ4 is 2-3× faster to decompress than zstd at similar text ratios.
For terminal content (highly repetitive), LZ4 hits 10-50×
compression easily. For video (already compressed by the codec),
compression ratio is 1.0-1.2× regardless of algorithm — so the
fastest decompressor wins.

LZ4 also has a `lz4_flex` Rust crate that works in `no_std`
contexts, and a stable Zig binding via `liblz4`. Both are
zero-config dependencies.

### 2.3 Why u16/u32 little-endian, not big-endian or varint?

Little-endian because the target platforms (x86_64, aarch64) are
little-endian natively — no byte-swap on read. u16/u32 (fixed width)
because SHM pool metadata is bounded (`u16 width` = max 65535 px per
dimension, `u32 stride` = max 4 GB per row, `u32 raw_len` = max 4 GB
per pool — these are already way more than realistic displays).

Varint would save 1-2 bytes per field on small values, but
adds code complexity (and varint encoding bugs). For ~30 fields per
event, the saving is ~30 bytes vs ~30 lines of code. Not worth it.

## 3. Event design

### 3.1 Why damage_x/y/w/h in SURFACE_COMMIT, not separate events?

Wayland itself uses a separate `wl_surface.damage` request before
`wl_surface.commit`. We could mirror this with separate events, but
the v1 protocol collapses them: SURFACE_COMMIT carries the final
damage rect.

Rationale:
- v1 is one-shot per commit; later commits don't need to know about
  earlier damage in the same frame (Wayland convention: union)
- Reduces event count by ~2-5× for typical UIs
- Lossless: client that wants finer-grained damage can subscribe to
  the upstream Wayland events directly (the tunnel exposes
  both)

### 3.2 Why POOL_DATA uses hash dedup, not always-send?

POOL_DATA is the bulk of the bandwidth. If a SHM pool is unchanged
between two commits, sending it again wastes 50-200 KB per
duplicate.

the tunnel uses a 64-bit FNV-1a hash of the pool
contents. On commit, if the hash matches the last-sent value, the
POOL_DATA is skipped. This is documented in the v1 spec
(`Отправляется один раз при create_pool, потом только при изменении`).

Limitation: FNV-1a is not cryptographic — a malicious app could
craft two pools with the same hash but different content. For
the threat model (single-user, single-device, no hostile
apps), this is fine. A future v2 could use SHA-256 (truncated to
64 bits) if cross-trust boundaries are needed.

### 3.3 Why SESSION_RESET, not per-event recovery?

A compositor crash leaves the client with stale state (cached pools,
surfaces). Recovering from this requires either:
- Re-issuing all SURFACE_CREATE + POOL_DATA events (bandwidth)
- Acknowledging a "reset" boundary (cheap)

SESSION_RESET is the cheap option. After receiving it, the client
clears its cache and waits for the next SURFACE_CREATE.

This is the same pattern that [wl_display](https://wayland.freedesktop.org/docs/html/Applies.html#Server-struct-wl_display)
uses internally — a "disconnect" event that means "forget
everything you knew, the new connection will replay state".

### 3.4 Why no input events in v1?

Input (keyboard, pointer) is bidirectional. v1 is unidirectional
(server → client). v1 ships display, not input.

Input goes through a separate path: Mac NSEvent → Zenoh
`input/{keyboard,pointer}` → relay → Unix socket →
tunnel → wl_keyboard/wl_pointer injection.

A v2 of wlstream could include input events for full symmetry
(input + output in one stream), but the pipeline separates them
because input has different latency requirements (sub-frame) and
different validation (can't trust client to send arbitrary key
events). Keeping them separate is cleaner.

## 4. Deployment topology

```
┌─ Server (Wayland compositor) ─────────────┐
│  cage / weston / sway / wlroots             │
│      │                                      │
│      ▼                                      │
│  tunnel (Zig or Rust)                      │
│   - reads Wayland socket                    │
│   - mmap SHM pools                          │
│   - LZ4-compress pixel data                 │
│   - emit v1 events                          │
│      │                                      │
│      ▼ (Unix socket)                        │
│  relay daemon                               │
│   - reads v1 events                         │
│   - publishes to Zenoh / TCP / etc.         │
│      │                                      │
└──────│──────────────────────────────────────┘
       │ (network: Zenoh / TCP / TLS)
       ▼
┌─ Client (renderer) ────────────────────────┐
│  relay daemon                               │
│   - subscribes to stream                    │
│   - re-emits to local Unix socket           │
│      │                                      │
│      ▼                                      │
│  renderer (Metal / Vulkan / ASCII / ...)   │
│   - reads v1 events                         │
│   - maintains Compositor state              │
│   - LZ4-decompresses to texture             │
│   - partial updates via damage rect         │
└─────────────────────────────────────────────┘
```

The wire format is **transport-agnostic** — the same bytes work over
Unix sockets, TCP, Zenoh, MQTT, files, etc.

## 5. Performance characteristics

### 5.1 Throughput

| Scenario | Bandwidth (single 1080p frame) |
|----------|-------------------------------|
| Idle terminal (no changes) | 0 (no event sent) |
| Cursor blink (8×16) | ~130 B (damage rect + COMMIT only) |
| Text typed in foot | ~50 KB (cursor + new chars) |
| Full screen redraw | ~4 MB (POOL_DATA + COMMIT) |
| Video (already-encoded H.264 stream) | ~1-2 MB (POOL_DATA, near-no compression) |

### 5.2 Latency

End-to-end (server → client render):
- Unix socket write: <100 µs
- Relay daemon publish: <5 ms (includes discovery + serialization)
- Network (loopback or LAN): <1 ms
- Client relay subscribe: <1 ms
- Client parse + LZ4 decompress: <5 ms
- Texture upload: <1 ms
- **Total:** ~10-15 ms (imperceptible at 60 Hz)

For WAN (cross-country): add network latency (50-100 ms each way)
= ~150-200 ms total. This is where the bandwidth savings matter
most — at WAN latency, the alternative (sending 250 MB/s of pixels)
would saturate the link.

### 5.3 CPU on Mac

Per v0.1.1 design spec (target):
- Idle terminal: <5% (was ~100% full-surface copy on v0.1.0)
- Active typing: ~10-20%
- Video: ~40-60% (LZ4 decompress + Metal upload is the bottleneck)

## 6. Security considerations

### 6.1 Threat model

the deployment is single-user, single-device. The Wayland
compositor runs the user's own apps in jails. The Mac client is
the user's own device. There is no hostile party on the wire.

This means v1 has minimal security:
- No authentication (Unix socket is filesystem-permissioned;
  Zenoh uses mTLS for cross-host)
- No encryption (relies on transport layer)
- No replay protection (state-recovery is the client's job)
- No input validation beyond length-prefix checks

A v2 with stricter threat model (multi-tenant, public relay)
would add:
- Per-event HMAC
- Sequence numbers
- Schema version negotiation
- Replay window

### 6.2 What v1 explicitly does NOT protect against

- Malicious compositor sending infinite SESSION_RESET (DoS)
- Malicious app sending 4 GB POOL_DATA (memory exhaustion)
- Malicious client requesting LZ4 decompression bomb
- Replay attacks (re-sending old POOL_DATA)

These are mitigated by transport-level (Zenoh mTLS) and OS-level
(jail resource limits) controls, not by the protocol itself.

## 7. Open design questions for v2

| Question | Current v1 | v2 candidate |
|----------|-----------|--------------|
| Multi-region damage? | Last rect only | Array of rects (or bitmask) |
| Buffer scale? | Not transmitted | Add `u16 scale` to SURFACE_COMMIT |
| Transform matrix? | Not transmitted | Add `u16 transform` (matches wl_output.transform) |
| Subsurface handling? | Implicit (parent gets SUBSCRIBE) | Explicit SUBSURFACE_COMMIT events |
| Frame callbacks? | Implicit | Explicit CALLBACK_DONE event |
| Opaque regions? | None | Add to SURFACE_COMMIT |
| Input events? | Separate path | Optional INPUT in v2 stream |

## 8. Alternatives rejected

### 8.1 MJPEG pixel streaming
- Used by older VNC
- High bandwidth, lossy
- No re-rendering flexibility
- Rejected for the reasons in §1.1

### 8.2 H.264 + RTP
- Used by Sunshine, Parsec, Steam Remote Play
- Excellent for video
- High CPU on encode/decode
- Rejected for text/UI; may be added later for video in v2+

### 8.3 Xpra (X11 forwarding)
- Mature, proven
- X11-specific
- Rejected: the protocol is Wayland-only

### 8.4 SPICE
- QEMU's remote display
- Pixel-based, lossy compression
- Rejected for the same reasons as MJPEG

### 8.5 VNC
- Bit-exact replication
- Mature, widely supported
- Rejected: Wayland has better semantic information

### 8.6 Custom binary protocol (no Wayland semantics)
- Maximum flexibility
- Maximum cost to design + maintain
- Rejected: Wayland's wl_surface / wl_shm semantics are well-known

## 9. References

- [Wayland protocol spec](https://wayland.freedesktop.org/docs/html/)
- [wl_surface damage docs](https://wayland.freedesktop.org/docs/html/apa.html#protocol-spec-wl_surface)
- [wl_shm format spec](https://wayland.freedesktop.org/docs/html/apa.html#protocol-spec-wl_shm)
- [LZ4 frame format](https://github.com/lz4/lz4/blob/dev/doc/lz4_Frame_format.md)
- [lz4_flex crate](https://crates.io/crates/lz4_flex)

---

**Last updated:** 2026-06-13
