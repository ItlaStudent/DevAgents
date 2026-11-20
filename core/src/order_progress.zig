const std = @import("std");
const db = @import("db.zig");

/// estado de avance escrito por el agente, por orden, sin pisar
/// al humano. Cada escritura es un compare-and-swap con un número de secuencia
/// (`seq`) monótono: quien escribe declara el `seq` que leyó (`expected_seq`) y
/// solo se escribe si sigue siendo el actual (UPDATE ... WHERE seq = ?). Un
/// reporte LLEGADO TARDE (secuenciado sobre un estado que ya cambió) se
/// descarta con error.StaleProgress y el seq real, SIN escribir nada. La regla
/// de lectura previa («leer antes de escribir») queda así obligatoria por
/// construcción, no por convención.
///
/// La nota que escribió el HUMANO solo la puede cambiar el humano: un agente
/// puede avanzar el estado (mismo seq al día) dejando la nota intacta, jamás
/// sobrescribirla. El humano siempre puede.
pub const MAX_NOTE_BYTES: usize = 2 * 1024;

pub const VALID_STATES = [_][]const u8{ "todo", "in_progress", "in_review", "done" };
pub const VALID_AUTHORS = [_][]const u8{ "agent", "human" };

pub const ProgressError = error{
    /// expected_seq no coincide con el seq actual (o hay fila y no era 0): no se escribe.
    StaleProgress,
    /// El agente intentó cambiar una nota escrita por el humano.
    HumanNoteProtected,
    InvalidState,
    InvalidAuthor,
    InvalidSequence,
    NoteTooLarge,
    OrderNotFound,
    OutOfMemory,
    DbUnavailable,
};

/// Una fila de avance: cadenas copiadas con `allocator`; `deinit` las libera.
pub const Progress = struct {
    order_id: i64,
    state: []const u8,
    note: []const u8,
    author: []const u8,
    seq: i64,
    updated_at: i64,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *Progress) void {
        self.allocator.free(self.state);
        self.allocator.free(self.note);
        self.allocator.free(self.author);
    }
};

fn dup(allocator: std.mem.Allocator, s: []const u8) ProgressError![]const u8 {
    if (s.len == 0) return "";
    return allocator.dupe(u8, s) catch error.OutOfMemory;
}

fn isValidState(state: []const u8) bool {
    for (VALID_STATES) |s| {
        if (std.mem.eql(u8, s, state)) return true;
    }
    return false;
}

fn isValidAuthor(author: []const u8) bool {
    for (VALID_AUTHORS) |a| {
        if (std.mem.eql(u8, a, author)) return true;
    }
    return false;
}

/// Lectura del avance de una orden. null = la orden existe pero nadie ha
/// reportado aún (found:false en la API).
pub fn readProgress(allocator: std.mem.Allocator, conn: db.Connection, order_id: i64) ProgressError!?Progress {
    const st = conn.prepare("SELECT state, note, author, seq, updated_at FROM order_progress WHERE order_id = ?") catch return error.DbUnavailable;
    defer conn.finalize(st);
    db.bindInt(st, 1, order_id) catch return error.DbUnavailable;
    const rc = db.c.sqlite3_step(st);
    if (rc != db.c.SQLITE_ROW) {
        if (rc != db.c.SQLITE_DONE) return error.DbUnavailable;
        // Sin fila no es un error: es una orden sin reporte (found:false).
        return null;
    }
    var p: Progress = .{
        .order_id = order_id,
        .state = "",
        .note = "",
        .author = "",
        .seq = db.c.sqlite3_column_int64(st, 3),
        .updated_at = db.c.sqlite3_column_int64(st, 4),
        .allocator = allocator,
    };
    errdefer p.deinit();
    p.state = try dup(allocator, colText(st, 0));
    p.note = try dup(allocator, colText(st, 1));
    p.author = try dup(allocator, colText(st, 2));
    return p;
}

fn colText(stmt: *db.c.sqlite3_stmt, col: c_int) []const u8 {
    const ptr = db.c.sqlite3_column_text(stmt, col) orelse return "";
    const len = db.c.sqlite3_column_bytes(stmt, col);
    return ptr[0..@intCast(len)];
}

