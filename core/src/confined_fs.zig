const std = @import("std");
const windows = std.os.windows;
const is_windows = @import("builtin").os.tag == .windows;
/// T9: fuera de Windows el mismo contrato vive en confined_posix.zig (openat
/// componente a componente con O_NOFOLLOW, descriptores retenidos, identidad).
const posix = @import("confined_posix.zig");
pub const Root = if (is_windows) WinRoot else posix.Root;
pub const Mutation = if (is_windows) WinMutation else posix.Mutation;

// The name is never trusted as proof about the object read. Open each existing
// component without following reparse points, keep ancestor handles without
// FILE_SHARE_DELETE, and check the final name and attributes on that handle.
extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
extern "kernel32" fn GetFileInformationByHandleEx(windows.HANDLE, c_int, *anyopaque, u32) callconv(.winapi) c_int;
extern "kernel32" fn GetFinalPathNameByHandleW(windows.HANDLE, [*]u16, u32, u32) callconv(.winapi) u32;
extern "kernel32" fn CloseHandle(windows.HANDLE) callconv(.winapi) c_int;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

const AttributeTag = extern struct { attributes: u32, tag: u32 };
const StandardInfo = extern struct { allocation_size: i64, end_of_file: i64, number_of_links: u32, delete_pending: u8, directory: u8 };
const Identity = extern struct { volume: u64, file: [16]u8 };
const REPARSE: u32 = 0x400;
const DIRECTORY: u32 = 0x10;
const OPEN_REPARSE_POINT: u32 = 0x00200000;
const BACKUP_SEMANTICS: u32 = 0x02000000;
const READ_ATTRIBUTES: u32 = 0x80;
const TRAVERSE: u32 = 0x20;
const DELETE_ACCESS: u32 = 0x10000;
const LIST_DIRECTORY: u32 = 1;

fn openNoFollowAccess(a: std.mem.Allocator, path: []const u8, access: u32, windows_error: ?*u32) !windows.HANDLE {
    return openNoFollowSharing(a, path, access, 3, windows_error);
}

fn openNoFollowSharing(a: std.mem.Allocator, path: []const u8, access: u32, share: u32, windows_error: ?*u32) !windows.HANDLE {
    const extended = if (std.mem.startsWith(u8, path, "\\\\"))
        try std.fmt.allocPrint(a, "\\\\?\\UNC\\{s}", .{path[2..]})
    else
        try std.fmt.allocPrint(a, "\\\\?\\{s}", .{path});
    defer a.free(extended);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, extended);
    defer a.free(wide);
    // READ|WRITE sharing permits normal editing; omitting DELETE prevents
    // replacement/rename of every retained component (CreateFileW contract).
    const handle = CreateFileW(wide.ptr, access, share, null, 3, OPEN_REPARSE_POINT | BACKUP_SEMANTICS, null);
    if (handle == windows.INVALID_HANDLE_VALUE) {
        const code = GetLastError();
        if (windows_error) |dest| dest.* = code;
        return switch (code) {
            2, 3 => error.FileNotFound,
            5 => error.AccessDenied,
            32 => error.SharingViolation,
            33 => error.LockViolation,
            206 => error.NameTooLong,
            else => error.OpenFailed,
        };
    }
    return handle;
}

fn openNoFollow(a: std.mem.Allocator, path: []const u8) !windows.HANDLE {
    return openNoFollowAccess(a, path, 0x80000000, null);
}

fn attributes(handle: windows.HANDLE) !u32 {
    var info: AttributeTag = undefined;
    if (GetFileInformationByHandleEx(handle, 9, &info, @sizeOf(AttributeTag)) == 0) return error.OpenFailed;
    if (info.attributes & REPARSE != 0) return error.SandboxDenied;
    return info.attributes;
}

pub fn identity(handle: std.posix.fd_t) !Identity {
    if (!is_windows) {
        const id = try posix.identity(handle);
        return .{ .volume = id.volume, .file = id.file };
    }
    var info: Identity = undefined;
    if (GetFileInformationByHandleEx(handle, 18, &info, @sizeOf(Identity)) == 0) return error.OpenFailed;
    return info;
}

fn rejectHardLinks(handle: windows.HANDLE) error{ OpenFailed, HardLinkDenied }!void {
    // Reject aliases already present before reading/mutating. This is not an
    // atomic ban on new hard links: FileLinkInformation can add one through a
    // metadata handle during a write (documented in docs/SEC-FS-CONFINAMIENTO.md).
    var info: StandardInfo = undefined;
    if (GetFileInformationByHandleEx(handle, 1, &info, @sizeOf(StandardInfo)) == 0) return error.OpenFailed;
    if (info.directory == 0 and info.number_of_links != 1) return error.HardLinkDenied;
}

fn finalName(a: std.mem.Allocator, handle: windows.HANDLE) ![]u8 {
    var wide: [32768]u16 = undefined;
    const len = GetFinalPathNameByHandleW(handle, &wide, wide.len, 0);
    if (len == 0 or len >= wide.len) return error.OpenFailed;
    const name = try std.unicode.utf16LeToUtf8Alloc(a, wide[0..len]);
    defer a.free(name);
    if (std.mem.startsWith(u8, name, "\\\\?\\UNC\\")) return std.fmt.allocPrint(a, "\\\\{s}", .{name[8..]});
    if (!std.mem.startsWith(u8, name, "\\\\?\\")) return error.SandboxDenied;
    return a.dupe(u8, name[4..]);
}

fn samePath(x: []const u8, y: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, x, "\\"), std.mem.trimEnd(u8, y, "\\"));
}

fn inside(root: []const u8, path: []const u8) bool {
    const base = std.mem.trimEnd(u8, root, "\\");
    return path.len > base.len and std.ascii.eqlIgnoreCase(path[0..base.len], base) and path[base.len] == '\\';
}

fn validateOpened(a: std.mem.Allocator, handle: windows.HANDLE, root: []const u8, expected: []const u8) !u32 {
    const attrs = try attributes(handle);
    const canonical = try finalName(a, handle);
    defer a.free(canonical);
    if (!inside(root, canonical) or !samePath(expected, canonical)) return error.SandboxDenied;
    return attrs;
}

