//! core/src/best_of_n.zig — E5.18 (D-C5): Best-of-N.
//!
//! La orden padre declara `best_of_n` (2..4). Al despachar, el motor crea una
//! orden hija por miembro — proveedores distintos — cada una en su propio
//! space `orden-<padre>-m<k>` (worktree git real), con su pin de ejecutor
//! persistido como `model_selection` ANTES de llamar al despachador, de modo
//! que corre la misma maquinaria (gates, auditoría cruzada por fabricante,
//! eventos, presupuesto) sin tubería paralela. La auditoría NO se fija: la
//! selección automática ya excluye al fabricante del productor (E5.08).
//!
//! Métricas por candidata (filtradas por el order_id de la hija):
//!   - gates:   eventos browser_gate_v1/semantic_gate_v1 con ran:true y
//!              verdict pass/fail;
//!   - pruebas: eventos test_evidence_v1 con ran:true y exit_code 0/!=0;
//!   - veredicto: último task_audit del hijo (pass > unavailable > fail);
//!   - coste:   SUM(usage_records.total_tokens) del hijo (NULL = ninguna
//!              llamada registrada — se ordena como 0; la instalación no
//!              persiste precio por token, así que el coste comparable es
//!              el consumo medido, no un número inventado en dólares);
//!   - tiempo:  ms de pared del despacho de la hija.
//!
//! Ranking determinista (spec): gates → pruebas → veredicto → coste →
//! tiempo. Empate total = mismo rank y lo decide el usuario (ambas
//! seleccionables). El orden de LISTADO es siempre por (rank, member_idx).
//!
//! `best_of_n_choose` aplica el ganador: la hija corre en un worktree que
//! arrancó del mismo HEAD que el de la orden, así que aplicar = copiar al
//! worktree de la orden los archivos que difieren (git diff/ls-files) o, en
//! modo degradado sin git, los archivos declarados (`owns`) que existan.
//! Las candidatas perdedoras quedan archivadas.

const std = @import("std");
const confined_fs = @import("confined_fs.zig");
const db = @import("db.zig");
const health = @import("health.zig");
const headless_adapter = @import("headless_adapter.zig");

pub const MAX_N: usize = 4;
pub const MIN_N: usize = 2;

pub const Member = struct {
    provider: []const u8,
    model: []const u8,

    pub fn deinit(self: *Member, allocator: std.mem.Allocator) void {
        allocator.free(self.provider);
        allocator.free(self.model);
    }
};

/// Lista explícita de miembros (`orders.best_of_n_members`): JSON
/// `[{provider,model},...]`. Null/vacío/inválido → slice vacía (el llamador
/// cae al enjambre). Los duplicados exactos se eliminan; el orden se conserva.
pub fn parseMembersJson(allocator: std.mem.Allocator, raw: ?[]const u8) ![]Member {
    const text = raw orelse return &.{};
    if (text.len == 0) return &.{};
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return &.{};
    defer parsed.deinit();
    if (parsed.value != .array) return &.{};
    var list = std.ArrayList(Member).empty;
    errdefer {
        for (list.items) |*m| m.deinit(allocator);
        list.deinit(allocator);
    }
    for (parsed.value.array.items) |item| {
        if (item != .object) continue;
        const pv = item.object.get("provider") orelse continue;
        const mv = item.object.get("model") orelse continue;
        if (pv != .string or mv != .string) continue;
        if (pv.string.len == 0 or mv.string.len == 0) continue;
        try list.append(allocator, .{
            .provider = try allocator.dupe(u8, pv.string),
            .model = try allocator.dupe(u8, mv.string),
        });
    }
    return list.toOwnedSlice(allocator);
}

/// De la lista dada devuelve hasta `n` miembros con PROVEEDOR distinto
/// (primera aparición de cada proveedor, orden de entrada conservado).
/// Devuelve una vista de `members` (sin clonar — memoria del llamador).
pub fn distinctProviders(members: []const Member, n: usize, out: []Member) usize {
    var count: usize = 0;
    for (members) |m| {
        if (count >= n) break;
        var dup = false;
        for (out[0..count]) |prev| {
            if (std.ascii.eqlIgnoreCase(prev.provider, m.provider)) {
                dup = true;
                break;
            }
        }
        if (dup) continue;
        out[count] = m;
        count += 1;
    }
    return count;
}

pub const Verdict = enum(u8) {
    none = 0,
    fail = 1,
    unavailable = 2,
    pass = 3,

    pub fn fromText(s: []const u8) Verdict {
        if (std.ascii.eqlIgnoreCase(s, "pass")) return .pass;
        if (std.ascii.eqlIgnoreCase(s, "unavailable")) return .unavailable;
        if (std.ascii.indexOfIgnoreCase(s, "fail") != null) return .fail;
        return .none;
    }

    pub fn toText(self: Verdict) []const u8 {
        return switch (self) {
            .none => "none",
            .fail => "fail",
            .unavailable => "unavailable",
            .pass => "pass",
        };
    }
};

/// Métricas medibles de una candidata — todo lo que entra al ranking.
pub const Metrics = struct {
    gates_pass: u32 = 0,
    gates_fail: u32 = 0,
    tests_pass: u32 = 0,
    tests_fail: u32 = 0,
    verdict: Verdict = .none,
    /// null = ninguna llamada registrada → se ordena como 0.
    cost_tokens: ?i64 = null,
    elapsed_ms: i64 = 0,
    /// Estado final de la hija (done/failed/…); se informa, no rankea.
    status: []const u8 = "",
};

/// Comparador del ranking determinista (spec E5.18): gates → pruebas →
/// veredicto (pass>unavailable>fail) → coste → tiempo. Devuelve true si `a`
/// es estrictamente mejor que `b`. Estable y total salvo empate completo.
pub fn ranksAbove(a: Metrics, b: Metrics) bool {
    // 1. gates: sin fallos antes que con fallos; a igualdad, más pases.
    if ((a.gates_fail == 0) != (b.gates_fail == 0)) return a.gates_fail == 0;
    if (a.gates_pass != b.gates_pass) return a.gates_pass > b.gates_pass;
    // 2. pruebas: igual regla.
    if ((a.tests_fail == 0) != (b.tests_fail == 0)) return a.tests_fail == 0;
    if (a.tests_pass != b.tests_pass) return a.tests_pass > b.tests_pass;
    // 3. veredicto del auditor: pass > unavailable > fail > none.
    if (@intFromEnum(a.verdict) != @intFromEnum(b.verdict))
        return @intFromEnum(a.verdict) > @intFromEnum(b.verdict);
    // 4. coste: menor primero; null cuenta como 0 (sin consumo registrado).
    const ca = a.cost_tokens orelse 0;
    const cb = b.cost_tokens orelse 0;
    if (ca != cb) return ca < cb;
    // 5. tiempo: menor primero.
    return a.elapsed_ms < b.elapsed_ms;
}

/// Asigna rank por competición (1,1,3): empate total = mismo número.
/// `items` ordenado por (ranksAbove desc, member_idx asc) — el rank se
/// escribe en el campo `rank` de cada candidata.
pub fn assignRanks(items: []CandidateRow) void {
    for (items, 0..) |*c, i| {
        if (i == 0) {
            c.rank = 1;
            continue;
        }
        const prev = items[i - 1];
        const tied = !ranksAbove(c.metrics, prev.metrics) and !ranksAbove(prev.metrics, c.metrics);
        c.rank = if (tied) prev.rank else @intCast(i + 1);
    }
}

// ── Persistencia ──────────────────────────────────────────────────────────

pub const CandidateRow = struct {
    id: i64 = 0,
    parent_order_id: i64,
    member_idx: u32,
    provider: []const u8 = "",
    model: []const u8 = "",
    child_order_id: ?i64 = null,
    space_id: ?i64 = null,
    plan_id: ?i64 = null,
    status: []const u8 = "pending",
    metrics: Metrics = .{},
    rank: ?u32 = null,
    chosen: bool = false,
};

