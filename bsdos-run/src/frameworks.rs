// START_AI_HEADER
// MODULE: bsdos-run/src/frameworks.rs
// PURPOSE: Discover the frameworks/dylibs an IPA ships *inside itself* and map each
//          one to its baked-in install-name, so a self-contained IPA can be launched
//          without an external macOS SDK.
// INTENT: Most real IPAs (iSH included) vendor their own ARM64 Mach-O frameworks under
//         Payload/<App>.app/Frameworks/*.framework/<Name> and bare *.dylib siblings.
//         Those are already ARM64 Mach-O — exactly what dyld needs.  This module:
//           1. enumerates the embedded Frameworks/ directory,
//           2. asks `machotool deps <main-binary>` what the binary actually requires,
//           3. matches each required install-name (@rpath/Foo.framework/Foo, @rpath/lib.dylib,
//              and absolute /usr/lib|/System paths) against the embedded inventory.
//         The result tells the launcher which deps are satisfied from within the IPA and
//         which are still MISSING (would need an external SDK / overlay).
// DEPENDENCIES: std, error::RunError; invokes the prebuilt `machotool` binary (no duplication).
// PUBLIC_API: EmbeddedFramework, DepResolution, DepStatus, discover_frameworks,
//             find_machotool, resolve_deps.
// END_AI_HEADER

use std::collections::BTreeMap;
use std::path::{Path, PathBuf};
use std::process::Command;

use crate::error::RunError;

/// Candidate locations for the machotool binary, mirroring vchroot/populate.sh:
/// prefer an explicit $MACHOTOOL, else release then debug under the workspace target/.
const MACHOTOOL_TARGET_SUBPATHS: &[&str] = &[
    "target/release/machotool",
    "target/debug/machotool",
];

/// One framework or dylib physically present inside the IPA's Frameworks/ directory.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct EmbeddedFramework {
    /// Short name, e.g. "Foo" for Foo.framework, or "libbar.dylib" for a bare dylib.
    pub name: String,
    /// Absolute path to the loadable Mach-O image inside the extracted IPA
    /// (Foo.framework/Foo, or .../libbar.dylib).
    pub binary: PathBuf,
    /// True for a *.framework bundle; false for a bare *.dylib.
    pub is_framework: bool,
}

/// Whether a required dependency is satisfied from inside the IPA.
#[derive(Debug, Clone, PartialEq, Eq)]
pub enum DepStatus {
    /// Resolved against an embedded framework/dylib; carries the on-disk path.
    Embedded(PathBuf),
    /// Not found inside the IPA — would need an external SDK / overlay.
    /// `hard` is true for LOAD/REEXPORT (must resolve), false for WEAK.
    Missing { hard: bool },
}

/// One resolved (or unresolved) dependency of the main binary.
#[derive(Debug, Clone, PartialEq, Eq)]
pub struct DepResolution {
    /// The install-name exactly as recorded in the Mach-O (e.g. "@rpath/Foo.framework/Foo").
    pub install_name: String,
    /// Resolution outcome.
    pub status: DepStatus,
}

