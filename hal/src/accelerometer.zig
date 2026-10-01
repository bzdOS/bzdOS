// START_AI_HEADER
// MODULE: hal/src/accelerometer.zig
// PURPOSE: ST LIS2DE12 (PinePhone) / MXC6655 3-axis accelerometer driver over /dev/iic1 with orientation detection (portrait/landscape/face-up/face-down).
// INTENT: Hot-path read is 1 burst-read of 6 bytes, decodes raw int16 → g via the 2g full-scale constant, and flags raw_ok=false on any I2C failure (consumers fall back to getAccelStub). WHO_AM_I check on init confirms the chip is actually present.
// DEPENDENCIES: std (debug, fmt), libc via @cImport (sys/types, sys/stat, fcntl, unistd, sys/ioctl).
// PUBLIC_API: AccelData, Orientation enum, detectOrientation(data) Orientation, getAccelStub() AccelData, readAccel() AccelData, formatAccelData(data, orientation, buf) ![]u8.
// END_AI_HEADER

// Модуль акселерометра для bsdOS HAL
// Чіп: ST LIS2DE12 (PinePhone) або MXC6655
// Транспорт: I2C (/dev/iic1) або заглушка для QEMU
//
// Дані: прискорення в g (9.8 m/s²)
// Частота: до 100Hz (для auto-rotation)
// 240Hz з IRQ режимом — майбутнє
//
// Стек-only, без heap аллокацій (обов'язково на hot path)

const std = @import("std");
const builtin = @import("builtin");
const i2c = @import("i2c.zig");
const log_debug = builtin.mode == .Debug;

