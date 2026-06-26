// START_AI_HEADER
// MODULE: lifecycled/src/zenoh_bridge.rs
// PURPOSE: Zenoh transport bridge for bsdOS lifecycle daemon — subscribe to
//          bsdos/ctl/lifecycle commands and publish status responses.
// INTENT: Allow bsdos-core (or any Zenoh peer) to FREEZE/THAW/STATUS jails
//         over the existing Zenoh mesh without requiring a Unix socket connection.
//         Complements the Unix socket interface; both run concurrently.
// DEPENDENCIES: zenoh (workspace), serde_json (workspace),
//               crate::{StateMap, AppState, freeze_application, thaw_application}
// PUBLIC_API: run_zenoh_bridge()
// END_AI_HEADER

// Zenoh bridge for lifecycle control.
//
// Topics:
//   Sub: bsdos/ctl/lifecycle   — receives text commands (FREEZE/THAW/STATUS)
//   Pub: bsdos/lifecycled/status — publishes JSON status responses
//
// Command format (UTF-8 text, no strict newline required):
//   FREEZE <app_id>
//   THAW   <app_id>
//   STATUS           (returns all tracked jails)
//
// Response format on bsdos/lifecycled/status (UTF-8 JSON):
//   {"cmd":"FREEZE","app_id":"appBrowser","ok":true,"msg":"..."}
//   {"cmd":"STATUS","ok":true,"jails":[{"app_id":"...","jid":7,"state":"frozen","pids":[101,102]},…]}
//
// Zenoh session config: defaults to peer mode, no listen endpoint (pure
// subscriber). Set LIFECYCLED_ZENOH_PEER=tcp/<ip>:7447 to connect to
// bsdos-core router. Multicast scouting is disabled (hangs on QEMU user-net).

use crate::{freeze_application, thaw_application, AppState, StateMap};
use serde_json::json;
use std::time::Duration;
use std::sync::Arc;

// ENV var — connect endpoint for the Zenoh router (optional).
const ENV_ZENOH_PEER: &str = "LIFECYCLED_ZENOH_PEER";

// build_zenoh_config:start
//   purpose: Build a minimal Zenoh peer config for the lifecycle bridge —
//            no listen endpoint, optional connect peer from env, scouting off.
//   input:  none (reads LIFECYCLED_ZENOH_PEER from environment)
//   output: Result<zenoh::Config, String>
//   sideEffects: reads environment variable LIFECYCLED_ZENOH_PEER
fn build_zenoh_config() -> Result<zenoh::Config, String> {
    let mut cfg = zenoh::Config::default();

    // Peer mode — subscribe/publish only, no routing.
    cfg.insert_json5("mode", "\"peer\"")
        .map_err(|e| format!("[zenoh_bridge] set mode: {e}"))?;

    // Disable multicast scouting — hangs on QEMU user-net.
    cfg.insert_json5("scouting/multicast/enabled", "false")
        .map_err(|e| format!("[zenoh_bridge] scouting config: {e}"))?;

    // Optional: connect to bsdos-core router.
    if let Ok(peer) = std::env::var(ENV_ZENOH_PEER) {
        if !peer.is_empty() {
            cfg.insert_json5("connect/endpoints", &format!("[\"{peer}\"]"))
                .map_err(|e| format!("[zenoh_bridge] connect config: {e}"))?;
            eprintln!("[zenoh_bridge] connecting to peer: {peer}");
        }
    }

    Ok(cfg)
}
// build_zenoh_config:end

// run_zenoh_bridge:start
//   purpose: Open a Zenoh session, subscribe to bsdos/ctl/lifecycle, dispatch
//            FREEZE/THAW/STATUS commands using the shared StateMap, publish
//            JSON results to bsdos/lifecycled/status. Runs until session drops.
//   input:  states — shared StateMap (same map used by the Unix socket server)
//   output: Result<(), Box<dyn std::error::Error + Send + Sync>>
//   sideEffects: opens Zenoh session, subscribes to topic, publishes responses,
//                calls freeze_application/thaw_application, logs to stderr
pub async fn run_zenoh_bridge(
    states: StateMap,
) -> Result<(), Box<dyn std::error::Error + Send + Sync>> {
    let config = build_zenoh_config()
        .map_err(|e| format!("[zenoh_bridge] config error: {e}"))?;

    eprintln!("[zenoh_bridge] opening Zenoh session...");

    let raw_session = tokio::time::timeout(
        Duration::from_secs(15),
        zenoh::open(config),
    )
    .await
    .map_err(|_| "[zenoh_bridge] zenoh::open timed out after 15s")?
    .map_err(|e| format!("[zenoh_bridge] zenoh::open failed: {e}"))?;
    let session: Arc<zenoh::Session> = Arc::new(raw_session);

    eprintln!("[zenoh_bridge] session open, subscribing to bsdos/ctl/lifecycle");

    let subscriber = (*session)
        .declare_subscriber("bsdos/ctl/lifecycle")
        .await
        .map_err(|e| format!("[zenoh_bridge] subscribe failed: {e}"))?;

    let publisher = (*session)
        .declare_publisher("bsdos/lifecycled/status")
        .await
        .map_err(|e| format!("[zenoh_bridge] publisher failed: {e}"))?;

    eprintln!("[zenoh_bridge] ready — sub=bsdos/ctl/lifecycle pub=bsdos/lifecycled/status");

    loop {
        let sample = match subscriber.recv_async().await {
            Ok(s) => s,
            Err(e) => {
                eprintln!("[zenoh_bridge] subscriber recv error: {e}");
                break;
            }
        };

        // Extract payload as UTF-8 string.
        let line = sample
            .payload()
            .try_to_string()
            .map(|s| s.to_string())
            .unwrap_or_default();
        let line = line.trim().to_string();

        if line.is_empty() {
            continue;
        }

        eprintln!("[zenoh_bridge] received: {line}");

        let response_json = dispatch_zenoh_cmd(&line, &states).await;

        let response_bytes = serde_json::to_vec(&response_json)
            .unwrap_or_else(|_| b"{}".to_vec());

        if let Err(e) = publisher.put(response_bytes.as_slice()).await {
            eprintln!("[zenoh_bridge] publish failed: {e}");
        }
    }

    eprintln!("[zenoh_bridge] subscriber loop exited");
    Ok(())
}
// run_zenoh_bridge:end

