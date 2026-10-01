// START_AI_HEADER
// MODULE: hal/src/gps.zig
// PURPOSE: NMEA 0183 GPS parser for the Quectel L96 on /dev/ttyu1 — RMC (position + fix validity) and GGA (accuracy, satellites, HDOP) sentence parsers, plus a 64-byte cache-line GpsData output struct.
// INTENT: Phase 1: parser + QEMU stub. Phase 2 will open /dev/ttyu1 @ 9600 baud and read NMEA lines into these parsers. Phase 3 will check jail permission before returning. No allocator, no heap — GpsData is one cache line.
// DEPENDENCIES: std (fmt, mem, debug), builtin (target os).
// PUBLIC_API: GpsData (64 B extern struct), parseNmeaDegrees(dmm_str) f64, parseGprmc(line) GpsData, parseGpgga(line) GpsData, getGpsStub() GpsData, getLocationData() GpsData, formatGpsData(data, buf) ![]u8, runTests() void.
// END_AI_HEADER

// GPS NMEA Parser для PinePhone Quectel L96
// Протокол: UART /dev/ttyu1 @ 9600 baud, NMEA 0183
//
// Phase 1: Stub + Parser skeleton
//   - QEMU: returns (0.0, 0.0, false)
//   - Parser: RMC (position), GGA (accuracy, satellites)
//   - No real UART I/O yet (Phase 2)

const std = @import("std");
const builtin = @import("builtin");

// ─────────────────────────────────────────────────────────────────────────────
// GpsData структура — выравнена по 64 байт (cache-line Cortex-A53)
// ─────────────────────────────────────────────────────────────────────────────

