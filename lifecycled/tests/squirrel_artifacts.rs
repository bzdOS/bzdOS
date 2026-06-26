// Tier 2 structural validation tests for Squirrel pipeline artifacts.
//
// Validates declarative configs from the repo to catch silent drift:
//   - Kernel configs (BSDOS-SQUIRREL-{amd64,aarch64})
//   - JPK recipes (jpk-recipes/*/jpk.toml)
//   - Jail configs (infra/etc-bsdOS/jails/*.conf)
//   - start-cage.sh (infra/etc-bsdOS/start-cage.sh)
//   - Makefile Squirrel targets + .PHONY
//
// These tests read files from the repo via CARGO_MANIFEST_DIR/../ to
// the workspace root. No QEMU, no network, no FreeBSD needed.

use std::path::PathBuf;
use toml::Value;

fn repo_root() -> PathBuf {
    PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("..")
}

fn read_file(rel: &str) -> String {
    let path = repo_root().join(rel);
    std::fs::read_to_string(&path)
        .unwrap_or_else(|e| panic!("failed to read {}: {e}", path.display()))
}

// ═══════════════════════════════════════════════════════════════════════════
// Kernel configs (freebsd-patches/conf/BSDOS-SQUIRREL-*)
// ═══════════════════════════════════════════════════════════════════════════

fn assert_kernel_has(conf: &str, needle: &str, arch: &str) {
    assert!(
        conf.contains(needle),
        "BSDOS-SQUIRREL-{arch}: missing '{needle}' — required for Squirrel QEMU"
    );
}

#[test]
fn kernel_config_amd64_has_required_devices() {
    let conf = read_file("freebsd-patches/conf/BSDOS-SQUIRREL-amd64");
    assert!(conf.contains("include GENERIC"), "must include GENERIC");
    assert_kernel_has(&conf, "virtio_blk", "amd64");
    assert_kernel_has(&conf, "virtio_net", "amd64");
    assert_kernel_has(&conf, "virtio_console", "amd64");
    assert_kernel_has(&conf, "EFI", "amd64");
    assert_kernel_has(&conf, "RACCT", "amd64");
    assert_kernel_has(&conf, "RCTL", "amd64");
    assert_kernel_has(&conf, "ZFS", "amd64");
    assert_kernel_has(&conf, "DEVFS", "amd64");
}

#[test]
fn kernel_config_aarch64_has_required_devices() {
    let conf = read_file("freebsd-patches/conf/BSDOS-SQUIRREL-aarch64");
    assert!(conf.contains("include GENERIC"), "must include GENERIC");
    assert_kernel_has(&conf, "virtio_blk", "aarch64");
    assert_kernel_has(&conf, "virtio_net", "aarch64");
    assert_kernel_has(&conf, "virtio_console", "aarch64");
    assert_kernel_has(&conf, "EFI", "aarch64");
    assert_kernel_has(&conf, "RACCT", "aarch64");
    assert_kernel_has(&conf, "RCTL", "aarch64");
    assert_kernel_has(&conf, "ZFS", "aarch64");
    // arm64-specific: UART for QEMU serial, ARM timer
    assert_kernel_has(&conf, "uart", "aarch64");
    assert_kernel_has(&conf, "generic_timer", "aarch64");
}

#[test]
fn kernel_configs_are_distinct() {
    let amd64 = read_file("freebsd-patches/conf/BSDOS-SQUIRREL-amd64");
    let aarch64 = read_file("freebsd-patches/conf/BSDOS-SQUIRREL-aarch64");
    assert_ne!(amd64, aarch64, "configs must not be identical");
    assert!(amd64.contains("amd64"), "amd64 config must reference amd64");
    assert!(aarch64.contains("aarch64"), "aarch64 config must reference aarch64");
}

// ═══════════════════════════════════════════════════════════════════════════
// JPK recipes (jpk-recipes/*/jpk.toml)
// ═══════════════════════════════════════════════════════════════════════════

fn parse_jpk_toml(rel: &str) -> Value {
    let content = read_file(rel);
    toml::from_str(&content).unwrap_or_else(|e| panic!("invalid TOML in {rel}: {e}"))
}

