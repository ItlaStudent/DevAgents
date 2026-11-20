const std = @import("std");
const connector = @import("connector.zig");
const connector_v2 = @import("connector_v2.zig");

pub const FinishReason = enum {
    stop,
    length,
    content_filter,
    tool_calls,
    other,
};

pub const StreamFailure = struct {
    kind: connector_v2.ErrorKind = .other,
    message: []const u8 = "",
    code: []const u8 = "",
};

pub const Event = union(enum) {
    content_delta: []const u8,
    reasoning_delta: []const u8,
    usage: struct { prompt_tokens: usize = 0, completion_tokens: usize = 0 },
    finish: FinishReason,
    failure: StreamFailure,
    tool_call_delta,
    tool_call,
    thought_signature,

    pub fn deinit(self: *const Event, allocator: std.mem.Allocator) void {
        switch (self.*) {
            .content_delta, .reasoning_delta => |d| allocator.free(d),
            .failure => |f| {
                if (f.message.len > 0) allocator.free(f.message);
                if (f.code.len > 0) allocator.free(f.code);
            },
            else => {},
        }
    }
};

/// (2026-09-01): este módulo era un STUB — `nextEvent` devolvía `null`
/// de inmediato y `fromConnector` devolvía un stream mudo. La única víctima
/// visible era el sondeo masivo (`callTimedDirectV2` en live_worker): el
/// modelo respondía content real (verificado contra el API crudo: 3 variantes
/// de body, todas con `content:"pong"`) y DevAgents lo clasificaba `.empty`
/// porque el normalizador no entregaba NADA. Ahora envuelve el `ChatStream`
/// V1 (el mismo que usa la ruta del CLI, probada en producción) y normaliza
/// cada chunk SSE a Event.
pub const NormalizedStream = struct {
    allocator: std.mem.Allocator,
    /// POSEÍDO por valor: el caller mueve el ChatStream aquí (conn.chat lo
    /// devuelve por valor) y YA NO lo toca — el deinit de esta struct es el
    /// único propietario. Evita el patrón de puntero compartido del stub original.
    stream: connector.ChatStream,

    pub fn nextEvent(self: *NormalizedStream) !?Event {
        while (true) {
            const maybe_chunk = self.stream.nextChunk() catch |err| {
                return try self.failureFromError(err);
            };
            var chunk = maybe_chunk orelse return null; // EOF limpio
            defer chunk.deinit();
            // El delta de nextChunk es el JSON crudo del SSE — mismo input
            // que la ruta V1 manda a appendChunkToBuffer.
            const ev = normalizeChunk(self.allocator, chunk.delta) catch {
                // Un fallo de alloc normalizando un chunk es OOM: no se
                // traga (sería un evento perdido en silencio) — sube.
                return error.OutOfMemory;
            };
            if (ev) |e| return e;
            // Chunk sin nada interesante (p. ej. solo role) → siguiente.
        }
    }

    fn failureFromError(self: *NormalizedStream, err: anyerror) !?Event {
        const kind: connector_v2.ErrorKind = switch (err) {
            error.AuthFailed => .auth,
            error.QuotaExceeded => .quota,
            error.RateLimited => .rate_limited,
            error.ModelNotFound => .model_not_found,
            error.ProviderError => .provider_error,
            error.SseParseFailed => .parse_error,
            error.Timeout, error.ResponseFailed => .timeout,
            else => .other,
        };
        _ = self;
        return .{ .failure = .{ .kind = kind } };
    }

    pub fn deinit(self: *NormalizedStream) void {
        self.stream.deinit();
    }
};

