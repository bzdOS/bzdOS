#!/bin/sh
# bpi-image.sh — Build bootable SD image for Banana Pi M64 (Allwinner A64)
#
# purpose: Build bootable SD image for Banana Pi M64 (Allwinner A64, FreeBSD aarch64)
# input:   $1 = rootfs dir (staged UFS tree, e.g. bsdos-build.sh $WORK/rootfs),
#          $2 = output .img path
# output:  bootable raw image: u-boot@8KB + GPT + UFS root (+ swap)
# sideEffects: writes image file; needs sysutils/u-boot-pine64-lts pkg OR a prebuilt
#              u-boot-sunxi-with-spl.bin (path overridable via $UBOOT_BIN); uses
#              makefs/mkimg/fsck_ufs from FreeBSD base. md(4) mount NOT required
#              (raw dd of SPL into the GPT gap).
# STATUS: UNTESTED — requires physical BPI-M64 to validate (a hub task, deadline 2026-06-27).
#         Every unverified assumption below is tagged `# ASSUMPTION:` or `# TODO(hardware):`.
#
# Why this differs from bsdos-build.sh Stage 6 (amd64/aarch64 QEMU):
#   QEMU amd64 = BIOS/CSM boot (pmbr + gptboot).
#   QEMU aarch64 = UEFI boot (EFI ESP + loader.efi via OVMF/edk2).
#   BPI-M64 = Allwinner BROM boot-ROM: NO UEFI firmware on the board. The BROM
#   scans the SD card at a FIXED byte offset (8 KiB) for the sunxi SPL, runs it,
#   the SPL loads full U-Boot, and U-Boot's EFI payload (ubldr/loader.efi) then
#   chainloads the FreeBSD kernel. So the boot blob is RAW (not in a partition),
#   and the GPT/partitions must begin AFTER the U-Boot region. See docs/BPI-M64-BOOT.md.
#
# Boot chain:  BROM → SPL(@8KiB) → U-Boot → EFI(loader.efi/ubldr) → FreeBSD kernel
#
set -eu

# ── Args ─────────────────────────────────────────────────────────────────────
ROOTFS="${1:-}"
OUT_IMG="${2:-}"
if [ -z "$ROOTFS" ] || [ -z "$OUT_IMG" ]; then
    echo "Usage: $0 <rootfs-dir> <output.img>" >&2
    echo "  e.g. $0 \$HOME/.cache/bsdos-build/aarch64/work/rootfs bsdos-chimp-bpi-m64.img" >&2
    exit 1
fi
if [ ! -d "$ROOTFS" ]; then
    echo "ERROR: rootfs dir not found: $ROOTFS" >&2
    exit 1
fi

# ── Tunables ─────────────────────────────────────────────────────────────────
# SSH public key to install in /root/.ssh/authorized_keys on the board.
# Set to empty string to skip SSH key injection.
SSH_PUBKEY="${SSH_PUBKEY:-$(dirname "$0")/../../bsdos-key.pub}"
SSH_PUBKEY="$(cd "$(dirname "$SSH_PUBKEY")" 2>/dev/null && pwd)/$(basename "$SSH_PUBKEY")"

# Board hostname.
CHIMP_HOSTNAME="${CHIMP_HOSTNAME:-bsdos-chimp}"

# U-Boot binary — mainline build with bananapi_m64_defconfig (sun50i-a64-bananapi-m64).
# Binary tracked in git at infra/u-boot/bananapi-m64/u-boot-sunxi-with-spl.bin
# To rebuild from source:
#   cd ~/.cache/u-boot-bpi && make CROSS_COMPILE=aarch64-linux-gnu- bananapi_m64_defconfig
#   make CROSS_COMPILE=aarch64-linux-gnu- -j$(nproc)
#   cp u-boot-sunxi-with-spl.bin infra/u-boot/bananapi-m64/
BSDOS_DIR_SCRIPT="$(cd "$(dirname "$0")/../.." && pwd)"
UBOOT_BIN="${UBOOT_BIN:-${BSDOS_DIR_SCRIPT}/infra/u-boot/bananapi-m64/u-boot-sunxi-with-spl.bin}"

# DTB the FreeBSD kernel/loader should hand the board.
# ASSUMPTION: this DTB ships in FreeBSD base arm64 under /boot/dtb/allwinner/.
#   It is the upstream BPI-M64 device tree — no custom DTS needed for bring-up.
DTB_NAME="${DTB_NAME:-sun50i-a64-bananapi-m64.dtb}"
DTB_SUBDIR="${DTB_SUBDIR:-allwinner}"

