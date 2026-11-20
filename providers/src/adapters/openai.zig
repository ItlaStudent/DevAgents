const std = @import("std");
const connector = @import("../connector.zig");
const http_client = @import("../http/client.zig");

/// Adaptador OpenAI-compatible para proveedores que usan la API de OpenAI.
pub const OpenAIAdapter = struct {
    allocator: std.mem.Allocator,
    http: *http_client.HttpClient,
    base_url: []const u8,
    api_key: []const u8,
    extra_headers: []const std.http.Header,
    /// La Compatibility API de Cohere rechaza `stream_options` con un 400
    /// (limitación documentada — el SDK de Strands chocó con la misma). Para
    /// ese estilo el campo se omite; el precio es no recibir usage en el
    /// último chunk, idéntico al opt-out que documenta Cohere para Python.
    omit_stream_options: bool,

    pub fn init(allocator: std.mem.Allocator, http: *http_client.HttpClient, base_url: []const u8, api_key: []const u8, extra_headers: []const std.http.Header, omit_stream_options: bool) !*OpenAIAdapter {
        const self = try allocator.create(OpenAIAdapter);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .http = http,
            .base_url = try allocator.dupe(u8, base_url),
            .api_key = try allocator.dupe(u8, api_key),
            .extra_headers = try allocator.dupe(std.http.Header, extra_headers),
            .omit_stream_options = omit_stream_options,
        };
        return self;
    }

    pub fn deinit(self: *OpenAIAdapter) void {
        self.allocator.free(self.base_url);
        self.allocator.free(self.api_key);
        self.allocator.free(self.extra_headers);
        self.allocator.destroy(self);
    }

    pub fn connectorInterface(self: *OpenAIAdapter) connector.Connector {
        return .{
            .ptr = self,
            .vtable = &.{
                .chat = chatImpl,
                .listModels = listModelsImpl,
                .destroy = destroyImpl,
            },
        };
    }

    fn destroyImpl(ctx: *anyopaque) void {
        const self: *OpenAIAdapter = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn chatImpl(ctx: *anyopaque, allocator: std.mem.Allocator, options: connector.ChatOptions) connector.ConnectorError!connector.ChatStream {
        const self: *OpenAIAdapter = @ptrCast(@alignCast(ctx));
        const url = try std.fmt.allocPrint(allocator, "{s}/chat/completions", .{self.base_url});
        defer allocator.free(url);
        const body = try buildChatBody(allocator, options, self.omit_stream_options);
        defer allocator.free(body);
        // MODELO-LOCAL: los proveedores sin clave (Ollama) llegan con "" — si la
        // pasáramos tal cual saldría `Authorization: Bearer ` vacío, que es un
        // header inválido. null = el cliente no emite Authorization en absoluto.
        const api_key_opt: ?[]const u8 = if (self.api_key.len == 0) null else self.api_key;
        const req = self.http.postSse(url, body, api_key_opt) catch |e| {
            return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.RequestFailed,
            };
        };
        // FIX-SEGFAULT-P0: heap-allocate the Response so it survives after this
        // function returns. Previously, `response` was a stack-local and
        // ChatStream stored a pointer to it → use-after-free → segfault when
        // nextChunk dereferenced the dangling reader pointer.
        const response = self.http.allocator.create(std.http.Client.Response) catch {
            req.deinit();
            self.http.allocator.destroy(req);
            return error.OutOfMemory;
        };
        // En TODA ruta de error posterior hay que cerrar y liberar el req Y el
        // response (lo creó postSse en el heap del HttpClient): si se fuga, la
        // conexión queda viva y el deinit del cliente HTTP hace panic.
        // FIX-SEGFAULT-P0: req.deinit() MUST run before response is destroyed,
        // since req may reference response's connection state.
        errdefer {
            req.deinit();
            self.http.allocator.destroy(req);
            self.http.allocator.destroy(response);
        }
        var redirect_buffer: [8192]u8 = undefined;
        response.* = req.receiveHead(&redirect_buffer) catch |e| {
            return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                error.RedirectBlocked => error.RedirectBlocked,
                else => error.ResponseFailed,
            };
        };
        if (response.head.status.class() != .success) self.http.captureFailure(response, self.api_key);
        if (response.head.status == .unauthorized or response.head.status == .forbidden) return error.AuthFailed;
        if (response.head.status == .payment_required) return error.QuotaExceeded;
        if (response.head.status == .too_many_requests) return error.RateLimited;
        if (response.head.status == .not_found) return error.ModelNotFound;
        if (response.head.status.class() == .server_error) return error.ProviderError;
        if (response.head.status.class() != .success) return error.RequestFailed;
        return try connector.ChatStream.init(allocator, req, response);
    }

    fn listModelsImpl(ctx: *anyopaque, allocator: std.mem.Allocator) connector.ConnectorError![]const u8 {
        const self: *OpenAIAdapter = @ptrCast(@alignCast(ctx));
        const url = try std.fmt.allocPrint(allocator, "{s}/models", .{self.base_url});
        defer allocator.free(url);
        // MODELO-LOCAL: igual que en chatImpl — clave vacía → sin Authorization.
        const api_key_opt: ?[]const u8 = if (self.api_key.len == 0) null else self.api_key;
        const result = self.http.getAuth(url, api_key_opt) catch |err| switch (err) {
            error.RequestFailed => return error.RequestFailed,
            error.ResponseFailed => return error.ResponseFailed,
            error.RedirectBlocked => return error.RedirectBlocked,
            else => |e| {
                std.log.debug("listModels error: {any}", .{e});
                return error.ProviderError;
            },
        };
        return result;
    }

    /// Construye el body con std.json.Stringify: escape correcto de model/role/content
    /// (la interpolación anterior rompía el JSON con comillas en el prompt — CODING-STANDARDS §8).
    /// WriteFailed del writer Allocating solo ocurre por agotamiento de memoria.
    fn buildChatBody(allocator: std.mem.Allocator, options: connector.ChatOptions, omit_stream_options: bool) error{OutOfMemory}![]const u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        writeChatJson(&out.writer, options, omit_stream_options) catch return error.OutOfMemory;
        return allocator.dupe(u8, out.written());
    }

    fn writeChatJson(writer: *std.Io.Writer, options: connector.ChatOptions, omit_stream_options: bool) !void {
        var js: std.json.Stringify = .{ .writer = writer, .options = .{} };
        try js.beginObject();
        try js.objectField("model");
        try js.write(options.model);
        try js.objectField("messages");
        try js.beginArray();
        for (options.messages) |msg| {
            try js.beginObject();
            try js.objectField("role");
            try js.write(msg.role);
            try js.objectField("content");
            if (msg.images.len > 0) {
                try js.beginArray();
                try js.write(.{ .type = "text", .text = msg.content });
                for (msg.images) |image| try @import("openai_v2.zig").writeImagePart(&js, image);
                try js.endArray();
            } else try js.write(msg.content);
            try js.endObject();
        }
        try js.endArray();
        try js.objectField("stream");
        try js.write(options.stream);
        // P08: pedir usage en streaming (OpenAI stream_options.include_usage).
        // Proveedores OpenAI-compatible que lo soportan devolverán usage en el
        // último chunk; los que no lo reconocen lo ignoran sin error. EXCEPCIÓN
        // medida en vivo: la Compatibility API de Cohere rechaza el campo con un
        // 400 (órdenes #589-#592: todo worker programar caía en RequestFailed
        // mientras el sondeo V2 —que no lo envía— respondía ok). Para ese
        // estilo llega omit_stream_options=true y el campo no sale al wire.
        if (options.stream and !omit_stream_options) {
            try js.objectField("stream_options");
            try js.beginObject();
            try js.objectField("include_usage");
            try js.write(true);
            try js.endObject();
        }
        if (options.temperature) |t| {
            try js.objectField("temperature");
            try js.write(t);
        }
        if (options.max_tokens) |m| {
            // La familia de razonamiento (o1/o3/o4) y gpt-5+ RECHAZAN
            // `max_tokens` y exigen `max_completion_tokens`; el resto de
            // OpenAI-compatible sigue con `max_tokens`.
            try js.objectField(if (requiresMaxCompletionTokens(options.model)) "max_completion_tokens" else "max_tokens");
            try js.write(m);
        }
        if (options.reasoning_effort) |e| {
            try js.objectField("reasoning_effort");
            try js.write(e);
        }
        // LOCAL-JSON (E5.03): salida estructurada pedida por esquema. La API
        // compatible con OpenAI de Ollama acepta response_format{json_schema}
        // (documentado en docs.ollama.com/capabilities/structured-outputs). El
        // esquema llega serializado: se emite en crudo, sin reescapar.
        if (options.response_format) |rf| {
            try js.objectField("response_format");
            try js.beginObject();
            try js.objectField("type");
            try js.write("json_schema");
            try js.objectField("json_schema");
            try js.beginObject();
            try js.objectField("name");
            try js.write(rf.name);
            try js.objectField("schema");
            // El esquema ya viene serializado: beginWriteRaw/endWriteRaw lo
            // emiten sin reescapar SIN romper la máquina de estados (un
            // writeAll a pelo deja next_punctuation=.colon y el siguiente
            // endObject cae en unreachable — probado con fixture).
            try js.beginWriteRaw();
            try writer.writeAll(rf.schema);
            js.endWriteRaw();
            try js.endObject();
            try js.endObject();
        }
        try js.endObject();
    }
};

