// START_AI_HEADER
// MODULE: lifecycled/src/zstd_pool.rs
// PURPOSE: Per-stream ZSTD compression pool for Wayland buffer data.
// INTENT: Compress stream frames per app_id before Zenoh publish, reducing
//          bandwidth on the Mac↔device link. Per SPEC_2stream_squirrel.md §10.3
//          (per-stream pool, cleaner accounting). Per SPEC_squirrel_rootfs.md §11.9.
// DEPENDENCIES: zstd, std::sync::{Arc, Mutex}, std::collections::HashMap
// PUBLIC_API: ZstdPool, CompressedFrame
// END_AI_HEADER

// Per-stream ZSTD compression pool.
//
// Each app_id (e.g. "appTerminal", "appBrowser") gets its own compression
// context and statistics. This allows independent tracking per stream type
// (terminal text compresses differently than browser frame data).
//
// Design: per-stream is cleaner accounting (SPEC §10.3 recommendation).
// A shared pool was considered but rejected — mixing terminal + browser
// frames in one ZSTD context degrades compression ratio.
//
// Implementation: stateless zstd::encode_all per frame (v1). Future v2 can
// add per-stream dictionary training (zstd::dict::from_samples).

use std::collections::HashMap;
use std::sync::{Arc, Mutex};

/// ZSTD compression level (3 = fast + good ratio for real-time streams).
const DEFAULT_LEVEL: i32 = 3;

/// A compressed Wayland buffer frame ready for Zenoh publish.
#[derive(Debug, Clone)]
pub struct CompressedFrame {
    pub app_id: String,
    pub original_len: usize,
    pub compressed: Vec<u8>,
    pub compression_ratio: f32,
}

/// Per-app_id compression statistics for monitoring.
#[derive(Debug, Clone, Default)]
pub struct StreamStats {
    pub frames_compressed: u64,
    pub total_original_bytes: u64,
    pub total_compressed_bytes: u64,
}

impl StreamStats {
    pub fn avg_ratio(&self) -> f32 {
        if self.total_compressed_bytes == 0 {
            return 0.0;
        }
        (self.total_original_bytes as f32) / (self.total_compressed_bytes as f32)
    }
}

/// Per-stream ZSTD compression pool.
/// Thread-safe via Mutex.
pub struct ZstdPool {
    level: i32,
    stats: Mutex<HashMap<String, StreamStats>>,
}

impl ZstdPool {
    /// Create a new pool with the given ZSTD compression level.
    pub fn new(level: i32) -> Self {
        Self {
            level,
            stats: Mutex::new(HashMap::new()),
        }
    }

    /// Compress a raw frame buffer for the given app_id.
    /// Updates per-stream statistics. Returns a CompressedFrame.
    pub fn compress(&self, app_id: &str, raw: &[u8]) -> Result<CompressedFrame, String> {
        let compressed = zstd::encode_all(raw, self.level)
            .map_err(|e| format!("zstd encode ({app_id}): {e}"))?;

        let ratio = if raw.is_empty() {
            0.0
        } else {
            (raw.len() as f32) / (compressed.len() as f32)
        };

        // Update stats
        if let Ok(mut map) = self.stats.lock() {
            let s = map.entry(app_id.to_string()).or_default();
            s.frames_compressed += 1;
            s.total_original_bytes += raw.len() as u64;
            s.total_compressed_bytes += compressed.len() as u64;
        }

        Ok(CompressedFrame {
            app_id: app_id.to_string(),
            original_len: raw.len(),
            compressed,
            compression_ratio: ratio,
        })
    }

    /// Decompress a frame back to raw bytes (for local testing / Mac viewer).
    pub fn decompress(compressed: &[u8]) -> Result<Vec<u8>, String> {
        zstd::decode_all(compressed)
            .map_err(|e| format!("zstd decode: {e}"))
    }

    /// Get compression statistics for a specific app_id.
    pub fn stats_for(&self, app_id: &str) -> Option<StreamStats> {
        self.stats.lock().ok()?.get(app_id).cloned()
    }

    /// Get statistics for all streams.
    pub fn all_stats(&self) -> HashMap<String, StreamStats> {
        self.stats.lock().map(|m| m.clone()).unwrap_or_default()
    }

    /// List all app_ids that have been compressed.
    pub fn app_ids(&self) -> Vec<String> {
        self.stats
            .lock()
            .map(|m| m.keys().cloned().collect())
            .unwrap_or_default()
    }

    /// Remove an app_id's stats (when its stream is stopped).
    pub fn remove(&self, app_id: &str) {
        if let Ok(mut m) = self.stats.lock() {
            m.remove(app_id);
        }
    }
}

/// Shared pool type used across the lifecycle daemon.
pub type SharedZstdPool = Arc<ZstdPool>;

