#!/bin/sh
[ -r "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}" ] && . "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}"
# @deprecated — используй _agent.sh для операций внутри VM.
# SSH остаётся только для: деплоя файлов (scp), начального setup, pkg install.
# Всё остальное → agent_* функции из _agent.sh.
set -eu

: "${SSH_KEY:=${BSDOS_SSH_KEY:?set BSDOS_SSH_KEY in /etc/bsdos/hosts.env}}"
: "${VM_SSH_PORT:=2222}"

# ControlMaster: первое соединение создаёт мастер-сокет,
# все последующие используют его без TCP handshake/auth (~200ms → ~5ms).
# ControlPersist=120 — мастер живёт 120с после последней команды.
_SSH_CONTROL="/tmp/bsdos-ssh-ctl-%r@%h:%p"
_SSH_OPTS="-p $VM_SSH_PORT -i $SSH_KEY \
    -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null \
    -o ControlMaster=auto \
    -o ControlPath=$_SSH_CONTROL \
    -o ControlPersist=120"

ssh_guest() {
    # shellcheck disable=SC2086
    ssh $_SSH_OPTS freebsd@localhost "$@"
}

ssh_root() {
    ssh_guest "su -m root -c \"$1\""
}

# Copy a file from HOST to GUEST via scp.
# Usage: scp_freebsd <host_src> <guest_dst>
# Uses the same ControlMaster socket, port, key and host-check options as ssh_guest.
scp_freebsd() {
    local host_src="$1"
    local guest_dst="$2"
    # shellcheck disable=SC2086
    scp -P "$VM_SSH_PORT" \
        -i "$SSH_KEY" \
        -o StrictHostKeyChecking=no \
        -o UserKnownHostsFile=/dev/null \
        -o ControlMaster=auto \
        -o "ControlPath=$_SSH_CONTROL" \
        -o ControlPersist=120 \
        "$host_src" \
        "freebsd@localhost:$guest_dst"
}

# Открыть мастер-соединение явно (вызывать из vm-wait или start скриптов)
ssh_master_open() {
    # shellcheck disable=SC2086
    ssh $_SSH_OPTS -MNf freebsd@localhost 2>/dev/null || true
    echo "[ssh] ControlMaster established ($_SSH_CONTROL)"
}

# Закрыть мастер-соединение
ssh_master_close() {
    # shellcheck disable=SC2086
    ssh $_SSH_OPTS -O exit freebsd@localhost 2>/dev/null || true
}

# @deprecated — cage_start spaws cage with wl-keepalive (legacy shim).
# Since #146 (2026-07-03), stream_manager.rs uses cage -s (shell mode) + FIFO stdin
# instead of wl-keepalive.  This function is kept for manual/debug use only.
# The bsdos-pipeline sh script (also deprecated) still calls it.
# Production streams are managed by bsdos-core StreamManager; do NOT call cage_start
# for production streams.
#
# Использование: cage_start              → cage -s (shell-mode, no keepalive)
#                cage_start "-- foot"   → cage с foot как embedded app (legacy)
cage_start() {
    local app_arg="${1:-}"
    # Legacy mode: if an explicit app is given, use it; otherwise use cage -s (shell mode)
    # which keeps cage alive without any client (no wl-keepalive needed).
    if [ -z "$app_arg" ]; then
        # cage -s: stay alive with 0 clients; stdin kept open via /dev/null trick
        # (cage -s exits on stdin EOF; redirecting from /dev/null gives EOF immediately,
        #  so for persistent headless use a FIFO or rely on StreamManager's FIFO approach).
        # For manual/debug: just use shell-mode; you'll need to keep cage's stdin open.
        app_arg="-s"
    fi
    ssh_root "pkill -f cage 2>/dev/null || true"
    local cage_cmd="nohup env XDG_RUNTIME_DIR=/tmp/wayland-run WLR_BACKENDS=headless WLR_RENDERER=pixman WLR_HEADLESS_OUTPUTS=1 LIBSEAT_BACKEND=noop cage $app_arg >/tmp/cage.log 2>&1 &"
    ssh_root "$cage_cmd"
    sleep 3
    ssh_root "chmod 777 /tmp/wayland-run/wayland-0 2>/dev/null || true"
}
