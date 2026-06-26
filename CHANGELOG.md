# Changelog

## v0.1.3 — 2026-06-25

### Added
- Multi-arch rootfs images: amd64 (298 MB) + aarch64 (362 MB)
- bsdos-lifecycled: jail FREEZE/THAW daemon (SIGSTOP/SIGCONT)
- .jpk prototype: phantom-browser + foot packages
- F3 test coverage >= 60%
- aarch64 cross-compile toolchain (Rust nightly + Zig --sysroot)

### Fixed
- wayland-tunnel: lld sysroot for aarch64 cross-compile
- squirrel-build: bmake CURDIR, PATH for cargo+nightly
- machotool: FAT binary endianness handling

## v0.1.2 — 2026-06-17

### Added
- 2-stream demo: Terminal (foot) + Browser (chromium) streaming over Zenoh
- Stream socket isolation: per-stream `/tmp/bsdos/streams/<app_id>/wayland-stream.sock`
- wayland_forwarder: v1 length-prefixed `[u32 LE size][payload]` protocol
- stop_stream(): SIGKILL + wait all children; duplicate start guard

### Fixed
- Duplicate stream registry entries on restart
- cage headless compositor: WLR_BACKENDS=headless, WLR_RENDERER=pixman

## v0.1.1 — 2026-06-10

### Added
- bsdos-core: Zenoh peer mode, StreamManager, lifecycle RPC
- Guest agent: text protocol over virtio-console /dev/ttyV0.2
- 9p shared filesystem (host /srv/bsdos == guest /mnt/bsdos)
- Initial .jpk descriptor spec v1

## v0.1.0 — 2026-05-01

Initial internal release — QEMU amd64 sandbox (Squirrel).
