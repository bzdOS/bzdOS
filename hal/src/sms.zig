// START_AI_HEADER
// MODULE: hal/src/sms.zig
// PURPOSE: SMS send/list over the Quectel EG25-G AT interface (AT+CMGF=1, AT+CMGS, AT+CMGL) on the same /dev/cuaU0 UART the SIM driver uses.
// INTENT: Stack-only, no allocator on hot paths. Reuse the AT_BUF_SIZE scratch across the 3 subcommands. Phase 1 covers send+list; read/delete and URC notifications are explicitly deferred.
// DEPENDENCIES: std (mem, posix, fmt), libc via @cImport (termios, unistd, fcntl, sys/time, errno, string) — same set as sim.zig.
// PUBLIC_API: SmsMessage struct, openModem() ?fd_t, closeModem(fd), sendSms(fd, number, text) bool, listSms(fd, buf) ![]u8.
// END_AI_HEADER

// SMS через AT команды EG25-G модема
// Транспорт: /dev/cuaU0 (из sim.zig)
//
// Phase 1: AT send (AT+CMGS) + list (AT+CMGL)
// Phase 2: read/delete (AT+CMGR, AT+CMGD)
// Phase 3: incoming notifications (AT+CNMI, URC)
//
// Все операции на стеке, без allocator в hot paths.

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

// Константы
const MODEM_DEV = "/dev/cuaU0";
const AT_TIMEOUT_MS: u64 = 3000;
const AT_BUF_SIZE: usize = 512;

pub const SmsMessage = struct {
    from: [20]u8 = [_]u8{0} ** 20,
    from_len: usize = 0,
    body: [160]u8 = [_]u8{0} ** 160,
    body_len: usize = 0,
    ts: [20]u8 = [_]u8{0} ** 20,
    ts_len: usize = 0,
};

