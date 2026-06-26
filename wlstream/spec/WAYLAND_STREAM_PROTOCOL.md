# Wayland Stream Protocol v1

Replaces pixel frame streaming. Transmits Wayland event semantics +
buffer contents (LZ4-compressed). The client compositor renders locally.

## Transport

Transport-agnostic — the same wire format works over Unix sockets, TCP,
Zenoh, or any byte stream. In production (bsdOS), events flow over
Unix socket → Zenoh pub/sub.

## Wire Format

Each payload is one or more events:
```
[total_size: u32 LE]  ← size of all events in bytes
[events...]           ← one or more events back-to-back
```

Each event:
```
[event_type: u8]
[payload: N bytes]    ← depends on event_type
```

All multi-byte integers are **little-endian**.

## Event Types

### 0x01 SURFACE_CREATE
```
[surface_id: u32 LE]
```
App created a `wl_surface`. Client allocates a rendering slot.

### 0x02 SURFACE_DESTROY
```
[surface_id: u32 LE]
```

### 0x03 POOL_DATA

Contents of a `wl_shm` pool (full or updated).
```
[pool_id: u32 LE]
[width:   u16 LE]
[height:  u16 LE]
[stride:  u32 LE]   ← bytes per row
[format:  u32 LE]   ← wl_shm.format (0=ARGB8888, 1=XRGB8888)
[raw_len: u32 LE]   ← size before compression
[lz4_len: u32 LE]   ← size after LZ4
[lz4_data: lz4_len bytes]
```
Sent once on `create_pool`, then only when content changes (hash dedup).

If `lz4_len == raw_len`, the data is uncompressed (backward compat).

### 0x04 SURFACE_COMMIT
```
[surface_id: u32 LE]
[pool_id:    u32 LE]   ← attached pool
[offset:     u32 LE]   ← offset within pool
[buf_width:  u16 LE]
[buf_height: u16 LE]
[buf_stride: u32 LE]
[format:     u32 LE]
[damage_x:   u16 LE]   ← dirty rect (0,0,0,0 = full surface)
[damage_y:   u16 LE]
[damage_w:   u16 LE]
[damage_h:   u16 LE]
```
Client composites the surface from `pool[offset..offset+stride*height]`.

**Damage rect convention** (matches Wayland):
- `(0,0,0,0)` means full surface
- Non-zero means the dirty region that changed since last commit
- Client can use this for partial texture uploads

### 0x05 CURSOR_MOVE
```
[x: i32 LE]
[y: i32 LE]
```

### 0xFE SESSION_RESET

Compositor restarted or app exited. Client **must** clear all caches.
```
[reason: u8]
  0 = compositor_restart
  1 = app_exit
  2 = error
[msg_len: u8]
[msg: msg_len UTF-8 bytes]
```

### 0xFF ERROR

Non-fatal error — client logs and continues.
```
[code: u16 LE]
  0x0001 = pool_not_found
  0x0002 = surface_not_found
  0x0003 = buffer_too_large (>8MB)
  0x0004 = mmap_failed
  0x00FF = generic
[msg_len: u8]
[msg: msg_len UTF-8 bytes]
```

## Error Handling

**Client:**
- Unknown `event_type` → log and skip (forward compatibility)
- `0xFF ERROR` → log, continue
- `0xFE SESSION_RESET` → clear all pool/surface caches, wait for new stream
- Connection lost → reconnect, expect `SESSION_RESET`

**Server:**
- Compositor crash → send `0xFE reason=0` before exit
- mmap failure → send `0xFF code=0x0004`, continue
- `pool_id` not found on commit → send `0xFF code=0x0001`

## Typical Session

```
1. SURFACE_CREATE (surface_id=3)
2. POOL_DATA (pool_id=54, 1280x694 XRGB8888, lz4_compressed)
3. SURFACE_COMMIT (surface_id=3, pool_id=54, damage=full)
   → Client renders surface 3 from pool 54

Optimizations:
- POOL_DATA sent only when hash changes (FNV-1a dedup)
- SURFACE_COMMIT with damage_rect → client updates only dirty region
```

## LZ4 Compression

| Content type | Compression ratio |
|---|---|
| Terminal (repetitive) | 10–50× |
| UI elements | 3–10× |
| Video/photos | 1–2× (minimal gain) |

Implementation:
- Zig (sender): `liblz4` via `@cImport`
- Rust (receiver): [`lz4_flex`](https://crates.io/crates/lz4_flex) (no_std compatible)

## Pixel Format

| `format` value | Wayland enum | Memory layout | Alpha |
|---|---|---|---|
| 0 | ARGB8888 | `[B, G, R, A]` | from buffer |
| 1 | XRGB8888 | `[B, G, R, X]` | forced to `0xFF` |

Both formats are stored in the pool as little-endian 32-bit words.
In memory, this maps directly to BGRA8 (common GPU texture format).

## Related Documents

- [Design rationale](../docs/DESIGN.md)
- [Roadmap](../docs/ROADMAP.md)
- [Rust crate](../src/) — parser, sender, compositor, LZ4
