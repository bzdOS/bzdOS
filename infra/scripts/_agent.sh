#!/bin/sh
[ -r "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}" ] && . "${BSDOS_HOSTS_ENV:-/etc/bsdos/hosts.env}"
# bsdOS Agent transport layer.
# Транспорты (приоритет):
#   1. virtio-console: socat UNIX-CONNECT к $AGENT_VPORT_SOCK (host-side QEMU chardev)
#   2. unix-socket:    nc -U к $AGENT_SOCK внутри VM через SSH (fallback)
#
# Протокол: текст CMD [ARG]\r\n / +OK [msg]\n...\n.\n / -ERR ...\n.\n
# Важно: virtio-console TTY требует \r\n (CR+LF) на входе.
# Использование: . "$(dirname "$0")/_agent.sh"

: "${SSH_KEY:=${BSDOS_SSH_KEY:?set BSDOS_SSH_KEY in /etc/bsdos/hosts.env}}"
: "${VM_SSH_PORT:=2222}"
: "${AGENT_SOCK:=/var/run/bsdos-agent.sock}"

# Автоопределение сокета: libvirt использует -x86.sock, raw QEMU — без суффикса
if [ -S /tmp/bsdos-agent-vport-x86.sock ]; then
    : "${AGENT_VPORT_SOCK:=/tmp/bsdos-agent-vport-x86.sock}"
elif [ -S /tmp/bsdos-agent-vport.sock ]; then
    : "${AGENT_VPORT_SOCK:=/tmp/bsdos-agent-vport.sock}"
else
    AGENT_VPORT_SOCK=/tmp/bsdos-agent-vport.sock  # fallback даже если нет
fi

# Robust host-side vport client (python). Replaces the fragile `nc -w | awk exit`
# transport that could close the socket mid-response and WEDGE the guest agent's
# write() in the FreeBSD virtio-console driver (see vport-client.py header). Located
# relative to this script; overridable via $VPORT_CLIENT. Falls back to nc only if
# python3 or the client is unavailable.
: "${PYTHON:=python3}"
: "${VPORT_CLIENT:=}"
if [ -z "$VPORT_CLIENT" ]; then
    for _vc in infra/scripts/vport-client.py \
               "$(dirname "$0" 2>/dev/null)/vport-client.py" \
               "${BSDOS_REPO:-.}/infra/scripts/vport-client.py"; do
        [ -f "$_vc" ] && { VPORT_CLIENT="$_vc"; break; }
    done
fi

# _vport_has_py: true if the robust python client is usable.
_vport_has_py() {
    [ -n "$VPORT_CLIENT" ] && command -v "$PYTHON" >/dev/null 2>&1
}


_SSH="ssh -p $VM_SSH_PORT -i $SSH_KEY \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null \
    -o ControlMaster=auto \
    -o ControlPath=/tmp/bsdos-ssh-ctl-%r@%h:%p \
    -o ControlPersist=120"

# Определить активный транспорт с проверкой лайвнесса.
# Соединение с сокетом не достаточно — агент может не отвечать (O_NONBLOCK drain-стейт).
# Посылаем PING и ждём +OK; при таймауте падаем на ssh-unix.
_agent_transport() {
    if [ -S "$AGENT_VPORT_SOCK" ]; then
        # Liveness via a real PING+drain. The robust client reads the full response
        # and drains before closing, so the check itself can never wedge the agent
        # (unlike the old `nc | head -1` which closed mid-response).
        if _vport_has_py; then
            if "$PYTHON" "$VPORT_CLIENT" ping "$AGENT_VPORT_SOCK" --idle 15 >/dev/null 2>&1; then
                echo "vport"; return
            fi
        else
            local resp
            resp=$(printf 'PING\r\n' | nc -w2 -U "$AGENT_VPORT_SOCK" 2>/dev/null | head -1)
            case "$resp" in
                +OK*) echo "vport"; return ;;
            esac
        fi
    fi
    # ssh fallback is OPT-IN only (native-first: no silent ssh). If the vport
    # is not live, FAIL loudly instead of tunnelling over ssh. Set
    # AGENT_ALLOW_SSH=1 to explicitly re-enable the legacy ssh-unix path.
    if [ "${AGENT_ALLOW_SSH:-0}" = "1" ]; then
        echo "ssh-unix"
    else
        echo "none"
    fi
}

