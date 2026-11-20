//! Secrets live only in the environment or a private JSON file, never SQLite.
const std = @import("std");
const c = std.c;
extern "c" fn fstat(fd: c.fd_t, stat: *c.Stat) c_int;
extern "c" fn renameat(old_dir: c.fd_t, old_path: [*:0]const u8, new_dir: c.fd_t, new_path: [*:0]const u8) c_int;
const Reference = struct { provider: []const u8, label: []const u8 };

pub fn validateMode(mode: u32, owner: u32, expected_owner: u32, regular: bool) !void {
    if (!regular or mode & 0o777 != 0o600 or owner != expected_owner) return error.UnsafeKeyFile;
}

/// T12B B-7 (auditor 3): la carpeta de claves no puede dejar entrar a grupo ni
/// a otros, y tiene que ser del usuario que la usa.
pub fn validateDirMode(mode: u32, owner: u32, expected_owner: u32, directory: bool) !void {
    if (!directory or mode & 0o077 != 0 or owner != expected_owner) return error.UnsafeKeyDir;
}

pub fn envName(a: std.mem.Allocator, provider: []const u8) ![:0]u8 {
    if (provider.len == 0 or provider.len > 128) return error.InvalidProvider;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(a);
    try out.appendSlice(a, "DEVAGENTS_KEY_");
    for (provider) |ch| try out.append(a, if (std.ascii.isAlphanumeric(ch)) std.ascii.toUpper(ch) else '_');
    return a.dupeZ(u8, out.items);
}

/// T12B B-7 (auditor 3): crea la carpeta con 0700 y valida propietario y permisos
/// sobre el descriptor abierto (O_NOFOLLOW|O_DIRECTORY), no por ruta. Así no
/// hay carrera entre crear y comprobar, y un enlace simbólico no cuela. Una
/// carpeta que ya existía abierta se rechaza; no se «arregla» en silencio.
fn ensurePrivateConfigDir(a: std.mem.Allocator, config: [:0]const u8) !c.fd_t {
    const parent = std.fs.path.dirname(config) orelse return error.InvalidConfigDirectory;
    {
        var t: std.Io.Threaded = .init(a, .{});
        defer t.deinit();
        try std.Io.Dir.cwd().createDirPath(t.io(), parent);
    }
    const parent_z = try a.dupeZ(u8, parent);
    defer a.free(parent_z);
    const parent_fd = c.open(parent_z, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .DIRECTORY = true });
    if (parent_fd < 0) return error.KeyDirOpenFailed;
    defer _ = c.close(parent_fd);
    const leaf = try a.dupeZ(u8, std.fs.path.basename(config));
    defer a.free(leaf);
    if (c.mkdirat(parent_fd, leaf, @as(c.mode_t, 0o700)) != 0 and c._errno().* != @intFromEnum(std.posix.E.EXIST))
        return error.KeyDirCreateFailed;
    const fd = c.openat(parent_fd, leaf, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .DIRECTORY = true });
    if (fd < 0) return error.KeyDirOpenFailed;
    errdefer _ = c.close(fd);
    const stat = @import("providers").posix_stat.get(fd, null) catch return error.KeyDirStatFailed;
    const mode: u32 = @intCast(stat.mode);
    try validateDirMode(mode, @intCast(stat.uid), @intCast(c.getuid()), mode & c.S.IFMT == c.S.IFDIR);
    return fd;
}

fn keyDirectory(a: std.mem.Allocator) !c.fd_t {
    const home = std.mem.span(c.getenv("HOME") orelse return error.HomeNotDefined);
    const config = if (c.getenv("XDG_CONFIG_HOME")) |raw| try std.fs.path.joinZ(a, &.{ std.mem.span(raw), "devagents" }) else try std.fs.path.joinZ(a, &.{ home, ".config/devagents" });
    defer a.free(config);
    if (!std.fs.path.isAbsolute(config)) return error.InvalidConfigDirectory;
    return ensurePrivateConfigDir(a, config);
}

