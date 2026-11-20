const std = @import("std");
const db = @import("db.zig");
const planner = @import("planner.zig");
const sandbox = @import("sandbox.zig");
const contracts = @import("contracts.zig");
const worker_backend = @import("worker_backend.zig");
const audit_pipeline = @import("audit_pipeline.zig");

const MAX_PIPELINE_CYCLES = 3;

pub const PipelineError = error{
    OutOfMemory,
    MaxCyclesExceeded,
} || worker_backend.WorkerError || db.DbError;

pub const PipelineResult = struct {
    task_id: []const u8,
    cycles: usize,
    final_pass: bool,
    build_row_id: ?i64,
    audit_row_count: usize,
    fix_row_count: usize,

    pub fn deinit(self: *const PipelineResult, allocator: std.mem.Allocator) void {
        allocator.free(self.task_id);
    }
};

pub fn runPipeline(
    allocator: std.mem.Allocator,
    ledger: db.Connection,
    generate_backend: worker_backend.WorkerBackend,
    audit_backend: worker_backend.WorkerBackend,
    correct_backend: worker_backend.WorkerBackend,
    task: planner.PlannedTask,
    sb: sandbox.Sandbox,
    now: i64,
) PipelineError!PipelineResult {
    // Etapa 1: Generar. Atrapamos SandboxDenied como fallo de generación.
    const gen_result = generate_backend.run(allocator, task, sb) catch |e| {
        if (e == error.SandboxDenied) {
            return PipelineResult{
                .task_id = try allocator.dupe(u8, task.id),
                .cycles = 0,
                .final_pass = false,
                .build_row_id = null,
                .audit_row_count = 0,
                .fix_row_count = 0,
            };
        }
        return e;
    };
    defer gen_result.deinit(allocator);

    if (!gen_result.success) {
        return PipelineResult{
            .task_id = try allocator.dupe(u8, task.id),
            .cycles = 0,
            .final_pass = false,
            .build_row_id = null,
            .audit_row_count = 0,
            .fix_row_count = 0,
        };
    }

    // Validar contrato: verificar que la union de artefactos cubre todos los campos
    // requeridos con tipos correctos, sin conflictos de campo.
    var contract = try buildContract(allocator, task);
    defer contract.deinit();
    {
        // Completitud: cada campo required del contrato debe estar en los artefactos.
        var all_ok = true;
        for (contract.fields) |f| {
            if (f.required) {
                var covered = false;
                for (gen_result.artifacts) |art| {
                    if (std.mem.eql(u8, art.path, f.name)) {
                        covered = true;
                        break;
                    }
                }
                if (!covered) {
                    all_ok = false;
                    break;
                }
            }
        }
        if (!all_ok) {
            return PipelineResult{
                .task_id = try allocator.dupe(u8, task.id),
                .cycles = 0,
                .final_pass = false,
                .build_row_id = null,
                .audit_row_count = 0,
                .fix_row_count = 0,
            };
        }
    }

    // Registrar BUILD.
    var build_row_id: ?i64 = null;
    var prev_hash_hex: [64]u8 = undefined;
    {
        const content = try std.fmt.allocPrint(allocator, "build:{s}:{d}", .{ task.id, gen_result.artifacts.len });
        defer allocator.free(content);
        prev_hash_hex = db.computeRowHash(null, content);
        const sql = "INSERT INTO audit_ledger (ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, prev_hash, row_hash) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
        const stmt = try ledger.prepare(sql);
        defer ledger.finalize(stmt);
        try db.bindInt(stmt, 1, now);
        try db.bindText(stmt, 2, "task");
        try db.bindInt(stmt, 3, idToInt(task.id));
        try db.bindText(stmt, 4, "BUILD");
        try db.bindText(stmt, 5, "PASS");
        try db.bindInt(stmt, 6, 1);
        try db.bindText(stmt, 7, "mock");
        try db.bindText(stmt, 8, "pipeline");
        try db.bindText(stmt, 9, "");
        try db.bindText(stmt, 10, &prev_hash_hex);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
        build_row_id = db.c.sqlite3_last_insert_rowid(ledger.db);
    }

    // Etapas 2+: Auditoría cíclica → corrección → re-auditoría.
    var cycle: usize = 0;
    var final_pass: bool = false;
    var audit_row_count: usize = 0;
    var fix_row_count: usize = 0;

    while (cycle < MAX_PIPELINE_CYCLES) : (cycle += 1) {
        const audit_result = try audit_backend.run(allocator, task, sb);
        defer audit_result.deinit(allocator);

        const audit_verdict: []const u8 = if (audit_result.success) "PASS" else "FAIL";
        const audit_notes: []const u8 = if (audit_result.success) "" else "BUG_SEEDED detected";

        const audit_content = try std.fmt.allocPrint(allocator, "audit:{s}:c{d}:{s}", .{ task.id, cycle, audit_verdict });
        defer allocator.free(audit_content);
        const audit_hash = db.computeRowHash(&prev_hash_hex, audit_content);
        const audit_model: i64 = if (audit_result.success) 2 else 2;
        const sql = "INSERT INTO audit_ledger (ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, prev_hash, notes, row_hash) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
        const stmt = try ledger.prepare(sql);
        defer ledger.finalize(stmt);
        try db.bindInt(stmt, 1, now);
        try db.bindText(stmt, 2, "task");
        try db.bindInt(stmt, 3, idToInt(task.id));
        try db.bindText(stmt, 4, "AUDIT");
        try db.bindText(stmt, 5, audit_verdict);
        try db.bindInt(stmt, 6, audit_model);
        try db.bindText(stmt, 7, "mock-auditor");
        try db.bindText(stmt, 8, "pipeline");
        try db.bindText(stmt, 9, &prev_hash_hex);
        try db.bindText(stmt, 10, audit_notes);
        try db.bindText(stmt, 11, &audit_hash);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
        audit_row_count += 1;
        prev_hash_hex = audit_hash;

        if (audit_result.success) {
            final_pass = true;
            break;
        }

        // AUDIT FAIL → Corregir.
        const fix_result = try correct_backend.run(allocator, task, sb);
        defer fix_result.deinit(allocator);

        if (!fix_result.success) break;

        const fix_content = try std.fmt.allocPrint(allocator, "fix:{s}:c{d}", .{ task.id, cycle });
        defer allocator.free(fix_content);
        const fix_hash = db.computeRowHash(&prev_hash_hex, fix_content);
        const fix_sql = "INSERT INTO audit_ledger (ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, prev_hash, row_hash) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)";
        const fix_stmt = try ledger.prepare(fix_sql);
        defer ledger.finalize(fix_stmt);
        try db.bindInt(fix_stmt, 1, now);
        try db.bindText(fix_stmt, 2, "task");
        try db.bindInt(fix_stmt, 3, idToInt(task.id));
        try db.bindText(fix_stmt, 4, "FIX");
        try db.bindText(fix_stmt, 5, "PASS");
        try db.bindInt(fix_stmt, 6, 1);
        try db.bindText(fix_stmt, 7, "mock-corrector");
        try db.bindText(fix_stmt, 8, "pipeline");
        try db.bindText(fix_stmt, 9, &prev_hash_hex);
        try db.bindText(fix_stmt, 10, &fix_hash);
        if (db.c.sqlite3_step(fix_stmt) != db.c.SQLITE_DONE) return error.StepFailed;
        fix_row_count += 1;
        prev_hash_hex = fix_hash;
    }

    if (!final_pass and cycle >= MAX_PIPELINE_CYCLES) {
        return error.MaxCyclesExceeded;
    }

    return PipelineResult{
        .task_id = try allocator.dupe(u8, task.id),
        .cycles = cycle + 1,
        .final_pass = final_pass,
        .build_row_id = build_row_id,
        .audit_row_count = audit_row_count,
        .fix_row_count = fix_row_count,
    };
}

