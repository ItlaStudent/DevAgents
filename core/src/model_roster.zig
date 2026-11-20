//! ROSTER-PRUEBAS: acota la cadena de candidatos a un puñado de modelos.
//!
//! El problema que resuelve, medido en `runtime.db` el 2026-08-11: el catálogo
//! marca `is_free = 1` a TODOS los modelos de un proveedor free-tier, porque el
//! descubrimiento propaga el flag del PROVEEDOR (`discoverFromJson(name, json,
//! cfg.is_free_tier)`). Así, los 55 modelos premium de OpenCode —gpt-5.5-pro,
//! claude-opus-5, deepseek-v4-pro…— figuran como gratis, la cadena los prueba, y
//! los 55 devuelven `auth_failed`: 154 intentos, 0 aciertos. Cada orden pagaba ese
//! peaje antes de llegar a un modelo que sí responde.
//!
//! Ilimitados de verdad hay unos pocos (los que llevan `-free`/`:free` en el
//! nombre). Este roster permite fijar ESE puñado para las pruebas, sin tocar el
//! catálogo ni la gobernanza: se activa por variable de entorno y, si no está
//! puesta, aquí no pasa nada — `allows` devuelve true para todo.
//!
//! Es deliberadamente una variable de entorno y no una preferencia guardada: un
//! ajuste de pruebas no debe sobrevivir a la sesión de pruebas ni aparecer
//! después como "configuración" que nadie recuerda haber puesto.
//!
//!   DEVAGENTS_MODEL_ROSTER=free                      → solo los -free/:free
//!   DEVAGENTS_MODEL_ROSTER=OpenCode/mimo-v2.5-free,Cohere/command-a-03-2025
//!   DEVAGENTS_MODEL_ROSTER=Cohere/*                  → todo un proveedor
//!
//! El filtro NUNCA deja la cadena vacía: quien lo consulta comprueba primero si
//! algún candidato pasa el roster y solo entonces descarta el resto (ver
//! `live_worker.appendDiverseCandidates` y `model_router.route`). Un roster mal
//! escrito degrada a "sin filtro", no a "sin modelos".

const std = @import("std");
const sync = @import("sync.zig");

pub const ENV_VAR = "DEVAGENTS_MODEL_ROSTER";

/// Comodín que selecciona los modelos gratuitos ILIMITADOS: los que llevan la
/// marca en el propio nombre. Es la única fuente de precio fiable que tenemos —
/// la columna `is_free` del catálogo hereda el flag del proveedor y miente.
pub const FREE_TOKEN = "free";

/// ¿El nombre del modelo declara que es la variante gratuita ilimitada?
/// `mimo-v2.5-free`, `qwen/qwen3-coder:free`, `ling-3.0-flash-free`.
pub fn isFreeNamed(model: []const u8) bool {
    if (std.mem.endsWith(u8, model, "-free") or std.mem.endsWith(u8, model, ":free")) return true;
    return std.mem.indexOf(u8, model, "-free-") != null or
        std.mem.indexOf(u8, model, ":free-") != null;
}

/// OpenCode's free catalog is name-scoped; provider-level `is_free_tier` is
/// not sufficient because the same endpoint also exposes paid models.
pub fn isOpenCodeKnownFree(model: []const u8) bool {
    return isFreeNamed(model) or
        std.ascii.eqlIgnoreCase(model, "big-pickle") or
        std.mem.endsWith(u8, model, "/big-pickle");
}

fn eqIgnoreCase(a: []const u8, b: []const u8) bool {
    return std.ascii.eqlIgnoreCase(a, b);
}

/// El nombre "corto" de un modelo: `models/gemini-3.5-flash` → `gemini-3.5-flash`.
/// Gemini prefija todo su catálogo con `models/`; escribirlo en el roster a mano
/// es una fuente de erratas silenciosas.
fn shortName(model: []const u8) []const u8 {
    if (std.mem.lastIndexOfScalar(u8, model, '/')) |i| return model[i + 1 ..];
    return model;
}

