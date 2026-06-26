# Contributing to bsdos-hal

## Bug reports

Open an issue with:
- What happened (expected vs actual response from the socket)
- The exact command that triggered it
- Platform (`-Dplatform=` value) and Zig version (`zig version`)
- Whether it is a real-hardware or QEMU run

## Pull requests

1. Fork → branch → PR.
2. Keep commits atomic with clear messages.
3. `zig build test` must pass.
4. `zig build -Dplatform=qemu_amd64 test` must pass (cross-platform commands
   are tested on every platform).
5. No hidden allocations in hot paths — stack and compile-time buffers only.
6. No `unsafe` equivalent: avoid `@ptrCast` / `@intToPtr` outside of explicit
   C-interop (i.e., `@cImport` blocks).

## Building locally

```sh
# Native FreeBSD 15.1 host or cross-compilation from any host with Zig 0.15+

# QEMU dev loop (default)
zig build

# Run tests
zig build test

# Cross-compile for Banana Pi BPI-M64 (Chimp v0.2)
zig build -Dtarget=aarch64-freebsd.15.1 -Dplatform=bpi_m64

# Cross-compile for PinePhone (Porcupine v0.3)
zig build -Dtarget=aarch64-freebsd.15.1 -Dplatform=pinephone
```

The resulting binary is `zig-out/bin/bsdos-hal`. Copy it to the target device
and run as root:

```sh
./bsdos-hal &
echo "hal_version" | nc -U /var/run/bsdos-hal.sock
```

## Adding a new platform

1. Add a variant to the `Platform` enum in `src/platform.zig`.
2. Wire up the `std.mem.eql` branch in the `current` comptime block.
3. Set the `has_*` flags for the new platform (follow existing patterns).
4. Set `i2c_sensor_bus` for the new platform if it has I2C.
5. Add a row to the platform table in `README.md`.
6. Add a row to the capability table in `README.md`.
7. `zig build -Dplatform=<new_platform> test` must pass.

## Adding a new command

1. Write the handler function in `src/main.zig` with a `purpose/input/output/sideEffects` contract comment (see existing functions for the pattern).
2. Add it to `processTextCmd` — cross-platform commands go in the first block;
   platform-gated commands go inside the appropriate `if (comptime platform.has_*)` block.
3. If the command is platform-gated, add it to the `gated` list in
   `isPlatformGatedCmd` so it returns `"unsupported on <platform>"` instead
   of `"unknown"` on platforms that lack it.
4. Add a unit test in `src/main.zig` covering at least: success case, missing
   argument case, invalid argument case.
5. Update the **Commands** table in `README.md`.

## Code style

- All structs `packed` or `extern`, explicitly aligned to 64 bytes where used
  in data paths (cache-line alignment for Cortex-A53).
- `comptime` for lookup tables and state machine layouts.
- Errors handled explicitly — never ignore a result.
- Response buffers are 4 KiB stack slices (`var buf: [4096]u8 = undefined`);
  responses must fit within that limit.

## License

By contributing, you agree that your contributions are licensed under MIT.
