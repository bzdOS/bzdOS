// START_AI_HEADER
// MODULE: sys-daemon-zig/src/audio_bridge.zig
// PURPOSE: Zero-copy Cap'n Proto AudioPacket reader that streams telephony audio from /var/run/bsdos-audio.sock to /dev/dsp (OSS FreeBSD) — pointer-arithmetic slice into a static 4 KiB buffer, no intermediate copies.
// INTENT: L2-cache-friendly pipeline (4096 B static recv_buf fits Cortex-A53 L2). The CapnpError / OssError types and the AudioPacketView let relay callers skip per-field decoding. Falls back to a no-dsp mode when /dev/dsp is missing (QEMU) so the socket path can still be tested.
// DEPENDENCIES: std (net, fmt, debug), libc via @cImport (sys/stat, sys/soundcard, sys/ioctl, fcntl, unistd).
// PUBLIC_API: AudioPacketView struct, run_audio_bridge() !void (thread entry; spawn from main.zig).
// END_AI_HEADER

// bsdOS Audio Bridge — Cap'n Proto zero-copy → /dev/dsp (OSS FreeBSD).
//
// Pipeline (нет промежуточных копий):
//   Rust telephony.rs
//       → raw capnp bytes → Unix socket /var/run/bsdos-audio.sock
//       → audio_bridge читает в статический буфер
//       → вычисляет offset opusPayload за O(1) (арифметика указателей)
//       → write(dsp_fd, payload_ptr, payload_len)  ← 1 системный вызов
//
// Вся арифметика — на стеке и регистрах. Никакого heap, никакого Allocator.
// Статический буфер 4096 байт влезает в L2-кэш Cortex-A53 (512KB).

const std = @import("std");
const builtin = @import("builtin");

// ── OSS audio через @cImport ──────────────────────────────────────────────────

const c = @cImport({
    @cInclude("sys/stat.h");         // chmod
    @cInclude("sys/soundcard.h");   // OSS: SNDCTL_DSP_*, AFMT_*
    @cInclude("sys/ioctl.h");
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
});

const DSP_PATH = "/dev/dsp";

// ── Cap'n Proto zero-copy reader ──────────────────────────────────────────────
//
// Мы не используем capnp-библиотеку. Вместо этого:
//   1. Читаем сообщение в статический буфер
//   2. Вычисляем offset и длину opusPayload по framing-заголовку
//   3. Возвращаем срез в тот же буфер — zero-copy

const CapnpError = error{ BadMagic, TooLarge, BadPointer };

const AudioPacketView = struct {
    sequence:    u64,
    timestamp:   u32,
    opus_bytes:  []const u8,  // срез в исходном буфере, без копирования
};

// Декодирует AudioPacket из сырых байт. Никаких копий.
// parse_audio_packet:start
//   purpose: validate a 40-byte Cap'n Proto framing header (segment_count=0, dataWords≥2, ptrWords≥1) and return a zero-copy view onto the opusPayload list bytes inside buf — no allocation, the slice is just an offset+length into the input.
//   input:  buf — raw bytes received from the audio socket (≥ 40 B, ≤ BUF_SIZE).
//   output: AudioPacketView on success; CapnpError.TooLarge on < 40 B; CapnpError.BadMagic on segment_count ≠ 0; CapnpError.BadPointer on dataWords/ptrWords/elem_size mismatch.
//   sideEffects: none (pure).
fn parse_audio_packet(buf: []const u8) CapnpError!AudioPacketView {
    if (buf.len < 40) return CapnpError.TooLarge;

    // framing: [0..4] = 0 (1 segment), [4..8] = segment size in words
    const seg_count = read_u32_le(buf[0..4]);
    if (seg_count != 0) return CapnpError.BadMagic;  // ожидаем ровно 1 сегмент

    // root struct pointer [8..16]: bits[32..47]=dataWords=2, bits[48..63]=ptrWords=1
    const data_words = read_u16_le(buf[12..14]);
    const ptr_words  = read_u16_le(buf[14..16]);
    if (data_words < 2 or ptr_words < 1) return CapnpError.BadPointer;

    // Данные struct: [16..32] — sequenceNumber + timestampMs + pad
    const seq = read_u64_le(buf[16..24]);
    const ts  = read_u32_le(buf[24..28]);

    // Pointer section: ptr[0] = list pointer for opusPayload [32..40]
    // List pointer lower 32: (offset << 2) | 1
    // List pointer upper 32: (elem_count << 3) | elem_size_code(BYTE=2)
    const list_ptr_lo = read_u32_le(buf[32..36]);
    const list_ptr_hi = read_u32_le(buf[36..40]);

    if ((list_ptr_lo & 3) != 1) return CapnpError.BadPointer;  // должен быть list ptr

    const offset_words = @as(i32, @bitCast(list_ptr_lo)) >> 2;  // знаковый offset
    const elem_count   = list_ptr_hi >> 3;
    const elem_size    = list_ptr_hi & 7;
    if (elem_size != 2) return CapnpError.BadPointer;  // BYTE = 2

    // Данные начинаются через offset_words * 8 байт от конца list pointer (offset 40)
    const data_start: usize = 40 + @as(usize, @intCast(offset_words)) * 8;
    const data_end = data_start + elem_count;

    if (data_end > buf.len) return CapnpError.TooLarge;

    return AudioPacketView{
        .sequence   = seq,
        .timestamp  = ts,
        .opus_bytes = buf[data_start..data_end],  // срез без копирования
    };
}
// parse_audio_packet:end

