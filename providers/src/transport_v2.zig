const std = @import("std");
const connector_v2 = @import("connector_v2.zig");
const http_client = @import("http/client.zig");

pub const HttpAttemptCtx = struct {
    allocator: std.mem.Allocator = undefined,
    http: ?*anyopaque = null,
    cfg: ?*anyopaque = null,
    api_key: []const u8 = "",
    model_id: []const u8 = "",
    prompt: []const u8 = "",
    system_prompt: ?[]const u8 = null,
    temperature: f32 = 0.7,
    token: ?*anyopaque = null,
    base_url: []const u8 = "",
    conn: ?*anyopaque = null,
    protocol: connector_v2.WireProtocol = .openai_compatible,
    is_cancelled_fn: ?*const fn (?*anyopaque) bool = null,
    request_body: []const u8 = "",
    response: ?[]u8 = null,
    post_json_fn: ?*const fn (*HttpAttemptCtx, []const u8, []const u8, []const std.http.Header) anyerror!http_client.JsonResponse = null,

    pub fn setRequest(self: ?*anyopaque, body: []const u8) !void {
        const ctx: *HttpAttemptCtx = @ptrCast(@alignCast(self orelse return error.InvalidContext));
        ctx.request_body = body;
    }

    pub fn deinit(self: *HttpAttemptCtx) void {
        if (self.response) |response| self.allocator.free(response);
        self.response = null;
        self.request_body = "";
    }
};

fn cancelled(ctx: *HttpAttemptCtx, client: ?*http_client.HttpClient) bool {
    if (ctx.is_cancelled_fn) |is_cancelled| if (is_cancelled(ctx.token)) return true;
    return if (client) |http| http.cancelledByDeadline() else false;
}

fn endpoint(allocator: std.mem.Allocator, ctx: *const HttpAttemptCtx) ![]u8 {
    const base = std.mem.trim(u8, ctx.base_url, "/");
    return switch (ctx.protocol) {
        .openai_compatible => std.fmt.allocPrint(allocator, "{s}/chat/completions", .{base}),
        .anthropic, .anthropic_v1 => std.fmt.allocPrint(allocator, "{s}/messages", .{base}),
        .gemini, .gemini_v1beta => blk: {
            const model = if (std.mem.startsWith(u8, ctx.model_id, "models/")) ctx.model_id[7..] else ctx.model_id;
            break :blk std.fmt.allocPrint(allocator, "{s}/models/{s}:generateContent", .{ base, model });
        },
    };
}

fn classifyStatus(status: std.http.Status) anyerror!void {
    return switch (status) {
        .unauthorized, .forbidden => error.AuthFailed,
        .payment_required => error.QuotaExceeded,
        .too_many_requests => error.RateLimited,
        .not_found => error.ModelNotFound,
        else => if (status.class() == .server_error) error.ProviderError else if (status.class() != .success) error.RequestFailed else {},
    };
}

