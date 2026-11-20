//! core/src/llm_planner.zig — Planificador VIVO del superagente (de-mockea el plan).
//!
//! Implementa PlannerBackend usando un LLM real (vía live_worker.LiveLlm, mismo pool de
//! proveedores con fallback free-first que los workers): dada la orden, pide al modelo un
//! plan JSON (entendimiento + grafo de tareas tipadas con contratos) y lo valida contra
//! la taxonomía F3 y los departamentos F5. Ante CUALQUIER fallo (sin clave, red, JSON
//! inválido, enum desconocido) DEGRADA a MockPlanner — el pipeline nunca se rompe.
//!
//! Es el `LlmPlanner` que spec 009 anticipaba ("(futuro) un LlmPlanner sobre los
//! conectores F2"); ahora que hay claves, se cablea.

const std = @import("std");
const planner = @import("planner.zig");
const model_router = @import("model_router.zig");
const contracts = @import("contracts.zig");
const live_worker = @import("live_worker.zig");
const model_catalog = @import("model_catalog.zig");
const db = @import("db.zig");
const health = @import("health.zig");
const credentials = @import("credentials.zig");
const sync = @import("sync.zig");

const DeleteFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn DeleteFileA(lpFileName: [*:0]const u8) callconv(.winapi) std.os.windows.BOOL;
}.DeleteFileA else @import("providers").posix_files.DeleteFileA;
const GetTickCount64 = @import("platform.zig").ticks;
const Sleep = @import("platform.zig").sleep;

const DEPARTMENTS = [_][]const u8{ "programacion", "testing", "auditoria", "correccion", "documentacion", "diseno" };

const PlannerThreadCallFn = *const fn (?*anyopaque, []const u8, []const u8) []const u8;
const PlannerThreadCancelFn = *const fn (?*anyopaque) void;

