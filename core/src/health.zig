// core/src/health.zig — Métrica de salud por modelo/proveedor (HEALTH-01 & S2-5).
//
// Registra el resultado de cada llamada real de chat (y de los `health probe`
// explícitos) en catalog.db (tabla model_health, 02-ARQUITECTURA.md §6.1).
const std = @import("std");
const db = @import("db.zig");

/// Resultado clasificado de una llamada.
pub const Status = enum {
    ok,
    empty, // 2xx pero sin contenido extraíble
    auth_failed, // 401/403
    /// 403 con cuerpo FreeTierError — el modelo gratuito solo se
    /// sirve desde la CLI del fabricante (OpenCode Zen). NO es una clave
    /// rechazada y por eso se cuenta aparte de auth_failed.
    free_tier_cli_only,
    quota, // 402
    rate_limited, // 429
    not_found, // 404
    timeout, // deadline por llamada agotado
    err, // otro fallo

    pub fn toString(self: Status) []const u8 {
        return switch (self) {
            .ok => "ok",
            .empty => "empty",
            .auth_failed => "auth_failed",
            .free_tier_cli_only => "free_tier_cli_only",
            .quota => "quota",
            .rate_limited => "rate_limited",
            .not_found => "not_found",
            .timeout => "timeout",
            .err => "error",
        };
    }
};

pub fn classifyError(e: anyerror) Status {
    return switch (e) {
        error.AuthFailed => .auth_failed,
        error.QuotaExceeded => .quota,
        error.RateLimited => .rate_limited,
        error.ModelNotFound => .not_found,
        error.Timeout => .timeout,
        else => .err,
    };
}

/// FREE-TIER-CLI: un 403 cuyo cuerpo trae FreeTierError NO es la
/// clave rechazada: es la pasarela HTTP diciendo que ese modelo gratuito solo
/// se sirve desde la CLI del fabricante — «OpenCode's free tier can only be
/// used from within OpenCode». El diagnóstico HTTP (Diagnostic del adaptador,
/// ya recortado y redactado) permite separarlo de auth_failed sin releer el
/// cuerpo: el marcador FreeTierError es estable en la API de OpenCode Zen.
pub fn classifyHttpFailure(e: anyerror, http_status: ?u16, body: []const u8) Status {
    if (e == error.AuthFailed and http_status == 403 and isFreeTierCliOnlyBody(body)) return .free_tier_cli_only;
    return classifyError(e);
}

/// El extracto del cuerpo (Diagnostic.message()) declara el tipo FreeTierError.
pub fn isFreeTierCliOnlyBody(body: []const u8) bool {
    return std.mem.indexOf(u8, body, "FreeTierError") != null;
}

pub fn reliabilityFromCounts(ok_count: i64, fail_count: i64) f64 {
    const ok: f64 = @floatFromInt(@max(ok_count, 0));
    const fail: f64 = @floatFromInt(@max(fail_count, 0));
    return (ok + 2.0) / (ok + fail + 2.0);
}

pub fn nowSeconds(conn: db.Connection) i64 {
    const stmt = conn.prepare("SELECT strftime('%s','now')") catch return 0;
    defer conn.finalize(stmt);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return 0;
    return db.c.sqlite3_column_int64(stmt, 0);
}

pub fn nowMillis(conn: db.Connection) i64 {
    const stmt = conn.prepare("SELECT CAST(strftime('%s','now') AS INTEGER) * 1000") catch return 0;
    defer conn.finalize(stmt);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return 0;
    return db.c.sqlite3_column_int64(stmt, 0);
}

/// Registra (upsert) la salud de un model_id en model_health.
///
/// Compatibilidad: sin etiqueta de clave, la fila cae en el cajón anónimo
/// (`key_label = ''`), que es donde viven todos los registros anteriores a H8
/// y los caminos que no saben con qué clave se llamó (sondeos manuales, tests).
pub fn recordHealth(conn: db.Connection, model_id: []const u8, status: Status) db.DbError!void {
    return recordHealthForKey(conn, model_id, "", status);
}

