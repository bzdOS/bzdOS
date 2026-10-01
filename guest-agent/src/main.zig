// START_AI_HEADER
// MODULE: guest-agent/src/main.zig
// PURPOSE: bsdOS Guest Agent — text-protocol RPC dispatcher over virtio-console or unix socket.
// INTENT: SSH-free guest control from QEMU host; single Zig file, no deps beyond libc.
// DEPENDENCIES: @import("std"), C headers: fcntl.h poll.h termios.h unistd.h
// PUBLIC_API: main()
// PROTOCOL: "CMD [ARG]\n" → "+OK msg\n[lines]\n.\n" | "-ERR msg\n[lines]\n.\n"
// TRANSPORT: chardev /dev/ttyV1.1 (primary, virtio-serial vser-agent slot 1)
//            unix   /var/run/bsdos-agent.sock (fallback, in-guest only)
// END_AI_HEADER

// bsdOS Guest Agent — text protocol, virtio-console transport.
//
// Транспорты (BSDOS_AGENT_TRANSPORT env):
//   auto     — chardev если устройство открывается, иначе unix (default)
//   chardev  — только /dev/ttyV* (принудительно)
//   unix     — только unix socket (dev/test)
//
// Протокол:
//   Запрос:         CMD [ARG]\n
//   Ответ OK:       +OK [msg]\n[lines\n]*.\n
//   Ответ ERR:      -ERR [msg]\n[lines\n]*.\n
//   EXEC_STREAM:    +OK streaming\n[lines as they arrive]\n.\n
//
// Команды: PING STATUS HELLO EXEC EXEC_BG EXEC_STREAM PUT GET
//          JOB_RUN JOB_LOG JOB_STATUS JOB_LIST JOB_KILL JOB_GC
//          JLS JAIL_SETUP JAIL_TEARDOWN FREEZE THAW
//          MEM_STATUS MEM_GUARD HAL_START BROKER_START LIFECYCLE_START
//          BUILD_BROKER BUILD_APP WAYLAND_STATUS WAYLAND_START RESIZE
//
// File transfer (binary-safe, length-prefixed raw payload — see "File transfer" below):
//   PUT <size> <path>\n<bytes>  host→guest  (+OK ready <chunk> → ACK-paced chunks → +OK <n>)
//   GET <path>\n                guest→host  (+OK <size>\n + streamed raw bytes)
//
// proto-v2 (additive, backward-compatible): HELLO reports "proto=2"; JOB_RUN/JOB_LOG
// keep their v1 happy-path behaviour unchanged. JOB_STATUS/JOB_LIST/JOB_KILL/JOB_GC
// are new out-of-band job-lifecycle verbs backed by a fixed job_table (see below).
// PUT/GET are additive file-transfer verbs; older callers simply never send them.

const std = @import("std");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("poll.h");
    @cInclude("sys/file.h");
    @cInclude("termios.h");
    @cInclude("unistd.h");
});

const VERSION         = "0.5.1";
const CHARDEV_DEFAULT = "/dev/ttyV1.1";
const UNIX_SOCK       = "/var/run/bsdos-agent.sock";
const LOCK_FILE       = "/var/run/bsdos-agent.lock";
const MAX_RESP        = 512 * 1024; // 512 KB response buffer
const MAX_LINE        = 4096;       // max incoming command length
const CAPTURE_BUF     = 64 * 1024; // captured stdout per EXEC call
const CMD_TIMEOUT_MS  = 30_000;    // max wall-clock seconds for any EXEC/EXEC_STREAM command (configurable via BSDOS_CMD_TIMEOUT_MS env)

const PROTO        = 2;     // wire protocol version reported by HELLO (proto-v2)
const JOB_CAP       = 32;   // max concurrently tracked jobs (job_table slot count)
const JOB_ID_MAX    = 32;   // max bytes stored per job id; JOB_RUN rejects longer ids
const JOB_CMD_BUF   = 4096; // job_run wrapper buffer (was 512 — root cause of silent drops)
const JOB_LIST_BUF  = 4096; // scratch buffer for JOB_LIST body lines

// child_alloc: libc malloc/free; avoids page_allocator page-granularity waste per spawn.
const child_alloc = std.heap.c_allocator;

// ── Subprocess helpers ────────────────────────────────────────────────────────

// spawn_bg:start
//   purpose: Spawn a detached background process (fire-and-forget).
//   input:  argv — null-terminated command + args slice
//   output: void; spawn errors silently discarded
//   sideEffects: creates a child process; argv allocation leaks (no wait)
fn spawn_bg(argv: []const []const u8) void {
    var ch = std.process.Child.init(argv, child_alloc);
    ch.spawn() catch {};
}
// spawn_bg:end

const Capture = struct { ok: bool, buf: [CAPTURE_BUF]u8, len: usize };

// run_capture:start
//   purpose: Run a command to completion and capture stdout (up to CAPTURE_BUF).
//            Has a watchdog timer (CMD_TIMEOUT_MS) that kills the child if it hangs
//            — a single stuck EXEC can never block the agent's dispatch loop forever.
//   input:  argv — command and arguments; stderr is discarded to avoid pipe-deadlock
//   output: Capture{ok, buf[0..len]}; buf ends with "\n[TRUNCATED]\n" if output was clipped;
//           timed-out commands return ok=false with "[TIMEOUT]" appended
//   sideEffects: spawns and waits for child process; SIGCHLD delivered; may SIGKILL child
fn run_capture(argv: []const []const u8) Capture {
    var r = Capture{ .ok = false, .buf = undefined, .len = 0 };
    var ch = std.process.Child.init(argv, child_alloc);
    ch.stdout_behavior = .Pipe;
    // Ignore stderr: if we piped it and didn't drain it, a chatty child would fill the
    // kernel pipe buffer and block, causing run_capture to hang on the stdout read.
    ch.stderr_behavior = .Ignore;
    ch.spawn() catch return r;

    const env_timeout = std.posix.getenv("BSDOS_CMD_TIMEOUT_MS");
    const timeout_ms: u64 = if (env_timeout) |val| (std.fmt.parseInt(u64, val, 10) catch CMD_TIMEOUT_MS) else CMD_TIMEOUT_MS;
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    var timed_out = false;

    if (ch.stdout) |out| {
        const fd = out.handle;
        var poll_fd = c.struct_pollfd{ .fd = fd, .events = @intCast(c.POLLIN), .revents = 0 };
        while (r.len < r.buf.len) {
            const remaining = deadline - std.time.milliTimestamp();
            if (remaining <= 0) {
                timed_out = true;
                break;
            }
            poll_fd.revents = 0;
            const poll_ms = if (remaining > 1000) @as(i32, 1000) else @as(i32, @intCast(remaining));
            const pret = c.poll(&poll_fd, 1, poll_ms);
            if (pret == 0) continue; // per-chunk timeout — check deadline
            if (pret < 0) break;     // poll error — bail
            const n = out.read(r.buf[r.len..]) catch break;
            if (n == 0) break;
            r.len += n;
        }
        // Non-blocking drain of any leftover data after the buffer filled.
        var drain: [512]u8 = undefined;
        var truncated = false;
        poll_fd.revents = 0;
        while (c.poll(&poll_fd, 1, 0) > 0) {
            const n = out.read(&drain) catch break;
            if (n == 0) break;
            truncated = true;
        }
        out.close();
        if (truncated) {
            const m = "\n[TRUNCATED]\n";
            if (r.len + m.len <= r.buf.len) {
                @memcpy(r.buf[r.len..][0..m.len], m);
                r.len += m.len;
            }
        }
        if (timed_out) {
            _ = ch.kill() catch {};
            const m = "[TIMEOUT]\n";
            if (r.len + m.len <= r.buf.len) {
                @memcpy(r.buf[r.len..][0..m.len], m);
                r.len += m.len;
            }
        }
    }
    const term = ch.wait() catch return r;
    r.ok = switch (term) {
        .Exited => |code| code == 0,
        else    => false,
    };
    return r;
}
// run_capture:end

// ── Response formatting ───────────────────────────────────────────────────────

