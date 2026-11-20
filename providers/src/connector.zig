const std = @import("std");
const http_client = @import("http/client.zig");
const sse = @import("http/sse.zig");

/// Errores de conector.
pub const ConnectorError = error{
    RequestFailed,
    ResponseFailed,
    RedirectBlocked,
    AuthFailed,
    RateLimited,
    QuotaExceeded,
    /// Modelo desconocido en el endpoint (404) → el catálogo local tiene un ID obsoleto.
    ModelNotFound,
    ProviderError,
    SseParseFailed,
    OutOfMemory,
};

/// Un mensaje en la conversación.
pub const ChatMessage = struct {
    role: []const u8,
    content: []const u8,
    images: []const ImagePart = &.{},
};

/// Validated attachment bytes encoded once by the engine; no remote URLs.
pub const ImagePart = struct {
    mime_type: []const u8,
    base64: []const u8,

    pub fn validate(self: ImagePart) !void {
        if (!(std.mem.eql(u8, self.mime_type, "image/png") or std.mem.eql(u8, self.mime_type, "image/jpeg") or
            std.mem.eql(u8, self.mime_type, "image/webp"))) return error.InvalidImagePart;
        if (self.base64.len == 0 or self.base64.len > ((5 * 1024 * 1024 + 2) / 3) * 4) return error.InvalidImagePart;
        const decoded_size = std.base64.standard.Decoder.calcSizeForSlice(self.base64) catch return error.InvalidImagePart;
        if (decoded_size > 5 * 1024 * 1024) return error.InvalidImagePart;
        for (self.base64) |ch| {
            if (!std.ascii.isAlphanumeric(ch) and ch != '+' and ch != '/' and ch != '=') return error.InvalidImagePart;
        }
    }
};

test "E5.24 image part rejects unsupported MIME oversized invalid and empty base64" {
    try (ImagePart{ .mime_type = "image/png", .base64 = "YWJj" }).validate();
    try std.testing.expectError(error.InvalidImagePart, (ImagePart{ .mime_type = "text/plain", .base64 = "YWJj" }).validate());
    try std.testing.expectError(error.InvalidImagePart, (ImagePart{ .mime_type = "image/png", .base64 = "" }).validate());
    try std.testing.expectError(error.InvalidImagePart, (ImagePart{ .mime_type = "image/png", .base64 = "\"abc" }).validate());
    try std.testing.expectError(error.InvalidImagePart, (ImagePart{ .mime_type = "image/png", .base64 = "abc" }).validate());
    const oversized = try std.testing.allocator.alloc(u8, ((5 * 1024 * 1024 + 2) / 3) * 4);
    defer std.testing.allocator.free(oversized);
    @memset(oversized, 'A');
    try std.testing.expectError(error.InvalidImagePart, (ImagePart{ .mime_type = "image/png", .base64 = oversized }).validate());
}

test "CK-PRV-007 Q6: una imagen por URL se rechaza con error claro (el conector es base64-only)" {
    // El contrato solo transporta bytes ya codificados por el motor: no hay
    // campo de URL remota. Una URL pasada como base64 no es base64 valido y se
    // rechaza antes de tocar la red, con un error tipado inequivoco.
    const urls = [_][]const u8{
        "https://example.com/pixel.png",
        "http://example.com/pixel.png",
        "//example.com/pixel.png",
        "data:image/png;base64,iVBORw0KGgo=",
    };
    for (urls) |url| {
        const result = (ImagePart{ .mime_type = "image/png", .base64 = url }).validate();
        try std.testing.expectError(error.InvalidImagePart, result);
    }
    // El mismo contenido en base64 real si pasa: no es un rechazo ciego.
    try (ImagePart{ .mime_type = "image/png", .base64 = "iVBORw0KGgo=" }).validate();
}