fn validateRootOpened(a: std.mem.Allocator, handle: windows.HANDLE, lexical: []const u8) !void {
    if (try attributes(handle) & DIRECTORY == 0) return error.SandboxDenied;
    const canonical = try finalName(a, handle);
    defer a.free(canonical);
    if (!samePath(lexical, canonical)) return error.SandboxDenied;
}

/// Owned root and retained ancestor handles. Callers keep it alive throughout
/// enumeration/reading, rather than validating a name and resolving it again.
const WinRoot = struct {
    allocator: std.mem.Allocator,
    canonical: []u8,
    handles: std.ArrayList(windows.HANDLE),
    object: Identity,
    windows_error: ?*u32 = null,
    mutation_locked: bool = false,

    pub fn init(a: std.mem.Allocator, path: []const u8) !Root {
        return initDiagnostic(a, path, null);
    }

    pub fn initDiagnostic(a: std.mem.Allocator, path: []const u8, windows_error: ?*u32) !Root {
        return initAccess(a, path, windows_error, READ_ATTRIBUTES | TRAVERSE, 3);
    }

    /// ACL consumers need READ_CONTROL on retained ancestors as well.
    pub fn initSecurity(a: std.mem.Allocator, path: []const u8) !Root {
        return initAccess(a, path, null, 0x20000 | READ_ATTRIBUTES | TRAVERSE, 3);
    }

    /// No WRITE/DELETE sharing: even installing a reparse tag in place must
    /// fail while a mutation retains this chain. Child creation is unaffected.
    pub fn initMutation(a: std.mem.Allocator, path: []const u8) !Root {
        return initAccess(a, path, null, READ_ATTRIBUTES | TRAVERSE, 1);
    }

    fn initAccess(a: std.mem.Allocator, path: []const u8, windows_error: ?*u32, ancestor_access: u32, share: u32) !Root {
        if (windows_error) |dest| dest.* = 0;
        if (!std.fs.path.isAbsoluteWindows(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.SandboxDenied;
        const lexical = try std.fs.path.resolveWindows(a, &.{path});
        errdefer a.free(lexical);
        var handles = std.ArrayList(windows.HANDLE).empty;
        errdefer {
            for (handles.items) |h| _ = CloseHandle(h);
            handles.deinit(a);
        }
        const prefix_len: usize = if (std.mem.startsWith(u8, lexical, "\\\\")) blk: {
            const server_end = std.mem.indexOfScalarPos(u8, lexical, 2, '\\') orelse return error.SandboxDenied;
            break :blk if (std.mem.indexOfScalarPos(u8, lexical, server_end + 1, '\\')) |share_end| share_end else lexical.len;
        } else 3;
        var end = prefix_len;
        while (true) {
            // Ancestors are retained for identity/attributes, never enumerated.
            // TRAVERSE (FILE_EXECUTE) participates in Windows share checks;
            // READ_ATTRIBUTES alone does NOT pin a directory against rename.
            // No LIST_DIRECTORY permission is needed on these ancestors.
            const handle = try openNoFollowSharing(a, lexical[0..end], if (end == lexical.len and share != 1) 0x80000000 else ancestor_access, share, windows_error);
            errdefer _ = CloseHandle(handle);
            try validateRootOpened(a, handle, lexical[0..end]);
            try handles.append(a, handle);
            if (end == lexical.len) break;
            const start = if (lexical[end] == '\\') end + 1 else end;
            end = std.mem.indexOfScalarPos(u8, lexical, start, '\\') orelse lexical.len;
        }
        return .{ .allocator = a, .canonical = lexical, .handles = handles, .object = try identity(handles.items[handles.items.len - 1]), .windows_error = windows_error, .mutation_locked = share == 1 };
    }

    pub fn validateIdentity(self: *const Root, other: *const Root) !void {
        for (self.handles.items) |h| _ = try attributes(h);
        const now = try identity(self.dir().handle);
        const selected = try identity(other.dir().handle);
        if (now.volume != self.object.volume or !std.mem.eql(u8, &now.file, &self.object.file) or
            selected.volume != self.object.volume or !std.mem.eql(u8, &selected.file, &self.object.file)) return error.RootChanged;
    }

    pub fn deinit(self: *Root) void {
        for (self.handles.items) |handle| _ = CloseHandle(handle);
        self.handles.deinit(self.allocator);
        self.allocator.free(self.canonical);
    }

    pub fn dir(self: *const Root) std.Io.Dir {
        return .{ .handle = self.handles.items[self.handles.items.len - 1] };
    }

    /// The returned file owns the final validated handle. Directory handles are
    /// also supported so recursive snapshots enumerate that same safe object.
    pub fn open(self: *const Root, relative: []const u8) !std.Io.File {
        return self.openAccess(relative, 0x80000000);
    }

    /// Metadata only: the returned handle has no FILE_READ_DATA permission.
    /// Uses the same canonical/reparse/hard-link checks as content reads.
    pub fn openMetadata(self: *const Root, relative: []const u8) !std.Io.File {
        return self.openAccess(relative, 0x80);
    }

    /// Lexical conversion only. The authority is the retained root and the
    /// handles opened below, never this returned name or a prior stat.
    pub fn relativePath(self: *const Root, path: []const u8) ![]u8 {
        const normalized = try self.allocator.dupe(u8, path);
        defer self.allocator.free(normalized);
        std.mem.replaceScalar(u8, normalized, '/', '\\');
        const relative = if (std.fs.path.isAbsoluteWindows(normalized)) blk: {
            if (!inside(self.canonical, normalized)) return error.SandboxDenied;
            break :blk normalized[std.mem.trimEnd(u8, self.canonical, "\\").len + 1 ..];
        } else normalized;
        try validateRelative(relative);
        return self.allocator.dupe(u8, relative);
    }

    pub fn openMutation(self: *const Root, relative: []const u8, mode: MutationMode) !Mutation {
        if (!self.mutation_locked) return error.MutationRequiresLock;
        try validateRelative(relative);
        var result: Mutation = .{ .root = self };
        errdefer result.deinit();
        var parts = std.mem.splitAny(u8, relative, "/\\");
        var parent = self.dir().handle;
        var expected = try self.allocator.dupe(u8, self.canonical);
        defer self.allocator.free(expected);
        while (parts.next()) |part| {
            const last = parts.peek() == null;
            const directory = !last or mode == .directory or mode == .delete_directory;
            const exclusive = mode == .exclusive or mode == .exclusive_temporary;
            const create = mode == .open_or_create or exclusive or mode == .directory;
            const disposition: u32 = if (last and exclusive) 2 else if (create) 3 else 1;
            const access: u32 = if (!last or mode == .directory)
                READ_ATTRIBUTES | TRAVERSE
            else if (mode == .delete_directory)
                DELETE_ACCESS | READ_ATTRIBUTES | LIST_DIRECTORY
            else if (mode == .delete_file)
                DELETE_ACCESS | READ_ATTRIBUTES
            else if (mode == .exclusive_temporary)
                0x40000000 | DELETE_ACCESS | READ_ATTRIBUTES
            else if (mode == .existing) 0xc0000000 | READ_ATTRIBUTES else 0x40000000 | READ_ATTRIBUTES;
            // One component relative to a pinned parent: no pathname prefix
            // can be re-resolved through an attacker-controlled junction.
            if (@import("builtin").is_test) if (mutation_open_hook) |hook| try hook(self, relative, part);
            const h = try openChild(self.allocator, parent, part, access, disposition, directory);
            errdefer _ = CloseHandle(h);
            const next = try std.fmt.allocPrint(self.allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ expected, part });
            self.allocator.free(expected);
            expected = next;
            const attrs = try validateOpened(self.allocator, h, self.canonical, expected);
            if (directory != (attrs & DIRECTORY != 0)) return error.SandboxDenied;
            if (!directory) try rejectHardLinks(h);
            try result.handles.append(self.allocator, h);
            parent = h;
        }
        result.object = try identity(result.handle());
        try result.validate();
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

    /// Bounded memory regardless of file size; neither endpoint is reopened.
    pub fn copyFile(self: *const Root, source: *const Root, from: []const u8, to: []const u8) !void {
        const input = try source.open(from);
        defer _ = CloseHandle(input.handle);
        if (try attributes(input.handle) & DIRECTORY != 0) return error.SandboxDenied;
        var output = try self.openMutation(to, .open_or_create);
        defer output.deinit();
        try output.validate();
        if (SetEndOfFile(output.handle()) == 0) return error.WriteFailed;
        var buffer: [65536]u8 = undefined;
        while (true) {
            var count: u32 = 0;
            if (ReadFile(input.handle, &buffer, buffer.len, &count, null) == 0) return error.ReadFailed;
            if (count == 0) break;
            var offset: usize = 0;
            while (offset < count) {
                var written: u32 = 0;
                if (WriteFile(output.handle(), buffer[offset..].ptr, @intCast(count - offset), &written, null) == 0 or written == 0) return error.WriteFailed;
                offset += written;
            }
        }
        if (SetEndOfFile(output.handle()) == 0) return error.WriteFailed;
    }

    pub fn readFileAlloc(self: *const Root, a: std.mem.Allocator, relative: []const u8, max: usize) ![]u8 {
        const file = try self.open(relative);
        defer _ = CloseHandle(file.handle);
        return readHandleAlloc(file.handle, a, max);
    }

    pub fn removeTree(self: *const Root, io: std.Io, relative: []const u8) !void {
        var tree = try self.openMutation(relative, .delete_directory);
        defer tree.deinit();
        const expected = try std.fmt.allocPrint(self.allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ self.canonical, relative });
        defer self.allocator.free(expected);
        std.mem.replaceScalar(u8, expected, '/', '\\');
        try removeTreeHandle(self, io, tree.handle(), expected);
    }

    fn openAccess(self: *const Root, relative: []const u8, access: u32) !std.Io.File {
        if (self.windows_error) |dest| dest.* = 0;
        if (relative.len == 0 or std.fs.path.isAbsoluteWindows(relative)) return error.SandboxDenied;
        var checked_parts = std.mem.splitAny(u8, relative, "/\\");
        while (checked_parts.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or std.mem.indexOfAny(u8, part, ":\x00") != null) return error.SandboxDenied;
        }
        var parts = std.mem.splitAny(u8, relative, "/\\");
        var current = try self.allocator.dupe(u8, self.canonical);
        defer self.allocator.free(current);
        var parents = std.ArrayList(windows.HANDLE).empty;
        defer {
            for (parents.items) |h| _ = CloseHandle(h);
            parents.deinit(self.allocator);
        }
        while (parts.next()) |part| {
            const next = try std.fmt.allocPrint(self.allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ current, part });
            self.allocator.free(current);
            current = next;
            const handle = try openNoFollowAccess(self.allocator, current, if (parts.peek() == null) access else READ_ATTRIBUTES | TRAVERSE, self.windows_error);
            errdefer _ = CloseHandle(handle);
            const attrs = try validateOpened(self.allocator, handle, self.canonical, current);
            if (parts.peek() == null) {
                if (attrs & DIRECTORY == 0) try rejectHardLinks(handle);
                // A directory may have acquired a reparse tag while a deeper
                // component opened. The same final handle is checked as well.
                for (self.handles.items) |h| _ = try attributes(h);
                for (parents.items) |h| _ = try attributes(h);
                return .{ .handle = handle, .flags = .{ .nonblocking = false } };
            }
            if (attrs & DIRECTORY == 0) return error.SandboxDenied;
            try parents.append(self.allocator, handle);
        }
        return error.SandboxDenied;
    }
};

