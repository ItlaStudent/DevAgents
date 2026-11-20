const std = @import("std");
const db = @import("db.zig");
const health = @import("health.zig");
// ROSTER-PRUEBAS: sin la variable de entorno puesta, `allowsEnv` devuelve true
// para todo y el router se comporta exactamente igual que antes.
const model_roster = @import("model_roster.zig");
// OPENCODE-FREE-TIER: la política de la pasarela HTTP vive en el catálogo
// (enforceHttpFreeTierPolicy); este archivo la aplica en la prueba y confía en
// el filtro `available = 1` de rankCandidates.
const model_catalog = @import("model_catalog.zig");

const MAX_FALLBACK_LEVELS = 5;
const DEFAULT_LATENCY_MS = 1000.0;
const MIN_CONTEXT_FACTOR = 0.05;
const MIN_PRIMARY_HEALTH = 0.10;
const MOVING_AVERAGE_WEIGHT = 0.30;

// ── P8: clasificación por ÉXITO MEDIDO, no por prior (orden dentro del tier) ─
//
// El fallo medido en `route --chain` (2026-08-07): cuatro modelos Gemini con
// score heurístico 0.88 y NINGUNA fila en model_health quedaban por delante del
// único modelo con historial real (north-mini-code-1-0, 6 oks, score 0.60). El
// motivo: los modelos sin historial recibían healthFactor 1.0 (neutral), así
// que en el tier no había nada que los bajara.
//
// Reglas (cada una con su prueba):
// 1. Cero éxitos registrados JAMÁS supera a un modelo con historial real. Eso
//    separa el tier en dos clases: `proven` (ok > 0 y muestra suficiente) y
//    `unproven` (sin éxitos, o con tan pocas muestras que la tasa no se puede
//    fiar). `unproven` ordena SIEMPRE detrás de `proven`, sin importar el
//    score heurístico.
// 2. `unproven` no se elimina: se sigue probando (health ≥ 0.10, por debajo
//    del umbral de exclusión) para no morir de hambre.
// 3. Muestra mínima para fiar una tasa: menos de MIN_EVIDENCE_SAMPLES entre
//    ok+err, o cero oks, → `unproven`. Un único ok con 0 errores NO es una
//    tasa medida.
// 4. Descuento por antigüedad: los contadores se acumularon durante semanas
//    midiendo un bug del PARSER ya corregido. model_health NO guarda eventos
//    individuales (solo last_ok_at/last_err_at + agregados), así que la edad
//    se aplica por lado: si hace > STALE_WINDOW no hay ningún evento ok (o
//    err) reciente, esa mitad del recuento pesa la mitad. Así la era del bug
//    se desvanece sola con el tiempo y un probe fresco revierte el descuento.
pub const MIN_EVIDENCE_SAMPLES: i64 = 3;
pub const NO_EVIDENCE_FACTOR: f64 = 0.35;
pub const STALE_WINDOW_SECONDS: i64 = 14 * 24 * 3600;

pub const EvidenceClass = enum { proven, unproven };

// ── Matriz de compatibilidad (discovery_snapshots_v2, catalog.db) ────────────
//
// `discovery_persistence` escribe ahí lo que el /models real del proveedor
// afirmó (una casilla por capacidad: yes/no/unknown + procedencia). El router
// la consulta para dos cosas:
//   1. VETO: un 'no' medido en una capacidad REQUERIDA excluye al candidato
//      del ranking entero — live_worker llama siempre con .stream=true, así
//      que un modelo que no chatea o no streamea solo quemaría un intento
//      real y una marca de salud antes de fallar.
//   2. SEÑAL: un 'yes' confirma lo que el prior heurístico solo supone; un
//      'no' en la capacidad PREFERIDA de la etapa penaliza sin vetar.
//
// Caducidad: `metadata_updated_at` es la fecha de la foto (epoch en segundos,
// texto). Pasada MATRIX_TTL_SECONDS la fila se ignora ENTERA — ni veta ni
// favorece: una casilla caducada no sabe nada del modelo de hoy. Lo mismo
// aplica a filas `metadata_payload_type='dummy'` (fabricadas, no medidas).
pub const MATRIX_TTL_SECONDS: i64 = 30 * 24 * 3600;
const MATRIX_CONFIRMED_FACTOR: f64 = 1.10;
const MATRIX_STREAMING_FACTOR: f64 = 1.05;
const MATRIX_PREFERRED_YES: f64 = 1.15;
const MATRIX_PREFERRED_NO: f64 = 0.85;

/// La capacidad que una etapa PREFIERE medida (señal, nunca veto). El
/// mapeo replica el criterio de `reasoning_factor`: pensar y auditar son las
/// etapas donde un modelo con reasoning rinde más; el resto no declara
/// preferencia y la matriz solo puntúa por las requeridas.
fn preferredMatrixCapability(task_type: TaskType) ?[]const u8 {
    return switch (task_type) {
        .planificar, .auditar => "reasoning",
        else => null,
    };
}

/// Una fila ya validada (fresca, capturada de verdad) de
/// `discovery_snapshots_v2`, con las casillas que el scoring consulta.
/// `found=false` se usa dentro del cache para no reconsultar los fallos.
const MatrixEvidence = struct {
    found: bool = false,
    chat: []const u8 = "",
    streaming: []const u8 = "",
    reasoning: []const u8 = "",
    /// Fecha de la foto tal como la persistió discovery (epoch segundos, en
    /// texto) — viaja a `reason` para que la validez de la casilla se pueda
    /// auditar sin abrir la base.
    updated_at: []const u8 = "",

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.chat.len > 0) allocator.free(self.chat);
        if (self.streaming.len > 0) allocator.free(self.streaming);
        if (self.reasoning.len > 0) allocator.free(self.reasoning);
        if (self.updated_at.len > 0) allocator.free(self.updated_at);
        self.* = undefined;
    }
};

/// P8 regla 1 y 3: ¿un (ok, err) cuenta como `proven`?
///
/// - Cero éxitos → NUNCA: 'unproven'. Un modelo que nunca ha conseguido ni una
///   respuesta no puede ordenar delante de uno que sí tiene historial, por muy
///   alto que sea su prior heurístico.
/// - ok>0 y err==0 → `proven` aunque falte muestra (1 éxito limpio es evidencia
///   real de que sirve; castigarlo sería inútil).
/// - ok>0 y err>0 → `proven` SOLO con muestra suficiente (≥ MIN): una tasa de
///   fallos de, por ejemplo, 1/1 (total 2 < 3) no se puede fiar.
pub fn evidenceClass(ok_count: i64, err_count: i64) EvidenceClass {
    if (ok_count <= 0) return .unproven;
    if (err_count == 0) return .proven;
    if (ok_count + err_count < MIN_EVIDENCE_SAMPLES) return .unproven;
    return .proven;
}

/// fiabilidad con descuento por antigüedad (P8 regla 4). Los timestamps vienen
/// en SEGUNDOS (health.nowSeconds), igual que last_ok_at/last_err_at en la
/// tabla; null = nunca → cuenta como viejo.
pub fn agedReliability(ok_count: i64, err_count: i64, last_ok_at: ?i64, last_err_at: ?i64, now_seconds: i64) f64 {
    // P8 regla 4 — descuento por antigüedad. model_health no guarda eventos
    // individuales (solo agregados + last_ok_at/last_err_at), así que la edad NO
    // se puede descontar por muestra. Alternativa elegida: si el ÚLTIMO evento
    // de una clase hace > STALE_WINDOW, esa mitad del historial no es fiable (p.
    // ej. los contadores de la era del bug del parser) y la tasa se arrastra
    // hacia 0.5 (neutral): cuanta más fracción está vieja, menos se fía el
    // recuento. Es deliberadamente un ROUND de la fiabilidad, no un descuento
    // por muestra, porque el esquema no da para más.
    //
    // `null` (nunca hubo evento de esa clase) o una brecha negativa (now < ts,
    // p. ej. `now` de pruebas anterior al timestamp real) NO penalizan: sin
    // referente temporal no se puede acusar de viejo.
    var stale_fraction: f64 = 0.0;
    if (last_ok_at) |ts| {
        const gap = now_seconds - ts;
        if (gap >= 0 and gap > STALE_WINDOW_SECONDS) stale_fraction += 0.5;
    }
    if (last_err_at) |ts| {
        const gap = now_seconds - ts;
        if (gap >= 0 and gap > STALE_WINDOW_SECONDS) stale_fraction += 0.5;
    }
    const trust: f64 = 1.0 - stale_fraction;
    const raw = health.reliabilityFromCounts(ok_count, err_count);
    // Mezcla hacia neutral en la proporción de historial viejo.
    return (raw - 0.5) * trust + 0.5;
}

pub const RouterError = error{
    NoCandidates,
    PaidEscalationRequiresJustification,
    InvalidTaskType,
    InvalidAuditVerdict,
    OutOfMemory,
} || db.DbError;

pub const TaskType = enum {
    planificar,
    /// Programación GENÉRICA en cualquier lenguaje (el lenguaje concreto va en la
    /// descripción de la tarea). DevAgents EN SÍ se construye en C/C++/Zig, pero el
    /// agente programa en el lenguaje que pida el usuario o sea mejor para la tarea.
    programar,
    programar_c,
    programar_cpp,
    programar_zig,
    testear,
    auditar,
    corregir,
    documentar,
    investigar,
    resumir,
    ejecutar,
    disenar,
    /// UI-ACTION: control de la propia IDE (tema, vista, sesión). Tarea
    /// determinística — no consume modelo: el ejecutor emite un evento
    /// `ui_action` whitelist-validado y la cabina lo aplica.
    ui,

    pub fn toText(self: TaskType) []const u8 {
        return switch (self) {
            .planificar => "planificar",
            .programar => "programar",
            .programar_c => "programar_c",
            .programar_cpp => "programar_cpp",
            .programar_zig => "programar_zig",
            .testear => "testear",
            .auditar => "auditar",
            .corregir => "corregir",
            .documentar => "documentar",
            .investigar => "investigar",
            .resumir => "resumir",
            .ejecutar => "ejecutar",
            .disenar => "disenar",
            .ui => "ui",
        };
    }

    pub fn allowsPaidEscalation(self: TaskType) bool {
        return switch (self) {
            // FIRE-2026-07-10: programar/testear añadidos — la tarea de
            // implementación es el corazón de toda orden "crea X"; sin escalada,
            // cuando los :free caen por rate-limit la orden entera muere aunque
            // haya modelos de pago vivos (visto en órdenes 316-324: t1/programar
            // agotaba los free y fallaba; t3/auditar sí completaba). El pago
            // sigue siendo ÚLTIMO recurso: entra al final de la cola de
            // respaldos, tope 2, solo tras fallar todos los free.
            .planificar, .auditar, .corregir, .programar, .programar_c, .programar_cpp, .programar_zig, .testear => true,
            else => false,
        };
    }
};

pub const GovernanceMode = enum {
    free_tier_first,
    paid_tier_first,
    hybrid,
    local_only,

    pub fn parse(text: []const u8) GovernanceMode {
        return parseStrict(text) orelse .hybrid;
    }

    /// QA-A H9: null si `text` no es ningún modo conocido (nombre canónico o
    /// alias corto). `parse` cae en `hybrid`; quien recibe texto del usuario
    /// usa esta y rechaza lo desconocido sin cambiar nada.
    pub fn parseStrict(text: []const u8) ?GovernanceMode {
        if (std.mem.eql(u8, text, "paid_tier_first") or std.mem.eql(u8, text, "paid")) return .paid_tier_first;
        if (std.mem.eql(u8, text, "free_tier_first") or std.mem.eql(u8, text, "free")) return .free_tier_first;
        if (std.mem.eql(u8, text, "local_only") or std.mem.eql(u8, text, "local") or std.mem.eql(u8, text, "solo_local")) return .local_only;
        if (std.mem.eql(u8, text, "hybrid")) return .hybrid;
        return null;
    }

    /// QA-A H9: el nombre que ve el usuario (el mismo que escribe en la CLI),
    /// no el interno que se guarda en `settings`.
    pub fn shortName(self: GovernanceMode) []const u8 {
        return switch (self) {
            .free_tier_first => "free",
            .paid_tier_first => "paid",
            .hybrid => "hybrid",
            .local_only => "local",
        };
    }

    pub fn toText(self: GovernanceMode) []const u8 {
        return switch (self) {
            .free_tier_first => "free_tier_first",
            .paid_tier_first => "paid_tier_first",
            .hybrid => "hybrid",
            .local_only => "local_only",
        };
    }
};

/// En modo Híbrido, la etapa decide el nivel de servicio.
/// Se prefieren modelos de pago al planificar y auditar. Son las dos
/// etapas donde un fallo contamina todo lo que viene detrás — un plan malo se
/// propaga a cada tarea del grafo, y una auditoría barata anula la red de
/// seguridad entera. El resto (construcción, tests, documentación) es volumen, y
/// ahí el auditor ya cubre la calidad.
///
/// Antes de esto, `route()` descartaba TODO candidato de pago mientras quedara un
/// gratuito con salud ≥ 0,10, así que Híbrido era indistinguible de Free-Tier-First.
pub fn hybridPrefersPaid(task_type: TaskType) bool {
    return switch (task_type) {
        .planificar, .auditar => true,
        else => false,
    };
}

/// Tier preferido para (modo, etapa). Es el ÚNICO sitio donde se decide si una
/// cadena de candidatos va free-first o paid-first. `live_worker` y `superagent`
/// lo consultan en vez de tener su propio criterio: tener dos políticas fue el
/// fallo real —`LiveLlm.init` ordenaba por `is_free DESC` a fuego, ignorando
/// `settings.governance_mode`, así que la misma configuración daba resultados
/// distintos según por qué camino entrara la orden.
pub fn prefersFreeFirst(mode: GovernanceMode, task_type: TaskType) bool {
    return switch (mode) {
        .free_tier_first, .local_only => true,
        .paid_tier_first => false,
        .hybrid => !hybridPrefersPaid(task_type),
    };
}

pub const RouteRequest = struct {
    task_type: TaskType,
    required_context: i32,
    needs_vision: bool = false,
    governance_mode: ?GovernanceMode = null,
    allow_paid_when_no_free: bool = true,
    escalation_justification: ?[]const u8 = null,
    /// FR-001 spec 013: modelos que NO pueden tomar esta tarea (p. ej. los
    /// productores del artefacto que una tarea `auditar` va a revisar — nadie
    /// se auto-audita). El filtro actúa en `rankCandidates`, así que cubre al
    /// primario Y a toda la cadena de respaldos.
    exclude_models: []const i64 = &.{},
    /// PIXEL-DEVTEAM-05: hint de modelo del especialista. Si el candidato coincide,
    /// recibe un boost de score, pero nunca salta la gobernanza free-first.
    preferred_model: ?[]const u8 = null,
};

/// P8: fila de model_health ya descargada, con lo justo para decidir factor y
/// clase. `proved` es el `evidenceClass` calculado una sola vez.
pub const HealthSnapshot = struct {
    ok: i64,
    err: i64,
    last_ok_at: ?i64,
    last_err_at: ?i64,
    status: []const u8,
    proved: bool,

    fn deinit(self: *@This(), allocator: std.mem.Allocator) void {
        if (self.status.len > 0) allocator.free(self.status);
        self.* = undefined;
    }
};

pub const Candidate = struct {
    provider_id: i64,
    provider_name: []const u8,
    model_id: i64,
    model_name: []const u8,
    api_key_id: i64,
    is_free: bool,
    score: f64,
    health_factor: f64,
    /// P8: true si el modelo tiene éxito MEDIDO (≥MIN muestras con ok>0). Se
    /// usa para que, dentro de un tier, lo probado ordene SIEMPRE delante de
    /// lo nunca probado, aunque el score heurístico del candidato sea mayor.
    proven: bool,
    reason: []const u8,

    pub fn deinit(self: Candidate, allocator: std.mem.Allocator) void {
        allocator.free(self.provider_name);
        allocator.free(self.model_name);
        allocator.free(self.reason);
    }
};

pub const AuditVerdict = enum {
    pass,
    partial,
    fail,
};

pub const FallbackChain = struct {
    levels: [MAX_FALLBACK_LEVELS]i64,

    pub fn init(levels: [MAX_FALLBACK_LEVELS]i64) FallbackChain {
        return .{ .levels = levels };
    }

    pub fn nextAfter(self: FallbackChain, current_model_id: i64) ?i64 {
        for (self.levels, 0..) |model_id, index| {
            if (model_id == current_model_id) {
                if (index + 1 >= self.levels.len) return null;
                return self.levels[index + 1];
            }
        }
        return self.levels[0];
    }
};

