const std = @import("std");
const model_router = @import("model_router.zig");
const contracts = @import("contracts.zig");

/// Backend de planificación del superagente (spec 009, FR-002/FR-007).
///
/// Produce el entendimiento de una orden, las preguntas de clarificación cuando
/// la orden es ambigua, y el grafo de tareas tipadas con sus contratos. Dos
/// implementaciones: `MockPlanner` (determinista, sin red, para tests y gate) y
/// (futuro) un `LlmPlanner` sobre los conectores F2 elegidos por el router F3.
pub const PlannerError = error{
    OutOfMemory,
    EmptyOrder,
    /// CLARIFY-CAP (D8): el modelo siguió pidiendo clarificaciones tras agotar
    /// las rondas permitidas. La orden falla de forma honesta en vez de ciclar
    /// preguntas para siempre.
    ClarifyRoundsExhausted,
};

/// Un campo de la interfaz de integración que la pieza producida debe cumplir.
/// Espejo declarativo de `contracts.Field` (se traduce a un `Contract` real al ensamblar).
pub const ContractField = struct {
    name: []const u8,
    field_type: contracts.FieldType,
    required: bool,
    /// P-EXEC-5: Valor ya resuelto para campos de transporte determinista
    /// (p.ej. el comando literal en una tarea `ejecutar`). Null en campos normales.
    value: ?[]const u8 = null,
};

/// Un turno de conversación dentro de la misma sesión (MEM-01).
/// Las cadenas son poseídas por quien gestiona el historial.
pub const ConversationTurn = struct {
    user: []const u8,
    agent: []const u8,
};

/// Buffer acotado de turnos previos. FIFO: al exceder el límite se evicta el
/// más antiguo. Cada texto se duplica y trunca a `max_bytes` para acotar memoria.
pub const ConversationHistory = struct {
    turns: std.ArrayListUnmanaged(ConversationTurn),

    pub const empty: ConversationHistory = .{ .turns = .empty };

    pub fn push(
        self: *ConversationHistory,
        allocator: std.mem.Allocator,
        user: []const u8,
        agent: []const u8,
        max_turns: usize,
        max_bytes: usize,
    ) !void {
        const u = try dupeTruncated(allocator, user, max_bytes);
        errdefer allocator.free(u);
        const a = try dupeTruncated(allocator, agent, max_bytes);
        errdefer allocator.free(a);

        if (self.turns.items.len == max_turns) {
            const oldest = self.turns.orderedRemove(0);
            allocator.free(oldest.user);
            allocator.free(oldest.agent);
        }
        try self.turns.append(allocator, .{ .user = u, .agent = a });
    }

    pub fn deinit(self: *ConversationHistory, allocator: std.mem.Allocator) void {
        for (self.turns.items) |t| {
            allocator.free(t.user);
            allocator.free(t.agent);
        }
        self.turns.deinit(allocator);
    }
};

pub fn dupeTruncated(allocator: std.mem.Allocator, text: []const u8, max_bytes: usize) ![]const u8 {
    if (text.len <= max_bytes) return allocator.dupe(u8, text);
    // Evita cortar un carácter UTF-8 por la mitad retrocediendo hasta el inicio
    // de un code point (byte que NO es continuación, es decir, top bits != 10).
    var end = max_bytes;
    while (end > 0) : (end -= 1) {
        if ((text[end] & 0xc0) != 0x80) break;
    }
    if (end == 0) end = max_bytes;
    return allocator.dupe(u8, text[0..end]);
}

/// Pregunta estructurada de clarificación (espejo de `/speckit.clarify`, FR-004).
pub const ClarificationQuestion = struct {
    id: []const u8,
    text: []const u8,
    options: [][]const u8,
};

/// Respuesta del usuario a una pregunta de clarificación.
pub const ClarificationAnswer = struct {
    question_id: []const u8,
    answer: []const u8,
};

/// Una tarea del plan: tipo de la taxonomía F3, departamento, contrato y dependencias.
pub const PlannedTask = struct {
    /// E5.23: imagen adjunta requerida; el motor lo fija antes del enrutado.
    needs_vision: bool = false,
    /// Id lógico dentro del plan (p. ej. "t1"); las dependencias lo referencian.
    id: []const u8,
    task_type: model_router.TaskType,
    department: []const u8,
    description: []const u8,
    contract_fields: []ContractField,
    /// Ids de tareas que deben completarse antes que esta.
    depends_on: [][]const u8,
    /// B1: archivos que la tarea produce. Lo declara el planificador; si viene
    /// vacío y el contrato trae `filename`, la tarea posee ese único archivo.
    owns: []const []const u8 = &.{},
    /// B1: entregable al que pertenecen los archivos de la tarea. Los
    /// productores del MISMO entregable se encadenan (cada uno ve el contenido
    /// real de sus hermanos antes de escribir); los de entregables distintos
    /// corren en paralelo. null = sin declarar: caen en el grupo implícito
    /// compartido, como antes de que existiera el campo.
    deliverable: ?[]const u8 = null,
};

/// Resultado de planificar: entendimiento + (preguntas | grafo de tareas).
/// Qué tipo de respuesta produjo el planificador. C-11: `tasks.len == 0` solo
/// no basta para distinguir «respondió charla» de «no pudo planificar» — un
/// plan fallido también trae 0 tareas y cerrarlo `done` sería falso éxito.
pub const PlanKind = enum {
    /// Plan de trabajo normal (tasks.len > 0; 0 tareas aquí = planificador roto).
    build,
    /// Respuesta conversacional deliberada (kind:"chat" del LLM o coerción por
    /// intención conversacional): la orden cierra `done` con el reply.
    chat,
    /// Clarificación estructurada (questions.len > 0).
    clarify,
    /// El planificador no pudo producir nada: la orden cierra `failed`.
    failed,
};

