#!/bin/sh
# bsdos-build.sh — bsdOS multi-machine rootfs build orchestrator
# Per SPEC_squirrel_rootfs.md §4-§5, §11.1 (internal task).
#
# Usage:  bsdos-build.sh <machine>
#   <machine> ∈ { qemu-amd64, qemu-aarch64, bpi-m64, pinephone-pro }
#   Back-compat aliases:  amd64 → qemu-amd64,  aarch64 → qemu-aarch64
#
# A "machine" subsumes arch + kernconf + platform-flag + pkgset. The single
# source of truth is infra/machines.conf (machine_resolve <machine>).
#
# 7 stages:
#   1. FreeBSD base.txz fetch + extract
#   2. pkg install (from infra/pkgsets/<pkgset>.txt)
#   3. Cross-compile Rust (bsdos-core, bsdos_lifecycled)
#   4. Cross-compile Zig (bsdos-hal, wayland-tunnel)
#   5. Stage config files + .jpk registry
#   6. mkimg(8) → raw disk image → gzip -9
#   7. (optional smoke — see squirrel-smoke.sh)
#
# Caching: ~/.cache/bsdos-build/<arch>/ keyed by FreeBSD release version.
# Idempotent: re-running skips stages whose output already exists.
set -eu

# Ensure build tools are reachable under the agent's minimal PATH.
# /.cargo/bin must come BEFORE /usr/local/bin: the port's standalone cargo
# does not support `+toolchain` directives; only rustup's cargo does.
# FreeBSD ports (zig, clang, pkg) live in /usr/local/bin.
HOME="${HOME:-/}"
PATH="$HOME/.cargo/bin:/usr/local/bin:/usr/local/sbin:$PATH"
export PATH HOME

# ── Args: resolve <machine> → arch/kernconf/platform/pkgset ──────────────────
BSDOS_DIR="${BSDOS_DIR:-$(cd "$(dirname "$0")/../.." && pwd)}"

MACHINE="${1:-}"
# Back-compat aliases so the current dev loop + CI keep working.
case "$MACHINE" in
    amd64)   MACHINE="qemu-amd64"   ;;
    aarch64) MACHINE="qemu-aarch64" ;;
esac
if [ -z "$MACHINE" ]; then
    echo "Usage: $0 <machine>" >&2
    echo "  machines: qemu-amd64 qemu-aarch64 bpi-m64 pinephone-pro" >&2
    echo "  aliases:  amd64 → qemu-amd64,  aarch64 → qemu-aarch64" >&2
    exit 1
fi

# shellcheck source=../machines.conf
. "$BSDOS_DIR/infra/machines.conf"
machine_resolve "$MACHINE" || {
    echo "Usage: $0 <machine>" >&2
    echo "  machines: qemu-amd64 qemu-aarch64 bpi-m64 pinephone-pro" >&2
    exit 1
}

# machine_resolve exports M_ARCH M_KERNCONF M_PLATFORM M_PKGSET.
# ARCH stays the working variable name across all stages (was the old $1).
ARCH="$M_ARCH"
KERNCONF="$M_KERNCONF"
PLATFORM="$M_PLATFORM"
PKGSET="$M_PKGSET"

_default_cache="$HOME/.cache/bsdos-build"
# Normalize: HOME=/ on FreeBSD root gives //.cache → resolve to /.cache
_default_cache="$(printf '%s' "$_default_cache" | sed 's|//|/|g')"
CACHE_DIR="${CACHE_DIR:-$_default_cache}"
WORK="${WORK:-$CACHE_DIR/$ARCH/work}"
ARTEFACTS="${ARTEFACTS:-$BSDOS_DIR/artefacts}"
FREEBSD_VER="${FREEBSD_VER:-15.1-RELEASE}"
BSDOS_VER="${BSDOS_VER:-$(git -C "$BSDOS_DIR" describe --tags --abbrev=0 2>/dev/null | sed 's/^v//' || echo "dev")}"
IMG_NAME="bsdos-v${BSDOS_VER}-${ARCH}"
IMG_RAW="${WORK}/${IMG_NAME}.img"
IMG_GZ="${ARTEFACTS}/${IMG_NAME}.img.gz"

# FreeBSD download URL (amd64 → amd64/, aarch64 → arm64/)
if [ "$ARCH" = "amd64" ]; then
    FREEBSD_ARCH="amd64"
    FREEBSD_KERNEL_ARCH="amd64"
else
    FREEBSD_ARCH="arm64"
    FREEBSD_KERNEL_ARCH="arm64"
fi
BASE_URL="https://download.freebsd.org/releases/${FREEBSD_ARCH}/${FREEBSD_VER}"
BASE_TXZ="${CACHE_DIR}/${ARCH}/base.txz"

# Per-arch RUST_TARGET + ZIG_TARGET
RUST_TARGET_AMD64="x86_64-unknown-freebsd"
RUST_TARGET_AARCH64="aarch64-unknown-freebsd"
ZIG_TARGET_AMD64="x86_64-freebsd.15.1"
ZIG_TARGET_AARCH64="aarch64-freebsd.15.1"

