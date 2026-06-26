// START_AI_HEADER
// MODULE: bsdos-pkgd/src/build.rs
// PURPOSE: Build subcommand — create a .jpk archive from a source directory.
// INTENT: Read jpk.toml, pack payload/, compute sha256 per-file manifest,
//         assemble tar+gzip archive with all required members per SPEC §2.
// DEPENDENCIES: descriptor, sha2, hex, tar, flate2, walkdir, serde_json, chrono.
// PUBLIC_API: run_build.
// END_AI_HEADER

use std::fs;
use std::io::{self, Write};
use std::path::Path;

use flate2::{write::GzEncoder, Compression};
use sha2::{Digest, Sha256};
use walkdir::WalkDir;

use crate::descriptor::JpkDescriptor;
use crate::error::PkgdError;
use crate::manifest::{FileEntry, ManifestJson};

// run_build:start
//   purpose: Build a .jpk archive from <dir>: validates jpk.toml, packs payload/,
//            computes per-file sha256 manifest, emits tar+gzip .jpk file.
//   input:  dir: source directory path (must contain jpk.toml and payload/).
//           output: path for the resulting .jpk archive.
//   output: Result<(), PkgdError>.
//   sideEffects: reads dir tree, writes .jpk file to output path.
pub fn run_build(dir: &Path, output: &Path) -> Result<(), PkgdError> {
    // ── 1. Load and validate jpk.toml ────────────────────────────────────────
    let toml_path = dir.join("jpk.toml");
    let toml_str = fs::read_to_string(&toml_path).map_err(|e| {
        PkgdError::Io(format!("cannot read {}: {e}", toml_path.display()))
    })?;
    let descriptor = JpkDescriptor::from_toml_str(&toml_str)?;
    descriptor.validate()?;

    let app_id = &descriptor.meta.id;
    let version = &descriptor.meta.version;

    // ── 2. Build payload.tar in memory ───────────────────────────────────────
    let payload_dir = dir.join("payload");
    if !payload_dir.is_dir() {
        return Err(PkgdError::Io(format!(
            "payload directory not found: {}",
            payload_dir.display()
        )));
    }
    let payload_tar_bytes = build_payload_tar(&payload_dir)?;

    // ── 3. Compute sha256 of each file → manifest.json ───────────────────────
    let mut file_entries: Vec<FileEntry> = Vec::new();

    // Hash jpk.toml
    let toml_hash = sha256_bytes(toml_str.as_bytes());
    file_entries.push(FileEntry {
        name: "jpk.toml".to_string(),
        sha256: toml_hash,
    });

    // Hash payload.tar
    let payload_hash = sha256_bytes(&payload_tar_bytes);
    file_entries.push(FileEntry {
        name: "payload.tar".to_string(),
        sha256: payload_hash,
    });

    // Build timestamp
    let build_timestamp = chrono::Utc::now().to_rfc3339();

    // build-info.txt content
    let build_info = format!(
        "build_host=bsdos-pkgd\nfreebsd_version=unknown\nbsdos_codename={}\nbuild_timestamp={}\n",
        descriptor.compatibility.bsdos_codename_min,
        build_timestamp,
    );
    let build_info_hash = sha256_bytes(build_info.as_bytes());
    file_entries.push(FileEntry {
        name: "build-info.txt".to_string(),
        sha256: build_info_hash,
    });

    let manifest_json_obj = ManifestJson {
        files: file_entries,
    };
    let manifest_json_bytes = serde_json::to_vec_pretty(&manifest_json_obj)
        .map_err(|e| PkgdError::Json(e.to_string()))?;

    // Also hash manifest.json itself and add (after serialisation, so self-referential)
    // We include a final manifest with its own hash appended for tools that need it.
    // The manifest hash entry is omitted from the manifest itself (standard practice).

    // jpk.json mirror of jpk.toml
    let jpk_json_bytes = serde_json::to_vec_pretty(&descriptor)
        .map_err(|e| PkgdError::Json(e.to_string()))?;

    // ── 4. Assemble outer tar+gzip .jpk archive ───────────────────────────────
    let output_file = fs::File::create(output)
        .map_err(|e| PkgdError::Io(format!("cannot create {}: {e}", output.display())))?;
    let gz_encoder = GzEncoder::new(output_file, Compression::default());
    let mut outer_tar = tar::Builder::new(gz_encoder);
    outer_tar.follow_symlinks(false);

    // Helper: append in-memory bytes as a tar entry
    append_bytes(&mut outer_tar, "jpk.toml", toml_str.as_bytes())?;
    append_bytes(&mut outer_tar, "jpk.json", &jpk_json_bytes)?;
    append_bytes(&mut outer_tar, "payload.tar", &payload_tar_bytes)?;
    append_bytes(&mut outer_tar, "manifest.json", &manifest_json_bytes)?;
    append_bytes(&mut outer_tar, "build-info.txt", build_info.as_bytes())?;
    // signature.ed25519 and cert.pem are optional (sign subcommand, not built here)

    let gz_encoder = outer_tar
        .into_inner()
        .map_err(|e| PkgdError::Io(format!("tar finish error: {e}")))?;
    gz_encoder
        .finish()
        .map_err(|e| PkgdError::Io(format!("gzip finish error: {e}")))?;

    println!(
        "Built {id} v{ver} -> {out}",
        id = app_id,
        ver = version,
        out = output.display()
    );
    Ok(())
}
// run_build:end

