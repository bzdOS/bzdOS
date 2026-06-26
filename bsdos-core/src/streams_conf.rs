// START_AI_HEADER
// MODULE: bsdos-core/src/streams_conf.rs
// PURPOSE: Parse /etc/bsdos/streams.conf (TOML) into Vec<StreamConfig>.
// INTENT: Replace the BSDOS_AUTOSTREAM env-var string with a proper config file;
//         retain full backward compatibility when the file is absent.
//
// START_INVARIANTS
// - If streams.conf is absent or unreadable, callers fall back to BSDOS_AUTOSTREAM.
// - The TOML schema matches streams.conf.example exactly.
// - No panic!, no unwrap() — all errors propagate via Result.
// END_INVARIANTS
//
// START_DEPENDENCIES
// - serde / toml — TOML deserialisation.
// - stream_manager::StreamConfig — canonical stream descriptor.
// END_DEPENDENCIES
// END_AI_HEADER

use serde::Deserialize;
use crate::stream_manager::StreamConfig;

// START_STREAMS_CONF_SCHEMA

/// purpose: Top-level TOML document for /etc/bsdos/streams.conf.
/// input: TOML text from filesystem.
/// output: Vec<StreamEntry> accessible via .streams.
#[derive(Debug, Deserialize)]
pub struct StreamsConf {
    #[serde(default)]
    pub streams: Vec<StreamEntry>,
}

/// purpose: One [[streams]] section — declaration for a single stream.
/// Fields map directly to StreamConfig; `args` is forwarded as the URL parameter.
#[derive(Debug, Deserialize)]
pub struct StreamEntry {
    /// Unique stream identifier, used in Zenoh topic paths.
    pub app_id: String,
    /// App name recognised by spawn_app(): "foot", "chrome", "cog", "cowork", etc.
    pub command: String,
    /// If true, stream is started automatically at daemon startup.
    #[serde(default)]
    pub autostart: bool,
    /// Optional URL / app-dir argument forwarded to the app (default: empty string).
    #[serde(default)]
    pub args: String,
}

// END_STREAMS_CONF_SCHEMA

// START_LOAD_STREAMS_CONF

/// purpose: Parse a streams.conf TOML file and return autostart StreamConfigs.
/// input:   path — filesystem path of the TOML config file (e.g. /etc/bsdos/streams.conf).
/// output:  Ok(Vec<StreamConfig>) — only entries with autostart = true are included.
///          Err(Box<dyn std::error::Error>) — IO or TOML parse failure.
/// sideEffects: reads filesystem; no writes; no network.
/// callerContract: caller should check file existence before calling; absent file
///                 should be handled as a signal to fall back to BSDOS_AUTOSTREAM.
pub fn load_streams_conf(path: &str) -> Result<Vec<StreamConfig>, Box<dyn std::error::Error>> {
    let content = std::fs::read_to_string(path)
        .map_err(|e| -> Box<dyn std::error::Error> {
            Box::new(std::io::Error::new(
                e.kind(),
                format!("streams.conf read {}: {}", path, e),
            ))
        })?;

    let conf: StreamsConf = toml::from_str(&content)
        .map_err(|e| -> Box<dyn std::error::Error> {
            Box::new(std::io::Error::new(
                std::io::ErrorKind::InvalidData,
                format!("streams.conf parse {}: {}", path, e),
            ))
        })?;

    let configs = conf.streams
        .into_iter()
        .filter(|e| e.autostart)
        .map(|e| StreamConfig {
            app_id: e.app_id,
            app:    e.command,
            url:    e.args,
            ..StreamConfig::default()
        })
        .collect();

    Ok(configs)
}

// END_LOAD_STREAMS_CONF

// START_AUTOSTREAM_CONFIGS

/// purpose: Build autostart StreamConfigs from BSDOS_AUTOSTREAM env var string.
/// input:   autostream — comma-separated "app_id:command:optional_url" entries.
/// output:  Vec<StreamConfig> — one entry per valid token; malformed tokens are skipped.
/// sideEffects: eprintln for skipped malformed entries.
/// note:    Mirrors the inline parsing in main.rs; extracted here so both paths are DRY.
pub fn parse_autostream_env(autostream: &str) -> Vec<StreamConfig> {
    let mut configs = Vec::new();
    for entry in autostream.split(',') {
        let entry = entry.trim();
        if entry.is_empty() { continue; }
        let parts: Vec<&str> = entry.splitn(3, ':').collect();
        if parts.len() < 2 {
            eprintln!("[streams_conf] skipping malformed BSDOS_AUTOSTREAM entry: {}", entry);
            continue;
        }
        configs.push(StreamConfig {
            app_id: parts[0].to_string(),
            app:    parts[1].to_string(),
            url:    parts.get(2).copied().unwrap_or("about:blank").to_string(),
            ..StreamConfig::default()
        });
    }
    configs
}

