const std = @import("std");
const http_client = @import("http/client.zig");

/// Resultado individual de búsqueda web (strings owned por el allocator).
pub const SearchResult = struct {
    title: []const u8,
    url: []const u8,
    snippet: []const u8,

    pub fn deinit(self: SearchResult, allocator: std.mem.Allocator) void {
        allocator.free(self.title);
        allocator.free(self.url);
        allocator.free(self.snippet);
    }
};

/// Selector de proveedor: si provider_name es "Tavily" o "Brave Search" y hay key,
/// usa esa API. Si no, usa DuckDuckGo sin clave.
pub fn search(
    allocator: std.mem.Allocator,
    http: *http_client.HttpClient,
    provider_name: ?[]const u8,
    provider_key: ?[]const u8,
    query: []const u8,
    max_results: usize,
) ![]SearchResult {
    if (provider_name) |name| {
        if (std.mem.eql(u8, name, "Tavily") and provider_key != null) {
            return searchTavily(allocator, http, provider_key.?, query, max_results);
        } else if (std.mem.eql(u8, name, "Brave Search") and provider_key != null) {
            return searchBrave(allocator, http, provider_key.?, query, max_results);
        }
    }
    return searchDuckDuckGo(allocator, http, query, max_results);
}

// ── Tavily ──────────────────────────────────────────────────────────────

fn searchTavily(
    allocator: std.mem.Allocator,
    http: *http_client.HttpClient,
    key: []const u8,
    query: []const u8,
    max_results: usize,
) ![]SearchResult {
    var body: std.Io.Writer.Allocating = .init(allocator);
    defer body.deinit();
    var js: std.json.Stringify = .{ .writer = &body.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("api_key");
    try js.write(key);
    try js.objectField("query");
    try js.write(query);
    try js.objectField("max_results");
    try js.write(@as(i64, @intCast(max_results)));
    try js.endObject();

    const response = try http.postJson("https://api.tavily.com/search", body.written(), null);
    defer allocator.free(response);
    return parseTavilyResponse(allocator, response, max_results);
}

fn parseTavilyResponse(allocator: std.mem.Allocator, json_str: []const u8, max_results: usize) ![]SearchResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return try allocator.alloc(SearchResult, 0);
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return try allocator.alloc(SearchResult, 0);
    const results_val = root.object.get("results") orelse return try allocator.alloc(SearchResult, 0);
    if (results_val != .array) return try allocator.alloc(SearchResult, 0);

    var results = std.ArrayList(SearchResult).empty;
    defer results.deinit(allocator);
    for (results_val.array.items) |item| {
        if (results.items.len >= max_results) break;
        if (item != .object) continue;
        const title = if (item.object.get("title")) |t| (if (t == .string) t.string else "") else "";
        const url = if (item.object.get("url")) |u| (if (u == .string) u.string else "") else "";
        const snippet = if (item.object.get("content")) |c| (if (c == .string) c.string else "") else "";
        try results.append(allocator, .{
            .title = try allocator.dupe(u8, title),
            .url = try allocator.dupe(u8, url),
            .snippet = try allocator.dupe(u8, snippet),
        });
    }
    return results.toOwnedSlice(allocator);
}

// ── Brave Search ────────────────────────────────────────────────────────

fn searchBrave(
    allocator: std.mem.Allocator,
    http: *http_client.HttpClient,
    key: []const u8,
    query: []const u8,
    max_results: usize,
) ![]SearchResult {
    const encoded = try urlEncode(allocator, query);
    defer allocator.free(encoded);
    const url = try std.fmt.allocPrint(allocator, "https://api.search.brave.com/res/v1/web/search?q={s}&count={d}", .{ encoded, max_results });
    defer allocator.free(url);
    const response = try http.getWithHeader(url, "X-Subscription-Token", key);
    defer allocator.free(response);
    return parseBraveResponse(allocator, response, max_results);
}

fn parseBraveResponse(allocator: std.mem.Allocator, json_str: []const u8, max_results: usize) ![]SearchResult {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json_str, .{}) catch {
        return try allocator.alloc(SearchResult, 0);
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return try allocator.alloc(SearchResult, 0);
    const web_val = root.object.get("web") orelse return try allocator.alloc(SearchResult, 0);
    if (web_val != .object) return try allocator.alloc(SearchResult, 0);
    const results_val = web_val.object.get("results") orelse return try allocator.alloc(SearchResult, 0);
    if (results_val != .array) return try allocator.alloc(SearchResult, 0);

    var results = std.ArrayList(SearchResult).empty;
    defer results.deinit(allocator);
    for (results_val.array.items) |item| {
        if (results.items.len >= max_results) break;
        if (item != .object) continue;
        const title = if (item.object.get("title")) |t| (if (t == .string) t.string else "") else "";
        const url = if (item.object.get("url")) |u| (if (u == .string) u.string else "") else "";
        const snippet = if (item.object.get("description")) |d| (if (d == .string) d.string else "") else "";
        try results.append(allocator, .{
            .title = try allocator.dupe(u8, title),
            .url = try allocator.dupe(u8, url),
            .snippet = try allocator.dupe(u8, snippet),
        });
    }
    return results.toOwnedSlice(allocator);
}

