const std = @import("std");
const planner = @import("planner.zig");
const sandbox = @import("sandbox.zig");
const confined_fs = @import("confined_fs.zig");
const artifact_quality = @import("artifact_quality.zig");
const cli_worker = @import("cli_worker.zig");
const worker_backend = @import("worker_backend.zig");
const debug_dump = @import("debug_dump.zig");
const providers = @import("providers");
const gh = providers.github;
const external_session = @import("external_session.zig");
const project_rules = @import("project_rules.zig");
const external_context = @import("external_context.zig");

// E5.07 / D-C2 / ADR-B013 D3: adaptadores sin interfaz sobre ExternalCliWorker.
//
// Un perfil de datos por CLI — TODO sale del --help verificado en la evidencia
// E5.01 (E5.01-clis-ayuda-20260923-0415.txt y E5.01-clis-subcomandos-…-0415.txt;
// versiones: claude 2.1.221, codex 0.144.4, gemini 0.53.1, opencode 1.18.25).
// Ninguna flag se inventa: si no estaba en el --help capturado, no está aquí.
//
//   claude-code  claude -p --output-format stream-json --verbose --allowedTools …  < stdin
//                (-p/--print no interactivo; --output-format stream-json;
//                --verbose OBLIGATORIO con -p + stream-json — sin él claude sale
//                con código 1 («--output-format=stream-json requires --verbose»,
//                medido en vivo 18-oct; la flag está en el --help capturado en
//                E5.55-inventory-native-20261001-235524.txt:275);
//                --allowedTools lista por comas según el modo (CLAUDE_TOOLS_*):
//                Manual/Aceptar ediciones sin Bash ni red; Auto con Bash y subagentes;
//                --bare NO se usa: fuerza auth por API key y rompe la suscripción
//                OAuth — el aviso de facturación cubre ese caso)
//   codex        codex exec --json -C <wt> -s workspace-write -c approval_policy="never" < stdin
//                (workspace-write = lo más restrictivo que permite editar el cwd;
//                never = nunca pide aprobación en headless; prompt posicional o stdin)
//   gemini-cli   gemini --approval-mode auto_edit|yolo -o stream-json < stdin
//                (Manual/Aceptar ediciones: auto_edit, los comandos siguen pidiendo
//                aprobación → denegados en headless; Auto: yolo, también comandos)
//   opencode     opencode run --format json --pure --auto --dir <wt> < stdin
//                (--format json = eventos JSON en bruto; --auto es el único modo
//                headless que permite editar — la gobernanza la pone DevAgents)
//
// Contrato: cwd = worktree; Codex retira las claves API del entorno del hijo,
// los demás perfiles lo heredan con aviso E5.01; streaming → eventos,
// transcripción acotada y censurada (patrones + valores exactos de las
// variables presentes), artefactos = diff del worktree frente al commit base
// registrado al despachar, validados por el sandbox; lo que el agente dice
// haber hecho va como «declaración del agente», nunca como artefacto.

const GetEnvironmentVariableA = @import("platform.zig").env;

/// Canal por el que el CLI recibe el prompt (todo verificado en --help E5.01).
pub const PromptChannel = enum {
    /// Último argumento posicional (claude -p, codex exec, opencode run).
    argv_tail,
    /// El prompt es el valor de un flag (gemini -p).
    argv_flag,
    /// El prompt va por stdin como texto (los cuatro CLIs lo aceptan; útil
    /// cuando el prompt podría superar el límite de línea de comandos).
    stdin_text,
};

/// Cómo hay que interpretar stdout del CLI.
pub const OutputMode = enum {
    /// Texto plano formateado (codex exec sin flag --json verificado).
    text,
    /// Un objeto JSON por línea (claude/gemini stream-json, opencode --format json).
    stream_json_lines,
};

pub const CliProfile = struct {
    /// Identificador estable para pines/enjambre (`agent:<id>`, formato model_router).
    id: []const u8,
    exe: []const u8,
    /// Argumentos fijos verificados en el --help de E5.01 (sin prompt ni cwd).
    argv_prefix: []const []const u8,
    /// Flag que además recibe el worktree (codex -C, opencode --dir); null = el
    /// cwd del spawn basta.
    cwd_flag: ?[]const u8 = null,
    /// Flag cuyo valor es el prompt (solo con prompt_channel=.argv_flag).
    prompt_flag: ?[]const u8 = null,
    prompt_channel: PromptChannel,
    output_mode: OutputMode,
    /// Modo de permisos más restrictivo que permite editar en el cwd (texto
    /// para ledger y para la tabla de aislamiento de E5.08).
    permission_note: []const u8,
    /// Cómo se acotan los turnos en esta versión del CLI.
    turn_cap_note: []const u8,
    model: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    resume_session: ?[]const u8 = null,
    /// capabilities stay inherited; personal context is opt-in.
    inherit_personal_context: bool = false,
    /// Ver `external_agents.RunRequest.deny_shell`.
    deny_shell: bool = false,
    /// QA-B H7: ver `external_agents.RunRequest.read_only`.
    read_only: bool = false,
    context_settings: ?[]const u8 = null,
};

pub const CLAUDE_CODE = CliProfile{
    .id = "claude-code",
    .exe = "claude",
    // Lista por comas: un solo argv. El prompt va por stdin para que nunca
    // se interprete como sintaxis de cmd ni quede expuesto en el proceso.
    // --verbose es obligatorio con -p + --output-format stream-json: sin él
    // claude 2.1.114 sale con código 1 sin responder (medido en vivo 18-oct).
    // `--allowedTools` lo añade buildArgv según el modo (CLAUDE_TOOLS_*).
    .argv_prefix = &.{ "-p", "--output-format", "stream-json", "--verbose" },
    .prompt_channel = .stdin_text,
    .output_mode = .stream_json_lines,
    .permission_note = "--allowedTools: Manual y Aceptar ediciones, edición y lectura sin Bash ni red; Auto, además Bash y subagentes; el resto queda denegado en -p",
    .turn_cap_note = "claude 2.1.221 no expone --max-turns en --help; tope externo de reloj/turnos (E5.08) y tope opcional --max-budget-usd",
};

pub const CODEX = CliProfile{
    .id = "codex",
    .exe = "codex",
    // codex 0.144.4 retiró `-a/--ask-for-approval` de `exec` (error: unexpected
    // argument). En su lugar `-c approval_policy="never"` evita que los
    // apply_patch se rechacen como "user approval settings" en no-interactivo.
    // E5.55: buildArgv pasa el modelo del pin; la detección fija el binario
    // que lo enumeró. Sin pin se conserva el modelo por defecto del CLI.
    // NO usar --ignore-user-config: en
    // Windows la config del usuario activa el sandbox "elevated" sin el cual
    // workspace-write degrada a solo-lectura. conserva la sesión:
    // --json captura thread_id; --ephemeral impediría reanudar tras una caída.
    .argv_prefix = &.{ "exec", "-s", "workspace-write", "-c", "approval_policy=\"never\"", "--json", "--skip-git-repo-check", "-c", @import("external_cli_policy.zig").CODEX_LOGIN_CONFIG },
    .cwd_flag = "-C",
    // El prompt viaja por stdin, no por argv: con el prompt posicional el
    // modelo contestaba como chat ("indícame la tarea") aunque el argv
    // llevaba el texto completo — medido en vivo (órdenes 766-769).
    .prompt_channel = .stdin_text,
    .output_mode = .stream_json_lines,
    .permission_note = "-s workspace-write: escritura confinada al workspace; exec es no-interactivo (nunca pide aprobación)",
    .turn_cap_note = "codex exec no expone flag de turnos; tope externo de reloj/turnos (E5.08)",
};

pub const GEMINI_CLI = CliProfile{
    .id = "gemini-cli",
    .exe = "gemini",
    // `--approval-mode` lo añade buildArgv según el modo (auto_edit o yolo).
    .argv_prefix = &.{ "-o", "stream-json" },
    // La entrada por pipe activa el modo no interactivo; -p exige un valor
    // argv y devolvería el prompt al intérprete del shim.
    .prompt_channel = .stdin_text,
    .output_mode = .stream_json_lines,
    .permission_note = "--approval-mode: Manual y Aceptar ediciones, auto_edit (edición auto-aprobada, comandos denegados en headless); Auto, yolo (también comandos)",
    .turn_cap_note = "gemini no expone flag de turnos; tope externo de reloj/turnos (E5.08)",
};

pub const OPENCODE = CliProfile{
    .id = "opencode",
    .exe = "opencode",
    .argv_prefix = &.{ "run", "--format", "json", "--pure", "--auto" },
    .cwd_flag = "--dir",
    .prompt_channel = .stdin_text,
    .output_mode = .stream_json_lines,
    .permission_note = "--auto: auto-aprueba permisos no denegados explícitamente — el único modo headless que permite editar; el confinamiento lo ponen worktree + sandbox + diff",
    .turn_cap_note = "opencode run no expone flag de turnos; tope externo de reloj/turnos (E5.08)",
};

pub const PROFILES = [_]CliProfile{ CLAUDE_CODE, CODEX, GEMINI_CLI, OPENCODE };

/// Tanda 2 de la salida (decisión del propietario del 12-nov): Claude Code y Gemini
/// reciben comandos en el modo que los permite, como Codex y OpenCode. Con
/// Manual o Aceptar ediciones (`deny_shell`) un CLI sin interfaz no puede
/// preguntar, así que edita y lee pero no ejecuta; con Auto, también ejecuta
/// y delega en sus subagentes (`Task`, y `Agent` en las versiones que lo
/// renombraron). Nombres de herramienta del --help de claude 2.1.283.
pub const CLAUDE_TOOLS_EDIT = "Edit,Write,Read,Glob,Grep";
/// QA-B H7: planificar solo lee el proyecto.
pub const CLAUDE_TOOLS_READ = "Read,Glob,Grep";
/// T12 A2: lo que se deniega explícitamente al planificar con Claude Code.
pub const CLAUDE_TOOLS_DENIED_READ_ONLY = "Edit,Write,MultiEdit,NotebookEdit,Bash,WebFetch";
pub const CLAUDE_TOOLS_AUTO = "Edit,Write,Read,Glob,Grep,Bash,Task,Agent,TodoWrite";

pub fn profileById(id: []const u8) ?CliProfile {
    for (PROFILES) |p| {
        if (std.mem.eql(u8, p.id, id)) return p;
    }
    return null;
}

/// Variables de facturación por API sondeadas en E5.01 (presencia, nunca valor).
/// Si alguna está presente se emite el aviso: la corrida puede facturar por API
/// en vez de usar la suscripción del usuario.
pub const BILLING_ENV_VARS = @import("external_cli_policy.zig").BILLING_ENV_VARS;

/// Seam de entorno para pruebas: null = ausente/vacía. Producción usa
/// GetEnvironmentVariableA (Win32) vía `defaultGetEnv`.
pub const GetEnvFn = *const fn (allocator: std.mem.Allocator, name: []const u8) anyerror!?[]u8;

pub fn defaultGetEnv(allocator: std.mem.Allocator, name: []const u8) anyerror!?[]u8 {
    const name_z = try allocator.dupeZ(u8, name);
    defer allocator.free(name_z);
    var buf: [4096:0]u8 = undefined;
    const n = GetEnvironmentVariableA(name_z, &buf, @intCast(buf.len));
    if (n == 0 or n >= buf.len) return null;
    const v = std.mem.trim(u8, buf[0..n], " \t\r\n");
    if (v.len == 0) return null;
    return try allocator.dupe(u8, v);
}

/// Seam de subprocesos git (misma forma que GitHubConnector.capture_fn).
pub const CaptureFn = *const fn (allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) anyerror!gh.CmdCapture;

/// D-C1: pública — el modo agéntico nativo (superagent.runAgenticTask) usa la
/// misma captura git con guardia que el adaptador headless.
pub fn defaultCapture(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) anyerror!gh.CmdCapture {
    // GIT_GUARD_ENV: git nunca abre diálogo de credenciales en un worktree
    // headless — sin credencial falla rápido y honesto.
    return gh.runCmdCaptureWin32Input(allocator, argv, cwd, null, gh.GIT_GUARD_ENV);
}

/// Construye el argv completo del CLI: exe + flags verificados + cwd_flag +
/// prompt por su canal. Las entradas son prestadas; solo el slice es owned.
pub fn buildArgv(allocator: std.mem.Allocator, profile: CliProfile, worktree: []const u8, prompt: []const u8) ![][]const u8 {
    var argv = std.ArrayList([]const u8).empty;
    errdefer argv.deinit(allocator);
    try argv.append(allocator, profile.exe);
    // gemini 0.53.1: --approval-mode default|auto_edit|yolo|plan.
    if (std.mem.eql(u8, profile.id, GEMINI_CLI.id))
        // T12 A2: planificar usa el modo `plan` de Gemini (solo lectura), no
        // `default`, que depende de lo que el proyecto declare permitido.
        try argv.appendSlice(allocator, &.{ "--approval-mode", if (profile.read_only) "plan" else if (profile.deny_shell) "auto_edit" else "yolo" });
    for (profile.argv_prefix) |a| {
        // QA-B H7: Codex planifica con su sandbox de solo lectura.
        const read_only_sandbox = profile.read_only and std.mem.eql(u8, profile.id, CODEX.id) and std.mem.eql(u8, a, "workspace-write");
        try argv.append(allocator, if (read_only_sandbox) "read-only" else a);
    }
    if (std.mem.eql(u8, profile.id, CLAUDE_CODE.id)) {
        // T12 A2: `--allowedTools` solo concede sin preguntar; no quita nada y
        // un .claude/settings.json del proyecto podría ampliar permisos. Para
        // planificar: modo `plan` (solo lectura de Claude Code) y denegación
        // explícita en línea de órdenes, que ninguna regla «allow» de archivo
        // reabre (las denegaciones ganan a cualquier permiso).
        if (profile.read_only) try argv.appendSlice(allocator, &.{ "--permission-mode", "plan", "--disallowedTools", CLAUDE_TOOLS_DENIED_READ_ONLY });
        try argv.appendSlice(allocator, &.{ "--allowedTools", if (profile.read_only) CLAUDE_TOOLS_READ else if (profile.deny_shell) CLAUDE_TOOLS_EDIT else CLAUDE_TOOLS_AUTO });
    }
    if (!profile.inherit_personal_context) {
        if (std.mem.eql(u8, profile.id, "claude-code")) {
            if (profile.context_settings) |settings| try argv.appendSlice(allocator, &.{ "--settings", settings });
        } else if (std.mem.eql(u8, profile.id, "codex")) {
            try external_context.appendCodexArgs(allocator, &argv, false);
        }
    }
    // QA primerizo (11-nov): Manual/Aceptar ediciones también para Codex. En
    // 0.164 la terminal son dos herramientas (`shell_tool` y `unified_exec`,
    // `codex features list`); apagadas, Codex edita con apply_patch pero no
    // ejecuta comandos. Comprobado contra la lista de la CLI instalada, no en
    // vivo (cada prueba consume la suscripción del usuario).
    if (profile.deny_shell and std.mem.eql(u8, profile.id, "codex"))
        try argv.appendSlice(allocator, &.{ "--disable", "shell_tool", "--disable", "unified_exec" });
    if (profile.model) |m| {
        if (!std.mem.eql(u8, m, profile.id) and !std.mem.eql(u8, m, "default")) {
            try argv.append(allocator, if (std.mem.eql(u8, profile.id, "codex") or std.mem.eql(u8, profile.id, "gemini-cli")) "-m" else "--model");
            try argv.append(allocator, m);
        }
    }
    if (profile.reasoning_effort) |effort| {
        if (std.mem.eql(u8, profile.id, "codex")) {
            try argv.append(allocator, "-c");
            // Value validated upstream; owned string is supplied by runHeadless.
            try argv.append(allocator, effort);
        } else if (std.mem.eql(u8, profile.id, "claude-code")) {
            try argv.append(allocator, "--effort");
            try argv.append(allocator, effort);
        }
    }
    if (profile.cwd_flag) |f| {
        try argv.append(allocator, f);
        try argv.append(allocator, worktree);
    }
    if (profile.resume_session) |id| {
        if (!external_session.validId(id)) return error.InvalidSessionId;
        // E5.55 inventory: Claude --resume (:225), Codex exec resume
        // (E5.01 subcommands :70), OpenCode run --session (:1069).
        const flag: []const u8 = if (std.mem.eql(u8, profile.id, "claude-code")) "--resume" else if (std.mem.eql(u8, profile.id, "codex")) "resume" else if (std.mem.eql(u8, profile.id, "opencode")) "--session" else return error.SessionResumeUnsupported;
        try argv.append(allocator, flag);
        try argv.append(allocator, id);
    }
    switch (profile.prompt_channel) {
        .argv_tail => try argv.append(allocator, prompt),
        .argv_flag => {
            try argv.append(allocator, profile.prompt_flag.?);
            try argv.append(allocator, prompt);
        },
        .stdin_text => {},
    }
    return argv.toOwnedSlice(allocator);
}

/// Aviso E5.01: una entrada por cada variable de facturación por API presente.
/// Los textos nombran la variable, jamás su valor.
pub fn billingEnvWarnings(allocator: std.mem.Allocator, getenv: GetEnvFn) !std.ArrayList([]u8) {
    return billingWarnings(allocator, getenv, null);
}

fn billingWarnings(allocator: std.mem.Allocator, getenv: GetEnvFn, env: ?*const std.process.Environ.Map) !std.ArrayList([]u8) {
    var warns = std.ArrayList([]u8).empty;
    errdefer {
        for (warns.items) |w| allocator.free(w);
        warns.deinit(allocator);
    }
    for (BILLING_ENV_VARS) |name| {
        const present = if (env) |map| blk: {
            const value = map.get(name) orelse break :blk false;
            break :blk value.len > 0;
        } else blk: {
            // El aviso es informativo; la guardia de facturación es separada.
            const value = (getenv(allocator, name) catch null) orelse break :blk false;
            defer allocator.free(value);
            break :blk true;
        };
        if (present) {
            const w = try std.fmt.allocPrint(allocator, "variable de facturacion por API presente: {s} — la corrida puede facturar por API en vez de usar la suscripcion (aviso E5.01)", .{name});
            try warns.append(allocator, w);
        }
    }
    return warns;
}

/// Tipos de evento DevAgents a los que se mapea el streaming del CLI.
pub const EventKind = enum { content, reasoning, tool, plan, status, result, warning, raw };

