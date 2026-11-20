//! · Modo Directo: «un solo modelo, como una CLI».
//!
//! El propietario (8-nov): si el usuario quiere usar un solo modelo «con normalidad,
//! como en cualquier otra IDE», DevAgents debe funcionar así desde el inicio:
//! conversar, ejecutar tareas, leer y editar el proyecto. Lo propio de
//! DevAgents (planificador, colmena, auditoría, Mejor de N) se añade aparte.
//!
//! Diseño: un `PlannerBackend` que NO planifica. Recibe la orden, abre una
//! sesión con el modelo elegido (o el primero apto si está en Automático) y
//! le da las herramientas gobernadas de siempre sobre la carpeta del proyecto
//! (`read_file`, `list_dir`, `grep_files`, `write_file`, `edit_file`,
//! `run_command`, `finish`) con la política de permisos viva de la cabina. Lo
//! que el modelo contesta vuelve como plan `chat` sin tareas, así que el
//! superagente cierra la orden `done` con esa respuesta por la misma ruta que
//! cualquier charla: sin plan, reparto, colmena ni auditoría, y la cabina lo
//! pinta como un turno normal (con sus eventos de herramientas en Actividad).
//!
//! Sin herramientas (el modelo fijado no las admite según la medición viva) el
//! modo sigue funcionando como conversación y lo dice en la respuesta.

const std = @import("std");
const db = @import("db.zig");
const planner = @import("planner.zig");
const live_worker = @import("live_worker.zig");
const executor = @import("executor.zig");
const workspace = @import("workspace.zig");
const sync = @import("sync.zig");
const llm_planner = @import("llm_planner.zig");
const external_agents = @import("external_agents.zig");
const external_registry = @import("external_registry.zig");
const sandbox = @import("sandbox.zig");
const health = @import("health.zig");
const browser_service = @import("browser_service.zig");
const providers = @import("providers");
const project_rules = @import("project_rules.zig");
const cli_accounts = @import("cli_accounts.zig");
const GetFileAttributesW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileAttributesW(name: [*:0]const u16) callconv(.winapi) u32;
}.GetFileAttributesW else @import("providers").posix_files.GetFileAttributesW;

/// Techo de rondas de herramientas por mensaje (el bridge no admite más de 32).
pub const MAX_ROUNDS: usize = 32;
/// Turnos previos de la conversación que viajan en el prompt.
const MAX_HISTORY_TURNS: usize = 12;
/// Cada texto de un turno previo se recorta a este tamaño.
const MAX_TURN_BYTES: usize = 6000;

pub const SYSTEM_PROMPT =
    "Eres el asistente de programación de DevAgents en modo Directo: un solo modelo que trabaja con el usuario como lo haría cualquier CLI o IDE de IA.\n" ++
    "- Si el usuario conversa o pregunta, responde con normalidad, en su idioma, sin usar herramientas que no hagan falta.\n" ++
    "- Si pide trabajo sobre el proyecto (crear, cambiar, revisar o ejecutar algo), hazlo de verdad con las herramientas: lee antes de editar, escribe los archivos completos, ejecuta lo necesario para comprobarlo y, al terminar, llama a `finish` con un resumen y la lista de archivos tocados.\n" ++
    "- Las rutas son relativas a la carpeta del proyecto. Un comando puede necesitar la aprobación del usuario o ser denegado: si pasa, explícalo y sigue con lo que puedas.\n" ++
    "- Tu respuesta final es lo que el usuario lee en el chat: basa el cierre en los resultados de las herramientas. Cita las rutas ya escritas como trabajo hecho, detalla el resultado de cada ejecución y evita pasos manuales redundantes y emojis.\n";

const PROCESSES_NOTE =
    "- En la cabina de Windows, para ventanas, servidores y observadores que deben seguir activos tras el turno, usa run_command con background=true. Guarda process_id y lease_generation para consultar process_logs o parar con process_stop. Usa el primer plano para comandos que deban terminar. Si vence el plazo, indica que DevAgents lo detuvo y ofrece relanzarlo en segundo plano.\n";

/// B1 (10-nov): las firmas de las herramientas ya viajan en sus definiciones
/// (nombre, descripción y esquema); repetirlas aquí costaba ~1,1 KB por vuelta.
/// Quedan solo las dos reglas de conducta que ninguna definición dice. El
/// navegador se anuncia con una línea desde `live_worker` (carga diferida) y
/// solo cuando la sesión tiene navegador. Público para la medición de tokens
/// (live_worker, prueba «B1 tarea 3»).
pub const TOOLS_PROMPT =
    "\n[HERRAMIENTAS]\n" ++
    PROCESSES_NOTE ++
    "- Con web_search y web_fetch buscas en internet: si el usuario lo pide o la respuesta depende de información actual, úsalas y cita las URL. Nunca digas que no puedes buscar.\n" ++
    "- Nunca digas que creaste, editaste o guardaste un archivo que no escribiste con write_file o edit_file en esta vuelta: DevAgents muestra al usuario los archivos que cambiaron de verdad.\n";

/// USUARIO-NUEVO B (10-nov): modo «DevAgents». Se añade al prompt de Directo
/// solo cuando la conversación puede delegar.
pub const DELEGATE_PROMPT =
    "\n[MODO DEVAGENTS: DELEGAR]\n" ++
    "- Tienes además delegate_tasks{tasks:[{role, instruction, files?, model?}]}: lanza hasta 4 subtareas EN PARALELO, cada una en su propia copia del proyecto, auditada por otro modelo.\n" ++
    "- Conversa normal y haz tú lo pequeño. Delega solo cuando la petición tenga partes INDEPENDIENTES que ganen haciéndose a la vez; nunca para saludar, responder preguntas o un cambio de un archivo.\n" ++
    "- Cada instruction debe ser completa: la subtarea no ve esta conversación. Reparte archivos distintos a cada subtarea (dos que tocan el mismo archivo no se integran a la vez).\n" ++
    "- Cuando vuelvan, revisa el resultado de cada una (estado, archivos, veredicto, si se integró) y responde al usuario con lo que quedó hecho y lo que no, sin inventar.\n" ++
    "- Si alguna no se integró, di cuántas se integraron («0 de 2») y copia para cada una su motivo del campo error (p. ej. la cuota diaria del auditor agotada) con lo que el usuario puede hacer, y dónde quedó su trabajo (campo worktree). No la des por hecha.\n";

const NO_TOOLS_PROMPT =
    "\n[SIN HERRAMIENTAS]\nEl modelo elegido no admite herramientas (medición viva del catálogo): solo puedes conversar. Si el usuario pide editar o ejecutar, dale el contenido o los pasos y dile que, para que lo hagas tú, elija un modelo con herramientas.\n";

/// (9-nov): Directo con un agente externo (Claude Code, Codex,
/// Gemini CLI, OpenCode) elegido en «Modelo». El agente trabaja con SUS
/// herramientas y SU suscripción directamente en la carpeta del proyecto,
/// como cuando el usuario lo abre en su terminal; DevAgents le pasa la
/// conversación y anuncia lo que cambió en disco.
const EXTERNAL_PROMPT =
    "Trabajas dentro de DevAgents en modo Directo: el usuario te habla desde la cabina como lo haría en tu terminal.\n" ++
    "- Si conversa o pregunta, responde con normalidad, en su idioma.\n" ++
    "- Si pide trabajo sobre el proyecto, hazlo de verdad en la carpeta indicada y, al terminar, di en pocas líneas qué hiciste y qué falta, sin inventar resultados.\n" ++
    PROCESSES_NOTE;

/// Lo que Directo necesita para lanzar un agente externo; lo rellena el motor.
pub const ExternalSetup = struct {
    /// Catálogo de agentes detectados (`external_registry`), con rutas y versiones.
    catalog_json: ?[]const u8 = null,
    /// catalog.db, para resolver el pin (ruta del ejecutable verificada).
    catalog_conn: ?db.Connection = null,
    /// runtime.db, para los eventos de la orden.
    event_conn: ?db.Connection = null,
    /// Seam de prueba; producción = `external_agents.defaultRun`.
    run_fn: ?external_agents.RunFn = null,
    run_ctx: ?*anyopaque = null,
    timeout_ms: u64 = 30 * 60 * 1000,
    max_turns: u32 = 200,
    /// Carga perezosa del catálogo para Automático: solo se detectan los
    /// agentes si no hay ningún modelo por API ni local. Devuelve memoria de
    /// `allocator` que libera el planificador.
    load_fn: ?*const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator) ?[]u8 = null,
    load_ctx: ?*anyopaque = null,
};

/// Sesión del modelo: producción = `LiveLlm.directoFn`; los tests inyectan una.
pub const RunFn = *const fn (ctx: ?*anyopaque, llm: *live_worker.LiveLlm, system_prompt: []const u8, user_prompt: []const u8) []const u8;

fn defaultRun(_: ?*anyopaque, llm: *live_worker.LiveLlm, system_prompt: []const u8, user_prompt: []const u8) []const u8 {
    return live_worker.LiveLlm.directoFn(llm, system_prompt, user_prompt);
}