pub const Router = struct {
    allocator: std.mem.Allocator,
    catalog: db.Connection,
    ledger: ?db.Connection,
    now: i64,
    quota_current: *const fn (std.mem.Allocator, db.Connection, @import("cli_quota.zig").Cli) anyerror!@import("cli_quota.zig").Snapshot = @import("cli_quota.zig").current,
    // HEALTH-03: conexión opcional a runtime.db para sesgar por salud (tabla
    // model_health). Si es null, healthFactor es neutral (NO_EVIDENCE_FACTOR en
    // P8, antes 1.0) → sin cambio de comportamiento. La inyecta el llamador con
    // setHealthConn.
    health: ?db.Connection = null,
    // T5: cache simple de healthFactor.
    health_cache: std.StringHashMap(f64) = undefined,
    // P8: snapshot de model_health (ok/err/timestamps) por provider|model, para
    // no leer la fila dos veces por candidato (una vez para el factor y otra
    // para decidir la clase proven/unproven).
    health_snapshot_cache: std.StringHashMap(HealthSnapshot) = undefined,

    pub fn init(allocator: std.mem.Allocator, catalog: db.Connection, ledger: ?db.Connection, now: i64) Router {
        return .{ .allocator = allocator, .catalog = catalog, .ledger = ledger, .now = now, .health_cache = std.StringHashMap(f64).init(allocator), .health_snapshot_cache = std.StringHashMap(HealthSnapshot).init(allocator) };
    }

    /// Inyecta runtime.db para que el ranking penalice modelos conocidos como no
    /// funcionales (401/402/empty) y prefiera los entitled+vivos (HEALTH-03).
    pub fn setHealthConn(self: *Router, conn: db.Connection) void {
        self.health = conn;
    }

    pub fn getGovernanceMode(self: *Router) GovernanceMode {
        const stmt = self.catalog.prepare("SELECT value FROM settings WHERE key='governance_mode'") catch return .hybrid;
        defer self.catalog.finalize(stmt);
        if (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            if (db.c.sqlite3_column_text(stmt, 0)) |ptr| {
                const val = ptr[0..std.mem.len(ptr)];
                return GovernanceMode.parse(val);
            }
        }
        return .hybrid;
    }

    pub fn setGovernanceMode(self: *Router, mode: GovernanceMode) !void {
        const stmt = try self.catalog.prepare(
            \\INSERT INTO settings (key, value) VALUES ('governance_mode', ?)
            \\ON CONFLICT(key) DO UPDATE SET value=excluded.value
        );
        defer self.catalog.finalize(stmt);
        try db.bindText(stmt, 1, mode.toText());
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.ExecFailed;
    }

    /// T5: Invalida el cache de healthFactor.
    pub fn invalidateHealthCache(self: *Router) void {
        var it = self.health_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.health_cache.clearAndFree();
        var sit = self.health_snapshot_cache.iterator();
        while (sit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.health_snapshot_cache.clearAndFree();
    }

    /// T5: Libera el cache de healthFactor. Llamar al destruir el Router.
    pub fn deinitHealthCache(self: *Router) void {
        var it = self.health_cache.iterator();
        while (it.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
        }
        self.health_cache.deinit();
        var sit = self.health_snapshot_cache.iterator();
        while (sit.next()) |entry| {
            self.allocator.free(entry.key_ptr.*);
            entry.value_ptr.deinit(self.allocator);
        }
        self.health_snapshot_cache.deinit();
    }

    /// Factor multiplicativo de salud por (proveedor, modelo). Sin conexión o sin
    /// dato → NO_EVIDENCE_FACTOR (P8): un modelo sin historial YA NO vale como
    /// si fuera perfecto (1.0); se prueba, pero ordena detrás de quien tiene
    /// éxito medido. Conocidos malos por entitlement/billing (auth_failed/quota)
    /// se hunden casi a cero pero NO se excluyen de forma dura (si TODOS están
    /// mal, el router aún elige el menos malo).
    /// P8: lee (y cachea) la fila de model_health del (provider, model). Sin
    /// conexión o sin fila → null (tratado como `unproven` por el llamador).
    fn healthSnapshot(self: *Router, provider: []const u8, model: []const u8) ?HealthSnapshot {
        const conn = self.health orelse return null;
        const key = std.fmt.allocPrint(self.allocator, "{s}|{s}", .{ provider, model }) catch return null;
        if (self.health_snapshot_cache.get(key)) |cached| {
            self.allocator.free(key);
            return cached;
        }
        var model_id_buf: [256]u8 = undefined;
        const model_id = std.fmt.bufPrint(&model_id_buf, "{s}/{s}", .{ provider, model }) catch model;
        const stmt = conn.prepare("SELECT COALESCE(last_err_kind,''), COALESCE(ok_count,0), COALESCE(err_count,0), last_ok_at, last_err_at FROM model_health WHERE model_id=? OR model_id=?") catch {
            self.allocator.free(key);
            return null;
        };
        defer conn.finalize(stmt);
        db.bindText(stmt, 1, model_id) catch {
            self.allocator.free(key);
            return null;
        };
        db.bindText(stmt, 2, model) catch {
            self.allocator.free(key);
            return null;
        };
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) {
            self.allocator.free(key);
            return null;
        }
        const s_ptr = db.c.sqlite3_column_text(stmt, 0);
        if (s_ptr == null) {
            self.allocator.free(key);
            return null;
        }
        const last_ok_raw = db.c.sqlite3_column_type(stmt, 3);
        const last_err_raw = db.c.sqlite3_column_type(stmt, 4);
        const snap = HealthSnapshot{
            .ok = db.c.sqlite3_column_int64(stmt, 1),
            .err = db.c.sqlite3_column_int64(stmt, 2),
            .last_ok_at = if (last_ok_raw == db.c.SQLITE_NULL) null else @intCast(db.c.sqlite3_column_int64(stmt, 3)),
            .last_err_at = if (last_err_raw == db.c.SQLITE_NULL) null else @intCast(db.c.sqlite3_column_int64(stmt, 4)),
            .status = self.allocator.dupe(u8, s_ptr[0..std.mem.len(s_ptr)]) catch {
                self.allocator.free(key);
                return null;
            },
            .proved = evidenceClass(db.c.sqlite3_column_int64(stmt, 1), db.c.sqlite3_column_int64(stmt, 2)) == .proven,
        };
        self.health_snapshot_cache.put(key, snap) catch {
            self.allocator.free(snap.status);
            self.allocator.free(key);
            return null;
        };
        return snap;
    }

    fn healthFactor(self: *Router, provider: []const u8, model: []const u8) f64 {
        // Sin conexión de salud NO se cachea: el llamador puede inyectarla después
        // (como HEALTH-03: llama sin setHealthConn y luego con). Devolver
        // NO_EVIDENCE_FACTOR sin caché da el mismo valor que un sin-fila, pero
        // deja que una conexión posterior se vea reflejada.
        if (self.health == null) return NO_EVIDENCE_FACTOR;
        // T5: factor cacheado.
        const key = std.fmt.allocPrint(self.allocator, "{s}|{s}", .{ provider, model }) catch return NO_EVIDENCE_FACTOR;
        if (self.health_cache.get(key)) |cached| {
            self.allocator.free(key);
            return cached;
        }
        const snap = self.healthSnapshot(provider, model) orelse {
            // Sin ninguna fila en model_health: NO es "perfecto" (antes daba
            // 1.0 neutral). El class separado (proven/unproven) lo baja dentro
            // del tier; este factor da la proporción para el score, siempre
            // por debajo de un historial real pero por encima de un conocido
            // malo (auth/quota se hunden solos con severity×reliability).
            self.health_cache.put(key, NO_EVIDENCE_FACTOR) catch self.allocator.free(key);
            return NO_EVIDENCE_FACTOR;
        };
        // factor = severidad del último status × fiabilidad mejorada por edad.
        const factor = statusToFactor(snap.status) * agedReliability(snap.ok, snap.err, snap.last_ok_at, snap.last_err_at, self.now);
        self.health_cache.put(key, factor) catch self.allocator.free(key);
        return factor;
    }

    /// T5: Lookup table for health status -> factor. Replaces if-chain.
    fn statusToFactor(s: []const u8) f64 {
        if (s.len == 0 or std.mem.eql(u8, s, "ok")) return 1.0;
        if (std.mem.eql(u8, s, "empty")) return 0.5;
        if (std.mem.eql(u8, s, "rate_limited")) return 0.15;
        if (std.mem.eql(u8, s, "not_found")) return 0.05;
        if (std.mem.eql(u8, s, "auth_failed")) return 0.05;
        if (std.mem.eql(u8, s, "quota")) return 0.05;
        if (std.mem.eql(u8, s, "timeout")) return 0.3;
        return 0.3; // error or unknown
    }

    /// Evidencia de la matriz de compatibilidad para (provider, model), o
    /// `found=false` cuando no hay fila usable: tabla inexistente, modelo no
    /// medido por ese proveedor, payload 'dummy' (fabricado, no capturado),
    /// `metadata_updated_at` ilegible o foto más vieja que MATRIX_TTL_SECONDS.
    /// Sin cache: una consulta por candidato, como `catalogModelIsFree`, y el
    /// llamador libera con `deinit` — no exige un deinit del Router.
    fn matrixEvidence(self: *Router, provider: []const u8, model: []const u8) MatrixEvidence {
        var model_prefixed_buf: [256]u8 = undefined;
        const model_prefixed = std.fmt.bufPrint(&model_prefixed_buf, "{s}/{s}", .{ provider, model }) catch model;
        const stmt = self.catalog.prepare(
            \\SELECT cap_chat_status, cap_streaming_status, cap_reasoning_status,
            \\       metadata_updated_at, metadata_payload_type
            \\FROM discovery_snapshots_v2
            \\WHERE provider = ? AND (model_id = ? OR model_id = ?)
        ) catch {
            // Tabla ausente (catálogo viejo) = matriz vacía: comportamiento anterior.
            return .{};
        };
        defer self.catalog.finalize(stmt);
        db.bindText(stmt, 1, provider) catch return .{};
        db.bindText(stmt, 2, model) catch return .{};
        db.bindText(stmt, 3, model_prefixed) catch return .{};
        var evidence = MatrixEvidence{};
        if (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            const payload_ptr = db.c.sqlite3_column_text(stmt, 4);
            const updated_ptr = db.c.sqlite3_column_text(stmt, 3);
            const payload_type = if (payload_ptr != null) payload_ptr[0..std.mem.len(payload_ptr)] else "";
            const updated_at = if (updated_ptr != null) updated_ptr[0..std.mem.len(updated_ptr)] else "";
            const updated_ts = std.fmt.parseInt(i64, updated_at, 10) catch null;
            // Solo una foto REAL y FRESCA habla por el modelo: 'dummy' es una
            // fila fabricada (no medida) y una foto caducada describe al
            // modelo de hace un mes, no al de hoy. 'live_probe' también es
            // usable: es una medición directa del modelo (sondeo real), no
            // un listado — evidencia más fuerte que 'captured_real'.
            const usable = (std.mem.eql(u8, payload_type, "captured_real") or
                std.mem.eql(u8, payload_type, "live_probe")) and
                updated_ts != null and self.now - updated_ts.? <= MATRIX_TTL_SECONDS;
            if (usable) {
                evidence.found = true;
                evidence.chat = self.allocator.dupe(u8, columnText(stmt, 0)) catch "";
                evidence.streaming = self.allocator.dupe(u8, columnText(stmt, 1)) catch "";
                evidence.reasoning = self.allocator.dupe(u8, columnText(stmt, 2)) catch "";
                evidence.updated_at = self.allocator.dupe(u8, updated_at) catch "";
            }
        }
        return evidence;
    }

    fn columnText(stmt: *db.c.sqlite3_stmt, col: c_int) []const u8 {
        const ptr = db.c.sqlite3_column_text(stmt, col);
        return if (ptr != null) ptr[0..std.mem.len(ptr)] else "";
    }

    /// Casilla medida como INCOMPATIBLE por la fuente ('no'). 'unknown' no es
    /// un 'no': no probado no puede vetar, solo deja de favorecer.
    fn capIncompatible(status: []const u8) bool {
        return std.mem.eql(u8, status, "no");
    }

    /// Casilla medida como soportada de verdad ('yes' o equivalente afirmativo).
    fn capConfirmed(status: []const u8) bool {
        return std.mem.eql(u8, status, "yes") or std.mem.eql(u8, status, "supported") or std.mem.eql(u8, status, "native");
    }

    pub fn seedInitialScores(self: *Router) RouterError!void {
        const task_types = [_]TaskType{ .planificar, .programar, .programar_c, .programar_cpp, .programar_zig, .testear, .auditar, .corregir, .documentar, .investigar, .resumir, .ejecutar, .disenar };
        const stmt = try self.catalog.prepare("SELECT id, model_name FROM models");
        defer self.catalog.finalize(stmt);
        while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            const model_id = db.c.sqlite3_column_int64(stmt, 0);
            const model_ptr = db.c.sqlite3_column_text(stmt, 1);
            const model_name = model_ptr[0..std.mem.len(model_ptr)];
            for (task_types) |task_type| {
                const score = initialHeuristicScore(model_name, task_type);
                // F9 (§8): parámetros ENLAZADOS, no interpolación (antes allocPrint {d}/{s}).
                const ins = try self.catalog.prepare("INSERT OR IGNORE INTO model_scores (model_id, task_type, score, sample_count, updated_at) VALUES (?, ?, ?, 0, ?)");
                defer self.catalog.finalize(ins);
                try db.bindInt(ins, 1, model_id);
                try db.bindText(ins, 2, task_type.toText());
                try db.bindDouble(ins, 3, score);
                try db.bindInt(ins, 4, self.now);
                if (db.c.sqlite3_step(ins) != db.c.SQLITE_DONE) return error.ExecFailed;
            }
        }
    }

    pub fn route(self: *Router, request: RouteRequest) RouterError!Candidate {
        var all = try self.rankCandidates(request);
        defer {
            for (all.items) |candidate| candidate.deinit(self.allocator);
            all.deinit(self.allocator);
        }
        if (all.items.len == 0) return error.NoCandidates;

        const mode = request.governance_mode orelse self.getGovernanceMode();
        const prefer_free = prefersFreeFirst(mode, request.task_type);
        const roster_activo = rosterCubreAlguno(all.items);

        var has_healthy = false;
        for (all.items) |candidate| {
            if (isRouteEligible(candidate, request, roster_activo) and !isHardBad(candidate)) {
                has_healthy = true;
                break;
            }
        }

        if (!has_healthy) {
            var best: ?Candidate = null;
            for (all.items) |candidate| {
                if (!isRouteEligible(candidate, request, roster_activo)) continue;
                if (best == null or candidate.score > best.?.score) best = candidate;
            }
            if (best) |candidate| {
                if (!candidate.is_free) try self.recordPaidSelection(candidate, request, prefer_free);
                return try cloneCandidate(self.allocator, candidate);
            }
            return error.NoCandidates;
        }

        // GOBERNANZA-HIBRIDO: se busca el tier PREFERIDO para esta etapa, no "free".
        // El descarte solo aplica si ese tier tiene algún candidato sano: si la
        // etapa pide pago y no hay ninguno vivo, la cadena cae al free en vez de
        // quedarse sin candidatos (y al revés).
        var has_preferred = false;
        for (all.items) |candidate| {
            if (isRouteEligible(candidate, request, roster_activo) and !isHardBad(candidate) and candidate.is_free == prefer_free) {
                has_preferred = true;
                break;
            }
        }

        for (all.items) |candidate| {
            if (isHardBad(candidate)) continue;
            if (has_preferred and candidate.is_free != prefer_free) continue;
            if (!isRouteEligible(candidate, request, roster_activo)) continue;
            if (!candidate.is_free) try self.recordPaidSelection(candidate, request, prefer_free);
            return try cloneCandidate(self.allocator, candidate);
        }
        return error.NoCandidates;
    }

    /// Registra la fila de `audit_ledger` de toda selección de pago (§1.3 exige
    /// trazabilidad de cada una) y decide si hace falta justificación del llamador.
    ///
    /// La distinción importa: si la etapa era free-first y aun así acabamos en
    /// pago, eso es una ESCALADA y el llamador debe justificarla —esa puerta es
    /// la que impide que un free-first se gaste dinero por descuido. Si la
    /// gobernanza ya pedía pago para esta etapa (Paid-Tier-First, o Híbrido en
    /// planificar/auditar), no hay nada que justificar: el usuario ya lo decidió
    /// al elegir el modo. Exigir justificación ahí habría roto la planificación
    /// de todo llamador que hoy no pasa ninguna.
    fn recordPaidSelection(self: *Router, candidate: Candidate, request: RouteRequest, prefer_free: bool) RouterError!void {
        if (request.escalation_justification) |justification| {
            if (justification.len > 0) return self.recordEscalation(candidate, request.task_type, justification);
        }
        if (prefer_free) return error.PaidEscalationRequiresJustification;
        var buf: [192]u8 = undefined;
        const auto = std.fmt.bufPrint(
            &buf,
            "politica de gobernanza: etapa '{s}' asignada a pago",
            .{request.task_type.toText()},
        ) catch "politica de gobernanza: etapa asignada a pago";
        return self.recordEscalation(candidate, request.task_type, auto);
    }

    pub fn rankCandidates(self: *Router, request: RouteRequest) RouterError!std.ArrayList(Candidate) {
        return self.rankCandidatesWithPreferences(request, true);
    }

    /// Counterfactual for preflight diagnostics only. All eligibility rules
    /// remain active; the caller compares this baseline with automatic vetoes.
    pub fn rankCandidatesBeforePreferences(self: *Router, request: RouteRequest) RouterError!std.ArrayList(Candidate) {
        return self.rankCandidatesWithPreferences(request, false);
    }

    fn rankCandidatesWithPreferences(self: *Router, request: RouteRequest, comptime apply_preferences: bool) RouterError!std.ArrayList(Candidate) {
        var candidates = std.ArrayList(Candidate).empty;
        errdefer {
            for (candidates.items) |candidate| candidate.deinit(self.allocator);
            candidates.deinit(self.allocator);
        }
        // El modo se lee UNA vez, no una por fila: `getGovernanceMode` prepara y
        // ejecuta un statement, y estaba dentro del bucle — con el catálogo real
        // del usuario (142 modelos con clave activa) eso eran 142 consultas por
        // cada llamada a rankCandidates. Además decide la consulta: en
        // `local_only` el JOIN con api_keys desaparece (los proveedores locales
        // no tienen clave) y el filtro es p.is_local.
        const mode = request.governance_mode orelse self.getGovernanceMode();
        // F9 (§8): parámetros ENLAZADOS, no interpolación (antes allocPrint {d}/{s}).
        const stmt = try self.catalog.prepare(if (mode == .local_only)
            \\SELECT p.id, p.name, m.id, m.model_name, 0, m.is_free, m.is_favorite, s.score,
            \\       1, 0,
            \\       COALESCE(m.context_window, 0), COALESCE(m.latency_p50_ms, ?), m.is_generative, m.modalities
            \\FROM models m
            \\JOIN providers p ON p.id = m.provider_id
            \\LEFT JOIN model_scores s ON s.model_id = m.id AND s.task_type = ?
            \\WHERE p.enabled = 1 AND m.available = 1 AND p.is_local = 1
        ++ (if (apply_preferences) @import("model_selection.zig").automatic_filter else "")
        else
            \\SELECT p.id, p.name, m.id, m.model_name, k.id, m.is_free, m.is_favorite, s.score,
            \\       COALESCE(k.quota_limit, 1), COALESCE(k.quota_used, 0),
            \\       COALESCE(m.context_window, 0), COALESCE(m.latency_p50_ms, ?), m.is_generative, m.modalities
            \\FROM models m
            \\JOIN providers p ON p.id = m.provider_id
            \\JOIN api_keys k ON k.provider_id = p.id
            \\LEFT JOIN model_scores s ON s.model_id = m.id AND s.task_type = ?
            \\WHERE p.enabled = 1 AND m.available = 1 AND k.status = 'active'
        ++ (if (apply_preferences) @import("model_selection.zig").automatic_filter else ""));
        defer self.catalog.finalize(stmt);
        try db.bindInt(stmt, 1, @as(i64, @intFromFloat(DEFAULT_LATENCY_MS)));
        try db.bindText(stmt, 2, request.task_type.toText());
        while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            const provider_name_ptr = db.c.sqlite3_column_text(stmt, 1);
            const model_name_ptr = db.c.sqlite3_column_text(stmt, 3);
            const provider_name = provider_name_ptr[0..std.mem.len(provider_name_ptr)];
            const model_name = model_name_ptr[0..std.mem.len(model_name_ptr)];
            if (@import("cli_quota.zig").cliForProvider(provider_name)) |cli| {
                const quota = self.quota_current(self.allocator, self.catalog, cli) catch |err| blk: {
                    std.log.warn("quota read failed for {s}: {s}; treating as unknown", .{ provider_name, @errorName(err) });
                    break :blk @import("cli_quota.zig").Snapshot{ .cli = cli };
                };
                if (quota.blocked()) continue;
            }
            if (request.needs_vision and !capVisionLiveProbed(self.catalog, provider_name, model_name, self.now)) continue;
            const is_free = db.c.sqlite3_column_int(stmt, 5) == 1 and
                catalogModelIsFree(self.catalog, provider_name, model_name);
            switch (mode) {
                .free_tier_first => {
                    if (!is_free) continue;
                },
                .paid_tier_first => {
                    if (is_free) continue;
                },
                // En local_only el SQL ya filtró por p.is_local: el JOIN con
                // api_keys no existe en esa consulta (los locales no tienen
                // clave), así que aquí no queda nada que descartar.
                .hybrid, .local_only => {},
            }
            // FIRE-2026-07-10: los modelos que no generan texto NO entran al ranking.
            // Penalizarlos en el prior no bastaba por dos vías reales: (a) model_scores
            // puede tener seeds/aprendizajes viejos que pisan el prior (base_score viene
            // de la tabla), y (b) con la salud degradando a ~0.04 a todos los chat models
            // rate-limiteados, un embed/multimedia con salud virgen (1.0) ganaba el
            // PRIMARIO (visto en vivo: nv-embedcode-7b-v1 asignado a auditar, orden 322).
            if (!@import("model_selection.zig").textGeneration(model_name, db.c.sqlite3_column_int(stmt, 12) != 0, columnText(stmt, 13))) continue;
            // FIX-2 / ROUT-02: si NO hay score aprendido en model_scores (LEFT JOIN miss →
            // columna NULL), usar el prior heurístico de capacidad en vez de un 0.50 plano.
            // Esto hace que el router honre la fortaleza en código (deepseek/qwen/command-a >
            // genéricos) aunque la tabla esté vacía, que es el estado real tras el discovery
            // (que borra y re-crea los modelos con IDs nuevos, orfanando cualquier seed).
            // Los scores aprendidos (sample_count>0) siguen teniendo precedencia cuando existen.
            const is_favorite = db.c.sqlite3_column_int(stmt, 6) == 1;
            const base_score = if (db.c.sqlite3_column_type(stmt, 7) == db.c.SQLITE_NULL)
                initialHeuristicScore(model_name, request.task_type)
            else
                db.c.sqlite3_column_double(stmt, 7);
            const quota_limit = db.c.sqlite3_column_double(stmt, 8);
            const quota_used = db.c.sqlite3_column_double(stmt, 9);
            const context_window = db.c.sqlite3_column_double(stmt, 10);
            const latency_ms = db.c.sqlite3_column_double(stmt, 11);
            const hf = self.healthFactor(provider_name, model_name);
            // MATRIZ-RANKING: un 'no' medido en una capacidad requerida excluye
            // al candidato del ranking entero — live_worker llama siempre con
            // .stream=true, así que un modelo sin chat o sin streaming solo
            // quemaría un intento real y una marca de salud antes de fallar.
            // 'unknown' no veta: no probado no es incompatible.
            var matrix = self.matrixEvidence(provider_name, model_name);
            defer matrix.deinit(self.allocator);
            if (matrix.found and (capIncompatible(matrix.chat) or capIncompatible(matrix.streaming))) continue;
            var matrix_factor: f64 = 1.0;
            if (matrix.found) {
                if (capConfirmed(matrix.chat)) matrix_factor *= MATRIX_CONFIRMED_FACTOR;
                if (capConfirmed(matrix.streaming)) matrix_factor *= MATRIX_STREAMING_FACTOR;
                if (preferredMatrixCapability(request.task_type)) |cap| {
                    const preferred_status = if (std.mem.eql(u8, cap, "reasoning")) matrix.reasoning else matrix.chat;
                    if (capConfirmed(preferred_status)) {
                        matrix_factor *= MATRIX_PREFERRED_YES;
                    } else if (capIncompatible(preferred_status)) {
                        matrix_factor *= MATRIX_PREFERRED_NO;
                    }
                }
            }
            var matrix_state_buf: [160]u8 = undefined;
            const matrix_state = if (matrix.found)
                std.fmt.bufPrint(&matrix_state_buf, "chat:{s},streaming:{s},reasoning:{s},updated:{s}", .{ matrix.chat, matrix.streaming, matrix.reasoning, matrix.updated_at }) catch "truncated"
            else
                "none";
            const favorite_factor: f64 = if (is_favorite) 1.60 else 1.0;
            // P05: para planificar preferimos modelos con reasoning (boost 1.30); para
            // tareas fast-generative los penalizamos (0.65). Modelos no-reasoning en
            // planificación quedan ligeramente desfavorecidos (0.85) frente a reasoning.
            const reasoning_factor: f64 = if (isReasoningModel(model_name) and prefersFastGenerative(request.task_type)) 0.65 else if (request.task_type == .planificar and isReasoningModel(model_name)) 1.30 else if (request.task_type == .planificar) 0.85 else 1.0;
            var score = base_score * quotaFactor(quota_limit, quota_used) * contextFactor(context_window, request.required_context) * latencyFactor(latency_ms) * hf * favorite_factor * reasoning_factor * matrix_factor;
            // PIXEL-DEVTEAM-05: boost honesto si el candidato coincide con el hint del especialista.
            if (request.preferred_model) |hint| {
                if (std.mem.indexOf(u8, model_name, hint) != null or std.mem.indexOf(u8, hint, model_name) != null) {
                    score *= 1.15;
                }
            }
            const reason = try std.fmt.allocPrint(
                self.allocator,
                "capability={d:.3} quota={d:.3} context={d:.3} latency={d:.3} health={d:.3} favorite={d:.3} reasoning={d:.3} matrix={d:.3} matrix_state={s}",
                .{ base_score, quotaFactor(quota_limit, quota_used), contextFactor(context_window, request.required_context), latencyFactor(latency_ms), hf, favorite_factor, reasoning_factor, matrix_factor, matrix_state },
            );
            try candidates.append(self.allocator, .{
                .provider_id = db.c.sqlite3_column_int64(stmt, 0),
                .provider_name = try self.allocator.dupe(u8, provider_name),
                .model_id = db.c.sqlite3_column_int64(stmt, 2),
                .model_name = try self.allocator.dupe(u8, model_name),
                .api_key_id = db.c.sqlite3_column_int64(stmt, 4),
                .is_free = db.c.sqlite3_column_int(stmt, 5) == 1 and
                    catalogModelIsFree(self.catalog, provider_name, model_name),
                .score = score,
                .health_factor = hf,
                .proven = if (self.healthSnapshot(provider_name, model_name)) |s| s.proved else false,
                .reason = reason,
            });
        }
        // Una clave activa adicional del mismo proveedor no debe duplicar el mismo
        // modelo en router_candidates ni en la cola de fallback. La rotación de claves
        // ocurre dentro del conector/proveedor; aquí mantenemos un candidato por modelo.
        var i: usize = 0;
        while (i < candidates.items.len) : (i += 1) {
            var j = i + 1;
            while (j < candidates.items.len) {
                if (candidates.items[i].model_id == candidates.items[j].model_id) {
                    if (candidates.items[j].score > candidates.items[i].score) {
                        const better = candidates.items[j];
                        candidates.items[j] = candidates.items[i];
                        candidates.items[i] = better;
                    }
                    candidates.items[j].deinit(self.allocator);
                    _ = candidates.swapRemove(j);
                } else {
                    j += 1;
                }
            }
        }
        // FR-001 de spec 013: excluir los modelos constructores para tareas de
        // auditoría (uno por productor del artefacto auditado).
        if (request.exclude_models.len > 0) {
            var exclude_i: usize = 0;
            while (exclude_i < candidates.items.len) {
                var excluded = false;
                for (request.exclude_models) |em| {
                    if (candidates.items[exclude_i].model_id == em) {
                        excluded = true;
                        break;
                    }
                }
                if (excluded) {
                    candidates.items[exclude_i].deinit(self.allocator);
                    _ = candidates.swapRemove(exclude_i);
                } else {
                    exclude_i += 1;
                }
            }
        }
        std.mem.sort(Candidate, candidates.items, SortContext{
            .prefer_free = prefersFreeFirst(mode, request.task_type),
        }, candidateLessThan);
        return candidates;
    }

    pub fn recordFallback(self: *Router, from_model_id: i64, to_model_id: ?i64, reason: []const u8) RouterError!void {
        if (self.ledger) |ledger| {
            const target = to_model_id orelse -1;
            const content = try std.fmt.allocPrint(self.allocator, "fallback:{d}:{d}:{s}", .{ from_model_id, target, reason });
            defer self.allocator.free(content);
            const hash = db.computeRowHash(null, content);
            // T3: parametrized INSERT with prepare+bind (no allocPrint of SQL).
            const stmt = try ledger.prepare("INSERT INTO audit_ledger (ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, notes, row_hash) VALUES (?, 'model_router', ?, 'REAUDIT', 'PARTIAL', ?, 'router', 'fallback', ?, ?)");
            defer ledger.finalize(stmt);
            try db.bindInt(stmt, 1, self.now);
            try db.bindInt(stmt, 2, from_model_id);
            try db.bindInt(stmt, 3, target);
            try db.bindText(stmt, 4, reason);
            try db.bindText(stmt, 5, &hash);
            if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.ExecFailed;
        }
    }

    pub fn recordAuditVerdict(self: *Router, model_id: i64, task_type: TaskType, verdict: AuditVerdict) RouterError!void {
        const current = try self.getScore(model_id, task_type);
        const verdict_score: f64 = switch (verdict) {
            .pass => 1.0,
            .partial => 0.55,
            .fail => 0.0,
        };
        const next_score = (current.score * (1.0 - MOVING_AVERAGE_WEIGHT)) + (verdict_score * MOVING_AVERAGE_WEIGHT);
        // F9 (§8): parámetros ENLAZADOS, no interpolación (antes allocPrint {d}/{s}).
        const stmt = try self.catalog.prepare("INSERT INTO model_scores (model_id, task_type, score, sample_count, updated_at) VALUES (?, ?, ?, 1, ?) " ++
            "ON CONFLICT(model_id, task_type) DO UPDATE SET score=?, sample_count=sample_count + 1, updated_at=?");
        defer self.catalog.finalize(stmt);
        try db.bindInt(stmt, 1, model_id);
        try db.bindText(stmt, 2, task_type.toText());
        try db.bindDouble(stmt, 3, next_score);
        try db.bindInt(stmt, 4, self.now);
        try db.bindDouble(stmt, 5, next_score);
        try db.bindInt(stmt, 6, self.now);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.ExecFailed;
    }

    fn getScore(self: *Router, model_id: i64, task_type: TaskType) RouterError!struct { score: f64, sample_count: i64 } {
        // F9 (§8): parámetros ENLAZADOS, no interpolación (antes allocPrint {d}/{s}).
        const stmt = try self.catalog.prepare("SELECT score, sample_count FROM model_scores WHERE model_id=? AND task_type=?");
        defer self.catalog.finalize(stmt);
        try db.bindInt(stmt, 1, model_id);
        try db.bindText(stmt, 2, task_type.toText());
        if (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            return .{ .score = db.c.sqlite3_column_double(stmt, 0), .sample_count = db.c.sqlite3_column_int64(stmt, 1) };
        }
        return .{ .score = 0.50, .sample_count = 0 };
    }

    fn recordEscalation(self: *Router, candidate: Candidate, task_type: TaskType, justification: []const u8) RouterError!void {
        if (self.ledger) |ledger| {
            const content = try std.fmt.allocPrint(self.allocator, "escalation:{s}:{s}:{s}", .{ candidate.model_name, task_type.toText(), justification });
            defer self.allocator.free(content);
            const hash = db.computeRowHash(null, content);
            // T3: parametrized INSERT with prepare+bind (no allocPrint of SQL).
            const stmt = try ledger.prepare("INSERT INTO audit_ledger (ts, subject_kind, subject_id, action, verdict, model_id, provider, evidence_ref, notes, row_hash) VALUES (?, 'model_router', ?, 'ESCALATION', 'PASS', ?, ?, 'route', ?, ?)");
            defer ledger.finalize(stmt);
            try db.bindInt(stmt, 1, self.now);
            try db.bindInt(stmt, 2, candidate.model_id);
            try db.bindText(stmt, 3, candidate.model_name);
            try db.bindText(stmt, 4, candidate.provider_name);
            try db.bindText(stmt, 5, justification);
            try db.bindText(stmt, 6, &hash);
            if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.ExecFailed;
        }
    }
};