// ── DuckDuckGo (sin clave) ──────────────────────────────────────────────

fn searchDuckDuckGo(
    allocator: std.mem.Allocator,
    http: *http_client.HttpClient,
    query: []const u8,
    max_results: usize,
) ![]SearchResult {
    const encoded = try urlEncode(allocator, query);
    defer allocator.free(encoded);
    const form_body = try std.fmt.allocPrint(allocator, "q={s}", .{encoded});
    defer allocator.free(form_body);
    const html = try http.postForm("https://lite.duckduckgo.com/lite/", form_body);
    defer allocator.free(html);
    return parseDuckDuckGoHtml(allocator, html, max_results);
}

fn parseDuckDuckGoHtml(allocator: std.mem.Allocator, html: []const u8, max_results: usize) ![]SearchResult {
    var results = std.ArrayList(SearchResult).empty;
    defer results.deinit(allocator);

    const link_marker = "<a rel=\"nofollow\" href=\"";
    var pos: usize = 0;
    while (pos < html.len) {
        if (results.items.len >= max_results) break;
        const link_start = std.mem.indexOfPos(u8, html, pos, link_marker) orelse break;
        const url_start = link_start + link_marker.len;
        const url_end = std.mem.indexOfPos(u8, html, url_start, "\"") orelse break;
        const url = html[url_start..url_end];

        // After URL closing quote, the real HTML has: class='result-link'>TITLE</a>
        // Find the '> that precedes the title text
        const title_delim = std.mem.indexOfPos(u8, html, url_end, "'>") orelse break;
        const title_start = title_delim + 2;
        if (title_start >= html.len) break;
        const title_end = std.mem.indexOfPos(u8, html, title_start, "</a>") orelse break;
        const title_raw = html[title_start..title_end];

        // Buscar snippet después del link
        var snippet_raw: []const u8 = "";
        const snippet_marker = "class='result-snippet'>";
        if (std.mem.indexOfPos(u8, html, title_end, snippet_marker)) |sp| {
            const snippet_text_start = sp + snippet_marker.len;
            if (std.mem.indexOfPos(u8, html, snippet_text_start, "</td>")) |se| {
                snippet_raw = html[snippet_text_start..se];
            }
        }

        // Filtrar links internos de DuckDuckGo
        if (std.mem.startsWith(u8, url, "http") and !std.mem.startsWith(u8, url, "https://duckduckgo.com")) {
            // FASE-AGENTIC-4: lite.duckduckgo.com envuelve los términos de búsqueda que
            // matchean dentro del snippet/título en <b>...</b> para resaltarlos — a
            // diferencia de las entidades (&amp;), esto es markup real, no texto escapado.
            // Sin quitarlo, el <b>/</b> literal termina visible en el chat (reproducido en
            // vivo: "Notas <b>de</b> <b>la</b> <b>versión</b>") y en el prompt del worker.
            const title_notags = try stripHtmlTags(allocator, title_raw);
            defer allocator.free(title_notags);
            const snippet_notags = try stripHtmlTags(allocator, snippet_raw);
            defer allocator.free(snippet_notags);
            const title = try decodeHtmlEntities(allocator, title_notags);
            const snippet = try decodeHtmlEntities(allocator, snippet_notags);
            try results.append(allocator, .{
                .title = title,
                .url = try allocator.dupe(u8, url),
                .snippet = snippet,
            });
        }
        pos = title_end + 4;
    }
    return results.toOwnedSlice(allocator);
}

// ── Helpers ─────────────────────────────────────────────────────────────

fn urlEncode(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const hex = "0123456789ABCDEF";
    for (s) |c| {
        switch (c) {
            'A'...'Z', 'a'...'z', '0'...'9', '-', '_', '.', '~' => {
                try out.append(allocator, c);
            },
            ' ' => {
                try out.appendSlice(allocator, "+");
            },
            else => {
                try out.append(allocator, '%');
                try out.append(allocator, hex[c >> 4]);
                try out.append(allocator, hex[c & 0xF]);
            },
        }
    }
    return out.toOwnedSlice(allocator);
}

