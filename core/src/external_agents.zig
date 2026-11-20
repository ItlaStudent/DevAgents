const std = @import("std");
const builtin = @import("builtin");
const test_cli_guard = @import("external_cli_test_guard.zig");
const planner = @import("planner.zig");
const sandbox = @import("sandbox.zig");
const worker_backend = @import("worker_backend.zig");
const headless_adapter = @import("headless_adapter.zig");
const acp_client = @import("acp_client.zig");
const executor = @import("executor.zig");
const db = @import("db.zig");
const health = @import("health.zig");
const providers = @import("providers");
const catalog = @import("external_agent_catalog.zig");
const cli_policy = @import("external_cli_policy.zig");
const process_tree = @import("process_tree.zig");

const GetTickCount64 = @import("platform.zig").ticks;
const GetTempPathA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetTempPathA(nBufferLength: u32, lpBuffer: [*]u8) u32;
}.GetTempPathA else @import("platform.zig").tempPath;
const CreateDirectoryA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateDirectoryA(lpPathName: [*:0]const u8, lpSecurityAttributes: ?*anyopaque) c_int;
}.CreateDirectoryA else @import("providers").posix_files.CreateDirectoryA;
const RemoveDirectoryA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn RemoveDirectoryA(lpPathName: [*:0]const u8) c_int;
}.RemoveDirectoryA else @import("providers").posix_files.RemoveDirectoryA;
const CreateFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateFileA(lpFileName: [*:0]const u8, dwDesiredAccess: u32, dwShareMode: u32, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: u32, dwFlagsAndAttributes: u32, hTemplateFile: ?*anyopaque) std.os.windows.HANDLE;
}.CreateFileA else @import("providers").posix_files.CreateFileA;
const WriteFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn WriteFile(hFile: std.os.windows.HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: ?*u32, lpOverlapped: ?*anyopaque) c_int;
}.WriteFile else @import("providers").posix_files.WriteFile;
const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(hObject: std.os.windows.HANDLE) c_int;
}.CloseHandle else @import("providers").posix_files.CloseHandle;
const DeleteFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn DeleteFileA(lpFileName: [*:0]const u8) c_int;
}.DeleteFileA else @import("providers").posix_files.DeleteFileA;
const SetEnvironmentVariableA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn SetEnvironmentVariableA(lpName: [*:0]const u8, lpValue: ?[*:0]const u8) c_int;
}.SetEnvironmentVariableA else @import("providers").posix_files.SetEnvironmentVariableA;
const GetEnvironmentVariableA = @import("platform.zig").env;

// ═══════════════════════════════════════════════════════════════════════════
// E5.08 — Gobierno encima: agentes externos (CLIs con suscripción del usuario)
// dentro del despacho gobernado del superagente.
//
// Registro: cada CLI conocido se detecta en runtime (`<exe> --version` vía
// CaptureFn — mismo seam que git) y se expone como proveedor `agent:<cli_id>`
// por C-ABI/MCP/cabina, elegible como pin de ejecución y miembro del enjambre.
//
// Despacho: una rama DENTRO del bucle de candidatos de runTaskInWave — el
// resultado es un WorkerResult como el del worker nativo (mismos gates,
// eventos, auditoría, ship y checkpoint/resume; no es una tubería paralela).
//
// Auditoría cruzada: el auditor nunca es del mismo fabricante que el
// productor (claude-code ↔ Anthropic/Claude, codex ↔ OpenAI/GPT,
// gemini-cli ↔ Google/Gemini, opencode ↔ OpenCode). Amplía la exclusión
// anti auto-auditoría por modelo exacto.
//
// Coste: usage_records con cost_category='subscription', tokens solo si el
// agente los informa, dólares nulos — nunca inventados.
//
// Límites: reloj y turnos por tarea y por orden, configurables; al superarlos
// el proceso se mata y la tarea falla honesto (timeout/turn_limited).
//
// Permisos: leer/editar dentro del worktree permitido; comandos pasan por
// executor.checkPrefix (normal/accept_edits → tarjeta de aprobación de la
// cabina; bypass/autonomous → auto); fuera del worktree siempre denegado —
// ACP lo resuelve por la misma seam de gobernanza (session/request_permission).
// ═══════════════════════════════════════════════════════════════════════════

/// Prefijo de proveedor estilo model_router para agentes externos.
pub const PROVIDER_PREFIX = "agent:";

/// Fabricante del agente — la unidad de la exclusión cruzada de auditoría.
pub const Manufacturer = catalog.Manufacturer;
pub const Session = catalog.Session;
pub const EnumerationStatus = catalog.EnumerationStatus;
pub const DetectedModel = catalog.Model;

/// Ficha estática de un CLI conocido. `acp_argv` = cómo se levanta el agente
/// en modo ACP (null = sin ACP en la versión verificada → va por headless).
pub const AgentMeta = struct {
    cli_id: []const u8,
    exe: []const u8,
    display: []const u8,
    manufacturer: Manufacturer,
    acp_argv: ?[]const []const u8,
};

/// Los cuatro CLIs de E5.01/E5.07. Versiones verificadas en evidencia:
/// claude 2.1.221, codex 0.144.4, gemini 0.53.1, opencode 1.18.25.
/// ACP verificado: gemini `--acp` nativo, opencode subcomando `acp`;
/// claude y codex no exponen ACP en esta versión (E5.01).
pub const AGENTS = [_]AgentMeta{
    .{ .cli_id = "claude-code", .exe = "claude", .display = "Claude Code", .manufacturer = .anthropic, .acp_argv = null },
    .{ .cli_id = "codex", .exe = "codex", .display = "Codex", .manufacturer = .openai, .acp_argv = null },
    .{ .cli_id = "gemini-cli", .exe = "gemini", .display = "Gemini CLI", .manufacturer = .google, .acp_argv = &.{"--acp"} },
    .{ .cli_id = "opencode", .exe = "opencode", .display = "OpenCode", .manufacturer = .opencode, .acp_argv = &.{"acp"} },
};

/// command_prefix de las tarjetas de permiso que levanta el puente ACP
/// (session/request_permission → aprobación persistida). La cabina une las
/// filas DB con este prefijo a la lista en memoria igual que hace con
/// worktree_script (E5.05) — sin la unión la tarjeta es invisible.
pub const ACP_APPROVAL_PREFIX: []const u8 = "agent_acp";

pub fn isAgentProvider(provider: []const u8) bool {
    return std.mem.startsWith(u8, provider, PROVIDER_PREFIX) and provider.len > PROVIDER_PREFIX.len;
}

pub fn metaForCliId(cli_id: []const u8) ?AgentMeta {
    for (AGENTS) |m| {
        if (std.mem.eql(u8, m.cli_id, cli_id)) return m;
    }
    return null;
}

/// Meta del agente para un provider `agent:<cli_id>`; null si no es agente
/// o el cli_id no está en la tabla conocida.
pub fn metaForProvider(provider: []const u8) ?AgentMeta {
    if (!isAgentProvider(provider)) return null;
    return metaForCliId(provider[PROVIDER_PREFIX.len..]);
}

/// `agent:<cli_id>` en buf (formato model_router para pines/enjambre).
pub fn providerName(buf: []u8, meta: AgentMeta) []const u8 {
    return std.fmt.bufPrint(buf, "{s}{s}", .{ PROVIDER_PREFIX, meta.cli_id }) catch unreachable;
}

/// Fabricante de un proveedor: agente externo por su tabla, o proveedor de
/// catálogo por nombre (Claude→anthropic, GPT/OpenAI→openai,
/// Gemini/Google AI Studio→google, OpenCode→opencode). null = desconocido
/// (proveedor sin agente asociado — la regla antigua por modelo sigue).
pub fn manufacturerOf(provider: []const u8) ?Manufacturer {
    if (metaForProvider(provider)) |m| return m.manufacturer;
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(provider, "Claude") or eq(provider, "Anthropic")) return .anthropic;
    if (eq(provider, "GPT") or eq(provider, "OpenAI")) return .openai;
    if (eq(provider, "Gemini") or eq(provider, "Google") or eq(provider, "Google AI Studio")) return .google;
    if (eq(provider, "OpenCode")) return .opencode;
    if (eq(provider, "Cohere")) return .cohere;
    if (eq(provider, "Mistral")) return .mistral;
    if (eq(provider, "DeepSeek")) return .deepseek;
    if (eq(provider, "Qwen") or eq(provider, "Alibaba")) return .qwen;
    if (eq(provider, "xAI")) return .xai;
    if (eq(provider, "Meta")) return .meta;
    if (eq(provider, "Moonshot")) return .moonshot;
    if (eq(provider, "Minimax")) return .minimax;
    if (eq(provider, "Z.AI")) return .zai;
    return null;
}

/// Regla E5.08: un auditor de catálogo NO puede ser del mismo fabricante que
/// un agente externo productor (y viceversa). Solo aplica cuando alguno de los
/// dos es `agent:*` — la anti auto-auditoría catálogo↔catálogo sigue siendo
/// por modelo exacto (exclude_models del router).
pub fn crossManufacturerExcluded(producer_provider: []const u8, candidate_provider: []const u8) bool {
    if (!isAgentProvider(producer_provider) and !isAgentProvider(candidate_provider)) return false;
    const mp = manufacturerOf(producer_provider) orelse return false;
    const mc = manufacturerOf(candidate_provider) orelse return false;
    return mp == mc;
}

/// Cross-manufacturer audit guard for model-specific CLI catalogs. Unknown
/// agent manufacturers cannot establish independent auditing: fail closed.
pub fn crossModelManufacturerExcluded(producer_provider: []const u8, producer_model: []const u8, candidate_provider: []const u8, candidate_model: []const u8) bool {
    const mp = modelManufacturer(producer_provider, producer_model);
    const mc = modelManufacturer(candidate_provider, candidate_model);
    if (mp == .unknown or mc == .unknown) return true;
    return mp == mc;
}

pub fn modelManufacturer(provider: []const u8, model: []const u8) Manufacturer {
    if (metaForProvider(provider)) |m| return catalog.manufacturerFor(m.cli_id, model);
    // Gateways are not manufacturers. Model families take precedence there.
    const family = catalog.manufacturerFor("gateway", model);
    if (family != .unknown) return family;
    if (manufacturerOf(provider)) |m| return m;
    return .unknown;
}

// ── Detección en runtime ──────────────────────────────────────────────────

/// Un agente detectado en esta máquina: exe presente + versión real.
/// Todas las cadenas son owned (liberar con deinit).
pub const DetectedAgent = struct {
    provider: []u8,
    cli: []u8,
    display: []u8,
    exe: []u8,
    version: ?[]u8,
    acp: bool,
    manufacturer: Manufacturer,
    models: []DetectedModel = &.{},
    session: Session = .desconocida,
    session_reason: ?[]u8 = null,
    enumeration_status: EnumerationStatus = .no_enumerable,
    detected_at_ms: u64 = 0,
    selection_reason: []const u8 = "PATH",
    authenticode_code: ?i32 = null,
    acl_appcontainer_sids: ?[]u8 = null,
    /// B1: escritores huérfanos aceptados en la instalación elegida (una SID
    /// por línea); Configuración lo muestra como «aceptado; escritor huérfano».
    acl_orphan_sids: ?[]u8 = null,
    codex_home_id: ?[]u8 = null,
    /// 10-nov (USUARIO-NUEVO A1): variables de facturación del anfitrión que
    /// esta CLI leería y que DevAgents le quita (nombres, nunca valores).
    ignored_env: ?[]u8 = null,
    /// A4: por qué no se pudo listar sus modelos, con lo que dijo la CLI.
    enumeration_reason: ?[]u8 = null,
    /// A2: otras instalaciones encontradas que no se eligieron, y por qué.
    rejected: []Rejected = &.{},
    /// A4: huella del ejecutable (última escritura) para invalidar la caché
    /// cuando la CLI se actualiza. null = no se pudo leer.
    exe_stamp: ?u64 = null,

    pub fn deinit(self: *DetectedAgent, allocator: std.mem.Allocator) void {
        allocator.free(self.provider);
        allocator.free(self.cli);
        allocator.free(self.display);
        allocator.free(self.exe);
        if (self.version) |v| allocator.free(v);
        if (self.acl_appcontainer_sids) |s| allocator.free(s);
        if (self.acl_orphan_sids) |s| allocator.free(s);
        if (self.codex_home_id) |s| allocator.free(s);
        if (self.session_reason) |s| allocator.free(s);
        if (self.ignored_env) |s| allocator.free(s);
        if (self.enumeration_reason) |s| allocator.free(s);
        for (self.rejected) |*r| r.deinit(allocator);
        if (self.rejected.len > 0) allocator.free(self.rejected);
        for (self.models) |*m| m.deinit(allocator);
        if (self.models.len > 0) allocator.free(self.models);
    }
};

/// Una instalación encontrada y no elegida (A2): antes se descartaba en
/// silencio y el usuario no sabía por qué se usaba otra versión.
pub const Rejected = struct {
    path: []u8,
    version: ?[]u8,
    reason: []u8,
    pub fn deinit(self: *Rejected, a: std.mem.Allocator) void {
        a.free(self.path);
        if (self.version) |v| a.free(v);
        a.free(self.reason);
    }
};

extern "version" fn GetFileVersionInfoSizeW(name: [*:0]const u16, handle: ?*u32) callconv(.winapi) u32;
extern "version" fn GetFileVersionInfoW(name: [*:0]const u16, handle: u32, len: u32, data: *anyopaque) callconv(.winapi) c_int;
extern "version" fn VerQueryValueW(block: *const anyopaque, sub: [*:0]const u16, out: *?*anyopaque, len: *u32) callconv(.winapi) c_int;
const GetFileAttributesExW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileAttributesExW(name: [*:0]const u16, level: c_int, info: *anyopaque) callconv(.winapi) c_int;
}.GetFileAttributesExW else @import("providers").posix_files.GetFileAttributesExW;

/// Versión del recurso de un .exe SIN ejecutarlo (una instalación rechazada
/// no se lanza). null si no tiene recurso de versión o no es un .exe.
pub fn fileVersion(a: std.mem.Allocator, path: []const u8) !?[]u8 {
    if (@import("builtin").os.tag != .windows) return null;
    if (!std.ascii.endsWithIgnoreCase(path, ".exe")) return null;
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    const size = GetFileVersionInfoSizeW(wide, null);
    if (size == 0 or size > 4 * 1024 * 1024) return null;
    const data = try a.alignedAlloc(u8, .of(u32), size);
    defer a.free(data);
    if (GetFileVersionInfoW(wide, 0, size, data.ptr) == 0) return null;
    var ptr: ?*anyopaque = null;
    var len: u32 = 0;
    if (VerQueryValueW(data.ptr, std.unicode.utf8ToUtf16LeStringLiteral("\\"), &ptr, &len) == 0 or ptr == null or len < 16) return null;
    const words: [*]const u32 = @ptrCast(@alignCast(ptr.?));
    if (words[0] != 0xFEEF04BD) return null;
    const ms = words[2];
    const ls = words[3];
    return try std.fmt.allocPrint(a, "{d}.{d}.{d}", .{ ms >> 16, ms & 0xffff, ls >> 16 });
}

/// Huella de la instalación: última escritura del ejecutable y, para un shim
/// de npm, también la de su carpeta `node_modules` (npm reemplaza el paquete,
/// no el .cmd). null si no se puede leer.
pub fn exeStamp(a: std.mem.Allocator, exe: []const u8) !?u64 {
    var stamp: u64 = (try lastWrite(a, exe)) orelse return null;
    if (std.ascii.endsWithIgnoreCase(exe, ".cmd")) {
        if (std.fs.path.dirnameWindows(exe)) |dir| {
            const modules = try std.fs.path.join(a, &.{ dir, "node_modules" });
            defer a.free(modules);
            if (try lastWrite(a, modules)) |t| stamp = @max(stamp, t);
        }
    }
    return stamp;
}

fn lastWrite(a: std.mem.Allocator, path: []const u8) !?u64 {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    var info: extern struct { attributes: u32, creation: [2]u32, access: [2]u32, write: [2]u32, size_high: u32, size_low: u32 } = undefined;
    if (GetFileAttributesExW(wide, 0, &info) == 0) return null;
    return (@as(u64, info.write[1]) << 32) | info.write[0];
}

fn dupeOwned(allocator: std.mem.Allocator, s: []const u8) ![]u8 {
    return try allocator.dupe(u8, s);
}

/// Extrae la versión del stdout de `<exe> --version`. e5-harden punto 5: las
/// líneas que son el aviso del intérprete (`Node.js v22…`, `node …`, `npm …`)
/// no cuentan, para que la versión de node no pase por la de la CLI. Se
/// prefiere el primer token semver completo (2.1.322, 0.68.0-preview.1); si
/// no hay, el primer token que empiece por dígito y tenga un punto (1.2); si
/// tampoco, la primera línea no vacía recortada a 64. null = salida vacía.
pub fn parseVersionText(allocator: std.mem.Allocator, stdout: []const u8) !?[]u8 {
    var dotted: ?[]const u8 = null;
    var first_line: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0 or isInterpreterBanner(line)) continue;
        if (first_line == null) first_line = line;
        var it = std.mem.tokenizeAny(u8, line, " \t,()[]");
        while (it.next()) |raw_tok| {
            // Tolerar prefijo `v`/`version` (`gemini-cli v0.53.1`).
            const tok = if (raw_tok.len > 1 and (raw_tok[0] == 'v' or raw_tok[0] == 'V') and std.ascii.isDigit(raw_tok[1])) raw_tok[1..] else raw_tok;
            if (tok.len == 0 or tok.len > 64 or !std.ascii.isDigit(tok[0])) continue;
            if (std.SemanticVersion.parse(tok)) |_| return try dupeOwned(allocator, tok) else |_| {}
            if (dotted == null and std.mem.indexOfScalar(u8, tok, '.') != null) dotted = tok;
        }
    }
    if (dotted) |tok| return try dupeOwned(allocator, tok);
    if (first_line) |line| return try dupeOwned(allocator, line[0..@min(line.len, 64)]);
    return null;
}

fn isInterpreterBanner(line: []const u8) bool {
    return std.ascii.startsWithIgnoreCase(line, "Node.js") or std.ascii.startsWithIgnoreCase(line, "node ") or std.ascii.startsWithIgnoreCase(line, "npm ");
}

test "HARD5. --version ignores the interpreter banner and prefers a full semver" {
    const a = std.testing.allocator;
    const cases = [_][2][]const u8{
        .{ "Node.js v22.11.0\n0.68.0\n", "0.68.0" },
        .{ "npm warn config 10.9.0\ncodex-cli 0.159.2\n", "0.159.2" },
        .{ "2.1.322 (Claude Code)\n", "2.1.322" },
        .{ "gemini-cli v0.53.1\n", "0.53.1" },
        .{ "opencode 1.2\n", "1.2" },
        .{ "build 0.9.0-preview.1+abc\n", "0.9.0-preview.1+abc" },
        .{ "Node.js v22.11.0\nnightly\n", "nightly" },
    };
    for (cases) |case| {
        const got = (try parseVersionText(a, case[0])).?;
        defer a.free(got);
        try std.testing.expectEqualStrings(case[1], got);
    }
    try std.testing.expect((try parseVersionText(a, "Node.js v22.11.0\n\n")) == null);
    try std.testing.expect((try parseVersionText(a, "")) == null);
}

/// Resuelve el exe del CLI a una ruta absoluta: `.exe`, `.cmd`, `.bat` en
/// ese orden. Los CLIs npm solo existen como shim `.cmd` (codex, gemini,
/// opencode en esta máquina) y ni CreateProcessA ni std.process.spawn los
/// resuelven por nombre — sin esto la detección y el despacho los perdían.
/// Reutiliza los resolvedores del ejecutor (SearchPathA con PATH explícito,
/// safe-searchmode, invariante de ruta absoluta). null = ausente en PATH.
/// POSIX: el nombre tal cual (spawn/capture resuelven por PATH ahí).
pub fn resolveCliExe(allocator: std.mem.Allocator, exe: []const u8) !?[]u8 {
    if (builtin.os.tag != .windows) return try allocator.dupe(u8, exe);
    for ([_][:0]const u8{ ".exe", ".cmd", ".bat" }) |ext| {
        const resolved = executor.resolveAllowedExeExt(allocator, exe, ext) catch |e| {
            if (e == error.OutOfMemory) return e;
            continue;
        };
        defer allocator.free(resolved);
        test_cli_guard.check(allocator, resolved) catch continue;
        var trusted = cli_policy.verify(allocator, resolved) catch |e| {
            if (e == error.OutOfMemory) return e;
            continue;
        };
        defer trusted.deinit();
        return try allocator.dupe(u8, trusted.path);
    }
    return null;
}

/// Seam de resolución del exe (producción: resolveCliExe real sobre PATH;
/// las pruebas inyectan una fija para no depender de los CLIs instalados).
pub const ResolveFn = *const fn (allocator: std.mem.Allocator, exe: []const u8) anyerror!?[]u8;

