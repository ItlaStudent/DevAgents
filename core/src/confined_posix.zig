//! T9 (, motor): POSIX side of confined_fs. Same contract as the
//! Windows Root: every component is opened relative to a retained parent fd
//! with O_NOFOLLOW (a symlink anywhere in the chain is SandboxDenied), the
//! ancestors stay open while the caller works, hard-linked files are refused
//! and the identity (device, inode) of the selected object is compared again
//! before each mutation. POSIX does not lock names: a retained directory can
//! be renamed, so identity changes are detected (RootChanged), not prevented.
const std = @import("std");
const builtin = @import("builtin");
const c = std.c;
const stat = @import("providers").posix_stat;

pub const Identity = extern struct { volume: u64, file: [16]u8 };

fn errno() c_int {
    return c._errno().*;
}

fn isErr(code: std.posix.E) bool {
    return errno() == @intFromEnum(code);
}

fn openError() anyerror {
    if (isErr(.NOENT)) return error.FileNotFound;
    if (isErr(.EXIST)) return error.PathAlreadyExists;
    if (isErr(.ACCES) or isErr(.PERM)) return error.AccessDenied;
    if (isErr(.NAMETOOLONG)) return error.NameTooLong;
    // ELOOP (a symlink with O_NOFOLLOW), ENOTDIR, EISDIR: never follow.
    if (isErr(.LOOP) or isErr(.NOTDIR) or isErr(.ISDIR) or isErr(.MLINK)) return error.SandboxDenied;
    return error.OpenFailed;
}

pub fn identity(fd: c.fd_t) !Identity {
    const meta = stat.get(fd, null) catch return error.OpenFailed;
    var id: Identity = .{ .volume = meta.dev, .file = @splat(0) };
    std.mem.writeInt(u64, id.file[0..8], meta.ino, .little);
    return id;
}

fn sameIdentity(x: Identity, y: Identity) bool {
    return x.volume == y.volume and std.mem.eql(u8, &x.file, &y.file);
}

fn kind(fd: c.fd_t) !u32 {
    const meta = stat.get(fd, null) catch return error.OpenFailed;
    const k = meta.mode & c.S.IFMT;
    if (k == c.S.IFLNK) return error.SandboxDenied;
    return k;
}

fn rejectHardLinks(fd: c.fd_t) !void {
    const meta = stat.get(fd, null) catch return error.OpenFailed;
    if (meta.mode & c.S.IFMT != c.S.IFDIR and meta.nlink != 1) return error.HardLinkDenied;
}

const dir_flags: c.O = .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .NOFOLLOW = true, .CLOEXEC = true };

fn openChild(a: std.mem.Allocator, parent: c.fd_t, name: []const u8, flags: c.O, mode: c.mode_t) !c.fd_t {
    if (name.len > 255) return error.NameTooLong;
    const z = try a.dupeZ(u8, name);
    defer a.free(z);
    const fd = c.openat(parent, z, flags, mode);
    if (fd < 0) return openError();
    return fd;
}

/// Same lexical rules as the Windows side (no empty, ".", "..", NUL or
/// control characters); both separators split, so a relative path written on
/// Windows resolves to the same components.
fn validateRelative(relative: []const u8) !void {
    if (relative.len == 0 or relative[0] == '/' or relative[0] == '\\') return error.SandboxDenied;
    var parts = std.mem.splitAny(u8, relative, "/\\");
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.SandboxDenied;
        for (part) |ch| if (ch < 32) return error.SandboxDenied;
    }
}

