//! POSIX implementation of the small file operations used by legacy callers.
//! Handles encode fd+1 so fd 0 remains representable; failed opens use -1.
const std = @import("std");
const c = std.c;
const H = std.os.windows.HANDLE;
const invalid: H = @ptrFromInt(~@as(usize, 0));
extern "c" fn fstat(fd: c.fd_t, stat: *c.Stat) c_int;
extern "c" fn lstat(path: [*:0]const u8, stat: *c.Stat) c_int;
extern "c" fn realpath(path: [*:0]const u8, resolved: [*]u8) ?[*:0]u8;

fn fd(h: ?H) c.fd_t {
    return if (h == null or h == invalid) -1 else @intCast(@intFromPtr(h.?) - 1);
}
fn normalized(path: [*:0]const u8, buf: *[4096:0]u8) ?[:0]u8 {
    const raw = std.mem.span(path);
    if (raw.len >= buf.len) return null;
    for (raw, 0..) |b, i| buf[i] = if (b == '\\') '/' else b;
    buf[raw.len] = 0;
    return buf[0..raw.len :0];
}

pub fn CreateFileA(path: [*:0]const u8, access: u32, _: u32, _: ?*anyopaque, disposition: u32, attrs: u32, _: ?H) H {
    var buffer: [4096:0]u8 = undefined;
    const p = normalized(path, &buffer) orelse return invalid;
    var flags: c.O = .{ .ACCMODE = if (access & 0x40000000 != 0) (if (access & 0x80000000 != 0) .RDWR else .WRONLY) else .RDONLY, .CLOEXEC = true };
    if (attrs & 0x00200000 != 0) flags.NOFOLLOW = true;
    switch (disposition) {
        1 => {
            flags.CREAT = true;
            flags.EXCL = true;
        },
        2 => {
            flags.CREAT = true;
            flags.TRUNC = true;
        },
        3 => {},
        4 => flags.CREAT = true,
        5 => flags.TRUNC = true,
        else => return invalid,
    }
    const result = c.open(p, flags, @as(c.mode_t, 0o600));
    if (result < 0) return invalid;
    return @ptrFromInt(@as(usize, @intCast(result)) + 1);
}
pub fn CloseHandle(h: ?H) c_int {
    return if (c.close(fd(h)) == 0) 1 else 0;
}
pub fn ReadFile(h: ?H, buf: [*]u8, size: u32, count: ?*u32, _: ?*anyopaque) c_int {
    const n = c.read(fd(h), buf, size);
    if (count) |p| p.* = if (n < 0) 0 else @intCast(n);
    return if (n < 0) 0 else 1;
}
pub fn WriteFile(h: ?H, buf: [*]const u8, size: u32, count: *u32, _: ?*anyopaque) c_int {
    const n = c.write(fd(h), buf, size);
    count.* = if (n < 0) 0 else @intCast(n);
    return if (n < 0) 0 else 1;
}
pub fn GetFileSizeEx(h: ?H, size: *i64) c_int {
    const stat = @import("posix_stat.zig").get(fd(h), null) catch return 0;
    size.* = stat.size;
    return 1;
}
pub fn GetFileSize(h: ?H, high: ?*u32) u32 {
    var size: i64 = 0;
    if (GetFileSizeEx(h, &size) == 0 or size < 0) return 0xffffffff;
    if (high) |p| p.* = @intCast(@as(u64, @intCast(size)) >> 32);
    return @truncate(@as(u64, @intCast(size)));
}
pub fn GetFileAttributesA(path: [*:0]const u8) u32 {
    var buffer: [4096:0]u8 = undefined;
    const p = normalized(path, &buffer) orelse return 0xffffffff;
    const stat = @import("posix_stat.zig").get(c.AT.FDCWD, p) catch return 0xffffffff;
    return (if (stat.mode & c.S.IFMT == c.S.IFDIR) @as(u32, 0x10) else 0x80) | (if (stat.mode & c.S.IFMT == c.S.IFLNK) @as(u32, 0x400) else 0);
}
pub fn CreateDirectoryA(path: [*:0]const u8, _: ?*anyopaque) c_int {
    var buf: [4096:0]u8 = undefined;
    return if (c.mkdir(normalized(path, &buf) orelse return 0, 0o700) == 0) 1 else 0;
}
pub fn DeleteFileA(path: [*:0]const u8) c_int {
    var buf: [4096:0]u8 = undefined;
    return if (c.unlink(normalized(path, &buf) orelse return 0) == 0) 1 else 0;
}
pub fn RemoveDirectoryA(path: [*:0]const u8) c_int {
    var buf: [4096:0]u8 = undefined;
    return if (c.rmdir(normalized(path, &buf) orelse return 0) == 0) 1 else 0;
}
pub fn GetFullPathNameA(path: [*:0]const u8, size: u32, buf: [*]u8, _: ?*?[*:0]u8) u32 {
    const a = std.heap.page_allocator;
    var buffer: [4096:0]u8 = undefined;
    const p = normalized(path, &buffer) orelse return 0;
    var current: [4096]u8 = undefined;
    const wd = c.getcwd(&current, current.len) orelse return 0;
    const resolved = std.fs.path.resolvePosix(a, &.{ std.mem.span(@as([*:0]u8, @ptrCast(wd))), p }) catch return 0;
    defer a.free(resolved);
    if (resolved.len >= size) return @intCast(resolved.len + 1);
    @memcpy(buf[0..resolved.len], resolved);
    buf[resolved.len] = 0;
    return @intCast(resolved.len);
}
pub fn canonical(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const z = try allocator.dupeZ(u8, path);
    defer allocator.free(z);
    var normalized_buf: [4096:0]u8 = undefined;
    var result: [4096]u8 = undefined;
    if (realpath(normalized(z, &normalized_buf) orelse return error.InvalidPath, &result) == null) return error.FileNotFound;
    return allocator.dupe(u8, std.mem.span(@as([*:0]u8, @ptrCast(&result))));
}

