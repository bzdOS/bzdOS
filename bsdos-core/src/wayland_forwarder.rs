// START_AI_HEADER
// MODULE: bsdos-core/src/wayland_forwarder.rs
// PURPOSE: Forward v1 Wayland stream packets from a Unix socket to a Zenoh topic.
// INTENT: One forwarder per active stream. Parameterized by app_id so that
//         multiple streams can publish to independent topics.
// DEPENDENCIES: zenoh session, tokio UnixStream, std::time::Duration, wlstream crate.
// PUBLIC_API: wayland_forwarder(session, app_id, stream_sock) — never returns.
// END_AI_HEADER

use std::sync::Arc;
use std::time::Duration;
use tokio::io::AsyncReadExt;
use wlstream::parser::{EV_POOL_DATA, EV_SURFACE_COMMIT};

const TIMER_KEEPALIVE_SECS: u64 = 5;

/// purpose: Forward v1 Wayland stream packets from a Unix socket to Zenoh.
/// input: session (shared Zenoh session), app_id (e.g. "appBrowser"),
///        stream_sock (path to wayland-stream.sock).
/// output: never returns during normal operation; reconnects after socket errors.
/// sideEffects: opens a Unix socket client, publishes to bsdos/app/{app_id}/stream,
///              stores an in-memory POOL_DATA keepalive cache, spawns timer keepalive task.
pub async fn wayland_forwarder(
    session: Arc<zenoh::Session>,
    app_id: String,
    stream_sock: String,
) {
    wayland_forwarder_impl(session, app_id, stream_sock, TIMER_KEEPALIVE_SECS).await
}

