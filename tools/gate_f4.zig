const std = @import("std");
const core = @import("core");

/// GATE F4 (T-F4-06, SC-001 de spec 009): demuestra el loop completo del superagente
/// SIN red, con backends deterministas:
///   orden ambigua → clarificación → orden resuelta → inventario de herramientas
///   (escaneo real de fixtures) → grafo de tareas con contratos y modelos asignados
///   → aprobación → despacho a workers paralelos con sandbox → reporte consolidado.
///
/// Reproducible: mismo input → mismo resultado. No requiere claves ni proveedores vivos.
pub fn main() !void {
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    std.debug.print("=== GATE F4: Superagente y descubrimiento (sin red) ===\n\n", .{});

    // Backends deterministas compartidos.
    var mp = core.planner.MockPlanner.init(allocator);
    const pb = mp.backend();

    // ── 1. Orden ambigua → clarificación ────────────────────────────────
    std.debug.print("[1] Orden ambigua: \"haz un programa que sume numeros\"\n", .{});
    {
        var runtime = try openMemRuntime(allocator);
        defer runtime.close();
        var sa = core.superagent.Superagent.init(allocator, runtime, null, core.superagent.NoopMemory.backend(), 1);
        var outcome = try sa.processOrder("gate", "haz un programa que sume numeros", &.{}, pb, null, null);
        defer outcome.deinit();
        if (outcome.status != .clarifying) return error.GateFailedExpectedClarification;
        std.debug.print("    Estado: {s}\n", .{outcome.status.toText()});
        for (outcome.plan.questions) |q| {
            std.debug.print("    Pregunta [{s}]: {s}\n", .{ q.id, q.text });
        }
        std.debug.print("    ✔ El superagente pregunta en vez de adivinar.\n\n", .{});
    }

    // ── 2. Inventario real de herramientas (escaneo de fixtures) ─────────
    std.debug.print("[2] Inventario de herramientas (escaneo de tests/fixtures/discovery):\n", .{});
    const inv = try core.tool_discovery.scanRoot(allocator, io, "tests/fixtures/discovery");
    defer inv.deinit(allocator);
    std.debug.print("    Recursos descubiertos: {d}\n", .{inv.resources.len});
    for (inv.resources) |r| {
        std.debug.print("      - {s}: {s}\n", .{ @tagName(r.kind), r.name });
    }
    std.debug.print("\n", .{});

    // ── 3. Orden resuelta → plan + modelos + descubrimiento + despacho ───
    std.debug.print("[3] Orden resuelta: \"construye una calculadora CLI en C con tests\"\n", .{});
    var runtime = try openMemRuntime(allocator);
    defer runtime.close();
    var catalog = try core.db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var ledger = try core.db.Connection.open(allocator, ":memory:");
    defer ledger.close();
    const migrator = core.db.Migrator.init(allocator);
    try migrator.migrate(catalog, &core.db.catalog_schema);
    try migrator.migrate(ledger, &core.db.ledger_schema);
    try seedCatalog(catalog);
    var router = core.model_router.Router.init(allocator, catalog, ledger, 1);
    try router.seedInitialScores();

    var kw = core.tool_discovery.KeywordDiscovery.init(allocator);
    const dbk = kw.backend();

    var sa = core.superagent.Superagent.init(allocator, runtime, &router, core.superagent.NoopMemory.backend(), 1);
    var outcome = try sa.processOrder("gate", "construye una calculadora CLI en C con tests", &.{}, pb, dbk, &inv);
    defer outcome.deinit();

    if (outcome.status != .planned) return error.GateFailedExpectedPlan;
    std.debug.print("    Entendimiento: {s}\n", .{outcome.plan.understanding});
    std.debug.print("    Herramientas necesarias: {d}, faltantes: {d}\n", .{ outcome.discovery_needed.len, outcome.discovery_missing.len });
    std.debug.print("    Grafo de tareas (con contrato y modelo asignado):\n", .{});
    var all_assigned = true;
    var all_free = true;
    for (outcome.plan.tasks) |pt| {
        const asg = findAssignment(outcome.assignments, pt.id);
        if (asg) |a| {
            if (!a.assigned) all_assigned = false;
            if (!a.is_free) all_free = false;
            std.debug.print("      [{s}] {s} ({s}) → {s}/{s} free={any}, contrato: {d} campos, deps: {d}\n", .{
                pt.id, pt.description, pt.task_type.toText(), a.provider_name, a.model_name, a.is_free, pt.contract_fields.len, pt.depends_on.len,
            });
        }
    }
    if (!all_assigned) return error.GateFailedUnassignedTask;
    if (!all_free) return error.GateFailedPaidWithoutNeed;
    std.debug.print("    ✔ Todas las tareas con modelo free asignado (free-tier-first).\n\n", .{});

    // ── 4. Aprobación y despacho paralelo con sandbox → reporte ──────────
    std.debug.print("[4] Aprobación → despacho a workers paralelos con sandbox → reporte:\n", .{});
    var dr = try sa.approveAndDispatch(&outcome, null, null, null);
    defer dr.deinit(allocator);
    std.debug.print("{s}\n", .{dr.report});

    if (std.mem.indexOf(u8, dr.report, "integradas") == null) return error.GateFailedNoConsolidation;

    // Verificar que la escalada a pago fue cero (free-first; ledger sin ESCALATION).
    const esc = try countEscalations(ledger);
    std.debug.print("Filas ESCALATION en ledger: {d} (debe ser 0 en este gate)\n", .{esc});
    if (esc != 0) return error.GateFailedUnexpectedEscalation;

    std.debug.print("\n=== GATE F4 superado ===\n", .{});
}