// build_payload_tar:start
//   purpose: Pack the contents of payload_dir into an uncompressed tar archive in memory.
//   input:  payload_dir: directory to pack (all files recursively).
//   output: Result<Vec<u8>, PkgdError> — raw tar bytes.
//   sideEffects: reads files from payload_dir.
fn build_payload_tar(payload_dir: &Path) -> Result<Vec<u8>, PkgdError> {
    let mut tar_bytes: Vec<u8> = Vec::new();
    {
        let mut tar_builder = tar::Builder::new(&mut tar_bytes);
        tar_builder.follow_symlinks(false);

        for entry in WalkDir::new(payload_dir).sort_by_file_name() {
            let entry = entry.map_err(|e| PkgdError::Io(format!("walkdir error: {e}")))?;
            let path = entry.path();

            // Compute relative path from payload_dir
            let rel = path
                .strip_prefix(payload_dir)
                .map_err(|e| PkgdError::Io(format!("strip_prefix error: {e}")))?;

            if rel.as_os_str().is_empty() {
                continue; // skip the root entry itself
            }

            let metadata = fs::metadata(path)
                .map_err(|e| PkgdError::Io(format!("metadata {}: {e}", path.display())))?;

            let mut header = tar::Header::new_gnu();
            header
                .set_metadata(&metadata);
            header.set_path(rel).map_err(|e| {
                PkgdError::Io(format!("tar set_path {}: {e}", rel.display()))
            })?;
            header.set_cksum();

            if metadata.is_dir() {
                tar_builder
                    .append(&header, io::empty())
                    .map_err(|e| PkgdError::Io(format!("tar append dir: {e}")))?;
            } else if metadata.is_file() {
                let file = fs::File::open(path)
                    .map_err(|e| PkgdError::Io(format!("open {}: {e}", path.display())))?;
                tar_builder
                    .append(&header, file)
                    .map_err(|e| PkgdError::Io(format!("tar append file: {e}")))?;
            }
            // symlinks: skipped (follow_symlinks=false, non-file/dir entries omitted)
        }
        tar_builder
            .finish()
            .map_err(|e| PkgdError::Io(format!("tar finish: {e}")))?;
    }
    Ok(tar_bytes)
}
// build_payload_tar:end

// sha256_bytes:start
//   purpose: Compute hex-encoded SHA-256 digest of a byte slice.
//   input:  data: &[u8].
//   output: String — lowercase hex SHA-256.
//   sideEffects: none.
pub fn sha256_bytes(data: &[u8]) -> String {
    let mut hasher = Sha256::new();
    hasher.update(data);
    hex::encode(hasher.finalize())
}
// sha256_bytes:end

// append_bytes:start
//   purpose: Append an in-memory byte slice as a named file entry to a tar archive.
//   input:  tar: mutable Builder, name: archive entry name, data: file bytes.
//   output: Result<(), PkgdError>.
//   sideEffects: writes to tar Builder's underlying writer.
fn append_bytes<W: Write>(
    tar: &mut tar::Builder<W>,
    name: &str,
    data: &[u8],
) -> Result<(), PkgdError> {
    let mut header = tar::Header::new_gnu();
    header.set_size(data.len() as u64);
    header.set_mode(0o644);
    header.set_cksum();
    tar.append_data(&mut header, name, data)
        .map_err(|e| PkgdError::Io(format!("tar append '{name}': {e}")))
}
// append_bytes:end
