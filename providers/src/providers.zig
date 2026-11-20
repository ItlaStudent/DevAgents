const std = @import("std");
const connector = @import("connector.zig");
const openai = @import("adapters/openai.zig");
const gemini = @import("adapters/gemini.zig");
const anthropic = @import("adapters/anthropic.zig");
const http_client = @import("http/client.zig");

/// Configuración de un proveedor.
pub const ProviderConfig = struct {
    name: []const u8,
    base_url: []const u8,
    api_style: ApiStyle,
    is_free_tier: bool,
    /// MODELO-LOCAL: el proveedor corre en la máquina del usuario (Ollama).
    /// Sin clave API: las peticiones van sin Authorization. Y con política
    /// conservadora por defecto — un solo modelo exacto, sin respaldos ni
    /// ejecución paralela de inferencias (los escapes opt-in son
    /// DEVAGENTS_LOCAL_ALLOW_FALLBACK y DEVAGENTS_LOCAL_ALLOW_PARALLEL).
    is_local: bool = false,
};

pub const ApiStyle = enum {
    openai,
    google_gemini,
    anthropic,
    nvidia_nim,
    cloudflare,
    cohere,
    github_models,
    opencode,
    web_search,
};

const connector_v2 = @import("connector_v2.zig");

pub const WireProtocol = connector_v2.WireProtocol;

pub fn protocolForApiStyle(style: ApiStyle) error{NotAnLlmProvider}!WireProtocol {
    return switch (style) {
        .google_gemini => .gemini,
        .anthropic => .anthropic,
        .openai, .nvidia_nim, .cloudflare, .cohere, .github_models, .opencode => .openai_compatible,
        .web_search => error.NotAnLlmProvider,
    };
}

