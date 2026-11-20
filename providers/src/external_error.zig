//! Bounded, untrusted diagnostics. Never retain a raw HTTP/CLI payload.
const std = @import("std");

/// 10-nov (USUARIO-NUEVO A6): lo que el proveedor dice sobre cuándo volver a
/// intentar tras un 429. Cabeceras estándar (`Retry-After`) y de cuota
/// (`X-RateLimit-Reset`, `X-RateLimit-Remaining`), también cuando OpenRouter
/// las reenvía dentro del cuerpo (`error.metadata.headers`). Solo números: el
/// texto del proveedor va por `excerpt`, que lo censura.
pub const RateHints = struct {
    /// `Retry-After` en segundos, convertido a ms (una fecha HTTP no se usa).
    retry_after_ms: ?u64 = null,
    /// `X-RateLimit-Reset` absoluto (epoch, normalizado a ms).
    reset_epoch_ms: ?u64 = null,
    /// `X-RateLimit-Reset` relativo (segundos desde ahora, normalizado a ms).
    reset_in_ms: ?u64 = null,
    remaining: ?u64 = null,
    /// El mensaje del proveedor habla de un límite diario («per-day»): no
    /// tiene sentido reintentar en segundos.
    daily: bool = false,

    pub fn note(self: *RateHints, name: []const u8, value: []const u8) void {
        const v = std.mem.trim(u8, value, " \t\"");
        const n = std.fmt.parseInt(u64, v, 10) catch return;
        if (std.ascii.eqlIgnoreCase(name, "retry-after")) {
            self.retry_after_ms = std.math.mul(u64, n, 1000) catch null;
        } else if (std.ascii.eqlIgnoreCase(name, "x-ratelimit-reset") or std.ascii.eqlIgnoreCase(name, "x-ratelimit-reset-requests")) {
            // 13 cifras = epoch en ms (OpenRouter); 10 = epoch en s; menos =
            // segundos desde ahora.
            if (v.len >= 13) self.reset_epoch_ms = n else if (v.len >= 10) self.reset_epoch_ms = std.math.mul(u64, n, 1000) catch null else self.reset_in_ms = std.math.mul(u64, n, 1000) catch null;
        } else if (std.ascii.eqlIgnoreCase(name, "x-ratelimit-remaining") or std.ascii.eqlIgnoreCase(name, "x-ratelimit-remaining-requests")) {
            self.remaining = n;
        }
    }

    /// Cabeceras explícitas ganan a lo deducido del cuerpo.
    pub fn merge(self: *RateHints, headers: RateHints) void {
        if (headers.retry_after_ms) |v| self.retry_after_ms = v;
        if (headers.reset_epoch_ms) |v| self.reset_epoch_ms = v;
        if (headers.reset_in_ms) |v| self.reset_in_ms = v;
        if (headers.remaining) |v| self.remaining = v;
        self.daily = self.daily or headers.daily;
    }

    /// Espera que pide el proveedor, en ms, vista desde `now_ms` (epoch).
    pub fn waitMs(self: RateHints, now_ms: u64) ?u64 {
        if (self.retry_after_ms) |v| return v;
        if (self.reset_in_ms) |v| return v;
        if (self.reset_epoch_ms) |v| return if (v > now_ms) v - now_ms else 0;
        return null;
    }

    /// Lee del cuerpo JSON del error, sin asignar memoria, los números de
    /// `X-RateLimit-*` que OpenRouter reenvía y si el límite es diario.
    pub fn fromBody(raw: []const u8) RateHints {
        var hints = RateHints{};
        for ([_][]const u8{ "X-RateLimit-Reset", "X-RateLimit-Remaining", "Retry-After" }) |name| {
            if (bodyNumber(raw, name)) |value| hints.note(name, value);
        }
        for ([_][]const u8{ "per-day", "per day", "daily", "per_day" }) |word| {
            if (std.ascii.indexOfIgnoreCase(raw, word) != null) hints.daily = true;
        }
        return hints;
    }
};