// discover_frameworks:start
//   purpose: Enumerate the *.framework bundles and bare *.dylib files an IPA ships
//            inside Payload/<App>.app/Frameworks/.
//   input:   app_dir — path to the extracted Payload/<App>.app directory.
//   output:  Result<Vec<EmbeddedFramework>, RunError>; empty Vec (Ok) when there is no
//            Frameworks/ directory (a fully static / SDK-dependent IPA).
//   sideEffects: reads one level of directory entries under <app>/Frameworks/.
pub fn discover_frameworks(app_dir: &Path) -> Result<Vec<EmbeddedFramework>, RunError> {
    let fw_dir = app_dir.join("Frameworks");
    if !fw_dir.is_dir() {
        // No embedded frameworks — not an error; just an empty inventory.
        return Ok(Vec::new());
    }

    let mut out: Vec<EmbeddedFramework> = Vec::new();
    let entries = std::fs::read_dir(&fw_dir).map_err(|e| {
        RunError::Ipa(format!("cannot read {}: {e}", fw_dir.display()))
    })?;

    for entry_res in entries {
        let entry = entry_res.map_err(RunError::Io)?;
        let path = entry.path();
        let file_name = match path.file_name().and_then(|n| n.to_str()) {
            Some(n) => n.to_string(),
            None => continue,
        };

        if path.is_dir() && file_name.ends_with(".framework") {
            // Foo.framework -> the loadable image is Foo.framework/Foo.
            let stem = file_name.trim_end_matches(".framework").to_string();
            let binary = path.join(&stem);
            if binary.is_file() {
                out.push(EmbeddedFramework {
                    name: stem,
                    binary,
                    is_framework: true,
                });
            }
        } else if path.is_file() && file_name.ends_with(".dylib") {
            out.push(EmbeddedFramework {
                name: file_name,
                binary: path,
                is_framework: false,
            });
        }
    }

    // Stable order for deterministic dry-run / test output.
    out.sort_by(|a, b| a.name.cmp(&b.name));
    Ok(out)
}
// discover_frameworks:end

// find_machotool:start
//   purpose: Locate the prebuilt machotool binary so we can call (not duplicate) it.
//            Mirrors ipa-runtime/vchroot/populate.sh: honour $MACHOTOOL, else search
//            the workspace target/{release,debug}, else a sibling of this executable.
//   input:   none (reads $MACHOTOOL and walks up from the current exe / cwd to find target/).
//   output:  Result<PathBuf, RunError>; Err if no machotool can be found.
//   sideEffects: getenv, stat calls.
pub fn find_machotool() -> Result<PathBuf, RunError> {
    // 1. Explicit override.
    if let Ok(explicit) = std::env::var("MACHOTOOL") {
        if !explicit.is_empty() {
            let p = PathBuf::from(&explicit);
            if p.is_file() {
                return Ok(p);
            }
            return Err(RunError::Ipa(format!(
                "MACHOTOOL={explicit} set but is not a file"
            )));
        }
    }

    // 2. Walk up from the current executable's directory looking for a workspace
    //    root that contains target/{release,debug}/machotool.  bsdos-run and
    //    machotool share one workspace target/ dir.
    let mut roots: Vec<PathBuf> = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        // exe is typically <root>/target/{release,debug}/bsdos-run, so the
        // workspace root is two levels above the target/ profile dir.
        if let Some(profile_dir) = exe.parent() {
            // profile_dir = .../target/<profile>
            if let Some(target_dir) = profile_dir.parent() {
                // target_dir = .../target
                if let Some(root) = target_dir.parent() {
                    roots.push(root.to_path_buf());
                }
            }
            // Also try a machotool sibling next to bsdos-run.
            let sibling = profile_dir.join("machotool");
            if sibling.is_file() {
                return Ok(sibling);
            }
        }
    }
    if let Ok(cwd) = std::env::current_dir() {
        roots.push(cwd);
    }

    for root in &roots {
        for sub in MACHOTOOL_TARGET_SUBPATHS {
            let cand = root.join(sub);
            if cand.is_file() {
                return Ok(cand);
            }
        }
    }

    Err(RunError::Ipa(format!(
        "machotool not found; build it (cargo build -p machotool) or set MACHOTOOL=/path/to/machotool \
         (searched target/release/machotool and target/debug/machotool under: {})",
        roots
            .iter()
            .map(|p| p.display().to_string())
            .collect::<Vec<_>>()
            .join(", ")
    )))
}
// find_machotool:end