// END_AUTOSTREAM_CONFIGS

// START_RESOLVE_AUTOSTART

/// purpose: Resolve the autostart stream list — prefer streams.conf, fall back to BSDOS_AUTOSTREAM.
/// input:   none (reads BSDOS_STREAMS_CONF and BSDOS_AUTOSTREAM from environment).
/// output:  Vec<StreamConfig> ready to pass to StreamManager::start_stream().
/// sideEffects: reads filesystem, eprintln diagnostics.
/// precedence:  BSDOS_STREAMS_CONF (or default /etc/bsdos/streams.conf) > BSDOS_AUTOSTREAM > empty.
pub fn resolve_autostart() -> Vec<StreamConfig> {
    let conf_path = std::env::var("BSDOS_STREAMS_CONF")
        .unwrap_or_else(|_| "/etc/bsdos/streams.conf".to_string());

    if std::path::Path::new(&conf_path).exists() {
        match load_streams_conf(&conf_path) {
            Ok(cfgs) => {
                eprintln!("[streams_conf] loaded {} autostart stream(s) from {}", cfgs.len(), conf_path);
                return cfgs;
            }
            Err(e) => {
                eprintln!("[streams_conf] WARN: failed to parse {}: {} — falling back to BSDOS_AUTOSTREAM", conf_path, e);
            }
        }
    } else {
        eprintln!("[streams_conf] {} not found — using BSDOS_AUTOSTREAM", conf_path);
    }

    // Fallback: BSDOS_AUTOSTREAM env var
    match std::env::var("BSDOS_AUTOSTREAM").ok().filter(|s| !s.is_empty()) {
        Some(v) => {
            let cfgs = parse_autostream_env(&v);
            eprintln!("[streams_conf] BSDOS_AUTOSTREAM: {} stream(s)", cfgs.len());
            cfgs
        }
        None => {
            eprintln!("[streams_conf] no streams.conf and no BSDOS_AUTOSTREAM — no autostart streams");
            Vec::new()
        }
    }
}

