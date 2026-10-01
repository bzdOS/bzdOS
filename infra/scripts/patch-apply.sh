#!/bin/sh
set -eu

. "$(dirname "$0")/_ssh.sh"

echo "[patch-apply] Copying KERNCONF files to guest..."

# Create target directories in guest
ssh_root "mkdir -p /usr/src/sys/amd64/conf /usr/src/sys/arm64/conf"

# Copy KERNCONF files
for conf in "$(dirname "$0")"/../../kernel/BSDOS-*; do
    if test -f "$conf"; then
        basename=$(basename "$conf")
        arch=$(echo "$basename" | sed 's/BSDOS-//')

        case "$arch" in
            amd64)
                echo "  Copying $basename to amd64/conf/"
                scp_freebsd "$conf" "/tmp/$basename"
                ssh_root "cp /tmp/$basename /usr/src/sys/amd64/conf/$basename"
                ;;
            arm64)
                echo "  Copying $basename to arm64/conf/"
                scp_freebsd "$conf" "/tmp/$basename"
                ssh_root "cp /tmp/$basename /usr/src/sys/arm64/conf/$basename"
                ;;
        esac
    fi
done

# Apply patches if any exist
PATCH_COUNT=$(find "$(dirname "$0")"/../../kernel -name "*.patch" -type f 2>/dev/null | wc -l)

if test $PATCH_COUNT -gt 0; then
    echo "[patch-apply] Found $PATCH_COUNT patch(es) — applying..."
    find "$(dirname "$0")"/../../kernel -name "*.patch" -type f -print0 | while IFS= read -r -d '' patch; do
        basename=$(basename "$patch")
        echo "  Applying $basename..."
        scp_freebsd "$patch" "/tmp/$basename"
        ssh_root "cd /usr/src && git apply /tmp/$basename"
    done
else
    echo "[patch-apply] no patches to apply"
fi

echo "[patch-apply] Done"
