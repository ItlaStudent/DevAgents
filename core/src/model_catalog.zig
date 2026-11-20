const std = @import("std");
const db = @import("db.zig");
const providers = @import("providers");
const model_roster = @import("model_roster.zig");

/// Contexto asumido cuando el `/models` del proveedor no expone `context_length`
/// (caso NVIDIA: su listado solo trae id/object/created/owned_by, nunca contexto).
/// Sin este default, `registerModel` guardaba 0 → `contextFactor` del router lo
/// hundía a MIN_CONTEXT_FACTOR (0.05) para TODOS los modelos de ese proveedor,
/// aunque la clave y la llamada real funcionaran perfectamente (verificado con
/// curl directo: /v1/models y /v1/chat/completions responden 200 con la misma
/// clave que el motor rechazaba en el ranking). 32768 es una aproximación
/// conservadora (no exacta) — mejor que 0, que es una garantía de fallo.
const UNKNOWN_CONTEXT_DEFAULT: i32 = 32768;

/// OPENCODE-FREE-TIER: la pasarela HTTP de OpenCode Zen no sirve
/// sus modelos gratuitos — una llamada muere con 403 FreeTierError («OpenCode's
/// free tier can only be used from within OpenCode»). El catálogo los marca
/// `available = 0` (no disponibles por HTTP) con este motivo; el router y la
/// cadena del planificador filtran por `available = 1`, así que no gastan
/// intentos ni ensucian la salud. El modelo sigue ofreciéndose por la CLI
/// (agent:opencode, catálogo externo de external_agents.zig). Los modelos de
/// pago de OpenCode NO se tocan.
pub const HTTP_FREE_TIER_CLI_ONLY_REASON: []const u8 = "solo desde la CLI de OpenCode";

/// ¿El par (proveedor, modelo) es un gratis de OpenCode Zen que SOLO responde
/// por su CLI? El nombre es la única señal fiable (el endpoint mezcla gratis y
/// pago; `providers.is_free_tier` no distingue) — misma regla que
/// `model_router.catalogModelIsFree` vía el roster.
pub fn httpFreeTierCliOnly(provider_name: []const u8, model_name: []const u8) bool {
    return isOpenCode(provider_name) and model_roster.isOpenCodeKnownFree(model_name);
}

/// OPENCODE-FREE-TIER: aplica la política a un catálogo YA poblado — filas
/// anteriores a este arreglo con available = 1. Se llama en CADA
/// `ModelCatalog.init` (arranque del motor) y es idempotente: solo apaga lo que
/// sigue encendido. No borra filas ni toca claves: model_scores y la salud
/// conservan su model_id. Devuelve cuántas filas se apagaron.
pub fn enforceHttpFreeTierPolicy(conn: db.Connection) !usize {
    const scratch = conn.allocator;
    var ids: std.ArrayList(i64) = .empty;
    defer ids.deinit(scratch);
    // Dos fases: recolectar ids y solo después apagar. Modificar `models`
    // mientras el SELECT la recorre depende del plan de sqlite; con la lista
    // el orden es explícito.
    const select = try conn.prepare(
        \\SELECT m.id, m.model_name FROM models m
        \\JOIN providers p ON m.provider_id = p.id
        \\WHERE LOWER(p.name) = 'opencode' AND m.available = 1
    );
    defer conn.finalize(select);
    while (db.c.sqlite3_step(select) == db.c.SQLITE_ROW) {
        const name_ptr = db.c.sqlite3_column_text(select, 1);
        const model_name = if (name_ptr != null) std.mem.span(name_ptr) else continue;
        if (!httpFreeTierCliOnly("OpenCode", model_name)) continue;
        try ids.append(scratch, db.c.sqlite3_column_int64(select, 0));
    }
    if (ids.items.len == 0) return 0;
    var updated: usize = 0;
    const update = try conn.prepare("UPDATE models SET available = 0 WHERE id = ? AND available = 1");
    defer conn.finalize(update);
    for (ids.items) |id| {
        _ = db.c.sqlite3_reset(update);
        try db.bindInt(update, 1, id);
        if (db.c.sqlite3_step(update) != db.c.SQLITE_DONE) return error.StepFailed;
        updated += @intCast(db.c.sqlite3_changes(conn.db));
    }
    return updated;
}