/// Lee la config best_of_n de la orden (0 = apagado). Devuelve también el
/// JSON de miembros explícitos si existe (slice owned por `allocator`).
pub fn orderConfig(conn: db.Connection, allocator: std.mem.Allocator, order_id: i64) struct { n: u32, members_json: ?[]const u8 } {
    const stmt = conn.prepare("SELECT best_of_n, best_of_n_members FROM orders WHERE id = ?") catch return .{ .n = 0, .members_json = null };
    defer conn.finalize(stmt);
    db.bindInt(stmt, 1, order_id) catch return .{ .n = 0, .members_json = null };
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return .{ .n = 0, .members_json = null };
    const n_i64 = db.c.sqlite3_column_int64(stmt, 0);
    var mj: ?[]const u8 = null;
    if (db.c.sqlite3_column_type(stmt, 1) != db.c.SQLITE_NULL) {
        const p = std.mem.span(db.c.sqlite3_column_text(stmt, 1));
        mj = allocator.dupe(u8, p) catch null;
    }
    const n: u32 = if (n_i64 < 0) 0 else @intCast(@min(n_i64, 99));
    return .{ .n = n, .members_json = mj };
}

pub fn insertCandidate(conn: db.Connection, parent_order_id: i64, idx: u32, m: Member) !i64 {
    const stmt = try conn.prepare(
        "INSERT INTO best_of_n_candidates (parent_order_id, member_idx, provider, model, created_at) VALUES (?, ?, ?, ?, ?)",
    );
    defer conn.finalize(stmt);
    try db.bindInt(stmt, 1, parent_order_id);
    try db.bindInt(stmt, 2, idx);
    try db.bindText(stmt, 3, m.provider);
    try db.bindText(stmt, 4, m.model);
    try db.bindInt(stmt, 5, health.nowSeconds(conn));
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
    return db.c.sqlite3_last_insert_rowid(conn.db);
}

fn bindIntOpt(stmt: *db.c.sqlite3_stmt, idx: c_int, value: ?i64) db.DbError!void {
    if (value) |v| return db.bindInt(stmt, idx, v);
    if (db.c.sqlite3_bind_null(stmt, idx) != db.c.SQLITE_OK) return error.BindFailed;
}

/// Actualiza el resultado de la candidata tras su despacho.
pub fn updateResult(conn: db.Connection, cand_id: i64, child_order_id: ?i64, space_id: ?i64, plan_id: ?i64, status: []const u8, m: Metrics) !void {
    const stmt = try conn.prepare(
        "UPDATE best_of_n_candidates SET child_order_id = ?, space_id = ?, plan_id = ?, status = ?, gates_pass = ?, gates_fail = ?, tests_pass = ?, tests_fail = ?, audit_verdict = ?, cost_tokens = ?, elapsed_ms = ? WHERE id = ?",
    );
    defer conn.finalize(stmt);
    try bindIntOpt(stmt, 1, child_order_id);
    try bindIntOpt(stmt, 2, space_id);
    try bindIntOpt(stmt, 3, plan_id);
    try db.bindText(stmt, 4, status);
    try db.bindInt(stmt, 5, m.gates_pass);
    try db.bindInt(stmt, 6, m.gates_fail);
    try db.bindInt(stmt, 7, m.tests_pass);
    try db.bindInt(stmt, 8, m.tests_fail);
    try db.bindText(stmt, 9, m.verdict.toText());
    if (m.cost_tokens) |c| {
        try db.bindInt(stmt, 10, c);
    } else {
        _ = db.c.sqlite3_bind_null(stmt, 10);
    }
    try db.bindInt(stmt, 11, m.elapsed_ms);
    try db.bindInt(stmt, 12, cand_id);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
}

pub fn setRank(conn: db.Connection, cand_id: i64, rank: u32) void {
    const stmt = conn.prepare("UPDATE best_of_n_candidates SET rank = ? WHERE id = ?") catch return;
    defer conn.finalize(stmt);
    db.bindInt(stmt, 1, rank) catch return;
    db.bindInt(stmt, 2, cand_id) catch return;
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return;
}

pub fn setChosen(conn: db.Connection, cand_id: i64) void {
    const stmt = conn.prepare("UPDATE best_of_n_candidates SET chosen = 1 WHERE id = ?") catch return;
    defer conn.finalize(stmt);
    db.bindInt(stmt, 1, cand_id) catch return;
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return;
}

/// Lista las candidatas de la orden padre, orden de inserción.
pub fn listByParent(conn: db.Connection, allocator: std.mem.Allocator, parent_order_id: i64) ![]CandidateRow {
    const stmt = try conn.prepare(
        "SELECT id, member_idx, provider, model, child_order_id, space_id, plan_id, status, gates_pass, gates_fail, tests_pass, tests_fail, audit_verdict, cost_tokens, elapsed_ms, rank, chosen FROM best_of_n_candidates WHERE parent_order_id = ? ORDER BY member_idx ASC",
    );
    defer conn.finalize(stmt);
    try db.bindInt(stmt, 1, parent_order_id);
    var list = std.ArrayList(CandidateRow).empty;
    errdefer {
        for (list.items) |*c| freeCandidateStrings(allocator, c);
        list.deinit(allocator);
    }
    while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
        var c = CandidateRow{
            .id = db.c.sqlite3_column_int64(stmt, 0),
            .parent_order_id = parent_order_id,
            .member_idx = @intCast(@max(0, db.c.sqlite3_column_int64(stmt, 1))),
            .provider = try dupText(allocator, stmt, 2),
            .model = try dupText(allocator, stmt, 3),
            .child_order_id = colIntOpt(stmt, 4),
            .space_id = colIntOpt(stmt, 5),
            .plan_id = colIntOpt(stmt, 6),
            .status = try dupText(allocator, stmt, 7),
            .metrics = .{
                .gates_pass = @intCast(@max(0, db.c.sqlite3_column_int(stmt, 8))),
                .gates_fail = @intCast(@max(0, db.c.sqlite3_column_int(stmt, 9))),
                .tests_pass = @intCast(@max(0, db.c.sqlite3_column_int(stmt, 10))),
                .tests_fail = @intCast(@max(0, db.c.sqlite3_column_int(stmt, 11))),
                .verdict = .none,
                .cost_tokens = if (db.c.sqlite3_column_type(stmt, 13) == db.c.SQLITE_NULL) null else db.c.sqlite3_column_int64(stmt, 13),
                .elapsed_ms = db.c.sqlite3_column_int64(stmt, 14),
                .status = "",
            },
        };
        if (db.c.sqlite3_column_type(stmt, 12) != db.c.SQLITE_NULL)
            c.metrics.verdict = Verdict.fromText(std.mem.span(db.c.sqlite3_column_text(stmt, 12)));
        if (db.c.sqlite3_column_type(stmt, 15) != db.c.SQLITE_NULL)
            c.rank = @intCast(@max(0, db.c.sqlite3_column_int64(stmt, 15)));
        c.chosen = db.c.sqlite3_column_int(stmt, 16) != 0;
        c.metrics.status = c.status;
        try list.append(allocator, c);
    }
    return list.toOwnedSlice(allocator);
}

pub fn freeCandidateStrings(allocator: std.mem.Allocator, c: *CandidateRow) void {
    allocator.free(c.provider);
    allocator.free(c.model);
    allocator.free(c.status);
}

pub fn freeCandidateList(allocator: std.mem.Allocator, list: []CandidateRow) void {
    for (list) |*c| freeCandidateStrings(allocator, c);
    allocator.free(list);
}

fn dupText(allocator: std.mem.Allocator, stmt: *db.c.sqlite3_stmt, col: c_int) ![]const u8 {
    if (db.c.sqlite3_column_type(stmt, col) == db.c.SQLITE_NULL) return "";
    const p = db.c.sqlite3_column_text(stmt, col);
    if (p == null) return "";
    return allocator.dupe(u8, std.mem.span(@as([*:0]const u8, @ptrCast(p))));
}

fn colIntOpt(stmt: *db.c.sqlite3_stmt, col: c_int) ?i64 {
    if (db.c.sqlite3_column_type(stmt, col) == db.c.SQLITE_NULL) return null;
    const v = db.c.sqlite3_column_int64(stmt, col);
    return if (v == 0) null else v;
}

