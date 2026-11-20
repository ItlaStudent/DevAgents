pub const posix_process = if (@import("builtin").os.tag == .windows) struct {} else @import("posix_process.zig");
pub const posix_stat = if (@import("builtin").os.tag == .windows) struct {} else @import("posix_stat.zig");
pub const posix_files = if (@import("builtin").os.tag == .windows) struct {} else @import("posix_files.zig");
pub const platform = @import("platform.zig");
const std = @import("std");

/// HTTP/TLS client with SSE streaming.
pub const http_client = @import("http/client.zig");

/// D1 (H5): banco aislado de lectura de socket con plazo (WSAPoll).
/// NO esta cableado al cliente HTTP todavia - ver la cabecera del archivo.
pub const poll_socket = @import("http/poll_socket.zig");

/// D1 tramo 2: el plazo de socket bajo la capa TLS del cliente real.
pub const deadline_io = @import("http/deadline_io.zig");

/// Server-Sent Events parser.
pub const sse = @import("http/sse.zig");

/// Generic connector interface.
pub const connector = @import("connector.zig");

/// Provider-neutral Connector V2 contract. V1 remains available as `connector`.
pub const connector_v2 = @import("connector_v2.zig");

/// Discovery V2 (Capabilities & Routing)
pub const discovery_v2 = @import("discovery_v2.zig");

/// Discovery V2 Registry & Routing
pub const discovery_registry = @import("discovery_registry.zig");

/// Ownership-safe adapter from raw V1 chunks to normalized V2 events.
pub const normalized_stream = @import("normalized_stream.zig");

/// Accumulates streaming chunks into complete tool calls.
pub const tool_call_accumulator = @import("tool_call_accumulator.zig");

/// Assembles normalized events into a provider-neutral response.
pub const response_assembler = @import("response_assembler.zig");

/// Provider-neutral stream collector.
pub const stream_collector = @import("stream_collector.zig");

/// Pure retry planner.
pub const retry_planner = @import("retry_planner.zig");

/// Provider execution plan (selection and fallback).
pub const provider_execution_plan = @import("provider_execution_plan.zig");

/// Provider execution runner/orchestrator V2.
pub const provider_executor_v2 = @import("provider_executor_v2.zig");

/// Provider tool execution loop V2.
pub const tool_execution_loop_v2 = @import("tool_execution_loop_v2.zig");

/// OpenAI-compatible adapter.
pub const openai_adapter = @import("adapters/openai.zig");

/// OpenAI-compatible chunk normalizer for Connector V2.
pub const openai_v2_parser = @import("adapters/openai_v2.zig");

/// Anthropic adapter.
pub const anthropic_adapter = @import("adapters/anthropic.zig");

/// Anthropic Messages event normalizer for Connector V2.
pub const anthropic_v2_parser = @import("adapters/anthropic_v2.zig");

/// Gemini adapter.
pub const gemini_adapter = @import("adapters/gemini.zig");

/// Gemini GenerateContent chunk normalizer for Connector V2.
pub const gemini_v2_parser = @import("adapters/gemini_v2.zig");

/// Provider configurations and factory.
pub const providers = @import("providers.zig");

/// Request builders for Connector V2.
pub const request_builders = @import("request_builders/root.zig");

/// Pure HTTP error classifier for Connector V2.
pub const error_mapping_v2 = @import("error_mapping_v2.zig");

/// Real, injectable HTTP transport for Connector V2 (request builders + HTTP/SSE).
pub const transport_v2 = @import("transport_v2.zig");

/// Web search (Tavily / Brave / DuckDuckGo).
pub const embeddings = @import("embeddings.zig");
pub const web_search = @import("web_search.zig");

/// GitHub REST API and git connector.
pub const github = @import("github.zig");

/// Gitea forge connector: PRs por API REST (git.4stra.dev no es GitHub).
pub const gitea = @import("gitea.zig");
pub const forge_rest = @import("forge_rest.zig");

