const std = @import("std");
const Io = std.Io;
const db = @import("db.zig");

const GetTickCount64 = @import("platform.zig").ticks;
const Sleep = @import("platform.zig").sleep;

pub const DiscoveryError = error{
    OutOfMemory,
    ScanError,
    ParseError,
    InvalidJson,
    InvalidFrontmatter,
    AccessDenied,
    SystemResources,
    PermissionDenied,
    Canceled,
    Unexpected,
};

pub const ResourceKind = enum {
    skill,
    agent,
    mcp_server,
    mcp_tool,
    plugin,
    webhook,
};

pub const Cost = enum {
    cheap,
    expensive,

    pub fn toText(self: Cost) []const u8 {
        return switch (self) {
            .cheap => "cheap",
            .expensive => "expensive",
        };
    }
};

pub const Resource = struct {
    kind: ResourceKind,
    name: []const u8,
    path: []const u8,
    description: []const u8,
    source_root: []const u8,
    /// P12-T1: cost estimate (cheap = local/skill, expensive = external API call).
    cost: Cost = .cheap,
    /// P12-T1: human-readable source identifier (e.g. "local-skill", "mcp:open-design").
    source: []const u8 = "",

    pub fn deinit(self: *const Resource, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.path);
        allocator.free(self.description);
        allocator.free(self.source_root);
        if (self.source.len > 0) allocator.free(self.source);
    }
};

pub const Inventory = struct {
    resources: []Resource,
    warnings: [][]const u8,

    pub fn deinit(self: *const Inventory, allocator: std.mem.Allocator) void {
        for (self.resources) |r| r.deinit(allocator);
        allocator.free(self.resources);
        for (self.warnings) |w| allocator.free(w);
        allocator.free(self.warnings);
    }

    /// Serializa el inventario a JSON consultable (FR-002). El llamador libera el slice.
    /// Usa `std.json.Stringify` (escape correcto; nunca concatena strings sin escapar).
    pub fn toJson(self: *const Inventory, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try js.beginObject();
        try js.objectField("resources");
        try js.beginArray();
        for (self.resources) |r| {
            try js.beginObject();
            try js.objectField("kind");
            try js.write(@tagName(r.kind));
            try js.objectField("name");
            try js.write(r.name);
            try js.objectField("path");
            try js.write(r.path);
            try js.objectField("description");
            try js.write(r.description);
            try js.objectField("source_root");
            try js.write(r.source_root);
            try js.objectField("cost");
            try js.write(r.cost.toText());
            try js.objectField("source");
            try js.write(r.source);
            try js.endObject();
        }
        try js.endArray();
        try js.objectField("warnings");
        try js.beginArray();
        for (self.warnings) |w| try js.write(w);
        try js.endArray();
        try js.endObject();
        return allocator.dupe(u8, out.written());
    }
};

pub const DiscoverySelection = struct {
    needed: []Resource,
    missing: [][]const u8,
    not_needed_reason: []const u8,
    warnings: [][]const u8,

    pub fn deinit(self: *const DiscoverySelection, allocator: std.mem.Allocator) void {
        for (self.needed) |r| r.deinit(allocator);
        allocator.free(self.needed);
        for (self.missing) |m| allocator.free(m);
        allocator.free(self.missing);
        allocator.free(self.not_needed_reason);
        for (self.warnings) |w| allocator.free(w);
        allocator.free(self.warnings);
    }
};

pub const DiscoveryBackend = struct {
    ptr: *anyopaque,
    selectFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, order: []const u8, inventory: *const Inventory) DiscoveryError!DiscoverySelection,
    deinitFn: *const fn (ctx: *anyopaque) void,

    pub fn select(self: DiscoveryBackend, allocator: std.mem.Allocator, order: []const u8, inventory: *const Inventory) DiscoveryError!DiscoverySelection {
        return self.selectFn(self.ptr, allocator, order, inventory);
    }

    pub fn deinit(self: DiscoveryBackend) void {
        self.deinitFn(self.ptr);
    }
};

pub const KeywordDiscovery = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) KeywordDiscovery {
        return .{ .allocator = allocator };
    }

    pub fn backend(self: *KeywordDiscovery) DiscoveryBackend {
        return .{
            .ptr = self,
            .selectFn = selectByKeywords,
            .deinitFn = noopDeinit,
        };
    }

    fn selectByKeywords(ctx: *anyopaque, allocator: std.mem.Allocator, order: []const u8, inventory: *const Inventory) DiscoveryError!DiscoverySelection {
        _ = ctx;
        const lower = try std.ascii.allocLowerString(allocator, order);
        defer allocator.free(lower);

        var needed = std.ArrayList(Resource).empty;
        errdefer {
            for (needed.items) |r| r.deinit(allocator);
            needed.deinit(allocator);
        }
        var missing = std.ArrayList([]const u8).empty;
        errdefer {
            for (missing.items) |m| allocator.free(m);
            missing.deinit(allocator);
        }
        var warnings = std.ArrayList([]const u8).empty;
        errdefer {
            for (warnings.items) |w| allocator.free(w);
            warnings.deinit(allocator);
        }

        var found_needed = false;

        // Un recurso es relevante si comparte al menos una palabra significativa
        // (≥3 chars, no stopword) con la orden, en su nombre o su descripción.
        // Así la selección depende de la orden (no de una lista fija de keywords).
        for (inventory.resources) |resource| {
            const needed_this = try resourceMatchesOrder(allocator, lower, resource);
            if (needed_this) {
                found_needed = true;
                try needed.append(allocator, .{
                    .kind = resource.kind,
                    .name = try allocator.dupe(u8, resource.name),
                    .path = try allocator.dupe(u8, resource.path),
                    .description = try allocator.dupe(u8, resource.description),
                    .source_root = try allocator.dupe(u8, resource.source_root),
                    .cost = resource.cost,
                    .source = if (resource.source.len > 0) try allocator.dupe(u8, resource.source) else try allocator.dupe(u8, ""),
                });
            }
        }

        // Capacidades requeridas por la orden sin recurso que las cubra → missing[].
        // (FR-004, US2-escenario-2): se reporta el hueco, no se inventa un recurso.
        for (CAPABILITY_VOCAB) |cap| {
            if (!containsToken(lower, cap.trigger)) continue;
            var covered = false;
            for (needed.items) |r| {
                if (try resourceCoversCapability(allocator, r, cap.match)) {
                    covered = true;
                    break;
                }
            }
            if (!covered) {
                try missing.append(allocator, try allocator.dupe(u8, cap.capability));
            }
        }

        const reason = if (found_needed) "coincidencia de palabras de la orden" else "ningún recurso relevante para la orden";
        return DiscoverySelection{
            .needed = try needed.toOwnedSlice(allocator),
            .missing = try missing.toOwnedSlice(allocator),
            .not_needed_reason = try allocator.dupe(u8, reason),
            .warnings = try warnings.toOwnedSlice(allocator),
        };
    }

    fn noopDeinit(_: *anyopaque) void {}
};

// ── P12-T2: LlmDiscovery — selector agéntico con pre-filtro + LLM + fallback ──

/// Deadline duro para la llamada LLM del selector (10s).
pub const SELECTOR_TIMEOUT_MS: u64 = 10_000;

/// Máximo de candidatos del pre-filtro (escalabilidad: prompt pequeño aunque haya 300 skills).
pub const MAX_CANDIDATES: usize = 20;

/// Function type para la llamada LLM del selector.
/// `system_prompt` + `user_prompt` → JSON string (o "" si falla).
pub const LlmCallFn = *const fn (ctx: *anyopaque, system_prompt: []const u8, user_prompt: []const u8) []const u8;

