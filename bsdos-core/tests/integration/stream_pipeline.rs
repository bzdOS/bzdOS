//! Stream pipeline integration tests.
//!
//! Covers three changed components:
//!   1. wayland_forwarder — POOL_DATA publish + timer keepalive for late subscribers
//!   2. compute_randr_mode — Retina DPI: physical pixels, not divided by scale
//!   3. stream_input_handler — Zenoh keyboard/pointer events → input.sock bytes
//!
//! All tests use in-process Zenoh (TestZenohPeer) and real Unix sockets.
//! keepalive_secs=1 is used in forwarder tests so the suite runs in <15s total.

use std::sync::atomic::{AtomicU32, Ordering};
use std::time::Duration;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;
use zenoh_peer::TestZenohPeer;

// ── helpers ──────────────────────────────────────────────────────────────────

static SOCK_SEQ: AtomicU32 = AtomicU32::new(0);

fn unique_sock() -> std::path::PathBuf {
    let n = SOCK_SEQ.fetch_add(1, Ordering::Relaxed);
    std::path::PathBuf::from(format!("/tmp/bsdos-test-{}-{}.sock", std::process::id(), n))
}

fn cleanup(path: &std::path::Path) {
    let _ = std::fs::remove_file(path);
}

/// Build a v1 length-prefixed POOL_DATA packet.
/// Layout: [payload_len:4 LE][0x03][pool_id:4 LE][data...]
fn make_pool_data(pool_id: u32, data: &[u8]) -> Vec<u8> {
    let payload_len = (1 + 4 + data.len()) as u32;
    let mut out = Vec::with_capacity(4 + payload_len as usize);
    out.extend_from_slice(&payload_len.to_le_bytes());
    out.push(0x03); // EV_POOL_DATA
    out.extend_from_slice(&pool_id.to_le_bytes());
    out.extend_from_slice(data);
    out
}

/// Build a v1 length-prefixed SURFACE_COMMIT packet.
/// Layout: [payload_len:4 LE][0x04][4 bytes padding][pool_id:4 LE]
/// wayland_forwarder reads pool_id at payload[9..13] (offset from start of full packet).
fn make_surface_commit(pool_id: u32) -> Vec<u8> {
    // payload = type(1) + padding(4) + pool_id(4) = 9 bytes
    let payload_len: u32 = 9;
    let mut out = vec![0u8; 4 + 9];
    out[0..4].copy_from_slice(&payload_len.to_le_bytes());
    out[4] = 0x04; // EV_SURFACE_COMMIT
    // out[5..9] = padding (zeroed)
    out[9..13].copy_from_slice(&pool_id.to_le_bytes());
    out
}

/// Build a 16-byte Zenoh keyboard payload.
fn make_kb_payload(key_code: u32, action: u8, modifiers: u8) -> Vec<u8> {
    let mut buf = vec![0u8; 16];
    buf[0..4].copy_from_slice(&key_code.to_le_bytes());
    buf[4] = action;
    buf[5] = modifiers;
    buf
}

/// Build a 17-byte Zenoh pointer payload.
fn make_ptr_payload(x: f32, y: f32, buttons: u8) -> Vec<u8> {
    let mut buf = vec![0u8; 17];
    buf[0..4].copy_from_slice(&x.to_le_bytes());
    buf[4..8].copy_from_slice(&y.to_le_bytes());
    buf[8] = buttons;
    buf
}

// ── Group 1: wayland_forwarder ────────────────────────────────────────────────