# Geometry.
#   SPL byte offset is FIXED by the A64 BROM at 8 KiB — do NOT change.
#   The first GPT partition must start after the U-Boot blob. We reserve a
#   generous 8 MiB front gap so the SPL+U-Boot (typically <1 MiB, but FIT/full
#   builds can grow) never collides with partition 1.
SPL_OFFSET_KIB=8          # BROM-mandated SPL load offset (sector 16 @ 512B). FIXED.
UBOOT_RESERVE_MIB="${UBOOT_RESERVE_MIB:-8}"   # front gap reserved for U-Boot
SWAP_MIB="${SWAP_MIB:-1024}"                  # freebsd-swap partition size

WORK_DIR="${WORK_DIR:-$(dirname "$OUT_IMG")}"
UFS_IMG="${WORK_DIR}/bpi-rootfs.ufs"

log() { printf '\033[1;36m[ bpi-image ]\033[0m %s\n' "$*"; }
err() { printf '\033[1;31m[ ERROR ]\033[0m %s\n' "$*" >&2; exit 1; }

# ── Tool checks (this recipe only runs on a FreeBSD build host) ──────────────
for t in makefs mkimg; do
    command -v "$t" >/dev/null 2>&1 || \
        err "'$t' not found — bpi-image.sh must run on a FreeBSD build host (dev-vm) with base tools."
done

# ── Step 0: locate U-Boot blob ───────────────────────────────────────────────
log "Step 0: locate U-Boot SPL+blob"
if [ ! -f "$UBOOT_BIN" ]; then
    cat >&2 <<EOF
ERROR: U-Boot blob not found: $UBOOT_BIN

  Install the port on the build host:
      pkg install ${UBOOT_PKG}
  then confirm the blob path:
      pkg info -l ${UBOOT_PKG} | grep u-boot-sunxi-with-spl.bin

  Or supply a prebuilt blob:
      UBOOT_BIN=/path/to/u-boot-sunxi-with-spl.bin $0 ...
EOF
    exit 1
fi
UBOOT_SIZE_B=$(stat -f %z "$UBOOT_BIN" 2>/dev/null || wc -c < "$UBOOT_BIN")
log "  U-Boot blob: $UBOOT_BIN (${UBOOT_SIZE_B} bytes)"
# Sanity: blob must fit inside the reserved front gap, leaving the 8 KiB head.
MAX_UBOOT_B=$(( (UBOOT_RESERVE_MIB * 1024 - SPL_OFFSET_KIB) * 1024 ))
if [ "$UBOOT_SIZE_B" -gt "$MAX_UBOOT_B" ]; then
    err "U-Boot blob (${UBOOT_SIZE_B}B) exceeds reserved gap (${MAX_UBOOT_B}B at offset ${SPL_OFFSET_KIB}KiB). Raise UBOOT_RESERVE_MIB."
fi

# ── Step 0.5: stage all config files into rootfs ─────────────────────────────
log "Step 0.5: staging loader.conf, fstab, rc.conf, SSH into rootfs"

# loader.conf — DTB + console (vidconsole first for HDMI, comconsole fallback)
mkdir -p "${ROOTFS}/boot"
cat > "${ROOTFS}/boot/loader.conf" <<LOADEREOF
# bsdOS Chimp — Banana Pi M64 (Allwinner A64)
fdt_name="/boot/dtb/${DTB_SUBDIR}/${DTB_NAME}"
console="vidconsole,comconsole"
comconsole_speed="115200"
boot_serial="YES"
beastie_disable="YES"
vfs.root.mountfrom="ufs:/dev/mmcsd0p3"
LOADEREOF
log "  loader.conf written (vidconsole+comconsole, DTB=${DTB_NAME})"

# fstab
mkdir -p "${ROOTFS}/etc"
cat > "${ROOTFS}/etc/fstab" <<FSTABEOF
# bsdOS Chimp — BPI-M64 (p1=u-boot reserve, p2=efi ESP, p3=ufs, p4=swap)
/dev/mmcsd0p3  /     ufs   rw,noatime  1 1
/dev/mmcsd0p4  none  swap  sw          0 0
FSTABEOF
log "  fstab written"

