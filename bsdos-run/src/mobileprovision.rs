// START_AI_HEADER
// MODULE: bsdos-run/src/mobileprovision.rs
// PURPOSE: Extract iOS entitlements from a Payload/*.app/embedded.mobileprovision profile.
// INTENT: A provisioning profile is a CMS / PKCS#7 SignedData container (DER, sometimes PEM-armored)
//         whose signed content is an XML property list.  That plist carries an <Entitlements> dict
//         with the *authoritative* permission grants (application-identifier, get-task-allow,
//         aps-environment, network entitlements, …) — the real source of truth that the
//         Info.plist only projects for dev/sideloaded builds.
//         Per PLAN-ipa-runtime ("Code signature: игнорировать для dev/sideloaded"), we do NOT
//         validate the CMS signature.  We locate the embedded "<?xml … </plist>" substring inside
//         the DER bytes and reuse the same XML text-scan helpers used for Info.plist.  This avoids
//         a heavyweight ASN.1 / crypto dependency for a dev-only loader.
// DEPENDENCIES: error::RunError, plist (XML text-scan helpers re-exported as pub(crate)).
// PUBLIC_API: Entitlements, parse_mobileprovision, read_mobileprovision.
// END_AI_HEADER

use std::path::Path;

use crate::error::RunError;
use crate::plist;

// Entitlements:start
//   purpose: The subset of an iOS entitlements dictionary that bsdos-run maps to a jail policy.
//   input:  produced by parse_mobileprovision from an embedded.mobileprovision profile.
//   output: app identifier + the permission flags consumed by entitlements::policy_from_entitlements.
//   sideEffects: none.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct Entitlements {
    /// application-identifier — "<TeamID>.<bundle-id>"; empty if absent.
    pub application_identifier: String,
    /// get-task-allow — true for development profiles (debuggable). Informational only.
    pub get_task_allow: bool,
    /// True if any iOS network entitlement is granted (client/server or developer networking).
    pub network: bool,
    /// aps-environment value (e.g. "development"/"production"); empty if push is not requested.
    pub aps_environment: String,
}
// Entitlements:end

impl Entitlements {
    // bundle_id:start
    //   purpose: Derive the reverse-DNS bundle id from application-identifier by stripping the
    //            leading team-id label.
    //   input:  &self.
    //   output: &str — the portion after the first '.', or the whole string if there is no team
    //           prefix; empty when application-identifier is empty.
    //   sideEffects: none.
    pub fn bundle_id(&self) -> &str {
        match self.application_identifier.split_once('.') {
            Some((_team, rest)) => rest,
            None => &self.application_identifier,
        }
    }
    // bundle_id:end
}

/// Network-granting entitlement keys (within the <Entitlements> dict).  Any present-and-true key
/// flips the jail to ip4=inherit.  Booleans use <true/>; the developer networking keys are arrays
/// (e.g. ["wifi", "cellular"]) whose mere presence implies the app needs the network stack.
const NETWORK_BOOL_KEYS: &[&str] = &[
    "com.apple.security.network.client",
    "com.apple.security.network.server",
];
const NETWORK_PRESENCE_KEYS: &[&str] = &[
    "com.apple.developer.networking.wifi-info",
    "com.apple.developer.networking.multipath",
    "com.apple.developer.networking.networkextension",
    "com.apple.developer.networking.vpn.api",
    "com.apple.developer.associated-domains",
];

// read_mobileprovision:start
//   purpose: Read embedded.mobileprovision from disk and extract its entitlements.
//   input:  path — filesystem path to the profile (DER or PEM CMS).
//   output: Result<Entitlements, RunError>; Err if unreadable or no embedded plist is found.
//   sideEffects: reads file from disk.
pub fn read_mobileprovision(path: &Path) -> Result<Entitlements, RunError> {
    let bytes = std::fs::read(path)
        .map_err(|e| RunError::Plist(format!("cannot read {}: {e}", path.display())))?;
    parse_mobileprovision(&bytes)
}
// read_mobileprovision:end

// parse_mobileprovision:start
//   purpose: Locate the XML plist embedded in a CMS profile and extract its <Entitlements> dict.
//   input:  bytes — the full embedded.mobileprovision contents (DER or PEM CMS SignedData).
//   output: Result<Entitlements, RunError>; Err if no "<?xml … </plist>" payload is present.
//           The signature is deliberately NOT validated (dev/sideloaded — see module header).
//   sideEffects: none.
pub fn parse_mobileprovision(bytes: &[u8]) -> Result<Entitlements, RunError> {
    let xml = extract_embedded_plist(bytes)
        .ok_or_else(|| RunError::Plist("no XML plist found inside mobileprovision".to_string()))?;
    Ok(entitlements_from_xml(xml))
}
// parse_mobileprovision:end

