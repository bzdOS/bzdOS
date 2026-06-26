// START_AI_HEADER
// MODULE: sys-daemon-zig/src/platform.zig
// PURPOSE: Compile-time platform detection and capability flags for bsdOS HAL.
//          Resolves -Dplatform=<str> from build.zig into typed enum + bool constants.
// INTENT: All platform-specific feature guards reference these pub const booleans.
//         Zero runtime overhead — every flag is a comptime constant evaluated to
//         a single true/false by the Zig compiler; dead branches are eliminated.
// DEPENDENCIES: build_options (injected by build.zig via addOptions).
// PUBLIC_API: Platform enum, current, has_*, i2c_sensor_bus.
// END_AI_HEADER

// platform.zig:start
//   purpose: Expose comptime hardware capability flags derived from the -Dplatform
//            build option so every HAL module can gate phone-specific code paths
//            without runtime overhead.
//   input:   none — all data comes from @import("build_options").platform ([]const u8)
//            injected at build time.
//   output:  pub const Platform enum, pub const current, pub const has_*, pub const i2c_sensor_bus.
//   sideEffects: none — pure comptime constants, no I/O, no allocations.

const std = @import("std");
const build_options = @import("build_options");

// Platform:start
//   purpose: Enumerate all supported bsdOS hardware targets.
//   input:   none.
//   output:  Platform enum type.
//   sideEffects: none.
pub const Platform = enum {
    // QEMU amd64 — primary dev loop (KVM, Squirrel v0.1.x)
    qemu_amd64,
    // QEMU aarch64 — architectural target (Squirrel v0.1.x, Chimp/Porcupine-ready)
    qemu_aarch64,
    // Banana Pi BPI-M64 (Allwinner A64, Chimp v0.2)
    bpi_m64,
    // Pine64 PinePhone (Allwinner A64 + Mali-400 — same SoC as BPI-M64; Porcupine v0.3)
    pinephone,
};
// Platform:end

// current:start
//   purpose: Resolve the -Dplatform=<str> build option to a typed Platform enum value
//            at comptime.  Falls back to qemu_aarch64 if an unrecognised string is passed.
//   input:   build_options.platform — []const u8 set by build.zig.
//   output:  Platform comptime constant.
//   sideEffects: none.
pub const current: Platform = blk: {
    const s = build_options.platform;
    if (std.mem.eql(u8, s, "qemu_amd64"))    break :blk .qemu_amd64;
    if (std.mem.eql(u8, s, "qemu_aarch64"))  break :blk .qemu_aarch64;
    if (std.mem.eql(u8, s, "bpi_m64"))       break :blk .bpi_m64;
    if (std.mem.eql(u8, s, "pinephone"))     break :blk .pinephone;
    // Unknown platform string — default to qemu_aarch64 (safe QEMU fallback)
    break :blk .qemu_aarch64;
};
// current:end

// ── Phone-only capabilities (PinePhone, Allwinner A64) ───────────────────────────────────

// has_modem:start
//   purpose: True when the target has a cellular modem (EC25 modem on PinePhone (A64)).
//   input:   none.  output: bool.  sideEffects: none.
pub const has_modem: bool = current == .pinephone;
// has_modem:end

// has_sim:start
//   purpose: True when the target has a SIM card slot.
//   input:   none.  output: bool.  sideEffects: none.
pub const has_sim: bool = current == .pinephone;
// has_sim:end

// has_sms:start
//   purpose: True when the target can send/receive SMS via AT+CMGS.
//   input:   none.  output: bool.  sideEffects: none.
pub const has_sms: bool = current == .pinephone;
// has_sms:end

// has_haptic:start
//   purpose: True when the target has a haptic vibration motor (GPIO/PWM).
//   input:   none.  output: bool.  sideEffects: none.
pub const has_haptic: bool = current == .pinephone;
// has_haptic:end

