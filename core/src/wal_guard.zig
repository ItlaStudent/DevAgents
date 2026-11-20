//! Protección contra un WAL ajeno emparejado con una base grande.
//!
//! Un arranque concurrente puede dejar junto a `runtime.db`, `catalog.db` y
//! `ledger.db` registros WAL de bases recién creadas (secuencia de checkpoint 0,
//! base de 2 páginas). Al
//! abrir, SQLite aplica el WAL sobre el archivo principal intacto y la base
//! queda vacía: DevAgents parecía una instalación nueva. El arreglo manual fue
//! apartar el WAL y el SHM; este módulo lo hace solo, ANTES de abrir.
//!
//! Regla (conservadora: ante la duda no toca nada):
//!   - el WAL tiene cabecera válida y secuencia de checkpoint 0;
//!   - tiene al menos un marco de commit válido (sales iguales a la cabecera);
//!   - el tamaño de base del ÚLTIMO commit es como mucho 1/8 de las páginas
//!     del archivo principal, y el principal tiene al menos 16 páginas.
//! Si se cumple, `<base>-wal` y `<base>-shm` se MUEVEN (nunca se borran) a
//! `wal-apartados\` junto a la base. Si no se pueden mover (otra instancia los
//! tiene abiertos), no se toca nada y se informa.
const std = @import("std");

pub const Outcome = enum { none, quarantined, locked };

const WAL_MAGIC_LE: u32 = 0x377f0682;
const WAL_MAGIC_BE: u32 = 0x377f0683;
const WAL_HEADER = 32;
const FRAME_HEADER = 24;
/// Solo se leen los primeros marcos: el WAL de una base nueva es pequeño.
const MAX_SCAN_BYTES: usize = 64 * 1024 * 1024;

fn be32(b: []const u8) u32 {
    return std.mem.readInt(u32, b[0..4], .big);
}

/// Páginas del archivo principal según su cabecera (offset 16, 2 bytes BE;
/// 1 significa 65536). Null si no es una base SQLite.
pub fn mainPages(header: []const u8, file_size: u64) ?u64 {
    if (header.len < 100) return null;
    if (!std.mem.eql(u8, header[0..16], "SQLite format 3\x00")) return null;
    const raw = std.mem.readInt(u16, header[16..18], .big);
    const page_size: u64 = if (raw == 1) 65536 else raw;
    if (page_size < 512) return null;
    return file_size / page_size;
}

/// Tamaño de base (en páginas) del último commit válido del WAL, o null si el
/// WAL no es de una base recién creada (secuencia distinta de 0) o no tiene
/// ningún commit válido.
pub fn freshWalCommitPages(wal: []const u8) ?u64 {
    if (wal.len < WAL_HEADER) return null;
    const magic = be32(wal[0..4]);
    if (magic != WAL_MAGIC_LE and magic != WAL_MAGIC_BE) return null;
    const page_size = be32(wal[8..12]);
    if (page_size < 512 or page_size > 65536) return null;
    const checkpoint_seq = be32(wal[12..16]);
    if (checkpoint_seq != 0) return null;
    const salt1 = be32(wal[16..20]);
    const salt2 = be32(wal[20..24]);
    var offset: usize = WAL_HEADER;
    var last_commit: ?u64 = null;
    while (offset + FRAME_HEADER + page_size <= wal.len) : (offset += FRAME_HEADER + page_size) {
        const frame = wal[offset .. offset + FRAME_HEADER];
        if (be32(frame[8..12]) != salt1 or be32(frame[12..16]) != salt2) break;
        const db_size = be32(frame[4..8]);
        if (db_size != 0) last_commit = db_size;
    }
    return last_commit;
}

const GetSystemTimeAsFileTime = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetSystemTimeAsFileTime(time: *std.os.windows.FILETIME) callconv(.winapi) void;
}.GetSystemTimeAsFileTime else @import("platform.zig").filetime;

/// Segundos Unix para nombrar lo apartado (no hace falta conexión a la base).
pub fn unixNow() i64 {
    var ft: std.os.windows.FILETIME = undefined;
    GetSystemTimeAsFileTime(&ft);
    const ticks = (@as(u64, ft.dwHighDateTime) << 32) | ft.dwLowDateTime;
    return @intCast(ticks / 10_000_000 -| 11_644_473_600);
}

/// Revisa las bases de una carpeta de datos antes de abrirlas (da_core_init).
pub fn guardAll(a: std.mem.Allocator, paths: []const []const u8) void {
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const now = unixNow();
    for (paths) |path| switch (guard(a, io, path, now)) {
        .none => {},
        .quarantined => std.debug.print("[wal_guard] {s}: WAL de una base nueva sobre una base grande; apartado en wal-apartados (no se borró nada)\n", .{path}),
        .locked => std.debug.print("[wal_guard] {s}: WAL sospechoso, pero está en uso; no se tocó\n", .{path}),
    };
}

