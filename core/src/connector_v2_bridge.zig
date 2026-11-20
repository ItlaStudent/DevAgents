const std = @import("std");
const providers = @import("providers");
const V = std.json.Value;
const A = std.mem.Allocator;
const Protocol = providers.connector_v2.WireProtocol;

pub const DEFAULT_MAX_ROUNDS: usize = 5;
pub const CompletedResponse = struct {
    content: []const u8,
    reasoning: []const u8,
    pub fn deinit(self: *const CompletedResponse, allocator: A) void {
        allocator.free(self.content);
        allocator.free(self.reasoning);
    }
};
pub const CallOutcome = union(enum) {
    completed: CompletedResponse,
    exhausted: []const u8,
    awaiting_paid_approval,
    cancelled,
};

pub fn classifyExhaustionReason(reason: []const u8) anyerror!void {
    inline for (.{ error.AuthFailed, error.QuotaExceeded, error.RateLimited, error.ModelNotFound, error.ProviderError, error.RequestFailed, error.ResponseFailed, error.Timeout, error.Cancelled, error.GovernanceDenied, error.PermissionRequired, error.PlanNotApproved, error.ToolRoundsExhausted, error.ToolsUnsupportedByModel, error.BudgetDenied }) |err| {
        if (std.mem.eql(u8, reason, @errorName(err))) return err;
    }
    return error.LlmCallFailed;
}

/// ¿El par (provider, model) admite tool calling nativo? Un modelo que no
/// lo admite hace que la sesión de herramientas muera con HTTP 422
/// (RequestFailed) sin haber corregido nada y gastando la reparación.
///
/// Cohere `command-a-reasoning-08-2025` admite peticiones sin herramientas
/// y devuelve HTTP 422 cuando la petición declara `tools`.
/// Los modelos de razonamiento de Cohere no combinan reasoning + function
/// calling en la Compatibility API, así que la sesión de tools NUNCA debe
/// salir con ese par. La lista de excepciones vive AQUÍ, en un solo punto.
///
/// Nota: es una regla conservadora por NOMBRE de modelo (no sustituye la
/// medición viva de capability en discovery_snapshots_v2 / agenticGateFor);
/// es la última red de seguridad del motor para no emitir una petición que ya
/// se sabe inválida. Cualquier modelo no listado se considera apto.
pub fn supportsToolCalling(provider: []const u8, model: []const u8) bool {
    if (std.ascii.eqlIgnoreCase(provider, "Cohere")) {
        // Comparación por nombre SIN distinguir mayúsculas (el segundo auditor P1): un
        // `Command-A-Reasoning-08-2025` también queda vetado por la lista.
        if (std.ascii.findIgnoreCase(model, "reasoning") != null) return false;
    }
    return true;
}

fn object(a: A) V {
    _ = a;
    return .{ .object = .{} };
}
fn array(a: A) V {
    return .{ .array = std.array_list.Managed(V).init(a) };
}
fn str(s: []const u8) V {
    return .{ .string = s };
}
fn put(a: A, o: *V, key: []const u8, value: V) !void {
    try o.object.put(a, key, value);
}
fn add(o: *V, value: V) !void {
    try o.array.append(value);
}
fn field(o: V, key: []const u8) !V {
    if (o != .object) return error.InvalidResponse;
    return o.object.get(key) orelse error.InvalidResponse;
}
fn string(v: V) ![]const u8 {
    if (v != .string) return error.InvalidResponse;
    return v.string;
}
fn first(v: V) !V {
    if (v != .array or v.array.items.len != 1) return error.InvalidResponse;
    return v.array.items[0];
}
fn json(a: A, value: anytype) ![]const u8 {
    return std.json.Stringify.valueAlloc(a, value, .{});
}
fn parse(a: A, bytes: []const u8) !V {
    return (try std.json.parseFromSlice(V, a, bytes, .{ .allocate = .alloc_always })).value;
}
fn textPart(a: A, text: []const u8) !V {
    var p = object(a);
    try put(a, &p, "text", str(text));
    return p;
}
fn message(a: A, role: []const u8, content: V, gemini: bool) !V {
    var m = object(a);
    try put(a, &m, "role", str(role));
    try put(a, &m, if (gemini) "parts" else "content", content);
    return m;
}
fn isGemini(p: Protocol) bool {
    return p == .gemini or p == .gemini_v1beta;
}
fn isAnthropic(p: Protocol) bool {
    return p == .anthropic or p == .anthropic_v1;
}

