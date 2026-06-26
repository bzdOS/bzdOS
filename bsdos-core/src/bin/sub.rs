// START_AI_HEADER
// MODULE: bin/sub.rs
// PURPOSE: bsdos-core-sub — CLI that subscribes to the bsdos/telemetry Zenoh keyexpr and prints decoded HardwareStatus lines.
// INTENT: Loopback-only subscriber used to validate the bsdos-core publisher from another shell; forces a 32-byte wire format check via capnp::decode.
// DEPENDENCIES: zenoh (peer mode, connects to tcp/127.0.0.1:7447), bsdos_core::capnp, tokio.
// PUBLIC_API: none (binary entry point only).
// END_AI_HEADER

// bsdos-core-sub: CLI subscriber to "bsdos/telemetry"
// Decodes Cap'n Proto messages and prints metrics

use bsdos_core::capnp;

// main:start
//   purpose: open a Zenoh peer session, subscribe to bsdos/telemetry, and print one stdout line per 32-byte payload decoded as HardwareStatus.
//   input:  none (binary entry; runtime config from zenoh::Config defaults + JSON5 connect endpoint).
//   output: Ok(()) on graceful Zenoh session close; Err on session/subscribe failure (printed via ?).
//   sideEffects: opens a Zenoh peer session on tcp/127.0.0.1:7447; writes to stdout and stderr; loop runs until the subscriber recv() returns Err.
#[tokio::main]
async fn main() -> Result<(), Box<dyn std::error::Error>> {
    eprintln!("[bsdos-core-sub] Starting Zenoh subscriber");

    // Open Zenoh session in peer mode
    // Connect to publisher on loopback TCP (multicast discovery fails in SLIRP)
    let mut config = zenoh::Config::default();
    config.insert_json5("connect/endpoints", "[\"tcp/127.0.0.1:7447\"]")
        .map_err(|e| format!("Failed to insert connect endpoint: {}", e))?;

    let session = zenoh::open(config).await
        .map_err(|e| format!("Failed to open Zenoh session: {}", e))?;

    eprintln!("[bsdos-core-sub] Zenoh session opened, subscribing to bsdos/telemetry");

    let subscriber = session.declare_subscriber("bsdos/telemetry").await
        .map_err(|e| format!("Failed to subscribe: {}", e))?;

    while let Ok(sample) = subscriber.recv() {
        let payload = sample.payload().to_bytes().to_vec();

        if payload.len() == 32 {
            // Convert to fixed 32-byte array
            let mut buf = [0u8; 32];
            buf.copy_from_slice(&payload[..32]);

            match capnp::decode(&buf) {
                Ok((uptime, battery, cpu)) => {
                    println!("uptime={}s battery={}% cpu={}%", uptime, battery, cpu);
                }
                Err(e) => {
                    eprintln!("[sub] Decode error: {}", e);
                }
            }
        } else {
            eprintln!("[sub] Invalid message size: {} bytes (expected 32)", payload.len());
        }
    }

    Ok(())
}
// main:end
