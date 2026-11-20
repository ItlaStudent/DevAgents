//! E5.15 — cliente de embeddings cloud con estilo por proveedor.
//!
//! Contratos soportados (catalog.api_style → Style):
//!   - "openai", "nvidia_nim", "cohere" → shape OpenAI `POST {base}/embeddings`
//!     con `{"model","input":[..],"encoding_format":"float"}`. Cohere lo sirve
//!     en su capa de compatibilidad (api.cohere.ai/compatibility/v1) y NVIDIA
//!     NIM es OpenAI-nativo — mismo constructor, mismo parseo index-aware.
//!   - "google_gemini" → `POST {base}/models/{model}:batchEmbedContents` con
//!     `{"requests":[{"content":{"parts":[{"text"}]}}]}` y auth `x-goog-api-key`.
//!
//! Solo se invoca cuando el usuario lo configuró y autorizó (settings
//! `embeddings_config` del catálogo). Si no hay configuración, la capa
//! semántica se reporta `unavailable`: NUNCA se suplanta con búsqueda léxica
//! renombrada como semántica.
//!
//! El status HTTP se traduce a errores tipados para que `retry_planner`
//! reintente solo lo transitorio (429) y `spend_budget`/gobernanza vean el
//! resto tal cual (auth, cuota, endpoint inexistente).

const std = @import("std");
const http_client = @import("http/client.zig");
const http = std.http;

pub const EmbedError = error{
    OutOfMemory,
    HttpFailed,
    BadResponse,
    /// 429 — techo transitorio: retry_planner lo reintenta con backoff.
    RateLimited,
    /// 401/403 — la clave no sirve (no es medición de capacidad ni transitorio).
    AuthFailed,
    /// 402 — cuota/pago agotado. Distinto de 429: no se reintenta.
    QuotaExhausted,
    /// 404 — el modelo no existe o no sirve embeddings en ese endpoint.
    NotFound,
};

pub const Style = enum {
    /// POST {base}/embeddings — shape OpenAI.
    openai,
    /// POST {base}/models/{model}:batchEmbedContents — shape Gemini.
    google_gemini,
};

/// api_style del catálogo → contrato de embeddings. null = el proveedor no
/// habla embeddings por ninguna de las rutas soportadas (honesto: la capa
/// semántica se reporta `unsupported_style`, nunca se finge).
pub fn styleForApi(api_style: []const u8) ?Style {
    if (std.mem.eql(u8, api_style, "google_gemini")) return .google_gemini;
    if (std.mem.eql(u8, api_style, "openai") or
        std.mem.eql(u8, api_style, "nvidia_nim") or
        std.mem.eql(u8, api_style, "cohere")) return .openai;
    return null;
}

fn statusToError(status: http.Status) EmbedError {
    return switch (status) {
        .too_many_requests => error.RateLimited,
        .unauthorized, .forbidden => error.AuthFailed,
        .payment_required => error.QuotaExhausted,
        .not_found => error.NotFound,
        else => error.HttpFailed,
    };
}

/// Embedding de `texts` en una sola llamada por lotes (OpenAI admite `input`
/// array; Gemini admite `requests[]` — ambos ahorran N-1 round trips).
/// `max_chars` trunca cada texto: los embeddings cobran por token y un chunk
/// de 40 líneas puede ser largo. Devuelve un vector por texto, en el MISMO
/// orden de entrada (OpenAI: respeta `index` del payload, no la posición en
/// `data`; Gemini devuelve en orden de la petición).
/// Sanea un texto para el wire JSON: reemplaza cada secuencia UTF-8 invalida
/// por '?'. Un byte roto en un trozo del repo (binario colado, truncado a
/// media secuencia) hace que el endpoint real responda 400 al LOTE entero —
/// observado en la pasada viva contra Cohere. Un texto que queda sin señal
/// se convierte en "?" para conservar la correspondencia 1:1 input↔vector.
pub fn sanitizeForWire(allocator: std.mem.Allocator, text: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(text) and std.mem.trim(u8, text, " \t\r\n").len > 0)
        return text;
    var out = try std.ArrayList(u8).initCapacity(allocator, text.len);
    var i: usize = 0;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            try out.append(allocator, '?');
            i += 1;
            continue;
        };
        if (i + n > text.len or !std.unicode.utf8ValidateSlice(text[i..][0..n])) {
            try out.append(allocator, '?');
            i += 1;
            continue;
        }
        try out.appendSlice(allocator, text[i..][0..n]);
        i += n;
    }
    const clean = out.items;
    return if (std.mem.trim(u8, clean, " \t\r\n").len == 0) "?" else clean;
}

