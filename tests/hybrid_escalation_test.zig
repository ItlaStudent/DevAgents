//! / H-G4-ESCALATION - camino POSITIVO de la escalada hibrida.
//!
//! E3-30 senalo que `gate-f4` solo comprueba "0 filas ESCALATION" en un
//! escenario todo-free; nadie ejercitaba el caso que la gobernanza hibrida
//! define como valido: PAGO para pensar/auditar y FREE para construir.
//!
//! Esta prueba recorre el camino real del producto:
//!   MockPlanner (sin red) -> Superagent.processOrder -> assignAndPersist ->
//!   Router.route en modo hybrid -> audit_ledger.
//!
//! Con catalogo mixto (un modelo free y uno de pago, ambos con clave activa)
//! la tarea de construccion debe resolverse en free y la de auditoria en pago.
//! La asignacion de pago debe dejar UNA fila ESCALATION con notes no vacias
//! (justificacion) y el modelo/provider reales. No se toca la red.

const std = @import("std");
const core = @import("core");

const db = core.db;

fn openRuntime(allocator: std.mem.Allocator) !db.Connection {
    var conn = try db.Connection.open(allocator, ":memory:");
    errdefer conn.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);
    return conn;
}

fn seedHybridCatalog(conn: db.Connection) !void {
    try conn.exec("INSERT INTO providers (id, name, base_url, api_style, is_free_tier) VALUES (1, 'OpenCode', 'local://opencode', 'opencode', 1)");
    try conn.exec("INSERT INTO providers (id, name, base_url, api_style, is_free_tier) VALUES (2, 'OpenRouterPaid', 'https://openrouter.ai/api/v1', 'openai', 0)");
    try conn.exec("INSERT INTO api_keys (id, provider_id, label, key_ciphertext, quota_limit, quota_used, status) VALUES (1, 1, 'free-a', x'00', 100, 0, 'active')");
    try conn.exec("INSERT INTO api_keys (id, provider_id, label, key_ciphertext, quota_limit, quota_used, status) VALUES (2, 2, 'paid-a', x'00', 100, 0, 'active')");
    try conn.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, latency_p50_ms, available) VALUES (1, 1, 'deepseek-coder-free', 128000, 1, 1200, 1)");
    try conn.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, latency_p50_ms, available) VALUES (2, 2, 'claude-opus-paid', 200000, 0, 1800, 1)");
}

fn findAssignment(
    assignments: []const core.superagent.ModelAssignment,
    task_id: []const u8,
) ?core.superagent.ModelAssignment {
    for (assignments) |assignment| {
        if (std.mem.eql(u8, assignment.task_id, task_id)) return assignment;
    }
    return null;
}

test "H-G4-ESCALATION: plan de pago + build gratis deja fila ESCALATION justificada" {
    const allocator = std.testing.allocator;

    var runtime = try openRuntime(allocator);
    defer runtime.close();
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var ledger = try db.Connection.open(allocator, ":memory:");
    defer ledger.close();

    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);
    try migrator.migrate(ledger, &db.ledger_schema);
    try seedHybridCatalog(catalog);

    var router = core.model_router.Router.init(allocator, catalog, ledger, 1);
    defer router.deinitHealthCache();
    try router.setGovernanceMode(.hybrid);
    try router.seedInitialScores();

    var mock_planner = core.planner.MockPlanner.init(allocator);
    const planner_backend = mock_planner.backend();
    var superagent = core.superagent.Superagent.init(
        allocator,
        runtime,
        &router,
        core.superagent.NoopMemory.backend(),
        1,
    );

    var outcome = try superagent.processOrder(
        "prb003",
        "construye una calculadora CLI en Zig con tests",
        &.{},
        planner_backend,
        null,
        null,
    );
    defer outcome.deinit();

    try std.testing.expect(outcome.status == .planned);

    var saw_free_build = false;
    var saw_paid_audit = false;
    for (outcome.plan.tasks) |task| {
        const assignment = findAssignment(outcome.assignments, task.id) orelse continue;
        std.debug.print(
            "[H-G4] tarea {s} ({s}) -> {s}/{s} free={any} assigned={any}\n",
            .{
                task.id,
                task.task_type.toText(),
                assignment.provider_name,
                assignment.model_name,
                assignment.is_free,
                assignment.assigned,
            },
        );
        switch (task.task_type) {
            .programar_zig => {
                try std.testing.expect(assignment.assigned);
                try std.testing.expect(assignment.is_free);
                saw_free_build = true;
            },
            .auditar => {
                try std.testing.expect(assignment.assigned);
                try std.testing.expect(!assignment.is_free);
                saw_paid_audit = true;
            },
            else => {},
        }
    }
    try std.testing.expect(saw_free_build);
    try std.testing.expect(saw_paid_audit);

    const stmt = try ledger.prepare(
        "SELECT model_id, provider, notes, evidence_ref, verdict FROM audit_ledger WHERE action='ESCALATION'",
    );
    defer ledger.finalize(stmt);

    var rows: usize = 0;
    var justified: usize = 0;
    var paid_model_rows: usize = 0;
    while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
        rows += 1;
        const model_ptr = db.c.sqlite3_column_text(stmt, 0);
        const provider_ptr = db.c.sqlite3_column_text(stmt, 1);
        const notes_ptr = db.c.sqlite3_column_text(stmt, 2);
        const evidence_ptr = db.c.sqlite3_column_text(stmt, 3);
        const verdict_ptr = db.c.sqlite3_column_text(stmt, 4);
        const model = if (model_ptr != null) model_ptr[0..std.mem.len(model_ptr)] else "";
        const provider = if (provider_ptr != null) provider_ptr[0..std.mem.len(provider_ptr)] else "";
        const notes = if (notes_ptr != null) notes_ptr[0..std.mem.len(notes_ptr)] else "";
        const evidence = if (evidence_ptr != null) evidence_ptr[0..std.mem.len(evidence_ptr)] else "";
        const verdict = if (verdict_ptr != null) verdict_ptr[0..std.mem.len(verdict_ptr)] else "";
        std.debug.print(
            "[H-G4] ESCALATION modelo={s} provider={s} verdict={s} evidence={s} notes='{s}'\n",
            .{ model, provider, verdict, evidence, notes },
        );
        if (std.mem.eql(u8, model, "claude-opus-paid") and std.mem.eql(u8, provider, "OpenRouterPaid")) {
            paid_model_rows += 1;
        }
        if (notes.len > 0 and
            std.mem.indexOf(u8, notes, "escalada permitida") != null and
            std.mem.eql(u8, verdict, "PASS") and
            std.mem.eql(u8, evidence, "route"))
        {
            justified += 1;
        }
    }

    std.debug.print(
        "[H-G4] filas ESCALATION={d} justificadas={d} del modelo de pago={d}\n",
        .{ rows, justified, paid_model_rows },
    );
    try std.testing.expectEqual(@as(usize, 1), rows);
    try std.testing.expectEqual(@as(usize, 1), justified);
    try std.testing.expectEqual(@as(usize, 1), paid_model_rows);
    std.debug.print("[H-G4] PASS: hibrido plan-pago/build-free con ESCALATION justificada\n", .{});
}
