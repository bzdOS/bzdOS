// START_AI_HEADER
// MODULE: bsdos-run/src/mldr.rs
// PURPOSE: Locate the mldr binary and exec it with the IPA application binary as its argument.
// INTENT: mldr is the Mach-O loader from the bsdOS IPA runtime stack (hal/darling-freebsd, Linux
//         layer removed).  We search for it in three well-known locations and then call execv(2)
//         to replace the current process.  The temporary IPA extraction directory is passed in
//         so that the borrow keeps it alive until after exec — on success exec does not return;
//         on failure we return Err so the caller can clean up.
// DEPENDENCIES: libc (execv), std::ffi::CString, tempfile::TempDir, error::RunError.
// PUBLIC_API: find_mldr, exec_mldr.
// END_AI_HEADER

use std::ffi::CString;
use std::path::{Path, PathBuf};

use tempfile::TempDir;

use crate::error::RunError;

/// Candidate locations for the mldr binary, searched in order.
const MLDR_CANDIDATES: &[&str] = &[
    "/usr/local/bin/mldr",
    "/mnt/bsdos/artefacts/myvm-bin/mldr",
];

// find_mldr:start
//   purpose: Search well-known paths for an executable mldr binary.
//            Falls back to checking `mldr` on the PATH via `which`.
//   input:  none.
//   output: Result<PathBuf, RunError>; Err if not found in any location.
//   sideEffects: stat calls on candidate paths; optionally forks `which`.
pub fn find_mldr() -> Result<PathBuf, RunError> {
    for candidate in MLDR_CANDIDATES {
        let p = Path::new(candidate);
        if p.exists() && p.is_file() {
            eprintln!("[bsdos-run] mldr found at {candidate}");
            return Ok(p.to_path_buf());
        }
    }

    // Last resort: look for `mldr` next to this executable
    if let Ok(exe) = std::env::current_exe() {
        if let Some(dir) = exe.parent() {
            let sibling = dir.join("mldr");
            if sibling.exists() {
                eprintln!("[bsdos-run] mldr found at {}", sibling.display());
                return Ok(sibling);
            }
        }
    }

    Err(RunError::Mldr(format!(
        "mldr not found; searched: {}; install mldr to /usr/local/bin/mldr or \
         /mnt/bsdos/artefacts/myvm-bin/mldr",
        MLDR_CANDIDATES.join(", ")
    )))
}
// find_mldr:end

// exec_mldr:start
//   purpose: Replace the current process with `mldr <binary> [app_args...]` via execv(2).
//   input:  mldr_path — path to the mldr binary;
//           binary_path — path to the Mach-O application binary (first arg to mldr);
//           app_args — additional arguments forwarded after the binary path;
//           _tmp — TempDir kept alive until exec (extracted IPA tree must exist during exec).
//   output: Result<(), RunError>; on success execv does not return (process is replaced).
//           Returns Err only if execv itself fails (e.g. mldr not executable on FreeBSD).
//   sideEffects: calls libc::execv — replaces the current process image on success.
pub fn exec_mldr(
    mldr_path: &Path,
    binary_path: &Path,
    app_args: &[String],
    _tmp: &TempDir,
) -> Result<(), RunError> {
    // Build argv: [mldr_path, binary_path, app_args...]
    let mut argv_cstrings: Vec<CString> = Vec::with_capacity(2 + app_args.len());

    argv_cstrings.push(
        CString::new(mldr_path.to_string_lossy().as_ref())
            .map_err(|e| RunError::Mldr(format!("mldr path contains nul byte: {e}")))?,
    );
    argv_cstrings.push(
        CString::new(binary_path.to_string_lossy().as_ref())
            .map_err(|e| RunError::Mldr(format!("binary path contains nul byte: {e}")))?,
    );
    for arg in app_args {
        argv_cstrings.push(
            CString::new(arg.as_str())
                .map_err(|e| RunError::Mldr(format!("app arg contains nul byte: {e}")))?,
        );
    }

    // Build null-terminated argv pointer array
    let mut argv_ptrs: Vec<*const libc::c_char> = argv_cstrings
        .iter()
        .map(|cs| cs.as_ptr())
        .collect();
    argv_ptrs.push(std::ptr::null());

    let mldr_cstr = CString::new(mldr_path.to_string_lossy().as_ref())
        .map_err(|e| RunError::Mldr(format!("mldr path nul: {e}")))?;

    eprintln!(
        "[bsdos-run] exec: {} {}",
        mldr_path.display(),
        binary_path.display()
    );

    // Safety: argv_ptrs is a null-terminated array of valid C strings derived from
    // argv_cstrings which remain alive for the duration of this call.  execv replaces
    // the process image; on failure it returns -1 and errno is set.
    let ret = unsafe { libc::execv(mldr_cstr.as_ptr(), argv_ptrs.as_ptr()) };

    // execv only returns on failure
    if ret == -1 {
        let errno = std::io::Error::last_os_error();
        return Err(RunError::Mldr(format!(
            "execv({}) failed: {errno}",
            mldr_path.display()
        )));
    }

    // Unreachable on success, but needed for type-correctness
    Ok(())
}
// exec_mldr:end
