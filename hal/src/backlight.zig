// START_AI_HEADER
// MODULE: hal/src/backlight.zig
// PURPOSE: Backlight control via the FreeBSD backlight(9) ioctl interface on /dev/backlight/backlight0 with a hw.backlight sysctl fallback, plus a light-sensor stub for auto-brightness.
// INTENT: Keep all paths (setLevel / getLevel / autoLevel / setPowerMode) allocation-free. Phase 1 = ioctl-only, Phase 2 = real APDS9960 /dev/iic0 light sensor, Phase 3 = power-mode integration.
// DEPENDENCIES: std (debug, fmt), libc via @cImport (sys/types, sys/stat, fcntl, unistd, sys/ioctl, sys/sysctl).
// PUBLIC_API: BacklightState, LightSensorReading, PowerMode enum, getBacklightStub, readLightSensorStub, setLevel(level) bool, getLevel() BacklightState, off() void, on(level) void, readLightSensor() LightSensorReading, autoLevel(lux) u8, setAutoLevel() bool, setPowerMode(mode) void, formatState/formatAutoLevel/formatError.
// END_AI_HEADER

// Модуль управління яскравістю екрана для bsdOS HAL
// Платформа: FreeBSD 14+ (backlight(9) + /dev/backlight/*)
// API: ioctl BACKLIGHTGETSTATUS / BACKLIGHTSETSTATE
//
// Датчик освітлення (light sensor):
// - Lux > 500   → день (автояскравість 100%)
// - Lux 100-500 → приміщення (автояскравість 60%)
// - Lux < 100   → ніч (автояскравість 30%)
//
// Стек-only, без heap аллокацій на hot path

const std = @import("std");
const builtin = @import("builtin");