/// Salida estructurada pedida al proveedor. En la API compatible con OpenAI se
/// serializa como `response_format: {"type":"json_schema","json_schema":{...}}`
/// — el endpoint /v1 de Ollama lo lista como soportado (docs.ollama.com,
/// "Structured outputs work through the OpenAI-compatible API via
/// response_format"). El esquema fuerza JSON parseable; la conformidad fina
/// del contrato la sigue verificando el parser del motor.
pub const JsonSchemaSpec = struct {
    /// json_schema.name — identificador del contrato pedido.
    name: []const u8,
    /// Esquema JSON serializado, emitido tal cual bajo `json_schema.schema`.
    schema: []const u8,
};

/// Opciones para una petición de chat.
pub const ChatOptions = struct {
    model: []const u8,
    messages: []const ChatMessage,
    temperature: ?f32 = null,
    max_tokens: ?u32 = null,
    stream: bool = true,
    /// LOCAL-JSON (E5.03): esquema a pedir como response_format. El llamador lo
    /// fija según el contrato esperado y solo lo emite a proveedores locales;
    /// los adaptadores que no hablan ese dialecto lo ignoran.
    response_format: ?JsonSchemaSpec = null,
    /// Nivel de esfuerzo de razonamiento: "low" | "medium" | "high".
    ///
    /// Solo lo entienden los modelos de razonamiento. Los demás proveedores lo
    /// ignoran, así que enviarlo de más no rompe nada; por eso se manda tal
    /// cual en vez de mantener una lista de qué modelo lo soporta, que
    /// envejecería mal.
    reasoning_effort: ?[]const u8 = null,
    /// H6 — prompt caching. Marca que el prefijo del prompt (instrucciones de
    /// sistema, y el primer turno de usuario en las continuaciones) es ESTABLE
    /// y merece un punto de corte de caché.
    ///
    /// Solo tiene efecto donde el proveedor exige declararlo: Anthropic pide
    /// `cache_control` explícito. Los OpenAI-compatible cachean el prefijo
    /// solos y Gemini tiene caché implícita, así que ahí la bandera no cambia
    /// el cuerpo — lo que importa en esos es que el prefijo NO varíe, y de eso
    /// se encarga el orden de los mensajes.
    cache_prefix: bool = false,
};

/// Un chunk de respuesta de streaming.
pub const ChatChunk = struct {
    allocator: std.mem.Allocator,
    delta: []const u8,
    finish_reason: ?[]const u8,

    pub fn deinit(self: *ChatChunk) void {
        self.allocator.free(self.delta);
        if (self.finish_reason) |r| self.allocator.free(r);
    }
};

/// Interfaz genérica de conector LLM.
pub const Connector = struct {
    /// Puntero a la implementación concreta.
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        chat: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, options: ChatOptions) ConnectorError!ChatStream,
        listModels: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) ConnectorError![]const u8,
        destroy: *const fn (ctx: *anyopaque) void,
    };

    /// Inicia una conversación de chat streaming.
    pub fn chat(self: Connector, allocator: std.mem.Allocator, options: ChatOptions) ConnectorError!ChatStream {
        return self.vtable.chat(self.ptr, allocator, options);
    }

    /// Lista modelos disponibles (JSON string).
    pub fn listModels(self: Connector, allocator: std.mem.Allocator) ConnectorError![]const u8 {
        return self.vtable.listModels(self.ptr, allocator);
    }

    /// Libera la implementación concreta subyacente.
    pub fn deinit(self: Connector) void {
        self.vtable.destroy(self.ptr);
    }
};

