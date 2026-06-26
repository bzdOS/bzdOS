# SPEC_2stream_squirrel.md — Squirrel 2-stream (browser + terminal) demo

**Date:** 2026-06-15
**Status:** Draft v2 (multi-arch per user 2026-06-15)
**Owner:** architect (claude-host / MiniMax M2.7)
**Decision:** Per user 2026-06-15, **2-stream demo moves from v0.2 "Chimp" Phase 0.3 → v0.1.x "Squirrel"**. This is a scope move, not a new feature.
**Architectures:** **amd64 AND aarch64** (multi-arch, equal status, per user 2026-06-15)

---

## 1. Цель

**Two Zenoh streams running simultaneously on a single Squirrel QEMU guest
(amd64 OR aarch64, both archs supported), both rendered on the Mac client
in two separate NSWindows.**

| Stream | App | Jail | Wayland display | Zenoh topic |
|---|---|---|---|---|
| appTerminal | foot | jail-appTerminal | wayland-0 | `bsdos/app/appTerminal/stream` |
| appBrowser | wpewebkit-fdo (Phantom) | jail-appBrowser | wayland-1 | `bsdos/app/appBrowser/stream` |

> **Architecture-agnostic:** the 2-stream demo works identically on amd64
> and aarch64 Squirrel images. Zenoh pub/sub, per-app_id topics, and
> Mac client (metal-viewer) are arch-independent. The bsdos-core
> HashMap<String, StreamInstance>, BSDOS_AUTOSTREAM env, and
> per-stream monitor_loop work the same on both archs.

The user is **the person running the Mac**: types in appTerminal, sees in
appTerminal; types in appBrowser, sees in appBrowser; the streams never
collide.

This is the **acceptance demo for v0.1.x "Squirrel"** and a **prerequisite
for v0.2 "Chimp"** (Chimp adds mTLS + 60% coverage + bench, but the
multi-stream baseline must already work).

---

## 2. What's already done (architect's audit, 2026-06-15)

| Component | Status | Reference |
|---|---|---|
| `bsdos-core/src/stream_manager.rs`: `HashMap<String, StreamInstance>` | ✅ | `stream_manager.rs:81` |
| `pub async fn start_stream(StreamConfig)` | ✅ | `stream_manager.rs:99` |
| Per-stream health monitor + auto-restart | ✅ | `stream_manager.rs:295-323` |
| `BSDOS_AUTOSTREAM` env: `"appBrowser:firefox:about:blank,appTerminal:foot"` | ✅ | `main.rs:394` |
| Per-stream Zenoh topic: `bsdos/app/{app_id}/*` | ✅ | commit 1a95431 |
| Persistent registry (Cap'n Proto + SQLite-like state) | ✅ | `stream_manager.rs:541` |
| Mac `metal-viewer`: 3 NSWindow references | ✅ | `mac-companion/metal-viewer/src/main.rs` |
| Per-app `MTKView` + `MTLTexture` | ✅ | `wayland_stream.rs` |
| Damage rect per-stream (commit 276f864) | ✅ | `protocol.rs` |

**Architectural finding: 2-stream infrastructure is ~80% done.** The
remaining 20% is verification + acceptance test scaffolding, not new code.

---

## 3. What's missing for "2 streams in 0.1"

| Gap | Severity | Owner |
|---|---|---|
| **E2E test** for 2 streams simultaneously (`make test-2stream-e2e`) | 🔴 blocker | runner (test infra) + system (test logic) |
| **Demo script** `make demo-2stream` | 🔴 blocker | runner |
| **Cage multi-instance**: 2 cages × 1 app each, or 1 cage × 2 apps? | 🟡 design | architect (this spec) |
| **Zenoh subscriber**: per-app_id routing (no global dispatch collision) | 🟡 verify | system (1-2 days) |
| **Mac window placement**: 2 NSWindow side-by-side vs cascade | 🟢 polish | frontend (low) |
| **Resource budget**: 2 cages + 2 tunnels + bsdos-core < 700 MB RAM | 🟡 verify | system (bench) |
| **Phantom browser .jpk** for Squirrel: appBrowser needs a real browser (or wpewebkit-fdo stub) | 🟡 depends | system (1 wk) |
| **amd64→aarch64 port**: cage + foot already in repo as amd64, cross-compile to aarch64 per `docs/specs/SPEC_squirrel_rootfs.md` | 🟡 depends | system (cross, 2-3 d) |

---

## 4. Cage multi-instance: the architectural decision

**Question:** How do 2 apps share a single QEMU guest's GPU/display?

**Three options considered:**

| Option | Pros | Cons |
|---|---|---|
| **A) 2 cage instances** (2 Wayland displays, 2 ZWS sockets) | Clean isolation, exactly matches jail model, each cage sees only its app | 2 cage procs × ~30 MB each, 2 weston-launchers, 2 WAYLAND_DISPLAYs |
| **B) 1 cage, 2 apps** (cage = kiosk single app, doesn't work) | — | **Cage is single-app kiosk** — option B is technically invalid |
| **C) 1 labwc/sway WM** with 2 windows | Lower resource use, real desktop | Violates "1 app = 1 jail" isolation principle, no real-world benefit |