/// `"Name":"123"` o `"Name":123` dentro de un cuerpo, sin interpretar JSON.
fn bodyNumber(raw: []const u8, name: []const u8) ?[]const u8 {
    var from: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(raw, from, name)) |at| : (from = at + name.len) {
        if (at == 0 or raw[at - 1] != '"') continue;
        var i = at + name.len;
        if (i >= raw.len or raw[i] != '"') continue;
        i += 1;
        while (i < raw.len and (raw[i] == ' ' or raw[i] == ':' or raw[i] == '"')) : (i += 1) {}
        const start = i;
        while (i < raw.len and std.ascii.isDigit(raw[i]) and i - start < 20) : (i += 1) {}
        if (i > start) return raw[start..i];
    }
    return null;
}

/// El texto de `"message":"…"` del cuerpo (primera aparición), sin escapes.
/// null si no hay o si lleva escapes (ambiguos: se censura el cuerpo entero).
pub fn bodyMessage(raw: []const u8) ?[]const u8 {
    const message = bodyString(raw, "\"message\"") orelse return null;
    // 10-nov (A6, medido en vivo): ante un 429 de un modelo `:free`, OpenRouter
    // responde «Provider returned error» y deja el motivo real del proveedor de
    // origen en `error.metadata.raw`. Ese es el que el usuario necesita leer.
    if (std.mem.eql(u8, message, "Provider returned error")) {
        if (bodyString(raw, "\"raw\"")) |upstream| {
            // Suele empezar por el id del modelo («google/gemma-…:free is
            // temporarily rate-limited upstream…»). Ese id largo dispararía la
            // censura de `excerpt` (parece un token) y DevAgents ya nombra el
            // modelo: se cita desde el verbo.
            var text = std.mem.trim(u8, upstream, " ");
            if (std.mem.indexOfScalar(u8, text, ' ')) |space| {
                if (std.mem.indexOfScalar(u8, text[0..space], '/') != null) text = std.mem.trim(u8, text[space..], " ");
            }
            // Medido en vivo: el texto acaba con un enlace de OpenRouter, que
            // la censura toma por token y tapaba el motivo entero. Se corta.
            if (std.mem.indexOf(u8, text, "http")) |link| text = std.mem.trimEnd(u8, text[0..link], " :;,.");
            if (text.len > 0) return text;
        }
    }
    return message;
}

fn bodyString(raw: []const u8, key: []const u8) ?[]const u8 {
    const at = std.mem.indexOf(u8, raw, key) orelse return null;
    var i = at + key.len;
    while (i < raw.len and (raw[i] == ' ' or raw[i] == ':')) : (i += 1) {}
    if (i >= raw.len or raw[i] != '"') return null;
    const start = i + 1;
    const end = std.mem.indexOfScalarPos(u8, raw, start, '"') orelse return null;
    const text = raw[start..end];
    if (std.mem.indexOfScalar(u8, text, '\\') != null) return null;
    return text;
}

/// Owned, bounded diagnostic shared across the HTTP thread and its caller.
pub const Diagnostic = struct {
    http_status: ?u16 = null,
    text: [200]u8 = undefined,
    len: usize = 0,
    /// A6: indicaciones de reintento (cabeceras y cuerpo) del último fallo.
    rate: RateHints = .{},

    pub fn capture(self: *Diagnostic, status: u16, raw: []const u8, secret: ?[]const u8) void {
        self.http_status = status;
        self.rate = RateHints.fromBody(raw);
        // El motivo del proveedor (`error.message`), si lo hay, es lo que el
        // usuario necesita leer; el cuerpo entero suele quedar censurado.
        const source = bodyMessage(raw) orelse raw;
        self.len = excerpt(&self.text, source, secret).len;
    }

    pub fn message(self: *const Diagnostic) []const u8 {
        return self.text[0..self.len];
    }

    pub fn reason(self: *const Diagnostic) []const u8 {
        return switch (self.http_status orelse 0) {
            401, 403 => "clave rechazada o sin acceso; revisa la clave y los permisos",
            402, 429 => "cuota o limite del proveedor; revisa el plan y reintenta cuando se renueve",
            404 => "modelo no disponible en este endpoint; cambia el modelo",
            400, 422 => "peticion no admitida por el proveedor; revisa los parametros del modelo",
            500...599 => "proveedor no disponible; reintenta o elige otro proveedor",
            else => "fallo de transporte o respuesta no valida; revisa la traza y reintenta",
        };
    }
};

