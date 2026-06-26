// START_AI_HEADER
// MODULE: bsdos-core/src/stream_manager.rs
// PURPOSE: Dynamic stream lifecycle — spawn/stop cage+tunnel+app per Zenoh command.
// INTENT: Replace hardcoded single-stream pipeline with N parallel isolated streams.
// DEPENDENCIES: tokio::process (spawn cage/tunnel/app), zenoh (control + data),
//               wayland_forwarder (per-stream forwarder task).
// PUBLIC_API:
//   - StreamManager::new(session) → manager
//   - manager.start_stream(cmd) → Result<(), StreamError>
//   - manager.stop_stream(app_id) → Result<(), StreamError>
//   - manager.list_streams() → Vec<String>
//   - StreamError — typed error enum for all lifecycle failures
// END_AI_HEADER

use std::collections::HashMap;
use std::path::PathBuf;
use std::process::{Command, Stdio};
use std::sync::Arc;
use tokio::task::JoinHandle;
use tokio::time::Duration;

// START_STREAM_ERROR
/// purpose: Typed error variants for stream lifecycle operations.
/// Replaces ad-hoc Result<T, String> to enable match-based error handling.
#[derive(Debug, thiserror::Error)]
pub enum StreamError {
    /// app_id is already active in the registry
    #[error("stream already running: {0}")]
    AlreadyRunning(String),
    /// app_id not found during stop
    #[error("stream not found: {0}")]
    NotFound(String),
    /// process spawn failed
    #[error("spawn failed: {0}")]
    SpawnFailed(String),
    /// wayland/stream socket did not appear within timeout
    #[error("socket timeout: {0}")]
    SocketTimeout(String),
    /// Cap'n Proto registry parse/write error
    #[error("registry error: {0}")]
    Registry(String),
    /// I/O error (filesystem operations)
    #[error("io error: {0}")]
    Io(#[from] std::io::Error),
}
// END_STREAM_ERROR

// START_STREAM_CONFIG
/// purpose: Configuration for a single stream instance.
#[derive(Clone)]
pub struct StreamConfig {
    pub app_id: String,
    pub app: String,
    pub url: String,
    pub user: String,
    pub width: u32,
    pub height: u32,
}

impl Default for StreamConfig {
    fn default() -> Self {
        Self {
            app_id: "appBrowser".to_string(),
            app: "firefox".to_string(),
            url: "about:blank".to_string(),
            user: "freebsd".to_string(),
            width: 400,
            height: 683,
        }
    }
}
// END_STREAM_CONFIG

// START_STREAM_INSTANCE
#[cfg(feature = "with-bridge")]
/// purpose: Runtime state of one active stream.
pub struct StreamInstance {
    pub app_id: String,
    pub cfg: StreamConfig,
    pub cage: std::process::Child,
    pub tunnel: std::process::Child,
    pub app: std::process::Child,
    pub rundir: PathBuf,
    pub forwarder_handle: JoinHandle<()>,
    pub input_handle: JoinHandle<()>,
    pub resize_handle: JoinHandle<()>,
}

#[cfg(feature = "with-bridge")]
impl StreamInstance {
    fn rundir_for(app_id: &str) -> PathBuf {
        PathBuf::from(format!("/tmp/bsdos/streams/{}", app_id))
    }

    #[allow(dead_code)]
    fn stream_sock(&self) -> PathBuf {
        self.rundir.join("wayland-stream.sock")
    }
}
// END_STREAM_INSTANCE

// START_STREAM_MANAGER
#[cfg(feature = "with-bridge")]
/// purpose: Registry + lifecycle controller for all active streams.
pub struct StreamManager {
    session: Arc<zenoh::Session>,
    streams: tokio::sync::Mutex<HashMap<String, StreamInstance>>,
}

#[cfg(feature = "with-bridge")]
impl StreamManager {
    pub fn new(session: Arc<zenoh::Session>) -> Self {
        Self {
            session,
            streams: tokio::sync::Mutex::new(HashMap::new()),
        }
    }

    // START_SM_START
    //   purpose: Spawn cage + tunnel + app + forwarder for one stream
    //   input: StreamConfig (app_id, app, url, user, dimensions)
    //   output: Ok(()) or Err(StreamError) with typed diagnostic
    //   sideEffects: creates rundir, spawns 3 processes, spawns tokio tasks
    //   preconditions: app_id not already in registry
    pub async fn start_stream(&self, cfg: StreamConfig) -> Result<(), StreamError> {
        let app_id = cfg.app_id.clone();
        let rundir = StreamInstance::rundir_for(&app_id);

        {
            let streams = self.streams.lock().await;
            if streams.contains_key(&app_id) {
                return Err(StreamError::AlreadyRunning(app_id.clone()));
            }
        }

        eprintln!("[sm] starting stream: {}", app_id);

        // ── Async process spawning using std::process + tokio::time::sleep.
        //    std::thread::sleep (nanosleep) hangs in QEMU KVM; tokio::time::sleep
        //    (kevent-based) works. fork() from std::process::Command is fast
        //    (fork+exec) so blocking the worker thread briefly is acceptable. ──
        let procs = match spawn_processes(&cfg, &rundir).await {
            Ok(p) => p,
            Err(e) => {
                eprintln!("[sm] {} failed: {}", app_id, e);
                return Err(e);
            }
        };

        eprintln!("[sm] {} stream active (cage={} tunnel={} app={})",
            app_id, procs.cage_pid, procs.tunnel_pid, procs.app_pid);

        // 4. Spawn forwarder task (async — Zenoh I/O)
        let session = self.session.clone();
        let fwd_app_id = app_id.clone();
        let fwd_sock = rundir.join("wayland-stream.sock").to_string_lossy().to_string();
        let forwarder_handle = tokio::spawn(async move {
            crate::wayland_forwarder::wayland_forwarder(session, fwd_app_id, fwd_sock).await;
        });

        // 5. Spawn per-stream input handler
        let input_session = self.session.clone();
        let input_app_id = app_id.clone();
        let input_rundir = rundir.clone();
        let input_handle = tokio::spawn(async move {
            stream_input_handler(input_session, input_app_id, input_rundir).await;
        });

        // 6. Spawn per-stream resize handler
        let resize_session = self.session.clone();
        let resize_app_id = app_id.clone();
        let resize_rundir = rundir.clone();
        let resize_handle = tokio::spawn(async move {
            stream_resize_handler(resize_session, resize_app_id, resize_rundir).await;
        });

        // Register
        let instance = StreamInstance {
            app_id: app_id.clone(),
            cfg: cfg.clone(),
            cage: procs.cage,
            tunnel: procs.tunnel,
            app: procs.app,
            rundir,
            forwarder_handle,
            input_handle,
            resize_handle,
        };

        let mut streams = self.streams.lock().await;
        streams.insert(app_id.clone(), instance);

        let _ = add_to_registry(&cfg);

        Ok(())
    }
    // END_SM_START