/// Catálogo de modelos: descubrimiento dinámico, metadatos, refresco.
pub const ModelCatalog = struct {
    allocator: std.mem.Allocator,
    db: db.Connection,

    pub fn init(allocator: std.mem.Allocator, db_path: []const u8) !ModelCatalog {
        const conn = try db.Connection.open(allocator, db_path);
        var migrator = db.Migrator.init(allocator);
        try migrator.migrate(conn, &db.catalog_schema);
        try seedProviders(conn);
        // OPENCODE-FREE-TIER: los gratis de OpenCode registrados antes de este
        // arreglo siguen con available = 1 en catalog.db; aquí se apagan en
        // cada arranque (idempotente) para que la pasarela HTTP no los intente.
        _ = try enforceHttpFreeTierPolicy(conn);
        return .{
            .allocator = allocator,
            .db = conn,
        };
    }

    pub fn deinit(self: *ModelCatalog) void {
        self.db.close();
    }

    /// Lista modelos registrados en el catálogo. Solo modelos de proveedores HABILITADOS
    /// (con al menos una clave activa) y marcados DISPONIBLES (el último discovery los
    /// vio en el proveedor real). Las filas de modelos deshabilitados/huérfanos se
    /// conservan en la DB (preservan model_scores por model_id) pero no deben aparecer
    /// en esta vista — de lo contrario "Modelos" sigue mostrando proveedores que el
    /// usuario ya quitó/sin clave, como si siguieran disponibles.
    pub fn listModels(self: *ModelCatalog, allocator: std.mem.Allocator) ![:0]const u8 {
        const sql = "SELECT p.name, m.model_name, m.context_window, m.is_free, m.available, m.is_favorite " ++
            "FROM models m JOIN providers p ON m.provider_id = p.id WHERE p.enabled = 1 AND m.available = 1 ORDER BY p.name, m.is_favorite DESC, m.model_name";
        const stmt = try self.db.prepare(sql);
        defer self.db.finalize(stmt);
        var result = std.ArrayList(u8).empty;
        defer result.deinit(allocator);
        try result.appendSlice(allocator, "Provider | Model | Context | Free | Available | Favorite\n");
        try result.appendSlice(allocator, "-------|-------|-------|------|----------|----------\n");
        while (db.c.sqlite3_step(@as(?*db.c.sqlite3_stmt, stmt)) == db.c.SQLITE_ROW) {
            const provider = db.c.sqlite3_column_text(stmt, 0);
            const model = db.c.sqlite3_column_text(stmt, 1);
            const context = db.c.sqlite3_column_int(stmt, 2);
            const is_free = db.c.sqlite3_column_int(stmt, 3);
            const available = db.c.sqlite3_column_int(stmt, 4);
            const favorite = db.c.sqlite3_column_int(stmt, 5);
            const line = try std.fmt.allocPrint(allocator, "{s} | {s} | {d} | {s} | {s} | {s}\n", .{
                provider[0..std.mem.len(provider)],
                model[0..std.mem.len(model)],
                context,
                if (is_free == 1 and
                    (!std.ascii.eqlIgnoreCase(std.mem.span(provider), "OpenCode") or
                        model_roster.isOpenCodeKnownFree(std.mem.span(model)))) "yes" else "no",
                if (available == 1) "yes" else "no",
                if (favorite == 1) "yes" else "no",
            });
            defer allocator.free(line);
            try result.appendSlice(allocator, line);
        }
        // Sentinel-terminated: el C API expone esto como [*:0]u8; sin el 0 final,
        // strlen/QString::fromUtf8 leen más allá del buffer → basura (������).
        return result.toOwnedSliceSentinel(allocator, 0);
    }

    /// Resumen compacto del catálogo REAL para fundamentar (grounding) las respuestas del
    /// superagente: total de modelos y proveedores, conteo por proveedor y una muestra de
    /// nombres. Lo consume el LlmPlanner como CONTEXTO para responder "¿qué modelos tienes?"
    /// con datos verídicos en vez de inventar o decir que no puede. Cadena vacía si el
    /// catálogo está vacío. El llamador libera el slice.
    pub fn summarize(self: *ModelCatalog, allocator: std.mem.Allocator) ![]u8 {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);

        // Totales.
        var total_models: i64 = 0;
        var total_providers: i64 = 0;
        {
            const stmt = try self.db.prepare(
                "SELECT (SELECT COUNT(*) FROM models m JOIN providers p ON m.provider_id=p.id WHERE p.enabled=1 AND m.available=1), " ++
                    "(SELECT COUNT(DISTINCT p.id) FROM models m JOIN providers p ON m.provider_id=p.id WHERE p.enabled=1 AND m.available=1)",
            );
            defer self.db.finalize(stmt);
            if (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
                total_models = db.c.sqlite3_column_int64(stmt, 0);
                total_providers = db.c.sqlite3_column_int64(stmt, 1);
            }
        }
        if (total_models == 0) return out.toOwnedSlice(allocator);

        const head = try std.fmt.allocPrint(allocator, "{d} modelos disponibles de {d} proveedores. Por proveedor: ", .{ total_models, total_providers });
        defer allocator.free(head);
        try out.appendSlice(allocator, head);

        // Conteo por proveedor (los de mayor catálogo primero).
        {
            const stmt = try self.db.prepare(
                "SELECT p.name, COUNT(*) FROM models m JOIN providers p ON m.provider_id=p.id " ++
                    "WHERE p.enabled=1 AND m.available=1 GROUP BY p.id ORDER BY COUNT(*) DESC",
            );
            defer self.db.finalize(stmt);
            var first = true;
            while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
                const name = db.c.sqlite3_column_text(stmt, 0);
                const cnt = db.c.sqlite3_column_int64(stmt, 1);
                const line = try std.fmt.allocPrint(allocator, "{s}{s} ({d})", .{
                    if (first) "" else ", ",
                    name[0..std.mem.len(name)],
                    cnt,
                });
                defer allocator.free(line);
                try out.appendSlice(allocator, line);
                first = false;
            }
        }

        // Muestra de nombres de modelo (hasta 12) para que el modelo pueda citar ejemplos reales.
        {
            const stmt = try self.db.prepare(
                "SELECT m.model_name FROM models m JOIN providers p ON m.provider_id=p.id " ++
                    "WHERE p.enabled=1 ORDER BY m.is_free DESC, p.name LIMIT 12",
            );
            defer self.db.finalize(stmt);
            try out.appendSlice(allocator, ". Ejemplos: ");
            var first = true;
            while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
                const name = db.c.sqlite3_column_text(stmt, 0);
                const line = try std.fmt.allocPrint(allocator, "{s}{s}", .{
                    if (first) "" else ", ",
                    name[0..std.mem.len(name)],
                });
                defer allocator.free(line);
                try out.appendSlice(allocator, line);
                first = false;
            }
            try out.appendSlice(allocator, ".");
        }

        return out.toOwnedSlice(allocator);
    }

    /// Registra un modelo en el catálogo (sentencia preparada con parámetros enlazados — sin inyección SQL).
    pub fn registerModel(self: *ModelCatalog, provider_name: []const u8, model_name: []const u8, context_window: ?i32, is_free: bool) !void {
        // free-tier-first: los "favoritos" son modelos free de alta funcionalidad que el
        // router debe probar PRIMERO (evita orden aleatorio entre cientos de free). Un
        // favorito jamás fuerza un modelo de pago: la marca solo aplica si is_free.
        const favorite = is_free and isFavoriteModel(model_name);
        // OPENCODE-FREE-TIER: un gratis de OpenCode Zen nace NO disponible para
        // la pasarela HTTP (HTTP_FREE_TIER_CLI_ONLY_REASON); `available` sigue
        // significando "la pasarela HTTP puede usarlo".
        const http_available: i64 = if (httpFreeTierCliOnly(provider_name, model_name)) 0 else 1;
        const provider_stmt = try self.db.prepare("SELECT id FROM providers WHERE name = ?");
        defer self.db.finalize(provider_stmt);
        try db.bindText(provider_stmt, 1, provider_name);
        if (db.c.sqlite3_step(provider_stmt) != db.c.SQLITE_ROW) return;
        const provider_id = db.c.sqlite3_column_int64(provider_stmt, 0);

        const sql =
            \\INSERT INTO models (provider_id, model_name, context_window, is_free, is_favorite, discovered_at, last_seen_at, available)
            \\VALUES (?, ?, ?, ?, ?, strftime('%s','now'), strftime('%s','now'), ?)
            \\ON CONFLICT(provider_id, model_name) DO UPDATE SET
            \\    context_window = excluded.context_window,
            \\    is_free = excluded.is_free,
            \\    is_favorite = excluded.is_favorite,
            \\    last_seen_at = strftime('%s','now'),
            \\    available = excluded.available
        ;
        const stmt = try self.db.prepare(sql);
        defer self.db.finalize(stmt);
        try db.bindInt(stmt, 1, provider_id);
        try db.bindText(stmt, 2, model_name);
        try db.bindInt(stmt, 3, context_window orelse 0);
        try db.bindInt(stmt, 4, if (is_free) 1 else 0);
        try db.bindInt(stmt, 5, if (favorite) 1 else 0);
        try db.bindInt(stmt, 6, http_available);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
    }

    /// GOBERNANZA-CATALOGO: recalcula `providers.enabled` para TODOS los proveedores según si
    /// tienen o no al menos una clave activa AHORA MISMO. Es de solo-lectura sobre `api_keys`
    /// (nunca borra ni modifica claves) — corrige datos preexistentes de instalaciones que
    /// perdieron claves ANTES de que `removeKey`/`addKey` sincronizaran `enabled` en el
    /// momento (esos dos ya lo hacen de forma incremental; esto es la reconciliación
    /// retroactiva/periódica para cuando el dato quedó desincronizado por otra vía o por
    /// versiones anteriores del motor). Se invoca desde "Refrescar catálogo" en la UI.
    pub fn reconcileProviderEnabled(self: *ModelCatalog) !void {
        // MODELO-LOCAL: un proveedor local (Ollama) no tiene claves — su
        // `enabled` no puede depender de api_keys o quedaría apagado siempre.
        try self.db.exec(
            \\UPDATE providers SET enabled = (
            \\  is_local = 1
            \\  OR EXISTS (SELECT 1 FROM api_keys k WHERE k.provider_id = providers.id AND k.status = 'active')
            \\)
        );
    }

    /// P4 / NVIDIA: habilita (o deshabilita) un proveedor. Un proveedor cuya clave funciona y
    /// devuelve modelos debe quedar enabled=1, porque el catálogo y el router filtran por
    /// enabled=1 (de lo contrario los modelos descubiertos quedan invisibles para el router).
    pub fn setProviderEnabled(self: *ModelCatalog, provider_name: []const u8, enabled: bool) !void {
        const stmt = try self.db.prepare("UPDATE providers SET enabled = ? WHERE name = ?");
        defer self.db.finalize(stmt);
        try db.bindInt(stmt, 1, if (enabled) 1 else 0);
        try db.bindText(stmt, 2, provider_name);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
    }

    /// Deshabilita en catalog.db los modelos que el probe activo confirmó como
    /// inexistentes de forma repetida. No borra filas ni toca claves.
    pub fn disableConsistentNotFound(self: *ModelCatalog, runtime: db.Connection, min_failures: i64) !usize {
        const select = try runtime.prepare(
            \\SELECT model_id
            \\FROM model_health
            \\WHERE last_err_kind = 'not_found' AND err_count >= ?
        );
        defer runtime.finalize(select);
        try db.bindInt(select, 1, min_failures);

        var disabled: usize = 0;
        while (db.c.sqlite3_step(@as(?*db.c.sqlite3_stmt, select)) == db.c.SQLITE_ROW) {
            const model_id_ptr = db.c.sqlite3_column_text(select, 0) orelse continue;
            const model_id = model_id_ptr[0..std.mem.len(model_id_ptr)];
            var provider: []const u8 = "";
            var model: []const u8 = model_id;
            if (std.mem.indexOfScalar(u8, model_id, '/')) |idx| {
                provider = model_id[0..idx];
                model = model_id[idx + 1 ..];
            }

            const update = try self.db.prepare(
                \\UPDATE models
                \\SET available = 0
                \\WHERE model_name = ?
                \\  AND provider_id = (SELECT id FROM providers WHERE name = ?)
                \\  AND available != 0
            );
            defer self.db.finalize(update);
            try db.bindText(update, 1, model);
            try db.bindText(update, 2, provider);
            if (db.c.sqlite3_step(update) != db.c.SQLITE_DONE) return error.StepFailed;
            if (db.c.sqlite3_changes(self.db.db) > 0) disabled += 1;
        }
        return disabled;
    }

    /// Marca como no disponibles los modelos de UN proveedor antes de redescubrir.
    /// No borra filas: los IDs estables preservan model_scores y relaciones aprendidas.
    pub fn deleteProviderModels(self: *ModelCatalog, provider_name: []const u8) !void {
        const stmt = try self.db.prepare("UPDATE models SET available = 0 WHERE provider_id = (SELECT id FROM providers WHERE name = ?)");
        defer self.db.finalize(stmt);
        try db.bindText(stmt, 1, provider_name);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
    }

    /// Descubrimiento dinámico: puebla el catálogo a partir de una respuesta JSON
    /// de un endpoint `/models`. Soporta el formato OpenAI (`{"data":[{"id":...}]}`)
    /// y el de Google (`{"models":[{"name":...}]}`). Devuelve el nº de modelos registrados.
    /// El proveedor debe existir ya en la tabla `providers`.
    pub fn discoverFromJson(self: *ModelCatalog, provider_name: []const u8, json_str: []const u8, is_free: bool) !usize {
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_str, .{}) catch return error.InvalidJson;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidJson;
        const root = parsed.value.object;

        const list_val = root.get("data") orelse root.get("models") orelse return error.InvalidJson;
        if (list_val != .array) return error.InvalidJson;

        // Re-descubrimiento por proveedor sin borrar filas. Una respuesta vacía no toca
        // el catálogo; una respuesta válida marca el set anterior unavailable y reactiva
        // cada modelo recibido vía UPSERT, preservando model_scores por model_id.
        if (list_val.array.items.len == 0) return 0;
        try self.deleteProviderModels(provider_name);

        var count: usize = 0;
        for (list_val.array.items) |entry| {
            if (entry != .object) continue;
            const obj = entry.object;
            const id_val = obj.get("id") orelse obj.get("name") orelse continue;
            if (id_val != .string) continue;
            var ctx: ?i32 = null;
            if (obj.get("context_length") orelse obj.get("context_window")) |cv| {
                if (cv == .integer) ctx = @intCast(cv.integer);
            }
            // El proveedor no expuso contexto para este modelo (0 rompería el ranking
            // por completo vía contextFactor) — usar el default conservador.
            const ctx_effective: i32 = ctx orelse UNKNOWN_CONTEXT_DEFAULT;
            // free-tier-first: clasificación POR MODELO, no por proveedor. Un proveedor
            // free-tier (p.ej. OpenRouter) proxya modelos de PAGO (anthropic/claude-*, etc.);
            // marcarlos todos is_free=1 rompía el free-first (el router probaba pago primero
            // → 402 → nunca llegaba a un free). Determinar por modelo:
            //   1) pricing prompt+completion == 0 (formato OpenRouter) => free
            //   2) sufijo ":free" en el id (convención OpenRouter) => free
            //   3) OpenCode sin pricing => solo marcas explícitas conocidas;
            //      no heredar el flag del proveedor a modelos mixtos.
            //   4) otros proveedores sin señal => default histórico del proveedor.
            var entry_free = if (isOpenCode(provider_name)) model_roster.isOpenCodeKnownFree(id_val.string) else is_free;
            if (obj.get("pricing")) |pv| {
                if (pv == .object) {
                    entry_free = priceIsZero(pv.object.get("prompt")) and priceIsZero(pv.object.get("completion"));
                }
            }
            if (!isOpenCode(provider_name) and std.mem.indexOf(u8, id_val.string, ":free") != null) entry_free = true;
            try self.registerModel(provider_name, id_val.string, ctx_effective, entry_free);
            const capability = @import("model_capabilities.zig");
            const explicit_text = capability.fromMetadata(id_val.string, entry);
            const text_gen = explicit_text orelse !capability.nonChat(id_val.string);
            const update = try self.db.prepare("UPDATE models SET is_generative=?, modalities=? WHERE model_name=? AND provider_id=(SELECT id FROM providers WHERE name=?)");
            defer self.db.finalize(update);
            try db.bindInt(update, 1, @intFromBool(text_gen));
            if (explicit_text) |text| {
                try db.bindText(update, 2, if (text) "text" else "non_chat");
            } else if (db.c.sqlite3_bind_null(update, 2) != db.c.SQLITE_OK) return error.BindFailed;
            try db.bindText(update, 3, id_val.string);
            try db.bindText(update, 4, provider_name);
            if (db.c.sqlite3_step(update) != db.c.SQLITE_DONE) return error.StepFailed;
            count += 1;
        }
        return count;
    }
};