pub const MutationMode = enum { existing, open_or_create, exclusive, exclusive_temporary, directory, delete_file, delete_directory };

// Only tests can install this seam. It runs after lexical validation and
// immediately before opening a component, so races need no timing guesses.
var mutation_open_hook: if (@import("builtin").is_test) ?*const fn (*const Root, []const u8, []const u8) anyerror!void else void = if (@import("builtin").is_test) null else {};

fn validateRelative(relative: []const u8) !void {
    if (relative.len == 0 or std.fs.path.isAbsoluteWindows(relative)) return error.SandboxDenied;
    var parts = std.mem.splitAny(u8, relative, "/\\");
    while (parts.next()) |part| {
        if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..") or
            std.mem.indexOfAny(u8, part, ":\x00<>\"|?*") != null or
            part[part.len - 1] == '.' or part[part.len - 1] == ' ') return error.SandboxDenied;
        for (part) |c| if (c < 32) return error.SandboxDenied;
        const base = std.mem.trimEnd(u8, part[0 .. std.mem.indexOfScalar(u8, part, '.') orelse part.len], " ");
        for ([_][]const u8{ "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$" }) |reserved| {
            if (std.ascii.eqlIgnoreCase(base, reserved)) return error.SandboxDenied;
        }
        if (base.len >= 4 and (std.ascii.eqlIgnoreCase(base[0..3], "COM") or std.ascii.eqlIgnoreCase(base[0..3], "LPT"))) {
            const n = base[3..];
            if ((n.len == 1 and n[0] >= '1' and n[0] <= '9') or std.mem.eql(u8, n, "¹") or std.mem.eql(u8, n, "²") or std.mem.eql(u8, n, "³")) return error.SandboxDenied;
        }
    }
}