const SortContext = struct { prefer_free: bool };

/// El tier preferido va primero; dentro del mismo tier manda P8: lo `proven`
/// (éxito medido) ordena SIEMPRE delante de lo `unproven` (sin historial o sin
/// muestras), y solo entonces el score. Antes el primer criterio era `a.is_free`
/// a secas, así que el ranking salía free-first incluso con la gobernanza
/// pidiendo pago — y dentro del tier mandaba el score heurístico: los Gemini
/// sin fila en model_health (0.88) ganaban al único modelo con historial (0.60).
fn candidateLessThan(ctx: SortContext, a: Candidate, b: Candidate) bool {
    if (a.is_free != b.is_free) return a.is_free == ctx.prefer_free;
    if (a.proven != b.proven) return a.proven;
    return a.score > b.score;
}

fn isHardBad(candidate: Candidate) bool {
    return candidate.health_factor < MIN_PRIMARY_HEALTH;
}

fn isRouteEligible(candidate: Candidate, request: RouteRequest, roster_activo: bool) bool {
    // ROSTER-PRUEBAS: el roster acota ANTES que la gobernanza. `roster_activo`
    // ya incluye la salvaguarda de "y alguno lo cumple" (ver `rosterCubreAlguno`):
    // un roster que no case con nada no deja al router sin candidatos.
    if (roster_activo and !model_roster.allowsEnv(candidate.provider_name, candidate.model_name)) return false;
    return candidate.is_free or request.task_type.allowsPaidEscalation() or request.allow_paid_when_no_free;
}

/// ¿Hay roster en vigor y algún candidato lo cumple? Público porque el
/// superagente arma su propia cola de respaldos desde `rankCandidates` — sin
/// pasar por `route`— y el roster tiene que acotar TAMBIÉN esa cola. Sin esto,
/// la cadena viva quedaba acotada pero los respaldos por tarea no: en la orden
/// #211 se usó Cohere/north-mini-code-1-0, que no estaba en el roster.
pub fn rosterCubreAlguno(candidates: []const Candidate) bool {
    if (model_roster.fromEnv() == null) return false;
    for (candidates) |candidate| {
        if (model_roster.allowsEnv(candidate.provider_name, candidate.model_name)) return true;
    }
    return false;
}