    // START_SM_STOP
    //   purpose: Kill all processes for a stream and clean up
    //   input: app_id
    //   sideEffects: SIGKILL + reap all children, abort forwarder, rm rundir
    pub async fn stop_stream(&self, app_id: &str) -> Result<(), StreamError> {
        let mut instance = {
            let mut streams = self.streams.lock().await;
            streams.remove(app_id)
                .ok_or_else(|| StreamError::NotFound(app_id.to_string()))?
        };

        eprintln!("[sm] stopping stream: {}", app_id);

        // SIGKILL all processes (std::process::Child API)
        let _ = instance.cage.kill();
        let _ = instance.tunnel.kill();
        let _ = instance.app.kill();

        // Chrome double-forks: the tracked su PID may be dead; kill real processes too.
        if instance.cfg.app == "chrome" || instance.cfg.app == "chromium" {
            let _ = std::process::Command::new("pkill")
                .args(["-U", &instance.cfg.user, "-f", "chrome.*bsdos-chrome"])
                .status();
        }

        // Reap all children
        let _ = instance.cage.wait();
        let _ = instance.tunnel.wait();
        let _ = instance.app.wait();

        // Abort tasks
        instance.forwarder_handle.abort();
        instance.input_handle.abort();
        instance.resize_handle.abort();

        // Cleanup rundir
        let _ = std::fs::remove_dir_all(&instance.rundir);

        eprintln!("[sm] stream {} stopped", app_id);

        let _ = remove_from_registry(app_id);

        Ok(())
    }
    // END_SM_STOP

    // START_SM_LIST
    //   purpose: Return snapshot of all active streams
    pub async fn list_streams(&self) -> Vec<String> {
        let streams = self.streams.lock().await;
        streams.keys().cloned().collect()
    }
    // END_SM_LIST

    // START_SM_HEALTH
    //   purpose: Return pipeline health as JSON string for bsdos/health topic
    //   output: JSON with core PID, zenoh state, active streams + process PIDs
    pub async fn health_snapshot(&self, zenoh_state: &str) -> String {
        let mut streams = self.streams.lock().await;
        let stream_list: Vec<String> = streams.iter_mut().map(|(id, inst)| {
            let cage_alive = inst.cage.try_wait().ok().flatten().is_none();
            let tunnel_alive = inst.tunnel.try_wait().ok().flatten().is_none();
            let app_alive = inst.app.try_wait().ok().flatten().is_none();
            format!(
                r#"{{"id":"{}","cage":{},"tunnel":{},"app":{}}}"#,
                id,
                if cage_alive { inst.cage.id().to_string() } else { "0".into() },
                if tunnel_alive { inst.tunnel.id().to_string() } else { "0".into() },
                if app_alive { inst.app.id().to_string() } else { "0".into() },
            )
        }).collect();
        format!(
            r#"{{"pid":{},"zenoh":"{}","streams":[{}]}}"#,
            std::process::id(),
            zenoh_state,
            stream_list.join(",")
        )
    }
    // END_SM_HEALTH

    // START_SM_RESTORE
    //   purpose: Restore streams from persistent registry on startup
    //   sideEffects: starts each persisted stream
    pub async fn restore_streams(&self) {
        match list_registry() {
            Ok(configs) => {
                if configs.is_empty() {
                    eprintln!("[sm] no persisted streams to restore");
                    return;
                }
                eprintln!("[sm] restoring {} stream(s) from registry", configs.len());
                for cfg in configs {
                    let app_id = cfg.app_id.clone();
                    eprintln!("[sm] restoring stream: {}", app_id);
                    if let Err(e) = self.start_stream(cfg).await {
                        eprintln!("[sm] restore failed for {}: {}", app_id, e);
                    }
                }
            }
            Err(e) => {
                eprintln!("[sm] registry load error: {}", e);
            }
        }
    }
    // END_SM_RESTORE