# rc.conf — SSH + DHCP + hostname
# Merge with existing rc.conf if present, otherwise create
RC_CONF="${ROOTFS}/etc/rc.conf"
touch "$RC_CONF"
# Remove any existing conflicting entries, then append ours
sed -i '' \
    -e '/^hostname=/d' \
    -e '/^sshd_enable=/d' \
    -e '/^ifconfig_awg0=/d' \
    "$RC_CONF" 2>/dev/null || true
cat >> "$RC_CONF" <<RCEOF
# bsdOS Chimp first-boot
hostname="${CHIMP_HOSTNAME}"
sshd_enable="YES"
ifconfig_awg0="DHCP"
RCEOF
log "  rc.conf: hostname=${CHIMP_HOSTNAME}, sshd=YES, awg0=DHCP"

# SSH authorized_keys for root
if [ -f "$SSH_PUBKEY" ]; then
    mkdir -p "${ROOTFS}/root/.ssh"
    chmod 700 "${ROOTFS}/root/.ssh"
    cp "$SSH_PUBKEY" "${ROOTFS}/root/.ssh/authorized_keys"
    chmod 600 "${ROOTFS}/root/.ssh/authorized_keys"
    log "  SSH key installed: $(basename "$SSH_PUBKEY")"
else
    log "  WARNING: SSH_PUBKEY not found ($SSH_PUBKEY) — skipping key install"
fi

# ── Step 1: makefs — UFS2 root from the staged rootfs tree ───────────────────
# (Mirrors bsdos-build.sh Stage 6: makefs -B little -o version=2)
log "Step 1: makefs UFS2 root from $ROOTFS"
# ASSUMPTION: caller already wrote /etc/fstab + /boot/loader.conf into $ROOTFS.
#   The required fragments are printed at Steps 4-5 — stage them BEFORE this step.
makefs -B little -o version=2 "$UFS_IMG" "$ROOTFS"

# makefs leaves the image flagged dirty; mark it clean so first boot skips a
# forced fsck (same fixup as bsdos-build.sh Stage 6).
log "  fsck: marking UFS image clean"
fsck_ufs -p -f "$UFS_IMG" >/dev/null 2>&1 || fsck_ffs -p -f "$UFS_IMG" >/dev/null 2>&1 || true

# ── Step 2: mkimg — GPT image with reserved U-Boot front gap ─────────────────
# mkimg lays out: [protective MBR][GPT header+table][... partitions ...].
# We push partition 1 past the U-Boot region by prepending a "freebsd-boot"-typed
# reservation partition of UBOOT_RESERVE_MIB. The sunxi SPL is then dd'd raw over
# sector 16 (Step 3); it lives inside this reserved partition's space and is NOT
# read via the partition table — the BROM reads the fixed byte offset directly.
#
# ASSUMPTION: an 8 MiB reservation partition starting at the mkimg default
#   first-usable-LBA (after the GPT) leaves the 8 KiB SPL slot and the rest of
#   the U-Boot blob untouched, because mkimg writes nothing into a freebsd-boot
#   partition unless given a `:=file`. We give it none → it stays zeroed → safe
#   to overwrite with dd.
# TODO(hardware): confirm the GPT secondary header at end-of-disk does not move
#   onto an SD-card region the BROM cares about (it does not on A64 — BROM only
#   reads the 8 KiB SPL offset — but verify the GPT itself is intact post-dd).
# Build a FAT32 EFI System Partition holding the FreeBSD arm64 loader as
# EFI/BOOT/BOOTAA64.EFI. U-Boot's distro/EFI boot scans FAT partitions for that
# path and chainloads it. U-Boot CANNOT read UFS, so the loader MUST live on this
# FAT ESP, not on the UFS root (the missing-ESP bug: board reached U-Boot but had
# no readable loader → hung, 2026-07-02). newfs_msdos (makefs -t msdos emits an
# invalid FAT on FreeBSD 15.x) — same recipe as bsdos-build.sh Stage 6 aarch64.
log "Step 2a: build FAT32 ESP with EFI/BOOT/BOOTAA64.EFI (= loader.efi)"
ESP_IMG="${WORK_DIR}/bpi-esp.img"
LOADER_EFI="${ROOTFS}/boot/loader.efi"
[ -f "$LOADER_EFI" ] || err "loader.efi not found in rootfs: $LOADER_EFI (need arm64 base loader)"
rm -f "$ESP_IMG"
truncate -s 128m "$ESP_IMG"
ESP_MD=$(mdconfig -a -t vnode -f "$ESP_IMG")
newfs_msdos -F 32 -c 2 -h 255 -u 63 "/dev/$ESP_MD" >/dev/null 2>&1
ESP_MNT="${WORK_DIR}/bpi-esp-mnt"
mkdir -p "$ESP_MNT"
mount_msdosfs "/dev/$ESP_MD" "$ESP_MNT"
mkdir -p "$ESP_MNT/EFI/BOOT"
cp "$LOADER_EFI" "$ESP_MNT/EFI/BOOT/BOOTAA64.EFI"
umount "$ESP_MNT"
mdconfig -d -u "$ESP_MD"
rmdir "$ESP_MNT" 2>/dev/null || true
log "  ESP built (BOOTAA64.EFI ← $(basename "$LOADER_EFI"), $(stat -f %z "$LOADER_EFI" 2>/dev/null)B)"