fn validateAbsolute(path: []const u8) !void {
    if (!std.fs.path.isAbsolutePosix(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.SandboxDenied;
    var parts = std.mem.tokenizeScalar(u8, path, '/');
    while (parts.next()) |part| {
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.SandboxDenied;
    }
}

/// T9 fase B: el motor arma muchas rutas con el separador de Windows (las
/// mismas que en Windows); aqui, como en providers/src/posix_files.zig, la
/// barra invertida se trata como separador. Un nombre POSIX con `\` queda asi
/// fuera del confinamiento: se rechaza o se parte, nunca se escapa de la raiz.
fn slashed(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const out = try a.dupe(u8, path);
    std.mem.replaceScalar(u8, out, '\\', '/');
    return out;
}

fn inside(root: []const u8, path: []const u8) bool {
    const base = std.mem.trimEnd(u8, root, "/");
    return path.len > base.len and std.mem.eql(u8, path[0..base.len], base) and path[base.len] == '/';
}

pub const Root = struct {
    allocator: std.mem.Allocator,
    canonical: []u8,
    handles: std.ArrayList(c.fd_t),
    object: Identity,
    /// Kept for the Windows-shaped diagnostics API: here it receives errno.
    windows_error: ?*u32 = null,
    mutation_locked: bool = false,

    pub fn init(a: std.mem.Allocator, path: []const u8) !Root {
        return initAccess(a, path, null, false);
    }

    pub fn initDiagnostic(a: std.mem.Allocator, path: []const u8, windows_error: ?*u32) !Root {
        return initAccess(a, path, windows_error, false);
    }

    pub fn initSecurity(a: std.mem.Allocator, path: []const u8) !Root {
        return initAccess(a, path, null, false);
    }

    pub fn initMutation(a: std.mem.Allocator, path: []const u8) !Root {
        return initAccess(a, path, null, true);
    }

    fn initAccess(a: std.mem.Allocator, raw_path: []const u8, windows_error: ?*u32, mutation: bool) !Root {
        if (windows_error) |dest| dest.* = 0;
        const path = try slashed(a, raw_path);
        defer a.free(path);
        try validateAbsolute(path);
        const canonical = try std.fs.path.resolvePosix(a, &.{path});
        errdefer a.free(canonical);
        var handles = std.ArrayList(c.fd_t).empty;
        errdefer {
            for (handles.items) |h| _ = c.close(h);
            handles.deinit(a);
        }
        const top = c.open("/", dir_flags);
        if (top < 0) {
            if (windows_error) |dest| dest.* = @intCast(errno());
            return openError();
        }
        handles.append(a, top) catch |e| {
            _ = c.close(top);
            return e;
        };
        var parts = std.mem.tokenizeScalar(u8, canonical, '/');
        while (parts.next()) |part| {
            const fd = openChild(a, handles.items[handles.items.len - 1], part, dir_flags, 0) catch |e| {
                if (windows_error) |dest| dest.* = @intCast(errno());
                return e;
            };
            handles.append(a, fd) catch |e| {
                _ = c.close(fd);
                return e;
            };
        }
        if (try kind(handles.items[handles.items.len - 1]) != c.S.IFDIR) return error.SandboxDenied;
        return .{
            .allocator = a,
            .canonical = canonical,
            .handles = handles,
            .object = try identity(handles.items[handles.items.len - 1]),
            .windows_error = windows_error,
            .mutation_locked = mutation,
        };
    }

    pub fn validateIdentity(self: *const Root, other: *const Root) !void {
        for (self.handles.items) |h| _ = try kind(h);
        const now = try identity(self.dir().handle);
        const selected = try identity(other.dir().handle);
        if (!sameIdentity(now, self.object) or !sameIdentity(selected, self.object)) return error.RootChanged;
        // POSIX does not pin names: reopen the path and require the same object.
        var fresh = Root.init(self.allocator, self.canonical) catch return error.RootChanged;
        defer fresh.deinit();
        if (!sameIdentity(fresh.object, self.object)) return error.RootChanged;
    }

    pub fn deinit(self: *Root) void {
        var i = self.handles.items.len;
        while (i > 0) {
            i -= 1;
            _ = c.close(self.handles.items[i]);
        }
        self.handles.deinit(self.allocator);
        self.allocator.free(self.canonical);
    }

    pub fn dir(self: *const Root) std.Io.Dir {
        return .{ .handle = self.handles.items[self.handles.items.len - 1] };
    }

    pub fn open(self: *const Root, relative: []const u8) !std.Io.File {
        return self.openAccess(relative, false);
    }

    pub fn openMetadata(self: *const Root, relative: []const u8) !std.Io.File {
        return self.openAccess(relative, true);
    }

    pub fn relativePath(self: *const Root, raw_path: []const u8) ![]u8 {
        const path = try slashed(self.allocator, raw_path);
        defer self.allocator.free(path);
        const relative = if (std.fs.path.isAbsolutePosix(path)) blk: {
            if (!inside(self.canonical, path)) return error.SandboxDenied;
            break :blk path[std.mem.trimEnd(u8, self.canonical, "/").len + 1 ..];
        } else path;
        try validateRelative(relative);
        const out = try self.allocator.dupe(u8, relative);
        std.mem.replaceScalar(u8, out, '\\', '/');
        return out;
    }

    pub fn openMutation(self: *const Root, relative: []const u8, mode: MutationMode) !Mutation {
        if (!self.mutation_locked) return error.MutationRequiresLock;
        try validateRelative(relative);
        var result: Mutation = .{ .root = self };
        errdefer result.deinit();
        var parts = std.mem.splitAny(u8, relative, "/\\");
        var parent = self.dir().handle;
        const exclusive = mode == .exclusive or mode == .exclusive_temporary;
        const create = mode == .open_or_create or exclusive or mode == .directory;
        while (parts.next()) |part| {
            const last = parts.peek() == null;
            const directory = !last or mode == .directory or mode == .delete_directory;
            const fd = if (directory) blk: {
                if (create) {
                    const z = try self.allocator.dupeZ(u8, part);
                    defer self.allocator.free(z);
                    if (c.mkdirat(parent, z, 0o700) != 0 and !isErr(.EXIST)) return openError();
                }
                break :blk try openChild(self.allocator, parent, part, dir_flags, 0);
            } else if (mode == .delete_file)
                try openChild(self.allocator, parent, part, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0)
            else
                try openChild(self.allocator, parent, part, .{
                    .ACCMODE = if (mode == .existing) .RDWR else .WRONLY,
                    .CREAT = create,
                    .EXCL = exclusive,
                    .NOFOLLOW = true,
                    .CLOEXEC = true,
                    .NONBLOCK = true,
                }, 0o600);
            errdefer _ = c.close(fd);
            const k = try kind(fd);
            if (directory != (k == c.S.IFDIR)) return error.SandboxDenied;
            if (!directory and k != c.S.IFREG) return error.SandboxDenied;
            // T9 fase B: borrar un enlace duro solo quita ese nombre (el
            // contenido del otro no cambia); leerlo o escribirlo sigue negado.
            if (!directory and mode != .delete_file) try rejectHardLinks(fd);
            try result.handles.append(self.allocator, fd);
            if (last) {
                result.name = try self.allocator.dupeZ(u8, part);
                result.parent = parent;
            }
            parent = fd;
        }
        result.object = try identity(result.handle());
        try result.validateObject(mode == .delete_file);
        return result;
    }

    pub fn writeFile(self: *const Root, relative: []const u8, data: []const u8) !void {
        var file = try self.openMutation(relative, .open_or_create);
        defer file.deinit();
        try file.writeAll(data);
    }

    pub fn createDirPath(self: *const Root, relative: []const u8) !void {
        var directory = try self.openMutation(relative, .directory);
        defer directory.deinit();
    }

    pub fn removeFile(self: *const Root, relative: []const u8) !void {
        var file = try self.openMutation(relative, .delete_file);
        defer file.deinit();
        try file.remove();
    }

    pub fn copyFile(self: *const Root, source: *const Root, from: []const u8, to: []const u8) !void {
        const input = try source.open(from);
        defer _ = c.close(input.handle);
        if (try kind(input.handle) != c.S.IFREG) return error.SandboxDenied;
        var output = try self.openMutation(to, .open_or_create);
        defer output.deinit();
        try output.validate();
        if (c.ftruncate(output.handle(), 0) != 0) return error.WriteFailed;
        var buffer: [65536]u8 = undefined;
        while (true) {
            const n = c.read(input.handle, &buffer, buffer.len);
            if (n < 0) return error.ReadFailed;
            if (n == 0) break;
            try writeAllFd(output.handle(), buffer[0..@intCast(n)]);
        }
    }

    pub fn readFileAlloc(self: *const Root, a: std.mem.Allocator, relative: []const u8, max: usize) ![]u8 {
        const file = try self.open(relative);
        defer _ = c.close(file.handle);
        return readHandleAlloc(file.handle, a, max);
    }

    pub fn removeTree(self: *const Root, io: std.Io, relative: []const u8) !void {
        var tree = try self.openMutation(relative, .delete_directory);
        defer tree.deinit();
        try tree.validate();
        try removeTreeContents(self.allocator, io, tree.handle());
        if (c.unlinkat(tree.parent, tree.name.?, c.AT.REMOVEDIR) != 0) return error.DeleteFailed;
    }

    fn openAccess(self: *const Root, relative: []const u8, metadata: bool) !std.Io.File {
        if (self.windows_error) |dest| dest.* = 0;
        try validateRelative(relative);
        var parts = std.mem.splitAny(u8, relative, "/\\");
        var parents = std.ArrayList(c.fd_t).empty;
        defer {
            for (parents.items) |h| _ = c.close(h);
            parents.deinit(self.allocator);
        }
        var parent = self.dir().handle;
        while (parts.next()) |part| {
            const last = parts.peek() == null;
            const flags: c.O = if (!last) dir_flags else if (metadata and builtin.os.tag == .linux)
                .{ .ACCMODE = .RDONLY, .PATH = true, .NOFOLLOW = true, .CLOEXEC = true }
            else
                .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true };
            const fd = openChild(self.allocator, parent, part, flags, 0) catch |e| {
                if (self.windows_error) |dest| dest.* = @intCast(errno());
                return e;
            };
            errdefer _ = c.close(fd);
            const k = try kind(fd);
            if (last) {
                if (k != c.S.IFREG and k != c.S.IFDIR) return error.SandboxDenied;
                if (k != c.S.IFDIR) try rejectHardLinks(fd);
                for (self.handles.items) |h| _ = try kind(h);
                return .{ .handle = fd, .flags = .{ .nonblocking = false } };
            }
            if (k != c.S.IFDIR) return error.SandboxDenied;
            try parents.append(self.allocator, fd);
            parent = fd;
        }
        return error.SandboxDenied;
    }
};

pub const MutationMode = @import("confined_fs.zig").MutationMode;

pub const Mutation = struct {
    root: *const Root,
    handles: std.ArrayList(c.fd_t) = .empty,
    object: Identity = undefined,
    /// Leaf name and its (retained) parent fd, for unlinkat.
    name: ?[:0]u8 = null,
    parent: c.fd_t = -1,

    pub fn handle(self: *const Mutation) c.fd_t {
        return self.handles.items[self.handles.items.len - 1];
    }

    pub fn deinit(self: *Mutation) void {
        var i = self.handles.items.len;
        while (i > 0) {
            i -= 1;
            _ = c.close(self.handles.items[i]);
        }
        self.handles.deinit(self.root.allocator);
        if (self.name) |n| self.root.allocator.free(n);
    }

    fn validate(self: *const Mutation) !void {
        return self.validateObject(false);
    }

    /// T9 fase B: `remove` acepta un enlace duro (borrar quita solo ese nombre).
    fn validateObject(self: *const Mutation, hard_link_ok: bool) !void {
        for (self.root.handles.items) |h| _ = try kind(h);
        for (self.handles.items) |h| _ = try kind(h);
        if (!hard_link_ok) try rejectHardLinks(self.handle());
        const now = try identity(self.handle());
        if (!sameIdentity(now, self.object)) return error.RootChanged;
    }

    pub fn readAlloc(self: *const Mutation, a: std.mem.Allocator, max: usize) ![]u8 {
        try self.validate();
        return readHandleAlloc(self.handle(), a, max);
    }

    pub fn writeAll(self: *const Mutation, data: []const u8) !void {
        try self.validate();
        if (c.ftruncate(self.handle(), 0) != 0) return error.WriteFailed;
        if (c.lseek(self.handle(), 0, c.SEEK.SET) < 0) return error.WriteFailed;
        try writeAllFd(self.handle(), data);
    }

    pub fn remove(self: *const Mutation) !void {
        try self.validateObject(true);
        const name = self.name orelse return error.DeleteFailed;
        // The name is resolved once more relative to the retained parent; the
        // object behind it must still be the one validated above.
        const z: [*:0]const u8 = name.ptr;
        const again = c.openat(self.parent, z, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true });
        if (again < 0) return error.DeleteFailed;
        defer _ = c.close(again);
        if (!sameIdentity(try identity(again), self.object)) return error.RootChanged;
        const is_dir = (try kind(again)) == c.S.IFDIR;
        if (c.unlinkat(self.parent, z, if (is_dir) c.AT.REMOVEDIR else 0) != 0) return error.DeleteFailed;
    }
};