fn assert_jpk_required_fields(toml_val: &Value, recipe: &str) {
    // [meta]
    let meta = toml_val.get("meta").unwrap_or_else(|| panic!("{recipe}: missing [meta]"));
    assert_eq!(
        meta.get("schema_version").and_then(|v| v.as_str()),
        Some("1.0"),
        "{recipe}: meta.schema_version must be \"1.0\""
    );
    assert!(meta.get("id").is_some(), "{recipe}: missing meta.id");
    assert!(meta.get("version").is_some(), "{recipe}: missing meta.version");
    assert!(meta.get("name").is_some(), "{recipe}: missing meta.name");

    // [compatibility]
    let compat = toml_val.get("compatibility")
        .unwrap_or_else(|| panic!("{recipe}: missing [compatibility]"));
    let arch = compat.get("arch")
        .and_then(|v| v.as_array())
        .unwrap_or_else(|| panic!("{recipe}: missing compatibility.arch"));
    assert!(arch.len() >= 2, "{recipe}: must support at least 2 arches");
    let arch_strs: Vec<&str> = arch.iter().filter_map(|v| v.as_str()).collect();
    assert!(arch_strs.contains(&"amd64"), "{recipe}: must support amd64");
    assert!(arch_strs.contains(&"aarch64"), "{recipe}: must support aarch64");

    // [runtime]
    let runtime = toml_val.get("runtime")
        .unwrap_or_else(|| panic!("{recipe}: missing [runtime]"));
    assert!(runtime.get("jail_name").is_some(), "{recipe}: missing runtime.jail_name");
    assert!(runtime.get("type").is_some(), "{recipe}: missing runtime.type");

    // [permissions]
    let perms = toml_val.get("permissions")
        .unwrap_or_else(|| panic!("{recipe}: missing [permissions]"));
    assert!(perms.get("max_memory_mb").is_some(), "{recipe}: missing permissions.max_memory_mb");
    assert!(perms.get("max_cpu_percent").is_some(), "{recipe}: missing permissions.max_cpu_percent");
}

#[test]
fn jpk_recipe_phantom_browser_valid() {
    let toml_val = parse_jpk_toml("jpk-recipes/phantom-browser/jpk.toml");
    assert_jpk_required_fields(&toml_val, "phantom-browser");
    assert_eq!(
        toml_val.get("runtime").and_then(|r| r.get("jail_name")).and_then(|v| v.as_str()),
        Some("appBrowser"),
    );
    assert_eq!(
        toml_val.get("runtime").and_then(|r| r.get("needs_wayland")).and_then(|v| v.as_bool()),
        Some(true),
    );
}

#[test]
fn jpk_recipe_foot_valid() {
    let toml_val = parse_jpk_toml("jpk-recipes/foot/jpk.toml");
    assert_jpk_required_fields(&toml_val, "foot");
    assert_eq!(
        toml_val.get("runtime").and_then(|r| r.get("jail_name")).and_then(|v| v.as_str()),
        Some("appTerminal"),
    );
}

#[test]
fn jpk_recipe_cage_valid() {
    let toml_val = parse_jpk_toml("jpk-recipes/cage/jpk.toml");
    assert_jpk_required_fields(&toml_val, "cage");
}

#[test]
fn jpk_recipe_wpewebkit_fdo_valid() {
    let toml_val = parse_jpk_toml("jpk-recipes/wpewebkit-fdo/jpk.toml");
    assert_jpk_required_fields(&toml_val, "wpewebkit-fdo");
    assert_eq!(
        toml_val.get("permissions").and_then(|p| p.get("network")).and_then(|v| v.as_str()),
        Some("inet"),
        "wpewebkit-fdo must have network = inet (browser needs HTTP)"
    );
}

// ═══════════════════════════════════════════════════════════════════════════
// Jail configs (infra/etc-bsdOS/jails/*.conf)
// ═══════════════════════════════════════════════════════════════════════════

#[test]
fn jail_config_appterminal_starts_cage_with_foot() {
    let conf = read_file("infra/etc-bsdOS/jails/jail-appTerminal.conf");
    assert!(conf.contains("exec.start"), "must have exec.start");
    assert!(
        conf.contains("start-cage.sh") && conf.contains("appTerminal"),
        "exec.start must call start-cage.sh appTerminal"
    );
    assert!(conf.contains("foot"), "must launch foot terminal");
    assert!(conf.contains("persist"), "must have persist directive");
}

#[test]
fn jail_config_appbrowser_starts_cage_with_browser() {
    let conf = read_file("infra/etc-bsdOS/jails/jail-appBrowser.conf");
    assert!(conf.contains("exec.start"), "must have exec.start");
    assert!(
        conf.contains("start-cage.sh") && conf.contains("appBrowser"),
        "exec.start must call start-cage.sh appBrowser"
    );
    assert!(
        conf.contains("phantom") || conf.contains("wpewebkit") || conf.contains("browser"),
        "must launch a browser (phantom/wpewebkit)"
    );
    assert!(conf.contains("persist"), "must have persist directive");
}