fn defaultResolve(allocator: std.mem.Allocator, exe: []const u8) anyerror!?[]u8 {
    return resolveCliExe(allocator, exe);
}

/// Prefijo owned: npm se lanza como node.exe + script verificados. Un batch
/// no resuelto conserva su ruta para el escapado específico del ejecutor.
fn spawnPrefixFor(allocator: std.mem.Allocator, resolved: []u8) ![][]const u8 {
    defer allocator.free(resolved);
    if (executor.isBatchShim(resolved)) {
        var launch = try executor.prepareBatchLaunch(allocator, resolved);
        defer launch.deinit(allocator);
        return copyLaunchPrefix(allocator, &launch);
    }
    return rawSpawnPrefix(allocator, resolved);
}

fn copyLaunchPrefix(allocator: std.mem.Allocator, launch: *const executor.BatchLaunch) ![][]const u8 {
    var pre = std.ArrayList([]const u8).empty;
    errdefer {
        for (pre.items) |entry| allocator.free(entry);
        pre.deinit(allocator);
    }
    {
        const owned = try allocator.dupe(u8, launch.exe);
        errdefer allocator.free(owned);
        try pre.append(allocator, owned);
    }
    for (launch.prefix) |entry| {
        const owned = try allocator.dupe(u8, entry);
        errdefer allocator.free(owned);
        try pre.append(allocator, owned);
    }
    return pre.toOwnedSlice(allocator);
}

fn rawSpawnPrefix(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    const pre = try allocator.alloc([]const u8, 1);
    errdefer allocator.free(pre);
    pre[0] = try allocator.dupe(u8, path);
    return pre;
}

/// The selected discovery binary is passed unchanged to headless/ACP spawn.
pub fn spawnPrefixForPath(allocator: std.mem.Allocator, path: []const u8) ![][]const u8 {
    var verified = try cli_policy.verify(allocator, path);
    defer verified.deinit();
    return spawnPrefixFor(allocator, try allocator.dupe(u8, verified.path));
}

fn validBinaryPath(path: []const u8) bool {
    return cli_policy.validBinaryPath(path);
}

/// Resuelve el exe y devuelve el prefijo de spawn. null = ausente en PATH.
fn spawnPrefix(allocator: std.mem.Allocator, exe: []const u8) !?[][]const u8 {
    const resolved = (try resolveCliExe(allocator, exe)) orelse return null;
    return try spawnPrefixFor(allocator, resolved);
}

pub fn freeSpawnPrefix(allocator: std.mem.Allocator, pre: []const []const u8) void {
    for (pre) |s| allocator.free(@constCast(s));
    allocator.free(pre);
}

/// Detecta UN agente: `<exe> --version` por el seam de captura (producción:
/// runCmdCaptureWin32Input real). null = exe ausente o versión no legible.
/// `.exe` queda con la RUTA RESUELTA que correrá el despacho.
pub fn detectOne(
    allocator: std.mem.Allocator,
    capture: headless_adapter.CaptureFn,
    meta: AgentMeta,
    resolve: ?ResolveFn,
) !?DetectedAgent {
    const resolve_fn = resolve orelse defaultResolve;
    const resolved = (try resolve_fn(allocator, meta.exe)) orelse return null;
    defer allocator.free(resolved);
    // Los resolvedores/capturas sintéticos sólo existen dentro de tests;
    // producción prepara siempre la cadena de confianza real.
    var launch: ?executor.BatchLaunch = null;
    defer if (launch) |*value| value.deinit(allocator);
    const prefix = if (builtin.is_test and resolve != null)
        try rawSpawnPrefix(allocator, resolved)
    else blk: {
        launch = executor.prepareBatchLaunch(allocator, resolved) catch return null;
        break :blk try copyLaunchPrefix(allocator, &launch.?);
    };
    defer freeSpawnPrefix(allocator, prefix);
    const argv = try allocator.alloc([]const u8, prefix.len + 1);
    defer allocator.free(argv);
    @memcpy(argv[0..prefix.len], prefix);
    argv[prefix.len] = "--version";
    const capture_fn = if (resolve == null and capture == defaultCapture) discoveryCapture else capture;
    var cap = capture_fn(allocator, argv, null) catch return null;
    defer cap.deinit(allocator);
    if (cap.exit_code != 0) return null;
    const version = (try parseVersionText(allocator, cap.stdout)) orelse return null;
    return .{
        .provider = try std.fmt.allocPrint(allocator, "{s}{s}", .{ PROVIDER_PREFIX, meta.cli_id }),
        .cli = try dupeOwned(allocator, meta.cli_id),
        .display = try dupeOwned(allocator, meta.display),
        .exe = try dupeOwned(allocator, resolved),
        .version = version,
        .acp = meta.acp_argv != null,
        .manufacturer = meta.manufacturer,
    };
}

/// Registro en runtime: los agentes conocidos presentes en esta máquina.
/// `capture`/`resolve` null = captura y resolución reales de proceso/PATH.
pub fn detectAll(allocator: std.mem.Allocator, capture: ?headless_adapter.CaptureFn, resolve: ?ResolveFn) ![]DetectedAgent {
    if (capture == null and resolve == null) return detectAllWithPaths(allocator, null, null);
    const cap_fn = capture orelse discoveryCapture;
    var list = std.ArrayList(DetectedAgent).empty;
    errdefer {
        for (list.items) |*d| d.deinit(allocator);
        list.deinit(allocator);
    }
    for (AGENTS) |meta| {
        if (try detectOne(allocator, cap_fn, meta, resolve)) |d| try list.append(allocator, d);
    }
    return list.toOwnedSlice(allocator);
}

fn defaultCapture(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) anyerror!providers.github.CmdCapture {
    try test_cli_guard.checkArgv(allocator, argv);
    return providers.github.runCmdCaptureWin32Input(allocator, argv, cwd, null, null);
}

/// Quota-free discovery uses the existing pinned executor: short deadline,
/// bounded output and job containment (including npm shim descendants).
fn discoveryCapture(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) anyerror!providers.github.CmdCapture {
    try test_cli_guard.checkArgv(allocator, argv);
    if (argv.len == 0) return error.InvalidExternalAgentPath;
    const target = if (argv.len >= 4 and std.mem.eql(u8, argv[1], "/d") and std.mem.eql(u8, argv[2], "/c")) argv[3] else argv[0];
    var verified = try cli_policy.verify(allocator, target);
    defer verified.deinit();
    var script: ?cli_policy.VerifiedBinary = null;
    defer if (script) |*value| value.deinit();
    if (std.ascii.eqlIgnoreCase(executor.basename(target), "node.exe") and argv.len > 1 and std.ascii.endsWithIgnoreCase(argv[1], ".js"))
        script = try cli_policy.verifyScript(allocator, argv[1]);
    return discoveryCaptureWithLimits(allocator, argv, cwd, 8000, 4 * 1024 * 1024);
}

fn discoveryCaptureWithLimits(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, timeout_ms: u32, output_cap: usize) anyerror!providers.github.CmdCapture {
    const environment = try cli_policy.probeEnvironment(allocator, cli_policy.getEnv);
    defer allocator.free(environment);
    return discoveryCaptureWithEnvironment(allocator, argv, cwd, timeout_ms, output_cap, environment);
}

fn discoveryCaptureWithEnvironment(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, timeout_ms: u32, output_cap: usize, environment: [:0]const u16) anyerror!providers.github.CmdCapture {
    try test_cli_guard.checkArgv(allocator, argv);
    if (@import("builtin").os.tag != .windows) return error.ExternalCliUnavailableOnLinux;
    if (argv.len == 0) return error.InvalidExternalAgentPath;
    var cwd_buf: [32768]u8 = undefined;
    const cwd_len = GetCurrentDirectoryA(cwd_buf.len, &cwd_buf);
    if (cwd_len == 0 or cwd_len >= cwd_buf.len) return error.CurrentDirectoryUnavailable;
    const dir = cwd orelse cwd_buf[0..cwd_len];
    var result = try executor.runVerifierPinned(allocator, .{ .workspace_root = dir, .timeout_ms = timeout_ms, .max_output_bytes = output_cap, .environment = environment }, argv[0], argv[1..], dir);
    if (result.timed_out) {
        result.deinit(allocator);
        return error.Timeout;
    }
    if (result.stdoutTruncated() or result.stderrTruncated()) {
        result.deinit(allocator);
        return error.OutputLimitExceeded;
    }
    return .{ .exit_code = if (result.exit_code >= 0) @intCast(result.exit_code) else 1, .stdout = @constCast(result.stdout), .stderr = @constCast(result.stderr) };
}

const GetCurrentDirectoryA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetCurrentDirectoryA(nBufferLength: u32, lpBuffer: [*]u8) callconv(.winapi) u32;
}.GetCurrentDirectoryA else @import("platform.zig").cwd;
const CliFileTime = extern struct { low: u32, high: u32 };
const GetSystemTimeAsFileTime = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *CliFileTime) callconv(.winapi) void;
}.GetSystemTimeAsFileTime else @import("platform.zig").filetime;

fn nowMillis() u64 {
    var ft: CliFileTime = undefined;
    GetSystemTimeAsFileTime(&ft);
    return ((@as(u64, ft.high) << 32) | ft.low) / 10000 -| 11644473600000;
}

fn captureForPath(allocator: std.mem.Allocator, capture: headless_adapter.CaptureFn, path: []const u8, args: []const []const u8) !providers.github.CmdCapture {
    return captureForPathEnvironment(allocator, capture, path, args, null);
}

fn captureForPathEnvironment(allocator: std.mem.Allocator, capture: headless_adapter.CaptureFn, path: []const u8, args: []const []const u8, env: ?*const std.process.Environ.Map) !providers.github.CmdCapture {
    var launch: ?executor.BatchLaunch = null;
    defer if (launch) |*value| value.deinit(allocator);
    const prefix = if (builtin.is_test and capture != defaultCapture and capture != discoveryCapture)
        try rawSpawnPrefix(allocator, path)
    else blk: {
        launch = try executor.prepareBatchLaunch(allocator, path);
        break :blk try copyLaunchPrefix(allocator, &launch.?);
    };
    defer freeSpawnPrefix(allocator, prefix);
    const argv = try allocator.alloc([]const u8, prefix.len + args.len);
    defer allocator.free(argv);
    @memcpy(argv[0..prefix.len], prefix);
    @memcpy(argv[prefix.len..], args);
    if (env) |map| {
        var verified = try cli_policy.verify(allocator, path);
        defer verified.deinit();
        const block = try map.createWindowsBlock(allocator, .{});
        defer block.deinit(allocator);
        return discoveryCaptureWithEnvironment(allocator, argv, null, 8000, 4 * 1024 * 1024, block.slice);
    }
    return capture(allocator, argv, null);
}

/// Candidate selection seam. Production supplies only PATH and documented
/// per-CLI locations; tests inject versions without installed CLI dependence.
pub fn detectCandidates(allocator: std.mem.Allocator, capture: headless_adapter.CaptureFn, meta: AgentMeta, paths: []const []const u8, forced: bool) !?DetectedAgent {
    return detectCandidatesImpl(allocator, capture, meta, paths, forced, true);
}

// Explicit synthetic seam: only private tests disable filesystem verification.
fn detectCandidatesImpl(allocator: std.mem.Allocator, capture: headless_adapter.CaptureFn, meta: AgentMeta, paths: []const []const u8, forced: bool, check_origin: bool) !?DetectedAgent {
    return detectCandidatesWithVerifier(allocator, capture, meta, paths, forced, if (check_origin) cli_policy.verify else null);
}

const VerifyFn = *const fn (std.mem.Allocator, []const u8) anyerror!cli_policy.VerifiedBinary;

/// A2: deja constancia de una instalación no elegida. Una ruta repetida (el
/// PATH y las rutas conocidas pueden coincidir) se anota una sola vez.
fn noteRejected(a: std.mem.Allocator, list: *std.ArrayList(Rejected), path: []const u8, version: ?[]const u8, reason: []const u8) !void {
    for (list.items) |r| if (std.ascii.eqlIgnoreCase(r.path, path)) return;
    const p = try a.dupe(u8, path);
    errdefer a.free(p);
    const v = if (version) |text| try a.dupe(u8, text) else try fileVersion(a, path);
    errdefer if (v) |text| a.free(text);
    const r = try a.dupe(u8, reason);
    errdefer a.free(r);
    try list.append(a, .{ .path = p, .version = v, .reason = r });
}

fn fileExists(a: std.mem.Allocator, path: []const u8) bool {
    const t = lastWrite(a, path) catch return false;
    return t != null;
}

fn detectCandidatesWithVerifier(allocator: std.mem.Allocator, capture: headless_adapter.CaptureFn, meta: AgentMeta, paths: []const []const u8, forced: bool, verify_fn: ?VerifyFn) !?DetectedAgent {
    return detectCandidatesCollect(allocator, capture, meta, paths, forced, verify_fn, null);
}

/// Tanda 4 (doctor): lo que se descartó de una CLI que no quedó elegida.
pub const MissingReport = struct {
    /// true = esta vez sí hay una instalación utilizable (la lista de la
    /// cabina estaba desfasada).
    detected: bool = false,
    rejected: []Rejected = &.{},
    pub fn deinit(self: *MissingReport, a: std.mem.Allocator) void {
        for (self.rejected) |*r| r.deinit(a);
        if (self.rejected.len > 0) a.free(self.rejected);
    }
};

/// Tanda 4 (doctor): repite la detección de UNA CLI (mismas rutas y misma
/// verificación que `detectAllWithPaths`) para explicar por qué no aparece:
/// una CLI con todas sus instalaciones descartadas no está en el catálogo.
pub fn explainMissing(a: std.mem.Allocator, cli_id: []const u8) !MissingReport {
    const meta = metaForCliId(cli_id) orelse return .{};
    var paths = std.ArrayList([]const u8).empty;
    defer {
        for (paths.items) |path| a.free(path);
        paths.deinit(a);
    }
    try gatherCandidatePaths(a, meta, &paths);
    var rejected: []Rejected = &.{};
    errdefer {
        for (rejected) |*r| r.deinit(a);
        if (rejected.len > 0) a.free(rejected);
    }
    if (try detectCandidatesCollect(a, discoveryCapture, meta, paths.items, false, cli_policy.verify, &rejected)) |detected| {
        var d = detected;
        d.deinit(a);
        return .{ .detected = true };
    }
    return .{ .rejected = rejected };
}

fn detectCandidatesCollect(allocator: std.mem.Allocator, capture: headless_adapter.CaptureFn, meta: AgentMeta, paths: []const []const u8, forced: bool, verify_fn: ?VerifyFn, missing_out: ?*[]Rejected) !?DetectedAgent {
    var chosen: ?DetectedAgent = null;
    var chosen_binary: ?cli_policy.VerifiedBinary = null;
    defer if (chosen_binary) |*v| v.deinit();
    errdefer if (chosen) |*d| d.deinit(allocator);
    var rejected = std.ArrayList(Rejected).empty;
    defer {
        for (rejected.items) |*r| r.deinit(allocator);
        rejected.deinit(allocator);
    }
    var seen = std.ArrayList([]const u8).empty;
    defer seen.deinit(allocator);
    candidates: for (paths) |path| {
        if (capture == defaultCapture or capture == discoveryCapture) {
            test_cli_guard.check(allocator, path) catch |e| {
                if (forced) return e;
                continue;
            };
        }
        for (seen.items) |prev| if (std.ascii.eqlIgnoreCase(prev, path)) continue :candidates;
        try seen.append(allocator, path);
        if (!validBinaryPath(path)) {
            if (forced) return error.InvalidExternalAgentPath;
            continue;
        }
        var verified: ?cli_policy.VerifiedBinary = null;
        defer if (verified) |*v| v.deinit();
        if (verify_fn) |verify_binary| {
            verified = verify_binary(allocator, path) catch |e| {
                if (e == error.OutOfMemory or forced) return e;
                // Una ruta conocida que no existe no es una instalación: no se anota.
                if (fileExists(allocator, path)) {
                    var reason: []u8 = try allocator.dupe(u8, cli_policy.rejectionReason(e));
                    defer allocator.free(reason);
                    if (e == error.CliWritableByOthers) {
                        if (try cli_policy.aclBlocker(allocator, path)) |blocker| {
                            defer allocator.free(blocker);
                            const who = try cli_policy.describeBlocker(allocator, blocker);
                            defer allocator.free(who);
                            const longer = try std.fmt.allocPrint(allocator, "{s} ({s})", .{ reason, who });
                            allocator.free(reason);
                            reason = longer;
                        }
                    }
                    try noteRejected(allocator, &rejected, path, null, reason);
                    std.log.warn("CLI {s} descartada: {s}: {s}", .{ meta.cli_id, path, reason });
                }
                continue;
            };
        }
        const pinned = if (verified) |v| v.path else path;
        var cap = captureForPath(allocator, capture, pinned, &.{"--version"}) catch |err| {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            // El lanzador (p. ej. el node de un shim de npm) puede caer en la
            // misma política que el binario: se dice en palabras, no por su
            // nombre de error.
            const reason = switch (err) {
                error.UntrustedCliRoot, error.CliReparseOrAlias, error.CliWritableByOthers, error.CodexSandboxUnavailable, error.CliUntrustedOwner, error.CliPermissionsUnavailable => try std.fmt.allocPrint(allocator, "no se pudo lanzar --version: {s} (el ejecutable o el intérprete que usa)", .{cli_policy.rejectionReason(err)}),
                else => try std.fmt.allocPrint(allocator, "no respondió a --version ({s})", .{@errorName(err)}),
            };
            defer allocator.free(reason);
            try noteRejected(allocator, &rejected, pinned, null, reason);
            continue;
        };
        defer cap.deinit(allocator);
        if (cap.exit_code != 0) {
            const reason = try std.fmt.allocPrint(allocator, "--version terminó con código {d}", .{cap.exit_code});
            defer allocator.free(reason);
            try noteRejected(allocator, &rejected, pinned, null, reason);
            continue;
        }
        const version = (try parseVersionText(allocator, cap.stdout)) orelse {
            try noteRejected(allocator, &rejected, pinned, null, "--version no devolvió una versión legible");
            continue;
        };
        if (chosen != null and !catalog.versionNewer(version, chosen.?.version.?)) {
            defer allocator.free(version);
            try noteRejected(allocator, &rejected, pinned, version, "versión igual o más antigua que la elegida");
            continue;
        }
        if (chosen) |*d| {
            try noteRejected(allocator, &rejected, d.exe, d.version, "versión más antigua que la elegida");
            d.deinit(allocator);
        }
        chosen = null;
        chosen = try ownDetected(allocator, meta, pinned, version, forced);
        if (verified) |v| {
            chosen.?.authenticode_code = v.authenticode_code;
            chosen.?.acl_appcontainer_sids = if (v.acl_appcontainer_sids) |s| try allocator.dupe(u8, s) else null;
            chosen.?.acl_orphan_sids = if (v.acl_orphan_sids) |s| try allocator.dupe(u8, s) else null;
        }
        // Transfer the retained binary and ancestors to the selected candidate.
        // Keep them through model/help/session probes, including injected captures.
        if (chosen_binary) |*v| v.deinit();
        chosen_binary = verified;
        verified = null;
    }
    if (chosen) |*d| {
        // La elegida no figura entre las descartadas (pudo anotarse antes como
        // «más antigua» si apareció dos veces con otra grafía).
        var i: usize = 0;
        while (i < rejected.items.len) {
            if (std.ascii.eqlIgnoreCase(rejected.items[i].path, d.exe)) {
                var r = rejected.orderedRemove(i);
                r.deinit(allocator);
            } else i += 1;
        }
        d.rejected = try rejected.toOwnedSlice(allocator);
        d.exe_stamp = try exeStamp(allocator, d.exe);
        try enrichDetected(allocator, capture, d);
    } else if (rejected.items.len > 0) {
        std.log.warn("{s}: ninguna instalación utilizable ({d} descartada(s))", .{ meta.cli_id, rejected.items.len });
        if (missing_out) |out| out.* = try rejected.toOwnedSlice(allocator);
    }
    return chosen;
}

fn ownDetected(a: std.mem.Allocator, meta: AgentMeta, path: []const u8, version: []u8, forced: bool) !DetectedAgent {
    errdefer a.free(version);
    const provider = try std.fmt.allocPrint(a, "{s}{s}", .{ PROVIDER_PREFIX, meta.cli_id });
    errdefer a.free(provider);
    const cli = try a.dupe(u8, meta.cli_id);
    errdefer a.free(cli);
    const display = try a.dupe(u8, meta.display);
    errdefer a.free(display);
    const exe = try a.dupe(u8, path);
    return .{ .provider = provider, .cli = cli, .display = display, .exe = exe, .version = version, .acp = meta.acp_argv != null, .manufacturer = meta.manufacturer, .detected_at_ms = nowMillis(), .selection_reason = if (forced) "external_agent_paths: ruta forzada por el usuario" else "mayor versión semver entre instalaciones canónicas confiables (ACL comprobada)" };
}