log() { printf '\033[1;32m[ bsdos-build %s ]\033[0m %s\n' "$MACHINE" "$*"; }
err() { printf '\033[1;31m[ ERROR ]\033[0m %s\n' "$*" >&2; exit 1; }

mkdir -p "$CACHE_DIR/$ARCH" "$WORK/rootfs" "$ARTEFACTS"

# ── Stage 1: FreeBSD base + kernel fetch + extract ──────────────────────────
stage1_base() {
    log "Stage 1/6: FreeBSD ${FREEBSD_VER} base.txz + kernel.txz"
    BASE_TXZ="${CACHE_DIR}/${ARCH}/base.txz"
    KERNEL_TXZ="${CACHE_DIR}/${ARCH}/kernel.txz"

    # Helper: fetch a release file (fetch/wget/curl fallback)
    _fetch() { # _fetch <url> <dest>
        fetch -o "$2" "$1" || wget -O "$2" "$1" || curl -fL -o "$2" "$1" || \
            err "Failed to download $1"
    }

    [ -f "$BASE_TXZ" ]   || { log "  Downloading base.txz ...";   _fetch "${BASE_URL}/base.txz"   "$BASE_TXZ"; }
    [ -f "$KERNEL_TXZ" ] || { log "  Downloading kernel.txz ..."; _fetch "${BASE_URL}/kernel.txz" "$KERNEL_TXZ"; }

    if [ ! -f "$WORK/rootfs/COPYRIGHT" ]; then
        log "  Extracting base.txz → $WORK/rootfs/"
        tar -xf "$BASE_TXZ" -C "$WORK/rootfs/"
    else
        log "  Already extracted: base.txz"
    fi
    if [ ! -f "$WORK/rootfs/boot/kernel/kernel" ]; then
        log "  Extracting kernel.txz → $WORK/rootfs/"
        tar -xf "$KERNEL_TXZ" -C "$WORK/rootfs/"
    else
        log "  Already extracted: kernel.txz"
    fi

    # Kernel selection is driven by $KERNCONF (from machine_resolve):
    #   GENERIC          → use the GENERIC kernel already extracted from
    #                      kernel.txz; do NOT buildkernel. Custom kernels are a
    #                      phase-2 optimization, not a bring-up requirement.
    #   <custom KERNCONF> → buildkernel + installkernel into the rootfs.
    if [ "$KERNCONF" = "GENERIC" ]; then
        log "  Kernel: GENERIC (from kernel.txz) — skipping buildkernel"
        if [ ! -f "$WORK/rootfs/boot/kernel/kernel" ]; then
            err "GENERIC kernel missing at $WORK/rootfs/boot/kernel/kernel (kernel.txz extract failed?)"
        fi
        return 0
    fi

    # Build custom kernel optimized for QEMU (strip ~90 unused drivers)
    log "  Building custom kernel ${KERNCONF} (QEMU-optimized)..."
    KERNDIR="$BSDOS_DIR/freebsd-patches/conf"
    _built=0
    if command -v make >/dev/null 2>&1 && [ -d /usr/src ]; then
        cd /usr/src
        if [ "$ARCH" = "amd64" ]; then
            if make -j"$(nproc)" buildkernel \
                    KERNCONF="$KERNCONF" KERNCONFDIR="$KERNDIR" 2>&1 | tail -10 && \
               make installkernel DESTDIR="$WORK/rootfs" \
                    KERNCONF="$KERNCONF" KERNCONFDIR="$KERNDIR"; then
                _built=1
            else
                log "  WARN: custom kernel build failed — falling back to GENERIC from kernel.txz"
            fi
        else
            if make -j"$(nproc)" buildkernel TARGET=arm64 \
                    KERNCONF="$KERNCONF" KERNCONFDIR="$KERNDIR" 2>&1 | tail -10 && \
               make installkernel DESTDIR="$WORK/rootfs" TARGET=arm64 \
                    KERNCONF="$KERNCONF" KERNCONFDIR="$KERNDIR"; then
                _built=1
            else
                log "  WARN: custom kernel build failed — falling back to GENERIC from kernel.txz"
            fi
        fi
        cd "$BSDOS_DIR"
        # Strip debug symbols from kernel
        if [ "$_built" = "1" ] && [ -f "$WORK/rootfs/boot/kernel/kernel" ]; then
            strip -s "$WORK/rootfs/boot/kernel/kernel" 2>/dev/null || true
            KSIZE=$(du -h "$WORK/rootfs/boot/kernel/kernel" | awk '{print $1}')
            log "  Custom kernel installed (${KSIZE})"
        fi
    else
        log "  SKIP: no /usr/src or make — using GENERIC kernel from kernel.txz"
    fi
}

