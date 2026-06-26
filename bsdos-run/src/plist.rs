// START_AI_HEADER
// MODULE: bsdos-run/src/plist.rs
// PURPOSE: Minimal Info.plist reader — extracts bundle metadata + entitlement-like keys, handling
//          both XML and binary ("bplist00") property lists.
// INTENT: Avoid pulling in a full XML parser crate.  Apple property lists in text/XML form
//         follow a predictable pattern: <key>K</key>\n<string>V</string> for scalars and
//         <key>K</key>\n<array>\n<string>V</string>...\n</array> for arrays, plus
//         <true/>/<false/> for booleans.  We scan for the keys we need; anything else is ignored.
//         Real-world IPAs ship Info.plist as a binary plist; we detect the "bplist00" magic and
//         hand the bytes to bplist.rs, otherwise we run the XML text scan.  Both paths converge on
//         a single BundleInfo.
// DEPENDENCIES: std::fs, std::io, error::RunError, bplist::{parse_bplist, BPlistValue, BPLIST_MAGIC}.
// PUBLIC_API: BundleInfo, read_info_plist, read_bundle_executable.
// END_AI_HEADER

use std::path::Path;

use crate::bplist::{parse_bplist, BPlistValue, BPLIST_MAGIC};
use crate::error::RunError;

// is_bplist:start
//   purpose: Detect whether a byte buffer is a binary property list by its magic prefix.
//   input:  bytes — file contents (any length).
//   output: bool — true if it begins with "bplist00".
//   sideEffects: none.
fn is_bplist(bytes: &[u8]) -> bool {
    bytes.len() >= BPLIST_MAGIC.len() && &bytes[..BPLIST_MAGIC.len()] == BPLIST_MAGIC
}
// is_bplist:end

// BundleInfo:start
//   purpose: Extracted metadata from Info.plist needed to launch the application and
//            derive a jail policy.
//   input:  constructed by read_info_plist.
//   output: bundle_identifier / bundle_executable / display name / arm64 flag / min OS /
//           network entitlement flags.
//   sideEffects: none.
#[derive(Debug, Clone, PartialEq)]
pub struct BundleInfo {
    /// CFBundleIdentifier — reverse-DNS app id, e.g. "com.example.app".
    pub bundle_identifier: String,
    /// CFBundleExecutable — the Mach-O binary name inside the .app bundle.
    pub bundle_executable: String,
    /// CFBundleName — short program name (may be empty).
    pub bundle_name: String,
    /// CFBundleDisplayName — user-facing name (may be empty).
    pub display_name: String,
    /// True if UIRequiredDeviceCapabilities declares "arm64".
    pub requires_arm64: bool,
    /// MinimumOSVersion — iOS floor, e.g. "13.0" (may be empty).
    pub minimum_os_version: String,
    /// True if the bundle requests the iOS network-client entitlement
    /// (com.apple.security.network.client) directly in Info.plist (dev/sideload).
    pub network_client: bool,
    /// True if the bundle requests the network-server entitlement
    /// (com.apple.security.network.server).
    pub network_server: bool,
}
// BundleInfo:end

impl BundleInfo {
    // best_name:start
    //   purpose: Pick the most user-friendly available name for display/logging.
    //   input:  &self.
    //   output: &str — display_name, else bundle_name, else bundle_identifier.
    //   sideEffects: none.
    pub fn best_name(&self) -> &str {
        if !self.display_name.is_empty() {
            &self.display_name
        } else if !self.bundle_name.is_empty() {
            &self.bundle_name
        } else {
            &self.bundle_identifier
        }
    }
    // best_name:end
}

// read_info_plist:start
//   purpose: Read Info.plist (XML or binary) and extract bundle metadata + entitlement-like keys.
//   input:  path — filesystem path to Info.plist.
//   output: Result<BundleInfo, RunError>; Err if file unreadable or a binary plist is malformed.
//           Missing keys fall back to safe defaults so the runner can proceed.
//   sideEffects: reads file from disk.
pub fn read_info_plist(path: &Path) -> Result<BundleInfo, RunError> {
    let bytes = std::fs::read(path)
        .map_err(|e| RunError::Plist(format!("cannot read {}: {e}", path.display())))?;

    parse_info_plist_bytes(&bytes)
}
// read_info_plist:end