// dispatch_zenoh_cmd:start
//   purpose: Parse a lifecycle command string and dispatch to FREEZE/THAW/STATUS.
//            Returns a serde_json::Value suitable for Zenoh publish.
//   input:  line — command text (e.g. "FREEZE appBrowser"); states — StateMap
//   output: serde_json::Value with "ok", "cmd", and "msg" or "jails" fields
//   sideEffects: calls freeze_application / thaw_application / reads StateMap
async fn dispatch_zenoh_cmd(line: &str, states: &StateMap) -> serde_json::Value {
    let parts: Vec<&str> = line.splitn(3, ' ').collect();
    let cmd = parts.first().copied().unwrap_or("");

    match cmd {
        "FREEZE" => {
            let app_id = parts.get(1).copied().unwrap_or("");
            match freeze_application(app_id, states).await {
                Ok(msg) => json!({ "cmd": "FREEZE", "app_id": app_id, "ok": true,  "msg": msg }),
                Err(e)  => json!({ "cmd": "FREEZE", "app_id": app_id, "ok": false, "err": e   }),
            }
        }

        "THAW" => {
            let app_id = parts.get(1).copied().unwrap_or("");
            match thaw_application(app_id, states).await {
                Ok(msg) => json!({ "cmd": "THAW", "app_id": app_id, "ok": true,  "msg": msg }),
                Err(e)  => json!({ "cmd": "THAW", "app_id": app_id, "ok": false, "err": e   }),
            }
        }

        "STATUS" => {
            let jails = collect_status(states);
            json!({ "cmd": "STATUS", "ok": true, "jails": jails })
        }

        other => {
            eprintln!("[zenoh_bridge] unknown command: {other}");
            json!({ "cmd": other, "ok": false, "err": "unknown command" })
        }
    }
}
// dispatch_zenoh_cmd:end

// collect_status:start
//   purpose: Snapshot the tracked jails and enrich each with its live kernel jid
//            and PID list, returning a JSON array of {app_id, jid, state, pids[]}.
//   input:  states — shared StateMap reference
//   output: serde_json::Value (JSON array of per-jail status objects)
//   sideEffects: acquires StateMap mutex lock briefly, then calls
//                jail_get(2)/sysctl(2) per jail (FreeBSD; stubs off FreeBSD)
fn collect_status(states: &StateMap) -> serde_json::Value {
    // Snapshot (app_id, state) pairs first, then release the lock before doing
    // any syscalls — never hold the StateMap mutex across jail_get/sysctl.
    let snapshot: Vec<(String, AppState)> = {
        let map = states.lock().unwrap_or_else(|p| p.into_inner());
        map.iter().map(|(id, st)| (id.clone(), st.clone())).collect()
    };

    let entries: Vec<serde_json::Value> = snapshot
        .into_iter()
        .map(|(app_id, state)| {
            let state_str = match state {
                AppState::Running    => "running",
                AppState::Frozen     => "frozen",
                AppState::Hibernated => "hibernated",
                AppState::Dead       => "dead",
            };
            // Resolve live kernel facts; a not-live jail reports jid=-1 / no pids.
            let (jid, pids) = match crate::jail_enum::jid_by_name(&app_id) {
                Ok(jid) => (jid, crate::jail_enum::jail_pids(jid).unwrap_or_default()),
                Err(_) => (-1, Vec::new()),
            };
            json!({ "app_id": app_id, "jid": jid, "state": state_str, "pids": pids })
        })
        .collect();

    serde_json::Value::Array(entries)
}
// collect_status:end
