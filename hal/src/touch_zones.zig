// START_AI_HEADER
// MODULE: sys-daemon-zig/src/touch_zones.zig
// PURPOSE: Compile-time-constant touch-zone lookup for the 720×1440 PinePhone layout — given (x, y) returns the owning jail name (appA/appB) or null for the status bar / dock / dead zones.
// INTENT: Zero allocations, O(N) with N=2 at compile time (inline for-loop unrolls). Touched only by main.zig's get_touch_zone command and predictive_touch (which uses detectZoneForEvent with a pressure filter). Compile-time asserts verify the layout is sane.
// DEPENDENCIES: std (mem.eql for the comptime tests).
// PUBLIC_API: TouchZone struct, ZONES const slice, detectJail(x, y) ?[]const u8, detectZoneForEvent(x, y, pressure) ?[]const u8, isStatusBar(y) bool, isDock(y) bool.
// END_AI_HEADER

// Compile-time lookup таблица touch зон для предсказания intent.
// Никаких heap аллокаций. O(N) с N = compile-time constant.
// Использование: detectJail(x, y) → jail name или null
//
// PinePhone 720x1440 layout:
//   StatusBar: 0-48px
//   AppCards: 48-1392px
//   Dock: 1392-1440px

const std = @import("std");

pub const TouchZone = struct {
    x1: u16,
    y1: u16,
    x2: u16,
    y2: u16,
    jail: []const u8,
};

// Compile-time constant zones — никаких malloc, всё на BSS
pub const ZONES: []const TouchZone = &.{
    // AppCard appA (top half: y 48..720)
    .{ .x1 = 0, .y1 = 48, .x2 = 720, .y2 = 720, .jail = "appA" },
    // AppCard appB (bottom half: y 720..1392)
    .{ .x1 = 0, .y1 = 720, .x2 = 720, .y2 = 1392, .jail = "appB" },
};

/// Детектировать jail по координатам touch события
/// Возвращает имя jail'а или null если точка снаружи зон
// detectJail:start
//   purpose: scan ZONES (compile-time-unrolled) and return the owning jail name for (x, y) or null if outside any zone.
//   input:  x, y — pixel coordinates.
//   output: "appA" / "appB" / null.
//   sideEffects: none (pure).
pub fn detectJail(x: u16, y: u16) ?[]const u8 {
    inline for (ZONES) |zone| {
        if (x >= zone.x1 and x < zone.x2 and y >= zone.y1 and y < zone.y2) {
            return zone.jail;
        }
    }
    return null;
}
// detectJail:end

/// Детектировать jail с учётом давления (фильтр шума)
/// Игнорирует нажатия с низким давлением (< 10 единиц)
// detectZoneForEvent:start
//   purpose: pressure-filtered wrapper around detectJail — returns null when pressure < 10 (treats it as noise).
//   input:  x, y — pixel coordinates; pressure — touch pressure (0..255).
//   output: detectJail(x, y) or null on low pressure.
//   sideEffects: none.
pub fn detectZoneForEvent(x: u16, y: u16, pressure: u8) ?[]const u8 {
    if (pressure < 10) return null;
    return detectJail(x, y);
}
// detectZoneForEvent:end

/// Возвращает true если координаты в StatusBar (0-48px)
// isStatusBar:start
//   purpose: true if y < 48 (top status-bar strip on the 720×1440 layout).
//   input:  y — pixel coordinate.
//   output: bool.
//   sideEffects: none.
pub fn isStatusBar(y: u16) bool {
    return y < 48;
}
// isStatusBar:end

/// Возвращает true если координаты в Dock (1392-1440px)
// isDock:start
//   purpose: true if y >= 1392 (bottom dock strip on the 720×1440 layout).
//   input:  y — pixel coordinate.
//   output: bool.
//   sideEffects: none.
pub fn isDock(y: u16) bool {
    return y >= 1392;
}
// isDock:end

// ── Compile-time verification ────────────────────────────────────────────────────

comptime {
    // Тест 1: центр appA (360, 400) должен вернуть "appA"
    const result1 = detectJail(360, 400);
    if (result1 == null or !std.mem.eql(u8, result1.?, "appA")) {
        @compileError("touch zone logic broken: (360,400) should be appA");
    }

    // Тест 2: центр appB (360, 1000) должен вернуть "appB"
    const result2 = detectJail(360, 1000);
    if (result2 == null or !std.mem.eql(u8, result2.?, "appB")) {
        @compileError("touch zone logic broken: (360,1000) should be appB");
    }

    // Тест 3: StatusBar (360, 20) должен вернуть null
    const result3 = detectJail(360, 20);
    if (result3 != null) {
        @compileError("touch zone logic broken: (360,20) should be null (statusbar)");
    }

    // Тест 4: Dock (360, 1420) должен вернуть null
    const result4 = detectJail(360, 1420);
    if (result4 != null) {
        @compileError("touch zone logic broken: (360,1420) should be null (dock)");
    }

    // Тест 5: detectZoneForEvent с низким давлением должен вернуть null
    const result5 = detectZoneForEvent(360, 400, 5);
    if (result5 != null) {
        @compileError("touch zone logic broken: low pressure should return null");
    }

    // Тест 6: detectZoneForEvent с нормальным давлением должен работать
    const result6 = detectZoneForEvent(360, 400, 50);
    if (result6 == null or !std.mem.eql(u8, result6.?, "appA")) {
        @compileError("touch zone logic broken: normal pressure should detect zone");
    }

    // Тест 7: isStatusBar
    if (!isStatusBar(30)) {
        @compileError("isStatusBar(30) should be true");
    }
    if (isStatusBar(100)) {
        @compileError("isStatusBar(100) should be false");
    }

    // Тест 8: isDock
    if (!isDock(1400)) {
        @compileError("isDock(1400) should be true");
    }
    if (isDock(1000)) {
        @compileError("isDock(1000) should be false");
    }
}
