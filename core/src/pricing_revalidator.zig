const std = @import("std");
const db = @import("db.zig");
const health = @import("health.zig");
const credentials = @import("credentials.zig");
const providers = @import("providers");

/// Revalidador periódico de pricing free/pago (P10-T1).
/// Usa Tavily/Brave con clave; sin clave devuelve skipped: no_search_key.
/// Pago→gratis solo genera sugerencias y eventos pricing_suggestion.
/// Gratis→pago registra pricing_revalidated. Preserva is_favorite.
pub const PricingRevalidator = struct {
    allocator: std.mem.Allocator,
    catalog_conn: db.Connection,
    runtime_conn: db.Connection,
    surface: enum { automatic, mcp } = .automatic,

    pub const ModelRow = struct {
        id: i64,
        provider: []const u8,
        model_name: []const u8,
        is_free: bool,
    };
    const Change = struct { provider: []const u8, model: []const u8, was: []const u8, now: []const u8 };
    const Suggestion = struct { provider: []const u8, model: []const u8, was: []const u8, suggested: []const u8 };
    const Report = struct {
        checked: usize = 0,
        changes: std.ArrayList(Change) = .empty,
        suggestions: std.ArrayList(Suggestion) = .empty,

        fn deinit(self: *Report, aa: std.mem.Allocator) void {
            self.changes.deinit(aa);
            self.suggestions.deinit(aa);
        }

        fn result(self: *const Report, aa: std.mem.Allocator) !RevalidationResult {
            return .{
                .checked = self.checked,
                .changed = self.changes.items.len,
                .changes_json = try std.json.Stringify.valueAlloc(aa, .{
                    .schema = "pricing_revalidate.v2",
                    .checked = self.checked,
                    .changed = self.changes.items.len,
                    .changes = self.changes.items,
                    .suggestions = self.suggestions.items,
                }, .{}),
            };
        }
    };

    pub fn init(allocator: std.mem.Allocator, catalog_conn: db.Connection, runtime_conn: db.Connection) PricingRevalidator {
        return .{ .allocator = allocator, .catalog_conn = catalog_conn, .runtime_conn = runtime_conn };
    }

    pub const RevalidationResult = struct {
        checked: usize,
        changed: usize,
        changes_json: []u8,

        pub fn deinit(self: *RevalidationResult, allocator: std.mem.Allocator) void {
            allocator.free(self.changes_json);
        }
    };

    /// Ruta sin red: la misma decisión, escritura y JSON que usa revalidate.
    pub fn revalidateResults(self: *PricingRevalidator, model: ModelRow, results: []const providers.web_search.SearchResult) !RevalidationResult {
        var report: Report = .{};
        defer report.deinit(self.allocator);
        try self.applyResults(model, results, &report);
        return report.result(self.allocator);
    }

    fn applyResults(self: *PricingRevalidator, model: ModelRow, results: []const providers.web_search.SearchResult, report: *Report) !void {
        report.checked += 1;
        const now_free = classifyPricing(results, model.is_free) orelse return;
        if (now_free == model.is_free) return;

        // N6: MCP no puede eludir spend_budget mediante contenido web. También
        // fuera de MCP toda promoción automática es solo una sugerencia.
        const suggest = (self.surface == .mcp and now_free) or (!model.is_free and now_free);
        const payload = if (suggest)
            try std.json.Stringify.valueAlloc(self.allocator, Suggestion{ .provider = model.provider, .model = model.model_name, .was = "paid", .suggested = "free" }, .{})
        else
            try std.json.Stringify.valueAlloc(self.allocator, Change{ .provider = model.provider, .model = model.model_name, .was = if (model.is_free) "free" else "paid", .now = if (now_free) "free" else "paid" }, .{});
        defer self.allocator.free(payload);

        if (!suggest) {
            // CAS: no sobrescribir una fila modificada mientras se buscaba.
            // Solo is_free: is_favorite y el resto de la fila se conservan.
            const upd = try self.catalog_conn.prepare("UPDATE models SET is_free = ? WHERE id = ? AND is_free = ?");
            defer self.catalog_conn.finalize(upd);
            try db.bindInt(upd, 1, if (now_free) 1 else 0);
            try db.bindInt(upd, 2, model.id);
            try db.bindInt(upd, 3, if (model.is_free) 1 else 0);
            if (db.c.sqlite3_step(upd) != db.c.SQLITE_DONE) return error.StepFailed;
            if (self.catalog_conn.changes() == 0) return;
        }

        self.recordEvent(suggest, payload) catch |event_error| {
            if (!suggest) self.restorePricing(model, now_free) catch return error.PricingRollbackFailed;
            return event_error;
        };

        if (suggest) {
            try report.suggestions.append(self.allocator, .{ .provider = model.provider, .model = model.model_name, .was = "paid", .suggested = "free" });
        } else {
            try report.changes.append(self.allocator, .{ .provider = model.provider, .model = model.model_name, .was = if (model.is_free) "free" else "paid", .now = if (now_free) "free" else "paid" });
        }
    }

    fn recordEvent(self: *PricingRevalidator, suggest: bool, payload: []const u8) !void {
        const ev = try self.runtime_conn.prepare("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (?, 'pricing_revalidator', ?, ?, 0)");
        defer self.runtime_conn.finalize(ev);
        try db.bindInt(ev, 1, health.nowMillis(self.runtime_conn));
        try db.bindText(ev, 2, if (suggest) "pricing_suggestion" else "pricing_revalidated");
        try db.bindText(ev, 3, payload);
        if (db.c.sqlite3_step(ev) != db.c.SQLITE_DONE) return error.StepFailed;
    }

    fn restorePricing(self: *PricingRevalidator, model: ModelRow, now_free: bool) !void {
        const upd = try self.catalog_conn.prepare("UPDATE models SET is_free = ? WHERE id = ? AND is_free = ?");
        defer self.catalog_conn.finalize(upd);
        try db.bindInt(upd, 1, if (model.is_free) 1 else 0);
        try db.bindInt(upd, 2, model.id);
        try db.bindInt(upd, 3, if (now_free) 1 else 0);
        if (db.c.sqlite3_step(upd) != db.c.SQLITE_DONE) return error.StepFailed;
        if (self.catalog_conn.changes() != 1) return error.PricingRollbackConflict;
    }

    /// Errores de red saltan modelos; errores de DB se propagan.
    pub fn revalidate(self: *PricingRevalidator, catalog_path: []const u8) !RevalidationResult {
        const aa = self.allocator;
        // Tavily → Brave. Esta ruta no utiliza el fallback DuckDuckGo.
        var search_provider: ?[]const u8 = null;
        var search_key: ?[]const u8 = null;
        var key_owned: ?[]const u8 = null;
        defer if (key_owned) |k| aa.free(k);
        {
            var cm = credentials.CredentialManager.init(aa, catalog_path) catch null;
            if (cm) |*cm_val| {
                defer cm_val.deinit();
                if (cm_val.getKey("Tavily") catch null) |k| {
                    key_owned = k;
                    search_provider = "Tavily";
                    search_key = k;
                }
                if (search_key == null) {
                    if (cm_val.getKey("Brave Search") catch null) |k| {
                        key_owned = k;
                        search_provider = "Brave Search";
                        search_key = k;
                    }
                }
            }
        }
        if (search_provider == null or search_key == null) {
            return .{
                .checked = 0,
                .changed = 0,
                .changes_json = try aa.dupe(u8, "{\"schema\":\"pricing_revalidate.v2\",\"checked\":0,\"changed\":0,\"changes\":[],\"suggestions\":[],\"skipped\":\"no_search_key\"}"),
            };
        }
        var models = std.ArrayList(ModelRow).empty;
        defer {
            for (models.items) |m| {
                aa.free(m.provider);
                aa.free(m.model_name);
            }
            models.deinit(aa);
        }
        {
            const stmt = try self.catalog_conn.prepare(
                "SELECT m.id, p.name, m.model_name, m.is_free FROM models m " ++
                    "JOIN providers p ON m.provider_id = p.id WHERE p.enabled = 1",
            );
            defer self.catalog_conn.finalize(stmt);
            while (true) {
                const rc = db.c.sqlite3_step(stmt);
                if (rc == db.c.SQLITE_DONE) break;
                if (rc != db.c.SQLITE_ROW) return error.StepFailed;
                const prov_ptr = db.c.sqlite3_column_text(stmt, 1);
                const prov_len = db.c.sqlite3_column_bytes(stmt, 1);
                const model_ptr = db.c.sqlite3_column_text(stmt, 2);
                const model_len = db.c.sqlite3_column_bytes(stmt, 2);
                const provider = try aa.dupe(u8, if (prov_ptr != null) prov_ptr[0..@intCast(prov_len)] else "");
                errdefer aa.free(provider);
                const model_name = try aa.dupe(u8, if (model_ptr != null) model_ptr[0..@intCast(model_len)] else "");
                errdefer aa.free(model_name);
                try models.append(aa, .{
                    .id = db.c.sqlite3_column_int64(stmt, 0),
                    .provider = provider,
                    .model_name = model_name,
                    .is_free = db.c.sqlite3_column_int(stmt, 3) == 1,
                });
            }
        }
        var report: Report = .{};
        defer report.deinit(aa);
        var http = providers.http_client.HttpClient.init(aa) catch null;
        defer if (http) |*h| h.deinit();
        for (models.items) |m| {
            const query = try std.fmt.allocPrint(aa, "{s} {s} API free pricing cost", .{ m.provider, m.model_name });
            defer aa.free(query);
            var results: []providers.web_search.SearchResult = &.{};
            if (http) |*h| {
                results = providers.web_search.search(aa, h, search_provider, search_key, query, 5) catch &.{};
            }
            defer {
                for (results) |r| r.deinit(aa);
                if (results.len > 0) aa.free(results);
            }
            try self.applyResults(m, results, &report);
        }
        return report.result(aa);
    }
};

