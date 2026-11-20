//! selection metadata shared by the cockpit and native routing.
const std = @import("std");
const db = @import("db.zig");
const caps = @import("model_capabilities.zig");
const roster = @import("model_roster.zig");

pub const Row = struct {
    provider: []const u8,
    model: []const u8,
    text_gen: bool,
    is_free: bool,
    show_in_selectors: bool = true,
    allow_automatic: bool = true,
};

pub const Preferences = struct { show_in_selectors: bool = true, allow_automatic: bool = true };

pub const automatic_filter = " AND NOT EXISTS (SELECT 1 FROM model_preferences mp WHERE mp.provider=p.name AND mp.model=m.model_name AND mp.allow_automatic=0) ";

pub fn get(conn: db.Connection, provider: []const u8, model: []const u8) !Preferences {
    const q = try conn.prepare("SELECT show_in_selectors,allow_automatic FROM model_preferences WHERE provider=? AND model=?");
    defer conn.finalize(q);
    try db.bindText(q, 1, provider);
    try db.bindText(q, 2, model);
    return switch (db.c.sqlite3_step(q)) {
        db.c.SQLITE_ROW => .{ .show_in_selectors = db.c.sqlite3_column_int(q, 0) != 0, .allow_automatic = db.c.sqlite3_column_int(q, 1) != 0 },
        db.c.SQLITE_DONE => .{},
        else => error.StepFailed,
    };
}

pub fn set(a: std.mem.Allocator, conn: db.Connection, external: []const u8, provider: []const u8, model: []const u8, preferences: Preferences) !void {
    if (provider.len == 0 or provider.len > 256 or model.len == 0 or model.len > 512 or
        !std.unicode.utf8ValidateSlice(provider) or !std.unicode.utf8ValidateSlice(model)) return error.InvalidModel;
    const all = try list(a, conn, external);
    defer a.free(all);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, all, .{});
    defer parsed.deinit();
    var found = false;
    for (parsed.value.array.items) |row| {
        if (std.mem.eql(u8, string(row, "provider"), provider) and std.mem.eql(u8, string(row, "model"), model)) {
            found = true;
            break;
        }
    }
    if (!found) return error.UnknownModel;
    const q = try conn.prepare("INSERT INTO model_preferences(provider,model,show_in_selectors,allow_automatic) VALUES(?,?,?,?) ON CONFLICT(provider,model) DO UPDATE SET show_in_selectors=excluded.show_in_selectors,allow_automatic=excluded.allow_automatic");
    defer conn.finalize(q);
    try db.bindText(q, 1, provider);
    try db.bindText(q, 2, model);
    try db.bindInt(q, 3, @intFromBool(preferences.show_in_selectors));
    try db.bindInt(q, 4, @intFromBool(preferences.allow_automatic));
    if (db.c.sqlite3_step(q) != db.c.SQLITE_DONE) return error.StepFailed;
}

pub fn textGeneration(name: []const u8, generative: bool, modalities: []const u8) bool {
    return generative and (std.mem.eql(u8, modalities, "text") or !caps.nonChat(name));
}

pub fn catalogTextGeneration(conn: db.Connection, provider: []const u8, model: []const u8) !bool {
    const q = try conn.prepare("SELECT m.is_generative,m.modalities FROM models m JOIN providers p ON p.id=m.provider_id WHERE p.name=? AND m.model_name=?");
    defer conn.finalize(q);
    try db.bindText(q, 1, provider);
    try db.bindText(q, 2, model);
    return switch (db.c.sqlite3_step(q)) {
        db.c.SQLITE_ROW => textGeneration(model, db.c.sqlite3_column_int(q, 0) != 0, column(q, 1)),
        db.c.SQLITE_DONE => !caps.nonChat(model),
        else => error.StepFailed,
    };
}

pub const ExternalEligibility = struct { free: bool = false, chat: bool = false };

