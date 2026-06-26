// START_AI_HEADER
// MODULE: bsdos-core/src/protocol.rs
// PURPOSE: Pure v1 Wayland stream protocol helpers extracted from main.rs so they
//          can be unit-tested without a Zenoh session or Unix socket.
// INTENT: The bridge tasks in main.rs (wayland_bridge / input_bridge /
//         resize_subscriber) embed non-trivial protocol parsing and reformatting
//         logic. Keeping the pure pieces here lets the test suite cover the
//         tricky byte-level contracts (POOL_DATA pool_id placement, SURFACE_COMMIT
//         pool_id shift, Zenoh→socket input reformatting, WxH@S size parsing)
//         while the async / effectful wrappers stay in main.rs. Any change to
//         the v1 wire format must update this module first; main.rs calls into
//         here, never duplicates the parsing.
// DEPENDENCIES: std only.
// PUBLIC_API:
//   parse_size_request(s) -> Option<(u32, u32, u32)>   (W, H, scale)
//   compute_logical_size(w, h, scale) -> Option<(u32, u32)>
//   payload_event_type(payload) -> Option<u8>
//   extract_pool_id_from_pool_data(payload) -> Option<u32>
//   extract_pool_id_from_surface_commit(payload) -> Option<u32>
//   should_republish_pool(elapsed, threshold_secs) -> bool
//   format_keyboard_payload(zh) -> Option<[u8; 7]>
//   format_pointer_payload(zh) -> Option<[u8; 18]>
//   is_valid_pool_payload_size(size) -> bool
//   EV_POOL_DATA, EV_SURFACE_COMMIT  (v1 event_type constants)
// START_INVARIANTS
//   - All functions in this module are pure (no IO, no allocations beyond
//     stack-only buffer construction). sideEffects: none on every contract.
//   - Returned fixed-size arrays are exactly the wire format byte counts
//     declared in WAYLAND_STREAM_PROTOCOL.md.
// END_INVARIANTS
// END_AI_HEADER

// v1 stream event_type constants — keep in sync with wayland-tunnel/src/stream.zig.
pub const EV_POOL_DATA: u8 = 0x03;
pub const EV_SURFACE_COMMIT: u8 = 0x04;

// parse_size_request:start
//   purpose: extract physical pixel width/height and scale factor from a
//            `bsdos/viewer/size` Zenoh payload.
//   input:  s — string payload (UTF-8/ASCII), expected shape `<u32>x<u32>@<u32>`
//            (e.g. "1440x720@2"). The '@' separator is required; the scale
//            defaults to 1 on parse failure (mirrors main.rs legacy behavior).
//   output: Some((w, h, s)) on success; None when 'x' or '@' is missing,
//           W or H is non-numeric or zero. Non-numeric scale → defaults to 1.
//   sideEffects: none (pure parsing).
pub fn parse_size_request(s: &str) -> Option<(u32, u32, u32)> {
    let (wh, scale_str) = s.split_once('@')?;
    let (w_str, h_str) = wh.split_once('x')?;
    let w: u32 = w_str.parse().ok()?;
    let h: u32 = h_str.parse().ok()?;
    let scale: u32 = scale_str.parse().unwrap_or(1).max(1);
    if w == 0 || h == 0 {
        return None;
    }
    Some((w, h, scale))
}
// parse_size_request:end

// compute_logical_size:start
//   purpose: map viewer physical-pixel size → compositor logical-pixel size
//            (used as the argument to wlr-randr --custom-mode).
//   input:  w, h — physical pixel size; scale — divisor (must be >= 1).
//   output: Some((lw, lh)) when the division produces non-zero values;
//           None when scale == 0 or the result would round to zero in
//           either dimension (caller should skip the resize).
//   sideEffects: none (pure integer division).
pub fn compute_logical_size(w: u32, h: u32, scale: u32) -> Option<(u32, u32)> {
    if scale == 0 {
        return None;
    }
    let lw = w / scale;
    let lh = h / scale;
    if lw == 0 || lh == 0 {
        return None;
    }
    Some((lw, lh))
}
// compute_logical_size:end

// payload_event_type:start
//   purpose: peek at byte 4 (the event_type field) of a length-prefixed
//            `[len:u32][event_type:u8]...` payload.
//   input:  payload — buffer of at least 5 bytes (4-byte length prefix + 1 byte type).
//   output: Some(event_type) when payload is long enough; None otherwise.
//   sideEffects: none.
pub fn payload_event_type(payload: &[u8]) -> Option<u8> {
    if payload.len() < 5 {
        return None;
    }
    Some(payload[4])
}
// payload_event_type:end

