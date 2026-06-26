// START_AI_HEADER
// MODULE: bsdos-pkgd/src/inspect.rs
// PURPOSE: inspect subcommand — print jpk.toml metadata and signature status.
// INTENT: Open .jpk tar+gzip, extract jpk.toml, print descriptor fields,
//         report whether signature.ed25519 is present per SPEC §2.
// DEPENDENCIES: descriptor, error, tar, flate2.
// PUBLIC_API: run_inspect.
// END_AI_HEADER

use std::fs;
use std::io::Read;
use std::path::Path;

use flate2::read::GzDecoder;

use crate::descriptor::JpkDescriptor;
use crate::error::PkgdError;

// run_inspect:start
//   purpose: Open file.jpk, extract jpk.toml and print descriptor fields plus
//            whether signature.ed25519 and cert.pem are present.
//   input:  path: path to .jpk archive file.
//   output: Result<(), PkgdError>.
//   sideEffects: reads .jpk file, prints to stdout.
pub fn run_inspect(path: &Path) -> Result<(), PkgdError> {
    let (descriptor, members) = read_jpk_members(path)?;

    let has_signature = members.iter().any(|n| n == "signature.ed25519");
    let has_cert = members.iter().any(|n| n == "cert.pem");
    let has_manifest = members.iter().any(|n| n == "manifest.json");
    let has_payload = members.iter().any(|n| n == "payload.tar");

    println!("=== {path} ===", path = path.display());
    println!("[meta]");
    println!("  schema_version = {}", descriptor.meta.schema_version);
    println!("  id             = {}", descriptor.meta.id);
    println!("  name           = {}", descriptor.meta.name);
    println!("  version        = {}", descriptor.meta.version);
    println!("  description    = {}", descriptor.meta.description);
    println!("  license        = {}", descriptor.meta.license);
    if !descriptor.meta.authors.is_empty() {
        println!("  authors        = {}", descriptor.meta.authors.join(", "));
    }
    println!();
    println!("[compatibility]");
    println!("  bsdos_codename_min = {}", descriptor.compatibility.bsdos_codename_min);
    if !descriptor.compatibility.bsdos_codename_max.is_empty() {
        println!("  bsdos_codename_max = {}", descriptor.compatibility.bsdos_codename_max);
    }
    println!("  freebsd_min    = {}", descriptor.compatibility.freebsd_min);
    println!("  arch           = {}", descriptor.compatibility.arch.join(", "));
    println!();
    println!("[runtime]");
    println!("  type           = {}", descriptor.runtime.runtime_type);
    println!("  entrypoint     = {}", descriptor.runtime.entrypoint);
    println!("  needs_wayland  = {}", descriptor.runtime.needs_wayland);
    println!("  needs_gpu      = {}", descriptor.runtime.needs_gpu);
    println!("  needs_audio    = {}", descriptor.runtime.needs_audio);
    println!();
    println!("[permissions]");
    println!("  network        = {}", descriptor.permissions.network);
    println!("  filesystem     = {}", descriptor.permissions.filesystem);
    if let Some(mem) = descriptor.permissions.max_memory_mb {
        println!("  max_memory_mb  = {mem}");
    }
    if let Some(cpu) = descriptor.permissions.max_cpu_percent {
        println!("  max_cpu_percent = {cpu}");
    }
    println!();
    println!("[archive members]");
    println!("  payload.tar    : {}", present(has_payload));
    println!("  manifest.json  : {}", present(has_manifest));
    println!("  signature.ed25519 : {}", present(has_signature));
    println!("  cert.pem       : {}", present(has_cert));
    println!();
    if has_signature && has_cert {
        println!("[signature] PRESENT (use 'verify' to check hashes)");
    } else {
        println!("[signature] NOT PRESENT (unsigned package)");
    }

    Ok(())
}
// run_inspect:end

// read_jpk_members:start
//   purpose: Open a .jpk tar+gzip, parse jpk.toml, and return descriptor + list of member names.
//   input:  path: path to .jpk archive.
//   output: Result<(JpkDescriptor, Vec<String>), PkgdError>.
//   sideEffects: reads .jpk file.
pub fn read_jpk_members(path: &Path) -> Result<(JpkDescriptor, Vec<String>), PkgdError> {
    let file = fs::File::open(path)
        .map_err(|e| PkgdError::Io(format!("cannot open {}: {e}", path.display())))?;
    let gz = GzDecoder::new(file);
    let mut archive = tar::Archive::new(gz);

    let mut toml_content: Option<String> = None;
    let mut member_names: Vec<String> = Vec::new();

    for entry_result in archive
        .entries()
        .map_err(|e| PkgdError::Archive(format!("tar entries error: {e}")))?
    {
        let mut entry = entry_result
            .map_err(|e| PkgdError::Archive(format!("tar entry error: {e}")))?;

        let entry_path = entry
            .path()
            .map_err(|e| PkgdError::Archive(format!("entry path error: {e}")))?
            .to_string_lossy()
            .to_string();

        member_names.push(entry_path.clone());

        if entry_path == "jpk.toml" {
            let mut content = String::new();
            entry
                .read_to_string(&mut content)
                .map_err(|e| PkgdError::Io(format!("read jpk.toml: {e}")))?;
            toml_content = Some(content);
        }
    }

    let toml_str = toml_content
        .ok_or_else(|| PkgdError::Archive("jpk.toml not found in archive".to_string()))?;
    let descriptor = JpkDescriptor::from_toml_str(&toml_str)?;

    Ok((descriptor, member_names))
}
// read_jpk_members:end

fn present(b: bool) -> &'static str {
    if b { "YES" } else { "NO" }
}
