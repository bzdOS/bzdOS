// START_AI_HEADER
// MODULE: sys-daemon-zig/src/telemetry.zig
// PURPOSE: HAL-side HardwareStatus producer — reads uptime/battery/cpu and pushes the 32-byte Cap'n Proto message to a Unix-socket consumer (bsdos-core).
// INTENT: Mirror the Rust bsdos-core/src/capnp.rs wire format (32 bytes, hand-rolled) on the Zig side; keep the encode hot path allocation-free by writing directly into a stack-typed [32]u8 buffer.
// DEPENDENCIES: std (mem, time, debug, net, process), builtin (target os), libc via @cImport (sysctl, timeval, unistd).
// PUBLIC_API: HardwareStatus struct, MSG_SIZE const, serialize(status, buf), readHardwareStatus(), pushToSocket(allocator, sock_path).
// END_AI_HEADER

// Телеметрия HAL: сериализация HardwareStatus в Cap'n Proto binary формат.
// Минимальный hand-rolled encoder для fixed-layout flat struct.
// Без скрытых аллокаций — caller передаёт буфер явно.

const std = @import("std");
const builtin = @import("builtin");

// C imports для чтения реальных данных ядра FreeBSD
const c = if (builtin.target.os.tag == .freebsd) @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/stat.h");
    @cInclude("sys/sysctl.h");
    @cInclude("sys/time.h");
    @cInclude("unistd.h");
}) else @cImport({
    @cInclude("sys/stat.h");
    @cInclude("unistd.h");
});

pub const HardwareStatus = struct {
    uptime: u64,        // секунды аптайма
    battery_level: u32, // 0-100 %
    cpu_usage: u32,     // 0-100 % (упрощённая метрика)
};

// Cap'n Proto message layout (32 байта, всегда):
//   [0..4]   framing: segment_count - 1 = 0
//   [4..8]   segment 0 size = 3 words (ptr + 2 data words)
//   [8..16]  root struct ptr: type=0, offset=0, dataWords=2, ptrWords=0
//   [16..24] uptime (u64 LE)
//   [24..28] batteryLevel (u32 LE)
//   [28..32] cpuUsage (u32 LE)
pub const MSG_SIZE: usize = 32;

// serialize:start
//   purpose: write a HardwareStatus into the fixed 32-byte Cap'n Proto wire form described in the module header (segment_count=0, seg0_size=3, struct pointer with dataWords=2/ptrWords=0, then uptime/battery/cpu little-endian).
//   input:  status — triple to encode; buf — pointer to exactly MSG_SIZE bytes (32).
//   output: void; buf is fully overwritten.
//   sideEffects: none (pure).
pub fn serialize(status: HardwareStatus, buf: *[MSG_SIZE]u8) void {
    // Framing: 1 сегмент → (count - 1) = 0
    std.mem.writeInt(u32, buf[0..4], 0, .little);
    // Segment 0: 3 слова = 8 bytes ptr + 16 bytes data = 24 bytes
    std.mem.writeInt(u32, buf[4..8], 3, .little);
    // Struct pointer: bits[0..31]=0 (struct type + offset=0), bits[32..47]=2 (dataWords), bits[48..63]=0
    std.mem.writeInt(u32, buf[8..12], 0, .little);      // lower 32 bits
    std.mem.writeInt(u16, buf[12..14], 2, .little);     // dataWords
    std.mem.writeInt(u16, buf[14..16], 0, .little);     // ptrWords
    // Struct data
    std.mem.writeInt(u64, buf[16..24], status.uptime, .little);
    std.mem.writeInt(u32, buf[24..28], status.battery_level, .little);
    std.mem.writeInt(u32, buf[28..32], status.cpu_usage, .little);
}
// serialize:end

/// Читает реальные данные из FreeBSD kernel
// readHardwareStatus:start
//   purpose: snapshot the current uptime + battery + cpu triple (cpu currently hard-coded to 0 — see kern.cp_time delta TODO in body).
//   input:  none.
//   output: a freshly read HardwareStatus (cpu_usage is always 0 today).
//   sideEffects: one sysctlbyname(2) for kern.boottime via readUptime().
pub fn readHardwareStatus() HardwareStatus {
    return HardwareStatus{
        .uptime = readUptime(),
        .battery_level = readBattery(),
        .cpu_usage = 0, // TODO: kern.cp_time sysctl
    };
}
// readHardwareStatus:end

// readUptime:start
//   purpose: read kernel boottime via sysctlbyname("kern.boottime") and return (now - boottime) clamped at 0.
//   input:  none.
//   output: uptime seconds (u64); 0 on non-FreeBSD or on sysctl failure (never errors).
//   sideEffects: one sysctlbyname(2) read.
fn readUptime() u64 {
    if (builtin.target.os.tag == .freebsd) {
        var tv: c.struct_timeval = undefined;
        var tv_len: usize = @sizeOf(c.struct_timeval);
        if (c.sysctlbyname("kern.boottime", &tv, &tv_len, null, 0) == 0) {
            const now = std.time.timestamp();
            const uptime = now - tv.tv_sec;
            return if (uptime >= 0) @intCast(uptime) else 0;
        }
    }
    return 0;
}
// readUptime:end

// readBattery:start
//   purpose: return the current battery percentage — today a hard-coded 100% until the I2C AXP803 driver is wired in.
//   input:  none.
//   output: 100 (u32).
//   sideEffects: none (stub).
fn readBattery() u32 {
    // TODO: iic/AXP803 на реальном железе
    // QEMU: нет батареи → 100%
    return 100;
}
// readBattery:end

/// Отправить одно Cap'n Proto сообщение в Unix-сокет (non-blocking попытка)
// pushToSocket:start
//   purpose: read one HardwareStatus, serialize into MSG_SIZE bytes, and write the whole buffer to the AF_UNIX consumer socket at sock_path; missing consumer is NOT an error (it just means nothing is listening right now).
//   input:  allocator — accepted for API symmetry with future hot-path code; today unused; sock_path — absolute path to the consumer AF_UNIX SOCK_STREAM socket.
//   output: void on success or no-consumer; propagates writeAll() errors only.
//   sideEffects: opens (and immediately closes) a connection to sock_path on every call; one 32-byte write to that socket.
pub fn pushToSocket(allocator: std.mem.Allocator, sock_path: []const u8) !void {
    _ = allocator; // используется только если нужна динамическая память

    var buf: [MSG_SIZE]u8 = undefined;
    const status = readHardwareStatus();
    serialize(status, &buf);

    const stream = std.net.connectUnixSocket(sock_path) catch |err| {
        // Subscriber не подключён — не ошибка, просто пропускаем
        std.debug.print("[telemetry] no consumer on {s}: {}\n", .{ sock_path, err });
        return;
    };
    defer stream.close();

    try stream.writeAll(&buf);
}
// pushToSocket:end
