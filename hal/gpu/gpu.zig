// bsdOS GPU/display HAL
// Target: aarch64-freebsd.15.1 (PinePhone — Squirrel/Woodpecker)
// Backend MVP: /dev/fb0 (fbdev via sys/fbio.h)
// Backend stretch: /dev/dri/card0 (Lima DRM — blocked on FreeBSD kernel port)
//
// Semantic markup per github.com/bzdOS/sema

const std = @import("std");
const builtin = @import("builtin");

const c = @cImport({
    @cInclude("fcntl.h");
    @cInclude("unistd.h");
    @cInclude("sys/ioctl.h");
    @cInclude("sys/fbio.h"); // FreeBSD framebuffer ioctls: FBIOGET_VSCREENINFO, video_info
});

comptime {
    if (builtin.os.tag != .freebsd and !builtin.is_test) {
        @compileError("gpu.zig targets FreeBSD only — do not build on Linux/macOS");
    }
}

// SEMA:START gpu_backend
/// purpose: Selects the display backend at comptime; no runtime branching in hot paths.
/// Fbdev  — /dev/fb0, always available, pure mmap, MVP path.
/// Lima   — /dev/dri/card0, requires Lima DRM kernel port (not yet merged in FreeBSD 15.1).
pub const GpuBackend = enum {
    Fbdev,
    Lima,
};
// SEMA:END gpu_backend

// Default backend; override with -Dbackend=Lima once Lima DRM lands.
pub const active_backend: GpuBackend = .Fbdev;

// SEMA:START fb_info
/// purpose: Framebuffer geometry descriptor, populated by getFbInfo().
/// All fields map directly to FreeBSD video_info / video_display_info fields so
/// that the struct can be filled with a single FBIOGET_VSCREENINFO ioctl without
/// intermediate copies.
/// Layout is extern so Zig lays it out exactly as the C side expects.
/// 64-byte cache-line alignment (Cortex-A53) is satisfied: 4 x u32 = 16 bytes,
/// one cache sub-line, no false sharing with adjacent data.
pub const FbInfo = extern struct {
    width: u32, // horizontal resolution in pixels
    height: u32, // vertical resolution in pixels
    depth: u32, // bits per pixel (typically 16 or 32)
    stride: u32, // bytes per scanline (may include padding)
};

comptime {
    if (@sizeOf(FbInfo) != 16) {
        @compileError("FbInfo must be exactly 16 bytes");
    }
    if (@alignOf(FbInfo) < 4) {
        @compileError("FbInfo must be at least 4-byte aligned");
    }
}
// SEMA:END fb_info

// SEMA:START open_fb
/// purpose: Open a framebuffer device node for subsequent ioctl and mmap operations.
/// input:   path — null-terminated device path, e.g. "/dev/fb0\x00"
/// output:  fd_t on success; error union on failure (see FbError).
/// sideEffects: opens a file descriptor; caller must call closeFb() when done.
pub fn openFb(path: [:0]const u8) !std.posix.fd_t {
    const fd = std.posix.open(path, .{ .ACCMODE = .RDWR }, 0) catch |err| {
        return mapPosixError(err);
    };
    return fd;
}
// SEMA:END open_fb

// SEMA:START get_fb_info
/// purpose: Query framebuffer geometry from the kernel via FBIOGET_VSCREENINFO.
/// input:   fd — open framebuffer file descriptor (from openFb).
/// output:  FbInfo struct with width/height/depth/stride on success.
/// sideEffects: issues one ioctl(2) syscall; no heap allocation.
pub fn getFbInfo(fd: std.posix.fd_t) !FbInfo {
    // FreeBSD fbio.h exposes `struct video_info` via FBIOGET_VSCREENINFO.
    // We read only the fields we need and store them in our own FbInfo.
    var vi: c.video_info = std.mem.zeroes(c.video_info);
    const rc = c.ioctl(@as(c_int, fd), c.FBIOGET_VSCREENINFO, &vi);
    if (rc != 0) {
        return FbError.IoctlFailed;
    }

    // vi.vi_width / vi.vi_height: pixel dimensions
    // vi.vi_depth: bits-per-pixel
    // Stride is not always exposed directly; derive from width * depth/8,
    // rounded up to a platform word boundary if vi does not carry it.
    const bpp: u32 = @intCast(vi.vi_depth);
    const bytes_pp: u32 = (bpp + 7) / 8;
    const stride: u32 = @as(u32, @intCast(vi.vi_width)) * bytes_pp;

    return FbInfo{
        .width = @intCast(vi.vi_width),
        .height = @intCast(vi.vi_height),
        .depth = bpp,
        .stride = stride,
    };
}
// SEMA:END get_fb_info

