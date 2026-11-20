const std = @import("std");
const db = @import("db.zig");

/// Metadatos de la ronda de descubrimiento que produjo el payload /models.
pub const SnapshotMeta = struct {
    provider: []const u8 = "",
    api_style: []const u8 = "",
    metadata_source: []const u8 = "",
    metadata_updated_at: []const u8 = "",
    metadata_payload_type: enum { captured_real, dummy } = .captured_real,
};

/// Qué midió de verdad un sondeo en vivo sobre (provider, model). Los demás
/// resultados del probe (auth/quota/rate_limit/timeout/empty/err) no dicen
/// nada de la capacidad del modelo — un 401 es un problema de la CLAVE, no un
/// 'no' del modelo — y por eso no producen fila aquí.
pub const ProbeEvidence = enum {
    /// Respondió contenido por el canal SSE real → chat y streaming probados.
    ok,
    /// 404 del endpoint: el modelo ya no existe ahí. 'no' es un veto real —
    /// el router deja de quemar intentos con él.
    not_found,
};

/// Persiste en `discovery_snapshots_v2` lo que un sondeo EN VIVO acaba de medir.
///
/// - INSERT cuando el modelo no tiene fila (catálogo todavía sin /models para
///   ese par): fila mínima con payload_type='live_probe' — medido de verdad,
///   no fabricado; el resto de casillas queda 'unknown'/'not_probed'.
/// - UPDATE cuando la fila ya existe: solo se tocan las casillas medidas y
///   health_state/updated_at — contexto, precios y caps declaradas por el
///   proveedor no se pisan.
///
/// La frescura se actualiza: un probe de hoy reconfirma la evidencia entera.
pub fn persistProbeEvidence(
    catalog_db: db.Connection,
    provider: []const u8,
    model_id: []const u8,
    api_style: []const u8,
    endpoint_url: []const u8,
    evidence: ProbeEvidence,
    now: i64,
) !void {
    const chat_status: []const u8 = if (evidence == .ok) "yes" else "no";
    var updated_buf: [24]u8 = undefined;
    const updated_at = std.fmt.bufPrint(&updated_buf, "{d}", .{now}) catch return error.FormatFailed;
    const stmt = try catalog_db.prepare(
        \\INSERT INTO discovery_snapshots_v2 (
        \\  provider, model_id, api_style, wire_protocol, endpoint_url,
        \\  cap_chat_status, cap_chat_provenance,
        \\  cap_streaming_status, cap_streaming_provenance,
        \\  cap_tool_calls_status, cap_tool_calls_provenance,
        \\  cap_structured_output_status, cap_structured_output_provenance,
        \\  cap_vision_status, cap_vision_provenance,
        \\  cap_reasoning_status, cap_reasoning_provenance,
        \\  cap_audio_input_status, cap_audio_input_provenance,
        \\  cap_audio_output_status, cap_audio_output_provenance,
        \\  cap_embeddings_status, cap_embeddings_provenance,
        \\  context_window, max_output_tokens,
        \\  pricing_prompt, pricing_completion, cost_category, quota_limit,
        \\  auth_required, auth_env_var,
        \\  metadata_source, metadata_updated_at, metadata_reference_url,
        \\  metadata_payload_type, health_state
        \\) VALUES (?,?,?,?,?, ?,?, ?,?,
        \\  'unknown','not_probed','unknown','not_probed',
        \\  'unknown','not_probed','unknown','not_probed',
        \\  'unknown','not_probed','unknown','not_probed',
        \\  'unknown','not_probed',
        \\  NULL,NULL,NULL,NULL,'unknown',NULL,
        \\  1,NULL,'live_probe',?,NULL,'live_probe',?)
        \\ON CONFLICT(provider, model_id) DO UPDATE SET
        \\  cap_chat_status = excluded.cap_chat_status,
        \\  cap_chat_provenance = excluded.cap_chat_provenance,
        \\  cap_streaming_status = CASE WHEN excluded.cap_streaming_status != 'unknown'
        \\      THEN excluded.cap_streaming_status ELSE cap_streaming_status END,
        \\  cap_streaming_provenance = CASE WHEN excluded.cap_streaming_status != 'unknown'
        \\      THEN excluded.cap_streaming_provenance ELSE cap_streaming_provenance END,
        \\  metadata_updated_at = excluded.metadata_updated_at,
        \\  health_state = excluded.health_state
    );
    defer catalog_db.finalize(stmt);
    try db.bindText(stmt, 1, provider);
    try db.bindText(stmt, 2, model_id);
    try db.bindText(stmt, 3, api_style);
    try db.bindText(stmt, 4, api_style);
    try db.bindText(stmt, 5, endpoint_url);
    try db.bindText(stmt, 6, chat_status);
    try db.bindText(stmt, 7, "live_probe");
    // streaming solo queda probado en .ok: un 404 no certifica nada del canal.
    try db.bindText(stmt, 8, if (evidence == .ok) "yes" else "unknown");
    try db.bindText(stmt, 9, if (evidence == .ok) "live_probe" else "not_probed");
    try db.bindText(stmt, 10, updated_at);
    try db.bindText(stmt, 11, if (evidence == .ok) "ok" else "not_found");
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
}

/// Casillas medidas por un sondeo de capacidades EN VIVO (E1.32).
/// null = la celda no se midió en esta ronda y NO se toca; "yes"/"no" =
/// medido de verdad — un 'no' también es medición (el modelo respondió sin
/// la capacidad), nunca un veto de clave o de red.
pub const CapabilityCells = struct {
    chat: ?[]const u8 = null,
    streaming: ?[]const u8 = null,
    tool_calls: ?[]const u8 = null,
    structured_output: ?[]const u8 = null,
    vision: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
};

