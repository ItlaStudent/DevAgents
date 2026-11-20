//! Shared Win32 user-only DACL for data roots and sensitive files.
//! T9: fuera de Windows el equivalente es propietario = usuario actual y modo
//! 0700 (carpetas) / 0600 (archivos), comprobados sobre el descriptor abierto.
const std = @import("std");
const is_windows = @import("builtin").os.tag == .windows;
extern fn da_private_data_directory([*:0]const u16) u32;
extern fn da_private_data_protect_file([*:0]const u16) u32;
extern fn da_private_data_write_new([*:0]const u16, [*]const u8, u32) u32;
extern "kernel32" fn SetLastError(u32) callconv(.winapi) void;

pub fn ensureDirectory(a: std.mem.Allocator, path: []const u8) !void {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (!is_windows) return posixEnsureDirectory(a, path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    const code = da_private_data_directory(wide);
    if (code != 0) {
        std.debug.print("private_data.ensureDirectory Win32={d}\n", .{code});
        SetLastError(code);
        return error.PrivateDataDirectoryFailed;
    }
}

pub fn protectFile(a: std.mem.Allocator, path: []const u8) !void {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (!is_windows) return posixProtect(a, path, false);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    const code = da_private_data_protect_file(wide);
    if (code != 0) {
        std.debug.print("private_data.protectFile Win32={d}\n", .{code});
        SetLastError(code);
        return error.PrivateDataFileFailed;
    }
}

pub fn writeNew(a: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidPath;
    if (!is_windows) return posixWriteNew(a, path, data);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    const code = da_private_data_write_new(wide, data.ptr, std.math.cast(u32, data.len) orelse return error.FileTooBig);
    if (code != 0) {
        std.debug.print("private_data.writeNew Win32={d}\n", .{code});
        SetLastError(code);
        return error.PrivateDataWriteFailed;
    }
}

const c = std.c;

fn posixEnsureDirectory(a: std.mem.Allocator, path: []const u8) !void {
    if (!std.fs.path.isAbsolutePosix(path)) return error.InvalidPath;
    var t: std.Io.Threaded = .init(a, .{});
    defer t.deinit();
    std.Io.Dir.cwd().createDirPath(t.io(), path) catch return error.PrivateDataDirectoryFailed;
    return posixProtect(a, path, true);
}

/// Opens without following a final link, requires the current user as owner
/// and removes every group/other permission (0700 or 0600).
fn posixProtect(a: std.mem.Allocator, path: []const u8, directory: bool) !void {
    const z = try a.dupeZ(u8, path);
    defer a.free(z);
    const fd = c.open(z, .{ .ACCMODE = .RDONLY, .DIRECTORY = directory, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true });
    if (fd < 0) return if (directory) error.PrivateDataDirectoryFailed else error.PrivateDataFileFailed;
    defer _ = c.close(fd);
    const meta = @import("providers").posix_stat.get(fd, null) catch return error.PrivateDataFileFailed;
    const kind = meta.mode & c.S.IFMT;
    if (kind != @as(u32, if (directory) c.S.IFDIR else c.S.IFREG)) return if (directory) error.PrivateDataDirectoryFailed else error.PrivateDataFileFailed;
    if (meta.uid != c.getuid()) return if (directory) error.PrivateDataDirectoryFailed else error.PrivateDataFileFailed;
    const wanted: c.mode_t = if (directory) @as(c.mode_t, 0o700) else @as(c.mode_t, 0o600);
    if (meta.mode & 0o777 != wanted and c.fchmod(fd, wanted) != 0) return if (directory) error.PrivateDataDirectoryFailed else error.PrivateDataFileFailed;
}

fn posixWriteNew(a: std.mem.Allocator, path: []const u8, data: []const u8) !void {
    const z = try a.dupeZ(u8, path);
    defer a.free(z);
    const fd = c.open(z, .{ .ACCMODE = .WRONLY, .CREAT = true, .EXCL = true, .NOFOLLOW = true, .CLOEXEC = true }, @as(c.mode_t, 0o600));
    if (fd < 0) return error.PrivateDataWriteFailed;
    var ok = false;
    defer {
        _ = c.close(fd);
        if (!ok) _ = c.unlink(z);
    }
    var offset: usize = 0;
    while (offset < data.len) {
        const n = c.write(fd, data.ptr + offset, data.len - offset);
        if (n < 0 and c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
        if (n <= 0) return error.PrivateDataWriteFailed;
        offset += @intCast(n);
    }
    if (c.fsync(fd) != 0) return error.PrivateDataWriteFailed;
    ok = true;
}

test "T9 POSIX private data: owner-only directory and new file" {
    if (is_windows) return @import("platform.zig").skip("T9: la DACL de Windows se prueba en private_data_security; aqui solo POSIX");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const dir = try std.fs.path.join(a, &.{ base, "datos", "privados" });
    defer a.free(dir);
    try ensureDirectory(a, dir);
    const dir_z = try a.dupeZ(u8, dir);
    defer a.free(dir_z);
    try std.testing.expectEqual(@as(u32, 0o700), (try @import("providers").posix_stat.get(c.AT.FDCWD, dir_z)).mode & 0o777);
    const file = try std.fs.path.join(a, &.{ dir, "secreto" });
    defer a.free(file);
    try writeNew(a, file, "x");
    try std.testing.expectError(error.PrivateDataWriteFailed, writeNew(a, file, "y"));
    const file_z = try a.dupeZ(u8, file);
    defer a.free(file_z);
    try std.testing.expectEqual(@as(u32, 0o600), (try @import("providers").posix_stat.get(c.AT.FDCWD, file_z)).mode & 0o777);
    try protectFile(a, file);
}
