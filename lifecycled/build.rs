// START_AI_HEADER
// MODULE: lifecycled/build.rs
// PURPOSE: Emit BSDOS_PLATFORM-derived rustc-cfg flags for bsdos-lifecycled.
// INTENT: lifecycled gates jail-lifecycle behaviour on the target platform now
//         (and battery-aware freeze/hibernate on PinePhone later). It pulls in
//         the shared helper so platform/capability cfgs stay in one place.
// DEPENDENCIES: ../infra/rust/platform_build.rs (include!d at compile time).
// PUBLIC_API: none (build script).
// END_AI_HEADER

include!("../infra/rust/platform_build.rs");

// main:start
//   purpose: Build-script entry point; emits the platform cfg directives.
//   input:   BSDOS_PLATFORM env var (read inside emit_platform_cfg).
//   output:  none (cargo directives printed to stdout).
//   sideEffects: prints cargo::rustc-cfg / rustc-check-cfg / rerun-if-env-changed.
fn main() {
    emit_platform_cfg();
}
// main:end
