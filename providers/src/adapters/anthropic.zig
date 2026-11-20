const std = @import("std");
const connector = @import("../connector.zig");
const http_client = @import("../http/client.zig");

/// Adaptador Anthropic (Claude) para la API Messages de Anthropic.
pub const AnthropicAdapter = struct {
    allocator: std.mem.Allocator,
    http: *http_client.HttpClient,
    base_url: []const u8,
    api_key: []const u8,

    pub fn init(allocator: std.mem.Allocator, http: *http_client.HttpClient, base_url: []const u8, api_key: []const u8) !*AnthropicAdapter {
        const self = try allocator.create(AnthropicAdapter);
        errdefer allocator.destroy(self);
        self.* = .{
            .allocator = allocator,
            .http = http,
            .base_url = try allocator.dupe(u8, base_url),
            .api_key = try allocator.dupe(u8, api_key),
        };
        return self;
    }

    pub fn deinit(self: *AnthropicAdapter) void {
        self.allocator.free(self.base_url);
        self.allocator.free(self.api_key);
        self.allocator.destroy(self);
    }

    pub fn connectorInterface(self: *AnthropicAdapter) connector.Connector {
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
        const self: *AnthropicAdapter = @ptrCast(@alignCast(ctx));
        self.deinit();
    }

    fn chatImpl(ctx: *anyopaque, allocator: std.mem.Allocator, options: connector.ChatOptions) connector.ConnectorError!connector.ChatStream {
        const self: *AnthropicAdapter = @ptrCast(@alignCast(ctx));
        const url = try std.fmt.allocPrint(allocator, "{s}/messages", .{self.base_url});
        defer allocator.free(url);

        const body = try buildChatBody(allocator, options);
        defer allocator.free(body);

        const req = self.http.postSseWithDualHeaders(
            url,
            body,
            "x-api-key",
            self.api_key,
            "anthropic-version",
            "2023-06-01",
        ) catch |e| {
            return switch (e) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.RequestFailed,
            };
        };

        const response = self.http.allocator.create(std.http.Client.Response) catch {
            req.deinit();
            self.http.allocator.destroy(req);
            return error.OutOfMemory;
        };

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

    fn listModelsImpl(_: *anyopaque, allocator: std.mem.Allocator) connector.ConnectorError![]const u8 {
        return try allocator.dupe(u8, "[\"claude-3-5-sonnet-20241022\",\"claude-3-opus-20240229\",\"claude-3-haiku-20240307\"]");
    }

    fn buildChatBody(allocator: std.mem.Allocator, options: connector.ChatOptions) error{OutOfMemory}![]const u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        writeChatJson(&out.writer, options) catch return error.OutOfMemory;
        return allocator.dupe(u8, out.written());
    }

    /// H6 — cuerpo de la API Messages, con puntos de corte de caché.
    ///
    /// Dos cosas se arreglan aquí a la vez, y conviene separarlas:
    ///
    /// 1. Anthropic NO acepta `role:"system"` dentro de `messages`; las
    ///    instrucciones de sistema van en el campo `system` de primer nivel.
    ///    Como el motor SIEMPRE manda un turno de sistema, este adaptador
    ///    producía peticiones que la API rechaza. Ahora se separan.
    ///
    /// 2. `cache_control` marca el FINAL de un prefijo cacheable, no el
    ///    principio. Se ponen como mucho dos cortes —el final del sistema y el
    ///    final del primer turno de usuario— porque son las dos fronteras que
    ///    de verdad se repiten: el sistema es idéntico en todas las tareas de
    ///    un departamento, y el primer turno de usuario se repite entero en
    ///    cada continuación por `finish_reason=length`.
    fn writeChatJson(writer: *std.Io.Writer, options: connector.ChatOptions) !void {
        var js: std.json.Stringify = .{ .writer = writer, .options = .{} };
        try js.beginObject();
        try js.objectField("model");
        try js.write(options.model);
        try js.objectField("max_tokens");
        try js.write(options.max_tokens orelse 4096);
        try js.objectField("stream");
        try js.write(options.stream);

        // ── system ────────────────────────────────────────────────────────
        var system_count: usize = 0;
        for (options.messages) |msg| {
            if (std.mem.eql(u8, msg.role, "system")) system_count += 1;
        }
        if (system_count > 0) {
            try js.objectField("system");
            try js.beginArray();
            var seen: usize = 0;
            for (options.messages) |msg| {
                if (!std.mem.eql(u8, msg.role, "system")) continue;
                seen += 1;
                try js.beginObject();
                try js.objectField("type");
                try js.write("text");
                try js.objectField("text");
                try js.write(msg.content);
                // El corte va en el ÚLTIMO bloque de sistema: marca el final
                // del prefijo, no cada trozo.
                if (options.cache_prefix and seen == system_count) {
                    try writeCacheControl(&js);
                }
                try js.endObject();
            }
            try js.endArray();
        }

        // ── messages ──────────────────────────────────────────────────────
        var turn_count: usize = 0;
        for (options.messages) |msg| {
            if (!std.mem.eql(u8, msg.role, "system")) turn_count += 1;
        }
        try js.objectField("messages");
        try js.beginArray();
        var turn_index: usize = 0;
        for (options.messages) |msg| {
            if (std.mem.eql(u8, msg.role, "system")) continue;
            turn_index += 1;
            // Segundo corte: final del primer turno de usuario, y solo cuando
            // hay conversación por detrás (continuaciones). En una llamada de
            // un solo turno ese corte no ahorraría nada y gasta uno de los
            // cuatro que permite la API.
            const breakpoint = options.cache_prefix and turn_index == 1 and turn_count > 1;
            try js.beginObject();
            try js.objectField("role");
            try js.write(msg.role);
            try js.objectField("content");
            if (breakpoint or msg.images.len > 0) {
                try js.beginArray();
                for (msg.images) |image| try @import("anthropic_v2.zig").writeImagePart(&js, image);
                try js.beginObject();
                try js.objectField("type");
                try js.write("text");
                try js.objectField("text");
                try js.write(msg.content);
                if (breakpoint) try writeCacheControl(&js);
                try js.endObject();
                try js.endArray();
            } else {
                try js.write(msg.content);
            }
            try js.endObject();
        }
        try js.endArray();
        try js.endObject();
    }

    fn writeCacheControl(js: *std.json.Stringify) !void {
        try js.objectField("cache_control");
        try js.beginObject();
        try js.objectField("type");
        try js.write("ephemeral");
        try js.endObject();
    }
};

