// START_AI_HEADER
// MODULE: bsdos-pkgd/src/manifest.rs
// PURPOSE: manifest.json structure for .jpk archives.
// INTENT: Store per-file SHA-256 hashes for integrity verification per SPEC §2.
// DEPENDENCIES: serde, serde_json.
// PUBLIC_API: FileEntry, ManifestJson.
// END_AI_HEADER

use serde::{Deserialize, Serialize};

/// Single file entry in manifest.json.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct FileEntry {
    /// Archive-relative file name, e.g. "jpk.toml", "payload.tar".
    pub name: String,
    /// Lowercase hex-encoded SHA-256 digest of the file bytes.
    pub sha256: String,
}

/// manifest.json root — list of all files with their SHA-256 hashes.
#[derive(Debug, Clone, Serialize, Deserialize, PartialEq)]
pub struct ManifestJson {
    /// All files tracked for integrity (excludes manifest.json itself and signature).
    pub files: Vec<FileEntry>,
}

impl ManifestJson {
    // find:start
    //   purpose: Look up a file entry by name.
    //   input:  name: &str — archive entry name.
    //   output: Option<&FileEntry>.
    //   sideEffects: none.
    #[allow(dead_code)]
    pub fn find(&self, name: &str) -> Option<&FileEntry> {
        self.files.iter().find(|e| e.name == name)
    }
    // find:end
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn find_existing_entry() {
        let m = ManifestJson {
            files: vec![
                FileEntry { name: "jpk.toml".to_string(), sha256: "aabb".to_string() },
                FileEntry { name: "payload.tar".to_string(), sha256: "ccdd".to_string() },
            ],
        };
        let e = m.find("payload.tar").unwrap();
        assert_eq!(e.sha256, "ccdd");
    }

    #[test]
    fn find_missing_entry_returns_none() {
        let m = ManifestJson { files: vec![] };
        assert!(m.find("missing.txt").is_none());
    }

    #[test]
    fn roundtrip_json() {
        let m = ManifestJson {
            files: vec![FileEntry { name: "a".to_string(), sha256: "b".to_string() }],
        };
        let json = serde_json::to_string(&m).unwrap();
        let back: ManifestJson = serde_json::from_str(&json).unwrap();
        assert_eq!(m, back);
    }
}
