#!/bin/sh
set -eu

## MAKE-TARGETS ##
# jpk-build: SRCDIR=$(SRCDIR) OUTFILE=$(OUTFILE) $(SCRIPTS)/jpk.sh build $(SRCDIR) $(OUTFILE)
# jpk-install: PKGFILE=$(PKGFILE) $(SCRIPTS)/jpk.sh install $(PKGFILE)
# jpk-info: PKGFILE=$(PKGFILE) $(SCRIPTS)/jpk.sh info $(PKGFILE)
# jpk-list: $(SCRIPTS)/jpk.sh list
## END-MAKE-TARGETS ##

# bsdOS .jpk (jail package) manager
# Formats: .jpk is tar.zst with META/manifest.json + rootfs/ + data/ + hooks/

PROGNAME="$(basename "$0")"
SCRIPTS_DIR="$(dirname "$0")"

# Source agent transport layer
. "${SCRIPTS_DIR}/_agent.sh"

# Проверить наличие команд
_check_tools() {
    local tools="tar zstd"
    for tool in $tools; do
        if ! command -v "$tool" >/dev/null 2>&1; then
            echo "Error: '$tool' not found in PATH" >&2
            return 1
        fi
    done
}

# Вывести справку
_usage() {
    cat >&2 << 'EOF'
Usage: jpk.sh [COMMAND] [ARGS...]

Commands:
  build SRCDIR OUTFILE.jpk       Pack directory into .jpk archive (host-side)
  install PKGFILE.jpk            Install .jpk into jail (guest-side, requires root)
  info PKGFILE.jpk               Show manifest of .jpk file
  list                           List installed jails (guest-side)

Examples:
  jpk.sh build ./myapp /tmp/myapp-1.0.jpk
  jpk.sh install /tmp/myapp-1.0.jpk
  jpk.sh info /tmp/myapp-1.0.jpk
  jpk.sh list
EOF
    exit 1
}

# === BUILD (host-side, local) ===
# Упаковать директорию SRCDIR в .jpk архив
# Структура SRCDIR:
#   - META/manifest.json (обязательно)
#   - rootfs/ (опционально, содержимое jail)
#   - data/ (опционально, начальные данные для /opt/proto/data/{name}/)
#   - hooks/pre-install.sh (опционально)
#   - hooks/post-install.sh (опционально)
_cmd_build() {
    local srcdir="${1:?build: SRCDIR not provided}"
    local outfile="${2:?build: OUTFILE not provided}"

    if [ ! -d "$srcdir" ]; then
        echo "Error: source directory '$srcdir' not found" >&2
        return 1
    fi

    if [ ! -f "$srcdir/META/manifest.json" ]; then
        echo "Error: $srcdir/META/manifest.json not found" >&2
        return 1
    fi

    # Проверить что manifest.json валидный JSON (простая проверка)
    if ! grep -q '"name"' "$srcdir/META/manifest.json" 2>/dev/null; then
        echo "Error: $srcdir/META/manifest.json missing 'name' field" >&2
        return 1
    fi

    echo "Building .jpk: $outfile"
    echo "  Source: $srcdir"
    echo "  Format: tar.zst"

    # Создать tar.zst архив
    # Переходим в srcdir и архивируем содержимое относительно текущей директории
    (
        cd "$srcdir"
        tar --zstd -cf "$outfile" META/ rootfs/ data/ hooks/ 2>/dev/null || \
        tar --zstd -cf "$outfile" META/ $(ls -d rootfs data hooks 2>/dev/null | grep -v '^$') 2>/dev/null || \
        tar --zstd -cf "$outfile" META/ || true
    )

    if [ ! -f "$outfile" ]; then
        echo "Error: failed to create $outfile" >&2
        return 1
    fi

    local size
    size=$(ls -lh "$outfile" | awk '{print $5}')
    echo "Created: $outfile ($size)"
}