fn openPrivate(dir: c.fd_t, path: [:0]const u8, create: bool) !c.fd_t {
    const flags: c.O = .{ .ACCMODE = if (create) .RDWR else .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .CREAT = create };
    const fd = c.openat(dir, path, flags, @as(c.mode_t, 0o600));
    if (fd < 0) return if (c._errno().* == @intFromEnum(std.posix.E.NOENT)) error.FileNotFound else error.KeyFileOpenFailed;
    errdefer _ = c.close(fd);
    const stat = @import("providers").posix_stat.get(fd, null) catch return error.KeyFileStatFailed;
    try validateMode(@intCast(stat.mode), @intCast(stat.uid), @intCast(c.getuid()), stat.mode & c.S.IFMT == c.S.IFREG);
    if (stat.size > 1024 * 1024) return error.KeyFileTooLarge;
    return fd;
}

fn load(a: std.mem.Allocator, fd: c.fd_t) !std.json.Parsed(std.json.Value) {
    var bytes: std.ArrayList(u8) = .empty;
    defer bytes.deinit(a);
    var buf: [4096]u8 = undefined;
    while (true) {
        const n = c.read(fd, &buf, buf.len);
        if (n < 0) {
            if (c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
            return error.KeyFileReadFailed;
        }
        if (n == 0) break;
        if (bytes.items.len + @as(usize, @intCast(n)) > 1024 * 1024) return error.KeyFileTooLarge;
        try bytes.appendSlice(a, buf[0..@intCast(n)]);
    }
    var parsed = try std.json.parseFromSlice(std.json.Value, a, if (bytes.items.len == 0) "{}" else bytes.items, .{ .allocate = .alloc_always });
    errdefer parsed.deinit();
    if (parsed.value != .object) return error.InvalidKeyFile;
    var providers = parsed.value.object.iterator();
    while (providers.next()) |provider| {
        if (provider.value_ptr.* != .object) return error.InvalidKeyFile;
        var labels = provider.value_ptr.object.iterator();
        while (labels.next()) |label| if (label.value_ptr.* != .string or label.value_ptr.string.len == 0) return error.InvalidKeyFile;
    }
    return parsed;
}

pub fn store(a: std.mem.Allocator, provider: []const u8, label: []const u8, key: []const u8) ![]const u8 {
    if (key.len == 0 or key.len > 16384 or label.len == 0 or label.len > 128) return error.InvalidKey;
    const name = try envName(a, provider);
    defer a.free(name);
    if (c.getenv(name)) |raw| {
        if (std.mem.eql(u8, std.mem.span(raw), key)) return std.json.Stringify.valueAlloc(a, Reference{ .provider = provider, .label = label }, .{});
    }
    const dir = try keyDirectory(a);
    defer _ = c.close(dir);
    const lock_fd = try openPrivate(dir, "keys.json.lock", true);
    defer _ = c.close(lock_fd);
    if (c.flock(lock_fd, c.LOCK.EX) != 0) return error.KeyFileLockFailed;
    const fd = try openPrivate(dir, "keys.json", true);
    defer _ = c.close(fd);
    var parsed = try load(a, fd);
    defer parsed.deinit();
    const arena = parsed.arena.allocator();
    const entry = try parsed.value.object.getOrPut(arena, try arena.dupe(u8, provider));
    if (!entry.found_existing) entry.value_ptr.* = .{ .object = .{} };
    try entry.value_ptr.object.put(arena, try arena.dupe(u8, label), .{ .string = try arena.dupe(u8, key) });
    try writeAtomic(a, dir, parsed.value);
    return std.json.Stringify.valueAlloc(a, Reference{ .provider = provider, .label = label }, .{});
}

fn writeAtomic(a: std.mem.Allocator, dir: c.fd_t, value: std.json.Value) !void {
    const json = try std.json.Stringify.valueAlloc(a, value, .{});
    defer a.free(json);
    const temporary = try std.fmt.allocPrintSentinel(a, "keys.json.{d}.{d}.new", .{ c.getpid(), @import("platform.zig").ticks() }, 0);
    defer a.free(temporary);
    const output = c.openat(dir, temporary, .{ .ACCMODE = .WRONLY, .CLOEXEC = true, .NOFOLLOW = true, .CREAT = true, .EXCL = true }, @as(c.mode_t, 0o600));
    if (output < 0) return error.KeyFileWriteFailed;
    defer _ = c.close(output);
    var committed = false;
    defer if (!committed) {
        if (c.unlinkat(dir, temporary, 0) != 0) std.log.err("key file temporary cleanup failed", .{});
    };
    var offset: usize = 0;
    while (offset < json.len) {
        const n = c.write(output, json.ptr + offset, json.len - offset);
        if (n < 0) {
            if (c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
            return error.KeyFileWriteFailed;
        }
        if (n == 0) return error.KeyFileWriteFailed;
        offset += @intCast(n);
    }
    if (c.fsync(output) != 0 or renameat(dir, temporary, dir, "keys.json") != 0) return error.KeyFileWriteFailed;
    committed = true;
}

pub fn resolve(a: std.mem.Allocator, reference: []const u8) ![]const u8 {
    var ref = try std.json.parseFromSlice(Reference, a, reference, .{});
    defer ref.deinit();
    const name = try envName(a, ref.value.provider);
    defer a.free(name);
    if (c.getenv(name)) |raw| {
        const value = std.mem.span(raw);
        if (value.len == 0 or value.len > 16384) return error.InvalidKey;
        return a.dupe(u8, value);
    }
    const dir = try keyDirectory(a);
    defer _ = c.close(dir);
    const fd = try openPrivate(dir, "keys.json", false);
    defer _ = c.close(fd);
    if (c.flock(fd, c.LOCK.SH) != 0) return error.KeyFileLockFailed;
    var parsed = try load(a, fd);
    defer parsed.deinit();
    const provider = parsed.value.object.get(ref.value.provider) orelse return error.KeyNotFound;
    const key = provider.object.get(ref.value.label) orelse return error.KeyNotFound;
    return a.dupe(u8, key.string);
}

test "B10 credential guard rejects group/world, wrong owner and non-regular file" {
    try validateMode(0o600, 1000, 1000, true);
    try std.testing.expectError(error.UnsafeKeyFile, validateMode(0o644, 1000, 1000, true));
    try std.testing.expectError(error.UnsafeKeyFile, validateMode(0o660, 1000, 1000, true));
    try std.testing.expectError(error.UnsafeKeyFile, validateMode(0o600, 0, 1000, true));
    try std.testing.expectError(error.UnsafeKeyFile, validateMode(0o600, 1000, 1000, false));
}
test "T12B B-7: la carpeta de claves se crea 0700 y se rechaza si grupo u otros pueden entrar" {
    if (@import("builtin").os.tag != .windows) {
        try validateDirMode(0o700, 1000, 1000, true);
        try std.testing.expectError(error.UnsafeKeyDir, validateDirMode(0o750, 1000, 1000, true));
        try std.testing.expectError(error.UnsafeKeyDir, validateDirMode(0o701, 1000, 1000, true));
        try std.testing.expectError(error.UnsafeKeyDir, validateDirMode(0o700, 0, 1000, true));
        try std.testing.expectError(error.UnsafeKeyDir, validateDirMode(0o700, 1000, 1000, false));

        const a = std.testing.allocator;
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
        defer a.free(base);
        // Crea también los padres que falten; la hoja queda en 0700.
        const fresh = try std.fmt.allocPrintSentinel(a, "{s}/cfg/devagents", .{base}, 0);
        defer a.free(fresh);
        const fresh_fd = try ensurePrivateConfigDir(a, fresh);
        defer _ = c.close(fresh_fd);
        {
            const fd = c.open(fresh, .{ .ACCMODE = .RDONLY, .CLOEXEC = true, .NOFOLLOW = true, .DIRECTORY = true });
            try std.testing.expect(fd >= 0);
            defer _ = c.close(fd);
            const st = try @import("providers").posix_stat.get(fd, null);
            try std.testing.expectEqual(@as(u32, 0o700), @as(u32, @intCast(st.mode)) & 0o777);
        }
        // Una carpeta preexistente con permisos abiertos no se acepta.
        const loose = try std.fmt.allocPrintSentinel(a, "{s}/abierta", .{base}, 0);
        defer a.free(loose);
        try tmp.dir.createDirPath(std.testing.io, "abierta");
        try std.testing.expectEqual(@as(c_int, 0), c.chmod(loose, 0o755));
        try std.testing.expectError(error.UnsafeKeyDir, ensurePrivateConfigDir(a, loose));
        try std.testing.expectEqual(@as(c_int, 0), c.chmod(loose, 0o700));
        const loose_fd = try ensurePrivateConfigDir(a, loose);
        defer _ = c.close(loose_fd);
        const link = try std.fmt.allocPrintSentinel(a, "{s}/enlace", .{base}, 0);
        defer a.free(link);
        try std.testing.expectEqual(@as(c_int, 0), c.symlink(loose, link));
        try std.testing.expectError(error.KeyDirOpenFailed, ensurePrivateConfigDir(a, link));
    } else {
        // En Windows las claves van por DPAPI; esta ruta POSIX no se compila.
        return @import("platform.zig").skip("T12B B-7: la carpeta de claves con 0700 es POSIX; en Windows las claves van por DPAPI");
    }
}

test "B10 environment names validate provider and normalize punctuation" {
    const name = try envName(std.testing.allocator, "NVIDIA API");
    defer std.testing.allocator.free(name);
    try std.testing.expectEqualStrings("DEVAGENTS_KEY_NVIDIA_API", name);
    try std.testing.expectError(error.InvalidProvider, envName(std.testing.allocator, ""));
}

test "T12B B-7: sustituir la ruta después de validar no redirige la escritura de claves" {
    if (@import("builtin").os.tag == .windows) return @import("platform.zig").skip("T12B B-7: carrera de directorio y openat solo POSIX; Windows usa DPAPI");
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(base);
    const original = try std.fmt.allocPrintSentinel(a, "{s}/private", .{base}, 0);
    defer a.free(original);
    const retained = try std.fmt.allocPrintSentinel(a, "{s}/retained", .{base}, 0);
    defer a.free(retained);
    const decoy = try std.fmt.allocPrintSentinel(a, "{s}/decoy", .{base}, 0);
    defer a.free(decoy);
    try tmp.dir.createDirPath(std.testing.io, "decoy");
    const dir = try ensurePrivateConfigDir(a, original);
    defer _ = c.close(dir);
    try std.testing.expectEqual(@as(c_int, 0), c.rename(original, retained));
    try std.testing.expectEqual(@as(c_int, 0), c.symlink(decoy, original));
    // Objeto vacío sintético: ninguna clave ni entorno real.
    try writeAtomic(a, dir, .{ .object = .empty });
    const file = try openPrivate(dir, "keys.json", false);
    defer _ = c.close(file);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(std.testing.io, "decoy/keys.json", .{}));
}

/// Deletes only the selected entries, under the same writer lock used for rotation.
pub fn remove(a: std.mem.Allocator, provider: ?[]const u8, label: ?[]const u8) !void {
    const dir = try keyDirectory(a);
    defer _ = c.close(dir);
    const lock_fd = try openPrivate(dir, "keys.json.lock", true);
    defer _ = c.close(lock_fd);
    if (c.flock(lock_fd, c.LOCK.EX) != 0) return error.KeyFileLockFailed;
    const fd = openPrivate(dir, "keys.json", false) catch |e| switch (e) {
        error.FileNotFound => return,
        else => return e,
    };
    defer _ = c.close(fd);
    var parsed = try load(a, fd);
    defer parsed.deinit();
    if (provider) |name| {
        if (label) |lbl| {
            if (parsed.value.object.getPtr(name)) |entry| {
                _ = entry.object.swapRemove(lbl);
                if (entry.object.count() == 0) _ = parsed.value.object.swapRemove(name);
            }
        } else _ = parsed.value.object.swapRemove(name);
    } else {
        // Webhook secrets share the private file and are not provider credentials.
        var it = parsed.value.object.iterator();
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(a);
        while (it.next()) |entry| if (!std.mem.eql(u8, entry.key_ptr.*, "_secrets")) try names.append(a, entry.key_ptr.*);
        for (names.items) |name| _ = parsed.value.object.swapRemove(name);
    }
    try writeAtomic(a, dir, parsed.value);
}
