// START_AI_HEADER
// MODULE: bsdos-core/src/config.rs
// PURPOSE: Unified configuration loader — TOML file + env var overrides.
// INTENT: Single source of truth for all bsdos-core settings, replacing
//         scattered env vars with a structured config file.
// END_AI_HEADER

// START_CONFIG_LOADER
//   purpose: Load bsdos-core configuration from TOML file + env overrides
//   input: /etc/bsdos/bsdos-core.toml (TOML), environment variables
//   output: Config struct (zenoh, stream, output, logging)
//   sideEffects: reads filesystem
//   precedence: env var > TOML > default
//   errorHandling: missing file → env-only mode; invalid TOML → exit with message

use serde::Deserialize;
use std::path::Path;

const CONFIG_PATH: &str = "/etc/bsdos/bsdos-core.toml";

// START_CONFIG_STRUCT
/// purpose: Top-level configuration for bsdos-core.
#[derive(Debug, Deserialize, Default)]
pub struct Config {
    #[serde(default)]
    pub zenoh: ZenohConfig,
    #[serde(default)]
    pub stream: StreamSection,
    #[serde(default)]
    pub output: OutputSection,
}

#[derive(Debug, Deserialize)]
pub struct ZenohConfig {
    #[serde(default = "default_transport")]
    pub transport: String,
    #[serde(default)]
    pub listen_ip: String,
    #[serde(default = "default_port")]
    pub listen_port: String,
    #[serde(default)]
    pub obfs_psk: String,
    #[serde(default)]
    pub multicast: bool,
    #[serde(default = "default_timeout")]
    pub open_timeout_secs: u64,
}
impl Default for ZenohConfig {
    fn default() -> Self {
        Self {
            transport: default_transport(),
            listen_ip: String::new(),
            listen_port: default_port(),
            obfs_psk: String::new(),
            multicast: false,
            open_timeout_secs: default_timeout(),
        }
    }
}

#[derive(Debug, Deserialize, Default)]
pub struct StreamSection {
    #[serde(default)]
    pub autostart: Vec<String>,
}

#[derive(Debug, Deserialize)]
pub struct OutputSection {
    #[serde(default = "default_width")]
    pub width: u32,
    #[serde(default = "default_height")]
    pub height: u32,
    #[serde(default = "default_scale")]
    pub scale: f32,
}
impl Default for OutputSection {
    fn default() -> Self {
        Self {
            width: default_width(),
            height: default_height(),
            scale: default_scale(),
        }
    }
}

fn default_transport() -> String { "tcp".into() }
fn default_port() -> String { "7447".into() }
fn default_timeout() -> u64 { 10 }
fn default_width() -> u32 { 1280 }
fn default_height() -> u32 { 720 }
fn default_scale() -> f32 { 1.0 }
// END_CONFIG_STRUCT

// START_CONFIG_LOAD
/// purpose: Load config from TOML file, then apply env var overrides.
/// input: CONFIG_PATH file (optional), environment variables
/// output: Config struct fully resolved
/// sideEffects: eprintln if TOML file is absent or unparseable
pub fn load() -> Config {
    let mut cfg = load_toml().unwrap_or_else(|e| {
        eprintln!("[config] No TOML config ({}) — using env vars only: {}", CONFIG_PATH, e);
        Config::default()
    });

    apply_env_overrides(&mut cfg, |k| std::env::var(k).ok());

    cfg
}

// apply_env_overrides:start
//   purpose: Apply env var overrides onto an already-loaded Config.
//   input:  cfg — mutable config to update
//           getenv — callable that maps var names to values (injectable for tests)
//   output: none (modifies cfg in place)
//   sideEffects: none
pub(crate) fn apply_env_overrides<F: Fn(&str) -> Option<String>>(cfg: &mut Config, getenv: F) {
    if let Some(v) = getenv("ZENOH_OBFS") {
        if v == "1" { cfg.zenoh.transport = "obfs".into(); }
    }
    if let Some(v) = getenv("ZENOH_TLS") {
        if v == "1" { cfg.zenoh.transport = "tls".into(); }
    }
    if let Some(v) = getenv("ZENOH_LISTEN_IP") {
        cfg.zenoh.listen_ip = v;
    }
    if let Some(v) = getenv("ZENOH_LISTEN_PORT") {
        cfg.zenoh.listen_port = v;
    }
    if let Some(v) = getenv("BSDOS_OBFS_PSK") {
        cfg.zenoh.obfs_psk = v;
    }
    if let Some(v) = getenv("BSDOS_ZENOH_SCOUTING") {
        cfg.zenoh.multicast = v == "1";
    }
    if let Some(v) = getenv("BSDOS_AUTOSTREAM") {
        if !v.is_empty() {
            cfg.stream.autostart = v.split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
        }
    }
    if let Some(v) = getenv("BSDOS_OUTPUT_WIDTH") {
        if let Ok(w) = v.parse() { cfg.output.width = w; }
    }
    if let Some(v) = getenv("BSDOS_OUTPUT_HEIGHT") {
        if let Ok(h) = v.parse() { cfg.output.height = h; }
    }
    if let Some(v) = getenv("BSDOS_OUTPUT_SCALE") {
        if let Ok(s) = v.parse::<f32>() { cfg.output.scale = s; }
    }
}
// apply_env_overrides:end