pub const DirectPlanner = struct {
    allocator: std.mem.Allocator,
    catalog_path: []const u8,
    rules_catalog: ?db.Connection = null,
    rules_context: ?project_rules.Context = null,
    history: []const planner.ConversationTurn = &.{},
    /// Modelo elegido en «Modelo». Con los dos fijados se usa SOLO ese modelo
    /// (`initExact`, sin respaldos): es la promesa de Directo.
    forced_provider: ?[]const u8 = null,
    forced_model: ?[]const u8 = null,
    /// Fila de la orden para atribuir eventos (0 = sin telemetría).
    event_order_id: i64 = 0,
    permission_config: executor.PermissionConfig = .{},
    origin: executor.Origin = .local,
    spawn_fn: ?executor.SpawnFn = null,
    /// Cancelación de la cabina («Detener» durante la planificación).
    cancel_slot: ?llm_planner.PlanCancelSlot = null,
    /// Raíz de trabajo; null = `workspace.effectiveRoot` (la carpeta abierta).
    workspace_root: ?[]const u8 = null,
    /// Seams de prueba: sesión y LiveLlm inyectados (sin red ni claves).
    run_fn: ?RunFn = null,
    run_ctx: ?*anyopaque = null,
    test_live: ?*live_worker.LiveLlm = null,
    /// Resultado de la última vuelta (para eventos y pruebas).
    last_used_tools: bool = false,
    /// 10-nov (propietario): el navegador integrado también en Directo. Con el
    /// registro del motor la vuelta pide su servicio de navegador por orden
    /// (como el orquestado) y el modelo recibe las herramientas browser_*.
    browser_registry: ?*browser_service.Registry = null,
    /// Agente externo como modelo de Directo (ver `ExternalSetup`).
    external: ExternalSetup = .{},
    /// Catálogo cargado por `load_fn` (propiedad del planificador).
    loaded_catalog: ?[]u8 = null,
    /// USUARIO-NUEVO B: modo «DevAgents» (c_api fija la delegación).
    delegate_fn: ?@import("governed_tool_executor.zig").DelegateFn = null,
    delegate_ctx: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, catalog_path: []const u8) DirectPlanner {
        return .{ .allocator = allocator, .catalog_path = catalog_path };
    }

    pub fn deinit(self: *DirectPlanner) void {
        if (self.loaded_catalog) |cat| self.allocator.free(cat);
        self.loaded_catalog = null;
    }

    pub fn backend(self: *DirectPlanner) planner.PlannerBackend {
        return .{ .ptr = self, .planFn = planImpl, .deinitFn = deinitImpl };
    }

    fn deinitImpl(_: *anyopaque) void {}

    fn planImpl(ctx: *anyopaque, allocator: std.mem.Allocator, order_text: []const u8, answers: []const planner.ClarificationAnswer, memory_context: ?[]const u8) planner.PlannerError!planner.Plan {
        _ = answers; // Directo no hace preguntas estructuradas: el modelo pregunta en el chat.
        const self: *DirectPlanner = @ptrCast(@alignCast(ctx));
        const trimmed = std.mem.trim(u8, order_text, " \t\r\n");
        if (trimmed.len == 0) return error.EmptyOrder;

        const user_prompt = try buildUserPrompt(allocator, self.history, memory_context, trimmed);
        defer allocator.free(user_prompt);

        const is_agent = if (self.forced_provider) |p| external_agents.isAgentProvider(p) else false;
        var outcome = (if (is_agent)
            self.runExternal(allocator, user_prompt, self.forced_provider.?, self.forced_model orelse "default")
        else
            self.runSession(allocator, user_prompt)) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        // QA primerizo (10-nov): Automático sin ningún modelo por API ni local
        // recurre a un agente externo detectado, como promete el tutorial.
        if (outcome.no_candidates and self.forced_provider == null) {
            if (self.automaticAgent(allocator)) |pick| {
                defer pick.deinit(allocator);
                const via = self.runExternal(allocator, user_prompt, pick.provider, pick.model) catch |e| switch (e) {
                    error.OutOfMemory => {
                        allocator.free(outcome.text);
                        return error.OutOfMemory;
                    },
                };
                allocator.free(outcome.text);
                const display = if (external_agents.metaForProvider(pick.provider)) |m| m.display else pick.provider;
                const note = std.fmt.allocPrint(allocator, "_Automático: no hay claves API ni modelos locales, así que respondió **{s}** ({s}), detectado en este equipo._\n\n{s}", .{ display, pick.model, via.text }) catch {
                    allocator.free(via.text);
                    return error.OutOfMemory;
                };
                allocator.free(via.text);
                outcome = .{ .text = note, .failed = via.failed };
            }
        }
        return chatPlan(allocator, outcome.text, outcome.failed);
    }

    const Outcome = struct { text: []u8, failed: bool, no_candidates: bool = false };

    /// Agente externo para Automático (sin claves ni locales). Respeta «Solo
    /// local» (ninguno) y la casilla «Permitir al router» de cada modelo.
    fn automaticAgent(self: *DirectPlanner, allocator: std.mem.Allocator) ?AutoAgent {
        const conn = self.external.catalog_conn;
        if (conn) |c| if (governanceIsLocalOnly(c)) return null;
        if (self.external.catalog_json == null) {
            const load = self.external.load_fn orelse return null;
            self.loaded_catalog = load(self.external.load_ctx, self.allocator);
            self.external.catalog_json = self.loaded_catalog;
        }
        const catalog = self.external.catalog_json orelse return null;
        return pickAutomaticAgent(allocator, catalog, conn) catch null;
    }

    fn runSession(self: *DirectPlanner, allocator: std.mem.Allocator, user_prompt: []const u8) error{OutOfMemory}!Outcome {
        const call_alloc = std.heap.c_allocator;
        var owned_live: ?*live_worker.LiveLlm = null;
        defer if (owned_live) |l| {
            l.deinit();
            call_alloc.destroy(l);
        };
        const llm: *live_worker.LiveLlm = if (self.test_live) |borrowed| borrowed else blk: {
            const l = try call_alloc.create(live_worker.LiveLlm);
            const built = if (self.forced_provider != null and self.forced_model != null)
                live_worker.LiveLlm.initExact(call_alloc, self.catalog_path, self.forced_provider.?, self.forced_model.?)
            else
                live_worker.LiveLlm.init(call_alloc, self.catalog_path);
            l.* = built orelse {
                call_alloc.destroy(l);
                const why = if (self.forced_provider != null)
                    "Directo: el modelo elegido no tiene una clave activa. Revísala en Configuración › Proveedores o elige otro modelo."
                else
                    "Directo: no hay ningún modelo disponible. Añade una clave en Configuración › Proveedores, abre Ollama y pulsa «Descubrir modelos», o instala e inicia sesión en un agente (Claude Code, Codex, Gemini CLI u OpenCode) y pulsa «Volver a detectar».";
                return .{ .text = try allocator.dupe(u8, why), .failed = true, .no_candidates = self.forced_provider == null };
            };
            owned_live = l;
            l.setOwnedHealthConnFromCatalogPath();
            if (self.event_order_id > 0) _ = l.setOwnedTraceConn(self.event_order_id);
            break :blk l;
        };

        // «Detener» de la cabina: el token vive lo que dure esta sesión.
        const token = live_worker.CancellationToken.create(call_alloc) catch null;
        defer if (token) |t| t.release();
        if (token) |t| {
            llm.setCancelToken(t);
            if (self.cancel_slot) |cs| {
                cs.mutex.lock();
                cs.slot.* = t;
                cs.mutex.unlock();
            }
        }
        defer if (token != null) if (self.cancel_slot) |cs| {
            cs.mutex.lock();
            cs.slot.* = null;
            cs.mutex.unlock();
        };

        // Herramientas solo si algún candidato las admite (medición viva).
        // El primero apto es el que responde: con herramientas la sesión no
        // pasa a otro modelo (live_worker corta tras el primer intento).
        var any_tools = false;
        var who_provider: []const u8 = self.forced_provider orelse "";
        var who_model: []const u8 = self.forced_model orelse "";
        for (llm.lives) |live| {
            if (llm.candidateAdmitsTools(live)) {
                any_tools = true;
                who_provider = live.cfg.name;
                who_model = live.model;
                break;
            }
        }
        if (!any_tools and llm.lives.len > 0 and self.forced_model == null) {
            who_provider = llm.lives[0].cfg.name;
            who_model = llm.lives[0].model;
        }
        if (self.test_live != null and llm.lives.len == 0) any_tools = llm.governed_tools_source != null;
        self.last_used_tools = any_tools;

        var root_buf: [4096]u8 = undefined;
        // Como cualquier IDE: la carpeta del proyecto elegida, no el
        // segmento `devagents-workspace` de las órdenes orquestadas.
        const root = self.workspace_root orelse (workspace.selectedProjectRoot(&root_buf) orelse workspace.effectiveRoot(&root_buf));
        var browser: ?*browser_service.Service = null;
        defer if (browser) |service| {
            service.cancelOrder();
            service.release();
        };
        if (any_tools and self.test_live == null and self.event_order_id > 0) {
            if (self.browser_registry) |registry| {
                if (registry.acquire(allocator, .{ .order_id = self.event_order_id, .space_id = 0, .workspace_root = root })) |service| {
                    if (service.beginDispatch()) |_| {
                        service.attach_grace_ms = 8000;
                        browser = service;
                    } else |_| service.release();
                } else |_| {}
            }
        }
        if (any_tools and self.test_live == null) {
            llm.setUseConnectorV2Dispatch(true);
            llm.max_tool_rounds = MAX_ROUNDS;
            llm.setGovernedTools(.{
                .policy = .{ .workspace_root = root, .origin = self.origin },
                .permission_config = self.permission_config,
                // El usuario dio la orden directamente: no hay plan que aprobar.
                // La denylist y el código inline siguen pidiendo aprobación.
                .plan_approved = true,
                .read_only = false,
                .agentic = true,
                .spawn_fn = self.spawn_fn,
                .is_cancelled_fn = if (token != null) tokenCancelled else null,
                .cancelled_ctx = if (token) |t| @ptrCast(t) else null,
                .browser = browser,
                .browser_identity = if (browser) |service| service.identity("directo", service.nextAttempt()) else null,
                .delegate_fn = self.delegate_fn,
                .delegate_ctx = self.delegate_ctx,
            });
            if (browser != null) {
                llm.order_id = self.event_order_id;
                llm.task_id = "directo";
            }
        }

        // propietario, 8-nov: «en Directo no es capaz de darse cuenta de cuál modelo
        // está usando». El modelo no lo sabe por sí mismo; se le dice.
        const identity = if (who_model.len > 0)
            try std.fmt.allocPrint(allocator, "\n[QUIÉN ERES]\nEres el modelo `{s}` del proveedor `{s}`, elegido {s}. Si te preguntan qué modelo eres o cuál estás usando, responde exactamente eso.\n", .{ who_model, who_provider, if (self.forced_model != null) "por el usuario en «Modelo»" else "automáticamente por DevAgents" })
        else
            try allocator.dupe(u8, "");
        defer allocator.free(identity);
        // QA primerizo (10-nov): qwen2.5:7b escribió «mi-proyecto2/saludo.py»
        // y el archivo acabó en una subcarpeta con el nombre del proyecto.
        // Se dice con el nombre real que las rutas NO lo repiten.
        const folder = std.fs.path.basename(root);
        const delegating = any_tools and self.delegate_fn != null;
        // T7 (e): Directo, el modo por defecto, también lleva las
        // reglas del proyecto (y las reglas del repositorio / las reglas del repositorio, que mandan sobre ellas).
        const ctx = self.rules_context orelse (project_rules.loadContext(allocator, self.rules_catalog orelse self.external.catalog_conn, root) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            return .{ .text = try std.fmt.allocPrint(allocator, "Reglas del proyecto ilegibles ({s}); la orden no se ejecutó.", .{@errorName(e)}), .failed = true };
        });
        defer if (self.rules_context == null) ctx.deinit(allocator);
        const rules = try ctx.blockForApi(allocator, root);
        defer allocator.free(rules);
        const system = try std.fmt.allocPrint(allocator, "{s}{s}{s}{s}\n[CARPETA DEL PROYECTO]\n{s}\nTus rutas ya parten de esta carpeta: para un archivo en la raíz usa `saludo.py`, nunca `{s}/saludo.py`.\n{s}", .{ SYSTEM_PROMPT, identity, if (any_tools) TOOLS_PROMPT else NO_TOOLS_PROMPT, if (delegating) DELEGATE_PROMPT else "", root, folder, rules });
        defer allocator.free(system);

        // El primer candidato es el que responde (ver arriba): se anuncia el
        // modelo real también en Automático, no «auto».
        recordDirectEvent(llm, allocator, "directo_started_v1", .{ .provider = if (who_provider.len > 0) who_provider else "auto", .model = if (who_model.len > 0) who_model else "auto", .automatic = self.forced_provider == null, .tools = any_tools, .root = root, .delegate = delegating });

        const run = self.run_fn orelse defaultRun;
        const reply = run(self.run_ctx, llm, system, user_prompt);
        const cancelled = llm.wasCancelled();
        const trimmed = std.mem.trim(u8, reply, " \t\r\n");

        var text: []u8 = undefined;
        var failed = false;
        if (trimmed.len > 0) {
            text = try allocator.dupe(u8, trimmed);
        } else if (llm.last_agentic_finished and llm.last_agentic_summary != null) {
            text = try allocator.dupe(u8, llm.last_agentic_summary.?);
        } else if (cancelled) {
            text = try allocator.dupe(u8, "Directo: detenido a petición tuya.");
            failed = true;
        } else {
            text = try failureText(allocator, llm.last_error_name, llm.last_http_failure, who_provider, who_model);
            failed = true;
        }
        // Qué modelo respondió de verdad (en Automático no se sabe de antemano).
        var used_provider: []const u8 = "";
        var used_model: []const u8 = "";
        for (llm.takeAttempts()) |attempt| {
            if (std.mem.eql(u8, attempt.status, "ok")) {
                used_provider = attempt.provider;
                used_model = attempt.model;
            }
        }
        // (9-nov): «Resultados» y la tarjeta de cambios del chat
        // leen `file_written`; sin él, lo que Directo escribía no aparecía.
        // Se anuncia lo que pasó en disco, no lo que el modelo declara.
        for (llm.last_agentic_written.items) |rel| {
            const abs = if (std.fs.path.isAbsolute(rel)) try allocator.dupe(u8, rel) else try std.fs.path.join(allocator, &.{ root, rel });
            defer allocator.free(abs);
            recordDirectEvent(llm, allocator, "file_written", .{ .file_path = abs, .task_id = "directo", .artifact_name = std.fs.path.basename(abs) });
        }
        // USUARIO-NUEVO R3 (10-nov): hechos del motor, no el texto del modelo.
        // Si `finish` declaró archivos que no existen en la carpeta, se dice
        // en la respuesta (el modelo afirmó algo que no pasó en disco).
        const missing = try missingDeclaredFiles(allocator, root, llm.last_agentic_files);
        defer allocator.free(missing);
        if (missing.len > 0 and !failed) {
            const noted = try std.fmt.allocPrint(allocator, "{s}\n\n_DevAgents comprobó la carpeta: el modelo dijo haber escrito {s}, pero no existe. No se escribió._", .{ text, missing });
            allocator.free(text);
            text = noted;
        }
        // B1 (10-nov): bajo la respuesta, lo que la vuelta escribió de verdad;
        // y si el texto afirma archivos que nadie escribió, se dice.
        const facts = try fileFacts(allocator, text, .{ .tools = llm.last_tools_run, .commands = llm.last_commands_run, .delegations = llm.last_delegations_run, .written = llm.last_agentic_written.items, .outcomes = llm.last_command_facts });
        if (facts) |f| {
            defer allocator.free(f.line);
            const noted = try std.mem.concat(allocator, u8, &.{ text, FACTS_MARK, f.line });
            allocator.free(text);
            text = noted;
        }
        const rate = llm.last_http_failure.rate;
        recordDirectEvent(llm, allocator, "directo_finished_v1", .{ .ok = !failed, .cancelled = cancelled, .error_name = if (failed and !cancelled) llm.last_error_name else "", .finished = llm.last_agentic_finished, .files = llm.last_agentic_written.items.len, .tools_run = llm.last_tools_run, .commands_run = llm.last_commands_run, .claims_unwritten = if (facts) |f| f.claims_unwritten else false, .missing_declared = missing, .provider = used_provider, .model = used_model, .failed_provider = if (failed) who_provider else "", .failed_model = if (failed) who_model else "", .http_status = if (failed) llm.last_http_failure.http_status else null, .rate_daily = failed and rate.daily, .rate_remaining = if (failed) rate.remaining else null });
        return .{ .text = text, .failed = failed };
    }

    const TurnFacts = struct {
        tools: u32 = 0,
        commands: u32 = 0,
        delegations: u32 = 0,
        written: []const []const u8 = &.{},
        outcomes: @import("governed_tool_executor.zig").CommandFacts = .{},
    };
    const FactsLine = struct { line: []u8, claims_unwritten: bool };

    /// B1 (tarea 4, amplía R3): la línea de sistema que va bajo la respuesta.
    /// Son hechos del motor, nunca el texto del modelo:
    /// - escribió archivos: «Archivos cambiados: …» (los de write_file/edit_file);
    /// - no escribió pero ejecutó comandos o delegó: se dice eso, porque un
    ///   comando o una subtarea sí pueden haber cambiado archivos;
    /// - no escribió nada y el texto afirma haber creado/editado/guardado
    ///   archivos: «Esta vuelta no escribió ningún archivo.»;
    /// - usó herramientas y no escribió: «Sin cambios en archivos.»;
    /// - conversación sin herramientas ni afirmaciones: nada (null).
    fn fileFacts(allocator: std.mem.Allocator, text: []const u8, facts: TurnFacts) error{OutOfMemory}!?FactsLine {
        var out = std.ArrayList(u8).empty;
        errdefer out.deinit(allocator);
        var claims_unwritten = false;
        if (facts.written.len > 0) {
            try out.appendSlice(allocator, "Archivos cambiados: ");
            const shown = @min(facts.written.len, MAX_FACT_FILES);
            for (facts.written[0..shown], 0..) |rel, i| {
                if (i > 0) try out.appendSlice(allocator, ", ");
                try out.appendSlice(allocator, rel);
            }
            if (facts.written.len > shown) {
                const more = try std.fmt.allocPrint(allocator, " y {d} más", .{facts.written.len - shown});
                defer allocator.free(more);
                try out.appendSlice(allocator, more);
            }
            try out.append(allocator, '.');
            if (facts.delegations > 0) try out.appendSlice(allocator, " Lo que integraron las subtareas figura en su resultado.");
        } else if (facts.delegations > 0) {
            try out.appendSlice(allocator, "Sin escrituras directas en esta vuelta: lo que integraron las subtareas figura en su resultado.");
        } else if (facts.commands > 0) {
            const line = if (facts.commands == 1)
                try allocator.dupe(u8, "Sin escrituras directas en esta vuelta: se ejecutó 1 comando, que puede haber cambiado archivos.")
            else
                try std.fmt.allocPrint(allocator, "Sin escrituras directas en esta vuelta: se ejecutaron {d} comandos, que pueden haber cambiado archivos.", .{facts.commands});
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
        } else if (claimsFileWrite(text) or claimsIntendedWrite(text)) {
            claims_unwritten = true;
            try out.appendSlice(allocator, UNWRITTEN_NOTE);
        } else if (facts.tools > 0) {
            try out.appendSlice(allocator, "Sin cambios en archivos.");
        }
        const outcomes = facts.outcomes;
        if (outcomes.succeeded > 0 or outcomes.failed > 0 or outcomes.timed_out > 0 or outcomes.background > 0) {
            if (out.items.len > 0) try out.append(allocator, ' ');
            const counts = try std.fmt.allocPrint(allocator, "Comandos: {d} correctos, {d} con error, {d} detenidos por tiempo límite y {d} iniciados en segundo plano.", .{ outcomes.succeeded, outcomes.failed, outcomes.timed_out, outcomes.background });
            defer allocator.free(counts);
            try out.appendSlice(allocator, counts);
            if (outcomes.timed_out > 0) try out.appendSlice(allocator, " Puedo relanzar en segundo plano el comando detenido.");
        }
        if (out.items.len == 0) return null;
        return .{ .line = try out.toOwnedSlice(allocator), .claims_unwritten = claims_unwritten };
    }

    /// R3: archivos que `finish` declaró y que no están en `root` (lista con
    /// comas, vacía si todos existen). Rutas absolutas, `..` o con separador
    /// final no se comprueban (no son del proyecto) y cuentan como ausentes.
    fn missingDeclaredFiles(allocator: std.mem.Allocator, root: []const u8, declared: []const []u8) error{OutOfMemory}![]u8 {
        var out = std.ArrayList(u8).empty;
        defer out.deinit(allocator);
        for (declared) |rel| {
            const clean = std.mem.trim(u8, rel, " \t\r\n");
            if (clean.len == 0) continue;
            const inside = !std.fs.path.isAbsolute(clean) and std.mem.indexOf(u8, clean, "..") == null;
            const exists = inside and blk: {
                const abs = try std.fs.path.join(allocator, &.{ root, clean });
                defer allocator.free(abs);
                const wide = std.unicode.utf8ToUtf16LeAllocZ(allocator, abs) catch |e| switch (e) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => break :blk false,
                };
                defer allocator.free(wide);
                break :blk GetFileAttributesW(wide) != 0xFFFFFFFF;
            };
            if (exists) continue;
            if (out.items.len > 0) try out.appendSlice(allocator, ", ");
            try out.appendSlice(allocator, clean);
        }
        return out.toOwnedSlice(allocator);
    }

    /// 10-nov (USUARIO-NUEVO A6): un fallo del modelo en lenguaje llano, con el
    /// motivo que dio el proveedor y qué hacer. Antes: «el modelo no respondió
    /// (RateLimited)», sin decir que la cuota gratuita del día se había agotado.
    fn failureText(allocator: std.mem.Allocator, error_name: []const u8, diag: providers.external_error.Diagnostic, provider: []const u8, model: []const u8) ![]u8 {
        const who = if (model.len > 0) model else "el modelo";
        const said_raw = diag.message();
        const prefix = "[texto externo] ";
        const said = if (std.mem.startsWith(u8, said_raw, prefix)) said_raw[prefix.len..] else said_raw;
        const quoted = if (said.len > 0 and !std.mem.eql(u8, said, "[REDACTADO]"))
            try std.fmt.allocPrint(allocator, " El proveedor dijo: «{s}».", .{said})
        else
            try allocator.dupe(u8, "");
        defer allocator.free(quoted);
        if (std.mem.eql(u8, error_name, "RateLimited")) {
            if (diag.rate.daily)
                return std.fmt.allocPrint(allocator, "Directo: {s}{s}{s} rechazó la petición: se agotó la cuota gratuita de hoy para ese modelo.{s} No se reintentó para no gastar más llamadas. Prueba con otro modelo gratuito o vuelve mañana.", .{ who, if (provider.len > 0) " de " else "", provider, quoted });
            return std.fmt.allocPrint(allocator, "Directo: {s}{s}{s} limitó las peticiones (demasiadas en poco tiempo).{s} Espera un momento y reintenta, o prueba con otro modelo gratuito.", .{ who, if (provider.len > 0) " de " else "", provider, quoted });
        }
        if (std.mem.eql(u8, error_name, "QuotaExceeded"))
            return std.fmt.allocPrint(allocator, "Directo: {s} rechazó la petición por falta de saldo o cuota en tu cuenta del proveedor.{s} Revisa tu plan o elige otro modelo.", .{ who, quoted });
        if (std.mem.eql(u8, error_name, "AuthFailed"))
            return std.fmt.allocPrint(allocator, "Directo: el proveedor rechazó la clave para {s}.{s} Revísala en Configuración › Proveedores o elige otro modelo.", .{ who, quoted });
        if (std.mem.eql(u8, error_name, "ModelNotFound"))
            return std.fmt.allocPrint(allocator, "Directo: el proveedor ya no ofrece {s}.{s} Elige otro modelo en «Modelo».", .{ who, quoted });
        if (std.mem.eql(u8, error_name, "Timeout"))
            return std.fmt.allocPrint(allocator, "Directo: {s} no respondió a tiempo. Reintenta o elige otro modelo en «Modelo».", .{who});
        if (error_name.len == 0)
            return std.fmt.allocPrint(allocator, "Directo: {s} no devolvió ninguna respuesta.{s} Reintenta o elige otro modelo en «Modelo».", .{ who, quoted });
        return std.fmt.allocPrint(allocator, "Directo: {s} falló.{s} Reintenta o elige otro modelo en «Modelo». (Detalle técnico: {s})", .{ who, quoted, error_name });
    }

    /// (9-nov): una vuelta de Directo con un agente externo.
    fn runExternal(self: *DirectPlanner, allocator: std.mem.Allocator, user_prompt: []const u8, provider: []const u8, model: []const u8) error{OutOfMemory}!Outcome {
        // T7: los avisos de rotación de cuenta encabezan la respuesta del hilo.
        var rotation = AccountRotation{ .conn = self.external.event_conn, .order_id = self.event_order_id, .allocator = allocator };
        defer rotation.deinit();
        const out = try self.runExternalWith(allocator, user_prompt, provider, model, &rotation);
        if (rotation.notes.items.len == 0) return out;
        const text = std.mem.concat(allocator, u8, &.{ rotation.notes.items, out.text }) catch {
            allocator.free(out.text);
            return error.OutOfMemory;
        };
        allocator.free(out.text);
        return .{ .text = text, .failed = out.failed, .no_candidates = out.no_candidates };
    }

    fn runExternalWith(self: *DirectPlanner, allocator: std.mem.Allocator, user_prompt: []const u8, provider: []const u8, model: []const u8, rotation: *AccountRotation) error{OutOfMemory}!Outcome {
        const call_alloc = std.heap.c_allocator;
        const meta = external_agents.metaForProvider(provider) orelse
            return failText(allocator, "Directo: no reconozco el agente «{s}». Elige otro en «Modelo».", .{provider});
        // Un CLI ejecuta y escribe con sus propios permisos: como en el
        // despacho orquestado, una orden que llega por MCP no lo lanza.
        if (self.origin == .mcp)
            return failText(allocator, "Directo: {s} solo se lanza desde la cabina; las órdenes que llegan por MCP no ejecutan agentes externos.", .{meta.display});

        var root_buf: [4096]u8 = undefined;
        const root = self.workspace_root orelse (workspace.selectedProjectRoot(&root_buf) orelse workspace.effectiveRoot(&root_buf));
        const ev = self.external.event_conn;
        const order_id = self.event_order_id;

        const token = live_worker.CancellationToken.create(call_alloc) catch null;
        defer if (token) |t| t.release();
        if (token) |t| if (self.cancel_slot) |cs| {
            cs.mutex.lock();
            cs.slot.* = t;
            cs.mutex.unlock();
        };
        defer if (token != null) if (self.cancel_slot) |cs| {
            cs.mutex.lock();
            cs.slot.* = null;
            cs.mutex.unlock();
        };

        var threaded = std.Io.Threaded.init(call_alloc, .{ .environ = @import("platform.zig").environ() });
        defer threaded.deinit();
        // Codex conserva PATH y perfil pero nunca recibe las claves API del
        // anfitrión (misma regla que el despacho orquestado).
        const cli_policy = @import("external_cli_policy.zig");
        var child_env: ?std.process.Environ.Map = null;
        defer if (child_env) |*env| env.deinit();
        const is_codex = std.mem.eql(u8, meta.cli_id, "codex");
        if (is_codex) {
            var parent_env = @import("platform.zig").environ().createMap(call_alloc) catch
                return failText(allocator, "Directo: no se pudo preparar el entorno de {s}.", .{meta.display});
            defer parent_env.deinit();
            child_env = cli_policy.codexEnvironment(call_alloc, &parent_env) catch
                return failText(allocator, "Directo: no se pudo preparar el entorno de {s}.", .{meta.display});
        }

        var pin: ?external_registry.Pin = null;
        defer if (pin) |pv| pv.deinit(call_alloc);
        var pin_error: ?anyerror = null;
        if (self.external.catalog_json) |cat| if (self.external.catalog_conn) |conn| {
            pin = (if (is_codex and self.external.run_fn == null)
                external_registry.revalidateCodexPin(call_alloc, conn, cat, model, threaded.io(), &child_env.?)
            else
                external_registry.resolvePin(call_alloc, conn, cat, provider, model)) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => blk: {
                    pin_error = e;
                    break :blk null;
                },
            };
        };
        // B1e (F0.6): el arranque guarda con qué permisos y con qué CLI se
        // lanzó, para poder demostrar la matriz de compatibilidad. Ruta y
        // versión son las de la detección (el pin), sin volver a ejecutar
        // `--version`; sin pin quedan null y la versión que midió el
        // adaptador va en `directo_finished_v1.cli_version`.
        recordConnEvent(ev, order_id, allocator, "directo_started_v1", .{
            .provider = provider,
            .model = model,
            .tools = true,
            .root = root,
            .agent = true,
            .permission_mode = @tagName(self.permission_config.mode),
            .cli_version = if (pin) |pv| @as(?[]const u8, pv.version) else null,
            .cli_path = if (pin) |pv| @as(?[]const u8, pv.exe) else null,
        });
        if (self.external.catalog_json != null and self.external.catalog_conn == null)
            return failText(allocator, "Directo: el catálogo de agentes externos no está disponible.", .{});
        if (pin_error) |e| {
            recordConnEvent(self.external.event_conn, self.event_order_id, allocator, "directo_finished_v1", .{ .ok = false, .provider = provider, .model = model, .agent = true, .@"error" = @errorName(e) });
            if (e == error.ApiBillingForbidden or e == error.NotLoggedIn) {
                const plain = @import("external_context.zig").plainStartFailure(allocator, meta.display, e) catch return error.OutOfMemory;
                defer allocator.free(plain);
                return failText(allocator, "Directo: {s}", .{plain});
            }
            const why: []const u8 = switch (e) {
                error.ModelUnavailable => "ese modelo ya no figura en su lista",
                error.AgentUnavailable => "no se encontró en la última detección",
                error.CodexHomeChanged => "su carpeta de perfil (CODEX_HOME) cambió desde la última detección",
                else => "no se pudo comprobar su instalación",
            };
            return failText(allocator, "Directo: {s} no está disponible: {s}. Pulsa «Volver a detectar» en Configuración › Agentes externos y elige el modelo otra vez.", .{ meta.display, why });
        }
        if (self.external.catalog_json == null and self.external.run_fn == null)
            return failText(allocator, "Directo: todavía no se han detectado los agentes externos. Pulsa «Actualizar» en Modelo › Agentes externos.", .{});

        var sb = sandbox.Sandbox.init(call_alloc, root) catch
            return failText(allocator, "Directo: la carpeta del proyecto no es válida ({s}).", .{root});
        defer sb.deinit();
        const prompt = try std.fmt.allocPrint(allocator, "{s}\n[CARPETA DEL PROYECTO]\n{s}\n\n{s}", .{ EXTERNAL_PROMPT, root, user_prompt });
        defer allocator.free(prompt);
        const task = planner.PlannedTask{
            .id = "directo",
            .task_type = .programar,
            .department = "programacion",
            .description = prompt,
            .contract_fields = &.{},
            .depends_on = &.{},
        };
        const run = self.external.run_fn orelse external_agents.defaultRun;
        var stream = ExternalStream{ .conn = ev, .order_id = order_id };
        // T7 (f): cuenta elegida para esta CLI (carpeta propia con
        // CODEX_HOME / CLAUDE_CONFIG_DIR) y rotación ante cuota agotada. Sin
        // cuenta elegida corre con el login del sistema, como siempre.
        var outcome = cli_accounts.runWithSelected(run, self.external.run_ctx, call_alloc, threaded.io(), task, .{
            .meta = meta,
            .model = model,
            .exe_path = if (pin) |pv| pv.exe else null,
            .zero_cost = if (pin) |pv| pv.zero_cost else false,
            .detected_version = if (pin) |pv| pv.version else null,
            .reasoning_effort = if (pin) |pv| pv.effort else null,
            .worktree = root,
            .prompt = prompt,
            .timeout_ms = self.external.timeout_ms,
            .max_turns = self.external.max_turns,
            .event_sink = .{ .ctx = &stream, .callFn = ExternalStream.call },
            // Misma política de contexto que el modo orquestado:
            // lo personal solo si el usuario lo activó en el ajuste.
            .inherit_personal_context = if (self.external.catalog_conn) |c| (@import("external_context.zig").load(c) catch false) else false,
            .deny_shell = external_agents.denyShellFor(self.permission_config.mode),
            .is_cancelled_fn = if (token != null) externalCancelled else null,
            .cancelled_ctx = if (token) |t| @ptrCast(t) else null,
            .environ_map = if (child_env) |*env| env else null,
        }, sb, self.external.catalog_conn, if (child_env) |*env| env else null, AccountRotation.notify, rotation) catch |e| {
            recordConnEvent(ev, order_id, allocator, "directo_finished_v1", .{ .ok = false, .provider = provider, .model = model, .agent = true, .@"error" = @errorName(e) });
            if (e == error.OutOfMemory) return error.OutOfMemory;
            // 10-nov (USUARIO-NUEVO A3): frase llana con su salida; la
            // cabina añade los botones según `directo_finished_v1.error`.
            const plain = @import("external_context.zig").plainStartFailure(allocator, meta.display, e) catch return error.OutOfMemory;
            defer allocator.free(plain);
            return failText(allocator, "Directo: {s}", .{plain});
        };
        defer outcome.deinit(call_alloc);

        // Lo que cambió en disco, medido por el adaptador (no lo que el agente dice).
        for (outcome.artifacts) |art| {
            const abs = if (std.fs.path.isAbsolute(art.path)) try allocator.dupe(u8, art.path) else try std.fs.path.join(allocator, &.{ root, art.path });
            defer allocator.free(abs);
            recordConnEvent(ev, order_id, allocator, "file_written", .{ .file_path = abs, .task_id = "directo", .artifact_name = std.fs.path.basename(abs) });
        }
        recordConnEvent(ev, order_id, allocator, "directo_finished_v1", .{ .ok = outcome.success, .provider = provider, .model = model, .agent = true, .files = outcome.artifacts.len, .turns = outcome.turns, .duration_ms = outcome.duration_ms, .cli_version = outcome.agent_version });

        const said = std.mem.trim(u8, outcome.declaration, " \t\r\n");
        if (outcome.success and said.len > 0) {
            // B1: con un agente externo las escrituras las mide el adaptador
            // (diferencia en disco). Se dicen si las hubo, o si el texto afirma
            // archivos y el disco no cambió.
            var written = std.ArrayList([]const u8).empty;
            defer written.deinit(allocator);
            for (outcome.artifacts) |art| try written.append(allocator, art.path);
            const facts = try fileFacts(allocator, said, .{ .written = written.items });
            if (facts) |f| {
                defer allocator.free(f.line);
                return .{ .text = try std.mem.concat(allocator, u8, &.{ said, FACTS_MARK, f.line }), .failed = false };
            }
            return .{ .text = try allocator.dupe(u8, said), .failed = false };
        }
        if (outcome.success)
            return .{ .text = try std.fmt.allocPrint(allocator, "{s} terminó sin dejar mensaje ({d} archivo(s) cambiados).", .{ meta.display, outcome.artifacts.len }), .failed = false };
        if (outcome.cancelled) return failText(allocator, "Directo: detenido a petición tuya.", .{});
        if (outcome.timed_out) return failText(allocator, "Directo: {s} superó el tiempo máximo ({d} min).", .{ meta.display, self.external.timeout_ms / 60000 });
        const tail = std.mem.trim(u8, outcome.detail, " \t\r\n");
        if (said.len > 0) return failText(allocator, "Directo: {s} terminó con error. Lo último que dijo:\n\n{s}", .{ meta.display, said });
        return failText(allocator, "Directo: {s} terminó con error.{s}{s}", .{ meta.display, if (tail.len > 0) "\n\n" else "", tail[tail.len -| 1500..] });
    }
};