/// Persiste las casillas medidas por `probeModelCapabilities`. Misma
/// disciplina que persistProbeEvidence:
/// - INSERT cuando el modelo no tiene fila: lo medido queda 'live_probe',
///   lo no medido 'unknown'/'not_probed'.
/// - ON CONFLICT: solo se pisan las celdas medidas ESTA ronda (las cuyo
///   provenance llega como 'live_probe'). Lo demás se conserva — una ronda
///   sin medición no puede desmedir un live_probe anterior ni pisar una
///   declaración del proveedor con 'unknown'.
/// - health_state sube a 'ok' solo cuando el chat quedó medido 'yes'
///   (respondió de verdad); en otro caso se conserva lo que hubiera.
pub fn persistCapabilityEvidence(
    catalog_db: db.Connection,
    provider: []const u8,
    model_id: []const u8,
    api_style: []const u8,
    endpoint_url: []const u8,
    cells: CapabilityCells,
    now: i64,
) !void {
    var updated_buf: [24]u8 = undefined;
    const updated_at = std.fmt.bufPrint(&updated_buf, "{d}", .{now}) catch return error.FormatFailed;
    const stmt = try catalog_db.prepare(
        \\INSERT INTO discovery_snapshots_v2 (
        \\  provider, model_id, api_style, wire_protocol, endpoint_url,
        \\  cap_chat_status, cap_chat_provenance,
        \\  cap_streaming_status, cap_streaming_provenance,
        \\  cap_tool_calls_status, cap_tool_calls_provenance,
        \\  cap_structured_output_status, cap_structured_output_provenance,
        \\  cap_vision_status, cap_vision_provenance,
        \\  cap_reasoning_status, cap_reasoning_provenance,
        \\  cap_audio_input_status, cap_audio_input_provenance,
        \\  cap_audio_output_status, cap_audio_output_provenance,
        \\  cap_embeddings_status, cap_embeddings_provenance,
        \\  context_window, max_output_tokens,
        \\  pricing_prompt, pricing_completion, cost_category, quota_limit,
        \\  auth_required, auth_env_var,
        \\  metadata_source, metadata_updated_at, metadata_reference_url,
        \\  metadata_payload_type, health_state
        \\) VALUES (?,?,?,?,?, ?,?,?,?,?,?,?,?,
        \\  ?,?,?,?,
        \\  'unknown','not_probed','unknown','not_probed','unknown','not_probed',
        \\  NULL,NULL,NULL,NULL,'unknown',NULL,
        \\  1,NULL,'live_probe',?,NULL,'live_probe',?)
        \\ON CONFLICT(provider, model_id) DO UPDATE SET
        \\  cap_chat_status = CASE WHEN excluded.cap_chat_provenance = 'live_probe'
        \\      THEN excluded.cap_chat_status ELSE cap_chat_status END,
        \\  cap_chat_provenance = CASE WHEN excluded.cap_chat_provenance = 'live_probe'
        \\      THEN 'live_probe' ELSE cap_chat_provenance END,
        \\  cap_streaming_status = CASE WHEN excluded.cap_streaming_provenance = 'live_probe'
        \\      THEN excluded.cap_streaming_status ELSE cap_streaming_status END,
        \\  cap_streaming_provenance = CASE WHEN excluded.cap_streaming_provenance = 'live_probe'
        \\      THEN 'live_probe' ELSE cap_streaming_provenance END,
        \\  cap_tool_calls_status = CASE WHEN excluded.cap_tool_calls_provenance = 'live_probe'
        \\      THEN excluded.cap_tool_calls_status ELSE cap_tool_calls_status END,
        \\  cap_tool_calls_provenance = CASE WHEN excluded.cap_tool_calls_provenance = 'live_probe'
        \\      THEN 'live_probe' ELSE cap_tool_calls_provenance END,
        \\  cap_structured_output_status = CASE WHEN excluded.cap_structured_output_provenance = 'live_probe'
        \\      THEN excluded.cap_structured_output_status ELSE cap_structured_output_status END,
        \\  cap_structured_output_provenance = CASE WHEN excluded.cap_structured_output_provenance = 'live_probe'
        \\      THEN 'live_probe' ELSE cap_structured_output_provenance END,
        \\  cap_vision_status = CASE WHEN excluded.cap_vision_provenance = 'live_probe'
        \\      THEN excluded.cap_vision_status ELSE cap_vision_status END,
        \\  cap_vision_provenance = CASE WHEN excluded.cap_vision_provenance = 'live_probe'
        \\      THEN 'live_probe' ELSE cap_vision_provenance END,
        \\  cap_reasoning_status = CASE WHEN excluded.cap_reasoning_provenance = 'live_probe'
        \\      THEN excluded.cap_reasoning_status ELSE cap_reasoning_status END,
        \\  cap_reasoning_provenance = CASE WHEN excluded.cap_reasoning_provenance = 'live_probe'
        \\      THEN 'live_probe' ELSE cap_reasoning_provenance END,
        \\  metadata_updated_at = excluded.metadata_updated_at,
        \\  health_state = CASE WHEN excluded.health_state != 'unknown'
        \\      THEN excluded.health_state ELSE health_state END
    );
    defer catalog_db.finalize(stmt);
    var col: c_int = 1;
    try db.bindText(stmt, col, provider);
    col += 1;
    try db.bindText(stmt, col, model_id);
    col += 1;
    try db.bindText(stmt, col, api_style);
    col += 1;
    try db.bindText(stmt, col, api_style);
    col += 1; // wire_protocol
    try db.bindText(stmt, col, endpoint_url);
    col += 1;
    inline for (.{ cells.chat, cells.streaming, cells.tool_calls, cells.structured_output, cells.vision }) |cell| {
        try db.bindText(stmt, col, cell orelse "unknown");
        col += 1;
        try db.bindText(stmt, col, if (cell != null) "live_probe" else "not_probed");
        col += 1;
    }
    try db.bindText(stmt, col, cells.reasoning orelse "unknown");
    col += 1;
    try db.bindText(stmt, col, if (cells.reasoning != null) "live_probe" else "not_probed");
    col += 1;
    try db.bindText(stmt, col, updated_at);
    col += 1;
    const healthy = cells.chat != null and std.mem.eql(u8, cells.chat.?, "yes");
    try db.bindText(stmt, col, if (healthy) "ok" else "unknown");
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
}

/// E5.15: qué midió de verdad un sondeo de embeddings sobre (provider, model).
/// Solo los veredictos del propio endpoint son medición: `yes` (devolvió
/// vectores) y `no` (404 — el modelo no sirve embeddings ahí). Auth, cuota,
/// 429, red o timeout son fallos de CLAVE/ENTORNO, no del modelo, y por eso
/// no tienen valor aquí: persistirlos fabricaría un 'no' mentiroso.
pub const EmbeddingEvidence = enum { yes, no };

