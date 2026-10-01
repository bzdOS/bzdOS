#!/bin/sh
# bsdOS Mac Companion Setup
# Installs and builds telemetry-client on Mac/Linux host
#
# Usage:
#   ./mac-setup.sh                          # auto-detect BSDOS_IP
#   BSDOS_IP=192.168.1.42 ./mac-setup.sh   # explicit phone IP
#
# Environment:
#   BSDOS_IP     — phone IP or hostname (default: localhost)
#   BSDOS_PORT   — Zenoh port (default: 7447)
#   INSTALL_PATH — bin symlink location (default: /usr/local/bin)

set -eu

# Defaults
BSDOS_IP="${BSDOS_IP:-localhost}"
BSDOS_PORT="${BSDOS_PORT:-7447}"
INSTALL_PATH="${INSTALL_PATH:-/usr/local/bin}"

# Detect script directory
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
BSDOS_DIR="$(dirname "$(dirname "$SCRIPT_DIR")")"

COLOR_BOLD='\033[1m'
COLOR_GREEN='\033[32m'
COLOR_BLUE='\033[34m'
COLOR_RESET='\033[0m'

log() {
    printf "%b%s%b\n" "$COLOR_BLUE===$COLOR_RESET " "$1" ""
}

success() {
    printf "%b✓ %s%b\n" "$COLOR_GREEN" "$1" "$COLOR_RESET"
}

error() {
    printf "✗ %s\n" "$1" >&2
    exit 1
}

# ─────────────────────────────────────────────────────────────────────────────

log "bsdOS Mac Companion Setup"
echo ""
echo "Target device: $BSDOS_IP:$BSDOS_PORT"
echo "Install path: $INSTALL_PATH"
echo ""

# ─────────────────────────────────────────────────────────────────────────────
# 1. Check Rust
# ─────────────────────────────────────────────────────────────────────────────

if ! command -v cargo >/dev/null 2>&1; then
    log "Installing Rust..."
    if [ "$(uname)" = "Darwin" ]; then
        # macOS — use Homebrew or rustup
        if command -v brew >/dev/null 2>&1; then
            brew install rust
            success "Rust installed via Homebrew"
        else
            curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
            . "$HOME/.cargo/env"
            success "Rust installed via rustup"
        fi
    else
        # Linux
        curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
        . "$HOME/.cargo/env"
        success "Rust installed via rustup"
    fi
else
    success "Rust $(cargo --version | cut -d' ' -f2) found"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 2. Build telemetry-client
# ─────────────────────────────────────────────────────────────────────────────

log "Building telemetry-client..."
cd "$BSDOS_DIR/telemetry-client" || error "telemetry-client not found"
cargo build --release 2>&1 | tail -3
success "telemetry-client built: $BSDOS_DIR/telemetry-client/target/release/telemetry-client"

# ─────────────────────────────────────────────────────────────────────────────
# 3. Symlink binaries (optional, requires sudo for /usr/local/bin)
# ─────────────────────────────────────────────────────────────────────────────

if [ -w "$INSTALL_PATH" ]; then
    log "Installing symlinks to $INSTALL_PATH..."
    ln -sf "$BSDOS_DIR/telemetry-client/target/release/telemetry-client" "$INSTALL_PATH/telemetry-client"
    success "Symlinks created"
else
    log "Skipping symlink install (no write permission to $INSTALL_PATH)"
    echo ""
    echo "To install symlinks manually:"
    echo "  sudo ln -sf $BSDOS_DIR/telemetry-client/target/release/telemetry-client $INSTALL_PATH/"
fi

# ─────────────────────────────────────────────────────────────────────────────
# 4. Summary
# ─────────────────────────────────────────────────────────────────────────────

echo ""
log "Setup Complete!"
echo ""
echo "$COLOR_BOLD=== Telemetry Monitor ===$COLOR_RESET"
echo "  # Watch battery, CPU, uptime in real-time"
echo "  $INSTALL_PATH/telemetry-client --peer tcp/$BSDOS_IP:$BSDOS_PORT"
echo ""
echo "$COLOR_BOLD=== Chrome DevTools Inspector ===$COLOR_RESET"
echo "  1. On device: make phantom-start"
echo "  2. On Mac: chrome://inspect"
echo "  3. Add: $BSDOS_IP:9222"
echo ""
echo "For more info, see: $BSDOS_DIR/PLAN-mac-companion.md"