/// H8 — la salud se atribuye a la CLAVE que hizo la llamada, no solo al modelo.
///
/// Un 401 dice «esta clave no cubre este modelo» y un 429 dice «a esta clave se
/// le acabó la cuota». Ninguno de los dos dice nada del modelo en sí. Mientras
/// las tres claves de Gemini del usuario compartían fila, un `auth_failed` de
/// la degradada bajaba el modelo también para las dos de pago, y en el peor
/// caso lo quemaba para siempre.
pub fn recordHealthForKey(conn: db.Connection, model_id: []const u8, key_label: []const u8, status: Status) db.DbError!void {
    const ok_inc: i64 = if (status == .ok) 1 else 0;
    const err_inc: i64 = if (status == .ok) 0 else 1;
    const timeout_inc: i64 = if (status == .timeout) 1 else 0;
    const now = nowSeconds(conn);
    const err_kind_str: ?[]const u8 = if (status == .ok) null else status.toString();

    const stmt = try conn.prepare(
        \\INSERT INTO model_health (model_id, key_label, ok_count, err_count, timeout_count, last_ok_at, last_err_at, last_err_kind)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(model_id, key_label) DO UPDATE SET
        \\  ok_count=ok_count+excluded.ok_count,
        \\  err_count=err_count+excluded.err_count,
        \\  timeout_count=timeout_count+excluded.timeout_count,
        \\  last_ok_at=CASE WHEN excluded.ok_count > 0 THEN excluded.last_ok_at ELSE model_health.last_ok_at END,
        \\  last_err_at=CASE WHEN excluded.err_count > 0 THEN excluded.last_err_at ELSE model_health.last_err_at END,
        \\  last_err_kind=CASE WHEN excluded.err_count > 0 THEN excluded.last_err_kind ELSE model_health.last_err_kind END
    );
    defer conn.finalize(stmt);
    try db.bindText(stmt, 1, model_id);
    try db.bindText(stmt, 2, key_label);
    try db.bindInt(stmt, 3, ok_inc);
    try db.bindInt(stmt, 4, err_inc);
    try db.bindInt(stmt, 5, timeout_inc);
    if (status == .ok) {
        try db.bindInt(stmt, 6, now);
        _ = db.c.sqlite3_bind_null(stmt, 7);
        _ = db.c.sqlite3_bind_null(stmt, 8);
    } else {
        _ = db.c.sqlite3_bind_null(stmt, 6);
        try db.bindInt(stmt, 7, now);
        try db.bindText(stmt, 8, err_kind_str.?);
    }
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
}

/// Sobrecarga compatible para invocadores que pasan (provider, model, status, latency_ms).
pub fn record(conn: db.Connection, provider: []const u8, model: []const u8, status: Status, latency_ms: i64) db.DbError!void {
    return recordForKey(conn, provider, model, "", status, latency_ms);
}

/// H8 — misma sobrecarga, con la etiqueta de la cuenta que hizo la llamada.
pub fn recordForKey(conn: db.Connection, provider: []const u8, model: []const u8, key_label: []const u8, status: Status, latency_ms: i64) db.DbError!void {
    _ = latency_ms;
    if (provider.len == 0) {
        return recordHealthForKey(conn, model, key_label, status);
    }
    var buf: [256]u8 = undefined;
    const model_id = std.fmt.bufPrint(&buf, "{s}/{s}", .{ provider, model }) catch model;
    return recordHealthForKey(conn, model_id, key_label, status);
}

pub fn resetProvider(conn: db.Connection, provider: []const u8) void {
    var buf: [256]u8 = undefined;
    const pattern = std.fmt.bufPrint(&buf, "{s}/%", .{provider}) catch return;
    const stmt = conn.prepare("DELETE FROM model_health WHERE model_id LIKE ? OR model_id = ?") catch return;
    defer conn.finalize(stmt);
    db.bindText(stmt, 1, pattern) catch return;
    db.bindText(stmt, 2, provider) catch return;
    _ = db.c.sqlite3_step(stmt);
}

/// fila de model_health copiada de una BD de escenario.
pub const StagedHealthRow = struct {
    model_id: []u8,
    key_label: []u8,
    ok_count: i64,
    err_count: i64,
    timeout_count: i64,
    last_ok_at: ?i64,
    last_err_at: ?i64,
    last_err_kind: ?[]u8,
};

