//! Headless subprocess capture: separate process group, bounded streams and deadline.
const std = @import("std");
const platform = @import("platform.zig");
const c = std.c;
pub const Capture = struct { stdout: []u8, stderr: []u8, exit_code: u32, timed_out: bool, stdout_total: usize, stderr_total: usize };

pub fn run(a: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, input: ?[]const u8, extra_env: ?[]const []const u8, timeout_ms: u32, cap: usize) !Capture {
    if (argv.len == 0 or timeout_ms == 0) return error.InvalidArguments;
    var env = try std.process.Environ.createMap(platform.environ(), a);
    defer env.deinit();
    if (extra_env) |values| for (values) |entry| {
        const split = std.mem.indexOfScalar(u8, entry, '=') orelse return error.InvalidEnvironment;
        if (split == 0) return error.InvalidEnvironment;
        try env.put(entry[0..split], entry[split + 1 ..]);
    };
    return runEnv(a, argv, cwd, input, &env, timeout_ms, cap);
}

/// T9: igual que `run` pero con el entorno COMPLETO del hijo dado por el
/// llamador (p. ej. el filtrado de command_environment); no hereda nada.
pub fn runEnv(a: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, input: ?[]const u8, env: *const std.process.Environ.Map, timeout_ms: u32, cap: usize) !Capture {
    if (argv.len == 0 or timeout_ms == 0) return error.InvalidArguments;
    var t: std.Io.Threaded = .init(a, .{});
    defer t.deinit();
    const io = t.io();
    var child = try std.process.spawn(io, .{ .argv = argv, .cwd = if (cwd) |p| .{ .path = p } else .inherit, .environ_map = env, .stdin = .pipe, .stdout = .pipe, .stderr = .pipe, .pgid = 0 });
    const pid = child.id orelse return error.SpawnFailed;
    var reaped_status: ?u32 = null;
    defer {
        if (c.kill(-pid, c.SIG.KILL) != 0 and c._errno().* != @intFromEnum(std.posix.E.SRCH)) std.log.err("POSIX process group cleanup failed", .{});
        if (reaped_status != null) {
            if (child.stdin) |file| file.close(io);
            if (child.stdout) |file| file.close(io);
            if (child.stderr) |file| file.close(io);
            child.stdin = null;
            child.stdout = null;
            child.stderr = null;
            child.id = null;
        } else child.kill(io);
    }
    for ([_]std.Io.File{ child.stdin.?, child.stdout.?, child.stderr.? }) |file| {
        const flags = c.fcntl(file.handle, c.F.GETFL);
        if (flags < 0 or c.fcntl(file.handle, c.F.SETFL, flags | @as(c_int, @intCast(@as(u32, @bitCast(c.O{ .NONBLOCK = true }))))) < 0) return error.PipeFailed;
    }
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    var err: std.ArrayList(u8) = .empty;
    errdefer err.deinit(a);
    var totals = [_]usize{ 0, 0 };
    var polls = [_]c.pollfd{
        .{ .fd = child.stdout.?.handle, .events = c.POLL.IN, .revents = 0 },
        .{ .fd = child.stderr.?.handle, .events = c.POLL.IN, .revents = 0 },
        .{ .fd = child.stdin.?.handle, .events = c.POLL.OUT, .revents = 0 },
    };
    const bytes = input orelse "";
    var input_offset: usize = 0;
    var timed_out = false;
    const start = platform.ticks();
    while (polls[0].fd >= 0 or polls[1].fd >= 0 or reaped_status == null) {
        if (reaped_status == null) {
            var status: c_int = 0;
            const waited = c.waitpid(pid, &status, c.W.NOHANG);
            if (waited == pid) reaped_status = @bitCast(status) else if (waited < 0 and c._errno().* != @intFromEnum(std.posix.E.INTR)) return error.WaitFailed;
        }
        const elapsed = platform.ticks() - start;
        if (elapsed >= timeout_ms) {
            timed_out = true;
            break;
        }
        const n = c.poll(&polls, polls.len, @intCast(@min(50, timeout_ms - elapsed)));
        if (n < 0) {
            if (c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
            return error.PollFailed;
        }
        if (polls[2].fd >= 0 and input_offset == bytes.len) {
            child.stdin.?.close(io);
            child.stdin = null;
            polls[2].fd = -1;
        } else if (polls[2].fd >= 0 and polls[2].revents != 0) {
            const sent = c.write(polls[2].fd, bytes.ptr + input_offset, @min(4096, bytes.len - input_offset));
            if (sent > 0) input_offset += @intCast(sent) else if (sent < 0 and c._errno().* != @intFromEnum(std.posix.E.AGAIN) and c._errno().* != @intFromEnum(std.posix.E.INTR)) {
                child.stdin.?.close(io);
                child.stdin = null;
                polls[2].fd = -1;
            }
        }
        for (0..2) |i| {
            if (polls[i].fd < 0 or polls[i].revents == 0) continue;
            var buffer: [8192]u8 = undefined;
            const count = c.read(polls[i].fd, &buffer, buffer.len);
            if (count == 0) {
                polls[i].fd = -1;
                continue;
            }
            if (count < 0) {
                if (c._errno().* == @intFromEnum(std.posix.E.AGAIN) or c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
                return error.PipeFailed;
            }
            const len: usize = @intCast(count);
            totals[i] += len;
            const list = if (i == 0) &out else &err;
            try list.appendSlice(a, buffer[0..@min(len, cap - @min(cap, list.items.len))]);
        }
    }
    if (timed_out) {
        if (c.kill(-pid, c.SIG.KILL) != 0 and c._errno().* != @intFromEnum(std.posix.E.SRCH)) return error.KillFailed;
    }
    const exit_code: u32 = if (reaped_status) |status| (if (status & 0x7f == 0) (status >> 8) & 0xff else 128 + (status & 0x7f)) else blk: {
        const term = try child.wait(io);
        break :blk switch (term) {
            .exited => |code| code,
            .signal => |signal| 128 + @as(u32, @intFromEnum(signal)),
            else => 1,
        };
    };
    const stdout = try out.toOwnedSlice(a);
    errdefer a.free(stdout);
    return .{ .stdout = stdout, .stderr = try err.toOwnedSlice(a), .exit_code = exit_code, .timed_out = timed_out, .stdout_total = totals[0], .stderr_total = totals[1] };
}

test "B10 POSIX process captures bounded stdout/stderr, stdin, exit and timeout" {
    const a = std.testing.allocator;
    const r = try run(a, &.{ "/bin/sh", "-c", "cat; printf error >&2; exit 7" }, null, "hello", null, 5000, 3);
    defer a.free(r.stdout);
    defer a.free(r.stderr);
    try std.testing.expectEqualStrings("hel", r.stdout);
    try std.testing.expectEqualStrings("err", r.stderr);
    try std.testing.expectEqual(@as(usize, 5), r.stdout_total);
    try std.testing.expectEqual(@as(u32, 7), r.exit_code);
    try std.testing.expect(!r.timed_out);
    const hung = try run(a, &.{ "/bin/sh", "-c", "exec 1>&- 2>&-; sleep 10" }, null, null, null, 100, 8);
    defer a.free(hung.stdout);
    defer a.free(hung.stderr);
    try std.testing.expect(hung.timed_out);
    try std.testing.expectError(error.InvalidArguments, run(a, &.{}, null, null, null, 1, 8));
    try std.testing.expectError(error.InvalidEnvironment, run(a, &.{"/bin/true"}, null, null, &.{"invalid"}, 100, 8));
}
