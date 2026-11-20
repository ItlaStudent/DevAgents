const std = @import("std");
const db = @import("db.zig");
const agents = @import("external_agents.zig");
const headless = @import("headless_adapter.zig");
const health = @import("health.zig");
const cli_policy = @import("external_cli_policy.zig");

pub const TTL_SECONDS: i64 = 300;

pub fn readSetting(a: std.mem.Allocator, conn: db.Connection, key: []const u8) ![]u8 {
    const q = try conn.prepare("SELECT value FROM settings WHERE key=?");
    defer conn.finalize(q);
    try db.bindText(q, 1, key);
    const rc = db.c.sqlite3_step(q);
    if (rc != db.c.SQLITE_ROW) return error.SettingUnavailable;
    // e5-harden punto 5: un NULL de SQLite no es una cadena (span de null cae).
    const value = db.c.sqlite3_column_text(q, 0);
    if (value == null) return error.SettingUnavailable;
    return a.dupe(u8, std.mem.span(value));
}

pub fn setPaths(a: std.mem.Allocator, conn: db.Connection, text: []const u8) !void {
    if (text.len > 32768) return error.InvalidPaths;
    var p = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch return error.InvalidPaths;
    defer p.deinit();
    if (p.value != .object) return error.InvalidPaths;
    var it = p.value.object.iterator();
    while (it.next()) |entry| {
        if (agents.metaForCliId(entry.key_ptr.*) == null) return error.UnknownCli;
        const v = entry.value_ptr.*;
        if (v != .string or v.string.len > 4096) return error.InvalidPaths;
        if (v.string.len > 0 and !std.fs.path.isAbsolute(v.string)) return error.RelativePath;
        for (v.string) |c| if (c < 32 or std.mem.indexOfScalar(u8, "\"&|<>^%!", c) != null) return error.InvalidPaths;
        if (v.string.len > 0 and !std.ascii.endsWithIgnoreCase(v.string, ".exe") and !std.ascii.endsWithIgnoreCase(v.string, ".cmd") and !std.ascii.endsWithIgnoreCase(v.string, ".bat")) return error.InvalidPaths;
        if (v.string.len > 0) {
            var verified = try cli_policy.verify(a, v.string);
            defer verified.deinit();
        }
    }
    const q = try conn.prepare("UPDATE settings SET value=? WHERE key='external_agent_paths'");
    defer conn.finalize(q);
    try db.bindText(q, 1, text);
    if (db.c.sqlite3_step(q) != db.c.SQLITE_DONE) return error.StepFailed;
    try conn.exec("DELETE FROM external_agent_cache");
}

pub fn cached(a: std.mem.Allocator, conn: db.Connection, now: i64) !?[]u8 {
    return cachedImpl(a, conn, now, true);
}

/// QA primerizo (10-nov): la última detección conocida aunque haya pasado el
/// TTL. Solo para AVISOS previos al envío (preflight, selectores): con
/// `cached` el aviso decía «Suscripción no disponible» a los 5 minutos de
/// detectar, sobre un agente que luego funcionaba. La ejecución sigue
/// revalidando con `cached`/`refresh` antes de lanzar nada.
pub fn lastKnown(a: std.mem.Allocator, conn: db.Connection, now: i64) !?[]u8 {
    return cachedImpl(a, conn, now, false);
}

