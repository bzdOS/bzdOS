// START_AI_HEADER
// MODULE: bsdos-core/src/main.rs
// PURPOSE: Zenoh peer daemon for HAL telemetry, Wayland stream forwarding,
//          viewer resize commands, and input delivery into the Wayland tunnel.
// INTENT: Keep the host/guest display and telemetry bridge in one FreeBSD-side
//         process until the stream, input, and telemetry contracts stabilize.
//
// START_INVARIANTS
// - Telemetry publishes to bsdos/telemetry once per second when Zenoh is up.
// - Wayland stream packets remain v1 length-prefixed bytes from the tunnel.
// - Bridge tasks log and retry instead of crashing the daemon on transient IO.
// END_INVARIANTS
//
// START_DEPENDENCIES
// - zenoh peer session for bsdos/* topics.
// - Tokio async runtime for Unix sockets and background bridge tasks.
// - bsdos_core::capnp and bsdos_core::hal for telemetry wire encoding.
// - Optional wlr-randr command for viewer-driven headless output resizing.
// END_DEPENDENCIES
//
// START_PUBLIC_API
// - resize_subscriber(session): bsdos/viewer/size -> wlr-randr.
// - main(): configures Zenoh, starts bridges, and publishes telemetry.
// END_PUBLIC_API
// END_AI_HEADER

use bsdos_core::{capnp, hal, protocol, stream_manager, streams_conf};
use std::sync::Arc;
use std::time::Duration;

/// purpose: Apply viewer size requests to the headless Wayland output.
/// input: session: shared Zenoh session used to subscribe to bsdos/viewer/size.
/// output: never returns unless the subscriber stream ends.
/// sideEffects: subscribes to Zenoh, spawns wlr-randr commands, and writes diagnostics.
/// preconditions: payload format is "WxH@S" where W/H are physical pixels and S is scale.
async fn resize_subscriber(session: std::sync::Arc<zenoh::Session>) {
    use tokio::process::Command;

    let rundir = std::env::var("BSDOS_RUNDIR")
        .unwrap_or_else(|_| "/tmp/wayland-run".to_string());

    let sub = match (*session).declare_subscriber("bsdos/viewer/size").await {
        Ok(s) => s,
        Err(e) => { eprintln!("[core] resize subscriber error: {}", e); return; }
    };
    eprintln!("[core] resize subscriber ready");

    while let Ok(sample) = sub.recv_async().await {
        let size_str = match sample.payload().try_to_string() {
            Ok(s) => s.to_string(),
            Err(_) => continue,
        };
        // Parse "WxH@S" via protocol helper; skip malformed payloads.
        let (w, h, s) = match protocol::parse_size_request(&size_str) {
            Some(v) => v,
            None => continue,
        };
        let (lw, lh) = match protocol::compute_logical_size(w, h, s) {
            Some(v) => v,
            None => continue,
        };

        let mode = format!("{}x{}", lw, lh);
        eprintln!("[core] resize: {} → logical {} → wlr-randr HEADLESS-1 --custom-mode {}", size_str, mode, mode);

        let status = Command::new("wlr-randr")
            .args(["--output", "HEADLESS-1", "--custom-mode", &mode])
            .env("XDG_RUNTIME_DIR", &rundir)
            .env("WAYLAND_DISPLAY", "wayland-0")
            .status()
            .await;

        if let Err(e) = status {
            eprintln!("[core] wlr-randr error: {}", e);
        }
    }
}