fn narrow(path: [*:0]const u16) ![:0]u8 {
    return std.unicode.utf16LeToUtf8AllocZ(std.heap.page_allocator, std.mem.span(path));
}
pub fn CreateFileW(path: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, disposition: u32, attrs: u32, template: ?H) H {
    const z = narrow(path) catch return invalid;
    defer std.heap.page_allocator.free(z);
    return CreateFileA(z, access, share, security, disposition, attrs, template);
}
pub fn GetFileAttributesW(path: [*:0]const u16) u32 {
    const z = narrow(path) catch return 0xffffffff;
    defer std.heap.page_allocator.free(z);
    return GetFileAttributesA(z);
}
pub fn CreateDirectoryW(path: [*:0]const u16, security: ?*anyopaque) c_int {
    const z = narrow(path) catch return 0;
    defer std.heap.page_allocator.free(z);
    return CreateDirectoryA(z, security);
}
pub fn SetFilePointerEx(h: H, offset: i64, result: ?*i64, method: u32) c_int {
    const n = c.lseek(fd(h), offset, @intCast(method));
    if (n < 0) return 0;
    if (result) |p| p.* = n;
    return 1;
}

pub fn DeleteFileW(path: [*:0]const u16) c_int {
    const z = narrow(path) catch return 0;
    defer std.heap.page_allocator.free(z);
    return DeleteFileA(z);
}
pub fn RemoveDirectoryW(path: [*:0]const u16) c_int {
    const z = narrow(path) catch return 0;
    defer std.heap.page_allocator.free(z);
    return RemoveDirectoryA(z);
}
/// MOVEFILE_REPLACE_EXISTING (1) is rename(2)'s behaviour; without it an
/// existing target is refused, as on Windows.
pub fn MoveFileExA(from: [*:0]const u8, to: [*:0]const u8, flags: u32) c_int {
    var a_buf: [4096:0]u8 = undefined;
    var b_buf: [4096:0]u8 = undefined;
    const src = normalized(from, &a_buf) orelse return 0;
    const dst = normalized(to, &b_buf) orelse return 0;
    if (flags & 1 == 0) {
        if (@import("posix_stat.zig").get(c.AT.FDCWD, dst)) |_| {
            c._errno().* = @intFromEnum(std.posix.E.EXIST);
            return 0;
        } else |_| {}
    }
    return if (c.rename(src, dst) == 0) 1 else 0;
}
pub fn MoveFileExW(from: [*:0]const u16, to: [*:0]const u16, flags: u32) c_int {
    const x = narrow(from) catch return 0;
    defer std.heap.page_allocator.free(x);
    const y = narrow(to) catch return 0;
    defer std.heap.page_allocator.free(y);
    return MoveFileExA(x, y, flags);
}
pub fn SetEndOfFile(h: ?H) c_int {
    const pos = c.lseek(fd(h), 0, c.SEEK.CUR);
    if (pos < 0) return 0;
    return if (c.ftruncate(fd(h), pos) == 0) 1 else 0;
}
pub fn FlushFileBuffers(h: ?H) c_int {
    return if (c.fsync(fd(h)) == 0) 1 else 0;
}