fn request(a: A, args: anytype) !V {
    const gemini = isGemini(args.protocol);
    const anthropic = isAnthropic(args.protocol);
    var root = object(a);
    if (!gemini) try put(a, &root, "model", str(args.model));
    if (!gemini) try put(a, &root, "stream", .{ .bool = false });
    if (anthropic) try put(a, &root, "max_tokens", .{ .integer = 4096 });
    var messages = array(a);
    if (args.system_prompt.len > 0) {
        if (gemini) {
            var parts = array(a);
            try add(&parts, try textPart(a, args.system_prompt));
            var system = object(a);
            try put(a, &system, "parts", parts);
            try put(a, &root, "systemInstruction", system);
        } else if (anthropic) {
            try put(a, &root, "system", str(args.system_prompt));
        } else try add(&messages, try message(a, "system", str(args.system_prompt), false));
    }
    var user: V = str(args.user_prompt);
    if (gemini) {
        user = array(a);
        try add(&user, try textPart(a, args.user_prompt));
    }
    if (@hasField(@TypeOf(args), "images")) {
        if (args.images.len > 0) {
            if (!gemini) {
                user = array(a);
                var text = try textPart(a, args.user_prompt);
                try put(a, &text, "type", str("text"));
                try add(&user, text);
            }
            for (args.images) |image| {
                var output: std.Io.Writer.Allocating = .init(a);
                defer output.deinit();
                var js: std.json.Stringify = .{ .writer = &output.writer, .options = .{} };
                if (gemini) try providers.gemini_v2_parser.writeImagePart(&js, image) else if (anthropic) try providers.anthropic_v2_parser.writeImagePart(&js, image) else try providers.openai_v2_parser.writeImagePart(&js, image);
                try add(&user, try parse(a, output.written()));
            }
        }
    }
    try add(&messages, try message(a, "user", user, gemini));
    try put(a, &root, if (gemini) "contents" else "messages", messages);
    try put(a, &root, "tools", try toolDefinitions(a, args.protocol, args.tools, &.{}));
    return root;
}

/// El campo `tools` de la petición. `extra` son las herramientas diferidas ya
/// cargadas (B1): se declaran detrás de las de siempre.
fn toolDefinitions(a: A, protocol: Protocol, tools: []const providers.connector_v2.ToolDefinition, extra: []const providers.connector_v2.ToolDefinition) !V {
    const gemini = isGemini(protocol);
    const anthropic = isAnthropic(protocol);
    var definitions = array(a);
    for ([_][]const providers.connector_v2.ToolDefinition{ tools, extra }) |list| for (list) |tool| {
        if (tool.name.len == 0) return error.InvalidToolDefinition;
        var definition = object(a);
        try put(a, &definition, "name", str(tool.name));
        try put(a, &definition, "description", str(tool.description));
        const schema = try parse(a, tool.parameters_json);
        if (schema != .object) return error.InvalidToolDefinition;
        try put(a, &definition, if (anthropic) "input_schema" else "parameters", schema);
        if (!gemini and !anthropic) {
            var wrapper = object(a);
            try put(a, &wrapper, "type", str("function"));
            try put(a, &wrapper, "function", definition);
            definition = wrapper;
        }
        try add(&definitions, definition);
    };
    if (gemini) {
        var wrapper = object(a);
        try put(a, &wrapper, "functionDeclarations", definitions);
        definitions = array(a);
        try add(&definitions, wrapper);
    }
    return definitions;
}

/// B1 (10-nov): el cuerpo JSON de la primera ronda, tal como sale hacia el
/// proveedor. Para medir lo que cuesta una petición sin llamar a nadie.
pub fn firstRequestJson(allocator: A, args: anytype) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const body = try request(arena.allocator(), args);
    return std.json.Stringify.valueAlloc(allocator, body, .{});
}

fn deferredArgs(args: anytype) struct { tools: []const providers.connector_v2.ToolDefinition, loader: []const u8, note: []const u8 } {
    if (@hasField(@TypeOf(args), "deferred_tools")) return .{ .tools = args.deferred_tools, .loader = args.deferred_loader, .note = args.deferred_note };
    return .{ .tools = &.{}, .loader = "", .note = "" };
}

fn inList(list: []const providers.connector_v2.ToolDefinition, name: []const u8) bool {
    for (list) |tool| if (std.mem.eql(u8, tool.name, name)) return true;
    return false;
}

