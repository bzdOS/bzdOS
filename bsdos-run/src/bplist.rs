// START_AI_HEADER
// MODULE: bsdos-run/src/bplist.rs
// PURPOSE: Hand-rolled parser for Apple binary property lists ("bplist00").
// INTENT: Real-world IPA Info.plist files are stored as binary plists, not XML, so the text-scan
//         parser in plist.rs cannot read them.  This module decodes the binary container far
//         enough to extract the scalar string/bool values keyed in a top-level dictionary — the
//         same keys plist.rs needs (CFBundleExecutable, CFBundleIdentifier, …).  No external crate:
//         the format is small and stable, so we decode it directly.  Numeric arrays/reals/dates
//         are parsed structurally but only string/bool getters are exposed because that is all the
//         runner consumes.
// FORMAT: 8-byte magic "bplist00" | object data | offset table | 32-byte trailer.
//         Trailer (big-endian): [6 unused][1 offset_int_size][1 object_ref_size]
//                               [8 num_objects][8 top_object][8 offset_table_offset].
//         Object tag byte high nibble = type, low nibble = length/marker.
// DEPENDENCIES: std::collections::BTreeMap, error::RunError.
// PUBLIC_API: BPlistValue, parse_bplist.
// END_AI_HEADER

use std::collections::BTreeMap;

use crate::error::RunError;

/// 8-byte magic that prefixes every binary plist.
pub const BPLIST_MAGIC: &[u8; 8] = b"bplist00";

// BPlistValue:start
//   purpose: Decoded binary-plist object tree — the subset of CFType values bsdos-run needs.
//   input:  produced by parse_bplist.
//   output: a recursive value (dict/array/string/int/real/bool/data/null) addressable by key.
//   sideEffects: none.
#[derive(Debug, Clone, PartialEq)]
pub enum BPlistValue {
    /// 0x0 marker 0x00 — null.
    Null,
    /// 0x0 marker 0x08/0x09 — boolean.
    Bool(bool),
    /// 0x1 — signed integer (widened to i64).
    Int(i64),
    /// 0x2 — IEEE float/double (widened to f64).
    Real(f64),
    /// 0x4 — raw byte blob.
    Data(Vec<u8>),
    /// 0x5 (ASCII) or 0x6 (UTF-16BE) — Unicode string.
    Str(String),
    /// 0xA — ordered array of child values.
    Array(Vec<BPlistValue>),
    /// 0xD — keyed dictionary; keys are the decoded string form of the key objects.
    Dict(BTreeMap<String, BPlistValue>),
}
// BPlistValue:end

impl BPlistValue {
    // get_string:start
    //   purpose: If self is a Dict, return the string value stored under `key`.
    //   input:  &self; key — dictionary key to look up.
    //   output: Option<&str> — Some(value) when the key maps to a Str, else None.
    //   sideEffects: none.
    pub fn get_string(&self, key: &str) -> Option<&str> {
        match self {
            BPlistValue::Dict(map) => match map.get(key) {
                Some(BPlistValue::Str(s)) => Some(s.as_str()),
                _ => None,
            },
            _ => None,
        }
    }
    // get_string:end

    // get_bool:start
    //   purpose: If self is a Dict, return the boolean value stored under `key`.
    //   input:  &self; key — dictionary key to look up.
    //   output: Option<bool> — Some(value) when the key maps to a Bool, else None.
    //   sideEffects: none.
    pub fn get_bool(&self, key: &str) -> Option<bool> {
        match self {
            BPlistValue::Dict(map) => match map.get(key) {
                Some(BPlistValue::Bool(b)) => Some(*b),
                _ => None,
            },
            _ => None,
        }
    }
    // get_bool:end