pub fn fromConnector(allocator: std.mem.Allocator, proto: anytype, stream: anytype) !NormalizedStream {
    // Los tres formatos de chunk que llegan por ChatStream ya están cubiertos
    // por normalizeChunk (OpenAI delta, Gemini candidates, Anthropic
    // text_delta — mismos parses que printChunkContent del CLI, la ruta
    // probada desde FASE-2). El protocolo se valida por tipos; los estilos
    // web_search nunca llegan aquí porque protocolForApiStyle los rechaza
    // antes. El stream se MUEVE: ownership único desde este punto.
    if (@TypeOf(proto) != connector_v2.WireProtocol) {
        @compileError("fromConnector: proto debe ser WireProtocol");
    }
    if (@TypeOf(stream) != connector.ChatStream) {
        @compileError("fromConnector: stream debe ser connector.ChatStream por valor");
    }
    return .{ .allocator = allocator, .stream = stream };
}

/// Normaliza un chunk SSE OpenAI a Event. Devuelve:
///   - null si el chunk no aporta nada que el caller consuma (role puro,
///     usage vacío, tool plumbing), para que nextEvent siga al siguiente;
///   - Event con slices DUPEADOS en allocator (caller libera con deinit).
///   - error de alloc como error (el caller lo convierte en failure).
fn normalizeChunk(allocator: std.mem.Allocator, chunk_json: []const u8) !?Event {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, chunk_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const obj = parsed.value.object;

    // SSE de error del proveedor: {"error":{...}} — se entrega como failure
    // con el mensaje real, no como silencio.
    if (obj.get("error")) |e| {
        if (e == .object) {
            var msg: []const u8 = "";
            var code: []const u8 = "";
            if (e.object.get("message")) |m| {
                if (m == .string) msg = m.string;
            }
            if (e.object.get("code")) |c| {
                if (c == .string) code = c.string;
            }
            const kind = errorKindFromCode(code);
            return .{ .failure = .{
                .kind = kind,
                .message = try allocator.dupe(u8, msg),
                .code = try allocator.dupe(u8, code),
            } };
        }
    }

    // usage (último chunk con stream_options.include_usage)
    if (obj.get("usage")) |u| {
        if (u == .object) {
            var pt: usize = 0;
            var ct: usize = 0;
            if (u.object.get("prompt_tokens")) |v| {
                if (v == .integer) pt = @intCast(v.integer);
            }
            if (u.object.get("completion_tokens")) |v| {
                if (v == .integer) ct = @intCast(v.integer);
            }
            if (pt == 0 and ct == 0) return null;
            return .{ .usage = .{ .prompt_tokens = pt, .completion_tokens = ct } };
        }
    }

    if (obj.get("choices")) |choices| {
        if (choices != .array or choices.array.items.len == 0) return null;
        const first = choices.array.items[0];
        if (first != .object) return null;
        const c = first.object;

        if (c.get("finish_reason")) |fr| {
            if (fr == .string and fr.string.len > 0) {
                return .{ .finish = finishFromReason(fr.string) };
            }
        }

        if (c.get("delta")) |delta| {
            if (delta != .object) return null;
            const d = delta.object;
            // content primero: si un chunk trae AMBOS, content es la
            // respuesta real y reasoning la traza (nunca al revés).
            if (d.get("content")) |cont| {
                if (cont == .string and cont.string.len > 0) {
                    return .{ .content_delta = try allocator.dupe(u8, cont.string) };
                }
            }
            // reasoning_content (el agente/OpenCode) y reasoning (OpenRouter)
            if (d.get("reasoning_content")) |r| {
                if (r == .string and r.string.len > 0) {
                    return .{ .reasoning_delta = try allocator.dupe(u8, r.string) };
                }
            }
            if (d.get("reasoning")) |r| {
                if (r == .string and r.string.len > 0) {
                    return .{ .reasoning_delta = try allocator.dupe(u8, r.string) };
                }
            }
            return null; // role puro / content null
        }
        return null;
    }

    // Gemini: candidates[0].content.parts[*].text (mismo parse que
    // printChunkContent del CLI — la ruta V1 probada en producción).
    if (obj.get("candidates")) |cands| {
        if (cands != .array or cands.array.items.len == 0) return null;
        const first = cands.array.items[0];
        if (first != .object) return null;
        const cand = first.object;
        if (cand.get("content")) |gc| {
            if (gc == .object) {
                if (gc.object.get("parts")) |parts| {
                    if (parts != .array) return null;
                    for (parts.array.items) |p| {
                        if (p != .object) continue;
                        if (p.object.get("text")) |txt| {
                            if (txt == .string and txt.string.len > 0) {
                                return .{ .content_delta = try allocator.dupe(u8, txt.string) };
                            }
                        }
                    }
                }
            }
        }
        if (cand.get("finishReason")) |fr| {
            if (fr == .string and fr.string.len > 0) {
                return .{ .finish = finishFromReason(fr.string) };
            }
        }
        return null;
    }

    // Anthropic: {type:"content_block_delta", delta:{type:"text_delta", text}}
    // y {type:"message_delta", delta:{stop_reason:"end_turn"}}.
    if (obj.get("delta")) |delta| {
        if (delta == .object) {
            const d = delta.object;
            if (d.get("text")) |text| {
                if (text == .string and text.string.len > 0) {
                    return .{ .content_delta = try allocator.dupe(u8, text.string) };
                }
            }
            if (d.get("stop_reason")) |sr| {
                if (sr == .string and sr.string.len > 0) {
                    return .{ .finish = finishFromReason(sr.string) };
                }
            }
        }
        return null;
    }
    return null;
}