// C headers для I2C на FreeBSD
const c = if (builtin.target.os.tag == .freebsd) @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
}) else @cImport({
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

// ────────────────────────────────────────────────────────────────────────────
// LIS2DE12: реєстри та константи
// ────────────────────────────────────────────────────────────────────────────

const LIS2DE12_ADDR: u8 = 0x19;
const LIS2DE12_WHO_AM_I: u8 = 0x0F;
const LIS2DE12_WHO_AM_I_VALUE: u8 = 0x33;

const LIS2DE12_CTRL_REG1: u8 = 0x20;  // ODR, enable axes
const LIS2DE12_CTRL_REG4: u8 = 0x23;  // Full-scale, data format

const LIS2DE12_STATUS_REG: u8 = 0x27; // ZYXDA bit (data ready)

const LIS2DE12_OUT_X_L: u8 = 0x28;    // X low byte
const LIS2DE12_OUT_X_H: u8 = 0x29;
const LIS2DE12_OUT_Y_L: u8 = 0x2A;
const LIS2DE12_OUT_Y_H: u8 = 0x2B;
const LIS2DE12_OUT_Z_L: u8 = 0x2C;
const LIS2DE12_OUT_Z_H: u8 = 0x2D;

// Full-scale: 2g, 4g, 8g, 16g
// 2g = 1 mg/LSB (за замовчуванням)
const FS_2G_SCALE: f32 = 0.001 * 9.80665; // mg/LSB × g/mg

const I2C_DEV = "/dev/iic1";
const I2C_RETRY_COUNT: usize = 3;

// ────────────────────────────────────────────────────────────────────────────
// Публічні типи
// ────────────────────────────────────────────────────────────────────────────

pub const AccelData = extern struct {
    x: f32 = 0.0,   // g
    y: f32 = 0.0,
    z: f32 = -1.0,  // -1g = обличчя вгору (гравітація)
    raw_ok: bool = false,  // чи успішно прочитали з I2C
};

pub const Orientation = enum {
    portrait,
    landscape_left,
    landscape_right,
    face_up,
    face_down,
};

// ────────────────────────────────────────────────────────────────────────────
// Детектування орієнтації (чистий алгоритм, без I/O)
// ────────────────────────────────────────────────────────────────────────────

// detectOrientation:start
//   purpose: pick one of 5 orientation buckets from |z|/|y|/|x| comparison — face-up/face-down when |z| > 0.9 g, otherwise portrait when |y| > |x|, else landscape_left/right by sign of x.
//   input:  data — AccelData (x, y, z in g).
//   output: an Orientation enum value.
//   sideEffects: none (pure).
pub fn detectOrientation(data: AccelData) Orientation {
    const abs_x = if (data.x < 0) -data.x else data.x;
    const abs_y = if (data.y < 0) -data.y else data.y;
    const abs_z = if (data.z < 0) -data.z else data.z;

    // Якщо переважно вертикально — обличчя вгору/вниз
    if (abs_z > 0.9) {
        return if (data.z < 0) .face_up else .face_down;
    }

    // Якщо переважно по Y (вертикально) — портрет
    if (abs_y > abs_x) {
        return .portrait;
    }

    // Інакше — ландшафт з X орієнтацією
    return if (data.x > 0) .landscape_right else .landscape_left;
}
// detectOrientation:end

// ────────────────────────────────────────────────────────────────────────────
// QEMU заглушка (портретна позиція, лежить на столі)
// ────────────────────────────────────────────────────────────────────────────

// getAccelStub:start
//   purpose: return a fixed "lying on the table, portrait" AccelData (y=-1 g, raw_ok=false) used when /dev/iic1 is missing or WHO_AM_I mismatches.
//   input:  none.
//   output: a stub AccelData.
//   sideEffects: none.
pub fn getAccelStub() AccelData {
    return .{
        .x = 0.0,
        .y = -1.0,
        .z = 0.0,
        .raw_ok = false,
    };
}
// getAccelStub:end

// ────────────────────────────────────────────────────────────────────────────
// I2C операції (низькорівневі, без heap)
// ────────────────────────────────────────────────────────────────────────────

// Записати один байт до регістра
// i2cWrite:start
//   purpose: write a single byte to LIS2DE12 register reg over the open /dev/iic1 fd.
//   input:  fd — open /dev/iic1; reg — register address; value — byte to write.
//   output: void; error.I2CWrite on failure.
//   sideEffects: one write(2) syscall.
fn i2cWrite(fd: i32, reg: u8, value: u8) !void {
    return i2c.i2cWrite(fd, reg, value);
}
// i2cWrite:end

// Прочитати один байт з регістра
// i2cRead:start
//   purpose: read a single byte from LIS2DE12 register reg over the open /dev/iic1 fd.
//   input:  fd — open /dev/iic1; reg — register address.
//   output: the byte on success; error.I2CWrite / error.I2CRead on failure.
//   sideEffects: two write(2) + one read(2) syscalls.
fn i2cRead(fd: i32, reg: u8) !u8 {
    return i2c.i2cRead(fd, reg);
}
// i2cRead:end

// Прочитати послідовність байтів (начебто burstread)
// i2cReadBurst:start
//   purpose: burst-read buf.len bytes starting at LIS2DE12 register reg with auto-increment.
//   input:  fd — open /dev/iic1; reg — start register; buf — destination.
//   output: void; error.I2CWrite / error.I2CRead on short transfer.
//   sideEffects: one write(2) + one read(2) syscall.
fn i2cReadBurst(fd: i32, reg: u8, buf: []u8) !void {
    return i2c.i2cReadBurst(fd, reg, buf);
}
// i2cReadBurst:end

// Ініціалізація чіпу (перевірка WHO_AM_I, налаштування)
// i2cInitLIS2DE12:start
//   purpose: verify WHO_AM_I=0x33, then write CTRL_REG1=0x57 (100 Hz ODR, all axes enabled) and CTRL_REG4=0x00 (2 g full-scale).
//   input:  fd — open /dev/iic1.
//   output: void; error.ChipNotFound on WHO_AM_I read failure; error.ChipMismatch on wrong WHO_AM_I value; error.I2CWrite on register writes failing.
//   sideEffects: up to 3 I2C transactions.
fn i2cInitLIS2DE12(fd: i32) !void {
    // Перевіримо чіп: WHO_AM_I повинен бути 0x33
    const who_am_i = i2cRead(fd, LIS2DE12_WHO_AM_I) catch |err| {
        if (log_debug) std.debug.print("[accel] WHO_AM_I read failed: {}\n", .{err});
        return error.ChipNotFound;
    };

    if (who_am_i != LIS2DE12_WHO_AM_I_VALUE) {
        if (log_debug) std.debug.print("[accel] WHO_AM_I mismatch: {x} (expected {x})\n", .{ who_am_i, LIS2DE12_WHO_AM_I_VALUE });
        return error.ChipMismatch;
    }

    // CTRL_REG1: ODR = 100 Hz, enable X Y Z
    // 0x57 = 0101_0111: ODR=100Hz, normal mode, all axes enabled
    try i2cWrite(fd, LIS2DE12_CTRL_REG1, 0x57);

    // CTRL_REG4: Full-scale = 2g (за замовчуванням)
    // 0x00 = 2g scale
    try i2cWrite(fd, LIS2DE12_CTRL_REG4, 0x00);

    if (log_debug) std.debug.print("[accel] LIS2DE12 initialized\n", .{});
}
// i2cInitLIS2DE12:end

// ────────────────────────────────────────────────────────────────────────────
// Основна функція читання (з реального I2C або заглушка)
// ────────────────────────────────────────────────────────────────────────────

// readAccel:start
//   purpose: on FreeBSD open /dev/iic1, initialise the LIS2DE12 (WHO_AM_I=0x33, CTRL_REG1=0x57 for 100 Hz ODR + all axes, CTRL_REG4=0x00 for 2 g full-scale), burst-read 6 bytes from OUT_X_L, decode int16 → g, retry up to 3 times on I2C errors, fall back to the stub on any failure.
//   input:  none.
//   output: a real AccelData with raw_ok=true on success, or the stub on any failure.
//   sideEffects: opens /dev/iic1; up to 3 I2C init transactions + 3 burst reads per call.
pub fn readAccel() AccelData {
    if (builtin.target.os.tag != .freebsd) {
        // Linux QEMU — заглушка
        return getAccelStub();
    }

    // Спробуємо відкрити /dev/iic1
    const fd = c.open(I2C_DEV, c.O_RDWR);
    if (fd < 0) {
        // Немає I2C на цьому хосту (напевно QEMU) — заглушка
        return getAccelStub();
    }
    defer _ = c.close(fd);

    // Ініціалізуємо чіп
    i2cInitLIS2DE12(fd) catch |err| {
        if (log_debug) std.debug.print("[accel] init failed: {}\n", .{err});
        return getAccelStub();
    };

    // Читаємо 6 байтів відразу (X, Y, Z по 2 байти)
    var data: [6]u8 = undefined;

    var retry: usize = 0;
    while (retry < I2C_RETRY_COUNT) : (retry += 1) {
        i2cReadBurst(fd, LIS2DE12_OUT_X_L, &data) catch |err| {
            if (log_debug) std.debug.print("[accel] read failed (retry {d}): {}\n", .{ retry, err });
            continue;
        };

        // Успіх
        break;
    } else {
        // Усі спроби не вдалися
        return getAccelStub();
    }

    // Розбираємо 16-бітні значення (little-endian)
    const raw_x: i16 = @as(i16, data[0]) | (@as(i16, @intCast(data[1])) << 8);
    const raw_y: i16 = @as(i16, data[2]) | (@as(i16, @intCast(data[3])) << 8);
    const raw_z: i16 = @as(i16, data[4]) | (@as(i16, @intCast(data[5])) << 8);

    // Конвертуємо в g (LIS2DE12 в режимі 2g: 1 LSB = ~0.98 мг)
    // Точніше: 1 LSB = 1 mg (в режимі 2g)
    const x_g: f32 = @as(f32, @floatFromInt(raw_x)) * (FS_2G_SCALE / 1000.0);
    const y_g: f32 = @as(f32, @floatFromInt(raw_y)) * (FS_2G_SCALE / 1000.0);
    const z_g: f32 = @as(f32, @floatFromInt(raw_z)) * (FS_2G_SCALE / 1000.0);

    return AccelData{
        .x = x_g,
        .y = y_g,
        .z = z_g,
        .raw_ok = true,
    };
}
// readAccel:end

// ────────────────────────────────────────────────────────────────────────────
// Форматування для JSON (буфер передається явно, без аллокацій)
// ────────────────────────────────────────────────────────────────────────────

// formatAccelData:start
//   purpose: emit `{"ok":true,"value":{"x":<g>,"y":<g>,"z":<g>,"orientation":"<enum>","raw_ok":<bool>}}`.
//   input:  data — AccelData; orientation — Orientation enum; buf — destination scratch buffer.
//   output: a slice of buf with the formatted JSON.
//   sideEffects: none.
pub fn formatAccelData(data: AccelData, orientation: Orientation, buf: []u8) ![]u8 {
    const orient_str: []const u8 = switch (orientation) {
        .portrait => "portrait",
        .landscape_left => "landscape_left",
        .landscape_right => "landscape_right",
        .face_up => "face_up",
        .face_down => "face_down",
    };

    return try std.fmt.bufPrint(buf,
        "{{\"ok\":true,\"value\":{{\"x\":{d:.2},\"y\":{d:.2},\"z\":{d:.2},\"orientation\":\"{s}\",\"raw_ok\":{s}}}}}",
        .{ data.x, data.y, data.z, orient_str, if (data.raw_ok) "true" else "false" });
}
// formatAccelData:end