    // get_array_strings:start
    //   purpose: If self is a Dict whose `key` maps to an Array, collect that array's string members.
    //   input:  &self; key — dictionary key to look up.
    //   output: Vec<String> — string elements in order; empty if absent or not an array of strings.
    //   sideEffects: none.
    pub fn get_array_strings(&self, key: &str) -> Vec<String> {
        match self {
            BPlistValue::Dict(map) => match map.get(key) {
                Some(BPlistValue::Array(items)) => items
                    .iter()
                    .filter_map(|v| match v {
                        BPlistValue::Str(s) => Some(s.clone()),
                        _ => None,
                    })
                    .collect(),
                _ => Vec::new(),
            },
            _ => Vec::new(),
        }
    }
    // get_array_strings:end
}

// Trailer:start
//   purpose: Decoded 32-byte binary-plist trailer — the geometry needed to walk the object table.
//   input:  built by read_trailer.
//   output: integer sizes, object count, root index, and offset-table location.
//   sideEffects: none.
#[derive(Debug, Clone, Copy)]
struct Trailer {
    offset_int_size: usize,
    object_ref_size: usize,
    num_objects: usize,
    top_object: usize,
    offset_table_offset: usize,
}
// Trailer:end

// parse_bplist:start
//   purpose: Parse a binary property list and return its root object as a BPlistValue tree.
//   input:  bytes — the full file contents (must begin with the "bplist00" magic).
//   output: Result<BPlistValue, RunError>; Err on bad magic, truncation, or malformed structure.
//   sideEffects: none (pure decode); recursion is depth-limited to guard against cyclic refs.
pub fn parse_bplist(bytes: &[u8]) -> Result<BPlistValue, RunError> {
    if bytes.len() < 8 + 32 {
        return Err(RunError::Plist(
            "bplist too short to contain header + trailer".to_string(),
        ));
    }
    if &bytes[..8] != BPLIST_MAGIC {
        return Err(RunError::Plist("not a bplist00 binary plist".to_string()));
    }

    let trailer = read_trailer(bytes)?;

    if trailer.offset_int_size == 0 || trailer.offset_int_size > 8 {
        return Err(RunError::Plist(format!(
            "bplist invalid offset_int_size {}",
            trailer.offset_int_size
        )));
    }
    if trailer.object_ref_size == 0 || trailer.object_ref_size > 8 {
        return Err(RunError::Plist(format!(
            "bplist invalid object_ref_size {}",
            trailer.object_ref_size
        )));
    }
    if trailer.num_objects == 0 {
        return Err(RunError::Plist("bplist has zero objects".to_string()));
    }
    if trailer.top_object >= trailer.num_objects {
        return Err(RunError::Plist(
            "bplist top_object index out of range".to_string(),
        ));
    }

    // The offset table holds num_objects entries of offset_int_size bytes each.
    let table_span = trailer
        .num_objects
        .checked_mul(trailer.offset_int_size)
        .ok_or_else(|| RunError::Plist("bplist offset table size overflow".to_string()))?;
    let table_end = trailer
        .offset_table_offset
        .checked_add(table_span)
        .ok_or_else(|| RunError::Plist("bplist offset table end overflow".to_string()))?;
    if table_end > bytes.len() {
        return Err(RunError::Plist(
            "bplist offset table extends past end of file".to_string(),
        ));
    }

    // Materialise the offset table: object index → byte offset of that object.
    let mut offsets = Vec::with_capacity(trailer.num_objects);
    for i in 0..trailer.num_objects {
        let pos = trailer.offset_table_offset + i * trailer.offset_int_size;
        let off = read_be_uint(&bytes[pos..pos + trailer.offset_int_size]);
        let off = usize::try_from(off)
            .map_err(|_| RunError::Plist("bplist offset exceeds usize".to_string()))?;
        if off >= bytes.len() {
            return Err(RunError::Plist(
                "bplist object offset past end of file".to_string(),
            ));
        }
        offsets.push(off);
    }

    // Recursion budget: any well-formed plist nests far shallower than this; the cap stops
    // a maliciously self-referential offset table from blowing the stack.
    let mut depth_budget: u32 = 256;
    parse_object(bytes, &offsets, &trailer, trailer.top_object, &mut depth_budget)
}
// parse_bplist:end