test "anthropic adapter init and deinit" {
    const allocator = std.testing.allocator;
    var http = try http_client.HttpClient.init(allocator);
    defer http.deinit();

    var adapter = try AnthropicAdapter.init(allocator, &http, "https://api.anthropic.com/v1", "test-key");
    defer adapter.deinit();

    const conn = adapter.connectorInterface();
    _ = conn;
}

test "H6: el turno de sistema sale del array de mensajes (Anthropic lo rechaza ahi)" {
    const allocator = std.testing.allocator;
    const msgs = [_]connector.ChatMessage{
        .{ .role = "system", .content = "Eres un programador." },
        .{ .role = "user", .content = "haz una calculadora" },
    };
    const body = try AnthropicAdapter.buildChatBody(allocator, .{ .model = "claude-x", .messages = &msgs });
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\":[") != null);
    // Ni rastro del rol "system" dentro de messages.
    const messages_at = std.mem.indexOf(u8, body, "\"messages\"").?;
    try std.testing.expect(std.mem.indexOf(u8, body[messages_at..], "\"system\"") == null);
}

test "CK-PRV-007 Q4: varios turnos de sistema se conservan todos y en orden en el campo system" {
    const allocator = std.testing.allocator;
    const msgs = [_]connector.ChatMessage{
        .{ .role = "system", .content = "REGLA_A: primero" },
        .{ .role = "user", .content = "hola" },
        .{ .role = "system", .content = "REGLA_B: segundo" },
        .{ .role = "system", .content = "REGLA_C: tercero" },
    };
    const body = try AnthropicAdapter.buildChatBody(allocator, .{ .model = "claude-x", .messages = &msgs });
    defer allocator.free(body);
    // Campo de primer nivel `system` como array (Anthropic no admite role system en messages).
    try std.testing.expect(std.mem.indexOf(u8, body, "\"system\":[") != null);
    // Los tres bloques viajan, en el mismo orden en que llegaron.
    const a = std.mem.indexOf(u8, body, "REGLA_A: primero") orelse return error.TestUnexpectedResult;
    const b = std.mem.indexOf(u8, body, "REGLA_B: segundo") orelse return error.TestUnexpectedResult;
    const c = std.mem.indexOf(u8, body, "REGLA_C: tercero") orelse return error.TestUnexpectedResult;
    try std.testing.expect(a < b and b < c);
    // Ninguno se cuela dentro de `messages`.
    const messages_at = std.mem.indexOf(u8, body, "\"messages\"").?;
    try std.testing.expect(std.mem.indexOf(u8, body[messages_at..], "REGLA_A") == null);
    try std.testing.expect(std.mem.indexOf(u8, body[messages_at..], "REGLA_B") == null);
    try std.testing.expect(std.mem.indexOf(u8, body[messages_at..], "REGLA_C") == null);
}