fn load_toml() -> Result<Config, String> {
    let path = Path::new(CONFIG_PATH);
    if !path.exists() {
        return Err(format!("{} not found", CONFIG_PATH));
    }
    let content = std::fs::read_to_string(path)
        .map_err(|e| format!("read {}: {}", CONFIG_PATH, e))?;
    toml::from_str(&content)
        .map_err(|e| format!("parse {}: {}", CONFIG_PATH, e))
}
// END_CONFIG_LOAD

// START_CONFIG_PRINT
/// purpose: Print resolved config for diagnostics (--check-config mode).
pub fn print_resolved(cfg: &Config) {
    eprintln!("[config] transport={}", cfg.zenoh.transport);
    eprintln!("[config] listen={}:{}", 
        if cfg.zenoh.listen_ip.is_empty() { "0.0.0.0" } else { &cfg.zenoh.listen_ip },
        cfg.zenoh.listen_port);
    eprintln!("[config] multicast={}", cfg.zenoh.multicast);
    eprintln!("[config] autostart={:?}", cfg.stream.autostart);
    eprintln!("[config] output={}x{}@{}", cfg.output.width, cfg.output.height, cfg.output.scale);
    eprintln!("[config] obfs_psk={}", if cfg.zenoh.obfs_psk.is_empty() { "none" } else { "set" });
}
// END_CONFIG_PRINT

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::HashMap;

    fn fakeenv(pairs: &[(&str, &str)]) -> HashMap<String, String> {
        pairs.iter().map(|(k, v)| (k.to_string(), v.to_string())).collect()
    }

    fn override_with(map: &HashMap<String, String>, cfg: &mut Config) {
        apply_env_overrides(cfg, |k| map.get(k).cloned());
    }

    // ── Defaults ──────────────────────────────────────────────────────────

    #[test]
    fn defaults_transport_tcp() {
        assert_eq!(Config::default().zenoh.transport, "tcp");
    }

    #[test]
    fn defaults_port_7447() {
        assert_eq!(Config::default().zenoh.listen_port, "7447");
    }

    #[test]
    fn defaults_open_timeout_10() {
        assert_eq!(Config::default().zenoh.open_timeout_secs, 10);
    }

    #[test]
    fn defaults_multicast_false() {
        assert!(!Config::default().zenoh.multicast);
    }

    #[test]
    fn defaults_autostart_empty() {
        assert!(Config::default().stream.autostart.is_empty());
    }

    #[test]
    fn defaults_output_1280x720_scale1() {
        let cfg = Config::default();
        assert_eq!(cfg.output.width, 1280);
        assert_eq!(cfg.output.height, 720);
        assert_eq!(cfg.output.scale, 1.0);
    }

    // ── TOML parsing ──────────────────────────────────────────────────────

    #[test]
    fn toml_empty_gives_all_defaults() {
        let cfg: Config = toml::from_str("").expect("empty toml");
        assert_eq!(cfg.zenoh.transport, "tcp");
        assert_eq!(cfg.zenoh.listen_port, "7447");
        assert_eq!(cfg.output.width, 1280);
    }

    #[test]
    fn toml_partial_zenoh_section() {
        let cfg: Config = toml::from_str("[zenoh]\nlisten_port = \"9000\"").expect("parse");
        assert_eq!(cfg.zenoh.listen_port, "9000");
        assert_eq!(cfg.zenoh.transport, "tcp"); // default preserved
    }

    #[test]
    fn toml_full_parse() {
        let toml_str = r#"
[zenoh]
transport = "obfs"
listen_ip = "0.0.0.0"
listen_port = "443"
obfs_psk = "secret"
multicast = true
open_timeout_secs = 30

[stream]
autostart = ["appTerminal:foot:", "appBrowser:chrome:about:blank"]

[output]
width = 1920
height = 1080
scale = 2.0
"#;
        let cfg: Config = toml::from_str(toml_str).expect("parse");
        assert_eq!(cfg.zenoh.transport, "obfs");
        assert_eq!(cfg.zenoh.listen_port, "443");
        assert_eq!(cfg.zenoh.obfs_psk, "secret");
        assert!(cfg.zenoh.multicast);
        assert_eq!(cfg.zenoh.open_timeout_secs, 30);
        assert_eq!(cfg.stream.autostart.len(), 2);
        assert_eq!(cfg.stream.autostart[0], "appTerminal:foot:");
        assert_eq!(cfg.output.width, 1920);
        assert_eq!(cfg.output.height, 1080);
        assert_eq!(cfg.output.scale, 2.0);
    }

    #[test]
    fn toml_multicast_explicit_false() {
        let cfg: Config = toml::from_str("[zenoh]\nmulticast = false").expect("parse");
        assert!(!cfg.zenoh.multicast);
    }

    // ── Env overrides ─────────────────────────────────────────────────────

    #[test]
    fn env_zenoh_obfs_sets_transport_obfs() {
        let mut cfg = Config::default();
        override_with(&fakeenv(&[("ZENOH_OBFS", "1")]), &mut cfg);
        assert_eq!(cfg.zenoh.transport, "obfs");
    }

    #[test]
    fn env_zenoh_obfs_zero_does_not_change_transport() {
        let mut cfg = Config::default();
        override_with(&fakeenv(&[("ZENOH_OBFS", "0")]), &mut cfg);
        assert_eq!(cfg.zenoh.transport, "tcp");
    }

    #[test]
    fn env_zenoh_tls_sets_transport_tls() {
        let mut cfg = Config::default();
        override_with(&fakeenv(&[("ZENOH_TLS", "1")]), &mut cfg);
        assert_eq!(cfg.zenoh.transport, "tls");
    }

    #[test]
    fn env_tls_overrides_toml_obfs() {
        let mut cfg: Config = toml::from_str("[zenoh]\ntransport = \"obfs\"").expect("parse");
        override_with(&fakeenv(&[("ZENOH_TLS", "1")]), &mut cfg);
        assert_eq!(cfg.zenoh.transport, "tls");
    }

    #[test]
    fn env_listen_ip_and_port() {
        let mut cfg = Config::default();
        override_with(&fakeenv(&[
            ("ZENOH_LISTEN_IP", "192.168.1.1"),
            ("ZENOH_LISTEN_PORT", "9999"),
        ]), &mut cfg);
        assert_eq!(cfg.zenoh.listen_ip, "192.168.1.1");
        assert_eq!(cfg.zenoh.listen_port, "9999");
    }

    #[test]
    fn env_obfs_psk() {
        let mut cfg = Config::default();
        override_with(&fakeenv(&[("BSDOS_OBFS_PSK", "mykey123")]), &mut cfg);
        assert_eq!(cfg.zenoh.obfs_psk, "mykey123");
    }

    #[test]
    fn env_scouting_one_enables_multicast() {
        let mut cfg = Config::default();
        override_with(&fakeenv(&[("BSDOS_ZENOH_SCOUTING", "1")]), &mut cfg);
        assert!(cfg.zenoh.multicast);
    }

    #[test]
    fn env_scouting_zero_disables_multicast_from_toml() {
        let mut cfg: Config = toml::from_str("[zenoh]\nmulticast = true").expect("parse");
        override_with(&fakeenv(&[("BSDOS_ZENOH_SCOUTING", "0")]), &mut cfg);
        assert!(!cfg.zenoh.multicast);
    }

    #[test]
    fn env_autostream_comma_split() {
        let mut cfg = Config::default();
        override_with(&fakeenv(&[("BSDOS_AUTOSTREAM", "appTerminal:foot:,appBrowser:chrome:")]), &mut cfg);
        assert_eq!(cfg.stream.autostart, vec!["appTerminal:foot:", "appBrowser:chrome:"]);
    }

    #[test]
    fn env_autostream_trims_spaces() {
        let mut cfg = Config::default();
        override_with(&fakeenv(&[("BSDOS_AUTOSTREAM", " appA:foo: , appB:bar: ")]), &mut cfg);
        assert_eq!(cfg.stream.autostart, vec!["appA:foo:", "appB:bar:"]);
    }

    #[test]
    fn env_autostream_empty_string_skips_override() {
        let mut cfg: Config = toml::from_str(
            "[stream]\nautostart = [\"appTerminal:foot:\"]"
        ).expect("parse");
        override_with(&fakeenv(&[("BSDOS_AUTOSTREAM", "")]), &mut cfg);
        assert_eq!(cfg.stream.autostart, vec!["appTerminal:foot:"]);
    }

    #[test]
    fn env_output_width_height_scale() {
        let mut cfg = Config::default();
        override_with(&fakeenv(&[
            ("BSDOS_OUTPUT_WIDTH", "2560"),
            ("BSDOS_OUTPUT_HEIGHT", "1440"),
            ("BSDOS_OUTPUT_SCALE", "2.0"),
        ]), &mut cfg);
        assert_eq!(cfg.output.width, 2560);
        assert_eq!(cfg.output.height, 1440);
        assert_eq!(cfg.output.scale, 2.0);
    }

    #[test]
    fn env_invalid_width_leaves_default() {
        let mut cfg = Config::default();
        override_with(&fakeenv(&[("BSDOS_OUTPUT_WIDTH", "notanumber")]), &mut cfg);
        assert_eq!(cfg.output.width, 1280);
    }

    #[test]
    fn env_invalid_scale_leaves_default() {
        let mut cfg = Config::default();
        override_with(&fakeenv(&[("BSDOS_OUTPUT_SCALE", "bad")]), &mut cfg);
        assert_eq!(cfg.output.scale, 1.0);
    }

    #[test]
    fn no_env_vars_leaves_toml_values() {
        let toml_str = "[zenoh]\ntransport = \"tls\"\nlisten_port = \"8443\"";
        let mut cfg: Config = toml::from_str(toml_str).expect("parse");
        override_with(&fakeenv(&[]), &mut cfg); // empty env
        assert_eq!(cfg.zenoh.transport, "tls");
        assert_eq!(cfg.zenoh.listen_port, "8443");
    }
}