/// Persiste la celda `cap_embeddings_*` medida por un probe EN VIVO.
/// - INSERT si no hay fila (mínima, payload_type='live_probe'): el resto de
///   capacidades queda 'unknown'/'not_probed' — el probe solo midió vectores.
/// - UPDATE: SOLO cap_embeddings_status/provenance + metadata_updated_at se
///   pisan; un probe de embeddings no puede desmedir chat/tool_calls previos.
pub fn persistEmbeddingEvidence(
    catalog_db: db.Connection,
    provider: []const u8,
    model_id: []const u8,
    api_style: []const u8,
    endpoint_url: []const u8,
    evidence: EmbeddingEvidence,
    now: i64,
) !void {
    const status: []const u8 = if (evidence == .yes) "yes" else "no";
    var updated_buf: [24]u8 = undefined;
    const updated_at = std.fmt.bufPrint(&updated_buf, "{d}", .{now}) catch return error.FormatFailed;
    const stmt = try catalog_db.prepare(
        \\INSERT INTO discovery_snapshots_v2 (
        \\  provider, model_id, api_style, wire_protocol, endpoint_url,
        \\  cap_chat_status, cap_chat_provenance,
        \\  cap_streaming_status, cap_streaming_provenance,
        \\  cap_tool_calls_status, cap_tool_calls_provenance,
        \\  cap_structured_output_status, cap_structured_output_provenance,
        \\  cap_vision_status, cap_vision_provenance,
        \\  cap_reasoning_status, cap_reasoning_provenance,
        \\  cap_audio_input_status, cap_audio_input_provenance,
        \\  cap_audio_output_status, cap_audio_output_provenance,
        \\  cap_embeddings_status, cap_embeddings_provenance,
        \\  context_window, max_output_tokens,
        \\  pricing_prompt, pricing_completion, cost_category, quota_limit,
        \\  auth_required, auth_env_var,
        \\  metadata_source, metadata_updated_at, metadata_reference_url,
        \\  metadata_payload_type, health_state
        \\) VALUES (?,?,?,?,?,
        \\  'unknown','not_probed','unknown','not_probed',
        \\  'unknown','not_probed','unknown','not_probed',
        \\  'unknown','not_probed','unknown','not_probed',
        \\  'unknown','not_probed','unknown','not_probed',
        \\  ?,'live_probe',
        \\  NULL,NULL,NULL,NULL,'unknown',NULL,
        \\  1,NULL,'live_probe',?,NULL,'live_probe','unknown')
        \\ON CONFLICT(provider, model_id) DO UPDATE SET
        \\  cap_embeddings_status = excluded.cap_embeddings_status,
        \\  cap_embeddings_provenance = 'live_probe',
        \\  metadata_updated_at = excluded.metadata_updated_at
    );
    defer catalog_db.finalize(stmt);
    try db.bindText(stmt, 1, provider);
    try db.bindText(stmt, 2, model_id);
    try db.bindText(stmt, 3, api_style);
    try db.bindText(stmt, 4, api_style);
    try db.bindText(stmt, 5, endpoint_url);
    try db.bindText(stmt, 6, status);
    try db.bindText(stmt, 7, updated_at);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
}

/// Capacidades que el payload /models DECLARA para un modelo concreto
/// (supported_parameters de OpenRouter y compatibles, architecture.*_modalities).
/// Lo no declarado queda 'unknown' — la ausencia de declaración NO es un 'no':
/// un proveedor puede no listar la casilla y aun así soportarla.
const DeclaredCaps = struct {
    tool_calls: bool = false,
    structured_output: bool = false,
    vision: bool = false,
    reasoning: bool = false,
    audio_input: bool = false,
    audio_output: bool = false,
};

fn declaredCaps(obj: std.json.ObjectMap) DeclaredCaps {
    var caps = DeclaredCaps{};
    if (obj.get("supported_parameters")) |sp| {
        if (sp == .array) {
            for (sp.array.items) |p| {
                if (p != .string) continue;
                if (std.mem.eql(u8, p.string, "tools") or std.mem.eql(u8, p.string, "tool_choice")) caps.tool_calls = true;
                if (std.mem.eql(u8, p.string, "response_format") or std.mem.eql(u8, p.string, "structured_outputs")) caps.structured_output = true;
                if (std.mem.eql(u8, p.string, "reasoning") or std.mem.eql(u8, p.string, "include_reasoning")) caps.reasoning = true;
            }
        }
    }
    if (obj.get("architecture")) |arch| {
        if (arch == .object) {
            if (arch.object.get("input_modalities")) |im| {
                if (im == .array) {
                    for (im.array.items) |m| {
                        if (m != .string) continue;
                        if (std.mem.eql(u8, m.string, "image")) caps.vision = true;
                        if (std.mem.eql(u8, m.string, "audio")) caps.audio_input = true;
                    }
                }
            }
            if (arch.object.get("output_modalities")) |om| {
                if (om == .array) {
                    for (om.array.items) |m| {
                        if (m == .string and std.mem.eql(u8, m.string, "audio")) caps.audio_output = true;
                    }
                }
            }
        }
    }
    return caps;
}

/// Casillas que un sondeo en vivo midió antes de esta ronda de /models y que
/// el DELETE+INSERT no puede perder: un listing nuevo no desmide una medición
/// real. Solo se cosechan celdas con procedencia 'live_probe'.
const LiveCaps = struct {
    chat: ?[]const u8 = null,
    streaming: ?[]const u8 = null,
    tool_calls: ?[]const u8 = null,
    structured_output: ?[]const u8 = null,
    vision: ?[]const u8 = null,
    reasoning: ?[]const u8 = null,
    audio_input: ?[]const u8 = null,
    audio_output: ?[]const u8 = null,
    embeddings: ?[]const u8 = null,
};

