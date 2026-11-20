//! Text roles use the detected subscription CLI in a read-only sandbox.
const std = @import("std");
const db = @import("db.zig");
const registry = @import("external_registry.zig");
const executor = @import("executor.zig");
const cli = @import("cli_worker.zig");
const policy = @import("external_cli_policy.zig");
const health = @import("health.zig");
const sessions = @import("external_session.zig");
const headless = @import("headless_adapter.zig");
const context = @import("external_context.zig");
const GetTickCount64 = @import("platform.zig").ticks;

pub const SessionOptions = struct {
    sink: sessions.Sink,
    resume_session: ?[]const u8 = null,
    timeout_ms: u64,
    event_sink: ?headless.EventSink = null,
    /// One policy snapshot for checkpoint lookup and this launch.
    inherit_personal_context: ?bool = null,
};

const SessionStream = struct {
    a: std.mem.Allocator,
    opts: SessionOptions,
    seen: bool = false,
    failure: ?anyerror = null,
    abort: *std.atomic.Value(bool),

    fn line(raw: *anyopaque, text: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.observe(text) catch |err| {
            self.failure = err;
            self.abort.store(true, .release);
        };
    }

    fn observe(self: *@This(), text: []const u8) !void {
        if (self.seen or self.failure != null) return;
        var p = std.json.parseFromSlice(std.json.Value, self.a, text, .{}) catch |err| switch (err) {
            error.OutOfMemory => return err,
            else => return,
        };
        defer p.deinit();
        if (p.value != .object) return;
        const ty = p.value.object.get("type") orelse return;
        if (ty != .string or !std.mem.eql(u8, ty.string, "thread.started")) return;
        const id = p.value.object.get("thread_id") orelse return;
        if (id != .string or !sessions.validId(id.string)) return;
        try self.opts.sink.call(.saved, id.string, "");
        if (self.opts.resume_session) |expected| if (std.mem.eql(u8, expected, id.string)) try self.opts.sink.call(.resumed, id.string, "");
        self.seen = true;
    }
};

fn callerCancelled(raw: ?*anyopaque) bool {
    const flag: *const std.atomic.Value(bool) = @ptrCast(@alignCast(raw orelse return false));
    return flag.load(.acquire);
}

pub fn recordTextCall(a: std.mem.Allocator, runtime: db.Connection, order_id: i64, role: []const u8, provider: []const u8, model: []const u8, success: bool) !void {
    const body = try std.json.Stringify.valueAlloc(a, .{ .role = role, .provider = provider, .model = model, .success = success, .cost_category = "subscription", .cost_usd = @as(?f64, null), .prompt_tokens = @as(?u64, null), .completion_tokens = @as(?u64, null) }, .{});
    defer a.free(body);
    const q = try runtime.prepare("INSERT INTO events(ts,source,kind,payload_json,order_id) VALUES(?,'external_completion','subscription_call_v1',?,?)");
    defer runtime.finalize(q);
    try db.bindInt(q, 1, health.nowMillis(runtime));
    try db.bindText(q, 2, body);
    try db.bindInt(q, 3, order_id);
    if (db.c.sqlite3_step(q) != db.c.SQLITE_DONE) return error.StepFailed;
}

pub fn finalMessage(a: std.mem.Allocator, transcript: []const u8) ![]u8 {
    var lines = std.mem.splitScalar(u8, transcript, '\n');
    var final: ?[]u8 = null;
    errdefer if (final) |text| a.free(text);
    while (lines.next()) |line| {
        var p = std.json.parseFromSlice(std.json.Value, a, line, .{}) catch continue;
        defer p.deinit();
        if (p.value != .object) continue;
        const kind = p.value.object.get("type") orelse continue;
        if (kind != .string or !std.mem.eql(u8, kind.string, "item.completed")) continue;
        const item = p.value.object.get("item") orelse continue;
        if (item != .object) continue;
        const ty = item.object.get("type") orelse continue;
        const text = item.object.get("text") orelse continue;
        if (ty != .string or text != .string or !std.mem.eql(u8, ty.string, "agent_message")) continue;
        const copy = try a.dupe(u8, text.string);
        if (final) |old| a.free(old);
        final = copy;
    }
    return final orelse error.EmptyCliResponse;
}