// write_resp:start
//   purpose: Serialise a protocol response into buf: "+OK"/"-ERR" header, body lines, ".\n" terminator.
//   input:  buf — destination; ok — success flag; msg — header message (may be ""); body — optional payload
//   output: usize — bytes written; writes are silently dropped if buf is too small
//   sideEffects: none
fn write_resp(buf: []u8, ok: bool, msg: []const u8, body: []const u8) usize {
    var w = std.io.fixedBufferStream(buf);
    const wr = w.writer();
    if (msg.len > 0) {
        if (ok) wr.print("+OK {s}\n", .{msg}) catch {}
        else    wr.print("-ERR {s}\n", .{msg}) catch {};
    } else {
        wr.writeAll(if (ok) "+OK\n" else "-ERR\n") catch {};
    }
    if (body.len > 0) {
        wr.writeAll(body) catch {};
        if (body[body.len - 1] != '\n') wr.writeByte('\n') catch {};
    }
    wr.writeAll(".\n") catch {};
    return w.pos;
}
// write_resp:end

// resp_ok:start
//   purpose: Emit "+OK msg\n.\n" into buf.
//   input:  buf — destination; msg — status message
//   output: usize bytes written
//   sideEffects: none
fn resp_ok(buf: []u8, msg: []const u8) usize {
    return write_resp(buf, true, msg, "");
}
// resp_ok:end

// resp_capture:start
//   purpose: Emit a Capture result as a protocol response.
//   input:  buf — destination; cap — Capture from run_capture
//   output: usize bytes written; status line is exit code "0" or "1"
//   sideEffects: none
fn resp_capture(buf: []u8, cap: Capture) usize {
    return write_resp(buf, cap.ok, if (cap.ok) "0" else "1", cap.buf[0..cap.len]);
}
// resp_capture:end

// ── Transport selector ────────────────────────────────────────────────────────

const StreamMode = enum { chardev, unix };

// fd_write:start
//   purpose: Write bytes to a transport fd using the appropriate write strategy.
//   input:  fd — file descriptor; data — bytes; mode — chardev (O_NONBLOCK) or unix (blocking)
//   output: void
//   sideEffects: writes to fd; chardev_write may drop bytes on EAGAIN
fn fd_write(fd: std.posix.fd_t, data: []const u8, mode: StreamMode) void {
    if (mode == .chardev) chardev_write(fd, data)
    else _ = std.posix.write(fd, data) catch {};
}
// fd_write:end

// ── EXEC_STREAM ───────────────────────────────────────────────────────────────

// exec_stream:start
//   purpose: Run shell command, forward each stdout+stderr line to fd as it arrives.
//            Has a watchdog timer (CMD_TIMEOUT_MS) that kills the child if it hangs
//            — a single stuck EXEC_STREAM can never block the agent's dispatch loop forever.
//   input:  cmd — shell command string; stderr merged via "cmd 2>&1" wrapper;
//           fd — transport fd; mode — chardev or unix
//   output: void; writes "+OK streaming\n[lines]\n.\n" directly to fd; timed-out streams
//           get "-ERR command timed out\n.\n" instead of the normal ".\n"
//   sideEffects: spawns child process; blocks caller until child exits; may SIGKILL child
fn exec_stream(cmd: []const u8, fd: std.posix.fd_t, mode: StreamMode) void {
    fd_write(fd, "+OK streaming\n", mode);

    // Merge stderr into stdout at the shell level so the caller sees error messages.
    var wrapper: [MAX_LINE + 8]u8 = undefined;
    const sh_cmd = std.fmt.bufPrint(&wrapper, "{s} 2>&1", .{cmd}) catch cmd;

    var ch = std.process.Child.init(&.{ "sh", "-c", sh_cmd }, child_alloc);
    ch.stdout_behavior = .Pipe;
    ch.stderr_behavior = .Ignore; // already merged above
    ch.spawn() catch {
        fd_write(fd, "-ERR spawn\n.\n", mode);
        return;
    };

    const env_timeout = std.posix.getenv("BSDOS_CMD_TIMEOUT_MS");
    const timeout_ms: u64 = if (env_timeout) |val| (std.fmt.parseInt(u64, val, 10) catch CMD_TIMEOUT_MS) else CMD_TIMEOUT_MS;
    const deadline = std.time.milliTimestamp() + @as(i64, @intCast(timeout_ms));
    var timed_out = false;

    // Line-buffer: forward each complete line immediately.
    var line: [4096]u8 = undefined;
    var lpos: usize = 0;
    if (ch.stdout) |out| {
        const out_fd = out.handle;
        var chunk: [4096]u8 = undefined;
        var poll_fd = c.struct_pollfd{ .fd = out_fd, .events = @intCast(c.POLLIN), .revents = 0 };
        while (true) {
            const remaining = deadline - std.time.milliTimestamp();
            if (remaining <= 0) {
                timed_out = true;
                break;
            }
            poll_fd.revents = 0;
            const poll_ms = if (remaining > 1000) @as(i32, 1000) else @as(i32, @intCast(remaining));
            const pret = c.poll(&poll_fd, 1, poll_ms);
            if (pret == 0) continue; // per-chunk timeout — check deadline
            if (pret < 0) break;     // poll error — bail
            const n = out.read(&chunk) catch break;
            if (n == 0) break;
            for (chunk[0..n]) |b| {
                if (b == '\n') {
                    line[lpos] = '\n';
                    fd_write(fd, line[0..lpos + 1], mode);
                    lpos = 0;
                } else if (lpos < line.len - 1) {
                    line[lpos] = b;
                    lpos += 1;
                }
            }
        }
        if (lpos > 0) {
            line[lpos] = '\n';
            fd_write(fd, line[0..lpos + 1], mode);
        }
        out.close();
        if (timed_out) {
            _ = ch.kill() catch {};
        }
    }
    _ = ch.wait() catch {};
    if (timed_out) {
        fd_write(fd, "-ERR command timed out\n.\n", mode);
    } else {
        fd_write(fd, ".\n", mode);
    }
}
// exec_stream:end

// ── File transfer (proto-v2 additive: PUT / GET) ──────────────────────────────
//
// Binary-safe file transfer over the same line transport. The command header is a
// normal newline-terminated line; the payload is length-prefixed RAW bytes (no
// base64 — no size blow-up, no escaping). Both chardev_loop and unix_loop read
// byte-by-byte and dispatch exactly at '\n', consuming nothing past it, so a PUT/GET
// handler can read/write the raw payload straight off `fd` right after the header.
//
//   PUT <size> <path>\n            host→guest. Agent validates+opens, replies
//     +OK ready <chunk>\n.\n        "ready" advertising the flow-control window, then
//     [ <=chunk raw bytes          the client sends the payload in <=chunk pieces,
//       +OK <recvd>\n.\n ]*         each ACKed before the next (the tty INPUT queue is
//                                  small + has no flow control; the final ACK carries
//     (-ERR ...\n.\n on failure)   recvd==size). size-first lets <path> hold spaces; the
//                                  ready-ack means a rejected PUT leaves no stray payload.
//   GET <path>\n                   guest→host.
//     +OK <size>\n                 header (NO ".\n"), then the file streamed verbatim.
//     <size> raw bytes             The host MUST read continuously to completion (our
//                                  vport-client does) so QEMU keeps the ring drained; a
//     -ERR <reason>\n.\n           host that stalls mid-stream can wedge the guest write
//                                  (virtio-console driver limit). On failure: framed, no payload.
//
// These helpers use their OWN reliable send/recv (re-poll on EAGAIN) rather than
// chardev_write, which deliberately DROPS bytes on a stalled ring — fine for a text
// line, corrupting for a binary file.

const MAX_XFER     = 256 * 1024 * 1024; // 256 MB hard cap per PUT/GET (runaway guard)
const XFER_CHUNK   = 64 * 1024;         // per-iteration read/write chunk
const XFER_POLL_MS = 15_000;            // per-chunk poll timeout — abort a stalled transfer
const PUT_CHUNK    = 1024;              // PUT flow-control window. The virtio-console tty
                                        // INPUT queue (~2 KB, measured on dev-vm) has NO flow
                                        // control — a burst past it silently DROPS bytes. So
                                        // the client sends at most this many bytes per ACK;
                                        // the guest drains + ACKs each before the next arrives.
                                        // (The GET/output direction self-paces via POLLOUT.)