fn isOpenCode(provider_name: []const u8) bool {
    return std.ascii.eqlIgnoreCase(provider_name, "OpenCode");
}

/// Interpreta un campo de precio de un endpoint /models (OpenRouter usa strings como
/// "0" o "0.0000015") como cero (free) o no. Ausente/ilegible => NO-cero (conservador: pago).
fn priceIsZero(v: ?std.json.Value) bool {
    const val = v orelse return false;
    return switch (val) {
        .string => |s| blk: {
            const f = std.fmt.parseFloat(f64, s) catch break :blk false;
            break :blk f == 0.0;
        },
        .number_string => |s| blk: {
            const f = std.fmt.parseFloat(f64, s) catch break :blk false;
            break :blk f == 0.0;
        },
        .integer => |i| i == 0,
        .float => |fl| fl == 0.0,
        else => false,
    };
}

/// "Modelos favoritos": familias free-tier de alta funcionalidad que el router debe
/// probar PRIMERO (evita que la asignación inicial sea aleatoria entre cientos de free).
/// Curado a partir de la experiencia del propietario (2026-07-02, ampliado 2026-07-08):
/// - el agente V4 Flash / Pro (free vía NVIDIA, OpenCode, OpenRouter:free)
///   - Nemotron generativos (NVIDIA FreeEndpoint; excluye content-safety/guard/parse/reward)
///   - Cohere Command de alto rendimiento (command-a-plus, command-a, command-r-plus, reasoning)
/// - Confirmados por el propietario en vivo 2026-07-08 (probados uno por uno, responden real):
///     GLM 5.2, MiniMax M3, Gemma 4 31B, y en OpenCode: Big Pickle, MiMo V2.5, North Mini
///     Code, Hy3 (verificado con order real: north-mini-code-free respondió a la primera).
/// El caller ya garantizó is_free; esta función NO decide gratuidad, solo prioridad.
/// Los nombres del endpoint /models llegan en minúsculas → comparación literal directa.
fn isFavoriteModel(name: []const u8) bool {
    const has = struct {
        fn f(haystack: []const u8, needle: []const u8) bool {
            return std.mem.indexOf(u8, haystack, needle) != null;
        }
    }.f;
    // el agente V4 (flash/pro): rápido y muy capaz para código.
    if (has(name, "deepseek-v4-flash")) return true;
    if (has(name, "deepseek-v4-pro")) return true;
    // Nemotron generativos — excluye TODA la familia de modelos NVIDIA NIM
    // especializados (no conversacionales) que GOBERNANZA-ROUTER ya penaliza en
    // model_router.zig: content-safety/guard (clasificadores), parse/nemoretriever
    // (parsers de documentos), reward (reward models). Favoritar uno de estos sería
    // contradictorio: el heurístico del router ya los hunde aposta.
    if (has(name, "nemotron") and !has(name, "content-safety") and !has(name, "guard") and
        !has(name, "-parse") and !has(name, "nemoretriever") and !has(name, "reward") and
        !has(name, "moderat")) return true;
    // Cohere Command de alto rendimiento.
    if (has(name, "command-a-plus")) return true;
    if (has(name, "command-a-03")) return true;
    if (has(name, "command-a-reasoning")) return true;
    if (has(name, "command-r-plus")) return true;
    // Confirmados por el propietario en vivo 2026-07-08 (ver comentario de arriba).
    if (has(name, "glm-5.2")) return true;
    if (has(name, "minimax-m3")) return true;
    if (has(name, "gemma-4-31b")) return true;
    if (has(name, "big-pickle")) return true;
    if (has(name, "mimo-v2.5")) return true;
    if (has(name, "north-mini-code")) return true;
    if (has(name, "hy3-free")) return true;
    return false;
}

