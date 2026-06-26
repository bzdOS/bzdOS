// START_AI_HEADER
// MODULE: bsdos-run/src/launch.rs
// PURPOSE: Build the dyld/mldr environment for a *self-contained* IPA and exec mldr so a
//          binary resolves its dylibs out of its own embedded Frameworks/ directory.
// INTENT: The ARM64-Mach-O SDK blocker (no ARM64 libobjc/libSystem in the external SDK)
//         does NOT apply when the IPA vendors its frameworks inside itself — those images
//         are already ARM64 Mach-O.  For such IPAs we point dyld at the .app bundle as its
//         root and at <app>/Frameworks for framework/dylib search, then exec mldr <binary>.
//         dyld resolves the binary's @rpath/@executable_path install-names there.
// DEPENDENCIES: libc (execve), std, error::RunError, frameworks::EmbeddedFramework.
// PUBLIC_API: DyldEnv, build_dyld_env, exec_self_contained.
// END_AI_HEADER

use std::ffi::CString;
use std::path::Path;

use crate::error::RunError;
use crate::frameworks::EmbeddedFramework;

/// The dyld/mldr environment variables computed for a self-contained launch.
/// Kept as an ordered list of (KEY, VALUE) so we can both print it (dry-run) and
/// apply it to the exec'd process deterministically.
#[derive(Debug, Clone, PartialEq, Eq, Default)]
pub struct DyldEnv {
    /// Ordered (key, value) pairs to set in the child environment.
    pub vars: Vec<(String, String)>,
}

impl DyldEnv {
    /// purpose: look up a value by key (for tests / introspection).
    /// input:   key. output: Some(value) or None. sideEffects: none.
    pub fn get(&self, key: &str) -> Option<&str> {
        self.vars
            .iter()
            .find(|(k, _)| k == key)
            .map(|(_, v)| v.as_str())
    }
}

// build_dyld_env:start
//   purpose: Compute the DYLD/mldr environment for launching a self-contained IPA.
//   input:   app_dir — the extracted Payload/<App>.app directory (becomes the dyld root
//            when the IPA ships its own frameworks);
//            embedded — discovered embedded frameworks (used only to decide whether a
//            Frameworks/ search path is worth adding).
//   output:  DyldEnv with the ordered variable list.
//   sideEffects: stats <app>/Frameworks to decide whether to add search paths.
//
// Variables set:
//   __mldr_DYLD_ROOT_PATH / DYLD_ROOT_PATH
//       The bundle dir.  dyld prepends this to absolute install-names; for a
//       self-contained IPA every needed image is reachable relative to the bundle.
//   DYLD_FRAMEWORK_PATH / DYLD_LIBRARY_PATH
//       <app>/Frameworks — where the vendored *.framework and *.dylib live.  This is
//       what @rpath typically points at for app frameworks.
//   DYLD_FALLBACK_FRAMEWORK_PATH / DYLD_FALLBACK_LIBRARY_PATH
//       Same dir as a last-resort search list.
pub fn build_dyld_env(app_dir: &Path, embedded: &[EmbeddedFramework]) -> DyldEnv {
    let app = app_dir.to_string_lossy().into_owned();
    let frameworks = app_dir.join("Frameworks");
    let frameworks_str = frameworks.to_string_lossy().into_owned();

    let mut vars: Vec<(String, String)> = Vec::new();

    // dyld root: the bundle itself.  mldr consumes __mldr_DYLD_ROOT_PATH and strips the
    // prefix before handoff; we also set the bare DYLD_ROOT_PATH for dyld builds that
    // read it directly (see ipa-runtime/vchroot/dyld-paths.env for the rationale).
    vars.push(("__mldr_DYLD_ROOT_PATH".to_string(), app.clone()));
    vars.push(("DYLD_ROOT_PATH".to_string(), app));

    // Only add the Frameworks search paths when the IPA actually ships frameworks there;
    // otherwise dyld would search a nonexistent directory.
    if !embedded.is_empty() || frameworks.is_dir() {
        vars.push(("DYLD_FRAMEWORK_PATH".to_string(), frameworks_str.clone()));
        vars.push(("DYLD_LIBRARY_PATH".to_string(), frameworks_str.clone()));
        vars.push((
            "DYLD_FALLBACK_FRAMEWORK_PATH".to_string(),
            frameworks_str.clone(),
        ));
        vars.push(("DYLD_FALLBACK_LIBRARY_PATH".to_string(), frameworks_str));
    }

    DyldEnv { vars }
}
// build_dyld_env:end

