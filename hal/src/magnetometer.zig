// START_AI_HEADER
// MODULE: hal/src/magnetometer.zig
// PURPOSE: LIS3MDL magnetometer driver over /dev/iic1 (PinePhone) — reads X/Y/Z in µT and converts to a 0..360° compass heading via atan2.
// INTENT: Burst-read 6 bytes, scale by ±4 gauss constant (1 LSB ≈ 0.0122 µT), heading = atan2(y, x) → 0..360. WHO_AM_I check on init confirms the chip. Stub on any I2C failure.
// DEPENDENCIES: std (math.atan2, fmt, debug), libc via @cImport (sys/types, sys/stat, fcntl, unistd, sys/ioctl, math.h).
// PUBLIC_API: MagData struct, getMagStub() MagData, calcHeading(x, y) f32, readMag() MagData, formatMagData(data, buf) ![]u8.
// END_AI_HEADER

// Magnetometer для bsdOS HAL
// Чіп: LIS3MDL (PinePhone)
// Адреса I2C: 0x1c
// Транспорт: I2C (/dev/iic1) або заглушка для QEMU
//
// Дані: X, Y, Z в мікротеслах (μT), розраховуємо heading (компасний курс)
// Частота: на запит
// Стек-only, без heap аллокацій

const std = @import("std");
const builtin = @import("builtin");
const i2c = @import("i2c.zig");

// C headers для I2C на FreeBSD
const c = if (builtin.target.os.tag == .freebsd) @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("math.h");
}) else @cImport({
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("math.h");
});

// ────────────────────────────────────────────────────────────────────────────
// LIS3MDL: реєстри та константи
// ────────────────────────────────────────────────────────────────────────────

const LIS3MDL_ADDR: u8 = 0x1c;
const LIS3MDL_WHO_AM_I: u8 = 0x0F;
const LIS3MDL_WHO_AM_I_VALUE: u8 = 0x3D;

const LIS3MDL_CTRL_REG1: u8 = 0x20;   // ODR, enable axes
const LIS3MDL_CTRL_REG2: u8 = 0x21;   // Full-scale
const LIS3MDL_CTRL_REG3: u8 = 0x22;   // Operating mode
const LIS3MDL_CTRL_REG4: u8 = 0x23;   // Z-axis mode

const LIS3MDL_OUT_X_L: u8 = 0x28;     // X low byte
const LIS3MDL_OUT_X_H: u8 = 0x29;
const LIS3MDL_OUT_Y_L: u8 = 0x2A;
const LIS3MDL_OUT_Y_H: u8 = 0x2B;
const LIS3MDL_OUT_Z_L: u8 = 0x2C;
const LIS3MDL_OUT_Z_H: u8 = 0x2D;

// Full-scale: ±4 gauss = 1 LSB ≈ 0.122 mG = 0.0122 μT
const FS_4G_SCALE: f32 = 0.0122;

const I2C_DEV = "/dev/iic1";
const I2C_RETRY_COUNT: usize = 3;

// ────────────────────────────────────────────────────────────────────────────
// Публічні типи
// ────────────────────────────────────────────────────────────────────────────

pub const MagData = struct {
    x: f32 = 0.0,              // мікротесла (μT)
    y: f32 = 0.0,
    z: f32 = 0.0,
    heading_deg: f32 = 0.0,    // компасний курс 0-360°
    raw_ok: bool = false,      // чи успішно прочитали з I2C
};

// ────────────────────────────────────────────────────────────────────────────
// QEMU заглушка
// ────────────────────────────────────────────────────────────────────────────

// getMagStub:start
//   purpose: return a hard-coded "north-pointing" MagData (x=20 µT, y=0, z=-45 µT, heading=0°, raw_ok=false) used when /dev/iic1 is missing.
//   input:  none.
//   output: the stub MagData.
//   sideEffects: none.
pub fn getMagStub() MagData {
    return .{
        .x = 20.0,
        .y = 0.0,
        .z = -45.0,
        .heading_deg = 0.0,
        .raw_ok = false,
    };
}
// getMagStub:end

// ────────────────────────────────────────────────────────────────────────────
// Розрахунок компасного курсу з X, Y компонентів
// ────────────────────────────────────────────────────────────────────────────

