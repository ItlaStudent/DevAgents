pub const posix_keys = @import("posix_keys.zig");
pub const containment = @import("containment.zig");
pub const platform = @import("platform.zig");
const std = @import("std");

/// sin esto, todo NTSTATUS que la std considera «inesperado» — como el
/// CONNECTION_RESET que el `shutdown` de la cancelación H5 provoca en el `recv`
/// del huérfano — imprime una traza completa en el stderr COMPARTIDO del
/// binario de tests. El runner de Zig adjudica ese stderr al test que esté
/// corriendo cuando llega (y a veces cuelga un `failed command` de un paso que
/// pasó), que es exactamente el mecanismo con el que la suite «fallaba al azar»
/// tumbando un test distinto cada vez (visto dos veces el 15-08 y 1 de cada 4
/// el 14-08).
///
/// El error SE PROPAGA igual (`error.Unexpected`): lo que se apaga es sólo la
/// traza en Debug, no la señal. Los huérfanos siguen desenrollando por su
/// camino normal y los tests de H5 siguen afirmando los hechos deterministas
/// (buzón marcado, hilo recogido). Lo que se pierde es el ruido que hacía
/// incalificable al instrumento.
pub const std_options: std.Options = .{
    .unexpected_error_tracing = false,
};

/// Versión real del producto DevAgents. Única fuente de verdad:
/// la DLL (`da_core_version`), el motor hijo (`engine_process`), el cliente MCP,
/// el servidor MCP propio ("devagents-mcp"; hasta el 10-nov, "beats-mcp") y el cliente ACP publican ESTA constante
/// en vez de repetir un literal.
pub const private_data = @import("private_data.zig");

pub const VERSION = "0.1.0";
pub const browser_tools = @import("browser_tools.zig");
pub const web_tools = @import("web_tools.zig");
pub const browser_service = @import("browser_service.zig");

/// Agent runtime module.
pub const agent = @import("agent.zig");

/// Message bus module.
pub const bus = @import("bus.zig");

/// Task scheduler module.
pub const scheduler = @import("scheduler.zig");

/// Synchronization primitives.
pub const sync = @import("sync.zig");

/// Database layer (SQLite embebido).
pub const db = @import("db.zig");
pub const issues = @import("issues.zig");

/// DPAPI encryption (Windows).
pub const dpapi = @import("dpapi.zig");

/// Credential manager (N keys, DPAPI, rotation, accounting).
pub const credentials = @import("credentials.zig");

/// Rutas canónicas de las bases (FIRE-04): que el CLI y la cabina miren el MISMO
/// archivo, en vez de que cada uno cree el suyo junto a su directorio de trabajo.
pub const paths = @import("paths.zig");

/// Model catalog (dynamic discovery, metadata, refresh).
pub const model_catalog = @import("model_catalog.zig");

/// Model router (task taxonomy, scoring, fallback, feedback).
pub const model_router = @import("model_router.zig");

/// Sandbox de FS por worker (lista blanca de rutas).
pub const sandbox = @import("sandbox.zig");

/// Validación de contratos de integración.
pub const contracts = @import("contracts.zig");

/// Native MCP client over stdio.
pub const mcp_client = @import("mcp_client.zig");

/// Open Design MCP integration (OD-MCP-01).
pub const od_mcp = @import("od_mcp.zig");

/// Tool discovery scanner and selection backend.
pub const tool_discovery = @import("tool_discovery.zig");

/// Planificador del superagente (backend mock determinista + interfaz LLM).
pub const planner = @import("planner.zig");

/// Planificador en vivo (LLM con fallback honesto a MockPlanner) — el bench
/// de E5.16 lo conduce directamente para medir el efecto del repo-map.
pub const llm_planner = @import("llm_planner.zig");
pub const direct_mode = @import("direct_mode.zig");
/// H7: edicion por bloques tolerante a la deriva del archivo.
pub const drift_edit = @import("drift_edit.zig");

/// Superagente: loop de orquestación piramidal (orden → plan → despacho → reporte).
pub const superagent = @import("superagent.zig");