/// POOL_DATA written to the socket is immediately published to Zenoh.
#[tokio::test(flavor = "multi_thread")]
async fn test_pool_data_published_to_zenoh() {
    let sock = unique_sock();
    cleanup(&sock);

    // "Tunnel" side: server that the forwarder will connect to.
    let listener = UnixListener::bind(&sock).expect("bind");

    let peer = TestZenohPeer::new().await;
    let session = peer.session();
    let sub = session.declare_subscriber("bsdos/app/t1/stream").await.unwrap();

    let fwd_session = session.clone();
    let sock_str = sock.to_str().unwrap().to_string();
    tokio::spawn(async move {
        bsdos_core::wayland_forwarder::wayland_forwarder_impl(
            fwd_session, "t1".into(), sock_str, 60,
        ).await;
    });

    let (mut tunnel, _) = listener.accept().await.unwrap();
    let pkt = make_pool_data(42, &[0xAA; 16]);
    tunnel.write_all(&pkt).await.unwrap();

    let sample = tokio::time::timeout(Duration::from_secs(2), sub.recv_async())
        .await.expect("timeout").expect("recv");
    let bytes = sample.payload().to_bytes();
    assert_eq!(bytes[4], 0x03, "ev_type should be EV_POOL_DATA");
    assert_eq!(&bytes[5..9], &42u32.to_le_bytes(), "pool_id should be 42");

    cleanup(&sock);
}

/// SURFACE_COMMIT written to the socket is immediately published to Zenoh.
#[tokio::test(flavor = "multi_thread")]
async fn test_surface_commit_published_to_zenoh() {
    let sock = unique_sock();
    cleanup(&sock);

    let listener = UnixListener::bind(&sock).expect("bind");

    let peer = TestZenohPeer::new().await;
    let session = peer.session();
    let sub = session.declare_subscriber("bsdos/app/t2/stream").await.unwrap();

    let fwd_session = session.clone();
    let sock_str = sock.to_str().unwrap().to_string();
    tokio::spawn(async move {
        bsdos_core::wayland_forwarder::wayland_forwarder_impl(
            fwd_session, "t2".into(), sock_str, 60,
        ).await;
    });

    let (mut tunnel, _) = listener.accept().await.unwrap();

    // First send POOL_DATA to populate cache (commit alone doesn't republish without it).
    let pd = make_pool_data(7, &[0xBB; 8]);
    tunnel.write_all(&pd).await.unwrap();
    // Drain the POOL_DATA publish.
    let _ = tokio::time::timeout(Duration::from_secs(2), sub.recv_async()).await;

    let sc = make_surface_commit(7);
    tunnel.write_all(&sc).await.unwrap();

    let sample = tokio::time::timeout(Duration::from_secs(2), sub.recv_async())
        .await.expect("timeout").expect("recv");
    let bytes = sample.payload().to_bytes();
    assert_eq!(bytes[4], 0x04, "ev_type should be EV_SURFACE_COMMIT");

    cleanup(&sock);
}

/// Timer keepalive: a subscriber that joins AFTER the last POOL_DATA was published
/// receives POOL_DATA within keepalive_secs + slack, even though Chrome is idle.
#[tokio::test(flavor = "multi_thread")]
async fn test_timer_keepalive_serves_late_subscriber() {
    let sock = unique_sock();
    cleanup(&sock);

    let listener = UnixListener::bind(&sock).expect("bind");

    let peer = TestZenohPeer::new().await;
    let session = peer.session();

    // Subscribe EARLY just to drain the initial publish (not the late-subscriber under test).
    let early_sub = session.declare_subscriber("bsdos/app/t3/stream").await.unwrap();

    let fwd_session = session.clone();
    let sock_str = sock.to_str().unwrap().to_string();
    tokio::spawn(async move {
        // keepalive_secs=1 so the test completes quickly.
        bsdos_core::wayland_forwarder::wayland_forwarder_impl(
            fwd_session, "t3".into(), sock_str, 1,
        ).await;
    });

    let (mut tunnel, _) = listener.accept().await.unwrap();

    // Send POOL_DATA — forwarder caches it and immediately publishes.
    let pkt = make_pool_data(99, &[0xCC; 32]);
    tunnel.write_all(&pkt).await.unwrap();
    let _ = tokio::time::timeout(Duration::from_secs(2), early_sub.recv_async()).await;

    // Now subscribe LATE (no new frames from Chrome, but timer should re-publish within 1s).
    let late_sub = session.declare_subscriber("bsdos/app/t3/stream").await.unwrap();

    let sample = tokio::time::timeout(
        Duration::from_millis(2500), // 1s keepalive + 1.5s slack
        late_sub.recv_async(),
    )
    .await.expect("timer keepalive should republish POOL_DATA within 1s + slack")
    .expect("recv");

    let bytes = sample.payload().to_bytes();
    assert_eq!(bytes[4], 0x03, "keepalive should republish EV_POOL_DATA");
    assert_eq!(&bytes[5..9], &99u32.to_le_bytes(), "keepalive pool_id should match");

    cleanup(&sock);
}