// resolve_deps:start
//   purpose: Run `machotool deps <main-binary>`, then resolve each LOAD/WEAK/REEXPORT
//            install-name against the embedded framework/dylib inventory.
//   input:   machotool — path to the machotool binary;
//            main_binary — path to the app's main Mach-O executable;
//            embedded — the inventory from discover_frameworks().
//   output:  Result<Vec<DepResolution>, RunError>; one entry per dependency, marked
//            Embedded(path) or Missing{hard}.  RPATH lines and `#`/`[arch]` headers are
//            ignored (they are not loadable deps).  Order follows machotool output but
//            duplicate install-names (across fat slices) are de-duplicated.
//   sideEffects: spawns the machotool process; reads its stdout.
pub fn resolve_deps(
    machotool: &Path,
    main_binary: &Path,
    embedded: &[EmbeddedFramework],
) -> Result<Vec<DepResolution>, RunError> {
    // Build a lookup index keyed by the basename of each embedded loadable image:
    //   - framework "Foo"         keyed by "Foo"
    //   - dylib    "libbar.dylib" keyed by "libbar.dylib"
    // Install-names embed exactly these basenames at the tail, so basename match is
    // both sufficient and what dyld effectively does with @rpath.
    let index = build_index(embedded);

    let output = Command::new(machotool)
        .arg("deps")
        .arg(main_binary)
        .output()
        .map_err(|e| {
            RunError::Ipa(format!(
                "failed to run machotool ({}): {e}",
                machotool.display()
            ))
        })?;

    if !output.status.success() {
        let stderr = String::from_utf8_lossy(&output.stderr);
        return Err(RunError::Ipa(format!(
            "machotool deps {} failed: {}",
            main_binary.display(),
            stderr.trim()
        )));
    }

    let stdout = String::from_utf8_lossy(&output.stdout);
    Ok(resolve_from_deps_output(&stdout, &index))
}
// resolve_deps:end

// build_index:start
//   purpose: Index embedded images by the basename dyld matches at the install-name tail.
//   input:   embedded inventory.
//   output:  basename -> on-disk image path.
//   sideEffects: none.
fn build_index(embedded: &[EmbeddedFramework]) -> BTreeMap<&str, &Path> {
    let mut index: BTreeMap<&str, &Path> = BTreeMap::new();
    for fw in embedded {
        index.insert(fw.name.as_str(), fw.binary.as_path());
    }
    index
}
// build_index:end

// resolve_from_deps_output:start
//   purpose: Parse `machotool deps` stdout and resolve each loadable dep against the index.
//            Split out from resolve_deps so it is unit-testable without spawning a process.
//   input:   deps_stdout — raw stdout of `machotool deps <bin>`;
//            index — basename -> embedded image path.
//   output:  Vec<DepResolution> (deduped, headers/RPATH skipped).
//   sideEffects: none.
fn resolve_from_deps_output(
    deps_stdout: &str,
    index: &BTreeMap<&str, &Path>,
) -> Vec<DepResolution> {
    let mut resolutions: Vec<DepResolution> = Vec::new();
    let mut seen: std::collections::BTreeSet<String> = std::collections::BTreeSet::new();

    for line in deps_stdout.lines() {
        // machotool emits dep lines as "\t<KIND>\t<path>"; header lines start with
        // '#' or '['.  Splitting on tab and dropping empty fields gives [KIND, PATH].
        if line.starts_with('#') || line.starts_with('[') {
            continue;
        }
        let mut fields = line.split('\t').filter(|f| !f.is_empty());
        let kind = match fields.next() {
            Some(k) => k,
            None => continue,
        };
        let install_name = match fields.next() {
            Some(p) => p.to_string(),
            None => continue,
        };

        let hard = match kind {
            "LOAD" | "REEXPORT" => true,
            "WEAK" => false,
            // RPATH (informational) and any unknown kind are not loadable deps.
            _ => continue,
        };

        if !seen.insert(install_name.clone()) {
            continue; // de-dup across fat slices
        }

        let status = match resolve_one(&install_name, index) {
            Some(path) => DepStatus::Embedded(path.to_path_buf()),
            None => DepStatus::Missing { hard },
        };
        resolutions.push(DepResolution {
            install_name,
            status,
        });
    }

    resolutions
}
// resolve_from_deps_output:end