const PlannerThreadCall = struct {
    allocator: std.mem.Allocator,
    call_fn: PlannerThreadCallFn,
    call_ctx: ?*anyopaque,
    system_prompt: []const u8,
    user_prompt: []u8,
    result: ?[]u8 = null,
    done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

/// Ejecuta una llamada con ownership completo del contexto y join obligatorio.
/// En timeout se cancela, recoge el hilo y descarta cualquier respuesta tardía.
fn runPlannerThreadCall(
    allocator: std.mem.Allocator,
    call_fn: PlannerThreadCallFn,
    cancel_fn: PlannerThreadCancelFn,
    call_ctx: ?*anyopaque,
    system_prompt: []const u8,
    user_prompt: []const u8,
    timeout_ms: u64,
) ?[]u8 {
    const state = allocator.create(PlannerThreadCall) catch return null;
    const prompt_owned = allocator.dupe(u8, user_prompt) catch {
        allocator.destroy(state);
        return null;
    };
    state.* = .{
        .allocator = allocator,
        .call_fn = call_fn,
        .call_ctx = call_ctx,
        .system_prompt = system_prompt,
        .user_prompt = prompt_owned,
    };
    const thread = std.Thread.spawn(.{}, struct {
        fn run(s: *PlannerThreadCall) void {
            const response = s.call_fn(s.call_ctx, s.system_prompt, s.user_prompt);
            s.result = s.allocator.dupe(u8, response) catch null;
            s.done.store(true, .release);
        }
    }.run, .{state}) catch {
        allocator.free(prompt_owned);
        allocator.destroy(state);
        return null;
    };

    const start_ms = GetTickCount64();
    var timed_out = false;
    while (!state.done.load(.acquire)) {
        if (GetTickCount64() - start_ms >= timeout_ms) {
            timed_out = true;
            break;
        }
        Sleep(10);
    }
    if (timed_out) cancel_fn(call_ctx);
    thread.join();

    const result = state.result;
    allocator.free(state.user_prompt);
    allocator.destroy(state);
    if (timed_out) {
        if (result) |late| allocator.free(late);
        return null;
    }
    return result;
}

/// PLAN-CANCEL: destino opcional donde tryLlmPlan publica el token de la
/// llamada LLM en curso. El propietario del slot (CoreState) lo lee desde
/// da_plan_cancel para abortar la E/S; se escribe SIEMPRE bajo `mutex` y
/// vuelve a null antes de que el token se libere.
pub const PlanCancelSlot = struct {
    mutex: *sync.Mutex,
    slot: *?*live_worker.CancellationToken,
};

const LivePlannerCall = struct {
    live: *live_worker.LiveLlm,
    token: *live_worker.CancellationToken,

    fn call(ctx: ?*anyopaque, system_prompt: []const u8, user_prompt: []const u8) []const u8 {
        const self: *LivePlannerCall = @ptrCast(@alignCast(ctx.?));
        return self.live.completeObject(system_prompt, user_prompt);
    }

    fn cancel(ctx: ?*anyopaque) void {
        const self: *LivePlannerCall = @ptrCast(@alignCast(ctx.?));
        self.token.cancel();
    }
};

const CAPABILITIES_CONTEXT =
    \\Capacidades reales de DevAgents:
    \\- Cliente MCP nativo (stdio + HTTP) y descubrimiento de herramientas (T-F4-01 / T-F4-04).
    \\- 5 departamentos de agentes: programación, testing, auditoría, corrección, documentación (F5).
    \\- Ejecución gobernada por pipeline con sandbox y flujo de aprobaciones (T-F7-07).
    \\- Catálogo real de modelos/proveedores con routing free-tier-first.
    \\- Ejecuta/compila código DENTRO del sandbox; cualquier cosa fuera del sandbox, red o gasto requiere aprobación (EXEC-01).
    \\- Ejecución de órdenes de origen remoto/no confiable requiere aprobación humana antes de cualquier spawn (EXEC-02).
    \\Instrucción: describe lo que SÍ puede hacer en lugar de negarlo de plano.
;

/// Heurística simple: ¿la orden del usuario es sobre el catálogo de modelos/proveedores?
fn isCatalogIntent(order: []const u8) bool {
    const keywords = [_][]const u8{ "modelo", "modelos", "catálogo", "catalogo", "proveedor", "proveedores", "context window", "contexto" };
    var buf: [256]u8 = undefined;
    const n = @min(order.len, buf.len);
    for (order[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const low = buf[0..n];
    for (keywords) |kw| {
        if (std.mem.indexOf(u8, low, kw) != null) return true;
    }
    return false;
}

/// Heurística simple: ¿la orden del usuario pregunta por capacidades/herramientas/MCPs?
fn isCapabilitiesIntent(order: []const u8) bool {
    const keywords = [_][]const u8{ "mcp", "herramienta", "herramientas", "tool", "tools", "capacidad", "capacidades", "qué puedes", "que puedes", "puedes hacer", "tienes acceso", "funciones", "habilidades" };
    var buf: [256]u8 = undefined;
    const n = @min(order.len, buf.len);
    for (order[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const low = buf[0..n];
    for (keywords) |kw| {
        if (std.mem.indexOf(u8, low, kw) != null) return true;
    }
    return false;
}

fn isWordChar(ch: u8) bool {
    return (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '+';
}

fn containsWord(haystack: []const u8, word: []const u8) bool {
    var i: usize = 0;
    while (std.mem.indexOfPos(u8, haystack, i, word)) |pos| {
        const before_ok = pos == 0 or !isWordChar(haystack[pos - 1]);
        const after_idx = pos + word.len;
        const after_ok = after_idx >= haystack.len or !isWordChar(haystack[after_idx]);
        if (before_ok and after_ok) return true;
        i = pos + 1;
    }
    return false;
}

/// FIX-ENGINE-10-A: Strip prefixes añadidos por la UI (notas de conocimiento,
/// context pills) antes de detectar intent. La UI prepende "--- Notas de contexto
/// adjuntas ---\n...\n--- Fin de notas ---\n\n" y "@label @label\n" al texto del
/// usuario. Sin esto, los verbos de ejecución pueden quedar fuera del buffer de
/// detección (512 bytes) o fallar el startsWith.
fn stripContextPrefix(text: []const u8) []const u8 {
    var t = text;
    // Strip knowledge notes prefix: "--- Notas de contexto adjuntas ---\n...\n--- Fin de notas ---\n"
    const kn_marker = "--- Notas de contexto adjuntas ---";
    const kn_end = "--- Fin de notas ---";
    if (std.mem.startsWith(u8, t, kn_marker)) {
        if (std.mem.indexOf(u8, t, kn_end)) |end_pos| {
            t = t[end_pos + kn_end.len ..];
            t = std.mem.trim(u8, t, " \t\r\n");
        }
    }
    // Strip fast context blocks: [Contexto: ...], [Archivos abiertos: ...], etc.
    // The UI prepends these before the user's order text. Each block starts with
    // a known prefix in brackets and ends with ] followed by newline (or end of text).
    const ctx_prefixes = [_][]const u8{
        "[Contexto:",
        "[Archivos abiertos:",
        "[Estructura del proyecto:",
        "[Selecci",
    };
    while (t.len > 0 and t[0] == '[') {
        var matched = false;
        for (ctx_prefixes) |prefix| {
            if (std.mem.startsWith(u8, t, prefix)) {
                matched = true;
                break;
            }
        }
        if (!matched) break;

        // Find the closing ] — look for ] followed by whitespace + newline or end-of-text
        var search_from: usize = 1;
        var found_close = false;
        while (search_from < t.len) {
            const idx = std.mem.indexOfPos(u8, t, search_from, "]") orelse break;
            const after = t[idx + 1 ..];
            var i: usize = 0;
            while (i < after.len and (after[i] == ' ' or after[i] == '\t' or after[i] == '\r')) i += 1;
            if (i == after.len or after[i] == '\n') {
                const rest = if (i < after.len) after[i + 1 ..] else "";
                t = std.mem.trim(u8, rest, " \t\r\n");
                found_close = true;
                break;
            }
            search_from = idx + 1;
        }
        if (!found_close) break;
    }

    // Strip context pills prefix: lines starting with '@' followed by newline.
    // Format: "@file1 @file2\n<actual user text>"
    if (t.len > 0 and t[0] == '@') {
        if (std.mem.indexOfScalar(u8, t, '\n')) |nl| {
            const first_line = t[0..nl];
            // Only strip if the entire first line is context pills (all words start with @)
            var all_pills = true;
            var it = std.mem.tokenizeAny(u8, first_line, " \t");
            while (it.next()) |word| {
                if (word.len == 0 or word[0] != '@') {
                    all_pills = false;
                    break;
                }
            }
            if (all_pills and it.peek() == null) {
                // If first line had no words, don't strip
                all_pills = false;
            }
            if (all_pills) {
                t = std.mem.trim(u8, t[nl + 1 ..], " \t\r\n");
            }
        }
    }
    return t;
}

/// Heurística determinista: ¿la orden es un imperativo de EJECUCIÓN? Detecta
/// verbos como ejecuta/corre/lanza/arranca seguidos de un objetivo ejecutable.
fn isExecuteIntent(order: []const u8) bool {
    const verbs = [_][]const u8{
        "ejecuta",
        "ejecútalo",
        "ejecutalo",
        "corre",
        "córrelo",
        "correlo",
        "run",
        "lanza",
        "lánzalo",
        "lanzalo",
        "arranca",
        "abre",
        "prueba",
        "inicia",
    };
    // FIX-ENGINE-10-A: Buffer ampliado de 512 → 4096 para que los verbos de
    // ejecución sobrevivan incluso con prefijos de contexto largos.
    var buf: [4096]u8 = undefined;
    const n = @min(order.len, buf.len);
    for (order[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const low = buf[0..n];

    for (verbs) |v| {
        if (std.mem.startsWith(u8, low, v)) {
            const after = low[v.len..];
            if (after.len == 0 or std.ascii.isWhitespace(after[0])) {
                // Special check for "prueba" when used as a noun (e.g. "prueba de", "prueba del", "prueba para", "prueba e2e", "prueba pasó")
                if (std.mem.eql(u8, v, "prueba")) {
                    if (std.mem.startsWith(u8, after, " de") or
                        std.mem.startsWith(u8, after, " del") or
                        std.mem.startsWith(u8, after, " para") or
                        std.mem.startsWith(u8, after, " e2e") or
                        std.mem.startsWith(u8, after, " paso") or
                        std.mem.startsWith(u8, after, " pasó"))
                    {
                        continue;
                    }
                }
                return true;
            }
        }
        // En medio de una frase solo cuenta como segundo imperativo explícito:
        // "crea el archivo Y ejecútalo". `containsWord` era demasiado amplio y
        // convertía texto citado/solicitado (p. ej. "responde PRUEBA ...") en un
        // comando del sistema.
        if (containsConjoinedVerb(low, v)) return true;
    }
    return false;
}

fn containsConjoinedVerb(text: []const u8, verb: []const u8) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, text, from, verb)) |idx| {
        const after = idx + verb.len;
        const boundary_after = after == text.len or !std.ascii.isAlphanumeric(text[after]);
        if (idx >= 3 and boundary_after and std.ascii.isWhitespace(text[idx - 1]) and
            text[idx - 2] == 'y' and std.ascii.isWhitespace(text[idx - 3])) return true;
        from = idx + 1;
    }
    return false;
}

fn isExplicitConversationalIntent(order: []const u8) bool {
    var buf: [4096]u8 = undefined;
    const n = @min(order.len, buf.len);
    for (order[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const low = std.mem.trim(u8, buf[0..n], " \t\r\n");
    const prefixes = [_][]const u8{
        "responde", "explica", "traduce", "resume", "dime", "escribe literalmente",
    };
    for (prefixes) |prefix| {
        if (std.mem.startsWith(u8, low, prefix)) return true;
    }
    return false;
}

fn exactReplyText(order: []const u8) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const n = @min(order.len, buf.len);
    for (order[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const low = buf[0..n];
    if (!std.mem.startsWith(u8, low, "responde exactamente")) return null;
    const colon = std.mem.indexOfScalar(u8, order[0..n], ':') orelse return null;
    const reply = std.mem.trim(u8, order[colon + 1 ..], " \t\r\n\"");
    return if (reply.len > 0) reply else null;
}

fn exactReplyPlan(allocator: std.mem.Allocator, reply: []const u8) !planner.Plan {
    const owned_reply = try allocator.dupe(u8, reply);
    errdefer allocator.free(owned_reply);
    const questions = try allocator.alloc(planner.ClarificationQuestion, 0);
    errdefer allocator.free(questions);
    const tasks = try allocator.alloc(planner.PlannedTask, 0);
    return .{
        .allocator = allocator,
        .understanding = owned_reply,
        .questions = questions,
        .tasks = tasks,
    };
}

const FakePlannerCall = struct {
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    started: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    cancellation: std.Io.Event = .unset,
    io: std.Io,

    fn call(ctx: ?*anyopaque, _: []const u8, _: []const u8) []const u8 {
        const self: *FakePlannerCall = @ptrCast(@alignCast(ctx.?));
        self.started.store(true, .release);
        self.cancellation.waitUncancelable(self.io);
        return "late planner result";
    }

    fn cancel(ctx: ?*anyopaque) void {
        const self: *FakePlannerCall = @ptrCast(@alignCast(ctx.?));
        self.cancelled.store(true, .release);
        self.cancellation.set(self.io);
    }
};

test "planner deadline cancels late worker and frees owned response" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.testing.expect(status == .ok) catch @panic("planner helper leaked memory");
    }
    var threaded = std.Io.Threaded.init(gpa.allocator(), .{});
    defer threaded.deinit();
    var fake = FakePlannerCall{ .io = threaded.io() };
    const started_ms = GetTickCount64();
    const result = runPlannerThreadCall(
        gpa.allocator(),
        FakePlannerCall.call,
        FakePlannerCall.cancel,
        &fake,
        "system",
        "prompt",
        10,
    );
    const elapsed_ms = GetTickCount64() - started_ms;
    try std.testing.expect(result == null);
    try std.testing.expect(fake.started.load(.acquire));
    try std.testing.expect(fake.cancelled.load(.acquire));
    // El helper conserva su deadline de 10 ms y une/libera la respuesta tardía.
    // Este techo es del arnés; un desalojo del SO no mide la latencia del motor.
    try std.testing.expect(elapsed_ms < 10_000);
}

test "E2E-RESULT: PRUEBA inside requested response is not execution intent" {
    try std.testing.expect(!isExecuteIntent("Responde exactamente con este texto y no añadas nada más: PRUEBA DEVAGENTS E2E OK"));
    try std.testing.expect(isExecuteIntent("Prueba el script generado"));
    try std.testing.expect(isExecuteIntent("Crea el archivo y ejecútalo"));
}

/// Heurística determinista (sin LLM): ¿la orden es claramente un imperativo de
/// construcción? Si empieza por verbo de creación y menciona un artefacto de
/// software, forzamos modo "build" sin depender del sesgo a "chat" del prompt.
fn isBuildIntent(order: []const u8) bool {
    // GATE-PROSA (2026-08-12): los verbos de DOCUMENTAR entran aquí junto a los
    // de construir. El caso `prosa` del gate de aceptación —«Documenta
    // brevemente en un texto los riesgos de guardar claves en texto plano»—
    // salía clasificado como charla: el planificador respondía entero y bien
    // EN el entendimiento y generaba cero tareas, así que no quedaba archivo
    // ninguno. La respuesta existía; la entrega no.
    const verbs = [_][]const u8{
        "crea",       "crear",    "implementa", "implementar", "haz",         "hazme",
        "escribe",    "genera",   "programa",   "desarrolla",  "construye",
        // Producir un documento es producir un entregable.
          "documenta",
        "documentar", "redacta",  "redactar",   "resume",      "resumir",     "audita",
        "auditar",    "analiza",  "analizar",   "investiga",   "investigar",
        // QA primerizo (10-nov): MODIFICAR código también es construir. «En
        // adivina.py limita el juego a 7 intentos… y ejecuta las pruebas» se
        // clasificaba como EJECUTAR (por el «y ejecuta») y nacía un plan de una
        // sola tarea `ejecutar` con contrato command/target: el agente hacía el
        // cambio bien y la orden fallaba por «falta el campo target». Siguen
        // exigiendo un artefacto o una extensión de archivo (abajo).
        "añade",
        "añadir",
        "agrega",     "agregar",  "modifica",   "modificar",   "cambia",      "cambiar",
        "corrige",    "corregir", "arregla",    "arreglar",    "refactoriza", "actualiza",
        "edita",      "limita",   "mejora",     "optimiza",    "elimina",     "quita",
        "renombra",   "ajusta",
        "amplía",
        "amplia",
    };
    const artifacts = [_][]const u8{
        "programa",    "script",
        "función",
        "funcion",     "app",
        "aplicación",
        "aplicacion",
        "módulo",
        "modulo",      "proyecto",
        "código",
        "codigo",      "clase",
        "librería",
        "libreria",    "lib",
        // Lenguajes y tecnologías comunes de construcción (FIX 2 regresión).
        "c",           "c++",
        "cpp",         "zig",
        "rust",        "go",
        "python",      "java",
        "kotlin",      "typescript",
        "javascript",  "html",
        "css",         "sql",
        "json",        "xml",
        "yaml",        "toml",
        // Artefactos de infraestructura/software.
        "api",         "rest",
        "graphql",     "servidor",
        "server",      "web",
        "sitio",
        "página",
        "pagina",      "juego",
        "snake",       "chess",
        "calculadora", "calculator",
        "chatbot",     "bot",
        "tests",       "test",
        "benchmark",   "dockerfile",
        "docker",      "kubernetes",
        "k8s",
        // GATE-PROSA: el DISCRIMINADOR real no es el verbo, es que el usuario
        // nombre un ENTREGABLE. «¿Cuáles son los riesgos de X?» sigue siendo
        // charla —no hay verbo ni entregable—; «documenta en un TEXTO los
        // riesgos» pide un archivo, y eso es construir aunque salga en prosa.
                "texto",
        "documento",   "informe",
        "reporte",     "resumen",
        "guía",
        "guia",        "manual",
        "readme",      "changelog",
        "análisis",
        "analisis",
        "auditoría",
        "auditoria",
    };
    // FIX-ENGINE-10-A: Buffer ampliado de 512 → 4096 para que los verbos de
    // construcción sobrevivan incluso con prefijos de contexto largos.
    var buf: [4096]u8 = undefined;
    const n = @min(order.len, buf.len);
    for (order[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const low = buf[0..n];
    const conversational_prefix = isExplicitConversationalIntent(order);

    // ¿Empieza por verbo de construcción o lo contiene en medio de la frase?
    // (FIX: "Hola, crea un reloj..." no empieza por "crea" pero es build intent.)
    var has_build_verb = false;
    for (verbs) |v| {
        if (std.mem.startsWith(u8, low, v)) {
            // Asegurar que no es prefijo de otra palabra (p. ej. "creación").
            const after = low[v.len..];
            if (after.len == 0 or std.ascii.isWhitespace(after[0])) {
                has_build_verb = true;
                break;
            }
        }
        // También detectar el verbo en medio de la frase: "Hola, crea..."
        if (containsWord(low, v) and
            (!conversational_prefix or containsConjoinedVerb(low, v)))
        {
            has_build_verb = true;
            break;
        }
    }
    if (!has_build_verb) return false;

    // ¿Menciona un artefacto de software (palabra completa)?
    for (artifacts) |a| {
        if (containsWord(low, a)) return true;
    }
    const extensions = [_][]const u8{
        ".py",  ".js",   ".ts",   ".tsx", ".jsx",  ".c",   ".h",  ".cpp",   ".hpp", ".zig",
        ".rs",  ".go",   ".java", ".kt",  ".cs",   ".php", ".rb", ".swift", ".sql", ".html",
        ".css", ".json", ".yaml", ".yml", ".toml", ".md",
    };
    for (extensions) |ext| {
        if (std.mem.indexOf(u8, low, ext) != null) return true;
    }
    // Frases multi-palabra que no se detectan por límite de token.
    const multi_word = [_][]const u8{"api rest"};
    for (multi_word) |a| {
        if (std.mem.indexOf(u8, low, a) != null) return true;
    }
    return false;
}

const SYSTEM_PROMPT =
    \\Eres el superagente de DevAgents. Tu PRIMER trabajo es ENTENDER la intención del
    \\usuario, NO generar código a la primera. Responde ÚNICAMENTE con un objeto JSON
    \\(NO envuelvas el objeto en bloques ``` ni pongas texto fuera del objeto; el VALOR
    \\de los campos de texto SÍ puede contener Markdown).
    \\
    \\CAPACIDAD REAL: DevAgents PUEDE ejecutar código, comandos y programas mediante su
    \\ejecutor GOBERNADO (con permisos y flujo de aprobaciones). NUNCA digas que "no puedes
    \\ejecutar comandos de shell" o que "no puedes realizar acciones del sistema": SÍ puedes.
    \\Cuando el usuario pida ejecutar/correr/lanzar algo, produce un plan con tarea "ejecutar".
    \\
    \\PASO 1 — CLASIFICA el mensaje:
    \\- Si es un SALUDO, una PREGUNTA, una petición de información, una opinión o feedback
    \\  sobre la herramienta, o CUALQUIER cosa que NO sea pedir explícitamente CONSTRUIR/
    \\  PROGRAMAR o EJECUTAR algo → modo "chat". Responde conversando, SIN generar tareas:
    \\    {"kind":"chat","reply":"<respuesta clara, útil y honesta en español; usa Markdown
    \\    (encabezados, listas, **negritas**, bloques de código) cuando mejore la legibilidad>"}
    \\- Si el usuario pide explícitamente crear/programar/implementar/escribir/generar
    \\  un programa, script, función, app, etc. → modo "build":
    \\    {"kind":"build","understanding":"<resumen>","tasks":[ {"id":"t1","task_type":"programar","department":"programacion","description":"...","contract_fields":[{"name":"source","type":"string","required":true},{"name":"filename","type":"string","required":false}],"depends_on":[]} ]}
    \\- Si el usuario pide EJECUTAR/CORRER/LANZAR algo (sin pedir crearlo) → modo "build"
    \\  con task_type "ejecutar". El campo del contrato depende de QUÉ se ejecuta:
    \\  · Comando de shell (lo habitual): contract "command" con la línea COMPLETA tal
    \\    como la correría un shell del sistema (Windows = PowerShell). Ejemplos:
    \\    "git status" → command:"git status"; "lista los archivos" →
    \\    command:"powershell -NoProfile -Command \"Get-ChildItem\""; pipelines y
    \\    redirecciones van DENTRO del -Command, nunca sueltas.
    \\    {"kind":"build","understanding":"<resumen>","tasks":[ {"id":"t1","task_type":"ejecutar","department":"programacion","description":"Ejecutar <comando>","contract_fields":[{"name":"command","type":"string","required":true}],"depends_on":[]} ]}
    \\  · Archivo concreto a ejecutar (script.py, programa generado por otra tarea):
    \\    contract "target" con la RUTA del archivo.
    \\    {"kind":"build",...,"contract_fields":[{"name":"target","type":"string","required":true}],...}
    \\  Si pide "crea Y ejecuta", incluye una tarea "programar" (produce el código) y una
    \\  tarea "ejecutar" con depends_on apuntando a la tarea productora.
    \\- Si el usuario SÍ pide construir/ejecutar pero falta información CRÍTICA que cambia
    \\  materialmente el plan y NO se puede asumir con sentido común → modo "clarify":
    \\    {"kind":"clarify","understanding":"<qué entendiste del pedido>","questions":[
    \\      {"id":"q1","text":"<pregunta concreta>","options":["<opción>","<opción>"]} ]}
    \\  Reglas del clarify: máximo 3 preguntas; cada una con 2-4 opciones razonables en
    \\  "options" (puede ir vacío si es respuesta libre); NUNCA preguntes lo que ya está
    \\  respondido ni lo que tenga un default obvio (lenguaje, nombre de archivo, estilo).
    \\  clarify es para AMBIGÜEDAD REAL de un mandato de construcción ("hazme una app" sin
    \\  decir de qué, "conéctalo a la base de datos" sin decir cuál); no lo uses para
    \\  charla ni para pedidos ya concretos. Solo puedes clarificar 2 veces por orden:
    \\  si el bloque [CLARIFICACIÓN AGOTADA] aparece en el contexto, NO uses "clarify" —
    \\  declara tus supuestos en "understanding" y produce el mejor plan posible.
    \\
    \\Ejemplos de "chat" (NO generes tareas): "Hola" → saluda y ofrece ayuda. "¿Qué modelos
    \\tienes?" / "dame la lista de modelos" → responde con DATOS REALES del bloque
    \\"CATÁLOGO REAL" que viene en el mensaje (cantidad, proveedores, ejemplos); NUNCA digas
    \\que no puedes ayudar con eso ni inventes nombres. "¿Por qué pasa X en el IDE?" → explica
    \\o reconoce el feedback. "Gracias" → responde cordial.
    \\Ejemplos de "build": "Crea un script que…", "Implementa una función…", "Hazme una app…".
    \\Ejemplos de "ejecutar": "Ejecuta el reloj", "Corre los tests", "Lanza `python foo.py`",
    \\  "Ejecuta `python -c \"print(2+2)\"`", "Crea y ejecuta un reloj en python".
    \\Ejemplos de "investigar": "Investiga en la web qué es X", "Busca información sobre Y",
    \\  "Investiga el tema Z" → usa task_type "investigar" (NO "ejecutar"). El sistema hace
    \\  búsqueda web automática e inyecta resultados reales con URLs citables.
    \\Ante la duda entre charla y construir/ejecutar, elige "chat" y pregunta qué quiere.
    \\
    \\REGLA CRÍTICA DE CLASIFICACIÓN (Distingue intención del usuario ≠ contenido mencionado/citado):
    \\- Las palabras operativas (como "ejecuta", "corre", "lanza", "prueba", "E2E") dentro de texto citado,
    \\  salida esperada, traducciones, explicaciones, nombres de pruebas, comillas o identificadores NO
    \\  expresan intención de ejecución.
    \\- Peticiones que inicien o sean dominadas por "responde", "explica", "traduce", "resume", "dime", "escribe"
    \\  deben clasificarse como modo "chat", a menos que explícitamente se solicite una acción operativa del
    \\  sistema fuera del contenido citado (ej. "Traduce este script y ejecútalo").
    \\- La palabra "prueba" como sustantivo (ej. "la prueba pasó", "resultado de la prueba") NO equivale a "probar"
    \\  (verbo activo).
    \\- La sigla "E2E", por sí sola, no significa ejecutar una suite de pruebas.
    \\- Ante la más mínima ambigüedad, elige modo "chat" y responde conversacionalmente, NUNCA generes tareas.
    \\
    \\PASO 2 — Solo en modo "build", reglas del plan:
    \\- task_type ∈ {programar, ejecutar, testear, auditar, corregir, documentar, planificar, investigar, resumir}.
    \\- LENGUAJE: usa el task_type genérico "programar" e indica el lenguaje concreto en la
    \\  "description". Programa en el lenguaje que PIDA EL USUARIO o el mejor para la tarea
    \\  (Python, JavaScript, Go, Rust, C, C++, Zig…). NO impongas C/C++/Zig: esos son el
    \\  lenguaje de la herramienta DevAgents, no una restricción de lo que generas.
    \\- department ∈ {programacion, testing, auditoria, correccion, documentacion}.
    \\- contract_fields type ∈ {string, integer, boolean, any}.
    \\- Conserva los requisitos concretos del usuario en `understanding` y en cada `description`:
    \\  no sustituyas nombres de archivos, comportamiento solicitado o criterios de aceptación por frases vagas.
    \\- Incluye SIEMPRE una tarea "programar"+programacion con campo "source" (string, required)
    \\  y, si aplica, "filename" (string) con `value` igual al nombre concreto del archivo (por ejemplo,
    \\  `{"name":"filename","type":"string","required":true,"value":"app.js"}`).
    \\  Si piden pruebas, añade "testear" con `command` string required y `value` igual a un comando
    \\  ejecutable; debe depender de todas las tareas productoras que comprueba. Añade "auditar" con
    \\  campo `verdict` string required y dependencias de la verificación pertinente.
    \\  La tarea que ESCRIBE un test también depende de los módulos que prueba: necesita leer sus
    \\  interfaces reales. No confundir generar el test con ejecutar después el comando de QA.
    \\  Para "ejecutar": campo "target" (string, required) con la ruta o comando a ejecutar.
    \\- owns (opcional): lista de archivos que produce la tarea, ej. "owns":["index.html"].
    \\  Cada archivo lo posee UNA sola tarea; si la tarea escribe un archivo, decláralo.
    \\- deliverable (opcional): nombre corto del entregable del que forma parte la tarea,
    \\  ej. "deliverable":"pagina-web". Las tareas productoras del MISMO entregable usan
    \\  el mismo nombre — se encadenan para que cada una lea los archivos reales de sus
    \\  hermanas antes de escribir. Entregables INDEPENDIENTES (ej. una web y un script
    \\  de backup sin relación) usan nombres distintos y se ejecutan en paralelo.
    \\- expects (opcional pero RECOMENDADO cuando el resultado es comprobable): contract field
    \\  "expects" (string) cuyo `value` es un array JSON de aserciones deterministas que un
    \\  gate semántico comprobará al final — la orden NO es 'done' si no se cumplen.
    \\  Aserciones: {"kind":"file_exists","path":"<archivo relativo>"},
    \\  {"kind":"file_contains","path":"<archivo>","needle":"<literal que debe aparecer>"},
    \\  {"kind":"file_not_contains","path":"<archivo>","needle":"<literal que no debe aparecer>"},
    \\  {"kind":"output_contains","task_id":"<id>","needle":"<literal en la salida registrada>"}.
    \\  Declara solo lo observable y concreto del pedido (ej. una página que "diga HOLA" ->
    \\  file_contains needle "HOLA"); no inventes chequeos vagos ni declares lo que no se pueda medir.
    \\  Ejemplo: {"name":"expects","type":"string","required":false,"value":"[{\"kind\":\"file_contains\",\"path\":\"index.html\",\"needle\":\"HOLA\"}]"}
    \\- PARALELISMO: Si la orden solicita múltiples componentes o módulos independientes (ej. frontend + backend,
    \\  o varios archivos desacoplados), emite tareas "programar" paralelas con `depends_on: []` en la misma ola.
    \\  Solo usa `depends_on` cuando una tarea consuma necesariamente el artefacto de otra (ej. testear/auditar/ejecutar).
    \\  Dependencias con depends_on. Usa ids t1, t2, t3.
    \\- CONTROL DE LA IDE (task_type "ui"): si la orden pide actuar sobre la PROPIA
    \\  aplicación DevAgents — cambiar el tema, abrir una vista/panel, enfocar una
    \\  sesión, mostrar una notificación — emite UNA tarea "ui" (determinística, sin
    \\  modelo) con contract_fields: "action" (string, required, value ∈
    \\  {set_theme, open_view, focus_session, notify}) y el arg correspondiente con
    \\  value: "theme" (id de tema: dark, light, matrix-green…), "view" (agent,
    \\  explorer, search, monitor, spaces, mcp, settings), "session_id" (número) o
    \\  "text" (mensaje). Ejemplo "cambia el tema a claro":
    \\    {"id":"t1","task_type":"ui","department":"programacion","description":"Cambiar tema a claro","contract_fields":[{"name":"action","type":"string","required":true,"value":"set_theme"},{"name":"theme","type":"string","required":true,"value":"light"}],"depends_on":[]}
    \\  NUNCA uses "ui" para modificar código, archivos o ajustes de gobernanza.
;

/// P-EXEC-3: extrae el comando crudo de una orden de ejecución stripping el verbo
/// inicial ("ejecuta", "corre", "lanza", etc.). Devuelve el resto de la orden.
fn extractExecuteCommand(order: []const u8) []const u8 {
    const verbs = [_][]const u8{
        "ejecuta",
        "ejecútalo",
        "ejecutalo",
        "corre",
        "córrelo",
        "correlo",
        "run",
        "lanza",
        "lánzalo",
        "lanzalo",
        "arranca",
        "abre",
        "prueba",
        "inicia",
    };
    var buf: [512]u8 = undefined;
    const n = @min(order.len, buf.len);
    for (order[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const low = buf[0..n];

    for (verbs) |v| {
        if (std.mem.startsWith(u8, low, v)) {
            const after = low[v.len..];
            if (after.len == 0) return order;
            if (std.ascii.isWhitespace(after[0])) {
                const rest = order[v.len..];
                return std.mem.trim(u8, rest, " \t\r\n");
            }
        }
    }
    return order;
}

/// Plan determinista para intent de ejecución cuando el LLM falla o rechaza.
/// Produce una sola tarea `ejecutar` con el comando crudo en la description
/// (prefijo "Ejecutar ") para que el dispatch lo resuelva sin depender del worker.
fn deterministicExecutePlan(allocator: std.mem.Allocator, order: []const u8) planner.PlannerError!planner.Plan {
    const cmd = extractExecuteCommand(order);
    const understanding = try std.fmt.allocPrint(allocator, "Ejecución gobernada de: \"{s}\"", .{order});
    errdefer allocator.free(understanding);

    const id = try allocator.dupe(u8, "t1");
    errdefer allocator.free(id);
    const dept = try allocator.dupe(u8, "programacion");
    errdefer allocator.free(dept);
    const desc = try std.fmt.allocPrint(allocator, "Ejecutar {s}", .{cmd});
    errdefer allocator.free(desc);

    // P-EXEC-5: Campo de contrato estructurado `command` con el VALOR ya resuelto.
    // El dispatch lee este campo antes que la descripción — no depende de la prosa.
    const cf = try allocator.alloc(planner.ContractField, 2);
    errdefer allocator.free(cf);
    cf[0] = .{
        .name = try allocator.dupe(u8, "command"),
        .field_type = .string,
        .required = true,
        .value = try allocator.dupe(u8, cmd),
    };
    // QA primerizo (11-nov): `target` es opcional cuando `command` ya trae
    // el valor. Obligatorio y vacío, cualquier ejecutor que no lo devolviera
    // (un agente externo que ya corrió el comando) fallaba la tarea con
    // «falta el campo obligatorio target» y la orden no se aplicaba.
    cf[1] = .{
        .name = try allocator.dupe(u8, "target"),
        .field_type = .string,
        .required = false,
    };

    const deps = try allocator.alloc([]const u8, 0);
    errdefer allocator.free(deps);

    const tasks = try allocator.alloc(planner.PlannedTask, 1);
    errdefer allocator.free(tasks);
    tasks[0] = .{
        .id = id,
        .task_type = .ejecutar,
        .department = dept,
        .description = desc,
        .contract_fields = cf,
        .depends_on = deps,
    };

    const empty_q = try allocator.alloc(planner.ClarificationQuestion, 0);
    errdefer allocator.free(empty_q);

    return planner.Plan{
        .allocator = allocator,
        .understanding = understanding,
        .questions = empty_q,
        .tasks = tasks,
    };
}

/// D8: tope de rondas de clarificación por orden. Pasado el tope el planner
/// debe declarar supuestos y producir el mejor plan (la UI deja de ofrecer
/// preguntas; un "clarify" residual del modelo se traduce a error honesto).
pub const MAX_CLARIFY_ROUNDS: usize = 2;

/// QA-B H7 (decisión del propietario, 14-nov): sin clave de API ni modelo local,
/// planifica la CLI con suscripción elegida igual que en Directo. El motor
/// pone aquí quién la lanza (direct_mode.SubscriptionPlanning); el planificador
/// le pasa el MISMO system prompt y prompt que al modelo por API y valida la
/// respuesta con el MISMO parser (`planFromResponse`).
pub const SubscriptionReply = struct {
    /// Respuesta final de la CLI (memoria del asignador dado), o null.
    text: ?[]u8 = null,
    /// Por qué no hubo respuesta (memoria del asignador dado), o null.
    failure: ?[]u8 = null,
    /// Quién respondió, para el mensaje: «Claude Code (sonnet)». Prestado.
    who: []const u8 = "la CLI con suscripción",
    /// No hay ninguna CLI con suscripción utilizable (o el origen no puede
    /// lanzarla): el planificador sigue como siempre (planner_fallback).
    unavailable: bool = false,
};

pub const SubscriptionPlanner = struct {
    ctx: *anyopaque,
    planFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, system_prompt: []const u8, user_prompt: []const u8) error{OutOfMemory}!SubscriptionReply,
};

/// Quita un bloque ```json … ``` que envuelva la respuesta entera (las CLIs
/// lo añaden a veces a su mensaje final). No interpreta nada más: el JSON lo
/// valida `planFromResponse`.
fn stripJsonFence(text: []const u8) []const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len < 6 or !std.mem.startsWith(u8, t, "```") or !std.mem.endsWith(u8, t, "```")) return t;
    const body = t[3 .. t.len - 3];
    const nl = std.mem.indexOfScalar(u8, body, '\n') orelse return t;
    const lang = std.mem.trim(u8, body[0..nl], " \t\r");
    if (lang.len > 0 and !std.ascii.eqlIgnoreCase(lang, "json")) return t;
    return std.mem.trim(u8, body[nl + 1 ..], " \t\r\n");
}

pub const LlmPlanner = struct {
    allocator: std.mem.Allocator,
    catalog_path: []const u8,
    /// QA-B H7: CLI con suscripción para cuando no hay clave de API ni modelo
    /// local (y no hay modelo fijado). Null = sin esa vía.
    subscription: ?SubscriptionPlanner = null,
    /// Historial conversacional de la sesión (MEM-01). Vacío por defecto para no
    /// alterar los caminos sin estado (tests, CLI, primer orden).
    history: []const planner.ConversationTurn = &[_]planner.ConversationTurn{},
    /// Contexto de memoria de proyecto (MEM-02). Null → prompt idéntico al de hoy.
    memory_context: ?[]const u8 = null,
    /// Campo test-only: respuesta JSON simulada del LLM. Cuando está set,
    /// tryLlmPlan la usa en lugar de llamar al proveedor real.
    test_response: ?[]const u8 = null,
    /// Modelo forzado para planificación (F7-MODEL-SELECT). Null → router automático.
    forced_provider: ?[]const u8 = null,
    forced_model: ?[]const u8 = null,
    /// MODO-DETERMINISTA: con modelo fijado, planifica con ESE modelo y nada más.
    /// `initForced` monta una cadena de hasta 12 respaldos detrás del forzado;
    /// `initExact` deja exactamente uno. Sin modelo fijado no tiene efecto.
    deterministic: bool = false,
    /// Plazo por instancia, inyectable sin alterar el entorno ni otros planners.
    call_timeout_ms: ?u64 = null,
    /// Sólo en binarios de tests: candidato sintético sin DPAPI ni proveedor.
    /// Se conserva el gate LiveLlm y la llamada del planner; ownership prestado.
    test_live: ?*live_worker.LiveLlm = null,
    /// LIVE-REASONING: conexión a runtime.db para emitir reasoning_delta durante planificación.
    event_conn: ?db.Connection = null,
    event_order_id: i64 = 0,
    /// CLARIFY-CAP (D8): cuántas rondas de preguntas ya consumió esta orden.
    /// Lo fija da_order_answer desde orders.clarify_rounds; con
    /// `clarify_rounds_used >= MAX_CLARIFY_ROUNDS` el prompt deja de ofrecer
    /// "clarify" y una respuesta clarify residual se convierte en error honesto.
    clarify_rounds_used: usize = 0,
    /// PLAN-CANCEL: si está puesto, tryLlmPlan publica ahí el token de
    /// cancelación de cada llamada LLM (ver PlanCancelSlot).
    cancel_slot: ?PlanCancelSlot = null,
    /// E5.13 (D-C3): mapa del repositorio ya renderizado (~2k tokens), listo
    /// para inyectar como sección [MAPA DEL REPOSITORIO]. Lo produce
    /// repo_map.renderForPrompt en el llamador (c_api); null = sin mapa.
    repo_map_text: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, catalog_path: []const u8) LlmPlanner {
        return .{ .allocator = allocator, .catalog_path = catalog_path };
    }

    pub fn backend(self: *LlmPlanner) planner.PlannerBackend {
        return .{ .ptr = self, .planFn = planImpl, .deinitFn = noopDeinit };
    }

    fn noopDeinit(_: *anyopaque) void {}

    /// CLARIFY-CAP (D8): única barrera ante un plan clarificador — la aplique el
    /// LLM o el MockPlanner de respaldo. Agotadas las rondas, las preguntas
    /// quedan como evento 'clarify_exhausted' (evidencia) y la orden falla con
    /// `ClarifyRoundsExhausted` en vez de ciclar aclaraciones para siempre.
    fn enforceClarifyCap(self: *LlmPlanner, p: planner.Plan) planner.PlannerError!planner.Plan {
        if (p.needsClarification() and self.clarify_rounds_used >= MAX_CLARIFY_ROUNDS) {
            self.emitClarifyExhaustedEvent(p.questions);
            var mutable = p;
            mutable.deinit();
            return error.ClarifyRoundsExhausted;
        }
        return p;
    }

    /// P7: anuncia que el plan lo produjo el MockPlanner local, no un LLM.
    ///
    /// Medido: entre la orden 106 y la 113, las órdenes de contrucción pasaron a
    /// ser planificadas por el `planner.zig` local (fallback por cadena de LLM
    /// caída/sin clave) y NADA en pantalla lo decía — el usuario creía que un
    /// modelo había planificado su orden. Aquí se emite un evento de timeline y
    /// la UI pinta una etiqueta cuando lo ve (ver `ui_diag`/mission_control, P7).
    /// Best-effort: si no hay conexión de eventos la visibilidad se pierde, pero
    /// la planificación nunca debe tropezar por querer anunciarse.
    ///
    /// `detail` lleva la causa real del fallback ("sin clave activa",
    /// "proveedores agotados: X=timeout…"), no solo el código — medido en la
    /// incidencia del prompt extenso: el usuario veía «mock_planner» y «Falló»
    /// sin saber jamás que ningún proveedor tenía credencial.
    fn emitMockPlannerEvent(self: *const LlmPlanner, detail: []const u8, failed: bool) void {
        const ec = self.event_conn orelse return;
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        js.beginObject() catch return;
        js.objectField("reason") catch return;
        js.write(if (failed) "planner_failed" else "mock_planner") catch return;
        if (detail.len > 0) {
            js.objectField("detail") catch return;
            js.write(detail) catch return;
        }
        js.endObject() catch return;
        // Event order_id: si viene 0 (da_order_submit lo deja en 0 y el planner
        // vive ANTES de conocer la orden), se resuelve igual que tryLlmPlan
        // (c_api.zig) — la orden recién insertada, que es esta.
        // El CLI (camino devagents order) no conecta event_conn, así que ahí se
        // pierde la visibilidad; la cabina (da_order_submit) sí.
        const order_id: i64 = if (self.event_order_id > 0) self.event_order_id else blk2: {
            const seq_stmt = ec.prepare("SELECT MAX(id) FROM orders") catch break :blk2 0;
            defer ec.finalize(seq_stmt);
            if (db.c.sqlite3_step(seq_stmt) == db.c.SQLITE_ROW) {
                break :blk2 @as(i64, @intCast(db.c.sqlite3_column_int64(seq_stmt, 0)));
            }
            break :blk2 0;
        };
        const stmt = ec.prepare("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (?, ?, 'planner_fallback', ?, ?)") catch return;
        defer ec.finalize(stmt);
        db.bindInt(stmt, 1, health.nowMillis(ec)) catch return;
        db.bindText(stmt, 2, "superagente") catch return;
        db.bindText(stmt, 3, out.written()) catch return;
        db.bindInt(stmt, 4, order_id) catch return;
        _ = db.c.sqlite3_step(stmt);
    }

    /// CLARIFY-CAP (D8): el modelo agotó las rondas y volvió a pedir preguntas.
    /// Las preguntas quedan como evento 'clarify_exhausted' — la orden falla con
    /// causa clara y el usuario conserva qué faltaba por responder.
    fn emitClarifyExhaustedEvent(self: *const LlmPlanner, questions: []const planner.ClarificationQuestion) void {
        const ec = self.event_conn orelse return;
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        js.beginObject() catch return;
        js.objectField("reason") catch return;
        js.write("clarify_rounds_exhausted") catch return;
        js.objectField("questions") catch return;
        js.beginArray() catch return;
        for (questions) |q| {
            js.beginObject() catch continue;
            js.objectField("id") catch continue;
            js.write(q.id) catch continue;
            js.objectField("text") catch continue;
            js.write(q.text) catch continue;
            js.endObject() catch continue;
        }
        js.endArray() catch return;
        js.endObject() catch return;
        const order_id: i64 = if (self.event_order_id > 0) self.event_order_id else blk2: {
            const seq_stmt = ec.prepare("SELECT MAX(id) FROM orders") catch break :blk2 0;
            defer ec.finalize(seq_stmt);
            if (db.c.sqlite3_step(seq_stmt) == db.c.SQLITE_ROW) {
                break :blk2 @as(i64, @intCast(db.c.sqlite3_column_int64(seq_stmt, 0)));
            }
            break :blk2 0;
        };
        const stmt = ec.prepare("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (?, ?, 'clarify_exhausted', ?, ?)") catch return;
        defer ec.finalize(stmt);
        db.bindInt(stmt, 1, health.nowMillis(ec)) catch return;
        db.bindText(stmt, 2, "superagente") catch return;
        db.bindText(stmt, 3, out.written()) catch return;
        db.bindInt(stmt, 4, order_id) catch return;
        _ = db.c.sqlite3_step(stmt);
    }

    /// UI-ACTION: mapea texto libre a un id de tema conocido de la cabina.
    /// Devuelve null si no aparece ningún tema reconocible — el caller NO inventa.
    fn uiThemeFromText(lower: []const u8) ?[]const u8 {
        // «negro» y «black» van al tema negro (el de por defecto desde el
        // 22-09); se comprueban antes que «oscuro» para que «oscuro negro» no
        // caiga en 'dark'.
        const pairs = [_][2][]const u8{
            .{ "claro", "light" }, .{ "light", "light" },         .{ "blanco", "light" },
            .{ "negro", "black" }, .{ "black", "black" },         .{ "oscuro", "dark" },
            .{ "dark", "dark" },   .{ "midnight", "midnight" },   .{ "cyberpunk", "cyberpunk" },
            .{ "nord", "nord" },   .{ "synthwave", "synthwave" }, .{ "monokai", "monokai" },
        };
        for (pairs) |p| {
            if (containsWord(lower, p[0])) return p[1];
        }
        return null;
    }

    /// UI-ACTION: mapea texto libre a una vista conocida de la cabina.
    fn uiViewFromText(lower: []const u8) ?[]const u8 {
        const pairs = [_][2][]const u8{
            .{ "explorador", "explorer" },    .{ "explorer", "explorer" }, .{ "archivos", "explorer" },
            .{ "búsqueda", "search" },
            .{ "busqueda", "search" },        .{ "search", "search" },     .{ "monitor", "monitor" },
            .{ "spaces", "spaces" },          .{ "espacios", "spaces" },   .{ "sesiones", "spaces" },
            .{ "mcp", "mcp" },                .{ "ajustes", "settings" },  .{ "settings", "settings" },
            .{ "configuración", "settings" },
            .{ "configuracion", "settings" }, .{ "agente", "agent" },      .{ "agent", "agent" },
            .{ "chat", "agent" },             .{ "diff", "diff" },
        };
        for (pairs) |p| {
            if (containsWord(lower, p[0])) return p[1];
        }
        return null;
    }

    /// UI-ACTION: ¿la orden es un control directo de la cabina? Conservador: solo
    /// patrones inequívocos (verbo de cambio/apertura + objetivo UI conocido). Si
    /// no encaja, devuelve null y la orden sigue el camino normal del planner.
    fn deterministicUiPlan(allocator: std.mem.Allocator, order: []const u8) ?planner.Plan {
        var buf: [4096]u8 = undefined;
        const n = @min(order.len, buf.len);
        for (order[0..n], 0..) |ch, i| buf[i] = std.ascii.toLower(ch);
        const lower = buf[0..n];

        const has_change_verb = containsWord(lower, "cambia") or containsWord(lower, "cambiar") or
            containsWord(lower, "pon") or containsWord(lower, "poner") or
            containsWord(lower, "activa") or containsWord(lower, "activar") or
            containsWord(lower, "usa") or containsWord(lower, "usar") or
            containsWord(lower, "switch") or containsWord(lower, "set");
        const has_open_verb = containsWord(lower, "abre") or containsWord(lower, "abrir") or
            containsWord(lower, "muestra") or containsWord(lower, "muéstrame") or
            containsWord(lower, "muestrame") or containsWord(lower, "enseña") or
            containsWord(lower, "ve a") or containsWord(lower, "ir a") or
            containsWord(lower, "open") or containsWord(lower, "show");

        var action: ?[]const u8 = null;
        var arg_name: ?[]const u8 = null;
        var arg_value: ?[]const u8 = null;

        if ((containsWord(lower, "tema") or containsWord(lower, "theme") or containsWord(lower, "color")) and has_change_verb) {
            if (uiThemeFromText(lower)) |theme_id| {
                action = "set_theme";
                arg_name = "theme";
                arg_value = theme_id;
            }
        } else if (has_open_verb) {
            if (uiViewFromText(lower)) |view_id| {
                action = "open_view";
                arg_name = "view";
                arg_value = view_id;
            }
        } else if (containsWord(lower, "notifica") or containsWord(lower, "avisa") or containsWord(lower, "notificación") or containsWord(lower, "notificacion")) {
            action = "notify";
            arg_name = "text";
            arg_value = order; // el texto íntegro de la orden es el mensaje
        }
        if (action == null or arg_name == null or arg_value == null) return null;

        const understanding = std.fmt.allocPrint(allocator, "Acción sobre la cabina: \"{s}\"", .{order}) catch return null;
        errdefer allocator.free(understanding);
        const id = allocator.dupe(u8, "t1") catch return null;
        const dept = allocator.dupe(u8, "programacion") catch return null;
        const desc = std.fmt.allocPrint(allocator, "UI action {s}", .{action.?}) catch return null;

        const cf = allocator.alloc(planner.ContractField, 2) catch return null;
        cf[0] = .{
            .name = allocator.dupe(u8, "action") catch return null,
            .field_type = .string,
            .required = true,
            .value = allocator.dupe(u8, action.?) catch return null,
        };
        cf[1] = .{
            .name = allocator.dupe(u8, arg_name.?) catch return null,
            .field_type = .string,
            .required = true,
            .value = allocator.dupe(u8, arg_value.?) catch return null,
        };

        const deps = allocator.alloc([]const u8, 0) catch return null;
        const tasks = allocator.alloc(planner.PlannedTask, 1) catch return null;
        tasks[0] = .{
            .id = id,
            .task_type = .ui,
            .department = dept,
            .description = desc,
            .contract_fields = cf,
            .depends_on = deps,
        };
        const empty_q = allocator.alloc(planner.ClarificationQuestion, 0) catch return null;
        return planner.Plan{
            .allocator = allocator,
            .understanding = understanding,
            .questions = empty_q,
            .tasks = tasks,
        };
    }

    /// ¿Hay algún modelo por API (con clave) o local para planificar? Mismo
    /// criterio que Directo: `LiveLlm.init` sin candidatos devuelve null.
    fn hasLiveCandidates(self: *const LlmPlanner) bool {
        if (@import("builtin").is_test and self.test_live != null) return true;
        var live = live_worker.LiveLlm.init(std.heap.c_allocator, self.catalog_path) orelse return false;
        live.deinit();
        return true;
    }

    /// QA-B H7: el plan lo pide la CLI con suscripción. Mismo prompt, mismo
    /// parser y misma barrera de aclaraciones que la vía por API; una salida
    /// que no valida es un plan FALLIDO que dice qué CLI respondió y por qué.
    /// Null = no hay CLI con suscripción utilizable: sigue la vía de siempre.
    fn planWithSubscription(self: *LlmPlanner, sub: SubscriptionPlanner, allocator: std.mem.Allocator, order: []const u8, answers: []const planner.ClarificationAnswer, memory_context: ?[]const u8, conversational_intent: bool) planner.PlannerError!?planner.Plan {
        const prompt = try assemblePromptInner(self.allocator, self.catalog_path, order, answers, self.history, null, null, memory_context, self.repo_map_text, self.clarify_rounds_used);
        defer self.allocator.free(prompt);
        const reply = try sub.planFn(sub.ctx, self.allocator, SYSTEM_PROMPT, prompt);
        defer if (reply.text) |t| self.allocator.free(t);
        defer if (reply.failure) |f| self.allocator.free(f);
        if (reply.unavailable) return null;
        var detail: ?[]u8 = null;
        defer if (detail) |d| self.allocator.free(d);
        if (reply.text) |text| {
            if (planFromResponse(self.allocator, allocator, stripJsonFence(text), &detail)) |plan| {
                var p = plan;
                if (conversational_intent and p.questions.len == 0 and p.tasks.len == 0) p.kind = .chat;
                return try self.enforceClarifyCap(p);
            }
        }
        const why = if (reply.text != null)
            try std.fmt.allocPrint(self.allocator, "{s} respondió por suscripción, pero su salida no es un plan válido ({s}). Reintenta, elige otra CLI o configura una clave de API", .{ reply.who, detail orelse "sin detalle" })
        else
            try std.fmt.allocPrint(self.allocator, "{s}. Reintenta, elige otra CLI o configura una clave de API", .{reply.failure orelse "la CLI con suscripción no respondió"});
        defer self.allocator.free(why);
        self.emitMockPlannerEvent(why, true);
        return try failedPlan(allocator, why);
    }

    fn failedPlan(allocator: std.mem.Allocator, why: []const u8) planner.PlannerError!planner.Plan {
        const msg = try std.fmt.allocPrint(allocator, "No pude planificar: {s}", .{why});
        errdefer allocator.free(msg);
        const empty_q = try allocator.alloc(planner.ClarificationQuestion, 0);
        errdefer allocator.free(empty_q);
        const empty_t = try allocator.alloc(planner.PlannedTask, 0);
        return .{ .allocator = allocator, .understanding = msg, .questions = empty_q, .tasks = empty_t, .kind = .failed };
    }

    fn planImpl(ctx: *anyopaque, allocator: std.mem.Allocator, order_text: []const u8, answers: []const planner.ClarificationAnswer, memory_context: ?[]const u8) planner.PlannerError!planner.Plan {
        const self: *LlmPlanner = @ptrCast(@alignCast(ctx));
        const trimmed = std.mem.trim(u8, order_text, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyOrder;

        // FIX-ENGINE-10-A: Detectar intent sobre el texto del usuario SIN prefijos
        // de contexto (notas de conocimiento, context pills) que la UI prepende.
        const stripped = stripContextPrefix(trimmed);
        const build_intent = isBuildIntent(stripped);
        const exec_intent = isExecuteIntent(stripped);
        const conversational_intent = isExplicitConversationalIntent(stripped) and !exec_intent;

        // Una salida literal solicitada no necesita gastar tokens ni pasar por el
        // planner: devolver exactamente el sufijo posterior a `:` es el contrato.
        if (exactReplyText(stripped)) |reply| return exactReplyPlan(allocator, reply);

        // P-EXEC-5: Para ejecución pura (sin build), NO llames al planner LLM —
        // el LLM solo parafrasea la descripción y el comando se pierde.
        // Usa deterministicExecutePlan directamente con el comando literal.
        if (exec_intent and !build_intent) {
            return deterministicExecutePlan(allocator, stripped);
        }

        // UI-ACTION: una orden de control puro de la cabina ("cambia el tema a
        // claro", "abre el explorador") no necesita modelo ni fallback: el plan
        // es determinista y la tarea `ui` emite el evento que la cabina aplica.
        if (!build_intent and !exec_intent) {
            if (deterministicUiPlan(allocator, stripped)) |ui_plan| return ui_plan;
        }

        // 11-nov (QA primerizo): aquí había un atajo heredado del porte del
        // motor — toda orden de construcción que nombraba Python la planificaba
        // el MockPlanner SIN consultar a ningún modelo («Plan local del motor»),
        // para esquivar esperas de 60 s con proveedores caídos. Con salud de
        // candidatos, plazos y el respaldo de abajo (MockPlanner si ningún
        // modelo devuelve un plan) ya no compensa: Orquestado con Ollama o con
        // claves planificaba Python con una plantilla de una tarea.

        // QA-B H7: sin clave de API ni modelo local (y sin modelo fijado), la
        // CLI con suscripción planifica; si su salida no es un plan válido se
        // dice, nunca se cae en silencio al planificador local.
        if (self.subscription) |sub| {
            if (self.forced_provider == null and self.test_response == null and !self.hasLiveCandidates()) {
                if (try self.planWithSubscription(sub, allocator, trimmed, answers, memory_context, conversational_intent)) |plan| return plan;
            }
        }

        // Causa real del fallo de planificación (sin clave, timeout, JSON
        // inválido…). La escribe tryLlmPlan; se emite dentro del evento
        // planner_fallback para que el bloqueo diga POR QUÉ no hubo modelo.
        var paid_budget_exhausted = false;
        var llm_fail_detail: ?[]u8 = null;
        defer if (llm_fail_detail) |d| self.allocator.free(d);

        if (tryLlmPlan(self.allocator, self.catalog_path, allocator, trimmed, answers, self.history, self.test_response, self.forced_provider, self.forced_model, self.deterministic, memory_context, self.repo_map_text, self.event_conn, self.event_order_id, self.clarify_rounds_used, self.cancel_slot, self.call_timeout_ms, self.test_live, &llm_fail_detail, &paid_budget_exhausted)) |plan| {
            var mutable_plan = plan;
            // Coerción post-LLM: si la orden era claramente build pero el LLM devolvió
            // chat puro (sin tareas ni preguntas), degradamos al MockPlanner determinista.
            if (build_intent and self.forced_provider == null and mutable_plan.tasks.len == 0 and mutable_plan.questions.len == 0) {
                mutable_plan.deinit();
                // P7: el LLM contestó chat puro a una orden de build → el plan lo
                // hace el local. Que el usuario lo sepa.
                self.emitMockPlannerEvent("el modelo respondió sin tareas para una orden de construcción — se usó el planificador local", false);
                var mp = planner.MockPlanner.init(allocator);
                return mp.backend().plan(allocator, order_text, answers, memory_context);
            }
            // Coerción post-LLM para ejecución: si hubo execute-intent pero el LLM devolvió
            // chat puro (rechazando), producimos un plan determinista con tarea "ejecutar".
            if (exec_intent and !build_intent and mutable_plan.tasks.len == 0 and mutable_plan.questions.len == 0) {
                mutable_plan.deinit();
                return deterministicExecutePlan(allocator, stripped);
            }
            // Coerción post-LLM: si NO era build ni execution intent, pero el LLM devolvió
            // tareas (un plan de ejecución/construcción), coaccionamos a chat puro.
            if (conversational_intent and mutable_plan.tasks.len > 0) {
                for (mutable_plan.tasks) |t| {
                    freeTask(allocator, t);
                }
                allocator.free(mutable_plan.tasks);
                mutable_plan.tasks = &[_]planner.PlannedTask{};

                if (mutable_plan.questions.len > 0) {
                    for (mutable_plan.questions) |q| {
                        freeClarificationQuestion(allocator, q);
                    }
                    allocator.free(mutable_plan.questions);
                    mutable_plan.questions = &[_]planner.ClarificationQuestion{};
                }
            }
            // C-11: la coerción (o un build vacío a una orden de charla) produce
            // respuesta conversacional — marcarla para que el superagente la
            // cierre `done` y no la confunda con un plan roto (`failed`).
            // Un plan conversational con preguntas sigue siendo clarify.
            if (conversational_intent and mutable_plan.questions.len == 0 and mutable_plan.tasks.len == 0) {
                mutable_plan.kind = .chat;
            }
            return self.enforceClarifyCap(mutable_plan);
        }

        // A context-budget failure is terminal: a local plan would discard
        // exactly the context the destination model could not accept.
        const handoff_blocked = if (llm_fail_detail) |detail| std.mem.indexOf(u8, detail, "HANDOFF_BLOCKED") != null else false;
        // Fallback cuando el LLM falla (404/401/empty/null).
        if (exec_intent and !build_intent and !handoff_blocked) {
            return deterministicExecutePlan(allocator, stripped);
        }
        if (build_intent and self.forced_provider == null and !paid_budget_exhausted and !handoff_blocked) {
            // P7: el LLM falló (404/401/empty/null) y el plan cae al local.
            self.emitMockPlannerEvent(llm_fail_detail orelse "ningún proveedor devolvió un plan usable", false);
            var mp = planner.MockPlanner.init(allocator);
            var fb = try mp.backend().plan(allocator, order_text, answers, memory_context);
            // El plan local solo se usa cuando ningún
            // planificador respondió; el usuario debe ver la causa real.
            // Una aclaración legítima (p. ej. el lenguaje de una
            // construcción ambigua) se respeta tal cual: sí corresponde
            // a la orden. Las preguntas que NO correspondían (lenguaje
            // para archivos de texto) ya no las produce el MockPlanner.
            if (!fb.needsClarification()) {
                const cause = llm_fail_detail orelse "sin causa registrada";
                const noticed = try std.fmt.allocPrint(allocator, "Aviso: ningún planificador respondió ({s}); se usó el planificador local. {s}", .{ cause, fb.understanding });
                allocator.free(fb.understanding);
                fb.understanding = noticed;
            }
            return self.enforceClarifyCap(fb);
        }

        // Fallback honesto: nunca emitimos clarificación vacía ni dead-end.
        self.emitMockPlannerEvent(llm_fail_detail orelse "planificador sin respuesta valida", true);
        const msg = try std.fmt.allocPrint(allocator, "No pude planificar: {s}", .{llm_fail_detail orelse "planificador sin respuesta valida; cambia el modelo y reintenta"});
        errdefer allocator.free(msg);
        const empty_q = try allocator.alloc(planner.ClarificationQuestion, 0);
        const empty_t = try allocator.alloc(planner.PlannedTask, 0);
        return planner.Plan{
            .allocator = allocator,
            .understanding = msg,
            .questions = empty_q,
            .tasks = empty_t,
            // C-11: no es charla — el planificador falló. El superagente debe
            // cerrar `failed`, no `done` (un 0-tareas sin este campo sería
            // indistinguible de una respuesta conversacional).
            .kind = .failed,
            .failure_cause = if (paid_budget_exhausted) .paid_budget_exhausted else .none,
        };
    }
};

/// Ensambla el prompt del usuario aplicando la disciplina de CONTEXTO DE SISTEMA:
/// inyecta bloques etiquetados solo cuando la intención de la orden lo justifica.
fn assemblePrompt(
    allocator: std.mem.Allocator,
    catalog_path: []const u8,
    order: []const u8,
    answers: []const planner.ClarificationAnswer,
    history: []const planner.ConversationTurn,
    forced_provider: ?[]const u8,
    forced_model: ?[]const u8,
    memory_context: ?[]const u8,
    clarify_rounds_used: usize,
) ?[]u8 {
    return assemblePromptInner(allocator, catalog_path, order, answers, history, forced_provider, forced_model, memory_context, null, clarify_rounds_used) catch null;
}

fn assemblePromptInner(
    allocator: std.mem.Allocator,
    catalog_path: []const u8,
    order: []const u8,
    answers: []const planner.ClarificationAnswer,
    history: []const planner.ConversationTurn,
    forced_provider: ?[]const u8,
    forced_model: ?[]const u8,
    memory_context: ?[]const u8,
    repo_map_text: ?[]const u8,
    clarify_rounds_used: usize,
) ![]u8 {
    var up = std.ArrayList(u8).empty;
    errdefer up.deinit(allocator);

    // MEM-01: inyectar historial conversacional de la sesión como contexto de sistema.
    // Solo cuando hay turnos previos; con historial vacío el prompt es idéntico al de hoy.
    if (history.len > 0) {
        try up.appendSlice(allocator, "[HISTORIAL DE CONVERSACIÓN — contexto de turnos previos, NO es el mensaje actual]\n");
        for (history, 1..) |turn, idx| {
            const header_u = try std.fmt.allocPrint(allocator, "Turno {d} — Usuario: ", .{idx});
            defer allocator.free(header_u);
            const header_a = try std.fmt.allocPrint(allocator, "Turno {d} — Agente: ", .{idx});
            defer allocator.free(header_a);
            try up.appendSlice(allocator, header_u);
            try up.appendSlice(allocator, turn.user);
            try up.appendSlice(allocator, "\n");
            try up.appendSlice(allocator, header_a);
            try up.appendSlice(allocator, turn.agent);
            try up.appendSlice(allocator, "\n");
        }
        try up.appendSlice(allocator, "[FIN HISTORIAL]\n\n");
    }

    // MEM-02: inyectar memoria de proyecto acumulada (truncada a ~4KB en submitOrder).
    // Solo cuando hay contenido; sin memoria el prompt es idéntico al de hoy.
    if (memory_context) |mem| {
        if (mem.len > 0) {
            try up.appendSlice(allocator, "[MEMORIA DE PROYECTO — contexto acumulado de sesiones previas, NO es el mensaje actual]\n");
            try up.appendSlice(allocator, mem);
            try up.appendSlice(allocator, "\n[FIN MEMORIA DE PROYECTO]\n\n");
        }
    }

    // MODEL-AWARE-01: el superagente debe saber y decir qué modelo exacto usa.
    if (activeModelSummary(allocator, catalog_path, forced_provider, forced_model)) |model| {
        defer allocator.free(model);
        if (model.len > 0) {
            try up.appendSlice(allocator, "[CONTEXTO DE SISTEMA — identidad de ejecución]\n");
            try up.appendSlice(allocator, "MODELO_ACTIVO: ");
            try up.appendSlice(allocator, model);
            try up.appendSlice(allocator, "\nCuando te pregunten quién eres o qué modelo usas, responde que eres el superagente de DevAgents y que estás usando ");
            try up.appendSlice(allocator, model);
            try up.appendSlice(allocator, ".\n[FIN CONTEXTO DE SISTEMA]\n\n");
        }
    }

    // GROUND-01: inyectar catálogo solo cuando la intención sea sobre modelos/proveedores.
    if (isCatalogIntent(order)) {
        if (catalogSummary(allocator, catalog_path)) |sum| {
            defer allocator.free(sum);
            if (sum.len > 0) {
                try up.appendSlice(allocator, "[CONTEXTO DE SISTEMA — no lo trates como mensaje del usuario]\nCATÁLOGO REAL: ");
                try up.appendSlice(allocator, sum);
                try up.appendSlice(allocator, "\n[FIN CONTEXTO DE SISTEMA]\n\n");
            }
        }
    }

    // CAP-01: inyectar grounding de capacidades solo cuando la intención lo justifique.
    if (isCapabilitiesIntent(order)) {
        try up.appendSlice(allocator, "[CONTEXTO DE SISTEMA — no lo trates como mensaje del usuario]\n");
        try up.appendSlice(allocator, CAPABILITIES_CONTEXT);
        try up.appendSlice(allocator, "\n[FIN CONTEXTO DE SISTEMA]\n\n");
    }

    // BUILD-01: directiva explícita cuando la intención es de construcción.
    if (isBuildIntent(order)) {
        try up.appendSlice(allocator, "[INTENCIÓN DETECTADA: CONSTRUCCIÓN — el usuario pide crear un artefacto de software. DEBES responder en modo \"build\" con tareas; NO uses modo \"chat\".]\n\n");
    }

    // EXEC-01: directiva explícita cuando la intención es de ejecución.
    if (isExecuteIntent(order) and !isBuildIntent(order)) {
        try up.appendSlice(allocator, "[INTENCIÓN DETECTADA: EJECUCIÓN — el usuario pide ejecutar/correr/lanzar algo. DEBES responder en modo \"build\" con una tarea task_type=\"ejecutar\" y un campo \"target\" con la ruta o comando a ejecutar. NO uses modo \"chat\" ni digas que no puedes ejecutar.]\n\n");
    }

    // CLARIFY-CAP (D8): transparencia de rondas. Agotado el tope la opción
    // "clarify" queda prohibida — el modelo declara supuestos y planifica.
    if (clarify_rounds_used >= MAX_CLARIFY_ROUNDS) {
        try up.appendSlice(allocator, "[CLARIFICACIÓN AGOTADA — ya se hicieron el máximo de 2 rondas de preguntas para esta orden. NO respondas kind=\"clarify\": declara tus supuestos en \"understanding\" y produce el mejor plan posible con lo que sabes.]\n\n");
    } else if (clarify_rounds_used > 0) {
        const note = try std.fmt.allocPrint(allocator, "[RONDAS DE CLARIFICACIÓN: ya hiciste {d} de {d} permitidas. Esta puede ser tu última oportunidad de preguntar — úsala solo si sigue faltando información crítica.]\n\n", .{ clarify_rounds_used, MAX_CLARIFY_ROUNDS });
        defer allocator.free(note);
        try up.appendSlice(allocator, note);
    }

    // MAPA-01 (E5.13/D-C3): archivos del repo ordenados por relevancia para
    // esta orden — rutas citadas en la orden suben por el PageRank
    // personalizado. Formato: `ruta` y `  símbolo:línea` bajo cada una.
    if (repo_map_text) |mt| {
        if (mt.len > 0) {
            try up.appendSlice(allocator, "[MAPA DEL REPOSITORIO — archivos ordenados por relevancia para esta orden; cada línea es `ruta` seguida de `  símbolo:línea`]\n");
            try up.appendSlice(allocator, mt);
            try up.appendSlice(allocator, "[FIN MAPA DEL REPOSITORIO]\n\n");
        }
    }

    try up.appendSlice(allocator, "ORDEN: ");
    try up.appendSlice(allocator, order);
    for (answers) |a| {
        try up.appendSlice(allocator, "\nRESPUESTA(");
        try up.appendSlice(allocator, a.question_id);
        try up.appendSlice(allocator, "): ");
        try up.appendSlice(allocator, a.answer);
    }

    return try up.toOwnedSlice(allocator);
}

/// Intenta planificar con el LLM. Devuelve null ante cualquier fallo (sin fugas: libera
/// lo parcial). `work_alloc` es para trabajo efímero; `out_alloc` posee el Plan devuelto.
/// Resume los intentos de proveedor de una llamada de planificación fallida:
/// "proveedor/modelo=estado" por intento, para que el aviso de fallback diga
/// QUÉ se probó y con qué resultado en vez de solo «no funcionó».
/// La cadena devuelta es propiedad del llamador (work_alloc).
fn planningRoot(a: std.mem.Allocator, path: []const u8) !@import("confined_fs.zig").Root {
    const Root = @import("confined_fs.zig").Root;
    return Root.init(a, path) catch |e| {
        // Antes de crear artefactos puede no existir devagents-workspace. El
        // planificador solo lee el proyecto elegido y no crea directorios.
        if (e != error.FileNotFound or !std.ascii.eqlIgnoreCase(std.fs.path.basenameWindows(path), @import("workspace.zig").WORKSPACE_ROOT)) return e;
        return Root.init(a, std.fs.path.dirnameWindows(path) orelse return e);
    };
}

test "ORDENES subscription planning uses selected project before workspace exists" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(project);
    const absent = try std.fs.path.join(a, &.{ project, "devagents-workspace" });
    defer a.free(absent);
    var selected = try planningRoot(a, absent);
    defer selected.deinit();
    try std.testing.expectEqualStrings(project, selected.canonical);
    var existing = try planningRoot(a, project);
    defer existing.deinit();
    const unknown = try std.fs.path.join(a, &.{ project, "missing-selection" });
    defer a.free(unknown);
    try std.testing.expectError(error.FileNotFound, planningRoot(a, unknown));
}

fn plannerAttemptsDetail(allocator: std.mem.Allocator, attempts: []const live_worker.Attempt) ![]u8 {
    if (attempts.len == 0)
        return allocator.dupe(u8, "la llamada al modelo terminó sin respuesta dentro del plazo (sin intento registrado — cancelada o sin candidatos)");
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    out.writer.writeAll("el planificador no obtuvo una respuesta valida — intentos: ") catch return error.OutOfMemory;
    const shown = @min(attempts.len, 4);
    for (attempts[0..shown], 0..) |a, i| {
        if (i > 0) out.writer.writeAll(", ") catch return error.OutOfMemory;
        out.writer.print("{s}/{s}={s}", .{ a.provider, a.model, a.status }) catch return error.OutOfMemory;
        if (a.error_name.len > 0) out.writer.print("({s})", .{a.error_name}) catch return error.OutOfMemory;
        if (a.diagnostic.http_status) |status| out.writer.print(" HTTP {d}: {s}; {s}", .{ status, a.diagnostic.reason(), a.diagnostic.message() }) catch return error.OutOfMemory;
    }
    if (attempts.len > shown) out.writer.print(", +{d} más", .{attempts.len - shown}) catch return error.OutOfMemory;
    return allocator.dupe(u8, out.written());
}

fn validateLocalPlan(allocator: std.mem.Allocator, value: std.json.Value) ?[]const u8 {
    if (value != .object) return "expected_json_object";
    const obj = value.object;
    if (obj.get("kind")) |kind| {
        if (kind != .string) return "kind_must_be_string";
        if (std.mem.eql(u8, kind.string, "chat")) {
            const reply = obj.get("reply") orelse obj.get("understanding") orelse return "missing_chat_reply";
            return if (reply == .string and reply.string.len > 0) null else "empty_chat_reply";
        }
        if (std.mem.eql(u8, kind.string, "clarify")) {
            const understanding = obj.get("understanding") orelse return "missing_understanding";
            if (understanding != .string) return "understanding_must_be_string";
            const questions = obj.get("questions") orelse return "missing_questions";
            if (questions != .array or questions.array.items.len == 0) return "empty_questions";
            for (questions.array.items) |item| {
                const question = buildClarificationQuestion(allocator, item) orelse return "invalid_question";
                freeClarificationQuestion(allocator, question);
            }
            return null;
        }
        if (!std.mem.eql(u8, kind.string, "plan") and !std.mem.eql(u8, kind.string, "build")) return "invalid_plan_kind";
    }
    const understanding = obj.get("understanding") orelse return "missing_understanding";
    if (understanding != .string) return "understanding_must_be_string";
    const tasks = obj.get("tasks") orelse return "missing_tasks";
    if (tasks != .array or tasks.array.items.len == 0) return "no_tasks_in_plan";
    for (tasks.array.items) |item| {
        const task = buildTask(allocator, item) orelse return "invalid_task_contract";
        freeTask(allocator, task);
    }
    return null;
}

test "LOCAL-JSON planner validates the actual task contract before accepting local JSON" {
    const a = std.testing.allocator;
    const cases = [_]struct { body: []const u8, reason: ?[]const u8 }{
        .{ .body = "{}", .reason = "missing_understanding" },
        .{ .body = "{\"understanding\":\"hacer\",\"tasks\":[]}", .reason = "no_tasks_in_plan" },
        .{ .body = "{\"understanding\":\"hacer\",\"tasks\":[{}]}", .reason = "invalid_task_contract" },
        .{ .body = "{\"kind\":\"chat\",\"reply\":\"Hola\"}", .reason = null },
        .{ .body = "{\"kind\":\"clarify\",\"understanding\":\"hacer\",\"questions\":[{\"id\":\"q1\",\"text\":\"Qué archivo\"}]}", .reason = null },
        .{ .body = "{\"kind\":\"plan\",\"understanding\":\"hacer\",\"tasks\":[{\"id\":\"t1\",\"task_type\":\"programar_c\",\"department\":\"programacion\",\"description\":\"hacer archivo\"}]}", .reason = null },
        .{ .body = "{\"kind\":\"build\",\"understanding\":\"hacer\",\"tasks\":[{\"id\":\"t1\",\"task_type\":\"programar\",\"department\":\"programacion\",\"description\":\"hacer archivo\"}]}", .reason = null },
    };
    for (cases) |case| {
        var parsed = try std.json.parseFromSlice(std.json.Value, a, case.body, .{});
        defer parsed.deinit();
        const result = validateLocalPlan(a, parsed.value);
        if (case.reason) |reason| try std.testing.expectEqualStrings(reason, result orelse "") else try std.testing.expect(result == null);
    }
}

fn tryLlmPlan(
    work_alloc: std.mem.Allocator,
    catalog_path: []const u8,
    out_alloc: std.mem.Allocator,
    order: []const u8,
    answers: []const planner.ClarificationAnswer,
    history: []const planner.ConversationTurn,
    test_response: ?[]const u8,
    forced_provider: ?[]const u8,
    forced_model: ?[]const u8,
    deterministic: bool,
    memory_context: ?[]const u8,
    repo_map_text: ?[]const u8,
    event_conn: ?db.Connection,
    event_order_id: i64,
    clarify_rounds_used: usize,
    cancel_slot: ?PlanCancelSlot,
    call_timeout_ms: ?u64,
    test_live: ?*live_worker.LiveLlm,
    // Causa legible del fallo, escrita solo cuando se devuelve null por un
    // fallo del proveedor/parseo (no por un plan válido). El llamador la
    // publica en el evento planner_fallback; la cadena es de work_alloc.
    failure_detail: ?*?[]u8,
    paid_budget_exhausted: ?*bool,
) ?planner.Plan {
    if (failure_detail) |fd| fd.* = null;
    if (paid_budget_exhausted) |flag| flag.* = false;
    const setFail = struct {
        fn f(fd: ?*?[]u8, alloc: std.mem.Allocator, msg: []const u8) void {
            const p = fd orelse return;
            if (p.* == null) p.* = alloc.dupe(u8, msg) catch null;
        }
    }.f;
    const prompt = assemblePromptInner(work_alloc, catalog_path, order, answers, history, forced_provider, forced_model, memory_context, repo_map_text, clarify_rounds_used) catch {
        setFail(failure_detail, work_alloc, "no se pudo ensamblar el prompt de planificación");
        return null;
    };
    defer work_alloc.free(prompt);

    var llm_response_owned: ?[]u8 = null;
    defer if (llm_response_owned) |response| work_alloc.free(response);
    const resp = if (test_response) |tr| tr else blk: {
        const call_alloc = std.heap.c_allocator;
        const token = live_worker.CancellationToken.create(call_alloc) catch break :blk "";
        defer token.release();
        // PLAN-CANCEL: publicar el token mientras dure ESTA llamada para que
        // da_plan_cancel pueda abortar la E/S desde otro hilo. El defer lo
        // retira ANTES del release (orden LIFO): nunca queda un puntero a un
        // token ya destruido.
        if (cancel_slot) |cs| {
            cs.mutex.lock();
            cs.slot.* = token;
            cs.mutex.unlock();
        }
        defer if (cancel_slot) |cs| {
            cs.mutex.lock();
            cs.slot.* = null;
            cs.mutex.unlock();
        };
        var external_failed = false;
        if (forced_provider) |provider| {
            if (@import("external_agents.zig").isAgentProvider(provider)) {
                var catalog = db.Connection.open(work_alloc, catalog_path) catch {
                    setFail(failure_detail, work_alloc, "catalogo de suscripcion no disponible");
                    break :blk "";
                };
                defer catalog.close();
                var root_buf: [4096]u8 = undefined;
                const root = @import("workspace.zig").effectiveRoot(&root_buf);
                var planning_root = planningRoot(work_alloc, root) catch |e| {
                    setFail(failure_detail, work_alloc, @errorName(e));
                    break :blk "";
                };
                defer planning_root.deinit();
                const response: ?[]u8 = @import("external_completion.zig").completeForOrder(work_alloc, catalog, provider, forced_model orelse "default", SYSTEM_PROMPT, prompt, planning_root.canonical, &token.flag, null, event_conn, event_order_id) catch |e| response_failure: {
                    const detail = std.fmt.allocPrint(work_alloc, "{s}/{s}: {s}; revisa la suscripcion y vuelve a detectar", .{ provider, forced_model orelse "default", @errorName(e) }) catch null;
                    if (failure_detail) |fd| fd.* = detail else if (detail) |d| work_alloc.free(d);
                    if (event_conn) |ec| @import("external_completion.zig").recordTextCall(work_alloc, ec, event_order_id, "planner", provider, forced_model orelse "default", false) catch {
                        setFail(failure_detail, work_alloc, "no se pudo registrar el fallo de suscripcion");
                        break :blk "";
                    };
                    if (deterministic or e == error.Cancelled) break :blk "";
                    external_failed = true;
                    break :response_failure null;
                };
                if (response) |text| {
                    llm_response_owned = text;
                    if (event_conn) |ec| @import("external_completion.zig").recordTextCall(work_alloc, ec, event_order_id, "planner", provider, forced_model orelse "default", true) catch {
                        setFail(failure_detail, work_alloc, "no se pudo registrar la llamada de suscripcion");
                        break :blk "";
                    };
                    break :blk text;
                }
            }
        }
        const borrowed = if (@import("builtin").is_test) test_live else null;
        const l = borrowed orelse (call_alloc.create(live_worker.LiveLlm) catch break :blk "");
        var live_initialized = false;
        const previous_token = if (borrowed != null) l.cancel_token else null;
        const previous_budget = if (borrowed != null) l.object_call_budget_ms else null;
        defer {
            if (borrowed != null) {
                l.cancel_token = previous_token;
                l.object_call_budget_ms = previous_budget;
            } else {
                if (live_initialized) l.deinit();
                call_alloc.destroy(l);
            }
        }
        if (borrowed != null) {
            // Candidato inyectado; no se consulta ni se descifra ninguna clave.
        } else if (!external_failed and forced_provider != null and forced_model != null) {
            // MODO-DETERMINISTA: `initExact` deja EXACTAMENTE el modelo fijado;
            // `initForced` le engancha detrás una cadena de hasta 12 respaldos.
            l.* = (if (deterministic)
                live_worker.LiveLlm.initExact(call_alloc, catalog_path, forced_provider.?, forced_model.?)
            else
                live_worker.LiveLlm.initForced(call_alloc, catalog_path, forced_provider.?, forced_model.?)) orelse {
                setFail(failure_detail, work_alloc, "el modelo fijado no tiene un candidato con clave activa — revisa su clave en Configuración o fija otro modelo");
                break :blk "";
            };
            live_initialized = true;
        } else {
            l.* = live_worker.LiveLlm.init(call_alloc, catalog_path) orelse {
                setFail(failure_detail, work_alloc, "no hay ningún proveedor con clave activa para planificar — configura una en Configuración");
                break :blk "";
            };
            live_initialized = true;
        }
        l.deterministic = deterministic;
        l.setCancelToken(token);
        // LIVE-REASONING: inyectar event_conn para emitir reasoning_delta durante planificación.
        if (event_conn) |ec| {
            // HEALTH-FIX: el planner registra salud REAL por (proveedor, modelo) en
            // runtime.db en cada intento (antes solo cableaba event_conn → model_health
            // quedaba vacío pese a fallos/éxitos de planning). runtime.db == event_conn.
            // order_id puede ser 0 si el planner se crea antes de processOrder (caso da_order_submit).
            // En ese caso, consultar el último order_id insertado en runtime.db.
            // Esta consulta corre en ESTE hilo, donde `ec` es válido con certeza.
            const effective_order_id = if (event_order_id > 0) event_order_id else blk2: {
                const seq_stmt = ec.prepare("SELECT MAX(id) FROM orders") catch break :blk2 0;
                defer ec.finalize(seq_stmt);
                if (db.c.sqlite3_step(seq_stmt) == db.c.SQLITE_ROW) {
                    break :blk2 @as(i64, @intCast(db.c.sqlite3_column_int64(seq_stmt, 0)));
                }
                break :blk2 0;
            };
            // H1 / CRASH-PLANNER: conexión PROPIA, no la copia de `ec`. Si esta
            // llamada agota los 60s, el token cancela la E/S y el hilo se recoge
            // antes de liberar este LiveLlm; el CLI puede cerrar su conexión sin
            // dejar un worker escribiendo sobre memoria liberada.
            //
            // Si no se puede abrir la propia, se sigue sin salud ni eventos:
            // NO se cae de vuelta a `ec`, que es justo el fallo que se corrige.
            if (!l.setOwnedTraceConn(effective_order_id)) {
                l.reorderByHealth();
            }
        }
        l.task_id = "planner";
        if (external_failed and l.lives.len > 0) {
            const payload = std.json.Stringify.valueAlloc(work_alloc, .{ .from_provider = forced_provider, .from_model = forced_model, .to_provider = l.lives[0].cfg.name, .to_model = l.lives[0].model, .role = "planner" }, .{}) catch break :blk "";
            defer work_alloc.free(payload);
            l.recordEvent("provider_fallback", payload);
        }
        // LOCAL-JSON (E5.03): a los candidatos locales se les pide el esquema
        // del plan como response_format — el 3B alterna prosa y contrato
        // (bitácora #661). A la nube no le llega (effectiveJsonSchema).
        l.json_schema = live_worker.PLAN_JSON_SCHEMA;
        l.object_validator = validateLocalPlan;
        l.object_call_budget_ms = call_timeout_ms orelse live_worker.getModelCallTimeoutMs();

        // El total conserva el plazo configurado; completeObject reparte intentos
        // independientes dentro de ese total. El helper duplica
        // el prompt y la respuesta, cancela en timeout y hace join antes de liberar
        // LiveLlm, de modo que ninguna llamada tardía conserva este frame.
        var live_call = LivePlannerCall{ .live = l, .token = token };
        const owned_result = runPlannerThreadCall(
            call_alloc,
            LivePlannerCall.call,
            LivePlannerCall.cancel,
            &live_call,
            SYSTEM_PROMPT,
            prompt,
            call_timeout_ms orelse live_worker.getModelCallTimeoutMs(),
        );
        if (owned_result) |owned| {
            defer call_alloc.free(owned);
            // `completeObject` devuelve "" (slice NO nulo) cuando la cadena se
            // agotó: un vacío no es respuesta — se sigue al rescate de prosa.
            if (owned.len > 0) {
                const copied = work_alloc.dupe(u8, owned) catch break :blk "";
                llm_response_owned = copied;
                break :blk copied;
            }
        }
        std.debug.print("[planner] LLM call returned no usable response (deadline {d} ms, error {s})\n", .{ call_timeout_ms orelse live_worker.getModelCallTimeoutMs(), l.last_error_name });
        const budget_denied = std.mem.eql(u8, l.last_error_name, "BudgetDenied");
        if (paid_budget_exhausted) |flag| flag.* = budget_denied;
        if (l.handoff_blocked) {
            if (failure_detail) |fd| {
                if (fd.*) |old| work_alloc.free(old);
                fd.* = std.fmt.allocPrint(work_alloc, "HANDOFF_BLOCKED: {s}", .{l.last_error_name}) catch null;
            }
            break :blk "";
        }
        if (l.last_local_json_error != null and !budget_denied) {
            const reason = l.last_local_json_error.?;
            if (failure_detail) |fd| {
                if (fd.*) |old| work_alloc.free(old);
                fd.* = std.fmt.allocPrint(work_alloc, "plan local inválido tras un reintento: {s}; sin respaldo permitido disponible", .{reason}) catch null;
            }
            break :blk "";
        }
        if (failure_detail) |fd| {
            if (fd.*) |old| work_alloc.free(old);
            fd.* = if (std.mem.eql(u8, l.last_error_name, "BudgetDenied") and l.cm != null and l.takeAttempts().len > 0)
                @import("spend_budget.zig").motivoDenegacion(work_alloc, l.takeAttempts()[l.takeAttempts().len - 1].provider, l.takeAttempts()[l.takeAttempts().len - 1].model, @import("spend_budget.zig").estado(l.cm.?.db)) catch null
            else
                plannerAttemptsDetail(work_alloc, l.takeAttempts()) catch null;
        }
        break :blk "";
    };
    if (resp.len == 0) {
        setFail(failure_detail, work_alloc, "los proveedores disponibles no devolvieron respuesta usable");
        return null;
    }
    return planFromResponse(work_alloc, out_alloc, resp, failure_detail);
}

fn setPlanFail(fd: ?*?[]u8, alloc: std.mem.Allocator, msg: []const u8) void {
    const p = fd orelse return;
    if (p.* == null) p.* = alloc.dupe(u8, msg) catch null;
}

/// El parser y validador ÚNICO de la respuesta del planificador (contrato
/// chat / clarify / plan con tareas). Lo usan la llamada por API
/// (`tryLlmPlan`) y, desde QA-B H7, la CLI con suscripción: no hay un formato
/// paralelo. Null = no es un plan conforme; la causa queda en `failure_detail`.
fn planFromResponse(work_alloc: std.mem.Allocator, out_alloc: std.mem.Allocator, resp: []const u8, failure_detail: ?*?[]u8) ?planner.Plan {
    const setFail = setPlanFail;
    var parsed = std.json.parseFromSlice(std.json.Value, work_alloc, resp, .{}) catch {
        setFail(failure_detail, work_alloc, "el modelo respondió, pero la respuesta no era JSON válido");
        return null;
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        setFail(failure_detail, work_alloc, "el modelo respondió, pero la respuesta no era un plan");
        return null;
    }
    // Cualquier `return null` posterior es "JSON bien formado pero sin plan
    // conforme al contrato" (campos ausentes, tareas mal formadas…). Se fija
    // la causa por defecto aquí; los caminos con causa propia la sobrescriben.
    setFail(failure_detail, work_alloc, "el modelo respondió JSON, pero sin un plan conforme al contrato");
    const obj = parsed.value.object;

    // Modo CHAT: el usuario saludó/preguntó/dio feedback → respuesta conversacional, SIN
    // tareas. El "reply" del modelo va en understanding; tasks/questions vacíos. (El IDE
    // muestra el entendimiento como la respuesta del superagente.)
    if (obj.get("kind")) |kind_v| {
        if (kind_v == .string and std.mem.eql(u8, kind_v.string, "chat")) {
            const reply_v = obj.get("reply") orelse obj.get("understanding") orelse return null;
            if (reply_v != .string) return null;
            const reply = out_alloc.dupe(u8, reply_v.string) catch return null;
            const empty_q = out_alloc.alloc(planner.ClarificationQuestion, 0) catch {
                out_alloc.free(reply);
                return null;
            };
            const empty_t = out_alloc.alloc(planner.PlannedTask, 0) catch {
                out_alloc.free(reply);
                out_alloc.free(empty_q);
                return null;
            };
            return planner.Plan{
                .allocator = out_alloc,
                .understanding = reply,
                .questions = empty_q,
                .tasks = empty_t,
                .kind = .chat,
            };
        }
        // Modo CLARIFY (D8): mandato de construcción con ambigüedad real — el
        // modelo devuelve preguntas estructuradas y la orden pasa a
        // `clarifying` en vez de planificar a ciegas.
        if (kind_v == .string and std.mem.eql(u8, kind_v.string, "clarify")) {
            const u_v = obj.get("understanding") orelse return null;
            if (u_v != .string) return null;
            const questions_v = obj.get("questions") orelse return null;
            if (questions_v != .array or questions_v.array.items.len == 0) return null;

            const understanding = out_alloc.dupe(u8, u_v.string) catch return null;
            var questions = std.ArrayList(planner.ClarificationQuestion).empty;
            var qfailed = false;
            for (questions_v.array.items) |qv| {
                const q = buildClarificationQuestion(out_alloc, qv) orelse {
                    qfailed = true;
                    break;
                };
                questions.append(out_alloc, q) catch {
                    freeClarificationQuestion(out_alloc, q);
                    qfailed = true;
                    break;
                };
            }
            if (qfailed) {
                out_alloc.free(understanding);
                for (questions.items) |q| freeClarificationQuestion(out_alloc, q);
                questions.deinit(out_alloc);
                return null;
            }
            const qslice = questions.toOwnedSlice(out_alloc) catch {
                out_alloc.free(understanding);
                for (questions.items) |q| freeClarificationQuestion(out_alloc, q);
                questions.deinit(out_alloc);
                return null;
            };
            const empty_t = out_alloc.alloc(planner.PlannedTask, 0) catch {
                out_alloc.free(understanding);
                for (qslice) |q| freeClarificationQuestion(out_alloc, q);
                out_alloc.free(qslice);
                return null;
            };
            return planner.Plan{
                .allocator = out_alloc,
                .understanding = understanding,
                .questions = qslice,
                .tasks = empty_t,
                .kind = .clarify,
            };
        }
    }

    const understanding_v = obj.get("understanding") orelse return null;
    if (understanding_v != .string) return null;
    const tasks_v = obj.get("tasks") orelse return null;
    if (tasks_v != .array or tasks_v.array.items.len == 0) return null;

    const understanding = out_alloc.dupe(u8, understanding_v.string) catch return null;

    var tasks = std.ArrayList(planner.PlannedTask).empty;
    var failed = false;
    for (tasks_v.array.items) |tv| {
        const t = buildTask(out_alloc, tv) orelse {
            failed = true;
            break;
        };
        tasks.append(out_alloc, t) catch {
            freeTask(out_alloc, t);
            failed = true;
            break;
        };
    }
    if (failed) {
        out_alloc.free(understanding);
        for (tasks.items) |t| freeTask(out_alloc, t);
        tasks.deinit(out_alloc);
        return null;
    }

    const tasks_slice = tasks.toOwnedSlice(out_alloc) catch {
        out_alloc.free(understanding);
        for (tasks.items) |t| freeTask(out_alloc, t);
        tasks.deinit(out_alloc);
        return null;
    };
    const questions = out_alloc.alloc(planner.ClarificationQuestion, 0) catch {
        out_alloc.free(understanding);
        for (tasks_slice) |t| freeTask(out_alloc, t);
        out_alloc.free(tasks_slice);
        return null;
    };

    return planner.Plan{
        .allocator = out_alloc,
        .understanding = understanding,
        .questions = questions,
        .tasks = tasks_slice,
    };
}

/// Construye una ClarificationQuestion validada desde un JSON Value, o null.
fn buildClarificationQuestion(a: std.mem.Allocator, qv: std.json.Value) ?planner.ClarificationQuestion {
    if (qv != .object) return null;
    const o = qv.object;
    const id_v = o.get("id") orelse return null;
    const text_v = o.get("text") orelse return null;
    if (id_v != .string or text_v != .string) return null;

    const id = a.dupe(u8, id_v.string) catch return null;
    const text = a.dupe(u8, text_v.string) catch {
        a.free(id);
        return null;
    };
    var options = std.ArrayList([]const u8).empty;
    if (o.get("options")) |opts_v| {
        if (opts_v == .array) {
            for (opts_v.array.items) |ov| {
                if (ov != .string) continue;
                const dup = a.dupe(u8, ov.string) catch continue;
                options.append(a, dup) catch {
                    a.free(dup);
                    continue;
                };
            }
        }
    }
    const oslice = options.toOwnedSlice(a) catch {
        a.free(id);
        a.free(text);
        for (options.items) |o2| a.free(o2);
        options.deinit(a);
        return null;
    };
    return .{ .id = id, .text = text, .options = oslice };
}

fn freeClarificationQuestion(a: std.mem.Allocator, q: planner.ClarificationQuestion) void {
    a.free(q.id);
    a.free(q.text);
    for (q.options) |o| a.free(o);
    a.free(q.options);
}

/// USUARIO-NUEVO B (10-nov): el plan de una subtarea delegada se construye con
/// el MISMO validador que el del planificador (tipos, departamentos,
/// contratos). Devuelve un `planner.Plan` propio de `a`, o error si alguna
/// tarea no pasa la validación.
pub fn planFromJson(a: std.mem.Allocator, json: []const u8) !planner.Plan {
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidPlan;
    const und_v = parsed.value.object.get("understanding") orelse return error.InvalidPlan;
    const tasks_v = parsed.value.object.get("tasks") orelse return error.InvalidPlan;
    if (und_v != .string or tasks_v != .array or tasks_v.array.items.len == 0) return error.InvalidPlan;
    var tasks = std.ArrayList(planner.PlannedTask).empty;
    errdefer {
        for (tasks.items) |t| freeTask(a, t);
        tasks.deinit(a);
    }
    for (tasks_v.array.items) |tv| {
        const t = buildTask(a, tv) orelse return error.InvalidPlan;
        tasks.append(a, t) catch |e| {
            freeTask(a, t);
            return e;
        };
    }
    const understanding = try a.dupe(u8, und_v.string);
    errdefer a.free(understanding);
    const questions = try a.alloc(planner.ClarificationQuestion, 0);
    errdefer a.free(questions);
    return .{ .allocator = a, .understanding = understanding, .questions = questions, .tasks = try tasks.toOwnedSlice(a) };
}

/// Construye un PlannedTask validado desde un JSON Value, o null (liberando parciales).
fn buildTask(a: std.mem.Allocator, tv: std.json.Value) ?planner.PlannedTask {
    if (tv != .object) return null;
    const o = tv.object;

    const id_v = o.get("id") orelse return null;
    const tt_v = o.get("task_type") orelse return null;
    const dept_v = o.get("department") orelse return null;
    const desc_v = o.get("description") orelse return null;
    if (id_v != .string or tt_v != .string or dept_v != .string or desc_v != .string) return null;

    const task_type = parseTaskType(tt_v.string) orelse return null;
    if (!validDepartment(dept_v.string)) return null;

    const id = a.dupe(u8, id_v.string) catch return null;
    const department = a.dupe(u8, dept_v.string) catch {
        a.free(id);
        return null;
    };
    const description = a.dupe(u8, desc_v.string) catch {
        a.free(id);
        a.free(department);
        return null;
    };

    const contract_fields = buildContractFields(a, o.get("contract_fields")) orelse {
        a.free(id);
        a.free(department);
        a.free(description);
        return null;
    };
    const depends_on = buildDependsOn(a, o.get("depends_on")) orelse {
        a.free(id);
        a.free(department);
        a.free(description);
        freeContractFields(a, contract_fields);
        return null;
    };
    errdefer {
        for (depends_on) |d| a.free(d);
        a.free(depends_on);
    }

    // B1: owns (array de archivos que produce) y deliverable (nombre del
    // entregable al que pertenecen). Ambos opcionales.
    const owns = buildDependsOn(a, o.get("owns")) orelse {
        a.free(id);
        a.free(department);
        a.free(description);
        freeContractFields(a, contract_fields);
        for (depends_on) |d| a.free(d);
        a.free(depends_on);
        return null;
    };
    errdefer {
        for (owns) |o2| a.free(o2);
        if (owns.len > 0) a.free(owns);
    }
    const deliverable: ?[]const u8 = if (o.get("deliverable")) |dv|
        (if (dv == .string and dv.string.len > 0) a.dupe(u8, dv.string) catch {
            a.free(id);
            a.free(department);
            a.free(description);
            freeContractFields(a, contract_fields);
            for (depends_on) |d| a.free(d);
            a.free(depends_on);
            for (owns) |o2| a.free(o2);
            if (owns.len > 0) a.free(owns);
            return null;
        } else null)
    else
        null;

    return planner.PlannedTask{
        .id = id,
        .task_type = task_type,
        .department = department,
        .description = description,
        .contract_fields = contract_fields,
        .depends_on = depends_on,
        .owns = owns,
        .deliverable = deliverable,
    };
}

fn buildContractFields(a: std.mem.Allocator, v: ?std.json.Value) ?[]planner.ContractField {
    var list = std.ArrayList(planner.ContractField).empty;
    if (v) |fields_v| {
        if (fields_v == .array) {
            for (fields_v.array.items) |fv| {
                if (fv != .object or !fv.object.contains("name") or
                    fv.object.get("name").? != .string or fv.object.get("name").?.string.len == 0)
                {
                    freeContractFieldItems(a, list.items);
                    list.deinit(a);
                    return null;
                }
                const fo = fv.object;
                const name_v = fo.get("name").?;
                const ft = parseFieldType(if (fo.get("type")) |t| (if (t == .string) t.string else "string") else "string");
                const required = if (fo.get("required")) |r| (r == .bool and r.bool) else true;
                const name = a.dupe(u8, name_v.string) catch {
                    freeContractFieldItems(a, list.items);
                    list.deinit(a);
                    return null;
                };
                const value: ?[]const u8 = if (fo.get("value")) |value_v| switch (value_v) {
                    .null => null,
                    .string => a.dupe(u8, value_v.string) catch {
                        a.free(name);
                        freeContractFieldItems(a, list.items);
                        list.deinit(a);
                        return null;
                    },
                    else => {
                        a.free(name);
                        freeContractFieldItems(a, list.items);
                        list.deinit(a);
                        return null;
                    },
                } else null;
                list.append(a, .{ .name = name, .field_type = ft, .required = required, .value = value }) catch {
                    a.free(name);
                    if (value) |owned| a.free(owned);
                    freeContractFieldItems(a, list.items);
                    list.deinit(a);
                    return null;
                };
            }
        }
    }
    return list.toOwnedSlice(a) catch {
        freeContractFieldItems(a, list.items);
        list.deinit(a);
        return null;
    };
}

fn freeContractFieldItems(a: std.mem.Allocator, fields: []const planner.ContractField) void {
    for (fields) |f| {
        a.free(f.name);
        if (f.value) |value| a.free(value);
    }
}

fn freeContractFields(a: std.mem.Allocator, fields: []const planner.ContractField) void {
    freeContractFieldItems(a, fields);
    a.free(fields);
}

fn buildDependsOn(a: std.mem.Allocator, v: ?std.json.Value) ?[][]const u8 {
    var list = std.ArrayList([]const u8).empty;
    if (v) |dv| {
        if (dv == .array) {
            for (dv.array.items) |item| {
                if (item != .string) continue;
                const dep = a.dupe(u8, item.string) catch {
                    for (list.items) |d| a.free(d);
                    list.deinit(a);
                    return null;
                };
                list.append(a, dep) catch {
                    a.free(dep);
                    for (list.items) |d| a.free(d);
                    list.deinit(a);
                    return null;
                };
            }
        }
    }
    return list.toOwnedSlice(a) catch {
        for (list.items) |d| a.free(d);
        list.deinit(a);
        return null;
    };
}

/// Libera un PlannedTask igual que Plan.deinit (para limpieza ante fallo parcial).
fn freeTask(a: std.mem.Allocator, t: planner.PlannedTask) void {
    a.free(t.id);
    a.free(t.department);
    a.free(t.description);
    freeContractFields(a, t.contract_fields);
    for (t.depends_on) |d| a.free(d);
    a.free(t.depends_on);
    for (t.owns) |o| a.free(o);
    if (t.owns.len > 0) a.free(t.owns);
    if (t.deliverable) |d| a.free(d);
}

/// Lee un resumen REAL del catálogo de modelos (tool-use). Devuelve null ante cualquier
/// fallo (catálogo ausente/ilegible): el planner simplemente no añade el bloque CONTEXTO.
fn catalogSummary(a: std.mem.Allocator, catalog_path: []const u8) ?[]u8 {
    var cat = model_catalog.ModelCatalog.init(a, catalog_path) catch return null;
    defer cat.deinit();
    return cat.summarize(a) catch null;
}

/// Nombre del modelo que se le dice al modelo (y por tanto al usuario) que está
/// respondiendo. Sale del MISMO `LiveLlm.init` que hará la llamada, así que es
/// la cabeza real de la cadena.
///
/// Antes tenía su propia consulta con `ORDER BY m.is_free DESC, score, m.id ASC
/// LIMIT 1` — una CUARTA copia del criterio de selección, y la única que no se
/// corrigió al arreglar las otras tres: ignoraba `settings.governance_mode` y
/// también la salud. Consecuencia medida el 2026-08-06: la orden 118 la
/// respondió `Gemini/models/gemini-2.5-flash` (1 ok en `model_health`) pero al
/// modelo se le dijo que era `OpenCode/claude-fable-5`, que tiene 0 aciertos y 2
/// `auth_failed` y no ha contestado nunca. El agente le dio ese nombre al
/// usuario en su respuesta. Nombrar mal el modelo activo no es cosmético: es la
/// información con la que el usuario decide si un modelo le sirve.
fn activeModelSummary(a: std.mem.Allocator, catalog_path: []const u8, forced_provider: ?[]const u8, forced_model: ?[]const u8) ?[]u8 {
    // F7-MODEL-SELECT: si hay modelo forzado, reportar ese en vez del #1 del router.
    if (forced_provider != null and forced_model != null) {
        return std.fmt.allocPrint(a, "{s}/{s}", .{ forced_provider.?, forced_model.? }) catch null;
    }
    var live = live_worker.LiveLlm.init(a, catalog_path) orelse return null;
    defer live.deinit();
    // La salud reordena la cadena, así que se aplica antes de leer la cabeza:
    // sin esto se anunciaría un candidato que la propia cadena va a saltarse.
    live.setOwnedHealthConnFromCatalogPath();
    if (live.lives.len == 0) return null;
    const head = live.lives[0];
    return std.fmt.allocPrint(a, "{s}/{s}", .{ head.cfg.name, head.model }) catch null;
}

fn parseTaskType(s: []const u8) ?model_router.TaskType {
    inline for (@typeInfo(model_router.TaskType).@"enum".fields) |f| {
        const tt = @field(model_router.TaskType, f.name);
        if (std.mem.eql(u8, s, tt.toText())) return tt;
    }
    return null;
}

fn validDepartment(s: []const u8) bool {
    for (DEPARTMENTS) |d| {
        if (std.mem.eql(u8, s, d)) return true;
    }
    return false;
}

fn parseFieldType(s: []const u8) contracts.FieldType {
    if (std.mem.eql(u8, s, "integer")) return .integer;
    if (std.mem.eql(u8, s, "boolean")) return .boolean;
    if (std.mem.eql(u8, s, "any")) return .any;
    return .string;
}

test "parseTaskType y validDepartment" {
    try std.testing.expectEqual(model_router.TaskType.programar_c, parseTaskType("programar_c").?);
    try std.testing.expectEqual(@as(?model_router.TaskType, null), parseTaskType("inventado"));
    try std.testing.expect(validDepartment("auditoria"));
    try std.testing.expect(!validDepartment("ventas"));
    try std.testing.expectEqual(contracts.FieldType.integer, parseFieldType("integer"));
    try std.testing.expectEqual(contracts.FieldType.string, parseFieldType("desconocido"));
}

test "isCatalogIntent detects catalog-related queries" {
    try std.testing.expect(isCatalogIntent("¿Qué modelos tienes?"));
    try std.testing.expect(isCatalogIntent("Dame el catálogo"));
    try std.testing.expect(isCatalogIntent("proveedores disponibles"));
    try std.testing.expect(!isCatalogIntent("Hola"));
    try std.testing.expect(!isCatalogIntent("Crea un script"));
}

test "isCapabilitiesIntent detects capability queries" {
    try std.testing.expect(isCapabilitiesIntent("¿Qué herramientas tienes?"));
    try std.testing.expect(isCapabilitiesIntent("Qué puedes hacer"));
    try std.testing.expect(isCapabilitiesIntent("Tienes MCP?"));
    try std.testing.expect(!isCapabilitiesIntent("Hola"));
    try std.testing.expect(!isCapabilitiesIntent("Crea una función"));
}

test "assemblePrompt: catalog block gated by intent and skipped when empty" {
    const allocator = std.testing.allocator;
    const no_answers = &[_]planner.ClarificationAnswer{};
    const no_history = &[_]planner.ConversationTurn{};

    // Con intención de catálogo pero catálogo vacío: el bloque no se inyecta (sum.len == 0).
    const prompt1 = assemblePrompt(allocator, "", "¿Qué modelos tienes?", no_answers, no_history, null, null, null, 0) orelse {
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(prompt1);
    try std.testing.expect(std.mem.indexOf(u8, prompt1, "ORDEN: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt1, "CATÁLOGO REAL") == null);

    // Sin intención de catálogo: no debe aparecer etiqueta de sistema.
    const prompt2 = assemblePrompt(allocator, "", "Hola", no_answers, no_history, null, null, null, 0) orelse {
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(prompt2);
    try std.testing.expect(std.mem.indexOf(u8, prompt2, "[CONTEXTO DE SISTEMA") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt2, "CATÁLOGO REAL") == null);
}

test "assemblePrompt: injects active provider and model identity" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const GetTempPathA = @import("platform.zig").tempPath;
    var sys_buf: [1024]u8 = undefined;
    const len = GetTempPathA(1024, &sys_buf);
    const sys_temp = if (len > 0 and len < 1024) sys_buf[0..len] else "C:\\Windows\\Temp\\";
    const path_raw = try std.fmt.allocPrint(
        allocator,
        "{s}beats-test-{s}-catalog.db",
        .{ sys_temp, tmp.sub_path[0..] },
    );
    defer allocator.free(path_raw);
    const path = try allocator.dupeZ(u8, path_raw);
    defer allocator.free(path);

    // La clave se siembra con CredentialManager (cifrado DPAPI real), no con un
    // x'00' a pelo. `activeModelSummary` ya no consulta el catálogo por su cuenta:
    // lee la cabeza de la MISMA cadena `LiveLlm.init` que hará la llamada, y esa
    // cadena descarta los candidatos cuya clave no se puede descifrar. Anunciar un
    // modelo cuya clave ni siquiera abre era parte del fallo que esto corrige.
    {
        var cm = try credentials.CredentialManager.init(allocator, path);
        defer cm.deinit();
        try cm.addProvider("Cerebras", "https://example.test", "openai", true);
        try cm.addKey("Cerebras", "default", "clave-de-prueba");
        try cm.db.exec("INSERT INTO models (provider_id, model_name, context_window, is_free, available) SELECT id, 'gpt-oss-120b', 128000, 1, 1 FROM providers WHERE name='Cerebras'");
    }

    const prompt = assemblePrompt(allocator, path, "¿Qué modelo usas?", &[_]planner.ClarificationAnswer{}, &[_]planner.ConversationTurn{}, null, null, null, 0) orelse {
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "MODELO_ACTIVO: Cerebras/gpt-oss-120b") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "estás usando Cerebras/gpt-oss-120b") != null);
}

test "MODELO-ANUNCIADO: el modelo que se anuncia es el que la cadena probaria primero" {
    // Fallo real reportado por el usuario y medido el 2026-08-06: el agente
    // contestó "estoy usando OpenCode/claude-fable-5" mientras quien respondía era
    // Gemini/models/gemini-2.5-flash. `activeModelSummary` tenía su propia consulta
    // (una CUARTA copia del criterio de selección) que ignoraba la gobernanza y la
    // salud, así que nombraba un candidato que la cadena real ni siquiera usaba.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const GetTempPathA = @import("platform.zig").tempPath;
    var sys_buf: [1024]u8 = undefined;
    const len = GetTempPathA(1024, &sys_buf);
    const sys_temp = if (len > 0 and len < 1024) sys_buf[0..len] else "C:\\Windows\\Temp\\";
    const path_raw = try std.fmt.allocPrint(allocator, "{s}beats-anuncio-{s}-catalog.db", .{ sys_temp, tmp.sub_path[0..] });
    defer allocator.free(path_raw);
    const path = try allocator.dupeZ(u8, path_raw);
    defer allocator.free(path);

    {
        var cm = try credentials.CredentialManager.init(allocator, path);
        defer cm.deinit();
        try cm.addProvider("Cohere", "https://api.cohere.ai", "cohere", true);
        try cm.addProvider("Gemini", "https://generativelanguage.googleapis.com/v1beta", "google_gemini", false);
        try cm.addKey("Cohere", "COHERE_01", "clave-cohere");
        try cm.addKey("Gemini", "GEMINI_01", "clave-gemini");
        try cm.db.exec("INSERT INTO models (provider_id, model_name, is_free, available) SELECT id, 'command-a-03-2025', 1, 1 FROM providers WHERE name='Cohere'");
        try cm.db.exec("INSERT INTO models (provider_id, model_name, is_free, available) SELECT id, 'models/gemini-pro-latest', 0, 1 FROM providers WHERE name='Gemini'");
        try cm.db.exec("UPDATE settings SET value='paid_tier_first' WHERE key='governance_mode'");
    }

    // Con "Prioriza pago" la cadena solo admite modelos de pago, así que lo
    // anunciado tiene que ser el de pago. Con la consulta vieja (`is_free DESC`)
    // se habría anunciado el gratuito de Cohere, que la cadena nunca probaría.
    const anunciado = activeModelSummary(allocator, path, null, null) orelse {
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(anunciado);
    try std.testing.expectEqualStrings("Gemini/models/gemini-pro-latest", anunciado);

    // Y la cadena real empieza por ese mismo modelo: anuncio y ejecución coinciden.
    var live = live_worker.LiveLlm.init(allocator, path) orelse return error.TestUnexpectedResult;
    defer live.deinit();
    try std.testing.expectEqualStrings("Gemini", live.lives[0].cfg.name);
    try std.testing.expectEqualStrings("models/gemini-pro-latest", live.lives[0].model);
}

test "assemblePrompt: capabilities block gated by intent" {
    const allocator = std.testing.allocator;
    const no_answers = &[_]planner.ClarificationAnswer{};
    const no_history = &[_]planner.ConversationTurn{};
    const prompt1 = assemblePrompt(allocator, "", "¿Qué herramientas tienes?", no_answers, no_history, null, null, null, 0) orelse {
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(prompt1);
    try std.testing.expect(std.mem.indexOf(u8, prompt1, "[CONTEXTO DE SISTEMA") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt1, "Capacidades reales de DevAgents") != null);
    // CAP-01: debe reflejar EXEC-01 como gobernado, no negado.
    try std.testing.expect(std.mem.indexOf(u8, prompt1, "DENTRO del sandbox") != null);

    const prompt2 = assemblePrompt(allocator, "", "Hola", no_answers, no_history, null, null, null, 0) orelse {
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(prompt2);
    try std.testing.expect(std.mem.indexOf(u8, prompt2, "Capacidades reales de DevAgents") == null);
}

test "assemblePrompt: history block included in oldest-to-newest order" {
    const allocator = std.testing.allocator;
    const no_answers = &[_]planner.ClarificationAnswer{};

    var turn_storage: [2]planner.ConversationTurn = undefined;
    turn_storage[0].user = try allocator.dupe(u8, "crea un módulo de logging");
    turn_storage[0].agent = try allocator.dupe(u8, "entendimiento previo 1");
    turn_storage[1].user = try allocator.dupe(u8, "en C");
    turn_storage[1].agent = try allocator.dupe(u8, "entendimiento previo 2");
    defer {
        allocator.free(turn_storage[0].user);
        allocator.free(turn_storage[0].agent);
        allocator.free(turn_storage[1].user);
        allocator.free(turn_storage[1].agent);
    }
    const history = turn_storage[0..];

    const prompt = assemblePrompt(allocator, "", "añade tests", no_answers, history, null, null, null, 0) orelse {
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(prompt);

    const hist_open = std.mem.indexOf(u8, prompt, "[HISTORIAL DE CONVERSACIÓN").?;
    const hist_close = std.mem.indexOf(u8, prompt, "[FIN HISTORIAL]").?;
    try std.testing.expect(hist_open < hist_close);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Turno 1 — Usuario: crea un módulo de logging") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Turno 1 — Agente: entendimiento previo 1") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Turno 2 — Usuario: en C") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Turno 2 — Agente: entendimiento previo 2") != null);

    // El mensaje actual sigue presente y NO se confunde con el historial.
    const order_pos = std.mem.indexOf(u8, prompt, "ORDEN: añade tests").?;
    try std.testing.expect(hist_close < order_pos);
}

test "assemblePrompt: history block omitted when empty" {
    const allocator = std.testing.allocator;
    const no_answers = &[_]planner.ClarificationAnswer{};
    const no_history = &[_]planner.ConversationTurn{};

    const prompt = assemblePrompt(allocator, "", "crea un módulo de logging", no_answers, no_history, null, null, null, 0) orelse {
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "[HISTORIAL DE CONVERSACIÓN") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "[FIN HISTORIAL]") == null);
}

// FIX 2 regresión: pre-clasificación determinista para imperativos de construcción.
test "QA primerizo: modificar un archivo y luego ejecutar las pruebas es construir, no ejecutar" {
    const order = "En adivina.py limita el juego a 7 intentos: si se agotan, muestra el número secreto y termina. Añade una prueba para el límite y ejecuta todas las pruebas.";
    try std.testing.expect(isExecuteIntent(order)); // sigue habiendo «y ejecuta»…
    try std.testing.expect(isBuildIntent(order)); // …pero manda construir: plan normal.
    try std.testing.expect(isBuildIntent("corrige el bug de login.ts"));
    try std.testing.expect(isBuildIntent("Añade un botón de reinicio al juego"));
    // Sin artefacto ni archivo no es construir: acciones de la cabina y charla.
    try std.testing.expect(!isBuildIntent("cambia el tema a claro"));
    try std.testing.expect(!isBuildIntent("ejecuta python adivina.py"));
}

test "isBuildIntent detects clear build orders" {
    try std.testing.expect(isBuildIntent("Crea un script que invierta un string"));
    try std.testing.expect(isBuildIntent("crea primos.py"));
    try std.testing.expect(isBuildIntent("Implementa factorial en C"));
    try std.testing.expect(isBuildIntent("Hazme un FizzBuzz en Zig"));
    try std.testing.expect(isBuildIntent("Escribe una app de consola en C++"));
    try std.testing.expect(isBuildIntent("Genera un módulo de logging"));
    try std.testing.expect(isBuildIntent("Programa un juego de snake"));
    try std.testing.expect(isBuildIntent("Desarrolla una librería matemática"));
    try std.testing.expect(isBuildIntent("Construye una API REST"));
}

test "isBuildIntent rejects chat and queries" {
    try std.testing.expect(!isBuildIntent("Hola"));
    try std.testing.expect(!isBuildIntent("¿Qué puedes hacer?"));
    try std.testing.expect(!isBuildIntent("dame el catálogo de modelos"));
    try std.testing.expect(!isBuildIntent("Gracias por tu ayuda"));
    try std.testing.expect(!isBuildIntent("creación de arte")); // "crea" como prefijo de otra palabra
}

// FIX 2 regresión: fallback honesto cuando LLM falla (sin catálogo/claves).
test "build intent falls back to MockPlanner tasks when LLM unavailable" {
    const allocator = std.testing.allocator;
    var lp = LlmPlanner.init(allocator, "nonexistent_catalog.db");
    const backend = lp.backend();
    defer backend.deinit();

    // Sin catálogo, tryLlmPlan devuelve null; isBuildIntent true → MockPlanner → tareas.
    var plan = try backend.plan(allocator, "Implementa factorial en C", &.{}, null);
    defer plan.deinit();

    try std.testing.expect(plan.tasks.len > 0);
    try std.testing.expectEqual(model_router.TaskType.programar_c, plan.tasks[0].task_type);
    // El understanding debe venir del MockPlanner (NO ser un dead-end vacío).
    try std.testing.expect(plan.understanding.len > 0);
}

test "planner_fallback event carries the real failure cause in detail" {
    const allocator = std.testing.allocator;
    // runtime.db en memoria para capturar el evento que el fallback emite.
    var runtime = try db.Connection.open(allocator, ":memory:");
    defer runtime.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(runtime, &db.runtime_schema);
    try runtime.exec("INSERT INTO orders(id,project_id,user_prompt,status,created_at) VALUES (77,'t','o','running',1)");

    var lp = LlmPlanner.init(allocator, "nonexistent_catalog.db");
    lp.event_conn = runtime;
    lp.event_order_id = 77;
    const backend = lp.backend();
    defer backend.deinit();

    // Sin catálogo no hay candidatos con clave: el LLM ni siquiera se intenta.
    var plan = try backend.plan(allocator, "Implementa factorial en C", &.{}, null);
    defer plan.deinit();

    const stmt = try runtime.prepare("SELECT payload_json FROM events WHERE kind='planner_fallback' AND order_id=77");
    defer runtime.finalize(stmt);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
    const payload = std.mem.span(@as([*:0]const u8, @ptrCast(db.c.sqlite3_column_text(stmt, 0))));
    // La causa real viaja en `detail` — el código «mock_planner» solo en reason.
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"reason\":\"mock_planner\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"detail\":\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "clave activa") != null);
}

test "CK-MOT-030: prosa sin planificador produce documento con aviso de causa, no pregunta de lenguaje" {
    const allocator = std.testing.allocator;
    var lp = LlmPlanner.init(allocator, "nonexistent_catalog.db");
    const backend = lp.backend();
    defer backend.deinit();

    // Orden de prosa (build intent por «documenta»+«texto») sin ningún
    // planificador: el MockPlanner ya no pregunta «¿lenguaje? (C/C++/Zig)»
    // — produce la tarea documentar y el aviso dice por qué cayó al local.
    var plan = try backend.plan(allocator, "documenta en un texto nota el ciclo del agua", &.{}, null);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 0), plan.questions.len);
    try std.testing.expectEqual(@as(usize, 1), plan.tasks.len);
    try std.testing.expectEqual(model_router.TaskType.documentar, plan.tasks[0].task_type);
    try std.testing.expect(std.mem.indexOf(u8, plan.understanding, "ningún planificador respondió") != null);
}

test "CK-MOT-030: código ambiguo sin planificador sigue aclarando el lenguaje" {
    const allocator = std.testing.allocator;
    var lp = LlmPlanner.init(allocator, "nonexistent_catalog.db");
    const backend = lp.backend();
    defer backend.deinit();

    // «Crea un módulo para el problema» sí es construcción ambigua: la
    // pregunta del lenguaje corresponde a la orden y se conserva.
    var plan = try backend.plan(allocator, "Crea un módulo para el problema", &.{}, null);
    defer plan.deinit();

    try std.testing.expect(plan.needsClarification());
    try std.testing.expectEqualStrings("target-language", plan.questions[0].id);
}

test "chat intent gets honest error message when LLM unavailable" {
    const allocator = std.testing.allocator;
    var lp = LlmPlanner.init(allocator, "nonexistent_catalog.db");
    const backend = lp.backend();
    defer backend.deinit();

    // Sin catálogo, tryLlmPlan devuelve null; isBuildIntent false → mensaje honesto.
    var plan = try backend.plan(allocator, "Hola", &.{}, null);
    defer plan.deinit();

    try std.testing.expect(plan.tasks.len == 0);
    try std.testing.expect(plan.questions.len == 0);
    try std.testing.expect(plan.understanding.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, plan.understanding, "No pude planificar") != null);
}

// FIX 2b regresión: heurística afinada por límite de palabra.
test "isBuildIntent rejects poem false positive (word boundary)" {
    try std.testing.expect(!isBuildIntent("Crea un poema sobre el mar"));
}

test "isBuildIntent preserves true positives after word boundary fix" {
    try std.testing.expect(isBuildIntent("Implementa factorial en C"));
    try std.testing.expect(isBuildIntent("Escribe una app en Go"));
    try std.testing.expect(isBuildIntent("Haz un programa en Zig"));
}

test "isBuildIntent rejects joke request" {
    try std.testing.expect(!isBuildIntent("Cuéntame un chiste"));
}

test "stripContextPrefix strips [Contexto: ...] fast context blocks" {
    const input = "[Contexto: archivo activo = main.py (python, 42 líneas)]\n[Archivos abiertos: main.py, utils.py]\n[Estructura del proyecto: src/, tests/, README.md]\n\nCrea una funcion Python factorial con test";
    const stripped = stripContextPrefix(input);
    try std.testing.expect(std.mem.startsWith(u8, stripped, "Crea"));
    try std.testing.expect(isBuildIntent(stripped));
}

test "stripContextPrefix strips [Selección del usuario: ...] multiline block" {
    const input = "[Contexto: archivo activo = main.py (python, 42 líneas)]\n[Selección del usuario:\ndef foo():\n    return 42\n]\n\nCrea una funcion Python factorial con test";
    const stripped = stripContextPrefix(input);
    try std.testing.expect(std.mem.startsWith(u8, stripped, "Crea"));
    try std.testing.expect(isBuildIntent(stripped));
}

// FIX 2b regresión: directiva en prompt.
test "assemblePrompt injects build directive for imperative order" {
    const allocator = std.testing.allocator;
    const no_answers = &[_]planner.ClarificationAnswer{};
    const no_history = &[_]planner.ConversationTurn{};

    const prompt = assemblePrompt(allocator, "", "Crea un script que invierta un string", no_answers, no_history, null, null, null, 0) orelse {
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "[INTENCIÓN DETECTADA: CONSTRUCCIÓN") != null);
}

test "assemblePrompt omits build directive for chat order" {
    const allocator = std.testing.allocator;
    const no_answers = &[_]planner.ClarificationAnswer{};
    const no_history = &[_]planner.ConversationTurn{};

    const prompt = assemblePrompt(allocator, "", "Hola", no_answers, no_history, null, null, null, 0) orelse {
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "[INTENCIÓN DETECTADA: CONSTRUCCIÓN") == null);
}