/// Si `questions.len > 0`, el plan está incompleto y el superagente debe clarificar
/// antes de generar tareas (Principio constitucional: nunca adivinar).
pub const Plan = struct {
    allocator: std.mem.Allocator,
    understanding: []const u8,
    questions: []ClarificationQuestion,
    tasks: []PlannedTask,
    /// C-11: discriminador del caso 0-tareas. Por defecto `build` — todo
    /// constructor existente (MockPlanner, planes deterministas, tests) produce
    /// planes de trabajo; solo el LLM/llm_planner marca chat/clarify/failed.
    kind: PlanKind = .build,
    failure_cause: enum { none, paid_budget_exhausted } = .none,

    pub fn deinit(self: *Plan) void {
        const a = self.allocator;
        a.free(self.understanding);
        for (self.questions) |q| {
            a.free(q.id);
            a.free(q.text);
            for (q.options) |o| a.free(o);
            a.free(q.options);
        }
        a.free(self.questions);
        for (self.tasks) |t| {
            a.free(t.id);
            a.free(t.department);
            a.free(t.description);
            for (t.contract_fields) |f| {
                a.free(f.name);
                if (f.value) |v| a.free(v);
            }
            a.free(t.contract_fields);
            for (t.depends_on) |d| a.free(d);
            a.free(t.depends_on);
            for (t.owns) |o| a.free(o);
            if (t.owns.len > 0) a.free(t.owns);
            if (t.deliverable) |d| a.free(d);
        }
        a.free(self.tasks);
    }

    pub fn needsClarification(self: *const Plan) bool {
        return self.questions.len > 0;
    }
};

pub const PlanEstimation = struct {
    estimated_tokens: u64,
    estimated_cost_usd: f64,
    estimated_time_ms: u64,
    task_count: usize,
    exceeds_budget: bool,
};

pub fn estimatePlan(plan: *const Plan, max_task_budget: usize) PlanEstimation {
    const count = plan.tasks.len;
    const tokens = @as(u64, count) * 3000;
    const cost = @as(f64, @floatFromInt(count)) * 0.006;
    const time_ms = @as(u64, count) * 4000;
    const exceeds = count > max_task_budget;
    return .{
        .estimated_tokens = tokens,
        .estimated_cost_usd = cost,
        .estimated_time_ms = time_ms,
        .task_count = count,
        .exceeds_budget = exceeds,
    };
}

/// Interfaz (vtable) de planificación. Permite intercambiar mock/LLM sin tocar el superagente.
pub const PlannerBackend = struct {
    ptr: *anyopaque,
    planFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, order_text: []const u8, answers: []const ClarificationAnswer, memory_context: ?[]const u8) PlannerError!Plan,
    deinitFn: *const fn (ctx: *anyopaque) void,

    pub fn plan(self: PlannerBackend, allocator: std.mem.Allocator, order_text: []const u8, answers: []const ClarificationAnswer, memory_context: ?[]const u8) PlannerError!Plan {
        return self.planFn(self.ptr, allocator, order_text, answers, memory_context);
    }

    pub fn deinit(self: PlannerBackend) void {
        self.deinitFn(self.ptr);
    }
};

const LANGUAGE_QUESTION_ID = "target-language";

/// BUG-2: ¿la orden pide un DOCUMENTO en vez de codigo?
///
/// Mismo criterio que `isBuildIntent` de `llm_planner`: no basta el verbo, hace
/// falta que el usuario nombre un ENTREGABLE. «¿Cuales son los riesgos?» es una
/// pregunta; «documenta en un TEXTO los riesgos» pide un archivo. Sin el
/// entregable nombrado se sigue preguntando el lenguaje, que es lo correcto
/// para una orden de codigo mal especificada.
fn detectProseIntent(lower: []const u8) bool {
    const verbos = [_][]const u8{
        "documenta", "documentar", "redacta",   "redactar",
        "resume",    "resumir",    "audita",    "auditar",
        "analiza",   "analizar",   "investiga", "investigar",
        // «crea/escribe 32 archivos de texto» no es una orden de
        // código — sin estos verbos caía en la pregunta de lenguaje (C/C++/Zig).
        "escribe",   "escribir",   "crea",      "crear",
        "genera",    "generar",    "produce",   "producir",
        "prepara",   "preparar",
    };
    var hay_verbo = false;
    for (verbos) |v| {
        if (std.mem.indexOf(u8, lower, v) != null) {
            hay_verbo = true;
            break;
        }
    }
    if (!hay_verbo) return false;

    const entregables = [_][]const u8{
        "texto",     "documento", "informe",   "reporte",
        "resumen",   "guia",
        "guía",
        "manual",    "readme",    "changelog", "analisis",
        "análisis",
        "auditoria",
        "auditoría",
    };
    for (entregables) |e| {
        if (std.mem.indexOf(u8, lower, e) != null) return true;
    }
    return false;
}

/// BUG-2: la unica tarea de una orden de prosa. El tipo `documentar` es el que
/// hace que `workspace` le ponga `.md`/`.txt` y nunca extension de codigo (S9).
fn buildProseTasks(allocator: std.mem.Allocator, order_text: []const u8) PlannerError![]PlannedTask {
    const tasks = try allocator.alloc(PlannedTask, 1);
    errdefer allocator.free(tasks);
    const fields = try allocator.alloc(ContractField, 1);
    errdefer allocator.free(fields);
    fields[0] = .{ .name = try allocator.dupe(u8, "source"), .field_type = .string, .required = true };
    tasks[0] = .{
        .id = try allocator.dupe(u8, "t1"),
        .task_type = .documentar,
        .department = try allocator.dupe(u8, "documentacion"),
        .description = try allocator.dupe(u8, order_text),
        .contract_fields = fields,
        .depends_on = try allocator.alloc([]const u8, 0),
    };
    return tasks;
}