/// ¿El roster descarta este candidato? `activo` viene de `rosterCubreAlguno`
/// y ya incluye la salvaguarda de no dejar la cola vacía.
pub fn rosterDescarta(activo: bool, candidate: Candidate) bool {
    return activo and !model_roster.allowsEnv(candidate.provider_name, candidate.model_name);
}

fn isReasoningModel(model_name: []const u8) bool {
    return std.mem.indexOf(u8, model_name, "reasoning") != null;
}

fn prefersFastGenerative(task_type: TaskType) bool {
    return switch (task_type) {
        .programar, .programar_c, .programar_cpp, .programar_zig, .corregir, .ejecutar, .disenar => true,
        else => false,
    };
}

fn cloneCandidate(allocator: std.mem.Allocator, candidate: Candidate) RouterError!Candidate {
    return .{
        .provider_id = candidate.provider_id,
        .provider_name = try allocator.dupe(u8, candidate.provider_name),
        .model_id = candidate.model_id,
        .model_name = try allocator.dupe(u8, candidate.model_name),
        .api_key_id = candidate.api_key_id,
        .is_free = candidate.is_free,
        .score = candidate.score,
        .health_factor = candidate.health_factor,
        .proven = candidate.proven,
        .reason = try allocator.dupe(u8, candidate.reason),
    };
}

fn quotaFactor(limit: f64, used: f64) f64 {
    if (limit <= 0.0) return 1.0;
    const remaining = (limit - used) / limit;
    return std.math.clamp(remaining, 0.0, 1.0);
}

fn contextFactor(window: f64, required: i32) f64 {
    if (required <= 0) return 1.0;
    if (window <= 0.0) return MIN_CONTEXT_FACTOR;
    if (window >= @as(f64, @floatFromInt(required))) return 1.0;
    return std.math.clamp(window / @as(f64, @floatFromInt(required)), MIN_CONTEXT_FACTOR, 1.0);
}

fn latencyFactor(latency_ms: f64) f64 {
    if (latency_ms <= 0.0) return 1.0;
    return std.math.clamp(DEFAULT_LATENCY_MS / latency_ms, 0.10, 1.0);
}

/// FIRE-2026-07-10: ¿modelo que NO genera texto de chat (embeddings, rerank,
/// multimedia, safety/guard/parse...)? Para tareas de texto estos modelos no
/// deben entrar NI COMO RESPALDO: penalizarlos en el prior no bastaba — con la
/// salud degradando a todos los candidatos por igual (rate-limits masivos de
/// :free), un "lyria" (música, prior default 0.60) terminaba ASIGNADO a una
/// tarea de auditoría y "rerank-v3.5" a una de testing (órdenes 316-318 de la
/// prueba de fuego). La cadena de respaldos quemaba sus 5 huecos en modelos
/// que jamás podrán responder texto.
pub fn isNonTextGenModel(model_name: []const u8) bool {
    return @import("model_capabilities.zig").nonChat(model_name);
}

/// Prior de capacidad por nombre de modelo. Es `pub` porque `live_worker` lo
/// necesita: su cadena de candidatos desempataba por `m.id ASC` (orden de
/// inserción del catálogo) cuando `model_scores` no tenía fila, que es el estado
/// normal tras un discovery — y así acabó probando `command-a-translate`,
/// `command-r7b-arabic` y `c4ai-aya-vision` para una orden de Python.
pub fn initialHeuristicScore(model_name: []const u8, task_type: TaskType) f64 {
    // Initial priors are documented heuristics, seeded from public benchmark families
    // (SWE-bench/LiveCodeBench for coding, MMLU-style reasoning for planning/audit).
    //
    // FASE-AGENTIC-4: las exclusiones de modelos NO-conversacionales (embed/rerank/
    // vision/transcribe, safety/guard/parse/reward) DEBEN evaluarse ANTES que los
    // bonus por familia (gemini/claude/deepseek/...) — un modelo real en vivo,
    // "models/gemini-embedding-2" (Google AI Studio), matcheaba el bonus "gemini"
    // (0.88 para investigar) porque ese check corría primero y esta función RETORNA
    // en el primer match; la penalización de "embed" (más abajo) nunca se alcanzaba.
    // Resultado reproducido en vivo: el router asignó un modelo de EMBEDDINGS a una
    // tarea "investigar" — la llamada no genera texto de chat, así que el worker
    // nunca produjo un artefacto narrativo (ver synthesizeFinalAnswer/FASE-AGENTIC-2).
    // Ambas familias de exclusión van primero para que ningún bonus futuro pueda
    // volver a sombrearlas.
    if (std.mem.indexOf(u8, model_name, "embed") != null or
        std.mem.indexOf(u8, model_name, "rerank") != null or
        std.mem.indexOf(u8, model_name, "vision") != null or
        std.mem.indexOf(u8, model_name, "transcribe") != null)
    {
        return switch (task_type) {
            .programar, .programar_c, .programar_cpp, .programar_zig => 0.10,
            else => 0.25,
        };
    }
    // GOBERNANZA-PRIOR: especializados por IDIOMA. Generan texto —así que no son
    // `isNonTextGenModel`— pero no son modelos de código ni de planificación, y los
    // prefijos de familia de más abajo los estaban premiando: `command-a-translate`
    // caza "command-a" y `command-r7b-arabic` caza "command-r", los dos con 0.82 de
    // capacidad en programar. Ambos fueron elegidos EN VIVO para la orden del reloj
    // en Python (órdenes 107 y 108) y devolvieron `empty`. Va antes que las familias
    // porque esta función retorna en el primer match.
    if (std.mem.indexOf(u8, model_name, "translate") != null or
        std.mem.indexOf(u8, model_name, "arabic") != null)
    {
        return switch (task_type) {
            .programar, .programar_c, .programar_cpp, .programar_zig, .testear, .auditar => 0.15,
            else => 0.35,
        };
    }
    // GOBERNANZA-ROUTER: modelos especializados NVIDIA NIM que no son de chat/generación
    // (safety classifiers, guardrails, parsers de documentos, reward models) — penalizado
    // fuerte, NO excluido (si algún día son el único candidato con clave, siguen elegibles).
    if (std.mem.indexOf(u8, model_name, "safety") != null or
        std.mem.indexOf(u8, model_name, "guard") != null or
        std.mem.indexOf(u8, model_name, "-parse") != null or
        std.mem.indexOf(u8, model_name, "nemoretriever") != null or
        std.mem.indexOf(u8, model_name, "reward") != null or
        std.mem.indexOf(u8, model_name, "moderat") != null)
    {
        return switch (task_type) {
            .programar, .programar_c, .programar_cpp, .programar_zig => 0.05,
            else => 0.08,
        };
    }
    if (std.mem.indexOf(u8, model_name, "deepseek") != null) {
        return switch (task_type) {
            .programar, .programar_c, .programar_cpp, .programar_zig, .corregir, .auditar => 0.86,
            else => 0.76,
        };
    }
    if (std.mem.indexOf(u8, model_name, "gemini") != null or std.mem.indexOf(u8, model_name, "claude") != null) {
        return switch (task_type) {
            .planificar, .auditar, .investigar, .resumir => 0.88,
            else => 0.78,
        };
    }
    if (std.mem.indexOf(u8, model_name, "minimax") != null or std.mem.indexOf(u8, model_name, "qwen") != null) {
        return switch (task_type) {
            .programar, .programar_c, .programar_cpp, .programar_zig, .testear => 0.80,
            else => 0.70,
        };
    }
    // Cohere family priors (ROUT-01 / FIRE-03).
    if (std.mem.indexOf(u8, model_name, "c4ai-aya") != null) {
        return switch (task_type) {
            .programar, .programar_c, .programar_cpp, .programar_zig => 0.45,
            .investigar, .resumir, .documentar => 0.65,
            else => 0.55,
        };
    }
    if (std.mem.indexOf(u8, model_name, "command-a") != null or
        std.mem.indexOf(u8, model_name, "command-r") != null or
        std.mem.indexOf(u8, model_name, "reasoning") != null)
    {
        return switch (task_type) {
            .programar, .programar_c, .programar_cpp, .programar_zig, .corregir, .auditar => 0.82,
            .planificar, .investigar, .resumir => 0.78,
            else => 0.72,
        };
    }
    // Modelos especializados en código no cubiertos por una familia con nombre propio
    // (p. ej. arcee-ai/coder-large, kwaipilot/kat-coder-*). El token "coder"/"-code" es
    // señal fuerte de capacidad de programación. Va al final: las penalizaciones de
    // embed/rerank/vision y las familias nombradas (deepseek/qwen/command-a) ya retornaron.
    if (std.mem.indexOf(u8, model_name, "coder") != null or
        std.mem.indexOf(u8, model_name, "-code") != null)
    {
        return switch (task_type) {
            .programar, .programar_c, .programar_cpp, .programar_zig, .corregir => 0.82,
            .testear, .auditar => 0.74,
            else => 0.60,
        };
    }
    // FIRE-2026-07-10: multimedia y demás no-generadores-de-texto que no cayeron
    // en las dos familias de arriba (lyria/imagen/veo/tts/image/video/...) NO
    // merecen el 0.60 default de "modelo desconocido" — con ese prior le ganaban
    // a modelos de chat reales con prior honesto más bajo (p.ej. c4ai-aya 0.45).
    if (isNonTextGenModel(model_name)) return 0.02;
    return 0.60;
}

pub fn runDemo(allocator: std.mem.Allocator) ![]const u8 {
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var ledger = try db.Connection.open(allocator, ":memory:");
    defer ledger.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);
    try migrator.migrate(ledger, &db.ledger_schema);
    try seedDemoCatalog(catalog);
    var router = Router.init(allocator, catalog, ledger, 20260612);
    defer router.deinitHealthCache();
    try router.seedInitialScores();

    const tasks = [_]TaskType{ .planificar, .programar, .programar_c, .programar_cpp, .programar_zig, .testear, .auditar, .corregir, .documentar, .investigar, .resumir, .ejecutar, .disenar };
    var output = std.ArrayList(u8).empty;
    errdefer output.deinit(allocator);
    try output.appendSlice(allocator, "DevAgents route demo\n");
    try catalog.exec("UPDATE api_keys SET quota_used = quota_limit WHERE id = 1");
    try output.appendSlice(allocator, "Simulated exhausted quota: OpenCode key\n");
    for (tasks) |task_type| {
        var candidate = try router.route(.{
            .task_type = task_type,
            .required_context = 32000,
            .allow_paid_when_no_free = true,
            .escalation_justification = "free candidates unavailable or insufficient for gate demo",
        });
        defer candidate.deinit(allocator);
        const line = try std.fmt.allocPrint(allocator, "{s}: {s}/{s} free={any} score={d:.3} why={s}\n", .{ task_type.toText(), candidate.provider_name, candidate.model_name, candidate.is_free, candidate.score, candidate.reason });
        defer allocator.free(line);
        try output.appendSlice(allocator, line);
    }
    try router.recordFallback(2, 3, "simulated 429 at fallback level 1");
    try output.appendSlice(allocator, "Fallback: level 1 failed with 429, degraded to level 2\n");
    try catalog.exec("UPDATE api_keys SET status = 'quota_exceeded' WHERE provider_id = 1");
    var paid_candidate = try router.route(.{
        .task_type = .auditar,
        .required_context = 32000,
        .allow_paid_when_no_free = true,
        .escalation_justification = "audit demo after every free key is exhausted",
    });
    defer paid_candidate.deinit(allocator);
    const escalation_count = try countLedgerEscalations(ledger);
    const paid_line = try std.fmt.allocPrint(allocator, "Paid escalation: {s}/{s} ledger_ESCALATION_rows={d}\n", .{ paid_candidate.provider_name, paid_candidate.model_name, escalation_count });
    defer allocator.free(paid_line);
    try output.appendSlice(allocator, paid_line);
    return output.toOwnedSlice(allocator);
}

fn countLedgerEscalations(conn: db.Connection) !i32 {
    const stmt = try conn.prepare("SELECT COUNT(*) FROM audit_ledger WHERE action='ESCALATION'");
    defer conn.finalize(stmt);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return error.StepFailed;
    return db.c.sqlite3_column_int(stmt, 0);
}

fn seedDemoCatalog(conn: db.Connection) !void {
    try conn.exec("INSERT INTO providers (id, name, base_url, api_style, is_free_tier) VALUES (1, 'OpenCode', 'local://opencode', 'opencode', 1)");
    try conn.exec("INSERT INTO providers (id, name, base_url, api_style, is_free_tier) VALUES (2, 'OpenRouterPaid', 'https://openrouter.ai/api/v1', 'openai', 0)");
    try conn.exec("INSERT INTO api_keys (id, provider_id, label, key_ciphertext, quota_limit, quota_used, status) VALUES (1, 1, 'free-a', x'00', 10, 0, 'active')");
    try conn.exec("INSERT INTO api_keys (id, provider_id, label, key_ciphertext, quota_limit, quota_used, status) VALUES (2, 1, 'free-b', x'00', 10, 2, 'active')");
    try conn.exec("INSERT INTO api_keys (id, provider_id, label, key_ciphertext, quota_limit, quota_used, status) VALUES (3, 2, 'paid-a', x'00', 100, 0, 'active')");
    try conn.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, latency_p50_ms, available) VALUES (1, 1, 'opencode/minimax-m2.5-free', 64000, 1, 900, 1)");
    try conn.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, latency_p50_ms, available) VALUES (2, 1, 'deepseek-coder-free', 128000, 1, 1200, 1)");
    try conn.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, latency_p50_ms, available) VALUES (3, 2, 'claude-opus-paid', 200000, 0, 1800, 1)");
}

test "router ranks free candidates before paid candidates" {
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);
    try seedDemoCatalog(catalog);
    var router = Router.init(allocator, catalog, null, 1);
    defer router.deinitHealthCache();
    try router.seedInitialScores();
    var candidate = try router.route(.{ .task_type = .programar_zig, .required_context = 8000 });
    defer candidate.deinit(allocator);
    try std.testing.expect(candidate.is_free);
}

test "router candidates are unique per model when provider has multiple active keys" {
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);
    try seedDemoCatalog(catalog);
    var router = Router.init(allocator, catalog, null, 1);
    defer router.deinitHealthCache();

    var candidates = try router.rankCandidates(.{ .task_type = .programar, .required_context = 8000 });
    defer {
        for (candidates.items) |candidate| candidate.deinit(allocator);
        candidates.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 3), candidates.items.len);
}

test "paid escalation without justification is impossible" {
    // GOBERNANZA-HIBRIDO: la tarea era `.auditar`, que ahora es una etapa de PAGO
    // por política en Híbrido — ahí el pago no es una escalada y no hay nada que
    // justificar. La puerta que este test protege (no gastar dinero por descuido)
    // sigue viva en las etapas free-first, y `.programar` es una de ellas.
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);
    try seedDemoCatalog(catalog);
    try catalog.exec("UPDATE api_keys SET status = 'quota_exceeded' WHERE provider_id = 1");
    var router = Router.init(allocator, catalog, null, 1);
    defer router.deinitHealthCache();
    try router.seedInitialScores();
    try std.testing.expectError(error.PaidEscalationRequiresJustification, router.route(.{ .task_type = .programar, .required_context = 8000 }));
}

test "GOBERNANZA-HIBRIDO: planificar y auditar van a PAGO sin exigir justificacion al llamador" {
    // El fallo medido en el equipo del usuario: con gobernanza `hybrid`, `route()`
    // descartaba TODO candidato de pago mientras quedara un free con salud, así que
    // sus 3 claves Gemini Premium tenían 0 llamadas correctas en model_health
    // mientras los free se agotaban orden tras orden. §1.3: "pago para pensar y
    // auditar, free para construir".
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var ledger = try db.Connection.open(allocator, ":memory:");
    defer ledger.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);
    try migrator.migrate(ledger, &db.ledger_schema);
    try seedDemoCatalog(catalog); // 2 free + 1 paid, TODAS las claves activas
    var router = Router.init(allocator, catalog, ledger, 1);
    defer router.deinitHealthCache();
    try router.setGovernanceMode(.hybrid);
    try router.seedInitialScores();

    // Pensar y auditar → pago, aunque haya free vivo y SIN justificación del llamador.
    for ([_]TaskType{ .planificar, .auditar }) |tt| {
        var c = try router.route(.{ .task_type = tt, .required_context = 8000 });
        defer c.deinit(allocator);
        try std.testing.expect(!c.is_free);
    }
    // Construir, testear y documentar → free, con el pago disponible al lado.
    for ([_]TaskType{ .programar, .programar_zig, .testear, .documentar }) |tt| {
        var c = try router.route(.{ .task_type = tt, .required_context = 8000 });
        defer c.deinit(allocator);
        try std.testing.expect(c.is_free);
    }
    // Trazabilidad (§1.3): cada fila de pago deja su ESCALATION con motivo legible.
    const stmt = try ledger.prepare("SELECT COUNT(*) FROM audit_ledger WHERE action='ESCALATION' AND notes LIKE '%politica de gobernanza%'");
    defer ledger.finalize(stmt);
    try std.testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);
    try std.testing.expectEqual(@as(i32, 2), db.c.sqlite3_column_int(stmt, 0));
}