// FIX 2b regresión: coerción post-LLM cuando el modelo sesga a chat puro.
test "coercion: build intent forces MockPlanner when LLM returns chat" {
    const allocator = std.testing.allocator;
    var lp = LlmPlanner.init(allocator, "nonexistent_catalog.db");
    lp.test_response = "{\"kind\":\"chat\",\"reply\":\"¡Claro! Aquí tienes una respuesta conversacional.\"}";
    const backend = lp.backend();
    defer backend.deinit();

    var plan = try backend.plan(allocator, "Crea un script en C que invierta un string", &.{}, null);
    defer plan.deinit();

    try std.testing.expect(plan.tasks.len > 0);
    try std.testing.expect(plan.questions.len == 0);
}

test "coercion: non-chat build plan from LLM is preserved" {
    const allocator = std.testing.allocator;
    var lp = LlmPlanner.init(allocator, "nonexistent_catalog.db");
    lp.test_response = "{\"kind\":\"build\",\"understanding\":\"Implementar script\",\"tasks\":[{\"id\":\"t1\",\"task_type\":\"programar\",\"department\":\"programacion\",\"description\":\"Invertir string\",\"contract_fields\":[{\"name\":\"source\",\"type\":\"string\",\"required\":true}],\"depends_on\":[]}]}";
    const backend = lp.backend();
    defer backend.deinit();

    var plan = try backend.plan(allocator, "Crea un script en C que invierta un string", &.{}, null);
    defer plan.deinit();

    try std.testing.expect(plan.tasks.len > 0);
    try std.testing.expectEqualStrings("Implementar script", plan.understanding);
}

