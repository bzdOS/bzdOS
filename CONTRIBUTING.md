# Contributing to bsdOS

## Prerequisites

- **Rust**: nightly toolchain (see `rust-toolchain.toml`)
- **Zig**: 0.13+
- **FreeBSD 15.1**: native build or cross-compile from Linux/macOS
- **QEMU**: for running Squirrel images locally
- **capnp**: Cap'n Proto compiler for schema regeneration

Install on FreeBSD:

```sh
pkg install rust zig cmake capnproto gmake
```

## Building

### bsdos-core (primary daemon)

```sh
cargo build -p bsdos-core
```

### Cross-compile to aarch64

```sh
# Set up Zig-based cross-compile toolchain:
./infra/scripts/mk-cross-cc.sh aarch64-unknown-freebsd15.1

# Build the full rootfs image:
./infra/scripts/bsdos-build.sh aarch64
```

### All Rust crates

```sh
cargo build --workspace
```

## Tests

```sh
cargo test --workspace
```

Smoke test against a running VM:

```sh
infra/scripts/bsdos-smoke.sh
```

## Code conventions

**Rust:**
- No `unwrap()` — use `?` or explicit `match`/`map_err`
- No `unsafe` outside C FFI (`libc` crate)
- Every public function carries a semantic contract comment:
  `/// purpose:`, `/// input:`, `/// output:`, `/// sideEffects:`
  See [github.com/bzdOS/SeMa](https://github.com/bzdOS/SeMa) for the full methodology.
- Errors propagate via `Result<T, E>`; `fn main()` returns `Result` or exits cleanly

**Zig (HAL, WLTunnel):**
- Pass `allocator: std.mem.Allocator` explicitly — no hidden heap allocations
- `@cImport` for FreeBSD C headers, guarded by `if (builtin.os.tag == .freebsd)`
- Structs in hot paths: `packed` or `extern`, 64-byte aligned (Cortex-A53 cache line)
- Handle errors explicitly — do not ignore return values

**Shell scripts:**
- Use `command + args` arrays, never `sh -c "string"` (injection risk)
- Quote all variables

## Serialization rules

| Layer | Format |
|---|---|
| Data-plane (frames, events) | Cap'n Proto (zero-copy, length-prefixed) |
| Inter-node transport | Zenoh peer mode |
| Control protocol | Plain text `CMD ARG\n` / `+OK\n` |

No JSON on any hot path.

## Pull requests

- Open an issue first for non-trivial changes
- Keep PRs focused — one feature or fix per PR
- Run `cargo test --workspace` before submitting
- Update `CHANGELOG.md` under `Unreleased`