fn cachedImpl(a: std.mem.Allocator, conn: db.Connection, now: i64, honor_ttl: bool) !?[]u8 {
    const q = try conn.prepare("SELECT payload_json,detected_at FROM external_agent_cache WHERE id=1");
    defer conn.finalize(q);
    const rc = db.c.sqlite3_step(q);
    if (rc == db.c.SQLITE_DONE) return null;
    if (rc != db.c.SQLITE_ROW) return error.StepFailed;
    const ts = db.c.sqlite3_column_int64(q, 1);
    if (honor_ttl and (ts > now or now - ts >= TTL_SECONDS)) return null;
    const payload = db.c.sqlite3_column_text(q, 0);
    if (payload == null) return null;
    const text = std.mem.span(payload);
    var parsed = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .array) return null;
    // 10-nov (USUARIO-NUEVO A4): si el ejecutable cambió desde la detección
    // (actualización de la CLI), la caché ya no vale aunque no haya vencido.
    if (honor_ttl) for (parsed.value.array.items) |agent| {
        if (agent != .object) continue;
        const stamp = agent.object.get("exe_stamp") orelse continue;
        if (stamp != .integer) continue;
        const exe = str(agent, "exe");
        if (exe.len == 0) continue;
        const now_stamp = try agents.exeStamp(a, exe);
        if (now_stamp == null or now_stamp.? != @as(u64, @bitCast(stamp.integer))) return null;
    };
    // Old OpenCode payloads inferred free from the ID and lack price evidence.
    for (parsed.value.array.items) |agent| {
        if (!std.mem.eql(u8, str(agent, "provider"), "agent:opencode")) continue;
        const models = agent.object.get("models") orelse return null;
        if (models != .array) return null;
        for (models.array.items) |m| {
            if (m != .object) return null;
            const cost = m.object.get("zero_cost") orelse return null;
            if (cost != .bool) return null;
        }
    }
    return try a.dupe(u8, text);
}

pub fn store(conn: db.Connection, text: []const u8, now: i64) !void {
    const q = try conn.prepare("INSERT INTO external_agent_cache(id,payload_json,detected_at) VALUES(1,?,?) ON CONFLICT(id) DO UPDATE SET payload_json=excluded.payload_json,detected_at=excluded.detected_at");
    defer conn.finalize(q);
    try db.bindText(q, 1, text);
    try db.bindInt(q, 2, now);
    if (db.c.sqlite3_step(q) != db.c.SQLITE_DONE) return error.StepFailed;
}

pub fn refresh(a: std.mem.Allocator, conn: db.Connection, capture: ?headless.CaptureFn, resolve: ?agents.ResolveFn) ![]u8 {
    const paths = try readSetting(a, conn, "external_agent_paths");
    defer a.free(paths);
    const body = try detectBody(a, paths, capture, resolve);
    errdefer a.free(body);
    try store(conn, body, health.nowSeconds(conn));
    return body;
}

/// La parte lenta de `refresh` (lanza cada CLI para listar sus modelos), sin
/// tocar la base: quien la llama puede soltar sus candados mientras corre
/// (QA primerizo 11-nov: «Detectar agentes» retenía el candado de agentes
/// externos ~60 s y todo lo que lo necesitaba esperaba).
pub fn detectBody(a: std.mem.Allocator, paths: []const u8, capture: ?headless.CaptureFn, resolve: ?agents.ResolveFn) ![]u8 {
    const list = if (resolve != null)
        try agents.detectAll(a, capture, resolve)
    else
        try agents.detectAllWithPaths(a, capture, paths);
    defer {
        for (list) |*d| d.deinit(a);
        a.free(list);
    }
    return agents.detectedJson(a, list);
}

pub fn withOptions(a: std.mem.Allocator, conn: db.Connection, text: []const u8) ![]u8 {
    var p = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer p.deinit();
    if (p.value != .array) return error.InvalidCatalog;
    const arena = p.arena.allocator();
    for (p.value.array.items) |*ag| {
        if (ag.* != .object) continue;
        if (@import("cli_quota.zig").cliForProvider(str(ag.*, "provider"))) |cli| {
            const snapshot = try @import("cli_quota.zig").current(a, conn, cli);
            const raw = try std.json.Stringify.valueAlloc(a, snapshot, .{});
            defer a.free(raw);
            const quota = try std.json.parseFromSlice(std.json.Value, arena, raw, .{ .allocate = .alloc_always });
            try ag.object.put(arena, "quota", quota.value);
        }
        const ms = ag.object.getPtr("models") orelse continue;
        if (ms.* != .array) continue;
        for (ms.array.items) |*m| {
            if (m.* != .object) continue;
            if (m.object.get("text_gen") == null) {
                try m.object.put(arena, "text_gen", .{ .bool = !@import("model_capabilities.zig").nonChat(str(m.*, "slug")) });
            }
            const q = try conn.prepare("SELECT reasoning_effort FROM external_model_options WHERE provider=? AND model=?");
            defer conn.finalize(q);
            try db.bindText(q, 1, str(ag.*, "provider"));
            try db.bindText(q, 2, str(m.*, "slug"));
            const rc = db.c.sqlite3_step(q);
            if (rc == db.c.SQLITE_ROW) {
                const stored = db.c.sqlite3_column_text(q, 0);
                if (stored == null) return error.InvalidOptions;
                const effort = try arena.dupe(u8, std.mem.span(stored));
                try m.object.put(arena, "reasoning_effort", .{ .string = effort });
            } else if (rc != db.c.SQLITE_DONE) return error.StepFailed;
        }
    }
    return std.json.Stringify.valueAlloc(a, p.value, .{});
}