/// ¿`provider/model` está en el roster `spec`? Con `spec` nulo o en blanco no hay
/// roster y todo pasa. Función pura: el enganche con el entorno es `fromEnv`.
pub fn allows(spec: ?[]const u8, provider: []const u8, model: []const u8) bool {
    const raw = spec orelse return true;
    const list = std.mem.trim(u8, raw, &std.ascii.whitespace);
    if (list.len == 0) return true;

    var it = std.mem.tokenizeAny(u8, list, ",;\n\r\t");
    while (it.next()) |token| {
        const entry = std.mem.trim(u8, token, &std.ascii.whitespace);
        if (entry.len == 0) continue;

        if (eqIgnoreCase(entry, FREE_TOKEN)) {
            if (isFreeNamed(model)) return true;
            continue;
        }

        // `Proveedor/*`: el proveedor entero.
        if (std.mem.endsWith(u8, entry, "/*")) {
            if (eqIgnoreCase(entry[0 .. entry.len - 2], provider)) return true;
            continue;
        }

        // `Proveedor/modelo`. Se parte por la PRIMERA barra porque el modelo
        // puede llevar las suyas (`models/gemini-3.5-flash`, `qwen/qwen3:free`).
        if (std.mem.indexOfScalar(u8, entry, '/')) |slash| {
            const p = entry[0..slash];
            const m = entry[slash + 1 ..];
            if (eqIgnoreCase(p, provider) and
                (eqIgnoreCase(m, model) or eqIgnoreCase(m, shortName(model)))) return true;
            // No era `proveedor/modelo` sino un modelo con barra escrito a secas
            // (`models/gemini-3.5-flash`): se sigue comparando entero abajo.
        }

        if (eqIgnoreCase(entry, model) or eqIgnoreCase(entry, shortName(model))) return true;
    }
    return false;
}

// ── Lectura del entorno, una sola vez por proceso ──────────────────────────
// `allows` se llama una vez por candidato y por orden; leer el entorno ahí
// dentro convertiría un ajuste de pruebas en un coste por fila.

var env_mutex: sync.Mutex = sync.Mutex.init();
var env_loaded: bool = false;
var env_value: ?[]const u8 = null;

/// El roster en vigor, o null si no hay ninguno. La cadena devuelta es propiedad
/// del proceso (vive hasta que termina): no se libera.
pub fn fromEnv() ?[]const u8 {
    env_mutex.lock();
    defer env_mutex.unlock();
    if (!env_loaded) {
        env_loaded = true;
        // `Environ.getAlloc` construye el mapa entero del entorno; por eso se
        // llama UNA vez y se cachea, no una vez por candidato.
        env_value = std.process.Environ.getAlloc(@import("platform.zig").environ(), std.heap.page_allocator, ENV_VAR) catch null;
        if (env_value) |v| {
            if (std.mem.trim(u8, v, &std.ascii.whitespace).len == 0) env_value = null;
        }
    }
    return env_value;
}

/// Atajo: ¿pasa el roster EN VIGOR? Es lo que llaman live_worker y model_router.
pub fn allowsEnv(provider: []const u8, model: []const u8) bool {
    return allows(fromEnv(), provider, model);
}

/// Solo para tests: fija el roster sin tocar el entorno del proceso.
pub fn setForTest(spec: ?[]const u8) void {
    env_mutex.lock();
    defer env_mutex.unlock();
    env_loaded = true;
    env_value = spec;
}

// ── Tests ──────────────────────────────────────────────────────────────────

test "ROSTER: sin roster no se filtra nada" {
    try std.testing.expect(allows(null, "OpenCode", "gpt-5.5-pro"));
    try std.testing.expect(allows("", "OpenCode", "gpt-5.5-pro"));
    try std.testing.expect(allows("   \n ", "OpenCode", "gpt-5.5-pro"));
}

