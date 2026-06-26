// START_AI_HEADER
// MODULE: sys-daemon-zig/src/modem.zig
// PURPOSE: Общие операции модема (open/close/sendAt) для sim.zig и sms.zig
// INTENT: Устранить дублирование modem операций между sim.zig и sms.zig
// DEPENDENCIES: libc (termios, unistd, fcntl, sys/time, errno, string)
// PUBLIC_API: openModem, closeModem, sendAt
// END_AI_HEADER

const std = @import("std");
const builtin = @import("builtin");

const c = if (builtin.target.os.tag == .freebsd) @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/time.h");
    @cInclude("errno.h");
    @cInclude("string.h");
}) else @cImport({
    @cInclude("termios.h");
    @cInclude("unistd.h");
    @cInclude("fcntl.h");
    @cInclude("sys/time.h");
    @cInclude("errno.h");
    @cInclude("string.h");
});

const MODEM_DEV = "/dev/cuaU0";
const MODEM_BAUD = 115200;
const AT_TIMEOUT_MS: u64 = 3000;
const AT_BUF_SIZE: usize = 512;

// openModem:start
//   purpose: Открыть UART модем и настроить termios (115200 8N1, VMIN=1, VTIME=10)
//   input: none
//   output: файловый дескриптор или null при ошибке
//   sideEffects: open(2), tcgetattr(2), cfsetspeed(2), tcsetattr(2)
pub fn openModem() ?std.posix.fd_t {
    const fd = std.posix.open(MODEM_DEV, .{ .ACCMODE = .RDWR }, 0) catch {
        return null;
    };

    var t: c.termios = undefined;
    if (c.tcgetattr(fd, &t) != 0) {
        _ = c.close(fd);
        return null;
    }

    c.cfmakeraw(&t);

    if (c.cfsetspeed(&t, c.B115200) != 0) {
        _ = c.close(fd);
        return null;
    }

    t.c_cc[c.VMIN] = 1;
    t.c_cc[c.VTIME] = 10;

    if (c.tcsetattr(fd, c.TCSANOW, &t) != 0) {
        _ = c.close(fd);
        return null;
    }

    return fd;
}
// openModem:end

// closeModem:start
//   purpose: Закрыть файловый дескриптор модема
//   input: fd - файловый дескриптор модема
//   output: void
//   sideEffects: close(2) syscall
pub fn closeModem(fd: std.posix.fd_t) void {
    _ = c.close(fd);
}
// closeModem:end

// sendAt:start
//   purpose: Отправить AT команду и прочитать ответ (с таймаутом)
//   input: fd - файловый дескриптор модема, cmd - AT команда, buf - буфер для ответа
//   output: длина ответа или null при ошибке/таймауте
//   sideEffects: write(2), read(2) syscalls
pub fn sendAt(fd: std.posix.fd_t, cmd: []const u8, buf: []u8) ?usize {
    const cmd_with_crlf = cmd[0..@min(cmd.len, AT_BUF_SIZE - 2)];

    if (c.write(fd, cmd_with_crlf.ptr, cmd_with_crlf.len) < 0) {
        return null;
    }
    if (c.write(fd, "\r\n".ptr, 2) < 0) {
        return null;
    }

    var resp_buf: [AT_BUF_SIZE]u8 = undefined;
    var resp_pos: usize = 0;
    var read_count: usize = 0;
    const max_reads: usize = 100;

    while (read_count < max_reads and resp_pos < AT_BUF_SIZE) : (read_count += 1) {
        const n = c.read(fd, resp_buf[resp_pos .. resp_pos + 1].ptr, 1);
        if (n < 0) {
            if (resp_pos == 0) return null;
            break;
        }
        if (n == 0) {
            break;
        }

        resp_pos += 1;

        if (resp_pos >= 2) {
            if (std.mem.eql(u8, resp_buf[resp_pos - 2 .. resp_pos], "\r\n")) {
                if (resp_pos >= 4) {
                    if (std.mem.eql(u8, resp_buf[resp_pos - 4 .. resp_pos - 2], "OK")) {
                        break;
                    }
                }
                if (resp_pos >= 7) {
                    if (std.mem.eql(u8, resp_buf[resp_pos - 7 .. resp_pos - 2], "ERROR")) {
                        return null;
                    }
                }
            }
        }
    }

    if (resp_pos == 0) return null;

    var i: usize = 0;
    while (i < resp_pos and (resp_buf[i] == '\r' or resp_buf[i] == '\n')) : (i += 1) {}

    const start_idx = i;

    var end_idx = resp_pos;
    while (end_idx > start_idx and (resp_buf[end_idx - 1] == '\r' or resp_buf[end_idx - 1] == '\n')) : (end_idx -= 1) {}

    if (end_idx >= 2 and std.mem.eql(u8, resp_buf[end_idx - 2 .. end_idx], "OK")) {
        end_idx -= 2;
    }
    if (end_idx >= 5 and std.mem.eql(u8, resp_buf[end_idx - 5 .. end_idx], "ERROR")) {
        end_idx -= 5;
    }

    while (end_idx > start_idx and (resp_buf[end_idx - 1] == '\r' or resp_buf[end_idx - 1] == '\n')) : (end_idx -= 1) {}

    const result_len = @min(end_idx - start_idx, buf.len - 1);
    if (result_len > 0) {
        @memcpy(buf[0..result_len], resp_buf[start_idx .. start_idx + result_len]);
    }

    return result_len;
}
// sendAt:end