/// Planificador determinista (sin red). Detecta el lenguaje objetivo y el criterio
/// de pruebas a partir del texto; si falta el lenguaje, pregunta en lugar de adivinar.
/// Mismo texto + mismas respuestas → mismo plan (idempotente, testeable).
pub const MockPlanner = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) MockPlanner {
        return .{ .allocator = allocator };
    }

    pub fn backend(self: *MockPlanner) PlannerBackend {
        return .{ .ptr = self, .planFn = planImpl, .deinitFn = noopDeinit };
    }

    fn noopDeinit(_: *anyopaque) void {}

    fn planImpl(ctx: *anyopaque, allocator: std.mem.Allocator, order_text: []const u8, answers: []const ClarificationAnswer, memory_context: ?[]const u8) PlannerError!Plan {
        _ = memory_context;
        _ = ctx;
        const trimmed = std.mem.trim(u8, order_text, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyOrder;

        // Fast Context pertenece al workspace, no a la intención del usuario. Si se
        // incluye en la detección, un build.zig del proyecto convierte erróneamente
        // cualquier solicitud explícita en Go/Python/etc. a programar_zig.
        const intent_text = stripFastContextPrefix(trimmed);
        const lower = try std.ascii.allocLowerString(allocator, intent_text);
        defer allocator.free(lower);

        // P09-T3: Detect design intent before language detection.
        // Design orders go to OpenDesign via the bridge MCP, not to code generation.
        if (detectDesignIntent(lower)) {
            const excerpt = orderExcerpt(trimmed);
            const understanding = try std.fmt.allocPrint(
                allocator,
                "Orden: \"{s}{s}\". Objetivo: diseño en OpenDesign. Estrategia: generar prompt de diseño, ejecutar via bridge MCP y auditar resultado.",
                .{ excerpt, if (excerpt.len < trimmed.len) "…" else "" },
            );
            errdefer allocator.free(understanding);
            const tasks = try buildDesignTasks(allocator, trimmed);
            return .{
                .allocator = allocator,
                .understanding = understanding,
                .questions = try allocator.alloc(ClarificationQuestion, 0),
                .tasks = tasks,
            };
        }

        // Lenguaje: del texto o de una respuesta de clarificación previa.
        var lang: ?model_router.TaskType = detectLanguage(lower);
        if (lang == null) {
            for (answers) |ans| {
                if (std.mem.eql(u8, ans.question_id, LANGUAGE_QUESTION_ID)) {
                    const al = try std.ascii.allocLowerString(allocator, ans.answer);
                    defer allocator.free(al);
                    lang = detectLanguage(al);
                }
            }
        }

        const understanding = try buildUnderstanding(allocator, trimmed, lang);
        errdefer allocator.free(understanding);

        // BUG-2 (2026-08-12): un DOCUMENTO no tiene lenguaje de programacion.
        //
        // «Documenta brevemente en un texto los riesgos de guardar claves de API
        // en texto plano» acababa en `clarifying` ofreciendo C / C++ / Zig, y la
        // orden se quedaba esperando una respuesta que no existe: cero archivos
        // entregados. Lo cazo el gate de aceptacion (caso `prosa`).
        //
        // Preguntar el lenguaje solo tiene sentido si lo que se pide es CODIGO.
        // Si la orden pide prosa, se planifica prosa y no se pregunta nada.
        if (lang == null and detectProseIntent(lower)) {
            const tasks = try buildProseTasks(allocator, trimmed);
            return .{
                .allocator = allocator,
                .understanding = understanding,
                .questions = try allocator.alloc(ClarificationQuestion, 0),
                .tasks = tasks,
            };
        }

        // Ambigüedad: sin lenguaje objetivo → 1 pregunta, sin generar tareas.
        if (lang == null) {
            var questions = try allocator.alloc(ClarificationQuestion, 1);
            errdefer allocator.free(questions);
            const opts = try allocator.alloc([]const u8, 3);
            errdefer allocator.free(opts);
            opts[0] = try allocator.dupe(u8, "C");
            opts[1] = try allocator.dupe(u8, "C++");
            opts[2] = try allocator.dupe(u8, "Zig");
            questions[0] = .{
                .id = try allocator.dupe(u8, LANGUAGE_QUESTION_ID),
                .text = try allocator.dupe(u8, "¿En qué lenguaje objetivo debe implementarse? (C, C++ o Zig)"),
                .options = opts,
            };
            return .{
                .allocator = allocator,
                .understanding = understanding,
                .questions = questions,
                .tasks = try allocator.alloc(PlannedTask, 0),
            };
        }

        const wants_tests = std.mem.indexOf(u8, lower, "test") != null or std.mem.indexOf(u8, lower, "prueba") != null;
        const tasks = try buildTasks(allocator, lang.?, wants_tests, trimmed);
        return .{
            .allocator = allocator,
            .understanding = understanding,
            .questions = try allocator.alloc(ClarificationQuestion, 0),
            .tasks = tasks,
        };
    }

    fn buildUnderstanding(allocator: std.mem.Allocator, order: []const u8, lang: ?model_router.TaskType) PlannerError![]const u8 {
        const lang_text = if (lang) |l| l.toText() else "lenguaje sin determinar";
        const excerpt = orderExcerpt(order);
        return std.fmt.allocPrint(
            allocator,
            "Orden: \"{s}{s}\". Objetivo: {s}. Estrategia: implementar, probar y auditar como piezas con contrato.",
            .{ excerpt, if (excerpt.len < order.len) "…" else "", lang_text },
        );
    }

    fn buildTasks(allocator: std.mem.Allocator, lang: model_router.TaskType, wants_tests: bool, order: []const u8) PlannerError![]PlannedTask {
        var list = std.ArrayList(PlannedTask).empty;
        errdefer {
            for (list.items) |t| freeTask(allocator, t);
            list.deinit(allocator);
        }

        // t1: implementación (contrato: source + exit_code).
        // FIRE-2026-07-10: exit_code ya NO es requerido. Un LLM no puede CONOCER el
        // exit code sin ejecutar nada — exigirlo convertía la integración en lotería:
        // si el modelo lo inventaba ("exit_code":0) la tarea pasaba (falso-verde por
        // dictado); si respondía solo el código (p.ej. gemini con fence), el rescate
        // artifactsFromRawProgrammingResponse produce SOLO 'source' → campo requerido
        // ausente → validatePieceForTask false → "Integración por contrato: rechazada"
        // → tarea fallida aunque el código existiera y fuera correcto (órdenes 316,
        // 325, 327, 330: el reloj en python moría aquí con CUALQUIER proveedor).
        // La verificación real del código la hacen las puertas del motor (ejecución
        // gobernada, isContentTriviallyInvalid, auto-auditoría), no un número dictado.
        {
            const cf = try allocator.alloc(ContractField, 2);
            errdefer allocator.free(cf);
            cf[0] = .{ .name = try allocator.dupe(u8, "source"), .field_type = .string, .required = true };
            cf[1] = .{ .name = try allocator.dupe(u8, "exit_code"), .field_type = .integer, .required = false };
            try list.append(allocator, .{
                .id = try allocator.dupe(u8, "t1"),
                .task_type = lang,
                .department = try allocator.dupe(u8, "programacion"),
                .description = try std.fmt.allocPrint(allocator, "Implementar la solución conforme a la orden: {s}", .{order}),
                .contract_fields = cf,
                .depends_on = try allocator.alloc([]const u8, 0),
            });
        }

        // t2: pruebas, dependientes de t1 (solo si la orden las pide).
        if (wants_tests) {
            const cf = try allocator.alloc(ContractField, 1);
            errdefer allocator.free(cf);
            // FIRE-2026-07-10: misma lógica que exit_code — un número dictado por el
            // LLM no es evidencia de tests; exigirlo solo producía rechazos aleatorios.
            cf[0] = .{ .name = try allocator.dupe(u8, "tests_passed"), .field_type = .integer, .required = false };
            const dep = try allocator.alloc([]const u8, 1);
            errdefer allocator.free(dep);
            dep[0] = try allocator.dupe(u8, "t1");
            try list.append(allocator, .{
                .id = try allocator.dupe(u8, "t2"),
                .task_type = .testear,
                .department = try allocator.dupe(u8, "testing"),
                .description = try allocator.dupe(u8, "Escribir y ejecutar pruebas de la implementación"),
                .contract_fields = cf,
                .depends_on = dep,
            });
        }

        // t3: auditoría, dependiente de t1.
        {
            const cf = try allocator.alloc(ContractField, 1);
            errdefer allocator.free(cf);
            cf[0] = .{ .name = try allocator.dupe(u8, "verdict"), .field_type = .string, .required = true };
            const dep = try allocator.alloc([]const u8, 1);
            errdefer allocator.free(dep);
            dep[0] = try allocator.dupe(u8, "t1");
            try list.append(allocator, .{
                .id = try allocator.dupe(u8, "t3"),
                .task_type = .auditar,
                .department = try allocator.dupe(u8, "auditoria"),
                .description = try allocator.dupe(u8, "Auditar la implementación por un modelo distinto al constructor"),
                .contract_fields = cf,
                .depends_on = dep,
            });
        }

        return list.toOwnedSlice(allocator);
    }
};