test "ORDENES HTTP diagnostics classify errors and never retain secrets" {
    var d = Diagnostic{};
    for ([_]u16{ 400, 401, 402, 403, 404, 422, 429, 500, 503 }) |status| {
        d.capture(status, "trial limit reached", null);
        try std.testing.expectEqual(status, d.http_status.?);
        try std.testing.expect(d.reason().len > 0);
        try std.testing.expectEqualStrings("[texto externo] trial limit reached", d.message());
    }
    d.capture(429, "echo fx-s7", "fx-s7");
    try std.testing.expectEqualStrings("[texto externo] [REDACTADO]", d.message());
    d.capture(400, "ok " ** 100 ++ "token=secret", null);
    try std.testing.expectEqualStrings("[texto externo] [REDACTADO]", d.message());
    d.capture(404, "", null);
    try std.testing.expectEqualStrings("[texto externo] ", d.message());
}

/// No allocation, including on the error path. Scan BEFORE truncating, so a
/// credential crossing byte 200 cannot survive as a partial secret. Ambiguous
/// structured/encoded credentials suppress the whole excerpt, not just a value.
pub fn excerpt(out: *[200]u8, raw: []const u8, known_secret: ?[]const u8) []const u8 {
    const marker = "[texto externo] ";
    @memcpy(out[0..marker.len], marker);
    var unsafe = false;
    if (known_secret) |secret| {
        if (secret.len > 0 and std.mem.indexOf(u8, raw, secret) != null) unsafe = true;
    }
    const sensitive = [_][]const u8{ "authorization", "token", "password", "passwd", "secret", "bearer", "basic ", "api_key", "api-key", "apikey", "cookie", "credential", "ghp_", "gho_", "github_pat_", "glpat-", "sk-" };
    var run: usize = 0;
    for (raw, 0..) |c, i| {
        for (sensitive) |word| {
            if (raw.len - i >= word.len and std.ascii.eqlIgnoreCase(raw[i..][0..word.len], word)) unsafe = true;
        }
        // Escapes, markup and URL userinfo are ambiguous in a diagnostic;
        // don't interpret attacker encodings or expose a rendered HTML body.
        if (c == '\\' or c == '<' or c == '@' or c == '%') unsafe = true;
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '/' or c == '+' or c == '=' or c == '.') {
            run += 1;
            if (run >= 24) unsafe = true;
        } else run = 0;
    }
    // Drop header-shaped lines, including unknown/custom headers.
    var lines = std.mem.splitScalar(u8, raw, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (std.mem.indexOfScalar(u8, trimmed, ':')) |colon| {
            var header = colon > 0;
            for (trimmed[0..colon]) |c| {
                if (!std.ascii.isAlphanumeric(c) and c != '-') header = false;
            }
            if (header) unsafe = true;
        }
    }
    const text = if (unsafe) "[REDACTADO]" else std.mem.trim(u8, raw, " \t\r\n");
    const len = @min(text.len, out.len - marker.len);
    for (text[0..len], marker.len..) |c, i| out[i] = if (c >= 32 and c < 127) c else ' ';
    return out[0 .. marker.len + len];
}