// ── Métricas por orden hija ───────────────────────────────────────────────

fn countEvents(conn: db.Connection, order_id: i64, kinds: []const []const u8, needle: []const u8, exclude: []const u8) u32 {
    // kinds es corto (1-2); construir el IN(...) con binds.
    var sql_buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&sql_buf);
    w.print("SELECT COUNT(*) FROM events WHERE order_id = ? AND kind IN (", .{}) catch return 0;
    for (kinds, 0..) |_, i| {
        if (i > 0) w.print(",", .{}) catch return 0;
        w.print("?", .{}) catch return 0;
    }
    w.print(") AND payload_json LIKE ?", .{}) catch return 0;
    if (exclude.len > 0) w.print(" AND payload_json NOT LIKE ?", .{}) catch return 0;
    const stmt = conn.prepare(w.buffered()) catch return 0;
    defer conn.finalize(stmt);
    db.bindInt(stmt, 1, order_id) catch return 0;
    var col: c_int = 2;
    for (kinds) |k| {
        db.bindText(stmt, col, k) catch return 0;
        col += 1;
    }
    db.bindText(stmt, col, needle) catch return 0;
    if (exclude.len > 0) {
        col += 1;
        db.bindText(stmt, col, exclude) catch return 0;
    }
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return 0;
    return @intCast(@max(0, db.c.sqlite3_column_int(stmt, 0)));
}

/// Recoge las métricas de la candidata desde su propio order_id (la hija).
/// `status` viene del estado terminal de la fila orders del hijo.
pub fn collectMetrics(conn: db.Connection, child_order_id: i64, elapsed_ms: i64) Metrics {
    const gate_kinds = [_][]const u8{ "browser_gate_v1", "semantic_gate_v1" };
    const test_kinds = [_][]const u8{"test_evidence_v1"};
    var m = Metrics{
        .gates_pass = countEvents(conn, child_order_id, &gate_kinds, "%\"ran\":true%\"verdict\":\"pass\"%", ""),
        .gates_fail = countEvents(conn, child_order_id, &gate_kinds, "%\"ran\":true%\"verdict\":\"fail\"%", ""),
        .tests_pass = countEvents(conn, child_order_id, &test_kinds, "%\"ran\":true%\"exit_code\":0%\"timed_out\":false%", ""),
        .elapsed_ms = elapsed_ms,
    };
    // pruebas fallidas: corrieron (ran:true) y NO son el patrón de pase.
    m.tests_fail = countEvents(conn, child_order_id, &test_kinds, "%\"ran\":true%", "%\"exit_code\":0%\"timed_out\":false%");
    // veredicto: el task_audit más reciente del hijo; si no hay ninguno pero
    // sí un task_audit_unavailable_v1, el veredicto es unavailable.
    if (conn.prepare("SELECT payload_json FROM events WHERE order_id = ? AND kind = 'task_audit' ORDER BY id DESC LIMIT 1") catch null) |stmt| {
        defer conn.finalize(stmt);
        db.bindInt(stmt, 1, child_order_id) catch {};
        if (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            const p = db.c.sqlite3_column_text(stmt, 0);
            if (p != null) {
                const txt = std.mem.span(@as([*:0]const u8, @ptrCast(p)));
                if (extractJsonString(txt, "verdict")) |v| m.verdict = Verdict.fromText(v);
            }
        }
    }
    if (m.verdict == .none) {
        const una_kinds = [_][]const u8{"task_audit_unavailable_v1"};
        if (countEvents(conn, child_order_id, &una_kinds, "%", "") > 0) m.verdict = .unavailable;
    }
    // coste: SUM de tokens sobre las filas de uso del hijo; NULL si ninguna.
    if (conn.prepare("SELECT SUM(total_tokens) FROM usage_records WHERE order_id = ?") catch null) |stmt| {
        defer conn.finalize(stmt);
        db.bindInt(stmt, 1, child_order_id) catch {};
        if (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW and db.c.sqlite3_column_type(stmt, 0) != db.c.SQLITE_NULL)
            m.cost_tokens = db.c.sqlite3_column_int64(stmt, 0);
    }
    return m;
}

/// Mini-extractor: `"clave":"valor"` — las métricas no necesitan un parser
/// completo; el valor buscado viene escrito por el propio motor.
fn extractJsonString(json: []const u8, key: []const u8) ?[]const u8 {
    var buf: [96]u8 = undefined;
    if (key.len + 4 > buf.len) return null;
    const needle = std.fmt.bufPrint(&buf, "\"{s}\":\"", .{key}) catch return null;
    const at = std.mem.indexOf(u8, json, needle) orelse return null;
    const start = at + needle.len;
    const end = std.mem.indexOfScalarPos(u8, json, start, '"') orelse return null;
    return json[start..end];
}

/// Estado textual actual de una orden hija (orders.status).
pub fn childStatus(conn: db.Connection, order_id: i64, buf: []u8) []const u8 {
    const stmt = conn.prepare("SELECT status FROM orders WHERE id = ?") catch return "";
    defer conn.finalize(stmt);
    db.bindInt(stmt, 1, order_id) catch return "";
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return "";
    const p = db.c.sqlite3_column_text(stmt, 0);
    if (p == null) return "";
    const s = std.mem.span(@as([*:0]const u8, @ptrCast(p)));
    if (s.len > buf.len) return "";
    @memcpy(buf[0..s.len], s);
    return buf[0..s.len];
}

// ── Aplicar el ganador ────────────────────────────────────────────────────

/// Archivos que difieren en `cand_wt` respecto a su HEAD (worktree git):
/// modificados/añadidos + no rastreados. El slice devuelto lo posee
/// `allocator`; cada entrada es ruta relativa a `cand_wt` con '/'.
///
/// `--relative` + `-- .` acotan la consulta al árbol del space: sin ellos,
/// en un space degradado (sin `.git` propio) `git -C` resuelve el repo
/// ENVOLVENTE y el diff listaría los cambios ajenos de ese repo — medido
/// en la orden #795, cuya candidata m1 enumeró los archivos sucios del
/// repo padre como si fueran suyos.
fn changedFilesGit(allocator: std.mem.Allocator, cand_wt: []const u8) !ChangedSets {
    var copy = std.ArrayList([]const u8).empty;
    errdefer {
        for (copy.items) |p| allocator.free(p);
        copy.deinit(allocator);
    }
    var del = std.ArrayList([]const u8).empty;
    errdefer {
        for (del.items) |p| allocator.free(p);
        del.deinit(allocator);
    }
    // Tracked modificados/añadidos/renombrados contra HEAD.
    {
        const out = try gitCapture(allocator, cand_wt, &.{ "diff", "--name-only", "-z", "--diff-filter=ACMR", "--relative", "HEAD", "--", "." });
        defer allocator.free(out);
        var it = std.mem.splitScalar(u8, out, 0);
        while (it.next()) |p| {
            if (p.len == 0) continue;
            try copy.append(allocator, try allocator.dupe(u8, p));
        }
    }
    // Tracked borrados.
    {
        const out = try gitCapture(allocator, cand_wt, &.{ "diff", "--name-only", "-z", "--diff-filter=D", "--relative", "HEAD", "--", "." });
        defer allocator.free(out);
        var it = std.mem.splitScalar(u8, out, 0);
        while (it.next()) |p| {
            if (p.len == 0) continue;
            try del.append(allocator, try allocator.dupe(u8, p));
        }
    }
    // No rastreados (salidas nuevas del candidato).
    {
        const out = try gitCapture(allocator, cand_wt, &.{ "ls-files", "-z", "--others", "--exclude-standard", "--", "." });
        defer allocator.free(out);
        var it = std.mem.splitScalar(u8, out, 0);
        while (it.next()) |p| {
            if (p.len == 0) continue;
            try copy.append(allocator, try allocator.dupe(u8, p));
        }
    }
    return .{ .copy = try copy.toOwnedSlice(allocator), .del = try del.toOwnedSlice(allocator) };
}