/// Stream de respuesta de chat (SSE).
pub const ChatStream = struct {
    allocator: std.mem.Allocator,
    request: *http_client.Request,
    response: *std.http.Client.Response,
    reader: *std.Io.Reader,
    buffer: []u8,
    /// `[DONE]` es distinto de un EOF de transporte: el CLI lo usa para no
    /// aceptar texto parcial como una respuesta terminada.
    saw_done: bool = false,

    pub fn init(allocator: std.mem.Allocator, request: *http_client.Request, response: *std.http.Client.Response) !ChatStream {
        // El buffer debe existir ANTES de crear el reader: el Reader del nuevo std.Io
        // necesita un buffer propio para las lecturas por delimitador (líneas SSE).
        const buffer = try allocator.alloc(u8, sse.MAX_LINE_LEN + 1);
        errdefer allocator.free(buffer);
        const reader = response.reader(buffer);
        return .{
            .allocator = allocator,
            .request = request,
            .response = response,
            .reader = reader,
            .buffer = buffer,
            .saw_done = false,
        };
    }

    pub fn deinit(self: *ChatStream) void {
        // FIX-SEGFAULT-P0: request.deinit() may access connection state that
        // lives in the response. Deinit request first, then free everything.
        self.request.deinit();
        self.allocator.destroy(self.response);
        self.allocator.destroy(self.request);
        self.allocator.free(self.buffer);
    }

    /// Lee el siguiente chunk del stream SSE. Retorna null cuando el stream termina
    /// (EOF o evento `[DONE]`). OJO con el fork: `takeDelimiterExclusive` NO consume
    /// el '\n' → bucle infinito en la línea en blanco que separa eventos SSE (colgó
    /// la primera llamada real). `takeDelimiter` sí lo consume y devuelve null en EOF.
    pub fn nextChunk(self: *ChatStream) ConnectorError!?ChatChunk {
        while (true) {
            const maybe = self.reader.takeDelimiter('\n') catch |err| switch (err) {
                error.StreamTooLong => {
                    std.debug.print("[sse] line exceeds {d} bytes\n", .{sse.MAX_LINE_LEN});
                    return error.SseParseFailed;
                },
                error.ReadFailed => {
                    const cause = if (self.response.bodyErr()) |body_error| @errorName(body_error) else "ReadFailed";
                    std.debug.print("[sse] transport read failed before end of stream: {s}\n", .{cause});
                    return error.SseParseFailed;
                },
            };
            const raw = maybe orelse return null; // EOF: fin del stream
            // Normalizar CRLF.
            var line = raw;
            if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
            if (line.len == 0) continue; // separador entre eventos
            if (!std.mem.startsWith(u8, line, "data:")) continue; // ignorar event:/comentarios

            const value = line["data:".len..];
            const json_str = if (value.len > 0 and value[0] == ' ') value[1..] else value;
            if (self.observeDoneMarker(json_str)) return null;
            // `line` apunta al buffer interno del reader; se copia antes de devolver.
            const delta = try self.allocator.dupe(u8, json_str);
            // P01-T2: Extract finish_reason from the SSE JSON for auto-continuation.
            const finish_reason = extractFinishReason(self.allocator, json_str) catch null;
            return .{
                .allocator = self.allocator,
                .delta = delta,
                .finish_reason = finish_reason,
            };
        }
    }

    fn observeDoneMarker(self: *ChatStream, data: []const u8) bool {
        if (!std.mem.eql(u8, data, "[DONE]")) return false;
        self.saw_done = true;
        return true;
    }
};