/// LOCKFILE_EXCLUSIVE_LOCK (2) and LOCKFILE_FAIL_IMMEDIATELY (1) over flock(2):
/// whole-file advisory lock; contention reports ERROR_LOCK_VIOLATION (33).
pub fn LockFileEx(h: ?H, flags: u32, _: u32, _: u32, _: u32, _: anytype) c_int {
    var op: c_int = if (flags & 2 != 0) c.LOCK.EX else c.LOCK.SH;
    if (flags & 1 != 0) op |= c.LOCK.NB;
    return if (c.flock(fd(h), op) == 0) 1 else 0;
}
pub fn UnlockFileEx(h: ?H, _: u32, _: u32, _: u32, _: anytype) c_int {
    return if (c.flock(fd(h), c.LOCK.UN) == 0) 1 else 0;
}

pub fn GetCurrentProcessId() u32 {
    return @intCast(c.getpid());
}
/// GetFileExInfoStandard (level 0): attributes, three FILETIMEs, size.
pub fn GetFileAttributesExW(path: [*:0]const u16, level: c_int, info: *anyopaque) c_int {
    if (level != 0) return 0;
    const z = narrow(path) catch return 0;
    defer std.heap.page_allocator.free(z);
    var buffer: [4096:0]u8 = undefined;
    const p = normalized(z, &buffer) orelse return 0;
    const st = @import("posix_stat.zig").get(c.AT.FDCWD, p) catch return 0;
    const Data = extern struct { attributes: u32, creation: [2]u32, access: [2]u32, write: [2]u32, size_high: u32, size_low: u32 };
    const out: *Data = @ptrCast(@alignCast(info));
    const kind = st.mode & c.S.IFMT;
    const ft: u64 = @intCast(@max(0, @as(i128, st.mtime_sec) * 10_000_000 + @divTrunc(@as(i128, st.mtime_nsec), 100) + 116444736000000000));
    const size: u64 = @intCast(@max(st.size, 0));
    out.* = .{
        .attributes = (if (kind == c.S.IFDIR) @as(u32, 0x10) else 0x80) | (if (kind == c.S.IFLNK) @as(u32, 0x400) else 0),
        .creation = .{ @truncate(ft), @intCast(ft >> 32) },
        .access = .{ @truncate(ft), @intCast(ft >> 32) },
        .write = .{ @truncate(ft), @intCast(ft >> 32) },
        .size_high = @intCast(size >> 32),
        .size_low = @truncate(size),
    };
    return 1;
}
/// Same size contract as the Windows call, in UTF-16 units.
pub fn GetEnvironmentVariableW(name: [*:0]const u16, buf: ?[*]u16, size: u32) u32 {
    const a = std.heap.page_allocator;
    const key = narrow(name) catch return 0;
    defer a.free(key);
    const raw = c.getenv(key) orelse return 0;
    const wide = std.unicode.utf8ToUtf16LeAlloc(a, std.mem.span(raw)) catch return 0;
    defer a.free(wide);
    if (buf == null or wide.len >= size) return @intCast(wide.len + 1);
    @memcpy(buf.?[0..wide.len], wide);
    buf.?[wide.len] = 0;
    return @intCast(wide.len);
}
extern "c" fn statvfs(path: [*:0]const u8, buf: *Statvfs) c_int;
const Statvfs = extern struct {
    f_bsize: c_ulong,
    f_frsize: c_ulong,
    f_blocks: u64,
    f_bfree: u64,
    f_bavail: u64,
    f_files: u64,
    f_ffree: u64,
    f_favail: u64,
    f_fsid: c_ulong,
    f_flag: c_ulong,
    f_namemax: c_ulong,
    spare: [6]c_int,
};
pub fn GetDiskFreeSpaceExW(dir: [*:0]const u16, free_to_caller: ?*u64, total: ?*u64, total_free: ?*u64) i32 {
    if (@import("builtin").os.tag != .linux) return 0;
    const z = narrow(dir) catch return 0;
    defer std.heap.page_allocator.free(z);
    var buffer: [4096:0]u8 = undefined;
    const p = normalized(z, &buffer) orelse return 0;
    var st: Statvfs = undefined;
    if (statvfs(p, &st) != 0) return 0;
    if (free_to_caller) |x| x.* = st.f_bavail * st.f_frsize;
    if (total) |x| x.* = st.f_blocks * st.f_frsize;
    if (total_free) |x| x.* = st.f_bfree * st.f_frsize;
    return 1;
}
pub fn GetFullPathNameW(path: [*:0]const u16, size: u32, buf: [*]u16, _: ?*?[*:0]u16) u32 {
    const a = std.heap.page_allocator;
    const z = narrow(path) catch return 0;
    defer a.free(z);
    var narrow_buf: [4096]u8 = undefined;
    const n = GetFullPathNameA(z, narrow_buf.len, &narrow_buf, null);
    if (n == 0 or n >= narrow_buf.len) return 0;
    const wide = std.unicode.utf8ToUtf16LeAlloc(a, narrow_buf[0..n]) catch return 0;
    defer a.free(wide);
    if (wide.len >= size) return @intCast(wide.len + 1);
    @memcpy(buf[0..wide.len], wide);
    buf[wide.len] = 0;
    return @intCast(wide.len);
}