// ── Group 2: compute_randr_mode ───────────────────────────────────────────────

/// Retina (2x): "2560x1440@2" → mode "2560x1440" (physical pixels, NOT "1280x720").
#[test]
fn test_randr_mode_uses_physical_pixels_retina() {
    let mode = bsdos_core::stream_manager::compute_randr_mode("2560x1440@2")
        .expect("should parse");
    assert_eq!(mode, "2560x1440", "must use physical pixel dimensions, not divide by scale");
}

/// Standard (1x): "1920x1080@1" → mode "1920x1080".
#[test]
fn test_randr_mode_1x_display() {
    let mode = bsdos_core::stream_manager::compute_randr_mode("1920x1080@1")
        .expect("should parse");
    assert_eq!(mode, "1920x1080");
}

/// Missing scale field → None (parse_size_request requires @S).
#[test]
fn test_randr_mode_missing_scale_returns_none() {
    let result = bsdos_core::stream_manager::compute_randr_mode("1920x1080");
    assert!(result.is_none(), "no @S suffix should return None");
}

// ── Group 3: stream_input_handler ─────────────────────────────────────────────

/// Helper: create a temp rundir with input.sock bound, return (rundir, listener).
/// stream_input_handler takes rundir and joins "input.sock" to get the socket path.
fn make_input_rundir() -> (std::path::PathBuf, UnixListener) {
    let rundir = std::path::PathBuf::from(format!(
        "/tmp/bsdos-test-rundir-{}-{}",
        std::process::id(),
        SOCK_SEQ.fetch_add(1, Ordering::Relaxed)
    ));
    std::fs::create_dir_all(&rundir).expect("mkdir rundir");
    let sock_path = rundir.join("input.sock");
    let _ = std::fs::remove_file(&sock_path);
    let listener = UnixListener::bind(&sock_path).expect("bind input.sock");
    (rundir, listener)
}

fn cleanup_rundir(rundir: &std::path::Path) {
    let _ = std::fs::remove_file(rundir.join("input.sock"));
    let _ = std::fs::remove_dir(rundir);
}

/// Keyboard event on Zenoh topic → 7-byte frame at input.sock.
/// Frame: [0x00][key_code:4 LE][action:1][modifiers:1]
#[tokio::test(flavor = "multi_thread")]
async fn test_keyboard_event_forwarded_to_sock() {
    let (rundir, listener) = make_input_rundir();

    let peer = TestZenohPeer::new().await;
    let session = peer.session();

    let handler_session = session.clone();
    let handler_rundir = rundir.clone();
    tokio::spawn(async move {
        bsdos_core::stream_manager::stream_input_handler(
            handler_session,
            "t4".into(),
            handler_rundir,
        ).await;
    });

    // Accept the handler's connection to input.sock.
    let (mut input_conn, _) = tokio::time::timeout(
        Duration::from_secs(3),
        listener.accept(),
    ).await.expect("handler should connect within 3s").expect("accept");

    // Publish keyboard event: KEY_A (evdev 30), action=down(1), modifiers=shift(1).
    let publisher = session.declare_publisher("bsdos/app/t4/input/keyboard").await.unwrap();
    publisher.put(make_kb_payload(30, 1, 0x01)).await.unwrap();

    // Read the 7-byte frame from input.sock.
    let mut frame = [0u8; 7];
    tokio::time::timeout(Duration::from_secs(2), input_conn.read_exact(&mut frame))
        .await.expect("timeout").expect("read");

    assert_eq!(frame[0], 0x00, "keyboard frame type byte");
    assert_eq!(&frame[1..5], &30u32.to_le_bytes(), "key_code KEY_A=30");
    assert_eq!(frame[5], 1,    "action=down");
    assert_eq!(frame[6], 0x01, "modifiers=shift");

    cleanup_rundir(&rundir);
}