// extract_pool_id_from_pool_data:start
//   purpose: extract the pool_id from a POOL_DATA event (EV_POOL_DATA=0x03).
//   input:  payload — at least 9 bytes. Wire layout: [len:u32][type:u8=0x03][pool_id:u32 LE]...
//   output: Some(pool_id) when event type is POOL_DATA and the buffer is long enough;
//           None on any other event type or short buffer.
//   sideEffects: none.
pub fn extract_pool_id_from_pool_data(payload: &[u8]) -> Option<u32> {
    if payload.len() < 9 {
        return None;
    }
    if payload[4] != EV_POOL_DATA {
        return None;
    }
    let pool_id = u32::from_le_bytes([payload[5], payload[6], payload[7], payload[8]]);
    Some(pool_id)
}
// extract_pool_id_from_pool_data:end

// extract_pool_id_from_surface_commit:start
//   purpose: extract the pool_id from a SURFACE_COMMIT event (EV_SURFACE_COMMIT=0x04).
//   input:  payload — at least 13 bytes. Wire layout:
//            [len:u32][type:u8=0x04][surface_id:u32 LE][pool_id:u32 LE]...
//            pool_id is shifted to bytes 9..12 because surface_id occupies 5..8.
//   output: Some(pool_id) when event type is SURFACE_COMMIT and the buffer is long enough;
//           None on any other event type or short buffer.
//   sideEffects: none.
pub fn extract_pool_id_from_surface_commit(payload: &[u8]) -> Option<u32> {
    if payload.len() < 13 {
        return None;
    }
    if payload[4] != EV_SURFACE_COMMIT {
        return None;
    }
    let pool_id = u32::from_le_bytes([payload[9], payload[10], payload[11], payload[12]]);
    Some(pool_id)
}
// extract_pool_id_from_surface_commit:end

// should_republish_pool:start
//   purpose: gate the bsdos-core pool keepalive — only republish cached
//            POOL_DATA when its age has passed the threshold (typically 3s).
//   input:  elapsed_secs — seconds since the POOL_DATA was last published;
//            threshold_secs — minimum gap between republishes.
//   output: true when elapsed has reached or passed the threshold.
//   sideEffects: none.
pub fn should_republish_pool(elapsed_secs: u64, threshold_secs: u64) -> bool {
    elapsed_secs >= threshold_secs
}
// should_republish_pool:end

// is_valid_pool_payload_size:start
//   purpose: validate the v1 stream payload size from the 4-byte LE length prefix.
//   input:  size — u32 value from the length prefix.
//   output: true when 0 < size <= 4 MiB (MAX_PAYLOAD constant in wayland_bridge).
//   sideEffects: none.
pub fn is_valid_pool_payload_size(size: u32) -> bool {
    size > 0 && size <= 4 * 1024 * 1024
}
// is_valid_pool_payload_size:end

// format_keyboard_payload:start
//   purpose: reformat a Zenoh keyboard payload into the 7-byte Wayland
//            tunnel input frame consumed by input_bridge.
//   input:  zh — Zenoh payload bytes (>= 5 needed; modifiers read at index 5
//            if present, else default 0). Zenoh layout: [key_code:u32][action:u8]
//            [modifiers:u8][pad:2][ts_ms:u64].
//   output: Some([u8; 7]) with [0x00, key_code(LE), action, modifiers, pad] on success;
//           None when payload is shorter than 5 bytes.
//   sideEffects: none.
pub fn format_keyboard_payload(zh: &[u8]) -> Option<[u8; 7]> {
    if zh.len() < 5 {
        return None;
    }
    let mut buf = [0u8; 7];
    buf[0] = 0x00;
    buf[1..5].copy_from_slice(&zh[0..4]);
    buf[5] = zh[4];
    buf[6] = if zh.len() > 5 { zh[5] } else { 0 };
    Some(buf)
}
// format_keyboard_payload:end

