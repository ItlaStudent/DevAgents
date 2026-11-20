//! E5.55: parsers of quota-free CLI discovery output. All strings are data.
const std = @import("std");

pub const Manufacturer = enum {
    anthropic,
    openai,
    google,
    opencode,
    meta,
    mistral,
    deepseek,
    qwen,
    nvidia,
    moonshot,
    minimax,
    zai,
    cohere,
    xai,
    unknown,
    pub fn text(self: Manufacturer) []const u8 {
        return @tagName(self);
    }
};
pub const Session = enum { suscripcion, api_key, sin_sesion, desconocida };
pub const Origin = enum { cli, alias, config, default };
pub const EnumerationStatus = enum { enumerated, no_enumerable, invalid_json, timeout, unavailable };
pub const Model = struct {
    slug: []u8,
    display_name: []u8,
    manufacturer: Manufacturer,
    reasoning_efforts: [][]u8,
    zero_cost: bool = false,
    text_gen: ?bool = null,
    /// De dónde sale la opción: la lista de la CLI, un alias declarado en su
    /// ayuda, el config del usuario o «sin --model» (A4, 10-nov).
    origin: Origin = .cli,
    pub fn deinit(self: *Model, a: std.mem.Allocator) void {
        a.free(self.slug);
        a.free(self.display_name);
        for (self.reasoning_efforts) |s| a.free(s);
        a.free(self.reasoning_efforts);
    }
};
pub const Models = struct {
    models: []Model,
    status: EnumerationStatus,
    pub fn deinit(self: *Models, a: std.mem.Allocator) void {
        for (self.models) |*m| m.deinit(a);
        a.free(self.models);
    }
};

fn validToken(s: []const u8) bool {
    if (s.len == 0 or s.len > 256 or s[0] == '-') return false;
    for (s) |c| if (!std.ascii.isAlphanumeric(c) and std.mem.indexOfScalar(u8, "/._:-", c) == null) return false;
    return true;
}

/// Both the exact Zen ID and current input/output prices must confirm free use.
pub fn isFreeModel(cli: []const u8, slug: []const u8, zero_cost: bool) bool {
    return zero_cost and std.mem.eql(u8, cli, "opencode") and validToken(slug) and
        std.mem.startsWith(u8, slug, "opencode/") and slug.len > "opencode/-free".len and
        std.mem.endsWith(u8, slug, "-free");
}

pub fn manufacturerFor(cli: []const u8, slug: []const u8) Manufacturer {
    if (std.mem.eql(u8, cli, "codex")) return .openai;
    if (std.mem.eql(u8, cli, "claude-code")) return .anthropic;
    if (std.mem.eql(u8, cli, "gemini-cli")) return .google;
    // OpenCode can serve several manufacturers. Resolve the model family,
    // rather than treating the gateway as the producer.
    const families = .{
        .{ "claude", Manufacturer.anthropic },  .{ "gpt-", Manufacturer.openai },       .{ "codex", Manufacturer.openai },
        .{ "gemini", Manufacturer.google },     .{ "gemma", Manufacturer.google },      .{ "paligemma", Manufacturer.google },
        .{ "llama", Manufacturer.meta },        .{ "muse-", Manufacturer.meta },        .{ "mistral", Manufacturer.mistral },
        .{ "mixtral", Manufacturer.mistral },   .{ "ministral", Manufacturer.mistral }, .{ "magistral", Manufacturer.mistral },
        .{ "deepseek", Manufacturer.deepseek }, .{ "qwen", Manufacturer.qwen },         .{ "nemotron", Manufacturer.nvidia },
        .{ "kimi", Manufacturer.moonshot },     .{ "minimax", Manufacturer.minimax },   .{ "glm-", Manufacturer.zai },
        .{ "command-", Manufacturer.cohere },   .{ "grok", Manufacturer.xai },
    };
    var parts = std.mem.splitScalar(u8, slug, '/');
    while (parts.next()) |part| {
        inline for (families) |pair| {
            if (std.ascii.startsWithIgnoreCase(part, pair[0])) return pair[1];
        }
    }
    return .unknown;
}

fn modelOwned(a: std.mem.Allocator, cli: []const u8, slug: []const u8, display: []const u8, efforts: []const []const u8) !Model {
    const s = try a.dupe(u8, slug);
    errdefer a.free(s);
    const d = try a.dupe(u8, display);
    errdefer a.free(d);
    var owned = std.ArrayList([]u8).empty;
    errdefer {
        for (owned.items) |e| a.free(e);
        owned.deinit(a);
    }
    for (efforts) |effort| {
        const e = try a.dupe(u8, effort);
        owned.append(a, e) catch |err| {
            a.free(e);
            return err;
        };
    }
    return .{ .slug = s, .display_name = d, .manufacturer = manufacturerFor(cli, slug), .reasoning_efforts = try owned.toOwnedSlice(a) };
}

pub fn defaultModels(a: std.mem.Allocator, cli: []const u8, status: EnumerationStatus) !Models {
    const models = try a.alloc(Model, 1);
    errdefer a.free(models);
    models[0] = try modelOwned(a, cli, "default", "Modelo por defecto", &.{});
    models[0].origin = .default;
    return .{ .models = models, .status = status };
}

/// Añade `model` (pasa a ser de `models`). Si falla, `models` queda intacto
/// y el llamador conserva `model`.
fn appendModel(a: std.mem.Allocator, models: *Models, model: Model) !void {
    const grown = try a.alloc(Model, models.models.len + 1);
    @memcpy(grown[0..models.models.len], models.models);
    grown[models.models.len] = model;
    a.free(models.models);
    models.models = grown;
}

fn hasSlug(models: []const Model, slug: []const u8) bool {
    for (models) |m| if (std.mem.eql(u8, m.slug, slug)) return true;
    return false;
}