fn enrichDetected(a: std.mem.Allocator, capture: headless_adapter.CaptureFn, d: *DetectedAgent) !void {
    return enrichDetectedWithPresence(a, capture, d, if (capture == discoveryCapture) cli_policy.envPresent else noEnvPresent);
}

fn enrichDetectedWithPresence(a: std.mem.Allocator, capture: headless_adapter.CaptureFn, d: *DetectedAgent, present: cli_policy.PresentFn) !void {
    var child: ?std.process.Environ.Map = null;
    defer if (child) |*env| env.deinit();
    if (std.mem.eql(u8, d.cli, "codex") and capture == discoveryCapture) {
        const block = try cli_policy.codexProbeEnvironment(a, cli_policy.getEnv);
        defer a.free(block);
        var probe = std.process.Environ.Map.init(a);
        defer probe.deinit();
        try probe.putWindowsBlock(.{ .ptr = block.ptr });
        child = try cli_policy.codexEnvironment(a, &probe);
        const home_id = try cli_policy.codexHomeId(&child.?);
        d.codex_home_id = try a.dupe(u8, &home_id);
    }
    const env = if (child) |*map| map else null;
    var model_args: ?[]const []const u8 = null;
    var session_args: ?[]const []const u8 = null;
    if (std.mem.eql(u8, d.cli, "codex")) {
        model_args = &.{ "-c", cli_policy.CODEX_LOGIN_CONFIG, "debug", "models" };
        session_args = &.{ "-c", cli_policy.CODEX_LOGIN_CONFIG, "login", "status" };
    }
    if (std.mem.eql(u8, d.cli, "claude-code")) session_args = &.{ "auth", "status" };
    if (std.mem.eql(u8, d.cli, "opencode")) {
        model_args = &.{ "models", "--verbose" };
        session_args = &.{ "auth", "list" };
    }
    var models = try catalog.defaultModels(a, d.cli, .no_enumerable);
    errdefer models.deinit(a);
    if (model_args) |args| {
        const captured: ?providers.github.CmdCapture = captureForPathEnvironment(a, capture, d.exe, args, env) catch |err| blk: {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            models.status = if (err == error.Timeout) .timeout else .unavailable;
            d.enumeration_reason = try std.fmt.allocPrint(a, "{s} no respondió al listar sus modelos ({s})", .{ d.display, if (err == error.Timeout) "más de 8 s" else @errorName(err) });
            break :blk null;
        };
        if (captured) |raw| {
            var cap = raw;
            defer cap.deinit(a);
            if (cap.exit_code == 0) {
                models.deinit(a);
                models = .{ .models = &.{}, .status = .unavailable };
                models = try catalog.parseModels(a, d.cli, cap.stdout);
            } else {
                models.status = .unavailable;
                // A4: el motivo real, con lo que dijo la propia CLI (p. ej.
                // OpenCode 1.19.4 en el equipo del propietario: «no such column:
                // project_id», un fallo de su propia base de datos).
                d.enumeration_reason = try enumerationFailure(a, d.display, cap.exit_code, cap.stderr, cap.stdout);
            }
        }
    }
    // 10-nov (A1): las sondas corren con el entorno mínimo (probeEnvironment)
    // y la ejecución con cliEnvironment: ninguna CLI recibe las variables de
    // facturación del anfitrión. Su presencia ya no bloquea: se informa, y la
    // sesión se clasifica por lo que responde la CLI con ese entorno limpio.
    const billing_env = if (env) |map| cli_policy.codexBilling(map) else false;
    d.ignored_env = try cli_policy.ignoredBillingVars(a, d.cli, present);
    if (std.mem.eql(u8, d.cli, "claude-code")) {
        const captured: ?providers.github.CmdCapture = captureForPath(a, capture, d.exe, &.{"--help"}) catch |err| blk: {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            break :blk null;
        };
        if (captured) |raw| {
            var cap = raw;
            defer cap.deinit(a);
            if (cap.exit_code == 0) {
                _ = try catalog.applyClaudeEfforts(a, models.models, cap.stdout);
                // A4: los alias que declara la ayuda de la versión instalada.
                try catalog.applyClaudeModelAliases(a, &models, cap.stdout);
            }
        }
    }
    d.session = if (billing_env) .api_key else .desconocida;
    if (session_args) |args| {
        const captured: ?providers.github.CmdCapture = captureForPathEnvironment(a, capture, d.exe, args, env) catch |err| blk: {
            if (err == error.OutOfMemory) return error.OutOfMemory;
            break :blk null;
        };
        if (captured) |raw| {
            var cap = raw;
            defer cap.deinit(a);
            d.session = try catalog.parseSession(a, d.cli, cap.stdout, cap.stderr, billing_env);
            if (cap.exit_code != 0 and d.session == .suscripcion) d.session = .desconocida;
        }
    }
    // T2d-D6: Gemini CLI no tiene `auth status`; su sesión sale de su
    // configuración local (settings.json, entorno, .env), sin red. Solo con la
    // captura real: las pruebas con capturas falsas no leen el perfil del propietario.
    if (std.mem.eql(u8, d.cli, "gemini-cli") and capture == discoveryCapture) {
        var threaded = std.Io.Threaded.init(a, .{});
        defer threaded.deinit();
        try applyGeminiProbe(a, d, try cli_policy.geminiSessionProbe(a, threaded.io(), cli_policy.getEnv));
    }
    if (env) |map| {
        var threaded = std.Io.Threaded.init(a, .{});
        defer threaded.deinit();
        const mode = cli_policy.codexAuthMode(a, threaded.io(), map) catch |e| blk: {
            if (e == error.OutOfMemory) return e;
            try setCodexProfileFailure(a, d, e);
            std.log.warn("{s}", .{d.session_reason.?});
            // Un proveedor propio en config.toml puede facturar por API: bloqueo.
            break :blk if (e == error.CodexProviderOverride) Session.api_key else Session.desconocida;
        };
        d.session = codexEffectiveSession(mode, d.session, billing_env);
        logCodexSession(d.session);
        // A4: el modelo de config.toml (si `debug models` no lo lista) y la
        // opción de no pasar --model.
        const configured = cli_policy.codexConfiguredModel(a, threaded.io(), map) catch |e| blk: {
            if (e == error.OutOfMemory) return e;
            std.log.warn("Codex config.toml: modelo configurado no legible: {s}", .{@errorName(e)});
            break :blk cli_policy.OwnedConfiguredModel{ .model = null, .effort = null };
        };
        defer if (configured.model) |m| a.free(m);
        defer if (configured.effort) |e| a.free(e);
        try catalog.addCodexChoices(a, &models, configured.model, configured.effort);
    }
    d.models = models.models;
    d.enumeration_status = models.status;
}

/// A4: frase con lo que la CLI respondió al listar sus modelos. Se queda con
/// las últimas líneas no vacías (el mensaje útil va al final), acotado y
/// censurado: es texto externo.
fn enumerationFailure(a: std.mem.Allocator, display: []const u8, code: u32, stderr: []const u8, stdout: []const u8) ![]u8 {
    const source = if (std.mem.trim(u8, stderr, " \t\r\n").len > 0) stderr else stdout;
    var lines = std.mem.splitScalar(u8, source, '\n');
    var said = std.ArrayList(u8).empty;
    defer said.deinit(a);
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (said.items.len > 0) try said.appendSlice(a, " — ");
        try said.appendSlice(a, line);
    }
    const tail = said.items[said.items.len -| 300..];
    const clean = try @import("debug_dump.zig").redactBytes(a, tail);
    defer a.free(clean);
    if (clean.len == 0) return std.fmt.allocPrint(a, "{s} no pudo listar sus modelos (código {d}, sin mensaje)", .{ display, code });
    return std.fmt.allocPrint(a, "{s} no pudo listar sus modelos (código {d}): «{s}»", .{ display, code, clean });
}

test "USUARIO-NUEVO A4: el fallo real de OpenCode al listar modelos llega a la interfaz" {
    const a = testing.allocator;
    // Salida real de `opencode models --verbose` (1.19.4) en el equipo del propietario.
    const reason = try enumerationFailure(a, "OpenCode", 1, "Error: Unexpected error\r\n\r\nno such column: project_id\r\n", "");
    defer a.free(reason);
    try testing.expectEqualStrings("OpenCode no pudo listar sus modelos (código 1): «Error: Unexpected error — no such column: project_id»", reason);
    const empty = try enumerationFailure(a, "OpenCode", 2, "", "  \n");
    defer a.free(empty);
    try testing.expectEqualStrings("OpenCode no pudo listar sus modelos (código 2, sin mensaje)", empty);
}

fn applyGeminiProbe(a: std.mem.Allocator, d: *DetectedAgent, probe: catalog.GeminiSession) !void {
    const reason = try a.dupe(u8, probe.reason);
    if (d.session_reason) |previous| a.free(previous);
    d.session_reason = reason;
    d.session = probe.session;
    // QA-A H14: detalle interno; en ReleaseSafe (nivel info) ya no sale en la consola de order/doctor/MCP.
    std.log.debug("Gemini CLI sesión={s}: {s}", .{ @tagName(probe.session), probe.reason });
}

test "T2d-D6: la sesión de Gemini llega con su motivo a la etiqueta y al JSON de la cabina" {
    const a = testing.allocator;
    var detected = try ownDetected(a, metaForCliId("gemini-cli").?, "C:\\npm\\gemini.cmd", try a.dupe(u8, "0.53.1"), false);
    defer detected.deinit(a);
    const cases = [_]struct { probe: catalog.GeminiSession, label: []const u8 }{
        .{ .probe = catalog.geminiSession(.oauth_personal, false), .label = "Gemini CLI (sin sesión — cuenta personal de Google: desde el 18-jun-2026" },
        .{ .probe = catalog.geminiSession(.api_key, false), .label = "Gemini CLI (método «gemini-api-key»: clave de API, factura por uso)" },
        .{ .probe = catalog.geminiSession(.oauth_personal, true), .label = "Gemini CLI (tu suscripción)" },
        .{ .probe = catalog.geminiSession(.none, false), .label = "Gemini CLI (sin sesión — Gemini CLI no tiene método de inicio de sesión" },
    };
    for (cases) |case| {
        try applyGeminiProbe(a, &detected, case.probe);
        const json = try detectedJson(a, &.{detected});
        defer a.free(json);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
        defer parsed.deinit();
        const fields = parsed.value.array.items[0].object;
        try testing.expectEqualStrings(@tagName(case.probe.session), fields.get("session").?.string);
        try testing.expectEqualStrings(case.probe.reason, fields.get("session_reason").?.string);
        try testing.expect(std.mem.startsWith(u8, fields.get("label").?.string, case.label));
    }
}

fn setCodexProfileFailure(a: std.mem.Allocator, d: *DetectedAgent, e: anyerror) !void {
    const reason = try cli_policy.codexProfileFailure(a, e);
    if (d.session_reason) |previous| a.free(previous);
    d.session_reason = reason;
}

test "RELOJ Codex profile failure reaches catalog label and UI reason" {
    const a = testing.allocator;
    var detected = try ownDetected(a, metaForCliId("codex").?, "C:\\codex.exe", try a.dupe(u8, "0.160.0"), false);
    defer detected.deinit(a);
    // Textos literales: el valor esperado NO se calcula con la función probada.
    const cases = [_]struct { err: anyerror, text: []const u8 }{
        .{ .err = error.CliWritableByOthers, .text = "perfil de Codex con permisos no verificables: escritor ajeno al sandbox oficial de Codex" },
        .{ .err = error.CliUntrustedOwner, .text = "perfil de Codex con permisos no verificables: propietario no confiable" },
        .{ .err = error.CodexSandboxUnavailable, .text = "identidad del sandbox oficial de Codex no verificable: no se pudo resolver el grupo local CodexSandboxUsers o verificar sus miembros" },
        .{ .err = error.CliPermissionsUnavailable, .text = "perfil de Codex con permisos no verificables: no se pudo inspeccionar el descriptor de seguridad" },
        .{ .err = error.AccessDenied, .text = "no se pudo leer el perfil de Codex: AccessDenied" },
        .{ .err = error.InvalidCodexAuth, .text = "auth.json de Codex inválido (JSON o metadatos): InvalidCodexAuth" },
        .{ .err = error.InvalidEnvironment, .text = "entorno de Codex inválido (CODEX_HOME o USERPROFILE): InvalidEnvironment" },
        .{ .err = error.CodexAuthReadIncomplete, .text = "no se pudo leer el perfil de Codex: CodexAuthReadIncomplete" },
        .{ .err = error.CodexProviderOverride, .text = "config.toml de Codex define un proveedor propio (model_provider, env_key o base_url distintos de ChatGPT): la sesión queda bloqueada porque podría facturar por API" },
        .{ .err = error.InvalidCodexConfig, .text = "config.toml de Codex inválido: tipo o tamaño no válidos" },
    };
    for (cases) |case| {
        try setCodexProfileFailure(a, &detected, case.err);
        // Un proveedor propio bloquea como facturación por API; el resto, como sesión desconocida.
        detected.session = if (case.err == error.CodexProviderOverride) .api_key else .desconocida;
        const json = try detectedJson(a, &.{detected});
        defer a.free(json);
        var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
        defer parsed.deinit();
        const fields = parsed.value.array.items[0].object;
        try testing.expectEqualStrings(case.text, detected.session_reason.?);
        try testing.expectEqualStrings(case.text, fields.get("session_reason").?.string);
        try testing.expect(std.mem.indexOf(u8, fields.get("label").?.string, case.text) != null);
    }
    var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try testing.expectError(error.OutOfMemory, cli_policy.codexProfileFailure(failing.allocator(), error.CliPermissionsUnavailable));
}

fn logCodexSession(session: Session) void {
    const mode = switch (session) {
        .suscripcion => "chatgpt",
        .api_key => "apikey",
        .sin_sesion => "none",
        .desconocida => "unknown",
    };
    // QA-A H14: detalle interno, nivel debug (no sale en la consola del usuario).
    std.log.debug("Codex auth origin=auth.json+login-status mode={s} removed=OPENAI_API_KEY,CODEX_API_KEY", .{mode});
}

pub fn codexEffectiveSession(mode: Session, login: Session, billing: bool) Session {
    if (billing or mode == .api_key or login == .api_key) return .api_key;
    if (mode == .suscripcion and login == .suscripcion) return .suscripcion;
    return if (mode == .sin_sesion or login == .sin_sesion) .sin_sesion else .desconocida;
}

test "RELOJ Codex authentication mismatch unknown and real child billing remain blocked" {
    try testing.expectEqual(Session.suscripcion, codexEffectiveSession(.suscripcion, .suscripcion, false));
    try testing.expectEqual(Session.api_key, codexEffectiveSession(.api_key, .suscripcion, false));
    try testing.expectEqual(Session.api_key, codexEffectiveSession(.suscripcion, .api_key, false));
    try testing.expectEqual(Session.api_key, codexEffectiveSession(.suscripcion, .suscripcion, true));
    try testing.expectEqual(Session.desconocida, codexEffectiveSession(.desconocida, .suscripcion, false));
    try testing.expectEqual(Session.desconocida, codexEffectiveSession(.suscripcion, .desconocida, false));
    try testing.expectEqual(Session.sin_sesion, codexEffectiveSession(.sin_sesion, .suscripcion, false));
}

/// La clasificación persistida nunca autoriza un envío por sí sola.
pub fn revalidateCodex(a: std.mem.Allocator, io: std.Io, exe: []const u8, env: *const std.process.Environ.Map) !Session {
    const mode = cli_policy.codexAuthMode(a, io, env) catch |e| {
        if (e == error.OutOfMemory) return e;
        const reason = try cli_policy.codexProfileFailure(a, e);
        defer a.free(reason);
        std.log.warn("{s}", .{reason});
        if (e == error.CodexProviderOverride) return .api_key;
        return e;
    };
    if (mode != .suscripcion or cli_policy.codexBilling(env)) return codexEffectiveSession(mode, .desconocida, cli_policy.codexBilling(env));
    const prefix = try spawnPrefixForPath(a, exe);
    defer freeSpawnPrefix(a, prefix);
    const argv = try a.alloc([]const u8, prefix.len + 4);
    defer a.free(argv);
    @memcpy(argv[0..prefix.len], prefix);
    @memcpy(argv[prefix.len..], &[_][]const u8{ "-c", cli_policy.CODEX_LOGIN_CONFIG, "login", "status" });
    const block = try env.createWindowsBlock(a, .{});
    defer block.deinit(a);
    const home = env.get("CODEX_HOME") orelse return error.InvalidEnvironment;
    var result = try executor.runVerifierPinned(a, .{ .workspace_root = home, .timeout_ms = 8000, .max_output_bytes = 64 * 1024, .environment = block.slice }, argv[0], argv[1..], home);
    defer result.deinit(a);
    if (result.timed_out) return error.Timeout;
    if (result.stdoutTruncated() or result.stderrTruncated()) return error.OutputLimitExceeded;
    const login = if (result.exit_code == 0) try catalog.parseSession(a, "codex", result.stdout, result.stderr, cli_policy.codexBilling(env)) else Session.desconocida;
    const session = codexEffectiveSession(mode, login, cli_policy.codexBilling(env));
    logCodexSession(session);
    return session;
}

fn noEnvPresent(_: [:0]const u8) bool {
    return false;
}

const CliFindData = extern struct {
    attributes: u32,
    creation_low: u32,
    creation_high: u32,
    access_low: u32,
    access_high: u32,
    write_low: u32,
    write_high: u32,
    size_high: u32,
    size_low: u32,
    reserved0: u32,
    reserved1: u32,
    name: [260]u16,
    alternate: [14]u16,
};
const FindFirstFileW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindFirstFileW(pattern: [*:0]const u16, data: *CliFindData) callconv(.winapi) std.os.windows.HANDLE;
}.FindFirstFileW else @import("providers").posix_files.FindFirstFileW;
const FindNextFileW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindNextFileW(handle: std.os.windows.HANDLE, data: *CliFindData) callconv(.winapi) c_int;
}.FindNextFileW else @import("providers").posix_files.FindNextFileW;
const FindClose = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindClose(handle: std.os.windows.HANDLE) callconv(.winapi) c_int;
}.FindClose else @import("providers").posix_files.FindClose;
const GetFileAttributesW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileAttributesW(path: [*:0]const u16) callconv(.winapi) u32;
}.GetFileAttributesW else @import("providers").posix_files.GetFileAttributesW;

fn appendKnownCodex(a: std.mem.Allocator, paths: *std.ArrayList([]const u8)) !void {
    if (@import("builtin").os.tag != .windows) return;
    var local: [32768]u8 = undefined;
    const n = GetEnvironmentVariableA("LOCALAPPDATA", &local, local.len);
    if (n == 0 or n >= local.len) return;
    const base = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "OpenAI" ++ std.fs.path.sep_str ++ "Codex" ++ std.fs.path.sep_str ++ "bin", .{local[0..n]});
    defer a.free(base);
    const direct = try std.fs.path.join(a, &.{ base, "codex" ++ comptime @import("builtin").target.exeFileExt() });
    paths.append(a, direct) catch |err| {
        a.free(direct);
        return err;
    };
    const pattern = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "*", .{base});
    defer a.free(pattern);
    const pw = try std.unicode.utf8ToUtf16LeAllocZ(a, pattern);
    defer a.free(pw);
    var fd: CliFindData = undefined;
    const h = FindFirstFileW(pw, &fd);
    if (h == std.os.windows.INVALID_HANDLE_VALUE) return;
    defer _ = FindClose(h);
    var count: usize = 0;
    while (true) {
        if ((fd.attributes & 0x10) != 0 and (fd.attributes & 0x400) == 0) {
            const len = std.mem.indexOfScalar(u16, &fd.name, 0) orelse fd.name.len;
            const name = try std.unicode.utf16LeToUtf8Alloc(a, fd.name[0..len]);
            defer a.free(name);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                count += 1;
                if (count > 64) return error.TooManyCliCandidates;
                const path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "{s}" ++ std.fs.path.sep_str ++ "codex.exe", .{ base, name });
                const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
                defer a.free(wide);
                const attrs = GetFileAttributesW(wide);
                if (attrs != 0xffffffff and attrs & (0x10 | 0x400) == 0) {
                    paths.append(a, path) catch |err| {
                        a.free(path);
                        return err;
                    };
                } else a.free(path);
            }
        }
        if (FindNextFileW(h, &fd) == 0) break;
    }
}

