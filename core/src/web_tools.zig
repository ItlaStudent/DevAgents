//! 10-nov (propietario): «web y navegador también en Directo o cualquier otro modo
//! siempre que el agente lo necesite». Antes la búsqueda web solo existía
//! dentro de las tareas «investigar» del orquestado (el motor buscaba POR el
//! modelo antes de llamarlo); ningún agente podía decidir buscar ni leer una
//! página. Estas dos herramientas viajan en todos los conjuntos gobernados
//! (Directo, orquestado, colmena, auditoría) y las atiende `live_worker`, que
//! es quien tiene las claves de búsqueda (Tavily o Brave; sin clave, DuckDuckGo).
//!
//! `web_fetch` solo lee páginas públicas: cada salto de redirección se
//! comprueba con `publicHost` (nada de localhost, red privada ni enlace
//! local). Para las apps locales está el navegador integrado (`browser_*`).
const std = @import("std");
const providers = @import("providers");

pub const SEARCH_TOOL_NAME = "web_search";
pub const FETCH_TOOL_NAME = "web_fetch";

const DEFAULT_RESULTS: usize = 5;
const MAX_RESULTS: usize = 10;
const DEFAULT_CHARS: usize = 20_000;
const MAX_CHARS: usize = 60_000;
const MAX_FETCH_BYTES: usize = 3 * 1024 * 1024;

pub const CATALOG = [_]providers.connector_v2.ToolDefinition{
    .{
        .name = SEARCH_TOOL_NAME,
        .description = "Busca en internet. Úsala cuando la respuesta dependa de información actual, externa al proyecto o que no sabes con certeza. Args: query (texto de búsqueda), max_results? (1-10, por defecto 5). Devuelve {ok, provider, results:[{title,url,snippet}]}. Para leer una página entera usa web_fetch con su url.",
        .parameters_json =
        \\{"type":"object","properties":{"query":{"type":"string","minLength":1,"maxLength":400},"max_results":{"type":"integer","minimum":1,"maximum":10}},"required":["query"],"additionalProperties":false}
        ,
    },
    .{
        .name = FETCH_TOOL_NAME,
        .description = "Lee una página web pública (http o https) y devuelve su texto legible. No accede a localhost ni a la red local: para ver una app local usa las herramientas browser_*. Args: url, max_chars? (1000-60000, por defecto 20000). Devuelve {ok, url, text, truncated}.",
        .parameters_json =
        \\{"type":"object","properties":{"url":{"type":"string","minLength":8,"maxLength":2048},"max_chars":{"type":"integer","minimum":1000,"maximum":60000}},"required":["url"],"additionalProperties":false}
        ,
    },
};

pub fn isWebTool(name: []const u8) bool {
    return std.mem.eql(u8, name, SEARCH_TOOL_NAME) or std.mem.eql(u8, name, FETCH_TOOL_NAME);
}

/// Clave de búsqueda resuelta por quien conoce el catálogo; ambas o ninguna.
pub const SearchKey = struct {
    provider: ?[]const u8 = null,
    key: ?[]const u8 = null,
};

/// Ejecuta la herramienta y devuelve SIEMPRE un objeto JSON: los fallos van
/// como `{ok:false,error}` para que el modelo sepa qué pasó y no invente.
pub fn execute(allocator: std.mem.Allocator, name: []const u8, args_json: []const u8, search_key: SearchKey) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, args_json, .{}) catch
        return failure(allocator, "argumentos JSON inválidos");
    defer parsed.deinit();
    if (parsed.value != .object) return failure(allocator, "los argumentos deben ser un objeto");
    const args = parsed.value.object;
    if (std.mem.eql(u8, name, SEARCH_TOOL_NAME)) {
        const query = stringArg(args, "query") orelse return failure(allocator, "falta `query`");
        const trimmed = std.mem.trim(u8, query, " \t\r\n");
        if (trimmed.len == 0 or trimmed.len > 400) return failure(allocator, "`query` vacía o demasiado larga");
        const max = clampInt(args, "max_results", DEFAULT_RESULTS, 1, MAX_RESULTS);
        return search(allocator, trimmed, max, search_key);
    }
    if (std.mem.eql(u8, name, FETCH_TOOL_NAME)) {
        const url = stringArg(args, "url") orelse return failure(allocator, "falta `url`");
        const max_chars = clampInt(args, "max_chars", DEFAULT_CHARS, 1000, MAX_CHARS);
        return fetch(allocator, std.mem.trim(u8, url, " \t\r\n"), max_chars);
    }
    return error.UnsupportedTool;
}

