//! Event encoder — convert typed events into wire bytes.

use crate::parser::{
    EV_CURSOR_MOVE, EV_POOL_DATA, EV_SURFACE_COMMIT, EV_SURFACE_CREATE, EV_SURFACE_DESTROY,
};

/// Builder for wire-format payloads.
///
/// ```
/// use wlstream::sender::Encoder;
///
/// let mut enc = Encoder::new();
/// enc.surface_create(42);
/// enc.cursor_move(100, 200);
/// let bytes = enc.finish();
/// ```
pub struct Encoder {
    events: Vec<u8>,
}

impl Encoder {
    pub fn new() -> Self {
        Self { events: Vec::new() }
    }

    pub fn surface_create(&mut self, surface_id: u32) {
        self.events.push(EV_SURFACE_CREATE);
        self.events.extend_from_slice(&surface_id.to_le_bytes());
    }

    pub fn surface_destroy(&mut self, surface_id: u32) {
        self.events.push(EV_SURFACE_DESTROY);
        self.events.extend_from_slice(&surface_id.to_le_bytes());
    }

    #[allow(clippy::too_many_arguments)]
    pub fn pool_data(
        &mut self,
        pool_id: u32,
        width: u16,
        height: u16,
        stride: u32,
        format: u32,
        raw_len: u32,
        lz4_data: &[u8],
    ) {
        self.events.push(EV_POOL_DATA);
        self.events.extend_from_slice(&pool_id.to_le_bytes());
        self.events.extend_from_slice(&width.to_le_bytes());
        self.events.extend_from_slice(&height.to_le_bytes());
        self.events.extend_from_slice(&stride.to_le_bytes());
        self.events.extend_from_slice(&format.to_le_bytes());
        self.events.extend_from_slice(&raw_len.to_le_bytes());
        self.events
            .extend_from_slice(&(lz4_data.len() as u32).to_le_bytes());
        self.events.extend_from_slice(lz4_data);
    }

    #[allow(clippy::too_many_arguments)]
    pub fn surface_commit(
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
        self.events.push(EV_SURFACE_COMMIT);
        self.events.extend_from_slice(&surface_id.to_le_bytes());
        self.events.extend_from_slice(&pool_id.to_le_bytes());
        self.events.extend_from_slice(&offset.to_le_bytes());
        self.events.extend_from_slice(&buf_width.to_le_bytes());
        self.events.extend_from_slice(&buf_height.to_le_bytes());
        self.events.extend_from_slice(&buf_stride.to_le_bytes());
        self.events.extend_from_slice(&format.to_le_bytes());
        self.events.extend_from_slice(&damage_x.to_le_bytes());
        self.events.extend_from_slice(&damage_y.to_le_bytes());
        self.events.extend_from_slice(&damage_w.to_le_bytes());
        self.events.extend_from_slice(&damage_h.to_le_bytes());
    }

    pub fn cursor_move(&mut self, x: i32, y: i32) {
        self.events.push(EV_CURSOR_MOVE);
        self.events.extend_from_slice(&x.to_le_bytes());
        self.events.extend_from_slice(&y.to_le_bytes());
    }

    /// Finalize into a wire payload: `[total_size: u32 LE][events...]`.
    pub fn finish(self) -> Vec<u8> {
        let mut out = Vec::with_capacity(4 + self.events.len());
        out.extend_from_slice(&(self.events.len() as u32).to_le_bytes());
        out.extend_from_slice(&self.events);
        out
    }
}

impl Default for Encoder {
    fn default() -> Self {
        Self::new()
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::parser::{parse_events, StreamEvent};

    #[test]
    fn encode_decode_surface_create() {
        let mut enc = Encoder::new();
        enc.surface_create(42);
        let bytes = enc.finish();

        let events = parse_events(&bytes);
        assert_eq!(events.len(), 1);
        match &events[0] {
            Ok(StreamEvent::SurfaceCreate { surface_id }) => assert_eq!(*surface_id, 42),
            other => panic!("expected SurfaceCreate, got {:?}", other),
        }
    }

    #[test]
    fn encode_decode_pool_data() {
        let data = [0xAA, 0xBB, 0xCC, 0xDD];
        let mut enc = Encoder::new();
        enc.pool_data(7, 8, 2, 32, 0, 64, &data);
        let bytes = enc.finish();

        let events = parse_events(&bytes);
        assert_eq!(events.len(), 1);
        match &events[0] {
            Ok(StreamEvent::PoolData {
                pool_id,
                width,
                height,
                raw_len,
                lz4_data,
                ..
            }) => {
                assert_eq!(*pool_id, 7);
                assert_eq!(*width, 8);
                assert_eq!(*height, 2);
                assert_eq!(*raw_len, 64);
                assert_eq!(*lz4_data, data);
            }
            other => panic!("expected PoolData, got {:?}", other),
        }
    }

    #[test]
    fn encode_decode_surface_commit() {
        let mut enc = Encoder::new();
        enc.surface_commit(1, 2, 0, 10, 20, 40, 0, 0, 0, 10, 20);
        let bytes = enc.finish();

        let events = parse_events(&bytes);
        assert_eq!(events.len(), 1);
        match &events[0] {
            Ok(StreamEvent::SurfaceCommit {
                surface_id,
                pool_id,
                buf_width,
                damage_w,
                ..
            }) => {
                assert_eq!(*surface_id, 1);
                assert_eq!(*pool_id, 2);
                assert_eq!(*buf_width, 10);
                assert_eq!(*damage_w, 10);
            }
            other => panic!("expected SurfaceCommit, got {:?}", other),
        }
    }

    #[test]
    fn encode_decode_cursor_move() {
        let mut enc = Encoder::new();
        enc.cursor_move(-100, 200);
        let bytes = enc.finish();

        let events = parse_events(&bytes);
        assert_eq!(events.len(), 1);
        match &events[0] {
            Ok(StreamEvent::CursorMove { x, y }) => {
                assert_eq!(*x, -100);
                assert_eq!(*y, 200);
            }
            other => panic!("expected CursorMove, got {:?}", other),
        }
    }

    #[test]
    fn encode_multiple_events() {
        let mut enc = Encoder::new();
        enc.surface_create(1);
        enc.surface_create(2);
        enc.surface_destroy(1);
        let bytes = enc.finish();

        let events = parse_events(&bytes);
        assert_eq!(events.len(), 3);
        assert!(events.iter().all(|e| e.is_ok()));
    }

    #[test]
    fn encode_decode_round_trip_all_types() {
        let mut enc = Encoder::new();
        enc.surface_create(1);
        enc.pool_data(1, 4, 1, 16, 0, 16, &[0u8; 16]);
        enc.surface_commit(1, 1, 0, 4, 1, 16, 0, 0, 0, 4, 1);
        enc.cursor_move(10, 20);
        enc.surface_destroy(1);
        let bytes = enc.finish();

        let events = parse_events(&bytes);
        assert_eq!(events.len(), 5);
        assert!(events.iter().all(|e| e.is_ok()));
    }
}