fn freeTask(allocator: std.mem.Allocator, t: PlannedTask) void {
    allocator.free(t.id);
    allocator.free(t.department);
    allocator.free(t.description);
    for (t.contract_fields) |f| {
        allocator.free(f.name);
        if (f.value) |v| allocator.free(v);
    }
    allocator.free(t.contract_fields);
    for (t.depends_on) |d| allocator.free(d);
    allocator.free(t.depends_on);
}

/// P09-T3: Detecta intención de diseño en texto ya en minúsculas.
/// Palabras clave: diseña/diseño/diseñar, logo, banner, mockup, ui, ux, layout,
/// open design, opendesign, prototipo, wireframe, figma-like.
fn detectDesignIntent(lower: []const u8) bool {
    // Artefacto de diseño explícito: gana siempre, aunque la orden también
    // mencione software («mockup de la app» sigue siendo un trabajo de diseño).
    if (std.mem.indexOf(u8, lower, "open design") != null) return true;
    if (std.mem.indexOf(u8, lower, "opendesign") != null) return true;
    if (containsWord(lower, "mockup")) return true;
    if (containsWord(lower, "wireframe")) return true;
    if (containsWord(lower, "prototipo")) return true;
    if (containsWord(lower, "banner")) return true;
    // Una orden que pide construir un artefacto de software —página web, sitio,
    // app, código— menciona «logo» y «diseño» como ATRIBUTOS, no como
    // entregable. Enviarla a OpenDesign producía un plan de prompt de imagen
    // para una orden de construcción web (incidencia del plan local).
    if (mentionsSoftwareArtifact(lower)) return false;
    if (containsWord(lower, "diseña") or containsWord(lower, "diseño") or containsWord(lower, "diseñar")) return true;
    if (containsWord(lower, "diseñe") or containsWord(lower, "diseñado")) return true;
    if (containsWord(lower, "logo")) return true;
    if (containsWord(lower, "layout")) return true;
    if (containsWord(lower, "ui") and containsWord(lower, "diseño")) return true;
    if (containsWord(lower, "ux") and containsWord(lower, "diseño")) return true;
    return false;
}

