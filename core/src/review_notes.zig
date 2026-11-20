const std = @import("std");
const db = @import("db.zig");

/// Tope del cuerpo en bytes (16 KiB), también impuesto por la migración.
pub const MAX_BODY_BYTES: usize = 16 * 1024;

/// Entrada de submitNotes. Hashes SHA-256 hex minúsculos, producidos por
/// hashLine/hashContext; round es la ronda de origen, no un contador de lecturas.
pub const Note = struct {
    file_path: []const u8,
    side: []const u8,
    line: i64,
    line_hash: []const u8,
    context_hash: []const u8,
    body: []const u8,
    round: i64 = 1,
};

pub const StoredNote = struct {
    id: i64,
    order_id: i64,
    task_id: i64,
    note: Note,
    status: []const u8,
    created_at: i64,
    updated_at: i64,
};

/// Las cadenas y la lista pertenecen al resultado; sobreviven al statement y
/// a la conexión. El llamador debe ejecutar deinit exactamente una vez.
pub const Notes = struct {
    arena: std.heap.ArenaAllocator,
    items: []const StoredNote,

    pub fn deinit(self: *Notes) void {
        self.arena.deinit();
    }
};

fn validatePath(path: []const u8) !void {
    if (path.len == 0 or path.len > 4096 or path[0] == '/' or path[0] == '\\' or
        std.mem.indexOfScalar(u8, path, ':') != null or std.mem.indexOfScalar(u8, path, 0) != null)
        return error.InvalidPath;
    var start: usize = 0;
    for (path, 0..) |ch, i| {
        if (ch == '/' or ch == '\\') {
            try validateComponent(path[start..i]);
            start = i + 1;
        }
    }
    try validateComponent(path[start..]);
}

fn validateComponent(part: []const u8) !void {
    if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return error.InvalidPath;
}

fn validateScope(conn: db.Connection, order_id: i64, task_id: i64) !void {
    const st = try conn.prepare("SELECT 1 FROM tasks t JOIN plans p ON p.id=t.plan_id JOIN orders o ON o.id=p.order_id WHERE o.id=? AND t.id=?");
    defer conn.finalize(st);
    try db.bindInt(st, 1, order_id);
    try db.bindInt(st, 2, task_id);
    switch (db.c.sqlite3_step(st)) {
        db.c.SQLITE_ROW => {},
        db.c.SQLITE_DONE => return error.InvalidScope,
        else => return error.StepFailed,
    }
}

fn validateHash(hash: []const u8) !void {
    if (hash.len != 64) return error.InvalidAnchor;
    for (hash) |ch| {
        if (!((ch >= '0' and ch <= '9') or (ch >= 'a' and ch <= 'f'))) return error.InvalidAnchor;
    }
}

fn validateNote(note: Note) !void {
    try validatePath(note.file_path);
    if (!std.mem.eql(u8, note.side, "old") and !std.mem.eql(u8, note.side, "new")) return error.InvalidSide;
    if (note.line < 1) return error.InvalidLine;
    if (std.mem.trim(u8, note.body, " \t\r\n").len == 0) return error.EmptyBody;
    if (note.body.len > MAX_BODY_BYTES) return error.BodyTooLarge;
    if (note.round < 1) return error.InvalidRound;
    try validateHash(note.line_hash);
    try validateHash(note.context_hash);
}

/// Una transacción por lote; valida cada nota dentro de la transacción para
/// revertir también las inserciones anteriores ante una entrada inválida.
/// Mutex de conexión igual que order_progress: nadie intercala otra operación
/// sobre esta conexión entre BEGIN y COMMIT. Conexiones distintas usan SQLite.
pub fn submitNotes(conn: db.Connection, order_id: i64, task_id: i64, notes: []const Note) !void {
    const mutex = db.c.sqlite3_db_mutex(conn.db);
    db.c.sqlite3_mutex_enter(mutex);
    defer db.c.sqlite3_mutex_leave(mutex);
    try conn.exec("BEGIN IMMEDIATE");
    errdefer conn.exec("ROLLBACK") catch |err| std.log.err("review_notes: rollback fallido: {s}", .{@errorName(err)});
    try validateScope(conn, order_id, task_id);
    const st = try conn.prepare(
        "INSERT INTO review_notes(order_id,task_id,file_path,side,line,line_hash,context_hash,body,status,round,created_at,updated_at) " ++
            "VALUES(?,?,?,?,?,?,?,?,'submitted',?,CAST(strftime('%s','now') AS INTEGER),CAST(strftime('%s','now') AS INTEGER))",
    );
    defer conn.finalize(st);
    for (notes) |note| {
        try validateNote(note);
        if (db.c.sqlite3_reset(st) != db.c.SQLITE_OK) return error.StepFailed;
        try db.bindInt(st, 1, order_id);
        try db.bindInt(st, 2, task_id);
        try db.bindText(st, 3, note.file_path);
        try db.bindText(st, 4, note.side);
        try db.bindInt(st, 5, note.line);
        try db.bindText(st, 6, note.line_hash);
        try db.bindText(st, 7, note.context_hash);
        try db.bindText(st, 8, note.body);
        try db.bindInt(st, 9, note.round);
        if (db.c.sqlite3_step(st) != db.c.SQLITE_DONE) return error.StepFailed;
    }
    try conn.exec("COMMIT");
}

