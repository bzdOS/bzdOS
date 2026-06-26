// START_AI_HEADER
// MODULE: hal.rs
// PURPOSE: HAL client that fetches (uptime, battery, cpu) from a sys-daemon Unix-socket text endpoint.
// INTENT: Keep the bsdos-core data path free of unsafe and untyped JSON — caller hands in a socket path, gets three plain integers back; all parsing errors collapse to zero values rather than panicking.
// DEPENDENCIES: std::io::{Read, Write}, std::os::unix::net::UnixStream, std::time::Duration.
// PUBLIC_API: fetch_telemetry(socket_path) -> (u64, u32, u32).  query_hal is private (per-call socket open).
// END_AI_HEADER

// HAL client: reads telemetry via Unix socket text protocol
// Protocol: send {"cmd":"get_uptime"}\n, receive {"ok":true,"value":"..."}\n

use std::io::{Read, Write};
use std::os::unix::net::UnixStream;
use std::time::Duration;

// query_hal:start
//   purpose: open a one-shot Unix socket to the HAL, send a single JSON-like command, parse the `"value"` field out of the response.
//   input:  socket_path — absolute path to the sys-daemon Unix socket; cmd — text command name (e.g. "get_uptime", "get_battery", "get_cpu_usage").
//   output: Ok(value_string) when the response contains a parseable `"value":"..."` field; Err when socket I/O or UTF-8 conversion fails.
//   sideEffects: opens a new AF_UNIX SOCK_STREAM connection on every call; sets 2-second read/write timeouts; writes one command line; reads up to 256 bytes and discards the rest.
/// Query HAL for a single metric via text protocol
fn query_hal(socket_path: &str, cmd: &str) -> Result<String, Box<dyn std::error::Error>> {
    let mut stream = UnixStream::connect(socket_path)?;
    stream.set_read_timeout(Some(Duration::from_secs(2)))?;
    stream.set_write_timeout(Some(Duration::from_secs(2)))?;

    // Send command as JSON-like text
    let request = format!(r#"{{"cmd":"{}"}}"#, cmd);
    stream.write_all(request.as_bytes())?;
    stream.write_all(b"\n")?;

    // Read response
    let mut buf = [0u8; 256];
    let n = stream.read(&mut buf)?;
    let response = std::str::from_utf8(&buf[..n])?;

    // Parse simple JSON: {"ok":true,"value":"..."}
    // Extract the value field
    if let Some(start) = response.find(r#""value":"#) {
        let value_start = start + 8; // skip `"value":"`
        if let Some(end) = response[value_start..].find('"') {
            let value = response[value_start..value_start + end].to_string();
            return Ok(value);
        }
    }

    Err("Failed to parse HAL response".into())
}
// query_hal:end

// fetch_telemetry:start
//   purpose: aggregate three HAL queries (uptime, battery, cpu) into one tuple for the periodic telemetry publisher.
//   input:  socket_path — passed through to query_hal on every internal call.
//   output: (uptime_secs, battery_pct, cpu_pct) — on any per-field error the field is replaced with 0; whole call never panics.
//   sideEffects: three sequential Unix-socket round trips per invocation; each call opens its own connection.
/// Fetch telemetry from HAL: (uptime_secs, battery_pct, cpu_pct)
/// Returns (0, 0, 0) on error without panicking
pub fn fetch_telemetry(socket_path: &str) -> (u64, u32, u32) {
    let uptime = match query_hal(socket_path, "get_uptime") {
        Ok(val) => val.parse::<u64>().unwrap_or(0),
        Err(_) => 0,
    };

    let battery = match query_hal(socket_path, "get_battery") {
        Ok(val) => val.parse::<u32>().unwrap_or(0),
        Err(_) => 0,
    };

    let cpu = match query_hal(socket_path, "get_cpu_usage") {
        Ok(val) => {
            // Response format: {"ok":true,"value":{"pct":N}}
            // Extract the pct value
            if let Some(pct_start) = val.find(r#""pct":"#) {
                let start = pct_start + 6; // skip `"pct":`
                if let Some(end) = val[start..].find(|c: char| !c.is_numeric()) {
                    match val[start..start + end].parse::<u32>() {
                        Ok(v) => v,
                        Err(_) => 0,
                    }
                } else {
                    match val[start..].parse::<u32>() {
                        Ok(v) => v,
                        Err(_) => 0,
                    }
                }
            } else {
                0
            }
        }
        Err(_) => 0,
    };

    (uptime, battery, cpu)
}
// fetch_telemetry:end

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_fetch_telemetry_no_socket() {
        // Should not panic, just return zeros
        let (uptime, battery, cpu) = fetch_telemetry("/nonexistent/socket");
        assert_eq!(uptime, 0);
        assert_eq!(battery, 0);
        assert_eq!(cpu, 0);
    }
}