pub fn externalEligibility(a: std.mem.Allocator, text: []const u8, provider: []const u8, model: []const u8) !ExternalEligibility {
    const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidCatalog;
    for (parsed.value.array.items) |agent| {
        if (!std.mem.eql(u8, string(agent, "provider"), provider)) continue;
        const models = agent.object.get("models") orelse continue;
        if (models != .array) continue;
        for (models.array.items) |item| {
            if (!std.mem.eql(u8, string(item, "slug"), model)) continue;
            const text_gen = item.object.get("text_gen");
            return .{
                .chat = if (text_gen != null and text_gen.? == .bool) text_gen.?.bool else !caps.nonChat(model),
                .free = @import("external_agent_catalog.zig").isFreeModel(string(agent, "cli"), model, boolean(item, "zero_cost")) or
                    (!std.mem.eql(u8, provider, "agent:opencode") and std.mem.eql(u8, string(agent, "session"), "suscripcion")),
            };
        }
    }
    return .{};
}

pub fn list(allocator: std.mem.Allocator, conn: db.Connection, external: []const u8) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var rows: std.ArrayList(Row) = .empty;
    const q = try conn.prepare("SELECT p.name,m.model_name,m.is_generative,m.modalities,m.is_free FROM models m JOIN providers p ON p.id=m.provider_id ORDER BY p.name,m.model_name");
    defer conn.finalize(q);
    while (true) {
        const rc = db.c.sqlite3_step(q);
        if (rc == db.c.SQLITE_DONE) break;
        if (rc != db.c.SQLITE_ROW) return error.StepFailed;
        const provider = try a.dupe(u8, column(q, 0));
        const model = try a.dupe(u8, column(q, 1));
        const preferences = try get(conn, provider, model);
        try rows.append(a, .{
            .provider = provider,
            .model = model,
            .text_gen = textGeneration(model, db.c.sqlite3_column_int(q, 2) != 0, column(q, 3)),
            .is_free = db.c.sqlite3_column_int(q, 4) != 0 and (!std.ascii.eqlIgnoreCase(provider, "OpenCode") or roster.isOpenCodeKnownFree(model)),
            .show_in_selectors = preferences.show_in_selectors,
            .allow_automatic = preferences.allow_automatic,
        });
    }
    const parsed = try std.json.parseFromSlice(std.json.Value, a, external, .{});
    if (parsed.value != .array) return error.InvalidCatalog;
    for (parsed.value.array.items) |agent| {
        const provider = string(agent, "provider");
        if (agent != .object) continue;
        const models = agent.object.get("models") orelse continue;
        if (models != .array) continue;
        for (models.array.items) |model| {
            const name = string(model, "slug");
            if (model != .object or name.len == 0) continue;
            const flag = model.object.get("text_gen");
            const chat = if (flag != null and flag.? == .bool) flag.?.bool else !caps.nonChat(name);
            const free = @import("external_agent_catalog.zig").isFreeModel(string(agent, "cli"), name, boolean(model, "zero_cost"));
            const preferences = try get(conn, provider, name);
            try rows.append(a, .{
                .provider = provider,
                .model = name,
                .text_gen = chat,
                .is_free = free or (!std.mem.eql(u8, provider, "agent:opencode") and std.mem.eql(u8, string(agent, "session"), "suscripcion")),
                .show_in_selectors = preferences.show_in_selectors,
                .allow_automatic = preferences.allow_automatic,
            });
        }
    }
    return std.json.Stringify.valueAlloc(allocator, rows.items, .{});
}

fn column(q: *db.c.sqlite3_stmt, i: c_int) []const u8 {
    const ptr = db.c.sqlite3_column_text(q, i);
    return if (ptr != null) std.mem.span(ptr) else "";
}

fn string(v: std.json.Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const item = v.object.get(key) orelse return "";
    return if (item == .string) item.string else "";
}

fn boolean(v: std.json.Value, key: []const u8) bool {
    if (v != .object) return false;
    const item = v.object.get(key) orelse return false;
    return item == .bool and item.bool;
}