/// Quita etiquetas HTML literales (p.ej. "<b>Zig</b>" -> "Zig"). NO decodifica
/// entidades (&amp; etc.) — eso lo hace decodeHtmlEntities por separado, en ese orden.
fn stripHtmlTags(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var in_tag = false;
    for (s) |c| {
        if (c == '<') {
            in_tag = true;
        } else if (c == '>') {
            in_tag = false;
        } else if (!in_tag) {
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn decodeHtmlEntities(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') {
            if (i + 5 <= s.len and std.mem.eql(u8, s[i .. i + 5], "&amp;")) {
                try out.append(allocator, '&');
                i += 5;
            } else if (i + 4 <= s.len and std.mem.eql(u8, s[i .. i + 4], "&lt;")) {
                try out.append(allocator, '<');
                i += 4;
            } else if (i + 4 <= s.len and std.mem.eql(u8, s[i .. i + 4], "&gt;")) {
                try out.append(allocator, '>');
                i += 4;
            } else if (i + 6 <= s.len and std.mem.eql(u8, s[i .. i + 6], "&quot;")) {
                try out.append(allocator, '"');
                i += 6;
            } else if (i + 5 <= s.len and std.mem.eql(u8, s[i .. i + 5], "&#39;")) {
                try out.append(allocator, '\'');
                i += 5;
            } else if (i + 6 <= s.len and std.mem.eql(u8, s[i .. i + 6], "&nbsp;")) {
                try out.append(allocator, ' ');
                i += 6;
            } else {
                try out.append(allocator, s[i]);
                i += 1;
            }
        } else {
            try out.append(allocator, s[i]);
            i += 1;
        }
    }
    return out.toOwnedSlice(allocator);
}

// ── Tests con fixtures (sin red) ─────────────────────────────────────────

test "parse Tavily response" {
    const fixture =
        \\{"results":[
        \\  {"title":"Zig Programming","url":"https://ziglang.org","content":"Zig is a general-purpose programming language"},
        \\  {"title":"Zig Docs","url":"https://ziglang.org/docs","content":"Documentation for Zig"}
        \\]}
    ;
    const results = try parseTavilyResponse(std.testing.allocator, fixture, 10);
    defer {
        for (results) |r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("Zig Programming", results[0].title);
    try std.testing.expectEqualStrings("https://ziglang.org", results[0].url);
    try std.testing.expect(std.mem.indexOf(u8, results[0].snippet, "general-purpose") != null);
}

test "parse Tavily response with max_results limit" {
    const fixture =
        \\{"results":[
        \\  {"title":"A","url":"https://a.com","content":"aa"},
        \\  {"title":"B","url":"https://b.com","content":"bb"},
        \\  {"title":"C","url":"https://c.com","content":"cc"}
        \\]}
    ;
    const results = try parseTavilyResponse(std.testing.allocator, fixture, 2);
    defer {
        for (results) |r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("A", results[0].title);
    try std.testing.expectEqualStrings("B", results[1].title);
}

test "parse Tavily malformed JSON returns empty" {
    const results = try parseTavilyResponse(std.testing.allocator, "not json", 10);
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "parse Brave response" {
    const fixture =
        \\{"web":{"results":[
        \\  {"title":"Zig Language","url":"https://ziglang.org","description":"A low-level language"},
        \\  {"title":"Learn Zig","url":"https://learnzig.com","description":"Tutorial for Zig"}
        \\]}}
    ;
    const results = try parseBraveResponse(std.testing.allocator, fixture, 10);
    defer {
        for (results) |r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("Zig Language", results[0].title);
    try std.testing.expectEqualStrings("https://ziglang.org", results[0].url);
    try std.testing.expectEqualStrings("A low-level language", results[0].snippet);
}

test "parse Brave malformed JSON returns empty" {
    const results = try parseBraveResponse(std.testing.allocator, "broken", 10);
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "FASE-AGENTIC-4: parse DuckDuckGo HTML strips <b> highlight tags from title/snippet" {
    // Reproduce exacto de lo visto en vivo: lite.duckduckgo.com envuelve los términos
    // que matchean la query en <b>...</b> dentro del snippet real. Antes de este fix,
    // ese markup quedaba literal en el texto mostrado al usuario ("Notas <b>de</b>
    // <b>la</b> <b>versión</b>").
    const fixture =
        \\<a rel="nofollow" href="https://ziglang.org/download" class='result-link'>Descargar el Lenguaje de Programacion <b>Zig</b></a>
        \\<td class='result-snippet'>0.16.0 2026-04-13 Notas <b>de</b> <b>la</b> <b>versión</b> Referencia del <b>Lenguaje</b>.</td>
    ;
    const results = try parseDuckDuckGoHtml(std.testing.allocator, fixture, 10);
    defer {
        for (results) |r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("Descargar el Lenguaje de Programacion Zig", results[0].title);
    try std.testing.expectEqualStrings("0.16.0 2026-04-13 Notas de la versión Referencia del Lenguaje.", results[0].snippet);
    try std.testing.expect(std.mem.indexOf(u8, results[0].snippet, "<b>") == null);
    try std.testing.expect(std.mem.indexOf(u8, results[0].title, "<b>") == null);
}

test "parse DuckDuckGo HTML" {
    const fixture =
        \\<a rel="nofollow" href="https://ziglang.org" class='result-link'>Zig Programming Language</a>
        \\<td class='result-snippet'>Zig is a general-purpose programming language &amp; toolchain.</td>
        \\<a rel="nofollow" href="https://ziglang.org/docs" class='result-link'>Zig Documentation</a>
        \\<td class='result-snippet'>Official Zig documentation &amp; tutorials.</td>
    ;
    const results = try parseDuckDuckGoHtml(std.testing.allocator, fixture, 10);
    defer {
        for (results) |r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("Zig Programming Language", results[0].title);
    try std.testing.expectEqualStrings("https://ziglang.org", results[0].url);
    try std.testing.expect(std.mem.indexOf(u8, results[0].snippet, "general-purpose") != null);
    try std.testing.expect(std.mem.indexOf(u8, results[0].snippet, "&") != null);
    try std.testing.expect(std.mem.indexOf(u8, results[0].snippet, "&amp;") == null);
}

test "parse DuckDuckGo HTML with max_results" {
    const fixture =
        \\<a rel="nofollow" href="https://a.com" class='result-link'>A</a>
        \\<td class='result-snippet'>Snippet A</td>
        \\<a rel="nofollow" href="https://b.com" class='result-link'>B</a>
        \\<td class='result-snippet'>Snippet B</td>
        \\<a rel="nofollow" href="https://c.com" class='result-link'>C</a>
        \\<td class='result-snippet'>Snippet C</td>
    ;
    const results = try parseDuckDuckGoHtml(std.testing.allocator, fixture, 2);
    defer {
        for (results) |r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 2), results.len);
    try std.testing.expectEqualStrings("A", results[0].title);
    try std.testing.expectEqualStrings("B", results[1].title);
}

test "parse DuckDuckGo HTML filters internal links" {
    const fixture =
        \\<a rel="nofollow" href="https://duckduckgo.com/internal" class='result-link'>Internal</a>
        \\<td class='result-snippet'>Internal snippet</td>
        \\<a rel="nofollow" href="https://example.com" class='result-link'>External</a>
        \\<td class='result-snippet'>External snippet</td>
    ;
    const results = try parseDuckDuckGoHtml(std.testing.allocator, fixture, 10);
    defer {
        for (results) |r| r.deinit(std.testing.allocator);
        std.testing.allocator.free(results);
    }
    try std.testing.expectEqual(@as(usize, 1), results.len);
    try std.testing.expectEqualStrings("External", results[0].title);
}

test "parse DuckDuckGo empty HTML returns empty" {
    const results = try parseDuckDuckGoHtml(std.testing.allocator, "<html></html>", 10);
    defer std.testing.allocator.free(results);
    try std.testing.expectEqual(@as(usize, 0), results.len);
}

test "url encode" {
    const encoded = try urlEncode(std.testing.allocator, "hello world & test");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("hello+world+%26+test", encoded);
}

test "url encode special chars" {
    const encoded = try urlEncode(std.testing.allocator, "what is <zig>?");
    defer std.testing.allocator.free(encoded);
    try std.testing.expectEqualStrings("what+is+%3Czig%3E%3F", encoded);
}

test "decode HTML entities" {
    const decoded = try decodeHtmlEntities(std.testing.allocator, "a &amp; b &lt; c &gt; d &quot;e&quot; &#39;f&#39;");
    defer std.testing.allocator.free(decoded);
    try std.testing.expectEqualStrings("a & b < c > d \"e\" 'f'", decoded);
}

test "search result deinit" {
    const r = SearchResult{
        .title = try std.testing.allocator.dupe(u8, "title"),
        .url = try std.testing.allocator.dupe(u8, "url"),
        .snippet = try std.testing.allocator.dupe(u8, "snippet"),
    };
    r.deinit(std.testing.allocator);
}