fn appendKnownRuntimePaths(a: std.mem.Allocator, meta: AgentMeta, paths: *std.ArrayList([]const u8)) !void {
    // Exact npm global shim and Claude native install roots; no disk scan.
    var env: [32768]u8 = undefined;
    const n = GetEnvironmentVariableA("APPDATA", &env, env.len);
    if (n > 0 and n < env.len) {
        const npm_path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "npm" ++ std.fs.path.sep_str ++ "{s}.cmd", .{ env[0..n], meta.exe });
        paths.append(a, npm_path) catch |err| {
            a.free(npm_path);
            return err;
        };
    }
    const program = if (std.mem.eql(u8, meta.cli_id, "codex")) "Codex" else if (std.mem.eql(u8, meta.cli_id, "claude-code")) "Claude" else if (std.mem.eql(u8, meta.cli_id, "opencode")) "OpenCode" else "Gemini";
    {
        const u = GetEnvironmentVariableA("LOCALAPPDATA", &env, env.len);
        if (u > 0 and u < env.len) {
            for ([_][]const u8{ "", "\\bin" }) |suffix| {
                const native = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "Programs" ++ std.fs.path.sep_str ++ "{s}{s}" ++ std.fs.path.sep_str ++ "{s}.exe", .{ env[0..u], program, suffix, meta.exe });
                paths.append(a, native) catch |err| {
                    a.free(native);
                    return err;
                };
            }
        }
    }
    // 10-nov (USUARIO-NUEVO A2): instalador nativo oficial (`claude install`,
    // y el mismo patrón en otras CLI): %USERPROFILE%\.local\bin\<exe>.exe. La
    // raíz ya es de confianza (external_cli_policy `locations`); sin esta ruta
    // conocida dependía de que estuviera en el PATH del proceso de DevAgents.
    {
        const u = GetEnvironmentVariableA("USERPROFILE", &env, env.len);
        if (u > 0 and u < env.len) {
            const local_bin = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".local" ++ std.fs.path.sep_str ++ "bin" ++ std.fs.path.sep_str ++ "{s}.exe", .{ env[0..u], meta.exe });
            paths.append(a, local_bin) catch |err| {
                a.free(local_bin);
                return err;
            };
        }
    }
}

/// B1 (10-nov): añade `<dir>\<exe>.{exe,cmd,bat}` si existe como archivo. Solo
/// carpetas absolutas con unidad: nunca el directorio actual ni una relativa.
fn appendDirCandidates(a: std.mem.Allocator, paths: *std.ArrayList([]const u8), dir_raw: []const u8, exe: []const u8) !void {
    if (@import("builtin").os.tag != .windows) return;
    const dir = std.mem.trimEnd(u8, std.mem.trim(u8, dir_raw, " \t\""), "\\/");
    if (dir.len < 2 or !std.ascii.isAlphabetic(dir[0]) or dir[1] != ':') return;
    if (dir.len > 2 and dir[2] != '\\' and dir[2] != '/') return;
    for ([_][]const u8{ ".exe", ".cmd", ".bat" }) |ext| {
        const path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "{s}{s}", .{ dir, exe, ext });
        errdefer a.free(path);
        const wide = std.unicode.utf8ToUtf16LeAllocZ(a, path) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            // Una entrada del PATH que no es UTF-8 válido no puede nombrar una instalación.
            error.InvalidUtf8 => {
                a.free(path);
                return;
            },
        };
        defer a.free(wide);
        const attrs = GetFileAttributesW(wide);
        if (attrs == 0xffffffff or attrs & 0x10 != 0) {
            a.free(path);
            continue;
        }
        try paths.append(a, path);
    }
}

/// Una lista tipo PATH (`a;b;c`): cada carpeta absoluta se mira con
/// `appendDirCandidates`. Tope de entradas: un PATH no es un escaneo de disco.
fn appendPathListCandidates(a: std.mem.Allocator, paths: *std.ArrayList([]const u8), list: []const u8, exe: []const u8) !void {
    var count: usize = 0;
    var dirs = std.mem.tokenizeScalar(u8, list, ';');
    while (dirs.next()) |dir| {
        count += 1;
        if (count > 256) return;
        try appendDirCandidates(a, paths, dir, exe);
    }
}

extern "advapi32" fn RegGetValueW(hkey: usize, sub_key: [*:0]const u16, value: [*:0]const u16, flags: u32, kind: ?*u32, data: ?*anyopaque, size: ?*u32) callconv(.winapi) i32;

/// B1: el PATH PERSISTIDO del usuario y del equipo (registro). El proceso de
/// DevAgents puede haber arrancado antes de que un instalador lo cambiara, o
/// desde un lanzador con otro entorno: la CLI está en el PATH del usuario y no
/// en el del proceso. REG_EXPAND_SZ se expande (RegGetValueW lo hace salvo
/// RRF_NOEXPAND). Un valor ausente no es un error: no hay nada que mirar.
fn appendRegistryPathCandidates(a: std.mem.Allocator, paths: *std.ArrayList([]const u8), exe: []const u8) !void {
    if (@import("builtin").os.tag != .windows) return;
    const HKCU: usize = 0x80000001;
    const HKLM: usize = 0x80000002;
    const sources = [_]struct { root: usize, key: [:0]const u16 }{
        .{ .root = HKCU, .key = std.unicode.utf8ToUtf16LeStringLiteral("Environment") },
        .{ .root = HKLM, .key = std.unicode.utf8ToUtf16LeStringLiteral("SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment") },
    };
    const value = std.unicode.utf8ToUtf16LeStringLiteral("Path");
    for (sources) |source| {
        // 0x2 | 0x4 = RRF_RT_REG_SZ | RRF_RT_REG_EXPAND_SZ.
        var bytes: u32 = 0;
        if (RegGetValueW(source.root, source.key, value, 0x6, null, null, &bytes) != 0 or bytes < 2 or bytes > 2 * 65536) continue;
        // Margen: la expansión puede crecer entre las dos llamadas.
        const buffer = try a.alloc(u16, bytes / 2 + 4096);
        defer a.free(buffer);
        var size: u32 = @intCast(buffer.len * 2);
        if (RegGetValueW(source.root, source.key, value, 0x6, null, buffer.ptr, &size) != 0) continue;
        const wide = std.mem.sliceTo(buffer[0..@min(buffer.len, size / 2)], 0);
        const list = std.unicode.utf16LeToUtf8Alloc(a, wide) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            else => continue,
        };
        defer a.free(list);
        try appendPathListCandidates(a, paths, list, exe);
    }
}

/// `<base>\<una carpeta>\<suffix>` para cada subcarpeta real de `base` (no
/// reanálisis): versiones de nvm (`v22.1.0`) y de fnm
/// (`v22.1.0\installation`). Con tope, sin recursión.
fn appendVersionedDirCandidates(a: std.mem.Allocator, paths: *std.ArrayList([]const u8), base: []const u8, suffix: []const u8, exe: []const u8) !void {
    if (@import("builtin").os.tag != .windows) return;
    const pattern = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "*", .{base});
    defer a.free(pattern);
    const pw = std.unicode.utf8ToUtf16LeAllocZ(a, pattern) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8 => return,
    };
    defer a.free(pw);
    var fd: CliFindData = undefined;
    const h = FindFirstFileW(pw, &fd);
    if (h == std.os.windows.INVALID_HANDLE_VALUE) return;
    defer _ = FindClose(h);
    var count: usize = 0;
    while (true) {
        if ((fd.attributes & 0x10) != 0 and (fd.attributes & 0x400) == 0) {
            const len = std.mem.indexOfScalar(u16, &fd.name, 0) orelse fd.name.len;
            const name = try std.unicode.utf16LeToUtf8Alloc(a, fd.name[0..len]);
            defer a.free(name);
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                count += 1;
                if (count > 64) return;
                const dir = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "{s}{s}", .{ base, name, suffix });
                defer a.free(dir);
                try appendDirCandidates(a, paths, dir, exe);
            }
        }
        if (FindNextFileW(h, &fd) == 0) break;
    }
}

/// B1 (visto en Orca, `stablyai/orca`): carpetas donde bun, pnpm, Volta, nvm
/// y fnm dejan los ejecutables globales. Solo añaden CANDIDATOS: cada uno pasa
/// por la misma verificación que el resto (`cli_policy.verify`: raíz de
/// confianza, propietario, ACL, reanálisis) y, si no la pasa, sale en Configuración
/// con su motivo.
fn appendManagerCandidates(a: std.mem.Allocator, paths: *std.ArrayList([]const u8), exe: []const u8) !void {
    const fixed = [_]struct { env: [:0]const u8, tail: []const u8 }{
        .{ .env = "USERPROFILE", .tail = "\\.bun\\bin" },
        .{ .env = "LOCALAPPDATA", .tail = "\\pnpm" },
        .{ .env = "LOCALAPPDATA", .tail = "\\Volta\\bin" },
    };
    var env: [32768]u8 = undefined;
    for (fixed) |entry| {
        const n = GetEnvironmentVariableA(entry.env, &env, env.len);
        if (n == 0 or n >= env.len) continue;
        const dir = try std.fmt.allocPrint(a, "{s}{s}", .{ env[0..n], entry.tail });
        defer a.free(dir);
        try appendDirCandidates(a, paths, dir, exe);
    }
    const n = GetEnvironmentVariableA("APPDATA", &env, env.len);
    if (n == 0 or n >= env.len) return;
    const nvm = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "nvm", .{env[0..n]});
    defer a.free(nvm);
    try appendVersionedDirCandidates(a, paths, nvm, "", exe);
    const fnm = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "fnm" ++ std.fs.path.sep_str ++ "node-versions", .{env[0..n]});
    defer a.free(fnm);
    try appendVersionedDirCandidates(a, paths, fnm, "\\installation", exe);
}

test "B1 detección: una lista PATH solo aporta carpetas absolutas, nunca la actual ni relativas" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "bin/claude.bat");
    try tmp.dir.createDirPath(io, "v22.1.0/installation");
    for ([_][]const u8{ "bin/claude.exe", "bin/claude.cmd", "v22.1.0/installation/claude.cmd" }) |name| {
        var file = try tmp.dir.createFile(io, name, .{});
        file.close(io);
    }
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var paths = std.ArrayList([]const u8).empty;
    defer {
        for (paths.items) |p| a.free(p);
        paths.deinit(a);
    }
    const list = try std.fmt.allocPrint(a, ".;;bin;..\\bin;\\bin;\"{s}\\bin\\\";{s}\\no-existe;\\\\servidor\\recurso", .{ root, root });
    defer a.free(list);
    try appendPathListCandidates(a, &paths, list, "claude");
    // La carpeta `claude.bat` no es un ejecutable; `.`, `bin`, `..\bin`, `\bin`
    // (relativas a la carpeta o a la unidad actual) y la ruta UNC no se miran.
    try std.testing.expectEqual(@as(usize, 2), paths.items.len);
    const exe = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "bin" ++ std.fs.path.sep_str ++ "claude.exe", .{root});
    defer a.free(exe);
    const cmd = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "bin" ++ std.fs.path.sep_str ++ "claude.cmd", .{root});
    defer a.free(cmd);
    try std.testing.expectEqualStrings(exe, paths.items[0]);
    try std.testing.expectEqualStrings(cmd, paths.items[1]);
    // Versiones de fnm: una subcarpeta por versión, con su sufijo.
    try appendVersionedDirCandidates(a, &paths, root, "\\installation", "claude");
    try std.testing.expectEqual(@as(usize, 3), paths.items.len);
    const fnm = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "v22.1.0" ++ std.fs.path.sep_str ++ "installation" ++ std.fs.path.sep_str ++ "claude.cmd", .{root});
    defer a.free(fnm);
    try std.testing.expectEqualStrings(fnm, paths.items[2]);
    // El PATH persistido del registro se lee sin error en cualquier equipo.
    try appendRegistryPathCandidates(a, &paths, "devagents-cli-que-no-existe");
    try std.testing.expectEqual(@as(usize, 3), paths.items.len);
}

/// Ad hoc forced paths are additive settings JSON: {"codex":"C:\\...exe"}.
/// With an explicit capture this is also the deterministic discovery seam.
/// Rutas candidatas de una CLI sin ruta forzada: PATH, rutas conocidas del
/// fabricante, PATH persistido y gestores de paquetes (B1).
fn gatherCandidatePaths(a: std.mem.Allocator, meta: AgentMeta, paths: *std.ArrayList([]const u8)) !void {
    if (try resolveCliExe(a, meta.exe)) |path| try paths.append(a, path);
    try appendKnownRuntimePaths(a, meta, paths);
    if (std.mem.eql(u8, meta.cli_id, "codex")) try appendKnownCodex(a, paths);
    try appendRegistryPathCandidates(a, paths, meta.exe);
    try appendManagerCandidates(a, paths, meta.exe);
}

pub fn detectAllWithPaths(a: std.mem.Allocator, capture: ?headless_adapter.CaptureFn, forced_paths_json: ?[]const u8) ![]DetectedAgent {
    return detectAllWithPathsImpl(a, capture, forced_paths_json, true);
}

fn detectAllWithPathsImpl(a: std.mem.Allocator, capture: ?headless_adapter.CaptureFn, forced_paths_json: ?[]const u8, check_origin: bool) ![]DetectedAgent {
    var forced: ?std.json.Parsed(std.json.Value) = null;
    defer if (forced) |*p| p.deinit();
    if (forced_paths_json) |json| {
        forced = std.json.parseFromSlice(std.json.Value, a, json, .{}) catch return error.InvalidExternalAgentPaths;
        if (forced.?.value != .object) return error.InvalidExternalAgentPaths;
        var fields = forced.?.value.object.iterator();
        while (fields.next()) |field| {
            if (metaForCliId(field.key_ptr.*) == null or field.value_ptr.* != .string or (field.value_ptr.string.len > 0 and !validBinaryPath(field.value_ptr.string))) return error.InvalidExternalAgentPaths;
        }
    }
    var list = std.ArrayList(DetectedAgent).empty;
    errdefer {
        for (list.items) |*d| d.deinit(a);
        list.deinit(a);
    }
    for (AGENTS) |meta| {
        var paths = std.ArrayList([]const u8).empty;
        defer {
            for (paths.items) |path| a.free(path);
            paths.deinit(a);
        }
        const configured = if (forced) |p| p.value.object.get(meta.cli_id) else null;
        const override = if (configured) |v| (if (v.string.len > 0) v else null) else null;
        if (override) |v| {
            try paths.append(a, try a.dupe(u8, v.string));
        } else {
            try gatherCandidatePaths(a, meta, &paths);
        }
        if (try detectCandidatesImpl(a, capture orelse discoveryCapture, meta, paths.items, override != null, check_origin)) |detected| {
            var d = detected;
            list.append(a, d) catch |err| {
                d.deinit(a);
                return err;
            };
        }
    }
    return list.toOwnedSlice(a);
}

/// JSON del registro para C-ABI/MCP/cabina:
/// [{provider, cli, display, version, acp, manufacturer, label}]
/// `label` es la etiqueta de suscripción para la cabina («X (tu suscripción)»).
pub fn detectedJson(allocator: std.mem.Allocator, list: []const DetectedAgent) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginArray();
    for (list) |d| {
        try js.beginObject();
        try js.objectField("provider");
        try js.write(d.provider);
        try js.objectField("cli");
        try js.write(d.cli);
        try js.objectField("display");
        try js.write(d.display);
        try js.objectField("exe");
        try js.write(d.exe);
        try js.objectField("version");
        if (d.version) |v| try js.write(v) else try js.write(@as(?[]const u8, null));
        try js.objectField("acp");
        try js.write(d.acp);
        try js.objectField("manufacturer");
        try js.write(d.manufacturer.text());
        try js.objectField("models");
        try js.beginArray();
        for (d.models) |m| {
            try js.beginObject();
            try js.objectField("slug");
            try js.write(m.slug);
            try js.objectField("display_name");
            try js.write(m.display_name);
            const free = catalog.isFreeModel(d.cli, m.slug, m.zero_cost);
            try js.objectField("zero_cost");
            try js.write(m.zero_cost);
            try js.objectField("text_gen");
            try js.write(m.text_gen orelse !@import("model_capabilities.zig").nonChat(m.slug));
            try js.objectField("free");
            try js.write(free);
            if (free) {
                const label = try std.fmt.allocPrint(allocator, "{s} · {s} (gratis)", .{ d.display, m.display_name });
                defer allocator.free(label);
                try js.objectField("label");
                try js.write(label);
            }
            try js.objectField("manufacturer");
            try js.write(m.manufacturer.text());
            try js.objectField("reasoning_efforts");
            try js.write(m.reasoning_efforts);
            try js.objectField("origin");
            try js.write(@tagName(m.origin));
            try js.endObject();
        }
        try js.endArray();
        try js.objectField("session");
        try js.write(@tagName(d.session));
        try js.objectField("session_reason");
        try js.write(d.session_reason);
        try js.objectField("codex_home_id");
        try js.write(d.codex_home_id);
        try js.objectField("enumeration_status");
        try js.write(@tagName(d.enumeration_status));
        try js.objectField("detected_at_ms");
        try js.write(d.detected_at_ms);
        try js.objectField("authenticode_code");
        try js.write(d.authenticode_code);
        try js.objectField("acl_appcontainer_sids");
        try js.beginArray();
        if (d.acl_appcontainer_sids) |s| {
            var lines = std.mem.tokenizeScalar(u8, s, '\n');
            while (lines.next()) |sid| if (!cli_policy.isAppContainerWriterLine(sid)) try js.write(sid);
        }
        try js.endArray();
        // una sola aplicación empaquetada (p. ej. la app de Claude)
        // puede escribir en el binario o en su instalación: se acepta como
        // señal y se dice cuál, para que el doctor y Configuración lo cuenten.
        try js.objectField("acl_appcontainer_writers");
        try js.beginArray();
        if (d.acl_appcontainer_sids) |s| {
            var lines = std.mem.tokenizeScalar(u8, s, '\n');
            while (lines.next()) |line| {
                if (!cli_policy.isAppContainerWriterLine(line)) continue;
                const sid = line[2..];
                const app = try cli_policy.appContainerAppName(allocator, sid);
                defer if (app) |n| allocator.free(n);
                try js.beginObject();
                try js.objectField("sid");
                try js.write(sid);
                try js.objectField("app");
                try js.write(app);
                try js.endObject();
            }
        }
        try js.endArray();
        try js.objectField("acl_orphan_sids");
        try js.beginArray();
        if (d.acl_orphan_sids) |s| {
            var lines = std.mem.tokenizeScalar(u8, s, '\n');
            while (lines.next()) |sid| try js.write(sid);
        }
        try js.endArray();
        try js.objectField("acl_orphan_note");
        const orphan_note = if (d.acl_orphan_sids) |s| try cli_policy.describeOrphans(allocator, s) else null;
        defer if (orphan_note) |n| allocator.free(n);
        try js.write(orphan_note);
        try js.objectField("authenticode");
        try js.write(if (d.authenticode_code) |code| (if (code == 0) "trusted" else if (code == @as(i32, @bitCast(@as(u32, 0x800b0100)))) "unsigned" else "not_trusted") else "not_checked_synthetic");
        try js.objectField("selection_reason");
        try js.write(d.selection_reason);
        try js.objectField("ignored_env");
        try js.write(d.ignored_env);
        try js.objectField("enumeration_reason");
        try js.write(d.enumeration_reason);
        try js.objectField("exe_stamp");
        try js.write(d.exe_stamp);
        try js.objectField("rejected");
        try js.beginArray();
        for (d.rejected) |r| {
            try js.beginObject();
            try js.objectField("path");
            try js.write(r.path);
            try js.objectField("version");
            try js.write(r.version);
            try js.objectField("reason");
            try js.write(r.reason);
            try js.endObject();
        }
        try js.endArray();
        try js.objectField("label");
        const is_opencode = std.mem.eql(u8, d.cli, "opencode");
        // T2d-D6: «sin sesión» lleva el motivo cuando la sonda lo sabe.
        const no_session = if (d.session == .sin_sesion and d.session_reason != null)
            try std.fmt.allocPrint(allocator, "sin sesión — {s}", .{d.session_reason.?})
        else
            null;
        defer if (no_session) |text| allocator.free(text);
        const suffix = switch (d.session) {
            .suscripcion => "tu suscripción",
            // OpenCode con claves guardadas en su propio perfil: sus modelos
            // gratuitos siguen disponibles; los de pago, no.
            .api_key => d.session_reason orelse if (is_opencode) "solo modelos gratuitos: OpenCode tiene claves de API guardadas" else "facturación API: bloqueado",
            .sin_sesion => no_session orelse "sin sesión",
            .desconocida => d.session_reason orelse "sesión desconocida",
        };
        const label = if (d.ignored_env) |names|
            try std.fmt.allocPrint(allocator, "{s} ({s} · se ignora {s} del entorno)", .{ d.display, suffix, names })
        else
            try std.fmt.allocPrint(allocator, "{s} ({s})", .{ d.display, suffix });
        defer allocator.free(label);
        try js.write(label);
        try js.endObject();
    }
    try js.endArray();
    return try allocator.dupe(u8, out.written());
}

// ── Límites (E5.08) ────────────────────────────────────────────────────────