// ── Inline helpers для чтения LE-чисел из байтового буфера ───────────────────

inline fn read_u16_le(b: []const u8) u16 {
    return @as(u16, b[0]) | (@as(u16, b[1]) << 8);
}
inline fn read_u32_le(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) |
           (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}
inline fn read_u64_le(b: []const u8) u64 {
    return @as(u64, read_u32_le(b[0..4])) |
           (@as(u64, read_u32_le(b[4..8])) << 32);
}

// ── OSS звуковой выход ────────────────────────────────────────────────────────

const OssError = error{ OpenFailed, IoctlFailed, WriteFailed };

// open_dsp:start
//   purpose: open /dev/dsp O_WRONLY, then SNDCTL_DSP_SETFMT=AFMT_S16_LE, SNDCTL_DSP_CHANNELS=1, SNDCTL_DSP_SPEED=48000 (Opus native rate).
//   input:  none.
//   output: the configured fd on success; OssError.OpenFailed / OssError.IoctlFailed on any step.
//   sideEffects: opens /dev/dsp; configures the kernel-side OSS state.
fn open_dsp() OssError!c_int {
    const fd = c.open(DSP_PATH, c.O_WRONLY, @as(c_int, 0));
    if (fd < 0) return OssError.OpenFailed;

    // Настройка для Opus декодированного выхода (16-bit, mono, 48kHz)
    // TODO: Opus decoder → PCM перед записью в DSP (сейчас пишем raw для прототипа)
    var fmt: c_int = c.AFMT_S16_LE;
    if (c.ioctl(fd, c.SNDCTL_DSP_SETFMT, &fmt) < 0) {
        _ = c.close(fd);
        return OssError.IoctlFailed;
    }

    var channels: c_int = 1;  // моно
    if (c.ioctl(fd, c.SNDCTL_DSP_CHANNELS, &channels) < 0) {
        _ = c.close(fd);
        return OssError.IoctlFailed;
    }

    var rate: c_int = 48000;  // Opus native rate
    if (c.ioctl(fd, c.SNDCTL_DSP_SPEED, &rate) < 0) {
        _ = c.close(fd);
        return OssError.IoctlFailed;
    }

    return fd;
}
// open_dsp:end

// Zero-copy write: пишем срез прямо из входного буфера, без промежуточной копии
// write_to_dsp:start
//   purpose: write a single zero-copy slice of the receive buffer (the opusPayload from parse_audio_packet) to the dsp fd.
//   input:  dsp_fd — open /dev/dsp fd; opus_bytes — slice returned by parse_audio_packet (must point into the same recv_buf the caller owns).
//   output: void; OssError.WriteFailed on negative write() return.
//   sideEffects: one write(2) on the dsp fd; no allocation, no copy.
fn write_to_dsp(dsp_fd: c_int, opus_bytes: []const u8) OssError!void {
    const written = c.write(dsp_fd, opus_bytes.ptr, opus_bytes.len);
    if (written < 0) return OssError.WriteFailed;
}
// write_to_dsp:end

// read_exact: читать ровно buf.len байт (заменяет readAll которого нет в Zig 0.15 net.Stream)
// read_exact:start
//   purpose: read exactly buf.len bytes from stream (handles short reads and signals error.EndOfStream on premature EOF — std.net.Stream.read in Zig 0.15 has no readAll).
//   input:  stream — open Unix socket; buf — destination buffer.
//   output: void; any underlying stream.read error propagates.
//   sideEffects: blocks reading from stream.
fn read_exact(stream: std.net.Stream, buf: []u8) !void {
    var total: usize = 0;
    while (total < buf.len) {
        const n = try stream.read(buf[total..]);
        if (n == 0) return error.EndOfStream;
        total += n;
    }
}
// read_exact:end