// format_pointer_payload:start
//   purpose: reformat a Zenoh pointer payload into the 18-byte Wayland
//            tunnel input frame consumed by input_bridge.
//   input:  zh — Zenoh payload bytes (>= 17 needed). Zenoh layout:
//            [x:f32][y:f32][buttons:u8][scroll_x:f32][scroll_y:f32] (17 bytes).
//   output: Some([u8; 18]) with [0x01, x, y, buttons, scroll_x, scroll_y] on success;
//           None when payload is shorter than 17 bytes.
//   sideEffects: none.
pub fn format_pointer_payload(zh: &[u8]) -> Option<[u8; 18]> {
    if zh.len() < 17 {
        return None;
    }
    let mut buf = [0u8; 18];
    buf[0] = 0x01;
    buf[1..18].copy_from_slice(&zh[0..17]);
    Some(buf)
}
// format_pointer_payload:end

#[cfg(test)]
mod tests {
    use super::*;

    // ── parse_size_request ──────────────────────────────────────────────────

    #[test]
    fn parse_size_request_basic() {
        let (w, h, s) = parse_size_request("1440x720@2").expect("parse failed");
        assert_eq!(w, 1440);
        assert_eq!(h, 720);
        assert_eq!(s, 2);
    }

    #[test]
    fn parse_size_request_no_scale_defaults_to_1() {
        let (w, h, s) = parse_size_request("800x600@").expect("parse failed");
        assert_eq!((w, h, s), (800, 600, 1));
    }

    #[test]
    fn parse_size_request_missing_at_returns_none() {
        assert!(parse_size_request("800x600").is_none());
    }

    #[test]
    fn parse_size_request_missing_x_returns_none() {
        assert!(parse_size_request("800@1").is_none());
    }

    #[test]
    fn parse_size_request_non_numeric_width_returns_none() {
        // Non-numeric W or H → None
        assert!(parse_size_request("abcxdef@1").is_none());
    }

    #[test]
    fn parse_size_request_non_numeric_scale_defaults_to_1() {
        // Non-numeric scale matches main.rs behavior: `parse().unwrap_or(1).max(1)`.
        let (w, h, s) = parse_size_request("800x600@xyz").expect("parse failed");
        assert_eq!((w, h, s), (800, 600, 1));
    }

    #[test]
    fn parse_size_request_zero_dimension_returns_none() {
        assert!(parse_size_request("0x600@1").is_none());
        assert!(parse_size_request("800x0@1").is_none());
    }

    // ── compute_logical_size ────────────────────────────────────────────────

    #[test]
    fn compute_logical_size_divides_by_scale() {
        assert_eq!(compute_logical_size(1440, 720, 2), Some((720, 360)));
        assert_eq!(compute_logical_size(800, 600, 1), Some((800, 600)));
        assert_eq!(compute_logical_size(3840, 2160, 4), Some((960, 540)));
    }

    #[test]
    fn compute_logical_size_zero_scale_returns_none() {
        assert!(compute_logical_size(800, 600, 0).is_none());
    }

    #[test]
    fn compute_logical_size_rounds_to_zero_returns_none() {
        // 1/2 == 0 in integer division
        assert!(compute_logical_size(1, 600, 2).is_none());
        assert!(compute_logical_size(800, 1, 2).is_none());
    }

    // ── payload_event_type ─────────────────────────────────────────────────

    #[test]
    fn payload_event_type_reads_byte_4() {
        // [len=0][type=0x03]... (len value is irrelevant to this helper)
        let buf = [0u8, 0, 0, 0, 0x03, 0, 0, 0, 0];
        assert_eq!(payload_event_type(&buf), Some(0x03));
    }

    #[test]
    fn payload_event_type_short_buffer_returns_none() {
        assert_eq!(payload_event_type(&[0, 0, 0, 0]), None);
        assert_eq!(payload_event_type(&[]), None);
    }

    // ── extract_pool_id (POOL_DATA & SURFACE_COMMIT) ────────────────────────

    #[test]
    fn extract_pool_id_from_pool_data_reads_bytes_5_to_8() {
        // [len=5][type=0x03][pool_id=42]
        let mut buf = [0u8; 9];
        buf[0..4].copy_from_slice(&5u32.to_le_bytes());
        buf[4] = EV_POOL_DATA;
        buf[5..9].copy_from_slice(&42u32.to_le_bytes());
        assert_eq!(extract_pool_id_from_pool_data(&buf), Some(42));
    }

    #[test]
    fn extract_pool_id_from_pool_data_wrong_event_returns_none() {
        let mut buf = [0u8; 9];
        buf[4] = EV_SURFACE_COMMIT; // wrong type
        assert_eq!(extract_pool_id_from_pool_data(&buf), None);
    }