fn harvestLiveProbeCaps(allocator: std.mem.Allocator, catalog_db: db.Connection, provider: []const u8) !std.StringHashMap(LiveCaps) {
    var map = std.StringHashMap(LiveCaps).init(allocator);
    const stmt = catalog_db.prepare(
        \\SELECT model_id,
        \\  cap_chat_status, cap_chat_provenance,
        \\  cap_streaming_status, cap_streaming_provenance,
        \\  cap_tool_calls_status, cap_tool_calls_provenance,
        \\  cap_structured_output_status, cap_structured_output_provenance,
        \\  cap_vision_status, cap_vision_provenance,
        \\  cap_reasoning_status, cap_reasoning_provenance,
        \\  cap_audio_input_status, cap_audio_input_provenance,
        \\  cap_audio_output_status, cap_audio_output_provenance,
        \\  cap_embeddings_status, cap_embeddings_provenance
        \\FROM discovery_snapshots_v2 WHERE provider = ?
    ) catch return map;
    defer catalog_db.finalize(stmt);
    try db.bindText(stmt, 1, provider);
    while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
        var caps = LiveCaps{};
        var any = false;
        inline for (0..9) |i| {
            const prov_col: c_int = @intCast(i * 2 + 2);
            const prov_ptr = db.c.sqlite3_column_text(stmt, prov_col);
            if (prov_ptr != null and std.mem.eql(u8, prov_ptr[0..std.mem.len(prov_ptr)], "live_probe")) {
                const st_col: c_int = @intCast(i * 2 + 1);
                const st_ptr = db.c.sqlite3_column_text(stmt, st_col);
                if (st_ptr != null) {
                    const status = try allocator.dupe(u8, st_ptr[0..std.mem.len(st_ptr)]);
                    switch (i) {
                        0 => caps.chat = status,
                        1 => caps.streaming = status,
                        2 => caps.tool_calls = status,
                        3 => caps.structured_output = status,
                        4 => caps.vision = status,
                        5 => caps.reasoning = status,
                        6 => caps.audio_input = status,
                        7 => caps.audio_output = status,
                        8 => caps.embeddings = status,
                        else => unreachable,
                    }
                    any = true;
                }
            }
        }
        if (any) {
            const id_ptr = db.c.sqlite3_column_text(stmt, 0) orelse continue;
            const id = try allocator.dupe(u8, id_ptr[0..std.mem.len(id_ptr)]);
            try map.put(id, caps);
        }
    }
    return map;
}

/// Libera las claves y los estados dupados de un mapa cosechado por
/// harvestLiveProbeCaps. StringHashMap.deinit no toca los pointees.
fn freeLiveCaps(allocator: std.mem.Allocator, map: *std.StringHashMap(LiveCaps)) void {
    var it = map.iterator();
    while (it.next()) |e| {
        allocator.free(e.key_ptr.*);
        const c = e.value_ptr;
        if (c.chat) |s| allocator.free(s);
        if (c.streaming) |s| allocator.free(s);
        if (c.tool_calls) |s| allocator.free(s);
        if (c.structured_output) |s| allocator.free(s);
        if (c.vision) |s| allocator.free(s);
        if (c.reasoning) |s| allocator.free(s);
        if (c.audio_input) |s| allocator.free(s);
        if (c.audio_output) |s| allocator.free(s);
        if (c.embeddings) |s| allocator.free(s);
    }
    map.deinit();
}

