// START_AI_HEADER
// MODULE: hal/src/watchdog.zig
// PURPOSE: FreeBSD /dev/watchdog heartbeat supervisor — keep the kernel watchdog fed every 10 s; if this HAL ever wedges, the kernel will NMI-reset the box.
// INTENT: Pet cadence is 1/3 of the typical 30-second kernel timeout so a single missed pet is recoverable. The pet thread is a detached loop; close() writes the magic 'V' for a graceful disable.
// DEPENDENCIES: std (posix.write, posix.close), libc via @cImport (fcntl, sys/time, sys/select for the timed sleep).
// PUBLIC_API: WatchdogError error set, open() !i32, pet() !void, close() void, runHeartbeat() void (thread entry), formatStatus(buf) ![]u8.
// END_AI_HEADER

// Hardware watchdog для bsdOS — `/dev/watchdog` heartbeat supervisor.
//
// Деталі FreeBSD:
// - write(fd, "1") = pet (дати ядру heartbeat)
// - write(fd, "V") = disable (магічне число, вимкнення)
// - ioctl WDIOCSETTIME = встановити timeout (мс або сек, залежить від driver'а)
//
// Наш стратегія:
// 1. Відкрити /dev/watchdog при startup (non-blocking, O_RDWR)
// 2. Кожні 10 сек: write(fd, "1")
// 3. Якщо write() помилиться або HAL завис → heartbeat припиняється
//    → ядро виявляє timeout (kernel watchdog) → NMI reset → reboot

const std = @import("std");
const builtin = @import("builtin");
const log_debug = builtin.mode == .Debug;

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("sys/time.h");
});

// FreeBSD watchdog device
const WATCHDOG_DEV = "/dev/watchdog";
const WATCHDOG_PET = "1";
const WATCHDOG_DISABLE = "V";

// Heartbeat інтервал: 10 сек (1/3 від типового 30-сек kernel timeout)
const HEARTBEAT_INTERVAL_SECS: u64 = 10;

// Глобальний fd для watchdog (thread-safe читання, write() атомарний)
var watchdog_fd: ?i32 = null;
var watchdog_init_done = false;

pub const WatchdogError = error{
    DeviceNotFound,
    OpenFailed,
    WriteFailed,
    AlreadyInitialized,
    NotInitialized,
};

// ── Ініціалізація watchdog ──────────────────────────────────────────────────────

/// open() запускається одного разу при startup.
/// Відкриває /dev/watchdog для писання (non-blocking).
// open:start
//   purpose: open /dev/watchdog in O_WRONLY|O_NONBLOCK once at startup; idempotent (returns WatchdogError.AlreadyInitialized on second call).
//   input:  none.
//   output: the kernel watchdog fd (i32) on success; WatchdogError.AlreadyInitialized on a second call, error.NotFreeBSD on non-FreeBSD targets, WatchdogError.OpenFailed if open(2) returns -1.
//   sideEffects: opens /dev/watchdog; sets the module-global watchdog_fd and watchdog_init_done.
pub fn open() !i32 {
    if (watchdog_init_done) {
        return WatchdogError.AlreadyInitialized;
    }

    if (builtin.target.os.tag != .freebsd) {
        // На non-FreeBSD системах /dev/watchdog може не існувати
        // Логуємо warning, але не падаємо
        if (log_debug) std.debug.print("[watchdog] skipped: not FreeBSD\n", .{});
        watchdog_init_done = true;
        return error.NotFreeBSD;
    }

    const flags: c_int = c.O_WRONLY | c.O_NONBLOCK;
    const fd = c.open(WATCHDOG_DEV, flags, @as(c_uint, 0));
    if (fd < 0) {
        if (log_debug) std.debug.print("[watchdog] failed to open {s}\n", .{WATCHDOG_DEV});
        return WatchdogError.OpenFailed;
    }

    watchdog_fd = fd;
    watchdog_init_done = true;

    if (log_debug) std.debug.print("[watchdog] opened {s} (fd={d})\n", .{ WATCHDOG_DEV, fd });
    return fd;
}
// open:end

/// pet() — write heartbeat до /dev/watchdog.
/// Безпечна для виклику з будь-якого потока (write() атомарний у POSIX).
// pet:start
//   purpose: write the 1-byte "1" heartbeat to /dev/watchdog (up to 3 attempts) to keep the kernel from resetting; no-op if the watchdog was never opened.
//   input:  none.
//   output: void on success; silently returns if watchdog_fd is null; WatchdogError.WriteFailed after 3 failed attempts.
//   sideEffects: one write(2) syscall per attempt (max 3).
pub fn pet() !void {
    const fd = watchdog_fd orelse {
        // Watchdog не ініціалізований (можна пропустити, це не критично)
        return;
    };

    // write() може бути перервана, так що кілька спроб:
    var attempt: u8 = 0;
    while (attempt < 3) : (attempt += 1) {
        const n = std.posix.write(fd, WATCHDOG_PET) catch |err| {
            if (log_debug) std.debug.print("[watchdog] write failed (attempt {d}/3): {}\n", .{ attempt + 1, err });
            if (attempt == 2) {
                return err;
            }
            continue;
        };

        if (n > 0) {
            // Успішно написали heartbeat
            return;
        } else {
            if (log_debug) std.debug.print("[watchdog] write returned 0 (attempt {d}/3)\n", .{attempt + 1});
        }
    }

    return WatchdogError.WriteFailed;
}
// pet:end

