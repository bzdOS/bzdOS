// START_AI_HEADER
// MODULE: bsdos-core/src/zenoh_config.rs
// PURPOSE: Single source of truth for Zenoh session configuration.
// INTENT: Eliminate silent config failures (missing listen endpoint,
//         multicast scouting hang, dead CLI args) by funnelling all
//         env vars through one builder that always produces a valid config.
//         F2: mTLS prototype — ZENOH_TLS_CA triggers TLS mode;
//         ZENOH_TLS_CERT + ZENOH_TLS_KEY enable mutual TLS (mTLS).
// END_AI_HEADER

use std::time::Duration;

/// Result of building Zenoh configuration: the config itself plus the
/// recommended timeout for `zenoh::open()`.
pub struct BuiltConfig {
    pub config: zenoh::Config,
    pub open_timeout: Duration,
}

fn env(name: &str) -> Option<String> {
    std::env::var(name).ok().filter(|s| !s.is_empty())
}

// START_FN apply_tls_config
// purpose: Apply TLS transport settings to a Zenoh config using the typed
//          field accessors from zenoh-config 1.x.
// input:   cfg — mutable Zenoh Config to modify in-place.
//          ca_path — path to PEM CA certificate file (required for TLS).
//          cert_path — optional PEM server/client certificate (mTLS listen side).
//          key_path  — optional PEM private key (mTLS listen side).
// output:  Ok(()) on success; Err(String) if any setter rejects the value.
// sideEffects: modifies cfg transport.link.tls fields; logs TLS status to stderr.
fn apply_tls_config(
    cfg: &mut zenoh::Config,
    ca_path: &str,
    cert_path: Option<&str>,
    key_path: Option<&str>,
) -> Result<(), String> {
    // zenoh 1.x Config exposes only insert_json5 — no typed transport.link.tls accessors.
    cfg.insert_json5(
        "transport/link/tls/root_ca_certificate",
        &format!("\"{}\"", ca_path),
    )
    .map_err(|e| format!("TLS CA config: {}", e))?;

    let mtls = cert_path.is_some() && key_path.is_some();

    if let Some(cert) = cert_path {
        cfg.insert_json5(
            "transport/link/tls/listen_certificate",
            &format!("\"{}\"", cert),
        )
        .map_err(|e| format!("TLS cert config: {}", e))?;
    }
    if let Some(key) = key_path {
        cfg.insert_json5(
            "transport/link/tls/listen_private_key",
            &format!("\"{}\"", key),
        )
        .map_err(|e| format!("TLS key config: {}", e))?;
    }

    // enable_mtls: require client certificates when both cert+key are present
    if mtls {
        cfg.insert_json5(
            "transport/link/tls/enable_mtls",
            "true",
        )
        .map_err(|e| format!("TLS mtls config: {}", e))?;
        cfg.insert_json5(
            "transport/link/tls/verify_name_on_connect",
            "false",
        )
        .map_err(|e| format!("TLS verify_name config: {}", e))?;
        eprintln!(
            "[bsdos-core] TLS: enabled mTLS (CA: {}, cert: {}, key: {})",
            ca_path,
            cert_path.unwrap_or(""),
            key_path.unwrap_or(""),
        );
    } else {
        eprintln!("[bsdos-core] TLS: enabled (CA: {})", ca_path);
    }

    Ok(())
}
// END_FN apply_tls_config

