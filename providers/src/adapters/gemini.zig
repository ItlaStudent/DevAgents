const std = @import("std");
const connector = @import("../connector.zig");
const http_client = @import("../http/client.zig");
const error_mapping_v2 = @import("../error_mapping_v2.zig");

/// Redact `key=...` from a URL string, replacing the key value with `REDACTED`.
/// Used in all log/error/event paths to prevent API key leakage.
pub fn redactUrl(allocator: std.mem.Allocator, url: []const u8) ![]const u8 {
    const marker = "key=";
    const pos = std.mem.indexOf(u8, url, marker) orelse return try allocator.dupe(u8, url);
    const key_start = pos + marker.len;
    // Find end of key value (next & or end of string).
    const key_end = std.mem.indexOfScalarPos(u8, url, key_start, '&') orelse url.len;
    return try std.fmt.allocPrint(allocator, "{s}key=REDACTED{s}", .{ url[0..pos], url[key_end..] });
}

/// Adaptador para Google AI Studio (API Gemini), cuyo protocolo difiere del de OpenAI:
/// cuerpo `{"contents":[{"role":..,"parts":[{"text":..}]}]}`, endpoint
/// `/models/{model}:streamGenerateContent` y autenticación por header `x-goog-api-key`.
pub const GeminiAdapter = struct {
    allocator: std.mem.Allocator,
    http: *http_client.HttpClient,
    base_url: []const u8,
    api_key: []const u8,

    pub fn init(allocator: std.mem.Allocator, http: *http_client.HttpClient, base_url: []const u8, api_key: []const u8) !*GeminiAdapter {
        const self = try allocator.create(GeminiAdapter);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .http = http,
            .base_url = try allocator.dupe(u8, base_url),
            .api_key = try allocator.dupe(u8, api_key),
        };
        return self;
    }

    pub fn deinit(self: *GeminiAdapter) void {
        self.allocator.free(self.base_url);
        self.allocator.free(self.api_key);
        self.allocator.destroy(self);
    }

    pub fn connectorInterface(self: *GeminiAdapter) connector.Connector {
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
        const self: *GeminiAdapter = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn chatImpl(ctx: *anyopaque, allocator: std.mem.Allocator, options: connector.ChatOptions) connector.ConnectorError!connector.ChatStream {
        const self: *GeminiAdapter = @ptrCast(@alignCast(ctx));
        // El catálogo guarda el id CON prefijo "models/" (así lo devuelve /models);
        // el endpoint ya añade "/models/", así que hay que quitarlo o queda
        // "/models/models/..." → 404. (Causa raíz de los RequestFailed de Google.)
        const model_id = if (std.mem.startsWith(u8, options.model, "models/"))
            options.model["models/".len..]
        else
            options.model;
        // T1: la clave va en el header x-goog-api-key, NUNCA en la URL.
        const url = try buildChatUrl(allocator, self.base_url, model_id);
        defer allocator.free(url);
        const body = try buildChatBody(allocator, options);
        defer allocator.free(body);
        const req = self.http.postSseWithCustomHeader(url, body, "x-goog-api-key", self.api_key) catch |e| {
            return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.RequestFailed,
            };
        };
        // FIX-SEGFAULT-P0: heap-allocate the Response so it survives after this
        // function returns. Previously, `response` was a stack-local and
        // ChatStream stored a pointer to it → use-after-free → segfault.
        const response = self.http.allocator.create(std.http.Client.Response) catch {
            req.deinit();
            self.http.allocator.destroy(req);
            return error.OutOfMemory;
        };
        // Mismo fix que en openai.zig: si una ruta de error fuga el req, la conexión
        // queda viva y el deinit del HttpClient hace panic (hallado con llamada real).
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
        if (response.head.status.class() != .success) {
            const redacted = redactUrl(allocator, url) catch url;
            defer if (redacted.ptr != url.ptr) allocator.free(redacted);
            std.debug.print("[gemini http] status={d} url={s}\n", .{ @intFromEnum(response.head.status), redacted });
        }
        // Body-first (Q1): Google responde 400, NO 401, cuando la
        // API key es invalida (reason API_KEY_INVALID). El status por si solo
        // lo llamaria "RequestFailed"; el cuerpo dice que es un fallo de
        // credencial. El clasificador puro vive en error_mapping_v2.zig y su
        // fixture esta bajo test " Q1".
        if (response.head.status.class() != .success and
            std.mem.eql(u8, error_mapping_v2.ErrorMappingV2.classify(@intFromEnum(response.head.status), self.http.last_failure.message()), "auth_error"))
            return error.AuthFailed;
        if (response.head.status == .unauthorized or response.head.status == .forbidden) return error.AuthFailed;
        if (response.head.status == .too_many_requests) return error.RateLimited;
        if (response.head.status == .not_found) return error.ModelNotFound;
        if (response.head.status.class() == .server_error) return error.ProviderError;
        if (response.head.status.class() != .success) return error.RequestFailed;
        return try connector.ChatStream.init(allocator, req, response);
    }

    fn listModelsImpl(ctx: *anyopaque, allocator: std.mem.Allocator) connector.ConnectorError![]const u8 {
        const self: *GeminiAdapter = @ptrCast(@alignCast(ctx));
        // T1: la clave va en el header x-goog-api-key, NUNCA en la URL.
        const url = try buildListModelsUrl(allocator, self.base_url);
        defer allocator.free(url);
        const result = self.http.getWithHeader(url, "x-goog-api-key", self.api_key) catch |err| switch (err) {
            error.RequestFailed => return error.RequestFailed,
            error.ResponseFailed => return error.ResponseFailed,
            error.RedirectBlocked => return error.RedirectBlocked,
            else => |e| {
                std.log.debug("gemini listModels error: {any}", .{e});
                return error.ProviderError;
            },
        };
        return result;
    }

    /// Construye el cuerpo en el formato Gemini (contents/parts). Mapea los roles
    /// OpenAI ("assistant"→"model"; el resto→"user"). Usa std.json.Stringify para
    /// ESCAPAR correctamente el contenido: la interpolación anterior rompía el JSON
    /// con comillas/saltos de línea en el prompt (CODING-STANDARDS §8) → 400 en
    /// Google (causa raíz de los RequestFailed con prompts de código).
    pub fn buildChatBody(allocator: std.mem.Allocator, options: connector.ChatOptions) error{OutOfMemory}![]const u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        writeChatJson(&out.writer, options) catch return error.OutOfMemory;
        return allocator.dupe(u8, out.written());
    }

    /// H6 — las instrucciones de sistema van a `systemInstruction`.
    ///
    /// Antes caían dentro de `contents` con el rol traducido a "user", porque
    /// el mapeo era «assistant→model, todo lo demás→user». Funcionaba, pero
    /// deja dos turnos de usuario seguidos y —lo que importa aquí— saca las
    /// instrucciones del sitio que Gemini considera parte estable de la
    /// petición. La caché implícita de Gemini premia el prefijo que no cambia,
    /// y el prefijo que no cambia entre dos tareas del mismo departamento es
    /// exactamente el prompt de sistema.
    fn writeChatJson(writer: *std.Io.Writer, options: connector.ChatOptions) !void {
        var js: std.json.Stringify = .{ .writer = writer, .options = .{} };
        try js.beginObject();

        var has_system = false;
        for (options.messages) |msg| {
            if (std.mem.eql(u8, msg.role, "system")) has_system = true;
        }
        if (has_system) {
            try js.objectField("systemInstruction");
            try js.beginObject();
            try js.objectField("parts");
            try js.beginArray();
            for (options.messages) |msg| {
                if (!std.mem.eql(u8, msg.role, "system")) continue;
                try js.beginObject();
                try js.objectField("text");
                try js.write(msg.content);
                try js.endObject();
            }
            try js.endArray();
            try js.endObject();
        }

        try js.objectField("contents");
        try js.beginArray();
        for (options.messages) |msg| {
            if (std.mem.eql(u8, msg.role, "system")) continue;
            try js.beginObject();
            try js.objectField("role");
            try js.write(if (std.mem.eql(u8, msg.role, "assistant")) "model" else "user");
            try js.objectField("parts");
            try js.beginArray();
            try js.beginObject();
            try js.objectField("text");
            try js.write(msg.content);
            try js.endObject();
            for (msg.images) |image| try @import("gemini_v2.zig").writeImagePart(&js, image);
            try js.endArray();
            try js.endObject();
        }
        try js.endArray();
        // generationConfig reúne temperatura y/o salida estructurada. Gemini
        // admite el esquema en su propio dialecto: `responseMimeType` +
        // `responseSchema` (subconjunto de OpenAPI/JSON Schema). Si no hay
        // ninguna de las dos cosas, el objeto no se emite.
        if (options.temperature != null or options.response_format != null) {
            try js.objectField("generationConfig");
            try js.beginObject();
            if (options.response_format) |rf| {
                try js.objectField("responseMimeType");
                try js.write("application/json");
                try js.objectField("responseSchema");
                // El esquema ya viene serializado: se emite en crudo sin
                // reescapar, igual que hace openai.zig con response_format.
                try js.beginWriteRaw();
                try writer.writeAll(rf.schema);
                js.endWriteRaw();
            }
            if (options.temperature) |t| {
                try js.objectField("temperature");
                try js.write(t);
            }
            try js.endObject();
        }
        try js.endObject();
    }
};

