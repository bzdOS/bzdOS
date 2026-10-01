#!/bin/sh
set -eu
. "$(dirname "$0")/_ssh.sh"

echo "=== Installing nightly Rust in VM ==="

# Install rustup if needed and set up nightly in a single session
ssh_guest "
set -e
echo '[1/4] Checking current Rust...'
rustc --version

echo '[2/4] Installing rustup and nightly toolchain...'
if ! command -v rustup >/dev/null 2>&1; then
    echo '  → downloading rustup...'
    curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y 2>&1 | grep -E '(Installed|installed|complete)' || true
    . \"\$HOME/.cargo/env\" 2>/dev/null || true
fi

echo '[3/4] Installing nightly toolchain...'
. \"\$HOME/.cargo/env\" 2>/dev/null || true
rustup toolchain install nightly --allow-downgrade 2>&1 | tail -5

echo '[4/4] Setting nightly as default...'
rustup default nightly 2>&1 | grep -E '(default|Updating|Toolchain)' || true

echo ''
echo '[verification] Rust setup complete:'
rustc --version
cargo --version
" 2>&1 | tail -30

echo "=== nightly Rust installation complete ==="