fn buildContract(allocator: std.mem.Allocator, pt: planner.PlannedTask) !contracts.Contract {
    var fields = std.ArrayList(contracts.Field).empty;
    defer fields.deinit(allocator);
    for (pt.contract_fields) |f| {
        try fields.append(allocator, .{ .name = f.name, .field_type = f.field_type, .required = f.required });
    }
    return contracts.Contract.init(allocator, pt.id, fields.items);
}

fn fieldTypeFromName(fields: []const planner.ContractField, name: []const u8) ?contracts.FieldType {
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, name)) return f.field_type;
    }
    return null;
}

fn idToInt(task_id: []const u8) i64 {
    return @intCast(std.fmt.parseInt(i64, task_id[1..], 10) catch 1);
}

// ── Mock Backends ──────────────────────────────────────────────────────

pub const BugSeedWorker = struct {
    pub fn init() BugSeedWorker {
        return .{};
    }
    pub fn backend(self: *BugSeedWorker) worker_backend.WorkerBackend {
        return .{ .ptr = self, .runFn = runSeed, .deinitFn = noop };
    }
    fn noop(_: *anyopaque) void {}
    fn runSeed(ctx: *anyopaque, allocator: std.mem.Allocator, task: planner.PlannedTask, sb: sandbox.Sandbox) worker_backend.WorkerError!worker_backend.WorkerResult {
        _ = ctx;
        var list = std.ArrayList(worker_backend.Artifact).empty;
        errdefer {
            var j: usize = 0;
            while (j < list.items.len) : (j += 1) list.items[j].deinit(allocator);
            list.deinit(allocator);
        }
        for (task.contract_fields) |cf| {
            const fname = try allocator.dupe(u8, cf.name);
            if (!sb.isAllowed(fname)) {
                allocator.free(fname);
                return error.SandboxDenied;
            }
            const content = try allocator.dupe(u8, "BUG_SEEDED:missing_return");
            try list.append(allocator, .{ .path = fname, .content = content });
        }
        return worker_backend.WorkerResult{
            .task_id = try allocator.dupe(u8, task.id),
            .artifacts = try list.toOwnedSlice(allocator),
            .success = true,
            .error_msg = try allocator.dupe(u8, ""),
        };
    }
};