    // START_SM_MONITOR
    //   purpose: Periodically check if cage/tunnel/app processes are alive;
    //            restart the stream if any component died.
    //   interval: 10 seconds
    //   sideEffects: calls stop_stream + start_stream on dead streams
    pub async fn monitor_loop(self: Arc<Self>) {
        let mut interval = tokio::time::interval(Duration::from_secs(10));
        loop {
            interval.tick().await;

            // Check liveness and collect dead stream IDs + their configs
            let dead: Vec<(String, StreamConfig)> = {
                let mut streams = self.streams.lock().await;
                let mut dead = Vec::new();
                for (app_id, inst) in streams.iter_mut() {
                    let cage_dead = inst.cage.try_wait().ok().flatten().is_some();
                    let tunnel_dead = inst.tunnel.try_wait().ok().flatten().is_some();
                    // Chrome double-forks: launcher exits, real browser gets new PID.
                    // Track via pgrep on user's processes instead of child PID.
                    let app_dead = if inst.cfg.app == "chrome" || inst.cfg.app == "chromium" {
                        let out = std::process::Command::new("pgrep")
                            .args(["-U", &inst.cfg.user, "-f", "chrome.*bsdos-chrome"])
                            .output();
                        match out {
                            Ok(o) => o.status.code() != Some(0),
                            Err(_) => false,
                        }
                    } else {
                        inst.app.try_wait().ok().flatten().is_some()
                    };
                    if cage_dead || tunnel_dead || app_dead {
                        eprintln!("[sm] monitor: {} died (cage={} tunnel={} app={})",
                            app_id, cage_dead, tunnel_dead, app_dead);
                        dead.push((app_id.clone(), inst.cfg.clone()));
                    }
                }
                dead
            };

            // Stop + restart each dead stream
            for (app_id, cfg) in dead {
                let _ = self.stop_stream(&app_id).await;
                eprintln!("[sm] monitor: restarting {}", app_id);
                tokio::time::sleep(Duration::from_secs(1)).await;
                if let Err(e) = self.start_stream(cfg).await {
                    eprintln!("[sm] monitor: restart failed for {}: {}", app_id, e);
                }
            }
        }
    }
    // END_SM_MONITOR
}
// END_STREAM_MANAGER

// START_SPAWN_PROCESSES
#[cfg(feature = "with-bridge")]
struct SpawnedProcesses {
    cage: std::process::Child,
    tunnel: std::process::Child,
    app: std::process::Child,
    cage_pid: u32,
    tunnel_pid: u32,
    app_pid: u32,
}

#[cfg(feature = "with-bridge")]
async fn spawn_processes(cfg: &StreamConfig, rundir: &std::path::Path) -> Result<SpawnedProcesses, StreamError> {
    let app_id = &cfg.app_id;

    // Create isolated rundir
    std::fs::create_dir_all(rundir)
        .map_err(|e| StreamError::SpawnFailed(format!("mkdir {}: {}", rundir.display(), e)))?;
    std::fs::set_permissions(rundir, std::os::unix::fs::PermissionsExt::from_mode(0o777))
        .map_err(|e| StreamError::SpawnFailed(format!("chmod {}: {}", rundir.display(), e)))?;

    // 1. Spawn cage
    eprintln!("[sm] {} spawning cage…", app_id);
    let mut cage = Command::new("/usr/local/bin/cage")
        .env("XDG_RUNTIME_DIR", rundir)
        .env("WLR_BACKENDS", "headless")
        .env("WLR_RENDERER", "pixman")
        .env("WLR_HEADLESS_OUTPUTS", "1")
        .env("LIBSEAT_BACKEND", "noop")
        .arg("--")
        .arg("/usr/local/bin/wl-keepalive")
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| StreamError::SpawnFailed(format!("cage spawn: {}", e)))?;
    let cage_pid = cage.id();
    eprintln!("[sm] {} cage pid={}", app_id, cage_pid);

    // Wait for cage socket (10s) — tokio::time::sleep (kevent) works in QEMU
    let wl_sock = rundir.join("wayland-0");
    let mut waited = 0u32;
    while !wl_sock.exists() {
        if waited >= 20 {
            let _ = cage.kill();
            let _ = cage.wait();
            return Err(StreamError::SocketTimeout(format!("{} cage socket timeout", app_id)));
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
        waited += 1;
    }
    eprintln!("[sm] {} cage ready", app_id);
    let _ = std::fs::set_permissions(&wl_sock, std::os::unix::fs::PermissionsExt::from_mode(0o777));

    // 2. Spawn wayland-tunnel
    eprintln!("[sm] {} spawning tunnel…", app_id);
    let mut tunnel = Command::new("/usr/local/bin/wayland-tunnel")
        .env("XDG_RUNTIME_DIR", rundir)
        .env("WLSTREAM_COMPOSITOR_SOCK", rundir.join("wayland-0"))
        .env("WLSTREAM_WAYLAND_SOCK", rundir.join("wayland-ghost-0"))
        .env("WLSTREAM_STREAM_SOCK", rundir.join("wayland-stream.sock"))
        .env("WLSTREAM_INPUT_SOCK", rundir.join("input.sock"))
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|e| { let _ = cage.kill(); StreamError::SpawnFailed(format!("tunnel spawn: {}", e)) })?;
    let tunnel_pid = tunnel.id();
    eprintln!("[sm] {} tunnel pid={}", app_id, tunnel_pid);

    // Wait for stream socket (10s)
    let stream_sock = rundir.join("wayland-stream.sock");
    waited = 0;
    while !stream_sock.exists() {
        if waited >= 20 {
            let _ = cage.kill(); let _ = cage.wait();
            let _ = tunnel.kill(); let _ = tunnel.wait();
            return Err(StreamError::SocketTimeout(format!("{} tunnel socket timeout", app_id)));
        }
        tokio::time::sleep(Duration::from_millis(500)).await;
        waited += 1;
    }
    eprintln!("[sm] {} tunnel ready", app_id);

    // 3. Spawn app
    eprintln!("[sm] {} spawning app ({})…", app_id, cfg.app);
    let app = spawn_app(cfg, rundir).map_err(|e| {
        let _ = cage.kill(); let _ = cage.wait();
        let _ = tunnel.kill(); let _ = tunnel.wait();
        e
    })?;
    let app_pid = app.id();

    Ok(SpawnedProcesses { cage, tunnel, app, cage_pid, tunnel_pid, app_pid })
}
// END_SPAWN_PROCESSES