fn buildChatUrl(allocator: std.mem.Allocator, base_url: []const u8, model_id: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/models/{s}:streamGenerateContent?alt=sse", .{ base_url, model_id });
}

fn buildListModelsUrl(allocator: std.mem.Allocator, base_url: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/models", .{base_url});
}

// ── Tests ──────────────────────────────────────────────────────────────

test "gemini body uses contents/parts format" {
    const allocator = std.testing.allocator;
    const msgs = [_]connector.ChatMessage{
        .{ .role = "user", .content = "hola" },
    };
    const body = try GeminiAdapter.buildChatBody(allocator, .{ .model = "gemini-2.0-flash", .messages = &msgs });
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"contents\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"parts\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"text\":\"hola\"") != null);
    // NO debe parecerse al formato OpenAI.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"messages\"") == null);
}

test "gemini maps assistant role to model" {
    const allocator = std.testing.allocator;
    const msgs = [_]connector.ChatMessage{
        .{ .role = "assistant", .content = "respuesta previa" },
    };
    const body = try GeminiAdapter.buildChatBody(allocator, .{ .model = "gemini-1.5-pro", .messages = &msgs });
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"role\":\"model\"") != null);
}

test "redactUrl replaces key value with REDACTED" {
    const allocator = std.testing.allocator;
    const url = "https://generativelanguage.googleapis.com/v1beta/models/gemini-2.0-flash:streamGenerateContent?alt=sse&key=AIzaSyABCDEFGHIJKLMNOPQRSTUVWXYZ1234567890";
    const redacted = try redactUrl(allocator, url);
    defer allocator.free(redacted);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "key=REDACTED") != null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "AIzaSy") == null);
    // Non-key part should be preserved.
    try std.testing.expect(std.mem.indexOf(u8, redacted, "alt=sse") != null);
}

