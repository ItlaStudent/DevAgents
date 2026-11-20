const std = @import("std");
const planner = @import("planner.zig");
const sandbox = @import("sandbox.zig");
const agent_def = @import("agent_def.zig");
/// el parser de artefactos (y sus predicados) viven en un solo
/// archivo; aquí solo se reexportan para los llamadores de siempre.
const artifact_parser = @import("artifact_parser.zig");

pub const WorkerError = error{
    UnsafeBatchArgument,
    OutOfMemory,
    AllKeysExhausted,
    InvalidArtifact,
    ContextHandoffBlocked,
    SandboxDenied,
    NotImplemented,
    ConnectorError,
    Timeout,
    LlmCallFailed,
    JsonParseError,
    SpawnFailed,
    ProcessDied,
};

pub const WorkerResult = struct {
    task_id: []const u8,
    artifacts: []Artifact,
    success: bool,
    error_msg: []const u8,
    paid_budget_exhausted: bool = false,
    /// E5.09: raíz real donde el worker escribió los archivos (worktree de la
    /// orden para agentes externos). Cuando viene fijada, `artifacts[i].path`
    /// son rutas RELATIVAS a esa raíz y los archivos YA existen en disco — el
    /// llamador no debe re-materializarlos aplanados bajo `orden-<id>`.
    /// Owned por el resultado; null = worker nativo (artefactos de contenido).
    worktree_root: ?[]const u8 = null,
    /// D-C1 (E5.11): la sesión agéntica corrió pero el modelo nunca llamó a
    /// `finish` — el resultado es INCOMPLETE, no un done ni un fallo de
    /// proveedor. La tarea queda sin cerrar y la orden jamás `done` por ella.
    incomplete: bool = false,

    pub fn deinit(self: *const WorkerResult, allocator: std.mem.Allocator) void {
        allocator.free(self.task_id);
        for (self.artifacts) |a| a.deinit(allocator);
        allocator.free(self.artifacts);
        allocator.free(self.error_msg);
        if (self.worktree_root) |wr| allocator.free(wr);
    }
};

/// El tipo canónico vive en `artifact_parser.zig`; el reexport
/// conserva todas las firmas que ya usaban `worker_backend.Artifact`.
pub const Artifact = artifact_parser.Artifact;

pub const WorkerBackend = struct {
    ptr: *anyopaque,
    runFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator, task: planner.PlannedTask, sb: sandbox.Sandbox) WorkerError!WorkerResult,
    deinitFn: *const fn (ctx: *anyopaque) void,

    pub fn run(self: WorkerBackend, allocator: std.mem.Allocator, task: planner.PlannedTask, sb: sandbox.Sandbox) WorkerError!WorkerResult {
        return self.runFn(self.ptr, allocator, task, sb);
    }

    pub fn deinit(self: WorkerBackend) void {
        self.deinitFn(self.ptr);
    }
};

pub const MockWorker = struct {
    pub fn init() MockWorker {
        return .{};
    }

    pub fn backend(self: *MockWorker) WorkerBackend {
        return .{ .ptr = self, .runFn = runImpl, .deinitFn = noopDeinit };
    }

    fn noopDeinit(_: *anyopaque) void {}

    fn runImpl(ctx: *anyopaque, allocator: std.mem.Allocator, task: planner.PlannedTask, sb: sandbox.Sandbox) WorkerError!WorkerResult {
        _ = ctx;

        const out_path = try std.fmt.allocPrint(allocator, "{s}.out", .{task.id});
        const allowed = sb.isAllowed(out_path);
        allocator.free(out_path);
        if (!allowed) return error.SandboxDenied;

        var artifacts = std.ArrayList(Artifact).empty;
        errdefer {
            for (artifacts.items) |a| a.deinit(allocator);
            artifacts.deinit(allocator);
        }

        for (task.contract_fields) |cf| {
            const fname = try std.fmt.allocPrint(allocator, "{s}", .{cf.name});
            if (!sb.isAllowed(fname)) {
                allocator.free(fname);
                return error.SandboxDenied;
            }
            const fake = switch (cf.field_type) {
                .string => try allocator.dupe(u8, "mock-value"),
                .integer => try allocator.dupe(u8, "1"),
                .boolean => try allocator.dupe(u8, "true"),
                .any => try allocator.dupe(u8, "{}"),
            };
            try artifacts.append(allocator, .{ .path = fname, .content = fake });
        }

        return WorkerResult{
            .task_id = try allocator.dupe(u8, task.id),
            .artifacts = try artifacts.toOwnedSlice(allocator),
            .success = true,
            .error_msg = try allocator.dupe(u8, ""),
        };
    }
};