fn search(allocator: std.mem.Allocator, query: []const u8, max: usize, search_key: SearchKey) ![]u8 {
    var http = providers.http_client.HttpClient.init(allocator) catch return failure(allocator, "no se pudo iniciar el cliente HTTP");
    defer http.deinit();
    const results = providers.web_search.search(allocator, &http, search_key.provider, search_key.key, query, max) catch |err|
        return failureFmt(allocator, "la búsqueda falló ({s}); di que no pudiste buscar, no inventes resultados", .{@errorName(err)});
    defer {
        for (results) |r| r.deinit(allocator);
        allocator.free(results);
    }
    const provider = if (search_key.key != null) (search_key.provider orelse "DuckDuckGo") else "DuckDuckGo";
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("ok");
    try js.write(true);
    try js.objectField("provider");
    try js.write(provider);
    try js.objectField("results");
    try js.beginArray();
    for (results) |r| {
        const title = try sanitizeUtf8(allocator, r.title);
        defer allocator.free(title);
        const url = try sanitizeUtf8(allocator, r.url);
        defer allocator.free(url);
        const snippet = try sanitizeUtf8(allocator, r.snippet);
        defer allocator.free(snippet);
        try js.beginObject();
        try js.objectField("title");
        try js.write(title);
        try js.objectField("url");
        try js.write(url);
        try js.objectField("snippet");
        try js.write(snippet);
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    return out.toOwnedSlice();
}

fn fetch(allocator: std.mem.Allocator, url: []const u8, max_chars: usize) ![]u8 {
    const uri = std.Uri.parse(url) catch return failure(allocator, "URL inválida");
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https"))
        return failure(allocator, "solo se leen páginas http o https");
    if (!publicHost(uri))
        return failure(allocator, "destino no público (localhost o red local): usa las herramientas browser_* para apps locales");
    var http = providers.http_client.HttpClient.init(allocator) catch return failure(allocator, "no se pudo iniciar el cliente HTTP");
    defer http.deinit();
    http.max_response_bytes = MAX_FETCH_BYTES;
    var final_url: ?[]u8 = null;
    defer if (final_url) |f| allocator.free(f);
    const body = http.getPublicFollow(url, publicHost, &final_url) catch |err| return switch (err) {
        error.HttpRedirectCrossOrigin => failure(allocator, "la página redirige a un destino no público; bloqueado"),
        error.ResponseTooLarge => failure(allocator, "la página supera 3 MB"),
        else => failureFmt(allocator, "no se pudo leer la página ({s})", .{@errorName(err)}),
    };
    defer allocator.free(body);
    if (std.mem.indexOfScalar(u8, body[0..@min(body.len, 2048)], 0) != null)
        return failure(allocator, "el contenido no es texto (binario)");
    const readable = if (looksLikeHtml(body)) try htmlToText(allocator, body) else try allocator.dupe(u8, body);
    defer allocator.free(readable);
    const clean = try sanitizeUtf8(allocator, readable);
    defer allocator.free(clean);
    const cut = utf8Prefix(clean, max_chars);
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("ok");
    try js.write(true);
    try js.objectField("url");
    try js.write(final_url orelse url);
    try js.objectField("text");
    try js.write(cut);
    try js.objectField("truncated");
    try js.write(cut.len < clean.len);
    try js.endObject();
    return out.toOwnedSlice();
}

/// Solo destinos públicos: nada de localhost, `.local`/`.internal`, IPv4
/// privada, de bucle, enlace local o CGNAT, ni literales IPv6.
pub fn publicHost(uri: std.Uri) bool {
    const host_component = uri.host orelse return false;
    const host = switch (host_component) {
        .raw, .percent_encoded => |h| h,
    };
    if (host.len == 0 or host.len > 253) return false;
    if (host[0] == '[' or std.mem.indexOfScalar(u8, host, ':') != null) return false;
    if (std.mem.indexOfScalar(u8, host, '%') != null) return false;
    const lower_suffixes = [_][]const u8{ "localhost", ".localhost", ".local", ".internal", ".lan", ".home.arpa" };
    for (lower_suffixes) |suffix| {
        if (std.ascii.eqlIgnoreCase(host, suffix) or
            (suffix[0] == '.' and host.len > suffix.len and std.ascii.eqlIgnoreCase(host[host.len - suffix.len ..], suffix)))
            return false;
    }
    // Un nombre de una sola etiqueta («intranet») resuelve en la red local.
    if (std.mem.indexOfScalar(u8, host, '.') == null) return false;
    if (parseIpv4(host)) |ip| {
        const a = ip[0];
        const b = ip[1];
        if (a == 0 or a == 10 or a == 127) return false;
        if (a == 169 and b == 254) return false;
        if (a == 172 and b >= 16 and b <= 31) return false;
        if (a == 192 and b == 168) return false;
        if (a == 100 and b >= 64 and b <= 127) return false;
        if (a >= 224) return false;
    } else {
        // Formas numéricas raras (decimal entero, octal, hexadecimal) que los
        // resolutores aceptan como IPv4: fuera.
        var all_numeric = true;
        for (host) |c| {
            if (!(std.ascii.isDigit(c) or c == '.' or c == 'x' or c == 'X' or std.ascii.isHex(c))) {
                all_numeric = false;
                break;
            }
        }
        const last_label = host[(std.mem.lastIndexOfScalar(u8, host, '.') orelse 0) + 1 ..];
        if (all_numeric and last_label.len > 0 and std.ascii.isDigit(last_label[0])) return false;
    }
    return true;
}

fn parseIpv4(host: []const u8) ?[4]u8 {
    var out: [4]u8 = undefined;
    var it = std.mem.splitScalar(u8, host, '.');
    var i: usize = 0;
    while (it.next()) |part| : (i += 1) {
        if (i >= 4 or part.len == 0 or part.len > 3) return null;
        out[i] = std.fmt.parseInt(u8, part, 10) catch return null;
    }
    return if (i == 4) out else null;
}

fn looksLikeHtml(body: []const u8) bool {
    const head = body[0..@min(body.len, 1024)];
    return std.ascii.indexOfIgnoreCase(head, "<html") != null or
        std.ascii.indexOfIgnoreCase(head, "<!doctype html") != null or
        std.ascii.indexOfIgnoreCase(head, "<head") != null or
        std.ascii.indexOfIgnoreCase(head, "<body") != null;
}

/// Texto legible de una página: quita scripts, estilos y etiquetas, pone
/// saltos en los bloques, decodifica las entidades comunes y junta espacios.
pub fn htmlToText(allocator: std.mem.Allocator, html: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var last_space = true;
    while (i < html.len) {
        const c = html[i];
        if (c == '<') {
            const close = std.mem.indexOfScalarPos(u8, html, i, '>') orelse break;
            const tag = html[i + 1 .. close];
            const skip_blocks = [_][]const u8{ "script", "style", "noscript", "svg", "template" };
            var skipped = false;
            for (skip_blocks) |block| {
                if (tag.len >= block.len and std.ascii.eqlIgnoreCase(tag[0..block.len], block) and
                    (tag.len == block.len or !std.ascii.isAlphanumeric(tag[block.len])))
                {
                    var end_buf: [16]u8 = undefined;
                    const end_tag = std.fmt.bufPrint(&end_buf, "</{s}", .{block}) catch unreachable;
                    const end = std.ascii.indexOfIgnoreCasePos(html, close, end_tag) orelse html.len;
                    i = (std.mem.indexOfScalarPos(u8, html, end, '>') orelse html.len -| 1) + 1;
                    skipped = true;
                    break;
                }
            }
            if (skipped) continue;
            const name_start: usize = if (tag.len > 0 and tag[0] == '/') 1 else 0;
            var name_end = name_start;
            while (name_end < tag.len and std.ascii.isAlphanumeric(tag[name_end])) name_end += 1;
            const name = tag[name_start..name_end];
            const blocks = [_][]const u8{ "p", "br", "div", "li", "tr", "h1", "h2", "h3", "h4", "h5", "h6", "section", "article", "header", "footer", "ul", "ol", "table", "pre", "blockquote" };
            for (blocks) |block| {
                if (std.ascii.eqlIgnoreCase(name, block)) {
                    if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
                        while (out.items.len > 0 and out.items[out.items.len - 1] == ' ') _ = out.pop();
                        try out.append(allocator, '\n');
                    }
                    last_space = true;
                    break;
                }
            }
            i = close + 1;
            continue;
        }
        if (c == '&') {
            const entities = [_]struct { name: []const u8, text: []const u8 }{
                .{ .name = "&amp;", .text = "&" },   .{ .name = "&lt;", .text = "<" },  .{ .name = "&gt;", .text = ">" },
                .{ .name = "&quot;", .text = "\"" }, .{ .name = "&#39;", .text = "'" }, .{ .name = "&apos;", .text = "'" },
                .{ .name = "&nbsp;", .text = " " },
            };
            var matched = false;
            for (entities) |e| {
                if (std.mem.startsWith(u8, html[i..], e.name)) {
                    try out.appendSlice(allocator, e.text);
                    i += e.name.len;
                    last_space = std.mem.eql(u8, e.text, " ");
                    matched = true;
                    break;
                }
            }
            if (matched) continue;
        }
        if (c == ' ' or c == '\t' or c == '\r' or c == '\n') {
            if (!last_space) try out.append(allocator, ' ');
            last_space = true;
            i += 1;
            continue;
        }
        try out.append(allocator, c);
        last_space = false;
        i += 1;
    }
    // Sin líneas en blanco repetidas.
    var compact: std.ArrayList(u8) = .empty;
    errdefer compact.deinit(allocator);
    var blank: usize = 0;
    for (out.items) |ch| {
        if (ch == '\n') {
            blank += 1;
            if (blank > 1) continue;
        } else blank = 0;
        try compact.append(allocator, ch);
    }
    out.deinit(allocator);
    return compact.toOwnedSlice(allocator);
}