/// Época en SEGUNDOS como orders.created_at (Zig 0.16 no expone
/// std.time.timestamp: ver plugin_loader.zig:375 — se le pide a SQLite).
fn nowSeconds(conn: db.Connection) ProgressError!i64 {
    const st = conn.prepare("SELECT CAST(strftime('%s','now') AS INTEGER)") catch return error.DbUnavailable;
    defer conn.finalize(st);
    if (db.c.sqlite3_step(st) != db.c.SQLITE_ROW) return error.DbUnavailable;
    return db.c.sqlite3_column_int64(st, 0);
}

/// Escritura condicional («leer antes de escribir», compare-and-swap). Solo
/// escribe si el seq actual == `expected_seq` (UPDATE ... WHERE seq = ? en UNA
/// sola sentencia; INSERT si no hay fila y expected_seq == 0) y deja seq+1,
/// devolviendo el nuevo seq. En cualquier otro caso devuelve error.StaleProgress
/// cargando en `out_stale_seq` (si no es null) el seq ACTUAL (0 si no hay fila)
/// y NO escribe nada.
///
/// Regla humana: si el último autor es 'human', un escritor 'agent' NO puede
/// cambiar la nota (solo avanzar el estado con el seq al día, dejándola
/// intacta); error.HumanNoteProtected. El humano siempre puede.
pub fn writeProgress(
    allocator: std.mem.Allocator,
    conn: db.Connection,
    order_id: i64,
    expected_seq: i64,
    state: []const u8,
    note: []const u8,
    author: []const u8,
    out_stale_seq: ?*i64,
) ProgressError!i64 {
    if (!isValidState(state)) return error.InvalidState;
    if (!isValidAuthor(author)) return error.InvalidAuthor;
    if (note.len > MAX_NOTE_BYTES) return error.NoteTooLarge;
    if (expected_seq < 0 or expected_seq == std.math.maxInt(i64)) return error.InvalidSequence;

    // SQLite's recursive connection mutex keeps step/changes inseparable even
    // when callers share this connection. Other connections still use the CAS.
    const mutex = db.c.sqlite3_db_mutex(conn.db);
    db.c.sqlite3_mutex_enter(mutex);
    defer db.c.sqlite3_mutex_leave(mutex);

    // La orden debe existir: order_progress referencia orders.
    if (!try orderExists(conn, order_id)) return error.OrderNotFound;

    var existing: ?Progress = try readProgress(allocator, conn, order_id);
    defer if (existing) |*p| {
        p.deinit();
    };

    const current_seq: i64 = if (existing) |p| p.seq else 0;
    defer if (current_seq != expected_seq) {
        if (out_stale_seq) |p| p.* = current_seq;
    };
    if (current_seq != expected_seq) return error.StaleProgress;

    // Regla humana: la nota del humano solo la cambia otro humano. El agente
    // con seq al día puede avanzar el estado dejando la nota EXACTA igual.
    if (existing) |p| {
        if (std.mem.eql(u8, p.author, "human") and std.mem.eql(u8, author, "agent") and
            !std.mem.eql(u8, note, p.note))
        {
            return error.HumanNoteProtected;
        }
    }

    const new_seq: i64 = current_seq + 1;
    const ts = try nowSeconds(conn);
    // A state-only agent report must not transfer ownership of a human note.
    const stored_author = if (existing != null and std.mem.eql(u8, existing.?.author, "human") and
        std.mem.eql(u8, author, "agent")) "human" else author;

    if (existing != null) {
        // CAS en UNA sola sentencia: si el concurrente avanzó el seq entre la
        // lectura y aquí, el WHERE ya no encuentra la fila (changes 0).
        const st = conn.prepare("UPDATE order_progress SET state = ?, note = ?, author = ?, seq = ?, updated_at = ? WHERE order_id = ? AND seq = ?") catch return error.DbUnavailable;
        defer conn.finalize(st);
        db.bindText(st, 1, state) catch return error.DbUnavailable;
        db.bindText(st, 2, note) catch return error.DbUnavailable;
        db.bindText(st, 3, stored_author) catch return error.DbUnavailable;
        db.bindInt(st, 4, new_seq) catch return error.DbUnavailable;
        db.bindInt(st, 5, ts) catch return error.DbUnavailable;
        db.bindInt(st, 6, order_id) catch return error.DbUnavailable;
        db.bindInt(st, 7, expected_seq) catch return error.DbUnavailable;
        if (db.c.sqlite3_step(st) != db.c.SQLITE_DONE) return error.DbUnavailable;
        if (conn.changes() != 1) {
            var raced: ?Progress = try readProgress(allocator, conn, order_id);
            defer if (raced) |*p| {
                p.deinit();
            };
            if (out_stale_seq) |s| s.* = if (raced) |p| p.seq else 0;
            return error.StaleProgress;
        }
    } else {
        const st = conn.prepare("INSERT INTO order_progress (order_id, state, note, author, seq, updated_at) VALUES (?, ?, ?, ?, ?, ?)") catch return error.DbUnavailable;
        defer conn.finalize(st);
        db.bindInt(st, 1, order_id) catch return error.DbUnavailable;
        db.bindText(st, 2, state) catch return error.DbUnavailable;
        db.bindText(st, 3, note) catch return error.DbUnavailable;
        db.bindText(st, 4, author) catch return error.DbUnavailable;
        db.bindInt(st, 5, new_seq) catch return error.DbUnavailable;
        db.bindInt(st, 6, ts) catch return error.DbUnavailable;
        if (db.c.sqlite3_step(st) != db.c.SQLITE_DONE) {
            // Carrera de INSERT: si otro escritor ganó, es un reporte del pasado.
            var raced: ?Progress = try readProgress(allocator, conn, order_id);
            defer if (raced) |*p| {
                p.deinit();
            };
            if (raced != null) {
                if (out_stale_seq) |s| s.* = raced.?.seq;
                return error.StaleProgress;
            }
            return error.DbUnavailable;
        }
    }
    return new_seq;
}

