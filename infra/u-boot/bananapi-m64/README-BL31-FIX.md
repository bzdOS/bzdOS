# BPI-M64 U-Boot BL31 fix (2026-07-03)

## Root cause of both dead SD images
`u-boot-sunxi-with-spl.bin` (mainline 2026.07-rc5, built 06-27) shipped with an
**empty BL31**: the FIT inside had `atf` image = **0 bytes** (also scp=0). Built
without `BL31=`. On A64/ARMv8 BL31 is mandatory: SPL inits DRAM (this is why FEL
DRAM tests + FEL SPL run always succeeded), then jumps to firmware=atf @0x44000
which is empty -> silent hang. That is exactly the "dies after SPL" symptom.
Verified via `dumpimage -l` (atf Data Size 0) on the original blob.

## Fix (rebuilt on the Linux host, aarch64-linux-gnu- cross)
1. ATF v2.10.0 (pre toolchain-rework; v2.15 breaks make on this host):
   `make CROSS_COMPILE=aarch64-linux-gnu- PLAT=sun50i_a64 DEBUG=0 bl31`
   -> build/sun50i_a64/release/bl31.bin (37 KB)  [saved: bl31-sun50i_a64.bin]
2. U-Boot v2026.07-rc5 bananapi_m64_defconfig, disable OpenSSL3.5-incompatible
   host tools then build with BL31:
   `./scripts/config --disable TOOLS_KWBIMAGE --disable TOOLS_MKEFICAPSULE --disable TOOLS_LIBCRYPTO`
   `make olddefconfig && make -j CROSS_COMPILE=aarch64-linux-gnu- BL31=.../bl31.bin`
   -> u-boot-sunxi-with-spl.bin  (FIT now has atf=37077 bytes)  [saved: *.FIXED-BL31.bin]
   (this saved copy has CONFIG_BOOTCOMMAND="dhcp; ping 192.0.2.2" x5 + BOOTDELAY=1
    baked in for the blind network-catch diagnostic — rebuild clean for production.)
3. sunxi-fel: stock 1.4.2 LACKS FIT support (only legacy uImage) -> rebuilt git
   d7bbd17 (has fit_image.c).  [saved: sunxi-fel-fit-capable]

## Proven
`./sunxi-fel-fit-capable uboot u-boot-sunxi-with-spl.FIXED-BL31.bin` -> FEL device
disappears from the USB bus = SPL->BL31->U-Boot handoff SUCCEEDS. (With the old
empty-BL31 blob + old sunxi-fel this failed on a CRC/type mismatch.)

## Remaining (hardware-gated)
Board is DC-powered (not USB-VBUS) so it cannot be power-cycled remotely; it is
currently sitting in U-Boot from the diagnostic boot. Next physical power-cycle:
board has no SD -> BROM enters FEL -> run the sunxi-fel command above -> U-Boot
auto-DHCPs on its LAN (10.0.0.0/24, Keenetic gw) and pings 192.0.2.2; catch it:
`tcpdump -i br0 -e -n 'icmp and src net 10.0.0.0/24'`.
