// START_AI_HEADER
// MODULE: bsdos-run/src/main.rs
// PURPOSE: bsdos-run CLI — IPA Phase 5 loader: `bsdos run app.ipa` unpacks and executes an iOS app.
// INTENT: Parse the `run` subcommand, dispatch to ipa/plist/bplist/entitlements/mobileprovision/
//         jpk/mldr/frameworks/launch modules.  Info.plist may be XML or binary (bplist00);
//         entitlements come from embedded.mobileprovision when present (authoritative) and
//         otherwise from the Info.plist projection.  Supports --dry-run (print plan + computed
//         JailPolicy + entitlement source + embedded frameworks + DYLD env), --jail (future:
//         spawn inside a bsdOS jail), --emit-jpk <out.toml>, and --launch (real self-contained
//         launch via mldr using the IPA's own embedded Frameworks/, sidestepping the external
//         ARM64-Mach-O SDK dylib blocker).
// DEPENDENCIES: clap, ipa, plist, bplist, entitlements, mobileprovision, jpk, mldr, frameworks,
//               launch, error.
// PUBLIC_API: main.
// END_AI_HEADER

mod bplist;
mod entitlements;
mod error;
mod frameworks;
mod ipa;
mod jpk;
mod launch;
mod mldr;
mod mobileprovision;
mod plist;

use std::path::{Path, PathBuf};

use clap::{Parser, Subcommand};

use error::RunError;

// Cli:start
//   purpose: Top-level CLI struct — currently exposes a single `run` subcommand.
//   input:  argv.
//   output: Cli with subcommand variant.
//   sideEffects: none.
#[derive(Debug, Parser)]
#[command(
    name = "bsdos-run",
    version,
    about = "bsdOS IPA runner — unpack and execute an iOS .ipa on FreeBSD via mldr"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}
// Cli:end

// Commands:start
//   purpose: Subcommand definitions.
//   input:  parsed from argv.
//   output: Commands enum variant.
//   sideEffects: none.
#[derive(Debug, Subcommand)]
enum Commands {
    /// Unpack an IPA archive and execute the application binary via mldr.
    ///
    /// The .ipa is extracted to a temporary directory; the directory is cleaned
    /// up automatically on process exit.
    ///
    /// Examples:
    ///   bsdos-run run app.ipa
    ///   bsdos-run run app.ipa --dry-run
    ///   bsdos-run run app.ipa --launch
    ///   bsdos-run run app.ipa --jail
    ///   bsdos-run run app.ipa --emit-jpk app.jpk.toml
    Run {
        /// Path to the .ipa file
        ipa: PathBuf,

        /// Print what would be executed (plus the computed jail policy, the embedded
        /// frameworks discovered inside the IPA, and the DYLD env that would be set)
        /// without running it
        #[arg(long)]
        dry_run: bool,

        /// Self-contained launch: resolve the IPA's deps against its OWN embedded
        /// Frameworks/ (no external macOS SDK) and exec mldr with the matching DYLD
        /// environment.  This is the path that runs apps which vendor their frameworks
        /// (e.g. iSH), sidestepping the ARM64-Mach-O SDK dylib blocker.
        #[arg(long)]
        launch: bool,

        /// Execute inside a bsdOS jail (requires jail infrastructure)
        #[arg(long)]
        jail: bool,

        /// Generate a jpk.toml descriptor from the IPA and write it to <PATH> (does not run).
        #[arg(long, value_name = "PATH")]
        emit_jpk: Option<PathBuf>,

        /// Extra arguments forwarded to the application binary
        #[arg(last = true)]
        app_args: Vec<String>,
    },
}
// Commands:end

// main:start
//   purpose: Entry point — parse CLI, dispatch to run_ipa, exit with error on failure.
//   input:  argv from std::env.
//   output: exits 0 on success, 1 on error (prints to stderr).
//   sideEffects: reads .ipa, extracts to temp dir, may write jpk.toml, may exec mldr.
fn main() {
    let cli = Cli::parse();
    if let Err(e) = dispatch(cli) {
        eprintln!("bsdos-run: error: {e}");
        std::process::exit(1);
    }
}
// main:end

// dispatch:start
//   purpose: Route parsed CLI command to the appropriate handler.
//   input:  cli — parsed Cli struct.
//   output: Result<(), RunError>.
//   sideEffects: delegates to run_ipa.
fn dispatch(cli: Cli) -> Result<(), RunError> {
    match cli.command {
        Commands::Run { ipa, dry_run, launch, jail, emit_jpk, app_args } => {
            run_ipa(&ipa, dry_run, launch, jail, emit_jpk.as_deref(), &app_args)
        }
    }
}
// dispatch:end