/// Backend de descubrimiento basado en LLM. Implementa `DiscoveryBackend`.
/// Pipeline: pre-filtro top-N (KeywordDiscovery) → prompt pequeño → LLM barato → JSON → validar → fallback si falla.
pub const LlmDiscovery = struct {
    allocator: std.mem.Allocator,
    /// Función y contexto para la llamada LLM (típicamente LiveLlm.completeObject).
    llm_ctx: ?*anyopaque,
    llm_fn: ?LlmCallFn,
    /// Fallback keyword (siempre presente; el sistema NUNCA se queda sin selección).
    keyword: KeywordDiscovery,
    /// P12-T5: Score store opcional para weighting del pre-filtro.
    score_store: ?*ToolScoreStore = null,

    pub fn init(allocator: std.mem.Allocator) LlmDiscovery {
        return .{
            .allocator = allocator,
            .llm_ctx = null,
            .llm_fn = null,
            .keyword = KeywordDiscovery.init(allocator),
        };
    }

    /// Configura la llamada LLM. `ctx` es opaque (típicamente *LiveLlm).
    pub fn setLlm(self: *LlmDiscovery, ctx: *anyopaque, call_fn: LlmCallFn) void {
        self.llm_ctx = ctx;
        self.llm_fn = call_fn;
    }

    pub fn backend(self: *LlmDiscovery) DiscoveryBackend {
        return .{
            .ptr = @ptrCast(self),
            .selectFn = selectImpl,
            .deinitFn = noopDeinitLlm,
        };
    }

    fn noopDeinitLlm(_: *anyopaque) void {}

    fn selectImpl(ctx: *anyopaque, allocator: std.mem.Allocator, order: []const u8, inventory: *const Inventory) DiscoveryError!DiscoverySelection {
        const self: *LlmDiscovery = @ptrCast(@alignCast(ctx));

        // Si no hay LLM configurado → fallback directo a keyword.
        if (self.llm_fn == null or self.llm_ctx == null) {
            return self.keywordSelect(allocator, order, inventory);
        }

        // 1. Pre-filtro determinista: top-N candidatos del inventario.
        const candidates = topNCandidates(allocator, order, inventory, MAX_CANDIDATES) catch {
            return self.keywordSelect(allocator, order, inventory);
        };
        defer {
            for (candidates) |r| r.deinit(allocator);
            allocator.free(candidates);
        }

        // 2. Construir prompt del selector.
        const prompt = buildSelectorPrompt(allocator, order, candidates) catch {
            return self.keywordSelect(allocator, order, inventory);
        };
        defer allocator.free(prompt);
        const system_prompt = "You are a tool selector. Given a user order and a list of available tools, decide which tools are needed. Respond as JSON: {\"skills\":[],\"mcps\":[],\"none_needed\":false,\"reason\":\"one line\"}. Only include tool names that exist in the list. For trivial tasks, set none_needed=true.";

        // 3. Llamada LLM con timeout duro.
        const llm_result = callLlmWithTimeout(self.llm_ctx.?, self.llm_fn.?, system_prompt, prompt, SELECTOR_TIMEOUT_MS);

        if (llm_result.len == 0) {
            // Timeout o error → fallback keyword.
            return self.keywordSelect(allocator, order, inventory);
        }

        // 4. Parsear JSON del selector.
        const parsed = parseSelectorJson(allocator, llm_result, inventory) catch {
            // JSON inválido → fallback keyword.
            return self.keywordSelect(allocator, order, inventory);
        };

        // 5. Si none_needed → devolver vacío con reason.
        if (parsed.none_needed) {
            var warnings = std.ArrayList([]const u8).empty;
            const w = allocator.dupe(u8, "selector-llm: none_needed") catch "";
            warnings.append(allocator, w) catch {};
            return DiscoverySelection{
                .needed = try allocator.alloc(Resource, 0),
                .missing = try allocator.alloc([]const u8, 0),
                .not_needed_reason = parsed.reason,
                .warnings = try warnings.toOwnedSlice(allocator),
            };
        }

        // 6. Validar que los nombres existen en el inventario y construir Resources.
        var needed = std.ArrayList(Resource).empty;
        for (parsed.skills) |skill_name| {
            if (findResource(inventory, skill_name)) |r| {
                needed.append(allocator, .{
                    .kind = r.kind,
                    .name = allocator.dupe(u8, r.name) catch continue,
                    .path = allocator.dupe(u8, r.path) catch continue,
                    .description = allocator.dupe(u8, r.description) catch continue,
                    .source_root = allocator.dupe(u8, r.source_root) catch continue,
                    .cost = r.cost,
                    .source = if (r.source.len > 0) allocator.dupe(u8, r.source) catch "" else "",
                }) catch continue;
            }
        }
        for (parsed.mcps) |mcp_name| {
            if (findResource(inventory, mcp_name)) |r| {
                needed.append(allocator, .{
                    .kind = r.kind,
                    .name = allocator.dupe(u8, r.name) catch continue,
                    .path = allocator.dupe(u8, r.path) catch continue,
                    .description = allocator.dupe(u8, r.description) catch continue,
                    .source_root = allocator.dupe(u8, r.source_root) catch continue,
                    .cost = r.cost,
                    .source = if (r.source.len > 0) allocator.dupe(u8, r.source) catch "" else "",
                }) catch continue;
            }
        }

        // Si el LLM no seleccionó nada válido → fallback keyword.
        if (needed.items.len == 0) {
            for (needed.items) |r| r.deinit(allocator);
            needed.deinit(allocator);
            return self.keywordSelect(allocator, order, inventory);
        }

        var warnings = std.ArrayList([]const u8).empty;
        const w = allocator.dupe(u8, "selector-llm") catch "";
        warnings.append(allocator, w) catch {};

        return DiscoverySelection{
            .needed = try needed.toOwnedSlice(allocator),
            .missing = try allocator.alloc([]const u8, 0),
            .not_needed_reason = parsed.reason,
            .warnings = try warnings.toOwnedSlice(allocator),
        };
    }

    /// Fallback: usa KeywordDiscovery.
    fn keywordSelect(self: *LlmDiscovery, allocator: std.mem.Allocator, order: []const u8, inventory: *const Inventory) DiscoveryError!DiscoverySelection {
        const sel = try self.keyword.backend().select(allocator, order, inventory);
        // Añadir warning de fallback.
        var warnings = std.ArrayList([]const u8).empty;
        for (sel.warnings) |w| warnings.append(allocator, allocator.dupe(u8, w) catch "") catch {};
        const fb = allocator.dupe(u8, "fallback: keyword discovery (LLM unavailable or timeout)") catch "";
        warnings.append(allocator, fb) catch {};
        allocator.free(sel.warnings);
        return .{
            .needed = sel.needed,
            .missing = sel.missing,
            .not_needed_reason = sel.not_needed_reason,
            .warnings = try warnings.toOwnedSlice(allocator),
        };
    }

    /// P12-T3: Selección por-tarea usando el LLM. Recibe la orden + lista de tareas + inventario.
    /// Devuelve una selección por tarea (TaskSelection[]). El caller libera cada elemento.
    /// Si el LLM no está configurado o falla, hace fallback a keyword por-tarea (todas las tareas
    /// reciben las mismas herramientas que la selección keyword de la orden).
    pub fn selectPerTask(
        self: *LlmDiscovery,
        allocator: std.mem.Allocator,
        order: []const u8,
        task_ids: []const []const u8,
        task_descriptions: []const []const u8,
        inventory: *const Inventory,
    ) ![]TaskSelection {
        // Sin LLM → fallback: una selección keyword para todas las tareas.
        if (self.llm_fn == null or self.llm_ctx == null) {
            return self.keywordSelectPerTask(allocator, order, task_ids, inventory);
        }

        // 1. Pre-filtro top-N (P12-T5: weighted by historical scores if available).
        var score_map: ?std.StringHashMap(f64) = null;
        if (self.score_store) |store| {
            // Use first task_type for pre-filter weighting (good enough for candidate ranking).
            score_map = store.getScoresForTaskType(allocator, "programar") catch null;
        }
        defer if (score_map) |*sm| {
            var it = sm.iterator();
            while (it.next()) |entry| allocator.free(entry.key_ptr.*);
            sm.deinit();
        };
        const candidates = if (score_map != null)
            topNCandidatesWithScores(allocator, order, inventory, MAX_CANDIDATES, &score_map.?) catch {
                return self.keywordSelectPerTask(allocator, order, task_ids, inventory);
            }
        else
            topNCandidates(allocator, order, inventory, MAX_CANDIDATES) catch {
                return self.keywordSelectPerTask(allocator, order, task_ids, inventory);
            };
        defer {
            for (candidates) |r| r.deinit(allocator);
            allocator.free(candidates);
        }

        // 2. Construir prompt con orden + tareas + candidatos.
        const prompt = buildPerTaskPrompt(allocator, order, task_ids, task_descriptions, candidates) catch {
            return self.keywordSelectPerTask(allocator, order, task_ids, inventory);
        };
        defer allocator.free(prompt);
        const system_prompt = "You are a tool selector. Given a user order, a list of tasks, and available tools, decide which tools each task needs. Respond as JSON array: [{\"task_id\":\"...\",\"skills\":[],\"mcps\":[],\"none_needed\":false,\"reason\":\"one line\"}]. Only include tool names from the list. For trivial tasks, set none_needed=true.";

        // 3. Llamada LLM.
        const llm_result = callLlmWithTimeout(self.llm_ctx.?, self.llm_fn.?, system_prompt, prompt, SELECTOR_TIMEOUT_MS);
        if (llm_result.len == 0) {
            return self.keywordSelectPerTask(allocator, order, task_ids, inventory);
        }

        // 4. Parsear JSON array de selecciones por-tarea.
        const parsed = parsePerTaskJson(allocator, llm_result, inventory, task_ids) catch {
            return self.keywordSelectPerTask(allocator, order, task_ids, inventory);
        };

        // 5. Validar que cada tarea tiene su selección; si falta alguna, fallback.
        if (parsed.len != task_ids.len) {
            for (parsed) |*ts| ts.deinit(allocator);
            allocator.free(parsed);
            return self.keywordSelectPerTask(allocator, order, task_ids, inventory);
        }

        return parsed;
    }

    /// Fallback keyword per-tarea: todas las tareas reciben la misma selección keyword.
    fn keywordSelectPerTask(
        self: *LlmDiscovery,
        allocator: std.mem.Allocator,
        order: []const u8,
        task_ids: []const []const u8,
        inventory: *const Inventory,
    ) ![]TaskSelection {
        const sel = try self.keyword.backend().select(allocator, order, inventory);
        defer sel.deinit(allocator);

        var results = try allocator.alloc(TaskSelection, task_ids.len);
        for (task_ids, 0..) |tid, i| {
            const needed = try allocator.alloc(Resource, sel.needed.len);
            for (sel.needed, 0..) |r, j| {
                needed[j] = .{
                    .kind = r.kind,
                    .name = try allocator.dupe(u8, r.name),
                    .path = try allocator.dupe(u8, r.path),
                    .description = try allocator.dupe(u8, r.description),
                    .source_root = try allocator.dupe(u8, r.source_root),
                    .cost = r.cost,
                    .source = if (r.source.len > 0) try allocator.dupe(u8, r.source) else try allocator.dupe(u8, ""),
                };
            }
            results[i] = .{
                .task_id = try allocator.dupe(u8, tid),
                .needed = needed,
                .none_needed = sel.needed.len == 0,
                .reason = try allocator.dupe(u8, sel.not_needed_reason),
            };
        }
        return results;
    }
};

/// Construye el prompt del selector por-tarea: orden + tareas + candidatos.
fn buildPerTaskPrompt(
    allocator: std.mem.Allocator,
    order: []const u8,
    task_ids: []const []const u8,
    task_descriptions: []const []const u8,
    candidates: []const Resource,
) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const header = try std.fmt.allocPrint(allocator, "Order: {s}\n\nTasks:\n", .{order});
    defer allocator.free(header);
    try out.appendSlice(allocator, header);
    for (task_ids, task_descriptions) |tid, desc| {
        const line = try std.fmt.allocPrint(allocator, "- {s}: {s}\n", .{ tid, desc });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }
    try out.appendSlice(allocator, "\nAvailable tools:\n");
    for (candidates) |r| {
        const line = try std.fmt.allocPrint(allocator, "- [{s}] {s}: {s}\n", .{ @tagName(r.kind), r.name, r.description });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }
    try out.appendSlice(allocator, "\nRespond as JSON array: [{\"task_id\":\"...\",\"skills\":[\"name\"],\"mcps\":[\"name\"],\"none_needed\":false,\"reason\":\"one line\"}]\n");
    return out.toOwnedSlice(allocator);
}