fn writeAllFd(fd: c.fd_t, data: []const u8) !void {
    var offset: usize = 0;
    while (offset < data.len) {
        const n = c.write(fd, data.ptr + offset, data.len - offset);
        if (n <= 0) {
            if (n < 0 and isErr(.INTR)) continue;
            return error.WriteFailed;
        }
        offset += @intCast(n);
    }
}

fn readHandleAlloc(fd: c.fd_t, a: std.mem.Allocator, max: usize) ![]u8 {
    const meta = stat.get(fd, null) catch return error.ReadFailed;
    if (meta.size < 0) return error.ReadFailed;
    if (meta.size > max) return error.FileTooLarge;
    const data = try a.alloc(u8, @intCast(meta.size));
    errdefer a.free(data);
    if (c.lseek(fd, 0, c.SEEK.SET) < 0) return error.ReadFailed;
    var offset: usize = 0;
    while (offset < data.len) {
        const n = c.read(fd, data.ptr + offset, data.len - offset);
        if (n < 0 and isErr(.INTR)) continue;
        if (n <= 0) return error.ReadFailed;
        offset += @intCast(n);
    }
    return data;
}

fn removeTreeContents(a: std.mem.Allocator, io: std.Io, fd: c.fd_t) anyerror!void {
    var iterator = (std.Io.Dir{ .handle = fd }).iterate();
    while (try iterator.next(io)) |entry| {
        try validateRelative(entry.name);
        const child = try openChild(a, fd, entry.name, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true, .NONBLOCK = true }, 0);
        defer _ = c.close(child);
        const k = try kind(child);
        if (k == c.S.IFDIR) {
            try removeTreeContents(a, io, child);
        } else {
            try rejectHardLinks(child);
        }
        const z = try a.dupeZ(u8, entry.name);
        defer a.free(z);
        if (c.unlinkat(fd, z, if (k == c.S.IFDIR) c.AT.REMOVEDIR else 0) != 0) return error.DeleteFailed;
    }
}

