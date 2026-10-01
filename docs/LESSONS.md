# Lessons kept from the archive

Facts worth keeping from the documents archived on 2026-10-01: observed
behaviour, root causes, measurements, and the reasons behind decisions. Plans
and statuses stayed in the archive, which is now in the local attic
(`attic/docs/archive/`, no remote). Each line names its source there
(`P/` = `2026-06-15-plans/`, `M/` = `2026-10-01-monorepo/`).

These are what the documents say was observed. Lines marked *(checked
2026-10-01)* were confirmed against the code on that date; the rest were not
re-verified.

## Banana Pi M64 boot (Chimp)

- Both early SD images were dead because the U-Boot FIT carried an **empty BL31** (atf=0). Fix: ATF v2.10.0 `PLAT=sun50i_a64` + U-Boot `bananapi_m64_defconfig` with `BL31=`. — `M/CHIMP-READINESS.md:79`, `M/SESSION-2026-07-07-part2-kernelhang.md:33-36`
- The 128-entry primary GPT array at LBA2 runs into the SPL at LBA16; U-Boot then sees 0 partitions (it does **not** fall back to the backup GPT). Fix: 16 entries. *(checked 2026-10-01: `bzdOS/infra/scripts/bpi-image.sh` Step 2c)* — `M/SESSION-…-kernelhang.md:36-38`
- After `ExitBootServices` the U-Boot USB-ACM gadget console dies, and the FreeBSD kernel has no USB-gadget console of its own: from kernel start to userland only UART or video show anything. — `M/SESSION-…-kernelhang.md:55-60`
- Load the DTB from U-Boot (`fatload …; bootefi $kernel $dtb`); `set fdt_name` in loader does not override the EFI DTB. — `M/SESSION-…-kernelhang.md:46-48`
- A "/dev/ttyACM0" that is a regular file was created by `printf > tty` while the gadget was disconnected. — `M/SESSION-…-kernelhang.md:71`
- Never `conv=sync` in `gunzip | dd`: it pads the flash with zeros. — `M/CHIMP-READINESS.md:146`
- Main U-Boot risk was DRAM/PHY init from the pine64-lts tree; fallback is mainline `bananapi_m64_defconfig`. — `M/CHIMP-READINESS.md:74`

## Display and GPU on the A64