// run_ipa:start
//   purpose: Orchestrate IPA unpacking, binary discovery, plist + entitlements parsing,
//            embedded-framework discovery, optional jpk emission, mldr location, and exec.
//   input:  ipa_path — path to .ipa; dry_run — if true, print plan + policy + frameworks +
//           DYLD env and exit; launch — if true, perform a self-contained launch via mldr
//           using the IPA's own embedded Frameworks/; jail — future flag; emit_jpk — if
//           Some, write a jpk.toml descriptor and exit; app_args — extra args for the app.
//   output: Result<(), RunError>; on a non-dry-run/non-emit launch, success does not return
//           (exec replaces the process).
//   sideEffects: creates temp dir, extracts zip, reads plist, runs machotool, may write a
//                file, may exec mldr.
fn run_ipa(
    ipa_path: &Path,
    dry_run: bool,
    launch: bool,
    jail: bool,
    emit_jpk: Option<&Path>,
    app_args: &[String],
) -> Result<(), RunError> {
    // Step 1: verify .ipa exists and looks like a zip
    ipa::check_ipa(ipa_path)?;

    // Step 2: extract into a managed temp dir (cleaned up on drop)
    let tmp = ipa::extract_ipa(ipa_path)?;
    let extract_dir = tmp.path().to_path_buf();

    // Step 3: find Payload/*.app and the main binary inside it
    let (app_dir, binary_path) = ipa::find_binary(&extract_dir)?;

    // Step 4: parse Info.plist for bundle metadata
    let info_plist_path = app_dir.join("Info.plist");
    let bundle_info = plist::read_info_plist(&info_plist_path)?;
    eprintln!(
        "[bsdos-run] bundle_id={} name={} executable={} arm64={} min_os={}",
        bundle_info.bundle_identifier,
        bundle_info.best_name(),
        bundle_info.bundle_executable,
        bundle_info.requires_arm64,
        if bundle_info.minimum_os_version.is_empty() {
            "?"
        } else {
            bundle_info.minimum_os_version.as_str()
        }
    );

    // Step 5: derive jail policy from entitlements / plist permissions.
    // Prefer the signed embedded.mobileprovision profile (authoritative); fall back to the
    // Info.plist entitlement projection when no profile is present.
    let provision_path = app_dir.join("embedded.mobileprovision");
    let (provision, entitlement_source) = if provision_path.is_file() {
        match mobileprovision::read_mobileprovision(&provision_path) {
            Ok(ent) => {
                eprintln!(
                    "[bsdos-run] embedded.mobileprovision: app_id={} network={} get_task_allow={}",
                    ent.application_identifier, ent.network, ent.get_task_allow
                );
                (Some(ent), "embedded.mobileprovision")
            }
            Err(e) => {
                // A malformed profile must not abort the run; fall back to Info.plist.
                eprintln!(
                    "[bsdos-run] warning: cannot parse {}: {e}; using Info.plist entitlements",
                    provision_path.display()
                );
                (None, "Info.plist (mobileprovision unreadable)")
            }
        }
    } else {
        (None, "Info.plist")
    };

    let policy = entitlements::policy_from_entitlements(&bundle_info, provision.as_ref());

    // Step 5b: discover frameworks the IPA ships INSIDE itself
    // (Payload/<App>.app/Frameworks/).  These are already ARM64 Mach-O, so a
    // self-contained IPA needs no external SDK — the overlay is the bundle itself.
    let embedded = frameworks::discover_frameworks(&app_dir)?;
    if embedded.is_empty() {
        eprintln!("[bsdos-run] no embedded Frameworks/ — IPA is not self-contained");
    } else {
        eprintln!(
            "[bsdos-run] embedded frameworks: {} found in {}/Frameworks",
            embedded.len(),
            app_dir.display()
        );
    }

    // Step 6 (optional): emit a jpk.toml descriptor and stop.
    if let Some(out_path) = emit_jpk {
        let descriptor = jpk::ipa_to_jpk_descriptor(&bundle_info, &policy);
        std::fs::write(out_path, descriptor.as_bytes()).map_err(|e| {
            RunError::Ipa(format!(
                "cannot write jpk descriptor to {}: {e}",
                out_path.display()
            ))
        })?;
        eprintln!("[bsdos-run] wrote jpk descriptor to {}", out_path.display());
        return Ok(());
    }

    // Step 7: locate mldr
    let mldr_path = mldr::find_mldr()?;

    if jail {
        eprintln!(
            "[bsdos-run] --jail: jail integration not yet implemented; \
             would apply ip4={} (network={})",
            policy.network.jail_param(),
            policy.network.jpk_network()
        );
    }

    // Compute the self-contained DYLD environment (used by both --dry-run printing and
    // --launch).  For a self-contained IPA the dyld root is the bundle itself and the
    // framework/library search path is <app>/Frameworks.
    let dyld_env = launch::build_dyld_env(&app_dir, &embedded);

    if dry_run {
        // Print the command that would be executed plus the computed jail policy.
        let display_args: Vec<String> = app_args.to_vec();
        println!(
            "mldr: {}\nbinary: {}\nargs: {:?}",
            mldr_path.display(),
            binary_path.display(),
            display_args
        );
        println!(
            "jail policy: network={} (ip4={}) audio={} gpu={}",
            policy.network.jpk_network(),
            policy.network.jail_param(),
            policy.audio,
            policy.gpu
        );
        println!("entitlement source: {entitlement_source}");

        // Embedded frameworks discovered inside the IPA.
        if embedded.is_empty() {
            println!("embedded frameworks: none (IPA depends on an external SDK)");
        } else {
            println!("embedded frameworks ({}):", embedded.len());
            for fw in &embedded {
                let kind = if fw.is_framework { "framework" } else { "dylib" };
                println!("  - {} [{}] -> {}", fw.name, kind, fw.binary.display());
            }
            // Resolve the main binary's deps against the embedded inventory so the
            // dry-run shows exactly which deps are satisfied from inside the IPA and
            // which would still be MISSING (need an external SDK / overlay).
            print_dep_resolution(&binary_path, &embedded);
        }

        // The DYLD environment that --launch would set.
        println!("DYLD env (self-contained launch):");
        for (k, v) in &dyld_env.vars {
            println!("  {k}={v}");
        }
        return Ok(());
    }

    if launch {
        // Self-contained launch: resolve deps against the embedded Frameworks/ and exec
        // mldr with the matching DYLD environment.  Report the resolution first so a
        // failure to find a hard dep is visible before exec.
        if embedded.is_empty() {
            eprintln!(
                "[bsdos-run] --launch: no embedded Frameworks/; falling back to plain mldr exec \
                 (will rely on the external SDK overlay if any)"
            );
            mldr::exec_mldr(&mldr_path, &binary_path, app_args, &tmp)?;
            drop(tmp);
            return Ok(());
        }
        print_dep_resolution(&binary_path, &embedded);

        // Step 8: exec via execve with the self-contained DYLD environment.  Replaces
        // the current process; tmp is kept alive until exec so the extracted tree stays
        // readable (TempDir's Drop will not run after a successful execve).
        launch::exec_self_contained(&mldr_path, &binary_path, app_args, &dyld_env)?;
        drop(tmp);
        return Ok(());
    }

    // Step 8 (default): plain mldr exec — replaces the current process; tmp dir is dropped
    // in the OS after exec because TempDir's Drop will not run after execv succeeds.
    // We keep `tmp` alive until exec so the extracted files remain readable.
    mldr::exec_mldr(&mldr_path, &binary_path, app_args, &tmp)?;

    // exec_mldr only returns on error; tmp remains bound here to satisfy the borrow.
    drop(tmp);
    Ok(())
}
// run_ipa:end