/// Las familias de razonamiento de OpenAI (o1/o3/o4) y gpt-5 en adelante
/// sustituyeron `max_tokens` por `max_completion_tokens`. Enviar el nombre
/// viejo a esos modelos devuelve 400.
pub fn requiresMaxCompletionTokens(model: []const u8) bool {
    const prefixes = [_][]const u8{ "o1", "o3", "o4", "gpt-5" };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, model, prefix)) return true;
    }
    return false;
}

test "CK-PRV-007 Q3: los modelos o/gpt-5+ reciben max_completion_tokens, no max_tokens" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "o1", "o3-mini", "o4-mini", "gpt-5", "gpt-5.1-codex" }) |model| {
        const body = try OpenAIAdapter.buildChatBody(a, .{
            .model = model,
            .messages = &.{.{ .role = "user", .content = "hola" }},
            .stream = false,
            .max_tokens = 1024,
        }, false);
        defer a.free(body);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, 1024), parsed.value.object.get("max_completion_tokens").?.integer);
        try std.testing.expect(parsed.value.object.get("max_tokens") == null);
    }
    // Control negativo: un compatible cualquiera conserva max_tokens.
    for ([_][]const u8{ "gpt-4o", "llama3.1:8b", "command-a-plus-05-2026" }) |model| {
        const body = try OpenAIAdapter.buildChatBody(a, .{
            .model = model,
            .messages = &.{.{ .role = "user", .content = "hola" }},
            .stream = false,
            .max_tokens = 1024,
        }, false);
        defer a.free(body);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, 1024), parsed.value.object.get("max_tokens").?.integer);
        try std.testing.expect(parsed.value.object.get("max_completion_tokens") == null);
    }
}

