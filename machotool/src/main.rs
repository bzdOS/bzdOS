// START_AI_HEADER
// MODULE: ipa-runtime/machotool/src/main.rs
// PURPOSE: CLI for the standalone Mach-O inspector — `machotool deps|arch <binary>`.
// INTENT: Print a binary's LC_LOAD_DYLIB deps (feeds vchroot/populate.sh) and its
//         architecture(s). Manual argv parsing, no external crates.
// DEPENDENCIES: std, crate::macho.
// PUBLIC_API: main.
// END_AI_HEADER

// main.rs
//
// purpose:     CLI front-end for the standalone Mach-O parser. Two subcommands:
//                machotool deps <binary>   — list LC_LOAD_DYLIB deps + rpaths
//                machotool arch <binary>   — list architecture(s)
//              `deps` output feeds vchroot/populate.sh, which symlinks each
//              dylib into the DYLD_ROOT_PATH overlay.
// input:       argv: <subcommand> <path-to-mach-o>.
// output:      stdout report; exit 0 on success, non-zero on any error.
// sideEffects: reads the named file; writes to stdout/stderr.
//
// Manual argv parsing (no clap) to keep this binary dependency-free — it must
// build on the dev VM (dev-vm) without network access (see Cargo.toml note).

mod macho;

use std::process::ExitCode;

// main:start
/// purpose: program entry; dispatch the subcommand and map errors to exit codes.
/// input:   none (reads std::env::args).
/// output:  ExitCode::SUCCESS or ::FAILURE.
/// sideEffects: file IO + stdout/stderr.
fn main() -> ExitCode {
    let args: Vec<String> = std::env::args().collect();
    match run(&args) {
        Ok(()) => ExitCode::SUCCESS,
        Err(msg) => {
            eprintln!("machotool: {msg}");
            ExitCode::FAILURE
        }
    }
}
// main:end

// run:start
/// purpose: parse argv and execute the requested subcommand.
/// input:   full argv slice (args[0] is the program name).
/// output:  Ok(()) or a human-readable error string.
/// sideEffects: file IO + stdout.
fn run(args: &[String]) -> Result<(), String> {
    // args[0] = program, args[1] = subcommand, args[2] = path.
    let sub = match args.get(1).map(String::as_str) {
        Some(s) => s,
        None => return Err(usage()),
    };

    match sub {
        "deps" => {
            let info = load(args, sub)?;
            print_deps(&info.0, &info.1);
            Ok(())
        }
        "arch" => {
            let info = load(args, sub)?;
            print_arch(&info.0, &info.1);
            Ok(())
        }
        "-h" | "--help" | "help" => {
            println!("{}", usage());
            Ok(())
        }
        other => Err(format!("unknown subcommand '{other}'\n{}", usage())),
    }
}
// run:end

// load:start
/// purpose: shared loader for `deps`/`arch` — read the file arg and parse it.
/// input:   full argv, the subcommand name (for the error message).
/// output:  (path, parsed MachInfo) or a human-readable error string.
/// sideEffects: reads the named file.
fn load(args: &[String], sub: &str) -> Result<(String, macho::MachInfo), String> {
    let path = args
        .get(2)
        .ok_or_else(|| format!("'{sub}' needs a <binary> argument\n{}", usage()))?;
    let bytes = std::fs::read(path).map_err(|e| format!("cannot read {path}: {e}"))?;
    let info = macho::parse(&bytes).map_err(|e| format!("{path}: {e}"))?;
    Ok((path.clone(), info))
}
// load:end

// usage:start
/// purpose: usage/help text. input: none. output: owned string. sideEffects: none.
fn usage() -> String {
    "\
usage:
  machotool deps <mach-o-binary>   list LC_LOAD_DYLIB / weak / reexport deps + LC_RPATH
  machotool arch <mach-o-binary>   list architecture(s) (thin or fat/universal)

deps output is consumed by ipa-runtime/vchroot/populate.sh to populate the
DYLD_ROOT_PATH overlay with the dylibs a binary needs."
        .to_string()
}
// usage:end

// print_deps:start
/// purpose: print the dependency report for `deps`.
/// input:   path (for the header), parsed MachInfo.
/// output:  none. sideEffects: stdout.
///
/// One section per arch slice. Dep lines are tab-indented and tagged so the
/// shell helper can filter on kind if it wants ("LOAD" lines are mandatory).
fn print_deps(path: &str, info: &macho::MachInfo) {
    println!("# deps {path}");
    for slice in &info.slices {
        println!("[{}]", slice.arch);
        for dep in &slice.deps {
            println!("\t{}\t{}", dep.kind.tag(), dep.path);
        }
        for rp in &slice.rpaths {
            println!("\tRPATH\t{rp}");
        }
    }
}
// print_deps:end

// print_arch:start
/// purpose: print the architecture report for `arch`.
/// input:   path, parsed MachInfo.
/// output:  none. sideEffects: stdout (one arch name per line).
fn print_arch(path: &str, info: &macho::MachInfo) {
    println!("# arch {path}");
    for slice in &info.slices {
        println!("{}", slice.arch);
    }
}
// print_arch:end