// resolve_one:start
//   purpose: Match a single install-name against the embedded inventory by its tail
//            basename — the segment dyld resolves via @rpath/@executable_path.
//   input:   install_name — the Mach-O install-name;
//            index — basename -> embedded image path.
//   output:  Some(&Path) if an embedded image matches, else None.
//   sideEffects: none.
//
// Examples:
//   @rpath/Foo.framework/Foo                      -> basename "Foo"
//   @executable_path/Frameworks/libbar.dylib      -> basename "libbar.dylib"
//   /usr/lib/libSystem.B.dylib                    -> basename "libSystem.B.dylib"
//   @rpath/Foo.framework/Versions/A/Foo           -> basename "Foo"
fn resolve_one<'a>(install_name: &str, index: &BTreeMap<&'a str, &'a Path>) -> Option<&'a Path> {
    let base = install_name.rsplit('/').next().unwrap_or(install_name);

    // Bare dylib by exact basename (e.g. "libbar.dylib") or framework short name.
    if let Some(p) = index.get(base) {
        return Some(*p);
    }

    None
}
// resolve_one:end

// ===========================================================================
// Tests — build a synthetic Payload/<App>.app/Frameworks tree in a tempdir and
// assert discovery + resolution behave.  No real IPA or machotool needed:
// resolution is tested against a hand-built machotool-style dep listing via
// resolve_from_deps_output.
// ===========================================================================
#[cfg(test)]
mod tests {
    use super::*;
    use std::fs;

    // Build: <tmp>/Payload/Demo.app/Frameworks/{Foo.framework/Foo, libbar.dylib}
    fn make_app(tmp: &Path) -> PathBuf {
        let app = tmp.join("Payload").join("Demo.app");
        let fw = app.join("Frameworks");
        let foo_fw = fw.join("Foo.framework");
        fs::create_dir_all(&foo_fw).unwrap();
        fs::write(foo_fw.join("Foo"), b"\xcf\xfa\xed\xfe").unwrap(); // pretend Mach-O
        fs::write(fw.join("libbar.dylib"), b"\xcf\xfa\xed\xfe").unwrap();
        // A stray non-loadable file that must be ignored.
        fs::write(fw.join("Info.plist"), b"x").unwrap();
        // An empty framework with no loadable image (must be skipped).
        fs::create_dir_all(fw.join("Empty.framework")).unwrap();
        app
    }

    #[test]
    fn discovers_embedded_frameworks_and_dylibs() {
        let tmp = tempfile::tempdir().unwrap();
        let app = make_app(tmp.path());

        let found = discover_frameworks(&app).expect("discover ok");
        // Foo.framework/Foo + libbar.dylib; Empty.framework (no image) skipped.
        assert_eq!(found.len(), 2, "got {found:?}");

        let foo = found.iter().find(|f| f.name == "Foo").expect("Foo present");
        assert!(foo.is_framework);
        assert!(foo.binary.ends_with("Foo.framework/Foo"));

        let bar = found
            .iter()
            .find(|f| f.name == "libbar.dylib")
            .expect("libbar present");
        assert!(!bar.is_framework);
    }

    #[test]
    fn no_frameworks_dir_is_empty_not_error() {
        let tmp = tempfile::tempdir().unwrap();
        let app = tmp.path().join("Payload").join("Bare.app");
        fs::create_dir_all(&app).unwrap();
        let found = discover_frameworks(&app).expect("discover ok");
        assert!(found.is_empty());
    }

    fn sample_inventory() -> Vec<EmbeddedFramework> {
        vec![
            EmbeddedFramework {
                name: "Foo".to_string(),
                binary: PathBuf::from("/x/Foo.framework/Foo"),
                is_framework: true,
            },
            EmbeddedFramework {
                name: "libbar.dylib".to_string(),
                binary: PathBuf::from("/x/libbar.dylib"),
                is_framework: false,
            },
        ]
    }