// Enumeración por la API W — misma razón que en c_api.zig: la vía ANSI
// mutila nombres UTF-8. std.Io.Threaded no se usa dentro del host (AV en el
// proceso MSVC); las copias usan los handles de confined_fs.
const FIND_DATA_W = extern struct {
    dwFileAttributes: u32,
    ftCreationTime_dwLowDateTime: u32,
    ftCreationTime_dwHighDateTime: u32,
    ftLastAccessTime_dwLowDateTime: u32,
    ftLastAccessTime_dwHighDateTime: u32,
    ftLastWriteTime_dwLowDateTime: u32,
    ftLastWriteTime_dwHighDateTime: u32,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u16,
    cAlternateFileName: [14]u16,
};

const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;

const FindFirstFileW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindFirstFileW(lpFileName: [*:0]const u16, lpFindFileData: *anyopaque) callconv(.winapi) std.os.windows.HANDLE;
}.FindFirstFileW else @import("providers").posix_files.FindFirstFileW;
const FindNextFileW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindNextFileW(hFindFile: std.os.windows.HANDLE, lpFindFileData: *anyopaque) callconv(.winapi) c_int;
}.FindNextFileW else @import("providers").posix_files.FindNextFileW;
const FindClose = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindClose(hFindFile: std.os.windows.HANDLE) c_int;
}.FindClose else @import("providers").posix_files.FindClose;

/// Nivel recursivo de `walkArtifactDir`: recorre `abs_dir` y añade a `out`
/// cada ARCHIVO como ruta relativa con '/', prefijada por `rel_dir`.
fn walkLevel(allocator: std.mem.Allocator, abs_dir: []const u8, rel_dir: []const u8, out: *std.ArrayList([]const u8)) !void {
    const pattern = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "*", .{abs_dir});
    defer allocator.free(pattern);
    const pattern_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, pattern);
    defer allocator.free(pattern_w);
    var fd: FIND_DATA_W = undefined;
    const h = FindFirstFileW(pattern_w, @ptrCast(&fd));
    if (h == std.os.windows.INVALID_HANDLE_VALUE) return;
    defer _ = FindClose(h);
    while (true) {
        {
            const name_len = std.mem.indexOfScalar(u16, &fd.cFileName, 0) orelse fd.cFileName.len;
            const name = std.unicode.utf16LeToUtf8Alloc(allocator, fd.cFileName[0..name_len]) catch {
                if (FindNextFileW(h, @ptrCast(&fd)) == 0) break;
                continue;
            };
            defer allocator.free(name);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                const abs = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ abs_dir, name });
                defer allocator.free(abs);
                const rel = if (rel_dir.len == 0)
                    try allocator.dupe(u8, name)
                else
                    try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ rel_dir, name });
                defer allocator.free(rel);
                if (fd.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0) {
                    try walkLevel(allocator, abs, rel, out);
                } else {
                    const rel_norm = try allocator.dupe(u8, rel);
                    std.mem.replaceScalar(u8, rel_norm, '\\', '/');
                    try out.append(allocator, rel_norm);
                }
            }
        }
        if (FindNextFileW(h, @ptrCast(&fd)) == 0) break;
    }
}

/// Paseo FS de la carpeta de artefactos (`orden-<hija>`): la lista real de
/// lo que la candidata escribió — determinista, inmune al `.gitignore` del
/// repo envolvente y al estado de git. Sin él, en un repo que ignore
/// `orden-*/` (esta misma base lo hace) la salida quedaría invisible para la
/// tarjeta y para la fusión — medido en la orden #795: la ganadora Cohere
/// había escrito `orden-798/e518_probe.txt` y `files_copied` salió 0.
/// Rutas devueltas con '/' y ya prefijadas (p.ej. "orden-798/x.txt").
/// Una carpeta ausente no es error: devuelve lista vacía.
fn walkArtifactDir(allocator: std.mem.Allocator, cand_wt: []const u8, prefix: []const u8) ![][]const u8 {
    var list = std.ArrayList([]const u8).empty;
    errdefer {
        for (list.items) |p| allocator.free(p);
        list.deinit(allocator);
    }
    const abs = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ cand_wt, prefix });
    defer allocator.free(abs);
    try walkLevel(allocator, abs, prefix, &list);
    return list.toOwnedSlice(allocator);
}

pub const ChangedSets = struct { copy: [][]const u8, del: [][]const u8 };

fn containsPath(items: []const []const u8, p: []const u8) bool {
    for (items) |q| {
        if (std.mem.eql(u8, q, p)) return true;
    }
    return false;
}

/// Versión pública para la tarjeta comparativa (WebUI/MCP): diff git acotado
/// en unión con el paseo FS de `artifact_prefix` (la carpeta `orden-<hija>`).
/// Sin git utilizable devuelve la lista del paseo — si tampoco hay prefijo,
/// null: la UI declara el modo degradado en vez de inventarse una lista.
pub fn changedFiles(allocator: std.mem.Allocator, cand_wt: []const u8, artifact_prefix: ?[]const u8) ?ChangedSets {
    var sets = changedFilesGit(allocator, cand_wt) catch {
        const ap = artifact_prefix orelse return null;
        const walked = walkArtifactDir(allocator, cand_wt, ap) catch return null;
        const empty = allocator.alloc([]const u8, 0) catch {
            for (walked) |p| allocator.free(p);
            allocator.free(walked);
            return null;
        };
        return .{ .copy = walked, .del = empty };
    };
    const ap = artifact_prefix orelse return sets;
    const walked = walkArtifactDir(allocator, cand_wt, ap) catch return sets;
    defer allocator.free(walked); // el contenedor; las cadenas vivas pasan a copy
    var copy = std.ArrayList([]const u8).empty;
    copy.appendSlice(allocator, sets.copy) catch {
        copy.deinit(allocator);
        for (walked) |p| allocator.free(p);
        return sets;
    };
    const base_len = copy.items.len;
    for (walked) |p| {
        if (containsPath(copy.items, p)) {
            allocator.free(p);
            continue;
        }
        copy.append(allocator, p) catch allocator.free(p);
    }
    const merged = copy.toOwnedSlice(allocator) catch {
        for (copy.items[base_len..]) |p| allocator.free(p);
        copy.deinit(allocator);
        return sets;
    };
    allocator.free(sets.copy);
    sets.copy = merged;
    return sets;
}

pub fn freeChangedSets(allocator: std.mem.Allocator, sets: ChangedSets) void {
    for (sets.copy) |p| allocator.free(p);
    for (sets.del) |p| allocator.free(p);
    allocator.free(sets.copy);
    allocator.free(sets.del);
}

fn gitCapture(allocator: std.mem.Allocator, root: []const u8, argv_tail: []const []const u8) ![]const u8 {
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "-C", root });
    try argv.appendSlice(allocator, argv_tail);
    var res = headless_adapter.defaultCapture(allocator, argv.items, null) catch return error.IoFailed;
    defer res.deinit(allocator);
    if (res.exit_code != 0) {
        if (@import("builtin").is_test) std.debug.print("[best_of_n git fixture] exit={d} stderr={s}\n", .{ res.exit_code, res.stderr });
        return error.IoFailed;
    }
    return try allocator.dupe(u8, res.stdout);
}

fn copyInto(source: *const confined_fs.Root, src_rel: []const u8, destination: *const confined_fs.Root, dst_rel: []const u8) !bool {
    destination.copyFile(source, src_rel, dst_rel) catch |e| switch (e) {
        // Declared owns may be absent, allowing the remapped artifact later.
        error.FileNotFound => return false,
        else => return e,
    };
    return true;
}

/// Reanclaje de la carpeta convencional `orden-<id>`: la salida de la
/// candidata vive bajo `orden-<hija>` dentro de su space, pero la vista de
/// artefactos y la verificación de la padre leen `orden-<padre>`.
pub const PathRemap = struct {
    /// Prefijo en la candidata, p.ej. "orden-790" (sin separador).
    from: []const u8,
    /// Prefijo equivalente en la padre, p.ej. "orden-789".
    to: []const u8,
};