// wayland_forwarder_impl:start
//   purpose: Parameterized implementation — keepalive_secs is configurable for tests (use 1s in tests).
//   input: keepalive_secs: timer interval for republishing cached POOL_DATA to late-joining viewers.
//   output: never returns.
//   sideEffects: same as wayland_forwarder.
pub async fn wayland_forwarder_impl(
    session: Arc<zenoh::Session>,
    app_id: String,
    stream_sock: String,
    keepalive_secs: u64,
) {
    use std::collections::HashMap;

    let topic = format!("bsdos/app/{}/stream", app_id);
    let tag = format!("[{}]", app_id);

    const MAX_PAYLOAD: usize = 4 * 1024 * 1024;
    const POOL_REFRESH_SECS: u64 = 3;

    eprintln!("{} forwarder: publishing to {}", tag, topic);
    let publisher = match (*session).declare_publisher(topic.clone()).await {
        Ok(p) => p,
        Err(e) => {
            eprintln!("{} forwarder: publisher error: {}", tag, e);
            return;
        }
    };

    // Shared pool cache for timer keepalive task.
    // Key: pool_id, Value: last POOL_DATA payload bytes.
    let shared_cache: Arc<tokio::sync::Mutex<HashMap<u32, Vec<u8>>>> =
        Arc::new(tokio::sync::Mutex::new(HashMap::new()));

    // Spawn timer keepalive task: every keepalive_secs republish all cached
    // POOL_DATA so that late-joining viewers get the current framebuffer even when
    // the app hasn't committed a new surface (static content, about:blank, etc.).
    {
        let cache_ka = shared_cache.clone();
        let session_ka = session.clone();
        let topic_ka = topic.clone();
        let tag_ka = tag.clone();
        tokio::spawn(async move {
            let pub_ka = match (*session_ka).declare_publisher(topic_ka).await {
                Ok(p) => p,
                Err(e) => {
                    eprintln!("{} timer-keepalive: publisher error: {}", tag_ka, e);
                    return;
                }
            };
            let mut ticker = tokio::time::interval(Duration::from_secs(keepalive_secs));
            ticker.tick().await; // skip first tick (fires immediately)
            loop {
                ticker.tick().await;
                let cache = cache_ka.lock().await;
                for data in cache.values() {
                    if let Err(e) = pub_ka.put(data.as_slice()).await {
                        eprintln!("{} timer-keepalive: publish error: {}", tag_ka, e);
                    }
                }
            }
        });
    }

    // START_WF_RETRY_LOOP
    //   purpose: outer reconnect loop — reconnect after any socket error or timeout
    //   backoff: 1 second between reconnect attempts
    loop {
        let mut retries = 0u32;
        let mut stream = loop {
            match tokio::net::UnixStream::connect(&stream_sock).await {
                Ok(s) => break s,
                Err(_) => {
                    if retries % 30 == 0 {
                        eprintln!("{} forwarder: tunnel not ready ({}), waiting...", tag, stream_sock);
                    }
                    retries += 1;
                    tokio::time::sleep(Duration::from_secs(1)).await;
                }
            }
        };
        eprintln!("{} forwarder: connected to {}", tag, stream_sock);

        let mut pool_cache: HashMap<u32, (Vec<u8>, std::time::Instant)> = HashMap::new();

        loop {
            // START_WF_READ_TIMEOUT
            //   purpose: detect silent connections (tunnel accepted but no frames)
            //   timeout: 10 seconds
            //   onFailure: break → outer loop reconnects
            let mut len_bytes = [0u8; 4];
            match tokio::time::timeout(Duration::from_secs(10), stream.read_exact(&mut len_bytes)).await {
                Ok(Ok(_)) => {}
                Ok(Err(e)) => {
                    eprintln!("{} forwarder: read error (reconnect): {}", tag, e);
                    break;
                }
                Err(_) => {
                    eprintln!("{} forwarder: no data for 10s, reconnecting", tag);
                    break;
                }
            }
            // END_WF_READ_TIMEOUT

            let payload_size = u32::from_le_bytes(len_bytes) as usize;
            if payload_size == 0 || payload_size > MAX_PAYLOAD {
                eprintln!("{} forwarder: payload_size out of range: {}", tag, payload_size);
                break;
            }

            let mut payload = vec![0u8; 4 + payload_size];
            payload[..4].copy_from_slice(&len_bytes);
            if let Err(e) = stream.read_exact(&mut payload[4..]).await {
                eprintln!("{} forwarder: payload read error: {}", tag, e);
                break;
            }

            let ev_type = if payload.len() > 4 { payload[4] } else { 0 };

            if ev_type == EV_POOL_DATA && payload.len() >= 9 {
                let pool_id = u32::from_le_bytes([payload[5], payload[6], payload[7], payload[8]]);
                eprintln!("{} POOL_DATA: pool_id={} size={}", tag, pool_id, payload.len());
                pool_cache.insert(pool_id, (payload.clone(), std::time::Instant::now()));
                // Update shared cache for timer keepalive task.
                shared_cache.lock().await.insert(pool_id, payload.clone());
            } else if ev_type == EV_SURFACE_COMMIT && payload.len() >= 13 {
                let pool_id = u32::from_le_bytes([payload[9], payload[10], payload[11], payload[12]]);
                if let Some((cached, last_pub)) = pool_cache.get_mut(&pool_id) {
                    let elapsed = last_pub.elapsed();
                    if elapsed >= Duration::from_secs(POOL_REFRESH_SECS) {
                        if let Err(e) = publisher.put(cached.as_slice()).await {
                            eprintln!("{} keepalive publish error: {}", tag, e);
                        }
                        *last_pub = std::time::Instant::now();
                    }
                }
            }

            if let Err(e) = publisher.put(payload.as_slice()).await {
                eprintln!("{} publish error: {}", tag, e);
            }
        }
        // END_WF_RETRY_LOOP

        // Clear shared cache on disconnect so stale data isn't republished.
        shared_cache.lock().await.clear();

        tokio::time::sleep(Duration::from_secs(1)).await;
    }
}

// START_WF_PROTO_HELPERS
// Pure v1 frame-protocol helpers — no I/O, no async, fully unit-testable.
// The wire format is: [4-byte LE payload_size][payload_size bytes of event data].
// The full assembled frame (length prefix + event bytes) is what the forwarder
// reads, caches, and publishes to Zenoh.
//
// Event-type constants are sourced from `wlstream::parser` to avoid duplication.
// These helpers are test-only; production code uses `EV_POOL_DATA` / `EV_SURFACE_COMMIT`
// directly from the top-level `use wlstream::parser::{...}` import.

/// Maximum accepted frame payload (4 MiB) — matches wlstream ERROR code 0x0003.
#[cfg(test)]
const WF_MAX_PAYLOAD: usize = 4 * 1024 * 1024;