fn openChild(a: std.mem.Allocator, parent: windows.HANDLE, name: []const u8, access: u32, disposition: u32, directory: ?bool) !windows.HANDLE {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, name);
    defer a.free(wide);
    if (wide.len > 255) return error.NameTooLong;
    var unicode = windows.UNICODE_STRING.init(wide);
    const object: windows.OBJECT.ATTRIBUTES = .{ .RootDirectory = parent, .ObjectName = &unicode, .Attributes = .{ .DONT_REPARSE = true } };
    var status_block: windows.IO_STATUS_BLOCK = undefined;
    var handle: windows.HANDLE = undefined;
    // OPEN_IF never truncates: attributes, canonical name and link count are
    // checked on the returned handle BEFORE the first write/set-end-of-file.
    const status = windows.ntdll.NtCreateFile(&handle, @bitCast(access | 0x100000), &object, &status_block, null, @bitCast(@as(u32, 0x80)), .{ .READ = true }, @enumFromInt(disposition), @bitCast(@as(u32, 0x00200000 | 0x20) | @as(u32, if (directory) |is_dir| (if (is_dir) 1 else 0x40) else 0)), null, 0);
    return switch (status) {
        .SUCCESS => handle,
        .OBJECT_NAME_NOT_FOUND, .OBJECT_PATH_NOT_FOUND => error.FileNotFound,
        .OBJECT_NAME_COLLISION => error.PathAlreadyExists,
        .ACCESS_DENIED => error.AccessDenied,
        .SHARING_VIOLATION => error.SharingViolation,
        @as(windows.NTSTATUS, @enumFromInt(0xc000050b)), .IO_REPARSE_TAG_NOT_HANDLED, .STOPPED_ON_SYMLINK => error.SandboxDenied,
        .FILE_IS_A_DIRECTORY, .NOT_A_DIRECTORY => error.SandboxDenied,
        else => error.OpenFailed,
    };
}