test "USUARIO-NUEVO A6: un 429 de OpenRouter deja su motivo, su reinicio y si es diario" {
    var d = Diagnostic{};
    // Forma documentada del 429 de OpenRouter para modelos :free.
    const body = "{\"error\":{\"message\":\"Rate limit exceeded: free-models-per-day. Add 10 credits to unlock 1000 free model requests per day\",\"code\":429,\"metadata\":{\"headers\":{\"X-RateLimit-Limit\":\"50\",\"X-RateLimit-Remaining\":\"0\",\"X-RateLimit-Reset\":\"1793318400000\"}}}}";
    d.capture(429, body, null);
    try std.testing.expectEqualStrings("[texto externo] Rate limit exceeded: free-models-per-day. Add 10 credits to unlock 1000 free model requests per day", d.message());
    try std.testing.expect(d.rate.daily);
    try std.testing.expectEqual(@as(?u64, 0), d.rate.remaining);
    try std.testing.expectEqual(@as(?u64, 1793318400000), d.rate.reset_epoch_ms);
    try std.testing.expectEqual(@as(?u64, 400000), d.rate.waitMs(1793318000000));
    var headers = RateHints{};
    headers.note("Retry-After", "7");
    d.rate.merge(headers);
    try std.testing.expectEqual(@as(?u64, 7000), d.rate.waitMs(0));
    // 429 «aguas arriba» de un :free: el motivo real va en metadata.raw.
    var upstream = Diagnostic{};
    upstream.capture(429, "{\"error\":{\"message\":\"Provider returned error\",\"code\":429,\"metadata\":{\"raw\":\"google/gemma-4-26b-a4b-it:free is temporarily rate-limited upstream. Please retry shortly.\",\"provider_name\":\"Google AI Studio\"}}}", null);
    try std.testing.expectEqualStrings("[texto externo] is temporarily rate-limited upstream. Please retry shortly.", upstream.message());
    var linked = Diagnostic{};
    linked.capture(429, "{\"error\":{\"message\":\"Provider returned error\",\"code\":429,\"metadata\":{\"raw\":\"google/gemma-4-26b-a4b-it:free is temporarily rate-limited upstream. Please retry shortly, or add your own key to accumulate your rate limits: https://openrouter.ai/settings/integrations\",\"provider_name\":\"Google AI Studio\"}}}", null);
    try std.testing.expectEqualStrings("[texto externo] is temporarily rate-limited upstream. Please retry shortly, or add your own key to accumulate your rate limits", linked.message());
    var bare = Diagnostic{};
    bare.capture(429, "{\"error\":{\"message\":\"Provider returned error\",\"code\":429}}", null);
    try std.testing.expectEqualStrings("[texto externo] Provider returned error", bare.message());
    var minute = Diagnostic{};
    minute.capture(429, "{\"error\":{\"message\":\"Rate limit exceeded: free-models-per-min.\",\"code\":429}}", null);
    try std.testing.expect(!minute.rate.daily);
    try std.testing.expect(minute.rate.waitMs(0) == null);
    var relative = RateHints{};
    relative.note("x-ratelimit-reset", "3");
    try std.testing.expectEqual(@as(?u64, 3000), relative.waitMs(5));
    relative.note("retry-after", "Wed, 21 Oct 2026 07:28:00 GMT");
    try std.testing.expect(relative.retry_after_ms == null);
}

test "E5.26 external error bounds and rejects credentials headers and encodings" {
    var out: [200]u8 = undefined;
    for ([_][]const u8{
        "{\"token\":\"fx-s7\"}", "Authorization: fx-s7",     "password=fx-s7",              "SeCrEt: fx-s7",
        "Bearer fx-s7",          "X-Custom: fx-s7",          "{\"to\\u006ben\":\"fx-s7\"}", "https://u:fx-s7@host",
        "<b>fx-s7</b>",          "abcdefghijklmnopqrstuvwx", "apiKey=fx-s7",
    }) |raw| {
        try std.testing.expectEqualStrings("[texto externo] [REDACTADO]", excerpt(&out, raw, null));
    }
    try std.testing.expectEqualStrings("[texto externo] [REDACTADO]", excerpt(&out, "echo fx-s7", "fx-s7"));
    try std.testing.expectEqualStrings("[texto externo] base branch missing", excerpt(&out, "base branch missing", null));
    try std.testing.expectEqualStrings("[texto externo] ", excerpt(&out, "", ""));
    try std.testing.expectEqual(@as(usize, 200), excerpt(&out, "ok " ** 100, null).len);
    try std.testing.expectEqualStrings("[texto externo] [REDACTADO]", excerpt(&out, "ok " ** 100 ++ "token=fx-s7", null));
    try std.testing.expect(std.unicode.utf8ValidateSlice(excerpt(&out, "error\x00\xff\r\n", null)));
}