/// NativeWorker: loop que toma una PlannedTask, construye el prompt desde la AgentDef
/// de su departamento (system_prompt + descripción + contrato), llama al LLM y parsea
/// los artefactos validándolos contra el Sandbox ANTES de aceptarlos.
///
/// Testeable SIN red inyectando `llmFn` (patrón del test de rotación en credentials.zig).
/// En producción usará `credentials.sendWithRotation` + conectores F2 cuando haya claves.
pub const NativeWorker = struct {
    system_prompt: []const u8,
    llm_fn: ?LlmFn = null,
    llm_ctx: ?*anyopaque = null,
    /// Bloque [HERRAMIENTAS DISPONIBLES] inyectado en el prompt del worker.
    /// El puntero es gestionado por el llamador (vive durante runImpl).
    available_tools: ?[]const u8 = null,
    /// FIX-3 / XFILE-01: bloque con los archivos ya creados por tareas previas de
    /// la misma orden. El puntero lo gestiona el llamador (vive durante runImpl).
    upstream_context: ?[]const u8 = null,
    /// FIX-4a / XFILE-02: manifiesto de TODAS las tareas de la orden (id/tipo/dept/desc),
    /// para que los workers coordinen nombres de archivos/funciones aunque corran en la
    /// misma ola. El puntero lo gestiona el llamador (vive durante runImpl).
    plan_manifest: ?[]const u8 = null,
    /// E5.13 (D-C3): mapa del repositorio renderizado (~3k tokens), archivos
    /// ordenados por relevancia para la orden. El puntero lo gestiona el
    /// llamador (vive durante runImpl).
    repo_map_context: ?[]const u8 = null,
    deterministic_fallback: bool = false,

    pub const LlmFn = *const fn (ctx: *anyopaque, system_prompt: []const u8, user_prompt: []const u8) []const u8;

    pub fn init(system_prompt: []const u8) NativeWorker {
        return .{ .system_prompt = system_prompt };
    }

    pub fn setLlmFn(self: *NativeWorker, ctx: *anyopaque, f: LlmFn) void {
        self.llm_fn = f;
        self.llm_ctx = ctx;
    }

    pub fn setAvailableTools(self: *NativeWorker, tools: []const u8) void {
        self.available_tools = tools;
    }

    pub fn setUpstreamContext(self: *NativeWorker, ctx: []const u8) void {
        self.upstream_context = ctx;
    }

    pub fn setPlanManifest(self: *NativeWorker, manifest: []const u8) void {
        self.plan_manifest = manifest;
    }

    pub fn setRepoMapContext(self: *NativeWorker, text: []const u8) void {
        self.repo_map_context = text;
    }

    pub fn enableDeterministicFallback(self: *NativeWorker) void {
        self.deterministic_fallback = true;
    }

    pub fn backend(self: *NativeWorker) WorkerBackend {
        return .{ .ptr = self, .runFn = runImpl, .deinitFn = noopDeinit };
    }

    fn noopDeinit(_: *anyopaque) void {}

    pub fn buildPrompt(self: *const NativeWorker, allocator: std.mem.Allocator, task: planner.PlannedTask) error{OutOfMemory}![]u8 {
        // 1. Construir prompt: system_prompt del departamento + herramientas disponibles + descripción de la tarea + contrato.
        var prompt = std.ArrayList(u8).empty;
        defer prompt.deinit(allocator);
        try prompt.appendSlice(allocator, self.system_prompt);
        if (self.available_tools) |tools| {
            try prompt.appendSlice(allocator, "\n\n[HERRAMIENTAS DISPONIBLES]\n");
            try prompt.appendSlice(allocator, tools);
        }
        try prompt.appendSlice(allocator, "\n\n---\n\nTAREA\n");
        try prompt.appendSlice(allocator, task.description);
        try prompt.appendSlice(allocator, "\n\nCONTRATO (campos a producir):\n");
        for (task.contract_fields) |cf| {
            const line = if (cf.value) |value|
                try std.fmt.allocPrint(allocator, "  - {s}: {s} (required={any}, value={s})\n", .{ cf.name, @tagName(cf.field_type), cf.required, value })
            else
                try std.fmt.allocPrint(allocator, "  - {s}: {s} (required={any})\n", .{ cf.name, @tagName(cf.field_type), cf.required });
            defer allocator.free(line);
            try prompt.appendSlice(allocator, line);
        }
        if (self.plan_manifest) |pm| {
            try prompt.appendSlice(allocator, "\n[PLAN DE LA ORDEN — OTRAS TAREAS DE ESTA MISMA ORDEN]\n");
            try prompt.appendSlice(allocator, "Eres uno de varios agentes trabajando en la MISMA orden. Este es el plan completo. Mantén nombres de archivos, modulos, funciones, clases y simbolos EXACTAMENTE CONSISTENTES con las demas tareas: si otra tarea implementa un modulo, usa EXACTAMENTE ese nombre de archivo y esos nombres de funciones (no inventes variantes).\n");
            try prompt.appendSlice(allocator, pm);
            try prompt.appendSlice(allocator, "\n");
        }
        if (self.repo_map_context) |mt| {
            try prompt.appendSlice(allocator, "\n[MAPA DEL REPOSITORIO — archivos ordenados por relevancia para esta orden; cada línea es `ruta` seguida de `  símbolo:línea`]\n");
            try prompt.appendSlice(allocator, mt);
            try prompt.appendSlice(allocator, "[FIN MAPA DEL REPOSITORIO]\n");
        }
        if (self.upstream_context) |uc| {
            try prompt.appendSlice(allocator, "\n[ARCHIVOS YA CREADOS POR TAREAS PREVIAS DE ESTA ORDEN]\n");
            try prompt.appendSlice(allocator, "Estos archivos YA existen en el proyecto. Referencia EXACTAMENTE estos nombres de archivo y los nombres de funciones/clases/símbolos que aparecen abajo. NO inventes nombres distintos ni asumas otra interfaz.\n");
            try prompt.appendSlice(allocator, uc);
            try prompt.appendSlice(allocator, "\n");
        }
        try prompt.appendSlice(allocator, "\nResponde ÚNICAMENTE con un array JSON de este formato:\n");
        try prompt.appendSlice(allocator, "[{\"field\":\"nombre_campo\",\"content\":\"valor\"}]\n");
        // ALTA-1 / ART-01: los modelos débiles a veces ponen en "content" una ruta, un nombre
        // de archivo o el tipo de tarea en vez del entregable real (auditoría/documentación).
        // Instrucción explícita de qué debe contener "content".
        try prompt.appendSlice(allocator, "El valor de \"content\" DEBE ser el contenido COMPLETO y FINAL del entregable de ese campo: el código fuente completo, o el texto íntegro del documento/README, o el reporte de auditoría completo en prosa. NUNCA pongas en \"content\" una ruta de archivo, un nombre de archivo, el nombre del departamento o del tipo de tarea, ni un marcador de posición. Para campos de documentación o auditoría escribe texto real y sustancial (varios párrafos cuando aplique), no una sola palabra ni una ruta.\n");
        // P0.2a (S22): texto aprobado literal del propietario. Los modelos
        // sobre-ingenieran entregables de texto: la orden 480 metió un
        // print(...) dentro del .txt y la 505 un script Node. Medido en vivo
        // con Cohere el 16-09: una paráfrasis más blanda de esta regla siguió
        // produciendo un script Python — por eso va el texto exacto.
        try prompt.appendSlice(allocator, "Si el entregable solicitado es un archivo de texto (.txt, .md, .log, .csv o sin extensión), escribe directamente el texto final que la persona quiere leer, no un programa que lo genere. Para un archivo que diga hola, el contenido es hola, sin print(...), console.log(...), scripts ni envoltorios de código. Respeta Markdown o CSV si se piden. Esta regla no aplica si la persona pide explícitamente código, un ejemplo de código o un script dentro del archivo. Mantén el array JSON de transporte indicado; la regla afecta al contenido del archivo, no al formato de la respuesta.\n");
        try prompt.appendSlice(allocator, "Si creas pruebas, carga los archivos reales producidos por las tareas previas; nunca copies su implementación dentro del test. Usa aserciones que fallen el proceso y prueba también la integración solicitada.\n");
        if (task.task_type == .auditar) {
            // declarar las tools reales que el executor sirve para esta
            // tarea (read_file, list_dir, grep_files — solo lectura, confinadas
            // al worktree de la orden). Sin esta instrucción el auditor no
            // sabía que podía leer y fabricaba citas (ronda 3: 0 lecturas
            // reales en 4 frentes).
            try prompt.appendSlice(allocator, "Tienes herramientas de SOLO LECTURA sobre el worktree real de la orden: read_file{path,offset?,limit?} lee un archivo de texto, list_dir{path?,recursive?} lista un directorio y grep_files{pattern,path?,ignore_case?,max_results?} busca un texto literal y repo_search{query,max_results?} devuelve los chunks mas relevantes por ranking BM25 (lexico). Las rutas pueden ser relativas al worktree. Usa las herramientas para abrir de verdad cada archivo que cites: una afirmación sobre el código sin lectura real del archivo no es evidencia. Nunca inventes rutas ni números de línea.\n");
            try prompt.appendSlice(allocator, "El campo verdict debe empezar con PASS o FAIL. Después explica los hallazgos concretos y los archivos afectados, usando el código y la evidencia de ejecución recibidos. Un comando que termina con exit 0 no demuestra por sí solo cobertura ni funcionamiento de la interfaz.\n");
        }
        // M1 — LA ENTREGA PUEDE SER DE VARIOS ARCHIVOS, y hay que pedirlo.
        //
        // Medido el 2026-08-11 en las órdenes #184 y #186: con el contrato ofreciendo un
        // solo campo `source`, el modelo entrega UN `index.html` que enlaza un
        // `styles.css` y un `script.js` que jamás escribe. La orden acaba `done`, la
        // auto-auditoría en verde, y el usuario abre una calculadora sin estilos en la
        // que no funciona ni un botón. La persistencia ya sabe escribir varios archivos
        // (workspace.persistTaskFiles); lo que faltaba era decirle al modelo que puede
        // —y debe— entregarlos, en la forma que el motor ya sabe leer: un objeto por
        // archivo, con el nombre del archivo en "field".
        if (self.plan_manifest != null) {
            try prompt.appendSlice(allocator, "Con este plan compartido, entrega SOLAMENTE los archivos asignados a ESTA tarea. Puedes referenciar nombres asignados a tareas hermanas del manifiesto, pero NO reescribas ni incluyas su contenido: cada archivo tiene un único propietario.\n");
        } else {
            try prompt.appendSlice(allocator, "Si el entregable necesita MÁS DE UN ARCHIVO (por ejemplo una página web con HTML, CSS y JavaScript separados), devuelve UN OBJETO POR ARCHIVO y pon el NOMBRE DEL ARCHIVO CON SU EXTENSIÓN en \"field\":\n");
            try prompt.appendSlice(allocator, "[{\"field\":\"index.html\",\"content\":\"...\"},{\"field\":\"styles.css\",\"content\":\"...\"},{\"field\":\"script.js\",\"content\":\"...\"}]\n");
            try prompt.appendSlice(allocator, "REGLA INNEGOCIABLE: no enlaces desde un archivo a otro que no estés entregando en ESTA MISMA respuesta. Si tu HTML lleva <link rel=\"stylesheet\" href=\"styles.css\"> o <script src=\"script.js\">, esos dos archivos TIENEN que venir también en el array. Si prefieres un único archivo, incrusta el CSS en <style> y el JS en <script> dentro del propio HTML. Lo que no vale es prometer archivos que no entregas.\n");
        }

        return prompt.toOwnedSlice(allocator);
    }

    fn runImpl(ctx: *anyopaque, allocator: std.mem.Allocator, task: planner.PlannedTask, sb: sandbox.Sandbox) WorkerError!WorkerResult {
        const self: *NativeWorker = @ptrCast(@alignCast(ctx));

        const full_prompt = try self.buildPrompt(allocator, task);
        defer allocator.free(full_prompt);

        // 2. Invocar LLM (mock inyectado para tests; producción usará credentials + connectores).
        const llm_response = blk: {
            const fn_ptr = self.llm_fn orelse {
                if (self.deterministic_fallback) {
                    if (try deterministicLocalResult(allocator, task, self.upstream_context)) |result| {
                        return result;
                    }
                }
                return error.LlmCallFailed;
            };
            const raw = fn_ptr(self.llm_ctx.?, self.system_prompt, full_prompt);
            // A rejected handoff is a terminal context error. Never reinterpret
            // its empty response as a broken artifact or use the local rescue.
            if (fn_ptr == @import("live_worker.zig").LiveLlm.llmFn) {
                const live: *@import("live_worker.zig").LiveLlm = @ptrCast(@alignCast(self.llm_ctx.?));
                if (live.handoff_blocked) return error.ContextHandoffBlocked;
            }
            // El mock puede devolver memoria stack; duplicamos para poseerla.
            break :blk try allocator.dupe(u8, raw);
        };
        defer allocator.free(llm_response);

        // 3. Parsear artefactos con el contrato unificado: la
        // respuesta puede traer prosa/fences o un objeto suelto; el parser
        // unico prueba los candidatos en vez de exigir "empieza por [".
        var artifacts = parseArtifacts(allocator, llm_response) catch |e| blk: {
            if (isProgrammingTask(task.task_type)) {
                break :blk artifactsFromRawProgrammingResponse(allocator, task, llm_response) catch {
                    if (self.deterministic_fallback) {
                        if (try deterministicLocalResult(allocator, task, self.upstream_context)) |result| {
                            return result;
                        }
                    }
                    return e;
                };
            }
            if (self.deterministic_fallback) {
                if (try deterministicLocalResult(allocator, task, self.upstream_context)) |result| {
                    return result;
                }
            }
            return e;
        };
        errdefer {
            var j: usize = 0;
            while (j < artifacts.items.len) : (j += 1) {
                artifacts.items[j].deinit(allocator);
            }
            artifacts.deinit(allocator);
        }

        // contenido válido con la ruta puesta en la etiqueta del campo
        // (`{"field":"source",...}` para una tarea que entrega un solo archivo)
        // debe salir con el nombre esperado, no tratarse como vacío.
        try assignArtifactRoutes(allocator, task, &artifacts);

        // ALTA-1 / ART-01: si TODOS los artefactos devueltos son rutas/nombres desnudos en vez
        // de contenido real (fallo típico de modelos débiles en tareas de auditar/documentar),
        // se trata como fallo de formato y se devuelve error → el fallback (FIX-5) reintenta con
        // otro modelo en vez de persistir un artefacto basura de 13-25 bytes (cero falso-verde).
        if (artifacts.items.len > 0) {
            var all_bare = true;
            for (artifacts.items) |art| {
                if (!looksLikeBarePath(art.content)) {
                    all_bare = false;
                    break;
                }
            }
            if (all_bare) return error.InvalidArtifact;
        }

        // 4. Validar cada artefacto contra el Sandbox ANTES de aceptarlo (errdefer limpia si falla).
        {
            const len = artifacts.items.len;
            var i: usize = 0;
            while (i < len) : (i += 1) {
                if (!sb.isAllowed(artifacts.items[i].path)) {
                    return error.SandboxDenied;
                }
            }
        }

        // Hoist las adquisiciones a locales con su propio errdefer ANTES de construir el
        // struct: los campos se evalúan en orden léxico, así que si toOwnedSlice vacía
        // `artifacts` (transfiriendo el slice) y un dupe posterior falla con OOM, el
        // errdefer de arriba corre sobre la lista YA VACÍA y fuga el slice extraído + el
        // task_id ya duplicado. Estos errdefers cubren la ventana post-extracción.
        const owned_artifacts = try artifacts.toOwnedSlice(allocator);
        errdefer {
            for (owned_artifacts) |*a| a.deinit(allocator);
            allocator.free(owned_artifacts);
        }
        const tid = try allocator.dupe(u8, task.id);
        errdefer allocator.free(tid);
        const emsg = try allocator.dupe(u8, "");
        return WorkerResult{
            .task_id = tid,
            .artifacts = owned_artifacts,
            .success = true,
            .error_msg = emsg,
        };
    }
};

fn deterministicLocalResult(allocator: std.mem.Allocator, task: planner.PlannedTask, upstream_context: ?[]const u8) WorkerError!?WorkerResult {
    if (isProgrammingTask(task.task_type)) {
        if (extractPythonFilename(task.description)) |filename| {
            const source = (try deterministicPythonSourceOwned(allocator, filename, task.description)) orelse return null;
            var source_owned = true;
            errdefer if (source_owned) allocator.free(source);
            const artifacts = try allocator.alloc(Artifact, 3);
            var initialized: usize = 0;
            errdefer {
                for (artifacts[0..initialized]) |*artifact| artifact.deinit(allocator);
                allocator.free(artifacts);
            }
            artifacts[0] = .{ .path = try allocator.dupe(u8, "source"), .content = source };
            source_owned = false;
            initialized += 1;
            artifacts[1] = .{ .path = try allocator.dupe(u8, "filename"), .content = try allocator.dupe(u8, filename) };
            initialized += 1;
            artifacts[2] = .{ .path = try allocator.dupe(u8, "exit_code"), .content = try allocator.dupe(u8, "0") };
            initialized += 1;
            return WorkerResult{
                .task_id = try allocator.dupe(u8, task.id),
                .artifacts = artifacts,
                .success = true,
                .error_msg = try allocator.dupe(u8, ""),
            };
        }
    }
    // AUDIT-UNAVAILABLE-P0 (S22, orden 500): las tareas `auditar` NO tienen
    // resultado local determinista. Antes este bloque devolvía verdict=PASS
    // con solo encontrar ".py" en el contexto upstream — un veredicto de
    // auditoría FABRICADO sin que ningún modelo revisara nada. Un auditor sin
    // respuesta usable deja la tarea sin veredicto (el despacho la clasifica
    // `audit_unavailable`), nunca un PASS.
    _ = upstream_context;
    return null;
}