# ── Stage 2: pkg install ───────────────────────────────────────────────────
stage2_pkg() {
    log "Stage 2/6: pkg install (pkgset: $PKGSET)"
    if [ -f "$WORK/rootfs/.bsdos-pkg-done" ]; then
        log "  Already installed: $WORK/rootfs/.bsdos-pkg-done"
        return 0
    fi

    # Package list comes from infra/pkgsets/<pkgset>.txt (one pkg/line, # comment).
    PKGSET_FILE="$BSDOS_DIR/infra/pkgsets/${PKGSET}.txt"
    [ -f "$PKGSET_FILE" ] || err "pkgset manifest not found: $PKGSET_FILE"
    # Strip comments + blank lines into a space-separated list.
    PKG_PKGS=$(sed -e 's/#.*//' "$PKGSET_FILE" | awk 'NF')
    log "  Packages ($PKGSET): $PKG_PKGS"

    if [ -z "$PKG_PKGS" ]; then
        log "  pkgset $PKGSET is empty — nothing to install"
        touch "$WORK/rootfs/.bsdos-pkg-done"
        return 0
    fi

    # chroot needs DNS — copy host resolv.conf so pkg can reach the repo
    cp /etc/resolv.conf "$WORK/rootfs/etc/resolv.conf" 2>/dev/null || true

    if [ "$ARCH" = "aarch64" ]; then
        # Can't chroot into aarch64 rootfs on amd64 — use host pkg with ABI override
        # Configure the aarch64 repo URL in the rootfs
        mkdir -p "$WORK/rootfs/usr/local/etc/pkg/repos"
        cat > "$WORK/rootfs/usr/local/etc/pkg/repos/freebsd.conf" <<REPO
FreeBSD: {
  url: "pkg+https://pkg.FreeBSD.org/FreeBSD:15:aarch64/quarterly";
  mirror_type: "srv";
  enabled: yes;
}
REPO
        log "  Cross-arch pkg: ABI=FreeBSD:15:aarch64 --rootdir $WORK/rootfs"
        # Install packages individually — some (zenoh, wpewebkit-fdo) may not
        # have aarch64 builds yet; don't let one missing pkg abort the rest.
        for pkg in $PKG_PKGS; do
            sudo env ABI="FreeBSD:15:aarch64" OSVERSION="1500000" \
                pkg --rootdir "$WORK/rootfs" install -y "$pkg" 2>/dev/null || \
                log "  SKIP: $pkg not available for aarch64"
        done
    elif command -v pkg-static >/dev/null 2>&1 || command -v pkg >/dev/null 2>&1; then
        _pkg="$(command -v pkg-static 2>/dev/null || command -v pkg)"
        log "  Installing via $_pkg -c $WORK/rootfs ..."
        # Install packages individually — zenoh/wpewebkit may not be in repo;
        # don't let one missing pkg abort cage/foot.
        for pkg in $PKG_PKGS; do
            sudo env PATH="/usr/local/sbin:/usr/local/bin:/sbin:/bin:/usr/sbin:/usr/bin" \
                "$_pkg" -c "$WORK/rootfs" install -y "$pkg" 2>/dev/null || \
                log "  SKIP: $pkg not available for ${ARCH}"
        done
    else
        log "  SKIP: no pkg/pkg-static — packages will be installed at first boot"
    fi
    touch "$WORK/rootfs/.bsdos-pkg-done"
}

# ── Stage 3+4: Cross-compile Rust + Zig components ─────────────────────────
stage345_build() {
    log "Stage 3-4/6: Cross-compile bsdos-core + lifecycled (Rust) + bsdos-hal + wayland-tunnel (Zig)"
    # The Makefile uses GNU make syntax ($(CURDIR), :=, $(shell)).
    # FreeBSD ships bmake which does not define CURDIR as a built-in (it uses .CURDIR).
    # Pass CURDIR explicitly so $(CURDIR) in the Makefile resolves to $BSDOS_DIR
    # regardless of whether the invoker is gmake or bmake.
    MAKE="$(command -v gmake || command -v make)"
    log "  Calling: $MAKE cross-squirrel-${ARCH} (platform=$PLATFORM)"

    # Platform wiring (machine_resolve → build):
    #   Rust: BSDOS_PLATFORM env (cargo inherits the exported env).
    #   Zig : -Dplatform=$PLATFORM, threaded via the ZIG_PLATFORM_FLAG make var.
    export BSDOS_PLATFORM="$PLATFORM"
    ZIG_PLATFORM_FLAG="-Dplatform=$PLATFORM"

    if [ "$ARCH" = "aarch64" ]; then
        # The rootfs (with aarch64 libc from base.txz) doubles as the sysroot
        # for the Rust cross-linker (clang --sysroot).
        # Normalize double-slash: HOME=/ on FreeBSD root gives //.cache → /.cache
        _sysroot="$(printf '%s/rootfs' "$WORK" | sed 's|//|/|g')"
        "$MAKE" -C "$BSDOS_DIR" cross-squirrel-${ARCH} \
            CURDIR="$BSDOS_DIR" \
            AARCH64_SYSROOT="$_sysroot" \
            BSDOS_PLATFORM="$PLATFORM" \
            ZIG_PLATFORM_FLAG="$ZIG_PLATFORM_FLAG" || \
            err "Cross-compile failed for ${ARCH}. Check toolchain (rust nightly + zig)."
    else
        "$MAKE" -C "$BSDOS_DIR" cross-squirrel-${ARCH} \
            CURDIR="$BSDOS_DIR" \
            BSDOS_PLATFORM="$PLATFORM" \
            ZIG_PLATFORM_FLAG="$ZIG_PLATFORM_FLAG" || \
            err "Cross-compile failed for ${ARCH}. Check toolchain (rust nightly + zig)."
    fi
    log "  Cross-compile succeeded"

    # Stage compiled binaries into rootfs
    # NOTE: bsdos-pkgd (.jpk package manager CLI) must also be cross-built into
    #   $BIN_SRC by the Makefile cross-squirrel-${ARCH} target (add `-p bsdos-pkgd`
    #   to its cargo invocation). It lands at /opt/bsdos/bin/bsdos-pkgd so the image
    #   has the .jpk install/inspect/verify tool on PATH at runtime. Missing binaries
    #   only WARN here (non-fatal); stage5c_verify gates the truly-critical ones.
    BIN_SRC="$ARTEFACTS/squirrel/${ARCH}/bin"
    BIN_DST="$WORK/rootfs/opt/bsdos/bin"
    mkdir -p "$BIN_DST"
    for bin in bsdos-core bsdos-lifecycled bsdos-pkgd bsdos-run bsdos-hal wayland-tunnel bsdos-agent; do
        if [ -f "$BIN_SRC/$bin" ]; then
            cp "$BIN_SRC/$bin" "$BIN_DST/$bin"
            log "  Staged: $bin"
        else
            log "  WARN: $bin not found at $BIN_SRC — component may not be built yet"
        fi
    done

    # Symlinks: stream_manager expects wayland-tunnel at /usr/local/bin/
    #           rc.d/bsdos_agent expects bsdos-agent at /usr/local/bin/
    #           bsdos-pkgd is invoked as a bare CLI name → expose on /usr/local/bin too
    mkdir -p "$WORK/rootfs/usr/local/bin"
    for bin in wayland-tunnel bsdos-agent bsdos-pkgd bsdos-run; do
        ln -sf "/opt/bsdos/bin/$bin" "$WORK/rootfs/usr/local/bin/$bin"
    done
 }