/// Copia válida en UTF-8: cada byte que no forma un carácter pasa a «?».
pub fn sanitizeUtf8(allocator: std.mem.Allocator, text: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    try out.ensureTotalCapacity(allocator, text.len);
    var i: usize = 0;
    while (i < text.len) {
        const len = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            out.appendAssumeCapacity('?');
            i += 1;
            continue;
        };
        if (i + len > text.len or !std.unicode.utf8ValidateSlice(text[i .. i + len])) {
            out.appendAssumeCapacity('?');
            i += 1;
            continue;
        }
        const ch = text[i];
        if (len == 1 and ch < 0x20 and ch != '\n' and ch != '\t') {
            out.appendAssumeCapacity(' ');
        } else out.appendSliceAssumeCapacity(text[i .. i + len]);
        i += len;
    }
    return out.toOwnedSlice(allocator);
}

/// Prefijo de como mucho `max` bytes que no parte un carácter UTF-8.
fn utf8Prefix(text: []const u8, max: usize) []const u8 {
    if (text.len <= max) return text;
    var end = max;
    while (end > 0 and (text[end] & 0xC0) == 0x80) end -= 1;
    return text[0..end];
}

fn stringArg(obj: std.json.ObjectMap, key: []const u8) ?[]const u8 {
    const v = obj.get(key) orelse return null;
    return if (v == .string) v.string else null;
}