fn finishFromReason(reason: []const u8) FinishReason {
    if (std.mem.eql(u8, reason, "stop")) return .stop;
    if (std.mem.eql(u8, reason, "length")) return .length;
    if (std.mem.eql(u8, reason, "content_filter")) return .content_filter;
    if (std.mem.eql(u8, reason, "tool_calls")) return .tool_calls;
    // Anthropic stop_reason (mismo mapeo que connector.zig extractFinishReason)
    if (std.mem.eql(u8, reason, "end_turn")) return .stop;
    if (std.mem.eql(u8, reason, "stop_sequence")) return .stop;
    if (std.mem.eql(u8, reason, "max_tokens")) return .length;
    // Gemini finishReason (MAL/SAFETY son filtros; STOP es el normal)
    if (std.mem.eql(u8, reason, "STOP")) return .stop;
    if (std.mem.eql(u8, reason, "MAX_TOKENS")) return .length;
    if (std.mem.eql(u8, reason, "SAFETY") or std.mem.eql(u8, reason, "MAL")) return .content_filter;
    return .other;
}

fn errorKindFromCode(code: []const u8) connector_v2.ErrorKind {
    // Mapeo conservador: códigos que el motor ya sabe clasificar por
    // HTTP en connector_v2; aquí solo se distinguen los evidentes.
    if (std.mem.indexOf(u8, code, "auth") != null) return .auth;
    if (std.mem.indexOf(u8, code, "quota") != null) return .quota;
    if (std.mem.indexOf(u8, code, "rate") != null) return .rate_limited;
    if (std.mem.indexOf(u8, code, "not_found") != null) return .model_not_found;
    return .other;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "normalizeChunk: content_delta con dupe" {
    const allocator = std.testing.allocator;
    const ev = (try normalizeChunk(allocator, "{\"choices\":[{\"delta\":{\"content\":\"pong\"}}]}")).?;
    defer ev.deinit(allocator);
    try std.testing.expectEqualStrings("pong", ev.content_delta);
}

test "normalizeChunk: reasoning_content y reasoning, ambos soportados" {
    const allocator = std.testing.allocator;
    const ev1 = (try normalizeChunk(allocator, "{\"choices\":[{\"delta\":{\"reasoning_content\":\"pienso\"}}]}")).?;
    defer ev1.deinit(allocator);
    try std.testing.expectEqualStrings("pienso", ev1.reasoning_delta);
    const ev2 = (try normalizeChunk(allocator, "{\"choices\":[{\"delta\":{\"reasoning\":\"pienso2\"}}]}")).?;
    defer ev2.deinit(allocator);
    try std.testing.expectEqualStrings("pienso2", ev2.reasoning_delta);
}

test "normalizeChunk: content gana sobre reasoning en el mismo chunk" {
    const allocator = std.testing.allocator;
    const ev = (try normalizeChunk(allocator, "{\"choices\":[{\"delta\":{\"content\":\"resp\",\"reasoning_content\":\"x\"}}]}")).?;
    defer ev.deinit(allocator);
    try std.testing.expect(ev == .content_delta);
}

test "normalizeChunk: finish se mapea a enum" {
    const allocator = std.testing.allocator;
    const ev = (try normalizeChunk(allocator, "{\"choices\":[{\"finish_reason\":\"length\"}]}")).?;
    try std.testing.expect(ev == .finish);
    try std.testing.expectEqual(FinishReason.length, ev.finish);
    const ev2 = (try normalizeChunk(allocator, "{\"choices\":[{\"finish_reason\":\"stop\"}]}")).?;
    try std.testing.expectEqual(FinishReason.stop, ev2.finish);
}

test "normalizeChunk: usage del chunk final" {
    const allocator = std.testing.allocator;
    const ev = (try normalizeChunk(allocator, "{\"usage\":{\"prompt_tokens\":17,\"completion_tokens\":154}}")).?;
    try std.testing.expect(ev == .usage);
    try std.testing.expectEqual(@as(usize, 17), ev.usage.prompt_tokens);
    try std.testing.expectEqual(@as(usize, 154), ev.usage.completion_tokens);
}

test "normalizeChunk: chunk con content null no emite nada" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(?Event, null), try normalizeChunk(allocator, "{\"choices\":[{\"delta\":{\"role\":\"assistant\",\"content\":null}}]}"));
}