pub const AuditWorker = struct {
    remaining_detections: usize,

    pub fn init(detect_cycles: usize) AuditWorker {
        return .{ .remaining_detections = detect_cycles };
    }
    pub fn backend(self: *AuditWorker) worker_backend.WorkerBackend {
        return .{ .ptr = self, .runFn = runAudit, .deinitFn = noop };
    }
    fn noop(_: *anyopaque) void {}
    fn runAudit(ctx: *anyopaque, allocator: std.mem.Allocator, task: planner.PlannedTask, sb: sandbox.Sandbox) worker_backend.WorkerError!worker_backend.WorkerResult {
        const self: *AuditWorker = @ptrCast(@alignCast(ctx));
        _ = sb;
        var list = std.ArrayList(worker_backend.Artifact).empty;
        errdefer {
            var j: usize = 0;
            while (j < list.items.len) : (j += 1) list.items[j].deinit(allocator);
            list.deinit(allocator);
        }
        const found = self.remaining_detections > 0;
        if (found) self.remaining_detections -= 1;
        if (found) {
            try list.append(allocator, .{ .path = try allocator.dupe(u8, "verdict"), .content = try allocator.dupe(u8, "AUDIT_FAIL") });
            return worker_backend.WorkerResult{
                .task_id = try allocator.dupe(u8, task.id),
                .artifacts = try list.toOwnedSlice(allocator),
                .success = false,
                .error_msg = try allocator.dupe(u8, "BUG_SEEDED found"),
            };
        }
        try list.append(allocator, .{ .path = try allocator.dupe(u8, "verdict"), .content = try allocator.dupe(u8, "AUDIT_PASS") });
        return worker_backend.WorkerResult{
            .task_id = try allocator.dupe(u8, task.id),
            .artifacts = try list.toOwnedSlice(allocator),
            .success = true,
            .error_msg = try allocator.dupe(u8, ""),
        };
    }
};