/// Hash exacto de los bytes de una línea, sin el separador de fin de línea.
/// Mismo SHA-256/hex que repo_search.chunkHashHex, sin normalización implícita.
pub fn hashLine(line: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(line, &digest, .{});
    var hex: [64]u8 = undefined;
    const chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[i * 2] = chars[b >> 4];
        hex[i * 2 + 1] = chars[b & 15];
    }
    return hex;
}

/// Contexto = SHA-256 de dos campos fijos (presencia + hash hex del vecino),
/// primero anterior y luego siguiente. Un borde se distingue de línea vacía.
/// index es base cero; índice inválido produce contexto sin vecinos.
pub fn hashContext(lines: []const []const u8, index: usize) [64]u8 {
    var context = [_]u8{0} ** 130;
    if (index < lines.len) {
        if (index > 0) {
            context[0] = 1;
            @memcpy(context[1..65], &hashLine(lines[index - 1]));
        }
        if (index < lines.len - 1) {
            context[65] = 1;
            @memcpy(context[66..130], &hashLine(lines[index + 1]));
        }
    }
    return hashLine(&context);
}

pub const RelocatedAnchor = union(enum) {
    line: i64,
    orphaned,
};

/// lines_new corresponde a la misma ruta y lado que note; el llamador elige
/// esa versión. Solo coincide línea Y vecinos exactos. No usa cercanía ni el
/// número anterior para desempatar. No modifica la nota ni la base de datos.
pub fn relocateAnchor(lines_new: []const []const u8, note: Note) RelocatedAnchor {
    var found: ?i64 = null;
    for (lines_new, 0..) |line, i| {
        if (!std.mem.eql(u8, &hashLine(line), note.line_hash)) continue;
        if (!std.mem.eql(u8, &hashContext(lines_new, i), note.context_hash)) continue;
        if (found != null) return .orphaned;
        found = std.math.cast(i64, i + 1) orelse return .orphaned;
    }
    return if (found) |line| .{ .line = line } else .orphaned;
}

fn colText(stmt: *db.c.sqlite3_stmt, col: c_int) []const u8 {
    const ptr = db.c.sqlite3_column_text(stmt, col) orelse return "";
    return ptr[0..@intCast(db.c.sqlite3_column_bytes(stmt, col))];
}

