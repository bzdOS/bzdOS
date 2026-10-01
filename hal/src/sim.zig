// START_AI_HEADER
// MODULE: sys-daemon-zig/src/sim.zig
// PURPOSE: SIM card status driver over the Quectel EG25-G modem on /dev/cuaU0 — 5 AT commands (CIMI, CPIN, CSQ, COPS, CREG) packed into a single SimInfo struct.
// INTENT: Keep the AT I/O stack-only (no heap on the hot path); reuse a single AT_BUF_SIZE scratch across all 5 commands. Each parser is a separate small function so the dispatcher (getSimInfo) can swap or fall back per-field.
// DEPENDENCIES: std (mem, posix, fmt), libc via @cImport (termios, unistd, fcntl, sys/time, errno, string).
// PUBLIC_API: SimInfo, PinStatus, openModem() ?fd_t, closeModem(fd), sendAt(fd, cmd, buf) ?usize, getSimInfo(fd) ?SimInfo, formatSimInfo(info, buf) usize.
// END_AI_HEADER

// SIM Card Management через AT-команды (Quectel EG25-G)
// Транспорт: /dev/cuaU0 (UART USB serial, 115200 baud)
//
// Команды:
//   AT+CIMI       → прочитать IMSI (International Mobile Subscriber Identity)
//   AT+CPIN?      → статус PIN (READY, SIM PIN, SIM PUK и т.д.)
//   AT+CSQ        → уровень сигнала (RSSI в dBm, BER)
//   AT+COPS?      → оператор сети
//   AT+CREG?      → регистрация в сети (0-5 = статусы)
//   AT+CLCK       → блокировка SIM PIN
//
// Все операции на стеке, без allocator в hot paths.
// Таймаут: 3000 ms для AT команд.

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
const MODEM_BAUD = 115200;
const AT_TIMEOUT_MS: u64 = 3000;
const AT_BUF_SIZE: usize = 512;

pub const SimInfo = struct {
    imsi: [20]u8 = [_]u8{0} ** 20,
    imsi_len: usize = 0,
    operator: [32]u8 = [_]u8{0} ** 32,
    operator_len: usize = 0,
    signal_rssi: i8 = -99,  // dBm, -99 = no signal
    signal_ber: u8 = 99,    // Bit Error Rate (0-7 = дБ, 99 = unknown)
    pin_status: PinStatus = .unknown,
    registered: bool = false,
    registration_status: u8 = 0,  // 0=not registered, 1=home, 2=searching, 5=roaming
};

pub const PinStatus = enum(u8) {
    unknown = 0,
    ready = 1,
    sim_pin = 2,
    sim_puk = 3,
    phone_pin = 4,
    phone_puk = 5,
    sim_pin2 = 6,
    sim_puk2 = 7,
};

