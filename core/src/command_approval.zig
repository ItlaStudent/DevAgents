//! Aprobación humana por argv exacto. No concede permisos por prefijo.
const std = @import("std");
const db = @import("db.zig");
const health = @import("health.zig");
const Sleep = @import("platform.zig").sleep;
pub const PREFIX = "inline_command";

/// T12 M5: ventana en la que una escritura por MCP se avisa en la tarjeta de
/// aprobación de un comando (un `npm run dev` aprobado ejecuta el
/// package.json que el cliente acaba de escribir).
pub const MCP_WRITES_NOTE_WINDOW_MS: i64 = 10 * 60 * 1000;
pub const MCP_FILE_WRITTEN_EVENT = "mcp_file_written_v1";

/// Devuelve `description` (copia) con el aviso de escrituras MCP recientes
/// añadido si las hay. Si no se puede leer el registro, lo dice en la tarjeta
/// en vez de callarlo.
pub fn withRecentMcpWritesNote(aa: std.mem.Allocator, conn: db.Connection, description: []const u8, project_root: []const u8) ![]u8 {
    const note = recentMcpWritesNote(aa, conn, project_root) catch |e| {
        std.log.warn("aviso de escrituras MCP no calculado: {s}", .{@errorName(e)});
        return std.fmt.allocPrint(aa, "{s}. Aviso: no se pudo comprobar si un cliente MCP escribió archivos del proyecto en los últimos minutos ({s}).", .{ description, @errorName(e) });
    };
    const text = note orelse return aa.dupe(u8, description);
    defer aa.free(text);
    return std.fmt.allocPrint(aa, "{s}. {s}", .{ description, text });
}

fn recentMcpWritesNote(aa: std.mem.Allocator, conn: db.Connection, project_root: []const u8) !?[]u8 {
    const key = try projectKey(aa, project_root);
    defer aa.free(key);
    const q = try conn.prepare(
        \\SELECT json_extract(payload_json,'$.path') FROM events
        \\WHERE kind = 'mcp_file_written_v1' AND ts >= ? AND json_valid(payload_json)
        \\AND json_extract(payload_json,'$.project_root') = ?
        \\GROUP BY json_extract(payload_json,'$.path')
        \\ORDER BY MAX(rowid) DESC
    );
    defer conn.finalize(q);
    try db.bindInt(q, 1, health.nowMillis(conn) - MCP_WRITES_NOTE_WINDOW_MS);
    try db.bindText(q, 2, key);
    var count: usize = 0;
    var names: std.Io.Writer.Allocating = .init(aa);
    defer names.deinit();
    while (true) {
        const rc = db.c.sqlite3_step(q);
        if (rc == db.c.SQLITE_DONE) break;
        if (rc != db.c.SQLITE_ROW) return error.StepFailed;
        count += 1;
        if (count <= 3) {
            if (count > 1) try names.writer.writeAll(", ");
            try names.writer.writeAll(colText(q, 0));
        }
    }
    if (count == 0) return null;
    return try std.fmt.allocPrint(aa, "Atención: un cliente MCP escribió {d} archivo(s) del proyecto en los últimos {d} min ({s}{s}); este comando puede ejecutar lo que escribió", .{ count, @divTrunc(MCP_WRITES_NOTE_WINDOW_MS, 60_000), names.written(), if (count > 3) ", ..." else "" });
}

fn colText(stmt: *db.c.sqlite3_stmt, index: c_int) []const u8 {
    if (db.c.sqlite3_column_type(stmt, index) == db.c.SQLITE_NULL) return "";
    const t = db.c.sqlite3_column_text(stmt, index);
    if (t == null) return "";
    return std.mem.span(t);
}

pub fn emitNeeded(conn: db.Connection, allocator: std.mem.Allocator, order_id: i64, approval_id: i64, task_id: []const u8, description: []const u8, command_prefix: ?[]const u8) !void {
    const payload = try std.json.Stringify.valueAlloc(allocator, .{
        .approval_id = approval_id,
        .task_id = task_id,
        .description = description,
        .command_prefix = command_prefix orelse "",
        .tool = "run_command",
        .reason = description,
    }, .{});
    defer allocator.free(payload);
    const query = try conn.prepare("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (?, 'superagente', 'approval_needed', ?, ?)");
    defer conn.finalize(query);
    try db.bindInt(query, 1, health.nowMillis(conn));
    try db.bindText(query, 2, payload);
    try db.bindInt(query, 3, order_id);
    if (db.c.sqlite3_step(query) != db.c.SQLITE_DONE) return error.ExecFailed;
}

