// START_AI_HEADER
// MODULE: sys-daemon-zig/build.zig
// PURPOSE: Zig build definition for sys-daemon-zig — FreeBSD daemon binary.
// INTENT: Standard Zig build.zig with libc linkage for FreeBSD syscalls.
//         Supports -Dplatform=<str> for comptime platform capability flags.
// DEPENDENCIES: std.Build.
// PUBLIC_API: build (pub fn).
// END_AI_HEADER

const std = @import("std");

// build:start
//   purpose: Define build targets, modules, run/test steps for this Zig binary.
//            Accepts -Dplatform=qemu_amd64|qemu_aarch64|bpi_m64|pinephone and
//            injects it as build_options so platform.zig can resolve comptime flags.
//   input:  b: standard Build object from zig build.
//   output: void (registers targets in b).
//   sideEffects: Registers executable, run step, test step in the Zig build graph.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // -Dplatform=<str>  — comptime platform selector
    // Valid values: qemu_amd64 | qemu_aarch64 | bpi_m64 | pinephone
    const platform = b.option(
        []const u8,
        "platform",
        "Target platform: qemu_amd64|qemu_aarch64|bpi_m64|pinephone",
    ) orelse "qemu_aarch64";

    // Build options module — imported as @import("build_options") in platform.zig
    const options = b.addOptions();
    options.addOption([]const u8, "platform", platform);

    const main_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    // Inject build_options so platform.zig can read the platform string at comptime
    main_module.addOptions("build_options", options);

    const exe = b.addExecutable(.{
        .name = "bsdos-hal",
        .root_module = main_module,
    });

    exe.linkLibC();

    b.installArtifact(exe);

    // Test step: zig build test
    // Use a separate module instance so tests get their own build_options injection
    const test_module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_module.addOptions("build_options", options);

    const unit_tests = b.addTest(.{
        .root_module = test_module,
    });

    unit_tests.linkLibC();

    const run_unit_tests = b.addRunArtifact(unit_tests);

    const test_step = b.step("test", "Run unit tests");
    test_step.dependOn(&run_unit_tests.step);
}
// build:end
