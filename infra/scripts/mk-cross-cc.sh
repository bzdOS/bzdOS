#!/bin/sh
# mk-cross-cc.sh — generate a clang cross-linker wrapper for Rust -Z build-std
#
# Usage: mk-cross-cc.sh <arch> <sysroot> <output>
#
# The wrapper invokes the host clang with --target + --sysroot + -fuse-ld=lld
# so Rust can cross-link for aarch64-freebsd using the host's toolchain.
set -eu

ARCH="$1"
SYSROOT="$2"
OUTPUT="$3"

case "$ARCH" in
    aarch64)
        TARGET="aarch64-unknown-freebsd14.1"
        ;;
    amd64|x86_64)
        TARGET="x86_64-unknown-freebsd14.1"
        ;;
    *)
        echo "Unsupported arch: $ARCH" >&2
        exit 1
        ;;
esac

mkdir -p "$(dirname "$OUTPUT")"

cat > "$OUTPUT" <<WRAPPER
#!/bin/sh
exec clang --target=$TARGET --sysroot=$SYSROOT -fuse-ld=lld "\$@"
WRAPPER
chmod +x "$OUTPUT"
echo "Cross-linker wrapper: $OUTPUT (target=$TARGET, sysroot=$SYSROOT)"