# === INSTALL (guest-side, via agent_exec) ===
# Распаковать .jpk в jail
_cmd_install() {
    local pkgfile="${1:?install: PKGFILE not provided}"

    if [ ! -f "$pkgfile" ]; then
        echo "Error: package file '$pkgfile' not found" >&2
        return 1
    fi

    echo "Installing .jpk: $pkgfile"

    # Получить имя приложения из META/manifest.json
    local appname
    appname=$(tar --zstd -xOf "$pkgfile" META/manifest.json 2>/dev/null | \
              grep -o '"name"\s*:\s*"[^"]*"' | cut -d'"' -f4 || true)

    if [ -z "$appname" ]; then
        echo "Error: could not extract 'name' from manifest" >&2
        return 1
    fi

    echo "  App name: $appname"

    # Скопировать файл на гост (если нужно) — для больших файлов
    # Но обычно .jpk создаётся на хосте или уже на гесте
    local guest_pkgfile="/tmp/jpk-install-$$.tar.zst"

    echo "  Copying to guest..."

    # Копируем файл в /tmp на гесте (через socat/SSH)
    # Используем agent_exec для создания архива прямо в директории установки
    local install_script=$(cat << 'EOSCRIPT'
set -e
APPNAME="$1"
PKGFILE="$2"

echo "Preparing directories for $APPNAME..."
mkdir -p /opt/proto/jails/"$APPNAME"
mkdir -p /opt/proto/data/"$APPNAME"

echo "Extracting rootfs..."
if tar --zstd -tf "$PKGFILE" 2>/dev/null | grep -q '^rootfs/'; then
    tar --zstd -xf "$PKGFILE" --strip-components=1 -C /opt/proto/jails/"$APPNAME" rootfs/ 2>/dev/null || true
fi

echo "Extracting data..."
if tar --zstd -tf "$PKGFILE" 2>/dev/null | grep -q '^data/'; then
    tar --zstd -xf "$PKGFILE" --strip-components=1 -C /opt/proto/data/"$APPNAME" data/ 2>/dev/null || true
fi

if [ -f /opt/proto/jails/"$APPNAME"/post-install.sh ]; then
    echo "Running post-install hook..."
    chmod +x /opt/proto/jails/"$APPNAME"/post-install.sh
    sh /opt/proto/jails/"$APPNAME"/post-install.sh
fi

echo "Installation complete for $APPNAME"
EOSCRIPT
)

    echo "  Running guest install..."
    agent_exec "$install_script" "$appname" "$pkgfile" || {
        echo "Error: guest-side installation failed" >&2
        return 1
    }

    echo "Package installed: $appname"
}

# === INFO ===
# Показать содержимое manifest.json из .jpk
_cmd_info() {
    local pkgfile="${1:?info: PKGFILE not provided}"

    if [ ! -f "$pkgfile" ]; then
        echo "Error: package file '$pkgfile' not found" >&2
        return 1
    fi

    echo "Package: $pkgfile"
    echo "---"
    tar --zstd -xOf "$pkgfile" META/manifest.json 2>/dev/null || {
        echo "Error: failed to extract META/manifest.json" >&2
        return 1
    }
}

# === LIST ===
# Показать установленные jails (на гесте)
_cmd_list() {
    echo "Installed jails:"
    agent_exec "ls -1 /opt/proto/jails/ 2>/dev/null || echo 'No jails found'" || true
}

# === MAIN ===
main() {
    _check_tools || return 1

    local cmd="${1:-}"
    case "$cmd" in
        build)
            shift || _usage
            _cmd_build "$@"
            ;;
        install)
            shift || _usage
            _cmd_install "$@"
            ;;
        info)
            shift || _usage
            _cmd_info "$@"
            ;;
        list)
            shift || true
            _cmd_list "$@"
            ;;
        ""|help|-h|--help)
            _usage
            ;;
        *)
            echo "Error: unknown command '$cmd'" >&2
            _usage
            ;;
    esac
}

main "$@"