# GPT vs U-Boot collision (FOUND ON HARDWARE 2026-07-07, a hub task): mkimg lays
# out the standard 128-entry primary GPT array at LBA2..33. The sunxi SPL is dd'd
# raw at LBA16 (8 KiB) in Step 3 — that overwrites the tail of the primary array
# (entries ~57-128), breaking its CRC. The OLD assumption below was WRONG:
#   # "U-Boot/FreeBSD fall back to the backup GPT"  ← FALSE.
# U-Boot's `part list` sees the bad primary CRC and reports 0 partitions → no
# boot, exactly the symptom seen on the eMMC bring-up. FIX: shrink the entry
# array to 16 entries (16*128 = 2048 B = 4 sectors = LBA2..5), which sits entirely
# BEFORE the SPL@LBA16, so the primary CRC stays valid. We only ever define 4
# partitions, so 16 is ample. Done as Step 2c, BEFORE the SPL dd.
log "Step 2b: mkimg GPT (u-boot reserve + EFI ESP + UFS root + swap)"
mkimg -s gpt -f raw \
    -p freebsd-boot::"${UBOOT_RESERVE_MIB}M" \
    -p efi/esp:="$ESP_IMG" \
    -p freebsd-ufs/rootfs:="$UFS_IMG" \
    -p freebsd-swap/swap::"${SWAP_MIB}M" \
    -o "$OUT_IMG"

# ── Step 2c: shrink GPT entry array to 16 (avoid SPL@LBA16 collision) ────────
# Rewrites primary + backup GPT so num_partition_entries=16 and the primary
# array fits in LBA2..5 (well clear of the LBA16 SPL slot). Recomputes both
# header CRCs and the entry-array CRC. Idempotent. Verified-equivalent to the
# runtime fix used in build/gpt-fix.sh / build/gpt-fix-console.py on the board.
GPT_NPARTS="${GPT_NPARTS:-16}"
log "Step 2c: shrink GPT entry array to ${GPT_NPARTS} (keep clear of SPL@LBA16)"
if ! command -v python3 >/dev/null 2>&1; then
    err "python3 not found — needed for GPT array shrink (Step 2c). Install lang/python3 on the build host."
fi
python3 - "$OUT_IMG" "$GPT_NPARTS" <<'PYGPT'
import sys, struct, zlib
img, NEW_N = sys.argv[1], int(sys.argv[2])
SEC = 512; PSZ = 128
if NEW_N < 1 or NEW_N * PSZ > 16 * SEC:
    sys.exit(f"GPT_NPARTS={NEW_N} invalid: must be 1..{16*SEC//PSZ} so array stays before SPL@LBA16")
f = open(img, 'r+b')
def rd(lba, n): f.seek(lba * SEC); return f.read(n)
def wr(lba, b): f.seek(lba * SEC); f.write(b); f.flush()
# primary header @ LBA1
h = bytearray(rd(1, SEC))
assert h[0:8] == b'EFI PART', "no EFI PART magic in primary GPT header"
my_lba, alt_lba = struct.unpack('<QQ', h[24:40])
first_use, last_use = struct.unpack('<QQ', h[40:56])
disk_guid = h[56:72]
pe_lba, nparts_old, psz, _pcrc = struct.unpack('<QIII', h[72:92])
assert psz == 128, f"unexpected partition entry size {psz}"
# read the real entries from the existing primary array (first few are real)
arr_old = rd(pe_lba, nparts_old * PSZ)
def nonzero(e): return e[0:16] != b'\x00' * 16
real_n = 0
while real_n < nparts_old and nonzero(arr_old[real_n*PSZ:(real_n+1)*PSZ]):
    real_n += 1