/// Topes de reloj y turnos por tarea y por orden. Los defaults de la fila:
/// 15 min y 40 turnos por tarea; los de orden agrupan cuatro tareas.
pub const Limits = struct {
    task_timeout_ms: u64 = 15 * 60 * 1000,
    task_max_turns: u32 = 40,
    order_timeout_ms: u64 = 60 * 60 * 1000,
    order_max_turns: u32 = 160,

    pub fn toJson(self: Limits, allocator: std.mem.Allocator) ![]u8 {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try js.beginObject();
        try js.objectField("task_timeout_ms");
        try js.write(self.task_timeout_ms);
        try js.objectField("task_max_turns");
        try js.write(self.task_max_turns);
        try js.objectField("order_timeout_ms");
        try js.write(self.order_timeout_ms);
        try js.objectField("order_max_turns");
        try js.write(self.order_max_turns);
        try js.endObject();
        return try allocator.dupe(u8, out.written());
    }

    /// Parse parcial: solo los campos presentes se aplican; el resto conserva
    /// el valor recibido en `base`. Rechaza negativos/overflow.
    pub fn fromJson(base: Limits, allocator: std.mem.Allocator, text: []const u8) !Limits {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{}) catch return error.InvalidJson;
        defer parsed.deinit();
        if (parsed.value != .object) return error.InvalidJson;
        var l = base;
        const obj = parsed.value.object;
        if (obj.get("task_timeout_ms")) |v| l.task_timeout_ms = try jsonU64(v);
        if (obj.get("task_max_turns")) |v| l.task_max_turns = try jsonU32(v);
        if (obj.get("order_timeout_ms")) |v| l.order_timeout_ms = try jsonU64(v);
        if (obj.get("order_max_turns")) |v| l.order_max_turns = try jsonU32(v);
        return l;
    }

    fn jsonU64(v: std.json.Value) !u64 {
        return switch (v) {
            .integer => |i| if (i >= 0) @intCast(i) else error.InvalidJson,
            else => error.InvalidJson,
        };
    }
    fn jsonU32(v: std.json.Value) !u32 {
        const n = try jsonU64(v);
        if (n > std.math.maxInt(u32)) return error.InvalidJson;
        return @intCast(n);
    }
};

// ── Despacho: seam de ejecución (producción real / prueba) ─────────────────

/// Petición de una corrida de agente externo para UNA tarea del superagente.
/// Permisos que exigen preguntar antes de ejecutar comandos (Manual y Aceptar
/// ediciones): un CLI sin interfaz no puede preguntar, así que no ejecuta.
pub fn denyShellFor(mode: executor.PermissionMode) bool {
    return mode == .normal or mode == .accept_edits;
}

pub const RunRequest = struct {
    meta: AgentMeta,
    model: ?[]const u8 = null,
    zero_cost: bool = false,
    exe_path: ?[]const u8 = null,
    detected_version: ?[]const u8 = null,
    reasoning_effort: ?[]const u8 = null,
    /// Worktree gobernado de la orden: cwd del proceso y raíz del diff.
    worktree: []const u8,
    /// Prompt completo de la tarea (system prompt + contrato + contexto).
    prompt: []const u8,
    /// Tope de reloj efectivo de la tarea (min(límite tarea, resto de orden)).
    timeout_ms: u64,
    /// Tope de turnos efectivo de la tarea (min(límite tarea, resto de orden)).
    max_turns: u32,
    /// Eventos del streaming hacia el ledger/cabina (headless y ACP).
    event_sink: ?headless_adapter.EventSink = null,
    session_sink: ?@import("external_session.zig").Sink = null,
    resume_session: ?[]const u8 = null,
    /// Seam de permisos ACP (session/request_permission → gobernanza).
    permission_fn: ?acp_client.PermissionFn = null,
    permission_ctx: ?*anyopaque = null,
    /// Cancelación de la orden (token compartido del despacho).
    is_cancelled_fn: ?*const fn (?*anyopaque) bool = null,
    cancelled_ctx: ?*anyopaque = null,
    /// Seams de prueba (misma forma que los del adaptador).
    capture_fn: ?headless_adapter.CaptureFn = null,
    getenv: ?headless_adapter.GetEnvFn = null,
    mock_output: ?[]const u8 = null,
    snapshot_diagnostic: ?*headless_adapter.SnapshotDiagnostic = null,
    environ_map: ?*const std.process.Environ.Map = null,
    inherit_personal_context: bool = false,
    /// QA primerizo (10-nov): con permisos «Manual» o «Aceptar ediciones» el
    /// agente no ejecuta comandos sin preguntar. Un CLI sin interfaz no puede
    /// preguntar, así que se le DENIEGA la terminal (hoy: OpenCode, cuyo
    /// `--auto` lo aprobaba todo). Verificado en vivo con OpenCode 1.19.4.
    /// Tanda 2 (12-nov): lo mismo en Codex, Claude Code y Gemini; con Auto
    /// (`false`) los cuatro ejecutan comandos (`headless_adapter.buildArgv`).
    deny_shell: bool = false,
    /// QA-B H7: planificar con la CLI solo lee el proyecto: Claude Code con
    /// Read/Glob/Grep, Codex con `-s read-only`, Gemini en `--approval-mode
    /// default` (sin interfaz deniega editar y ejecutar). OpenCode no tiene
    /// modo de solo lectura: se le niega la terminal (`deny_shell`).
    read_only: bool = false,
};

/// Resultado de una corrida de agente externo: lo que el ledger y el
/// WorkerResult necesitan. Todos los campos owned (deinit con el allocator).
pub const RunOutcome = struct {
    success: bool,
    timed_out: bool = false,
    turn_limited: bool = false,
    cancelled: bool = false,
    exit_code: ?u8 = null,
    duration_ms: u64 = 0,
    turns: u32 = 0,
    /// Tokens solo si el agente los informó; 0 = no informados.
    prompt_tokens: u64 = 0,
    completion_tokens: u64 = 0,
    /// Versión detectada del CLI (cadena, puede ir vacía).
    agent_version: []u8,
    /// argv completo censurado (secretos enmascarados) para el ledger.
    argv_censored: []u8,
    /// Declaración del agente (lo que dice haber hecho — no es artefacto).
    declaration: []u8,
    /// Detalle de salida/error para el ledger (cola de transcripción ACP o
    /// el detalle del modo headless; acotado).
    detail: []u8,
    /// Artefactos del diff del worktree validados por el sandbox.
    artifacts: []worker_backend.Artifact,
    env_warnings: [][]u8 = &.{},

    pub fn deinit(self: *RunOutcome, allocator: std.mem.Allocator) void {
        for (self.artifacts) |*a| a.deinit(allocator);
        allocator.free(self.artifacts);
        allocator.free(self.agent_version);
        allocator.free(self.argv_censored);
        allocator.free(self.declaration);
        allocator.free(self.detail);
        for (self.env_warnings) |w| allocator.free(w);
        if (self.env_warnings.len > 0) allocator.free(self.env_warnings);
    }
};

/// Seam de ejecución: producción = defaultRun (headless_adapter o ACP según
/// el agente); tests inyectan uno fake. `io` solo lo usa el camino headless.
pub const RunFn = *const fn (
    ctx: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    task: planner.PlannedTask,
    req: RunRequest,
    sb: sandbox.Sandbox,
) anyerror!RunOutcome;

/// 10-nov (USUARIO-NUEVO A1). Antes, `checkModelBilling` bloqueaba a Claude
/// Code y OpenCode en cuanto el ANFITRIÓN tenía una variable de facturación,
/// aunque el usuario tuviera suscripción. Ahora el hijo headless nunca la
/// hereda (`cli_policy.cliEnvironment`), así que su presencia ya no impide
/// ejecutar; la facturación la decide la sesión que la CLI declara con ese
/// entorno limpio (`external_registry.resolvePin`: `api_key` sigue bloqueando
/// salvo los gratuitos de OpenCode). El transporte ACP, en cambio, se lanza
/// con el entorno del anfitrión: solo se usa si el anfitrión no tiene ninguna
/// variable de facturación para esa CLI; si la tiene, va por headless.
fn acpAllowed(cli: []const u8, explicit_model: bool, present: cli_policy.PresentFn) bool {
    if (explicit_model or std.mem.eql(u8, cli, "opencode")) return false;
    return !cli_policy.billingForCli(cli, present);
}

test "CK-CAB-002 opencode free execution guard permits only exact free model and forwards pin" {
    // 10-nov (A1): la guardia por variables del anfitrión desapareció (ver
    // acpAllowed). Lo que queda de ella: ACP nunca recibe un anfitrión con
    // claves, y el pin del modelo gratuito llega a la línea de órdenes.
    const Presence = struct {
        fn present(name: [:0]const u8) bool {
            return std.mem.eql(u8, name, "GEMINI_API_KEY");
        }
        fn none(_: [:0]const u8) bool {
            return false;
        }
    };
    try testing.expect(!acpAllowed("gemini-cli", false, Presence.present));
    try testing.expect(acpAllowed("gemini-cli", false, Presence.none));
    try testing.expect(!acpAllowed("gemini-cli", true, Presence.none));
    try testing.expect(!acpAllowed("opencode", false, Presence.none));
    var profile = headless_adapter.OPENCODE;
    profile.model = "opencode/x-free";
    const argv = try headless_adapter.buildArgv(testing.allocator, profile, "C:/fixture", "fixture prompt");
    defer testing.allocator.free(argv);
    var found = false;
    for (argv[0 .. argv.len - 1], 0..) |arg, i| {
        if (std.mem.eql(u8, arg, "--model")) {
            try testing.expectEqualStrings("opencode/x-free", argv[i + 1]);
            found = true;
        }
    }
    try testing.expect(found);
}

/// Ejecución real: ACP si el agente lo soporta (gemini `--acp`, opencode
/// `acp`), si no adaptador headless sobre ExternalCliWorker.
pub fn defaultRun(
    _: ?*anyopaque,
    allocator: std.mem.Allocator,
    io: std.Io,
    task: planner.PlannedTask,
    req: RunRequest,
    sb: sandbox.Sandbox,
) anyerror!RunOutcome {
    const is_codex = std.mem.eql(u8, req.meta.cli_id, "codex");
    const path = if (req.exe_path) |value| try allocator.dupe(u8, value) else (try resolveCliExe(allocator, req.meta.exe)) orelse return error.ExeNotResolved;
    defer allocator.free(path);
    try test_cli_guard.check(allocator, path);
    var verified = try cli_policy.verify(allocator, path);
    defer verified.deinit();
    if (is_codex) {
        const env = req.environ_map orelse return error.InvalidEnvironment;
        switch (try revalidateCodex(allocator, io, verified.path, env)) {
            .suscripcion => {},
            .api_key => return error.ApiBillingForbidden,
            else => return error.NotLoggedIn,
        }
    }
    // Retener shim, node y script hasta cerrar el hijo impide sustituir un
    // eslabón tras verificarlo. El fallback batch usa el escape BatBadBut de
    // Zig 0.16, con la guardia compartida antes del spawn de worker/transporte.
    var launch = try executor.prepareBatchLaunch(allocator, verified.path);
    defer launch.deinit(allocator);
    // ACP defaults remain unchanged. A model pin uses the verified headless
    // model flag rather than silently ignoring it in session/new.
    const explicit_model = if (req.model) |m| !std.mem.eql(u8, m, req.meta.cli_id) and !std.mem.eql(u8, m, "default") else false;
    var pinned_req = req;
    pinned_req.exe_path = verified.path;
    // OpenCode uses run --format json even without a model pin: this is the
    // verified session-resume protocol. Gemini keeps its ACP path.
    if (req.meta.acp_argv != null and acpAllowed(req.meta.cli_id, explicit_model, cli_policy.envPresent))
        return runAcp(allocator, io, task, pinned_req, sb, &launch);
    return runHeadless(allocator, io, task, pinned_req, sb, &launch);
}

fn censorArgv(allocator: std.mem.Allocator, argv: []const []const u8, getenv: ?headless_adapter.GetEnvFn) ![]u8 {
    var joined = std.ArrayList(u8).empty;
    defer joined.deinit(allocator);
    for (argv, 0..) |a, i| {
        if (i > 0) try joined.append(allocator, ' ');
        try joined.appendSlice(allocator, a);
    }
    return try headless_adapter.censorTranscript(allocator, joined.items, getenv orelse headless_adapter.defaultGetEnv);
}

fn runHeadless(
    allocator: std.mem.Allocator,
    io: std.Io,
    task: planner.PlannedTask,
    req: RunRequest,
    sb: sandbox.Sandbox,
    launch: *const executor.BatchLaunch,
) anyerror!RunOutcome {
    const started = GetTickCount64();
    var profile = headless_adapter.profileById(req.meta.cli_id) orelse return error.UnknownCli;
    profile.model = req.model;
    profile.resume_session = req.resume_session;
    profile.inherit_personal_context = req.inherit_personal_context;
    profile.deny_shell = req.deny_shell or req.read_only;
    profile.read_only = req.read_only;
    var effort_config: ?[]u8 = null;
    defer if (effort_config) |value| allocator.free(value);
    if (req.reasoning_effort) |effort| {
        if (effort.len > 0) {
            for (effort) |c| if (!std.ascii.isAlphabetic(c)) return error.UnsupportedReasoningEffort;
            if (std.mem.eql(u8, req.meta.cli_id, "codex")) {
                effort_config = try std.fmt.allocPrint(allocator, "model_reasoning_effort=\"{s}\"", .{effort});
                profile.reasoning_effort = effort_config;
            } else if (std.mem.eql(u8, req.meta.cli_id, "claude-code")) profile.reasoning_effort = effort else return error.UnsupportedReasoningEffort;
        }
    }

    // Versión para el ledger (mismo seam que la detección del registro).
    const capture = req.capture_fn orelse defaultCapture;
    var version: []u8 = try allocator.dupe(u8, "");
    errdefer allocator.free(version);
    if (req.detected_version) |v| {
        allocator.free(version);
        version = try allocator.dupe(u8, v);
    } else if (try detectOne(allocator, capture, req.meta, null)) |d| {
        var dv = d;
        defer dv.deinit(allocator);
        if (dv.version) |v| {
            allocator.free(version);
            version = try allocator.dupe(u8, v);
        }
    }

    // El prompt completo reemplaza a task.description en el adaptador: se
    // despacha una PlannedTask espejo con description=prompt.
    var task2 = task;
    task2.description = req.prompt;

    // Copiar la MISMA cadena retenida por defaultRun: resolver Node de nuevo
    // permitiría elegir otro PATH tras verificar el primero.
    const prefix = try copyLaunchPrefix(allocator, launch);
    defer freeSpawnPrefix(allocator, prefix);

    var report = try headless_adapter.run(allocator, io, task2, sb, .{
        .profile = profile,
        .worktree = req.worktree,
        .timeout_ms = req.timeout_ms,
        .max_turns = req.max_turns,
        .event_sink = req.event_sink,
        .session_sink = req.session_sink,
        .getenv = req.getenv,
        .capture_fn = req.capture_fn,
        .mock_output = req.mock_output,
        .spawn_prefix = prefix,
        .snapshot_diagnostic = req.snapshot_diagnostic,
        .environ_map = req.environ_map,
        .is_cancelled_fn = req.is_cancelled_fn,
        .cancelled_ctx = req.cancelled_ctx,
    });
    errdefer report.deinit(allocator);

    const argv_censored = report.argv_censored orelse return error.MissingLaunchArgv;

    const duration = GetTickCount64() -| started;
    const detail = if (report.transcript.len > 4096)
        try allocator.dupe(u8, report.transcript[report.transcript.len - 4096 ..])
    else
        try allocator.dupe(u8, report.transcript);
    errdefer allocator.free(detail);
    allocator.free(report.transcript);

    return .{
        .success = report.success,
        .timed_out = report.timed_out,
        .turn_limited = report.turn_limited,
        .cancelled = report.cancelled,
        .exit_code = report.exit_code,
        .duration_ms = duration,
        .turns = report.turns,
        .prompt_tokens = report.prompt_tokens,
        .completion_tokens = report.completion_tokens,
        .agent_version = version,
        .argv_censored = argv_censored,
        .declaration = report.declaration,
        .detail = detail,
        .artifacts = report.artifacts,
        .env_warnings = report.env_warnings,
    };
}

/// Puente update_sink de ACP → EventSink del streaming DevAgents.
const AcpEventBridge = struct {
    sink: ?headless_adapter.EventSink,
    /// Último texto de agent_message observado (declaración del agente).
    last_text: std.ArrayList(u8),
    allocator: std.mem.Allocator,

    fn onEvent(ctx: ?*anyopaque, ev: *const acp_client.SessionEvent) void {
        const self: *AcpEventBridge = @ptrCast(@alignCast(ctx.?));
        const kind: headless_adapter.EventKind = switch (ev.kind) {
            .content => .content,
            .reasoning => .reasoning,
            .tool => .tool,
            .plan => .plan,
            .usage => .status,
            .user_echo => .raw,
            else => .status,
        };
        if (ev.text) |t| {
            if (ev.kind == .content and t.len > 0) {
                self.last_text.clearRetainingCapacity();
                self.last_text.appendSlice(self.allocator, t) catch {};
            }
            if (self.sink) |s| s.call(kind, t);
        }
    }
};

fn runAcp(
    allocator: std.mem.Allocator,
    io: std.Io,
    task: planner.PlannedTask,
    req: RunRequest,
    sb: sandbox.Sandbox,
    launch: *const executor.BatchLaunch,
) anyerror!RunOutcome {
    const snapshot_ctx: headless_adapter.SnapshotContext = .{ .diagnostic = req.snapshot_diagnostic, .sink = req.event_sink };
    @import("workspace.zig").ensureExternalRoot(allocator, io, req.worktree) catch |e| {
        snapshot_ctx.reportRoot(allocator, req.worktree, e);
        return e;
    };
    // Captura sobre el handle retenido y compuerta ACL antes de lanzar nada.
    var permissions = try headless_adapter.capturePermissions(allocator, req.worktree, snapshot_ctx);
    defer permissions.deinit();
    var restore_attempted = false;
    // El transporte ACP no devuelve si su árbol quedó atascado: se compara la
    // cuenta global (un falso positivo solo cancela una restauración).
    const stuck_before = process_tree.ProcessTree.stuck_total.load(.acquire);
    return runAcpInner(allocator, io, task, req, sb, launch, &permissions, &restore_attempted, stuck_before) catch |e| {
        // The inner scope has already killed/closed the ACP transport on error.
        if (!restore_attempted) try headless_adapter.restoreWorkspace(allocator, &permissions, .{ .profile = headless_adapter.profileById(req.meta.cli_id) orelse return error.UnknownCli, .worktree = req.worktree, .event_sink = req.event_sink }, snapshot_ctx, process_tree.ProcessTree.stuck_total.load(.acquire) != stuck_before);
        return e;
    };
}