test "GOBERNANZA-HIBRIDO: una etapa de pago cae al free si no hay ningun candidato de pago" {
    // El filtro por etapa es una PREFERENCIA, no una condena: sin modelos de pago
    // en el catálogo, auditar debe seguir resolviéndose con free en vez de quedarse
    // sin candidatos. Es el caso del gate F4, cuyo catálogo es todo gratuito.
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);
    try catalog.exec("INSERT INTO providers (id, name, base_url, api_style, is_free_tier) VALUES (1, 'Cohere', 'https://api.cohere.ai', 'cohere', 1)");
    try catalog.exec("INSERT INTO api_keys (id, provider_id, label, key_ciphertext, quota_limit, quota_used, status) VALUES (1, 1, 'free-a', x'00', 100, 0, 'active')");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, latency_p50_ms, available) VALUES (1, 1, 'command-a-03-2025', 256000, 1, 800, 1)");

    var router = Router.init(allocator, catalog, null, 1);
    defer router.deinitHealthCache();
    try router.setGovernanceMode(.hybrid);
    var c = try router.route(.{ .task_type = .auditar, .required_context = 8000 });
    defer c.deinit(allocator);
    try std.testing.expect(c.is_free);
    try std.testing.expectEqualStrings("command-a-03-2025", c.model_name);
}

test "GOBERNANZA-PRIOR: modelos de traduccion e idioma no reciben prior de codigo" {
    // Elegidos EN VIVO para la orden del reloj en Python (órdenes 107 y 108, ambas
    // `empty`): `command-a-translate` cazaba el prefijo "command-a" y
    // `command-r7b-arabic` el de "command-r", los dos con 0.82 en programar.
    const idioma = [_][]const u8{
        "command-a-translate-08-2025",
        "command-r7b-arabic-02-2025",
    };
    for (idioma) |m| {
        try std.testing.expect(initialHeuristicScore(m, .programar) < 0.20);
        try std.testing.expect(initialHeuristicScore(m, .auditar) < 0.20);
        // Y deben quedar por DEBAJO de un modelo de chat honesto de su misma familia.
        try std.testing.expect(initialHeuristicScore(m, .programar) < initialHeuristicScore("command-a-03-2025", .programar));
    }
    // El modelo de chat real de la familia conserva su prior de código.
    try std.testing.expect(initialHeuristicScore("command-a-03-2025", .programar) >= 0.80);
}

test "paid escalation writes ledger row with justification" {
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var ledger = try db.Connection.open(allocator, ":memory:");
    defer ledger.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);
    try migrator.migrate(ledger, &db.ledger_schema);
    try seedDemoCatalog(catalog);
    try catalog.exec("UPDATE api_keys SET status = 'quota_exceeded' WHERE provider_id = 1");
    var router = Router.init(allocator, catalog, ledger, 1);
    defer router.deinitHealthCache();
    try router.seedInitialScores();
    var candidate = try router.route(.{ .task_type = .auditar, .required_context = 8000, .escalation_justification = "audit requires paid model after free exhaustion" });
    defer candidate.deinit(allocator);
    const stmt = try ledger.prepare("SELECT COUNT(*) FROM audit_ledger WHERE action='ESCALATION' AND notes LIKE '%free exhaustion%'");
    defer ledger.finalize(stmt);
    try std.testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);
    try std.testing.expectEqual(@as(i32, 1), db.c.sqlite3_column_int(stmt, 0));
}

test "audit feedback lowers score after repeated failures" {
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);
    try seedDemoCatalog(catalog);
    var router = Router.init(allocator, catalog, null, 1);
    defer router.deinitHealthCache();
    try router.seedInitialScores();
    const before = try router.getScore(2, .programar_zig);
    try router.recordAuditVerdict(2, .programar_zig, .fail);
    try router.recordAuditVerdict(2, .programar_zig, .fail);
    try router.recordAuditVerdict(2, .programar_zig, .fail);
    const after = try router.getScore(2, .programar_zig);
    try std.testing.expect(after.score < before.score);
    try std.testing.expect(after.sample_count >= before.sample_count + 3);
}

test "route demo emits heterogeneous assignments and fallback" {
    const allocator = std.testing.allocator;
    const demo = try runDemo(allocator);
    defer allocator.free(demo);
    try std.testing.expect(std.mem.indexOf(u8, demo, "programar_zig") != null);
    try std.testing.expect(std.mem.indexOf(u8, demo, "Fallback:") != null);
    // GOBERNANZA-HIBRIDO: eran 1. Ahora son 3 — el catálogo de la demo tiene un
    // modelo de pago, y en Híbrido `planificar` y `auditar` lo eligen por política
    // (2 filas) además de la escalada explícita del final (1). Las 11 etapas
    // restantes del bucle siguen resolviéndose en free y no dejan fila.
    try std.testing.expect(std.mem.indexOf(u8, demo, "ledger_ESCALATION_rows=3") != null);
    // free para construir: la asignación de programar_zig no puede ser de pago.
    const zig_line = std.mem.indexOf(u8, demo, "programar_zig:").?;
    const zig_end = std.mem.indexOfScalarPos(u8, demo, zig_line, '\n').?;
    try std.testing.expect(std.mem.indexOf(u8, demo[zig_line..zig_end], "free=true") != null);
}

test "fallback chain degrades through five levels and then exhausts" {
    const chain = FallbackChain.init(.{ 10, 20, 30, 40, 50 });
    try std.testing.expectEqual(@as(?i64, 20), chain.nextAfter(10));
    try std.testing.expectEqual(@as(?i64, 30), chain.nextAfter(20));
    try std.testing.expectEqual(@as(?i64, 40), chain.nextAfter(30));
    try std.testing.expectEqual(@as(?i64, 50), chain.nextAfter(40));
    try std.testing.expectEqual(@as(?i64, null), chain.nextAfter(50));
}

test "exclude_model filters the constructor model from audit candidates" {
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);
    try seedDemoCatalog(catalog);
    var router = Router.init(allocator, catalog, null, 1);
    defer router.deinitHealthCache();
    try router.seedInitialScores();

    // Sin exclude_model: rankCandidates devuelve todos los modelos (2 free + 1 paid = 3)
    var all_candidates = try router.rankCandidates(.{ .task_type = .auditar, .required_context = 8000 });
    defer {
        for (all_candidates.items) |c| c.deinit(allocator);
        all_candidates.deinit(allocator);
    }
    try std.testing.expect(all_candidates.items.len >= 3);

    // Con exclude_model=1: el modelo 1 (opencode/minimax-m2.5-free) queda excluido
    var filtered = try router.rankCandidates(.{ .task_type = .auditar, .required_context = 8000, .exclude_models = &.{1} });
    defer {
        for (filtered.items) |c| c.deinit(allocator);
        filtered.deinit(allocator);
    }
    for (filtered.items) |c| {
        try std.testing.expect(c.model_id != 1);
    }
    try std.testing.expect(filtered.items.len < all_candidates.items.len);
}

test "HEALTH-03: healthFactor penaliza modelos no funcionales y es neutral sin dato" {
    const allocator = std.testing.allocator;
    var rt = try db.Connection.open(allocator, ":memory:");
    defer rt.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(rt, &db.runtime_schema);
    try health.record(rt, "NVIDIA API", "kimi", .ok, 0);
    try health.record(rt, "OpenCode", "premium", .auth_failed, 0);
    try health.record(rt, "X", "slow", .empty, 0);
    try health.record(rt, "OpenRouter", "hung", .timeout, 0);

    var cat = try db.Connection.open(allocator, ":memory:");
    defer cat.close();
    try migrator.migrate(cat, &db.catalog_schema);
    var router = Router.init(allocator, cat, null, 1);
    defer router.deinitHealthCache();

    // P8: sin conexión de salud, no hay historial que leer → NO_EVIDENCE_FACTOR.
    // Antes esto daba 1.0 (neutral), que era el fallo de `route --chain`: un
    // modelo SIN registros parecía perfecto y saltaba delante del único que
    // tenía historial real. Ahora lo sin-probar vale NO_EVIDENCE_FACTOR, no 1.0.
    try std.testing.expectApproxEqAbs(@as(f64, NO_EVIDENCE_FACTOR), router.healthFactor("OpenCode", "premium"), 0.001);
    router.setHealthConn(rt);
    // GOBERNANZA-FIABILIDAD: factor = statusToFactor × reliabilityFromCounts. Cada record()
    // arriba aporta 1 muestra; un único fallo → fiabilidad (0+2)/(0+1+2)=0.667; un único ok
    // → (1+2)/(1+0+2)=1.0. Por eso los fallidos quedan aún más hundidos que solo por status.
    const rel_one_fail: f64 = 2.0 / 3.0;
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), router.healthFactor("NVIDIA API", "kimi"), 0.001); // ok (1,0)
    try std.testing.expectApproxEqAbs(@as(f64, 0.05) * rel_one_fail, router.healthFactor("OpenCode", "premium"), 0.001); // 401
    try std.testing.expectApproxEqAbs(@as(f64, 0.5) * rel_one_fail, router.healthFactor("X", "slow"), 0.001); // empty
    try std.testing.expectApproxEqAbs(@as(f64, 0.3) * rel_one_fail, router.healthFactor("OpenRouter", "hung"), 0.001); // timeout
    // P8: sin-datos (ninguna fila en model_health) ya NO es 1.0 neutral; es la
    // banda "sin probar", por debajo de cualquier historial real.
    try std.testing.expectApproxEqAbs(@as(f64, NO_EVIDENCE_FACTOR), router.healthFactor("Nuevo", "sin-datos"), 0.001);
}

test "GOBERNANZA-FIABILIDAD: modelo flaky (ultimo ok pero historial malo) queda denigrado" {
    const allocator = std.testing.allocator;
    var rt = try db.Connection.open(allocator, ":memory:");
    defer rt.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(rt, &db.runtime_schema);

    // Modelo flaky: 15 fallos y luego 1 ok (la ÚLTIMA llamada fue ok).
    var i: usize = 0;
    while (i < 15) : (i += 1) try health.record(rt, "Flaky", "flaky-model", .err, 0);
    try health.record(rt, "Flaky", "flaky-model", .ok, 0);
    // Modelo sano: 1 ok.
    try health.record(rt, "Solido", "solid-model", .ok, 0);

    var cat = try db.Connection.open(allocator, ":memory:");
    defer cat.close();
    try migrator.migrate(cat, &db.catalog_schema);
    var router = Router.init(allocator, cat, null, 1);
    defer router.deinitHealthCache();
    router.setHealthConn(rt);

    // Aunque el último status del flaky es 'ok' (statusToFactor=1.0), su fiabilidad
    // acumulada (1 ok / 16 total) lo hunde muy por debajo del modelo sólido.
    const flaky = router.healthFactor("Flaky", "flaky-model");
    const solid = router.healthFactor("Solido", "solid-model");
    try std.testing.expect(flaky < 0.3);
    try std.testing.expect(solid > 0.9);
    try std.testing.expect(solid > flaky);
}

test "P8: cero éxitos registrados NUNCA ordena delante de un historial real" {
    // El caso medido en `route --chain` (2026-08-07): 4 Gemini sin fila en
    // model_health con score heurístico 0.88 delante del único modelo con
    // historial real (north-mini-code-1-0, 6 oks, score 0.60). Con la clase
    // explicitada, lo `proven` va SIEMPRE primero dentro del tier.
    try std.testing.expectEqual(EvidenceClass.proven, evidenceClass(6, 10));
    try std.testing.expectEqual(EvidenceClass.unproven, evidenceClass(0, 0)); // sin fila
    try std.testing.expectEqual(EvidenceClass.unproven, evidenceClass(0, 3)); // cero éxitos
    try std.testing.expectEqual(EvidenceClass.unproven, evidenceClass(1, 1)); // muestra insuficiente
    try std.testing.expectEqual(EvidenceClass.proven, evidenceClass(3, 0)); // historial limpio
    try std.testing.expectEqual(EvidenceClass.proven, evidenceClass(3, 2)); // muestra suficiente
}

test "P8: mínimo de muestras antes de fiar una tasa con fallos" {
    // 1 ok / 0 err es evidencia real (1 éxito limpio). Pero 1 ok / 1 err (total
    // 2 < MIN) NO se puede fiar como tasa → unproven hasta que haya más muestras.
    try std.testing.expectEqual(EvidenceClass.proven, evidenceClass(1, 0));
    try std.testing.expectEqual(EvidenceClass.unproven, evidenceClass(1, 1));
    try std.testing.expectEqual(EvidenceClass.proven, evidenceClass(2, 1)); // total 3 ≥ MIN
}

test "P8: la historia vieja (era del bug del parser) pierde peso por antigüedad" {
    // Misma fiabilidad nominal (3 ok / 1 err): con el último ok muy reciente la
    // tasa se fía entera; con el último ok de semanas atrás pesa la mitad.
    const now: i64 = 1_000_000;
    const fresh = agedReliability(6, 2, now - 10, now - 10, now);
    const stale = agedReliability(6, 2, now - STALE_WINDOW_SECONDS - 400_000, now - STALE_WINDOW_SECONDS - 400_000, now);
    try std.testing.expect(fresh > 0.6);
    try std.testing.expect(stale < fresh);
    // Sólido con historial reciente se mantiene alto; con historial viejo
    // RETROCEDE hacia neutral (era del bug del parser).
    try std.testing.expect(fresh > 0.7);
    try std.testing.expect(stale > 0.45 and stale < 0.7);
    // La brecha negativa (now anterior al timestamp, como en los tests) NUNCA
    // penaliza: sin referente temporal no se acusa de viejo.
    const inverted = agedReliability(20, 0, now + 50, now + 50, now);
    try std.testing.expectApproxEqAbs(@as(f64, 1.0), inverted, 0.01);
}

test "P1-FALSE-GREEN: router avoids auth_failed and quota models in ranking" {
    const allocator = std.testing.allocator;
    var rt = try db.Connection.open(allocator, ":memory:");
    defer rt.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(rt, &db.runtime_schema);

    var cat = try db.Connection.open(allocator, ":memory:");
    defer cat.close();
    try migrator.migrate(cat, &db.catalog_schema);
    try seedDemoCatalog(cat);

    // Mark model 1 (opencode/minimax-m2.5-free) as auth_failed.
    try health.record(rt, "OpenCode", "opencode/minimax-m2.5-free", .auth_failed, 0);

    var router = Router.init(allocator, cat, null, 1);
    defer router.deinitHealthCache();
    router.setHealthConn(rt);
    try router.seedInitialScores();

    var candidates = try router.rankCandidates(.{ .task_type = .programar, .required_context = 8000 });
    defer {
        for (candidates.items) |c| c.deinit(allocator);
        candidates.deinit(allocator);
    }

    // The top candidate must NOT be the auth_failed model — the other free model
    // (deepseek-coder-free) should rank higher because healthFactor penalizes auth_failed.
    try std.testing.expect(candidates.items.len > 0);
    const top = candidates.items[0];
    try std.testing.expect(!std.mem.eql(u8, top.model_name, "opencode/minimax-m2.5-free"));
    // The healthy free model should be at the top.
    try std.testing.expect(std.mem.eql(u8, top.model_name, "deepseek-coder-free"));
}

test "router skips hard-bad free primary when a healthy paid candidate exists" {
    const allocator = std.testing.allocator;
    var rt = try db.Connection.open(allocator, ":memory:");
    defer rt.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(rt, &db.runtime_schema);

    var cat = try db.Connection.open(allocator, ":memory:");
    defer cat.close();
    try migrator.migrate(cat, &db.catalog_schema);
    try seedDemoCatalog(cat);

    try health.record(rt, "OpenCode", "opencode/minimax-m2.5-free", .auth_failed, 0);
    try health.record(rt, "OpenCode", "deepseek-coder-free", .quota, 0);

    var router = Router.init(allocator, cat, null, 1);
    defer router.deinitHealthCache();
    router.setHealthConn(rt);
    try router.seedInitialScores();

    var candidate = try router.route(.{ .task_type = .programar, .required_context = 8000, .escalation_justification = "free candidates are hard-bad" });
    defer candidate.deinit(allocator);

    try std.testing.expect(!candidate.is_free);
    try std.testing.expectEqualStrings("claude-opus-paid", candidate.model_name);
}

test "router still returns the least bad candidate when every candidate is hard-bad" {
    const allocator = std.testing.allocator;
    var rt = try db.Connection.open(allocator, ":memory:");
    defer rt.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(rt, &db.runtime_schema);

    var cat = try db.Connection.open(allocator, ":memory:");
    defer cat.close();
    try migrator.migrate(cat, &db.catalog_schema);
    try seedDemoCatalog(cat);

    try health.record(rt, "OpenCode", "opencode/minimax-m2.5-free", .auth_failed, 0);
    try health.record(rt, "OpenCode", "deepseek-coder-free", .quota, 0);
    try health.record(rt, "OpenRouterPaid", "claude-opus-paid", .not_found, 0);

    var router = Router.init(allocator, cat, null, 1);
    defer router.deinitHealthCache();
    router.setHealthConn(rt);
    try router.seedInitialScores();

    var candidate = try router.route(.{ .task_type = .programar, .required_context = 8000, .escalation_justification = "all candidates are hard-bad" });
    defer candidate.deinit(allocator);

    try std.testing.expect(candidate.health_factor < MIN_PRIMARY_HEALTH);
    try std.testing.expect(candidate.score > 0.0);
}