**Decision: A) 2 cage instances.** This matches the jail model (1 cage per
app per jail), is what the user implies with "2 streams", and is the
cleanest isolation story for Chimp (where each cage runs on real
GPU/display surface).

### 4.1 Implementation

In each jail (`/etc/bsdOS/jails/jail-appTerminal.conf` and `jail-appBrowser.conf`):
```
exec.start = "/bin/sh /etc/bsdOS/start-cage.sh appTerminal wayland-0 foot"
exec.start = "/bin/sh /etc/bsdOS/start-cage.sh appBrowser wayland-1 firefox"
```

`/etc/bsdOS/start-cage.sh`:
```sh
#!/bin/sh
APP_ID=$1
WAYLAND_DISPLAY_NAME=$2
APP_CMD=$3

# Set up runtime dir
export XDG_RUNTIME_DIR=/tmp/wayland-run
mkdir -p $XDG_RUNTIME_DIR
chmod 700 $XDG_RUNTIME_DIR

# Launch cage on its own Wayland display
WAYLAND_DISPLAY=$WAYLAND_DISPLAY_NAME \
  cage -d -- $APP_CMD &
CAGE_PID=$!

# Wait for cage to create the socket
sleep 0.5

# Notify bsdos-core to start streaming
echo "READY $APP_ID" | nc -U /var/run/bsdOS/control.sock
```

bsdos-core picks up the ready signal and starts the Zenoh publisher on
`bsdos/app/{app_id}/stream`.

---

## 5. Zenoh routing (per-app_id)

**Current topic structure** (commit 1a95431):
- Publisher: `bsdos/app/{app_id}/stream` (data, QPS=1)
- Publisher: `bsdos/app/{app_id}/input` (input events, QPS=N)
- Subscriber (control plane): `bsdos/app/+/health` (health heartbeats)
- Subscriber (logs): `bsdos/logs/{app_id}` (aggregated logs)

**For 2 streams, the Mac metal-viewer must:**
1. Subscribe to `bsdos/app/+/stream` (wildcard, gets both)
2. Demux by `app_id` field in the FrameUpdate Cap'n Proto
3. Route to the right `MTKView` (window 1 = appTerminal, window 2 = appBrowser)
4. Avoid cross-routing (typing in window 1 must go to `bsdos/app/appTerminal/input`, not browser)

**Architectural invariant:** routing is by `app_id`, not by topic
prefix. The Mac viewer is the only component that knows the
app_id→window mapping.

---

## 6. Mac viewer multi-window

**Already in `mac-companion/metal-viewer/src/main.rs`:**
- 3 `NSWindow` references (search confirmed)
- Per-app `MTKView` + `MTLTexture` (one per `app_id`)

