const std = @import("std");
const db = @import("db.zig");
const superagent = @import("superagent.zig");

const GetTickCount64 = @import("platform.zig").ticks;

/// Memory backend fallback persistente sobre runtime.db.
/// Usa SQL con parámetros enlazados (CODING-STANDARDS §8).
/// Toda salida JSON se construye con std.json.Stringify (sin interpolación).
pub const LocalMemory = struct {
    allocator: std.mem.Allocator,
    db_conn: db.Connection,

    pub fn init(allocator: std.mem.Allocator, db_conn: db.Connection) LocalMemory {
        return .{ .allocator = allocator, .db_conn = db_conn };
    }

    pub fn deinit(self: *LocalMemory) void {
        _ = self;
    }

    pub fn backend(self: *LocalMemory) superagent.MemoryBackend {
        return .{
            .ptr = self,
            .loadContextFn = loadContext,
            .saveFindingFn = saveFinding,
            .sessionSummaryFn = sessionSummary,
            .saveLessonFn = saveLesson,
            .loadLessonsFn = loadLessons,
        };
    }

    fn loadContext(ptr: *anyopaque, allocator: std.mem.Allocator, project: []const u8) ?[]const u8 {
        const self: *LocalMemory = @ptrCast(@alignCast(ptr));

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        js.beginObject() catch return null;

        js.objectField("sessions") catch return null;
        js.beginArray() catch return null;
        if (loadSessionsJson(self, &js)) {} else |_| {}
        js.endArray() catch return null;

        js.objectField("findings") catch return null;
        js.beginArray() catch return null;
        if (loadFindingsJson(self, project, &js)) {} else |_| {}
        js.endArray() catch return null;

        js.objectField("note") catch return null;
        js.write("Fallback local persistente (runtime.db). Engram MCP no disponible.") catch return null;

        js.endObject() catch return null;
        return allocator.dupe(u8, out.written()) catch null;
    }

    fn loadSessionsJson(self: *LocalMemory, js: *std.json.Stringify) !void {
        const stmt = self.db_conn.prepare("SELECT id, title, summary, created_at FROM memory_sessions ORDER BY created_at DESC LIMIT 50") catch return;
        defer self.db_conn.finalize(stmt);
        while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            js.beginObject() catch continue;
            js.objectField("id") catch continue;
            js.write(db.c.sqlite3_column_int64(stmt, 0)) catch continue;
            js.objectField("title") catch continue;
            const title_ptr = db.c.sqlite3_column_text(stmt, 1);
            const title_len = db.c.sqlite3_column_bytes(stmt, 1);
            const title = if (title_ptr != null) title_ptr[0..@intCast(title_len)] else "";
            js.write(title) catch continue;
            js.objectField("summary") catch continue;
            const sum_ptr = db.c.sqlite3_column_text(stmt, 2);
            const sum_len = db.c.sqlite3_column_bytes(stmt, 2);
            const summary = sum_ptr[0..@intCast(sum_len)];
            js.write(summary) catch continue;
            js.objectField("created_at") catch continue;
            js.write(db.c.sqlite3_column_int64(stmt, 3)) catch continue;
            js.endObject() catch continue;
        }
    }

    fn loadFindingsJson(self: *LocalMemory, project: []const u8, js: *std.json.Stringify) !void {
        const stmt = if (project.len > 0)
            self.db_conn.prepare("SELECT id, content, type, project, created_at FROM memory_findings WHERE project = ? OR project = '' ORDER BY created_at DESC LIMIT 100") catch return
        else
            self.db_conn.prepare("SELECT id, content, type, project, created_at FROM memory_findings ORDER BY created_at DESC LIMIT 100") catch return;
        defer self.db_conn.finalize(stmt);
        if (project.len > 0) {
            db.bindText(stmt, 1, project) catch {};
        }
        while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            js.beginObject() catch continue;
            js.objectField("id") catch continue;
            js.write(db.c.sqlite3_column_int64(stmt, 0)) catch continue;
            js.objectField("content") catch continue;
            const cptr = db.c.sqlite3_column_text(stmt, 1);
            const clen = db.c.sqlite3_column_bytes(stmt, 1);
            const content = cptr[0..@intCast(clen)];
            js.write(content) catch continue;
            js.objectField("type") catch continue;
            const tptr = db.c.sqlite3_column_text(stmt, 2);
            const tlen = db.c.sqlite3_column_bytes(stmt, 2);
            const ftype = tptr[0..@intCast(tlen)];
            js.write(ftype) catch continue;
            js.objectField("project") catch continue;
            const pptr = db.c.sqlite3_column_text(stmt, 3);
            const plen = db.c.sqlite3_column_bytes(stmt, 3);
            const fproj = pptr[0..@intCast(plen)];
            js.write(fproj) catch continue;
            js.objectField("created_at") catch continue;
            js.write(db.c.sqlite3_column_int64(stmt, 4)) catch continue;
            js.endObject() catch continue;
        }
    }

    fn saveFinding(ptr: *anyopaque, finding: []const u8) void {
        const self: *LocalMemory = @ptrCast(@alignCast(ptr));
        const stmt = self.db_conn.prepare("INSERT INTO memory_findings (content, type, project, created_at) VALUES (?, 'discovery', '', ?)") catch return;
        defer self.db_conn.finalize(stmt);
        db.bindText(stmt, 1, finding) catch return;
        db.bindInt(stmt, 2, @intCast(GetTickCount64())) catch return;
        _ = db.c.sqlite3_step(stmt);
    }

    fn sessionSummary(ptr: *anyopaque, summary: []const u8, _: []const u8) void {
        const self: *LocalMemory = @ptrCast(@alignCast(ptr));
        const title = deriveTitle(summary);
        const stmt = self.db_conn.prepare("INSERT INTO memory_sessions (title, summary, created_at) VALUES (?, ?, ?)") catch return;
        defer self.db_conn.finalize(stmt);
        db.bindText(stmt, 1, title) catch return;
        db.bindText(stmt, 2, summary) catch return;
        db.bindInt(stmt, 3, @intCast(GetTickCount64())) catch return;
        _ = db.c.sqlite3_step(stmt);
    }

    fn saveLesson(ptr: *anyopaque, lesson: []const u8, project: []const u8) bool {
        const self: *LocalMemory = @ptrCast(@alignCast(ptr));
        const stmt = self.db_conn.prepare("INSERT INTO memory_findings (content, type, project, created_at) VALUES (?, 'lesson', ?, ?)") catch return false;
        defer self.db_conn.finalize(stmt);
        db.bindText(stmt, 1, lesson) catch return false;
        db.bindText(stmt, 2, project) catch return false;
        db.bindInt(stmt, 3, @intCast(GetTickCount64())) catch return false;
        // T8: el evento memory_lesson_saved_v1 solo sale si la fila se escribió.
        return db.c.sqlite3_step(stmt) == db.c.SQLITE_DONE;
    }

    fn loadLessons(ptr: *anyopaque, allocator: std.mem.Allocator, project: []const u8, limit: usize) ?[]const u8 {
        const self: *LocalMemory = @ptrCast(@alignCast(ptr));
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        js.beginArray() catch return null;

        const lim: i64 = @intCast(if (limit > 0) limit else 3);
        const stmt = if (project.len > 0)
            self.db_conn.prepare("SELECT id, content, project, created_at FROM memory_findings WHERE type = 'lesson' AND (project = ? OR project = '') ORDER BY created_at DESC LIMIT ?") catch return null
        else
            self.db_conn.prepare("SELECT id, content, project, created_at FROM memory_findings WHERE type = 'lesson' ORDER BY created_at DESC LIMIT ?") catch return null;
        defer self.db_conn.finalize(stmt);

        if (project.len > 0) {
            db.bindText(stmt, 1, project) catch return null;
            db.bindInt(stmt, 2, lim) catch return null;
        } else {
            db.bindInt(stmt, 1, lim) catch return null;
        }

        while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            js.beginObject() catch continue;
            js.objectField("id") catch continue;
            js.write(db.c.sqlite3_column_int64(stmt, 0)) catch continue;
            js.objectField("content") catch continue;
            const cptr = db.c.sqlite3_column_text(stmt, 1);
            const clen = db.c.sqlite3_column_bytes(stmt, 1);
            js.write(if (cptr != null) cptr[0..@intCast(clen)] else "") catch continue;
            js.objectField("project") catch continue;
            const pptr = db.c.sqlite3_column_text(stmt, 2);
            const plen = db.c.sqlite3_column_bytes(stmt, 2);
            js.write(if (pptr != null) pptr[0..@intCast(plen)] else "") catch continue;
            js.objectField("created_at") catch continue;
            js.write(db.c.sqlite3_column_int64(stmt, 3)) catch continue;
            js.endObject() catch continue;
        }
        js.endArray() catch return null;
        return allocator.dupe(u8, out.written()) catch null;
    }
};