/// Parsea el JSON array de selecciones por-tarea del LLM.
/// Valida nombres contra el inventario y task_ids contra los esperados.
fn parsePerTaskJson(
    allocator: std.mem.Allocator,
    raw: []const u8,
    inventory: *const Inventory,
    expected_task_ids: []const []const u8,
) ![]TaskSelection {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    if (parsed.value != .array) return error.InvalidJson;
    const arr = parsed.value.array.items;

    var results = std.ArrayList(TaskSelection).empty;
    for (arr) |item| {
        if (item != .object) continue;
        const obj = item.object;

        const task_id = blk: {
            if (obj.get("task_id")) |t| {
                if (t == .string) break :blk t.string;
            }
            continue;
        };

        // Validar que el task_id existe en los esperados.
        var found = false;
        for (expected_task_ids) |etid| {
            if (std.mem.eql(u8, task_id, etid)) {
                found = true;
                break;
            }
        }
        if (!found) continue;

        var needed = std.ArrayList(Resource).empty;

        if (obj.get("skills")) |s| {
            if (s == .array) {
                for (s.array.items) |sk| {
                    if (sk == .string) {
                        if (findResource(inventory, sk.string)) |r| {
                            needed.append(allocator, .{
                                .kind = r.kind,
                                .name = allocator.dupe(u8, r.name) catch continue,
                                .path = allocator.dupe(u8, r.path) catch continue,
                                .description = allocator.dupe(u8, r.description) catch continue,
                                .source_root = allocator.dupe(u8, r.source_root) catch continue,
                                .cost = r.cost,
                                .source = if (r.source.len > 0) allocator.dupe(u8, r.source) catch "" else "",
                            }) catch continue;
                        }
                    }
                }
            }
        }

        if (obj.get("mcps")) |m| {
            if (m == .array) {
                for (m.array.items) |mc| {
                    if (mc == .string) {
                        if (findResource(inventory, mc.string)) |r| {
                            needed.append(allocator, .{
                                .kind = r.kind,
                                .name = allocator.dupe(u8, r.name) catch continue,
                                .path = allocator.dupe(u8, r.path) catch continue,
                                .description = allocator.dupe(u8, r.description) catch continue,
                                .source_root = allocator.dupe(u8, r.source_root) catch continue,
                                .cost = r.cost,
                                .source = if (r.source.len > 0) allocator.dupe(u8, r.source) catch "" else "",
                            }) catch continue;
                        }
                    }
                }
            }
        }

        const none_needed = if (obj.get("none_needed")) |n| blk: {
            if (n == .bool) break :blk n.bool;
            break :blk false;
        } else false;

        const reason = if (obj.get("reason")) |r| blk: {
            if (r == .string) break :blk try allocator.dupe(u8, r.string);
            break :blk try allocator.dupe(u8, "");
        } else try allocator.dupe(u8, "");

        try results.append(allocator, .{
            .task_id = try allocator.dupe(u8, task_id),
            .needed = try needed.toOwnedSlice(allocator),
            .none_needed = none_needed,
            .reason = reason,
        });
    }

    return results.toOwnedSlice(allocator);
}

/// Construye el prompt del selector: orden + lista de candidatos con descripciones de 1 línea.
fn buildSelectorPrompt(allocator: std.mem.Allocator, order: []const u8, candidates: []const Resource) ![]u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    const header = try std.fmt.allocPrint(allocator, "Order: {s}\n\nAvailable tools:\n", .{order});
    defer allocator.free(header);
    try out.appendSlice(allocator, header);
    for (candidates) |r| {
        const line = try std.fmt.allocPrint(allocator, "- [{s}] {s}: {s}\n", .{ @tagName(r.kind), r.name, r.description });
        defer allocator.free(line);
        try out.appendSlice(allocator, line);
    }
    try out.appendSlice(allocator, "\nRespond as JSON: {\"skills\":[\"name1\"],\"mcps\":[\"name2\"],\"none_needed\":false,\"reason\":\"one line\"}\n");
    return out.toOwnedSlice(allocator);
}

/// Llama al selector de herramientas. El nombre conserva "WithTimeout" porque
/// el plazo sigue existiendo, pero AHORA lo impone la propia llamada al modelo
/// y no un vigilante externo.
///
/// ANTES: se lanzaba un hilo y, al vencer `timeout_ms` (10 s), se hacia
/// `t.detach()` y se retornaba. Ese hilo abandonado seguia usando `ctx`, que es
/// un `*LiveLlm` que el llamador tiene EN LA PILA (superagent.zig:
/// `var llm_opt = LiveLlm.initForced(...)` con su `defer llm.deinit()`). En
/// cuanto la tarea terminaba, el huerfano escribia sobre un marco muerto.
/// Reproducido tres veces, con la pila resuelta contra el .pdb:
///
///   clearRetainingCapacity  <- callWithTimeout <- llmFn <- run (este hilo)
///   recordHealth            <- llmFn           <- run (este hilo)
///   emitContentDelta        <- callTimedDirect <- callTimedThread
///
/// Es el patron que ningun entorno serio usa: en Go, Rust o .NET el plazo va
/// atado a la operacion (context / CancellationToken) y la operacion se CANCELA
/// y se desenrolla; nadie abandona un hilo que sostiene un puntero prestado.
/// Aqui el cliente HTTP no tiene cancelacion, asi que la alternativa correcta es
/// no abandonar: se llama en el hilo del llamador. El plazo real lo pone
/// `LiveLlm.callWithTimeout` por candidato, y `llmFn` degrada al siguiente
/// proveedor ante un fallo, de modo que la llamada sigue acotada.
fn callLlmWithTimeout(ctx: *anyopaque, call_fn: LlmCallFn, system_prompt: []const u8, user_prompt: []const u8, timeout_ms: u64) []const u8 {
    _ = timeout_ms;
    return call_fn(ctx, system_prompt, user_prompt);
}

/// Resultado parseado del JSON del selector LLM.
const ParsedSelection = struct {
    skills: [][]const u8,
    mcps: [][]const u8,
    none_needed: bool,
    reason: []const u8,
};

/// Parsea el JSON devuelto por el LLM selector.
/// Valida que los nombres existan en el inventario (descarta los que no).
fn parseSelectorJson(allocator: std.mem.Allocator, raw: []const u8, inventory: *const Inventory) !ParsedSelection {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, raw, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidJson;
    const obj = parsed.value.object;

    var skills = std.ArrayList([]const u8).empty;
    var mcps = std.ArrayList([]const u8).empty;

    if (obj.get("skills")) |s| {
        if (s == .array) {
            for (s.array.items) |item| {
                if (item == .string) {
                    // Solo incluir si existe en el inventario.
                    if (findResource(inventory, item.string) != null) {
                        try skills.append(allocator, try allocator.dupe(u8, item.string));
                    }
                }
            }
        }
    }

    if (obj.get("mcps")) |m| {
        if (m == .array) {
            for (m.array.items) |item| {
                if (item == .string) {
                    if (findResource(inventory, item.string) != null) {
                        try mcps.append(allocator, try allocator.dupe(u8, item.string));
                    }
                }
            }
        }
    }

    const none_needed = if (obj.get("none_needed")) |n| blk: {
        if (n == .bool) break :blk n.bool;
        break :blk false;
    } else false;

    const reason = if (obj.get("reason")) |r| blk: {
        if (r == .string) break :blk try allocator.dupe(u8, r.string);
        break :blk try allocator.dupe(u8, "");
    } else try allocator.dupe(u8, "");

    return ParsedSelection{
        .skills = try skills.toOwnedSlice(allocator),
        .mcps = try mcps.toOwnedSlice(allocator),
        .none_needed = none_needed,
        .reason = reason,
    };
}

/// Busca un recurso por nombre en el inventario.
fn findResource(inventory: *const Inventory, name: []const u8) ?*const Resource {
    for (inventory.resources) |*r| {
        if (std.mem.eql(u8, r.name, name)) return r;
    }
    return null;
}

/// Vocabulario de capacidades: si la orden menciona `trigger`, se requiere un recurso
/// cuyo nombre/descripción contenga `match`; de no haberlo, se reporta `capability` como hueco.
const Capability = struct { trigger: []const u8, match: []const u8, capability: []const u8 };
const CAPABILITY_VOCAB = [_]Capability{
    .{ .trigger = "test", .match = "test", .capability = "testing" },
    .{ .trigger = "prueba", .match = "test", .capability = "testing" },
    .{ .trigger = "lint", .match = "lint", .capability = "linting" },
    .{ .trigger = "review", .match = "review", .capability = "code-review" },
    .{ .trigger = "audit", .match = "review", .capability = "code-review" },
    .{ .trigger = "deploy", .match = "ci", .capability = "deployment" },
    .{ .trigger = "memoria", .match = "engram", .capability = "memory" },
    .{ .trigger = "memory", .match = "engram", .capability = "memory" },
    .{ .trigger = "format", .match = "format", .capability = "formatting" },
    .{ .trigger = "security", .match = "security", .capability = "security-scan" },
    .{ .trigger = "seguridad", .match = "security", .capability = "security-scan" },
};

/// Indica si el recurso comparte alguna palabra significativa con la orden (en minúsculas).
fn resourceMatchesOrder(allocator: std.mem.Allocator, order_lower: []const u8, resource: Resource) DiscoveryError!bool {
    const name_lower = try std.ascii.allocLowerString(allocator, resource.name);
    defer allocator.free(name_lower);
    if (try sharesSignificantWord(allocator, order_lower, name_lower)) return true;
    if (resource.description.len > 0) {
        const desc_lower = try std.ascii.allocLowerString(allocator, resource.description);
        defer allocator.free(desc_lower);
        if (try sharesSignificantWord(allocator, order_lower, desc_lower)) return true;
    }
    return false;
}

/// Indica si el recurso (nombre o descripción) contiene el término `match`.
fn resourceCoversCapability(allocator: std.mem.Allocator, resource: Resource, match: []const u8) DiscoveryError!bool {
    const name_lower = try std.ascii.allocLowerString(allocator, resource.name);
    defer allocator.free(name_lower);
    if (std.mem.indexOf(u8, name_lower, match) != null) return true;
    if (resource.description.len > 0) {
        const desc_lower = try std.ascii.allocLowerString(allocator, resource.description);
        defer allocator.free(desc_lower);
        if (std.mem.indexOf(u8, desc_lower, match) != null) return true;
    }
    return false;
}

/// True si `text` contiene alguna palabra (≥3 chars, no stopword) presente en `order_lower`.
/// Las palabras se delimitan por no-alfanuméricos (`-`, `_`, `.`, espacios, etc.).
fn sharesSignificantWord(allocator: std.mem.Allocator, order_lower: []const u8, text: []const u8) DiscoveryError!bool {
    var text_it = std.mem.tokenizeAny(u8, text, " \t\r\n-_./,:;()[]{}");
    while (text_it.next()) |tw| {
        if (tw.len < 3 or isStopword(tw)) continue;
        var order_it = std.mem.tokenizeAny(u8, order_lower, " \t\r\n-_./,:;()[]{}");
        while (order_it.next()) |ow| {
            if (ow.len < 3 or isStopword(ow)) continue;
            if (std.mem.eql(u8, ow, tw)) return true;
        }
    }
    _ = allocator;
    return false;
}

/// True si `text` contiene `token` como subcadena (para disparadores de capacidad).
fn containsToken(text: []const u8, token: []const u8) bool {
    return std.mem.indexOf(u8, text, token) != null;
}

fn isStopword(w: []const u8) bool {
    const stops = [_][]const u8{ "the", "for", "and", "una", "con", "por", "los", "las", "del", "que", "como", "para" };
    for (stops) |s| {
        if (std.mem.eql(u8, w, s)) return true;
    }
    return false;
}