/// T12 A2: huella del árbol de una carpeta (ruta, tipo, tamaño y fecha de
/// modificación) para comprobar desde fuera de la CLI que planificar no
/// cambió nada. No sigue enlaces ni uniones y omite `.git` salvo config,
/// hooks e info (consultas de
/// solo lectura como `git status` pueden refrescar su índice). Una
/// subcarpeta ilegible cuenta como entrada propia; más de `CAP` entradas
/// deja la huella incompleta (no comprobada), nunca «sin cambios».
pub const ProjectTreePrint = struct {
    pub const CAP: usize = 200_000;
    const Meta = struct { kind: u8, size: u64, mtime: i128 };

    a: std.mem.Allocator,
    entries: std.StringHashMapUnmanaged(Meta) = .empty,
    complete: bool = true,
    /// T12B M-3: tope configurable (las pruebas lo bajan para provocar el
    /// descarte sin crear cientos de miles de archivos).
    cap: usize = CAP,

    pub fn take(a: std.mem.Allocator, root: []const u8) !ProjectTreePrint {
        return takeWithCap(a, root, CAP);
    }

    pub fn takeWithCap(a: std.mem.Allocator, root: []const u8, cap: usize) !ProjectTreePrint {
        var threaded = std.Io.Threaded.init(a, .{});
        defer threaded.deinit();
        const io = threaded.io();
        var self: ProjectTreePrint = .{ .a = a, .cap = cap };
        errdefer self.deinit();
        var dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
        defer dir.close(io);
        var walker = try dir.walkSelectively(a);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (self.entries.count() >= self.cap) {
                self.complete = false;
                break;
            }
            var meta: Meta = .{ .kind = @intFromEnum(entry.kind), .size = 0, .mtime = 0 };
            if (entry.kind == .directory) {
                if (std.ascii.eqlIgnoreCase(entry.basename, ".git")) continue;
                walker.enter(io, entry) catch |e| switch (e) {
                    // Ilegible: no se puede comprobar que quedó intacta.
                    error.AccessDenied, error.PermissionDenied => {
                        meta.size = std.math.maxInt(u64);
                        self.complete = false;
                    },
                    else => return e,
                };
            } else if (entry.kind == .file) {
                const stat = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch |e| switch (e) {
                    error.FileNotFound => continue,
                    else => return e,
                };
                meta.size = stat.size;
                meta.mtime = stat.mtime.nanoseconds;
            }
            const key = try a.dupe(u8, entry.path);
            errdefer a.free(key);
            try self.entries.put(a, key, meta);
        }
        // T12B M-3: el resto de `.git` se omite (su índice lo refresca
        // `git status`), pero lo que gobierna la ejecución de git —config,
        // hooks e info— sí entra en la huella.
        try self.addGitControl(io, root);
        return self;
    }

    fn addGitControl(self: *ProjectTreePrint, io: std.Io, root: []const u8) !void {
        const git_path = try std.fs.path.join(self.a, &.{ root, ".git" });
        defer self.a.free(git_path);
        var git = std.Io.Dir.cwd().openDir(io, git_path, .{ .iterate = true }) catch |e| switch (e) {
            // No hay .git o es un fichero (worktree/submódulo): la entrada ya
            // quedó en la huella principal.
            error.FileNotFound, error.NotDir => return,
            // Ilegible: no se puede afirmar que no cambió.
            error.AccessDenied, error.PermissionDenied => {
                self.complete = false;
                return;
            },
            else => return e,
        };
        defer git.close(io);
        try self.addGitFile(io, git, "config", ".git" ++ std.fs.path.sep_str ++ "config");
        try self.addGitTree(io, git, "hooks", ".git" ++ std.fs.path.sep_str ++ "hooks");
        try self.addGitTree(io, git, "info", ".git" ++ std.fs.path.sep_str ++ "info");
    }

    fn addGitFile(self: *ProjectTreePrint, io: std.Io, dir: std.Io.Dir, name: []const u8, key: []const u8) !void {
        const stat = dir.statFile(io, name, .{ .follow_symlinks = false }) catch |e| switch (e) {
            error.FileNotFound => return,
            error.AccessDenied, error.PermissionDenied => {
                self.complete = false;
                return;
            },
            else => return e,
        };
        if (self.entries.count() >= self.cap) {
            self.complete = false;
            return;
        }
        const owned = try self.a.dupe(u8, key);
        errdefer self.a.free(owned);
        try self.entries.put(self.a, owned, .{ .kind = @intFromEnum(std.Io.File.Kind.file), .size = stat.size, .mtime = stat.mtime.nanoseconds });
    }

    fn addGitTree(self: *ProjectTreePrint, io: std.Io, git: std.Io.Dir, sub: []const u8, key_prefix: []const u8) !void {
        var dir = git.openDir(io, sub, .{ .iterate = true }) catch |e| switch (e) {
            error.FileNotFound, error.NotDir => return,
            error.AccessDenied, error.PermissionDenied => {
                self.complete = false;
                return;
            },
            else => return e,
        };
        defer dir.close(io);
        var walker = try dir.walkSelectively(self.a);
        defer walker.deinit();
        while (true) {
            const maybe_entry = walker.next(io) catch |e| switch (e) {
                error.OutOfMemory => return e,
                else => {
                    self.complete = false;
                    return;
                },
            };
            const entry = maybe_entry orelse break;
            if (self.entries.count() >= self.cap) {
                self.complete = false;
                return;
            }
            var meta: Meta = .{ .kind = @intFromEnum(entry.kind), .size = 0, .mtime = 0 };
            if (entry.kind == .directory) {
                walker.enter(io, entry) catch |e| switch (e) {
                    error.AccessDenied, error.PermissionDenied => {
                        meta.size = std.math.maxInt(u64);
                        self.complete = false;
                    },
                    else => return e,
                };
            } else if (entry.kind == .file) {
                const stat = entry.dir.statFile(io, entry.basename, .{ .follow_symlinks = false }) catch |e| switch (e) {
                    error.FileNotFound => continue,
                    else => return e,
                };
                meta.size = stat.size;
                meta.mtime = stat.mtime.nanoseconds;
            }
            const key = try std.fs.path.join(self.a, &.{ key_prefix, entry.path });
            errdefer self.a.free(key);
            try self.entries.put(self.a, key, meta);
        }
    }

    pub fn deinit(self: *ProjectTreePrint) void {
        var it = self.entries.keyIterator();
        while (it.next()) |key| self.a.free(key.*);
        self.entries.deinit(self.a);
    }

    /// Primera ruta nueva, cambiada o desaparecida (owned) o null si es igual.
    pub fn firstDifference(self: *const ProjectTreePrint, a: std.mem.Allocator, other: *const ProjectTreePrint) !?[]u8 {
        var it = other.entries.iterator();
        while (it.next()) |kv| {
            const old = self.entries.get(kv.key_ptr.*) orelse return try std.fmt.allocPrint(a, "nuevo: {s}", .{kv.key_ptr.*});
            if (old.kind != kv.value_ptr.kind or old.size != kv.value_ptr.size or old.mtime != kv.value_ptr.mtime)
                return try std.fmt.allocPrint(a, "modificado: {s}", .{kv.key_ptr.*});
        }
        var mine = self.entries.keyIterator();
        while (mine.next()) |key| {
            if (!other.entries.contains(key.*)) return try std.fmt.allocPrint(a, "borrado: {s}", .{key.*});
        }
        return null;
    }
};