test "CK-PRV-004 C4 preferences survive reopening and rediscovery and reject unknown identities" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const directory = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(directory);
    const path = try std.fs.path.join(a, &.{ directory, "catalog.db" });
    defer a.free(path);
    {
        var catalog = try @import("model_catalog.zig").ModelCatalog.init(a, path);
        defer catalog.deinit();
        try catalog.registerModel("Cohere", "command-fixture", 1000, true);
        const initial = try get(catalog.db, "Cohere", "command-fixture");
        try std.testing.expect(initial.show_in_selectors and initial.allow_automatic);
        try set(a, catalog.db, "[]", "Cohere", "command-fixture", .{ .show_in_selectors = false, .allow_automatic = true });
        const ext = "[{\"provider\":\"agent:opencode\",\"cli\":\"opencode\",\"models\":[{\"slug\":\"opencode/chat-free\",\"zero_cost\":true}]}]";
        try set(a, catalog.db, ext, "agent:opencode", "opencode/chat-free", .{ .show_in_selectors = true, .allow_automatic = false });
        try std.testing.expectError(error.UnknownModel, set(a, catalog.db, "[]", "unknown", "x", .{}));
        try std.testing.expectError(error.InvalidModel, set(a, catalog.db, "[]", "", "x", .{}));
        _ = try catalog.discoverFromJson("Cohere", "{\"data\":[{\"id\":\"command-fixture\"}]}", true);
    }
    var reopened = try @import("model_catalog.zig").ModelCatalog.init(a, path);
    defer reopened.deinit();
    const http = try get(reopened.db, "Cohere", "command-fixture");
    try std.testing.expect(!http.show_in_selectors and http.allow_automatic);
    const cli = try get(reopened.db, "agent:opencode", "opencode/chat-free");
    try std.testing.expect(cli.show_in_selectors and !cli.allow_automatic);
    const json = try list(a, reopened.db, "[]");
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"show_in_selectors\":false") != null);
    try reopened.db.exec("DROP TABLE model_preferences");
    try std.testing.expectError(error.PrepareFailed, get(reopened.db, "Cohere", "command-fixture"));
}

test "CK-PRV-004 C2 metadata distinguishes chat vision from speech text output" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "{\"modalities\":{\"output\":[\"text\"]}}", .{});
    defer parsed.deinit();
    try std.testing.expectEqual(true, caps.fromMetadata("vision-chat", parsed.value).?);
    try std.testing.expectEqual(false, caps.fromMetadata("whisper-v3", parsed.value).?);
    try std.testing.expectEqual(false, caps.fromMetadata("nvidia/studiovoice", parsed.value).?);
}

test "CK-PRV-004 r2-4 accidental substrings stay chat in Zig metadata and SQL" {
    const a = std.testing.allocator;
    var c = try db.Connection.open(a, ":memory:");
    defer c.close();
    try c.exec("CREATE TABLE models(model_name TEXT)");
    const metadata = try std.json.parseFromSlice(std.json.Value, a, "{\"modalities\":{\"output\":[\"text\"]}}", .{});
    defer metadata.deinit();
    // Synthetic names: a chat persona named Whisperer, a coding model for
    // embedded systems, and a surname ending in 'tts' (Watts). No modality
    // claim follows from those accidental substrings.
    for ([_][]const u8{ "Whisperer-Chat-7B", "embedded-systems-chat", "Watts-Chat-8B" }) |name| {
        try std.testing.expect(!caps.nonChat(name));
        try std.testing.expectEqual(true, caps.fromMetadata(name, metadata.value).?);
        const insert = try c.prepare("INSERT INTO models VALUES(?)");
        defer c.finalize(insert);
        try db.bindText(insert, 1, name);
        try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(insert));
    }
    try c.exec("INSERT INTO models VALUES('whisper-v3'),('text-embedding-3'),('tts-1'),('bge-m3'),('flux'),('studiovoice')");
    const q = try c.prepare("SELECT COUNT(*) FROM models m WHERE 1=1" ++ caps.sql_filter);
    defer c.finalize(q);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(q));
    try std.testing.expectEqual(@as(c_int, 3), db.c.sqlite3_column_int(q, 0));
}