test "isFavoriteModel: modelos confirmados en vivo por el propietario 2026-07-08" {
    const confirmed = [_][]const u8{
        "glm-5.2",    "minimax-m3",     "gemma-4-31b-it",
        "big-pickle", "mimo-v2.5-free", "north-mini-code-free",
        "hy3-free",
    };
    for (confirmed) |m| try std.testing.expect(isFavoriteModel(m));
}

test "isFavoriteModel: la familia nemotron NO favorita a los modelos NIM especializados" {
    // Alineado con GOBERNANZA-ROUTER en model_router.zig: si el heuristico del router
    // ya hunde estos, favoritarlos aqui seria contradictorio (y antes de este fix,
    // "nvidia/nemotron-parse" SI se marcaba favorite=1 por matchear "nemotron" a secas).
    const specialized = [_][]const u8{
        "nvidia/nemotron-parse",
        "nvidia/nemotron-3-content-safety",
        "nvidia/nemotron-content-safety-reasoning-4b",
        "nvidia/llama-3.1-nemotron-safety-guard-8b-v3",
        "nvidia/nemotron-4-340b-reward",
    };
    for (specialized) |m| try std.testing.expect(!isFavoriteModel(m));
    // Un nemotron de chat real SI debe seguir favoritandose.
    try std.testing.expect(isFavoriteModel("nvidia/nemotron-3-ultra-550b-a55b"));
}