pub const Pin = struct {
    exe: []u8,
    version: []u8,
    effort: ?[]u8,
    zero_cost: bool = false,
    pub fn deinit(self: Pin, a: std.mem.Allocator) void {
        a.free(self.exe);
        a.free(self.version);
        if (self.effort) |v| a.free(v);
    }
};

pub fn resolvePin(a: std.mem.Allocator, conn: db.Connection, text: []const u8, provider: []const u8, model: []const u8) !Pin {
    var p = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch return error.InvalidCatalog;
    defer p.deinit();
    if (p.value != .array) return error.InvalidCatalog;
    for (p.value.array.items) |agent| {
        if (agent != .object) continue;
        if (!std.mem.eql(u8, str(agent, "provider"), provider)) continue;
        const models = agent.object.get("models") orelse return error.ModelUnavailable;
        if (models != .array) return error.InvalidCatalog;
        for (models.array.items) |m| {
            if (m != .object) continue;
            if (!std.mem.eql(u8, str(m, "slug"), model) and !std.mem.eql(u8, model, str(agent, "cli"))) continue;
            const cost = m.object.get("zero_cost");
            const zero_cost = cost != null and cost.? == .bool and cost.?.bool;
            const free = std.mem.eql(u8, provider, "agent:opencode") and @import("external_agent_catalog.zig").isFreeModel(str(agent, "cli"), model, zero_cost);
            if (!free) {
                if (std.mem.eql(u8, str(agent, "session"), "api_key")) return error.ApiBillingForbidden;
                if (!std.mem.eql(u8, str(agent, "session"), "suscripcion")) return error.NotLoggedIn;
            }
            const exe = str(agent, "exe");
            if (exe.len == 0 or !std.fs.path.isAbsolute(exe)) return error.InvalidBinary;
            const owned = try a.dupe(u8, exe);
            errdefer a.free(owned);
            const ver = try a.dupe(u8, str(agent, "version"));
            errdefer a.free(ver);
            const q = try conn.prepare("SELECT reasoning_effort FROM external_model_options WHERE provider=? AND model=?");
            defer conn.finalize(q);
            try db.bindText(q, 1, provider);
            try db.bindText(q, 2, model);
            const rc = db.c.sqlite3_step(q);
            const effort = if (rc == db.c.SQLITE_ROW) blk: {
                const stored = db.c.sqlite3_column_text(q, 0);
                if (stored == null) return error.InvalidOptions;
                break :blk try a.dupe(u8, std.mem.span(stored));
            } else if (rc == db.c.SQLITE_DONE) null else return error.StepFailed;
            return .{ .exe = owned, .version = ver, .effort = effort, .zero_cost = free };
        }
        return error.ModelUnavailable;
    }
    return error.AgentUnavailable;
}