pub fn complete(a: std.mem.Allocator, catalog: db.Connection, provider: []const u8, model: []const u8, system: []const u8, user: []const u8, cwd: []const u8, abort: ?*const std.atomic.Value(bool), mock: ?[]const u8) ![]u8 {
    return completeImpl(a, catalog, provider, model, system, user, cwd, abort, mock, null, null);
}

pub fn completeWithSession(a: std.mem.Allocator, catalog: db.Connection, provider: []const u8, model: []const u8, system: []const u8, user: []const u8, cwd: []const u8, abort: ?*const std.atomic.Value(bool), mock: ?[]const u8, opts: SessionOptions) ![]u8 {
    return completeImpl(a, catalog, provider, model, system, user, cwd, abort, mock, opts, opts.event_sink);
}

/// Planning has no resumable task/session yet, but its warnings still belong
/// to the order and use the same public activity event as executor warnings.
pub fn completeForOrder(a: std.mem.Allocator, catalog: db.Connection, provider: []const u8, model: []const u8, system: []const u8, user: []const u8, cwd: []const u8, abort: ?*const std.atomic.Value(bool), mock: ?[]const u8, runtime: ?db.Connection, order_id: i64) ![]u8 {
    var events = PlanningEvents{ .a = a, .runtime = runtime, .order_id = order_id };
    const result = completeImpl(a, catalog, provider, model, system, user, cwd, abort, mock, null, .{ .ctx = &events, .callFn = PlanningEvents.call });
    if (events.failure) |e| {
        if (result) |text| a.free(text) else |_| {}
        return e;
    }
    return result;
}

const PlanningEvents = struct {
    a: std.mem.Allocator,
    runtime: ?db.Connection,
    order_id: i64,
    failure: ?anyerror = null,

    fn call(raw: *anyopaque, kind: headless.EventKind, text: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        self.record(kind, text) catch |e| {
            self.failure = e;
        };
    }

    fn record(self: *@This(), kind: headless.EventKind, text: []const u8) !void {
        const conn = self.runtime orelse return;
        const order_id = if (self.order_id > 0) self.order_id else blk: {
            // Same pre-task order resolution already used by llm_planner.
            const seq = try conn.prepare("SELECT COALESCE(MAX(id),0) FROM orders");
            defer conn.finalize(seq);
            if (db.c.sqlite3_step(seq) != db.c.SQLITE_ROW) return error.StepFailed;
            break :blk db.c.sqlite3_column_int64(seq, 0);
        };
        const body = try std.json.Stringify.valueAlloc(self.a, .{ .task_id = "planner", .kind = @tagName(kind), .text = text }, .{});
        defer self.a.free(body);
        const q = try conn.prepare("INSERT INTO events(ts,source,kind,payload_json,order_id) VALUES(?,'external_completion','external_agent_event',?,?)");
        defer conn.finalize(q);
        try db.bindInt(q, 1, health.nowMillis(conn));
        try db.bindText(q, 2, body);
        try db.bindInt(q, 3, order_id);
        if (db.c.sqlite3_step(q) != db.c.SQLITE_DONE) return error.StepFailed;
    }
};