/// Proveedores soportados (Fase 2).
pub const ALL_PROVIDERS = [_]ProviderConfig{
    .{ .name = "OpenRouter", .base_url = "https://openrouter.ai/api/v1", .api_style = .openai, .is_free_tier = true },
    .{ .name = "Claude", .base_url = "https://api.anthropic.com/v1", .api_style = .anthropic, .is_free_tier = false },
    .{ .name = "GPT", .base_url = "https://api.openai.com/v1", .api_style = .openai, .is_free_tier = false },
    .{ .name = "GLM", .base_url = "https://api.z.ai/api/coding/paas/v4", .api_style = .openai, .is_free_tier = false },
    .{ .name = "Groq", .base_url = "https://api.groq.com/openai/v1", .api_style = .openai, .is_free_tier = true },
    .{ .name = "Cerebras", .base_url = "https://api.cerebras.ai/v1", .api_style = .openai, .is_free_tier = true },
    .{ .name = "Google AI Studio", .base_url = "https://generativelanguage.googleapis.com/v1beta", .api_style = .google_gemini, .is_free_tier = true },
    .{ .name = "Gemini", .base_url = "https://generativelanguage.googleapis.com/v1beta", .api_style = .google_gemini, .is_free_tier = false },
    .{ .name = "Mistral", .base_url = "https://api.mistral.ai/v1", .api_style = .openai, .is_free_tier = true },
    .{ .name = "DeepSeek", .base_url = "https://api.deepseek.com/v1", .api_style = .openai, .is_free_tier = true },
    .{ .name = "MiniMax", .base_url = "https://api.minimax.io/v1", .api_style = .openai, .is_free_tier = false },
    .{ .name = "Grok", .base_url = "https://api.x.ai/v1", .api_style = .openai, .is_free_tier = false },
    .{ .name = "nGrok", .base_url = "https://gateway.ngrok.ai/v1", .api_style = .openai, .is_free_tier = false },
    .{ .name = "Muse Spark", .base_url = "https://api.meta.ai/v1", .api_style = .openai, .is_free_tier = false },
    .{ .name = "NVIDIA API", .base_url = "https://integrate.api.nvidia.com/v1", .api_style = .nvidia_nim, .is_free_tier = true },
    .{ .name = "Cloudflare Workers AI", .base_url = "https://api.cloudflare.com/client/v4/accounts/{account_id}/ai/v1", .api_style = .cloudflare, .is_free_tier = true },
    .{ .name = "GitHub Models", .base_url = "https://models.inference.ai.azure.com", .api_style = .github_models, .is_free_tier = true },
    .{ .name = "Cohere", .base_url = "https://api.cohere.ai/compatibility/v1", .api_style = .cohere, .is_free_tier = true },
    .{ .name = "SambaNova", .base_url = "https://api.sambanova.ai/v1", .api_style = .openai, .is_free_tier = true },
    .{ .name = "Chutes.ai", .base_url = "https://api.chutes.ai/v1", .api_style = .openai, .is_free_tier = true },
    .{ .name = "OpenCode", .base_url = "https://opencode.ai/zen/v1", .api_style = .opencode, .is_free_tier = true },
    // TokenRouter: agregador OpenAI-compatible (api.tokenrouter.com). URL dada
    // por el propietario el 02-09 tras verificar EN VIVO GET /models (200, formato
    // OpenAI estándar) y POST /chat/completions con la clave del propietario (200,
    // «OK» de z-ai/glm-5.3-free). `is_free_tier = true`: el único modelo que
    // el token lista es `z-ai/glm-5.3-free`; si el propietario contrata modelos de
    // pago habrá que revisar esta marca (el bug abierto de `is_free` hereda
    // del proveedor).
    .{ .name = "TokenRouter", .base_url = "https://api.tokenrouter.com/v1", .api_style = .openai, .is_free_tier = true },
    // Fireworks AI: OpenAI-compatible puro, así que el descubrimiento genérico de
    // `/models` lo puebla solo — devuelve `{"data":[{"id":"accounts/fireworks/models/..."}]}`.
    // `is_free_tier = false` a propósito: es una API de pago, y como `is_free` se
    // hereda del proveedor (ver el bug abierto de `is_free`), marcarla gratis metería
    // todo su catálogo en el tramo «Solo gratis» sin serlo.
    .{ .name = "Fireworks AI", .base_url = "https://api.fireworks.ai/inference/v1", .api_style = .openai, .is_free_tier = false },
    // Ollama: servidor OpenAI-compatible en la máquina del usuario. La API
    // vive bajo `/v1` (chat/completions y models); el override
    // DEVAGENTS_OLLAMA_URL se normaliza a `…/v1` en effectiveBaseUrl.
    // `is_local` activa la política conservadora (sin clave, sin respaldos,
    // sin paralelismo de inferencias por defecto — ver ProviderConfig).
    .{ .name = "Ollama", .base_url = "http://127.0.0.1:11434/v1", .api_style = .openai, .is_free_tier = true, .is_local = true },
    .{ .name = "Tavily", .base_url = "https://api.tavily.com", .api_style = .web_search, .is_free_tier = false },
    .{ .name = "Brave Search", .base_url = "https://api.search.brave.com", .api_style = .web_search, .is_free_tier = false },
};

/// Crea un conector para un proveedor OpenAI-compatible.
pub fn createOpenAIConnector(
    allocator: std.mem.Allocator,
    http: *http_client.HttpClient,
    config: ProviderConfig,
    api_key: []const u8,
) !connector.Connector {
    const adapter = try openai.OpenAIAdapter.init(allocator, http, config.base_url, api_key, &.{}, false);
    return adapter.connectorInterface();
}

const GetEnvironmentVariableA = @import("platform.zig").env;

/// ¿El usuario activó una capacidad opt-in por variable de entorno?
/// Vale "1"/"true"/"yes"/"on" (sin distinción de mayúsculas). Es el mecanismo
/// de escape de la política local-conservadora: paralelismo de inferencias y
/// respaldos automáticos quedan apagados salvo opt-in explícito.
pub fn envFlagEnabled(comptime name: [*:0]const u8) bool {
    var buf: [16]u8 = undefined;
    const len = GetEnvironmentVariableA(name, &buf, buf.len);
    if (len == 0 or len >= buf.len) return false;
    const v = buf[0..len];
    return std.ascii.eqlIgnoreCase(v, "1") or
        std.ascii.eqlIgnoreCase(v, "true") or
        std.ascii.eqlIgnoreCase(v, "yes") or
        std.ascii.eqlIgnoreCase(v, "on");
}