pub fn attemptFn(raw_ctx: ?*anyopaque) anyerror![]const u8 {
    const ctx: *HttpAttemptCtx = @ptrCast(@alignCast(raw_ctx orelse return error.InvalidContext));
    const client: ?*http_client.HttpClient = if (ctx.post_json_fn == null)
        @ptrCast(@alignCast(ctx.http orelse return error.InvalidContext))
    else
        null;
    if (cancelled(ctx, client)) return error.Cancelled;
    if (ctx.request_body.len == 0 or ctx.base_url.len == 0 or ctx.model_id.len == 0) return error.InvalidRequest;
    if (ctx.response) |response| {
        ctx.allocator.free(response);
        ctx.response = null;
    }

    const url = try endpoint(ctx.allocator, ctx);
    defer ctx.allocator.free(url);
    var headers: [3]std.http.Header = undefined;
    var header_count: usize = 1;
    headers[0] = .{ .name = "content-type", .value = "application/json" };
    var auth_value: ?[]u8 = null;
    defer if (auth_value) |value| ctx.allocator.free(value);
    switch (ctx.protocol) {
        .openai_compatible => {
            // MODELO-LOCAL: un proveedor sin clave (Ollama) llega con api_key ==
            // "" — emitir `Bearer ` vacío es un header inválido, así que la
            // llamada sale sin Authorization en absoluto.
            if (ctx.api_key.len > 0) {
                auth_value = try std.fmt.allocPrint(ctx.allocator, "Bearer {s}", .{ctx.api_key});
                headers[header_count] = .{ .name = "authorization", .value = auth_value.? };
                header_count += 1;
            }
        },
        .anthropic, .anthropic_v1 => {
            headers[header_count] = .{ .name = "x-api-key", .value = ctx.api_key };
            header_count += 1;
            headers[header_count] = .{ .name = "anthropic-version", .value = "2023-06-01" };
            header_count += 1;
        },
        .gemini, .gemini_v1beta => {
            headers[header_count] = .{ .name = "x-goog-api-key", .value = ctx.api_key };
            header_count += 1;
        },
    }

    var result = if (ctx.post_json_fn) |post|
        try post(ctx, url, ctx.request_body, headers[0..header_count])
    else
        try client.?.postJsonWithHeaders(url, ctx.request_body, headers[0..header_count]);
    errdefer ctx.allocator.free(result.body);
    if (cancelled(ctx, client)) return error.Cancelled;
    if (result.status.class() != .success) {
        if (client) |http| {
            http.last_failure.capture(@intFromEnum(result.status), result.body, ctx.api_key);
            // A6 (10-nov): Retry-After / X-RateLimit-* de las cabeceras.
            http.last_failure.rate.merge(result.rate);
        }
    }
    try classifyStatus(result.status);
    ctx.response = result.body;
    result.body = undefined;
    return ctx.response.?;
}

const MockState = struct {
    allocator: std.mem.Allocator,
    status: std.http.Status,
    url_buf: [512]u8 = undefined,
    url_len: usize = 0,
    body_ok: bool = false,
    headers_ok: bool = false,
    /// Registro genérico para tests de política de cabeceras (MODELO-LOCAL):
    /// cuántas cabeceras salieron y si alguna era `authorization`.
    last_header_count: usize = 0,
    last_had_auth: bool = false,
};

fn mockPost(ctx: *HttpAttemptCtx, url: []const u8, body: []const u8, headers: []const std.http.Header) anyerror!http_client.JsonResponse {
    const state: *MockState = @ptrCast(@alignCast(ctx.conn.?));
    state.url_len = url.len;
    @memcpy(state.url_buf[0..url.len], url);
    state.body_ok = std.mem.eql(u8, body, ctx.request_body);
    state.last_header_count = headers.len;
    state.last_had_auth = false;
    for (headers) |h| {
        if (std.mem.eql(u8, h.name, "authorization")) state.last_had_auth = true;
    }
    state.headers_ok = switch (ctx.protocol) {
        .openai_compatible => headers.len == 2 and
            std.mem.eql(u8, headers[1].name, "authorization") and
            std.mem.eql(u8, headers[1].value, "Bearer fake-key"),
        .anthropic, .anthropic_v1 => headers.len == 3 and
            std.mem.eql(u8, headers[1].name, "x-api-key") and
            std.mem.eql(u8, headers[1].value, "fake-key") and
            std.mem.eql(u8, headers[2].name, "anthropic-version") and
            std.mem.eql(u8, headers[2].value, "2023-06-01"),
        .gemini, .gemini_v1beta => headers.len == 2 and
            std.mem.eql(u8, headers[1].name, "x-goog-api-key") and
            std.mem.eql(u8, headers[1].value, "fake-key"),
    };
    return .{ .status = state.status, .body = try state.allocator.dupe(u8, "mock-response") };
}

fn alwaysCancelled(_: ?*anyopaque) bool {
    return true;
}