fn completeImpl(a: std.mem.Allocator, catalog: db.Connection, provider: []const u8, model: []const u8, system: []const u8, user: []const u8, cwd: []const u8, abort: ?*const std.atomic.Value(bool), mock: ?[]const u8, session: ?SessionOptions, event_sink: ?headless.EventSink) anyerror![]u8 {
    const started = GetTickCount64();
    if (!std.mem.eql(u8, provider, "agent:codex")) return error.TextRoleUnsupported;
    if (abort) |flag| if (flag.load(.acquire)) return error.Cancelled;
    const inherit = if (session) |opts| opts.inherit_personal_context orelse try context.load(catalog) else try context.load(catalog);
    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();
    const worktree = try std.Io.Dir.cwd().realPathFileAlloc(io, cwd, a);
    defer a.free(worktree);
    var parent = try @import("platform.zig").environ().createMap(a);
    defer parent.deinit();
    var child = try context.environment(a, io, &parent, "codex", worktree, inherit);
    defer child.deinit();
    if (!inherit and mock == null) context.checkCodexGlobals(a, io, &child) catch |e| {
        if (event_sink) |sink| sink.call(.warning, "external_context_blocked: Codex no se lanzó como auditor porque tienes instrucciones personales (AGENTS.md en tu carpeta de Codex) y DevAgents, por defecto, no se las pasa. Actívalo en Configuración › Agentes externos › «Heredar mis instrucciones personales» o quita ese AGENTS.md de tu perfil de Codex.");
        return e;
    };
    if (policy.codexBilling(&child)) return error.ApiBillingForbidden;
    const cat = (try registry.cached(a, catalog, health.nowSeconds(catalog))) orelse return error.ExternalCatalogUnavailable;
    defer a.free(cat);
    const pin = if (mock != null)
        try registry.resolvePin(a, catalog, cat, provider, model)
    else
        try registry.revalidateCodexPin(a, catalog, cat, model, threaded.io(), &child);
    defer pin.deinit(a);
    // El launch verificado posee Node/JS/ancestros hasta terminar el worker;
    // un prefijo copiado y liberado antes del hijo dejaría la cadena sustituible.
    var launch: ?executor.BatchLaunch = if (mock == null) try executor.prepareBatchLaunch(a, pin.exe) else null;
    defer if (launch) |*value| value.deinit(a);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    if (launch) |value| {
        try argv.append(a, value.exe);
        try argv.appendSlice(a, value.prefix);
    } else try argv.append(a, pin.exe);
    try appendTextArgvWithPolicy(a, &argv, model, worktree, inherit);
    if (session) |opts| try appendSessionArgv(a, &argv, opts.resume_session);
    const effort = try effortArgument(a, pin.effort);
    defer if (effort) |e| a.free(e);
    if (effort) |e| try argv.appendSlice(a, &.{ "-c", e });
    const original_prompt = if (session != null and session.?.resume_session != null)
        try a.dupe(u8, headless.CONTINUATION_PROMPT)
    else
        try std.fmt.allocPrint(a, "{s}\n\n{s}\n\nDevuelve solo el JSON solicitado en tu respuesta final. No escribas archivos ni ejecutes comandos.", .{ system, user });
    defer a.free(original_prompt);
    const project_prompt = if (!inherit and mock == null) try context.projectPrompt(a, io, worktree, original_prompt) else null;
    defer if (project_prompt) |text| a.free(text);
    const prompt = project_prompt orelse original_prompt;
    var outside = if (mock == null or event_sink != null) try context.OutsideGuard.init(a, io, worktree) else null;
    defer if (outside) |*guard| guard.deinit();
    var worker = cli.ExternalCliWorker.init(a, threaded.io(), argv.items, if (session) |opts| opts.timeout_ms else @import("live_worker.zig").getModelCallTimeoutMs());
    worker.environ_map = &child;
    worker.cwd = worktree;
    worker.stdin_mode = .prompt_text;
    worker.abort_flag = abort;
    var local_abort = std.atomic.Value(bool).init(false);
    var stream: ?SessionStream = if (session) |opts| .{ .a = a, .opts = opts, .abort = &local_abort } else null;
    if (stream) |*value| {
        worker.sink = .{ .ctx = value, .callFn = SessionStream.line };
        worker.abort_flag = &local_abort;
        worker.is_cancelled_fn = callerCancelled;
        worker.cancelled_ctx = if (abort) |flag| @ptrCast(@constCast(flag)) else null;
    }
    worker.mock_output = mock;
    if (event_sink) |sink| sink.call(.status, if (inherit)
        "external_context_policy: personal_context=true; skills/MCP=inherit; role=read_only"
    else
        "external_context_policy: personal_context=false; skills/MCP=inherit; role=read_only");
    const collected = worker.runCollect(a, .{ .id = "text-role", .task_type = .auditar, .department = "auditoria", .description = prompt, .contract_fields = &.{}, .depends_on = &.{} });
    if (outside) |*guard| headless.reportOutsideWorkspace(a, io, guard, event_sink);
    var outcome = try collected;
    defer outcome.deinit(a);
    // The in-memory CLI double returns a transcript without invoking its sink.
    if (mock != null) if (stream) |*value| {
        var lines = std.mem.splitScalar(u8, outcome.output, '\n');
        while (lines.next()) |line| SessionStream.line(value, line);
    };
    if (stream) |value| if (value.failure) |err| return err;
    if (outcome.cancelled) return error.Cancelled;
    if (outcome.limit_hit) return error.Cancelled;
    if (outcome.timed_out) return error.Timeout;
    if (outcome.truncated) return error.CliResponseTooLarge;
    if (outcome.exit_code != 0) {
        if (session) |opts| if (opts.resume_session != null and !stream.?.seen) {
            if (headless.resumeRejection(outcome.output)) |reason| {
                const elapsed = GetTickCount64() -| started;
                if (elapsed >= opts.timeout_ms) return error.Timeout;
                const message = try std.fmt.allocPrint(a, "no se pudo reanudar: {s}; se relanza", .{reason});
                defer a.free(message);
                try opts.sink.call(.restart, opts.resume_session, message);
                var fresh = opts;
                fresh.resume_session = null;
                fresh.timeout_ms -= elapsed;
                return completeImpl(a, catalog, provider, model, system, user, cwd, abort, mock, fresh, event_sink);
            }
        };
        return error.CliProcessFailed;
    }
    return finalMessage(a, outcome.output);
}

