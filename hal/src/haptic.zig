// START_AI_HEADER
// MODULE: sys-daemon-zig/src/haptic.zig
// PURPOSE: Haptic feedback (vibration motor) on the SGM3602 LRA — currently a debug-print stub; Phase 2 will drive GPIO/PWM via /dev/gpioc0 ioctl.
// INTENT: Define the HapticPattern enum up-front so callers and the stub agree; the Phase 1 stub still goes through playPattern/parsePattern so the wire path is exercised end-to-end.
// DEPENDENCIES: std (fmt, mem, debug).
// PUBLIC_API: HapticPattern enum (short, double, long, error), playPattern(pattern) void, formatHapticResp(buf, ok, error_msg) ![]u8, parsePattern(s) ?HapticPattern.
// END_AI_HEADER

// Haptic feedback (vibration motor) — PinePhone SGM3602 LRA
// Phase 1: stub with debug print
// Phase 2: real GPIO/PWM via /dev/gpioc0 ioctl
//
// Паттерны вибрации:
//   short:  50ms
//   double: 50ms + 100ms gap + 50ms
//   long:   300ms
//   error:  100ms × 3 with 50ms gaps

const std = @import("std");

/// Haptic vibration patterns
pub const HapticPattern = enum {
    short,    // 50ms pulse
    double,   // two 50ms pulses with gap
    long,     // 300ms long pulse
    @"error", // triple 100ms with gaps
};

/// Phase 1: stub implementation (debug print only)
/// TODO Phase 2: real GPIO/PWM via libc ioctl
// playPattern:start
//   purpose: trigger the named haptic pattern; Phase 1 prints the pattern name to stderr as a stub; Phase 2 will GPIO-toggle the LRA driver for the pattern duration (50 / 100+50 / 300 / 100×3 ms).
//   input:  pattern — HapticPattern enum value.
//   output: void.
//   sideEffects: writes to stderr (Phase 1); future GPIO toggles.
pub fn playPattern(pattern: HapticPattern) void {
    const name: []const u8 = switch (pattern) {
        .short => "short",
        .double => "double",
        .long => "long",
        .@"error" => "error",
    };
    std.debug.print("[haptic] playing {s} (stub)\n", .{name});
}
// playPattern:end

/// Format HAL response: {"ok":true} or {"ok":false,"error":"msg"}
// formatHapticResp:start
//   purpose: emit the HAL response for a haptic command — `{"ok":true}` on success, `{"ok":false,"error":"<msg>"}` on failure, `{"ok":false}` if no error_msg was given.
//   input:  buf — destination scratch buffer; ok — success flag; error_msg — optional human-readable reason.
//   output: a slice of buf with the formatted JSON.
//   sideEffects: none.
pub fn formatHapticResp(buf: []u8, ok: bool, error_msg: ?[]const u8) ![]u8 {
    if (ok) {
        return try std.fmt.bufPrint(buf, "{{\"ok\":true}}", .{});
    } else if (error_msg) |msg| {
        return try std.fmt.bufPrint(buf, "{{\"ok\":false,\"error\":\"{s}\"}}", .{msg});
    } else {
        return try std.fmt.bufPrint(buf, "{{\"ok\":false}}", .{});
    }
}
// formatHapticResp:end

/// Parse pattern from string: "short", "double", "long", "error"
// parsePattern:start
//   purpose: map a string identifier ("short" / "double" / "long" / "error") to a HapticPattern enum value.
//   input:  s — pattern name (case-sensitive, exact match).
//   output: HapticPattern or null on no match.
//   sideEffects: none (pure).
pub fn parsePattern(s: []const u8) ?HapticPattern {
    if (std.mem.eql(u8, s, "short")) return .short;
    if (std.mem.eql(u8, s, "double")) return .double;
    if (std.mem.eql(u8, s, "long")) return .long;
    if (std.mem.eql(u8, s, "error")) return .@"error";
    return null;
}
// parsePattern:end
