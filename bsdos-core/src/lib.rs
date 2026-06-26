// START_AI_HEADER
// MODULE: lib.rs
// PURPOSE: bsdos-core library surface — exposes Cap'n Proto codec, HAL client, stream manager.
// INTENT: Single library entry point so the bsdos-core binary and the bin/sub subscriber share the same decoding logic.
// DEPENDENCIES: capnp module (hand-rolled 32-byte HardwareStatus codec), hal module (Unix-socket text protocol), stream_manager (dynamic stream lifecycle).
// PUBLIC_API: capnp::{encode, decode}, hal::{fetch_telemetry, query_hal}, stream_manager::{StreamManager, StreamConfig}.
// END_AI_HEADER

// bsdos-core library: Cap'n Proto codec, HAL client, stream manager

pub mod capnp;
pub mod hal;
pub mod protocol;
pub mod stream_manager;
pub mod streams_conf;

#[cfg(feature = "with-bridge")]
pub mod config;

#[cfg(feature = "with-bridge")]
pub mod zenoh_config;

#[cfg(feature = "with-bridge")]
pub mod wayland_forwarder;

// Cap'n Proto generated code from stream.capnp
pub mod stream_capnp {
    include!(concat!(env!("OUT_DIR"), "/stream_capnp.rs"));
}
