const std = @import("std");
const b = @import("connector_v2_bridge.zig");
const p = @import("providers");
const a = std.testing.allocator;
const tools = [_]p.connector_v2.ToolDefinition{.{ .name = "run_command", .description = "Execute governed command", .parameters_json = "{\"type\":\"object\"}" }};
const openai_tool = "{\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{\"id\":\"one\",\"type\":\"function\",\"function\":{\"name\":\"run_command\",\"arguments\":\"{\\\"exe\\\":\\\"zig\\\"}\"}}]},\"finish_reason\":\"tool_calls\"}]}";
const openai_done = "{\"choices\":[{\"message\":{\"content\":\"verified\"},\"finish_reason\":\"stop\"}]}";
const anthropic_tool = "{\"stop_reason\":\"tool_use\",\"content\":[{\"type\":\"thinking\",\"thinking\":\"inspect\",\"signature\":\"sig\"},{\"type\":\"tool_use\",\"id\":\"one\",\"name\":\"run_command\",\"input\":{\"exe\":\"zig\"}}]}";
const anthropic_done = "{\"stop_reason\":\"end_turn\",\"content\":[{\"type\":\"text\",\"text\":\"verified\"}]}";
const gemini_tool = "{\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"role\":\"model\",\"parts\":[{\"thoughtSignature\":\"sig\",\"functionCall\":{\"id\":\"one\",\"name\":\"run_command\",\"args\":{\"exe\":\"zig\"}}}]}}]}";
const gemini_done = "{\"candidates\":[{\"finishReason\":\"STOP\",\"content\":{\"role\":\"model\",\"parts\":[{\"text\":\"verified\"}]}}]}";
const Fixture = struct {
    attempts: usize = 0,
    executions: usize = 0,
    prepared: usize = 0,
    proto: p.connector_v2.WireProtocol = .openai_compatible,
    first_response: []const u8 = openai_tool,
    final_response: []const u8 = openai_done,
    cancel: bool = false,
    cancel_on_execute: bool = false,
    cancel_on_prepare: bool = false,
    fail_execute: bool = false,
    provider: []const u8 = "fixture",
    model: []const u8 = "fixture",
    tools_measured_live: bool = false,
    max_rounds: usize = 5,
    fn prepare(ctx: ?*anyopaque, body: []const u8) anyerror!void {
        const f: *Fixture = @ptrCast(@alignCast(ctx.?));
        var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer parsed.deinit();
        const root = parsed.value.object;
        try std.testing.expect(root.contains("tools"));
        const gemini = f.proto == .gemini_v1beta;
        const anthropic = f.proto == .anthropic_v1;
        const messages = root.get(if (gemini) "contents" else "messages").?.array.items;
        if (f.prepared == 0) {
            try std.testing.expectEqual(@as(usize, if (!gemini and !anthropic) 2 else 1), messages.len);
            try std.testing.expect(std.mem.indexOf(u8, body, "fixture user") != null);
        } else {
            const last = messages[messages.len - 1].object;
            if (gemini) {
                const result = last.get("parts").?.array.items[0].object.get("functionResponse").?.object;
                try std.testing.expectEqualStrings("one", result.get("id").?.string);
                try std.testing.expect(std.mem.indexOf(u8, body, "thoughtSignature") != null);
            } else if (anthropic) {
                try std.testing.expectEqualStrings("one", last.get("content").?.array.items[0].object.get("tool_use_id").?.string);
                try std.testing.expect(std.mem.indexOf(u8, body, "signature") != null);
            } else try std.testing.expectEqualStrings("one", last.get("tool_call_id").?.string);
            try std.testing.expect(std.mem.indexOf(u8, body, "executed-output") != null);
        }
        f.prepared += 1;
        if (f.cancel_on_prepare) f.cancel = true;
    }
    fn attempt(ctx: ?*anyopaque) anyerror![]const u8 {
        const f: *Fixture = @ptrCast(@alignCast(ctx.?));
        f.attempts += 1;
        return if (f.attempts == 1) f.first_response else f.final_response;
    }
    fn execute(ctx: ?*anyopaque, name: []const u8, args: []const u8) anyerror![]const u8 {
        const f: *Fixture = @ptrCast(@alignCast(ctx.?));
        try std.testing.expectEqualStrings("run_command", name);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, args, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings("zig", parsed.value.object.get("exe").?.string);
        f.executions += 1;
        if (f.fail_execute) return error.PermissionRequired;
        if (f.cancel_on_execute) f.cancel = true;
        return "executed-output";
    }
    fn isCancelled(ctx: ?*anyopaque) bool {
        return @as(*Fixture, @ptrCast(@alignCast(ctx.?))).cancel;
    }
    fn call(f: *Fixture) !b.CallOutcome {
        return b.callWithTools(a, .{ .protocol = f.proto, .provider = f.provider, .model = f.model, .tools_measured_live = f.tools_measured_live, .system_prompt = @as([]const u8, "fixture system"), .user_prompt = @as([]const u8, "fixture user"), .tools = &tools, .max_rounds = f.max_rounds, .set_request_fn = prepare, .attempt_fn = attempt, .attempt_ctx = f, .tool_executor_fn = execute, .tool_executor_ctx = f, .is_cancelled_fn = @as(?*const fn (?*anyopaque) bool, isCancelled), .cancelled_ctx = f });
    }
};
fn destroy(outcome: b.CallOutcome) void {
    switch (outcome) {
        .completed => |c| c.deinit(a),
        .exhausted => |r| a.free(r),
        else => {},
    }
}
test "BRIDGE-TOOL actual roundtrip OpenAI Anthropic Gemini preserves tool IDs and signatures" {
    for ([_]p.connector_v2.WireProtocol{ .openai_compatible, .anthropic_v1, .gemini_v1beta }, [_][]const u8{ openai_tool, anthropic_tool, gemini_tool }, [_][]const u8{ openai_done, anthropic_done, gemini_done }) |proto, first_response, final_response| {
        var f = Fixture{ .proto = proto, .first_response = first_response, .final_response = final_response };
        const result = try f.call();
        defer destroy(result);
        try std.testing.expect(result == .completed);
        try std.testing.expectEqualStrings("verified", result.completed.content);
        try std.testing.expectEqual(@as(usize, 2), f.attempts);
        try std.testing.expectEqual(@as(usize, 1), f.executions);
    }
}
test "BRIDGE-TOOL cancellation before HTTP and after execution prevents another call" {
    var f = Fixture{ .cancel = true };
    const early = try f.call();
    defer destroy(early);
    try std.testing.expect(early == .cancelled);
    try std.testing.expectEqual(@as(usize, 0), f.attempts);
    f.cancel = false;
    f.cancel_on_execute = true;
    const late = try f.call();
    defer destroy(late);
    try std.testing.expect(late == .cancelled);
    try std.testing.expectEqual(@as(usize, 1), f.attempts);
    try std.testing.expectEqual(@as(usize, 1), f.executions);
}
test "BRIDGE-TOOL duplicate IDs across rounds never repeat a side effect" {
    var f = Fixture{ .final_response = openai_tool };
    const r = try f.call();
    defer destroy(r);
    try std.testing.expect(r == .exhausted);
    try std.testing.expectEqualStrings("DuplicateToolCall", r.exhausted);
    try std.testing.expectEqual(@as(usize, 1), f.executions);
}
test "BRIDGE-TOOL cancellation during preparation prevents HTTP" {
    var f = Fixture{ .cancel_on_prepare = true };
    const r = try f.call();
    defer destroy(r);
    try std.testing.expect(r == .cancelled);
    try std.testing.expectEqual(@as(usize, 0), f.attempts);
}
test "BRIDGE-TOOL permission rejection propagates without repeating operation" {
    var f = Fixture{ .fail_execute = true };
    const r = try f.call();
    defer destroy(r);
    try std.testing.expect(r == .exhausted);
    try std.testing.expectError(error.PermissionRequired, b.classifyExhaustionReason(r.exhausted));
    try std.testing.expectEqual(@as(usize, 1), f.attempts);
    try std.testing.expectEqual(@as(usize, 1), f.executions);
}
test "BRIDGE-TOOL exhausted rounds do not execute an unreviewable command" {
    var f = Fixture{ .max_rounds = 1 };
    const r = try f.call();
    defer destroy(r);
    try std.testing.expect(r == .exhausted);
    try std.testing.expectEqualStrings("ToolRoundsExhausted", r.exhausted);
    try std.testing.expectEqual(@as(usize, 0), f.executions);
}
test "BRIDGE-TOOL invalid empty truncated and undeclared responses never complete" {
    for ([_][]const u8{ "", "{}", "{\"choices\":[{\"finish_reason\":\"length\",\"message\":{\"content\":\"partial\"}}]}", "{\"choices\":[{\"finish_reason\":\"stop\",\"message\":{\"content\":\"\"}}]}", "{\"choices\":[{\"finish_reason\":\"tool_calls\",\"message\":{\"tool_calls\":[{\"id\":\"x\",\"type\":\"function\",\"function\":{\"name\":\"other\",\"arguments\":\"{}\"}}]}}]}" }) |response| {
        var f = Fixture{ .first_response = response };
        const r = try f.call();
        defer destroy(r);
        try std.testing.expect(r == .exhausted);
        try std.testing.expectEqual(@as(usize, 0), f.executions);
        try std.testing.expectEqual(@as(usize, 1), f.attempts);
    }
}

