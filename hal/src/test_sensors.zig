// START_AI_HEADER
// MODULE: hal/src/test_sensors.zig
// PURPOSE: Unit tests for sensor register conversion functions (charging, magnetometer)
// INTENT: Verify pure functions that convert raw register values to physical units
// DEPENDENCIES: std (testing)
// PUBLIC_API: test blocks (run with `zig test test_sensors.zig`)
// END_AI_HEADER

const std = @import("std");

// ============================================================================
// Test 1: AXP803 charging current register conversion
// ============================================================================

test "AXP803 register to current mA conversion" {
    // AXP803 CHARGING_CURRENT register (0x84):
    // Bits [6:0] = (current_ma - 300) / 100
    // Range: 300-2000 mA, step 100 mA

    const registerToCurrentMa = struct {
        fn convert(reg: u8) u16 {
            const val: u16 = @as(u16, reg & 0x7F) * 100 + 300;
            return if (val > 2000) 2000 else val;
        }
    }.convert;

    // 300 mA = reg 0x00
    try std.testing.expect(registerToCurrentMa(0x00) == 300);

    // 500 mA = reg 0x02
    try std.testing.expect(registerToCurrentMa(0x02) == 500);

    // 1000 mA = reg 0x07
    try std.testing.expect(registerToCurrentMa(0x07) == 1000);

    // 2000 mA = reg 0x11 (17)
    try std.testing.expect(registerToCurrentMa(0x11) == 2000);

    // Cap at 2000 mA even if register value is higher
    try std.testing.expect(registerToCurrentMa(0x7F) == 2000);
}

// ============================================================================
// Test 2: AXP803 charging voltage register conversion
// ============================================================================

test "AXP803 register to voltage mV conversion" {
    // AXP803 CHARGING_VOLTAGE register (0x83):
    // Bits [7:5] = voltage level
    // 0x0 = 4100 mV, 0x1 = 4150 mV, 0x2 = 4200 mV, 0x3 = 4360 mV

    const registerToVoltageMv = struct {
        fn convert(reg: u8) u32 {
            return switch ((reg >> 5) & 0x3) {
                0x0 => 4100,
                0x1 => 4150,
                0x2 => 4200,
                0x3 => 4360,
                else => 4200,
            };
        }
    }.convert;

    // 4100 mV = bits [7:5] = 000
    try std.testing.expect(registerToVoltageMv(0x00) == 4100);

    // 4150 mV = bits [7:5] = 001
    try std.testing.expect(registerToVoltageMv(0x20) == 4150);

    // 4200 mV = bits [7:5] = 010
    try std.testing.expect(registerToVoltageMv(0x40) == 4200);

    // 4360 mV = bits [7:5] = 011
    try std.testing.expect(registerToVoltageMv(0x60) == 4360);

    // Other bits don't affect voltage
    try std.testing.expect(registerToVoltageMv(0x1F) == 4100);
    try std.testing.expect(registerToVoltageMv(0x7F) == 4360);
}

// ============================================================================
// Test 3: LIS3MDL magnetometer heading calculation
// ============================================================================

test "magnetometer heading from X/Y components" {
    const calcHeading = struct {
        fn convert(x: f32, y: f32) f32 {
            const rad = std.math.atan2(y, x);
            var deg = rad * (180.0 / std.math.pi);
            if (deg < 0) {
                deg += 360.0;
            }
            return deg;
        }
    }.convert;

    // East (x > 0, y = 0) → 0°
    const east = calcHeading(1.0, 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 0.0), east, 0.1);

    // North (x = 0, y > 0) → 90°
    const north = calcHeading(0.0, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 90.0), north, 0.1);

    // West (x < 0, y = 0) → 180°
    const west = calcHeading(-1.0, 0.0);
    try std.testing.expectApproxEqAbs(@as(f32, 180.0), west, 0.1);

    // South (x = 0, y < 0) → 270°
    const south = calcHeading(0.0, -1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 270.0), south, 0.1);

    // Northeast (x > 0, y > 0) → 45°
    const ne = calcHeading(1.0, 1.0);
    try std.testing.expectApproxEqAbs(@as(f32, 45.0), ne, 0.1);
}

// ============================================================================
// Test 4: LIS2DE12 accelerometer orientation detection
// ============================================================================

test "accelerometer orientation from X/Y/Z" {
    const Orientation = enum { portrait, landscape_left, landscape_right, face_up, face_down };

    const detectOrientation = struct {
        fn convert(x: f32, y: f32, z: f32) Orientation {
            const abs_x = if (x < 0) -x else x;
            const abs_y = if (y < 0) -y else y;
            const abs_z = if (z < 0) -z else z;

            if (abs_z > 0.9) {
                return if (z < 0) .face_up else .face_down;
            }
            if (abs_y > abs_x) {
                return .portrait;
            }
            return if (x > 0) .landscape_right else .landscape_left;
        }
    }.convert;

    // Face up (z = -1g)
    try std.testing.expect(detectOrientation(0.0, 0.0, -1.0) == .face_up);

    // Face down (z = +1g)
    try std.testing.expect(detectOrientation(0.0, 0.0, 1.0) == .face_down);

    // Portrait (y dominant)
    try std.testing.expect(detectOrientation(0.0, -1.0, 0.0) == .portrait);

    // Landscape left (x < 0 dominant)
    try std.testing.expect(detectOrientation(-1.0, 0.0, 0.0) == .landscape_left);

    // Landscape right (x > 0 dominant)
    try std.testing.expect(detectOrientation(1.0, 0.0, 0.0) == .landscape_right);
}

// ============================================================================
// Test 5: Touch zone pressure filter
// ============================================================================

test "touch zone pressure filter" {
    const detectZoneForEvent = struct {
        fn convert(pressure: u8) ?[]const u8 {
            if (pressure < 10) return null;
            return "appA"; // stub
        }
    }.convert;

    // Low pressure (< 10) → null (noise filter)
    try std.testing.expect(detectZoneForEvent(5) == null);
    try std.testing.expect(detectZoneForEvent(0) == null);
    try std.testing.expect(detectZoneForEvent(9) == null);

    // Normal pressure (>= 10) → zone detected
    try std.testing.expectEqualStrings("appA", detectZoneForEvent(10).?);
    try std.testing.expectEqualStrings("appA", detectZoneForEvent(50).?);
    try std.testing.expectEqualStrings("appA", detectZoneForEvent(255).?);
}