/// P01-T2: Extract finish_reason from an SSE JSON chunk (OpenAI format).
/// Returns a duped string (caller frees via allocator) or null if not present.
/// Used to detect finish_reason="length" for auto-continuation.
fn extractFinishReason(allocator: std.mem.Allocator, json_str: []const u8) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;
    // OpenAI: choices[0].finish_reason
    if (obj.get("choices")) |choices| {
        if (choices == .array and choices.array.items.len > 0 and choices.array.items[0] == .object) {
            if (choices.array.items[0].object.get("finish_reason")) |fr| {
                if (fr == .string and fr.string.len > 0) {
                    return try allocator.dupe(u8, fr.string);
                }
            }
        }
    }
    // Anthropic: {type:"message_delta", delta:{stop_reason:"end_turn"}}
    if (obj.get("delta")) |delta| {
        if (delta == .object) {
            if (delta.object.get("stop_reason")) |sr| {
                if (sr == .string and sr.string.len > 0) {
                    // Map Anthropic stop_reason to OpenAI finish_reason equivalents
                    if (std.mem.eql(u8, sr.string, "end_turn") or std.mem.eql(u8, sr.string, "stop_sequence")) {
                        return try allocator.dupe(u8, "stop");
                    } else if (std.mem.eql(u8, sr.string, "max_tokens")) {
                        return try allocator.dupe(u8, "length");
                    }
                    return try allocator.dupe(u8, sr.string);
                }
            }
        }
    }
    // Gemini: candidates[0].finishReason. Normalizamos sus nombres al mismo
    // vocabulario que el consumidor OpenAI/Anthropic.
    if (obj.get("candidates")) |candidates| {
        if (candidates == .array and candidates.array.items.len > 0 and candidates.array.items[0] == .object) {
            if (candidates.array.items[0].object.get("finishReason")) |fr| {
                if (fr == .string and fr.string.len > 0) {
                    if (std.mem.eql(u8, fr.string, "STOP")) return try allocator.dupe(u8, "stop");
                    if (std.mem.eql(u8, fr.string, "MAX_TOKENS")) return try allocator.dupe(u8, "length");
                    return try allocator.dupe(u8, fr.string);
                }
            }
        }
    }
    return null;
}

test "extractFinishReason detects length" {
    const allocator = std.testing.allocator;
    const json =
        \\{"choices":[{"delta":{"content":"hello"},"finish_reason":"length"}]}
    ;
    const fr = (try extractFinishReason(allocator, json)) orelse return error.TestFailed;
    defer allocator.free(fr);
    try std.testing.expectEqualStrings("length", fr);
}

test "extractFinishReason returns null when no finish_reason" {
    const allocator = std.testing.allocator;
    const json =
        \\{"choices":[{"delta":{"content":"hello"},"finish_reason":null}]}
    ;
    const fr = try extractFinishReason(allocator, json);
    try std.testing.expect(fr == null);
}

test "extractFinishReason returns null on non-JSON" {
    const allocator = std.testing.allocator;
    const fr = try extractFinishReason(allocator, "not json at all");
    try std.testing.expect(fr == null);
}

test "extractFinishReason detects Anthropic max_tokens as length" {
    const allocator = std.testing.allocator;
    const json =
        \\{"type":"message_delta","delta":{"stop_reason":"max_tokens"}}
    ;
    const fr = (try extractFinishReason(allocator, json)) orelse return error.TestFailed;
    defer allocator.free(fr);
    try std.testing.expectEqualStrings("length", fr);
}

test "extractFinishReason detects Anthropic end_turn as stop" {
    const allocator = std.testing.allocator;
    const json =
        \\{"type":"message_delta","delta":{"stop_reason":"end_turn"}}
    ;
    const fr = (try extractFinishReason(allocator, json)) orelse return error.TestFailed;
    defer allocator.free(fr);
    try std.testing.expectEqualStrings("stop", fr);
}

test "extractFinishReason normalizes Gemini STOP and MAX_TOKENS" {
    const allocator = std.testing.allocator;
    const stop = (try extractFinishReason(allocator, "{\"candidates\":[{\"finishReason\":\"STOP\"}]}")) orelse return error.TestFailed;
    defer allocator.free(stop);
    try std.testing.expectEqualStrings("stop", stop);
    const length = (try extractFinishReason(allocator, "{\"candidates\":[{\"finishReason\":\"MAX_TOKENS\"}]}")) orelse return error.TestFailed;
    defer allocator.free(length);
    try std.testing.expectEqualStrings("length", length);
}

test "ChatStream remembers an explicit DONE marker" {
    var stream: ChatStream = undefined;
    stream.saw_done = false;
    try std.testing.expect(!stream.observeDoneMarker("not-done"));
    try std.testing.expect(!stream.saw_done);
    try std.testing.expect(stream.observeDoneMarker("[DONE]"));
    try std.testing.expect(stream.saw_done);
}