# Послать одну команду и прочитать ответ (все строки до "." = конец ответа).
# Возвращает 0 если ответ начинается с +OK, 1 если -ERR.
# $2 — таймаут nc в секундах (default 5; для долгих EXEC увеличивай).
agent_cmd() {
    local cmd="$1"
    local nc_timeout="${2:-5}"
    local transport
    transport=$(_agent_transport)
    if [ "$transport" = "vport" ]; then
        if _vport_has_py; then
            # Robust path: idle-timeout reads to terminator + full drain; the client
            # exits 0 iff the response header is +OK and prints all response lines.
            "$PYTHON" "$VPORT_CLIENT" cmd "$AGENT_VPORT_SOCK" "$cmd" --idle "$nc_timeout"
            return $?
        fi
        # Legacy nc fallback (only if python/client missing) — fragile, kept for safety.
        local raw
        raw=$(printf '%s\r\n' "$cmd" | nc -w"$nc_timeout" -U "$AGENT_VPORT_SOCK" 2>/dev/null \
            | awk '/^\.$/{exit} {print}')
        printf '%s\n' "$raw" 2>/dev/null || true
        printf '%s\n' "$raw" | head -1 | grep -q '^+OK' 2>/dev/null || return 1
        return 0
    elif [ "$transport" = "ssh-unix" ]; then
        local raw
        raw=$(printf '%s\r\n' "$cmd" | $_SSH freebsd@localhost \
            "nc -w${nc_timeout} -U $AGENT_SOCK" 2>/dev/null \
            | awk '/^\.$/{exit} {print}')
        printf '%s\n' "$raw" 2>/dev/null || true
        printf '%s\n' "$raw" | head -1 | grep -q '^+OK' 2>/dev/null || return 1
        return 0
    else
        printf -- '-ERR vport transport unavailable; ssh fallback disabled (set AGENT_ALLOW_SSH=1 to allow ssh)\n'
        return 1
    fi
}

# File transfer over the vport (binary-safe, no scp/ssh needed). Requires the
# python client + a proto>=2 guest agent (PUT/GET verbs).
# agent_put LOCAL REMOTE — upload a host file to the guest.
agent_put() {
    local local_f="${1:?usage: agent_put LOCAL REMOTE}"
    local remote_f="${2:?usage: agent_put LOCAL REMOTE}"
    if ! _vport_has_py; then printf -- '-ERR agent_put needs python3 + vport-client.py\n'; return 1; fi
    if [ ! -S "$AGENT_VPORT_SOCK" ]; then printf -- '-ERR vport socket not present\n'; return 1; fi
    "$PYTHON" "$VPORT_CLIENT" put "$AGENT_VPORT_SOCK" "$local_f" "$remote_f" --idle "${AGENT_XFER_TIMEOUT:-120}"
}
# agent_get REMOTE LOCAL — download a guest file to the host.
agent_get() {
    local remote_f="${1:?usage: agent_get REMOTE LOCAL}"
    local local_f="${2:?usage: agent_get REMOTE LOCAL}"
    if ! _vport_has_py; then printf -- '-ERR agent_get needs python3 + vport-client.py\n'; return 1; fi
    if [ ! -S "$AGENT_VPORT_SOCK" ]; then printf -- '-ERR vport socket not present\n'; return 1; fi
    "$PYTHON" "$VPORT_CLIENT" get "$AGENT_VPORT_SOCK" "$remote_f" "$local_f" --idle "${AGENT_XFER_TIMEOUT:-120}"
}

# Утилиты (вывод идёт вызывающему через agent_cmd)
agent_ping()            { agent_cmd "PING"; }
agent_status()          { agent_cmd "STATUS"; }
agent_jail_setup()      { agent_cmd "JAIL_SETUP"; }
agent_jail_teardown()   { agent_cmd "JAIL_TEARDOWN"; }
agent_hal_start()       { agent_cmd "HAL_START"; }
agent_broker_start()    { agent_cmd "BROKER_START"; }
agent_lifecycle_start() { agent_cmd "LIFECYCLE_START"; }
agent_build_broker()    { agent_cmd "BUILD_BROKER"; }
agent_build_app()       { agent_cmd "BUILD_APP"; }
agent_mem_status()      { agent_cmd "MEM_STATUS"; }
agent_jls()             { agent_cmd "JLS"; }

agent_freeze() {
    local jail="${1:?usage: agent_freeze JAIL}"
    agent_cmd "FREEZE $jail"
}
agent_thaw() {
    local jail="${1:?usage: agent_thaw JAIL}"
    agent_cmd "THAW $jail"
}

agent_mem_guard() {
    local state="${1:-status}"
    agent_cmd "MEM_GUARD $state"
}

# Проверить что jail реально существует (через JLS команду агента).
# jls -v выводит имя джейла с отступом, поэтому grep без ^ якоря.
agent_check_jail() {
    agent_cmd "JLS" 2>/dev/null | grep -qw "$1"
}

# Общее выполнение команды внутри VM (без SSH round-trip)
# agent_exec: ждёт завершения (nc timeout = длина команды + 2s, default 30s)
agent_exec()    { agent_cmd "EXEC $*" "${AGENT_EXEC_TIMEOUT:-30}"; }
agent_exec_bg() { agent_cmd "EXEC_BG $*"; }  # возвращает немедленно

# Wayland стек
agent_wayland_start()  { agent_cmd "WAYLAND_START"; }
agent_wayland_status() { agent_cmd "WAYLAND_STATUS"; }