# ── Stage 5: Stage config files + .jpk registry ────────────────────────────
stage5_configs() {
    log "Stage 5/6: Stage config files + .jpk registry"

    # bsdOS config dir
    mkdir -p "$WORK/rootfs/etc/bsdOS"
    if [ -d "$BSDOS_DIR/infra/etc-bsdOS" ]; then
        cp -r "$BSDOS_DIR/infra/etc-bsdOS/." "$WORK/rootfs/etc/bsdOS/"
        log "  Copied: infra/etc-bsdOS/ → /etc/bsdOS/"
    else
        log "  WARN: infra/etc-bsdOS/ not found — generating minimal configs"
        _gen_minimal_configs
    fi

    # Serial console — kernel + loader output to ttyu0 (QEMU -serial)
    cat > "$WORK/rootfs/boot/loader.conf.local" <<'EOF'
# bsdOS Squirrel — serial console for QEMU smoke (COM1/ttyu0)
console="comconsole"
boot_serial="YES"
beastie_disable="YES"
# Root on virtio-blk GPT partition 2 (UFS); tells kernel where to mount /
vfs.root.mountfrom="ufs:/dev/vtbd0p2"
EOF
    log "  Wrote: /boot/loader.conf.local (serial console)"

    # /etc/fstab — root + swap so rc runs fsck and mounts R/W
    cat > "$WORK/rootfs/etc/fstab" <<'EOF'
# bsdOS Squirrel — /etc/fstab (virtio-blk GPT)
/dev/vtbd0p2  /         ufs   rw,noatime  1 1
/dev/vtbd0p3  none      swap  sw          0 0
EOF
    log "  Wrote: /etc/fstab"

    # rc.conf — remove old bsdOS block, then append fresh (prevents triplication)
    sed -i '' '/^# ── bsdOS autostart/,/bsdos_agent_chardev/d' "$WORK/rootfs/etc/rc.conf" 2>/dev/null || true
    cat >> "$WORK/rootfs/etc/rc.conf" <<'EOF'

# ── bsdOS autostart (Squirrel demo image) ──────────────────────────────────
bsdos_core_enable="YES"
bsdos_lifecycled_enable="YES"
bsdos_hal_enable="YES"
bsdos_agent_enable="YES"
bsdos_agent_chardev="/dev/ttyV0.1"
EOF

    # rc.d scripts — enable rc.conf above needs a corresponding rc.d script
    mkdir -p "$WORK/rootfs/usr/local/etc/rc.d"

    # ── Phase 4: Structured config file sourced by rc.d ───────────────────
    mkdir -p "$WORK/rootfs/etc/bsdos"
    cat > "$WORK/rootfs/etc/bsdos/bsdos-core.conf" <<'CONF'
# bsdos-core runtime configuration (sourced by rc.d/bsdos_core)
BSDOS_AUTOSTREAM="${BSDOS_AUTOSTREAM:-appTerminal:foot,appBrowser:wpewebkit-fdo}"
BSDOS_ZENOH_LISTEN_IP="${BSDOS_ZENOH_LISTEN_IP:-0.0.0.0}"
BSDOS_ZENOH_LISTEN_PORT="${BSDOS_ZENOH_LISTEN_PORT:-7447}"
CONF

    cat > "$WORK/rootfs/usr/local/etc/rc.d/bsdos_core" <<'EOF'
#!/bin/sh
# PROVIDE: bsdos_core
# REQUIRE: FILESYSTEMS
# KEYWORD: shutdown
. /etc/rc.subr
name=bsdos_core
rcvar=bsdos_core_enable

: ${bsdos_core_conf="/etc/bsdos/bsdos-core.conf"}
[ -f "$bsdos_core_conf" ] && . "$bsdos_core_conf"

ZENOH_LISTEN_IP="${BSDOS_ZENOH_LISTEN_IP:-0.0.0.0}"
ZENOH_LISTEN_PORT="${BSDOS_ZENOH_LISTEN_PORT:-7447}"
export BSDOS_AUTOSTREAM ZENOH_LISTEN_IP ZENOH_LISTEN_PORT

load_rc_config $name
: ${bsdos_core_enable:="NO"}

bsdos_core_start() {
    if [ ! -x /opt/bsdos/bin/bsdos-core ]; then
        echo "${name}: /opt/bsdos/bin/bsdos-core not found"
        return 1
    fi
    pkill -f bsdos-core 2>/dev/null || true
    sleep 0.5
    echo "Starting ${name}..."
    /usr/sbin/daemon -p /var/run/bsdos-core.pid -r -o /var/log/bsdos-core.log \
        /opt/bsdos/bin/bsdos-core
    echo "${name} started"
}

bsdos_core_stop() {
    if [ -f /var/run/bsdos-core.pid ]; then
        kill $(cat /var/run/bsdos-core.pid) 2>/dev/null || true
        rm -f /var/run/bsdos-core.pid
    fi
    pkill -f bsdos-core 2>/dev/null || true
}

bsdos_core_status() {
    if [ -f /var/run/bsdos-core.pid ] && kill -0 $(cat /var/run/bsdos-core.pid) 2>/dev/null; then
        echo "${name} is running (pid $(cat /var/run/bsdos-core.pid))"
    else
        echo "${name} is not running"
    fi
}

start_cmd=bsdos_core_start
stop_cmd=bsdos_core_stop
status_cmd=bsdos_core_status

run_rc_command "$1"
EOF
    chmod 755 "$WORK/rootfs/usr/local/etc/rc.d/bsdos_core"
    log "  Wrote: /usr/local/etc/rc.d/bsdos_core"

    # rc.d/bsdos_agent — guest agent (virtio-console RPC, no Zenoh/network dependency)
    if [ -f "$BSDOS_DIR/infra/rc.d/bsdos_agent" ]; then
        cp "$BSDOS_DIR/infra/rc.d/bsdos_agent" "$WORK/rootfs/usr/local/etc/rc.d/bsdos_agent"
        chmod 755 "$WORK/rootfs/usr/local/etc/rc.d/bsdos_agent"
        log "  Wrote: /usr/local/etc/rc.d/bsdos_agent"
    else
        log "  WARN: infra/rc.d/bsdos_agent not found — agent will not auto-start"
    fi

    # .jpk registry mirror (offline mode)
    mkdir -p "$WORK/rootfs/opt/bsdos/share/jpk"
    JPK_DIR="$BSDOS_DIR/jpk-recipes"
    # Use freshly-built bsdos-pkgd from this arch's artefacts (host=amd64 can run amd64 binary)
    _pkgd="${ARTEFACTS}/squirrel/amd64/bin/bsdos-pkgd"
    [ ! -x "$_pkgd" ] && _pkgd="$(command -v bsdos-pkgd 2>/dev/null || true)"
    if [ -x "$_pkgd" ]; then
        for _recipe in phantom-browser foot; do
            if [ -d "$JPK_DIR/$_recipe/payload" ]; then
                _out="$WORK/rootfs/opt/bsdos/share/jpk/${_recipe}.jpk"
                log "  Building $_recipe .jpk ..."
                if "$_pkgd" build "$JPK_DIR/$_recipe" --output "$_out" 2>&1 | tail -3; then
                    log "  Built $_recipe → ${_out}"
                else
                    log "  WARN: bsdos-pkgd build failed for $_recipe — not included"
                fi
            else
                log "  SKIP: $_recipe .jpk (no payload/ dir in $JPK_DIR/$_recipe)"
            fi
        done
    else
        log "  SKIP: all .jpk builds (bsdos-pkgd not available at ${_pkgd:-unset})"
    fi

    # zpids.conf — preinstalled package list
    cat > "$WORK/rootfs/etc/bsdOS/zpids.conf" <<EOF
# Preinstalled .jpk packages for bsdOS v${BSDOS_VER}
phantom-browser = 0.1.0
foot-terminal = 0.2.0
EOF

    # Wayland runtime dir
    mkdir -p "$WORK/rootfs/tmp/wayland-run"
    chmod 700 "$WORK/rootfs/tmp/wayland-run"

    # cage binary symlink (if installed via pkg)
    mkdir -p "$WORK/rootfs/opt/cage/bin"
    if [ -f "$WORK/rootfs/usr/local/bin/cage" ]; then
        ln -sf /usr/local/bin/cage "$WORK/rootfs/opt/cage/bin/cage"
    fi

    # ── Chimp (bpi-m64): image-first rc.d + headless rc.conf + mmcsd fstab ──────
    # Only for real Banana Pi hardware; QEMU paths above are left untouched.
    if [ "${PLATFORM:-}" = "bpi_m64" ]; then
        log "  Chimp/bpi-m64: installing image-first rc.d + bpi-headless rc.conf + fstab"
        for _s in bsdos_core bsdos_lifecycled bsdos_agent; do
            if [ -f "$BSDOS_DIR/infra/rc.d/$_s" ]; then
                cp "$BSDOS_DIR/infra/rc.d/$_s" "$WORK/rootfs/usr/local/etc/rc.d/$_s"
                chmod 755 "$WORK/rootfs/usr/local/etc/rc.d/$_s"
                log "    rc.d: $_s (image-first /opt/bsdos/bin)"
            else
                log "    WARN: infra/rc.d/$_s not found"
            fi
        done
        # Append headless overrides last (later rc.conf assignments win on source).
        if [ -f "$BSDOS_DIR/infra/etc/rc.conf.bpi-headless" ]; then
            printf '\n' >> "$WORK/rootfs/etc/rc.conf"
            cat "$BSDOS_DIR/infra/etc/rc.conf.bpi-headless" >> "$WORK/rootfs/etc/rc.conf"
            log "    rc.conf += rc.conf.bpi-headless (headless autostart, no GUI)"
        fi
        # mmcsd root replaces the QEMU vtbd fstab (no 9p on hardware).
        if [ -f "$BSDOS_DIR/infra/etc/fstab.bpi" ]; then
            cp "$BSDOS_DIR/infra/etc/fstab.bpi" "$WORK/rootfs/etc/fstab"
            log "    fstab ← fstab.bpi (mmcsd root, no 9p)"
        fi
    fi
}