// MEM-02: inyección de memoria de proyecto en el prompt del planner.
test "assemblePrompt injects memory_context block when present" {
    const allocator = std.testing.allocator;
    const no_answers = &[_]planner.ClarificationAnswer{};
    const no_history = &[_]planner.ConversationTurn{};
    const mem = "Sesión previa: encontré que el módulo de logging necesita mutex.";

    const prompt = assemblePrompt(allocator, "", "añade tests al logger", no_answers, no_history, null, null, mem, 0) orelse {
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "[MEMORIA DE PROYECTO") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "[FIN MEMORIA DE PROYECTO]") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, mem) != null);
    // El bloque debe aparecer ANTES de la orden actual.
    const mem_open = std.mem.indexOf(u8, prompt, "[MEMORIA DE PROYECTO").?;
    const order_pos = std.mem.indexOf(u8, prompt, "ORDEN: añade tests al logger").?;
    try std.testing.expect(mem_open < order_pos);
}

test "assemblePrompt omits memory_context block when null" {
    const allocator = std.testing.allocator;
    const no_answers = &[_]planner.ClarificationAnswer{};
    const no_history = &[_]planner.ConversationTurn{};

    const prompt = assemblePrompt(allocator, "", "crea un módulo de logging", no_answers, no_history, null, null, null, 0) orelse {
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "[MEMORIA DE PROYECTO") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "[FIN MEMORIA DE PROYECTO]") == null);
}