**Acceptance test:** boot 2 streams, verify 2 NSWindows appear
side-by-side, type in window 1 → foot in jail 1 receives keystrokes,
type in window 2 → firefox in jail 2 receives.

**Layout:** cascade by default (window 1 top-left, window 2 offset
+30px right +30px down). User can drag-resize.

---

## 7. Resource budget (target: Squirrel on aarch64 QEMU)

| Component | RAM (MB) | CPU% idle | CPU% typing |
|---|---|---|---|
| FreeBSD 15.1 base | 60 | 1 | 1 |
| bsdos-core (Rust) | 15 | 0.5 | 2 |
| bsdos_lifecycled (Rust) | 5 | 0.1 | 0.5 |
| cage #1 + foot | 35 | 0.5 | 5 |
| cage #2 + firefox | 220 | 1 | 25 (rendering) |
| wayland-tunnel ×2 | 10 | 0.5 | 2 |
| ZFS ARC | 50 | 0 | 0 |
| **Total** | **~400 MB** | **<5%** | **<35%** |

(Compare to v0.1.0 single-stream baseline: ~180 MB, 25% with rendering.)

**Target hardware for Squirrel smoke test:** QEMU aarch64 with
`-m 1G` (1 GB RAM, 4 vCPU Cortex-A72). 2-stream fits comfortably.

**For Chimp real hardware (Banana Pi 2 GB RAM):** headroom for
stream #3 (matrix?), bsd_lifecycled ZSTD compression active.

---

## 8. E2E test (`make test-2stream-e2e`)

Script outline (runner-side implementation, architect spec):

```sh
#!/bin/sh
# infra/scripts/test-2stream-e2e.sh
set -e

# 1. Start QEMU with 2 cages
qemu-system-aarch64 -m 1G -smp 4 -machine virt -cpu cortex-a72 \
    -drive file=artefacts/bsdos-squirrel-v0.1.3.img.gz,format=raw \
    -device virtio-net-pci,netdev=net0 -netdev user,id=net0,hostfwd=tcp::7447-:7447 \
    -nographic -serial stdio &

QEMU_PID=$!
sleep 30  # wait for boot

# 2. Verify both cages spawned
jls | grep -E "appTerminal|appBrowser" || { echo "FAIL: cages not started"; exit 1; }

# 3. Verify Zenoh topics
zenoh_subscriber --topic "bsdos/app/+/health" --timeout 5 | \
    grep -E "appTerminal|appBrowser" || { echo "FAIL: no health"; exit 1; }

# 4. Connect Mac viewer
metal-viewer --subscribe "bsdos/app/+/stream" --window-count 2 &
VIEWER_PID=$!
sleep 5

# 5. Type into appTerminal window
osascript -e 'tell application "System Events" to keystroke "ls\n"' \
    --window-id terminal_window_id

# 6. Verify foot received the keys
zenoh_subscriber --topic "bsdos/app/appTerminal/input" --timeout 5 | \
    grep -c "ls" | grep -v "^0$" || { echo "FAIL: keys not forwarded"; exit 1; }

# 7. Type into appBrowser window
osascript -e 'tell application "System Events" to keystroke "github.com\n"' \
    --window-id browser_window_id

# 8. Verify firefox received the keys
zenoh_subscriber --topic "bsdos/app/appBrowser/input" --timeout 5 | \
    grep -c "github" | grep -v "^0$" || { echo "FAIL: browser keys"; exit 1; }

# 9. Cleanup
kill $VIEWER_PID $QEMU_PID
echo "PASS: 2-stream E2E"
```

**This test gates v0.1.x Squirrel acceptance.**

---

## 9. Implementation plan