// xfer_send_all:start
//   purpose: Write ALL bytes to a transport fd, re-polling POLLOUT on EAGAIN so nothing
//            is dropped (the reliable counterpart to chardev_write, for file payloads).
//   input:  fd — transport fd (chardev O_NONBLOCK or unix blocking); data — bytes
//   output: true iff every byte was written; false on poll timeout / write error (abort)
//   sideEffects: writes to fd
fn xfer_send_all(fd: std.posix.fd_t, data: []const u8) bool {
    var sent: usize = 0;
    while (sent < data.len) {
        var wpfd = c.struct_pollfd{ .fd = fd, .events = @intCast(c.POLLOUT), .revents = 0 };
        if (c.poll(&wpfd, 1, XFER_POLL_MS) <= 0) return false; // stalled — abort transfer
        // Peer gone: abort rather than wedge in vtcon_tty_outwakeup (see chardev_write).
        if ((wpfd.revents & @as(c_short, @intCast(c.POLLHUP | c.POLLERR | c.POLLNVAL))) != 0) return false;
        const n = std.posix.write(fd, data[sent..]) catch |e| {
            if (e == error.WouldBlock) continue; // ring momentarily full — re-poll, don't drop
            return false;
        };
        if (n == 0) return false;
        sent += n;
    }
    return true;
}
// xfer_send_all:end

// xfer_recv_to_file:start
//   purpose: Read exactly `size` bytes from fd, streaming them into `file`. Polls POLLIN
//            and retries on EAGAIN so an O_NONBLOCK chardev transfer never loses payload.
//   input:  fd — transport fd; file — open, writable, truncated; size — expected byte count
//   output: true iff all `size` bytes were received and written; false on timeout/EOF/write err
//   sideEffects: consumes `size` bytes from fd; writes them to file
fn xfer_recv_to_file(fd: std.posix.fd_t, file: std.fs.File, size: u64) bool {
    var buf: [XFER_CHUNK]u8 = undefined;
    var remaining: u64 = size;
    while (remaining > 0) {
        var rpfd = c.struct_pollfd{ .fd = fd, .events = @intCast(c.POLLIN), .revents = 0 };
        if (c.poll(&rpfd, 1, XFER_POLL_MS) <= 0) return false; // stalled — abort
        const want: usize = @intCast(@min(remaining, @as(u64, buf.len)));
        const n = std.posix.read(fd, buf[0..want]) catch |e| {
            if (e == error.WouldBlock) continue; // no data yet — re-poll
            return false;
        };
        if (n == 0) return false; // EOF before the full payload arrived
        file.writeAll(buf[0..n]) catch return false;
        remaining -= n;
    }
    return true;
}
// xfer_recv_to_file:end

// xfer_send_file:start
//   purpose: Stream exactly `size` bytes of `file` to fd. The OUTPUT direction is safe to
//            STREAM (unlike PUT's input): as long as the host keeps draining, QEMU keeps
//            the virtio ring drained and xfer_send_all's writes make progress. It must NOT
//            be ACK-gated — pausing for ACKs breaks the host's continuous drain, the ring
//            backs up between pieces, and a write then wedges in vtcon_tty_outwakeup even
//            though poll(POLLOUT) (which reflects the tty queue, not the ring) says writable.
//   input:  fd; file — open at 0; size — bytes to send
//   output: true iff all bytes sent; false on read/short-file/send failure
//   sideEffects: reads file; writes payload to fd
//   CAVEAT: if the host STOPS draining mid-stream (a client that crashes/RSTs, not our
//           robust vport-client which always reads to completion), a write can wedge
//           unkillably in the FreeBSD virtio-console driver. That is a kernel-driver limit
//           with no userland cure (poll(POLLOUT) can't predict it); our tooling never does it.
fn xfer_send_file(fd: std.posix.fd_t, file: std.fs.File, size: u64) bool {
    var buf: [XFER_CHUNK]u8 = undefined;
    var remaining: u64 = size;
    while (remaining > 0) {
        const want: usize = @intCast(@min(remaining, @as(u64, buf.len)));
        const n = file.read(buf[0..want]) catch return false;
        if (n == 0) return false; // file shrank under us
        if (!xfer_send_all(fd, buf[0..n])) return false;
        remaining -= @intCast(n);
    }
    return true;
}
// xfer_send_file:end

// ── Job tracker ───────────────────────────────────────────────────────────────
//
// proto-v2 job table: a fixed array (no allocation) tracking background jobs started via
// JOB_RUN, so JOB_STATUS/JOB_LIST/JOB_KILL/JOB_GC can report real exit status out-of-band
// instead of the host having to scrape a "__RC__:" marker from the log tail.
//
// Concurrency: main() may run chardev_loop() on the main thread AND unix_loop() on a
// background thread simultaneously (BSDOS_AGENT_TRANSPORT=auto, the default, when the
// chardev path exists). Both call dispatch(), so job_table is the first piece of mutable
// state shared across threads in this file — every access goes through job_mutex.

const JobState = enum { none, running, exited, killed };

const Job = struct {
    id:      [JOB_ID_MAX]u8 = [_]u8{0} ** JOB_ID_MAX,
    id_len:  usize          = 0,
    pid:     std.posix.pid_t = 0,
    state:   JobState        = .none,
    rc:      i32             = 0,  // exit code (exited) or signal number (killed)
    started: i64             = 0,  // std.time.timestamp() at JOB_RUN
};

const JobError = error{ CmdTooLong, JobTableFull, SpawnFailed };

var job_mutex: std.Thread.Mutex = .{};
var job_table: [JOB_CAP]Job = [_]Job{Job{}} ** JOB_CAP;

// reap:start
//   purpose: Non-blocking wait on every `running` job; promotes finished ones to exited/killed.
//   input:  none
//   output: void
//   sideEffects: waitpid(WNOHANG) on tracked pids (reaps zombies); mutates job_table under job_mutex
fn reap() void {
    job_mutex.lock();
    defer job_mutex.unlock();
    for (&job_table) |*j| {
        if (j.state != .running) continue;
        const r = std.posix.waitpid(j.pid, std.posix.W.NOHANG);
        if (r.pid == 0) continue; // still running
        if (std.posix.W.IFEXITED(r.status)) {
            j.state = .exited;
            j.rc = std.posix.W.EXITSTATUS(r.status);
        } else if (std.posix.W.IFSIGNALED(r.status)) {
            j.state = .killed;
            j.rc = @intCast(std.posix.W.TERMSIG(r.status));
        }
        // else: stopped/continued — shouldn't happen without WUNTRACED/WCONTINUED; leave running.
    }
}
// reap:end

// find_job:start
//   purpose: Look up a job-table slot by id string.
//   input:  id — job identifier to match (any length; never matches if it exceeds JOB_ID_MAX)
//   output: pointer to the matching slot, or null if no live (non-`.none`) slot has this id
//   sideEffects: none
//   precondition: caller holds job_mutex
fn find_job(id: []const u8) ?*Job {
    for (&job_table) |*j| {
        if (j.state == .none) continue;
        if (std.mem.eql(u8, j.id[0..j.id_len], id)) return j;
    }
    return null;
}
// find_job:end