fn clampInt(obj: std.json.ObjectMap, key: []const u8, default: usize, min: usize, max: usize) usize {
    const v = obj.get(key) orelse return default;
    const n: i64 = switch (v) {
        .integer => |x| x,
        .float => |f| @intFromFloat(@max(@min(f, 1e9), -1e9)),
        else => return default,
    };
    if (n < @as(i64, @intCast(min))) return min;
    if (n > @as(i64, @intCast(max))) return max;
    return @intCast(n);
}

fn failure(allocator: std.mem.Allocator, message: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("ok");
    try js.write(false);
    try js.objectField("error");
    try js.write(message);
    try js.endObject();
    return out.toOwnedSlice();
}

fn failureFmt(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) ![]u8 {
    const message = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(message);
    return failure(allocator, message);
}

test "web_tools: publicHost bloquea la red local y admite sitios públicos" {
    const ok = [_][]const u8{ "https://www.google.com/", "http://example.com/a", "https://8.8.8.8/" };
    for (ok) |u| try std.testing.expect(publicHost(try std.Uri.parse(u)));
    const bad = [_][]const u8{
        "http://localhost:3000/", "http://127.0.0.1/",       "http://10.0.0.5/",   "http://192.168.1.1/",
        "http://172.20.0.1/",     "http://169.254.169.254/", "http://[::1]/",      "http://app.localhost/",
        "http://printer.local/",  "http://intranet/",        "http://2130706433/", "http://0x7f.0.0.1/",
        "http://100.64.0.1/",     "http://svc.internal/",
    };
    for (bad) |u| try std.testing.expect(!publicHost(try std.Uri.parse(u)));
}