// parse_info_plist_bytes:start
//   purpose: Dispatch raw Info.plist bytes to the binary or XML parser and return a BundleInfo.
//   input:  bytes — full Info.plist contents.
//   output: Result<BundleInfo, RunError>; Err only when a "bplist00"-tagged buffer fails to decode.
//           XML/text input never errors here — missing keys fall back to defaults.
//   sideEffects: none.
pub fn parse_info_plist_bytes(bytes: &[u8]) -> Result<BundleInfo, RunError> {
    if is_bplist(bytes) {
        let root = parse_bplist(bytes)?;
        return Ok(bundle_info_from_bplist(&root));
    }
    // Fall back to the XML text scan. Decode lossily so a stray non-UTF-8 byte does not abort
    // metadata extraction (the keys we read are ASCII).
    let content = String::from_utf8_lossy(bytes);
    Ok(parse_info_plist(&content))
}
// parse_info_plist_bytes:end

// bundle_info_from_bplist:start
//   purpose: Project a decoded binary-plist root dictionary onto a BundleInfo.
//   input:  root — parsed BPlistValue (expected to be the top-level Dict).
//   output: BundleInfo with the same key set / defaults as the XML path.
//   sideEffects: none.
fn bundle_info_from_bplist(root: &BPlistValue) -> BundleInfo {
    let bundle_identifier = root
        .get_string("CFBundleIdentifier")
        .map(str::to_string)
        .unwrap_or_else(|| "unknown.bundle".to_string());

    let bundle_executable = root
        .get_string("CFBundleExecutable")
        .map(str::to_string)
        .unwrap_or_else(|| "AppBinary".to_string());

    let bundle_name = root
        .get_string("CFBundleName")
        .map(str::to_string)
        .unwrap_or_default();

    let display_name = root
        .get_string("CFBundleDisplayName")
        .map(str::to_string)
        .unwrap_or_default();

    let requires_arm64 = root
        .get_array_strings("UIRequiredDeviceCapabilities")
        .iter()
        .any(|c| c == "arm64");

    let minimum_os_version = root
        .get_string("MinimumOSVersion")
        .map(str::to_string)
        .unwrap_or_default();

    let network_client = root
        .get_bool("com.apple.security.network.client")
        .unwrap_or(false);
    let network_server = root
        .get_bool("com.apple.security.network.server")
        .unwrap_or(false);

    BundleInfo {
        bundle_identifier,
        bundle_executable,
        bundle_name,
        display_name,
        requires_arm64,
        minimum_os_version,
        network_client,
        network_server,
    }
}
// bundle_info_from_bplist:end

// parse_info_plist:start
//   purpose: Pure parser over Info.plist text → BundleInfo (no I/O, testable).
//   input:  content — full Info.plist text.
//   output: BundleInfo with defaults for missing keys.
//   sideEffects: none.
fn parse_info_plist(content: &str) -> BundleInfo {
    let bundle_identifier = extract_string_after_key(content, "CFBundleIdentifier")
        .unwrap_or_else(|| "unknown.bundle".to_string());

    let bundle_executable = extract_string_after_key(content, "CFBundleExecutable")
        .unwrap_or_else(|| "AppBinary".to_string());

    let bundle_name =
        extract_string_after_key(content, "CFBundleName").unwrap_or_default();

    let display_name =
        extract_string_after_key(content, "CFBundleDisplayName").unwrap_or_default();

    let capabilities =
        extract_array_after_key(content, "UIRequiredDeviceCapabilities");
    let requires_arm64 = capabilities.iter().any(|c| c == "arm64");

    let minimum_os_version =
        extract_string_after_key(content, "MinimumOSVersion").unwrap_or_default();

    // iOS entitlement keys may appear directly in a dev/sideloaded Info.plist.
    let network_client =
        extract_bool_after_key(content, "com.apple.security.network.client")
            .unwrap_or(false);
    let network_server =
        extract_bool_after_key(content, "com.apple.security.network.server")
            .unwrap_or(false);

    BundleInfo {
        bundle_identifier,
        bundle_executable,
        bundle_name,
        display_name,
        requires_arm64,
        minimum_os_version,
        network_client,
        network_server,
    }
}
// parse_info_plist:end

// read_bundle_executable:start
//   purpose: Convenience wrapper — return only CFBundleExecutable from Info.plist (XML or binary).
//   input:  path — filesystem path to Info.plist.
//   output: Result<String, String> with the executable name; Err if absent/unreadable/malformed.
//   sideEffects: reads file from disk.
pub fn read_bundle_executable(path: &Path) -> Result<String, String> {
    let bytes = std::fs::read(path).map_err(|e| format!("cannot read plist: {e}"))?;

    if is_bplist(&bytes) {
        let root = parse_bplist(&bytes).map_err(|e| format!("bplist parse: {e}"))?;
        return root
            .get_string("CFBundleExecutable")
            .map(str::to_string)
            .ok_or_else(|| "CFBundleExecutable not found".to_string());
    }

    let content = String::from_utf8_lossy(&bytes);
    extract_string_after_key(&content, "CFBundleExecutable")
        .ok_or_else(|| "CFBundleExecutable not found".to_string())
}
// read_bundle_executable:end