/// 10-nov (USUARIO-NUEVO A4): la ayuda de Claude Code declara los alias que
/// acepta `--model` («an alias for the latest model (e.g. 'fable', 'opus', or
/// 'sonnet')»). Se ofrecen esos, no una lista inventada, con los mismos
/// esfuerzos que el modelo por defecto. Sin declaración, no se añade nada.
pub fn applyClaudeModelAliases(a: std.mem.Allocator, models: *Models, help: []const u8) !void {
    if (help.len > 256 * 1024 or models.models.len == 0) return;
    const start = std.mem.indexOf(u8, help, "--model <") orelse return;
    const tail = help[start..@min(help.len, start + 600)];
    const end = std.mem.indexOf(u8, tail[8..], "\n  --") orelse (tail.len - 8);
    const declaration = tail[0 .. end + 8];
    const alias_at = std.mem.indexOf(u8, declaration, "alias") orelse return;
    const open = std.mem.indexOfScalarPos(u8, declaration, alias_at, '(') orelse return;
    const close = std.mem.indexOfScalarPos(u8, declaration, open, ')') orelse return;
    const efforts = models.models[0].reasoning_efforts;
    var rest = declaration[open + 1 .. close];
    var added: usize = 0;
    while (std.mem.indexOfScalar(u8, rest, '\'')) |q| {
        const after = rest[q + 1 ..];
        const q2 = std.mem.indexOfScalar(u8, after, '\'') orelse break;
        const alias = after[0..q2];
        rest = after[q2 + 1 ..];
        if (!validToken(alias) or alias.len > 32 or hasSlug(models.models, alias)) continue;
        if (added >= 8) break;
        const consts: []const []const u8 = @ptrCast(efforts);
        var model = try modelOwned(a, "claude-code", alias, alias, consts);
        model.origin = .alias;
        appendModel(a, models, model) catch |e| {
            model.deinit(a);
            return e;
        };
        added += 1;
    }
}

/// 10-nov (A4): Codex. El modelo de `~/.codex/config.toml` cuando `debug
/// models` no lo lista (el del propietario, `gpt-6.1-sol`, no salía) y «Modelo por
/// defecto de Codex» (sin `--model`: Codex decide con su configuración).
pub fn addCodexChoices(a: std.mem.Allocator, models: *Models, configured: ?[]const u8, configured_effort: ?[]const u8) !void {
    if (configured) |slug| if (validToken(slug) and !hasSlug(models.models, slug)) {
        const display = try std.fmt.allocPrint(a, "{s} (de tu configuración)", .{slug});
        defer a.free(display);
        const efforts: []const []const u8 = if (configured_effort) |e| (if (validToken(e)) &.{e} else &.{}) else &.{};
        var model = try modelOwned(a, "codex", slug, display, efforts);
        model.origin = .config;
        appendModel(a, models, model) catch |e| {
            model.deinit(a);
            return e;
        };
    };
    if (!hasSlug(models.models, "default")) {
        var model = try modelOwned(a, "codex", "default", "Modelo por defecto de Codex", &.{});
        model.origin = .default;
        appendModel(a, models, model) catch |e| {
            model.deinit(a);
            return e;
        };
    }
}

test "USUARIO-NUEVO A4: Codex oculta los modelos «hide» y ofrece el de config y el por defecto" {
    const a = std.testing.allocator;
    // Forma real de `codex debug models` (0.164, 10-nov): visibility "hide" en
    // gpt-reserve y codex-auto-review.
    var models = try parseModels(a, "codex", "{\"models\":[{\"slug\":\"gpt-reserve\",\"visibility\":\"hide\"},{\"slug\":\"gpt-6-luna\",\"visibility\":\"list\"},{\"slug\":\"codex-auto-review\",\"visibility\":\"hide\"}]}");
    defer models.deinit(a);
    try std.testing.expectEqual(@as(usize, 1), models.models.len);
    try std.testing.expectEqualStrings("gpt-6-luna", models.models[0].slug);
    try addCodexChoices(a, &models, "gpt-6.1-sol", "medium");
    try std.testing.expectEqual(@as(usize, 3), models.models.len);
    try std.testing.expectEqualStrings("gpt-6.1-sol", models.models[1].slug);
    try std.testing.expectEqualStrings("gpt-6.1-sol (de tu configuración)", models.models[1].display_name);
    try std.testing.expectEqual(Origin.config, models.models[1].origin);
    try std.testing.expectEqualStrings("medium", models.models[1].reasoning_efforts[0]);
    try std.testing.expectEqualStrings("default", models.models[2].slug);
    // Ya listado o inválido: no se duplica ni se acepta.
    try addCodexChoices(a, &models, "gpt-6-luna", null);
    try addCodexChoices(a, &models, "--injected", null);
    try std.testing.expectEqual(@as(usize, 3), models.models.len);
}

test "USUARIO-NUEVO A4: Claude Code ofrece los alias que declara su propia ayuda" {
    const a = std.testing.allocator;
    // `claude --help` real de 2.1.283 (nativo, ajustado a la consola) y de
    // 2.1.114 (npm), equipo del propietario, 10-nov.
    const native =
        "  --mcp-config <configs...>             Load MCP servers\n" ++
        "  --model <model>                       Model for the current session. Provide\n" ++
        "                                        an alias for the latest model (e.g.\n" ++
        "                                        'fable', 'opus', or 'sonnet') or a\n" ++
        "                                        model's full name (e.g.\n" ++
        "                                        'claude-sonnet-4-6').\n" ++
        "  -n, --name <name>                     Set a display name\n";
    var models = try defaultModels(a, "claude-code", .no_enumerable);
    defer models.deinit(a);
    try applyClaudeModelAliases(a, &models, native);
    try std.testing.expectEqual(@as(usize, 4), models.models.len);
    try std.testing.expectEqualStrings("default", models.models[0].slug);
    for ([_][]const u8{ "fable", "opus", "sonnet" }, models.models[1..]) |want, m| {
        try std.testing.expectEqualStrings(want, m.slug);
        try std.testing.expectEqual(Origin.alias, m.origin);
    }
    // El nombre completo del ejemplo no es un alias: no se ofrece.
    for (models.models) |m| try std.testing.expect(!std.mem.eql(u8, m.slug, "claude-sonnet-4-6"));
    const npm = "  --model <model>      Model for the current session. Provide an alias for the latest model (e.g. 'sonnet' or 'opus') or a model's full name (e.g. 'claude-sonnet-4-6').\n  -n, --name <name>   Set a display name\n";
    var older = try defaultModels(a, "claude-code", .no_enumerable);
    defer older.deinit(a);
    try applyClaudeModelAliases(a, &older, npm);
    try std.testing.expectEqual(@as(usize, 3), older.models.len);
    try std.testing.expectEqualStrings("sonnet", older.models[1].slug);
    try std.testing.expectEqualStrings("opus", older.models[2].slug);
    // Sin declaración de alias en la ayuda no se inventa ninguno.
    var none = try defaultModels(a, "claude-code", .no_enumerable);
    defer none.deinit(a);
    try applyClaudeModelAliases(a, &none, "  --model <model>  Model for the current session.\n");
    try std.testing.expectEqual(@as(usize, 1), none.models.len);
}