_gen_minimal_configs() {
    # bsdos-core config
    cat > "$WORK/rootfs/etc/bsdOS/bsdos.conf" <<'EOF'
# bsdOS core config — Zenoh endpoint + stream settings
[zenoh]
listen = "tcp/0.0.0.0:7447"
mode = "peer"

[stream]
fps = 30
quality = 80
EOF

    # cage config
    cat > "$WORK/rootfs/etc/bsdOS/cage.conf" <<'EOF'
# cage Wayland compositor config — kiosk mode
[compositor]
backend = "drm"      # QEMU virtio-gpu / fbdev fallback
resolution = "720x1440"
EOF

    # start-cage.sh (from SPEC_2stream_squirrel.md §4.1)
    cat > "$WORK/rootfs/etc/bsdOS/start-cage.sh" <<'SCRIPT'
#!/bin/sh
APP_ID=$1
WAYLAND_DISPLAY_NAME=${2:-wayland-0}
APP_CMD=${3:-foot}

export XDG_RUNTIME_DIR=/tmp/wayland-run
mkdir -p "$XDG_RUNTIME_DIR"
chmod 700 "$XDG_RUNTIME_DIR"

WAYLAND_DISPLAY=$WAYLAND_DISPLAY_NAME cage -d -- "$APP_CMD" &
CAGE_PID=$!

sleep 0.5

# Notify bsdos-core that the cage is ready for streaming
echo "READY $APP_ID" | nc -U /var/run/bsdOS/control.sock 2>/dev/null || true
SCRIPT
    chmod +x "$WORK/rootfs/etc/bsdOS/start-cage.sh"
}