test "H6: sin cache_prefix no se manda ningun cache_control" {
    const allocator = std.testing.allocator;
    const msgs = [_]connector.ChatMessage{
        .{ .role = "system", .content = "Eres un programador." },
        .{ .role = "user", .content = "hola" },
    };
    const body = try AnthropicAdapter.buildChatBody(allocator, .{ .model = "claude-x", .messages = &msgs });
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "cache_control") == null);
}

test "H6: con cache_prefix el corte va al final del sistema" {
    const allocator = std.testing.allocator;
    const msgs = [_]connector.ChatMessage{
        .{ .role = "system", .content = "Eres un programador." },
        .{ .role = "user", .content = "hola" },
    };
    const body = try AnthropicAdapter.buildChatBody(allocator, .{ .model = "claude-x", .messages = &msgs, .cache_prefix = true });
    defer allocator.free(body);
    try std.testing.expect(std.mem.indexOf(u8, body, "\"cache_control\":{\"type\":\"ephemeral\"}") != null);
    // Un solo turno de usuario: NO se gasta un segundo corte.
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, body, i, "cache_control")) |at| : (i = at + 1) count += 1;
    try std.testing.expectEqual(@as(usize, 1), count);
}

test "H6: en una continuacion hay DOS cortes — sistema y primer turno" {
    const allocator = std.testing.allocator;
    const msgs = [_]connector.ChatMessage{
        .{ .role = "system", .content = "Eres un programador." },
        .{ .role = "user", .content = "haz una calculadora" },
        .{ .role = "assistant", .content = "<html>..." },
        .{ .role = "user", .content = "Continue your previous response" },
    };
    const body = try AnthropicAdapter.buildChatBody(allocator, .{ .model = "claude-x", .messages = &msgs, .cache_prefix = true });
    defer allocator.free(body);
    var count: usize = 0;
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, body, i, "cache_control")) |at| : (i = at + 1) count += 1;
    try std.testing.expectEqual(@as(usize, 2), count);
    // El primer turno de usuario viaja como bloque, no como cadena suelta.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":[{\"type\":\"text\",\"text\":\"haz una calculadora\"") != null);
    // El ultimo turno sigue siendo cadena simple: no hace falta bloque.
    try std.testing.expect(std.mem.indexOf(u8, body, "\"content\":\"Continue your previous response\"") != null);
}

test "E5.24 anthropic streaming adapter serializes every attached image" {
    const a = std.testing.allocator;
    const images = [_]connector.ImagePart{ .{ .mime_type = "image/png", .base64 = "YWJj" }, .{ .mime_type = "image/webp", .base64 = "ZGVm" } };
    const messages = [_]connector.ChatMessage{ .{ .role = "system", .content = "rules" }, .{ .role = "user", .content = "look", .images = &images } };
    const options = connector.ChatOptions{ .model = "fixture", .messages = &messages };
    const body = try AnthropicAdapter.buildChatBody(a, options);
    defer a.free(body);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, body, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.contains("messages"));
    try std.testing.expect(std.mem.indexOf(u8, body, "YWJj") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "ZGVm") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "image/png") != null);
    try std.testing.expect(std.mem.indexOf(u8, body, "image/webp") != null);
}