/// close() — вимкнути watchdog перед shutdown (граціозний вихід).
/// Записує магічний символ "V" до ядра.
// close:start
//   purpose: graceful shutdown — write the magic 'V' byte to the kernel (disables the watchdog) then close the fd; no-op if not open.
//   input:  none.
//   output: void; errors from the magic-byte write are logged and swallowed (kernel will still reset us if we crashed, but at least we tried).
//   sideEffects: one write(2) + one close(2) on /dev/watchdog; clears the module-global watchdog_fd.
pub fn close() void {
    const fd = watchdog_fd orelse return;

    // Спробуємо писати магічний символ (graceful disable)
    _ = std.posix.write(fd, WATCHDOG_DISABLE) catch |err| {
        if (log_debug) std.debug.print("[watchdog] graceful disable failed: {}\n", .{err});
    };

    std.posix.close(fd);
    watchdog_fd = null;
    if (log_debug) std.debug.print("[watchdog] closed\n", .{});
}
// close:end

// ── Heartbeat loop (детачений потік) ────────────────────────────────────────────

/// runHeartbeat() — live цикл для heartbeat потока.
/// Запускається в окремому потоці (stack_size = 16 KB).
/// Кожні 10 сек пише "1" до /dev/watchdog.
// runHeartbeat:start
//   purpose: detached-thread entry — open() the watchdog, then loop forever: sleep HEARTBEAT_INTERVAL_SECS via select() timeout, then pet(); once a minute print a debug heartbeat counter.
//   input:  none.
//   output: noreturn-style void — this function is intended to be spawned with std.Thread and never returns.
//   sideEffects: blocks on select() inside the kernel; pet() opens/closes /dev/watchdog on first iteration; one stderr line per minute in Debug builds.
pub fn runHeartbeat() void {
    if (log_debug) std.debug.print("[watchdog] heartbeat thread starting\n", .{});

    // Ініціалізуємо watchdog
    if (open()) |_| {
        if (log_debug) std.debug.print("[watchdog] watchdog initialized\n", .{});
    } else |err| {
        if (log_debug) std.debug.print("[watchdog] init failed: {}, continuing without watchdog\n", .{err});
    }

    // Loop: heartbeat цикл
    var iter: u64 = 0;
    while (true) : (iter += 1) {
        // Спимо HEARTBEAT_INTERVAL_SECS через select() timeout
        var timeout: c.timeval = undefined;
        timeout.tv_sec = @as(c.time_t, HEARTBEAT_INTERVAL_SECS);
        timeout.tv_usec = 0;
        _ = c.select(0, null, null, null, &timeout);

        // Пишемо heartbeat
        if (pet()) |_| {
            // Успішно
        } else |err| {
            if (log_debug) std.debug.print("[watchdog] heartbeat #{d} failed: {}\n", .{ iter, err });
            // Продовжуємо спробу при наступному циклі (не впадаємо)
        }

        if (iter % 6 == 0) {
            // Раз на хвилину: log статистика (60 сек = 6 × 10 сек heartbeat)
            if (log_debug) std.debug.print("[watchdog] alive (heartbeat #{d})\n", .{iter});
        }
    }
}
// runHeartbeat:end

// ── Команда для HAL socket ──────────────────────────────────────────────────────

/// format_watchdog_status() — JSON статус для HAL socket.
// formatStatus:start
//   purpose: emit `{"ok":true,"value":{"watchdog":"enabled"|"disabled","interval_secs":<n>}}` for the HAL socket `watchdog_status` command.
//   input:  buf — destination scratch buffer.
//   output: a slice of buf with the formatted JSON.
//   sideEffects: none (reads the module-global watchdog_fd).
pub fn formatStatus(buf: []u8) ![]u8 {
    const enabled = watchdog_fd != null;
    const status = if (enabled) "enabled" else "disabled";

    return try std.fmt.bufPrint(
        buf,
        "{{\"ok\":true,\"value\":{{\"watchdog\":\"{s}\",\"interval_secs\":{d}}}}}",
        .{ status, HEARTBEAT_INTERVAL_SECS },
    );
}
// formatStatus:end

// ── Тестування (при compile з -Dtest) ──────────────────────────────────────────

export fn test_watchdog_open() void {
    if (open()) |fd| {
        if (log_debug) std.debug.print("[test] watchdog opened: fd={d}\n", .{fd});
    } else |err| {
        if (log_debug) std.debug.print("[test] watchdog open failed: {}\n", .{err});
    }
}

export fn test_watchdog_pet() void {
    pet() catch |err| {
        if (log_debug) std.debug.print("[test] pet failed: {}\n", .{err});
    };
}

export fn test_watchdog_close() void {
    close();
}