fn deriveTitle(summary: []const u8) []const u8 {
    const nl = std.mem.indexOfScalar(u8, summary, '\n') orelse summary.len;
    const end = @min(nl, @as(usize, 60));
    const t = std.mem.trim(u8, summary[0..end], " \t\r");
    return t;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "local memory saveFinding and loadContext roundtrip" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    var lm = LocalMemory.init(allocator, conn);
    const bk = lm.backend();

    bk.saveFinding("hallazgo de prueba");
    const ctx = bk.loadContext(allocator, "");
    try std.testing.expect(ctx != null);
    defer if (ctx) |c| allocator.free(c);
    try std.testing.expect(std.mem.indexOf(u8, ctx.?, "hallazgo de prueba") != null);
    try std.testing.expect(std.mem.indexOf(u8, ctx.?, "Fallback local") != null);
}

test "local memory sessionSummary persists" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    var lm = LocalMemory.init(allocator, conn);
    const bk = lm.backend();

    bk.saveSessionSummary("resumen de sesión de prueba", "proj");
    const ctx = bk.loadContext(allocator, "");
    try std.testing.expect(ctx != null);
    defer if (ctx) |c| allocator.free(c);
    try std.testing.expect(std.mem.indexOf(u8, ctx.?, "resumen de sesión") != null);
}

test "local memory re-init over same db preserves findings" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    {
        var lm = LocalMemory.init(allocator, conn);
        const bk = lm.backend();
        bk.saveFinding("finding persistente");
    }

    {
        var lm2 = LocalMemory.init(allocator, conn);
        const bk2 = lm2.backend();
        const ctx = bk2.loadContext(allocator, "");
        try std.testing.expect(ctx != null);
        defer if (ctx) |c| allocator.free(c);
        try std.testing.expect(std.mem.indexOf(u8, ctx.?, "finding persistente") != null);
    }
}

test "local memory saveLesson and loadLessons roundtrip" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    var lm = LocalMemory.init(allocator, conn);
    const bk = lm.backend();

    try std.testing.expect(bk.saveLesson("lesson: avoid model X for task Y", "proj-test"));
    const lessons = bk.loadLessons(allocator, "proj-test", 3);
    try std.testing.expect(lessons != null);
    defer if (lessons) |l| allocator.free(l);
    try std.testing.expect(std.mem.indexOf(u8, lessons.?, "avoid model X") != null);
}
