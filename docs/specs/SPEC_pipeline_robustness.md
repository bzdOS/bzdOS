# SPEC: Pipeline Robustness Refactor

> Created: 2026-06-18 by claude-host
> Status: **DRAFT** — awaiting review
> Supersedes: ad-hoc fixes from session 2026-06-17/18

## Problem Statement

The bsdOS streaming pipeline (cage → tunnel → bsdos-core → Zenoh → viewer)
has **6 fragility layers** discovered during the 2026-06-17/18 sessions.
Each layer can break silently, producing a black viewer with no diagnostics.

## Root Causes

<!-- START_RC_PROD_VERSION_DRIFT -->
### RC-1: Production version drift
- **Symptom:** Production server (dev-vm) runs OLD bsdos-core (legacy
  single-stream, `/usr/local/bin/`). Squirrel images run NEW bsdos-core
  (stream_manager, `/opt/bsdos/bin/`). Different env vars, different topics,
  different rc.d scripts.
- **Impact:** Fixes applied to Squirrel images don't reach production.
  Viewer connects to production → broken topics, missing features.
- **Fix:** Single deployment pipeline. `deploy-bsdos-myvm.sh` copies the
  SAME binary from `artefacts/squirrel/<arch>/bin/` to production.
<!-- END_RC_PROD_VERSION_DRIFT -->

<!-- START_RC_PROCESS_SUPERVISION -->
### RC-2: No process supervision
- **Symptom:** cage, wayland-tunnel, and Chrome are started manually with
  `nohup ... &`. When any dies, the pipeline breaks silently. bsdos-core
  shows "no data for 10s" but doesn't restart dependencies.
- **Impact:** Black viewer after hours of uptime. No auto-recovery.
- **Fix:** bsdos-core's `stream_manager` already manages cage+tunnel+app
  lifecycle with `monitor_loop` (restart on death). Deploy the NEW
  bsdos-core to production so `stream_manager` handles supervision.
<!-- END_RC_PROCESS_SUPERVISION -->

<!-- START_RC_TOPIC_MISMATCH -->
### RC-3: Zenoh topic mismatch (resize)
- **Symptom:** Viewer publishes resize to `bsdos/app/{app_id}/viewer/size`.
  Legacy bsdos-core subscribes to `bsdos/viewer/size`. Resolution never
  applied → text rendered at 1280x720, upscaled to 2560x1440 → jagged.
- **Impact:** Poor font rendering on Retina displays. Viewer size requests
  ignored.
- **Fix:** bsdos-core must subscribe to `bsdos/app/+/viewer/size` (wildcard)
  OR the viewer must publish to `bsdos/viewer/size` (legacy compat). Prefer
  the wildcard — aligns with per-app architecture.
<!-- END_RC_TOPIC_MISMATCH -->

<!-- START_RC_RESOLUTION_DEFAULT -->
### RC-4: Hardcoded headless resolution
- **Symptom:** cage creates headless output at 1280x720 (wlroots default).
  No mechanism to set initial resolution from config or viewer handshake.
- **Impact:** All streams start at 1280x720 regardless of viewer display.
- **Fix:** `bsdos-core.conf` adds `BSDOS_OUTPUT_WIDTH=2560` and
  `BSDOS_OUTPUT_HEIGHT=1440`. bsdos-core applies via `wlr-randr` after
  cage socket appears. Viewer resize updates dynamically.
<!-- END_RC_RESOLUTION_DEFAULT -->

<!-- START_RC_ENV_SPRawl -->
### RC-5: Environment variable sprawl
- **Symptom:** Old code: `ZENOH_OBFS`, `BSDOS_OBFS_PSK`, `BSDOS_STREAM_SOCK`.
  New code: `BSDOS_AUTOSTREAM`, `ZENOH_LISTEN_IP`, `ZENOH_LISTEN_PORT`.
  Some overlap, some don't. No validation, no documentation.
- **Impact:** Misconfiguration → silent failures. Hard to deploy correctly.
- **Fix:** `zenoh_config.rs` (already created) is the single source of
  truth. Add `stream_config.rs` for stream/output config. Deprecate old
  vars with warnings. Single TOML config file option.
<!-- END_RC_ENV_SPRawl -->

<!-- START_RC_NO_HEALTH_CHECK -->
### RC-6: No health check endpoint
- **Symptom:** No way to query "is the pipeline healthy?" from outside.
  Viewer connects but sees black — no error, no diagnostic.