fn appendSessionArgv(a: std.mem.Allocator, argv: *std.ArrayList([]const u8), id: ?[]const u8) !void {
    for (argv.items, 0..) |arg, index| if (std.mem.eql(u8, arg, "--ephemeral")) {
        _ = argv.orderedRemove(index);
        break;
    };
    if (id) |value| {
        if (!sessions.validId(value)) return error.InvalidSessionId;
        try argv.appendSlice(a, &.{ "resume", value });
    }
}

test "CK-COMP-002 read only Codex task persists and resumes its session without changing the sandbox" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    const Sink = struct {
        conn: db.Connection,
        fn call(raw: *anyopaque, kind: sessions.Kind, id: ?[]const u8, reason: []const u8) anyerror!void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            try sessions.record(std.testing.allocator, self.conn, .{ .order_id = 11, .task_id = "audit", .cli = "codex", .model = "gpt-6.1-sol", .worktree = "." }, kind, id, reason);
        }
    };
    var catalog = try db.Connection.open(a, ":memory:");
    defer catalog.close();
    try db.Migrator.init(a).migrate(catalog, &db.catalog_schema);
    const q = try catalog.prepare("INSERT INTO external_agent_cache(id,payload_json,detected_at) VALUES(1,?,?)");
    defer catalog.finalize(q);
    try db.bindText(q, 1, "[{\"provider\":\"agent:codex\",\"session\":\"suscripcion\",\"exe\":\"C:/fixture/codex.exe\",\"version\":\"0.159.2\",\"models\":[{\"slug\":\"gpt-6.1-sol\"}]}]");
    try db.bindInt(q, 2, health.nowSeconds(catalog));
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(q));
    var runtime = try db.Connection.open(a, ":memory:");
    defer runtime.close();
    try db.Migrator.init(a).migrate(runtime, &db.runtime_schema);
    var sink = Sink{ .conn = runtime };
    const mock = "{\"type\":\"thread.started\",\"thread_id\":\"audit-123\"}\n{\"type\":\"thread.started\",\"thread_id\":\"audit-123\"}\n{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"PASS fixture\"}}\n";
    for ([_]?[]const u8{ null, "audit-123" }) |id| {
        const result = try completeWithSession(a, catalog, "agent:codex", "gpt-6.1-sol", "audit", "FULL AUDIT TASK", ".", null, mock, .{ .sink = .{ .ctx = &sink, .callFn = Sink.call }, .resume_session = id, .timeout_ms = 10000 });
        defer a.free(result);
        try std.testing.expectEqualStrings("PASS fixture", result);
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(a);
        try appendTextArgv(a, &argv, "gpt-6.1-sol", ".");
        try appendSessionArgv(a, &argv, id);
        for (argv.items) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--ephemeral"));
        try std.testing.expectEqualStrings("read-only", argv.items[3]);
        if (id) |value| {
            try std.testing.expectEqualStrings("resume", argv.items[argv.items.len - 2]);
            try std.testing.expectEqualStrings(value, argv.items[argv.items.len - 1]);
        }
    }
    const count = try runtime.prepare("SELECT COUNT(*) FROM events WHERE kind='external_session_saved'");
    defer runtime.finalize(count);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(count));
    try std.testing.expectEqual(@as(i64, 2), db.c.sqlite3_column_int64(count, 0));
    const resumed = try runtime.prepare("SELECT COUNT(*) FROM events WHERE kind='external_session_resumed'");
    defer runtime.finalize(resumed);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(resumed));
    try std.testing.expectEqual(@as(i64, 1), db.c.sqlite3_column_int64(resumed, 0));
}