test "transport v2 builds provider endpoints and headers for all protocols" {
    const allocator = std.testing.allocator;
    var state = MockState{ .allocator = allocator, .status = .ok };
    var ctx = HttpAttemptCtx{ .allocator = allocator, .http = @ptrCast(&state), .conn = @ptrCast(&state), .api_key = "fake-key", .model_id = "models/gemini-test", .base_url = "http://127.0.0.1:9/v1beta/", .request_body = "{\"contents\":[]}", .post_json_fn = mockPost };
    defer ctx.deinit();
    for ([_]struct { protocol: connector_v2.WireProtocol, url: []const u8, header: []const u8 }{
        .{ .protocol = .openai_compatible, .url = "http://127.0.0.1:9/v1beta/chat/completions", .header = "authorization" },
        .{ .protocol = .anthropic, .url = "http://127.0.0.1:9/v1beta/messages", .header = "x-api-key" },
        .{ .protocol = .gemini, .url = "http://127.0.0.1:9/v1beta/models/gemini-test:generateContent", .header = "x-goog-api-key" },
    }) |case| {
        ctx.protocol = case.protocol;
        const result = try attemptFn(&ctx);
        try std.testing.expectEqualStrings("mock-response", result);
        try std.testing.expectEqualStrings(case.url, state.url_buf[0..state.url_len]);
        try std.testing.expect(state.body_ok);
        try std.testing.expect(state.headers_ok);
        try std.testing.expect(std.mem.indexOf(u8, state.url_buf[0..state.url_len], "fake-key") == null);
    }
}

test "transport v2 openai_compatible omite authorization con clave vacia (MODELO-LOCAL)" {
    const allocator = std.testing.allocator;
    var state = MockState{ .allocator = allocator, .status = .ok };
    var ctx = HttpAttemptCtx{ .allocator = allocator, .http = @ptrCast(&state), .conn = @ptrCast(&state), .api_key = "", .model_id = "llama3.1:8b", .base_url = "http://127.0.0.1:11434/v1", .request_body = "{}", .post_json_fn = mockPost, .protocol = .openai_compatible };
    defer ctx.deinit();
    const result = try attemptFn(&ctx);
    try std.testing.expectEqualStrings("mock-response", result);
    // Sin clave: solo content-type — nada de `Authorization: Bearer ` inválido.
    try std.testing.expectEqual(@as(usize, 1), state.last_header_count);
    try std.testing.expect(!state.last_had_auth);
}

test "transport v2 maps statuses and cancellation without network" {
    const allocator = std.testing.allocator;
    var state = MockState{ .allocator = allocator, .status = .unauthorized };
    var ctx = HttpAttemptCtx{ .allocator = allocator, .http = @ptrCast(&state), .conn = @ptrCast(&state), .api_key = "fake", .model_id = "model", .base_url = "http://127.0.0.1:9", .request_body = "{}", .post_json_fn = mockPost };
    defer ctx.deinit();
    try std.testing.expectError(error.AuthFailed, attemptFn(&ctx));
    state.status = .too_many_requests;
    try std.testing.expectError(error.RateLimited, attemptFn(&ctx));
    state.status = .payment_required;
    try std.testing.expectError(error.QuotaExceeded, attemptFn(&ctx));
    state.status = .bad_request;
    try std.testing.expectError(error.RequestFailed, attemptFn(&ctx));
    state.status = .not_found;
    try std.testing.expectError(error.ModelNotFound, attemptFn(&ctx));
    state.status = .internal_server_error;
    try std.testing.expectError(error.ProviderError, attemptFn(&ctx));
    ctx.is_cancelled_fn = alwaysCancelled;
    try std.testing.expectError(error.Cancelled, attemptFn(&ctx));
}

test "transport v2 setRequest borrows body and deinit frees response" {
    const allocator = std.testing.allocator;
    var ctx = HttpAttemptCtx{ .allocator = allocator };
    const body = "{\"prompt\":\"fake\"}";
    try HttpAttemptCtx.setRequest(&ctx, body);
    try std.testing.expectEqualStrings(body, ctx.request_body);
    ctx.response = try allocator.dupe(u8, "response");
    ctx.deinit();
    try std.testing.expectEqual(@as(?[]u8, null), ctx.response);
    try std.testing.expectEqualStrings("", ctx.request_body);
}