// START_WAIT_SOCKET
#[cfg(feature = "with-bridge")]
#[allow(dead_code)]
/// purpose: Poll for a Unix socket file to appear (up to `max_half_seconds` × 0.5s).
/// input: path — socket file to wait for; max_half_seconds — poll limit.
/// output: Ok(()) when the socket appears; Err(StreamError::SocketTimeout) on timeout.
/// sideEffects: sleeps up to max_half_seconds × 500ms.
async fn wait_socket(path: &std::path::Path, max_half_seconds: u32) -> Result<(), StreamError> {
    let mut i = 0;
    while i < max_half_seconds {
        if path.exists() {
            return Ok(());
        }
        tokio::time::sleep(std::time::Duration::from_millis(500)).await;
        i += 1;
    }
    Err(StreamError::SocketTimeout(format!("timeout waiting for socket: {}", path.display())))
}
// END_WAIT_SOCKET

// START_SPAWN_APP
#[cfg(feature = "with-bridge")]
/// purpose: Spawn the Wayland application (firefox or foot).
/// input: StreamConfig + rundir path
/// output: std::process::Child or Err(StreamError::SpawnFailed)
/// sideEffects: spawns child process as `cfg.user`
fn spawn_app(cfg: &StreamConfig, rundir: &std::path::Path) -> Result<std::process::Child, StreamError> {
    let display = "wayland-ghost-0";

    match cfg.app.as_str() {
        "firefox" => {
            let child = Command::new("su")
                .arg("-m").arg(&cfg.user)
                .arg("-c")
                .arg(format!(
                    "exec env XDG_RUNTIME_DIR='{}' WAYLAND_DISPLAY={} MOZ_ENABLE_WAYLAND=1 HOME=/home/{} /usr/local/bin/firefox --new-instance --no-remote '{}'",
                    rundir.display(), display, cfg.user, cfg.url
                ))
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|e| StreamError::SpawnFailed(format!("app spawn: {}", e)))?;
            Ok(child)
        }
        "foot" => {
            let child = Command::new("env")
                .env("XDG_RUNTIME_DIR", rundir)
                .env("WAYLAND_DISPLAY", display)
                .arg("/usr/local/bin/foot")
                .arg("sh").arg("-c").arg("while true; do date; uptime; sleep 1; done")
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|e| StreamError::SpawnFailed(format!("app spawn: {}", e)))?;
            Ok(child)
        }
        "chrome" | "chromium" => {
            // Chromium via Mesa swrast (software GL, but GPU code path in Skia).
            // LIBGL_ALWAYS_SOFTWARE=true + MESA_GL_VERSION_OVERRIDE=3.3 gives Skia
            // the GPU rendering path → LCD subpixel antialiasing vs --disable-gpu's
            // grayscale AA. --force-device-scale-factor=2 matches Retina viewer (2x).
            // exec collapses sh→env so su tracks the Chrome launcher PID directly.
            let child = Command::new("su")
                .arg("-m").arg(&cfg.user)
                .arg("-c")
                .arg(format!(
                    "exec env XDG_RUNTIME_DIR='{}' WAYLAND_DISPLAY={} HOME=/home/{} LIBGL_ALWAYS_SOFTWARE=true MESA_GL_VERSION_OVERRIDE=3.3 /usr/local/bin/chrome --ozone-platform=wayland --no-sandbox --no-first-run --no-default-browser-check --user-data-dir=/home/{}/.bsdos-chrome --force-device-scale-factor=2 --new-window '{}'",
                    rundir.display(), display, cfg.user, cfg.user, cfg.url
                ))
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|e| StreamError::SpawnFailed(format!("app spawn: {}", e)))?;
            Ok(child)
        }
        "cowork" | "claude-desktop" => {
            // Claude Desktop (Electron) via FreeBSD electron42 (devel/electron42 from tagattie)
            // + aaddrick-patched asar at app dir (cfg.url, default /opt/claude-cowork).
            // Platform normalized to linux in the app's own frame-fix-entry. No header-spoof.
            // Fallback chain: electron42 → electron39 → electron37 (first found wins).
            let app_dir = if cfg.url.is_empty() || cfg.url == "about:blank" {
                "/opt/claude-cowork".to_string()
            } else { cfg.url.clone() };
            let electron = ["/usr/local/bin/electron42",
                            "/usr/local/bin/electron39",
                            "/usr/local/bin/electron37"]
                .iter()
                .find(|p| std::path::Path::new(p).exists())
                .copied()
                .unwrap_or("/usr/local/bin/electron42");
            let child = Command::new("su")
                .arg("-m").arg(&cfg.user)
                .arg("-c")
                .arg(format!(
                    "exec env XDG_RUNTIME_DIR='{}' WAYLAND_DISPLAY={} HOME=/home/{} COWORK_VM_BACKEND=host GIO_USE_VFS=local GSETTINGS_BACKEND=memory LIBGL_ALWAYS_SOFTWARE=true MESA_GL_VERSION_OVERRIDE=3.3 {} --no-sandbox --ozone-platform=wayland --force-device-scale-factor=2 {}",
                    rundir.display(), display, cfg.user, electron, app_dir
                ))
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|e| StreamError::SpawnFailed(format!("app spawn: {}", e)))?;
            Ok(child)
        }
        "wpewebkit-fdo" | "phantom-browser" | "cog" => {
            // Cog (WPE WebKit FDO) — appBrowser in 2-stream demo.
            // pkg: wpewebkit-fdo; binary: cog; --platform=fdo for Wayland.
            let url = if cfg.url.is_empty() || cfg.url == "about:blank" {
                "about:blank".to_string()
            } else {
                cfg.url.clone()
            };
            let child = Command::new("su")
                .arg("-m").arg(&cfg.user)
                .arg("-c")
                .arg(format!(
                    "exec env XDG_RUNTIME_DIR='{}' WAYLAND_DISPLAY={} HOME=/home/{} /usr/local/bin/cog --platform=fdo '{}'",
                    rundir.display(), display, cfg.user, url
                ))
                .stdout(Stdio::null())
                .stderr(Stdio::null())
                .spawn()
                .map_err(|e| StreamError::SpawnFailed(format!("app spawn: {}", e)))?;
            Ok(child)
        }
        other => Err(StreamError::SpawnFailed(format!("unknown app: {}", other))),
    }
}
// END_SPAWN_APP

