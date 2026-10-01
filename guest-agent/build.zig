// START_AI_HEADER
// MODULE: guest-agent/build.zig
// PURPOSE: Zig build definition for guest-agent — FreeBSD daemon binary.
// INTENT: Standard Zig build.zig with libc linkage for FreeBSD syscalls.
// DEPENDENCIES: std.Build.
// PUBLIC_API: build (pub fn).
// END_AI_HEADER

const std = @import("std");

// build:start
//   purpose: Define build targets for bsdos-agent Zig binary.
//   input:  b: standard Build object from zig build.
//   output: void (registers targets in b).
//   sideEffects: Registers executable in the Zig build graph.
pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const exe_mod = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    const exe = b.addExecutable(.{
        .name = "bsdos-agent",
        .root_module = exe_mod,
    });
    exe.linkLibC();

    b.installArtifact(exe);
}
// build:end