/// Clasificador de errores de providers → estados de salud (tests E3.23).
pub const health = @import("health.zig");

/// Definiciones de agentes departamentales (markdown + frontmatter).
pub const agent_def = @import("agent_def.zig");

/// Backend de workers (nativo + mock) para ejecutar tareas con LLM + sandbox.
pub const worker_backend = @import("worker_backend.zig");

pub const live_worker = @import("live_worker.zig");

/// Pipeline anti-falso-verde + deriveStatus del audit_ledger.
pub const audit_pipeline = @import("audit_pipeline.zig");
pub const audit_citas = @import("audit_citas.zig");

/// Pipeline de calidad orquestado: generar→validar→auditar(≠modelo)→corregir→re-validar.
pub const quality_pipeline = @import("quality_pipeline.zig");

/// Worker CLI externo: proceso hijo supervisado (patrón StdioTransport).
pub const cli_worker = @import("cli_worker.zig");

/// Cliente ACP v1 (E5.06 /): JSON-RPC sobre stdio de un agente externo,
/// con fs/* confinado al worktree, permisos por seam y cancelación de orden.
pub const acp_client = @import("acp_client.zig");

/// Adaptadores headless (E5.07 / D-C2): perfiles verificados de claude/codex/
/// gemini/opencode sobre ExternalCliWorker — cwd=worktree, streaming→eventos,
/// transcripción acotada+censurada y artefactos del diff validados por sandbox.
pub const headless_adapter = @import("headless_adapter.zig");
pub const external_agents = @import("external_agents.zig");

/// Repo-map (E5.13 / D-C3): símbolos por lenguaje (Ast en Zig, léxico en el
/// resto), grafo de referencias, PageRank personalizado por la orden y caché
/// por (raíz, HEAD, config) en runtime.db.
pub const repo_map = @import("repo_map.zig");
pub const repo_search = @import("repo_search.zig");
pub const repo_embed = @import("repo_embed.zig");
pub const embedder_ctx = @import("embedder_ctx.zig");
pub const plan_fanout = @import("plan_fanout.zig");
pub const best_of_n = @import("best_of_n.zig");

/// CLI de DevAgents.
pub const cli = @import("cli.zig");

/// Pagina de codigos de la consola Windows al arrancar la CLI:
/// fija UTF-8 y restaura la original al salir.
pub const console_cp = @import("console_cp.zig");

/// Driver CLI-JSON universal (BACKLOG-IDE-REMOTE Fase 1).
pub const cli_driver = @import("cli_driver.zig");

/// Engram memory backend (Fase 6).
pub const engram_memory = @import("engram_memory.zig");

/// Local memory fallback persistente (ENGRAM-WIRE-07).
pub const local_memory = @import("local_memory.zig");

/// Revalidador periódico de pricing free/pago (P10-T1).
pub const pricing_revalidator = @import("pricing_revalidator.zig");

/// C API exports (Fase 7 — frontera C pura entre núcleo Zig e IDE C++/Qt).
pub const c_api = @import("c_api.zig");
pub const remote_server = @import("remote_server.zig");
pub const doctor = @import("doctor.zig");
/// Tanda 5 (F0.4): actualizador «avisar y aplicar al cerrar».
pub const updater = @import("updater.zig");

/// Ejecución gobernada de procesos en sandbox (EXEC-01).
pub const executor = @import("executor.zig");
/// T7 (d): el MCP sirve archivos con las MISMAS tools confinadas
/// del agente (read_file, list_dir, grep_files, write_file) sobre la raíz
/// efectiva del proyecto o el worktree de un space.
pub const governed_tool_executor = @import("governed_tool_executor.zig");
pub const workspace = @import("workspace.zig");
/// QA-B 2a: el MCP arma git_status/diff/log con el prefijo domesticado que
/// la política exime (`GIT_SAFE_PREFIX`).
pub const command_policy = @import("command_policy.zig");
/// T7 (e): «Reglas del proyecto» en todos los modos.
pub const project_rules = @import("project_rules.zig");
/// T7 (f): varias cuentas por CLI, aisladas y con rotación.
pub const cli_accounts = @import("cli_accounts.zig");