/// Persiste en `discovery_snapshots_v2` (catalog.db) la matriz
/// proveedor/modelo/protocolo que sale del /models real del proveedor.
///
/// Reglas de honestidad de datos — se escribe SOLO lo que la respuesta afirma:
///   - cap_chat_status = 'yes': listado por el endpoint /models del proveedor
///     (salvo que un sondeo en vivo haya medido lo contrario — ver abajo).
///   - Caps declaradas por el propio proveedor en el payload (supported_parameters,
///     architecture.*_modalities) = 'yes' con procedencia 'provider_declared'.
///   - El resto = 'unknown' con procedencia 'not_probed': un listado /models
///     no certifica streaming, tools, visión ni embeddings por sí solo.
///   - Las casillas medidas por sondeo en vivo ('live_probe') SOBREVIVEN a la
///     ronda: la medición real pesa más que la declaración del listado.
///   - context_window/pricing se copian si el payload los trae; si no, NULL.
///   - cost_category se decide POR MODELO (misma regla que el catálogo:
///     pricing 0+0 o sufijo ':free' => 'free'; si no, 'paid'/'free_tier' según
///     el flag del proveedor solo cuando no hay señal de precio).
///
/// Reemplaza por proveedor (DELETE+INSERT) para reflejar el estado real del
/// endpoint: un modelo que dejó de listarse desaparece de la matriz.
pub fn normalizeAndSaveProviderSnapshot(
    allocator: std.mem.Allocator,
    catalog_db: db.Connection,
    json: []const u8,
    meta: SnapshotMeta,
    base_url: []const u8,
    is_free_tier: bool,
    persisted_health: anytype,
) !void {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, json, .{}) catch return error.InvalidJson;
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;
    const root = parsed.value.object;
    const list_val = root.get("data") orelse root.get("models") orelse return error.InvalidJson;
    if (list_val != .array) return error.InvalidJson;
    if (list_val.array.items.len == 0) return;

    const payload_type = @tagName(meta.metadata_payload_type);

    // Cosecha ANTES del DELETE: las mediciones live_probe no se pierden al
    // refrescar el listado del proveedor.
    var live_caps = try harvestLiveProbeCaps(allocator, catalog_db, meta.provider);
    defer freeLiveCaps(allocator, &live_caps);

    // Una transacción para toda la ronda: DELETE+INSERT por fila con commit
    // individual tardaba segundos en SQLite para catálogos de ~200 modelos.
    try catalog_db.exec("BEGIN");
    var committed = false;
    defer if (!committed) catalog_db.exec("ROLLBACK") catch {};

    {
        const del = try catalog_db.prepare("DELETE FROM discovery_snapshots_v2 WHERE provider = ?");
        defer catalog_db.finalize(del);
        try db.bindText(del, 1, meta.provider);
        if (db.c.sqlite3_step(del) != db.c.SQLITE_DONE) return error.StepFailed;
    }

    const ins = try catalog_db.prepare(
        \\INSERT OR REPLACE INTO discovery_snapshots_v2 (
        \\  provider, model_id, api_style, wire_protocol, endpoint_url,
        \\  cap_chat_status, cap_chat_provenance,
        \\  cap_streaming_status, cap_streaming_provenance,
        \\  cap_tool_calls_status, cap_tool_calls_provenance,
        \\  cap_structured_output_status, cap_structured_output_provenance,
        \\  cap_vision_status, cap_vision_provenance,
        \\  cap_reasoning_status, cap_reasoning_provenance,
        \\  cap_audio_input_status, cap_audio_input_provenance,
        \\  cap_audio_output_status, cap_audio_output_provenance,
        \\  cap_embeddings_status, cap_embeddings_provenance,
        \\  context_window, max_output_tokens,
        \\  pricing_prompt, pricing_completion, cost_category, quota_limit,
        \\  auth_required, auth_env_var,
        \\  metadata_source, metadata_updated_at, metadata_reference_url,
        \\  metadata_payload_type, health_state
        \\) VALUES (?,?,?,?,?, ?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,
        \\  ?,?,?,?,?,?,
        \\  1,?,?,?,?,?,?)
    );
    defer catalog_db.finalize(ins);

    for (list_val.array.items) |entry| {
        if (entry != .object) continue;
        const obj = entry.object;
        const id_val = obj.get("id") orelse obj.get("name") orelse continue;
        if (id_val != .string) continue;
        const model_id = id_val.string;

        const ctx = intField(obj, "context_length") orelse intField(obj, "context_window") orelse
            intField(obj, "inputTokenLimit"); // Gemini /models
        const max_out = intField(obj, "max_completion_tokens") orelse intField(obj, "outputTokenLimit") orelse blk: {
            if (obj.get("top_provider")) |tp| {
                if (tp == .object) break :blk intField(tp.object, "max_completion_tokens");
            }
            break :blk null;
        };
        var price_prompt: ?f64 = null;
        var price_completion: ?f64 = null;
        if (obj.get("pricing")) |pv| {
            if (pv == .object) {
                price_prompt = floatField(pv.object, "prompt");
                price_completion = floatField(pv.object, "completion");
            }
        }
        const cost: []const u8 = blk: {
            if (price_prompt != null and price_completion != null and
                price_prompt.? == 0.0 and price_completion.? == 0.0) break :blk "free";
            if (std.mem.indexOf(u8, model_id, ":free") != null) break :blk "free";
            // 10-nov (USUARIO-NUEVO A5): OpenCode Zen tiene `is_free_tier` y
            // mezcla en su listado 12 gratuitos y 58 de pago; sin señal de
            // precio, los de pago salían como 'free_tier'. En OpenCode solo los
            // gratuitos conocidos (misma regla que catalogModelIsFree) lo son.
            if (is_free_tier and std.ascii.eqlIgnoreCase(meta.provider, "OpenCode") and
                !@import("model_roster.zig").isOpenCodeKnownFree(model_id)) break :blk "paid";
            break :blk if (is_free_tier) "free_tier" else "paid";
        };

        // health_state: si la ronda trae un mapa de salud persistida se usa;
        // si el modelo no aparece ahí, 'unknown' — nunca se afirma lo que no
        // se midió.
        var health_state: []const u8 = "unknown";
        if (persisted_health.get(model_id)) |hs| health_state = @tagName(hs);

        const declared = declaredCaps(obj);
        const live: LiveCaps = if (live_caps.get(model_id)) |lc| lc else .{};
        // Resolución por casilla: medición en vivo > declaración del proveedor
        // en este payload > desconocido. chat tiene fuente propia: el listado.
        const chat_status: []const u8 = live.chat orelse "yes";
        const chat_prov: []const u8 = if (live.chat != null) "live_probe" else "live_models_endpoint";

        _ = db.c.sqlite3_reset(ins);
        var col: c_int = 1;
        try db.bindText(ins, col, meta.provider);
        col += 1;
        try db.bindText(ins, col, model_id);
        col += 1;
        try db.bindText(ins, col, meta.api_style);
        col += 1;
        try db.bindText(ins, col, meta.api_style);
        col += 1; // wire_protocol
        try db.bindText(ins, col, base_url);
        col += 1;
        try db.bindText(ins, col, chat_status);
        col += 1;
        try db.bindText(ins, col, chat_prov);
        col += 1;
        // streaming: /models no lo declara — solo live_probe lo conoce.
        try db.bindText(ins, col, live.streaming orelse "unknown");
        col += 1;
        try db.bindText(ins, col, if (live.streaming != null) "live_probe" else "not_probed");
        col += 1;
        try db.bindText(ins, col, live.tool_calls orelse if (declared.tool_calls) "yes" else "unknown");
        col += 1;
        try db.bindText(ins, col, if (live.tool_calls != null) "live_probe" else if (declared.tool_calls) "provider_declared" else "not_probed");
        col += 1;
        try db.bindText(ins, col, live.structured_output orelse if (declared.structured_output) "yes" else "unknown");
        col += 1;
        try db.bindText(ins, col, if (live.structured_output != null) "live_probe" else if (declared.structured_output) "provider_declared" else "not_probed");
        col += 1;
        try db.bindText(ins, col, live.vision orelse if (declared.vision) "yes" else "unknown");
        col += 1;
        try db.bindText(ins, col, if (live.vision != null) "live_probe" else if (declared.vision) "provider_declared" else "not_probed");
        col += 1;
        try db.bindText(ins, col, live.reasoning orelse if (declared.reasoning) "yes" else "unknown");
        col += 1;
        try db.bindText(ins, col, if (live.reasoning != null) "live_probe" else if (declared.reasoning) "provider_declared" else "not_probed");
        col += 1;
        try db.bindText(ins, col, live.audio_input orelse if (declared.audio_input) "yes" else "unknown");
        col += 1;
        try db.bindText(ins, col, if (live.audio_input != null) "live_probe" else if (declared.audio_input) "provider_declared" else "not_probed");
        col += 1;
        try db.bindText(ins, col, live.audio_output orelse if (declared.audio_output) "yes" else "unknown");
        col += 1;
        try db.bindText(ins, col, if (live.audio_output != null) "live_probe" else if (declared.audio_output) "provider_declared" else "not_probed");
        col += 1;
        try db.bindText(ins, col, live.embeddings orelse "unknown");
        col += 1;
        try db.bindText(ins, col, if (live.embeddings != null) "live_probe" else "not_probed");
        col += 1;
        try bindOptInt(ins, col, ctx);
        col += 1;
        try bindOptInt(ins, col, max_out);
        col += 1;
        try bindOptFloat(ins, col, price_prompt);
        col += 1;
        try bindOptFloat(ins, col, price_completion);
        col += 1;
        try db.bindText(ins, col, cost);
        col += 1;
        try bindNull(ins, col); // quota_limit: no viene en /models
        col += 1;
        // col 30 auth_required va literal (1)
        try bindNull(ins, col); // auth_env_var
        col += 1;
        try db.bindText(ins, col, meta.metadata_source);
        col += 1;
        try db.bindText(ins, col, meta.metadata_updated_at);
        col += 1;
        try bindNull(ins, col); // metadata_reference_url
        col += 1;
        try db.bindText(ins, col, payload_type);
        col += 1;
        try db.bindText(ins, col, health_state);
        if (db.c.sqlite3_step(ins) != db.c.SQLITE_DONE) return error.StepFailed;
    }
    try catalog_db.exec("COMMIT");
    committed = true;
}

