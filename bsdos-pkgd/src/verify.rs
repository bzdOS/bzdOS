// START_AI_HEADER
// MODULE: bsdos-pkgd/src/verify.rs
// PURPOSE: verify subcommand — check manifest.json sha256 hashes in a .jpk archive.
// INTENT: Read all tracked files from archive, recompute sha256, compare against
//         manifest.json entries per SPEC §6 rule 2. Signature check is TODO/stub.
// DEPENDENCIES: error, manifest, sha2, hex, tar, flate2, serde_json.
// PUBLIC_API: run_verify.
// END_AI_HEADER

use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::Path;

use flate2::read::GzDecoder;
use sha2::{Digest, Sha256};

use crate::error::PkgdError;
use crate::manifest::ManifestJson;

// run_verify:start
//   purpose: Verify a .jpk archive: extract all files, recompute sha256,
//            compare against manifest.json. Signature verify is stubbed as TODO.
//   input:  path: path to .jpk archive.
//   output: Result<(), PkgdError> — Ok if all hashes match, Err on first mismatch.
//   sideEffects: reads .jpk file, prints results to stdout.
pub fn run_verify(path: &Path) -> Result<(), PkgdError> {
    // ── Pass 1: extract all file bytes and manifest.json ─────────────────────
    let file = fs::File::open(path)
        .map_err(|e| PkgdError::Io(format!("cannot open {}: {e}", path.display())))?;
    let gz = GzDecoder::new(file);
    let mut archive = tar::Archive::new(gz);

    let mut file_bytes: HashMap<String, Vec<u8>> = HashMap::new();

    for entry_result in archive
        .entries()
        .map_err(|e| PkgdError::Archive(format!("tar entries: {e}")))?
    {
        let mut entry = entry_result
            .map_err(|e| PkgdError::Archive(format!("tar entry: {e}")))?;

        let name = entry
            .path()
            .map_err(|e| PkgdError::Archive(format!("entry path: {e}")))?
            .to_string_lossy()
            .to_string();

        let mut buf: Vec<u8> = Vec::new();
        entry
            .read_to_end(&mut buf)
            .map_err(|e| PkgdError::Io(format!("read {name}: {e}")))?;

        file_bytes.insert(name, buf);
    }

    // ── Locate manifest.json ─────────────────────────────────────────────────
    let manifest_bytes = file_bytes
        .get("manifest.json")
        .ok_or_else(|| PkgdError::Verify("manifest.json not found in archive".to_string()))?;

    let manifest: ManifestJson = serde_json::from_slice(manifest_bytes)
        .map_err(|e| PkgdError::Json(format!("parse manifest.json: {e}")))?;

    // ── Verify each tracked file ─────────────────────────────────────────────
    let mut all_ok = true;
    for entry in &manifest.files {
        match file_bytes.get(&entry.name) {
            None => {
                eprintln!("  MISSING  {}", entry.name);
                all_ok = false;
            }
            Some(data) => {
                let computed = sha256_hex(data);
                if computed == entry.sha256 {
                    println!("  OK       {} ({})", entry.name, &entry.sha256[..12]);
                } else {
                    eprintln!(
                        "  MISMATCH {} expected={} got={}",
                        entry.name,
                        &entry.sha256[..12],
                        &computed[..12]
                    );
                    all_ok = false;
                }
            }
        }
    }

    // ── Signature stub ───────────────────────────────────────────────────────
    if file_bytes.contains_key("signature.ed25519") && file_bytes.contains_key("cert.pem") {
        println!("  SIGN     signature.ed25519 present (Ed25519 verify: TODO)");
    } else {
        println!("  SIGN     unsigned package (no signature.ed25519)");
    }

    if all_ok {
        println!("Verify OK: {}", path.display());
        Ok(())
    } else {
        Err(PkgdError::Verify(format!(
            "one or more hash mismatches in {}",
            path.display()
        )))
    }
}
// run_verify:end

// sha256_hex:start
//   purpose: Compute hex-encoded SHA-256 of a byte slice.
//   input:  data: &[u8].
//   output: String — lowercase hex.
//   sideEffects: none.
fn sha256_hex(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    hex::encode(hasher.finalize())
}
// sha256_hex:end