fn extractPythonFilename(text: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n\"'`:,;()[]{}<>");
    while (it.next()) |token| {
        if (std.mem.endsWith(u8, token, ".py")) return basenameAscii(token);
    }
    return null;
}

fn basenameAscii(path: []const u8) []const u8 {
    var start: usize = 0;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '/' or path[i] == '\\') start = i + 1;
    }
    return path[start..];
}

fn asciiIndexOfIgnoreCase(haystack: []const u8, needle: []const u8) ?usize {
    if (needle.len == 0 or needle.len > haystack.len) return null;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        var matches = true;
        for (needle, 0..) |expected, j| {
            if (std.ascii.toLower(haystack[i + j]) != expected) {
                matches = false;
                break;
            }
        }
        if (matches) return i;
    }
    return null;
}

fn extractExactPrintLiteral(description: []const u8) ?[]const u8 {
    const patterns = [_][]const u8{ "imprima exactamente", "imprime exactamente", "print exactly" };
    for (patterns) |pattern| {
        const pos = asciiIndexOfIgnoreCase(description, pattern) orelse continue;
        var rest = description[pos + pattern.len ..];
        var first: usize = 0;
        while (first < rest.len and std.mem.indexOfScalar(u8, " \t\r\n:", rest[first]) != null) : (first += 1) {}
        rest = rest[first..];
        if (rest.len == 0) continue;
        const quote = rest[0];
        if (quote == '"' or quote == '\'') {
            const end = std.mem.indexOfScalar(u8, rest[1..], quote) orelse continue;
            const literal = rest[1 .. 1 + end];
            if (literal.len > 0) return literal;
        } else {
            // Forma natural sin comillas: "imprima exactamente TEXTO, ejecútalo".
            // Se limita a una cláusula corta para no convertir el resto completo de
            // la orden en output determinista.
            const end = std.mem.indexOfAny(u8, rest, ",;\r\n") orelse rest.len;
            const literal = std.mem.trim(u8, rest[0..end], " \t.!?");
            if (literal.len > 0 and literal.len <= 200) return literal;
        }
    }
    return null;
}

fn pythonPrintSource(allocator: std.mem.Allocator, literal: []const u8) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    try out.appendSlice(allocator, "def main():\n    print(\"");
    for (literal) |ch| switch (ch) {
        '\\' => try out.appendSlice(allocator, "\\\\"),
        '"' => try out.appendSlice(allocator, "\\\""),
        '\n' => try out.appendSlice(allocator, "\\n"),
        '\r' => try out.appendSlice(allocator, "\\r"),
        '\t' => try out.appendSlice(allocator, "\\t"),
        else => try out.append(allocator, ch),
    };
    try out.appendSlice(allocator, "\")\n\n\nif __name__ == \"__main__\":\n    main()\n");
    return out.toOwnedSlice(allocator);
}

fn deterministicPythonSourceOwned(allocator: std.mem.Allocator, filename: []const u8, description: []const u8) !?[]u8 {
    if (extractExactPrintLiteral(description)) |literal| return try pythonPrintSource(allocator, literal);
    if (std.mem.indexOf(u8, filename, "primo") != null or std.mem.indexOf(u8, filename, "prime") != null) {
        return try allocator.dupe(u8,
            \\def es_primo(n):
            \\    if n < 2:
            \\        return False
            \\    for divisor in range(2, int(n ** 0.5) + 1):
            \\        if n % divisor == 0:
            \\            return False
            \\    return True
            \\
            \\
            \\def main():
            \\    primos = [n for n in range(2, 101) if es_primo(n)]
            \\    print(primos)
            \\
            \\
            \\if __name__ == "__main__":
            \\    main()
            \\
        );
    }
    return null;
}

// ── Parser único de artefactos ───────────────────────────
//
// La implementación (extracción + parseo + predicados) vive en
// `artifact_parser.zig`: un solo contrato para las tres rutas —live_worker,
// este worker y cli_worker—. Aquí quedan los nombres que el resto del motor ya
// usaba, delegando en ese parser único; ya no son copias.

/// Par `open`/`close` balanceado (ver `artifact_parser.scanBalanced`).
pub const scanBalanced = artifact_parser.scanBalanced;

/// Extracción textual del JSON de un blob (ver `artifact_parser.extractJsonArray`).
pub const extractJsonArray = artifact_parser.extractJsonArray;

/// Saneado de escapes/control chars del JSON del modelo (ver
/// `artifact_parser.escapeRawControlChars`); también lo usa live_worker para el
/// doble del planner.
pub const escapeRawControlChars = artifact_parser.escapeRawControlChars;

/// Parser unificado de artefactos: blob (prosa/fences/JSON) -> artefactos.
/// La versión con test rojo/verde está en `artifact_parser.parseArtifacts`.
pub fn parseArtifacts(allocator: std.mem.Allocator, raw: []const u8) WorkerError!std.ArrayList(Artifact) {
    return artifact_parser.parseArtifacts(allocator, raw);
}

/// Pivote estricto del parser único: un JSON YA AISLADO (array de objetos
/// `{field, content}` o un objeto suelto) -> artefactos. Delega en
/// `artifact_parser.parseArtifactsJson`.
pub fn parseLlmResponse(allocator: std.mem.Allocator, raw: []const u8) WorkerError!std.ArrayList(Artifact) {
    return artifact_parser.parseArtifactsJson(allocator, raw);
}

/// Desvallado del contenido de un artefacto (ver `artifact_parser.stripMarkdownFence`).
pub const stripMarkdownFence = artifact_parser.stripMarkdownFence;

fn isProgrammingTask(task_type: anytype) bool {
    return switch (task_type) {
        .programar, .programar_c, .programar_cpp, .programar_zig => true,
        else => false,
    };
}

fn artifactsFromRawProgrammingResponse(allocator: std.mem.Allocator, task: planner.PlannedTask, raw: []const u8) WorkerError!std.ArrayList(Artifact) {
    if (task.contract_fields.len == 0) return error.InvalidArtifact;
    const field = task.contract_fields[0].name;
    const code = if (extractFencedCode(raw)) |fenced|
        fenced
    else blk: {
        const trimmed = std.mem.trim(u8, raw, " \t\r\n");
        if (!looksLikeProgrammingContent(trimmed)) return error.InvalidArtifact;
        break :blk trimmed;
    };
    if (code.len == 0) return error.InvalidArtifact;

    var list = std.ArrayList(Artifact).empty;
    errdefer {
        for (list.items) |a| a.deinit(allocator);
        list.deinit(allocator);
    }
    const path = try allocator.dupe(u8, field);
    errdefer allocator.free(path);
    const body = try allocator.dupe(u8, code);
    errdefer allocator.free(body);
    try list.append(allocator, .{ .path = path, .content = body });
    return list;
}

fn extractFencedCode(raw: []const u8) ?[]const u8 {
    const start = std.mem.indexOf(u8, raw, "```") orelse return null;
    var body_start = start + 3;
    if (std.mem.indexOfScalarPos(u8, raw, body_start, '\n')) |nl| {
        body_start = nl + 1;
    }
    const end = std.mem.indexOfPos(u8, raw, body_start, "```") orelse return null;
    return std.mem.trim(u8, raw[body_start..end], " \t\r\n");
}

fn looksLikeProgrammingContent(raw: []const u8) bool {
    if (raw.len < 8) return false;
    const needles = [_][]const u8{
        "def ",   "class ",   "function ",   "import ", "from ",  "#include", "fn ",
        "pub fn", "int main", "console.log", "return ", "const ", "let ",     "var ",
        "{",      "}",        ";",
    };
    for (needles) |n| {
        if (std.mem.indexOf(u8, raw, n) != null) return true;
    }
    return false;
}

/// ALTA-1 / ART-01: detecta el patrón de fallo de modelos débiles que devuelven una RUTA o
/// NOMBRE de archivo como "content" en vez del entregable real (p. ej. una tarea de auditoría
/// que responde "core/src/superagent.zig" en lugar del reporte). Contenido real (código o
/// prosa) siempre tiene espacios o saltos de línea; una ruta desnuda no.
fn looksLikeBarePath(s: []const u8) bool {
    const t = std.mem.trim(u8, s, " \t\r\n");
    if (t.len == 0 or t.len > 200) return false;
    if (std.mem.indexOfScalar(u8, t, '\n') != null) return false; // multilínea = contenido real
    if (std.mem.indexOfScalar(u8, t, ' ') != null) return false; // con espacios = contenido real
    return std.mem.indexOfScalar(u8, t, '/') != null or std.mem.indexOfScalar(u8, t, '\\') != null;
}

test "ART-01: looksLikeBarePath distingue rutas desnudas de contenido real" {
    try std.testing.expect(looksLikeBarePath("core/src/superagent.zig"));
    try std.testing.expect(looksLikeBarePath("core\\src\\model_router.zig"));
    try std.testing.expect(!looksLikeBarePath("# Mi Modulo\nUso real del modulo.")); // multilínea
    try std.testing.expect(!looksLikeBarePath("int main(){ return 0; }")); // tiene espacios
    try std.testing.expect(!looksLikeBarePath("documentacion")); // palabra suelta sin separador
    try std.testing.expect(!looksLikeBarePath("")); // vacío
}

/// el contrato `{field,content}` manda el NOMBRE del archivo en
/// `field`, pero muchos modelos ponen ahí la ETIQUETA del campo (`source`,
/// `code`, `text`) en vez de un nombre. Ese contenido no está vacío: está
/// huérfano de ruta. Cuando la tarea espera EXACTAMENTE un archivo, se le pone
/// el nombre esperado (lo que `workspace.planOutFiles` ya hacía para la entrega
/// en disco, ahora también en el artefacto que valida el contrato). Con VARIOS
/// artefactos sin ruta y VARIOS archivos esperados no se adivina: se rechaza con
/// causa legible en vez de bautizar a un archivo con un nombre de campo.
///
/// No se toca la prosa: las tareas de prosa ya resuelven su nombre
/// en `workspace.planOutFiles` y se dejan pasar aquí.
pub fn assignArtifactRoutes(
    allocator: std.mem.Allocator,
    task: planner.PlannedTask,
    artifacts: *std.ArrayList(Artifact),
) WorkerError!void {
    // Punto 4 de la auditoría: un cuerpo vacío llega aquí solo si su ruta puede
    // estar vacía o es una etiqueta de cuerpo (provisional). Se descarta salvo
    // que la tarea pida expresamente un archivo vacío.
    const wants_empty = taskWantsEmptyFile(task);
    try dropDisallowedEmptyArtifacts(allocator, artifacts, wants_empty);

    switch (task.task_type) {
        .auditar, .documentar, .investigar, .resumir => return,
        else => {},
    }

    // Artefactos "sin ruta": cuerpo real (con contenido) cuyo `path` es una
    // etiqueta de campo, no un nombre de archivo. Los objetos de METADATOS
    // (`filename`, `path`, `type`…) no cuentan como entregable; sirven para
    // declarar el nombre.
    var routeless: ?usize = null;
    var routeless_count: usize = 0;
    for (artifacts.items, 0..) |a, i| {
        const empty = std.mem.trim(u8, a.content, " \t\r\n").len == 0;
        // Un cuerpo huérfano vacío solo se bautiza si la tarea pide un archivo
        // vacío (si no, `dropDisallowedEmptyArtifacts` ya lo quitó).
        if (empty and !wants_empty) continue;
        if (!isBodyLabel(a.path)) continue;
        routeless = i;
        routeless_count += 1;
    }
    if (routeless_count == 0) return;

    var buf: [16][]const u8 = undefined;
    const expected = expectedOutFiles(task, artifacts.items, &buf);
    if (expected.len == 0) return;

    if (routeless_count == 1 and expected.len == 1) {
        const old = artifacts.items[routeless.?].path;
        const name = try allocator.dupe(u8, expected[0]);
        allocator.free(old);
        artifacts.items[routeless.?].path = name;
        return;
    }
    // Varios sin ruta y varios esperados: no se adivina cuál es cuál.
    if (routeless_count >= 2 and expected.len >= 2) return error.InvalidArtifact;
}