/// La orden pide un artefacto de software construido (web, app, código), no una
/// pieza gráfica. Lista corta y deliberada: solo marcadores inequívocos.
fn mentionsSoftwareArtifact(lower: []const u8) bool {
    const markers = [_][]const u8{
        "página web",
        "pagina web",
        "sitio web",
        "website",
        "landing",
        "html",
        "css",
        "javascript",
        "aplicación web",
        "aplicacion web",
        "app web",
        "web app",
        "tienda online",
        "e-commerce",
        "ecommerce",
    };
    for (markers) |m| {
        if (std.mem.indexOf(u8, lower, m) != null) return true;
    }
    return false;
}

/// P09-T3: Construye el grafo de tareas para una orden de diseño.
/// t1: Generar prompt de diseño y llamar al bridge MCP de OpenDesign.
/// t2: Auditar el resultado del diseño.
fn buildDesignTasks(allocator: std.mem.Allocator, order: []const u8) PlannerError![]PlannedTask {
    var list = std.ArrayList(PlannedTask).empty;
    errdefer {
        for (list.items) |t| freeTask(allocator, t);
        list.deinit(allocator);
    }

    // t1: diseño — el worker LLM genera el prompt y lo ejecuta via mcp_call_tool.
    // Contract: `prompt` (el prompt de diseño generado por el LLM) + `result` (URL/artefacto).
    {
        const cf = try allocator.alloc(ContractField, 2);
        errdefer allocator.free(cf);
        cf[0] = .{ .name = try allocator.dupe(u8, "prompt"), .field_type = .string, .required = true };
        cf[1] = .{ .name = try allocator.dupe(u8, "result"), .field_type = .string, .required = true };
        try list.append(allocator, .{
            .id = try allocator.dupe(u8, "t1"),
            .task_type = .disenar,
            .department = try allocator.dupe(u8, "diseno"),
            .description = try std.fmt.allocPrint(allocator, "Diseñar en OpenDesign conforme a la orden: {s}", .{order}),
            .contract_fields = cf,
            .depends_on = try allocator.alloc([]const u8, 0),
        });
    }

    // t2: auditoría del diseño, dependiente de t1.
    {
        const cf = try allocator.alloc(ContractField, 1);
        errdefer allocator.free(cf);
        cf[0] = .{ .name = try allocator.dupe(u8, "verdict"), .field_type = .string, .required = true };
        const dep = try allocator.alloc([]const u8, 1);
        errdefer allocator.free(dep);
        dep[0] = try allocator.dupe(u8, "t1");
        try list.append(allocator, .{
            .id = try allocator.dupe(u8, "t2"),
            .task_type = .auditar,
            .department = try allocator.dupe(u8, "auditoria"),
            .description = try allocator.dupe(u8, "Auditar el resultado del diseño por un modelo distinto al constructor"),
            .contract_fields = cf,
            .depends_on = dep,
        });
    }

    return list.toOwnedSlice(allocator);
}

/// Extracto acotado de la orden para incrustarlo en textos de DISPLAY
/// (`understanding`). Un prompt puede tener miles de caracteres — la orden del
/// negocio con sus tres carpetas opacaba la pantalla entera como
/// «entendimiento». El texto completo vive en orders.text y en el hilo; aquí
/// solo hace falta reconocer de qué orden se habla. Corta en un límite de
/// palabra cercano para no partir términos a la mitad.
fn orderExcerpt(order: []const u8) []const u8 {
    const MAX: usize = 220;
    if (order.len <= MAX) return order;
    // No cortar una secuencia UTF-8 por la mitad: retrocede hasta un byte
    // que no sea de continuación (10xxxxxx).
    var cut: usize = MAX;
    while (cut > 0 and (order[cut] & 0xC0) == 0x80) cut -= 1;
    return order[0..cut];
}

/// Detecta el lenguaje objetivo en texto ya en minúsculas. Orden: específicos primero,
/// luego genéricos. Si reconoce un lenguaje sin TaskType dedicado (p. ej. Python, JS,
/// Go, Rust...), devuelve `.programar` para que el plan se genere sin clarificación
/// innecesaria (el lenguaje concreto va en la descripción de la tarea).
fn detectLanguage(lower: []const u8) ?model_router.TaskType {
    if (containsWord(lower, "zig")) return .programar_zig;
    if (std.mem.indexOf(u8, lower, "c++") != null or containsWord(lower, "cpp")) return .programar_cpp;
    // «c#»/«csharp» antes que la «c» suelta: si no, C# se clasificaba como C.
    if (std.mem.indexOf(u8, lower, "c#") != null or containsWord(lower, "csharp")) return .programar;
    if (containsWord(lower, "c")) return .programar_c;
    // Stacks web explícitos («Solo HTML+CSS+JS», «página web», «landing»):
    // reutiliza los marcadores inequívocos del veto de diseño. Sin esto la
    // orden #598 acabó en `clarifying` ofreciendo C/C++/Zig — además el '+'
    // une tokens y rompe la frontera de palabra de «js» en «css+js».
    if (mentionsSoftwareArtifact(lower)) return .programar;
    // Genéricos: reconocidos para no ignorar la respuesta del usuario (FIX D.2).
    const generic = [_][]const u8{
        "python",  "typescript", "javascript", "rust",       "go",          "golang",
        "java",    "php",        "ruby",       "swift",      "kotlin",      "dart",
        "lua",     "perl",       "bash",       "powershell", "sql",         "scala",
        "haskell", "elixir",     "matlab",     "assembly",   "ensamblador",
    };
    for (generic) |w| {
        if (containsWord(lower, w)) return .programar;
    }
    if (std.mem.indexOf(u8, lower, ".py") != null) return .programar;
    // El '+' separa stacks («html+js»); isWordChar lo trata como parte de la
    // palabra (necesario para «c++»), así que estas formas van por subcadena.
    if (std.mem.indexOf(u8, lower, ".js") != null or std.mem.indexOf(u8, lower, "+js") != null or std.mem.indexOf(u8, lower, "js+") != null) return .programar;
    if (std.mem.indexOf(u8, lower, ".ts") != null or std.mem.indexOf(u8, lower, "+ts") != null or std.mem.indexOf(u8, lower, "ts+") != null) return .programar;
    if (containsWord(lower, "js") or containsWord(lower, "ts")) return .programar;
    return null;
}

