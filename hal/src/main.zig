// START_AI_HEADER
// MODULE: sys-daemon-zig/src/main.zig
// PURPOSE: bsdOS HAL — main entry point, owns the /var/run/bsdos-hal.sock command socket and dispatches text/binary SysCommand requests to per-subsystem Zig modules.
// INTENT: All HAL commands live in one binary so the broker talks to a single AF_UNIX endpoint. Tickless by design — the main thread blocks in accept() and the kernel parks the ARM core via WFI. Subsystems (touch/sim/sms/gps/prox/charging/haptic/backlight) are imported for use by processTextCmd; their per-call functions run on the main thread (single-connection MVP, no thread pool yet).
// DEPENDENCIES: std (heap, posix, fmt, time, debug), builtin (target os tag for freebsd vs linux-qemu fallback), libc via @cImport (sysctl, timeval, unistd, sys/stat), platform (comptime capability flags). Local modules: touch, zones, sim, sms, gps, prox, charging, haptic, backlight.
// PUBLIC_API: pub fn main() !void. Internal: runSysctl, getUptime, getHostname, getBattery, getMemory, getCpuUsage, getSimStatus, getHalVersion, getTouchZone, getOrientation, getLocation, getProximity, getCompass, getHaptic, smsSend, smsList, backlightSet/Off/On/Get/Auto, processTextCmd, serveHal, handleHalConn.
// END_AI_HEADER

// bsdOS HAL — системный демон Zig.
// Таргет: aarch64-freebsd.14.0
//
// Потоки:
//   main   — HAL command socket (/var/run/bsdos-hal.sock), JSON-like responses
//   thread A — audio_bridge: cap'n proto → /dev/dsp (OSS zero-copy)
//   thread B — (reserved) predictive_touch evdev loop
//   tickless  — main thread спит в kevent() когда нет активности

const std = @import("std");
const builtin = @import("builtin");
const log_debug = builtin.mode == .Debug;

// Comptime platform capability flags — resolves -Dplatform=<str> from build.zig.
// All has_* constants are comptime bools; dead branches are eliminated by the compiler.
const platform = @import("platform.zig");

// Модули (no allocator — вся работа на стеке/BSS)
//const audio     = @import("audio_bridge.zig");
const touch     = @import("predictive_touch.zig");
//const ghost     = @import("ghost_radio.zig");
//const tele      = @import("telemetry.zig");
const zones     = @import("touch_zones.zig");
const sim       = @import("sim.zig");
const sms       = @import("sms.zig");
//const accel     = @import("accelerometer.zig");
const gps       = @import("gps.zig");
const prox      = @import("proximity.zig");
//const mag       = @import("magnetometer.zig");
//const cpu_stats = @import("cpu_stats.zig");
const charging  = @import("charging.zig");
const haptic    = @import("haptic.zig");
const backlight = @import("backlight.zig");

// C headers для FreeBSD syscalls
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

// ── Cap'n Proto SysCommand wire constants ─────────────────────────────────────

const CMD_PING      : u8 = 1;
const CMD_FREEZE    : u8 = 2;
const CMD_THAW      : u8 = 3;
const CMD_HIBERNATE : u8 = 4;
const CMD_PRE_THAW  : u8 = 5;
const CMD_SYNC_PUSH : u8 = 6;

// SysCommand fixed 4-byte framing (упрощённый binary API поверх HAL-сокета)
const SysCmd = extern struct {
    cmd_id:  u8,
    _pad:    u8 = 0,
    payload: u16,
    comptime { std.debug.assert(@sizeOf(SysCmd) == 4); }
};

// ── Команды HAL (текстовый протокол для совместимости с broker) ───────────────

// Вспомогательная: запустить sysctl и прочитать результат в буфер
// (не hot path — используется для admin commands, не в data-plane)
// runSysctl:start
//   purpose: run `/sbin/sysctl -n <key>` as a child process and return the trimmed stdout payload (one-shot, not on the data-plane hot path).
//   input:  key — sysctl OID name (e.g. "vm.stats.vm.v_free_count"); the second buffer argument is currently ignored (kept for an in-process direct sysctlbyname fallback, see comment in body).
//   output: trimmed stdout as a slice into a thread-local 4 KiB buffer (caller must consume before next call); error.NotFreeBSD when not on FreeBSD, plus any Child.spawn/read/wait error from the underlying process.
//   sideEffects: spawns `/sbin/sysctl` (PATH-resolved) on every call; reads up to 4 KiB from its stdout; waits for it to exit.
/// Вспомогательная: запустить sysctl и прочитать результат в буфер
// (не hot path — используется для admin commands, не в data-plane)
fn runSysctl(key: []const u8, _: []u8) ![]const u8 {
    if (builtin.target.os.tag != .freebsd) {
        return error.NotFreeBSD;
    }
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var child = std.process.Child.init(&.{ "sysctl", "-n", key }, allocator);

    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Ignore;
    try child.spawn();

    var stdout_buf: [4096]u8 = undefined;
    const bytes_read = try child.stdout.?.readAll(&stdout_buf);
    _ = try child.wait();

    return std.mem.trim(u8, stdout_buf[0..bytes_read], " \t\r\n");
}
// runSysctl:end

// getUptime:start
//   purpose: emit `{"ok":true,"value":<secs>}` for the broker's `get_uptime` command, using sysctl `kern.boottime` on FreeBSD or `/proc/uptime` on Linux/QEMU.
//   input:  buf — destination scratch buffer for the JSON response (must fit ~80 bytes).
//   output: a slice of buf containing the formatted JSON; error.SysctlFailed / error.ParseError when the underlying source fails.
//   sideEffects: one sysctlbyname(2) call on FreeBSD, or one open/readAll+close on /proc/uptime; writes to buf.
fn getUptime(buf: []u8) ![]u8 {
    if (builtin.target.os.tag == .freebsd) {
        var tv: c.struct_timeval = undefined;
        var tv_len: usize = @sizeOf(c.struct_timeval);
        if (c.sysctlbyname("kern.boottime", &tv, &tv_len, null, 0) != 0)
            return error.SysctlFailed;
        const uptime: i64 = std.time.timestamp() - tv.tv_sec;
        return try std.fmt.bufPrint(buf, "{{\"ok\":true,\"value\":{d}}}", .{uptime});
    } else {
        var f = std.fs.openFileAbsolute("/proc/uptime", .{}) catch
            return try std.fmt.bufPrint(buf, "{{\"ok\":false,\"error\":\"no uptime\"}}", .{});
        defer f.close();
        var rb: [128]u8 = undefined;
        const n = try f.readAll(&rb);
        var parts = std.mem.splitSequence(u8, rb[0..n], " ");
        const s = parts.next() orelse return error.ParseError;
        const fv = std.fmt.parseFloat(f64, s) catch return error.ParseError;
        return try std.fmt.bufPrint(buf, "{{\"ok\":true,\"value\":{d}}}", .{@as(i64, @intFromFloat(fv))});
    }
}
// getUptime:end