#[cfg(test)]
use wlstream::parser::EV_POOL_DATA as WF_EV_POOL_DATA;
#[cfg(test)]
use wlstream::parser::EV_SURFACE_COMMIT as WF_EV_SURFACE_COMMIT;

/// Build a v1 stream frame: prepend the 4-byte LE length of `event_data`.
#[cfg(test)]
fn build_v1_frame(event_data: &[u8]) -> Vec<u8> {
    let mut frame = Vec::with_capacity(4 + event_data.len());
    frame.extend_from_slice(&(event_data.len() as u32).to_le_bytes());
    frame.extend_from_slice(event_data);
    frame
}

/// Decode the payload size from a 4-byte frame header.
#[cfg(test)]
fn decode_v1_frame_size(header: &[u8; 4]) -> usize {
    u32::from_le_bytes(*header) as usize
}

/// Return false if size is 0 or exceeds the 4 MiB hard limit.
#[cfg(test)]
fn is_valid_frame_size(size: usize) -> bool {
    size > 0 && size <= WF_MAX_PAYLOAD
}

/// Extract the event-type byte from a full frame (offset 4). Returns 0 on short frames.
#[cfg(test)]
fn frame_ev_type(frame: &[u8]) -> u8 {
    if frame.len() > 4 { frame[4] } else { 0 }
}

/// Extract pool_id from a POOL_DATA frame (bytes 5-8 of the full frame).
/// Field offsets match the canonical wlstream wire layout.
#[cfg(test)]
fn pool_data_pool_id(frame: &[u8]) -> Option<u32> {
    if frame.len() >= 9 {
        Some(u32::from_le_bytes([frame[5], frame[6], frame[7], frame[8]]))
    } else {
        None
    }
}

/// Extract pool_id from a SURFACE_COMMIT frame (bytes 9-12 of the full frame).
/// Field offsets match the canonical wlstream wire layout.
#[cfg(test)]
fn surface_commit_pool_id(frame: &[u8]) -> Option<u32> {
    if frame.len() >= 13 {
        Some(u32::from_le_bytes([frame[9], frame[10], frame[11], frame[12]]))
    } else {
        None
    }
}
// END_WF_PROTO_HELPERS

#[cfg(test)]
mod tests {
    use super::*;

    // ── build_v1_frame / decode_v1_frame_size ─────────────────────────────

    #[test]
    fn build_frame_empty_payload() {
        let frame = build_v1_frame(&[]);
        assert_eq!(frame.len(), 4);
        assert_eq!(decode_v1_frame_size(frame[..4].try_into().unwrap()), 0);
    }

    #[test]
    fn build_frame_small_payload_roundtrip() {
        let data: Vec<u8> = vec![WF_EV_POOL_DATA, 0x01, 0x00, 0x00, 0x00];
        let frame = build_v1_frame(&data);
        assert_eq!(frame.len(), 4 + 5);
        let size = decode_v1_frame_size(frame[..4].try_into().unwrap());
        assert_eq!(size, 5);
        assert_eq!(&frame[4..], data.as_slice());
    }

    #[test]
    fn build_frame_100_byte_payload_roundtrip() {
        let data: Vec<u8> = (0u8..100).collect();
        let frame = build_v1_frame(&data);
        let size = decode_v1_frame_size(frame[..4].try_into().unwrap());
        assert_eq!(size, 100);
        assert_eq!(&frame[4..], data.as_slice());
    }

    #[test]
    fn decode_frame_size_little_endian() {
        // 0x00000100 = 256, stored LE as [0x00, 0x01, 0x00, 0x00]
        let hdr: [u8; 4] = [0x00, 0x01, 0x00, 0x00];
        assert_eq!(decode_v1_frame_size(&hdr), 256);
    }

    // ── is_valid_frame_size ───────────────────────────────────────────────

    #[test]
    fn valid_frame_size_one_byte() {
        assert!(is_valid_frame_size(1));
    }

    #[test]
    fn valid_frame_size_at_limit() {
        assert!(is_valid_frame_size(WF_MAX_PAYLOAD));
    }