extern "kernel32" fn SetFilePointerEx(windows.HANDLE, i64, ?*i64, u32) callconv(.winapi) c_int;
extern "kernel32" fn SetEndOfFile(windows.HANDLE) callconv(.winapi) c_int;
extern "kernel32" fn WriteFile(windows.HANDLE, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn ReadFile(windows.HANDLE, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn GetFileSizeEx(windows.HANDLE, *i64) callconv(.winapi) c_int;
extern "kernel32" fn SetFileInformationByHandle(windows.HANDLE, c_int, *anyopaque, u32) callconv(.winapi) c_int;

/// Owns the final object AND all its parents until the mutation has finished.
/// Root must outlive this value. No operation below reopens a pathname.
const WinMutation = struct {
    root: *const Root,
    handles: std.ArrayList(windows.HANDLE) = .empty,
    object: Identity = undefined,

    pub fn handle(self: *const Mutation) windows.HANDLE {
        return self.handles.items[self.handles.items.len - 1];
    }

    pub fn deinit(self: *Mutation) void {
        var i = self.handles.items.len;
        while (i > 0) {
            i -= 1;
            _ = CloseHandle(self.handles.items[i]);
        }
        self.handles.deinit(self.root.allocator);
    }

    fn validate(self: *const Mutation) !void {
        for (self.root.handles.items) |h| _ = try attributes(h);
        for (self.handles.items) |h| _ = try attributes(h);
        try rejectHardLinks(self.handle());
        const now = try identity(self.handle());
        if (now.volume != self.object.volume or !std.mem.eql(u8, &now.file, &self.object.file)) return error.RootChanged;
    }

    pub fn readAlloc(self: *const Mutation, a: std.mem.Allocator, max: usize) ![]u8 {
        try self.validate();
        return readHandleAlloc(self.handle(), a, max);
    }

    pub fn writeAll(self: *const Mutation, data: []const u8) !void {
        try self.validate();
        if (SetFilePointerEx(self.handle(), 0, null, 0) == 0) return error.WriteFailed;
        if (SetEndOfFile(self.handle()) == 0) return error.WriteFailed;
        var offset: usize = 0;
        while (offset < data.len) {
            var count: u32 = 0;
            if (WriteFile(self.handle(), data.ptr + offset, @intCast(@min(data.len - offset, std.math.maxInt(u32))), &count, null) == 0 or count == 0) return error.WriteFailed;
            offset += count;
        }
        if (SetEndOfFile(self.handle()) == 0) return error.WriteFailed;
    }

    pub fn remove(self: *const Mutation) !void {
        try self.validate();
        var remove_file: u32 = 1;
        if (SetFileInformationByHandle(self.handle(), 4, &remove_file, @sizeOf(u32)) == 0) return error.DeleteFailed;
    }
};

fn readHandleAlloc(handle: windows.HANDLE, a: std.mem.Allocator, max: usize) ![]u8 {
    var size: i64 = 0;
    if (GetFileSizeEx(handle, &size) == 0 or size < 0) return error.ReadFailed;
    if (size > max) return error.FileTooLarge;
    const data = try a.alloc(u8, @intCast(size));
    errdefer a.free(data);
    if (SetFilePointerEx(handle, 0, null, 0) == 0) return error.ReadFailed;
    var offset: usize = 0;
    while (offset < data.len) {
        var count: u32 = 0;
        if (ReadFile(handle, data.ptr + offset, @intCast(@min(data.len - offset, std.math.maxInt(u32))), &count, null) == 0 or count == 0) return error.ReadFailed;
        offset += count;
    }
    return data;
}

fn removeTreeHandle(root: *const Root, io: std.Io, handle: windows.HANDLE, expected: []const u8) anyerror!void {
    const attrs = try validateOpened(root.allocator, handle, root.canonical, expected);
    try rejectHardLinks(handle);
    if (attrs & DIRECTORY != 0) {
        var iterator = (std.Io.Dir{ .handle = handle }).iterate();
        while (try iterator.next(io)) |entry| {
            try validateRelative(entry.name);
            const child = try openChild(root.allocator, handle, entry.name, DELETE_ACCESS | READ_ATTRIBUTES | LIST_DIRECTORY, 1, null);
            defer _ = CloseHandle(child);
            const name = try std.fmt.allocPrint(root.allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ expected, entry.name });
            defer root.allocator.free(name);
            try removeTreeHandle(root, io, child, name);
        }
    }
    var remove_file: u32 = 1;
    if (SetFileInformationByHandle(handle, 4, &remove_file, @sizeOf(u32)) == 0) return error.DeleteFailed;
}

/// Materialize a selected root using the nearest existing, pinned ancestor.
/// Transfer its handles: even a newly created root is never reopened by name.
pub fn createRoot(a: std.mem.Allocator, path: []const u8) !Root {
    if (!is_windows) return posix.createRoot(a, path);
    if (!std.fs.path.isAbsoluteWindows(path)) return error.SandboxDenied;
    const normalized = try std.fs.path.resolveWindows(a, &.{path});
    defer a.free(normalized);
    var ancestor: []const u8 = normalized;
    while (true) {
        var root = Root.initMutation(a, ancestor) catch |err| switch (err) {
            error.FileNotFound => {
                ancestor = std.fs.path.dirnameWindows(ancestor) orelse return err;
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

/// Existing root only; returns an owned canonical path. Reparse roots and
/// aliases introduced anywhere in the selected path are denied explicitly.
pub fn strictRoot(a: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!is_windows) return posix.strictRoot(a, path);
    var root = try Root.init(a, path);
    defer root.deinit();
    return a.dupe(u8, root.canonical);
}

/// A directory that may not exist yet. Its closest existing ancestor must
/// pass the same no-reparse and canonical/lexical identity checks as a root.
/// Callers that create it retain Root.init(ancestor) while doing the mutation.
pub fn strictNewPath(a: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!is_windows) return posix.strictNewPath(a, path);
    if (!std.fs.path.isAbsoluteWindows(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.SandboxDenied;
    const lexical = try std.fs.path.resolveWindows(a, &.{path});
    errdefer a.free(lexical);
    var ancestor: []const u8 = lexical;
    while (true) {
        var root = Root.init(a, ancestor) catch |e| switch (e) {
            error.FileNotFound => {
                ancestor = std.fs.path.dirnameWindows(ancestor) orelse return error.FileNotFound;
                continue;
            },
            else => return e,
        };
        defer root.deinit();
        return lexical;
    }
}

test "E5.20 E-127 ronda2: strictRoot y handles rechazan entradas y destino ajeno" {
    if (!is_windows) return @import("platform.zig").skip("T9: semantica Win32 (reparse, junction, ADS, 8.3, nombres finales); equivalente POSIX en confined_posix.zig");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root");
    const root_path = try tmp.dir.realPathFileAlloc(io, "root", a);
    defer a.free(root_path);
    const owned = try strictRoot(a, root_path);
    defer a.free(owned);
    try std.testing.expect(samePath(root_path, owned));
    var root = try Root.init(a, root_path);
    defer root.deinit();
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    const no_memory = failing.allocator();
    try std.testing.expectError(error.OutOfMemory, Root.init(no_memory, root_path));
    try std.testing.expectError(error.OutOfMemory, strictRoot(no_memory, root_path));
    try std.testing.expectError(error.OutOfMemory, strictNewPath(no_memory, root_path));
    const saved_allocator = root.allocator;
    root.allocator = no_memory;
    const no_memory_open = root.open("file");
    root.allocator = saved_allocator;
    try std.testing.expectError(error.OutOfMemory, no_memory_open);
    for ([_][]const u8{ "", "../outside", "file:stream", "a//b", "C:\\outside", "./file" }) |invalid| {
        try std.testing.expectError(error.SandboxDenied, root.open(invalid));
    }
    try std.testing.expectError(error.FileNotFound, root.open("missing"));
    try std.testing.expectError(error.SandboxDenied, strictRoot(a, "relative"));
    try std.testing.expectError(error.SandboxDenied, strictRoot(a, "C:\\bad\x00path"));
    try std.testing.expectError(error.FileNotFound, strictRoot(a, "Z:\\missing-e520-root"));
    try std.testing.expectError(error.SandboxDenied, strictNewPath(a, "relative"));
    try std.testing.expectError(error.SandboxDenied, strictNewPath(a, "C:\\bad\x00path"));
    try std.testing.expectError(error.FileNotFound, strictNewPath(a, "Z:\\missing-e520-root"));
    const future = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "new" ++ std.fs.path.sep_str ++ "directory", .{root_path});
    defer a.free(future);
    const future_canonical = try strictNewPath(a, future);
    defer a.free(future_canonical);
    try std.testing.expectEqualStrings(future, future_canonical);

    const parent = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(parent);
    const outside = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "outside.txt", .{parent});
    defer a.free(outside);
    var created = try tmp.dir.createFile(io, "outside.txt", .{});
    created.close(io);
    const handle = try openNoFollow(a, outside);
    defer _ = CloseHandle(handle);
    // Guardia directa del MISMO handle: abrir un archivo externo no lo vuelve
    // seguro aunque el nombre esperado fuese proporcionado por el llamador.
    try std.testing.expectError(error.SandboxDenied, validateOpened(a, handle, root.canonical, outside));
    try std.testing.expect(!inside("C:\\root", "C:\\root-other\\x"));
}

test "SEC-FS mutation retains the file and parents through truncation and deletion" {
    if (!is_windows) return @import("platform.zig").skip("T9: semantica Win32 (reparse, junction, ADS, 8.3, nombres finales); equivalente POSIX en confined_posix.zig");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    var root = try Root.initMutation(a, path);
    defer root.deinit();
    try root.writeFile("parent/child.txt", "long original content");
    {
        var file = try root.openMutation("parent/child.txt", .existing);
        defer file.deinit();
        const before = try file.readAlloc(a, 128);
        defer a.free(before);
        try std.testing.expectEqualStrings("long original content", before);
        const Rename = struct {
            extern "kernel32" fn MoveFileExW([*:0]const u16, [*:0]const u16, u32) callconv(.winapi) c_int;
        };
        const from = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "parent", .{path});
        defer a.free(from);
        const to = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "moved", .{path});
        defer a.free(to);
        const from_w = try std.unicode.utf8ToUtf16LeAllocZ(a, from);
        defer a.free(from_w);
        const to_w = try std.unicode.utf8ToUtf16LeAllocZ(a, to);
        defer a.free(to_w);
        try std.testing.expectEqual(@as(c_int, 0), Rename.MoveFileExW(from_w, to_w, 0));
        const code = GetLastError();
        try std.testing.expect(code == 32 or code == 5);
        try file.writeAll("new");
        const after = try file.readAlloc(a, 128);
        defer a.free(after);
        try std.testing.expectEqualStrings("new", after);
    }
    try root.removeFile("parent/child.txt");
    try std.testing.expectError(error.FileNotFound, root.open("parent/child.txt"));
    try root.writeFile("parent/deep/new.txt", "remove tree");
    try root.removeTree(io, "parent");
    try std.testing.expectError(error.FileNotFound, root.open("parent"));
}

test "SEC-FS deterministic junction swap before component open writes zero bytes outside" {
    if (!is_windows) return @import("platform.zig").skip("T9: semantica Win32 (reparse, junction, ADS, 8.3, nombres finales); equivalente POSIX en confined_posix.zig");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "work/switch");
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside/target.txt", .data = "sentinel" });
    const path = try tmp.dir.realPathFileAlloc(io, "work", a);
    defer a.free(path);
    var root = try Root.initMutation(a, path);
    defer root.deinit();
    const Swap = struct {
        fn before(r: *const Root, _: []const u8, component: []const u8) !void {
            if (!std.mem.eql(u8, component, "switch")) return;
            mutation_open_hook = null;
            const link = try std.fmt.allocPrint(r.allocator, "{s}" ++ std.fs.path.sep_str ++ "switch", .{r.canonical});
            defer r.allocator.free(link);
            const outside = try std.fmt.allocPrint(r.allocator, "{s}" ++ std.fs.path.sep_str ++ "outside", .{std.fs.path.dirnameWindows(r.canonical).?});
            defer r.allocator.free(outside);
            const Remove = struct {
                extern "kernel32" fn RemoveDirectoryW([*:0]const u16) callconv(.winapi) c_int;
            };
            const link_w = try std.unicode.utf8ToUtf16LeAllocZ(r.allocator, link);
            defer r.allocator.free(link_w);
            try std.testing.expect(Remove.RemoveDirectoryW(link_w) != 0);
            var mk = try @import("providers").github.runCmdCaptureWin32(r.allocator, &.{ "cmd.exe", "/d", "/c", "mklink", "/J", link, outside }, null);
            defer mk.deinit(r.allocator);
            try std.testing.expectEqual(@as(u32, 0), mk.exit_code);
        }
    };
    mutation_open_hook = Swap.before;
    defer mutation_open_hook = null;
    defer tmp.dir.deleteDir(io, "work/switch") catch |e| std.debug.print("SEC-FS junction cleanup: {s}\n", .{@errorName(e)});
    try std.testing.expectError(error.SandboxDenied, root.writeFile("switch/target.txt", "corrupted"));
    try std.testing.expect(mutation_open_hook == null);
    try std.testing.expectError(error.SandboxDenied, root.writeFile("switch/new.txt", "escaped"));
    try std.testing.expectError(error.SandboxDenied, root.createDirPath("switch/newdir/deep"));
    try std.testing.expectError(error.SandboxDenied, root.removeFile("switch/target.txt"));
    try std.testing.expectError(error.SandboxDenied, root.removeTree(io, "switch"));
    const outside = try tmp.dir.readFileAlloc(io, "outside/target.txt", a, .limited(128));
    defer a.free(outside);
    try std.testing.expectEqualStrings("sentinel", outside);
    try std.testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "outside/new.txt", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.openDir(io, "outside/newdir", .{}));
}

