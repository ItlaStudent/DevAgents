//! additive role pins, using the existing {provider,model} contract.
const std = @import("std");
const db = @import("db.zig");

pub const Pin = struct { role: []const u8, provider: []const u8, model: []const u8 };
pub const key = "composer_role_pins_v1";

pub fn reviewMode(executor_p: ?[]const u8, executor_m: ?[]const u8, audit_p: ?[]const u8, audit_m: ?[]const u8) []const u8 {
    if (executor_p == null or executor_m == null or audit_p == null or audit_m == null) return "self_reviewed";
    if (executor_m.?.len == 0 or audit_m.?.len == 0 or
        std.mem.eql(u8, executor_m.?, audit_m.?) or
        @import("external_agents.zig").crossModelManufacturerExcluded(executor_p.?, executor_m.?, audit_p.?, audit_m.?)) return "self_reviewed";
    return "independent_pending";
}

pub fn reviewLabel(mode: []const u8) []const u8 {
    if (std.mem.eql(u8, mode, "self_reviewed")) return "Autorrevisada";
    if (std.mem.eql(u8, mode, "independent_pending")) return "Auditor independiente asignado";
    return "Revisión por decidir";
}

/// Call only after routing. Pins cannot establish what an order will use.
pub fn effectiveReview(tasks: anytype, assignments: anytype) []const u8 {
    var producers: usize = 0;
    for (tasks) |task| {
        if (task.task_type == .auditar) continue;
        var assigned = false;
        for (assignments) |assignment| {
            if (std.mem.eql(u8, assignment.task_id, task.id) and assignment.assigned) assigned = true;
        }
        if (!assigned) return "undecided";
        producers += 1;
    }
    if (producers == 0) return "undecided";
    for (tasks) |audit_task| {
        if (audit_task.task_type != .auditar) continue;
        for (assignments) |auditor| {
            if (!auditor.assigned or !std.mem.eql(u8, auditor.task_id, audit_task.id)) continue;
            var independent = true;
            for (tasks) |producer_task| {
                if (producer_task.task_type == .auditar) continue;
                for (assignments) |producer| {
                    if (!producer.assigned or !std.mem.eql(u8, producer.task_id, producer_task.id)) continue;
                    if (!std.mem.eql(u8, reviewMode(producer.provider_name, producer.model_name, auditor.provider_name, auditor.model_name), "independent_pending")) independent = false;
                }
            }
            if (independent) return "independent_pending";
        }
    }
    return "self_reviewed";
}

pub fn persistReview(a: std.mem.Allocator, runtime: db.Connection, order_id: i64, tasks: anytype, assignments: anytype) !void {
    if (order_id <= 0) return;
    const mode = effectiveReview(tasks, assignments);
    const json = try std.json.Stringify.valueAlloc(a, .{ .mode = mode, .label = reviewLabel(mode), .pending_verdict = true }, .{});
    defer a.free(json);
    const q = try runtime.prepare("INSERT INTO events(ts,source,kind,payload_json,order_id) VALUES(?,'superagente','composer_review_v1',?,?)");
    defer runtime.finalize(q);
    try db.bindInt(q, 1, @import("health.zig").nowMillis(runtime));
    try db.bindText(q, 2, json);
    try db.bindInt(q, 3, order_id);
    if (db.c.sqlite3_step(q) != db.c.SQLITE_DONE) return error.StepFailed;
}

pub fn setSwarmEnabled(catalog: db.Connection, enabled: bool) !void {
    const q = try catalog.prepare("INSERT INTO settings(key,value) VALUES('composer_swarm_enabled_v1',?) ON CONFLICT(key) DO UPDATE SET value=excluded.value");
    defer catalog.finalize(q);
    try db.bindText(q, 1, if (enabled) "true" else "false");
    if (db.c.sqlite3_step(q) != db.c.SQLITE_DONE) return error.StepFailed;
}

pub fn swarmEnabled(catalog: db.Connection) !bool {
    const q = try catalog.prepare("SELECT value FROM settings WHERE key='composer_swarm_enabled_v1'");
    defer catalog.finalize(q);
    return switch (db.c.sqlite3_step(q)) {
        db.c.SQLITE_ROW => std.mem.eql(u8, std.mem.span(db.c.sqlite3_column_text(q, 0)), "true"),
        db.c.SQLITE_DONE => true,
        else => error.StepFailed,
    };
}