/// ¿El nombre corresponde a un proveedor que corre en la máquina del usuario?
/// La clasificación vive en ALL_PROVIDERS (`is_local`); los proveedores dados
/// de alta por `da_provider_add` son siempre remotos.
pub fn isLocalProviderName(name: []const u8) bool {
    for (ALL_PROVIDERS) |p| {
        if (std.mem.eql(u8, p.name, name)) return p.is_local;
    }
    return false;
}

var ollama_url_buf: [512]u8 = undefined;
var ollama_url_len: usize = 0;
var ollama_url_ready = std.atomic.Value(bool).init(false);
/// `std.atomic.Mutex` de este Zig solo trae `tryLock`/`unlock` — la espera
/// activa la da lockOllamaUrl, igual que `lockSpin` en http/client.zig.
var ollama_url_mutex: std.atomic.Mutex = .unlocked;

fn lockOllamaUrl() void {
    while (!ollama_url_mutex.tryLock()) std.atomic.spinLoopHint();
}

/// Normaliza DEVAGENTS_OLLAMA_URL a `esquema://host[:puerto]/v1` — la API
/// OpenAI-compatible de Ollama vive bajo /v1. Acepta tanto la raíz del
/// servidor (`http://127.0.0.1:11434`, `127.0.0.1:11434`) como la raíz /v1
/// completa. Entrada ilegible o descabellada → default seguro.
fn resolveOllamaUrl(buf: *[512]u8) usize {
    const default_url = "http://127.0.0.1:11434/v1";
    var env_buf: [256]u8 = undefined;
    const len = GetEnvironmentVariableA("DEVAGENTS_OLLAMA_URL", &env_buf, env_buf.len);
    if (len == 0 or len >= env_buf.len) {
        @memcpy(buf[0..default_url.len], default_url);
        return default_url.len;
    }
    var url: []const u8 = std.mem.trim(u8, env_buf[0..len], " \t\r\n");
    url = std.mem.trimEnd(u8, url, "/");
    if (url.len == 0) {
        @memcpy(buf[0..default_url.len], default_url);
        return default_url.len;
    }
    var w: usize = 0;
    if (std.mem.indexOf(u8, url, "://") == null) {
        @memcpy(buf[w..][0..7], "http://");
        w += 7;
    }
    const needs_v1 = !std.mem.endsWith(u8, url, "/v1");
    if (w + url.len + @as(usize, if (needs_v1) 3 else 0) > buf.len) {
        @memcpy(buf[0..default_url.len], default_url);
        return default_url.len;
    }
    @memcpy(buf[w..][0..url.len], url);
    w += url.len;
    if (needs_v1) {
        @memcpy(buf[w..][0..3], "/v1");
        w += 3;
    }
    return w;
}

/// La base_url efectiva de un proveedor: la declarada, salvo override de
/// entorno. Hoy solo los proveedores locales la pisan (DEVAGENTS_OLLAMA_URL
/// para Ollama), resuelta UNA vez por proceso — la variable no cambia en
/// caliente y el buffer compartido devuelve siempre el mismo slice.
pub fn effectiveBaseUrl(cfg: ProviderConfig) []const u8 {
    if (!cfg.is_local) return cfg.base_url;
    // Resolución perezosa y una sola vez por proceso (la variable de entorno no
    // cambia en caliente). Después de la primera escritura el buffer es
    // inmutable y compartido — el slice devuelto nunca queda invalidado.
    if (!ollama_url_ready.load(.acquire)) {
        lockOllamaUrl();
        defer ollama_url_mutex.unlock();
        if (!ollama_url_ready.load(.acquire)) {
            ollama_url_len = resolveOllamaUrl(&ollama_url_buf);
            ollama_url_ready.store(true, .release);
        }
    }
    return ollama_url_buf[0..ollama_url_len];
}