/// Respuesta de la herramienta cargadora: qué se cargó y cómo se usa.
/// `premature`: el modelo llamó a una diferida sin haberla cargado (no ha
/// visto su esquema ni la nota de uso). No se ejecuta: se carga y se le pide
/// repetirla.
fn loaderResult(a: A, deferred: []const providers.connector_v2.ToolDefinition, note: []const u8, already: bool, premature: bool) ![]const u8 {
    var names = array(a);
    for (deferred) |tool| try add(&names, str(tool.name));
    var out = object(a);
    try put(a, &out, "ok", .{ .bool = !premature });
    if (premature) try put(a, &out, "error", str("tool_not_loaded: esta herramienta no se ejecutó; ya está cargada, repite la llamada con su esquema."));
    try put(a, &out, "already_loaded", .{ .bool = already });
    try put(a, &out, "tools", names);
    if (note.len > 0 and !already) try put(a, &out, "usage", str(note));
    return json(a, out);
}

const ToolCall = struct { id: []const u8, name: []const u8, arguments: []const u8 };
const Decoded = struct {
    assistant: V,
    calls: std.ArrayList(ToolCall) = .empty,
    content: std.ArrayList(u8) = .empty,
    reasoning: std.ArrayList(u8) = .empty,
};

fn decode(a: A, protocol: Protocol, response: V) !Decoded {
    if (response != .object) return error.InvalidResponse;
    if (response.object.contains("error")) return error.ProviderError;
    var d: Decoded = .{ .assistant = undefined };
    if (!isGemini(protocol) and !isAnthropic(protocol)) {
        const choice = try first(try field(response, "choices"));
        const finish = try string(try field(choice, "finish_reason"));
        if (std.mem.eql(u8, finish, "length")) return error.TruncatedResponse;
        if (!std.mem.eql(u8, finish, "stop") and !std.mem.eql(u8, finish, "tool_calls")) return error.InvalidResponse;
        d.assistant = try field(choice, "message");
        if (d.assistant != .object) return error.InvalidResponse;
        try put(a, &d.assistant, "role", str("assistant"));
        if (d.assistant.object.get("content")) |c| {
            if (c == .string) try d.content.appendSlice(a, c.string) else if (c != .null) return error.InvalidResponse;
        }
        if (d.assistant.object.get("reasoning_content")) |r| {
            if (r == .string) try d.reasoning.appendSlice(a, r.string);
        }
        if (d.assistant.object.get("tool_calls")) |calls| {
            if (calls != .array) return error.InvalidResponse;
            for (calls.array.items) |c| {
                const f = try field(c, "function");
                if (!std.mem.eql(u8, try string(try field(c, "type")), "function")) return error.InvalidResponse;
                try d.calls.append(a, .{ .id = try string(try field(c, "id")), .name = try string(try field(f, "name")), .arguments = try string(try field(f, "arguments")) });
            }
        }
        if (std.mem.eql(u8, finish, "tool_calls") != (d.calls.items.len > 0)) return error.InvalidResponse;
    } else {
        var parts: V = undefined;
        if (isGemini(protocol)) {
            const candidate = try first(try field(response, "candidates"));
            if (!std.mem.eql(u8, try string(try field(candidate, "finishReason")), "STOP")) return error.TruncatedResponse;
            d.assistant = try field(candidate, "content");
            parts = try field(d.assistant, "parts");
        } else {
            const finish = try string(try field(response, "stop_reason"));
            if (std.mem.eql(u8, finish, "max_tokens")) return error.TruncatedResponse;
            if (!std.mem.eql(u8, finish, "end_turn") and !std.mem.eql(u8, finish, "tool_use")) return error.InvalidResponse;
            parts = try field(response, "content");
            d.assistant = try message(a, "assistant", parts, false);
        }
        if (parts != .array) return error.InvalidResponse;
        for (parts.array.items) |part| {
            if (part != .object) return error.InvalidResponse;
            if (isGemini(protocol)) {
                if (part.object.get("text")) |t| {
                    const thought = part.object.get("thought");
                    if (thought != null and thought.? == .bool and thought.?.bool) {
                        try d.reasoning.appendSlice(a, try string(t));
                    } else try d.content.appendSlice(a, try string(t));
                }
                if (part.object.get("functionCall")) |f| {
                    const id = if (f == .object) f.object.get("id") else return error.InvalidResponse;
                    try d.calls.append(a, .{ .id = if (id) |i| try string(i) else "", .name = try string(try field(f, "name")), .arguments = try json(a, try field(f, "args")) });
                }
            } else {
                const kind = try string(try field(part, "type"));
                if (std.mem.eql(u8, kind, "text")) try d.content.appendSlice(a, try string(try field(part, "text")));
                if (std.mem.eql(u8, kind, "thinking")) try d.reasoning.appendSlice(a, try string(try field(part, "thinking")));
                if (std.mem.eql(u8, kind, "tool_use")) try d.calls.append(a, .{ .id = try string(try field(part, "id")), .name = try string(try field(part, "name")), .arguments = try json(a, try field(part, "input")) });
            }
        }
        if (isAnthropic(protocol)) {
            const finish = try string(try field(response, "stop_reason"));
            if (std.mem.eql(u8, finish, "tool_use") != (d.calls.items.len > 0)) return error.InvalidResponse;
        }
    }
    if (d.calls.items.len > 16) return error.ToolCallLimitExceeded;
    return d;
}