test "web_tools: htmlToText quita scripts y estilos y deja el texto legible" {
    const a = std.testing.allocator;
    const text = try htmlToText(a, "<html><head><style>p{color:red}</style><script>alert(1)</script></head><body><h1>Hola &amp; adi&oacute;s</h1><p>Uno   dos</p><p>tres</p></body></html>");
    defer a.free(text);
    try std.testing.expect(std.mem.indexOf(u8, text, "alert") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "color") == null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Hola & adi") != null);
    try std.testing.expect(std.mem.indexOf(u8, text, "Uno dos\ntres") != null);
}

test "web_tools: argumentos inválidos y destinos locales vuelven como {ok:false} sin red" {
    const a = std.testing.allocator;
    const cases = [_]struct { name: []const u8, args: []const u8 }{
        .{ .name = SEARCH_TOOL_NAME, .args = "no json" },
        .{ .name = SEARCH_TOOL_NAME, .args = "{\"query\":\"   \"}" },
        .{ .name = FETCH_TOOL_NAME, .args = "{\"url\":\"http://localhost:5173/\"}" },
        .{ .name = FETCH_TOOL_NAME, .args = "{\"url\":\"file:///C:/secreto.txt\"}" },
    };
    for (cases) |c| {
        const out = try execute(a, c.name, c.args, .{});
        defer a.free(out);
        try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":false") != null);
    }
    try std.testing.expectError(error.UnsupportedTool, execute(a, "run_command", "{}", .{}));
}

test "web_tools: sanitizeUtf8 y utf8Prefix no parten caracteres" {
    const a = std.testing.allocator;
    const clean = try sanitizeUtf8(a, "a\xffb\xc3\xa1");
    defer a.free(clean);
    try std.testing.expectEqualStrings("a?bá", clean);
    try std.testing.expectEqualStrings("ab", utf8Prefix("ab\xc3\xa1", 3));
}