/// Escanea una sola raíz. Conveniencia sobre `scanRoots`.
pub fn scanRoot(allocator: std.mem.Allocator, io: Io, root_path: []const u8) DiscoveryError!Inventory {
    return scanRoots(allocator, io, &.{root_path});
}

/// Escanea N raíces y FUSIONA los recursos en un único inventario (US1-escenario-2,
/// preparación de carpetas vinculadas de F8). Cada recurso conserva su `source_root`.
pub fn scanRoots(allocator: std.mem.Allocator, io: Io, roots: []const []const u8) DiscoveryError!Inventory {
    var resources = std.ArrayList(Resource).empty;
    errdefer {
        for (resources.items) |r| r.deinit(allocator);
        resources.deinit(allocator);
    }
    var warns = std.ArrayList([]const u8).empty;
    errdefer {
        for (warns.items) |w| allocator.free(w);
        warns.deinit(allocator);
    }

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const arena_alloc = arena.allocator();

    for (roots) |root_path| {
        const root_dir = Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch {
            const msg = try std.fmt.allocPrint(allocator, "cannot open root: {s}", .{root_path});
            try warns.append(allocator, msg);
            continue;
        };
        defer root_dir.close(io);
        try scanDir(arena_alloc, allocator, io, root_dir, root_path, &resources, &warns);
    }

    return Inventory{
        .resources = try resources.toOwnedSlice(allocator),
        .warnings = try warns.toOwnedSlice(allocator),
    };
}

fn scanDir(arena_alloc: std.mem.Allocator, allocator: std.mem.Allocator, io: Io, dir: Io.Dir, rel_path: []const u8, resources: *std.ArrayList(Resource), warns: *std.ArrayList([]const u8)) DiscoveryError!void {
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .directory) {
            if (entry.name.len > 0 and entry.name[0] == '.' and !std.mem.eql(u8, entry.name, ".claude")) continue;
            const sub_path = try std.fs.path.join(arena_alloc, &.{ rel_path, entry.name });
            const sub_dir = dir.openDir(io, entry.name, .{ .iterate = true }) catch continue;
            defer sub_dir.close(io);
            try scanDir(arena_alloc, allocator, io, sub_dir, sub_path, resources, warns);
            continue;
        }

        const file_path = try std.fs.path.join(arena_alloc, &.{ rel_path, entry.name });
        const name = entry.name;

        // Skills: SKILL.md files
        if (std.mem.eql(u8, name, "SKILL.md")) {
            if (tryFrontmatterSkill(allocator, arena_alloc, io, dir, name, rel_path)) |r| {
                try resources.append(allocator, r);
            } else |_| {
                const msg = try std.fmt.allocPrint(allocator, "bad frontmatter in {s}", .{file_path});
                try warns.append(allocator, msg);
            }
            continue;
        }

        // Agents: .md files with frontmatter in agents directories
        if (std.mem.endsWith(u8, name, ".md") and
            (std.mem.indexOf(u8, rel_path, ".claude") != null or std.mem.indexOf(u8, rel_path, "agents") != null))
        {
            if (tryFrontmatterAgent(allocator, arena_alloc, io, dir, name, rel_path)) |r| {
                try resources.append(allocator, r);
            } else |_| {
                // Not an agent (no frontmatter), skip silently
            }
            continue;
        }

        // MCP configs
        if (std.mem.eql(u8, name, "mcp.json")) {
            if (tryParseMcpConfig(allocator, arena_alloc, io, dir, name, rel_path)) |entries| {
                for (entries) |r| try resources.append(allocator, r);
                allocator.free(entries);
            } else |_| {
                const msg = try std.fmt.allocPrint(allocator, "bad MCP config in {s}", .{file_path});
                try warns.append(allocator, msg);
            }
            continue;
        }

        // Plugin manifests
        if (std.mem.endsWith(u8, name, ".daplugin.json")) {
            if (tryParsePluginManifest(allocator, arena_alloc, io, dir, name, rel_path)) |r| {
                try resources.append(allocator, r);
            } else |_| {
                const msg = try std.fmt.allocPrint(allocator, "bad plugin manifest in {s}", .{file_path});
                try warns.append(allocator, msg);
            }
            continue;
        }

        // Webhooks
        if (std.mem.eql(u8, name, "webhooks.json")) {
            if (tryParseWebhooks(allocator, arena_alloc, io, dir, name, rel_path)) |entries| {
                for (entries) |r| try resources.append(allocator, r);
                allocator.free(entries);
            } else |_| {
                const msg = try std.fmt.allocPrint(allocator, "bad webhooks in {s}", .{file_path});
                try warns.append(allocator, msg);
            }
        }
    }
}

fn readFileContent(allocator: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8) ![]u8 {
    const file = try dir.openFile(io, name, .{});
    defer file.close(io);
    const stat = try file.stat(io);
    const size: usize = @intCast(stat.size);
    const buf = try allocator.alloc(u8, size);
    _ = try file.readPositionalAll(io, buf, 0);
    return buf;
}

fn tryFrontmatterSkill(allocator: std.mem.Allocator, arena_alloc: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8, rel_path: []const u8) DiscoveryError!Resource {
    const content = readFileContent(arena_alloc, io, dir, name) catch return error.ParseError;
    var fm = try parseFrontmatter(arena_alloc, content) orelse return error.InvalidFrontmatter;
    defer fm.deinit();
    const skill_name = fm.get("name") orelse return error.InvalidFrontmatter;
    const desc = fm.get("description");

    return Resource{
        .kind = .skill,
        .name = try allocator.dupe(u8, skill_name),
        .path = try allocator.dupe(u8, rel_path),
        .description = if (desc) |d| try allocator.dupe(u8, d) else try allocator.dupe(u8, ""),
        .source_root = try allocator.dupe(u8, rel_path),
        .cost = .cheap,
        .source = try allocator.dupe(u8, "local-skill"),
    };
}

fn tryFrontmatterAgent(allocator: std.mem.Allocator, arena_alloc: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8, rel_path: []const u8) DiscoveryError!Resource {
    const content = readFileContent(arena_alloc, io, dir, name) catch return error.ParseError;
    var fm = try parseFrontmatter(arena_alloc, content) orelse return error.InvalidFrontmatter;
    defer fm.deinit();
    const agent_name = fm.get("name") orelse return error.InvalidFrontmatter;
    const desc = fm.get("description");

    return Resource{
        .kind = .agent,
        .name = try allocator.dupe(u8, agent_name),
        .path = try std.fs.path.join(allocator, &.{ rel_path, name }),
        .description = if (desc) |d| try allocator.dupe(u8, d) else try allocator.dupe(u8, ""),
        .source_root = try allocator.dupe(u8, rel_path),
        .cost = .cheap,
        .source = try allocator.dupe(u8, "local-agent"),
    };
}

fn tryParseMcpConfig(allocator: std.mem.Allocator, arena_alloc: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8, rel_path: []const u8) DiscoveryError![]Resource {
    const content = readFileContent(arena_alloc, io, dir, name) catch return error.ParseError;
    const parsed = std.json.parseFromSlice(std.json.Value, arena_alloc, content, .{}) catch return error.InvalidJson;
    if (parsed.value != .object) return error.InvalidJson;
    const root = parsed.value.object;
    const servers = root.get("mcpServers") orelse return error.InvalidJson;
    if (servers != .object) return error.InvalidJson;

    var list = std.ArrayList(Resource).empty;
    errdefer {
        for (list.items) |r| r.deinit(allocator);
        list.deinit(allocator);
    }

    var it = servers.object.iterator();
    while (it.next()) |entry| {
        const srv = entry.value_ptr.*;
        const srv_name = entry.key_ptr.*;
        var srv_desc: []const u8 = "";
        if (srv == .object) {
            if (srv.object.get("description")) |d| {
                if (d == .string) srv_desc = d.string;
            }
        }
        try list.append(allocator, .{
            .kind = .mcp_server,
            .name = try allocator.dupe(u8, srv_name),
            .path = try allocator.dupe(u8, rel_path),
            .description = try allocator.dupe(u8, srv_desc),
            .source_root = try allocator.dupe(u8, rel_path),
            .cost = .expensive,
            .source = try std.fmt.allocPrint(allocator, "mcp:{s}", .{srv_name}),
        });
    }

    return list.toOwnedSlice(allocator);
}

fn tryParsePluginManifest(allocator: std.mem.Allocator, arena_alloc: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8, rel_path: []const u8) DiscoveryError!Resource {
    const content = readFileContent(arena_alloc, io, dir, name) catch return error.ParseError;
    const parsed = std.json.parseFromSlice(std.json.Value, arena_alloc, content, .{}) catch return error.InvalidJson;
    if (parsed.value != .object) return error.InvalidJson;
    const root = parsed.value.object;
    const plugin_name = blk: {
        if (root.get("name")) |n| {
            if (n == .string) break :blk n.string;
        }
        return error.InvalidJson;
    };
    const desc = blk: {
        if (root.get("description")) |d| {
            if (d == .string) break :blk d.string;
        }
        break :blk "";
    };

    return Resource{
        .kind = .plugin,
        .name = try allocator.dupe(u8, plugin_name),
        .path = try allocator.dupe(u8, rel_path),
        .description = try allocator.dupe(u8, desc),
        .source_root = try allocator.dupe(u8, rel_path),
        .cost = .cheap,
        .source = try std.fmt.allocPrint(allocator, "plugin:{s}", .{plugin_name}),
    };
}

fn tryParseWebhooks(allocator: std.mem.Allocator, arena_alloc: std.mem.Allocator, io: Io, dir: Io.Dir, name: []const u8, rel_path: []const u8) DiscoveryError![]Resource {
    const content = readFileContent(arena_alloc, io, dir, name) catch return error.ParseError;
    const parsed = std.json.parseFromSlice(std.json.Value, arena_alloc, content, .{}) catch return error.InvalidJson;
    if (parsed.value != .object) return error.InvalidJson;
    const root = parsed.value.object;
    const hooks = root.get("webhooks") orelse return error.InvalidJson;
    if (hooks != .array) return error.InvalidJson;

    var list = std.ArrayList(Resource).empty;
    errdefer {
        for (list.items) |r| r.deinit(allocator);
        list.deinit(allocator);
    }

    for (hooks.array.items) |hook_val| {
        if (hook_val != .object) continue;
        const hook = hook_val.object;
        const hook_name = blk: {
            if (hook.get("name")) |n| {
                if (n == .string) break :blk n.string;
            }
            continue;
        };
        const desc = blk: {
            if (hook.get("description")) |d| {
                if (d == .string) break :blk d.string;
            }
            break :blk "";
        };
        try list.append(allocator, .{
            .kind = .webhook,
            .name = try allocator.dupe(u8, hook_name),
            .path = try allocator.dupe(u8, rel_path),
            .description = try allocator.dupe(u8, desc),
            .source_root = try allocator.dupe(u8, rel_path),
            .cost = .expensive,
            .source = try std.fmt.allocPrint(allocator, "webhook:{s}", .{hook_name}),
        });
    }

    return list.toOwnedSlice(allocator);
}