/// crea la tabla model_health en una conexión de escenario
/// (":memory:"). Misma forma que la tabla real para que recordHealthForKey
/// pueda escribir en ella sin tocar la salud real.
pub fn initStaging(conn: db.Connection) db.DbError!void {
    try conn.exec(
        \\CREATE TABLE IF NOT EXISTS model_health (
        \\    model_id TEXT NOT NULL,
        \\    key_label TEXT NOT NULL DEFAULT '',
        \\    ok_count INTEGER NOT NULL DEFAULT 0,
        \\    err_count INTEGER NOT NULL DEFAULT 0,
        \\    timeout_count INTEGER NOT NULL DEFAULT 0,
        \\    last_ok_at INTEGER,
        \\    last_err_at INTEGER,
        \\    last_err_kind TEXT,
        \\    PRIMARY KEY (model_id, key_label)
        \\)
    );
}

/// copia las filas del escenario con memoria del llamador.
pub fn readStagedRows(allocator: std.mem.Allocator, conn: db.Connection) db.DbError![]StagedHealthRow {
    const stmt = try conn.prepare(
        \\SELECT model_id, key_label, ok_count, err_count, timeout_count,
        \\       last_ok_at, last_err_at, last_err_kind
        \\FROM model_health
    );
    defer conn.finalize(stmt);
    var rows = std.ArrayList(StagedHealthRow).empty;
    errdefer {
        for (rows.items) |row| freeStagedRow(allocator, row);
        rows.deinit(allocator);
    }
    while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
        if (db.c.sqlite3_column_text(stmt, 0) == null) continue;
        const model_id = try dupColumn(allocator, stmt, 0);
        errdefer allocator.free(model_id);
        const key_label = try dupColumn(allocator, stmt, 1);
        errdefer allocator.free(key_label);
        const last_err_kind: ?[]u8 = if (db.c.sqlite3_column_type(stmt, 7) == db.c.SQLITE_NULL)
            null
        else
            try dupColumn(allocator, stmt, 7);
        errdefer if (last_err_kind) |kind| allocator.free(kind);
        try rows.append(allocator, .{
            .model_id = model_id,
            .key_label = key_label,
            .ok_count = db.c.sqlite3_column_int64(stmt, 2),
            .err_count = db.c.sqlite3_column_int64(stmt, 3),
            .timeout_count = db.c.sqlite3_column_int64(stmt, 4),
            .last_ok_at = if (db.c.sqlite3_column_type(stmt, 5) == db.c.SQLITE_NULL) null else db.c.sqlite3_column_int64(stmt, 5),
            .last_err_at = if (db.c.sqlite3_column_type(stmt, 6) == db.c.SQLITE_NULL) null else db.c.sqlite3_column_int64(stmt, 6),
            .last_err_kind = last_err_kind,
        });
    }
    return rows.toOwnedSlice(allocator);
}

pub fn freeStagedRows(allocator: std.mem.Allocator, rows: []StagedHealthRow) void {
    for (rows) |row| freeStagedRow(allocator, row);
    if (rows.len > 0) allocator.free(rows);
}

fn freeStagedRow(allocator: std.mem.Allocator, row: StagedHealthRow) void {
    allocator.free(row.model_id);
    allocator.free(row.key_label);
    if (row.last_err_kind) |kind| allocator.free(kind);
}

fn dupColumn(allocator: std.mem.Allocator, stmt: *db.c.sqlite3_stmt, col: c_int) db.DbError![]u8 {
    const ptr = db.c.sqlite3_column_text(stmt, col) orelse return try allocator.dupe(u8, "");
    const len: usize = @intCast(db.c.sqlite3_column_bytes(stmt, col));
    return try allocator.dupe(u8, ptr[0..len]);
}