// Открыть UART устройство и настроить termios
// openModem:start
//   purpose: open /dev/cuaU0 in RDWR, put the termios into raw mode at 115200 8N1 with VMIN=1 / VTIME=10 (0.1 s interbyte timeout).
//   input:  none.
//   output: the configured fd on success; null if open/tcgetattr/cfsetspeed/tcsetattr fails (no real modem, wrong permissions, or non-FreeBSD).
//   sideEffects: opens /dev/cuaU0; mutates the kernel-side termios.
pub fn openModem() ?std.posix.fd_t {
    const fd = std.posix.open(MODEM_DEV, .{ .ACCMODE = .RDWR }, 0) catch {
        return null;  // Модем недоступен (OK на non-real hardware)
    };

    var t: c.termios = undefined;
    if (c.tcgetattr(fd, &t) != 0) {
        _ = c.close(fd);
        return null;
    }

    // Очистить режимы и установить raw
    c.cfmakeraw(&t);

    // Скорость передачи 115200
    if (c.cfsetspeed(&t, c.B115200) != 0) {
        _ = c.close(fd);
        return null;
    }

    // Минимум 1 символ, таймаут 100ms
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
//   purpose: thin wrapper around close(2) for the modem fd.
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
//   purpose: write the AT command + "\r\n" to the modem, read characters one at a time until "OK\r\n" or "ERROR\r\n" appears, then strip the OK/ERROR echo and surrounding CRLF into buf.
//   input:  fd — open modem; cmd — command bytes (no trailing CRLF); buf — destination buffer for the cleaned response.
//   output: length of the cleaned response written into buf; null on transport error, modem returned "ERROR", or zero-byte response.
//   sideEffects: one write(2) for the command + "\r\n", up to 100 read(2) calls (≤ 10 s total), one @memcpy into buf.
pub fn sendAt(fd: std.posix.fd_t, cmd: []const u8, buf: []u8) ?usize {
    // Отправить команду
    const cmd_with_crlf = cmd[0..@min(cmd.len, AT_BUF_SIZE - 2)];

    // write "cmd\r\n"
    if (c.write(fd, cmd_with_crlf.ptr, cmd_with_crlf.len) < 0) {
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
            // Таймаут или ошибка
            if (resp_pos == 0) return null;
            break;
        }
        if (n == 0) {
            // EOF
            break;
        }

        resp_pos += 1;

        // Проверяем на "OK\r\n" или "ERROR\r\n"
        if (resp_pos >= 2) {
            if (std.mem.eql(u8, resp_buf[resp_pos - 2 .. resp_pos], "\r\n")) {
                // Проверяем что это OK или ERROR
                if (resp_pos >= 4) {
                    if (std.mem.eql(u8, resp_buf[resp_pos - 4 .. resp_pos - 2], "OK")) {
                        // Успешно
                        break;
                    }
                }
                if (resp_pos >= 7) {
                    if (std.mem.eql(u8, resp_buf[resp_pos - 7 .. resp_pos - 2], "ERROR")) {
                        // Ошибка AT команды
                        return null;
                    }
                }
            }
        }
    }

    if (resp_pos == 0) return null;

    // Очистить буфер ответа от лишнего и пропустить echo команды
    var i: usize = 0;
    while (i < resp_pos and (resp_buf[i] == '\r' or resp_buf[i] == '\n')) : (i += 1) {}

    const start_idx = i;

    // Найти последний \r\n перед OK/ERROR
    var end_idx = resp_pos;
    while (end_idx > start_idx and (resp_buf[end_idx - 1] == '\r' or resp_buf[end_idx - 1] == '\n')) : (end_idx -= 1) {}

    // Дополнительно очистить OK/ERROR из конца
    if (end_idx >= 2 and std.mem.eql(u8, resp_buf[end_idx - 2 .. end_idx], "OK")) {
        end_idx -= 2;
    }
    if (end_idx >= 5 and std.mem.eql(u8, resp_buf[end_idx - 5 .. end_idx], "ERROR")) {
        end_idx -= 5;
    }

    // Финальная очистка trailing \r\n
    while (end_idx > start_idx and (resp_buf[end_idx - 1] == '\r' or resp_buf[end_idx - 1] == '\n')) : (end_idx -= 1) {}

    const result_len = @min(end_idx - start_idx, buf.len - 1);
    if (result_len > 0) {
        @memcpy(buf[0..result_len], resp_buf[start_idx .. start_idx + result_len]);
    }

    return result_len;
}
// sendAt:end

// Парсить IMSI из AT+CIMI ответа
// parseImsi:start
//   purpose: copy up to 20 bytes of an AT+CIMI response (raw digits, no "+CIMI:" prefix expected) into imsi_buf.
//   input:  resp — the cleaned sendAt() response; imsi_buf — destination.
//   output: number of bytes copied.
//   sideEffects: none (pure).
fn parseImsi(resp: []const u8, imsi_buf: []u8) usize {
    // Ожидаем строку типа: "460069018890123456" (15-18 цифр)
    const len = @min(resp.len, 20);
    if (len > 0) {
        @memcpy(imsi_buf[0..len], resp[0..len]);
    }
    return len;
}
// parseImsi:end

// Парсить статус PIN из AT+CPIN? ответа
// parsePinStatus:start
//   purpose: substring-match the AT+CPIN? response ("READY", "SIM PIN", "SIM PUK", "PH_SIM PIN", ...) to a PinStatus enum value.
//   input:  resp — cleaned AT+CPIN? response.
//   output: the matching PinStatus; .unknown on no match.
//   sideEffects: none (pure).
fn parsePinStatus(resp: []const u8) PinStatus {
    // Ответ формата: "+CPIN: READY" или "+CPIN: SIM PIN" и т.д.
    const trimmed = std.mem.trim(u8, resp, " \r\n\t");

    if (std.mem.indexOf(u8, trimmed, "READY") != null) return .ready;
    if (std.mem.indexOf(u8, trimmed, "SIM PIN2") != null) return .sim_pin2;
    if (std.mem.indexOf(u8, trimmed, "SIM PUK2") != null) return .sim_puk2;
    if (std.mem.indexOf(u8, trimmed, "SIM PIN") != null) return .sim_pin;
    if (std.mem.indexOf(u8, trimmed, "SIM PUK") != null) return .sim_puk;
    if (std.mem.indexOf(u8, trimmed, "PH_SIM PIN") != null) return .phone_pin;
    if (std.mem.indexOf(u8, trimmed, "PH_SIM PUK") != null) return .phone_puk;

    return .unknown;
}
// parsePinStatus:end

