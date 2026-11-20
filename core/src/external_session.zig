//! session checkpoints in the existing runtime.db event ledger.
const std = @import("std");
const db = @import("db.zig");
const health = @import("health.zig");

pub const Kind = enum { saved, resumed, restart };
pub const Sink = struct {
    ctx: *anyopaque,
    callFn: *const fn (*anyopaque, Kind, ?[]const u8, []const u8) anyerror!void,

    pub fn call(self: Sink, kind: Kind, id: ?[]const u8, reason: []const u8) !void {
        try self.callFn(self.ctx, kind, id, reason);
    }
};

pub const Key = struct { order_id: i64, task_id: []const u8, cli: []const u8, model: []const u8, worktree: []const u8, inherit_personal_context: bool = false };

pub fn validId(id: []const u8) bool {
    if (id.len == 0 or id.len > 256 or id[0] == '-') return false;
    for (id) |ch| if (!std.ascii.isAlphanumeric(ch) and ch != '-' and ch != '_') return false;
    return true;
}

pub fn eventName(kind: Kind) []const u8 {
    return switch (kind) {
        .saved => "external_session_saved",
        .resumed => "external_session_resumed",
        .restart => "external_session_restart",
    };
}

pub fn payload(a: std.mem.Allocator, key: Key, id: ?[]const u8, reason: []const u8) ![]u8 {
    return std.json.Stringify.valueAlloc(a, .{ .task_id = key.task_id, .cli = key.cli, .model = key.model, .worktree = key.worktree, .session_id = id, .reason = reason, .context_policy_version = @as(u32, 1), .inherit_personal_context = key.inherit_personal_context }, .{});
}

pub fn record(a: std.mem.Allocator, conn: db.Connection, key: Key, kind: Kind, id: ?[]const u8, reason: []const u8) !void {
    if (id) |value| if (!validId(value)) return error.InvalidSessionId;
    const body = try payload(a, key, id, reason);
    defer a.free(body);
    const q = try conn.prepare("INSERT INTO events(ts,source,kind,payload_json,order_id) VALUES(?,'superagente',?,?,?)");
    defer conn.finalize(q);
    try db.bindInt(q, 1, health.nowMillis(conn));
    try db.bindText(q, 2, eventName(kind));
    try db.bindText(q, 3, body);
    try db.bindInt(q, 4, key.order_id);
    if (db.c.sqlite3_step(q) != db.c.SQLITE_DONE) return error.SessionCheckpointWriteFailed;
}

pub fn load(a: std.mem.Allocator, conn: db.Connection, key: Key) !?[]u8 {
    const q = try conn.prepare(
        "SELECT kind,json_extract(payload_json,'$.session_id') FROM events WHERE order_id=? " ++
            "AND kind IN ('external_session_saved','external_session_restart') " ++
            "AND json_extract(payload_json,'$.task_id')=? AND json_extract(payload_json,'$.cli')=? " ++
            "AND json_extract(payload_json,'$.model')=? AND json_extract(payload_json,'$.worktree')=? " ++
            "AND json_extract(payload_json,'$.context_policy_version')=1 " ++
            "AND json_extract(payload_json,'$.inherit_personal_context')=? ORDER BY id DESC LIMIT 1",
    );
    defer conn.finalize(q);
    try db.bindInt(q, 1, key.order_id);
    try db.bindText(q, 2, key.task_id);
    try db.bindText(q, 3, key.cli);
    try db.bindText(q, 4, key.model);
    try db.bindText(q, 5, key.worktree);
    try db.bindInt(q, 6, @intFromBool(key.inherit_personal_context));
    const rc = db.c.sqlite3_step(q);
    if (rc == db.c.SQLITE_DONE) return null;
    if (rc != db.c.SQLITE_ROW) return error.SessionCheckpointReadFailed;
    const kind = std.mem.span(db.c.sqlite3_column_text(q, 0));
    if (std.mem.eql(u8, kind, eventName(.restart))) return null;
    const ptr = db.c.sqlite3_column_text(q, 1) orelse return error.InvalidSessionId;
    const id = std.mem.span(ptr);
    if (!validId(id)) return error.InvalidSessionId;
    return try a.dupe(u8, id);
}

test "CK-COMP-002 ledger isolates order task CLI model and worktree and invalidates rejected sessions" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
    const key: Key = .{ .order_id = 1, .task_id = "t1", .cli = "codex", .model = "m", .worktree = "wt" };
    try std.testing.expectEqual(@as(?[]u8, null), try load(a, conn, key));
    try record(a, conn, key, .saved, "thread-123", "");
    const saved = (try load(a, conn, key)).?;
    defer a.free(saved);
    try std.testing.expectEqualStrings("thread-123", saved);
    inline for (.{ "order_id", "task_id", "cli", "model", "worktree" }) |field| {
        var other = key;
        if (comptime std.mem.eql(u8, field, "order_id")) other.order_id = 2 else @field(other, field) = "other";
        try std.testing.expectEqual(@as(?[]u8, null), try load(a, conn, other));
    }
    try record(a, conn, key, .restart, "thread-123", "no se pudo reanudar: sesion inexistente; se relanza");
    try std.testing.expectEqual(@as(?[]u8, null), try load(a, conn, key));
    try std.testing.expectError(error.InvalidSessionId, record(a, conn, key, .saved, "--last", ""));
    try conn.exec("DROP TABLE events");
    try std.testing.expectError(error.PrepareFailed, load(a, conn, key));
}

test "CK-COMP-002 saved init survives closing and reopening the runtime database" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const path = try std.fs.path.join(a, &.{ root, "runtime.db" });
    defer a.free(path);
    const key: Key = .{ .order_id = 9, .task_id = "t1", .cli = "claude-code", .model = "m", .worktree = root };
    {
        var conn = try db.Connection.open(a, path);
        defer conn.close();
        try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
        try record(a, conn, key, .saved, "session-9", "");
    }
    {
        var conn = try db.Connection.open(a, path);
        defer conn.close();
        const id = (try load(a, conn, key)).?;
        defer a.free(id);
        try std.testing.expectEqualStrings("session-9", id);
    }
}

test "CK-CAB-027 sessions never reuse legacy or differently inherited context" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
    const key: Key = .{ .order_id = 1, .task_id = "t", .cli = "claude-code", .model = "m", .worktree = "wt" };
    try conn.exec("INSERT INTO events(ts,source,kind,payload_json,order_id) VALUES(0,'superagente','external_session_saved','{\"task_id\":\"t\",\"cli\":\"claude-code\",\"model\":\"m\",\"worktree\":\"wt\",\"session_id\":\"legacy\"}',1)");
    const legacy = try load(a, conn, key);
    defer if (legacy) |id| a.free(id);
    try std.testing.expect(legacy == null);
    try record(a, conn, key, .saved, "isolated", "");
    var opted = key;
    opted.inherit_personal_context = true;
    const foreign = try load(a, conn, opted);
    defer if (foreign) |id| a.free(id);
    try std.testing.expect(foreign == null);
    const current = (try load(a, conn, key)).?;
    defer a.free(current);
    try std.testing.expectEqualStrings("isolated", current);
}