test "ROSTER: `free` deja pasar solo a los gratuitos de verdad" {
    // Los 7 que el catálogo real tiene marcados en el nombre.
    try std.testing.expect(allows("free", "OpenCode", "mimo-v2.5-free"));
    try std.testing.expect(allows("free", "OpenCode", "deepseek-v4-flash-free"));
    try std.testing.expect(allows("free", "OpenCode", "north-mini-code-free"));
    try std.testing.expect(allows("free", "OpenRouter", "qwen/qwen3-coder:free"));
    // Y los premium que el catálogo marca is_free=1 por herencia del proveedor:
    // son justo los 55 que devolvían auth_failed.
    try std.testing.expect(!allows("free", "OpenCode", "claude-opus-5"));
    try std.testing.expect(!allows("free", "OpenCode", "gpt-5.5-pro"));
    try std.testing.expect(!allows("free", "OpenCode", "deepseek-v4-pro"));
    // `deepseek-v4-flash` (pago) no se cuela por parecerse a `-free`.
    try std.testing.expect(!allows("free", "OpenCode", "deepseek-v4-flash"));
}

test "ROSTER: lista explícita proveedor/modelo" {
    const spec = "OpenCode/mimo-v2.5-free, Cohere/command-a-03-2025";
    try std.testing.expect(allows(spec, "OpenCode", "mimo-v2.5-free"));
    try std.testing.expect(allows(spec, "Cohere", "command-a-03-2025"));
    try std.testing.expect(!allows(spec, "Cohere", "command-a-plus-05-2026"));
    // El mismo nombre bajo otro proveedor NO pasa: la entrada lleva proveedor.
    try std.testing.expect(!allows(spec, "OpenRouter", "mimo-v2.5-free"));
}

test "ROSTER: el prefijo `models/` de Gemini no obliga a escribirlo" {
    try std.testing.expect(allows("Gemini/gemini-3.1-flash-lite-preview", "Gemini", "models/gemini-3.1-flash-lite-preview"));
    try std.testing.expect(allows("Gemini/models/gemini-3.6-flash", "Gemini", "models/gemini-3.6-flash"));
    try std.testing.expect(allows("gemini-3.6-flash", "Gemini", "models/gemini-3.6-flash"));
    try std.testing.expect(!allows("Gemini/gemini-3.6-flash", "Gemini", "models/gemini-2.5-pro"));
}

test "ROSTER: comodín de proveedor" {
    try std.testing.expect(allows("Cohere/*", "Cohere", "command-a-03-2025"));
    try std.testing.expect(allows("Cohere/*", "Cohere", "north-mini-code-1-0"));
    try std.testing.expect(!allows("Cohere/*", "OpenCode", "mimo-v2.5-free"));
}

test "ROSTER: se combinan comodines, `free` y entradas sueltas" {
    const spec = "free, Cohere/command-a-03-2025";
    try std.testing.expect(allows(spec, "OpenCode", "ling-3.0-flash-free"));
    try std.testing.expect(allows(spec, "Cohere", "command-a-03-2025"));
    try std.testing.expect(!allows(spec, "Gemini", "models/gemini-2.5-pro"));
}

test "ROSTER: mayúsculas y espacios no cambian el resultado" {
    try std.testing.expect(allows("  opencode/MIMO-V2.5-FREE  ", "OpenCode", "mimo-v2.5-free"));
    try std.testing.expect(allows("FREE", "OpenCode", "mimo-v2.5-free"));
}

test "ROSTER: separadores alternativos (salto de línea, punto y coma)" {
    const spec = "OpenCode/mimo-v2.5-free;\nCohere/command-a-03-2025\n";
    try std.testing.expect(allows(spec, "OpenCode", "mimo-v2.5-free"));
    try std.testing.expect(allows(spec, "Cohere", "command-a-03-2025"));
}