pub fn swarmForOrder(runtime: db.Connection, catalog: db.Connection, order_id: i64) !bool {
    if (order_id <= 0) return swarmEnabled(catalog);
    const q = try runtime.prepare("SELECT payload_json FROM events WHERE order_id=? AND kind='composer_swarm_v1' ORDER BY id LIMIT 1");
    defer runtime.finalize(q);
    try db.bindInt(q, 1, order_id);
    const rc = db.c.sqlite3_step(q);
    if (rc == db.c.SQLITE_ROW) return std.mem.eql(u8, std.mem.span(db.c.sqlite3_column_text(q, 0)), "true");
    if (rc != db.c.SQLITE_DONE) return error.StepFailed;
    const enabled = try swarmEnabled(catalog);
    const insert = try runtime.prepare("INSERT INTO events(ts,source,kind,payload_json,order_id) VALUES(0,'usuario','composer_swarm_v1',?,?)");
    defer runtime.finalize(insert);
    try db.bindText(insert, 1, if (enabled) "true" else "false");
    try db.bindInt(insert, 2, order_id);
    if (db.c.sqlite3_step(insert) != db.c.SQLITE_DONE) return error.StepFailed;
    return enabled;
}

pub fn validRole(role: []const u8) bool {
    for ([_][]const u8{ "second_audit", "programmer", "sidekick" }) |r|
        if (std.mem.eql(u8, role, r)) return true;
    return false;
}

pub fn read(a: std.mem.Allocator, catalog: db.Connection) ![]u8 {
    const q = try catalog.prepare("SELECT value FROM settings WHERE key=?");
    defer catalog.finalize(q);
    try db.bindText(q, 1, key);
    return switch (db.c.sqlite3_step(q)) {
        db.c.SQLITE_ROW => a.dupe(u8, std.mem.span(db.c.sqlite3_column_text(q, 0))),
        db.c.SQLITE_DONE => a.dupe(u8, "[]"),
        else => error.StepFailed,
    };
}

pub fn set(a: std.mem.Allocator, catalog: db.Connection, role: []const u8, provider: []const u8, model: []const u8) !void {
    if (!validRole(role)) return error.InvalidRole;
    if ((provider.len == 0) != (model.len == 0) or provider.len > 256 or model.len > 1024 or
        !std.unicode.utf8ValidateSlice(provider) or !std.unicode.utf8ValidateSlice(model)) return error.InvalidPin;
    const before = try read(a, catalog);
    defer a.free(before);
    const parsed = try std.json.parseFromSlice([]Pin, a, before, .{});
    defer parsed.deinit();
    var pins: std.ArrayList(Pin) = .empty;
    defer pins.deinit(a);
    for (parsed.value) |pin| if (!std.mem.eql(u8, pin.role, role)) try pins.append(a, pin);
    if (provider.len > 0) try pins.append(a, .{ .role = role, .provider = provider, .model = model });
    const json = try std.json.Stringify.valueAlloc(a, pins.items, .{});
    defer a.free(json);
    const q = try catalog.prepare("INSERT INTO settings(key,value) VALUES(?,?) ON CONFLICT(key) DO UPDATE SET value=excluded.value");
    defer catalog.finalize(q);
    try db.bindText(q, 1, key);
    try db.bindText(q, 2, json);
    if (db.c.sqlite3_step(q) != db.c.SQLITE_DONE) return error.StepFailed;
}

/// Persist the first selection for this order, including an empty selection.
/// Later changes to the composer cannot alter an approved or resumed order.
pub fn forOrder(a: std.mem.Allocator, runtime: db.Connection, catalog: db.Connection, order_id: i64) ![]u8 {
    if (order_id <= 0) return read(a, catalog);
    const q = try runtime.prepare("SELECT payload_json FROM events WHERE order_id=? AND kind='composer_roles_v1' ORDER BY id LIMIT 1");
    defer runtime.finalize(q);
    try db.bindInt(q, 1, order_id);
    const rc = db.c.sqlite3_step(q);
    if (rc == db.c.SQLITE_ROW) return a.dupe(u8, std.mem.span(db.c.sqlite3_column_text(q, 0)));
    if (rc != db.c.SQLITE_DONE) return error.StepFailed;
    const json = try read(a, catalog);
    errdefer a.free(json);
    const insert = try runtime.prepare("INSERT INTO events(ts,source,kind,payload_json,order_id) VALUES(0,'usuario','composer_roles_v1',?,?)");
    defer runtime.finalize(insert);
    try db.bindText(insert, 1, json);
    try db.bindInt(insert, 2, order_id);
    if (db.c.sqlite3_step(insert) != db.c.SQLITE_DONE) return error.StepFailed;
    return json;
}