// read_trailer:start
//   purpose: Decode the final 32 bytes of a binary plist into a Trailer.
//   input:  bytes — full file (length already validated ≥ 40).
//   output: Result<Trailer, RunError>; Err only if a width field cannot be represented as usize.
//   sideEffects: none.
fn read_trailer(bytes: &[u8]) -> Result<Trailer, RunError> {
    let t = &bytes[bytes.len() - 32..];
    // Layout: [0..5] unused, [5] sort_version, [6] offset_int_size, [7] object_ref_size,
    //         [8..16] num_objects, [16..24] top_object, [24..32] offset_table_offset.
    let offset_int_size = t[6] as usize;
    let object_ref_size = t[7] as usize;

    let num_objects = u64_from_be(&t[8..16]);
    let top_object = u64_from_be(&t[16..24]);
    let offset_table_offset = u64_from_be(&t[24..32]);

    let to_usize = |v: u64, what: &str| -> Result<usize, RunError> {
        usize::try_from(v).map_err(|_| RunError::Plist(format!("bplist {what} exceeds usize")))
    };

    Ok(Trailer {
        offset_int_size,
        object_ref_size,
        num_objects: to_usize(num_objects, "num_objects")?,
        top_object: to_usize(top_object, "top_object")?,
        offset_table_offset: to_usize(offset_table_offset, "offset_table_offset")?,
    })
}
// read_trailer:end