fn zeroPrice(value: std.json.Value) bool {
    if (value != .number_string) return false;
    // Inspect the validated JSON mantissa to avoid rounding a tiny price to zero.
    const end = std.mem.indexOfAny(u8, value.number_string, "eE") orelse value.number_string.len;
    for (value.number_string[0..end]) |c| if (c >= '1' and c <= '9') return false;
    return true;
}

fn metadataMatchesSlug(obj: std.json.ObjectMap, slug: []const u8) bool {
    const id_v = obj.get("id") orelse return false;
    if (id_v != .string) return false;
    if (std.mem.eql(u8, id_v.string, slug)) return true;
    const prov_v = obj.get("providerID") orelse return false;
    if (prov_v != .string) return false;
    const sep = std.mem.indexOfScalar(u8, slug, '/') orelse return false;
    return std.mem.eql(u8, slug[0..sep], prov_v.string) and std.mem.eql(u8, slug[sep + 1 ..], id_v.string);
}

fn appendOpenCodeModel(a: std.mem.Allocator, list: *std.ArrayList(Model), slug: []const u8, metadata: []const u8) !void {
    // Local models remain forbidden in this owner-authorized block.
    if (std.mem.startsWith(u8, slug, "ollama/") or std.mem.startsWith(u8, slug, "lmstudio/")) return;
    if (list.items.len >= 1024) return error.CatalogTooLarge;
    var model = try modelOwned(a, "opencode", slug, slug, &.{});
    errdefer model.deinit(a);
    const parsed = std.json.parseFromSlice(std.json.Value, a, metadata, .{ .max_value_len = 4 * 1024 * 1024, .parse_numbers = false }) catch |err| blk: {
        if (err == error.OutOfMemory) return err;
        break :blk null;
    };
    if (parsed) |p| {
        defer p.deinit();
        // El coste solo vale para el modelo de la cabecera si el bloque dice
        // ser ese modelo: `id` igual al slug o `providerID/id` igual al slug
        // (el segundo auditor, segunda vuelta). Sin `id` coincidente, no hay gratuidad.
        if (p.value == .object and metadataMatchesSlug(p.value.object, slug)) {
            model.text_gen = @import("model_capabilities.zig").fromMetadata(slug, p.value);
            if (p.value.object.get("cost")) |cost| {
                if (cost == .object) {
                    const input = cost.object.get("input");
                    const output = cost.object.get("output");
                    model.zero_cost = input != null and output != null and zeroPrice(input.?) and zeroPrice(output.?);
                }
            }
        }
    }
    try list.append(a, model);
}

pub fn parseModels(a: std.mem.Allocator, cli: []const u8, output: []const u8) !Models {
    if (output.len > 4 * 1024 * 1024) return defaultModels(a, cli, .unavailable);
    var list = std.ArrayList(Model).empty;
    defer {
        for (list.items) |*m| m.deinit(a);
        list.deinit(a);
    }
    if (std.mem.eql(u8, cli, "codex")) {
        var parsed = std.json.parseFromSlice(std.json.Value, a, output, .{ .max_value_len = 4 * 1024 * 1024 }) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return defaultModels(a, cli, .invalid_json);
        };
        defer parsed.deinit();
        const value = if (parsed.value == .object) parsed.value.object.get("models") orelse return defaultModels(a, cli, .invalid_json) else parsed.value;
        if (value != .array or value.array.items.len > 1024) return defaultModels(a, cli, .invalid_json);
        for (value.array.items) |row| {
            if (row != .object) return defaultModels(a, cli, .invalid_json);
            const slug = row.object.get("slug") orelse return defaultModels(a, cli, .invalid_json);
            if (slug != .string or !validToken(slug.string)) return defaultModels(a, cli, .invalid_json);
            if (row.object.get("supported_in_api")) |supported| if (supported == .bool and !supported.bool) continue;
            // A4 (10-nov): Codex marca con `visibility: "hide"` los modelos
            // internos (gpt-reserve, codex-auto-review); su propio selector no
            // los ofrece y DevAgents tampoco.
            if (row.object.get("visibility")) |visibility| if (visibility == .string and std.mem.eql(u8, visibility.string, "hide")) continue;
            const display = row.object.get("display_name");
            const name = if (display != null and display.? == .string and display.?.string.len <= 256 and std.unicode.utf8ValidateSlice(display.?.string)) display.?.string else slug.string;
            var efforts = std.ArrayList([]const u8).empty;
            defer efforts.deinit(a);
            if (row.object.get("supported_reasoning_levels")) |levels| {
                if (levels == .array and levels.array.items.len <= 16) for (levels.array.items) |level| {
                    if (level != .object) continue;
                    const effort = level.object.get("effort") orelse continue;
                    if (effort == .string and validToken(effort.string)) try efforts.append(a, effort.string);
                };
            }
            var model = try modelOwned(a, cli, slug.string, name, efforts.items);
            list.append(a, model) catch |err| {
                model.deinit(a);
                return err;
            };
        }
    } else if (std.mem.eql(u8, cli, "opencode")) {
        var lines = std.mem.splitScalar(u8, output, '\n');
        var pending: ?[]const u8 = null;
        var metadata_start: usize = 0;
        var offset: usize = 0;
        while (lines.next()) |line| {
            const line_start = offset;
            offset = @min(output.len, offset + line.len + 1);
            const slug = std.mem.trim(u8, line, " \t\r");
            if (slug.len == 0) continue;
            if (validToken(slug) and std.mem.indexOfScalar(u8, slug, '/') != null) {
                if (pending) |previous| try appendOpenCodeModel(a, &list, previous, output[metadata_start..line_start]);
                for (list.items) |m| if (std.mem.eql(u8, m.slug, slug)) return defaultModels(a, cli, .no_enumerable);
                pending = slug;
                metadata_start = offset;
            } else if (pending == null) return defaultModels(a, cli, .no_enumerable);
        }
        if (pending) |slug| try appendOpenCodeModel(a, &list, slug, output[metadata_start..]);
    } else return defaultModels(a, cli, .no_enumerable);
    if (list.items.len == 0) return defaultModels(a, cli, .no_enumerable);
    return .{ .models = try list.toOwnedSlice(a), .status = .enumerated };
}