// job_run:start
//   purpose: Start a named background job; stdout+stderr logged to /tmp/bsdos-job-<id>.log;
//            register the child pid in job_table so it can be polled/killed/reaped later.
//   input:  id — job identifier, caller-validated to fit JOB_ID_MAX; cmd — shell command
//   output: JobError!void — error.CmdTooLong if the wrapped command overflows JOB_CMD_BUF,
//           error.JobTableFull if every slot is `running`, error.SpawnFailed if spawn/exec failed
//   sideEffects: spawns a child process; creates /tmp/bsdos-job-<id>.log; mutates job_table
//
// Slot allocation and spawn happen inside one job_mutex critical section: if we spawned first
// and the table turned out full, we'd have an untracked orphan process (a zombie forever,
// since nothing would ever waitpid it) — exactly the kind of silent failure this file is
// being fixed to avoid. Finding the slot before spawning means a full table fails closed.
fn job_run(id: []const u8, cmd: []const u8) JobError!void {
    var wrapper: [JOB_CMD_BUF]u8 = undefined;
    const sh = std.fmt.bufPrint(&wrapper, "{s} >/tmp/bsdos-job-{s}.log 2>&1", .{ cmd, id })
        catch return error.CmdTooLong;

    job_mutex.lock();
    defer job_mutex.unlock();

    const slot = for (&job_table) |*j| {
        if (j.state != .running) break j;
    } else return error.JobTableFull;

    var ch = std.process.Child.init(&.{ "sh", "-c", sh }, child_alloc);
    ch.spawn() catch return error.SpawnFailed;
    // Blocks only until the child execs (or fails to) — microseconds — and closes the
    // Child's internal error-reporting pipe. Without this call that fd leaks forever, since
    // we deliberately never call ch.wait() (reap() owns this job's exit status from here on).
    ch.waitForSpawn() catch return error.SpawnFailed;

    slot.* = .{
        .id_len  = id.len,
        .pid     = ch.id,
        .state   = .running,
        .rc      = 0,
        .started = std.time.timestamp(),
    };
    @memcpy(slot.id[0..id.len], id);
}
// job_run:end

// ── Command dispatch ──────────────────────────────────────────────────────────