/// Resultado de parseFrontmatter. Posee el allocator original para liberar sus buffers.
/// Valores inline son slices del contenido original; valores de bloque son slices
/// de sus propias asignaciones (tanto key como value) y se liberan con `deinit`.
pub const FrontmatterMap = struct {
    allocator: std.mem.Allocator,
    map: std.StringHashMap([]const u8),
    /// Pares key+value de bloque (cada bloque aporta 2 entradas: key, value).
    block_owned: std.ArrayList([]const u8),

    pub fn get(self: FrontmatterMap, key: []const u8) ?[]const u8 {
        return self.map.get(key);
    }

    pub fn deinit(self: *FrontmatterMap) void {
        var i: usize = 0;
        while (i < self.block_owned.items.len) : (i += 2) {
            self.allocator.free(self.block_owned.items[i]); // key
            self.allocator.free(self.block_owned.items[i + 1]); // value
        }
        self.block_owned.deinit(self.allocator);
        self.map.deinit();
    }

    fn init(allocator: std.mem.Allocator) FrontmatterMap {
        return .{
            .allocator = allocator,
            .map = std.StringHashMap([]const u8).init(allocator),
            .block_owned = std.ArrayList([]const u8).empty,
        };
    }

    fn putBlock(self: *FrontmatterMap, key: []const u8, value: []const u8) !void {
        const k_owned = try self.allocator.dupe(u8, key);
        errdefer self.allocator.free(k_owned);
        const v_owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(v_owned);
        try self.map.put(k_owned, v_owned);
        try self.block_owned.append(self.allocator, k_owned);
        try self.block_owned.append(self.allocator, v_owned);
    }

    fn putScalar(self: *FrontmatterMap, key: []const u8, value: []const u8) !void {
        try self.map.put(key, value);
    }
};

/// Parsea frontmatter YAML (`--- ... ---`) del contenido.
/// Soporta: claves escalares, arrays `[a, b]` y escalares de bloque `|`.
/// Devuelve `null` si no hay frontmatter. El llamador DEBE llamar a `deinit`.
pub fn parseFrontmatter(allocator: std.mem.Allocator, content: []const u8) !?FrontmatterMap {
    if (!std.mem.startsWith(u8, content, "---")) return null;
    const end = std.mem.indexOf(u8, content[3..], "---") orelse return null;
    const fm_text = content[3 .. 3 + end];

    var fm = FrontmatterMap.init(allocator);
    errdefer fm.deinit();

    var block_key: ?[]const u8 = null;
    var block_lines = std.ArrayList(u8).empty;
    var block_indent: ?usize = null;
    var block_is_folded: bool = false;

    var lines = std.mem.splitScalar(u8, fm_text, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \r");

        if (block_key) |bk| {
            const indent = leadingWhitespace(line);
            if (trimmed.len > 0 and indent > 0 and (block_indent == null or indent >= block_indent.?)) {
                try block_lines.appendSlice(allocator, line[indent..]);
                try block_lines.append(allocator, '\n');
                if (block_indent == null) block_indent = indent;
                continue;
            }
            // Fin del bloque.
            const raw_value = std.mem.trim(u8, block_lines.items, "\n");
            const folded_value = if (block_is_folded) try foldBlock(allocator, raw_value) else null;
            defer if (folded_value) |fv| allocator.free(fv);
            const value = folded_value orelse raw_value;
            if (value.len > 0) try fm.putBlock(bk, value);
            allocator.free(bk);
            block_key = null;
            block_lines.deinit(allocator);
            block_lines = std.ArrayList(u8).empty;
            block_indent = null;
            block_is_folded = false;
        }

        if (trimmed.len == 0) continue;
        if (std.mem.indexOfScalar(u8, trimmed, ':') == null) continue;
        const colon_pos = std.mem.indexOfScalar(u8, trimmed, ':').?;
        const key = std.mem.trim(u8, trimmed[0..colon_pos], " \t");
        const value_raw = std.mem.trim(u8, trimmed[colon_pos + 1 ..], " \t");

        const is_literal = std.mem.eql(u8, value_raw, "|") or std.mem.eql(u8, value_raw, "\"|\"") or std.mem.eql(u8, value_raw, "'|'");
        const is_folded = std.mem.eql(u8, value_raw, ">") or std.mem.eql(u8, value_raw, "\">\"") or std.mem.eql(u8, value_raw, "'>'");
        if (is_literal or is_folded) {
            block_key = try allocator.dupe(u8, key);
            block_lines = std.ArrayList(u8).empty;
            block_indent = null;
            block_is_folded = is_folded;
            continue;
        }

        var value = value_raw;
        // Trim quotes and spaces on the right only for inline values.
        while (value.len > 0 and (value[value.len - 1] == '"' or value[value.len - 1] == '\'' or value[value.len - 1] == ' ' or value[value.len - 1] == '\t')) {
            value = value[0 .. value.len - 1];
        }
        if (value.len > 0 and value[0] == '[') {
            const array_end = std.mem.indexOfScalar(u8, value, ']') orelse continue;
            value = value[0 .. array_end + 1];
        }
        fm.putScalar(key, value) catch continue;
    }

    if (block_key) |bk| {
        const raw_value = std.mem.trim(u8, block_lines.items, "\n");
        const folded_value = if (block_is_folded) try foldBlock(allocator, raw_value) else null;
        defer if (folded_value) |fv| allocator.free(fv);
        const value = folded_value orelse raw_value;
        if (value.len > 0) try fm.putBlock(bk, value);
        allocator.free(bk);
        block_lines.deinit(allocator);
    }

    return fm;
}

/// Colapsa newlines de un bloque YAML folded (`>`) en espacios,
/// manteniendo líneas en blanco como separadores de párrafo (doble newline).
fn foldBlock(allocator: std.mem.Allocator, raw: []const u8) std.mem.Allocator.Error![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    var prev_was_newline = false;
    while (i < raw.len) : (i += 1) {
        const c = raw[i];
        if (c == '\n') {
            if (prev_was_newline) {
                // Doble newline = separador de párrafo; mantener uno.
                if (out.items.len > 0 and out.items[out.items.len - 1] != '\n') {
                    try out.append(allocator, '\n');
                }
                try out.append(allocator, '\n');
            } else {
                // Primer newline: convertir a espacio si el siguiente no es otro newline.
                if (i + 1 < raw.len and raw[i + 1] != '\n') {
                    try out.append(allocator, ' ');
                } else if (i + 1 >= raw.len) {
                    // newline al final, ignorar
                }
            }
            prev_was_newline = true;
        } else {
            prev_was_newline = false;
            try out.append(allocator, c);
        }
    }
    return out.toOwnedSlice(allocator);
}

fn leadingWhitespace(line: []const u8) usize {
    var i: usize = 0;
    while (i < line.len and (line[i] == ' ' or line[i] == '\t')) i += 1;
    return i;
}

// ── P12: Cached inventory with mtime invalidation ─────────────────────

/// Inventario cacheado con invalidación por mtime. Evita re-escanear en cada orden.
/// El cache se invalida cuando el mtime de cualquier raíz cambia.
pub const CachedInventory = struct {
    allocator: std.mem.Allocator,
    inventory: ?Inventory,
    /// MTimes por raíz (epoch ms). Si cambia → invalidar.
    root_mtimes: std.StringHashMap(i64),
    last_scan_ts: i64,

    pub fn init(allocator: std.mem.Allocator) CachedInventory {
        return .{
            .allocator = allocator,
            .inventory = null,
            .root_mtimes = std.StringHashMap(i64).init(allocator),
            .last_scan_ts = 0,
        };
    }

    pub fn deinit(self: *CachedInventory) void {
        if (self.inventory) |*inv| inv.deinit(self.allocator);
        var it = self.root_mtimes.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.root_mtimes.deinit();
    }

    /// Devuelve el inventario cacheado si es válido, o null si necesita re-escaneo.
    pub fn get(self: *CachedInventory, roots: []const []const u8, now_ms: i64) ?*const Inventory {
        if (self.inventory == null) return null;
        // Verificar mtime de cada raíz.
        for (roots) |root_path| {
            const cached_mtime = self.root_mtimes.get(root_path) orelse return null;
            const current_mtime = getRootMtime(root_path) orelse return null;
            if (current_mtime != cached_mtime) return null;
        }
        _ = now_ms;
        return &self.inventory.?;
    }

    /// Fuerza un re-escaneo y actualiza el cache.
    pub fn refresh(self: *CachedInventory, io: Io, roots: []const []const u8) DiscoveryError!void {
        if (self.inventory) |*inv| inv.deinit(self.allocator);
        self.inventory = null;
        // Limpiar mtimes anteriores.
        var it = self.root_mtimes.iterator();
        while (it.next()) |entry| self.allocator.free(entry.key_ptr.*);
        self.root_mtimes.clearRetainingCapacity();

        self.inventory = try scanRoots(self.allocator, io, roots);
        for (roots) |root_path| {
            const mtime = getRootMtime(root_path) orelse 0;
            const key = self.allocator.dupe(u8, root_path) catch continue;
            self.root_mtimes.put(key, mtime) catch {
                self.allocator.free(key);
            };
        }
    }

    /// Invalida el cache (próxima llamada a get devolverá null).
    pub fn invalidate(self: *CachedInventory) void {
        if (self.inventory) |*inv| inv.deinit(self.allocator);
        self.inventory = null;
    }
};

/// Obtiene el mtime de una ruta (última modificación) como i64 epoch ms.
/// Devuelve null si no se puede acceder.
fn getRootMtime(path: []const u8) ?i64 {
    _ = path;
    // En el contexto DLL/engine, no podemos usar std.fs directamente por
    // restricciones de std.Io.Threaded. El mtime se obtiene vía WinAPI
    // en c_api.zig donde ya hay código de FindFirstFileA.
    // Aquí devolvemos null para forzar re-escaneo si el caller no proveee mtime.
    return null;
}

// ── P12: Per-task selection ───────────────────────────────────────────

/// Selección de herramientas para una tarea específica.
pub const TaskSelection = struct {
    task_id: []const u8,
    needed: []Resource,
    none_needed: bool,
    reason: []const u8,

    pub fn deinit(self: *const TaskSelection, allocator: std.mem.Allocator) void {
        for (self.needed) |r| r.deinit(allocator);
        allocator.free(self.needed);
        allocator.free(self.task_id);
        allocator.free(self.reason);
    }
};

