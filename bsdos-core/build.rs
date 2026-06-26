// START_AI_HEADER
// MODULE: bsdos-core/build.rs
// PURPOSE: Compile Cap'n Proto schema (stream.capnp) into Rust code.
// INTENT: Generate stream_capnp module with StreamConfig, StreamState, StreamRegistry types.
// DEPENDENCIES: capnpc (Cap'n Proto compiler).
// PUBLIC_API: none (build script).
// END_AI_HEADER

fn main() {
    capnpc::CompilerCommand::new()
        .src_prefix("src")
        .file("src/stream.capnp")
        .run()
        .expect("schema compiler command");
}