pub const HeadlessEvent = struct {
    kind: EventKind,
    /// owned por el evento (liberar con deinit).
    text: []u8,

    pub fn deinit(self: HeadlessEvent, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

/// Receptor de eventos del streaming. `text` solo es válida durante la llamada.
pub const EventSink = struct {
    ctx: *anyopaque,
    callFn: *const fn (ctx: *anyopaque, kind: EventKind, text: []const u8) void,

    pub fn call(self: EventSink, kind: EventKind, text: []const u8) void {
        self.callFn(self.ctx, kind, text);
    }
};

fn classifyType(t: []const u8) EventKind {
    // rate_limit_event (claude 2.1.114 con --verbose, medido en la orden #891)
    // es un evento no textual: nunca debe llegar como contenido ni veredicto.
    if (std.mem.indexOf(u8, t, "rate_limit") != null) return .status;
    if (std.mem.indexOf(u8, t, "result") != null) return .result;
    if (std.mem.indexOf(u8, t, "error") != null) return .warning;
    if (std.mem.indexOf(u8, t, "tool") != null) return .tool;
    if (std.mem.indexOf(u8, t, "plan") != null) return .plan;
    if (std.mem.indexOf(u8, t, "think") != null or std.mem.indexOf(u8, t, "reason") != null) return .reasoning;
    if (std.mem.indexOf(u8, t, "system") != null or std.mem.indexOf(u8, t, "init") != null) return .status;
    return .content;
}

/// Extrae texto legible de un evento JSON del CLI probando las formas conocidas
/// (claude/gemini/opencode): message.content[]text, content, delta.text,
/// part.text, result, text.
fn extractJsonText(allocator: std.mem.Allocator, obj: std.json.ObjectMap) !?[]u8 {
    // Codex exec --json: only the assistant message is user-facing content.
    if (obj.get("item")) |item| if (item == .object) {
        const ty = item.object.get("type");
        const text_value = item.object.get("text");
        if (ty != null and ty.? == .string and std.mem.eql(u8, ty.?.string, "agent_message") and text_value != null and text_value.? == .string)
            return try allocator.dupe(u8, text_value.?.string);
    };
    if (obj.get("message")) |m| {
        if (m == .object) {
            if (m.object.get("content")) |c| {
                if (c == .array) {
                    var out = std.ArrayList(u8).empty;
                    errdefer out.deinit(allocator);
                    for (c.array.items) |block| {
                        if (block == .object) {
                            if (block.object.get("text")) |t| {
                                if (t == .string) try out.appendSlice(allocator, t.string);
                            }
                        }
                    }
                    if (out.items.len > 0) return try out.toOwnedSlice(allocator);
                    out.deinit(allocator);
                }
                if (c == .string) return try allocator.dupe(u8, c.string);
            }
        }
        if (m == .string) return try allocator.dupe(u8, m.string);
    }
    inline for (.{ "content", "result", "text" }) |field| {
        if (obj.get(field)) |v| {
            if (v == .string and v.string.len > 0) return try allocator.dupe(u8, v.string);
        }
    }
    inline for (.{ "delta", "part" }) |field| {
        if (obj.get(field)) |v| {
            if (v == .object) {
                if (v.object.get("text")) |t| {
                    if (t == .string and t.string.len > 0) return try allocator.dupe(u8, t.string);
                }
            }
        }
    }
    return null;
}

/// Mapea una línea de stdout a un evento DevAgents. null = línea vacía.
/// Una línea no-JSON en modo stream_json se conserva como evento `raw` — la
/// salida del agente es dato no confiable y nunca rompe el parseo. Un objeto
/// JSON sin texto legible (tool_use sin texto, user/tool_result,
/// rate_limit_event, system distinto de init…) se clasifica aparte —nunca como
/// contenido— y JAMÁS conserva el JSON crudo como texto (r5).
pub fn mapLineToEvent(allocator: std.mem.Allocator, mode: OutputMode, line: []const u8) !?HeadlessEvent {
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return null;

    if (mode == .text) {
        return HeadlessEvent{ .kind = .content, .text = try allocator.dupe(u8, trimmed) };
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{}) catch {
        return HeadlessEvent{ .kind = .raw, .text = try allocator.dupe(u8, trimmed) };
    };
    defer parsed.deinit();
    if (parsed.value != .object) {
        return HeadlessEvent{ .kind = .raw, .text = try allocator.dupe(u8, trimmed) };
    }
    const obj = parsed.value.object;
    const ty: []const u8 = if (obj.get("type")) |t| (if (t == .string) t.string else "") else "";
    const kind = classifyType(ty);
    if (try extractJsonText(allocator, obj)) |text| {
        return HeadlessEvent{ .kind = kind, .text = text };
    }
    // Sin texto legible: un evento posterior al result no puede sustituir la
    // declaración con la línea JSON en bruto (medido en la orden #891).
    return HeadlessEvent{
        .kind = if (kind == .content) .status else kind,
        .text = try allocator.dupe(u8, ""),
    };
}

/// «Declaración del agente»: lo que el CLI dice haber hecho. Para salida
/// stream-json es el texto del ÚLTIMO evento result; solo si no hubo ningún
/// result se usa el último content con texto real (r5: un rate_limit_event o
/// un tool_use posterior no pueden pisar el veredicto). En stream-json la
/// reserva NUNCA vuelca el transcript crudo: sin result ni content con texto
/// la declaración queda vacía (r6: un transcript de solo JSON sin texto, p.
/// ej. system/init + tool_use + rate_limit_event, no da JSON como declaración).
/// Para texto plano, la cola de la transcripción — hasta 4 KiB empezando en un
/// límite de línea. NUNCA es un artefacto.
pub fn extractDeclaration(allocator: std.mem.Allocator, mode: OutputMode, transcript: []const u8) ![]u8 {
    if (mode == .stream_json_lines) {
        var last_result: ?[]u8 = null;
        var last_content: ?[]u8 = null;
        defer {
            if (last_result) |l| allocator.free(l);
            if (last_content) |l| allocator.free(l);
        }
        var it = std.mem.splitScalar(u8, transcript, '\n');
        while (it.next()) |raw| {
            const line = std.mem.trim(u8, raw, " \t\r");
            if (line.len == 0) continue;
            const maybe_ev = mapLineToEvent(allocator, .stream_json_lines, line) catch continue;
            if (maybe_ev) |ev| {
                defer ev.deinit(allocator);
                if (ev.text.len == 0) continue;
                if (ev.kind != .result and ev.kind != .content) continue;
                const copy = try allocator.dupe(u8, ev.text);
                if (ev.kind == .result) {
                    if (last_result) |l| allocator.free(l);
                    last_result = copy;
                } else {
                    if (last_content) |l| allocator.free(l);
                    last_content = copy;
                }
            }
        }
        if (last_result) |l| return try allocator.dupe(u8, l);
        if (last_content) |l| return try allocator.dupe(u8, l);
        // r6 (caso límite de la auditoría r5): la reserva de texto plano
        // devolvería la cola del transcript, que en stream-json es JSON crudo
        // cuando solo hubo eventos sin texto. Declaración vacía, no JSON.
        return try allocator.dupe(u8, "");
    }
    const cap: usize = 4096;
    var start: usize = if (transcript.len > cap) transcript.len - cap else 0;
    if (start > 0) {
        if (std.mem.indexOfScalarPos(u8, transcript, start, '\n')) |nl| start = nl + 1;
    }
    return try allocator.dupe(u8, std.mem.trim(u8, transcript[start..], " \t\r\n"));
}

/// Censura de la transcripción: patrones de token (headers, Bearer, campos
/// api_key — debug_dump.redactBytes) y luego el VALOR EXACTO de cada variable
/// de facturación presente (un eco del CLI quedaría en claro sin esta pasada).
pub fn censorTranscript(allocator: std.mem.Allocator, raw: []const u8, getenv: GetEnvFn) ![]u8 {
    var out = try debug_dump.redactBytes(allocator, raw);
    errdefer allocator.free(out);
    for (BILLING_ENV_VARS) |name| {
        const val = getenv(allocator, name) catch null;
        if (val) |v| {
            defer allocator.free(v);
            const masked = try debug_dump.redactExact(allocator, out, v);
            allocator.free(out);
            out = masked;
        }
    }
    return out;
}

// Preserve OS errors; the per-run context carries stage and relative path.
pub const AdapterError = anyerror;

/// git sólo es fuente de artefactos si su raíz canónica ES el espacio.
/// La raíz elegida no admite reparse points, tampoco en sus ancestros.
pub fn gitRootMatches(allocator: std.mem.Allocator, capture: CaptureFn, worktree: []const u8) AdapterError!bool {
    var root = try artifactRoot(allocator, worktree);
    defer root.deinit();
    var cap = capture(allocator, &.{ "git", "rev-parse", "--show-toplevel" }, worktree) catch return error.GitFailed;
    defer cap.deinit(allocator);
    if (cap.exit_code != 0) return false;
    const top = std.mem.trim(u8, cap.stdout, " \t\r\n");
    if (top.len == 0) return false;
    const canonical_top = sandbox.canonicalizeExisting(allocator, top) orelse return error.GitFailed;
    defer allocator.free(canonical_top);
    return std.ascii.eqlIgnoreCase(canonical_top, root.canonical);
}

fn appendGitLines(
    allocator: std.mem.Allocator,
    paths: *std.ArrayList([]const u8),
    capture: CaptureFn,
    worktree: []const u8,
    argv: []const []const u8,
) AdapterError!void {
    var cap = capture(allocator, argv, worktree) catch return error.GitFailed;
    defer cap.deinit(allocator);
    if (cap.exit_code != 0) return error.GitFailed;
    var it = std.mem.splitScalar(u8, cap.stdout, 0);
    while (it.next()) |line| {
        if (line.len == 0) continue;
        // E-GOV.2: la caché de compilación de Go no es un artefacto cuando aún
        // no está versionada (primer build la crea). La caché rastreada por git
        // sigue contando: solo se filtra la salida de `ls-files`.
        if (argv.len > 1 and std.mem.eql(u8, argv[1], "ls-files") and generatedCachePath(line)) continue;
        if (dependencyArtifactPath(line)) continue;
        if (paths.items.len >= SNAPSHOT_ENTRY_CAP) return error.TooManyFiles;
        const owned = try allocator.dupe(u8, line);
        errdefer allocator.free(owned);
        for (owned) |*c| if (c.* == '/') {
            c.* = '\\';
        };
        try paths.append(allocator, owned);
    }
}

/// Registra el commit base del worktree al despachar (`git rev-parse HEAD`).
pub fn recordBaseCommit(allocator: std.mem.Allocator, capture: CaptureFn, worktree: []const u8) AdapterError![]u8 {
    if (!try gitRootMatches(allocator, capture, worktree)) return error.GitFailed;
    var cap = capture(allocator, &.{ "git", "rev-parse", "HEAD" }, worktree) catch return error.GitFailed;
    defer cap.deinit(allocator);
    if (cap.exit_code != 0) return error.GitFailed;
    const sha = std.mem.trim(u8, cap.stdout, " \t\r\n");
    if (sha.len == 0) return error.GitFailed;
    return try allocator.dupe(u8, sha);
}

/// Cota por artefacto leído del worktree.
pub const ARTIFACT_CONTENT_CAP: usize = 1024 * 1024;
const SNAPSHOT_ENTRY_CAP: usize = 10_000;
const SNAPSHOT_BYTE_CAP: u64 = 256 * 1024 * 1024;

const TreeEntry = struct {
    path: []u8,
    size: u64 = 0,
    mtime: i128 = 0,
    sha256: [32]u8 = @splat(0),
    readable: bool = true,
    metadata_only: bool = false,
    /// E-GOV.1: huellas de las líneas-marcador presentes en la línea base.
    placeholders: []artifact_quality.LineHash = &.{},
};

pub const SnapshotDiagnostic = struct {
    buf: [4608]u8 = undefined,
    len: usize = 0,
    windows_error: u32 = 0,
    /// Raíz canónica e identidad (volumen + FileId) del espacio rechazado por
    /// escritores ajenos. Viajan en el evento de fallo: la reparación explícita
    /// exige que sigan coincidiendo y nunca repara «el espacio actual».
    repair_root_buf: [520]u8 = undefined,
    repair_root_len: usize = 0,
    repair_id_buf: [64]u8 = undefined,
    repair_id_len: usize = 0,

    pub fn message(self: *const SnapshotDiagnostic) []const u8 {
        return self.buf[0..self.len];
    }

    pub fn repairRoot(self: *const SnapshotDiagnostic) ?[]const u8 {
        return if (self.repair_root_len > 0) self.repair_root_buf[0..self.repair_root_len] else null;
    }

    pub fn repairId(self: *const SnapshotDiagnostic) ?[]const u8 {
        return if (self.repair_id_len > 0) self.repair_id_buf[0..self.repair_id_len] else null;
    }

    /// Una raíz o identidad que no cabe deja la reparación sin ofrecer (cierra
    /// en falso): jamás se guarda un valor truncado.
    fn setRepairTarget(self: *SnapshotDiagnostic, root: []const u8, id: []const u8) void {
        self.repair_root_len = 0;
        self.repair_id_len = 0;
        if (root.len == 0 or root.len > self.repair_root_buf.len or id.len == 0 or id.len > self.repair_id_buf.len) return;
        @memcpy(self.repair_root_buf[0..root.len], root);
        @memcpy(self.repair_id_buf[0..id.len], id);
        self.repair_root_len = root.len;
        self.repair_id_len = id.len;
    }
};

fn appendWriterDiagnosis(d: *SnapshotDiagnostic, writers: []const u8) void {
    const prefix = "; escritores=";
    const action = "; accion=workspace_acl_restore (Restaurar permisos del espacio)";
    const truncated = " [lista truncada]";
    const capacity = d.buf.len - d.len - prefix.len - action.len - truncated.len;
    var count = @min(capacity, writers.len);
    if (count < writers.len) while (count > 0 and writers[count] & 0xc0 == 0x80) : (count -= 1) {};
    @memcpy(d.buf[d.len..][0..prefix.len], prefix);
    d.len += prefix.len;
    for (writers[0..count]) |c| {
        d.buf[d.len] = if (c < 32 or c == 127) ' ' else c;
        d.len += 1;
    }
    if (count < writers.len) {
        @memcpy(d.buf[d.len..][0..truncated.len], truncated);
        d.len += truncated.len;
    }
    @memcpy(d.buf[d.len..][0..action.len], action);
    d.len += action.len;
}

pub const SnapshotContext = struct {
    diagnostic: ?*SnapshotDiagnostic = null,
    sink: ?EventSink = null,
    // Deterministic filesystem races, available only in test binaries.
    after_stat: ?*const fn (?*anyopaque, std.Io, std.Io.File, []const u8) anyerror!void = null,
    hook_ctx: ?*anyopaque = null,

    pub fn reportRoot(self: SnapshotContext, a: std.mem.Allocator, root: []const u8, err: anyerror) void {
        var local: SnapshotDiagnostic = .{};
        const d = self.diagnostic orelse &local;
        const quiet: SnapshotContext = .{ .diagnostic = d };
        quiet.report("raiz", ".", err, false);
        if (err == error.CliWritableByOthers) {
            if (@import("workspace_acl.zig").identity(a, root)) |found| {
                var target = found;
                defer target.deinit(a);
                d.setRepairTarget(target.canonical, target.id);
            } else |_| {}
            const writers = @import("workspace_acl.zig").writers(a, root) catch |e| {
                const tail = std.fmt.bufPrint(d.buf[d.len..], "; escritores=no verificables ({s}); accion=workspace_acl_restore (Restaurar permisos del espacio)", .{@errorName(e)}) catch return;
                d.len += tail.len;
                if (self.sink) |sink| sink.call(.warning, d.message());
                return;
            };
            defer a.free(writers);
            appendWriterDiagnosis(d, writers);
        }
        if (self.sink) |sink| sink.call(.warning, d.message());
    }

    pub fn report(self: SnapshotContext, stage: []const u8, path: []const u8, err: anyerror, warning: bool) void {
        var local: SnapshotDiagnostic = .{};
        const d = if (warning) &local else self.diagnostic orelse &local;
        const windows_error = if (self.diagnostic) |diag| diag.windows_error else 0;
        // Scan the complete path before truncation; normalize separators so
        // normal Windows paths remain useful to the shared untrusted scanner.
        var path_buf: [4096]u8 = undefined;
        const normalized = if (path.len <= path_buf.len) blk: {
            for (path, 0..) |c, i| path_buf[i] = if (c == '\\') '/' else c;
            break :blk path_buf[0..path.len];
        } else "[ruta demasiado larga]";
        var excerpt: [200]u8 = undefined;
        const clean_path = @import("providers").external_error.excerpt(&excerpt, normalized, null)["[texto externo] ".len..];
        const msg = std.fmt.bufPrint(&d.buf, "snapshot: {s}; etapa={s}; ruta={s}; error={s}; win32={d}", .{ if (warning) "no legible" else "fallo", stage, clean_path, @errorName(err), if (std.mem.eql(u8, stage, "raiz") or std.mem.eql(u8, stage, "apertura") or std.mem.eql(u8, stage, "restauracion_permisos")) windows_error else 0 }) catch return;
        d.len = msg.len;
        if (self.sink) |sink| sink.call(.warning, msg);
    }
};

fn unreadableError(e: anyerror) bool {
    return e == error.AccessDenied or e == error.PermissionDenied or e == error.SharingViolation or e == error.LockViolation or e == error.FileBusy or e == error.FileNotFound or e == error.SizeChanged or e == error.FileChanged;
}

fn unknownEntry(a: std.mem.Allocator, entries: *std.ArrayList(TreeEntry), path: []const u8) !void {
    const owned = try a.dupe(u8, path);
    errdefer a.free(owned);
    try entries.append(a, .{ .path = owned, .readable = false, .metadata_only = dependencyArtifactPath(path) });
}

fn unknownPath(entries: []const TreeEntry, path: []const u8) bool {
    for (entries) |entry| {
        if (entry.readable) continue;
        if (std.ascii.eqlIgnoreCase(path, entry.path)) return true;
        if (path.len > entry.path.len and std.ascii.eqlIgnoreCase(path[0..entry.path.len], entry.path) and (path[entry.path.len] == '/' or path[entry.path.len] == '\\')) return true;
    }
    return false;
}

/// Una sola línea base para headless, ACP y worker nativo. Sin git propio,
/// la verdad es el árbol del espacio ANTES de que el agente empiece a editar.
pub const ArtifactBaseline = struct {
    canonical_root: []const u8,
    retained_root: confined_fs.Root,
    git_commit: ?[]u8 = null,
    entries: []TreeEntry = &.{},

    pub fn deinit(self: *ArtifactBaseline, allocator: std.mem.Allocator) void {
        self.retained_root.deinit();
        if (self.git_commit) |s| allocator.free(s);
        freeTree(allocator, self.entries);
    }
};

fn freeTree(a: std.mem.Allocator, entries: []TreeEntry) void {
    for (entries) |entry| {
        a.free(entry.path);
        a.free(entry.placeholders);
    }
    a.free(entries);
}

/// E-GOV.2: la caché de disco de Go (`<dir>/.cache/go-build/<2 hex>/<64 hex>-a|d`)
/// no se versiona y no puede consumir la cota de artefactos. Un directorio con
/// ese nombre no basta: se exige la forma exacta de la ruta del archivo.
fn generatedCachePath(path: []const u8) bool {
    var parts = std.mem.tokenizeAny(u8, path, "/\\");
    var previous_cache = false;
    while (parts.next()) |part| {
        if (previous_cache and std.ascii.eqlIgnoreCase(part, "go-build")) {
            const bucket = parts.next() orelse return false;
            const file = parts.next() orelse return false;
            if (parts.next() != null or bucket.len != 2 or file.len != 66 or file[64] != '-' or (file[65] != 'a' and file[65] != 'd')) return false;
            for (bucket) |c| if (!std.ascii.isHex(c)) return false;
            for (file[0..64]) |c| if (!std.ascii.isHex(c)) return false;
            return std.ascii.eqlIgnoreCase(bucket, file[0..2]);
        }
        previous_cache = std.ascii.eqlIgnoreCase(part, ".cache");
    }
    return false;
}

fn excludedArtifactPath(path: []const u8, data_relative: ?[]const u8) bool {
    if (data_relative) |data| {
        if (std.ascii.eqlIgnoreCase(path, data) or
            (path.len > data.len and std.ascii.eqlIgnoreCase(path[0..data.len], data) and (path[data.len] == '/' or path[data.len] == '\\'))) return true;
    }
    const end = std.mem.indexOfAny(u8, path, "/\\") orelse path.len;
    for ([_][]const u8{ ".beats", ".git", "$RECYCLE.BIN", "System Volume Information" }) |internal| {
        if (std.ascii.eqlIgnoreCase(path[0..end], internal)) return true;
    }
    // (10-nov): lo interno pasó de `.beats` a `.devagents`, pero en
    // `.devagents` también vive la configuración del usuario (worktree.json),
    // así que solo se excluyen las dos subcarpetas que escribe DevAgents.
    if (end < path.len and std.ascii.eqlIgnoreCase(path[0..end], ".devagents")) {
        const rest = path[end + 1 ..];
        const sub_end = std.mem.indexOfAny(u8, rest, "/\\") orelse rest.len;
        for ([_][]const u8{ "spaces", "external-context-opencode" }) |internal| {
            if (std.ascii.eqlIgnoreCase(rest[0..sub_end], internal)) return true;
        }
    }
    return false;
}

// Only the first component belongs to the root exclusion policy. An identically
// named directory under a user subdirectory remains a normal artifact source.
fn dependencyArtifactPath(path: []const u8) bool {
    const end = std.mem.indexOfAny(u8, path, "/\\") orelse path.len;
    for ([_][]const u8{ "node_modules", "zig-out", ".zig-cache", ".venv", "__pycache__" }) |dependency| {
        if (std.ascii.eqlIgnoreCase(path[0..end], dependency)) return true;
    }
    return false;
}

fn dataRootRelative(a: std.mem.Allocator, root: []const u8, local_app_data: []const u8) !?[]u8 {
    const data = try std.fs.path.resolveWindows(a, &.{ local_app_data, "DevAgents-Angel" });
    defer a.free(data);
    const base = std.mem.trimEnd(u8, root, "\\");
    if (std.ascii.eqlIgnoreCase(base, data) or
        (base.len > data.len and std.ascii.eqlIgnoreCase(base[0..data.len], data) and base[data.len] == '\\')) return error.SandboxDenied;
    if (data.len > base.len and std.ascii.eqlIgnoreCase(data[0..base.len], base) and data[base.len] == '\\') return try a.dupe(u8, data[base.len + 1 ..]);
    return null;
}

fn protectedDataRelative(a: std.mem.Allocator, root: []const u8) !?[]u8 {
    const local = (try defaultGetEnv(a, "LOCALAPPDATA")) orelse return error.EnvironmentUnavailable;
    defer a.free(local);
    return dataRootRelative(a, root, local);
}

fn artifactRoot(a: std.mem.Allocator, path: []const u8) AdapterError!confined_fs.Root {
    return confined_fs.Root.init(a, path);
}

fn artifactRootContext(a: std.mem.Allocator, path: []const u8, ctx: SnapshotContext) !confined_fs.Root {
    return confined_fs.Root.initDiagnostic(a, path, if (ctx.diagnostic) |d| &d.windows_error else null);
}

// Esta comprobación usa handles; las lecturas vuelven a validar EL handle que
// leen. No existe la anterior apertura por nombre tras comprobar atributos.
fn regularChain(a: std.mem.Allocator, root: []const u8, rel: []const u8) AdapterError!bool {
    var safe = try artifactRoot(a, root);
    defer safe.deinit();
    const file = safe.open(rel) catch |e| switch (e) {
        error.SandboxDenied => return false,
        error.OutOfMemory => return error.OutOfMemory,
        else => return e,
    };
    @import("platform.zig").closeHandle(file.handle);
    return true;
}

const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(std.os.windows.HANDLE) callconv(.winapi) c_int;
}.CloseHandle else @import("providers").posix_files.CloseHandle;

fn nextSnapshotEntry(a: std.mem.Allocator, io: std.Io, walker: *std.Io.Dir.SelectiveWalker, entries: *std.ArrayList(TreeEntry), ctx: SnapshotContext) !?std.Io.Dir.Walker.Entry {
    // Iterate the validated directory handle directly so an enumeration error
    // retains the exact parent path (SelectiveWalker.next pops it on error).
    while (walker.stack.items.len > 0) {
        const top = &walker.stack.items[walker.stack.items.len - 1];
        const dirname_len = top.dirname_len;
        const item = top.iter.next(io) catch |e| {
            const rel = walker.name_buffer.items[0..dirname_len];
            const recoverable = unreadableError(e) and dirname_len > 0;
            ctx.report("recorrido", if (rel.len == 0) "." else rel, e, recoverable);
            if (!recoverable) return e;
            try unknownEntry(a, entries, rel);
            walker.leave(io);
            continue;
        };
        if (item) |entry| {
            walker.name_buffer.shrinkRetainingCapacity(dirname_len);
            if (dirname_len > 0) try walker.name_buffer.append(a, std.fs.path.sep);
            const start = walker.name_buffer.items.len;
            try walker.name_buffer.appendSlice(a, entry.name);
            try walker.name_buffer.append(a, 0);
            const end = walker.name_buffer.items.len - 1;
            return .{ .dir = top.iter.reader.dir, .basename = walker.name_buffer.items[start..end :0], .path = walker.name_buffer.items[0..end :0], .kind = entry.kind };
        }
        walker.leave(io);
    }
    return null;
}

fn treeSnapshotInner(a: std.mem.Allocator, io: std.Io, safe: *const confined_fs.Root, ctx: SnapshotContext) ![]TreeEntry {
    const data_relative = protectedDataRelative(a, safe.canonical) catch |e| {
        ctx.reportRoot(a, safe.canonical, e);
        return e;
    };
    defer if (data_relative) |p| a.free(p);
    const dir = safe.dir();
    var walker = dir.walkSelectively(a) catch |e| {
        ctx.report("recorrido", ".", e, false);
        return e;
    };
    defer {
        while (walker.stack.items.len > 1) walker.leave(io);
        walker.deinit();
    }
    var entries = std.ArrayList(TreeEntry).empty;
    errdefer {
        for (entries.items) |entry| {
            a.free(entry.path);
            a.free(entry.placeholders);
        }
        entries.deinit(a);
    }
    var visited: usize = 0;
    var bytes: u64 = 0;
    while (try nextSnapshotEntry(a, io, &walker, &entries, ctx)) |entry| {
        if (excludedArtifactPath(entry.path, data_relative) or generatedCachePath(entry.path)) continue;
        const metadata_only = dependencyArtifactPath(entry.path);
        if (!metadata_only) visited += 1;
        if (visited > SNAPSHOT_ENTRY_CAP) {
            ctx.report("limite", entry.path, error.TooManyFiles, false);
            return error.TooManyFiles;
        }
        if (entry.kind != .directory and entry.kind != .file) continue;
        const file = (if (metadata_only and entry.kind == .file) safe.openMetadata(entry.path) else safe.open(entry.path)) catch |e| switch (e) {
            // Enlaces son excluidos, incluyendo sustituciones entre enumerar y
            // abrir. Ningún byte se lee de un handle rechazado.
            error.SandboxDenied => continue,
            error.HardLinkDenied => {
                ctx.report("apertura", entry.path, e, false);
                return e;
            },
            else => {
                ctx.report("apertura", entry.path, e, unreadableError(e));
                if (!unreadableError(e)) return e;
                try unknownEntry(a, &entries, entry.path);
                continue;
            },
        };
        if (entry.kind == .directory) {
            const child: std.Io.Dir = .{ .handle = file.handle };
            errdefer child.close(io);
            try walker.stack.append(a, .{ .iter = child.iterate(), .dirname_len = walker.name_buffer.items.len - 1 });
            continue;
        }
        defer file.close(io);
        const stat = file.stat(io) catch |e| {
            ctx.report("atributos", entry.path, e, false);
            return e;
        };
        if (stat.kind != .file) {
            ctx.report("atributos", entry.path, error.SandboxDenied, false);
            return error.SandboxDenied;
        }
        if (metadata_only) {
            const path = try a.dupe(u8, entry.path);
            errdefer a.free(path);
            try entries.append(a, .{ .path = path, .size = stat.size, .mtime = stat.mtime.nanoseconds, .metadata_only = true });
            continue;
        }
        bytes = std.math.add(u64, bytes, stat.size) catch SNAPSHOT_BYTE_CAP + 1;
        if (bytes > SNAPSHOT_BYTE_CAP) {
            ctx.report("limite", entry.path, error.SnapshotTooLarge, false);
            return error.SnapshotTooLarge;
        }
        if (@import("builtin").is_test) if (ctx.after_stat) |hook| try hook(ctx.hook_ctx, io, file, entry.path);
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        var buffer: [64 * 1024]u8 = undefined;
        var offset: u64 = 0;
        var read_error: ?anyerror = null;
        const marker_body = if (stat.size <= ARTIFACT_CONTENT_CAP) try a.alloc(u8, @intCast(stat.size)) else null;
        defer if (marker_body) |body| a.free(body);
        while (offset < stat.size) {
            const n = file.readPositionalAll(io, buffer[0..@intCast(@min(buffer.len, stat.size - offset))], offset) catch |e| {
                read_error = e;
                break;
            };
            if (n == 0) {
                read_error = error.SizeChanged;
                break;
            }
            if (marker_body) |body| @memcpy(body[@intCast(offset)..][0..n], buffer[0..n]);
            hasher.update(buffer[0..n]);
            offset += n;
        }
        const after = file.stat(io) catch |e| {
            ctx.report("atributos", entry.path, e, false);
            return e;
        };
        if (after.size != stat.size) read_error = error.SizeChanged else if (after.mtime.nanoseconds != stat.mtime.nanoseconds) read_error = error.FileChanged;
        if (read_error) |e| {
            ctx.report(if (e == error.SizeChanged or e == error.FileChanged) "tamano_cambiado" else "lectura", entry.path, e, unreadableError(e));
            if (!unreadableError(e)) return e;
            try unknownEntry(a, &entries, entry.path);
            continue;
        }
        const path = try a.dupe(u8, entry.path);
        errdefer a.free(path);
        const placeholders = if (marker_body) |body| try artifact_quality.placeholderLines(a, body) else try a.alloc(artifact_quality.LineHash, 0);
        errdefer a.free(placeholders);
        try entries.append(a, .{ .path = path, .size = stat.size, .sha256 = hasher.finalResult(), .placeholders = placeholders });
    }
    return try entries.toOwnedSlice(a);
}

pub fn captureArtifactBaseline(a: std.mem.Allocator, io: std.Io, capture: CaptureFn, root: []const u8, requested_base: ?[]const u8) AdapterError!ArtifactBaseline {
    return captureArtifactBaselineContext(a, io, capture, root, requested_base, .{});
}

pub fn captureArtifactBaselineContext(a: std.mem.Allocator, io: std.Io, capture: CaptureFn, root: []const u8, requested_base: ?[]const u8, ctx: SnapshotContext) AdapterError!ArtifactBaseline {
    var safe = artifactRootContext(a, root, ctx) catch |e| {
        ctx.reportRoot(a, root, e);
        return e;
    };
    errdefer safe.deinit();
    const entries = try treeSnapshotInner(a, io, &safe, ctx);
    errdefer freeTree(a, entries);
    if (gitRootMatches(a, capture, root) catch |e| {
        ctx.report("git", ".", e, false);
        return e;
    }) {
        const commit = if (requested_base) |s| try a.dupe(u8, s) else recordBaseCommit(a, capture, root) catch |e| {
            ctx.report("git", ".", e, false);
            return e;
        };
        return .{ .canonical_root = safe.canonical, .retained_root = safe, .git_commit = commit, .entries = entries };
    }
    return .{ .canonical_root = safe.canonical, .retained_root = safe, .entries = entries };
}

pub fn collectArtifactChanges(a: std.mem.Allocator, io: std.Io, capture: CaptureFn, root: []const u8, baseline: ArtifactBaseline, sb: sandbox.Sandbox) AdapterError![]worker_backend.Artifact {
    return collectArtifactChangesContext(a, io, capture, root, baseline, sb, .{});
}

pub fn collectArtifactChangesContext(a: std.mem.Allocator, io: std.Io, capture: CaptureFn, root: []const u8, baseline: ArtifactBaseline, sb: sandbox.Sandbox, ctx: SnapshotContext) AdapterError![]worker_backend.Artifact {
    var safe = artifactRootContext(a, root, ctx) catch |e| {
        ctx.report("raiz", ".", e, false);
        return e;
    };
    defer safe.deinit();
    if (!std.ascii.eqlIgnoreCase(safe.canonical, baseline.canonical_root)) {
        ctx.report("raiz", ".", error.SandboxDenied, false);
        return error.SandboxDenied;
    }
    baseline.retained_root.validateIdentity(&safe) catch |e| {
        ctx.report("raiz", ".", e, false);
        return e;
    };
    var retained = baseline.retained_root;
    retained.windows_error = if (ctx.diagnostic) |d| &d.windows_error else null;
    const current = try treeSnapshotInner(a, io, &retained, ctx);
    defer freeTree(a, current);
    var paths = std.StringHashMap(void).init(a);
    defer paths.deinit();
    var git_paths = std.ArrayList([]const u8).empty;
    defer {
        for (git_paths.items) |p| a.free(p);
        git_paths.deinit(a);
    }
    if (baseline.git_commit) |base| {
        const data_relative = try protectedDataRelative(a, safe.canonical);
        defer if (data_relative) |p| a.free(p);
        try appendGitLines(a, &git_paths, capture, root, &.{ "git", "diff", "--name-only", "-z", base });
        // Git ignores dependencies by design; the tree comparison below must
        // still expose changes under ignored paths, including in Git spaces.
        for (git_paths.items) |p| {
            if (!excludedArtifactPath(p, data_relative) and !dependencyArtifactPath(p)) try paths.put(p, {});
        }
    }
    var observed = std.StringHashMap(TreeEntry).init(a);
    defer observed.deinit();
    var before = std.StringHashMap(TreeEntry).init(a);
    defer before.deinit();
    var dependency_changes: usize = 0;
    for (baseline.entries) |entry| try before.put(entry.path, entry);
    for (current) |entry| {
        try observed.put(entry.path, entry);
        const old = before.get(entry.path);
        if (entry.metadata_only) {
            if (entry.readable and !unknownPath(baseline.entries, entry.path)) {
                if (old == null or old.?.size != entry.size or old.?.mtime != entry.mtime) dependency_changes += 1;
            } else if (entry.readable) ctx.report("linea_base", entry.path, error.BaselineUnreadable, true);
            _ = before.remove(entry.path);
            continue;
        }
        if (entry.readable and !unknownPath(baseline.entries, entry.path)) {
            if (old == null or old.?.size != entry.size or !std.mem.eql(u8, &old.?.sha256, &entry.sha256)) try paths.put(entry.path, {});
        } else if (entry.readable) ctx.report("linea_base", entry.path, error.BaselineUnreadable, true);
        _ = before.remove(entry.path);
    }
    var deleted = before.iterator();
    while (deleted.next()) |entry| {
        if (entry.value_ptr.readable and !unknownPath(current, entry.key_ptr.*)) {
            if (entry.value_ptr.metadata_only) dependency_changes += 1 else try paths.put(entry.key_ptr.*, {});
        }
    }
    var arts = std.ArrayList(worker_backend.Artifact).empty;
    errdefer {
        for (arts.items) |*art| art.deinit(a);
        arts.deinit(a);
    }
    var changed = paths.keyIterator();
    while (changed.next()) |path| {
        if (!sb.isAllowed(path.*)) {
            ctx.report("apertura", path.*, error.SandboxDenied, false);
            return error.SandboxDenied;
        }
        const content = readArtifactContentContext(a, io, &retained, path.*, ctx, observed.get(path.*)) catch |e| {
            if (unreadableError(e)) continue;
            return e;
        };
        errdefer a.free(content);
        const owned_path = try a.dupe(u8, path.*);
        errdefer a.free(owned_path);
        // E-GOV.1: la procedencia sale de la línea base del motor, no del modelo.
        const inherited = blk: {
            for (baseline.entries) |entry| if (std.ascii.eqlIgnoreCase(entry.path, path.*)) break :blk try a.dupe(artifact_quality.LineHash, entry.placeholders);
            break :blk try a.alloc(artifact_quality.LineHash, 0);
        };
        errdefer a.free(inherited);
        try arts.append(a, .{ .path = owned_path, .content = content, .inherited_placeholders = inherited });
    }
    std.mem.sort(worker_backend.Artifact, arts.items, {}, struct {
        fn less(_: void, x: worker_backend.Artifact, y: worker_backend.Artifact) bool {
            return std.mem.lessThan(u8, x.path, y.path);
        }
    }.less);
    if (dependency_changes > 0) if (ctx.sink) |sink| {
        var message: [128]u8 = undefined;
        const text = try std.fmt.bufPrint(&message, "{d} archivos cambiados en carpetas de dependencias/cachés", .{dependency_changes});
        sink.call(.warning, text);
    };
    return try arts.toOwnedSlice(a);
}

fn readArtifactContent(allocator: std.mem.Allocator, io: std.Io, root: *const confined_fs.Root, rel: []const u8) AdapterError![]u8 {
    return readArtifactContentContext(allocator, io, root, rel, .{}, null);
}

fn readArtifactContentContext(allocator: std.mem.Allocator, io: std.Io, root: *const confined_fs.Root, rel: []const u8, ctx: SnapshotContext, expected: ?TreeEntry) AdapterError![]u8 {
    const file = root.open(rel) catch |e| switch (e) {
        error.OutOfMemory, error.SandboxDenied => {
            ctx.report("apertura", rel, e, false);
            return e;
        },
        // Borrado del diff: ningún handle fue abierto ni contenido ajeno leído.
        error.FileNotFound => {
            if (expected != null) {
                ctx.report("apertura", rel, e, true);
                return e;
            }
            return try allocator.dupe(u8, "");
        },
        else => {
            ctx.report("apertura", rel, e, unreadableError(e));
            return e;
        },
    };
    defer file.close(io);
    const stat = file.stat(io) catch |e| {
        ctx.report("atributos", rel, e, false);
        return e;
    };
    if (stat.kind != .file) {
        ctx.report("atributos", rel, error.SandboxDenied, false);
        return error.SandboxDenied;
    }
    if (stat.size > ARTIFACT_CONTENT_CAP) {
        ctx.report("limite", rel, error.ArtifactTooLarge, false);
        return error.ArtifactTooLarge;
    }
    if (@import("builtin").is_test) if (ctx.after_stat) |hook| try hook(ctx.hook_ctx, io, file, rel);
    const data = try allocator.alloc(u8, @intCast(stat.size));
    defer allocator.free(data);
    if ((file.readPositionalAll(io, data, 0) catch |e| {
        ctx.report("lectura", rel, e, unreadableError(e));
        return e;
    }) != data.len) {
        ctx.report("tamano_cambiado", rel, error.SizeChanged, true);
        return error.SizeChanged;
    }
    const after = file.stat(io) catch |e| {
        ctx.report("atributos", rel, e, false);
        return e;
    };
    if (after.size != stat.size or after.mtime.nanoseconds != stat.mtime.nanoseconds) {
        ctx.report("tamano_cambiado", rel, error.SizeChanged, true);
        return error.SizeChanged;
    }
    if (expected) |entry| {
        var sha: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &sha, .{});
        if (entry.size != stat.size or !std.mem.eql(u8, &sha, &entry.sha256)) {
            ctx.report("lectura", rel, error.FileChanged, true);
            return error.FileChanged;
        }
    }
    if (data.len == 0) return try allocator.dupe(u8, "");
    if (!std.unicode.utf8ValidateSlice(data)) {
        return try std.fmt.allocPrint(allocator, "(artefacto binario, {d} bytes)", .{data.len});
    }
    return try allocator.dupe(u8, data);
}

/// Artefactos = diff del worktree frente al commit base registrado al despachar:
/// `git diff --name-only <base>` + `git ls-files --others --exclude-standard`,
/// cada ruta validada por el sandbox y con su contenido leído del worktree.
/// CONTROL NEGATIVO E5.07: quitar `sb.isAllowed` deja pasar rutas fuera del
/// worktree y la prueba dedicada lo caza en rojo.
pub fn collectDiffArtifacts(
    allocator: std.mem.Allocator,
    io: std.Io,
    capture: CaptureFn,
    worktree: []const u8,
    base_commit: []const u8,
    sb: sandbox.Sandbox,
) AdapterError![]worker_backend.Artifact {
    return collectDiffArtifactsContext(allocator, io, capture, worktree, base_commit, sb, .{});
}

fn collectDiffArtifactsContext(allocator: std.mem.Allocator, io: std.Io, capture: CaptureFn, worktree: []const u8, base_commit: []const u8, sb: sandbox.Sandbox, ctx: SnapshotContext) AdapterError![]worker_backend.Artifact {
    var safe = artifactRootContext(allocator, worktree, ctx) catch |e| {
        ctx.report("raiz", ".", e, false);
        return e;
    };
    defer safe.deinit();
    const data_relative = try protectedDataRelative(allocator, safe.canonical);
    defer if (data_relative) |p| allocator.free(p);
    if (!try gitRootMatches(allocator, capture, worktree)) return error.GitFailed;
    var paths = std.ArrayList([]const u8).empty;
    defer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    try appendGitLines(allocator, &paths, capture, worktree, &.{ "git", "diff", "--name-only", "-z", base_commit });
    try appendGitLines(allocator, &paths, capture, worktree, &.{ "git", "ls-files", "--others", "--exclude-standard", "-z" });

    var artifacts = std.ArrayList(worker_backend.Artifact).empty;
    errdefer {
        for (artifacts.items) |*a| a.deinit(allocator);
        artifacts.deinit(allocator);
    }
    for (paths.items) |rel| {
        if (excludedArtifactPath(rel, data_relative) or dependencyArtifactPath(rel)) continue;
        // VALIDACIÓN DE RUTA (control negativo de la fila): una ruta del diff
        // que resuelva fuera del sandbox rechaza la recolección entera.
        if (!sb.isAllowed(rel)) {
            ctx.report("apertura", rel, error.SandboxDenied, false);
            return error.SandboxDenied;
        }
        const content = readArtifactContentContext(allocator, io, &safe, rel, ctx, null) catch |e| {
            if (unreadableError(e)) continue;
            return e;
        };
        errdefer allocator.free(content);
        const owned_path = try allocator.dupe(u8, rel);
        errdefer allocator.free(owned_path);
        // E-GOV.1: la versión del commit base es la procedencia real del diff;
        // sin ella, un TODO preexistente se confundiría con una omisión nueva.
        const slash_path = try allocator.dupe(u8, rel);
        defer allocator.free(slash_path);
        for (slash_path) |*c| if (c.* == '\\') {
            c.* = '/';
        };
        const spec = try std.fmt.allocPrint(allocator, "{s}:{s}", .{ base_commit, slash_path });
        defer allocator.free(spec);
        var old = capture(allocator, &.{ "git", "show", spec }, worktree) catch return error.GitFailed;
        defer old.deinit(allocator);
        if (old.stdout.len > ARTIFACT_CONTENT_CAP) return error.ArtifactTooLarge;
        const inherited = try artifact_quality.placeholderLines(allocator, if (old.exit_code == 0) old.stdout else "");
        errdefer allocator.free(inherited);
        try artifacts.append(allocator, .{
            .path = owned_path,
            .content = content,
            .inherited_placeholders = inherited,
        });
    }
    return artifacts.toOwnedSlice(allocator);
}