fn orderExists(conn: db.Connection, order_id: i64) ProgressError!bool {
    const st = conn.prepare("SELECT 1 FROM orders WHERE id = ?") catch return error.DbUnavailable;
    defer conn.finalize(st);
    db.bindInt(st, 1, order_id) catch return error.DbUnavailable;
    return switch (db.c.sqlite3_step(st)) {
        db.c.SQLITE_ROW => true,
        db.c.SQLITE_DONE => false,
        else => error.DbUnavailable,
    };
}

// ── Pruebas (rojo: fallan sin las guardas, verde: pasan con ellas) ─────

fn setup() !db.Connection {
    const conn = try db.Connection.open(std.testing.allocator, ":memory:");
    var migrator = db.Migrator.init(std.testing.allocator);
    try migrator.migrate(conn, &db.runtime_schema);
    // 501 = orden de trabajo; 502 = sin reportes; 999 no existe.
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (501, 'p', 'prueba avance', 'running', 1000)");
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (502, 'p', 'sin reportes', 'running', 1000)");
    return conn;
}

test "CK-COMP-015: el CAS correcto avanza la secuencia y la lectura trae lo último" {
    var conn = try setup();
    defer conn.close();

    var stale: i64 = -1;
    const s1 = try writeProgress(std.testing.allocator, conn, 501, 0, "todo", "arrancado", "agent", &stale);
    try std.testing.expectEqual(@as(i64, 1), s1);
    const s2 = try writeProgress(std.testing.allocator, conn, 501, 1, "in_progress", "voy por el módulo", "agent", &stale);
    try std.testing.expectEqual(@as(i64, 2), s2);

    var p = (try readProgress(std.testing.allocator, conn, 501)) orelse return error.ShouldHave;
    defer p.deinit();
    try std.testing.expectEqualStrings("in_progress", p.state);
    try std.testing.expectEqualStrings("voy por el módulo", p.note);
    try std.testing.expectEqualStrings("agent", p.author);
    try std.testing.expectEqual(@as(i64, 2), p.seq);
}