// START_STREAM_INPUT_HANDLER
#[cfg(feature = "with-bridge")]
//   purpose: Forward keyboard/pointer events from per-app Zenoh topics to the
//            tunnel's input.sock for this stream.
//   topics: bsdos/app/{app_id}/input/keyboard, bsdos/app/{app_id}/input/pointer
//   sideEffects: connects to input.sock, writes Wayland tunnel input frames
pub async fn stream_input_handler(
    session: Arc<zenoh::Session>,
    app_id: String,
    rundir: PathBuf,
) {
    use tokio::io::AsyncWriteExt;
    use tokio::net::UnixStream;

    let tag = format!("[{}:input]", app_id);
    let input_sock = rundir.join("input.sock");

    let kb_topic = format!("bsdos/app/{}/input/keyboard", app_id);
    let ptr_topic = format!("bsdos/app/{}/input/pointer", app_id);

    let kb_sub = match (*session).declare_subscriber(kb_topic.clone()).await {
        Ok(s) => s,
        Err(e) => { eprintln!("{} subscribe error: {}", tag, e); return; }
    };
    let ptr_sub = match (*session).declare_subscriber(ptr_topic.clone()).await {
        Ok(s) => s,
        Err(e) => { eprintln!("{} subscribe error: {}", tag, e); return; }
    };
    eprintln!("{} listening on {}/{}", tag, kb_topic, ptr_topic);

    loop {
        // Wait for tunnel to create the input.sock
        if !input_sock.exists() {
            tokio::time::sleep(Duration::from_secs(1)).await;
            continue;
        }

        let mut stream = match UnixStream::connect(&input_sock).await {
            Ok(s) => s,
            Err(_) => {
                tokio::time::sleep(Duration::from_secs(1)).await;
                continue;
            }
        };
        eprintln!("{} connected to {}", tag, input_sock.display());

        loop {
            tokio::select! {
                sample = kb_sub.recv_async() => {
                    if let Ok(s) = sample {
                        let payload = s.payload().to_bytes();
                        eprintln!("{} ZENOH KB event {} bytes", tag, payload.len());
                        if let Some(buf) = crate::protocol::format_keyboard_payload(&payload) {
                            if let Err(e) = stream.write_all(&buf).await {
                                eprintln!("{} write error: {}", tag, e);
                                break;
                            }
                        }
                    }
                }
                sample = ptr_sub.recv_async() => {
                    if let Ok(s) = sample {
                        let payload = s.payload().to_bytes();
                        eprintln!("{} ZENOH PTR event {} bytes", tag, payload.len());
                        if let Some(buf) = crate::protocol::format_pointer_payload(&payload) {
                            if let Err(e) = stream.write_all(&buf).await {
                                eprintln!("{} write error: {}", tag, e);
                                break;
                            }
                        }
                    }
                }
                // Detect EOF from relay: when the relay thread exits it closes the
                // accepted fd. readable() fires immediately on EOF; try_read returning
                // 0 (or WouldBlock — not EOF) distinguishes the two cases.
                _ = stream.readable() => {
                    let mut buf = [0u8; 1];
                    match stream.try_read(&mut buf) {
                        Ok(0) => {
                            eprintln!("{} relay closed connection (EOF), reconnecting", tag);
                            break;
                        }
                        Err(ref e) if e.kind() == std::io::ErrorKind::WouldBlock => {}
                        Err(e) => {
                            eprintln!("{} socket error: {}, reconnecting", tag, e);
                            break;
                        }
                        Ok(_) => {} // unexpected byte from tunnel — ignore
                    }
                }
            }
        }
        eprintln!("{} tunnel disconnected, waiting for reconnect", tag);
    }
}
// END_STREAM_INPUT_HANDLER

// START_STREAM_RESIZE_HANDLER
#[cfg(feature = "with-bridge")]
//   purpose: Listen for viewer resize requests on per-app Zenoh topic and
//            apply them via wlr-randr to this stream's headless output.
//   topic: bsdos/app/{app_id}/viewer/size
//   sideEffects: spawns wlr-randr commands with per-stream XDG_RUNTIME_DIR
async fn stream_resize_handler(
    session: Arc<zenoh::Session>,
    app_id: String,
    rundir: PathBuf,
) {
    let tag = format!("[{}:resize]", app_id);
    let size_topic = format!("bsdos/app/{}/viewer/size", app_id);

    let sub = match (*session).declare_subscriber(size_topic.clone()).await {
        Ok(s) => s,
        Err(e) => { eprintln!("{} subscribe error: {}", tag, e); return; }
    };
    eprintln!("{} listening on {}", tag, size_topic);

    while let Ok(sample) = sub.recv_async().await {
        eprintln!("{} ZENOH SIZE event", tag);
        let size_str = match sample.payload().try_to_string() {
            Ok(s) => s.to_string(),
            Err(_) => continue,
        };
        // Viewer sends physical pixel dimensions (drawableSize) with scale factor.
        // Set headless output to PHYSICAL pixels so Chrome renders at full resolution.
        // Chrome gets --force-device-scale-factor matching the viewer's backingScaleFactor.
        let (w, h, _s) = match crate::protocol::parse_size_request(&size_str) {
            Some(v) => v,
            None => continue,
        };
        if w == 0 || h == 0 { continue; }

        let mode = format!("{}x{}", w, h);
        eprintln!("{} {} → wlr-randr {}", tag, size_str, mode);

        let _ = std::process::Command::new("wlr-randr")
            .args(["--output", "HEADLESS-1", "--custom-mode", &mode])
            .env("XDG_RUNTIME_DIR", &rundir)
            .env("WAYLAND_DISPLAY", "wayland-0")
            .status();
    }
}
// END_STREAM_RESIZE_HANDLER