pub fn parseSession(a: std.mem.Allocator, cli: []const u8, stdout: []const u8, stderr: []const u8, billing_env: bool) !Session {
    if (billing_env) return .api_key;
    if (std.mem.eql(u8, cli, "codex")) {
        for ([_][]const u8{ stdout, stderr }) |out| {
            if (std.mem.indexOf(u8, out, "Logged in using ChatGPT") != null) return .suscripcion;
            if (std.mem.indexOf(u8, out, "API key") != null or std.mem.indexOf(u8, out, "API Key") != null) return .api_key;
            if (std.mem.indexOf(u8, out, "Not logged in") != null) return .sin_sesion;
        }
    } else if (std.mem.eql(u8, cli, "claude-code")) {
        var parsed = std.json.parseFromSlice(std.json.Value, a, stdout, .{}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            return .desconocida;
        };
        defer parsed.deinit();
        if (parsed.value != .object) return .desconocida;
        if (parsed.value.object.get("authMethod")) |method| {
            if (method == .string) {
                if (std.mem.eql(u8, method.string, "api_key")) return .api_key;
                // La CLI real (2.x) escribe «claude.ai»; versiones anteriores, «claude_ai».
                if (std.mem.eql(u8, method.string, "claude_ai") or std.mem.eql(u8, method.string, "claude.ai")) return .suscripcion;
                if (std.mem.eql(u8, method.string, "none")) return .sin_sesion;
            }
        }
        if (parsed.value.object.get("loggedIn")) |logged| if (logged == .bool and !logged.bool) return .sin_sesion;
    } else if (std.mem.eql(u8, cli, "opencode")) {
        if (std.mem.indexOf(u8, stdout, "_API_KEY") != null or std.mem.indexOf(u8, stdout, "API key") != null or std.mem.indexOf(u8, stdout, "API Key") != null) return .api_key;
        if ((std.mem.indexOf(u8, stdout, "api") != null or std.mem.indexOf(u8, stdout, "API") != null) and std.mem.indexOf(u8, stdout, "credentials") != null) return .api_key;
        if (std.mem.indexOf(u8, stdout, "oauth") != null) return .suscripcion;
        if (std.mem.indexOf(u8, stdout, "0 credentials") != null) return .sin_sesion;
    }
    return .desconocida;
}

/// Solo auth_mode clasifica el perfil; un campo con nombre de clave no lo hace.
pub fn parseCodexAuthMode(a: std.mem.Allocator, text: []const u8) !Session {
    if (text.len > 1024 * 1024) return .desconocida;
    var parsed = std.json.parseFromSlice(std.json.Value, a, text, .{}) catch |e| {
        if (e == error.OutOfMemory) return e;
        return .desconocida;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return .desconocida;
    const mode = parsed.value.object.get("auth_mode") orelse return .desconocida;
    if (mode != .string) return .desconocida;
    if (std.mem.eql(u8, mode.string, "chatgpt")) return .suscripcion;
    if (std.mem.eql(u8, mode.string, "apikey")) return .api_key;
    return .desconocida;
}

test "RELOJ auth_mode is authoritative without interpreting credential fields" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(Session.suscripcion, try parseCodexAuthMode(a, "{\"auth_mode\":\"chatgpt\",\"OPENAI_API_KEY\":null}"));
    try std.testing.expectEqual(Session.api_key, try parseCodexAuthMode(a, "{\"auth_mode\":\"apikey\"}"));
    for ([_][]const u8{ "{}", "{bad", "[]", "{\"auth_mode\":null}", "{\"auth_mode\":\"other\"}", "{\"OPENAI_API_KEY\":\"synthetic\"}" }) |input|
        try std.testing.expectEqual(Session.desconocida, try parseCodexAuthMode(a, input));
    var fail = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, parseCodexAuthMode(fail.allocator(), "{}"));
}

// ── T2d-D6 (12-nov): sesión de Gemini CLI sin llamar a la red ──────────────
// Gemini CLI no tiene `auth status`. Lo que decide cómo se autentica es
// `security.auth.selectedType` de su settings.json y, solo si falta, sus
// variables de entorno (validateNonInterActiveAuth.ts: `configured ||
// getAuthTypeFromEnv()`, v0.68.0). Desde el 18-jun-2026 Google ya no atiende
// Gemini CLI con cuentas personales (gratis, AI Pro, AI Ultra); con «Sign in
// with Google» solo sirve una licencia Gemini Code Assist Standard o
// Enterprise, que exige GOOGLE_CLOUD_PROJECT. El plan real solo lo sabe el
// servidor de Google: no se consulta (ver D6-gemini-investigacion-20261112.md).