# ── Stage 5b: Slim down rootfs (remove build deps, docs, caches) ────────────
stage5b_slim() {
    log "Stage 5b: Slim rootfs (remove build deps, docs, caches)"
    local R="$WORK/rootfs"

    # LLVM (1.7G) — pulled in by build deps, not needed at runtime
    rm -rf "$R/usr/local/llvm"* 2>/dev/null && log "  Removed: llvm"

    # Python/Perl/Lua runtimes (only needed by LLVM build chain)
    rm -rf "$R/usr/local/lib/python"* "$R/usr/local/lib/perl5" "$R/usr/local/lib/lua"* 2>/dev/null
    rm -rf "$R/usr/local/bin/python"* "$R/usr/local/bin/perl"* 2>/dev/null

    # Dev headers — not needed at runtime
    rm -rf "$R/usr/local/include" 2>/dev/null && log "  Removed: include headers"

    # Documentation and locale data
    rm -rf "$R/usr/local/share/doc" "$R/usr/local/share/gtk-doc" \
           "$R/usr/local/share/gir-1.0" "$R/usr/local/share/man" \
           "$R/usr/local/share/info" 2>/dev/null
    log "  Removed: docs/gtk-doc/gir/man/info"

    # Locale — keep only en_US (~58M savings)
    if [ -d "$R/usr/local/share/locale" ]; then
        find "$R/usr/local/share/locale" -maxdepth 1 -type d \
             ! -name en_US ! -name en_US.UTF-8 ! -name locale -exec rm -rf {} \; 2>/dev/null
        log "  Trimmed: locale (kept en_US only)"
    fi

    # DRI drivers — cage uses pixman, not hardware GL (~31M)
    rm -rf "$R/usr/local/lib/dri" 2>/dev/null && log "  Removed: dri drivers"

    # Vulkan shaders — software rendering only (~15M)
    rm -rf "$R/usr/local/share/vulkan" 2>/dev/null && log "  Removed: vulkan"

    # Hardware database — QEMU has no real hardware (~10M)
    rm -rf "$R/usr/local/share/hwdata" 2>/dev/null && log "  Removed: hwdata"

    # MIME database — not needed for headless (~6M)
    rm -rf "$R/usr/local/share/mime" 2>/dev/null && log "  Removed: mime"

    # Icon themes — keep only hicolor (~15M savings)
    if [ -d "$R/usr/local/share/icons" ]; then
        find "$R/usr/local/share/icons" -maxdepth 1 -type d \
             ! -name hicolor ! -name icons -exec rm -rf {} \; 2>/dev/null
        log "  Trimmed: icons (kept hicolor only)"
    fi

    # 32-bit compatibility libs — not needed on aarch64, optional on amd64
    rm -rf "$R/usr/lib32" 2>/dev/null && log "  Removed: lib32 compat"

    # pkg cache (416M of downloaded .txz files)
    rm -rf "$R/var/cache/pkg" 2>/dev/null && log "  Removed: pkg cache"

    # Kernel debug modules (.debug files — 200M+ in /boot/kernel/*.debug)
    rm -f "$R/boot/kernel/"*.debug 2>/dev/null
    rm -rf "$R/usr/lib/debug" 2>/dev/null && log "  Removed: kernel debug symbols"

    # Strip kernel modules (debug symbols only — -s breaks .ko loadability)
    if command -v strip >/dev/null 2>&1; then
        for mod in "$R/boot/kernel/"*.ko; do
            [ -f "$mod" ] && strip --strip-debug "$mod" 2>/dev/null
        done
        log "  Stripped: /boot/kernel/*.ko (debug symbols)"
    fi

    # Strip debug symbols from bsdos binaries
    if command -v strip >/dev/null 2>&1; then
        for bin in "$R/opt/bsdos/bin/"*; do
            [ -f "$bin" ] && strip "$bin" 2>/dev/null
        done
        log "  Stripped: /opt/bsdos/bin/*"
    fi

    # Report savings
    local SIZE=$(du -sh "$R" 2>/dev/null | awk '{print $1}')
    log "  Rootfs size after slim: $SIZE"
}