// Парсить уровень сигнала из AT+CSQ ответа
// parseSignal:start
//   purpose: parse an AT+CSQ response ("+CSQ: <rssi>,<ber>") into dBm and BER values; CSQ 0..31 maps to -113..-51 dBm, anything else (incl. 99) collapses to -99/99.
//   input:  resp — cleaned AT+CSQ response.
//   output: an anonymous struct {rssi: i8, ber: u8}.
//   sideEffects: none (pure).
fn parseSignal(resp: []const u8) struct { rssi: i8, ber: u8 } {
// parseSignal:end
    // Ответ формата: "+CSQ: 23,0" (rssi, ber)
    const trimmed = std.mem.trim(u8, resp, " \r\n\t");

    var rssi: i8 = -99;
    var ber: u8 = 99;

    // Пропускаем "+CSQ: "
    if (std.mem.indexOf(u8, trimmed, ": ")) |idx| {
        const values = trimmed[idx + 2 ..];
        var val_parts = std.mem.splitSequence(u8, values, ",");

        if (val_parts.next()) |rssi_str| {
            const rssi_val = std.fmt.parseInt(i32, std.mem.trim(u8, rssi_str, " "), 10) catch -99;
            // CSQ возвращает 0-31 (dBm: -113 до -51), 99 = unknown
            if (rssi_val >= 0 and rssi_val <= 31) {
                rssi = @as(i8, @intCast(-113 + (rssi_val * 2)));
            }
        }

        if (val_parts.next()) |ber_str| {
            ber = std.fmt.parseInt(u8, std.mem.trim(u8, ber_str, " "), 10) catch 99;
        }
    }

    return .{ .rssi = rssi, .ber = ber };
}

// Парсить оператора из AT+COPS? ответа
// parseOperator:start
//   purpose: copy the quoted operator name out of "+COPS: 0,0,\"<name>\",0" into op_buf.
//   input:  resp — cleaned AT+COPS? response; op_buf — destination.
//   output: number of bytes written.
//   sideEffects: none (pure).
fn parseOperator(resp: []const u8, op_buf: []u8) usize {
    // Ответ формата: "+COPS: 0,0,"China Mobile",0" или "+COPS: 0,0,"46000",0"
    const trimmed = std.mem.trim(u8, resp, " \r\n\t");

    // Ищем кавычки
    var in_quotes = false;
    var op_pos: usize = 0;

    for (trimmed) |ch| {
        if (ch == '"') {
            if (!in_quotes) {
                in_quotes = true;
            } else {
                break;
            }
        } else if (in_quotes and op_pos < op_buf.len) {
            op_buf[op_pos] = ch;
            op_pos += 1;
        }
    }

    return op_pos;
}
// parseOperator:end

// Парсить статус регистрации из AT+CREG? ответа
// parseRegistration:start
//   purpose: parse "+CREG: <mode>,<status>" — flag registered when status is 1 (home) or 5 (roaming).
//   input:  resp — cleaned AT+CREG? response.
//   output: anonymous struct {registered: bool, status: u8}.
//   sideEffects: none (pure).
fn parseRegistration(resp: []const u8) struct { registered: bool, status: u8 } {
// parseRegistration:end
    // Ответ формата: "+CREG: 1,1" или "+CREG: 1,5" (mode, status)
    // Статусы: 0=not registered, 1=home, 2=searching, 3=denied, 4=unknown, 5=roaming
    const trimmed = std.mem.trim(u8, resp, " \r\n\t");

    var registered = false;
    var status: u8 = 0;

    // Пропускаем "+CREG: "
    if (std.mem.indexOf(u8, trimmed, ": ")) |idx| {
        const values = trimmed[idx + 2 ..];
        var val_parts = std.mem.splitSequence(u8, values, ",");

        _ = val_parts.next(); // пропускаем mode

        if (val_parts.next()) |status_str| {
            const st = std.fmt.parseInt(u8, std.mem.trim(u8, status_str, " "), 10) catch 0;
            status = st;
            registered = (st == 1 or st == 5); // home или roaming
        }
    }

    return .{ .registered = registered, .status = status };
}