/// Resultado de una corrida headless: artefactos del diff, declaración del
/// agente, transcripción acotada+censurada, warnings de facturación y estado
/// real del proceso.
pub const RunReport = struct {
    artifacts: []worker_backend.Artifact,
    declaration: []u8,
    transcript: []u8,
    transcript_truncated: bool,
    exit_code: ?u8,
    timed_out: bool,
    /// E5.08: turnos del asistente observados en el stream (o `num_turns`
    /// informado por el CLI en su evento result). 0 = no observables.
    turns: u32 = 0,
    /// E5.08: el kill lo pidió el tope de turnos, no el reloj.
    turn_limited: bool = false,
    cancelled: bool = false,
    /// E5.08: tokens informados por el CLI (usage del evento result). 0 = el
    /// agente no los reportó — nunca se inventan.
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    env_warnings: [][]u8,
    success: bool,
    resume_attempted: bool = false,
    session_seen: bool = false,
    /// Actual launch argv after context policy and verified spawn prefix.
    argv_censored: ?[]u8 = null,

    pub fn deinit(self: *RunReport, allocator: std.mem.Allocator) void {
        for (self.artifacts) |*a| a.deinit(allocator);
        allocator.free(self.artifacts);
        allocator.free(self.declaration);
        allocator.free(self.transcript);
        if (self.argv_censored) |argv| allocator.free(argv);
        for (self.env_warnings) |w| allocator.free(w);
        allocator.free(self.env_warnings);
    }
};

pub const Options = struct {
    rules_context: project_rules.Context = .{},
    profile: CliProfile,
    /// Worktree gobernado: cwd del hijo y raíz del diff.
    worktree: []const u8,
    /// Commit base del diff; null = `git rev-parse HEAD` al despachar.
    base_commit: ?[]const u8 = null,
    /// Tope de reloj por corrida (E5.08 impone el de orden/tarea configurado).
    timeout_ms: u64 = 15 * 60 * 1000,
    /// E5.08: tope de turnos del asistente por corrida; 0 = sin tope.
    /// Al superarlo el worker mata al hijo y el informe llega con
    /// `turn_limited` (no `timed_out`).
    max_turns: u32 = 0,
    transcript_cap: usize = cli_worker.DEFAULT_TRANSCRIPT_CAP,
    /// Prefijo verificado de spawn: exe/batch absoluto o node.exe + script npm.
    /// Sustituye argv[0]; el llamador retiene los handles de confianza.
    spawn_prefix: ?[]const []const u8 = null,
    /// Codex construye su entorno filtrado si el llamador no lo proporciona.
    environ_map: ?*const std.process.Environ.Map = null,
    /// Receptor de eventos del streaming (contenido, herramientas, plan…).
    event_sink: ?EventSink = null,
    session_sink: ?external_session.Sink = null,
    /// Seams de prueba.
    getenv: ?GetEnvFn = null,
    capture_fn: ?CaptureFn = null,
    mock_output: ?[]const u8 = null,
    snapshot_diagnostic: ?*SnapshotDiagnostic = null,
    is_cancelled_fn: ?*const fn (?*anyopaque) bool = null,
    cancelled_ctx: ?*anyopaque = null,
    workspace_restore: ?*const fn (*@import("workspace_acl.zig").Snapshot) anyerror!void = null,
};

/// Captura el descriptor de la raíz ANTES de lanzar el CLI, sobre el handle
/// que el Snapshot retiene (no reabre la ruta), y en las raíces gobernadas
/// (devagents-workspace) exige que ese mismo handle ya sea privado. Un espacio
/// contaminado entre la comprobación previa y la captura no lanza nada: causa
/// visible con la oferta de reparar.
pub fn capturePermissions(a: std.mem.Allocator, root: []const u8, ctx: SnapshotContext) !@import("workspace_acl.zig").Snapshot {
    var code: u32 = 0;
    var snapshot = @import("workspace_acl.zig").Snapshot.initDiagnostic(a, root, &code) catch |e| {
        if (ctx.diagnostic) |d| d.windows_error = code;
        ctx.report("apertura", ".", e, false);
        return e;
    };
    errdefer snapshot.deinit();
    snapshot.checkGoverned(root) catch |e| {
        ctx.reportRoot(a, root, e);
        return e;
    };
    return snapshot;
}

/// Restaura los permisos de la raíz tras el CLI, por cualquier vía de salida.
/// `tree_stuck`: el árbol de procesos no terminó en su tope; no se restaura a
/// ciegas con descendientes posiblemente vivos. Tras restaurar, las raíces
/// gobernadas se vuelven a comprobar: un proceso escapado del Job pudo
/// recontaminarlas, y la orden no debe quedar `done` en silencio.
pub fn restoreWorkspace(a: std.mem.Allocator, snapshot: *@import("workspace_acl.zig").Snapshot, opts: Options, ctx: SnapshotContext, tree_stuck: bool) !void {
    if (tree_stuck) {
        if (ctx.diagnostic) |d| d.windows_error = 0;
        ctx.report("restauracion_permisos", ".", error.ProcessTreeStillActive, false);
        if (opts.event_sink) |sink| sink.call(.warning, "quedan procesos del CLI activos tras 15 s: no se restauran los permisos del espacio para no hacerlo a ciegas");
        return error.ProcessTreeStillActive;
    }
    const restored = if (@import("builtin").is_test and opts.workspace_restore != null)
        opts.workspace_restore.?(snapshot)
    else
        snapshot.restore();
    // Enlaces en el árbol (hardlinks de pnpm, junctions de npm, clones locales):
    // la raíz ya quedó restaurada y verificada por el nativo, solo los hijos
    // no se tocaron. Es un aviso visible, no un fallo de la orden; sigue siendo
    // error en la reparación explícita.
    var links_left = false;
    restored catch |e| {
        if (e != error.WorkspaceTreeHasLinks) {
            // T2d-D5: sin diagnóstico del llamante (Directo) el aviso decía
            // win32=0; el código nativo viaja siempre.
            var local: SnapshotDiagnostic = .{};
            var with_code = ctx;
            const d = ctx.diagnostic orelse &local;
            d.windows_error = snapshot.last_error;
            with_code.diagnostic = d;
            with_code.report("restauracion_permisos", ".", error.WorkspacePermissionsRestoreFailed, false);
            return error.WorkspacePermissionsRestoreFailed;
        }
        links_left = true;
        if (opts.event_sink) |sink| sink.call(.warning, "el espacio contiene enlaces (junction, symlink o vínculo físico): la raíz quedó restaurada y no se tocaron los hijos");
    };
    snapshot.checkGoverned(opts.worktree) catch |e| {
        ctx.reportRoot(a, opts.worktree, e);
        if (opts.event_sink) |sink| sink.call(.warning, "la raíz del espacio volvió a quedar con escritores ajenos tras restaurar: un proceso escapó del trabajo");
        return e;
    };
    // La traza solo sale si hubo algo que restaurar: con el descriptor intacto
    // (el caso normal) no se anuncia nada ni se añade un evento tras el result.
    if (!snapshot.rewritten()) return;
    if (opts.event_sink) |sink| {
        const codex = std.mem.eql(u8, opts.profile.id, CODEX.id);
        sink.call(.status, if (links_left)
            (if (codex) "permisos de la raíz del espacio restaurados tras Codex (hijos sin tocar)" else "permisos de la raíz del espacio restaurados tras CLI externo (hijos sin tocar)")
        else if (codex) "permisos del espacio restaurados tras Codex" else "permisos del espacio restaurados tras CLI externo");
    }
}

const LineCtx = struct {
    allocator: std.mem.Allocator,
    mode: OutputMode,
    sink: EventSink,
    /// E5.08: turnos contados + tope; al superarlo se levanta `abort` y el
    /// worker mata al hijo (limit_hit, no timeout). Solo cuentan los eventos
    /// `assistant` del stream — ni ecos de usuario ni tool results.
    turns: u32 = 0,
    cap: u32 = 0,
    abort: ?*std.atomic.Value(bool) = null,
    /// Uso informado por el CLI en su evento result (claude lo envía).
    reported_input_tokens: u64 = 0,
    reported_output_tokens: u64 = 0,
    cli: []const u8 = "",
    session_sink: ?external_session.Sink = null,
    resume_session: ?[]const u8 = null,
    session_seen: bool = false,
    session_error: ?anyerror = null,
};

fn nopSinkCall(_: *anyopaque, _: EventKind, _: []const u8) void {}
var nop_sink_ctx: u8 = 0;
fn nopSink() EventSink {
    return .{ .ctx = &nop_sink_ctx, .callFn = nopSinkCall };
}

/// Inspección interna de una línea stream-json para la telemetría de E5.08:
/// cuenta turnos (type=assistant), captura num_turns/usage del result y
/// levanta el abort del worker cuando se supera el tope configurado.
fn inspectJsonLine(ctx: *LineCtx, line: []const u8) void {
    var parsed = std.json.parseFromSlice(std.json.Value, ctx.allocator, line, .{}) catch return;
    defer parsed.deinit();
    if (parsed.value != .object) return;
    const obj = parsed.value.object;
    const ty: []const u8 = if (obj.get("type")) |t| (if (t == .string) t.string else "") else "";
    const session = sessionId(ctx.cli, obj);
    if (session) |id| if (!ctx.session_seen and external_session.validId(id)) {
        if (ctx.session_sink) |sink| {
            sink.call(.saved, id, "") catch |err| {
                ctx.session_error = err;
                if (ctx.abort) |flag| flag.store(true, .release);
                return;
            };
            if (ctx.resume_session) |expected| if (std.mem.eql(u8, expected, id)) {
                sink.call(.resumed, id, "") catch |err| {
                    ctx.session_error = err;
                    if (ctx.abort) |flag| flag.store(true, .release);
                    return;
                };
            };
        }
        ctx.session_seen = true;
    };
    if (std.mem.eql(u8, ty, "assistant")) {
        ctx.turns += 1;
        if (ctx.cap > 0 and ctx.turns > ctx.cap) {
            if (ctx.abort) |a| a.store(true, .release);
        }
    } else if (std.mem.eql(u8, ty, "result") or std.mem.eql(u8, ty, "turn.completed")) {
        if (std.mem.eql(u8, ty, "turn.completed")) {
            ctx.turns += 1;
            if (ctx.cap > 0 and ctx.turns > ctx.cap) if (ctx.abort) |a| a.store(true, .release);
        }
        if (obj.get("num_turns")) |nt| {
            if (nt == .integer and nt.integer > 0)
                ctx.turns = @intCast(@min(nt.integer, std.math.maxInt(u32)));
        }
        if (obj.get("usage")) |u| {
            if (u == .object) {
                if (u.object.get("input_tokens")) |v| {
                    if (v == .integer and v.integer > 0) ctx.reported_input_tokens = @intCast(v.integer);
                }
                if (u.object.get("output_tokens")) |v| {
                    if (v == .integer and v.integer > 0) ctx.reported_output_tokens = @intCast(v.integer);
                }
            }
        }
    }
}

fn sessionId(cli: []const u8, obj: std.json.ObjectMap) ?[]const u8 {
    const ty = obj.get("type") orelse return null;
    if (ty != .string) return null;
    const field: []const u8 = if (std.mem.eql(u8, cli, "claude-code")) blk: {
        const sub = obj.get("subtype") orelse return null;
        if (!std.mem.eql(u8, ty.string, "system") or sub != .string or !std.mem.eql(u8, sub.string, "init")) return null;
        break :blk "session_id";
    } else if (std.mem.eql(u8, cli, "codex")) blk: {
        if (!std.mem.eql(u8, ty.string, "thread.started")) return null;
        break :blk "thread_id";
    } else if (std.mem.eql(u8, cli, "opencode")) blk: {
        // An error can carry the requested sessionID without accepting it.
        if (!std.mem.eql(u8, ty.string, "step_start") and !std.mem.eql(u8, ty.string, "text") and !std.mem.eql(u8, ty.string, "tool_use") and !std.mem.eql(u8, ty.string, "step_finish")) return null;
        break :blk "sessionID";
    } else return null;
    const id = obj.get(field) orelse return null;
    return if (id == .string) id.string else null;
}

fn onCleanupWarning(ctx_ptr: *anyopaque, text: []const u8) void {
    const ctx: *LineCtx = @ptrCast(@alignCast(ctx_ptr));
    ctx.sink.call(.warning, text);
}

/// Nombre del agente para los avisos que lee el usuario.
fn cliDisplayName(id: []const u8) []const u8 {
    if (std.mem.eql(u8, id, "claude-code")) return "Claude Code";
    if (std.mem.eql(u8, id, "codex")) return "Codex";
    if (std.mem.eql(u8, id, "gemini-cli")) return "Gemini CLI";
    if (std.mem.eql(u8, id, "opencode")) return "OpenCode";
    return if (id.len > 0) id else "El agente externo";
}

/// F13: el worker avisa con los segundos de silencio; aquí se
/// convierte en la línea de progreso que ve el usuario (aviso, no corte).
fn formatIdleNotice(buf: []u8, cli: []const u8, silent_s_text: []const u8) ?[]const u8 {
    const secs = std.fmt.parseInt(u64, silent_s_text, 10) catch return null;
    const mins = secs / 60;
    return if (mins >= 1)
        std.fmt.bufPrint(buf, "{s} lleva {d} min sin dar señales. DevAgents sigue esperando; si no avanza, puedes cancelar la orden.", .{ cliDisplayName(cli), mins }) catch null
    else
        std.fmt.bufPrint(buf, "{s} lleva {d} s sin dar señales. DevAgents sigue esperando; si no avanza, puedes cancelar la orden.", .{ cliDisplayName(cli), secs }) catch null;
}

fn onIdle(ctx_ptr: *anyopaque, silent_s_text: []const u8) void {
    const ctx: *LineCtx = @ptrCast(@alignCast(ctx_ptr));
    var buf: [256]u8 = undefined;
    if (formatIdleNotice(&buf, ctx.cli, silent_s_text)) |text| ctx.sink.call(.warning, text);
}

test "CK-PUB-009 F13: el aviso de inactividad nombra al agente y no promete cortar" {
    var buf: [256]u8 = undefined;
    const t = formatIdleNotice(&buf, "opencode", "180").?;
    try testing.expect(std.mem.startsWith(u8, t, "OpenCode lleva 3 min sin dar señales."));
    try testing.expect(std.mem.indexOf(u8, t, "puedes cancelar la orden") != null);
    const s = formatIdleNotice(&buf, "claude-code", "45").?;
    try testing.expect(std.mem.startsWith(u8, s, "Claude Code lleva 45 s"));
    try testing.expect(formatIdleNotice(&buf, "codex", "x") == null);
}

fn onLine(ctx_ptr: *anyopaque, line: []const u8) void {
    const ctx: *LineCtx = @ptrCast(@alignCast(ctx_ptr));
    const trimmed = std.mem.trim(u8, line, " \t\r");
    if (trimmed.len == 0) return;
    if (ctx.mode == .stream_json_lines) inspectJsonLine(ctx, trimmed);
    const maybe_ev = mapLineToEvent(ctx.allocator, ctx.mode, line) catch return;
    if (maybe_ev) |ev| {
        defer ev.deinit(ctx.allocator);
        ctx.sink.call(ev.kind, ev.text);
    }
}

/// Ejecuta el CLI headless sobre ExternalCliWorker y devuelve el informe:
/// proceso supervisado en el worktree, streaming → eventos, transcripción
/// acotada+censurada y artefactos del diff validados por el sandbox.
/// `timed_out` llega en el informe (con transcripción parcial), no como error.
pub fn run(
    allocator: std.mem.Allocator,
    io: std.Io,
    task: planner.PlannedTask,
    sb: sandbox.Sandbox,
    opts: Options,
) AdapterError!RunReport {
    const started = GetTickCount64();
    var resumed_task = task;
    if (opts.profile.resume_session != null) resumed_task.description = CONTINUATION_PROMPT;
    var report = try runAttempt(allocator, io, resumed_task, sb, opts);
    if (opts.profile.resume_session == null or report.success or report.session_seen or
        report.timed_out or report.cancelled or report.turn_limited) return report;
    const reason = resumeRejection(report.transcript) orelse return report;
    const message = std.fmt.allocPrint(allocator, "no se pudo reanudar: {s}; se relanza", .{reason}) catch |err| {
        report.deinit(allocator);
        return err;
    };
    defer allocator.free(message);
    if (opts.session_sink) |sink| sink.call(.restart, opts.profile.resume_session, message) catch |err| {
        report.deinit(allocator);
        return err;
    };
    if (opts.event_sink) |sink| sink.call(.warning, message);
    const elapsed = GetTickCount64() -| started;
    if (elapsed >= opts.timeout_ms) return report;
    var fresh_opts = opts;
    fresh_opts.profile.resume_session = null;
    fresh_opts.timeout_ms -= elapsed;
    report.deinit(allocator);
    return runAttempt(allocator, io, task, sb, fresh_opts);
}

pub const CONTINUATION_PROMPT = "Continua la tarea interrumpida desde esta sesion. Conserva los archivos y completa el encargo pendiente.";

pub fn resumeRejection(text: []const u8) ?[]const u8 {
    // Only an explicit missing/expired session allows replay. Generic process,
    // quota, permission and network failures must never duplicate work.
    inline for (.{ "No conversation found", "Session not found", "Session does not exist", "Session expired", "No session found", "No rollout found", "No saved session found with id" }) |reason| {
        if (text.len >= reason.len) for (0..text.len - reason.len + 1) |offset| {
            if (std.ascii.eqlIgnoreCase(text[offset..][0..reason.len], reason)) return reason;
        };
    }
    return null;
}

fn runAttempt(
    allocator: std.mem.Allocator,
    io: std.Io,
    task: planner.PlannedTask,
    sb: sandbox.Sandbox,
    opts: Options,
) AdapterError!RunReport {
    const getenv = opts.getenv orelse defaultGetEnv;
    const capture = opts.capture_fn orelse defaultCapture;

    var parent_env: ?std.process.Environ.Map = null;
    defer if (parent_env) |*env| env.deinit();
    const parent = opts.environ_map orelse blk: {
        parent_env = try @import("platform.zig").environ().createMap(allocator);
        break :blk &parent_env.?;
    };
    const snapshot_ctx: SnapshotContext = .{ .diagnostic = opts.snapshot_diagnostic, .sink = opts.event_sink };
    @import("workspace.zig").ensureExternalRoot(allocator, io, opts.worktree) catch |e| {
        snapshot_ctx.reportRoot(allocator, opts.worktree, e);
        return e;
    };
    // Use the same canonical authority for cwd, CLI flags and git discovery.
    // The root's retained handle also rejects ancestor junctions/renames.
    var launch_root = try confined_fs.Root.init(allocator, opts.worktree);
    defer launch_root.deinit();
    const worktree = launch_root.canonical;
    var child_env = external_context.environment(allocator, io, parent, opts.profile.id, worktree, opts.profile.inherit_personal_context) catch |e| {
        if (opts.event_sink) |sink| sink.call(.warning, if (e == error.CustomOpenCodeContextUnavailable)
            "external_context_blocked: OpenCode no se lanzó: tu carpeta de configuración propia (OPENCODE_CONFIG_DIR) declara habilidades o MCP que se perderían al aislar tus instrucciones personales. Muévelas al perfil estándar de OpenCode o pulsa «Heredar mis instrucciones» (Configuración › Agentes externos)."
        else if (e == error.OpenCodeProfileInspectionFailed)
            "external_context_blocked: OpenCode no se lanzó: no se pudo leer tu carpeta de configuración (OPENCODE_CONFIG_DIR). Revisa que exista, que su opencode.json sea válido y no enorme, o pulsa «Heredar mis instrucciones» (Configuración › Agentes externos)."
        else
            "external_context_blocked: no se pudo preparar el entorno del agente externo; no se lanzó.");
        return e;
    };
    defer child_env.deinit();
    const environ_map = &child_env;
    // T12 A2: OpenCode no tiene modo de solo lectura; al planificar se le
    // niegan por permisos la terminal, la edición y la web (nunca «se le pide»
    // no escribir por texto). Con `--auto` lo denegado no se aprueba.
    if (opts.profile.read_only and std.mem.eql(u8, opts.profile.id, OPENCODE.id)) {
        external_context.denyOpenCodeWrites(allocator, &child_env) catch |e| {
            if (opts.event_sink) |sink| sink.call(.warning, "external_permissions_blocked: no se pudo inspeccionar la configuración JSON/JSONC y negar edición, terminal, web y MCP a OpenCode para planificar; no se lanzó");
            return e;
        };
    } else if (opts.profile.deny_shell and std.mem.eql(u8, opts.profile.id, OPENCODE.id)) {
        external_context.denyOpenCodeShell(allocator, &child_env) catch |e| {
            if (opts.event_sink) |sink| sink.call(.warning, "external_permissions_blocked: no se pudo negar la terminal a OpenCode con los permisos actuales; no se lanzo");
            return e;
        };
        if (!opts.profile.read_only) if (opts.event_sink) |sink| sink.call(.status, "permisos: OpenCode puede leer y editar el proyecto, pero no ejecutar comandos (permisos Manual o Aceptar ediciones). Para que ejecute, elige Auto en Permisos.");
    }
    // QA-B H7 / T12 A2: planificar es de solo lectura en las cuatro CLIs.
    if (opts.profile.read_only) {
        if (opts.event_sink) |sink| sink.call(.status, if (std.mem.eql(u8, opts.profile.id, OPENCODE.id))
            "permisos: planificación en solo lectura; a OpenCode se le niegan edición, terminal y web por permisos"
        else
            "permisos: planificación en solo lectura; la CLI lee el proyecto, no edita ni ejecuta comandos");
    } else if (opts.profile.deny_shell and std.mem.eql(u8, opts.profile.id, CODEX.id)) {
        if (opts.event_sink) |sink| sink.call(.status, "permisos: Codex puede leer y editar el proyecto, pero no ejecutar comandos (permisos Manual o Aceptar ediciones). Para que ejecute, elige Auto en Permisos.");
    }
    if (!opts.profile.read_only and opts.profile.deny_shell and std.mem.eql(u8, opts.profile.id, CLAUDE_CODE.id)) {
        if (opts.event_sink) |sink| sink.call(.status, "permisos: Claude Code puede leer y editar el proyecto, pero no ejecutar comandos ni delegar en subagentes (permisos Manual o Aceptar ediciones). Para que lo haga, elige Auto en Permisos.");
    }
    if (!opts.profile.read_only and opts.profile.deny_shell and std.mem.eql(u8, opts.profile.id, GEMINI_CLI.id)) {
        if (opts.event_sink) |sink| sink.call(.status, "permisos: Gemini CLI puede leer y editar el proyecto, pero no ejecutar comandos (permisos Manual o Aceptar ediciones). Para que ejecute, elige Auto en Permisos.");
    }
    if (!opts.profile.inherit_personal_context and std.mem.eql(u8, opts.profile.id, CODEX.id)) {
        external_context.checkCodexGlobals(allocator, io, &child_env) catch |e| {
            if (opts.event_sink) |sink| sink.call(.warning, "external_context_blocked: Codex no se lanzó porque tienes instrucciones personales (AGENTS.md en tu carpeta de Codex) y DevAgents, por defecto, no se las pasa; Codex no permite omitir solo esas. Pulsa «Heredar mis instrucciones» o actívalo en Configuración › Agentes externos. Tus habilidades, MCP y sesión no se tocaron.");
            return e;
        };
    }

    var warns = try billingWarnings(allocator, getenv, environ_map);
    errdefer {
        for (warns.items) |w| allocator.free(w);
        warns.deinit(allocator);
    }

    var baseline = try captureArtifactBaselineContext(allocator, io, capture, opts.worktree, opts.base_commit, snapshot_ctx);
    defer baseline.deinit(allocator);

    var outside = try external_context.OutsideGuard.init(allocator, io, worktree);
    defer outside.deinit();
    var profile = opts.profile;
    var settings: ?[]u8 = null;
    defer if (settings) |s| allocator.free(s);
    if (!profile.inherit_personal_context and std.mem.eql(u8, profile.id, CLAUDE_CODE.id)) {
        settings = try external_context.claudeSettings(allocator, &child_env);
        profile.context_settings = settings;
    }
    // 9-nov: a través de un shim .cmd (Claude Code instalado con npm) el JSON
    // en línea lleva comillas y windows_cmd lo rechaza (UnsafeBatchArgument):
    // Claude Code no arrancaba nunca. `--settings` acepta también una ruta, así
    // que en ese caso se escribe a un archivo temporal propio y se borra al salir.
    var settings_file: ?[]u8 = null;
    defer if (settings_file) |path| {
        std.Io.Dir.cwd().deleteFile(io, path) catch {};
        allocator.free(path);
    };
    const first_exe = if (opts.spawn_prefix) |pre| (if (pre.len > 0) pre[0] else profile.exe) else profile.exe;
    if (settings != null and @import("executor.zig").isBatchShim(first_exe)) {
        const temp = child_env.get("TEMP") orelse child_env.get("TMP") orelse return error.InvalidEnvironment;
        var rnd: [8]u8 = undefined;
        io.random(&rnd);
        const path = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "devagents-claude-settings-{x}.json", .{ std.mem.trimEnd(u8, temp, "\\"), rnd });
        errdefer allocator.free(path);
        try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = settings.? });
        settings_file = path;
        profile.context_settings = path;
    }
    if (!profile.inherit_personal_context and std.mem.eql(u8, profile.id, OPENCODE.id)) {
        const path = child_env.get("OPENCODE_CONFIG_DIR").?;
        try std.Io.Dir.cwd().createDirPath(io, path);
        var safe = try confined_fs.Root.init(allocator, path);
        defer safe.deinit();
        // carpeta interna; que no aparezca en el git del usuario.
        if (safe.openMetadata(".gitignore")) |file| {
            file.close(io);
        } else |e| if (e == error.FileNotFound) safe.writeFile(".gitignore", "*\n") catch {};
        if (safe.openMetadata("AGENTS.md")) |file| {
            file.close(io);
            if (opts.event_sink) |sink| sink.call(.warning, "external_context_blocked: OpenCode no se lanzó: la carpeta aislada que DevAgents le prepara contiene un AGENTS.md que no puso DevAgents. Bórralo de esa carpeta o pulsa «Heredar mis instrucciones» (Configuración › Agentes externos).");
            return error.ContextDirectoryContaminated;
        } else |e| if (e != error.FileNotFound) return e;
    }
    // T7 (e): toda CLI externa (Directo con agente, tareas de
    // Orquestado/Colmena) recibe las reglas del proyecto en su encargo; las
    // instrucciones del proyecto (las reglas del repositorio/las reglas del repositorio) van detrás y mandan.
    // Una sesión reanudada ya recibió las reglas en su primer encargo: su
    // continuación viaja tal cual (CONTINUATION_PROMPT).
    const ruled_description = if (profile.resume_session != null)
        try allocator.dupe(u8, task.description)
    else
        try opts.rules_context.withCliBlock(allocator, task.description);
    defer allocator.free(ruled_description);
    const context_prompt = if (!profile.inherit_personal_context and
        (std.mem.eql(u8, profile.id, CODEX.id) or std.mem.eql(u8, profile.id, OPENCODE.id)))
        try external_context.projectPrompt(allocator, io, worktree, ruled_description)
    else
        null;
    defer if (context_prompt) |p| allocator.free(p);
    var launch_task = task;
    launch_task.description = ruled_description;
    if (context_prompt) |p| launch_task.description = p;
    const argv = try buildArgv(allocator, profile, worktree, launch_task.description);
    defer allocator.free(argv);
    // El prefijo sustituye argv[0] por el ejecutable real (node + script
    // para npm). Un batch custom conserva el escape de la stdlib de Zig.
    const spawn_argv = if (opts.spawn_prefix) |pre| blk: {
        const sa = try allocator.alloc([]const u8, pre.len + argv.len - 1);
        @memcpy(sa[0..pre.len], pre);
        @memcpy(sa[pre.len..], argv[1..]);
        break :blk sa;
    } else argv;
    defer if (opts.spawn_prefix != null) allocator.free(spawn_argv);
    var joined = std.ArrayList(u8).empty;
    defer joined.deinit(allocator);
    for (spawn_argv) |arg| {
        try joined.appendSlice(allocator, arg);
        try joined.append(allocator, ' ');
    }
    const argv_censored = try censorTranscript(allocator, joined.items, getenv);
    errdefer allocator.free(argv_censored);

    var worker = cli_worker.ExternalCliWorker.init(allocator, io, spawn_argv, opts.timeout_ms);
    worker.cwd = worktree;
    worker.environ_map = environ_map;
    worker.stdin_mode = switch (opts.profile.prompt_channel) {
        .argv_tail, .argv_flag => .none,
        .stdin_text => .prompt_text,
    };
    worker.transcript_cap = opts.transcript_cap;
    if (opts.mock_output) |mo| {
        // runCollect returns this transcript before creating a child.
        worker.setMockOutput(mo);
    } else {
        try @import("external_cli_test_guard.zig").checkArgv(allocator, spawn_argv);
    }

    // E5.08: el sink va SIEMPRE puesto — onLine cuenta turnos y levanta el
    // abort del worker al superar max_turns aunque nadie escuche eventos.
    var abort = std.atomic.Value(bool).init(false);
    var line_ctx = LineCtx{
        .allocator = allocator,
        .mode = opts.profile.output_mode,
        .sink = opts.event_sink orelse nopSink(),
        .cap = opts.max_turns,
        .abort = &abort,
        .cli = opts.profile.id,
        .session_sink = opts.session_sink,
        .resume_session = opts.profile.resume_session,
    };
    worker.sink = .{ .ctx = &line_ctx, .callFn = onLine };
    worker.cleanup_sink = .{ .ctx = &line_ctx, .callFn = onCleanupWarning };
    worker.idle_sink = .{ .ctx = &line_ctx, .callFn = onIdle };
    worker.abort_flag = &abort;
    worker.is_cancelled_fn = opts.is_cancelled_fn;
    worker.cancelled_ctx = opts.cancelled_ctx;

    var permissions = try capturePermissions(allocator, opts.worktree, snapshot_ctx);
    defer permissions.deinit();
    if (opts.event_sink) |sink| sink.call(.status, if (profile.inherit_personal_context)
        "external_context_policy: personal_context=true; skills/MCP=inherit; git_ceiling=order_parent"
    else
        "external_context_policy: personal_context=false; skills/MCP=inherit; git_ceiling=order_parent");
    const outcome = worker.runCollect(allocator, launch_task);
    const tree_stuck = if (outcome) |value| value.tree_stuck else |_| false;
    restoreWorkspace(allocator, &permissions, opts, snapshot_ctx, tree_stuck) catch |e| {
        if (outcome) |value| {
            var owned = value;
            owned.deinit(allocator);
        } else |process_error| {
            if (opts.event_sink) |sink| sink.call(.warning, @errorName(process_error));
        }
        return e;
    };
    // Advisory even on failure/timeout/cancellation; the child's outcome
    // remains authoritative. Outside files never enter the artifact collector.
    reportOutsideWorkspace(allocator, io, &outside, opts.event_sink);
    var oc = outcome catch |e| return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.SpawnFailed => error.SpawnFailed,
        error.UnsafeBatchArgument => error.UnsafeBatchArgument,
        // El hijo murió a mitad de escritura/lectura del pipe.
        else => error.ProcessDied,
    };
    defer oc.deinit(allocator);
    if (line_ctx.session_error) |err| return err;

    const transcript = try censorTranscript(allocator, oc.output, getenv);
    errdefer allocator.free(transcript);

    const declaration = try extractDeclaration(allocator, opts.profile.output_mode, transcript);
    errdefer allocator.free(declaration);

    // El diff refleja el estado real del worktree aunque el proceso muriera
    // por timeout — evidencia útil para el ledger, no se descarta.
    const artifacts = try collectArtifactChangesContext(allocator, io, capture, opts.worktree, baseline, sb, snapshot_ctx);
    errdefer {
        for (artifacts) |*a| a.deinit(allocator);
        allocator.free(artifacts);
    }

    // En modo text no hay turnos observables: la invocación es un solo turno.
    const turns: u32 = if (opts.profile.output_mode == .text)
        1
    else
        line_ctx.turns;

    return .{
        .artifacts = artifacts,
        .declaration = declaration,
        .transcript = transcript,
        .transcript_truncated = oc.truncated,
        .exit_code = oc.exit_code,
        .timed_out = oc.timed_out,
        .turns = turns,
        .turn_limited = oc.limit_hit,
        .cancelled = oc.cancelled,
        .prompt_tokens = line_ctx.reported_input_tokens,
        .completion_tokens = line_ctx.reported_output_tokens,
        .env_warnings = try warns.toOwnedSlice(allocator),
        .success = !oc.timed_out and !oc.limit_hit and !oc.cancelled and (oc.exit_code orelse 1) == 0,
        .resume_attempted = opts.profile.resume_session != null,
        .session_seen = line_ctx.session_seen,
        .argv_censored = argv_censored,
    };
}

