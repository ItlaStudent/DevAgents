const std = @import("std");
const db = @import("db.zig");
const sandbox = @import("sandbox.zig");

pub const Mount = struct {
    id: i64,
    path: []const u8,
    added_at: i64,
    active: bool,
};

pub const MountError = db.DbError || error{
    OutOfMemory,
    PathNotFound,
    AlreadyMounted,
};

pub const MountRegistry = struct {
    allocator: std.mem.Allocator,
    conn: db.Connection,

    pub fn init(allocator: std.mem.Allocator, conn: db.Connection) MountRegistry {
        return .{ .allocator = allocator, .conn = conn };
    }

    pub fn add(self: *MountRegistry, path: []const u8, now: i64) MountError!void {
        // Validar que la ruta existe usando el mismo patrón que tool_discovery
        if (path.len == 0) return error.PathNotFound;

        const stmt = try self.conn.prepare("INSERT INTO mounts (path, added_at) VALUES (?1, ?2)");
        defer self.conn.finalize(stmt);
        try db.bindText(stmt, 1, path);
        try db.bindInt(stmt, 2, now);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.AlreadyMounted;
    }

    pub fn remove(self: *MountRegistry, path: []const u8) MountError!void {
        const stmt = try self.conn.prepare("DELETE FROM mounts WHERE path = ?1");
        defer self.conn.finalize(stmt);
        try db.bindText(stmt, 1, path);
        // El resultado se descartaba con `_ =`. Comprobado en vivo: la fila
        // seguia en runtime.db y la API respondia `unmounted:true` igualmente,
        // asi que desde el panel se podian enlazar carpetas pero no quitarlas
        // nunca. Un DELETE que no borra tiene que doler.
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.PathNotFound;
        if (db.c.sqlite3_changes(self.conn.db) == 0) return error.PathNotFound;
    }

    pub fn list(self: *MountRegistry, allocator: std.mem.Allocator) MountError![]Mount {
        const stmt = try self.conn.prepare("SELECT id, path, added_at, active FROM mounts ORDER BY id");
        defer self.conn.finalize(stmt);
        var mounts: std.ArrayList(Mount) = .empty;
        while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            const id = db.c.sqlite3_column_int64(stmt, 0);
            const path_ptr = db.c.sqlite3_column_text(stmt, 1);
            const path_len: usize = @intCast(db.c.sqlite3_column_bytes(stmt, 1));
            const added_at = db.c.sqlite3_column_int64(stmt, 2);
            const active_int = db.c.sqlite3_column_int(stmt, 3);
            const path_dup = try allocator.alloc(u8, path_len);
            @memcpy(path_dup, path_ptr[0..path_len]);
            try mounts.append(allocator, .{
                .id = id,
                .path = path_dup,
                .added_at = added_at,
                .active = active_int != 0,
            });
        }
        return mounts.toOwnedSlice(allocator);
    }

    pub fn listActive(self: *MountRegistry, allocator: std.mem.Allocator) MountError![]Mount {
        const stmt = try self.conn.prepare("SELECT id, path, added_at, active FROM mounts WHERE active = 1 ORDER BY id");
        defer self.conn.finalize(stmt);
        var mounts: std.ArrayList(Mount) = .empty;
        while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            const id = db.c.sqlite3_column_int64(stmt, 0);
            const path_ptr = db.c.sqlite3_column_text(stmt, 1);
            const path_len: usize = @intCast(db.c.sqlite3_column_bytes(stmt, 1));
            const added_at = db.c.sqlite3_column_int64(stmt, 2);
            const active_int = db.c.sqlite3_column_int(stmt, 3);
            const path_dup = try allocator.alloc(u8, path_len);
            @memcpy(path_dup, path_ptr[0..path_len]);
            try mounts.append(allocator, .{
                .id = id,
                .path = path_dup,
                .added_at = added_at,
                .active = active_int != 0,
            });
        }
        return mounts.toOwnedSlice(allocator);
    }

    pub fn getActivePaths(self: *MountRegistry, allocator: std.mem.Allocator) MountError![][]const u8 {
        const all = try self.listActive(allocator);
        var paths: std.ArrayList([]const u8) = .empty;
        for (all) |m| {
            try paths.append(allocator, m.path);
        }
        return paths.toOwnedSlice(allocator);
    }
};

/// H7 r4: true si la ruta es UNC (`\\servidor\...` o `//servidor/...`).
/// Incluye las formas de dispositivo y extendidas (`\\.\`, `\\?\`), que
/// empiezan igual. La usa también el confinamiento MCP de `da_mount_add`.
pub fn pathIsUnc(path: []const u8) bool {
    return path.len >= 2 and ((path[0] == '\\' and path[1] == '\\') or (path[0] == '/' and path[1] == '/'));
}

pub const NewRootError = error{
    /// Ruta vacía o de más de 4000 bytes.
    MountPathInvalid,
    /// `\\servidor\recurso`, o una unidad de red que resuelve a una.
    MountPathUnc,
    /// `\\.\NUL`, `\\?\C:\…`, `CON`, `NUL`… (dispositivos y rutas extendidas).
    MountPathDevice,
    /// `C:\` entero: montar una unidad completa expone todo el disco.
    MountPathDriveRoot,
    PathNotFound,
    MountPathNotDirectory,
    OutOfMemory,
};

