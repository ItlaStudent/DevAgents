//!. Read-only local quota adapters. Native formats UNVERIFIED:
//! the repository contains no authoritative Codex/Claude quota samples.
//! Sources are explicitly configured via cli_quota_<cli>_source settings;
//! never discover profiles, credentials or network endpoints here.
const std = @import("std");
const db = @import("db.zig");
const health = @import("health.zig");

pub const Cli = enum { codex, @"claude-code" };
pub const Window = struct {
    used_percent: ?f64 = null,
    reset_at: ?i64 = null,
};
pub const Snapshot = struct {
    cli: Cli,
    format: []const u8 = "sin verificar",
    status: []const u8 = "desconocido",
    five_hour: Window = .{},
    daily: Window = .{},
    weekly: Window = .{},

    pub fn blocked(self: Snapshot) bool {
        for ([_]Window{ self.five_hour, self.daily, self.weekly }) |w| {
            if ((w.used_percent orelse continue) >= 100) return true;
        }
        return false;
    }
};

fn field(v: std.json.Value, key: []const u8) std.json.Value {
    return if (v == .object) v.object.get(key) orelse .null else .null;
}

fn number(v: std.json.Value) ?f64 {
    return switch (v) {
        .integer => @floatFromInt(v.integer),
        .float => v.float,
        else => null,
    };
}