pub fn suspicious(main_pages: u64, commit_pages: u64) bool {
    return main_pages >= 16 and commit_pages * 8 <= main_pages;
}

/// Revisa `db_path` y, si su WAL es de una base nueva y el principal es
/// grande, aparta el WAL y el SHM. Nunca borra. Cualquier error de lectura
/// cuenta como «no tocar».
pub fn guard(a: std.mem.Allocator, io: std.Io, db_path: []const u8, now_s: i64) Outcome {
    return guardImpl(a, io, db_path, now_s) catch .none;
}

fn guardImpl(a: std.mem.Allocator, io: std.Io, db_path: []const u8, now_s: i64) !Outcome {
    const cwd = std.Io.Dir.cwd();
    const wal_path = try std.fmt.allocPrint(a, "{s}-wal", .{db_path});
    defer a.free(wal_path);
    const shm_path = try std.fmt.allocPrint(a, "{s}-shm", .{db_path});
    defer a.free(shm_path);

    const wal = cwd.readFileAlloc(io, wal_path, a, .limited(MAX_SCAN_BYTES)) catch |e| switch (e) {
        error.FileNotFound => return .none,
        error.StreamTooLong => return .none,
        else => return e,
    };
    defer a.free(wal);
    const commit_pages = freshWalCommitPages(wal) orelse return .none;

    var main = cwd.openFile(io, db_path, .{}) catch return .none;
    const stat = main.stat(io) catch {
        main.close(io);
        return .none;
    };
    var header: [100]u8 = undefined;
    const read = main.readPositionalAll(io, &header, 0) catch 0;
    main.close(io);
    if (read < header.len) return .none;
    const pages = mainPages(&header, stat.size) orelse return .none;
    if (!suspicious(pages, commit_pages)) return .none;

    const dir = std.fs.path.dirname(db_path) orelse ".";
    const base = std.fs.path.basename(db_path);
    const aside_dir = try std.fs.path.join(a, &.{ dir, "wal-apartados" });
    defer a.free(aside_dir);
    cwd.createDirPath(io, aside_dir) catch return .locked;
    const wal_dest = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "{s}-wal-{d}", .{ aside_dir, base, now_s });
    defer a.free(wal_dest);
    cwd.rename(wal_path, cwd, wal_dest, io) catch return .locked;
    const shm_dest = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "{s}-shm-{d}", .{ aside_dir, base, now_s });
    defer a.free(shm_dest);
    cwd.rename(shm_path, cwd, shm_dest, io) catch |e| switch (e) {
        // Sin SHM no hay nada más que apartar; SQLite lo recrea.
        error.FileNotFound => {},
        else => {
            // Sin el WAL, el SHM viejo describe marcos que ya no existen:
            // devolver el WAL a su sitio antes que dejar la pareja rota.
            cwd.rename(wal_dest, cwd, wal_path, io) catch {};
            return .locked;
        },
    };
    return .quarantined;
}

// --- Pruebas ---------------------------------------------------------------

fn walBytes(a: std.mem.Allocator, seq: u32, commits: []const u32, page_size: u32) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    var h: [WAL_HEADER]u8 = @splat(0);
    std.mem.writeInt(u32, h[0..4], WAL_MAGIC_LE, .big);
    std.mem.writeInt(u32, h[4..8], 3007000, .big);
    std.mem.writeInt(u32, h[8..12], page_size, .big);
    std.mem.writeInt(u32, h[12..16], seq, .big);
    std.mem.writeInt(u32, h[16..20], 0xAAAA0001, .big);
    std.mem.writeInt(u32, h[20..24], 0xBBBB0002, .big);
    try out.appendSlice(a, &h);
    for (commits, 0..) |db_size, i| {
        var f: [FRAME_HEADER]u8 = @splat(0);
        std.mem.writeInt(u32, f[0..4], @intCast(i + 1), .big);
        std.mem.writeInt(u32, f[4..8], db_size, .big);
        std.mem.writeInt(u32, f[8..12], 0xAAAA0001, .big);
        std.mem.writeInt(u32, f[12..16], 0xBBBB0002, .big);
        try out.appendSlice(a, &f);
        try out.appendNTimes(a, 0, page_size);
    }
    return out.toOwnedSlice(a);
}

fn mainBytes(a: std.mem.Allocator, pages: usize) ![]u8 {
    const page = 4096;
    const out = try a.alloc(u8, pages * page);
    @memset(out, 0);
    @memcpy(out[0..16], "SQLite format 3\x00");
    std.mem.writeInt(u16, out[16..18], page, .big);
    return out;
}