/// Factory: crea el conector adecuado según el estilo de API del proveedor.
pub fn createConnector(
    allocator: std.mem.Allocator,
    http: *http_client.HttpClient,
    config: ProviderConfig,
    api_key: []const u8,
) !connector.Connector {
    switch (config.api_style) {
        .google_gemini => {
            const adapter = try gemini.GeminiAdapter.init(allocator, http, config.base_url, api_key);
            return adapter.connectorInterface();
        },
        .anthropic => {
            const adapter = try anthropic.AnthropicAdapter.init(allocator, http, config.base_url, api_key);
            return adapter.connectorInterface();
        },
        .openai, .nvidia_nim, .cloudflare, .cohere, .github_models, .opencode => {
            // Cohere: su Compatibility API documenta el rechazo de
            // `stream_options` — sin omitirlo toda llamada streaming muere
            // en un 400 (medido: workers programar caían en RequestFailed
            // con las dos claves mientras el sondeo V2 respondía ok).
            const adapter = try openai.OpenAIAdapter.init(allocator, http, config.base_url, api_key, &.{}, config.api_style == .cohere);
            return adapter.connectorInterface();
        },
        .web_search => return error.NotAnLlmProvider,
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

test "provider count is 26" {
    try std.testing.expectEqual(@as(usize, 26), ALL_PROVIDERS.len);
}

test "Ollama esta declarado como proveedor local OpenAI-compatible y gratis" {
    var found = false;
    for (ALL_PROVIDERS) |p| {
        if (!std.mem.eql(u8, p.name, "Ollama")) continue;
        found = true;
        // La API OpenAI-compatible de Ollama vive bajo /v1 en el puerto 11434.
        try std.testing.expectEqualStrings("http://127.0.0.1:11434/v1", p.base_url);
        try std.testing.expectEqual(ApiStyle.openai, p.api_style);
        try std.testing.expectEqual(WireProtocol.openai_compatible, try protocolForApiStyle(p.api_style));
        // Sin clave ni facturación: `is_local` activa la política conservadora
        // (modelo exacto, sin respaldos, sin paralelismo por defecto).
        try std.testing.expect(p.is_free_tier);
        try std.testing.expect(p.is_local);
    }
    try std.testing.expect(found);
}

test "isLocalProviderName solo reconoce a Ollama" {
    try std.testing.expect(isLocalProviderName("Ollama"));
    try std.testing.expect(!isLocalProviderName("GPT"));
    try std.testing.expect(!isLocalProviderName("NVIDIA API"));
    try std.testing.expect(!isLocalProviderName("no-existe"));
    try std.testing.expect(!isLocalProviderName("ollama")); // el nombre canónico es exacto
}

test "effectiveBaseUrl respeta la declarada y normaliza la de Ollama a /v1" {
    const remote = ProviderConfig{ .name = "X", .base_url = "https://x/v9", .api_style = .openai, .is_free_tier = true };
    try std.testing.expectEqualStrings("https://x/v9", effectiveBaseUrl(remote));
    const local = ProviderConfig{ .name = "Ollama", .base_url = "http://127.0.0.1:11434/v1", .api_style = .openai, .is_free_tier = true, .is_local = true };
    const url = effectiveBaseUrl(local);
    // Sin override o con él, el resultado siempre apunta a la API /v1.
    try std.testing.expect(std.mem.endsWith(u8, url, "/v1"));
    try std.testing.expect(std.mem.indexOf(u8, url, "://") != null);
}

test "resolveOllamaUrl normaliza raíz, /v1 y host sin esquema" {
    var buf: [512]u8 = undefined;
    // Sin variable de entorno en este proceso de tests → el default oficial.
    const n = resolveOllamaUrl(&buf);
    const url = buf[0..n];
    try std.testing.expect(std.mem.endsWith(u8, url, "/v1"));
    try std.testing.expect(std.mem.indexOf(u8, url, "://") != null);
}

test "envFlagEnabled es conservador: ausente apaga" {
    // Un nombre que no se exporta nunca: la llamada debe devolver false en
    // vez de leer basura del entorno.
    try std.testing.expect(!envFlagEnabled("DEVAGENTS_NOMBRE_QUE_NO_EXISTE"));
}

test "Fireworks AI esta declarado como OpenAI-compatible y de pago" {
    var found = false;
    for (ALL_PROVIDERS) |p| {
        if (!std.mem.eql(u8, p.name, "Fireworks AI")) continue;
        found = true;
        // El endpoint de chat documentado es .../inference/v1/chat/completions,
        // asi que la base es .../inference/v1 y el descubrimiento pega /models.
        try std.testing.expectEqualStrings("https://api.fireworks.ai/inference/v1", p.base_url);
        try std.testing.expectEqual(ApiStyle.openai, p.api_style);
        // De pago: `is_free` se hereda del proveedor, y marcarla gratis colaria
        // todo su catalogo en el tramo «Solo gratis».
        try std.testing.expect(!p.is_free_tier);
        try std.testing.expectEqual(WireProtocol.openai_compatible, try protocolForApiStyle(p.api_style));
    }
    try std.testing.expect(found);
}

test "TokenRouter esta declarado como OpenAI-compatible con la URL del dueno" {
    var found = false;
    for (ALL_PROVIDERS) |p| {
        if (!std.mem.eql(u8, p.name, "TokenRouter")) continue;
        found = true;
        // URL verificada EN VIVO el 02-09: GET /models 200 (formato OpenAI),
        // chat/completions 200 con z-ai/glm-5.3-free usando la clave del dueno.
        try std.testing.expectEqualStrings("https://api.tokenrouter.com/v1", p.base_url);
        try std.testing.expectEqual(ApiStyle.openai, p.api_style);
        try std.testing.expectEqual(WireProtocol.openai_compatible, try protocolForApiStyle(p.api_style));
        // El unico modelo que el token lista es z-ai/glm-5.3-free; si esa
        // marca cambia, revisar is_free_tier (se hereda a todo el catalogo).
        try std.testing.expect(p.is_free_tier);
    }
    try std.testing.expect(found);
}

test "all providers have names and base urls" {
    for (ALL_PROVIDERS) |p| {
        try std.testing.expect(p.name.len > 0);
        try std.testing.expect(p.base_url.len > 0);
    }
}

test "factory builds a connector for every LLM provider without leaking" {
    const allocator = std.testing.allocator;
    var http = try http_client.HttpClient.init(allocator);
    defer http.deinit();
    for (ALL_PROVIDERS) |p| {
        if (p.api_style == .web_search) continue;
        const conn = try createConnector(allocator, &http, p, "dummy-key");
        conn.deinit();
    }
}

test "factory selects Gemini adapter for google_gemini style" {
    const allocator = std.testing.allocator;
    var http = try http_client.HttpClient.init(allocator);
    defer http.deinit();
    const cfg = ProviderConfig{ .name = "Google AI Studio", .base_url = "https://generativelanguage.googleapis.com/v1beta", .api_style = .google_gemini, .is_free_tier = true };
    const conn = try createConnector(allocator, &http, cfg, "dummy-key");
    defer conn.deinit();
    // El adaptador Gemini produce un cuerpo distinto (contents/parts) — verificado en gemini.zig.
}

test "protocolForApiStyle maps LLM wire formats and rejects web search" {
    try std.testing.expectEqual(@import("connector_v2.zig").WireProtocol.openai_compatible, try protocolForApiStyle(.openai));
    try std.testing.expectEqual(@import("connector_v2.zig").WireProtocol.openai_compatible, try protocolForApiStyle(.opencode));
    try std.testing.expectEqual(@import("connector_v2.zig").WireProtocol.anthropic, try protocolForApiStyle(.anthropic));
    try std.testing.expectEqual(@import("connector_v2.zig").WireProtocol.gemini, try protocolForApiStyle(.google_gemini));
    try std.testing.expectError(error.NotAnLlmProvider, protocolForApiStyle(.web_search));
}

test "E5.24 factory selects actual Anthropic transport and propagates allocation errors" {
    const a = std.testing.allocator;
    var http = try http_client.HttpClient.init(a);
    defer http.deinit();
    const config = ProviderConfig{ .name = "Claude", .base_url = "https://api.anthropic.com/v1", .api_style = .anthropic, .is_free_tier = false };
    const actual = try createConnector(a, &http, config, "fixture-key");
    defer actual.deinit();
    const expected_adapter = try anthropic.AnthropicAdapter.init(a, &http, config.base_url, "fixture-key");
    defer expected_adapter.deinit();
    const expected = expected_adapter.connectorInterface();
    try std.testing.expect(actual.vtable.chat == expected.vtable.chat);
    try std.testing.expect(actual.vtable.listModels == expected.vtable.listModels);
    try std.testing.expect(actual.vtable.destroy == expected.vtable.destroy);
    var empty: [0]u8 = .{};
    var failing = std.heap.FixedBufferAllocator.init(&empty);
    try std.testing.expectError(error.OutOfMemory, createConnector(failing.allocator(), &http, config, "fixture-key"));
}