test "favorites prefer fast generative models over reasoning for programming" {
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);

    try catalog.exec("INSERT INTO providers (id, name, base_url, api_style, is_free_tier) VALUES (1, 'OpenRouter', 'https://openrouter.ai/api/v1', 'openai', 1)");
    try catalog.exec("INSERT INTO api_keys (id, provider_id, label, key_ciphertext, quota_limit, quota_used, status) VALUES (1, 1, 'free-openrouter', x'00', 100, 0, 'active')");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, is_favorite, latency_p50_ms, available) VALUES (1, 1, 'nvidia/nemotron-3-nano-omni-30b-a3b-reasoning:free', 128000, 1, 1, 800, 1)");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, is_favorite, latency_p50_ms, available) VALUES (2, 1, 'nvidia/nemotron-3-nano-30b-a3b:free', 128000, 1, 1, 800, 1)");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, is_favorite, latency_p50_ms, available) VALUES (3, 1, 'deepseek-ai/deepseek-coder-6.7b-instruct', 128000, 1, 0, 800, 1)");

    var router = Router.init(allocator, catalog, null, 1);
    defer router.deinitHealthCache();
    var candidate = try router.route(.{ .task_type = .programar, .required_context = 8000 });
    defer candidate.deinit(allocator);

    try std.testing.expectEqualStrings("nvidia/nemotron-3-nano-30b-a3b:free", candidate.model_name);
}

test "ROUT-01: for programar prefers command-a over c4ai-aya-expanse-32b" {
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);

    // Seed a Cohere-only catalog with two free models.
    try catalog.exec("INSERT INTO providers (id, name, base_url, api_style, is_free_tier) VALUES (1, 'Cohere', 'https://api.cohere.ai', 'cohere', 1)");
    try catalog.exec("INSERT INTO api_keys (id, provider_id, label, key_ciphertext, quota_limit, quota_used, status) VALUES (1, 1, 'free-cohere', x'00', 100, 0, 'active')");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, latency_p50_ms, available) VALUES (1, 1, 'command-a-03-2025', 256000, 1, 800, 1)");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, latency_p50_ms, available) VALUES (2, 1, 'c4ai-aya-expanse-32b', 128000, 1, 900, 1)");

    var router = Router.init(allocator, catalog, null, 1);
    defer router.deinitHealthCache();
    try router.seedInitialScores();

    const programar_tasks = [_]TaskType{ .programar, .programar_c, .programar_cpp, .programar_zig };
    for (programar_tasks) |task_type| {
        var candidate = try router.route(.{ .task_type = task_type, .required_context = 8000 });
        defer candidate.deinit(allocator);
        try std.testing.expectEqualStrings("command-a-03-2025", candidate.model_name);
    }
}

test "ROUT-01b: migration rebuilds model_scores for existing DBs" {
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();

    // Simular DB existente con esquema VIEJO (CHECK sin 'programar').
    try catalog.exec(
        \\CREATE TABLE providers (id INTEGER PRIMARY KEY, name TEXT NOT NULL UNIQUE, base_url TEXT NOT NULL, api_style TEXT NOT NULL, is_free_tier INTEGER NOT NULL DEFAULT 1, enabled INTEGER NOT NULL DEFAULT 1)
    );
    try catalog.exec(
        \\CREATE TABLE api_keys (id INTEGER PRIMARY KEY, provider_id INTEGER NOT NULL REFERENCES providers(id), label TEXT NOT NULL, key_ciphertext BLOB NOT NULL, quota_window TEXT, quota_limit INTEGER, quota_used INTEGER DEFAULT 0, last_rotated_at INTEGER, status TEXT NOT NULL DEFAULT 'active', requests_count INTEGER DEFAULT 0, last_used_at INTEGER)
    );
    try catalog.exec(
        \\CREATE TABLE models (id INTEGER PRIMARY KEY, provider_id INTEGER NOT NULL REFERENCES providers(id), model_name TEXT NOT NULL, context_window INTEGER, modalities TEXT, is_free INTEGER NOT NULL DEFAULT 1, latency_p50_ms INTEGER, discovered_at INTEGER, last_seen_at INTEGER, available INTEGER NOT NULL DEFAULT 1)
    );
    try catalog.exec(
        \\CREATE TABLE model_scores (model_id INTEGER NOT NULL, task_type TEXT NOT NULL CHECK(task_type IN ('planificar','programar_c','programar_cpp','programar_zig','testear','auditar','corregir','documentar','investigar','resumir')), score REAL NOT NULL CHECK(score >= 0.0 AND score <= 1.0), sample_count INTEGER NOT NULL DEFAULT 0 CHECK(sample_count >= 0), updated_at INTEGER, FOREIGN KEY(model_id) REFERENCES models(id), PRIMARY KEY (model_id, task_type))
    );

    // Seed datos Cohere (como en el test ROUT-01 original).
    try catalog.exec("INSERT INTO providers (id, name, base_url, api_style, is_free_tier) VALUES (1, 'Cohere', 'https://api.cohere.ai', 'cohere', 1)");
    try catalog.exec("INSERT INTO api_keys (id, provider_id, label, key_ciphertext, quota_limit, quota_used, status) VALUES (1, 1, 'free-cohere', x'00', 100, 0, 'active')");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, latency_p50_ms, available) VALUES (1, 1, 'command-a-03-2025', 256000, 1, 800, 1)");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, latency_p50_ms, available) VALUES (2, 1, 'c4ai-aya-expanse-32b', 128000, 1, 900, 1)");

    // Simular un score previo aprendido para c4ai-aya en programar_c (0.60, prior viejo generico).
    try catalog.exec("INSERT INTO model_scores (model_id, task_type, score, sample_count) VALUES (2, 'programar_c', 0.60, 0)");

    // Marcar como si ya se habian aplicado las 4 migraciones originales.
    try catalog.setUserVersion(4);

    // Aplicar el schema NUEVO (ahora tiene 5 migraciones; la 5 reconstruye model_scores).
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);

    // user_version debe igualar el nº de migraciones del catálogo (robusto ante nuevas
    // migraciones: p.ej. V7 añadió is_favorite y antes esto rompía con "expected 6, found 7").
    const version = try catalog.getUserVersion();
    try std.testing.expectEqual(@as(i32, db.catalog_schema.len), version);

    // La tabla fue reconstruida: el score previo de programar_c desaparecio.
    const stmt_count = try catalog.prepare("SELECT COUNT(*) FROM model_scores");
    defer catalog.finalize(stmt_count);
    try std.testing.expect(db.c.sqlite3_step(stmt_count) == db.c.SQLITE_ROW);
    try std.testing.expectEqual(@as(i32, 0), db.c.sqlite3_column_int(stmt_count, 0));

    // El CHECK nuevo SI acepta 'programar'.
    try catalog.exec("INSERT INTO model_scores (model_id, task_type, score, sample_count) VALUES (1, 'programar', 0.82, 0)");

    // Repoblar priors.
    var router = Router.init(allocator, catalog, null, 1);
    defer router.deinitHealthCache();
    try router.seedInitialScores();

    // route para .programar debe elegir command-a sobre c4ai-aya.
    var candidate = try router.route(.{ .task_type = .programar, .required_context = 8000 });
    defer candidate.deinit(allocator);
    try std.testing.expectEqualStrings("command-a-03-2025", candidate.model_name);
}

test "ROUT-02: programar prefiere modelo code-strong con model_scores vacio (fallback heuristico en ruteo)" {
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);

    try catalog.exec("INSERT INTO providers (id, name, base_url, api_style, is_free_tier) VALUES (1, 'OpenRouter', 'https://openrouter.ai/api/v1', 'openai', 1)");
    try catalog.exec("INSERT INTO api_keys (id, provider_id, label, key_ciphertext, quota_limit, quota_used, status) VALUES (1, 1, 'k', x'00', 100, 0, 'active')");
    // jamba: sin familia (prior generico 0.60). deepseek: code-strong (0.86). Ambos free.
    // A jamba se le da MEJOR contexto y latencia a proposito: la capacidad debe ganar igual.
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, latency_p50_ms, available) VALUES (1, 1, 'ai21/jamba-large-1.7', 256000, 1, 700, 1)");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, latency_p50_ms, available) VALUES (2, 1, 'deepseek/deepseek-chat', 128000, 1, 900, 1)");

    var router = Router.init(allocator, catalog, null, 1);
    defer router.deinitHealthCache();
    // CLAVE: NO se llama seedInitialScores → model_scores vacio (estado real tras discovery).
    const programar_tasks = [_]TaskType{ .programar, .programar_c, .programar_cpp, .programar_zig };
    for (programar_tasks) |task_type| {
        var c = try router.route(.{ .task_type = task_type, .required_context = 8000 });
        defer c.deinit(allocator);
        try std.testing.expectEqualStrings("deepseek/deepseek-chat", c.model_name);
    }
}

test "ROUT-02b: un score aprendido en model_scores tiene precedencia sobre el prior heuristico" {
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);

    try catalog.exec("INSERT INTO providers (id, name, base_url, api_style, is_free_tier) VALUES (1, 'OpenRouter', 'https://openrouter.ai/api/v1', 'openai', 1)");
    try catalog.exec("INSERT INTO api_keys (id, provider_id, label, key_ciphertext, quota_limit, quota_used, status) VALUES (1, 1, 'k', x'00', 100, 0, 'active')");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, latency_p50_ms, available) VALUES (1, 1, 'ai21/jamba-large-1.7', 128000, 1, 900, 1)");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, latency_p50_ms, available) VALUES (2, 1, 'deepseek/deepseek-chat', 128000, 1, 900, 1)");

    // jamba demostro ser excelente en programar (score aprendido alto): debe ganar a deepseek.
    try catalog.exec("INSERT INTO model_scores (model_id, task_type, score, sample_count, updated_at) VALUES (1, 'programar', 0.99, 5, 1)");

    var router = Router.init(allocator, catalog, null, 1);
    defer router.deinitHealthCache();
    var c = try router.route(.{ .task_type = .programar, .required_context = 8000 });
    defer c.deinit(allocator);
    try std.testing.expectEqualStrings("ai21/jamba-large-1.7", c.model_name);
}

test "ROUT-02c: initialHeuristicScore da prior de codigo a modelos *coder* sin familia" {
    // arcee-ai/coder-large y kwaipilot/kat-coder-* caian a 0.60 generico; ahora 0.82 en programar.
    try std.testing.expect(initialHeuristicScore("arcee-ai/coder-large", .programar) >= 0.80);
    try std.testing.expect(initialHeuristicScore("kwaipilot/kat-coder-pro-v2", .programar) >= 0.80);
    // un modelo sin senal de codigo sigue en el generico.
    try std.testing.expect(initialHeuristicScore("ai21/jamba-large-1.7", .programar) < 0.70);
}

test "GOBERNANZA-ROUTER: modelos NVIDIA especializados (safety/guard/parse/reward) NO deben rankear como chat generico" {
    // Reproducido en vivo: sin este fix caian al 0.60 generico (a la par de un modelo
    // real) y el router eligio "nvidia/nemotron-parse" como PRIMER candidato para una
    // orden de programacion — la llamada se colgo minutos en vez de fallar rapido.
    const specialized = [_][]const u8{
        "nvidia/nemotron-parse",
        "nvidia/nemoretriever-parse",
        "nvidia/nemotron-3-content-safety",
        "nvidia/nemotron-content-safety-reasoning-4b",
        "nvidia/llama-3.1-nemoguard-8b-content-safety",
        "nvidia/llama-3.1-nemotron-safety-guard-8b-v3",
        "meta/llama-guard-4-12b",
        "nvidia/nemotron-4-340b-reward",
    };
    for (specialized) |m| {
        try std.testing.expect(initialHeuristicScore(m, .programar) < 0.10);
        try std.testing.expect(initialHeuristicScore(m, .planificar) < 0.10);
    }
    // Un modelo de chat real de la misma familia nemotron NO debe caer en este filtro.
    try std.testing.expect(initialHeuristicScore("nvidia/nemotron-3-ultra-550b-a55b", .programar) >= 0.55);
}

test "FASE-AGENTIC-4: el bonus de familia (gemini/claude) NO debe tapar la penalizacion de embeddings" {
    // Bug real reproducido en vivo (orden 299): "models/gemini-embedding-2" (Google AI
    // Studio) contiene "gemini" Y "embed" — el check de familia corria PRIMERO y esta
    // funcion retorna en el primer match, asi que el router lo puntuaba 0.88 para
    // investigar (igual que un gemini-pro real) en vez de la penalizacion de 0.25 que
    // le corresponde por ser un modelo de solo-embeddings. Consecuencia observada:
    // el worker no genero texto de chat -> ningun artefacto narrativo -> el usuario
    // nunca vio la respuesta de la busqueda web.
    const embed_models_con_familia = [_][]const u8{
        "models/gemini-embedding-2",
        "models/gemini-embedding-2-preview",
        "claude-embed-v1", // hipotetico, mismo patron
    };
    for (embed_models_con_familia) |m| {
        try std.testing.expect(initialHeuristicScore(m, .investigar) < 0.30);
        try std.testing.expect(initialHeuristicScore(m, .planificar) < 0.30);
        try std.testing.expect(initialHeuristicScore(m, .programar) < 0.15);
    }
    // Un modelo de chat REAL de esas familias sigue recibiendo el bonus.
    try std.testing.expect(initialHeuristicScore("models/gemini-2.5-flash", .investigar) >= 0.80);
    try std.testing.expect(initialHeuristicScore("claude-sonnet-5", .investigar) >= 0.80);
}

test "FIRE-2026-07-10: multimedia/no-texto excluidos de respaldos y sin prior default" {
    // Reproducido en la prueba de fuego (órdenes 316-318): "google/lyria-3-pro-preview"
    // (música) asignado a auditar y "rerank-v3.5" a testear — quemaban los huecos de
    // respaldo y la orden moría en provider_exhausted aunque hubiera chat models vivos.
    const non_text = [_][]const u8{
        "google/lyria-3-pro-preview",
        "rerank-v3.5",
        "models/imagen-4-ultra-generate",
        "qwen-image-edit",
        "google/veo-3-preview",
        "gpt-4o-mini-tts",
        "nvidia/nemotron-parse",
        "models/gemini-embedding-2",
    };
    for (non_text) |m| {
        try std.testing.expect(isNonTextGenModel(m));
    }
    // El prior de los multimedia sin familia debe hundirse muy por debajo del
    // default 0.60 para que nunca le ganen a un chat model honesto.
    try std.testing.expect(initialHeuristicScore("google/lyria-3-pro-preview", .auditar) <= 0.05);
    try std.testing.expect(initialHeuristicScore("google/veo-3-preview", .programar) <= 0.05);
    // Modelos de chat reales NO deben caer en el filtro.
    const chat_models = [_][]const u8{
        "nvidia/nemotron-3-ultra-550b-a55b",
        "claude-sonnet-5",
        "c4ai-aya-expanse-32b",
        "meta-llama/llama-3.3-70b-instruct:free",
        "command-r-08-2024",
    };
    for (chat_models) |m| {
        try std.testing.expect(!isNonTextGenModel(m));
    }
}

test "SQL injection: task_type with injection payload is treated as literal text" {
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);
    try seedDemoCatalog(catalog);

    var router = Router.init(allocator, catalog, null, 1);
    defer router.deinitHealthCache();
    try router.seedInitialScores();

    // Insert a score with a task_type that contains SQL injection attempt
    // using bound parameters (the safe path). The injection string is treated
    // as a literal value, not as SQL syntax.
    // Use model_id 999 to avoid UNIQUE constraint conflicts with seeded data.
    const injection_type = "programar'; DROP TABLE models; --";
    const ins = try catalog.prepare("INSERT OR IGNORE INTO model_scores (model_id, task_type, score, sample_count, updated_at) VALUES (?, ?, 0.42, 1, 1)");
    defer catalog.finalize(ins);
    try db.bindInt(ins, 1, 999);
    try db.bindText(ins, 2, injection_type);
    try std.testing.expect(db.c.sqlite3_step(ins) == db.c.SQLITE_DONE);

    // getScore with the normal task_type 'programar' should still work
    // and return the seeded score (not the injection one).
    const score = try router.getScore(1, .programar);
    try std.testing.expect(score.score >= 0.0 and score.score <= 1.0);

    // Verify models table still exists (no DROP TABLE happened).
    const check = try catalog.prepare("SELECT COUNT(*) FROM models");
    defer catalog.finalize(check);
    try std.testing.expect(db.c.sqlite3_step(check) == db.c.SQLITE_ROW);
    try std.testing.expect(db.c.sqlite3_column_int(check, 0) >= 3); // 3 demo models

    // recordAuditVerdict with normal task_type should also work without error.
    try router.recordAuditVerdict(1, .programar, .pass);
    // Verify the score was updated.
    const after = try router.getScore(1, .programar);
    try std.testing.expect(after.sample_count >= score.sample_count + 1);

    // Verify the injection row did NOT execute as SQL: models table still intact.
    // (Already checked above, but double-check the count hasn't changed.)
    const check2 = try catalog.prepare("SELECT COUNT(*) FROM models");
    defer catalog.finalize(check2);
    try std.testing.expect(db.c.sqlite3_step(check2) == db.c.SQLITE_ROW);
    try std.testing.expect(db.c.sqlite3_column_int(check2, 0) >= 3);
}