test "LlmPlanner plan with memory_context does not leak" {
    const allocator = std.testing.allocator;
    var lp = LlmPlanner.init(allocator, "nonexistent_catalog.db");
    lp.memory_context = try allocator.dupe(u8, "hallazgo de prueba");
    defer allocator.free(lp.memory_context.?);
    const backend = lp.backend();
    defer backend.deinit();

    var plan = try backend.plan(allocator, "Implementa factorial en C", &.{}, lp.memory_context);
    defer plan.deinit();

    try std.testing.expect(plan.tasks.len > 0);
}

test "PLANNER-INTENT: classification checks" {
    // True positives (execution intent)
    try std.testing.expect(isExecuteIntent("Ejecuta el programa"));
    try std.testing.expect(isExecuteIntent("Corre los tests"));
    try std.testing.expect(isExecuteIntent("Lanza `python app.py`"));
    try std.testing.expect(isExecuteIntent("Prueba el script generado"));
    try std.testing.expect(isExecuteIntent("Crea el archivo y ejecútalo"));
    try std.testing.expect(isExecuteIntent("Abre la aplicación"));
    try std.testing.expect(isExecuteIntent("Inicia el servidor"));

    // True negatives (NOT execution intent)
    try std.testing.expect(!isExecuteIntent("Responde exactamente: PRUEBA DEVAGENTS E2E OK"));
    try std.testing.expect(!isExecuteIntent("Escribe literalmente “ejecuta el programa”"));
    try std.testing.expect(!isExecuteIntent("Traduce “run the tests” al español"));
    try std.testing.expect(!isExecuteIntent("Explica qué significa “corre el servidor”"));
    try std.testing.expect(!isExecuteIntent("Resume el resultado de la prueba E2E"));
    try std.testing.expect(!isExecuteIntent("Dime si la prueba pasó"));

    // Noun check
    try std.testing.expect(!isExecuteIntent("Prueba de compilación"));
    try std.testing.expect(!isExecuteIntent("Prueba de E2E"));

    // Una mención nominal de "programa" dentro de una pregunta no es el
    // imperativo "programa <algo>".
    try std.testing.expect(!isBuildIntent("Explica brevemente qué diferencia hay entre compilar y ejecutar un programa."));
    try std.testing.expect(isBuildIntent("Explica la diferencia y crea un script de ejemplo."));
    try std.testing.expect(isBuildIntent("Hola, crea un programa en Zig."));
}