test "BRIDGE-TOOL #874 Cohere reasoning model is never sent a native tool body (no HTTP, repair not spent)" {
    // Cohere command-a-reasoning-08-2025 respondió como worker normal pero
    // rechaza `tools` con HTTP 422 (orden #874). El bridge debe abortar ANTES
    // del primer intento HTTP y clasificar el motivo para que el motor rote.
    var f = Fixture{ .provider = "Cohere", .model = "command-a-reasoning-08-2025" };
    const r = try f.call();
    defer destroy(r);
    try std.testing.expect(r == .exhausted);
    try std.testing.expectEqualStrings("ToolsUnsupportedByModel", r.exhausted);
    try std.testing.expectError(error.ToolsUnsupportedByModel, b.classifyExhaustionReason(r.exhausted));
    // Cero peticiones salieron al proveedor: la sesión no se gasta en un 422.
    try std.testing.expectEqual(@as(usize, 0), f.attempts);
    try std.testing.expectEqual(@as(usize, 0), f.executions);
}

test "BRIDGE-TOOL #874 control: Cohere non-reasoning and other vendors keep tools" {
    // Control negativo: la guarda es específica (Cohere + reasoning). Un modelo
    // de Cohere sin reasoning, o un modelo ajeno, siguen por la vía normal.
    for ([_]Fixture{
        .{ .provider = "Cohere", .model = "command-a-03-2025" },
        .{ .provider = "OpenAI", .model = "o-reasoning-model" },
        .{ .provider = "OpenCode", .model = "deepseek-v4-flash-free" },
    }) |seed| {
        var f = seed;
        const r = try f.call();
        defer destroy(r);
        try std.testing.expect(r == .completed);
        try std.testing.expectEqual(@as(usize, 2), f.attempts);
        try std.testing.expectEqual(@as(usize, 1), f.executions);
    }
}