pub fn embedTexts(
    allocator: std.mem.Allocator,
    client: *http_client.HttpClient,
    style: Style,
    base_url: []const u8,
    api_key: ?[]const u8,
    model: []const u8,
    texts: []const []const u8,
    max_chars: usize,
) EmbedError![][]f32 {
    if (texts.len == 0) return try allocator.alloc([]f32, 0);
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();

    // Truncar puede cortar una secuencia UTF-8 por la mitad y un chunk crudo
    // puede traer bytes rotos: se sanea UNA vez aquí — el boundary del wire —
    // para consulta, pool live y lotes del indexador por igual.
    const clean = try allocator.alloc([]const u8, texts.len);
    defer allocator.free(clean);
    for (texts, 0..) |t, i|
        clean[i] = try sanitizeForWire(allocator, t[0..@min(t.len, max_chars)]);

    const base = std.mem.trimEnd(u8, base_url, "/");
    var headers_buf: [3]http.Header = undefined;
    var headers_len: usize = 0;
    headers_buf[headers_len] = .{ .name = "content-type", .value = "application/json" };
    headers_len += 1;
    var auth_alloc: ?[]u8 = null;
    defer if (auth_alloc) |b| allocator.free(b);
    var url: []u8 = undefined;

    switch (style) {
        .openai => {
            var js: std.json.Stringify = .{ .writer = &body.writer, .options = .{} };
            js.beginObject() catch return error.OutOfMemory;
            js.objectField("model") catch return error.OutOfMemory;
            js.write(model) catch return error.OutOfMemory;
            js.objectField("input") catch return error.OutOfMemory;
            js.beginArray() catch return error.OutOfMemory;
            for (clean) |t| js.write(t) catch return error.OutOfMemory;
            js.endArray() catch return error.OutOfMemory;
            js.objectField("encoding_format") catch return error.OutOfMemory;
            js.write("float") catch return error.OutOfMemory;
            js.endObject() catch return error.OutOfMemory;
            url = try std.fmt.allocPrint(allocator, "{s}/embeddings", .{base});
            if (api_key) |key| {
                auth_alloc = try std.fmt.allocPrint(allocator, "Bearer {s}", .{key});
                headers_buf[headers_len] = .{ .name = "authorization", .value = auth_alloc.? };
                headers_len += 1;
            }
        },
        .google_gemini => {
            const bare = if (std.mem.startsWith(u8, model, "models/")) model[7..] else model;
            const full_model = try std.fmt.allocPrint(allocator, "models/{s}", .{bare});
            defer allocator.free(full_model);
            var js: std.json.Stringify = .{ .writer = &body.writer, .options = .{} };
            js.beginObject() catch return error.OutOfMemory;
            js.objectField("requests") catch return error.OutOfMemory;
            js.beginArray() catch return error.OutOfMemory;
            for (clean) |t| {
                js.beginObject() catch return error.OutOfMemory;
                js.objectField("model") catch return error.OutOfMemory;
                js.write(full_model) catch return error.OutOfMemory;
                js.objectField("content") catch return error.OutOfMemory;
                js.beginObject() catch return error.OutOfMemory;
                js.objectField("parts") catch return error.OutOfMemory;
                js.beginArray() catch return error.OutOfMemory;
                js.beginObject() catch return error.OutOfMemory;
                js.objectField("text") catch return error.OutOfMemory;
                js.write(t) catch return error.OutOfMemory;
                js.endObject() catch return error.OutOfMemory;
                js.endArray() catch return error.OutOfMemory;
                js.endObject() catch return error.OutOfMemory;
                js.endObject() catch return error.OutOfMemory;
            }
            js.endArray() catch return error.OutOfMemory;
            js.endObject() catch return error.OutOfMemory;
            url = try std.fmt.allocPrint(allocator, "{s}/models/{s}:batchEmbedContents", .{ base, bare });
            if (api_key) |key| {
                headers_buf[headers_len] = .{ .name = "x-goog-api-key", .value = key };
                headers_len += 1;
            }
        },
    }
    defer allocator.free(url);

    const resp = client.postJsonWithHeaders(url, body.written(), headers_buf[0..headers_len]) catch
        return error.HttpFailed;
    defer allocator.free(resp.body);
    const code = @intFromEnum(resp.status);
    if (code < 200 or code >= 300) return statusToError(resp.status);
    return switch (style) {
        .openai => parseEmbeddings(allocator, resp.body, texts.len),
        .google_gemini => parseGeminiEmbeddings(allocator, resp.body, texts.len),
    };
}