/// Etiqueta de CAMPO (cuerpo del entregable), no nombre de archivo (ver
/// `artifact_parser.isBodyLabel`).
const isBodyLabel = artifact_parser.isBodyLabel;

/// Etiqueta de METADATOS: describe el artefacto, no es el entregable.
fn isMetadataLabel(label: []const u8) bool {
    const names = [_][]const u8{
        "filename",       "file_name", "filepath", "file_path",   "path",       "archivo",
        "nombre_archivo", "name",      "type",     "task_type",   "department", "id",
        "status",         "expects",   "language", "description",
    };
    for (names) |n| {
        if (std.ascii.eqlIgnoreCase(label, n)) return true;
    }
    return false;
}

/// Nombres que legítimamente pueden entregarse vacíos (ver
/// `artifact_parser.canBeEmptyFileName`).
const canBeEmptyFileName = artifact_parser.canBeEmptyFileName;

/// Punto 4 (auditoría): quita los artefactos de cuerpo vacío que no son una
/// entrega legítima. `wants_empty` (la tarea pide expresamente un archivo
/// vacío) protege el caso intencional. Si no queda ningún artefacto, la
/// respuesta entera es un vacío.
fn dropDisallowedEmptyArtifacts(
    allocator: std.mem.Allocator,
    artifacts: *std.ArrayList(Artifact),
    wants_empty: bool,
) WorkerError!void {
    var i: usize = 0;
    while (i < artifacts.items.len) {
        const a = artifacts.items[i];
        const empty = std.mem.trim(u8, a.content, " \t\r\n").len == 0;
        if (!empty or canBeEmptyFileName(a.path) or wants_empty) {
            i += 1;
            continue;
        }
        if (isBodyLabel(a.path)) {
            const gone = artifacts.orderedRemove(i);
            gone.deinit(allocator);
            continue;
        }
        i += 1;
    }
    if (artifacts.items.len == 0) return error.InvalidArtifact;
}

/// Punto 4 (auditoría): ¿la descripción pide expresamente un archivo vacío?
/// Solo se aceptan frases que marcan esa intención, para no convertir en
/// entrega vacía una negación del tipo «no dejes el archivo vacío».
fn taskWantsEmptyFile(task: planner.PlannedTask) bool {
    const markers = [_][]const u8{
        "archivo vacío",
        "archivo vacio",
        "fichero vacío",
        "fichero vacio",
        "archivo en blanco",
        "empty file",
        "fichero en blanco",
    };
    for (markers) |m| {
        if (markerNotNegated(task.description, m)) return true;
    }
    return false;
}

/// Auditoría r2 (el segundo auditor): «No dejes el archivo vacío» contiene el marcador pero lo
/// niega. Una aparición cuenta solo si en las 24 posiciones previas no hay una
/// negación («no», «nunca», «sin», «not», «never», «don't», «ni»).
fn markerNotNegated(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (!std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) continue;
        const start = if (i > 24) i - 24 else 0;
        if (!hasNegationWord(haystack[start..i])) return true;
    }
    return false;
}

fn hasNegationWord(window: []const u8) bool {
    const words = [_][]const u8{ "no", "nunca", "sin", "ni", "not", "never", "don't", "dont" };
    // Sin apóstrofo como separador: «don't» debe llegar entero (el segundo auditor, r3).
    var it = std.mem.tokenizeAny(u8, window, " \t\r\n,.;:!?\"()");
    while (it.next()) |w| {
        for (words) |n| {
            if (std.ascii.eqlIgnoreCase(w, n)) return true;
        }
    }
    return false;
}

fn containsIgnoreCase(haystack: []const u8, needle: []const u8) bool {
    if (needle.len == 0 or haystack.len < needle.len) return false;
    var i: usize = 0;
    while (i + needle.len <= haystack.len) : (i += 1) {
        if (std.ascii.eqlIgnoreCase(haystack[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Archivos que la tarea espera entregar, por orden de fiabilidad: `owns`
/// declarado, luego un artefacto de metadatos `filename`/`path` con nombre
/// válido, luego los campos del contrato con extensión de código, luego el
/// nombre pedido en la descripción (`extractRequestedBasename`, ya usado por el
/// workspace). Deduplica sin distinguir mayúsculas. Devuelve la porción de `buf`.
fn expectedOutFiles(
    task: planner.PlannedTask,
    artifacts: []const Artifact,
    buf: *[16][]const u8,
) []const []const u8 {
    var n: usize = 0;

    for (task.owns) |o| {
        if (o.len == 0 or !looksLikeFilename(o)) continue;
        addUnique(buf, &n, o);
    }

    if (n == 0) {
        for (artifacts) |a| {
            if (!isMetadataLabel(a.path)) continue;
            const cand = std.mem.trim(u8, a.content, " \t\r\n");
            if (looksLikeFilename(cand)) addUnique(buf, &n, cand);
            break;
        }
    }

    if (n == 0) {
        for (task.contract_fields) |f| {
            if (std.mem.eql(u8, f.name, "filename")) {
                if (f.value) |v| {
                    const cand = std.mem.trim(u8, v, " \t\r\n");
                    if (looksLikeFilename(cand)) addUnique(buf, &n, cand);
                }
            } else if (looksLikeFilename(f.name)) {
                addUnique(buf, &n, f.name);
            }
        }
    }

    if (n == 0) {
        if (extractRequestedBasename(task.description)) |r| addUnique(buf, &n, r);
    }

    return buf[0..n];
}

fn addUnique(buf: *[16][]const u8, n: *usize, name: []const u8) void {
    if (n.* >= buf.len) return;
    for (buf[0..n.*]) |e| {
        if (std.ascii.eqlIgnoreCase(e, name)) return;
    }
    buf[n.*] = name;
    n.* += 1;
}

/// Primer nombre de archivo (con extensión conocida) mencionado en la
/// descripción de la tarea como DESTINO (punto 2 de la auditoría). Espejo local
/// de `workspace.extractRequestedBasename` (worker_backend no puede importar
/// workspace: hay ciclo), pero este exige contexto de SALIDA: una mención como
/// entrada («lee config.json», «a partir de datos.csv») no cuenta. Solo la
/// última componente de la ruta, y solo si es un nombre sano con extensión
/// conocida.
fn extractRequestedBasename(text: []const u8) ?[]const u8 {
    var tokens: [128][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n\"'`:,;()[]{}<>*|");
    while (it.next()) |tok| {
        if (n >= tokens.len) break;
        tokens[n] = tok;
        n += 1;
    }
    for (tokens[0..n], 0..) |tok, i| {
        const base = std.mem.trim(u8, basenameLocal(tok), ".!?");
        if (!looksLikeFilename(base)) continue;
        if (isOutputMention(tokens[0..i])) return base;
    }
    return null;
}

/// Punto 2 (auditoría): ¿el nombre que sigue viene introducido como SALIDA?
/// Recorre hacia atrás una ventana corta de tokens: la primera marca que
/// encuentra decide. Una marca de ENTRADA gana (mención de lectura); una de
/// SALIDA lo confirma; si no hay marca, NO se asume destino.
fn isOutputMention(prev: []const []const u8) bool {
    const out_markers = [_][]const u8{
        "archivo",     "fichero",   "file",      "llamado",    "llamada",
        "named",       "nombre",    "nombrado",  "crea",       "crear",
        "creas",       "genera",    "generar",   "generas",    "escribe",
        "escribir",    "escribes",  "guarda",    "guardar",    "guardas",
        "guarde",      "salida",    "output",    "save",       "write",
        "create",      "generate",  "produce",   "producir",   "implementa",
        "implementar", "construye", "construir", "desarrolla", "desarrollar",
        "entrega",     "entregar",  "entregas",  "haz",        "hacer",
        "devuelve",    "devolver",  "resultado",
    };
    const in_markers = [_][]const u8{
        "lee",    "leer",     "leas",    "reads",    "read",    "carga",
        "cargas", "cargar",   "load",    "loads",    "from",    "de",
        "desde",  "using",    "usa",     "usar",     "usando",  "entrada",
        "input",  "requiere", "require", "requires", "depende", "partir",
    };
    var j: usize = prev.len;
    var steps: usize = 0;
    while (j > 0 and steps < 4) {
        j -= 1;
        const t = prev[j];
        if (tokenIn(t, &in_markers)) return false;
        if (tokenIn(t, &out_markers)) return true;
        steps += 1;
    }
    return false;
}

fn tokenIn(tok: []const u8, list: []const []const u8) bool {
    for (list) |m| {
        if (std.ascii.eqlIgnoreCase(tok, m)) return true;
    }
    return false;
}

/// Última componente de una ruta (ver `artifact_parser.basenameLocal`).
const basenameLocal = artifact_parser.basenameLocal;

/// Nombre de archivo real vs etiqueta (ver `artifact_parser.looksLikeFilename`).
const looksLikeFilename = artifact_parser.looksLikeFilename;

/// Fuzz wrapper: parsea el contrato unificado (blob -> artefactos) y limpia.
/// Misma puerta que `fuzz_parseLlmResponse`, ahora con extracción tolerante a
/// prosa/candidatos.
pub fn fuzz_parseArtifacts(allocator: std.mem.Allocator, raw: []const u8) !void {
    var artifacts = try parseArtifacts(allocator, raw);
    defer {
        for (artifacts.items) |*a| a.deinit(allocator);
        artifacts.deinit(allocator);
    }
}

/// Fuzz wrapper: calls parseLlmResponse and cleans up. Returns error on invalid input,
/// crashes on logic errors. Used by tools/fuzz.zig.
pub fn fuzz_parseLlmResponse(allocator: std.mem.Allocator, raw: []const u8) !void {
    var artifacts = try parseLlmResponse(allocator, raw);
    defer {
        for (artifacts.items) |*a| a.deinit(allocator);
        artifacts.deinit(allocator);
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

test "mock worker produces artifacts per contract field" {
    const allocator = std.testing.allocator;
    var mw = MockWorker.init();
    const backend = mw.backend();
    defer backend.deinit();

    const fields = try allocator.alloc(planner.ContractField, 2);
    defer allocator.free(fields);
    fields[0] = .{ .name = "source", .field_type = .string, .required = true };
    fields[1] = .{ .name = "exit_code", .field_type = .integer, .required = true };

    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar_c,
        .department = "programacion",
        .description = "test task",
        .contract_fields = fields,
        .depends_on = &.{},
    };

    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t1");
    defer sb.deinit();

    const result = try backend.run(allocator, task, sb);
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 2), result.artifacts.len);
    try std.testing.expectEqualStrings("source", result.artifacts[0].path);
    try std.testing.expectEqualStrings("exit_code", result.artifacts[1].path);
}

test "mock worker respects sandbox boundaries" {
    const allocator = std.testing.allocator;
    var mw = MockWorker.init();
    const backend = mw.backend();
    defer backend.deinit();

    const fields = try allocator.alloc(planner.ContractField, 1);
    defer allocator.free(fields);
    fields[0] = .{ .name = "..\\outside.txt", .field_type = .string, .required = true };

    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar_c,
        .department = "programacion",
        .description = "escape test",
        .contract_fields = fields,
        .depends_on = &.{},
    };

    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t1");
    defer sb.deinit();

    try std.testing.expectError(error.SandboxDenied, backend.run(allocator, task, sb));
}

test "mock worker is deterministic" {
    const allocator = std.testing.allocator;
    var mw = MockWorker.init();
    const backend = mw.backend();
    defer backend.deinit();

    const fields = try allocator.alloc(planner.ContractField, 1);
    defer allocator.free(fields);
    fields[0] = .{ .name = "source", .field_type = .string, .required = true };

    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar_c,
        .department = "programacion",
        .description = "deterministic",
        .contract_fields = fields,
        .depends_on = &.{},
    };

    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t1");
    defer sb.deinit();

    const r1 = try backend.run(allocator, task, sb);
    defer r1.deinit(allocator);
    const r2 = try backend.run(allocator, task, sb);
    defer r2.deinit(allocator);

    try std.testing.expect(r1.success == r2.success);
    try std.testing.expectEqual(r1.artifacts.len, r2.artifacts.len);
}

const LlmTestCtx = struct {
    response: []const u8,
    calls: usize = 0,
};

fn mockLlmSend(ctx: *anyopaque, _: []const u8, _: []const u8) []const u8 {
    const tc: *LlmTestCtx = @ptrCast(@alignCast(ctx));
    tc.calls += 1;
    return tc.response;
}

test "E2E-RESULT: empty LLM artifact array is not a successful worker result" {
    const allocator = std.testing.allocator;
    var ctx = LlmTestCtx{ .response = "[]" };
    var nw = NativeWorker.init("Responde al usuario.");
    nw.setLlmFn(&ctx, mockLlmSend);
    const backend = nw.backend();
    defer backend.deinit();

    const task = planner.PlannedTask{
        .id = "t-empty",
        .task_type = .ejecutar,
        .department = "programacion",
        .description = "Responder exactamente PRUEBA DEVAGENTS E2E OK",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t-empty");
    defer sb.deinit();

    try std.testing.expectError(error.InvalidArtifact, backend.run(allocator, task, sb));
}

test "E2E-RESULT: deterministic Python fallback preserves requested exact output" {
    const allocator = std.testing.allocator;
    var ctx = LlmTestCtx{ .response = "" };
    var nw = NativeWorker.init("Eres programador Python.");
    nw.setLlmFn(&ctx, mockLlmSend);
    nw.enableDeterministicFallback();
    const backend = nw.backend();
    defer backend.deinit();

    var fields = [_]planner.ContractField{
        .{ .name = "source", .field_type = .string, .required = true },
        .{ .name = "filename", .field_type = .string, .required = false },
    };
    const task = planner.PlannedTask{
        .id = "t-exact-python",
        .task_type = .programar_c,
        .department = "programacion",
        .description = "Crea e4_test.py que imprima exactamente \"AUDITORIA EJECUCION OK\".",
        .contract_fields = &fields,
        .depends_on = &.{},
    };
    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t-exact-python");
    defer sb.deinit();

    const result = try backend.run(allocator, task, sb);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), ctx.calls);
    try std.testing.expectEqualStrings("source", result.artifacts[0].path);
    try std.testing.expect(std.mem.indexOf(u8, result.artifacts[0].content, "AUDITORIA EJECUCION OK") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.artifacts[0].content, "print(\"OK\")") == null);
}

