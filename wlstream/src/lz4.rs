//! LZ4 compress/decompress wrapper.

use lz4_flex::{compress_prepend_size, decompress_size_prepended};

/// Compress raw bytes with LZ4.
///
/// The output includes a 4-byte little-endian size prefix (uncompressed length).
pub fn compress(input: &[u8]) -> Vec<u8> {
    compress_prepend_size(input)
}

/// Decompress LZ4 data (expects 4-byte LE size prefix).
///
/// Returns `None` on decompression failure.
pub fn decompress(input: &[u8]) -> Option<Vec<u8>> {
    decompress_size_prepended(input).ok()
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn round_trip_compressible() {
        let input = b"AAAAAAAABBBBBBBBCCCCCCCCDDDDDDDD".repeat(100);
        let compressed = compress(&input);
        assert!(compressed.len() < input.len());
        let decompressed = decompress(&compressed).expect("decompress failed");
        assert_eq!(decompressed, input);
    }

    #[test]
    fn round_trip_incompressible() {
        let input: Vec<u8> = (0..1024).map(|i| (i * 7919) as u8).collect();
        let compressed = compress(&input);
        let decompressed = decompress(&compressed).expect("decompress failed");
        assert_eq!(decompressed, input);
    }

    #[test]
    fn round_trip_empty() {
        let compressed = compress(&[]);
        let decompressed = decompress(&compressed).expect("decompress failed");
        assert_eq!(decompressed, Vec::<u8>::new());
    }

    #[test]
    fn decompress_garbage_returns_none() {
        assert!(decompress(&[0xFF, 0xFF, 0xFF, 0xFF]).is_none());
    }
}