/// QA-B H7 (decisión del propietario, 14-nov): planificar con la CLI con suscripción
/// cuando no hay clave de API ni modelo local. Elige la CLI como Automático
/// de Directo (`pickAutomaticAgent`), la lanza con la cuenta elegida y la
/// rotación por cuota (`cli_accounts.runWithSelected`) en modo de solo lectura
/// sobre la carpeta del proyecto, y devuelve su respuesta final para que
/// `llm_planner` la valide con el mismo parser que la vía por API.
/// Deja el evento `planner_cli_v1` (qué CLI, qué modelo, si valió) y, si rota,
/// `cli_account_rotated_v1`; `label()` lo dice en la consola de la CLI.
pub const SubscriptionPlanning = struct {
    allocator: std.mem.Allocator,
    external: ExternalSetup = .{},
    /// Fila de la orden (0 = la última insertada, como el resto del planificador).
    event_order_id: i64 = 0,
    origin: executor.Origin = .local,
    /// Raíz de lectura; null = la carpeta del proyecto elegida (como Directo).
    workspace_root: ?[]const u8 = null,
    /// T12B M-3: tope de entradas de la huella del árbol (las pruebas lo
    /// bajan para comprobar que, por encima del tope, el plan se descarta).
    tree_cap: usize = ProjectTreePrint.CAP,
    loaded_catalog: ?[]u8 = null,
    label_buf: [160]u8 = undefined,
    label_len: usize = 0,
    /// Avisos de rotación de la última planificación (texto para la consola).
    notes: std.ArrayList(u8) = .empty,

    /// Tope de reloj de una planificación por CLI.
    pub const TIMEOUT_MS: u64 = 10 * 60 * 1000;
    const PLAN_SUFFIX = "\n\nDevuelve solo el JSON solicitado en tu respuesta final, sin texto alrededor. No escribas archivos ni ejecutes comandos: solo puedes leer el proyecto.";

    pub fn init(allocator: std.mem.Allocator) SubscriptionPlanning {
        return .{ .allocator = allocator, .external = .{ .timeout_ms = TIMEOUT_MS, .max_turns = 40 } };
    }

    pub fn deinit(self: *SubscriptionPlanning) void {
        if (self.loaded_catalog) |cat| self.allocator.free(cat);
        self.loaded_catalog = null;
        self.notes.deinit(self.allocator);
    }

    pub fn subscriptionPlanner(self: *SubscriptionPlanning) llm_planner.SubscriptionPlanner {
        return .{ .ctx = self, .planFn = planFn };
    }

    /// «Claude Code (sonnet)» si la última planificación la hizo una CLI.
    pub fn label(self: *const SubscriptionPlanning) ?[]const u8 {
        return if (self.label_len == 0) null else self.label_buf[0..self.label_len];
    }

    pub fn rotationNotes(self: *const SubscriptionPlanning) []const u8 {
        return self.notes.items;
    }

    fn orderId(self: *const SubscriptionPlanning) i64 {
        if (self.event_order_id > 0) return self.event_order_id;
        const conn = self.external.event_conn orelse return 0;
        const q = conn.prepare("SELECT COALESCE(MAX(id),0) FROM orders") catch return 0;
        defer conn.finalize(q);
        if (db.c.sqlite3_step(q) != db.c.SQLITE_ROW) return 0;
        return db.c.sqlite3_column_int64(q, 0);
    }

    fn pick(self: *SubscriptionPlanning, a: std.mem.Allocator) ?AutoAgent {
        if (self.external.catalog_conn) |c| if (governanceIsLocalOnly(c)) return null;
        if (self.external.catalog_json == null) {
            const load = self.external.load_fn orelse return null;
            self.loaded_catalog = load(self.external.load_ctx, self.allocator);
            self.external.catalog_json = self.loaded_catalog;
        }
        const catalog = self.external.catalog_json orelse return null;
        return pickAutomaticAgent(a, catalog, self.external.catalog_conn) catch |e| {
            std.log.warn("planificación por suscripción: catálogo de agentes ilegible ({s})", .{@errorName(e)});
            return null;
        };
    }

    fn planFn(ctx: *anyopaque, a: std.mem.Allocator, system_prompt: []const u8, user_prompt: []const u8) error{OutOfMemory}!llm_planner.SubscriptionReply {
        const self: *SubscriptionPlanning = @ptrCast(@alignCast(ctx));
        self.label_len = 0;
        self.notes.clearRetainingCapacity();
        // Una orden por MCP no lanza agentes externos (como Directo y el
        // despacho orquestado); sin CLI detectada tampoco hay a quién pedir.
        // En los dos casos el planificador sigue su vía de siempre.
        if (self.origin == .mcp) return .{ .unavailable = true };
        // En las pruebas nunca se lanza una CLI real detectada en el equipo:
        // solo la simulada (run_fn), igual que directCatalogLoad en la C-ABI.
        if (@import("builtin").is_test and self.external.run_fn == null) return .{ .unavailable = true };
        const choice = self.pick(a) orelse return .{ .unavailable = true };
        defer choice.deinit(a);
        const meta = external_agents.metaForProvider(choice.provider) orelse
            return .{ .failure = try std.fmt.allocPrint(a, "agente externo desconocido: {s}", .{choice.provider}) };
        const shown = std.fmt.bufPrint(&self.label_buf, "{s} ({s})", .{ meta.display, choice.model }) catch self.label_buf[0..];
        self.label_len = shown.len;
        const who = self.label().?;
        const order_id = self.orderId();
        recordConnEvent(self.external.event_conn, order_id, a, "planner_cli_v1", .{ .status = "started", .provider = choice.provider, .model = choice.model, .display = meta.display });

        var root_buf: [4096]u8 = undefined;
        const root = self.workspace_root orelse (workspace.selectedProjectRoot(&root_buf) orelse workspace.effectiveRoot(&root_buf));
        // T12 A2: planificar es de solo lectura también comprobado por fuera
        // de la CLI: huella del árbol del proyecto antes y después.
        var before = ProjectTreePrint.takeWithCap(a, root, self.tree_cap) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            recordConnEvent(self.external.event_conn, order_id, a, "planner_cli_v1", .{ .status = "failed", .ok = false, .provider = choice.provider, .model = choice.model, .display = meta.display, .@"error" = @errorName(e) });
            return .{ .failure = try std.fmt.allocPrint(a, "{s} no se lanzó: no se pudo tomar la huella de la carpeta del proyecto ({s}) para comprobar que planificar no la cambia", .{ who, @errorName(e) }), .who = who };
        };
        defer before.deinit();

        var outcome = self.run(a, meta, choice.provider, choice.model, system_prompt, user_prompt, order_id, root) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            recordConnEvent(self.external.event_conn, order_id, a, "planner_cli_v1", .{ .status = "failed", .ok = false, .provider = choice.provider, .model = choice.model, .display = meta.display, .@"error" = @errorName(e) });
            const plain = try @import("external_context.zig").plainStartFailure(a, meta.display, e);
            defer a.free(plain);
            return .{ .failure = try std.fmt.allocPrint(a, "{s} no pudo planificar: {s}", .{ who, plain }), .who = who };
        };
        defer outcome.deinit(std.heap.c_allocator);
        var after = ProjectTreePrint.takeWithCap(a, root, self.tree_cap) catch |e| {
            if (e == error.OutOfMemory) return error.OutOfMemory;
            recordConnEvent(self.external.event_conn, order_id, a, "planner_cli_v1", .{ .status = "failed", .ok = false, .provider = choice.provider, .model = choice.model, .display = meta.display, .@"error" = @errorName(e) });
            return .{ .failure = try std.fmt.allocPrint(a, "{s}: no se pudo comprobar que la carpeta del proyecto no cambió al planificar ({s}); el plan se descarta", .{ who, @errorName(e) }), .who = who };
        };
        defer after.deinit();
        const tree_checked = before.complete and after.complete;
        if (tree_checked) {
            if (try before.firstDifference(a, &after)) |changed| {
                defer a.free(changed);
                recordConnEvent(self.external.event_conn, order_id, a, "planner_cli_v1", .{ .status = "failed", .ok = false, .provider = choice.provider, .model = choice.model, .display = meta.display, .@"error" = "project_modified", .path = changed });
                return .{ .failure = try std.fmt.allocPrint(a, "{s} cambió la carpeta del proyecto mientras planificaba ({s}); planificar debe ser de solo lectura, así que el plan se descarta. Revisa ese cambio antes de seguir.", .{ who, changed }), .who = who };
            }
        } else {
            // T12B M-3: una huella incompleta no permite afirmar que la carpeta
            // no cambió, así que el plan se descarta en vez de solo anotarlo.
            recordConnEvent(self.external.event_conn, order_id, a, "planner_cli_v1", .{ .status = "failed", .ok = false, .provider = choice.provider, .model = choice.model, .display = meta.display, .@"error" = "tree_unchecked" });
            return .{ .failure = try std.fmt.allocPrint(a, "{s}: no se pudo comprobar que planificar dejara intacta la carpeta del proyecto (huella incompleta: límite de {d} entradas o directorio ilegible); el plan se descarta.", .{ who, self.tree_cap }), .who = who };
        }
        const said = std.mem.trim(u8, outcome.declaration, " \t\r\n");
        recordConnEvent(self.external.event_conn, order_id, a, "planner_cli_v1", .{ .status = "finished", .tree_checked = tree_checked, .answered = outcome.success and said.len > 0, .provider = choice.provider, .model = choice.model, .display = meta.display, .duration_ms = outcome.duration_ms, .cli_version = outcome.agent_version, .rotations = self.notes.items });
        if (outcome.success and said.len > 0) return .{ .text = try a.dupe(u8, said), .who = who };
        if (outcome.cancelled) return .{ .failure = try std.fmt.allocPrint(a, "{s}: planificación detenida a petición tuya", .{who}), .who = who };
        if (outcome.timed_out) return .{ .failure = try std.fmt.allocPrint(a, "{s} no terminó de planificar en {d} min", .{ who, self.external.timeout_ms / 60000 }), .who = who };
        const tail = std.mem.trim(u8, outcome.detail, " \t\r\n");
        return .{ .failure = try std.fmt.allocPrint(a, "{s} terminó sin un plan{s}{s}", .{ who, if (tail.len > 0) ": " else "", tail[tail.len -| 600..] }), .who = who };
    }

    fn run(self: *SubscriptionPlanning, a: std.mem.Allocator, meta: external_agents.AgentMeta, provider: []const u8, model: []const u8, system_prompt: []const u8, user_prompt: []const u8, order_id: i64, root: []const u8) anyerror!external_agents.RunOutcome {
        const call_alloc = std.heap.c_allocator;
        var threaded = std.Io.Threaded.init(call_alloc, .{ .environ = @import("platform.zig").environ() });
        defer threaded.deinit();
        // Codex conserva PATH y perfil pero nunca recibe las claves API del
        // anfitrión (misma regla que Directo y el despacho orquestado).
        var child_env: ?std.process.Environ.Map = null;
        defer if (child_env) |*env| env.deinit();
        const is_codex = std.mem.eql(u8, meta.cli_id, "codex");
        if (is_codex) {
            var parent_env = try @import("platform.zig").environ().createMap(call_alloc);
            defer parent_env.deinit();
            child_env = try @import("external_cli_policy.zig").codexEnvironment(call_alloc, &parent_env);
        }
        if (self.external.catalog_json != null and self.external.catalog_conn == null) return error.ExternalCatalogUnavailable;
        var pin: ?external_registry.Pin = null;
        defer if (pin) |pv| pv.deinit(call_alloc);
        if (self.external.catalog_json) |cat| if (self.external.catalog_conn) |conn| {
            pin = try (if (is_codex and self.external.run_fn == null)
                external_registry.revalidateCodexPin(call_alloc, conn, cat, model, threaded.io(), &child_env.?)
            else
                external_registry.resolvePin(call_alloc, conn, cat, provider, model));
        };
        var sb = try sandbox.Sandbox.init(call_alloc, root);
        defer sb.deinit();
        const prompt = try std.mem.concat(a, u8, &.{ system_prompt, "\n\n", user_prompt, PLAN_SUFFIX });
        defer a.free(prompt);
        const task = planner.PlannedTask{
            .id = "planner",
            .task_type = .programar,
            .department = "programacion",
            .description = prompt,
            .contract_fields = &.{},
            .depends_on = &.{},
        };
        var stream = ExternalStream{ .conn = self.external.event_conn, .order_id = order_id, .task_id = "planner" };
        var rotation = PlanRotation{ .owner = self, .order_id = order_id };
        return cli_accounts.runWithSelected(self.external.run_fn orelse external_agents.defaultRun, self.external.run_ctx, call_alloc, threaded.io(), task, .{
            .meta = meta,
            .model = model,
            .exe_path = if (pin) |pv| pv.exe else null,
            .zero_cost = if (pin) |pv| pv.zero_cost else false,
            .detected_version = if (pin) |pv| pv.version else null,
            .reasoning_effort = if (pin) |pv| pv.effort else null,
            .worktree = root,
            .prompt = prompt,
            .timeout_ms = self.external.timeout_ms,
            .max_turns = self.external.max_turns,
            .event_sink = .{ .ctx = &stream, .callFn = ExternalStream.call },
            .inherit_personal_context = if (self.external.catalog_conn) |c| try @import("external_context.zig").load(c) else false,
            .deny_shell = true,
            .read_only = true,
            .environ_map = if (child_env) |*env| env else null,
        }, sb, self.external.catalog_conn, if (child_env) |*env| env else null, PlanRotation.notify, &rotation);
    }

    const PlanRotation = struct {
        owner: *SubscriptionPlanning,
        order_id: i64,

        fn notify(ctx: ?*anyopaque, notice: cli_accounts.RotationNotice) void {
            const self: *PlanRotation = @ptrCast(@alignCast(ctx.?));
            const a = self.owner.allocator;
            const text = cli_accounts.noticeText(a, notice) catch |e| {
                std.log.warn("aviso de rotación de cuenta no construido: {s}", .{@errorName(e)});
                return;
            };
            defer a.free(text);
            recordConnEvent(self.owner.external.event_conn, self.order_id, a, "cli_account_rotated_v1", .{ .task_id = "planner", .cli = notice.cli, .from = notice.from_id, .to = notice.to_id, .message = text });
            self.owner.notes.print(a, "{s}\n", .{text}) catch |e| std.log.warn("aviso de rotación de cuenta no anotado: {s}", .{@errorName(e)});
        }
    };
};