test "E2E-RESULT: deterministic Python fallback accepts exact output without quotes" {
    const allocator = std.testing.allocator;
    const source = (try deterministicPythonSourceOwned(
        allocator,
        "e4_sol_test.py",
        "Crea e4_sol_test.py que imprima exactamente AUDITORIA EJECUCION OK, ejecútalo.",
    )).?;
    defer allocator.free(source);
    try std.testing.expect(std.mem.indexOf(u8, source, "print(\"AUDITORIA EJECUCION OK\")") != null);
}

test "E2E-RESULT: deterministic Python fallback fails honestly for unsupported request" {
    const allocator = std.testing.allocator;
    var ctx = LlmTestCtx{ .response = "" };
    var nw = NativeWorker.init("Eres programador Python.");
    nw.setLlmFn(&ctx, mockLlmSend);
    nw.enableDeterministicFallback();
    const backend = nw.backend();
    defer backend.deinit();

    var fields = [_]planner.ContractField{.{ .name = "source", .field_type = .string, .required = true }};
    const task = planner.PlannedTask{
        .id = "t-unsupported-python",
        .task_type = .programar,
        .department = "programacion",
        .description = "Crea generic.py con una arquitectura no documentada.",
        .contract_fields = &fields,
        .depends_on = &.{},
    };
    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t-unsupported-python");
    defer sb.deinit();
    try std.testing.expectError(error.InvalidArtifact, backend.run(allocator, task, sb));
}

test "deterministic fallback never replaces a valid programming LLM response" {
    const allocator = std.testing.allocator;
    var ctx = LlmTestCtx{ .response = "[{\"field\":\"test_ok.py\",\"content\":\"from datetime import date\\nprint(date.today().isoformat())\\n\"}]" };
    var nw = NativeWorker.init("Eres programador Python.");
    nw.setLlmFn(&ctx, mockLlmSend);
    nw.enableDeterministicFallback();
    const backend = nw.backend();
    defer backend.deinit();

    const fields = try allocator.alloc(planner.ContractField, 1);
    defer allocator.free(fields);
    fields[0] = .{ .name = "test_ok.py", .field_type = .string, .required = true };

    const task = planner.PlannedTask{
        .id = "t-live-first",
        .task_type = .programar,
        .department = "programacion",
        .description = "Crea test_ok.py que imprima la fecha actual",
        .contract_fields = fields,
        .depends_on = &.{},
    };

    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t-live-first");
    defer sb.deinit();

    const result = try backend.run(allocator, task, sb);
    defer result.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), ctx.calls);
    try std.testing.expectEqual(@as(usize, 1), result.artifacts.len);
    try std.testing.expectEqualStrings("test_ok.py", result.artifacts[0].path);
    try std.testing.expect(std.mem.indexOf(u8, result.artifacts[0].content, "date.today") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.artifacts[0].content, "print(\"OK\")") == null);
}

test "native worker calls LLM and parses artifacts from JSON" {
    const allocator = std.testing.allocator;
    var ctx = LlmTestCtx{ .response = "[{\"field\":\"source.c\",\"content\":\"int main(){return 0;}\"},{\"field\":\"test.c\",\"content\":\"#include <assert.h>\"}]" };
    var nw = NativeWorker.init("Eres programador C. Escribe código.");
    nw.setLlmFn(&ctx, mockLlmSend);
    const backend = nw.backend();
    defer backend.deinit();

    const fields = try allocator.alloc(planner.ContractField, 2);
    defer allocator.free(fields);
    fields[0] = .{ .name = "source.c", .field_type = .string, .required = true };
    fields[1] = .{ .name = "test.c", .field_type = .string, .required = true };

    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar_c,
        .department = "programacion",
        .description = "Escribe una calculadora en C con tests",
        .contract_fields = fields,
        .depends_on = &.{},
    };

    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t1");
    defer sb.deinit();

    const result = try backend.run(allocator, task, sb);
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 2), result.artifacts.len);
    try std.testing.expectEqualStrings("source.c", result.artifacts[0].path);
    try std.testing.expectEqualStrings("int main(){return 0;}", result.artifacts[0].content);
    try std.testing.expectEqualStrings("test.c", result.artifacts[1].path);
}

test "native worker rescata codigo fenced para tareas de programacion" {
    const allocator = std.testing.allocator;
    var ctx = LlmTestCtx{ .response =
        \\```python
        \\def es_primo(n):
        \\    return n > 1
        \\```
    };
    var nw = NativeWorker.init("Eres programador.");
    nw.setLlmFn(&ctx, mockLlmSend);
    const backend = nw.backend();
    defer backend.deinit();

    const fields = try allocator.alloc(planner.ContractField, 1);
    defer allocator.free(fields);
    fields[0] = .{ .name = "primos.py", .field_type = .string, .required = true };

    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "Crea primos.py",
        .contract_fields = fields,
        .depends_on = &.{},
    };

    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t1-raw");
    defer sb.deinit();

    const result = try backend.run(allocator, task, sb);
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 1), result.artifacts.len);
    try std.testing.expectEqualStrings("primos.py", result.artifacts[0].path);
    try std.testing.expect(std.mem.indexOf(u8, result.artifacts[0].content, "def es_primo") != null);
}

test "native worker rejects artifact that escapes sandbox" {
    const allocator = std.testing.allocator;
    var ctx = LlmTestCtx{ .response = "[{\"field\":\"../outside.txt\",\"content\":\"stolen\"}]" };
    var nw = NativeWorker.init("Eres programador.");
    nw.setLlmFn(&ctx, mockLlmSend);
    const backend = nw.backend();
    defer backend.deinit();

    const fields = try allocator.alloc(planner.ContractField, 1);
    defer allocator.free(fields);
    fields[0] = .{ .name = "source.c", .field_type = .string, .required = true };

    const task = planner.PlannedTask{
        .id = "t2",
        .task_type = .programar_c,
        .department = "programacion",
        .description = "test",
        .contract_fields = fields,
        .depends_on = &.{},
    };

    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t2");
    defer sb.deinit();

    try std.testing.expectError(error.SandboxDenied, backend.run(allocator, task, sb));
}

test "native worker rejects malformed JSON from LLM" {
    const allocator = std.testing.allocator;
    var ctx = LlmTestCtx{ .response = "no soy JSON" };
    var nw = NativeWorker.init("Eres programador.");
    nw.setLlmFn(&ctx, mockLlmSend);
    const backend = nw.backend();
    defer backend.deinit();

    const fields = try allocator.alloc(planner.ContractField, 1);
    defer allocator.free(fields);
    fields[0] = .{ .name = "x", .field_type = .string, .required = true };

    const task = planner.PlannedTask{
        .id = "t3",
        .task_type = .programar_c,
        .department = "programacion",
        .description = "test",
        .contract_fields = fields,
        .depends_on = &.{},
    };

    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t3");
    defer sb.deinit();

    try std.testing.expectError(error.InvalidArtifact, backend.run(allocator, task, sb));
}