pub fn SetLastError(code: u32) void {
    c._errno().* = @intCast(code);
}
/// STD_INPUT/OUTPUT/ERROR_HANDLE (-10/-11/-12 as u32) -> fd 0/1/2 (encoded).
pub fn GetStdHandle(which: u32) H {
    const fd_value: usize = switch (which) {
        0xFFFFFFF6 => 0,
        0xFFFFFFF5 => 1,
        0xFFFFFFF4 => 2,
        else => return invalid,
    };
    return @ptrFromInt(fd_value + 1);
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
/// null value removes the variable, as on Windows.
pub fn SetEnvironmentVariableA(name: [*:0]const u8, value: ?[*:0]const u8) c_int {
    const rc = if (value) |v| setenv(name, v, 1) else unsetenv(name);
    return if (rc == 0) 1 else 0;
}

const FindData = extern struct {
    dwFileAttributes: u32,
    times: [6]u32,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    reserved: [2]u32,
    cFileName: [260]u8,
    alternate: [14]u8,
};
const FindDataW = extern struct {
    dwFileAttributes: u32,
    times: [6]u32,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    reserved: [2]u32,
    cFileName: [260]u16,
    alternate: [14]u16,
};
const Listing = struct {
    threaded: std.Io.Threaded,
    dir: std.Io.Dir,
    iterator: std.Io.Dir.Iterator,
    pattern: []u8,
};
fn nextListing(list: *Listing, data: anytype) c_int {
    const a = std.heap.page_allocator;
    while (true) {
        const entry = (list.iterator.next(list.threaded.io()) catch return 0) orelse return 0;
        if (!std.mem.eql(u8, list.pattern, "*") and !std.mem.eql(u8, list.pattern, "*.*") and !std.mem.eql(u8, list.pattern, entry.name)) {
            const star = std.mem.indexOfScalar(u8, list.pattern, '*') orelse continue;
            if (entry.name.len < list.pattern.len - 1 or
                !std.mem.startsWith(u8, entry.name, list.pattern[0..star]) or
                !std.mem.endsWith(u8, entry.name, list.pattern[star + 1 ..])) continue;
        }
        const info = list.dir.statFile(list.threaded.io(), entry.name, .{ .follow_symlinks = false }) catch return 0;
        data.* = std.mem.zeroes(@TypeOf(data.*));
        // Legacy callers use FILETIME to expire old artifacts. A zero mtime
        // makes a newly written directory look centuries old and deletes it.
        const modified: u64 = @intCast(@divFloor(info.mtime.nanoseconds, 100) + 116444736000000000);
        data.times[4] = @truncate(modified);
        data.times[5] = @intCast(modified >> 32);
        data.dwFileAttributes = if (info.kind == .directory) 0x10 else if (info.kind == .sym_link) 0x400 else 0x80;
        data.nFileSizeHigh = @intCast(info.size >> 32);
        data.nFileSizeLow = @truncate(info.size);
        if (@TypeOf(data.cFileName[0]) == u16) {
            const wide = std.unicode.utf8ToUtf16LeAlloc(a, entry.name) catch return 0;
            defer a.free(wide);
            if (wide.len >= data.cFileName.len) return 0;
            @memcpy(data.cFileName[0..wide.len], wide);
        } else {
            if (entry.name.len >= data.cFileName.len) return 0;
            @memcpy(data.cFileName[0..entry.name.len], entry.name);
        }
        return 1;
    }
}
fn startListing(pattern: [*:0]const u8) ?*Listing {
    const a = std.heap.page_allocator;
    var buffer: [4096:0]u8 = undefined;
    const path = normalized(pattern, &buffer) orelse return null;
    const base = std.fs.path.dirname(path) orelse ".";
    const list = a.create(Listing) catch return null;
    list.threaded = .init(a, .{});
    list.dir = std.Io.Dir.cwd().openDir(list.threaded.io(), base, .{ .iterate = true }) catch {
        list.threaded.deinit();
        a.destroy(list);
        return null;
    };
    list.pattern = a.dupe(u8, std.fs.path.basename(path)) catch {
        list.dir.close(list.threaded.io());
        list.threaded.deinit();
        a.destroy(list);
        return null;
    };
    list.iterator = list.dir.iterate();
    return list;
}
pub fn FindFirstFileA(pattern: [*:0]const u8, data: anytype) H {
    const list = startListing(pattern) orelse return invalid;
    const handle: H = @ptrCast(list);
    if (nextListing(list, @as(*FindData, @ptrCast(@alignCast(data)))) == 0) {
        _ = FindClose(handle);
        return invalid;
    }
    return handle;
}
pub fn FindNextFileA(h: H, data: anytype) c_int {
    return nextListing(@as(*Listing, @ptrCast(@alignCast(h))), @as(*FindData, @ptrCast(@alignCast(data))));
}
pub fn FindFirstFileW(pattern: [*:0]const u16, data: *anyopaque) H {
    const z = narrow(pattern) catch return invalid;
    defer std.heap.page_allocator.free(z);
    const list = startListing(z) orelse return invalid;
    const handle: H = @ptrCast(list);
    if (nextListing(list, @as(*FindDataW, @ptrCast(@alignCast(data)))) == 0) {
        _ = FindClose(handle);
        return invalid;
    }
    return handle;
}
pub fn FindNextFileW(h: H, data: *anyopaque) c_int {
    return nextListing(@as(*Listing, @ptrCast(@alignCast(h))), @as(*FindDataW, @ptrCast(@alignCast(data))));
}
pub fn FindClose(h: H) c_int {
    const list: *Listing = @ptrCast(@alignCast(h));
    list.dir.close(list.threaded.io());
    list.threaded.deinit();
    std.heap.page_allocator.free(list.pattern);
    std.heap.page_allocator.destroy(list);
    return 1;
}
pub fn CopyFileA(source: [*:0]const u8, target: [*:0]const u8, exclusive: c_int) c_int {
    const from = CreateFileA(source, 0x80000000, 0, null, 3, 0x00200000, null);
    if (from == invalid) return 0;
    defer _ = CloseHandle(from);
    const to = CreateFileA(target, 0x40000000, 0, null, if (exclusive != 0) 1 else 2, 0x00200000, null);
    if (to == invalid) return 0;
    defer _ = CloseHandle(to);
    var buf: [8192]u8 = undefined;
    while (true) {
        var n: u32 = 0;
        if (ReadFile(from, &buf, buf.len, &n, null) == 0) return 0;
        if (n == 0) return 1;
        var offset: u32 = 0;
        while (offset < n) {
            var written: u32 = 0;
            if (WriteFile(to, buf[offset..].ptr, n - offset, &written, null) == 0 or written == 0) return 0;
            offset += written;
        }
    }
}

test "B10 POSIX file operations fail closed for absent paths" {
    if (@import("builtin").os.tag == .windows) return @import("platform.zig").skip("T9: operaciones de archivo POSIX; en Windows las cubren las pruebas Win32");
    try std.testing.expectEqual(invalid, CreateFileA("/devagents-b10-absent/file", 0x80000000, 0, null, 3, 0, null));
    try std.testing.expectEqual(@as(u32, 0xffffffff), GetFileAttributesA("/devagents-b10-absent/file"));
}

pub fn CreateFileNullableA(path: [*:0]const u8, access: u32, share: u32, security: ?*anyopaque, disposition: u32, attrs: u32, template: ?H) ?H {
    const h = CreateFileA(path, access, share, security, disposition, attrs, template);
    return if (h == invalid) null else h;
}

pub fn GetLastError() u32 {
    const e = c._errno().*;
    if (e == @intFromEnum(std.posix.E.EXIST)) return 80;
    if (e == @intFromEnum(std.posix.E.AGAIN)) return 33; // ERROR_LOCK_VIOLATION
    if (e == @intFromEnum(std.posix.E.NOENT)) return 2;
    if (e == @intFromEnum(std.posix.E.ACCES) or e == @intFromEnum(std.posix.E.PERM)) return 5;
    return @intCast(e);
}

test "B10 POSIX files: private create, write, size, seek, read, canonical and removal" {
    const a = std.testing.allocator;
    var t: std.Io.Threaded = .init(a, .{});
    defer t.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(t.io(), ".", a);
    defer a.free(root);
    const path = try std.fmt.allocPrintSentinel(a, "{s}/fixture", .{root}, 0);
    defer a.free(path);
    const h = CreateFileA(path, 0xc0000000, 0, null, 1, 0, null);
    try std.testing.expect(h != invalid);
    var closed = false;
    defer if (!closed) {
        _ = CloseHandle(h);
    };
    var count: u32 = 0;
    try std.testing.expectEqual(@as(c_int, 1), WriteFile(h, "hello", 5, &count, null));
    try std.testing.expectEqual(@as(u32, 5), count);
    var size: i64 = 0;
    try std.testing.expectEqual(@as(c_int, 1), GetFileSizeEx(h, &size));
    try std.testing.expectEqual(@as(i64, 5), size);
    try std.testing.expectEqual(@as(c_int, 1), SetFilePointerEx(h, 0, null, 0));
    var bytes: [5]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 1), ReadFile(h, &bytes, 5, &count, null));
    try std.testing.expectEqualStrings("hello", &bytes);
    const meta = try @import("posix_stat.zig").get(fd(h), null);
    try std.testing.expectEqual(@as(u32, 0o600), meta.mode & 0o777);
    try std.testing.expectEqual(@as(c_int, 1), CloseHandle(h));
    closed = true;
    const resolved = try canonical(a, path);
    defer a.free(resolved);
    try std.testing.expectEqualStrings(path, resolved);
    try std.testing.expectEqual(@as(c_int, 1), DeleteFileA(path));
    try std.testing.expectEqual(@as(u32, 0xffffffff), GetFileAttributesA(path));
    try std.testing.expect(CreateFileA(path, 0x80000000, 0, null, 3, 0, null) == invalid);
    try std.testing.expectEqual(@as(c_int, 0), ReadFile(invalid, &bytes, 5, &count, null));
}