test "T3: recordFallback stores SQL injection payload as literal (round-trip)" {
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var ledger = try db.Connection.open(allocator, ":memory:");
    defer ledger.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);
    try migrator.migrate(ledger, &db.ledger_schema);
    try seedDemoCatalog(catalog);
    var router = Router.init(allocator, catalog, ledger, 1);
    defer router.deinitHealthCache();
    try router.seedInitialScores();

    // Injection payload in the reason field.
    const injection = "'); DROP TABLE audit_ledger;--";
    try router.recordFallback(1, 2, injection);

    // The audit_ledger table must still exist (no DROP TABLE happened).
    const check = try ledger.prepare("SELECT COUNT(*) FROM audit_ledger");
    defer ledger.finalize(check);
    try std.testing.expect(db.c.sqlite3_step(check) == db.c.SQLITE_ROW);
    try std.testing.expect(db.c.sqlite3_column_int(check, 0) == 1);

    // The reason must be stored literally (round-trip).
    const row = try ledger.prepare("SELECT notes FROM audit_ledger WHERE action='REAUDIT'");
    defer ledger.finalize(row);
    try std.testing.expect(db.c.sqlite3_step(row) == db.c.SQLITE_ROW);
    const notes_ptr = db.c.sqlite3_column_text(row, 0);
    const notes = notes_ptr[0..std.mem.len(notes_ptr)];
    try std.testing.expectEqualStrings(injection, notes);
}

test "T3: recordEscalation stores SQL injection payload as literal (round-trip)" {
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var ledger = try db.Connection.open(allocator, ":memory:");
    defer ledger.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);
    try migrator.migrate(ledger, &db.ledger_schema);
    try seedDemoCatalog(catalog);
    try catalog.exec("UPDATE api_keys SET status = 'quota_exceeded' WHERE provider_id = 1");
    var router = Router.init(allocator, catalog, ledger, 1);
    defer router.deinitHealthCache();
    try router.seedInitialScores();

    // Injection payload in the justification field.
    const injection = "'); DROP TABLE audit_ledger;--";
    var candidate = try router.route(.{
        .task_type = .auditar,
        .required_context = 8000,
        .escalation_justification = injection,
    });
    defer candidate.deinit(allocator);

    // The audit_ledger table must still exist.
    const check = try ledger.prepare("SELECT COUNT(*) FROM audit_ledger WHERE action='ESCALATION'");
    defer ledger.finalize(check);
    try std.testing.expect(db.c.sqlite3_step(check) == db.c.SQLITE_ROW);
    try std.testing.expect(db.c.sqlite3_column_int(check, 0) == 1);

    // The justification must be stored literally (round-trip).
    const row = try ledger.prepare("SELECT notes FROM audit_ledger WHERE action='ESCALATION'");
    defer ledger.finalize(row);
    try std.testing.expect(db.c.sqlite3_step(row) == db.c.SQLITE_ROW);
    const notes_ptr = db.c.sqlite3_column_text(row, 0);
    const notes = notes_ptr[0..std.mem.len(notes_ptr)];
    try std.testing.expectEqualStrings(injection, notes);
}

test "T1: GovernanceMode hard filters candidate selection in router" {
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var ledger = try db.Connection.open(allocator, ":memory:");
    defer ledger.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);
    try migrator.migrate(ledger, &db.ledger_schema);
    try seedDemoCatalog(catalog);
    var router = Router.init(allocator, catalog, ledger, 1);
    defer router.deinitHealthCache();
    try router.seedInitialScores();

    // Test 1: free_tier_first mode only returns free candidates
    try router.setGovernanceMode(.free_tier_first);
    try std.testing.expectEqual(GovernanceMode.free_tier_first, router.getGovernanceMode());
    var free_candidates = try router.rankCandidates(.{ .task_type = .programar, .required_context = 8000 });
    defer {
        for (free_candidates.items) |c| c.deinit(allocator);
        free_candidates.deinit(allocator);
    }
    for (free_candidates.items) |c| {
        try std.testing.expect(c.is_free);
    }

    // Test 2: paid_tier_first mode only returns paid candidates
    try router.setGovernanceMode(.paid_tier_first);
    try std.testing.expectEqual(GovernanceMode.paid_tier_first, router.getGovernanceMode());
    var paid_candidates = try router.rankCandidates(.{ .task_type = .programar, .required_context = 8000 });
    defer {
        for (paid_candidates.items) |c| c.deinit(allocator);
        paid_candidates.deinit(allocator);
    }
    for (paid_candidates.items) |c| {
        try std.testing.expect(!c.is_free);
    }
}

test "LOCAL-ONLY: parse y toText del modo solo-local" {
    try std.testing.expectEqual(GovernanceMode.local_only, GovernanceMode.parse("local"));
    try std.testing.expectEqual(GovernanceMode.local_only, GovernanceMode.parse("local_only"));
    try std.testing.expectEqual(GovernanceMode.local_only, GovernanceMode.parse("solo_local"));
    try std.testing.expectEqualStrings("local_only", GovernanceMode.local_only.toText());
    // Round-trip: lo que se guarda en settings se vuelve a parsear igual.
    try std.testing.expectEqual(GovernanceMode.local_only, GovernanceMode.parse(GovernanceMode.local_only.toText()));
    // Solo-local es free-first: los proveedores locales no cobran ni escalan a pago.
    try std.testing.expect(prefersFreeFirst(.local_only, .planificar));
    try std.testing.expect(prefersFreeFirst(.local_only, .auditar));
}

test "LOCAL-ONLY: rankCandidates devuelve solo modelos locales, sin exigir clave" {
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var ledger = try db.Connection.open(allocator, ":memory:");
    defer ledger.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);
    try migrator.migrate(ledger, &db.ledger_schema);
    // Un proveedor local SIN api_key y uno de nube CON clave activa.
    try catalog.exec("INSERT INTO providers (id, name, base_url, api_style, is_free_tier, is_local, enabled) VALUES (1, 'Ollama', 'http://127.0.0.1:11434/v1', 'openai', 1, 1, 1)");
    try catalog.exec("INSERT INTO providers (id, name, base_url, api_style, is_free_tier, is_local, enabled) VALUES (2, 'Nuboso', 'https://api.nube.test/v1', 'openai', 0, 0, 1)");
    try catalog.exec("INSERT INTO api_keys (id, provider_id, label, key_ciphertext, status) VALUES (1, 2, 'k', x'00', 'active')");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, available) VALUES (1, 1, 'qwen2.5:3b', 32000, 1, 1)");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, available) VALUES (2, 2, 'nuboso-pro', 128000, 0, 1)");

    var router = Router.init(allocator, catalog, ledger, 1);
    defer router.deinitHealthCache();

    var cands = try router.rankCandidates(.{ .task_type = .programar, .required_context = 8000, .governance_mode = .local_only });
    defer {
        for (cands.items) |c| c.deinit(allocator);
        cands.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), cands.items.len);
    try std.testing.expectEqualStrings("Ollama", cands.items[0].provider_name);
    try std.testing.expectEqualStrings("qwen2.5:3b", cands.items[0].model_name);
    // Sin clave: api_key_id 0 y cuota neutra — no estorban al candidato local.
    try std.testing.expectEqual(@as(i64, 0), cands.items[0].api_key_id);

    // En modo normal el proveedor local no entra al ranking (sin clave activa):
    // es la misma asimetría que antes, solo que ahora local_only sí lo ve.
    var cloud = try router.rankCandidates(.{ .task_type = .programar, .required_context = 8000, .governance_mode = .hybrid });
    defer {
        for (cloud.items) |c| c.deinit(allocator);
        cloud.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), cloud.items.len);
    try std.testing.expectEqualStrings("Nuboso", cloud.items[0].provider_name);
}

test "T4: Fictional model registered in catalog.db works in router without touching model_router.zig" {
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var ledger = try db.Connection.open(allocator, ":memory:");
    defer ledger.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);
    try migrator.migrate(ledger, &db.ledger_schema);
    try seedDemoCatalog(catalog);

    // Register fictional provider & model in DB
    try catalog.exec("INSERT INTO providers (id, name, base_url, api_style, is_free_tier, enabled) VALUES (99, 'FictionalCorp', 'https://api.fictional.ai/v1', 'openai', 1, 1)");
    try catalog.exec("INSERT INTO api_keys (id, provider_id, label, key_ciphertext, status) VALUES (99, 99, 'key-fictional', x'00', 'active')");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, context_window, is_free, available) VALUES (99, 99, 'fictional-ai/model-v99', 128000, 1, 1)");

    var router = Router.init(allocator, catalog, ledger, 1);
    defer router.deinitHealthCache();
    try router.seedInitialScores();

    var candidates = try router.rankCandidates(.{ .task_type = .programar, .required_context = 8000, .governance_mode = .free_tier_first });
    defer {
        for (candidates.items) |c| c.deinit(allocator);
        candidates.deinit(allocator);
    }
    var found = false;
    for (candidates.items) |c| {
        if (std.mem.eql(u8, c.model_name, "fictional-ai/model-v99")) {
            found = true;
            break;
        }
    }
    try std.testing.expect(found);
}

/// Free policy uses catalog metadata; unknown models are never classified free.
pub fn catalogModelIsFree(catalog: db.Connection, provider: []const u8, model: []const u8) bool {
    const stmt = catalog.prepare("SELECT m.is_free FROM models m JOIN providers p ON m.provider_id = p.id WHERE p.name = ? AND m.model_name = ? LIMIT 1") catch return false;
    defer catalog.finalize(stmt);
    db.bindText(stmt, 1, provider) catch return false;
    db.bindText(stmt, 2, model) catch return false;
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW or db.c.sqlite3_column_int(stmt, 0) != 1) return false;
    if (std.ascii.eqlIgnoreCase(provider, "OpenCode")) return model_roster.isOpenCodeKnownFree(model);
    return true;
}

/// E5.11 (D-C1): por qué un par (provider, model) no puede abrir el modo
/// agéntico — el motivo viaja en el evento `agentic_unavailable`.
pub const AgenticGate = enum {
    /// `cap_tool_calls='yes'` con `provenance='live_probe'` y foto fresca.
    ok,
    /// Ninguna fila usable para (provider, model) en discovery_snapshots_v2.
    sin_fila,
    /// Hay fila pero la casilla de tool_calls nunca se midió en vivo
    /// (provenance != 'live_probe' — declarada o desconocida no basta).
    sin_medicion_viva,
    /// La medición viva existe y dice que NO soporta tool calls.
    medido_no,
    /// La foto tiene más de MATRIX_TTL_SECONDS: habla del modelo de hace
    /// un mes, no del de hoy.
    foto_caducada,
};

/// E5.11 (D-C1): puerta del modo agéntico. El modo escribe archivos de forma
/// autónoma dentro del worktree — solo se abre con evidencia medida EN VIVO:
/// `cap_tool_calls_status='yes'` AND `cap_tool_calls_provenance='live_probe'`
/// en una foto dentro del TTL (misma frescura que matrixEvidence). Cualquier
/// otra evidencia (declarada, 'unknown', caducada) devuelve el motivo del
/// rechazo — nunca un sí ambiguo.
pub fn agenticGateFor(catalog: db.Connection, provider: []const u8, model: []const u8, now: i64) AgenticGate {
    var prefixed_buf: [256]u8 = undefined;
    const prefixed = std.fmt.bufPrint(&prefixed_buf, "{s}/{s}", .{ provider, model }) catch model;
    const stmt = catalog.prepare(
        \\SELECT cap_tool_calls_status, cap_tool_calls_provenance, metadata_updated_at
        \\FROM discovery_snapshots_v2
        \\WHERE provider = ? AND (model_id = ? OR model_id = ?)
    ) catch return .sin_fila;
    defer catalog.finalize(stmt);
    db.bindText(stmt, 1, provider) catch return .sin_fila;
    db.bindText(stmt, 2, model) catch return .sin_fila;
    db.bindText(stmt, 3, prefixed) catch return .sin_fila;
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return .sin_fila;
    const status_ptr = db.c.sqlite3_column_text(stmt, 0);
    const prov_ptr = db.c.sqlite3_column_text(stmt, 1);
    const updated_ptr = db.c.sqlite3_column_text(stmt, 2);
    const status = if (status_ptr != null) status_ptr[0..std.mem.len(status_ptr)] else "";
    const provenance = if (prov_ptr != null) prov_ptr[0..std.mem.len(prov_ptr)] else "";
    const updated_at = if (updated_ptr != null) updated_ptr[0..std.mem.len(updated_ptr)] else "";
    const updated_ts = std.fmt.parseInt(i64, updated_at, 10) catch return .sin_fila;
    if (now - updated_ts > MATRIX_TTL_SECONDS) return .foto_caducada;
    if (!std.mem.eql(u8, provenance, "live_probe")) return .sin_medicion_viva;
    if (!std.mem.eql(u8, status, "yes")) return .medido_no;
    return .ok;
}

/// Atajo booleano del gate — mismo criterio que `agenticGateFor`.
pub fn capToolCallsLiveProbed(catalog: db.Connection, provider: []const u8, model: []const u8, now: i64) bool {
    return agenticGateFor(catalog, provider, model, now) == .ok;
}

/// E5.24: declared vision never authorizes delivery of an image. The row must
/// contain a successful live measurement, a real payload and a fresh timestamp.
pub fn capVisionLiveProbed(catalog: db.Connection, provider: []const u8, model: []const u8, now: i64) bool {
    const stmt = catalog.prepare(
        \\SELECT cap_vision_status,cap_vision_provenance,metadata_updated_at,metadata_payload_type
        \\FROM discovery_snapshots_v2 WHERE provider=? AND (model_id=? OR model_id=?)
    ) catch return false;
    defer catalog.finalize(stmt);
    var prefixed: [256]u8 = undefined;
    const identifier = std.fmt.bufPrint(&prefixed, "{s}/{s}", .{ provider, model }) catch return false;
    db.bindText(stmt, 1, provider) catch return false;
    db.bindText(stmt, 2, model) catch return false;
    db.bindText(stmt, 3, identifier) catch return false;
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return false;
    const measured_at = std.fmt.parseInt(i64, Router.columnText(stmt, 2), 10) catch return false;
    const payload = Router.columnText(stmt, 3);
    return std.mem.eql(u8, Router.columnText(stmt, 0), "yes") and
        std.mem.eql(u8, Router.columnText(stmt, 1), "live_probe") and
        (std.mem.eql(u8, payload, "live_probe") or std.mem.eql(u8, payload, "captured_real")) and
        measured_at <= now and now - measured_at <= MATRIX_TTL_SECONDS;
}

test "free-tier-first: OpenCode legacy is_free cannot bless paid names" {
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);
    try catalog.exec("INSERT INTO providers (id, name, base_url, api_style, is_free_tier) VALUES (1, 'OpenCode', 'https://opencode.ai/zen/v1', 'opencode', 1)");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, is_free, available) VALUES (1, 1, 'gpt-5.6', 1, 1)");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, is_free, available) VALUES (2, 1, 'mimo-v2.5-free', 1, 1)");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, is_free, available) VALUES (3, 1, 'big-pickle', 1, 1)");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, is_free, available) VALUES (101, 1, 'future-open-model', 1, 1)");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, is_free, available) VALUES (102, 1, 'mimo-v2.5-free-regression', 0, 1)");
    try std.testing.expect(!catalogModelIsFree(catalog, "OpenCode", "gpt-5.6"));
    try std.testing.expect(catalogModelIsFree(catalog, "OpenCode", "mimo-v2.5-free"));
    try std.testing.expect(catalogModelIsFree(catalog, "OpenCode", "big-pickle"));
    try std.testing.expect(!catalogModelIsFree(catalog, "OpenCode", "future-open-model"));
    try std.testing.expect(!catalogModelIsFree(catalog, "OpenCode", "mimo-v2.5-free-regression"));
    try std.testing.expect(!catalogModelIsFree(catalog, "OpenCode", "unregistered-model-free"));
}

test "CK-PRV-012: «Solo gratis» no gasta intentos en la pasarela HTTP de OpenCode" {
    const allocator = std.testing.allocator;
    var catalog = try db.Connection.open(allocator, ":memory:");
    defer catalog.close();
    var ledger = try db.Connection.open(allocator, ":memory:");
    defer ledger.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);
    try migrator.migrate(ledger, &db.ledger_schema);
    try catalog.exec("INSERT INTO providers (id, name, base_url, api_style, is_free_tier, enabled) VALUES (1, 'OpenCode', 'https://opencode.ai/zen/v1', 'opencode', 1, 1)");
    try catalog.exec("INSERT INTO providers (id, name, base_url, api_style, is_free_tier, enabled) VALUES (2, 'Cohere', 'https://api.cohere.com/v2', 'cohere', 1, 1)");
    try catalog.exec("INSERT INTO api_keys (id, provider_id, label, key_ciphertext, status) VALUES (1, 1, 'k', x'00', 'active'), (2, 2, 'k', x'00', 'active')");
    // Estado LEGACY: los gratuitos de OpenCode figuran disponibles (=1) —
    // exactamente lo que había en catalog.db antes de este arreglo.
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, is_free, available) VALUES (10, 1, 'deepseek-v4.1-flash-free', 1, 1)");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, is_free, available) VALUES (11, 1, 'mimo-v2.5-free', 1, 1)");
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, is_free, available) VALUES (12, 1, 'big-pickle', 1, 1)");
    // Y un modelo de PAGO del mismo proveedor, que NO debe cambiar.
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, is_free, available) VALUES (13, 1, 'deepseek-v4-pro', 0, 1)");
    // Un gratis sano de otro proveedor: la cadena «Solo gratis» sigue teniendo
    // a quién recurrir sin OpenCode.
    try catalog.exec("INSERT INTO models (id, provider_id, model_name, is_free, available) VALUES (20, 2, 'command-a-03-2025', 1, 1)");

    _ = try model_catalog.enforceHttpFreeTierPolicy(catalog);

    var router = Router.init(allocator, catalog, ledger, 1);
    defer router.deinitHealthCache();
    try router.seedInitialScores();

    var free_candidates = try router.rankCandidates(.{ .task_type = .programar, .required_context = 8000, .governance_mode = .free_tier_first });
    defer {
        for (free_candidates.items) |c| c.deinit(allocator);
        free_candidates.deinit(allocator);
    }
    // Ningún candidato HTTP de OpenCode (ni los gratuitos ni big-pickle)…
    var saw_cohere = false;
    for (free_candidates.items) |c| {
        try std.testing.expect(!std.ascii.eqlIgnoreCase(c.provider_name, "OpenCode"));
        if (std.mem.eql(u8, c.model_name, "command-a-03-2025")) saw_cohere = true;
    }
    // …y la cadena no se queda vacía: el gratis de Cohere sigue elegible.
    try std.testing.expect(saw_cohere);

    // Los de PAGO de OpenCode no cambian: siguen siendo candidatos en pago.
    var paid_candidates = try router.rankCandidates(.{ .task_type = .programar, .required_context = 8000, .governance_mode = .paid_tier_first });
    defer {
        for (paid_candidates.items) |c| c.deinit(allocator);
        paid_candidates.deinit(allocator);
    }
    var saw_paid = false;
    for (paid_candidates.items) |c| {
        try std.testing.expect(!(std.ascii.eqlIgnoreCase(c.provider_name, "OpenCode") and c.is_free));
        if (std.mem.eql(u8, c.model_name, "deepseek-v4-pro")) saw_paid = true;
    }
    try std.testing.expect(saw_paid);
}

