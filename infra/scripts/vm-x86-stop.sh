#!/bin/sh
# Graceful QEMU shutdown via QMP system_powerdown.
# Falls back to SIGTERM only after timeout.
# NOTE: QMP command + timeout behaviour should be verified on a live VM.
set -eu

QMP_SOCK="${QMP_SOCK:-/tmp/bsdos-qmp.sock}"
# Seconds to wait for QEMU to exit after system_powerdown before SIGTERM fallback.
# Guest runs multiple jails (browser/cage/tunnel) + services; clean FreeBSD shutdown
# of that workload measured >30s in live testing, so the default is generous.
# QMP system_powerdown itself is confirmed working; this is just the patience window.
# Override via env: POWERDOWN_TIMEOUT=60 make vm-x86-stop
POWERDOWN_TIMEOUT="${POWERDOWN_TIMEOUT:-120}"

if ! pgrep -f "qemu-system-x86_64.*freebsd-x86" >/dev/null 2>&1; then
    echo "x86 VM not running"
    exit 0
fi

# ── Graceful path: send QMP system_powerdown ──────────────────────────────────
if [ -S "$QMP_SOCK" ]; then
    echo "[stop] Sending QMP system_powerdown via $QMP_SOCK ..."
    # QMP requires an initial capability negotiation before commands are accepted.
    # We send:  { "execute": "qmp_capabilities" }
    # then:     { "execute": "system_powerdown" }
    # The printf writes both JSON lines separated by newlines; socat pipes stdin
    # to the socket and reads with a 10 s idle timeout (-T10), then closes.
    # -T10 matches the canonical QMP pattern in vm-restore.sh and prevents a hang
    # if QEMU is slow/unresponsive on the QMP greeting.
    # Command+args form — no sh -c string concatenation.
    # VERIFY ON LIVE VM: socat must be installed on the host (apt/brew install socat).
    printf '{ "execute": "qmp_capabilities" }\n{ "execute": "system_powerdown" }\n' \
        | socat -T10 - "UNIX-CONNECT:${QMP_SOCK}" \
        2>/dev/null || true

    # Wait for QEMU process to exit (until-loop, no blind sleep).
    _elapsed=0
    until ! pgrep -f "qemu-system-x86_64.*freebsd-x86" >/dev/null 2>&1; do
        if [ "$_elapsed" -ge "$POWERDOWN_TIMEOUT" ]; then
            echo "[stop] Timeout (${POWERDOWN_TIMEOUT}s) waiting for graceful shutdown — falling back to SIGTERM"
            pkill -f "qemu-system-x86_64.*freebsd-x86" 2>/dev/null \
                && echo "[stop] x86 VM killed (SIGTERM)" \
                || echo "[stop] x86 VM already gone"
            exit 0
        fi
        sleep 1
        _elapsed=$((_elapsed + 1))
    done

    echo "[stop] x86 VM stopped gracefully"
else
    # ── Fallback: QMP socket not present (VM started without QMP or already gone) ──
    echo "[stop] QMP socket not found at $QMP_SOCK — falling back to SIGTERM"
    pkill -f "qemu-system-x86_64.*freebsd-x86" 2>/dev/null \
        && echo "[stop] x86 VM stopped (SIGTERM)" \
        || echo "[stop] x86 VM not running"
fi