/// purpose: Configure the core Zenoh session, start bridge tasks, and publish HAL telemetry.
/// input: process environment variables for Zenoh, transport security, and runtime paths.
/// output: Result error only for startup/configuration failures before the publish loop.
/// sideEffects: opens Zenoh, spawns async bridge tasks, polls the HAL socket, publishes telemetry,
///              runs optional transport security configuration, and writes diagnostics.
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    // ── --version / --check-config early exit ────────────────────────────
    let args: Vec<String> = std::env::args().collect();
    if args.iter().any(|a| a == "--version" || a == "-V") {
        println!("bsdos-core {} ({})", env!("CARGO_PKG_VERSION"), env!("CARGO_PKG_HOMEPAGE"));
        return Ok(());
    }

    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::from_env("RUST_LOG")
        )
        .with_writer(std::io::stderr)
        .init();

    eprintln!("[bsdos-core] v{} starting", env!("CARGO_PKG_VERSION"));

    // ── Phase 4: Unified config (TOML + env overrides) ───────────────────
    let cfg = bsdos_core::config::load();
    bsdos_core::config::print_resolved(&cfg);

    // ── Phase 1: Zenoh config via centralized builder ─────────────────────
    let built = bsdos_core::zenoh_config::from_env()
        .map_err(|e| -> Box<dyn std::error::Error> { e.into() })?;

    // ── Phase 0: Emit READY immediately (degraded mode) ───────────────────
    // Smoke test polls agent PING (primary) or READY (fallback).
    // Emitting READY before Zenoh ensures the daemon is "alive" even if
    // Zenoh is slow to connect. Zenoh retries in background below.
    let degraded_ready = format!(
        "{{\"pid\":{},\"zenoh\":\"pending\",\"streams\":[]}}",
        std::process::id()
    );
    let _ = std::fs::write("/var/run/bsdos-core.ready", &degraded_ready);
    eprintln!("[bsdos-core] READY: {}", degraded_ready);

    // ── Phase 1: Open Zenoh session with retry loop ───────────────────────
    // If Zenoh fails (timeout, network), retry every 5s instead of crashing.
    // This makes the daemon resilient to transient network issues in QEMU.
    eprintln!("[bsdos-core] Opening Zenoh session (timeout {:?}, retry 5s)…", built.open_timeout);
    let session: Arc<zenoh::Session> = loop {
        let config = built.config.clone();
        let open_task = tokio::spawn(async move { zenoh::open(config).await });
        match tokio::time::timeout(built.open_timeout, open_task).await {
            Ok(Ok(Ok(session))) => {
                eprintln!("[bsdos-core] Zenoh session opened");
                break Arc::new(session);
            }
            Ok(Ok(Err(e))) => {
                eprintln!("[bsdos-core] Zenoh open error: {} — retry in 5s", e);
            }
            Ok(Err(e)) => {
                eprintln!("[bsdos-core] Zenoh open task join error: {} — retry in 5s", e);
            }
            Err(_) => {
                eprintln!("[bsdos-core] Zenoh open timeout ({:?}) — retry in 5s", built.open_timeout);
            }
        }
        tokio::time::sleep(Duration::from_secs(5)).await;
    };

    // START_SPAWN_BRIDGE_TASKS
    // Stream manager: dynamic multi-stream lifecycle via Zenoh control commands
    let manager = Arc::new(stream_manager::StreamManager::new(session.clone()));
    
    // Control subscriber: bsdos/ctl/stream/{start,stop,list}
    let mgr_clone = manager.clone();
    let sess_clone = session.clone();
    tokio::spawn(async move {
        ctl_subscriber(sess_clone, mgr_clone).await;
    });

    // Monitor loop: health check + auto-restart dead streams
    let mgr_monitor = manager.clone();
    tokio::spawn(async move {
        mgr_monitor.monitor_loop().await;
    });

    // START_AUTOSTART_STREAMS
    // Resolve autostart list: streams.conf (BSDOS_STREAMS_CONF or /etc/bsdos/streams.conf)
    // takes priority; falls back to BSDOS_AUTOSTREAM env var; falls back to persisted registry.
    // Phase 3: sequential stream startup with per-stream 20s timeout.
    let autostart_cfgs = streams_conf::resolve_autostart();
    if !autostart_cfgs.is_empty() {
        for cfg in autostart_cfgs {
            let app_name = cfg.app_id.clone();
            match tokio::time::timeout(
                Duration::from_secs(20),
                manager.start_stream(cfg),
            ).await {
                Ok(Ok(())) => eprintln!("[sm] {} started", app_name),
                Ok(Err(e))  => eprintln!("[sm] {} failed: {}", app_name, e),
                Err(_)      => eprintln!("[sm] {} start timeout (20s)", app_name),
            }
        }
    } else {
        // No streams.conf and no BSDOS_AUTOSTREAM — restore from Cap'n Proto registry.
        manager.restore_streams().await;
    }
    // END_AUTOSTART_STREAMS

    let session_resize = session.clone();
    tokio::spawn(resize_subscriber(session_resize));
    // END_SPAWN_BRIDGE_TASKS

    // ── Phase 2: Readiness probe — update with Zenoh state ────────────────
    let active = manager.list_streams().await;
    let ready = format!(
        "{{\"pid\":{},\"zenoh\":\"open\",\"streams\":{:?}}}",
        std::process::id(),
        active
    );
    let _ = std::fs::write("/var/run/bsdos-core.ready", &ready);
    eprintln!("[bsdos-core] READY: {}", ready);

    let hal_socket = "/var/run/bsdos-hal.sock";

    // START_TELEMETRY_PUBLISH_LOOP
    loop {
        // Fetch telemetry from HAL
        let (uptime, battery, cpu) = hal::fetch_telemetry(hal_socket);

        // Encode as Cap'n Proto
        let encoded = capnp::encode(uptime, battery, cpu);

        // Publish telemetry to Zenoh
        match (*session).put("bsdos/telemetry", &encoded[..]).await {
            Ok(_) => {},
            Err(e) => eprintln!("[core] publish error (retrying next sec): {}", e),
        }

        // Publish health status every loop (1s)
        let health = manager.health_snapshot("open").await;
        match (*session).put("bsdos/health", health.as_bytes()).await {
            Ok(_) => {},
            Err(e) => eprintln!("[core] health publish error: {}", e),
        }

        eprintln!("[core] uptime={}s battery={}% cpu={}%", uptime, battery, cpu);

        // Wait 1 second before next publish
        tokio::time::sleep(Duration::from_secs(1)).await;
    }
    // END_TELEMETRY_PUBLISH_LOOP
}