/// Shared with read-only CLI roles. Only routes and scope enter the event;
/// a new outside file is a visible advisory, never a task failure.
pub fn reportOutsideWorkspace(a: std.mem.Allocator, io: std.Io, guard: *external_context.OutsideGuard, sink: ?EventSink) void {
    if (guard.parent == null) {
        if (sink) |s| s.call(.warning, "external_workspace_scope: sin repo antecesor: no se vigila fuera de la carpeta");
        return;
    }
    guard.check(io) catch |e| {
        const message = std.fmt.allocPrint(a, "external_workspace_scan_warning: no se pudo vigilar fuera de la carpeta ({s}); resultado de la tarea conservado", .{@errorName(e)}) catch {
            if (sink) |s| s.call(.warning, "external_workspace_scan_warning: no se pudo vigilar fuera de la carpeta; resultado de la tarea conservado");
            return;
        };
        defer a.free(message);
        if (sink) |s| s.call(.warning, message);
        return;
    };
    for (guard.new_paths.items) |path| {
        const message = std.fmt.allocPrint(a, "external_workspace_warning: archivo nuevo fuera de la carpeta de la orden: {s}; no se incorpora como artefacto; compruebe su origen (puede ser actividad concurrente); confinamiento pendiente CK-SEG-006", .{path}) catch {
            if (sink) |s| s.call(.warning, "external_workspace_scan_warning: no se pudo publicar la ruta de un archivo externo; resultado de la tarea conservado");
            return;
        };
        defer a.free(message);
        if (sink) |s| s.call(.warning, message);
    }
}

// ── Tests ──────────────────────────────────────────────────────────────

const Comp002Sink = struct {
    conn: @import("db.zig").Connection,
    key: external_session.Key,
    saved: usize = 0,
    resumed: usize = 0,
    restarted: usize = 0,
    fail_write: bool = false,

    fn call(raw: *anyopaque, kind: external_session.Kind, id: ?[]const u8, reason: []const u8) anyerror!void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (self.fail_write) return error.CheckpointDiskFailure;
        try external_session.record(std.testing.allocator, self.conn, self.key, kind, id, reason);
        switch (kind) {
            .saved => self.saved += 1,
            .resumed => self.resumed += 1,
            .restart => self.restarted += 1,
        }
    }
};

fn comp002NoGit(a: std.mem.Allocator, _: []const []const u8, _: ?[]const u8) anyerror!gh.CmdCapture {
    return .{ .stdout = try a.dupe(u8, ""), .stderr = try a.dupe(u8, ""), .exit_code = 1 };
}

const Cab027Sink = struct {
    violation: bool = false,
    blocked: bool = false,
    no_repository: bool = false,
    outside_path: bool = false,
    fn call(raw: *anyopaque, kind: EventKind, text: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(raw));
        if (kind == .warning and std.mem.indexOf(u8, text, "external_workspace_warning") != null)
            self.violation = true;
        if (kind == .warning and std.mem.indexOf(u8, text, "outside.txt") != null) self.outside_path = true;
        if (kind == .warning and std.mem.indexOf(u8, text, "sin repo antecesor: no se vigila fuera de la carpeta") != null) self.no_repository = true;
        if (kind == .warning and std.mem.indexOf(u8, text, "external_context_blocked") != null)
            self.blocked = true;
    }
};

fn writeTestScript(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, source: []const u8) ![:0]u8 {
    try dir.writeFile(io, .{ .sub_path = "cli-double.cjs", .data = source });
    return dir.realPathFileAlloc(io, "cli-double.cjs", a);
}

fn cab027SystemEnv(a: std.mem.Allocator, env: *std.process.Environ.Map) !void {
    // Windows crypto initialization (Node) requires SystemRoot even for a
    // synthetic child with no profile or credentials.
    const system = (try defaultGetEnv(a, "SystemRoot")) orelse return error.EnvironmentUnavailable;
    defer a.free(system);
    try env.put("SystemRoot", system);
}

test "CK-CAB-027 child doubles record isolated args environment cwd and inherited capabilities" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();
    const node = try @import("executor.zig").resolveAllowedExeExt(a, "node", ".exe");
    defer a.free(node);
    for ([_]CliProfile{ CLAUDE_CODE, CODEX, OPENCODE }) |original| {
        for ([_]bool{ false, true }) |inherit| {
            var tmp = testing.tmpDir(.{});
            defer tmp.cleanup();
            const script = try writeTestScript(a, io, tmp.dir, @embedFile("fixtures/cab027_cli.cjs"));
            defer a.free(script);
            try tmp.dir.createDirPath(io, "repo/order");
            try tmp.dir.createDirPath(io, "repo/.git");
            try tmp.dir.writeFile(io, .{ .sub_path = "repo/AGENTS.md", .data = "PROJECT_AGENT_INSTRUCTIONS" });
            try tmp.dir.writeFile(io, .{ .sub_path = "repo/CLAUDE.md", .data = "PROJECT_CLAUDE_INSTRUCTIONS" });
            const root = try tmp.dir.realPathFileAlloc(io, "repo/order", a);
            defer a.free(root);
            var sb = try sandbox.Sandbox.init(a, root);
            defer sb.deinit();
            var env = std.process.Environ.Map.init(a);
            defer env.deinit();
            try cab027SystemEnv(a, &env);
            try env.put("USERPROFILE", "C:\\synthetic-home");
            try env.put("HOME", "C:\\synthetic-home");
            try env.put("CODEX_HOME", "C:\\synthetic-home\\.codex-sid");
            try env.put("CLAUDE_CONFIG_DIR", "C:\\synthetic-home\\custom-claude");
            try env.put("GIT_DIR", "C:\\foreign\\.git");
            try env.put("GIT_WORK_TREE", "C:\\foreign");
            var profile = original;
            var settings_db = try @import("db.zig").Connection.open(a, ":memory:");
            defer settings_db.close();
            try @import("db.zig").Migrator.init(a).migrate(settings_db, &@import("db.zig").catalog_schema);
            if (inherit) try settings_db.exec("UPDATE settings SET value='true' WHERE key='external_agent_inherit_personal_context'");
            profile.inherit_personal_context = try external_context.load(settings_db);
            var report = try run(a, io, makeTask("t1", "TASK"), sb, .{
                .profile = profile,
                .worktree = root,
                .environ_map = &env,
                .spawn_prefix = &.{ node, script },
                .getenv = fakeGetEnv,
                .capture_fn = comp002NoGit,
                .timeout_ms = 15000,
            });
            defer report.deinit(a);
            if (!report.success) std.debug.print("[CK-CAB-027 double failure] cli={s} exit={any} output={s}\n", .{ original.id, report.exit_code, report.transcript });
            try testing.expect(report.success);
            const data = try tmp.dir.readFileAlloc(io, "repo/order/launch.json", a, .limited(65536));
            defer a.free(data);
            var p = try std.json.parseFromSlice(std.json.Value, a, data, .{});
            defer p.deinit();
            const obj = p.value.object;
            const vars = obj.get("env").?.object;
            try testing.expectEqualStrings(root, obj.get("cwd").?.string);
            // Git ignores a ceiling equal to cwd: forbid entering the parent.
            try testing.expect(vars.get("GIT_CEILING_DIRECTORIES").? == .string);
            try testing.expectEqualStrings(std.fs.path.dirname(root).?, vars.get("GIT_CEILING_DIRECTORIES").?.string);
            try testing.expect(vars.get("GIT_DIR").? == .null);
            try testing.expect(vars.get("GIT_WORK_TREE").? == .null);
            try testing.expectEqualStrings("C:\\synthetic-home\\.codex-sid", vars.get("CODEX_HOME").?.string);
            try testing.expectEqualStrings("C:\\synthetic-home", vars.get("HOME").?.string);
            const args = obj.get("argv").?.array.items;
            var joined = std.ArrayList(u8).empty;
            defer joined.deinit(a);
            for (args) |arg| {
                try joined.appendSlice(a, arg.string);
                try joined.append(a, '\n');
                try testing.expect(!std.mem.eql(u8, arg.string, "--bare"));
                try testing.expect(!std.mem.eql(u8, arg.string, "--safe-mode"));
                try testing.expect(!std.mem.eql(u8, arg.string, "--disable-slash-commands"));
                try testing.expect(!std.mem.eql(u8, arg.string, "--strict-mcp-config"));
                try testing.expect(!std.mem.eql(u8, arg.string, "--ignore-user-config"));
            }
            if (std.mem.eql(u8, original.id, "claude-code")) {
                if (!inherit) {
                    try testing.expectEqualStrings("1", vars.get("CLAUDE_CODE_DISABLE_AUTO_MEMORY").?.string);
                    try testing.expect(std.mem.indexOf(u8, joined.items, "claudeMdExcludes") != null);
                    try testing.expect(std.mem.indexOf(u8, joined.items, "custom-claude") != null);
                } else try testing.expect(vars.get("CLAUDE_CODE_DISABLE_AUTO_MEMORY").? == .null);
            } else if (std.mem.eql(u8, original.id, "codex")) {
                try testing.expectEqual(!inherit, std.mem.indexOf(u8, joined.items, "project_doc_max_bytes=0") != null);
                try testing.expectEqual(!inherit, std.mem.indexOf(u8, joined.items, "memories.use_memories=false") != null);
                if (!inherit) try testing.expect(std.mem.indexOf(u8, obj.get("prompt").?.string, "PROJECT_AGENT_INSTRUCTIONS") != null);
            } else {
                try testing.expect(vars.get("OPENCODE_DISABLE_CLAUDE_CODE_SKILLS").? == .null);
                try testing.expect(vars.get("OPENCODE_DISABLE_EXTERNAL_SKILLS").? == .null);
                if (!inherit) {
                    try testing.expectEqualStrings("1", vars.get("OPENCODE_DISABLE_CLAUDE_CODE_PROMPT").?.string);
                    try testing.expect(std.mem.startsWith(u8, vars.get("OPENCODE_CONFIG_DIR").?.string, root));
                    try testing.expect(std.mem.indexOf(u8, obj.get("prompt").?.string, "PROJECT_CLAUDE_INSTRUCTIONS") != null);
                } else try testing.expect(vars.get("OPENCODE_DISABLE_CLAUDE_CODE_PROMPT").? == .null);
            }
            std.debug.print("[CK-CAB-027 double] cli={s} inherit_personal={any} cwd/argv/env recorded; capabilities preserved\n", .{ original.id, inherit });
        }
    }
}

test "CK-CAB-027 nested non-git workspace warns new outside files without failing" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const node = try @import("executor.zig").resolveAllowedExeExt(a, "node", ".exe");
    defer a.free(node);
    for ([_]CliProfile{ CLAUDE_CODE, CODEX, OPENCODE }) |profile| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const script = try writeTestScript(a, io, tmp.dir, @embedFile("fixtures/cab027_cli.cjs"));
        defer a.free(script);
        try tmp.dir.createDirPath(io, "repo/order");
        const parent = try tmp.dir.realPathFileAlloc(io, "repo", a);
        defer a.free(parent);
        var init = try defaultCapture(a, &.{ "git", "init", "--quiet" }, parent);
        defer init.deinit(a);
        try testing.expectEqual(@as(u32, 0), init.exit_code);
        const root = try tmp.dir.realPathFileAlloc(io, "repo/order", a);
        defer a.free(root);
        var sb = try sandbox.Sandbox.init(a, root);
        defer sb.deinit();
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try cab027SystemEnv(a, &env);
        try env.put("USERPROFILE", "C:\\synthetic-home");
        try env.put("CAB027_ESCAPE", "1");
        const git = try @import("executor.zig").resolveAllowedExeExt(a, "git", ".exe");
        defer a.free(git);
        try env.put("CAB027_GIT_EXE", git);
        var events: Cab027Sink = .{};
        const result = run(a, io, makeTask("t1", "TASK"), sb, .{
            .profile = profile,
            .worktree = root,
            .environ_map = &env,
            .spawn_prefix = &.{ node, script },
            .getenv = fakeGetEnv,
            .capture_fn = comp002NoGit,
            .timeout_ms = 15000,
            .event_sink = .{ .ctx = &events, .callFn = Cab027Sink.call },
        });
        var report = try result;
        defer report.deinit(a);
        try testing.expect(report.success);
        try testing.expect(events.violation and events.outside_path);
        for (report.artifacts) |artifact| try testing.expect(std.mem.indexOf(u8, artifact.path, "outside.txt") == null);
        const data = try tmp.dir.readFileAlloc(io, "repo/order/launch.json", a, .limited(65536));
        defer a.free(data);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, data, .{});
        defer parsed.deinit();
        const probe = parsed.value.object.get("git").?.object;
        try testing.expect(probe.get("status").?.integer != 0);
        try testing.expectEqualStrings("", probe.get("root").?.string);
        std.debug.print("[CK-CAB-027 outside] cli={s} success preserved; outside.txt warning event emitted\n", .{profile.id});
    }
}

test "CK-CAB-027 concurrent existing file git internals and ignored new files produce no outside warning" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const node = try @import("executor.zig").resolveAllowedExeExt(a, "node", ".exe");
    defer a.free(node);
    for ([_][]const u8{ "existing", "existing-tracked", "git", "ignored", "staged", "multiple" }) |mode| {
        var tmp = testing.tmpDir(.{});
        defer tmp.cleanup();
        const script = try writeTestScript(a, io, tmp.dir, @embedFile("fixtures/cab027_cli.cjs"));
        defer a.free(script);
        try tmp.dir.createDirPath(io, "repo/order");
        const parent = try tmp.dir.realPathFileAlloc(io, "repo", a);
        defer a.free(parent);
        var init = try defaultCapture(a, &.{ "git", "init", "--quiet" }, parent);
        defer init.deinit(a);
        try testing.expectEqual(@as(u32, 0), init.exit_code);
        try tmp.dir.writeFile(io, .{ .sub_path = "repo/existing.txt", .data = "before" });
        try tmp.dir.writeFile(io, .{ .sub_path = "repo/.gitignore", .data = "ignored/\n" });
        if (std.mem.eql(u8, mode, "existing-tracked")) {
            var add = try defaultCapture(a, &.{ "git", "add", "--", "existing.txt" }, parent);
            defer add.deinit(a);
            try testing.expectEqual(@as(u32, 0), add.exit_code);
        }
        const root = try tmp.dir.realPathFileAlloc(io, "repo/order", a);
        defer a.free(root);
        var sb = try sandbox.Sandbox.init(a, root);
        defer sb.deinit();
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try cab027SystemEnv(a, &env);
        try env.put("USERPROFILE", "C:\\synthetic-home");
        try env.put("CAB027_CHANGE", mode);
        const git = try @import("executor.zig").resolveAllowedExeExt(a, "git", ".exe");
        defer a.free(git);
        try env.put("CAB027_GIT_EXE", git);
        var events = CollectSink.init(a);
        defer events.deinit();
        var report = try run(a, io, makeTask("t", "TASK"), sb, .{
            .profile = CLAUDE_CODE,
            .worktree = root,
            .environ_map = &env,
            .spawn_prefix = &.{ node, script },
            .getenv = fakeGetEnv,
            .capture_fn = comp002NoGit,
            .timeout_ms = 15000,
            .event_sink = events.sink(),
        });
        defer report.deinit(a);
        try testing.expect(report.success);
        var count: usize = 0;
        for (events.texts.items) |text| {
            try testing.expect(!std.mem.startsWith(u8, text, "external_workspace_scan_warning:"));
            if (std.mem.startsWith(u8, text, "external_workspace_warning:")) count += 1;
        }
        const expected: usize = if (std.mem.eql(u8, mode, "multiple")) 2 else if (std.mem.eql(u8, mode, "staged")) 1 else 0;
        try testing.expectEqual(expected, count);
        std.debug.print("[CK-CAB-027 r2] change={s}; outside warnings={d}; success=true\n", .{ mode, count });
    }
}

test "CK-CAB-027 workspace without ancestor repo emits explicit visible scope event" {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    for ([_]bool{ false, true }) |own_repo| {
        var tmp = try tempTree(a, io, "cab027-no-repo");
        defer tmp.deinit(a, io);
        if (own_repo) {
            var init = try defaultCapture(a, &.{ "git", "init", "--quiet" }, tmp.path);
            defer init.deinit(a);
            try testing.expectEqual(@as(u32, 0), init.exit_code);
        }
        var sb = try sandbox.Sandbox.init(a, tmp.path);
        defer sb.deinit();
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("USERPROFILE", "C:\\synthetic-home");
        var events: Cab027Sink = .{};
        var report = try run(a, io, makeTask("t", "TASK"), sb, .{
            .profile = CLAUDE_CODE,
            .worktree = tmp.path,
            .environ_map = &env,
            .getenv = fakeGetEnv,
            .capture_fn = comp002NoGit,
            .mock_output = "{\"type\":\"result\",\"result\":\"complete\"}\n",
            .event_sink = .{ .ctx = &events, .callFn = Cab027Sink.call },
        });
        defer report.deinit(a);
        try testing.expect(report.success);
        try testing.expect(events.no_repository);
        try testing.expect(!events.violation);
        std.debug.print("[CK-CAB-027 r2] scope explicit; order is repo root={any}; no ancestor repo watched\n", .{own_repo});
    }
}

test "CK-CAB-027 newly created private CODEX_HOME has no global instructions and launches normally" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const script = try writeTestScript(a, io, tmp.dir, @embedFile("fixtures/cab027_cli.cjs"));
    defer a.free(script);
    try tmp.dir.createDirPath(io, "user/.codex");
    try tmp.dir.createDirPath(io, "order");
    try tmp.dir.writeFile(io, .{ .sub_path = "user/.codex/AGENTS.md", .data = "PERSONAL_GLOBAL_NOT_FOR_CHILD" });
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const home = try std.fs.path.join(a, &.{ base, "private-codex" });
    defer a.free(home);
    // Same native private-directory primitive used by DevAgents, no copies.
    try @import("external_cli_policy.zig").createPrivateDirectory(a, home);
    var dir = try std.Io.Dir.cwd().openDir(io, home, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    try testing.expect((try it.next(io)) == null);
    const user = try tmp.dir.realPathFileAlloc(io, "user", a);
    defer a.free(user);
    const root = try tmp.dir.realPathFileAlloc(io, "order", a);
    defer a.free(root);
    var sb = try sandbox.Sandbox.init(a, root);
    defer sb.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try cab027SystemEnv(a, &env);
    try env.put("USERPROFILE", user);
    try env.put("CODEX_HOME", home);
    const node = try @import("executor.zig").resolveAllowedExeExt(a, "node", ".exe");
    defer a.free(node);
    var events: Cab027Sink = .{};
    var report = try run(a, io, makeTask("t", "TASK"), sb, .{
        .profile = CODEX,
        .worktree = root,
        .environ_map = &env,
        .spawn_prefix = &.{ node, script },
        .getenv = fakeGetEnv,
        .capture_fn = comp002NoGit,
        .timeout_ms = 15000,
        .event_sink = .{ .ctx = &events, .callFn = Cab027Sink.call },
    });
    defer report.deinit(a);
    try testing.expect(report.success and !events.blocked);
    try external_context.checkCodexGlobals(a, io, &env);
    const data = try tmp.dir.readFileAlloc(io, "order/launch.json", a, .limited(65536));
    defer a.free(data);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, data, .{});
    defer parsed.deinit();
    try testing.expectEqualStrings(home, parsed.value.object.get("env").?.object.get("CODEX_HOME").?.string);
    try testing.expect(std.mem.indexOf(u8, parsed.value.object.get("prompt").?.string, "PERSONAL_GLOBAL_NOT_FOR_CHILD") == null);
    std.debug.print("[CK-CAB-027 r2] private home initially empty; global user instructions outside; child launch succeeds; CODEX_HOME preserved\n", .{});
}

test "CK-CAB-027 custom OpenCode profile blocks with actionable visible event" {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var sb = try sandbox.Sandbox.init(a, root);
    defer sb.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try tmp.dir.createDirPath(io, "profile");
    try tmp.dir.writeFile(io, .{ .sub_path = "profile/opencode.json", .data = "{\"mcp\":{\"synthetic\":{\"type\":\"local\",\"command\":[\"synthetic\"]}},\"skills\":{\"paths\":[\"synthetic\"]}}" });
    const custom = try tmp.dir.realPathFileAlloc(io, "profile", a);
    defer a.free(custom);
    try env.put("OPENCODE_CONFIG_DIR", custom);
    var events = CollectSink.init(a);
    defer events.deinit();
    try testing.expectError(error.CustomOpenCodeContextUnavailable, run(a, io, makeTask("t", "TASK"), sb, .{
        .profile = OPENCODE,
        .worktree = root,
        .environ_map = &env,
        .getenv = fakeGetEnv,
        .capture_fn = comp002NoGit,
        .event_sink = events.sink(),
    }));
    try testing.expectEqual(@as(usize, 1), events.texts.items.len);
    try testing.expect(std.mem.indexOf(u8, events.texts.items[0], "OPENCODE_CONFIG_DIR") != null);
    // 10-nov (USUARIO-NUEVO A3): la salida se nombra como la ve el usuario
    // (botón y ajuste de Configuración), no por la clave interna del ajuste.
    try testing.expect(std.mem.indexOf(u8, events.texts.items[0], "«Heredar mis instrucciones»") != null);
    try testing.expect(std.mem.indexOf(u8, events.texts.items[0], "Configuración › Agentes externos") != null);
}

test "CK-CAB-027 r3 custom OpenCode profile without skills or MCP launches isolated child" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const script = try writeTestScript(a, io, tmp.dir, @embedFile("fixtures/cab027_cli.cjs"));
    defer a.free(script);
    try tmp.dir.createDirPath(io, "profile");
    try tmp.dir.createDirPath(io, "order");
    try tmp.dir.writeFile(io, .{ .sub_path = "profile/opencode.json", .data = "{\"model\":\"synthetic/model\"}" });
    const custom = try tmp.dir.realPathFileAlloc(io, "profile", a);
    defer a.free(custom);
    const root = try tmp.dir.realPathFileAlloc(io, "order", a);
    defer a.free(root);
    const node = try @import("executor.zig").resolveAllowedExeExt(a, "node", ".exe");
    defer a.free(node);
    var sb = try sandbox.Sandbox.init(a, root);
    defer sb.deinit();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try cab027SystemEnv(a, &env);
    try env.put("OPENCODE_CONFIG_DIR", custom);
    var events = Cab027Sink{};
    var report = try run(a, io, makeTask("t", "TASK"), sb, .{
        .profile = OPENCODE,
        .worktree = root,
        .environ_map = &env,
        .spawn_prefix = &.{ node, script },
        .getenv = fakeGetEnv,
        .capture_fn = comp002NoGit,
        .timeout_ms = 15000,
        .event_sink = .{ .ctx = &events, .callFn = Cab027Sink.call },
    });
    defer report.deinit(a);
    try testing.expect(report.success and !events.blocked);
    const data = try tmp.dir.readFileAlloc(io, "order/launch.json", a, .limited(65536));
    defer a.free(data);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, data, .{});
    defer parsed.deinit();
    const vars = parsed.value.object.get("env").?.object;
    const dedicated = try std.fs.path.join(a, &.{ root, ".devagents", "external-context-opencode" });
    defer a.free(dedicated);
    try testing.expectEqualStrings(dedicated, vars.get("OPENCODE_CONFIG_DIR").?.string);
    try testing.expectEqualStrings("1", vars.get("OPENCODE_DISABLE_CLAUDE_CODE_PROMPT").?.string);
    try testing.expectEqualStrings(custom, env.get("OPENCODE_CONFIG_DIR").?);
    std.debug.print("[CK-CAB-027 r3] custom profile without capabilities launches; dedicated config and prompt isolation preserved\n", .{});
}

test "CK-CAB-027 Codex inseparable globals block before child launch with an explicit event" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "home");
    try tmp.dir.createDirPath(io, "order");
    try tmp.dir.writeFile(io, .{ .sub_path = "home/AGENTS.md", .data = "PERSONAL CONTEXT MUST NOT BE LOADED" });
    const home = try tmp.dir.realPathFileAlloc(io, "home", a);
    defer a.free(home);
    const root = try tmp.dir.realPathFileAlloc(io, "order", a);
    defer a.free(root);
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    try env.put("CODEX_HOME", home);
    var sb = try sandbox.Sandbox.init(a, root);
    defer sb.deinit();
    var events: Cab027Sink = .{};
    const result = run(a, io, makeTask("t", "TASK"), sb, .{
        .profile = CODEX,
        .worktree = root,
        .environ_map = &env,
        .getenv = fakeGetEnv,
        .capture_fn = comp002NoGit,
        .mock_output = "done",
        .event_sink = .{ .ctx = &events, .callFn = Cab027Sink.call },
    });
    if (result) |r| {
        var owned = r;
        owned.deinit(a);
        return error.TestExpectedError;
    } else |e| try testing.expectEqual(error.PersonalContextIsolationUnavailable, e);
    try testing.expect(events.blocked);
}

test "CK-COMP-002 mock CLI persists init resumes per CLI and falls back only on missing session" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    const db = @import("db.zig");
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bin = (try defaultGetEnv(a, "BEATS_TEST_BIN_DIR")) orelse return error.MissingMockBin;
    defer a.free(bin);
    const exe = try std.fs.path.join(a, &.{ bin, "cli-worker-mock" ++ comptime @import("builtin").target.exeFileExt() });
    defer a.free(exe);
    for ([_]CliProfile{ CLAUDE_CODE, CODEX, OPENCODE }) |original| {
        for ([_]?[]const u8{ null, "saved-123", "expired", "quota", "interrupted" }) |id| {
            var tmp = std.testing.tmpDir(.{});
            defer tmp.cleanup();
            const wt = try tmp.dir.realPathFileAlloc(io, ".", a);
            defer a.free(wt);
            var sb = try sandbox.Sandbox.init(a, wt);
            defer sb.deinit();
            var conn = try db.Connection.open(a, ":memory:");
            defer conn.close();
            try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
            var sink = Comp002Sink{ .conn = conn, .key = .{ .order_id = 42, .task_id = "t1", .cli = original.id, .model = "m", .worktree = wt } };
            var profile = original;
            profile.resume_session = id;
            var env = std.process.Environ.Map.init(a);
            defer env.deinit();
            // Claude builds its isolated --settings from the profile
            // home and Codex derives/validates CODEX_HOME; keep the synthetic
            // child independent of the real personal profile.
            try env.put("USERPROFILE", wt);
            try env.put("HOME", wt);
            const interrupted = if (id) |value| std.mem.eql(u8, value, "interrupted") else false;
            const rejected = if (id) |value| std.mem.eql(u8, value, "expired") else false;
            const quota = if (id) |value| std.mem.eql(u8, value, "quota") else false;
            var report = try run(a, io, makeTask("t1", "FULL ORIGINAL TASK CONTRACT AND UPSTREAM"), sb, .{
                .profile = profile,
                .worktree = wt,
                .spawn_prefix = &.{ exe, "--headless", "session", "--mock-cli", original.id },
                .timeout_ms = if (interrupted) 1500 else 15000,
                .environ_map = &env,
                .getenv = fakeGetEnv,
                .capture_fn = comp002NoGit,
                .session_sink = .{ .ctx = &sink, .callFn = Comp002Sink.call },
            });
            defer report.deinit(a);
            try testing.expectEqual(!quota and !interrupted, report.success);
            try testing.expectEqual(interrupted, report.timed_out);
            try testing.expectEqual(@as(usize, if (quota) 0 else 1), sink.saved);
            try testing.expectEqual(@as(usize, if (id != null and !rejected and !quota) 1 else 0), sink.resumed);
            try testing.expectEqual(@as(usize, if (rejected) 1 else 0), sink.restarted);
            if (!quota) {
                const saved = (try external_session.load(a, conn, sink.key)).?;
                defer a.free(saved);
                try testing.expectEqualStrings(if (interrupted) "interrupted" else "saved-123", saved);
            }
            if (report.success) try testing.expectEqualStrings("mock complete", report.declaration);
            if (id != null) {
                const data = try tmp.dir.readFileAlloc(io, "resume-request.json", a, .limited(65536));
                defer a.free(data);
                var p = try std.json.parseFromSlice(std.json.Value, a, data, .{});
                defer p.deinit();
                try testing.expectEqualStrings(CONTINUATION_PROMPT, p.value.object.get("prompt").?.string);
                const args = p.value.object.get("argv").?.array.items;
                const flag = if (std.mem.eql(u8, original.id, "codex")) "resume" else if (std.mem.eql(u8, original.id, "opencode")) "--session" else "--resume";
                var found = false;
                for (args, 0..) |arg, index| {
                    try testing.expect(!std.mem.eql(u8, arg.string, "--ephemeral"));
                    if (std.mem.eql(u8, arg.string, flag)) {
                        try testing.expectEqualStrings(id.?, args[index + 1].string);
                        found = true;
                    }
                }
                try testing.expect(found);
            }
            if (id == null or rejected) {
                const data = try tmp.dir.readFileAlloc(io, "fresh-request.json", a, .limited(65536));
                defer a.free(data);
                var p = try std.json.parseFromSlice(std.json.Value, a, data, .{});
                defer p.deinit();
                // T7: el encargo completo lleva detrás las [REGLAS DEL PROYECTO].
                const fresh_prompt = p.value.object.get("prompt").?.string;
                try testing.expect(std.mem.startsWith(u8, fresh_prompt, "FULL ORIGINAL TASK CONTRACT AND UPSTREAM\n\n" ++ project_rules.HEADER));
            } else try testing.expectError(error.FileNotFound, tmp.dir.openFile(io, "fresh-request.json", .{}));
        }
    }
}