test "ORDENES Codex text response ignores stderr tools and malformed lines" {
    const a = std.testing.allocator;
    const result = try finalMessage(a, "stderr\n{bad}\n{\"type\":\"item.completed\",\"item\":{\"type\":\"command_execution\",\"text\":\"fake\"}}\n{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"{\\\"kind\\\":\\\"chat\\\",\\\"reply\\\":\\\"Hola\\\"}\"}}\n");
    defer a.free(result);
    try std.testing.expectEqualStrings("{\"kind\":\"chat\",\"reply\":\"Hola\"}", result);

    try std.testing.expectError(error.EmptyCliResponse, finalMessage(a, "{}\nerror\n"));
    var c = try db.Connection.open(a, ":memory:");
    defer c.close();
    try std.testing.expectError(error.TextRoleUnsupported, complete(a, c, "agent:other", "m", "", "", ".", null, ""));
    var stop = std.atomic.Value(bool).init(true);
    try std.testing.expectError(error.Cancelled, complete(a, c, "agent:codex", "m", "", "", ".", &stop, ""));
}

test "ORDENES subscription text mock preserves pin final message and read only roles" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var c = try db.Connection.open(a, ":memory:");
    defer c.close();
    try db.Migrator.init(a).migrate(c, &db.catalog_schema);
    const q = try c.prepare("INSERT INTO external_agent_cache(id,payload_json,detected_at) VALUES(1,?,?)");
    defer c.finalize(q);
    try db.bindText(q, 1, "[{\"provider\":\"agent:codex\",\"session\":\"suscripcion\",\"exe\":\"C:/fixture/codex.exe\",\"version\":\"0.159.2\",\"models\":[{\"slug\":\"gpt-6.1-sol\"}]}]");
    try db.bindInt(q, 2, health.nowSeconds(c));
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(q));
    const mock = "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"{\\\"kind\\\":\\\"chat\\\",\\\"reply\\\":\\\"Hola\\\"}\"}}\n";
    try c.exec("INSERT INTO settings(key,value) VALUES('paid_calls_authorized','200'),('paid_calls_spent','200')");
    const result = try complete(a, c, "agent:codex", "gpt-6.1-sol", "planner", "Hola", ".", null, mock);
    defer a.free(result);
    try std.testing.expectEqualStrings("{\"kind\":\"chat\",\"reply\":\"Hola\"}", result);
    try std.testing.expectEqual(@as(u64, 200), @import("spend_budget.zig").estado(c).consumidas);
    for ([_][]const u8{ "free", "hybrid", "paid" }) |mode| {
        const set = try c.prepare("INSERT OR REPLACE INTO settings(key,value) VALUES('governance_mode',?)");
        try db.bindText(set, 1, mode);
        try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(set));
        c.finalize(set);
        for ([_]u64{ 200, 201 }) |authorized| {
            try @import("spend_budget.zig").autorizar(c, authorized);
            const reply = try complete(a, c, "agent:codex", "gpt-6.1-sol", "planner", "Hola", ".", null, mock);
            defer a.free(reply);
            try std.testing.expectEqualStrings(result, reply);
            try std.testing.expectEqual(@as(u64, 200), @import("spend_budget.zig").estado(c).consumidas);
            std.debug.print("R2_SUBSCRIPTION mode={s} authorized={d} spent=200\n", .{ mode, authorized });
        }
    }
    try std.testing.expectError(error.ModelUnavailable, complete(a, c, "agent:codex", "missing", "", "", ".", null, mock));
    try std.testing.expectError(error.EmptyCliResponse, complete(a, c, "agent:codex", "gpt-6.1-sol", "", "", ".", null, ""));
}