- Two independent projects: **A** display (sun4i/DE2 KMS → Wayland with software rendering, no GPU needed) and **B** GPU (Mali-400/lima, only after A). — `M/DESIGN-gpu-display-a64.md:7-10`
- DE2/TCON/MIPI-DSI and Mali-400 are not emulated by QEMU: KMS and lima work happens on hardware over serial. — `M/DESIGN-gpu-display-a64.md:59-69`
- Base for ARM-SoC DRM is **drm-subtree + DRMKPI**, not drm-kmod/LinuxKPI (that is for PCIe GPUs and lacks component/of/clk/regulator/phy/panel/bridge/mipi_dsi KPI). The A64 DE2 pieces exist in `allwinner/aw_de2*.c`. — `M/PLAN-gpu-bringup.md:myvm-216`, `M/DESIGN-gpu-display-a64.md:36`
- As of 2026-07-10 there was no Lima driver for FreeBSD anywhere (Panfrost was ported by Ruslan Bukin, ~6 months solo); `bzdOS/lima-freebsd` is this project's own port. — `M/PLAN-gpu-bringup.md:190-196`
- **MIPI-DSI is missing from drm-subtree** (a hub task): the PinePhone panel is blocked independently of the GPU. A port means `sun6i_mipi_dsi.c` (~35 KB) + `phy-sun6i-mipi-dphy.c` (~20 KB), and DRMKPI has no PHY framework. Relevant to Woodpecker. — `M/PLAN-gpu-bringup.md:193`
- Utgard MMU is simpler than Midgard (one DTE register), but GP + up to 8 PP cores means two scheduler pipes. — `M/PLAN-gpu-bringup.md:213-222`
- Without DRM-KMS on the device there is no Wayland: compositors need a DRM device, and an EFI framebuffer is not one. — `M/ARCHITECTURE-REVIEW.md:28-30`
- drm-kmod is GPL: a native BSD driver has to be written from the spec, not copied. — `M/DESIGN-gpu-display-a64.md:56-58`
- AP6255 (BCM43455) SDIO Wi-Fi is not supported in FreeBSD base; `bwn(4)` does not know it. — `P/PLAN-network-stack.md:19-23` (since then: `bzdOS/freebsd-brcmfmac-sdio` for the BPI-M64's BCM43430)

## Wayland streaming (WLTunnel, bsdos-core, metal-viewer)

- On 64-bit FreeBSD `CMSG_DATA` is at offset 16, not 12; with 12, cage received 0 FDs → protocol error → foot POLLHUP. *(checked 2026-10-01: `WLTunnel/src/socket.zig:20`)* — `M/QUICKSTART-WAYLAND.md:66-68`
- cage creates `wayland-0` as 0755 root:wheel → EACCES for user `freebsd`. — `M/QUICKSTART-WAYLAND.md:70-72`
- A blocking `std::sync::mpsc::recv()` inside tokio blocked the executor; the Zenoh session died after ~157 ms. — `M/QUICKSTART-WAYLAND.md:74-76`
- cage exits when it has 0 clients → a keepalive client is needed. — `M/QUICKSTART-WAYLAND.md:56`
- Headless cage advertises `wl_seat.capabilities = 0`, so clients never call `get_keyboard`/`get_pointer`. Patching capabilities only on compositor→client fails (`get_pointer called when no pointer capability has existed`); swallowing the whole buffer loses `wl_surface.commit` (Firefox drops frames). What works: virtual `wl_keyboard`/`wl_pointer` between tunnel and client only. — `P/PLAN-input-injection.md:7-26`
- Send `wl_keyboard.enter` before `key` and `wl_pointer.enter` before `motion` (foot ignores input otherwise); `wl_pointer.motion` takes absolute surface coordinates; buttons are evdev `BTN_LEFT=0x110`…; axis opcode 8, axis_stop 9. — `P/PLAN-input-forwarding.md:45-66,133-160`
- `input.sock` is SOCK_STREAM: frame by event length, one `read()` is not one event. — `M/DEV-GUIDE.md:207-209`
- `SURFACE_COMMIT` (0x04) already carries `damage_x/y/w/h` (u16 LE); damage rects needed no protocol change. Stream v1 framing: `[u32 LE size][u8 type][data]`, types 0x03 POOL_DATA, 0x04 SURFACE_COMMIT, 0xFE SESSION_RESET, 0xFF ERROR. — `M/PLAN-damage-rect-v0.1.md:64-78`, `M/PLAN-release-0.1.md:55`
- Measured LZ4 in the tunnel (2026-06-15, QEMU x86): raw frame 1280×694×4 = 3.55 MB → Firefox idle ~27 KB, foot ~120 KB, one sample 46 KB. Touch-to-photon was never measured. — `M/PLAN-benchmarks.md:642,656-662`, `M/QUICKSTART-WAYLAND.md:49-52`
- DPI was first beaten by a zenoh-link-tls patch adding ALPN `h2`/`http/1.1` (no nginx or wstunnel); later replaced by the obfs link. — `M/DESIGN-bsdos-transport.md:7-66`
- metal-viewer needs the whole `[patch.crates-io]` set to build. — `M/MAC-BUILD.md:11-37`

## Dev VM and the agent

- `/dev/ttyV*` is a TTY with a line discipline: raw 0x03/0x04/0x0a/0x0d/0x11/0x13 of a binary protocol get mangled. That is why the agent protocol is text `CMD ARG\n`. — `P/PLAN-virtio-console.md:36-58`
- A QEMU chardev for it needs `server=on,wait=off`, or QEMU hangs at start; the agent must reopen the device on EOF. — `P/PLAN-virtio-console.md:72,121-122`
- FreeBSD base has no virtio_vsock / AF_VSOCK (bug 271793), and vsock is VM↔hypervisor only, useless on hardware. Checked for 14.x, not re-checked for 15.1. — `P/PLAN-virtio-vsock.md:6-27`
- sshd on myvm needs `UseDNS no` or it hangs; console without a TTY is `virsh ttyconsole myvm`. — `M/PLAN-myvm.md:11-12`
- In QEMU user-net there is no raw ICMP: ping does not work, test over TCP. — `M/RUNBOOK.md:217`
- Cross-node 9p `flock` does not work. — `M/ARCHITECTURE-REVIEW-2026-07-04.md:9`

## Toolchains

- Zig cross to FreeBSD needs Zig ≥ 0.15 and an explicit version in the target (`aarch64-freebsd.14`/`.15.1`); without it Zig picks freebsd.13 with no bundled libc. — `M/PLAN-stage0.md:19-21`, `M/CHIMP-READINESS.md:43`
- `aarch64-unknown-freebsd` is Rust Tier 3: `rustup target add` gives no rust-std — build in the guest or nightly `-Z build-std`. — `M/ARCHITECTURE-REVIEW.md:34`
- zenoh pulls `stabby-abi`, which needs nightly (`feature(freeze)`); keep zenoh/tokio optional behind a feature so `cargo test --lib --no-default-features` runs on stable. — `M/PLAN-test-coverage.md:142-148`
- FreeBSD bmake has `.CURDIR`, not `$(CURDIR)` → use gmake; give lld `--sysroot`, not `-Dsysroot` (else it links the host's amd64 libc); system cargo in `/usr/local/bin` ignores `+toolchain`, use rustup's; a pipe around `buildkernel` masked its exit code. — `M/RELEASE-NOTES-v0.1.3.md:40-57`
- Mach-O fat headers: `FAT_MAGIC` is big-endian on disk; the `swapped` flag was inverted. — `M/RELEASE-NOTES-v0.1.3.md:24`
- Coverage needs llvm-cov from the Rust nightly, not system llvm-cov-18. — `M/RELEASE-NOTES-v0.1.3.md:19`
- An in-process Zenoh `Config::default()` may go into multicast scouting and hang a test: set `multicast/scouting=false`. — `M/RELEASE-NOTES-v0.1.2.md:73-75`

## Jails and devfs

- Permissions are enforced by the kernel (devfs ruleset, VNET+pf, RCTL), not userspace. A jail does not isolate Wayland clients from each other → `security-context-v1`. App identity = one bus socket per jail, nullfs-mounted inside, `getpeereid` as defence in depth. — `M/DESIGN-jail-app-model.md:20-77`
- devfs rulesets 0–3 are reserved, 4 is `$devfsrules_jail`, own ones 10–60; a ruleset must be loaded before the jail is created. — `M/DEVFS-IMPLEMENTATION-SUMMARY.md:267-271`, `M/DEVFS-ADVANCED-GUIDE.md:278,343-347`
- unionfs is unstable → read-only nullfs base + read-write nullfs `/data`; unmount strictly in reverse order or get `device busy`; loopback inside a jail is unreliable, test on the main IP. — `M/PLAN-jail-prototype.md:103-126`
- PF cannot match jail UID/GID, filter by source IP; `ip4=disable` does not cover IPv6 (`ip6=disable`). — `P/PLAN-network-policy.md:149-152`
- FreeBSD `nc` has no `-e`; if pkg bootstrap failed inside a jail, pkg there is unusable. — `M/CONDUIT-DEPLOYMENT-STATUS.md:180-192`

## Distributed state (mrgd / couplingd)

- Why an own homeserver: Conduit and Synapse are single-master. The "Conduit test" for priorities: if stock Conduit would solve it, it is tax; if not, it is the product. — `M/DESIGN-matrix-homeserver.md:9-18`
- PostgreSQL cannot be multi-master (shared buffers and LWLocks are process shmem): the ceiling is single-primary with failover; a resurrected node's fence token must be rejected. — `M/specs/SPEC_matrix_bringup.md:39-47,160-200`
- Persistence: append-only JSONL with fsync, replay idempotent thanks to grow-sets, "best-effort-but-loud"; file names with `!#:/` are percent-encoded. — `M/specs/SPEC_matrix_persistence.md:22-156`
- The "shared hub_bridge" was a false claim: the bridge in production is `infra/scripts/hubd-matrix-bridge.py`; `hub_bridge.rs` was never deployed. — `M/PLAN-coordination-free-extraction.md:13-19`

## Still open, as of the archived docs

Not re-checked against the trackers unless noted; follow-ups are hubd tasks.

- metal-viewer `REVIEW(mac)`: the drawable height is set once, so the Y-flip drifts on resize; the scroll divisor `/10.0` ignores `hasPreciseScrollingDeltas()`. *(checked 2026-10-01: still in `metal-viewer/src/main.rs:1037,1206`)* — `M/MAC-BUILD.md:124-127`
- Coordination-free gaps: authenticated key bootstrap (now TOFU, #dev-vm), journal of `sig`/`signer_node`/`prev_events`/`depth` (#192), grow-set GC, token revocation across nodes, federation, key backup, state-res v2. — `M/PLAN-coordination-free-extraction.md:242-297`
- Not measured: CRDT metadata growth, obfs-443 under a chatty mesh, cross-DC latency. — `M/ARCHITECTURE-REVIEW-2026-07-04.md:45-47`
- Ideas never tracked: per-jail RCTL memory limits instead of lifecycled's global threshold; `MEM_GUARD`; Zenoh command keys and readiness probes instead of TCP 9999 and sleeps; duress PIN / emergency wipe. — `P/PLAN-jail-memory-budget.md:64-81`, `M/PLAN-lifecycle-v2.md:17-35`, `M/PLAN-bsdos-vision.md:81-87`
- The prototype broker listens on `0.0.0.0:9999` and gives `host-ui` full access without auth. It is in the attic now; do not revive it as is. — `M/TCP_UI_README.md:24-53`

Resolved since: the BPI-M64 early kernel hang (`M/SESSION-…-kernelhang.md:99-111`) — the guest reaches userland under bzdk (a hub task, 2026-08-20); multi-node never proven (`M/ARCHITECTURE-REVIEW-2026-07-04.md:14-20`) — cross-node convergence live-verified 2026-07-06; matrix-hs passwords in plain text (`M/specs/SPEC_matrix_persistence.md:82`) — mrgd uses Argon2id *(checked 2026-10-01)*; CGEventTap SIGILL (`P/PLAN-metal-viewer-runtime-config.md:484-492`) — metal-viewer uses objc2-core-graphics *(checked 2026-10-01)*.

**Harmful if followed:** `M/DEV-GUIDE.md` (direct-QEMU `make vm-x86-start`, chardev `/dev/ttyV1.1`), `M/IMPLEMENTATION-jail-policy-apply.md` and `M/DEVFS-*` (ssh/scp inside scripts), `M/DESIGN-ipc-protocol.md` (JSON control plane).
