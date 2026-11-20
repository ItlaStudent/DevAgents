const std = @import("std");
const db = @import("db.zig");

pub const ChecklistStatus = enum {
    pending,
    built,
    audited,
    verified,
    reopened,
    self_reviewed,

    pub fn toText(self: ChecklistStatus) []const u8 {
        return switch (self) {
            .pending => "pending",
            .built => "built",
            .audited => "audited",
            .verified => "verified",
            .reopened => "reopened",
            .self_reviewed => "self_reviewed",
        };
    }
};

const LedgerRow = struct {
    action: []const u8,
    verdict: []const u8,
    model_id: []const u8,
    row_hash: []const u8,
    prev_hash: []const u8,
};

/// Estado interno por subject mientras se recorre el ledger.
const SubjectState = struct {
    has_build_pass: bool = false,
    builder_model: ?[]u8 = null,
    audit_models: std.StringHashMap(void),
    last_was_fail: bool = false,
    self_reviewed: bool = false,

    fn init(allocator: std.mem.Allocator) SubjectState {
        return .{ .audit_models = std.StringHashMap(void).init(allocator) };
    }

    fn deinit(self: *SubjectState, allocator: std.mem.Allocator) void {
        if (self.builder_model) |bm| allocator.free(bm);
        var it = self.audit_models.keyIterator();
        while (it.next()) |k| allocator.free(k.*);
        self.audit_models.deinit();
    }

    /// Alimenta una fila (action/verdict/model) del subject al autómata.
    /// Solo cuentan auditores DISTINTOS entre sí y distintos del constructor
    /// (regla nuclear del protocolo: nadie se auto-audita, y 2 ✔ del mismo
    /// modelo no equivalen a 2 auditores). El gate determinista del motor firma
    /// AUDIT con model_id="" → no cuenta como auditoría de modelo.
    fn feed(self: *SubjectState, allocator: std.mem.Allocator, action: []const u8, verdict: []const u8, model: []const u8) !void {
        if (std.mem.eql(u8, action, "BUILD") and std.mem.eql(u8, verdict, "PASS")) {
            self.has_build_pass = true;
            if (self.builder_model == null and model.len > 0) {
                self.builder_model = try allocator.dupe(u8, model);
            }
            self.last_was_fail = false;
        } else if (std.mem.eql(u8, action, "AUDIT")) {
            if (std.mem.eql(u8, verdict, "PASS")) {
                const distinct: bool = if (self.builder_model) |bm|
                    !std.mem.eql(u8, model, bm)
                else
                    true;
                if (distinct and model.len > 0) {
                    const gop = try self.audit_models.getOrPut(model);
                    if (!gop.found_existing) {
                        gop.key_ptr.* = try allocator.dupe(u8, model);
                    }
                } else if (!distinct and model.len > 0) {
                    self.self_reviewed = true;
                }
                self.last_was_fail = false;
            } else if (std.mem.eql(u8, verdict, "FAIL")) {
                self.last_was_fail = true;
            }
        } else if (std.mem.eql(u8, action, "FIX") and std.mem.eql(u8, verdict, "PASS")) {
            self.last_was_fail = false;
        }
    }

    fn status(self: *const SubjectState) ChecklistStatus {
        const distinct_audits = self.audit_models.count();
        if (self.last_was_fail) return .reopened;
        if (self.has_build_pass and distinct_audits >= 2) return .verified;
        if (self.has_build_pass and distinct_audits >= 1) return .audited;
        if (self.has_build_pass and self.self_reviewed) return .self_reviewed;
        if (self.has_build_pass) return .built;
        return .pending;
    }
};