test "providers exports connector v2 beside connector v1" {
    try std.testing.expect(@hasDecl(@This(), "connector_v2"));
}

test "providers exports openai v2 parser beside openai v1 adapter" {
    try std.testing.expect(@hasDecl(@This(), "openai_v2_parser"));
}

test "providers exports anthropic v2 parser beside anthropic v1 adapter" {
    try std.testing.expect(@hasDecl(@This(), "anthropic_v2_parser"));
}

test "providers exports gemini v2 parser beside gemini v1 adapter" {
    try std.testing.expect(@hasDecl(@This(), "gemini_v2_parser"));
}

test "providers exports normalized stream v2" {
    try std.testing.expect(@hasDecl(@This(), "normalized_stream"));
}

// Fuerza la inclusión de los tests de los submódulos de providers (ver nota en core/src/root.zig).
test {
    _ = @import("external_error.zig");
    _ = @import("http/client.zig");
    _ = @import("http/sse.zig");
    _ = @import("http/poll_socket.zig");
    _ = @import("connector.zig");
    _ = @import("connector_v2.zig");
    _ = @import("discovery_v2.zig");
    _ = @import("normalized_stream.zig");
    _ = @import("tool_call_accumulator.zig");
    _ = @import("response_assembler.zig");
    _ = @import("stream_collector.zig");
    _ = @import("retry_planner.zig");
    _ = @import("provider_execution_plan.zig");
    _ = @import("provider_executor_v2.zig");
    _ = @import("tool_execution_loop_v2.zig");
    _ = @import("error_mapping_v2.zig");
    _ = @import("transport_v2.zig");
    _ = @import("adapters/openai.zig");
    _ = @import("adapters/openai_v2.zig");
    _ = @import("adapters/gemini.zig");
    _ = @import("adapters/gemini_v2.zig");
    _ = @import("adapters/anthropic.zig");
    _ = @import("adapters/anthropic_v2.zig");
    _ = @import("providers.zig");
    _ = @import("web_search.zig");
    _ = @import("embeddings.zig");
    _ = @import("discovery_registry.zig");
    _ = @import("github.zig");
    _ = @import("gitea.zig");
    _ = @import("forge_rest.zig");
}

pub const external_error = @import("external_error.zig");

test "SEC-RED adaptadores conservan RedirectBlocked y causa visible" {
    var buffer: [512]u8 = undefined;
    const len = platform.env("BEATS_SEC_RED_URL", &buffer, buffer.len);
    if (len == 0 or len >= buffer.len) return error.MissingSecurityFixture;
    const a = std.testing.allocator;
    var http = try http_client.HttpClient.initForUrl(a, buffer[0..len]);
    defer http.deinit();
    const openai = try openai_adapter.OpenAIAdapter.init(a, &http, buffer[0..len], "fixture-key", &.{}, false);
    defer openai.deinit();
    const anthropic = try anthropic_adapter.AnthropicAdapter.init(a, &http, buffer[0..len], "fixture-key");
    defer anthropic.deinit();
    const gemini = try gemini_adapter.GeminiAdapter.init(a, &http, buffer[0..len], "fixture-key");
    defer gemini.deinit();
    for ([_]connector.Connector{ openai.connectorInterface(), anthropic.connectorInterface(), gemini.connectorInterface() }) |adapter| {
        try std.testing.expectError(error.RedirectBlocked, adapter.chat(a, .{ .model = "fixture-model", .messages = &.{.{ .role = "user", .content = "Hola" }} }));
        try std.testing.expectEqual(@as(?u16, 302), http.last_failure.http_status);
        try std.testing.expect(std.mem.indexOf(u8, http.last_failure.message(), http_client.REDIRECT_MESSAGE) != null);
    }
    for ([_]connector.Connector{ openai.connectorInterface(), gemini.connectorInterface() }) |adapter| {
        try std.testing.expectError(error.RedirectBlocked, adapter.listModels(a));
    }
}