    #[test]
    fn invalid_frame_size_zero() {
        assert!(!is_valid_frame_size(0));
    }

    #[test]
    fn invalid_frame_size_over_limit() {
        assert!(!is_valid_frame_size(WF_MAX_PAYLOAD + 1));
    }

    // ── frame_ev_type ────────────────────────────────────────────────────

    #[test]
    fn ev_type_pool_data() {
        let data = [WF_EV_POOL_DATA, 0x01, 0x00, 0x00, 0x00];
        let frame = build_v1_frame(&data);
        assert_eq!(frame_ev_type(&frame), WF_EV_POOL_DATA);
    }

    #[test]
    fn ev_type_surface_commit() {
        let mut data = vec![WF_EV_SURFACE_COMMIT];
        data.extend_from_slice(&[0u8; 8]);
        let frame = build_v1_frame(&data);
        assert_eq!(frame_ev_type(&frame), WF_EV_SURFACE_COMMIT);
    }

    #[test]
    fn ev_type_short_frame_returns_zero() {
        assert_eq!(frame_ev_type(&[0u8; 4]), 0);
    }

    // ── pool_data_pool_id ────────────────────────────────────────────────

    #[test]
    fn pool_data_pool_id_extracted_correctly() {
        let pool_id: u32 = 42;
        let mut data = vec![WF_EV_POOL_DATA];
        data.extend_from_slice(&pool_id.to_le_bytes()); // bytes 1-4 of event data
        data.extend_from_slice(&[0u8; 16]);             // rest of payload
        let frame = build_v1_frame(&data);
        assert_eq!(pool_data_pool_id(&frame), Some(42));
    }

    #[test]
    fn pool_data_pool_id_max_value() {
        let pool_id: u32 = u32::MAX;
        let mut data = vec![WF_EV_POOL_DATA];
        data.extend_from_slice(&pool_id.to_le_bytes());
        let frame = build_v1_frame(&data);
        assert_eq!(pool_data_pool_id(&frame), Some(u32::MAX));
    }

    #[test]
    fn pool_data_pool_id_too_short_returns_none() {
        let frame = build_v1_frame(&[WF_EV_POOL_DATA, 0x01, 0x00]);
        assert_eq!(pool_data_pool_id(&frame), None);
    }

    // ── surface_commit_pool_id ───────────────────────────────────────────

    #[test]
    fn surface_commit_pool_id_extracted_correctly() {
        // Layout: [ev_type=0x04][4 bytes][4 bytes][pool_id u32 LE]
        // In full frame: [0..4]=size [4]=ev [5..9]=4 bytes [9..13]=pool_id
        let pool_id: u32 = 99;
        let mut data = vec![WF_EV_SURFACE_COMMIT];
        data.extend_from_slice(&[0xAAu8; 4]); // unknown bytes at event-data offsets 1-4
        data.extend_from_slice(&pool_id.to_le_bytes()); // at event-data offsets 5-8
        let frame = build_v1_frame(&data);
        assert_eq!(surface_commit_pool_id(&frame), Some(99));
    }

    #[test]
    fn surface_commit_pool_id_too_short_returns_none() {
        // event data has only 7 bytes → full frame 4+7=11 < 13
        let data = [WF_EV_SURFACE_COMMIT; 7];
        let frame = build_v1_frame(&data);
        assert_eq!(frame.len(), 11);
        assert_eq!(surface_commit_pool_id(&frame), None);
    }

    // ── Pool ID distinctness across event types ───────────────────────────

    #[test]
    fn pool_data_and_surface_commit_use_different_offsets() {
        // A frame containing both bytes-5-8=0x11111111 and bytes-9-12=0x22222222.
        let mut data = vec![0x00u8]; // ev_type placeholder
        data.extend_from_slice(&0x11111111u32.to_le_bytes()); // bytes 1-4 (POOL_DATA pool_id @ frame[5..9])
        data.extend_from_slice(&0x22222222u32.to_le_bytes()); // bytes 5-8 (SURFACE_COMMIT pool_id @ frame[9..13])
        let frame = build_v1_frame(&data);
        assert_eq!(pool_data_pool_id(&frame), Some(0x11111111));
        assert_eq!(surface_commit_pool_id(&frame), Some(0x22222222));
    }
}
