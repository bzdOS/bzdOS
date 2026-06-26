//! Compositor state machine — composites RGBA frames from stream events.

use std::collections::HashMap;

use crate::protocol::{clamp_damage, Rect};

struct Pool {
    data: Vec<u8>,
    _width: u16,
    _height: u16,
    _stride: u32,
    _format: u32,
}

struct Surface {
    _active: bool,
    damage: Rect,
}

/// Compositor that tracks surfaces and pools, producing RGBA frames.
///
/// ```
/// use wlstream::compositor::Compositor;
/// use wlstream::sender::Encoder;
/// use wlstream::parse_events;
///
/// let mut enc = Encoder::new();
/// enc.pool_data(1, 4, 1, 16, 0, 16, &[0u8; 16]);
/// enc.surface_commit(1, 1, 0, 4, 1, 16, 0, 0, 0, 4, 1);
///
/// let mut comp = Compositor::new();
/// for event in parse_events(&enc.finish()) {
///     match event.unwrap() {
///         wlstream::StreamEvent::PoolData { pool_id, width, height, stride, format, raw_len, lz4_data } => {
///             comp.handle_pool_data(pool_id, width, height, stride, format, raw_len, lz4_data);
///         }
///         wlstream::StreamEvent::SurfaceCommit { surface_id, pool_id, offset, buf_width, buf_height,
///             buf_stride, format, damage_x, damage_y, damage_w, damage_h } => {
///             comp.handle_surface_commit(surface_id, pool_id, offset, buf_width, buf_height,
///                 buf_stride, format, damage_x, damage_y, damage_w, damage_h);
///         }
///         _ => {}
///     }
/// }
/// assert!(comp.dirty);
/// ```
pub struct Compositor {
    pools: HashMap<u32, Pool>,
    surfaces: HashMap<u32, Surface>,
    /// Last composited frame (RGBA/BGRA, row-major, stride = width * 4).
    pub frame: FrameOutput,
    /// Set to `true` when a SURFACE_COMMIT produces new pixel data.
    pub dirty: bool,
    /// Last damage rect from SURFACE_COMMIT (clamped to surface bounds).
    pub last_damage: Rect,
}

/// Composited RGBA frame output.
#[derive(Debug, Clone)]
pub struct FrameOutput {
    pub width: u32,
    pub height: u32,
    pub stride: u32,
    pub data: Vec<u8>,
}

impl Compositor {
    pub fn new() -> Self {
        Self {
            pools: HashMap::new(),
            surfaces: HashMap::new(),
            frame: FrameOutput {
                width: 0,
                height: 0,
                stride: 0,
                data: Vec::new(),
            },
            dirty: false,
            last_damage: Rect::zero(),
        }
    }

    pub fn handle_surface_create(&mut self, surface_id: u32) {
        self.surfaces.insert(
            surface_id,
            Surface {
                _active: true,
                damage: Rect::zero(),
            },
        );
    }

    pub fn handle_surface_destroy(&mut self, surface_id: u32) {
        self.surfaces.remove(&surface_id);
    }

    /// Decompress (if needed) and cache pool pixel data.
    ///
    /// If `lz4_data.len() == raw_len`, the data is treated as uncompressed.
    /// Otherwise, LZ4 decompression is applied.
    #[allow(clippy::too_many_arguments)]
    pub fn handle_pool_data(
        &mut self,
        pool_id: u32,
        width: u16,
        height: u16,
        stride: u32,
        format: u32,
        raw_len: u32,
        lz4_data: &[u8],
    ) {
        let decompressed = if lz4_data.len() == raw_len as usize {
            lz4_data.to_vec()
        } else {
            match crate::lz4::decompress(lz4_data) {
                Some(d) if d.len() >= raw_len as usize => d,
                Some(d) => {
                    let mut padded = d;
                    padded.resize(raw_len as usize, 0);
                    padded
                }
                None => return,
            }
        };

        self.pools.insert(
            pool_id,
            Pool {
                data: decompressed,
                _width: width,
                _height: height,
                _stride: stride,
                _format: format,
            },
        );
    }

    /// Composite surface frame from pool data.
    ///
    /// Extracts pixels from `pool[offset..offset+stride*height]`, normalizes stride to
    /// `width * 4`, sets alpha to `0xFF` for XRGB8888 (format 1).
    ///
    /// Silently drops if pool not found or too small.
    #[allow(clippy::too_many_arguments)]
    pub fn handle_surface_commit(
        &mut self,
        surface_id: u32,
        pool_id: u32,
        offset: u32,
        buf_width: u16,
        buf_height: u16,
        buf_stride: u32,
        format: u32,
        damage_x: u16,
        damage_y: u16,
        damage_w: u16,
        damage_h: u16,
    ) {
        let pool = match self.pools.get(&pool_id) {
            Some(p) => p,
            None => return,
        };

        let w = buf_width as u32;
        let h = buf_height as u32;
        let s = buf_stride as usize;
        let off = offset as usize;

        let needed = off + s * (h as usize);
        if pool.data.len() < needed {
            return;
        }

        let expected_stride = w as usize * 4;
        let mut pixels = vec![0u8; expected_stride * (h as usize)];

        for row in 0..(h as usize) {
            let src_start = off + row * s;
            let src_end = src_start + expected_stride.min(s);
            let dst_start = row * expected_stride;
            let copy_len = (src_end - src_start).min(expected_stride);
            if src_end <= pool.data.len() && dst_start + copy_len <= pixels.len() {
                pixels[dst_start..dst_start + copy_len]
                    .copy_from_slice(&pool.data[src_start..src_end]);
            }
        }

        // XRGB8888 (format 1): set padding byte to 0xFF for opaque alpha.
        if format == 1 {
            for chunk in pixels.chunks_exact_mut(4) {
                chunk[3] = 0xFF;
            }
        }

        let damage = Rect::new(damage_x, damage_y, damage_w, damage_h);
        let clamped = clamp_damage(damage, buf_width, buf_height)
            .unwrap_or_else(|| Rect::new(0, 0, buf_width, buf_height));

        if let Some(surface) = self.surfaces.get_mut(&surface_id) {
            surface.damage = clamped;
        }

        self.last_damage = clamped;
        self.frame.width = w;
        self.frame.height = h;
        self.frame.stride = w * 4;
        self.frame.data = pixels;
        self.dirty = true;
    }

