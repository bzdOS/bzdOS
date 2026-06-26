// START_AI_HEADER
// MODULE: bsdos-run/src/ipa.rs
// PURPOSE: IPA archive validation, extraction, and binary discovery.
// INTENT: An .ipa is a ZIP archive containing a Payload/<AppName>.app/ directory.
//         This module verifies the file is a zip, extracts it to a temp dir, and
//         locates the main executable at Payload/<AppName>.app/<CFBundleExecutable>.
// DEPENDENCIES: zip, tempfile, std::fs, error::RunError.
// PUBLIC_API: check_ipa, extract_ipa, find_binary.
// END_AI_HEADER

use std::fs::File;
use std::io::Read;
use std::path::{Path, PathBuf};

use tempfile::TempDir;
use zip::ZipArchive;

use crate::error::RunError;

// check_ipa:start
//   purpose: Verify the given path points to an existing file with a valid ZIP local-file header.
//   input:  path — filesystem path to the .ipa file.
//   output: Result<(), RunError>; Err if absent, unreadable, or not a ZIP.
//   sideEffects: opens and reads the first 4 bytes of the file.
pub fn check_ipa(path: &Path) -> Result<(), RunError> {
    if !path.exists() {
        return Err(RunError::Ipa(format!("file not found: {}", path.display())));
    }
    if !path.is_file() {
        return Err(RunError::Ipa(format!("not a regular file: {}", path.display())));
    }

    // ZIP magic: PK\x03\x04 (local file header signature)
    let mut buf = [0u8; 4];
    let mut f = File::open(path)?;
    f.read_exact(&mut buf)
        .map_err(|e| RunError::Ipa(format!("cannot read {}: {e}", path.display())))?;

    if buf != [0x50, 0x4B, 0x03, 0x04] {
        return Err(RunError::Ipa(format!(
            "{} does not appear to be a ZIP/IPA archive (bad magic: {:02x?})",
            path.display(),
            buf
        )));
    }

    Ok(())
}
// check_ipa:end

// extract_ipa:start
//   purpose: Extract all entries from the IPA ZIP archive into a new temporary directory.
//   input:  path — path to the .ipa file.
//   output: Result<TempDir, RunError>; the TempDir owns the extracted tree and deletes it on drop.
//   sideEffects: creates a temporary directory, writes extracted files.
pub fn extract_ipa(path: &Path) -> Result<TempDir, RunError> {
    let tmp = TempDir::new()
        .map_err(|e| RunError::Ipa(format!("cannot create temp dir: {e}")))?;

    let f = File::open(path)?;
    let mut archive = ZipArchive::new(f)?;

    for i in 0..archive.len() {
        let mut entry = archive.by_index(i)?;
        let entry_name = entry.name().to_string();

        // Sanitise entry name: reject absolute paths and path traversal attempts
        if entry_name.contains("..") || entry_name.starts_with('/') {
            return Err(RunError::Ipa(format!(
                "IPA contains unsafe entry name: {entry_name}"
            )));
        }

        let dest = tmp.path().join(&entry_name);

        if entry.is_dir() {
            std::fs::create_dir_all(&dest)?;
        } else {
            // Ensure parent directories exist
            if let Some(parent) = dest.parent() {
                std::fs::create_dir_all(parent)?;
            }

            let mut out = File::create(&dest)?;
            std::io::copy(&mut entry, &mut out)?;

            // Preserve executable bit on Unix (important for the app binary)
            #[cfg(unix)]
            {
                use std::os::unix::fs::PermissionsExt;
                let unix_mode = entry.unix_mode().unwrap_or(0o644);
                let perm = std::fs::Permissions::from_mode(unix_mode);
                std::fs::set_permissions(&dest, perm)?;
            }
        }
    }

    eprintln!(
        "[bsdos-run] extracted {} entries to {}",
        archive.len(),
        tmp.path().display()
    );
    Ok(tmp)
}
// extract_ipa:end

// find_binary:start
//   purpose: Locate the .app bundle directory and its main executable inside the extracted IPA tree.
//   input:  extract_dir — path to the root of the extracted archive.
//   output: Result<(PathBuf, PathBuf), RunError>:
//             .0 — path to the *.app directory (Payload/<AppName>.app)
//             .1 — path to the main executable inside the .app bundle
//   sideEffects: reads directory entries under Payload/.
pub fn find_binary(extract_dir: &Path) -> Result<(PathBuf, PathBuf), RunError> {
    let payload = extract_dir.join("Payload");
    if !payload.is_dir() {
        return Err(RunError::Ipa(format!(
            "Payload/ directory not found inside IPA (extracted to {})",
            extract_dir.display()
        )));
    }

    // Find the first *.app entry
    let app_dir = find_app_dir(&payload)?;

    // Derive the default executable name from the .app directory name
    let default_name = app_dir
        .file_stem()
        .and_then(|s| s.to_str())
        .unwrap_or("AppBinary")
        .to_string();

    // Attempt to read CFBundleExecutable from Info.plist for the true name
    let plist_path = app_dir.join("Info.plist");
    let exec_name = if plist_path.is_file() {
        crate::plist::read_bundle_executable(&plist_path)
            .unwrap_or(default_name)
    } else {
        default_name
    };

    let binary = app_dir.join(&exec_name);
    if !binary.exists() {
        return Err(RunError::Ipa(format!(
            "binary not found at {}: expected CFBundleExecutable={}",
            binary.display(),
            exec_name
        )));
    }

    eprintln!(
        "[bsdos-run] app_dir={} binary={}",
        app_dir.display(),
        binary.display()
    );
    Ok((app_dir, binary))
}
// find_binary:end

// find_app_dir:start
//   purpose: Scan a Payload/ directory and return the first entry whose name ends with `.app`.
//   input:  payload — path to the Payload/ directory.
//   output: Result<PathBuf, RunError>; Err if no .app entry found.
//   sideEffects: reads one level of directory entries.
fn find_app_dir(payload: &Path) -> Result<PathBuf, RunError> {
    let entries = std::fs::read_dir(payload)?;
    for entry_res in entries {
        let entry = entry_res?;
        let path = entry.path();
        if path.is_dir() {
            if let Some(name) = path.file_name().and_then(|n| n.to_str()) {
                if name.ends_with(".app") {
                    return Ok(path);
                }
            }
        }
    }
    Err(RunError::Ipa(format!(
        "no *.app bundle found inside Payload/ ({})",
        payload.display()
    )))
}
// find_app_dir:end
