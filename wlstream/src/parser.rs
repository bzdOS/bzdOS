//! Wire-format parser — decode raw bytes into typed events.

/// Event type constants.
pub const EV_SURFACE_CREATE: u8 = 0x01;
pub const EV_SURFACE_DESTROY: u8 = 0x02;
pub const EV_POOL_DATA: u8 = 0x03;
pub const EV_SURFACE_COMMIT: u8 = 0x04;
pub const EV_CURSOR_MOVE: u8 = 0x05;
pub const EV_SESSION_RESET: u8 = 0xFE;
pub const EV_ERROR: u8 = 0xFF;

/// A parsed stream event.
///
/// Lifetime `'a` ties `lz4_data` to the input buffer (zero-copy).
#[derive(Debug)]
pub enum StreamEvent<'a> {
    SurfaceCreate {
        surface_id: u32,
    },
    SurfaceDestroy {
        surface_id: u32,
    },
    PoolData {
        pool_id: u32,
        width: u16,
        height: u16,
        stride: u32,
        format: u32,
        raw_len: u32,
        lz4_data: &'a [u8],
    },
    SurfaceCommit {
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
    },
    CursorMove {
        x: i32,
        y: i32,
    },
}

/// Parse all events from a wire payload.
///
/// Format: `[total_size: u32 LE][events...]`
///
/// Each event: `[event_type: u8][payload...]`
///
/// Returns parsed events and stops on the first unknown event type or parse error.
pub fn parse_events(data: &[u8]) -> Vec<Result<StreamEvent<'_>, String>> {
    let mut results = Vec::new();

    if data.len() < 4 {
        return results;
    }

    let total_size = u32::from_le_bytes([data[0], data[1], data[2], data[3]]) as usize;
    let end = (4 + total_size).min(data.len());
    let mut pos = 4;

    while pos < end {
        if pos >= data.len() {
            break;
        }
        let event_type = data[pos];
        pos += 1;

        let result = match event_type {
            EV_SURFACE_CREATE => parse_surface_create(&data[pos..end]),
            EV_SURFACE_DESTROY => parse_surface_destroy(&data[pos..end]),
            EV_POOL_DATA => parse_pool_data(&data[pos..end]),
            EV_SURFACE_COMMIT => parse_surface_commit(&data[pos..end]),
            EV_CURSOR_MOVE => parse_cursor_move(&data[pos..end]),
            _ => {
                results.push(Err(format!("Unknown event type 0x{:02x}", event_type)));
                break;
            }
        };

        match result {
            Ok((event, consumed)) => {
                pos += consumed;
                results.push(Ok(event));
            }
            Err(e) => {
                results.push(Err(e));
                break;
            }
        }
    }

    results
}

/// Heuristic check: does this data look like v1 protocol?
pub fn is_v1_protocol(data: &[u8]) -> bool {
    if data.len() < 5 {
        return false;
    }
    let total_size = u32::from_le_bytes([data[0], data[1], data[2], data[3]]) as usize;
    let first_event = data[4];
    total_size > 0 && total_size <= data.len() - 4 && (0x01..=0x05).contains(&first_event)
}

fn parse_surface_create(data: &[u8]) -> Result<(StreamEvent<'_>, usize), String> {
    if data.len() < 4 {
        return Err("SURFACE_CREATE: need 4 bytes".into());
    }
    let surface_id = u32::from_le_bytes([data[0], data[1], data[2], data[3]]);
    Ok((StreamEvent::SurfaceCreate { surface_id }, 4))
}

fn parse_surface_destroy(data: &[u8]) -> Result<(StreamEvent<'_>, usize), String> {
    if data.len() < 4 {
        return Err("SURFACE_DESTROY: need 4 bytes".into());
    }
    let surface_id = u32::from_le_bytes([data[0], data[1], data[2], data[3]]);
    Ok((StreamEvent::SurfaceDestroy { surface_id }, 4))
}

fn parse_pool_data(data: &[u8]) -> Result<(StreamEvent<'_>, usize), String> {
    if data.len() < 24 {
        return Err(format!(
            "POOL_DATA: need 24 bytes header, got {}",
            data.len()
        ));
    }
    let pool_id = u32::from_le_bytes([data[0], data[1], data[2], data[3]]);
    let width = u16::from_le_bytes([data[4], data[5]]);
    let height = u16::from_le_bytes([data[6], data[7]]);
    let stride = u32::from_le_bytes([data[8], data[9], data[10], data[11]]);
    let format = u32::from_le_bytes([data[12], data[13], data[14], data[15]]);
    let raw_len = u32::from_le_bytes([data[16], data[17], data[18], data[19]]);
    let lz4_len = u32::from_le_bytes([data[20], data[21], data[22], data[23]]) as usize;

    if data.len() < 24 + lz4_len {
        return Err(format!(
            "POOL_DATA: need {} bytes lz4 data, got {}",
            lz4_len,
            data.len() - 24
        ));
    }

    let lz4_data = &data[24..24 + lz4_len];
    Ok((
        StreamEvent::PoolData {
            pool_id,
            width,
            height,
            stride,
            format,
            raw_len,
            lz4_data,
        },
        24 + lz4_len,
    ))
}