// exec_self_contained:start
//   purpose: Replace the current process with `mldr <main_binary> [app_args...]`, with the
//            self-contained DYLD environment applied, via execve(2).
//   input:   mldr_path — path to the mldr binary;
//            main_binary — the app's main Mach-O executable;
//            app_args — extra args forwarded after the binary path;
//            dyld_env — environment computed by build_dyld_env (merged over the inherited
//            environment: existing vars are kept, the DYLD_* keys overridden).
//   output:  Result<(), RunError>; on success execve does not return.  Returns Err only if
//            building the C strings or execve itself fails.
//   sideEffects: calls libc::execve — replaces the current process image on success.
pub fn exec_self_contained(
    mldr_path: &Path,
    main_binary: &Path,
    app_args: &[String],
    dyld_env: &DyldEnv,
) -> Result<(), RunError> {
    // ---- argv: [mldr, main_binary, app_args...] ----
    let mut argv_cstrings: Vec<CString> = Vec::with_capacity(2 + app_args.len());
    argv_cstrings.push(cstr(&mldr_path.to_string_lossy(), "mldr path")?);
    argv_cstrings.push(cstr(&main_binary.to_string_lossy(), "binary path")?);
    for arg in app_args {
        argv_cstrings.push(cstr(arg, "app arg")?);
    }
    let mut argv_ptrs: Vec<*const libc::c_char> =
        argv_cstrings.iter().map(|cs| cs.as_ptr()).collect();
    argv_ptrs.push(std::ptr::null());

    // ---- envp: inherited environment with DYLD_* keys overridden ----
    let merged = merge_env(dyld_env);
    let env_cstrings: Vec<CString> = merged
        .iter()
        .map(|kv| cstr(kv, "env entry"))
        .collect::<Result<Vec<_>, _>>()?;
    let mut env_ptrs: Vec<*const libc::c_char> =
        env_cstrings.iter().map(|cs| cs.as_ptr()).collect();
    env_ptrs.push(std::ptr::null());

    let mldr_cstr = cstr(&mldr_path.to_string_lossy(), "mldr path")?;

    eprintln!(
        "[bsdos-run] exec (self-contained): {} {}",
        mldr_path.display(),
        main_binary.display()
    );
    for (k, v) in &dyld_env.vars {
        eprintln!("[bsdos-run]   {k}={v}");
    }

    // Safety: argv_ptrs and env_ptrs are NUL-terminated arrays of valid C string
    // pointers; their backing CStrings (argv_cstrings / env_cstrings / mldr_cstr) stay
    // alive for the duration of this call.  execve replaces the process image; on
    // failure it returns -1 with errno set.  This is the project's sole allowed unsafe
    // (the execve FFI), matching mldr.rs's execv usage.
    let ret = unsafe { libc::execve(mldr_cstr.as_ptr(), argv_ptrs.as_ptr(), env_ptrs.as_ptr()) };

    if ret == -1 {
        let errno = std::io::Error::last_os_error();
        return Err(RunError::Mldr(format!(
            "execve({}) failed: {errno}",
            mldr_path.display()
        )));
    }
    // Unreachable on success; kept for type-correctness.
    Ok(())
}
// exec_self_contained:end