// extract_string_after_key:start
//   purpose: Scan plist text for a <key>K</key> immediately followed (on the next non-blank line)
//            by <string>V</string> and return V.
//   input:  content — full plist file content as a string; key — the plist key name to find.
//   output: Option<String> — Some(value) if found, None otherwise.
//   sideEffects: none (pure text scan).
//   note: pub(crate) so mobileprovision.rs can reuse the XML text-scan on profile plists.
pub(crate) fn extract_string_after_key(content: &str, key: &str) -> Option<String> {
    let key_tag = format!("<key>{key}</key>");
    let string_open = "<string>";
    let string_close = "</string>";

    let mut lines = content.lines().peekable();
    while let Some(line) = lines.next() {
        let trimmed = line.trim();

        if trimmed == key_tag {
            // Consume subsequent lines until we find a <string>…</string>
            for next_line in lines.by_ref() {
                let nxt = next_line.trim();
                if nxt.is_empty() {
                    continue;
                }
                if let Some(rest) = nxt.strip_prefix(string_open) {
                    if let Some(value) = rest.strip_suffix(string_close) {
                        return Some(value.to_string());
                    }
                }
                // If the next non-empty line is not a <string> tag, give up on this key
                break;
            }
        }
    }

    None
}
// extract_string_after_key:end

// extract_array_after_key:start
//   purpose: Scan plist text for a <key>K</key> followed by an <array>…</array> block and
//            return all contained <string>V</string> values.
//   input:  content — full plist text; key — the plist key name to find.
//   output: Vec<String> — element values in order; empty if key absent or array empty.
//   sideEffects: none (pure text scan).
fn extract_array_after_key(content: &str, key: &str) -> Vec<String> {
    let key_tag = format!("<key>{key}</key>");
    let string_open = "<string>";
    let string_close = "</string>";
    let mut out = Vec::new();

    let mut lines = content.lines().peekable();
    while let Some(line) = lines.next() {
        let trimmed = line.trim();
        if !trimmed.contains(&key_tag) {
            continue;
        }
        // Key found on this line. Check if the array is also inline on the same line.
        if let Some(after_key) = trimmed.strip_prefix(&key_tag) {
            let after_key = after_key.trim();
            if after_key.starts_with("<array>") {
                // Key and array are on the same line.
                collect_inline_array_strings(after_key, &mut out);
                if after_key.contains("</array>") {
                    return out;
                }
                // Array continues on subsequent lines.
                for next_line in lines.by_ref() {
                    let nxt = next_line.trim();
                    if nxt.starts_with("</array>") { return out; }
                    if let Some(rest) = nxt.strip_prefix(string_open) {
                        if let Some(value) = rest.strip_suffix(string_close) {
                            out.push(value.to_string());
                        }
                    }
                }
                return out;
            }
        }
        // Key is on its own line; find the opening <array> on a subsequent non-blank line.
        let mut in_array = false;
        for next_line in lines.by_ref() {
            let nxt = next_line.trim();
            if nxt.is_empty() {
                continue;
            }
            if !in_array {
                if nxt.starts_with("<array>") {
                    in_array = true;
                    // Handle a single-line <array><string>x</string></array>.
                    collect_inline_array_strings(nxt, &mut out);
                    if nxt.contains("</array>") {
                        return out;
                    }
                    continue;
                }
                // Key is not followed by an array; nothing to collect.
                break;
            }
            // Inside the array: gather <string> entries until </array>.
            if nxt.starts_with("</array>") {
                return out;
            }
            if let Some(rest) = nxt.strip_prefix(string_open) {
                if let Some(value) = rest.strip_suffix(string_close) {
                    out.push(value.to_string());
                }
            }
        }
        return out;
    }

    out
}
// extract_array_after_key:end

// collect_inline_array_strings:start
//   purpose: Extract every <string>V</string> occurrence inside a single line of plist text.
//   input:  line — one line possibly containing inline <string> elements; out — accumulator.
//   output: none (appends to out).
//   sideEffects: mutates out.
fn collect_inline_array_strings(line: &str, out: &mut Vec<String>) {
    let string_open = "<string>";
    let string_close = "</string>";
    let mut rest = line;
    while let Some(start) = rest.find(string_open) {
        let after = &rest[start + string_open.len()..];
        if let Some(end) = after.find(string_close) {
            out.push(after[..end].to_string());
            rest = &after[end + string_close.len()..];
        } else {
            break;
        }
    }
}
// collect_inline_array_strings:end