test "PLANNER-INTENT: coercion of incorrect LLM execution plan to chat" {
    const allocator = std.testing.allocator;
    var p = LlmPlanner.init(allocator, "dummy_catalog.db");

    // Simular un LLM que devuelve incorrectamente una tarea de ejecución para una orden conversacional
    p.test_response =
        \\{
        \\  "kind": "build",
        \\  "understanding": "Respondiendo a la pregunta sobre el servidor",
        \\  "tasks": [
        \\    {
        \\      "id": "t1",
        \\      "task_type": "ejecutar",
        \\      "department": "programacion",
        \\      "description": "Ejecutar corre el servidor",
        \\      "contract_fields": [
        \\        {"name": "target", "type": "string", "required": true}
        \\      ],
        \\      "depends_on": []
        \\    }
        \\  ]
        \\}
    ;

    const order = "Explica qué significa “corre el servidor”";
    var plan_res = try p.backend().plan(allocator, order, &[_]planner.ClarificationAnswer{}, null);
    defer plan_res.deinit();

    // Comprobar que la capa posterior detectó que no había intent y coaccionó a chat (sin tareas)
    try std.testing.expectEqual(@as(usize, 0), plan_res.tasks.len);
    try std.testing.expectEqualStrings("Respondiendo a la pregunta sobre el servidor", plan_res.understanding);
}