/// Siembra/actualiza los proveedores de ALL_PROVIDERS en catalog.db.
/// Seguro para catalog.db existente: corrige metadatos del proveedor sin tocar claves.
///
/// GOBERNANZA-CATALOGO ronda 3 (2026-07-08): esta función corre en CADA arranque del
/// motor (la llama ModelCatalog.init, no solo en instalación nueva). El ON CONFLICT
/// antes traía `enabled = 1` fijo — cada reinicio pisaba el trabajo de
/// syncProviderEnabled/reconcileProviderEnabled (que sí reflejan si el proveedor tiene
/// una clave activa AHORA) y devolvía TODOS los proveedores a enabled=1, sin importar
/// que llevaran claves quitadas hace tiempo. Síntoma real: el usuario veía
/// "593 modelos/23 proveedores" en cada apertura de DevAgents con una sola clave activa,
/// hasta que pulsaba "Refrescar catálogo" — y volvía a romperse en el siguiente reinicio.
/// Fix: en el INSERT nuevo (proveedor nunca visto) sigue naciendo enabled=1 (caso
/// instalación limpia, sin claves aún — comportamiento esperado por
/// "da_catalog_info_json ... provider_count:25"). En el UPDATE (proveedor ya existente)
/// NO se toca enabled — su valor real lo propietaria syncProviderEnabled, no el reseed.
fn seedProviders(conn: db.Connection) !void {
    const sql =
        \\INSERT INTO providers (name, base_url, api_style, is_free_tier, enabled, is_local)
        \\VALUES (?, ?, ?, ?, 1, ?)
        \\ON CONFLICT(name) DO UPDATE SET
        \\  base_url = excluded.base_url,
        \\  api_style = excluded.api_style,
        \\  is_free_tier = excluded.is_free_tier,
        \\  is_local = excluded.is_local,
        \\  enabled = CASE WHEN excluded.is_local = 1 THEN 1 ELSE providers.enabled END
    ;
    for (providers.providers.ALL_PROVIDERS) |cfg| {
        const stmt = try conn.prepare(sql);
        defer conn.finalize(stmt);
        try db.bindText(stmt, 1, cfg.name);
        // MODELO-LOCAL: la URL que se persiste es la EFECTIVA — Ollama admite
        // override por DEVAGENTS_OLLAMA_URL y el catálogo debe reflejar dónde
        // se está llamando de verdad.
        try db.bindText(stmt, 2, providers.providers.effectiveBaseUrl(cfg));
        try db.bindText(stmt, 3, @tagName(cfg.api_style));
        try db.bindInt(stmt, 4, if (cfg.is_free_tier) 1 else 0);
        try db.bindInt(stmt, 5, if (cfg.is_local) 1 else 0);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.DbError;
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

test "model catalog init" {
    const allocator = std.testing.allocator;
    const path = ":memory:";
    var catalog = try ModelCatalog.init(allocator, path);
    defer catalog.deinit();
}

test "seedProviders inserts all 26 providers" {
    const allocator = std.testing.allocator;
    var catalog = try ModelCatalog.init(allocator, ":memory:");
    defer catalog.deinit();
    const stmt = try catalog.db.prepare("SELECT COUNT(*) FROM providers");
    defer catalog.db.finalize(stmt);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return error.StepFailed;
    try std.testing.expectEqual(@as(c_int, 26), db.c.sqlite3_column_int(stmt, 0));
}

test "MODELO-LOCAL: Ollama se siembra is_local=1, enabled=1 y con la URL /v1" {
    const allocator = std.testing.allocator;
    var catalog = try ModelCatalog.init(allocator, ":memory:");
    defer catalog.deinit();
    const stmt = try catalog.db.prepare("SELECT base_url, api_style, is_free_tier, enabled, is_local FROM providers WHERE name = 'Ollama'");
    defer catalog.db.finalize(stmt);
    try std.testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);
    // La URL persistida es la EFECTIVA (default u override normalizado a /v1).
    const url = std.mem.span(db.c.sqlite3_column_text(stmt, 0));
    try std.testing.expect(std.mem.endsWith(u8, url, "/v1"));
    try std.testing.expectEqualStrings("openai", std.mem.span(db.c.sqlite3_column_text(stmt, 1)));
    try std.testing.expectEqual(@as(c_int, 1), db.c.sqlite3_column_int(stmt, 2));
    // Un proveedor local está habilitado desde el seed: no hay clave que lo
    // active después.
    try std.testing.expectEqual(@as(c_int, 1), db.c.sqlite3_column_int(stmt, 3));
    try std.testing.expectEqual(@as(c_int, 1), db.c.sqlite3_column_int(stmt, 4));
}

test "MODELO-LOCAL: reconcileProviderEnabled mantiene Ollama enabled sin claves y apaga la nube" {
    const allocator = std.testing.allocator;
    var catalog = try ModelCatalog.init(allocator, ":memory:");
    defer catalog.deinit();
    // Estado previo: un proveedor de nube aparentemente habilitado y sin claves.
    try catalog.db.exec("UPDATE providers SET enabled=1 WHERE name='NVIDIA API'");
    try catalog.reconcileProviderEnabled();
    try std.testing.expect(try providerEnabled(&catalog, "Ollama"));
    try std.testing.expect(!(try providerEnabled(&catalog, "NVIDIA API")));
}

test "MODELO-LOCAL: re-seeding (reinicio del motor) reactiva un proveedor local apagado" {
    const allocator = std.testing.allocator;
    var catalog = try ModelCatalog.init(allocator, ":memory:");
    defer catalog.deinit();
    try catalog.db.exec("UPDATE providers SET enabled=0 WHERE name='Ollama'");
    try seedProviders(catalog.db);
    // La habilitación de un proveedor local no depende de api_keys: el reseed
    // lo devuelve a enabled=1.
    try std.testing.expect(try providerEnabled(&catalog, "Ollama"));
}

test "seedProviders refreshes stale provider metadata without deleting keys OR flipping enabled" {
    const allocator = std.testing.allocator;
    var catalog = try ModelCatalog.init(allocator, ":memory:");
    defer catalog.deinit();

    try catalog.db.exec("UPDATE providers SET api_style='openai', base_url='https://old.invalid', is_free_tier=1, enabled=0 WHERE name='Claude'");
    try catalog.db.exec("INSERT INTO api_keys (provider_id, label, key_ciphertext, status) SELECT id, 'default', x'010203', 'active' FROM providers WHERE name='Claude'");
    try seedProviders(catalog.db);

    const stmt = try catalog.db.prepare(
        \\SELECT p.api_style, p.base_url, p.is_free_tier, p.enabled, COUNT(k.id)
        \\FROM providers p LEFT JOIN api_keys k ON k.provider_id = p.id
        \\WHERE p.name='Claude'
        \\GROUP BY p.id
    );
    defer catalog.db.finalize(stmt);
    try std.testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);
    try std.testing.expectEqualStrings("anthropic", std.mem.span(db.c.sqlite3_column_text(stmt, 0)));
    try std.testing.expectEqualStrings("https://api.anthropic.com/v1", std.mem.span(db.c.sqlite3_column_text(stmt, 1)));
    try std.testing.expectEqual(@as(c_int, 0), db.c.sqlite3_column_int(stmt, 2));
    // enabled=0 se preserva pese al reseed, aunque haya una clave 'active' en la tabla:
    // seedProviders ya NO decide enabled (eso es trabajo de syncProviderEnabled/
    // reconcileProviderEnabled) — antes este test esperaba 1 aquí, codificando el bug
    // que revertía el catálogo a "todos habilitados" en cada arranque del motor.
    try std.testing.expectEqual(@as(c_int, 0), db.c.sqlite3_column_int(stmt, 3));
    try std.testing.expectEqual(@as(c_int, 1), db.c.sqlite3_column_int(stmt, 4));
}

test "GOBERNANZA-CATALOGO ronda 3: re-seeding (simula reinicio del motor) NO reactiva un proveedor sin clave activa" {
    const allocator = std.testing.allocator;
    var catalog = try ModelCatalog.init(allocator, ":memory:");
    defer catalog.deinit();

    // Simula el ciclo real: NVIDIA tenía clave, se quitó (enabled correctamente en 0
    // vía syncProviderEnabled — aquí lo emulamos directo ya que ese código vive en
    // credentials.zig), y el usuario cierra y reabre DevAgents (init corre otra vez).
    try catalog.db.exec("UPDATE providers SET enabled=0 WHERE name='NVIDIA API'");
    try seedProviders(catalog.db); // <- lo que ModelCatalog.init() ejecuta en cada arranque

    try std.testing.expect(!(try providerEnabled(&catalog, "NVIDIA API")));
}

test "model catalog register and list" {
    const allocator = std.testing.allocator;
    const path = ":memory:";
    var catalog = try ModelCatalog.init(allocator, path);
    defer catalog.deinit();
    // OpenRouter already seeded by init; ensure it exists (idempotent).
    try catalog.db.exec("INSERT OR IGNORE INTO providers (name, base_url, api_style, is_free_tier) VALUES ('OpenRouter', 'https://openrouter.ai/api/v1', 'openai', 1)");
    try catalog.registerModel("OpenRouter", "openai/gpt-4o", 128000, true);
    try catalog.registerModel("OpenRouter", "anthropic/claude-3.5-sonnet", 200000, true);
    const list = try catalog.listModels(allocator);
    defer allocator.free(list);
    try std.testing.expect(list.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, list, "openai/gpt-4o") != null);
}