# ── Stage 5c: Manifest verification ─────────────────────────────────────────
stage5c_verify() {
    log "Stage 5c: Manifest verification"

    local R="$WORK/rootfs"
    local missing=0

    # Critical cross-compiled binaries (always required — built in Stage 3-4)
    for binpath in \
        /opt/bsdos/bin/bsdos-core \
        /opt/bsdos/bin/bsdos-lifecycled \
        /opt/bsdos/bin/bsdos-hal \
        /opt/bsdos/bin/wayland-tunnel \
        /opt/bsdos/bin/bsdos-agent \
        /usr/local/etc/rc.d/bsdos_core \
        /usr/local/etc/rc.d/bsdos_agent \
        /etc/bsdos/bsdos-core.conf
    do
        if [ ! -e "$R$binpath" ] && [ ! -L "$R$binpath" ]; then
            log "  MISSING: $binpath"
            missing=$((missing + 1))
        fi
    done

    # Optional pkg-installed binaries (warn; pkg may be deferred to first boot)
    for binpath in \
        /usr/local/bin/cage \
        /usr/local/bin/foot \
        /usr/local/bin/cog \
        /usr/local/bin/wpewebkit-fdo
    do
        if [ ! -e "$R$binpath" ]; then
            log "  OPTIONAL MISSING: $binpath (will be installed at first boot via pkg)"
        fi
    done

    if [ "$missing" -gt 0 ]; then
        log "  FATAL: $missing critical files missing — aborting"
        exit 1
    fi
    log "  All critical binaries present"
}