fn parse_surface_commit(data: &[u8]) -> Result<(StreamEvent<'_>, usize), String> {
    if data.len() < 32 {
        return Err(format!("SURFACE_COMMIT: need 32 bytes, got {}", data.len()));
    }
    let surface_id = u32::from_le_bytes([data[0], data[1], data[2], data[3]]);
    let pool_id = u32::from_le_bytes([data[4], data[5], data[6], data[7]]);
    let offset = u32::from_le_bytes([data[8], data[9], data[10], data[11]]);
    let buf_width = u16::from_le_bytes([data[12], data[13]]);
    let buf_height = u16::from_le_bytes([data[14], data[15]]);
    let buf_stride = u32::from_le_bytes([data[16], data[17], data[18], data[19]]);
    let format = u32::from_le_bytes([data[20], data[21], data[22], data[23]]);
    let damage_x = u16::from_le_bytes([data[24], data[25]]);
    let damage_y = u16::from_le_bytes([data[26], data[27]]);
    let damage_w = u16::from_le_bytes([data[28], data[29]]);
    let damage_h = u16::from_le_bytes([data[30], data[31]]);

    Ok((
        StreamEvent::SurfaceCommit {
            surface_id,
            pool_id,
            offset,
            buf_width,
            buf_height,
            buf_stride,
            format,
            damage_x,
            damage_y,
            damage_w,
            damage_h,
        },
        32,
    ))
}