test "normalizeChunk: error del proveedor se entrega como failure" {
    const allocator = std.testing.allocator;
    const ev = (try normalizeChunk(allocator, "{\"error\":{\"message\":\"no access\",\"code\":\"auth_xyz\"}}")).?;
    defer ev.deinit(allocator);
    try std.testing.expect(ev == .failure);
    try std.testing.expectEqualStrings("no access", ev.failure.message);
    try std.testing.expectEqual(connector_v2.ErrorKind.auth, ev.failure.kind);
}

test "normalizeChunk: json basura se ignora sin tumbar el stream" {
    const allocator = std.testing.allocator;
    try std.testing.expectEqual(@as(?Event, null), try normalizeChunk(allocator, "no-json"));
}

test "normalizeChunk: Gemini candidates text" {
    const allocator = std.testing.allocator;
    const ev = (try normalizeChunk(allocator, "{\"candidates\":[{\"content\":{\"parts\":[{\"text\":\"hola\"}]}}]}")).?;
    defer ev.deinit(allocator);
    try std.testing.expectEqualStrings("hola", ev.content_delta);
}

test "normalizeChunk: Gemini finishReason MAX_TOKENS mapea a length" {
    const allocator = std.testing.allocator;
    const ev = (try normalizeChunk(allocator, "{\"candidates\":[{\"finishReason\":\"MAX_TOKENS\"}]}")).?;
    try std.testing.expectEqual(FinishReason.length, ev.finish);
}

test "normalizeChunk: Anthropic text_delta" {
    const allocator = std.testing.allocator;
    const ev = (try normalizeChunk(allocator, "{\"type\":\"content_block_delta\",\"delta\":{\"type\":\"text_delta\",\"text\":\"mundo\"}}")).?;
    defer ev.deinit(allocator);
    try std.testing.expectEqualStrings("mundo", ev.content_delta);
}

test "normalizeChunk: Anthropic end_turn mapea a stop" {
    const allocator = std.testing.allocator;
    const ev = (try normalizeChunk(allocator, "{\"type\":\"message_delta\",\"delta\":{\"stop_reason\":\"end_turn\"}}")).?;
    try std.testing.expectEqual(FinishReason.stop, ev.finish);
}

test "normalizeChunk: sin leaks con mensajes vacios en failure" {
    const allocator = std.testing.allocator;
    const ev = (try normalizeChunk(allocator, "{\"error\":{}}")).?;
    defer ev.deinit(allocator);
    try std.testing.expect(ev == .failure);
    try std.testing.expectEqualStrings("", ev.failure.message);
}