fn bindNull(stmt: *db.c.sqlite3_stmt, col: c_int) !void {
    if (db.c.sqlite3_bind_null(stmt, col) != db.c.SQLITE_OK)
        return error.BindFailed;
}

fn bindOptInt(stmt: *db.c.sqlite3_stmt, col: c_int, v: ?i32) !void {
    if (v) |x| return db.bindInt(stmt, col, x);
    return bindNull(stmt, col);
}

fn bindOptFloat(stmt: *db.c.sqlite3_stmt, col: c_int, v: ?f64) !void {
    if (v) |x| return db.bindDouble(stmt, col, x);
    return bindNull(stmt, col);
}

fn intField(obj: std.json.ObjectMap, key: []const u8) ?i32 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| @intCast(i),
        .float => |f| @intFromFloat(f),
        .number_string, .string => |s| std.fmt.parseInt(i32, s, 10) catch null,
        else => null,
    };
}

fn floatField(obj: std.json.ObjectMap, key: []const u8) ?f64 {
    const v = obj.get(key) orelse return null;
    return switch (v) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        .number_string, .string => |s| std.fmt.parseFloat(f64, s) catch null,
        else => null,
    };
}

// ── Tests ────────────────────────────────────────────────────────────────────

fn testCatalog() !db.Connection {
    var conn = try db.Connection.open(std.testing.allocator, ":memory:");
    errdefer conn.close();
    var migrator = db.Migrator.init(std.testing.allocator);
    try migrator.migrate(conn, &db.catalog_schema);
    return conn;
}

/// Lee una casilla de la fila (provider, model) copiándola en `buf` — sin
/// reservas: el test allocator cuenta cualquier dupe olvidado como leak.
fn snapshotCell(conn: db.Connection, provider: []const u8, model: []const u8, col: []const u8, buf: []u8) !?[]const u8 {
    var sql_buf: [192]u8 = undefined;
    const sql = try std.fmt.bufPrintZ(&sql_buf, "SELECT {s} FROM discovery_snapshots_v2 WHERE provider = ? AND model_id = ?", .{col});
    const stmt = try conn.prepare(sql);
    defer conn.finalize(stmt);
    try db.bindText(stmt, 1, provider);
    try db.bindText(stmt, 2, model);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return null;
    const ptr = db.c.sqlite3_column_text(stmt, 0) orelse return null;
    const val = ptr[0..std.mem.len(ptr)];
    @memcpy(buf[0..val.len], val);
    return buf[0..val.len];
}

// anytype en normalizeAndSaveProviderSnapshot: basta un mapa cuyo get devuelva
// un enum — en tests nunca se consulta porque queda vacío.
const TestHealth = enum { ok, failed };

fn testHealthMap() std.StringHashMap(TestHealth) {
    return std.StringHashMap(TestHealth).init(std.testing.allocator);
}

test "persistProbeEvidence ok crea fila live_probe con chat y streaming medidos" {
    var conn = try testCatalog();
    defer conn.close();
    var buf: [256]u8 = undefined;
    try persistProbeEvidence(conn, "TestProv", "modelo-x", "openai_compat", "https://api.test", .ok, 1_800_000_000);
    try std.testing.expectEqualStrings("yes", (try snapshotCell(conn, "TestProv", "modelo-x", "cap_chat_status", &buf)).?);
    try std.testing.expectEqualStrings("live_probe", (try snapshotCell(conn, "TestProv", "modelo-x", "cap_chat_provenance", &buf)).?);
    try std.testing.expectEqualStrings("yes", (try snapshotCell(conn, "TestProv", "modelo-x", "cap_streaming_status", &buf)).?);
    try std.testing.expectEqualStrings("live_probe", (try snapshotCell(conn, "TestProv", "modelo-x", "metadata_payload_type", &buf)).?);
    try std.testing.expectEqualStrings("ok", (try snapshotCell(conn, "TestProv", "modelo-x", "health_state", &buf)).?);
    // Lo no medido queda honesto.
    try std.testing.expectEqualStrings("unknown", (try snapshotCell(conn, "TestProv", "modelo-x", "cap_tool_calls_status", &buf)).?);
}

test "persistProbeEvidence not_found marca chat 'no' (veto) sin inventar streaming" {
    var conn = try testCatalog();
    defer conn.close();
    var buf: [256]u8 = undefined;
    try persistProbeEvidence(conn, "TestProv", "modelo-muerto", "openai_compat", "https://api.test", .not_found, 1_800_000_000);
    try std.testing.expectEqualStrings("no", (try snapshotCell(conn, "TestProv", "modelo-muerto", "cap_chat_status", &buf)).?);
    try std.testing.expectEqualStrings("live_probe", (try snapshotCell(conn, "TestProv", "modelo-muerto", "cap_chat_provenance", &buf)).?);
    try std.testing.expectEqualStrings("unknown", (try snapshotCell(conn, "TestProv", "modelo-muerto", "cap_streaming_status", &buf)).?);
}

test "persistProbeEvidence sobre fila existente no pisa contexto ni precios" {
    var conn = try testCatalog();
    defer conn.close();
    var buf: [256]u8 = undefined;
    var health_map = testHealthMap();
    defer health_map.deinit();
    try normalizeAndSaveProviderSnapshot(std.testing.allocator, conn,
        \\{"data":[{"id":"modelo-y","context_length":128000,"pricing":{"prompt":"0.1","completion":"0.2"}}]}
    , .{ .provider = "TestProv", .api_style = "openai_compat", .metadata_source = "t", .metadata_updated_at = "1790000000" }, "https://api.test", false, &health_map);
    try persistProbeEvidence(conn, "TestProv", "modelo-y", "openai_compat", "https://api.test", .ok, 1_800_000_000);
    try std.testing.expectEqualStrings("yes", (try snapshotCell(conn, "TestProv", "modelo-y", "cap_streaming_status", &buf)).?);
    const ctx_val = try snapshotCell(conn, "TestProv", "modelo-y", "context_window", &buf);
    try std.testing.expectEqualStrings("128000", ctx_val.?);
    // El tipo de fila no se degrada: sigue siendo evidencia capturada real.
    try std.testing.expectEqualStrings("captured_real", (try snapshotCell(conn, "TestProv", "modelo-y", "metadata_payload_type", &buf)).?);
    try std.testing.expectEqualStrings("1800000000", (try snapshotCell(conn, "TestProv", "modelo-y", "metadata_updated_at", &buf)).?);
}