/// Reemplaza solo la sesión Codex: los modelos enumerados conservan su TTL.
pub fn revalidateCodexPin(a: std.mem.Allocator, conn: db.Connection, text: []const u8, model: []const u8, io: std.Io, env: *const std.process.Environ.Map) !Pin {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer parsed.deinit();
    if (parsed.value != .array) return error.InvalidCatalog;
    for (parsed.value.array.items) |*agent| {
        if (!std.mem.eql(u8, str(agent.*, "provider"), "agent:codex")) continue;
        const home_id = try cli_policy.codexHomeId(env);
        if (!std.mem.eql(u8, str(agent.*, "codex_home_id"), &home_id)) return error.CodexHomeChanged;
        const session = try agents.revalidateCodex(a, io, str(agent.*, "exe"), env);
        return updateCodexPin(a, conn, &parsed, agent, model, session);
    }
    return error.AgentUnavailable;
}

fn updateCodexPin(a: std.mem.Allocator, conn: db.Connection, parsed: *std.json.Parsed(std.json.Value), agent: *std.json.Value, model: []const u8, session: agents.Session) !Pin {
    try agent.object.put(parsed.arena.allocator(), "session", .{ .string = @tagName(session) });
    const body = try std.json.Stringify.valueAlloc(a, parsed.value, .{});
    defer a.free(body);
    // No renovar detected_at: la autenticación no reenumera modelos.
    const q = try conn.prepare("UPDATE external_agent_cache SET payload_json=? WHERE id=1");
    defer conn.finalize(q);
    try db.bindText(q, 1, body);
    if (db.c.sqlite3_step(q) != db.c.SQLITE_DONE) return error.StepFailed;
    return resolvePin(a, conn, body, "agent:codex", model);
}

fn str(v: std.json.Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const field = v.object.get(key) orelse return "";
    return if (field == .string) field.string else "";
}

pub fn setOptions(a: std.mem.Allocator, conn: db.Connection, text: []const u8, catalog: []const u8) !void {
    var p = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch return error.InvalidOptions;
    defer p.deinit();
    if (p.value != .object) return error.InvalidOptions;
    const provider = str(p.value, "provider");
    const model = str(p.value, "model");
    const effort = str(p.value, "reasoning_effort");
    var cat = std.json.parseFromSlice(std.json.Value, a, catalog, .{}) catch return error.InvalidCatalog;
    defer cat.deinit();
    if (cat.value != .array) return error.InvalidCatalog;
    var allowed = false;
    for (cat.value.array.items) |ag| {
        if (ag != .object or !std.mem.eql(u8, str(ag, "provider"), provider)) continue;
        const ms = ag.object.get("models") orelse continue;
        if (ms != .array) continue;
        for (ms.array.items) |m| {
            if (m != .object or !std.mem.eql(u8, str(m, "slug"), model)) continue;
            if (effort.len == 0) {
                allowed = true;
                break;
            }
            const levels = m.object.get("reasoning_efforts") orelse continue;
            if (levels != .array) continue;
            for (levels.array.items) |level| {
                if (level == .string and std.mem.eql(u8, level.string, effort)) allowed = true;
            }
        }
    }
    if (!allowed) return error.UnsupportedReasoningEffort;
    const q = try conn.prepare("INSERT INTO external_model_options(provider,model,reasoning_effort) VALUES(?,?,?) ON CONFLICT(provider,model) DO UPDATE SET reasoning_effort=excluded.reasoning_effort");
    defer conn.finalize(q);
    try db.bindText(q, 1, provider);
    try db.bindText(q, 2, model);
    try db.bindText(q, 3, effort);
    if (db.c.sqlite3_step(q) != db.c.SQLITE_DONE) return error.StepFailed;
}

const fixture = "[{\"provider\":\"agent:codex\",\"cli\":\"codex\",\"exe\":\"C:/app/codex.exe\",\"version\":\"0.159.2\",\"session\":\"suscripcion\",\"models\":[{\"slug\":\"gpt-6-luna\",\"reasoning_efforts\":[\"low\",\"high\"]}]}]";