fn stripFastContextPrefix(text: []const u8) []const u8 {
    const prefixes = [_][]const u8{
        "[Contexto:",
        "[Archivos abiertos:",
        "[Estructura del proyecto:",
        "[Selecci",
    };
    var current = std.mem.trim(u8, text, " \t\r\n");
    while (current.len > 0 and current[0] == '[') {
        var recognized = false;
        for (prefixes) |prefix| {
            if (std.mem.startsWith(u8, current, prefix)) {
                recognized = true;
                break;
            }
        }
        if (!recognized) break;
        const close = std.mem.indexOfScalar(u8, current, ']') orelse break;
        current = std.mem.trim(u8, current[close + 1 ..], " \t\r\n");
    }
    return current;
}

/// Coincidencia de palabra completa (evita que "c" matchee dentro de "calculadora").
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

fn isWordChar(ch: u8) bool {
    // Todo byte no ASCII pertenece a una secuencia UTF-8 y, para efectos de
    // frontera, debe tratarse como parte de la palabra. De lo contrario la `c`
    // de "código" parecía el lenguaje C porque el siguiente byte de `ó` (0xC3)
    // se clasificaba erróneamente como separador.
    return ch >= 0x80 or (ch >= 'a' and ch <= 'z') or (ch >= 'A' and ch <= 'Z') or (ch >= '0' and ch <= '9') or ch == '+';
}

// ── Tests ──────────────────────────────────────────────────────────────

test "mock planner asks for language when ambiguous" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const backend = mp.backend();
    defer backend.deinit();

    var plan = try backend.plan(allocator, "haz un programa que sume numeros", &.{}, null);
    defer plan.deinit();

    try std.testing.expect(plan.needsClarification());
    try std.testing.expectEqual(@as(usize, 1), plan.questions.len);
    try std.testing.expectEqualStrings("target-language", plan.questions[0].id);
    try std.testing.expectEqual(@as(usize, 0), plan.tasks.len);
}

test "mock planner builds task graph for explicit C order with tests" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const backend = mp.backend();
    defer backend.deinit();

    var plan = try backend.plan(allocator, "construye una calculadora CLI en C con tests", &.{}, null);
    defer plan.deinit();

    try std.testing.expect(!plan.needsClarification());
    try std.testing.expectEqual(@as(usize, 3), plan.tasks.len);
    try std.testing.expectEqual(model_router.TaskType.programar_c, plan.tasks[0].task_type);
    try std.testing.expectEqual(model_router.TaskType.testear, plan.tasks[1].task_type);
    try std.testing.expectEqual(model_router.TaskType.auditar, plan.tasks[2].task_type);
    // La auditoría depende de la implementación.
    try std.testing.expectEqual(@as(usize, 1), plan.tasks[2].depends_on.len);
    try std.testing.expectEqualStrings("t1", plan.tasks[2].depends_on[0]);
}

test "mock planner resolves ambiguity via clarification answer" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const backend = mp.backend();
    defer backend.deinit();

    const answers = [_]ClarificationAnswer{
        .{ .question_id = "target-language", .answer = "Zig" },
    };
    var plan = try backend.plan(allocator, "haz un parser", &answers, null);
    defer plan.deinit();

    try std.testing.expect(!plan.needsClarification());
    try std.testing.expectEqual(model_router.TaskType.programar_zig, plan.tasks[0].task_type);
}

test "mock planner is deterministic" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const backend = mp.backend();
    defer backend.deinit();

    var p1 = try backend.plan(allocator, "escribe una libreria en zig con pruebas", &.{}, null);
    defer p1.deinit();
    var p2 = try backend.plan(allocator, "escribe una libreria en zig con pruebas", &.{}, null);
    defer p2.deinit();

    try std.testing.expectEqual(p1.tasks.len, p2.tasks.len);
    try std.testing.expectEqualStrings(p1.understanding, p2.understanding);
}

test "mock planner propagates python from clarification answer to plan" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const backend = mp.backend();
    defer backend.deinit();

    // Orden inicial ambigua (sin lenguaje reconocido en texto).
    var plan1 = try backend.plan(allocator, "haz un programa que sume numeros", &.{}, null);
    defer plan1.deinit();
    try std.testing.expect(plan1.needsClarification());

    // Respuesta "Python" debe propagarse y generar plan sin nueva clarificación.
    const answers = [_]ClarificationAnswer{
        .{ .question_id = "target-language", .answer = "Python" },
    };
    var plan2 = try backend.plan(allocator, "haz un programa que sume numeros", &answers, null);
    defer plan2.deinit();
    try std.testing.expect(!plan2.needsClarification());
    try std.testing.expectEqual(model_router.TaskType.programar, plan2.tasks[0].task_type);
}