test "SEC-FS ADS devices aliases extended namespace and long Unicode paths" {
    if (!is_windows) return @import("platform.zig").skip("T9: semantica Win32 (reparse, junction, ADS, 8.3, nombres finales); equivalente POSIX en confined_posix.zig");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    var root = try Root.initMutation(a, path);
    defer root.deinit();
    for ([_][]const u8{ "file:stream", "CON", "NUL.txt", "aux", "COM1", "LPT9.txt", "COM¹", "CON .txt", "dir/../outside", "a//b", "file.", "file ", "\\\\?\\C:\\evil" }) |invalid| {
        try std.testing.expectError(error.SandboxDenied, root.writeFile(invalid, "evil"));
    }
    const extended = try std.fmt.allocPrint(a, "\\\\?\\{s}\\x", .{path});
    defer a.free(extended);
    try std.testing.expectError(error.SandboxDenied, root.relativePath(extended));
    const absolute_slash = try std.fmt.allocPrint(a, "{s}/Mixed/Unicode-ñ.txt", .{path});
    defer a.free(absolute_slash);
    std.mem.replaceScalar(u8, absolute_slash, '\\', '/');
    const relative = try root.relativePath(absolute_slash);
    defer a.free(relative);
    try root.writeFile(relative, "slash");
    const lower = try root.readFileAlloc(a, "mixed/Unicode-ñ.txt", 128);
    defer a.free(lower);
    try std.testing.expectEqualStrings("slash", lower);
    const new_root_slash = try std.fmt.allocPrint(a, "{s}/new/selected", .{path});
    defer a.free(new_root_slash);
    std.mem.replaceScalar(u8, new_root_slash, '\\', '/');
    var selected = try createRoot(a, new_root_slash);
    defer selected.deinit();
    try selected.writeFile("works.txt", "retained");
    const long = "directorio-largo-para-superar-max-path/" ** 8 ++ "música-日本語.txt";
    try root.writeFile(long, "Unicode sin truncar");
    const content = try root.readFileAlloc(a, long, 128);
    defer a.free(content);
    try std.testing.expectEqualStrings("Unicode sin truncar", content);
}