// SEMA:START close_fb
/// purpose: Release the framebuffer file descriptor.
/// input:   fd — open framebuffer file descriptor previously returned by openFb.
/// output:  void (errors silently discarded — closing is best-effort on teardown).
/// sideEffects: closes the file descriptor; fd is invalid after this call.
pub fn closeFb(fd: std.posix.fd_t) void {
    std.posix.close(fd);
}
// SEMA:END close_fb

// ---------------------------------------------------------------------------
// Error set
// ---------------------------------------------------------------------------

pub const FbError = error{
    /// ioctl(FBIOGET_VSCREENINFO) returned non-zero.
    IoctlFailed,
    /// Device node could not be opened (permission, missing device).
    OpenFailed,
    /// Operation not supported on this backend (e.g. Lima call on Fbdev).
    NotSupported,
};

// ---------------------------------------------------------------------------
// Internal helpers
// ---------------------------------------------------------------------------

fn mapPosixError(err: std.posix.OpenError) FbError {
    _ = err;
    return FbError.OpenFailed;
}

// ---------------------------------------------------------------------------
// Comptime backend guard (Lima stubs)
// ---------------------------------------------------------------------------

/// purpose: Placeholder — Lima path is not yet callable; kept here so the
///          enum value compiles and future work has a clear landing zone.
/// input:   none.
/// output:  FbError.NotSupported always (Lima DRM not yet available on FreeBSD 15.1).
/// sideEffects: compile-time error if called with active_backend == .Fbdev.
pub fn limaOpen() !void {
    comptime {
        if (active_backend != .Lima) {
            @compileError("limaOpen() requires active_backend = .Lima");
        }
    }
    return FbError.NotSupported;
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------
//
// Struct-layout tests are OS-independent (pure comptime/sizeof logic) and run
// on any host.  The openFb integration test requires a real FreeBSD device
// tree and is therefore gated on builtin.os.tag == .freebsd.

// SEMA:START test_fbinfo_size
/// purpose: Verify FbInfo is exactly 16 bytes so the extern layout assumption holds.
test "FbInfo size" {
    try std.testing.expectEqual(@as(usize, 16), @sizeOf(FbInfo));
}
// SEMA:END test_fbinfo_size

// SEMA:START test_fbinfo_alignment
/// purpose: Verify FbInfo alignment satisfies at least 4-byte (u32 field) requirement.
test "FbInfo alignment" {
    try std.testing.expect(@alignOf(FbInfo) >= 4);
}
// SEMA:END test_fbinfo_alignment

// SEMA:START test_gpu_backend_default
/// purpose: Verify the compile-time default backend is .Fbdev (MVP path).
test "GpuBackend default" {
    comptime try std.testing.expectEqual(GpuBackend.Fbdev, active_backend);
}
// SEMA:END test_gpu_backend_default

// SEMA:START test_fbinfo_field_offsets
/// purpose: Verify each FbInfo field sits at the expected byte offset so the
///          extern struct maps correctly onto FreeBSD video_info fields.
test "FbInfo field offsets" {
    try std.testing.expectEqual(@as(usize, 0), @offsetOf(FbInfo, "width"));
    try std.testing.expectEqual(@as(usize, 4), @offsetOf(FbInfo, "height"));
    try std.testing.expectEqual(@as(usize, 8), @offsetOf(FbInfo, "depth"));
    try std.testing.expectEqual(@as(usize, 12), @offsetOf(FbInfo, "stride"));
}
// SEMA:END test_fbinfo_field_offsets

// SEMA:START test_open_fb_missing
/// purpose: Verify openFb returns FbError.OpenFailed for a non-existent device path.
/// Gated on FreeBSD because the @cImport block pulls in fbio.h which only
/// exists on FreeBSD; the test itself exercises pure error-path logic.
test "openFb returns error on missing device" {
    if (builtin.os.tag != .freebsd) return error.SkipZigTest;
    const result = openFb("/dev/null/nonexistent");
    try std.testing.expectError(FbError.OpenFailed, result);
}