// Получить полную информацию о SIM (отправляет 5 AT команд)
// getSimInfo:start
//   purpose: issue 5 AT commands in sequence (CIMI, CPIN?, CSQ, COPS?, CREG?) on fd and assemble a SimInfo (per-field errors leave the corresponding field at its default).
//   input:  fd — open modem (caller still owns the lifetime).
//   output: the assembled SimInfo, never null (always returns the zero-initialised default on total failure).
//   sideEffects: 5 AT round-trips on the modem UART.
pub fn getSimInfo(fd: std.posix.fd_t) ?SimInfo {
    var info = SimInfo{};
    var resp: [AT_BUF_SIZE]u8 = undefined;

    // AT+CIMI → IMSI
    if (sendAt(fd, "AT+CIMI", &resp)) |len| {
        if (len > 0) {
            info.imsi_len = parseImsi(resp[0..len], &info.imsi);
        }
    }

    // AT+CPIN? → PIN status
    if (sendAt(fd, "AT+CPIN?", &resp)) |len| {
        if (len > 0) {
            info.pin_status = parsePinStatus(resp[0..len]);
        }
    }

    // AT+CSQ → signal quality
    if (sendAt(fd, "AT+CSQ", &resp)) |len| {
        if (len > 0) {
            const sig = parseSignal(resp[0..len]);
            info.signal_rssi = sig.rssi;
            info.signal_ber = sig.ber;
        }
    }

    // AT+COPS? → operator
    if (sendAt(fd, "AT+COPS?", &resp)) |len| {
        if (len > 0) {
            info.operator_len = parseOperator(resp[0..len], &info.operator);
        }
    }

    // AT+CREG? → registration status
    if (sendAt(fd, "AT+CREG?", &resp)) |len| {
        if (len > 0) {
            const reg = parseRegistration(resp[0..len]);
            info.registered = reg.registered;
            info.registration_status = reg.status;
        }
    }

    return info;
}
// getSimInfo:end

// Форматировать информацию о SIM в JSON для возврата клиенту
// formatSimInfo:start
//   purpose: hand-assemble a JSON object with the SimInfo fields the broker expects (registered, signal, pin_required, imsi, optional operator + ber) directly into buf.
//   input:  info — SimInfo from getSimInfo; buf — destination scratch buffer (must fit worst case ≈ imsi + operator + 200 B JSON wrapping).
//   output: number of bytes written; emits `{"ok":false,"error":"sim not found"}` if IMSI is empty.
//   sideEffects: none.
pub fn formatSimInfo(info: SimInfo, buf: []u8) usize {
    // Если IMSI пустой — сразу error
    if (info.imsi_len == 0) {
        const msg = "{\"ok\":false,\"error\":\"sim not found\"}";
        const n = @min(msg.len, buf.len);
        @memcpy(buf[0..n], msg[0..n]);
        return n;
    }

    // Форматируем JSON
    // {"ok":true,"value":{"registered":true,"signal":-75,"pin_required":false,"imsi":"460069018890123456"}}
    var pos: usize = 0;

    const prefix = "{\"ok\":true,\"value\":{";
    @memcpy(buf[pos .. pos + prefix.len], prefix);
    pos += prefix.len;

    // "registered":true/false
    const reg_str = if (info.registered) "\"registered\":true," else "\"registered\":false,";
    @memcpy(buf[pos .. pos + reg_str.len], reg_str);
    pos += reg_str.len;

    // "signal":-75,
    const signal_bytes = std.fmt.bufPrintZ(buf[pos..], "\"signal\":{d},", .{info.signal_rssi}) catch buf[0..0];
    pos += signal_bytes.len;

    // "pin_required":false,
    const pin_str = if (info.pin_status != .ready and info.pin_status != .unknown)
        "\"pin_required\":true,"
    else
        "\"pin_required\":false,";
    @memcpy(buf[pos .. pos + pin_str.len], pin_str);
    pos += pin_str.len;

    // "imsi":"460069018890123456"
    const imsi_prefix = "\"imsi\":\"";
    @memcpy(buf[pos .. pos + imsi_prefix.len], imsi_prefix);
    pos += imsi_prefix.len;

    if (info.imsi_len > 0) {
        @memcpy(buf[pos .. pos + info.imsi_len], info.imsi[0..info.imsi_len]);
        pos += info.imsi_len;
    }

    const imsi_suffix = "\"";
    @memcpy(buf[pos .. pos + imsi_suffix.len], imsi_suffix);
    pos += imsi_suffix.len;

    // Опционально: operator, ber
    if (info.operator_len > 0) {
        const op_prefix = ",\"operator\":\"";
        @memcpy(buf[pos .. pos + op_prefix.len], op_prefix);
        pos += op_prefix.len;

        @memcpy(buf[pos .. pos + info.operator_len], info.operator[0..info.operator_len]);
        pos += info.operator_len;

        const op_suffix = "\"";
        @memcpy(buf[pos .. pos + op_suffix.len], op_suffix);
        pos += op_suffix.len;
    }

    if (info.signal_ber < 99) {
        const ber_str = std.fmt.bufPrintZ(buf[pos..], ",\"ber\":{d}", .{info.signal_ber}) catch buf[0..0];
        pos += ber_str.len;
    }

    const suffix = "}}";
    @memcpy(buf[pos .. pos + suffix.len], suffix);
    pos += suffix.len;

    return pos;
}
// formatSimInfo:end