// compute_randr_mode:start
//   purpose: Compute wlr-randr mode string from viewer size payload ("WxH@S" → "WxH").
//            Uses physical pixel dimensions directly (no divide by scale) so the headless
//            output matches the viewer's Retina drawable 1:1. Chrome is launched with
//            --force-device-scale-factor matching the viewer's backingScaleFactor.
//   input:  size_str: viewer size string e.g. "2560x1440@2".
//   output: Some("2560x1440") on success; None if malformed or zero dimensions.
//   sideEffects: none (pure).
pub fn compute_randr_mode(size_str: &str) -> Option<String> {
    let (w, h, _s) = crate::protocol::parse_size_request(size_str)?;
    if w == 0 || h == 0 { return None; }
    Some(format!("{}x{}", w, h))
}
// compute_randr_mode:end

// START_STATE_PERSISTENCE

use crate::stream_capnp;

const REGISTRY_PATH: &str = "/var/db/bsdos/streams.capnp";
const REGISTRY_VERSION: u32 = 1;

// Internal: parse registry file → Vec<StreamConfig>
fn load_registry_vec() -> Result<Vec<StreamConfig>, StreamError> {
    use capnp::serialize;
    use std::io::Read;

    let path = std::path::Path::new(REGISTRY_PATH);
    if !path.exists() {
        return Ok(Vec::new());
    }
    let mut file = std::fs::File::open(path)
        .map_err(|e| StreamError::Registry(format!("open registry: {}", e)))?;
    let mut buf = Vec::new();
    file.read_to_end(&mut buf)
        .map_err(|e| StreamError::Registry(format!("read registry: {}", e)))?;

    let msg = serialize::read_message(&mut &buf[..], capnp::message::ReaderOptions::new())
        .map_err(|e| StreamError::Registry(format!("parse registry: {}", e)))?;
    let reg = msg.get_root::<stream_capnp::stream_registry::Reader>()
        .map_err(|e| StreamError::Registry(format!("registry root: {}", e)))?;
    let streams = reg.get_streams()
        .map_err(|e| StreamError::Registry(format!("registry streams: {}", e)))?;

    let mut out = Vec::with_capacity(streams.len() as usize);
    for i in 0..streams.len() {
        let s = streams.get(i);
        let c = s.get_config().map_err(|e| StreamError::Registry(format!("config[{}]: {}", i, e)))?;
        out.push(StreamConfig {
            app_id: c.get_app_id().map_err(|e| StreamError::Registry(format!("app_id[{}]: {}", i, e)))?.to_str().map_err(|e| StreamError::Registry(format!("app_id[{}] utf8: {}", i, e)))?.to_owned(),
            app:    c.get_app().map_err(|e| StreamError::Registry(format!("app[{}]: {}", i, e)))?.to_str().map_err(|e| StreamError::Registry(format!("app[{}] utf8: {}", i, e)))?.to_owned(),
            url:    c.get_url().map_err(|e| StreamError::Registry(format!("url[{}]: {}", i, e)))?.to_str().map_err(|e| StreamError::Registry(format!("url[{}] utf8: {}", i, e)))?.to_owned(),
            user:   c.get_user().map_err(|e| StreamError::Registry(format!("user[{}]: {}", i, e)))?.to_str().map_err(|e| StreamError::Registry(format!("user[{}] utf8: {}", i, e)))?.to_owned(),
            width:  c.get_width(),
            height: c.get_height(),
        });
    }
    Ok(out)
}

// Internal: serialize Vec<StreamConfig> → registry file (atomic write)
fn save_registry_vec(configs: &[StreamConfig]) -> Result<(), StreamError> {
    use capnp::serialize;

    if let Some(p) = std::path::Path::new(REGISTRY_PATH).parent() {
        std::fs::create_dir_all(p).map_err(|e| StreamError::Registry(format!("mkdir registry dir: {}", e)))?;
    }

    let mut msg = capnp::message::Builder::new_default();
    {
        let mut reg = msg.init_root::<stream_capnp::stream_registry::Builder>();
        reg.set_version(REGISTRY_VERSION);
        let mut sl = reg.init_streams(configs.len() as u32);
        for (i, cfg) in configs.iter().enumerate() {
            let mut st = sl.reborrow().get(i as u32);
            {
                let mut c = st.reborrow().init_config();
                c.set_app_id(&cfg.app_id);
                c.set_app(&cfg.app);
                c.set_url(&cfg.url);
                c.set_user(&cfg.user);
                c.set_width(cfg.width);
                c.set_height(cfg.height);
            }
            st.set_status(stream_capnp::stream_state::Status::Running);
            st.set_started_at(0);
            st.set_restart_count(0);
        }
    }

    let tmp = format!("{}.tmp", REGISTRY_PATH);
    let mut f = std::fs::File::create(&tmp).map_err(|e| StreamError::Registry(format!("create tmp: {}", e)))?;
    serialize::write_message(&mut f, &msg).map_err(|e| StreamError::Registry(format!("write registry: {}", e)))?;
    f.sync_all().map_err(|e| StreamError::Registry(format!("fsync: {}", e)))?;
    drop(f);
    std::fs::rename(&tmp, REGISTRY_PATH).map_err(|e| StreamError::Registry(format!("rename: {}", e)))?;
    Ok(())
}