test "ORDENES subscription ledger keeps unknown tokens and dollars null" {
    const a = std.testing.allocator;
    var c = try db.Connection.open(a, ":memory:");
    defer c.close();
    try db.Migrator.init(a).migrate(c, &db.runtime_schema);
    try recordTextCall(a, c, 0, "planner", "agent:codex", "gpt-6.1-sol", true);
    const q = try c.prepare("SELECT payload_json FROM events WHERE kind='subscription_call_v1'");
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(q));
    const text = std.mem.span(db.c.sqlite3_column_text(q, 0));
    try std.testing.expect(std.mem.indexOf(u8, text, "\"prompt_tokens\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "\"cost_usd\":null") != null);
    c.finalize(q);
    try c.exec("DROP TABLE events");
    try std.testing.expectError(error.PrepareFailed, recordTextCall(a, c, 0, "planner", "agent:codex", "gpt-6.1-sol", false));
}

fn appendTextArgv(a: std.mem.Allocator, argv: *std.ArrayList([]const u8), model: []const u8, cwd: []const u8) !void {
    try appendTextArgvWithPolicy(a, argv, model, cwd, false);
}

fn appendTextArgvWithPolicy(a: std.mem.Allocator, argv: *std.ArrayList([]const u8), model: []const u8, cwd: []const u8, inherit: bool) !void {
    try argv.appendSlice(a, &.{ "exec", "--json", "-s", "read-only", "-c", "approval_policy=\"never\"", "--ephemeral", "--skip-git-repo-check", "-m", model, "-C", cwd });
    try argv.appendSlice(a, &.{ "-c", policy.CODEX_LOGIN_CONFIG });
    try context.appendCodexArgs(a, argv, inherit);
}

test "CK-CAB-027 text roles preserve user capabilities and disable personal memory by default" {
    const a = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try appendTextArgv(a, &argv, "model", "C:\\order");
    var memory_off = false;
    for (argv.items) |arg| {
        try std.testing.expect(!std.mem.eql(u8, arg, "--ignore-user-config"));
        if (std.mem.eql(u8, arg, "memories.use_memories=false")) memory_off = true;
    }
    try std.testing.expect(memory_off);
}