// has_battery:start
//   purpose: True when the target has a battery and ACPI/fuel-gauge driver.
//   input:   none.  output: bool.  sideEffects: none.
pub const has_battery: bool = current == .pinephone;
// has_battery:end

// has_gps:start
//   purpose: True when the target has an on-board GPS/GNSS receiver.
//   input:   none.  output: bool.  sideEffects: none.
pub const has_gps: bool = current == .pinephone;
// has_gps:end

// has_accelerometer:start
//   purpose: True when the target has a 3-axis accelerometer (accelerometer on PinePhone, A64).
//   input:   none.  output: bool.  sideEffects: none.
pub const has_accelerometer: bool = current == .pinephone;
// has_accelerometer:end

// has_magnetometer:start
//   purpose: True when the target has a magnetometer / compass (magnetometer on PinePhone, A64).
//   input:   none.  output: bool.  sideEffects: none.
pub const has_magnetometer: bool = current == .pinephone;
// has_magnetometer:end

// has_proximity:start
//   purpose: True when the target has a proximity + ambient-light sensor (STK3311).
//   input:   none.  output: bool.  sideEffects: none.
pub const has_proximity: bool = current == .pinephone;
// has_proximity:end

// has_predictive_touch:start
//   purpose: True when the target runs the predictive-touch pre-warping pipeline.
//   input:   none.  output: bool.  sideEffects: none.
pub const has_predictive_touch: bool = current == .pinephone;
// has_predictive_touch:end

// has_ghost_radio:start
//   purpose: True when the ghost-radio stealth scan thread should be started.
//   input:   none.  output: bool.  sideEffects: none.
pub const has_ghost_radio: bool = current == .pinephone;
// has_ghost_radio:end

// ── Real-hardware capabilities (BPI + PinePhone) ─────────────────────────────

// has_i2c:start
//   purpose: True when the target has I2C buses exposed via /dev/iic*.
//            Both BPI-M64 (Allwinner A64 TWI) and PinePhone (A64 TWI) qualify;
//            QEMU guests do not expose iic devices.
//   input:   none.  output: bool.  sideEffects: none.
pub const has_i2c: bool = current != .qemu_amd64 and current != .qemu_aarch64;
// has_i2c:end

// has_audio:start
//   purpose: True when the target has OSS audio (/dev/dsp*) via a real codec driver.
//   input:   none.  output: bool.  sideEffects: none.
pub const has_audio: bool = current == .bpi_m64 or current == .pinephone;
// has_audio:end

// has_backlight:start
//   purpose: True when the target has a backlight controller via /dev/backlight/*.
//   input:   none.  output: bool.  sideEffects: none.
pub const has_backlight: bool = current == .bpi_m64 or current == .pinephone;
// has_backlight:end

// ── Per-platform I2C sensor bus path ─────────────────────────────────────────

// i2c_sensor_bus:start
//   purpose: FreeBSD /dev/iic* path for the primary sensor bus on each platform.
//            Returns "" for QEMU targets (has_i2c is false there; callers must check
//            has_i2c before using this path).
//   input:   none.
//   output:  []const u8 comptime path literal.
//   sideEffects: none.
pub const i2c_sensor_bus: []const u8 = switch (current) {
    // Allwinner A64 TWI0 (BPI-M64): sensors on bus 0
    .bpi_m64       => "/dev/iic0",
    // Allwinner A64 TWI (PinePhone): same SoC as BPI-M64; sensor bus
    .pinephone => "/dev/iic1",
    // QEMU targets have no I2C — empty string; guard with has_i2c before use
    else           => "",
};
// i2c_sensor_bus:end

// ── Compile-time self-check ───────────────────────────────────────────────────

// Ensure the resolved platform name round-trips through the enum (catches typos).
comptime {
    _ = current;
    // has_i2c must be false on both QEMU targets
    if (current == .qemu_amd64 or current == .qemu_aarch64) {
        std.debug.assert(!has_i2c);
        std.debug.assert(i2c_sensor_bus.len == 0);
    }
}