test "CK-PRV-003 C2: role pins roundtrip remove validation and immutable order" {
    const a = std.testing.allocator;
    var catalog = try db.Connection.open(a, ":memory:");
    defer catalog.close();
    var runtime = try db.Connection.open(a, ":memory:");
    defer runtime.close();
    var m = db.Migrator.init(a);
    try m.migrate(catalog, &db.catalog_schema);
    try m.migrate(runtime, &db.runtime_schema);
    try runtime.exec("INSERT INTO orders(id,project_id,user_prompt,status,created_at) VALUES(1,'p','x','pending',0)");
    try set(a, catalog, "programmer", "p", "m");
    try setSwarmEnabled(catalog, true);
    try std.testing.expect(try swarmForOrder(runtime, catalog, 1));
    try setSwarmEnabled(catalog, false);
    try std.testing.expect(!try swarmEnabled(catalog));
    try std.testing.expect(try swarmForOrder(runtime, catalog, 1));
    try set(a, catalog, "second_audit", "q", "n");
    const first = try forOrder(a, runtime, catalog, 1);
    defer a.free(first);
    try set(a, catalog, "programmer", "", "");
    const captured = try forOrder(a, runtime, catalog, 1);
    defer a.free(captured);
    try std.testing.expectEqualStrings(first, captured);
    const live = try read(a, catalog);
    defer a.free(live);
    try std.testing.expect(std.mem.indexOf(u8, live, "programmer") == null);
    try std.testing.expectError(error.InvalidRole, set(a, catalog, "unknown", "p", "m"));
    try std.testing.expectError(error.InvalidPin, set(a, catalog, "sidekick", "p", ""));
}

test "CK-PRV-003 C3: review configuration never calls one model audited" {
    try std.testing.expectEqualStrings("self_reviewed", reviewMode("GPT", "gpt-6-sol", "GPT", "gpt-6-sol"));
    try std.testing.expectEqualStrings("self_reviewed", reviewMode("GPT", "gpt-6-sol", null, null));
    try std.testing.expectEqualStrings("self_reviewed", reviewMode("GPT", "gpt-6-sol", "agent:codex", "gpt-6-luna"));
    try std.testing.expectEqualStrings("independent_pending", reviewMode("GPT", "gpt-6-sol", "Anthropic", "claude-fixture"));
}

test "CK-PRV-003 P1-a: effective review neutral pending routing and checks every producer" {
    const Task = struct { id: []const u8, task_type: enum { programar, auditar } };
    const Assignment = struct { task_id: []const u8, assigned: bool = true, provider_name: []const u8 = "OpenRouter", model_name: []const u8 };
    const tasks = [_]Task{ .{ .id = "build", .task_type = .programar }, .{ .id = "audit", .task_type = .auditar } };
    const assignments = [_]Assignment{ .{ .task_id = "build", .model_name = "gpt-fixture" }, .{ .task_id = "audit", .model_name = "claude-fixture" } };
    try std.testing.expectEqualStrings("undecided", effectiveReview(&tasks, &[_]Assignment{}));
    try std.testing.expectEqualStrings("undecided", effectiveReview(&[_]Task{}, &assignments));
    try std.testing.expectEqualStrings("independent_pending", effectiveReview(&tasks, &assignments));
    try std.testing.expectEqualStrings("self_reviewed", effectiveReview(&tasks, assignments[0..1]));
    var same = assignments;
    same[1].model_name = "gpt-fixture";
    same[1].provider_name = "another-provider";
    try std.testing.expectEqualStrings("self_reviewed", effectiveReview(&tasks, &same));
    same[1].assigned = false;
    try std.testing.expectEqualStrings("self_reviewed", effectiveReview(&tasks, &same));
    const multi_tasks = tasks ++ [_]Task{.{ .id = "other", .task_type = .programar }};
    const multi_assignments = assignments ++ [_]Assignment{.{ .task_id = "other", .model_name = "claude-fixture" }};
    try std.testing.expectEqualStrings("self_reviewed", effectiveReview(&multi_tasks, &multi_assignments));
    try std.testing.expectEqualStrings("Revisión por decidir", reviewLabel("undecided"));
}