test "CK-COMP-002 invalid session flags and checkpoint failure never silently continue" {
    const a = std.testing.allocator;
    var profile = CLAUDE_CODE;
    profile.resume_session = "--last";
    try testing.expectError(error.InvalidSessionId, buildArgv(a, profile, "wt", "task"));
    var unsupported = GEMINI_CLI;
    unsupported.resume_session = "id";
    try testing.expectError(error.SessionResumeUnsupported, buildArgv(a, unsupported, "wt", "task"));
    var conn = try @import("db.zig").Connection.open(a, ":memory:");
    defer conn.close();
    var sink = Comp002Sink{ .conn = conn, .key = .{ .order_id = 1, .task_id = "t", .cli = "claude-code", .model = "m", .worktree = "wt" }, .fail_write = true };
    var abort = std.atomic.Value(bool).init(false);
    var ctx = LineCtx{ .allocator = a, .mode = .stream_json_lines, .sink = nopSink(), .cli = "claude-code", .abort = &abort, .session_sink = .{ .ctx = &sink, .callFn = Comp002Sink.call } };
    onLine(&ctx, "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"saved-123\"}");
    try testing.expect(ctx.session_error != null);
    try testing.expectEqual(error.CheckpointDiskFailure, ctx.session_error.?);
    try testing.expect(abort.load(.acquire));
}

test "CK-COMP-002 verified profiles persist Codex JSON sessions and pass explicit resume arguments" {
    const a = std.testing.allocator;
    for ([_]CliProfile{ CLAUDE_CODE, CODEX, OPENCODE }) |original| {
        var profile = original;
        profile.resume_session = "saved-123";
        const argv = try buildArgv(a, profile, "wt", "FULL PRIVATE TASK");
        defer a.free(argv);
        var json = false;
        for (argv) |arg| {
            try testing.expect(!std.mem.eql(u8, arg, "--ephemeral"));
            try testing.expect(!std.mem.eql(u8, arg, "FULL PRIVATE TASK"));
            json = json or std.mem.eql(u8, arg, "--json");
        }
        try testing.expectEqualStrings("saved-123", argv[argv.len - 1]);
        try testing.expectEqualStrings(if (std.mem.eql(u8, original.id, "codex")) "resume" else if (std.mem.eql(u8, original.id, "opencode")) "--session" else "--resume", argv[argv.len - 2]);
        if (std.mem.eql(u8, original.id, "codex")) try testing.expect(json);
        try testing.expectEqual(OutputMode.stream_json_lines, original.output_mode);
    }
}

const testing = std.testing;

fn makeTask(id: []const u8, desc: []const u8) planner.PlannedTask {
    return .{
        .id = id,
        .task_type = .programar_c,
        .department = "programacion",
        .description = desc,
        .contract_fields = &.{},
        .depends_on = &.{},
    };
}

test "perfiles verificados: argv por CLI (E5.01)" {
    const allocator = testing.allocator;

    const claude = try buildArgv(allocator, CLAUDE_CODE, "C:\\wt", "haz X");
    defer allocator.free(claude);
    try testing.expectEqualStrings("claude", claude[0]);
    try testing.expectEqualStrings("-p", claude[1]);
    try testing.expectEqualStrings("--output-format", claude[2]);
    try testing.expectEqualStrings("stream-json", claude[3]);
    // --verbose es obligatorio con -p + stream-json (medido en vivo 18-oct:
    // «When using --print, --output-format=stream-json requires --verbose»).
    try testing.expectEqualStrings("--verbose", claude[4]);
    // Sin deny_shell (Auto) Claude Code recibe Bash y subagentes.
    try testing.expectEqualStrings("--allowedTools", claude[claude.len - 2]);
    try testing.expectEqualStrings(CLAUDE_TOOLS_AUTO, claude[claude.len - 1]);
    try testing.expectEqual(PromptChannel.stdin_text, CLAUDE_CODE.prompt_channel);

    const codex = try buildArgv(allocator, CODEX, "C:\\wt", "haz X");
    defer allocator.free(codex);
    try testing.expectEqualStrings("codex", codex[0]);
    try testing.expectEqualStrings("exec", codex[1]);
    // exec -s workspace-write -c approval_policy="never" --json
    // -c project_doc_max_bytes=0 … -C <wt> — el prompt va por stdin
    // (stdin_text), no por argv. añade los cuatro ajustes que
    // separan el contexto personal sin tocar skills/MCP.
    try testing.expectEqualStrings("workspace-write", codex[3]);
    try testing.expectEqualStrings("approval_policy=\"never\"", codex[5]);
    try testing.expectEqualStrings("project_doc_max_bytes=0", codex[11]);
    try testing.expectEqualStrings("memories.use_memories=false", codex[13]);
    try testing.expectEqualStrings("memories.generate_memories=false", codex[15]);
    try testing.expectEqualStrings("developer_instructions=\"\"", codex[17]);
    try testing.expectEqualStrings("-C", codex[codex.len - 2]);
    try testing.expectEqualStrings("C:\\wt", codex[codex.len - 1]);
    try testing.expect(codex.len == 20);

    const gemini = try buildArgv(allocator, GEMINI_CLI, "C:\\wt", "haz X");
    defer allocator.free(gemini);
    try testing.expectEqualStrings("gemini", gemini[0]);
    try testing.expectEqualStrings("stream-json", gemini[gemini.len - 1]);
    try testing.expectEqualStrings("--approval-mode", gemini[1]);
    try testing.expectEqualStrings("yolo", gemini[2]);
    try testing.expectEqual(PromptChannel.stdin_text, GEMINI_CLI.prompt_channel);

    const oc = try buildArgv(allocator, OPENCODE, "C:\\wt", "haz X");
    defer allocator.free(oc);
    try testing.expectEqualStrings("opencode", oc[0]);
    try testing.expectEqualStrings("run", oc[1]);
    try testing.expectEqualStrings("--dir", oc[oc.len - 2]);
    try testing.expectEqualStrings("C:\\wt", oc[oc.len - 1]);
    try testing.expectEqual(PromptChannel.stdin_text, OPENCODE.prompt_channel);

    try testing.expect(profileById("claude-code") != null);
    try testing.expect(profileById("inexistente") == null);
}

var test_env_pairs: []const [2][]const u8 = &.{};

fn fakeGetEnv(allocator: std.mem.Allocator, name: []const u8) anyerror!?[]u8 {
    for (test_env_pairs) |kv| {
        // Vacío cuenta como ausente, igual que defaultGetEnv.
        if (std.mem.eql(u8, kv[0], name) and kv[1].len > 0) return try allocator.dupe(u8, kv[1]);
    }
    return null;
}

test "aviso E5.01 por variables de facturacion presentes" {
    const allocator = testing.allocator;
    test_env_pairs = &.{ .{ "ANTHROPIC_API_KEY", "sk-ant-fake-para-test" }, .{ "OPENAI_API_KEY", "" } };
    var warns = try billingEnvWarnings(allocator, fakeGetEnv);
    defer {
        for (warns.items) |w| allocator.free(w);
        warns.deinit(allocator);
    }
    // Solo ANTHROPIC_API_KEY (valor no vacío) dispara el aviso.
    try testing.expectEqual(@as(usize, 1), warns.items.len);
    try testing.expect(std.mem.indexOf(u8, warns.items[0], "ANTHROPIC_API_KEY") != null);
    // El aviso nunca lleva el valor.
    try testing.expect(std.mem.indexOf(u8, warns.items[0], "sk-ant-fake") == null);
}

test "streaming: linea stream-json de claude -> evento" {
    const allocator = testing.allocator;
    const ev = (try mapLineToEvent(allocator, .stream_json_lines,
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"edito main.c"}]}}
    )).?;
    defer ev.deinit(allocator);
    try testing.expectEqual(EventKind.content, ev.kind);
    try testing.expectEqualStrings("edito main.c", ev.text);

    // --verbose añade system/init antes de assistant/result: se mapea a
    // status y nunca rompe el parseo ni se confunde con contenido.
    const init_ev = (try mapLineToEvent(allocator, .stream_json_lines,
        \\{"type":"system","subtype":"init","cwd":"C:\\wt","session_id":"s1","tools":["Edit","Read","Glob","Grep"]}
    )).?;
    defer init_ev.deinit(allocator);
    try testing.expectEqual(EventKind.status, init_ev.kind);

    const res = (try mapLineToEvent(allocator, .stream_json_lines,
        \\{"type":"result","subtype":"success","result":"hecho: edite main.c"}
    )).?;
    defer res.deinit(allocator);
    try testing.expectEqual(EventKind.result, res.kind);
    try testing.expectEqualStrings("hecho: edite main.c", res.text);

    // Línea no-JSON: evento raw, nunca error.
    const raw = (try mapLineToEvent(allocator, .stream_json_lines, "prosa suelta del cli")).?;
    defer raw.deinit(allocator);
    try testing.expectEqual(EventKind.raw, raw.kind);
    try testing.expectEqualStrings("prosa suelta del cli", raw.text);

    // Modo texto: cada línea es contenido.
    const t = (try mapLineToEvent(allocator, .text, "codex: applying patch")).?;
    defer t.deinit(allocator);
    try testing.expectEqual(EventKind.content, t.kind);
}

test "declaracion: ultimo result del stream; texto -> cola" {
    const allocator = testing.allocator;
    const transcript =
        \\{"type":"system","subtype":"init","cwd":"C:\\wt","session_id":"s1"}
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"voy a editar"}]}}
        \\{"type":"result","subtype":"success","result":"cree f.c con la funcion"}
        \\
    ;
    const d = try extractDeclaration(allocator, .stream_json_lines, transcript);
    defer allocator.free(d);
    try testing.expectEqualStrings("cree f.c con la funcion", d);

    const d2 = try extractDeclaration(allocator, .text, "linea1\nlinea2\nultima declaracion\n");
    defer allocator.free(d2);
    try testing.expect(std.mem.indexOf(u8, d2, "ultima declaracion") != null);
}

test "streaming: eventos no textuales del stream-json -> status sin JSON crudo (r5)" {
    const allocator = testing.allocator;

    // assistant con solo tool_use (sin texto): nunca contenido con JSON crudo.
    const tool_only = (try mapLineToEvent(allocator, .stream_json_lines,
        \\{"type":"assistant","message":{"id":"msg_1","content":[{"type":"tool_use","id":"tu_1","name":"Read","input":{"file_path":"f.c"}}]}}
    )).?;
    defer tool_only.deinit(allocator);
    try testing.expectEqual(EventKind.status, tool_only.kind);
    try testing.expectEqualStrings("", tool_only.text);

    // rate_limit_event (forma real medida en la orden #891): status, sin JSON.
    const rate = (try mapLineToEvent(allocator, .stream_json_lines,
        \\{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}
    )).?;
    defer rate.deinit(allocator);
    try testing.expectEqual(EventKind.status, rate.kind);
    try testing.expectEqualStrings("", rate.text);

    // user/tool_result: status, sin volcar el JSON crudo.
    const tool_res = (try mapLineToEvent(allocator, .stream_json_lines,
        \\{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"tu_1","content":"salida"}]}}
    )).?;
    defer tool_res.deinit(allocator);
    try testing.expectEqual(EventKind.status, tool_res.kind);
    try testing.expect(std.mem.indexOf(u8, tool_res.text, "tu_1") == null);

    // system distinto de init: status, sin JSON crudo.
    const sys = (try mapLineToEvent(allocator, .stream_json_lines,
        \\{"type":"system","subtype":"compact_boundary"}
    )).?;
    defer sys.deinit(allocator);
    try testing.expectEqual(EventKind.status, sys.kind);
    try testing.expectEqualStrings("", sys.text);

    // assistant CON texto sigue siendo contenido.
    const with_text = (try mapLineToEvent(allocator, .stream_json_lines,
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"edito f.c"}]}}
    )).?;
    defer with_text.deinit(allocator);
    try testing.expectEqual(EventKind.content, with_text.kind);
    try testing.expectEqualStrings("edito f.c", with_text.text);
}

test "declaracion: el ultimo result manda sobre eventos posteriores del stream (r5)" {
    const allocator = testing.allocator;
    // Transcript real de claude con --verbose: el rate_limit_event y un
    // assistant/tool_use llegan DESPUÉS del result y no deben pisarlo (#891).
    const transcript =
        \\{"type":"system","subtype":"init","session_id":"s1"}
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_1","name":"Read","input":{"file_path":"f.c"}}]}}
        \\{"type":"result","subtype":"success","result":"cree f.c con la funcion"}
        \\{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_2","name":"Edit","input":{}}]}}
        \\
    ;
    const d = try extractDeclaration(allocator, .stream_json_lines, transcript);
    defer allocator.free(d);
    try testing.expectEqualStrings("cree f.c con la funcion", d);

    // Sin ningún result: manda el último content con texto real.
    const no_result =
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_1","name":"Read"}]}}
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"texto anterior"}]}}
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"texto final"}]}}
        \\{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}
        \\
    ;
    const d2 = try extractDeclaration(allocator, .stream_json_lines, no_result);
    defer allocator.free(d2);
    try testing.expectEqualStrings("texto final", d2);
}

test "declaracion: stream solo con eventos sin texto -> sin JSON crudo (r6)" {
    const allocator = testing.allocator;
    // Transcript de SOLO metadatos del stream (el caso límite de la auditoría
    // r5): ni result ni content con texto. La ruta de reserva no puede volcar
    // estas líneas JSON como declaración; queda vacía.
    const solo_json =
        \\{"type":"system","subtype":"init","session_id":"s1"}
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_1","name":"Read","input":{"file_path":"f.c"}}]}}
        \\{"type":"rate_limit_event","rate_limit_info":{"status":"allowed"}}
        \\
    ;
    const d = try extractDeclaration(allocator, .stream_json_lines, solo_json);
    defer allocator.free(d);
    try testing.expectEqualStrings("", d);

    // El modo texto plano conserva su comportamiento: la cola es la
    // declaración (aquí no hay JSON que volcar).
    const t = try extractDeclaration(allocator, .text, "linea suelta del cli");
    defer allocator.free(t);
    try testing.expectEqualStrings("linea suelta del cli", t);
}

test "streaming: assistant con text y tool_use conserva el texto (r6)" {
    const allocator = testing.allocator;
    // Cobertura del hueco que señaló la auditoría r5: un assistant que MEZCLA
    // bloques text y tool_use no pierde el texto real.
    const ev = (try mapLineToEvent(allocator, .stream_json_lines,
        \\{"type":"assistant","message":{"content":[{"type":"tool_use","id":"tu_1","name":"Edit","input":{}},{"type":"text","text":"edite f.c"}]}}
    )).?;
    defer ev.deinit(allocator);
    try testing.expectEqual(EventKind.content, ev.kind);
    try testing.expectEqualStrings("edite f.c", ev.text);

    const transcript =
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"edite f.c"},{"type":"tool_use","id":"tu_1","name":"Edit","input":{}}]}}
        \\
    ;
    const d = try extractDeclaration(allocator, .stream_json_lines, transcript);
    defer allocator.free(d);
    try testing.expectEqualStrings("edite f.c", d);
}

test "transcripcion censurada: patrones + valor exacto de env" {
    const allocator = testing.allocator;
    test_env_pairs = &.{.{ "ANTHROPIC_API_KEY", "sk-ant-VALORSECRETO123" }};
    const raw = "Authorization: Bearer tok123\nel cli ecoa sk-ant-VALORSECRETO123 en el log\n";
    const out = try censorTranscript(allocator, raw, fakeGetEnv);
    defer allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "sk-ant-VALORSECRETO123") == null);
    try testing.expect(std.mem.indexOf(u8, out, "tok123") == null);
}

// ── Seams git para pruebas (mismo patrón que ship_flow) ──────────────────

var script_entries: []const [2][]const u8 = &.{}; // {substring argv unido, stdout}

fn scriptedCapture(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) anyerror!gh.CmdCapture {
    for (argv) |arg| if (std.mem.eql(u8, arg, "--show-toplevel")) {
        return .{ .exit_code = 0, .stdout = try allocator.dupe(u8, cwd orelse ""), .stderr = try allocator.dupe(u8, "") };
    };
    var joined = std.ArrayList(u8).empty;
    defer joined.deinit(allocator);
    for (argv, 0..) |a, i| {
        if (i > 0) try joined.append(allocator, ' ');
        try joined.appendSlice(allocator, a);
    }
    for (script_entries) |e| {
        if (std.mem.indexOf(u8, joined.items, e[0]) != null) {
            return .{
                .exit_code = 0,
                .stdout = try allocator.dupe(u8, e[1]),
                .stderr = try allocator.dupe(u8, ""),
            };
        }
    }
    return .{
        .exit_code = 0,
        .stdout = try allocator.dupe(u8, ""),
        .stderr = try allocator.dupe(u8, ""),
    };
}

fn writeFile(io: std.Io, dir: std.Io.Dir, rel: []const u8, data: []const u8) !void {
    try dir.writeFile(io, .{ .sub_path = rel, .data = data });
}

fn failingCapture(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) anyerror!gh.CmdCapture {
    _ = argv;
    _ = cwd;
    return .{ .exit_code = 1, .stdout = try allocator.dupe(u8, ""), .stderr = try allocator.dupe(u8, "") };
}

test "artefactos del diff: name-only + untracked, contenido del worktree" {
    const allocator = testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "modificado.c", "int x = 2;");
    try writeFile(io, tmp.dir, "nuevo.txt", "nuevo");
    const wt = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(wt);

    script_entries = &.{
        .{ "diff --name-only", "modificado.c\x00" },
        .{ "ls-files --others", "nuevo.txt\x00" },
    };
    defer script_entries = &.{};

    var sb = try sandbox.Sandbox.init(allocator, wt);
    defer sb.deinit();

    const arts = try collectDiffArtifacts(allocator, io, scriptedCapture, wt, "base123", sb);
    defer {
        for (arts) |*a| a.deinit(allocator);
        allocator.free(arts);
    }
    try testing.expectEqual(@as(usize, 2), arts.len);
    try testing.expectEqualStrings("modificado.c", arts[0].path);
    try testing.expectEqualStrings("int x = 2;", arts[0].content);
    try testing.expectEqualStrings("nuevo.txt", arts[1].path);
}

test "E-GOV.2: cache de Go excluida solo de untracked y no consume la cota" {
    const a = testing.allocator;
    try testing.expect(!generatedCachePath(".cache/go-build/legitimate.go"));
    try testing.expect(generatedCachePath(".cache/go-build/03/03" ++ "a" ** 62 ++ "-d"));
    try testing.expect(generatedCachePath(".CACHE\\GO-BUILD\\03\\03" ++ "a" ** 62 ++ "-a"));
    try testing.expect(!generatedCachePath(".cache/source.go"));
    try testing.expect(!generatedCachePath("cache/go-build/03/cache-d"));
    try testing.expect(!generatedCachePath(".cache/go-build/03/" ++ "a" ** 64 ++ "-d"));
    try testing.expect(!generatedCachePath(".cache/go-build/03/03" ++ "a" ** 62 ++ "-d/source.go"));
    try testing.expect(!generatedCachePath(".cache/go-build/03/03" ++ "a" ** 62 ++ "-x"));
    try testing.expect(!generatedCachePath(".cache/go-build/03/03" ++ "z" ** 62 ++ "-d"));
    try testing.expect(!generatedCachePath(".cache/go-build"));
    try testing.expect(!generatedCachePath(".cache/go-build/03"));

    var paths: std.ArrayList([]const u8) = .empty;
    defer {
        for (paths.items) |path| a.free(path);
        paths.deinit(a);
    }
    var output: std.Io.Writer.Allocating = .init(a);
    defer output.deinit();
    for (0..SNAPSHOT_ENTRY_CAP + 1) |i| try output.writer.print(".cache/go-build/00/{x:0>64}-d\x00", .{i});
    script_entries = &.{.{ "ls-files --others", output.written() }};
    defer script_entries = &.{};
    try appendGitLines(a, &paths, scriptedCapture, ".", &.{ "git", "ls-files", "--others", "--exclude-standard", "-z" });
    try testing.expectEqual(@as(usize, 0), paths.items.len);

    script_entries = &.{.{ "diff --name-only", ".cache/go-build/tracked.go\x00" }};
    try appendGitLines(a, &paths, scriptedCapture, ".", &.{ "git", "diff", "--name-only", "-z", "base" });
    try testing.expectEqual(@as(usize, 1), paths.items.len);

    script_entries = &.{.{ "ls-files --others", ".cache/go-build/legitimate.go\x00" }};
    try appendGitLines(a, &paths, scriptedCapture, ".", &.{ "git", "ls-files", "--others", "--exclude-standard", "-z" });
    try testing.expectEqual(@as(usize, 2), paths.items.len);
    // appendGitLines normaliza a `\` las rutas que guarda (comportamiento ya
    // existente en main); el filtro de cache debe dejar pasar la ruta legitima.
    try testing.expectEqualStrings(".cache\\go-build\\legitimate.go", paths.items[1]);

    output.clearRetainingCapacity();
    for (0..SNAPSHOT_ENTRY_CAP + 1) |i| try output.writer.print("source-{d}.go\x00", .{i});
    script_entries = &.{.{ "ls-files --others", output.written() }};
    try testing.expectError(error.TooManyFiles, appendGitLines(a, &paths, scriptedCapture, ".", &.{ "git", "ls-files", "--others", "--exclude-standard", "-z" }));
}

test "E-GOV.2: la cache de Go no entra en la linea base del espacio" {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, ".cache/go-build/03");
    try writeFile(io, tmp.dir, ".cache/go-build/03/03" ++ "a" ** 62 ++ "-d", "cache");
    try writeFile(io, tmp.dir, "main.go", "package main\n");
    const wt = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(wt);
    var baseline = try captureArtifactBaseline(a, io, failingCapture, wt, null);
    defer baseline.deinit(a);
    var found = false;
    for (baseline.entries) |entry| {
        try testing.expect(!generatedCachePath(entry.path));
        if (std.ascii.eqlIgnoreCase(entry.path, "main.go")) found = true;
    }
    try testing.expect(found);
}

test "E-GOV.1: la linea base aporta huellas y solo falla la omision nueva" {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "lib.py", "# TODO: inherited\nprint(1)\n");
    const wt = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(wt);
    var baseline = try captureArtifactBaseline(a, io, failingCapture, wt, null);
    defer baseline.deinit(a);
    var sb = try sandbox.Sandbox.init(a, wt);
    defer sb.deinit();

    try writeFile(io, tmp.dir, "lib.py", "# TODO: inherited\n# TODO: new\nprint(2)\n");
    const changed = try collectArtifactChanges(a, io, scriptedCapture, wt, baseline, sb);
    defer {
        for (changed) |*art| art.deinit(a);
        a.free(changed);
    }
    try testing.expectEqual(@as(usize, 1), changed.len);
    try testing.expect(changed[0].inherited_placeholders != null);
    try testing.expectEqual(@as(usize, 1), changed[0].inherited_placeholders.?.len);
    try testing.expect(artifact_quality.invalidReason(changed[0].path, changed[0].content, changed[0].inherited_placeholders) != null);

    try writeFile(io, tmp.dir, "lib.py", "# TODO: inherited\nprint(3)\n");
    const kept = try collectArtifactChanges(a, io, scriptedCapture, wt, baseline, sb);
    defer {
        for (kept) |*art| art.deinit(a);
        a.free(kept);
    }
    try testing.expectEqual(@as(usize, 1), kept.len);
    try testing.expect(artifact_quality.invalidReason(kept[0].path, kept[0].content, kept[0].inherited_placeholders) == null);
}

test "E-GOV.1: el diff toma la procedencia del commit base" {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try writeFile(io, tmp.dir, "lib.py", "# TODO: inherited\nprint(2)\n");
    const wt = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(wt);
    var sb = try sandbox.Sandbox.init(a, wt);
    defer sb.deinit();
    script_entries = &.{
        .{ "diff --name-only", "lib.py\x00" },
        .{ "show base123:lib.py", "# TODO: inherited\nprint(1)\n" },
    };
    defer script_entries = &.{};
    const arts = try collectDiffArtifacts(a, io, scriptedCapture, wt, "base123", sb);
    defer {
        for (arts) |*art| art.deinit(a);
        a.free(arts);
    }
    try testing.expectEqual(@as(usize, 1), arts.len);
    try testing.expect(arts[0].inherited_placeholders != null);
    try testing.expectEqual(@as(usize, 1), arts[0].inherited_placeholders.?.len);
    try testing.expect(artifact_quality.invalidReason(arts[0].path, arts[0].content, arts[0].inherited_placeholders) == null);

    try writeFile(io, tmp.dir, "lib.py", "# TODO: inherited\n# TODO: added\nprint(2)\n");
    script_entries = &.{
        .{ "diff --name-only", "lib.py\x00" },
        .{ "show base123:lib.py", "# TODO: inherited\nprint(1)\n" },
    };
    const added = try collectDiffArtifacts(a, io, scriptedCapture, wt, "base123", sb);
    defer {
        for (added) |*art| art.deinit(a);
        a.free(added);
    }
    try testing.expectEqual(@as(usize, 1), added.len);
    try testing.expect(artifact_quality.invalidReason(added[0].path, added[0].content, added[0].inherited_placeholders) != null);
}

test "RELOJ artefactos del diff: ruta fuera del worktree -> SandboxDenied" {
    const allocator = testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const wt = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(wt);

    // Un git comprometido/bugado devuelve una ruta que escapa del worktree.
    script_entries = &.{.{ "diff --name-only", "..\\escape.txt\x00" }};
    defer script_entries = &.{};

    var sb = try sandbox.Sandbox.init(allocator, wt);
    defer sb.deinit();

    try testing.expectError(error.SandboxDenied, collectDiffArtifacts(allocator, io, scriptedCapture, wt, "base123", sb));
}

test "recordBaseCommit: sha del rev-parse" {
    const allocator = testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(threaded.io(), ".", allocator);
    defer allocator.free(root);
    script_entries = &.{.{ "rev-parse HEAD", "abc123def\n" }};
    defer script_entries = &.{};
    const sha = try recordBaseCommit(allocator, scriptedCapture, root);
    defer allocator.free(sha);
    try testing.expectEqualStrings("abc123def", sha);
}

test "E5.20 E-127: git de un repo padre real no es git del espacio" {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "foreign");
    defer tmp.deinit(a, io);
    const parent = tmp.path;
    const base = (try gitInitWorktree(a, io, parent)) orelse return error.TestUnexpectedResult;
    defer a.free(base);
    try writeFile(io, tmp.dir, ".gitignore", "space/\n");
    try writeFile(io, tmp.dir, "base.txt", "changed parent");
    try tmp.dir.createDirPath(io, "space/src");
    const space = try tmp.dir.realPathFileAlloc(io, "space", a);
    defer a.free(space);
    var sb = try sandbox.Sandbox.init(a, space);
    defer sb.deinit();
    // El defecto devuelve base.txt del padre (contenido vacío al leerlo en space).
    if (collectDiffArtifacts(a, io, defaultCapture, space, base, sb)) |arts| {
        defer {
            for (arts) |*art| art.deinit(a);
            a.free(arts);
        }
        for (arts) |art| std.debug.print("E-127 FOREIGN_ARTIFACT={s} bytes={d}\n", .{ art.path, art.content.len });
        return error.TestUnexpectedResult;
    } else |e| try testing.expectEqual(error.GitFailed, e);

    var baseline = try captureArtifactBaseline(a, io, defaultCapture, space, base);
    defer baseline.deinit(a);
    try testing.expect(baseline.git_commit == null);
    var child = try std.Io.Dir.cwd().openDir(io, space, .{});
    defer child.close(io);
    try writeFile(io, child, "src/encoding.py", "real source");
    const changes = try collectArtifactChanges(a, io, defaultCapture, space, baseline, sb);
    defer {
        for (changes) |*art| art.deinit(a);
        a.free(changes);
    }
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqualStrings("src" ++ std.fs.path.sep_str ++ "encoding.py", changes[0].path);
    try testing.expectEqualStrings("real source", changes[0].content);
}