test "CK-CAB-002 opencode free R2 legacy free flag without costs cannot authorize pin" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.catalog_schema);
    const text = "[{\"provider\":\"agent:opencode\",\"cli\":\"opencode\",\"exe\":\"C:/app/opencode.exe\",\"session\":\"api_key\",\"models\":[{\"slug\":\"opencode/x-free\",\"free\":true}]}]";
    try store(conn, text, 1000);
    try std.testing.expect((try cached(a, conn, 1001)) == null);
    const pin = resolvePin(a, conn, text, "agent:opencode", "opencode/x-free") catch |err| {
        try std.testing.expectEqual(error.ApiBillingForbidden, err);
        return;
    };
    defer pin.deinit(a);
    return error.TestExpectedError;
}

test "CK-CAB-002 opencode free pin uses catalog while paid models stay blocked" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.catalog_schema);
    const text = "[{\"provider\":\"agent:opencode\",\"cli\":\"opencode\",\"exe\":\"C:/app/opencode.exe\",\"version\":\"1.18.25\",\"session\":\"api_key\",\"models\":[{\"slug\":\"opencode/x-free\",\"zero_cost\":true},{\"slug\":\"opencode/charged-free\",\"zero_cost\":false},{\"slug\":\"opencode/claude-opus-5\"},{\"slug\":\"fireworks/x-free\",\"zero_cost\":true},{\"slug\":\"nvidia/x\"},{\"slug\":\"tokenrouter/x\"}]}]";
    const pin = try resolvePin(a, conn, text, "agent:opencode", "opencode/x-free");
    defer pin.deinit(a);
    try std.testing.expectEqualStrings("C:/app/opencode.exe", pin.exe);
    try std.testing.expect(pin.zero_cost);
    for ([_][]const u8{ "opencode/charged-free", "opencode/claude-opus-5", "fireworks/x-free", "nvidia/x", "tokenrouter/x", "opencode" }) |model|
        try std.testing.expectError(error.ApiBillingForbidden, resolvePin(a, conn, text, "agent:opencode", model));
    try std.testing.expectError(error.ModelUnavailable, resolvePin(a, conn, text, "agent:opencode", "opencode/absent-free"));
    for ([_][]const u8{ "sin_sesion", "desconocida" }) |session| {
        const other = try std.mem.replaceOwned(u8, a, text, "api_key", session);
        defer a.free(other);
        const free_pin = try resolvePin(a, conn, other, "agent:opencode", "opencode/x-free");
        defer free_pin.deinit(a);
        try std.testing.expectError(error.NotLoggedIn, resolvePin(a, conn, other, "agent:opencode", "opencode/claude-opus-5"));
    }
}

test "RELOJ old API cache becomes ChatGPT without renewing models and changed sessions block dispatch" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.catalog_schema);
    const old = try std.mem.replaceOwned(u8, a, fixture, "suscripcion", "api_key");
    defer a.free(old);
    try store(conn, old, 1000);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, old, .{});
    defer parsed.deinit();
    const pin = try updateCodexPin(a, conn, &parsed, &parsed.value.array.items[0], "gpt-6-luna", .suscripcion);
    defer pin.deinit(a);
    const fresh = (try cached(a, conn, 1001)).?;
    defer a.free(fresh);
    try std.testing.expect(std.mem.indexOf(u8, fresh, "api_key") == null);
    try std.testing.expect((try cached(a, conn, 1300)) == null);
    try std.testing.expectError(error.ApiBillingForbidden, updateCodexPin(a, conn, &parsed, &parsed.value.array.items[0], "gpt-6-luna", .api_key));
    try std.testing.expectError(error.NotLoggedIn, updateCodexPin(a, conn, &parsed, &parsed.value.array.items[0], "gpt-6-luna", .desconocida));
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("CODEX_HOME", "C:\\changed-profile");
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    try std.testing.expectError(error.CodexHomeChanged, revalidateCodexPin(a, conn, old, "gpt-6-luna", threaded.io(), &env));
}

test "QA primerizo: los avisos usan la última detección aunque caduque el TTL" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(a);
    try migrator.migrate(conn, &db.catalog_schema);
    try std.testing.expect((try lastKnown(a, conn, 1000)) == null);
    try store(conn, fixture, 1000);
    // Pasado el TTL, `cached` obliga a revalidar antes de ejecutar…
    try std.testing.expect((try cached(a, conn, 1000 + TTL_SECONDS)) == null);
    // …pero el aviso previo no inventa «Suscripción no disponible».
    const known = (try lastKnown(a, conn, 1000 + TTL_SECONDS * 10)).?;
    defer a.free(known);
    try std.testing.expectEqualStrings(fixture, known);
}