// calcHeading:start
//   purpose: convert (x, y) magnetic field components in µT to a 0..360° compass heading (0° = east, 90° = north, 180° = west, 270° = south).
//   input:  x, y — µT readings.
//   output: heading in degrees, normalised to [0, 360).
//   sideEffects: none.
pub fn calcHeading(x: f32, y: f32) f32 {
    // atan2(y, x) → радіани → градуси
    // atan2 повертає значення від -π до π
    // 0° =北на схід (х позитивний, у = 0)
    // 90° = север (х = 0, у позитивний)
    // Нормалізуємо до 0-360°
    const rad = std.math.atan2(y, x);
    var deg = rad * (180.0 / std.math.pi);

    // Конвертуємо з діапазону [-180, 180] до [0, 360]
    if (deg < 0) {
        deg += 360.0;
    }

    return deg;
}
// calcHeading:end

// ────────────────────────────────────────────────────────────────────────────
// I2C операції (низькорівневі, без heap)
// ────────────────────────────────────────────────────────────────────────────

// Прочитати один байт з регістра
// i2cRead:start
//   purpose: read a single byte from LIS3MDL register reg over the open /dev/iic1 fd.
//   input:  fd — open /dev/iic1; reg — register address.
//   output: the byte on success; error.I2CWrite / error.I2CRead on failure.
//   sideEffects: two write(2) + one read(2) syscalls.
fn i2cRead(fd: i32, reg: u8) !u8 {
    return i2c.i2cRead(fd, reg);
}
// i2cRead:end

// i2cReadBurst:start
//   purpose: burst-read buf.len bytes starting at LIS3MDL register reg with auto-increment.
//   input:  fd — open /dev/iic1; reg — start register; buf — destination.
//   output: void; error.I2CWrite / error.I2CRead on short transfer.
//   sideEffects: one write(2) + one read(2) syscall.
fn i2cReadBurst(fd: i32, reg: u8, buf: []u8) !void {
    return i2c.i2cReadBurst(fd, reg, buf);
}
// i2cReadBurst:end

// Записати один байт до регістра
// i2cWrite:start
//   purpose: write a single byte to LIS3MDL register reg over the open /dev/iic1 fd.
//   input:  fd — open /dev/iic1; reg — register address; value — byte to write.
//   output: void; error.I2CWrite on failure.
//   sideEffects: one write(2) syscall.
fn i2cWrite(fd: i32, reg: u8, value: u8) !void {
    return i2c.i2cWrite(fd, reg, value);
}
// i2cWrite:end

// Ініціалізація чіпу (перевірка WHO_AM_I, налаштування)
// i2cInitLIS3MDL:start
//   purpose: verify WHO_AM_I=0x3D, then write CTRL_REG1=0x70 (80 Hz ODR, temp-comp), CTRL_REG2=0x00 (±4 gauss), CTRL_REG3=0x00 (continuous), CTRL_REG4=0x0C (Z ultra-high-performance).
//   input:  fd — open /dev/iic1.
//   output: void; error.ChipNotFound / error.ChipMismatch / error.I2CWrite on failure.
//   sideEffects: up to 5 I2C transactions.
fn i2cInitLIS3MDL(fd: i32) !void {
    // Перевіримо чіп: WHO_AM_I повинен бути 0x3D
    const who_am_i = i2cRead(fd, LIS3MDL_WHO_AM_I) catch |err| {
        std.debug.print("[mag] WHO_AM_I read failed: {}\n", .{err});
        return error.ChipNotFound;
    };

    if (who_am_i != LIS3MDL_WHO_AM_I_VALUE) {
        std.debug.print("[mag] WHO_AM_I mismatch: {x} (expected {x})\n", .{ who_am_i, LIS3MDL_WHO_AM_I_VALUE });
        return error.ChipMismatch;
    }

    // CTRL_REG1: ODR = 80 Hz, Temperature compensated (Temp En)
    // 0x70 = 0111_0000: Temp en, Z-axis ultra-high performance, ODR = 80Hz
    try i2cWrite(fd, LIS3MDL_CTRL_REG1, 0x70);

    // CTRL_REG2: Full-scale = ±4 gauss (за замовчуванням)
    // 0x00 = ±4 gauss
    try i2cWrite(fd, LIS3MDL_CTRL_REG2, 0x00);

    // CTRL_REG3: Operating mode = continuous conversion
    // 0x00 = continuous conversion
    try i2cWrite(fd, LIS3MDL_CTRL_REG3, 0x00);

    // CTRL_REG4: Z-axis ultra-high performance mode
    // 0x0C = Z-axis ultra-high performance
    try i2cWrite(fd, LIS3MDL_CTRL_REG4, 0x0C);

    std.debug.print("[mag] LIS3MDL initialized\n", .{});
}
// i2cInitLIS3MDL:end

