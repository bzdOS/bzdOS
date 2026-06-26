//! Demonstration test for zenoh-integration-test crate (v0.1.2 DOF item)
//!
//! Verifies that TestZenohPeer provides a real `Arc<zenoh::Session>` that
//! supports pub/sub without network I/O.

use std::time::Duration;
use zenoh_peer::TestZenohPeer;

/// Pub/sub roundtrip: declare publisher + subscriber, put payload, recv_async returns it.
///
/// This test must complete in <10ms with no network access (in-process channels only).
#[tokio::test(flavor = "multi_thread", worker_threads = 1)]
async fn pubsub_roundtrip() {
    let peer = TestZenohPeer::new().await;
    let session = peer.session();

    let publisher = session
        .declare_publisher("bsdos/test")
        .await
        .expect("Failed to declare publisher");

    let subscriber = session
        .declare_subscriber("bsdos/test")
        .await
        .expect("Failed to declare subscriber");

    publisher
        .put("hello world")
        .await
        .expect("Failed to put payload");

    let sample = tokio::time::timeout(Duration::from_millis(100), subscriber.recv_async())
        .await
        .expect("Timeout waiting for sample — in-process pub/sub should be <10ms")
        .expect("Failed to receive sample");

    assert_eq!(
        sample.payload().to_bytes().as_ref(),
        b"hello world",
        "Payload mismatch — in-process channel should preserve bytes exactly"
    );
}

/// Multiple subscribers on the same topic all receive the payload.
#[tokio::test(flavor = "multi_thread", worker_threads = 1)]
async fn fanout_to_multiple_subscribers() {
    let peer = TestZenohPeer::new().await;
    let session = peer.session();

    let publisher = session
        .declare_publisher("bsdos/fanout")
        .await
        .expect("Failed to declare publisher");

    let sub1 = session
        .declare_subscriber("bsdos/fanout")
        .await
        .expect("Failed to declare subscriber 1");

    let sub2 = session
        .declare_subscriber("bsdos/fanout")
        .await
        .expect("Failed to declare subscriber 2");

    publisher
        .put("broadcast")
        .await
        .expect("Failed to put payload");

    let s1 = tokio::time::timeout(Duration::from_millis(100), sub1.recv_async())
        .await
        .expect("Timeout on sub1")
        .expect("Failed to recv on sub1");

    let s2 = tokio::time::timeout(Duration::from_millis(100), sub2.recv_async())
        .await
        .expect("Timeout on sub2")
        .expect("Failed to recv on sub2");

    assert_eq!(s1.payload().to_bytes().as_ref(), b"broadcast");
    assert_eq!(s2.payload().to_bytes().as_ref(), b"broadcast");
}

/// Binary payloads (non-UTF8) are preserved exactly.
#[tokio::test(flavor = "multi_thread", worker_threads = 1)]
async fn binary_payload_preserved() {
    let peer = TestZenohPeer::new().await;
    let session = peer.session();

    let publisher = session
        .declare_publisher("bsdos/binary")
        .await
        .expect("Failed to declare publisher");

    let subscriber = session
        .declare_subscriber("bsdos/binary")
        .await
        .expect("Failed to declare subscriber");

    // 32-byte Cap'n Proto payload (same as bsdos/telemetry wire format)
    let binary_payload: Vec<u8> = (0..32).collect();

    publisher
        .put(&binary_payload)
        .await
        .expect("Failed to put binary payload");

    let sample = tokio::time::timeout(Duration::from_millis(100), subscriber.recv_async())
        .await
        .expect("Timeout waiting for binary sample")
        .expect("Failed to receive binary sample");

    assert_eq!(
        sample.payload().to_bytes().as_ref(),
        binary_payload.as_slice(),
        "Binary payload should be preserved byte-for-byte"
    );
}