// key_is_present:start
//   purpose: Report whether a <key>K</key> tag occurs anywhere in plist text (value type ignored).
//   input:  content — full plist text; key — the plist key name to find.
//   output: bool — true if the key tag is present.
//   sideEffects: none (pure text scan).
//   note: pub(crate) so mobileprovision.rs can detect presence-only entitlements (arrays/dicts).
pub(crate) fn key_is_present(content: &str, key: &str) -> bool {
    let key_tag = format!("<key>{key}</key>");
    content.lines().any(|line| line.trim() == key_tag)
}
// key_is_present:end

// extract_bool_after_key:start
//   purpose: Scan plist text for a <key>K</key> followed by a <true/> or <false/> element.
//   input:  content — full plist text; key — the plist key name to find.
//   output: Option<bool> — Some(true/false) if a boolean element follows the key, None otherwise.
//   sideEffects: none (pure text scan).
//   note: pub(crate) so mobileprovision.rs can reuse the XML text-scan on profile plists.
pub(crate) fn extract_bool_after_key(content: &str, key: &str) -> Option<bool> {
    let key_tag = format!("<key>{key}</key>");

    let mut lines = content.lines().peekable();
    while let Some(line) = lines.next() {
        if line.trim() == key_tag {
            for next_line in lines.by_ref() {
                let nxt = next_line.trim();
                if nxt.is_empty() {
                    continue;
                }
                if nxt.starts_with("<true") {
                    return Some(true);
                }
                if nxt.starts_with("<false") {
                    return Some(false);
                }
                // If the following element is not a boolean, this key is not a boolean.
                break;
            }
        }
    }

    None
}
// extract_bool_after_key:end

#[cfg(test)]
mod tests {
    use super::*;

    const FULL_PLIST: &str = r#"
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>com.example.app</string>
    <key>CFBundleExecutable</key>
    <string>MyApp</string>
    <key>CFBundleName</key>
    <string>MyAppShort</string>
    <key>CFBundleDisplayName</key>
    <string>My Fancy App</string>
    <key>MinimumOSVersion</key>
    <string>13.0</string>
    <key>UIRequiredDeviceCapabilities</key>
    <array>
        <string>arm64</string>
        <string>metal</string>
    </array>
    <key>com.apple.security.network.client</key>
    <true/>
    <key>com.apple.security.network.server</key>
    <false/>
</dict>
</plist>
"#;

    #[test]
    fn test_extract_simple() {
        assert_eq!(
            extract_string_after_key(FULL_PLIST, "CFBundleIdentifier"),
            Some("com.example.app".to_string())
        );
        assert_eq!(
            extract_string_after_key(FULL_PLIST, "CFBundleExecutable"),
            Some("MyApp".to_string())
        );
        assert_eq!(
            extract_string_after_key(FULL_PLIST, "CFBundleVersion"),
            None
        );
    }

    #[test]
    fn test_extract_missing_key() {
        let plist = "<dict><key>Foo</key><string>bar</string></dict>";
        assert_eq!(extract_string_after_key(plist, "CFBundleExecutable"), None);
    }

    #[test]
    fn test_extract_array() {
        let caps = extract_array_after_key(FULL_PLIST, "UIRequiredDeviceCapabilities");
        assert_eq!(caps, vec!["arm64".to_string(), "metal".to_string()]);
        // Absent array key returns empty.
        assert!(extract_array_after_key(FULL_PLIST, "NoSuchArray").is_empty());
    }

    #[test]
    fn test_extract_array_inline() {
        let inline = "<key>K</key><array><string>arm64</string><string>x</string></array>";
        let caps = extract_array_after_key(inline, "K");
        assert_eq!(caps, vec!["arm64".to_string(), "x".to_string()]);
    }

    #[test]
    fn test_extract_bool() {
        assert_eq!(
            extract_bool_after_key(FULL_PLIST, "com.apple.security.network.client"),
            Some(true)
        );
        assert_eq!(
            extract_bool_after_key(FULL_PLIST, "com.apple.security.network.server"),
            Some(false)
        );
        assert_eq!(extract_bool_after_key(FULL_PLIST, "NoSuchBool"), None);
    }

    #[test]
    fn test_parse_full_bundle_info() {
        let info = parse_info_plist(FULL_PLIST);
        assert_eq!(info.bundle_identifier, "com.example.app");
        assert_eq!(info.bundle_executable, "MyApp");
        assert_eq!(info.bundle_name, "MyAppShort");
        assert_eq!(info.display_name, "My Fancy App");
        assert_eq!(info.minimum_os_version, "13.0");
        assert!(info.requires_arm64);
        assert!(info.network_client);
        assert!(!info.network_server);
        assert_eq!(info.best_name(), "My Fancy App");
    }