    #[test]
    fn resolves_rpath_framework_and_dylib() {
        let items = sample_inventory();
        let idx = build_index(&items);

        // @rpath framework install-name resolves to the framework image.
        assert_eq!(
            resolve_one("@rpath/Foo.framework/Foo", &idx),
            Some(Path::new("/x/Foo.framework/Foo"))
        );
        // Versioned framework path resolves by short name too.
        assert_eq!(
            resolve_one("@rpath/Foo.framework/Versions/A/Foo", &idx),
            Some(Path::new("/x/Foo.framework/Foo"))
        );
        // @executable_path dylib resolves by basename.
        assert_eq!(
            resolve_one("@executable_path/Frameworks/libbar.dylib", &idx),
            Some(Path::new("/x/libbar.dylib"))
        );
        // A system dylib the IPA does not vendor stays unresolved.
        assert_eq!(resolve_one("/usr/lib/libSystem.B.dylib", &idx), None);
    }

    #[test]
    fn find_machotool_via_env_var() {
        let tmp = tempfile::tempdir().unwrap();
        let fake = tmp.path().join("machotool");
        std::fs::write(&fake, b"").unwrap();

        // Valid path → returns it.
        std::env::set_var("MACHOTOOL", fake.to_str().unwrap());
        let result = find_machotool();
        std::env::remove_var("MACHOTOOL");
        assert_eq!(result.unwrap(), fake);
    }

    #[test]
    fn find_machotool_env_var_bad_path() {
        std::env::set_var("MACHOTOOL", "/nonexistent/machotool");
        let result = find_machotool();
        std::env::remove_var("MACHOTOOL");
        assert!(result.is_err());
        assert!(result.unwrap_err().to_string().contains("MACHOTOOL="));
    }

    #[test]
    fn resolve_reexport_dep() {
        let items = sample_inventory();
        let idx = build_index(&items);
        let out = "\tREEXPORT\t@rpath/Foo.framework/Foo\n";
        let res = resolve_from_deps_output(out, &idx);
        assert_eq!(res.len(), 1);
        assert!(matches!(res[0].status, DepStatus::Embedded(_)));
        assert!(matches!(res[0].status, DepStatus::Embedded(_)));
        // REEXPORT is hard (true).
        if let DepStatus::Missing { hard } = res[0].status {
            panic!("expected Embedded, got Missing{{hard={hard}}}");
        }
    }

    #[test]
    fn resolve_unknown_dep_kind_skipped() {
        let items = sample_inventory();
        let idx = build_index(&items);
        let out = "\tUNKNOWN\t@rpath/Foo.framework/Foo\n";
        let res = resolve_from_deps_output(out, &idx);
        assert!(res.is_empty(), "unknown kind must be skipped");
    }

    #[test]
    fn parses_machotool_output_into_resolutions() {
        let items = sample_inventory();
        let idx = build_index(&items);

        // Mimic real `machotool deps` output: header + tab-indented kind/path lines,
        // including an RPATH line (must be ignored) and a duplicate across slices.
        let out = "# deps /x/Demo.app/Demo\n\
                   [arm64]\n\
                   \tLOAD\t@rpath/Foo.framework/Foo\n\
                   \tWEAK\t@executable_path/Frameworks/libbar.dylib\n\
                   \tLOAD\t/usr/lib/libSystem.B.dylib\n\
                   \tRPATH\t@executable_path/Frameworks\n\
                   [x86_64]\n\
                   \tLOAD\t/usr/lib/libSystem.B.dylib\n";

        let res = resolve_from_deps_output(out, &idx);
        // libSystem deduped across the two slices -> 3 unique deps, RPATH skipped.
        assert_eq!(res.len(), 3, "got {res:?}");

        let foo = res
            .iter()
            .find(|r| r.install_name == "@rpath/Foo.framework/Foo")
            .unwrap();
        assert_eq!(
            foo.status,
            DepStatus::Embedded(PathBuf::from("/x/Foo.framework/Foo"))
        );

        let bar = res
            .iter()
            .find(|r| r.install_name.ends_with("libbar.dylib"))
            .unwrap();
        assert_eq!(
            bar.status,
            DepStatus::Embedded(PathBuf::from("/x/libbar.dylib"))
        );

        let sys = res
            .iter()
            .find(|r| r.install_name == "/usr/lib/libSystem.B.dylib")
            .unwrap();
        assert_eq!(sys.status, DepStatus::Missing { hard: true });
    }
}