fn runAcpInner(
    allocator: std.mem.Allocator,
    io: std.Io,
    task: planner.PlannedTask,
    req: RunRequest,
    sb: sandbox.Sandbox,
    launch: *const executor.BatchLaunch,
    permissions: *@import("workspace_acl.zig").Snapshot,
    restore_attempted: *bool,
    stuck_before: u32,
) anyerror!RunOutcome {
    _ = task;
    const started = GetTickCount64();
    const capture = req.capture_fn orelse defaultCapture;
    const getenv = req.getenv orelse headless_adapter.defaultGetEnv;
    const acp_argv = req.meta.acp_argv.?;
    // Despacho: la línea base precede incluso al arranque/initialize/session-new
    // del agente externo, que se trata como código no confiable.
    // La raíz ya pasó la compuerta ACL y la captura en `runAcp`.
    const snapshot_ctx: headless_adapter.SnapshotContext = .{ .diagnostic = req.snapshot_diagnostic, .sink = req.event_sink };
    var baseline = try headless_adapter.captureArtifactBaselineContext(allocator, io, capture, req.worktree, null, snapshot_ctx);
    defer baseline.deinit(allocator);

    // ACP comparte exactamente el launch retenido del request, sin volver
    // a seleccionar Node/JS por PATH ni comprobar otra cadena distinta.
    const prefix = try copyLaunchPrefix(allocator, launch);
    defer freeSpawnPrefix(allocator, prefix);
    var argv = try allocator.alloc([]const u8, prefix.len + acp_argv.len);
    defer allocator.free(argv);
    @memcpy(argv[0..prefix.len], prefix);
    @memcpy(argv[prefix.len..], acp_argv);
    const argv_censored = try censorArgv(allocator, argv, req.getenv);
    errdefer allocator.free(argv_censored);

    // Avisos E5.01 de facturación por API (misma regla que headless).
    var warns = try headless_adapter.billingEnvWarnings(allocator, getenv);
    errdefer {
        for (warns.items) |w| allocator.free(w);
        warns.deinit(allocator);
    }

    var client = acp_client.AcpClient.connect(allocator, argv, req.worktree, 60 * 1000) catch |e| {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.UnsafeBatchArgument => error.UnsafeBatchArgument,
            else => error.SpawnFailed,
        };
    };
    // El deinit del cliente cierra el transporte → kill del hijo ACP.
    var client_live = true;
    defer if (client_live) client.deinit();

    client.permission_fn = req.permission_fn;
    client.permission_ctx = req.permission_ctx;
    client.is_cancelled_fn = req.is_cancelled_fn;
    client.cancelled_ctx = req.cancelled_ctx;

    var bridge = AcpEventBridge{
        .sink = req.event_sink,
        .last_text = .empty,
        .allocator = allocator,
    };
    defer bridge.last_text.deinit(allocator);
    client.update_sink = .{ .ctx = &bridge, .func = AcpEventBridge.onEvent };

    try client.initialize();
    _ = try client.sessionNew(req.worktree);

    var stop: ?acp_client.StopReason = null;
    var prompt_err: ?anyerror = null;
    const res = client.prompt(client.session_id.?, req.prompt, req.timeout_ms) catch |e| blk: {
        prompt_err = e;
        break :blk acp_client.PromptResult{ .stop_reason = .end_turn };
    };
    stop = res.stop_reason;

    const duration = GetTickCount64() -| started;
    const timed_out = prompt_err != null and prompt_err.? == error.Timeout;
    const cancelled = client.cancelled_local or stop == .cancelled;

    const version = try allocator.dupe(u8, client.agent_info.version);
    errdefer allocator.free(version);
    const last_error = if (client.last_error) |value| try allocator.dupe(u8, value) else null;
    defer if (last_error) |value| allocator.free(value);
    client.deinit();
    client_live = false;
    restore_attempted.* = true;
    try headless_adapter.restoreWorkspace(allocator, permissions, .{ .profile = headless_adapter.profileById(req.meta.cli_id) orelse return error.UnknownCli, .worktree = req.worktree, .event_sink = req.event_sink }, snapshot_ctx, process_tree.ProcessTree.stuck_total.load(.acquire) != stuck_before);

    // Artefactos del diff (igual que headless): nada cuenta si el sandbox
    // rechaza una ruta — el fallo se propaga y la tarea falla honesto.
    const artifacts = try headless_adapter.collectArtifactChangesContext(allocator, io, capture, req.worktree, baseline, sb, snapshot_ctx);
    errdefer {
        for (artifacts) |*a| a.deinit(allocator);
        allocator.free(artifacts);
    }

    const success = prompt_err == null and !cancelled and stop == .end_turn;
    const declaration = try allocator.dupe(u8, bridge.last_text.items);
    errdefer allocator.free(declaration);
    const detail = if (last_error) |le|
        try std.fmt.allocPrint(allocator, "acp:{s} stop={s} err={s}", .{ req.meta.cli_id, @tagName(stop orelse .end_turn), le })
    else
        try std.fmt.allocPrint(allocator, "acp:{s} stop={s}", .{ req.meta.cli_id, @tagName(stop orelse .end_turn) });
    errdefer allocator.free(detail);

    return .{
        .success = success,
        .timed_out = timed_out,
        .turn_limited = false,
        .cancelled = cancelled,
        .exit_code = null,
        .duration_ms = duration,
        // ACP v1: un turno = un session/prompt (los turnos internos del agente
        // no son observables por el protocolo — ver docs aislamiento).
        .turns = 1,
        .prompt_tokens = 0,
        .completion_tokens = 0,
        .agent_version = version,
        .argv_censored = argv_censored,
        .declaration = declaration,
        .detail = detail,
        .artifacts = artifacts,
        .env_warnings = try warns.toOwnedSlice(allocator),
    };
}

// ── Coste (E5.08): usage_records con categoría subscription ────────────────

/// Fila de consumo de un agente externo: tokens solo si el agente los
/// informó (0 si no), dólares nulos (la tabla no los tiene — nunca
/// inventados), categoría 'subscription' para que el contable de escaladas
/// NO lo confunda con una llamada de API de pago.
pub fn recordSubscriptionUsage(
    conn: db.Connection,
    order_id: i64,
    worker_id: []const u8,
    provider: []const u8,
    model: []const u8,
    prompt_tokens: u64,
    completion_tokens: u64,
) void {
    const stmt = conn.prepare("INSERT INTO usage_records (order_id, worker_id, provider, model, prompt_tokens, completion_tokens, total_tokens, cached_tokens, key_label, timestamp, cost_category) VALUES (?, ?, ?, ?, ?, ?, ?, 0, '', ?, 'subscription')") catch return;
    defer conn.finalize(stmt);
    db.bindInt(stmt, 1, order_id) catch return;
    db.bindText(stmt, 2, worker_id) catch return;
    db.bindText(stmt, 3, provider) catch return;
    db.bindText(stmt, 4, model) catch return;
    db.bindInt(stmt, 5, @intCast(@min(prompt_tokens, std.math.maxInt(i64)))) catch return;
    db.bindInt(stmt, 6, @intCast(@min(completion_tokens, std.math.maxInt(i64)))) catch return;
    db.bindInt(stmt, 7, @intCast(@min(prompt_tokens +| completion_tokens, std.math.maxInt(i64)))) catch return;
    db.bindInt(stmt, 8, health.nowMillis(conn)) catch return;
    _ = db.c.sqlite3_step(stmt);
}

// ── Permisos (E5.08): clasificación de session/request_permission ──────────

/// Resultado de evaluar un request de permiso ACP contra la gobernanza.
pub const PermissionVerdict = enum {
    /// Toda ruta declarada dentro del worktree (read/edit/search) o comando
    /// auto-aprobado por checkPrefix → elegir la opción allow.
    allow,
    /// Comando que pide aprobación en este modo → tarjeta de la cabina
    /// (persistApprovalRequest + espera de resolución).
    ask,
    /// Ruta fuera del worktree → siempre denegado.
    deny,
};

/// Clasifica un tool_call ACP: fs/kind de lectura-escritura → veredicto por
/// rutas (todas deben pasar el sandbox del worktree); execute/fetch/otros →
/// comando gobernado por `executor.checkPrefix` con la config de la orden.
pub fn classifyPermission(
    allocator: std.mem.Allocator,
    tool_call_json: []const u8,
    sb: sandbox.Sandbox,
    permission_config: executor.PermissionConfig,
) PermissionVerdict {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, tool_call_json, .{}) catch return .deny;
    defer parsed.deinit();
    if (parsed.value != .object) return .deny;
    const obj = parsed.value.object;
    const kind: []const u8 = if (obj.get("kind")) |k| (if (k == .string) k.string else "") else "";

    const is_fs = std.mem.eql(u8, kind, "read") or
        std.mem.eql(u8, kind, "edit") or
        std.mem.eql(u8, kind, "delete") or
        std.mem.eql(u8, kind, "move") or
        std.mem.eql(u8, kind, "search");
    if (is_fs) {
        // Toda ruta declarada debe caer dentro del worktree. locations[] del
        // spec trae {path}; rawInput.path/newPath cubre variantes del agente.
        var found = false;
        if (obj.get("locations")) |locs| {
            if (locs == .array) {
                for (locs.array.items) |loc| {
                    if (loc != .object) continue;
                    if (loc.object.get("path")) |p| {
                        if (p == .string and p.string.len > 0) {
                            found = true;
                            if (!pathInsideSandbox(allocator, p.string, sb)) return .deny;
                        }
                    }
                }
            }
        }
        if (obj.get("rawInput")) |ri| {
            if (ri == .object) {
                inline for (.{ "path", "newPath", "oldPath" }) |field| {
                    if (ri.object.get(field)) |p| {
                        if (p == .string and p.string.len > 0) {
                            found = true;
                            if (!pathInsideSandbox(allocator, p.string, sb)) return .deny;
                        }
                    }
                }
            }
        }
        // Un fs sin rutas legibles no se auto-aprueba: pide tarjeta.
        return if (found) .allow else .ask;
    }

    if (std.mem.eql(u8, kind, "think")) return .allow;

    // execute / fetch / switch_mode / other / ausente → comando gobernado.
    // El exe lo da rawInput.command (primer token) o el título del tool_call.
    var exe: []const u8 = "";
    if (obj.get("rawInput")) |ri| {
        if (ri == .object) {
            if (ri.object.get("command")) |c| {
                if (c == .string) exe = firstToken(c.string);
            }
        }
    }
    if (exe.len == 0) {
        if (obj.get("title")) |t| {
            if (t == .string) exe = firstToken(t.string);
        }
    }
    return switch (executor.checkPrefix(exe, permission_config)) {
        .auto => .allow,
        .ask => .ask,
    };
}

fn firstToken(s: []const u8) []const u8 {
    const trimmed = std.mem.trim(u8, s, " \t\"'");
    const end = std.mem.indexOfAny(u8, trimmed, " \t") orelse trimmed.len;
    return trimmed[0..end];
}

/// ¿La ruta (absoluta o relativa al worktree) cae dentro del sandbox?
/// ACP envía rutas absolutas: se prueban tal cual contra la raíz canónica.
fn pathInsideSandbox(allocator: std.mem.Allocator, path: []const u8, sb: sandbox.Sandbox) bool {
    _ = allocator;
    return sb.isAllowed(path);
}

/// Elige el optionId de la lista ofrecida por el agente: preferir
/// allow_once/allow_always para allow; reject_* para deny; null = la lista
/// no ofrece esa clase → el llamador decide cancelled.
pub fn pickOption(allocator: std.mem.Allocator, options_json: []const u8, allow: bool) ?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, options_json, .{}) catch return null;
    defer parsed.deinit();
    if (parsed.value != .array) return null;
    var fallback: ?[]const u8 = null;
    for (parsed.value.array.items) |opt| {
        if (opt != .object) continue;
        const o = opt.object;
        const oid = if (o.get("optionId")) |v| (if (v == .string) v.string else "") else "";
        const kind = if (o.get("kind")) |v| (if (v == .string) v.string else "") else "";
        if (oid.len == 0) continue;
        const is_allow_opt = std.mem.startsWith(u8, kind, "allow");
        if (allow and is_allow_opt) {
            if (std.mem.eql(u8, kind, "allow_once")) return dupStr(allocator, oid);
            if (fallback == null) fallback = oid;
        } else if (!allow and !is_allow_opt and kind.len > 0) {
            if (std.mem.eql(u8, kind, "reject_once")) return dupStr(allocator, oid);
            if (fallback == null) fallback = oid;
        } else if (!allow and kind.len == 0) {
            if (fallback == null) fallback = oid;
        }
    }
    if (fallback) |f| return dupStr(allocator, f);
    return null;
}

fn dupStr(allocator: std.mem.Allocator, s: []const u8) ?[]u8 {
    return allocator.dupe(u8, s) catch null;
}

// ── Tests ─────────────────────────────────────────────────────────────────

const testing = std.testing;

test "registro: ids agent:<cli> y fabricantes (E5.08)" {
    try testing.expect(isAgentProvider("agent:claude-code"));
    try testing.expect(!isAgentProvider("Claude"));
    try testing.expect(!isAgentProvider("agent:"));

    const m = metaForProvider("agent:codex").?;
    try testing.expectEqualStrings("codex", m.cli_id);
    try testing.expectEqual(Manufacturer.openai, m.manufacturer);
    try testing.expect(metaForProvider("agent:desconocido") == null);
    try testing.expect(metaForProvider("GPT") == null);

    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("agent:gemini-cli", providerName(&buf, metaForCliId("gemini-cli").?));
}

test "exclusión cruzada por fabricante (E5.08)" {
    // Productor agente ↔ auditor del mismo fabricante (catálogo u otro agente).
    try testing.expect(crossManufacturerExcluded("agent:claude-code", "Claude"));
    try testing.expect(crossManufacturerExcluded("agent:claude-code", "Anthropic"));
    try testing.expect(crossManufacturerExcluded("agent:codex", "GPT"));
    try testing.expect(crossManufacturerExcluded("agent:codex", "OpenAI"));
    try testing.expect(crossManufacturerExcluded("agent:gemini-cli", "Gemini"));
    try testing.expect(crossManufacturerExcluded("agent:gemini-cli", "Google AI Studio"));
    try testing.expect(crossManufacturerExcluded("agent:opencode", "OpenCode"));
    // La regla es simétrica: productor de catálogo ↔ auditor agente.
    try testing.expect(crossManufacturerExcluded("Claude", "agent:claude-code"));
    // Fabricantes distintos: permitido.
    try testing.expect(!crossManufacturerExcluded("agent:claude-code", "GPT"));
    try testing.expect(!crossManufacturerExcluded("agent:codex", "Gemini"));
    try testing.expect(!crossManufacturerExcluded("agent:gemini-cli", "Cohere"));
    // Catálogo↔catálogo sigue siendo por modelo exacto: aquí NO se excluye.
    try testing.expect(!crossManufacturerExcluded("Claude", "Claude"));
    try testing.expect(!crossManufacturerExcluded("GPT", "Gemini"));
    // Proveedor sin fabricante mapeado no se excluye.
    try testing.expect(!crossManufacturerExcluded("agent:claude-code", "Cohere"));
}

test "parseVersionText extrae semver" {
    const a = testing.allocator;
    const v1 = (try parseVersionText(a, "claude 2.1.221\n")).?;
    defer a.free(v1);
    try testing.expectEqualStrings("2.1.221", v1);
    const v2 = (try parseVersionText(a, "0.144.4\n")).?;
    defer a.free(v2);
    try testing.expectEqualStrings("0.144.4", v2);
    const v3 = (try parseVersionText(a, "opencode version 1.18.25")).?;
    defer a.free(v3);
    try testing.expectEqualStrings("1.18.25", v3);
    // Sin semver legible → primera línea honesta.
    const v4 = (try parseVersionText(a, "custom build")).?;
    defer a.free(v4);
    try testing.expectEqualStrings("custom build", v4);
    try testing.expect((try parseVersionText(a, "  \n")) == null);
}

fn fakeResolvePresent(allocator: std.mem.Allocator, exe: []const u8) anyerror!?[]u8 {
    // Solo claude/gemini "existen" para el seam; el resto ausente.
    if (std.mem.eql(u8, exe, "claude")) return try allocator.dupe(u8, "C:\\tools\\claude.exe");
    if (std.mem.eql(u8, exe, "gemini")) return try allocator.dupe(u8, "C:\\npm\\gemini.cmd");
    return null;
}

fn fakeCapturePresent(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) anyerror!providers.github.CmdCapture {
    _ = cwd;
    // argv[0] ya viene resuelto (ruta absoluta o cmd.exe fijado + /d /c +
    // shim): el nombre del CLI puede ir en cualquier entrada del argv.
    var has_claude = false;
    var has_gemini = false;
    for (argv) |a| {
        if (std.mem.indexOf(u8, a, "claude") != null) has_claude = true;
        if (std.mem.indexOf(u8, a, "gemini") != null) has_gemini = true;
    }
    if (has_claude) {
        return .{ .exit_code = 0, .stdout = try allocator.dupe(u8, "2.1.221 (Claude Code)"), .stderr = try allocator.dupe(u8, "") };
    }
    if (has_gemini) {
        return .{ .exit_code = 0, .stdout = try allocator.dupe(u8, "gemini-cli v0.53.1"), .stderr = try allocator.dupe(u8, "") };
    }
    return .{ .exit_code = 1, .stdout = try allocator.dupe(u8, ""), .stderr = try allocator.dupe(u8, "not found") };
}

test "detectAll: solo los presentes, con versión y capacidad ACP" {
    const a = testing.allocator;
    const list = try detectAll(a, fakeCapturePresent, fakeResolvePresent);
    defer {
        for (list) |*d| d.deinit(a);
        a.free(list);
    }
    try testing.expectEqual(@as(usize, 2), list.len);
    try testing.expectEqualStrings("agent:claude-code", list[0].provider);
    try testing.expectEqualStrings("2.1.221", list[0].version.?);
    try testing.expect(!list[0].acp);
    try testing.expectEqualStrings("C:\\tools\\claude.exe", list[0].exe);
    try testing.expectEqualStrings("agent:gemini-cli", list[1].provider);
    try testing.expectEqualStrings("0.53.1", list[1].version.?);
    try testing.expect(list[1].acp);
    try testing.expectEqualStrings("C:\\npm\\gemini.cmd", list[1].exe);
    try testing.expectEqual(Manufacturer.google, list[1].manufacturer);
}

test "E-369: detectedJson separa las apps empaquetadas que pueden escribir" {
    const a = testing.allocator;
    const list = try detectAll(a, fakeCapturePresent, fakeResolvePresent);
    defer {
        for (list) |*d| d.deinit(a);
        a.free(list);
    }
    // Una SID de solo lectura y otra de una app (huérfana: ningún paquete de
    // este equipo tiene estos RID) con escritura.
    list[0].acl_appcontainer_sids = try a.dupe(u8, "S-1-15-2-123-456\nw:S-1-15-3-11-22-33-44-55-66-77\n");
    const json = try detectedJson(a, list);
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"acl_appcontainer_sids\":[\"S-1-15-2-123-456\"]") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"acl_appcontainer_writers\":[{\"sid\":\"S-1-15-3-11-22-33-44-55-66-77\",\"app\":null}]") != null);
    try testing.expect(std.mem.indexOf(u8, json, "w:S-1-15") == null);
}

test "detectedJson: campos del registro para C-ABI/MCP/cabina" {
    const a = testing.allocator;
    const list = try detectAll(a, fakeCapturePresent, fakeResolvePresent);
    defer {
        for (list) |*d| d.deinit(a);
        a.free(list);
    }
    list[0].acl_appcontainer_sids = try a.dupe(u8, "S-1-15-2-123-456\nS-1-15-3-123-456\n");
    const json = try detectedJson(a, list);
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"acl_appcontainer_sids\":[\"S-1-15-2-123-456\",\"S-1-15-3-123-456\"]") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"acl_appcontainer_sids\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"acl_appcontainer_writers\":[]") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"provider\":\"agent:claude-code\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"version\":\"2.1.221\"") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"acp\":true") != null);
    try testing.expect(std.mem.indexOf(u8, json, "Claude Code (sesión desconocida)") != null);
    try testing.expect(std.mem.indexOf(u8, json, "\"manufacturer\":\"anthropic\"") != null);
}

test "CK-CAB-002 opencode free R2 discovery requests verbose metadata" {
    const Probe = struct {
        fn capture(a: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) anyerror!providers.github.CmdCapture {
            if (std.mem.eql(u8, argv[argv.len - 1], "--verbose")) {
                try testing.expectEqualStrings("models", argv[argv.len - 2]);
                return .{ .exit_code = 0, .stdout = try a.dupe(u8, "opencode/x-free\n{\"id\":\"x-free\",\"providerID\":\"opencode\",\"cost\":{\"input\":0,\"output\":0}}\n"), .stderr = try a.dupe(u8, "") };
            }
            if (std.mem.eql(u8, argv[argv.len - 1], "models")) return error.VerboseMetadataRequired;
            return fakeCatalogCapture(a, argv, cwd);
        }
    };
    const a = testing.allocator;
    var d = try ownDetected(a, metaForCliId("opencode").?, "C:/fixture/opencode.exe", try a.dupe(u8, "1.18.25"), false);
    defer d.deinit(a);
    try enrichDetectedWithPresence(a, Probe.capture, &d, noEnvPresent);
    try testing.expectEqual(EnumerationStatus.enumerated, d.enumeration_status);
    try testing.expectEqual(Session.api_key, d.session);
    try testing.expect(d.models[0].zero_cost);
    try testing.expect(catalog.isFreeModel(d.cli, d.models[0].slug, d.models[0].zero_cost));
}

test "CK-CAB-002 opencode free R2 verbose costs control catalog labels" {
    const a = testing.allocator;
    const output =
        \\opencode/deepseek-v4.1-flash-free
        \\{
        \\  "id": "deepseek-v4.1-flash-free",
        \\  "providerID": "opencode",
        \\  "cost": {
        \\    "input": 0,
        \\    "output": 0,
        \\    "cache": {"read": 0, "write": 0}
        \\  }
        \\}
        \\opencode/charged-free
        \\{
        \\  "cost": {"input": 0, "output": 0.25}
        \\}
        \\opencode/missing-free
        \\opencode/broken-free
        \\{bad}
        \\fireworks/x-free
        \\{"cost":{"input":0,"output":0}}
    ;
    var models = try catalog.parseModels(a, "opencode", output);
    defer models.deinit(a);
    try testing.expectEqual(EnumerationStatus.enumerated, models.status);
    try testing.expectEqual(@as(usize, 5), models.models.len);
    const detected: DetectedAgent = .{
        .provider = @constCast("agent:opencode"),
        .cli = @constCast("opencode"),
        .display = @constCast("OpenCode"),
        .exe = @constCast("C:/app/opencode.exe"),
        .version = null,
        .acp = true,
        .manufacturer = .opencode,
        .session = .api_key,
        .models = models.models,
    };
    const json = try detectedJson(a, &.{detected});
    defer a.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    const rows = parsed.value.array.items[0].object.get("models").?.array.items;
    for (rows, 0..) |row, i| try testing.expectEqual(i == 0, row.object.get("free").?.bool);
}

