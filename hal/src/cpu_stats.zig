// START_AI_HEADER
// MODULE: sys-daemon-zig/src/cpu_stats.zig
// PURPOSE: FreeBSD `kern.cp_time` CPU utilization sampler — two reads 100 ms apart, weighted deltas into per-bucket and total percent.
// INTENT: Avoid the capnp crate on the HAL side; we shell out to `/sbin/sysctl -n kern.cp_time` twice and parse the five integer fields. A single static 4 KiB scratch buffer is reused across both reads so no per-call heap.
// DEPENDENCIES: std (process, heap, fmt), libc via @cImport (sysctl, sys/types, unistd for usleep).
// PUBLIC_API: CpuStats struct, getCpuStats() CpuStats, formatCpuStats(s, buf) ![]u8.
// END_AI_HEADER

// CPU utilization через FreeBSD sysctl kern.cp_time
// kern.cp_time = 5 значень: [user, nice, sys, intr, idle] (тіки)
// CPU% = 100 - (delta_idle / delta_total * 100)
// Два зчитування з паузою 100ms для дельти

const std = @import("std");
const builtin = @import("builtin");

const c = if (builtin.target.os.tag == .freebsd) @cImport({
    @cInclude("sys/types.h");
    @cInclude("sys/sysctl.h");
    @cInclude("unistd.h");
}) else @cImport({
    @cInclude("unistd.h");
});

pub const CpuStats = struct {
    user_pct: u32 = 0,
    sys_pct: u32 = 0,
    idle_pct: u32 = 100,
    total_pct: u32 = 0,  // = 100 - idle_pct
};

const CP_TIME_FIELDS = 5;
const CP_USER  = 0;
const CP_NICE  = 1;
const CP_SYS   = 2;
const CP_INTR  = 3;
const CP_IDLE  = 4;

// Статический FixedBufferAllocator для readCpTime
var _cptime_alloc_buf: [4096]u8 = undefined;

// Прочитати kern.cp_time через sysctl и вернуть результат в buf
// readCpTime:start
//   purpose: run `/sbin/sysctl -n kern.cp_time` as a child process and copy the trimmed stdout into buf.
//   input:  buf — destination buffer (caller-owned, must be at least ~80 bytes for the 5 fields).
//   output: a slice of buf with the trimmed response; error.NotFreeBSD on Linux, plus any child-process error.
//   sideEffects: spawns a /sbin/sysctl child; reads up to 256 B from its stdout.
fn readCpTime(buf: []u8) ![]const u8 {
    if (builtin.target.os.tag != .freebsd) {
        return error.NotFreeBSD;
    }

    var fba = std.heap.FixedBufferAllocator.init(&_cptime_alloc_buf);
    const allocator = fba.allocator();

    var child = std.process.Child.init(&.{ "sysctl", "-n", "kern.cp_time" }, allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;

    try child.spawn();

    var stdout_buf: [256]u8 = undefined;
    const bytes_read = try child.stdout.?.readAll(&stdout_buf);
    _ = try child.wait();

    const result = std.mem.trim(u8, stdout_buf[0..bytes_read], " \t\r\n");
    @memcpy(buf[0..result.len], result);
    return buf[0..result.len];
}
// readCpTime:end

// Распарсить "user nice sys intr idle" в масив
// parseCpTime:start
//   purpose: tokenise a "user nice sys intr idle" string on whitespace and write up to 5 parsed u64 values into out (missing fields stay 0).
//   input:  s — text from readCpTime; out — pointer to a 5-element u64 array.
//   output: void; non-numeric tokens are written as 0.
//   sideEffects: none (pure).
fn parseCpTime(s: []const u8, out: *[CP_TIME_FIELDS]u64) void {
    var it = std.mem.splitAny(u8, s, " \t");
    var i: usize = 0;
    while (it.next()) |tok| {
        if (i >= CP_TIME_FIELDS) break;
        out[i] = std.fmt.parseInt(u64, tok, 10) catch 0;
        i += 1;
    }
}
// parseCpTime:end

// Получить CPU статистику (два зчитування с дельтой)
// getCpuStats:start
//   purpose: sample kern.cp_time twice with a 100 ms usleep between, compute deltas, and convert them to per-bucket and total percentages.
//   input:  none.
//   output: a CpuStats struct; the zero-initialised default on any sysctl/parse error or on zero-total delta (counter wrap is silently treated as 0%).
//   sideEffects: two `/sbin/sysctl` invocations; one usleep(100_000); zero heap allocations.
pub fn getCpuStats() CpuStats {
    var buf1: [256]u8 = undefined;
    var buf2: [256]u8 = undefined;
    var t1: [CP_TIME_FIELDS]u64 = [_]u64{0} ** CP_TIME_FIELDS;
    var t2: [CP_TIME_FIELDS]u64 = [_]u64{0} ** CP_TIME_FIELDS;

    // Першое зчитування
    const s1 = readCpTime(&buf1) catch return .{};
    parseCpTime(s1, &t1);

    // 100ms пауза
    _ = c.usleep(100_000);

    // Второе зчитување
    const s2 = readCpTime(&buf2) catch return .{};
    parseCpTime(s2, &t2);

    // Рассчитаємо дельты (safe: проверяем overflow)
    const d_user = if (t2[CP_USER] >= t1[CP_USER]) t2[CP_USER] - t1[CP_USER] else 0;
    const d_nice = if (t2[CP_NICE] >= t1[CP_NICE]) t2[CP_NICE] - t1[CP_NICE] else 0;
    const d_sys  = if (t2[CP_SYS] >= t1[CP_SYS]) t2[CP_SYS] - t1[CP_SYS] else 0;
    const d_intr = if (t2[CP_INTR] >= t1[CP_INTR]) t2[CP_INTR] - t1[CP_INTR] else 0;
    const d_idle = if (t2[CP_IDLE] >= t1[CP_IDLE]) t2[CP_IDLE] - t1[CP_IDLE] else 0;

    const d_total = d_user + d_nice + d_sys + d_intr + d_idle;

    if (d_total == 0) return .{};

    // Зчислення відсотків
    const user_pct = @as(u32, @intCast(d_user * 100 / d_total));
    const sys_pct  = @as(u32, @intCast(d_sys  * 100 / d_total));
    const idle_pct = @as(u32, @intCast(d_idle * 100 / d_total));
    const total_pct = @as(u32, @intCast((d_total - d_idle) * 100 / d_total));

    return .{
        .user_pct = user_pct,
        .sys_pct = sys_pct,
        .idle_pct = idle_pct,
        .total_pct = total_pct,
    };
}
// getCpuStats:end

// Форматировати CPU stats у JSON
// formatCpuStats:start
//   purpose: emit `{"ok":true,"value":{"pct":<total>,"user":<u>,"sys":<s>,"idle":<i>}}` from a CpuStats into buf.
//   input:  s — CpuStats to format; buf — destination scratch buffer.
//   output: a slice of buf with the formatted JSON.
//   sideEffects: none.
pub fn formatCpuStats(s: CpuStats, buf: []u8) ![]u8 {
    return try std.fmt.bufPrint(buf,
        "{{\"ok\":true,\"value\":{{\"pct\":{d},\"user\":{d},\"sys\":{d},\"idle\":{d}}}}}",
        .{ s.total_pct, s.user_pct, s.sys_pct, s.idle_pct });
}
// formatCpuStats:end