// ISO 8601 UTC (the fixture adapter contract), plus Unix seconds. Other
// encodings remain unknown rather than inventing a reset time.
fn timestamp(v: std.json.Value) ?i64 {
    if (v == .integer) return if (v.integer > 0 and v.integer <= 4133980800) v.integer else null;
    if (v != .string) return null;
    const s = v.string;
    if (s.len != 20 or s[4] != '-' or s[7] != '-' or s[10] != 'T' or s[13] != ':' or s[16] != ':' or s[19] != 'Z') return null;
    const year = std.fmt.parseInt(u16, s[0..4], 10) catch return null;
    const month = std.fmt.parseInt(u8, s[5..7], 10) catch return null;
    const day = std.fmt.parseInt(u8, s[8..10], 10) catch return null;
    const hour = std.fmt.parseInt(u8, s[11..13], 10) catch return null;
    const minute = std.fmt.parseInt(u8, s[14..16], 10) catch return null;
    const second = std.fmt.parseInt(u8, s[17..19], 10) catch return null;
    if (year < 1970 or year > 2100 or month < 1 or month > 12 or hour > 23 or minute > 59 or second > 59) return null;
    const days_in_month = [_]u8{ 31, if (leap(year)) 29 else 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
    if (day < 1 or day > days_in_month[month - 1]) return null;
    var days: i64 = day - 1;
    for (1970..year) |y| days += if (leap(y)) @as(i64, 366) else 365;
    for (days_in_month[0 .. month - 1]) |d| days += d;
    return days * 86400 + @as(i64, hour) * 3600 + @as(i64, minute) * 60 + second;
}

fn leap(year: usize) bool {
    return year % 4 == 0 and (year % 100 != 0 or year % 400 == 0);
}

fn window(v: std.json.Value, percent_key: []const u8, reset_key: []const u8, now: i64) Window {
    const percent = number(field(v, percent_key)) orelse return .{};
    if (!std.math.isFinite(percent) or percent < 0 or percent > 100) return .{};
    const reset = timestamp(field(v, reset_key));
    // An expired sample is unknown, never an invented 0 %.
    if (reset != null and reset.? <= now) return .{};
    return .{ .used_percent = percent, .reset_at = reset };
}

pub fn parse(a: std.mem.Allocator, cli: Cli, bytes: []const u8, now: i64) !Snapshot {
    var result: Snapshot = .{ .cli = cli };
    if (bytes.len > 1024 * 1024) return result;
    var lines = std.mem.splitScalar(u8, bytes, '\n');
    while (lines.next()) |line| {
        if (std.mem.trim(u8, line, " \r\t").len == 0) continue;
        var p = std.json.parseFromSlice(std.json.Value, a, line, .{}) catch |e| switch (e) {
            error.OutOfMemory => return e,
            else => {
                result = .{ .cli = cli };
                continue;
            },
        };
        defer p.deinit();
        const root = p.value;
        var next: Snapshot = .{ .cli = cli };
        switch (cli) {
            .codex => {
                var limits = field(root, "rate_limits");
                if (limits == .null) limits = field(field(root, "payload"), "rate_limits");
                if (limits == .null) continue; // unrelated session event
                for ([_][]const u8{ "primary", "secondary", "daily" }) |key| {
                    const v = field(limits, key);
                    const duration = number(field(v, "window_minutes")) orelse continue;
                    const w = window(v, "used_percent", "resets_at", now);
                    if (duration == 300) next.five_hour = w else if (duration == 1440) next.daily = w else if (duration == 10080) next.weekly = w;
                }
            },
            .@"claude-code" => {
                next.five_hour = window(field(root, "five_hour"), "utilization", "resets_at", now);
                next.daily = window(field(root, "one_day"), "utilization", "resets_at", now);
                next.weekly = window(field(root, "seven_day"), "utilization", "resets_at", now);
            },
        }
        for ([_]Window{ next.five_hour, next.daily, next.weekly }) |w| {
            if (w.used_percent != null) {
                next.status = "disponible";
                break;
            }
        }
        result = next;
    }
    return result;
}

pub const ReadFn = *const fn (std.mem.Allocator, []const u8) anyerror![]u8;

fn readLocal(a: std.mem.Allocator, path: []const u8) ![]u8 {
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    return std.Io.Dir.cwd().readFileAlloc(threaded.io(), path, a, .limited(1024 * 1024));
}

pub fn load(a: std.mem.Allocator, conn: db.Connection, cli: Cli, now: i64, reader: ReadFn) !Snapshot {
    const key = try std.fmt.allocPrint(a, "cli_quota_{s}_source", .{@tagName(cli)});
    defer a.free(key);
    const q = try conn.prepare("SELECT value FROM settings WHERE key=?");
    defer conn.finalize(q);
    try db.bindText(q, 1, key);
    const rc = db.c.sqlite3_step(q);
    if (rc == db.c.SQLITE_DONE) return .{ .cli = cli };
    if (rc != db.c.SQLITE_ROW) return error.StepFailed;
    const path = std.mem.span(db.c.sqlite3_column_text(q, 0));
    if (path.len == 0 or path.len > 4096 or std.mem.indexOfScalar(u8, path, 0) != null) return .{ .cli = cli };
    const bytes = reader(a, path) catch |e| switch (e) {
        error.OutOfMemory => return e,
        else => return .{ .cli = cli },
    };
    defer a.free(bytes);
    return parse(a, cli, bytes, now);
}

pub fn current(a: std.mem.Allocator, conn: db.Connection, cli: Cli) !Snapshot {
    return load(a, conn, cli, health.nowSeconds(conn), readLocal);
}

pub fn allJson(a: std.mem.Allocator, conn: db.Connection) ![]u8 {
    return std.json.Stringify.valueAlloc(a, .{ .schema = "cli-quota.v1", .quotas = [_]Snapshot{ try current(a, conn, .codex), try current(a, conn, .@"claude-code") } }, .{});
}

pub fn reason(a: std.mem.Allocator, s: Snapshot) !?[]u8 {
    const names = [_][]const u8{ "5 h", "diaria", "semanal" };
    for ([_]Window{ s.five_hour, s.daily, s.weekly }, names) |w, name| {
        if ((w.used_percent orelse continue) < 100) continue;
        const display = if (s.cli == .codex) "Codex" else "Claude Code";
        if (w.reset_at) |reset| {
            const day = @mod(reset, 86400);
            return try std.fmt.allocPrint(a, "{s}: cuota de {s} agotada hasta las {d:0>2}:{d:0>2} UTC (reinicio Unix {d})", .{ display, name, @divTrunc(day, 3600), @divTrunc(@mod(day, 3600), 60), reset });
        }
        return try std.fmt.allocPrint(a, "{s}: cuota de {s} agotada; reinicio desconocido", .{ display, name });
    }
    return null;
}

// A fresh query at the actual dispatch boundary also covers manual pins.
// The caller returns the normal failed WorkerResult so its existing fallback
// chain proceeds. No process is started, and the reason remains observable.
pub fn dispatchBlock(a: std.mem.Allocator, catalog: ?db.Connection, events: ?db.Connection, order_id: i64, provider: []const u8) ?[]u8 {
    const cli = cliForProvider(provider) orelse return null;
    const conn = catalog orelse return null;
    const s = current(a, conn, cli) catch |e| {
        std.log.warn("quota read failed: {s}", .{@errorName(e)});
        return null;
    };
    publish(a, events, order_id, s) catch |e| std.log.warn("quota event failed: {s}", .{@errorName(e)});
    return reason(a, s) catch |e| {
        std.log.err("quota reason failed: {s}", .{@errorName(e)});
        return a.dupe(u8, "CLI: cuota agotada; reinicio desconocido") catch null;
    };
}

pub fn cliForProvider(provider: []const u8) ?Cli {
    if (std.mem.eql(u8, provider, "agent:codex")) return .codex;
    if (std.mem.eql(u8, provider, "agent:claude-code")) return .@"claude-code";
    return null;
}

pub fn publish(a: std.mem.Allocator, events: ?db.Connection, order_id: i64, s: Snapshot) !void {
    const conn = events orelse return;
    var warn = false;
    for ([_]Window{ s.five_hour, s.daily, s.weekly }) |w| {
        if ((w.used_percent orelse continue) >= 80) warn = true;
    }
    if (!warn) return;
    const why = try reason(a, s);
    defer if (why) |v| a.free(v);
    const body = try std.json.Stringify.valueAlloc(a, .{ .schema = "cli-quota.v1", .quota = s, .reason = why }, .{});
    defer a.free(body);
    const q = try conn.prepare("INSERT INTO events(ts,source,kind,payload_json,order_id) VALUES(?,'cli_quota',?,?,?)");
    defer conn.finalize(q);
    try db.bindInt(q, 1, health.nowMillis(conn));
    try db.bindText(q, 2, if (s.blocked()) "cli_quota_skipped" else "cli_quota_warning");
    try db.bindText(q, 3, body);
    if (order_id > 0) try db.bindInt(q, 4, order_id) else if (db.c.sqlite3_bind_null(q, 4) != db.c.SQLITE_OK) return error.BindFailed;
    if (db.c.sqlite3_step(q) != db.c.SQLITE_DONE) return error.StepFailed;
}

fn fixture(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const fixtures = @import("cli_quota_fixtures");
    for (fixtures.paths, fixtures.contents) |name, bytes| {
        if (std.mem.eql(u8, name, path)) return a.dupe(u8, bytes);
    }
    return error.FileNotFound;
}

test "CK-COMP-007 lectores fixtures normal 80 100 desconocido" {
    const a = std.testing.allocator;
    for ([_]Cli{ .codex, .@"claude-code" }) |cli| {
        for ([_][]const u8{ "normal", "80", "100", "unknown" }, [_]?f64{ 79, 80, 100, null }) |name, expected| {
            const path = try std.fmt.allocPrint(a, "tests/fixtures/CK-COMP-007/{s}-{s}.jsonl", .{ @tagName(cli), name });
            defer a.free(path);
            const bytes = try fixture(a, path);
            defer a.free(bytes);
            const s = try parse(a, cli, bytes, 1800000000);
            try std.testing.expectEqual(expected, s.five_hour.used_percent);
            try std.testing.expectEqual(expected != null and expected.? == 100, s.blocked());
            if (expected != null) try std.testing.expectEqual(@as(?i64, 1800005000), s.five_hour.reset_at);
            try std.testing.expectEqualStrings("sin verificar", s.format);
        }
    }
}

test "CK-COMP-007 caducado invalido diario semanal y sin datos" {
    const a = std.testing.allocator;
    try std.testing.expect(!(try parse(a, .codex, "{}", 1)).blocked());
    try std.testing.expectEqual(@as(?f64, null), (try parse(a, .codex, "{\"rate_limits\":{\"primary\":{\"used_percent\":100,\"window_minutes\":300,\"resets_at\":100}}}", 101)).five_hour.used_percent);
    const s = try parse(a, .@"claude-code", "{\"five_hour\":{\"utilization\":-1},\"one_day\":{\"utilization\":80,\"resets_at\":\"2027-01-15T08:00:00Z\"},\"seven_day\":{\"utilization\":100}}", 1);
    try std.testing.expectEqual(@as(?f64, null), s.five_hour.used_percent);
    try std.testing.expectEqual(@as(?f64, 80), s.daily.used_percent);
    try std.testing.expectEqual(@as(?i64, 1800000000), s.daily.reset_at);
    const msg = (try reason(a, s)).?;
    defer a.free(msg);
    try std.testing.expect(std.mem.indexOf(u8, msg, "semanal agotada; reinicio desconocido") != null);
}

test "CK-COMP-007 router salta CLI agotado sigue cadena y acepta 79 y aviso 80" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try conn.exec("CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT); CREATE TABLE events(ts INTEGER,source TEXT,kind TEXT,payload_json TEXT,order_id INTEGER)");
    const io = std.testing.io;
    const fixtures = @import("cli_quota_fixtures");
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "CK-COMP-007-codex.jsonl", .data = fixtures.contents[2] });
    defer std.Io.Dir.cwd().deleteFile(io, "CK-COMP-007-codex.jsonl") catch |e| std.log.err("quota fixture cleanup: {s}", .{@errorName(e)});
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "CK-COMP-007-claude.jsonl", .data = fixtures.contents[4] });
    defer std.Io.Dir.cwd().deleteFile(io, "CK-COMP-007-claude.jsonl") catch |e| std.log.err("quota fixture cleanup: {s}", .{@errorName(e)});
    try conn.exec("INSERT INTO settings VALUES('cli_quota_codex_source','CK-COMP-007-codex.jsonl'),('cli_quota_claude-code_source','CK-COMP-007-claude.jsonl')");
    var selected: []const u8 = "";
    for ([_][]const u8{ "agent:codex", "agent:claude-code", "other" }) |provider| {
        if (dispatchBlock(a, conn, conn, 0, provider)) |why| {
            defer a.free(why);
            try std.testing.expect(std.mem.indexOf(u8, why, "Codex: cuota de 5 h agotada hasta las") != null);
            continue;
        }
        selected = provider;
        break;
    }
    try std.testing.expectEqualStrings("agent:claude-code", selected);
    try std.testing.expect(dispatchBlock(a, conn, conn, 0, "other") == null);
    const q = try conn.prepare("SELECT kind,payload_json FROM events");
    defer conn.finalize(q);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(q));
    try std.testing.expectEqualStrings("cli_quota_skipped", std.mem.span(db.c.sqlite3_column_text(q, 0)));
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(db.c.sqlite3_column_text(q, 1)), "agotada hasta") != null);
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(q));
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "CK-COMP-007-codex.jsonl", .data = fixtures.contents[1] });
    try std.testing.expect(dispatchBlock(a, conn, conn, 0, "agent:codex") == null);
    const w = try conn.prepare("SELECT COUNT(*) FROM events WHERE kind='cli_quota_warning'");
    defer conn.finalize(w);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(w));
    try std.testing.expectEqual(@as(c_int, 1), db.c.sqlite3_column_int(w, 0));
}