// print_dep_resolution:start
//   purpose: Run machotool against the main binary and print, per dependency, whether it is
//            satisfied from the IPA's embedded Frameworks/ or still MISSING.
//   input:  binary_path — the app's main Mach-O; embedded — the discovered inventory.
//   output: none; on a machotool failure prints a warning (does not abort the run — a
//           dry-run / launch should still proceed and let dyld report the real error).
//   sideEffects: spawns machotool; prints to stdout/stderr.
fn print_dep_resolution(binary_path: &Path, embedded: &[frameworks::EmbeddedFramework]) {
    let machotool = match frameworks::find_machotool() {
        Ok(p) => p,
        Err(e) => {
            eprintln!("[bsdos-run] dep resolution skipped: {e}");
            return;
        }
    };
    let resolutions = match frameworks::resolve_deps(&machotool, binary_path, embedded) {
        Ok(r) => r,
        Err(e) => {
            eprintln!("[bsdos-run] dep resolution failed: {e}");
            return;
        }
    };

    println!("dependency resolution (vs embedded Frameworks/):");
    let mut missing_hard = 0usize;
    for res in &resolutions {
        match &res.status {
            frameworks::DepStatus::Embedded(path) => {
                println!("  EMBEDDED {} -> {}", res.install_name, path.display());
            }
            frameworks::DepStatus::Missing { hard } => {
                if *hard {
                    missing_hard += 1;
                    println!("  MISSING  {} (hard)", res.install_name);
                } else {
                    println!("  missing  {} (weak, ok)", res.install_name);
                }
            }
        }
    }
    println!(
        "  -> {} hard dep(s) MISSING from the IPA's own Frameworks/{}",
        missing_hard,
        if missing_hard == 0 {
            " — self-contained launch is viable"
        } else {
            " (these would need an external SDK / overlay)"
        }
    );
}
// print_dep_resolution:end
