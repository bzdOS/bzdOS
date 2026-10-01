#!/usr/bin/env python3
# START_AI_HEADER
# MODULE: infra/scripts/vport-client.py
# PURPOSE: Robust host-side client for the bsdOS guest-agent virtio-console vport.
# INTENT: Replace the fragile `nc -w<t> | awk '/^\.$/{exit}'` transport that could
#         close the socket mid-response and WEDGE the guest agent's write() inside
#         the FreeBSD virtio-console driver (vtcon_tty_outwakeup) — taking the whole
#         agent down ("vport отваливается каждую сессию"). Also adds binary PUT/GET.
# DEPENDENCIES: python3 stdlib only (socket, select, os, argparse).
# PUBLIC_API: cmd | ping | put | get  (see usage)
# END_AI_HEADER
"""Robust bsdOS vport client.

The guest agent speaks a line protocol over a QEMU virtio-console unix socket:

    request   CMD [ARG]\\r\\n
    response  +OK [msg]\\n [body\\n]* .\\n      (success)
              -ERR [msg]\\n [body\\n]* .\\n     (failure)
    PUT       PUT <size> <path>\\r\\n  -> +OK ready\\n.\\n  -> <size> raw bytes -> +OK <n>\\n.\\n
    GET       GET <path>\\r\\n         -> +OK <size>\\n + <size> raw bytes   (or -ERR\\n.\\n)

Why this exists (reliability): the guest write() to the virtio-console wedges,
unkillably, in vtcon_tty_outwakeup if the host stops draining the ring while the
agent is writing. The old `nc -w` client used an ABSOLUTE timeout and tore the
pipe down early (`awk exit`, `head -1`), so a slightly-large or slightly-slow
response could close the socket mid-write and wedge the agent. This client:

  * uses an IDLE timeout (reset on every byte) — a command that streams output
    over time is never cut off; only a genuine stall aborts;
  * reads to the true terminator (a line == ".") and then FULLY DRAINS trailing
    bytes before closing, so the socket is never closed while the agent is writing;
  * is binary-safe for PUT/GET (length-prefixed raw payload, streamed to/from disk).

Usage:
  vport-client.py cmd  SOCK "COMMAND"      text command; prints response, exit 0 iff +OK
  vport-client.py ping SOCK                liveness; prints "vport" + exit 0 iff +OK PONG
  vport-client.py put  SOCK LOCAL REMOTE   upload LOCAL -> guest REMOTE
  vport-client.py get  SOCK REMOTE LOCAL   download guest REMOTE -> LOCAL
Options: --idle SECONDS (idle-read timeout, default 600), --connect SECONDS (default 8)
"""
import argparse
import os
import select
import socket
import sys

DRAIN_SECS = 0.3  # brief post-terminator drain so the agent is never mid-write at close


class Conn:
    """Buffered, idle-timeout unix-socket connection to the vport."""

    def __init__(self, path, idle, connect_timeout):
        self.idle = idle
        self.buf = b""
        self.s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.s.settimeout(connect_timeout)
        self.s.connect(path)
        self.s.setblocking(False)

    def _fill(self):
        """Wait up to `idle` secs for more bytes. False on idle-timeout or EOF."""
        r, _, _ = select.select([self.s], [], [], self.idle)
        if not r:
            return False  # idle timeout — genuine stall
        try:
            d = self.s.recv(65536)
        except BlockingIOError:
            return True
        if not d:
            return False  # peer EOF
        self.buf += d
        return True

    def read_line(self):
        """One line without trailing newline (\\r stripped); None on timeout/EOF."""
        while b"\n" not in self.buf:
            if not self._fill():
                return None
        i = self.buf.index(b"\n")
        line, self.buf = self.buf[:i], self.buf[i + 1:]
        return line.rstrip(b"\r")

    def read_exact(self, n):
        """Return exactly n bytes, or None if the stream stalls/EOFs before n arrive."""
        while len(self.buf) < n:
            if not self._fill():
                return None
        out = self.buf[:n]
        self.buf = self.buf[n:]
        return bytes(out)

    def send_all(self, data):
        """Send every byte, waiting for writability (never partial-drop)."""
        mv = memoryview(data)
        sent = 0
        while sent < len(mv):
            _, w, _ = select.select([], [self.s], [], self.idle)
            if not w:
                raise TimeoutError("send idle timeout")
            try:
                n = self.s.send(mv[sent:])
            except BlockingIOError:
                continue
            if n == 0:
                raise BrokenPipeError("send returned 0")
            sent += n

    def drain(self, secs=DRAIN_SECS):
        """Consume any trailing bytes briefly so the agent is never mid-write at close."""
        while True:
            r, _, _ = select.select([self.s], [], [], secs)
            if not r:
                return
            try:
                d = self.s.recv(65536)
            except BlockingIOError:
                return
            if not d:
                return

    def close(self):
        try:
            self.s.shutdown(socket.SHUT_WR)
        except OSError:
            pass
        try:
            self.s.close()
        except OSError:
            pass


