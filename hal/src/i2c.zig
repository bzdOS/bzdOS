// START_AI_HEADER
// MODULE: sys-daemon-zig/src/i2c.zig
// PURPOSE: Общие I2C операции для всех сенсоров (open/read/write/burst)
// INTENT: Устранить дублирование i2cRead/i2cWrite/i2cReadBurst в accelerometer/proximity/magnetometer/charging;
//         централизовать выбор шины — путь /dev/iicN берётся из platform.i2c_sensor_bus,
//         а не хардкодится на каждом call-site (BPI-M64 TWI0=/dev/iic0, PPP I2C1=/dev/iic1).
// DEPENDENCIES: libc (open, close, write, read), platform (comptime bus path + has_i2c).
// PUBLIC_API: I2CError, openSensorBus, openBus, closeBus, i2cRead, i2cWrite, i2cReadBurst
// END_AI_HEADER

const std = @import("std");
const builtin = @import("builtin");
const platform = @import("platform.zig");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

pub const I2CError = error{
    I2COpen,
    I2CWrite,
    I2CRead,
    I2CNoBus,
};

// openBus:start
//   purpose: Открыть конкретную I2C-шину /dev/iicN для read/write (O_RDWR).
//   input:   path — абсолютный путь к iic(4) устройству (например platform.i2c_sensor_bus).
//   output:  файловый дескриптор (i32) или I2CError.I2COpen при ошибке open(2);
//            I2CError.I2CNoBus если путь пустой (QEMU has_i2c==false).
//   sideEffects: open(2) syscall на /dev/iicN; caller обязан вызвать closeBus(fd).
pub fn openBus(path: []const u8) I2CError!i32 {
    // Путь пустой → нет шины на этой платформе (QEMU). Не открываем "".
    if (path.len == 0) return I2CError.I2CNoBus;

    // c.open ждёт NUL-terminated строку; копируем в стек-буфер (без heap).
    // Пути берутся из comptime-литералов platform.zig / bpi_m64.zig (≤16 байт).
    var path_buf: [64]u8 = undefined;
    if (path.len >= path_buf.len) return I2CError.I2COpen;
    @memcpy(path_buf[0..path.len], path);
    path_buf[path.len] = 0;

    const fd = c.open(&path_buf, c.O_RDWR);
    if (fd < 0) return I2CError.I2COpen;
    return fd;
}
// openBus:end

// openSensorBus:start
//   purpose: Открыть первичную сенсорную I2C-шину для текущей платформы
//            (comptime platform.i2c_sensor_bus): BPI-M64 → /dev/iic0, PPP → /dev/iic1.
//   input:   none — путь резолвится comptime из platform.zig.
//   output:  файловый дескриптор (i32) или I2CError (I2CNoBus на QEMU, I2COpen при сбое).
//   sideEffects: open(2) на platform.i2c_sensor_bus; caller обязан closeBus(fd).
pub fn openSensorBus() I2CError!i32 {
    // has_i2c == false (QEMU) → шины нет; ветка open вырезается comptime.
    if (comptime !platform.has_i2c) return I2CError.I2CNoBus;
    return openBus(platform.i2c_sensor_bus);
}
// openSensorBus:end

// closeBus:start
//   purpose: Закрыть открытую I2C-шину (close(2)).
//   input:   fd — дескриптор из openBus/openSensorBus.
//   output:  void.
//   sideEffects: close(2) syscall.
pub fn closeBus(fd: i32) void {
    _ = c.close(fd);
}
// closeBus:end

// i2cWrite:start
//   purpose: Записать один байт в регистр I2C устройства
//   input: fd - файловый дескриптор /dev/iicN, reg - адрес регистра, value - байт для записи
//   output: void или I2CError.I2CWrite при ошибке
//   sideEffects: write(2) syscall
pub fn i2cWrite(fd: i32, reg: u8, value: u8) I2CError!void {
    var buf: [2]u8 = undefined;
    buf[0] = reg;
    buf[1] = value;

    const written = c.write(fd, &buf, buf.len);
    if (written < 0 or written < 2) {
        return I2CError.I2CWrite;
    }
}
// i2cWrite:end

// i2cRead:start
//   purpose: Прочитать один байт из регистра I2C устройства
//   input: fd - файловый дескриптор /dev/iicN, reg - адрес регистра
//   output: байт или I2CError при ошибке
//   sideEffects: write(2) + read(2) syscalls
pub fn i2cRead(fd: i32, reg: u8) I2CError!u8 {
    if (c.write(fd, &[_]u8{reg}, 1) < 1) {
        return I2CError.I2CWrite;
    }

    var result: [1]u8 = undefined;
    if (c.read(fd, &result, 1) < 1) {
        return I2CError.I2CRead;
    }

    return result[0];
}
// i2cRead:end

// i2cReadBurst:start
//   purpose: Прочитать несколько байт из регистра I2C устройства (burst read)
//   input: fd - файловый дескриптор /dev/iicN, reg - начальный адрес регистра, buf - буфер для данных
//   output: void или I2CError при ошибке
//   sideEffects: write(2) + read(2) syscalls
pub fn i2cReadBurst(fd: i32, reg: u8, buf: []u8) I2CError!void {
    if (c.write(fd, &[_]u8{reg}, 1) < 1) {
        return I2CError.I2CWrite;
    }

    const nread = c.read(fd, buf.ptr, buf.len);
    if (nread < 0 or nread < @as(isize, @intCast(buf.len))) {
        return I2CError.I2CRead;
    }
}
// i2cReadBurst:end