test "CK-COMP-007 lectura inyectada desconocida sin fuente archivo ausente y JSON de solo lectura" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try conn.exec("CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT)");
    const Reject = struct {
        fn read(_: std.mem.Allocator, _: []const u8) anyerror![]u8 {
            return error.FileNotFound;
        }
    };
    const missing = try load(a, conn, .codex, 1, Reject.read);
    try std.testing.expectEqual(@as(?f64, null), missing.five_hour.used_percent);
    try conn.exec("INSERT INTO settings VALUES('cli_quota_codex_source','not-a-real-profile')");
    try std.testing.expectEqual(@as(?f64, null), (try load(a, conn, .codex, 1, Reject.read)).five_hour.used_percent);
    try conn.exec("DELETE FROM settings");
    const body = try allJson(a, conn);
    defer a.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "cli-quota.v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"used_percent\":null") != null);
}

test "CK-COMP-007 router real excluye 100 y conserva 79 antes de seleccionar respaldo" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    const migrator = db.Migrator.init(a);
    try migrator.migrate(conn, &db.catalog_schema);
    try conn.exec("INSERT INTO providers(id,name,base_url,api_style,is_local) VALUES(901,'agent:codex','local://fixture','openai',1),(902,'fixture-backup','local://fixture','openai',1)");
    try conn.exec("INSERT INTO models(id,provider_id,model_name,context_window,is_free,available) VALUES(901,901,'fixture-coder',64000,0,1),(902,902,'fixture-backup',64000,0,1)");
    try conn.exec("INSERT INTO settings(key,value) VALUES('cli_quota_codex_source','CK-COMP-007-router.jsonl')");
    const io = std.testing.io;
    defer std.Io.Dir.cwd().deleteFile(io, "CK-COMP-007-router.jsonl") catch |e| std.log.err("quota fixture cleanup: {s}", .{@errorName(e)});
    const fixtures = @import("cli_quota_fixtures");
    const router_mod = @import("model_router.zig");
    var router = router_mod.Router.init(a, conn, null, 1);
    defer router.deinitHealthCache();
    for ([_]usize{ 2, 0 }, [_]usize{ 1, 2 }) |fixture_index, count| {
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = "CK-COMP-007-router.jsonl", .data = fixtures.contents[fixture_index] });
        var candidates = try router.rankCandidates(.{ .task_type = .programar, .required_context = 1000, .governance_mode = .local_only });
        defer {
            for (candidates.items) |c| c.deinit(a);
            candidates.deinit(a);
        }
        try std.testing.expectEqual(count, candidates.items.len);
        if (count == 1) try std.testing.expectEqualStrings("fixture-backup", candidates.items[0].provider_name);
    }
}

test "CK-COMP-007 cabina catalogo existente incorpora cuota y export rechaza argumentos nulos" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try conn.exec("CREATE TABLE settings(key TEXT PRIMARY KEY,value TEXT)");
    const body = try @import("external_registry.zig").withOptions(a, conn, "[{\"provider\":\"agent:codex\",\"models\":[]}]");
    defer a.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    const q = field(parsed.value.array.items[0], "quota");
    try std.testing.expectEqualStrings("desconocido", field(q, "status").string);
    try std.testing.expect(field(field(q, "five_hour"), "used_percent") == .null);
    const api = @import("c_api.zig");
    var out: ?[*:0]const u8 = null;
    try std.testing.expect(api.da_cli_quota_v1_json(null, &out) != 0);
    try std.testing.expect(out == null);
    try std.testing.expect(api.da_cli_quota_v1_json(null, null) != 0);
}