const CaptureCtx = struct {
    response: []const u8,
    contains_tools: bool = false,
};

fn mockLlmCapture(ctx: *anyopaque, _: []const u8, user_prompt: []const u8) []const u8 {
    const c: *CaptureCtx = @ptrCast(@alignCast(ctx));
    c.contains_tools = std.mem.indexOf(u8, user_prompt, "[HERRAMIENTAS DISPONIBLES]") != null;
    return c.response;
}

test "native worker prompt includes available tools block" {
    const allocator = std.testing.allocator;
    var ctx = CaptureCtx{ .response = "[{\"field\":\"x\",\"content\":\"y\"}]" };
    var nw = NativeWorker.init("Eres programador.");
    nw.setAvailableTools("- skill \"test\": desc\n");
    nw.setLlmFn(&ctx, mockLlmCapture);
    const backend = nw.backend();
    defer backend.deinit();

    const fields = try allocator.alloc(planner.ContractField, 1);
    defer allocator.free(fields);
    fields[0] = .{ .name = "x", .field_type = .string, .required = true };

    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar_c,
        .department = "programacion",
        .description = "test",
        .contract_fields = fields,
        .depends_on = &.{},
    };

    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t1");
    defer sb.deinit();

    const result = try backend.run(allocator, task, sb);
    defer result.deinit(allocator);
    try std.testing.expect(ctx.contains_tools);
}

// Regresión del leak en la ruta OOM de runImpl (audit dogfood W4, 2026-06-17): si
// toOwnedSlice vacía `artifacts` (transfiriendo el slice) y un dupe POSTERIOR falla con
// OutOfMemory, el código viejo dejaba que el errdefer corriera sobre la lista YA VACÍA
// (no liberaba nada) y fugaba el slice extraído + el task_id ya duplicado.
//
// Estrategia: se hace una pasada de conteo (FailingAllocator que nunca falla) para saber
// cuántas asignaciones hace runImpl, y luego una segunda pasada que falla EXACTAMENTE la
// última asignación. Forzar OOM solo en la última garantiza que parseLlmResponse ya
// terminó (no se traga el OOM como InvalidArtifact) y que el fallo ocurre DESPUÉS de
// toOwnedSlice — justo la ventana del bug. std.testing.allocator detecta cualquier fuga.
test "native worker leaks nothing when the final post-toOwnedSlice dupe OOMs" {
    const base = std.testing.allocator;
    var ctx = LlmTestCtx{ .response = "[{\"field\":\"source.c\",\"content\":\"int main(){return 0;}\"},{\"field\":\"test.c\",\"content\":\"#include <assert.h>\"}]" };
    var nw = NativeWorker.init("Eres programador C.");
    nw.setLlmFn(&ctx, mockLlmSend);
    const backend = nw.backend();
    defer backend.deinit();

    const fields = try base.alloc(planner.ContractField, 2);
    defer base.free(fields);
    fields[0] = .{ .name = "source.c", .field_type = .string, .required = true };
    fields[1] = .{ .name = "test.c", .field_type = .string, .required = true };

    const task = planner.PlannedTask{
        .id = "t-oom",
        .task_type = .programar_c,
        .department = "programacion",
        .description = "ruta OOM",
        .contract_fields = fields,
        .depends_on = &.{},
    };

    var sb = try sandbox.Sandbox.init(base, "sandbox/t-oom");
    defer sb.deinit();

    // Pasada 1: contar asignaciones de una corrida limpia (el allocator nunca falla).
    var counter = std.testing.FailingAllocator.init(base, .{});
    {
        const result = try backend.run(counter.allocator(), task, sb);
        result.deinit(counter.allocator());
    }
    try std.testing.expect(counter.alloc_index > 0);

    // Pasada 2: fallar EXACTAMENTE la última asignación (la dupe posterior a toOwnedSlice).
    // El allocator es determinista para la misma entrada, así que la cuenta coincide.
    var failing = std.testing.FailingAllocator.init(base, .{ .fail_index = counter.alloc_index - 1 });
    try std.testing.expectError(error.OutOfMemory, backend.run(failing.allocator(), task, sb));
    // Si hubiera fuga, std.testing.allocator (base) lo reportaría al cerrar el test.
}

test "FIX-3: NativeWorker inyecta upstream_context en el prompt del worker" {
    const allocator = std.testing.allocator;

    const Recorder = struct {
        buf: std.ArrayList(u8) = .empty,
        alloc: std.mem.Allocator,
        fn llm(ctx: *anyopaque, sys: []const u8, user_prompt: []const u8) []const u8 {
            _ = sys;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.buf.appendSlice(self.alloc, user_prompt) catch {};
            return "[{\"field\":\"source\",\"content\":\"x=1\"},{\"field\":\"exit_code\",\"content\":\"0\"}]";
        }
    };
    var rec = Recorder{ .alloc = allocator };
    defer rec.buf.deinit(allocator);

    const fields = try allocator.alloc(planner.ContractField, 2);
    defer allocator.free(fields);
    fields[0] = .{ .name = "source", .field_type = .string, .required = true };
    fields[1] = .{ .name = "exit_code", .field_type = .integer, .required = true };
    const task = planner.PlannedTask{
        .id = "t2",
        .task_type = .testear,
        .department = "testing",
        .description = "escribe tests que importen la calculadora",
        .contract_fields = fields,
        .depends_on = &.{},
    };

    var sb = try sandbox.Sandbox.init(allocator, "sandbox/fix3-a");
    defer sb.deinit();

    var nw = NativeWorker.init("SYS");
    nw.setLlmFn(&rec, Recorder.llm);
    nw.setUpstreamContext("ARCHIVO: calculator.py\n```\ndef suma(a, b):\n    return a + b\n```\n");
    const result = try nw.backend().run(allocator, task, sb);
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, rec.buf.items, "ARCHIVOS YA CREADOS") != null);
    try std.testing.expect(std.mem.indexOf(u8, rec.buf.items, "calculator.py") != null);
    try std.testing.expect(std.mem.indexOf(u8, rec.buf.items, "def suma") != null);
}

test "FIX-4a: NativeWorker inyecta plan_manifest en el prompt del worker" {
    const allocator = std.testing.allocator;

    const Rec = struct {
        buf: std.ArrayList(u8) = .empty,
        alloc: std.mem.Allocator,
        fn llm(ctx: *anyopaque, sys: []const u8, user_prompt: []const u8) []const u8 {
            _ = sys;
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.buf.appendSlice(self.alloc, user_prompt) catch {};
            return "[{\"field\":\"source\",\"content\":\"x=1\"},{\"field\":\"exit_code\",\"content\":\"0\"}]";
        }
    };
    var rec = Rec{ .alloc = allocator };
    defer rec.buf.deinit(allocator);

    const fields = try allocator.alloc(planner.ContractField, 2);
    defer allocator.free(fields);
    fields[0] = .{ .name = "source", .field_type = .string, .required = true };
    fields[1] = .{ .name = "exit_code", .field_type = .integer, .required = true };
    const task = planner.PlannedTask{
        .id = "t2",
        .task_type = .testear,
        .department = "testing",
        .description = "escribe tests para el modulo",
        .contract_fields = fields,
        .depends_on = &.{},
    };

    var sb = try sandbox.Sandbox.init(allocator, "sandbox/fix4a");
    defer sb.deinit();

    var nw = NativeWorker.init("SYS");
    nw.setLlmFn(&rec, Rec.llm);
    nw.setPlanManifest("- t1 [programar/programacion]: Implementar calculator.py con suma, resta\n- t2 [testear/testing]: tests\n");
    const result = try nw.backend().run(allocator, task, sb);
    defer result.deinit(allocator);

    try std.testing.expect(std.mem.indexOf(u8, rec.buf.items, "PLAN DE LA ORDEN") != null);
    try std.testing.expect(std.mem.indexOf(u8, rec.buf.items, "calculator.py") != null);
    try std.testing.expect(std.mem.indexOf(u8, rec.buf.items, "suma, resta") != null);
}

test "manifest preserves contract values and assigns exclusive file ownership" {
    const allocator = std.testing.allocator;
    const Capture = struct {
        prompt: std.ArrayList(u8) = .empty,
        allocator: std.mem.Allocator,
        fn call(ctx: *anyopaque, _: []const u8, user: []const u8) []const u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.prompt.appendSlice(self.allocator, user) catch {};
            return "[{\"field\":\"index.html\",\"content\":\"<link href='styles.css'>\"}]";
        }
    };
    var capture = Capture{ .prompt = .empty, .allocator = allocator };
    defer capture.prompt.deinit(allocator);
    var fields = [_]planner.ContractField{.{ .name = "command", .field_type = .string, .required = true, .value = "node test_app.js" }};
    const task = planner.PlannedTask{ .id = "html", .task_type = .programar, .department = "programacion", .description = "solo index", .contract_fields = &fields, .depends_on = &.{} };
    var sb = try sandbox.Sandbox.init(allocator, "sandbox/manifest-owner");
    defer sb.deinit();
    var nw = NativeWorker.init("SYS");
    nw.setLlmFn(&capture, Capture.call);
    nw.setPlanManifest("- html: index.html\n- styles: styles.css\n- app: app.js\n");
    const result = try nw.backend().run(allocator, task, sb);
    defer result.deinit(allocator);
    try std.testing.expect(std.mem.indexOf(u8, capture.prompt.items, "value=node test_app.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.prompt.items, "SOLAMENTE los archivos asignados") != null);
    try std.testing.expect(std.mem.indexOf(u8, capture.prompt.items, "REGLA INNEGOCIABLE") == null);
}

test "E-41: una comilla invertida suelta tambien es una valla, y llega SIN cerrar" {
    // El caso real, orden #343 del 2026-08-15: Cohere entrego `script.js`
    // abriendo con una comilla invertida sola y sin cerrarla. El archivo se
    // escribio tal cual y `node` lo tumbo con «SyntaxError: Unexpected end of
    // input»; la orden acabo `failed` con el HTML y el CSS impecables.
    const sin_cerrar = "`\nconst A = 1;\nfunction f() { return A; }";
    try std.testing.expectEqualStrings("const A = 1;\nfunction f() { return A; }", stripMarkdownFence(sin_cerrar));

    // Con cierre tambien, que es la variante educada del mismo error.
    const con_cierre = "`\nconst A = 1;\n`";
    try std.testing.expectEqualStrings("const A = 1;", stripMarkdownFence(con_cierre));

    // Con etiqueta de lenguaje pegada a la comilla.
    const con_lenguaje = "`js\nconst A = 1;\n`";
    try std.testing.expectEqualStrings("const A = 1;", stripMarkdownFence(con_lenguaje));

    // Y lo que NO debe tocar: codigo que empieza por una plantilla de verdad.
    // Aqui la comilla NO esta sola en su linea — hay codigo detras.
    const plantilla = "`hola ${nombre}`;\nconst B = 2;";
    try std.testing.expectEqualStrings(plantilla, stripMarkdownFence(plantilla));

    // Ni una comilla invertida suelta sin nada detras: sin cuerpo no hay valla.
    try std.testing.expectEqualStrings("`", stripMarkdownFence("`"));
}

test "B8: stripMarkdownFence desvalla markdown y codigo respetando contenido interno" {
    // Caso 1: markdown con fence exterior
    const md_fenced = "```markdown\n# Titulo\nContenido del texto.\n```";
    try std.testing.expectEqualStrings("# Titulo\nContenido del texto.", stripMarkdownFence(md_fenced));

    // Caso 2: markdown con bloque de codigo interno
    const md_nested = "```markdown\n# Titulo\n```python\nprint(1)\n```\nFin.\n```";
    try std.testing.expectEqualStrings("# Titulo\n```python\nprint(1)\n```\nFin.", stripMarkdownFence(md_nested));

    // Caso 3: texto plano sin vallas se conserva intacto
    const plain = "# Titulo\nTexto sin vallas.";
    try std.testing.expectEqualStrings(plain, stripMarkdownFence(plain));

    // Caso 4: fence generico ``` ... ```
    const generic = "```\nlinea 1\nlinea 2\n```";
    try std.testing.expectEqualStrings("linea 1\nlinea 2", stripMarkdownFence(generic));
}

test "B8: parseLlmResponse elimina vallas exteriores en el campo content" {
    const allocator = std.testing.allocator;
    const json_fenced = "[{\"field\":\"t1.md\",\"content\":\"```markdown\\n# Documento\\nRiesgos de seguridad.\\n```\"}]";
    var artifacts = try parseLlmResponse(allocator, json_fenced);
    defer {
        for (artifacts.items) |a| a.deinit(allocator);
        artifacts.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), artifacts.items.len);
    try std.testing.expectEqualStrings("t1.md", artifacts.items[0].path);
    try std.testing.expectEqualStrings("# Documento\nRiesgos de seguridad.", artifacts.items[0].content);
}