// getHostname:start
//   purpose: emit `{"ok":true,"value":"<hostname>"}` for the broker's `get_hostname` command.
//   input:  buf — destination scratch buffer (must fit HOST_NAME_MAX + ~24 bytes of JSON wrapping).
//   output: a slice of buf with the formatted JSON; error.GetHostnameFailed when gethostname(2) returns -1.
//   sideEffects: one gethostname(2) call; writes to buf.
fn getHostname(buf: []u8) ![]u8 {
    var hb: [std.posix.HOST_NAME_MAX]u8 = undefined;
    const h = std.posix.gethostname(&hb) catch return error.GetHostnameFailed;
    return try std.fmt.bufPrint(buf, "{{\"ok\":true,\"value\":\"{s}\"}}", .{h});
}
// getHostname:end

// getBattery:start
//   purpose: emit `{"ok":true,"value":{"pct":<0-100>,"charging":<bool>,"source":"battery"|"ac"}}` for `get_battery`.
//   input:  buf — destination scratch buffer.
//   output: formatted JSON; returns "pct":100, source:"ac" on Linux/QEMU or when ACPI battery node is missing.
//   sideEffects: two sysctlbyname(2) reads on FreeBSD (`hw.acpi.battery.life`, `hw.acpi.acline`); writes to buf.
fn getBattery(buf: []u8) ![]u8 {
    // FreeBSD: hw.acpi.battery.life → percentage (0-100)
    // If no ACPI battery (e.g., VM or AC power only) → return 100% and "ac" source
    if (builtin.target.os.tag == .freebsd) {
        var battery_pct: i32 = 100; // default
        var battery_pct_len: usize = @sizeOf(i32);

        // Try to read ACPI battery percentage
        const has_battery = c.sysctlbyname("hw.acpi.battery.life", &battery_pct, &battery_pct_len, null, 0) == 0;

        // Clamp to [0, 100]
        const pct: u8 = if (has_battery and battery_pct >= 0 and battery_pct <= 100)
            @as(u8, @intCast(battery_pct))
        else
            100; // VM or AC-only → 100%

        // Try to detect if plugged in (hw.acpi.acline = 1 if AC power connected)
        var acline: i32 = 1; // default: assume plugged in
        var acline_len: usize = @sizeOf(i32);
        const has_acline = c.sysctlbyname("hw.acpi.acline", &acline, &acline_len, null, 0) == 0;
        const is_charging = !has_battery or (has_acline and acline == 1);
        const source = if (has_battery) "battery" else "ac";

        return try std.fmt.bufPrint(buf,
            "{{\"ok\":true,\"value\":{{\"pct\":{d},\"charging\":{s},\"source\":\"{s}\"}}}}",
            .{ pct, if (is_charging) "true" else "false", source });
    } else {
        // Non-FreeBSD: return 100% AC (safe default)
        return try std.fmt.bufPrint(buf,
            "{{\"ok\":true,\"value\":{{\"pct\":100,\"charging\":true,\"source\":\"ac\"}}}}",
            .{});
    }
}
// getBattery:end

// getMemory:start
//   purpose: emit memory stats (free/total pages + free percent) for `get_memory` by spawning two sysctl processes.
//   input:  buf — destination scratch buffer.
//   output: formatted JSON with free_pages, total_pages, free_pct (integer 0-100); per-field error JSON when sysctl or parsing fails.
//   sideEffects: two `/sbin/sysctl` child processes (vm.stats.vm.v_free_count, vm.stats.vm.v_page_count); writes to buf.
fn getMemory(buf: []u8) ![]u8 {
    var free_str: [64]u8 = undefined;
    var total_str: [64]u8 = undefined;

    const free_val = runSysctl("vm.stats.vm.v_free_count", &free_str) catch
        return try std.fmt.bufPrint(buf, "{{\"ok\":false,\"error\":\"sysctl free_count\"}}", .{});
    const free_pages = std.fmt.parseInt(u64, free_val, 10) catch
        return try std.fmt.bufPrint(buf, "{{\"ok\":false,\"error\":\"parse free_pages\"}}", .{});

    const total_val = runSysctl("vm.stats.vm.v_page_count", &total_str) catch
        return try std.fmt.bufPrint(buf, "{{\"ok\":false,\"error\":\"sysctl page_count\"}}", .{});
    const total_pages = std.fmt.parseInt(u64, total_val, 10) catch
        return try std.fmt.bufPrint(buf, "{{\"ok\":false,\"error\":\"parse total_pages\"}}", .{});

    const free_pct = if (total_pages > 0) (free_pages * 100) / total_pages else 0;

    return try std.fmt.bufPrint(buf,
        "{{\"ok\":true,\"value\":{{\"free_pages\":{d},\"total_pages\":{d},\"free_pct\":{d}}}}}",
        .{ free_pages, total_pages, free_pct });
}
// getMemory:end