// parse_object:start
//   purpose: Decode the object at object-index `idx` into a BPlistValue (recursive for containers).
//   input:  bytes — full file; offsets — object-index → byte-offset table; trailer — geometry;
//           idx — object index to decode; depth — remaining recursion budget (decremented).
//   output: Result<BPlistValue, RunError>; Err on truncation, bad markers, or budget exhaustion.
//   sideEffects: decrements *depth.
fn parse_object(
    bytes: &[u8],
    offsets: &[usize],
    trailer: &Trailer,
    idx: usize,
    depth: &mut u32,
) -> Result<BPlistValue, RunError> {
    if *depth == 0 {
        return Err(RunError::Plist("bplist nesting too deep".to_string()));
    }
    *depth -= 1;

    let start = *offsets
        .get(idx)
        .ok_or_else(|| RunError::Plist("bplist object index out of range".to_string()))?;
    let marker = *bytes
        .get(start)
        .ok_or_else(|| RunError::Plist("bplist object offset past end".to_string()))?;

    let obj_type = marker >> 4;
    let obj_info = (marker & 0x0F) as usize;

    match obj_type {
        // 0x0: singletons — null / bool / fill.
        0x0 => match marker {
            0x00 => Ok(BPlistValue::Null),
            0x08 => Ok(BPlistValue::Bool(false)),
            0x09 => Ok(BPlistValue::Bool(true)),
            // 0x0F is a "fill" byte; treat as null.
            0x0F => Ok(BPlistValue::Null),
            other => Err(RunError::Plist(format!(
                "bplist unknown 0x0 marker {other:#04x}"
            ))),
        },

        // 0x1: integer — 2^obj_info bytes, big-endian.
        0x1 => {
            let n = 1usize << obj_info;
            let data = slice_at(bytes, start + 1, n)?;
            let raw = read_be_uint(data);
            // Per CFBinaryPlist the 8-byte form is signed; smaller forms are unsigned and
            // fit positively in i64.  Either way `raw as i64` reproduces the stored value.
            Ok(BPlistValue::Int(raw as i64))
        }

        // 0x2: real — 4 (f32) or 8 (f64) bytes, big-endian.
        0x2 => {
            let n = 1usize << obj_info;
            let data = slice_at(bytes, start + 1, n)?;
            let val = match n {
                4 => {
                    let mut b = [0u8; 4];
                    b.copy_from_slice(data);
                    f32::from_be_bytes(b) as f64
                }
                8 => {
                    let mut b = [0u8; 8];
                    b.copy_from_slice(data);
                    f64::from_be_bytes(b)
                }
                _ => {
                    return Err(RunError::Plist(format!(
                        "bplist unsupported real width {n}"
                    )))
                }
            };
            Ok(BPlistValue::Real(val))
        }

        // 0x4: data blob.
        0x4 => {
            let (count, data_start) = read_count(bytes, start, obj_info)?;
            let data = slice_at(bytes, data_start, count)?;
            Ok(BPlistValue::Data(data.to_vec()))
        }

        // 0x5: ASCII string — `count` 1-byte chars.
        0x5 => {
            let (count, data_start) = read_count(bytes, start, obj_info)?;
            let data = slice_at(bytes, data_start, count)?;
            // ASCII strings may technically carry Latin-1; from_utf8_lossy keeps us total.
            Ok(BPlistValue::Str(String::from_utf8_lossy(data).into_owned()))
        }

        // 0x6: UTF-16BE string — `count` 16-bit code units.
        0x6 => {
            let (count, data_start) = read_count(bytes, start, obj_info)?;
            let byte_len = count
                .checked_mul(2)
                .ok_or_else(|| RunError::Plist("bplist utf16 length overflow".to_string()))?;
            let data = slice_at(bytes, data_start, byte_len)?;
            Ok(BPlistValue::Str(decode_utf16_be(data)))
        }

        // 0xA: array — `count` object references.
        0xA => {
            let (count, refs_start) = read_count(bytes, start, obj_info)?;
            let mut items = Vec::with_capacity(count);
            for i in 0..count {
                let ref_pos = refs_start + i * trailer.object_ref_size;
                let ref_bytes = slice_at(bytes, ref_pos, trailer.object_ref_size)?;
                let child_idx = read_be_uint(ref_bytes) as usize;
                items.push(parse_object(bytes, offsets, trailer, child_idx, depth)?);
            }
            Ok(BPlistValue::Array(items))
        }

        // 0xD: dictionary — `count` key refs followed by `count` value refs.
        0xD => {
            let (count, keys_start) = read_count(bytes, start, obj_info)?;
            let values_start = keys_start
                .checked_add(count * trailer.object_ref_size)
                .ok_or_else(|| RunError::Plist("bplist dict layout overflow".to_string()))?;

            let mut map = BTreeMap::new();
            for i in 0..count {
                let key_pos = keys_start + i * trailer.object_ref_size;
                let val_pos = values_start + i * trailer.object_ref_size;

                let key_ref = read_be_uint(slice_at(bytes, key_pos, trailer.object_ref_size)?);
                let val_ref = read_be_uint(slice_at(bytes, val_pos, trailer.object_ref_size)?);

                let key_obj =
                    parse_object(bytes, offsets, trailer, key_ref as usize, depth)?;
                let val_obj =
                    parse_object(bytes, offsets, trailer, val_ref as usize, depth)?;

                // Keys in a CF dictionary are strings; ignore non-string keys defensively.
                if let BPlistValue::Str(k) = key_obj {
                    map.insert(k, val_obj);
                }
            }
            Ok(BPlistValue::Dict(map))
        }

        other => Err(RunError::Plist(format!(
            "bplist unsupported object type {other:#x}"
        ))),
    }
}
// parse_object:end