// dispatch:start
//   purpose: Parse one command line and invoke the matching handler.
//   input:  line — raw input bytes (no newline); resp — response buffer;
//           fd — transport fd (for EXEC_STREAM direct writes); mode — transport type
//   output: usize bytes written to resp; 0 if EXEC_STREAM handled fd directly
//   sideEffects: may spawn/wait children, read/write files
fn dispatch(line: []const u8, resp: []u8, fd: std.posix.fd_t, mode: StreamMode) usize {
    const t    = std.mem.trim(u8, line, " \t\r\n");
    var  it    = std.mem.splitScalar(u8, t, ' ');
    const cmd  = it.next() orelse return resp_ok(resp, "empty");
    const arg  = it.next();
    const rest: []const u8 = if (cmd.len < t.len) t[cmd.len + 1..] else "";

    // ── Core ──────────────────────────────────────────────────────────────────
    if (std.mem.eql(u8, cmd, "PING"))         return resp_ok(resp, "PONG");
    if (std.mem.eql(u8, cmd, "STATUS"))       return resp_ok(resp, "alive");
    if (std.mem.eql(u8, cmd, "HELLO")) {
        var used: usize = 0;
        job_mutex.lock();
        for (job_table) |j| { if (j.state == .running) used += 1; }
        job_mutex.unlock();
        var msg: [64]u8 = undefined;
        const m = std.fmt.bufPrint(&msg, "bsdos-agent proto={d} jobs={d}/{d}", .{ PROTO, used, JOB_CAP })
            catch return write_resp(resp, false, "internal", "");
        return resp_ok(resp, m);
    }

    if (std.mem.eql(u8, cmd, "EXEC")) {
        if (rest.len == 0) return write_resp(resp, false, "missing cmd", "");
        return resp_capture(resp, run_capture(&.{ "sh", "-c", rest }));
    }
    if (std.mem.eql(u8, cmd, "EXEC_BG")) {
        if (rest.len == 0) return write_resp(resp, false, "missing cmd", "");
        spawn_bg(&.{ "sh", "-c", rest });
        return resp_ok(resp, "background");
    }
    if (std.mem.eql(u8, cmd, "EXEC_STREAM")) {
        if (rest.len == 0) return write_resp(resp, false, "missing cmd", "");
        exec_stream(rest, fd, mode);
        return 0;
    }

    // ── File transfer (writes control + payload straight to fd; returns 0) ──────
    if (std.mem.eql(u8, cmd, "PUT")) {
        // PUT <size> <path>\n<size raw bytes> — size first so <path> may contain spaces.
        const size_s = arg orelse { _ = xfer_send_all(fd, "-ERR missing size\n.\n"); return 0; };
        const size = std.fmt.parseInt(u64, size_s, 10) catch {
            _ = xfer_send_all(fd, "-ERR bad size (want: PUT <size> <path>)\n.\n");
            return 0;
        };
        const path = std.mem.trim(u8, rest[@min(size_s.len, rest.len)..], " ");
        if (path.len == 0) { _ = xfer_send_all(fd, "-ERR missing path\n.\n"); return 0; }
        if (size > MAX_XFER) { _ = xfer_send_all(fd, "-ERR too-large\n.\n"); return 0; }
        // Reject (no ready-ack) BEFORE the client streams payload, so the wire stays synced.
        const file = std.fs.createFileAbsolute(path, .{ .truncate = true }) catch |e| {
            var eb: [160]u8 = undefined;
            const m = std.fmt.bufPrint(&eb, "-ERR open ({s})\n.\n", .{@errorName(e)}) catch "-ERR open\n.\n";
            _ = xfer_send_all(fd, m);
            return 0;
        };
        // ready-ack advertises the PUT_CHUNK window the client must pace to (flow control).
        var rb: [48]u8 = undefined;
        const rmsg = std.fmt.bufPrint(&rb, "+OK ready {d}\n.\n", .{PUT_CHUNK}) catch "+OK ready 1024\n.\n";
        if (!xfer_send_all(fd, rmsg)) { file.close(); return 0; }
        var received: u64 = 0;
        var okall = true;
        while (received < size) {
            const want = @min(size - received, @as(u64, PUT_CHUNK));
            if (!xfer_recv_to_file(fd, file, want)) { okall = false; break; }
            received += want;
            // ACK each chunk: this is the flow-control gate (client waits for it before
            // sending the next chunk) AND the progress/completion signal — the final ACK
            // carries received==size.
            var ab: [48]u8 = undefined;
            const amsg = std.fmt.bufPrint(&ab, "+OK {d}\n.\n", .{received}) catch "+OK\n.\n";
            if (!xfer_send_all(fd, amsg)) { okall = false; break; }
        }
        file.close();
        if (!okall) {
            // Remove the partial file so a stalled transfer never leaves a corrupt half-write.
            std.fs.deleteFileAbsolute(path) catch {};
            _ = xfer_send_all(fd, "-ERR incomplete (transfer stalled or short)\n.\n");
            return 0;
        }
        // Empty file: no chunks were sent, so emit an explicit completion ack.
        if (size == 0) _ = xfer_send_all(fd, "+OK 0\n.\n");
        return 0;
    }
    if (std.mem.eql(u8, cmd, "GET")) {
        // GET <path>\n → "+OK <size>\n" + <size> raw bytes (no ".\n" after binary).
        const path = std.mem.trim(u8, rest, " ");
        if (path.len == 0) { _ = xfer_send_all(fd, "-ERR missing path\n.\n"); return 0; }
        const file = std.fs.openFileAbsolute(path, .{}) catch |e| {
            var eb: [160]u8 = undefined;
            const m = std.fmt.bufPrint(&eb, "-ERR open ({s})\n.\n", .{@errorName(e)}) catch "-ERR open\n.\n";
            _ = xfer_send_all(fd, m);
            return 0;
        };
        defer file.close();
        const st = file.stat() catch { _ = xfer_send_all(fd, "-ERR stat failed\n.\n"); return 0; };
        if (st.size > MAX_XFER) { _ = xfer_send_all(fd, "-ERR too-large\n.\n"); return 0; }
        var hb: [48]u8 = undefined;
        const h = std.fmt.bufPrint(&hb, "+OK {d}\n", .{st.size}) catch { // header line, NO ".\n"
            _ = xfer_send_all(fd, "-ERR internal\n.\n");
            return 0;
        };
        if (!xfer_send_all(fd, h)) return 0;
        _ = xfer_send_file(fd, file, st.size);
        return 0;
    }

    // ── Job tracker ───────────────────────────────────────────────────────────
    if (std.mem.eql(u8, cmd, "JOB_RUN")) {
        const id = arg orelse return write_resp(resp, false, "missing id", "");
        const jcmd: []const u8 = if (id.len < rest.len) rest[id.len + 1..] else "";
        if (jcmd.len == 0) return write_resp(resp, false, "missing cmd", "");
        if (id.len > JOB_ID_MAX) return write_resp(resp, false, "id-too-long", "");
        job_run(id, jcmd) catch |e| return write_resp(resp, false, switch (e) {
            error.CmdTooLong   => "cmd-too-long",
            error.JobTableFull => "job-table-full",
            error.SpawnFailed  => "spawn-failed",
        }, "");
        var msg: [64]u8 = undefined;
        // id.len <= JOB_ID_MAX is already enforced above, so this can't realistically
        // overflow — but per the no-silent-truncation rule, a formatting failure here
        // must still fail loud rather than fall back to a misleading generic message.
        const m = std.fmt.bufPrint(&msg, "log=/tmp/bsdos-job-{s}.log", .{id})
            catch return write_resp(resp, false, "id-too-long", "");
        return resp_ok(resp, m);
    }
    if (std.mem.eql(u8, cmd, "JOB_LOG")) {
        const id = arg orelse return write_resp(resp, false, "missing id", "");
        var path: [64]u8 = undefined;
        const p = std.fmt.bufPrint(&path, "/tmp/bsdos-job-{s}.log", .{id})
            catch return write_resp(resp, false, "path error", "");
        return resp_capture(resp, run_capture(&.{ "tail", "-100", p }));
    }
    if (std.mem.eql(u8, cmd, "JOB_STATUS")) {
        const id = arg orelse return write_resp(resp, false, "missing id", "");
        reap();
        job_mutex.lock();
        defer job_mutex.unlock();
        const j = find_job(id) orelse return write_resp(resp, false, "no-such-job", "");
        switch (j.state) {
            .running => return resp_ok(resp, "state=running"),
            .killed  => return resp_ok(resp, "state=killed"),
            .exited  => {
                var msg: [64]u8 = undefined;
                const m = std.fmt.bufPrint(&msg, "state=exited rc={d}", .{j.rc})
                    catch "state=exited";
                return resp_ok(resp, m);
            },
            .none => return write_resp(resp, false, "no-such-job", ""), // unreachable via find_job
        }
    }
    if (std.mem.eql(u8, cmd, "JOB_LIST")) {
        reap();
        var body: [JOB_LIST_BUF]u8 = undefined;
        var bw = std.io.fixedBufferStream(&body);
        const bwr = bw.writer();
        job_mutex.lock();
        const now = std.time.timestamp();
        for (job_table) |j| {
            if (j.state == .none) continue;
            bwr.print("{s} {s} {d} {d}s\n",
                .{ j.id[0..j.id_len], @tagName(j.state), j.rc, now - j.started }) catch break;
        }
        job_mutex.unlock();
        return write_resp(resp, true, "", body[0..bw.pos]);
    }
    if (std.mem.eql(u8, cmd, "JOB_KILL")) {
        const id = arg orelse return write_resp(resp, false, "missing id", "");
        job_mutex.lock();
        defer job_mutex.unlock();
        const j = find_job(id) orelse return write_resp(resp, false, "no-such-job", "");
        if (j.state != .running) return write_resp(resp, false, "no-such-job", "");
        // SIGTERM only; reap() classifies the job `killed` once it actually exits.
        std.posix.kill(j.pid, std.posix.SIG.TERM) catch return write_resp(resp, false, "kill-failed", "");
        return resp_ok(resp, "");
    }
    if (std.mem.eql(u8, cmd, "JOB_GC")) {
        reap();
        const age_s: i64 = if (arg) |a|
            (std.fmt.parseInt(i64, a, 10) catch return write_resp(resp, false, "bad-age", ""))
        else
            3600;
        var count: usize = 0;
        const now = std.time.timestamp();
        job_mutex.lock();
        defer job_mutex.unlock();
        for (&job_table) |*j| {
            if (j.state != .exited and j.state != .killed) continue;
            if (now - j.started < age_s) continue;
            var path: [64]u8 = undefined;
            if (std.fmt.bufPrint(&path, "/tmp/bsdos-job-{s}.log", .{j.id[0..j.id_len]})) |p| {
                std.fs.deleteFileAbsolute(p) catch {};
            } else |_| {}
            j.* = .{};
            count += 1;
        }
        var msg: [64]u8 = undefined;
        const m = std.fmt.bufPrint(&msg, "gc={d}", .{count}) catch "gc=done";
        return resp_ok(resp, m);
    }

    // ── Jails ─────────────────────────────────────────────────────────────────
    if (std.mem.eql(u8, cmd, "JLS")) {
        return resp_capture(resp, run_capture(&.{ "jls", "-v" }));
    }
    if (std.mem.eql(u8, cmd, "JAIL_SETUP")) {
        _ = run_capture(&.{ "sh", "-c",
            "devfs rule -s 10 delall 2>/dev/null; devfs rule -s 10 add include 4;" ++
            "devfs rule -s 10 add path bpf unhide;" ++
            "devfs rule -s 11 delall 2>/dev/null; devfs rule -s 11 add include 4;" ++
            "devfs rule -s 11 add path bpf hide",
        });
        return resp_capture(resp, run_capture(&.{ "sh", "-c",
            "/opt/proto/jailmgr.sh setup-all 2>&1",
        }));
    }
    if (std.mem.eql(u8, cmd, "JAIL_TEARDOWN")) {
        return resp_capture(resp, run_capture(&.{ "sh", "-c",
            "/opt/proto/jailmgr.sh teardown-all 2>&1",
        }));
    }
    if (std.mem.eql(u8, cmd, "FREEZE")) {
        const jail = arg orelse return write_resp(resp, false, "missing jail", "");
        return resp_capture(resp, run_capture(&.{ "jexec", jail, "kill", "-STOP", "-1" }));
    }
    if (std.mem.eql(u8, cmd, "THAW")) {
        const jail = arg orelse return write_resp(resp, false, "missing jail", "");
        return resp_capture(resp, run_capture(&.{ "jexec", jail, "kill", "-CONT", "-1" }));
    }

    // ── Lifecycle ─────────────────────────────────────────────────────────────
    if (std.mem.eql(u8, cmd, "MEM_STATUS")) {
        return resp_capture(resp, run_capture(&.{ "sh", "-c",
            "sysctl vm.stats.vm.v_free_count vm.stats.vm.v_page_count 2>&1",
        }));
    }
    if (std.mem.eql(u8, cmd, "MEM_GUARD")) {
        const state = arg orelse "status";
        const sh = if (std.mem.eql(u8, state, "off"))
            "printf 'MEM_GUARD off\\n' | nc -w2 -U /var/run/bsdos-lifecycle.sock 2>/dev/null || echo lifecycled-not-running"
        else
            "printf 'MEM_GUARD on\\n'  | nc -w2 -U /var/run/bsdos-lifecycle.sock 2>/dev/null || echo lifecycled-not-running";
        return resp_capture(resp, run_capture(&.{ "sh", "-c", sh }));
    }
    if (std.mem.eql(u8, cmd, "HAL_START")) {
        spawn_bg(&.{ "sh", "-c",
            "pkill -f bsdos-hal 2>/dev/null; nohup /usr/local/bin/bsdos-hal >/tmp/hal.log 2>&1 &",
        });
        return resp_ok(resp, "background");
    }
    if (std.mem.eql(u8, cmd, "BROKER_START")) {
        spawn_bg(&.{ "sh", "-c",
            "pkill -f broker 2>/dev/null;" ++
            "nohup /opt/proto-src/broker/target/release/broker >/tmp/broker.log 2>&1 &",
        });
        return resp_ok(resp, "background");
    }
    if (std.mem.eql(u8, cmd, "LIFECYCLE_START")) {
        spawn_bg(&.{ "sh", "-c",
            "pkill -f bsdos-lifecycled 2>/dev/null;" ++
            "nohup /usr/local/bin/bsdos-lifecycled >/tmp/lifecycle.log 2>&1 &",
        });
        return resp_ok(resp, "background");
    }
    if (std.mem.eql(u8, cmd, "BUILD_BROKER")) {
        spawn_bg(&.{ "sh", "-c",
            "cd /opt/proto-src/broker && cargo build --release >/tmp/build-broker.log 2>&1",
        });
        return resp_ok(resp, "background");
    }
    if (std.mem.eql(u8, cmd, "BUILD_APP")) {
        spawn_bg(&.{ "sh", "-c",
            "cd /opt/proto-src/app && cargo build --release" ++
            " && cp target/release/proto-app /opt/proto/app/proto-app" ++
            " >/tmp/build-app.log 2>&1",
        });
        return resp_ok(resp, "background");
    }

    // ── Wayland ───────────────────────────────────────────────────────────────
    if (std.mem.eql(u8, cmd, "WAYLAND_STATUS")) {
        return resp_capture(resp, run_capture(&.{ "sh", "-c",
            "printf 'cage: ';        pgrep -q cage           && echo running || echo stopped;" ++
            "printf 'tunnel: ';      pgrep -q wayland-tunnel && echo running || echo stopped;" ++
            "printf 'core: ';        pgrep -q bsdos-core     && echo running || echo stopped;" ++
            "printf 'foot: ';        pgrep -q foot           && echo running || echo stopped;" ++
            "printf 'wayland-0: ';   test -S /tmp/wayland-run/wayland-0      && echo exists || echo missing;" ++
            "printf 'stream-sock: '; test -S /tmp/wayland-run/wayland-stream.sock && echo exists || echo missing",
        }));
    }
    if (std.mem.eql(u8, cmd, "WAYLAND_START")) {
        _ = run_capture(&.{ "sh", "-c",
            "pkill -f cage 2>/dev/null; pkill -f wayland-tunnel 2>/dev/null;" ++
            "pkill -f bsdos-core 2>/dev/null; pkill -f foot 2>/dev/null; sleep 0.3;" ++
            "rm -f /tmp/wayland-run/wayland-*.lock /tmp/wayland-run/wayland-[0-9]" ++
            "    /tmp/wayland-run/wayland-stream.sock /tmp/wayland-run/wayland-ghost-* 2>/dev/null;" ++
            "mkdir -p /tmp/wayland-run && chmod 777 /tmp/wayland-run",
        });
        spawn_bg(&.{ "sh", "-c",
            "nohup env XDG_RUNTIME_DIR=/tmp/wayland-run WLR_BACKENDS=headless" ++
            " WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1 LIBSEAT_BACKEND=noop" ++
            " cage -- /usr/local/bin/wl-keepalive >/tmp/cage.log 2>&1",
        });
        // Poll up to 5 seconds for wayland-0 socket to appear.
        for (0..50) |_| {
            std.posix.access("/tmp/wayland-run/wayland-0", 0) catch {
                _ = c.usleep(100_000);
                continue;
            };
            break;
        }
        spawn_bg(&.{ "sh", "-c",
            "nohup env XDG_RUNTIME_DIR=/tmp/wayland-run" ++
            " BSDOS_COMPOSITOR_SOCK=/tmp/wayland-run/wayland-0" ++
            " /usr/local/bin/wayland-tunnel >/tmp/wayland-tunnel.log 2>&1",
        });
        _ = c.usleep(500_000);
        spawn_bg(&.{ "sh", "-c",
            // Listen address and certs are per-host: /etc/bsdos/hosts.env on the guest.
            ". /etc/bsdos/hosts.env && nohup env ZENOH_TLS=1" ++
            " ZENOH_LISTEN_IP=\"$BSDOS_OBFS_LISTEN_IP\" ZENOH_LISTEN_PORT=\"$BSDOS_OBFS_LISTEN_PORT\"" ++
            " ZENOH_TLS_CA=\"$BSDOS_CERTS/ca.pem\"" ++
            " ZENOH_TLS_CERT=\"$BSDOS_CERTS/server.pem\"" ++
            " ZENOH_TLS_KEY=\"$BSDOS_CERTS/server.key\"" ++
            " /usr/local/bin/bsdos-core >/tmp/core.log 2>&1",
        });
        spawn_bg(&.{ "sh", "-c",
            "nohup env XDG_RUNTIME_DIR=/tmp/wayland-run WAYLAND_DISPLAY=wayland-ghost-0" ++
            " foot sh -c 'while true; do date; uptime; sleep 1; done' >/tmp/foot.log 2>&1",
        });
        _ = c.usleep(500_000);
        return resp_capture(resp, run_capture(&.{ "sh", "-c",
            "printf 'cage: ';    pgrep -q cage           && echo running || echo stopped;" ++
            "printf 'tunnel: ';  pgrep -q wayland-tunnel && echo running || echo stopped;" ++
            "printf 'core: ';    pgrep -q bsdos-core     && echo running || echo stopped;" ++
            "printf 'foot: ';    pgrep -q foot           && echo running || echo stopped",
        }));
    }
    if (std.mem.eql(u8, cmd, "RESIZE")) {
        if (rest.len == 0) return write_resp(resp, false, "missing WxH", "");
        var mode_s: []const u8 = rest;
        var scale:  []const u8 = "1";
        if (std.mem.indexOfScalar(u8, rest, '@')) |at| {
            mode_s = rest[0..at];
            scale  = rest[at + 1..];
        }
        if (std.mem.indexOfScalar(u8, mode_s, 'x') == null)
            return write_resp(resp, false, "invalid format WxH[@S]", "");
        var cb: [256]u8 = undefined;
        const randr = std.fmt.bufPrint(&cb,
            "env XDG_RUNTIME_DIR=/tmp/wayland-run" ++
            " wlr-randr --output HEADLESS-1 --custom-mode {s} --scale {s} 2>/dev/null || true",
            .{ mode_s, scale }) catch return write_resp(resp, false, "cmd too long", "");
        spawn_bg(&.{ "sh", "-c", randr });
        return resp_ok(resp, rest);
    }

    return write_resp(resp, false, "unknown command", cmd);
}
// dispatch:end