/// Pre-filtro determinista: reduce el inventario a top-N candidatos por relevancia
/// con la tarea. Usa el scoring de KeywordDiscovery (coincidencia de palabras).
/// N = max_candidates (default 20). Así el prompt del selector LLM se mantiene pequeño.
pub fn topNCandidates(
    allocator: std.mem.Allocator,
    order_text: []const u8,
    inventory: *const Inventory,
    max_candidates: usize,
) ![]Resource {
    const lower = try std.ascii.allocLowerString(allocator, order_text);
    defer allocator.free(lower);

    var scored = std.ArrayList(struct { resource: Resource, score: usize }).empty;
    defer scored.deinit(allocator);

    for (inventory.resources) |resource| {
        const matches = try resourceMatchesOrder(allocator, lower, resource);
        if (matches) {
            try scored.append(allocator, .{
                .resource = resource,
                .score = 1, // KeywordDiscovery es binario (match/no-match); el score LLM va en T2
            });
        }
    }

    // Si hay más de max_candidates, truncar (ya están en orden de aparición del inventario).
    const count = @min(scored.items.len, max_candidates);
    var out = try allocator.alloc(Resource, count);
    for (0..count) |i| {
        out[i] = .{
            .kind = scored.items[i].resource.kind,
            .name = try allocator.dupe(u8, scored.items[i].resource.name),
            .path = try allocator.dupe(u8, scored.items[i].resource.path),
            .description = try allocator.dupe(u8, scored.items[i].resource.description),
            .source_root = try allocator.dupe(u8, scored.items[i].resource.source_root),
            .cost = scored.items[i].resource.cost,
            .source = if (scored.items[i].resource.source.len > 0) try allocator.dupe(u8, scored.items[i].resource.source) else try allocator.dupe(u8, ""),
        };
    }
    return out;
}

/// P12-T5: Almacén de scores (skill, task_type) → score en SQLite.
/// Reutiliza el patrón de model_router: moving average con peso 0.3.
/// Permite al pre-filtro topNCandidates priorizar herramientas con histórico positivo.
pub const ToolScoreStore = struct {
    db_conn: db.Connection,
    now: i64,

    const MOVING_AVERAGE_WEIGHT: f64 = 0.3;

    pub fn init(conn: db.Connection, now_sec: i64) ToolScoreStore {
        return .{ .db_conn = conn, .now = now_sec };
    }

    /// Registra un verdict (pass=1.0, fail=0.0) para (tool_name, task_type).
    pub fn recordVerdict(self: *ToolScoreStore, tool_name: []const u8, task_type: []const u8, success: bool) void {
        const current = self.getScore(tool_name, task_type);
        const verdict_score: f64 = if (success) 1.0 else 0.0;
        const next_score = (current.score * (1.0 - MOVING_AVERAGE_WEIGHT)) + (verdict_score * MOVING_AVERAGE_WEIGHT);
        const next_count = current.sample_count + 1;
        // Use INSERT OR REPLACE with explicit conflict target for SQLite compatibility.
        const stmt = self.db_conn.prepare("INSERT INTO tool_scores (tool_name, task_type, score, sample_count, updated_at) VALUES (?, ?, ?, ?, ?) " ++
            "ON CONFLICT(tool_name, task_type) DO UPDATE SET score=?, sample_count=?, updated_at=?") catch return;
        defer self.db_conn.finalize(stmt);
        db.bindText(stmt, 1, tool_name) catch return;
        db.bindText(stmt, 2, task_type) catch return;
        db.bindDouble(stmt, 3, next_score) catch return;
        db.bindInt(stmt, 4, next_count) catch return;
        db.bindInt(stmt, 5, self.now) catch return;
        db.bindDouble(stmt, 6, next_score) catch return;
        db.bindInt(stmt, 7, next_count) catch return;
        db.bindInt(stmt, 8, self.now) catch return;
        _ = db.c.sqlite3_step(stmt);
    }

    /// Test variant that returns errors instead of swallowing them.
    fn recordVerdictDebug(self: *ToolScoreStore, tool_name: []const u8, task_type: []const u8, success: bool) !void {
        const current = self.getScore(tool_name, task_type);
        const verdict_score: f64 = if (success) 1.0 else 0.0;
        const next_score = (current.score * (1.0 - MOVING_AVERAGE_WEIGHT)) + (verdict_score * MOVING_AVERAGE_WEIGHT);
        const next_count = current.sample_count + 1;
        const stmt = try self.db_conn.prepare("INSERT INTO tool_scores (tool_name, task_type, score, sample_count, updated_at) VALUES (?, ?, ?, ?, ?) " ++
            "ON CONFLICT(tool_name, task_type) DO UPDATE SET score=?, sample_count=?, updated_at=?");
        defer self.db_conn.finalize(stmt);
        try db.bindText(stmt, 1, tool_name);
        try db.bindText(stmt, 2, task_type);
        try db.bindDouble(stmt, 3, next_score);
        try db.bindInt(stmt, 4, next_count);
        try db.bindInt(stmt, 5, self.now);
        try db.bindDouble(stmt, 6, next_score);
        try db.bindInt(stmt, 7, next_count);
        try db.bindInt(stmt, 8, self.now);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.ExecFailed;
    }

    /// Obtiene el score actual para (tool_name, task_type). Default 0.50.
    pub fn getScore(self: *ToolScoreStore, tool_name: []const u8, task_type: []const u8) struct { score: f64, sample_count: i64 } {
        const stmt = self.db_conn.prepare("SELECT score, sample_count FROM tool_scores WHERE tool_name=? AND task_type=?") catch return .{ .score = 0.50, .sample_count = 0 };
        defer self.db_conn.finalize(stmt);
        db.bindText(stmt, 1, tool_name) catch return .{ .score = 0.50, .sample_count = 0 };
        db.bindText(stmt, 2, task_type) catch return .{ .score = 0.50, .sample_count = 0 };
        if (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            return .{
                .score = db.c.sqlite3_column_double(stmt, 0),
                .sample_count = db.c.sqlite3_column_int64(stmt, 1),
            };
        }
        return .{ .score = 0.50, .sample_count = 0 };
    }

    /// Obtiene un mapa de scores para todos los tools dado un task_type.
    /// Devuelve un allocator-owned hashmap de tool_name → score.
    pub fn getScoresForTaskType(self: *ToolScoreStore, allocator: std.mem.Allocator, task_type: []const u8) !std.StringHashMap(f64) {
        var map = std.StringHashMap(f64).init(allocator);
        const stmt = self.db_conn.prepare("SELECT tool_name, score FROM tool_scores WHERE task_type=?") catch return map;
        defer self.db_conn.finalize(stmt);
        db.bindText(stmt, 1, task_type) catch return map;
        while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            const name_ptr = db.c.sqlite3_column_text(stmt, 0);
            const name_len = db.c.sqlite3_column_bytes(stmt, 0);
            if (name_ptr != null) {
                const name = name_ptr[0..@intCast(name_len)];
                const score = db.c.sqlite3_column_double(stmt, 1);
                const owned_name = try allocator.dupe(u8, name);
                try map.put(owned_name, score);
            }
        }
        return map;
    }
};

/// P12-T5: Pre-filtro con weighting por histórico de scores.
/// Igual que topNCandidates pero prioriza herramientas con score histórico positivo.
pub fn topNCandidatesWithScores(
    allocator: std.mem.Allocator,
    order_text: []const u8,
    inventory: *const Inventory,
    max_candidates: usize,
    score_map: ?*const std.StringHashMap(f64),
) ![]Resource {
    const lower = try std.ascii.allocLowerString(allocator, order_text);
    defer allocator.free(lower);

    const Item = struct { resource: Resource, score: f64 };
    var scored = std.ArrayList(Item).empty;
    defer scored.deinit(allocator);

    for (inventory.resources) |resource| {
        const matches = try resourceMatchesOrder(allocator, lower, resource);
        if (matches) {
            // Base score 1.0 for keyword match; boost by historical score if available.
            var score: f64 = 1.0;
            if (score_map) |sm| {
                if (sm.get(resource.name)) |hist_score| {
                    score = 1.0 + hist_score; // 0.0..2.0 range
                }
            }
            try scored.append(allocator, .{ .resource = resource, .score = score });
        }
    }

    // Sort by score descending (stable enough for our purposes).
    std.mem.sort(Item, scored.items, {}, struct {
        fn lessThan(_: void, a: Item, b: Item) bool {
            return a.score > b.score;
        }
    }.lessThan);

    const count = @min(scored.items.len, max_candidates);
    var out = try allocator.alloc(Resource, count);
    for (0..count) |i| {
        out[i] = .{
            .kind = scored.items[i].resource.kind,
            .name = try allocator.dupe(u8, scored.items[i].resource.name),
            .path = try allocator.dupe(u8, scored.items[i].resource.path),
            .description = try allocator.dupe(u8, scored.items[i].resource.description),
            .source_root = try allocator.dupe(u8, scored.items[i].resource.source_root),
            .cost = scored.items[i].resource.cost,
            .source = if (scored.items[i].resource.source.len > 0) try allocator.dupe(u8, scored.items[i].resource.source) else try allocator.dupe(u8, ""),
        };
    }
    return out;
}
/// `mcp_tools_json`: JSON array de tools desde `listToolsJson` del OdMcpState.
/// Devuelve un nuevo inventario (el caller libera el anterior).
pub fn mergeMcpTools(
    allocator: std.mem.Allocator,
    base: *const Inventory,
    mcp_server_name: []const u8,
    mcp_tools_json: []const u8,
) !Inventory {
    var resources = std.ArrayList(Resource).empty;
    // Copiar recursos existentes.
    for (base.resources) |r| {
        try resources.append(allocator, .{
            .kind = r.kind,
            .name = try allocator.dupe(u8, r.name),
            .path = try allocator.dupe(u8, r.path),
            .description = try allocator.dupe(u8, r.description),
            .source_root = try allocator.dupe(u8, r.source_root),
            .cost = r.cost,
            .source = if (r.source.len > 0) try allocator.dupe(u8, r.source) else try allocator.dupe(u8, ""),
        });
    }

    // Parsear JSON de tools y añadir como mcp_tool resources.
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, mcp_tools_json, .{}) catch {
        // Si no parsea, devolver base sin cambios.
        var warns = std.ArrayList([]const u8).empty;
        const w = try allocator.dupe(u8, "failed to parse MCP tools JSON");
        try warns.append(allocator, w);
        return Inventory{
            .resources = try resources.toOwnedSlice(allocator),
            .warnings = try warns.toOwnedSlice(allocator),
        };
    };
    defer parsed.deinit();

    const tools = switch (parsed.value) {
        .array => parsed.value.array.items,
        else => &[_]std.json.Value{},
    };

    for (tools) |tool_val| {
        if (tool_val != .object) continue;
        const tool = tool_val.object;
        const name = blk: {
            if (tool.get("name")) |n| {
                if (n == .string) break :blk n.string;
            }
            continue;
        };
        const desc = blk: {
            if (tool.get("description")) |d| {
                if (d == .string) break :blk d.string;
            }
            break :blk "";
        };
        const full_name = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ mcp_server_name, name });
        try resources.append(allocator, .{
            .kind = .mcp_tool,
            .name = full_name,
            .path = try allocator.dupe(u8, ""),
            .description = try allocator.dupe(u8, desc),
            .source_root = try allocator.dupe(u8, ""),
            .cost = .expensive,
            .source = try std.fmt.allocPrint(allocator, "mcp-tool:{s}", .{mcp_server_name}),
        });
    }

    // Copiar warnings existentes.
    var warns = std.ArrayList([]const u8).empty;
    for (base.warnings) |w| {
        try warns.append(allocator, try allocator.dupe(u8, w));
    }

    return Inventory{
        .resources = try resources.toOwnedSlice(allocator),
        .warnings = try warns.toOwnedSlice(allocator),
    };
}