pub const GeminiAuth = enum { none, oauth_personal, api_key, vertex, gateway, adc, unknown };

/// Valores de `AuthType` de Gemini CLI (contentGenerator.ts).
pub fn geminiAuthFromName(name: []const u8) GeminiAuth {
    const table = [_]struct { []const u8, GeminiAuth }{
        .{ "oauth-personal", .oauth_personal },
        .{ "gemini-api-key", .api_key },
        .{ "vertex-ai", .vertex },
        .{ "gateway", .gateway },
        .{ "cloud-shell", .adc },
        .{ "compute-default-credentials", .adc },
    };
    for (table) |row| if (std.mem.eql(u8, name, row[0])) return row[1];
    return .unknown;
}

/// Quita comentarios `//` y `/* */` fuera de las cadenas: Gemini lee su
/// settings.json con strip-json-comments.
pub fn stripJsonComments(a: std.mem.Allocator, text: []const u8) ![]u8 {
    var out = try std.ArrayList(u8).initCapacity(a, text.len);
    errdefer out.deinit(a);
    var i: usize = 0;
    var in_string = false;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (in_string) {
            out.appendAssumeCapacity(c);
            if (c == '\\' and i + 1 < text.len) {
                i += 1;
                out.appendAssumeCapacity(text[i]);
            } else if (c == '"') in_string = false;
            continue;
        }
        if (c == '"') {
            in_string = true;
            out.appendAssumeCapacity(c);
        } else if (c == '/' and i + 1 < text.len and text[i + 1] == '/') {
            while (i < text.len and text[i] != '\n') i += 1;
            if (i < text.len) out.appendAssumeCapacity('\n');
        } else if (c == '/' and i + 1 < text.len and text[i + 1] == '*') {
            i += 2;
            while (i + 1 < text.len and !(text[i] == '*' and text[i + 1] == '/')) i += 1;
            i += 1;
            out.appendAssumeCapacity(' ');
        } else out.appendAssumeCapacity(c);
    }
    return out.toOwnedSlice(a);
}

/// El método elegido en un settings.json de Gemini CLI: `security.auth.selectedType`
/// (actual) o `selectedAuthType` (versiones antiguas). `.none` si no hay
/// ninguno; null si el archivo no es un JSON legible.
pub fn parseGeminiSelectedType(a: std.mem.Allocator, text: []const u8) !?GeminiAuth {
    if (text.len > 1024 * 1024) return null;
    const clean = try stripJsonComments(a, text);
    defer a.free(clean);
    if (std.mem.trim(u8, clean, " \t\r\n").len == 0) return .none;
    var parsed = std.json.parseFromSlice(std.json.Value, a, clean, .{}) catch |e| {
        if (e == error.OutOfMemory) return e;
        return null;
    };
    defer parsed.deinit();
    if (parsed.value != .object) return null;
    const root = parsed.value.object;
    const value = geminiSelectedValue(root) orelse root.get("selectedAuthType") orelse return .none;
    return switch (value) {
        .null => .none,
        .string => |s| if (s.len == 0) .none else geminiAuthFromName(s),
        else => .unknown,
    };
}

fn geminiSelectedValue(root: std.json.ObjectMap) ?std.json.Value {
    const security = root.get("security") orelse return null;
    if (security != .object) return null;
    const auth = security.object.get("auth") orelse return null;
    if (auth != .object) return null;
    return auth.object.get("selectedType");
}

/// Las variables que Gemini CLI consulta cuando el settings.json no elige
/// método. `project`: GOOGLE_CLOUD_PROJECT o GOOGLE_CLOUD_PROJECT_ID.
pub const GeminiEnv = struct {
    gca: bool = false,
    vertex: bool = false,
    gateway: bool = false,
    api_key: bool = false,
    adc: bool = false,
    project: bool = false,
};

/// Mismo orden que getAuthTypeFromEnv de Gemini CLI.
pub fn geminiAuthFromEnv(env: GeminiEnv) GeminiAuth {
    if (env.gca) return .oauth_personal;
    if (env.vertex) return .vertex;
    if (env.gateway) return .gateway;
    if (env.api_key) return .api_key;
    if (env.adc) return .adc;
    return .none;
}

/// Valor de `NAME` en un archivo .env (formato dotenv: `export` opcional,
/// comillas simples o dobles, `#` de comentario al final si no va entre
/// comillas). La última aparición gana, como en dotenv. El valor es un trozo
/// de `text`: puede ser una clave, el llamante no lo guarda.
pub fn dotenvValue(text: []const u8, name: []const u8) ?[]const u8 {
    var found: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        var line = std.mem.trim(u8, raw, " \t\r");
        if (std.mem.startsWith(u8, line, "export ")) line = std.mem.trimStart(u8, line["export ".len..], " \t");
        if (!std.mem.startsWith(u8, line, name)) continue;
        var rest = std.mem.trimStart(u8, line[name.len..], " \t");
        if (rest.len == 0 or rest[0] != '=') continue;
        rest = std.mem.trim(u8, rest[1..], " \t");
        if (rest.len >= 1 and (rest[0] == '"' or rest[0] == '\'')) {
            const close = std.mem.indexOfScalarPos(u8, rest, 1, rest[0]) orelse rest.len;
            found = rest[1..close];
        } else {
            const hash = std.mem.indexOf(u8, rest, " #") orelse rest.len;
            found = std.mem.trimEnd(u8, rest[0..hash], " \t");
        }
    }
    return found;
}