/// Si `rel` (forma '\' normalizada) cuelga de `remap.from\`, devuelve la ruta
/// reanclada bajo `remap.to`; si no, una copia de `rel`. Owned por allocator.
fn remapDstRel(allocator: std.mem.Allocator, rel: []const u8, remap: ?PathRemap) ![]const u8 {
    const r = remap orelse return allocator.dupe(u8, rel);
    var buf: [256]u8 = undefined;
    const prefix = std.fmt.bufPrint(&buf, "{s}" ++ std.fs.path.sep_str ++ "", .{r.from}) catch return allocator.dupe(u8, rel);
    if (!std.mem.startsWith(u8, rel, prefix)) return allocator.dupe(u8, rel);
    // USUARIO-NUEVO B (10-nov): `to` vacío = a la raíz del destino (la
    // conversación de DevAgents trabaja en la raíz del proyecto, como Directo).
    if (r.to.len == 0) return allocator.dupe(u8, rel[prefix.len..]);
    return std.fmt.allocPrint(allocator, "{s}{s}", .{ r.to, rel[r.from.len..] });
}

/// Conjunto de destinos ya escritos — evita copiar dos veces la misma ruta
/// cuando el diff git y el paseo FS coinciden (o cuando un `own` declarado y
/// el artefacto envuelto apuntan al mismo destino). Se marca SOLO tras una
/// copia exitosa: si un origen falla, otro equivalente puede seguir
/// intentándolo (own declarado como `orden-<padre>/x` no existe en la
/// candidata, pero `orden-<hija>/x` sí).
const SeenDst = struct {
    items: std.ArrayList([]const u8) = .empty,

    fn deinit(self: *SeenDst, allocator: std.mem.Allocator) void {
        for (self.items.items) |p| allocator.free(p);
        self.items.deinit(allocator);
    }

    fn contains(self: *const SeenDst, dst_rel: []const u8) bool {
        return containsPath(self.items.items, dst_rel);
    }

    fn put(self: *SeenDst, allocator: std.mem.Allocator, dst_rel: []const u8) !void {
        try self.items.append(allocator, try allocator.dupe(u8, dst_rel));
    }
};

fn copyOnce(allocator: std.mem.Allocator, source: *const confined_fs.Root, destination: *const confined_fs.Root, src_rel: []const u8, dst_rel: []const u8, seen: *SeenDst, copied: *u32) !void {
    // También salta los destinos que el llamador excluyó (applyWinnerSkipping).
    if (seen.contains(dst_rel)) return;
    if (!try copyInto(source, src_rel, destination, dst_rel)) return;
    copied.* += 1;
    try seen.put(allocator, dst_rel);
}

/// Aplica el resultado del ganador al worktree de la orden. `owns` son las
/// rutas declaradas por el plan (respaldo cuando la candidata corrió en un
/// space degradado sin git). `remap` reancla `orden-<hija>` → `orden-<padre>`
/// en el destino y habilita el paseo FS de la carpeta de artefactos — la
/// unión que mantiene la fusión correcta aunque el repo envolvente ignore
/// `orden-*/` o el space sea degradado. Devuelve cuántos archivos se
/// copiaron y cuántos se borraron del destino.
pub const Applied = struct { copied: u32, deleted: u32 };

pub fn applyWinner(
    allocator: std.mem.Allocator,
    cand_wt: []const u8,
    dst_wt: []const u8,
    owns: []const []const u8,
    remap: ?PathRemap,
) !Applied {
    return applyWinnerSkipping(allocator, cand_wt, dst_wt, owns, remap, &.{});
}

/// USUARIO-NUEVO B (10-nov): la MISMA fusión, sin tocar los destinos de
/// `skip_dst` (rutas relativas al destino ya reancladas). La delegación de
/// DevAgents la usa para no copiar a la carpeta del proyecto el informe del
/// auditor de cada subtarea, que se queda como evidencia en su worktree.
pub fn applyWinnerSkipping(
    allocator: std.mem.Allocator,
    cand_wt: []const u8,
    dst_wt: []const u8,
    owns: []const []const u8,
    remap: ?PathRemap,
    skip_dst: []const []const u8,
) !Applied {
    var source = try confined_fs.Root.init(allocator, cand_wt);
    defer source.deinit();
    var destination = try confined_fs.createRoot(allocator, dst_wt);
    defer destination.deinit();
    var copied: u32 = 0;
    var deleted: u32 = 0;
    var seen: SeenDst = .{};
    defer seen.deinit(allocator);
    for (skip_dst) |s| {
        const norm = try allocator.dupe(u8, s);
        defer allocator.free(norm);
        std.mem.replaceScalar(u8, norm, '/', std.fs.path.sep);
        try seen.put(allocator, norm);
    }

    if (changedFilesGit(allocator, cand_wt)) |sets| {
        defer {
            for (sets.copy) |p| allocator.free(p);
            for (sets.del) |p| allocator.free(p);
            allocator.free(sets.copy);
            allocator.free(sets.del);
        }
        for (sets.copy) |rel| {
            const norm = try std.fmt.allocPrint(allocator, "{s}", .{rel});
            defer allocator.free(norm);
            std.mem.replaceScalar(u8, norm, '/', std.fs.path.sep);
            const dst_rel = try remapDstRel(allocator, norm, remap);
            defer allocator.free(dst_rel);
            try copyOnce(allocator, &source, &destination, norm, dst_rel, &seen, &copied);
        }
        for (sets.del) |rel| {
            const norm = try std.fmt.allocPrint(allocator, "{s}", .{rel});
            defer allocator.free(norm);
            std.mem.replaceScalar(u8, norm, '/', std.fs.path.sep);
            const dst_rel = try remapDstRel(allocator, norm, remap);
            defer allocator.free(dst_rel);
            destination.removeFile(dst_rel) catch |e| switch (e) {
                error.FileNotFound => continue,
                else => return e,
            };
            deleted += 1;
        }
    } else |_| {
        // Modo degradado (space sin git utilizable): copiar los declarados
        // que existan en su ruta de layout; el envuelto `orden-<hija>` lo
        // cubre el paseo de abajo.
        for (owns) |own0| {
            const rel = try std.fmt.allocPrint(allocator, "{s}", .{own0});
            defer allocator.free(rel);
            std.mem.replaceScalar(u8, rel, '/', std.fs.path.sep);
            const dst_rel = try remapDstRel(allocator, rel, remap);
            defer allocator.free(dst_rel);
            try copyOnce(allocator, &source, &destination, rel, dst_rel, &seen, &copied);
        }
    }

    // Paseo FS de `orden-<hija>`: determinista e inmune a .gitignore. Corre
    // en AMBAS ramas — en git porque la carpeta puede estar ignorada, en
    // degradado porque es la única fuente completa de artefactos.
    if (remap) |r| {
        const walked = try walkArtifactDir(allocator, cand_wt, r.from);
        defer {
            for (walked) |p| allocator.free(p);
            allocator.free(walked);
        }
        for (walked) |src| {
            const norm = try std.fmt.allocPrint(allocator, "{s}", .{src});
            defer allocator.free(norm);
            std.mem.replaceScalar(u8, norm, '/', std.fs.path.sep);
            const dst_rel = try remapDstRel(allocator, norm, remap);
            defer allocator.free(dst_rel);
            try copyOnce(allocator, &source, &destination, norm, dst_rel, &seen, &copied);
        }
    }
    return .{ .copied = copied, .deleted = deleted };
}

// ── Pruebas ───────────────────────────────────────────────────────────────

fn mkMetrics(gates: [2]u32, tests: [2]u32, verdict: Verdict, cost: ?i64, ms: i64) Metrics {
    return .{ .gates_pass = gates[0], .gates_fail = gates[1], .tests_pass = tests[0], .tests_fail = tests[1], .verdict = verdict, .cost_tokens = cost, .elapsed_ms = ms };
}