test "USUARIO-NUEVO A5: los modelos de pago de OpenCode Zen no se catalogan como free_tier" {
    var conn = try testCatalog();
    defer conn.close();
    var buf: [256]u8 = undefined;
    var health_map = testHealthMap();
    defer health_map.deinit();
    try normalizeAndSaveProviderSnapshot(std.testing.allocator, conn,
        \\{"data":[{"id":"claude-opus-5"},{"id":"big-pickle"},{"id":"deepseek-v4-flash-free"}]}
    , .{ .provider = "OpenCode", .api_style = "openai_compat", .metadata_source = "t", .metadata_updated_at = "1790000000" }, "https://opencode.ai/zen/v1", true, &health_map);
    try std.testing.expectEqualStrings("paid", (try snapshotCell(conn, "OpenCode", "claude-opus-5", "cost_category", &buf)).?);
    try std.testing.expectEqualStrings("free_tier", (try snapshotCell(conn, "OpenCode", "big-pickle", "cost_category", &buf)).?);
    try std.testing.expectEqualStrings("free_tier", (try snapshotCell(conn, "OpenCode", "deepseek-v4-flash-free", "cost_category", &buf)).?);
}

test "snapshot lee capacidades declaradas por el proveedor (supported_parameters, modalities)" {
    var conn = try testCatalog();
    defer conn.close();
    var buf: [256]u8 = undefined;
    var health_map = testHealthMap();
    defer health_map.deinit();
    try normalizeAndSaveProviderSnapshot(std.testing.allocator, conn,
        \\{"data":[{"id":"modelo-pro","supported_parameters":["tools","response_format","reasoning"],
        \\"architecture":{"input_modalities":["text","image"],"output_modalities":["text"]}}]}
    , .{ .provider = "TestProv", .api_style = "openai_compat", .metadata_source = "t", .metadata_updated_at = "1800000000" }, "https://api.test", false, &health_map);
    try std.testing.expectEqualStrings("yes", (try snapshotCell(conn, "TestProv", "modelo-pro", "cap_tool_calls_status", &buf)).?);
    try std.testing.expectEqualStrings("provider_declared", (try snapshotCell(conn, "TestProv", "modelo-pro", "cap_tool_calls_provenance", &buf)).?);
    try std.testing.expectEqualStrings("yes", (try snapshotCell(conn, "TestProv", "modelo-pro", "cap_structured_output_status", &buf)).?);
    try std.testing.expectEqualStrings("yes", (try snapshotCell(conn, "TestProv", "modelo-pro", "cap_vision_status", &buf)).?);
    try std.testing.expectEqualStrings("yes", (try snapshotCell(conn, "TestProv", "modelo-pro", "cap_reasoning_status", &buf)).?);
    // No declarado => unknown, nunca inventado.
    try std.testing.expectEqualStrings("unknown", (try snapshotCell(conn, "TestProv", "modelo-pro", "cap_audio_output_status", &buf)).?);
    try std.testing.expectEqualStrings("unknown", (try snapshotCell(conn, "TestProv", "modelo-pro", "cap_streaming_status", &buf)).?);
}

test "refresh /models preserva caps live_probe y actualiza el resto" {
    var conn = try testCatalog();
    defer conn.close();
    var buf: [256]u8 = undefined;
    var health_map = testHealthMap();
    defer health_map.deinit();
    // 1) Sondeo midió streaming en vivo.
    try persistProbeEvidence(conn, "TestProv", "modelo-z", "openai_compat", "https://api.test", .ok, 1_800_000_000);
    // 2) Ronda /models posterior: streaming sigue probado aunque el listado no lo declare.
    try normalizeAndSaveProviderSnapshot(std.testing.allocator, conn,
        \\{"data":[{"id":"modelo-z","context_length":32000,"supported_parameters":["tools"]}]}
    , .{ .provider = "TestProv", .api_style = "openai_compat", .metadata_source = "t", .metadata_updated_at = "1800000100" }, "https://api.test", false, &health_map);
    try std.testing.expectEqualStrings("yes", (try snapshotCell(conn, "TestProv", "modelo-z", "cap_streaming_status", &buf)).?);
    try std.testing.expectEqualStrings("live_probe", (try snapshotCell(conn, "TestProv", "modelo-z", "cap_streaming_provenance", &buf)).?);
    try std.testing.expectEqualStrings("yes", (try snapshotCell(conn, "TestProv", "modelo-z", "cap_tool_calls_status", &buf)).?);
    try std.testing.expectEqualStrings("provider_declared", (try snapshotCell(conn, "TestProv", "modelo-z", "cap_tool_calls_provenance", &buf)).?);
    try std.testing.expectEqualStrings("captured_real", (try snapshotCell(conn, "TestProv", "modelo-z", "metadata_payload_type", &buf)).?);
}

test "un 'no' medido en vivo sobrevive a un listado que aún lo incluye" {
    var conn = try testCatalog();
    defer conn.close();
    var buf: [256]u8 = undefined;
    var health_map = testHealthMap();
    defer health_map.deinit();
    try persistProbeEvidence(conn, "TestProv", "modelo-404", "openai_compat", "https://api.test", .not_found, 1_800_000_000);
    // El proveedor sigue listándolo en /models: la medición real (404) gana.
    try normalizeAndSaveProviderSnapshot(std.testing.allocator, conn,
        \\{"data":[{"id":"modelo-404"}]}
    , .{ .provider = "TestProv", .api_style = "openai_compat", .metadata_source = "t", .metadata_updated_at = "1800000100" }, "https://api.test", false, &health_map);
    try std.testing.expectEqualStrings("no", (try snapshotCell(conn, "TestProv", "modelo-404", "cap_chat_status", &buf)).?);
    try std.testing.expectEqualStrings("live_probe", (try snapshotCell(conn, "TestProv", "modelo-404", "cap_chat_provenance", &buf)).?);
}