test "mock planner infiere python desde extension py" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const backend = mp.backend();
    defer backend.deinit();

    var plan = try backend.plan(allocator, "crea primos.py", &.{}, null);
    defer plan.deinit();

    try std.testing.expect(!plan.needsClarification());
    try std.testing.expectEqual(model_router.TaskType.programar, plan.tasks[0].task_type);
}

test "E2E-RESULT: MockPlanner prioriza el lenguaje del usuario sobre Fast Context" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const backend = mp.backend();
    defer backend.deinit();

    var plan = try backend.plan(
        allocator,
        "[Estructura del proyecto: agents/, build.zig, catalog.db]\n\nCrea código en Go para un reloj analógico y ejecútalo",
        &.{},
        null,
    );
    defer plan.deinit();

    try std.testing.expect(!plan.needsClarification());
    try std.testing.expectEqual(model_router.TaskType.programar, plan.tasks[0].task_type);
}

test "mock planner rejects empty order" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const backend = mp.backend();
    defer backend.deinit();
    try std.testing.expectError(error.EmptyOrder, backend.plan(allocator, "   ", &.{}, null));
}

test "mock planner omits tests when not requested" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const backend = mp.backend();
    defer backend.deinit();

    var plan = try backend.plan(allocator, "implementa un servidor en zig", &.{}, null);
    defer plan.deinit();

    // Sin "test"/"prueba" → solo implementación + auditoría.
    try std.testing.expectEqual(@as(usize, 2), plan.tasks.len);
    try std.testing.expectEqual(model_router.TaskType.programar_zig, plan.tasks[0].task_type);
    try std.testing.expectEqual(model_router.TaskType.auditar, plan.tasks[1].task_type);
}

test "ConversationHistory keeps last N turns in FIFO order" {
    const allocator = std.testing.allocator;
    var h = ConversationHistory.empty;
    defer h.deinit(allocator);

    for (0..10) |i| {
        const u = try std.fmt.allocPrint(allocator, "user {d}", .{i});
        const a = try std.fmt.allocPrint(allocator, "agent {d}", .{i});
        defer allocator.free(u);
        defer allocator.free(a);
        try h.push(allocator, u, a, 3, 2048);
    }

    try std.testing.expectEqual(@as(usize, 3), h.turns.items.len);
    try std.testing.expectEqualStrings("user 7", h.turns.items[0].user);
    try std.testing.expectEqualStrings("agent 7", h.turns.items[0].agent);
    try std.testing.expectEqualStrings("user 9", h.turns.items[2].user);
}

test "ConversationHistory truncates turn text to max bytes" {
    const allocator = std.testing.allocator;
    var h = ConversationHistory.empty;
    defer h.deinit(allocator);

    const long = try allocator.alloc(u8, 3000);
    defer allocator.free(long);
    @memset(long, 'a');

    try h.push(allocator, long, "short", 8, 2048);
    try std.testing.expectEqual(@as(usize, 2048), h.turns.items[0].user.len);
    try std.testing.expectEqualStrings("short", h.turns.items[0].agent);
}

test "P09: mock planner detects design intent for 'diseña un logo'" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const backend = mp.backend();
    defer backend.deinit();

    var plan = try backend.plan(allocator, "diseña un logo para mi empresa", &.{}, null);
    defer plan.deinit();

    try std.testing.expect(!plan.needsClarification());
    try std.testing.expectEqual(@as(usize, 2), plan.tasks.len);
    try std.testing.expectEqual(model_router.TaskType.disenar, plan.tasks[0].task_type);
    try std.testing.expectEqualStrings("diseno", plan.tasks[0].department);
    try std.testing.expectEqual(model_router.TaskType.auditar, plan.tasks[1].task_type);
    // Auditoría depende del diseño.
    try std.testing.expectEqual(@as(usize, 1), plan.tasks[1].depends_on.len);
    try std.testing.expectEqualStrings("t1", plan.tasks[1].depends_on[0]);
}

test "P09: mock planner detects design intent for 'mockup wireframe'" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const backend = mp.backend();
    defer backend.deinit();

    var plan = try backend.plan(allocator, "crea un mockup wireframe de la app", &.{}, null);
    defer plan.deinit();

    try std.testing.expect(!plan.needsClarification());
    try std.testing.expectEqual(model_router.TaskType.disenar, plan.tasks[0].task_type);
}

test "P09: website order with logo and design words is a BUILD order, not OpenDesign" {
    // Incidencia real: «crea una página web… usa el logo… diseño elegante»
    // caía en la rama OpenDesign por las palabras logo/diseño, y el plan era
    // generar un prompt de imagen + auditarlo — no construir la web pedida.
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const backend = mp.backend();
    defer backend.deinit();

    const order = "Crea una página web profesional y responsive para mi negocio con HTML, CSS y JavaScript. Usa el logo real, respeta la paleta de colores, y que el diseño sea elegante.";
    var plan = try backend.plan(allocator, order, &.{}, null);
    defer plan.deinit();

    try std.testing.expect(!plan.needsClarification());
    for (plan.tasks) |t| {
        try std.testing.expect(t.task_type != .disenar);
        try std.testing.expect(!std.mem.eql(u8, t.department, "diseno"));
    }
}

test "P09: mock planner does NOT detect design intent for programming order" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const backend = mp.backend();
    defer backend.deinit();

    var plan = try backend.plan(allocator, "implementa un servidor en zig", &.{}, null);
    defer plan.deinit();

    try std.testing.expect(!plan.needsClarification());
    try std.testing.expectEqual(model_router.TaskType.programar_zig, plan.tasks[0].task_type);
}