fn cancelled(args: anytype) bool {
    if (@hasField(@TypeOf(args), "is_cancelled_fn")) {
        if (args.is_cancelled_fn) |f| return f(args.cancelled_ctx);
    }
    return false;
}

fn run(allocator: A, args: anytype) !CallOutcome {
    // #874: no emitir una petición de tools que el modelo ya se sabe que
    // rechaza (Cohere reasoning => 422). Falla ANTES de cualquier HTTP para no
    // gastar la sesión de reparación; el llamador puede rotar de candidato.
    // el segundo auditor-P1: la medición VIVA positiva del catálogo MANDA sobre la lista por
    // nombre — el llamador lo declara explícitamente en `tools_measured_live` y
    // entonces NO se aborta, aunque el nombre coincida con la lista conservadora.
    if (@hasField(@TypeOf(args), "provider")) {
        const measured_live_yes = @hasField(@TypeOf(args), "tools_measured_live") and args.tools_measured_live;
        if (!measured_live_yes and !supportsToolCalling(args.provider, args.model)) return error.ToolsUnsupportedByModel;
    }
    if (cancelled(args)) return .cancelled;
    if (args.max_rounds == 0 or args.max_rounds > 32 or args.tools.len == 0) return error.InvalidToolConfiguration;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var body = try request(a, args);
    const gemini = isGemini(args.protocol);
    const anthropic = isAnthropic(args.protocol);
    const messages = body.object.getPtr(if (gemini) "contents" else "messages").?;
    var executed_ids: std.StringHashMapUnmanaged(void) = .{};
    // B1 (10-nov): herramientas diferidas (patrón ToolSearch). Sus esquemas no
    // viajan hasta que el modelo llama a la cargadora: desde la ronda siguiente
    // se declaran todas. Ejecutarlas sigue pasando por `tool_executor_fn` (la
    // ejecución gobernada no cambia); la cargadora no tiene efectos y la
    // responde el propio bucle. Una diferida llamada sin cargar no se ejecuta:
    // se carga y se pide repetirla (el modelo aún no ha visto su esquema).
    const deferred = deferredArgs(args);
    var deferred_loaded = false;
    var deferred_expanded = false;
    for (0..args.max_rounds) |round| {
        if (cancelled(args)) return .cancelled;
        // D-C1 (E5.11): puerta de presupuesto POR INTENTO. Una sesión de tools
        // consume una llamada al proveedor por ronda; sin este hook el gasto
        // solo se anotaba una vez a la entrada de la sesión.
        if (@hasField(@TypeOf(args), "round_gate_fn")) {
            if (args.round_gate_fn) |gate| try gate(args.round_gate_ctx);
        }
        try args.set_request_fn(args.attempt_ctx, try json(a, body));
        if (cancelled(args)) return .cancelled;
        const raw = try args.attempt_fn(args.attempt_ctx);
        if (@hasField(@TypeOf(args), "on_response_fn")) args.on_response_fn(args.on_response_ctx, raw);
        if (cancelled(args)) return .cancelled;
        // Own all parsed strings before the next HTTP attempt replaces its buffer.
        const decoded = try decode(a, args.protocol, try parse(a, raw));
        if (decoded.calls.items.len == 0) {
            // Reasoning alone is not a final answer or a completed correction.
            if (std.mem.trim(u8, decoded.content.items, " \t\r\n").len == 0) return error.EmptyResponse;
            const content = try allocator.dupe(u8, decoded.content.items);
            errdefer allocator.free(content);
            return .{ .completed = .{ .content = content, .reasoning = try allocator.dupe(u8, decoded.reasoning.items) } };
        }
        // Do not execute an operation if there is no round left to review its result.
        if (round + 1 == args.max_rounds) return error.ToolRoundsExhausted;
        // Validate the entire batch before any side effect.
        for (decoded.calls.items, 0..) |c, i| {
            const declared = inList(args.tools, c.name) or inList(deferred.tools, c.name);
            if (!declared) return error.UnsupportedTool;
            if ((!gemini and c.id.len == 0) or c.name.len == 0) return error.InvalidResponse;
            if (c.id.len > 0 and executed_ids.contains(c.id)) return error.DuplicateToolCall;
            if ((try parse(a, c.arguments)) != .object) return error.InvalidToolArguments;
            if (c.id.len > 0) for (decoded.calls.items[0..i]) |previous| {
                if (std.mem.eql(u8, c.id, previous.id)) return error.DuplicateToolCall;
            };
        }
        try add(messages, decoded.assistant); // preserves Gemini thought signatures and Anthropic thinking blocks
        var results = array(a);
        for (decoded.calls.items) |c| {
            if (cancelled(args)) return .cancelled;
            if (c.id.len > 0) try executed_ids.put(a, c.id, {});
            const is_loader = deferred.tools.len > 0 and std.mem.eql(u8, c.name, deferred.loader);
            // Una diferida llamada antes de que sus esquemas hayan viajado.
            const premature = !is_loader and !deferred_expanded and inList(deferred.tools, c.name);
            const was_loaded = deferred_loaded;
            if (is_loader or premature) deferred_loaded = true;
            // Executor output is borrowed until its next invocation: copy it now.
            const result = if (is_loader or premature)
                try loaderResult(a, deferred.tools, deferred.note, was_loaded, premature)
            else
                try a.dupe(u8, try args.tool_executor_fn(args.tool_executor_ctx, c.name, c.arguments));
            var output = object(a);
            if (gemini) {
                var response = object(a);
                try put(a, &response, "result", str(result));
                try put(a, &output, "name", str(c.name));
                if (c.id.len > 0) try put(a, &output, "id", str(c.id));
                try put(a, &output, "response", response);
                var part = object(a);
                try put(a, &part, "functionResponse", output);
                try add(&results, part);
            } else if (anthropic) {
                try put(a, &output, "type", str("tool_result"));
                try put(a, &output, "tool_use_id", str(c.id));
                try put(a, &output, "content", str(result));
                try add(&results, output);
            } else {
                output = try message(a, "tool", str(result), false);
                try put(a, &output, "tool_call_id", str(c.id));
                try add(messages, output);
            }
        }
        if (gemini or anthropic) try add(messages, try message(a, "user", results, gemini));
        // Se amplía una sola vez; la cargadora sigue declarada (su llamada
        // está en el historial) y, si se repite, responde «ya cargadas».
        if (deferred_loaded and !deferred_expanded) {
            try body.object.put(a, "tools", try toolDefinitions(a, args.protocol, args.tools, deferred.tools));
            deferred_expanded = true;
        }
    }
    return error.ToolRoundsExhausted;
}

/// A bounded native tool loop. Never retries a side-effecting tool after failure.
/// Transport owns response buffers; completed/exhausted payloads belong to caller.
pub fn callWithTools(allocator: A, args: anytype) !CallOutcome {
    return run(allocator, args) catch |err| {
        if (err == error.OutOfMemory) return err;
        if (err == error.Cancelled) return .cancelled;
        return .{ .exhausted = try allocator.dupe(u8, @errorName(err)) };
    };
}

test "E5.24 tool requests preserve image parts in every protocol" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const images = [_]providers.connector.ImagePart{.{ .mime_type = "image/png", .base64 = "YWJj" }};
    for ([_]Protocol{ .openai_compatible, .gemini, .anthropic }) |protocol| {
        const body = try request(a, .{ .protocol = protocol, .model = "fixture", .system_prompt = "rules", .user_prompt = "look", .tools = &[_]providers.connector_v2.ToolDefinition{}, .images = &images });
        const bytes = try json(a, body);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "YWJj") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, "image/png") != null);
        try std.testing.expect(std.mem.indexOf(u8, bytes, switch (protocol) {
            .gemini => "inlineData",
            .anthropic => "source",
            else => "image_url",
        }) != null);
    }
}