    pub fn handle_cursor_move(&mut self, x: i32, y: i32) {
        let _ = (x, y);
    }

    pub fn pool_count(&self) -> usize {
        self.pools.len()
    }

    pub fn surface_count(&self) -> usize {
        self.surfaces.len()
    }
}

impl Default for Compositor {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn surface_create_destroy() {
        let mut c = Compositor::new();
        assert_eq!(c.surface_count(), 0);
        c.handle_surface_create(1);
        c.handle_surface_create(2);
        assert_eq!(c.surface_count(), 2);
        c.handle_surface_destroy(1);
        assert_eq!(c.surface_count(), 1);
    }

    #[test]
    fn pool_data_uncompressed_path() {
        let mut c = Compositor::new();
        let raw = vec![0u8; 16];
        c.handle_pool_data(1, 4, 1, 16, 0, 16, &raw);
        assert_eq!(c.pool_count(), 1);
    }

    #[test]
    fn surface_commit_produces_frame() {
        let mut c = Compositor::new();
        let raw = vec![0u8; 16];
        c.handle_pool_data(1, 4, 1, 16, 0, 16, &raw);
        c.handle_surface_commit(99, 1, 0, 4, 1, 16, 0, 0, 0, 4, 1);

        assert!(c.dirty);
        assert_eq!(c.frame.width, 4);
        assert_eq!(c.frame.height, 1);
        assert_eq!(c.frame.stride, 16);
        assert_eq!(c.frame.data.len(), 16);
    }

    #[test]
    fn surface_commit_missing_pool_is_noop() {
        let mut c = Compositor::new();
        c.handle_surface_commit(1, 999, 0, 4, 1, 16, 0, 0, 0, 4, 1);
        assert!(!c.dirty);
        assert_eq!(c.frame.width, 0);
        assert_eq!(c.frame.data.len(), 0);
    }

    #[test]
    fn surface_commit_format_1_sets_alpha() {
        let mut c = Compositor::new();
        let mut raw = vec![0u8; 16];
        raw[3] = 0x00;
        raw[7] = 0x00;
        raw[11] = 0x00;
        raw[15] = 0x00;
        c.handle_pool_data(1, 4, 1, 16, 1, 16, &raw);
        c.handle_surface_commit(1, 1, 0, 4, 1, 16, 1, 0, 0, 4, 1);

        assert_eq!(c.frame.data[3], 0xFF);
        assert_eq!(c.frame.data[7], 0xFF);
        assert_eq!(c.frame.data[11], 0xFF);
        assert_eq!(c.frame.data[15], 0xFF);
    }

    #[test]
    fn surface_commit_pool_too_small_does_not_panic() {
        let mut c = Compositor::new();
        let raw = vec![0u8; 4];
        c.handle_pool_data(1, 4, 1, 16, 0, 16, &raw);
        c.handle_surface_commit(1, 1, 0, 4, 1, 16, 0, 0, 0, 4, 1);
        assert_eq!(c.frame.width, 0);
    }

    #[test]
    fn cursor_move_is_noop() {
        let mut c = Compositor::new();
        c.handle_cursor_move(10, 20);
        assert!(!c.dirty);
    }

    #[test]
    fn surface_commit_stores_damage() {
        let mut c = Compositor::new();
        let raw = vec![0u8; 16];
        c.handle_pool_data(1, 4, 1, 16, 0, 16, &raw);
        c.handle_surface_commit(99, 1, 0, 4, 1, 16, 0, 1, 0, 2, 1);

        assert!(c.dirty);
        assert_eq!(c.last_damage, Rect::new(1, 0, 2, 1));
    }

    #[test]
    fn surface_commit_clamps_oversized_damage() {
        let mut c = Compositor::new();
        let raw = vec![0u8; 16];
        c.handle_pool_data(1, 4, 1, 16, 0, 16, &raw);
        c.handle_surface_commit(99, 1, 0, 4, 1, 16, 0, 2, 0, 10, 5);

        assert_eq!(c.last_damage, Rect::new(2, 0, 2, 1));
    }

    #[test]
    fn surface_commit_zero_damage_means_full_surface() {
        let mut c = Compositor::new();
        let raw = vec![0u8; 16];
        c.handle_pool_data(1, 4, 1, 16, 0, 16, &raw);
        c.handle_surface_commit(99, 1, 0, 4, 1, 16, 0, 0, 0, 0, 0);

        assert_eq!(c.last_damage, Rect::new(0, 0, 4, 1));
    }
}