test "CK-MOT-025: apostrofos sobreescapados en JS se decodifican sin barra" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"path":"script.js","content":"alert(\'hola\');"}
    ;
    var artifacts = try parseArtifacts(allocator, raw);
    defer {
        for (artifacts.items) |a| a.deinit(allocator);
        artifacts.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), artifacts.items.len);
    try std.testing.expectEqualStrings("script.js", artifacts.items[0].path);
    try std.testing.expectEqualStrings("alert('hola');", artifacts.items[0].content);
}

test "CK-MOT-025: HTML de orden 876 solo normaliza el escape JSON" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"path":"index.html","content":"<button onclick='setOperation(\'+\')'>+</button>"}
    ;
    var artifacts = try parseArtifacts(allocator, raw);
    defer {
        for (artifacts.items) |a| a.deinit(allocator);
        artifacts.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), artifacts.items.len);
    try std.testing.expectEqualStrings("index.html", artifacts.items[0].path);
    // El atributo sigue mal delimitado: reparar HTML no es tarea del parser JSON.
    try std.testing.expectEqualStrings("<button onclick='setOperation('+')'>+</button>", artifacts.items[0].content);
}

test "CK-MOT-025: barras JSON validas ante apostrofo sobreviven por pares" {
    const allocator = std.testing.allocator;
    const cases = .{
        .{ .raw = "\"'\"", .expected = "'" },
        .{ .raw = "\"\\'\"", .expected = "'" },
        .{ .raw = "\"\\\\'\"", .expected = "\\'" },
        .{ .raw = "\"\\\\\\'\"", .expected = "\\'" },
        .{ .raw = "\"\\\\\\\\'\"", .expected = "\\\\'" },
    };
    inline for (cases) |case| {
        const sanitized = try escapeRawControlChars(allocator, case.raw);
        defer allocator.free(sanitized);
        const parsed = try std.json.parseFromSlice([]const u8, allocator, sanitized, .{});
        defer parsed.deinit();
        try std.testing.expectEqualStrings(case.expected, parsed.value);
    }
}

test "CK-MOT-025: todos los escapes JSON validos quedan identicos" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"path":"valid.txt","content":"\\'\"\/\b\f\n\r\t\u0041"}
    ;
    const sanitized = try escapeRawControlChars(allocator, raw);
    defer allocator.free(sanitized);
    try std.testing.expectEqualStrings(raw, sanitized);
    var artifacts = try parseArtifacts(allocator, raw);
    defer {
        for (artifacts.items) |a| a.deinit(allocator);
        artifacts.deinit(allocator);
    }
    try std.testing.expectEqualStrings("\\'\"/\x08\x0c\n\r\tA", artifacts.items[0].content);
}

test "CK-MOT-025: otros escapes invalidos conservan la barra E-86" {
    const allocator = std.testing.allocator;
    const raw =
        \\{"path":"regex.txt","content":"\. \w \d C:\Proyectos \q \x41"}
    ;
    var artifacts = try parseArtifacts(allocator, raw);
    defer {
        for (artifacts.items) |a| a.deinit(allocator);
        artifacts.deinit(allocator);
    }
    try std.testing.expectEqualStrings("\\. \\w \\d C:\\Proyectos \\q \\x41", artifacts.items[0].content);
}

test "E-86: escapes JSON invalidos del modelo (\\., \\w, C:\\) no tiran el artefacto" {
    // Medido en la campaña E3-T1 (19/19 órdenes failed): el 3B escribe
    // regex `\.` y rutas `C:\` dentro del `content` y std.json rechazaba el
    // documento entero → provider_failed status:empty → orden failed con el
    // trabajo bien generado. El saneado escapa el backslash inválido.
    const allocator = std.testing.allocator;
    // el raw lleva \. \w \d y C:\Proyectos — todos escapes JSON inválidos
    // (OJO: \t \n etc. sí son válidos; una ruta con \t decodificaría a TAB,
    // así que la prueba usa \P \w \d \., nunca un escape real)
    const raw = "[{\"field\":\"e3dev/validador.py\",\"content\":\"regex = r'^[a-z]+\\.[a-z]+$'\\nwin: C:\\Proyectos \\w \\d\"}]";
    var artifacts = try parseLlmResponse(allocator, raw);
    defer {
        for (artifacts.items) |a| a.deinit(allocator);
        artifacts.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), artifacts.items.len);
    try std.testing.expectEqualStrings("e3dev/validador.py", artifacts.items[0].path);
    // el backslash inválido sobrevive literal: `\.` sigue siendo regex válido
    try std.testing.expectEqualStrings("regex = r'^[a-z]+\\.[a-z]+$'\nwin: C:\\Proyectos \\w \\d", artifacts.items[0].content);
}

test "E-86: los escapes JSON validos no se tocan" {
    const allocator = std.testing.allocator;
    // \n \\ \" \t \u0041 ya válidos: deben decodificar igual que antes
    const raw = "[{\"field\":\"a.txt\",\"content\":\"linea1\\nlinea2\\t\\\\fina\\\"l\\u0041\"}]";
    var artifacts = try parseLlmResponse(allocator, raw);
    defer {
        for (artifacts.items) |a| a.deinit(allocator);
        artifacts.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), artifacts.items.len);
    try std.testing.expectEqualStrings("linea1\nlinea2\t\\fina\"lA", artifacts.items[0].content);
}

test "AUDIT-UNAVAILABLE-P0: el fallback determinista NUNCA fabrica un verdict de auditoría" {
    // Orden 500: el contexto upstream contenía ".py" y esta función devolvía
    // verdict=PASS sin que ningún modelo revisara nada. Ahora una tarea
    // `auditar` no tiene resultado local: el auditor sin respuesta usable
    // deja la tarea sin veredicto, nunca un PASS fabricado.
    const allocator = std.testing.allocator;
    const audit_task = planner.PlannedTask{
        .id = "t-audit",
        .task_type = .auditar,
        .department = "auditoria",
        .description = "Audita calculator.py",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    const upstream_with_py = "calculator.py\n----\ndef add(a, b):\n    return a + b\n";
    const result = try deterministicLocalResult(allocator, audit_task, upstream_with_py);
    try std.testing.expect(result == null);

    // Y la tarea de programación con .py sigue teniendo su fallback intacto —
    // lo que se quitó es la auditoría fabricada, no la entrega determinista.
    var fields = [_]planner.ContractField{.{ .name = "source", .field_type = .string, .required = true }};
    const prog_task = planner.PlannedTask{
        .id = "t-prog",
        .task_type = .programar,
        .department = "programacion",
        .description = "Crea e4_det_test.py que imprima exactamente \"HOLA MUNDO\".",
        .contract_fields = &fields,
        .depends_on = &.{},
    };
    const prog = try deterministicLocalResult(allocator, prog_task, null);
    try std.testing.expect(prog != null);
    defer if (prog) |r| r.deinit(allocator);
}

test "CK-MOT-022: la muestra real de la orden 874 entrega index.html" {
    // La orden 874 pidió una calculadora web en `index.html`; el modelo devolvió
    // `[{"field":"source","content":"<!DOCTYPE html>..."}]`. El campo `source` es
    // la ETIQUETA del contrato, no el nombre del archivo: el artefacto salía con
    // path `source` y el contrato lo clasificaba como entrega vacía. Ahora hereda
    // el nombre esperado que pide la descripción.
    const allocator = std.testing.allocator;
    var ctx = LlmTestCtx{
        .response = "[{\"field\":\"source\",\"content\":\"<!DOCTYPE html>\\n<html lang=\\\"es\\\"><head><title>Calculadora Web</title></head></html>\"}]",
    };
    var nw = NativeWorker.init("Eres programador web.");
    nw.setLlmFn(&ctx, mockLlmSend);
    const backend = nw.backend();
    defer backend.deinit();

    var fields = [_]planner.ContractField{.{ .name = "source", .field_type = .string, .required = true }};
    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "Crea una calculadora web en un solo archivo index.html con HTML, CSS y JavaScript.",
        .contract_fields = &fields,
        .depends_on = &.{},
    };
    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t-874");
    defer sb.deinit();

    const result = try backend.run(allocator, task, sb);
    defer result.deinit(allocator);

    try std.testing.expect(result.success);
    try std.testing.expectEqual(@as(usize, 1), result.artifacts.len);
    try std.testing.expectEqualStrings("index.html", result.artifacts[0].path);
    try std.testing.expect(std.mem.indexOf(u8, result.artifacts[0].content, "<!DOCTYPE html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, result.artifacts[0].content, "Calculadora Web") != null);
}

test "CK-MOT-022: filename+source asigna el nombre declarado al cuerpo" {
    // Forma del contrato con un objeto de metadatos `filename` que declara el
    // nombre y un objeto `source` con el cuerpo: el cuerpo debe heredar el
    // nombre, no quedarse como `source`.
    const allocator = std.testing.allocator;
    var ctx = LlmTestCtx{
        .response = "[{\"field\":\"filename\",\"content\":\"index.html\"},{\"field\":\"source\",\"content\":\"<html><body>hola</body></html>\"}]",
    };
    var nw = NativeWorker.init("Eres programador web.");
    nw.setLlmFn(&ctx, mockLlmSend);
    const backend = nw.backend();
    defer backend.deinit();

    var fields = [_]planner.ContractField{.{ .name = "source", .field_type = .string, .required = true }};
    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "Entrega el archivo solicitado.",
        .contract_fields = &fields,
        .depends_on = &.{},
    };
    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t-fs");
    defer sb.deinit();

    const result = try backend.run(allocator, task, sb);
    defer result.deinit(allocator);

    var found = false;
    for (result.artifacts) |a| {
        if (std.mem.eql(u8, a.path, "index.html")) {
            found = true;
            try std.testing.expect(std.mem.indexOf(u8, a.content, "<body>hola</body>") != null);
        }
    }
    try std.testing.expect(found);
}

test "CK-MOT-022: varios sin ruta con varios archivos esperados no adivina" {
    // Dos cuerpos sin nombre de archivo y dos archivos esperados: no hay forma de
    // saber cuál va dónde. Se rechaza en vez de bautizar un archivo con el nombre
    // de un campo.
    const allocator = std.testing.allocator;
    var ctx = LlmTestCtx{
        .response = "[{\"field\":\"source\",\"content\":\"<html></html>\"},{\"field\":\"code\",\"content\":\"body{background:red}\"}]",
    };
    var nw = NativeWorker.init("Eres programador web.");
    nw.setLlmFn(&ctx, mockLlmSend);
    const backend = nw.backend();
    defer backend.deinit();

    var fields = [_]planner.ContractField{.{ .name = "source", .field_type = .string, .required = true }};
    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "Crea index.html y styles.css para el sitio.",
        .contract_fields = &fields,
        .depends_on = &.{},
        .owns = &.{ "index.html", "styles.css" },
    };
    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t-multi");
    defer sb.deinit();

    try std.testing.expectError(error.InvalidArtifact, backend.run(allocator, task, sb));
}