// ── virtio-console (chardev) transport ───────────────────────────────────────

// set_raw:start
//   purpose: Put a tty fd into raw mode (no line-discipline processing).
//   input:  fd — open tty file descriptor
//   output: void; silently no-ops if tcgetattr fails (e.g. non-tty fd)
//   sideEffects: modifies kernel termios state for fd
fn set_raw(fd: std.posix.fd_t) void {
    var t: c.termios = undefined;
    if (c.tcgetattr(fd, &t) == 0) {
        c.cfmakeraw(&t);
        _ = c.tcsetattr(fd, c.TCSANOW, &t);
    }
}
// set_raw:end

// chardev_write:start
//   purpose: Write bytes to a chardev with a write-readiness guard to prevent kernel blocking.
//   input:  fd — O_NONBLOCK chardev fd; data — bytes to send
//   output: void
//   sideEffects: writes to fd; drops data on 500ms poll timeout or EAGAIN
// Why poll first: even with O_NONBLOCK, FreeBSD's ttydisc_write acquires the tty mutex before
// checking the nonblock flag. If vtcon_tty_outwakeup is running (e.g. flushing a full virtio ring),
// it holds the tty mutex and a concurrent write blocks on mutex acquisition. poll(POLLOUT) returns
// without holding any kernel lock, so a 500ms timeout here prevents indefinite blocking.
fn chardev_write(fd: std.posix.fd_t, data: []const u8) void {
    // Poll + peer-check before EVERY write (not once up front): a large response is
    // several write()s, and if the host disconnects partway a later write into the
    // hung-up virtio-console wedges in vtcon_tty_outwakeup — unkillable, pegs a core,
    // and takes the whole agent down (the recurring "agent отвалился" wedge). Checking
    // POLLHUP/ERR/NVAL each iteration drops a response the vanished caller can't read
    // and keeps the agent alive for the next one.
    var sent: usize = 0;
    while (sent < data.len) {
        var wpfd = c.struct_pollfd{ .fd = fd, .events = @intCast(c.POLLOUT), .revents = 0 };
        if (c.poll(&wpfd, 1, 500) <= 0) {
            std.debug.print("[agent] chardev write timeout — dropped {d}B\n", .{data.len - sent});
            return;
        }
        if ((wpfd.revents & @as(c_short, @intCast(c.POLLHUP | c.POLLERR | c.POLLNVAL))) != 0) {
            std.debug.print("[agent] chardev peer gone (revents=0x{x}) — dropped {d}B\n",
                .{ wpfd.revents, data.len - sent });
            return;
        }
        // Cap each write to PUT_CHUNK: a single write bigger than the virtio-console
        // ring makes vtcon_tty_outwakeup spin-wait for ring space that never frees if
        // the host stopped draining → the unkillable wedge. A <=ring write fits in one
        // outwakeup pass, so when the peer dies the ring simply fills over a few small
        // writes and the next poll times out / shows HUP → we drop, never wedge.
        const end = @min(data.len, sent + PUT_CHUNK);
        const n = std.posix.write(fd, data[sent..end]) catch |e| {
            if (e == error.WouldBlock) continue; // ring momentarily full — re-poll, don't wedge
            return;
        };
        if (n == 0) return;
        sent += n;
    }
}
// chardev_write:end