test "E5.20 E-127: snapshot SHA detecta misma longitud, alta y borrado; excluye .beats" {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "snapshot");
    defer tmp.deinit(a, io);
    try writeFile(io, tmp.dir, "same.txt", "aaaa");
    try writeFile(io, tmp.dir, "unchanged.txt", "keep");
    try writeFile(io, tmp.dir, "deleted.txt", "bye");
    try tmp.dir.createDirPath(io, ".beats/hidden");
    try writeFile(io, tmp.dir, ".beats/hidden/private.txt", "internal");
    var baseline = try captureArtifactBaseline(a, io, defaultCapture, tmp.path, null);
    defer baseline.deinit(a);
    try testing.expectEqual(@as(usize, 3), baseline.entries.len);
    try writeFile(io, tmp.dir, "same.txt", "bbbb");
    try writeFile(io, tmp.dir, "new.txt", "new");
    try tmp.dir.deleteFile(io, "deleted.txt");
    try writeFile(io, tmp.dir, ".beats/hidden/private.txt", "changed internal");
    var sb = try sandbox.Sandbox.init(a, tmp.path);
    defer sb.deinit();
    const changes = try collectArtifactChanges(a, io, defaultCapture, tmp.path, baseline, sb);
    defer {
        for (changes) |*art| art.deinit(a);
        a.free(changes);
    }
    try testing.expectEqual(@as(usize, 3), changes.len);
    try testing.expectEqualStrings("deleted.txt", changes[0].path);
    try testing.expectEqualStrings("", changes[0].content);
    try testing.expectEqualStrings("new.txt", changes[1].path);
    try testing.expectEqualStrings("same.txt", changes[2].path);
    try testing.expectEqualStrings("bbbb", changes[2].content);
    // La enumeración recursiva también consume los handles validados, sin
    // resolver otra vez el nombre del directorio con walker.enter.
    try tmp.dir.createDirPath(io, "nested/deep");
    try writeFile(io, tmp.dir, "nested/deep/result.txt", "nested before");
    var nested_baseline = try captureArtifactBaseline(a, io, defaultCapture, tmp.path, null);
    defer nested_baseline.deinit(a);
    try testing.expectEqual(@as(usize, 4), nested_baseline.entries.len);
    try writeFile(io, tmp.dir, "nested/deep/result.txt", "nested after");
    const nested_changes = try collectArtifactChanges(a, io, defaultCapture, tmp.path, nested_baseline, sb);
    defer {
        for (nested_changes) |*art| art.deinit(a);
        a.free(nested_changes);
    }
    try testing.expectEqual(@as(usize, 1), nested_changes.len);
    try testing.expectEqualStrings("nested after", nested_changes[0].content);
}

test "E5.20 E-127: snapshot no sigue junction y rechaza alias de raíz" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: crea junctions con cmd.exe mklink /J (Windows); en Linux los enlaces los rechaza confined_posix y lo prueba su propia prueba");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "junction");
    defer tmp.deinit(a, io);
    try tmp.dir.createDirPath(io, "space");
    try tmp.dir.createDirPath(io, "outside");
    try writeFile(io, tmp.dir, "outside/foreign.txt", "outside");
    const space = try tmp.dir.realPathFileAlloc(io, "space", a);
    defer a.free(space);
    const outside = try tmp.dir.realPathFileAlloc(io, "outside", a);
    defer a.free(outside);
    const link = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "link", .{space});
    defer a.free(link);
    var mk = try defaultCapture(a, &.{ "cmd.exe", "/d", "/c", "mklink", "/J", link, outside }, null);
    defer mk.deinit(a);
    try testing.expectEqual(@as(u32, 0), mk.exit_code);
    defer tmp.dir.deleteDir(io, "space/link") catch |e| std.debug.print("junction cleanup: {s}\n", .{@errorName(e)});
    // El iterador también clasifica junctions como enlaces. Probar la guardia
    // directamente asegura el control negativo aunque esa segunda defensa siga viva.
    try testing.expect(!try regularChain(a, space, "link/foreign.txt"));
    var baseline = try captureArtifactBaseline(a, io, defaultCapture, space, null);
    defer baseline.deinit(a);
    try testing.expectEqual(@as(usize, 0), baseline.entries.len);
    const base = (try gitInitWorktree(a, io, outside)) orelse return error.TestUnexpectedResult;
    defer a.free(base);
    try testing.expectError(error.SandboxDenied, gitRootMatches(a, defaultCapture, link));
    try testing.expectError(error.SandboxDenied, captureArtifactBaseline(a, io, defaultCapture, link, null));
    try testing.expectError(error.FileNotFound, captureArtifactBaseline(a, io, defaultCapture, "Z:\\missing-e520-space", null));
}

test "E5.20 E-127 ronda2: sustitucion por junction entre validacion y lectura" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: crea junctions con cmd.exe mklink /J (Windows); en Linux los enlaces los rechaza confined_posix y lo prueba su propia prueba");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "handle-race");
    defer tmp.deinit(a, io);
    try tmp.dir.createDirPath(io, "space/child");
    try tmp.dir.createDirPath(io, "outside");
    try writeFile(io, tmp.dir, "space/child/result.txt", "inside");
    try writeFile(io, tmp.dir, "outside/result.txt", "foreign bytes must never be read");
    const space = try tmp.dir.realPathFileAlloc(io, "space", a);
    defer a.free(space);
    const outside = try tmp.dir.realPathFileAlloc(io, "outside", a);
    defer a.free(outside);
    const link = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "child", .{space});
    defer a.free(link);
    var safe = try artifactRoot(a, space);
    defer safe.deinit();
    // Costura determinista de la ventana antigua: la ruta pasa la comprobacion,
    // otro proceso la sustituye, y SOLO entonces se pide leer el artefacto.
    try testing.expect(try regularChain(a, space, "child/result.txt"));
    try tmp.dir.rename("space/child", tmp.dir, "space/saved", io);
    var mk = try defaultCapture(a, &.{ "cmd.exe", "/d", "/c", "mklink", "/J", link, outside }, null);
    defer mk.deinit(a);
    try testing.expectEqual(@as(u32, 0), mk.exit_code);
    defer tmp.dir.deleteDir(io, "space/child") catch |e| std.debug.print("race junction cleanup: {s}\n", .{@errorName(e)});
    try testing.expectError(error.SandboxDenied, readArtifactContent(a, io, &safe, "child/result.txt"));
}

test "E5.20 E-127 ronda2: contenido regular binario borrado y lectura de directorio" {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "read-handles");
    defer tmp.deinit(a, io);
    try writeFile(io, tmp.dir, "binary", "\xff\x01");
    try tmp.dir.createDirPath(io, "directory");
    var safe = try artifactRoot(a, tmp.path);
    defer safe.deinit();
    const binary = try readArtifactContent(a, io, &safe, "binary");
    defer a.free(binary);
    try testing.expectEqualStrings("(artefacto binario, 2 bytes)", binary);
    const deleted = try readArtifactContent(a, io, &safe, "deleted");
    defer a.free(deleted);
    try testing.expectEqualStrings("", deleted);
    try testing.expectError(error.SandboxDenied, readArtifactContent(a, io, &safe, "directory"));
}

test "E5.20 E-127: artefacto sobre 1 MiB y árbol sobre 10000 entradas fallan explícitos" {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "caps");
    defer tmp.deinit(a, io);
    var baseline = try captureArtifactBaseline(a, io, defaultCapture, tmp.path, null);
    defer baseline.deinit(a);
    const body = try a.alloc(u8, ARTIFACT_CONTENT_CAP + 1);
    defer a.free(body);
    @memset(body, 'x');
    try writeFile(io, tmp.dir, "large.txt", body);
    var sb = try sandbox.Sandbox.init(a, tmp.path);
    defer sb.deinit();
    if (collectArtifactChanges(a, io, defaultCapture, tmp.path, baseline, sb)) |arts| {
        defer {
            for (arts) |*art| art.deinit(a);
            a.free(arts);
        }
        return error.TestUnexpectedResult;
    } else |e| try testing.expectEqual(error.ArtifactTooLarge, e);
    try tmp.dir.deleteFile(io, "large.txt");
    for (0..SNAPSHOT_ENTRY_CAP + 1) |i| {
        var name: [32]u8 = undefined;
        try writeFile(io, tmp.dir, try std.fmt.bufPrint(&name, "f{d}", .{i}), "");
    }
    if (captureArtifactBaseline(a, io, defaultCapture, tmp.path, null)) |value| {
        var unexpected = value;
        defer unexpected.deinit(a);
        return error.TestUnexpectedResult;
    } else |e| try testing.expectEqual(error.TooManyFiles, e);
    for (0..SNAPSHOT_ENTRY_CAP + 1) |i| {
        var name: [32]u8 = undefined;
        try tmp.dir.deleteFile(io, try std.fmt.bufPrint(&name, "f{d}", .{i}));
    }
    var large = try tmp.dir.createFile(io, "large", .{});
    defer large.close(io);
    try large.setLength(io, SNAPSHOT_BYTE_CAP + 1);
    if (captureArtifactBaseline(a, io, defaultCapture, tmp.path, null)) |value| {
        var unexpected = value;
        defer unexpected.deinit(a);
        return error.TestUnexpectedResult;
    } else |e| try testing.expectEqual(error.SnapshotTooLarge, e);
}

fn failedCapture(_: std.mem.Allocator, _: []const []const u8, _: ?[]const u8) anyerror!gh.CmdCapture {
    return error.SpawnFailed;
}

test "E5.20 E-127: fallo de captura y sustitución de raíz abortan sin artefactos" {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var one = try tempTree(a, io, "one");
    defer one.deinit(a, io);
    var two = try tempTree(a, io, "two");
    defer two.deinit(a, io);
    try testing.expectError(error.GitFailed, gitRootMatches(a, failedCapture, one.path));
    try testing.expectError(error.GitFailed, recordBaseCommit(a, failedCapture, one.path));
    try testing.expectError(error.GitFailed, captureArtifactBaseline(a, io, failedCapture, one.path, null));
    var baseline = try captureArtifactBaseline(a, io, defaultCapture, one.path, null);
    defer baseline.deinit(a);
    var sb = try sandbox.Sandbox.init(a, two.path);
    defer sb.deinit();
    if (collectArtifactChanges(a, io, defaultCapture, two.path, baseline, sb)) |arts| {
        defer {
            for (arts) |*art| art.deinit(a);
            a.free(arts);
        }
        return error.TestUnexpectedResult;
    } else |e| try testing.expectEqual(error.SandboxDenied, e);
}

test "E5.20 E-127 RELOJ: proceso headless real sobre carpeta sin git recoge la edición" {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "headless");
    defer tmp.deinit(a, io);
    const bin = (try defaultGetEnv(a, "BEATS_TEST_BIN_DIR")) orelse try a.dupe(u8, TEST_BIN_DIR);
    defer a.free(bin);
    const exe = try std.fs.path.join(a, &.{ bin, "cli-worker-mock" ++ comptime @import("builtin").target.exeFileExt() });
    defer a.free(exe);
    var sb = try sandbox.Sandbox.init(a, tmp.path);
    defer sb.deinit();
    var report = try run(a, io, makeTask("nongit", "edit"), sb, .{
        .profile = .{ .id = "mock", .exe = exe, .argv_prefix = &.{"--headless"}, .prompt_channel = .argv_tail, .output_mode = .stream_json_lines, .permission_note = "mock", .turn_cap_note = "mock" },
        .worktree = tmp.path,
        .getenv = fakeGetEnv,
        .timeout_ms = 30000,
    });
    defer report.deinit(a);
    try testing.expect(report.success);
    try testing.expectEqual(@as(usize, 1), report.artifacts.len);
    try testing.expectEqualStrings("mock_edit.txt", report.artifacts[0].path);
    try testing.expectEqualStrings("editado por cli-worker-mock\n", report.artifacts[0].content);
}

// ── Integración contra cli-worker-mock.exe real ────────────────────

// 8-nov: apuntaba a los binarios de DevAgents (congelado y fuera de este equipo
// en adelante); Angel prueba sus propios binarios.
// 9-nov: relativo a la raíz del repo (cwd de `zig build test`), sin ruta
// absoluta del equipo del propietario (repo público,).
const TEST_BIN_DIR = "zig-out\\bin";

test "RELOJ Codex argv keeps stdin workspace sandbox and allows a non Git root" {
    const a = testing.allocator;
    const argv = try buildArgv(a, CODEX, "C:\\clock", "private prompt");
    defer a.free(argv);
    try testing.expectEqual(PromptChannel.stdin_text, CODEX.prompt_channel);
    try testing.expectEqualStrings("workspace-write", argv[3]);
    try testing.expectEqualStrings("-C", argv[argv.len - 2]);
    try testing.expectEqualStrings("C:\\clock", argv[argv.len - 1]);
    var skip_git = false;
    var chatgpt = false;
    for (argv) |arg| {
        skip_git = skip_git or std.mem.eql(u8, arg, "--skip-git-repo-check");
        chatgpt = chatgpt or std.mem.eql(u8, arg, "forced_login_method=\"chatgpt\"");
        try testing.expect(!std.mem.eql(u8, arg, "private prompt"));
    }
    try testing.expect(skip_git);
    try testing.expect(chatgpt);
}

test "RELOJ Codex run with null environment filters the real child" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "codex-null-env");
    defer tmp.deinit(a, io);
    const node = try @import("executor.zig").resolveAllowedExeExt(a, "node", ".exe");
    defer a.free(node);
    const script = try writeTestScript(a, io, tmp.dir, "require('fs').readFileSync(0,'utf8');if(process.env.OPENAI_API_KEY||process.env.CODEX_API_KEY)process.exit(3);if(!process.env.CODEX_HOME)process.exit(4);console.log('RELOJ_NULL_ENV_KEYS_ABSENT=true');");
    defer a.free(script);
    var sb = try sandbox.Sandbox.init(a, tmp.path);
    defer sb.deinit();
    // este caso mide el filtrado del entorno real, no el bloqueo
    // de AGENTS globales; la herencia explícita conserva el filtrado de claves.
    var profile = CODEX;
    profile.inherit_personal_context = true;
    var report = try run(a, io, makeTask("null-env", "check child environment"), sb, .{
        .profile = profile,
        .spawn_prefix = &.{ node, script },
        .environ_map = null,
        .worktree = tmp.path,
        .getenv = fakeGetEnv,
        .timeout_ms = 30000,
    });
    defer report.deinit(a);
    try testing.expect(report.success);
    try testing.expectEqual(@as(?u8, 0), report.exit_code);
    try testing.expect(std.mem.indexOf(u8, report.transcript, "RELOJ_NULL_ENV_KEYS_ABSENT=true") != null);
    for (report.env_warnings) |warning| {
        try testing.expect(std.mem.indexOf(u8, warning, "OPENAI_API_KEY") == null);
        try testing.expect(std.mem.indexOf(u8, warning, "CODEX_API_KEY") == null);
    }
}

test "RELOJ Codex profile creates a real file and snapshot in a non Git root with a mock process" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "codex-clock");
    defer tmp.deinit(a, io);
    const bin = (try defaultGetEnv(a, "BEATS_TEST_BIN_DIR")) orelse return error.MissingMockBin;
    defer a.free(bin);
    const exe = try std.fs.path.join(a, &.{ bin, "cli-worker-mock" ++ comptime @import("builtin").target.exeFileExt() });
    defer a.free(exe);
    var parent = std.process.Environ.Map.init(a);
    defer parent.deinit();
    try parent.put("CODEX_HOME", tmp.path);
    try parent.put("OPENAI_API_KEY", "synthetic");
    try parent.put("CODEX_API_KEY", "synthetic");
    var child = try @import("external_cli_policy.zig").codexEnvironment(a, &parent);
    defer child.deinit();
    var sb = try sandbox.Sandbox.init(a, tmp.path);
    defer sb.deinit();
    var report = try run(a, io, makeTask("clock", "write the clock"), sb, .{
        .profile = CODEX,
        .spawn_prefix = &.{ exe, "--headless", "clock" },
        .environ_map = &child,
        .worktree = tmp.path,
        .getenv = fakeGetEnv,
        .timeout_ms = 30000,
    });
    defer report.deinit(a);
    try testing.expect(report.success);
    try testing.expectEqual(@as(usize, 1), report.artifacts.len);
    try testing.expectEqualStrings("reloj.py", report.artifacts[0].path);
    try testing.expectEqualStrings("print('reloj-simulado')\n", report.artifacts[0].content);
    try testing.expectError(error.FileNotFound, tmp.dir.openDir(io, ".git", .{}));
    try testing.expect(report.env_warnings.len == 0);
}

test "RELOJ SNAP external CLI restores exact root SDDL on success error timeout and cancellation" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: SDDL y ACE de Windows; los permisos del espacio de trabajo no existen en Linux (WorkspacePermissionsUnavailableOnLinux)");
    const Cancel = struct {
        events: *CollectSink,
        flag: *std.atomic.Value(bool),
        fn event(raw: *anyopaque, kind: EventKind, text: []const u8) void {
            const self: *@This() = @ptrCast(@alignCast(raw));
            CollectSink.onEvent(self.events, kind, text);
            if (std.mem.indexOf(u8, text, "ACE added") != null) self.flag.store(true, .release);
        }
        fn check(raw: ?*anyopaque) bool {
            const flag: *std.atomic.Value(bool) = @ptrCast(@alignCast(raw.?));
            return flag.load(.acquire);
        }
    };
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();
    const bin = (try defaultGetEnv(a, "BEATS_TEST_BIN_DIR")) orelse return error.MissingMockBin;
    defer a.free(bin);
    const exe = try std.fs.path.join(a, &.{ bin, "cli-worker-mock" ++ comptime @import("builtin").target.exeFileExt() });
    defer a.free(exe);
    for ([_][]const u8{ "acl-clock", "acl-error", "acl-hang", "acl-cancel" }) |scenario| {
        var tmp = try tempTree(a, io, scenario);
        defer tmp.deinit(a, io);
        const root = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{tmp.path});
        defer a.free(root);
        try @import("external_cli_policy.zig").createPrivateDirectory(a, root);
        var original = try @import("workspace_acl.zig").Snapshot.init(a, root);
        defer original.deinit();
        const before = try original.sddl(a);
        defer a.free(before);
        var sb = try sandbox.Sandbox.init(a, root);
        defer sb.deinit();
        var events = CollectSink.init(a);
        defer events.deinit();
        var cancelled = std.atomic.Value(bool).init(false);
        var cancel_sink: Cancel = .{ .events = &events, .flag = &cancelled };
        const cancel = std.mem.eql(u8, scenario, "acl-cancel");
        // este caso mide la restauración exacta del SDDL; la
        // herencia explícita evita depender del CODEX_HOME personal del host.
        var profile = CODEX;
        profile.output_mode = .stream_json_lines;
        profile.inherit_personal_context = true;
        var report = try run(a, io, makeTask("acl", "modify root ACL"), sb, .{
            .profile = profile,
            .spawn_prefix = &.{ exe, "--headless", scenario },
            .worktree = root,
            .getenv = fakeGetEnv,
            .timeout_ms = if (std.mem.eql(u8, scenario, "acl-hang")) 3000 else 30000,
            .event_sink = if (cancel) .{ .ctx = &cancel_sink, .callFn = Cancel.event } else events.sink(),
            .is_cancelled_fn = if (cancel) Cancel.check else null,
            .cancelled_ctx = &cancelled,
        });
        defer report.deinit(a);
        try testing.expectEqual(std.mem.eql(u8, scenario, "acl-clock"), report.success);
        if (std.mem.eql(u8, scenario, "acl-hang")) try testing.expect(report.timed_out);
        if (cancel) try testing.expect(report.cancelled and !report.turn_limited and !report.timed_out);
        var restored = try @import("workspace_acl.zig").Snapshot.init(a, root);
        defer restored.deinit();
        const after = try restored.sddl(a);
        defer a.free(after);
        try testing.expectEqualStrings(before, after);
        try @import("workspace.zig").ensureExternalRoot(a, io, root);
        var next = try captureArtifactBaseline(a, io, defaultCapture, root, null);
        defer next.deinit(a);
        var child = try confined_fs.Root.init(a, root);
        defer child.deinit();
        const file = try child.open("acl-child.txt");
        defer file.close(io);
        try @import("external_cli_policy.zig").checkAcl(file.handle);
        var found = false;
        for (events.texts.items) |message| {
            if (std.mem.indexOf(u8, message, "permisos del espacio restaurados tras Codex") != null) found = true;
        }
        try testing.expect(found);
    }
}

test "SNAP root writer diagnostic preserves repair action when its list is truncated" {
    var diagnostic: SnapshotDiagnostic = .{};
    const ctx: SnapshotContext = .{ .diagnostic = &diagnostic };
    ctx.report("raiz", ".", error.CliWritableByOthers, false);
    appendWriterDiagnosis(&diagnostic, "usuario sintético\n" ** 2000);
    try testing.expect(std.mem.indexOf(u8, diagnostic.message(), "[lista truncada]") != null);
    try testing.expect(std.mem.endsWith(u8, diagnostic.message(), "accion=workspace_acl_restore (Restaurar permisos del espacio)"));
    try testing.expect(std.unicode.utf8ValidateSlice(diagnostic.message()));
}

test "RELOJ SNAP failed restoration is visible and never returns a successful report" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: SDDL y ACE de Windows; los permisos del espacio de trabajo no existen en Linux (WorkspacePermissionsUnavailableOnLinux)");
    const Fail = struct {
        fn restore(snapshot: *@import("workspace_acl.zig").Snapshot) anyerror!void {
            snapshot.last_error = 5;
            return error.WorkspacePermissionsRestoreFailed;
        }
    };
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "restore-failure");
    defer tmp.deinit(a, io);
    var sb = try sandbox.Sandbox.init(a, tmp.path);
    defer sb.deinit();
    var events = CollectSink.init(a);
    defer events.deinit();
    var diagnostic: SnapshotDiagnostic = .{};
    // el caso fuerza el fallo de restauración; la herencia
    // explícita evita depender del CODEX_HOME personal del host.
    var profile = CODEX;
    profile.inherit_personal_context = true;
    try testing.expectError(error.WorkspacePermissionsRestoreFailed, run(a, io, makeTask("fail", "restore"), sb, .{
        .profile = profile,
        .worktree = tmp.path,
        .getenv = fakeGetEnv,
        .mock_output = "completed",
        .event_sink = events.sink(),
        .snapshot_diagnostic = &diagnostic,
        .workspace_restore = Fail.restore,
    }));
    try testing.expect(std.mem.indexOf(u8, diagnostic.message(), "WorkspacePermissionsRestoreFailed") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostic.message(), "win32=5") != null);
    try testing.expect(events.texts.items.len > 0);
}

test "T2d-D5: sin diagnóstico del llamante (Directo) el aviso de restauración lleva el código win32" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: SDDL y ACE de Windows; los permisos del espacio de trabajo no existen en Linux (WorkspacePermissionsUnavailableOnLinux)");
    const Fail = struct {
        fn restore(snapshot: *@import("workspace_acl.zig").Snapshot) anyerror!void {
            snapshot.last_error = 1338;
            return error.WorkspacePermissionsRestoreFailed;
        }
    };
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "restore-failure-direct");
    defer tmp.deinit(a, io);
    var sb = try sandbox.Sandbox.init(a, tmp.path);
    defer sb.deinit();
    var events = CollectSink.init(a);
    defer events.deinit();
    var profile = CODEX;
    profile.inherit_personal_context = true;
    try testing.expectError(error.WorkspacePermissionsRestoreFailed, run(a, io, makeTask("fail", "restore"), sb, .{
        .profile = profile,
        .worktree = tmp.path,
        .getenv = fakeGetEnv,
        .mock_output = "completed",
        .event_sink = events.sink(),
        .workspace_restore = Fail.restore,
    }));
    var found = false;
    for (events.texts.items) |text| {
        if (std.mem.indexOf(u8, text, "etapa=restauracion_permisos") != null) {
            try testing.expect(std.mem.indexOf(u8, text, "win32=1338") != null);
            found = true;
        }
    }
    try testing.expect(found);
}

test "RELOJ SNAP an ordinary unprotected user folder keeps its control bits when the CLI adds an ACE" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: SDDL y ACE de Windows; los permisos del espacio de trabajo no existen en Linux (WorkspacePermissionsUnavailableOnLinux)");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();
    const bin = (try defaultGetEnv(a, "BEATS_TEST_BIN_DIR")) orelse return error.MissingMockBin;
    defer a.free(bin);
    const exe = try std.fs.path.join(a, &.{ bin, "cli-worker-mock" ++ comptime @import("builtin").target.exeFileExt() });
    defer a.free(exe);
    // Carpeta normal del usuario: hereda del padre, DACL NO protegida, y su
    // nombre no es el del espacio gobernado (no pasa por la compuerta privada).
    var tmp = try tempTree(a, io, "unprotected-root");
    defer tmp.deinit(a, io);
    var original = try @import("workspace_acl.zig").Snapshot.init(a, tmp.path);
    defer original.deinit();
    const before = try original.sddl(a);
    defer a.free(before);
    try testing.expect(std.mem.indexOf(u8, before, "D:P") == null);
    var sb = try sandbox.Sandbox.init(a, tmp.path);
    defer sb.deinit();
    var events = CollectSink.init(a);
    defer events.deinit();
    var profile = CODEX;
    profile.output_mode = .stream_json_lines;
    // el caso mide los bits de control del ACL; la herencia
    // explícita evita depender del CODEX_HOME personal del host.
    profile.inherit_personal_context = true;
    var report = try run(a, io, makeTask("acl", "modify root ACL"), sb, .{
        .profile = profile,
        .spawn_prefix = &.{ exe, "--headless", "acl-clock" },
        .worktree = tmp.path,
        .getenv = fakeGetEnv,
        .timeout_ms = 30000,
        .event_sink = events.sink(),
    });
    defer report.deinit(a);
    try testing.expect(report.success);
    var restored = try @import("workspace_acl.zig").Snapshot.init(a, tmp.path);
    defer restored.deinit();
    const after = try restored.sddl(a);
    defer a.free(after);
    // Mismos bits de control (sin P ni cambios) y sin ERROR_INVALID_SECURITY_DESCR.
    try testing.expectEqualStrings(before, after);
    try testing.expectEqual(@as(u32, 0), restored.last_error);
}

test "RELOJ SNAP an untouched root restores silently: no event after the result" {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "silent-restore");
    defer tmp.deinit(a, io);
    const governed = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{tmp.path});
    defer a.free(governed);
    try @import("external_cli_policy.zig").createPrivateDirectory(a, governed);
    var events = CollectSink.init(a);
    defer events.deinit();
    const ctx: SnapshotContext = .{ .sink = events.sink() };
    var snapshot = try capturePermissions(a, governed, ctx);
    defer snapshot.deinit();
    try restoreWorkspace(a, &snapshot, .{ .profile = CODEX, .worktree = governed, .event_sink = events.sink() }, ctx, false);
    try testing.expect(!snapshot.rewritten());
    try testing.expectEqual(@as(usize, 0), events.kinds.items.len);
}

test "RELOJ SNAP a link in the tree is a visible warning after restoring the root, not a failed order" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: SDDL y ACE de Windows; los permisos del espacio de trabajo no existen en Linux (WorkspacePermissionsUnavailableOnLinux)");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "links-warning");
    defer tmp.deinit(a, io);
    const governed = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{tmp.path});
    defer a.free(governed);
    try @import("external_cli_policy.zig").createPrivateDirectory(a, governed);
    var events = CollectSink.init(a);
    defer events.deinit();
    const ctx: SnapshotContext = .{ .sink = events.sink() };
    var snapshot = try capturePermissions(a, governed, ctx);
    defer snapshot.deinit();
    const original = try snapshot.sddl(a);
    defer a.free(original);
    try snapshot.widenForTest(a);
    // Un hardlink de pnpm / un clon local: dos nombres para el mismo archivo.
    const first = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "a.txt", .{governed});
    defer a.free(first);
    const second = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "b.txt", .{governed});
    defer a.free(second);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = first, .data = "same file" });
    var mk = try @import("providers").github.runCmdCaptureWin32(a, &.{ "cmd.exe", "/d", "/c", "mklink", "/H", second, first }, null);
    defer mk.deinit(a);
    try testing.expectEqual(@as(u32, 0), mk.exit_code);
    // La restauración automática NO falla: aviso visible y raíz restaurada.
    try restoreWorkspace(a, &snapshot, .{ .profile = CODEX, .worktree = governed, .event_sink = events.sink() }, ctx, false);
    const restored = try snapshot.sddl(a);
    defer a.free(restored);
    try testing.expectEqualStrings(original, restored);
    var warned = false;
    var announced = false;
    for (events.texts.items) |text| {
        if (std.mem.indexOf(u8, text, "la raíz quedó restaurada y no se tocaron los hijos") != null) warned = true;
        if (std.mem.indexOf(u8, text, "(hijos sin tocar)") != null) announced = true;
    }
    try testing.expect(warned and announced);
    // La compuerta de la raíz sigue pasando: el CLI siguiente puede lanzarse.
    try snapshot.checkGoverned(governed);
}

test "RELOJ SNAP capture on the retained handle refuses a contaminated governed root before launching" {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "capture-contaminated");
    defer tmp.deinit(a, io);
    const acl = @import("workspace_acl.zig");
    const governed = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{tmp.path});
    defer a.free(governed);
    try @import("external_cli_policy.zig").createPrivateDirectory(a, governed);
    {
        // Entre la comprobación previa y la captura otro proceso añade su ACE.
        var injector = try acl.Snapshot.init(a, governed);
        defer injector.deinit();
        try injector.widenForTest(a);
    }
    var diagnostic: SnapshotDiagnostic = .{};
    var events = CollectSink.init(a);
    defer events.deinit();
    const ctx: SnapshotContext = .{ .diagnostic = &diagnostic, .sink = events.sink() };
    try testing.expectError(error.CliWritableByOthers, capturePermissions(a, governed, ctx));
    try testing.expect(std.mem.indexOf(u8, diagnostic.message(), "etapa=raiz; ruta=.; error=CliWritableByOthers;") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostic.message(), "accion=workspace_acl_restore (Restaurar permisos del espacio)") != null);
    try testing.expect(diagnostic.repairRoot() != null and diagnostic.repairId() != null);
    try testing.expect(std.ascii.eqlIgnoreCase(diagnostic.repairRoot().?, governed));
    // Una carpeta de usuario con otro nombre no pasa por esa compuerta.
    const plain = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "proyecto", .{tmp.path});
    defer a.free(plain);
    try std.Io.Dir.cwd().createDirPath(io, plain);
    {
        var injector = try acl.Snapshot.init(a, plain);
        defer injector.deinit();
        try injector.widenForTest(a);
    }
    var accepted = try capturePermissions(a, plain, .{});
    accepted.deinit();
}