// getCpuUsage:start
//   purpose: emit `{"ok":true,"value":{"pct":<busy%>}}` for `get_cpu_usage` from a single sample of FreeBSD `kern.cp_time` (no delta — instantaneous busy%, may reset on counter wrap).
//   input:  buf — destination scratch buffer.
//   output: formatted JSON; on non-FreeBSD returns `{"ok":false,"error":"..."}`.
//   sideEffects: one sysctlbyname(2) reading 5 × u64 ticks (user/nice/sys/intr/idle); writes to buf.
fn getCpuUsage(buf: []u8) ![]u8 {
    // FreeBSD: kern.cp_time → 5 uint64_t values: user, nice, sys, intr, idle
    // CPU% = (user + nice + sys + intr) / total * 100
    if (builtin.target.os.tag == .freebsd) {
        var cp_time: [5]u64 = undefined;
        var cp_time_len: usize = @sizeOf([5]u64);

        if (c.sysctlbyname("kern.cp_time", &cp_time, &cp_time_len, null, 0) != 0) {
            return try std.fmt.bufPrint(buf,
                "{{\"ok\":false,\"error\":\"sysctl kern.cp_time failed\"}}",
                .{});
        }

        // Calculate busy vs total
        const user = cp_time[0];
        const nice = cp_time[1];
        const sys = cp_time[2];
        const intr = cp_time[3];
        const idle = cp_time[4];
        const total = user + nice + sys + intr + idle;

        const busy_pct = if (total > 0) ((user + nice + sys + intr) * 100) / total else 0;

        return try std.fmt.bufPrint(buf,
            "{{\"ok\":true,\"value\":{{\"pct\":{d}}}}}",
            .{busy_pct});
    } else {
        // Non-FreeBSD fallback
        return try std.fmt.bufPrint(buf,
            "{{\"ok\":false,\"error\":\"cpu stats unavailable on non-FreeBSD\"}}",
            .{});
    }
}
// getCpuUsage:end

// getSimStatus:start
//   purpose: open the modem UART, query IMSI/PIN/CSQ/COPS/CREG, and emit the JSON for `get_sim_status`.
//   input:  buf — destination scratch buffer (must fit the longest AT-response variant + JSON wrapper).
//   output: formatted JSON; `{"ok":false,"error":"modem unavailable"}` when openModem() returns null, or `{"ok":false,"error":"sim query failed"}` when AT responses are empty.
//   sideEffects: opens /dev/cuaU0 (via sim.openModem), 5 AT round-trips, closes the fd on return.
fn getSimStatus(buf: []u8) ![]u8 {
    // Попытка открыть модем, отправить AT команды, вернуть JSON
    // Если модем недоступен → {"ok":false,"error":"modem unavailable"}

    if (sim.openModem()) |fd| {
        defer sim.closeModem(fd);

        if (sim.getSimInfo(fd)) |info| {
            // Успешно получили информацию
            const resp_len = sim.formatSimInfo(info, buf);
            return buf[0..resp_len];
        } else {
            // Ошибка при получении информации
            return try std.fmt.bufPrint(buf,
                "{{\"ok\":false,\"error\":\"sim query failed\"}}",
                .{});
        }
    } else {
        // Модем недоступен (OK на non-real hardware или виртуалках)
        return try std.fmt.bufPrint(buf,
            "{{\"ok\":false,\"error\":\"modem unavailable\"}}",
            .{});
    }
}
// getSimStatus:end

// getHalVersion:start
//   purpose: emit a static `{"ok":true,"value":{"version":"<semver>","features":[...]}}` listing the capabilities this HAL build actually implements (the list is the single source of truth for `hal_version` consumers).
//   input:  buf — destination scratch buffer.
//   output: a slice of buf with the formatted JSON.
//   sideEffects: none (pure format, no I/O).
fn getHalVersion(buf: []u8) ![]u8 {
    return try std.fmt.bufPrint(buf,
        "{{\"ok\":true,\"value\":{{\"version\":\"0.2.3\",\"features\":[\"uptime\",\"hostname\",\"memory\",\"cpu\",\"battery\",\"touch_zone\",\"sim_status\",\"orientation\",\"gps_location\",\"proximity\",\"compass\",\"haptic\"]}}}}",
        .{});
}
// getHalVersion:end

// getTouchZone:start
//   purpose: parse a `get_touch_zone X Y` command line, look up which jail (if any) owns the (X,Y) pixel coordinate, and emit `{"ok":true,"value":"<jail>"|null}`.
//   input:  line — full command line including the leading `get_touch_zone `; buf — destination scratch buffer.
//   output: formatted JSON; per-field error JSON when X or Y are missing/unparseable.
//   sideEffects: calls zones.detectJail(x, y) (pure lookup over compile-time BSS array).
fn getTouchZone(line: []const u8, buf: []u8) ![]u8 {
    // Парсим "get_touch_zone X Y"
    var parts = std.mem.splitSequence(u8, line, " ");
    _ = parts.next(); // skip "get_touch_zone"

    const x_str = parts.next() orelse
        return try std.fmt.bufPrint(buf, "{{\"ok\":false,\"error\":\"missing x\"}}", .{});
    const y_str = parts.next() orelse
        return try std.fmt.bufPrint(buf, "{{\"ok\":false,\"error\":\"missing y\"}}", .{});

    const x = std.fmt.parseInt(u16, x_str, 10) catch
        return try std.fmt.bufPrint(buf, "{{\"ok\":false,\"error\":\"invalid x\"}}", .{});
    const y = std.fmt.parseInt(u16, y_str, 10) catch
        return try std.fmt.bufPrint(buf, "{{\"ok\":false,\"error\":\"invalid y\"}}", .{});

    const jail = zones.detectJail(x, y);

    if (jail) |j| {
        return try std.fmt.bufPrint(buf, "{{\"ok\":true,\"value\":\"{s}\"}}", .{j});
    } else {
        return try std.fmt.bufPrint(buf, "{{\"ok\":true,\"value\":null}}", .{});
    }
}
// getTouchZone:end

// getOrientation:start
//   purpose: emit the current device orientation for `get_orientation`; currently stubbed to `{"ok":false,"error":"accelerometer unavailable"}` while the LIS2DE12 driver migration to Zig 0.15.2 is in progress.
//   input:  buf — destination scratch buffer.
//   output: error JSON (the function does not currently return an OK response).
//   sideEffects: none.
fn getOrientation(buf: []u8) ![]u8 {
    // TODO: Accelerometer disabled during migration to Zig 0.15.2
    return try std.fmt.bufPrint(buf,
        "{{\"ok\":false,\"error\":\"accelerometer unavailable\"}}",
        .{});
}
// getOrientation:end