test "USUARIO-NUEVO A4: la caché del catálogo se invalida sola cuando el ejecutable cambia" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(a);
    try migrator.migrate(conn, &db.catalog_schema);
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(io, "claude.exe", .{});
    file.close(io);
    const exe = try tmp.dir.realPathFileAlloc(io, "claude.exe", a);
    defer a.free(exe);
    const stamp = (try agents.exeStamp(a, exe)).?;
    const exe_json = try std.json.Stringify.valueAlloc(a, exe, .{});
    defer a.free(exe_json);
    const payload = try std.fmt.allocPrint(a, "[{{\"provider\":\"agent:claude-code\",\"exe\":{s},\"exe_stamp\":{d},\"models\":[]}}]", .{ exe_json, stamp });
    defer a.free(payload);
    try store(conn, payload, 1000);
    // Misma instalación: la caché sigue valiendo dentro del TTL.
    const same = (try cached(a, conn, 1001)).?;
    a.free(same);
    // La CLI se actualiza (otra fecha de escritura): la caché deja de valer
    // aunque no haya vencido, y la siguiente consulta vuelve a detectar.
    const stale = try std.fmt.allocPrint(a, "[{{\"provider\":\"agent:claude-code\",\"exe\":{s},\"exe_stamp\":{d},\"models\":[]}}]", .{ exe_json, stamp - 1 });
    defer a.free(stale);
    try store(conn, stale, 1000);
    try std.testing.expect((try cached(a, conn, 1001)) == null);
    // Los avisos previos siguen leyendo la última detección conocida.
    const known = (try lastKnown(a, conn, 1001)).?;
    a.free(known);
}

test "E5.55: cache TTL paths and model options persist with honest errors" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(a);
    try migrator.migrate(conn, &db.catalog_schema);
    try std.testing.expectError(error.SettingUnavailable, readSetting(a, conn, "missing"));
    try std.testing.expectError(error.InvalidCatalog, withOptions(a, conn, "{}"));
    try std.testing.expectError(error.InvalidPaths, setPaths(a, conn, "{\"codex\":\"C:/evil&command.exe\"}"));
    try std.testing.expectError(error.InvalidPaths, setPaths(a, conn, "{\"codex\":\"C:/file.txt\"}"));
    try store(conn, fixture, 1000);
    const fresh = (try cached(a, conn, 1299)).?;
    defer a.free(fresh);
    try std.testing.expectEqualStrings(fixture, fresh);
    try std.testing.expect((try cached(a, conn, 1300)) == null);
    try std.testing.expect((try cached(a, conn, 999)) == null);
    try store(conn, "invalid json", 1000);
    try std.testing.expect((try cached(a, conn, 1001)) == null);
    try std.testing.expectError(error.RelativePath, setPaths(a, conn, "{\"codex\":\"relative.cmd\"}"));
    try std.testing.expectError(error.UnknownCli, setPaths(a, conn, "{\"other\":\"C:/x.exe\"}"));
    try std.testing.expectError(error.InvalidPaths, setPaths(a, conn, "[]"));
    try std.testing.expectError(error.UntrustedCliRoot, setPaths(a, conn, "{\"codex\":\"C:/new/codex.exe\"}"));
    try std.testing.expectError(error.InvalidExternalAgentPath, setPaths(a, conn, "{\"codex\":\"C:/new/codex.exe:evil.exe\"}"));
    try setPaths(a, conn, "{}");
    const paths = try readSetting(a, conn, "external_agent_paths");
    defer a.free(paths);
    try std.testing.expectEqualStrings("{}", paths);
    try std.testing.expectError(error.SettingUnavailable, readSetting(a, conn, "missing"));
    try std.testing.expect((try cached(a, conn, 1001)) == null);
    try setOptions(a, conn, "{\"provider\":\"agent:codex\",\"model\":\"gpt-6-luna\",\"reasoning_effort\":\"high\"}", fixture);
    const pin = try resolvePin(a, conn, fixture, "agent:codex", "gpt-6-luna");
    defer pin.deinit(a);
    try std.testing.expectEqualStrings("C:/app/codex.exe", pin.exe);
    try std.testing.expectEqualStrings("high", pin.effort.?);
    const bill = try std.mem.replaceOwned(u8, a, fixture, "suscripcion", "api_key");
    defer a.free(bill);
    try std.testing.expectError(error.ApiBillingForbidden, resolvePin(a, conn, bill, "agent:codex", "gpt-6-luna"));
    const logged_out = try std.mem.replaceOwned(u8, a, fixture, "suscripcion", "sin_sesion");
    defer a.free(logged_out);
    try std.testing.expectError(error.NotLoggedIn, resolvePin(a, conn, logged_out, "agent:codex", "gpt-6-luna"));
    const decorated = try withOptions(a, conn, fixture);
    defer a.free(decorated);
    try std.testing.expect(std.mem.indexOf(u8, decorated, "\"reasoning_effort\":\"high\"") != null);
    try std.testing.expectError(error.InvalidCatalog, withOptions(a, conn, "{}"));
    try std.testing.expectError(error.UnsupportedReasoningEffort, setOptions(a, conn, "{\"provider\":\"agent:codex\",\"model\":\"gpt-6-luna\",\"reasoning_effort\":\"impossible\"}", fixture));
    try std.testing.expectError(error.InvalidOptions, setOptions(a, conn, "bad", fixture));
    try std.testing.expectError(error.ModelUnavailable, resolvePin(a, conn, fixture, "agent:codex", "missing"));
    try std.testing.expectError(error.AgentUnavailable, resolvePin(a, conn, fixture, "agent:missing", "x"));
    try std.testing.expectError(error.InvalidCatalog, resolvePin(a, conn, "bad", "agent:codex", "x"));
}

