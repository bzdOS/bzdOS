// START_AI_HEADER
// MODULE: bsdos-pkgd/src/main.rs
// PURPOSE: bsdos-pkgd CLI entry point — build/inspect/verify/install subcommands for .jpk packages.
// INTENT: Parse CLI arguments via clap and dispatch to the corresponding subcommand module.
//         .jpk = tar+gzip archive with jpk.toml, payload.tar, manifest.json per SPEC_jpk_descriptor_v1.
// DEPENDENCIES: clap, build, inspect, verify, install, descriptor, error.
// PUBLIC_API: main.
// END_AI_HEADER

mod build;
mod descriptor;
mod error;
mod inspect;
mod install;
mod manifest;
mod verify;

use std::path::PathBuf;

use clap::{Parser, Subcommand};

use error::PkgdError;

// Cli:start
//   purpose: Top-level CLI argument struct parsed by clap.
//   input:  argv.
//   output: Cli struct with subcommand variant.
//   sideEffects: none.
#[derive(Debug, Parser)]
#[command(
    name = "bsdos-pkgd",
    version,
    about = "bsdOS .jpk package tool — build, inspect, verify, install jail packages"
)]
struct Cli {
    #[command(subcommand)]
    command: Commands,
}
// Cli:end

#[derive(Debug, Subcommand)]
enum Commands {
    /// Build a .jpk archive from a source directory.
    ///
    /// The directory must contain:
    ///   jpk.toml     — descriptor (required)
    ///   payload/     — application files to pack (required)
    Build {
        /// Source directory containing jpk.toml and payload/
        dir: PathBuf,
        /// Output .jpk file path (default: <app_id>-<version>.jpk)
        #[arg(short, long)]
        output: Option<PathBuf>,
    },

    /// Print jpk.toml metadata and signature status from a .jpk archive.
    Inspect {
        /// Path to .jpk archive
        file: PathBuf,
    },

    /// Verify manifest.json SHA-256 hashes inside a .jpk archive.
    ///
    /// Ed25519 signature verification is not yet implemented (TODO).
    Verify {
        /// Path to .jpk archive
        file: PathBuf,
    },

    /// Install a .jpk package by extracting its payload into <root>/<app_id>/.
    Install {
        /// Path to .jpk archive
        file: PathBuf,
        /// Base directory for jail roots
        #[arg(long, default_value = "/opt/bsdos/jails")]
        root: PathBuf,
    },
}

// main:start
//   purpose: Entry point — parse CLI and dispatch to subcommand handlers.
//   input:  argv from std::env.
//   output: exits 0 on success, 1 on error.
//   sideEffects: reads/writes files, prints to stdout/stderr.
fn main() {
    let cli = Cli::parse();
    let result = run(cli);
    if let Err(e) = result {
        eprintln!("error: {e}");
        std::process::exit(1);
    }
}
// main:end

// run:start
//   purpose: Dispatch parsed CLI to the appropriate subcommand function.
//   input:  cli: parsed Cli struct.
//   output: Result<(), PkgdError>.
//   sideEffects: calls subcommand functions that read/write files.
fn run(cli: Cli) -> Result<(), PkgdError> {
    match cli.command {
        Commands::Build { dir, output } => {
            // Derive default output name from jpk.toml if not specified
            let out = match output {
                Some(p) => p,
                None => derive_output_path(&dir)?,
            };
            build::run_build(&dir, &out)
        }

        Commands::Inspect { file } => inspect::run_inspect(&file),

        Commands::Verify { file } => verify::run_verify(&file),

        Commands::Install { file, root } => install::run_install(&file, &root),
    }
}
// run:end

// derive_output_path:start
//   purpose: Read app_id and version from <dir>/jpk.toml to form a default output filename.
//   input:  dir: source directory path.
//   output: Result<PathBuf, PkgdError> — e.g. "org.bsdos.foot-1.0.0.jpk".
//   sideEffects: reads jpk.toml.
fn derive_output_path(dir: &PathBuf) -> Result<PathBuf, PkgdError> {
    let toml_path = dir.join("jpk.toml");
    let toml_str = std::fs::read_to_string(&toml_path)
        .map_err(|e| PkgdError::Io(format!("cannot read {}: {e}", toml_path.display())))?;
    let desc = descriptor::JpkDescriptor::from_toml_str(&toml_str)?;
    let name = format!("{}-{}.jpk", desc.meta.id, desc.meta.version);
    Ok(PathBuf::from(name))
}
// derive_output_path:end