test "RELOJ SNAP a root contaminated again after restoring is a visible failure and a stuck tree skips restoring" {
    const Recontaminate = struct {
        fn restore(snapshot: *@import("workspace_acl.zig").Snapshot) anyerror!void {
            try snapshot.restore();
            // Un proceso escapado del trabajo vuelve a añadir su ACE.
            try snapshot.widenForTest(testing.allocator);
        }
    };
    const Counting = struct {
        var calls: u32 = 0;
        fn restore(_: *@import("workspace_acl.zig").Snapshot) anyerror!void {
            calls += 1;
        }
    };
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "restore-recontaminated");
    defer tmp.deinit(a, io);
    const governed = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{tmp.path});
    defer a.free(governed);
    try @import("external_cli_policy.zig").createPrivateDirectory(a, governed);
    var events = CollectSink.init(a);
    defer events.deinit();
    var diagnostic: SnapshotDiagnostic = .{};
    const ctx: SnapshotContext = .{ .diagnostic = &diagnostic, .sink = events.sink() };
    var snapshot = try capturePermissions(a, governed, ctx);
    defer snapshot.deinit();
    try snapshot.widenForTest(a);
    try testing.expectError(error.CliWritableByOthers, restoreWorkspace(a, &snapshot, .{
        .profile = CODEX,
        .worktree = governed,
        .event_sink = events.sink(),
        .workspace_restore = Recontaminate.restore,
    }, ctx, false));
    try testing.expect(std.mem.indexOf(u8, diagnostic.message(), "error=CliWritableByOthers;") != null);
    try testing.expect(std.mem.indexOf(u8, diagnostic.message(), "accion=workspace_acl_restore") != null);
    var warned = false;
    var announced = false;
    for (events.texts.items) |text| {
        if (std.mem.indexOf(u8, text, "volvió a quedar con escritores ajenos") != null) warned = true;
        if (std.mem.indexOf(u8, text, "permisos del espacio restaurados") != null) announced = true;
    }
    try testing.expect(warned and !announced);
    // Árbol atascado: no se restaura a ciegas; causa visible y sin llamar al restaurador.
    var stuck_diagnostic: SnapshotDiagnostic = .{};
    const stuck_ctx: SnapshotContext = .{ .diagnostic = &stuck_diagnostic, .sink = events.sink() };
    try testing.expectError(error.ProcessTreeStillActive, restoreWorkspace(a, &snapshot, .{
        .profile = CODEX,
        .worktree = governed,
        .event_sink = events.sink(),
        .workspace_restore = Counting.restore,
    }, stuck_ctx, true));
    try testing.expectEqual(@as(u32, 0), Counting.calls);
    try testing.expect(std.mem.indexOf(u8, stuck_diagnostic.message(), "etapa=restauracion_permisos") != null);
    try testing.expect(std.mem.indexOf(u8, stuck_diagnostic.message(), "error=ProcessTreeStillActive") != null);
}

const GetTempPathA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetTempPathA(size: u32, buffer: [*]u8) callconv(.winapi) u32;
}.GetTempPathA else @import("platform.zig").tempPath;
const GetTickCount64 = @import("platform.zig").ticks;

const TempTree = struct {
    dir: std.Io.Dir,
    path: []u8,
    fn deinit(self: *TempTree, a: std.mem.Allocator, io: std.Io) void {
        self.dir.close(io);
        std.Io.Dir.cwd().deleteTree(io, self.path) catch |e| std.debug.print("E5.20 cleanup {s}: {s}\n", .{ self.path, @errorName(e) });
        a.free(self.path);
    }
};

fn tempTree(a: std.mem.Allocator, io: std.Io, label: []const u8) !TempTree {
    var buffer: [4096]u8 = undefined;
    const n = GetTempPathA(buffer.len, &buffer);
    if (n == 0 or n >= buffer.len) return error.TestUnexpectedResult;
    const path = try std.fmt.allocPrint(a, "{s}beats-e520-{s}-{d}", .{ buffer[0..n], label, GetTickCount64() });
    errdefer a.free(path);
    try std.Io.Dir.cwd().createDir(io, path, .default_dir);
    return .{ .path = path, .dir = try std.Io.Dir.cwd().openDir(io, path, .{}) };
}

const CollectSink = struct {
    kinds: std.ArrayList(EventKind),
    texts: std.ArrayList([]u8),
    allocator: std.mem.Allocator,

    fn init(allocator: std.mem.Allocator) CollectSink {
        return .{ .kinds = .empty, .texts = .empty, .allocator = allocator };
    }
    fn deinit(self: *CollectSink) void {
        self.kinds.deinit(self.allocator);
        for (self.texts.items) |t| self.allocator.free(t);
        self.texts.deinit(self.allocator);
    }
    fn onEvent(ctx: *anyopaque, kind: EventKind, text: []const u8) void {
        const self: *CollectSink = @ptrCast(@alignCast(ctx));
        self.kinds.append(self.allocator, kind) catch return;
        self.texts.append(self.allocator, self.allocator.dupe(u8, text) catch return) catch return;
    }
    fn sink(self: *CollectSink) EventSink {
        return .{ .ctx = self, .callFn = onEvent };
    }
};

/// git real en tmpDir (patrón ship_flow): null si git no está → SkipZigTest.
fn gitInitWorktree(allocator: std.mem.Allocator, io: std.Io, dir: []const u8) !?[]u8 {
    var cap = gh.runCmdCaptureWin32(allocator, &.{ "git", "init", dir }, null) catch return null;
    defer cap.deinit(allocator);
    if (cap.exit_code != 0) return null;
    const cfgs = [_][]const []const u8{
        &.{ "git", "-C", dir, "config", "user.email", "e507@test" },
        &.{ "git", "-C", dir, "config", "user.name", "e507" },
        &.{ "git", "-C", dir, "config", "commit.gpgsign", "false" },
    };
    for (cfgs) |argv| {
        var c = gh.runCmdCaptureWin32(allocator, argv, null) catch return null;
        defer c.deinit(allocator);
        if (c.exit_code != 0) return null;
    }
    // Commit inicial para tener HEAD como base.
    var wt_dir = std.Io.Dir.cwd().openDir(io, dir, .{}) catch return null;
    defer wt_dir.close(io);
    writeFile(io, wt_dir, "base.txt", "base") catch return null;
    var add = gh.runCmdCaptureWin32(allocator, &.{ "git", "-C", dir, "add", "." }, null) catch return null;
    defer add.deinit(allocator);
    var com = gh.runCmdCaptureWin32(allocator, &.{ "git", "-C", dir, "commit", "-m", "init" }, null) catch return null;
    defer com.deinit(allocator);
    if (com.exit_code != 0) return null;
    var rev = gh.runCmdCaptureWin32(allocator, &.{ "git", "-C", dir, "rev-parse", "HEAD" }, null) catch return null;
    defer rev.deinit(allocator);
    if (rev.exit_code != 0) return null;
    const sha = std.mem.trim(u8, rev.stdout, " \t\r\n");
    if (sha.len == 0) return null;
    return try allocator.dupe(u8, sha);
}

test "integracion real: cli-worker-mock --headless edit en worktree git" {
    const allocator = testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const wt = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(wt);

    const base = (try gitInitWorktree(allocator, io, wt)) orelse return error.SkipZigTest;
    defer allocator.free(base);

    var collector = CollectSink.init(allocator);
    defer collector.deinit();

    // Perfil sintético contra el mock: argv_tail, stream-json. argv[0] lleva la
    // ruta absoluta del exe porque el cwd del hijo es el worktree, no zig-out\bin.
    const test_bin_dir = (try defaultGetEnv(allocator, "BEATS_TEST_BIN_DIR")) orelse try allocator.dupe(u8, TEST_BIN_DIR);
    defer allocator.free(test_bin_dir);
    const exe_path = try std.fs.path.join(allocator, &.{ test_bin_dir, "cli-worker-mock" ++ comptime @import("builtin").target.exeFileExt() });
    defer allocator.free(exe_path);
    const mock_profile = CliProfile{
        .id = "mock-cli",
        .exe = exe_path,
        .argv_prefix = &.{"--headless"},
        .prompt_channel = .argv_tail,
        .output_mode = .stream_json_lines,
        .permission_note = "mock",
        .turn_cap_note = "mock",
    };

    var sb = try sandbox.Sandbox.init(allocator, wt);
    defer sb.deinit();

    var report = try run(allocator, io, makeTask("t-e507", "edit"), sb, .{
        .profile = mock_profile,
        .worktree = wt,
        .base_commit = base,
        .timeout_ms = 30000,
        .event_sink = collector.sink(),
        .getenv = fakeGetEnv,
    });
    defer report.deinit(allocator);

    try testing.expect(report.success);
    try testing.expectEqual(@as(?u8, 0), report.exit_code);
    // El mock corrió en el worktree (spawn cwd) y escribió mock_edit.txt:
    // el diff lo recoge como artefacto untracked validado por el sandbox.
    var saw_edit = false;
    for (report.artifacts) |a| {
        if (std.mem.eql(u8, a.path, "mock_edit.txt")) saw_edit = true;
    }
    try testing.expect(saw_edit);
    // Streaming: el mock emite líneas stream-json → eventos. añade
    // avisos de alcance/contexto después del result; el result debe seguir ahí.
    try testing.expect(collector.kinds.items.len >= 2);
    try testing.expect(std.mem.indexOfScalar(EventKind, collector.kinds.items, .result) != null);
    // La declaración viene del stream, no del diff.
    try testing.expect(std.mem.indexOf(u8, report.declaration, "mock") != null);
}

test "T7 reglas del proyecto: el encargo a una CLI externa las lleva (argv capturado)" {
    const allocator = testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const wt = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(wt);
    const base = (try gitInitWorktree(allocator, io, wt)) orelse return error.SkipZigTest;
    defer allocator.free(base);
    const test_bin_dir = (try defaultGetEnv(allocator, "BEATS_TEST_BIN_DIR")) orelse try allocator.dupe(u8, TEST_BIN_DIR);
    defer allocator.free(test_bin_dir);
    const exe_path = try std.fs.path.join(allocator, &.{ test_bin_dir, "cli-worker-mock" ++ comptime @import("builtin").target.exeFileExt() });
    defer allocator.free(exe_path);
    const mock_profile = CliProfile{
        .id = "mock-cli",
        .exe = exe_path,
        .argv_prefix = &.{"--headless"},
        .prompt_channel = .argv_tail,
        .output_mode = .stream_json_lines,
        .permission_note = "mock",
        .turn_cap_note = "mock",
    };
    var sb = try sandbox.Sandbox.init(allocator, wt);
    defer sb.deinit();
    var report = try run(allocator, io, makeTask("t-t7-reglas", "edit"), sb, .{
        .rules_context = .{ .custom = "REGLA-T7-CLI: nunca uses eval." },
        .profile = mock_profile,
        .worktree = wt,
        .base_commit = base,
        .timeout_ms = 30000,
        .getenv = fakeGetEnv,
    });
    defer report.deinit(allocator);
    try testing.expect(report.success);
    const argv = report.argv_censored.?;
    try testing.expect(std.mem.indexOf(u8, argv, project_rules.HEADER) != null);
    try testing.expect(std.mem.indexOf(u8, argv, "REGLA-T7-CLI: nunca uses eval.") != null);
    try testing.expect(std.mem.indexOf(u8, argv, project_rules.PRECEDENCE_NOTE) != null);
    try testing.expectEqual(@as(usize, 1), std.mem.count(u8, argv, project_rules.HEADER));
}

test "integracion real: timeout mata al mock colgado y conserva transcript" {
    const allocator = testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const wt = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(wt);

    const base = (try gitInitWorktree(allocator, io, wt)) orelse return error.SkipZigTest;
    defer allocator.free(base);

    const test_bin_dir = (try defaultGetEnv(allocator, "BEATS_TEST_BIN_DIR")) orelse try allocator.dupe(u8, TEST_BIN_DIR);
    defer allocator.free(test_bin_dir);
    const exe_path = try std.fs.path.join(allocator, &.{ test_bin_dir, "cli-worker-mock" ++ comptime @import("builtin").target.exeFileExt() });
    defer allocator.free(exe_path);
    const mock_profile = CliProfile{
        .id = "mock-cli",
        .exe = exe_path,
        .argv_prefix = &.{ "--headless", "hang" },
        .prompt_channel = .argv_tail,
        .output_mode = .stream_json_lines,
        .permission_note = "mock",
        .turn_cap_note = "mock",
    };

    var sb = try sandbox.Sandbox.init(allocator, wt);
    defer sb.deinit();

    var report = try run(allocator, io, makeTask("t-e507-hang", "x"), sb, .{
        .profile = mock_profile,
        .worktree = wt,
        .base_commit = base,
        .timeout_ms = 800,
        .getenv = fakeGetEnv,
    });
    defer report.deinit(allocator);

    try testing.expect(report.timed_out);
    try testing.expect(!report.success);
    try testing.expect(report.exit_code == null);
    // La línea parcial previa al cuelgue queda en la transcripción.
    try testing.expect(std.mem.indexOf(u8, report.transcript, "mock-hang") != null);
}

test "E5.55: CLI default does not force an obsolete Codex model" {
    const a = std.testing.allocator;
    const argv = try buildArgv(a, CODEX, "C:\\wt", "test");
    defer a.free(argv);
    for (argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "gpt-5.6-sol"));
}

test "E5.55: chosen model reaches argv of every CLI" {
    const a = std.testing.allocator;
    for (PROFILES) |base| {
        var p = base;
        p.model = "gpt-6-luna";
        const argv = try buildArgv(a, p, "C:\\wt", "prompt");
        defer a.free(argv);
        var found = false;
        for (argv, 0..) |arg, i| {
            if (std.mem.eql(u8, arg, "gpt-6-luna")) {
                try testing.expect(i > 0);
                try testing.expect(std.mem.eql(u8, argv[i - 1], "-m") or std.mem.eql(u8, argv[i - 1], "--model"));
                found = true;
            }
            try testing.expect(!std.mem.eql(u8, arg, "gpt-5.6-sol"));
        }
        try testing.expect(found);
    }
    var p = CODEX;
    p.model = "gpt-6-luna";
    p.reasoning_effort = "model_reasoning_effort=\"high\"";
    const argv = try buildArgv(a, p, "C:\\wt", "prompt");
    defer a.free(argv);
    var found = false;
    for (argv) |arg| if (std.mem.eql(u8, arg, p.reasoning_effort.?)) {
        found = true;
    };
    try testing.expect(found);
    var claude = CLAUDE_CODE;
    claude.reasoning_effort = "high";
    const claude_argv = try buildArgv(a, claude, "C:\\wt", "prompt");
    defer a.free(claude_argv);
    found = false;
    for (claude_argv, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--effort")) {
            try testing.expectEqualStrings("high", claude_argv[i + 1]);
            found = true;
        }
    }
    try testing.expect(found);
}

test "SNAP missing root preserves FileNotFound" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var diagnostic: SnapshotDiagnostic = .{};
    try testing.expectError(error.FileNotFound, captureArtifactBaselineContext(a, threaded.io(), defaultCapture, "Z:\\missing-snap-root", null, .{ .diagnostic = &diagnostic }));
    try testing.expect(std.mem.indexOf(u8, diagnostic.message(), "etapa=raiz; ruta=.; error=FileNotFound") != null);
    try testing.expect(diagnostic.windows_error == 2 or diagnostic.windows_error == 3);
    try testing.expectError(error.SandboxDenied, captureArtifactBaselineContext(a, threaded.io(), defaultCapture, "relative", null, .{ .diagnostic = &diagnostic }));
    try testing.expect(std.mem.indexOf(u8, diagnostic.message(), "error=SandboxDenied") != null);
}

test "SNAP locked user file does not abort or become an invented artifact" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "snap-lock");
    defer tmp.deinit(a, io);
    try writeFile(io, tmp.dir, "locked.sqlite", "before");
    const path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "locked.sqlite", .{tmp.path});
    defer a.free(path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    const handle = SnapLock.CreateFileW(wide.ptr, 0x80000000, 0, null, 3, 0x80, null);
    try testing.expect(handle != std.os.windows.INVALID_HANDLE_VALUE);
    var locked = true;
    defer if (locked) {
        _ = CloseHandle(handle);
    };
    var events = CollectSink.init(a);
    defer events.deinit();
    var diagnostic: SnapshotDiagnostic = .{};
    var baseline = try captureArtifactBaselineContext(a, io, defaultCapture, tmp.path, null, .{ .diagnostic = &diagnostic, .sink = events.sink() });
    defer baseline.deinit(a);
    try testing.expectEqual(@as(usize, 1), baseline.entries.len);
    try testing.expect(!baseline.entries[0].readable);
    try testing.expect(std.mem.indexOf(u8, events.texts.items[0], "etapa=apertura; ruta=locked.sqlite; error=SharingViolation; win32=32") != null);
    _ = CloseHandle(handle);
    locked = false;
    try writeFile(io, tmp.dir, "locked.sqlite", "after!");
    try writeFile(io, tmp.dir, "reloj.py", "print('clock')\n");
    var sb = try sandbox.Sandbox.init(a, tmp.path);
    defer sb.deinit();
    const changes = try collectArtifactChanges(a, io, defaultCapture, tmp.path, baseline, sb);
    defer {
        for (changes) |*art| art.deinit(a);
        a.free(changes);
    }
    try testing.expectEqual(@as(usize, 1), changes.len);
    try testing.expectEqualStrings("reloj.py", changes[0].path);
}

const SnapLock = struct {
    extern "kernel32" fn CreateFileW([*:0]const u16, u32, u32, ?*anyopaque, u32, u32, ?std.os.windows.HANDLE) callconv(.winapi) std.os.windows.HANDLE;
    extern "kernel32" fn SetFileAttributesW([*:0]const u16, u32) callconv(.winapi) c_int;
};

test "CK-PUB-015 .devagents excludes only DevAgents internals, never the user's config" {
    try testing.expect(excludedArtifactPath(".devagents/spaces/orden-1/a.txt", null));
    try testing.expect(excludedArtifactPath(".devagents\\external-context-opencode\\opencode.json", null));
    try testing.expect(excludedArtifactPath(".beats/spaces/orden-1/a.txt", null));
    try testing.expect(!excludedArtifactPath(".devagents/worktree.json", null));
    try testing.expect(!excludedArtifactPath(".devagents", null));
    try testing.expect(!excludedArtifactPath("src/.devagents/spaces/x", null));
}

test "SNAP exclusions anchor internals and metadata dependencies while preserving hidden sources" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "snap-exclusions");
    defer tmp.deinit(a, io);
    for ([_][]const u8{ ".beats", ".git", "$RECYCLE.BIN", "System Volume Information" }) |excluded| {
        try tmp.dir.createDirPath(io, excluded);
        const name = try std.fmt.allocPrint(a, "{s}/large.bin", .{excluded});
        defer a.free(name);
        var file = try tmp.dir.createFile(io, name, .{});
        defer file.close(io);
        try file.setLength(io, SNAPSHOT_BYTE_CAP + 1);
    }
    try tmp.dir.createDirPath(io, ".user-hidden");
    const hidden_path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".user-hidden", .{tmp.path});
    defer a.free(hidden_path);
    const hidden_wide = try std.unicode.utf8ToUtf16LeAllocZ(a, hidden_path);
    defer a.free(hidden_wide);
    try testing.expect(SnapLock.SetFileAttributesW(hidden_wide.ptr, 0x12) != 0);
    try writeFile(io, tmp.dir, ".user-hidden/source.py", "print('user')\n");
    var diagnostic: SnapshotDiagnostic = .{};
    var baseline = try captureArtifactBaselineContext(a, io, defaultCapture, tmp.path, null, .{ .diagnostic = &diagnostic });
    defer baseline.deinit(a);
    try testing.expectEqual(@as(usize, 1), baseline.entries.len);
    try testing.expectEqualStrings(".user-hidden\\source.py", baseline.entries[0].path);
    var sb = try sandbox.Sandbox.init(a, tmp.path);
    defer sb.deinit();
    try writeFile(io, tmp.dir, ".user-hidden/source.py", "print('changed')\n");
    const arts = try collectArtifactChangesContext(a, io, defaultCapture, tmp.path, baseline, sb, .{ .diagnostic = &diagnostic });
    defer {
        for (arts) |*art| art.deinit(a);
        a.free(arts);
    }
    try testing.expectEqual(@as(usize, 1), arts.len);
    try testing.expectEqualStrings("print('changed')\n", arts[0].content);
    try tmp.dir.createDirPath(io, "node_modules");
    var huge = try tmp.dir.createFile(io, "node_modules/large.bin", .{});
    defer huge.close(io);
    try huge.setLength(io, SNAPSHOT_BYTE_CAP + 1);
    var with_dependencies = try captureArtifactBaselineContext(a, io, defaultCapture, tmp.path, null, .{ .diagnostic = &diagnostic });
    defer with_dependencies.deinit(a);
    try testing.expectEqual(@as(usize, 2), with_dependencies.entries.len);
    for (with_dependencies.entries) |entry| if (entry.metadata_only) {
        try testing.expectEqualStrings("node_modules\\large.bin", entry.path);
        try testing.expectEqual(SNAPSHOT_BYTE_CAP + 1, entry.size);
        try testing.expect(entry.mtime != 0);
        try testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &entry.sha256);
    };
    // A large ordinary file still reaches the byte guard.
    var user_large = try tmp.dir.createFile(io, "user.bin", .{});
    defer user_large.close(io);
    try user_large.setLength(io, SNAPSHOT_BYTE_CAP + 1);
    try testing.expectError(error.SnapshotTooLarge, captureArtifactBaselineContext(a, io, defaultCapture, tmp.path, null, .{ .diagnostic = &diagnostic }));
    try testing.expect(std.mem.indexOf(u8, diagnostic.message(), "error=SnapshotTooLarge") != null);
}

fn resizeSnapshotFile(raw: ?*anyopaque, io: std.Io, _: std.Io.File, rel: []const u8) !void {
    if (!std.mem.eql(u8, rel, "changing.txt")) return;
    const dir: *std.Io.Dir = @ptrCast(@alignCast(raw.?));
    try writeFile(io, dir.*, rel, "x");
}

test "SNAP size race is unknown and cannot create or delete artifacts" {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "snap-size");
    defer tmp.deinit(a, io);
    try writeFile(io, tmp.dir, "changing.txt", "before resize");
    var events = CollectSink.init(a);
    defer events.deinit();
    var baseline = try captureArtifactBaselineContext(a, io, defaultCapture, tmp.path, null, .{ .sink = events.sink(), .after_stat = resizeSnapshotFile, .hook_ctx = &tmp.dir });
    defer baseline.deinit(a);
    try testing.expect(!baseline.entries[0].readable);
    try testing.expect(std.mem.indexOf(u8, events.texts.items[0], "etapa=tamano_cambiado; ruta=changing.txt; error=SizeChanged") != null);
    var sb = try sandbox.Sandbox.init(a, tmp.path);
    defer sb.deinit();
    const arts = try collectArtifactChangesContext(a, io, defaultCapture, tmp.path, baseline, sb, .{ .sink = events.sink() });
    defer {
        for (arts) |*art| art.deinit(a);
        a.free(arts);
    }
    try testing.expectEqual(@as(usize, 0), arts.len);
    var safe = try artifactRoot(a, tmp.path);
    defer safe.deinit();
    try writeFile(io, tmp.dir, "changing.txt", "before resize again");
    try testing.expectError(error.SizeChanged, readArtifactContentContext(a, io, &safe, "changing.txt", .{ .sink = events.sink(), .after_stat = resizeSnapshotFile, .hook_ctx = &tmp.dir }, null));
}

test "SNAP user file locks after baseline are not deletions" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "snap-after-lock");
    defer tmp.deinit(a, io);
    try writeFile(io, tmp.dir, "user.db", "user");
    var baseline = try captureArtifactBaseline(a, io, defaultCapture, tmp.path, null);
    defer baseline.deinit(a);
    const path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "user.db", .{tmp.path});
    defer a.free(path);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    const handle = SnapLock.CreateFileW(wide.ptr, 0x80000000, 0, null, 3, 0x80, null);
    try testing.expect(handle != std.os.windows.INVALID_HANDLE_VALUE);
    defer _ = CloseHandle(handle);
    var sb = try sandbox.Sandbox.init(a, tmp.path);
    defer sb.deinit();
    const arts = try collectArtifactChanges(a, io, defaultCapture, tmp.path, baseline, sb);
    defer {
        for (arts) |*art| art.deinit(a);
        a.free(arts);
    }
    try testing.expectEqual(@as(usize, 0), arts.len);
}

test "SNAP diagnostic stages, bounded message and error branches" {
    const a = testing.allocator;
    var diagnostic: SnapshotDiagnostic = .{};
    var events = CollectSink.init(a);
    defer events.deinit();
    const ctx: SnapshotContext = .{ .diagnostic = &diagnostic, .sink = events.sink() };
    for ([_][]const u8{ "raiz", "recorrido", "apertura", "lectura", "tamano_cambiado" }) |stage| {
        ctx.report(stage, "user.py", error.AccessDenied, false);
        try testing.expect(std.mem.indexOf(u8, diagnostic.message(), stage) != null);
        try testing.expect(std.mem.indexOf(u8, diagnostic.message(), "ruta=user.py; error=AccessDenied") != null);
    }
    const long = try a.alloc(u8, 5000);
    defer a.free(long);
    @memset(long, 'x');
    ctx.report("lectura", long, error.SizeChanged, false);
    try testing.expect(diagnostic.message().len < diagnostic.buf.len);
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "snap-errors");
    defer tmp.deinit(a, io);
    try testing.expectError(error.GitFailed, captureArtifactBaselineContext(a, io, failedCapture, tmp.path, null, ctx));
    try testing.expect(std.mem.indexOf(u8, diagnostic.message(), "etapa=git; ruta=.; error=GitFailed") != null);
    var failing = testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, captureArtifactBaselineContext(failing.allocator(), io, defaultCapture, tmp.path, null, ctx));
    try testing.expect(std.mem.indexOf(u8, diagnostic.message(), "error=OutOfMemory") != null);
    var safe = try artifactRoot(a, tmp.path);
    defer safe.deinit();
    try tmp.dir.createDirPath(io, "folder");
    try testing.expectError(error.SandboxDenied, readArtifactContentContext(a, io, &safe, "folder", ctx, null));
    try testing.expectError(error.FileNotFound, readArtifactContentContext(a, io, &safe, "missing.txt", ctx, .{ .path = @constCast("missing.txt") }));
    try writeFile(io, tmp.dir, "wrong.txt", "observed after snapshot");
    try testing.expectError(error.FileChanged, readArtifactContentContext(a, io, &safe, "wrong.txt", ctx, .{ .path = @constCast("wrong.txt") }));
}

test "SNAP new default workspace is created only under a validated existing project" {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "snap-new-root");
    defer tmp.deinit(a, io);
    const path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{tmp.path});
    defer a.free(path);
    try @import("workspace.zig").ensureExternalRoot(a, io, path);
    try @import("workspace.zig").ensureExternalRoot(a, io, path);
    var baseline = try captureArtifactBaseline(a, io, defaultCapture, path, null);
    defer baseline.deinit(a);
    try testing.expectEqual(@as(usize, 0), baseline.entries.len);
    try testing.expect(baseline.git_commit == null);
    const missing = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "missing" ++ std.fs.path.sep_str ++ "devagents-workspace", .{tmp.path});
    defer a.free(missing);
    try testing.expectError(error.FileNotFound, @import("workspace.zig").ensureExternalRoot(a, io, missing));
    const explicit = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "missing-space", .{tmp.path});
    defer a.free(explicit);
    try testing.expectError(error.FileNotFound, @import("workspace.zig").ensureExternalRoot(a, io, explicit));
    try tmp.dir.createDirPath(io, "other-project");
    const other_explicit = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "other-project" ++ std.fs.path.sep_str ++ "explicit-space", .{tmp.path});
    defer a.free(other_explicit);
    try testing.expectError(error.FileNotFound, @import("workspace.zig").ensureExternalRoot(a, io, other_explicit));
    try testing.expectError(error.FileNotFound, tmp.dir.openDir(io, "other-project/devagents-workspace", .{}));
    try testing.expectError(error.SandboxDenied, @import("workspace.zig").ensureExternalRoot(a, io, "relative"));
    var failing = testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, @import("workspace.zig").ensureExternalRoot(failing.allocator(), io, path));
}

test "SNAP exclusive lock from a child process warns while a new clock remains provable" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "snap-child-lock");
    defer tmp.deinit(a, io);
    try writeFile(io, tmp.dir, "user.db", "sqlite-like user bytes");
    const bin = (try defaultGetEnv(a, "BEATS_TEST_BIN_DIR")) orelse return error.MissingMockBin;
    defer a.free(bin);
    const exe = try std.fs.path.join(a, &.{ bin, "cli-worker-mock" ++ comptime @import("builtin").target.exeFileExt() });
    defer a.free(exe);
    var child = try std.process.spawn(io, .{ .argv = &.{ exe, "--headless", "lock" }, .cwd = .{ .path = tmp.path } });
    defer {
        child.kill(io);
    }
    const deadline = GetTickCount64() + 10000;
    while (true) {
        const ready = tmp.dir.openFile(io, "lock.ready", .{}) catch |e| {
            if (e != error.FileNotFound) return e;
            if (GetTickCount64() > deadline) return error.LockHandshakeTimeout;
            SnapWait.Sleep(10);
            continue;
        };
        ready.close(io);
        break;
    }
    var events = CollectSink.init(a);
    defer events.deinit();
    var diagnostic: SnapshotDiagnostic = .{};
    var baseline = try captureArtifactBaselineContext(a, io, defaultCapture, tmp.path, null, .{ .sink = events.sink(), .diagnostic = &diagnostic });
    defer baseline.deinit(a);
    try testing.expect(std.mem.indexOf(u8, events.texts.items[0], "ruta=user.db; error=SharingViolation; win32=32") != null);
    try writeFile(io, tmp.dir, "reloj.py", "print('clock')\n");
    var sb = try sandbox.Sandbox.init(a, tmp.path);
    defer sb.deinit();
    const arts = try collectArtifactChangesContext(a, io, defaultCapture, tmp.path, baseline, sb, .{ .sink = events.sink(), .diagnostic = &diagnostic });
    defer {
        for (arts) |*art| art.deinit(a);
        a.free(arts);
    }
    try testing.expectEqual(@as(usize, 1), arts.len);
    try testing.expectEqualStrings("reloj.py", arts[0].path);
}

const SnapWait = struct {
    extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
};