test "E5.18: ranking determinista — gates, pruebas, veredicto, coste, tiempo" {
    // Orden del spec: gates primero.
    const g_fail = mkMetrics(.{ 2, 1 }, .{ 5, 0 }, .pass, 1, 100);
    const g_ok = mkMetrics(.{ 1, 0 }, .{ 0, 0 }, .none, null, 9000);
    try std.testing.expect(ranksAbove(g_ok, g_fail)); // 0 fails > más pases con 1 fail
    // Pruebas después de gates.
    const t_fail = mkMetrics(.{ 0, 0 }, .{ 3, 1 }, .pass, null, 50);
    const t_ok = mkMetrics(.{ 0, 0 }, .{ 1, 0 }, .none, 5000, 8000);
    try std.testing.expect(ranksAbove(t_ok, t_fail));
    // Veredicto: pass > unavailable > fail > none.
    try std.testing.expect(ranksAbove(mkMetrics(.{ 0, 0 }, .{ 0, 0 }, .pass, null, 9999), mkMetrics(.{ 0, 0 }, .{ 0, 0 }, .unavailable, null, 1)));
    try std.testing.expect(ranksAbove(mkMetrics(.{ 0, 0 }, .{ 0, 0 }, .unavailable, null, 9999), mkMetrics(.{ 0, 0 }, .{ 0, 0 }, .fail, null, 1)));
    try std.testing.expect(ranksAbove(mkMetrics(.{ 0, 0 }, .{ 0, 0 }, .fail, null, 1), mkMetrics(.{ 0, 0 }, .{ 0, 0 }, .none, null, 1)));
    // Coste: null (gratis) cuenta 0 y gana a pago.
    try std.testing.expect(ranksAbove(mkMetrics(.{ 0, 0 }, .{ 0, 0 }, .pass, null, 9999), mkMetrics(.{ 0, 0 }, .{ 0, 0 }, .pass, 50, 1)));
    // Tiempo: desempate final.
    try std.testing.expect(ranksAbove(mkMetrics(.{ 0, 0 }, .{ 0, 0 }, .pass, null, 10), mkMetrics(.{ 0, 0 }, .{ 0, 0 }, .pass, null, 20)));
    // Empate total: ninguno supera al otro.
    const a = mkMetrics(.{ 1, 0 }, .{ 1, 0 }, .pass, null, 10);
    const b = mkMetrics(.{ 1, 0 }, .{ 1, 0 }, .pass, null, 10);
    try std.testing.expect(!ranksAbove(a, b) and !ranksAbove(b, a));
}

test "E5.18: assignRanks da rank de competición (1,1,3)" {
    const allocator = std.testing.allocator;
    _ = allocator;
    var rows = [_]CandidateRow{
        .{ .parent_order_id = 1, .member_idx = 1, .metrics = mkMetrics(.{ 0, 0 }, .{ 0, 0 }, .pass, null, 10) },
        .{ .parent_order_id = 1, .member_idx = 2, .metrics = mkMetrics(.{ 0, 0 }, .{ 0, 0 }, .pass, null, 10) },
        .{ .parent_order_id = 1, .member_idx = 3, .metrics = mkMetrics(.{ 0, 0 }, .{ 0, 0 }, .fail, null, 10) },
    };
    assignRanks(rows[0..]);
    try std.testing.expectEqual(@as(?u32, 1), rows[0].rank);
    try std.testing.expectEqual(@as(?u32, 1), rows[1].rank);
    try std.testing.expectEqual(@as(?u32, 3), rows[2].rank);
}

test "E5.18: distinctProviders conserva orden y quita duplicados de proveedor" {
    const members = [_]Member{
        .{ .provider = "OpenRouter", .model = "a" },
        .{ .provider = "NVIDIA", .model = "b" },
        .{ .provider = "openrouter", .model = "c" }, // duplicado (case-insensitive)
        .{ .provider = "Cohere", .model = "d" },
    };
    var out: [4]Member = undefined;
    const n = distinctProviders(&members, 4, &out);
    try std.testing.expectEqual(@as(usize, 3), n);
    try std.testing.expectEqualStrings("a", out[0].model);
    try std.testing.expectEqualStrings("b", out[1].model);
    try std.testing.expectEqualStrings("d", out[2].model);
    // n < disponibles recorta.
    var out2: [2]Member = undefined;
    try std.testing.expectEqual(@as(usize, 2), distinctProviders(&members, 2, &out2));
}

test "E5.18: parseMembersJson acepta lista y rechaza basura" {
    const allocator = std.testing.allocator;
    const ms = try parseMembersJson(allocator, "[{\"provider\":\"A\",\"model\":\"x\"},{\"provider\":\"B\",\"model\":\"y\"}]");
    defer {
        for (ms) |*m| m.deinit(allocator);
        allocator.free(ms);
    }
    try std.testing.expectEqual(@as(usize, 2), ms.len);
    try std.testing.expectEqualStrings("B", ms[1].provider);
    // Basura → lista vacía (no crash, cae al enjambre).
    const bad = try parseMembersJson(allocator, "{\"no\":1}");
    defer allocator.free(bad);
    try std.testing.expectEqual(@as(usize, 0), bad.len);
    const nulls = try parseMembersJson(allocator, null);
    defer allocator.free(nulls);
    try std.testing.expectEqual(@as(usize, 0), nulls.len);
}

fn openTestDb(allocator: std.mem.Allocator) !db.Connection {
    var conn = try db.Connection.open(allocator, ":memory:");
    errdefer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);
    return conn;
}

test "E5.18: collectMetrics cuenta gates, pruebas, veredicto y coste del hijo" {
    const allocator = std.testing.allocator;
    var conn = try openTestDb(allocator);
    defer conn.close();
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (10, 'p', 'x', 'done', 1)");
    try conn.exec("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (1,'s','semantic_gate_v1','{\"ran\":true,\"verdict\":\"pass\"}',10)");
    try conn.exec("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (2,'s','browser_gate_v1','{\"ran\":true,\"verdict\":\"fail\"}',10)");
    try conn.exec("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (3,'s','test_evidence_v1','{\"ran\":true,\"exit_code\":0,\"timed_out\":false}',10)");
    try conn.exec("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (4,'s','test_evidence_v1','{\"ran\":true,\"exit_code\":3,\"timed_out\":false}',10)");
    try conn.exec("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (5,'s','task_audit','{\"task_id\":\"a1\",\"verdict\":\"pass\"}',10)");
    try conn.exec("INSERT INTO usage_records (order_id, provider, model, total_tokens, timestamp) VALUES (10, 'p', 'm', 250, 100)");
    // Ruido de OTRA orden no contamina.
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (11, 'p', 'y', 'done', 1)");
    try conn.exec("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (6,'s','test_evidence_v1','{\"ran\":true,\"exit_code\":0,\"timed_out\":false}',11)");

    const m = collectMetrics(conn, 10, 1234);
    try std.testing.expectEqual(@as(u32, 1), m.gates_pass);
    try std.testing.expectEqual(@as(u32, 1), m.gates_fail);
    try std.testing.expectEqual(@as(u32, 1), m.tests_pass);
    try std.testing.expectEqual(@as(u32, 1), m.tests_fail);
    try std.testing.expectEqual(Verdict.pass, m.verdict);
    try std.testing.expectEqual(@as(?i64, 250), m.cost_tokens);
    try std.testing.expectEqual(@as(i64, 1234), m.elapsed_ms);
}

test "E5.18: candidates persisten y listan con métricas" {
    const allocator = std.testing.allocator;
    var conn = try openTestDb(allocator);
    defer conn.close();
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'x', 'running', 1)");
    const cid = try insertCandidate(conn, 1, 1, .{ .provider = "A", .model = "m1" });
    try updateResult(conn, cid, 101, 55, 77, "done", .{ .gates_pass = 2, .tests_pass = 3, .verdict = .pass, .elapsed_ms = 42 });
    setRank(conn, cid, 1);
    setChosen(conn, cid);
    const list = try listByParent(conn, allocator, 1);
    defer freeCandidateList(allocator, list);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(@as(?i64, 101), list[0].child_order_id);
    try std.testing.expectEqual(@as(u32, 2), list[0].metrics.gates_pass);
    try std.testing.expectEqual(@as(u32, 3), list[0].metrics.tests_pass);
    try std.testing.expectEqual(Verdict.pass, list[0].metrics.verdict);
    try std.testing.expectEqual(@as(?u32, 1), list[0].rank);
    try std.testing.expect(list[0].chosen);
    try std.testing.expectEqualStrings("done", list[0].status);
}