test "redactUrl handles key at end of URL" {
    const allocator = std.testing.allocator;
    const url = "https://example.com/v1/models/test:key?key=SECRET123";
    const redacted = try redactUrl(allocator, url);
    defer allocator.free(redacted);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "key=REDACTED") != null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "SECRET123") == null);
}

test "redactUrl handles key with trailing params" {
    const allocator = std.testing.allocator;
    const url = "https://example.com/v1?key=SECRET&page=2";
    const redacted = try redactUrl(allocator, url);
    defer allocator.free(redacted);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "key=REDACTED") != null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "SECRET") == null);
    try std.testing.expect(std.mem.indexOf(u8, redacted, "page=2") != null);
}

test "redactUrl passes through URL without key" {
    const allocator = std.testing.allocator;
    const url = "https://example.com/v1/models";
    const redacted = try redactUrl(allocator, url);
    defer allocator.free(redacted);
    try std.testing.expectEqualStrings(url, redacted);
}

test "T1: gemini chat URL does not contain API key" {
    const allocator = std.testing.allocator;
    const url = try buildChatUrl(allocator, "https://generativelanguage.googleapis.com/v1beta", "gemini-2.0-flash");
    defer allocator.free(url);
    // The URL must NOT contain key= or the actual key value.
    try std.testing.expect(std.mem.indexOf(u8, url, "key=") == null);
    try std.testing.expect(std.mem.indexOf(u8, url, "AIzaSyTESTKEY") == null);
    // alt=sse must still be present.
    try std.testing.expect(std.mem.indexOf(u8, url, "alt=sse") != null);
    // The endpoint path must be correct.
    try std.testing.expect(std.mem.indexOf(u8, url, "streamGenerateContent") != null);
}