// START_CTL_SUBSCRIBER
//   purpose: Listen for stream control commands on Zenoh
//   topics: bsdos/ctl/stream/start, bsdos/ctl/stream/stop, bsdos/ctl/stream/list
//   payload: JSON (serde_json or manual parse)
async fn ctl_subscriber(session: Arc<zenoh::Session>, manager: Arc<stream_manager::StreamManager>) {
    let sub = match (*session).declare_subscriber("bsdos/ctl/stream/*").await {
        Ok(s) => s,
        Err(e) => {
            eprintln!("[ctl] subscriber error: {}", e);
            return;
        }
    };
    eprintln!("[ctl] listening on bsdos/ctl/stream/*");

    while let Ok(sample) = sub.recv_async().await {
        let topic = sample.key_expr().as_str();
        let payload = sample.payload();
        let text = payload.try_to_string()
            .map(|s| s.to_string())
            .unwrap_or_default();

        eprintln!("[ctl] {} → {}", topic, text);

        if topic.ends_with("/start") {
            let parts: Vec<&str> = text.splitn(3, ':').collect();
            if parts.len() >= 2 {
                let cfg = stream_manager::StreamConfig {
                    app_id: parts[0].to_string(),
                    app: parts[1].to_string(),
                    url: parts.get(2).unwrap_or(&"about:blank").to_string(),
                    ..Default::default()
                };
                if let Err(e) = manager.start_stream(cfg).await {
                    eprintln!("[ctl] start failed: {}", e);
                }
            }
        } else if topic.ends_with("/stop") {
            let app_id = text.trim();
            if let Err(e) = manager.stop_stream(app_id).await {
                eprintln!("[ctl] stop failed: {}", e);
            }
        } else if topic.ends_with("/list") {
            let streams = manager.list_streams().await;
            eprintln!("[ctl] active streams: {:?}", streams);
        }
    }
}
// END_CTL_SUBSCRIBER