/// `{"data":[{"index":i,"embedding":[f32,…]},…]}` → vecs[i]. Todos los
/// vectores deben tener la misma dimensión; si falta algún índice o las
/// dimensiones difieren → BadResponse (un rerank con vectores truncados
/// sería mentira silenciosa).
fn parseEmbeddings(allocator: std.mem.Allocator, json_str: []const u8, n_inputs: usize) EmbedError![][]f32 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return error.BadResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadResponse;
    const data_v = parsed.value.object.get("data") orelse return error.BadResponse;
    if (data_v != .array) return error.BadResponse;

    const vecs = try allocator.alloc([]f32, n_inputs);
    var filled = try allocator.alloc(bool, n_inputs);
    defer allocator.free(filled);
    @memset(filled, false);
    errdefer {
        for (vecs, 0..) |v, i| {
            if (filled[i]) allocator.free(v);
        }
        allocator.free(vecs);
    }

    var dim: usize = 0;
    for (data_v.array.items) |item| {
        if (item != .object) continue;
        const idx_v = item.object.get("index") orelse continue;
        const emb_v = item.object.get("embedding") orelse continue;
        if (idx_v != .integer or emb_v != .array) continue;
        const idx: usize = @intCast(idx_v.integer);
        if (idx >= n_inputs or filled[idx]) continue;
        const v = try allocVec(allocator, emb_v.array.items);
        if (dim == 0) dim = v.len;
        if (v.len != dim) {
            allocator.free(v);
            return error.BadResponse;
        }
        vecs[idx] = v;
        filled[idx] = true;
    }
    for (filled) |f| {
        if (!f) return error.BadResponse;
    }
    return vecs;
}

/// Gemini `{"embeddings":[{"values":[f32,…]},…]}` → vecs[i]. Sin campo
/// `index`: el orden de `embeddings` es el orden de `requests`. Misma
/// disciplina de dimensiones que el parseo OpenAI.
fn parseGeminiEmbeddings(allocator: std.mem.Allocator, json_str: []const u8, n_inputs: usize) EmbedError![][]f32 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch
        return error.BadResponse;
    defer parsed.deinit();
    if (parsed.value != .object) return error.BadResponse;
    const embs_v = parsed.value.object.get("embeddings") orelse return error.BadResponse;
    if (embs_v != .array or embs_v.array.items.len != n_inputs) return error.BadResponse;

    const vecs = try allocator.alloc([]f32, n_inputs);
    var filled = try allocator.alloc(bool, n_inputs);
    defer allocator.free(filled);
    @memset(filled, false);
    errdefer {
        for (vecs, 0..) |v, i| {
            if (filled[i]) allocator.free(v);
        }
        allocator.free(vecs);
    }

    var dim: usize = 0;
    for (embs_v.array.items, 0..) |item, i| {
        if (item != .object) continue;
        const vals_v = item.object.get("values") orelse continue;
        if (vals_v != .array) continue;
        const v = try allocVec(allocator, vals_v.array.items);
        if (dim == 0) dim = v.len;
        if (v.len != dim) {
            allocator.free(v);
            return error.BadResponse;
        }
        vecs[i] = v;
        filled[i] = true;
    }
    for (filled) |f| {
        if (!f) return error.BadResponse;
    }
    return vecs;
}

fn allocVec(allocator: std.mem.Allocator, items: []const std.json.Value) ![]f32 {
    const v = try allocator.alloc(f32, items.len);
    for (items, 0..) |num, k| {
        v[k] = switch (num) {
            .float => |f| @floatCast(f),
            .integer => |n| @floatFromInt(n),
            else => 0,
        };
    }
    return v;
}

/// Coseno a·b/(|a||b|) en [-1,1]; 0 si alguna norma es 0 o las dims difieren
/// (nunca NaN hacia el ranking).
pub fn cosine(a: []const f32, b: []const f32) f32 {
    if (a.len == 0 or a.len != b.len) return 0;
    var dot: f64 = 0;
    var na: f64 = 0;
    var nb: f64 = 0;
    for (a, b) |x, y| {
        dot += @as(f64, x) * @as(f64, y);
        na += @as(f64, x) * @as(f64, x);
        nb += @as(f64, y) * @as(f64, y);
    }
    if (na == 0 or nb == 0) return 0;
    return @floatCast(dot / (@sqrt(na) * @sqrt(nb)));
}