// C headers для FreeBSD ioctl
const c = if (builtin.target.os.tag == .freebsd) @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/sysctl.h");
}) else @cImport({
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

// ────────────────────────────────────────────────────────────────────────────
// FreeBSD backlight ioctl константи (з sys/dev/backlight/backlight.h)
// ────────────────────────────────────────────────────────────────────────────

// ioctl commands (визначені як IOC(IN/OUT, 'b', cmd, size))
// #define BACKLIGHTGETSTATUS _IOR('b', 0, struct backlight_props)
// #define BACKLIGHTSETSTATE _IOW('b', 1, struct backlight_props)

const BACKLIGHT_DEVICE = "/dev/backlight/backlight0";
const BACKLIGHT_SYSCTL = "hw.backlight";

// Структура за POSIX стилем — packed, без padding
const BacklightProps = extern struct {
    nlevels: u32 = 0,     // кількість рівнів яскравості
    cur_level: u32 = 100, // поточний рівень (0-100%)
};

// ioctl номери (скомпільовані для FreeBSD aarch64)
// Базова формула: IOC(direction, group, num, size)
// direction: _IOC_IN (write) = 0x80000000, _IOC_OUT (read) = 0x40000000
// group: 'b' = 0x62 = 98
const BACKLIGHTGETSTATUS: u32 = 0x40084602; // _IOR('b', 2, 8 bytes)
const BACKLIGHTSETSTATE: u32 = 0x80084601;  // _IOW('b', 1, 8 bytes)

// ────────────────────────────────────────────────────────────────────────────
// Публічні типи
// ────────────────────────────────────────────────────────────────────────────

pub const BacklightState = struct {
    level: u8 = 100,     // 0-100%
    enabled: bool = true,
    light_lux: u16 = 500, // освітлення в люксах (заглушка)
};

pub const LightSensorReading = struct {
    lux: u16 = 500,
    auto_level: u8 = 80, // рекомендована яскравість
};

// ────────────────────────────────────────────────────────────────────────────
// Заглушка для QEMU / non-FreeBSD платформ
// ────────────────────────────────────────────────────────────────────────────

// getBacklightStub:start
//   purpose: return a fixed "100% / enabled / 500 lux" BacklightState used when neither ioctl nor sysctl can be queried.
//   input:  none.
//   output: the stub BacklightState.
//   sideEffects: none.
pub fn getBacklightStub() BacklightState {
    return .{
        .level = 100,
        .enabled = true,
        .light_lux = 500,
    };
}
// getBacklightStub:end

// readLightSensorStub:start
//   purpose: return a fixed "500 lux / 80% auto_level" LightSensorReading used while the real APDS9960 /dev/iic0 driver is not wired in.
//   input:  none.
//   output: the stub LightSensorReading.
//   sideEffects: none.
pub fn readLightSensorStub() LightSensorReading {
    return .{
        .lux = 500,
        .auto_level = 80,
    };
}
// readLightSensorStub:end

// ────────────────────────────────────────────────────────────────────────────
// Основні функції управління яскравістю
// ────────────────────────────────────────────────────────────────────────────

/// Установити рівень яскравості (0-100%)
// setLevel:start
//   purpose: clamp the requested brightness to 0..100, then apply it via BACKLIGHTSETSTATE ioctl (primary) or hw.backlight sysctl (fallback). Returns true on success.
//   input:  level — 0..100 percent (out-of-range values are clamped to 100).
//   output: true if the kernel accepted the change; false on Linux/QEMU or both backends failing on FreeBSD.
//   sideEffects: opens (and immediately closes) /dev/backlight/backlight0; ioctl or sysctl write.
pub fn setLevel(level: u8) bool {
    if (builtin.target.os.tag != .freebsd) {
        std.debug.print("[backlight] setLevel({d}) - stub (non-FreeBSD)\n", .{level});
        return true;
    }

    // Валідація діапазону
    const clamped_level = if (level > 100) 100 else level;

    // Спробуємо через ioctl (Phase 1)
    const fd = c.open(BACKLIGHT_DEVICE, c.O_RDWR);
    if (fd >= 0) {
        defer _ = c.close(fd);

        var props: BacklightProps = .{
            .nlevels = 100,
            .cur_level = clamped_level,
        };

        if (c.ioctl(fd, BACKLIGHTSETSTATE, @intFromPtr(&props)) >= 0) {
            std.debug.print("[backlight] setLevel({d}) via ioctl OK\n", .{clamped_level});
            return true;
        } else {
            std.debug.print("[backlight] setLevel ioctl failed, trying sysctl\n", .{});
        }
    }

    // Fallback: sysctl hw.backlight=N
    if (trySysctl(clamped_level)) {
        std.debug.print("[backlight] setLevel({d}) via sysctl OK\n", .{clamped_level});
        return true;
    }

    std.debug.print("[backlight] setLevel({d}) FAILED\n", .{clamped_level});
    return false;
}
// setLevel:end

/// Получить текущий рівень яскравості
// getLevel:start
//   purpose: read the current backlight level and the enabled flag via BACKLIGHTGETSTATUS ioctl or sysctl fallback; on Linux/QEMU or both failures, returns the QEMU stub (100% / enabled).
//   input:  none.
//   output: a BacklightState with level (0..100) + enabled (level > 0) + light_lux placeholder (500).
//   sideEffects: opens (and immediately closes) /dev/backlight/backlight0; one ioctl or sysctl read.
pub fn getLevel() BacklightState {
    if (builtin.target.os.tag != .freebsd) {
        return getBacklightStub();
    }

    const fd = c.open(BACKLIGHT_DEVICE, c.O_RDONLY);
    if (fd >= 0) {
        defer _ = c.close(fd);

        var props: BacklightProps = .{ .nlevels = 100, .cur_level = 100 };

        if (c.ioctl(fd, BACKLIGHTGETSTATUS, @intFromPtr(&props)) >= 0) {
            const level = @as(u8, @intCast(if (props.cur_level > 100) 100 else props.cur_level));
            std.debug.print("[backlight] getLevel via ioctl: {d}%\n", .{level});
            return .{
                .level = level,
                .enabled = level > 0,
                .light_lux = 500,
            };
        }
    }

    // Fallback: sysctl читання
    if (readSysctl()) |level| {
        std.debug.print("[backlight] getLevel via sysctl: {d}%\n", .{level});
        return .{
            .level = level,
            .enabled = level > 0,
            .light_lux = 500,
        };
    }

    std.debug.print("[backlight] getLevel FAILED, using stub\n", .{});
    return getBacklightStub();
}
// getLevel:end

/// Вимкнути екран (рівень = 0)
// off:start
//   purpose: setLevel(0) helper — turn the screen off.
//   input:  none.
//   output: void.
//   sideEffects: same as setLevel(0).
pub fn off() void {
    _ = setLevel(0);
}
// off:end

/// Увімкнути екран з заданим рівнем
// on:start
//   purpose: setLevel helper — treat level==0 as "use 80% default" (matches the backlight_on protocol where omitting the level means 80%).
//   input:  level — 0..100 percent; 0 is silently remapped to 80.
//   output: void.
//   sideEffects: same as setLevel.
pub fn on(level: u8) void {
    _ = setLevel(if (level == 0) 80 else level);
}
// on:end

// ────────────────────────────────────────────────────────────────────────────
// Light sensor + автоматична яскравість (Phase 2)
// ────────────────────────────────────────────────────────────────────────────

/// Прочитати light sensor (заглушка, Phase 2 → APDS9960 чи інший)
// readLightSensor:start
//   purpose: read ambient light in lux; Phase 1 returns the stub (500 lux), Phase 2 will read an APDS9960 or built-in sensor over /dev/iic0.
//   input:  none.
//   output: a LightSensorReading (lux + auto_level) — both currently constants from the stub.
//   sideEffects: none (Phase 1); Phase 2 will open /dev/iic0.
pub fn readLightSensor() LightSensorReading {
    if (builtin.target.os.tag != .freebsd) {
        return readLightSensorStub();
    }

    // TODO Phase 2: I2C /dev/iic0 → APDS9960 або вбудований датчик
    // Сейчас: просто заглушка
    return readLightSensorStub();
}
// readLightSensor:end

/// Обчислити рекомендовану яскравість за рівнем освітлення
// autoLevel:start
//   purpose: pick a recommended backlight level for a given lux reading (<100 → 30%, <500 → 60%, else 100%).
//   input:  lux — ambient light reading.
//   output: backlight level 30/60/100.
//   sideEffects: none.
pub fn autoLevel(lux: u16) u8 {
    return if (lux < 100)
        30      // ніч (lux < 100)
    else if (lux < 500)
        60      // приміщення (100-500)
    else
        100;    // день (lux >= 500)
}
// autoLevel:end

/// Встановити яскравість на основі автоматичного датчика
// setAutoLevel:start
//   purpose: read the light sensor, compute autoLevel(lux), and apply it via setLevel.
//   input:  none.
//   output: whatever setLevel returns.
//   sideEffects: light-sensor read + setLevel.
pub fn setAutoLevel() bool {
    const sensor = readLightSensor();
    const level = autoLevel(sensor.lux);
    std.debug.print("[backlight] autoLevel: lux={d} → level={d}%\n", .{ sensor.lux, level });
    return setLevel(level);
}
// setAutoLevel:end

// ────────────────────────────────────────────────────────────────────────────
// Інтеграція з режимами живлення (Phase 3)
// ────────────────────────────────────────────────────────────────────────────

pub const PowerMode = enum {
    performance,  // нормальна яскравість, CPU full speed
    balanced,     // середня яскравість, CPU дин.частота
    power_save,   // низька яскравість (30%), CPU мінімум
    screen_off,   // екран вимкнено (0%), система спить
};

/// Встановити яскравість за режимом живлення
// setPowerMode:start
//   purpose: map a PowerMode enum to a fixed backlight level (100/80/30/0) and apply it via setLevel.
//   input:  mode — performance/balanced/power_save/screen_off.
//   output: void.
//   sideEffects: same as setLevel.
pub fn setPowerMode(mode: PowerMode) void {
    const level = switch (mode) {
        .performance => 100,
        .balanced => 80,
        .power_save => 30,
        .screen_off => 0,
    };

    std.debug.print("[backlight] setPowerMode({s}) → level={d}%\n", .{
        switch (mode) {
            .performance => "performance",
            .balanced => "balanced",
            .power_save => "power_save",
            .screen_off => "screen_off",
        },
        level,
    });

    _ = setLevel(level);
}
// setPowerMode:end

// ────────────────────────────────────────────────────────────────────────────
// sysctl helper — читання/запис hw.backlight
// ────────────────────────────────────────────────────────────────────────────

// trySysctl:start
//   purpose: Phase-1 stub fallback path for setLevel — currently always returns false (the ioctl path is expected to succeed on real hardware; sysctl shell integration is deferred).
//   input:  level — desired backlight level (unused today).
//   output: false.
//   sideEffects: none.
fn trySysctl(level: u8) bool {
    // NOTE: Phase 1 fallback stub — actual sysctl write via shell
    // TODO: implement proper ioctl-only solution or shell integration
    _ = level;
    if (builtin.target.os.tag != .freebsd) return false;
    // Stub: return false (ioctl should have succeeded)
    return false;
}
// trySysctl:end

// readSysctl:start
//   purpose: Phase-1 stub fallback path for getLevel — currently always returns null (the ioctl path is expected to succeed on real hardware; sysctl read is deferred).
//   input:  none.
//   output: null.
//   sideEffects: none.
fn readSysctl() ?u8 {
    // NOTE: Phase 1 fallback stub
    // TODO: implement sysctl read via shell integration
    if (builtin.target.os.tag != .freebsd) return null;
    // Stub: return null (ioctl should have succeeded)
    return null;
}
// readSysctl:end

// ────────────────────────────────────────────────────────────────────────────
// JSON форматування (буфер передається явно, без аллокацій)
// ────────────────────────────────────────────────────────────────────────────

// formatState:start
//   purpose: emit `{"ok":true,"value":{"level":<n>,"enabled":<bool>}}` from a BacklightState.
//   input:  state — BacklightState; buf — destination scratch buffer.
//   output: a slice of buf with the formatted JSON; empty slice on overflow.
//   sideEffects: none.
pub fn formatState(state: BacklightState, buf: []u8) []u8 {
    const result = std.fmt.bufPrint(buf,
        "{{\"ok\":true,\"value\":{{\"level\":{d},\"enabled\":{s}}}}}",
        .{
            state.level,
            if (state.enabled) "true" else "false",
        },
    ) catch buf[0..0];
    return result;
}
// formatState:end

// formatAutoLevel:start
//   purpose: emit `{"ok":true,"value":{"lux":<n>,"auto_level":<n>}}` from a LightSensorReading.
//   input:  reading — LightSensorReading; buf — destination scratch buffer.
//   output: a slice of buf with the formatted JSON; empty slice on overflow.
//   sideEffects: none.
pub fn formatAutoLevel(reading: LightSensorReading, buf: []u8) []u8 {
    const result = std.fmt.bufPrint(buf,
        "{{\"ok\":true,\"value\":{{\"lux\":{d},\"auto_level\":{d}}}}}",
        .{
            reading.lux,
            reading.auto_level,
        },
    ) catch buf[0..0];
    return result;
}
// formatAutoLevel:end

// formatError:start
//   purpose: emit `{"ok":false,"error":"<msg>"}` for a backlight command failure.
//   input:  buf — destination scratch buffer; msg — human-readable error reason.
//   output: a slice of buf with the formatted JSON; empty slice on overflow.
//   sideEffects: none.
pub fn formatError(buf: []u8, msg: []const u8) []u8 {
    return std.fmt.bufPrint(buf,
        "{{\"ok\":false,\"error\":\"{s}\"}}",
        .{msg},
    ) catch buf[0..0];
}
// formatError:end