const GetFullPathNameA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFullPathNameA(lpFileName: [*:0]const u8, nBufferLength: u32, lpBuffer: [*]u8, lpFilePart: ?*?[*:0]u8) callconv(.winapi) u32;
}.GetFullPathNameA else @import("providers").posix_files.GetFullPathNameA;
const GetFileAttributesA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileAttributesA(lpFileName: [*:0]const u8) callconv(.winapi) u32;
}.GetFileAttributesA else @import("providers").posix_files.GetFileAttributesA;

fn isDriveRoot(path: []const u8) bool {
    return path.len == 3 and std.ascii.isAlphabetic(path[0]) and path[1] == ':' and (path[2] == '\\' or path[2] == '/');
}

/// QA-A H8: una raíz NUEVA que registra una persona (CLI) tiene que ser una
/// carpeta local que existe y que no sea una unidad entera. El MCP no la
/// necesita: solo puede montar dentro de raíces ya registradas
/// (`mountConfined` en c_api.zig). Devuelve la ruta absoluta (del llamador).
pub fn validateNewRoot(allocator: std.mem.Allocator, path: []const u8) NewRootError![]u8 {
    if (path.len == 0 or path.len > 4000 or std.mem.indexOfScalar(u8, path, 0) != null) return error.MountPathInvalid;
    if (pathIsUnc(path)) {
        if (path.len >= 4 and (path[2] == '.' or path[2] == '?') and (path[3] == '\\' or path[3] == '/')) return error.MountPathDevice;
        return error.MountPathUnc;
    }
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    var full_buf: [4096]u8 = undefined;
    const n = GetFullPathNameA(path_z, full_buf.len, &full_buf, null);
    if (n == 0 or n >= full_buf.len) return error.MountPathInvalid;
    const full = full_buf[0..n];
    // Un nombre reservado (`NUL`, `CON`, `COM1`…) se resuelve a `\\.\NUL`.
    if (pathIsUnc(full)) return error.MountPathDevice;
    if (isDriveRoot(full)) return error.MountPathDriveRoot;
    const full_z = try allocator.dupeZ(u8, full);
    defer allocator.free(full_z);
    const attrs = GetFileAttributesA(full_z);
    if (attrs == 0xFFFFFFFF) return error.PathNotFound;
    if (attrs & 0x10 == 0) return error.MountPathNotDirectory;
    // El destino REAL (junctions, unidades de red y `subst` resueltos) tampoco
    // puede ser una unidad entera ni un recurso de red.
    const canonical = sandbox.canonicalizeExisting(allocator, full) orelse return error.PathNotFound;
    defer allocator.free(canonical);
    if (std.ascii.startsWithIgnoreCase(canonical, "UNC\\")) return error.MountPathUnc;
    if (isDriveRoot(canonical)) return error.MountPathDriveRoot;
    return allocator.dupe(u8, full);
}

/// QA-A H8/H12: frase para la persona que montó la ruta.
pub fn newRootErrorMessage(e: anyerror) []const u8 {
    return switch (e) {
        error.MountPathInvalid => "la ruta está vacía o es demasiado larga",
        error.MountPathUnc => "es una ruta de red (UNC); monta una carpeta local",
        error.MountPathDevice => "es un dispositivo o una ruta extendida de Windows (\\\\.\\, \\\\?\\, NUL, CON…), no una carpeta",
        error.MountPathDriveRoot => "es la raíz de una unidad entera; elige una carpeta dentro de ella",
        error.PathNotFound => "la carpeta no existe; créala antes o revisa la ruta",
        error.MountPathNotDirectory => "es un archivo, no una carpeta",
        error.AlreadyMounted => "ya estaba montada (míralo con `devagents mount list`)",
        error.OutOfMemory => "memoria insuficiente",
        else => "no se pudo guardar en runtime.db",
    };
}

test "add and list mounts" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    var reg = MountRegistry.init(allocator, conn);

    try reg.add("C:\\test\\path", 1000);
    const mounts = try reg.list(allocator);
    defer {
        for (mounts) |m| allocator.free(m.path);
        allocator.free(mounts);
    }
    try std.testing.expectEqual(@as(usize, 1), mounts.len);
    try std.testing.expectEqualStrings("C:\\test\\path", mounts[0].path);
    try std.testing.expectEqual(@as(i64, 1000), mounts[0].added_at);
    try std.testing.expectEqual(true, mounts[0].active);
}

test "remove mount" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    var reg = MountRegistry.init(allocator, conn);

    try reg.add("C:\\mounts\\a", 1000);
    try reg.remove("C:\\mounts\\a");
    const mounts = try reg.list(allocator);
    defer {
        for (mounts) |m| allocator.free(m.path);
        allocator.free(mounts);
    }
    try std.testing.expectEqual(@as(usize, 0), mounts.len);
}

test "reject duplicate mount" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    var reg = MountRegistry.init(allocator, conn);

    try reg.add("C:\\unique", 1000);
    try std.testing.expectError(error.AlreadyMounted, reg.add("C:\\unique", 1001));
}

test "listActive returns only active mounts" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    var reg = MountRegistry.init(allocator, conn);

    try reg.add("C:\\active", 1000);
    const active = try reg.listActive(allocator);
    defer {
        for (active) |m| allocator.free(m.path);
        allocator.free(active);
    }
    try std.testing.expectEqual(@as(usize, 1), active.len);
    try std.testing.expectEqual(true, active[0].active);
    try std.testing.expectEqualStrings("C:\\active", active[0].path);
}