fn openMemRuntime(allocator: std.mem.Allocator) !core.db.Connection {
    var conn = try core.db.Connection.open(allocator, ":memory:");
    errdefer conn.close();
    const migrator = core.db.Migrator.init(allocator);
    try migrator.migrate(conn, &core.db.runtime_schema);
    return conn;
}

fn findAssignment(assignments: []const core.superagent.ModelAssignment, task_id: []const u8) ?core.superagent.ModelAssignment {
    for (assignments) |a| {
        if (std.mem.eql(u8, a.task_id, task_id)) return a;
    }
    return null;
}

fn countEscalations(conn: core.db.Connection) !i32 {
    const stmt = try conn.prepare("SELECT COUNT(*) FROM audit_ledger WHERE action='ESCALATION'");
    defer conn.finalize(stmt);
    if (core.db.c.sqlite3_step(stmt) != core.db.c.SQLITE_ROW) return error.StepFailed;
    return core.db.c.sqlite3_column_int(stmt, 0);
}

fn seedCatalog(conn: core.db.Connection) !void {
    try conn.exec("INSERT INTO providers (id, name, base_url, api_style, is_free_tier) VALUES (1, 'OpenCode', 'local://opencode', 'opencode', 1)");
    try conn.exec("INSERT INTO providers (id, name, base_url, api_style, is_free_tier) VALUES (2, 'Groq', 'https://api.groq.com/openai/v1', 'openai', 1)");
    try conn.exec("INSERT INTO api_keys (id, provider_id, label, key_ciphertext, quota_limit, quota_used, status) VALUES (1, 1, 'free-a', x'00', 100, 0, 'active')");
    try conn.exec("INSERT INTO api_keys (id, provider_id, label, key_ciphertext, quota_limit, quota_used, status) VALUES (2, 2, 'free-b', x'00', 100, 0, 'active')");
    try conn.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, latency_p50_ms, available) VALUES (1, 1, 'deepseek-coder-free', 128000, 1, 900, 1)");
    try conn.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, latency_p50_ms, available) VALUES (2, 2, 'gemini-flash-free', 128000, 1, 800, 1)");
    try conn.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, latency_p50_ms, available) VALUES (3, 1, 'qwen-coder-free', 64000, 1, 1100, 1)");
}