fn writeT(tmp: *std.testing.TmpDir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |dd| try tmp.dir.createDirPath(std.testing.io, dd);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

/// Ruta absoluta de `<tmp>/<sub>` — los roots que reciben applyWinner y
/// gitCapture. `buf` lo posee el llamador.
fn tmpSub(tmp: *std.testing.TmpDir, buf: []u8, sub: []const u8) ![]const u8 {
    var rb: [4096]u8 = undefined;
    const n = tmp.dir.realPath(std.testing.io, rb[0..]) catch return error.IoFailed;
    return try std.fmt.bufPrint(buf, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ rb[0..n], sub });
}

fn readT(tmp: *std.testing.TmpDir, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    return try tmp.dir.readFileAlloc(std.testing.io, path, allocator, .limited(1 << 20));
}

fn existsT(tmp: *std.testing.TmpDir, path: []const u8) bool {
    _ = tmp.dir.statFile(std.testing.io, path, .{}) catch return false;
    return true;
}

test "E5.18: applyWinner sin git copia solo los owns declarados (modo degradado)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeT(&tmp, "cand" ++ std.fs.path.sep_str ++ "w.txt", "v2-cand");
    try writeT(&tmp, "cand" ++ std.fs.path.sep_str ++ "stray.txt", "no declarado — NO debe copiarse");
    try writeT(&tmp, "dst" ++ std.fs.path.sep_str ++ "w.txt", "v1-base");
    try writeT(&tmp, "dst" ++ std.fs.path.sep_str ++ "keep.txt", "intocable");

    var cand_buf: [4096]u8 = undefined;
    var dst_buf: [4096]u8 = undefined;
    const cand = try tmpSub(&tmp, &cand_buf, "cand");
    const dst = try tmpSub(&tmp, &dst_buf, "dst");

    // Modo degradado REAL: `git init` sin commit → HEAD no nace y
    // `git diff HEAD` falla → applyWinner cae a los owns declarados.
    // (Sin esto el dir dentro del repo respondería con diff vacío a la
    // consulta y la prueba mediría la ruta git, no la degradada.)
    {
        const out = try gitCapture(allocator, cand, &.{"init"});
        defer allocator.free(out);
    }

    const owns = [_][]const u8{ "w.txt", "missing.txt" };
    const r = try applyWinner(allocator, cand, dst, &owns, null);
    try std.testing.expectEqual(@as(u32, 1), r.copied); // missing.txt no existe: falla limpio
    try std.testing.expectEqual(@as(u32, 0), r.deleted);

    const content = try readT(&tmp, allocator, "dst" ++ std.fs.path.sep_str ++ "w.txt");
    defer allocator.free(content);
    try std.testing.expectEqualStrings("v2-cand", content);
    // stray.txt NO cruzó (sin git solo se mueven los declarados).
    try std.testing.expect(!existsT(&tmp, "dst" ++ std.fs.path.sep_str ++ "stray.txt"));
    const keep = try readT(&tmp, allocator, "dst" ++ std.fs.path.sep_str ++ "keep.txt");
    defer allocator.free(keep);
    try std.testing.expectEqualStrings("intocable", keep);
}

test "E5.18: applyWinner con git copia modificados+nuevos y borra eliminados" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Base común: las dos copias arrancan del mismo contenido.
    try writeT(&tmp, "cand" ++ std.fs.path.sep_str ++ "mod.txt", "v1");
    try writeT(&tmp, "cand" ++ std.fs.path.sep_str ++ "del.txt", "borrame");
    try writeT(&tmp, "cand" ++ std.fs.path.sep_str ++ "keep.txt", "igual");
    try writeT(&tmp, "dst" ++ std.fs.path.sep_str ++ "mod.txt", "v1");
    try writeT(&tmp, "dst" ++ std.fs.path.sep_str ++ "del.txt", "borrame");
    try writeT(&tmp, "dst" ++ std.fs.path.sep_str ++ "keep.txt", "igual");

    var cand_buf: [4096]u8 = undefined;
    var dst_buf: [4096]u8 = undefined;
    const cand = try tmpSub(&tmp, &cand_buf, "cand");
    const dst = try tmpSub(&tmp, &dst_buf, "dst");

    // Repo git real en la candidata con la base commiteada.
    {
        const out = try gitCapture(allocator, cand, &.{"init"});
        defer allocator.free(out);
    }
    {
        const out = try gitCapture(allocator, cand, &.{ "add", "-A" });
        defer allocator.free(out);
    }
    {
        const out = try gitCapture(allocator, cand, &.{ "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "base" });
        defer allocator.free(out);
    }
    // La candidata modifica, borra y añade.
    try writeT(&tmp, "cand" ++ std.fs.path.sep_str ++ "mod.txt", "v2");
    try writeT(&tmp, "cand" ++ std.fs.path.sep_str ++ "new.txt", "nuevo");
    try tmp.dir.deleteFile(std.testing.io, "cand" ++ std.fs.path.sep_str ++ "del.txt");

    const r = try applyWinner(allocator, cand, dst, &.{}, null);
    try std.testing.expectEqual(@as(u32, 2), r.copied); // mod.txt + new.txt
    try std.testing.expectEqual(@as(u32, 1), r.deleted); // del.txt

    const mod_dst = try readT(&tmp, allocator, "dst" ++ std.fs.path.sep_str ++ "mod.txt");
    defer allocator.free(mod_dst);
    try std.testing.expectEqualStrings("v2", mod_dst);
    const new_dst = try readT(&tmp, allocator, "dst" ++ std.fs.path.sep_str ++ "new.txt");
    defer allocator.free(new_dst);
    try std.testing.expectEqualStrings("nuevo", new_dst);
    try std.testing.expect(!existsT(&tmp, "dst" ++ std.fs.path.sep_str ++ "del.txt"));
    // keep.txt intacto.
    const keep = try readT(&tmp, allocator, "dst" ++ std.fs.path.sep_str ++ "keep.txt");
    defer allocator.free(keep);
    try std.testing.expectEqualStrings("igual", keep);
}

test "E5.18: applyWinner reancla orden-<hija> a orden-<padre> en el destino" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // La candidata escribe bajo su carpeta de orden convencional; la padre
    // lee la suya. Git real para la ruta principal.
    try writeT(&tmp, "cand" ++ std.fs.path.sep_str ++ "orden-790" ++ std.fs.path.sep_str ++ "e518_probe.txt", "23");
    try writeT(&tmp, "cand" ++ std.fs.path.sep_str ++ "base.txt", "compartido");
    try writeT(&tmp, "dst" ++ std.fs.path.sep_str ++ "base.txt", "compartido");

    var cand_buf: [4096]u8 = undefined;
    var dst_buf: [4096]u8 = undefined;
    const cand = try tmpSub(&tmp, &cand_buf, "cand");
    const dst = try tmpSub(&tmp, &dst_buf, "dst");
    {
        const out = try gitCapture(allocator, cand, &.{"init"});
        defer allocator.free(out);
    }
    {
        const out = try gitCapture(allocator, cand, &.{ "add", "base.txt" });
        defer allocator.free(out);
    }
    {
        const out = try gitCapture(allocator, cand, &.{ "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "base" });
        defer allocator.free(out);
    }

    const remap = PathRemap{ .from = "orden-790", .to = "orden-789" };
    const r = try applyWinner(allocator, cand, dst, &.{}, remap);
    try std.testing.expectEqual(@as(u32, 1), r.copied);
    // El artefacto aterriza en la carpeta de la PADRE, no en la de la hija.
    const got = try readT(&tmp, allocator, "dst" ++ std.fs.path.sep_str ++ "orden-789" ++ std.fs.path.sep_str ++ "e518_probe.txt");
    defer allocator.free(got);
    try std.testing.expectEqualStrings("23", got);
    try std.testing.expect(!existsT(&tmp, "dst" ++ std.fs.path.sep_str ++ "orden-790" ++ std.fs.path.sep_str ++ "e518_probe.txt"));
}

test "USUARIO-NUEVO B: applyWinnerSkipping lleva orden-<hija> a la raíz y deja fuera lo excluido" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeT(&tmp, "cand" ++ std.fs.path.sep_str ++ "orden-17" ++ std.fs.path.sep_str ++ "saludo.py", "print('Hola desde B')");
    try writeT(&tmp, "cand" ++ std.fs.path.sep_str ++ "orden-17" ++ std.fs.path.sep_str ++ "t2.txt", "informe del auditor");
    try writeT(&tmp, "cand" ++ std.fs.path.sep_str ++ "base.txt", "compartido");
    try writeT(&tmp, "dst" ++ std.fs.path.sep_str ++ "base.txt", "compartido");
    var cand_buf: [4096]u8 = undefined;
    var dst_buf: [4096]u8 = undefined;
    const cand = try tmpSub(&tmp, &cand_buf, "cand");
    const dst = try tmpSub(&tmp, &dst_buf, "dst");
    {
        const out = try gitCapture(allocator, cand, &.{"init"});
        defer allocator.free(out);
    }
    {
        const out = try gitCapture(allocator, cand, &.{ "add", "base.txt" });
        defer allocator.free(out);
    }
    {
        const out = try gitCapture(allocator, cand, &.{ "-c", "user.email=t@t", "-c", "user.name=t", "commit", "-m", "base" });
        defer allocator.free(out);
    }
    const remap = PathRemap{ .from = "orden-17", .to = "" };
    const r = try applyWinnerSkipping(allocator, cand, dst, &.{}, remap, &.{"t2.txt"});
    try std.testing.expectEqual(@as(u32, 1), r.copied);
    const got = try readT(&tmp, allocator, "dst" ++ std.fs.path.sep_str ++ "saludo.py");
    defer allocator.free(got);
    try std.testing.expectEqualStrings("print('Hola desde B')", got);
    try std.testing.expect(!existsT(&tmp, "dst" ++ std.fs.path.sep_str ++ "t2.txt"));
    try std.testing.expect(!existsT(&tmp, "dst" ++ std.fs.path.sep_str ++ "orden-17" ++ std.fs.path.sep_str ++ "saludo.py"));
}

test "E5.18: walkArtifactDir lista la carpeta de artefactos (recursivo)" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeT(&tmp, "cand" ++ std.fs.path.sep_str ++ "orden-790" ++ std.fs.path.sep_str ++ "e518_probe.txt", "23");
    try writeT(&tmp, "cand" ++ std.fs.path.sep_str ++ "orden-790" ++ std.fs.path.sep_str ++ "sub" ++ std.fs.path.sep_str ++ "deep.txt", "x");
    var cand_buf: [4096]u8 = undefined;
    const cand = try tmpSub(&tmp, &cand_buf, "cand");
    const got = try walkArtifactDir(allocator, cand, "orden-790");
    defer {
        for (got) |p| allocator.free(p);
        allocator.free(got);
    }
    try std.testing.expectEqual(@as(usize, 2), got.len);
    try std.testing.expect(containsPath(got, "orden-790/e518_probe.txt"));
    try std.testing.expect(containsPath(got, "orden-790/sub/deep.txt"));
    // Carpeta ausente → lista vacía, no error.
    const none = try walkArtifactDir(allocator, cand, "orden-999");
    defer allocator.free(none);
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "E5.18: applyWinner degradado reancla artefactos envueltos en orden-<hija>" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // Space degradado (sin git utilizable): el artefacto vive bajo
    // orden-<hija> aunque el plan declare el nombre suelto.
    try writeT(&tmp, "cand" ++ std.fs.path.sep_str ++ "orden-790" ++ std.fs.path.sep_str ++ "e518_probe.txt", "23");

    var cand_buf: [4096]u8 = undefined;
    var dst_buf: [4096]u8 = undefined;
    const cand = try tmpSub(&tmp, &cand_buf, "cand");
    const dst = try tmpSub(&tmp, &dst_buf, "dst");
    {
        const out = try gitCapture(allocator, cand, &.{"init"});
        defer allocator.free(out);
    }

    const remap = PathRemap{ .from = "orden-790", .to = "orden-789" };
    const owns = [_][]const u8{"e518_probe.txt"};
    const r = try applyWinner(allocator, cand, dst, &owns, remap);
    try std.testing.expectEqual(@as(u32, 1), r.copied);
    const got = try readT(&tmp, allocator, "dst" ++ std.fs.path.sep_str ++ "orden-789" ++ std.fs.path.sep_str ++ "e518_probe.txt");
    defer allocator.free(got);
    try std.testing.expectEqualStrings("23", got);
}

