// START_AI_HEADER
// MODULE: infra/rust/platform_build.rs
// PURPOSE: Reusable build-script helper that translates the BSDOS_PLATFORM env var
//          into cargo rustc-cfg flags, mirroring sys-daemon-zig/src/platform.zig.
// INTENT: Single source of truth for compile-time platform selection on the Rust
//         side. Crates include!() this file from their build.rs and call
//         emit_platform_cfg(). Selection is mutually-exclusive (one platform),
//         unlike additive cargo features — chosen deliberately to stay symmetric
//         with the Zig `-Dplatform=<str>` mechanism (no compile_error! guards).
// DEPENDENCIES: std only (env + println for cargo directives). No external crates.
// PUBLIC_API: emit_platform_cfg().
// END_AI_HEADER

// emit_platform_cfg:start
//   purpose: Emit cargo cfg flags from the BSDOS_PLATFORM env var so downstream
//            code can gate on `#[cfg(bsdos_platform = "...")]` and per-capability
//            cfgs (e.g. `#[cfg(bsdos_has_i2c)]`). The capability set mirrors the
//            comptime `has_*` constants in sys-daemon-zig/src/platform.zig exactly.
//   input:   BSDOS_PLATFORM env var (one of: qemu_amd64, qemu_aarch64, bpi_m64,
//            pinephone). Defaults to "qemu_amd64" when unset; an unrecognised
//            value falls back to qemu_aarch64 (matching platform.zig `current`).
//   output:  prints cargo::rustc-cfg=bsdos_platform="<p>" plus one cargo::rustc-cfg
//            line per enabled capability; declares every possible value/cfg name via
//            cargo::rustc-check-cfg so no unexpected_cfgs warnings are produced.
//   sideEffects: writes cargo directives to stdout (consumed by cargo at build time).
pub fn emit_platform_cfg() {
    // Re-run this build script whenever the platform selection changes.
    println!("cargo::rerun-if-env-changed=BSDOS_PLATFORM");

    // Resolve the platform string; default to the primary dev loop (qemu_amd64).
    let p = std::env::var("BSDOS_PLATFORM").unwrap_or_else(|_| "qemu_amd64".to_string());

    // Validate against the known set; an unknown value falls back to qemu_aarch64,
    // mirroring the Zig-side `current` fallback in platform.zig.
    let platform: &str = match p.as_str() {
        "qemu_amd64" | "qemu_aarch64" | "bpi_m64" | "pinephone" => p.as_str(),
        other => {
            println!(
                "cargo::warning=BSDOS_PLATFORM=\"{other}\" not recognised; \
                 falling back to qemu_aarch64 (mirrors platform.zig)"
            );
            "qemu_aarch64"
        }
    };

    // Declare the full set of valid bsdos_platform values so cargo's unexpected_cfgs
    // lint stays silent regardless of which one is selected.
    println!(
        "cargo::rustc-check-cfg=cfg(bsdos_platform, \
         values(\"qemu_amd64\",\"qemu_aarch64\",\"bpi_m64\",\"pinephone\"))"
    );
    println!("cargo::rustc-cfg=bsdos_platform=\"{platform}\"");

    // ── Capability flags — kept 1:1 with sys-daemon-zig/src/platform.zig `has_*` ──
    // Phone-only (PinePhone).
    let is_phone = platform == "pinephone";
    // Real hardware = anything that is not a QEMU guest (BPI-M64 + PinePhone).
    let is_real_hw = platform == "bpi_m64" || platform == "pinephone";

    // (cfg-name, enabled) — declared via check-cfg, emitted only when enabled.
    // Mirrors platform.zig: has_modem/sim/sms/haptic/battery/gps/accelerometer/
    // magnetometer/proximity/predictive_touch/ghost_radio = phone-only;
    // has_i2c/audio/backlight = real hardware.
    let caps: [(&str, bool); 14] = [
        ("bsdos_has_modem", is_phone),
        ("bsdos_has_sim", is_phone),
        ("bsdos_has_sms", is_phone),
        ("bsdos_has_haptic", is_phone),
        ("bsdos_has_battery", is_phone),
        ("bsdos_has_gps", is_phone),
        ("bsdos_has_accelerometer", is_phone),
        ("bsdos_has_magnetometer", is_phone),
        ("bsdos_has_proximity", is_phone),
        ("bsdos_has_predictive_touch", is_phone),
        ("bsdos_has_ghost_radio", is_phone),
        ("bsdos_has_i2c", is_real_hw),
        ("bsdos_has_audio", is_real_hw),
        ("bsdos_has_backlight", is_real_hw),
    ];

    for (name, enabled) in caps {
        // check-cfg must be emitted for every cfg name, enabled or not, so that
        // `#[cfg(...)]` uses elsewhere never trip the unexpected_cfgs lint.
        println!("cargo::rustc-check-cfg=cfg({name})");
        if enabled {
            println!("cargo::rustc-cfg={name}");
        }
    }
}
// emit_platform_cfg:end