if real_n > NEW_N:
    sys.exit(f"image already has {real_n} partitions, won't fit in GPT_NPARTS={NEW_N}; raise GPT_NPARTS")
real = arr_old[0:real_n*PSZ]
# new array: real entries + zero padding to NEW_N
newarr = real + b'\x00' * ((NEW_N - real_n) * PSZ)
assert len(newarr) == NEW_N * PSZ
newcrc = zlib.crc32(newarr) & 0xffffffff
NARR_SEC = (NEW_N * PSZ) // SEC              # sectors the array spans
def build_header(my, alt, pe, arr_crc):
    hh = bytearray(SEC)
    hh[0:8] = b'EFI PART'
    struct.pack_into('<I', hh, 8, 0x00010000)    # revision 1.0
    struct.pack_into('<I', hh, 12, 92)           # header size
    struct.pack_into('<I', hh, 16, 0)            # header crc (placeholder)
    struct.pack_into('<I', hh, 20, 0)            # reserved
    struct.pack_into('<Q', hh, 24, my)
    struct.pack_into('<Q', hh, 32, alt)
    struct.pack_into('<Q', hh, 40, first_use)
    struct.pack_into('<Q', hh, 48, last_use)
    hh[56:72] = disk_guid
    struct.pack_into('<Q', hh, 72, pe)
    struct.pack_into('<I', hh, 80, NEW_N)
    struct.pack_into('<I', hh, 84, PSZ)
    struct.pack_into('<I', hh, 88, arr_crc)
    hcrc = zlib.crc32(bytes(hh[0:92])) & 0xffffffff
    struct.pack_into('<I', hh, 16, hcrc)
    return bytes(hh)
# primary: header @LBA1, array @pe_lba (=2)
prim = build_header(1, alt_lba, pe_lba, newcrc)
wr(1, prim); wr(pe_lba, newarr)
# backup: header @alt_lba, array right before it
bk_pe = alt_lba - NARR_SEC
bkp = build_header(alt_lba, 1, bk_pe, newcrc)
wr(bk_pe, newarr); wr(alt_lba, bkp)
import os as _os; _os.fsync(f.fileno()); f.close()
print(f"  GPT shrunk: nparts {nparts_old}->{NEW_N}, primary array LBA{pe_lba}..LBA{pe_lba+NARR_SEC-1} "
      f"(before SPL@LBA16), real partitions kept={real_n}, array_crc={newcrc:#010x}")
PYGPT
log "  GPT entry array now fits before the SPL slot; primary CRC will stay valid after Step 3."

# ── Step 3: dd the sunxi SPL+U-Boot over sector 16 (8 KiB offset) ────────────
# This is THE sunxi-specific step. conv=notrunc keeps the rest of the GPT image.
# bs=1k seek=8 == byte offset 8192 == sector 16 @ 512B sectors == BROM SPL slot.
log "Step 3: dd U-Boot SPL → offset ${SPL_OFFSET_KIB}KiB (sunxi BROM slot)"
dd if="$UBOOT_BIN" of="$OUT_IMG" bs=1024 seek="$SPL_OFFSET_KIB" conv=notrunc 2>/dev/null
log "  U-Boot written. Boot chain: BROM → SPL@${SPL_OFFSET_KIB}KiB → U-Boot → loader.efi → kernel"

SIZE=$(ls -lh "$OUT_IMG" | awk '{print $5}')
log "DONE (UNTESTED): $OUT_IMG ($SIZE)"
log "Flash with:  dd if=$OUT_IMG of=/dev/daX bs=1m  (X = SD reader)"
log "  ⚠ NEVER add conv=sync when piping (gunzip -c img.gz | dd): it zero-pads every"
log "    short pipe read up to bs, inflating a 2.4GB image to tens of GB of misaligned"
log "    garbage (overflows the card, corrupts layout). Decompress to a file first, or"
log "    pipe WITHOUT conv=sync:  gunzip -c ${OUT_IMG}.gz | dd of=/dev/daX bs=1m"
log "Validate on hardware: see docs/BPI-M64-BOOT.md (Validation checklist, a hub task)."