test "T2d-D6: valores de .env como los lee Gemini CLI" {
    const text = "# comentario\nGOOGLE_CLOUD_PROJECT=mi-proyecto # nota\nexport GOOGLE_GENAI_USE_GCA=\"true\"\nGEMINI_API_KEY=''\nGEMINI_API_KEY_OLD=x\nCLOUD_SHELL = 'true'\r\n";
    try std.testing.expectEqualStrings("mi-proyecto", dotenvValue(text, "GOOGLE_CLOUD_PROJECT").?);
    try std.testing.expectEqualStrings("true", dotenvValue(text, "GOOGLE_GENAI_USE_GCA").?);
    try std.testing.expectEqualStrings("", dotenvValue(text, "GEMINI_API_KEY").?);
    try std.testing.expectEqualStrings("true", dotenvValue(text, "CLOUD_SHELL").?);
    try std.testing.expect(dotenvValue(text, "GOOGLE_GENAI_USE_VERTEXAI") == null);
    try std.testing.expectEqualStrings("b", dotenvValue("A=a\nA=b\n", "A").?);
}

pub const GeminiSession = struct { session: Session, reason: []const u8 };

/// Clasificación de DevAgents. Solo «cuenta de Google + proyecto de Google
/// Cloud» cuenta como suscripción (licencia por puesto, sin cobro por uso).
pub fn geminiSession(auth: GeminiAuth, project: bool) GeminiSession {
    return switch (auth) {
        .oauth_personal => if (project)
            .{ .session = .suscripcion, .reason = "cuenta de Google con proyecto de Google Cloud: licencia Gemini Code Assist Standard o Enterprise" }
        else
            .{ .session = .sin_sesion, .reason = "cuenta personal de Google: desde el 18-jun-2026 Gemini CLI solo funciona con licencia de empresa (GOOGLE_CLOUD_PROJECT) o clave de pago; para cuentas personales Google ofrece Antigravity CLI" },
        .api_key => .{ .session = .api_key, .reason = "método «gemini-api-key»: clave de API, factura por uso" },
        .vertex => .{ .session = .api_key, .reason = "método «vertex-ai»: Vertex AI, factura por uso en Google Cloud" },
        .gateway => .{ .session = .api_key, .reason = "método «gateway»: pasarela propia (GOOGLE_GEMINI_BASE_URL)" },
        .adc => .{ .session = .api_key, .reason = "credenciales de Google Cloud de la máquina: factura por uso en Google Cloud" },
        .none => .{ .session = .sin_sesion, .reason = "Gemini CLI no tiene método de inicio de sesión: ábrelo una vez y elige uno" },
        .unknown => .{ .session = .desconocida, .reason = "método de inicio de sesión de Gemini CLI no reconocido" },
    };
}

test "T2d-D6: el método de settings.json de Gemini CLI, con comentarios y formato antiguo" {
    const a = std.testing.allocator;
    const cases = [_]struct { []const u8, ?GeminiAuth }{
        .{ "{\"security\":{\"auth\":{\"selectedType\":\"gemini-api-key\"}}}", .api_key },
        .{ "// usuario\n{\"security\":{\"auth\":{\"selectedType\":\"oauth-personal\"}} /* fin */}", .oauth_personal },
        .{ "{\"url\":\"https://x//y\",\"security\":{\"auth\":{\"selectedType\":\"vertex-ai\"}}}", .vertex },
        .{ "{\"selectedAuthType\":\"oauth-personal\"}", .oauth_personal },
        .{ "{\"security\":{\"auth\":{\"selectedType\":\"compute-default-credentials\"}}}", .adc },
        .{ "{\"security\":{\"auth\":{\"selectedType\":\"gateway\"}}}", .gateway },
        .{ "{\"security\":{\"auth\":{\"selectedType\":\"otra-cosa\"}}}", .unknown },
        .{ "{\"security\":{\"auth\":{\"selectedType\":7}}}", .unknown },
        .{ "{\"security\":{\"auth\":{}}}", .none },
        .{ "{\"security\":{\"auth\":{\"selectedType\":null}}}", .none },
        .{ "{}", .none },
        .{ "  \n", .none },
        .{ "{roto", null },
        .{ "[]", null },
    };
    for (cases) |case| try std.testing.expectEqual(case[1], try parseGeminiSelectedType(a, case[0]));
    var fail = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, parseGeminiSelectedType(fail.allocator(), "{}"));
}

test "T2d-D6: sin método en settings.json, manda el entorno en el orden de Gemini CLI" {
    try std.testing.expectEqual(GeminiAuth.none, geminiAuthFromEnv(.{}));
    try std.testing.expectEqual(GeminiAuth.oauth_personal, geminiAuthFromEnv(.{ .gca = true, .vertex = true, .api_key = true }));
    try std.testing.expectEqual(GeminiAuth.vertex, geminiAuthFromEnv(.{ .vertex = true, .api_key = true }));
    try std.testing.expectEqual(GeminiAuth.gateway, geminiAuthFromEnv(.{ .gateway = true, .api_key = true }));
    try std.testing.expectEqual(GeminiAuth.api_key, geminiAuthFromEnv(.{ .api_key = true, .adc = true }));
    try std.testing.expectEqual(GeminiAuth.adc, geminiAuthFromEnv(.{ .adc = true }));
}

test "T2d-D6: solo la cuenta de Google con proyecto cuenta como suscripción" {
    try std.testing.expectEqual(Session.suscripcion, geminiSession(.oauth_personal, true).session);
    const personal = geminiSession(.oauth_personal, false);
    try std.testing.expectEqual(Session.sin_sesion, personal.session);
    try std.testing.expect(std.mem.indexOf(u8, personal.reason, "18-jun-2026") != null);
    for ([_]GeminiAuth{ .api_key, .vertex, .gateway, .adc }) |auth| {
        try std.testing.expectEqual(Session.api_key, geminiSession(auth, false).session);
        try std.testing.expectEqual(Session.api_key, geminiSession(auth, true).session);
    }
    try std.testing.expectEqual(Session.sin_sesion, geminiSession(.none, true).session);
    try std.testing.expectEqual(Session.desconocida, geminiSession(.unknown, true).session);
}