// read_count:start
//   purpose: Decode the element-count of a variable-length object (string/data/array/dict).
//   input:  bytes — full file; start — offset of the object's marker byte;
//           obj_info — low nibble of the marker.
//   output: Result<(usize, usize), RunError>: (element count, byte offset of the first element).
//           When obj_info == 0xF the real count is stored as a following int object.
//   sideEffects: none.
fn read_count(bytes: &[u8], start: usize, obj_info: usize) -> Result<(usize, usize), RunError> {
    if obj_info != 0x0F {
        // Count fits in the low nibble; payload begins at start + 1.
        return Ok((obj_info, start + 1));
    }

    // Extended count: the next byte is an int marker 0x1X with 2^X bytes of big-endian count.
    let int_marker = *bytes
        .get(start + 1)
        .ok_or_else(|| RunError::Plist("bplist truncated extended count marker".to_string()))?;
    if int_marker >> 4 != 0x1 {
        return Err(RunError::Plist(
            "bplist extended count is not an integer".to_string(),
        ));
    }
    let int_pow = (int_marker & 0x0F) as usize;
    let int_len = 1usize << int_pow;
    let count_bytes = slice_at(bytes, start + 2, int_len)?;
    let count = usize::try_from(read_be_uint(count_bytes))
        .map_err(|_| RunError::Plist("bplist extended count exceeds usize".to_string()))?;
    Ok((count, start + 2 + int_len))
}
// read_count:end

// slice_at:start
//   purpose: Bounds-checked subslice helper.
//   input:  bytes — buffer; offset — start index; len — number of bytes.
//   output: Result<&[u8], RunError>; Err if the range exceeds the buffer.
//   sideEffects: none.
fn slice_at(bytes: &[u8], offset: usize, len: usize) -> Result<&[u8], RunError> {
    let end = offset
        .checked_add(len)
        .ok_or_else(|| RunError::Plist("bplist slice length overflow".to_string()))?;
    bytes
        .get(offset..end)
        .ok_or_else(|| RunError::Plist("bplist slice past end of file".to_string()))
}
// slice_at:end

// read_be_uint:start
//   purpose: Read a big-endian unsigned integer of 1..=8 bytes into a u64.
//   input:  data — 1..=8 bytes (callers guarantee width; extra bytes ignored, missing read as 0).
//   output: u64 value.
//   sideEffects: none.
fn read_be_uint(data: &[u8]) -> u64 {
    let mut v: u64 = 0;
    for &b in data.iter().take(8) {
        v = (v << 8) | b as u64;
    }
    v
}
// read_be_uint:end

// u64_from_be:start
//   purpose: Read exactly 8 big-endian bytes into a u64 (used for trailer fields).
//   input:  data — slice of at least 8 bytes (only the first 8 are read).
//   output: u64 value.
//   sideEffects: none.
fn u64_from_be(data: &[u8]) -> u64 {
    read_be_uint(&data[..8.min(data.len())])
}
// u64_from_be:end

// decode_utf16_be:start
//   purpose: Decode a big-endian UTF-16 byte buffer into a String (lossy on bad surrogates).
//   input:  data — UTF-16BE bytes (even length expected; a trailing odd byte is dropped).
//   output: String; replacement chars substituted for unpaired surrogates.
//   sideEffects: none.
fn decode_utf16_be(data: &[u8]) -> String {
    let units: Vec<u16> = data
        .chunks_exact(2)
        .map(|c| u16::from_be_bytes([c[0], c[1]]))
        .collect();
    String::from_utf16_lossy(&units)
}
// decode_utf16_be:end

#[cfg(test)]
mod tests {
    use super::*;

    // ValueSpec:start
    //   purpose: Test-only description of a dictionary value to encode into a synthetic bplist.
    //   input:  authored inline by tests.
    //   output: drives build_bplist's object emission.
    //   sideEffects: none.
    enum ValueSpec {
        Str(&'static str),
        Bool(bool),
        IntU8(u8),
        ArrStr(&'static [&'static str]),
    }
    // ValueSpec:end