test "LOCAL-JSON (E5.03): el body lleva response_format con el esquema pedido" {
    const allocator = std.testing.allocator;
    const msgs = [_]connector.ChatMessage{.{ .role = "user", .content = "hola" }};
    const body = try OpenAIAdapter.buildChatBody(allocator, .{
        .model = "llama3.1:8b",
        .messages = &msgs,
        .stream = false,
        .response_format = .{ .name = "devagents_plan", .schema = "{\"type\":\"object\",\"required\":[\"understanding\"]}" },
    }, false);
    defer allocator.free(body);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const rf = parsed.value.object.get("response_format") orelse return error.TestUnexpectedResult;
    try std.testing.expect(rf == .object);
    try std.testing.expectEqualStrings("json_schema", rf.object.get("type").?.string);
    const js = rf.object.get("json_schema") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("devagents_plan", js.object.get("name").?.string);
    // El esquema se emitió EN CRUDO: vuelve a parsear como objeto JSON.
    const schema = js.object.get("schema") orelse return error.TestUnexpectedResult;
    try std.testing.expect(schema == .object);
    try std.testing.expectEqualStrings("object", schema.object.get("type").?.string);
}

test "LOCAL-JSON (E5.03): sin esquema no se emite response_format (control negativo)" {
    const allocator = std.testing.allocator;
    const msgs = [_]connector.ChatMessage{.{ .role = "user", .content = "hola" }};
    const body = try OpenAIAdapter.buildChatBody(allocator, .{
        .model = "llama3.1:8b",
        .messages = &msgs,
        .stream = false,
    }, false);
    defer allocator.free(body);
    // Control: quitar el esquema deja el body como antes de E5.03 — si la
    // emisión se aplicara siempre, esta prueba se pondría en rojo.
    try std.testing.expect(std.mem.indexOf(u8, body, "response_format") == null);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("response_format") == null);
}

test "E5.24 openai streaming adapter serializes every attached image" {
    const a = std.testing.allocator;
    const images = [_]connector.ImagePart{ .{ .mime_type = "image/png", .base64 = "YWJj" }, .{ .mime_type = "image/webp", .base64 = "ZGVm" } };
    const messages = [_]connector.ChatMessage{ .{ .role = "system", .content = "rules" }, .{ .role = "user", .content = "look", .images = &images } };
    const options = connector.ChatOptions{ .model = "fixture", .messages = &messages };
    const body = try OpenAIAdapter.buildChatBody(a, options, false);
    defer a.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.contains("messages"));
    try std.testing.expect(std.mem.indexOf(u8, body, "YWJj") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ZGVm") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "image/png") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "image/webp") != null);
}

test "ORDENES Cohere compatibility omits unsupported options and bounds output" {
    const a = std.testing.allocator;
    const body = try OpenAIAdapter.buildChatBody(a, .{ .model = "command-a-plus-05-2026", .messages = &.{.{ .role = "user", .content = "Hola" }}, .stream = true, .max_tokens = 4096 }, true);
    defer a.free(body);
    var p = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer p.deinit();
    try std.testing.expect(!p.value.object.contains("stream_options"));
    try std.testing.expect(!p.value.object.contains("response_format"));
    try std.testing.expectEqual(@as(i64, 4096), p.value.object.get("max_tokens").?.integer);
}