/// Claude has no quota-free model list, but its current --help declares the
/// accepted --effort values. Parse that declaration; absent/malformed help
/// leaves the default model unchanged.
pub fn applyClaudeEfforts(a: std.mem.Allocator, models: []Model, help: []const u8) !bool {
    if (models.len != 1 or help.len > 256 * 1024) return false;
    const start = std.mem.indexOf(u8, help, "--effort ") orelse return false;
    const tail = help[start..@min(help.len, start + 512)];
    const boundary = std.mem.indexOf(u8, tail[9..], "--") orelse (tail.len - 9);
    const declaration = tail[0 .. boundary + 9];
    const open = std.mem.indexOfScalar(u8, declaration, '(') orelse return false;
    const close = std.mem.indexOfScalarPos(u8, declaration, open + 1, ')') orelse return false;
    var levels = std.ArrayList([]u8).empty;
    defer {
        for (levels.items) |s| a.free(s);
        levels.deinit(a);
    }
    var tokens = std.mem.splitScalar(u8, declaration[open + 1 .. close], ',');
    while (tokens.next()) |raw| {
        const effort = std.mem.trim(u8, raw, " \t\r\n");
        if (!validToken(effort) or effort.len > 16 or levels.items.len >= 16) return false;
        const owned = try a.dupe(u8, effort);
        levels.append(a, owned) catch |err| {
            a.free(owned);
            return err;
        };
    }
    if (levels.items.len < 2) return false;
    const efforts = try levels.toOwnedSlice(a);
    for (models[0].reasoning_efforts) |s| a.free(s);
    a.free(models[0].reasoning_efforts);
    models[0].reasoning_efforts = efforts;
    return true;
}

pub fn versionNewer(candidate: []const u8, previous: []const u8) bool {
    const a = std.SemanticVersion.parse(candidate) catch return false;
    const b = std.SemanticVersion.parse(previous) catch return true;
    return a.order(b) == .gt;
}

test "E5.55 version choice rejects old PATH and prefers release over prerelease" {
    try std.testing.expect(versionNewer("0.159.2", "0.144.4"));
    try std.testing.expect(!versionNewer("0.130.0-alpha.5", "0.144.4"));
    try std.testing.expect(versionNewer("0.159.2", "0.159.2-alpha.5"));
    try std.testing.expect(!versionNewer("garbage", "0.144.4"));
    try std.testing.expect(versionNewer("1.0.0", "garbage"));
}
test "E5.55 quota-free catalogs preserve el segundo auditor, efforts and malformed JSON fallback" {
    const a = std.testing.allocator;
    var codex = try parseModels(a, "codex", "{\"models\":[{\"slug\":\"gpt-6-luna\",\"display_name\":\"GPT-6-Luna\",\"supported_reasoning_levels\":[{\"effort\":\"high\"}]}]}");
    defer codex.deinit(a);
    try std.testing.expectEqual(EnumerationStatus.enumerated, codex.status);
    try std.testing.expectEqualStrings("gpt-6-luna", codex.models[0].slug);
    try std.testing.expectEqualStrings("high", codex.models[0].reasoning_efforts[0]);
    var broken = try parseModels(a, "codex", "{broken");
    defer broken.deinit(a);
    try std.testing.expectEqual(EnumerationStatus.invalid_json, broken.status);
    var opencode = try parseModels(a, "opencode", "opencode/gpt-6-luna\nnvidia/google/gemma-4-31b-it\nollama/local\n");
    defer opencode.deinit(a);
    try std.testing.expectEqual(@as(usize, 2), opencode.models.len);
    try std.testing.expectEqual(Manufacturer.openai, opencode.models[0].manufacturer);
    try std.testing.expectEqual(Manufacturer.google, opencode.models[1].manufacturer);
    var gemini = try parseModels(a, "gemini-cli", "help only");
    defer gemini.deinit(a);
    try std.testing.expectEqual(EnumerationStatus.no_enumerable, gemini.status);
}
test "E5.55 sessions distinguish subscription, billing, no session and unknown" {
    const a = std.testing.allocator;
    try std.testing.expectEqual(Session.suscripcion, try parseSession(a, "codex", "", "Logged in using ChatGPT", false));
    try std.testing.expectEqual(Session.api_key, try parseSession(a, "codex", "Logged in using ChatGPT", "", true));
    try std.testing.expectEqual(Session.sin_sesion, try parseSession(a, "codex", "Not logged in", "", false));
    try std.testing.expectEqual(Session.api_key, try parseSession(a, "claude-code", "{\"authMethod\":\"api_key\"}", "", false));
    try std.testing.expectEqual(Session.sin_sesion, try parseSession(a, "claude-code", "{\"loggedIn\":false}", "", false));
    try std.testing.expectEqual(Session.desconocida, try parseSession(a, "claude-code", "broken", "", false));
    // salida real de `claude auth status` con sesión de claude.ai (16-oct).
    try std.testing.expectEqual(Session.suscripcion, try parseSession(a, "claude-code", "{\n  \"loggedIn\": true,\n  \"authMethod\": \"claude.ai\",\n  \"apiProvider\": \"firstParty\",\n  \"subscriptionType\": \"pro\"\n}", "", false));
    try std.testing.expectEqual(Session.sin_sesion, try parseSession(a, "claude-code", "{\"loggedIn\": false, \"authMethod\": \"none\"}", "", false));
    try std.testing.expectEqual(Session.api_key, try parseSession(a, "opencode", "OpenCode Zen api — 4 credentials", "", false));
    try std.testing.expectEqual(Session.api_key, try parseSession(a, "opencode", "0 credentials\nEnvironment\nTokenRouter TOKENROUTER_API_KEY\n1 environment variable", "", false));
    try std.testing.expectEqual(Session.api_key, try parseSession(a, "opencode", "OpenCode API — 1 credentials", "", false));
    try std.testing.expectEqual(Session.desconocida, try parseSession(a, "gemini-cli", "", "", false));
    // 10-nov (A1): salida real de `opencode auth list` (1.19.4) con el entorno
    // limpio en el equipo del propietario. Sus cuatro credenciales son claves de API
    // guardadas en el propio OpenCode: sigue siendo `api_key` (solo gratuitos).
    try std.testing.expectEqual(Session.api_key, try parseSession(a, "opencode", "T  Credentials ~\\.local\\share\\opencode\\auth.json\n|\n•  OpenCode api\n|\n•  Fireworks AI api\n|\n•  Nvidia api\n|\n•  TokenRouter api\n|\n—  4 credentials\n", "", false));
    try std.testing.expectEqual(Session.suscripcion, try parseSession(a, "opencode", "T  Credentials ~\\.local\\share\\opencode\\auth.json\n|\n•  Anthropic oauth\n|\n—  1 credentials\n", "", false));
}