    // build_bplist:start
    //   purpose: Assemble a minimal valid bplist00 with a single top-level dict from (key, value)
    //            specs (1-byte offsets/refs; all counts < 15) — drives the parser in tests.
    //   input:  entries — (key string, ValueSpec) pairs to encode.
    //   output: Vec<u8> — a complete, parseable binary plist.
    //   sideEffects: none.
    fn build_bplist(entries: &[(&'static str, ValueSpec)]) -> Vec<u8> {
        // Object table layout:
        //   obj 0 = top dict
        //   then, for each entry: key string object, then value object(s).
        let mut objects: Vec<Vec<u8>> = Vec::new();

        // Reserve index 0 for the dict; fill its body after children are indexed.
        objects.push(Vec::new());

        let mut key_refs: Vec<u8> = Vec::new();
        let mut val_refs: Vec<u8> = Vec::new();

        for (key, spec) in entries {
            // Encode key string object.
            let key_idx = objects.len() as u8;
            objects.push(encode_ascii_string(key));
            key_refs.push(key_idx);

            // Encode value object.
            let val_idx = objects.len() as u8;
            match spec {
                ValueSpec::Str(s) => objects.push(encode_ascii_string(s)),
                ValueSpec::Bool(b) => objects.push(vec![if *b { 0x09 } else { 0x08 }]),
                ValueSpec::IntU8(n) => objects.push(vec![0x10, *n]),
                ValueSpec::ArrStr(items) => {
                    // Array refers to string objects appended after it.
                    let mut arr = Vec::new();
                    let count = items.len();
                    arr.push(0xA0 | (count as u8)); // assume count < 15
                    // Children get the indices following the array object.
                    let first_child = objects.len() as u8 + 1;
                    for k in 0..count as u8 {
                        arr.push(first_child + k);
                    }
                    objects.push(arr);
                    for it in *items {
                        objects.push(encode_ascii_string(it));
                    }
                }
            }
            val_refs.push(val_idx);
        }

        // Build the dict object now that we know all child indices.
        let count = entries.len();
        let mut dict = Vec::new();
        dict.push(0xD0 | (count as u8)); // assume count < 15
        dict.extend_from_slice(&key_refs);
        dict.extend_from_slice(&val_refs);
        objects[0] = dict;

        serialise_objects(&objects)
    }
    // build_bplist:end

    // serialise_objects:start
    //   purpose: Lay out an object vector into a complete bplist (1-byte offsets/refs, top = 0).
    //   input:  objects — pre-encoded object bodies, index 0 is the root.
    //   output: Vec<u8> — header + objects + offset table + 32-byte trailer.
    //   sideEffects: none.
    fn serialise_objects(objects: &[Vec<u8>]) -> Vec<u8> {
        let mut out = Vec::new();
        out.extend_from_slice(BPLIST_MAGIC);

        let mut offsets: Vec<u8> = Vec::with_capacity(objects.len());
        for obj in objects {
            offsets.push(out.len() as u8); // 1-byte offsets fine for tiny test plists
            out.extend_from_slice(obj);
        }

        let offset_table_offset = out.len() as u64;
        out.extend_from_slice(&offsets);

        let mut trailer = [0u8; 32];
        trailer[6] = 1; // offset_int_size
        trailer[7] = 1; // object_ref_size
        trailer[8..16].copy_from_slice(&(objects.len() as u64).to_be_bytes());
        trailer[16..24].copy_from_slice(&0u64.to_be_bytes()); // top_object = 0
        trailer[24..32].copy_from_slice(&offset_table_offset.to_be_bytes());
        out.extend_from_slice(&trailer);

        out
    }
    // serialise_objects:end

    // encode_ascii_string:start
    //   purpose: Encode a short (<15 char) ASCII string as a 0x5 bplist object.
    //   input:  s — string (test inputs are short).
    //   output: Vec<u8> — marker + bytes.
    //   sideEffects: none.
    fn encode_ascii_string(s: &str) -> Vec<u8> {
        assert!(s.len() < 15, "test helper only handles short strings");
        let mut v = Vec::with_capacity(s.len() + 1);
        v.push(0x50 | (s.len() as u8));
        v.extend_from_slice(s.as_bytes());
        v
    }
    // encode_ascii_string:end

    #[test]
    fn test_parse_simple_dict() {
        // Keys and values must be < 15 chars (simple encoder uses 0x5N marker, N ≤ 14).
        let data = build_bplist(&[
            ("BundleId", ValueSpec::Str("com.test.app")),
            ("BundleExe", ValueSpec::Str("MyApp")),
        ]);
        let root = parse_bplist(&data).expect("parse");
        assert_eq!(root.get_string("BundleId"), Some("com.test.app"));
        assert_eq!(root.get_string("BundleExe"), Some("MyApp"));
        assert_eq!(root.get_string("Missing"), None);
    }

    #[test]
    fn test_parse_bool_values() {
        let data = build_bplist(&[
            ("net.client", ValueSpec::Bool(true)),
            ("net.server", ValueSpec::Bool(false)),
        ]);
        let root = parse_bplist(&data).expect("parse");
        assert_eq!(root.get_bool("net.client"), Some(true));
        assert_eq!(root.get_bool("net.server"), Some(false));
        assert_eq!(root.get_bool("absent"), None);
        // A bool is not a string.
        assert_eq!(root.get_string("net.client"), None);
    }

    #[test]
    fn test_parse_int_and_array() {
        let data = build_bplist(&[
            ("count", ValueSpec::IntU8(42)),
            ("caps", ValueSpec::ArrStr(&["arm64", "metal"])),
        ]);
        let root = parse_bplist(&data).expect("parse");
        // Int present but not exposed as string/bool.
        assert_eq!(root.get_string("count"), None);
        assert_eq!(root.get_array_strings("caps"), vec!["arm64", "metal"]);
        assert!(root.get_array_strings("count").is_empty());
        if let BPlistValue::Dict(m) = &root {
            assert_eq!(m.get("count"), Some(&BPlistValue::Int(42)));
        } else {
            panic!("root not a dict");
        }
    }

    #[test]
    fn test_bad_magic_rejected() {
        let mut data = build_bplist(&[("k", ValueSpec::Str("v"))]);
        data[0] = b'X';
        assert!(parse_bplist(&data).is_err());
    }

    #[test]
    fn test_too_short_rejected() {
        assert!(parse_bplist(b"bplist00").is_err());
        assert!(parse_bplist(b"short").is_err());
    }

    #[test]
    fn test_utf16_string_roundtrip() {
        // Dict {key0: utf16-value} built by hand since the ASCII helper cannot emit 0x6 objects.
        let value = "café"; // 'é' exercises the UTF-16 decode path.
        let mut objects: Vec<Vec<u8>> = Vec::new();
        // dict: 1 entry → marker 0xD1, key ref=1, val ref=2
        objects.push(vec![0xD1, 1, 2]);
        objects.push(encode_ascii_string("k"));
        // UTF-16BE encode the value into a 0x6 object.
        let units: Vec<u16> = value.encode_utf16().collect();
        assert!(units.len() < 15);
        let mut sobj = Vec::new();
        sobj.push(0x60 | (units.len() as u8));
        for u in &units {
            sobj.extend_from_slice(&u.to_be_bytes());
        }
        objects.push(sobj);

        let out = serialise_objects(&objects);
        let root = parse_bplist(&out).expect("parse");
        assert_eq!(root.get_string("k"), Some("café"));
    }

    #[test]
    fn test_extended_count_string() {
        // A string of length 20 (>14) forces the extended-count encoding (info nibble 0xF).
        let long: String = "a".repeat(20);

        let mut objects: Vec<Vec<u8>> = Vec::new();
        objects.push(vec![0xD1, 1, 2]); // dict, 1 entry
        objects.push(encode_ascii_string("long"));
        // Extended ASCII string: 0x5F, int marker 0x10, 1-byte count, then bytes.
        let mut sobj = Vec::new();
        sobj.push(0x5F);
        sobj.push(0x10); // int, 2^0 = 1 byte
        sobj.push(long.len() as u8);
        sobj.extend_from_slice(long.as_bytes());
        objects.push(sobj);

        let out = serialise_objects(&objects);
        let root = parse_bplist(&out).expect("parse");
        assert_eq!(root.get_string("long"), Some(long.as_str()));
    }
}