// extract_embedded_plist:start
//   purpose: Find the embedded "<?xml … </plist>" substring inside the (possibly binary) CMS bytes.
//   input:  bytes — DER/PEM CMS profile.
//   output: Option<&str> — the plist text slice if both markers are found in order, else None.
//   sideEffects: none.
fn extract_embedded_plist(bytes: &[u8]) -> Option<&str> {
    const XML_OPEN: &[u8] = b"<?xml";
    const PLIST_CLOSE: &[u8] = b"</plist>";

    let start = find_subslice(bytes, XML_OPEN)?;
    // Search for the closing tag after the opening one.
    let close_rel = find_subslice(&bytes[start..], PLIST_CLOSE)?;
    let end = start + close_rel + PLIST_CLOSE.len();

    // The plist body is ASCII/UTF-8 XML even though the surrounding container is binary.
    std::str::from_utf8(&bytes[start..end]).ok()
}
// extract_embedded_plist:end

// find_subslice:start
//   purpose: Return the index of the first occurrence of `needle` within `haystack`.
//   input:  haystack — bytes to search; needle — pattern (non-empty).
//   output: Option<usize> — start index of the match, or None if absent.
//   sideEffects: none.
fn find_subslice(haystack: &[u8], needle: &[u8]) -> Option<usize> {
    if needle.is_empty() || needle.len() > haystack.len() {
        return None;
    }
    haystack
        .windows(needle.len())
        .position(|w| w == needle)
}
// find_subslice:end

// entitlements_from_xml:start
//   purpose: Extract the <Entitlements> dict's relevant keys from the profile's XML plist text.
//   input:  xml — the embedded plist as text.
//   output: Entitlements with defaults for absent keys.
//   sideEffects: none.
fn entitlements_from_xml(xml: &str) -> Entitlements {
    // The provisioning profile's top-level dict contains an "Entitlements" key whose value is a
    // nested <dict>. We isolate that nested dict so a key like "get-task-allow" is read from the
    // entitlements scope rather than any same-named profile-level key.
    let scope = isolate_entitlements_dict(xml).unwrap_or(xml);

    let application_identifier =
        plist::extract_string_after_key(scope, "application-identifier").unwrap_or_default();

    let get_task_allow =
        plist::extract_bool_after_key(scope, "get-task-allow").unwrap_or(false);

    let aps_environment =
        plist::extract_string_after_key(scope, "aps-environment").unwrap_or_default();

    let mut network = false;
    for key in NETWORK_BOOL_KEYS {
        if plist::extract_bool_after_key(scope, key).unwrap_or(false) {
            network = true;
        }
    }
    if !network {
        for key in NETWORK_PRESENCE_KEYS {
            if plist::key_is_present(scope, key) {
                network = true;
                break;
            }
        }
    }

    Entitlements {
        application_identifier,
        get_task_allow,
        network,
        aps_environment,
    }
}
// entitlements_from_xml:end

// isolate_entitlements_dict:start
//   purpose: Return the text of the nested <dict> that is the value of the "Entitlements" key.
//   input:  xml — full profile plist text.
//   output: Option<&str> — slice spanning the entitlements <dict>…</dict>, or None if the key /
//           opening tag is not found.  Nested dicts are balanced so the correct </dict> is chosen.
//   sideEffects: none.
fn isolate_entitlements_dict(xml: &str) -> Option<&str> {
    let key_pos = xml.find("<key>Entitlements</key>")?;
    let after_key = &xml[key_pos..];
    let dict_rel = after_key.find("<dict>")?;
    let dict_start = key_pos + dict_rel;
    let body_start = dict_start + "<dict>".len();

    // Walk forward balancing <dict>/</dict> so a nested dict does not terminate the scope early.
    let mut depth = 1usize;
    let mut idx = body_start;
    let bytes = xml.as_bytes();
    while idx < xml.len() {
        if xml[idx..].starts_with("<dict>") {
            depth += 1;
            idx += "<dict>".len();
        } else if xml[idx..].starts_with("</dict>") {
            depth -= 1;
            if depth == 0 {
                let end = idx + "</dict>".len();
                return Some(&xml[dict_start..end]);
            }
            idx += "</dict>".len();
        } else {
            // Advance by one UTF-8 char boundary.
            idx += utf8_char_len(bytes[idx]);
        }
    }
    None
}
// isolate_entitlements_dict:end

// utf8_char_len:start
//   purpose: Byte length of the UTF-8 sequence starting with the given lead byte.
//   input:  b — a UTF-8 lead byte.
//   output: usize — 1..=4 byte step (1 for ASCII / continuation, used to keep slicing on boundaries).
//   sideEffects: none.
fn utf8_char_len(b: u8) -> usize {
    if b >= 0xF0 {
        4
    } else if b >= 0xE0 {
        3
    } else if b >= 0xC0 {
        2
    } else {
        1
    }
}
// utf8_char_len:end