fn effortsAllocationCase(a: std.mem.Allocator) !void {
    var models = try defaultModels(a, "claude-code", .no_enumerable);
    defer models.deinit(a);
    _ = try applyClaudeEfforts(a, models.models, "--effort <level> Effort level for the current session\n (low, medium, high, xhigh, max)\n--environment <id>");
}

fn opencodeCostsAllocationCase(a: std.mem.Allocator) !void {
    var models = try parseModels(a, "opencode", "opencode/x-free\n{\"cost\":{\"input\":0,\"output\":0}}\nopencode/paid-free\n{bad}\n");
    defer models.deinit(a);
}

test "CK-CAB-002 opencode free R2 prices must both be numeric zero and ID must match Zen free" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "{\"id\":\"x-free\",\"providerID\":\"opencode\",\"cost\":{\"input\":0,\"output\":0}}",
        "{\"id\":\"opencode/x-free\",\"cost\":{\"input\":0.0,\"output\":0e0,\"cache\":{\"read\":0,\"write\":0}}}",
    }) |metadata| {
        const text = try std.fmt.allocPrint(a, "opencode/x-free\r\n{s}\r\n", .{metadata});
        defer a.free(text);
        var models = try parseModels(a, "opencode", text);
        defer models.deinit(a);
        try std.testing.expect(models.models[0].zero_cost);
        try std.testing.expect(isFreeModel("opencode", models.models[0].slug, models.models[0].zero_cost));
    }
    for ([_][]const u8{
        "{\"cost\":{\"input\":1e-999,\"output\":0}}",
        // el segundo auditor r2: sin `id`, o con el `id` de otro modelo, el coste no vale.
        "{\"cost\":{\"input\":0,\"output\":0}}",
        "{\"id\":\"y-free\",\"providerID\":\"opencode\",\"cost\":{\"input\":0,\"output\":0}}",
        "{\"id\":\"x-free\",\"providerID\":\"fireworks\",\"cost\":{\"input\":0,\"output\":0}}",
        "",
        "{bad}",
        "{}",
        "[]",
        "{\"cost\":null}",
        "{\"cost\":{\"input\":0}}",
        "{\"cost\":{\"output\":0}}",
        "{\"cost\":{\"input\":0.1,\"output\":0}}",
        "{\"cost\":{\"input\":0,\"output\":0.1}}",
        "{\"cost\":{\"input\":-1,\"output\":0}}",
        "{\"cost\":{\"input\":\"0\",\"output\":0}}",
        "{\"cost\":{\"input\":false,\"output\":0}}",
        "{\"cost\":{\"input\":0,\"output\":null}}",
        "{\"cost\":{\"input\":0,\"output\":0}} trailing",
    }) |metadata| {
        const text = try std.fmt.allocPrint(a, "opencode/x-free\n{s}\n", .{metadata});
        defer a.free(text);
        var models = try parseModels(a, "opencode", text);
        defer models.deinit(a);
        try std.testing.expect(!models.models[0].zero_cost);
        try std.testing.expect(!isFreeModel("opencode", models.models[0].slug, models.models[0].zero_cost));
    }
    for ([_][]const u8{ "opencode/paid", "fireworks/x-free", "opencode/-free", "opencode/x-free-pro", "opencode/x-free\n", "opencode", "OpenCode/x-free" }) |slug|
        try std.testing.expect(!isFreeModel("opencode", slug, true));
    try std.testing.expect(!isFreeModel("codex", "opencode/x-free", true));
    try std.testing.expect(!isFreeModel("opencode", "opencode/x-free", false));
    var duplicate = try parseModels(a, "opencode", "opencode/x-free\n{\"cost\":{\"input\":0,\"output\":0}}\nopencode/x-free\n{\"cost\":{\"input\":1,\"output\":1}}\n");
    defer duplicate.deinit(a);
    try std.testing.expectEqual(EnumerationStatus.no_enumerable, duplicate.status);
    try std.testing.checkAllAllocationFailures(a, opencodeCostsAllocationCase, .{});
}

test "E5.55 Claude effort values come only from actual help declaration" {
    const a = std.testing.allocator;
    var models = try defaultModels(a, "claude-code", .no_enumerable);
    defer models.deinit(a);
    try std.testing.expect(try applyClaudeEfforts(a, models.models, "--effort <level> Effort level for the current session\n (low, medium, high, xhigh, max)\n--environment <id>"));
    try std.testing.expectEqual(@as(usize, 5), models.models[0].reasoning_efforts.len);
    try std.testing.expectEqualStrings("xhigh", models.models[0].reasoning_efforts[3]);
    try std.testing.expect(!(try applyClaudeEfforts(a, models.models, "--effort <level>\n--other (bad, values)")));
    try std.testing.expect(!(try applyClaudeEfforts(a, models.models, "--effort <level> (low, invalid value)")));
    try std.testing.expect(!(try applyClaudeEfforts(a, models.models, "no effort flag")));
    try std.testing.checkAllAllocationFailures(a, effortsAllocationCase, .{});
}