// END_RESOLVE_AUTOSTART

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_autostream_env_valid() {
        let cfgs = parse_autostream_env("appTerminal:foot,appBrowser:cog:about:blank");
        assert_eq!(cfgs.len(), 2);
        assert_eq!(cfgs[0].app_id, "appTerminal");
        assert_eq!(cfgs[0].app, "foot");
        assert_eq!(cfgs[1].app_id, "appBrowser");
        assert_eq!(cfgs[1].url, "about:blank");
    }

    #[test]
    fn test_parse_autostream_env_skip_malformed() {
        let cfgs = parse_autostream_env("onlyone,,goodOne:foot");
        // "onlyone" has no colon → skipped; empty → skipped; "goodOne:foot" → ok
        assert_eq!(cfgs.len(), 1);
        assert_eq!(cfgs[0].app_id, "goodOne");
    }

    #[test]
    fn test_load_streams_conf_parse() {
        let toml = r#"
[[streams]]
app_id    = "appTerminal"
command   = "foot"
autostart = true
args      = ""

[[streams]]
app_id    = "appBrowser"
command   = "cog"
autostart = false
args      = "about:blank"
"#;
        // Write to a temp file
        let tmp = "/tmp/test_streams_conf.toml";
        std::fs::write(tmp, toml).expect("write temp file");
        let cfgs = load_streams_conf(tmp).expect("load_streams_conf");
        // Only autostart=true entries returned
        assert_eq!(cfgs.len(), 1);
        assert_eq!(cfgs[0].app_id, "appTerminal");
        assert_eq!(cfgs[0].app, "foot");
        let _ = std::fs::remove_file(tmp);
    }

    // --- New tests for F3 coverage ---

    /// purpose: all entries have autostart=false → load_streams_conf returns empty vec.
    /// input:   TOML with two [[streams]] both having autostart=false.
    /// output:  Ok(Vec<StreamConfig>) with len == 0.
    #[test]
    fn test_load_conf_autostart_false() {
        let toml = r#"
[[streams]]
app_id    = "appA"
command   = "foot"
autostart = false
args      = ""

[[streams]]
app_id    = "appB"
command   = "cog"
autostart = false
args      = "about:blank"
"#;
        let tmp = "/tmp/test_sc_all_false.toml";
        std::fs::write(tmp, toml).expect("write temp file");
        let result = load_streams_conf(tmp);
        let _ = std::fs::remove_file(tmp);
        let cfgs = result.expect("load_streams_conf should succeed");
        assert_eq!(cfgs.len(), 0, "no autostart entries expected");
    }

    // Mutex to serialize all tests that mutate BSDOS_STREAMS_CONF / BSDOS_AUTOSTREAM.
    // Rust runs tests in parallel threads; std::env is process-global so mutations race.
    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    /// purpose: BSDOS_STREAMS_CONF points to a valid temp file → resolve_autostart returns 1 entry.
    /// input:   TOML with one autostart=true entry; env var set to temp file path.
    /// output:  Vec<StreamConfig> len == 1 with expected app_id.
    /// sideEffects: sets and restores BSDOS_STREAMS_CONF env var; serialised via ENV_LOCK.
    #[test]
    fn test_resolve_autostart_file_override() {
        let _guard = ENV_LOCK.lock().expect("env lock");

        let toml = r#"
[[streams]]
app_id    = "testStream"
command   = "foot"
autostart = true
args      = ""
"#;
        let tmp = "/tmp/test_sc_resolve_override.toml";
        std::fs::write(tmp, toml).expect("write temp file");

        std::env::set_var("BSDOS_STREAMS_CONF", tmp);
        std::env::remove_var("BSDOS_AUTOSTREAM");

        let cfgs = resolve_autostart();

        std::env::remove_var("BSDOS_STREAMS_CONF");
        let _ = std::fs::remove_file(tmp);

        assert_eq!(cfgs.len(), 1, "expected 1 autostart entry from file");
        assert_eq!(cfgs[0].app_id, "testStream");
        assert_eq!(cfgs[0].app, "foot");
    }

    /// purpose: BSDOS_STREAMS_CONF points to nonexistent file; BSDOS_AUTOSTREAM is set → fallback works.
    /// input:   BSDOS_STREAMS_CONF=/nonexistent/path; BSDOS_AUTOSTREAM="fbApp:foot:".
    /// output:  Vec<StreamConfig> len == 1 with app_id "fbApp".
    /// sideEffects: sets and restores env vars; serialised via ENV_LOCK.
    #[test]
    fn test_resolve_autostart_fallback_env() {
        let _guard = ENV_LOCK.lock().expect("env lock");

        std::env::set_var("BSDOS_STREAMS_CONF", "/tmp/bsdos_test_nonexistent_streams.toml");
        std::env::set_var("BSDOS_AUTOSTREAM", "fbApp:foot:");

        let cfgs = resolve_autostart();

        std::env::remove_var("BSDOS_STREAMS_CONF");
        std::env::remove_var("BSDOS_AUTOSTREAM");

        assert_eq!(cfgs.len(), 1, "expected 1 fallback entry from BSDOS_AUTOSTREAM");
        assert_eq!(cfgs[0].app_id, "fbApp");
        assert_eq!(cfgs[0].app, "foot");
    }

    /// purpose: neither BSDOS_STREAMS_CONF nor BSDOS_AUTOSTREAM is set → empty vec.
    /// input:   BSDOS_STREAMS_CONF points to absent path; BSDOS_AUTOSTREAM removed.
    /// output:  Vec<StreamConfig> len == 0.
    /// sideEffects: sets and restores env vars; serialised via ENV_LOCK.
    #[test]
    fn test_resolve_autostart_both_absent() {
        let _guard = ENV_LOCK.lock().expect("env lock");

        std::env::set_var("BSDOS_STREAMS_CONF", "/tmp/bsdos_test_definitely_absent_xyz.toml");
        std::env::remove_var("BSDOS_AUTOSTREAM");

        let cfgs = resolve_autostart();

        std::env::remove_var("BSDOS_STREAMS_CONF");

        assert_eq!(cfgs.len(), 0, "expected empty vec when no conf source is present");
    }

    /// purpose: URL with colons inside is preserved intact via splitn(3,':').
    /// input:   "appBrowser:chrome:https://example.com:8080" — url part contains colons.
    /// output:  url == "https://example.com:8080".
    #[test]
    fn test_parse_url_with_colons() {
        let cfgs = parse_autostream_env("appBrowser:chrome:https://example.com:8080");
        assert_eq!(cfgs.len(), 1);
        assert_eq!(cfgs[0].app_id, "appBrowser");
        assert_eq!(cfgs[0].app, "chrome");
        assert_eq!(cfgs[0].url, "https://example.com:8080");
    }
}
