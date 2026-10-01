# Stream pipeline deploy contract (bsdos-core ↔ wayland-tunnel)

## Why this file exists

Discovered live on dev-vm (2026-07-10/11): bsdos-core and wayland-tunnel had each
been rebuilt independently over time, and drifted out of sync twice at once:

1. bsdos-core (Rust) spawned wayland-tunnel with env vars named `BSDOS_*`;
   wayland-tunnel (Zig) had since been renamed to read `WLSTREAM_*` (commit
   `e147a5a`). Neither side errored — wayland-tunnel silently fell back to
   hardcoded `/tmp/wayland-run/*` defaults, so streams "worked" but ignored
   the per-app_id socket paths bsdos-core thought it was assigning.
2. The **installed** `/usr/local/etc/rc.d/bsdos_core` on dev-vm had a different
   default log path (`/tmp/bsdos-core-health.log`) than the one checked into
   `infra/rc.d/bsdos_core` (`/var/log/bsdos-core.log`) — someone had edited
   the live rc.d script directly at some point instead of reinstalling from
   the repo.

Both were invisible until manually diffed process-by-process against source.
`make deploy-stream-pipeline` (below) exists so this class of drift can't
recur silently.

## The contract

bsdos-core's `StreamManager::spawn_processes` (`bsdos-core/src/stream_manager.rs`)
launches wayland-tunnel with these env vars, one distinct socket set per `app_id`
under `/tmp/bsdos/streams/<app_id>/`:

| Env var | Purpose | Read by |
|---|---|---|
| `WLSTREAM_COMPOSITOR_SOCK` | cage's Wayland compositor socket | `wayland-tunnel/src/main.zig` |
| `WLSTREAM_WAYLAND_SOCK` | ghost Wayland display socket exposed to the app | `wayland-tunnel/src/main.zig` |
| `WLSTREAM_STREAM_SOCK` | v1 length-prefixed frame stream (read by `stream-reader`, forwarded to Zenoh) | `wayland-tunnel/src/main.zig`, `src/stream-reader.zig` |
| `WLSTREAM_INPUT_SOCK` | injected keyboard/pointer events from the viewer | `wayland-tunnel/src/main.zig` |
| `WLSTREAM_JAIL` | `1` enables jail-per-stream mode (#147) | `bsdos-core/src/stream_manager.rs` only |
| `WLSTREAM_NO_LZ4` | skip LZ4 compression on stream frames | `wayland-tunnel/src/stream.zig` |

**Nothing checks these names match at compile time or at startup** — a rename
on either side is a silent behavior change on the other, not a build error.
If you rename any `WLSTREAM_*` var, grep both `bsdos-core/src/stream_manager.rs`
and `wayland-tunnel/src/*.zig` and update every occurrence in the same commit.

## Deploying — always both halves together

```
make deploy-stream-pipeline    # aliases: deploy-streaming, deploy-dev-vm
```

Runs `infra/scripts/deploy-dev-vm.sh`, which — in one atomic pass, guest-agent
only, no SSH in the recipe — does:

1. `cargo build --release --features with-bridge` (bsdos-core)
2. `zig build -Doptimize=ReleaseSafe` (wayland-tunnel, wl-keepalive, stream-reader
   — via `infra/scripts/build-wayland-tunnel.sh`)
3. install both sets of binaries + `infra/rc.d/bsdos_core` (always reinstalled
   from repo — never hand-edit the live rc.d script on dev-vm)
4. stop old processes, `rm -rf /tmp/bsdos/streams/*`
5. `service bsdos_core start`
6. smoke-check: waits for `READY` in `/var/log/bsdos-core.log`, checks `:443`
   listening and the input handler line

Do **not** run `make wayland-tunnel-build` / `build-core` separately as your
only deploy step for a live-behavior change spanning both binaries — that's
exactly how the drift above happened. Those targets still exist for
iterating on one side only (e.g. a Zig-only protocol fix with no Rust-side
change), but a change to the shared contract needs the combined target.

## Verifying after deploy

```sh
# from the ops checkout (bsdOS monorepo):
. infra/scripts/_agent.sh
agent_exec 'grep "\[sm\]" /var/log/bsdos-core.log | tail -20'   # both app_ids started clean?
agent_exec 'find /tmp/bsdos/streams -maxdepth 2'                # distinct sockets per app_id?
```

Each `app_id` directory under `/tmp/bsdos/streams/` should have its own
`wayland-0`, `wayland-stream.sock`, `input.sock` — no shared paths between
streams. This is the concrete, live check for #39/#50 (2-stream demo).