/// Gate funcional de navegador: abre el entregable web en un navegador real y
/// observa qué hace cada control (BGATE-1, causa raíz de la orden 437).
pub const browser_gate = @import("browser_gate.zig");

/// Presupuesto duro de llamadas de pago: se comprueba ANTES de cada llamada y
/// de cada reintento, en todos los roles (BUDGET-1).
pub const spend_budget = @import("spend_budget.zig");

/// Carpetas vinculadas (mounts). T-F8-01.
pub const mounts = @import("mounts.zig");

/// Adaptador Pixel Enterprise (read-only). T-F8-02.
pub const pixel_adapter = @import("pixel_adapter.zig");

/// Registro unificado de especialistas (nativos + Pixel). PIXEL-DEVTEAM-05.
pub const pixel_registry = @import("pixel_registry.zig");

/// Cargador de plugins C (.dll con manifiesto). T-F8-03.
pub const plugin_loader = @import("plugin_loader.zig");

/// Registro de plugins dinámicos. T-F8-03.
pub const plugin_registry = @import("plugin_registry.zig");

/// Webhooks entrantes. T-F8-04.
pub const webhooks = @import("webhooks.zig");

/// Concurrent queue (thread-safe).
pub const concurrent_queue = @import("concurrent_queue.zig");

/// Almacenamiento de sesiones.
pub const session_store = @import("session_store.zig");

/// Gestor de Spaces y aislamiento por worktrees.
pub const spaces = @import("spaces.zig");
/// E5.04/preparación del worktree (.devagents/worktree.json).
pub const worktree_prepare = @import("worktree_prepare.zig");

/// D4: el motor fuera del proceso de la cabina (supervisor + hijo por el bus).
pub const engine_process = @import("engine_process.zig");

/// D7: contexto y presupuesto por subagente (a quién ve cada rama del fanout).
pub const subagent = @import("subagent.zig");

/// Poller de GitHub de fondo no bloqueante.
pub const github_poller = @import("github_poller.zig");

/// Keep-awake system reliability (SetThreadExecutionState).
pub const sys_keep_awake = @import("sys_keep_awake.zig");

/// Telemetría anónima opt-in y feedback de sistema. T-F9-07.
pub const telemetry = @import("telemetry.zig");

/// estado de avance escrito por el agente por orden (CAS por
/// secuencia para descartar reportes viejos y regla de no pisar al humano).
pub const order_progress = @import("order_progress.zig");

/// Returns a greeting string for the core runtime.
pub fn greeting() []const u8 {
    return "DevAgents core runtime";
}

test "core greeting is non-empty" {
    const msg = greeting();
    try std.testing.expect(msg.len > 0);
}

test "core version is set" {
    try std.testing.expect(VERSION.len > 0);
}

// el producto declaraba dos versiones (la DLL devolvia "0.1.0" y el
// motor hijo publicaba "0.0.0-foundation"). La version real es "0.1.0" y vive
// en un solo sitio: esta constante. Contrato: la DLL (`da_core_version`), el
// motor hijo (`engine_process`), el cliente MCP, el servidor MCP propio y el
// cliente ACP publican TODOS esta misma constante.
test "CK-MOT-020: la version del producto es una sola y vale 0.1.0" {
    try std.testing.expectEqualStrings("0.1.0", VERSION);
    try std.testing.expectEqualStrings(VERSION, std.mem.span(c_api.da_core_version()));
    // Otro punto que publica la version del producto: el cliente ACP.
    try std.testing.expectEqualStrings(VERSION, acp_client.CLIENT_VERSION);
}