- **Impact:** Manual debugging required for every failure.
- **Fix:** bsdos-core publishes `bsdos/health` with JSON status:
  `{"core":"ok","zenoh":"open","cage":pid,"tunnel":pid,"streams":[...]}`.
  Viewer checks health before subscribing. Agent `STATUS` command shows it.
<!-- END_RC_NO_HEALTH_CHECK -->

## Refactoring Plan

<!-- START_PHASE_1 -->
### Phase 1: Deploy new bsdos-core to production (1h)

**Goal:** Replace legacy single-stream bsdos-core with stream_manager version.

**Steps:**
1. Cross-compile bsdos-core for production arch (amd64 native)
2. `deploy-bsdos-myvm.sh`: copy from `target/release/` to `/usr/local/bin/`
3. Update production rc.d to new format (FILESYSTEMS, daemon -o, stream_manager)
4. Set `BSDOS_AUTOSTREAM=appBrowser:chrome` in rc.conf
5. Remove legacy `bsdos_core_zenoh_key`, `bsdos_core_stream_sock` vars
6. Test: viewer connects → sees Chrome → resize works

**Acceptance:**
- `pgrep bsdos-core` shows ONE process (not daemon + orphan)
- `/var/log/bsdos-core.log` shows `[sm] appBrowser started`
- Viewer receives frames within 10s of connect
- `wlr-randr` shows correct resolution after viewer resize

**Risk:** Low — stream_manager already works in Squirrel smoke (5/5 PASS).
<!-- END_PHASE_1 -->

<!-- START_PHASE_2 -->
### Phase 2: Process supervision + health (2h)

**Goal:** Pipeline auto-recovers from cage/tunnel/Chrome crashes.

**Steps:**
1. Verify `monitor_loop` in `stream_manager.rs` detects dead cage/tunnel
2. Add `bsdos/health` Zenoh publisher (1s interval):
   ```json
   {"ts":"...","core":PID,"zenoh":"open",
    "streams":[{"id":"appBrowser","cage":PID,"tunnel":PID,"app":PID}]}
   ```
3. Guest agent `STATUS` command includes health JSON
4. Smoke test verifies health after boot

**Acceptance:**
- Kill cage → bsdos-core restarts it within 10s (monitor_loop)
- Kill tunnel → bsdos-core restarts stream (stop + start)
- `bsdos/health` shows accurate PIDs
<!-- END_PHASE_2 -->

<!-- START_PHASE_3 -->
### Phase 3: Resolution + font quality (1h)

**Goal:** Native Retina resolution, crisp fonts.

**Steps:**
1. Fix resize topic: `bsdos/app/+/viewer/size` in bsdos-core
2. Add `BSDOS_OUTPUT_WIDTH` / `BSDOS_OUTPUT_HEIGHT` to `bsdos-core.conf`
3. bsdos-core applies `wlr-randr --custom-mode WxH --scale S` after cage starts
4. Viewer publishes `WxH@scale` on connect → bsdos-core applies immediately
5. Verify: `wlr-randr` shows `2560x1440, Scale: 2.000000`

**Acceptance:**
- `wlr-randr` shows viewer-requested resolution
- Font edges are smooth (no 2x upscale artifacts)
- Chrome renders at native DPI
<!-- END_PHASE_3 -->

<!-- START_PHASE_4 -->
### Phase 4: Config consolidation (1h)

**Goal:** One config file, validated, no env var guessing.

**Steps:**
1. Create `stream_config.rs` — parses `/etc/bsdos/bsdos-core.conf` (TOML)
2. All env vars become optional overrides on top of TOML defaults
3. Deprecation warnings for old var names (`BSDOS_STREAM_SOCK`, etc.)
4. Single `/etc/bsdos/bsdos-core.conf` example:
   ```toml
   [zenoh]
   transport = "obfs"
   listen = "192.0.2.10:443"
   obfs_psk = "..."
   
   [stream]
   autostart = ["appBrowser:chrome"]
   output_width = 2560
   output_height = 1440
   output_scale = 2
   
   [logging]
   level = "info"
   file = "/var/log/bsdos-core.log"
   ```

**Acceptance:**
- No env vars required for production (all from TOML)
- Old env vars produce `[WARN] deprecated: BSDOS_STREAM_SOCK → stream.sock`
- `hub doctor`-style validation: `bsdos-core --check-config` exits 0
<!-- END_PHASE_4 -->

<!-- START_PHASE_5 -->
### Phase 5: Deployment automation (30min)

**Goal:** `make deploy-myvm` updates production in one command.