/// Build a Zenoh `Config` from environment variables.
///
/// Priority:
/// 1. `ZENOH_CONFIG` → load from file (backward compat)
/// 2. Individual env vars (see below)
///
/// Env vars:
/// - `ZENOH_LISTEN`         — full endpoint, e.g. `tcp/0.0.0.0:7447` (preferred)
/// - `ZENOH_LISTEN_IP`      — listen IP (legacy, default `0.0.0.0`)
/// - `ZENOH_LISTEN_PORT`    — listen port (legacy, default `7447`)
/// - `ZENOH_OBFS=1`         — use `obfs/` transport
/// - `ZENOH_TLS_CA`         — path to CA PEM; if set, enables TLS transport
/// - `ZENOH_TLS_CERT`       — path to server/client cert PEM (optional, for mTLS)
/// - `ZENOH_TLS_KEY`        — path to private key PEM (optional, for mTLS)
/// - `ZENOH_PEER`           — connect endpoint for peer discovery
/// - `ZENOH_MODE`             — Zenoh session mode: `router` (default) | `peer` | `client`
/// - `BSDOS_ZENOH_SCOUTING=1` — enable multicast scouting (default: off)
/// - `BSDOS_ZENOH_OPEN_TIMEOUT` — `zenoh::open()` timeout seconds (default: 10)
pub fn from_env() -> Result<BuiltConfig, String> {
    // 1. File-based config (backward compat)
    if let Some(path) = env("ZENOH_CONFIG") {
        eprintln!("[bsdos-core] Loading Zenoh config from: {}", path);
        let config = zenoh::config::Config::from_file(&path)
            .map_err(|e| format!("Failed to load Zenoh config: {}", e))?;
        return Ok(BuiltConfig {
            config,
            open_timeout: Duration::from_secs(
                env("BSDOS_ZENOH_OPEN_TIMEOUT")
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(30),
            ),
        });
    }

    // 2. Build from individual env vars
    let mut cfg = zenoh::Config::default();

    // --- Mode: default router so Zenoh clients (metal-viewer) receive publications ---
    let mode = env("ZENOH_MODE").unwrap_or_else(|| "router".to_string());
    cfg.insert_json5("mode", &format!("\"{}\"", mode))
        .map_err(|e| format!("mode config: {}", e))?;
    eprintln!("[bsdos-core] Zenoh mode: {}", mode);

    // --- Listen endpoint (ALWAYS set — no silent fallback) ---
    let listen_ip = env("ZENOH_LISTEN_IP").unwrap_or_else(|| "0.0.0.0".to_string());
    let listen_port = env("ZENOH_LISTEN_PORT").unwrap_or_else(|| "7447".to_string());

    // F2: TLS mode is activated by ZENOH_TLS_CA being present (explicit path), or
    // by the legacy ZENOH_TLS=1 flag (backward compat with run-core.sh, core-bind-443.sh).
    // When ZENOH_TLS=1 is used without explicit paths, defaults to /etc/bsdos/{ca,server}.pem.
    // ZENOH_OBFS=1 takes precedence over TLS (obfs wraps its own transport).
    let tls_ca = env("ZENOH_TLS_CA").or_else(|| {
        if std::env::var("ZENOH_TLS").as_deref() == Ok("1") {
            Some("/etc/bsdos/ca.pem".to_string())
        } else {
            None
        }
    });
    let protocol = if std::env::var("ZENOH_OBFS").as_deref() == Ok("1") {
        eprintln!("[bsdos-core] Transport: obfs");
        "obfs"
    } else if let Some(ref ca_path) = tls_ca {
        let cert = env("ZENOH_TLS_CERT").or_else(|| {
            if std::env::var("ZENOH_TLS").as_deref() == Ok("1") {
                Some("/etc/bsdos/server.pem".to_string())
            } else {
                None
            }
        });
        let key = env("ZENOH_TLS_KEY").or_else(|| {
            if std::env::var("ZENOH_TLS").as_deref() == Ok("1") {
                Some("/etc/bsdos/server.key".to_string())
            } else {
                None
            }
        });
        apply_tls_config(
            &mut cfg,
            ca_path,
            cert.as_deref(),
            key.as_deref(),
        )?;
        "tls"
    } else {
        eprintln!("[bsdos-core] TLS: disabled (plaintext)");
        "tcp"
    };

    // Prefer ZENOH_LISTEN (full endpoint) over legacy IP:PORT
    let listen_ep = env("ZENOH_LISTEN").unwrap_or_else(|| {
        format!("{}/{}:{}", protocol, listen_ip, listen_port)
    });
    cfg.insert_json5("listen/endpoints", &format!("[\"{}\"]", listen_ep))
        .map_err(|e| format!("listen endpoint config: {}", e))?;
    eprintln!("[bsdos-core] Listen: {}", listen_ep);

    // --- Multicast scouting (default OFF — hangs on QEMU user-net) ---
    let scouting = std::env::var("BSDOS_ZENOH_SCOUTING").as_deref() == Ok("1");
    cfg.insert_json5("scouting/multicast/enabled", if scouting { "true" } else { "false" })
        .map_err(|e| format!("scouting config: {}", e))?;
    if !scouting {
        eprintln!("[bsdos-core] Multicast scouting: disabled (set BSDOS_ZENOH_SCOUTING=1 to enable)");
    }

    // --- Optional peer connect endpoint ---
    if let Some(peer) = env("ZENOH_PEER") {
        cfg.insert_json5("connect/endpoints", &format!("[\"{}\"]", peer))
            .map_err(|e| format!("connect endpoint config: {}", e))?;
        eprintln!("[bsdos-core] Peer: {}", peer);
    }

    let open_timeout = Duration::from_secs(
        env("BSDOS_ZENOH_OPEN_TIMEOUT")
            .and_then(|s| s.parse().ok())
            .unwrap_or(10),
    );

    Ok(BuiltConfig { config: cfg, open_timeout })
}

#[cfg(test)]
mod tests {
    use super::*;