test "WAL de base nueva sobre una base grande: se reconoce" {
    const a = std.testing.allocator;
    const fresh = try walBytes(a, 0, &.{ 0, 2 }, 4096);
    defer a.free(fresh);
    try std.testing.expectEqual(@as(?u64, 2), freshWalCommitPages(fresh));
    try std.testing.expect(suspicious(400, 2));
    // Un WAL normal de la propia base: el commit conserva su tamaño.
    try std.testing.expect(!suspicious(400, 401));
    try std.testing.expect(!suspicious(10, 1)); // base pequeña: no se toca
    // Secuencia distinta de 0: no es de una base recién creada.
    const old = try walBytes(a, 3, &.{2}, 4096);
    defer a.free(old);
    try std.testing.expectEqual(@as(?u64, null), freshWalCommitPages(old));
    // Sin commit válido no hay nada que aplicar.
    const no_commit = try walBytes(a, 0, &.{0}, 4096);
    defer a.free(no_commit);
    try std.testing.expectEqual(@as(?u64, null), freshWalCommitPages(no_commit));
}

test "WAL ajeno: se aparta junto al SHM y nunca se borra; uno normal no se toca" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const db_path = try std.fs.path.join(a, &.{ root, "runtime.db" });
    defer a.free(db_path);

    const main = try mainBytes(a, 64);
    defer a.free(main);
    try tmp.dir.writeFile(io, .{ .sub_path = "runtime.db", .data = main });
    const normal = try walBytes(a, 0, &.{64}, 4096);
    defer a.free(normal);
    try tmp.dir.writeFile(io, .{ .sub_path = "runtime.db-wal", .data = normal });
    try std.testing.expectEqual(Outcome.none, guard(a, io, db_path, 1));

    const fresh = try walBytes(a, 0, &.{2}, 4096);
    defer a.free(fresh);
    try tmp.dir.writeFile(io, .{ .sub_path = "runtime.db-wal", .data = fresh });
    try tmp.dir.writeFile(io, .{ .sub_path = "runtime.db-shm", .data = "shm" });
    try std.testing.expectEqual(Outcome.quarantined, guard(a, io, db_path, 77));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "runtime.db-wal", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "runtime.db-shm", .{}));
    _ = try tmp.dir.statFile(io, "wal-apartados/runtime.db-wal-77", .{});
    _ = try tmp.dir.statFile(io, "wal-apartados/runtime.db-shm-77", .{});
    // El archivo principal queda intacto.
    const after = try tmp.dir.readFileAlloc(io, "runtime.db", a, .limited(1 << 20));
    defer a.free(after);
    try std.testing.expectEqualSlices(u8, main, after);
}

test "WAL real de una base recién creada junto a una base grande: la base no se vacía" {
    const db = @import("db.zig");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const big_path = try std.fs.path.join(a, &.{ root, "runtime.db" });
    defer a.free(big_path);
    const fresh_path = try std.fs.path.join(a, &.{ root, "nueva.db" });
    defer a.free(fresh_path);

    // Base grande con datos, cerrada y sin WAL pendiente.
    {
        var big = try db.Connection.open(a, big_path);
        defer big.close();
        try big.exec("CREATE TABLE orders(id INTEGER PRIMARY KEY, body TEXT)");
        var i: usize = 0;
        while (i < 400) : (i += 1) try big.exec("INSERT INTO orders(body) VALUES (hex(randomblob(400)))");
        try big.exec("PRAGMA wal_checkpoint(TRUNCATE)");
    }
    // WAL de una base recién creada (lo que dejaron las instancias del 10-nov).
    var fresh = try db.Connection.open(a, fresh_path);
    try fresh.exec("CREATE TABLE orders(id INTEGER PRIMARY KEY, body TEXT)");
    const fresh_wal = try std.fmt.allocPrint(a, "{s}-wal", .{fresh_path});
    defer a.free(fresh_wal);
    const wal_bytes = try std.Io.Dir.cwd().readFileAlloc(io, fresh_wal, a, .limited(1 << 22));
    defer a.free(wal_bytes);
    fresh.close();
    const big_wal = try std.fmt.allocPrint(a, "{s}-wal", .{big_path});
    defer a.free(big_wal);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = big_wal, .data = wal_bytes });

    try std.testing.expectEqual(Outcome.quarantined, guard(a, io, big_path, 5));
    var check = try db.Connection.open(a, big_path);
    defer check.close();
    const q = try check.prepare("SELECT COUNT(*) FROM orders");
    defer check.finalize(q);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(q));
    try std.testing.expectEqual(@as(i64, 400), db.c.sqlite3_column_int64(q, 0));
}