/// Verifica el eslabón de la fila contra la cadena. La cadena es SEGMENTADA:
/// el writer (persistAuditEntriesOnConn) encadena dentro de cada lote de flush
/// y arranca cada lote con prev_hash="". Un prev_hash vacío abre segmento;
/// uno no vacío debe igualar el row_hash de la fila inmediatamente anterior
/// (orden por id, GLOBAL — los subjects se entrelazan dentro de un lote).
/// Se compara el texto almacenado directamente (no se re-decodea hex): el
/// invariante del writer es prev_hash(N) == row_hash(N-1).
fn verifyLink(prev_hash: []const u8, last_row_hash: ?[]const u8) !void {
    if (prev_hash.len == 0) return; // frontera de segmento (primer row del lote)
    const last = last_row_hash orelse return error.HashChainBroken;
    if (!std.mem.eql(u8, prev_hash, last)) return error.HashChainBroken;
}

/// Estado derivado de la cadena de marcas en audit_ledger.
/// Implementa la máquina de estados del CHECKLIST.md:
///   pending → built → audited(n) → verified | reopened.
/// FR-003 de spec 013.
///
/// La verificación de la cadena corre sobre el ledger COMPLETO en orden de id
/// (los lotes de flush entrelazan subjects; filtrar por subject rompería la
/// comparación prev_hash→row_hash sobre datos legítimos).
pub fn deriveStatus(conn: db.Connection, subject_kind: []const u8, order_id: i64, subject_id: i64) !ChecklistStatus {
    const stmt = try conn.prepare(
        "SELECT subject_kind, subject_id, action, verdict, COALESCE(model_id,''), row_hash, COALESCE(prev_hash,''), COALESCE(order_id,0) FROM audit_ledger ORDER BY id ASC",
    );
    defer conn.finalize(stmt);

    var state = SubjectState.init(conn.allocator);
    defer state.deinit(conn.allocator);
    // El texto de una columna sqlite3_column_text muere en el siguiente step:
    // el hash de la fila previa se copia a un buffer propio, nunca se referencia.
    var last_hash_buf: [128]u8 = undefined;
    var last_row_hash: ?[]const u8 = null;

    while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
        const prev_hash = std.mem.span(db.c.sqlite3_column_text(stmt, 6));
        try verifyLink(prev_hash, last_row_hash);
        const row_hash = std.mem.span(db.c.sqlite3_column_text(stmt, 5));
        if (row_hash.len > last_hash_buf.len) return error.HashChainBroken;
        @memcpy(last_hash_buf[0..row_hash.len], row_hash);
        last_row_hash = last_hash_buf[0..row_hash.len];

        const kind = std.mem.span(db.c.sqlite3_column_text(stmt, 0));
        const id = db.c.sqlite3_column_int64(stmt, 1);
        const oid = db.c.sqlite3_column_int64(stmt, 7);
        if (id != subject_id or oid != order_id or !std.mem.eql(u8, kind, subject_kind)) continue;
        const action = std.mem.span(db.c.sqlite3_column_text(stmt, 2));
        const verdict = std.mem.span(db.c.sqlite3_column_text(stmt, 3));
        const model = std.mem.span(db.c.sqlite3_column_text(stmt, 4));
        try state.feed(conn.allocator, action, verdict, model);
    }
    return state.status();
}

/// Estado derivado de un subject, con el detalle de quién auditó.
pub const SubjectStatus = struct {
    subject_kind: []u8,
    subject_id: i64,
    /// Orden a la que pertenece el subject (0 = filas históricas sin orden).
    order_id: i64,
    status: ChecklistStatus,
    /// Modelos auditores distintos y ≠ constructor que dejaron AUDIT PASS.
    auditors: [][]u8,
    /// Modelo constructor (primer BUILD PASS), si existe.
    builder: ?[]u8,

    pub fn deinit(self: *SubjectStatus, allocator: std.mem.Allocator) void {
        allocator.free(self.subject_kind);
        for (self.auditors) |m| allocator.free(m);
        allocator.free(self.auditors);
        if (self.builder) |b| allocator.free(b);
    }
};