// Reparse point de archivo que cualquier usuario puede crear: no exige
// SeCreateSymbolicLinkPrivilege ni modo desarrollador. Se usa una etiqueta sin
// asignar con el bit Microsoft (0x80000000) y sin bits de name-surrogate/latencia.
// En esta maquina (Windows 11 26200) NTFS rechaza con ERROR_IO_REPARSE_DATA_INVALID
// (4392) los REPARSE_GUID_DATA_BUFFER de etiqueta ajena, de ahi el buffer generico.
const SENTINEL_REPARSE_TAG: u32 = 0x80001D0A;
const FSCTL_SET_REPARSE_POINT: u32 = 0x000900A4;
const FSCTL_GET_REPARSE_POINT: u32 = 0x000900A8;
const FSCTL_DELETE_REPARSE_POINT: u32 = 0x000900AC;
const REPARSE_HEADER: usize = 8; // tag u32, longitud u16, reservado u16
const GENERIC_READ_WRITE: u32 = 0xc0000000;

const DeviceControl = struct {
    extern "kernel32" fn DeviceIoControl(windows.HANDLE, u32, ?*const anyopaque, u32, ?*anyopaque, u32, ?*u32, ?*anyopaque) callconv(.winapi) c_int;
};

fn reparseBuffer(payload: []const u8) [REPARSE_HEADER + 4]u8 {
    std.debug.assert(payload.len <= 4);
    var buffer: [REPARSE_HEADER + 4]u8 = [_]u8{0} ** (REPARSE_HEADER + 4);
    std.mem.writeInt(u32, buffer[0..4], SENTINEL_REPARSE_TAG, .little);
    std.mem.writeInt(u16, buffer[4..6], @intCast(payload.len), .little);
    @memcpy(buffer[REPARSE_HEADER..][0..payload.len], payload);
    return buffer;
}

/// Marca un archivo existente con un reparse point sin privilegios.
fn markReparse(a: std.mem.Allocator, path: []const u8) !void {
    const handle = try openNoFollowAccess(a, path, GENERIC_READ_WRITE, null);
    defer _ = CloseHandle(handle);
    const buffer = reparseBuffer("SEC!");
    var returned: u32 = 0;
    if (DeviceControl.DeviceIoControl(handle, FSCTL_SET_REPARSE_POINT, &buffer, buffer.len, null, 0, &returned, null) == 0) {
        std.debug.print("SEC-FS symlink: FSCTL_SET_REPARSE_POINT fallo ({d})\n", .{GetLastError()});
        return error.TestUnexpectedResult;
    }
}

fn clearReparse(a: std.mem.Allocator, path: []const u8) void {
    const handle = openNoFollowAccess(a, path, GENERIC_READ_WRITE, null) catch return;
    defer _ = CloseHandle(handle);
    const buffer = reparseBuffer("");
    var returned: u32 = 0;
    _ = DeviceControl.DeviceIoControl(handle, FSCTL_DELETE_REPARSE_POINT, &buffer, REPARSE_HEADER, null, 0, &returned, null);
}

/// El reparse point sigue presente con la misma etiqueta y datos (no se toco).
fn expectReparseIntact(a: std.mem.Allocator, path: []const u8) !void {
    const handle = try openNoFollowAccess(a, path, 0x80000000, null);
    defer _ = CloseHandle(handle);
    try std.testing.expectError(error.SandboxDenied, attributes(handle));
    var out: [1024]u8 = undefined;
    var returned: u32 = 0;
    try std.testing.expect(DeviceControl.DeviceIoControl(handle, FSCTL_GET_REPARSE_POINT, null, 0, &out, out.len, &returned, null) != 0);
    const expected = reparseBuffer("SEC!");
    try std.testing.expectEqualSlices(u8, &expected, out[0..returned]);
}

test "SEC-FS file symlink never truncates its external target" {
    if (!is_windows) return @import("platform.zig").skip("T9: semantica Win32 (reparse, junction, ADS, 8.3, nombres finales); equivalente POSIX en confined_posix.zig");
    const Link = struct {
        extern "kernel32" fn CreateSymbolicLinkW([*:0]const u16, [*:0]const u16, u32) callconv(.winapi) u8;
    };
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "work");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.txt", .data = "sentinel" });
    const path = try tmp.dir.realPathFileAlloc(io, "work", a);
    defer a.free(path);
    const link = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "link.txt", .{path});
    defer a.free(link);
    const target = try tmp.dir.realPathFileAlloc(io, "outside.txt", a);
    defer a.free(target);
    const link_w = try std.unicode.utf8ToUtf16LeAllocZ(a, link);
    defer a.free(link_w);
    const target_w = try std.unicode.utf8ToUtf16LeAllocZ(a, target);
    defer a.free(target_w);
    var fallback = false;
    if (Link.CreateSymbolicLinkW(link_w, target_w, 2) == 0) {
        if (GetLastError() != 1314) return error.TestUnexpectedResult;
        // Sin privilegio de symlink: mismo escenario con un reparse point de
        // archivo que cualquier usuario puede crear. Ejercita el mismo rechazo
        // generico por atributo REPARSE del handle abierto sin seguirlo.
        fallback = true;
        try tmp.dir.writeFile(io, .{ .sub_path = "work/link.txt", .data = "marcador-intacto" });
        try markReparse(a, link);
    }
    defer if (fallback) clearReparse(a, link);
    std.debug.print("{s}\n", .{if (fallback) "SEC-FS symlink: respaldo reparse (etiqueta 0x80001D0A)" else "SEC-FS symlink: privilegiado"});
    var root = try Root.initMutation(a, path);
    defer root.deinit();
    try std.testing.expectError(error.SandboxDenied, root.writeFile("link.txt", "evil"));
    try std.testing.expectError(error.SandboxDenied, root.openMutation("link.txt", .existing));
    const bytes = try tmp.dir.readFileAlloc(io, "outside.txt", a, .limited(128));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("sentinel", bytes);
    if (fallback) {
        try expectReparseIntact(a, link);
        clearReparse(a, link);
        const marked = try tmp.dir.readFileAlloc(io, "work/link.txt", a, .limited(128));
        defer a.free(marked);
        try std.testing.expectEqualStrings("marcador-intacto", marked);
    }
}