pub const AutoAgent = struct {
    provider: []u8,
    model: []u8,
    pub fn deinit(self: AutoAgent, a: std.mem.Allocator) void {
        a.free(self.provider);
        a.free(self.model);
    }
};

fn governanceIsLocalOnly(conn: db.Connection) bool {
    const q = conn.prepare("SELECT value FROM settings WHERE key='governance_mode'") catch return false;
    defer conn.finalize(q);
    if (db.c.sqlite3_step(q) != db.c.SQLITE_ROW) return false;
    const ptr = db.c.sqlite3_column_text(q, 0) orelse return false;
    return @import("model_router.zig").GovernanceMode.parse(std.mem.span(ptr)) == .local_only;
}

fn jsonStr(v: std.json.Value, key: []const u8) []const u8 {
    if (v != .object) return "";
    const f = v.object.get(key) orelse return "";
    return if (f == .string) f.string else "";
}

/// Elige el agente externo de Automático entre los detectados: primero los de
/// suscripción con sesión iniciada (Claude Code, Codex, Gemini CLI), luego un
/// modelo gratis de OpenCode. Nunca uno que cobraría por API (`api_key` fuera
/// de los gratis de OpenCode) ni un modelo que el usuario quitó del router.
pub fn pickAutomaticAgent(a: std.mem.Allocator, catalog_json: []const u8, conn: ?db.Connection) !?AutoAgent {
    var parsed = std.json.parseFromSlice(std.json.Value, a, catalog_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .array) return null;
    const order = [_][]const u8{ "agent:claude-code", "agent:codex", "agent:gemini-cli", "agent:opencode" };
    for (order) |wanted| {
        for (parsed.value.array.items) |agent| {
            if (!std.mem.eql(u8, jsonStr(agent, "provider"), wanted)) continue;
            if (jsonStr(agent, "exe").len == 0) continue;
            const is_opencode = std.mem.eql(u8, wanted, "agent:opencode");
            if (!is_opencode and !std.mem.eql(u8, jsonStr(agent, "session"), "suscripcion")) continue;
            const models = agent.object.get("models") orelse continue;
            if (models != .array) continue;
            for (models.array.items) |m| {
                const slug = jsonStr(m, "slug");
                if (slug.len == 0) continue;
                if (@import("model_capabilities.zig").nonChat(slug)) continue;
                if (is_opencode) {
                    const cost = if (m == .object) m.object.get("zero_cost") else null;
                    const zero = cost != null and cost.? == .bool and cost.?.bool;
                    if (!@import("external_agent_catalog.zig").isFreeModel(jsonStr(agent, "cli"), slug, zero)) continue;
                }
                if (conn) |c| {
                    const prefs = @import("model_selection.zig").get(c, wanted, slug) catch @import("model_selection.zig").Preferences{};
                    if (!prefs.allow_automatic) continue;
                }
                const provider = try a.dupe(u8, wanted);
                errdefer a.free(provider);
                return .{ .provider = provider, .model = try a.dupe(u8, slug) };
            }
        }
    }
    return null;
}

test "QA primerizo: Automático elige suscripción antes que OpenCode gratis y nunca pago por API" {
    const a = std.testing.allocator;
    const both = "[{\"provider\":\"agent:opencode\",\"cli\":\"opencode\",\"exe\":\"C:/o.exe\",\"session\":\"api_key\",\"models\":[{\"slug\":\"opencode/caro\",\"zero_cost\":false},{\"slug\":\"opencode/glm-free\",\"zero_cost\":true}]}," ++
        "{\"provider\":\"agent:codex\",\"cli\":\"codex\",\"exe\":\"C:/c.exe\",\"session\":\"suscripcion\",\"models\":[{\"slug\":\"gpt-6-sol\"}]}]";
    const p1 = (try pickAutomaticAgent(a, both, null)).?;
    defer p1.deinit(a);
    try std.testing.expectEqualStrings("agent:codex", p1.provider);
    try std.testing.expectEqualStrings("gpt-6-sol", p1.model);

    // Codex sin sesión: queda el gratis de OpenCode, nunca el de pago.
    const logged_out = "[{\"provider\":\"agent:codex\",\"cli\":\"codex\",\"exe\":\"C:/c.exe\",\"session\":\"none\",\"models\":[{\"slug\":\"gpt-6-sol\"}]}," ++
        "{\"provider\":\"agent:opencode\",\"cli\":\"opencode\",\"exe\":\"C:/o.exe\",\"session\":\"api_key\",\"models\":[{\"slug\":\"opencode/caro\",\"zero_cost\":false},{\"slug\":\"opencode/glm-free\",\"zero_cost\":true}]}]";
    const p2 = (try pickAutomaticAgent(a, logged_out, null)).?;
    defer p2.deinit(a);
    try std.testing.expectEqualStrings("agent:opencode", p2.provider);
    try std.testing.expectEqualStrings("opencode/glm-free", p2.model);

    // Nada usable: null (Directo explica cómo conseguir un modelo).
    try std.testing.expect((try pickAutomaticAgent(a, "[{\"provider\":\"agent:opencode\",\"cli\":\"opencode\",\"exe\":\"C:/o.exe\",\"models\":[{\"slug\":\"opencode/caro\",\"zero_cost\":false}]}]", null)) == null);
    try std.testing.expect((try pickAutomaticAgent(a, "no-json", null)) == null);
}

test "QA primerizo: el plazo de un modelo local crece con la petición y tiene tope" {
    const base: u64 = 180_000;
    try std.testing.expectEqual(base, live_worker.localCallTimeoutMs(base, 0, false));
    // ~11 500 tokens de Directo con herramientas: bastante más que 3 minutos.
    const directo = live_worker.localCallTimeoutMs(base, 16_500, true);
    try std.testing.expect(directo >= base + 11_000 * 50);
    try std.testing.expectEqual(live_worker.LOCAL_CALL_TIMEOUT_MAX_MS, live_worker.localCallTimeoutMs(base, 10_000_000, true));
}