#[cfg(test)]
mod tests {
    use super::*;

    const PROFILE_XML: &str = r#"<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>AppIDName</key>
    <string>My App</string>
    <key>get-task-allow</key>
    <false/>
    <key>Entitlements</key>
    <dict>
        <key>application-identifier</key>
        <string>ABCDE12345.com.example.app</string>
        <key>get-task-allow</key>
        <true/>
        <key>aps-environment</key>
        <string>development</string>
        <key>com.apple.security.network.client</key>
        <true/>
    </dict>
    <key>TeamName</key>
    <string>Example Inc</string>
</dict>
</plist>
"#;

    // wrap_in_der:start
    //   purpose: Embed a plist string inside fake binary CMS-ish framing to exercise the scan.
    //   input:  xml — the plist text.
    //   output: Vec<u8> — binary prefix/suffix around the XML bytes.
    //   sideEffects: none.
    fn wrap_in_der(xml: &str) -> Vec<u8> {
        let mut v = Vec::new();
        // Fake DER SignedData header bytes (non-UTF-8 to prove the scanner tolerates binary).
        v.extend_from_slice(&[0x30, 0x82, 0x12, 0x34, 0x06, 0x09, 0x2A, 0x86, 0x48, 0xFF, 0x00]);
        v.extend_from_slice(xml.as_bytes());
        // Trailing signature blob.
        v.extend_from_slice(&[0x00, 0xDE, 0xAD, 0xBE, 0xEF]);
        v
    }
    // wrap_in_der:end

    #[test]
    fn test_extract_embedded_plist() {
        let der = wrap_in_der(PROFILE_XML);
        let xml = extract_embedded_plist(&der).expect("found plist");
        assert!(xml.starts_with("<?xml"));
        assert!(xml.trim_end().ends_with("</plist>"));
    }

    #[test]
    fn test_parse_mobileprovision_full() {
        let der = wrap_in_der(PROFILE_XML);
        let ent = parse_mobileprovision(&der).expect("parse");
        assert_eq!(ent.application_identifier, "ABCDE12345.com.example.app");
        assert_eq!(ent.bundle_id(), "com.example.app");
        assert!(ent.get_task_allow); // read from the Entitlements scope, not the profile-level false
        assert_eq!(ent.aps_environment, "development");
        assert!(ent.network);
    }

    #[test]
    fn test_no_network_entitlement() {
        let xml = r#"<?xml version="1.0"?>
<plist version="1.0">
<dict>
    <key>Entitlements</key>
    <dict>
        <key>application-identifier</key>
        <string>TEAM.com.example.noweb</string>
        <key>get-task-allow</key>
        <false/>
    </dict>
</dict>
</plist>
"#;
        let ent = parse_mobileprovision(xml.as_bytes()).expect("parse");
        assert!(!ent.network);
        assert!(!ent.get_task_allow);
        assert_eq!(ent.aps_environment, "");
        assert_eq!(ent.bundle_id(), "com.example.noweb");
    }

    #[test]
    fn test_developer_networking_presence_grants_network() {
        let xml = r#"<?xml version="1.0"?>
<plist version="1.0">
<dict>
    <key>Entitlements</key>
    <dict>
        <key>application-identifier</key>
        <string>TEAM.com.example.net</string>
        <key>com.apple.developer.networking.networkextension</key>
        <array>
            <string>packet-tunnel-provider</string>
        </array>
    </dict>
</dict>
</plist>
"#;
        let ent = parse_mobileprovision(xml.as_bytes()).expect("parse");
        assert!(ent.network);
    }

    #[test]
    fn test_missing_plist_errors() {
        let garbage = vec![0x30u8, 0x82, 0x00, 0x01, 0xFF, 0xAB];
        assert!(parse_mobileprovision(&garbage).is_err());
    }

    #[test]
    fn test_isolate_entitlements_handles_nested_dict() {
        let xml = r#"<?xml version="1.0" encoding="UTF-8"?>
<plist><dict>
    <key>Entitlements</key>
    <dict>
        <key>com.apple.developer.icloud-container-environment</key>
        <dict>
            <key>nested</key>
            <string>x</string>
        </dict>
        <key>application-identifier</key>
        <string>TEAM.com.nested.app</string>
    </dict>
</dict></plist>"#;
        let ent = parse_mobileprovision(xml.as_bytes()).expect("parse");
        // The nested dict must not truncate the scope before application-identifier.
        assert_eq!(ent.application_identifier, "TEAM.com.nested.app");
    }
}
