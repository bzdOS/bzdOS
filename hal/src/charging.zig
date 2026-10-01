// START_AI_HEADER
// MODULE: sys-daemon-zig/src/charging.zig
// PURPOSE: AXP803 PMIC charging-status driver over /dev/iic0 — read charging flag + current (mA) + voltage (mV) and write the charging-current limit register.
// INTENT: Stack-only, no heap, retries per I2C transaction; falls back to a fixed "active charging" stub when /dev/iic0 is missing (QEMU / no PMIC).
// DEPENDENCIES: std (debug, fmt), libc via @cImport (sys/types, sys/stat, fcntl, unistd, sys/ioctl).
// PUBLIC_API: ChargingInfo struct, getChargingStub() ChargingInfo, readCharging() ChargingInfo, setChargingLimit(current_ma) bool, formatChargingInfo/formatSetSuccess/formatError.
// END_AI_HEADER

// Модуль управления зарядкой батареи для bsdOS HAL
// Чіп: AXP803 (PinePhone) PMIC
// Транспорт: I2C (/dev/iic0) або заглушка для QEMU
//
// Дані: статус зарядки, ток (mA), напруга (mV)
// Частота: опитування 1Hz (або мати пер за подією від PMIC)
//
// Стек-only, без heap аллокацій (обов'язково на hot path)

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
}) else @cImport({
    @cInclude("sys/stat.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

// ────────────────────────────────────────────────────────────────────────────
// AXP803: реєстри та константи
// ────────────────────────────────────────────────────────────────────────────

const AXP803_ADDR: u8 = 0x34;
const AXP803_REG_CHARGING_STATUS: u8 = 0x01;  // [6] = CHARGING flag
const AXP803_REG_CHARGING_CURRENT: u8 = 0x84; // [6:0] = 300–2000mA
const AXP803_REG_CHARGING_VOLTAGE: u8 = 0x83; // [7:5] = voltage limit

const I2C_DEV = "/dev/iic0";
const I2C_RETRY_COUNT: usize = 3;

// ────────────────────────────────────────────────────────────────────────────
// Публічні типи
// ────────────────────────────────────────────────────────────────────────────

pub const ChargingInfo = extern struct {
    charging: bool = false,      // чи йде зарядка
    current_ma: u16 = 0,         // ток (300–2000 mA)
    voltage_mv: u32 = 0,         // напруга (4100–4360 mV)
    limit_80pct: bool = true,    // включена 80% лімітація (future)
};

// ────────────────────────────────────────────────────────────────────────────
// QEMU заглушка (активна зарядка, стандартні значення)
// ────────────────────────────────────────────────────────────────────────────

// getChargingStub:start
//   purpose: return a hard-coded "actively charging" ChargingInfo (1000 mA @ 4200 mV, 80% limit on) used when /dev/iic0 is unavailable.
//   input:  none.
//   output: a ChargingInfo with the stub values.
//   sideEffects: none.
pub fn getChargingStub() ChargingInfo {
    return .{
        .charging = true,
        .current_ma = 1000,
        .voltage_mv = 4200,
        .limit_80pct = true,
    };
}
// getChargingStub:end

// ────────────────────────────────────────────────────────────────────────────
// I2C операції (низькорівневі, без heap)
// ────────────────────────────────────────────────────────────────────────────

// Прочитати один байт з регістра
// i2cRead:start
//   purpose: read a single byte from AXP803 register reg over the open /dev/iic0 fd (write-then-read, plain I²C transaction).
//   input:  fd — open /dev/iic0; reg — register address.
//   output: the byte on success; error.I2CWrite if the register-select write fails; error.I2CRead if the data read returns < 1 byte.
//   sideEffects: two write(2) + one read(2) syscalls.
fn i2cRead(fd: i32, reg: u8) !u8 {
    return i2c.i2cRead(fd, reg);
}
// i2cRead:end

// i2cWrite:start
//   purpose: write a single byte to AXP803 register reg over the open /dev/iic0 fd.
//   input:  fd — open /dev/iic0; reg — register address; value — byte to write.
//   output: void; error.I2CWrite if write(2) returns < 2 bytes or negative.
//   sideEffects: one write(2) syscall.
fn i2cWrite(fd: i32, reg: u8, value: u8) !void {
    return i2c.i2cWrite(fd, reg, value);
}
// i2cWrite:end

// ────────────────────────────────────────────────────────────────────────────
// Конвертування регістрів в значення
// ────────────────────────────────────────────────────────────────────────────

// Конвертувати регістр 0x84 в mA (300–2000mA, шаг 100mA)
// registerToCurrentMa:start
//   purpose: decode the 7-bit AXP803 CHARGING_CURRENT register to mA — (raw & 0x7F) * 100 + 300, capped at 2000.
//   input:  reg — raw register byte.
//   output: charging current in mA.
//   sideEffects: none (pure).
fn registerToCurrentMa(reg: u8) u16 {
    const val: u16 = (reg & 0x7F) * 100 + 300;
    return if (val > 2000) 2000 else val;
}
// registerToCurrentMa:end

// Конвертувати регістр 0x83 в mV (бітти [7:5] = 4100/4150/4200/4360mV)
// registerToVoltageMv:start
//   purpose: decode the AXP803 CHARGING_VOLTAGE register bits[7:5] to one of 4100/4150/4200/4360 mV (else 4200 mV).
//   input:  reg — raw register byte.
//   output: charging voltage in mV.
//   sideEffects: none (pure).
fn registerToVoltageMv(reg: u8) u32 {
    return switch ((reg >> 5) & 0x3) {
        0x0 => 4100,
        0x1 => 4150,
        0x2 => 4200,
        0x3 => 4360,
        else => 4200,
    };
}
// registerToVoltageMv:end

// ────────────────────────────────────────────────────────────────────────────
// Основна функція читання (з реального I2C або заглушка)
// ────────────────────────────────────────────────────────────────────────────

// readCharging:start
//   purpose: open /dev/iic0 RDWR; read the CHARGING_STATUS (0x01), CHARGING_CURRENT (0x84) and CHARGING_VOLTAGE (0x83) registers; decode via registerToCurrentMa / registerToVoltageMv; per-register retries (I2C_RETRY_COUNT) before falling back to the stub on total failure.
//   input:  none.
//   output: a ChargingInfo struct (always populated; stub on hardware failure).
//   sideEffects: opens /dev/iic0; up to 3×3 I2C transactions per call.
pub fn readCharging() ChargingInfo {
    if (builtin.target.os.tag != .freebsd) {
        // Linux QEMU — заглушка
        return getChargingStub();
    }

    // Спробуємо відкрити /dev/iic0
    const fd = c.open(I2C_DEV, c.O_RDWR);
    if (fd < 0) {
        // Немає I2C на цьому хосту (напевно QEMU) — заглушка
        std.debug.print("[charging] I2C not available, using stub\n", .{});
        return getChargingStub();
    }
    defer _ = c.close(fd);

    var charging = false;
    var current_ma: u16 = 0;
    var voltage_mv: u32 = 4200;

    // Читаємо регістр 0x01: charging status (бит 6 = CHARGING)
    var retry: usize = 0;
    while (retry < I2C_RETRY_COUNT) : (retry += 1) {
        const status = i2cRead(fd, AXP803_REG_CHARGING_STATUS) catch |err| {
            std.debug.print("[charging] status read failed (retry {d}): {}\n", .{ retry, err });
            continue;
        };

        charging = (status & 0x40) != 0;
        break;
    } else {
        std.debug.print("[charging] all status read attempts failed\n", .{});
        return getChargingStub();
    }

    // Читаємо регістр 0x84: charging current
    retry = 0;
    while (retry < I2C_RETRY_COUNT) : (retry += 1) {
        const current_reg = i2cRead(fd, AXP803_REG_CHARGING_CURRENT) catch |err| {
            std.debug.print("[charging] current read failed (retry {d}): {}\n", .{ retry, err });
            continue;
        };

        current_ma = registerToCurrentMa(current_reg);
        break;
    } else {
        std.debug.print("[charging] all current read attempts failed\n", .{});
        current_ma = 0;
    }

    // Читаємо регістр 0x83: charging voltage
    retry = 0;
    while (retry < I2C_RETRY_COUNT) : (retry += 1) {
        const voltage_reg = i2cRead(fd, AXP803_REG_CHARGING_VOLTAGE) catch |err| {
            std.debug.print("[charging] voltage read failed (retry {d}): {}\n", .{ retry, err });
            continue;
        };

        voltage_mv = registerToVoltageMv(voltage_reg);
        break;
    } else {
        std.debug.print("[charging] all voltage read attempts failed\n", .{});
        voltage_mv = 4200;
    }

    std.debug.print("[charging] AXP803: charging={}, {d}mA, {d}mV\n", .{ charging, current_ma, voltage_mv });

    return ChargingInfo{
        .charging = charging,
        .current_ma = current_ma,
        .voltage_mv = voltage_mv,
        .limit_80pct = true,
    };
}
// readCharging:end

// ────────────────────────────────────────────────────────────────────────────
// Управління зарядкою (запис в регістри)
// ────────────────────────────────────────────────────────────────────────────

/// Установити лимит тока зарядки (медленна зарядка для ночного режиму)
/// @param current_ma: 300–2000 mA (step 100mA)
// setChargingLimit:start
//   purpose: validate that current_ma is in the 300..2000 mA range, open /dev/iic0, convert the value to the AXP803 register encoding, and write it to CHARGING_CURRENT with up to 3 retries.
//   input:  current_ma — desired charging current (mA), step 100 mA.
//   output: true on a successful write; false on out-of-range, missing /dev/iic0, or all retries failing.
//   sideEffects: opens /dev/iic0; up to 3 I2C writes per call.
pub fn setChargingLimit(current_ma: u16) bool {
    if (builtin.target.os.tag != .freebsd) {
        // Stub на Linux QEMU
        return true;
    }

    // Валідація діапазону
    if (current_ma < 300 or current_ma > 2000) {
        std.debug.print("[charging] invalid current {d}mA (300–2000 range)\n", .{current_ma});
        return false;
    }

    // Спробуємо відкрити /dev/iic0
    const fd = c.open(I2C_DEV, c.O_RDWR);
    if (fd < 0) {
        std.debug.print("[charging] I2C not available for write\n", .{});
        return false;
    }
    defer _ = c.close(fd);

    // Конвертуємо mA в регістр (300–2000mA, шаг 100mA)
    const reg_val = @as(u8, @intCast((current_ma - 300) / 100));

    var retry: usize = 0;
    while (retry < I2C_RETRY_COUNT) : (retry += 1) {
        i2cWrite(fd, AXP803_REG_CHARGING_CURRENT, reg_val) catch |err| {
            std.debug.print("[charging] write failed (retry {d}): {}\n", .{ retry, err });
            continue;
        };

        std.debug.print("[charging] set current to {d}mA (reg={x})\n", .{ current_ma, reg_val });
        return true;
    }

    std.debug.print("[charging] all write attempts failed\n", .{});
    return false;
}
// setChargingLimit:end

// ────────────────────────────────────────────────────────────────────────────
// Форматування для JSON (буфер передається явно, без аллокацій)
// ────────────────────────────────────────────────────────────────────────────

// formatChargingInfo:start
//   purpose: emit `{"ok":true,"value":{"charging":<bool>,"current_ma":<n>,"voltage_mv":<n>}}` from a ChargingInfo.
//   input:  info — ChargingInfo from readCharging; buf — destination scratch buffer.
//   output: a slice of buf with the formatted JSON; on buf-overflow returns an empty slice.
//   sideEffects: none.
pub fn formatChargingInfo(info: ChargingInfo, buf: []u8) []u8 {
    const result = std.fmt.bufPrint(buf,
        "{{\"ok\":true,\"value\":{{\"charging\":{s},\"current_ma\":{d},\"voltage_mv\":{d}}}}}",
        .{
            if (info.charging) "true" else "false",
            info.current_ma,
            info.voltage_mv,
        },
    ) catch buf[0..0];
    return result;
}
// formatChargingInfo:end

/// Форматувати успіх команди set_charging_limit
// formatSetSuccess:start
//   purpose: emit `{"ok":true,"message":"charging limit updated"}` for a successful set_charging_limit.
//   input:  buf — destination scratch buffer.
//   output: a slice of buf with the formatted JSON.
//   sideEffects: none.
pub fn formatSetSuccess(buf: []u8) []u8 {
    return std.fmt.bufPrint(buf,
        "{{\"ok\":true,\"message\":\"charging limit updated\"}}",
        .{},
    ) catch buf[0..0];
}
// formatSetSuccess:end

/// Форматувати помилку команди
// formatError:start
//   purpose: emit `{"ok":false,"error":"<msg>"}` for a set_charging_limit failure.
//   input:  buf — destination scratch buffer; msg — human-readable error reason.
//   output: a slice of buf with the formatted JSON.
//   sideEffects: none.
pub fn formatError(buf: []u8, msg: []const u8) []u8 {
    return std.fmt.bufPrint(buf,
        "{{\"ok\":false,\"error\":\"{s}\"}}",
        .{msg},
    ) catch buf[0..0];
}
// formatError:end