fn failText(allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!DirectPlanner.Outcome {
    return .{ .text = try std.fmt.allocPrint(allocator, fmt, args), .failed = true };
}

/// T7 (f): cada rotación de cuenta deja un evento del motor
/// (`cli_account_rotated_v1`) y una línea que encabeza la respuesta del hilo.
const AccountRotation = struct {
    conn: ?db.Connection,
    order_id: i64,
    allocator: std.mem.Allocator,
    notes: std.ArrayList(u8) = .empty,

    fn deinit(self: *AccountRotation) void {
        self.notes.deinit(self.allocator);
    }

    fn notify(ctx: ?*anyopaque, notice: cli_accounts.RotationNotice) void {
        const self: *AccountRotation = @ptrCast(@alignCast(ctx.?));
        const text = cli_accounts.noticeText(self.allocator, notice) catch |e| {
            std.log.warn("aviso de rotación de cuenta no construido: {s}", .{@errorName(e)});
            return;
        };
        defer self.allocator.free(text);
        recordConnEvent(self.conn, self.order_id, self.allocator, "cli_account_rotated_v1", .{ .cli = notice.cli, .from = notice.from_id, .to = notice.to_id, .message = text });
        self.notes.print(self.allocator, "_{s}_\n\n", .{text}) catch |e| std.log.warn("aviso de rotación de cuenta no añadido al hilo: {s}", .{@errorName(e)});
    }
};

fn recordConnEvent(conn: ?db.Connection, order_id: i64, allocator: std.mem.Allocator, kind: []const u8, value: anytype) void {
    const c = conn orelse return;
    const payload = std.json.Stringify.valueAlloc(allocator, value, .{}) catch return;
    defer allocator.free(payload);
    const stmt = c.prepare("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (?, 'directo', ?, ?, ?)") catch return;
    defer c.finalize(stmt);
    db.bindInt(stmt, 1, health.nowMillis(c)) catch return;
    db.bindText(stmt, 2, kind) catch return;
    db.bindText(stmt, 3, payload) catch return;
    db.bindInt(stmt, 4, order_id) catch return;
    _ = db.c.sqlite3_step(stmt);
}

/// Lo que el agente va haciendo (texto, herramientas, plan) llega a la cabina
/// como `external_agent_event`, la misma superficie del modo orquestado: sin
/// esto, Directo con un agente externo parecía colgado hasta que terminaba.
const ExternalStream = struct {
    conn: ?db.Connection,
    order_id: i64,
    /// QA-B H7: la planificación por suscripción usa «planner».
    task_id: []const u8 = "directo",
    mutex: sync.Mutex = .init(),

    fn call(raw: *anyopaque, kind: @import("headless_adapter.zig").EventKind, text: []const u8) void {
        const self: *ExternalStream = @ptrCast(@alignCast(raw));
        if (self.conn == null) return;
        // Orden 932: el adaptador emitía estados vacíos (8 de 13 eventos);
        // no informan de nada y ensuciaban la actividad.
        if (std.mem.trim(u8, text, " \t\r\n").len == 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        recordConnEvent(self.conn, self.order_id, std.heap.c_allocator, "external_agent_event", .{ .task_id = self.task_id, .kind = @tagName(kind), .text = text[0..@min(text.len, 2048)] });
    }
};

fn externalCancelled(ctx: ?*anyopaque) bool {
    const token: *const live_worker.CancellationToken = @ptrCast(@alignCast(ctx.?));
    return token.isCancelled();
}

fn tokenCancelled(ctx: ?*anyopaque) bool {
    const token: *const live_worker.CancellationToken = @ptrCast(@alignCast(ctx.?));
    return token.isCancelled();
}

fn recordDirectEvent(llm: *const live_worker.LiveLlm, allocator: std.mem.Allocator, kind: []const u8, value: anytype) void {
    const payload = std.json.Stringify.valueAlloc(allocator, value, .{}) catch return;
    defer allocator.free(payload);
    llm.recordEvent(kind, payload);
}

/// B1 (tarea 4): separador de la línea de sistema que DevAgents añade bajo la
/// respuesta. La cabina la pinta aparte, con otro estilo; el texto del modelo
/// va antes.
pub const FACTS_MARK = "\n\n[DevAgents] ";
pub const UNWRITTEN_NOTE = "Esta vuelta no escribió ningún archivo.";
/// Nombres de archivo que caben en la línea; el resto se cuenta.
const MAX_FACT_FILES: usize = 12;

/// El texto del modelo sin la línea de sistema.
pub fn stripFacts(text: []const u8) []const u8 {
    const at = std.mem.lastIndexOf(u8, text, FACTS_MARK) orelse return text;
    return text[0..at];
}

/// ¿El texto afirma haber creado, editado o guardado archivos? Heurística
/// deliberadamente estrecha (es/en): una frase de acción en primera persona o
/// impersonal Y una mención de archivo (la palabra o un nombre con extensión).
/// Un falso negativo deja la respuesta como estaba; el aviso que provoca un
/// positivo es un hecho comprobado (la vuelta no escribió nada), no un juicio.
pub fn claimsFileWrite(text: []const u8) bool {
    return claimsWrite(text, &CLAIM_PHRASES);
}

const CLAIM_PHRASES = [_][]const u8{
    "he creado",        "he escrito",     "he guardado",       "he editado",     "he modificado",    "he actualizado",
    "he añadido",
    "he generado",      "he corregido",
    "creé ",
    "escribí ",
    "guardé ",
    "edité ",
    "modifiqué ",
    "actualicé ",
    "se ha creado",     "se ha guardado", "se ha actualizado", "archivo creado", "archivo guardado", "archivos creados",
    "ya está creado",
    "queda guardado",   "i created",      "i've created",      "i have created", "i wrote",          "i've written",
    "i have written",   "i saved",        "i've saved",        "i have saved",   "i edited",         "i've edited",
    "i updated",        "i've updated",   "i have updated",    "i modified",     "i've modified",    "i added",
    "i've added",       "file created",   "file saved",        "files created",  "has been created", "has been saved",
    "has been updated", "was created",
};

/// Auditoría C-3: promesas de escritura en futuro («voy a escribir el
/// archivo…», «I'll create the file») delatan igual una escritura que no
/// llegó: la nota «no escribió ningún archivo» es un hecho, no un juicio.
fn claimsIntendedWrite(text: []const u8) bool {
    return claimsWrite(text, &INTENT_PHRASES);
}

const INTENT_PHRASES = [_][]const u8{
    "voy a escribir",             "voy a crear",             "voy a guardar",                "vamos a escribir",          "vamos a crear",
    "escribiré ",
    "crearé ",
    "guardaré ",
    "i'll write",                 "i will write",            "i'll create",                  "i will create",             "let me write",
    "let me create",
    "empezaré por escribir",
    "empezaré por crear",
    "primero escribiré",
    "primero crearé",
    "voy a empezar por escribir", "voy a empezar por crear", "vamos a empezar por escribir", "vamos a empezar por crear",
};

fn claimsWrite(text: []const u8, phrases: []const []const u8) bool {
    var buf: [8192]u8 = undefined;
    const n = @min(text.len, buf.len);
    const lower = std.ascii.lowerString(buf[0..n], text[0..n]);
    var claimed = false;
    for (phrases) |phrase| {
        var from: usize = 0;
        while (std.mem.indexOfPos(u8, lower, from, phrase)) |at| : (from = at + 1) {
            // «no he creado…» niega justo eso.
            if (at >= 3 and std.mem.eql(u8, lower[at - 3 .. at], "no ")) continue;
            claimed = true;
            break;
        }
        if (claimed) break;
    }
    if (!claimed) return false;
    inline for (.{ "archivo", "fichero", "file" }) |word| if (std.mem.indexOf(u8, lower, word) != null) return true;
    // Un nombre con extensión: `algo.ext` con 1-5 letras o cifras y al menos una letra.
    var i: usize = 1;
    while (i + 1 < lower.len) : (i += 1) {
        if (lower[i] != '.' or !std.ascii.isAlphanumeric(lower[i - 1])) continue;
        var j = i + 1;
        var letters = false;
        while (j < lower.len and std.ascii.isAlphanumeric(lower[j])) : (j += 1) {
            if (std.ascii.isAlphabetic(lower[j])) letters = true;
        }
        const len = j - i - 1;
        if (letters and len >= 1 and len <= 5 and (j == lower.len or !std.ascii.isAlphanumeric(lower[j]))) return true;
    }
    return false;
}

test "B1 tarea 4: la línea de hechos dice lo que la vuelta escribió, no lo que el modelo afirma" {
    const a = std.testing.allocator;
    const F = DirectPlanner;
    // Escribió: se listan los archivos reales.
    const wrote = (try F.fileFacts(a, "Listo.", .{ .tools = 3, .written = &.{ "web/index.html", "web/app.js" } })).?;
    defer a.free(wrote.line);
    try std.testing.expectEqualStrings("Archivos cambiados: web/index.html, web/app.js.", wrote.line);
    try std.testing.expect(!wrote.claims_unwritten);
    // Usó herramientas de lectura y no escribió.
    const read = (try F.fileFacts(a, "El archivo tiene 40 líneas.", .{ .tools = 2 })).?;
    defer a.free(read.line);
    try std.testing.expectEqualStrings("Sin cambios en archivos.", read.line);
    // Afirma archivos sin haber escrito nada (con o sin herramientas): aviso.
    for ([_][]const u8{ "He creado el archivo saludo.py con el programa.", "I've created hello.html for you.", "Listo, archivo guardado.", "Creé index.html y styles.css." }) |text| {
        for ([_]u32{ 0, 2 }) |tools| {
            const lie = (try F.fileFacts(a, text, .{ .tools = tools })).?;
            defer a.free(lie.line);
            try std.testing.expectEqualStrings(UNWRITTEN_NOTE, lie.line);
            try std.testing.expect(lie.claims_unwritten);
        }
    }
    // Un comando pudo escribir: no se afirma «ningún archivo».
    const ran = (try F.fileFacts(a, "He creado dist/app.js con el build.", .{ .tools = 1, .commands = 1 })).?;
    defer a.free(ran.line);
    try std.testing.expectEqualStrings("Sin escrituras directas en esta vuelta: se ejecutó 1 comando, que puede haber cambiado archivos.", ran.line);
    try std.testing.expect(!ran.claims_unwritten);
    const ran2 = (try F.fileFacts(a, "He creado dist/app.js con el build.", .{ .tools = 2, .commands = 2 })).?;
    defer a.free(ran2.line);
    try std.testing.expectEqualStrings("Sin escrituras directas en esta vuelta: se ejecutaron 2 comandos, que pueden haber cambiado archivos.", ran2.line);
    // Conversación: nada que decir.
    try std.testing.expect((try F.fileFacts(a, "Hola, ¿en qué te ayudo?", .{})) == null);
    try std.testing.expect((try F.fileFacts(a, "No he creado ningún archivo todavía; dime el nombre.", .{})) == null);
    try std.testing.expect((try F.fileFacts(a, "He creado un plan de tres pasos.", .{})) == null);
    try std.testing.expect(!claimsFileWrite("La versión 2.1 salió ayer."));
    // Auditoría C-3: promesa de escritura en futuro sin herramientas = misma
    // nota de «no escribió»; la negación y la charla no la disparan.
    const intent = (try F.fileFacts(a, "Voy a empezar por escribir el archivo auditor_roto.py con el error pedido.", .{})).?;
    defer a.free(intent.line);
    try std.testing.expectEqualStrings(UNWRITTEN_NOTE, intent.line);
    try std.testing.expect(intent.claims_unwritten);
    try std.testing.expect((try F.fileFacts(a, "No voy a escribir ningún archivo; solo te explico.", .{})) == null);
    try std.testing.expect((try F.fileFacts(a, "Voy a crear un plan de tres pasos.", .{})) == null);
    try std.testing.expect((try F.fileFacts(a, "I will create a plan with three steps.", .{})) == null);
    // Más de doce archivos: se cuentan los que no caben.
    var many: [14][]const u8 = undefined;
    for (&many) |*m| m.* = "a.txt";
    const lots = (try F.fileFacts(a, "Listo.", .{ .tools = 14, .written = &many })).?;
    defer a.free(lots.line);
    try std.testing.expect(std.mem.endsWith(u8, lots.line, " y 2 más."));
    // La línea no vuelve al modelo en el historial.
    try std.testing.expectEqualStrings("Hecho.", stripFacts("Hecho." ++ FACTS_MARK ++ "Archivos cambiados: a.txt."));
    const history = [_]planner.ConversationTurn{.{ .user = "crea a.txt", .agent = "Hecho." ++ FACTS_MARK ++ "Archivos cambiados: a.txt." }};
    const prompt = try buildUserPrompt(a, &history, null, "sigue");
    defer a.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "[DevAgents]") == null);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "Asistente: Hecho.\n") != null);
}

test "B1 tarea 4: Directo añade la línea de sistema bajo la respuesta" {
    const a = std.testing.allocator;
    const Wrote = struct {
        fn run(_: ?*anyopaque, llm: *live_worker.LiveLlm, system: []const u8, _: []const u8) []const u8 {
            // La regla viaja en el prompt de sistema, en una sola línea.
            std.testing.expect(std.mem.indexOf(u8, system, "Nunca digas que creaste, editaste o guardaste un archivo que no escribiste") != null) catch return "";
            llm.last_tools_run = 2;
            const copy = std.testing.allocator.dupe(u8, "saludo.py") catch return "";
            llm.last_agentic_written.append(std.testing.allocator, copy) catch {
                std.testing.allocator.free(copy);
                return "";
            };
            return "He creado saludo.py.";
        }
        fn claimed(_: ?*anyopaque, _: *live_worker.LiveLlm, _: []const u8, _: []const u8) []const u8 {
            return "He creado el archivo saludo.py con el programa.";
        }
    };
    var live = live_worker.LiveLlm{ .allocator = a, .lives = &.{}, .buffer = .empty, .catalog_path = "" };
    defer live.deinit();
    live.setGovernedTools(.{ .plan_approved = true, .agentic = true });
    var dp = DirectPlanner.init(a, "");
    dp.test_live = &live;
    dp.run_fn = Wrote.run;
    dp.workspace_root = "C:\\fixture";
    var plan = try dp.backend().plan(a, "crea saludo.py", &.{}, null);
    defer plan.deinit();
    try std.testing.expectEqualStrings("He creado saludo.py." ++ FACTS_MARK ++ "Archivos cambiados: saludo.py.", plan.understanding);
    var live2 = live_worker.LiveLlm{ .allocator = a, .lives = &.{}, .buffer = .empty, .catalog_path = "" };
    defer live2.deinit();
    var dp2 = DirectPlanner.init(a, "");
    dp2.test_live = &live2;
    dp2.run_fn = Wrote.claimed;
    dp2.workspace_root = "C:\\fixture";
    var plan2 = try dp2.backend().plan(a, "crea saludo.py", &.{}, null);
    defer plan2.deinit();
    try std.testing.expectEqualStrings("He creado el archivo saludo.py con el programa." ++ FACTS_MARK ++ UNWRITTEN_NOTE, plan2.understanding);
}

/// Prompt del usuario: conversación previa, memoria del proyecto y el mensaje.
pub fn buildUserPrompt(allocator: std.mem.Allocator, history: []const planner.ConversationTurn, memory_context: ?[]const u8, message: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(allocator);
    const start = if (history.len > MAX_HISTORY_TURNS) history.len - MAX_HISTORY_TURNS else 0;
    if (history.len > start) {
        try out.appendSlice(allocator, "[CONVERSACIÓN PREVIA]\n");
        for (history[start..]) |turn| {
            try out.appendSlice(allocator, "Usuario: ");
            try out.appendSlice(allocator, turn.user[0..@min(turn.user.len, MAX_TURN_BYTES)]);
            try out.appendSlice(allocator, "\nAsistente: ");
            // B1: la línea de hechos es del sistema; no vuelve al modelo (ni la
            // paga en tokens ni aprende a imitarla).
            const said = stripFacts(turn.agent);
            try out.appendSlice(allocator, said[0..@min(said.len, MAX_TURN_BYTES)]);
            try out.appendSlice(allocator, "\n");
        }
        try out.appendSlice(allocator, "[FIN DE LA CONVERSACIÓN PREVIA]\n\n");
    }
    if (memory_context) |m| if (std.mem.trim(u8, m, " \t\r\n").len > 0) {
        try out.appendSlice(allocator, "[MEMORIA DEL PROYECTO]\n");
        try out.appendSlice(allocator, m);
        try out.appendSlice(allocator, "\n[FIN DE LA MEMORIA]\n\n");
    };
    try out.appendSlice(allocator, "[MENSAJE DEL USUARIO]\n");
    try out.appendSlice(allocator, message);
    return out.toOwnedSlice(allocator);
}

/// Plan de charla sin tareas: el superagente lo cierra `done` (o `failed` si
/// la sesión no produjo respuesta) por la ruta conversacional de siempre.
fn chatPlan(allocator: std.mem.Allocator, text: []u8, failed: bool) planner.PlannerError!planner.Plan {
    errdefer allocator.free(text);
    const questions = try allocator.alloc(planner.ClarificationQuestion, 0);
    errdefer allocator.free(questions);
    const tasks = try allocator.alloc(planner.PlannedTask, 0);
    return .{
        .allocator = allocator,
        .understanding = text,
        .questions = questions,
        .tasks = tasks,
        .kind = if (failed) .failed else .chat,
    };
}

// ---------------------------------------------------------------- pruebas

const TestSession = struct {
    reply: []const u8,
    calls: usize = 0,
    last_system: []u8 = &.{},
    last_user: []u8 = &.{},

    fn run(ctx: ?*anyopaque, llm: *live_worker.LiveLlm, system_prompt: []const u8, user_prompt: []const u8) []const u8 {
        _ = llm;
        const self: *TestSession = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.last_system = std.testing.allocator.dupe(u8, system_prompt) catch &.{};
        self.last_user = std.testing.allocator.dupe(u8, user_prompt) catch &.{};
        return self.reply;
    }

    fn deinit(self: *TestSession) void {
        std.testing.allocator.free(self.last_system);
        std.testing.allocator.free(self.last_user);
    }
};

test "CK-PUB-011 Directo: una sola llamada al modelo y plan de charla sin tareas" {
    const a = std.testing.allocator;
    var live = live_worker.LiveLlm{ .allocator = a, .lives = &.{}, .buffer = .empty, .catalog_path = "" };
    defer live.deinit();
    var session = TestSession{ .reply = "  Hola, ¿en qué te ayudo?  " };
    defer session.deinit();
    var dp = DirectPlanner.init(a, "");
    dp.test_live = &live;
    dp.run_fn = TestSession.run;
    dp.run_ctx = &session;
    dp.workspace_root = "C:\\proyecto";
    const history = [_]planner.ConversationTurn{.{ .user = "primer mensaje", .agent = "primera respuesta" }};
    dp.history = &history;
    var plan = try dp.backend().plan(a, "hola", &.{}, "nota de memoria");
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), session.calls);
    try std.testing.expectEqual(planner.PlanKind.chat, plan.kind);
    try std.testing.expectEqual(@as(usize, 0), plan.tasks.len);
    try std.testing.expectEqual(@as(usize, 0), plan.questions.len);
    try std.testing.expectEqualStrings("Hola, ¿en qué te ayudo?", plan.understanding);
    // La conversación, la memoria y el mensaje viajan en el prompt.
    try std.testing.expect(std.mem.indexOf(u8, session.last_user, "primer mensaje") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.last_user, "primera respuesta") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.last_user, "nota de memoria") != null);
    try std.testing.expect(std.mem.endsWith(u8, session.last_user, "[MENSAJE DEL USUARIO]\nhola"));
    try std.testing.expect(std.mem.indexOf(u8, session.last_system, "C:\\proyecto") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.last_system, "modo Directo") != null);
    // T7: Directo (el modo por defecto) lleva las reglas de código limpio.
    try std.testing.expect(std.mem.indexOf(u8, session.last_system, project_rules.HEADER) != null);
    try std.testing.expect(std.mem.indexOf(u8, session.last_system, "RAII") != null);
}