/// vuelca una fila del escenario a model_health real, con la misma
/// semántica acumulativa que recordHealthForKey.
pub fn mergeStagedRow(conn: db.Connection, row: StagedHealthRow) db.DbError!void {
    const stmt = try conn.prepare(
        \\INSERT INTO model_health (model_id, key_label, ok_count, err_count, timeout_count, last_ok_at, last_err_at, last_err_kind)
        \\VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        \\ON CONFLICT(model_id, key_label) DO UPDATE SET
        \\  ok_count=model_health.ok_count+excluded.ok_count,
        \\  err_count=model_health.err_count+excluded.err_count,
        \\  timeout_count=model_health.timeout_count+excluded.timeout_count,
        \\  last_ok_at=CASE WHEN excluded.ok_count > 0 THEN excluded.last_ok_at ELSE model_health.last_ok_at END,
        \\  last_err_at=CASE WHEN excluded.err_count > 0 THEN excluded.last_err_at ELSE model_health.last_err_at END,
        \\  last_err_kind=CASE WHEN excluded.err_count > 0 THEN excluded.last_err_kind ELSE model_health.last_err_kind END
    );
    defer conn.finalize(stmt);
    try db.bindText(stmt, 1, row.model_id);
    try db.bindText(stmt, 2, row.key_label);
    try db.bindInt(stmt, 3, row.ok_count);
    try db.bindInt(stmt, 4, row.err_count);
    try db.bindInt(stmt, 5, row.timeout_count);
    if (row.last_ok_at) |v| try db.bindInt(stmt, 6, v) else _ = db.c.sqlite3_bind_null(stmt, 6);
    if (row.last_err_at) |v| try db.bindInt(stmt, 7, v) else _ = db.c.sqlite3_bind_null(stmt, 7);
    if (row.last_err_kind) |v| try db.bindText(stmt, 8, v) else _ = db.c.sqlite3_bind_null(stmt, 8);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
}

pub fn summaryJson(allocator: std.mem.Allocator, conn: db.Connection) ![]u8 {
    const stmt = try conn.prepare(
        \\SELECT model_id,
        \\       SUM(COALESCE(ok_count,0)) AS total_ok,
        \\       SUM(COALESCE(err_count,0)) AS total_err,
        \\       SUM(COALESCE(timeout_count,0)) AS total_timeout,
        \\       MAX(last_err_kind)
        \\FROM model_health GROUP BY model_id ORDER BY model_id
    );
    defer conn.finalize(stmt);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginArray();
    while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
        const model_id = std.mem.span(db.c.sqlite3_column_text(stmt, 0));
        const total_ok = db.c.sqlite3_column_int64(stmt, 1);
        const total_err = db.c.sqlite3_column_int64(stmt, 2);
        const total_timeout = db.c.sqlite3_column_int64(stmt, 3);
        try js.beginObject();
        try js.objectField("model_id");
        try js.write(model_id);
        try js.objectField("total_ok");
        try js.write(total_ok);
        try js.objectField("total_err");
        try js.write(total_err);
        try js.objectField("total_timeout");
        try js.write(total_timeout);
        try js.endObject();
    }
    try js.endArray();
    return allocator.dupe(u8, out.written());
}

pub fn listJson(allocator: std.mem.Allocator, conn: db.Connection) ![]u8 {
    const stmt = try conn.prepare(
        \\SELECT model_id, SUM(ok_count), SUM(err_count), SUM(timeout_count), MAX(last_ok_at), MAX(last_err_at), MAX(last_err_kind)
        \\FROM model_health GROUP BY model_id ORDER BY model_id
    );
    defer conn.finalize(stmt);
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginArray();
    while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
        try js.beginObject();
        try js.objectField("model_id");
        try js.write(std.mem.span(db.c.sqlite3_column_text(stmt, 0)));
        try js.objectField("ok_count");
        try js.write(db.c.sqlite3_column_int64(stmt, 1));
        try js.objectField("err_count");
        try js.write(db.c.sqlite3_column_int64(stmt, 2));
        try js.objectField("timeout_count");
        try js.write(db.c.sqlite3_column_int64(stmt, 3));
        const kind_ptr = db.c.sqlite3_column_text(stmt, 6);
        try js.objectField("last_err_kind");
        try js.write(if (kind_ptr != null) std.mem.span(kind_ptr) else "");
        try js.endObject();
    }
    try js.endArray();
    return allocator.dupe(u8, out.written());
}