/// Lectura no consumible: devuelve open/submitted de cualquier ronda de origen
/// en orden de creación (id). Resolved/orphaned no se envían al productor.
/// Usa el allocator de conn; el resultado es propietario de todas sus cadenas.
pub fn openNotesForRound(conn: db.Connection, order_id: i64, task_id: i64) !Notes {
    const mutex = db.c.sqlite3_db_mutex(conn.db);
    db.c.sqlite3_mutex_enter(mutex);
    defer db.c.sqlite3_mutex_leave(mutex);
    try validateScope(conn, order_id, task_id);
    var arena = std.heap.ArenaAllocator.init(conn.allocator);
    errdefer arena.deinit();
    const allocator = arena.allocator();
    var list: std.ArrayList(StoredNote) = .empty;
    const st = try conn.prepare(
        "SELECT id,file_path,side,line,line_hash,context_hash,body,status,round,created_at,updated_at FROM review_notes " ++
            "WHERE order_id=? AND task_id=? AND status IN ('open','submitted') ORDER BY id",
    );
    defer conn.finalize(st);
    try db.bindInt(st, 1, order_id);
    try db.bindInt(st, 2, task_id);
    while (true) {
        switch (db.c.sqlite3_step(st)) {
            db.c.SQLITE_DONE => break,
            db.c.SQLITE_ROW => {},
            else => return error.StepFailed,
        }
        try list.append(allocator, .{
            .id = db.c.sqlite3_column_int64(st, 0),
            .order_id = order_id,
            .task_id = task_id,
            .note = .{
                .file_path = try allocator.dupe(u8, colText(st, 1)),
                .side = try allocator.dupe(u8, colText(st, 2)),
                .line = db.c.sqlite3_column_int64(st, 3),
                .line_hash = try allocator.dupe(u8, colText(st, 4)),
                .context_hash = try allocator.dupe(u8, colText(st, 5)),
                .body = try allocator.dupe(u8, colText(st, 6)),
                .round = db.c.sqlite3_column_int64(st, 8),
            },
            .status = try allocator.dupe(u8, colText(st, 7)),
            .created_at = db.c.sqlite3_column_int64(st, 9),
            .updated_at = db.c.sqlite3_column_int64(st, 10),
        });
    }
    return .{ .arena = arena, .items = try list.toOwnedSlice(allocator) };
}

/// Edición sobre la versión actual ('new'); 'old' es histórico inmutable.
/// Divide un rango IA en hasta tres sin atribuir al modelo la línea humana.
/// Invalida content_hash de fragmentos: el hash del rango original ya no los
/// identifica. Conserva provider/model en fragmentos IA, vacíos en el humano.
/// Una línea aún sin rango se registra como humana; repetir es idempotente.
pub fn markHumanEdit(conn: db.Connection, order_id: i64, task_id: i64, file_path: []const u8, line: i64) !void {
    try validatePath(file_path);
    if (line < 1) return error.InvalidLine;
    const mutex = db.c.sqlite3_db_mutex(conn.db);
    db.c.sqlite3_mutex_enter(mutex);
    defer db.c.sqlite3_mutex_leave(mutex);
    try conn.exec("BEGIN IMMEDIATE");
    errdefer conn.exec("ROLLBACK") catch |err| std.log.err("review_notes: rollback de autoría fallido: {s}", .{@errorName(err)});
    try validateScope(conn, order_id, task_id);
    const where = " WHERE order_id=?1 AND task_id=?2 AND file_path=?3 AND side='new' AND author='ai' AND line_start<=?4 AND line_end>=?4";
    for ([_][]const u8{
        "INSERT INTO artifact_line_authorship SELECT order_id,task_id,file_path,side,?4+1,line_end,'',provider,model,author FROM artifact_line_authorship" ++ where ++ " AND line_end>?4",
        "UPDATE artifact_line_authorship SET line_end=?4-1,content_hash=''" ++ where ++ " AND line_start<?4",
        "UPDATE artifact_line_authorship SET line_start=?4,line_end=?4,content_hash='',provider='',model='',author='human'" ++ where,
        "INSERT INTO artifact_line_authorship SELECT ?1,?2,?3,'new',?4,?4,'','','','human' WHERE NOT EXISTS(SELECT 1 FROM artifact_line_authorship WHERE order_id=?1 AND task_id=?2 AND file_path=?3 AND side='new' AND line_start<=?4 AND line_end>=?4)",
    }) |sql| {
        const st = try conn.prepare(sql);
        defer conn.finalize(st);
        try db.bindInt(st, 1, order_id);
        try db.bindInt(st, 2, task_id);
        try db.bindText(st, 3, file_path);
        try db.bindInt(st, 4, line);
        if (db.c.sqlite3_step(st) != db.c.SQLITE_DONE) return error.StepFailed;
    }
    try conn.exec("COMMIT");
}

fn setup() !db.Connection {
    var conn = try db.Connection.open(std.testing.allocator, ":memory:");
    errdefer conn.close();
    try db.Migrator.init(std.testing.allocator).migrate(conn, &db.runtime_schema);
    try conn.exec("INSERT INTO orders(id,project_id,user_prompt,status,created_at) VALUES(1,'p','review','running',1),(2,'p','other','running',1)");
    try conn.exec("INSERT INTO plans(id,order_id,understanding,approved,created_at) VALUES(10,1,'review',1,1),(20,2,'other',1,1)");
    try conn.exec("INSERT INTO tasks(id,plan_id,department,task_type,description,status,created_at) VALUES(11,10,'code','code','review','done',1),(21,20,'code','code','other','done',1)");
    return conn;
}