test "model catalog list hides legacy OpenCode free flags" {
    const allocator = std.testing.allocator;
    var catalog = try ModelCatalog.init(allocator, ":memory:");
    defer catalog.deinit();
    try catalog.db.exec("UPDATE providers SET enabled=1 WHERE name='OpenCode'");
    try catalog.db.exec("INSERT INTO models (provider_id, model_name, is_free, available) SELECT id, 'future-open-model', 1, 1 FROM providers WHERE name='OpenCode'");
    try catalog.db.exec("INSERT INTO models (provider_id, model_name, is_free, available) SELECT id, 'mimo-v2.5-free', 0, 1 FROM providers WHERE name='OpenCode'");
    try catalog.db.exec("INSERT INTO models (provider_id, model_name, is_free, available) SELECT id, 'big-pickle', 1, 1 FROM providers WHERE name='OpenCode'");
    const list = try catalog.listModels(allocator);
    defer allocator.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "OpenCode | future-open-model | 0 | no") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "OpenCode | mimo-v2.5-free | 0 | no") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "OpenCode | big-pickle | 0 | yes") != null);
}

test "model catalog registerModel is idempotent and refreshes metadata" {
    const allocator = std.testing.allocator;
    var catalog = try ModelCatalog.init(allocator, ":memory:");
    defer catalog.deinit();

    try catalog.registerModel("OpenRouter", "openai/gpt-4o", 128000, true);
    try catalog.registerModel("OpenRouter", "openai/gpt-4o", 256000, false);

    const stmt = try catalog.db.prepare(
        \\SELECT COUNT(*), MAX(context_window), MAX(is_free), MAX(available)
        \\FROM models m JOIN providers p ON m.provider_id=p.id
        \\WHERE p.name='OpenRouter' AND m.model_name='openai/gpt-4o'
    );
    defer catalog.db.finalize(stmt);
    try std.testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);
    try std.testing.expectEqual(@as(c_int, 1), db.c.sqlite3_column_int(stmt, 0));
    try std.testing.expectEqual(@as(c_int, 256000), db.c.sqlite3_column_int(stmt, 1));
    try std.testing.expectEqual(@as(c_int, 0), db.c.sqlite3_column_int(stmt, 2));
    try std.testing.expectEqual(@as(c_int, 1), db.c.sqlite3_column_int(stmt, 3));
}

test "model catalog dynamic discovery from OpenAI-style JSON" {
    const allocator = std.testing.allocator;
    var catalog = try ModelCatalog.init(allocator, ":memory:");
    defer catalog.deinit();
    try catalog.db.exec("INSERT OR IGNORE INTO providers (name, base_url, api_style, is_free_tier) VALUES ('Groq', 'https://api.groq.com/openai/v1', 'openai', 1)");
    const json =
        \\{"object":"list","data":[
        \\  {"id":"llama-3.3-70b","context_length":131072},
        \\  {"id":"mixtral-8x7b","context_length":32768}
        \\]}
    ;
    const n = try catalog.discoverFromJson("Groq", json, true);
    try std.testing.expectEqual(@as(usize, 2), n);
    const list = try catalog.listModels(allocator);
    defer allocator.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "llama-3.3-70b") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "mixtral-8x7b") != null);
}

test "model catalog discovery is non-destructive across providers (fix provider-removal)" {
    const allocator = std.testing.allocator;
    var catalog = try ModelCatalog.init(allocator, ":memory:");
    defer catalog.deinit();
    try catalog.db.exec("INSERT OR IGNORE INTO providers (name, base_url, api_style, is_free_tier) VALUES ('Groq', 'https://g', 'openai', 1)");
    try catalog.db.exec("INSERT OR IGNORE INTO providers (name, base_url, api_style, is_free_tier) VALUES ('Cohere', 'https://c', 'cohere', 1)");

    _ = try catalog.discoverFromJson("Groq", "{\"data\":[{\"id\":\"llama-3.3-70b\"}]}", true);
    // Descubrir Cohere NO debe borrar los modelos de Groq.
    _ = try catalog.discoverFromJson("Cohere", "{\"data\":[{\"id\":\"command-a\"}]}", true);
    var list = try catalog.listModels(allocator);
    try std.testing.expect(std.mem.indexOf(u8, list, "llama-3.3-70b") != null);
    try std.testing.expect(std.mem.indexOf(u8, list, "command-a") != null);
    allocator.free(list);

    // Una respuesta VACÍA no debe wipear los modelos existentes del proveedor.
    const empty_n = try catalog.discoverFromJson("Groq", "{\"data\":[]}", true);
    try std.testing.expectEqual(@as(usize, 0), empty_n);
    list = try catalog.listModels(allocator);
    defer allocator.free(list);
    try std.testing.expect(std.mem.indexOf(u8, list, "llama-3.3-70b") != null);

    // Re-descubrir Groq con datos reemplaza SOLO sus modelos (idempotente, sin duplicar).
    _ = try catalog.discoverFromJson("Groq", "{\"data\":[{\"id\":\"llama-3.3-70b\"},{\"id\":\"mixtral\"}]}", true);
    const after = try catalog.listModels(allocator);
    defer allocator.free(after);
    try std.testing.expect(std.mem.indexOf(u8, after, "mixtral") != null);
    try std.testing.expect(std.mem.indexOf(u8, after, "command-a") != null); // Cohere intacto
}

test "model catalog discovery from Google-style JSON" {
    const allocator = std.testing.allocator;
    var catalog = try ModelCatalog.init(allocator, ":memory:");
    defer catalog.deinit();
    try catalog.db.exec("INSERT OR IGNORE INTO providers (name, base_url, api_style, is_free_tier) VALUES ('Google AI Studio', 'https://generativelanguage.googleapis.com/v1beta', 'google_gemini', 1)");
    const json =
        \\{"models":[{"name":"gemini-2.0-flash"},{"name":"gemini-1.5-pro"}]}
    ;
    const n = try catalog.discoverFromJson("Google AI Studio", json, true);
    try std.testing.expectEqual(@as(usize, 2), n);
}

test "model catalog discovery rejects malformed JSON" {
    const allocator = std.testing.allocator;
    var catalog = try ModelCatalog.init(allocator, ":memory:");
    defer catalog.deinit();
    try std.testing.expectError(error.InvalidJson, catalog.discoverFromJson("X", "not json", true));
}

fn modelFreeFlag(catalog: *ModelCatalog, model_name: []const u8) !i32 {
    const stmt = try catalog.db.prepare("SELECT is_free FROM models WHERE model_name = ?");
    defer catalog.db.finalize(stmt);
    try db.bindText(stmt, 1, model_name);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return error.NotFound;
    return db.c.sqlite3_column_int(stmt, 0);
}

fn modelAvailableFlag(catalog: *ModelCatalog, model_name: []const u8) !i32 {
    const stmt = try catalog.db.prepare("SELECT available FROM models WHERE model_name = ?");
    defer catalog.db.finalize(stmt);
    try db.bindText(stmt, 1, model_name);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return error.NotFound;
    return db.c.sqlite3_column_int(stmt, 0);
}