test "CK-CAB-002 opencode free E5.56 catalog labels models without changing CLI session" {
    const a = testing.allocator;
    var models = try catalog.parseModels(a, "opencode", "opencode/x-free\n{\"id\":\"x-free\",\"providerID\":\"opencode\",\"cost\":{\"input\":0,\"output\":0}}\nopencode/claude-opus-5\nfireworks/x-free\n");
    defer models.deinit(a);
    const detected: DetectedAgent = .{
        .provider = @constCast("agent:opencode"),
        .cli = @constCast("opencode"),
        .display = @constCast("OpenCode"),
        .exe = @constCast("C:/app/opencode.exe"),
        .version = null,
        .acp = true,
        .manufacturer = .opencode,
        .session = .api_key,
        .models = models.models,
    };
    const json = try detectedJson(a, &.{detected});
    defer a.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    const agent = parsed.value.array.items[0];
    try testing.expectEqualStrings("api_key", agent.object.get("session").?.string);
    const rows = agent.object.get("models").?.array.items;
    try testing.expect(rows[0].object.contains("free"));
    try testing.expect(rows[0].object.get("free").?.bool);
    try testing.expectEqualStrings("OpenCode · opencode/x-free (gratis)", rows[0].object.get("label").?.string);
    for (rows[1..]) |row| {
        try testing.expect(!row.object.get("free").?.bool);
        try testing.expect(row.object.get("label") == null);
    }
    // 10-nov (A1): OpenCode con claves guardadas en su perfil conserva sus
    // gratuitos; la etiqueta lo dice en vez de «facturación API: bloqueado».
    try testing.expect(std.mem.indexOf(u8, agent.object.get("label").?.string, "solo modelos gratuitos") != null);
}

test "Limits: defaults de la fila + roundtrip JSON" {
    const a = testing.allocator;
    const l = Limits{};
    try testing.expectEqual(@as(u64, 15 * 60 * 1000), l.task_timeout_ms);
    try testing.expectEqual(@as(u32, 40), l.task_max_turns);
    const json = try l.toJson(a);
    defer a.free(json);
    const back = try Limits.fromJson(.{}, a, json);
    try testing.expectEqual(l, back);
    // Parse parcial: solo cambia el campo dado.
    const l2 = try Limits.fromJson(l, a, "{\"task_max_turns\":7}");
    try testing.expectEqual(@as(u32, 7), l2.task_max_turns);
    try testing.expectEqual(l.task_timeout_ms, l2.task_timeout_ms);
    try testing.expectError(error.InvalidJson, Limits.fromJson(l, a, "{\"task_max_turns\":-1}"));
}

test "classifyPermission: fs dentro del worktree → allow" {
    const a = testing.allocator;
    var sb = try sandbox.Sandbox.init(a, "C:\\wt");
    defer sb.deinit();
    const tc = "{\"kind\":\"edit\",\"locations\":[{\"path\":\"src/main.zig\"}]}";
    try testing.expectEqual(PermissionVerdict.allow, classifyPermission(a, tc, sb, .{}));
}

test "classifyPermission: fuera del worktree → siempre deny (E5.08)" {
    const a = testing.allocator;
    var sb = try sandbox.Sandbox.init(a, "C:\\wt");
    defer sb.deinit();
    // Absoluta fuera del root.
    try testing.expectEqual(PermissionVerdict.deny, classifyPermission(a, "{\"kind\":\"edit\",\"locations\":[{\"path\":\"C:\\\\other\\\\evil.txt\"}]}", sb, .{}));
    // Escape relativo por "..".
    try testing.expectEqual(PermissionVerdict.deny, classifyPermission(a, "{\"kind\":\"edit\",\"rawInput\":{\"path\":\"..\\\\escape.txt\"}}", sb, .{}));
    // La regla no depende del modo de permisos.
    try testing.expectEqual(PermissionVerdict.deny, classifyPermission(a, "{\"kind\":\"edit\",\"locations\":[{\"path\":\"C:\\\\other\\\\evil.txt\"}]}", sb, .{ .mode = .bypass }));
}

test "classifyPermission: fs sin rutas → ask (tarjeta)" {
    const a = testing.allocator;
    var sb = try sandbox.Sandbox.init(a, "C:\\wt");
    defer sb.deinit();
    try testing.expectEqual(PermissionVerdict.ask, classifyPermission(a, "{\"kind\":\"read\"}", sb, .{}));
}

test "classifyPermission: comandos por modo de gobernanza" {
    const a = testing.allocator;
    var sb = try sandbox.Sandbox.init(a, "C:\\wt");
    defer sb.deinit();
    const tc = "{\"kind\":\"execute\",\"rawInput\":{\"command\":\"npm test\"}}";
    // normal → ask (tarjeta de la cabina)
    try testing.expectEqual(PermissionVerdict.ask, classifyPermission(a, tc, sb, .{ .mode = .normal }));
    try testing.expectEqual(PermissionVerdict.ask, classifyPermission(a, tc, sb, .{ .mode = .accept_edits }));
    // bypass/autonomous → auto
    try testing.expectEqual(PermissionVerdict.allow, classifyPermission(a, tc, sb, .{ .mode = .bypass }));
    try testing.expectEqual(PermissionVerdict.allow, classifyPermission(a, tc, sb, .{ .mode = .autonomous }));
    // denylist siempre gana → ask
    try testing.expectEqual(PermissionVerdict.ask, classifyPermission(a, tc, sb, .{ .mode = .bypass, .deny_prefixes = &.{"npm"} }));
    // allowlist → auto incluso en normal
    try testing.expectEqual(PermissionVerdict.allow, classifyPermission(a, tc, sb, .{ .mode = .normal, .allow_prefixes = &.{"npm"} }));
    // think → allow; JSON ilegible → deny (fail-closed)
    try testing.expectEqual(PermissionVerdict.allow, classifyPermission(a, "{\"kind\":\"think\"}", sb, .{}));
    try testing.expectEqual(PermissionVerdict.deny, classifyPermission(a, "not json", sb, .{}));
}

test "pickOption: allow_once preferido; reject para deny" {
    const a = testing.allocator;
    const opts = "[{\"optionId\":\"r1\",\"kind\":\"reject_once\"},{\"optionId\":\"a1\",\"kind\":\"allow_always\"},{\"optionId\":\"a2\",\"kind\":\"allow_once\"}]";
    const sel = pickOption(a, opts, true).?;
    defer a.free(sel);
    try testing.expectEqualStrings("a2", sel);
    const rej = pickOption(a, opts, false).?;
    defer a.free(rej);
    try testing.expectEqualStrings("r1", rej);
    // Sin opción de la clase pedida → null (cancelled).
    try testing.expect(pickOption(a, "[{\"optionId\":\"a\",\"kind\":\"allow_once\"}]", false) == null);
}

// ── Resolución de shims .cmd (E5.08): los CLIs npm solo existen como .cmd ──

const GENERIC_WRITE_T: u32 = 0x40000000;
const FILE_SHARE_READ_T: u32 = 0x00000001;
const CREATE_NEW_T: u32 = 1;
const FILE_ATTRIBUTE_NORMAL_T: u32 = 0x80;
const INVALID_HANDLE_VALUE_T: std.os.windows.HANDLE = @ptrFromInt(~@as(usize, 0));

/// Monta `<tmp>/e5agshim<tick>/<name>.cmd` y lo antepone al PATH del proceso
/// durante el test (restaurado siempre). Mismo patrón que el fixture del
/// ejecutor E5.05.
const CliShimFixture = struct {
    dir: []u8,
    shim: []u8,
    old_path: [:0]u8,

    fn install(a: std.mem.Allocator, name: []const u8) !CliShimFixture {
        var tmp_buf: [4096]u8 = undefined;
        const tn = GetTempPathA(tmp_buf.len, &tmp_buf);
        if (tn == 0 or tn >= tmp_buf.len) return error.TempPathFailed;
        const dir = try std.fmt.allocPrint(a, "{s}e5agshim{d}", .{ tmp_buf[0..tn], GetTickCount64() });
        errdefer a.free(dir);
        const dir_z = try a.dupeZ(u8, dir);
        defer a.free(dir_z);
        if (CreateDirectoryA(dir_z, null) == 0) return error.MkdirFailed;

        const shim = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "{s}.cmd", .{ dir, name });
        errdefer a.free(shim);
        const shim_z = try a.dupeZ(u8, shim);
        defer a.free(shim_z);
        const hf = CreateFileA(shim_z.ptr, GENERIC_WRITE_T, FILE_SHARE_READ_T, null, CREATE_NEW_T, FILE_ATTRIBUTE_NORMAL_T, null);
        if (hf == INVALID_HANDLE_VALUE_T) return error.ShimWriteFailed;
        const body = "@echo off\r\n@echo 9.9.9-test\r\n";
        var written: u32 = 0;
        _ = WriteFile(hf, body.ptr, body.len, &written, null);
        _ = CloseHandle(hf);

        var path_buf: [32768]u8 = undefined;
        const pn = GetEnvironmentVariableA("PATH", &path_buf, path_buf.len);
        if (pn == 0 or pn >= path_buf.len) return error.EnvNotFound;
        const old_path = try a.dupeZ(u8, path_buf[0..pn]);
        errdefer a.free(old_path);
        const new_path = try std.fmt.allocPrintSentinel(a, "{s};{s}", .{ dir, old_path }, 0);
        defer a.free(new_path);
        if (SetEnvironmentVariableA("PATH", new_path.ptr) == 0) return error.PathSetFailed;
        return .{ .dir = dir, .shim = shim, .old_path = old_path };
    }

    fn uninstall(fx: *CliShimFixture, a: std.mem.Allocator) void {
        _ = SetEnvironmentVariableA("PATH", fx.old_path.ptr);
        const dir_z = a.dupeZ(u8, fx.dir) catch null;
        const shim_z = a.dupeZ(u8, fx.shim) catch null;
        if (shim_z) |s| _ = DeleteFileA(s.ptr);
        if (dir_z) |d| _ = RemoveDirectoryA(d.ptr);
        if (shim_z) |s| a.free(s);
        if (dir_z) |d| a.free(d);
        a.free(fx.shim);
        a.free(fx.dir);
        a.free(fx.old_path);
    }
};

test "E5.B13 trust: untrusted real PATH shim is not executed" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = testing.allocator;
    var fx = try CliShimFixture.install(a, "e5agcli");
    defer fx.uninstall(a);
    try testing.expect((try resolveCliExe(a, "e5agcli")) == null);
    try testing.expect((try spawnPrefix(a, "e5agcli")) == null);
    const meta: AgentMeta = .{ .cli_id = "e5agcli", .exe = "e5agcli", .display = "E5 Shim", .manufacturer = .opencode, .acp_argv = null };
    try testing.expect((try detectOne(a, discoveryCapture, meta, null)) == null);
    try testing.expectError(error.UntrustedCliRoot, spawnPrefixForPath(a, fx.shim));
    try testing.expectError(error.UntrustedCliRoot, detectCandidates(a, discoveryCapture, meta, &.{fx.shim}, true));
}

test "VG1 H19: fake claude on PATH outside double directories cannot be detected or launched" {
    if (builtin.os.tag != .windows) return @import("platform.zig").skip("Windows PATH shim regression; POSIX barrier uses the same canonical path check");
    const a = testing.allocator;
    var fx = try CliShimFixture.install(a, "claude");
    defer fx.uninstall(a);
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const allowed = try tmp.dir.realPathFileAlloc(testing.io, ".", a);
    defer a.free(allowed);
    const allowed_z = try a.dupeZ(u8, allowed);
    defer a.free(allowed_z);
    const keys = [_][:0]const u8{ "BEATS_TEST_BIN_DIR", "DEVAGENTS_TEST_FIXTURE_DIR", "DEVAGENTS_TEST_REAL_CLI_FORBIDDEN" };
    var saved: [3]?[:0]u8 = @splat(null);
    for (keys, 0..) |key, i| {
        var buf: [32768]u8 = undefined;
        const n = GetEnvironmentVariableA(key, &buf, buf.len);
        if (n > 0 and n < buf.len) saved[i] = try a.dupeZ(u8, buf[0..n]);
    }
    defer for (keys, saved) |key, value| {
        _ = SetEnvironmentVariableA(key, if (value) |v| v.ptr else null);
        if (value) |v| a.free(v);
    };
    try testing.expect(SetEnvironmentVariableA(keys[0], allowed_z) != 0);
    try testing.expect(SetEnvironmentVariableA(keys[1], allowed_z) != 0);
    try testing.expect(SetEnvironmentVariableA(keys[2], "1") != 0);
    try testing.expectError(error.TestRealCliForbidden, test_cli_guard.check(a, fx.shim));
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "double.cmd", .data = "@exit /b 0" });
    const double = try tmp.dir.realPathFileAlloc(testing.io, "double.cmd", a);
    defer a.free(double);
    try test_cli_guard.checkArgv(a, &.{ "cmd.exe", "/d", "/s", "/c", double });
    try testing.expectError(error.TestRealCliForbidden, test_cli_guard.checkArgv(a, &.{ "cmd.exe", "/d", "/s", "/c", fx.shim }));
    const meta = metaForCliId("claude-code").?;
    try testing.expect((try detectOne(a, discoveryCapture, meta, null)) == null);
    try testing.expectError(error.TestRealCliForbidden, detectCandidates(a, discoveryCapture, meta, &.{fx.shim}, true));
    const forced = try std.json.Stringify.valueAlloc(a, .{ .@"claude-code" = fx.shim }, .{});
    defer a.free(forced);
    try testing.expectError(error.TestRealCliForbidden, detectAllWithPaths(a, null, forced));
    var sb = try sandbox.Sandbox.init(a, allowed);
    defer sb.deinit();
    const task = planner.PlannedTask{ .id = "guard", .task_type = .investigar, .department = "documentacion", .description = "must not launch", .contract_fields = &.{}, .depends_on = &.{}, .needs_vision = false };
    try testing.expectError(error.TestRealCliForbidden, defaultRun(null, a, testing.io, task, .{ .meta = meta, .exe_path = fx.shim, .worktree = allowed, .prompt = "must not launch", .timeout_ms = 1000, .max_turns = 1 }, sb));
}

fn fakeCatalogCapture(a: std.mem.Allocator, argv: []const []const u8, _: ?[]const u8) anyerror!providers.github.CmdCapture {
    const binary = if (argv.len >= 4 and std.mem.eql(u8, argv[1], "/d")) argv[3] else argv[0];
    const last = argv[argv.len - 1];
    var text: []const u8 = "";
    if (std.mem.eql(u8, last, "--version")) {
        text = if (std.mem.indexOf(u8, binary, "latest") != null) "codex-cli 0.159.2" else if (std.mem.indexOf(u8, binary, "alpha") != null) "codex-cli 0.130.0-alpha.5" else "codex-cli 0.144.4";
    } else if (std.mem.eql(u8, last, "models") or std.mem.eql(u8, last, "--verbose")) {
        if (std.mem.indexOf(u8, binary, "hang") != null) return error.Timeout;
        text = if (std.mem.indexOf(u8, binary, "broken") != null) "{invalid" else if (std.mem.indexOf(u8, binary, "opencode") != null) "opencode/gpt-6-luna\nopencode/claude-opus-5-5\n" else "{\"models\":[{\"slug\":\"gpt-6-luna\",\"display_name\":\"GPT-6-Luna\",\"supported_reasoning_levels\":[{\"effort\":\"high\"}]}]}";
    } else if (std.mem.eql(u8, last, "status")) {
        text = if (std.mem.indexOf(u8, binary, "claude") != null) "{\"authMethod\":\"api_key\"}" else "Logged in using ChatGPT";
    } else if (std.mem.eql(u8, last, "list")) text = "OpenCode Zen api — 1 credentials";
    return .{ .exit_code = 0, .stdout = try a.dupe(u8, text), .stderr = try a.dupe(u8, "") };
}

test "E5.B13 probes: selected handle prevents replacement between version models and session" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: rutas y CLIs externas de Windows; en Linux no hay descubrimiento de CLIs externas en esta version");
    const Fixture = struct {
        var calls: u8 = 0;
        var replaced: bool = false;
        extern "kernel32" fn GetLastError() u32;
        // Synthetic ACL seam only: real no-write/no-delete binary handle and
        // canonical ancestor handles, independent of shared sandbox grants.
        fn verify(a: std.mem.Allocator, path: []const u8) anyerror!cli_policy.VerifiedBinary {
            var root = try @import("confined_fs.zig").Root.init(a, std.fs.path.dirnameWindows(path).?);
            errdefer root.deinit();
            const z = try a.dupeZ(u8, path);
            defer a.free(z);
            const file = CreateFileA(z, 0x80020000, 1, null, 3, 0x80, null);
            if (file == INVALID_HANDLE_VALUE_T) return error.CliOpenFailed;
            errdefer _ = CloseHandle(file);
            return .{ .allocator = a, .path = try a.dupe(u8, path), .root = root, .file = file, .authenticode_code = 0 };
        }
        fn capture(a: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) anyerror!providers.github.CmdCapture {
            const path = if (argv.len >= 4 and std.mem.eql(u8, argv[1], "/d")) argv[3] else argv[0];
            const last = argv[argv.len - 1];
            calls |= if (std.mem.eql(u8, last, "--version")) @as(u8, 1) else if (std.mem.eql(u8, last, "models")) @as(u8, 2) else @as(u8, 4);
            const z = try a.dupeZ(u8, path);
            defer a.free(z);
            if (DeleteFileA(z) != 0) {
                replaced = true;
                const file = CreateFileA(z, GENERIC_WRITE_T, FILE_SHARE_READ_T, null, CREATE_NEW_T, FILE_ATTRIBUTE_NORMAL_T, null);
                if (file == INVALID_HANDLE_VALUE_T) return error.ShimWriteFailed;
                _ = CloseHandle(file);
            } else if (GetLastError() != 32) return error.ExpectedSharingViolation;
            const writer = CreateFileA(z, GENERIC_WRITE_T, FILE_SHARE_READ_T, null, 3, FILE_ATTRIBUTE_NORMAL_T, null);
            if (writer != INVALID_HANDLE_VALUE_T) {
                replaced = true;
                _ = CloseHandle(writer);
            } else if (GetLastError() != 32) return error.ExpectedSharingViolation;
            return fakeCatalogCapture(a, argv, cwd);
        }
    };
    const a = testing.allocator;
    Fixture.calls = 0;
    Fixture.replaced = false;
    var fx = try CliShimFixture.install(a, "codex");
    defer fx.uninstall(a);
    var detected = (try detectCandidatesWithVerifier(a, Fixture.capture, metaForCliId("codex").?, &.{fx.shim}, true, Fixture.verify)).?;
    defer detected.deinit(a);
    try testing.expectEqual(@as(u8, 7), Fixture.calls);
    try testing.expect(!Fixture.replaced);
    try testing.expectEqual(EnumerationStatus.enumerated, detected.enumeration_status);
    try testing.expectEqual(Session.suscripcion, detected.session);
    const z = try a.dupeZ(u8, fx.shim);
    defer a.free(z);
    // Once all probes return, the retained handle must be released.
    try testing.expect(DeleteFileA(z) != 0);
    std.debug.print("[E5.B13 probes] version/models/session: replacement and writing blocked; handle released after detection\n", .{});
}

test "Tanda 4: una CLI con todas sus instalaciones descartadas entrega los motivos al doctor" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const Fixture = struct {
        fn verify(_: std.mem.Allocator, _: []const u8) anyerror!cli_policy.VerifiedBinary {
            return error.UntrustedCliRoot;
        }
    };
    const a = testing.allocator;
    var fx = try CliShimFixture.install(a, "codex");
    defer fx.uninstall(a);
    var rejected: []Rejected = &.{};
    defer {
        for (rejected) |*r| r.deinit(a);
        if (rejected.len > 0) a.free(rejected);
    }
    try testing.expect((try detectCandidatesCollect(a, fakeCatalogCapture, metaForCliId("codex").?, &.{fx.shim}, false, Fixture.verify, &rejected)) == null);
    try testing.expectEqual(@as(usize, 1), rejected.len);
    try testing.expectEqualStrings(fx.shim, rejected[0].path);
    try testing.expectEqualStrings(cli_policy.rejectionReason(error.UntrustedCliRoot), rejected[0].reason);
    // Sin destino (la detección normal), nada cambia: null y sin fugas.
    try testing.expect((try detectCandidatesWithVerifier(a, fakeCatalogCapture, metaForCliId("codex").?, &.{fx.shim}, false, Fixture.verify)) == null);
}

test "E5.55 discovery chooses highest semver and carries subscription el segundo auditor with selected path" {
    const a = testing.allocator;
    var d = (try detectCandidatesImpl(a, fakeCatalogCapture, metaForCliId("codex").?, &.{ "C:\\npm\\codex.cmd", "C:\\app\\alpha\\codex.exe", "C:\\app\\latest\\codex.exe" }, false, false)).?;
    defer d.deinit(a);
    try testing.expectEqualStrings("C:\\app\\latest\\codex.exe", d.exe);
    try testing.expectEqualStrings("0.159.2", d.version.?);
    try testing.expectEqual(Session.suscripcion, d.session);
    try testing.expectEqual(EnumerationStatus.enumerated, d.enumeration_status);
    try testing.expectEqualStrings("gpt-6-luna", d.models[0].slug);
    try testing.expect(d.detected_at_ms > 1700000000000);
    const prefix = try spawnPrefixFor(a, try a.dupe(u8, d.exe));
    defer freeSpawnPrefix(a, prefix);
    try testing.expectEqualStrings(d.exe, prefix[0]);
    const json = try detectedJson(a, &.{d});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "GPT-6-Luna") != null);
    try testing.expect(std.mem.indexOf(u8, json, "tu suscripción") != null);
    try testing.expect(std.mem.indexOf(u8, json, "selection_reason") != null);
}

