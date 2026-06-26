# Contributing to wlstream

## Bug reports

Open an issue with:
- What happened (expected vs actual)
- Minimal reproduction (wire bytes, event type, input data)
- Platform + Rust version

## Pull requests

1. Fork → branch → PR.
2. Keep commits atomic with clear messages.
3. `cargo test` must pass.
4. `cargo clippy -- -D warnings` must pass.
5. `cargo fmt --all -- --check` must pass.
6. If adding a new event type, update:
   - `spec/WAYLAND_STREAM_PROTOCOL.md`
   - `spec/wlstream.schema.json`
   - `src/parser.rs` (decode)
   - `src/sender.rs` (encode)
   - Tests in both modules

## Protocol changes

Protocol versioning follows the spec. Breaking changes require a new
major version (v2, v3, ...). Non-breaking additions (new event types
with new IDs) can be minor versions.

Backward compatibility: receivers must silently skip unknown event types.

## Adding language bindings

The wire format is language-agnostic. If you implement a parser/sender
in another language (C, Python, Go, etc.), open a PR with:
- A `bindings/<lang>/` directory
- Tests proving round-trip compatibility with the Rust crate
- A `build.zig` or equivalent build configuration

## License

By contributing, you agree that your contributions are licensed under MIT.