**Steps:**
1. `deploy-bsdos-myvm.sh` already exists — update to:
   - Copy bsdos-core from `target/release/` (not Squirrel artefacts)
   - Copy wayland-tunnel from `hal/zig-out/bin/`
   - Copy new rc.d script
   - Copy new bsdos-core.conf
   - `service bsdos_core restart`
2. `make deploy-myvm` target in Makefile

**Acceptance:**
- `make deploy-myvm` → production runs new binary within 30s
- No manual SSH commands needed
- `bsdos/health` confirms new version
<!-- END_PHASE_5 -->

## Semantic Markup Inventory

<!-- START_SM_CONTRACT_CONTRACTS -->
### Contracts to add/update

```
// START_SPAWN_PROCESSES
//   purpose: Spawn cage + tunnel + app for one stream, supervised by monitor_loop
//   input: StreamConfig (app_id, app, url, user, dimensions)
//   output: SpawnedProcesses (cage Child, tunnel Child, app Child)
//   sideEffects: creates rundir, spawns 3 processes, waits for sockets
//   preconditions: Zenoh session open, app_id not already active
//   postconditions: cage wayland-0 socket exists, tunnel stream.sock exists
//   invariant: monitor_loop restarts any dead child within 10s
//   errorHandling: spawn failure → kill partial spawns, return Err
// END_SPAWN_PROCESSES

// START_HEALTH_PUBLISHER
//   purpose: Publish pipeline health status to bsdos/health every 1s
//   input: StreamManager state (active streams, process PIDs)
//   output: Zenoh PUT bsdos/health JSON
//   sideEffects: none (read-only query)
//   contract: health JSON schema:
//     {"ts":ISO8601,"core":PID,"zenoh":"open|pending|closed",
//      "streams":[{"id":str,"cage":PID|0,"tunnel":PID|0,"app":PID|0,
//                  "resolution":"WxH","scale":float}]}
// END_HEALTH_PUBLISHER

// START_RESIZE_HANDLER
//   purpose: Apply viewer resize requests to headless output via wlr-randr
//   input: Zenoh subscriber on bsdos/app/+/viewer/size
//   output: wlr-randr --custom-mode WxH --scale S
//   sideEffects: changes cage headless output resolution
//   preconditions: cage running, XDG_RUNTIME_DIR set
//   topic: bsdos/app/{app_id}/viewer/size (per-app, wildcard match)
//   payload: "WxH@S" where W=pixel_width, H=pixel_height, S=scale_factor
//   invariant: resolution change triggers frame flush within 2s
// END_RESIZE_HANDLER

// START_CONFIG_LOADER
//   purpose: Load bsdos-core configuration from TOML file + env overrides
//   input: /etc/bsdos/bsdos-core.conf (TOML), environment variables
//   output: Config struct (zenoh, stream, logging)
//   sideEffects: reads filesystem, logs deprecation warnings
//   preconditions: config file exists OR all env vars set
//   errorHandling: missing required field → exit with clear message
//   precedence: env var > TOML > default
// END_CONFIG_LOADER
```
<!-- END_SM_CONTRACT_CONTRACTS -->

## Priority Matrix

| Phase | Impact | Effort | Priority | Blocks |
|-------|--------|--------|----------|--------|
| 1. Deploy new core | Critical | 1h | **P0** | 2,3,4 |
| 2. Supervision + health | High | 2h | **P1** | — |
| 3. Resolution + fonts | High | 1h | **P1** | — |
| 4. Config consolidation | Medium | 1h | **P2** | — |
| 5. Deploy automation | Medium | 30min | **P2** | — |

## Test Gates

<!-- START_TEST_GATES -->
- **Unit:** `cargo test -p bsdos-core` (existing 103 tests must pass)
- **Integration:** `make squirrel-smoke-amd64` (5/5 PASS required)
- **E2E:** Viewer connects to production → sees Chrome → resize works
- **Health:** `bsdos/health` JSON valid, PIDs match `pgrep`
- **Recovery:** Kill cage → auto-restart within 10s → frames resume
<!-- END_TEST_GATES -->

## Open Questions

1. Should production use `stream_manager` (multi-stream) or stay single-stream?
   → **stream_manager** — it's the Squirrel architecture, production should match.
2. Should Chrome be replaced with foot for simpler testing?
   → No — Chrome is the production app. Test with foot in Squirrel, deploy with Chrome.
3. Config format: TOML vs YAML vs env-only?
   → **TOML** — FreeBSD convention, no external deps (toml crate already in lifecycled).
<!-- END_SPEC -->