test "BRIDGE-TOOL #874 nombre sin distinguir mayúsculas veta igual (el segundo auditor P1)" {
    // La lista conservadora compara el nombre del modelo sin distinguir
    // mayúsculas: `Command-A-REASONING-X` de `cohere` también se aborta.
    var f = Fixture{ .provider = "cohere", .model = "Command-A-REASONING-X" };
    const r = try f.call();
    defer destroy(r);
    try std.testing.expect(r == .exhausted);
    try std.testing.expectEqualStrings("ToolsUnsupportedByModel", r.exhausted);
    try std.testing.expectEqual(@as(usize, 0), f.attempts);
}

/// B1 (10-nov): herramientas diferidas (patrón ToolSearch). Respuestas en
/// orden; cada petición anota los nombres declarados en `tools`.
const Deferred = struct {
    responses: []const []const u8,
    attempts: usize = 0,
    declared: [4][8][]const u8 = undefined,
    declared_len: [4]usize = @splat(0),
    bodies: [4]usize = @splat(0),
    loader_results: usize = 0,
    executed: [4][]const u8 = undefined,
    executed_len: usize = 0,
    last_body_has_note: bool = false,
    last_body_has_not_loaded: bool = false,
    names: std.heap.ArenaAllocator,
    const deferred_tools = [_]p.connector_v2.ToolDefinition{
        .{ .name = "browser_text", .description = "Read page text", .parameters_json = "{\"type\":\"object\"}" },
        .{ .name = "browser_click", .description = "Click", .parameters_json = "{\"type\":\"object\"}" },
    };
    const base_tools = [_]p.connector_v2.ToolDefinition{
        .{ .name = "run_command", .description = "Execute governed command", .parameters_json = "{\"type\":\"object\"}" },
        .{ .name = "load_browser_tools", .description = "Loads the browser tools", .parameters_json = "{\"type\":\"object\"}" },
    };
    fn prepare(ctx: ?*anyopaque, body: []const u8) anyerror!void {
        const f: *Deferred = @ptrCast(@alignCast(ctx.?));
        var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer parsed.deinit();
        const round = f.attempts;
        for (parsed.value.object.get("tools").?.array.items, 0..) |tool, i| {
            const fun = tool.object.get("function").?.object;
            f.declared[round][i] = try f.names.allocator().dupe(u8, fun.get("name").?.string);
            f.declared_len[round] = i + 1;
        }
        f.bodies[round] = body.len;
        f.last_body_has_note = std.mem.indexOf(u8, body, "session_id=fixture") != null;
        f.last_body_has_not_loaded = std.mem.indexOf(u8, body, "tool_not_loaded") != null;
    }
    fn attempt(ctx: ?*anyopaque) anyerror![]const u8 {
        const f: *Deferred = @ptrCast(@alignCast(ctx.?));
        defer f.attempts += 1;
        return f.responses[f.attempts];
    }
    fn execute(ctx: ?*anyopaque, name: []const u8, _: []const u8) anyerror![]const u8 {
        const f: *Deferred = @ptrCast(@alignCast(ctx.?));
        f.executed[f.executed_len] = try f.names.allocator().dupe(u8, name);
        f.executed_len += 1;
        return "page-text";
    }
    fn declares(f: *const Deferred, round: usize, name: []const u8) bool {
        for (f.declared[round][0..f.declared_len[round]]) |n| if (std.mem.eql(u8, n, name)) return true;
        return false;
    }
    fn call(f: *Deferred) !b.CallOutcome {
        return b.callWithTools(a, .{ .protocol = p.connector_v2.WireProtocol.openai_compatible, .model = @as([]const u8, "fixture"), .system_prompt = @as([]const u8, "fixture system"), .user_prompt = @as([]const u8, "fixture user"), .tools = &base_tools, .deferred_tools = @as([]const p.connector_v2.ToolDefinition, &deferred_tools), .deferred_loader = @as([]const u8, "load_browser_tools"), .deferred_note = @as([]const u8, "Browser context: session_id=fixture"), .max_rounds = @as(usize, 5), .set_request_fn = prepare, .attempt_fn = attempt, .attempt_ctx = f, .tool_executor_fn = execute, .tool_executor_ctx = f });
    }
};