test "persistCapabilityEvidence mide las capacidades probadas y deja el resto honesto" {
    var conn = try testCatalog();
    defer conn.close();
    var buf: [256]u8 = undefined;
    try persistCapabilityEvidence(conn, "TestProv", "modelo-c", "openai_compat", "https://api.test", .{
        .chat = "yes",
        .streaming = "yes",
        .tool_calls = "yes",
        .structured_output = "no",
        .reasoning = "yes",
    }, 1_800_000_000);
    try std.testing.expectEqualStrings("yes", (try snapshotCell(conn, "TestProv", "modelo-c", "cap_tool_calls_status", &buf)).?);
    try std.testing.expectEqualStrings("live_probe", (try snapshotCell(conn, "TestProv", "modelo-c", "cap_tool_calls_provenance", &buf)).?);
    // Un 'no' también es medición: respondió limpio sin la capacidad.
    try std.testing.expectEqualStrings("no", (try snapshotCell(conn, "TestProv", "modelo-c", "cap_structured_output_status", &buf)).?);
    try std.testing.expectEqualStrings("live_probe", (try snapshotCell(conn, "TestProv", "modelo-c", "cap_structured_output_provenance", &buf)).?);
    try std.testing.expectEqualStrings("yes", (try snapshotCell(conn, "TestProv", "modelo-c", "cap_reasoning_status", &buf)).?);
    try std.testing.expectEqualStrings("ok", (try snapshotCell(conn, "TestProv", "modelo-c", "health_state", &buf)).?);
    // Lo no medido (vision, audio, embeddings) sigue honesto.
    try std.testing.expectEqualStrings("unknown", (try snapshotCell(conn, "TestProv", "modelo-c", "cap_vision_status", &buf)).?);
    try std.testing.expectEqualStrings("not_probed", (try snapshotCell(conn, "TestProv", "modelo-c", "cap_vision_provenance", &buf)).?);
}

test "persistCapabilityEvidence sin medición no pisa lo declarado por el proveedor" {
    var conn = try testCatalog();
    defer conn.close();
    var buf: [256]u8 = undefined;
    var health_map = testHealthMap();
    defer health_map.deinit();
    try normalizeAndSaveProviderSnapshot(std.testing.allocator, conn,
        \\{"data":[{"id":"modelo-d","supported_parameters":["tools","response_format"]}]}
    , .{ .provider = "TestProv", .api_style = "openai_compat", .metadata_source = "t", .metadata_updated_at = "1790000000" }, "https://api.test", false, &health_map);
    // Ronda que solo midió chat: tools/structured declarados se conservan.
    try persistCapabilityEvidence(conn, "TestProv", "modelo-d", "openai_compat", "https://api.test", .{
        .chat = "yes",
    }, 1_800_000_000);
    try std.testing.expectEqualStrings("yes", (try snapshotCell(conn, "TestProv", "modelo-d", "cap_chat_status", &buf)).?);
    try std.testing.expectEqualStrings("live_probe", (try snapshotCell(conn, "TestProv", "modelo-d", "cap_chat_provenance", &buf)).?);
    try std.testing.expectEqualStrings("yes", (try snapshotCell(conn, "TestProv", "modelo-d", "cap_tool_calls_status", &buf)).?);
    try std.testing.expectEqualStrings("provider_declared", (try snapshotCell(conn, "TestProv", "modelo-d", "cap_tool_calls_provenance", &buf)).?);
    try std.testing.expectEqualStrings("yes", (try snapshotCell(conn, "TestProv", "modelo-d", "cap_structured_output_status", &buf)).?);
    try std.testing.expectEqualStrings("provider_declared", (try snapshotCell(conn, "TestProv", "modelo-d", "cap_structured_output_provenance", &buf)).?);
    // reasoning nunca se declaró ni se midió: desconocido honesto.
    try std.testing.expectEqualStrings("unknown", (try snapshotCell(conn, "TestProv", "modelo-d", "cap_reasoning_status", &buf)).?);
}

test "capacidad medida en vivo sobrevive a un refresh /models posterior" {
    var conn = try testCatalog();
    defer conn.close();
    var buf: [256]u8 = undefined;
    var health_map = testHealthMap();
    defer health_map.deinit();
    try persistCapabilityEvidence(conn, "TestProv", "modelo-e", "openai_compat", "https://api.test", .{
        .chat = "yes",
        .tool_calls = "no",
        .reasoning = "yes",
    }, 1_800_000_000);
    // El listado declara tools: la medición real ('no') gana a la declaración.
    try normalizeAndSaveProviderSnapshot(std.testing.allocator, conn,
        \\{"data":[{"id":"modelo-e","supported_parameters":["tools"]}]}
    , .{ .provider = "TestProv", .api_style = "openai_compat", .metadata_source = "t", .metadata_updated_at = "1800000100" }, "https://api.test", false, &health_map);
    try std.testing.expectEqualStrings("no", (try snapshotCell(conn, "TestProv", "modelo-e", "cap_tool_calls_status", &buf)).?);
    try std.testing.expectEqualStrings("live_probe", (try snapshotCell(conn, "TestProv", "modelo-e", "cap_tool_calls_provenance", &buf)).?);
    try std.testing.expectEqualStrings("yes", (try snapshotCell(conn, "TestProv", "modelo-e", "cap_reasoning_status", &buf)).?);
    try std.testing.expectEqualStrings("live_probe", (try snapshotCell(conn, "TestProv", "modelo-e", "cap_reasoning_provenance", &buf)).?);
}

test "E5.24 vision persistence is measured additive and does not erase prior capabilities" {
    var conn = try testCatalog();
    defer conn.close();
    var buf: [256]u8 = undefined;
    try persistCapabilityEvidence(conn, "Fixture", "visual", "openai", "fixture://only", .{ .chat = "yes", .tool_calls = "yes" }, 1800000000);
    try persistCapabilityEvidence(conn, "Fixture", "visual", "openai", "fixture://only", .{ .vision = "yes" }, 1800000001);
    try std.testing.expectEqualStrings("yes", (try snapshotCell(conn, "Fixture", "visual", "cap_vision_status", &buf)).?);
    try std.testing.expectEqualStrings("live_probe", (try snapshotCell(conn, "Fixture", "visual", "cap_vision_provenance", &buf)).?);
    try std.testing.expectEqualStrings("yes", (try snapshotCell(conn, "Fixture", "visual", "cap_tool_calls_status", &buf)).?);
    try persistCapabilityEvidence(conn, "Fixture", "visual", "openai", "fixture://only", .{ .chat = "yes" }, 1800000002);
    try std.testing.expectEqualStrings("yes", (try snapshotCell(conn, "Fixture", "visual", "cap_vision_status", &buf)).?);
    try persistCapabilityEvidence(conn, "Fixture", "visual", "openai", "fixture://only", .{ .vision = "no" }, 1800000003);
    try std.testing.expectEqualStrings("no", (try snapshotCell(conn, "Fixture", "visual", "cap_vision_status", &buf)).?);
}