def _read_response(conn):
    """Read a full text response to the '.' terminator, then drain.
    Returns (ok: bool, lines: list[str]) — lines includes the header."""
    header = conn.read_line()
    if header is None:
        return (False, ["-ERR (no response / idle timeout)"])
    lines = [header]
    ok = header.startswith(b"+OK")
    while True:
        ln = conn.read_line()
        if ln is None or ln == b".":
            break
        lines.append(ln)
    conn.drain()
    return (ok, [l.decode("utf-8", "replace") for l in lines])


def _read_ack(conn):
    """Read one '+OK...\\n.\\n' / '-ERR...\\n.\\n' WITHOUT the post-drain — used per PUT
    chunk, where a 0.3s drain each would add minutes over thousands of chunks.
    Returns (ok: bool, header: str|None)."""
    hdr = conn.read_line()
    if hdr is None:
        return (False, None)
    ok = hdr.startswith(b"+OK")
    while True:
        ln = conn.read_line()
        if ln is None or ln == b".":
            break
    return (ok, hdr.decode("utf-8", "replace"))


def _drain_error(conn, header):
    """After a leading -ERR header, consume the rest of the response; return the text."""
    msg = [header]
    while True:
        ln = conn.read_line()
        if ln is None or ln == b".":
            break
        msg.append(ln)
    conn.drain()
    return b" ".join(msg).decode("utf-8", "replace")


def cmd_mode(conn, command):
    conn.send_all((command + "\r\n").encode())
    ok, lines = _read_response(conn)
    for l in lines:
        print(l)
    return 0 if ok else 1


def ping_mode(conn):
    conn.send_all(b"PING\r\n")
    ok, lines = _read_response(conn)
    if ok and any("PONG" in l for l in lines):
        print("vport")
        return 0
    return 1