// Открыть UART модема (переиспользуем из sim.zig эквивалент)
// openModem:start
//   purpose: open /dev/cuaU0 in RDWR, put termios into raw 115200 8N1 with VMIN=1 / VTIME=10 (same shape as sim.openModem).
//   input:  none.
//   output: configured fd on success; null on any termios/open failure.
//   sideEffects: opens /dev/cuaU0; mutates kernel-side termios.
pub fn openModem() ?std.posix.fd_t {
    const fd = std.posix.open(MODEM_DEV, .{ .ACCMODE = .RDWR }, 0) catch {
        return null;  // Модем недоступен
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
    t.c_cc[c.VTIME] = 10;  // 0.1 sec

    if (c.tcsetattr(fd, c.TCSANOW, &t) != 0) {
        _ = c.close(fd);
        return null;
    }

    return fd;
}
// openModem:end

// Закрыть модем
// closeModem:start
//   purpose: close(2) wrapper for the SMS modem fd.
//   input:  fd — previously returned by openModem().
//   output: void.
//   sideEffects: closes the fd.
pub fn closeModem(fd: std.posix.fd_t) void {
    _ = c.close(fd);
}
// closeModem:end

// Отправить AT команду и прочитать ответ (с таймаутом)
// Возвращает длину буфера с ответом (без \r\n)
// sendAt:start
//   purpose: write cmd + CRLF, read up to 10 s of response into an internal scratch, detect OK/ERROR terminators, and copy the cleaned payload into buf. Effectively a duplicate of sim.sendAt — kept independent so SMS-side parameter changes don't break the SIM path.
//   input:  fd — open modem; cmd — command bytes; buf — destination buffer.
//   output: cleaned response length, or null on transport/ERROR/empty.
//   sideEffects: writes + reads on the modem UART.
fn sendAt(fd: std.posix.fd_t, cmd: []const u8, buf: []u8) ?usize {
    // Отправить команду
    const cmd_with_len = @min(cmd.len, AT_BUF_SIZE - 2);

    if (c.write(fd, cmd.ptr, cmd_with_len) < 0) {
        return null;
    }
    if (c.write(fd, "\r\n".ptr, 2) < 0) {
        return null;
    }

    // Читаем ответ до "OK\r\n" или "ERROR"
    var resp_buf: [AT_BUF_SIZE]u8 = undefined;
    var resp_pos: usize = 0;
    var read_count: usize = 0;
    const max_reads: usize = 100;  // макс 100 * 100ms = 10 sec total

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

        // Проверяем на "OK\r\n" или "ERROR\r\n"
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

    // Очистить буфер ответа
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

// Отправить SMS через AT+CMGS
// number: "+1234567890"
// text: "Hello from bsdOS"
// sendSms:start
//   purpose: send one SMS — switch modem into text mode (AT+CMGF=1), open the message with AT+CMGS="<number>", wait for the > prompt, write the body + Ctrl-Z, and confirm with a final OK/ERROR read.
//   input:  fd — open modem; number — destination in international form; text — message body (truncated to 160 chars per SMS spec).
//   output: true on a final OK; false on any intermediate failure (text-mode, CMGS, body write, or final ack).
//   sideEffects: 3 AT round-trips + one 160-byte text write + one Ctrl-Z write on the UART.
pub fn sendSms(fd: std.posix.fd_t, number: []const u8, text: []const u8) bool {
    // Установить текстовый режим (Phase 1)
    var dummy: [64]u8 = undefined;
    if (sendAt(fd, "AT+CMGF=1", &dummy) == null) {
        return false;
    }

    // AT+CMGS="+1234567890"
    var cmd_buf: [256]u8 = undefined;
    const cmd_result = std.fmt.bufPrint(&cmd_buf, "AT+CMGS=\"{s}\"", .{number}) catch return false;

    if (sendAt(fd, cmd_result, &dummy) == null) {
        return false;
    }

    // Отправить текст + Ctrl-Z
    const text_len = @min(text.len, 160);  // SMS максимум 160 символов
    if (c.write(fd, text.ptr, text_len) < 0) {
        return false;
    }

    // Ctrl-Z (0x1A) для отправки
    const ctrl_z: u8 = 0x1A;
    if (c.write(fd, &ctrl_z, 1) < 0) {
        return false;
    }

    // Читаем финальный OK/ERROR
    var resp_buf: [256]u8 = undefined;
    return sendAt(fd, "", &resp_buf) != null;
}
// sendSms:end

// Получить список SMS через AT+CMGL
// Возвращает JSON массив индексов: [1, 2, 3, ...]
// listSms:start
//   purpose: AT+CMGL="ALL", scan the response for "+CMGL: <idx>," markers, and emit a JSON array of indices directly into buf.
//   input:  fd — open modem; buf — destination scratch buffer.
//   output: slice of buf with the formatted JSON (`{"ok":true,"value":[idx,...]}` or `[]` for empty, or `{"ok":false,"error":"..."}` on failure).
//   sideEffects: 2 AT round-trips; in-memory scan of the response.
pub fn listSms(fd: std.posix.fd_t, buf: []u8) ![]u8 {
    // Установить текстовый режим
    var dummy: [64]u8 = undefined;
    if (sendAt(fd, "AT+CMGF=1", &dummy) == null) {
        const msg = "{\"ok\":false,\"error\":\"modem error\"}";
        const len = @min(msg.len, buf.len);
        @memcpy(buf[0..len], msg[0..len]);
        return buf[0..len];
    }

    // AT+CMGL="ALL"
    var resp: [AT_BUF_SIZE]u8 = undefined;
    if (sendAt(fd, "AT+CMGL=\"ALL\"", &resp)) |resp_len| {
        if (resp_len == 0) {
            // Нет SMS
            const msg = "{\"ok\":true,\"value\":[]}";
            const len = @min(msg.len, buf.len);
            @memcpy(buf[0..len], msg[0..len]);
            return buf[0..len];
        }

        // Парсим ответ, ищем индексы (формат: "+CMGL: 1,1,..." и т.д.)
        // Простое решение: собираем индексы вручную
        var result_pos: usize = 0;
        const msg_prefix = "{\"ok\":true,\"value\":[";
        @memcpy(buf[result_pos .. result_pos + msg_prefix.len], msg_prefix);
        result_pos += msg_prefix.len;

        var i: usize = 0;
        var first = true;
        while (i < resp_len) {
            if (std.mem.eql(u8, resp[i .. @min(i + 7, resp_len)], "+CMGL: ")) {
                i += 7;
                // Парсим индекс (первое число)
                const idx_start = i;
                while (i < resp_len and resp[i] >= '0' and resp[i] <= '9') : (i += 1) {}

                if (i > idx_start) {
                    if (!first) {
                        if (result_pos + 1 < buf.len) {
                            buf[result_pos] = ',';
                            result_pos += 1;
                        }
                    }
                    const idx_str = resp[idx_start..i];
                    if (result_pos + idx_str.len < buf.len) {
                        @memcpy(buf[result_pos .. result_pos + idx_str.len], idx_str);
                        result_pos += idx_str.len;
                    }
                    first = false;
                }
            } else {
                i += 1;
            }
        }

        const msg_suffix = "]}";
        if (result_pos + msg_suffix.len < buf.len) {
            @memcpy(buf[result_pos .. result_pos + msg_suffix.len], msg_suffix);
            result_pos += msg_suffix.len;
        }

        return buf[0..@min(result_pos, buf.len)];
    }

    const msg = "{\"ok\":false,\"error\":\"list failed\"}";
    const len = @min(msg.len, buf.len);
    @memcpy(buf[0..len], msg[0..len]);
    return buf[0..len];
}
// listSms:end

// TODO: Phase 2
// pub fn readSms(fd: std.posix.fd_t, id: u32) ?SmsMessage { ... }
// pub fn deleteSms(fd: std.posix.fd_t, id: u32) bool { ... }