test "T7 reglas del proyecto: Directo lleva las propias y las reglas del repositorio detras, que manda" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "AGENTS-T7: tests con pytest." });
    var live = live_worker.LiveLlm{ .allocator = a, .lives = &.{}, .buffer = .empty, .catalog_path = "" };
    defer live.deinit();
    var session = TestSession{ .reply = "hecho" };
    defer session.deinit();
    var dp = DirectPlanner.init(a, "");
    dp.test_live = &live;
    dp.run_fn = TestSession.run;
    dp.run_ctx = &session;
    dp.workspace_root = root;
    dp.rules_context = .{ .root = root, .custom = "REGLA-T7-DIRECTO: comenta en inglés." };
    var plan = try dp.backend().plan(a, "crea main.py", &.{}, null);
    defer plan.deinit();
    const system = session.last_system;
    const rules_at = std.mem.indexOf(u8, system, "REGLA-T7-DIRECTO: comenta en inglés.") orelse return error.TestUnexpectedResult;
    const doc_at = std.mem.indexOf(u8, system, "AGENTS-T7: tests con pytest.") orelse return error.TestUnexpectedResult;
    try std.testing.expect(rules_at < doc_at);
    try std.testing.expect(std.mem.indexOf(u8, system, project_rules.PRECEDENCE_NOTE) != null);
    // Reglas propias sustituyen a las de defecto.
    try std.testing.expect(std.mem.indexOf(u8, system, "RAII") == null);
}

test "CK-PUB-011 Directo: sin respuesta la orden falla con el motivo, nunca charla vacía" {
    const a = std.testing.allocator;
    var live = live_worker.LiveLlm{ .allocator = a, .lives = &.{}, .buffer = .empty, .catalog_path = "" };
    defer live.deinit();
    var session = TestSession{ .reply = "" };
    defer session.deinit();
    var dp = DirectPlanner.init(a, "");
    dp.test_live = &live;
    dp.run_fn = TestSession.run;
    dp.run_ctx = &session;
    dp.workspace_root = ".";
    var plan = try dp.backend().plan(a, "crea un archivo", &.{}, null);
    defer plan.deinit();
    try std.testing.expectEqual(planner.PlanKind.failed, plan.kind);
    try std.testing.expect(std.mem.startsWith(u8, plan.understanding, "Directo: el modelo no devolvió ninguna respuesta"));
}

test "USUARIO-NUEVO R3: finish que declara un archivo que no existe se dice en la respuesta" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var file = try tmp.dir.createFile(io, "existe.txt", .{});
    file.close(io);
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    const Claim = struct {
        fn run(_: ?*anyopaque, llm: *live_worker.LiveLlm, _: []const u8, _: []const u8) []const u8 {
            const files = std.testing.allocator.alloc([]u8, 2) catch return "";
            files[0] = std.testing.allocator.dupe(u8, "existe.txt") catch return "";
            files[1] = std.testing.allocator.dupe(u8, "plegado.txt") catch return "";
            llm.last_agentic_finished = true;
            llm.last_agentic_files = files;
            return "He creado plegado.txt.";
        }
    };
    var live = live_worker.LiveLlm{ .allocator = a, .lives = &.{}, .buffer = .empty, .catalog_path = "" };
    defer live.deinit();
    var dp = DirectPlanner.init(a, "");
    dp.test_live = &live;
    dp.run_fn = Claim.run;
    dp.workspace_root = root;
    var plan = try dp.backend().plan(a, "crea plegado.txt", &.{}, null);
    defer plan.deinit();
    try std.testing.expectEqual(planner.PlanKind.chat, plan.kind);
    try std.testing.expect(std.mem.indexOf(u8, plan.understanding, "dijo haber escrito plegado.txt, pero no existe") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.understanding, "existe.txt,") == null);
    // Sin `finish` (respuesta de texto sin herramientas) el motor no tiene un
    // hecho que contrastar: no se toca el texto.
    var plain = TestSession{ .reply = "Hola." };
    defer plain.deinit();
    var live2 = live_worker.LiveLlm{ .allocator = a, .lives = &.{}, .buffer = .empty, .catalog_path = "" };
    defer live2.deinit();
    var dp2 = DirectPlanner.init(a, "");
    dp2.test_live = &live2;
    dp2.run_fn = TestSession.run;
    dp2.run_ctx = &plain;
    dp2.workspace_root = root;
    var plan2 = try dp2.backend().plan(a, "hola", &.{}, null);
    defer plan2.deinit();
    try std.testing.expectEqualStrings("Hola.", plan2.understanding);
}

test "USUARIO-NUEVO A6: el 429 por cuota diaria se explica con el motivo del proveedor y qué hacer" {
    const a = std.testing.allocator;
    var diag = providers.external_error.Diagnostic{};
    diag.capture(429, "{\"error\":{\"message\":\"Rate limit exceeded: free-models-per-day.\",\"code\":429}}", null);
    const daily = try DirectPlanner.failureText(a, "RateLimited", diag, "OpenRouter", "google/gemma-4-26b-a4b-it:free");
    defer a.free(daily);
    try std.testing.expectEqualStrings("Directo: google/gemma-4-26b-a4b-it:free de OpenRouter rechazó la petición: se agotó la cuota gratuita de hoy para ese modelo. El proveedor dijo: «Rate limit exceeded: free-models-per-day.». No se reintentó para no gastar más llamadas. Prueba con otro modelo gratuito o vuelve mañana.", daily);
    var empty = providers.external_error.Diagnostic{};
    empty.capture(429, "", null);
    const burst = try DirectPlanner.failureText(a, "RateLimited", empty, "OpenRouter", "x:free");
    defer a.free(burst);
    try std.testing.expect(std.mem.indexOf(u8, burst, "RateLimited") == null);
    try std.testing.expect(std.mem.indexOf(u8, burst, "otro modelo gratuito") != null);
}

test "CK-PUB-011 Directo: el modelo sabe qué modelo es" {
    const a = std.testing.allocator;
    var live = live_worker.LiveLlm{ .allocator = a, .lives = &.{}, .buffer = .empty, .catalog_path = "" };
    defer live.deinit();
    var session = TestSession{ .reply = "Soy command-a-plus-05-2026." };
    defer session.deinit();
    var dp = DirectPlanner.init(a, "");
    dp.test_live = &live;
    dp.run_fn = TestSession.run;
    dp.run_ctx = &session;
    dp.workspace_root = ".";
    dp.forced_provider = "Cohere";
    dp.forced_model = "command-a-plus-05-2026";
    var plan = try dp.backend().plan(a, "¿qué modelo eres?", &.{}, null);
    defer plan.deinit();
    try std.testing.expect(std.mem.indexOf(u8, session.last_system, "Eres el modelo `command-a-plus-05-2026` del proveedor `Cohere`") != null);
    try std.testing.expect(std.mem.indexOf(u8, session.last_system, "por el usuario") != null);
}

test "CK-PUB-011 Directo: orden vacía se rechaza y el historial se acota" {
    const a = std.testing.allocator;
    var dp = DirectPlanner.init(a, "");
    try std.testing.expectError(error.EmptyOrder, dp.backend().plan(a, "  \n", &.{}, null));
    var turns: [20]planner.ConversationTurn = undefined;
    for (&turns, 0..) |*t, i| t.* = .{ .user = if (i == 0) "turno-viejo" else "u", .agent = "r" };
    const prompt = try buildUserPrompt(a, &turns, null, "ahora");
    defer a.free(prompt);
    try std.testing.expect(std.mem.indexOf(u8, prompt, "turno-viejo") == null);
    try std.testing.expect(std.mem.endsWith(u8, prompt, "ahora"));
}

const FakeAgent = struct {
    declaration: []const u8 = "Listo: creé index.html.",
    success: bool = true,
    fail_with: ?anyerror = null,
    calls: usize = 0,
    worktree: [256]u8 = undefined,
    worktree_len: usize = 0,
    cli: []const u8 = "",
    /// B1c: el agente responde sin haber cambiado nada en disco.
    no_files: bool = false,

    fn run(ctx: ?*anyopaque, a: std.mem.Allocator, io: std.Io, task: planner.PlannedTask, req: external_agents.RunRequest, sb: sandbox.Sandbox) anyerror!external_agents.RunOutcome {
        _ = io;
        _ = sb;
        const self: *FakeAgent = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.cli = req.meta.cli_id;
        @memcpy(self.worktree[0..req.worktree.len], req.worktree);
        self.worktree_len = req.worktree.len;
        if (std.mem.indexOf(u8, task.description, "[MENSAJE DEL USUARIO]\nhaz la web") == null) return error.PromptSinMensaje;
        if (self.fail_with) |e| return e;
        const arts = try a.alloc(@import("worker_backend.zig").Artifact, if (self.no_files) 0 else 1);
        if (!self.no_files) arts[0] = .{ .path = try a.dupe(u8, "web/index.html"), .content = try a.dupe(u8, "<p>hola</p>") };
        return .{
            .success = self.success,
            .agent_version = try a.dupe(u8, "1.0"),
            .argv_censored = try a.dupe(u8, "claude -p"),
            .declaration = try a.dupe(u8, self.declaration),
            .detail = try a.dupe(u8, "traza"),
            .artifacts = arts,
        };
    }
};

test "CK-PUB-011 Directo con agente externo: lo lanza en la carpeta del proyecto y responde con lo que dijo" {
    const a = std.testing.allocator;
    var fake = FakeAgent{};
    var dp = DirectPlanner.init(a, "");
    dp.forced_provider = "agent:claude-code";
    dp.forced_model = "default";
    dp.workspace_root = "C:\\proyecto";
    dp.external = .{ .run_fn = FakeAgent.run, .run_ctx = &fake };
    var plan = try dp.backend().plan(a, "haz la web", &.{}, null);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.calls);
    try std.testing.expectEqualStrings("claude-code", fake.cli);
    try std.testing.expectEqualStrings("C:\\proyecto", fake.worktree[0..fake.worktree_len]);
    try std.testing.expectEqual(planner.PlanKind.chat, plan.kind);
    // B1c (tarea 4): bajo lo que dijo el agente, lo que cambió en disco.
    try std.testing.expectEqualStrings("Listo: creé index.html." ++ FACTS_MARK ++ "Archivos cambiados: web/index.html.", plan.understanding);
    // Si afirma un archivo y el disco no cambió, la nota del sistema lo dice.
    var idle = FakeAgent{ .no_files = true };
    dp.external.run_ctx = &idle;
    var plan2 = try dp.backend().plan(a, "haz la web", &.{}, null);
    defer plan2.deinit();
    try std.testing.expectEqualStrings("Listo: creé index.html." ++ FACTS_MARK ++ UNWRITTEN_NOTE, plan2.understanding);
}

test "B1e F0.6: directo_started_v1 guarda modo de permisos, versión y ruta de la CLI detectada" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var catalog = try db.Connection.open(a, ":memory:");
    defer catalog.close();
    try db.Migrator.init(a).migrate(catalog, &db.catalog_schema);
    var events = try db.Connection.open(a, ":memory:");
    defer events.close();
    try events.exec("CREATE TABLE events (id INTEGER PRIMARY KEY, ts INTEGER, source TEXT, kind TEXT, payload_json TEXT, order_id INTEGER)");
    const cat = "[{\"provider\":\"agent:claude-code\",\"cli\":\"claude-code\",\"exe\":\"C:/app/claude.exe\",\"version\":\"2.4.1\",\"session\":\"suscripcion\",\"models\":[{\"slug\":\"sonnet\"}]}]";
    var fake = FakeAgent{};
    var dp = DirectPlanner.init(a, "");
    dp.forced_provider = "agent:claude-code";
    dp.forced_model = "sonnet";
    dp.workspace_root = "C:\\proyecto";
    dp.event_order_id = 7;
    dp.permission_config = .{ .mode = .accept_edits };
    dp.external = .{ .run_fn = FakeAgent.run, .run_ctx = &fake, .catalog_json = cat, .catalog_conn = catalog, .event_conn = events };
    var plan = try dp.backend().plan(a, "haz la web", &.{}, null);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), fake.calls);

    const q = try events.prepare("SELECT kind, payload_json FROM events WHERE order_id = 7 AND kind LIKE 'directo_%' ORDER BY id");
    defer events.finalize(q);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(q));
    try std.testing.expectEqualStrings("directo_started_v1", std.mem.span(db.c.sqlite3_column_text(q, 0)));
    var started = try std.json.parseFromSlice(std.json.Value, a, std.mem.span(db.c.sqlite3_column_text(q, 1)), .{});
    defer started.deinit();
    const s = started.value.object;
    try std.testing.expectEqualStrings("accept_edits", s.get("permission_mode").?.string);
    try std.testing.expectEqualStrings("2.4.1", s.get("cli_version").?.string);
    try std.testing.expectEqualStrings("C:/app/claude.exe", s.get("cli_path").?.string);
    try std.testing.expectEqualStrings("agent:claude-code", s.get("provider").?.string);
    try std.testing.expect(s.get("agent").?.bool);
    // El cierre lleva la versión que midió el adaptador (la del FakeAgent).
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(q));
    try std.testing.expectEqualStrings("directo_finished_v1", std.mem.span(db.c.sqlite3_column_text(q, 0)));
    var finished = try std.json.parseFromSlice(std.json.Value, a, std.mem.span(db.c.sqlite3_column_text(q, 1)), .{});
    defer finished.deinit();
    try std.testing.expectEqualStrings("1.0", finished.value.object.get("cli_version").?.string);

    // Sin catálogo (sin pin) el arranque lo dice con null, sin ejecutar `--version`.
    var fake2 = FakeAgent{};
    dp.external = .{ .run_fn = FakeAgent.run, .run_ctx = &fake2, .event_conn = events };
    dp.event_order_id = 8;
    var plan2 = try dp.backend().plan(a, "haz la web", &.{}, null);
    defer plan2.deinit();
    const q2 = try events.prepare("SELECT payload_json FROM events WHERE order_id = 8 AND kind = 'directo_started_v1'");
    defer events.finalize(q2);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(q2));
    var s2 = try std.json.parseFromSlice(std.json.Value, a, std.mem.span(db.c.sqlite3_column_text(q2, 0)), .{});
    defer s2.deinit();
    try std.testing.expectEqualStrings("accept_edits", s2.value.object.get("permission_mode").?.string);
    try std.testing.expect(s2.value.object.get("cli_version").? == .null);
    try std.testing.expect(s2.value.object.get("cli_path").? == .null);
}

test "CK-PUB-011 Directo con agente externo: sin sesión o por MCP falla con el motivo, sin charla falsa" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var fake = FakeAgent{ .fail_with = error.NotLoggedIn };
    var dp = DirectPlanner.init(a, "");
    dp.forced_provider = "agent:codex";
    dp.forced_model = "gpt-5";
    dp.workspace_root = "C:\\proyecto";
    dp.external = .{ .run_fn = FakeAgent.run, .run_ctx = &fake };
    var plan = try dp.backend().plan(a, "haz la web", &.{}, null);
    defer plan.deinit();
    try std.testing.expect(plan.kind != planner.PlanKind.chat);
    try std.testing.expect(std.mem.indexOf(u8, plan.understanding, "sesión iniciada") != null);

    var fake2 = FakeAgent{};
    dp.external.run_ctx = &fake2;
    dp.origin = .mcp;
    var plan2 = try dp.backend().plan(a, "haz la web", &.{}, null);
    defer plan2.deinit();
    try std.testing.expectEqual(@as(usize, 0), fake2.calls);
    try std.testing.expect(std.mem.indexOf(u8, plan2.understanding, "MCP") != null);
}