test "CK-PRV-012: la sincronización con /models registra deepseek-v4.1-flash-free con la forma gratuita y fuera de la pasarela HTTP" {
    const allocator = std.testing.allocator;
    var catalog = try ModelCatalog.init(allocator, ":memory:");
    defer catalog.deinit();
    // Fixture con la forma real de /zen/v1/models: gratis nuevos y viejos,
    // big-pickle, y dos de pago de la misma pasarela.
    const json =
        \\{"object":"list","data":[
        \\  {"id":"deepseek-v4.1-flash-free"},
        \\  {"id":"mimo-v2.5-free"},
        \\  {"id":"big-pickle"},
        \\  {"id":"deepseek-v4-pro"},
        \\  {"id":"grok-code-fast"}
        \\]}
    ;
    try std.testing.expectEqual(@as(usize, 5), try catalog.discoverFromJson("OpenCode", json, true));
    // El modelo nuevo pasa por el MISMO mecanismo que los demás gratuitos:
    // clasificado gratis por nombre (roster)…
    try std.testing.expectEqual(@as(i32, 1), try modelFreeFlag(&catalog, "deepseek-v4.1-flash-free"));
    try std.testing.expect(model_roster.isOpenCodeKnownFree("deepseek-v4.1-flash-free"));
    // …y marcado NO disponible por HTTP (solo desde la CLI).
    try std.testing.expectEqual(@as(i32, 0), try modelAvailableFlag(&catalog, "deepseek-v4.1-flash-free"));
    try std.testing.expectEqual(@as(i32, 0), try modelAvailableFlag(&catalog, "mimo-v2.5-free"));
    try std.testing.expectEqual(@as(i32, 0), try modelAvailableFlag(&catalog, "big-pickle"));
    // Los de pago de OpenCode no cambian.
    try std.testing.expectEqual(@as(i32, 1), try modelAvailableFlag(&catalog, "deepseek-v4-pro"));
    try std.testing.expectEqual(@as(i32, 1), try modelAvailableFlag(&catalog, "grok-code-fast"));
    try std.testing.expectEqualStrings("solo desde la CLI de OpenCode", HTTP_FREE_TIER_CLI_ONLY_REASON);
}

test "CK-PRV-012: el barrido de arranque apaga los gratuitos legacy y respeta pagos y otros proveedores" {
    const allocator = std.testing.allocator;
    var catalog = try ModelCatalog.init(allocator, ":memory:");
    defer catalog.deinit();
    // Estado LEGACY: filas gratuitas con available = 1 anteriores al arreglo.
    try catalog.db.exec("INSERT INTO models (provider_id, model_name, is_free, available) SELECT id, 'north-mini-code-free', 1, 1 FROM providers WHERE name='OpenCode'");
    try catalog.db.exec("INSERT INTO models (provider_id, model_name, is_free, available) SELECT id, 'big-pickle', 1, 1 FROM providers WHERE name='OpenCode'");
    try catalog.db.exec("INSERT INTO models (provider_id, model_name, is_free, available) SELECT id, 'x-free-y', 1, 1 FROM providers WHERE name='OpenCode'");
    try catalog.db.exec("INSERT INTO models (provider_id, model_name, is_free, available) SELECT id, 'deepseek-v4-pro', 0, 1 FROM providers WHERE name='OpenCode'");
    try catalog.db.exec("INSERT INTO models (provider_id, model_name, is_free, available) SELECT id, 'grok-code-fast', 0, 1 FROM providers WHERE name='OpenCode'");
    // Un gratis de OTRO proveedor no debe tocarse.
    try catalog.db.exec("INSERT INTO models (provider_id, model_name, is_free, available) SELECT id, 'command-a-03-2025', 1, 1 FROM providers WHERE name='Cohere'");

    const apagados = try enforceHttpFreeTierPolicy(catalog.db);
    try std.testing.expectEqual(@as(usize, 3), apagados);
    try std.testing.expectEqual(@as(i32, 0), try modelAvailableFlag(&catalog, "north-mini-code-free"));
    try std.testing.expectEqual(@as(i32, 0), try modelAvailableFlag(&catalog, "big-pickle"));
    try std.testing.expectEqual(@as(i32, 0), try modelAvailableFlag(&catalog, "x-free-y"));
    try std.testing.expectEqual(@as(i32, 1), try modelAvailableFlag(&catalog, "deepseek-v4-pro"));
    try std.testing.expectEqual(@as(i32, 1), try modelAvailableFlag(&catalog, "grok-code-fast"));
    try std.testing.expectEqual(@as(i32, 1), try modelAvailableFlag(&catalog, "command-a-03-2025"));
    // Idempotente: una segunda pasada no encuentra nada que apagar.
    try std.testing.expectEqual(@as(usize, 0), try enforceHttpFreeTierPolicy(catalog.db));
}

test "free-tier-first: per-model is_free from OpenRouter pricing + :free suffix" {
    const allocator = std.testing.allocator;
    var catalog = try ModelCatalog.init(allocator, ":memory:");
    defer catalog.deinit();
    try catalog.db.exec("INSERT OR IGNORE INTO providers (name, base_url, api_style, is_free_tier) VALUES ('OpenRouter', 'https://openrouter.ai/api/v1', 'openai', 1)");
    // Respuesta estilo OpenRouter: modelo de PAGO (pricing != 0), FREE por pricing 0, y FREE por sufijo :free.
    const json =
        \\{"data":[
        \\  {"id":"anthropic/claude-sonnet-5","pricing":{"prompt":"0.000003","completion":"0.000015"}},
        \\  {"id":"deepseek/deepseek-chat-v3-0324","pricing":{"prompt":"0","completion":"0"}},
        \\  {"id":"nvidia/nemotron-nano:free","pricing":{"prompt":"0.0000001","completion":"0"}}
        \\]}
    ;
    // El proveedor es free-tier (true) pero la clasificación debe ser POR MODELO.
    const n = try catalog.discoverFromJson("OpenRouter", json, true);
    try std.testing.expectEqual(@as(usize, 3), n);
    // claude-sonnet-5: pricing != 0 => PAGO (is_free=0), aunque el proveedor sea free-tier. (Antes: bug = 1)
    try std.testing.expectEqual(@as(i32, 0), try modelFreeFlag(&catalog, "anthropic/claude-sonnet-5"));
    // deepseek con pricing 0 => FREE.
    try std.testing.expectEqual(@as(i32, 1), try modelFreeFlag(&catalog, "deepseek/deepseek-chat-v3-0324"));
    // sufijo :free fuerza FREE.
    try std.testing.expectEqual(@as(i32, 1), try modelFreeFlag(&catalog, "nvidia/nemotron-nano:free"));
}

test "free-tier-first: OpenCode discovery fails closed for mixed models" {
    const allocator = std.testing.allocator;
    var catalog = try ModelCatalog.init(allocator, ":memory:");
    defer catalog.deinit();
    const json =
        \\{"data":[
        \\  {"id":"gpt-5.6"},
        \\  {"id":"claude-opus-5"},
        \\  {"id":"mimo-v2.5-free"},
        \\  {"id":"big-pickle"},
        \\  {"id":"verified-zero","pricing":{"prompt":"0","completion":"0"}},
        \\  {"id":"priced-model","pricing":{"prompt":"1","completion":"0"}}
        \\]}
    ;
    try std.testing.expectEqual(@as(usize, 6), try catalog.discoverFromJson("OpenCode", json, true));
    try std.testing.expectEqual(@as(i32, 0), try modelFreeFlag(&catalog, "gpt-5.6"));
    try std.testing.expectEqual(@as(i32, 0), try modelFreeFlag(&catalog, "claude-opus-5"));
    try std.testing.expectEqual(@as(i32, 1), try modelFreeFlag(&catalog, "mimo-v2.5-free"));
    try std.testing.expectEqual(@as(i32, 1), try modelFreeFlag(&catalog, "big-pickle"));
    try std.testing.expectEqual(@as(i32, 1), try modelFreeFlag(&catalog, "verified-zero"));
    try std.testing.expectEqual(@as(i32, 0), try modelFreeFlag(&catalog, "priced-model"));
}