fn count(conn: db.Connection, sql: []const u8) !i64 {
    const st = try conn.prepare(sql);
    defer conn.finalize(st);
    if (db.c.sqlite3_step(st) != db.c.SQLITE_ROW) return error.StepFailed;
    return db.c.sqlite3_column_int64(st, 0);
}

fn fixtureNote() Note {
    return .{ .file_path = "src/main.zig", .side = "new", .line = 2, .line_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa", .context_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .body = "Check the bound" };
}

test "CK-COMP-010 two notes are submitted together and returned in insertion order" {
    var conn = try setup();
    defer conn.close();
    var second = fixtureNote();
    second.body = "Second note";
    second.line = 4;
    try submitNotes(conn, 1, 11, &.{ fixtureNote(), second });
    var notes = try openNotesForRound(conn, 1, 11);
    defer notes.deinit();
    try std.testing.expectEqual(@as(usize, 2), notes.items.len);
    try std.testing.expectEqualStrings("Check the bound", notes.items[0].note.body);
    try std.testing.expectEqualStrings("Second note", notes.items[1].note.body);
    try std.testing.expectEqualStrings("submitted", notes.items[0].status);
    try std.testing.expect(notes.items[0].id < notes.items[1].id);
    try std.testing.expect(notes.items[0].created_at > 0);
    try std.testing.expectEqual(notes.items[0].created_at, notes.items[0].updated_at);
}

test "CK-COMP-010 invalid second note rolls back the complete batch" {
    var conn = try setup();
    defer conn.close();
    var invalid = fixtureNote();
    invalid.body = " \t\r\n";
    try std.testing.expectError(error.EmptyBody, submitNotes(conn, 1, 11, &.{ fixtureNote(), invalid }));
    try std.testing.expectEqual(@as(i64, 0), try count(conn, "SELECT count(*) FROM review_notes"));
    // A database failure after the first INSERT must also undo that INSERT.
    try conn.exec("CREATE TRIGGER reject_second BEFORE INSERT ON review_notes WHEN NEW.body='reject' BEGIN SELECT RAISE(ABORT,'test rollback'); END");
    invalid.body = "reject";
    try std.testing.expectError(error.StepFailed, submitNotes(conn, 1, 11, &.{ fixtureNote(), invalid }));
    try std.testing.expectEqual(@as(i64, 0), try count(conn, "SELECT count(*) FROM review_notes"));
    try submitNotes(conn, 1, 11, &.{fixtureNote()});
}

test "CK-COMP-010 validates portable relative paths side line body size and scope" {
    var conn = try setup();
    defer conn.close();
    for ([_][]const u8{ "", "../x", "a/../x", "a\\..\\x", "/x", "\\x", "C:/x", "C:x", "//server/x", "a\x00b", ".", "a//x", "a/./x", "a/" }) |path| {
        var n = fixtureNote();
        n.file_path = path;
        try std.testing.expectError(error.InvalidPath, submitNotes(conn, 1, 11, &.{n}));
    }
    var n = fixtureNote();
    n.side = "context";
    try std.testing.expectError(error.InvalidSide, submitNotes(conn, 1, 11, &.{n}));
    n = fixtureNote();
    n.line = 0;
    try std.testing.expectError(error.InvalidLine, submitNotes(conn, 1, 11, &.{n}));
    n = fixtureNote();
    n.body = "";
    try std.testing.expectError(error.EmptyBody, submitNotes(conn, 1, 11, &.{n}));
    const too_big = [_]u8{'a'} ** (MAX_BODY_BYTES + 1);
    n.body = &too_big;
    try std.testing.expectError(error.BodyTooLarge, submitNotes(conn, 1, 11, &.{n}));
    n = fixtureNote();
    n.round = 0;
    try std.testing.expectError(error.InvalidRound, submitNotes(conn, 1, 11, &.{n}));
    try std.testing.expectError(error.InvalidScope, submitNotes(conn, 1, 21, &.{fixtureNote()}));
    try std.testing.expectEqual(@as(i64, 0), try count(conn, "SELECT count(*) FROM review_notes"));
}

test "CK-COMP-010 inserting earlier lines relocates the unique context anchor" {
    const old = [_][]const u8{ "before", "target", "after" };
    const fresh = [_][]const u8{ "inserted", "before", "target", "after" };
    const lh = hashLine(old[1]);
    const ch = hashContext(&old, 1);
    var n = fixtureNote();
    n.line_hash = &lh;
    n.context_hash = &ch;
    const found = relocateAnchor(&fresh, n);
    try std.testing.expectEqual(@as(i64, 3), found.line);
    // Current line number is not used as a fallback when context changed.
    try std.testing.expect(relocateAnchor(&.{ "different", "target", "after" }, n) == .orphaned);
}

test "CK-COMP-010 ambiguous missing and boundary anchors remain explicit" {
    const old = [_][]const u8{ "before", "target", "after" };
    const lh = hashLine(old[1]);
    const ch = hashContext(&old, 1);
    var n = fixtureNote();
    n.line_hash = &lh;
    n.context_hash = &ch;
    try std.testing.expect(relocateAnchor(&.{ "before", "target", "after", "before", "target", "after" }, n) == .orphaned);
    try std.testing.expect(relocateAnchor(&.{}, n) == .orphaned);
    try std.testing.expect(relocateAnchor(&.{"different"}, n) == .orphaned);
    const edge_lh = hashLine("target");
    const edge_ch = hashContext(&.{"target"}, 0);
    n.line_hash = &edge_lh;
    n.context_hash = &edge_ch;
    try std.testing.expectEqual(@as(i64, 1), relocateAnchor(&.{"target"}, n).line);
    try std.testing.expect(relocateAnchor(&.{ "", "target" }, n) == .orphaned);
}

test "CK-COMP-010 round feedback includes only open and submitted within scope" {
    var conn = try setup();
    defer conn.close();
    const n = fixtureNote();
    try submitNotes(conn, 1, 11, &.{ n, n, n, n });
    try conn.exec("UPDATE review_notes SET status=CASE id WHEN 1 THEN 'open' WHEN 2 THEN 'submitted' WHEN 3 THEN 'resolved' ELSE 'orphaned' END");
    try submitNotes(conn, 2, 21, &.{n});
    var notes = try openNotesForRound(conn, 1, 11);
    defer notes.deinit();
    try std.testing.expectEqual(@as(usize, 2), notes.items.len);
    try std.testing.expectEqualStrings("open", notes.items[0].status);
    try std.testing.expectEqualStrings("submitted", notes.items[1].status);
    // Reading another round does not consume unresolved feedback.
    var again = try openNotesForRound(conn, 1, 11);
    defer again.deinit();
    try std.testing.expectEqual(@as(usize, 2), again.items.len);
}

test "CK-COMP-010 human edit splits ai range and preserves other sides and scopes" {
    var conn = try setup();
    defer conn.close();
    try conn.exec("INSERT INTO artifact_line_authorship VALUES(1,11,'src/main.zig','new',1,5,'digest','provider','model','ai'),(1,11,'src/main.zig','old',1,5,'old','provider','model','ai'),(2,21,'src/main.zig','new',1,5,'other','provider','model','ai')");
    try markHumanEdit(conn, 1, 11, "src/main.zig", 3);
    const st = try conn.prepare("SELECT line_start,line_end,author,provider,model,content_hash FROM artifact_line_authorship WHERE order_id=1 AND side='new' ORDER BY line_start");
    defer conn.finalize(st);
    for ([_]i64{ 1, 3, 4 }, [_]i64{ 2, 3, 5 }, [_][]const u8{ "ai", "human", "ai" }) |start, end, author| {
        try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(st));
        try std.testing.expectEqual(start, db.c.sqlite3_column_int64(st, 0));
        try std.testing.expectEqual(end, db.c.sqlite3_column_int64(st, 1));
        try std.testing.expectEqualStrings(author, colText(st, 2));
        try std.testing.expectEqualStrings(if (start == 3) "" else "provider", colText(st, 3));
        try std.testing.expectEqualStrings(if (start == 3) "" else "model", colText(st, 4));
        try std.testing.expectEqualStrings("", colText(st, 5));
    }
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(st));
    try markHumanEdit(conn, 1, 11, "src/main.zig", 3);
    try std.testing.expectEqual(@as(i64, 5), try count(conn, "SELECT count(*) FROM artifact_line_authorship"));
    try std.testing.expectEqual(@as(i64, 2), try count(conn, "SELECT count(*) FROM artifact_line_authorship WHERE content_hash IN ('old','other') AND author='ai'"));
}