test "SEC-FS preexisting external hardlink rejects write and copy without truncation" {
    if (!is_windows) return @import("platform.zig").skip("T9: semantica Win32 (reparse, junction, ADS, 8.3, nombres finales); equivalente POSIX en confined_posix.zig");
    const Link = struct {
        extern "kernel32" fn CreateHardLinkW([*:0]const u16, [*:0]const u16, ?*anyopaque) callconv(.winapi) c_int;
    };
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "work");
    try tmp.dir.writeFile(io, .{ .sub_path = "outside.txt", .data = "external sentinel must remain byte-for-byte intact" });
    try tmp.dir.writeFile(io, .{ .sub_path = "work/source.txt", .data = "replacement" });
    const path = try tmp.dir.realPathFileAlloc(io, "work", a);
    defer a.free(path);
    const target = try tmp.dir.realPathFileAlloc(io, "outside.txt", a);
    defer a.free(target);
    const link = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "alias.txt", .{path});
    defer a.free(link);
    const target_w = try std.unicode.utf8ToUtf16LeAllocZ(a, target);
    defer a.free(target_w);
    const link_w = try std.unicode.utf8ToUtf16LeAllocZ(a, link);
    defer a.free(link_w);
    try std.testing.expect(Link.CreateHardLinkW(link_w, target_w, null) != 0);
    var root = try Root.initMutation(a, path);
    defer root.deinit();
    try std.testing.expectError(error.HardLinkDenied, root.writeFile("alias.txt", "evil"));
    try std.testing.expectError(error.HardLinkDenied, root.openMutation("alias.txt", .existing));
    try std.testing.expectError(error.HardLinkDenied, root.copyFile(&root, "source.txt", "alias.txt"));
    const bytes = try tmp.dir.readFileAlloc(io, "outside.txt", a, .limited(128));
    defer a.free(bytes);
    try std.testing.expectEqualStrings("external sentinel must remain byte-for-byte intact", bytes);
}

test "SEC-FS actual 8.3 alias cannot select a different canonical name" {
    if (!is_windows) return @import("platform.zig").skip("T9: semantica Win32 (reparse, junction, ADS, 8.3, nombres finales); equivalente POSIX en confined_posix.zig");
    const Short = struct {
        extern "kernel32" fn GetShortPathNameW([*:0]const u16, [*]u16, u32) callconv(.winapi) u32;
    };
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "LongFilenameForAlias.txt", .data = "sentinel" });
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const full = try tmp.dir.realPathFileAlloc(io, "LongFilenameForAlias.txt", a);
    defer a.free(full);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, full);
    defer a.free(wide);
    var short: [32768]u16 = undefined;
    const n = Short.GetShortPathNameW(wide, &short, short.len);
    try std.testing.expect(n > 0 and n < short.len);
    const short_utf8 = try std.unicode.utf16LeToUtf8Alloc(a, short[0..n]);
    defer a.free(short_utf8);
    const basename = std.fs.path.basenameWindows(short_utf8);
    if (std.ascii.eqlIgnoreCase(basename, "LongFilenameForAlias.txt")) {
        std.debug.print("SKIPPED 8.3 alias: volume did not create a short name\n", .{});
        return @import("platform.zig").skip("T9: el volumen no genera nombres cortos 8.3 (NtfsDisable8dot3NameCreation); no hay alias que probar");
    }
    var root = try Root.initMutation(a, path);
    defer root.deinit();
    try std.testing.expectError(error.SandboxDenied, root.writeFile(basename, "evil"));
    const bytes = try root.readFileAlloc(a, "LongFilenameForAlias.txt", 128);
    defer a.free(bytes);
    try std.testing.expectEqualStrings("sentinel", bytes);
}

test "E5.20 E-127 ronda2: handle retenido bloquea reemplazo de raiz" {
    if (!is_windows) return @import("platform.zig").skip("T9: semantica Win32 (reparse, junction, ADS, 8.3, nombres finales); equivalente POSIX en confined_posix.zig");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root");
    const path = try tmp.dir.realPathFileAlloc(io, "root", a);
    defer a.free(path);
    var root = try Root.init(a, path);
    defer root.deinit();
    if (tmp.dir.rename("root", tmp.dir, "replaced", io)) |_| {
        return error.TestUnexpectedResult;
    } else |e| {
        try std.testing.expect(e == error.AccessDenied or e == error.FileBusy);
    }
    var iter = root.dir().iterate();
    try std.testing.expect((try iter.next(io)) == null);
}

test "E5.20 E-127 ronda2: atributos del handle y raiz junction con ancestro alias" {
    if (!is_windows) return @import("platform.zig").skip("T9: semantica Win32 (reparse, junction, ADS, 8.3, nombres finales); equivalente POSIX en confined_posix.zig");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "outside/child");
    const parent = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(parent);
    const outside = try tmp.dir.realPathFileAlloc(io, "outside", a);
    defer a.free(outside);
    const link = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "alias", .{parent});
    defer a.free(link);
    var mk = try @import("providers").github.runCmdCaptureWin32(a, &.{ "cmd.exe", "/d", "/c", "mklink", "/J", link, outside }, null);
    defer mk.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), mk.exit_code);
    defer tmp.dir.deleteDir(io, "alias") catch |e| std.debug.print("confined root junction cleanup: {s}\n", .{@errorName(e)});
    const handle = try openNoFollow(a, link);
    defer _ = CloseHandle(handle);
    // Controles directos: retirar OPEN_REPARSE_POINT o el rechazo de atributos
    // debe poner esta asercion en rojo aunque siga viva la guarda canonica.
    try std.testing.expectError(error.SandboxDenied, attributes(handle));
    try std.testing.expectError(error.SandboxDenied, Root.init(a, link));
    try std.testing.expectError(error.SandboxDenied, strictRoot(a, link));
    const ancestor_alias = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "child", .{link});
    defer a.free(ancestor_alias);
    try std.testing.expectError(error.SandboxDenied, Root.init(a, ancestor_alias));
    const new_alias_child = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "missing" ++ std.fs.path.sep_str ++ "directory", .{link});
    defer a.free(new_alias_child);
    try std.testing.expectError(error.SandboxDenied, strictNewPath(a, new_alias_child));
    const regular_handle = try openNoFollow(a, outside);
    defer _ = CloseHandle(regular_handle);
    // Misma raiz canonica, nombre lexico distinto: no aceptar un alias que
    // ocultase un reparse cuando ambos toplevels coinciden.
    try std.testing.expectError(error.SandboxDenied, validateOpened(a, regular_handle, parent, link));
    try std.testing.expectError(error.SandboxDenied, validateRootOpened(a, regular_handle, link));
}
