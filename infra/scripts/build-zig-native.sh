#!/bin/sh
set -eu

# Build Zig HAL daemon natively (for testing on Linux host)
SCRIPT_DIR="$(dirname "$0")"
PROJECT_DIR="$(cd "$SCRIPT_DIR/../.." && pwd)"
ZIG_DIR="$PROJECT_DIR/hal"

echo "Building bsdos-hal natively..."
cd "$ZIG_DIR"

zig build -Doptimize=ReleaseSafe

if [ -f zig-out/bin/bsdos-hal ]; then
    echo "✓ Built: $ZIG_DIR/zig-out/bin/bsdos-hal"
else
    echo "✗ Build failed: no binary produced"
    exit 1
fi