// ── Tests (sin red: parse + coseno + builders) ───────────────────────────

test "E5.15 parseEmbeddings: vectores por indice, orden de entrada" {
    const fixture =
        \\{"data":[
        \\  {"index":1,"embedding":[0.0,1.0]},
        \\  {"index":0,"embedding":[1.0,0.0]}
        \\],"model":"m","usage":{"total_tokens":4}}
    ;
    const vecs = try parseEmbeddings(std.testing.allocator, fixture, 2);
    defer {
        for (vecs) |v| std.testing.allocator.free(v);
        std.testing.allocator.free(vecs);
    }
    try std.testing.expectEqual(@as(usize, 2), vecs.len);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), vecs[0][0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), vecs[1][1], 0.0001);
}

test "E5.15 parseEmbeddings: indice faltante o dims mixtas -> BadResponse" {
    try std.testing.expectError(error.BadResponse, parseEmbeddings(std.testing.allocator, "{\"data\":[{\"index\":0,\"embedding\":[1]}]}", 2));
    try std.testing.expectError(error.BadResponse, parseEmbeddings(std.testing.allocator, "{\"data\":[{\"index\":0,\"embedding\":[1,2]},{\"index\":1,\"embedding\":[1]}]}", 2));
    try std.testing.expectError(error.BadResponse, parseEmbeddings(std.testing.allocator, "not json", 1));
}

test "E5.15 parseGeminiEmbeddings: orden de peticion y dims consistentes" {
    const fixture =
        \\{"embeddings":[
        \\  {"values":[0.5,0.5]},
        \\  {"values":[1.0,0.0]}
        \\]}
    ;
    const vecs = try parseGeminiEmbeddings(std.testing.allocator, fixture, 2);
    defer {
        for (vecs) |v| std.testing.allocator.free(v);
        std.testing.allocator.free(vecs);
    }
    try std.testing.expectApproxEqAbs(@as(f32, 0.5), vecs[0][0], 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), vecs[1][0], 0.0001);
    // Conteo distinto al de la petición o dims mixtas -> BadResponse.
    try std.testing.expectError(error.BadResponse, parseGeminiEmbeddings(std.testing.allocator, "{\"embeddings\":[{\"values\":[1]}]}", 2));
    try std.testing.expectError(error.BadResponse, parseGeminiEmbeddings(std.testing.allocator, "{\"embeddings\":[{\"values\":[1,2]},{\"values\":[1]}]}", 2));
}

test "E5.15 styleForApi: estilos del catalogo a contrato de embeddings" {
    try std.testing.expectEqual(Style.openai, styleForApi("openai").?);
    try std.testing.expectEqual(Style.openai, styleForApi("nvidia_nim").?);
    try std.testing.expectEqual(Style.openai, styleForApi("cohere").?);
    try std.testing.expectEqual(Style.google_gemini, styleForApi("google_gemini").?);
    try std.testing.expect(styleForApi("anthropic") == null);
    try std.testing.expect(styleForApi("web_search") == null);
}

test "E5.15 statusToError: 429 transitorio, resto tipado honesto" {
    try std.testing.expectEqual(error.RateLimited, statusToError(.too_many_requests));
    try std.testing.expectEqual(error.AuthFailed, statusToError(.unauthorized));
    try std.testing.expectEqual(error.AuthFailed, statusToError(.forbidden));
    try std.testing.expectEqual(error.QuotaExhausted, statusToError(.payment_required));
    try std.testing.expectEqual(error.NotFound, statusToError(.not_found));
    try std.testing.expectEqual(error.HttpFailed, statusToError(.internal_server_error));
}

test "E5.15 cosine: ortogonal 0, identico 1, dims distintas 0" {
    const a = [_]f32{ 1, 0 };
    const b = [_]f32{ 0, 1 };
    const c = [_]f32{ 1, 0 };
    try std.testing.expectApproxEqAbs(@as(f32, 0), cosine(&a, &b), 0.0001);
    try std.testing.expectApproxEqAbs(@as(f32, 1), cosine(&a, &c), 0.0001);
    const d = [_]f32{1};
    try std.testing.expectApproxEqAbs(@as(f32, 0), cosine(&a, &d), 0.0001);
}