// merge_env:start
//   purpose: Produce the child environment as "KEY=VALUE" entries: the inherited env with
//            every key from dyld_env replaced (or added).
//   input:   dyld_env — the DYLD overrides.
//   output:  Vec<String> of "KEY=VALUE" entries.
//   sideEffects: reads std::env::vars().
fn merge_env(dyld_env: &DyldEnv) -> Vec<String> {
    let overrides: std::collections::BTreeSet<&str> =
        dyld_env.vars.iter().map(|(k, _)| k.as_str()).collect();

    let mut out: Vec<String> = Vec::new();
    for (k, v) in std::env::vars() {
        if overrides.contains(k.as_str()) {
            continue; // replaced below
        }
        out.push(format!("{k}={v}"));
    }
    for (k, v) in &dyld_env.vars {
        out.push(format!("{k}={v}"));
    }
    out
}
// merge_env:end

// cstr:start
//   purpose: Convert a &str into a CString, mapping interior-NUL errors to RunError.
//   input:   s — the string; what — a label for the error message.
//   output:  Result<CString, RunError>.
//   sideEffects: none.
fn cstr(s: &str, what: &str) -> Result<CString, RunError> {
    CString::new(s).map_err(|e| RunError::Mldr(format!("{what} contains nul byte: {e}")))
}
// cstr:end

// ===========================================================================
// Tests — verify the computed DYLD environment for self-contained launches.
// execve itself is not exercised (it would replace the test process).
// ===========================================================================
#[cfg(test)]
mod tests {
    use super::*;
    use std::path::PathBuf;

    fn one_fw() -> Vec<EmbeddedFramework> {
        vec![EmbeddedFramework {
            name: "Foo".to_string(),
            binary: PathBuf::from("/tmp/x/Payload/Demo.app/Frameworks/Foo.framework/Foo"),
            is_framework: true,
        }]
    }

    #[test]
    fn dyld_env_points_at_bundle_and_frameworks() {
        let app = Path::new("/tmp/x/Payload/Demo.app");
        let env = build_dyld_env(app, &one_fw());

        assert_eq!(
            env.get("__mldr_DYLD_ROOT_PATH"),
            Some("/tmp/x/Payload/Demo.app")
        );
        assert_eq!(env.get("DYLD_ROOT_PATH"), Some("/tmp/x/Payload/Demo.app"));
        assert_eq!(
            env.get("DYLD_FRAMEWORK_PATH"),
            Some("/tmp/x/Payload/Demo.app/Frameworks")
        );
        assert_eq!(
            env.get("DYLD_LIBRARY_PATH"),
            Some("/tmp/x/Payload/Demo.app/Frameworks")
        );
        assert_eq!(
            env.get("DYLD_FALLBACK_FRAMEWORK_PATH"),
            Some("/tmp/x/Payload/Demo.app/Frameworks")
        );
    }

    #[test]
    fn no_frameworks_omits_search_paths() {
        // No embedded frameworks and no Frameworks/ dir on disk -> only the root vars.
        let app = Path::new("/definitely/not/on/disk/Bare.app");
        let env = build_dyld_env(app, &[]);
        assert!(env.get("__mldr_DYLD_ROOT_PATH").is_some());
        assert!(env.get("DYLD_FRAMEWORK_PATH").is_none());
        assert!(env.get("DYLD_LIBRARY_PATH").is_none());
    }

    #[test]
    fn merge_env_overrides_existing_key() {
        // SAFETY: setting an env var in a single-threaded test is fine.
        std::env::set_var("DYLD_ROOT_PATH", "/old");
        let env = DyldEnv {
            vars: vec![("DYLD_ROOT_PATH".to_string(), "/new".to_string())],
        };
        let merged = merge_env(&env);
        // Exactly one DYLD_ROOT_PATH entry, with the new value.
        let hits: Vec<&String> = merged
            .iter()
            .filter(|e| e.starts_with("DYLD_ROOT_PATH="))
            .collect();
        assert_eq!(hits.len(), 1, "merged: {merged:?}");
        assert_eq!(hits[0], "DYLD_ROOT_PATH=/new");
        std::env::remove_var("DYLD_ROOT_PATH");
    }
}