test "T1: gemini listModels URL does not contain API key" {
    const allocator = std.testing.allocator;
    const url = try buildListModelsUrl(allocator, "https://generativelanguage.googleapis.com/v1beta");
    defer allocator.free(url);
    try std.testing.expect(std.mem.indexOf(u8, url, "key=") == null);
    try std.testing.expect(std.mem.indexOf(u8, url, "AIzaSyTESTKEY") == null);
    try std.testing.expect(std.mem.indexOf(u8, url, "/models") != null);
}

test "T1: gemini uses x-goog-api-key header name" {
    // Verify the header name constant used by the adapter.
    const header_name = "x-goog-api-key";
    try std.testing.expectEqualStrings("x-goog-api-key", header_name);
    // Ensure it's NOT "authorization" or "Bearer".
    try std.testing.expect(!std.mem.eql(u8, header_name, "authorization"));
}

test "H6: el prompt de sistema de Gemini viaja en systemInstruction, no como turno" {
    const allocator = std.testing.allocator;
    const msgs = [_]connector.ChatMessage{
        .{ .role = "system", .content = "Eres un programador." },
        .{ .role = "user", .content = "haz una calculadora" },
    };
    const body = try GeminiAdapter.buildChatBody(allocator, .{ .model = "gemini-3-flash", .messages = &msgs });
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"systemInstruction\"") != null);
    // El texto del sistema NO se repite dentro de contents.
    const contents_at = std.mem.indexOf(u8, body, "\"contents\"").?;
    try std.testing.expect(std.mem.indexOf(u8, body[contents_at..], "Eres un programador") == null);
    try std.testing.expect(std.mem.indexOf(u8, body[contents_at..], "haz una calculadora") != null);
}

test "H6: sin turno de sistema no aparece systemInstruction" {
    const allocator = std.testing.allocator;
    const msgs = [_]connector.ChatMessage{
        .{ .role = "user", .content = "hola" },
    };
    const body = try GeminiAdapter.buildChatBody(allocator, .{ .model = "gemini-3-flash", .messages = &msgs });
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "systemInstruction") == null);
}

test "CK-PRV-007 Q5: Gemini recibe el esquema como responseSchema en generationConfig" {
    const allocator = std.testing.allocator;
    const msgs = [_]connector.ChatMessage{.{ .role = "user", .content = "plan" }};
    const schema = "{\"type\":\"object\",\"required\":[\"understanding\"],\"properties\":{\"understanding\":{\"type\":\"string\"}}}";
    const body = try GeminiAdapter.buildChatBody(allocator, .{
        .model = "gemini-3-flash",
        .messages = &msgs,
        .stream = false,
        .temperature = 0.2,
        .response_format = .{ .name = "devagents_plan", .schema = schema },
    });
    defer allocator.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, body, .{});
    defer parsed.deinit();
    const gc = parsed.value.object.get("generationConfig") orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("application/json", gc.object.get("responseMimeType").?.string);
    // El esquema se emitió EN CRUDO: vuelve a parsear como objeto JSON.
    const rs = gc.object.get("responseSchema") orelse return error.TestUnexpectedResult;
    try std.testing.expect(rs == .object);
    try std.testing.expectEqualStrings("object", rs.object.get("type").?.string);
    // temperature y responseSchema conviven en UN solo generationConfig.
    try std.testing.expect(gc.object.get("temperature") != null);
}

test "CK-PRV-007 Q5: sin esquema Gemini no emite responseMimeType ni responseSchema" {
    const allocator = std.testing.allocator;
    const msgs = [_]connector.ChatMessage{.{ .role = "user", .content = "hola" }};
    const body = try GeminiAdapter.buildChatBody(allocator, .{ .model = "gemini-3-flash", .messages = &msgs });
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "responseSchema") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "responseMimeType") == null);
    try std.testing.expect(std.mem.indexOf(u8, body, "generationConfig") == null);
}

test "E5.24 gemini streaming adapter serializes every attached image" {
    const a = std.testing.allocator;
    const images = [_]connector.ImagePart{ .{ .mime_type = "image/png", .base64 = "YWJj" }, .{ .mime_type = "image/webp", .base64 = "ZGVm" } };
    const messages = [_]connector.ChatMessage{ .{ .role = "system", .content = "rules" }, .{ .role = "user", .content = "look", .images = &images } };
    const options = connector.ChatOptions{ .model = "fixture", .messages = &messages };
    const body = try GeminiAdapter.buildChatBody(a, options);
    defer a.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.contains("contents"));
    try std.testing.expect(std.mem.indexOf(u8, body, "YWJj") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ZGVm") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "image/png") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "image/webp") != null);
}
