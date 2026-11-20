//! Small OS operations shared by the provider and core layers.
const std = @import("std");
const builtin = @import("builtin");
const win = struct {
    extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
    extern "kernel32" fn Sleep(ms: u32) callconv(.winapi) void;
    extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, buf: ?[*]u8, size: u32) callconv(.winapi) u32;
    extern "kernel32" fn GetTempPathA(size: u32, buf: [*]u8) callconv(.winapi) u32;
    extern "kernel32" fn GetCurrentDirectoryA(size: u32, buf: [*]u8) callconv(.winapi) u32;
};

pub fn ticks() u64 {
    return switch (builtin.os.tag) {
        .windows => win.GetTickCount64(),
        else => blk: {
            var threaded: std.Io.Threaded = .init(std.heap.page_allocator, .{});
            defer threaded.deinit();
            break :blk @intCast(@max(0, std.Io.Clock.awake.now(threaded.io()).toMilliseconds()));
        },
    };
}

pub fn sleep(ms: u32) void {
    switch (builtin.os.tag) {
        .windows => win.Sleep(ms),
        else => {
            var duration: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
            while (std.c.nanosleep(&duration, &duration) != 0) {
                if (std.c._errno().* != @intFromEnum(std.posix.E.INTR)) @panic("nanosleep failed");
            }
        },
    }
}

/// Matches the existing Windows size-query contract, including the trailing NUL.
pub fn env(name: [*:0]const u8, buf: ?[*]u8, size: u32) u32 {
    return switch (builtin.os.tag) {
        .windows => win.GetEnvironmentVariableA(name, buf, size),
        else => blk: {
            const raw = std.c.getenv(name) orelse return 0;
            const value = std.mem.span(raw);
            // Win32 returns the required capacity before accessing the buffer
            // when size is insufficient, including a null buffer with size > 0.
            if (value.len >= size) break :blk @intCast(value.len + 1);
            // A sufficient capacity requires a valid buffer. Reject a null
            // pointer on POSIX rather than attempting the invalid write.
            if (buf == null) {
                std.c._errno().* = @intFromEnum(std.posix.E.INVAL);
                return 0;
            }
            @memcpy(buf.?[0..value.len], value);
            buf.?[value.len] = 0;
            break :blk @intCast(value.len);
        },
    };
}

pub fn cwd(size: u32, buf: [*]u8) u32 {
    return switch (builtin.os.tag) {
        .windows => win.GetCurrentDirectoryA(size, buf),
        else => blk: {
            if (std.c.getcwd(buf, size) == null) break :blk 0;
            break :blk @intCast(std.mem.len(@as([*:0]u8, @ptrCast(buf))));
        },
    };
}

test "B10 platform: clock, sleep, missing environment and cwd" {
    const before = ticks();
    sleep(2);
    try std.testing.expect(ticks() >= before);
    var buf: [4096]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 0), env("DEVAGENTS_B10_MISSING_FIXTURE", &buf, buf.len));
    try std.testing.expect(cwd(buf.len, &buf) > 0);
    const needed = env("PATH", null, 0);
    try std.testing.expect(needed > 0);
    try std.testing.expectEqual(needed, env("PATH", &buf, 1));
    // Insufficient capacity returns the required size even with a null buffer.
    try std.testing.expectEqual(needed, env("PATH", null, needed - 1));
    if (builtin.os.tag != .windows) {
        try std.testing.expectEqual(@as(u32, 0), env("PATH", null, needed));
        try std.testing.expectEqual(@as(c_int, @intFromEnum(std.posix.E.INVAL)), std.c._errno().*);
    }
    try std.testing.expectEqual(needed, env("PATH", &buf, 0));
}

pub fn environ() std.process.Environ {
    return switch (builtin.os.tag) {
        .windows => .{ .block = .global },
        else => .{ .block = .{ .slice = std.mem.sliceTo(std.c.environ, null) } },
    };
}

pub fn random(_: ?*anyopaque, buf: [*]u8, size: u32, _: u32) i32 {
    var t: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer t.deinit();
    t.io().randomSecure(buf[0..size]) catch return -1;
    return 0;
}

pub fn filetime(output: anytype) void {
    var t: std.Io.Threaded = .init(std.heap.page_allocator, .{});
    defer t.deinit();
    const value: u64 = @intCast(@divFloor(std.Io.Clock.real.now(t.io()).nanoseconds, 100) + 116444736000000000);
    @memcpy(@as([*]u8, @ptrCast(output))[0..8], std.mem.asBytes(&value));
}

pub fn tempPath(size: u32, buf: [*]u8) u32 {
    if (builtin.os.tag == .windows) return win.GetTempPathA(size, buf);
    const root = if (std.c.getenv("TMPDIR")) |raw| std.mem.span(raw) else "/tmp";
    if (!std.fs.path.isAbsolute(root)) return 0;
    const slash = root.len == 0 or root[root.len - 1] != '/';
    const needed = root.len + @intFromBool(slash);
    if (needed >= size) return @intCast(needed + 1);
    @memcpy(buf[0..root.len], root);
    if (slash) buf[root.len] = '/';
    buf[needed] = 0;
    return @intCast(needed);
}

/// T9 (L7): omision por sistema con motivo, como `core/src/platform.zig`
/// `skip`. Devuelve `error.PlatformNotApplicable`, que el runner del proyecto
/// (tools/quiet_test_runner.zig) cuenta como omitida y no como fallo.
pub fn skip(comptime reason: []const u8) error{PlatformNotApplicable} {
    std.debug.print("SKIPPED_REASON=" ++ reason ++ "\n", .{});
    return error.PlatformNotApplicable;
}