    #[test]
    fn test_parse_minimal_bundle_info() {
        let plist = r#"
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>org.bsdos.foot</string>
    <key>CFBundleExecutable</key>
    <string>foot</string>
</dict>
</plist>
"#;
        let info = parse_info_plist(plist);
        assert_eq!(info.bundle_identifier, "org.bsdos.foot");
        assert_eq!(info.bundle_executable, "foot");
        assert!(info.bundle_name.is_empty());
        assert!(info.display_name.is_empty());
        assert!(!info.requires_arm64);
        assert!(info.minimum_os_version.is_empty());
        assert!(!info.network_client);
        // best_name falls back to bundle_identifier when names are empty.
        assert_eq!(info.best_name(), "org.bsdos.foot");
    }

    #[test]
    fn test_parse_info_plist_bytes_xml_path() {
        // A plain XML buffer is routed to the text scanner.
        let info = parse_info_plist_bytes(FULL_PLIST.as_bytes()).expect("xml parse");
        assert_eq!(info.bundle_identifier, "com.example.app");
        assert_eq!(info.bundle_executable, "MyApp");
        assert!(info.network_client);
    }

    // build_bplist_dict:start
    //   purpose: Hand-assemble a binary plist whose top dict carries id + executable + an
    //            arm64 capability + a network-client bool, to exercise the bplist dispatch path.
    //   input:  none (fixed keys).
    //   output: Vec<u8> — a complete bplist00 buffer.
    //   sideEffects: none.
    fn build_bplist_dict() -> Vec<u8> {
        // Object indices:
        //   0 dict (4 entries)
        //   1 "CFBundleIdentifier"  2 "com.example.app"
        //   3 "CFBundleExecutable"  4 "MyApp"
        //   5 "UIRequiredDeviceCapabilities"  6 array[7]
        //   7 "arm64"
        //   8 "com.apple.security.network.client"  9 bool true
        fn ascii(s: &str) -> Vec<u8> {
            // Supports the extended-count form for keys longer than 14 bytes.
            let mut v = Vec::new();
            if s.len() < 15 {
                v.push(0x50 | (s.len() as u8));
            } else {
                v.push(0x5F);
                v.push(0x10);
                v.push(s.len() as u8);
            }
            v.extend_from_slice(s.as_bytes());
            v
        }

        let objects: Vec<Vec<u8>> = vec![
            vec![0xD4, 1, 3, 5, 8, 2, 4, 6, 9], // dict: 4 keys (1,3,5,8) then 4 vals (2,4,6,9)
            ascii("CFBundleIdentifier"),
            ascii("com.example.app"),
            ascii("CFBundleExecutable"),
            ascii("MyApp"),
            ascii("UIRequiredDeviceCapabilities"),
            vec![0xA1, 7],         // array of 1 → obj 7
            ascii("arm64"),
            ascii("com.apple.security.network.client"),
            vec![0x09],            // bool true
        ];

        let mut out = Vec::new();
        out.extend_from_slice(BPLIST_MAGIC);
        let mut offsets: Vec<u8> = Vec::new();
        for obj in &objects {
            offsets.push(out.len() as u8);
            out.extend_from_slice(obj);
        }
        let offset_table_offset = out.len() as u64;
        out.extend_from_slice(&offsets);
        let mut trailer = [0u8; 32];
        trailer[6] = 1; // offset_int_size
        trailer[7] = 1; // object_ref_size
        trailer[8..16].copy_from_slice(&(objects.len() as u64).to_be_bytes());
        trailer[16..24].copy_from_slice(&0u64.to_be_bytes());
        trailer[24..32].copy_from_slice(&offset_table_offset.to_be_bytes());
        out.extend_from_slice(&trailer);
        out
    }
    // build_bplist_dict:end

    #[test]
    fn test_parse_info_plist_bytes_binary_path() {
        let data = build_bplist_dict();
        assert!(is_bplist(&data));
        let info = parse_info_plist_bytes(&data).expect("bplist parse");
        assert_eq!(info.bundle_identifier, "com.example.app");
        assert_eq!(info.bundle_executable, "MyApp");
        assert!(info.requires_arm64);
        assert!(info.network_client);
        assert!(!info.network_server);
    }

    #[test]
    fn test_is_bplist_detection() {
        assert!(is_bplist(b"bplist00\x00\x00"));
        assert!(!is_bplist(b"<?xml version"));
        assert!(!is_bplist(b"bp"));
    }
}