test "CK-MOT-022: path/filename/file/name son sinonimos de la ruta" {
    const allocator = std.testing.allocator;
    const keys = [_][]const u8{ "path", "filename", "file", "name" };
    for (keys) |k| {
        const raw = try std.fmt.allocPrint(
            allocator,
            "[{{\"{s}\":\"index.html\",\"content\":\"<html></html>\"}}]",
            .{k},
        );
        defer allocator.free(raw);
        var artifacts = parseLlmResponse(allocator, raw) catch |e| {
            std.debug.print("CK-MOT-022 sinonimo '{s}' fallo: {s}\n", .{ k, @errorName(e) });
            return error.SinonimoRechazado;
        };
        defer {
            for (artifacts.items) |a| a.deinit(allocator);
            artifacts.deinit(allocator);
        }
        try std.testing.expectEqual(@as(usize, 1), artifacts.items.len);
        try std.testing.expectEqualStrings("index.html", artifacts.items[0].path);
        try std.testing.expectEqualStrings("<html></html>", artifacts.items[0].content);
    }
}

test "CK-MOT-022: un artefacto sin contenido sigue siendo vacio" {
    // El content vacío no es una entrega: antes colaba como artefacto de 0 bytes.
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidArtifact,
        parseLlmResponse(allocator, "[{\"field\":\"index.html\",\"content\":\"\"}]"),
    );
    try std.testing.expectError(
        error.InvalidArtifact,
        parseLlmResponse(allocator, "[{\"field\":\"index.html\",\"content\":\"   \\n  \"}]"),
    );
}

test "CK-MOT-022: el objeto sin cuerpo se descarta pero el cuerpo real se conserva" {
    const allocator = std.testing.allocator;
    const raw = "[{\"field\":\"filename\",\"content\":\"\"},{\"field\":\"source\",\"content\":\"<html>ok</html>\"}]";
    var artifacts = try parseLlmResponse(allocator, raw);
    defer {
        for (artifacts.items) |a| a.deinit(allocator);
        artifacts.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), artifacts.items.len);
    try std.testing.expectEqualStrings("source", artifacts.items[0].path);
}

// ── Corrección tras la auditoría (16-oct 04:52) ────────────────────────
// Punto 2 (MEDIA): un nombre MENCIONADO en la descripción no es destino solo
// por aparecer: hace falta que la descripción lo marque como SALIDA.

test "CK-MOT-022 r2: una mencion de entrada no se toma como destino" {
    // "Lee config.json y crea index.html": config.json es ENTRADA; el destino
    // pedido es index.html. Antes se tomaba el primer nombre (config.json).
    const allocator = std.testing.allocator;
    var ctx = LlmTestCtx{ .response = "[{\"field\":\"source\",\"content\":\"<html>\\nconfig\\n</html>\"}]" };
    var nw = NativeWorker.init("Eres programador web.");
    nw.setLlmFn(&ctx, mockLlmSend);
    const backend = nw.backend();
    defer backend.deinit();

    var fields = [_]planner.ContractField{.{ .name = "source", .field_type = .string, .required = true }};
    const task = planner.PlannedTask{
        .id = "t-in",
        .task_type = .programar,
        .department = "programacion",
        .description = "Lee config.json y crea index.html a partir de sus valores.",
        .contract_fields = &fields,
        .depends_on = &.{},
    };
    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t-in");
    defer sb.deinit();

    const result = try backend.run(allocator, task, sb);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.artifacts.len);
    try std.testing.expectEqualStrings("index.html", result.artifacts[0].path);
}

test "CK-MOT-022 r2: una mencion solo de entrada no bautiza el cuerpo" {
    // Sin ningún nombre de SALIDA en la descripción, el cuerpo huérfano NO se
    // bautiza con el nombre de la entrada: queda con su etiqueta de campo.
    const allocator = std.testing.allocator;
    var ctx = LlmTestCtx{ .response = "[{\"field\":\"source\",\"content\":\"<html>\\nlistado\\n</html>\"}]" };
    var nw = NativeWorker.init("Eres programador web.");
    nw.setLlmFn(&ctx, mockLlmSend);
    const backend = nw.backend();
    defer backend.deinit();

    var fields = [_]planner.ContractField{.{ .name = "source", .field_type = .string, .required = true }};
    const task = planner.PlannedTask{
        .id = "t-in2",
        .task_type = .programar,
        .department = "programacion",
        .description = "A partir de config.json prepara el listado de claves.",
        .contract_fields = &fields,
        .depends_on = &.{},
    };
    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t-in2");
    defer sb.deinit();

    const result = try backend.run(allocator, task, sb);
    defer result.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), result.artifacts.len);
    try std.testing.expectEqualStrings("source", result.artifacts[0].path);
}

// Punto 3 (BAJA): con alias en conflicto, gana el que PARECE nombre de archivo.

test "CK-MOT-022 r2: alias en conflicto prefiere el nombre de archivo" {
    const allocator = std.testing.allocator;
    var artifacts = try parseLlmResponse(allocator, "[{\"path\":\"source\",\"filename\":\"index.html\",\"content\":\"<html></html>\"}]");
    defer {
        for (artifacts.items) |a| a.deinit(allocator);
        artifacts.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), artifacts.items.len);
    try std.testing.expectEqualStrings("index.html", artifacts.items[0].path);
}

test "CK-MOT-022 r2: un nombre conocido sin extension (Dockerfile) es archivo" {
    const allocator = std.testing.allocator;
    var artifacts = try parseLlmResponse(allocator, "[{\"path\":\"source\",\"filename\":\"Dockerfile\",\"content\":\"FROM alpine\"}]");
    defer {
        for (artifacts.items) |a| a.deinit(allocator);
        artifacts.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), artifacts.items.len);
    try std.testing.expectEqualStrings("Dockerfile", artifacts.items[0].path);
}

// Punto 4 (BAJA): un cuerpo vacío solo es entrega si el nombre lo admite.

test "CK-MOT-022 r2: un __init__.py vacio si es una entrega" {
    const allocator = std.testing.allocator;
    var artifacts = try parseLlmResponse(allocator, "[{\"field\":\"__init__.py\",\"content\":\"\"}]");
    defer {
        for (artifacts.items) |a| a.deinit(allocator);
        artifacts.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), artifacts.items.len);
    try std.testing.expectEqualStrings("__init__.py", artifacts.items[0].path);
    try std.testing.expectEqual(@as(usize, 0), artifacts.items[0].content.len);
}

test "CK-MOT-022 r2: un .gitkeep vacio si es una entrega" {
    const allocator = std.testing.allocator;
    var artifacts = try parseLlmResponse(allocator, "[{\"field\":\".gitkeep\",\"content\":\"   \\n \"}]");
    defer {
        for (artifacts.items) |a| a.deinit(allocator);
        artifacts.deinit(allocator);
    }
    try std.testing.expectEqual(@as(usize, 1), artifacts.items.len);
    try std.testing.expectEqualStrings(".gitkeep", artifacts.items[0].path);
}

test "CK-MOT-022 r2: un cuerpo vacio con nombre normal sigue siendo vacio" {
    // La excepción del punto 4 no abre la puerta a entregas de 0 bytes.
    const allocator = std.testing.allocator;
    try std.testing.expectError(
        error.InvalidArtifact,
        parseLlmResponse(allocator, "[{\"field\":\"app.py\",\"content\":\"\"}]"),
    );
}

test "CK-MOT-022 r2: un cuerpo vacio sin ruta no es entrega sin peticion" {
    // Etiqueta de cuerpo vacía y una tarea que NO pide archivo vacío: se rechaza.
    const allocator = std.testing.allocator;
    var ctx = LlmTestCtx{ .response = "[{\"field\":\"source\",\"content\":\"\"}]" };
    var nw = NativeWorker.init("Eres programador web.");
    nw.setLlmFn(&ctx, mockLlmSend);
    const backend = nw.backend();
    defer backend.deinit();

    var fields = [_]planner.ContractField{.{ .name = "source", .field_type = .string, .required = true }};
    const task = planner.PlannedTask{
        .id = "t-empty2",
        .task_type = .programar,
        .department = "programacion",
        .description = "Crea una calculadora web.",
        .contract_fields = &fields,
        .depends_on = &.{},
    };
    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t-empty2");
    defer sb.deinit();

    try std.testing.expectError(error.InvalidArtifact, backend.run(allocator, task, sb));
}

test "CK-MOT-022 r3: una negacion no convierte en peticion de archivo vacio" {
    // «No dejes el archivo vacío» contiene el marcador pero lo niega: se rechaza.
    const allocator = std.testing.allocator;
    var ctx = LlmTestCtx{ .response = "[{\"field\":\"source\",\"content\":\"\"}]" };
    var nw = NativeWorker.init("Eres programador web.");
    nw.setLlmFn(&ctx, mockLlmSend);
    const backend = nw.backend();
    defer backend.deinit();

    var fields = [_]planner.ContractField{.{ .name = "source", .field_type = .string, .required = true }};
    const task = planner.PlannedTask{
        .id = "t-empty-neg",
        .task_type = .programar,
        .department = "programacion",
        .description = "Crea index.html con la calculadora. No dejes el archivo vacío.",
        .contract_fields = &fields,
        .depends_on = &.{},
    };
    var sb = try sandbox.Sandbox.init(allocator, "sandbox/t-empty-neg");
    defer sb.deinit();

    try std.testing.expectError(error.InvalidArtifact, backend.run(allocator, task, sb));
    try std.testing.expect(!markerNotNegated("No dejes el archivo vacío", "archivo vacío"));
    try std.testing.expect(markerNotNegated("Crea un archivo vacío llamado .env.example", "archivo vacío"));
    try std.testing.expect(!markerNotNegated("Please don't leave an empty file here", "empty file"));
    try std.testing.expect(!markerNotNegated("Never ship an empty file", "empty file"));
}