/// PRODUCCIÓN (AUDIT-INDEP): recorrido único por el ledger en orden de id que
/// verifica la cadena segmentada y deriva el estado de checklist de TODOS los
/// subjects presentes. Consume `da_audit_checklist_json` — antes de este
/// cableado, deriveStatus solo se alcanzaba desde tests.
/// error.HashChainBroken invalida el reporte entero (un ledger manipulado no
/// certifica nada).
pub fn deriveAllSubjects(conn: db.Connection, allocator: std.mem.Allocator) ![]SubjectStatus {
    const stmt = try conn.prepare(
        "SELECT subject_kind, subject_id, action, verdict, COALESCE(model_id,''), row_hash, COALESCE(prev_hash,''), COALESCE(order_id,0) FROM audit_ledger ORDER BY id ASC",
    );
    defer conn.finalize(stmt);

    const SubjectKey = struct { kind: []u8, id: i64, order_id: i64 };
    var states = std.ArrayList(SubjectKey).empty;
    var subjects = std.ArrayList(SubjectState).empty;
    defer {
        for (states.items) |k| allocator.free(k.kind);
        for (subjects.items) |*s| s.deinit(allocator);
        states.deinit(allocator);
        subjects.deinit(allocator);
    }

    var last_hash_buf: [128]u8 = undefined;
    var last_row_hash: ?[]const u8 = null;
    while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
        const prev_hash = std.mem.span(db.c.sqlite3_column_text(stmt, 6));
        try verifyLink(prev_hash, last_row_hash);
        const row_hash = std.mem.span(db.c.sqlite3_column_text(stmt, 5));
        if (row_hash.len > last_hash_buf.len) return error.HashChainBroken;
        @memcpy(last_hash_buf[0..row_hash.len], row_hash);
        last_row_hash = last_hash_buf[0..row_hash.len];

        const kind = std.mem.span(db.c.sqlite3_column_text(stmt, 0));
        const id = db.c.sqlite3_column_int64(stmt, 1);
        const oid = db.c.sqlite3_column_int64(stmt, 7);
        const action = std.mem.span(db.c.sqlite3_column_text(stmt, 2));
        const verdict = std.mem.span(db.c.sqlite3_column_text(stmt, 3));
        const model = std.mem.span(db.c.sqlite3_column_text(stmt, 4));

        var idx: ?usize = null;
        for (states.items, 0..) |k, i| {
            if (k.id == id and k.order_id == oid and std.mem.eql(u8, k.kind, kind)) {
                idx = i;
                break;
            }
        }
        const si = idx orelse blk: {
            try states.append(allocator, .{ .kind = try allocator.dupe(u8, kind), .id = id, .order_id = oid });
            try subjects.append(allocator, SubjectState.init(allocator));
            break :blk subjects.items.len - 1;
        };
        try subjects.items[si].feed(allocator, action, verdict, model);
    }

    var out = std.ArrayList(SubjectStatus).empty;
    errdefer {
        for (out.items) |*s| s.deinit(allocator);
        out.deinit(allocator);
    }
    for (states.items, subjects.items) |k, s| {
        var auditors = std.ArrayList([]u8).empty;
        errdefer {
            for (auditors.items) |m| allocator.free(m);
            auditors.deinit(allocator);
        }
        var it = s.audit_models.keyIterator();
        while (it.next()) |mk| {
            try auditors.append(allocator, try allocator.dupe(u8, mk.*));
        }
        try out.append(allocator, .{
            .subject_kind = try allocator.dupe(u8, k.kind),
            .subject_id = k.id,
            .order_id = k.order_id,
            .status = s.status(),
            .auditors = try auditors.toOwnedSlice(allocator),
            .builder = if (s.builder_model) |bm| try allocator.dupe(u8, bm) else null,
        });
    }
    return out.toOwnedSlice(allocator);
}