fn wordByte(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

// Normalización sin asignaciones: guiones, guiones bajos y espacios se
// colapsan en un espacio; la misma vista se aplica al texto y a las frases.
const PricingText = struct {
    text: []const u8,
    index: usize = 0,

    fn separator(c: u8) bool {
        return c == '-' or c == '_' or std.ascii.isWhitespace(c);
    }

    fn next(self: *PricingText) ?u8 {
        if (self.index == self.text.len) return null;
        const c = self.text[self.index];
        self.index += 1;
        if (separator(c)) {
            while (self.index < self.text.len and separator(self.text[self.index])) self.index += 1;
            return ' ';
        }
        return std.ascii.toLower(c);
    }
};

/// Frases normalizadas con límites de palabra, sin distinguir mayúsculas.
fn hasWords(text: []const u8, phrase: []const u8) bool {
    var cursor: PricingText = .{ .text = text };
    var previous: ?u8 = null;
    while (true) {
        var candidate = cursor;
        const first = cursor.next() orelse return false;
        if (previous == null or !wordByte(previous.?)) {
            var needle: PricingText = .{ .text = phrase };
            var matches = true;
            while (needle.next()) |c| {
                if (candidate.next() != c) {
                    matches = false;
                    break;
                }
            }
            if (matches) {
                const after = candidate.next();
                if (after == null or !wordByte(after.?)) return true;
            }
        }
        previous = first;
    }
}

/// Un voto por resultado distinto (URL y contenido); dos votos concordantes
/// y ninguna evidencia contraria. Un plan gratuito no prueba que el modelo lo sea.
fn classifyPricing(results: []const providers.web_search.SearchResult, _: bool) ?bool {
    var free_votes: usize = 0;
    var paid_votes: usize = 0;
    for (results, 0..) |r, i| {
        if (r.url.len == 0 or r.snippet.len == 0) continue;
        var duplicate = false;
        for (results[0..i]) |prior| {
            if (std.mem.eql(u8, prior.url, r.url) or std.ascii.eqlIgnoreCase(prior.snippet, r.snippet)) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        const text = r.snippet;
        const limited = hasWords(text, "free trial") or hasWords(text, "free credits") or hasWords(text, "free tier") or
            hasWords(text, "free plan") or hasWords(text, "free quota");
        const free = !limited and (hasWords(text, "free") or hasWords(text, "no cost") or hasWords(text, "gratuito") or hasWords(text, "gratuit"));
        const usage_rate = hasWords(text, "per token") or hasWords(text, "per 1m") or hasWords(text, "per million") or
            hasWords(text, "/1m") or hasWords(text, "per 1k") or hasWords(text, "per request") or
            hasWords(text, "input tokens") or hasWords(text, "output tokens");
        // Gratis→pago solo con tarifa por uso: «paid», «pricing», «cost» o «$»
        // sueltos no son atribuibles al modelo (el segundo auditor R2, hallazgo 1). Si el mismo
        // resultado menciona un plan gratuito, la tarifa puede ser de otro plan:
        // no vota pago y el modelo conserva su estado (el segundo auditor R3).
        const paid = usage_rate and !limited;
        if (free and !paid) free_votes += 1;
        if (paid and !free) paid_votes += 1;
    }
    if (free_votes >= 2 and paid_votes == 0) return true;
    if (paid_votes >= 2 and free_votes == 0) return false;
    return null;
}

// ── Tests ──────────────────────────────────────────────────────────────

const free_results = [_]providers.web_search.SearchResult{
    .{ .title = "one", .url = "https://one", .snippet = "This model is Free to use" },
    .{ .title = "two", .url = "https://two", .snippet = "The API model is FREE" },
};
const paid_results = [_]providers.web_search.SearchResult{
    .{ .title = "one", .url = "https://one", .snippet = "Pricing: $0.50 per token" },
    .{ .title = "two", .url = "https://two", .snippet = "Output: $1.50 per million output tokens" },
};

test "PRICING single paid snippet and trial are indeterminate" {
    try std.testing.expectEqual(@as(?bool, null), classifyPricing(paid_results[0..1], true));
    const trial = [_]providers.web_search.SearchResult{
        .{ .title = "trial", .url = "https://one", .snippet = "free trial and free credits" },
        .{ .title = "tier", .url = "https://two", .snippet = "free tier" },
    };
    try std.testing.expectEqual(@as(?bool, null), classifyPricing(&trial, false));
}

test "PRICING generic paid words never complete a free to paid downgrade" {
    const generic = [_]providers.web_search.SearchResult{
        .{ .title = "rate", .url = "https://one", .snippet = "Pricing: $0.50 per token" },
        .{ .title = "generic", .url = "https://two", .snippet = "This is a PAID API model; see pricing and cost ($)" },
    };
    try std.testing.expectEqual(@as(?bool, null), classifyPricing(&generic, true));
    try testRevalidation(true, &generic, 0, 0);
}

test "PRICING whole words case insensitive and distinct results" {
    try std.testing.expectEqual(@as(?bool, true), classifyPricing(&free_results, false));
    try std.testing.expectEqual(@as(?bool, false), classifyPricing(&paid_results, true));
    try std.testing.expectEqual(@as(?bool, null), classifyPricing(&.{}, true));
    var results = free_results;
    results[0].snippet = "freely and freedom";
    results[1].snippet = "carefree and freeform";
    try std.testing.expectEqual(@as(?bool, null), classifyPricing(&results, false));
    for ([_][]const u8{ "free trial", "FREE CREDITS", "Free Tier" }) |limited| {
        results = free_results;
        results[0].snippet = limited;
        try std.testing.expectEqual(@as(?bool, null), classifyPricing(&results, false));
    }
    results = free_results;
    results[1].url = results[0].url;
    try std.testing.expectEqual(@as(?bool, null), classifyPricing(&results, false));
    results = free_results;
    results[1].snippet = results[0].snippet;
    try std.testing.expectEqual(@as(?bool, null), classifyPricing(&results, false));
    results = free_results;
    results[1] = paid_results[1];
    try std.testing.expectEqual(@as(?bool, null), classifyPricing(&results, true));
}

fn testScalar(conn: db.Connection, sql: []const u8) !i64 {
    const stmt = try conn.prepare(sql);
    defer conn.finalize(stmt);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return error.StepFailed;
    return db.c.sqlite3_column_int64(stmt, 0);
}

fn testRevalidation(was_free: bool, results: []const providers.web_search.SearchResult, expected_changed: usize, expected_suggestions: usize) !void {
    const aa = std.testing.allocator;
    var cat = try db.Connection.open(aa, ":memory:");
    defer cat.close();
    var rt = try db.Connection.open(aa, ":memory:");
    defer rt.close();
    var migrator = db.Migrator.init(aa);
    try migrator.migrate(cat, &db.catalog_schema);
    try migrator.migrate(rt, &db.runtime_schema);
    try cat.exec("INSERT INTO providers(id,name,base_url,api_style) VALUES(1,'test','https://test','openai')");
    try cat.exec("INSERT INTO models(id,provider_id,model_name,is_free,is_favorite) VALUES(1,1,'model',0,1)");
    if (was_free) try cat.exec("UPDATE models SET is_free=1 WHERE id=1");
    var rv = PricingRevalidator.init(aa, cat, rt);
    const model: PricingRevalidator.ModelRow = .{ .id = 1, .provider = "test", .model_name = "model", .is_free = was_free };
    // Ambas superficies usan el mismo núcleo y producen la misma respuesta.
    for ([_]bool{ false, true }) |mcp| {
        try rt.exec("DELETE FROM events");
        if (was_free) try cat.exec("UPDATE models SET is_free=1 WHERE id=1");
        rv.surface = if (mcp) .mcp else .automatic;
        var result = try rv.revalidateResults(model, results);
        defer result.deinit(aa);
        // Primera aserción detecta la mutación pago→gratis en catalog.db.
        try std.testing.expectEqual(@as(i64, if (was_free and expected_changed == 0) 1 else 0), try testScalar(cat, "SELECT is_free FROM models WHERE id=1"));
        try std.testing.expectEqual(@as(i64, 1), try testScalar(cat, "SELECT is_favorite FROM models WHERE id=1"));
        try std.testing.expectEqual(expected_changed, result.changed);
        try std.testing.expectEqual(@as(usize, 1), result.checked);
        const json = try std.json.parseFromSlice(std.json.Value, aa, result.changes_json, .{});
        defer json.deinit();
        try std.testing.expectEqualStrings("pricing_revalidate.v2", json.value.object.get("schema").?.string);
        const suggestions = json.value.object.get("suggestions").?.array.items;
        const changes = json.value.object.get("changes").?.array.items;
        try std.testing.expectEqual(expected_suggestions, suggestions.len);
        try std.testing.expectEqual(expected_changed, changes.len);
        try std.testing.expectEqual(@as(i64, @intCast(expected_suggestions)), try testScalar(rt, "SELECT count(*) FROM events WHERE kind='pricing_suggestion'"));
        try std.testing.expectEqual(@as(i64, @intCast(expected_changed)), try testScalar(rt, "SELECT count(*) FROM events WHERE kind='pricing_revalidated'"));
        if (expected_suggestions > 0) {
            const suggestion = suggestions[0].object;
            try std.testing.expectEqualStrings("test", suggestion.get("provider").?.string);
            try std.testing.expectEqualStrings("model", suggestion.get("model").?.string);
            try std.testing.expectEqualStrings("paid", suggestion.get("was").?.string);
            try std.testing.expectEqualStrings("free", suggestion.get("suggested").?.string);
            try std.testing.expectEqual(@as(i64, 1), try testScalar(rt, "SELECT count(*) FROM events WHERE json_extract(payload_json,'$.suggested')='free' AND json_extract(payload_json,'$.was')='paid'"));
        }
        if (expected_changed > 0) {
            try std.testing.expectEqualStrings("free", changes[0].object.get("was").?.string);
            try std.testing.expectEqualStrings("paid", changes[0].object.get("now").?.string);
            try std.testing.expectEqual(@as(i64, 1), try testScalar(rt, "SELECT count(*) FROM events WHERE json_extract(payload_json,'$.now')='paid' AND json_extract(payload_json,'$.was')='free'"));
        }
    }
}

test "PRICING paid to free is suggestion only and favorite preserved" {
    try testRevalidation(false, &free_results, 0, 1);
}

test "PRICING free to paid needs two results and favorite preserved" {
    try testRevalidation(true, &paid_results, 1, 0);
}

test "PRICING free with one paid snippet stays free" {
    try testRevalidation(true, paid_results[0..1], 0, 0);
}

test "PRICING stale model row does not overwrite current catalog" {
    const aa = std.testing.allocator;
    var cat = try db.Connection.open(aa, ":memory:");
    defer cat.close();
    var rt = try db.Connection.open(aa, ":memory:");
    defer rt.close();
    var migrator = db.Migrator.init(aa);
    try migrator.migrate(cat, &db.catalog_schema);
    try migrator.migrate(rt, &db.runtime_schema);
    try cat.exec("INSERT INTO providers(id,name,base_url,api_style) VALUES(1,'test','https://test','openai')");
    try cat.exec("INSERT INTO models(id,provider_id,model_name,is_free,is_favorite) VALUES(1,1,'model',0,1)");
    var rv = PricingRevalidator.init(aa, cat, rt);
    var result = try rv.revalidateResults(.{ .id = 1, .provider = "test", .model_name = "model", .is_free = true }, &paid_results);
    defer result.deinit(aa);
    try std.testing.expectEqual(@as(usize, 0), result.changed);
    try std.testing.expectEqual(@as(i64, 0), try testScalar(rt, "SELECT count(*) FROM events"));
}

test "PRICING revalidate without search key returns empty arrays" {
    const aa = std.testing.allocator;
    var cat = try db.Connection.open(aa, ":memory:");
    defer cat.close();
    var rt = try db.Connection.open(aa, ":memory:");
    defer rt.close();
    var migrator = db.Migrator.init(aa);
    try migrator.migrate(cat, &db.catalog_schema);
    try migrator.migrate(rt, &db.runtime_schema);
    var rv = PricingRevalidator.init(aa, cat, rt);
    var result = try rv.revalidate(":memory:");
    defer result.deinit(aa);
    try std.testing.expectEqual(@as(usize, 0), result.checked);
    try std.testing.expectEqual(@as(usize, 0), result.changed);
    const json = try std.json.parseFromSlice(std.json.Value, aa, result.changes_json, .{});
    defer json.deinit();
    try std.testing.expectEqualStrings("pricing_revalidate.v2", json.value.object.get("schema").?.string);
    try std.testing.expectEqualStrings("no_search_key", json.value.object.get("skipped").?.string);
    try std.testing.expectEqual(@as(usize, 0), json.value.object.get("changes").?.array.items.len);
    try std.testing.expectEqual(@as(usize, 0), json.value.object.get("suggestions").?.array.items.len);
}

test "PRICING normalized limited plans never vote free or paid from pro price" {
    try std.testing.expect(hasWords("Free__  tier", "free-tier"));
    for ([_][]const u8{ "Free-tier", "free_tier", "free  tier", "free plan", "free trial", "free credits", "free quota" }) |phrase| {
        const first = try std.fmt.allocPrint(std.testing.allocator, "{s} access for Model-X", .{phrase});
        defer std.testing.allocator.free(first);
        const second = try std.fmt.allocPrint(std.testing.allocator, "Model-X offers {s} access", .{phrase});
        defer std.testing.allocator.free(second);
        var results = free_results;
        results[0].snippet = first;
        results[1].snippet = second;
        try std.testing.expectEqual(@as(?bool, null), classifyPricing(&results, false));
        try testRevalidation(false, &results, 0, 0);
        const pro1 = try std.fmt.allocPrint(std.testing.allocator, "{s} pricing: $5/month for pro", .{phrase});
        defer std.testing.allocator.free(pro1);
        const pro2 = try std.fmt.allocPrint(std.testing.allocator, "Pro cost is $5/month; {s} available", .{phrase});
        defer std.testing.allocator.free(pro2);
        results[0].snippet = pro1;
        results[1].snippet = pro2;
        try testRevalidation(true, &results, 0, 0);
    }
}

test "PRICING two usage rates apply paid including underscore; free plan mentions never downgrade" {
    for ([_][]const u8{ "per token", "per 1M", "per million", "/1M", "per 1K", "per request", "input tokens", "output tokens", "per_1M input_tokens" }) |rate| {
        const first = try std.fmt.allocPrint(std.testing.allocator, "$0.50 {s}", .{rate});
        defer std.testing.allocator.free(first);
        const second = try std.fmt.allocPrint(std.testing.allocator, "API rate: $0.50 {s}", .{rate});
        defer std.testing.allocator.free(second);
        var results = paid_results;
        results[0].snippet = first;
        results[1].snippet = second;
        try testRevalidation(true, &results, 1, 0);
        results[0].snippet = "free_tier with $0.50 per_1M input_tokens";
        try testRevalidation(true, &results, 0, 0);
        results[1].snippet = "Free plan available; paid plan $0.50 per million tokens";
        try testRevalidation(true, &results, 0, 0);
    }
}

test "PRICING event failure rolls back applied update and propagates error" {
    const aa = std.testing.allocator;
    var cat = try db.Connection.open(aa, ":memory:");
    defer cat.close();
    var rt = try db.Connection.open(aa, ":memory:");
    defer rt.close();
    var migrator = db.Migrator.init(aa);
    try migrator.migrate(cat, &db.catalog_schema);
    try cat.exec("INSERT INTO providers(id,name,base_url,api_style) VALUES(1,'test','https://test','openai')");
    try cat.exec("INSERT INTO models(id,provider_id,model_name,is_free,is_favorite) VALUES(1,1,'model',1,1)");
    var rv = PricingRevalidator.init(aa, cat, rt);
    const model: PricingRevalidator.ModelRow = .{ .id = 1, .provider = "test", .model_name = "model", .is_free = true };
    // runtime sin events: falla prepare después del UPDATE aplicado.
    try std.testing.expectError(error.PrepareFailed, rv.revalidateResults(model, &paid_results));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(cat, "SELECT is_free FROM models WHERE id=1"));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(cat, "SELECT is_favorite FROM models WHERE id=1"));
    // También step del evento y fallo de la reversión tienen evidencia propia.
    try migrator.migrate(rt, &db.runtime_schema);
    try rt.exec("CREATE TRIGGER fail_event BEFORE INSERT ON events BEGIN SELECT RAISE(ABORT,'event failed'); END");
    try std.testing.expectError(error.StepFailed, rv.revalidateResults(model, &paid_results));
    try std.testing.expectEqual(@as(i64, 1), try testScalar(cat, "SELECT is_free FROM models WHERE id=1"));
    try cat.exec("CREATE TRIGGER fail_restore BEFORE UPDATE OF is_free ON models WHEN NEW.is_free=1 BEGIN SELECT RAISE(ABORT,'restore failed'); END");
    try std.testing.expectError(error.PricingRollbackFailed, rv.revalidateResults(model, &paid_results));
    try std.testing.expectEqual(@as(i64, 0), try testScalar(cat, "SELECT is_free FROM models WHERE id=1"));
}