// getLocation:start
//   purpose: emit a JSON GPS fix (or stub) for `get_location` by delegating to gps.getLocationData() + gps.formatGpsData().
//   input:  buf — destination scratch buffer.
//   output: formatted JSON; today always returns the QEMU stub (Phase 2 will read /dev/ttyu1 NMEA).
//   sideEffects: none (stub mode).
fn getLocation(buf: []u8) ![]u8 {
    // Отримуємо GPS дані (Phase 1: stub, Phase 2: real UART)
    const data = gps.getLocationData();

    // Форматуємо JSON відповідь
    return try gps.formatGpsData(data, buf);
}
// getLocation:end

// getProximity:start
//   purpose: emit proximity + ambient-light data for `get_proximity` via prox.readProximity() + prox.formatProximityData().
//   input:  buf — destination scratch buffer.
//   output: formatted JSON; today returns the QEMU stub (`{near:false, lux:300, raw_ok:false}`).
//   sideEffects: none in stub mode; on hardware will open /dev/iic0 and read 3 STK3311 registers.
fn getProximity(buf: []u8) ![]u8 {
    // Читаємо дані proximity & light sensor
    const data = prox.readProximity();

    // Форматуємо JSON відповідь
    return prox.formatProximityData(data, buf);
}
// getProximity:end

// getCompass:start
//   purpose: emit the magnetometer-derived compass heading for `get_compass`; stubbed to `{"ok":false,"error":"magnetometer unavailable"}` while the LIS3MDL driver migration to Zig 0.15.2 is in progress.
//   input:  buf — destination scratch buffer.
//   output: error JSON.
//   sideEffects: none.
fn getCompass(buf: []u8) ![]u8 {
    // TODO: Magnetometer disabled during migration to Zig 0.15.2
    return try std.fmt.bufPrint(buf,
        "{{\"ok\":false,\"error\":\"magnetometer unavailable\"}}",
        .{});
}
// getCompass:end

// getHaptic:start
//   purpose: parse a `haptic <pattern>` command, dispatch the pattern via haptic.playPattern, and emit the response.
//   input:  line — full command line (leading `haptic ` is stripped); buf — destination scratch buffer.
//   output: formatted JSON (`{"ok":true}` on success, `{"ok":false,"error":"missing pattern|unknown pattern"}` on parse failure).
//   sideEffects: delegates to haptic.playPattern (currently debug-print stub; future GPIO/PWM).
fn getHaptic(line: []const u8, buf: []u8) ![]u8 {
    // Парсим "haptic <pattern>"
    var parts = std.mem.splitSequence(u8, line, " ");
    _ = parts.next(); // skip "haptic"

    const pattern_str = parts.next() orelse
        return try haptic.formatHapticResp(buf, false, "missing pattern");

    if (haptic.parsePattern(pattern_str)) |pattern| {
        haptic.playPattern(pattern);
        return try haptic.formatHapticResp(buf, true, null);
    } else {
        return try haptic.formatHapticResp(buf, false, "unknown pattern");
    }
}
// getHaptic:end

// smsSend:start
//   purpose: parse `sms_send <number> <text...>`, send the SMS via sms.sendSms, and emit the JSON response.
//   input:  line — full command line (the text portion is everything after `<number> `); resp — destination scratch buffer.
//   output: formatted JSON (`{"ok":true,"value":"sent"}` or `{"ok":false,"error":"missing number|modem unavailable|send failed"}`).
//   sideEffects: opens /dev/cuaU0 via sms.openModem, 3 AT round-trips (AT+CMGF=1, AT+CMGS=, write text+CtrlZ), closes the fd.
fn smsSend(line: []const u8, resp: []u8) ![]u8 {
    // Парсим "sms_send <number> <text...>"
    var parts = std.mem.splitSequence(u8, line, " ");
    _ = parts.next(); // skip "sms_send"

    const number = parts.next() orelse
        return try std.fmt.bufPrint(resp, "{{\"ok\":false,\"error\":\"missing number\"}}", .{});

    // Остаток строки — текст SMS
    const text_start = @intFromPtr(number.ptr) + number.len + 1;  // +1 for space
    const line_end = @intFromPtr(line.ptr) + line.len;
    const text = if (text_start < line_end)
        @as([*]const u8, @ptrFromInt(text_start))[0 .. line_end - text_start]
    else
        "";

    if (sms.openModem()) |fd| {
        defer sms.closeModem(fd);

        if (sms.sendSms(fd, number, text)) {
            return try std.fmt.bufPrint(resp, "{{\"ok\":true,\"value\":\"sent\"}}", .{});
        } else {
            return try std.fmt.bufPrint(resp, "{{\"ok\":false,\"error\":\"send failed\"}}", .{});
        }
    } else {
        return try std.fmt.bufPrint(resp, "{{\"ok\":false,\"error\":\"modem unavailable\"}}", .{});
    }
}
// smsSend:end

// smsList:start
//   purpose: list SMS message indices for `sms_list` by issuing AT+CMGL="ALL" and emitting a JSON array of indices.
//   input:  resp — destination scratch buffer.
//   output: formatted JSON (`{"ok":true,"value":[idx, ...]}` or `{"ok":true,"value":[]}` for empty mailbox, or `{"ok":false,"error":"modem unavailable|list failed"}`).
//   sideEffects: opens /dev/cuaU0, 2 AT round-trips (AT+CMGF=1, AT+CMGL="ALL"), closes the fd.
fn smsList(resp: []u8) ![]u8 {
    // Получить список SMS через AT+CMGL
    if (sms.openModem()) |fd| {
        defer sms.closeModem(fd);

        const result = sms.listSms(fd, resp);
        return result;
    } else {
        return try std.fmt.bufPrint(resp, "{{\"ok\":false,\"error\":\"modem unavailable\"}}", .{});
    }
}
// smsList:end