fn openaiCall(comptime id: []const u8, comptime name: []const u8) []const u8 {
    return "{\"choices\":[{\"message\":{\"content\":null,\"tool_calls\":[{\"id\":\"" ++ id ++ "\",\"type\":\"function\",\"function\":{\"name\":\"" ++ name ++ "\",\"arguments\":\"{}\"}}]},\"finish_reason\":\"tool_calls\"}]}";
}

test "B1 herramientas diferidas: el catálogo viaja solo desde la ronda siguiente a la cargadora" {
    var f = Deferred{ .names = .init(a), .responses = &.{ openaiCall("l1", "load_browser_tools"), openaiCall("b1", "browser_text"), openai_done } };
    defer f.names.deinit();
    const r = try f.call();
    defer destroy(r);
    try std.testing.expect(r == .completed);
    try std.testing.expectEqual(@as(usize, 3), f.attempts);
    // Ronda 1: solo las de siempre y la cargadora; ningún esquema del navegador.
    try std.testing.expectEqual(@as(usize, 2), f.declared_len[0]);
    try std.testing.expect(!f.declares(0, "browser_text") and !f.declares(0, "browser_click"));
    // Ronda 2 en adelante: las diferidas declaradas detrás; la cargadora sigue.
    try std.testing.expect(f.declares(1, "browser_text") and f.declares(1, "browser_click") and f.declares(1, "load_browser_tools"));
    try std.testing.expect(f.declares(2, "browser_text"));
    try std.testing.expect(f.bodies[1] > f.bodies[0]);
    // La cargadora la responde el bucle (sin ejecutor) y entrega la nota de
    // uso; la diferida sí pasa por el ejecutor gobernado.
    try std.testing.expectEqual(@as(usize, 1), f.executed_len);
    try std.testing.expectEqualStrings("browser_text", f.executed[0]);
    try std.testing.expect(f.last_body_has_note);
}