/// Materialize a selected root from its nearest existing, retained ancestor.
pub fn createRoot(a: std.mem.Allocator, raw_path: []const u8) !Root {
    const path = try slashed(a, raw_path);
    defer a.free(path);
    try validateAbsolute(path);
    const normalized = try std.fs.path.resolvePosix(a, &.{path});
    defer a.free(normalized);
    var ancestor: []const u8 = normalized;
    while (true) {
        var root = Root.initMutation(a, ancestor) catch |err| switch (err) {
            error.FileNotFound => {
                ancestor = std.fs.path.dirnamePosix(ancestor) orelse return err;
                continue;
            },
            else => return err,
        };
        if (ancestor.len == normalized.len) return root;
        errdefer root.deinit();
        const relative = try root.relativePath(normalized);
        defer a.free(relative);
        var created = try root.openMutation(relative, .directory);
        defer created.deinit();
        const object = try identity(created.handle());
        const canonical = try a.dupe(u8, normalized);
        errdefer a.free(canonical);
        try root.handles.appendSlice(a, created.handles.items);
        created.handles.clearRetainingCapacity();
        a.free(root.canonical);
        root.canonical = canonical;
        root.object = object;
        return root;
    }
}

pub fn strictRoot(a: std.mem.Allocator, path: []const u8) ![]u8 {
    var root = try Root.init(a, path);
    defer root.deinit();
    return a.dupe(u8, root.canonical);
}