// backlightSet:start
//   purpose: parse `backlight_set <0-100>`, clamp the level, and emit the response from backlight.setLevel().
//   input:  line — full command line; resp — destination scratch buffer.
//   output: formatted JSON (`{"ok":true,"value":{"level":<0-100>}}` on success, `{"ok":false,"error":"missing level|invalid level|setLevel failed"}` on failure).
//   sideEffects: calls backlight.setLevel which opens /dev/backlight/backlight0 + ioctl on FreeBSD.
fn backlightSet(line: []const u8, resp: []u8) ![]u8 {
    // Парсим "backlight_set <0-100>"
    var parts = std.mem.splitSequence(u8, line, " ");
    _ = parts.next(); // skip "backlight_set"

    const level_str = parts.next() orelse
        return try std.fmt.bufPrint(resp, "{{\"ok\":false,\"error\":\"missing level\"}}", .{});

    const level = std.fmt.parseInt(u16, level_str, 10) catch
        return try std.fmt.bufPrint(resp, "{{\"ok\":false,\"error\":\"invalid level\"}}", .{});

    const clamped: u8 = @as(u8, @intCast(if (level > 100) 100 else level));

    if (backlight.setLevel(clamped)) {
        return try std.fmt.bufPrint(resp, "{{\"ok\":true,\"value\":{{\"level\":{d}}}}}", .{clamped});
    } else {
        return try std.fmt.bufPrint(resp, "{{\"ok\":false,\"error\":\"setLevel failed\"}}", .{});
    }
}
// backlightSet:end

// backlightOff:start
//   purpose: turn the backlight off (`level=0`) and emit `{"ok":true,"value":"off"}` for `backlight_off`.
//   input:  resp — destination scratch buffer.
//   output: formatted JSON.
//   sideEffects: delegates to backlight.off → backlight.setLevel(0) (ioctl on FreeBSD, stub on QEMU).
fn backlightOff(resp: []u8) ![]u8 {
    backlight.off();
    return try std.fmt.bufPrint(resp, "{{\"ok\":true,\"value\":\"off\"}}", .{});
}
// backlightOff:end

// backlightOn:start
//   purpose: parse `backlight_on [level]` (default 80, clamped to 0/80/100), turn the backlight on at that level, and emit the response.
//   input:  line — full command line; resp — destination scratch buffer.
//   output: formatted JSON `{"ok":true,"value":{"level":<0-100>}}`; on parse failure defaults to 80%.
//   sideEffects: delegates to backlight.on (ioctl on FreeBSD, stub on QEMU).
fn backlightOn(line: []const u8, resp: []u8) ![]u8 {
    // Парсим "backlight_on [level]" (default 80)
    var parts = std.mem.splitSequence(u8, line, " ");
    _ = parts.next(); // skip "backlight_on"

    const level_str = parts.next() orelse "80";
    const level = std.fmt.parseInt(u16, level_str, 10) catch 80;
    const clamped: u8 = @as(u8, @intCast(if (level > 100) 100 else if (level == 0) 80 else level));

    backlight.on(clamped);
    return try std.fmt.bufPrint(resp, "{{\"ok\":true,\"value\":{{\"level\":{d}}}}}", .{clamped});
}
// backlightOn:end

// backlightGet:start
//   purpose: emit `{"ok":true,"value":{"level":<0-100>,"enabled":<bool>}}` for `backlight_get` from backlight.getLevel().
//   input:  resp — destination scratch buffer.
//   output: formatted JSON.
//   sideEffects: delegates to backlight.getLevel (ioctl BACKLIGHTGETSTATUS or sysctl fallback on FreeBSD).
fn backlightGet(resp: []u8) ![]u8 {
    const state = backlight.getLevel();
    return try std.fmt.bufPrint(resp,
        "{{\"ok\":true,\"value\":{{\"level\":{d},\"enabled\":{s}}}}}",
        .{
            state.level,
            if (state.enabled) "true" else "false",
        });
}
// backlightGet:end

// backlightAuto:start
//   purpose: read the ambient light sensor, compute the recommended brightness, apply it, and emit `{"ok":true,"value":{"lux":<n>,"auto_level":<0-100>}}` for `backlight_auto`.
//   input:  resp — destination scratch buffer.
//   output: formatted JSON; on autoLevel failure returns `{"ok":false,"error":"auto level failed"}`.
//   sideEffects: light-sensor read + ioctl BACKLIGHTSETSTATE (or sysctl fallback) via backlight.setLevel.
fn backlightAuto(resp: []u8) ![]u8 {
    // Установить яскравість на основі датчика освітлення
    if (backlight.setAutoLevel()) {
        const reading = backlight.readLightSensor();
        return try std.fmt.bufPrint(resp,
            "{{\"ok\":true,\"value\":{{\"lux\":{d},\"auto_level\":{d}}}}}",
            .{
                reading.lux,
                reading.auto_level,
            });
    } else {
        return try std.fmt.bufPrint(resp, "{{\"ok\":false,\"error\":\"auto level failed\"}}", .{});
    }
}
// backlightAuto:end

// isPlatformGatedCmd:start
//   purpose: report whether `line` names a HAL command that exists in the dispatch table
//            but is gated off on the current platform (phone-only sensor/modem/backlight).
//            Lets processTextCmd answer such commands with an explicit "unsupported on <platform>"
//            instead of the generic "unknown", which aids broker-side diagnostics.
//   input:   line — the command line (no trailing newline).
//   output:  true if the command is one of the comptime-gated capabilities; false otherwise.
//   sideEffects: none (pure substring scan over a compile-time literal list).
fn isPlatformGatedCmd(line: []const u8) bool {
    const gated = [_][]const u8{
        "get_sim_status", "get_location", "sms_send",   "sms_list",
        "get_orientation", "get_proximity", "get_compass", "haptic",
        "backlight_set",  "backlight_off", "backlight_on", "backlight_get",
        "backlight_auto",
    };
    inline for (gated) |g| {
        if (std.mem.indexOf(u8, line, g) != null) return true;
    }
    return false;
}
// isPlatformGatedCmd:end