test {
    _ = @import("direct_mode.zig");
    _ = @import("browser_service.zig");
    _ = @import("browser_tools.zig");
    _ = @import("app_server.zig");
    _ = @import("web_tools.zig");
    _ = @import("agent.zig");
    _ = @import("bus.zig");
    _ = @import("bus/protocol.zig");
    _ = @import("bus/named_pipe.zig");
    _ = @import("scheduler.zig");
    _ = @import("sync.zig");
    _ = @import("db.zig");
    _ = @import("review_notes.zig");
    _ = @import("issues.zig");
    _ = @import("health.zig");
    _ = @import("dpapi.zig");
    _ = @import("credentials.zig");
    _ = @import("model_catalog.zig");
    _ = @import("model_router.zig");
    _ = @import("concurrent_queue.zig");
    _ = @import("cli.zig");
    _ = @import("console_cp.zig");
    // E1: sesión interactiva de la CLI (estado, render, teclas,
    // consola, backend y bucle con puertos probados con dobles).
    _ = @import("tui/state.zig");
    _ = @import("tui/keys.zig");
    _ = @import("tui/render.zig");
    _ = @import("tui/console.zig");
    _ = @import("tui/host.zig");
    _ = @import("tui/session.zig");
    _ = @import("tui/interaction.zig");
    _ = @import("tui/progress.zig");
    _ = @import("order_trace.zig");
    // estado de avance por orden, con CAS por secuencia y regla humana.
    _ = @import("order_progress.zig");
    _ = @import("debug_dump.zig");
    _ = @import("cli_driver.zig");
    _ = @import("engram_memory.zig");
    _ = @import("local_memory.zig");
    _ = @import("live_worker.zig");
    _ = @import("retry_planner.zig");
    _ = @import("ship_flow.zig");
    _ = @import("connector_v2_bridge_test.zig");
    _ = @import("native_http_test.zig");
    _ = @import("governed_tool_executor.zig");
    _ = @import("project_rules.zig");
    _ = @import("cli_accounts.zig");
    _ = @import("sandbox.zig");
    _ = @import("contracts.zig");
    _ = @import("mcp_client.zig");
    _ = @import("od_mcp.zig");
    _ = @import("tool_discovery.zig");
    _ = @import("planner.zig");
    _ = @import("llm_planner.zig");
    _ = @import("superagent.zig");
    _ = @import("agent_def.zig");
    _ = @import("worker_backend.zig");
    _ = @import("artifact_parser.zig");
    _ = @import("workspace.zig");
    _ = @import("drift_edit.zig");
    _ = @import("audit_pipeline.zig");
    _ = @import("audit_citas.zig");
    _ = @import("quality_pipeline.zig");
    _ = @import("cli_worker.zig");
    _ = @import("acp_client.zig");
    _ = @import("headless_adapter.zig");
    _ = @import("external_session.zig");
    _ = @import("external_context.zig");
    _ = @import("wal_guard.zig");
    _ = @import("external_agents.zig");
    _ = @import("external_registry.zig");
    _ = @import("cli_quota.zig");
    _ = @import("repo_map.zig");
    _ = @import("repo_search.zig");
    _ = @import("repo_embed.zig");
    _ = @import("embedder_ctx.zig");
    _ = @import("plan_fanout.zig");
    _ = @import("best_of_n.zig");
    _ = @import("delegation.zig");
    _ = @import("c_api.zig");
    _ = @import("executor.zig");
    _ = @import("containment.zig");
    _ = @import("platform.zig");
    _ = @import("posix_keys.zig");
    _ = @import("confined_posix.zig");
    _ = @import("private_data.zig");
    _ = @import("paths.zig");
    _ = @import("browser_gate.zig");
    _ = @import("spend_budget.zig");
    _ = @import("mounts.zig");
    _ = @import("pixel_adapter.zig");
    _ = @import("pixel_registry.zig");
    _ = @import("plugin_loader.zig");
    _ = @import("plugin_registry.zig");
    _ = @import("webhooks.zig");
    _ = @import("session_store.zig");
    _ = @import("pricing_revalidator.zig");
    _ = @import("spaces.zig");
    _ = @import("worktree_prepare.zig");
    _ = @import("subagent.zig");
    _ = @import("engine_process.zig");
    _ = @import("remote_server.zig");
    _ = @import("doctor.zig");
    _ = @import("updater.zig");
    _ = @import("github_poller.zig");
    _ = @import("sys_keep_awake.zig");
    _ = @import("telemetry.zig");
}
