// START_AI_HEADER
// MODULE: bsdos-pkgd/src/install.rs
// PURPOSE: install subcommand — extract .jpk payload into jail root directory.
// INTENT: Verify manifest hashes, validate descriptor, then unpack payload.tar
//         into <root>/<app_id>/ per SPEC §5.1 install flow.
// DEPENDENCIES: descriptor, error, verify, tar, flate2, serde_json, manifest.
// PUBLIC_API: run_install.
// END_AI_HEADER

use std::collections::HashMap;
use std::fs;
use std::io::Read;
use std::path::Path;

use flate2::read::GzDecoder;

use crate::descriptor::JpkDescriptor;
use crate::error::PkgdError;
use crate::verify::run_verify;

// run_install:start
//   purpose: Install a .jpk package by verifying manifest hashes and extracting
//            payload.tar into <root>/<app_id>/ directory.
//   input:  path: .jpk archive path; root: jail root base directory (e.g. /opt/bsdos/jails).
//   output: Result<(), PkgdError>.
//   sideEffects: creates <root>/<app_id>/ directory, extracts files from payload.tar.
pub fn run_install(path: &Path, root: &Path) -> Result<(), PkgdError> {
    // ── 1. Verify hashes first ────────────────────────────────────────────────
    println!("Verifying {}...", path.display());
    run_verify(path)?;

    // ── 2. Read archive members ───────────────────────────────────────────────
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
        let mut buf = Vec::new();
        entry
            .read_to_end(&mut buf)
            .map_err(|e| PkgdError::Io(format!("read {name}: {e}")))?;
        file_bytes.insert(name, buf);
    }

    // ── 3. Parse descriptor ───────────────────────────────────────────────────
    let toml_bytes = file_bytes
        .get("jpk.toml")
        .ok_or_else(|| PkgdError::Archive("jpk.toml not found in archive".to_string()))?;
    let toml_str = std::str::from_utf8(toml_bytes)
        .map_err(|e| PkgdError::Io(format!("jpk.toml is not valid UTF-8: {e}")))?;
    let descriptor = JpkDescriptor::from_toml_str(toml_str)?;
    descriptor.validate()?;

    let app_id = &descriptor.meta.id;

    // ── 4. Create destination directory ──────────────────────────────────────
    let dest = root.join(app_id);
    fs::create_dir_all(&dest)
        .map_err(|e| PkgdError::Install(format!("create dir {}: {e}", dest.display())))?;

    // ── 5. Unpack payload.tar into dest ──────────────────────────────────────
    let payload_bytes = file_bytes
        .get("payload.tar")
        .ok_or_else(|| PkgdError::Archive("payload.tar not found in archive".to_string()))?;

    let mut payload_archive = tar::Archive::new(payload_bytes.as_slice());
    payload_archive
        .unpack(&dest)
        .map_err(|e| PkgdError::Install(format!("unpack payload into {}: {e}", dest.display())))?;

    println!(
        "Installed {id} v{ver} -> {dest}",
        id = app_id,
        ver = descriptor.meta.version,
        dest = dest.display()
    );
    Ok(())
}
// run_install:end