    #[test]
    fn extract_pool_id_from_pool_data_short_returns_none() {
        let buf = [0u8; 8];
        assert_eq!(extract_pool_id_from_pool_data(&buf), None);
    }

    #[test]
    fn extract_pool_id_from_surface_commit_reads_bytes_9_to_12() {
        // [len=9][type=0x04][surface_id=10][pool_id=42]
        let mut buf = [0u8; 13];
        buf[0..4].copy_from_slice(&9u32.to_le_bytes());
        buf[4] = EV_SURFACE_COMMIT;
        buf[5..9].copy_from_slice(&10u32.to_le_bytes());
        buf[9..13].copy_from_slice(&42u32.to_le_bytes());
        assert_eq!(extract_pool_id_from_surface_commit(&buf), Some(42));
    }

    #[test]
    fn extract_pool_id_from_surface_commit_short_returns_none() {
        let buf = [0u8; 12];
        assert_eq!(extract_pool_id_from_surface_commit(&buf), None);
    }

    // ── should_republish_pool ───────────────────────────────────────────────

    #[test]
    fn should_republish_pool_below_threshold_returns_false() {
        assert!(!should_republish_pool(0, 3));
        assert!(!should_republish_pool(2, 3));
    }

    #[test]
    fn should_republish_pool_at_threshold_returns_true() {
        assert!(should_republish_pool(3, 3));
        assert!(should_republish_pool(10, 3));
    }

    // ── is_valid_pool_payload_size ─────────────────────────────────────────

    #[test]
    fn is_valid_pool_payload_size_zero_is_invalid() {
        assert!(!is_valid_pool_payload_size(0));
    }

    #[test]
    fn is_valid_pool_payload_size_4mb_is_max() {
        assert!(is_valid_pool_payload_size(4 * 1024 * 1024));
    }

    #[test]
    fn is_valid_pool_payload_size_above_4mb_is_invalid() {
        assert!(!is_valid_pool_payload_size(4 * 1024 * 1024 + 1));
        assert!(!is_valid_pool_payload_size(u32::MAX));
    }

    // ── format_keyboard_payload ────────────────────────────────────────────

    #[test]
    fn format_keyboard_payload_basic() {
        // Zenoh: key_code=30 (KEY_A), action=1 (press), modifiers=0
        let zh = [
            30, 0, 0, 0, // key_code
            1,    // action
            0,    // modifiers
        ];
        let out = format_keyboard_payload(&zh).expect("format failed");
        assert_eq!(out[0], 0x00); // type=key
        assert_eq!(&out[1..5], &[30, 0, 0, 0]);
        assert_eq!(out[5], 1); // action
        assert_eq!(out[6], 0); // modifiers
    }

    #[test]
    fn format_keyboard_payload_short_returns_none() {
        assert!(format_keyboard_payload(&[0, 0, 0, 0]).is_none());
        assert!(format_keyboard_payload(&[]).is_none());
    }

    #[test]
    fn format_keyboard_payload_missing_modifiers_defaults_to_zero() {
        // 5 bytes — no modifiers
        let zh = [30, 0, 0, 0, 1];
        let out = format_keyboard_payload(&zh).expect("format failed");
        assert_eq!(out[6], 0);
    }

    // ── format_pointer_payload ─────────────────────────────────────────────

    #[test]
    fn format_pointer_payload_basic() {
        // x=100.0 f32, y=200.0 f32, buttons=0x01, scroll_x=0, scroll_y=0
        let mut zh = [0u8; 17];
        zh[0..4].copy_from_slice(&100.0f32.to_le_bytes());
        zh[4..8].copy_from_slice(&200.0f32.to_le_bytes());
        zh[8] = 0x01;
        // scroll_x/y already zero
        let out = format_pointer_payload(&zh).expect("format failed");
        assert_eq!(out[0], 0x01); // type=pointer
        assert_eq!(&out[1..18], &zh[..17]);
    }

    #[test]
    fn format_pointer_payload_short_returns_none() {
        assert!(format_pointer_payload(&[0u8; 16]).is_none());
    }

    // ── cross-check with capnp framing constants ───────────────────────────

    #[test]
    fn ev_constants_match_main_rs_constants() {
        // If main.rs ever changes these, this test will catch it.
        assert_eq!(EV_POOL_DATA, 0x03);
        assert_eq!(EV_SURFACE_COMMIT, 0x04);
    }
}