def put_mode(conn, local, remote):
    try:
        size = os.path.getsize(local)
    except OSError as e:
        print("-ERR local (%s)" % e)
        return 1
    # Terminate the header with a BARE '\n' (not '\r\n'): chardev_loop dispatches on
    # the first line-end byte, so a trailing '\r' would leave '\n' in the stream to be
    # mis-read as the first payload byte. LF-only keeps the raw payload clean.
    conn.send_all(("PUT %d %s\n" % (size, remote)).encode())
    hdr = conn.read_line()
    if hdr is None:
        print("-ERR (no ready ack / idle timeout)")
        return 1
    if not hdr.startswith(b"+OK"):
        print(_drain_error(conn, hdr))
        return 1
    # Ready-ack: "+OK ready <chunk>\n.\n". Parse the flow-control window the guest
    # advertises — the tty input queue is small + unbuffered, so we MUST send at most
    # <chunk> bytes and wait for the guest's ACK before sending the next piece.
    parts = hdr.split()
    chunk = 1024
    if len(parts) >= 3:
        try:
            chunk = int(parts[2])
        except ValueError:
            pass
    if chunk <= 0:
        chunk = 1024
    term = conn.read_line()  # consume the ready-ack terminator "."
    if term is not None and term != b".":
        pass
    if size == 0:
        ok, hh = _read_ack(conn)  # empty file → explicit completion ack
        print(hh if hh else "-ERR (no completion)")
        return 0 if ok else 1
    sent = 0
    last = "+OK"
    with open(local, "rb") as f:
        while sent < size:
            piece = f.read(min(chunk, size - sent))
            if not piece:
                print("-ERR local read short at %d/%d" % (sent, size))
                return 1
            conn.send_all(piece)
            sent += len(piece)
            ok, hh = _read_ack(conn)  # flow-control gate: wait for this chunk's ACK
            if not ok:
                print(hh if hh else "-ERR (no ack at %d/%d)" % (sent, size))
                return 1
            last = hh
    conn.drain()
    print(last)  # final ACK carries "+OK <size>"
    return 0


def get_mode(conn, remote, local):
    conn.send_all(("GET %s\n" % remote).encode())  # bare LF (see put_mode note)
    hdr = conn.read_line()
    if hdr is None:
        print("-ERR (no response / idle timeout)")
        return 1
    if hdr.startswith(b"-ERR"):
        print(_drain_error(conn, hdr))
        return 1
    if not hdr.startswith(b"+OK"):
        print("-ERR (bad header: %r)" % hdr)
        return 1
    # Header: "+OK <size>". Stream the payload to disk, reading CONTINUOUSLY (no ACKs) so
    # QEMU keeps the guest's virtio ring drained. Pausing (e.g. to ACK) lets the ring back
    # up between reads and wedges the guest's write in the FreeBSD virtio-console driver —
    # so the GET reader must never stall mid-stream.
    parts = hdr.split()
    try:
        size = int(parts[1])
    except (IndexError, ValueError):
        print("-ERR (bad size header: %r)" % hdr)
        return 1
    tmp = local + ".part"
    got = 0
    try:
        with open(tmp, "wb") as f:
            while got < size:
                piece = conn.read_exact(min(65536, size - got))
                if piece is None:
                    break
                f.write(piece)
                got += len(piece)
    except OSError as e:
        print("-ERR local write (%s)" % e)
        return 1
    if got != size:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        print("-ERR (short read: got %d/%d bytes)" % (got, size))
        return 1
    os.replace(tmp, local)
    conn.drain()
    print("+OK %d bytes -> %s" % (size, local))
    return 0


def main():
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("mode", choices=["cmd", "ping", "put", "get"])
    ap.add_argument("sock")
    ap.add_argument("args", nargs="*")
    ap.add_argument("--idle", type=float,
                    default=float(os.environ.get("VPORT_IDLE", "600")))
    ap.add_argument("--connect", type=float,
                    default=float(os.environ.get("VPORT_CONNECT", "8")))
    a = ap.parse_args()

    try:
        conn = Conn(a.sock, a.idle, a.connect)
    except OSError as e:
        print("-ERR connect (%s)" % e)
        return 1
    try:
        if a.mode == "cmd":
            return cmd_mode(conn, a.args[0] if a.args else "")
        if a.mode == "ping":
            return ping_mode(conn)
        if a.mode == "put":
            if len(a.args) < 2:
                print("-ERR usage: put SOCK LOCAL REMOTE")
                return 2
            return put_mode(conn, a.args[0], a.args[1])
        if a.mode == "get":
            if len(a.args) < 2:
                print("-ERR usage: get SOCK REMOTE LOCAL")
                return 2
            return get_mode(conn, a.args[0], a.args[1])
    except (TimeoutError, BrokenPipeError, OSError) as e:
        print("-ERR transport (%s)" % e)
        return 1
    finally:
        conn.close()


if __name__ == "__main__":
    sys.exit(main())