test "GOBERNANZA-CATALOGO: reconcileProviderEnabled deshabilita proveedores sin clave activa, sin tocar api_keys" {
    const allocator = std.testing.allocator;
    var catalog = try ModelCatalog.init(allocator, ":memory:");
    defer catalog.deinit();

    // NVIDIA API viene seedeada (enabled=1 por defecto) pero sin ninguna clave aun.
    try catalog.db.exec("INSERT INTO api_keys (provider_id, label, key_ciphertext, status) SELECT id, 'default', x'00', 'rotated' FROM providers WHERE name='NVIDIA API'");
    try catalog.db.exec("INSERT INTO api_keys (provider_id, label, key_ciphertext, status) SELECT id, 'default', x'00', 'active' FROM providers WHERE name='Cerebras'");

    try catalog.reconcileProviderEnabled();

    const nvidia_enabled = try providerEnabled(&catalog, "NVIDIA API");
    const cerebras_enabled = try providerEnabled(&catalog, "Cerebras");
    try std.testing.expect(!nvidia_enabled); // solo tiene una clave 'rotated', no 'active'
    try std.testing.expect(cerebras_enabled);

    // No debe haber tocado ninguna fila de api_keys (solo lee, nunca escribe ahi).
    const key_count_stmt = try catalog.db.prepare("SELECT COUNT(*) FROM api_keys");
    defer catalog.db.finalize(key_count_stmt);
    try std.testing.expect(db.c.sqlite3_step(key_count_stmt) == db.c.SQLITE_ROW);
    try std.testing.expectEqual(@as(c_int, 2), db.c.sqlite3_column_int(key_count_stmt, 0));
}

fn providerEnabled(catalog: *ModelCatalog, name: []const u8) !bool {
    const stmt = try catalog.db.prepare("SELECT enabled FROM providers WHERE name = ?");
    defer catalog.db.finalize(stmt);
    try db.bindText(stmt, 1, name);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return error.NotFound;
    return db.c.sqlite3_column_int(stmt, 0) == 1;
}

test "disableConsistentNotFound marks repeated missing models unavailable" {
    var catalog = try ModelCatalog.init(std.testing.allocator, ":memory:");
    defer catalog.deinit();
    try catalog.registerModel("OpenRouter", "ghost/model:free", 0, true);
    try catalog.registerModel("OpenRouter", "healthy/model:free", 0, true);

    var runtime = try db.Connection.open(std.testing.allocator, ":memory:");
    defer runtime.close();
    const migrator = db.Migrator.init(std.testing.allocator);
    try migrator.migrate(runtime, &db.runtime_schema);
    const health_mod = @import("health.zig");
    try health_mod.record(runtime, "OpenRouter", "ghost/model:free", .not_found, 0);
    try health_mod.record(runtime, "OpenRouter", "ghost/model:free", .not_found, 0);
    try health_mod.record(runtime, "OpenRouter", "healthy/model:free", .ok, 10);

    const disabled = try catalog.disableConsistentNotFound(runtime, 2);
    try std.testing.expectEqual(@as(usize, 1), disabled);

    const stmt = try catalog.db.prepare(
        "SELECT available FROM models m JOIN providers p ON m.provider_id=p.id WHERE p.name='OpenRouter' AND m.model_name='ghost/model:free'",
    );
    defer catalog.db.finalize(stmt);
    try std.testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);
    try std.testing.expectEqual(@as(c_int, 0), db.c.sqlite3_column_int(stmt, 0));
}

fn modelFavFlag(catalog: *ModelCatalog, model_name: []const u8) !i32 {
    const stmt = try catalog.db.prepare("SELECT is_favorite FROM models WHERE model_name = ?");
    defer catalog.db.finalize(stmt);
    try db.bindText(stmt, 1, model_name);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return error.NotFound;
    return db.c.sqlite3_column_int(stmt, 0);
}

test "favoritos: familias free de alto rendimiento se marcan is_favorite; nunca los de pago ni los no-generativos" {
    const allocator = std.testing.allocator;
    var catalog = try ModelCatalog.init(allocator, ":memory:");
    defer catalog.deinit();
    try catalog.db.exec("INSERT OR IGNORE INTO providers (name, base_url, api_style, is_free_tier) VALUES ('OpenRouter', 'https://openrouter.ai/api/v1', 'openai', 1)");
    const json =
        \\{"data":[
        \\  {"id":"deepseek/deepseek-v4-flash","pricing":{"prompt":"0","completion":"0"}},
        \\  {"id":"deepseek/deepseek-chat-v3","pricing":{"prompt":"0","completion":"0"}},
        \\  {"id":"cohere/command-a-plus","pricing":{"prompt":"0","completion":"0"}},
        \\  {"id":"nvidia/nemotron-3-super:free"},
        \\  {"id":"nvidia/nemotron-3.5-content-safety:free"},
        \\  {"id":"deepseek/deepseek-v4-pro","pricing":{"prompt":"0.00001","completion":"0"}}
        \\]}
    ;
    const n = try catalog.discoverFromJson("OpenRouter", json, true);
    try std.testing.expectEqual(@as(usize, 6), n);
    // Familias curadas + free => favorito.
    try std.testing.expectEqual(@as(i32, 1), try modelFavFlag(&catalog, "deepseek/deepseek-v4-flash"));
    try std.testing.expectEqual(@as(i32, 1), try modelFavFlag(&catalog, "cohere/command-a-plus"));
    try std.testing.expectEqual(@as(i32, 1), try modelFavFlag(&catalog, "nvidia/nemotron-3-super:free"));
    // Free pero NO en la lista curada => no favorito.
    try std.testing.expectEqual(@as(i32, 0), try modelFavFlag(&catalog, "deepseek/deepseek-chat-v3"));
    // Nemotron NO generativo (content-safety) => excluido de favoritos aunque sea free.
    try std.testing.expectEqual(@as(i32, 0), try modelFavFlag(&catalog, "nvidia/nemotron-3.5-content-safety:free"));
    // Familia curada pero de PAGO (pricing != 0) => NUNCA favorito (un favorito jamás fuerza pago).
    try std.testing.expectEqual(@as(i32, 0), try modelFreeFlag(&catalog, "deepseek/deepseek-v4-pro"));
    try std.testing.expectEqual(@as(i32, 0), try modelFavFlag(&catalog, "deepseek/deepseek-v4-pro"));
}

test "CK-PRV-004 C2 discovery persists output capability metadata" {
    const a = std.testing.allocator;
    var c = try ModelCatalog.init(a, ":memory:");
    defer c.deinit();
    try c.db.exec("INSERT INTO providers(name,base_url,api_style) VALUES('Fixture','http://fixture','openai')");
    _ = try c.discoverFromJson("Fixture", "{\"data\":[{\"id\":\"opaque-encoder\",\"architecture\":{\"output_modalities\":[\"embedding\"]}},{\"id\":\"vision-chat\",\"modalities\":{\"output\":[\"text\"]}}]}", true);
    const stmt = try c.db.prepare("SELECT is_generative FROM models WHERE model_name='opaque-encoder'");
    defer c.db.finalize(stmt);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(c_int, 0), db.c.sqlite3_column_int(stmt, 0));
}