test "ORDENES RELOJ Codex text argv preserves model workspace and read only sandbox" {
    const a = std.testing.allocator;
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try appendTextArgv(a, &argv, "gpt-6.1-sol", "C:/fixture");
    try std.testing.expectEqualStrings("--json", argv.items[1]);
    try std.testing.expectEqualStrings("read-only", argv.items[3]);
    try std.testing.expectEqualStrings("approval_policy=\"never\"", argv.items[5]);
    try std.testing.expectEqualStrings("gpt-6.1-sol", argv.items[9]);
    try std.testing.expectEqualStrings("C:/fixture", argv.items[11]);
    try std.testing.expectEqualStrings("-c", argv.items[12]);
    try std.testing.expectEqualStrings(policy.CODEX_LOGIN_CONFIG, argv.items[13]);
}

fn effortArgument(a: std.mem.Allocator, effort: ?[]const u8) !?[]u8 {
    const level = effort orelse return null;
    if (level.len == 0) return null;
    return try std.fmt.allocPrint(a, "model_reasoning_effort=\"{s}\"", .{level});
}

test "ORDENES subscription provider default effort omits empty CLI override" {
    const a = std.testing.allocator;
    try std.testing.expect((try effortArgument(a, null)) == null);
    try std.testing.expect((try effortArgument(a, "")) == null);
    const high = (try effortArgument(a, "high")).?;
    defer a.free(high);
    try std.testing.expectEqualStrings("model_reasoning_effort=\"high\"", high);
}

test "CK-CAB-027 planner CLI scope warnings persist on the order without a task session" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const temp = (try headless.defaultGetEnv(a, "TEMP")) orelse return error.EnvironmentUnavailable;
    defer a.free(temp);
    const root = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "beats-cab027-planning-{d}", .{ temp, GetTickCount64() });
    defer a.free(root);
    try std.Io.Dir.cwd().createDir(io, root, .default_dir);
    defer std.Io.Dir.cwd().deleteTree(io, root) catch |e| std.debug.print("CK-CAB-027 planning cleanup: {s}\n", .{@errorName(e)});
    var catalog = try db.Connection.open(a, ":memory:");
    defer catalog.close();
    try db.Migrator.init(a).migrate(catalog, &db.catalog_schema);
    const cache = try catalog.prepare("INSERT INTO external_agent_cache(id,payload_json,detected_at) VALUES(1,?,?)");
    defer catalog.finalize(cache);
    try db.bindText(cache, 1, "[{\"provider\":\"agent:codex\",\"session\":\"suscripcion\",\"exe\":\"C:/fixture/codex.exe\",\"version\":\"0.159.2\",\"models\":[{\"slug\":\"gpt-6.1-sol\"}]}]");
    try db.bindInt(cache, 2, health.nowSeconds(catalog));
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(cache));
    var runtime = try db.Connection.open(a, ":memory:");
    defer runtime.close();
    try db.Migrator.init(a).migrate(runtime, &db.runtime_schema);
    const mock = "{\"type\":\"item.completed\",\"item\":{\"type\":\"agent_message\",\"text\":\"fixture plan\"}}\n";
    const result = try completeForOrder(a, catalog, "agent:codex", "gpt-6.1-sol", "planner", "TASK", root, null, mock, runtime, 77);
    defer a.free(result);
    try std.testing.expectEqualStrings("fixture plan", result);
    {
        const q = try runtime.prepare("SELECT COUNT(*) FROM events WHERE order_id=77 AND kind='external_agent_event' AND json_extract(payload_json,'$.kind')='warning' AND json_extract(payload_json,'$.text') LIKE '%sin repo antecesor: no se vigila fuera de la carpeta%'");
        defer runtime.finalize(q);
        try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(q));
        try std.testing.expectEqual(@as(i64, 1), db.c.sqlite3_column_int64(q, 0));
    }
    try runtime.exec("DROP TABLE events");
    try std.testing.expectError(error.PrepareFailed, completeForOrder(a, catalog, "agent:codex", "gpt-6.1-sol", "planner", "TASK", root, null, mock, runtime, 77));
    std.debug.print("[CK-CAB-027 r2] planner warning attached to order 77; missing event table returns explicit error\n", .{});
}
