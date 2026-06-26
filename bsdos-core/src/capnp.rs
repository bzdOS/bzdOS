// START_AI_HEADER
// MODULE: capnp.rs
// PURPOSE: hand-rolled Cap'n Proto encoder/decoder for the 32-byte HardwareStatus message.
// INTENT: Avoid the capnp crate's code generation step — the message is a single struct with three primitive fields, so we hard-code the framing, segment header, and struct pointer. Any schema change here is a wire-format break; keep decode's framing check in sync.
// DEPENDENCIES: none (no_std-safe apart from formatting helpers in tests).
// PUBLIC_API: encode(uptime, battery, cpu) -> [u8; 32], decode(&[u8; 32]) -> Result<(u64, u32, u32), &'static str>.
// END_AI_HEADER

// Hand-rolled Cap'n Proto encoder/decoder for HardwareStatus
// Binary layout (32 bytes, little-endian):
//   [0..4]    framing: segment count - 1 = 0 (1 segment)
//   [4..8]    segment 0 size = 3 × 64-bit words
//   [8..16]   struct pointer: dataWords=2, ptrWords=0, offset=0
//   [16..24]  uptime (u64)
//   [24..28]  batteryLevel (u32)
//   [28..32]  cpuUsage (u32)

// encode:start
//   purpose: serialise a HardwareStatus triple into the fixed 32-byte Cap'n Proto wire form.
//   input:  uptime (u64 seconds), battery (u32 percent), cpu (u32 percent).
//   output: 32-byte little-endian buffer; layout documented in the module header.
//   sideEffects: none (pure).
/// Encode HardwareStatus into 32-byte Cap'n Proto message
pub fn encode(uptime: u64, battery: u32, cpu: u32) -> [u8; 32] {
    let mut buf = [0u8; 32];

    // Framing header: segment count - 1 = 0
    buf[0..4].copy_from_slice(&0u32.to_le_bytes());

    // Segment 0 size: 3 × 64-bit words (framing + 2 data words)
    buf[4..8].copy_from_slice(&3u32.to_le_bytes());

    // Struct pointer: dataWords=2 in bits [32..48] of 64-bit little-endian
    // Format: offset (bits 0..30) | ptrWords (bits 30..32) | dataWords (bits 32..48)
    // offset=0, ptrWords=0, dataWords=2 → 0x0000_0002_0000_0000
    buf[8..16].copy_from_slice(&0x0000_0002_0000_0000u64.to_le_bytes());

    // Data section
    buf[16..24].copy_from_slice(&uptime.to_le_bytes());
    buf[24..28].copy_from_slice(&battery.to_le_bytes());
    buf[28..32].copy_from_slice(&cpu.to_le_bytes());

    buf
}
// encode:end

// decode:start
//   purpose: validate framing and extract the (uptime, battery, cpu) triple from a 32-byte Cap'n Proto buffer.
//   input:  buf — exactly 32 bytes, little-endian, in the layout produced by encode.
//   output: Ok((uptime, battery, cpu)) on valid framing; Err("Invalid segment count" | "Invalid segment size") on framing mismatch — never panics on payload shape.
//   sideEffects: none (pure).
/// Decode HardwareStatus from 32-byte Cap'n Proto message
pub fn decode(buf: &[u8; 32]) -> Result<(u64, u32, u32), &'static str> {
    // Validate framing
    let segment_count = u32::from_le_bytes([buf[0], buf[1], buf[2], buf[3]]);
    if segment_count != 0 {
        return Err("Invalid segment count");
    }

    let segment_size = u32::from_le_bytes([buf[4], buf[5], buf[6], buf[7]]);
    if segment_size != 3 {
        return Err("Invalid segment size");
    }

    // Extract data
    let uptime = u64::from_le_bytes([
        buf[16], buf[17], buf[18], buf[19],
        buf[20], buf[21], buf[22], buf[23],
    ]);
    let battery = u32::from_le_bytes([buf[24], buf[25], buf[26], buf[27]]);
    let cpu = u32::from_le_bytes([buf[28], buf[29], buf[30], buf[31]]);

    Ok((uptime, battery, cpu))
}
// decode:end

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_encode_decode() {
        let uptime = 12345u64;
        let battery = 85u32;
        let cpu = 42u32;

        let encoded = encode(uptime, battery, cpu);
        let (decoded_uptime, decoded_battery, decoded_cpu) = decode(&encoded)
            .expect("decode failed");

        assert_eq!(uptime, decoded_uptime);
        assert_eq!(battery, decoded_battery);
        assert_eq!(cpu, decoded_cpu);
    }
}