test "PLANNER-INTENT: post-LLM guard preserves legitimate unrecognized build verbs" {
    const allocator = std.testing.allocator;
    var p = LlmPlanner.init(allocator, "dummy_catalog.db");
    p.test_response =
        \\{
        \\  "kind": "build",
        \\  "understanding": "Refactorizar el módulo solicitado",
        \\  "tasks": [{
        \\    "id": "t1",
        \\    "task_type": "corregir",
        \\    "department": "correccion",
        \\    "description": "Refactorizar el módulo de autenticación",
        \\    "contract_fields": [{"name":"source","type":"string","required":true}],
        \\    "depends_on": []
        \\  }]
        \\}
    ;

    var plan_res = try p.backend().plan(allocator, "Refactoriza el módulo de autenticación", &.{}, null);
    defer plan_res.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan_res.tasks.len);
    try std.testing.expectEqual(model_router.TaskType.corregir, plan_res.tasks[0].task_type);
}

test "PLANNER-INTENT: exact-reply request preserves requested text without tasks" {
    const allocator = std.testing.allocator;
    var p = LlmPlanner.init(allocator, "dummy_catalog.db");
    p.test_response =
        \\{"kind":"build","understanding":"El usuario solicita una verificación", "tasks":[{
        \\  "id":"t1","task_type":"ejecutar","department":"programacion",
        \\  "description":"Ejecutar verificación","contract_fields":[],"depends_on":[]
        \\}]}
    ;
    var plan_res = try p.backend().plan(
        allocator,
        "Responde exactamente con este texto y no añadas nada más: PRUEBA DEVAGENTS E2E OK",
        &.{},
        null,
    );
    defer plan_res.deinit();
    try std.testing.expectEqual(@as(usize, 0), plan_res.tasks.len);
    try std.testing.expectEqualStrings("PRUEBA DEVAGENTS E2E OK", plan_res.understanding);
}