test "E5.55 malformed catalogs and hanging enumeration fail honestly" {
    const a = testing.allocator;
    var broken = (try detectCandidatesImpl(a, fakeCatalogCapture, metaForCliId("codex").?, &.{"C:\\broken\\codex.exe"}, true, false)).?;
    defer broken.deinit(a);
    try testing.expectEqual(EnumerationStatus.invalid_json, broken.enumeration_status);
    try testing.expectEqualStrings("default", broken.models[0].slug);
    var hung = (try detectCandidatesImpl(a, fakeCatalogCapture, metaForCliId("codex").?, &.{"C:\\hang\\codex.exe"}, true, false)).?;
    defer hung.deinit(a);
    try testing.expectEqual(EnumerationStatus.timeout, hung.enumeration_status);
    try testing.expect((try detectCandidatesImpl(a, fakeCatalogCapture, metaForCliId("codex").?, &.{}, false, false)) == null);
    try testing.expectError(error.InvalidExternalAgentPath, detectCandidatesImpl(a, fakeCatalogCapture, metaForCliId("codex").?, &.{"relative.exe"}, true, false));
    try testing.expectError(error.InvalidExternalAgentPath, spawnPrefixForPath(a, "C:\\evil&command.cmd"));
}

test "E5.55 forced paths and simulated states for all four CLIs" {
    const a = testing.allocator;
    const detected = try detectAllWithPathsImpl(a, fakeCatalogCapture, "{\"codex\":\"C:\\\\latest\\\\codex.exe\",\"claude-code\":\"C:\\\\claude.exe\",\"gemini-cli\":\"C:\\\\gemini.exe\",\"opencode\":\"C:\\\\opencode.exe\"}", false);
    defer {
        for (detected) |*d| d.deinit(a);
        a.free(detected);
    }
    try testing.expectEqual(@as(usize, 4), detected.len);
    try testing.expectEqual(Session.api_key, detected[0].session);
    try testing.expectEqual(Session.suscripcion, detected[1].session);
    try testing.expectEqual(Session.desconocida, detected[2].session);
    try testing.expectEqual(EnumerationStatus.no_enumerable, detected[2].enumeration_status);
    try testing.expectEqual(Session.api_key, detected[3].session);
    try testing.expectEqual(Manufacturer.openai, detected[3].models[0].manufacturer);
    try testing.expectEqual(Manufacturer.anthropic, detected[3].models[1].manufacturer);
    try testing.expectError(error.InvalidExternalAgentPaths, detectAllWithPathsImpl(a, fakeCatalogCapture, "[1]", false));
    try testing.expectError(error.InvalidExternalAgentPaths, detectAllWithPathsImpl(a, fakeCatalogCapture, "{\"unknown\":\"C:\\\\x.exe\"}", false));
    try testing.expectError(error.InvalidExternalAgentPaths, detectAllWithPathsImpl(a, fakeCatalogCapture, "{\"codex\":\"relative.exe\"}", false));
}

test "E5.55 audit veto follows manufacturer of new CLI models and gateways" {
    try testing.expect(crossModelManufacturerExcluded("agent:codex", "gpt-6-luna", "agent:codex", "gpt-6-astra"));
    try testing.expect(crossModelManufacturerExcluded("agent:codex", "gpt-6-luna", "agent:opencode", "opencode/gpt-6-sol"));
    try testing.expect(crossModelManufacturerExcluded("agent:opencode", "opencode/gpt-6-luna", "GPT", "gpt-6-astra"));
    try testing.expect(!crossModelManufacturerExcluded("agent:opencode", "opencode/claude-opus-5-5", "GPT", "gpt-6-astra"));
    try testing.expect(!crossModelManufacturerExcluded("agent:codex", "gpt-6-luna", "Cohere", "command-a"));
    try testing.expect(crossModelManufacturerExcluded("agent:opencode", "opencode/unknown", "GPT", "gpt-6-astra"));
    try testing.expect(crossModelManufacturerExcluded("GPT", "gpt-6-luna", "GPT", "gpt-6-astra"));
}

test "E5.55 discovery capture enforces deadline and output cap against real shim" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const a = testing.allocator;
    var fx = try CliShimFixture.install(a, "e555bounded");
    defer fx.uninstall(a);
    const prefix = try rawSpawnPrefix(a, fx.shim);
    defer freeSpawnPrefix(a, prefix);
    try testing.expectError(error.OutputLimitExceeded, discoveryCaptureWithLimits(a, prefix, null, 1000, 4));
    const shim_z = try a.dupeZ(u8, fx.shim);
    defer a.free(shim_z);
    const hf = CreateFileA(shim_z.ptr, GENERIC_WRITE_T, FILE_SHARE_READ_T, null, 3, FILE_ATTRIBUTE_NORMAL_T, null);
    if (hf == INVALID_HANDLE_VALUE_T) return error.ShimWriteFailed;
    const body = "@echo off\r\n:again\r\ngoto again\r\n";
    var written: u32 = 0;
    const ok = WriteFile(hf, body.ptr, body.len, &written, null);
    _ = CloseHandle(hf);
    if (ok == 0 or written != body.len) return error.ShimWriteFailed;
    const start = GetTickCount64();
    try testing.expectError(error.Timeout, discoveryCaptureWithLimits(a, prefix, null, 60, 128));
    try testing.expect(GetTickCount64() - start < 2000);
}

test "E5.B13 trust: UNC ADS traversal and device paths are rejected" {
    for ([_][]const u8{
        "\\\\server\\share\\codex.exe",
        "C:\\trusted\\codex.exe:planted.exe",
        "C:\\trusted\\..\\codex.exe",
        "\\\\?\\C:\\trusted\\codex.exe",
        "C:\\trusted\\codex.exe. ",
    }) |path| try testing.expect(!validBinaryPath(path));
}

test "E5.B13 trust: planted PATH candidate is not selected or probed" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: CLI externa (Codex, OpenCode, Claude, Gemini) no disponible en Linux en esta version (ExternalCliUnavailableOnLinux en external_cli_policy)");
    const Spy = struct {
        var calls: usize = 0;
        fn capture(a: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) anyerror!providers.github.CmdCapture {
            calls += 1;
            return fakeCatalogCapture(a, argv, cwd);
        }
    };
    const a = testing.allocator;
    var fx = try CliShimFixture.install(a, "e5b13planted");
    defer fx.uninstall(a);
    Spy.calls = 0;
    const picked = try detectCandidates(a, Spy.capture, metaForCliId("codex").?, &.{fx.shim}, false);
    defer if (picked) |value| {
        var d = value;
        d.deinit(a);
    };
    try testing.expect(picked == null);
    try testing.expectEqual(@as(usize, 0), Spy.calls);
    const resolved = try resolveCliExe(a, "e5b13planted");
    defer if (resolved) |p| a.free(p);
    try testing.expect(resolved == null);
}

test "USUARIO-NUEVO A1: ANTHROPIC_API_KEY del anfitrión no convierte la suscripción en facturación por API" {
    const Probe = struct {
        fn capture(a: std.mem.Allocator, argv: []const []const u8, _: ?[]const u8) anyerror!providers.github.CmdCapture {
            const last = argv[argv.len - 1];
            // Salidas reales de Claude Code 2.1.283 (10-nov), con el entorno limpio.
            const text: []const u8 = if (std.mem.eql(u8, last, "status"))
                "{\n  \"loggedIn\": true,\n  \"authMethod\": \"claude.ai\",\n  \"apiProvider\": \"firstParty\",\n  \"subscriptionType\": \"pro\"\n}"
            else if (std.mem.eql(u8, last, "--help"))
                "  --effort <level>                      Effort level for the current session\n                                        (low, medium, high, xhigh, max)\n  --model <model>                       Model for the current session. Provide\n                                        an alias for the latest model (e.g.\n                                        'fable', 'opus', or 'sonnet') or a\n                                        model's full name (e.g.\n                                        'claude-fable-5').\n  --name <name>  Session name\n"
            else
                "";
            return .{ .exit_code = 0, .stdout = try a.dupe(u8, text), .stderr = try a.dupe(u8, "") };
        }
    };
    const Presence = struct {
        fn present(name: [:0]const u8) bool {
            return std.mem.eql(u8, name, "ANTHROPIC_API_KEY");
        }
    };
    const a = testing.allocator;
    var d = try ownDetected(a, metaForCliId("claude-code").?, "C:\\synthetic\\claude.exe", try a.dupe(u8, "2.1.283"), false);
    defer d.deinit(a);
    try enrichDetectedWithPresence(a, Probe.capture, &d, Presence.present);
    try testing.expectEqual(Session.suscripcion, d.session);
    try testing.expectEqualStrings("ANTHROPIC_API_KEY", d.ignored_env.?);
    // A4: por defecto + los alias que declara la ayuda instalada, con sus esfuerzos.
    try testing.expectEqual(@as(usize, 4), d.models.len);
    try testing.expectEqualStrings("default", d.models[0].slug);
    try testing.expectEqualStrings("fable", d.models[1].slug);
    try testing.expectEqualStrings("opus", d.models[2].slug);
    try testing.expectEqualStrings("sonnet", d.models[3].slug);
    try testing.expectEqual(@as(usize, 5), d.models[3].reasoning_efforts.len);
    const json = try detectedJson(a, &.{d});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "Claude Code (tu suscripción · se ignora ANTHROPIC_API_KEY del entorno)") != null);
}

test "USUARIO-NUEVO A2: la detección dice qué otras instalaciones encontró y por qué no las eligió" {
    const Probe = struct {
        fn capture(a: std.mem.Allocator, argv: []const []const u8, _: ?[]const u8) anyerror!providers.github.CmdCapture {
            const last = argv[argv.len - 1];
            var exe: []const u8 = argv[0];
            for (argv) |part| if (std.ascii.endsWithIgnoreCase(part, ".cmd") or std.ascii.endsWithIgnoreCase(part, ".exe")) {
                exe = part;
            };
            const text: []const u8 = if (std.mem.eql(u8, last, "--version"))
                (if (std.mem.indexOf(u8, exe, "npm") != null) "2.1.114 (Claude Code)" else "2.1.283 (Claude Code)")
            else
                "";
            return .{ .exit_code = 0, .stdout = try a.dupe(u8, text), .stderr = try a.dupe(u8, "") };
        }
    };
    const a = testing.allocator;
    // npm (más antigua), la nativa (elegida) y una copia con la misma versión.
    const paths = [_][]const u8{ "C:\\synthetic\\npm\\claude.cmd", "C:\\synthetic\\.local\\bin\\claude.exe", "C:\\synthetic\\copia\\claude.exe" };
    var d = (try detectCandidatesWithVerifier(a, Probe.capture, metaForCliId("claude-code").?, &paths, false, null)).?;
    defer d.deinit(a);
    try testing.expectEqualStrings("C:\\synthetic\\.local\\bin\\claude.exe", d.exe);
    try testing.expectEqual(@as(usize, 2), d.rejected.len);
    try testing.expectEqualStrings("C:\\synthetic\\npm\\claude.cmd", d.rejected[0].path);
    try testing.expectEqualStrings("2.1.114", d.rejected[0].version.?);
    try testing.expectEqualStrings("versión más antigua que la elegida", d.rejected[0].reason);
    try testing.expectEqualStrings("C:\\synthetic\\copia\\claude.exe", d.rejected[1].path);
    try testing.expectEqualStrings("2.1.283", d.rejected[1].version.?);
    try testing.expectEqualStrings("versión igual o más antigua que la elegida", d.rejected[1].reason);
    const json = try detectedJson(a, &.{d});
    defer a.free(json);
    try testing.expect(std.mem.indexOf(u8, json, "\"rejected\":[{\"path\":\"C:\\\\synthetic\\\\npm\\\\claude.cmd\",\"version\":\"2.1.114\",\"reason\":\"versión más antigua que la elegida\"}") != null);
}

test "E5.B13 RELOJ billing: parent CODEX_API_KEY does not reach Codex discovery" {
    const Presence = struct {
        fn present(name: [:0]const u8) bool {
            return std.mem.eql(u8, name, "CODEX_API_KEY");
        }
    };
    const a = testing.allocator;
    var d = try ownDetected(a, metaForCliId("codex").?, "C:\\synthetic\\codex.exe", try a.dupe(u8, "0.159.2"), false);
    defer d.deinit(a);
    try enrichDetectedWithPresence(a, fakeCatalogCapture, &d, Presence.present);
    try testing.expectEqual(Session.suscripcion, d.session);
    try testing.expectEqual(EnumerationStatus.enumerated, d.enumeration_status);
}

test "SEC2 external npm: cadena retenida y spawn directo conservan prompt hostil" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const npm = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "npm", .{base});
    defer a.free(npm);
    try cli_policy.createPrivateDirectory(a, npm);
    try tmp.dir.createDirPath(io, "npm\\node_modules");
    const bin = (try cli_policy.getEnv(a, "BEATS_TEST_BIN_DIR")) orelse return error.TestBinDirectoryMissing;
    defer a.free(bin);
    const source = try std.fs.path.join(a, &.{ bin, "cli-worker-mock" ++ comptime @import("builtin").target.exeFileExt() });
    defer a.free(source);
    const node = try std.fs.path.join(a, &.{ npm, "node" ++ comptime @import("builtin").target.exeFileExt() });
    defer a.free(node);
    try std.Io.Dir.copyFileAbsolute(source, node, io, .{});
    try tmp.dir.writeFile(io, .{ .sub_path = "npm\\node_modules\\fixture.js", .data = "// Fixture de argv y stdin.\n" });
    const shim_body =
        "@ECHO off\nGOTO start\n:find_dp0\nSET dp0=%~dp0\nEXIT /b\n:start\nSETLOCAL\nCALL :find_dp0\n\n" ++
        "IF EXIST \"%dp0%\\node.exe\" (\n  SET \"_prog=%dp0%\\node.exe\"\n) ELSE (\n  SET \"_prog=node\"\n  SET PATHEXT=%PATHEXT:;.JS;=;%\n)\n\n" ++
        "endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & \"%_prog%\"  \"%dp0%\\node_modules\\fixture.js\" %*\n";
    try tmp.dir.writeFile(io, .{ .sub_path = "npm\\fixture.cmd", .data = shim_body });
    const shim = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "fixture.cmd", .{npm});
    defer a.free(shim);
    const old_appdata = try cli_policy.getEnv(a, "APPDATA");
    defer if (old_appdata) |value| a.free(value);
    const old_z = if (old_appdata) |value| try a.dupeZ(u8, value) else null;
    defer if (old_z) |value| a.free(value);
    const base_z = try a.dupeZ(u8, base);
    defer a.free(base_z);
    if (SetEnvironmentVariableA("APPDATA", base_z) == 0) return error.TestEnvironmentFailed;
    defer _ = SetEnvironmentVariableA("APPDATA", if (old_z) |value| value.ptr else null);
    // No reconocer contenido truncado ni rechazar un batch legítimo por tamaño.
    const large_body = try a.alloc(u8, 16385);
    defer a.free(large_body);
    @memset(large_body, ' ');
    try tmp.dir.writeFile(io, .{ .sub_path = "npm\\large.cmd", .data = large_body });
    const large_path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "large.cmd", .{npm});
    defer a.free(large_path);
    var large_launch = try executor.prepareBatchLaunch(a, large_path);
    defer large_launch.deinit(a);
    try testing.expectEqualStrings(large_path, large_launch.exe);
    try testing.expect(large_launch.node == null and large_launch.script == null);
    try testing.expectEqual(@as(usize, 0), large_launch.prefix.len);
    var launch = try executor.prepareBatchLaunch(a, shim);
    defer launch.deinit(a);
    try testing.expect(launch.shim != null and launch.node != null and launch.script != null);
    try testing.expectEqualStrings(node, launch.exe);
    try testing.expectEqual(@as(usize, 1), launch.prefix.len);
    const pre = try copyLaunchPrefix(a, &launch);
    defer freeSpawnPrefix(a, pre);
    try testing.expect(!std.ascii.eqlIgnoreCase(executor.basename(pre[0]), "cmd.exe"));
    const args = [_][]const u8{ pre[0], pre[1], "--headless", "echo-stdin", "& echo injected > marker.txt" };
    var worker = @import("cli_worker.zig").ExternalCliWorker.init(a, io, &args, 15000);
    worker.cwd = base;
    worker.stdin_mode = .prompt_text;
    const prompt = "& | ^ %PATH% ! < > ( ) \"\r\nsegunda línea\n";
    const task: planner.PlannedTask = .{ .id = "SEC2-npm", .task_type = .programar_c, .department = "programacion", .description = prompt, .contract_fields = &.{}, .depends_on = &.{} };
    var result = try worker.runCollect(a, task);
    defer result.deinit(a);
    try testing.expectEqual(@as(?u8, 0), result.exit_code);
    try testing.expect(!result.timed_out and !result.truncated);
    var echoed = try std.json.parseFromSlice([]const u8, a, result.output, .{});
    defer echoed.deinit();
    try testing.expectEqualStrings(prompt, echoed.value);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "marker.txt", .{}));

    // La ruta detached también resuelve npm y conserva argv nativo/Unicode.
    try tmp.dir.writeFile(io, .{ .sub_path = "npm\\npm.cmd", .data = shim_body });
    const old_path = try cli_policy.getEnv(a, "PATH");
    defer if (old_path) |value| a.free(value);
    const old_path_z = if (old_path) |value| try a.dupeZ(u8, value) else null;
    defer if (old_path_z) |value| a.free(value);
    const npm_z = try a.dupeZ(u8, npm);
    defer a.free(npm_z);
    if (SetEnvironmentVariableA("PATH", npm_z) == 0) return error.TestEnvironmentFailed;
    defer _ = SetEnvironmentVariableA("PATH", if (old_path_z) |value| value.ptr else null);
    const detached_args = &[_][]const u8{ "--record-argv", "detached-argv.json", "& | ^ %PATH% ! < > ( ) \"\r\n中文", "" };
    const detached = try executor.runDetached(a, .{ .workspace_root = base }, "npm", detached_args, base);
    const Api = struct {
        extern "kernel32" fn OpenProcess(u32, c_int, u32) callconv(.winapi) std.os.windows.HANDLE;
        extern "kernel32" fn WaitForSingleObject(std.os.windows.HANDLE, u32) callconv(.winapi) u32;
        extern "kernel32" fn TerminateProcess(std.os.windows.HANDLE, u32) callconv(.winapi) c_int;
        extern "kernel32" fn CloseHandle(std.os.windows.HANDLE) callconv(.winapi) c_int;
        extern "kernel32" fn Sleep(u32) callconv(.winapi) void;
    };
    const child = Api.OpenProcess(0x100001, 0, detached.pid);
    if (@intFromPtr(child) != 0) {
        defer _ = Api.CloseHandle(child);
        if (Api.WaitForSingleObject(child, 15000) != 0) {
            _ = Api.TerminateProcess(child, 1);
            _ = Api.WaitForSingleObject(child, 5000);
            return error.TestDetachedTimeout;
        }
    }
    const recorded = try tmp.dir.readFileAlloc(io, "detached-argv.json", a, .limited(8192));
    defer a.free(recorded);
    var actual = try std.json.parseFromSlice([][]const u8, a, recorded, .{});
    defer actual.deinit();
    try testing.expectEqual(detached_args.len + 1, actual.value.len);
    try testing.expectEqualStrings(launch.prefix[0], actual.value[0]);
    for (detached_args, actual.value[1..]) |expected, value| try testing.expectEqualStrings(expected, value);
    try testing.expectError(error.FileNotFound, tmp.dir.access(io, "marker.txt", .{}));
    // El shim sólo se puede retirar cuando el observador cerró toda la cadena.
    var released = false;
    for (0..500) |_| {
        tmp.dir.deleteFile(io, "npm\\npm.cmd") catch |e| {
            if (e != error.AccessDenied and e != error.FileBusy) return e;
            Api.Sleep(10);
            continue;
        };
        released = true;
        break;
    }
    try testing.expect(released);
}

test "SEC2 external dispatch prefix uses retained launch without resolving again" {
    const a = testing.allocator;
    const exe = try a.dupeZ(u8, "C:\\retained\\node.exe");
    defer a.free(exe);
    var prefix = [_][]const u8{"C:\\retained\\node_modules\\cli.js"};
    // Fixture prestado: rutas inexistentes prueban que copiar el launch no
    // consulta PATH ni abre una cadena distinta; no posee handles de confianza.
    const launch: executor.BatchLaunch = .{ .exe = exe, .prefix = &prefix };
    const copied = try copyLaunchPrefix(a, &launch);
    defer freeSpawnPrefix(a, copied);
    try testing.expectEqual(@as(usize, 2), copied.len);
    try testing.expectEqualStrings(exe, copied[0]);
    try testing.expectEqualStrings(prefix[0], copied[1]);
    try testing.expect(copied[0].ptr != launch.exe.ptr);
    try testing.expect(copied[1].ptr != launch.prefix[0].ptr);
}
