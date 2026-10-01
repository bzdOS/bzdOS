#!/bin/sh
set -eu

# Cross-compile Zig HAL daemon for aarch64-freebsd.14
ZIG="${ZIG:-zig}"
SCRIPT_DIR="$(dirname "$0")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ZIG_DIR="$PROJECT_DIR/sys-daemon-zig"

echo "Building bsdos-hal for aarch64-freebsd.14..."
cd "$ZIG_DIR"

"$ZIG" build \
    -Dtarget=aarch64-freebsd.14.0 \
    -Doptimize=ReleaseSafe

if [ -f zig-out/bin/bsdos-hal ]; then
    echo "✓ Built: $ZIG_DIR/zig-out/bin/bsdos-hal"
else
    echo "✗ Build failed: no binary produced"
    exit 1
fi