// add_to_registry:start
//   purpose: Upsert a stream into the persistent registry (idempotent).
//   input: StreamConfig
//   output: Ok(()) on success, Err(StreamError) on IO/parse failure
//   sideEffects: atomic rewrite of /var/db/bsdos/streams.capnp
pub fn add_to_registry(cfg: &StreamConfig) -> Result<(), StreamError> {
    let mut configs = load_registry_vec()?;
    configs.retain(|c| c.app_id != cfg.app_id);
    configs.push(cfg.clone());
    save_registry_vec(&configs)
}
// add_to_registry:end

// remove_from_registry:start
//   purpose: Remove a stream from the persistent registry.
//   input: app_id
//   output: Ok(()) on success, Err(StreamError) if not found or IO failure
//   sideEffects: atomic rewrite of /var/db/bsdos/streams.capnp
pub fn remove_from_registry(app_id: &str) -> Result<(), StreamError> {
    let mut configs = load_registry_vec()?;
    let before = configs.len();
    configs.retain(|c| c.app_id != app_id);
    if configs.len() == before {
        return Err(StreamError::NotFound(format!("stream {} not in registry", app_id)));
    }
    save_registry_vec(&configs)
}
// remove_from_registry:end

// list_registry:start
//   purpose: Return all persisted StreamConfigs; empty Vec on first boot.
//   output: Ok(Vec<StreamConfig>) or Err(StreamError) on parse failure
pub fn list_registry() -> Result<Vec<StreamConfig>, StreamError> {
    load_registry_vec()
}
// list_registry:end

// decode_stream_config:start
//   purpose: Parse Cap'n Proto StreamConfig from a Zenoh PUT payload.
//   input: raw bytes from bsdos/ctl/stream/add
//   output: StreamConfig or Err(StreamError::Registry) on parse error
pub fn decode_stream_config(bytes: &[u8]) -> Result<StreamConfig, StreamError> {
    use capnp::serialize;
    let msg = serialize::read_message(&mut &bytes[..], capnp::message::ReaderOptions::new())
        .map_err(|e| StreamError::Registry(format!("parse StreamConfig: {}", e)))?;
    let c = msg.get_root::<stream_capnp::stream_config::Reader>()
        .map_err(|e| StreamError::Registry(format!("StreamConfig root: {}", e)))?;
    Ok(StreamConfig {
        app_id: c.get_app_id().map_err(|e| StreamError::Registry(format!("app_id: {}", e)))?.to_str().map_err(|e| StreamError::Registry(format!("app_id utf8: {}", e)))?.to_owned(),
        app:    c.get_app().map_err(|e| StreamError::Registry(format!("app: {}", e)))?.to_str().map_err(|e| StreamError::Registry(format!("app utf8: {}", e)))?.to_owned(),
        url:    c.get_url().map_err(|e| StreamError::Registry(format!("url: {}", e)))?.to_str().map_err(|e| StreamError::Registry(format!("url utf8: {}", e)))?.to_owned(),
        user:   c.get_user().map_err(|e| StreamError::Registry(format!("user: {}", e)))?.to_str().map_err(|e| StreamError::Registry(format!("user utf8: {}", e)))?.to_owned(),
        width:  c.get_width(),
        height: c.get_height(),
    })
}
// decode_stream_config:end

// decode_stream_remove:start
//   purpose: Parse Cap'n Proto StreamRemove from a Zenoh PUT payload.
//   input: raw bytes
//   output: app_id string or Err(StreamError::Registry) on parse error
pub fn decode_stream_remove(bytes: &[u8]) -> Result<String, StreamError> {
    use capnp::serialize;
    let msg = serialize::read_message(&mut &bytes[..], capnp::message::ReaderOptions::new())
        .map_err(|e| StreamError::Registry(format!("parse StreamRemove: {}", e)))?;
    let r = msg.get_root::<stream_capnp::stream_remove::Reader>()
        .map_err(|e| StreamError::Registry(format!("StreamRemove root: {}", e)))?;
    Ok(r.get_app_id().map_err(|e| StreamError::Registry(format!("app_id: {}", e)))?.to_str().map_err(|e| StreamError::Registry(format!("app_id utf8: {}", e)))?.to_owned())
}
// decode_stream_remove:end

// encode_stream_list:start
//   purpose: Encode a slice of StreamConfigs as Cap'n Proto StreamList bytes.
//   input: active stream configs
//   output: serialized bytes; empty Vec on encode error
pub fn encode_stream_list(configs: &[StreamConfig]) -> Vec<u8> {
    use capnp::serialize;
    let mut msg = capnp::message::Builder::new_default();
    {
        let list = msg.init_root::<stream_capnp::stream_list::Builder>();
        let mut sl = list.init_streams(configs.len() as u32);
        for (i, cfg) in configs.iter().enumerate() {
            let mut st = sl.reborrow().get(i as u32);
            {
                let mut c = st.reborrow().init_config();
                c.set_app_id(&cfg.app_id);
                c.set_app(&cfg.app);
                c.set_url(&cfg.url);
                c.set_user(&cfg.user);
                c.set_width(cfg.width);
                c.set_height(cfg.height);
            }
            st.set_status(stream_capnp::stream_state::Status::Running);
        }
    }
    let mut buf = Vec::new();
    if let Err(e) = serialize::write_message(&mut buf, &msg) {
        eprintln!("[sm] encode_stream_list error: {}", e);
    }
    buf
}
// encode_stream_list:end

// END_STATE_PERSISTENCE

#[cfg(test)]
mod tests {
    use super::*;

    // ── StreamConfig defaults ─────────────────────────────────────────────