#[test]
fn jail_configs_use_different_wayland_displays() {
    let term = read_file("infra/etc-bsdOS/jails/jail-appTerminal.conf");
    let browser = read_file("infra/etc-bsdOS/jails/jail-appBrowser.conf");
    assert!(term.contains("wayland-0"), "appTerminal must use wayland-0");
    assert!(browser.contains("wayland-1"), "appBrowser must use wayland-1");
}

// ═══════════════════════════════════════════════════════════════════════════
// start-cage.sh
// ═══════════════════════════════════════════════════════════════════════════

#[test]
fn start_cage_script_has_required_logic() {
    let script = read_file("infra/etc-bsdOS/start-cage.sh");
    assert!(script.contains("APP_ID"), "must accept APP_ID argument");
    assert!(script.contains("WAYLAND_DISPLAY"), "must handle WAYLAND_DISPLAY");
    assert!(script.contains("XDG_RUNTIME_DIR"), "must set XDG_RUNTIME_DIR");
    assert!(script.contains("cage"), "must launch cage");
    assert!(script.contains("READY"), "must send READY signal to bsdos-core");
    assert!(script.contains("control.sock"), "must notify via control.sock");
}

// ═══════════════════════════════════════════════════════════════════════════
// Makefile Squirrel targets
// ═══════════════════════════════════════════════════════════════════════════

#[test]
fn makefile_has_squirrel_targets() {
    let makefile = read_file("Makefile");

    for target in &[
        "squirrel-build",
        "squirrel-build-amd64",
        "squirrel-build-aarch64",
        "squirrel-smoke",
        "squirrel-smoke-amd64",
        "squirrel-smoke-aarch64",
        "squirrel-boot-amd64",
        "squirrel-boot-aarch64",
        "cross-squirrel-amd64",
        "cross-squirrel-aarch64",
        "test-2stream-e2e",
        "demo-2stream",
    ] {
        assert!(
            makefile.contains(target),
            "Makefile missing target: {target}"
        );
    }
}

#[test]
fn makefile_squirrel_targets_in_phony() {
    let makefile = read_file("Makefile");
    // Find the .PHONY block and check key squirrel targets are listed
    for target in &[
        "cross-squirrel-amd64",
        "squirrel-build",
        "squirrel-smoke",
        "test-2stream-e2e",
        "demo-2stream",
    ] {
        assert!(
            makefile.contains(target),
            "Makefile .PHONY missing: {target}"
        );
    }
}

// ═══════════════════════════════════════════════════════════════════════════
// Squirrel shell scripts exist and are non-empty
// ═══════════════════════════════════════════════════════════════════════════

#[test]
fn squirrel_scripts_exist_and_have_shebang() {
    for script in &[
        "infra/scripts/squirrel-build.sh",
        "infra/scripts/squirrel-smoke.sh",
        "infra/scripts/test-2stream-e2e.sh",
    ] {
        let content = read_file(script);
        assert!(
            content.starts_with("#!/bin/sh") || content.starts_with("#!/usr/bin/env sh"),
            "{script}: must have #!/bin/sh shebang"
        );
        assert!(
            content.len() > 100,
            "{script}: suspiciously short ({} bytes), expected a real script",
            content.len()
        );
    }
}

#[test]
fn squirrel_build_script_has_all_stages() {
    let script = read_file("infra/scripts/squirrel-build.sh");
    // Verify the 7-stage pipeline is present
    for stage in &["stage1_base", "stage2_pkg", "stage345_build", "stage5_configs", "stage6_mkimg"] {
        assert!(
            script.contains(stage),
            "squirrel-build.sh: missing stage function: {stage}"
        );
    }
    // Verify arch validation
    assert!(script.contains("amd64"), "must handle amd64");
    assert!(script.contains("aarch64"), "must handle aarch64");
}

#[test]
fn squirrel_smoke_script_checks_zenoh_port() {
    let script = read_file("infra/scripts/squirrel-smoke.sh");
    assert!(script.contains("7447"), "smoke must check Zenoh port 7447");
    assert!(script.contains("QEMU") || script.contains("qemu"), "must launch QEMU");
    assert!(script.contains("TIMEOUT") || script.contains("timeout"), "must have timeout logic");
}

#[test]
fn test_2stream_e2e_checks_both_streams() {
    let script = read_file("infra/scripts/test-2stream-e2e.sh");
    assert!(script.contains("appTerminal"), "must check appTerminal stream");
    assert!(script.contains("appBrowser"), "must check appBrowser stream");
    assert!(script.contains("BSDOS_AUTOSTREAM"), "must set BSDOS_AUTOSTREAM");
    assert!(script.contains("PASS") && script.contains("FAIL"), "must report pass/fail");
}