// ── Главный цикл ──────────────────────────────────────────────────────────────

const SOCK_PATH = "/var/run/bsdos-audio.sock";
const BUF_SIZE  = 4096;  // влезает в L2-кэш A64 (512KB); хватает для Opus фрейма (~1500 байт)

// Статический буфер — на стеке модуля, нет heap
var recv_buf: [BUF_SIZE]u8 = undefined;

// run_audio_bridge:start
//   purpose: main audio-bridge loop — open /dev/dsp once, bind /var/run/bsdos-audio.sock, accept connections, read 4-byte length-prefixed Cap'n Proto frames, parse with parse_audio_packet, and write the opus slice to the dsp (zero copy).
//   input:  none (thread entry — spawn with std.Thread).
//   output: never returns; only fails on listen() / chmod() at startup, in which case it falls through to run_audio_bridge_nodsp when /dev/dsp is missing.
//   sideEffects: opens /dev/dsp + /var/run/bsdos-audio.sock; per-connection alloc/release; one write per frame to the dsp fd.
pub fn run_audio_bridge() !void {
    // Открыть DSP один раз — держим fd на всё время работы
    const dsp_fd = open_dsp() catch |err| {
        std.debug.print("[audio] DSP open failed: {} (QEMU: no dsp, skip)\n", .{err});
        // В QEMU нет /dev/dsp — продолжаем без аудио для тестирования пайплайна
        return run_audio_bridge_nodsp();
    };
    defer _ = c.close(dsp_fd);
    std.debug.print("[audio] {s} opened, waiting on {s}\n", .{ DSP_PATH, SOCK_PATH });

    // Unix socket сервер
    std.fs.deleteFileAbsolute(SOCK_PATH) catch {};
    const addr   = try std.net.Address.initUnix(SOCK_PATH);
    var  server  = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    _ = c.chmod(SOCK_PATH, 0o777);

    while (true) {
        const conn = try server.accept();
        defer conn.stream.close();

        // Читаем длину пакета (4 байта prefixed-length)
        var len_buf: [4]u8 = undefined;
        read_exact(conn.stream, &len_buf) catch continue;
        const pkt_len = read_u32_le(&len_buf);
        if (pkt_len == 0 or pkt_len > BUF_SIZE) continue;

        // Читаем capnp payload в статический буфер
        read_exact(conn.stream, recv_buf[0..pkt_len]) catch continue;

        // Zero-copy parse: получаем срез на opusPayload внутри recv_buf
        const pkt = parse_audio_packet(recv_buf[0..pkt_len]) catch |err| {
            std.debug.print("[audio] capnp parse err: {}\n", .{err});
            continue;
        };

        std.debug.print("[audio] seq={d} ts={d}ms opus={d}bytes\n",
            .{ pkt.sequence, pkt.timestamp, pkt.opus_bytes.len });

        // write(dsp_fd, pkt.opus_bytes) — 1 системный вызов, 0 копий
        write_to_dsp(dsp_fd, pkt.opus_bytes) catch |err| {
            std.debug.print("[audio] dsp write err: {}\n", .{err});
        };
    }
}
// run_audio_bridge:end

// Версия без DSP — для тестирования в QEMU (просто дропаем данные с логом)
// run_audio_bridge_nodsp:start
//   purpose: QEMU-only fallback — same socket/parse loop as run_audio_bridge but logs and drops each frame (no /dev/dsp on the host).
//   input:  none.
//   output: never returns.
//   sideEffects: opens /var/run/bsdos-audio.sock; writes to stderr per frame.
fn run_audio_bridge_nodsp() !void {
    std.fs.deleteFileAbsolute(SOCK_PATH) catch {};
    const addr  = try std.net.Address.initUnix(SOCK_PATH);
    var  server = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    _ = c.chmod(SOCK_PATH, 0o777);
    std.debug.print("[audio] no-dsp mode (QEMU), socket ready at {s}\n", .{SOCK_PATH});

    while (true) {
        const conn = try server.accept();
        defer conn.stream.close();
        var len_buf: [4]u8 = undefined;
        read_exact(conn.stream, &len_buf) catch continue;
        const pkt_len = read_u32_le(&len_buf);
        if (pkt_len == 0 or pkt_len > BUF_SIZE) continue;
        read_exact(conn.stream, recv_buf[0..pkt_len]) catch continue;
        const pkt = parse_audio_packet(recv_buf[0..pkt_len]) catch continue;
        std.debug.print("[audio] seq={d} opus={d}b (no-dsp drop)\n",
            .{ pkt.sequence, pkt.opus_bytes.len });
    }
}
// run_audio_bridge_nodsp:end