test "CK-COMP-015: el reporte viejo se descarta con StaleProgress y no escribe" {
    var conn = try setup();
    defer conn.close();

    _ = try writeProgress(std.testing.allocator, conn, 501, 0, "todo", "arrancado", "agent", null);
    _ = try writeProgress(std.testing.allocator, conn, 501, 1, "in_progress", "voy", "agent", null);

    // Un reporte secuenciado sobre la versión 1 (ya caducado: la fila está en 2).
    var stale: i64 = -1;
    try std.testing.expectError(error.StaleProgress, writeProgress(std.testing.allocator, conn, 501, 1, "done", "listo (tarde)", "agent", &stale));
    try std.testing.expectEqual(@as(i64, 2), stale);

    // Nada cambió: la fila sigue siendo la segunda reporte.
    var p = (try readProgress(std.testing.allocator, conn, 501)) orelse return error.ShouldHave;
    defer p.deinit();
    try std.testing.expectEqualStrings("in_progress", p.state);
    try std.testing.expectEqualStrings("voy", p.note);
    try std.testing.expectEqual(@as(i64, 2), p.seq);
}

test "CK-COMP-015: el agente no pisa la nota del humano (pero puede avanzar el estado)" {
    var conn = try setup();
    defer conn.close();

    _ = try writeProgress(std.testing.allocator, conn, 501, 0, "todo", "reviso el plan", "human", null);

    // El agente SIN seq al día ya no escribe (descuento de reportes viejos).
    // El agente CON seq al día que quiere cambiar la nota: rechazado.
    var stale: i64 = -1;
    try std.testing.expectError(error.StaleProgress, writeProgress(std.testing.allocator, conn, 501, 2, "in_progress", "mi nota", "agent", &stale));
    try std.testing.expectEqual(@as(i64, 1), stale);
    try std.testing.expectError(error.HumanNoteProtected, writeProgress(std.testing.allocator, conn, 501, 1, "done", "otra nota diferente", "agent", &stale));

    // La fila queda como la dejó el humano.
    {
        var p = (try readProgress(std.testing.allocator, conn, 501)) orelse return error.ShouldHave;
        defer p.deinit();
        try std.testing.expectEqualStrings("reviso el plan", p.note);
        try std.testing.expectEqualStrings("human", p.author);
        try std.testing.expectEqual(@as(i64, 1), p.seq);
    }

    // El agente puede AVANZAR el estado dejando la nota del humano intacta.
    const s = try writeProgress(std.testing.allocator, conn, 501, 1, "in_review", "reviso el plan", "agent", null);
    try std.testing.expectEqual(@as(i64, 2), s);
    var p = (try readProgress(std.testing.allocator, conn, 501)) orelse return error.ShouldHave;
    defer p.deinit();
    try std.testing.expectEqualStrings("in_review", p.state);
    try std.testing.expectEqualStrings("reviso el plan", p.note);
    try std.testing.expectEqualStrings("human", p.author);
    try std.testing.expectError(error.HumanNoteProtected, writeProgress(std.testing.allocator, conn, 501, 2, "done", "segundo intento", "agent", null));
}

test "CK-COMP-015: el humano siempre puede escribir" {
    var conn = try setup();
    defer conn.close();

    _ = try writeProgress(std.testing.allocator, conn, 501, 0, "in_progress", "nota del agente", "agent", null);
    const s = try writeProgress(std.testing.allocator, conn, 501, 1, "done", "cierre humano con su propia nota", "human", null);
    try std.testing.expectEqual(@as(i64, 2), s);

    var p = (try readProgress(std.testing.allocator, conn, 501)) orelse return error.ShouldHave;
    defer p.deinit();
    try std.testing.expectEqualStrings("cierre humano con su propia nota", p.note);
    try std.testing.expectEqualStrings("human", p.author);
    try std.testing.expectEqualStrings("done", p.state);
}

test "CK-COMP-015: la nota mayor de 2 KiB se rechaza sin escribir" {
    var conn = try setup();
    defer conn.close();

    const exacta = [_]u8{'x'} ** MAX_NOTE_BYTES; // 2048: cabe
    const s = try writeProgress(std.testing.allocator, conn, 501, 0, "todo", &exacta, "agent", null);
    try std.testing.expectEqual(@as(i64, 1), s);

    const excedida = [_]u8{'x'} ** (MAX_NOTE_BYTES + 1); // 2049: no cabe
    try std.testing.expectError(error.NoteTooLarge, writeProgress(std.testing.allocator, conn, 501, 1, "todo", &excedida, "agent", null));

    // La fila quedó en la aceptada, sin la excedida.
    var p = (try readProgress(std.testing.allocator, conn, 501)) orelse return error.ShouldHave;
    defer p.deinit();
    try std.testing.expectEqual(@as(usize, MAX_NOTE_BYTES), p.note.len);
    try std.testing.expectEqual(@as(i64, 1), p.seq);
}