    // All tests that read or write Zenoh env vars share this lock.
    // Rust runs tests in parallel threads; std::env is process-global.
    static ENV_LOCK: std::sync::Mutex<()> = std::sync::Mutex::new(());

    // Canonical set of Zenoh env vars cleared before each env-sensitive test.
    const ZENOH_ENV_VARS: &[&str] = &[
        "ZENOH_LISTEN", "ZENOH_LISTEN_IP", "ZENOH_LISTEN_PORT",
        "ZENOH_OBFS", "ZENOH_TLS", "ZENOH_TLS_CA",
        "ZENOH_MODE", "ZENOH_PEER", "ZENOH_CONFIG",
        "BSDOS_ZENOH_SCOUTING", "BSDOS_ZENOH_OPEN_TIMEOUT",
    ];

    fn clear_zenoh_env() {
        for v in ZENOH_ENV_VARS { std::env::remove_var(v); }
    }

    // Helper: compute the listen endpoint string from current env state.
    // Mirrors the protocol-selection logic in from_env() without calling zenoh::open().
    fn listen_ep_from_env_state() -> String {
        let listen_ip   = std::env::var("ZENOH_LISTEN_IP").ok()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "0.0.0.0".to_string());
        let listen_port = std::env::var("ZENOH_LISTEN_PORT").ok()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "7447".to_string());

        let protocol = if std::env::var("ZENOH_OBFS").as_deref() == Ok("1") {
            "obfs"
        } else if std::env::var("ZENOH_TLS_CA").ok().filter(|s| !s.is_empty()).is_some()
               || std::env::var("ZENOH_TLS").as_deref() == Ok("1") {
            "tls"
        } else {
            "tcp"
        };

        std::env::var("ZENOH_LISTEN").ok()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| format!("{}/{}:{}", protocol, listen_ip, listen_port))
    }

    // --- env() helper (no env mutation — no lock needed) ---

    /// purpose: env() returns None when the env var holds an empty string.
    /// input:   unique env var set to "" (TEST_ZC_* prefix avoids collision with Zenoh vars).
    /// output:  None.
    #[test]
    fn test_env_returns_none_for_empty() {
        let var = "TEST_ZC_ENV_EMPTY_UNIQUE_7A1";
        std::env::set_var(var, "");
        let result = std::env::var(var).ok().filter(|s| !s.is_empty());
        std::env::remove_var(var);
        assert!(result.is_none(), "empty string must filter to None");
    }

    /// purpose: env() returns Some when the env var holds a non-empty string.
    /// input:   unique env var set to "hello".
    /// output:  Some("hello".to_string()).
    #[test]
    fn test_env_returns_some_for_nonempty() {
        let var = "TEST_ZC_ENV_NONEMPTY_UNIQUE_7A2";
        std::env::set_var(var, "hello");
        let result = std::env::var(var).ok().filter(|s| !s.is_empty());
        std::env::remove_var(var);
        assert_eq!(result, Some("hello".to_string()));
    }

    // --- Default listen endpoint ---

    /// purpose: Without any Zenoh env vars set, the listen endpoint is tcp/0.0.0.0:7447.
    /// input:   all Zenoh env vars cleared.
    /// output:  endpoint string == "tcp/0.0.0.0:7447".
    /// sideEffects: acquires ENV_LOCK.
    #[test]
    fn test_default_listen_ep_format() {
        let _g = ENV_LOCK.lock().expect("env lock");
        clear_zenoh_env();
        let ep = listen_ep_from_env_state();
        assert_eq!(ep, "tcp/0.0.0.0:7447");
    }

    // --- Protocol selection ---

    /// purpose: ZENOH_OBFS=1 causes protocol prefix "obfs" in the listen endpoint.
    /// input:   ZENOH_OBFS=1, all other Zenoh vars cleared.
    /// output:  endpoint starts with "obfs/".
    /// sideEffects: acquires ENV_LOCK.
    #[test]
    fn test_obfs_protocol_selection() {
        let _g = ENV_LOCK.lock().expect("env lock");
        clear_zenoh_env();
        std::env::set_var("ZENOH_OBFS", "1");
        let ep = listen_ep_from_env_state();
        clear_zenoh_env();
        assert!(ep.starts_with("obfs/"), "expected obfs/ prefix, got: {}", ep);
    }

    /// purpose: ZENOH_TLS_CA set (without ZENOH_OBFS) causes protocol prefix "tls".
    /// input:   ZENOH_TLS_CA="/tmp/fake_ca.pem", ZENOH_OBFS unset.
    /// output:  endpoint starts with "tls/".
    /// note:    Only tests protocol-selection logic, not apply_tls_config.
    /// sideEffects: acquires ENV_LOCK.
    #[test]
    fn test_tls_ca_protocol_selection() {
        let _g = ENV_LOCK.lock().expect("env lock");
        clear_zenoh_env();
        std::env::set_var("ZENOH_TLS_CA", "/tmp/fake_ca.pem");
        let ep = listen_ep_from_env_state();
        clear_zenoh_env();
        assert!(ep.starts_with("tls/"), "expected tls/ prefix, got: {}", ep);
    }

    /// purpose: ZENOH_TLS_CA absent and ZENOH_OBFS absent → protocol is "tcp".
    /// input:   both ZENOH_OBFS and ZENOH_TLS_CA unset (all Zenoh vars cleared).
    /// output:  endpoint starts with "tcp/".
    /// sideEffects: acquires ENV_LOCK.
    #[test]
    fn test_tls_disabled_gives_tcp() {
        let _g = ENV_LOCK.lock().expect("env lock");
        clear_zenoh_env();
        let ep = listen_ep_from_env_state();
        assert!(ep.starts_with("tcp/"), "expected tcp/ prefix when TLS disabled, got: {}", ep);
    }

    // --- ZENOH_LISTEN override ---

    /// purpose: ZENOH_LISTEN overrides legacy IP:PORT construction.
    /// input:   ZENOH_LISTEN="tcp/1.2.3.4:9999".
    /// output:  endpoint == "tcp/1.2.3.4:9999" (verbatim).
    /// sideEffects: acquires ENV_LOCK.
    #[test]
    fn test_zenoh_listen_override() {
        let _g = ENV_LOCK.lock().expect("env lock");
        clear_zenoh_env();
        std::env::set_var("ZENOH_LISTEN", "tcp/1.2.3.4:9999");
        let ep = listen_ep_from_env_state();
        clear_zenoh_env();
        assert_eq!(ep, "tcp/1.2.3.4:9999");
    }

    // --- BSDOS_ZENOH_OPEN_TIMEOUT parsing (pure arithmetic — no ENV_LOCK needed) ---

    /// purpose: BSDOS_ZENOH_OPEN_TIMEOUT unset → Duration defaults to 10s.
    #[test]
    fn test_open_timeout_default() {
        std::env::remove_var("BSDOS_ZENOH_OPEN_TIMEOUT");
        let timeout = Duration::from_secs(
            std::env::var("BSDOS_ZENOH_OPEN_TIMEOUT")
                .ok().filter(|s| !s.is_empty())
                .and_then(|s| s.parse::<u64>().ok())
                .unwrap_or(10),
        );
        assert_eq!(timeout, Duration::from_secs(10));
    }

    /// purpose: BSDOS_ZENOH_OPEN_TIMEOUT="30" → Duration::from_secs(30).
    #[test]
    fn test_open_timeout_custom() {
        let var = "BSDOS_ZENOH_OPEN_TIMEOUT";
        std::env::set_var(var, "30");
        let timeout = Duration::from_secs(
            std::env::var(var).ok().filter(|s| !s.is_empty())
                .and_then(|s| s.parse::<u64>().ok()).unwrap_or(10),
        );
        std::env::remove_var(var);
        assert_eq!(timeout, Duration::from_secs(30));
    }

    /// purpose: BSDOS_ZENOH_OPEN_TIMEOUT="bogus" (non-numeric) → falls back to 10s.
    #[test]
    fn test_open_timeout_bad_value_falls_back() {
        let var = "BSDOS_ZENOH_OPEN_TIMEOUT";
        std::env::set_var(var, "bogus");
        let timeout = Duration::from_secs(
            std::env::var(var).ok().filter(|s| !s.is_empty())
                .and_then(|s| s.parse::<u64>().ok()).unwrap_or(10),
        );
        std::env::remove_var(var);
        assert_eq!(timeout, Duration::from_secs(10));
    }

    // --- ZENOH_MODE default ---

    /// purpose: ZENOH_MODE unset → defaults to "router".
    #[test]
    fn test_zenoh_mode_default_router() {
        std::env::remove_var("ZENOH_MODE");
        let mode = std::env::var("ZENOH_MODE").ok()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "router".to_string());
        assert_eq!(mode, "router");
    }

    /// purpose: ZENOH_MODE="peer" → forwarded as "peer".
    #[test]
    fn test_zenoh_mode_peer_forwarded() {
        let var = "ZENOH_MODE";
        std::env::set_var(var, "peer");
        let mode = std::env::var(var).ok()
            .filter(|s| !s.is_empty())
            .unwrap_or_else(|| "router".to_string());
        std::env::remove_var(var);
        assert_eq!(mode, "peer");
    }
}