// ────────────────────────────────────────────────────────────────────────────
// Основна функція читання (з реального I2C або заглушка)
// ────────────────────────────────────────────────────────────────────────────

// readMag:start
//   purpose: open /dev/iic1, init LIS3MDL (WHO_AM_I=0x3D, CTRL_REG1=0x70 for 80 Hz ODR + temp-comp, CTRL_REG2=0x00 for ±4 gauss, CTRL_REG3=0x00 for continuous, CTRL_REG4=0x0C for Z ultra-high-performance), burst-read 6 bytes from OUT_X_L, scale and compute heading, retry up to 3 times on I2C errors, fall back to the stub on any failure.
//   input:  none.
//   output: a MagData; raw_ok=true on success.
//   sideEffects: opens /dev/iic1; up to 3 I2C init transactions + 3 burst reads per call.
pub fn readMag() MagData {
    if (builtin.target.os.tag != .freebsd) {
        // Linux QEMU — заглушка
        return getMagStub();
    }

    // Спробуємо відкрити /dev/iic1
    const fd = c.open(I2C_DEV, c.O_RDWR);
    if (fd < 0) {
        // Немає I2C на цьому хосту (напевно QEMU) — заглушка
        return getMagStub();
    }
    defer _ = c.close(fd);

    // Ініціалізуємо чіп
    i2cInitLIS3MDL(fd) catch |err| {
        std.debug.print("[mag] init failed: {}\n", .{err});
        return getMagStub();
    };

    // Читаємо 6 байтів відразу (X, Y, Z по 2 байти)
    var data: [6]u8 = undefined;

    var retry: usize = 0;
    while (retry < I2C_RETRY_COUNT) : (retry += 1) {
        i2cReadBurst(fd, LIS3MDL_OUT_X_L, &data) catch |err| {
            std.debug.print("[mag] read failed (retry {d}): {}\n", .{ retry, err });
            continue;
        };

        // Успіх
        break;
    } else {
        // Усі спроби не вдалися
        return getMagStub();
    }

    // Розбираємо 16-бітні значення (little-endian)
    const raw_x: i16 = @as(i16, data[0]) | (@as(i16, @intCast(data[1])) << 8);
    const raw_y: i16 = @as(i16, data[2]) | (@as(i16, @intCast(data[3])) << 8);
    const raw_z: i16 = @as(i16, data[4]) | (@as(i16, @intCast(data[5])) << 8);

    // Конвертуємо в μT (LIS3MDL в режимі ±4 gauss: 1 LSB ≈ 0.0122 μT)
    const x_ut: f32 = @as(f32, @floatFromInt(raw_x)) * FS_4G_SCALE;
    const y_ut: f32 = @as(f32, @floatFromInt(raw_y)) * FS_4G_SCALE;
    const z_ut: f32 = @as(f32, @floatFromInt(raw_z)) * FS_4G_SCALE;

    // Розраховуємо компасний курс з X, Y
    const heading = calcHeading(x_ut, y_ut);

    return MagData{
        .x = x_ut,
        .y = y_ut,
        .z = z_ut,
        .heading_deg = heading,
        .raw_ok = true,
    };
}
// readMag:end

// ────────────────────────────────────────────────────────────────────────────
// Форматування для JSON (буфер передається явно, без аллокацій)
// ────────────────────────────────────────────────────────────────────────────

// formatMagData:start
//   purpose: emit `{"ok":true,"value":{"heading":<deg>,"x":<µT>,"y":<µT>,"z":<µT>,"raw_ok":<bool>}}` from a MagData.
//   input:  data — MagData; buf — destination scratch buffer.
//   output: a slice of buf with the formatted JSON.
//   sideEffects: none.
pub fn formatMagData(data: MagData, buf: []u8) ![]u8 {
    return try std.fmt.bufPrint(buf,
        "{{\"ok\":true,\"value\":{{\"heading\":{d:.1},\"x\":{d:.2},\"y\":{d:.2},\"z\":{d:.2},\"raw_ok\":{s}}}}}",
        .{ data.heading_deg, data.x, data.y, data.z, if (data.raw_ok) "true" else "false" });
}
// formatMagData:end