test "B1 herramientas diferidas: una diferida llamada sin cargar no se ejecuta; se carga y se repite" {
    var f = Deferred{ .names = .init(a), .responses = &.{ openaiCall("b0", "browser_text"), openaiCall("b1", "browser_text"), openai_done } };
    defer f.names.deinit();
    const r = try f.call();
    defer destroy(r);
    try std.testing.expect(r == .completed);
    try std.testing.expect(!f.declares(0, "browser_text"));
    try std.testing.expect(f.declares(1, "browser_text"));
    // La llamada prematura no tuvo efectos: solo la repetida llegó al ejecutor.
    try std.testing.expectEqual(@as(usize, 1), f.executed_len);
    try std.testing.expect(f.last_body_has_not_loaded);
    // Una herramienta que no está ni declarada ni diferida sigue rechazada.
    var g = Deferred{ .names = .init(a), .responses = &.{ openaiCall("x", "browser_nope"), openai_done } };
    defer g.names.deinit();
    const rejected = try g.call();
    defer destroy(rejected);
    try std.testing.expect(rejected == .exhausted);
    try std.testing.expectEqual(@as(usize, 0), g.executed_len);
}

test "BRIDGE-TOOL #874 la medición viva positiva manda sobre la lista (el segundo auditor P1)" {
    // El catálogo midió `cap_tool_calls=yes` (live_probe) para un modelo cuyo
    // nombre está en la lista conservadora: el llamador lo declara y el bridge
    // NO debe abortar la sesión. La petición sale por la vía normal.
    var f = Fixture{ .provider = "Cohere", .model = "command-a-reasoning-08-2025", .tools_measured_live = true };
    const r = try f.call();
    defer destroy(r);
    try std.testing.expect(r == .completed);
    try std.testing.expectEqual(@as(usize, 2), f.attempts);
    try std.testing.expectEqual(@as(usize, 1), f.executions);
}
