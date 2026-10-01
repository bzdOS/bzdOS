// bsdOS HAL build script
// Target: aarch64-freebsd.15.1 (PinePhone / Banana Pi Chimp / Squirrel aarch64)
// Build: zig build  (defaults to Fbdev backend)
//        zig build -Dbackend=Lima  (when Lima DRM lands)

const std = @import("std");

// build:start
//   purpose: Define the bsdOS HAL build (libhal_gpu static lib + unit tests).
//            Accepts -Dbackend=Fbdev|Lima and -Dplatform=<str>, injecting both
//            as build_options so gpu.zig can resolve comptime backend/platform flags.
//   input:  b: standard Build object from zig build.
//   output: void (registers lib + test targets in b).
//   sideEffects: Registers static library, test step in the Zig build graph.
pub fn build(b: *std.Build) void {
    // ---------------------------------------------------------------------------
    // Target: aarch64-freebsd 15.1
    // ---------------------------------------------------------------------------
    const target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag   = .freebsd,
        // FreeBSD 15.1 ABI — pin so cross-compiled binaries don't depend on
        // features absent in 15.1 libc.
        .os_version_min = .{ .semver = .{ .major = 15, .minor = 1, .patch = 0 } },
    });

    const optimize = b.standardOptimizeOption(.{});

    // ---------------------------------------------------------------------------
    // Backend option
    // ---------------------------------------------------------------------------
    const backend_opt = b.option(
        []const u8,
        "backend",
        "GPU backend: Fbdev (default) or Lima",
    ) orelse "Fbdev";

    const backend_enum_val = blk: {
        if (std.mem.eql(u8, backend_opt, "Lima")) break :blk "Lima";
        break :blk "Fbdev";
    };

    // -Dplatform=<str>  — comptime platform selector, threaded from the Makefile
    // cross-squirrel targets via $(ZIG_PLATFORM_FLAG) (set by squirrel-build.sh).
    // gpu.zig does not yet branch on platform; the option is accepted and injected
    // as build_options for forward-compat (e.g. selecting fbdev vs Lima/Mali by
    // device class). Valid: qemu_amd64|qemu_aarch64|bpi_m64|pinephone.
    const platform = b.option(
        []const u8,
        "platform",
        "Target platform: qemu_amd64|qemu_aarch64|bpi_m64|pinephone",
    ) orelse "qemu_aarch64";

    // Pass the backend + platform choices as comptime strings that gpu.zig can use.
    // (gpu.zig currently hard-codes active_backend = .Fbdev; a future step
    //  can wire these options in via @import("build_options").)
    const options = b.addOptions();
    options.addOption([]const u8, "backend", backend_enum_val);
    options.addOption([]const u8, "platform", platform);

    // ---------------------------------------------------------------------------
    // Static library: libhal_gpu
    // ---------------------------------------------------------------------------
    const lib = b.addStaticLibrary(.{
        .name    = "hal_gpu",
        .root_source_file = b.path("gpu.zig"),
        .target  = target,
        .optimize = optimize,
    });
    lib.addOptions("build_options", options);

    // FreeBSD system include paths (needed when cross-compiling from Linux host
    // with a sysroot; on-device builds find these automatically).
    // Override with -Dsysroot=/path if cross-compiling.
    const sysroot = b.option([]const u8, "sysroot", "FreeBSD 15.1 sysroot for cross-compile") orelse "";
    if (sysroot.len > 0) {
        lib.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr/include" }) });
    }

    b.installArtifact(lib);

    // ---------------------------------------------------------------------------
    // Unit test executable
    // ---------------------------------------------------------------------------
    const unit_tests = b.addTest(.{
        .root_source_file = b.path("gpu.zig"),
        .target  = target,
        .optimize = optimize,
    });
    unit_tests.addOptions("build_options", options);

    const run_unit_tests = b.addRunArtifact(unit_tests);
    const test_step = b.step("test", "Run HAL unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
// build:end