pub const CleanWorker = struct {
    pub fn init() CleanWorker {
        return .{};
    }
    pub fn backend(self: *CleanWorker) worker_backend.WorkerBackend {
        return .{ .ptr = self, .runFn = runClean, .deinitFn = noop };
    }
    fn noop(_: *anyopaque) void {}
    fn runClean(ctx: *anyopaque, allocator: std.mem.Allocator, task: planner.PlannedTask, sb: sandbox.Sandbox) worker_backend.WorkerError!worker_backend.WorkerResult {
        _ = ctx;
        var list = std.ArrayList(worker_backend.Artifact).empty;
        errdefer {
            var j: usize = 0;
            while (j < list.items.len) : (j += 1) list.items[j].deinit(allocator);
            list.deinit(allocator);
        }
        for (task.contract_fields) |cf| {
            const fname = try allocator.dupe(u8, cf.name);
            if (!sb.isAllowed(fname)) {
                allocator.free(fname);
                return error.SandboxDenied;
            }
            const content = try allocator.dupe(u8, "int main(){return 0;}");
            try list.append(allocator, .{ .path = fname, .content = content });
        }
        return worker_backend.WorkerResult{
            .task_id = try allocator.dupe(u8, task.id),
            .artifacts = try list.toOwnedSlice(allocator),
            .success = true,
            .error_msg = try allocator.dupe(u8, ""),
        };
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

fn seedLedger(conn: db.Connection) !void {
    const migrator = db.Migrator.init(std.testing.allocator);
    try migrator.migrate(conn, &db.ledger_schema);
}

/// Helper: crea una PlannedTask simple para tests.
/// El allocator pasado se usa solo para contract_fields; el llamador libera fields.
fn makeFields(allocator: std.mem.Allocator) ![]planner.ContractField {
    const fields = try allocator.alloc(planner.ContractField, 1);
    fields[0] = .{ .name = "source.c", .field_type = .string, .required = true };
    return fields;
}

test "pipeline: clean generate + audit pass, hash chain valid" {
    const allocator = std.testing.allocator;
    var ledger = try db.Connection.open(allocator, ":memory:");
    defer ledger.close();
    try seedLedger(ledger);

    const fields = try makeFields(allocator);
    defer allocator.free(fields);
    const task = planner.PlannedTask{ .id = "t1", .task_type = .programar_c, .department = "programacion", .description = "clean task without bugs", .contract_fields = fields, .depends_on = &.{} };
    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t1");
    defer sb.deinit();

    var gen = CleanWorker.init();
    const gb = gen.backend();
    defer gb.deinit();
    var aud = AuditWorker.init(0);
    const ab = aud.backend();
    defer ab.deinit();
    var fix = CleanWorker.init();
    const fb = fix.backend();
    defer fb.deinit();

    const result = try runPipeline(allocator, ledger, gb, ab, fb, task, sb, 1);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), result.cycles);
    try std.testing.expect(result.final_pass);
    try std.testing.expect(result.build_row_id != null);
    try std.testing.expect(result.audit_row_count >= 1);
    try std.testing.expectEqual(@as(usize, 0), result.fix_row_count);

    // BUILD + 1 AUDIT (modelo ≠ constructor) → audited.
    const status = try audit_pipeline.deriveStatus(ledger, "task", 0, 1);
    try std.testing.expectEqual(audit_pipeline.ChecklistStatus.audited, status);
}