/// QA-B H7: CLI simulada para planificar: comprueba que la llamada es de solo
/// lectura y lleva el prompt del planificador, y responde con `reply`.
const PlanAgent = struct {
    reply: []const u8,
    calls: usize = 0,
    saw_read_only: bool = false,
    saw_planner_prompt: bool = false,
    /// T12 A2: si no es null, la CLI simulada escribe este archivo en la
    /// carpeta del proyecto mientras «planifica» (lo que una CLI no debe hacer).
    writes: ?[]const u8 = null,

    fn run(ctx: ?*anyopaque, a: std.mem.Allocator, _: std.Io, task: planner.PlannedTask, req: external_agents.RunRequest, _: sandbox.Sandbox) anyerror!external_agents.RunOutcome {
        const self: *PlanAgent = @ptrCast(@alignCast(ctx.?));
        self.calls += 1;
        self.saw_read_only = req.read_only and req.deny_shell;
        self.saw_planner_prompt = std.mem.indexOf(u8, task.description, "crea hola.py") != null and
            std.mem.indexOf(u8, task.description, "Devuelve solo el JSON") != null;
        if (self.writes) |name| {
            var dir = try std.Io.Dir.cwd().openDir(std.testing.io, req.worktree, .{});
            defer dir.close(std.testing.io);
            try dir.writeFile(std.testing.io, .{ .sub_path = name, .data = "escrito al planificar" });
        }
        return .{
            .success = true,
            .agent_version = try a.dupe(u8, "9.9.9"),
            .argv_censored = try a.dupe(u8, "claude -p"),
            .declaration = try a.dupe(u8, self.reply),
            .detail = try a.dupe(u8, ""),
            .artifacts = &.{},
        };
    }
};

test "T12 A2: si la CLI escribe en el proyecto al planificar, el plan falla y dice qué cambió" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var catalog = try db.Connection.open(a, ":memory:");
    defer catalog.close();
    try db.Migrator.init(a).migrate(catalog, &db.catalog_schema);
    var runtime = try db.Connection.open(a, ":memory:");
    defer runtime.close();
    try db.Migrator.init(a).migrate(runtime, &db.runtime_schema);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "existente.txt", .data = "antes" });
    try tmp.dir.createDirPath(std.testing.io, ".git");
    try tmp.dir.createDirPath(std.testing.io, ".git" ++ std.fs.path.sep_str ++ "hooks");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const git_index = try std.fs.path.join(a, &.{ ".git", "index" });
    defer a.free(git_index);
    const git_hook = try std.fs.path.join(a, &.{ ".git", "hooks", "pre-commit" });
    defer a.free(git_hook);
    const agents = "[{\"provider\":\"agent:claude-code\",\"cli\":\"claude-code\",\"session\":\"suscripcion\",\"exe\":\"C:/fixture/claude.exe\",\"version\":\"9.9.9\",\"models\":[{\"slug\":\"sonnet\"}]}]";
    const valid = "{\"understanding\":\"Crear hola.py\",\"tasks\":[{\"id\":\"t1\",\"task_type\":\"programar\",\"department\":\"programacion\",\"description\":\"Escribe hola.py\",\"contract_fields\":[],\"depends_on\":[]}]}";
    for ([_]struct { writes: ?[]const u8, ok: bool, changed: []const u8 }{
        .{ .writes = null, .ok = true, .changed = "" },
        // Lo que git toca al consultar no cuenta: el índice de .git queda fuera.
        .{ .writes = git_index, .ok = true, .changed = "" },
        // T12B M-3: un hook sí gobierna lo que git ejecuta: cuenta.
        .{ .writes = git_hook, .ok = false, .changed = "pre-commit" },
        .{ .writes = "hola.py", .ok = false, .changed = "hola.py" },
    }) |case| {
        var agent = PlanAgent{ .reply = valid, .writes = case.writes };
        var sub = SubscriptionPlanning.init(a);
        defer sub.deinit();
        sub.external.catalog_json = agents;
        sub.external.catalog_conn = catalog;
        sub.external.event_conn = runtime;
        sub.external.run_fn = PlanAgent.run;
        sub.external.run_ctx = &agent;
        sub.workspace_root = root;
        var lp = llm_planner.LlmPlanner.init(a, "no-existe-t12.db");
        lp.subscription = sub.subscriptionPlanner();
        var plan = try lp.backend().plan(a, "crea hola.py que imprima hola", &.{}, null);
        defer plan.deinit();
        try std.testing.expectEqual(@as(usize, 1), agent.calls);
        if (case.ok) {
            try std.testing.expect(plan.kind != .failed);
        } else {
            try std.testing.expectEqual(planner.PlanKind.failed, plan.kind);
            try std.testing.expectEqual(@as(usize, 0), plan.tasks.len);
            try std.testing.expect(std.mem.indexOf(u8, plan.understanding, "cambió la carpeta del proyecto mientras planificaba") != null);
            try std.testing.expect(std.mem.indexOf(u8, plan.understanding, case.changed) != null);
        }
    }
    const q = try runtime.prepare("SELECT COUNT(*) FROM events WHERE kind='planner_cli_v1' AND json_extract(payload_json,'$.error')='project_modified' AND json_extract(payload_json,'$.path')='nuevo: hola.py'");
    defer runtime.finalize(q);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(q));
    try std.testing.expectEqual(@as(i64, 1), db.c.sqlite3_column_int64(q, 0));
}

test "T12B M-3: si la huella del árbol queda incompleta, el plan se descarta" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var catalog = try db.Connection.open(a, ":memory:");
    defer catalog.close();
    try db.Migrator.init(a).migrate(catalog, &db.catalog_schema);
    var runtime = try db.Connection.open(a, ":memory:");
    defer runtime.close();
    try db.Migrator.init(a).migrate(runtime, &db.runtime_schema);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "existente.txt", .data = "antes" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const agents = "[{\"provider\":\"agent:claude-code\",\"cli\":\"claude-code\",\"session\":\"suscripcion\",\"exe\":\"C:/fixture/claude.exe\",\"version\":\"9.9.9\",\"models\":[{\"slug\":\"sonnet\"}]}]";
    const valid = "{\"understanding\":\"Crear hola.py\",\"tasks\":[{\"id\":\"t1\",\"task_type\":\"programar\",\"department\":\"programacion\",\"description\":\"Escribe hola.py\",\"contract_fields\":[],\"depends_on\":[]}]}";
    var agent = PlanAgent{ .reply = valid, .writes = null };
    var sub = SubscriptionPlanning.init(a);
    defer sub.deinit();
    sub.external.catalog_json = agents;
    sub.external.catalog_conn = catalog;
    sub.external.event_conn = runtime;
    sub.external.run_fn = PlanAgent.run;
    sub.external.run_ctx = &agent;
    sub.workspace_root = root;
    // Con el tope a cero la huella no se puede completar: no se puede afirmar
    // que la carpeta quedó intacta.
    sub.tree_cap = 0;
    var lp = llm_planner.LlmPlanner.init(a, "no-existe-t12.db");
    lp.subscription = sub.subscriptionPlanner();
    var plan = try lp.backend().plan(a, "crea hola.py que imprima hola", &.{}, null);
    defer plan.deinit();
    try std.testing.expectEqual(@as(usize, 1), agent.calls);
    try std.testing.expectEqual(planner.PlanKind.failed, plan.kind);
    try std.testing.expectEqual(@as(usize, 0), plan.tasks.len);
    try std.testing.expect(std.mem.indexOf(u8, plan.understanding, "el plan se descarta") != null);
    const q = try runtime.prepare("SELECT COUNT(*) FROM events WHERE kind='planner_cli_v1' AND json_extract(payload_json,'$.error')='tree_unchecked'");
    defer runtime.finalize(q);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(q));
    try std.testing.expectEqual(@as(i64, 1), db.c.sqlite3_column_int64(q, 0));
}

test "T12B M-3: config, hooks e info entran en la huella, el índice no" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, ".git" ++ std.fs.path.sep_str ++ "hooks" ++ std.fs.path.sep_str ++ "nested");
    try tmp.dir.createDirPath(std.testing.io, ".git" ++ std.fs.path.sep_str ++ "info");
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const paths = [_][]const u8{
        ".git" ++ std.fs.path.sep_str ++ "config",
        ".git" ++ std.fs.path.sep_str ++ "hooks" ++ std.fs.path.sep_str ++ "nested" ++ std.fs.path.sep_str ++ "pre-commit",
        ".git" ++ std.fs.path.sep_str ++ "info" ++ std.fs.path.sep_str ++ "attributes",
        ".git" ++ std.fs.path.sep_str ++ "index",
    };
    for (paths, 0..) |path, i| {
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "antes" });
        var before = try ProjectTreePrint.take(a, root);
        defer before.deinit();
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = "después, tamaño distinto" });
        var after = try ProjectTreePrint.take(a, root);
        defer after.deinit();
        try std.testing.expect(before.complete and after.complete);
        const changed = try before.firstDifference(a, &after);
        defer if (changed) |text| a.free(text);
        if (i < 3) {
            try std.testing.expect(changed != null);
            try std.testing.expect(std.mem.indexOf(u8, changed.?, path) != null);
        } else try std.testing.expect(changed == null);
    }
}

test "T12 A2: la huella del árbol ve archivos nuevos, cambiados y borrados" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src\\a.txt", .data = "uno" });
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var first = try ProjectTreePrint.take(a, root);
    defer first.deinit();
    try std.testing.expect(first.complete);
    var same = try ProjectTreePrint.take(a, root);
    defer same.deinit();
    try std.testing.expect((try first.firstDifference(a, &same)) == null);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "src\\a.txt", .data = "uno y dos" });
    var changed = try ProjectTreePrint.take(a, root);
    defer changed.deinit();
    const what = (try first.firstDifference(a, &changed)).?;
    defer a.free(what);
    try std.testing.expect(std.mem.startsWith(u8, what, "modificado: src"));
    try tmp.dir.deleteFile(std.testing.io, "src\\a.txt");
    var gone = try ProjectTreePrint.take(a, root);
    defer gone.deinit();
    const removed = (try first.firstDifference(a, &gone)).?;
    defer a.free(removed);
    try std.testing.expect(std.mem.startsWith(u8, removed, "borrado: src"));
}

test "QA-B H7: sin clave de API la orden la planifica la CLI con suscripción; salida inválida = fallo claro" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var catalog = try db.Connection.open(a, ":memory:");
    defer catalog.close();
    try db.Migrator.init(a).migrate(catalog, &db.catalog_schema);
    var runtime = try db.Connection.open(a, ":memory:");
    defer runtime.close();
    try db.Migrator.init(a).migrate(runtime, &db.runtime_schema);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const agents = "[{\"provider\":\"agent:claude-code\",\"cli\":\"claude-code\",\"session\":\"suscripcion\",\"exe\":\"C:/fixture/claude.exe\",\"version\":\"9.9.9\",\"models\":[{\"slug\":\"sonnet\"}]}]";
    const valid = "```json\n{\"understanding\":\"Crear hola.py\",\"tasks\":[{\"id\":\"t1\",\"task_type\":\"programar\",\"department\":\"programacion\",\"description\":\"Escribe hola.py\",\"contract_fields\":[],\"depends_on\":[]}]}\n```";

    for ([_]struct { reply: []const u8, ok: bool }{ .{ .reply = valid, .ok = true }, .{ .reply = "Te lo hago enseguida: primero el archivo.", .ok = false } }) |case| {
        var agent = PlanAgent{ .reply = case.reply };
        var sub = SubscriptionPlanning.init(a);
        defer sub.deinit();
        sub.external.catalog_json = agents;
        sub.external.catalog_conn = catalog;
        sub.external.event_conn = runtime;
        sub.external.run_fn = PlanAgent.run;
        sub.external.run_ctx = &agent;
        sub.workspace_root = root;
        // Sin catálogo de claves ni modelos locales: no hay candidato por API.
        var lp = llm_planner.LlmPlanner.init(a, "no-existe-qa-b.db");
        lp.subscription = sub.subscriptionPlanner();
        var plan = try lp.backend().plan(a, "crea hola.py que imprima hola", &.{}, null);
        defer plan.deinit();
        try std.testing.expectEqual(@as(usize, 1), agent.calls);
        try std.testing.expect(agent.saw_read_only);
        try std.testing.expect(agent.saw_planner_prompt);
        try std.testing.expectEqualStrings("Claude Code (sonnet)", sub.label().?);
        if (case.ok) {
            try std.testing.expect(plan.kind != .failed);
            try std.testing.expectEqual(@as(usize, 1), plan.tasks.len);
            try std.testing.expectEqualStrings("Escribe hola.py", plan.tasks[0].description);
        } else {
            // Nada de plan local en silencio: plan fallido que nombra la CLI.
            try std.testing.expectEqual(planner.PlanKind.failed, plan.kind);
            try std.testing.expectEqual(@as(usize, 0), plan.tasks.len);
            try std.testing.expect(std.mem.indexOf(u8, plan.understanding, "Claude Code (sonnet) respondió por suscripción, pero su salida no es un plan válido") != null);
        }
    }
    // El motor deja qué CLI planificó y si valió (la cabina lo pinta).
    const q = try runtime.prepare("SELECT COUNT(*) FROM events WHERE kind='planner_cli_v1' AND json_extract(payload_json,'$.status')='finished' AND json_extract(payload_json,'$.display')='Claude Code'");
    defer runtime.finalize(q);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(q));
    try std.testing.expectEqual(@as(i64, 2), db.c.sqlite3_column_int64(q, 0));

    // Sin ninguna CLI detectada, el planificador sigue su vía de siempre.
    var none = SubscriptionPlanning.init(a);
    defer none.deinit();
    none.external.catalog_json = "[]";
    none.external.catalog_conn = catalog;
    var lp2 = llm_planner.LlmPlanner.init(a, "no-existe-qa-b.db");
    lp2.subscription = none.subscriptionPlanner();
    var fallback = try lp2.backend().plan(a, "crea hola.py que imprima hola", &.{}, null);
    defer fallback.deinit();
    try std.testing.expect(none.label() == null);
}

test "VG2 Directo: el cierre confirma escritura y vencimiento con modelo simulado" {
    const a = std.testing.allocator;
    var live = live_worker.LiveLlm{ .allocator = a, .lives = &.{}, .buffer = .empty, .catalog_path = "" };
    defer live.deinit();
    const Model = struct {
        fn run(_: ?*anyopaque, llm: *live_worker.LiveLlm, system: []const u8, _: []const u8) []const u8 {
            if (std.mem.indexOf(u8, system, "basa el cierre en los resultados") == null) return "";
            const file = a.dupe(u8, "reloj_analogico.py") catch unreachable;
            llm.last_agentic_written.append(a, file) catch unreachable;
            llm.last_command_facts.timed_out = 1;
            return "Escribí el reloj e intenté abrirlo.";
        }
    };
    var dp = DirectPlanner.init(a, "");
    dp.test_live = &live;
    dp.run_fn = Model.run;
    dp.workspace_root = ".";
    var plan = try dp.backend().plan(a, "crea y abre un reloj", &.{}, null);
    defer plan.deinit();
    try std.testing.expect(std.mem.indexOf(u8, plan.understanding, "Archivos cambiados: reloj_analogico.py") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.understanding, "1 detenidos por tiempo límite") != null);
    try std.testing.expect(std.mem.indexOf(u8, plan.understanding, "relanzar en segundo plano") != null);
}