test "deriveStatus returns pending for empty ledger" {
    var conn = try db.Connection.open(std.testing.allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(std.testing.allocator);
    try migrator.migrate(conn, &db.ledger_schema);
    try std.testing.expectEqual(ChecklistStatus.pending, try deriveStatus(conn, "task", 0, 1));
}

test "deriveStatus returns built after BUILD PASS" {
    var conn = try db.Connection.open(std.testing.allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(std.testing.allocator);
    try migrator.migrate(conn, &db.ledger_schema);
    try conn.exec("INSERT INTO audit_ledger (ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, row_hash) VALUES (1, 'task', 1, 'BUILD', 'PASS', 'deepseek-v4', 'deepseek', 'ref', x'00')");
    try std.testing.expectEqual(ChecklistStatus.built, try deriveStatus(conn, "task", 0, 1));
}

test "deriveStatus returns verified after BUILD + 2 AUDIT PASS" {
    var conn = try db.Connection.open(std.testing.allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(std.testing.allocator);
    try migrator.migrate(conn, &db.ledger_schema);
    try conn.exec("INSERT INTO audit_ledger (ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, row_hash) VALUES (1, 'task', 1, 'BUILD', 'PASS', 'deepseek-v4', 'deepseek', 'ref', x'00')");
    try conn.exec("INSERT INTO audit_ledger (ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, row_hash) VALUES (2, 'task', 1, 'AUDIT', 'PASS', 'claude-opus', 'anthropic', 'ref', x'00')");
    try conn.exec("INSERT INTO audit_ledger (ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, row_hash) VALUES (3, 'task', 1, 'AUDIT', 'PASS', 'gemini-pro', 'google', 'ref', x'00')");
    try std.testing.expectEqual(ChecklistStatus.verified, try deriveStatus(conn, "task", 0, 1));
}

test "deriveStatus: two audits from the SAME model do not reach verified" {
    var conn = try db.Connection.open(std.testing.allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(std.testing.allocator);
    try migrator.migrate(conn, &db.ledger_schema);
    try conn.exec("INSERT INTO audit_ledger (ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, row_hash) VALUES (1, 'task', 1, 'BUILD', 'PASS', 'deepseek-v4', 'deepseek', 'ref', x'00')");
    try conn.exec("INSERT INTO audit_ledger (ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, row_hash) VALUES (2, 'task', 1, 'AUDIT', 'PASS', 'claude-opus', 'anthropic', 'ref', x'00')");
    try conn.exec("INSERT INTO audit_ledger (ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, row_hash) VALUES (3, 'task', 1, 'AUDIT', 'PASS', 'claude-opus', 'anthropic', 'ref', x'00')");
    // 2 AUDIT del MISMO modelo = 1 auditor distinto → audited, jamás verified.
    try std.testing.expectEqual(ChecklistStatus.audited, try deriveStatus(conn, "task", 0, 1));
}

test "deriveStatus: audits by the builder model itself never count" {
    var conn = try db.Connection.open(std.testing.allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(std.testing.allocator);
    try migrator.migrate(conn, &db.ledger_schema);
    try conn.exec("INSERT INTO audit_ledger (ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, row_hash) VALUES (1, 'task', 1, 'BUILD', 'PASS', 'deepseek-v4', 'deepseek', 'ref', x'00')");
    try conn.exec("INSERT INTO audit_ledger (ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, row_hash) VALUES (2, 'task', 1, 'AUDIT', 'PASS', 'deepseek-v4', 'deepseek', 'ref', x'00')");
    try conn.exec("INSERT INTO audit_ledger (ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, row_hash) VALUES (3, 'task', 1, 'AUDIT', 'PASS', 'deepseek-v4', 'deepseek', 'ref', x'00')");
    // Autoauditoría explícita: se etiqueta sin contar auditores independientes.
    try std.testing.expectEqual(ChecklistStatus.self_reviewed, try deriveStatus(conn, "task", 0, 1));
}

test "deriveStatus returns reopened after AUDIT FAIL" {
    var conn = try db.Connection.open(std.testing.allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(std.testing.allocator);
    try migrator.migrate(conn, &db.ledger_schema);
    try conn.exec("INSERT INTO audit_ledger (ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, row_hash) VALUES (1, 'task', 1, 'BUILD', 'PASS', 'deepseek-v4', 'deepseek', 'ref', x'00')");
    try conn.exec("INSERT INTO audit_ledger (ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, row_hash) VALUES (2, 'task', 1, 'AUDIT', 'FAIL', 'claude-opus', 'anthropic', 'ref', x'00')");
    try std.testing.expectEqual(ChecklistStatus.reopened, try deriveStatus(conn, "task", 0, 1));
}

// ── AUDIT-INDEP: cadena segmentada, gate determinista, multi-subject ──

fn insertLedgerRow(conn: db.Connection, a: std.mem.Allocator, ts: i64, order: i64, id: i64, action: []const u8, verdict: []const u8, model: []const u8, provider: []const u8, prev: []const u8, hash: []const u8) !void {
    const q = try std.fmt.allocPrint(a, "INSERT INTO audit_ledger (ts,subject_kind,subject_id,order_id,action,verdict,model_id,provider,evidence_ref,prev_hash,row_hash) VALUES ({d},'task',{d},{d},'{s}','{s}','{s}','{s}','ref','{s}','{s}')", .{ ts, id, order, action, verdict, model, provider, prev, hash });
    defer a.free(q);
    try conn.exec(q);
}

test "deriveStatus: subjects entrelazados en un lote no rompen la cadena segmentada" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(a);
    try migrator.migrate(conn, &db.ledger_schema);

    // El writer real encadena dentro de cada flush y entrelaza subjects: la
    // primera fila del lote lleva prev_hash="" aunque NO sea la primera del
    // subject. Una verificacion por-subject rechazaria datos legitimos.
    const h1 = db.computeRowHash(null, "lote1-t1-build");
    const h2 = db.computeRowHash(&h1, "lote1-t2-build");
    const h3 = db.computeRowHash(&h2, "lote1-t1-audit");
    const h4 = db.computeRowHash(&h3, "lote1-t2-audit");
    try insertLedgerRow(conn, a, 1, 7, 1, "BUILD", "PASS", "mimo", "open", "", &h1);
    try insertLedgerRow(conn, a, 1, 7, 2, "BUILD", "PASS", "mimo", "open", &h1, &h2);
    try insertLedgerRow(conn, a, 2, 7, 1, "AUDIT", "PASS", "claude", "anthropic", &h2, &h3);
    try insertLedgerRow(conn, a, 2, 7, 2, "AUDIT", "PASS", "claude", "anthropic", &h3, &h4);
    // Segundo lote: nuevo segmento (prev=""), mismos subjects.
    const h5 = db.computeRowHash(null, "lote2-t1-audit");
    const h6 = db.computeRowHash(&h5, "lote2-t2-audit");
    try insertLedgerRow(conn, a, 3, 7, 1, "AUDIT", "PASS", "gemini", "google", "", &h5);
    try insertLedgerRow(conn, a, 3, 7, 2, "AUDIT", "PASS", "gemini", "google", &h5, &h6);

    try std.testing.expectEqual(ChecklistStatus.verified, try deriveStatus(conn, "task", 7, 1));
    try std.testing.expectEqual(ChecklistStatus.verified, try deriveStatus(conn, "task", 7, 2));
}

test "deriveStatus: el gate determinista (model_id vacio) no cuenta como auditoria de modelo" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(a);
    try migrator.migrate(conn, &db.ledger_schema);

    const h1 = db.computeRowHash(null, "build");
    const h2 = db.computeRowHash(&h1, "gate");
    try insertLedgerRow(conn, a, 1, 7, 1, "BUILD", "PASS", "mimo", "open", "", &h1);
    try insertLedgerRow(conn, a, 2, 7, 1, "AUDIT", "PASS", "", "deterministic-gate", &h1, &h2);
    // Gate determinista != auditor de modelo: sigue en built, no audited.
    try std.testing.expectEqual(ChecklistStatus.built, try deriveStatus(conn, "task", 7, 1));
}

test "deriveAllSubjects: deriva todos los subjects de una pasada con cadena verificada" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(a);
    try migrator.migrate(conn, &db.ledger_schema);

    const h1 = db.computeRowHash(null, "t1-build");
    const h2 = db.computeRowHash(&h1, "t2-build");
    const h3 = db.computeRowHash(&h2, "t1-a1");
    const h4 = db.computeRowHash(&h3, "t1-a2");
    const h5 = db.computeRowHash(&h4, "t2-a1");
    try insertLedgerRow(conn, a, 1, 9, 1, "BUILD", "PASS", "mimo", "open", "", &h1);
    try insertLedgerRow(conn, a, 1, 9, 2, "BUILD", "PASS", "mimo", "open", &h1, &h2);
    try insertLedgerRow(conn, a, 2, 9, 1, "AUDIT", "PASS", "claude", "anthropic", &h2, &h3);
    try insertLedgerRow(conn, a, 2, 9, 1, "AUDIT", "PASS", "gemini", "google", &h3, &h4);
    try insertLedgerRow(conn, a, 2, 9, 2, "AUDIT", "PASS", "claude", "anthropic", &h4, &h5);

    const subjects = try deriveAllSubjects(conn, a);
    defer {
        for (subjects) |*s| s.deinit(a);
        a.free(subjects);
    }
    try std.testing.expectEqual(@as(usize, 2), subjects.len);
    try std.testing.expectEqual(ChecklistStatus.verified, subjects[0].status);
    try std.testing.expectEqual(@as(usize, 2), subjects[0].auditors.len);
    try std.testing.expectEqual(ChecklistStatus.audited, subjects[1].status);
}

test "deriveStatus: subject_id se aisla por order_id (T1 orden 7 no hereda auditorias de orden 8)" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(a);
    try migrator.migrate(conn, &db.ledger_schema);

    const h1 = db.computeRowHash(null, "o7-t1-build");
    const h2 = db.computeRowHash(&h1, "o8-t1-build");
    const h3 = db.computeRowHash(&h2, "o8-t1-a1");
    const h4 = db.computeRowHash(&h3, "o8-t1-a2");
    try insertLedgerRow(conn, a, 1, 7, 1, "BUILD", "PASS", "mimo", "open", "", &h1);
    try insertLedgerRow(conn, a, 1, 8, 1, "BUILD", "PASS", "mimo", "open", &h1, &h2);
    try insertLedgerRow(conn, a, 2, 8, 1, "AUDIT", "PASS", "claude", "anthropic", &h2, &h3);
    try insertLedgerRow(conn, a, 2, 8, 1, "AUDIT", "PASS", "gemini", "google", &h3, &h4);

    try std.testing.expectEqual(ChecklistStatus.built, try deriveStatus(conn, "task", 7, 1));
    try std.testing.expectEqual(ChecklistStatus.verified, try deriveStatus(conn, "task", 8, 1));
}

test "deriveStatus: una fila con prev_hash que no encaja invalida el reporte" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(a);
    try migrator.migrate(conn, &db.ledger_schema);

    const h1 = db.computeRowHash(null, "build");
    try insertLedgerRow(conn, a, 1, 7, 1, "BUILD", "PASS", "mimo", "open", "", &h1);
    try insertLedgerRow(conn, a, 2, 7, 1, "AUDIT", "PASS", "claude", "anthropic", "deadbeef", "cafe1234");
    try std.testing.expectError(error.HashChainBroken, deriveStatus(conn, "task", 7, 1));
}

test "CK-PRV-003 C3: mismo modelo queda Autorrevisada nunca Auditada" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(a);
    try migrator.migrate(conn, &db.ledger_schema);
    const h1 = db.computeRowHash(null, "build");
    const h2 = db.computeRowHash(&h1, "self");
    try insertLedgerRow(conn, a, 1, 7, 1, "BUILD", "PASS", "solo", "p", "", &h1);
    try insertLedgerRow(conn, a, 2, 7, 1, "AUDIT", "PASS", "solo", "p", &h1, &h2);
    const status = try deriveStatus(conn, "task", 7, 1);
    try std.testing.expectEqualStrings("self_reviewed", status.toText());
}