/// Pointer event on Zenoh topic → 18-byte frame at input.sock.
/// Frame: [0x01][x:4][y:4][buttons:1][scroll_x:4][scroll_y:4]
#[tokio::test(flavor = "multi_thread")]
async fn test_pointer_event_forwarded_to_sock() {
    let (rundir, listener) = make_input_rundir();

    let peer = TestZenohPeer::new().await;
    let session = peer.session();

    let handler_session = session.clone();
    let handler_rundir = rundir.clone();
    tokio::spawn(async move {
        bsdos_core::stream_manager::stream_input_handler(
            handler_session,
            "t5".into(),
            handler_rundir,
        ).await;
    });

    let (mut input_conn, _) = tokio::time::timeout(
        Duration::from_secs(3),
        listener.accept(),
    ).await.expect("handler should connect within 3s").expect("accept");

    let publisher = session.declare_publisher("bsdos/app/t5/input/pointer").await.unwrap();
    publisher.put(make_ptr_payload(320.0_f32, 240.0_f32, 0x01)).await.unwrap();

    let mut frame = [0u8; 18];
    tokio::time::timeout(Duration::from_secs(2), input_conn.read_exact(&mut frame))
        .await.expect("timeout").expect("read");

    assert_eq!(frame[0], 0x01, "pointer frame type byte");
    assert_eq!(&frame[1..5],  &320.0_f32.to_le_bytes(), "x=320.0");
    assert_eq!(&frame[5..9],  &240.0_f32.to_le_bytes(), "y=240.0");
    assert_eq!(frame[9], 0x01, "buttons=left");

    cleanup_rundir(&rundir);
}

/// Malformed keyboard payload (too short) → nothing written to input.sock.
#[tokio::test(flavor = "multi_thread")]
async fn test_malformed_keyboard_not_forwarded() {
    let (rundir, listener) = make_input_rundir();

    let peer = TestZenohPeer::new().await;
    let session = peer.session();

    let handler_session = session.clone();
    let handler_rundir = rundir.clone();
    tokio::spawn(async move {
        bsdos_core::stream_manager::stream_input_handler(
            handler_session,
            "t6".into(),
            handler_rundir,
        ).await;
    });

    let (mut input_conn, _) = tokio::time::timeout(
        Duration::from_secs(3),
        listener.accept(),
    ).await.expect("handler should connect").expect("accept");

    // 4-byte payload: format_keyboard_payload requires >= 5 → None → nothing written.
    let publisher = session.declare_publisher("bsdos/app/t6/input/keyboard").await.unwrap();
    publisher.put(vec![0x01u8, 0x00, 0x00, 0x00]).await.unwrap();

    let mut buf = [0u8; 7];
    let result = tokio::time::timeout(
        Duration::from_millis(500),
        input_conn.read_exact(&mut buf),
    ).await;
    assert!(result.is_err(), "malformed payload must not produce a socket write");

    cleanup_rundir(&rundir);
}

/// EOF from tunnel (relay closed accepted fd) → handler detects and reconnects.
/// Verifies the `stream.readable()` arm in the select loop.
#[tokio::test(flavor = "multi_thread")]
async fn test_handler_reconnects_after_relay_eof() {
    let (rundir, listener) = make_input_rundir();

    let peer = TestZenohPeer::new().await;
    let session = peer.session();

    let handler_session = session.clone();
    let handler_rundir = rundir.clone();
    tokio::spawn(async move {
        bsdos_core::stream_manager::stream_input_handler(
            handler_session,
            "t7".into(),
            handler_rundir,
        ).await;
    });

    // First connection: relay accepts, then drops (simulates relay thread exit).
    let (conn1, _) = tokio::time::timeout(Duration::from_secs(3), listener.accept())
        .await.expect("first connect timeout").expect("accept");
    drop(conn1); // server closes fd → EOF on handler side

    // Handler must detect EOF via readable() and reconnect within 2s.
    let result = tokio::time::timeout(Duration::from_secs(2), listener.accept()).await;
    assert!(result.is_ok() && result.unwrap().is_ok(),
        "handler must reconnect after relay EOF");

    cleanup_rundir(&rundir);
}
