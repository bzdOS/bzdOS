// START_AI_HEADER
// MODULE: jpk-manager/src/main.rs
// PURPOSE: CLI entry point for JPK package manager.
// INTENT: Parse subcommands (install/uninstall) and delegate to manager module.
// DEPENDENCIES: std, mod manager, mod manifest.
// PUBLIC_API: main.
// END_AI_HEADER

mod manager;
mod manifest;

use std::env;

// main:start
//   purpose: Parse CLI args and dispatch to install or uninstall.
//   input:  args: subcommand (install/uninstall) and path or app-id.
//   output: Never (exits on error via process::exit).
//   sideEffects: calls manager::install_package or uninstall_package, stderr output.
fn main() {
    let args: Vec<String> = env::args().collect();
    let result = match args.get(1).map(|s| s.as_str()) {
        Some("install") => {
            let path = args.get(2).map(|s| s.as_str()).unwrap_or("");
            manager::install_package(path)
        }
        Some("uninstall") => {
            let id = args.get(2).map(|s| s.as_str()).unwrap_or("");
            manager::uninstall_package(id)
        }
        _ => {
            eprintln!("Usage: bsdos-pkgd install <file.jpk>");
            eprintln!("       bsdos-pkgd uninstall <app-id>");
            std::process::exit(1);
        }
    };
    if let Err(e) = result {
        eprintln!("[pkgd] error: {e}");
        std::process::exit(1);
    }
}
// main:end