fn parse_cursor_move(data: &[u8]) -> Result<(StreamEvent<'_>, usize), String> {
    if data.len() < 8 {
        return Err("CURSOR_MOVE: need 8 bytes".into());
    }
    let x = i32::from_le_bytes([data[0], data[1], data[2], data[3]]);
    let y = i32::from_le_bytes([data[4], data[5], data[6], data[7]]);
    Ok((StreamEvent::CursorMove { x, y }, 8))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn is_v1_protocol_rejects_short_buffers() {
        assert!(!is_v1_protocol(&[]));
        assert!(!is_v1_protocol(&[0, 0, 0, 0]));
    }

    #[test]
    fn is_v1_protocol_accepts_well_formed_envelope() {
        let mut buf = vec![0u8; 4 + 33];
        buf[0..4].copy_from_slice(&33u32.to_le_bytes());
        buf[4] = EV_SURFACE_COMMIT;
        assert!(is_v1_protocol(&buf));
    }

    #[test]
    fn is_v1_protocol_rejects_oversized_total_size() {
        let mut buf = vec![0u8; 5];
        buf[0..4].copy_from_slice(&1000u32.to_le_bytes());
        buf[4] = EV_POOL_DATA;
        assert!(!is_v1_protocol(&buf));
    }

    #[test]
    fn is_v1_protocol_rejects_unknown_event_type() {
        let mut buf = vec![0u8; 5];
        buf[0..4].copy_from_slice(&1u32.to_le_bytes());
        buf[4] = 0xAB;
        assert!(!is_v1_protocol(&buf));
    }

    #[test]
    fn parse_events_surface_create_and_destroy() {
        let mut buf = vec![0u8; 4 + 1 + 4 + 1 + 4];
        let total = (buf.len() - 4) as u32;
        buf[0..4].copy_from_slice(&total.to_le_bytes());
        buf[4] = EV_SURFACE_CREATE;
        buf[5..9].copy_from_slice(&42u32.to_le_bytes());
        buf[9] = EV_SURFACE_DESTROY;
        buf[10..14].copy_from_slice(&99u32.to_le_bytes());

        let events = parse_events(&buf);
        assert_eq!(events.len(), 2);
        match &events[0] {
            Ok(StreamEvent::SurfaceCreate { surface_id }) => assert_eq!(*surface_id, 42),
            other => panic!("expected SurfaceCreate, got {:?}", other),
        }
        match &events[1] {
            Ok(StreamEvent::SurfaceDestroy { surface_id }) => assert_eq!(*surface_id, 99),
            other => panic!("expected SurfaceDestroy, got {:?}", other),
        }
    }

    #[test]
    fn parse_events_pool_data_round_trip() {
        let lz4_data = [0xDE, 0xAD, 0xBE, 0xEF, 0x42];
        let mut buf = vec![0u8; 4 + 1 + 4 + 2 + 2 + 4 + 4 + 4 + 4 + lz4_data.len()];
        let total = (buf.len() - 4) as u32;
        buf[0..4].copy_from_slice(&total.to_le_bytes());
        buf[4] = EV_POOL_DATA;
        buf[5..9].copy_from_slice(&7u32.to_le_bytes());
        buf[9..11].copy_from_slice(&8u16.to_le_bytes());
        buf[11..13].copy_from_slice(&2u16.to_le_bytes());
        buf[13..17].copy_from_slice(&32u32.to_le_bytes());
        buf[17..21].copy_from_slice(&0u32.to_le_bytes());
        buf[21..25].copy_from_slice(&64u32.to_le_bytes());
        buf[25..29].copy_from_slice(&(lz4_data.len() as u32).to_le_bytes());
        buf[29..].copy_from_slice(&lz4_data);

        let events = parse_events(&buf);
        assert_eq!(events.len(), 1);
        match &events[0] {
            Ok(StreamEvent::PoolData {
                pool_id,
                width,
                height,
                stride,
                format,
                raw_len,
                lz4_data: data,
            }) => {
                assert_eq!(*pool_id, 7);
                assert_eq!(*width, 8);
                assert_eq!(*height, 2);
                assert_eq!(*stride, 32);
                assert_eq!(*format, 0);
                assert_eq!(*raw_len, 64);
                assert_eq!(*data, lz4_data);
            }
            other => panic!("expected PoolData, got {:?}", other),
        }
    }

    #[test]
    fn parse_events_pool_data_truncated_returns_error() {
        let mut buf = vec![0u8; 4 + 1 + 4 + 2 + 2 + 4 + 4 + 4 + 4 + 3];
        let total = (buf.len() - 4) as u32;
        buf[0..4].copy_from_slice(&total.to_le_bytes());
        buf[4] = EV_POOL_DATA;
        buf[25..29].copy_from_slice(&10u32.to_le_bytes());

        let events = parse_events(&buf);
        assert_eq!(events.len(), 1);
        assert!(events[0].is_err());
    }

    #[test]
    fn parse_events_surface_commit_round_trip() {
        let mut buf = vec![0u8; 4 + 33];
        buf[0..4].copy_from_slice(&33u32.to_le_bytes());
        buf[4] = EV_SURFACE_COMMIT;
        buf[5..9].copy_from_slice(&1u32.to_le_bytes());
        buf[9..13].copy_from_slice(&2u32.to_le_bytes());
        buf[13..17].copy_from_slice(&0u32.to_le_bytes());
        buf[17..19].copy_from_slice(&10u16.to_le_bytes());
        buf[19..21].copy_from_slice(&20u16.to_le_bytes());
        buf[21..25].copy_from_slice(&40u32.to_le_bytes());
        buf[25..29].copy_from_slice(&0u32.to_le_bytes());
        buf[29..31].copy_from_slice(&0u16.to_le_bytes());
        buf[31..33].copy_from_slice(&0u16.to_le_bytes());
        buf[33..35].copy_from_slice(&10u16.to_le_bytes());
        buf[35..37].copy_from_slice(&20u16.to_le_bytes());

        let events = parse_events(&buf);
        assert_eq!(events.len(), 1);
        match &events[0] {
            Ok(StreamEvent::SurfaceCommit {
                surface_id,
                pool_id,
                buf_width,
                buf_height,
                buf_stride,
                damage_w,
                damage_h,
                ..
            }) => {
                assert_eq!(*surface_id, 1);
                assert_eq!(*pool_id, 2);
                assert_eq!(*buf_width, 10);
                assert_eq!(*buf_height, 20);
                assert_eq!(*buf_stride, 40);
                assert_eq!(*damage_w, 10);
                assert_eq!(*damage_h, 20);
            }
            other => panic!("expected SurfaceCommit, got {:?}", other),
        }
    }

    #[test]
    fn parse_events_cursor_move() {
        let mut buf = vec![0u8; 4 + 1 + 4 + 4];
        buf[0..4].copy_from_slice(&9u32.to_le_bytes());
        buf[4] = EV_CURSOR_MOVE;
        buf[5..9].copy_from_slice(&1234i32.to_le_bytes());
        buf[9..13].copy_from_slice(&(-567i32).to_le_bytes());

        let events = parse_events(&buf);
        assert_eq!(events.len(), 1);
        match &events[0] {
            Ok(StreamEvent::CursorMove { x, y }) => {
                assert_eq!(*x, 1234);
                assert_eq!(*y, -567);
            }
            other => panic!("expected CursorMove, got {:?}", other),
        }
    }

    #[test]
    fn parse_events_short_buffer_returns_empty_vec() {
        let events = parse_events(&[0, 0, 0]);
        assert!(events.is_empty());
    }

    #[test]
    fn parse_events_unknown_event_returns_error_and_stops() {
        let mut buf = vec![0u8; 10];
        buf[0..4].copy_from_slice(&5u32.to_le_bytes());
        buf[4] = 0xAB;

        let events = parse_events(&buf);
        assert_eq!(events.len(), 1);
        assert!(events[0].is_err());
    }
}