test "SNAP R2 hard link outside root is never read or counted" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const Api = struct {
        extern "kernel32" fn CreateHardLinkW([*:0]const u16, [*:0]const u16, ?*anyopaque) callconv(.winapi) c_int;
    };
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "snap-r2-hardlink");
    defer tmp.deinit(a, io);
    try tmp.dir.createDirPath(io, "space");
    try writeFile(io, tmp.dir, "outside.txt", "synthetic external content");
    const space = try tmp.dir.realPathFileAlloc(io, "space", a);
    defer a.free(space);
    var baseline = try captureArtifactBaseline(a, io, defaultCapture, space, null);
    defer baseline.deinit(a);
    const source = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "outside.txt", .{tmp.path});
    defer a.free(source);
    const link = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "artifact.txt", .{space});
    defer a.free(link);
    const source_w = try std.unicode.utf8ToUtf16LeAllocZ(a, source);
    defer a.free(source_w);
    const link_w = try std.unicode.utf8ToUtf16LeAllocZ(a, link);
    defer a.free(link_w);
    try testing.expect(Api.CreateHardLinkW(link_w, source_w, null) != 0);
    if (baseline.retained_root.open("artifact.txt")) |file| {
        file.close(io);
        return error.HardLinkGuardBypassed;
    } else |e| try testing.expectEqual(error.HardLinkDenied, e);
    try testing.expectError(error.HardLinkDenied, baseline.retained_root.openMetadata("artifact.txt"));
    var diagnostic: SnapshotDiagnostic = .{};
    var events = CollectSink.init(a);
    defer events.deinit();
    const ctx: SnapshotContext = .{ .diagnostic = &diagnostic, .sink = events.sink() };
    var sb = try sandbox.Sandbox.init(a, space);
    defer sb.deinit();
    try testing.expectError(error.HardLinkDenied, collectArtifactChangesContext(a, io, defaultCapture, space, baseline, sb, ctx));
    try testing.expectError(error.HardLinkDenied, readArtifactContentContext(a, io, &baseline.retained_root, "artifact.txt", ctx, null));
    try testing.expectError(error.HardLinkDenied, captureArtifactBaselineContext(a, io, defaultCapture, space, null, ctx));
    for (events.texts.items) |text| {
        try testing.expect(std.mem.indexOf(u8, text, "synthetic external content") == null);
        try testing.expect(std.mem.indexOf(u8, text, "error=HardLinkDenied") != null);
    }
}

test "SNAP R2 nested internals dependencies and ignored Git changes remain visible" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const Git = struct {
        fn capture(a: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !gh.CmdCapture {
            const out = if (std.mem.eql(u8, argv[1], "rev-parse"))
                (if (std.mem.eql(u8, argv[2], "--show-toplevel")) cwd.? else "synthetic-base")
            else
                "";
            return .{ .stdout = try a.dupe(u8, out), .stderr = try a.dupe(u8, ""), .exit_code = 0 };
        }
    };
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const protected = (try dataRootRelative(a, "C:\\synthetic-profile", "C:\\synthetic-profile\\AppData\\Local")).?;
    defer a.free(protected);
    try testing.expectEqualStrings("AppData\\Local\\DevAgents-Angel", protected);
    try testing.expect(excludedArtifactPath("AppData\\Local\\DevAgents-Angel\\db", protected));
    try testing.expect(!excludedArtifactPath("sub\\DevAgents-Angel\\db", protected));
    try testing.expectError(error.SandboxDenied, dataRootRelative(a, "C:\\synthetic-profile\\AppData\\Local\\DevAgents-Angel", "C:\\synthetic-profile\\AppData\\Local"));
    try testing.expect((try dataRootRelative(a, "C:\\project", "C:\\synthetic-profile\\AppData\\Local")) == null);
    for ([_]CaptureFn{ defaultCapture, Git.capture }) |capture| {
        var tmp = try tempTree(a, io, "snap-r2-visible");
        defer tmp.deinit(a, io);
        for ([_][]const u8{ "sub/node_modules", "sub/.git", "node_modules", ".beats", ".git" }) |dir| try tmp.dir.createDirPath(io, dir);
        try writeFile(io, tmp.dir, "sub/node_modules/x", "before");
        var baseline = try captureArtifactBaseline(a, io, capture, tmp.path, null);
        defer baseline.deinit(a);
        try testing.expectEqual(capture == Git.capture, baseline.git_commit != null);
        try writeFile(io, tmp.dir, "sub/node_modules/x", "after");
        try writeFile(io, tmp.dir, "sub/.git/x", "new nested file");
        try writeFile(io, tmp.dir, "node_modules/x", "new dependency file");
        try writeFile(io, tmp.dir, ".beats/x", "internal");
        try writeFile(io, tmp.dir, ".git/x", "internal");
        var sb = try sandbox.Sandbox.init(a, tmp.path);
        defer sb.deinit();
        var events = CollectSink.init(a);
        defer events.deinit();
        const arts = try collectArtifactChangesContext(a, io, capture, tmp.path, baseline, sb, .{ .sink = events.sink() });
        defer {
            for (arts) |*art| art.deinit(a);
            a.free(arts);
        }
        try testing.expectEqual(@as(usize, 2), arts.len);
        try testing.expectEqualStrings("sub\\.git\\x", arts[0].path);
        try testing.expectEqualStrings("sub\\node_modules\\x", arts[1].path);
        try testing.expectEqualStrings("after", arts[1].content);
        try testing.expectEqual(@as(usize, 1), events.texts.items.len);
        try testing.expectEqual(EventKind.warning, events.kinds.items[0]);
        try testing.expectEqualStrings("1 archivos cambiados en carpetas de dependencias/cachés", events.texts.items[0]);
    }
}

test "SNAP R2 dependency metadata counts additions changes deletions without reading or caps" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "snap-r3-metadata");
    defer tmp.deinit(a, io);
    const categories = [_][]const u8{ "node_modules", "zig-out", ".zig-cache", ".venv", "__pycache__" };
    for (categories) |category| {
        try tmp.dir.createDirPath(io, category);
        const rel = try std.fmt.allocPrint(a, "{s}/x", .{category});
        defer a.free(rel);
        try writeFile(io, tmp.dir, rel, "before");
    }
    // Thousands of metadata entries do not consume the ordinary entry budget.
    for (0..SNAPSHOT_ENTRY_CAP + 1) |i| {
        const rel = try std.fmt.allocPrint(a, "node_modules/empty-{d}", .{i});
        defer a.free(rel);
        var file = try tmp.dir.createFile(io, rel, .{});
        file.close(io);
    }
    const NoRead = struct {
        fn hook(_: ?*anyopaque, _: std.Io, _: std.Io.File, _: []const u8) !void {
            return error.DependencyContentRead;
        }
    };
    var events = CollectSink.init(a);
    defer events.deinit();
    const ctx: SnapshotContext = .{ .sink = events.sink(), .after_stat = NoRead.hook };
    var baseline = try captureArtifactBaselineContext(a, io, defaultCapture, tmp.path, null, ctx);
    defer baseline.deinit(a);
    try testing.expectEqual(SNAPSHOT_ENTRY_CAP + 1 + categories.len, baseline.entries.len);
    for (baseline.entries) |entry| {
        try testing.expect(entry.metadata_only and entry.readable);
        try testing.expect(entry.mtime > 0);
        try testing.expectEqualSlices(u8, &@as([32]u8, @splat(0)), &entry.sha256);
    }
    const meta = try baseline.retained_root.openMetadata("node_modules/x");
    defer meta.close(io);
    try testing.expectEqual(@as(u64, 6), (try meta.stat(io)).size);
    var buffer: [6]u8 = undefined;
    try testing.expectError(error.AccessDenied, meta.readPositionalAll(io, &buffer, 0));
    try testing.expectError(error.SandboxDenied, baseline.retained_root.openMetadata("../outside"));
    try testing.expectError(error.FileNotFound, baseline.retained_root.openMetadata("node_modules/missing"));
    var failing = testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    var no_memory = baseline.retained_root;
    no_memory.allocator = failing.allocator();
    try testing.expectError(error.OutOfMemory, no_memory.openMetadata("node_modules/x"));
    try writeFile(io, tmp.dir, "node_modules/new", "added");
    try writeFile(io, tmp.dir, "zig-out/x", "changed size");
    var timestamp = try tmp.dir.openFile(io, ".zig-cache/x", .{ .mode = .read_write });
    defer timestamp.close(io);
    const stat = try timestamp.stat(io);
    try timestamp.setTimestamps(io, .{ .modify_timestamp = .{ .new = .{ .nanoseconds = stat.mtime.nanoseconds + 2 * std.time.ns_per_s } } });
    try tmp.dir.deleteFile(io, ".venv/x");
    var sb = try sandbox.Sandbox.init(a, tmp.path);
    defer sb.deinit();
    const arts = try collectArtifactChangesContext(a, io, defaultCapture, tmp.path, baseline, sb, ctx);
    defer {
        for (arts) |*art| art.deinit(a);
        a.free(arts);
    }
    try testing.expectEqual(@as(usize, 0), arts.len);
    try testing.expectEqual(@as(usize, 1), events.texts.items.len);
    try testing.expectEqualStrings("4 archivos cambiados en carpetas de dependencias/cachés", events.texts.items[0]);
    try testing.expectEqual(EventKind.warning, events.kinds.items[0]);
}

test "SNAP R2 root retained across run and identity mismatch has a cause" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "snap-r2-root");
    defer tmp.deinit(a, io);
    try tmp.dir.createDirPath(io, "space");
    try tmp.dir.createDirPath(io, "other");
    const space = try tmp.dir.realPathFileAlloc(io, "space", a);
    defer a.free(space);
    const other_path = try tmp.dir.realPathFileAlloc(io, "other", a);
    defer a.free(other_path);
    var baseline = try captureArtifactBaseline(a, io, defaultCapture, space, null);
    defer baseline.deinit(a);
    if (tmp.dir.rename("space", tmp.dir, "replaced", io)) |_| {
        return error.RootRetentionBypassed;
    } else |e| try testing.expect(e == error.AccessDenied or e == error.FileBusy);
    var same = try confined_fs.Root.init(a, space);
    defer same.deinit();
    try baseline.retained_root.validateIdentity(&same);
    var other = try confined_fs.Root.init(a, other_path);
    defer other.deinit();
    try testing.expectError(error.RootChanged, baseline.retained_root.validateIdentity(&other));
    baseline.retained_root.object.volume ^= 1;
    var sb = try sandbox.Sandbox.init(a, space);
    defer sb.deinit();
    var diagnostic: SnapshotDiagnostic = .{};
    try testing.expectError(error.RootChanged, collectArtifactChangesContext(a, io, defaultCapture, space, baseline, sb, .{ .diagnostic = &diagnostic }));
    try testing.expect(std.mem.indexOf(u8, diagnostic.message(), "etapa=raiz; ruta=.; error=RootChanged") != null);
}

test "SNAP R2 diagnostic paths redact before bounds and strip controls" {
    const a = testing.allocator;
    var diagnostic: SnapshotDiagnostic = .{};
    var events = CollectSink.init(a);
    defer events.deinit();
    const ctx: SnapshotContext = .{ .diagnostic = &diagnostic, .sink = events.sink() };
    for ([_][]const u8{ "sub/api_key=fixture.txt", "sub/Bearer fx-s7", "sub/ghp_fixture", "x" ** 199 ++ "/token=fx-s7" }) |path| {
        ctx.report("apertura", path, error.AccessDenied, false);
        try testing.expect(std.mem.indexOf(u8, diagnostic.message(), "ruta=[REDACTADO]") != null);
        try testing.expect(std.mem.indexOf(u8, diagnostic.message(), "fx-s7") == null);
        try testing.expect(diagnostic.message().len <= 320);
    }
    ctx.report("lectura", "sub\\x\x00\n\r\x1b.txt", error.FileChanged, false);
    try testing.expect(std.mem.indexOf(u8, diagnostic.message(), "ruta=sub/x    .txt") != null);
    for (diagnostic.message()) |c| try testing.expect(c >= 32 and c < 127);
    ctx.report("lectura", "x" ** 5000 ++ "token=fx-s7", error.SizeChanged, false);
    try testing.expect(std.mem.indexOf(u8, diagnostic.message(), "ruta=[ruta demasiado larga]") != null);
    for (events.texts.items) |text| try testing.expect(text.len <= 320);
}

test "SNAP R2 identity guard rejects another directory and corrupted baseline" {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "snap-r2-identity");
    defer tmp.deinit(a, io);
    try tmp.dir.createDirPath(io, "other");
    const other_path = try tmp.dir.realPathFileAlloc(io, "other", a);
    defer a.free(other_path);
    var baseline = try captureArtifactBaseline(a, io, defaultCapture, tmp.path, null);
    defer baseline.deinit(a);
    var other = try confined_fs.Root.init(a, other_path);
    defer other.deinit();
    try testing.expectError(error.RootChanged, baseline.retained_root.validateIdentity(&other));
    baseline.retained_root.object.volume ^= 1;
    var sb = try sandbox.Sandbox.init(a, tmp.path);
    defer sb.deinit();
    var diagnostic: SnapshotDiagnostic = .{};
    try testing.expectError(error.RootChanged, collectArtifactChangesContext(a, io, defaultCapture, tmp.path, baseline, sb, .{ .diagnostic = &diagnostic }));
    try testing.expect(std.mem.indexOf(u8, diagnostic.message(), "error=RootChanged") != null);
}

test "SNAP R2 preexisting writable default root is rejected" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "snap-r2-existing-acl");
    defer tmp.deinit(a, io);
    try tmp.dir.createDirPath(io, "devagents-workspace");
    const path = try tmp.dir.realPathFileAlloc(io, "devagents-workspace", a);
    defer a.free(path);
    var grant = try defaultCapture(a, &.{ "icacls.exe", path, "/grant", "*S-1-1-0:(F)" }, null);
    defer grant.deinit(a);
    try testing.expectEqual(@as(u32, 0), grant.exit_code);
    try testing.expectError(error.CliWritableByOthers, @import("workspace.zig").ensureExternalRoot(a, io, path));
}

test "SNAP R2 default root ACL is private even under a writable parent" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: prueba de Windows");
    const policy = @import("external_cli_policy.zig");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = try tempTree(a, io, "snap-r2-acl");
    defer tmp.deinit(a, io);
    var grant = try defaultCapture(a, &.{ "icacls.exe", tmp.path, "/grant", "*S-1-1-0:(OI)(CI)F" }, null);
    defer grant.deinit(a);
    try testing.expectEqual(@as(u32, 0), grant.exit_code);
    var parent = try confined_fs.Root.init(a, tmp.path);
    defer parent.deinit();
    try testing.expectError(error.CliWritableByOthers, policy.checkAcl(parent.dir().handle));
    const path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{tmp.path});
    defer a.free(path);
    try @import("workspace.zig").ensureExternalRoot(a, io, path);
    var private = try confined_fs.Root.init(a, path);
    defer private.deinit();
    try policy.checkAcl(private.dir().handle);
    try @import("workspace.zig").ensureExternalRoot(a, io, path);
    try testing.expectError(error.PathAlreadyExists, policy.createPrivateDirectory(a, path));
    try testing.expectError(error.InvalidExternalAgentPath, policy.createPrivateDirectory(a, "relative"));
    var fail = testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, policy.createPrivateDirectory(fail.allocator(), path));
    try testing.expectError(error.CliPermissionsUnavailable, policy.checkAcl(std.os.windows.INVALID_HANDLE_VALUE));
    const missing = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "missing" ++ std.fs.path.sep_str ++ "private", .{tmp.path});
    defer a.free(missing);
    try testing.expectError(error.FileNotFound, policy.createPrivateDirectory(a, missing));
    var unsafe_grant = try defaultCapture(a, &.{ "icacls.exe", path, "/grant", "*S-1-1-0:(F)" }, null);
    defer unsafe_grant.deinit(a);
    try testing.expectEqual(@as(u32, 0), unsafe_grant.exit_code);
    try testing.expectError(error.CliWritableByOthers, @import("workspace.zig").ensureExternalRoot(a, io, path));
}

test "SEC2 headless: prompts adversariales fuera de argv y stdin íntegro en cuatro perfiles" {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();
    const bin = (try defaultGetEnv(a, "BEATS_TEST_BIN_DIR")) orelse try a.dupe(u8, TEST_BIN_DIR);
    defer a.free(bin);
    const exe = try std.fs.path.join(a, &.{ bin, "cli-worker-mock" ++ comptime @import("builtin").target.exeFileExt() });
    defer a.free(exe);
    const prompt = "& | ^ %PATH% ! < > ( ) \"\r\nsegunda línea\n";
    const cwd = "C:\\wt & | ^ % ! < > ( ) \"";
    for (PROFILES) |profile| {
        try testing.expectEqual(PromptChannel.stdin_text, profile.prompt_channel);
        const argv = try buildArgv(a, profile, cwd, prompt);
        defer a.free(argv);
        for (argv) |arg| try testing.expect(!std.mem.eql(u8, prompt, arg));
        if (profile.cwd_flag != null) try testing.expectEqualStrings(cwd, argv[argv.len - 1]);
        const spawn_argv = try a.alloc([]const u8, argv.len + 2);
        defer a.free(spawn_argv);
        spawn_argv[0] = exe;
        spawn_argv[1] = "--headless";
        spawn_argv[2] = "echo-stdin";
        @memcpy(spawn_argv[3..], argv[1..]);
        var worker = cli_worker.ExternalCliWorker.init(a, io, spawn_argv, 15000);
        worker.stdin_mode = .prompt_text;
        var result = try worker.runCollect(a, makeTask("SEC2-stdin", prompt));
        defer result.deinit(a);
        try testing.expectEqual(@as(?u8, 0), result.exit_code);
        try testing.expect(!result.timed_out and !result.truncated);
        var echoed = try std.json.parseFromSlice([]const u8, a, result.output, .{});
        defer echoed.deinit();
        try testing.expectEqualStrings(prompt, echoed.value);
    }
}

test "QA-B H7: planificar con la CLI es de solo lectura en Claude Code, Codex y Gemini" {
    const a = testing.allocator;
    var claude = CLAUDE_CODE;
    claude.read_only = true;
    claude.deny_shell = true;
    const c = try buildArgv(a, claude, "C:\\proyecto", "plan");
    defer a.free(c);
    try std.testing.expectEqualStrings(CLAUDE_TOOLS_READ, c[c.len - 1]);
    // T12 A2: modo plan y denegación explícita, no solo una lista de permitidos.
    try std.testing.expect(argvHasPair(c, "--permission-mode", "plan"));
    try std.testing.expect(argvHasPair(c, "--disallowedTools", "Edit,Write,MultiEdit,NotebookEdit,Bash,WebFetch"));
    var settings_env = std.process.Environ.Map.init(a);
    defer settings_env.deinit();
    try settings_env.put("USERPROFILE", "C:\\synthetic-home");
    const own_settings = try external_context.claudeSettings(a, &settings_env);
    defer a.free(own_settings);
    var claude_ctx = claude;
    claude_ctx.context_settings = own_settings;
    const cs = try buildArgv(a, claude_ctx, "C:\\proyecto", "plan");
    defer a.free(cs);
    try std.testing.expect(argvHasPair(cs, "--permission-mode", "plan"));
    try std.testing.expect(argvHasPair(cs, "--disallowedTools", CLAUDE_TOOLS_DENIED_READ_ONLY));
    try std.testing.expect(argvHasPair(cs, "--settings", own_settings));
    // El --settings del contexto propio no lleva permisos ni modo que reabran nada.
    try std.testing.expect(std.mem.indexOf(u8, own_settings, "permissions") == null);
    try std.testing.expect(std.mem.indexOf(u8, own_settings, "defaultMode") == null);
    var codex = CODEX;
    codex.read_only = true;
    codex.deny_shell = true;
    const x = try buildArgv(a, codex, "C:\\proyecto", "plan");
    defer a.free(x);
    var read_only = false;
    for (x) |arg| {
        try std.testing.expect(!std.mem.eql(u8, arg, "workspace-write"));
        if (std.mem.eql(u8, arg, "read-only")) read_only = true;
    }
    try std.testing.expect(read_only);
    var gemini = GEMINI_CLI;
    gemini.read_only = true;
    const g = try buildArgv(a, gemini, "C:\\proyecto", "plan");
    defer a.free(g);
    try std.testing.expectEqualStrings("plan", g[2]);
    // Sin read_only nada cambia (Directo y Orquestado).
    const normal = try buildArgv(a, CODEX, "C:\\proyecto", "x");
    defer a.free(normal);
    var writes = false;
    for (normal) |arg| {
        if (std.mem.eql(u8, arg, "workspace-write")) writes = true;
    }
    try std.testing.expect(writes);
    var claude_edit = CLAUDE_CODE;
    claude_edit.deny_shell = true;
    const ce = try buildArgv(a, claude_edit, "C:\\proyecto", "x");
    defer a.free(ce);
    for (ce) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--permission-mode") and !std.mem.eql(u8, arg, "--disallowedTools"));
}

test "T12 A2: al planificar cada CLI recibe argumentos y entorno de solo lectura (simulador, sin CLI real)" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const bin = (try defaultGetEnv(a, "BEATS_TEST_BIN_DIR")) orelse return error.MissingMockBin;
    defer a.free(bin);
    const exe = try std.fs.path.join(a, &.{ bin, "cli-worker-mock" ++ comptime @import("builtin").target.exeFileExt() });
    defer a.free(exe);
    for (PROFILES) |original| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const wt = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(wt);
        var sb = try sandbox.Sandbox.init(a, wt);
        defer sb.deinit();
        var env = std.process.Environ.Map.init(a);
        defer env.deinit();
        try env.put("USERPROFILE", wt);
        try env.put("HOME", wt);
        // El usuario permite editar y la web en su configuración en línea: al
        // planificar no debe valer.
        try env.put("OPENCODE_CONFIG_CONTENT", "{\"permission\":{\"edit\":\"allow\",\"bash\":\"allow\",\"webfetch\":\"allow\"}}");
        var profile = original;
        profile.read_only = true;
        profile.deny_shell = true;
        var report = try run(a, io, makeTask("planner", "planifica"), sb, .{
            .profile = profile,
            .worktree = wt,
            .spawn_prefix = &.{ exe, "--headless", "permissions" },
            .timeout_ms = 15000,
            .environ_map = &env,
            .getenv = fakeGetEnv,
            .capture_fn = comp002NoGit,
        });
        defer report.deinit(a);
        try testing.expect(report.success);
        const data = try tmp.dir.readFileAlloc(io, "permissions-request.json", a, .limited(65536));
        defer a.free(data);
        var p = try std.json.parseFromSlice(std.json.Value, a, data, .{});
        defer p.deinit();
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(a);
        for (p.value.object.get("argv").?.array.items) |item| try argv.append(a, item.string);
        if (std.mem.eql(u8, original.id, CLAUDE_CODE.id)) {
            try testing.expect(argvHasPair(argv.items, "--permission-mode", "plan"));
            try testing.expect(argvHasPair(argv.items, "--disallowedTools", CLAUDE_TOOLS_DENIED_READ_ONLY));
            try testing.expect(argvHasPair(argv.items, "--allowedTools", CLAUDE_TOOLS_READ));
        } else if (std.mem.eql(u8, original.id, GEMINI_CLI.id)) {
            try testing.expect(argvHasPair(argv.items, "--approval-mode", "plan"));
        } else if (std.mem.eql(u8, original.id, CODEX.id)) {
            try testing.expect(argvHasPair(argv.items, "-s", "read-only"));
            for (argv.items) |arg| try testing.expect(!std.mem.eql(u8, arg, "workspace-write"));
        } else {
            try testing.expectEqualStrings(OPENCODE.id, original.id);
            var cfg = try std.json.parseFromSlice(std.json.Value, a, p.value.object.get("opencode_config").?.string, .{});
            defer cfg.deinit();
            const perm = cfg.value.object.get("permission").?.object;
            for (external_context.OPENCODE_READ_ONLY_DENIED) |key| try testing.expectEqualStrings("deny", perm.get(key).?.string);
        }
    }
}

fn argvHasPair(argv: []const []const u8, flag: []const u8, value: []const u8) bool {
    for (argv, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, flag) and i + 1 < argv.len and std.mem.eql(u8, argv[i + 1], value)) return true;
    }
    return false;
}

test "tanda 2: Claude Code y Gemini ejecutan comandos solo en el modo que lo permite" {
    const a = testing.allocator;
    var claude = CLAUDE_CODE;
    claude.deny_shell = true;
    const manual = try buildArgv(a, claude, "C:\\proyecto", "hola");
    defer a.free(manual);
    try std.testing.expectEqualStrings(CLAUDE_TOOLS_EDIT, manual[manual.len - 1]);
    for (manual) |arg| try std.testing.expect(std.mem.indexOf(u8, arg, "Bash") == null);
    claude.deny_shell = false;
    const auto = try buildArgv(a, claude, "C:\\proyecto", "hola");
    defer a.free(auto);
    try std.testing.expect(std.mem.indexOf(u8, auto[auto.len - 1], "Bash") != null);
    try std.testing.expect(std.mem.indexOf(u8, auto[auto.len - 1], "Task") != null);

    var gemini = GEMINI_CLI;
    gemini.deny_shell = true;
    const g_manual = try buildArgv(a, gemini, "C:\\proyecto", "hola");
    defer a.free(g_manual);
    try std.testing.expectEqualStrings("auto_edit", g_manual[2]);
    gemini.deny_shell = false;
    const g_auto = try buildArgv(a, gemini, "C:\\proyecto", "hola");
    defer a.free(g_auto);
    try std.testing.expectEqualStrings("yolo", g_auto[2]);
    for (g_auto) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "auto_edit"));
}

test "QA primerizo: Codex con permisos Manual se lanza sin terminal" {
    const a = testing.allocator;
    var profile = CODEX;
    profile.inherit_personal_context = true;
    profile.deny_shell = true;
    const argv = try buildArgv(a, profile, "C:\\proyecto", "hola");
    defer a.free(argv);
    var disabled: usize = 0;
    for (argv, 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--disable") and i + 1 < argv.len) {
            if (std.mem.eql(u8, argv[i + 1], "shell_tool") or std.mem.eql(u8, argv[i + 1], "unified_exec")) disabled += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 2), disabled);
    profile.deny_shell = false;
    const free_argv = try buildArgv(a, profile, "C:\\proyecto", "hola");
    defer a.free(free_argv);
    for (free_argv) |arg| try std.testing.expect(!std.mem.eql(u8, arg, "--disable"));
}

const T7MockAccountRunner = struct {
    exe: []const u8,
    base: []const u8,
    homes_seen: usize = 0,

    fn profile(self: *const T7MockAccountRunner) CliProfile {
        return .{
            .id = "mock-cli",
            .exe = self.exe,
            .argv_prefix = &.{"--headless"},
            .prompt_channel = .argv_tail,
            .output_mode = .stream_json_lines,
            .permission_note = "mock",
            .turn_cap_note = "mock",
        };
    }

    fn call(ctx: ?*anyopaque, a: std.mem.Allocator, io: std.Io, task: planner.PlannedTask, req: @import("external_agents.zig").RunRequest, sb: sandbox.Sandbox) anyerror!@import("external_agents.zig").RunOutcome {
        const self: *T7MockAccountRunner = @ptrCast(@alignCast(ctx.?));
        if (req.environ_map.?.get("CODEX_HOME") != null) self.homes_seen += 1;
        var report = try run(a, io, task, sb, .{
            .profile = self.profile(),
            .worktree = req.worktree,
            .base_commit = self.base,
            .timeout_ms = 30000,
            .environ_map = req.environ_map,
            .getenv = fakeGetEnv,
        });
        defer report.deinit(a);
        return .{
            .success = report.success,
            .exit_code = report.exit_code,
            .agent_version = try a.dupe(u8, ""),
            .argv_censored = try a.dupe(u8, ""),
            .declaration = try a.dupe(u8, report.declaration),
            .detail = try a.dupe(u8, report.transcript),
            .artifacts = &.{},
        };
    }
};

const T7RotationLog = struct {
    count: usize = 0,
    text: [256]u8 = undefined,
    len: usize = 0,
    fn notify(ctx: ?*anyopaque, notice: @import("cli_accounts.zig").RotationNotice) void {
        const self: *T7RotationLog = @ptrCast(@alignCast(ctx.?));
        self.count += 1;
        const message = @import("cli_accounts.zig").noticeText(testing.allocator, notice) catch @panic("T7: aviso");
        defer testing.allocator.free(message);
        const n = @min(message.len, self.text.len);
        @memcpy(self.text[0..n], message[0..n]);
        self.len = n;
    }
};

test "T7 cuentas: CLI simulada agota la cuota con una cuenta y la orden sigue con la siguiente" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const cli_accounts = @import("cli_accounts.zig");
    const allocator = testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const wt = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(wt);
    const base = (try gitInitWorktree(allocator, io, wt)) orelse return error.SkipZigTest;
    defer allocator.free(base);
    const test_bin_dir = (try defaultGetEnv(allocator, "BEATS_TEST_BIN_DIR")) orelse try allocator.dupe(u8, TEST_BIN_DIR);
    defer allocator.free(test_bin_dir);
    const exe_path = try std.fs.path.join(allocator, &.{ test_bin_dir, "cli-worker-mock" ++ comptime @import("builtin").target.exeFileExt() });
    defer allocator.free(exe_path);
    var sb = try sandbox.Sandbox.init(allocator, wt);
    defer sb.deinit();
    // Carpetas sintéticas (nunca las de las CLIs del usuario).
    const accounts = [_]cli_accounts.Account{
        .{ .id = "codex-1", .cli = "codex", .label = "Trabajo", .dir = "E:\\t7-sintetico\\cli-accounts\\codex\\codex-1-agotada" },
        .{ .id = "codex-2", .cli = "codex", .label = "Personal", .dir = "E:\\t7-sintetico\\cli-accounts\\codex\\codex-2" },
    };
    var env = try @import("platform.zig").environ().createMap(allocator);
    defer env.deinit();
    _ = env.swapRemove("CODEX_HOME");
    var runner = T7MockAccountRunner{ .exe = exe_path, .base = base };
    var log = T7RotationLog{};
    const req = @import("external_agents.zig").RunRequest{
        .meta = @import("external_agents.zig").metaForProvider("agent:codex").?,
        .worktree = wt,
        .prompt = "quota-account",
        .timeout_ms = 30000,
        .max_turns = 0,
    };
    var outcome = try cli_accounts.runRotating(T7MockAccountRunner.call, &runner, allocator, io, makeTask("t-t7-cuentas", "quota-account"), req, sb, &env, &accounts, "codex-1", T7RotationLog.notify, &log);
    defer outcome.deinit(allocator);
    try testing.expect(outcome.success);
    try testing.expect(std.mem.indexOf(u8, outcome.declaration, "hecho con codex-2") != null);
    try testing.expectEqual(@as(usize, 2), runner.homes_seen);
    try testing.expectEqual(@as(usize, 1), log.count);
    try testing.expectEqualStrings("La cuenta «Trabajo» de Codex agotó su cuota; sigue con «Personal».", log.text[0..log.len]);
    // El entorno base (login del sistema) no recibió ninguna cuenta.
    try testing.expect(env.get("CODEX_HOME") == null);
}