// ── GATE-PROSA: pedir un documento es pedir un entregable ─────────────────

test "B1: el planner parsea owns y deliverable por tarea" {
    const allocator = std.testing.allocator;
    var p = LlmPlanner.init(allocator, "dummy_catalog.db");
    p.test_response =
        \\{"kind":"build","understanding":"Web de tres archivos","tasks":[
        \\  {"id":"t1","task_type":"programar","department":"programacion","description":"Crear index.html","owns":["index.html"],"deliverable":"pagina","contract_fields":[],"depends_on":[]},
        \\  {"id":"t2","task_type":"programar","department":"programacion","description":"Crear app.js","owns":["app.js"],"deliverable":"pagina","contract_fields":[],"depends_on":[]},
        \\  {"id":"t3","task_type":"programar","department":"programacion","description":"Crear backup.py","owns":["backup.py"],"deliverable":"backup","contract_fields":[],"depends_on":[]}
        \\]}
    ;
    var plan_res = try p.backend().plan(allocator, "crea una web y un script de backup", &.{}, null);
    defer plan_res.deinit();

    try std.testing.expectEqual(@as(usize, 3), plan_res.tasks.len);
    try std.testing.expectEqual(@as(usize, 1), plan_res.tasks[0].owns.len);
    try std.testing.expectEqualStrings("index.html", plan_res.tasks[0].owns[0]);
    try std.testing.expectEqualStrings("pagina", plan_res.tasks[0].deliverable.?);
    try std.testing.expectEqualStrings("backup", plan_res.tasks[2].deliverable.?);
}

test "B1: tarea sin owns ni deliverable parsea con vacíos" {
    const allocator = std.testing.allocator;
    var p = LlmPlanner.init(allocator, "dummy_catalog.db");
    p.test_response =
        \\{"kind":"build","understanding":"x","tasks":[
        \\  {"id":"t1","task_type":"programar","department":"programacion","description":"Crear a.js","contract_fields":[],"depends_on":[]}
        \\]}
    ;
    var plan_res = try p.backend().plan(allocator, "crea a.js", &.{}, null);
    defer plan_res.deinit();
    try std.testing.expectEqual(@as(usize, 0), plan_res.tasks[0].owns.len);
    try std.testing.expect(plan_res.tasks[0].deliverable == null);
}

test "GATE-PROSA: pedir un documento es construir, no charlar" {
    // El caso exacto del gate de aceptacion (#220, #224): la respuesta se
    // escribia entera en el entendimiento y no quedaba archivo ninguno.
    try std.testing.expect(isBuildIntent("Documenta brevemente en un texto los riesgos de guardar claves de API en texto plano"));
    try std.testing.expect(isBuildIntent("Redacta un informe sobre el estado del proyecto"));
    try std.testing.expect(isBuildIntent("Escribe un README para el modulo de router"));
    try std.testing.expect(isBuildIntent("Audita el manejo de errores y deja un reporte"));
}

test "GATE-PROSA: una PREGUNTA sigue siendo charla" {
    // El discriminador es que el usuario nombre un ENTREGABLE. Sin verbo de
    // produccion y sin entregable, no hay nada que escribir en disco: forzar
    // build aqui llenaria el workspace de archivos que nadie pidio.
    try std.testing.expect(!isBuildIntent("Cuales son los riesgos de guardar claves en texto plano"));
    try std.testing.expect(!isBuildIntent("Que modelos tengo configurados"));
    try std.testing.expect(!isBuildIntent("Hola"));
    try std.testing.expect(!isBuildIntent("Explicame como funciona el router"));
}

test "GATE-PROSA: un verbo de documentar SIN entregable no basta" {
    // «Documenta esto» a secas no dice que producir. Ante la duda, charla:
    // es la regla que el propio SYSTEM_PROMPT ya declara.
    try std.testing.expect(!isBuildIntent("Documenta"));
    try std.testing.expect(!isBuildIntent("Resume lo que hablamos"));
}

test "D2: planificador genera y parsea tareas paralelas sin depends_on para entregables independientes" {
    const allocator = std.testing.allocator;
    var p = LlmPlanner.init(allocator, "dummy_catalog.db");
    p.test_response =
        \\{"kind":"build","understanding":"Crear aplicación web con HTML, CSS y JS en paralelo", "tasks":[
        \\  {"id":"t1","task_type":"programar","department":"programacion","description":"Crear index.html","contract_fields":[{"name":"source","type":"string","required":true},{"name":"filename","type":"string","required":false}],"depends_on":[]},
        \\  {"id":"t2","task_type":"programar","department":"programacion","description":"Crear styles.css","contract_fields":[{"name":"source","type":"string","required":true},{"name":"filename","type":"string","required":false}],"depends_on":[]},
        \\  {"id":"t3","task_type":"programar","department":"programacion","description":"Crear app.js","contract_fields":[{"name":"source","type":"string","required":true},{"name":"filename","type":"string","required":false}],"depends_on":[]},
        \\  {"id":"t4","task_type":"auditar","department":"auditoria","description":"Auditar entregables","contract_fields":[{"name":"verdict","type":"string","required":true}],"depends_on":["t1","t2","t3"]}
        \\]}
    ;
    var plan_res = try p.backend().plan(
        allocator,
        "Crea una app web con index.html, styles.css y app.js",
        &.{},
        null,
    );
    defer plan_res.deinit();

    try std.testing.expectEqual(@as(usize, 4), plan_res.tasks.len);
    // t1, t2, t3 son independientes (depends_on vacíos) -> Ola 0 paralelizable
    try std.testing.expectEqual(@as(usize, 0), plan_res.tasks[0].depends_on.len);
    try std.testing.expectEqual(@as(usize, 0), plan_res.tasks[1].depends_on.len);
    try std.testing.expectEqual(@as(usize, 0), plan_res.tasks[2].depends_on.len);
    // t4 depende de los 3
    try std.testing.expectEqual(@as(usize, 3), plan_res.tasks[3].depends_on.len);
}

test "planner preserves filename and command contract values" {
    const allocator = std.testing.allocator;
    const response =
        \\{"kind":"build","understanding":"Crear index.html y comprobarlo con Node","tasks":[
        \\{"id":"t1","task_type":"programar","department":"programacion","description":"Crear index.html","contract_fields":[{"name":"source","type":"string","required":true},{"name":"filename","type":"string","required":true,"value":"index.html"}],"depends_on":[]},
        \\{"id":"t2","task_type":"testear","department":"testing","description":"Ejecutar prueba de index.html","contract_fields":[{"name":"command","type":"string","required":true,"value":"node test_app.js"}],"depends_on":["t1"]}
        \\]}
    ;
    var plan = tryLlmPlan(allocator, "dummy_catalog.db", allocator, "Crear index.html", &.{}, &.{}, response, null, null, false, null, null, null, 0, 0, null, null, null, null, null) orelse return error.TestExpectedPlan;
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 2), plan.tasks.len);
    try std.testing.expectEqualStrings("index.html", plan.tasks[0].contract_fields[1].value.?);
    try std.testing.expectEqualStrings("node test_app.js", plan.tasks[1].contract_fields[0].value.?);
}

test "planner rejects typed contract value and frees earlier values" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer {
        const status = gpa.deinit();
        std.testing.expect(status == .ok) catch @panic("planner value cleanup leaked");
    }
    const allocator = gpa.allocator();
    const malformed_later =
        \\{"kind":"build","understanding":"Plan de prueba","tasks":[
        \\{"id":"t1","task_type":"programar","department":"programacion","description":"Crear app.js","contract_fields":[{"name":"filename","type":"string","required":true,"value":"app.js"}],"depends_on":[]},
        \\{"id":"t2","task_type":"testear","department":"testing","description":"Probar app.js","contract_fields":[{"name":"command","type":"string","required":true,"value":42}],"depends_on":["t1"]}
        \\]}
    ;
    const plan = tryLlmPlan(allocator, "dummy_catalog.db", allocator, "Crear app.js", &.{}, &.{}, malformed_later, null, null, false, null, null, null, 0, 0, null, null, null, null, null);
    try std.testing.expect(plan == null);
}

test "planner rejects malformed fields instead of silently dropping requirements" {
    const a = std.testing.allocator;
    for ([_][]const u8{
        "[{\"type\":\"string\"}]",                           "[42]", "[{\"name\":42}]", "[{\"name\":\"\"}]",
        "[{\"name\":\"filename\",\"value\":\"app.js\"},42]",
    }) |raw| {
        var parsed = try std.json.parseFromSlice(std.json.Value, a, raw, .{});
        defer parsed.deinit();
        const result = buildContractFields(a, parsed.value);
        defer if (result) |fields| freeContractFields(a, fields);
        try std.testing.expect(result == null);
    }
}

test "UI-ACTION: deterministicUiPlan reconoce controles de cabina y rechaza lo demas" {
    const allocator = std.testing.allocator;

    // Tema por sinonimo comun.
    {
        var plan = (LlmPlanner.deterministicUiPlan(allocator, "cambia el tema a claro")).?;
        defer plan.deinit();
        try std.testing.expectEqual(@as(usize, 1), plan.tasks.len);
        try std.testing.expectEqual(model_router.TaskType.ui, plan.tasks[0].task_type);
        try std.testing.expectEqualStrings("set_theme", plan.tasks[0].contract_fields[0].value.?);
        try std.testing.expectEqualStrings("theme", plan.tasks[0].contract_fields[1].name);
        try std.testing.expectEqualStrings("light", plan.tasks[0].contract_fields[1].value.?);
    }
    // Vista por nombre.
    {
        var plan = (LlmPlanner.deterministicUiPlan(allocator, "abre el explorador")).?;
        defer plan.deinit();
        try std.testing.expectEqualStrings("open_view", plan.tasks[0].contract_fields[0].value.?);
        try std.testing.expectEqualStrings("explorer", plan.tasks[0].contract_fields[1].value.?);
    }
    // Notificacion conserva el texto integro de la orden.
    {
        var plan = (LlmPlanner.deterministicUiPlan(allocator, "notifica cuando termine")).?;
        defer plan.deinit();
        try std.testing.expectEqualStrings("notify", plan.tasks[0].contract_fields[0].value.?);
        try std.testing.expectEqualStrings("notifica cuando termine", plan.tasks[0].contract_fields[1].value.?);
    }
    // Negativos: ordenes que NO son control de cabina no se coaccionan.
    try std.testing.expect(LlmPlanner.deterministicUiPlan(allocator, "crea un archivo hola.txt") == null);
    try std.testing.expect(LlmPlanner.deterministicUiPlan(allocator, "cambia el color del boton en styles.css") == null);
    try std.testing.expect(LlmPlanner.deterministicUiPlan(allocator, "hazme una app") == null);
    try std.testing.expect(LlmPlanner.deterministicUiPlan(allocator, "pon a prueba el modulo de pagos") == null);
}

test "D8: kind:clarify parses into a clarification plan" {
    const allocator = std.testing.allocator;
    var p = LlmPlanner.init(allocator, "dummy_catalog.db");
    p.test_response =
        \\{"kind":"clarify","understanding":"El usuario quiere una app pero no dice de que tipo",
        \\  "questions":[{"id":"app-type","text":"Que tipo de app?","options":["CLI","GUI"]},
        \\               {"id":"target-os","text":"Para que SO?","options":[]}]}
    ;
    const backend = p.backend();
    defer backend.deinit();

    var plan = try backend.plan(allocator, "hazme una app para organizar fotos", &.{}, null);
    defer plan.deinit();

    try std.testing.expect(plan.needsClarification());
    try std.testing.expectEqual(@as(usize, 0), plan.tasks.len);
    try std.testing.expectEqual(@as(usize, 2), plan.questions.len);
    try std.testing.expectEqualStrings("app-type", plan.questions[0].id);
    try std.testing.expectEqualStrings("Que tipo de app?", plan.questions[0].text);
    try std.testing.expectEqual(@as(usize, 2), plan.questions[0].options.len);
    try std.testing.expectEqualStrings("CLI", plan.questions[0].options[0]);
    try std.testing.expectEqualStrings("GUI", plan.questions[0].options[1]);
    try std.testing.expectEqual(@as(usize, 0), plan.questions[1].options.len);
    try std.testing.expect(std.mem.indexOf(u8, plan.understanding, "app") != null);
}

test "D8: clarify response past the round cap fails honestly" {
    const allocator = std.testing.allocator;
    var p = LlmPlanner.init(allocator, "dummy_catalog.db");
    p.test_response =
        \\{"kind":"clarify","understanding":"Sigue faltando contexto",
        \\  "questions":[{"id":"q1","text":"Una mas?","options":[]}]}
    ;
    p.clarify_rounds_used = MAX_CLARIFY_ROUNDS;
    const backend = p.backend();
    defer backend.deinit();

    try std.testing.expectError(
        error.ClarifyRoundsExhausted,
        backend.plan(allocator, "hazme una app", &.{}, null),
    );
}

test "D8: MockPlanner clarify fallback is capped too" {
    const allocator = std.testing.allocator;
    // Sin catálogo el LLM no responde y el plan cae al MockPlanner — que también
    // sabe pedir clarificación. El tope debe cortar el ciclo igual.
    var p = LlmPlanner.init(allocator, "nonexistent_catalog.db");
    p.clarify_rounds_used = MAX_CLARIFY_ROUNDS;
    const backend = p.backend();
    defer backend.deinit();

    try std.testing.expectError(
        error.ClarifyRoundsExhausted,
        backend.plan(allocator, "crea un proyecto", &.{}, null),
    );
}

test "D8: clarify below the cap still reaches the user" {
    const allocator = std.testing.allocator;
    var p = LlmPlanner.init(allocator, "dummy_catalog.db");
    p.test_response =
        \\{"kind":"clarify","understanding":"Ambiguo","questions":[{"id":"q1","text":"Cual?","options":["A","B"]}]}
    ;
    p.clarify_rounds_used = 1;
    const backend = p.backend();
    defer backend.deinit();

    var plan = try backend.plan(allocator, "hazme una app", &.{}, null);
    defer plan.deinit();
    try std.testing.expect(plan.needsClarification());
    try std.testing.expectEqual(@as(usize, 1), plan.questions.len);
}

test "D8: assemblePrompt injects clarification answers into the re-plan prompt" {
    const allocator = std.testing.allocator;
    const no_history = &[_]planner.ConversationTurn{};
    const answers = [_]planner.ClarificationAnswer{
        .{ .question_id = "target-language", .answer = "C" },
        .{ .question_id = "app-type", .answer = "CLI" },
    };
    const prompt = assemblePrompt(allocator, "", "crea un modulo", &answers, no_history, null, null, null, 0) orelse {
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(prompt);

    try std.testing.expect(std.mem.indexOf(u8, prompt, "RESPUESTA(target-language): C") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "RESPUESTA(app-type): CLI") != null);
}

test "D8: assemblePrompt advertises remaining and exhausted clarify rounds" {
    const allocator = std.testing.allocator;
    const no_answers = &[_]planner.ClarificationAnswer{};
    const no_history = &[_]planner.ConversationTurn{};

    const prompt1 = assemblePrompt(allocator, "", "crea un modulo", no_answers, no_history, null, null, null, 1) orelse {
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(prompt1);
    try std.testing.expect(std.mem.indexOf(u8, prompt1, "RONDAS DE CLARIFICACI") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt1, "1 de 2") != null);

    const prompt2 = assemblePrompt(allocator, "", "crea un modulo", no_answers, no_history, null, null, null, MAX_CLARIFY_ROUNDS) orelse {
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(prompt2);
    try std.testing.expect(std.mem.indexOf(u8, prompt2, "CLARIFICACI") != null);
    try std.testing.expect(std.mem.indexOf(u8, prompt2, "AGOTADA") != null);

    const prompt0 = assemblePrompt(allocator, "", "crea un modulo", no_answers, no_history, null, null, null, 0) orelse {
        try std.testing.expect(false);
        return;
    };
    defer allocator.free(prompt0);
    try std.testing.expect(std.mem.indexOf(u8, prompt0, "CLARIFICACI") == null);
}

test "ORDENES Hola without candidates always emits planner cause" {
    const a = std.testing.allocator;
    var runtime = try db.Connection.open(a, ":memory:");
    defer runtime.close();
    try db.Migrator.init(a).migrate(runtime, &db.runtime_schema);
    try runtime.exec("INSERT INTO orders(id,project_id,user_prompt,status,created_at) VALUES(77,'fixture','Hola','pending',1)");
    var lp = LlmPlanner.init(a, "nonexistent_catalog.db");
    lp.event_conn = runtime;
    lp.event_order_id = 77;
    var plan = try lp.backend().plan(a, "Hola", &.{}, null);
    defer plan.deinit();
    try std.testing.expect(plan.kind == .failed);
    try std.testing.expect(std.mem.indexOf(u8, plan.understanding, "clave activa") != null);
    const q = try runtime.prepare("SELECT payload_json FROM events WHERE kind='planner_fallback' AND order_id=77");
    defer runtime.finalize(q);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(q));
    const text = std.mem.span(db.c.sqlite3_column_text(q, 0));
    try std.testing.expect(std.mem.indexOf(u8, text, "clave activa") != null);
}

fn subscriptionFailFn(ctx: *anyopaque, allocator: std.mem.Allocator, system_prompt: []const u8, user_prompt: []const u8) error{OutOfMemory}!SubscriptionReply {
    _ = ctx;
    _ = system_prompt;
    _ = user_prompt;
    return .{
        .failure = try allocator.dupe(u8, "Codex (gpt-6.2-sol) no pudo planificar: CLI rechazada: binario escribible por otros usuarios"),
        .who = "Codex (gpt-6.2-sol)",
    };
}

test "CK-MOT-030 subscription planner failure offers retry or another model" {
    const a = std.testing.allocator;
    var lp = LlmPlanner.init(a, "nonexistent_catalog.db");
    lp.subscription = .{ .ctx = @ptrCast(&lp), .planFn = subscriptionFailFn };
    var plan = try lp.backend().plan(a, "documenta en un archivo nota.txt el ciclo del agua", &.{}, null);
    defer plan.deinit();
    try std.testing.expect(plan.kind == .failed);
    try std.testing.expect(std.mem.indexOf(u8, plan.understanding, "No pude planificar") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.understanding, "CLI rechazada") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.understanding, "Reintenta") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.understanding, "lenguaje objetivo") == null);
    try std.testing.expect(plan.questions.len == 0);
}