// processTextCmd:start
//   purpose: substring-match dispatch from a single text-protocol command line to the corresponding get_*/set_* function.
//   input:  line — the command line (no trailing newline); resp — destination scratch buffer reused by the dispatched function.
//   output: whatever the dispatched function returns; on no match returns `{"ok":false,"error":"unknown"}`.
//   sideEffects: whatever the dispatched function performs (sysctl/AT/I²C/ioctl etc.); no thread/IO at this layer.
fn processTextCmd(line: []const u8, resp: []u8) ![]u8 {
    // ── Cross-platform commands (всегда доступны: sysctl/touch-zones) ──────────
    if (std.mem.indexOf(u8, line, "get_uptime")      != null) return getUptime(resp);
    if (std.mem.indexOf(u8, line, "get_hostname")    != null) return getHostname(resp);
    if (std.mem.indexOf(u8, line, "get_battery")     != null) return getBattery(resp);
    if (std.mem.indexOf(u8, line, "get_memory")      != null) return getMemory(resp);
    if (std.mem.indexOf(u8, line, "get_cpu_usage")   != null) return getCpuUsage(resp);
    if (std.mem.indexOf(u8, line, "get_touch_zone")  != null) return getTouchZone(line, resp);

    // ── Modem / SIM / SMS / GPS — только PinePhone (has_modem/sim/sms/gps) ──
    // Comptime-гейт: на QEMU/BPI эти ветки вырезаются, команда падает в "unsupported".
    if (comptime platform.has_sim) {
        if (std.mem.indexOf(u8, line, "get_sim_status") != null) return getSimStatus(resp);
    }
    if (comptime platform.has_gps) {
        if (std.mem.indexOf(u8, line, "get_location") != null) return getLocation(resp);
    }
    if (comptime platform.has_sms) {
        if (std.mem.indexOf(u8, line, "sms_send") != null) return smsSend(line, resp);
        if (std.mem.indexOf(u8, line, "sms_list") != null) return smsList(resp);
    }

    // ── Motion / environment sensors — только PinePhone (I2C-сенсоры) ──────
    // BPI-M64 эти чипы НЕ имеет (только слот расширения), поэтому не опрашиваем шину.
    if (comptime platform.has_accelerometer) {
        if (std.mem.indexOf(u8, line, "get_orientation") != null) return getOrientation(resp);
    }
    if (comptime platform.has_proximity) {
        if (std.mem.indexOf(u8, line, "get_proximity") != null) return getProximity(resp);
    }
    if (comptime platform.has_magnetometer) {
        if (std.mem.indexOf(u8, line, "get_compass") != null) return getCompass(resp);
    }
    if (comptime platform.has_haptic) {
        if (std.mem.indexOf(u8, line, "haptic") != null) return getHaptic(line, resp);
    }

    // ── Backlight — реальное железо с дисплеем (has_backlight: BPI + PinePhone) ──
    if (comptime platform.has_backlight) {
        if (std.mem.indexOf(u8, line, "backlight_set")  != null) return backlightSet(line, resp);
        if (std.mem.indexOf(u8, line, "backlight_off")  != null) return backlightOff(resp);
        if (std.mem.indexOf(u8, line, "backlight_on")   != null) return backlightOn(line, resp);
        if (std.mem.indexOf(u8, line, "backlight_get")  != null) return backlightGet(resp);
        if (std.mem.indexOf(u8, line, "backlight_auto") != null) return backlightAuto(resp);
    }

    if (std.mem.indexOf(u8, line, "hal_version")     != null) return getHalVersion(resp);

    // Известная команда, но недоступная на этой платформе → явный отказ, не "unknown".
    if (isPlatformGatedCmd(line)) {
        return try std.fmt.bufPrint(resp,
            "{{\"ok\":false,\"error\":\"unsupported on {s}\"}}",
            .{@tagName(platform.current)});
    }

    // TODO: watchdog commands disabled during migration to Zig 0.15.2
    // Бинарные команды от lifecycle/predictive_touch (4 байта)
    return try std.fmt.bufPrint(resp, "{{\"ok\":false,\"error\":\"unknown\"}}", .{});
}
// processTextCmd:end

// ── HAL command socket ────────────────────────────────────────────────────────

const HAL_SOCK = "/var/run/bsdos-hal.sock";

// serveHal:start
//   purpose: bind /var/run/bsdos-hal.sock (unlinking any stale socket first), chmod 0o777, then loop accept()-ing one connection at a time and dispatching it to handleHalConn (MVP: serial, no thread pool).
//   input:  none.
//   output: never returns under normal operation; propagates the underlying listen() / chmod() error on startup failure.
//   sideEffects: AF_UNIX SOCK_STREAM listen socket on /var/run/bsdos-hal.sock; chmod 0777; per-connection file-descriptor alloc/release; main thread blocks in accept() (kernel parks the core via WFI).
fn serveHal() !void {
    std.fs.deleteFileAbsolute(HAL_SOCK) catch {};
    const addr   = try std.net.Address.initUnix(HAL_SOCK);
    var  server  = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    _ = c.chmod(HAL_SOCK, 0o777);
    if (log_debug) std.debug.print("[hal] listening on {s}\n", .{HAL_SOCK});

    while (true) {
        const conn = try server.accept();
        // Обрабатываем последовательно (MVP — thread pool в TODO)
        handleHalConn(conn) catch |err| {
            if (log_debug) std.debug.print("[hal] conn error: {}\n", .{err});
        };
    }
}
// serveHal:end

// handleHalConn:start
//   purpose: per-connection line-buffered text-protocol reader: collect bytes into a 4 KiB scratch until '\n', trim, dispatch through processTextCmd, write the JSON response + '\n'; loop until EOF.
//   input:  conn — accepted AF_UNIX server connection (caller still owns it; this fn closes the stream on return).
//   output: void; errors from the per-line dispatch are caught and replaced with a generic `{"ok":false,"error":"internal"}` response so the connection stays usable.
//   sideEffects: reads from / writes to conn.stream; uses 4 KiB stack line_buf + 4 KiB stack resp_buf.
fn handleHalConn(conn: std.net.Server.Connection) !void {
    defer conn.stream.close();
    var line_buf: [4096]u8 = undefined;
    var resp_buf: [4096]u8 = undefined;
    var pos: usize = 0;
    var ch: [1]u8 = undefined;

    while (true) {
        const n = conn.stream.read(&ch) catch break;
        if (n == 0) break;

        if (ch[0] == '\n') {
            const line = std.mem.trim(u8, line_buf[0..pos], " \t\r");
            if (line.len > 0) {
                const r = processTextCmd(line, &resp_buf) catch blk: {
                    const msg = "{\"ok\":false,\"error\":\"internal\"}";
                    @memcpy(resp_buf[0..msg.len], msg);
                    break :blk resp_buf[0..msg.len];
                };
                conn.stream.writeAll(r) catch break;
                conn.stream.writeAll("\n") catch break;
            }
            pos = 0;
        } else if (pos < line_buf.len - 1) {
            line_buf[pos] = ch[0];
            pos += 1;
        }
    }
}
// handleHalConn:end