test "F8-T1: estimatePlan calculates tokens cost time and detects budget limit" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const backend = mp.backend();
    defer backend.deinit();

    var plan = try backend.plan(allocator, "construye una calculadora CLI en C con tests", &.{}, null);
    defer plan.deinit();

    const est = estimatePlan(&plan, 2);
    try std.testing.expectEqual(@as(usize, 3), est.task_count);
    try std.testing.expectEqual(@as(u64, 9000), est.estimated_tokens);
    try std.testing.expect(est.estimated_cost_usd > 0.01);
    try std.testing.expectEqual(@as(u64, 12000), est.estimated_time_ms);
    try std.testing.expect(est.exceeds_budget);

    const est2 = estimatePlan(&plan, 10);
    try std.testing.expect(!est2.exceeds_budget);
}

// ── BUG-2: un documento no tiene lenguaje de programacion ─────────────────

test "BUG-2: pedir un documento NO pregunta el lenguaje, y planifica prosa" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const pb = mp.backend();
    defer pb.deinit();

    // El caso exacto del gate: acababa en `clarifying` ofreciendo C / C++ / Zig
    // y la orden se quedaba esperando una respuesta que no existe.
    var plan = try pb.plan(allocator, "Documenta brevemente en un texto los riesgos de guardar claves de API en texto plano", &.{}, null);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 0), plan.questions.len);
    try std.testing.expectEqual(@as(usize, 1), plan.tasks.len);
    // `documentar` es lo que hace que workspace le ponga .md/.txt (S9).
    try std.testing.expectEqual(model_router.TaskType.documentar, plan.tasks[0].task_type);
}

test "BUG-2: una orden de CODIGO sin lenguaje sigue preguntando" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const pb = mp.backend();
    defer pb.deinit();

    // Sin entregable de prosa nombrado, preguntar el lenguaje es lo correcto:
    // es una orden de codigo mal especificada.
    var plan = try pb.plan(allocator, "Crea una calculadora", &.{}, null);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), plan.questions.len);
    try std.testing.expectEqualStrings("target-language", plan.questions[0].id);
}

test "CK-MOT-030: «archivos de texto» es prosa, no pregunta de lenguaje" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const pb = mp.backend();
    defer pb.deinit();

    // El caso de la orden #897: 32 archivos de texto independientes. Antes
    // «crea» no era verbo de prosa y la orden caía en la pregunta C/C++/Zig.
    var plan = try pb.plan(allocator, "Crea 32 archivos de texto independientes sobre el mar", &.{}, null);
    defer plan.deinit();

    try std.testing.expectEqual(@as(usize, 0), plan.questions.len);
    try std.testing.expectEqual(@as(usize, 1), plan.tasks.len);
    try std.testing.expectEqual(model_router.TaskType.documentar, plan.tasks[0].task_type);
}

test "BUG-2: una PREGUNTA no se convierte en documento" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const pb = mp.backend();
    defer pb.deinit();

    // Sin verbo de producir no hay entregable: no se planifica prosa por que
    // aparezca la palabra «riesgos». Se sigue el camino normal.
    var plan = try pb.plan(allocator, "Cuales son los riesgos de guardar claves en texto plano", &.{}, null);
    defer plan.deinit();
    try std.testing.expect(plan.tasks.len == 0 or plan.tasks[0].task_type != .documentar);
}

// ── E2.19: stack explícito no-C nunca debe preguntar C/C++/Zig ─────────────

test "E2.19: orden web «Solo HTML+CSS+JS» no pregunta el lenguaje" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const pb = mp.backend();
    defer pb.deinit();

    // Caso real de la sesión de usabilidad (orden #598): el stack estaba
    // declarado y aun así cayó en `clarifying` ofreciendo C/C++/Zig; al
    // responder, el entendimiento mutó a «Objetivo: programar_cpp».
    var plan = try pb.plan(allocator, "Crea pomodoro.html en devagents-workspace: una pagina estatica con un temporizador Pomodoro de 25 minutos, boton iniciar/pausar/reiniciar, y un contador de pomodoros completados. Solo HTML+CSS+JS en un archivo.", &.{}, null);
    defer plan.deinit();

    try std.testing.expect(!plan.needsClarification());
    try std.testing.expectEqual(model_router.TaskType.programar, plan.tasks[0].task_type);
}

test "E2.19: stack unido con '+' se detecta (css+js sin marcador html)" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const pb = mp.backend();
    defer pb.deinit();

    var plan = try pb.plan(allocator, "mueve la logica del badge a ts+vanilla", &.{}, null);
    defer plan.deinit();
    try std.testing.expect(!plan.needsClarification());
    try std.testing.expectEqual(model_router.TaskType.programar, plan.tasks[0].task_type);
}

test "E2.19: c# no se clasifica como C" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const pb = mp.backend();
    defer pb.deinit();

    var plan = try pb.plan(allocator, "crea un hola mundo en c#", &.{}, null);
    defer plan.deinit();
    try std.testing.expect(!plan.needsClarification());
    try std.testing.expectEqual(model_router.TaskType.programar, plan.tasks[0].task_type);
}

test "E2.19: otros lenguajes explicitos tampoco preguntan" {
    const allocator = std.testing.allocator;
    var mp = MockPlanner.init(allocator);
    const pb = mp.backend();
    defer pb.deinit();

    const ordenes = [_][]const u8{
        "automatiza el backup con bash",
        "escribe la api en php",
        "migra el script a ruby",
        "haz el cli en kotlin",
    };
    for (ordenes) |orden| {
        var plan = try pb.plan(allocator, orden, &.{}, null);
        defer plan.deinit();
        try std.testing.expect(!plan.needsClarification());
        try std.testing.expectEqual(model_router.TaskType.programar, plan.tasks[0].task_type);
    }
}