/// Create a shared pool with default settings.
pub fn create_shared_pool() -> SharedZstdPool {
    Arc::new(ZstdPool::new(DEFAULT_LEVEL))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_compress_decompress_roundtrip() {
        let pool = ZstdPool::new(3);
        let data = b"Hello, bsdOS! This is a test frame for appTerminal.";
        let frame = pool.compress("appTerminal", data).expect("compress");
        assert_eq!(frame.app_id, "appTerminal");
        assert_eq!(frame.original_len, data.len());

        let decompressed = ZstdPool::decompress(&frame.compressed).expect("decompress");
        assert_eq!(decompressed.as_slice(), data);
    }

    #[test]
    fn test_per_stream_isolation() {
        let pool = ZstdPool::new(3);
        let term_data = b"ls -la\nexit";
        let browser_data = b"<html><body>Browser frame</body></html>";

        let term_frame = pool.compress("appTerminal", term_data).expect("compress term");
        let browser_frame = pool.compress("appBrowser", browser_data).expect("compress browser");

        assert_eq!(term_frame.app_id, "appTerminal");
        assert_eq!(browser_frame.app_id, "appBrowser");

        let term_back = ZstdPool::decompress(&term_frame.compressed).expect("decompress term");
        let browser_back = ZstdPool::decompress(&browser_frame.compressed).expect("decompress browser");

        assert_eq!(term_back.as_slice(), term_data);
        assert_eq!(browser_back.as_slice(), browser_data);
    }

    #[test]
    fn test_empty_frame() {
        let pool = ZstdPool::new(3);
        let frame = pool.compress("test", b"").expect("compress empty");
        assert_eq!(frame.original_len, 0);
        assert_eq!(frame.compression_ratio, 0.0);
    }

    #[test]
    fn test_stats_tracking() {
        let pool = ZstdPool::new(3);
        pool.compress("appTerminal", b"data chunk 1").unwrap();
        pool.compress("appTerminal", b"data chunk 2").unwrap();
        pool.compress("appBrowser", b"<html>").unwrap();

        let term_stats = pool.stats_for("appTerminal").expect("stats");
        assert_eq!(term_stats.frames_compressed, 2);

        let all = pool.all_stats();
        assert_eq!(all.len(), 2);
    }

    #[test]
    fn test_pool_management() {
        let pool = ZstdPool::new(3);
        pool.compress("a", b"data").unwrap();
        pool.compress("b", b"data").unwrap();
        assert_eq!(pool.app_ids().len(), 2);
        pool.remove("a");
        assert_eq!(pool.app_ids().len(), 1);
    }

    #[test]
    fn test_large_frame_roundtrip() {
        // Simulate a realistic Wayland buffer: 1280x720 RGBA = ~3.5 MB
        let pool = ZstdPool::new(3);
        let raw: Vec<u8> = (0..(1280 * 720 * 4))
            .map(|i| (i % 256) as u8)
            .collect();
        let frame = pool.compress("appBrowser", &raw).expect("compress large");

        // Compressed should be smaller for this semi-repetitive data
        assert!(frame.compressed.len() < raw.len(),
            "compressed {} should be < raw {}", frame.compressed.len(), raw.len());
        assert!(frame.compression_ratio > 1.0, "should achieve positive ratio");

        let back = ZstdPool::decompress(&frame.compressed).expect("decompress large");
        assert_eq!(back.len(), raw.len());
        assert_eq!(back, raw);
    }

    #[test]
    fn test_repetitive_data_high_ratio() {
        // Highly repetitive data should compress very well (ratio >> 10)
        let pool = ZstdPool::new(3);
        let raw: Vec<u8> = vec![0xABu8; 100_000]; // 100KB of identical bytes
        let frame = pool.compress("test", &raw).expect("compress repetitive");

        assert!(frame.compression_ratio > 10.0,
            "ratio {:.1} should be > 10 for identical bytes", frame.compression_ratio);
    }

    #[test]
    fn test_decompress_invalid_data_errors() {
        // Invalid ZSTD data should return Err, not panic
        let result = ZstdPool::decompress(b"this is not valid zstd data at all");
        assert!(result.is_err(), "decompressing garbage should fail");
    }

    #[test]
    fn test_concurrent_compress_thread_safety() {
        // Multiple threads compressing into the same shared pool
        let pool = create_shared_pool();
        let pool = Arc::clone(&pool);
        let mut handles = Vec::new();

        for i in 0..4 {
            let p = Arc::clone(&pool);
            let app_id = format!("app{}", i);
            handles.push(std::thread::spawn(move || {
                for _ in 0..10 {
                    let data = format!("frame from {}", app_id);
                    let frame = p.compress(&app_id, data.as_bytes()).expect("compress");
                    assert_eq!(frame.app_id, app_id);
                }
            }));
        }

        for h in handles {
            h.join().expect("thread panicked");
        }

        // 4 apps × 10 frames each = 4 streams, each with 10 frames
        assert_eq!(pool.app_ids().len(), 4);
        for i in 0..4 {
            let stats = pool.stats_for(&format!("app{}", i)).expect("stats");
            assert_eq!(stats.frames_compressed, 10);
        }
    }

    #[test]
    fn test_stats_accumulate_across_frames() {
        let pool = ZstdPool::new(3);
        let data = b"some test data for accumulation check";
        pool.compress("app", data).unwrap();
        pool.compress("app", data).unwrap();
        pool.compress("app", data).unwrap();

        let stats = pool.stats_for("app").expect("stats");
        assert_eq!(stats.frames_compressed, 3);
        assert_eq!(stats.total_original_bytes, (data.len() * 3) as u64);
        assert!(stats.avg_ratio() > 0.0);
    }
}