pub fn waitForHuman(allocator: std.mem.Allocator, conn: db.Connection, order_id: i64, task_id: []const u8, exe: []const u8, args: []const []const u8, cwd: []const u8, project_root: []const u8, cancelled: *const fn (?*anyopaque) bool, ctx: ?*anyopaque) !bool {
    if (cancelled(ctx)) return error.Cancelled;
    const payload = try std.json.Stringify.valueAlloc(allocator, .{ .exe = exe, .args = args, .cwd = cwd }, .{});
    defer allocator.free(payload);
    const plain = try std.fmt.allocPrint(allocator, "Aprobar este comando exacto: {s}", .{payload});
    defer allocator.free(plain);
    // T12 M5: la tarjeta de un agente también dice si un cliente MCP escribió
    // archivos del proyecto hace poco (el comando puede ejecutarlos).
    const description = try withRecentMcpWritesNote(allocator, conn, plain, project_root);
    defer allocator.free(description);
    const id = blk: {
        const insert = try conn.prepare("INSERT INTO approvals (task_id, description, approved, resolved, created_at, command_prefix, exe, args_json, order_id) VALUES (?, ?, 0, 0, ?, ?, NULL, ?, ?) RETURNING id");
        defer conn.finalize(insert);
        try db.bindText(insert, 1, task_id);
        try db.bindText(insert, 2, description);
        try db.bindInt(insert, 3, health.nowMillis(conn));
        try db.bindText(insert, 4, PREFIX);
        try db.bindText(insert, 5, payload);
        try db.bindInt(insert, 6, order_id);
        if (db.c.sqlite3_step(insert) != db.c.SQLITE_ROW) return error.ExecFailed;
        const id = db.c.sqlite3_column_int64(insert, 0);
        if (db.c.sqlite3_step(insert) != db.c.SQLITE_DONE) return error.ExecFailed;
        break :blk id;
    };
    // El worker espera por su conexión propia, sin retener mutex de UI.
    // Timeout/cancelación invalida la tarjeta: no puede aprobar un hijo huérfano.
    defer {
        const expire = conn.prepare("UPDATE approvals SET resolved=1, approved=0 WHERE id=? AND resolved=0") catch |e| blk: {
            std.log.err("approval expire prepare: {s}", .{@errorName(e)});
            break :blk null;
        };
        if (expire) |stmt| {
            defer conn.finalize(stmt);
            db.bindInt(stmt, 1, id) catch |e| std.log.err("approval expire bind: {s}", .{@errorName(e)});
            if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) std.log.err("approval expire failed", .{});
        }
    }
    try emitNeeded(conn, allocator, order_id, id, task_id, description, PREFIX);
    for (0..1200) |_| {
        if (cancelled(ctx)) return error.Cancelled;
        {
            const query = try conn.prepare("SELECT resolved, approved FROM approvals WHERE id=?");
            defer conn.finalize(query);
            try db.bindInt(query, 1, id);
            if (db.c.sqlite3_step(query) != db.c.SQLITE_ROW) return error.ExecFailed;
            if (db.c.sqlite3_column_int(query, 0) != 0) return db.c.sqlite3_column_int(query, 1) != 0;
        }
        Sleep(100);
    }
    return error.PermissionRequired;
}

/// Stable project identity; Windows paths are case insensitive.
pub fn projectKey(a: std.mem.Allocator, root: []const u8) ![]u8 {
    const absolute = try std.fs.path.resolve(a, &.{root});
    if (@import("builtin").os.tag == .windows) for (absolute) |*c| {
        c.* = if (c.* == '/') '\\' else std.ascii.toLower(c.*);
    };
    return absolute;
}

test "VG1 B-1: MCP writes are scoped to their project" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try conn.exec("CREATE TABLE events(ts INTEGER, kind TEXT, payload_json TEXT)");
    const key = try projectKey(a, "project-A");
    defer a.free(key);
    const payload = try std.json.Stringify.valueAlloc(a, .{ .path = "package.json", .project_root = key }, .{});
    defer a.free(payload);
    const q = try conn.prepare("INSERT INTO events VALUES (?, 'mcp_file_written_v1', ?)");
    defer conn.finalize(q);
    try db.bindInt(q, 1, health.nowMillis(conn));
    try db.bindText(q, 2, payload);
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(q));
    const other = try withRecentMcpWritesNote(a, conn, "command", "project-B");
    defer a.free(other);
    try std.testing.expectEqualStrings("command", other);
    const same = try withRecentMcpWritesNote(a, conn, "command", "project-A");
    defer a.free(same);
    try std.testing.expect(std.mem.indexOf(u8, same, "package.json") != null);
}
