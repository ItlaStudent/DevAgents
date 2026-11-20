const std = @import("std");

/// Clasificador puro de errores HTTP de proveedor.
///
/// El status HTTP por si solo no basta: varios proveedores usan codigos
/// genericos para causas muy distintas. El caso medido es Gemini, que responde
/// 400 (no 401) cuando la API key es invalida. Por eso `classify` mira PRIMERO
/// el cuerpo (body-first) y solo cae al status cuando el cuerpo no aporta nada.
pub const ErrorMappingV2 = struct {
    /// Clasificacion pura por status. Se conserva por compatibilidad y como
    /// ultimo recurso de `classify`.
    pub fn classifyHttpStatus(status: u16) []const u8 {
        return switch (status) {
            401, 403 => "auth_error",
            429 => "rate_limit_error",
            404 => "model_not_found",
            500...599 => "provider_server_error",
            else => "unknown_error",
        };
    }

    /// Clasificacion body-first. `body` es el cuerpo de error del proveedor
    /// (fixture en texto; nunca se persiste, solo se inspecciona aqui).
    pub fn classify(status: u16, body: []const u8) []const u8 {
        // Gemini: la key invalida llega como 400 con reason API_KEY_INVALID
        // (o "API key not valid") — es un fallo de CREDENCIAL, no de peticion.
        if (containsIgnoreCase(body, "API_KEY_INVALID") or
            containsIgnoreCase(body, "api key not valid")) return "auth_error";
        // OpenAI/otros: cuota agotada y credito bajo son terminales de cuenta.
        if (containsIgnoreCase(body, "insufficient_quota") or
            containsIgnoreCase(body, "exceeded your current quota") or
            containsIgnoreCase(body, "low credit") or
            containsIgnoreCase(body, "credit balance is too low")) return "quota_error";
        return classifyHttpStatus(status);
    }
};

/// `Retry-After` en segundos enteros -> milisegundos, con tope duro.
///
/// Devuelve null si la cabecera no es un entero (p. ej. la forma HTTP-date, que
/// este conector no usa). Un valor enorme se acota a `cap_ms` para que una
/// cabecera hostil no pueda secuestrar el hilo con un sleep desmedido.
pub fn retryAfterMs(value: []const u8, cap_ms: u64) ?u64 {
    const trimmed = std.mem.trim(u8, value, " \t\r\n");
    if (trimmed.len == 0) return null;
    const seconds = std.fmt.parseInt(u64, trimmed, 10) catch |err| switch (err) {
        // Un entero que desborda u64 es, a efectos practicos, "enorme": se
        // acota al tope en vez de descartarse.
        error.Overflow => return cap_ms,
        error.InvalidCharacter => return null,
    };
    const ms = std.math.mul(u64, seconds, 1000) catch return cap_ms;
    return @min(ms, cap_ms);
}

/// Tope por defecto de una espera Retry-After: 30 s. Mas que eso se considera
/// mejor degradar al siguiente candidato que mantener el hilo dormido.
pub const MAX_RETRY_AFTER_MS: u64 = 30_000;

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

test "error mapping classify status" {
    try std.testing.expectEqualStrings("auth_error", ErrorMappingV2.classifyHttpStatus(401));
    try std.testing.expectEqualStrings("rate_limit_error", ErrorMappingV2.classifyHttpStatus(429));
}

test "CK-PRV-007 Q1: Gemini 400 API_KEY_INVALID se clasifica como auth_error" {
    // Fixture real de Gemini: HTTP 400 con reason API_KEY_INVALID.
    const gemini_body =
        \\{"error":{"code":400,"message":"API key not valid. Please pass a valid API key.","status":"INVALID_ARGUMENT","details":[{"@type":"type.googleapis.com/google.rpc.ErrorInfo","reason":"API_KEY_INVALID","domain":"googleapis.com","metadata":{"service":"generativelanguage.googleapis.com"}}]}}
    ;
    try std.testing.expectEqualStrings("auth_error", ErrorMappingV2.classify(400, gemini_body));
    // No se confunde con "empty" ni con un fallo transitorio de peticion.
    try std.testing.expect(!std.mem.eql(u8, "unknown_error", ErrorMappingV2.classify(400, gemini_body)));
    // Un 400 de verdad de parametros sigue siendo desconocido (control negativo).
    try std.testing.expectEqualStrings("unknown_error", ErrorMappingV2.classify(400, "{\"error\":{\"message\":\"Invalid JSON payload\"}}"));
}

test "CK-PRV-007 Q1: cuota agotada y credito bajo se clasifican como quota_error" {
    try std.testing.expectEqualStrings("quota_error", ErrorMappingV2.classify(400, "{\"error\":{\"code\":\"insufficient_quota\",\"message\":\"You exceeded your current quota\"}}"));
    try std.testing.expectEqualStrings("quota_error", ErrorMappingV2.classify(403, "Your credit balance is too low to access the Anthropic API"));
}

test "CK-PRV-007 Q2: Retry-After entero se convierte a ms y un valor enorme se acota" {
    try std.testing.expectEqual(@as(?u64, 2_000), retryAfterMs("2", MAX_RETRY_AFTER_MS));
    try std.testing.expectEqual(@as(?u64, 0), retryAfterMs("0", MAX_RETRY_AFTER_MS));
    try std.testing.expectEqual(@as(?u64, 60_000), retryAfterMs("60", 60_000));
    // Un retry-after desmedido (24 h) NO puede dormir el hilo mas alla del tope.
    try std.testing.expectEqual(@as(?u64, MAX_RETRY_AFTER_MS), retryAfterMs("86400", MAX_RETRY_AFTER_MS));
    // Desbordamiento aritmetico -> tope, nunca wrap ni panico.
    try std.testing.expectEqual(@as(?u64, MAX_RETRY_AFTER_MS), retryAfterMs("99999999999999999999", MAX_RETRY_AFTER_MS));
    // Forma HTTP-date no soportada: se descarta (no se inventa una espera).
    try std.testing.expectEqual(@as(?u64, null), retryAfterMs("Wed, 21 Oct 2026 07:28:00 GMT", MAX_RETRY_AFTER_MS));
    try std.testing.expectEqual(@as(?u64, null), retryAfterMs("", MAX_RETRY_AFTER_MS));
}