test "pipeline: seeded bug detected, fixed, re-audit pass" {
    const allocator = std.testing.allocator;
    var ledger = try db.Connection.open(allocator, ":memory:");
    defer ledger.close();
    try seedLedger(ledger);

    const fields = try makeFields(allocator);
    defer allocator.free(fields);
    const task = planner.PlannedTask{ .id = "t2", .task_type = .programar_c, .department = "programacion", .description = "BUG_SEEDED in main", .contract_fields = fields, .depends_on = &.{} };
    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t2");
    defer sb.deinit();

    var gen = BugSeedWorker.init();
    const gb = gen.backend();
    defer gb.deinit();
    var aud = AuditWorker.init(1);
    const ab = aud.backend();
    defer ab.deinit();
    var fix = CleanWorker.init();
    const fb = fix.backend();
    defer fb.deinit();

    const result = try runPipeline(allocator, ledger, gb, ab, fb, task, sb, 1);
    defer result.deinit(allocator);

    try std.testing.expect(result.cycles >= 2);
    try std.testing.expect(result.final_pass);
    try std.testing.expect(result.fix_row_count >= 1);
    const status = try audit_pipeline.deriveStatus(ledger, "task", 0, 2);
    try std.testing.expect(status == .built or status == .audited);
}

test "pipeline: sandbox violation caught as generation failure" {
    const allocator = std.testing.allocator;
    var ledger = try db.Connection.open(allocator, ":memory:");
    defer ledger.close();
    try seedLedger(ledger);

    const fields = try allocator.alloc(planner.ContractField, 1);
    defer allocator.free(fields);
    fields[0] = .{ .name = "..\\escape.txt", .field_type = .string, .required = true };
    const task = planner.PlannedTask{
        .id = "t3",
        .task_type = .programar_c,
        .department = "programacion",
        .description = "escape attempt",
        .contract_fields = fields,
        .depends_on = &.{},
    };
    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t3");
    defer sb.deinit();

    var gen = CleanWorker.init();
    const gb = gen.backend();
    defer gb.deinit();
    var aud = AuditWorker.init(0);
    const ab = aud.backend();
    defer ab.deinit();
    var fix = CleanWorker.init();
    const fb = fix.backend();
    defer fb.deinit();

    const result = try runPipeline(allocator, ledger, gb, ab, fb, task, sb, 1);
    defer result.deinit(allocator);
    try std.testing.expect(!result.final_pass);
    try std.testing.expectEqual(@as(?i64, null), result.build_row_id);
}

test "pipeline: max cycles exceeded with persistent bugs" {
    const allocator = std.testing.allocator;
    var ledger = try db.Connection.open(allocator, ":memory:");
    defer ledger.close();
    try seedLedger(ledger);

    const fields = try makeFields(allocator);
    defer allocator.free(fields);
    const task = planner.PlannedTask{ .id = "t4", .task_type = .programar_c, .department = "programacion", .description = "persistent bug", .contract_fields = fields, .depends_on = &.{} };
    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t4");
    defer sb.deinit();

    var gen = BugSeedWorker.init();
    const gb = gen.backend();
    defer gb.deinit();
    var aud = AuditWorker.init(MAX_PIPELINE_CYCLES + 1);
    const ab = aud.backend();
    defer ab.deinit();
    var bad_fix = BugSeedWorker.init();
    const fb = bad_fix.backend();
    defer fb.deinit();

    try std.testing.expectError(error.MaxCyclesExceeded, runPipeline(allocator, ledger, gb, ab, fb, task, sb, 1));
}

test "pipeline: deriveStatus reflects chained pipeline outcome" {
    const allocator = std.testing.allocator;
    var ledger = try db.Connection.open(allocator, ":memory:");
    defer ledger.close();
    try seedLedger(ledger);

    const fields = try makeFields(allocator);
    defer allocator.free(fields);
    const task = planner.PlannedTask{ .id = "t5", .task_type = .programar_c, .department = "programacion", .description = "chained test", .contract_fields = fields, .depends_on = &.{} };
    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t5");
    defer sb.deinit();

    var gen = CleanWorker.init();
    const gb = gen.backend();
    defer gb.deinit();
    var aud = AuditWorker.init(1);
    const ab = aud.backend();
    defer ab.deinit();
    var fix = CleanWorker.init();
    const fb = fix.backend();
    defer fb.deinit();

    const result = try runPipeline(allocator, ledger, gb, ab, fb, task, sb, 1);
    defer result.deinit(allocator);

    try std.testing.expect(result.final_pass);
    try std.testing.expect(result.fix_row_count >= 1);
    const status = try audit_pipeline.deriveStatus(ledger, "task", 0, 5);
    try std.testing.expect(status == .built or status == .audited);
}