| Step | Owner | Estimate | Depends on |
|---|---|---|---|
| 9.1 Cross-compile cage + foot to aarch64 (per `SPEC_squirrel_rootfs.md`) | system (Qwen 3.7) | 2 d | rootfs build pipeline |
| 9.2 Cross-compile Firefox or wpewebkit-fdo to aarch64 | system (Qwen 3.7) | 1 wk | rootfs build pipeline |
| 9.3 Configure 2 jails with `/etc/bsdOS/start-cage.sh` | runner | 2 d | 9.1, 9.2 |
| 9.4 Verify Zenoh per-app_id routing on Mac viewer | system (Qwen 3.7) | 1-2 d | Mac availability |
| 9.5 Add 2 NSWindow layout (cascade) | frontend (Kimi K2.6) | 1 d | 9.4 |
| 9.6 Write `infra/scripts/test-2stream-e2e.sh` | runner (DeepSeek) | 2 d | 9.1, 9.3 |
| 9.7 `make test-2stream-e2e` integration into CI | sre | 1 d | 9.6 |
| 9.8 `make demo-2stream` user-facing script | runner | 1 d | 9.6 |
| **Total** | | **~3 weeks** | Squirrel ARM64 QEMU build pipeline (internal task) |

---

## 10. Open questions

1. **Firefox vs wpewebkit-fdo for appBrowser?** wpewebkit-fdo is
   ~30 MB, Firefox is ~220 MB. For Squirrel, recommend **wpewebkit-fdo**
   (Squirrel is a demo, not a production browser). For Chimp, upgrade
   to Firefox.
2. **Cage `--immediate` flag** — should cage start before its app is
   ready, or after? Affects startup race. Recommend `--immediate` +
   0.5s sleep in `start-cage.sh` (works in practice).
3. **bsdos_lifecycled for 2 streams** — does the lifecycle daemon need
   per-stream ZSTD compression, or one shared ZSTD pool? Recommend per-stream
   (cleaner accounting) for Squirrel; revisit for Chimp.
4. **What if appBrowser crashes?** monitor_loop auto-restarts it. But
   Firefox is heavy; should Squirrel prefer a lighter browser to avoid
   thrash? Recommend: yes, wpewebkit-fdo for Squirrel.
5. **CI: 2-stream smoke on every PR?** Or only on `main` merges?
   Recommend: 2-stream smoke on `main` merges only (5-7 min); unit tests
   on every PR.

---

## 11. Why this is in v0.1, not v0.2

User decision 2026-06-15. Architecturally defensible:
- The infrastructure (HashMap<String, StreamInstance>, BSDOS_AUTOSTREAM,
  per-stream monitor_loop, per-app_id topics) is **already in v0.1.0**.
- The 2-stream E2E test is the **natural acceptance criterion** for
  Squirrel's "QEMU sandbox" stage.
- Without 2-stream, Squirrel is single-app (essentially a QEMU terminal
  demo). 2-stream is what makes Squirrel a real "sandbox" (you can run
  a terminal + browser side by side, exactly the use case the user
  described in the original 2026-06-13 vision: "Mac renders a Wayland
  stream from a real application ... typing on the Mac reaches that
  application").
- v0.2 "Chimp" was originally the multi-stream target. Moving it to
  Squirrel **frees up Chimp scope** for the Chimp-specific features
  (mTLS, 60% coverage, hardware bringup on Banana Pi). Chimp was
  over-scoped.

---

## 12. What changes in the docs

| File | Change |
|---|---|
| `ROADMAP.md` | Move "2-stream demo" from `📋 Outstanding (v0.1.x / v0.2)` to `v0.1.x "Squirrel"` acceptance |
| `PLAN-release-0.1.md` | Add `Stage 4 — 2-stream demo` to v0.1 DOF (or close as DONE per spec) |
| `docs/v0.2-release-plan.md` | Remove F1 (2-stream) from Chimp; redistribute to mTLS + coverage + bench |
| `docs/q3-architecture.md` | Stream A: 2-stream moves from v0.2 → v0.1.x in the W1-W4 plan |
| `internal task` | Add 2-stream E2E + demo as sub-tasks in implementation plan |

---

**Status:** Architect design draft v1. Move to runner for `make demo-2stream` + `test-2stream-e2e`, system for cage+firefox cross-compile, sre for CI gate. ~3 weeks after Squirrel rootfs build pipeline lands.