    #[test]
    fn stream_config_default_fields() {
        let cfg = StreamConfig::default();
        assert_eq!(cfg.app_id, "appBrowser");
        assert_eq!(cfg.app, "firefox");
        assert_eq!(cfg.url, "about:blank");
        assert_eq!(cfg.user, "freebsd");
        assert_eq!(cfg.width, 400);
        assert_eq!(cfg.height, 683);
    }

    #[test]
    fn stream_config_clone_is_equal() {
        let cfg = StreamConfig::default();
        let cloned = cfg.clone();
        assert_eq!(cfg.app_id, cloned.app_id);
        assert_eq!(cfg.width, cloned.width);
    }

    // ── compute_randr_mode — pure function ────────────────────────────────

    #[test]
    fn randr_mode_requires_scale_suffix() {
        // parse_size_request uses split_once('@') — no @ means None
        assert_eq!(compute_randr_mode("1280x720"), None);
    }

    #[test]
    fn randr_mode_with_at_one() {
        assert_eq!(compute_randr_mode("1280x720@1"), Some("1280x720".into()));
    }

    #[test]
    fn randr_mode_with_scale_factor() {
        assert_eq!(compute_randr_mode("2560x1440@2"), Some("2560x1440".into()));
    }

    #[test]
    fn randr_mode_4k_with_scale() {
        assert_eq!(compute_randr_mode("3840x2160@3"), Some("3840x2160".into()));
    }

    #[test]
    fn randr_mode_malformed_string() {
        assert_eq!(compute_randr_mode("notvalid"), None);
    }

    #[test]
    fn randr_mode_empty_string() {
        assert_eq!(compute_randr_mode(""), None);
    }

    #[test]
    fn randr_mode_zero_width_rejected() {
        assert_eq!(compute_randr_mode("0x720"), None);
    }

    #[test]
    fn randr_mode_zero_height_rejected() {
        assert_eq!(compute_randr_mode("1280x0"), None);
    }

    // ── Cap'n Proto encode/decode round-trips ─────────────────────────────

    fn make_config(app_id: &str, app: &str, url: &str) -> StreamConfig {
        StreamConfig {
            app_id: app_id.into(),
            app: app.into(),
            url: url.into(),
            user: "freebsd".into(),
            width: 1280,
            height: 720,
        }
    }

    fn encode_one_config(cfg: &StreamConfig) -> Vec<u8> {
        use crate::stream_capnp;
        use capnp::serialize;
        let mut msg = capnp::message::Builder::new_default();
        {
            let mut c = msg.init_root::<stream_capnp::stream_config::Builder>();
            c.set_app_id(&cfg.app_id);
            c.set_app(&cfg.app);
            c.set_url(&cfg.url);
            c.set_user(&cfg.user);
            c.set_width(cfg.width);
            c.set_height(cfg.height);
        }
        let mut buf = Vec::new();
        serialize::write_message(&mut buf, &msg).expect("serialize");
        buf
    }

    fn encode_remove(app_id: &str) -> Vec<u8> {
        use crate::stream_capnp;
        use capnp::serialize;
        let mut msg = capnp::message::Builder::new_default();
        {
            let mut r = msg.init_root::<stream_capnp::stream_remove::Builder>();
            r.set_app_id(app_id);
        }
        let mut buf = Vec::new();
        serialize::write_message(&mut buf, &msg).expect("serialize");
        buf
    }

    #[test]
    fn decode_stream_config_roundtrip() {
        let original = make_config("appTerminal", "foot", "");
        let bytes = encode_one_config(&original);
        let decoded = decode_stream_config(&bytes).expect("decode");
        assert_eq!(decoded.app_id, "appTerminal");
        assert_eq!(decoded.app, "foot");
        assert_eq!(decoded.url, "");
        assert_eq!(decoded.user, "freebsd");
        assert_eq!(decoded.width, 1280);
        assert_eq!(decoded.height, 720);
    }

    #[test]
    fn decode_stream_config_with_url() {
        let original = make_config("appBrowser", "chromium", "https://example.com");
        let bytes = encode_one_config(&original);
        let decoded = decode_stream_config(&bytes).expect("decode");
        assert_eq!(decoded.url, "https://example.com");
    }

    #[test]
    fn decode_stream_config_invalid_bytes_errors() {
        let err = decode_stream_config(b"this is not capnp data");
        assert!(err.is_err());
    }

    #[test]
    fn decode_stream_config_empty_bytes_errors() {
        let err = decode_stream_config(b"");
        assert!(err.is_err());
    }

    #[test]
    fn decode_stream_remove_roundtrip() {
        let bytes = encode_remove("appBrowser");
        let decoded = decode_stream_remove(&bytes).expect("decode");
        assert_eq!(decoded, "appBrowser");
    }

    #[test]
    fn decode_stream_remove_invalid_bytes_errors() {
        let err = decode_stream_remove(b"garbage");
        assert!(err.is_err());
    }

    #[test]
    fn encode_stream_list_empty_produces_bytes() {
        let bytes = encode_stream_list(&[]);
        assert!(!bytes.is_empty(), "cap'n proto header must be present");
    }

    #[test]
    fn encode_stream_list_single_entry() {
        let cfg = make_config("appTerminal", "foot", "");
        let bytes = encode_stream_list(&[cfg]);
        assert!(!bytes.is_empty());
    }

    #[test]
    fn encode_stream_list_multiple_entries_larger_than_single() {
        let single = encode_stream_list(&[make_config("appA", "foot", "")]);
        let double = encode_stream_list(&[
            make_config("appA", "foot", ""),
            make_config("appB", "chromium", "about:blank"),
        ]);
        assert!(double.len() > single.len(), "two entries must be larger than one");
    }
}