test "CK-COMP-010 human edits handle edges untracked lines and rollback on failure" {
    var conn = try setup();
    defer conn.close();
    try conn.exec("INSERT INTO artifact_line_authorship VALUES(1,11,'src/main.zig','new',1,3,'digest','p','m','ai')");
    try conn.exec("CREATE TRIGGER reject_human BEFORE INSERT ON artifact_line_authorship WHEN NEW.author='human' BEGIN SELECT RAISE(ABORT,'test rollback'); END");
    try std.testing.expectError(error.StepFailed, markHumanEdit(conn, 1, 11, "src/main.zig", 2));
    try std.testing.expectEqual(@as(i64, 1), try count(conn, "SELECT count(*) FROM artifact_line_authorship"));
    try conn.exec("DROP TRIGGER reject_human");
    try markHumanEdit(conn, 1, 11, "src/main.zig", 1);
    try markHumanEdit(conn, 1, 11, "src/main.zig", 3);
    try markHumanEdit(conn, 1, 11, "src/main.zig", 8);
    try std.testing.expectEqual(@as(i64, 3), try count(conn, "SELECT count(*) FROM artifact_line_authorship WHERE author='human' AND line_start=line_end"));
    try std.testing.expectError(error.InvalidLine, markHumanEdit(conn, 1, 11, "src/main.zig", 0));
    try std.testing.expectError(error.InvalidPath, markHumanEdit(conn, 1, 11, "../x", 1));
    try std.testing.expectError(error.InvalidScope, markHumanEdit(conn, 1, 21, "src/main.zig", 1));
}