test "CK-COMP-015: estado y autor inválidos se rechazan sin escribir" {
    var conn = try setup();
    defer conn.close();

    try std.testing.expectError(error.InvalidState, writeProgress(std.testing.allocator, conn, 501, 0, "cancelado", "n", "agent", null));
    try std.testing.expectError(error.InvalidAuthor, writeProgress(std.testing.allocator, conn, 501, 0, "todo", "n", "bot", null));

    // Nada se escribió.
    try std.testing.expectEqual(@as(?Progress, null), try readProgress(std.testing.allocator, conn, 501));
}

test "CK-COMP-015: sin reporte la lectura da null e insertar exige expected_seq 0" {
    var conn = try setup();
    defer conn.close();

    try std.testing.expectEqual(@as(?Progress, null), try readProgress(std.testing.allocator, conn, 502));

    // Sin fila, expected_seq distinto de 0 es un reporte imposible: se descarta.
    var stale: i64 = -1;
    try std.testing.expectError(error.StaleProgress, writeProgress(std.testing.allocator, conn, 502, 3, "todo", "n", "agent", &stale));
    try std.testing.expectEqual(@as(i64, 0), stale);
    try std.testing.expectEqual(@as(?Progress, null), try readProgress(std.testing.allocator, conn, 502));
}

test "CK-COMP-015: escribir sobre una orden inexistente da OrderNotFound" {
    var conn = try setup();
    defer conn.close();

    var stale: i64 = -1;
    try std.testing.expectError(error.OrderNotFound, writeProgress(std.testing.allocator, conn, 999, 0, "todo", "n", "agent", &stale));
    try std.testing.expectEqual(@as(?Progress, null), try readProgress(std.testing.allocator, conn, 999));
}

test "CK-COMP-015 db migration upgrades previous schema and enforces byte and enum constraints" {
    var conn = try db.Connection.open(std.testing.allocator, ":memory:");
    defer conn.close();
    const migrator = db.Migrator.init(std.testing.allocator);
    // V49 (índice 48) crea order_progress: índice fijo, no «la última».
    try migrator.migrate(conn, db.runtime_schema[0..48]);
    try std.testing.expectEqual(@as(i32, 48), try conn.getUserVersion());
    try std.testing.expectError(error.PrepareFailed, conn.prepare("SELECT seq FROM order_progress"));
    try conn.exec("INSERT INTO orders (id,project_id,user_prompt,status,created_at) VALUES (501,'p','preservada','running',1)");
    try migrator.migrate(conn, &db.runtime_schema);
    try migrator.migrate(conn, &db.runtime_schema);
    try std.testing.expectEqual(@as(i32, db.runtime_schema.len), try conn.getUserVersion());
    _ = try writeProgress(std.testing.allocator, conn, 501, 0, "todo", "á", "human", null);
    try std.testing.expectError(error.ExecFailed, conn.exec("UPDATE order_progress SET state='bad'"));
    try std.testing.expectError(error.ExecFailed, conn.exec("UPDATE order_progress SET author='bot'"));
    // 1025 two-byte characters are under 2048 characters but over 2048 bytes.
    const large = "á" ** 1025;
    const stmt = try conn.prepare("UPDATE order_progress SET note=? WHERE order_id=501");
    defer conn.finalize(stmt);
    try db.bindText(stmt, 1, large);
    try std.testing.expectEqual(db.c.SQLITE_CONSTRAINT, db.c.sqlite3_step(stmt));
    try std.testing.expectError(error.InvalidSequence, writeProgress(std.testing.allocator, conn, 501, -1, "todo", "", "agent", null));
    try std.testing.expectError(error.InvalidSequence, writeProgress(std.testing.allocator, conn, 501, std.math.maxInt(i64), "todo", "", "agent", null));
    var p = (try readProgress(std.testing.allocator, conn, 501)).?;
    defer p.deinit();
    try std.testing.expectEqualStrings("á", p.note);
    try std.testing.expectEqual(@as(i64, 1), p.seq);
}