pub const GpsData = extern struct {
    lat: f64 = 0.0,           // Latitude in decimal degrees
    lon: f64 = 0.0,           // Longitude in decimal degrees
    accuracy_m: f32 = 9999.0, // Horizontal accuracy in meters (9999 = invalid)
    valid: bool = false,      // true if fix is valid
    satellites: u8 = 0,       // Number of satellites in fix
    hdop: f32 = 99.9,         // Horizontal Dilution of Precision
    _pad: [31]u8 = undefined, // Padding to 64 bytes (aarch64 cache line)

    comptime {
        std.debug.assert(@sizeOf(GpsData) == 64);
        std.debug.assert(@alignOf(GpsData) == 8);
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// NMEA RMC Parser
// $GPRMC,HHMMSS,A/V,LLLL.LLLL,N/S,YYYYY.YYYY,E/W,speed,bearing,DDMMYY,magvar,E/W*hh
// ─────────────────────────────────────────────────────────────────────────────

// parseNmeaDegrees:start
//   purpose: convert an NMEA lat/lon field (DDMM.MMMM or DDDMM.MMMM, no hemisphere) to decimal degrees.
//   input:  dmm_str — raw NMEA coordinate string.
//   output: decimal degrees (f64); 0.0 on parse failure or string shorter than 5 chars.
//   sideEffects: none (pure).
fn parseNmeaDegrees(dmm_str: []const u8) f64 {
    // DDMM.MMMM (latitude) или DDDMM.MMMM (longitude)
    // Return as decimal degrees

    if (dmm_str.len < 5) return 0.0;

    var dot_pos: ?usize = null;
    for (dmm_str, 0..) |c, i| {
        if (c == '.') {
            dot_pos = i;
            break;
        }
    }

    const dot = dot_pos orelse return 0.0;
    if (dot < 3) return 0.0;

    // Degree part: first (dot-2) digits
    const deg_len = dot - 2;
    const deg_str = dmm_str[0..deg_len];
    const deg = std.fmt.parseInt(u16, deg_str, 10) catch return 0.0;

    // Minute part: 2 digits before dot + fractional after
    const min_str = dmm_str[deg_len..];
    const min_frac = std.fmt.parseFloat(f64, min_str) catch return 0.0;

    // Convert to decimal degrees: DD + MM.mmmm / 60
    return @as(f64, @floatFromInt(deg)) + (min_frac / 60.0);
}
// parseNmeaDegrees:end

// parseGprmc:start
//   purpose: parse a $GPRMC sentence — only the position and validity flag are extracted today; speed/bearing/date are consumed and dropped; assumes 5 m accuracy when the fix is valid.
//   input:  line — a single NMEA line beginning with "$GPRMC".
//   output: a GpsData; valid=true only on an 'A' (active) status field; lat/lon signs flipped on S/W hemispheres.
//   sideEffects: none (pure).
pub fn parseGprmc(line: []const u8) GpsData {
    var result = GpsData{};

    if (!std.mem.startsWith(u8, line, "$GPRMC")) {
        return result;
    }

    // Split by comma
    var fields = std.mem.splitSequence(u8, line, ",");

    // 0: $GPRMC
    _ = fields.next();

    // 1: HHMMSS (time)
    _ = fields.next();

    // 2: A (valid) / V (invalid)
    const status_str = fields.next() orelse return result;
    if (status_str.len < 1 or status_str[0] != 'A') {
        return result; // Invalid fix
    }
    result.valid = true;

    // 3: Latitude (LLLL.LLLL)
    const lat_str = fields.next() orelse return result;
    result.lat = parseNmeaDegrees(lat_str);

    // 4: N/S
    const ns_str = fields.next() orelse return result;
    if (ns_str.len > 0 and ns_str[0] == 'S') {
        result.lat = -result.lat;
    }

    // 5: Longitude (YYYYY.YYYY)
    const lon_str = fields.next() orelse return result;
    result.lon = parseNmeaDegrees(lon_str);

    // 6: E/W
    const ew_str = fields.next() orelse return result;
    if (ew_str.len > 0 and ew_str[0] == 'W') {
        result.lon = -result.lon;
    }

    // Speed (knots) — skip
    _ = fields.next();

    // Bearing (degrees) — skip
    _ = fields.next();

    // Date (DDMMYY) — skip for now
    _ = fields.next();

    // Default accuracy: assume 5m for valid GPS fix (no HDOP in RMC)
    result.accuracy_m = 5.0;

    return result;
}
// parseGprmc:end

// ─────────────────────────────────────────────────────────────────────────────
// NMEA GGA Parser (для точности + количество спутников)
// $GPGGA,HHMMSS,lat,N/S,lon,E/W,fix_quality,num_sats,hdop,altitude,M,...*hh
// ─────────────────────────────────────────────────────────────────────────────

// parseGpgga:start
//   purpose: parse a $GPGGA sentence — position + fix_quality (valid only when ≥ 1) + number of satellites + HDOP; accuracy ≈ HDOP × 5 m.
//   input:  line — a single NMEA line beginning with "$GPGGA".
//   output: a GpsData with valid, satellites, hdop, accuracy_m populated.
//   sideEffects: none (pure).
pub fn parseGpgga(line: []const u8) GpsData {
    var result = GpsData{};

    if (!std.mem.startsWith(u8, line, "$GPGGA")) {
        return result;
    }

    var fields = std.mem.splitSequence(u8, line, ",");

    // 0: $GPGGA
    _ = fields.next();

    // 1: HHMMSS
    _ = fields.next();

    // 2: Latitude
    const lat_str = fields.next() orelse return result;
    result.lat = parseNmeaDegrees(lat_str);

    // 3: N/S
    const ns_str = fields.next() orelse return result;
    if (ns_str.len > 0 and ns_str[0] == 'S') {
        result.lat = -result.lat;
    }

    // 4: Longitude
    const lon_str = fields.next() orelse return result;
    result.lon = parseNmeaDegrees(lon_str);

    // 5: E/W
    const ew_str = fields.next() orelse return result;
    if (ew_str.len > 0 and ew_str[0] == 'W') {
        result.lon = -result.lon;
    }

    // 6: Fix quality (0=invalid, 1=GPS, 2=DGPS, 3=PPS, 4=RTK, 5=Float RTK, 6=Estimated)
    const fix_str = fields.next() orelse return result;
    const fix_quality = std.fmt.parseInt(u8, fix_str, 10) catch 0;
    result.valid = (fix_quality >= 1);

    // 7: Number of satellites
    const sats_str = fields.next() orelse return result;
    result.satellites = std.fmt.parseInt(u8, sats_str, 10) catch 0;

    // 8: HDOP (Horizontal Dilution of Precision)
    const hdop_str = fields.next() orelse return result;
    result.hdop = std.fmt.parseFloat(f32, hdop_str) catch 99.9;

    // Accuracy estimate: HDOP * ~5m per unit
    // (empirical: 1.0 HDOP ≈ 5m horizontal accuracy)
    result.accuracy_m = result.hdop * 5.0;

    return result;
}
// parseGpgga:end

// ─────────────────────────────────────────────────────────────────────────────
// QEMU Stub: возвращает (0.0, 0.0, false) — off-shore position
// ─────────────────────────────────────────────────────────────────────────────

// getGpsStub:start
//   purpose: return a "0,0 / 9999 m accuracy / invalid" GpsData (off-shore) used when /dev/ttyu1 is missing or the parser sees no fix.
//   input:  none.
//   output: the stub GpsData with valid=false.
//   sideEffects: none.
pub fn getGpsStub() GpsData {
    return .{
        .lat = 0.0,
        .lon = 0.0,
        .accuracy_m = 9999.0,
        .valid = false,
        .satellites = 0,
        .hdop = 99.9,
        ._pad = undefined,
    };
}
// getGpsStub:end

// ─────────────────────────────────────────────────────────────────────────────
// Main entry point: получить GPS данные (stub для Phase 1)
// ─────────────────────────────────────────────────────────────────────────────

// getLocationData:start
//   purpose: main GPS entry point — today always returns getGpsStub() (Phase 1); Phase 2 will open /dev/ttyu1, read NMEA lines, and dispatch to parseGprmc / parseGpgga; Phase 3 will gate the result on jail permission.
//   input:  none.
//   output: a GpsData; stub for now.
//   sideEffects: none in Phase 1.
pub fn getLocationData() GpsData {
    // Phase 1: QEMU stub
    // Phase 2: check if builtin.target.os.tag == .freebsd && /dev/ttyu1 readable
    //   → read UART, parse NMEA
    // Phase 3: check jail permission before returning

    if (builtin.target.os.tag == .freebsd) {
        // Device path: /dev/ttyu1 (real hardware)
        // TODO Phase 2: open /dev/ttyu1, read NMEA lines, parse
        // For now: return stub (PinePhone will be tested in Phase 2)
        return getGpsStub();
    } else {
        // Non-FreeBSD (QEMU on Linux host)
        return getGpsStub();
    }
}
// getLocationData:end

// ─────────────────────────────────────────────────────────────────────────────
// Format GpsData as JSON response
// ─────────────────────────────────────────────────────────────────────────────

// formatGpsData:start
//   purpose: emit the JSON for `get_location` — full lat/lon/accuracy/satellites/HDOP when valid, or the fixed "0,0,9999,invalid" structure otherwise.
//   input:  data — GpsData; buf — destination scratch buffer.
//   output: a slice of buf with the formatted JSON.
//   sideEffects: none.
pub fn formatGpsData(data: GpsData, buf: []u8) ![]u8 {
    if (data.valid) {
        return try std.fmt.bufPrint(
            buf,
            "{{\"ok\":true,\"value\":{{\"lat\":{d:.6},\"lon\":{d:.6},\"accuracy_m\":{d:.1},\"valid\":true,\"satellites\":{d},\"hdop\":{d:.2}}}}}",
            .{ data.lat, data.lon, data.accuracy_m, data.satellites, data.hdop },
        );
    } else {
        // Invalid/stub: return structure with valid=false
        return try std.fmt.bufPrint(
            buf,
            "{{\"ok\":true,\"value\":{{\"lat\":0.0,\"lon\":0.0,\"accuracy_m\":9999.0,\"valid\":false,\"satellites\":0,\"hdop\":99.9}}}}",
            .{},
        );
    }
}
// formatGpsData:end

// ─────────────────────────────────────────────────────────────────────────────
// Test: NMEA parser (stack-only, no allocator)
// ─────────────────────────────────────────────────────────────────────────────

// runTests:start
//   purpose: in-process smoke test of the NMEA parsers + formatGpsData; prints to stderr so it can be invoked from a one-shot `zig run` or unit-test binary.
//   input:  none.
//   output: void; never asserts (debug-print only today).
//   sideEffects: writes to stderr via std.debug.print; no file/network I/O.
pub fn runTests() void {
    // Test RMC parser
    const rmc_line = "$GPRMC,123456,A,5954.8324,N,01045.3132,E,12.3,45.6,050624,2.1,W*7C";
    const rmc_data = parseGprmc(rmc_line);

    std.debug.print("[gps test] RMC parse\n", .{});
    std.debug.print("  lat={d:.6}, lon={d:.6}, valid={}\n", .{ rmc_data.lat, rmc_data.lon, rmc_data.valid });

    // Test GGA parser
    const gga_line = "$GPGGA,123519,4807.038,N,01131.000,E,1,08,0.9,545.4,M,46.9,M,,*42";
    const gga_data = parseGpgga(gga_line);

    std.debug.print("[gps test] GGA parse\n", .{});
    std.debug.print("  lat={d:.6}, lon={d:.6}, sats={d}, hdop={d:.2}, accuracy={d:.1}m, valid={}\n",
        .{ gga_data.lat, gga_data.lon, gga_data.satellites, gga_data.hdop, gga_data.accuracy_m, gga_data.valid });

    // Test stub
    const stub = getGpsStub();
    std.debug.print("[gps test] Stub\n", .{});
    std.debug.print("  lat={d}, lon={d}, valid={}\n", .{ stub.lat, stub.lon, stub.valid });

    // Test formatting
    var fmt_buf: [512]u8 = undefined;
    const stub_json = formatGpsData(stub, &fmt_buf) catch "error";
    std.debug.print("[gps test] JSON format:\n  {s}\n", .{stub_json});
}
// runTests:end