test "CK-COMP-010 migration upgrades previous version without changing existing data" {
    var conn = try db.Connection.open(std.testing.allocator, ":memory:");
    defer conn.close();
    const migrator = db.Migrator.init(std.testing.allocator);
    // V50 (índice 49) crea review_notes; desde V51 ya no es la última migración,
    // así que el índice va fijo y se comprueba que la tabla aún no existe.
    const previous = 49;
    try migrator.migrate(conn, db.runtime_schema[0..previous]);
    try std.testing.expectEqual(@as(i32, previous), try conn.getUserVersion());
    try std.testing.expectError(error.PrepareFailed, conn.prepare("SELECT id FROM review_notes"));
    try conn.exec("INSERT INTO orders(id,project_id,user_prompt,status,created_at) VALUES(7,'existing','preserve','pending',123)");
    try migrator.migrate(conn, &db.runtime_schema);
    try std.testing.expectEqual(@as(i32, @intCast(db.runtime_schema.len)), try conn.getUserVersion());
    try std.testing.expectEqual(@as(i64, 1), try count(conn, "SELECT count(*) FROM orders WHERE id=7 AND project_id='existing' AND user_prompt='preserve' AND status='pending' AND created_at=123"));
    try std.testing.expectEqual(@as(i64, 0), try count(conn, "SELECT count(*) FROM review_notes"));
    try std.testing.expectEqual(@as(i64, 0), try count(conn, "SELECT count(*) FROM artifact_line_authorship"));
    try std.testing.expectEqual(@as(i64, 2), try count(conn, "SELECT count(*) FROM sqlite_master WHERE type='index' AND name IN ('idx_review_notes_order_task','idx_artifact_line_authorship_order_task')"));
    try migrator.migrate(conn, &db.runtime_schema);
    try std.testing.expectError(error.ExecFailed, conn.exec("INSERT INTO review_notes(order_id,task_id,file_path,side,line,line_hash,context_hash,body,status,round,created_at,updated_at) VALUES(7,1,'a','bad',1,'h','c','body','open',1,1,1)"));
    try std.testing.expectError(error.ExecFailed, conn.exec("INSERT INTO review_notes(order_id,task_id,file_path,side,line,line_hash,context_hash,body,status,round,created_at,updated_at) VALUES(7,1,'a','new',1,'h','c','body','bad',1,1,1)"));
    try std.testing.expectError(error.ExecFailed, conn.exec("INSERT INTO artifact_line_authorship VALUES(7,1,'a','new',1,1,'h','p','m','bad')"));
    try std.testing.expectError(error.ExecFailed, conn.exec("INSERT INTO artifact_line_authorship VALUES(7,1,'a','bad',1,1,'h','p','m','ai')"));
}