# ── Stage 6: mkimg + gzip ──────────────────────────────────────────────────
# Per SPEC §5.7 + §11.4 (internal task).
stage6_mkimg() {
    log "Stage 6/6: mkimg → ${IMG_NAME}.img.gz"

    # Chimp: U-Boot sunxi image (UNTESTED until hardware) ─────────────────────
    # BPI-M64 (Allwinner A64) boots via the BROM/sunxi SPL at a fixed 8 KiB byte
    # offset — NOT UEFI. So instead of the mkimg UEFI/BIOS path below we hand the
    # staged rootfs to bpi-image.sh, which lays out the raw SPL + GPT + UFS. The
    # qemu-* machines keep the unchanged UEFI/BIOS path. See docs/BPI-M64-BOOT.md.
    if [ "$PLATFORM" = "bpi_m64" ]; then
        log "  Platform bpi_m64 → bpi-image.sh (U-Boot sunxi layout, UNTESTED)"
        BPI_OUT="${WORK}/${IMG_NAME}.img"
        WORK_DIR="$WORK" "$BSDOS_DIR/infra/scripts/bpi-image.sh" \
            "$WORK/rootfs" "$BPI_OUT" || \
            err "bpi-image.sh failed (U-Boot blob present? see docs/BPI-M64-BOOT.md)"
        log "  gzip -9 ..."
        gzip -9 -c "$BPI_OUT" > "$IMG_GZ"
        SIZE=$(ls -lh "$IMG_GZ" | awk '{print $5}')
        log "  Output: $IMG_GZ ($SIZE)"
        return 0
    fi

    if ! command -v mkimg >/dev/null 2>&1; then
        log "  mkimg(8) not available — creating tarball fallback"
        cd "$WORK/rootfs"
        tar -czf "$ARTEFACTS/${IMG_NAME}.rootfs.tar.gz" .
        log "  Fallback: $ARTEFACTS/${IMG_NAME}.rootfs.tar.gz"
        log "  (On FreeBSD host: mkimg -s gpt -f raw ... to create bootable image)"
        return 0
    fi

    # 1. makefs: create UFS2 filesystem image from the rootfs directory tree
    #    Invalidate cache if any binary in rootfs/opt/bsdos/bin/ is newer than UFS image
    UFS_IMG="${WORK}/rootfs.ufs"
    UFS_STALE=0
    if [ ! -f "$UFS_IMG" ]; then
        UFS_STALE=1
    else
        for bin in "$WORK/rootfs/opt/bsdos/bin/"* "$WORK/rootfs/usr/local/etc/rc.d/"*; do
            [ -e "$bin" ] && [ "$bin" -nt "$UFS_IMG" ] && UFS_STALE=1 && break
        done
    fi
    if [ "$UFS_STALE" -eq 1 ]; then
        log "  makefs: UFS2 from $WORK/rootfs (rebuilding)"
        makefs -B little -o version=2 "$UFS_IMG" "$WORK/rootfs"
    else
        log "  Cached: $UFS_IMG"
    fi

    # Mark the makefs-produced UFS image clean (makefs leaves it "dirty")
    log "  fsck: marking UFS image clean"
    fsck_ufs -p -f "$UFS_IMG" >/dev/null 2>&1 || fsck_ffs -p -f "$UFS_IMG" >/dev/null 2>&1 || true

    # 2. mkimg: assemble bootable GPT image (boot code differs per arch)
    if [ "$ARCH" = "amd64" ]; then
        # BIOS/CSM boot (q35 + SeaBIOS): pmbr protective MBR + gptboot + UFS
        log "  mkimg: GPT + pmbr + gptboot (BIOS boot)"
        mkimg -s gpt -f raw -b /boot/pmbr \
            -p freebsd-boot:=/boot/gptboot \
            -p freebsd-ufs/rootfs:="$UFS_IMG" \
            -p freebsd-swap/swap::1G \
            -o "$IMG_RAW"
    else
        # aarch64 UEFI boot: ESP (FAT32 with loader.efi) + UFS
        ESP_IMG="${WORK}/esp.img"
        if [ ! -f "$ESP_IMG" ]; then
            # Create a valid FAT32 ESP using newfs_msdos (makefs -t msdos produces
            # invalid FAT on FreeBSD 15.x). -c 2 = 1KB clusters (FAT32 needs 65525+
            # clusters; 128MB / 1KB = 130040 clusters → meets minimum).
            log "  Creating FAT32 ESP via newfs_msdos ..."
            truncate -s 128m "$ESP_IMG"
            MDUNIT=$(mdconfig -a -t vnode -f "$ESP_IMG")
            newfs_msdos -F 32 -c 2 -h 255 -u 63 "/dev/$MDUNIT" >/dev/null 2>&1
            mount_msdosfs "/dev/$MDUNIT" /mnt
            mkdir -p /mnt/EFI/BOOT
            cp "$WORK/rootfs/boot/loader.efi" /mnt/EFI/BOOT/BOOTAA64.EFI
            umount /mnt
            mdconfig -d -u "$MDUNIT"
        fi
        log "  mkimg: GPT + EFI ESP + UFS (UEFI boot)"
        mkimg -s gpt -f raw \
            -p efi/esp:="$ESP_IMG" \
            -p freebsd-ufs/rootfs:="$UFS_IMG" \
            -p freebsd-swap/swap::1G \
            -o "$IMG_RAW"
    fi

    log "  gzip -9 ..."
    gzip -9 -c "$IMG_RAW" > "$IMG_GZ"

    SIZE=$(ls -lh "$IMG_GZ" | awk '{print $5}')
    log "  Output: $IMG_GZ ($SIZE)"
}

# ── Main ───────────────────────────────────────────────────────────────────
main() {
    log "bsdOS v${BSDOS_VER} build for machine '${MACHINE}'"
    log "  arch=$ARCH kernconf=$KERNCONF platform=$PLATFORM pkgset=$PKGSET"
    log "  BSDOS_DIR:   $BSDOS_DIR"
    log "  WORK:        $WORK"
    log "  FreeBSD:     ${FREEBSD_VER} (${FREEBSD_ARCH})"

    stage1_base
    stage2_pkg
    stage345_build
    stage5_configs
    stage5b_slim
    stage5c_verify
    stage6_mkimg

    log "DONE: $IMG_GZ"
    log "Smoke test: make squirrel-smoke-${ARCH}"
}

main "$@"