// chardev_loop:start
//   purpose: Read-dispatch loop for an open chardev fd; accumulates bytes until newline.
//             On POLLHUP (host nc disconnect), idles in place rather than returning —
//             this avoids the close/reopen race that drops leading bytes of the next
//             nc session while QEMU resets the virtio-serial state machine.
//   input:  fd — O_NONBLOCK virtio-console fd
//   output: void; returns only on unrecoverable poll error (errno ≠ POLLHUP/POLLIN)
//   sideEffects: calls dispatch() per command, writes responses via chardev_write
fn chardev_loop(fd: std.posix.fd_t) void {
    var line: [MAX_LINE]u8 = undefined;
    var pos:  usize = 0;
    var overflow = false; // true once a line exceeds MAX_LINE — reply -ERR, never dispatch a truncated cmd
    var resp: [MAX_RESP]u8 = undefined;
    while (true) {
        var pfd = c.struct_pollfd{
            .fd     = fd,
            .events = @intCast(c.POLLIN | c.POLLHUP),
            .revents = 0,
        };
        const pret = c.poll(&pfd, 1, -1);
        if (pret < 0) break; // unrecoverable
        if (pret == 0) continue;

        const hup = (pfd.revents & @as(c_short, @intCast(c.POLLHUP))) != 0;
        const rin = (pfd.revents & @as(c_short, @intCast(c.POLLIN))) != 0;
        // POLLNVAL/POLLERR (output-only flags poll sets regardless of .events): the fd
        // is invalid or errored — the virtio-console device was removed/reset. Bail out
        // so serve_chardev takes its 1s backoff and re-scans/reopens, instead of falling
        // through to read() every wakeup (which, if it ever returns 0 rather than EBADF,
        // would spin at ~20 Hz). This is the clean exit for the device-vanished case.
        if ((pfd.revents & @as(c_short, @intCast(c.POLLNVAL | c.POLLERR))) != 0) break;
        // POLLHUP without POLLIN: host disconnected; idle until next nc reconnects.
        if (hup and !rin) {
            pos = 0; // discard partial line
            _ = c.usleep(50_000); // 50 ms: let QEMU complete virtio-serial reset
            continue;
        }

        var byte: [1]u8 = undefined;
        const n = std.posix.read(fd, &byte) catch break;
        if (n == 0) { // EOF without POLLHUP — shouldn't happen on chardev
            _ = c.usleep(50_000);
            continue;
        }
        if (byte[0] == '\n' or byte[0] == '\r') {
            if (overflow) {
                const len = write_resp(&resp, false, "line-too-long", "");
                chardev_write(fd, resp[0..len]);
                pos = 0;
                overflow = false;
            } else if (pos > 0) {
                const len = dispatch(line[0..pos], &resp, fd, .chardev);
                if (len > 0) chardev_write(fd, resp[0..len]);
                pos = 0;
            }
        } else if (pos < line.len - 1) {
            line[pos] = byte[0];
            pos += 1;
        } else {
            overflow = true; // buffer full and still no newline — drop bytes, flag for -ERR
        }
    }
}
// chardev_loop:end

// chardev_find:start
//   purpose: Locate a usable chardev: try the configured path first, then scan /dev/ttyV*.1.
//   input:  configured — env-configured or default chardev path;
//           pathbuf    — caller-supplied buffer for the alternative path string
//   output: slice into configured or pathbuf with the first openable path; configured if none found
//   sideEffects: logs via stderr when falling back to an alternative
fn chardev_find(configured: []const u8, pathbuf: []u8) []const u8 {
    if (std.fs.openFileAbsolute(configured, .{ .mode = .read_write })) |f| {
        f.close();
        return configured;
    } else |_| {}
    // Scan /dev/ttyV0.1 … /dev/ttyV3.1 for an alternative.
    for (0..4) |i| {
        const candidate = std.fmt.bufPrint(pathbuf, "/dev/ttyV{d}.1", .{i}) catch continue;
        if (std.mem.eql(u8, candidate, configured)) continue;
        if (std.fs.openFileAbsolute(candidate, .{ .mode = .read_write })) |f| {
            f.close();
            std.debug.print("[agent] chardev fallback: {s} (configured={s} unavailable)\n",
                .{ candidate, configured });
            return candidate;
        } else |_| {}
    }
    return configured; // best effort; open error will be logged in serve_chardev
}
// chardev_find:end

// serve_chardev:start
//   purpose: Open the chardev once, set it raw+nonblock, then hand off to chardev_loop
//             forever. chardev_loop handles POLLHUP in-place (no close/reopen on disconnect),
//             so we only reopen if chardev_loop exits on a hard poll error.
//   input:  configured — desired chardev path from env; actual path may differ via chardev_find
//   output: noreturn
//   sideEffects: opens fd (rarely closes/reopens), sets raw mode, blocks in chardev_loop
fn serve_chardev(configured: []const u8) noreturn {
    var pathbuf: [32]u8 = undefined;
    while (true) {
        // Re-scan EVERY iteration: across a virtio-serial reset the chardev can
        // vanish and reappear (possibly at a different /dev/ttyVN.1), so a path
        // resolved once at startup goes stale and we'd reopen a dead node forever.
        const path = chardev_find(configured, &pathbuf);
        const file = std.fs.openFileAbsolute(path, .{ .mode = .read_write }) catch |e| {
            std.debug.print("[agent] chardev open failed ({s}): {s}\n", .{ @errorName(e), path });
            _ = c.sleep(1);
            continue;
        };
        const fd = file.handle;
        // O_NONBLOCK: prevents write() from blocking when QEMU host-side socket has no reader.
        const fl = std.posix.fcntl(fd, std.posix.F.GETFL, 0) catch 0;
        _ = std.posix.fcntl(fd, std.posix.F.SETFL,
            @as(usize, @intCast(fl)) | @as(usize, @intCast(c.O_NONBLOCK))) catch {};
        set_raw(fd);
        std.debug.print("[agent] chardev open: {s}\n", .{path});
        chardev_loop(fd); // returns only on a hard poll/read error
        file.close();
        // CRITICAL FIX (recurring agent wedge): back off before reopening. If the
        // device is broken-but-openable (poll returns POLLNVAL/error immediately
        // after a virtio-serial reset), reopening in a tight open→break→close loop
        // pegs a CPU core at 100% and the spinning process becomes hard to signal
        // (the wedge we kept resetting the VM for). A 1s sleep keeps the reopen loop
        // cheap and the process interruptible.
        std.debug.print("[agent] chardev loop exited — backing off 1s before reopen\n", .{});
        _ = c.sleep(1);
    }
}
// serve_chardev:end

// ── Unix socket transport ─────────────────────────────────────────────────────