pub fn strictNewPath(a: std.mem.Allocator, raw_path: []const u8) ![]u8 {
    const path = try slashed(a, raw_path);
    defer a.free(path);
    try validateAbsolute(path);
    const lexical = try std.fs.path.resolvePosix(a, &.{path});
    errdefer a.free(lexical);
    var ancestor: []const u8 = lexical;
    while (true) {
        var root = Root.init(a, ancestor) catch |e| switch (e) {
            error.FileNotFound => {
                ancestor = std.fs.path.dirnamePosix(ancestor) orelse return error.FileNotFound;
                continue;
            },
            else => return e,
        };
        root.deinit();
        return lexical;
    }
}

test "T9 POSIX confined root rejects traversal, symlinks, fifos and hard links" {
    if (builtin.os.tag == .windows) return @import("platform.zig").skip("T9: confinamiento POSIX; Windows lo cubren las pruebas de confined_fs");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root");
    try tmp.dir.createDirPath(io, "outside");
    const path = try tmp.dir.realPathFileAlloc(io, "root", a);
    defer a.free(path);
    const outside = try tmp.dir.realPathFileAlloc(io, "outside", a);
    defer a.free(outside);
    try std.testing.expectError(error.SandboxDenied, Root.init(a, "relative"));
    try std.testing.expectError(error.SandboxDenied, strictNewPath(a, "relative"));

    var root = try Root.initMutation(a, path);
    defer root.deinit();
    try root.writeFile("sub/file.txt", "safe");
    const back = try root.readFileAlloc(a, "sub/file.txt", 64);
    defer a.free(back);
    try std.testing.expectEqualStrings("safe", back);
    try std.testing.expectError(error.FileTooLarge, root.readFileAlloc(a, "sub/file.txt", 2));
    try std.testing.expectError(error.SandboxDenied, root.open("../escape"));
    try std.testing.expectError(error.SandboxDenied, root.open("a//b"));
    try std.testing.expectError(error.FileNotFound, root.open("absent"));
    const abs_file = try std.fmt.allocPrint(a, "{s}/sub/file.txt", .{path});
    defer a.free(abs_file);
    const rel = try root.relativePath(abs_file);
    defer a.free(rel);
    try std.testing.expectEqualStrings("sub/file.txt", rel);
    try std.testing.expectError(error.SandboxDenied, root.relativePath(outside));

    // A symlink anywhere in the chain is denied, for reads and for writes.
    const link = try std.fs.path.join(a, &.{ path, "link" });
    defer a.free(link);
    try std.Io.Dir.cwd().symLink(io, outside, link, .{ .is_directory = true });
    try std.testing.expectError(error.SandboxDenied, root.open("link/x"));
    try std.testing.expectError(error.SandboxDenied, root.writeFile("link/stolen", "x"));
    try std.testing.expectError(error.SandboxDenied, Root.init(a, link));
    const linked_child = try std.fs.path.join(a, &.{ link, "new-child" });
    defer a.free(linked_child);
    try std.testing.expectError(error.SandboxDenied, strictNewPath(a, linked_child));
    var outside_entries = try tmp.dir.openDir(io, "outside", .{ .iterate = true });
    defer outside_entries.close(io);
    var it = outside_entries.iterate();
    try std.testing.expect((try it.next(io)) == null);

    // Hard links are refused before reading or writing.
    const original = try std.fs.path.joinZ(a, &.{ path, "sub", "file.txt" });
    defer a.free(original);
    const alias = try std.fs.path.joinZ(a, &.{ path, "alias.txt" });
    defer a.free(alias);
    try std.testing.expectEqual(@as(c_int, 0), c.link(original, alias));
    try std.testing.expectError(error.HardLinkDenied, root.open("alias.txt"));
    try std.testing.expectError(error.HardLinkDenied, root.writeFile("alias.txt", "x"));
    try root.removeFile("alias.txt");

    // Mutations need the mutation root; removal works through retained fds.
    var reader = try Root.init(a, path);
    defer reader.deinit();
    try std.testing.expectError(error.MutationRequiresLock, reader.writeFile("x", "y"));
    try root.validateIdentity(&reader);
    try root.createDirPath("tree/deep");
    try root.writeFile("tree/deep/leaf", "1");
    try root.removeTree(io, "tree");
    try std.testing.expectError(error.FileNotFound, root.open("tree"));

    const made = try std.fs.path.join(a, &.{ path, "made", "here" });
    defer a.free(made);
    var created = try createRoot(a, made);
    defer created.deinit();
    try std.testing.expect(std.mem.endsWith(u8, created.canonical, "/made/here"));
}