test "recordHealth and schema" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.catalog_schema);

    try recordHealth(conn, "test-model-1", .ok);
    try recordHealth(conn, "test-model-1", .timeout);

    const stmt = try conn.prepare("SELECT ok_count, err_count, timeout_count, last_err_kind FROM model_health WHERE model_id = ?");
    defer conn.finalize(stmt);
    try db.bindText(stmt, 1, "test-model-1");
    try std.testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);
    try std.testing.expectEqual(@as(i64, 1), db.c.sqlite3_column_int64(stmt, 0));
    try std.testing.expectEqual(@as(i64, 1), db.c.sqlite3_column_int64(stmt, 1));
    try std.testing.expectEqual(@as(i64, 1), db.c.sqlite3_column_int64(stmt, 2));
    const kind_ptr = db.c.sqlite3_column_text(stmt, 3);
    try std.testing.expect(kind_ptr != null);
    try std.testing.expectEqualStrings("timeout", std.mem.span(kind_ptr));
}

test "PRAGMA table_info(model_health) has 8 columns (H8: +key_label) and PRAGMA integrity_check is clean on all 3 databases (S2-5)" {
    const allocator = std.testing.allocator;
    const migrator = db.Migrator.init(allocator);

    // 1. catalog.db
    var catalog_conn = try db.Connection.open(allocator, ":memory:");
    defer catalog_conn.close();
    try migrator.migrate(catalog_conn, &db.catalog_schema);

    const stmt_info = try catalog_conn.prepare("PRAGMA table_info(model_health)");
    defer catalog_conn.finalize(stmt_info);
    var col_count: usize = 0;
    while (db.c.sqlite3_step(stmt_info) == db.c.SQLITE_ROW) : (col_count += 1) {}
    // H8: siete de siempre + `key_label`.
    try std.testing.expectEqual(@as(usize, 8), col_count);

    const stmt_ic1 = try catalog_conn.prepare("PRAGMA integrity_check");
    defer catalog_conn.finalize(stmt_ic1);
    try std.testing.expect(db.c.sqlite3_step(stmt_ic1) == db.c.SQLITE_ROW);
    try std.testing.expectEqualStrings("ok", std.mem.span(db.c.sqlite3_column_text(stmt_ic1, 0)));

    // 2. runtime.db
    var runtime_conn = try db.Connection.open(allocator, ":memory:");
    defer runtime_conn.close();
    try migrator.migrate(runtime_conn, &db.runtime_schema);

    const stmt_ic2 = try runtime_conn.prepare("PRAGMA integrity_check");
    defer runtime_conn.finalize(stmt_ic2);
    try std.testing.expect(db.c.sqlite3_step(stmt_ic2) == db.c.SQLITE_ROW);
    try std.testing.expectEqualStrings("ok", std.mem.span(db.c.sqlite3_column_text(stmt_ic2, 0)));

    // 3. ledger.db
    var ledger_conn = try db.Connection.open(allocator, ":memory:");
    defer ledger_conn.close();
    try migrator.migrate(ledger_conn, &db.ledger_schema);

    const stmt_ic3 = try ledger_conn.prepare("PRAGMA integrity_check");
    defer ledger_conn.finalize(stmt_ic3);
    try std.testing.expect(db.c.sqlite3_step(stmt_ic3) == db.c.SQLITE_ROW);
    try std.testing.expectEqualStrings("ok", std.mem.span(db.c.sqlite3_column_text(stmt_ic3, 0)));
}

test "classifyError maps ModelNotFound to not_found status" {
    try std.testing.expectEqual(Status.not_found, classifyError(error.ModelNotFound));
    try std.testing.expectEqual(Status.auth_failed, classifyError(error.AuthFailed));
    try std.testing.expectEqual(Status.rate_limited, classifyError(error.RateLimited));
    try std.testing.expectEqual(Status.quota, classifyError(error.QuotaExceeded));
    try std.testing.expectEqual(Status.timeout, classifyError(error.Timeout));
    try std.testing.expectEqual(Status.err, classifyError(error.RequestFailed));
    try std.testing.expectEqual(Status.err, classifyError(error.SseParseFailed));
}