// unix_loop:start
//   purpose: Per-connection blocking read-dispatch loop for a unix socket fd.
//   input:  fd — accepted connection fd
//   output: void; returns on EOF or read error
//   sideEffects: reads commands, writes responses to fd
fn unix_loop(fd: std.posix.fd_t) void {
    var line: [MAX_LINE]u8 = undefined;
    var pos:  usize = 0;
    var overflow = false; // true once a line exceeds MAX_LINE — reply -ERR, never dispatch a truncated cmd
    var resp: [MAX_RESP]u8 = undefined;
    while (true) {
        var byte: [1]u8 = undefined;
        const n = std.posix.read(fd, &byte) catch break;
        if (n == 0) break;
        if (byte[0] == '\n' or byte[0] == '\r') {
            if (overflow) {
                const len = write_resp(&resp, false, "line-too-long", "");
                _ = std.posix.write(fd, resp[0..len]) catch break;
                pos = 0;
                overflow = false;
            } else if (pos > 0) {
                const len = dispatch(line[0..pos], &resp, fd, .unix);
                if (len > 0) _ = std.posix.write(fd, resp[0..len]) catch break;
                pos = 0;
            }
        } else if (pos < line.len - 1) {
            line[pos] = byte[0];
            pos += 1;
        } else {
            overflow = true; // buffer full and still no newline — drop bytes, flag for -ERR
        }
    }
}
// unix_loop:end

// serve_unix:start
//   purpose: Create a unix socket, accept connections serially, run unix_loop per connection.
//   input:  none
//   output: error on socket creation or accept failure; loops forever on success
//   sideEffects: creates UNIX_SOCK, chmod 0666, blocks on accept
fn serve_unix() !void {
    std.fs.deleteFileAbsolute(UNIX_SOCK) catch {};
    const addr = try std.net.Address.initUnix(UNIX_SOCK);
    var server  = try addr.listen(.{ .reuse_address = true });
    defer server.deinit();
    _ = std.c.chmod(UNIX_SOCK, 0o666);
    std.debug.print("[agent] unix socket ready: {s}\n", .{UNIX_SOCK});
    while (true) {
        const conn = try server.accept();
        unix_loop(conn.stream.handle);
        conn.stream.close();
    }
}
// serve_unix:end

// serve_unix_bg:start
//   purpose: Thread entry point: run serve_unix, log error if it fails.
//   input:  none
//   output: void
//   sideEffects: creates unix socket, blocks on accept
fn serve_unix_bg() void {
    serve_unix() catch |e|
        std.debug.print("[agent] unix socket error: {s}\n", .{@errorName(e)});
}
// serve_unix_bg:end

// ── Entry point ───────────────────────────────────────────────────────────────

// acquire_instance_lock:start
//   purpose: Ensure exactly one agent instance runs at a time using an exclusive flock,
//            self-healing past a lock file left behind by a dead instance instead of
//            requiring an operator to notice and `rm -f` it by hand.
//   input:  LOCK_FILE path
//   output: void — returns only if lock acquired; exits(0) if another instance holds it
//   sideEffects: opens LOCK_FILE, holds LOCK_EX for process lifetime (fd leaked intentionally);
//                writes PID to lock file for rc.d diagnostics; may unlink+recreate the file
//                once if the previously-recorded PID no longer exists
// Why: multiple instances on the same chardev cause tty mutex contention. FreeBSD's tty
// lock is held across vtcon_tty_outwakeup; a second writer blocks on tty_lock even with
// O_NONBLOCK set, eventually rendering it unkillable via SIGKILL (kernel mutex sleep).
//
// STALE-LOCK NOTE (2026-07-24 incident): flock() is released by the kernel the instant
// every fd on the locked inode closes, including on process death (even via SIGKILL) --
// a truly-dead holder cannot keep the lock. What was actually observed: a restart left a
// lock file whose recorded PID no longer existed, yet a fresh flock() attempt still
// failed, and clearing it required an operator to manually `rm -f` the file before the
// next start would succeed. Rather than requiring that by hand every time: on a failed
// flock(), check whether the PID recorded in the file is still alive; if not (ESRCH),
// treat the file as safely stale, unlink it, and retry the lock ONCE on a fresh inode. If
// the recorded PID IS alive (even stuck in an uninterruptible kernel wait), leave it
// alone -- that is the genuine "another instance" case this lock exists to prevent.
fn acquire_instance_lock() void {
    acquire_instance_lock_attempt(true);
}

fn acquire_instance_lock_attempt(allow_stale_retry: bool) void {
    const lock_fd = std.posix.open(
        LOCK_FILE,
        .{ .ACCMODE = .WRONLY, .CREAT = true },
        0o600,
    ) catch |e| {
        std.debug.print("[agent] lock open ({s}) — no single-instance guard\n", .{@errorName(e)});
        return;
    };
    if (c.flock(lock_fd, c.LOCK_EX | c.LOCK_NB) != 0) {
        std.posix.close(lock_fd);
        if (allow_stale_retry and clear_stale_lock()) {
            return acquire_instance_lock_attempt(false); // one retry only, on a fresh inode
        }
        std.debug.print("[agent] another instance holds {s} — exiting\n", .{LOCK_FILE});
        std.process.exit(0);
    }
    var pidbuf: [24]u8 = undefined;
    const pid_str = std.fmt.bufPrint(&pidbuf, "{d}\n", .{c.getpid()}) catch "";
    _ = std.posix.write(lock_fd, pid_str) catch {};
    // lock_fd intentionally not closed: flock is released when fd is closed or process exits.
}
// acquire_instance_lock:end

// clear_stale_lock:start
//   purpose: Check whether LOCK_FILE's recorded PID is still alive; unlink the file if the
//            recorded PID is confirmed dead, so the caller can retry flock() on a fresh inode.
//   input:  none (reads LOCK_FILE)
//   output: true  — PID confirmed dead (ESRCH) and the file was removed; safe to retry
//           false — PID alive, or the file/PID could not be read/parsed; leave it alone
//   sideEffects: may unlink LOCK_FILE
fn clear_stale_lock() bool {
    const file = std.fs.openFileAbsolute(LOCK_FILE, .{}) catch return false;
    defer file.close();
    var buf: [24]u8 = undefined;
    const n = file.read(&buf) catch return false;
    const trimmed = std.mem.trim(u8, buf[0..n], " \n\r\t");
    const pid = std.fmt.parseInt(std.posix.pid_t, trimmed, 10) catch return false;
    std.posix.kill(pid, 0) catch |e| {
        if (e == error.ProcessNotFound) {
            std.debug.print("[agent] {s} PID {d} is dead — clearing stale lock\n", .{ LOCK_FILE, pid });
            std.fs.deleteFileAbsolute(LOCK_FILE) catch return false;
            return true;
        }
        return false; // PermissionDenied or unexpected — don't guess, leave it alone
    };
    return false; // PID is alive — genuinely another instance, don't touch the lock
}
// clear_stale_lock:end

// main:start
//   purpose: Select transport mode and start serving; log version and PID on startup.
//   input:  env BSDOS_AGENT_TRANSPORT — "auto"|"chardev"|"unix" (default: "auto")
//           env BSDOS_CHARDEV_PATH    — chardev path (default: CHARDEV_DEFAULT)
//   output: error on unix transport failure; never returns in chardev or auto+chardev mode
//   sideEffects: spawns unix background thread in auto mode; opens chardev
pub fn main() !void {
    const transport = std.posix.getenv("BSDOS_AGENT_TRANSPORT") orelse "auto";
    const configured = std.posix.getenv("BSDOS_CHARDEV_PATH")  orelse CHARDEV_DEFAULT;

    std.debug.print("[agent] v{s} pid={d} transport={s} chardev={s}\n",
        .{ VERSION, c.getpid(), transport, configured });

    acquire_instance_lock();

    if (std.mem.eql(u8, transport, "unix"))    return serve_unix();
    if (std.mem.eql(u8, transport, "chardev")) serve_chardev(configured);

    // auto: chardev primary, unix socket fallback (for in-guest local callers).
    std.fs.accessAbsolute(configured, .{}) catch {
        std.debug.print("[agent] chardev not found, unix-only\n", .{});
        return serve_unix();
    };
    const t = std.Thread.spawn(.{}, serve_unix_bg, .{}) catch |e| {
        std.debug.print("[agent] unix thread failed ({s}), chardev-only\n", .{@errorName(e)});
        serve_chardev(configured);
    };
    t.detach();
    serve_chardev(configured);
}
// main:end