// ── Tests ──────────────────────────────────────────────────────────────

test "discovery scans fixtures directory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const inv = try scanRoot(allocator, io, "tests/fixtures/discovery");
    defer inv.deinit(allocator);

    try std.testing.expect(inv.resources.len >= 6);
    try std.testing.expect(inv.warnings.len == 0);

    var skill_count: usize = 0;
    var agent_count: usize = 0;
    var mcp_count: usize = 0;
    var plugin_count: usize = 0;
    var webhook_count: usize = 0;

    for (inv.resources) |r| {
        switch (r.kind) {
            .skill => skill_count += 1,
            .agent => agent_count += 1,
            .mcp_server, .mcp_tool => mcp_count += 1,
            .plugin => plugin_count += 1,
            .webhook => webhook_count += 1,
        }
    }

    try std.testing.expect(skill_count >= 2);
    try std.testing.expect(agent_count >= 1);
    try std.testing.expect(mcp_count >= 2);
    try std.testing.expect(plugin_count >= 1);
    try std.testing.expect(webhook_count >= 1);
}

test "discovery selection by keywords is deterministic" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const inv = try scanRoot(allocator, io, "tests/fixtures/discovery");
    defer inv.deinit(allocator);

    var kw = KeywordDiscovery.init(allocator);
    const backend = kw.backend();
    defer backend.deinit();

    const sel1 = try backend.select(allocator, "review code for bugs", &inv);
    defer sel1.deinit(allocator);
    const sel2 = try backend.select(allocator, "review code for bugs", &inv);
    defer sel2.deinit(allocator);

    // Same order + same inventory → same result
    try std.testing.expectEqual(sel1.needed.len, sel2.needed.len);
}

test "discovery empty inventory yields empty selection" {
    const allocator = std.testing.allocator;
    var inv = Inventory{
        .resources = &.{},
        .warnings = &.{},
    };

    var kw = KeywordDiscovery.init(allocator);
    const backend = kw.backend();
    defer backend.deinit();

    const sel = try backend.select(allocator, "build a calculator in C", &inv);
    defer sel.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), sel.needed.len);
}

test "discovery nonexistent root yields warning" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const inv = try scanRoot(allocator, io, "tests/fixtures/nonexistent_dir_12345");
    defer inv.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), inv.resources.len);
    try std.testing.expect(inv.warnings.len > 0);
}

test "discovery reports missing capabilities not covered by any resource" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const inv = try scanRoot(allocator, io, "tests/fixtures/discovery");
    defer inv.deinit(allocator);

    var kw = KeywordDiscovery.init(allocator);
    const backend = kw.backend();
    defer backend.deinit();

    // Orden que pide formatear y seguridad: ningún recurso seleccionado los cubre.
    const sel = try backend.select(allocator, "necesito formatear con seguridad", &inv);
    defer sel.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), sel.needed.len);
    try std.testing.expect(sel.missing.len >= 2);
    var has_format = false;
    var has_security = false;
    for (sel.missing) |m| {
        if (std.mem.eql(u8, m, "formatting")) has_format = true;
        if (std.mem.eql(u8, m, "security-scan")) has_security = true;
    }
    try std.testing.expect(has_format and has_security);
}

test "discovery covers capability when a relevant resource exists" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const inv = try scanRoot(allocator, io, "tests/fixtures/discovery");
    defer inv.deinit(allocator);

    var kw = KeywordDiscovery.init(allocator);
    const backend = kw.backend();
    defer backend.deinit();

    // "review the code" selecciona code-reviewer, que cubre la capacidad code-review.
    const sel = try backend.select(allocator, "review the code", &inv);
    defer sel.deinit(allocator);

    try std.testing.expect(sel.needed.len >= 1);
    for (sel.missing) |m| try std.testing.expect(!std.mem.eql(u8, m, "code-review"));
}

test "discovery selection depends on the order (not fixed keywords)" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const inv = try scanRoot(allocator, io, "tests/fixtures/discovery");
    defer inv.deinit(allocator);

    var kw = KeywordDiscovery.init(allocator);
    const backend = kw.backend();
    defer backend.deinit();

    // Orden sin relación con ningún recurso → 0 seleccionados (keywords NO fijas).
    const sel = try backend.select(allocator, "renombra el archivo principal", &inv);
    defer sel.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), sel.needed.len);
}

test "discovery merges resources from multiple roots" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const single = try scanRoot(allocator, io, "tests/fixtures/discovery");
    defer single.deinit(allocator);

    // Fusionar la misma raíz dos veces duplica los recursos (US1-escenario-2).
    const merged = try scanRoots(allocator, io, &.{ "tests/fixtures/discovery", "tests/fixtures/discovery" });
    defer merged.deinit(allocator);

    try std.testing.expectEqual(single.resources.len * 2, merged.resources.len);
}

test "discovery scanRoots continues past a missing root" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const inv = try scanRoots(allocator, io, &.{ "tests/fixtures/nonexistent_xyz", "tests/fixtures/discovery" });
    defer inv.deinit(allocator);

    try std.testing.expect(inv.resources.len >= 6); // los de la raíz válida
    try std.testing.expect(inv.warnings.len >= 1); // aviso por la raíz inexistente
}

test "inventory serializes to JSON with escaped fields" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const inv = try scanRoot(allocator, io, "tests/fixtures/discovery");
    defer inv.deinit(allocator);

    const json = try inv.toJson(allocator);
    defer allocator.free(json);

    // JSON válido y consultable: parsea sin error y contiene claves/recursos esperados.
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, json, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .object);
    try std.testing.expect(parsed.value.object.get("resources") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "engram") != null);
}

// ── parseFrontmatter tests ─────────────────────────────────────────────

test "parseFrontmatter returns null without delimiters" {
    try std.testing.expectEqual(@as(?FrontmatterMap, null), try parseFrontmatter(std.testing.allocator, "solo texto sin frontmatter"));
}

test "parseFrontmatter parses simple key value" {
    const allocator = std.testing.allocator;
    var fm = (try parseFrontmatter(allocator,
        \\---
        \\name: Test
        \\value: 42
        \\---
    )).?;
    defer fm.deinit();
    try std.testing.expectEqualStrings("Test", fm.get("name").?);
    try std.testing.expectEqualStrings("42", fm.get("value").?);
}

test "parseFrontmatter parses block scalar" {
    const allocator = std.testing.allocator;
    var fm = (try parseFrontmatter(allocator,
        \\---
        \\name: Programación
        \\system_prompt: |
        \\  Eres un agente del departamento de Programación.
        \\  Usa RAII para la gestión de recursos.
        \\  Escribe SOLO dentro del sandbox asignado.
        \\---
    )).?;
    defer fm.deinit();
    const prompt = fm.get("system_prompt") orelse @panic("missing system_prompt");
    try std.testing.expect(std.mem.indexOf(u8, prompt, "RAII") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "sandbox") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "DevAgents") == null); // not in this fixture
    try std.testing.expect(prompt.len > 50);
}

test "parseFrontmatter block scalar with trailing spaces on pipe" {
    const allocator = std.testing.allocator;
    var fm = (try parseFrontmatter(allocator,
        \\---
        \\system_prompt: |
        \\  Primer línea.
        \\  Segunda línea.
        \\---
    )).?;
    defer fm.deinit();
    const prompt = fm.get("system_prompt") orelse @panic("missing");
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Primer") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Segunda") != null);
}

test "parseFrontmatter inline and block values mix" {
    const allocator = std.testing.allocator;
    var fm = (try parseFrontmatter(allocator,
        \\---
        \\name: Mix
        \\department: testing
        \\task_types: [testear, auditar]
        \\system_prompt: |
        \\  Eres un agente de testing.
        \\  Usa modelos DISTINTOS al constructor.
        \\description: Departamento de testing y auditoría.
        \\---
    )).?;
    defer fm.deinit();
    try std.testing.expectEqualStrings("Mix", fm.get("name").?);
    try std.testing.expectEqualStrings("testing", fm.get("department").?);
    try std.testing.expectEqualStrings("[testear, auditar]", fm.get("task_types").?);
    const prompt = fm.get("system_prompt") orelse @panic("missing");
    try std.testing.expect(std.mem.indexOf(u8, prompt, "DISTINTOS") != null);
    try std.testing.expectEqualStrings("Departamento de testing y auditoría.", fm.get("description").?);
}

test "parseFrontmatter block scalar stop at dedent" {
    const allocator = std.testing.allocator;
    var fm = (try parseFrontmatter(allocator,
        \\---
        \\system_prompt: |
        \\  Línea dentro del bloque.
        \\description: Fuera del bloque.
        \\---
    )).?;
    defer fm.deinit();
    const prompt = fm.get("system_prompt") orelse @panic("missing");
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Línea dentro") != null);
    try std.testing.expectEqualStrings("Fuera del bloque.", fm.get("description").?);
}

test "parseFrontmatter folded block scalar >" {
    const allocator = std.testing.allocator;
    var fm = (try parseFrontmatter(allocator,
        \\---
        \\name: smeargle-noir
        \\description: >
        \\  Director creativo de élite con criterio blindado.
        \\  Activa esta skill SIEMPRE QUE el usuario pida diseñar.
        \\---
    )).?;
    defer fm.deinit();
    try std.testing.expectEqualStrings("smeargle-noir", fm.get("name").?);
    const desc = fm.get("description") orelse @panic("missing description");
    // Las líneas individuales deben colapsarse en espacios.
    try std.testing.expect(std.mem.indexOf(u8, desc, "blindado.") != null);
    try std.testing.expect(std.mem.indexOf(u8, desc, "diseñar.") != null);
    // No debe haber newline entre las líneas (colapsado a espacio).
    try std.testing.expect(std.mem.indexOf(u8, desc, "blindado.\nActiva") == null);
}