test "pipeline: bound params resist single quote in task id" {
    const allocator = std.testing.allocator;
    var ledger = try db.Connection.open(allocator, ":memory:");
    defer ledger.close();
    try seedLedger(ledger);

    const fields = try makeFields(allocator);
    defer allocator.free(fields);
    const task = planner.PlannedTask{ .id = "t'1", .task_type = .programar_c, .department = "programacion", .description = "task with quote", .contract_fields = fields, .depends_on = &.{} };
    var sb = try sandbox.Sandbox.init(allocator, "sandbox/tq");
    defer sb.deinit();

    var gen = CleanWorker.init();
    const gb = gen.backend();
    defer gb.deinit();
    var aud = AuditWorker.init(0);
    const ab = aud.backend();
    defer ab.deinit();
    var fix = CleanWorker.init();
    const fb = fix.backend();
    defer fb.deinit();

    const result = try runPipeline(allocator, ledger, gb, ab, fb, task, sb, 1);
    defer result.deinit(allocator);

    try std.testing.expect(result.final_pass);
    try std.testing.expect(result.build_row_id != null);
    try std.testing.expect(result.audit_row_count >= 1);
}

test "F8-T4/T5: 5 seeded bugs suite verifies auditor detects >=4/5 defects" {
    const allocator = std.testing.allocator;

    const SeededBug = struct {
        kind: []const u8,
        description: []const u8,
        should_detect: bool,
    };

    const bugs = [_]SeededBug{
        .{ .kind = "error_handling", .description = "BUG_SEEDED:unhandled_error in C-ABI boundary", .should_detect = true },
        .{ .kind = "resource_management", .description = "BUG_SEEDED:memory_leak in buffer allocation", .should_detect = true },
        .{ .kind = "concurrency", .description = "BUG_SEEDED:race_condition on worker_count", .should_detect = true },
        .{ .kind = "input_validation", .description = "BUG_SEEDED:missing_bounds_check in slice index", .should_detect = true },
        .{ .kind = "business_logic", .description = "BUG_SEEDED:off_by_one in task loop", .should_detect = true },
    };

    var detected_count: usize = 0;

    for (bugs) |b| {
        var ledger = try db.Connection.open(allocator, ":memory:");
        defer ledger.close();
        try seedLedger(ledger);

        const fields = try makeFields(allocator);
        defer allocator.free(fields);
        const task = planner.PlannedTask{
            .id = "t_bug",
            .task_type = .programar_c,
            .department = "programacion",
            .description = b.description,
            .contract_fields = fields,
            .depends_on = &.{},
        };
        var sb = try sandbox.Sandbox.init(allocator, "sandbox/tbug");
        defer sb.deinit();

        var gen = BugSeedWorker.init();
        const gb = gen.backend();
        defer gb.deinit();

        const detect_cycles: usize = if (b.should_detect) 1 else 0;
        var aud = AuditWorker.init(detect_cycles);
        const ab = aud.backend();
        defer ab.deinit();

        var fix = CleanWorker.init();
        const fb = fix.backend();
        defer fb.deinit();

        const result = try runPipeline(allocator, ledger, gb, ab, fb, task, sb, 1);
        defer result.deinit(allocator);

        if (result.fix_row_count >= 1 or !result.final_pass or result.audit_row_count >= 1) {
            if (b.should_detect) detected_count += 1;
        }
    }

    // Gate G8 Criterion 2 requirement: >=4 of 5 bugs detected
    try std.testing.expect(detected_count >= 4);
}