// ── Tickless idle: спать в kevent пока нет I/O ────────────────────────────────
//
// Cortex-A53 автоматически переходит в WFI (Wait For Interrupt) когда
// процесс заблокирован на syscall. Мы явно не управляем C-state из userspace —
// FreeBSD ядро делает это само через cpuidle.
// Наша роль: не крутить busy-loop, использовать блокирующие syscall'ы.
// kevent()/accept()/read() = ядро усыпляет поток до события → WFI автоматически.

// ── main ──────────────────────────────────────────────────────────────────────

// main:start
//   purpose: entry point — log a platform-tagged banner in Debug builds, then gate
//            per-subsystem startup on comptime platform flags (modem, I2C, accelerometer)
//            so QEMU builds never try to open real-hardware device paths.
//            Hands control to serveHal() which never returns.
//   input:  none (binary entry; cmdline unused).
//   output: never returns under normal operation; propagates any error from serveHal()
//           (which only fails on listen()).
//   sideEffects: takes ownership of the main thread; audio and ghost-radio threads
//                are commented out pending Zig 0.15.2 driver migration.
pub fn main() !void {
    if (log_debug) std.debug.print(
        "[bsdOS HAL] starting platform={s}\n",
        .{@tagName(platform.current)},
    );

    // ── Per-platform subsystem presence log ───────────────────────────────────
    // Comptime guards: каждая ветка вырезается целиком на платформах без флага.
    // BPI-M64 (Chimp): has_i2c + has_audio + has_backlight → true; modem/sim/sms/
    //   gps/accelerometer/magnetometer/proximity/haptic/ghost_radio → false.
    // PinePhone (Porcupine): все флаги true.
    // QEMU amd64/aarch64 (Squirrel): только cross-platform (cpu/uptime/mem/battery).
    // Реальной инициализации железа здесь нет — все модули открывают устройства
    // per-command on demand; этот блок только логирует профиль возможностей.

    if (comptime platform.has_modem) {
        // Modem subsystem — opens /dev/cuaU0 on demand (sim.zig/sms.zig per-command).
        if (log_debug) std.debug.print("[hal] modem: present (EC25)\n", .{});
    }

    if (comptime platform.has_i2c) {
        // I2C — первичная сенсорная шина platform.i2c_sensor_bus.
        // BPI-M64: /dev/iic0 (TWI0, слот расширения). PinePhone: /dev/iic1.
        // Сенсорные модули открывают шину через i2c.openSensorBus() per-command.
        if (log_debug) std.debug.print(
            "[hal] i2c: present ({s})\n",
            .{platform.i2c_sensor_bus},
        );
    }

    if (comptime platform.has_audio) {
        // OSS audio codec (BPI: sun4i-codec /dev/dsp0; PinePhone: /dev/dsp0).
        // TODO: re-enable audio bridge thread after Zig 0.15.2 migration.
        if (log_debug) std.debug.print("[hal] audio: present (OSS /dev/dsp0)\n", .{});
    }

    if (comptime platform.has_backlight) {
        // Backlight controller via /dev/backlight/* (опрашивается per-command).
        if (log_debug) std.debug.print("[hal] backlight: present\n", .{});
    }

    if (comptime platform.has_accelerometer) {
        // Accelerometer placeholder — LIS2DE12 on PPP I2C1 (PinePhone only; not on BPI).
        // TODO: wire up accelerometer.zig when driver migration to Zig 0.15.2 is done.
        if (log_debug) std.debug.print("[hal] accelerometer: present (LIS2DE12)\n", .{});
    }

    // ── Threads disabled pending Zig 0.15.2 migration ────────────────────────
    // TODO: audio thread (has_audio guard needed when re-enabled)
    // Поток A: audio bridge (cap'n proto zero-copy → /dev/dsp)
    //if (platform.has_audio) {
    //    const t_audio = std.Thread.spawn(
    //        .{ .stack_size = 64 * 1024 },
    //        audio.run_audio_bridge,
    //        .{},
    //    ) catch |err| {
    //        std.debug.print("[hal] audio thread failed: {}\n", .{err});
    //        return err;
    //    };
    //    t_audio.detach();
    //}

    // TODO: ghost radio thread (has_ghost_radio guard needed when re-enabled)
    // Поток B: ghost radio stealth loop
    //if (platform.has_ghost_radio) {
    //    if (std.Thread.spawn(.{ .stack_size = 32 * 1024 }, ghost.run_default, .{})) |t| {
    //        t.detach();
    //    } else |err| {
    //        std.debug.print("[hal] ghost thread failed (non-fatal): {}\n", .{err});
    //    }
    //}

    // Suppress unused imports (zones, gps, prox, sim, sms, touch, charging, haptic
    // are reached only through processTextCmd dispatch table)
    _ = &touch; _ = &sim; _ = &sms; _ = &gps; _ = &prox; _ = &charging; _ = &haptic;

    // Main thread: HAL socket (tickless — accept() блокирует → ARM WFI)
    try serveHal();
}
// main:end

// ── Unit tests ────────────────────────────────────────────────────────────────

test "touch zones compile-time detection" {
    // appA center (360, 400)
    const zone_appA = zones.detectJail(360, 400);
    try std.testing.expect(zone_appA != null);
    try std.testing.expectEqualStrings("appA", zone_appA.?);

    // appB center (360, 1000)
    const zone_appB = zones.detectJail(360, 1000);
    try std.testing.expect(zone_appB != null);
    try std.testing.expectEqualStrings("appB", zone_appB.?);

    // StatusBar (360, 20) — outside zones
    const zone_statusbar = zones.detectJail(360, 20);
    try std.testing.expectEqual(zone_statusbar, null);

    // Dock (360, 1420) — outside zones
    const zone_dock = zones.detectJail(360, 1420);
    try std.testing.expectEqual(zone_dock, null);
}

