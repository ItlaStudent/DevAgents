const std = @import("std");
const builtin = @import("builtin");
/// T9: `nlink`, `dev` and `ino` let callers reject hard links and compare the
/// identity of a retained object (the POSIX side of confined_fs.identity).
pub const Metadata = struct { mode: u32, uid: u32, size: i64, nlink: u64 = 1, dev: u64 = 0, ino: u64 = 0, mtime_sec: i64 = 0, mtime_nsec: u32 = 0 };
extern "c" fn fstat(fd: std.c.fd_t, stat: *std.c.Stat) c_int;
extern "c" fn lstat(path: [*:0]const u8, stat: *std.c.Stat) c_int;

pub fn get(fd: std.c.fd_t, path: ?[*:0]const u8) !Metadata {
    return switch (builtin.os.tag) {
        .linux => blk: {
            const linux = std.os.linux;
            var stat: linux.Statx = undefined;
            if (std.c.statx(fd, path orelse "", if (path == null) linux.AT.EMPTY_PATH else linux.AT.SYMLINK_NOFOLLOW, .{ .TYPE = true, .MODE = true, .UID = true, .SIZE = true, .NLINK = true, .INO = true, .MTIME = true }, &stat) != 0) return error.StatFailed;
            break :blk .{
                .mode = stat.mode,
                .uid = stat.uid,
                .size = @intCast(stat.size),
                .nlink = stat.nlink,
                .dev = (@as(u64, stat.dev_major) << 32) | stat.dev_minor,
                .ino = stat.ino,
                .mtime_sec = stat.mtime.sec,
                .mtime_nsec = stat.mtime.nsec,
            };
        },
        else => blk: {
            var stat: std.c.Stat = undefined;
            if ((if (path) |p| lstat(p, &stat) else fstat(fd, &stat)) != 0) return error.StatFailed;
            break :blk .{ .mode = stat.mode, .uid = stat.uid, .size = stat.size, .nlink = stat.nlink, .dev = @intCast(stat.dev), .ino = @intCast(stat.ino), .mtime_sec = @intCast(stat.mtime().sec), .mtime_nsec = @intCast(stat.mtime().nsec) };
        },
    };
}
