//! TestZenohPeer — in-process Zenoh peer for unit tests
//!
//! Provides a real `Arc<zenoh::Session>` that uses internal channels instead of
//! TCP/TLS. Tests can `declare_publisher`, `declare_subscriber`, `put`, `recv_async`
//! without network I/O.
//!
//! # Example
//!
//! ```rust
//! use zenoh_peer::TestZenohPeer;
//! use std::time::Duration;
//!
//! #[tokio::test]
//! async fn pubsub_roundtrip() {
//!     let peer = TestZenohPeer::new().await;
//!     let session = peer.session();
//!     let pub_ = session.declare_publisher("bsdos/test").await.unwrap();
//!     let sub = session.declare_subscriber("bsdos/test").await.unwrap();
//!
//!     pub_.put("hello world").await.unwrap();
//!
//!     let sample = tokio::time::timeout(Duration::from_millis(100), sub.recv_async())
//!         .await.expect("timeout")
//!         .expect("recv");
//!     assert_eq!(sample.payload().to_bytes(), b"hello world");
//! }
//! ```

use std::sync::Arc;
use std::time::Duration;
use zenoh::Session;

/// In-process Zenoh peer for testing
///
/// Wraps a real `zenoh::Session` configured to use only internal channels.
/// No network I/O occurs — all pub/sub stays in-process.
pub struct TestZenohPeer {
    session: Arc<Session>,
}

impl TestZenohPeer {
    /// Create a new in-process Zenoh peer
    ///
    /// Configures Zenoh with:
    /// - `mode = "peer"` (no router needed)
    /// - `connect/endpoints = []` (no network connections)
    /// - `listen/endpoints = []` (no listeners)
    ///
    /// Returns a `TestZenohPeer` wrapping an `Arc<zenoh::Session>`.
    ///
    /// # Panics
    ///
    /// Panics if Zenoh session creation fails (should not happen with this config).
    pub async fn new() -> Self {
        let mut config = zenoh::Config::default();

        // Configure for in-process only (no network I/O)
        config.insert_json5("mode", "\"peer\"").expect("Failed to set mode");
        config.insert_json5("connect/endpoints", "[]").expect("Failed to set connect endpoints");
        config.insert_json5("listen/endpoints", "[]").expect("Failed to set listen endpoints");

        let session = zenoh::open(config)
            .await
            .expect("Failed to open in-process Zenoh session");

        Self {
            session: Arc::new(session),
        }
    }

    /// Get a reference to the underlying `Arc<zenoh::Session>`
    ///
    /// Use this to `declare_publisher`, `declare_subscriber`, etc.
    pub fn session(&self) -> Arc<Session> {
        Arc::clone(&self.session)
    }

    /// Inject a payload into a topic (for testing subscribers)
    ///
    /// Creates a temporary publisher, puts the payload, and drops the publisher.
    ///
    /// # Arguments
    ///
    /// * `topic` - Zenoh key expression (e.g., "bsdos/test")
    /// * `payload` - Bytes to publish
    ///
    /// # Panics
    ///
    /// Panics if publisher creation or put fails.
    pub async fn inject(&self, topic: &str, payload: &[u8]) {
        let publisher = self.session.declare_publisher(topic)
            .await
            .expect("Failed to declare publisher for inject");

        publisher.put(payload).await.expect("Failed to put payload");
    }

    /// Capture all payloads received on a topic within a timeout
    ///
    /// Creates a temporary subscriber, collects payloads for `timeout_ms`,
    /// then returns the collected payloads.
    ///
    /// # Arguments
    ///
    /// * `topic` - Zenoh key expression (e.g., "bsdos/test")
    /// * `timeout_ms` - How long to collect (milliseconds)
    ///
    /// # Returns
    ///
    /// `Vec<Vec<u8>>` — all payloads received within the timeout.
    ///
    /// # Panics
    ///
    /// Panics if subscriber creation fails.
    pub async fn captured(&self, topic: &str, timeout_ms: u64) -> Vec<Vec<u8>> {
        let subscriber = self.session.declare_subscriber(topic)
            .await
            .expect("Failed to declare subscriber for captured");

        let mut payloads = Vec::new();
        let timeout = Duration::from_millis(timeout_ms);

        loop {
            match tokio::time::timeout(timeout, subscriber.recv_async()).await {
                Ok(Ok(sample)) => {
                    payloads.push(sample.payload().to_bytes().to_vec());
                }
                _ => break, // timeout or error
            }
        }

        payloads
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[tokio::test(flavor = "multi_thread", worker_threads = 1)]
    async fn test_pubsub_roundtrip() {
        let peer = TestZenohPeer::new().await;
        let session = peer.session();

        let publisher = session.declare_publisher("bsdos/test")
            .await
            .expect("Failed to declare publisher");

        let subscriber = session.declare_subscriber("bsdos/test")
            .await
            .expect("Failed to declare subscriber");

        publisher.put("hello world").await.expect("Failed to put");

        let sample = tokio::time::timeout(Duration::from_millis(100), subscriber.recv_async())
            .await
            .expect("Timeout waiting for sample")
            .expect("Failed to receive sample");

        assert_eq!(sample.payload().to_bytes().as_ref(), b"hello world");
    }

    #[tokio::test(flavor = "multi_thread", worker_threads = 1)]
    async fn test_no_network_io() {
        let peer = TestZenohPeer::new().await;
        let session = peer.session();

        // This should work without any network I/O
        let publisher = session.declare_publisher("bsdos/no-network")
            .await
            .expect("Failed to declare publisher");

        publisher.put("test").await.expect("Failed to put");

        // If we reach here, no network I/O was required
    }
}