test "SEC-FS winner copies confined nested files and rejects source and destination traversal" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeT(&tmp, "source/nested/file.bin", "\x00new\xff");
    try writeT(&tmp, "destination/file.bin", "long previous contents");
    try writeT(&tmp, "outside.txt", "outside unchanged");
    const source_path = try tmp.dir.realPathFileAlloc(io, "source", a);
    defer a.free(source_path);
    const destination_path = try tmp.dir.realPathFileAlloc(io, "destination", a);
    defer a.free(destination_path);
    var source = try confined_fs.Root.init(a, source_path);
    defer source.deinit();
    var destination = try confined_fs.Root.initMutation(a, destination_path);
    defer destination.deinit();
    try std.testing.expect(try copyInto(&source, "nested/file.bin", &destination, "file.bin"));
    try std.testing.expect(try copyInto(&source, "nested/file.bin", &destination, "created/deep/file.bin"));
    try std.testing.expect(!try copyInto(&source, "missing", &destination, "absent"));
    try std.testing.expectError(error.SandboxDenied, copyInto(&source, "../outside.txt", &destination, "stolen"));
    try std.testing.expectError(error.SandboxDenied, copyInto(&source, "nested/file.bin", &destination, "../outside.txt"));
    const copied = try readT(&tmp, a, "destination/file.bin");
    defer a.free(copied);
    try std.testing.expectEqualStrings("\x00new\xff", copied);
    const outside = try readT(&tmp, a, "outside.txt");
    defer a.free(outside);
    try std.testing.expectEqualStrings("outside unchanged", outside);
    try destination.removeFile("created/deep/file.bin");
    try std.testing.expect(!existsT(&tmp, "destination/created/deep/file.bin"));
}

test "CK-MOT-032 r2: best_of_n.updateResult conserva NULL en referencias opcionales" {
    const allocator = std.testing.allocator;
    var conn = try openTestDb(allocator);
    defer conn.close();
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'x', 'running', 1)");
    const cid = try insertCandidate(conn, 1, 0, .{ .provider = "A", .model = "m1" });

    try updateResult(conn, cid, null, null, null, "cancelled", .{});
    {
        const stmt = try conn.prepare("SELECT child_order_id, space_id, plan_id FROM best_of_n_candidates WHERE id = ?");
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, cid);
        try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
        try std.testing.expectEqual(db.c.SQLITE_NULL, db.c.sqlite3_column_type(stmt, 0));
        try std.testing.expectEqual(db.c.SQLITE_NULL, db.c.sqlite3_column_type(stmt, 1));
        try std.testing.expectEqual(db.c.SQLITE_NULL, db.c.sqlite3_column_type(stmt, 2));
    }

    try updateResult(conn, cid, 101, null, 77, "done", .{});
    {
        const stmt = try conn.prepare("SELECT child_order_id, space_id, plan_id FROM best_of_n_candidates WHERE id = ?");
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, cid);
        try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
        try std.testing.expectEqual(@as(i64, 101), db.c.sqlite3_column_int64(stmt, 0));
        try std.testing.expectEqual(db.c.SQLITE_NULL, db.c.sqlite3_column_type(stmt, 1));
        try std.testing.expectEqual(@as(i64, 77), db.c.sqlite3_column_int64(stmt, 2));
    }

    const list = try listByParent(conn, allocator, 1);
    defer freeCandidateList(allocator, list);
    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqual(@as(?i64, 101), list[0].child_order_id);
    try std.testing.expectEqual(@as(?i64, null), list[0].space_id);
    try std.testing.expectEqual(@as(?i64, 77), list[0].plan_id);
}