test "CK-PRV-004 C2 external cached rows receive core text capability" {
    const a = std.testing.allocator;
    var c = try db.Connection.open(a, ":memory:");
    defer c.close();
    try db.Migrator.init(a).migrate(c, &db.catalog_schema);
    const text = "[{\"provider\":\"agent:opencode\",\"models\":[{\"slug\":\"baai/bge-m3\"},{\"slug\":\"nvidia/studiovoice\"},{\"slug\":\"opencode/chat-free\"}]}]";
    const result = try withOptions(a, c, text);
    defer a.free(result);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, result, .{});
    defer parsed.deinit();
    const models = parsed.value.array.items[0].object.get("models").?.array.items;
    for (models, 0..) |model, i| {
        const flag = model.object.get("text_gen") orelse return error.TestUnexpectedResult;
        try std.testing.expectEqual(i == 2, flag.bool);
    }
}

test "HARD5. SQL NULL settings cache and model options fail honestly" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try conn.exec("CREATE TABLE settings(key TEXT,value TEXT); INSERT INTO settings VALUES('null-setting',NULL)");
    try conn.exec("CREATE TABLE external_agent_cache(id INTEGER,payload_json TEXT,detected_at INTEGER); INSERT INTO external_agent_cache VALUES(1,NULL,1000)");
    try conn.exec("CREATE TABLE external_model_options(provider TEXT,model TEXT,reasoning_effort TEXT); INSERT INTO external_model_options VALUES('agent:codex','gpt-6-luna',NULL)");
    try std.testing.expectError(error.SettingUnavailable, readSetting(a, conn, "null-setting"));
    try std.testing.expect((try cached(a, conn, 1001)) == null);
    try std.testing.expect((try lastKnown(a, conn, 1001)) == null);
    try std.testing.expectError(error.InvalidOptions, withOptions(a, conn, fixture));
    try std.testing.expectError(error.InvalidOptions, resolvePin(a, conn, fixture, "agent:codex", "gpt-6-luna"));
}