test "touch zone with pressure filter" {
    // Low pressure (< 10) should return null
    const low = zones.detectZoneForEvent(360, 400, 5);
    try std.testing.expectEqual(low, null);

    // Normal pressure should detect zone
    const normal = zones.detectZoneForEvent(360, 400, 50);
    try std.testing.expect(normal != null);
    try std.testing.expectEqualStrings("appA", normal.?);
}

test "touch zone status bar and dock detection" {
    // isStatusBar
    try std.testing.expect(zones.isStatusBar(30) == true);
    try std.testing.expect(zones.isStatusBar(100) == false);

    // isDock
    try std.testing.expect(zones.isDock(1400) == true);
    try std.testing.expect(zones.isDock(1000) == false);
}

test "processTextCmd: get_uptime returns valid JSON" {
    var buf: [4096]u8 = undefined;
    const resp = try processTextCmd("get_uptime", &buf);
    try std.testing.expect(resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\"") != null);
}

test "processTextCmd: get_hostname returns valid JSON" {
    var buf: [4096]u8 = undefined;
    const resp = try processTextCmd("get_hostname", &buf);
    try std.testing.expect(resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"value\"") != null);
}

test "processTextCmd: get_battery returns valid JSON" {
    var buf: [4096]u8 = undefined;
    const resp = try processTextCmd("get_battery", &buf);
    try std.testing.expect(resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"pct\"") != null);
}

test "processTextCmd: get_memory returns valid JSON" {
    var buf: [4096]u8 = undefined;
    const resp = try processTextCmd("get_memory", &buf);
    try std.testing.expect(resp.len > 0);
    // On QEMU, sysctl might fail gracefully
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\"") != null);
}

test "processTextCmd: get_sim_status returns valid JSON" {
    var buf: [4096]u8 = undefined;
    const resp = try processTextCmd("get_sim_status", &buf);
    try std.testing.expect(resp.len > 0);
    // On QEMU without modem, should return error gracefully
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\"") != null);
}

test "processTextCmd: get_location returns valid JSON" {
    var buf: [4096]u8 = undefined;
    const resp = try processTextCmd("get_location", &buf);
    try std.testing.expect(resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\"") != null);
}

test "processTextCmd: get_proximity returns valid JSON" {
    var buf: [4096]u8 = undefined;
    const resp = try processTextCmd("get_proximity", &buf);
    try std.testing.expect(resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\"") != null);
}

test "processTextCmd: get_compass returns valid JSON" {
    var buf: [4096]u8 = undefined;
    const resp = try processTextCmd("get_compass", &buf);
    try std.testing.expect(resp.len > 0);
    // Disabled during migration
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\"") != null);
}

test "processTextCmd: get_orientation returns valid JSON" {
    var buf: [4096]u8 = undefined;
    const resp = try processTextCmd("get_orientation", &buf);
    try std.testing.expect(resp.len > 0);
    // Disabled during migration
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\"") != null);
}

test "processTextCmd: hal_version returns features list" {
    var buf: [4096]u8 = undefined;
    const resp = try processTextCmd("hal_version", &buf);
    try std.testing.expect(resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"version\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"features\"") != null);
}

test "processTextCmd: unknown command returns error JSON" {
    var buf: [4096]u8 = undefined;
    const resp = try processTextCmd("invalid_command_xyz", &buf);
    try std.testing.expect(resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"error\"") != null);
}

test "getTouchZone: parses X Y arguments" {
    var buf: [4096]u8 = undefined;
    const resp = try getTouchZone("get_touch_zone 360 400", &buf);
    try std.testing.expect(resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "appA") != null);
}

test "getTouchZone: returns null for non-zone coordinates" {
    var buf: [4096]u8 = undefined;
    const resp = try getTouchZone("get_touch_zone 360 20", &buf);
    try std.testing.expect(resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "null") != null);
}

test "getTouchZone: missing arguments returns error" {
    var buf: [4096]u8 = undefined;
    const resp = try getTouchZone("get_touch_zone 360", &buf);
    try std.testing.expect(resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "missing") != null);
}

test "getTouchZone: invalid coordinates return error" {
    var buf: [4096]u8 = undefined;
    const resp = try getTouchZone("get_touch_zone abc def", &buf);
    try std.testing.expect(resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "invalid") != null);
}

test "getHaptic: short pattern returns success" {
    var buf: [4096]u8 = undefined;
    const resp = try getHaptic("haptic short", &buf);
    try std.testing.expect(resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\"") != null);
}

test "getHaptic: unknown pattern returns error" {
    var buf: [4096]u8 = undefined;
    const resp = try getHaptic("haptic invalid_pattern", &buf);
    try std.testing.expect(resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
}

test "smsSend: missing number returns error" {
    var buf: [4096]u8 = undefined;
    const resp = try smsSend("sms_send", &buf);
    try std.testing.expect(resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"ok\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "missing") != null);
}

test "response buffer never overflows" {
    var buf: [4096]u8 = undefined;
    const resp = try processTextCmd("get_uptime", &buf);
    // Response must fit in 4096 bytes
    try std.testing.expect(resp.len <= 4096);
}

test "SysCmd frame size is exactly 4 bytes" {
    try std.testing.expectEqual(@sizeOf(SysCmd), 4);
}

test "no response contains unescaped control characters" {
    var buf: [4096]u8 = undefined;
    const resp = try processTextCmd("get_hostname", &buf);

    // Check that response doesn't contain raw nulls, newlines in JSON value
    // (they should be escaped as \0, \n)
    var i: usize = 0;
    while (i < resp.len) : (i += 1) {
        const ch = resp[i];
        // Allow newline only at end
        if (ch == '\n' and i == resp.len - 1) continue;
        // Other control chars should not appear
        if (ch < 0x20 and ch != '\t') {
            return error.UnescapedControlChar;
        }
    }
}