test "parseFrontmatter folded block with trailing newline" {
    const allocator = std.testing.allocator;
    var fm = (try parseFrontmatter(allocator,
        \\---
        \\description: >
        \\  Última línea.
        \\---
    )).?;
    defer fm.deinit();
    const desc = fm.get("description") orelse @panic("missing");
    try std.testing.expect(std.mem.indexOf(u8, desc, "Última línea.") != null);
}

// ── P12-T1 tests ───────────────────────────────────────────────────────

test "P12-T1: resources have cost and source fields" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const inv = try scanRoot(allocator, io, "tests/fixtures/discovery");
    defer inv.deinit(allocator);

    try std.testing.expect(inv.resources.len >= 6);
    for (inv.resources) |r| {
        // Every resource must have a non-empty source.
        try std.testing.expect(r.source.len > 0);
        // Skills and agents should be cheap; MCP servers and webhooks expensive.
        switch (r.kind) {
            .skill, .agent, .plugin => try std.testing.expectEqual(Cost.cheap, r.cost),
            .mcp_server, .webhook => try std.testing.expectEqual(Cost.expensive, r.cost),
            .mcp_tool => try std.testing.expectEqual(Cost.expensive, r.cost),
        }
    }
}

test "P12-T1: toJson includes cost and source" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const inv = try scanRoot(allocator, io, "tests/fixtures/discovery");
    defer inv.deinit(allocator);

    const json = try inv.toJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "\"cost\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"source\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "local-skill") != null);
}

test "P12-T1: topNCandidates reduces inventory to max" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const inv = try scanRoot(allocator, io, "tests/fixtures/discovery");
    defer inv.deinit(allocator);

    const candidates = try topNCandidates(allocator, "review code", &inv, 2);
    defer {
        for (candidates) |r| r.deinit(allocator);
        allocator.free(candidates);
    }

    try std.testing.expect(candidates.len <= 2);
    // Should have at least 1 (code-reviewer matches "review code").
    if (candidates.len > 0) {
        try std.testing.expect(candidates[0].source.len > 0);
    }
}

test "P12-T1: mergeMcpTools adds mcp_tool resources" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const base = try scanRoot(allocator, io, "tests/fixtures/discovery");
    defer base.deinit(allocator);

    const mcp_json = "[{\"name\":\"echo\",\"description\":\"Echo tool\"},{\"name\":\"search\",\"description\":\"Search tool\"}]";
    var merged = try mergeMcpTools(allocator, &base, "test-server", mcp_json);
    defer merged.deinit(allocator);

    var mcp_tool_count: usize = 0;
    for (merged.resources) |r| {
        if (r.kind == .mcp_tool) mcp_tool_count += 1;
    }
    try std.testing.expectEqual(@as(usize, 2), mcp_tool_count);
}

test "P12-T1: CachedInventory returns null when empty" {
    const allocator = std.testing.allocator;
    var cache = CachedInventory.init(allocator);
    defer cache.deinit();

    const roots = [_][]const u8{"tests/fixtures/discovery"};
    const result = cache.get(&roots, 0);
    try std.testing.expect(result == null);
}

// ── P12-T2 tests ───────────────────────────────────────────────────────

test "P12-T2: LlmDiscovery falls back to keyword when no LLM configured" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const inv = try scanRoot(allocator, io, "tests/fixtures/discovery");
    defer inv.deinit(allocator);

    var llm_disc = LlmDiscovery.init(allocator);
    const backend = llm_disc.backend();
    defer backend.deinit();

    const sel = try backend.select(allocator, "review code", &inv);
    defer sel.deinit(allocator);

    // Should have selected something via keyword fallback.
    var has_fallback_warning = false;
    for (sel.warnings) |w| {
        if (std.mem.indexOf(u8, w, "fallback") != null) has_fallback_warning = true;
    }
    try std.testing.expect(has_fallback_warning);
}

test "P12-T2: parseSelectorJson validates names against inventory" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const inv = try scanRoot(allocator, io, "tests/fixtures/discovery");
    defer inv.deinit(allocator);

    // Find a skill name that exists in the inventory.
    var skill_name: []const u8 = "";
    for (inv.resources) |r| {
        if (r.kind == .skill) {
            skill_name = r.name;
            break;
        }
    }
    try std.testing.expect(skill_name.len > 0);

    const json = try std.fmt.allocPrint(allocator, "{{\"skills\":[\"{s}\",\"nonexistent-skill\"],\"mcps\":[],\"none_needed\":false,\"reason\":\"test\"}}", .{skill_name});
    defer allocator.free(json);

    const parsed = try parseSelectorJson(allocator, json, &inv);
    defer {
        for (parsed.skills) |s| allocator.free(s);
        allocator.free(parsed.skills);
        for (parsed.mcps) |m| allocator.free(m);
        allocator.free(parsed.mcps);
        allocator.free(parsed.reason);
    }

    // "nonexistent-skill" should be discarded; only the real skill remains.
    try std.testing.expectEqual(@as(usize, 1), parsed.skills.len);
    try std.testing.expect(std.mem.eql(u8, parsed.skills[0], skill_name));
}

test "P12-T2: parseSelectorJson handles none_needed=true" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const inv = try scanRoot(allocator, io, "tests/fixtures/discovery");
    defer inv.deinit(allocator);

    const json = "{\"skills\":[],\"mcps\":[],\"none_needed\":true,\"reason\":\"trivial task\"}";
    const parsed = try parseSelectorJson(allocator, json, &inv);
    defer {
        for (parsed.skills) |s| allocator.free(s);
        allocator.free(parsed.skills);
        for (parsed.mcps) |m| allocator.free(m);
        allocator.free(parsed.mcps);
        allocator.free(parsed.reason);
    }

    try std.testing.expect(parsed.none_needed);
    try std.testing.expectEqual(@as(usize, 0), parsed.skills.len);
    try std.testing.expect(std.mem.eql(u8, parsed.reason, "trivial task"));
}

test "P12-T2: parseSelectorJson rejects invalid JSON" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const inv = try scanRoot(allocator, io, "tests/fixtures/discovery");
    defer inv.deinit(allocator);

    const result = parseSelectorJson(allocator, "not json at all", &inv);
    try std.testing.expectError(error.SyntaxError, result);
}

/// Mock LLM function that returns a canned response.
fn mockLlmFn(_: *anyopaque, _: []const u8, _: []const u8) []const u8 {
    return "{\"skills\":[],\"mcps\":[],\"none_needed\":true,\"reason\":\"mock: trivial\"}";
}

/// Mock LLM function that returns empty string (simulates timeout).
fn mockLlmTimeoutFn(_: *anyopaque, _: []const u8, _: []const u8) []const u8 {
    return "";
}

fn slowMockLlmFn(ctx: *anyopaque, _: []const u8, _: []const u8) []const u8 {
    const completed: *std.atomic.Value(bool) = @ptrCast(@alignCast(ctx));
    Sleep(200);
    completed.store(true, .release);
    return "{\"skills\":[],\"mcps\":[],\"none_needed\":true,\"reason\":\"late\"}";
}

test "callLlmWithTimeout ya NO abandona el hilo: espera y devuelve la respuesta" {
    // Este test afirmaba lo contrario — que a los 20 ms devolvia "" y seguia —,
    // que era justamente el comportamiento que provocaba el use-after-free: el
    // hilo abandonado seguia usando el `*LiveLlm` del llamador, que vive en su
    // pila. Ahora la llamada es sincrona, asi que un selector lento SE ESPERA y
    // su respuesta se aprovecha en vez de tirarse. El plazo real lo pone
    // `LiveLlm.callWithTimeout` por candidato.
    var completed = std.atomic.Value(bool).init(false);
    const result = callLlmWithTimeout(@ptrCast(&completed), slowMockLlmFn, "sys", "user", 20);
    try std.testing.expectEqualStrings("{\"skills\":[],\"mcps\":[],\"none_needed\":true,\"reason\":\"late\"}", result);
    // Verificar completion, no la granularidad variable del reloj de Windows.
    try std.testing.expect(completed.load(.acquire));
}

test "P12-T2: LlmDiscovery with mock LLM returns none_needed" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const inv = try scanRoot(allocator, io, "tests/fixtures/discovery");
    defer inv.deinit(allocator);

    var llm_disc = LlmDiscovery.init(allocator);
    var dummy_ctx: u8 = 0;
    llm_disc.setLlm(@ptrCast(&dummy_ctx), mockLlmFn);
    const backend = llm_disc.backend();
    defer backend.deinit();

    const sel = try backend.select(allocator, "hola", &inv);
    defer sel.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), sel.needed.len);
    // Should NOT have fallback warning (LLM succeeded with none_needed).
    var has_fallback = false;
    for (sel.warnings) |w| {
        if (std.mem.indexOf(u8, w, "fallback") != null) has_fallback = true;
    }
    try std.testing.expect(!has_fallback);
}

test "P12-T2: LlmDiscovery with timeout mock falls back to keyword" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const inv = try scanRoot(allocator, io, "tests/fixtures/discovery");
    defer inv.deinit(allocator);

    var llm_disc = LlmDiscovery.init(allocator);
    var dummy_ctx: u8 = 0;
    llm_disc.setLlm(@ptrCast(&dummy_ctx), mockLlmTimeoutFn);
    const backend = llm_disc.backend();
    defer backend.deinit();

    const sel = try backend.select(allocator, "review code", &inv);
    defer sel.deinit(allocator);

    // Should have fallback warning.
    var has_fallback = false;
    for (sel.warnings) |w| {
        if (std.mem.indexOf(u8, w, "fallback") != null) has_fallback = true;
    }
    try std.testing.expect(has_fallback);
}

test "P12-T5: ToolScoreStore recordVerdict and getScore roundtrip" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    var store = ToolScoreStore.init(conn, 1000);
    try store.recordVerdictDebug("code-review", "programar", true);
    try store.recordVerdictDebug("code-review", "programar", true);
    try store.recordVerdictDebug("code-review", "programar", false);

    const score = store.getScore("code-review", "programar");
    // After 3 verdicts (pass, pass, fail) with MA weight 0.3:
    // s1 = 0.7*0.5 + 0.3*1.0 = 0.65
    // s2 = 0.7*0.65 + 0.3*1.0 = 0.755
    // s3 = 0.7*0.755 + 0.3*0.0 = 0.5285
    try std.testing.expect(score.sample_count >= 1);
    try std.testing.expect(score.score > 0.3 and score.score < 0.7);
}