test "CK-PRV-012: un 403 con cuerpo FreeTierError no es auth_failed y health lo cuenta aparte" {
    // Cuerpo FIJO: el que devuelve la API de OpenCode Zen al pedir un modelo
    // gratuito fuera de su CLI (recorte: el diagnóstico guarda 200 bytes).
    const body = "{\"type\":\"error\",\"error\":{\"type\":\"FreeTierError\",\"message\":\"OpenCode's free tier can only be used from within OpenCode\"}}";
    try std.testing.expectEqual(Status.free_tier_cli_only, classifyHttpFailure(error.AuthFailed, 403, body));
    try std.testing.expectEqualStrings("free_tier_cli_only", Status.free_tier_cli_only.toString());
    // El mismo 403 SIN el marcador sigue siendo la clave rechazada.
    try std.testing.expectEqual(Status.auth_failed, classifyHttpFailure(error.AuthFailed, 403, "{\"error\":{\"type\":\"AuthenticationError\"}}"));
    // El marcador en un 401 no reclasifica (FreeTierError llega en 403).
    try std.testing.expectEqual(Status.auth_failed, classifyHttpFailure(error.AuthFailed, 401, body));
    // Sin diagnóstico HTTP (clave rechazada localmente) no hay nada que separar.
    try std.testing.expectEqual(Status.auth_failed, classifyHttpFailure(error.AuthFailed, null, body));
    try std.testing.expectEqual(Status.rate_limited, classifyHttpFailure(error.RateLimited, 429, body));
    try std.testing.expect(!isFreeTierCliOnlyBody("{\"error\":{\"message\":\"límite agotado\"}}"));

    // …y el registro de salud conserva el motivo propio: last_err_kind distinto.
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.catalog_schema);
    try record(conn, "OpenCode", "deepseek-v4.1-flash-free", classifyHttpFailure(error.AuthFailed, 403, body), 0);
    const stmt = try conn.prepare("SELECT last_err_kind, err_count FROM model_health WHERE model_id='OpenCode/deepseek-v4.1-flash-free'");
    defer conn.finalize(stmt);
    try std.testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);
    try std.testing.expectEqualStrings("free_tier_cli_only", std.mem.span(db.c.sqlite3_column_text(stmt, 0)));
    try std.testing.expectEqual(@as(i64, 1), db.c.sqlite3_column_int64(stmt, 1));
}

test "reliabilityFromCounts: neutral sin datos, hunde por historial, se recupera" {
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), reliabilityFromCounts(0, 0), 0.001);
    try std.testing.expect(reliabilityFromCounts(0, 1) > 0.6);
    try std.testing.expect(reliabilityFromCounts(1, 9) < 0.3);
    try std.testing.expect(reliabilityFromCounts(0, 20) < 0.15);
    try std.testing.expect(reliabilityFromCounts(10, 1) > 0.85);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), reliabilityFromCounts(-5, -5), 0.001);
}

test "record upserts and summary aggregates" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.catalog_schema);

    try recordHealth(conn, "NVIDIA API/kimi-k2.6", .ok);
    try recordHealth(conn, "NVIDIA API/kimi-k2.6", .ok);
    try recordHealth(conn, "OpenCode/deepseek-v4-pro", .auth_failed);

    const list = try listJson(allocator, conn);
    defer allocator.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "\"model_id\":\"NVIDIA API/kimi-k2.6\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "\"last_err_kind\":\"auth_failed\"") != null);
}

test "listJson reflects not_found status for obsolete model IDs" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.catalog_schema);

    try recordHealth(conn, "Cerebras/llama3.1-8b", .not_found);
    const list = try listJson(allocator, conn);
    defer allocator.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "\"last_err_kind\":\"not_found\"") != null);
}

test "resetProvider borra el historial de UN proveedor sin tocar los demas" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.catalog_schema);

    try recordHealth(conn, "OpenCode/deepseek-v4-flash-free", .auth_failed);
    try recordHealth(conn, "NVIDIA API/nemotron-3-ultra", .ok);

    resetProvider(conn, "OpenCode");

    const stmt = try conn.prepare("SELECT COUNT(*) FROM model_health WHERE model_id LIKE 'OpenCode/%'");
    defer conn.finalize(stmt);
    try std.testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);
    try std.testing.expectEqual(@as(i64, 0), db.c.sqlite3_column_int64(stmt, 0));
}