// ── MATRIZ-RANKING: tests de la capa de compatibilidad ──────────────────────

/// Inserta una fila usable en discovery_snapshots_v2 (payload 'captured_real',
/// procedencias 'test'); las columnas no consultadas quedan en 'unknown'.
fn insertMatrixRow(conn: db.Connection, provider: []const u8, model_id: []const u8, chat: []const u8, streaming: []const u8, reasoning: []const u8, updated_at: []const u8) !void {
    return insertMatrixRowPayload(conn, provider, model_id, chat, streaming, reasoning, updated_at, "captured_real");
}

/// Idem con payload_type explícito — para fijar qué tipos de evidencia la
/// matriz considera usables.
fn insertMatrixRowPayload(conn: db.Connection, provider: []const u8, model_id: []const u8, chat: []const u8, streaming: []const u8, reasoning: []const u8, updated_at: []const u8, payload_type: []const u8) !void {
    const stmt = try conn.prepare(
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
        \\  cost_category, auth_required,
        \\  metadata_source, metadata_updated_at, metadata_payload_type, health_state
        \\) VALUES (?,?,'test','test','test://endpoint',
        \\  ?,'test', ?,'test', 'unknown','not_probed','unknown','not_probed',
        \\  'unknown','not_probed', ?,'test', 'unknown','not_probed',
        \\  'unknown','not_probed','unknown','not_probed',
        \\  'free',1,'test',?,?,'unknown')
    );
    defer conn.finalize(stmt);
    try db.bindText(stmt, 1, provider);
    try db.bindText(stmt, 2, model_id);
    try db.bindText(stmt, 3, chat);
    try db.bindText(stmt, 4, streaming);
    try db.bindText(stmt, 5, reasoning);
    try db.bindText(stmt, 6, updated_at);
    try db.bindText(stmt, 7, payload_type);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
}

fn matrixTestCatalog(allocator: std.mem.Allocator) !db.Connection {
    var catalog = try db.Connection.open(allocator, ":memory:");
    errdefer catalog.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(catalog, &db.catalog_schema);
    try seedDemoCatalog(catalog);
    return catalog;
}

test "CK-COMP-007 r2 error del lector conserva CLI y cadena de respaldo" {
    const a = std.testing.allocator;
    var catalog = try db.Connection.open(a, ":memory:");
    defer catalog.close();
    const migrator = db.Migrator.init(a);
    try migrator.migrate(catalog, &db.catalog_schema);
    try catalog.exec("INSERT INTO providers(id,name,base_url,api_style,is_local) VALUES(901,'agent:codex','local://fixture','openai',1),(902,'agent:claude-code','local://fixture','openai',1),(903,'fixture-backup','local://fixture','openai',1)");
    try catalog.exec("INSERT INTO models(id,provider_id,model_name,context_window,is_free,available) VALUES(901,901,'fixture-codex',64000,0,1),(902,902,'fixture-claude',64000,0,1),(903,903,'fixture-backup',64000,0,1)");
    try catalog.exec("INSERT INTO settings(key,value) VALUES('cli_quota_codex_source','fixture://codex'),('cli_quota_claude-code_source','fixture://claude')");
    const FailingReader = struct {
        fn read(_: std.mem.Allocator, _: []const u8) anyerror![]u8 {
            return error.OutOfMemory;
        }

        fn current(allocator: std.mem.Allocator, conn: db.Connection, cli: @import("cli_quota.zig").Cli) anyerror!@import("cli_quota.zig").Snapshot {
            return @import("cli_quota.zig").load(allocator, conn, cli, 1, read);
        }
    };
    var router = Router.init(a, catalog, null, 1);
    defer router.deinitHealthCache();
    router.quota_current = FailingReader.current;
    for ([_]@import("cli_quota.zig").Cli{ .codex, .@"claude-code" }) |cli| {
        try std.testing.expectError(error.OutOfMemory, router.quota_current(a, catalog, cli));
    }
    var candidates = try router.rankCandidates(.{ .task_type = .programar, .required_context = 1000, .governance_mode = .local_only });
    defer {
        for (candidates.items) |candidate| candidate.deinit(a);
        candidates.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 3), candidates.items.len);
    for ([_][]const u8{ "agent:codex", "agent:claude-code", "fixture-backup" }) |provider| {
        var found = false;
        for (candidates.items) |candidate| {
            if (std.mem.eql(u8, provider, candidate.provider_name)) found = true;
        }
        try std.testing.expect(found);
    }
}

test "MATRIZ-RANKING: modelo con capacidad requerida en 'no' queda excluido" {
    const allocator = std.testing.allocator;
    var catalog = try matrixTestCatalog(allocator);
    defer catalog.close();
    const now: i64 = 1_800_000_000;
    // deepseek-coder-free medido SIN streaming: live_worker llama siempre con
    // .stream=true — el candidato no puede ni entrar al ranking.
    try insertMatrixRow(catalog, "OpenCode", "deepseek-coder-free", "yes", "no", "unknown", "1800000000");
    var router = Router.init(allocator, catalog, null, now);
    defer router.deinitHealthCache();
    try router.seedInitialScores();
    var candidates = try router.rankCandidates(.{ .task_type = .programar, .required_context = 8000 });
    defer {
        for (candidates.items) |c| c.deinit(allocator);
        candidates.deinit(allocator);
    }
    try std.testing.expect(candidates.items.len > 0);
    for (candidates.items) |c| {
        try std.testing.expect(!std.mem.eql(u8, c.model_name, "deepseek-coder-free"));
    }
}

test "MATRIZ-RANKING: matriz vacia conserva el comportamiento anterior" {
    const allocator = std.testing.allocator;
    var catalog = try matrixTestCatalog(allocator);
    defer catalog.close();
    var router = Router.init(allocator, catalog, null, 1);
    defer router.deinitHealthCache();
    try router.seedInitialScores();
    var candidate = try router.route(.{ .task_type = .programar_zig, .required_context = 8000 });
    defer candidate.deinit(allocator);
    try std.testing.expect(candidate.is_free);
    try std.testing.expect(std.mem.indexOf(u8, candidate.reason, "matrix=1.000") != null);
    try std.testing.expect(std.mem.indexOf(u8, candidate.reason, "matrix_state=none") != null);
}

test "MATRIZ-RANKING: snapshot caducado no veta ni favorece" {
    const allocator = std.testing.allocator;
    var catalog = try matrixTestCatalog(allocator);
    defer catalog.close();
    const now: i64 = 1_800_000_000;
    // streaming='no' pero la foto tiene 31 días: una casilla caducada no sabe
    // nada del modelo de hoy — no puede vetarlo.
    const stale_ts = try std.fmt.allocPrint(allocator, "{d}", .{now - MATRIX_TTL_SECONDS - 100});
    defer allocator.free(stale_ts);
    try insertMatrixRow(catalog, "OpenCode", "deepseek-coder-free", "yes", "no", "unknown", stale_ts);
    var router = Router.init(allocator, catalog, null, now);
    defer router.deinitHealthCache();
    try router.seedInitialScores();
    var candidates = try router.rankCandidates(.{ .task_type = .programar, .required_context = 8000 });
    defer {
        for (candidates.items) |c| c.deinit(allocator);
        candidates.deinit(allocator);
    }
    var found = false;
    for (candidates.items) |c| {
        if (std.mem.eql(u8, c.model_name, "deepseek-coder-free")) {
            found = true;
            try std.testing.expect(std.mem.indexOf(u8, c.reason, "matrix_state=none") != null);
        }
    }
    try std.testing.expect(found);
}

test "MATRIZ-RANKING: fila live_probe es evidencia usable — un 'no' medido en vivo veta" {
    const allocator = std.testing.allocator;
    var catalog = try matrixTestCatalog(allocator);
    defer catalog.close();
    const now: i64 = 1_800_000_000;
    // Un sondeo real midió chat='no' (404) hoy: la fila no vino de /models pero
    // es evidencia medida — debe vetar igual que una foto capturada.
    try insertMatrixRowPayload(catalog, "OpenCode", "deepseek-coder-free", "no", "unknown", "unknown", "1800000000", "live_probe");
    var router = Router.init(allocator, catalog, null, now);
    defer router.deinitHealthCache();
    try router.seedInitialScores();
    var candidates = try router.rankCandidates(.{ .task_type = .programar, .required_context = 8000 });
    defer {
        for (candidates.items) |c| c.deinit(allocator);
        candidates.deinit(allocator);
    }
    try std.testing.expect(candidates.items.len > 0);
    for (candidates.items) |c| {
        try std.testing.expect(!std.mem.eql(u8, c.model_name, "deepseek-coder-free"));
    }
}

test "MATRIZ-RANKING: 'yes' medido sube el score frente a la misma fila sin matriz" {
    const allocator = std.testing.allocator;
    var catalog = try matrixTestCatalog(allocator);
    defer catalog.close();
    const now: i64 = 1_800_000_000;
    var router = Router.init(allocator, catalog, null, now);
    defer router.deinitHealthCache();
    try router.seedInitialScores();
    const request = RouteRequest{ .task_type = .programar, .required_context = 8000 };
    var score_without: f64 = 0;
    {
        var candidates = try router.rankCandidates(request);
        defer {
            for (candidates.items) |c| c.deinit(allocator);
            candidates.deinit(allocator);
        }
        for (candidates.items) |c| {
            if (std.mem.eql(u8, c.model_name, "deepseek-coder-free")) score_without = c.score;
        }
    }
    try std.testing.expect(score_without > 0);
    try insertMatrixRow(catalog, "OpenCode", "deepseek-coder-free", "yes", "yes", "unknown", "1800000000");
    router.invalidateHealthCache(); // la matriz se consulta en vivo, sin cache
    var score_with: f64 = 0;
    var saw_factor = false;
    {
        var candidates = try router.rankCandidates(request);
        defer {
            for (candidates.items) |c| c.deinit(allocator);
            candidates.deinit(allocator);
        }
        for (candidates.items) |c| {
            if (std.mem.eql(u8, c.model_name, "deepseek-coder-free")) {
                score_with = c.score;
                saw_factor = std.mem.indexOf(u8, c.reason, "matrix_state=chat:yes,streaming:yes") != null;
            }
        }
    }
    try std.testing.expect(score_with > score_without);
    try std.testing.expect(saw_factor);
}

test "E5.24 vision routing requires fresh measured evidence for entire candidate chain" {
    const a = std.testing.allocator;
    var catalog = try matrixTestCatalog(a);
    defer catalog.close();
    const now: i64 = 1800000000;
    var unavailable_catalog = try db.Connection.open(a, ":memory:");
    defer unavailable_catalog.close();
    try std.testing.expect(!capVisionLiveProbed(unavailable_catalog, "OpenCode", "deepseek-coder-free", now));
    var router = Router.init(a, catalog, null, now);
    defer router.deinitHealthCache();
    const request = RouteRequest{ .task_type = .programar, .required_context = 8000, .needs_vision = true };
    try std.testing.expectError(error.NoCandidates, router.route(request));
    try @import("discovery_persistence.zig").persistCapabilityEvidence(catalog, "OpenCode", "deepseek-coder-free", "openai", "fixture://only", .{ .vision = "yes" }, now);
    try std.testing.expect(capVisionLiveProbed(catalog, "OpenCode", "deepseek-coder-free", now));
    var candidates = try router.rankCandidates(request);
    defer {
        for (candidates.items) |c| c.deinit(a);
        candidates.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 1), candidates.items.len);
    try std.testing.expectEqualStrings("deepseek-coder-free", candidates.items[0].model_name);
    try catalog.exec("UPDATE discovery_snapshots_v2 SET cap_vision_provenance='provider_declared'");
    try std.testing.expect(!capVisionLiveProbed(catalog, "OpenCode", "deepseek-coder-free", now));
    try std.testing.expectError(error.NoCandidates, router.route(request));
    try catalog.exec("UPDATE discovery_snapshots_v2 SET cap_vision_provenance='live_probe',metadata_updated_at='1'");
    try std.testing.expectError(error.NoCandidates, router.route(request));
    try catalog.exec("UPDATE discovery_snapshots_v2 SET metadata_updated_at='1800000001'");
    try std.testing.expect(!capVisionLiveProbed(catalog, "OpenCode", "deepseek-coder-free", now));
    try catalog.exec("UPDATE discovery_snapshots_v2 SET metadata_updated_at='1800000000',metadata_payload_type='dummy'");
    try std.testing.expectError(error.NoCandidates, router.route(request));
    try catalog.exec("UPDATE discovery_snapshots_v2 SET metadata_payload_type='live_probe',cap_vision_status='no'");
    try std.testing.expectError(error.NoCandidates, router.route(request));
    var nonvisual = try router.route(.{ .task_type = .programar, .required_context = 8000 });
    defer nonvisual.deinit(a);
}

test "CK-PRV-004 C2 classifier rejects observed non chat families case insensitively" {
    for ([_][]const u8{ "baai/bge-m3", "nvidia/studiovoice", "BAAI/BGE-M3", "FLUX.1", "whisper-v3" }) |name| {
        try std.testing.expect(isNonTextGenModel(name));
    }
    for ([_][]const u8{ "qwen/chat", "deepseek-v4.1-flash-free", "gpt-6.1-sol" }) |name| {
        try std.testing.expect(!isNonTextGenModel(name));
    }
}

test "CK-PRV-004 C2 router honors catalog is_generative metadata" {
    const a = std.testing.allocator;
    var c = try db.Connection.open(a, ":memory:");
    defer c.close();
    try db.Migrator.init(a).migrate(c, &db.catalog_schema);
    try c.exec("INSERT INTO providers(id,name,base_url,api_style,enabled) VALUES(1,'Fixture','http://fixture','openai',1)");
    try c.exec("INSERT INTO api_keys(provider_id,label,key_ciphertext,status) VALUES(1,'synthetic',X'00','active')");
    try c.exec("INSERT INTO models(provider_id,model_name,is_free,available,is_generative) VALUES(1,'chat',1,1,1),(1,'opaque-nonchat',1,1,0),(1,'baai/bge-m3',1,1,1),(1,'nvidia/studiovoice',1,1,1)");
    var r = Router.init(a, c, null, 1);
    defer r.deinitHealthCache();
    var ranked = try r.rankCandidates(.{ .task_type = .programar, .required_context = 0, .governance_mode = .free_tier_first });
    defer {
        for (ranked.items) |v| v.deinit(a);
        ranked.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 1), ranked.items.len);
    try std.testing.expectEqualStrings("chat", ranked.items[0].model_name);
}

test "CK-PRV-004 C4 router excludes a veto independently of selector visibility" {
    const a = std.testing.allocator;
    var c = try db.Connection.open(a, ":memory:");
    defer c.close();
    try db.Migrator.init(a).migrate(c, &db.catalog_schema);
    try c.exec("CREATE TABLE IF NOT EXISTS model_preferences(provider TEXT NOT NULL,model TEXT NOT NULL,show_in_selectors INTEGER NOT NULL DEFAULT 1,allow_automatic INTEGER NOT NULL DEFAULT 1,PRIMARY KEY(provider,model))");
    try c.exec("INSERT INTO providers(id,name,base_url,api_style,enabled) VALUES(1,'Fixture','http://fixture','openai',1)");
    try c.exec("INSERT INTO api_keys(provider_id,label,key_ciphertext,status) VALUES(1,'synthetic',X'00','active')");
    try c.exec("INSERT INTO models(provider_id,model_name,is_free,available) VALUES(1,'hidden',1,1),(1,'vetoed',1,1)");
    try c.exec("INSERT INTO model_preferences VALUES('Fixture','hidden',0,1),('Fixture','vetoed',1,0)");
    var r = Router.init(a, c, null, 1);
    defer r.deinitHealthCache();
    var ranked = try r.rankCandidates(.{ .task_type = .programar, .required_context = 0, .governance_mode = .free_tier_first });
    defer {
        for (ranked.items) |v| v.deinit(a);
        ranked.deinit(a);
    }
    try std.testing.expectEqual(@as(usize, 1), ranked.items.len);
    try std.testing.expectEqualStrings("hidden", ranked.items[0].model_name);
}
