# Chimp boot / auto-start (bpi-headless)

How a Banana Pi (aarch64, Chimp v0.2) image brings the bsdOS stack up on boot,
and how that differs from the QEMU/Squirrel dev loop.

## Files

| File | Goes to | Purpose |
|---|---|---|
| `infra/rc.d/bsdos_core` | `/usr/local/etc/rc.d/bsdos_core` | Wayland stream manager + Zenoh node |
| `infra/rc.d/bsdos_lifecycled` | `/usr/local/etc/rc.d/bsdos_lifecycled` | Jail lifecycle daemon (FREEZE/THAW/...) |
| `infra/rc.d/bsdos_agent` | `/usr/local/etc/rc.d/bsdos_agent` | Guest agent (virtio-console; self-skips on bare metal) |
| `infra/etc/rc.conf.bpi-headless` | merged into `/etc/rc.conf` | Enables the three services, GUI off |
| `infra/etc/fstab.bpi` | `/etc/fstab` | UFS root on SD/eMMC; no 9p |

## Service start order

`rcorder(8)` derives ordering from the `PROVIDE`/`REQUIRE` headers:

```
FILESYSTEMS  →  NETWORKING
                  ├─ bsdos_core        REQUIRE: NETWORKING FILESYSTEMS
                  ├─ bsdos_lifecycled  REQUIRE: NETWORKING FILESYSTEMS mountcritremote
                  └─ bsdos_agent       REQUIRE: FILESYSTEMS mountcritremote
```

- **bsdos_core** needs the network (Zenoh listener on `:7447`) and a mounted,
  writable FS (it creates `/tmp/bsdos/streams`, writes logs).
- **bsdos_lifecycled** needs the FS mounted (`mountcritremote`) because it
  inspects jail state on disk before SIGSTOP/SIGCONT; it also opens a control
  socket at `/var/run/bsdos-lifecycle.sock`.
- **bsdos_agent** needs `/dev/ttyV*` (virtio-console). On bare metal that device
  does not exist, so the script logs and returns success without starting — see
  below. No hard ordering between the three; they may start in any interleaving
  after their REQUIRE targets.

## What differs from QEMU (Squirrel)

| Aspect | QEMU / Squirrel | Banana Pi / Chimp |
|---|---|---|
| Binaries | symlinked into `/usr/local/bin` from `/opt/bsdos/bin` | shipped in rootfs at `/opt/bsdos/bin` |
| Source share | `/mnt/bsdos` via virtio-9p (host `/srv/bsdos`) | **none** — nothing is built on device |
| Agent build fallback | rc.d may `zig build-exe` from the 9p source | **never** — no 9p, no compiler in image |
| Agent transport | virtio-console `/dev/ttyV1.1` | absent → `bsdos_agent` self-skips |
| Root device | `vtbd0p2` (virtio-blk) | `mmcsd0p2` (SD/eMMC) |
| Console | serial `ttyu0` (`-nographic`) | board UART / HDMI (Phase 2) |
| Display | none (headless) | none in Phase 1; fbdev+weston in Phase 2 |

The rc.d scripts are **shared** between QEMU and hardware. They resolve the
binary as `/opt/bsdos/bin/<name>` first, then fall back to the
`/usr/local/bin/<name>` symlink, so a single script works in both worlds. The
only QEMU-only branch is `bsdos_agent`'s build-from-9p fallback, which is gated
on the 9p source existing **and** `zig` being installed — neither is true on the
device, so it is never taken there.

## Installing on a device image

```sh
# rc.d scripts (FreeBSD installs third-party rc.d under /usr/local/etc/rc.d)
install -m 755 infra/rc.d/bsdos_core        $ROOTFS/usr/local/etc/rc.d/
install -m 755 infra/rc.d/bsdos_lifecycled  $ROOTFS/usr/local/etc/rc.d/
install -m 755 infra/rc.d/bsdos_agent       $ROOTFS/usr/local/etc/rc.d/

# config
cat infra/etc/rc.conf.bpi-headless >> $ROOTFS/etc/rc.conf   # or merge with sysrc
install -m 644 infra/etc/fstab.bpi          $ROOTFS/etc/fstab

# binaries already staged by the (aarch64) build into $ROOTFS/opt/bsdos/bin/
```

After boot, verify:

```sh
service bsdos_core status
service bsdos_lifecycled status
service bsdos_agent status     # expect the "chardev not present — skipping" note
```
