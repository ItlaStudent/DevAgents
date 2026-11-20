const std = @import("std");
const core = @import("core");
const is_windows = @import("builtin").os.tag == .windows;
// T9: fuera de Windows los relojes, el entorno y el azar salen de la capa de
// plataforma del motor; el resto de llamadas Win32 tiene su rama POSIX abajo.
const Sleep = if (is_windows) struct {
    extern "kernel32" fn Sleep(dwMilliseconds: u32) callconv(.winapi) void;
}.Sleep else core.platform.sleep;

// MCP is an engine process: its listener uses the same C-ABI handle as its tools.
const RemoteSession = struct {
    server: core.remote_server.Server,
    thread: ?std.Thread = null,
    origin: ?[]u8 = null,
    failed: std.atomic.Value(bool) = .init(false),

    fn run(self: *RemoteSession) void {
        self.server.serve() catch |failure| {
            self.failed.store(true, .release);
            std.debug.print("remote engine stopped: {s}\n", .{@errorName(failure)});
        };
    }

    fn stop(self: *RemoteSession, allocator: std.mem.Allocator) void {
        self.server.requestStop();
        if (self.thread) |thread| thread.join();
        self.server.deinit();
        if (self.origin) |origin| allocator.free(origin);
        allocator.destroy(self);
    }
};

test "E5.30 MCP remote lifecycle default off and invalid configuration" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true;
    const off = try processRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"remote_status\",\"arguments\":{}}}", &ctx);
    defer if (off) |response| allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, off.?, "false") != null);
    for ([_][]const u8{
        "{\"bind\":\"0.0.0.0\"}",                   "{\"port\":-1}",    "{\"port\":65536}",
        "{\"port\":\"bad\"}",                       "{\"bind\":false}", "{\"origin\":false}",
        "{\"origin\":\"https://evil\\n.invalid\"}",
    }) |arguments| {
        const request = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"remote_start\",\"arguments\":{s}}}}}", .{arguments});
        defer allocator.free(request);
        const response = try processRequest(allocator, request, &ctx);
        defer if (response) |value| allocator.free(value);
        try std.testing.expect(std.mem.indexOf(u8, response.?, "isError\":true") != null or std.mem.indexOf(u8, response.?, "-32602") != null);
        try std.testing.expect(ctx.remote_session == null);
    }
    const started = try processRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"remote_start\",\"arguments\":{}}}", &ctx);
    defer if (started) |response| allocator.free(response);
    // e5-harden punto 8: MCP no abre el listener ni devuelve el token.
    try std.testing.expect(ctx.remote_session == null);
    try std.testing.expect(std.mem.indexOf(u8, started.?, "isError\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, started.?, "inicia el acceso remoto allí") != null);
    try std.testing.expect(std.mem.indexOf(u8, started.?, "token\\\":") == null);
    const duplicate = try processRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"remote_start\",\"arguments\":{}}}", &ctx);
    defer if (duplicate) |response| allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, duplicate.?, "isError\":true") != null);
    const status = try processRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"remote_status\",\"arguments\":{}}}", &ctx);
    defer if (status) |response| allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, status.?, "token") == null);
    for (0..2) |_| {
        const stopped = try processRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"remote_stop\",\"arguments\":{}}}", &ctx);
        defer if (stopped) |response| allocator.free(response);
        try std.testing.expect(ctx.remote_session == null);
    }
}

test "E5.30 MCP remote start and stop require authentication" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = false;
    for ([_][]const u8{ "remote_start", "remote_stop" }) |name| {
        const request = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{{}}}}}}", .{name});
        defer allocator.free(request);
        const response = try processRequest(allocator, request, &ctx);
        defer if (response) |value| allocator.free(value);
        try std.testing.expect(std.mem.indexOf(u8, response.?, "autenticacion requerida") != null);
        try std.testing.expect(ctx.remote_session == null);
    }
}

test "HARD10. MCP token comparison rejects prefix suffix length and missing" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.releaseToken(null);
    try std.testing.expect(!ctx.checkToken("fixture-a"));
    ctx.expected_token = try a.dupe(u8, "fixture-a");
    try std.testing.expect(ctx.checkToken("fixture-a"));
    for ([_][]const u8{ "fixture-b", "xixture-a", "fixture", "fixture-aa", "" }) |token| try std.testing.expect(!ctx.checkToken(token));
}

test "HARD10. MCP owned token erased before allocator releases storage" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.releaseToken(null);
    ctx.expected_token = try a.dupe(u8, "fixture-a");
    const Observation = struct {
        called: bool = false,
        zero: bool = false,
        fn observe(context: *anyopaque, token: []const u8) void {
            const observation: *@This() = @ptrCast(@alignCast(context));
            observation.called = true;
            observation.zero = token.len == 9 and std.mem.allEqual(u8, token, 0);
        }
    };
    var observation: Observation = .{};
    ctx.releaseToken(.{ .context = &observation, .observe = Observation.observe });
    try std.testing.expect(observation.called);
    try std.testing.expect(observation.zero);
    try std.testing.expect(ctx.expected_token == null);
}

test "HARD10. escaped JSON tokens erased on initialize authenticate and parse error" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.releaseToken(null);
    ctx.expected_token = try a.dupe(u8, "fixture-a");
    const Observation = struct {
        frees: usize = 0,
        all_zero: bool = true,
        fn observe(context: *anyopaque, memory: []const u8) void {
            const observation: *@This() = @ptrCast(@alignCast(context));
            observation.frees += 1;
            observation.all_zero = observation.all_zero and std.mem.allEqual(u8, memory, 0);
        }
    };
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"token\":\"fixture-\\u0061\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"authenticate\",\"arguments\":{\"token\":\"fixture-\\u0061\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"authenticate\",\"arguments\":{\"token\":\"fixture-\\u0062\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"initialize\",\"params\":{\"token\":\"fixture-\\u0061\"},\"invalid\":",
    }, 0..) |request, i| {
        ctx.authed = false;
        var observation: Observation = .{};
        const response = (try processRequestWithParserObserver(a, request, &ctx, .{ .context = &observation, .observe = Observation.observe })) orelse return error.MissingResponse;
        defer a.free(response);
        try std.testing.expect(observation.frees > 0);
        try std.testing.expect(observation.all_zero);
        try std.testing.expectEqual(i < 2, ctx.authed);
        if (i == 2) try std.testing.expect(std.mem.indexOf(u8, response, "token invalido") != null);
        if (i == 3) try std.testing.expect(std.mem.indexOf(u8, response, "-32700") != null);
    }
}

test "E5.30 MCP requests serialize with the remote engine mutex" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true;
    const Worker = struct {
        ctx: *ServerCtx,
        entered: std.atomic.Value(bool) = .init(false),
        finished: std.atomic.Value(bool) = .init(false),
        response: ?[]u8 = null,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.entered.store(true, .release);
            self.response = processRequest(std.testing.allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"webhooks_list\",\"arguments\":{}}}", self.ctx) catch |failure| {
                self.failure = failure;
                self.finished.store(true, .release);
                return;
            };
            self.finished.store(true, .release);
        }
    };
    var worker = Worker{ .ctx = &ctx };
    ctx.remote_mutex.lock();
    const thread = std.Thread.spawn(.{}, Worker.run, .{&worker}) catch |failure| {
        ctx.remote_mutex.unlock();
        return failure;
    };
    var waited: u32 = 0;
    while (!worker.entered.load(.acquire) and waited < 1000) : (waited += 1) Sleep(1);
    Sleep(50);
    const blocked = worker.entered.load(.acquire) and !worker.finished.load(.acquire);
    ctx.remote_mutex.unlock();
    thread.join();
    defer if (worker.response) |response| allocator.free(response);
    try std.testing.expect(blocked);
    if (worker.failure) |failure| return failure;
    try std.testing.expect(worker.finished.load(.acquire));
    try std.testing.expect(worker.response != null);
}

// T12 A1: el proceso MCP ya no captura la pantalla por su cuenta (se retiró la
// captura GDI propia). La pantalla solo se captura en la cabina, tras la
// aprobación humana que registra da_capture_screenshot (screen_capture).
const GetTickCount64 = if (is_windows) struct {
    extern "kernel32" fn GetTickCount64() u64;
}.GetTickCount64 else core.platform.ticks;
extern "kernel32" fn CreateFileA(lpFileName: [*:0]const u8, dwDesiredAccess: u32, dwShareMode: u32, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: u32, dwFlagsAndAttributes: u32, hTemplateFile: ?*anyopaque) ?*anyopaque;
extern "kernel32" fn WriteFile(hFile: ?*anyopaque, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque) c_int;
extern "kernel32" fn CloseHandle(hObject: ?*anyopaque) c_int;
const GetEnvironmentVariableA = if (is_windows) struct {
    extern "kernel32" fn GetEnvironmentVariableA(lpName: [*:0]const u8, lpBuffer: ?[*]u8, nSize: u32) u32;
}.GetEnvironmentVariableA else core.platform.env;
// las pruebas hermeticas fijan DEVAGENTS_WORKSPACE_ROOT antes de
// ServerCtx.init (unica via que el humano tiene para elegir raiz; el test la
// restaura al terminar).
const SetEnvironmentVariableA = if (is_windows) struct {
    extern "kernel32" fn SetEnvironmentVariableA(lpName: [*:0]const u8, lpValue: ?[*:0]const u8) c_int;
}.SetEnvironmentVariableA else core.platform.files.SetEnvironmentVariableA;
extern "kernel32" fn GetFileSize(hFile: ?*anyopaque, lpFileSizeHigh: ?*u32) u32;
extern "kernel32" fn ReadFile(hFile: ?*anyopaque, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: ?*u32, lpOverlapped: ?*anyopaque) c_int;
const BCryptGenRandom = if (is_windows) struct {
    extern "bcrypt" fn BCryptGenRandom(hAlgorithm: ?*anyopaque, pbBuffer: [*]u8, cbBuffer: u32, dwFlags: u32) callconv(.winapi) i32;
}.BCryptGenRandom else core.platform.random;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;

fn tokenDiagnostic(comptime source: std.builtin.SourceLocation, operation: []const u8, code: u32) void {
    std.debug.print("devagents-mcp: {s}:{d} {s}: Win32={d} GetLastError={d}\n", .{ source.file, source.line, operation, code, GetLastError() });
}

extern "kernel32" fn GetCurrentProcess() callconv(.winapi) ?*anyopaque;
extern "kernel32" fn LocalFree(memory: ?*anyopaque) callconv(.winapi) ?*anyopaque;
extern "advapi32" fn OpenProcessToken(process: ?*anyopaque, access: u32, token: *?*anyopaque) callconv(.winapi) c_int;
extern "advapi32" fn GetTokenInformation(token: ?*anyopaque, info_class: u32, info: ?*anyopaque, size: u32, needed: *u32) callconv(.winapi) c_int;
extern "advapi32" fn ConvertSidToStringSidA(sid: ?*anyopaque, text: *?[*:0]u8) callconv(.winapi) c_int;
extern "advapi32" fn ConvertStringSecurityDescriptorToSecurityDescriptorA(text: [*:0]const u8, revision: u32, descriptor: *?*anyopaque, size: ?*u32) callconv(.winapi) c_int;
extern "advapi32" fn GetSecurityDescriptorDacl(descriptor: ?*anyopaque, present: *c_int, dacl: *?*anyopaque, defaulted: *c_int) callconv(.winapi) c_int;
extern "advapi32" fn SetSecurityInfo(handle: ?*anyopaque, object_type: u32, info: u32, owner: ?*anyopaque, group: ?*anyopaque, dacl: ?*anyopaque, sacl: ?*anyopaque) callconv(.winapi) u32;

const TokenSecurityAttributes = extern struct {
    length: u32 = @sizeOf(TokenSecurityAttributes),
    descriptor: ?*anyopaque,
    inherit: c_int = 0,
};

/// Servidor MCP (Model Context Protocol) sobre stdio para DevAgents.
/// Protocolo: JSON-RPC 2.0 line-delimited por stdin/stdout.
/// Carga el nucleo via C-ABI (`da_*`) y expone herramientas de lectura y accion.
///
/// Tools de LECTURA (read-only):
///   health, catalog_info, router_candidates, sessions, order_status,
///   order_events, get_plan, approvals_list
///
/// Tools de ACCION (mutan estado o ejecutan):
///   da_submit_order, confirm_plan, shell_run, approvals_resolve
///
/// Seguridad:
///   * shell_run delega 100 % en `da_shell_run` (misma allowlist + sandbox +
///     escaner de .db/destructivo del core).
///   * Ninguna tool expone claves API ni permite navegacion/ejecucion arbitraria.
///   * confirm_plan requiere un plan existente.
///
/// Uso: `devagents-mcp` (sin argumentos). El cliente MCP lanza el binario y habla
///        stdio JSON-RPC.
pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    const in = std.Io.File.stdin();
    const out = std.Io.File.stdout();
    // E5.23: cuatro imágenes base64 de 5 MiB caben, con cota dura.
    const in_buf = try allocator.alloc(u8, 28 * 1024 * 1024);
    defer allocator.free(in_buf);
    var out_buf: [32768]u8 = undefined;
    var reader = in.readerStreaming(io, in_buf);
    var writer = out.writerStreaming(io, &out_buf);

    // Parse --db <path> or --data-dir <dir> from argv.
    // --data-dir sets the directory where runtime.db / catalog.db live.
    // la carpeta de datos NO se resuelve aqui a mano: se delega en
    // core.paths.resolveDataDir (la unica funcion, mismo orden que la CLI y la
    // cabina). --db sigue mandando sobre la carpeta por defecto.
    var db_path: []const u8 = "runtime.db";
    var explicit_db: ?[]const u8 = null;
    var data_dir_arg: ?[]const u8 = null;
    var args_iter = try std.process.Args.Iterator.initAllocator(init.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.skip(); // skip argv[0]
    while (args_iter.next()) |arg| {
        if (std.mem.eql(u8, arg, "--db")) {
            if (args_iter.next()) |val| {
                db_path = val;
                explicit_db = val;
            }
        } else if (std.mem.eql(u8, arg, "--data-dir")) {
            if (args_iter.next()) |val| {
                data_dir_arg = val;
            }
        }
    }
    // UNA sola resolución de la carpeta de datos y un orden único
    // documentado: --data-dir > BEATS_DATA_DIR > DEVAGENTS_DATA_DIR (alias) >
    // carpeta por defecto (API de carpetas conocidas, igual que la cabina).
    // Un override inútil es fallo cerrado con mensaje claro: nunca se abre una
    // base relativa ni la real por accidente.
    const resolved = core.paths.resolveDataDir(allocator, data_dir_arg) catch |err| {
        std.debug.print("devagents-mcp: carpeta de datos no valida ({s}); BEATS_DATA_DIR/DEVAGENTS_DATA_DIR debe ser una ruta absoluta y existente\n", .{@errorName(err)});
        return err;
    };
    // La carpeta manda sobre --db salvo cuando --db venia solo (se conserva el
    // comportamiento anterior: `--db :memory:` y `--db ruta` siguen intactos).
    const carpeta_manda = data_dir_arg != null or resolved.source != .default_known_folders or explicit_db == null;
    // owned_db_path: la ruta unica de base construida desde la carpeta resuelta.
    var owned_db_path: ?[]u8 = null;
    defer if (owned_db_path) |p| allocator.free(p);
    if (carpeta_manda) {
        owned_db_path = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "runtime.db", .{resolved.dir});
        db_path = owned_db_path.?;
    }
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);

    // QA-B H11: sin detección de CLIs al arrancar; si no, cerrar la entrada
    // esperaba 13-16 s a que terminara (ver c_api.startup_external_detection).
    core.c_api.startup_external_detection = false;
    var ctx = try ServerCtx.init(allocator, io, db_path_z);
    defer ctx.deinit();
    // C3: capabilities informa la carpeta REAL abierta, nunca «(cwd default)».
    ctx.data_dir = if (carpeta_manda) resolved.dir else std.fs.path.dirname(db_path);

    while (true) {
        const maybe = reader.interface.takeDelimiter('\n') catch |e| switch (e) {
            // /E5.23: una línea >28 MiB no mata la sesión. Tras StreamTooLong el
            // stream queda intacto: se drena el resto de la línea hasta el '\n'
            // y se responde -32700 — el cliente ve un error por-request, no un
            // servidor muerto.
            error.StreamTooLong => {
                drainOverlongLine(&reader.interface) catch break;
                const err_json = try buildErrorResp(allocator, 0, -32700, "parse error: request line exceeds buffer");
                defer allocator.free(err_json);
                writer.interface.writeAll(err_json) catch break;
                writer.interface.writeByte('\n') catch break;
                writer.flush() catch break;
                continue;
            },
            error.ReadFailed => break,
        };
        const line = maybe orelse break;
        var trimmed = line;
        if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\r') trimmed = trimmed[0 .. trimmed.len - 1];
        if (trimmed.len == 0) continue;

        const resp = processRequest(allocator, trimmed, &ctx) catch |e| {
            const msg = try std.fmt.allocPrint(allocator, "internal error: {s}", .{@errorName(e)});
            defer allocator.free(msg);
            const err_json = try buildErrorResp(allocator, 0, -32603, msg);
            defer allocator.free(err_json);
            writer.interface.writeAll(err_json) catch break;
            writer.interface.writeByte('\n') catch break;
            writer.flush() catch break;
            continue;
        };
        defer if (resp) |r| allocator.free(r);
        if (resp) |r| {
            writer.interface.writeAll(r) catch break;
            writer.interface.writeByte('\n') catch break;
            writer.flush() catch break;
        }
    }
}

/// /E5.23: tras `error.StreamTooLong` del lector de líneas, drena el resto
/// de la línea hasta el `'\n'` (a un `Writer.Discarding`) y deja el stream
/// listo para la siguiente petición. Es la guarda que impide que una línea
/// mayor que el buffer del lector mate la sesión: sin el drenado el stream
/// queda a mitad de línea y el siguiente `takeDelimiter` vuelve a desbordar.
/// `peekDelimiterExclusive` garantiza el stream intacto tras `StreamTooLong`.
fn drainOverlongLine(reader: *std.Io.Reader) !void {
    var discard_buf: [4096]u8 = undefined;
    var discarding = std.Io.Writer.Discarding.init(&discard_buf);
    _ = try reader.streamDelimiterEnding(&discarding.writer, '\n');
}

// ---------------------------------------------------------------------------
// Estado del servidor
// ---------------------------------------------------------------------------

const ServerCtx = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    core_handle: ?*anyopaque,
    next_id: i64,
    data_dir: ?[]const u8,
    /// MCP-AUTH: token que el cliente debe presentar para tools privilegiadas.
    /// Resuelto desde env DEVAGENTS_MCP_TOKEN o el archivo `mcp_token` junto a
    /// la runtime.db. Null solo si ni env ni archivo ni generación pudieron.
    expected_token: ?[]const u8,
    /// Sesión autenticada (env presente, initialize con token, o authenticate).
    authed: bool,
    /// T12B B-2: origen de esta sesión (hash SHA-256 de token e identidad
    /// del cliente). Se pasa al núcleo con
    /// da_set_mcp_session y se escribe en las tarjetas de spaces, para que la
    /// propiedad sobreviva a reiniciar el proceso.
    session_tag: ?[]const u8 = null,
    /// T7: versión del protocolo MCP negociada en `initialize` (una de
    /// SUPPORTED_PROTOCOL_VERSIONS). Antes de initialize vale la más antigua,
    /// que es el comportamiento histórico del servidor.
    protocol_version: []const u8 = PROTOCOL_2024_11_05,
    remote_session: ?*RemoteSession = null,
    remote_mutex: core.sync.Mutex = .init(),
    /// r3: base de runtime EFECTIVA del núcleo abierta por
    /// da_core_init (con fallback ":memory:"). La conexión propia de
    /// aprobaciones de spaces se abre sobre la MISMA base para compartir la
    /// tabla approvals con el proceso que la resuelve (la cabina). Copia de
    /// propiedad del servidor; se libera en deinit.
    db_path: ?[]u8 = null,
    /// r3: conexión propia (perezosa) a la tabla approvals
    /// compartida. Se abre a demanda en la primera solicitud de spaces y
    /// permanece abierta hasta deinit.
    approvals_db: ?core.db.Connection = null,
    /// F0.7: respuesta de tools/list ya parseada; `validateToolArgs` valida
    /// cada tools/call contra el inputSchema de su tool. Se libera en deinit.
    tool_schemas: std.json.Parsed(std.json.Value),

    /// `db_path` selecciona la BD de runtime (y, vía hermano, el catalog.db). El
    /// servidor real pasa "runtime.db" (anclado a la raíz del proyecto → catalog.db
    /// real con claves DPAPI). Los tests pasan ":memory:" para ser HERMÉTICOS: con
    /// ":memory:" el catálogo hermano también es ":memory:" (vacío, sin claves), así
    /// que la planificación/despacho caen al MockPlanner/MockWorker y NO hacen red.
    fn init(allocator: std.mem.Allocator, io: std.Io, db_path: [*:0]const u8) !ServerCtx {
        // F0.7: una sola fuente de verdad; se validan los MISMOS esquemas que
        // publica tools/list.
        const list = try buildToolsListResp(allocator, 0);
        defer allocator.free(list);
        var schemas = try std.json.parseFromSlice(std.json.Value, allocator, list, .{ .allocate = .alloc_always });
        errdefer schemas.deinit();
        var ctx = ServerCtx{
            .tool_schemas = schemas,
            .allocator = allocator,
            .io = io,
            .core_handle = null,
            .next_id = 1,
            .data_dir = null,
            .expected_token = null,
            .authed = false,
        };
        errdefer if (ctx.expected_token) |token| allocator.free(token);
        errdefer if (ctx.db_path) |p| allocator.free(p);
        // Resolve before core init, which also ensures mcp_token. The MCP's
        // generated file must be private from the moment it is created.
        ctx.resolveAuthToken(std.mem.span(db_path));
        var handle: ?*anyopaque = null;
        var rc = core.c_api.da_core_init(&handle, db_path);
        db_found: {
            if (rc == 0) {
                ctx.db_path = allocator.dupe(u8, std.mem.span(db_path)) catch null;
                break :db_found;
            }
            rc = core.c_api.da_core_init(&handle, ":memory:");
            if (rc != 0) return error.CoreInitFailed;
            ctx.db_path = allocator.dupe(u8, ":memory:") catch null;
            std.debug.print("devagents-mcp: fallback a base en memoria para approvals de spaces\n", .{});
        }
        ctx.core_handle = handle;
        errdefer _ = core.c_api.da_core_shutdown(handle);
        // La raiz que elige quien LANZA el servidor (como el token) es voluntad humana;
        // se aplica antes de marcar la superficie MCP, que ya solo puede estrecharla.
        var rootbuf: [1024]u8 = undefined;
        const rn = GetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", &rootbuf, rootbuf.len);
        if (rn > 0 and rn < rootbuf.len) {
            rootbuf[rn] = 0;
            if (core.c_api.da_set_workspace_root(handle, @ptrCast(&rootbuf)) != 0) {
                std.debug.print("devagents-mcp: DEVAGENTS_WORKSPACE_ROOT rechazado; se conserva la raiz por defecto\n", .{});
            }
        }
        _ = core.c_api.da_set_mcp_surface(handle);
        var session_buf: [256]u8 = undefined;
        const session_len = GetEnvironmentVariableA("DEVAGENTS_MCP_SESSION_ID", &session_buf, session_buf.len);
        if (session_len >= session_buf.len) return error.InvalidMcpSessionId;
        try ctx.installSessionTag(handle, if (session_len > 0) session_buf[0..session_len] else null);
        return ctx;
    }

    /// T12B: un token autoriza varios clientes, no identifica una sesión.
    /// El lanzador puede fijar DEVAGENTS_MCP_SESSION_ID (distinto por cliente,
    /// estable entre reinicios). Sin él se usa un nonce privado de proceso:
    /// nunca se comparte la bandeja solo por tener el mismo token.
    fn installSessionTag(self: *ServerCtx, handle: ?*anyopaque, stable_id: ?[]const u8) !void {
        const token = self.expected_token orelse return;
        var nonce: [32]u8 = undefined;
        const scope = stable_id orelse blk: {
            if (BCryptGenRandom(null, &nonce, nonce.len, 0x2) != 0) return error.McpSessionRandomFailed;
            break :blk nonce[0..];
        };
        var hash = std.crypto.hash.sha2.Sha256.init(.{});
        hash.update(token);
        hash.update("\x00devagents-mcp-session\x00");
        hash.update(scope);
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        hash.final(&digest);
        const hex = std.fmt.bytesToHex(digest, .lower);
        const tag = try self.allocator.dupe(u8, &hex);
        errdefer self.allocator.free(tag);
        const tag_z = try self.allocator.dupeZ(u8, tag);
        defer self.allocator.free(tag_z);
        if (core.c_api.da_set_mcp_session(handle, tag_z.ptr) != 0) return error.McpSessionOriginFailed;
        if (self.session_tag) |old| self.allocator.free(old);
        self.session_tag = tag;
    }

    fn deinit(self: *ServerCtx) void {
        if (self.session_tag) |tag| {
            self.allocator.free(tag);
            self.session_tag = null;
        }
        self.tool_schemas.deinit();
        if (self.approvals_db != null) {
            self.approvals_db.?.close();
            self.approvals_db = null;
        }
        if (self.db_path) |p| self.allocator.free(p);
        self.db_path = null;
        if (self.remote_session) |session| session.stop(self.allocator);
        self.releaseToken(null);
        if (self.core_handle) |h| {
            _ = core.c_api.da_core_shutdown(h);
        }
    }

    const TokenObserver = struct { context: *anyopaque, observe: *const fn (*anyopaque, []const u8) void };

    /// e5-harden punto 10: la credencial se pone a cero antes de devolver su
    /// memoria al asignador. `observer` solo lo usan las pruebas.
    fn releaseToken(self: *ServerCtx, observer: ?TokenObserver) void {
        if (self.expected_token) |t| {
            std.crypto.secureZero(u8, @constCast(t));
            if (observer) |check| check.observe(check.context, t);
            self.allocator.free(t);
            self.expected_token = null;
        }
    }

    /// r3 (auditoría el segundo auditor): conexión propia del servidor a la tabla
    /// approvals de la MISMA base de runtime que abrió el núcleo (c_api.zig la
    /// declara fuente de verdad compartida entre procesos; la cabina la lee en
    /// tiempo real vía da_approval_pending_json y la resuelve con
    /// da_approval_resolve desde bridge.cpp core.approvals.resolve). El
    /// registro y la lectura las hace el servidor; la decisión sigue siendo
    /// exclusivamente humana desde otro proceso.
    fn spacesApprovalConn(self: *ServerCtx) !core.db.Connection {
        if (self.approvals_db) |conn| return conn;
        const path = self.db_path orelse return error.NoRuntimeDb;
        var conn = try core.db.Connection.open(self.allocator, path);
        errdefer conn.close();
        if (std.mem.eql(u8, path, ":memory:")) {
            // Sesión hermética: la BD del núcleo es OTRA :memory:, así que la
            // tabla approvals vive solo para este servidor (fase 1 y fase 2
            // comparten esta misma conexión). Mismo esquema mínimo que las
            // migraciones V9/V15/V16 de runtime.db (core/src/db.zig:665).
            try conn.exec(
                \\CREATE TABLE IF NOT EXISTS approvals (
                \\    id INTEGER PRIMARY KEY,
                \\    task_id TEXT NOT NULL,
                \\    description TEXT NOT NULL,
                \\    approved INTEGER NOT NULL DEFAULT 0,
                \\    resolved INTEGER NOT NULL DEFAULT 0,
                \\    created_at INTEGER NOT NULL
                \\);
            );
            inline for ([_][]const u8{
                "ALTER TABLE approvals ADD COLUMN command_prefix TEXT",
                "ALTER TABLE approvals ADD COLUMN exe TEXT",
                "ALTER TABLE approvals ADD COLUMN args_json TEXT",
                "ALTER TABLE approvals ADD COLUMN order_id INTEGER NOT NULL DEFAULT 0",
                "ALTER TABLE approvals ADD COLUMN origin TEXT NOT NULL DEFAULT ''",
            }) |sql| try conn.exec(sql);
        }
        self.approvals_db = conn;
        return conn;
    }

    /// Registra (o reutiliza si ya hay una idéntica pendiente) una solicitud
    /// de spaces en la tabla compartida y devuelve su approval_id. Nunca
    /// ejecuta: el realizado queda pendiente hasta que un humano lo resuelva
    /// desde otro proceso (cabina) con da_approval_resolve.
    fn spacesApprovalInsert(self: *ServerCtx, task_name: []const u8, description: []const u8, descriptor: []const u8) !i64 {
        const conn = try self.spacesApprovalConn();
        // T12B B-2 (auditor 3): la reutilización y la inserción van acotadas al
        // origen de esta sesión; una tarjeta ajena no se reutiliza ni se ve.
        const origin = self.session_tag orelse "";
        {
            const stmt = try conn.prepare("SELECT id FROM approvals WHERE resolved = 0 AND command_prefix = ? AND task_id = ? AND args_json = ? AND origin = ?");
            defer conn.finalize(stmt);
            try core.db.bindText(stmt, 1, SPACES_MCP_PREFIX);
            try core.db.bindText(stmt, 2, task_name);
            try core.db.bindText(stmt, 3, descriptor);
            try core.db.bindText(stmt, 4, origin);
            if (core.db.c.sqlite3_step(stmt) == core.db.c.SQLITE_ROW)
                return core.db.c.sqlite3_column_int64(stmt, 0);
        }
        const stmt = try conn.prepare("INSERT INTO approvals (task_id, description, approved, resolved, created_at, command_prefix, exe, args_json, order_id, origin) VALUES (?, ?, 0, 0, ?, ?, NULL, ?, 0, ?) RETURNING id");
        defer conn.finalize(stmt);
        try core.db.bindText(stmt, 1, task_name);
        try core.db.bindText(stmt, 2, description);
        try core.db.bindInt(stmt, 3, core.health.nowMillis(conn));
        try core.db.bindText(stmt, 4, SPACES_MCP_PREFIX);
        try core.db.bindText(stmt, 5, descriptor);
        try core.db.bindText(stmt, 6, origin);
        if (core.db.c.sqlite3_step(stmt) != core.db.c.SQLITE_ROW) return error.ExecApprovalFailed;
        const id = core.db.c.sqlite3_column_int64(stmt, 0);
        if (core.db.c.sqlite3_step(stmt) != core.db.c.SQLITE_DONE) return error.ExecApprovalFailed;
        return id;
    }

    /// Estado de una solicitud de aprobación en la tabla compartida. `mismatch`
    /// existe la fila, pero no corresponde a la ACCIÓN EXACTA que el cliente
    /// reenvía (misma tool y mismos argumentos canónicos): el anti-falsificación
    /// es la comparación exacta descriptor/args_json + task_id. `consumed` es
    /// el estado posterior a ejecutar: la aprobación es de UN SOLO USO.
    const SpacesApprovalState = enum { pending, rejected, granted, unknown, mismatch, consumed };

    const SpacesApprovalRow = struct {
        state: SpacesApprovalState,
        /// Copia del args_json registrado al solicitar ("" si NULL). En poda
        /// contiene el snapshot de ids archivados que el humano vio.
        stored: ?[]u8 = null,
    };

    fn spacesApprovalFetch(self: *ServerCtx, allocator: std.mem.Allocator, id: i64, task_name: []const u8) SpacesApprovalRow {
        const conn = self.spacesApprovalConn() catch return .{ .state = .unknown };
        const stmt = conn.prepare("SELECT resolved, approved, task_id, args_json FROM approvals WHERE id = ? AND command_prefix = ? AND origin = ?") catch return .{ .state = .unknown };
        defer conn.finalize(stmt);
        core.db.bindInt(stmt, 1, id) catch return .{ .state = .unknown };
        core.db.bindText(stmt, 2, SPACES_MCP_PREFIX) catch return .{ .state = .unknown };
        core.db.bindText(stmt, 3, self.session_tag orelse "") catch return .{ .state = .unknown };
        if (core.db.c.sqlite3_step(stmt) != core.db.c.SQLITE_ROW) return .{ .state = .unknown };
        const resolved_code = core.db.c.sqlite3_column_int64(stmt, 0);
        const approved = core.db.c.sqlite3_column_int64(stmt, 1) != 0;
        const row_task = sqliteColumnText(stmt, 2);
        if (!std.mem.eql(u8, row_task, task_name)) return .{ .state = .mismatch };
        const state: SpacesApprovalState = if (resolved_code == SPACES_APPROVAL_CONSUMED)
            .consumed
        else if (resolved_code != 0)
            (if (approved) .granted else .rejected)
        else
            .pending;
        return .{ .state = state, .stored = allocator.dupe(u8, sqliteColumnText(stmt, 3)) catch null };
    }

    /// Consume (de un solo uso) una aprobación concedida. Devuelve false si la
    /// fila ya no estaba en granted (otro proceso la resolvió o consumió).
    fn spacesApprovalConsume(self: *ServerCtx, id: i64) bool {
        const conn = self.spacesApprovalConn() catch return false;
        const stmt = conn.prepare("UPDATE approvals SET resolved = ? WHERE id = ? AND resolved = 1 AND approved = 1") catch return false;
        defer conn.finalize(stmt);
        core.db.bindInt(stmt, 1, SPACES_APPROVAL_CONSUMED) catch return false;
        core.db.bindInt(stmt, 2, id) catch return false;
        if (core.db.c.sqlite3_step(stmt) != core.db.c.SQLITE_DONE) return false;
        return conn.changes() == 1;
    }

    /// Ids de los spaces YA archivados del proyecto: el conjunto que el humano
    /// ve en la solicitud de poda. Se guarda en args_json al pedir la
    /// aprobación para que la fase 2 no pode lo archivado después.
    fn spacesArchivedIds(self: *ServerCtx, allocator: std.mem.Allocator, project_id: []const u8) ![]i64 {
        const conn = try self.spacesApprovalConn();
        const stmt = conn.prepare("SELECT id FROM spaces WHERE project_id = ? AND archived_at IS NOT NULL ORDER BY id ASC") catch return allocator.alloc(i64, 0);
        defer conn.finalize(stmt);
        try core.db.bindText(stmt, 1, project_id);
        var ids: std.ArrayListUnmanaged(i64) = .empty;
        errdefer ids.deinit(allocator);
        while (core.db.c.sqlite3_step(stmt) == core.db.c.SQLITE_ROW)
            try ids.append(allocator, core.db.c.sqlite3_column_int64(stmt, 0));
        return ids.toOwnedSlice(allocator);
    }

    /// r6 (auditoría el segundo auditor, lote I): la poda aprobada se delega en
    /// el motor con los ids EXACTOS del snapshot. `da_spaces_prune_ids`
    /// (core/src/c_api.zig) comprueba por id que siga archivado y del
    /// proyecto, retira su worktree y su rama y borra la fila: replica la
    /// limpieza de la poda normal, que el DELETE directo anterior no hacía.
    /// Los espacios archivados después de la aprobación no están en la lista
    /// y jamás entran aquí. Devuelve cuántos se podaron.
    fn spacesPruneApproved(
        self: *ServerCtx,
        allocator: std.mem.Allocator,
        handle: ?*anyopaque,
        project_id: []const u8,
        approved_ids: []const i64,
    ) !u32 {
        _ = self;
        const ids_json = try std.json.Stringify.valueAlloc(allocator, approved_ids, .{});
        defer allocator.free(ids_json);
        const ids_z = try allocator.dupeZ(u8, ids_json);
        defer allocator.free(ids_z);
        const project_z = try allocator.dupeZ(u8, project_id);
        defer allocator.free(project_z);
        var count: u32 = 0;
        if (core.c_api.da_spaces_prune_ids(handle, project_z.ptr, ids_z.ptr, &count) != 0)
            return error.PruneFailed;
        return count;
    }

    /// MCP-AUTH: frontera de confianza del servidor. Un proceso lanzado con
    /// DEVAGENTS_MCP_TOKEN en su entorno (el host propio o una IDE externa
    /// configurada por el usuario) nace autenticado. Sin env, el cliente debe
    /// presentar el token vía `initialize` (params.token) o la tool
    /// `authenticate`; el token esperado vive en el archivo `mcp_token` junto a
    /// la runtime.db y lo muestra el panel MCP de la cabina. Si ni env ni
    /// archivo pueden resolverse, se genera y persiste con ACL del usuario.
    /// Los avisos contienen la ruta, nunca la credencial. :memory: conserva
    /// un token privado en RAM para las sesiones herméticas de prueba.
    fn resolveAuthToken(self: *ServerCtx, db_path: []const u8) void {
        var envbuf: [256]u8 = undefined;
        defer std.crypto.secureZero(u8, &envbuf);
        const n = GetEnvironmentVariableA("DEVAGENTS_MCP_TOKEN", &envbuf, envbuf.len);
        if (n > 0 and n < envbuf.len) {
            self.expected_token = self.allocator.dupe(u8, envbuf[0..n]) catch {
                std.debug.print("devagents-mcp: no se pudo copiar la credencial del entorno; autenticacion bloqueada\n", .{});
                return;
            };
            self.authed = true; // el lanzador configuró la credencial a propósito
            return;
        }
        if (!std.mem.eql(u8, db_path, ":memory:")) {
            // con el lanzamiento por defecto db_path es "runtime.db" a
            // secas; el núcleo lo ancla a %LOCALAPPDATA%\DevAgents
            // (paths.canonicalDbPath, en da_core_init) pero aquí dirname daba
            // null y el token se volvía efímero siempre. Misma función que el
            // núcleo: el archivo de token vive junto a la base que se abrió.
            const anclado: ?[:0]const u8 = if (std.fs.path.dirname(db_path) == null) blk: {
                const z = self.allocator.dupeZ(u8, db_path) catch break :blk null;
                defer self.allocator.free(z);
                break :blk core.paths.canonicalDbPath(self.allocator, z) catch null;
            } else null;
            defer if (anclado) |a| self.allocator.free(a);
            const efectivo: []const u8 = if (anclado) |a| a else db_path;
            if (std.fs.path.dirname(efectivo)) |dir| {
                core.private_data.ensureDirectory(self.allocator, dir) catch {
                    std.debug.print("devagents-mcp: no se pudo proteger la carpeta de datos; autenticacion bloqueada; configure DEVAGENTS_MCP_TOKEN\n", .{});
                    return;
                };
                if (std.fs.path.join(self.allocator, &.{ dir, "mcp_token" })) |tp| {
                    defer self.allocator.free(tp);
                    if (self.readOrCreateTokenFile(tp)) |tok| {
                        self.expected_token = tok;
                        return;
                    }
                } else |_| {
                    std.debug.print("devagents-mcp: no se pudo resolver el archivo de token; autenticacion bloqueada\n", .{});
                    return;
                }
            }
            std.debug.print("devagents-mcp: no se pudo persistir el token; autenticacion bloqueada; configure DEVAGENTS_MCP_TOKEN\n", .{});
            return;
        }
        self.expected_token = self.generateToken();
    }

    fn generateToken(self: *ServerCtx) ?[]u8 {
        var bytes: [16]u8 = undefined;
        defer std.crypto.secureZero(u8, &bytes);
        // BCRYPT_USE_SYSTEM_PREFERRED_RNG (0x2): CNG del sistema — el fork no
        // expone std.crypto.random.
        if (BCryptGenRandom(null, &bytes, bytes.len, 0x00000002) != 0) return null;
        const hex_chars = "0123456789abcdef";
        const out = self.allocator.alloc(u8, 32) catch return null;
        for (bytes, 0..) |b, i| {
            out[i * 2] = hex_chars[b >> 4];
            out[i * 2 + 1] = hex_chars[b & 0x0f];
        }
        return out;
    }

    /// Lee `path` vía Win32 (el fork Zig no expone std.fs.readFileAlloc).
    fn readFileAllocWin(self: *ServerCtx, path: []const u8) ?[]u8 {
        if (!is_windows) {
            const z = self.allocator.dupeZ(u8, path) catch return null;
            defer self.allocator.free(z);
            const fd = std.c.open(z, .{ .ACCMODE = .RDONLY, .NOFOLLOW = true, .CLOEXEC = true });
            if (fd < 0) return null;
            defer _ = std.c.close(fd);
            var buf: [4096]u8 = undefined;
            const n = std.c.read(fd, &buf, buf.len);
            if (n <= 0 or n >= buf.len) return null;
            defer std.crypto.secureZero(u8, &buf);
            return self.allocator.dupe(u8, buf[0..@intCast(n)]) catch null;
        }
        const GENERIC_READ: u32 = 0x80000000;
        const FILE_SHARE_READ: u32 = 0x00000001;
        const OPEN_EXISTING: u32 = 3;
        const path_z = self.allocator.dupeZ(u8, path) catch return null;
        defer self.allocator.free(path_z);
        const h = CreateFileA(path_z.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
        if (h == null or h == @as(?*anyopaque, @ptrFromInt(std.math.maxInt(usize)))) return null;
        defer _ = CloseHandle(h);
        const size = GetFileSize(h, null);
        if (size == 0xFFFFFFFF or size == 0 or size > 4096) return null;
        const buf = self.allocator.alloc(u8, size) catch return null;
        var n: u32 = 0;
        if (ReadFile(h, buf.ptr, size, &n, null) == 0 or n != size) {
            std.crypto.secureZero(u8, buf);
            self.allocator.free(buf);
            return null;
        }
        return buf;
    }

    fn writeFileWin(self: *ServerCtx, path: []const u8, data: []const u8) bool {
        // T9: en POSIX el archivo nace 0600 con O_EXCL (nunca reemplaza).
        if (!is_windows) {
            core.private_data.writeNew(self.allocator, path, data) catch return false;
            return true;
        }
        const descriptor = self.userOnlyTokenDescriptor() catch return false;
        defer _ = LocalFree(descriptor);
        var attributes = TokenSecurityAttributes{ .descriptor = descriptor };
        const path_z = self.allocator.dupeZ(u8, path) catch return false;
        defer self.allocator.free(path_z);
        // CREATE_NEW never replaces an existing credential (or link).
        const h = CreateFileA(path_z.ptr, 0x40000000, 0, &attributes, 1, 0x80, null);
        if (h == null or h == @as(?*anyopaque, @ptrFromInt(std.math.maxInt(usize)))) return false;
        defer _ = CloseHandle(h);
        var n: u32 = 0;
        return WriteFile(h, data.ptr, @intCast(data.len), &n, null) != 0 and n == data.len;
    }

    fn userOnlyTokenDescriptor(self: *ServerCtx) !?*anyopaque {
        var token: ?*anyopaque = null;
        if (OpenProcessToken(GetCurrentProcess(), 0x0008, &token) == 0) {
            tokenDiagnostic(@src(), "OpenProcessToken", GetLastError());
            return error.TokenAccessFailed;
        }
        defer _ = CloseHandle(token);
        var needed: u32 = 0;
        const queried = GetTokenInformation(token, 1, null, 0, &needed);
        const query_error = GetLastError();
        if (queried != 0 or query_error != 122 or needed == 0 or needed > 65536) {
            tokenDiagnostic(@src(), "GetTokenInformation(size)", query_error);
            return error.TokenUserFailed;
        }
        const buffer = self.allocator.alignedAlloc(u8, .of(usize), needed) catch |failure| {
            tokenDiagnostic(@src(), "TokenUser allocation", 8);
            return failure;
        };
        defer self.allocator.free(buffer);
        if (GetTokenInformation(token, 1, buffer.ptr, needed, &needed) == 0) {
            tokenDiagnostic(@src(), "GetTokenInformation(TokenUser)", GetLastError());
            return error.TokenUserFailed;
        }
        const sid: *const ?*anyopaque = @ptrCast(@alignCast(buffer.ptr));
        var sid_text: ?[*:0]u8 = null;
        if (ConvertSidToStringSidA(sid.*, &sid_text) == 0) {
            tokenDiagnostic(@src(), "ConvertSidToStringSidA", GetLastError());
            return error.SidConversionFailed;
        }
        defer _ = LocalFree(@ptrCast(sid_text));
        const sddl = std.fmt.allocPrintSentinel(self.allocator, "D:P(A;;FA;;;{s})", .{std.mem.span(sid_text.?)}, 0) catch |failure| {
            tokenDiagnostic(@src(), "SDDL allocation", 8);
            return failure;
        };
        defer self.allocator.free(sddl);
        var descriptor: ?*anyopaque = null;
        if (ConvertStringSecurityDescriptorToSecurityDescriptorA(sddl, 1, &descriptor, null) == 0) {
            tokenDiagnostic(@src(), "ConvertStringSecurityDescriptorToSecurityDescriptorA", GetLastError());
            return error.SecurityDescriptorFailed;
        }
        return descriptor;
    }

    fn restrictTokenFile(self: *ServerCtx, path: []const u8) bool {
        if (!is_windows) {
            core.private_data.protectFile(self.allocator, path) catch return false;
            return true;
        }
        const descriptor = self.userOnlyTokenDescriptor() catch return false;
        defer _ = LocalFree(descriptor);
        var present: c_int = 0;
        var defaulted: c_int = 0;
        var dacl: ?*anyopaque = null;
        if (GetSecurityDescriptorDacl(descriptor, &present, &dacl, &defaulted) == 0) {
            tokenDiagnostic(@src(), "GetSecurityDescriptorDacl", GetLastError());
            return false;
        }
        if (present == 0 or dacl == null) {
            tokenDiagnostic(@src(), "GetSecurityDescriptorDacl missing DACL", 1338);
            return false;
        }
        const path_z = self.allocator.dupeZ(u8, path) catch {
            tokenDiagnostic(@src(), "token path allocation", 8);
            return false;
        };
        defer self.allocator.free(path_z);
        // SetSecurityInfo can query the existing security information; grant
        // READ_CONTROL as well as WRITE_DAC, matching workspace ACL repair.
        const h = CreateFileA(path_z, 0x00060080, 3, null, 3, 0x00200000, null);
        if (h == null or h == @as(?*anyopaque, @ptrFromInt(std.math.maxInt(usize)))) {
            tokenDiagnostic(@src(), "CreateFileA(READ_CONTROL|WRITE_DAC)", GetLastError());
            return false;
        }
        const code = SetSecurityInfo(h, 1, 0x80000004, null, null, dacl, null);
        // Capture before CloseHandle overwrites the thread's last error.
        if (code != 0) tokenDiagnostic(@src(), "SetSecurityInfo(PROTECTED_DACL)", code);
        _ = CloseHandle(h);
        if (code == 0) return true;
        // Retain the credential and repair the existing object through the same
        // native file setter used by private workspaces. Never truncate/delete.
        core.private_data.protectFile(self.allocator, path) catch {
            tokenDiagnostic(@src(), "native protected DACL fallback failed", GetLastError());
            return false;
        };
        std.debug.print("devagents-mcp: ACL del token reparada por descriptor nativo\n", .{});
        return true;
    }

    fn readOrCreateTokenFile(self: *ServerCtx, path: []const u8) ?[]const u8 {
        if (self.readFileAllocWin(path)) |raw| {
            defer self.allocator.free(raw);
            defer std.crypto.secureZero(u8, raw);
            const t = std.mem.trim(u8, raw, " \t\r\n");
            if (t.len >= 16) {
                const owned = self.allocator.dupe(u8, t) catch return null;
                if (!self.restrictTokenFile(path)) {
                    std.crypto.secureZero(u8, owned);
                    self.allocator.free(owned);
                    std.debug.print("devagents-mcp: no se pudo proteger el archivo de token; autenticacion bloqueada\n", .{});
                    return null;
                }
                return owned;
            }
        }
        const tok = self.generateToken() orelse return null;
        if (!self.writeFileWin(path, tok)) {
            std.crypto.secureZero(u8, tok);
            self.allocator.free(tok);
            std.debug.print("devagents-mcp: no se pudo persistir el token; autenticacion bloqueada; archivo: {s}\n", .{path});
            return null;
        }
        // T9 fase B: la orden para leerlo es la del sistema (PowerShell en Windows).
        const reader = if (@import("builtin").os.tag == .windows) "Get-Content -LiteralPath" else "cat --";
        std.debug.print("devagents-mcp: token guardado en {s}\nPara leerlo: {s} \"{s}\"\n", .{ path, reader, path });
        return tok;
    }

    /// e5-harden punto 10: comparación en tiempo constante. Se comparan los
    /// SHA-256 para que ni el contenido ni la longitud del token presentado
    /// cambien el tiempo de respuesta.
    fn checkToken(self: *ServerCtx, presented: []const u8) bool {
        const expected = self.expected_token orelse return false;
        var expected_hash: [32]u8 = undefined;
        var presented_hash: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &expected_hash);
        defer std.crypto.secureZero(u8, &presented_hash);
        std.crypto.hash.sha2.Sha256.hash(expected, &expected_hash, .{});
        std.crypto.hash.sha2.Sha256.hash(presented, &presented_hash, .{});
        return std.crypto.timing_safe.eql([32]u8, presented_hash, expected_hash);
    }

    fn freshId(self: *ServerCtx) i64 {
        const id = self.next_id;
        self.next_id += 1;
        return id;
    }
};

/// Tools que mutan estado, ejecutan procesos, resuelven aprobaciones, tocan
/// credenciales/gobernanza, gastan cuota externa o capturan la pantalla del
/// usuario. Requieren sesión autenticada (MCP-AUTH). Todo lo demás es de
/// lectura/observación y queda abierto — ese es el producto: una IDE externa
/// puede inspeccionar DevAgents sin credencial, pero no actuar sobre él.
// Las lecturas de datos del proyecto, la sesión o el proveedor de incidencias también exigen token.
const PRIVILEGED_READ_TOOLS = [_][]const u8{
    "fs_read",
    "fs_list",
    "fs_search",
    "session_messages",
    "worker_output",
    "memory_context",
    "approvals_list",
    "approval_result",
    "git_status",
    "git_diff",
    "git_log",
    "issues_list",
    "issue_read",
    "issue_prompt",
};

const PRIVILEGED_TOOLS = [_][]const u8{
    "remote_start",
    "remote_stop",
    // SEC2 R6/H8: `notify` pinta texto arbitrario en la cabina y podia imitar
    // una peticion de aprobacion; ahora exige la credencial MCP.
    "ui_action",
    "order_from_issue",
    "issue_comment",
    "da_submit_order",
    "da_submit_order_async",
    "order_submit",
    "vision_probe",
    "confirm_plan",
    "answer_order",
    "dispatch_async",
    "dispatch_cancel",
    // PLAN-CANCEL: detiene una planificación en curso — acción sobre la orden.
    "plan_cancel",
    "add_key",
    "remove_key",
    "shell_run",
    "run_detached",
    "set_workspace_root",
    // las tres tools de spaces mutan estado (crean/retiran
    // worktrees y filas en runtime.db) — misma gobernanza que el resto.
    "space_create",
    "space_archive",
    "spaces_prune",
    "mount_add",
    "mount_remove",
    "mcp_disconnect",
    "mcp_call_tool",
    "plan_set_model",
    // MCP-AUTH-HOLE (mesa-seguridad 2026-09-15): fijar el modelo del ejecutor
    // o del auditor ES gobernanza — un cliente sin autenticar podía dirigir la
    // ejecución/auditoría al modelo que quisiera. Los getters quedan abiertos.
    "exec_set_model",
    "audit_set_model",
    // ENJAMBRE: fijar el conjunto de modelos también ES gobernanza — misma
    // regla que los pines de rol (mesa-seguridad 2026-09-15).
    "swarm_set_models",
    "models_preferences_set_v1",
    // E5.08: fijar los límites de los agentes externos también ES gobernanza
    // (controla cuánto puede correr un CLI externo por tarea y por orden).
    "external_model_options_set",
    "catalog_reconcile_enabled",
    "session_rename",
    "pricing_revalidate",
    "inventory_refresh",
    "webhook_add",
    "webhook_delete",
    "webhook_test",
    "web_search",
    "embeddings_config_set",
    // E5.18: elegir la ganadora muta el worktree de la orden (fusión).
    "best_of_n_choose",
    // E5.15: indexar envia contenido del repo al proveedor y el probe hace una
    // llamada real — misma gobernanza que embeddings_config_set/health_probe.
    "repo_embed_index",
    "embeddings_probe",
    "health_probe_all",
    "screenshot",
    "capture_screenshot",
    // B3 Ship Flow: crean ramas, empujan a remoto, abren/fusionan PRs y
    // escriben disco (git clone). prs_list queda abierta: es lectura.
    "ship_order",
    "pr_merge",
    "repo_clone",
    // T7 (paridad sin gobierno): aprobar/replanificar, archivar, escribir
    // archivos y git mutan estado o abren tarjetas de aprobación en la cabina.
    "plan_approve",
    "plan_replan",
    "session_archive",
    "fs_write",
    "git_add",
    "git_commit",
    // T12 A1 (recorrido de todas las tools con efecto): repo_search lee los
    // archivos del proyecto y en modo semantic/hybrid los manda al proveedor
    // de embeddings; discover_models llama a /models de cada proveedor con
    // sus claves; agents_external_refresh lanza las CLIs instaladas para
    // detectarlas. Red, cuota o procesos: credencial.
    "repo_search",
    "discover_models",
    "agents_external_refresh",
} ++ PRIVILEGED_READ_TOOLS;

fn isPrivilegedTool(name: []const u8) bool {
    for (PRIVILEGED_TOOLS) |t| {
        if (std.mem.eql(u8, name, t)) return true;
    }
    return false;
}

/// T7 (d, decisión del propietario del 13-nov «paridad sin gobierno»):
/// cambiar permisos, reglas de gobierno, hooks y plugins queda SOLO en la
/// cabina. Un agente conectado por MCP no puede aflojar (ni tocar) sus propias
/// barreras: estas tools no se anuncian en tools/list y cualquier llamada con
/// estos nombres se rechaza antes de autenticar, validar o llegar al motor.
/// La cabina conserva sus manejadores (core.permissions.set,
/// core.external.paths.set, core.external.limits.set,
/// core.agentic.setIterations, core.budget.set, core.approvals.resolve*,
/// core.hooks.set, core.plugin.trust, core.mcp.connect, core.governance.set).
const CABIN_ONLY_TOOLS = [_][]const u8{
    "set_permission_config",
    "approvals_resolve",
    "approvals_resolve_scoped",
    "external_paths_set",
    "external_limits_set",
    "set_agentic_max_iterations",
    "paid_budget_set",
    "mcp_connect",
    "hooks_set",
    "plugin_trust",
    "plugin_untrust",
    "governance_set",
    "project_rules_set",
};

fn isCabinOnlyTool(name: []const u8) bool {
    for (CABIN_ONLY_TOOLS) |t| {
        if (std.mem.eql(u8, name, t)) return true;
    }
    return false;
}

const CABIN_ONLY_MESSAGE = "reservado a la cabina (UI humana): cambiar permisos, aprobaciones de comandos, reglas de gobierno, limites, cupo de gasto, hooks, plugins o servidores MCP solo se hace desde DevAgents. Un cliente MCP no puede tocar sus propias barreras.";

// ---------------------------------------------------------------------------
// Procesamiento de requests JSON-RPC
// ---------------------------------------------------------------------------

// e5-harden punto 10: el analizador JSON copia las cadenas que descodifica
// (por ejemplo un token con escapes \u); todo lo que asigna se pone a cero al
// liberarse, también lo de un documento rechazado a medias.
const ParserAllocator = struct {
    backing: std.mem.Allocator,
    observer: ?ServerCtx.TokenObserver = null,

    fn allocator(self: *ParserAllocator) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = std.mem.Allocator.noResize, .remap = std.mem.Allocator.noRemap, .free = free } };
    }

    fn alloc(context: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *ParserAllocator = @ptrCast(@alignCast(context));
        return self.backing.rawAlloc(len, alignment, ret_addr);
    }

    fn free(context: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *ParserAllocator = @ptrCast(@alignCast(context));
        std.crypto.secureZero(u8, memory);
        if (self.observer) |observer| observer.observe(observer.context, memory);
        self.backing.rawFree(memory, alignment, ret_addr);
    }
};

fn processRequest(allocator: std.mem.Allocator, raw: []const u8, ctx: *ServerCtx) !?[]u8 {
    return processRequestWithParserObserver(allocator, raw, ctx, null);
}

fn processRequestWithParserObserver(allocator: std.mem.Allocator, raw: []const u8, ctx: *ServerCtx, observer: ?ServerCtx.TokenObserver) !?[]u8 {
    var secure_parser: ParserAllocator = .{ .backing = allocator, .observer = observer };
    var parsed = std.json.parseFromSlice(std.json.Value, secure_parser.allocator(), raw, .{}) catch {
        return try buildErrorResp(allocator, 0, -32700, "parse error");
    };
    defer parsed.deinit();
    switch (parsed.value) {
        .object => |obj| return processMessage(allocator, obj, ctx),
        .array => |items| return processBatch(allocator, items.items, ctx),
        else => return try buildErrorResp(allocator, 0, -32600, "invalid request"),
    }
}

// ---------------------------------------------------------------------------
// T7 (d): versiones del protocolo MCP
// ---------------------------------------------------------------------------
// Fuente: https://modelcontextprotocol.io/specification/2025-11-25/basic/lifecycle
// («If the server supports the requested protocol version, it MUST respond
// with the same version. Otherwise, the server MUST respond with another
// protocol version it supports. This SHOULD be the latest»). Lo que cambia
// entre versiones para un servidor stdio de herramientas, según los changelog
// oficiales de cada revisión:
// - 2025-03-26: el receptor DEBE aceptar lotes JSON-RPC (basic, «Batching»).
// - 2025-06-18: se retiran los lotes; `title` en Implementation; MUST en la
//   fase de operación (respetar la versión negociada).
// - 2025-11-25: `description` en Implementation; los errores de validación de
//   argumentos de una tool vuelven como error de ejecución (isError) y no como
//   error de protocolo (SEP-1303), para que el modelo pueda corregirse.
// En todas: los ids pueden ser cadena o entero y nunca null, y a una
// notificación (sin id) no se le responde.
const PROTOCOL_2024_11_05 = "2024-11-05";
const PROTOCOL_2025_03_26 = "2025-03-26";
const PROTOCOL_2025_06_18 = "2025-06-18";
const PROTOCOL_2025_11_25 = "2025-11-25";
const SUPPORTED_PROTOCOL_VERSIONS = [_][]const u8{ PROTOCOL_2024_11_05, PROTOCOL_2025_03_26, PROTOCOL_2025_06_18, PROTOCOL_2025_11_25 };
const LATEST_PROTOCOL_VERSION = PROTOCOL_2025_11_25;

fn negotiateProtocolVersion(requested: ?[]const u8) []const u8 {
    const wanted = requested orelse return LATEST_PROTOCOL_VERSION;
    for (SUPPORTED_PROTOCOL_VERSIONS) |version| {
        if (std.mem.eql(u8, version, wanted)) return version;
    }
    return LATEST_PROTOCOL_VERSION;
}

/// Las fechas ISO se ordenan como texto.
fn protocolAtLeast(ctx: *const ServerCtx, version: []const u8) bool {
    return std.mem.order(u8, ctx.protocol_version, version) != .lt;
}

fn processBatch(allocator: std.mem.Allocator, items: []const std.json.Value, ctx: *ServerCtx) !?[]u8 {
    if (!std.mem.eql(u8, ctx.protocol_version, PROTOCOL_2025_03_26))
        return try buildErrorResp(allocator, 0, -32600, "invalid request: los lotes JSON-RPC solo existen en la version 2025-03-26 del protocolo");
    if (items.len == 0) return try buildErrorResp(allocator, 0, -32600, "invalid request: lote vacio");
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var count: usize = 0;
    try out.writer.writeByte('[');
    for (items) |item| {
        const response = if (item == .object)
            try processMessage(allocator, item.object, ctx)
        else
            try buildErrorResp(allocator, 0, -32600, "invalid request");
        const body = response orelse continue;
        defer allocator.free(body);
        if (count > 0) try out.writer.writeByte(',');
        try out.writer.writeAll(body);
        count += 1;
    }
    if (count == 0) return null;
    try out.writer.writeByte(']');
    return try allocator.dupe(u8, out.written());
}

fn processMessage(allocator: std.mem.Allocator, obj: std.json.ObjectMap, ctx: *ServerCtx) !?[]u8 {
    const raw_id = obj.get("id");
    // JSON-RPC: un mensaje sin id es una notificación y nunca lleva respuesta.
    const is_notification = raw_id == null;
    const method = blk: {
        const m = obj.get("method") orelse {
            if (is_notification) return null;
            return try respondWithId(allocator, try buildErrorResp(allocator, 0, -32600, "missing method"), raw_id.?);
        };
        if (m != .string) {
            if (is_notification) return null;
            return try respondWithId(allocator, try buildErrorResp(allocator, 0, -32600, "invalid method"), raw_id.?);
        }
        break :blk m.string;
    };
    if (is_notification) {
        // notifications/initialized, notifications/cancelled y cualquier otra:
        // no hay estado que cambiar en este servidor.
        return null;
    }
    const id_value = raw_id.?;
    if (id_value != .integer and id_value != .string and id_value != .float and id_value != .number_string)
        return try respondWithId(allocator, try buildErrorResp(allocator, 0, -32600, "invalid request: id debe ser cadena o entero, nunca null"), .null);
    const id = idOf(id_value);
    const response = try dispatchMethod(allocator, method, id, obj, ctx) orelse return null;
    return try respondWithId(allocator, response, id_value);
}

fn dispatchMethod(allocator: std.mem.Allocator, method: []const u8, id: i64, obj: std.json.ObjectMap, ctx: *ServerCtx) !?[]u8 {
    if (std.mem.eql(u8, method, "initialize")) {
        var requested: ?[]const u8 = null;
        // MCP-AUTH: el cliente puede presentar el token en params.token (una IDE
        // externa configurada con la credencial del panel MCP de DevAgents).
        if (obj.get("params")) |pv| {
            if (pv == .object) {
                if (pv.object.get("token")) |tv| {
                    if (tv == .string and ctx.checkToken(tv.string)) ctx.authed = true;
                }
                if (pv.object.get("protocolVersion")) |vv| {
                    if (vv == .string) requested = vv.string;
                }
            }
        }
        ctx.protocol_version = negotiateProtocolVersion(requested);
        return try buildInitializeResp(allocator, id, ctx.protocol_version);
    }
    if (std.mem.eql(u8, method, "notifications/initialized")) return null;
    if (std.mem.eql(u8, method, "ping")) return try buildEmptyResult(allocator, id, null);
    if (std.mem.eql(u8, method, "resources/list")) return try buildEmptyResult(allocator, id, "resources");
    if (std.mem.eql(u8, method, "resources/templates/list")) return try buildEmptyResult(allocator, id, "resourceTemplates");
    if (std.mem.eql(u8, method, "prompts/list")) return try buildEmptyResult(allocator, id, "prompts");
    // Sin recursos ni prompts que ofrecer: cualquier uri o nombre es desconocido
    // (códigos de la especificación: -32002 recurso no encontrado, -32602 prompt).
    if (std.mem.eql(u8, method, "resources/read")) return try buildErrorResp(allocator, id, -32002, "Resource not found");
    if (std.mem.eql(u8, method, "prompts/get")) return try buildErrorResp(allocator, id, -32602, "Invalid prompt name");
    if (std.mem.eql(u8, method, "tools/list")) {
        return try buildToolsListResp(allocator, id);
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        const response = try handleToolCall(allocator, id, obj, ctx) orelse return null;
        if (!protocolAtLeast(ctx, PROTOCOL_2025_11_25)) return response;
        return try validationErrorAsToolError(allocator, id, response);
    }
    return try buildErrorResp(allocator, id, -32601, "method not found");
}

/// SEP-1303 (2025-11-25): un -32602 de tools/call (argumentos que no cumplen
/// el esquema) se entrega como resultado con isError para que el modelo lo lea.
/// Toma posesión de `response`.
fn validationErrorAsToolError(allocator: std.mem.Allocator, id: i64, response: []u8) ![]u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return response;
    defer parsed.deinit();
    if (parsed.value != .object) return response;
    const failure = parsed.value.object.get("error") orelse return response;
    if (failure != .object) return response;
    const code = failure.object.get("code") orelse return response;
    if (code != .integer or code.integer != -32602) return response;
    const message = failure.object.get("message") orelse return response;
    const converted = try buildToolResult(allocator, id, if (message == .string) message.string else "invalid arguments", true);
    allocator.free(response);
    return converted;
}

/// Los constructores escriben un id entero; si el cliente mandó una cadena (o el
/// id era inválido y se responde null) se reescribe para que la respuesta lleve
/// EXACTAMENTE el id de la petición. Toma posesión de `response`.
fn respondWithId(allocator: std.mem.Allocator, response: []u8, id_value: std.json.Value) ![]u8 {
    // Enteros (y los flotantes heredados de, reducidos por idOf) ya van bien.
    if (id_value != .string and id_value != .null) return response;
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch return response;
    defer parsed.deinit();
    if (parsed.value != .object) return response;
    try parsed.value.object.put(parsed.arena.allocator(), "id", id_value);
    const rewritten = try std.json.Stringify.valueAlloc(allocator, parsed.value, .{});
    allocator.free(response);
    return rewritten;
}

// ---------------------------------------------------------------------------
// Respuestas JSON-RPC
// ---------------------------------------------------------------------------

fn buildInitializeResp(allocator: std.mem.Allocator, id: i64, version: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("jsonrpc");
    try js.write("2.0");
    try js.objectField("id");
    try js.write(id);
    try js.objectField("result");
    try js.beginObject();
    try js.objectField("protocolVersion");
    try js.write(version);
    try js.objectField("capabilities");
    try js.beginObject();
    try js.objectField("tools");
    try js.beginObject();
    try js.objectField("listChanged");
    try js.write(false);
    try js.endObject();
    // Sin recursos ni prompts que ofrecer hoy: las listas responden vacías.
    try js.objectField("resources");
    try js.beginObject();
    try js.endObject();
    try js.objectField("prompts");
    try js.beginObject();
    try js.endObject();
    try js.endObject();
    try js.objectField("serverInfo");
    try js.beginObject();
    try js.objectField("name");
    try js.write("devagents-mcp");
    if (std.mem.order(u8, version, PROTOCOL_2025_06_18) != .lt) {
        try js.objectField("title");
        try js.write("DevAgents");
    }
    try js.objectField("version");
    // shared product/build identity, including ABI/bus/UI revisions.
    try js.write(std.mem.span(core.c_api.da_build_identity_v1()));
    if (std.mem.order(u8, version, PROTOCOL_2025_11_25) != .lt) {
        try js.objectField("description");
        try js.write("Motor de DevAgents: ordenes, planes, modelos, archivos, terminal y git del proyecto, con el mismo gobierno que la cabina.");
    }
    try js.endObject();
    try js.objectField("instructions");
    try js.write("Las tools marcadas x-devagents-privileged exigen el token del panel MCP de DevAgents (params.token en initialize o la tool authenticate). Permisos, aprobaciones de comandos, reglas de gobierno, hooks y plugins solo se cambian en la cabina.");
    try js.endObject();
    try js.endObject();
    return allocator.dupe(u8, out.written());
}

/// `{"result":{}}` (ping) o `{"result":{"<field>":[]}}` (listas vacías).
fn buildEmptyResult(allocator: std.mem.Allocator, id: i64, list_field: ?[]const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("jsonrpc");
    try js.write("2.0");
    try js.objectField("id");
    try js.write(id);
    try js.objectField("result");
    try js.beginObject();
    if (list_field) |field| {
        try js.objectField(field);
        try js.beginArray();
        try js.endArray();
    }
    try js.endObject();
    try js.endObject();
    return allocator.dupe(u8, out.written());
}

const SchemaField = struct {
    name: []const u8,
    typ: []const u8,
    req: bool,
    desc: []const u8,
    enum_vals: ?[]const []const u8 = null,
    default_val: ?[]const u8 = null,
    // F0.7 (reaplicado de e5-b11): cotas que se anuncian en el inputSchema y
    // que el validador genérico (`schemaViolation`) hace cumplir al despachar.
    minimum: ?i64 = null,
    maximum: ?i64 = null,
    min_length: ?usize = null,
    max_length: ?usize = null,
    max_items: ?usize = null,
    items_schema: ?[]const u8 = null,
};

const string_item_schema = "{\"type\":\"string\"}";
const git_path_item_schema = "{\"type\":\"string\",\"minLength\":1,\"maxLength\":2048}";
const model_item_schema = "{\"type\":\"object\",\"required\":[\"provider\",\"model\"],\"properties\":{\"provider\":{\"type\":\"string\",\"minLength\":1},\"model\":{\"type\":\"string\",\"minLength\":1}}}";
const image_item_schema = "{\"type\":\"object\",\"required\":[\"name\",\"data_base64\"],\"properties\":{\"name\":{\"type\":\"string\",\"minLength\":1,\"maxLength\":255},\"data_base64\":{\"type\":\"string\",\"maxLength\":6990508}}}";
const c_int_max: i64 = std.math.maxInt(c_int);

fn schemaNumber(value: std.json.Value) f64 {
    return switch (value) {
        .integer => |n| @floatFromInt(n),
        .float => |n| n,
        // Solo se llama con cotas internas del esquema o con números ya comprobados.
        else => unreachable,
    };
}

/// F0.7 (reaplicado de e5-b11): valida un valor JSON contra el subconjunto de
/// JSON Schema que publica `tools/list` (type, enum, minimum/maximum,
/// minLength/maxLength, minItems/maxItems, items, required, properties,
/// additionalProperties:false). Devuelve un diagnóstico propio del llamador
/// con la RUTA del campo y nunca su valor (podría ser un secreto), o null si
/// el valor cumple.
fn schemaViolation(allocator: std.mem.Allocator, schema: std.json.Value, value: std.json.Value, path: []const u8) std.mem.Allocator.Error!?[]u8 {
    const spec = schema.object;
    const typ = spec.get("type").?.string;
    const matches = if (std.mem.eql(u8, typ, "object"))
        value == .object
    else if (std.mem.eql(u8, typ, "array"))
        value == .array
    else if (std.mem.eql(u8, typ, "string"))
        value == .string
    else if (std.mem.eql(u8, typ, "boolean"))
        value == .bool
    else if (std.mem.eql(u8, typ, "null"))
        value == .null
    else if (std.mem.eql(u8, typ, "integer"))
        (value == .integer or (value == .float and floatFitsI64(value.float) and @trunc(value.float) == value.float))
    else if (std.mem.eql(u8, typ, "number"))
        (value == .integer or (value == .float and std.math.isFinite(value.float)))
    else
        false;
    if (!matches) return try std.fmt.allocPrint(allocator, "{s}: se esperaba {s}", .{ path, typ });
    if (spec.get("enum")) |values| {
        var found = false;
        for (values.array.items) |candidate| {
            if (value == .string and candidate == .string) {
                found = found or std.mem.eql(u8, value.string, candidate.string);
            } else if ((value == .integer or value == .float) and (candidate == .integer or candidate == .float)) {
                found = found or schemaNumber(value) == schemaNumber(candidate);
            } else if (value == .bool and candidate == .bool) {
                found = found or value.bool == candidate.bool;
            } else if (value == .null and candidate == .null) {
                found = true;
            }
        }
        if (!found) {
            // Los admitidos salen del propio esquema publicado, nunca del valor recibido.
            const allowed = try std.json.Stringify.valueAlloc(allocator, values, .{});
            defer allocator.free(allowed);
            return try std.fmt.allocPrint(allocator, "{s}: valor fuera de enum; admitidos: {s}", .{ path, allowed });
        }
    }
    if (value == .integer or value == .float) {
        if (spec.get("minimum")) |bound| {
            if (schemaNumber(value) < schemaNumber(bound)) return try std.fmt.allocPrint(allocator, "{s}: por debajo de minimum", .{path});
        }
        if (spec.get("maximum")) |bound| {
            if (schemaNumber(value) > schemaNumber(bound)) return try std.fmt.allocPrint(allocator, "{s}: por encima de maximum", .{path});
        }
    }
    if (value == .string) {
        const count = std.unicode.utf8CountCodepoints(value.string) catch return try std.fmt.allocPrint(allocator, "{s}: UTF-8 invalido", .{path});
        if (spec.get("minLength")) |bound| {
            if (count < @as(usize, @intCast(bound.integer))) return try std.fmt.allocPrint(allocator, "{s}: por debajo de minLength", .{path});
        }
        if (spec.get("maxLength")) |bound| {
            if (count > @as(usize, @intCast(bound.integer))) return try std.fmt.allocPrint(allocator, "{s}: por encima de maxLength", .{path});
        }
    }
    if (value == .array) {
        if (spec.get("minItems")) |bound| {
            if (value.array.items.len < @as(usize, @intCast(bound.integer))) return try std.fmt.allocPrint(allocator, "{s}: por debajo de minItems", .{path});
        }
        if (spec.get("maxItems")) |bound| {
            if (value.array.items.len > @as(usize, @intCast(bound.integer))) return try std.fmt.allocPrint(allocator, "{s}: por encima de maxItems", .{path});
        }
        if (spec.get("items")) |item_schema| {
            for (value.array.items, 0..) |item, index| {
                const item_path = try std.fmt.allocPrint(allocator, "{s}[{d}]", .{ path, index });
                defer allocator.free(item_path);
                if (try schemaViolation(allocator, item_schema, item, item_path)) |failure| return failure;
            }
        }
    }
    if (value == .object) {
        if (spec.get("required")) |required| {
            for (required.array.items) |field| {
                // "missing <campo>" se conserva: clientes y pruebas ya lo buscan.
                if (!value.object.contains(field.string)) return try std.fmt.allocPrint(allocator, "{s}.{s}: missing {s} (obligatorio)", .{ path, field.string, field.string });
            }
        }
        if (spec.get("properties")) |properties| {
            var fields = value.object.iterator();
            while (fields.next()) |field| {
                if (properties.object.get(field.key_ptr.*)) |field_schema| {
                    const field_path = try std.fmt.allocPrint(allocator, "{s}.{s}", .{ path, field.key_ptr.* });
                    defer allocator.free(field_path);
                    if (try schemaViolation(allocator, field_schema, field.value_ptr.*, field_path)) |failure| return failure;
                } else if (spec.get("additionalProperties")) |additional| {
                    // Mismo texto que `rejectUnknownArgs`.
                    if (additional == .bool and !additional.bool) return try std.fmt.allocPrint(allocator, "argumento desconocido: {s}.{s}", .{ path, field.key_ptr.* });
                }
            }
        }
    }
    return null;
}

/// F0.7: busca la tool en los esquemas publicados por `tools/list` y valida
/// `args` contra su inputSchema. Una tool que no se anuncia (p. ej.
/// `mcp_connect`, retirada por SEC2 y reservada a la cabina en T7) no se
/// valida aquí: sigue al despacho, que la rechaza con su propio mensaje.
fn validateToolArgs(allocator: std.mem.Allocator, id: i64, ctx: *const ServerCtx, name: []const u8, args: std.json.Value) !?[]u8 {
    const tools = ctx.tool_schemas.value.object.get("result").?.object.get("tools").?.array.items;
    for (tools) |tool| {
        if (!std.mem.eql(u8, tool.object.get("name").?.string, name)) continue;
        const message = (try schemaViolation(allocator, tool.object.get("inputSchema").?, args, "arguments")) orelse return null;
        defer allocator.free(message);
        return try buildErrorResp(allocator, id, -32602, message);
    }
    return null;
}

test "F0.7 (e5-b11): el esquema generico valida cada tipo y cada cota" {
    const a = std.testing.allocator;
    for ([_]struct { schema: []const u8, valid: []const u8, invalid: []const u8 }{
        .{ .schema = "{\"type\":\"string\",\"minLength\":1,\"maxLength\":2}", .valid = "\"éé\"", .invalid = "\"abc\"" },
        .{ .schema = "{\"type\":\"string\",\"minLength\":1}", .valid = "\"x\"", .invalid = "\"\"" },
        .{ .schema = "{\"type\":\"integer\",\"minimum\":0,\"maximum\":2}", .valid = "2.0", .invalid = "2.5" },
        .{ .schema = "{\"type\":\"integer\",\"minimum\":0}", .valid = "0", .invalid = "-1" },
        .{ .schema = "{\"type\":\"integer\",\"maximum\":2}", .valid = "2", .invalid = "3" },
        .{ .schema = "{\"type\":\"integer\"}", .valid = "9223372036854775807", .invalid = "9223372036854775808" },
        .{ .schema = "{\"type\":\"number\",\"minimum\":0,\"maximum\":2}", .valid = "1.25", .invalid = "\"1\"" },
        .{ .schema = "{\"type\":\"boolean\",\"enum\":[true]}", .valid = "true", .invalid = "false" },
        .{ .schema = "{\"type\":\"null\",\"enum\":[null]}", .valid = "null", .invalid = "false" },
        .{ .schema = "{\"type\":\"integer\",\"enum\":[0,1,2]}", .valid = "0.0", .invalid = "3" },
        .{ .schema = "{\"type\":\"string\",\"enum\":[\"normal\"]}", .valid = "\"normal\"", .invalid = "\"invalid\"" },
        .{ .schema = "{\"type\":\"array\",\"minItems\":1,\"maxItems\":2,\"items\":{\"type\":\"string\"}}", .valid = "[\"x\"]", .invalid = "[]" },
        .{ .schema = "{\"type\":\"array\",\"maxItems\":1}", .valid = "[]", .invalid = "[0,1]" },
        .{ .schema = "{\"type\":\"array\",\"items\":{\"type\":\"string\"}}", .valid = "[\"x\"]", .invalid = "[false]" },
        .{ .schema = "{\"type\":\"object\",\"required\":[\"x\"],\"properties\":{\"x\":{\"type\":\"string\"}}}", .valid = "{\"x\":\"a\",\"extension\":true}", .invalid = "{}" },
        .{ .schema = "{\"type\":\"object\",\"properties\":{},\"additionalProperties\":false}", .valid = "{}", .invalid = "{\"x\":0}" },
    }) |case| {
        const schema = try std.json.parseFromSlice(std.json.Value, a, case.schema, .{});
        defer schema.deinit();
        const valid = try std.json.parseFromSlice(std.json.Value, a, case.valid, .{});
        defer valid.deinit();
        const invalid = try std.json.parseFromSlice(std.json.Value, a, case.invalid, .{});
        defer invalid.deinit();
        const good = try schemaViolation(a, schema.value, valid.value, "arguments");
        defer if (good) |message| a.free(message);
        try std.testing.expect(good == null);
        const bad = try schemaViolation(a, schema.value, invalid.value, "arguments");
        defer if (bad) |message| a.free(message);
        try std.testing.expect(bad != null);
    }
}

test "F0.7 (e5-b11): argumentos que no cumplen el esquema se rechazan antes del motor" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true;
    for ([_]struct { name: []const u8, args: []const u8, field: []const u8 }{
        // Casos de la rama (tools que existían en octubre).
        .{ .name = "health", .args = "{\"provider_hint\":false}", .field = "provider_hint" },
        .{ .name = "health", .args = "null", .field = "arguments" },
        .{ .name = "health", .args = "{\"provider_hint\":null}", .field = "provider_hint" },
        .{ .name = "session_timeline", .args = "{\"order_id\":1,\"offset\":1.5}", .field = "offset" },
        .{ .name = "session_timeline", .args = "{\"order_id\":1,\"limit\":201}", .field = "limit" },
        .{ .name = "confirm_plan", .args = "{\"order_id\":1,\"plan_json\":{}}", .field = "plan_json" },
        .{ .name = "shell_run", .args = "{\"exe\":\"cmd.exe\",\"args\":[42]}", .field = "args" },
        .{ .name = "shell_run", .args = "{\"exe\":\"cmd.exe\",\"timeout_ms\":-1}", .field = "timeout_ms" },
        .{ .name = "health_probe_all", .args = "{\"max_models\":2147483648}", .field = "max_models" },
        .{ .name = "swarm_set_models", .args = "{\"models\":[{\"provider\":false,\"model\":\"x\"}]}", .field = "provider" },
        .{ .name = "swarm_set_models", .args = "{\"models\":[{},{},{},{},{},{},{},{},{}]}", .field = "models" },
        .{ .name = "order_submit", .args = "{\"order_text\":\"x\",\"attachments\":[{}]}", .field = "name" },
        .{ .name = "order_submit", .args = "{\"order_text\":\"x\",\"attachments\":[{}, {}, {}, {}, {}]}", .field = "attachments" },
        .{ .name = "da_submit_order_async", .args = "{\"order_text\":\"x\",\"best_of_n\":1}", .field = "best_of_n" },
        .{ .name = "remote_start", .args = "{\"port\":65536}", .field = "port" },
        .{ .name = "remote_start", .args = "{\"bind\":\"0.0.0.0\"}", .field = "bind" },
        .{ .name = "webhook_add", .args = "{\"url\":\"https://example.test\",\"format\":\"xml\"}", .field = "format" },
        .{ .name = "web_search", .args = "{\"query\":\"x\",\"max_results\":-1}", .field = "max_results" },
        // Tools añadidas después de octubre.
        .{ .name = "issue_read", .args = "{\"source\":\"github\",\"base_url\":\"https://github.com\",\"project\":\"o/r\",\"issue_id\":7}", .field = "issue_id" },
        .{ .name = "order_from_issue", .args = "{\"source\":\"github\",\"base_url\":\"https://github.com\",\"project\":\"o/r\",\"issue_id\":\"7\",\"attachments\":[{},{},{},{},{}]}", .field = "attachments" },
        .{ .name = "issues_list", .args = "{\"source\":\"svn\",\"base_url\":\"https://x.test\",\"project\":\"p\"}", .field = "source" },
        .{ .name = "order_progress", .args = "{\"action\":\"get\",\"order_id\":\"1\"}", .field = "order_id" },
        .{ .name = "space_create", .args = "{\"name\":\"a\",\"kind\":\"otro\"}", .field = "kind" },
        .{ .name = "authenticate", .args = "{}", .field = "token" },
    }) |case| {
        const req = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ case.name, case.args });
        defer a.free(req);
        const response = (try processRequest(a, req, &ctx)).?;
        defer a.free(response);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, response, .{});
        defer parsed.deinit();
        const failure = parsed.value.object.get("error") orelse {
            std.debug.print("ACEPTADO INVALIDO {s}: {s}\n", .{ case.name, case.args });
            return error.TestExpectedError;
        };
        try std.testing.expectEqual(@as(i64, -32602), failure.object.get("code").?.integer);
        try std.testing.expect(std.mem.indexOf(u8, failure.object.get("message").?.string, case.field) != null);
    }
}

/// Escribe un valor que cumple el esquema del campo: el primer valor del enum
/// si lo hay; si no, uno del tipo declarado que respeta las cotas publicadas.
fn writeSchemaSample(w: *std.Io.Writer, field: std.json.ObjectMap) !void {
    if (field.get("enum")) |values| return std.json.Stringify.value(values.array.items[0], .{}, w);
    const typ = field.get("type").?.string;
    if (std.mem.eql(u8, typ, "string")) return w.writeAll("\"x\"");
    if (std.mem.eql(u8, typ, "integer")) return w.writeAll("1");
    if (std.mem.eql(u8, typ, "boolean")) return w.writeAll("true");
    if (std.mem.eql(u8, typ, "array")) return w.writeAll("[]");
    if (std.mem.eql(u8, typ, "object")) return w.writeAll("{}");
    return w.writeAll("null");
}

test "F0.7: cada tool publicada hoy pasa por el validador antes del despacho" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true;
    var checked_tools: usize = 0;
    var checked_fields: usize = 0;
    for (ctx.tool_schemas.value.object.get("result").?.object.get("tools").?.array.items) |tool| {
        const name = tool.object.get("name").?.string;
        const schema = tool.object.get("inputSchema").?.object;
        const properties = schema.get("properties").?.object;
        if (properties.count() == 0) continue;
        checked_tools += 1;
        var it = properties.iterator();
        while (it.next()) |target| {
            // Todos los obligatorios con un valor válido salvo `target`, que
            // lleva un tipo equivocado: el rechazo tiene que nombrar `target`
            // y llegar antes del manejador (que respondería otra cosa).
            var args: std.Io.Writer.Allocating = .init(a);
            defer args.deinit();
            try args.writer.writeByte('{');
            for (schema.get("required").?.array.items) |required| {
                if (std.mem.eql(u8, required.string, target.key_ptr.*)) continue;
                try args.writer.print("\"{s}\":", .{required.string});
                try writeSchemaSample(&args.writer, properties.get(required.string).?.object);
                try args.writer.writeByte(',');
            }
            const wrong = if (std.mem.eql(u8, target.value_ptr.object.get("type").?.string, "string")) "0" else "\"x\"";
            try args.writer.print("\"{s}\":{s}}}", .{ target.key_ptr.*, wrong });
            const req = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{s}}}}}", .{ name, args.written() });
            defer a.free(req);
            const response = (try processRequest(a, req, &ctx)).?;
            defer a.free(response);
            const parsed = try std.json.parseFromSlice(std.json.Value, a, response, .{});
            defer parsed.deinit();
            const failure = parsed.value.object.get("error") orelse {
                std.debug.print("SIN VALIDAR {s}.{s}: {s}\n", .{ name, target.key_ptr.*, response });
                return error.TestExpectedError;
            };
            try std.testing.expectEqual(@as(i64, -32602), failure.object.get("code").?.integer);
            try std.testing.expect(std.mem.indexOf(u8, failure.object.get("message").?.string, target.key_ptr.*) != null);
            checked_fields += 1;
        }
    }
    // Cotas para que la prueba no pase vacía si cambia la forma de tools/list.
    try std.testing.expect(checked_tools >= 60);
    try std.testing.expect(checked_fields >= 150);
}

fn writeTool(js: *std.json.Stringify, name: []const u8, description: []const u8, fields: []const SchemaField) !void {
    return writeToolStrict(js, name, description, fields, false);
}

/// variante con `additionalProperties:false` anunciado. Lo que el
/// inputSchema no declara lo rechaza el despacho (`rejectUnknownArgs`), así que
/// el contrato anunciado y el comportamiento no pueden divergir.
fn writeToolStrict(js: *std.json.Stringify, name: []const u8, description: []const u8, fields: []const SchemaField, strict: bool) !void {
    try js.beginObject();
    try js.objectField("name");
    try js.write(name);
    try js.objectField("description");
    try js.write(description);
    // MCP-AUTH: marca machine-readable para que el cliente sepa que exige sesión
    // autenticada (env DEVAGENTS_MCP_TOKEN, initialize params.token o authenticate).
    if (isPrivilegedTool(name)) {
        try js.objectField("x-devagents-privileged");
        try js.write(true);
    }
    try js.objectField("inputSchema");
    try js.beginObject();
    try js.objectField("type");
    try js.write("object");
    try js.objectField("properties");
    try js.beginObject();
    for (fields) |f| {
        if (std.mem.eql(u8, f.name, "dummy")) continue;
        try js.objectField(f.name);
        try js.beginObject();
        try js.objectField("type");
        try js.write(f.typ);
        if (f.desc.len > 0) {
            try js.objectField("description");
            try js.write(f.desc);
        }
        if (f.enum_vals) |vals| {
            try js.objectField("enum");
            try js.beginArray();
            // Un enum de un campo integer se publica como números: con cadenas
            // ningún entero válido podría cumplirlo.
            for (vals) |v| {
                if (std.mem.eql(u8, f.typ, "integer")) try js.write(try std.fmt.parseInt(i64, v, 10)) else try js.write(v);
            }
            try js.endArray();
        }
        if (f.default_val) |def| {
            try js.objectField("default");
            if (std.mem.eql(u8, f.typ, "integer")) try js.write(try std.fmt.parseInt(i64, def, 10)) else try js.write(def);
        }
        inline for (.{ .{ "minimum", f.minimum }, .{ "maximum", f.maximum }, .{ "minLength", f.min_length }, .{ "maxLength", f.max_length }, .{ "maxItems", f.max_items } }) |constraint| {
            if (constraint[1]) |bound| {
                try js.objectField(constraint[0]);
                try js.write(bound);
            }
        }
        if (f.items_schema) |raw| {
            // Esquema constante del propio archivo: si no parsea es un fallo de programación.
            const item = try std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, raw, .{});
            defer item.deinit();
            try js.objectField("items");
            try js.write(item.value);
        }
        try js.endObject();
    }
    try js.endObject();
    if (strict) {
        try js.objectField("additionalProperties");
        try js.write(false);
    }
    try js.objectField("required");
    try js.beginArray();
    for (fields) |f| {
        if (f.req) try js.write(f.name);
    }
    try js.endArray();
    try js.endObject();
    try js.endObject();
}

fn buildErrorResp(allocator: std.mem.Allocator, id: i64, code: i64, message: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("jsonrpc");
    try js.write("2.0");
    try js.objectField("id");
    try js.write(id);
    try js.objectField("error");
    try js.beginObject();
    try js.objectField("code");
    try js.write(code);
    try js.objectField("message");
    try js.write(message);
    try js.endObject();
    try js.endObject();
    return allocator.dupe(u8, out.written());
}

fn buildToolResult(allocator: std.mem.Allocator, id: i64, text: []const u8, is_error: bool) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("jsonrpc");
    try js.write("2.0");
    try js.objectField("id");
    try js.write(id);
    try js.objectField("result");
    try js.beginObject();
    try js.objectField("content");
    try js.beginArray();
    try js.beginObject();
    try js.objectField("type");
    try js.write("text");
    try js.objectField("text");
    try js.write(text);
    try js.endObject();
    try js.endArray();
    try js.objectField("isError");
    try js.write(is_error);
    try js.endObject();
    try js.endObject();
    return allocator.dupe(u8, out.written());
}

// r3: prefijo que distingue en la tabla approvals las solicitudes
// que el servidor MCP registra para archivar/podar spaces (nunca ejecuta
// shell_command/worktree_script, así que no colisiona con prefixes existentes
// ni puede re-disparar un comando real vía da_approval_resolve).
const SPACES_MCP_PREFIX = "spaces_mcp";

/// r4: `resolved = 2` marca una aprobación YA CONSUMIDA por la
/// ejecución. No se usa 1 porque la cabina reserva `resolved = 1` para la
/// decisión humana; el motor trata cualquier resolved != 0 como resuelta.
const SPACES_APPROVAL_CONSUMED: i64 = 2;

/// Documentación compartida del argumento approval_id en tools/list.
const CK_MCP_001_R3_APPROVAL_DESC = "CK-MCP-001 r3/r4/r5: id de la solicitud humana registrada por la primera llamada. Ausente: SOLO registra la solicitud (isError, pendiente, nada ejecuta). Presente: ejecuta únicamente si ese humano ya concedió esta acción exacta y la aprobación no se consumió antes (es de un solo uso); en poda se podan SOLO los spaces archivados que el humano vio al aprobar (los archivados después no se tocan).";

/// Descriptor canónico (JSON) de la ACCIÓN EXACTA pedida para archivar: la
/// fase 2 compara esto contra args_json de la fila compartida, así que no sirve
/// reutilizar la aprobación de una solicitud distinta.
fn spacesArchiveDescriptor(allocator: std.mem.Allocator, space_id: i64) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, .{ .tool = "space_archive", .space_id = space_id }, .{});
}

/// r4/r5: descriptor de poda acotado. `space_ids` es el conjunto
/// de spaces archivados que el humano vio al conceder; la fase 2 poda SOLO
/// esos ids (comprobando por id que sigan archivados), así que lo archivado
/// después nunca se toca.
const SpacesPruneScope = struct {
    tool: []const u8,
    project_id: []const u8,
    space_ids: []const i64,
};

fn spacesPruneDescriptor(allocator: std.mem.Allocator, project_id: []const u8, space_ids: []const i64) ![]u8 {
    return try std.json.Stringify.valueAlloc(allocator, SpacesPruneScope{
        .tool = "spaces_prune",
        .project_id = project_id,
        .space_ids = space_ids,
    }, .{});
}

/// La fila registrada corresponde a ESTA poda (misma tool y mismo proyecto).
/// El snapshot de ids no se compara aquí: se valida al ejecutar.
fn spacesPruneScopeMatches(allocator: std.mem.Allocator, stored: ?[]const u8, project_id: []const u8) bool {
    const text = stored orelse return false;
    var scope = std.json.parseFromSlice(SpacesPruneScope, allocator, text, .{ .ignore_unknown_fields = true }) catch return false;
    defer scope.deinit();
    return std.mem.eql(u8, scope.value.tool, "spaces_prune") and
        std.mem.eql(u8, scope.value.project_id, project_id);
}

/// La fila registrada corresponde a ESTE archivado (tool y space_id exactos).
fn spacesArchiveMatches(allocator: std.mem.Allocator, stored: ?[]const u8, space_id: i64) bool {
    const text = stored orelse return false;
    const wanted = spacesArchiveDescriptor(allocator, space_id) catch return false;
    defer allocator.free(wanted);
    return std.mem.eql(u8, text, wanted);
}

/// Respuesta uniforme cuando el approval_id no es la acción exacta pedida.
fn spacesApprovalMismatchResp(allocator: std.mem.Allocator, id: i64, aid: i64) ![]u8 {
    const msg = try std.fmt.allocPrint(allocator,
        \\{{"approval_id":{d},"status":"mismatch","message":"la solicitud y la accion no corresponden: el approval_id registrado no es exactamente esta accion (misma tool, mismos argumentos). Consulta approvals_list; el motor no se toco."}}
    , .{aid});
    defer allocator.free(msg);
    return try buildToolResult(allocator, id, msg, true);
}

/// Texto de una columna de `approvals`, tolerante a NULL (args_json/exe lo son).
fn sqliteColumnText(stmt: *core.db.c.sqlite3_stmt, col: c_int) []const u8 {
    const ptr = core.db.c.sqlite3_column_text(stmt, col) orelse return "";
    const len: usize = @intCast(core.db.c.sqlite3_column_bytes(stmt, col));
    return ptr[0..len];
}

//: contrato de las tres tools de spaces, idéntico al puente
// de la cabina (shell/host/bridge.cpp:3265-3328) y a las validaciones del motor
// (core/src/spaces.zig:262 nombres, c_api.zig:8602 kind order/main-checkout).
// El MISMO array alimenta el inputSchema anunciado y el rechazo de argumentos
// desconocidos en despacho: una sola fuente para anunciar y para validar.
const SPACE_CREATE_FIELDS = [_]SchemaField{
    .{ .name = "project_id", .typ = "string", .req = false, .desc = "Proyecto del space; default si ausente.", .default_val = "default" },
    .{ .name = "name", .typ = "string", .req = true, .desc = "Nombre ASCII 1..64 (letras o dígitos, '-' y '_'); sin puntos, separadores ni nombres reservados de Windows." },
    .{ .name = "kind", .typ = "string", .req = false, .desc = "order (default) o main-checkout.", .enum_vals = &.{ "order", "main-checkout" }, .default_val = "order" },
};
const SPACE_ARCHIVE_FIELDS = [_]SchemaField{
    .{ .name = "space_id", .typ = "integer", .req = true, .desc = "ID numérico del space (fila spaces.id, > 0)." },
    .{ .name = "approval_id", .typ = "integer", .req = false, .desc = CK_MCP_001_R3_APPROVAL_DESC },
};
const SPACES_PRUNE_FIELDS = [_]SchemaField{
    .{ .name = "project_id", .typ = "string", .req = false, .desc = "Proyecto a podar; default si ausente.", .default_val = "default" },
    .{ .name = "approval_id", .typ = "integer", .req = false, .desc = CK_MCP_001_R3_APPROVAL_DESC },
};

fn buildToolsListResp(allocator: std.mem.Allocator, id: i64) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };

    try js.beginObject();
    try js.objectField("jsonrpc");
    try js.write("2.0");
    try js.objectField("id");
    try js.write(id);
    try js.objectField("result");
    try js.beginObject();
    try js.objectField("tools");
    try js.beginArray();

    // MCP-AUTH: autenticación de sesión para tools privilegiadas.
    try writeTool(&js, "authenticate", "Autentica la sesión MCP con el token del servidor (panel MCP de DevAgents o DEVAGENTS_MCP_TOKEN). Sin auth las tools mutadoras/privilegiadas responden is_error.", &.{
        .{ .name = "token", .typ = "string", .req = true, .desc = "Token de autenticación del servidor." },
    });

    // Lectura
    try writeTool(&js, "health", "Salud detallada de modelos (por proveedor/modelo).", &.{
        .{ .name = "provider_hint", .typ = "string", .req = false, .desc = "Filtrar por proveedor (opcional)." },
    });
    try writeTool(&js, "health_probe_all", "Probe activo de modelos free generativos y actualizacion de model_health.", &.{
        .{ .name = "max_models", .typ = "integer", .req = false, .desc = "Maximo de modelos a probar (0=todos).", .minimum = 0, .maximum = c_int_max },
    });
    try writeTool(&js, "catalog_info", "Informacion del catalogo cargado (ruta, conteos). Sin claves.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "router_candidates", "Candidatos del router para un tipo de tarea.", &.{
        .{ .name = "task_type", .typ = "string", .req = true, .desc = "Tipo de tarea (p. ej. programar, auditar)." },
    });
    try writeTool(&js, "sessions", "Lista ordenes/sesiones activas con estado.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "session_messages", "Mensajes de una sesion (rehidratacion de chat).", &.{
        .{ .name = "order_id", .typ = "integer", .req = true, .desc = "ID numerico de la orden/sesion." },
    });
    try writeTool(&js, "session_timeline", "Timeline completo de una sesion para replay (mensajes + eventos + metadatos).", &.{
        .{ .name = "order_id", .typ = "integer", .req = true, .desc = "ID numerico de la orden/sesion." },
        .{ .name = "offset", .typ = "integer", .req = false, .desc = "Offset de paginacion (default 0).", .minimum = 0 },
        .{ .name = "limit", .typ = "integer", .req = false, .desc = "Maximo de items por pagina (default 50, max 200).", .minimum = 0, .maximum = 200 },
    });
    try writeTool(&js, "order_status", "Estado de una orden especifica.", &.{
        .{ .name = "order_id", .typ = "integer", .req = true, .desc = "ID numerico de la orden." },
    });
    try writeTool(&js, "order_events", "Timeline de eventos de una orden (polling incremental).", &.{
        .{ .name = "order_id", .typ = "integer", .req = true, .desc = "ID numerico de la orden." },
        .{ .name = "since_event_id", .typ = "integer", .req = false, .desc = "Solo eventos con id mayor que este valor." },
    });
    try writeTool(&js, "get_plan", "Obtener el plan de una orden en JSON.", &.{
        .{ .name = "order_id", .typ = "integer", .req = true, .desc = "ID numerico de la orden." },
    });
    try writeTool(&js, "repo_search", "Busqueda sobre el repo con tres motores: 'bm25' = ranking lexico (simbolo+ventana, pliegue camelCase/snake, peso ruta/simbolo); 'semantic' = ranking PURAMENTE vectorial por coseno (solo trozos con vector; el coseno es el score); 'hybrid' = fusion RRF de BM25 con el ranking por coseno del indice vectorial persistente (o rerank del pool live si no hay indice). Devuelve {query_mode:'bm25'|'semantic'|'hybrid', semantic_status, index?{state,chunks_indexed,files_indexed,model,updated_at}, truncated, files_scanned, matches:[{path,line,snippet,score,source}]} — cada match declara su procedencia: 'bm25', 'vector' (solo semantico: BM25=0) o 'bm25+vector'. Sin capa semantica configurada sale bm25 + semantic_status con la razon honesta.", &.{
        .{ .name = "query", .typ = "string", .req = true, .desc = "Texto libre de la consulta." },
        .{ .name = "root", .typ = "string", .req = false, .desc = "Raiz del repo (default = raiz efectiva del workspace)." },
        .{ .name = "max_results", .typ = "integer", .req = false, .desc = "Maximo de resultados (default=20, max=100)." },
        .{ .name = "mode", .typ = "string", .req = false, .desc = "'bm25' (default) | 'semantic' (vectorial puro) | 'hybrid' (RRF BM25+coseno sobre el indice vectorial; solo si embeddings_config lo habilita — si no, bm25 + semantic_status honesto).", .enum_vals = &.{ "bm25", "semantic", "hybrid" } },
    });
    try writeTool(&js, "embeddings_config_get", "Config de la capa semantica E5.15 {enabled, provider, model}. enabled=true autoriza a enviar chunks del repo al endpoint de embeddings del proveedor.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "embeddings_config_set", "Fija la capa semantica desde JSON parcial {enabled?, provider?, model?} (claves ausentes conservan el valor; provider debe ser del catalogo con api_style soportado — openai/cohere/nvidia_nim/google_gemini — y clave activa). PRIVILEGIADA: autoriza el envio de contenido del repo a un endpoint cloud.", &.{
        .{ .name = "json", .typ = "string", .req = true, .desc = "JSON parcial, p.ej. {\"enabled\":true,\"provider\":\"NVIDIA API\",\"model\":\"nvidia/nv-embedqa-e5-v5\"}." },
    });
    try writeTool(&js, "repo_embed_index", "E5.15: construye/actualiza el indice vectorial persistente del repo (tabla repo_embeddings). Incremental: solo re-embebe los trozos cuyo hash cambio; borra los obsoletos; por lotes con la puerta de presupuesto y reintento 429. Requiere embeddings_config habilitado. Devuelve {indexed, reason?, model, files_scanned, chunks_total, embedded, reused, removed, batches, dim, elapsed_ms, retries_429, error?}. PRIVILEGIADA: envia contenido del repo al proveedor.", &.{
        .{ .name = "root", .typ = "string", .req = false, .desc = "Raiz del repo (default = raiz efectiva del workspace)." },
    });
    try writeTool(&js, "repo_embed_status", "E5.15: estado del indice vectorial del repo. {root?, model?} → {state:'empty'|'ready', chunks_indexed, files_indexed, model, updated_at}. Sin model informa el indice mas reciente.", &.{
        .{ .name = "root", .typ = "string", .req = false, .desc = "Raiz del repo (default = raiz efectiva del workspace)." },
        .{ .name = "model", .typ = "string", .req = false, .desc = "Modelo de embeddings concreto (default = el del indice mas reciente)." },
    });
    try writeTool(&js, "embeddings_probe", "E5.15: sondeo EN VIVO de cap_embeddings para (provider, model) — una llamada real con presupuesto y reintento 429; persiste cap_embeddings_*='live_probe' solo si el endpoint respondio (yes|no; auth/quota/red no se persisten). {provider?, model?} — sin args usa embeddings_config → {ok, status:'yes'|'no'|'unmeasured', dim?, elapsed_ms, retries_429, reason?}. PRIVILEGIADA: llamada real al proveedor.", &.{
        .{ .name = "provider", .typ = "string", .req = false, .desc = "Proveedor del catalogo (default = el de embeddings_config)." },
        .{ .name = "model", .typ = "string", .req = false, .desc = "Modelo de embeddings (default = el de embeddings_config)." },
    });
    try writeTool(&js, "best_of_n_candidates", "E5.18: candidatas de una orden best-of-N con métricas (gates, pruebas, veredicto, coste en tokens, ms) y rank — la tabla comparativa. Solo si la orden se envió con best_of_n=2..4.", &.{
        .{ .name = "order_id", .typ = "integer", .req = true, .desc = "ID numerico de la orden padre." },
    });
    try writeTool(&js, "best_of_n_choose", "E5.18: elige la candidata ganadora — aplica sus cambios al worktree de la orden padre, archiva las perdedoras y cierra la orden en done. Solo con la orden en awaiting_best_of_n. PRIVILEGIADA: muta el arbol de trabajo.", &.{
        .{ .name = "order_id", .typ = "integer", .req = true, .desc = "ID numerico de la orden padre." },
        .{ .name = "candidate_id", .typ = "integer", .req = true, .desc = "ID de la candidata (campo id de best_of_n_candidates)." },
    });
    try writeTool(&js, "approvals_list", "Aprobaciones pendientes.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });

    // Accion
    try writeTool(&js, "da_submit_order", "Enviar una orden en lenguaje natural al superagente (síncrono, bloquea hasta terminar).", &.{
        .{ .name = "attachments", .typ = "array", .req = false, .desc = "E5.23: hasta 4 imagenes {name,data_base64}, PNG/JPEG/WebP por bytes, 5 MiB cada una.", .max_items = 4, .items_schema = image_item_schema },
        .{ .name = "order_text", .typ = "string", .req = true, .desc = "Texto de la orden." },
        .{ .name = "project_id", .typ = "string", .req = false, .desc = "Identificador del proyecto (default='default')." },
        .{ .name = "conversation_id", .typ = "string", .req = false, .desc = "Hilo de conversación (loop agéntico): si se provee, el planner recupera el historial real de TODAS las órdenes previas de este mismo hilo." },
        .{ .name = "best_of_n", .typ = "integer", .req = false, .desc = "E5.18: N candidatas paralelas (2..4) de proveedores distintos, cada una en su worktree; el usuario elige la ganadora y su diff se fusiona a la orden.", .enum_vals = &.{ "0", "2", "3", "4" } },
        .{ .name = "best_of_n_members", .typ = "string", .req = false, .desc = "JSON [{provider,model}] con la lista explicita de miembros (default: N primeros miembros usables del enjambre, proveedores distintos)." },
    });
    try writeTool(&js, "da_submit_order_async", "Enviar una orden de forma asíncrona (no bloquea). Retorna order_id inmediatamente; consultar con plan_poll.", &.{
        .{ .name = "attachments", .typ = "array", .req = false, .desc = "E5.23: imagenes {name,data_base64}, mismas cotas que la cabina.", .max_items = 4, .items_schema = image_item_schema },
        .{ .name = "order_text", .typ = "string", .req = true, .desc = "Texto de la orden." },
        .{ .name = "project_id", .typ = "string", .req = false, .desc = "Identificador del proyecto (default='default')." },
        .{ .name = "conversation_id", .typ = "string", .req = false, .desc = "Hilo de conversación (loop agéntico): si se provee, el planner recupera el historial real de TODAS las órdenes previas de este mismo hilo." },
        .{ .name = "best_of_n", .typ = "integer", .req = false, .desc = "E5.18: N candidatas paralelas (2..4) de proveedores distintos, cada una en su worktree; el usuario elige la ganadora y su diff se fusiona a la orden.", .enum_vals = &.{ "0", "2", "3", "4" } },
        .{ .name = "best_of_n_members", .typ = "string", .req = false, .desc = "JSON [{provider,model}] con la lista explicita de miembros (default: N primeros miembros usables del enjambre, proveedores distintos)." },
    });
    try writeTool(&js, "vision_probe", "E5.24: medir vision con PNG rojo/azul, solo nube gratuita. Llamada real explicita; fallos de entorno no miden capacidad.", &.{
        .{ .name = "provider", .typ = "string", .req = true, .desc = "Proveedor." },
        .{ .name = "model", .typ = "string", .req = true, .desc = "Modelo exacto." },
    });
    try writeTool(&js, "order_submit", "E5.23: envio asincrono con adjuntos validados por el motor; consultar plan_poll.", &.{
        .{ .name = "order_text", .typ = "string", .req = true, .desc = "Texto de la orden." },
        .{ .name = "project_id", .typ = "string", .req = false, .desc = "Proyecto." },
        .{ .name = "conversation_id", .typ = "string", .req = false, .desc = "Hilo." },
        .{ .name = "attachments", .typ = "array", .req = false, .desc = "Hasta 4 {name,data_base64}; PNG/JPEG/WebP, 5 MiB por imagen.", .max_items = 4, .items_schema = image_item_schema },
    });
    try writeTool(&js, "order_attachments", "E5.23: listar metadatos de imagenes conservadas en la orden.", &.{
        .{ .name = "order_id", .typ = "integer", .req = true, .desc = "ID de orden." },
    });
    try writeTool(&js, "plan_poll", "Consulta si la planificación asíncrona ha terminado.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "confirm_plan", "Guardar/confirmar el plan de una orden (sin despachar). Por MCP no es aprobacion humana: los comandos de la orden siguen pidiendo tarjeta en la cabina.", &.{
        .{ .name = "order_id", .typ = "integer", .req = true, .desc = "ID numerico de la orden." },
        .{ .name = "plan_json", .typ = "string", .req = false, .desc = "Plan editado JSON (si se omite, aprueba el plan actual)." },
    });
    try writeTool(&js, "answer_order", "Responder preguntas de clarificacion de una orden en estado clarifying.", &.{
        .{ .name = "order_id", .typ = "integer", .req = true, .desc = "ID numerico de la orden." },
        .{ .name = "answers_json", .typ = "string", .req = true, .desc = "JSON array de objetos {question_id, answer}." },
    });
    try writeTool(&js, "shell_run", "Ejecutar un comando gobernado. Las consultas de solo lectura que la politica exime corren y devuelven su salida; el resto requiere aprobacion humana en la cabina y devuelve approval_id sin ejecutar (el resultado se recoge con approval_result). Raiz por defecto: la carpeta de trabajo de DevAgents (<proyecto>/devagents-workspace); con root='project', la carpeta del proyecto elegida.", &.{
        .{ .name = "exe", .typ = "string", .req = true, .desc = "Ejecutable (debe estar en allowlist)." },
        .{ .name = "args", .typ = "array", .req = false, .desc = "Argumentos como array de strings.", .items_schema = string_item_schema },
        .{ .name = "cwd", .typ = "string", .req = false, .desc = "Directorio de trabajo relativo a la raiz (default='.')." },
        .{ .name = "root", .typ = "string", .req = false, .desc = "Raiz del sandbox: 'workspace' (default, devagents-workspace) o 'project' (la carpeta del proyecto, como el modo Directo). Mismas reglas de aprobacion.", .enum_vals = &.{ "workspace", "project" } },
        .{ .name = "timeout_ms", .typ = "integer", .req = false, .desc = "Timeout en milisegundos (default=30000).", .minimum = 0, .maximum = c_int_max },
    });
    try writeTool(&js, "run_detached", "Lanza apps GUI/scripts como proceso independiente tras aprobacion humana por comando desde UI. Solo versiones acotadas se ejecutan directamente; devuelve approval_id pendiente o PID. MCP no puede aprobar.", &.{
        .{ .name = "exe", .typ = "string", .req = true, .desc = "Ejecutable (debe estar en allowlist)." },
        .{ .name = "args", .typ = "array", .req = false, .desc = "Argumentos como array de strings.", .items_schema = string_item_schema },
        .{ .name = "cwd", .typ = "string", .req = false, .desc = "Directorio de trabajo (default='.')." },
    });
    try writeTool(&js, "ui_action", "Pide a la cabina de DevAgents una accion cosmetica sobre la UI: cambiar tema, abrir una vista, enfocar una sesion o mostrar una notificacion. Solo acciones del allowlist; la cabina reporta el resultado como evento ui_action_result.", &.{
        .{ .name = "action", .typ = "string", .req = true, .desc = "Accion a aplicar.", .enum_vals = &.{ "set_theme", "open_view", "focus_session", "notify", "open_window" } },
        .{ .name = "args", .typ = "object", .req = false, .desc = "Argumentos de la accion: {theme, view, session_id, text} segun la accion." },
        .{ .name = "order_id", .typ = "integer", .req = false, .desc = "Orden asociada (0/omitido = accion global)." },
    });
    try writeTool(&js, "discover_models", "Descubrimiento vivo de modelos para cada proveedor con clave activa.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "catalog_reconcile_enabled", "Recalcula que proveedores estan habilitados segun claves activas AHORA (solo lee api_keys, nunca las modifica). Usar tras anadir/quitar claves para que catalog_info/models_list dejen de contar proveedores sin clave.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });

    // Despacho asíncrono + polling de salidas (F0)
    try writeTool(&js, "dispatch_async", "Despacha una orden planeada en segundo plano (no bloquea). Por MCP, solo las consultas de version se ejecutan solas; el resto de comandos y los agentes externos requieren la cabina.", &.{
        .{ .name = "order_id", .typ = "integer", .req = true, .desc = "ID numerico de la orden." },
    });
    try writeTool(&js, "dispatch_poll", "Consulta si un despacho asíncrono ha terminado.", &.{
        .{ .name = "order_id", .typ = "integer", .req = true, .desc = "ID numerico de la orden." },
    });
    try writeTool(&js, "worker_output", "Polling incremental de salidas de workers desde un timestamp.", &.{
        .{ .name = "since_ms", .typ = "integer", .req = false, .desc = "Solo salidas con ts > since_ms (default=0)." },
    });
    try writeTool(&js, "dispatch_cancel", "Cancela un despacho activo de la orden.", &.{
        .{ .name = "order_id", .typ = "integer", .req = true, .desc = "ID numerico de la orden." },
    });
    try writeTool(&js, "plan_cancel", "PLAN-CANCEL: cancela la planificacion EN CURSO (submit/answer async). La orden queda 'cancelled'; sin order_id cancela la planificacion actual.", &.{
        .{ .name = "order_id", .typ = "integer", .req = false, .desc = "ID de la orden que se esta planificando (omitir = la actual)." },
    });

    // Ship Flow B3: plan -> revision -> PR -> merge sobre `gh` real.
    try writeTool(&js, "issues_list", "E5.27: lista la primera pagina de incidencias de GitHub, Gitea, GitLab, Linear o Jira Cloud. Usa credenciales del almacen vinculadas a fuente/host; no devuelve secretos.", &.{
        .{ .name = "source", .typ = "string", .req = true, .desc = "github | gitea | gitlab | linear | jira", .enum_vals = &.{ "github", "gitea", "gitlab", "linear", "jira" } },
        .{ .name = "base_url", .typ = "string", .req = true, .desc = "Raiz HTTPS registrada del proveedor." },
        .{ .name = "project", .typ = "string", .req = true, .desc = "owner/repo, namespace/project, equipo Linear o clave de proyecto Jira." },
        .{ .name = "fixture", .typ = "boolean", .req = false, .desc = "Fuente sintetica, solo con DEVAGENTS_ISSUES_FIXTURE=1." },
    });
    inline for (.{ "issue_read", "issue_prompt", "issue_comment", "order_from_issue" }) |tool_name| {
        try writeTool(&js, tool_name, "E5.27: referencia de incidencia validada por el motor. issue_read lee; issue_prompt cita como dato no confiable; issue_comment requiere text y explicit=true; order_from_issue crea orden asincrona y conserva el vinculo antes de iniciar el planificador. El envoltorio no garantiza el comportamiento del modelo.", &.{
            .{ .name = "source", .typ = "string", .req = true, .desc = "github | gitea | gitlab | linear | jira", .enum_vals = &.{ "github", "gitea", "gitlab", "linear", "jira" } },
            .{ .name = "base_url", .typ = "string", .req = true, .desc = "Raiz HTTPS registrada del proveedor." },
            .{ .name = "project", .typ = "string", .req = true, .desc = "Identificador de proyecto." },
            .{ .name = "issue_id", .typ = "string", .req = true, .desc = "Numero/identificador de incidencia." },
            .{ .name = "instruction", .typ = "string", .req = false, .desc = "Instruccion del usuario para order_from_issue; cuerpo remoto siempre citado por motor." },
            .{ .name = "attachments", .typ = "array", .req = false, .desc = "Imagenes PNG/JPEG/WebP para order_from_issue; mismas cotas y validacion que order_submit.", .max_items = 4, .items_schema = image_item_schema },
            .{ .name = "project_id", .typ = "string", .req = false, .desc = "Proyecto de la orden; default si ausente." },
            .{ .name = "conversation_id", .typ = "string", .req = false, .desc = "Conversacion de la orden." },
            .{ .name = "text", .typ = "string", .req = false, .desc = "Texto del comentario explicito." },
            .{ .name = "explicit", .typ = "boolean", .req = false, .desc = "Debe ser true para comentar; nunca automatico." },
            .{ .name = "fixture", .typ = "boolean", .req = false, .desc = "Fuente sintetica autorizada por variable de entorno." },
        });
    }
    try writeTool(&js, "ship_order", "Empaqueta una orden done en un PR/MR real: sella la rama, push guardado y REST GitHub/GitLab/Gitea (o adopta el abierto). gh es alternativa opcional. Conserva el enlace a la incidencia importada.", &.{
        .{ .name = "order_id", .typ = "integer", .req = true, .desc = "ID numerico de la orden (debe estar done)." },
    });
    try writeTool(&js, "pr_merge", "Fusiona un PR via gh pr merge y relee su estado real con gh pr view. Devuelve {merged,state}.", &.{
        .{ .name = "pr_id", .typ = "integer", .req = true, .desc = "ID de la fila pull_requests (no el numero de GitHub)." },
    });
    try writeTool(&js, "prs_list", "PRs persistidos del ship flow (tabla pull_requests, refrescada por el poller en segundo plano).", &.{
        .{ .name = "order_id", .typ = "integer", .req = false, .desc = "Filtrar por orden (0/omitido = todos)." },
    });
    try writeTool(&js, "repo_clone", "Clona un repositorio https:// o git@host:ruta con git clone real, solo dentro de la raíz del workspace.", &.{
        .{ .name = "url", .typ = "string", .req = true, .desc = "URL del repositorio." },
        .{ .name = "target_dir", .typ = "string", .req = true, .desc = "Directorio destino (no debe existir)." },
    });

    // Seleccion de modelo para planificacion (F7-MODEL-SELECT)
    try writeTool(&js, "plan_set_model", "Fijar modelo para planificacion (provider+model). Vacia = router automatico.", &.{
        .{ .name = "provider", .typ = "string", .req = false, .desc = "Proveedor (vacio = automatico)." },
        .{ .name = "model", .typ = "string", .req = false, .desc = "Modelo (vacio = automatico)." },
    });
    try writeTool(&js, "plan_get_model", "Consulta el modelo forzado para planificacion.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    // ROLES-MODELO: pins por rol. Vacios = heredan el pin de la orden
    // (plan_set_model). El auditor nunca hereda el pin del ejecutor.
    try writeTool(&js, "exec_set_model", "Fijar modelo del EJECUTOR (tareas constructoras/correcciones). Vacio = sigue al de la orden.", &.{
        .{ .name = "provider", .typ = "string", .req = false, .desc = "Proveedor (vacio = hereda el de la orden)." },
        .{ .name = "model", .typ = "string", .req = false, .desc = "Modelo (vacio = hereda el de la orden)." },
    });
    try writeTool(&js, "exec_get_model", "Consulta el modelo forzado del ejecutor (vacio = sigue al de la orden).", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "audit_set_model", "Fijar modelo del AUDITOR (solo tareas de auditoria). Vacio = sigue al de la orden; nunca hereda el del ejecutor.", &.{
        .{ .name = "provider", .typ = "string", .req = false, .desc = "Proveedor (vacio = hereda el de la orden)." },
        .{ .name = "model", .typ = "string", .req = false, .desc = "Modelo (vacio = hereda el de la orden)." },
    });
    try writeTool(&js, "audit_get_model", "Consulta el modelo forzado del auditor (vacio = sigue al de la orden).", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    // ENJAMBRE: conjunto cerrado de modelos para las tareas productoras.
    // [] = Automatico (router decide por tarea); maximo 8 miembros.
    try writeTool(&js, "swarm_set_models", "Fijar el ENJAMBRE: conjunto cerrado de modelos que se reparten las tareas productoras en paralelo. [] = Automatico (router).", &.{
        .{ .name = "models", .typ = "array", .req = true, .desc = "Array de {provider,model}. [] = Automatico. Maximo 8.", .max_items = 8, .items_schema = model_item_schema },
    });
    try writeTool(&js, "swarm_get_models", "Consulta el enjambre fijado ([{provider,model}]; [] = Automatico).", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    // E5.08 — GOBIERNO ENCIMA: registro de agentes externos (CLI del usuario,
    // cobran por SU suscripcion — jamas clave API). Los ids `agent:*` valen en
    // swarm_set_models / *_set_model como provider y van por la rama gobernada
    // del despacho (worktree + sandbox + auditoria + ledger).
    try writeTool(&js, "paid_budget_get", "Cupo de pago actual: authorized, spent, remaining. Suscripcion y gratis no consumen llamadas de pago.", &.{});
    try writeTool(&js, "order_preflight", "Conflictos de modelos y gobernanza antes de enviar. allowed, issues por rol, determinismo y aviso de cuota de suscripcion. No llama proveedores.", &.{});
    try writeTool(&js, "agents_external_list", "Agentes instalados: [{provider,cli,exe,version,session,selection_reason,detected_at_ms,enumeration_status,authenticode,authenticode_code,acl_appcontainer_sids,models:[{slug,display_name,manufacturer,reasoning_efforts,reasoning_effort}]}]. Cache 5 minutos; sin inferencia. api_key bloqueado; no_enumerable ofrece default.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "agents_external_refresh", "E5.55: redetect binaries, versions, models and sessions without inference; refresh five-minute cache.", &.{.{ .name = "dummy", .typ = "null", .req = false, .desc = "" }});
    try writeTool(&js, "external_paths_get", "Read optional external_agent_paths CLI overrides.", &.{.{ .name = "dummy", .typ = "null", .req = false, .desc = "" }});
    try writeTool(&js, "external_model_options_set", "Set detected model pin reasoning_effort; validated against its declared levels.", &.{.{ .name = "json", .typ = "string", .req = true, .desc = "{provider,model,reasoning_effort}" }});
    try writeTool(&js, "external_limits_get", "Limites vigentes de los agentes externos: {task_timeout_ms,task_max_turns,order_timeout_ms,order_max_turns} (0 = sin tope).", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "models_list", "Lista todos los modelos disponibles en el catalogo.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "models_selection_v1", "CK-PRV-004: capacidades de texto, gratuidad y permisos persistentes por modelo; no hace sondeos.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "models_preferences_set_v1", "CK-PRV-004: guarda Mostrar en selectores y Permitir al router/enjambre. Devuelve el preflight con aviso si falta auditor independiente; conserva los pines manuales. PRIVILEGIADA.", &.{
        .{ .name = "json", .typ = "string", .req = true, .desc = "JSON {provider,model,show_in_selectors:boolean,allow_automatic:boolean}; modelo conocido." },
    });

    // Gestion de claves API (KEY-MGMT): el usuario administra claves desde Configuracion
    // a traves del engine YA corriendo, sin lanzar key-admin.exe (que abria catalog.db con
    // un esquema desfasado -> DbSchemaAhead).
    try writeTool(&js, "add_key", "Anade una clave API a un proveedor (con etiqueta opcional para multi-cuenta).", &.{
        .{ .name = "provider", .typ = "string", .req = true, .desc = "Nombre EXACTO del proveedor (p. ej. 'NVIDIA API')." },
        .{ .name = "key", .typ = "string", .req = true, .desc = "La clave API." },
        .{ .name = "label", .typ = "string", .req = false, .desc = "Etiqueta (p. ej. 'cuenta-1'). Default 'default'." },
    });
    try writeTool(&js, "remove_key", "Elimina claves de un proveedor (una etiqueta, o todas si se omite).", &.{
        .{ .name = "provider", .typ = "string", .req = true, .desc = "Nombre EXACTO del proveedor." },
        .{ .name = "label", .typ = "string", .req = false, .desc = "Etiqueta a borrar; vacio = borra TODAS las del proveedor." },
    });
    try writeTool(&js, "list_keys", "Lista las claves registradas (sin el secreto): [{provider,label,status}].", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });

    // MCP / Skills / Mounts (PANEL-ADDONS)
    // SEC2: mcp_connect lanza un argv arbitrario como proceso hijo; no se anuncia
    // a clientes MCP y el nucleo lo rechaza (da_mcp_connect con mcp_surface).
    try writeTool(&js, "mcp_disconnect", "Desconectar del servidor MCP.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "mcp_is_connected", "Consulta estado de conexion MCP.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "mcp_tools", "Lista las tools del servidor MCP conectado.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "mcp_call_tool", "Llama una tool del servidor MCP conectado.", &.{
        .{ .name = "name", .typ = "string", .req = true, .desc = "Nombre de la tool." },
        .{ .name = "args_json", .typ = "string", .req = true, .desc = "Argumentos como objeto JSON string." },
    });
    // P2: Persistencia de archivos
    try writeTool(&js, "set_workspace_root", "Estrecha la raíz del workspace a una subcarpeta de la actual. Cambiarla a otra carpeta requiere la cabina o DEVAGENTS_WORKSPACE_ROOT al lanzar devagents-mcp.", &.{
        .{ .name = "path", .typ = "string", .req = true, .desc = "Ruta absoluta o relativa para el workspace." },
    });
    //: paridad con core.space.create/archive/spaces.prune del
    // puente (bridge.cpp:3265-3328). Esquema estricto anunciado
    // (additionalProperties:false) y rechazo real de claves no declaradas.
    try writeToolStrict(&js, "space_create", "Crea un space manual (worktree devagents/<name> o directorio aislado sin git) y devuelve su ficha. Mismo contrato que core.space.create de la cabina.", &SPACE_CREATE_FIELDS, true);
    try writeToolStrict(&js, "space_archive", "Archiva un space: retira su worktree y sella archivedAt; la fila se borra con spaces_prune. Exige aprobacion humana en dos fases: sin approval_id registra la solicitud (el humano la ve y decide en la cabina) y devuelve el id; con approval_id ejecuta solo si fue concedida y aun no consumida (un solo uso).", &SPACE_ARCHIVE_FIELDS, true);
    try writeToolStrict(&js, "spaces_prune", "Poda los spaces ya archivados del proyecto: borra sus filas y limpia worktrees/ramas colgantes. Exige aprobacion humana en dos fases: sin approval_id registra la solicitud con el conjunto exacto de spaces archivados que el humano ve; con approval_id ejecuta solo si fue concedida, aun no consumida y ese conjunto no cambio (lo archivado despues no se poda).", &SPACES_PRUNE_FIELDS, true);
    try writeToolStrict(&js, "order_progress", "order_progress.v1: lee (get) o escribe (set) avance por orden. set exige autenticacion, expected_seq de lectura previa, state y note (maximo 2 KiB); autor agent fijado por el servidor. La nota humana se conserva.", &ORDER_PROGRESS_FIELDS, true);
    try writeTool(&js, "list_artifacts", "Lista los artefactos generados (archivos). Si order_id=0, lista todas las órdenes.", &.{
        .{ .name = "order_id", .typ = "integer", .req = false, .desc = "ID de la orden (0 = todas)." },
    });
    try writeTool(&js, "skills_discover", "Descubre skills de los mounts activos.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    // P12-T1: Inventario unificado
    try writeTool(&js, "inventory", "Devuelve el inventario unificado (skills + MCPs + plugins + webhooks) con cost y source.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "inventory_refresh", "Invalida el cache del inventario y fuerza re-escaneo.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "webhooks_list", "Lista avisos salientes sin exponer secretos.", &.{});
    try writeTool(&js, "remote_start", "El acceso remoto se inicia desde la cabina, donde se muestra el token. Desde MCP esta herramienta solo valida los argumentos y responde con esa indicación: MCP no devuelve credenciales.", &.{
        .{ .name = "port", .typ = "integer", .req = false, .desc = "Puerto 0 (libre aleatorio) o 1–65535.", .minimum = 0, .maximum = 65535 },
        .{ .name = "bind", .typ = "string", .req = false, .desc = "Solo 127.0.0.1.", .enum_vals = &.{"127.0.0.1"} },
        .{ .name = "origin", .typ = "string", .req = false, .desc = "Origen HTTPS del túnel permitido, adicional a loopback." },
    });
    try writeTool(&js, "remote_stop", "Apaga el listener remoto de esta sesión MCP.", &.{});
    try writeTool(&js, "remote_status", "Estado y URL de la web remota; nunca devuelve el token.", &.{});
    try writeTool(&js, "webhook_add", "Configura un aviso saliente HTTP o ntfy. El secreto se cifra en el motor.", &.{
        .{ .name = "url", .typ = "string", .req = true, .desc = "URL HTTP(S), sin credenciales ni query; ntfy incluye topic." },
        .{ .name = "event", .typ = "string", .req = false, .desc = "* o estado de orden; por defecto *." },
        .{ .name = "format", .typ = "string", .req = false, .desc = "json o ntfy.", .enum_vals = &.{ "json", "ntfy" } },
        .{ .name = "secret", .typ = "string", .req = false, .desc = "Secreto HMAC opcional; no se devuelve." },
        .{ .name = "allow_private", .typ = "boolean", .req = false, .desc = "Por defecto false. Advertencia: true permite loopback, redes privadas y metadatos para este webhook. No se siguen redirecciones." },
    });
    try writeTool(&js, "webhook_delete", "Quita un aviso saliente.", &.{.{ .name = "id", .typ = "integer", .req = true, .desc = "Id del aviso." }});
    try writeTool(&js, "webhook_test", "Encola una prueba asíncrona del aviso; no acredita entrega hasta recibirla.", &.{.{ .name = "id", .typ = "integer", .req = true, .desc = "Id del aviso." }});
    try writeTool(&js, "mount_add", "Anade un path al registry de mounts.", &.{
        .{ .name = "path", .typ = "string", .req = true, .desc = "Ruta absoluta o relativa al workspace." },
    });
    try writeTool(&js, "mounts_list", "Lista los mounts registrados.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "mount_remove", "Elimina un path del registry de mounts.", &.{
        .{ .name = "path", .typ = "string", .req = true, .desc = "Ruta a eliminar del registry de mounts." },
    });

    // Captura de pantalla (P-VIS)
    try writeTool(&js, "screenshot", "Alias de capture_screenshot (mismo permiso humano): pide capturar la pantalla primaria; devuelve {status:'pending', approval_id}, la cabina muestra la tarjeta y nada se captura hasta que el humano la aprueba. Recoge {ok, path, width, height} con approval_result.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });

    // Especialistas y divisiones (PANEL-ESPECIALISTAS)
    try writeTool(&js, "specialists", "Lista especialistas nativos + Pixel con rol, especializacion y task_types.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });

    // Gobernanza: ledger de auditoria + contexto de memoria (PANEL-GOBERNANZA)
    try writeTool(&js, "ledger_escalations", "Entradas append-only del audit ledger (escalaciones a modelos de pago).", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "audit_ledger", "Lista TODAS las acciones del audit_ledger (BUILD, AUDIT, FIX, REAUDIT, ESCALATION, etc.) con verdict, model, provider y notes.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "audit_checklist", "Estado de checklist DERIVADO del audit_ledger por subject: pending/built/audited/verified/reopened con constructor y auditores. Solo cuenta auditoria de modelos distintos del constructor.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "memory_context", "Contexto de memoria persistente del proyecto (hallazgos, sesiones, proximos pasos).", &.{
        .{ .name = "project", .typ = "string", .req = false, .desc = "Identificador del proyecto (default='data')." },
    });

    // Token usage summary (P08)
    try writeTool(&js, "usage_summary", "Resumen de tokens consumidos por llamadas LLM. order_id=0 para totales globales.", &.{
        .{ .name = "order_id", .typ = "integer", .req = false, .desc = "ID de la orden (0 = totales globales, default=0)." },
    });

    // Preview embebido (F1): abre una URL en el panel de preview del chat
    try writeTool(&js, "preview", "Abre vista previa embebida de una URL (localhost). Devuelve {ok,url}.", &.{
        .{ .name = "url", .typ = "string", .req = true, .desc = "URL a previsualizar (p. ej. http://localhost:8000)." },
    });

    // Web search (F2): Tavily/Brave con clave, DuckDuckGo sin clave
    try writeTool(&js, "web_search", "Busca en la web. Sin clave usa DuckDuckGo (gratis). Con clave Tavily/Brave usa esa API. Devuelve {provider, results:[{title,url,snippet}]}.", &.{
        .{ .name = "query", .typ = "string", .req = true, .desc = "Consulta de busqueda." },
        .{ .name = "max_results", .typ = "integer", .req = false, .desc = "Maximo numero de resultados (default=5).", .default_val = "5", .minimum = 0, .maximum = c_int_max },
    });

    // ── T4: Capabilities — punto de entrada para cualquier IDE ──
    try writeTool(&js, "capabilities", "Devuelve las capacidades del motor DevAgents: versión, lista de tools disponibles con versión de contrato, rutas de datos activas, y proveedores configurados (solo nombres y si tienen clave activa: true/false, NUNCA valores de claves). Es el punto de entrada recomendado para cualquier IDE o cliente MCP que se conecta por primera vez.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });

    // ── T1: Tools faltantes del mapa UI↔MCP ──
    try writeTool(&js, "session_rename", "Renombra una sesión/orden (persiste el título en runtime.db). Equivalente MCP al comando UI 'Renombrar sesión'.", &.{
        .{ .name = "order_id", .typ = "integer", .req = true, .desc = "ID numérico de la orden/sesión a renombrar." },
        .{ .name = "title", .typ = "string", .req = true, .desc = "Nuevo título para la sesión." },
    });
    try writeTool(&js, "health_summary", "Resumen de salud por proveedor: {provider, models, ok_models, ok_rate, total_ok, total_fail}. Más ligero que 'health' (que da detalle por modelo). Equivalente MCP al panel Health de la UI.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });

    // P10-T1: Revalidación de pricing free/pago
    try writeTool(&js, "pricing_revalidate", "Revalida pricing mediante web_search. Devuelve schema=pricing_revalidate.v2, checked, changed, changes como array [{provider,model,was,now}] y suggestions como array [{provider,model,was,suggested}]. Pago→gratis solo se sugiere (pricing_suggestion); gratis→pago registra pricing_revalidated. Sin clave devuelve skipped=no_search_key; los errores se devuelven con isError=true.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });

    // P10-T3: Scores reales de calidad por modelo+task_type
    try writeTool(&js, "model_scores", "Devuelve los scores reales de calidad por modelo+task_type desde audit_pipeline. JSON [{model,provider,task_type,score,samples,updated_at}] ordenado por score descendente.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });

    // P10-T4: Autoevaluación visual opcional
    try writeTool(&js, "capture_screenshot", "Pide capturar la pantalla primaria (BMP en .screenshots/). Ver la pantalla exige permiso humano: devuelve {status:'pending', approval_id} y la cabina muestra la tarjeta; nada se captura hasta que el humano la aprueba. Recoge {ok, path, width, height} con approval_result.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });
    try writeTool(&js, "approval_result", "Solo lectura: estado de una aprobación pedida por shell_run, git_add/git_commit, run_detached o capture_screenshot (pending, approved, denied, unknown) y, si la cabina ya la ejecutó, su resultado acotado (exit_code, stdout y stderr hasta 16 KiB cada uno; o la ruta de la captura). Quien aprueba es siempre un humano en la cabina.", &.{
        .{ .name = "approval_id", .typ = "integer", .req = true, .desc = "approval_id devuelto al pedir la acción.", .minimum = 1 },
    });

    // P10-T5: Resumen evolutivo del motor
    try writeTool(&js, "evolution_summary", "Resumen read-only de lo aprendido por el motor: top modelos por score real, últimos cambios free/pago (T1), últimas lecciones (T2), y fecha del último probe/sweep. JSON consolidado para el panel Evolución.", &.{
        .{ .name = "dummy", .typ = "null", .req = false, .desc = "" },
    });

    // T7 (d, «paridad sin gobierno»): lo mismo que hace la cabina.
    try writeTool(&js, "spaces_list", "Spaces activos (un git worktree por orden) de un proyecto: [{id,projectId,kind,name,worktreePath,branch,createdAt,archivedAt}]. Igual que core.spaces.list de la cabina.", &.{
        .{ .name = "project_id", .typ = "string", .req = false, .desc = "Proyecto (default 'default').", .min_length = 1, .max_length = 256 },
    });
    try writeTool(&js, "plan_approve", "Aprueba el plan de una orden en estado planificado y la despacha (botón «Aprobar» de la cabina). Los comandos de una orden de origen MCP siguen pidiendo tarjeta en la cabina.", &.{
        .{ .name = "order_id", .typ = "integer", .req = true, .desc = "Orden con plan pendiente de aprobar.", .minimum = 1 },
    });
    try writeTool(&js, "plan_replan", "Replanifica una orden que espera aprobación o aclaración con los cambios pedidos; nunca aprueba ni despacha. Seguir con plan_poll y get_plan.", &.{
        .{ .name = "order_id", .typ = "integer", .req = true, .desc = "Orden a replanificar.", .minimum = 1 },
        .{ .name = "changes", .typ = "string", .req = true, .desc = "Qué cambiar del plan (1..16384 bytes).", .min_length = 1, .max_length = REPLAN_CHANGES_MAX },
    });
    try writeTool(&js, "session_archive", "Archiva (o restaura con archived=false) una sesión/orden, como el menú de sesiones de la cabina.", &.{
        .{ .name = "order_id", .typ = "integer", .req = true, .desc = "Orden/sesión.", .minimum = 1 },
        .{ .name = "archived", .typ = "boolean", .req = false, .desc = "true = archivar (default), false = restaurar." },
    });
    try writeTool(&js, "fs_list", "Lista una carpeta dentro de la raíz confinada (misma tool list_dir y mismo confinamiento que los agentes). Raíz por defecto: la carpeta del proyecto elegida (como el modo Directo; si no hay una elegida, la raíz efectiva) o el worktree de un space.", &.{
        .{ .name = "path", .typ = "string", .req = false, .desc = "Ruta relativa a la raíz (default '.').", .max_length = 2048 },
        .{ .name = "recursive", .typ = "boolean", .req = false, .desc = "Recorrer subcarpetas (con tope de entradas)." },
        SPACE_ROOT_FIELDS[0],
        SPACE_ROOT_FIELDS[1],
    });
    try writeTool(&js, "fs_read", "Lee un archivo de texto dentro de la raíz confinada (tool read_file del agente: 48 KiB por defecto, 128 KiB como máximo por llamada). Raíz por defecto: la carpeta del proyecto elegida (como el modo Directo; si no hay una elegida, la raíz efectiva) o el worktree de un space.", &.{
        .{ .name = "path", .typ = "string", .req = true, .desc = "Ruta relativa a la raíz.", .min_length = 1, .max_length = 2048 },
        .{ .name = "offset", .typ = "integer", .req = false, .desc = "Byte inicial.", .minimum = 0 },
        .{ .name = "limit", .typ = "integer", .req = false, .desc = "Bytes a leer.", .minimum = 1 },
        SPACE_ROOT_FIELDS[0],
        SPACE_ROOT_FIELDS[1],
    });
    try writeTool(&js, "fs_search", "Busca texto en los archivos de la raíz confinada (tool grep_files del agente). Raíz por defecto: la carpeta del proyecto elegida (como el modo Directo; si no hay una elegida, la raíz efectiva) o el worktree de un space.", &.{
        .{ .name = "pattern", .typ = "string", .req = true, .desc = "Texto a buscar (literal).", .min_length = 1, .max_length = 256 },
        .{ .name = "path", .typ = "string", .req = false, .desc = "Subcarpeta donde buscar (default '.').", .max_length = 2048 },
        .{ .name = "ignore_case", .typ = "boolean", .req = false, .desc = "Ignorar mayúsculas." },
        .{ .name = "max_results", .typ = "integer", .req = false, .desc = "Máximo de coincidencias (tope 200).", .minimum = 1, .maximum = 200 },
        SPACE_ROOT_FIELDS[0],
        SPACE_ROOT_FIELDS[1],
    });
    try writeTool(&js, "fs_write", "Escribe un archivo de texto UTF-8 dentro de la raíz confinada (tool write_file del agente: sin flujos alternativos, nombres reservados ni la carpeta .git; 256 KiB por llamada). Raíz por defecto: la carpeta del proyecto elegida (como el modo Directo; si no hay una elegida, la raíz efectiva) o el worktree de un space.", &.{
        .{ .name = "path", .typ = "string", .req = true, .desc = "Ruta relativa a la raíz.", .min_length = 1, .max_length = 2048 },
        .{ .name = "content", .typ = "string", .req = true, .desc = "Contenido completo del archivo." },
        SPACE_ROOT_FIELDS[0],
        SPACE_ROOT_FIELDS[1],
    });
    try writeTool(&js, "git_status", "git status (porcelana) con el git domesticado de la cabina (sin hooks, fsmonitor, bloqueos opcionales ni firmas) por la puerta de shell_run. Es una consulta de solo lectura: corre sin aprobación y devuelve su salida. Raíz por defecto: la carpeta del proyecto elegida (como el modo Directo; si no hay una elegida, la raíz efectiva) o el worktree de un space.", &.{
        SPACE_ROOT_FIELDS[0],
        SPACE_ROOT_FIELDS[1],
    });
    try writeTool(&js, "git_diff", "git diff sin diff externos ni textconv (staged=true para lo preparado). Solo lectura, sin aprobación, como git_status. Raíz por defecto: la carpeta del proyecto elegida (como el modo Directo; si no hay una elegida, la raíz efectiva) o el worktree de un space.", &.{
        .{ .name = "staged", .typ = "boolean", .req = false, .desc = "Ver lo preparado (--cached)." },
        .{ .name = "path", .typ = "string", .req = false, .desc = "Limitar a una ruta (literal).", .min_length = 1, .max_length = 2048 },
        SPACE_ROOT_FIELDS[0],
        SPACE_ROOT_FIELDS[1],
    });
    try writeTool(&js, "git_log", "git log --oneline de los últimos commits. Solo lectura, sin aprobación, como git_status. Raíz por defecto: la carpeta del proyecto elegida (como el modo Directo; si no hay una elegida, la raíz efectiva) o el worktree de un space.", &.{
        .{ .name = "max_count", .typ = "integer", .req = false, .desc = "Número de commits (1..200, default 20).", .minimum = 1, .maximum = GIT_LOG_MAX },
        SPACE_ROOT_FIELDS[0],
        SPACE_ROOT_FIELDS[1],
    });
    try writeTool(&js, "git_add", "git add -- <rutas> (rutas literales). Escribe: pide aprobación humana en la cabina y devuelve approval_id (resultado con approval_result). No hay push ni reescritura de historial por MCP. Raíz por defecto: la carpeta del proyecto elegida (como el modo Directo; si no hay una elegida, la raíz efectiva) o el worktree de un space.", &.{
        .{ .name = "paths", .typ = "array", .req = true, .desc = "Rutas a preparar.", .items_schema = git_path_item_schema, .max_items = GIT_ADD_MAX_PATHS },
        SPACE_ROOT_FIELDS[0],
        SPACE_ROOT_FIELDS[1],
    });
    try writeTool(&js, "git_commit", "git commit -m <mensaje> sin hooks; nunca --amend. Escribe: pide aprobación humana en la cabina y devuelve approval_id (resultado con approval_result). No hay push por MCP. Raíz por defecto: la carpeta del proyecto elegida (como el modo Directo; si no hay una elegida, la raíz efectiva) o el worktree de un space.", &.{
        .{ .name = "message", .typ = "string", .req = true, .desc = "Mensaje del commit.", .min_length = 1, .max_length = COMMIT_MESSAGE_MAX },
        SPACE_ROOT_FIELDS[0],
        SPACE_ROOT_FIELDS[1],
    });

    try js.endArray();
    try js.endObject();
    try js.endObject();

    return allocator.dupe(u8, out.written());
}

const capability_tools = [_][]const u8{
    "order_progress",
    "best_of_n_candidates",
    "best_of_n_choose",
    "repo_clone",
    "ship_order",
    "embeddings_config_set",
    "issues_list",
    "catalog_reconcile_enabled",
    "issue_read",
    "issue_comment",
    "issue_prompt",
    "prs_list",
    "pr_merge",
    "order_from_issue",
    "authenticate",
    "health",
    "health_probe_all",
    "health_summary",
    "catalog_info",
    "router_candidates",
    "sessions",
    "session_messages",
    "session_timeline",
    "session_rename",
    "order_status",
    "order_events",
    "get_plan",
    "approvals_list",
    "ui_action",
    "da_submit_order",
    "da_submit_order_async",
    "order_submit",
    "vision_probe",
    "order_attachments",
    "plan_poll",
    "confirm_plan",
    "answer_order",
    "dispatch_async",
    "dispatch_cancel",
    "plan_cancel",
    "dispatch_poll",
    "worker_output",
    "shell_run",
    "run_detached",
    "discover_models",
    "models_list",
    "models_selection_v1",
    "models_preferences_set_v1",
    "plan_set_model",
    "plan_get_model",
    "exec_set_model",
    "exec_get_model",
    "audit_set_model",
    "audit_get_model",
    "swarm_set_models",
    "swarm_get_models",
    "paid_budget_get",
    "order_preflight",
    "agents_external_list",
    "agents_external_refresh",
    "external_paths_get",
    "external_model_options_set",
    "external_limits_get",
    "add_key",
    "remove_key",
    "list_keys",
    "mcp_disconnect",
    "mcp_is_connected",
    "mcp_tools",
    "mcp_call_tool",
    "set_workspace_root",
    "space_create",
    "space_archive",
    "spaces_prune",
    "list_artifacts",
    "skills_discover",
    "inventory",
    "webhooks_list",
    "remote_start",
    "remote_stop",
    "remote_status",
    "webhook_add",
    "webhook_delete",
    "webhook_test",
    "inventory_refresh",
    "mount_add",
    "mounts_list",
    "mount_remove",
    "screenshot",
    "specialists",
    "ledger_escalations",
    "audit_ledger",
    "audit_checklist",
    "memory_context",
    "usage_summary",
    "preview",
    "web_search",
    "repo_search",
    "repo_embed_index",
    "repo_embed_status",
    "embeddings_probe",
    "embeddings_config_get",
    "pricing_revalidate",
    "model_scores",
    "capture_screenshot",
    "approval_result",
    "evolution_summary",
    "capabilities",
    "spaces_list",
    "plan_approve",
    "plan_replan",
    "session_archive",
    "fs_list",
    "fs_read",
    "fs_search",
    "fs_write",
    "git_status",
    "git_diff",
    "git_log",
    "git_add",
    "git_commit",
};

fn providerHasActiveKey(provider: std.json.Value) bool {
    if (provider != .object) return false;
    const obj = provider.object;
    if (obj.get("has_key")) |has_key| {
        if (has_key == .bool) return has_key.bool;
    }
    const keys = obj.get("keys") orelse return false;
    if (keys != .array) return false;
    for (keys.array.items) |key| {
        if (key != .object) continue;
        const status = key.object.get("status") orelse continue;
        if (status == .string and std.mem.eql(u8, status.string, "active")) return true;
    }
    return false;
}

fn writeCapabilitiesPayload(
    allocator: std.mem.Allocator,
    js: *std.json.Stringify,
    version: []const u8,
    data_dir: []const u8,
    governance_mode: []const u8,
    catalog_json: []const u8,
    providers_json: []const u8,
) !void {
    var catalog = std.json.parseFromSlice(std.json.Value, allocator, catalog_json, .{}) catch null;
    defer if (catalog) |*parsed| parsed.deinit();
    var providers = std.json.parseFromSlice(std.json.Value, allocator, providers_json, .{}) catch null;
    defer if (providers) |*parsed| parsed.deinit();

    try js.beginObject();
    try js.objectField("ok");
    try js.write(true);
    try js.objectField("engine");
    try js.beginObject();
    try js.objectField("name");
    try js.write("DevAgents Angel");
    try js.objectField("version");
    try js.write(version);
    try js.objectField("build_hash");
    const identity = std.mem.span(core.c_api.da_build_identity_v1());
    const version_end = std.mem.indexOfScalar(u8, identity, '/') orelse identity.len;
    const revision = if (std.mem.indexOfScalar(u8, identity[0..version_end], '+')) |start|
        identity[start + 1 .. version_end]
    else
        "";
    try js.write(if (revision.len > 0) revision else "unknown");
    try js.endObject();
    try js.objectField("contract_version");
    try js.write("1.0");
    try js.objectField("version");
    try js.write(version);
    try js.objectField("protocolVersion");
    try js.write(LATEST_PROTOCOL_VERSION);
    try js.objectField("protocolVersions");
    try js.write(SUPPORTED_PROTOCOL_VERSIONS);
    try js.objectField("dataDir");
    try js.write(data_dir);
    try js.objectField("data_dirs");
    try js.beginObject();
    try js.objectField("runtime");
    try js.write(data_dir);
    try js.objectField("catalog");
    try js.write(data_dir);
    try js.objectField("ledger");
    try js.write(data_dir);
    try js.endObject();
    try js.objectField("governance_mode");
    try js.write(governance_mode);
    try js.objectField("catalog");
    if (catalog) |parsed| {
        try js.write(parsed.value);
    } else {
        try js.beginObject();
        try js.endObject();
    }
    try js.objectField("providers");
    try js.beginArray();
    if (providers) |parsed| {
        if (parsed.value == .array) {
            for (parsed.value.array.items) |provider| {
                if (provider != .object) continue;
                const name = provider.object.get("name") orelse continue;
                if (name != .string) continue;
                const has_key = providerHasActiveKey(provider);
                const key_count: i64 = if (has_key) 1 else 0;
                try js.beginObject();
                try js.objectField("name");
                try js.write(name.string);
                try js.objectField("provider");
                try js.write(name.string);
                try js.objectField("has_active_key");
                try js.write(has_key);
                try js.objectField("has_key");
                try js.write(has_key);
                try js.objectField("key_count");
                try js.write(key_count);
                try js.endObject();
            }
        }
    }
    try js.endArray();
    try js.objectField("features");
    try js.beginArray();
    try js.beginObject();
    try js.objectField("name");
    try js.write("spaces");
    try js.objectField("contract");
    try js.write("1.0");
    try js.endObject();
    try js.beginObject();
    try js.objectField("name");
    try js.write("ship_flow");
    try js.objectField("contract");
    try js.write("1.0");
    try js.endObject();
    try js.beginObject();
    try js.objectField("name");
    try js.write("departments");
    try js.objectField("contract");
    try js.write("1.0");
    try js.endObject();
    try js.endArray();
    try js.objectField("tools");
    try js.beginArray();
    for (capability_tools) |tool_name| try js.write(tool_name);
    try js.endArray();
    try js.endObject();
}

// ---------------------------------------------------------------------------
// Helpers de extraccion JSON
// ---------------------------------------------------------------------------

/// cota exacta de `@intFromFloat` sobre i64. `maxInt(i64)` no es
/// representable en f64 (redondea a 2^63), así que la cota superior segura es
/// `< 2^63` y la inferior `>= -2^63` (ambas exactas). Un float fuera del rango
/// o NaN — enviables por JSON (`"id":1e30`, `"order_id":1e999` parsea como
/// `inf`) — hacía panic en el cast y tumbaba el servidor con UNA línea.
const F64_I64_BOUND: f64 = 9223372036854775808.0; // 2^63

fn floatFitsI64(f: f64) bool {
    return f >= -F64_I64_BOUND and f < F64_I64_BOUND;
}

fn idOf(v: ?std.json.Value) i64 {
    const val = v orelse return 0;
    return switch (val) {
        .integer => |i| i,
        .float => |f| if (floatFitsI64(f)) @intFromFloat(f) else 0,
        else => 0,
    };
}

fn stringOf(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return if (val == .string) val.string else null;
}

fn boolOf(v: ?std.json.Value) ?bool {
    const val = v orelse return null;
    return if (val == .bool) val.bool else null;
}

fn intOf(v: ?std.json.Value) ?i64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| i,
        .float => |f| if (floatFitsI64(f)) @intFromFloat(f) else null,
        else => null,
    };
}

fn orderIdToHandle(id: i64) ?*anyopaque {
    // `order_id:-1` (o cualquier negativo) hacía panic en el @intCast a
    // usize — una sola línea JSON tumbaba el servidor, y por tools ABIERTAS
    // (get_plan/order_status/order_events — sin auth). Un id no positivo no
    // es una orden válida: null → orderHandleToId devuelve invalid_arg, el
    // mismo resultado honesto que un id inexistente.
    if (id <= 0) return null;
    return @ptrFromInt(@as(usize, @intCast(id)));
}

/// rechazo estricto de argumentos desconocidos. `fields` es el
/// MISMO array con el que se anunció el inputSchema de la tool (writeToolStrict):
/// una clave que no esté declarada recibe -32602 antes de despachar, el patrón
///. El diagnóstico nombra la clave, nunca su valor (podría ser un secreto).
/// Devuelve la respuesta de error ya construida, o null si todo está declarado.
fn rejectUnknownArgs(allocator: std.mem.Allocator, id: i64, args: std.json.ObjectMap, fields: []const SchemaField) !?[]u8 {
    var entries = args.iterator();
    while (entries.next()) |entry| {
        var declared = false;
        for (fields) |f| {
            if (std.mem.eql(u8, f.name, entry.key_ptr.*)) {
                declared = true;
                break;
            }
        }
        if (declared) continue;
        const message = try std.fmt.allocPrint(allocator, "argumento desconocido: {s}", .{entry.key_ptr.*});
        defer allocator.free(message);
        return try buildErrorResp(allocator, id, -32602, message);
    }
    return null;
}

fn statusToText(st: core.c_api.DaOrderStatus) []const u8 {
    return switch (st) {
        .pending => "pending",
        .clarifying => "clarifying",
        .planned => "planned",
        .approved => "approved",
        .running => "running",
        .awaiting_approval => "awaiting_approval",
        .done => "done",
        .failed => "failed",
        .rejected => "rejected",
        .cancelled => "cancelled",
        .interrupted => "interrupted",
        // AUDIT-UNAVAILABLE-P0: la herramienta MCP también ve el tercer
        // cierre honesto — la cadena coincide con orders.status en la DB.
        .audit_unavailable => "audit_unavailable",
        // E5.18: la orden best-of-N terminó sus candidatas y espera la
        // elección del usuario (best_of_n_candidates / best_of_n_choose).
        .awaiting_best_of_n => "awaiting_best_of_n",
    };
}

// ---------------------------------------------------------------------------
// Handler de tools/call
// ---------------------------------------------------------------------------

fn handleToolCall(allocator: std.mem.Allocator, id: i64, obj: std.json.ObjectMap, ctx: *ServerCtx) !?[]u8 {
    const params = obj.get("params") orelse return try buildErrorResp(allocator, id, -32602, "missing params");
    if (params != .object) return try buildErrorResp(allocator, id, -32602, "invalid params");
    const p = params.object;

    const name_v = p.get("name") orelse return try buildErrorResp(allocator, id, -32602, "missing name");
    if (name_v != .string) return try buildErrorResp(allocator, id, -32602, "invalid name");
    const name = name_v.string;

    // `arguments` no-objeto (string, número, array) se tragaba como {}
    // — la tool recibía args vacíos y el cliente no veía por qué. El campo
    // debe ser objeto o ausente; cualquier otro tipo es -32602.
    // F0.7 (e5-b11): `arguments` ausente equivale a {}; `null` explícito no es
    // un objeto y se rechaza igual que cualquier otro tipo.
    const args = p.get("arguments") orelse std.json.Value{ .object = .empty };
    if (args != .object)
        return try buildErrorResp(allocator, id, -32602, "arguments must be an object");
    const a = args.object;

    // T7 (paridad sin gobierno): antes que la autenticación y el validador.
    // Un token autentica al cliente, no lo convierte en el humano de la cabina.
    if (isCabinOnlyTool(name)) return try buildToolResult(allocator, id, CABIN_ONLY_MESSAGE, true);

    // MCP-AUTH: tools privilegiadas exigen sesión autenticada. Sin ella el
    // cliente puede leer/observar pero NO mutar estado, ejecutar procesos,
    // resolver aprobaciones ni tocar credenciales/gobernanza. Va antes del
    // validador: sin sesión no se examinan los argumentos de una tool privilegiada.
    if (!ctx.authed and isPrivilegedTool(name)) {
        const guidance = " Lanza el servidor con DEVAGENTS_MCP_TOKEN o llama 'authenticate' con el token del panel MCP de DevAgents.";
        for (PRIVILEGED_READ_TOOLS) |read_tool| {
            if (std.mem.eql(u8, name, read_tool)) return try buildToolResult(allocator, id, "autenticacion requerida: esta herramienta lee datos privados." ++ guidance, true);
        }
        return try buildToolResult(allocator, id, "autenticacion requerida: esta herramienta muta estado, ejecuta procesos o toca gobernanza/credenciales." ++ guidance, true);
    }

    // F0.7: validador genérico contra el inputSchema publicado (tipo,
    // obligatorios, enum, cotas, elementos de arrays) antes de llegar al motor.
    if (try validateToolArgs(allocator, id, ctx, name, args)) |response| return response;

    // MCP-AUTH: `authenticate` es la única tool privilegiada-alcanzable —
    // presenta el token y habilita el resto de la sesión.
    if (std.mem.eql(u8, name, "authenticate")) {
        const tok = stringOf(a.get("token")) orelse return try buildErrorResp(allocator, id, -32602, "missing token");
        if (ctx.checkToken(tok)) {
            ctx.authed = true;
            return try buildToolResult(allocator, id, "{\"ok\":true}", false);
        }
        return try buildToolResult(allocator, id, "token invalido", true);
    }

    // Un token autentica al cliente, no lo convierte en el humano que aprueba.
    // Conservar los nombres permite un error claro a clientes existentes.
    // r3 (auditoría el segundo auditor): APRUEBA HUMANA REAL para archivar/podar
    // spaces. r2 vetaba de plano por MCP; el encargo pidió una vía con
    // aprobación real SIN exponer da_approval_resolve (esa API nunca se
    // expone: quien resuelve es un HUMANO desde otro núcleo sin superficie
    // MCP, como la cabina con core.approvals.resolve → bridge.cpp:2631).
    // Fase 1 (sin approval_id): valida el contrato, registra la solicitud
    // EXACTA en la tabla approvals de la MISMA base que abrió el núcleo
    // (fuente de verdad compartida entre procesos, E5.05/E5.09) y responde
    // isError con approval_id, sin tocar el motor.
    // Fase 2 (con approval_id): solo ejecuta si esa solicitud exacta
    // (misma tool + mismos argumentos canónicos) fue YA CONCEDIDA por el
    // humano; pendiente/rechazada/desconocida/mismatch → isError y el motor
    // no se toca. La ejecución en sí es paridad exacta del puente.
    if (std.mem.eql(u8, name, "space_archive") or std.mem.eql(u8, name, "spaces_prune")) {
        const handle = ctx.core_handle orelse return try buildErrorResp(allocator, id, -32603, "core not initialized");
        const is_prune = std.mem.eql(u8, name, "spaces_prune");
        // Primero el contrato (claves desconocidas y tipos: patrones que ya
        // usan las demás tools), después la gobernanza (r2 P1/P2).
        if (is_prune) {
            if (try rejectUnknownArgs(allocator, id, a, &SPACES_PRUNE_FIELDS)) |resp| return resp;
            // r2 (P2): PRESENTE con tipo incorrecto se rechaza; ausente toma default.
            if (a.get("project_id")) |v| {
                if (v != .string) return try buildErrorResp(allocator, id, -32602, "project_id presente debe ser string");
            }
        } else {
            if (try rejectUnknownArgs(allocator, id, a, &SPACE_ARCHIVE_FIELDS)) |resp| return resp;
            const space_arg = a.get("space_id") orelse return try buildErrorResp(allocator, id, -32602, "missing space_id (> 0)");
            if (space_arg != .integer or space_arg.integer <= 0) return try buildErrorResp(allocator, id, -32602, "space_id debe ser entero > 0");
        }
        if (a.get("approval_id")) |v| {
            if (v != .integer or v.integer <= 0) return try buildErrorResp(allocator, id, -32602, "approval_id presente debe ser entero > 0");
        }

        const project_id = stringOf(a.get("project_id")) orelse "default";
        const requested_approval: ?i64 = if (a.get("approval_id")) |v| v.integer else null;
        if (requested_approval) |aid| {
            // Fase 2: la fila compartida decide. La aprobación es de UN SOLO
            // USO y, en poda, queda acotada al conjunto de spaces archivados
            // que el humano vio al concederla.
            const row = ctx.spacesApprovalFetch(allocator, aid, name);
            defer if (row.stored) |stored| allocator.free(stored);
            if (row.state == .unknown) {
                const msg = try std.fmt.allocPrint(allocator,
                    \\{{"approval_id":{d},"status":"unknown","message":"no existe una solicitud humana registrada con ese id. Vuelve a pedir la accion sin approval_id y usa el nuevo id."}}
                , .{aid});
                defer allocator.free(msg);
                return try buildToolResult(allocator, id, msg, true);
            }
            // Un solo uso: el id ya ejecutado no vuelve a servir para nada,
            // aunque el reenvío cambie de argumentos.
            if (row.state == .consumed) {
                const msg = try std.fmt.allocPrint(allocator,
                    \\{{"approval_id":{d},"status":"consumed","message":"aprobacion ya consumida: es de un solo uso y ya se ejecuto con ella. Reutilizarla no tiene efecto. Pide una nueva aprobacion sin approval_id si hace falta. El motor no se toco."}}
                , .{aid});
                defer allocator.free(msg);
                return try buildToolResult(allocator, id, msg, true);
            }
            // La fila debe ser EXACTAMENTE esta acción en cualquier estado: un
            // id de otra tool u otros argumentos no vale ni para consultar.
            if (is_prune) {
                if (!spacesPruneScopeMatches(allocator, row.stored, project_id))
                    return try spacesApprovalMismatchResp(allocator, id, aid);
            } else {
                if (!spacesArchiveMatches(allocator, row.stored, a.get("space_id").?.integer))
                    return try spacesApprovalMismatchResp(allocator, id, aid);
            }
            if (row.state == .granted) {
                // r5 (auditoría el segundo auditor, lote H): en poda ya NO se
                // compara el snapshot con el conjunto ACTUAL de archivados.
                // Se recuperan los ids que vio el humano y solo esos se podan,
                // comprobando por id que sigan archivados al borrarlos. Un
                // space archivado después (B) no está en el snapshot y no se
                // toca, aunque exista en el momento de podar.
                if (is_prune) {
                    var scope = std.json.parseFromSlice(SpacesPruneScope, allocator, row.stored.?, .{ .ignore_unknown_fields = true }) catch {
                        return try spacesApprovalMismatchResp(allocator, id, aid);
                    };
                    defer scope.deinit();
                    // Reclamo atómico del único uso: si otro reenvío ganó,
                    // este no puede ejecutar (changes()==0).
                    if (!ctx.spacesApprovalConsume(aid)) {
                        const msg = try std.fmt.allocPrint(allocator,
                            \\{{"approval_id":{d},"status":"unknown","message":"no se pudo consumir la aprobacion: es de un solo uso y otra ejecucion la reclamo o dejo de estar concedida. El motor no se toco."}}
                        , .{aid});
                        defer allocator.free(msg);
                        return try buildToolResult(allocator, id, msg, true);
                    }
                    const pruned_count = ctx.spacesPruneApproved(allocator, handle, project_id, scope.value.space_ids) catch {
                        const msg = try std.fmt.allocPrint(allocator,
                            \\{{"approval_id":{d},"status":"error","message":"no se pudo podar por ids en runtime.db; el motor no se toco para el resto. Pide una nueva aprobacion si hace falta."}}
                        , .{aid});
                        defer allocator.free(msg);
                        return try buildToolResult(allocator, id, msg, true);
                    };
                    const out = try std.fmt.allocPrint(allocator, "{{\"pruned\":{d}}}", .{pruned_count});
                    defer allocator.free(out);
                    return try buildToolResult(allocator, id, out, false);
                }
                // Archivar: reclamo del único uso y ejecución idéntica al
                // puente (da_space_archive).
                if (!ctx.spacesApprovalConsume(aid)) {
                    const msg = try std.fmt.allocPrint(allocator,
                        \\{{"approval_id":{d},"status":"unknown","message":"no se pudo consumir la aprobacion: es de un solo uso y otra ejecucion la reclamo o dejo de estar concedida. El motor no se toco."}}
                    , .{aid});
                    defer allocator.free(msg);
                    return try buildToolResult(allocator, id, msg, true);
                }
                if (core.c_api.da_space_archive(handle, a.get("space_id").?.integer) != 0)
                    return try lastErrorToolResult(allocator, id);
                return try buildToolResult(allocator, id, "{\"archived\":true}", false);
            }
            if (row.state == .pending) {
                const msg = try std.fmt.allocPrint(allocator,
                    \\{{"approval_id":{d},"status":"pending","message":"aprobacion humana requerida: la solicitud sigue pendiente de un humano (se resuelve desde la cabina con core.approvals.resolve). El motor no se toco. Consulta el detalle en approvals_list."}}
                , .{aid});
                defer allocator.free(msg);
                return try buildToolResult(allocator, id, msg, true);
            }
            if (row.state == .rejected) {
                const msg = try std.fmt.allocPrint(allocator,
                    \\{{"approval_id":{d},"status":"rejected","message":"aprobacion humana rechazada: el humano la nego. Solicitala de nuevo si cambia de parecer (sin approval_id). El motor no se toco."}}
                , .{aid});
                defer allocator.free(msg);
                return try buildToolResult(allocator, id, msg, true);
            }
            if (row.state == .unknown) {
                const msg = try std.fmt.allocPrint(allocator,
                    \\{{"approval_id":{d},"status":"unknown","message":"no existe una solicitud humana registrada con ese id. Vuelve a pedir la accion sin approval_id y usa el nuevo id."}}
                , .{aid});
                defer allocator.free(msg);
                return try buildToolResult(allocator, id, msg, true);
            }
            {
                const msg = try std.fmt.allocPrint(allocator,
                    \\{{"approval_id":{d},"status":"mismatch","message":"la solicitud y la accion no corresponden: el approval_id registrado no es exactamente esta accion (misma tool, mismos argumentos). Consulta approvals_list; el motor no se toco."}}
                , .{aid});
                defer allocator.free(msg);
                return try buildToolResult(allocator, id, msg, true);
            }
        }
        // Fase 1: registrar la solicitud pendiente para un humano. En poda el
        // descriptor guarda el snapshot exacto de lo que el humano verá.
        const action_noun = if (is_prune) "podar los spaces del proyecto" else "archivar el space";
        var descriptor: []u8 = undefined;
        if (is_prune) {
            const snapshot = try ctx.spacesArchivedIds(allocator, project_id);
            defer allocator.free(snapshot);
            descriptor = try spacesPruneDescriptor(allocator, project_id, snapshot);
        } else {
            descriptor = try spacesArchiveDescriptor(allocator, a.get("space_id").?.integer);
        }
        defer allocator.free(descriptor);
        const description = try std.fmt.allocPrint(allocator, "{s} con argumentos {s}", .{ action_noun, descriptor });
        defer allocator.free(description);
        const registered = ctx.spacesApprovalInsert(name, description, descriptor) catch {
            return try buildToolResult(allocator, id, "aprobacion humana requerida: no se pudo registrar la solicitud en la base compartida. Ejecutalo desde la cabina (ficha del space -> Archivar/Podar)", true);
        };
        const pending = try std.fmt.allocPrint(allocator,
            \\{{"approval_id":{d},"status":"pending","message":"aprobacion humana requerida: {s} retira worktrees y borra filas; un humano debe concederla. Solicitud registrada en la tabla approvals de runtime.db (la lee la cabina). Vuelve a llamar {s} con approval_id:{d} solo cuando este concedida."}}
        , .{ registered, action_noun, name, registered });
        defer allocator.free(pending);
        return try buildToolResult(allocator, id, pending, true);
    }

    const handle = ctx.core_handle orelse return try buildErrorResp(allocator, id, -32603, "core not initialized");
    const remote_lifecycle = std.mem.eql(u8, name, "remote_start") or std.mem.eql(u8, name, "remote_stop") or std.mem.eql(u8, name, "remote_status");
    if (!remote_lifecycle) ctx.remote_mutex.lock();
    defer if (!remote_lifecycle) ctx.remote_mutex.unlock();

    if (try handleParityTool(allocator, id, name, a, handle)) |response| return response;

    if (std.mem.eql(u8, name, "order_progress")) {
        if (try rejectUnknownArgs(allocator, id, a, &ORDER_PROGRESS_FIELDS)) |response| return response;
        const action = stringOf(a.get("action")) orelse return try buildErrorResp(allocator, id, -32602, "missing action (get/set)");
        const oid_value = a.get("order_id") orelse return try buildErrorResp(allocator, id, -32602, "missing integer order_id");
        if (oid_value != .integer) return try buildErrorResp(allocator, id, -32602, "order_id must be integer");
        const oid = oid_value.integer;
        if (oid <= 0) return try buildErrorResp(allocator, id, -32602, "order_id must be positive");
        const setting = std.mem.eql(u8, action, "set");
        if (!setting and !std.mem.eql(u8, action, "get")) return try buildErrorResp(allocator, id, -32602, "action must be get/set");
        if (setting and !ctx.authed) return try buildToolResult(allocator, id, "autenticacion requerida: order_progress set", true);
        var request: std.Io.Writer.Allocating = .init(allocator);
        defer request.deinit();
        var js: std.json.Stringify = .{ .writer = &request.writer, .options = .{} };
        try js.beginObject();
        try js.objectField("order_id");
        try js.write(oid);
        if (setting) {
            const seq_value = a.get("expected_seq") orelse return try buildErrorResp(allocator, id, -32602, "set requires integer expected_seq");
            if (seq_value != .integer) return try buildErrorResp(allocator, id, -32602, "expected_seq must be integer");
            const seq = seq_value.integer;
            if (seq < 0 or seq == std.math.maxInt(i64)) return try buildErrorResp(allocator, id, -32602, "expected_seq out of range");
            const state = stringOf(a.get("state")) orelse return try buildErrorResp(allocator, id, -32602, "set requires state");
            const note = stringOf(a.get("note")) orelse return try buildErrorResp(allocator, id, -32602, "set requires note");
            try js.objectField("expected_seq");
            try js.write(seq);
            try js.objectField("state");
            try js.write(state);
            try js.objectField("note");
            try js.write(note);
            try js.objectField("author");
            try js.write("agent");
        } else {
            if (a.get("expected_seq") != null or a.get("state") != null or a.get("note") != null)
                return try buildErrorResp(allocator, id, -32602, "get accepts only action and order_id");
        }
        try js.endObject();
        const raw = try allocator.dupeZ(u8, request.written());
        defer allocator.free(raw);
        var output: ?[*:0]u8 = null;
        const rc = if (setting) core.c_api.da_order_progress_set(handle, raw, &output) else core.c_api.da_order_progress_get(handle, raw, &output);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        const body = output orelse return try buildErrorResp(allocator, id, -32603, "order_progress: null output");
        defer core.c_api.da_string_free(body);
        return try buildToolResult(allocator, id, std.mem.span(body), false);
    }

    if (std.mem.eql(u8, name, "issues_list") or std.mem.eql(u8, name, "issue_read") or
        std.mem.eql(u8, name, "issue_prompt") or std.mem.eql(u8, name, "issue_comment") or std.mem.eql(u8, name, "order_from_issue"))
    {
        var request: std.Io.Writer.Allocating = .init(allocator);
        defer request.deinit();
        var js: std.json.Stringify = .{ .writer = &request.writer, .options = .{} };
        try js.beginObject();
        inline for (.{ "source", "base_url", "project", "issue_id" }) |field| {
            if (a.get(field)) |value| {
                try js.objectField(field);
                try js.write(value);
            }
        }
        if (a.get("fixture")) |value| {
            try js.objectField("fixture");
            try js.write(value);
        }
        if (std.mem.eql(u8, name, "issue_comment")) {
            inline for (.{ "text", "explicit" }) |field| {
                if (a.get(field)) |value| {
                    try js.objectField(field);
                    try js.write(value);
                }
            }
        }
        try js.endObject();
        const ref_z = try allocator.dupeZ(u8, request.written());
        defer allocator.free(ref_z);
        if (std.mem.eql(u8, name, "order_from_issue")) {
            const instruction = try allocator.dupeZ(u8, stringOf(a.get("instruction")) orelse "");
            defer allocator.free(instruction);
            const project_id = try allocator.dupeZ(u8, stringOf(a.get("project_id")) orelse "default");
            defer allocator.free(project_id);
            const conversation = if (stringOf(a.get("conversation_id"))) |v| try allocator.dupeZ(u8, v) else null;
            defer if (conversation) |v| allocator.free(v);
            var order: ?*anyopaque = null;
            const image_json = if (a.get("attachments")) |v| try std.json.Stringify.valueAlloc(allocator, v, .{}) else null;
            defer if (image_json) |j| allocator.free(j);
            const image_z = if (image_json) |j| try allocator.dupeZ(u8, j) else null;
            defer if (image_z) |j| allocator.free(j);
            if (core.c_api.da_order_from_issue_images_async(handle, ref_z.ptr, instruction.ptr, project_id.ptr, if (conversation) |v| v.ptr else null, if (image_z) |j| j.ptr else null, &order) != 0) return try lastErrorToolResult(allocator, id);
            const result = try std.fmt.allocPrint(allocator, "{{\"order_id\":{d}}}", .{@intFromPtr(order.?)});
            defer allocator.free(result);
            return try buildToolResult(allocator, id, result, false);
        }
        var out: ?[*:0]u8 = null;
        const rc = if (std.mem.eql(u8, name, "issues_list")) core.c_api.da_issues_list_json(handle, ref_z.ptr, &out) else if (std.mem.eql(u8, name, "issue_read")) core.c_api.da_issue_read_json(handle, ref_z.ptr, &out) else if (std.mem.eql(u8, name, "issue_prompt")) core.c_api.da_issue_prompt_json(handle, ref_z.ptr, &out) else core.c_api.da_issue_comment_json(handle, ref_z.ptr, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        const result = out orelse return try buildErrorResp(allocator, id, -32603, "issues: salida nula del motor");
        defer core.c_api.da_string_free(result);
        return try buildToolResult(allocator, id, std.mem.span(result), false);
    }

    if (std.mem.eql(u8, name, "da_submit_order")) {
        const text = stringOf(a.get("order_text")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_text");
        const proj = stringOf(a.get("project_id")) orelse "default";
        const text_z = try allocator.dupeZ(u8, text);
        defer allocator.free(text_z);
        const proj_z = try allocator.dupeZ(u8, proj);
        defer allocator.free(proj_z);
        const conv_id_opt = stringOf(a.get("conversation_id"));
        const conv_id_dup: ?[:0]u8 = if (conv_id_opt) |cid| try allocator.dupeZ(u8, cid) else null;
        defer if (conv_id_dup) |c| allocator.free(c);
        const conv_id_z: ?[*:0]const u8 = if (conv_id_dup) |c| c.ptr else null;
        var out_order: ?*anyopaque = null;
        const image_json = if (a.get("attachments")) |v| try std.json.Stringify.valueAlloc(allocator, v, .{}) else null;
        defer if (image_json) |j| allocator.free(j);
        const image_z = if (image_json) |j| try allocator.dupeZ(u8, j) else null;
        defer if (image_z) |j| allocator.free(j);
        const rc = if (image_z) |j| core.c_api.da_order_submit_images_async(handle, text_z, proj_z, conv_id_z, j, &out_order) else core.c_api.da_order_submit(handle, text_z, proj_z, conv_id_z, &out_order);
        if (rc == 0 and image_z != null) {
            var done: c_int = 0;
            var plan_ok: c_int = 0;
            while (done == 0) {
                if (core.c_api.da_order_plan_poll(handle, &done, &plan_ok) != 0) return try lastErrorToolResult(allocator, id);
                if (done == 0) Sleep(50);
            }
            if (plan_ok == 0) return try lastErrorToolResult(allocator, id);
        }
        if (rc != 0) {
            var err: [*:0]u8 = undefined;
            _ = core.c_api.da_last_error(&err);
            defer core.c_api.da_string_free(err);
            return try buildToolResult(allocator, id, std.mem.span(err), true);
        }
        const oid: i64 = @intCast(@intFromPtr(out_order.?));
        // E5.18: opcion best-of-N — se fija sobre la fila antes de aprobar.
        if (intOf(a.get("best_of_n"))) |n| {
            if (n > 0) {
                const n_c = std.math.cast(c_int, n) orelse
                    return try buildToolResult(allocator, id, "best_of_n fuera de rango", true);
                const members = stringOf(a.get("best_of_n_members"));
                const members_z: ?[:0]u8 = if (members) |ms| try allocator.dupeZ(u8, ms) else null;
                defer if (members_z) |mz| allocator.free(mz);
                const rc2 = core.c_api.da_order_set_best_of_n(handle, orderIdToHandle(oid), n_c, if (members_z) |mz| mz.ptr else null);
                if (rc2 != 0) return try lastErrorToolResult(allocator, id);
            }
        }
        const msg = try std.fmt.allocPrint(allocator, "{{\"order_id\":{d}}}", .{oid});
        defer allocator.free(msg);
        return try buildToolResult(allocator, id, msg, false);
    }

    if (std.mem.eql(u8, name, "vision_probe")) {
        const vision_provider = stringOf(a.get("provider")) orelse return try buildErrorResp(allocator, id, -32602, "missing provider");
        const m = stringOf(a.get("model")) orelse return try buildErrorResp(allocator, id, -32602, "missing model");
        const pz = try allocator.dupeZ(u8, vision_provider);
        defer allocator.free(pz);
        const mz = try allocator.dupeZ(u8, m);
        defer allocator.free(mz);
        var json: ?[*:0]u8 = null;
        if (core.c_api.da_vision_probe_json(handle, pz, mz, &json) != 0) return try lastErrorToolResult(allocator, id);
        defer if (json) |j| core.c_api.da_string_free(j);
        return try buildToolResult(allocator, id, std.mem.span(json.?), false);
    }
    if (std.mem.eql(u8, name, "order_attachments")) {
        const oid = intOf(a.get("order_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_id");
        if (oid <= 0) return try buildErrorResp(allocator, id, -32602, "invalid order_id");
        var json: ?[*:0]u8 = null;
        if (core.c_api.da_order_attachments_json(handle, orderIdToHandle(oid), &json) != 0) return try lastErrorToolResult(allocator, id);
        defer if (json) |j| core.c_api.da_string_free(j);
        return try buildToolResult(allocator, id, std.mem.span(json.?), false);
    }

    if (std.mem.eql(u8, name, "da_submit_order_async") or std.mem.eql(u8, name, "order_submit")) {
        const text = stringOf(a.get("order_text")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_text");
        const proj = stringOf(a.get("project_id")) orelse "default";
        const text_z = try allocator.dupeZ(u8, text);
        defer allocator.free(text_z);
        const proj_z = try allocator.dupeZ(u8, proj);
        defer allocator.free(proj_z);
        const conv_id_opt = stringOf(a.get("conversation_id"));
        const conv_id_dup: ?[:0]u8 = if (conv_id_opt) |cid| try allocator.dupeZ(u8, cid) else null;
        defer if (conv_id_dup) |c| allocator.free(c);
        const conv_id_z: ?[*:0]const u8 = if (conv_id_dup) |c| c.ptr else null;
        var out_order: ?*anyopaque = null;
        const image_json = if (a.get("attachments")) |v| try std.json.Stringify.valueAlloc(allocator, v, .{}) else null;
        defer if (image_json) |j| allocator.free(j);
        const image_z = if (image_json) |j| try allocator.dupeZ(u8, j) else null;
        defer if (image_z) |j| allocator.free(j);
        const rc = core.c_api.da_order_submit_images_async(handle, text_z, proj_z, conv_id_z, if (image_z) |j| j.ptr else null, &out_order);
        if (rc != 0) {
            var err: [*:0]u8 = undefined;
            _ = core.c_api.da_last_error(&err);
            defer core.c_api.da_string_free(err);
            return try buildToolResult(allocator, id, std.mem.span(err), true);
        }
        const oid: i64 = @intCast(@intFromPtr(out_order.?));
        // E5.18: opcion best-of-N — se fija sobre la fila antes de aprobar.
        if (intOf(a.get("best_of_n"))) |n| {
            if (n > 0) {
                const n_c = std.math.cast(c_int, n) orelse
                    return try buildToolResult(allocator, id, "best_of_n fuera de rango", true);
                const members = stringOf(a.get("best_of_n_members"));
                const members_z: ?[:0]u8 = if (members) |ms| try allocator.dupeZ(u8, ms) else null;
                defer if (members_z) |mz| allocator.free(mz);
                const rc2 = core.c_api.da_order_set_best_of_n(handle, orderIdToHandle(oid), n_c, if (members_z) |mz| mz.ptr else null);
                if (rc2 != 0) return try lastErrorToolResult(allocator, id);
            }
        }
        const msg = try std.fmt.allocPrint(allocator, "{{\"order_id\":{d}}}", .{oid});
        defer allocator.free(msg);
        return try buildToolResult(allocator, id, msg, false);
    }

    if (std.mem.eql(u8, name, "best_of_n_candidates")) {
        const oid = intOf(a.get("order_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_id");
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_best_of_n_candidates_json(handle, orderIdToHandle(oid), &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "best_of_n_choose")) {
        const oid = intOf(a.get("order_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_id");
        const cand = intOf(a.get("candidate_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing candidate_id");
        const rc = core.c_api.da_best_of_n_choose(handle, orderIdToHandle(oid), cand);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"ok\":true}", false);
    }

    if (std.mem.eql(u8, name, "plan_poll")) {
        var done: c_int = 0;
        var ok_flag: c_int = 0;
        const rc = core.c_api.da_order_plan_poll(handle, &done, &ok_flag);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        const msg = try std.fmt.allocPrint(allocator, "{{\"done\":{d},\"ok\":{d}}}", .{ done, ok_flag });
        defer allocator.free(msg);
        return try buildToolResult(allocator, id, msg, false);
    }

    if (std.mem.eql(u8, name, "get_plan")) {
        const oid = intOf(a.get("order_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_id");
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_plan_get_json(handle, orderIdToHandle(oid), &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "confirm_plan")) {
        const oid = intOf(a.get("order_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_id");
        if (stringOf(a.get("plan_json"))) |plan| {
            const plan_z = try allocator.dupeZ(u8, plan);
            defer allocator.free(plan_z);
            // FIX-ENGINE-7: save plan WITHOUT dispatching. The extension calls
            // dispatch_async next, which runs the dispatch in a background thread.
            const rc = core.c_api.da_order_plan_set_json(handle, orderIdToHandle(oid), plan_z);
            if (rc != 0) return try lastErrorToolResult(allocator, id);
        }
        // No dispatch here — confirm_plan only confirms/approves the plan.
        // dispatch_async handles the actual dispatch (non-blocking).
        return try buildToolResult(allocator, id, "{\"ok\":true}", false);
    }

    if (std.mem.eql(u8, name, "answer_order")) {
        const oid = intOf(a.get("order_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_id");
        const answers = stringOf(a.get("answers_json")) orelse return try buildErrorResp(allocator, id, -32602, "missing answers_json");
        const answers_z = try allocator.dupeZ(u8, answers);
        defer allocator.free(answers_z);
        const rc = core.c_api.da_order_answer(handle, orderIdToHandle(oid), answers_z);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"ok\":true}", false);
    }

    if (std.mem.eql(u8, name, "order_status")) {
        const oid = intOf(a.get("order_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_id");
        var status: c_int = undefined;
        const rc = core.c_api.da_order_status(handle, orderIdToHandle(oid), &status);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        const st_enum: core.c_api.DaOrderStatus = @enumFromInt(status);
        const msg = try std.fmt.allocPrint(allocator, "{{\"status\":{d},\"status_text\":\"{s}\"}}", .{ status, statusToText(st_enum) });
        defer allocator.free(msg);
        return try buildToolResult(allocator, id, msg, false);
    }

    if (std.mem.eql(u8, name, "order_events")) {
        const oid = intOf(a.get("order_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_id");
        const since = intOf(a.get("since_event_id")) orelse 0;
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_order_events_json(handle, orderIdToHandle(oid), since, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "ship_order")) {
        const oid = intOf(a.get("order_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_id");
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_order_ship_json(handle, orderIdToHandle(oid), &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "pr_merge")) {
        const pid = intOf(a.get("pr_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing pr_id");
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_pr_merge(handle, pid, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "prs_list")) {
        const oid = intOf(a.get("order_id")) orelse 0;
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_prs_json(handle, oid, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "repo_clone")) {
        const url = stringOf(a.get("url")) orelse return try buildErrorResp(allocator, id, -32602, "missing url");
        const dir = stringOf(a.get("target_dir")) orelse return try buildErrorResp(allocator, id, -32602, "missing target_dir");
        const url_z = try allocator.dupeZ(u8, url);
        defer allocator.free(url_z);
        const dir_z = try allocator.dupeZ(u8, dir);
        defer allocator.free(dir_z);
        const rc = core.c_api.da_repo_clone(handle, url_z, dir_z);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"cloned\":true}", false);
    }

    if (std.mem.eql(u8, name, "sessions")) {
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_sessions_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "session_messages")) {
        const oid = intOf(a.get("order_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_id");
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_session_messages_json(handle, orderIdToHandle(oid), &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "session_timeline")) {
        const oid = intOf(a.get("order_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_id");
        const offset = intOf(a.get("offset")) orelse 0;
        const limit = intOf(a.get("limit")) orelse 50;
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_session_timeline_json(handle, orderIdToHandle(oid), offset, limit, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "health")) {
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_health_detail_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "health_probe_all")) {
        // un `max_models` presente pero de tipo no-numérico (string, bool,
        // array) se tragaba la peticion: `intOf` devolvia null, el `orelse 0`
        // lo convertia en «sin limite», y el cliente esperaba una respuesta
        // que llegaba tarde y como error de protocolo generico. Como las
        // otras 61 tools: -32602 ANTES de despachar. Medido 2026-09-01
        // invocando desde la cabina con {"max_models": "esto no es un numero"}.
        if (a.get("max_models")) |mv| {
            if (mv != .null and intOf(mv) == null) {
                return try buildErrorResp(allocator, id, -32602, "max_models must be an integer");
            }
        }
        const max_models_value = intOf(a.get("max_models")) orelse 0;
        if (max_models_value < 0 or max_models_value > @as(i64, std.math.maxInt(c_int))) {
            return try buildErrorResp(allocator, id, -32602, "max_models must be a non-negative c_int");
        }
        const max_models: c_int = @intCast(max_models_value);
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_health_probe_all_json(handle, max_models, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "router_candidates")) {
        const tt = stringOf(a.get("task_type")) orelse return try buildErrorResp(allocator, id, -32602, "missing task_type");
        const tt_z = try allocator.dupeZ(u8, tt);
        defer allocator.free(tt_z);
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_router_candidates_json(handle, tt_z, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "catalog_info")) {
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_catalog_info_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "ledger_escalations")) {
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_ledger_escalations_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "audit_ledger")) {
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_audit_ledger_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "audit_checklist")) {
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_audit_checklist_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "memory_context")) {
        const project = stringOf(a.get("project")) orelse "data";
        const project_z = try allocator.dupeZ(u8, project);
        defer allocator.free(project_z);
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_memory_context_json(handle, project_z, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "usage_summary")) {
        // `order_id` fuera de c_int hacía panic en el @intCast — una
        // línea JSON tumbaba el servidor por esta tool ABIERTA. Mismo guard
        // que health_probe_all.
        const oid_i = intOf(a.get("order_id")) orelse 0;
        if (oid_i < 0 or oid_i > @as(i64, std.math.maxInt(c_int))) {
            return try buildErrorResp(allocator, id, -32602, "order_id must be a non-negative c_int");
        }
        const oid: c_int = @intCast(oid_i);
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_usage_summary_json(handle, oid, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "web_search")) {
        const query = stringOf(a.get("query")) orelse return try buildErrorResp(allocator, id, -32602, "missing query");
        const query_z = try allocator.dupeZ(u8, query);
        defer allocator.free(query_z);
        const max_results: c_int = blk: {
            // fuera de c_int → panic en el cast. Guard como los demás.
            const m = intOf(a.get("max_results")) orelse 5;
            if (m < 0 or m > @as(i64, std.math.maxInt(c_int))) {
                return try buildErrorResp(allocator, id, -32602, "max_results must be a non-negative c_int");
            }
            break :blk @intCast(m);
        };
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_web_search(handle, query_z, max_results, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "repo_search")) {
        // E5.14: ranking BM25 lexico del motor — el JSON de args se reenvia
        // tal cual ({query, root?, max_results?}); el motor valida.
        const query = stringOf(a.get("query")) orelse return try buildErrorResp(allocator, id, -32602, "missing query");
        var arg_buf: std.Io.Writer.Allocating = .init(allocator);
        defer arg_buf.deinit();
        var ajs: std.json.Stringify = .{ .writer = &arg_buf.writer, .options = .{} };
        try ajs.beginObject();
        try ajs.objectField("query");
        try ajs.write(query);
        if (stringOf(a.get("root"))) |root| {
            try ajs.objectField("root");
            try ajs.write(root);
        }
        if (intOf(a.get("max_results"))) |mr| {
            try ajs.objectField("max_results");
            try ajs.write(mr);
        }
        if (stringOf(a.get("mode"))) |mode| {
            try ajs.objectField("mode");
            try ajs.write(mode);
        }
        try ajs.endObject();
        const arg_z = try allocator.dupeZ(u8, arg_buf.written());
        defer allocator.free(arg_z);
        var out: ?[*:0]u8 = null;
        const rc = core.c_api.da_repo_search(handle, arg_z, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        const body = out orelse return try buildErrorResp(allocator, id, -32603, "repo_search: salida nula del motor");
        defer core.c_api.da_string_free(body);
        return try buildToolResult(allocator, id, std.mem.span(body), false);
    }

    // E5.15: las tres tools nuevas comparten el mismo shape ({root?} /
    // {provider?,model?} → el motor valida). Se reenvía el objeto args tal
    // cual para no duplicar la validación.
    if (std.mem.eql(u8, name, "repo_embed_index") or
        std.mem.eql(u8, name, "repo_embed_status") or
        std.mem.eql(u8, name, "embeddings_probe"))
    {
        var arg_buf: std.Io.Writer.Allocating = .init(allocator);
        defer arg_buf.deinit();
        var ajs: std.json.Stringify = .{ .writer = &arg_buf.writer, .options = .{} };
        try ajs.beginObject();
        if (stringOf(a.get("root"))) |root| {
            try ajs.objectField("root");
            try ajs.write(root);
        }
        if (stringOf(a.get("model"))) |mdl| {
            try ajs.objectField("model");
            try ajs.write(mdl);
        }
        if (stringOf(a.get("provider"))) |prv| {
            try ajs.objectField("provider");
            try ajs.write(prv);
        }
        try ajs.endObject();
        const arg_z = try allocator.dupeZ(u8, arg_buf.written());
        defer allocator.free(arg_z);
        var out: ?[*:0]u8 = null;
        const rc = if (std.mem.eql(u8, name, "repo_embed_index"))
            core.c_api.da_repo_embed_index(handle, arg_z, &out)
        else if (std.mem.eql(u8, name, "repo_embed_status"))
            core.c_api.da_repo_embed_status(handle, arg_z, &out)
        else
            core.c_api.da_embeddings_probe_json(handle, arg_z, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        const body = out orelse return try buildErrorResp(allocator, id, -32603, "embed: salida nula del motor");
        defer core.c_api.da_string_free(body);
        return try buildToolResult(allocator, id, std.mem.span(body), false);
    }

    if (std.mem.eql(u8, name, "embeddings_config_get")) {
        var out: ?[*:0]u8 = null;
        const rc = core.c_api.da_embeddings_config_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        const body2 = out orelse return try buildErrorResp(allocator, id, -32603, "embeddings_config: salida nula");
        defer core.c_api.da_string_free(body2);
        return try buildToolResult(allocator, id, std.mem.span(body2), false);
    }

    if (std.mem.eql(u8, name, "embeddings_config_set")) {
        const json = stringOf(a.get("json")) orelse return try buildErrorResp(allocator, id, -32602, "missing json");
        const json_z = try allocator.dupeZ(u8, json);
        defer allocator.free(json_z);
        const rc = core.c_api.da_embeddings_config_set(handle, json_z);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"ok\":true}", false);
    }

    if (std.mem.eql(u8, name, "approvals_list")) {
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_approval_pending_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        // r3: el JSON del motor lista los prefixes que core conoce
        // (shell_command, worktree_script, inline_command, agent_acp) y NO
        // incluye las solicitudes spaces registradas por este servidor (gap
        // del motor documentado en informe.txt). Se les añade aquí una
        // consulta perezosa a la tabla compartida para que el humano vea
        // también la solicitud de space_archive/spaces_prune pendiente.
        var merged: std.Io.Writer.Allocating = .init(allocator);
        defer merged.deinit();
        var js: std.json.Stringify = .{ .writer = &merged.writer, .options = .{} };
        var engine_rows = std.json.parseFromSlice(std.json.Value, allocator, std.mem.span(out), .{}) catch return try buildErrorResp(allocator, id, -32603, "approvals_list: json inválido del núcleo");
        defer engine_rows.deinit();
        try js.beginArray();
        if (engine_rows.value == .array) {
            for (engine_rows.value.array.items) |row| try js.write(row);
        } else {
            try js.write(engine_rows.value);
        }
        if (ctx.spacesApprovalConn()) |conn| {
            const stmt = conn.prepare("SELECT id, task_id, description, args_json, order_id, exe FROM approvals WHERE resolved = 0 AND command_prefix = ? AND origin = ?");
            if (stmt) |s| {
                defer conn.finalize(s);
                if (core.db.bindText(s, 1, SPACES_MCP_PREFIX)) {} else |_| {}
                if (core.db.bindText(s, 2, ctx.session_tag orelse "")) {} else |_| {}
                while (core.db.c.sqlite3_step(s) == core.db.c.SQLITE_ROW) {
                    const approval_id = core.db.c.sqlite3_column_int64(s, 0);
                    var already_listed = false;
                    if (engine_rows.value == .array) for (engine_rows.value.array.items) |row| {
                        if (row == .object) if (row.object.get("id")) |value| {
                            if (value == .integer and value.integer == approval_id) already_listed = true;
                        };
                    };
                    if (already_listed) continue;
                    try js.beginObject();
                    try js.objectField("id");
                    try js.write(approval_id);
                    try js.objectField("task_id");
                    try js.write(sqliteColumnText(s, 1));
                    try js.objectField("description");
                    try js.write(sqliteColumnText(s, 2));
                    try js.objectField("command_prefix");
                    try js.write(SPACES_MCP_PREFIX);
                    try js.objectField("exe");
                    try js.write(sqliteColumnText(s, 5));
                    try js.objectField("args_json");
                    try js.write(sqliteColumnText(s, 3));
                    try js.objectField("order_id");
                    try js.write(core.db.c.sqlite3_column_int64(s, 4));
                    try js.endObject();
                }
            } else |_| {}
        } else |_| {}
        try js.endArray();
        const merged_json = try allocator.dupe(u8, merged.written());
        defer allocator.free(merged_json);
        return try buildToolResult(allocator, id, merged_json, false);
    }

    if (std.mem.eql(u8, name, "ui_action")) {
        // UI-ACTION: el agente pide una acción cosmética sobre la cabina.
        // {action, args?} se valida contra el allowlist del motor; la cabina la
        // aplica al drenar eventos y reporta el ack en ui_action_result.
        const action = stringOf(a.get("action")) orelse return try buildErrorResp(allocator, id, -32602, "missing action");
        const order_id = intOf(a.get("order_id")) orelse 0;
        var payload_buf: std.Io.Writer.Allocating = .init(allocator);
        defer payload_buf.deinit();
        var js: std.json.Stringify = .{ .writer = &payload_buf.writer, .options = .{} };
        try js.beginObject();
        try js.objectField("action");
        try js.write(action);
        if (a.get("args")) |args_v| {
            try js.objectField("args");
            try js.write(args_v);
        }
        try js.endObject();
        const payload_json = try allocator.dupeZ(u8, payload_buf.written());
        defer allocator.free(payload_json);
        var event_id: i64 = 0;
        const rc = core.c_api.da_ui_action_request(handle, payload_json.ptr, order_id, &event_id);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        const msg = try std.fmt.allocPrint(allocator, "{{\"ok\":true,\"event_id\":{d}}}", .{event_id});
        defer allocator.free(msg);
        return try buildToolResult(allocator, id, msg, false);
    }

    if (std.mem.eql(u8, name, "shell_run")) {
        const exe = stringOf(a.get("exe")) orelse return try buildErrorResp(allocator, id, -32602, "missing exe");
        const cwd = stringOf(a.get("cwd")) orelse ".";
        const timeout = intOf(a.get("timeout_ms")) orelse 30000;
        if (timeout <= 0 or timeout > 300_000) return try buildErrorResp(allocator, id, -32602, "timeout_ms fuera de rango");

        var cmd_out: std.Io.Writer.Allocating = .init(allocator);
        defer cmd_out.deinit();
        var js: std.json.Stringify = .{ .writer = &cmd_out.writer, .options = .{} };
        try js.beginObject();
        try js.objectField("exe");
        try js.write(exe);
        try js.objectField("args");
        try js.beginArray();
        if (a.get("args")) |args_v| {
            if (args_v != .array) return try buildErrorResp(allocator, id, -32602, "args debe ser un array de strings");
            for (args_v.array.items) |item| {
                if (item != .string) return try buildErrorResp(allocator, id, -32602, "args debe ser un array de strings");
                try js.write(item.string);
            }
        }
        try js.endArray();
        try js.objectField("cwd");
        try js.write(cwd);
        if (stringOf(a.get("root"))) |root| {
            try js.objectField("root");
            try js.write(root);
        }
        try js.objectField("timeout_ms");
        try js.write(timeout);
        try js.endObject();

        const cmd_json = cmd_out.written();
        const cmd_z = try allocator.dupeZ(u8, cmd_json);
        defer allocator.free(cmd_z);

        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_shell_run(handle, cmd_z, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "run_detached")) {
        const exe = stringOf(a.get("exe")) orelse return try buildErrorResp(allocator, id, -32602, "missing exe");
        const cwd = stringOf(a.get("cwd")) orelse ".";

        var cmd_out: std.Io.Writer.Allocating = .init(allocator);
        defer cmd_out.deinit();
        var js2: std.json.Stringify = .{ .writer = &cmd_out.writer, .options = .{} };
        try js2.beginObject();
        try js2.objectField("exe");
        try js2.write(exe);
        try js2.objectField("args");
        try js2.beginArray();
        if (a.get("args")) |args_v| {
            if (args_v != .array) return try buildErrorResp(allocator, id, -32602, "args debe ser un array de strings");
            for (args_v.array.items) |item| {
                if (item != .string) return try buildErrorResp(allocator, id, -32602, "args debe ser un array de strings");
                try js2.write(item.string);
            }
        }
        try js2.endArray();
        try js2.objectField("cwd");
        try js2.write(cwd);
        try js2.endObject();

        const cmd_json = cmd_out.written();
        const cmd_z = try allocator.dupeZ(u8, cmd_json);
        defer allocator.free(cmd_z);

        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_run_detached(handle, cmd_z, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "discover_models")) {
        var count: c_int = 0;
        const rc = core.c_api.da_models_discover(handle, &count);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        // FIX-DISCOVER-P0: return degraded info when 0 models found, so the caller
        // knows it's a credential issue (401/quota) not a silent empty response.
        if (count > 0) {
            const msg = try std.fmt.allocPrint(allocator, "{{\"discovered_count\":{d},\"degraded\":false}}", .{count});
            defer allocator.free(msg);
            return try buildToolResult(allocator, id, msg, false);
        } else {
            const msg = try std.fmt.allocPrint(allocator, "{{\"discovered_count\":0,\"degraded\":true,\"reason\":\"no providers returned models — check API keys and health status\"}}", .{});
            defer allocator.free(msg);
            return try buildToolResult(allocator, id, msg, false);
        }
    }

    if (std.mem.eql(u8, name, "catalog_reconcile_enabled")) {
        const rc = core.c_api.da_catalog_reconcile_enabled(handle);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"ok\":true}", false);
    }

    if (std.mem.eql(u8, name, "dispatch_async")) {
        const oid = intOf(a.get("order_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_id");
        const rc = core.c_api.da_order_dispatch_async(handle, orderIdToHandle(oid));
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"ok\":true}", false);
    }

    if (std.mem.eql(u8, name, "dispatch_cancel")) {
        const oid = intOf(a.get("order_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_id");
        const rc = core.c_api.da_order_cancel(handle, orderIdToHandle(oid));
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        const msg = try std.fmt.allocPrint(allocator, "{{\"ok\":true,\"order_id\":{d}}}", .{oid});
        defer allocator.free(msg);
        return try buildToolResult(allocator, id, msg, false);
    }

    if (std.mem.eql(u8, name, "plan_cancel")) {
        const oid = intOf(a.get("order_id")) orelse 0;
        const rc = core.c_api.da_plan_cancel(handle, if (oid > 0) orderIdToHandle(oid) else null);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        const msg = try std.fmt.allocPrint(allocator, "{{\"ok\":true,\"order_id\":{d}}}", .{oid});
        defer allocator.free(msg);
        return try buildToolResult(allocator, id, msg, false);
    }

    if (std.mem.eql(u8, name, "dispatch_poll")) {
        const oid = intOf(a.get("order_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_id");
        var done: c_int = 0;
        var ok_flag: c_int = 0;
        const rc = core.c_api.da_order_dispatch_poll(handle, orderIdToHandle(oid), &done, &ok_flag);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        const msg = try std.fmt.allocPrint(allocator, "{{\"done\":{d},\"ok\":{d}}}", .{ done, ok_flag });
        defer allocator.free(msg);
        return try buildToolResult(allocator, id, msg, false);
    }

    if (std.mem.eql(u8, name, "worker_output")) {
        const since = intOf(a.get("since_ms")) orelse 0;
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_worker_output_poll(handle, since, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    // ── Seleccion de modelo (F7-MODEL-SELECT) ──
    if (std.mem.eql(u8, name, "plan_set_model")) {
        const prov = stringOf(a.get("provider")) orelse "";
        const mod = stringOf(a.get("model")) orelse "";
        const prov_z = try allocator.dupeZ(u8, prov);
        defer allocator.free(prov_z);
        const mod_z = try allocator.dupeZ(u8, mod);
        defer allocator.free(mod_z);
        const prov_ptr: ?[*:0]const u8 = if (prov.len > 0) prov_z else null;
        const mod_ptr: ?[*:0]const u8 = if (mod.len > 0) mod_z else null;
        const rc = core.c_api.da_plan_set_model(handle, prov_ptr, mod_ptr);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"ok\":true}", false);
    }

    if (std.mem.eql(u8, name, "plan_get_model")) {
        var out_prov: ?[*:0]const u8 = null;
        var out_mod: ?[*:0]const u8 = null;
        const rc = core.c_api.da_plan_get_model(handle, &out_prov, &out_mod);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        const prov_str = if (out_prov) |s| std.mem.span(s) else "";
        const model_str = if (out_mod) |s| std.mem.span(s) else "";
        const msg = try std.fmt.allocPrint(allocator, "{{\"provider\":\"{s}\",\"model\":\"{s}\"}}", .{ prov_str, model_str });
        if (out_prov) |s| core.c_api.da_string_free(@constCast(s));
        if (out_mod) |s| core.c_api.da_string_free(@constCast(s));
        defer allocator.free(msg);
        return try buildToolResult(allocator, id, msg, false);
    }

    // ROLES-MODELO: mismo contrato que plan_set_model/plan_get_model pero para
    // los pines del ejecutor y del auditor.
    if (std.mem.eql(u8, name, "exec_set_model")) {
        const prov = stringOf(a.get("provider")) orelse "";
        const mod = stringOf(a.get("model")) orelse "";
        const prov_z = try allocator.dupeZ(u8, prov);
        defer allocator.free(prov_z);
        const mod_z = try allocator.dupeZ(u8, mod);
        defer allocator.free(mod_z);
        const prov_ptr: ?[*:0]const u8 = if (prov.len > 0) prov_z else null;
        const mod_ptr: ?[*:0]const u8 = if (mod.len > 0) mod_z else null;
        const rc = core.c_api.da_exec_set_model(handle, prov_ptr, mod_ptr);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"ok\":true}", false);
    }

    if (std.mem.eql(u8, name, "audit_set_model")) {
        const prov = stringOf(a.get("provider")) orelse "";
        const mod = stringOf(a.get("model")) orelse "";
        const prov_z = try allocator.dupeZ(u8, prov);
        defer allocator.free(prov_z);
        const mod_z = try allocator.dupeZ(u8, mod);
        defer allocator.free(mod_z);
        const prov_ptr: ?[*:0]const u8 = if (prov.len > 0) prov_z else null;
        const mod_ptr: ?[*:0]const u8 = if (mod.len > 0) mod_z else null;
        const rc = core.c_api.da_audit_set_model(handle, prov_ptr, mod_ptr);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"ok\":true}", false);
    }

    if (std.mem.eql(u8, name, "exec_get_model")) {
        var out_prov: ?[*:0]const u8 = null;
        var out_mod: ?[*:0]const u8 = null;
        const rc = core.c_api.da_exec_get_model(handle, &out_prov, &out_mod);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        const prov_str = if (out_prov) |s| std.mem.span(s) else "";
        const model_str = if (out_mod) |s| std.mem.span(s) else "";
        const msg = try std.fmt.allocPrint(allocator, "{{\"provider\":\"{s}\",\"model\":\"{s}\"}}", .{ prov_str, model_str });
        if (out_prov) |s| core.c_api.da_string_free(@constCast(s));
        if (out_mod) |s| core.c_api.da_string_free(@constCast(s));
        defer allocator.free(msg);
        return try buildToolResult(allocator, id, msg, false);
    }

    if (std.mem.eql(u8, name, "audit_get_model")) {
        var out_prov: ?[*:0]const u8 = null;
        var out_mod: ?[*:0]const u8 = null;
        const rc = core.c_api.da_audit_get_model(handle, &out_prov, &out_mod);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        const prov_str = if (out_prov) |s| std.mem.span(s) else "";
        const model_str = if (out_mod) |s| std.mem.span(s) else "";
        const msg = try std.fmt.allocPrint(allocator, "{{\"provider\":\"{s}\",\"model\":\"{s}\"}}", .{ prov_str, model_str });
        if (out_prov) |s| core.c_api.da_string_free(@constCast(s));
        if (out_mod) |s| core.c_api.da_string_free(@constCast(s));
        defer allocator.free(msg);
        return try buildToolResult(allocator, id, msg, false);
    }

    // ENJAMBRE: el array viaja tal cual — el motor valida la forma
    // ([{provider,model}], max. 8) y normaliza. [] = Automatico.
    if (std.mem.eql(u8, name, "swarm_set_models")) {
        const models_val = a.get("models") orelse
            return try buildErrorResp(allocator, id, -32602, "missing models");
        if (models_val != .array)
            return try buildErrorResp(allocator, id, -32602, "models debe ser un array [{provider,model}]");
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try js.write(models_val);
        const json_z = try allocator.dupeZ(u8, out.written());
        defer allocator.free(json_z);
        const rc = core.c_api.da_swarm_set_models_json(handle, json_z);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"ok\":true}", false);
    }

    if (std.mem.eql(u8, name, "swarm_get_models")) {
        var out: ?[*:0]const u8 = null;
        const rc = core.c_api.da_swarm_get_models_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        const body = if (out) |s| std.mem.span(s) else "[]";
        defer if (out) |s| core.c_api.da_string_free(@constCast(s));
        return try buildToolResult(allocator, id, body, false);
    }

    if (std.mem.eql(u8, name, "paid_budget_get")) {
        var out: [*:0]u8 = undefined;
        if (core.c_api.da_budget_state_json(handle, &out) != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }
    if (std.mem.eql(u8, name, "order_preflight")) {
        var out: ?[*:0]const u8 = null;
        if (core.c_api.da_order_preflight_json(handle, &out) != 0) return try lastErrorToolResult(allocator, id);
        defer if (out) |text| core.c_api.da_string_free(@constCast(text));
        return try buildToolResult(allocator, id, if (out) |text| std.mem.span(text) else "{}", false);
    }

    // ── E5.08: agentes externos ──
    if (std.mem.eql(u8, name, "agents_external_list") or std.mem.eql(u8, name, "agents_external_refresh")) {
        var out: ?[*:0]const u8 = null;
        const rc = if (std.mem.eql(u8, name, "agents_external_refresh")) core.c_api.da_external_agents_refresh(handle, &out) else core.c_api.da_external_agents_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        const body = if (out) |s| std.mem.span(s) else "[]";
        defer if (out) |s| core.c_api.da_string_free(@constCast(s));
        return try buildToolResult(allocator, id, body, false);
    }

    if (std.mem.eql(u8, name, "external_paths_get")) {
        var out: ?[*:0]const u8 = null;
        if (core.c_api.da_external_paths_json(handle, &out) != 0) return try lastErrorToolResult(allocator, id);
        defer if (out) |s| core.c_api.da_string_free(@constCast(s));
        return try buildToolResult(allocator, id, if (out) |s| std.mem.span(s) else "{}", false);
    }
    if (std.mem.eql(u8, name, "external_model_options_set")) {
        const json = stringOf(a.get("json")) orelse return try buildErrorResp(allocator, id, -32602, "missing json");
        const z = try allocator.dupeZ(u8, json);
        defer allocator.free(z);
        const rc = core.c_api.da_external_model_options_set(handle, z);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"ok\":true}", false);
    }

    if (std.mem.eql(u8, name, "external_limits_get")) {
        var out: ?[*:0]const u8 = null;
        const rc = core.c_api.da_external_limits_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        const body = if (out) |s| std.mem.span(s) else "{}";
        defer if (out) |s| core.c_api.da_string_free(@constCast(s));
        return try buildToolResult(allocator, id, body, false);
    }

    if (std.mem.eql(u8, name, "models_list")) {
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_models_list_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }
    if (std.mem.eql(u8, name, "models_selection_v1") or std.mem.eql(u8, name, "models_preferences_set_v1")) {
        var out: ?[*:0]const u8 = null;
        const rc = if (std.mem.eql(u8, name, "models_selection_v1"))
            core.c_api.da_models_selection_v1_json(handle, &out)
        else blk: {
            const json = stringOf(a.get("json")) orelse return try buildErrorResp(allocator, id, -32602, "missing json");
            const json_z = try allocator.dupeZ(u8, json);
            defer allocator.free(json_z);
            break :blk core.c_api.da_model_preferences_set_v1_json(handle, json_z, &out);
        };
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        const body = out orelse return try buildErrorResp(allocator, id, -32603, "empty selection response");
        defer core.c_api.da_string_free(@constCast(body));
        return try buildToolResult(allocator, id, std.mem.span(body), false);
    }

    // ── Gestion de claves (KEY-MGMT) ──
    if (std.mem.eql(u8, name, "add_key")) {
        const provider = stringOf(a.get("provider")) orelse return try buildErrorResp(allocator, id, -32602, "missing provider");
        const key = stringOf(a.get("key")) orelse return try buildErrorResp(allocator, id, -32602, "missing key");
        const label = stringOf(a.get("label")) orelse "default";
        const provider_z = try allocator.dupeZ(u8, provider);
        defer allocator.free(provider_z);
        const key_z = try allocator.dupeZ(u8, key);
        defer allocator.free(key_z);
        const label_z = try allocator.dupeZ(u8, label);
        defer allocator.free(label_z);
        const rc = core.c_api.da_key_add(handle, provider_z, label_z, key_z);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"ok\":true}", false);
    }

    if (std.mem.eql(u8, name, "remove_key")) {
        const provider = stringOf(a.get("provider")) orelse return try buildErrorResp(allocator, id, -32602, "missing provider");
        const label = stringOf(a.get("label")) orelse "";
        const provider_z = try allocator.dupeZ(u8, provider);
        defer allocator.free(provider_z);
        const label_z = try allocator.dupeZ(u8, label);
        defer allocator.free(label_z);
        const rc = core.c_api.da_key_remove(handle, provider_z, label_z);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"ok\":true}", false);
    }

    if (std.mem.eql(u8, name, "list_keys")) {
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_keys_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    // ── MCP / Skills / Mounts (PANEL-ADDONS) ──
    if (std.mem.eql(u8, name, "mcp_disconnect")) {
        const rc = core.c_api.da_mcp_disconnect(handle);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"ok\":true}", false);
    }

    if (std.mem.eql(u8, name, "mcp_is_connected")) {
        var connected: c_int = 0;
        const rc = core.c_api.da_mcp_is_connected(handle, &connected);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        const msg = try std.fmt.allocPrint(allocator, "{{\"connected\":{d}}}", .{connected});
        defer allocator.free(msg);
        return try buildToolResult(allocator, id, msg, false);
    }

    if (std.mem.eql(u8, name, "mcp_tools")) {
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_mcp_tools_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "mcp_call_tool")) {
        const tool_name = stringOf(a.get("name")) orelse return try buildErrorResp(allocator, id, -32602, "missing name");
        const args_json = stringOf(a.get("args_json")) orelse return try buildErrorResp(allocator, id, -32602, "missing args_json");
        const name_z = try allocator.dupeZ(u8, tool_name);
        defer allocator.free(name_z);
        const args_z = try allocator.dupeZ(u8, args_json);
        defer allocator.free(args_z);
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_mcp_call_tool(handle, name_z, args_z, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "set_workspace_root")) {
        const wpath = stringOf(a.get("path")) orelse return try buildErrorResp(allocator, id, -32602, "missing path");
        const path_z = try allocator.dupeZ(u8, wpath);
        defer allocator.free(path_z);
        const rc = core.c_api.da_set_workspace_root(handle, path_z);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"ok\":true}", false);
    }

    //: paridad MCP de core.space.create (bridge.cpp:3265).
    // Los argumentos se validan ANTES de tocar el motor, como el resto de tools;
    // el resultado imita al puente: create devuelve la ficha del motor. r2 (P2):
    // un argumento PRESENTE con tipo incorrecto se rechaza (-32602), nunca se
    // silencia a su default; ausente si toma el default del puente.
    // space_archive y spaces_prune no llegan aqui: el veto de aprobación humana
    // los resuelve antes (handleToolCall, arriba).
    if (std.mem.eql(u8, name, "space_create")) {
        if (try rejectUnknownArgs(allocator, id, a, &SPACE_CREATE_FIELDS)) |resp| return resp;
        if (a.get("project_id")) |v| {
            if (v != .string) return try buildErrorResp(allocator, id, -32602, "project_id presente debe ser string");
        }
        if (a.get("kind")) |v| {
            if (v != .string) return try buildErrorResp(allocator, id, -32602, "kind presente debe ser string");
        }
        const project_id = stringOf(a.get("project_id")) orelse "default";
        const space_name = stringOf(a.get("name")) orelse return try buildErrorResp(allocator, id, -32602, "missing name");
        const kind = stringOf(a.get("kind")) orelse "order";
        const project_z = try allocator.dupeZ(u8, project_id);
        defer allocator.free(project_z);
        const name_z = try allocator.dupeZ(u8, space_name);
        defer allocator.free(name_z);
        const kind_z = try allocator.dupeZ(u8, kind);
        defer allocator.free(kind_z);
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_space_create(handle, project_z, name_z, kind_z, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "list_artifacts")) {
        const oid = intOf(a.get("order_id")) orelse 0;
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_list_artifacts_json(handle, oid, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "skills_discover")) {
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_skills_discover_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    // P12-T1: Inventario unificado
    if (std.mem.eql(u8, name, "remote_start")) {
        // e5-harden punto 8: un cliente MCP es un agente; no recibe la credencial del
        // acceso remoto ni abre un listener. Se valida igual la forma de los argumentos.
        const port_value: i64 = if (a.get("port")) |value| intOf(value) orelse return try buildErrorResp(allocator, id, -32602, "invalid port") else 0;
        if (port_value < 0 or port_value > 65535) return try buildErrorResp(allocator, id, -32602, "invalid port");
        const address = if (a.get("bind")) |value| stringOf(value) orelse return try buildErrorResp(allocator, id, -32602, "invalid bind") else "127.0.0.1";
        core.remote_server.checkBind(address) catch return try buildToolResult(allocator, id, "Solo se permite 127.0.0.1.", true);
        if (a.get("origin")) |value| if (stringOf(value) == null) return try buildErrorResp(allocator, id, -32602, "invalid origin");
        return try buildToolResult(allocator, id, "El acceso remoto se inicia desde la cabina (Ajustes, Acceso remoto), que es donde se muestra el token: inicia el acceso remoto allí. MCP no devuelve credenciales.", true);
    }
    if (std.mem.eql(u8, name, "remote_stop")) {
        if (ctx.remote_session) |session| {
            session.stop(ctx.allocator);
            ctx.remote_session = null;
        }
        return try buildToolResult(allocator, id, "{\"running\":false}", false);
    }
    if (std.mem.eql(u8, name, "remote_status")) {
        if (ctx.remote_session) |session| {
            const result = try std.fmt.allocPrint(allocator, "{{\"running\":{s},\"url\":\"http://127.0.0.1:{d}\"}}", .{ if (session.failed.load(.acquire)) "false" else "true", session.server.port });
            defer allocator.free(result);
            return try buildToolResult(allocator, id, result, false);
        }
        return try buildToolResult(allocator, id, "{\"running\":false}", false);
    }
    if (std.mem.eql(u8, name, "webhooks_list")) {
        var out: [*:0]u8 = undefined;
        if (core.c_api.da_webhook_list_json(handle, &out) != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }
    if (std.mem.eql(u8, name, "webhook_add")) {
        const url = stringOf(a.get("url")) orelse return try buildErrorResp(allocator, id, -32602, "missing url");
        for ([_][]const u8{ "event", "format", "secret" }) |key| {
            if (a.get(key)) |v| if (v != .string) return try buildErrorResp(allocator, id, -32602, "invalid webhook field");
        }
        if (a.get("allow_private")) |v| if (v != .bool) return try buildErrorResp(allocator, id, -32602, "invalid allow_private boolean");
        const json = try std.json.Stringify.valueAlloc(allocator, .{ .url = url, .event = stringOf(a.get("event")) orelse "*", .format = stringOf(a.get("format")) orelse "json", .secret = stringOf(a.get("secret")), .allow_private = if (a.get("allow_private")) |v| v.bool else false }, .{});
        defer allocator.free(json);
        const json_z = try allocator.dupeZ(u8, json);
        defer allocator.free(json_z);
        var webhook_id: i64 = 0;
        if (core.c_api.da_webhook_add(handle, json_z, &webhook_id) != 0) return try lastErrorToolResult(allocator, id);
        const result = try std.fmt.allocPrint(allocator, "{{\"ok\":true,\"id\":{d}}}", .{webhook_id});
        defer allocator.free(result);
        return try buildToolResult(allocator, id, result, false);
    }
    if (std.mem.eql(u8, name, "webhook_delete") or std.mem.eql(u8, name, "webhook_test")) {
        const hook_id = intOf(a.get("id")) orelse return try buildErrorResp(allocator, id, -32602, "missing webhook id");
        if (hook_id <= 0) return try buildErrorResp(allocator, id, -32602, "invalid webhook id");
        const testing_hook = std.mem.eql(u8, name, "webhook_test");
        const rc = if (testing_hook) core.c_api.da_webhook_test(handle, hook_id) else core.c_api.da_webhook_delete(handle, hook_id);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, if (testing_hook) "{\"ok\":true,\"queued\":true}" else "{\"ok\":true}", false);
    }
    if (std.mem.eql(u8, name, "inventory")) {
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_inventory_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }
    if (std.mem.eql(u8, name, "inventory_refresh")) {
        const rc = core.c_api.da_inventory_refresh(handle);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"ok\":true}", false);
    }

    if (std.mem.eql(u8, name, "mount_add")) {
        const mpath = stringOf(a.get("path")) orelse return try buildErrorResp(allocator, id, -32602, "missing path");
        const path_z = try allocator.dupeZ(u8, mpath);
        defer allocator.free(path_z);
        const rc = core.c_api.da_mount_add(handle, path_z);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"ok\":true}", false);
    }

    if (std.mem.eql(u8, name, "mounts_list")) {
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_mounts_list_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    if (std.mem.eql(u8, name, "mount_remove")) {
        const mpath = stringOf(a.get("path")) orelse return try buildErrorResp(allocator, id, -32602, "missing path");
        const path_z = try allocator.dupeZ(u8, mpath);
        defer allocator.free(path_z);
        const rc = core.c_api.da_mount_remove(handle, path_z);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"ok\":true}", false);
    }

    // ── Preview embebido (F1) ──
    if (std.mem.eql(u8, name, "preview")) {
        const url = stringOf(a.get("url")) orelse return try buildErrorResp(allocator, id, -32602, "missing url");
        if (url.len == 0) return try buildErrorResp(allocator, id, -32602, "empty url");
        // Validar que sea localhost o 127.0.0.1 (gobernanza EXEC-01: bajo riesgo)
        const is_localhost = std.mem.startsWith(u8, url, "http://localhost:") or
            std.mem.startsWith(u8, url, "http://127.0.0.1:") or
            std.mem.startsWith(u8, url, "https://localhost:") or
            std.mem.startsWith(u8, url, "https://127.0.0.1:");
        if (!is_localhost) {
            const msg = try std.fmt.allocPrint(allocator, "{{\"ok\":false,\"error\":\"URL externa bloqueada (solo localhost permitido)\"}}", .{});
            defer allocator.free(msg);
            return try buildToolResult(allocator, id, msg, true);
        }
        const msg = try std.fmt.allocPrint(allocator, "{{\"ok\":true,\"url\":\"{s}\"}}", .{url});
        defer allocator.free(msg);
        return try buildToolResult(allocator, id, msg, false);
    }

    // ── Especialistas (PANEL-ESPECIALISTAS) ──
    if (std.mem.eql(u8, name, "specialists")) {
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_specialists_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    // ── T4: Capabilities — punto de entrada para cualquier IDE ──
    if (std.mem.eql(u8, name, "capabilities")) {
        const ver_ptr = core.c_api.da_core_version();
        const ver_str = std.mem.span(ver_ptr);

        var governance_out: [*:0]u8 = undefined;
        const governance_rc = core.c_api.da_get_governance_mode(handle, &governance_out);
        if (governance_rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(governance_out);
        const governance_mode = std.mem.span(governance_out);

        // Get providers list (includes key status, never key values)
        var prov_out: [*:0]u8 = undefined;
        const prov_rc = core.c_api.da_providers_list_json(handle, &prov_out);
        const prov_json = if (prov_rc == 0) blk: {
            defer core.c_api.da_string_free(prov_out);
            break :blk try allocator.dupe(u8, std.mem.span(prov_out));
        } else try allocator.dupe(u8, "[]");
        defer allocator.free(prov_json);

        // Get catalog info for data paths
        var cat_out: [*:0]u8 = undefined;
        const cat_rc = core.c_api.da_catalog_info_json(handle, &cat_out);
        const cat_json = if (cat_rc == 0) blk: {
            defer core.c_api.da_string_free(cat_out);
            break :blk try allocator.dupe(u8, std.mem.span(cat_out));
        } else try allocator.dupe(u8, "{}");
        defer allocator.free(cat_json);

        // (C3): capabilities informa la carpeta REAL abierta. Sin
        // ctx.data_dir (caso cwd) se resuelve con la misma funcion unica que
        // main: jamás se devuelve el placeholder «(cwd default)»; si el override
        // del entorno es inútil, se dice el fallo cerrado en vez de mentir.
        var resolved_dd: ?[]u8 = null;
        defer if (resolved_dd) |liberado| allocator.free(liberado);
        const dd_str: []const u8 = if (ctx.data_dir) |d| d else blk: {
            const r = core.paths.resolveDataDir(allocator, null) catch break :blk @as([]const u8, "carpeta de datos no valida (BEATS_DATA_DIR/DEVAGENTS_DATA_DIR debe ser absoluta y existente)");
            resolved_dd = r.dir;
            break :blk @as([]const u8, resolved_dd.?);
        };

        var payload_buf: std.Io.Writer.Allocating = .init(allocator);
        defer payload_buf.deinit();
        var payload_js: std.json.Stringify = .{ .writer = &payload_buf.writer, .options = .{} };
        try writeCapabilitiesPayload(allocator, &payload_js, ver_str, dd_str, governance_mode, cat_json, prov_json);
        const msg = payload_buf.written();
        return try buildToolResult(allocator, id, msg, false);
    }

    // ── T1: session_rename ──
    if (std.mem.eql(u8, name, "session_rename")) {
        const oid = intOf(a.get("order_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_id");
        const title = stringOf(a.get("title")) orelse return try buildErrorResp(allocator, id, -32602, "missing title");
        const title_z = try allocator.dupeZ(u8, title);
        defer allocator.free(title_z);
        const rc = core.c_api.da_session_rename(handle, orderIdToHandle(oid), title_z);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"ok\":true}", false);
    }

    // ── T1: health_summary ──
    if (std.mem.eql(u8, name, "health_summary")) {
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_health_summary_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    // P10-T1: pricing_revalidate
    if (std.mem.eql(u8, name, "pricing_revalidate")) {
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_pricing_revalidate(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    // P10-T3: model_scores
    if (std.mem.eql(u8, name, "model_scores")) {
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_model_scores_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    // QA-B 2a/H4: estado y resultado de una aprobación (solo lectura).
    if (std.mem.eql(u8, name, "approval_result")) {
        const aid = intOf(a.get("approval_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing approval_id");
        if (aid <= 0) return try buildErrorResp(allocator, id, -32602, "approval_id debe ser > 0");
        var out: [*:0]u8 = undefined;
        if (core.c_api.da_approval_result_json(handle, aid, &out) != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    // P10-T4: capture_screenshot. QA-B H4: por MCP solo registra la
    // aprobación (da_capture_screenshot con mcp_surface); no captura nada.
    // T12 A1: `screenshot` (nombre antiguo, P-VIS) capturaba en este proceso
    // sin humano; se conserva el nombre para los clientes que ya lo llaman,
    // pero va por la MISMA aprobación screen_capture: pending + approval_id,
    // la cabina captura al aprobar y el resultado se recoge con approval_result.
    if (std.mem.eql(u8, name, "capture_screenshot") or std.mem.eql(u8, name, "screenshot")) {
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_capture_screenshot(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    // P10-T5: evolution_summary
    if (std.mem.eql(u8, name, "evolution_summary")) {
        var out: [*:0]u8 = undefined;
        const rc = core.c_api.da_evolution_summary_json(handle, &out);
        if (rc != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }

    return try buildErrorResp(allocator, id, -32601, "unknown tool");
}

fn lastErrorToolResult(allocator: std.mem.Allocator, id: i64) ![]u8 {
    var err: [*:0]u8 = undefined;
    _ = core.c_api.da_last_error(&err);
    defer core.c_api.da_string_free(err);
    return try buildToolResult(allocator, id, std.mem.span(err), true);
}

// ---------------------------------------------------------------------------
// T7 (d): paridad con la cabina — spaces, plan, sesiones, archivos,
// git. Cada tool llama a lo que ya usa la cabina o el agente: C-ABI del motor
// (da_spaces_list_json, da_order_dispatch_async, da_order_replan_async,
// da_session_archive, da_shell_run) o las tools confinadas del agente
// (GovernedToolExecutor: read_file, list_dir, grep_files, write_file). La
// terminal es `shell_run` (da_shell_run: lista de programas, denylist,
// command_policy.decide y aprobación humana por comando para este origen).
// ---------------------------------------------------------------------------

const GIT_TIMEOUT_MS: i64 = 30_000;
const GIT_LOG_MAX: i64 = 200;
const GIT_ADD_MAX_PATHS: usize = 64;
const COMMIT_MESSAGE_MAX: usize = 4096;
const REPLAN_CHANGES_MAX: usize = 16384;

/// Mismas opciones que el git domesticado de la cabina (bridge.cpp
/// RunGitCapture): sin bloqueos opcionales, rutas literales, sin fsmonitor,
/// sin hooks y sin recorrer submódulos (y sin verificar firmas). QA-B 2a: es
/// el prefijo que `command_policy` reconoce para eximir status/diff/log.
const GIT_SAFE_PREFIX = core.command_policy.GIT_SAFE_PREFIX;

const SPACE_ROOT_FIELDS = [_]SchemaField{
    .{ .name = "space_id", .typ = "integer", .req = false, .desc = "Space (worktree) donde actuar; omitido = raíz del proyecto confinado.", .minimum = 1 },
    .{ .name = "project_id", .typ = "string", .req = false, .desc = "Proyecto del space (default 'default').", .min_length = 1, .max_length = 256 },
};

fn isParityTool(name: []const u8) bool {
    for ([_][]const u8{ "spaces_list", "plan_approve", "plan_replan", "session_archive", "fs_list", "fs_read", "fs_search", "fs_write", "git_status", "git_diff", "git_log", "git_add", "git_commit" }) |t| {
        if (std.mem.eql(u8, t, name)) return true;
    }
    return false;
}

/// Raíz donde actúan archivos y git: la carpeta del proyecto elegida (como el
/// modo Directo; la raíz efectiva si no hay ninguna) o el worktree de un
/// space activo dentro de ella.
/// Devuelve null con `reason` si el space no existe o queda fuera.
fn parityRoot(allocator: std.mem.Allocator, handle: *anyopaque, a: std.json.ObjectMap, reason: *[]const u8) !?[]u8 {
    var root_buf: [4096]u8 = undefined;
    // QA-B 2b: la carpeta del proyecto elegida, como el modo Directo (y la
    // raíz efectiva si no hay una elegida). Mismo confinamiento: las tools
    // del agente sobre esa raíz y los spaces solo si quedan dentro.
    const effective = core.workspace.projectOrEffectiveRoot(&root_buf);
    const space_id = intOf(a.get("space_id")) orelse return try allocator.dupe(u8, effective);
    const project = stringOf(a.get("project_id")) orelse "default";
    const project_z = try allocator.dupeZ(u8, project);
    defer allocator.free(project_z);
    var out: [*:0]u8 = undefined;
    if (core.c_api.da_spaces_list_json(handle, project_z.ptr, &out) != 0) {
        reason.* = "no se pudo leer la lista de spaces";
        return null;
    }
    defer core.c_api.da_string_free(out);
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, std.mem.span(out), .{}) catch {
        reason.* = "lista de spaces ilegible";
        return null;
    };
    defer parsed.deinit();
    const list = switch (parsed.value) {
        .array => |arr| arr.items,
        .object => |obj| if (obj.get("spaces")) |v| (if (v == .array) v.array.items else &.{}) else &.{},
        else => &.{},
    };
    for (list) |item| {
        if (item != .object) continue;
        const sid = intOf(item.object.get("id")) orelse continue;
        if (sid != space_id) continue;
        const path = stringOf(item.object.get("worktreePath")) orelse break;
        if (!core.workspace.resolvesInside(path, effective)) {
            reason.* = "el worktree del space queda fuera de la raiz confinada";
            return null;
        }
        return try allocator.dupe(u8, path);
    }
    reason.* = "space no encontrado o archivado en ese proyecto";
    return null;
}

/// Ejecuta una tool confinada del agente sobre `root` y devuelve su JSON.
fn runConfinedTool(allocator: std.mem.Allocator, id: i64, root: []const u8, tool_name: []const u8, args_json: []const u8) ![]u8 {
    var failed = false;
    return runConfinedToolStatus(allocator, id, root, tool_name, args_json, &failed);
}

fn runConfinedToolStatus(allocator: std.mem.Allocator, id: i64, root: []const u8, tool_name: []const u8, args_json: []const u8, failed_out: *bool) ![]u8 {
    failed_out.* = true;
    const GTE = core.governed_tool_executor.GovernedToolExecutor;
    var tool = GTE{
        .policy = .{ .workspace_root = root, .origin = .mcp },
        .plan_approved = true,
        .agentic = true,
        .allocator = allocator,
    };
    defer tool.deinitState(allocator);
    const response = GTE.execute(&tool, tool_name, args_json) catch |e| {
        const msg = try std.fmt.allocPrint(allocator, "{{\"error\":\"{s}\"}}", .{@errorName(e)});
        defer allocator.free(msg);
        return try buildToolResult(allocator, id, msg, true);
    };
    // Las tools devuelven {"error":...} para los rechazos esperados.
    const failed = std.mem.startsWith(u8, response, "{\"error\"");
    failed_out.* = failed;
    return try buildToolResult(allocator, id, response, failed);
}

/// Copia los argumentos permitidos de `a` a un objeto JSON para la tool del agente.
fn forwardArgs(allocator: std.mem.Allocator, a: std.json.ObjectMap, comptime keys: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginObject();
    inline for (keys) |key| {
        if (a.get(key)) |v| {
            try js.objectField(key);
            try js.write(v);
        }
    }
    try js.endObject();
    return allocator.dupe(u8, out.written());
}

/// git por la puerta de la terminal del motor (da_shell_run): misma lista de
/// programas, denylist, sandbox de cwd y aprobación humana que shell_run.
fn runGovernedGit(allocator: std.mem.Allocator, id: i64, handle: *anyopaque, root: []const u8, sub_args: []const []const u8) ![]u8 {
    var cmd: std.Io.Writer.Allocating = .init(allocator);
    defer cmd.deinit();
    var js: std.json.Stringify = .{ .writer = &cmd.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("exe");
    try js.write("git");
    try js.objectField("args");
    try js.beginArray();
    for (GIT_SAFE_PREFIX) |arg| try js.write(arg);
    for (sub_args) |arg| try js.write(arg);
    try js.endArray();
    try js.objectField("cwd");
    try js.write(root);
    // QA-B 2b: el sandbox del comando es la carpeta del proyecto (parityRoot).
    try js.objectField("root");
    try js.write("project");
    try js.objectField("timeout_ms");
    try js.write(GIT_TIMEOUT_MS);
    try js.endObject();
    const cmd_z = try allocator.dupeZ(u8, cmd.written());
    defer allocator.free(cmd_z);
    var out: [*:0]u8 = undefined;
    if (core.c_api.da_shell_run(handle, cmd_z, &out) != 0) return try lastErrorToolResult(allocator, id);
    defer core.c_api.da_string_free(out);
    const body = std.mem.span(out);
    const blocked = std.mem.indexOf(u8, body, "\"blocked\":true") != null;
    return try buildToolResult(allocator, id, body, blocked);
}

fn handleParityTool(allocator: std.mem.Allocator, id: i64, name: []const u8, a: std.json.ObjectMap, handle: *anyopaque) !?[]u8 {
    if (!isParityTool(name)) return null;

    if (std.mem.eql(u8, name, "spaces_list")) {
        const project = stringOf(a.get("project_id")) orelse "default";
        const project_z = try allocator.dupeZ(u8, project);
        defer allocator.free(project_z);
        var out: [*:0]u8 = undefined;
        if (core.c_api.da_spaces_list_json(handle, project_z.ptr, &out) != 0) return try lastErrorToolResult(allocator, id);
        defer core.c_api.da_string_free(out);
        return try buildToolResult(allocator, id, std.mem.span(out), false);
    }
    if (std.mem.eql(u8, name, "plan_approve")) {
        // Lo mismo que el botón «Aprobar» de la cabina (core.order.dispatch).
        // Una orden de origen MCP sigue pidiendo tarjeta en la cabina para
        // cada comando (executor.Origin.mcp).
        const oid = intOf(a.get("order_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_id");
        if (core.c_api.da_order_dispatch_async(handle, orderIdToHandle(oid)) != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"approved\":true,\"dispatching\":true}", false);
    }
    if (std.mem.eql(u8, name, "plan_replan")) {
        const oid = intOf(a.get("order_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_id");
        const changes = stringOf(a.get("changes")) orelse return try buildErrorResp(allocator, id, -32602, "missing changes");
        const changes_z = try allocator.dupeZ(u8, changes);
        defer allocator.free(changes_z);
        if (core.c_api.da_order_replan_async(handle, orderIdToHandle(oid), changes_z.ptr) != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, "{\"planning\":true}", false);
    }
    if (std.mem.eql(u8, name, "session_archive")) {
        const oid = intOf(a.get("order_id")) orelse return try buildErrorResp(allocator, id, -32602, "missing order_id");
        const archived = boolOf(a.get("archived")) orelse true;
        if (core.c_api.da_session_archive(handle, orderIdToHandle(oid), @intFromBool(archived)) != 0) return try lastErrorToolResult(allocator, id);
        return try buildToolResult(allocator, id, if (archived) "{\"archived\":true}" else "{\"archived\":false}", false);
    }

    var reason: []const u8 = "";
    const root = (try parityRoot(allocator, handle, a, &reason)) orelse return try buildToolResult(allocator, id, reason, true);
    defer allocator.free(root);

    if (std.mem.eql(u8, name, "fs_list")) {
        const args = try forwardArgs(allocator, a, &.{ "path", "recursive" });
        defer allocator.free(args);
        return try runConfinedTool(allocator, id, root, core.governed_tool_executor.LIST_DIR_TOOL_NAME, args);
    }
    if (std.mem.eql(u8, name, "fs_read")) {
        const args = try forwardArgs(allocator, a, &.{ "path", "offset", "limit" });
        defer allocator.free(args);
        return try runConfinedTool(allocator, id, root, core.governed_tool_executor.READ_FILE_TOOL_NAME, args);
    }
    if (std.mem.eql(u8, name, "fs_search")) {
        const args = try forwardArgs(allocator, a, &.{ "pattern", "path", "ignore_case", "max_results" });
        defer allocator.free(args);
        return try runConfinedTool(allocator, id, root, core.governed_tool_executor.GREP_FILES_TOOL_NAME, args);
    }
    if (std.mem.eql(u8, name, "fs_write")) {
        const args = try forwardArgs(allocator, a, &.{ "path", "content" });
        defer allocator.free(args);
        var failed = true;
        const result = try runConfinedToolStatus(allocator, id, root, core.governed_tool_executor.WRITE_FILE_TOOL_NAME, args, &failed);
        if (failed) return result;
        // T12 M5: queda anotado que este cliente escribió el archivo; la
        // tarjeta de un comando que pida después lo avisa.
        const written = stringOf(a.get("path")) orelse "";
        const written_z = try allocator.dupeZ(u8, written);
        defer allocator.free(written_z);
        const root_z = try allocator.dupeZ(u8, root);
        defer allocator.free(root_z);
        if (core.c_api.da_mcp_file_written_v2(handle, root_z.ptr, written_z.ptr) != 0) {
            allocator.free(result);
            var err_text: [*:0]u8 = undefined;
            _ = core.c_api.da_last_error(&err_text);
            defer core.c_api.da_string_free(err_text);
            const msg = try std.json.Stringify.valueAlloc(allocator, .{ .@"error" = "write_not_recorded", .detail = std.mem.span(err_text), .message = "el archivo se escribió, pero no se pudo anotar la escritura para avisar en las tarjetas de aprobación" }, .{});
            defer allocator.free(msg);
            return try buildToolResult(allocator, id, msg, true);
        }
        return result;
    }

    // git: subcomandos fijos. No hay push, ni fetch, ni reescritura de
    // historial (sin --amend, rebase, reset ni opciones libres).
    var git_args: std.ArrayList([]const u8) = .empty;
    defer git_args.deinit(allocator);
    var count_buf: [32]u8 = undefined;
    if (std.mem.eql(u8, name, "git_status")) {
        try git_args.appendSlice(allocator, &.{ "status", "--porcelain=v1", "--branch", "--untracked-files=normal" });
    } else if (std.mem.eql(u8, name, "git_diff")) {
        try git_args.appendSlice(allocator, &.{ "diff", "--no-ext-diff", "--no-textconv", "--no-color" });
        if (boolOf(a.get("staged")) orelse false) try git_args.append(allocator, "--cached");
        if (stringOf(a.get("path"))) |path| try git_args.appendSlice(allocator, &.{ "--", path });
    } else if (std.mem.eql(u8, name, "git_log")) {
        const max = intOf(a.get("max_count")) orelse 20;
        const max_arg = try std.fmt.bufPrint(&count_buf, "--max-count={d}", .{max});
        try git_args.appendSlice(allocator, &.{ "log", "--no-ext-diff", "--no-textconv", "--no-color", "--oneline", "--decorate=no", max_arg });
    } else if (std.mem.eql(u8, name, "git_add")) {
        const paths = a.get("paths") orelse return try buildErrorResp(allocator, id, -32602, "missing paths");
        if (paths.array.items.len == 0) return try buildErrorResp(allocator, id, -32602, "paths vacio");
        try git_args.appendSlice(allocator, &.{ "add", "--" });
        for (paths.array.items) |p| try git_args.append(allocator, p.string);
    } else if (std.mem.eql(u8, name, "git_commit")) {
        const message = stringOf(a.get("message")) orelse return try buildErrorResp(allocator, id, -32602, "missing message");
        if (std.mem.trim(u8, message, " \t\r\n").len == 0) return try buildErrorResp(allocator, id, -32602, "message vacio");
        try git_args.appendSlice(allocator, &.{ "commit", "--no-verify", "-m", message });
    }
    return try runGovernedGit(allocator, id, handle, root, git_args.items);
}

// ---------------------------------------------------------------------------
// Tests deterministas (core :memory:)
// ---------------------------------------------------------------------------

test "mcp server initialize returns protocol version" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();

    const resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05"}}
    , &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "2024-11-05") != null);
    // T7: sin versión pedida (cliente que no cumple) se ofrece la más reciente.
    const latest = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":2,"method":"initialize","params":{}}
    , &ctx)).?;
    defer allocator.free(latest);
    try std.testing.expect(std.mem.indexOf(u8, latest, LATEST_PROTOCOL_VERSION) != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "devagents-mcp") != null);
}

test "mcp server initialize echoes request id" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();

    const resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":3546,"method":"initialize","params":{}}
    , &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "\"id\":3546") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "\"id\":1") == null);
}

test "SEC2 MCP token cannot approve or grant scope to a pending shell command" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    const auth_request = try std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = 1,
        .method = "tools/call",
        .params = .{ .name = "authenticate", .arguments = .{ .token = ctx.expected_token.? } },
    }, .{});
    defer allocator.free(auth_request);
    const auth = (try processRequest(allocator, auth_request, &ctx)).?;
    defer allocator.free(auth);
    try std.testing.expect(ctx.authed);
    const detached = (try processRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"run_detached\",\"arguments\":{\"exe\":\"python\",\"args\":[\"script.py\"]}}}", &ctx)).?;
    defer allocator.free(detached);
    try std.testing.expect(std.mem.indexOf(u8, detached, "PermissionRequired") != null);
    const shell = (try processRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"shell_run\",\"arguments\":{\"exe\":\"touch\",\"args\":[\"SEC2-never-created\"]}}}", &ctx)).?;
    defer allocator.free(shell);
    try std.testing.expect(std.mem.indexOf(u8, shell, "PermissionRequired") != null);
    const list = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"approvals_list\"}}";
    const before = (try processRequest(allocator, list, &ctx)).?;
    defer allocator.free(before);
    try std.testing.expect(std.mem.indexOf(u8, before, "shell_run") != null);
    for ([_][]const u8{ "approvals_resolve", "approvals_resolve_scoped" }) |name| {
        const request = try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .id = 4,
            .method = "tools/call",
            .params = .{ .name = name, .arguments = .{ .approval_id = 1, .approved = true, .scope = 2 } },
        }, .{});
        defer allocator.free(request);
        const result = (try processRequest(allocator, request, &ctx)).?;
        defer allocator.free(result);
        try std.testing.expect(std.mem.indexOf(u8, result, "UI humana") != null);
        try std.testing.expect(std.mem.indexOf(u8, result, "\"isError\":true") != null);
    }
    const after = (try processRequest(allocator, list, &ctx)).?;
    defer allocator.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "mcp server notifications/initialized returns null" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();

    const resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":2,"method":"notifications/initialized","params":{}}
    , &ctx);
    try std.testing.expect(resp == null);
}

test "mcp server tools/list returns all tools" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();

    const resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/list","params":{}}
    , &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, resp.?, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("result").?.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 121), tools.len);
    var names = std.StringHashMap(void).init(allocator);
    defer names.deinit();
    for (tools) |tool| {
        const name = tool.object.get("name").?.string;
        const entry = try names.getOrPut(name);
        try std.testing.expect(!entry.found_existing);
    }
    for ([_][]const u8{ "paid_budget_get", "order_preflight", "issues_list", "issue_read", "issue_prompt", "issue_comment", "order_from_issue", "webhooks_list", "webhook_add", "webhook_delete", "webhook_test", "remote_start", "remote_stop", "remote_status", "agents_external_refresh", "external_paths_get", "external_model_options_set" }) |name| {
        try std.testing.expect(names.contains(name));
    }
    try std.testing.expectEqual(tools.len, capability_tools.len);
    var capability_names = std.StringHashMap(void).init(allocator);
    defer capability_names.deinit();
    for (capability_tools) |name| {
        try std.testing.expect(names.contains(name));
        const entry = try capability_names.getOrPut(name);
        try std.testing.expect(!entry.found_existing);
    }
    // Debe contener al menos health, catalog_info, da_submit_order, shell_run
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "health") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "catalog_info") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "da_submit_order") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "da_submit_order_async") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "plan_poll") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "shell_run") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "confirm_plan") != null);
}

test "mcp server submit order + status roundtrip" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();
    ctx.authed = true; // MCP-AUTH: da_submit_order es privilegiada

    // Submit
    const r1 = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"da_submit_order","arguments":{"order_text":"haz una calculadora","project_id":"test"}}}
    , &ctx);
    try std.testing.expect(r1 != null);
    defer if (r1) |r| allocator.free(r);
    if (std.mem.indexOf(u8, r1.?, "order_id") == null) {
        std.debug.print("DEBUG submit response: {s}\n", .{r1.?});
    }
    try std.testing.expect(std.mem.indexOf(u8, r1.?, "order_id") != null);

    // Extraer order_id del texto del resultado (dentro del JSON de respuesta MCP).
    const oid_marker = "order_id";
    const oid_pos = std.mem.indexOf(u8, r1.?, oid_marker) orelse return error.MissingOrderId;
    var num_start = oid_pos + oid_marker.len;
    while (num_start < r1.?.len and !std.ascii.isDigit(r1.?[num_start])) num_start += 1;
    var num_end = num_start;
    while (num_end < r1.?.len and std.ascii.isDigit(r1.?[num_end])) num_end += 1;
    const oid_str = r1.?[num_start..num_end];
    const oid = try std.fmt.parseInt(i64, oid_str, 10);
    try std.testing.expect(oid > 0);

    // Status
    const req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{{"name":"order_status","arguments":{{"order_id":{d}}}}}}}
    , .{oid});
    defer allocator.free(req);
    const r2 = try processRequest(allocator, req, &ctx);
    try std.testing.expect(r2 != null);
    defer if (r2) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r2.?, "status_text") != null);
}

test "mcp server health returns JSON" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();

    const resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"health","arguments":{}}}
    , &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);
    // La respuesta MCP contiene content/text con el JSON de salud.
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "content") != null);
}

test "mcp server catalog_info returns JSON" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();

    const resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"catalog_info","arguments":{}}}
    , &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "content") != null);
}

test "mcp server shell_run blocked for .db access" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();
    ctx.authed = true; // MCP-AUTH: shell_run es privilegiada

    const resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"shell_run","arguments":{"exe":"python","args":["runtime.db"],"cwd":"."}}}
    , &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);
    // Debe indicar bloqueo o un resultado JSON honesto (incluso si no hay
    // executor allowlistado, la respuesta no debe ser un crash).
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "content") != null);
}

test "mcp server approvals list returns array" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();
    ctx.authed = true; // T12B M-1: approvals_list es privilegiada

    const resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"approvals_list","arguments":{}}}
    , &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "content") != null);
}

test "T12B M-1: approvals_list exige token y cada sesion MCP solo ve sus tarjetas" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);
    const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}\\runtime.db", .{dir}, 0);
    defer allocator.free(db_path);

    // 1. Sin token, approvals_list no llega al manejador.
    {
        var anon = try ServerCtx.init(allocator, io, ":memory:");
        defer anon.deinit();
        const denied = (try processRequest(allocator,
            \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"approvals_list","arguments":{}}}
        , &anon)).?;
        defer allocator.free(denied);
        try std.testing.expect(std.mem.indexOf(u8, denied, "autenticacion requerida") != null);
    }

    // 2. Dos sesiones MCP con el MISMO token y distinta identidad de cliente.
    var ctx_a = try ServerCtx.init(allocator, io, db_path);
    defer ctx_a.deinit();
    ctx_a.authed = true;
    if (ctx_a.expected_token) |old| allocator.free(old);
    ctx_a.expected_token = try allocator.dupe(u8, "t12b-fixture-token");
    try ctx_a.installSessionTag(ctx_a.core_handle, "client-a");
    var ctx_b = try ServerCtx.init(allocator, io, db_path);
    defer ctx_b.deinit();
    ctx_b.authed = true;
    if (ctx_b.expected_token) |old| allocator.free(old);
    ctx_b.expected_token = try allocator.dupe(u8, "t12b-fixture-token");
    try ctx_b.installSessionTag(ctx_b.core_handle, "client-b");
    try std.testing.expect(!std.mem.eql(u8, ctx_a.session_tag.?, ctx_b.session_tag.?));

    // A pide una captura: queda como tarjeta pendiente, propia de A.
    const shot = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"capture_screenshot","arguments":{}}}
    , &ctx_a)).?;
    defer allocator.free(shot);
    var shot_body = try t7ToolText(allocator, shot);
    defer shot_body.parsed.deinit();
    try std.testing.expect(!shot_body.is_error);
    try std.testing.expect(std.mem.indexOf(u8, shot_body.text, "\"status\":\"pending\"") != null);

    var own: [*:0]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_approval_pending_json(ctx_a.core_handle, &own));
    defer core.c_api.da_string_free(own);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.span(own), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    const id = parsed.value.array.items[0].object.get("id").?.integer;
    const id_text = try std.fmt.allocPrint(allocator, "\"id\":{d}", .{id});
    defer allocator.free(id_text);

    // A ve su tarjeta por la tool...
    const list_a = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"approvals_list","arguments":{}}}
    , &ctx_a)).?;
    defer allocator.free(list_a);
    var a_body = try t7ToolText(allocator, list_a);
    defer a_body.parsed.deinit();
    try std.testing.expect(!a_body.is_error);
    try std.testing.expect(std.mem.indexOf(u8, a_body.text, id_text) != null);

    // ...B no, ni por la tool ni por la C-ABI del nucleo.
    const list_b = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"approvals_list","arguments":{}}}
    , &ctx_b)).?;
    defer allocator.free(list_b);
    var b_body = try t7ToolText(allocator, list_b);
    defer b_body.parsed.deinit();
    try std.testing.expect(!b_body.is_error);
    try std.testing.expectEqualStrings("[]", b_body.text);
    var other: [*:0]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_approval_pending_json(ctx_b.core_handle, &other));
    defer core.c_api.da_string_free(other);
    try std.testing.expectEqualStrings("[]", std.mem.span(other));
}

test "T12B B-2: las tarjetas de spaces llevan el origen de la sesion y no se comparten" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);
    const db_path = try std.fmt.allocPrintSentinel(allocator, "{s}\\runtime.db", .{dir}, 0);
    defer allocator.free(db_path);

    var ctx_a = try ServerCtx.init(allocator, io, db_path);
    defer ctx_a.deinit();
    ctx_a.authed = true;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_set_mcp_session(ctx_a.core_handle, "tag-a"));
    if (ctx_a.session_tag) |old| allocator.free(old);
    ctx_a.session_tag = try allocator.dupe(u8, "tag-a");

    const id_a = try ctx_a.spacesApprovalInsert("space_1", "archivar space", "{\"ids\":[1]}");
    // El origen de la sesión queda escrito en la tabla compartida.
    const conn = try ctx_a.spacesApprovalConn();
    const q = try conn.prepare("SELECT origin FROM approvals WHERE id = ?");
    defer conn.finalize(q);
    try core.db.bindInt(q, 1, id_a);
    try std.testing.expectEqual(core.db.c.SQLITE_ROW, core.db.c.sqlite3_step(q));
    try std.testing.expectEqualStrings("tag-a", sqliteColumnText(q, 0));
    // La propia sesión la ve; otra con token distinto no, ni la reutiliza.
    const own = ctx_a.spacesApprovalFetch(allocator, id_a, "space_1");
    defer if (own.stored) |s| allocator.free(s);
    try std.testing.expectEqual(ServerCtx.SpacesApprovalState.pending, own.state);

    var ctx_b = try ServerCtx.init(allocator, io, db_path);
    defer ctx_b.deinit();
    ctx_b.authed = true;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_set_mcp_session(ctx_b.core_handle, "tag-b"));
    if (ctx_b.session_tag) |old| allocator.free(old);
    ctx_b.session_tag = try allocator.dupe(u8, "tag-b");
    const other = ctx_b.spacesApprovalFetch(allocator, id_a, "space_1");
    defer if (other.stored) |s| allocator.free(s);
    try std.testing.expectEqual(ServerCtx.SpacesApprovalState.unknown, other.state);
    const id_b = try ctx_b.spacesApprovalInsert("space_1", "archivar space", "{\"ids\":[1]}");
    try std.testing.expect(id_b != id_a);

    var restored = try ServerCtx.init(allocator, io, db_path);
    defer restored.deinit();
    restored.authed = true;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_set_mcp_session(restored.core_handle, "tag-a"));
    if (restored.session_tag) |old| allocator.free(old);
    restored.session_tag = try allocator.dupe(u8, "tag-a");
    const recovered = restored.spacesApprovalFetch(allocator, id_a, "space_1");
    defer if (recovered.stored) |s| allocator.free(s);
    try std.testing.expectEqual(ServerCtx.SpacesApprovalState.pending, recovered.state);
    try std.testing.expectEqual(id_a, try restored.spacesApprovalInsert("space_1", "archivar space", "{\"ids\":[1]}"));
    const listed = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":92,"method":"tools/call","params":{"name":"approvals_list","arguments":{}}}
    , &restored)).?;
    defer allocator.free(listed);
    var body = try t7ToolText(allocator, listed);
    defer body.parsed.deinit();
    var cards = try std.json.parseFromSlice(std.json.Value, allocator, body.text, .{});
    defer cards.deinit();
    try std.testing.expectEqual(@as(usize, 1), cards.value.array.items.len);
    try std.testing.expectEqual(id_a, cards.value.array.items[0].object.get("id").?.integer);
}

test "T12B B-2: el token no identifica al proceso; identidad estable recupera el origen" {
    const a = std.testing.allocator;
    var t = std.Io.Threaded.init(a, .{});
    defer t.deinit();
    var ctx = try ServerCtx.init(a, t.io(), ":memory:");
    defer ctx.deinit();
    if (ctx.expected_token) |old| a.free(old);
    ctx.expected_token = try a.dupe(u8, "t12b-token-sintetico");
    try ctx.installSessionTag(ctx.core_handle, "cliente-a");
    const first = try a.dupe(u8, ctx.session_tag.?);
    defer a.free(first);
    try ctx.installSessionTag(ctx.core_handle, "cliente-a");
    try std.testing.expectEqualStrings(first, ctx.session_tag.?);
    try ctx.installSessionTag(ctx.core_handle, "cliente-b");
    try std.testing.expect(!std.mem.eql(u8, first, ctx.session_tag.?));
    try ctx.installSessionTag(ctx.core_handle, null);
    const anonymous = try a.dupe(u8, ctx.session_tag.?);
    defer a.free(anonymous);
    try ctx.installSessionTag(ctx.core_handle, null);
    try std.testing.expect(!std.mem.eql(u8, anonymous, ctx.session_tag.?));
}

test "mcp server unknown tool returns error" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();

    const resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"nope","arguments":{}}}
    , &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "error") != null);
}

test "mcp server order_events returns array" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();
    ctx.authed = true; // MCP-AUTH: da_submit_order es privilegiada

    // Primero enviamos una orden para tener un order_id.
    const r1 = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"da_submit_order","arguments":{"order_text":"hola","project_id":"ev"}}}
    , &ctx);
    try std.testing.expect(r1 != null);
    defer if (r1) |r| allocator.free(r);

    const oid_marker = "order_id";
    const oid_pos = std.mem.indexOf(u8, r1.?, oid_marker) orelse return error.MissingOrderId;
    var num_start = oid_pos + oid_marker.len;
    while (num_start < r1.?.len and !std.ascii.isDigit(r1.?[num_start])) num_start += 1;
    var num_end = num_start;
    while (num_end < r1.?.len and std.ascii.isDigit(r1.?[num_end])) num_end += 1;
    const oid = try std.fmt.parseInt(i64, r1.?[num_start..num_end], 10);

    const req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{{"name":"order_events","arguments":{{"order_id":{d},"since_event_id":0}}}}}}
    , .{oid});
    defer allocator.free(req);
    const r2 = try processRequest(allocator, req, &ctx);
    try std.testing.expect(r2 != null);
    defer if (r2) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r2.?, "content") != null);
}

test "mcp server tools/list includes dispatch_async, dispatch_poll, worker_output, dispatch_cancel" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();

    const resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":20,"method":"tools/list","params":{}}
    , &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "dispatch_async") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "dispatch_poll") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "worker_output") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "dispatch_cancel") != null);
}

test "mcp server dispatch_cancel returns error when order not found" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();
    ctx.authed = true; // MCP-AUTH: dispatch_cancel es privilegiada

    const resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"dispatch_cancel","arguments":{"order_id":99999}}}
    , &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "error") != null or std.mem.indexOf(u8, resp.?, "not found") != null);
}

test "mcp server worker_output returns JSON array" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();
    ctx.authed = true; // T12B M-1: worker_output es privilegiada

    const resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"worker_output","arguments":{"since_ms":0}}}
    , &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "content") != null);
}

test "FIX-DISPATCH-P0: discover_models returns degraded info when 0 models found" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();

    // T12 A1: descubrir llama a /models de cada proveedor con sus claves:
    // sin credencial no llega al manejador.
    const denied = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"discover_models","arguments":{}}}
    , &ctx)).?;
    defer allocator.free(denied);
    try std.testing.expect(std.mem.indexOf(u8, denied, "autenticacion requerida") != null);
    ctx.authed = true;
    const resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"discover_models","arguments":{}}}
    , &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);
    // With no keys configured, should return degraded:true with a reason.
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "degraded") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "discovered_count") != null);
}

test "VG2 P08-T4: capabilities returns version, tools, and providers" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();

    const free_mode = try allocator.dupeZ(u8, "free");
    defer allocator.free(free_mode);
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_set_governance_mode(ctx.core_handle, free_mode));

    const resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{"name":"capabilities","arguments":{}}}
    , &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);
    // The JSON payload is wrapped in content[].text, so inner quotes are escaped
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "\\\"ok\\\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "version") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "protocolVersion") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "dataDir") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "providers") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "tools") != null);

    var outer = try std.json.parseFromSlice(std.json.Value, allocator, resp.?, .{});
    defer outer.deinit();
    const text = outer.value.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
    var inner = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer inner.deinit();
    const obj = inner.value.object;
    try std.testing.expectEqualStrings("free_tier_first", obj.get("governance_mode").?.string);
    const engine = obj.get("engine").?.object;
    try std.testing.expectEqualStrings("DevAgents Angel", engine.get("name").?.string);
    const identity = std.mem.span(core.c_api.da_build_identity_v1());
    const expected_hash = if (std.mem.indexOfScalar(u8, identity, '+')) |start|
        identity[start + 1 .. std.mem.indexOfScalar(u8, identity, '/').?]
    else
        "unknown";
    try std.testing.expectEqualStrings(expected_hash, engine.get("build_hash").?.string);
    // Must NOT contain any key values
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "api_key") == null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "secret") == null);
}

test "MCP health_probe_all rejects negative and c_int overflow before dispatch" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();
    ctx.authed = true; // MCP-AUTH: health_probe_all es privilegiada

    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":41,\"method\":\"tools/call\",\"params\":{\"name\":\"health_probe_all\",\"arguments\":{\"max_models\":-1}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":42,\"method\":\"tools/call\",\"params\":{\"name\":\"health_probe_all\",\"arguments\":{\"max_models\":2147483648}}}",
    }) |request| {
        const resp = try processRequest(allocator, request, &ctx);
        try std.testing.expect(resp != null);
        defer if (resp) |r| allocator.free(r);
        try std.testing.expect(std.mem.indexOf(u8, resp.?, "-32602") != null);
    }

    var out: [*:0]u8 = undefined;
    const rc = core.c_api.da_health_probe_all_json(ctx.core_handle, -1, &out);
    try std.testing.expect(rc != 0);
}

test "P08-T4: capabilities payload is parseable and sanitizes Windows paths/providers" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();
    ctx.data_dir = "C:\\tmp\\codex-p08-data";

    const resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":35,"method":"tools/call","params":{"name":"capabilities","arguments":{}}}
    , &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);

    var outer = try std.json.parseFromSlice(std.json.Value, allocator, resp.?, .{});
    defer outer.deinit();
    const text = outer.value.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;

    var inner = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer inner.deinit();
    const obj = inner.value.object;
    try std.testing.expectEqualStrings("C:\\tmp\\codex-p08-data", obj.get("dataDir").?.string);

    const providers = obj.get("providers").?.array.items;
    if (providers.len > 0) {
        const provider = providers[0].object;
        try std.testing.expect(provider.get("provider") != null);
        try std.testing.expect(provider.get("has_key") != null);
        try std.testing.expect(provider.get("keys") == null);
        try std.testing.expect(provider.get("models") == null);
        try std.testing.expect(provider.get("base_url") == null);
        try std.testing.expect(provider.get("api_style") == null);
    }
}

test "P08-T1: tools/list includes capabilities, session_rename, health_summary" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();

    const resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":31,"method":"tools/list","params":{}}
    , &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "capabilities") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "session_rename") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "health_summary") != null);
}

test "P08-T1: health_summary returns JSON content" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();

    const resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":32,"method":"tools/call","params":{"name":"health_summary","arguments":{}}}
    , &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "content") != null);
}

fn t7ToolText(allocator: std.mem.Allocator, response: []const u8) !struct { parsed: std.json.Parsed(std.json.Value), text: []const u8, is_error: bool } {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    const result = parsed.value.object.get("result") orelse return .{ .parsed = parsed, .text = "", .is_error = true };
    return .{
        .parsed = parsed,
        .text = result.object.get("content").?.array.items[0].object.get("text").?.string,
        .is_error = result.object.get("isError").?.bool,
    };
}

test "T7: ninguna herramienta de gobierno se expone por MCP y la cabina sigue pudiendo" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true; // ni siquiera con el token

    const listing = (try processRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}", &ctx)).?;
    defer allocator.free(listing);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, listing, .{});
    defer parsed.deinit();
    for (parsed.value.object.get("result").?.object.get("tools").?.array.items) |tool| {
        const name = tool.object.get("name").?.string;
        try std.testing.expect(!isCabinOnlyTool(name));
        // Ninguna tool que por su nombre cambie permisos, hooks, plugins,
        // reglas de gobierno, límites o cupo.
        for ([_][]const u8{ "permission", "hooks_set", "hook_set", "plugin", "governance", "budget_set", "limits_set", "paths_set", "iterations", "approvals_resolve", "mcp_connect" }) |forbidden| {
            if (std.mem.indexOf(u8, name, forbidden) != null) {
                std.debug.print("T7 gobierno expuesto por MCP: {s}\n", .{name});
                return error.TestUnexpectedResult;
            }
        }
    }

    var before: [*:0]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_get_permission_config(ctx.core_handle, &before));
    defer core.c_api.da_string_free(before);
    for (CABIN_ONLY_TOOLS) |name| {
        const request = try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .id = 2,
            .method = "tools/call",
            .params = .{ .name = name, .arguments = .{ .mode = "bypass", .allow = [_][]const u8{"python"}, .json = "{}", .authorized = 0, .explicit = true, .max_iterations = 12 } },
        }, .{});
        defer allocator.free(request);
        const response = (try processRequest(allocator, request, &ctx)).?;
        defer allocator.free(response);
        var tool = try t7ToolText(allocator, response);
        defer tool.parsed.deinit();
        try std.testing.expect(tool.is_error);
        try std.testing.expect(std.mem.indexOf(u8, tool.text, "UI humana") != null);
    }
    var after: [*:0]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_get_permission_config(ctx.core_handle, &after));
    defer core.c_api.da_string_free(after);
    try std.testing.expectEqualStrings(std.mem.span(before), std.mem.span(after));

    // La cabina (un núcleo sin superficie MCP, como el que abre el host) sigue
    // cambiando permisos y límites con el mismo C-ABI.
    var cabin: ?*anyopaque = null;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_core_init(&cabin, ":memory:"));
    defer _ = core.c_api.da_core_shutdown(cabin);
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_set_permission_config(cabin, "{\"mode\":\"accept_edits\",\"allow\":[],\"deny\":[\"rm\"]}"));
    var cabin_cfg: [*:0]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_get_permission_config(cabin, &cabin_cfg));
    defer core.c_api.da_string_free(cabin_cfg);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(cabin_cfg), "accept_edits") != null);
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_external_limits_set(cabin, "{\"order_timeout_ms\":0}"));
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_set_agentic_max_iterations(cabin, 3));
}

test "T7: negociacion de version, ping, resources/prompts, notificaciones e ids" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();

    const Case = struct { requested: []const u8, expected: []const u8, title: bool, description: bool };
    for ([_]Case{
        .{ .requested = "2024-11-05", .expected = "2024-11-05", .title = false, .description = false },
        .{ .requested = "2025-03-26", .expected = "2025-03-26", .title = false, .description = false },
        .{ .requested = "2025-06-18", .expected = "2025-06-18", .title = true, .description = false },
        .{ .requested = "2025-11-25", .expected = "2025-11-25", .title = true, .description = true },
        .{ .requested = "1999-01-01", .expected = "2025-11-25", .title = true, .description = true },
        .{ .requested = "2099-12-31", .expected = "2025-11-25", .title = true, .description = true },
    }) |case| {
        const request = try std.json.Stringify.valueAlloc(allocator, .{
            .jsonrpc = "2.0",
            .id = 1,
            .method = "initialize",
            .params = .{ .protocolVersion = case.requested, .capabilities = .{}, .clientInfo = .{ .name = "t7", .version = "1" } },
        }, .{});
        defer allocator.free(request);
        const response = (try processRequest(allocator, request, &ctx)).?;
        defer allocator.free(response);
        const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer parsed.deinit();
        const result = parsed.value.object.get("result").?.object;
        try std.testing.expectEqualStrings(case.expected, result.get("protocolVersion").?.string);
        try std.testing.expectEqualStrings(case.expected, ctx.protocol_version);
        const caps = result.get("capabilities").?.object;
        try std.testing.expect(caps.get("tools") != null);
        try std.testing.expect(caps.get("resources") != null);
        try std.testing.expect(caps.get("prompts") != null);
        const info = result.get("serverInfo").?.object;
        try std.testing.expectEqualStrings("devagents-mcp", info.get("name").?.string);
        try std.testing.expect(info.get("version") != null);
        try std.testing.expectEqual(case.title, info.get("title") != null);
        try std.testing.expectEqual(case.description, info.get("description") != null);
    }

    // ping, listas vacías bien formadas y lecturas de algo que no existe.
    const MethodCase = struct { method: []const u8, expected: []const u8 };
    for ([_]MethodCase{
        .{ .method = "ping", .expected = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{}}" },
        .{ .method = "resources/list", .expected = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"resources\":[]}}" },
        .{ .method = "resources/templates/list", .expected = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"resourceTemplates\":[]}}" },
        .{ .method = "prompts/list", .expected = "{\"jsonrpc\":\"2.0\",\"id\":7,\"result\":{\"prompts\":[]}}" },
        .{ .method = "resources/read", .expected = "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32002,\"message\":\"Resource not found\"}}" },
        .{ .method = "prompts/get", .expected = "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32602,\"message\":\"Invalid prompt name\"}}" },
        .{ .method = "logging/setLevel", .expected = "{\"jsonrpc\":\"2.0\",\"id\":7,\"error\":{\"code\":-32601,\"message\":\"method not found\"}}" },
    }) |case| {
        const request = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"{s}\",\"params\":{{}}}}", .{case.method});
        defer allocator.free(request);
        const response = (try processRequest(allocator, request, &ctx)).?;
        defer allocator.free(response);
        try std.testing.expectEqualStrings(case.expected, response);
    }

    // A una notificación (sin id) no se le responde, sea cual sea el método.
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/cancelled\",\"params\":{\"requestId\":3}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"ping\"}",
    }) |request| {
        try std.testing.expect((try processRequest(allocator, request, &ctx)) == null);
    }

    // Ids de cadena se devuelven tal cual; null no es un id válido.
    const string_id = (try processRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"abc-7\",\"method\":\"ping\"}", &ctx)).?;
    defer allocator.free(string_id);
    try std.testing.expectEqualStrings("{\"jsonrpc\":\"2.0\",\"id\":\"abc-7\",\"result\":{}}", string_id);
    const tool_string_id = (try processRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":\"t-1\",\"method\":\"tools/call\",\"params\":{\"name\":\"catalog_info\",\"arguments\":{}}}", &ctx)).?;
    defer allocator.free(tool_string_id);
    try std.testing.expect(std.mem.startsWith(u8, tool_string_id, "{\"jsonrpc\":\"2.0\",\"id\":\"t-1\""));
    const null_id = (try processRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":null,\"method\":\"ping\"}", &ctx)).?;
    defer allocator.free(null_id);
    try std.testing.expect(std.mem.indexOf(u8, null_id, "\"id\":null") != null);
    try std.testing.expect(std.mem.indexOf(u8, null_id, "-32600") != null);
}

test "T7: lotes solo en 2025-03-26 y errores de validacion como isError en 2025-11-25" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    const batch = "[{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"ping\"},{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\"},{\"jsonrpc\":\"2.0\",\"id\":\"b\",\"method\":\"prompts/list\"}]";
    const invalid_args = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"health\",\"arguments\":{\"provider_hint\":false}}}";

    const Case = struct { version: []const u8, batch_ok: bool, validation_as_tool_error: bool };
    for ([_]Case{
        .{ .version = "2024-11-05", .batch_ok = false, .validation_as_tool_error = false },
        .{ .version = "2025-03-26", .batch_ok = true, .validation_as_tool_error = false },
        .{ .version = "2025-06-18", .batch_ok = false, .validation_as_tool_error = false },
        .{ .version = "2025-11-25", .batch_ok = false, .validation_as_tool_error = true },
    }) |case| {
        const init_request = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":0,\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"{s}\"}}}}", .{case.version});
        defer allocator.free(init_request);
        allocator.free((try processRequest(allocator, init_request, &ctx)).?);

        const batch_response = (try processRequest(allocator, batch, &ctx)).?;
        defer allocator.free(batch_response);
        if (case.batch_ok) {
            try std.testing.expectEqualStrings("[{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{}},{\"jsonrpc\":\"2.0\",\"id\":\"b\",\"result\":{\"prompts\":[]}}]", batch_response);
        } else {
            try std.testing.expect(std.mem.startsWith(u8, batch_response, "{"));
            try std.testing.expect(std.mem.indexOf(u8, batch_response, "-32600") != null);
        }

        const validation = (try processRequest(allocator, invalid_args, &ctx)).?;
        defer allocator.free(validation);
        if (case.validation_as_tool_error) {
            var tool = try t7ToolText(allocator, validation);
            defer tool.parsed.deinit();
            try std.testing.expect(tool.is_error);
            try std.testing.expect(std.mem.indexOf(u8, tool.text, "provider_hint") != null);
        } else {
            try std.testing.expect(std.mem.indexOf(u8, validation, "-32602") != null);
        }
    }
}

test "T7: archivos, spaces, git y plan por MCP pasan por el gobierno del motor" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);
    const dir_z = try allocator.dupeZ(u8, dir);
    defer allocator.free(dir_z);
    var previous: [4096]u8 = undefined;
    const previous_len = GetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", &previous, previous.len);
    defer {
        if (previous_len > 0 and previous_len < previous.len) {
            previous[previous_len] = 0;
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", @ptrCast(&previous[0]));
        } else {
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", null);
        }
    }
    try std.testing.expect(SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", dir_z.ptr) != 0);
    const base = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{dir});
    defer allocator.free(base);
    try std.Io.Dir.cwd().createDirPath(io, base);
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();

    // Sin token, escribir, leer archivos (T12 M4) y git se rechazan;
    // listar spaces no.
    const unauth = (try processRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"fs_write\",\"arguments\":{\"path\":\"x.txt\",\"content\":\"x\"}}}", &ctx)).?;
    defer allocator.free(unauth);
    try std.testing.expect(std.mem.indexOf(u8, unauth, "autenticacion requerida") != null);
    for ([_][]const u8{ "fs_read", "fs_list", "fs_search" }) |reader| {
        const request = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{{\"path\":\".env\",\"pattern\":\"x\"}}}}}}", .{reader});
        defer allocator.free(request);
        const denied = (try processRequest(allocator, request, &ctx)).?;
        defer allocator.free(denied);
        try std.testing.expect(std.mem.indexOf(u8, denied, "autenticacion requerida") != null);
    }
    const spaces_resp = (try processRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"spaces_list\",\"arguments\":{\"project_id\":\"t7\"}}}", &ctx)).?;
    defer allocator.free(spaces_resp);
    var spaces_tool = try t7ToolText(allocator, spaces_resp);
    defer spaces_tool.parsed.deinit();
    try std.testing.expect(!spaces_tool.is_error);
    try std.testing.expect(std.mem.startsWith(u8, spaces_tool.text, "["));

    ctx.authed = true;
    const Step = struct { request: []const u8, is_error: bool, contains: []const u8 };
    const steps = [_]Step{
        .{ .request = "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"fs_write\",\"arguments\":{\"path\":\"t7/hola.txt\",\"content\":\"hola desde T7\"}}}", .is_error = false, .contains = "" },
        .{ .request = "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"fs_read\",\"arguments\":{\"path\":\"t7/hola.txt\"}}}", .is_error = false, .contains = "hola desde T7" },
        .{ .request = "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"fs_list\",\"arguments\":{\"path\":\"t7\"}}}", .is_error = false, .contains = "hola.txt" },
        .{ .request = "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"fs_search\",\"arguments\":{\"pattern\":\"desde T7\"}}}", .is_error = false, .contains = "hola.txt" },
        // Mismo confinamiento que el agente: nada fuera de la raíz.
        .{ .request = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"fs_read\",\"arguments\":{\"path\":\"..\\\\..\\\\fuera.txt\"}}}", .is_error = true, .contains = "outside_sandbox" },
        .{ .request = "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"fs_write\",\"arguments\":{\"path\":\"..\\\\fuera.txt\",\"content\":\"x\"}}}", .is_error = true, .contains = "outside_sandbox" },
        .{ .request = "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"fs_list\",\"arguments\":{\"space_id\":424242,\"project_id\":\"t7\"}}}", .is_error = true, .contains = "space no encontrado" },
        // QA-B 2a: git_status es la consulta domesticada de solo lectura:
        // corre sin tarjeta y devuelve su salida (aquí no hay repo: exit 128).
        .{ .request = "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"git_status\",\"arguments\":{}}}", .is_error = false, .contains = "\"blocked\":false" },
        // QA-B 2a: .git no se escribe con archivos (sus filtros los correría git status).
        .{ .request = "{\"jsonrpc\":\"2.0\",\"id\":20,\"method\":\"tools/call\",\"params\":{\"name\":\"fs_write\",\"arguments\":{\"path\":\".git/config\",\"content\":\"x\"}}}", .is_error = true, .contains = "git_metadata_denied" },
        .{ .request = "{\"jsonrpc\":\"2.0\",\"id\":11,\"method\":\"tools/call\",\"params\":{\"name\":\"git_commit\",\"arguments\":{\"message\":\"t7\"}}}", .is_error = true, .contains = "PermissionRequired" },
        .{ .request = "{\"jsonrpc\":\"2.0\",\"id\":12,\"method\":\"tools/call\",\"params\":{\"name\":\"plan_approve\",\"arguments\":{\"order_id\":987654}}}", .is_error = true, .contains = "" },
        .{ .request = "{\"jsonrpc\":\"2.0\",\"id\":13,\"method\":\"tools/call\",\"params\":{\"name\":\"plan_replan\",\"arguments\":{\"order_id\":987654,\"changes\":\"mas corto\"}}}", .is_error = true, .contains = "" },
    };
    for (steps) |step| {
        const response = (try processRequest(allocator, step.request, &ctx)).?;
        defer allocator.free(response);
        var tool = try t7ToolText(allocator, response);
        defer tool.parsed.deinit();
        if (tool.is_error != step.is_error or std.mem.indexOf(u8, tool.text, step.contains) == null) {
            std.debug.print("T7 paridad inesperada: {s}\n -> {s}\n", .{ step.request, response });
            return error.TestUnexpectedResult;
        }
    }
    // QA-B 2b: la raíz por defecto es la carpeta del proyecto elegida.
    const written = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "t7" ++ std.fs.path.sep_str ++ "hola.txt", .{dir});
    defer allocator.free(written);
    const on_disk = try std.Io.Dir.cwd().readFileAlloc(io, written, allocator, .limited(1024));
    defer allocator.free(on_disk);
    try std.testing.expectEqualStrings("hola desde T7", on_disk);
    // T12 M5: la escritura quedó anotada y la tarjeta de git_commit (pedida
    // después) avisa de que este cliente escribió t7/hola.txt.
    const cards = (try processRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":22,\"method\":\"tools/call\",\"params\":{\"name\":\"approvals_list\"}}", &ctx)).?;
    defer allocator.free(cards);
    try std.testing.expect(std.mem.indexOf(u8, cards, "un cliente MCP escribi") != null);
    try std.testing.expect(std.mem.indexOf(u8, cards, "hola.txt") != null);

    // Las tarjetas de git que escriben llegan a la bandeja de la cabina con el
    // git domesticado; la consulta de solo lectura no deja tarjeta.
    const pending = (try processRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":14,\"method\":\"tools/call\",\"params\":{\"name\":\"approvals_list\"}}", &ctx)).?;
    defer allocator.free(pending);
    try std.testing.expect(std.mem.indexOf(u8, pending, "core.hooksPath=NUL") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "--no-verify") != null);
    try std.testing.expect(std.mem.indexOf(u8, pending, "--porcelain=v1") == null);
    // QA-B 2a: el estado de la tarjeta se consulta sin poder resolverla.
    const result = (try processRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":21,\"method\":\"tools/call\",\"params\":{\"name\":\"approval_result\",\"arguments\":{\"approval_id\":1}}}", &ctx)).?;
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOf(u8, result, "pending") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"isError\":false") != null);

    // Contratos: sin push ni opciones libres; rutas y mensajes vacíos fuera.
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":15,\"method\":\"tools/call\",\"params\":{\"name\":\"git_add\",\"arguments\":{\"paths\":[]}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":16,\"method\":\"tools/call\",\"params\":{\"name\":\"git_commit\",\"arguments\":{\"message\":\"   \"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":17,\"method\":\"tools/call\",\"params\":{\"name\":\"git_log\",\"arguments\":{\"max_count\":201}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":18,\"method\":\"tools/call\",\"params\":{\"name\":\"plan_replan\",\"arguments\":{\"order_id\":1,\"changes\":\"\"}}}",
    }) |request| {
        const response = (try processRequest(allocator, request, &ctx)).?;
        defer allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "-32602") != null);
    }
    const listing = (try processRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":19,\"method\":\"tools/list\"}", &ctx)).?;
    defer allocator.free(listing);
    for ([_][]const u8{ "git_push", "git_reset", "git_rebase", "git_amend", "git_fetch" }) |absent| {
        try std.testing.expect(std.mem.indexOf(u8, listing, absent) == null);
    }
    for ([_][]const u8{ "spaces_list", "plan_approve", "plan_replan", "session_archive", "fs_list", "fs_read", "fs_search", "fs_write", "git_status", "git_diff", "git_log", "git_add", "git_commit", "shell_run" }) |present| {
        const quoted = try std.fmt.allocPrint(allocator, "\"{s}\"", .{present});
        defer allocator.free(quoted);
        try std.testing.expect(std.mem.indexOf(u8, listing, quoted) != null);
    }
}

test "SEC2 MCP client cannot launch an arbitrary process through mcp_connect" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(threaded.io(), ".", allocator);
    defer allocator.free(dir);
    const marker = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "sec2-mcp-marker", .{dir});
    defer allocator.free(marker);
    const script = try std.fmt.allocPrint(allocator, "Set-Content -LiteralPath '{s}' -Value pwned", .{marker});
    defer allocator.free(script);
    const argv_json = try std.json.Stringify.valueAlloc(allocator, [_][]const u8{ "powershell.exe", "-NoProfile", "-Command", script }, .{});
    defer allocator.free(argv_json);
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true; // incluso autenticado: el token no es autoridad humana
    const listing = (try processRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}", &ctx)).?;
    defer allocator.free(listing);
    try std.testing.expect(std.mem.indexOf(u8, listing, "\"mcp_connect\"") == null);
    const request = try std.json.Stringify.valueAlloc(allocator, .{
        .jsonrpc = "2.0",
        .id = 2,
        .method = "tools/call",
        .params = .{ .name = "mcp_connect", .arguments = .{ .argv_json = argv_json, .timeout_ms = 2000 } },
    }, .{});
    defer allocator.free(request);
    const resp = (try processRequest(allocator, request, &ctx)).?;
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"isError\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "UI humana") != null);
    const connected = (try processRequest(allocator, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"mcp_is_connected\",\"arguments\":{}}}", &ctx)).?;
    defer allocator.free(connected);
    try std.testing.expect(std.mem.indexOf(u8, connected, "connected\\\":0") != null);
    tmp.dir.access(threaded.io(), "sec2-mcp-marker", .{}) catch |e| {
        try std.testing.expect(e == error.FileNotFound);
        return;
    };
    return error.TestUnexpectedResult;
}

test "SEC2 MCP set_workspace_root and repo_clone cannot redirect or run options" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true;
    for ([_][]const u8{
        \\{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"set_workspace_root","arguments":{"path":"C:\\Windows\\Temp"}}}
        ,
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"repo_clone","arguments":{"url":"--upload-pack=calc","target_dir":"x"}}}
        ,
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"repo_clone","arguments":{"url":"https://github.com/o/r.git","target_dir":"C:\\Windows\\Temp\\sec2"}}}
    }) |request| {
        const resp = (try processRequest(allocator, request, &ctx)).?;
        defer allocator.free(resp);
        try std.testing.expect(std.mem.indexOf(u8, resp, "\"isError\":true") != null);
    }
}

test "MCP-AUTH: tools privilegiadas rechazan sin sesion autenticada" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();
    try std.testing.expect(!ctx.authed); // nace sin autenticar (sin env)

    // Cada tool privilegiada debe responder is_error de autenticación.
    const privileged_names = [_][]const u8{
        "plan_approve",    "shell_run",          "plan_replan",
        "add_key",         "dispatch_async",     "run_detached",
        "mcp_call_tool",   "set_workspace_root", "confirm_plan",
        "da_submit_order", "fs_write",           "external_model_options_set",
        "space_create",    "space_archive",      "spaces_prune",
        "git_status",      "git_commit",         "session_archive",
    };
    var req_id: i64 = 40;
    for (privileged_names) |tool_name| {
        const req = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":{d},"method":"tools/call","params":{{"name":"{s}","arguments":{{}}}}}}
        , .{ req_id, tool_name });
        defer allocator.free(req);
        req_id += 1;
        const resp = try processRequest(allocator, req, &ctx);
        try std.testing.expect(resp != null);
        defer allocator.free(resp.?);
        try std.testing.expect(std.mem.indexOf(u8, resp.?, "autenticacion requerida") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.?, "isError\":true") != null);
    }

    // Una tool de lectura sí responde sin auth.
    const read_resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":46,"method":"tools/call","params":{"name":"health","arguments":{}}}
    , &ctx);
    try std.testing.expect(read_resp != null);
    defer if (read_resp) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, read_resp.?, "autenticacion requerida") == null);
}

test "MCP-AUTH: authenticate con token correcto habilita privilegiadas" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();
    try std.testing.expect(ctx.expected_token != null);

    // Token incorrecto: sigue sin autenticar.
    const bad = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":50,"method":"tools/call","params":{"name":"authenticate","arguments":{"token":"token-falso-0000"}}}
    , &ctx);
    try std.testing.expect(bad != null);
    defer if (bad) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, bad.?, "token invalido") != null);
    try std.testing.expect(!ctx.authed);

    // Token correcto (el esperado por esta instancia): autentica.
    const good_req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":51,"method":"tools/call","params":{{"name":"authenticate","arguments":{{"token":"{s}"}}}}}}
    , .{ctx.expected_token.?});
    defer allocator.free(good_req);
    const good = try processRequest(allocator, good_req, &ctx);
    try std.testing.expect(good != null);
    defer if (good) |r| allocator.free(r);
    // La respuesta envuelve el JSON escapado — el aserto real es ctx.authed
    // y que la tool NO devolvió isError.
    try std.testing.expect(ctx.authed);
    try std.testing.expect(std.mem.indexOf(u8, good.?, "isError\":true") == null);

    // Tras auth, una privilegiada ya no responde el error de autenticación
    // (puede fallar por su propia lógica — lo que no puede es el veto de auth).
    const after = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":52,"method":"tools/call","params":{"name":"set_permission_config","arguments":{"mode":"normal"}}}
    , &ctx);
    try std.testing.expect(after != null);
    defer if (after) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, after.?, "autenticacion requerida") == null);
}

test "MCP-AUTH: initialize con params.token autentica la sesion" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();
    try std.testing.expect(ctx.expected_token != null);

    const init_req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":60,"method":"initialize","params":{{"protocolVersion":"2024-11-05","token":"{s}","capabilities":{{}},"clientInfo":{{"name":"t","version":"0"}}}}}}
    , .{ctx.expected_token.?});
    defer allocator.free(init_req);
    const resp = try processRequest(allocator, init_req, &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);
    try std.testing.expect(ctx.authed);
}

test "MCP-AUTH: tools/list marca las privilegiadas y declara authenticate" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();

    const resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":61,"method":"tools/list","params":{}}
    , &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "authenticate") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "x-devagents-privileged") != null);
}

test "B3: tools/list expone ship_order/pr_merge/prs_list/repo_clone y ship_order es privilegiada" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();

    const rl = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":40,"method":"tools/list","params":{}}
    , &ctx);
    try std.testing.expect(rl != null);
    defer if (rl) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, rl.?, "\"ship_order\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rl.?, "\"pr_merge\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rl.?, "\"prs_list\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, rl.?, "\"repo_clone\"") != null);
    // Marcada privilegiada en el listado.
    try std.testing.expect(std.mem.indexOf(u8, rl.?, "x-devagents-privileged") != null);

    // Sin auth: veto — NO llega al motor.
    const r2 = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"ship_order","arguments":{"order_id":1}}}
    , &ctx);
    try std.testing.expect(r2 != null);
    defer if (r2) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r2.?, "autenticacion requerida") != null);

    // prs_list es de lectura: sin auth devuelve [] de la tabla real, no veto.
    const r3 = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"prs_list","arguments":{}}}
    , &ctx);
    try std.testing.expect(r3 != null);
    defer if (r3) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r3.?, "[]") != null);

    // Con auth pero orden inexistente: error REAL del motor, no exito fingido.
    ctx.authed = true;
    const r4 = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":43,"method":"tools/call","params":{"name":"ship_order","arguments":{"order_id":99999}}}
    , &ctx);
    try std.testing.expect(r4 != null);
    defer if (r4) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, r4.?, "isError") != null or std.mem.indexOf(u8, r4.?, "error") != null);
}

test "VG2: MCP distingue lectura privilegiada de mutación sin token" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    for ([_][]const u8{ "fs_read", "fs_list", "fs_search", "session_messages", "worker_output", "memory_context", "approvals_list", "shell_run" }) |name| {
        const request = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\"}}}}", .{name});
        defer a.free(request);
        const denied = (try processRequest(a, request, &ctx)).?;
        defer a.free(denied);
        try std.testing.expect(std.mem.indexOf(u8, denied, "isError\":true") != null);
        const expected = if (std.mem.eql(u8, name, "shell_run")) "muta estado" else "lee datos privados";
        try std.testing.expect(std.mem.indexOf(u8, denied, expected) != null);
    }
}

test "E5.27 MCP: paridad de incidencias y acciones privilegiadas sin autenticacion" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    const catalog = (try processRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}", &ctx)).?;
    defer a.free(catalog);
    for ([_][]const u8{ "issues_list", "issue_read", "issue_prompt", "issue_comment", "order_from_issue" }) |name| {
        try std.testing.expect(std.mem.indexOf(u8, catalog, name) != null);
        try std.testing.expect(isPrivilegedTool(name));
        const request = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{{}}}}}}", .{name});
        defer a.free(request);
        const denied = (try processRequest(a, request, &ctx)).?;
        defer a.free(denied);
        try std.testing.expect(std.mem.indexOf(u8, denied, "autenticacion requerida") != null);
        ctx.authed = true;
        // F0.7: `{}` no trae los obligatorios del esquema; el validador
        // genérico lo rechaza con -32602 antes del manejador.
        const invalid = (try processRequest(a, request, &ctx)).?;
        defer a.free(invalid);
        try std.testing.expect(std.mem.indexOf(u8, invalid, "-32602") != null);
        try std.testing.expect(std.mem.indexOf(u8, invalid, "arguments.source: missing source") != null);
        ctx.authed = false;
    }
}

test "C-13: barrido post-auth — toda tool privilegiada llega a su handler, ninguna queda vetada" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();
    ctx.authed = true; // Sesion autenticada: el veto ya no aplica.

    for (PRIVILEGED_TOOLS) |tool| {
        // T12 A1: "screenshot" ya no captura en este proceso (solo registra la
        // aprobación), así que entra en el barrido como las demás. Con {} el
        // resto solo valida args o toca la BD :memory:.
        const req = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":70,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{{}}}}}}", .{tool});
        defer allocator.free(req);
        const resp = try processRequest(allocator, req, &ctx);
        try std.testing.expect(resp != null);
        defer if (resp) |r| allocator.free(r);
        // Post-auth: la respuesta puede ser error de args (-32602), error real
        // del motor o un resultado — lo que NO puede ser es el veto de auth.
        if (std.mem.indexOf(u8, resp.?, "autenticacion requerida") != null) {
            std.debug.print("C-13 veto inesperado post-auth en tool: {s}\n", .{tool});
            return error.TestUnexpectedResult;
        }
    }
}

// ---------------------------------------------------------------------------
// T12 A1/M4 (auditorías del modelo y el segundo auditor): recorrido de TODAS las tools que se
// anuncian. Cada una tiene una clase: lectura sin efecto (abierta, con su
// motivo escrito aquí, una a una), credencial MCP, o credencial más aprobación
// humana en la cabina. Una tool nueva que no se clasifique hace fallar la
// prueba; una de lectura que pase a privilegiada también (hay que moverla).
// ---------------------------------------------------------------------------

const T12OpenTool = struct { name: []const u8, motivo: []const u8 };

/// Tools abiertas sin credencial: solo leen el estado de DevAgents (base de
/// datos, memoria del proceso o configuración propia); ninguna escribe en
/// disco, lanza procesos, sale a la red, gasta cuota ni ve la pantalla.
const T12_OPEN_TOOLS = [_]T12OpenTool{
    .{ .name = "authenticate", .motivo = "es la puerta: compara el token en tiempo constante y no actúa" },
    .{ .name = "order_progress", .motivo = "lee el progreso de una orden de runtime.db" },
    .{ .name = "best_of_n_candidates", .motivo = "lee las candidatas guardadas de una orden; elegir (best_of_n_choose) es privilegiada" },
    .{ .name = "prs_list", .motivo = "lee las PR registradas en la base (ship_flow.listPrs), sin gh ni red" },
    .{ .name = "health", .motivo = "lee el detalle de salud guardado; el sondeo real es health_probe_all (privilegiada)" },
    .{ .name = "health_summary", .motivo = "lee el resumen de salud guardado" },
    .{ .name = "catalog_info", .motivo = "lee el catálogo de modelos" },
    .{ .name = "router_candidates", .motivo = "calcula candidatos del enrutador sobre el catálogo, sin llamadas" },
    .{ .name = "sessions", .motivo = "lista sesiones de la base" },
    .{ .name = "session_timeline", .motivo = "lee la línea de tiempo de una sesión" },
    .{ .name = "order_status", .motivo = "lee el estado de una orden" },
    .{ .name = "order_events", .motivo = "lee los eventos de una orden" },
    .{ .name = "get_plan", .motivo = "lee el plan de una orden" },
    .{ .name = "order_attachments", .motivo = "lista los adjuntos guardados de una orden" },
    .{ .name = "plan_poll", .motivo = "lee el estado de una planificación en curso" },
    .{ .name = "dispatch_poll", .motivo = "lee el estado de un despacho en curso" },
    .{ .name = "models_list", .motivo = "lee los modelos descubiertos; descubrir (discover_models) es privilegiada" },
    .{ .name = "models_selection_v1", .motivo = "lee la selección de modelos" },
    .{ .name = "plan_get_model", .motivo = "lee el pin del planificador; fijarlo es privilegiada" },
    .{ .name = "exec_get_model", .motivo = "lee el pin del ejecutor; fijarlo es privilegiada" },
    .{ .name = "audit_get_model", .motivo = "lee el pin del auditor; fijarlo es privilegiada" },
    .{ .name = "swarm_get_models", .motivo = "lee el enjambre; fijarlo es privilegiada" },
    .{ .name = "paid_budget_get", .motivo = "lee el cupo de gasto; cambiarlo es solo de la cabina" },
    .{ .name = "order_preflight", .motivo = "calcula la configuración vigente sobre la base, sin llamadas" },
    .{ .name = "agents_external_list", .motivo = "lee la última detección guardada; redetectar (agents_external_refresh) es privilegiada" },
    .{ .name = "external_paths_get", .motivo = "lee las rutas configuradas; cambiarlas es solo de la cabina" },
    .{ .name = "external_limits_get", .motivo = "lee los límites; cambiarlos es solo de la cabina" },
    .{ .name = "list_keys", .motivo = "lista proveedores con clave sin el valor; añadir o quitar es privilegiada" },
    .{ .name = "mcp_is_connected", .motivo = "lee si hay un servidor MCP conectado; conectar es solo de la cabina" },
    .{ .name = "mcp_tools", .motivo = "pide tools/list al servidor que la cabina ya conectó; no lanza procesos (llamar es privilegiada)" },
    .{ .name = "list_artifacts", .motivo = "lee los artefactos registrados" },
    .{ .name = "skills_discover", .motivo = "lee los manifiestos de habilidades de los mounts registrados por la cabina" },
    .{ .name = "inventory", .motivo = "lee el inventario guardado; refrescarlo es privilegiada" },
    .{ .name = "webhooks_list", .motivo = "lista los webhooks registrados" },
    .{ .name = "remote_status", .motivo = "lee el estado del acceso remoto, sin la credencial" },
    .{ .name = "mounts_list", .motivo = "lista los mounts registrados" },
    .{ .name = "specialists", .motivo = "lista los especialistas" },
    .{ .name = "ledger_escalations", .motivo = "lee escalados del registro de auditoría" },
    .{ .name = "audit_ledger", .motivo = "lee el registro de auditoría" },
    .{ .name = "audit_checklist", .motivo = "lee la lista de auditoría" },
    .{ .name = "usage_summary", .motivo = "lee el resumen de uso" },
    .{ .name = "preview", .motivo = "solo valida que la URL sea localhost y la devuelve; no abre ni pide nada" },
    .{ .name = "repo_embed_status", .motivo = "lee el estado del índice; indexar es privilegiada" },
    .{ .name = "embeddings_config_get", .motivo = "lee la configuración de embeddings; cambiarla es privilegiada" },
    .{ .name = "model_scores", .motivo = "lee las puntuaciones guardadas" },
    .{ .name = "evolution_summary", .motivo = "lee el resumen de evolución" },
    .{ .name = "capabilities", .motivo = "describe versión, gobierno y tools" },
    .{ .name = "spaces_list", .motivo = "lista los spaces de la base; crearlos, archivarlos y podarlos es privilegiada" },
};

fn t12OpenMotivo(name: []const u8) ?[]const u8 {
    for (T12_OPEN_TOOLS) |entry| {
        if (std.mem.eql(u8, entry.name, name)) return entry.motivo;
    }
    return null;
}

fn t12ScreenshotFiles(io: std.Io) !usize {
    var dir = std.Io.Dir.cwd().openDir(io, ".screenshots", .{ .iterate = true }) catch |e| switch (e) {
        error.FileNotFound => return 0,
        else => return e,
    };
    defer dir.close(io);
    var it = dir.iterate();
    var n: usize = 0;
    while (try it.next(io)) |entry| {
        if (entry.kind == .file) n += 1;
    }
    return n;
}

test "T12 A1: toda tool anunciada tiene clase; ninguna con efecto actúa sin credencial ni, si lo exige, sin humano" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);
    const dir_z = try allocator.dupeZ(u8, dir);
    defer allocator.free(dir_z);
    var previous: [4096]u8 = undefined;
    const previous_len = GetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", &previous, previous.len);
    defer {
        if (previous_len > 0 and previous_len < previous.len) {
            previous[previous_len] = 0;
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", @ptrCast(&previous[0]));
        } else {
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", null);
        }
    }
    try std.testing.expect(SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", dir_z.ptr) != 0);
    const base = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{dir});
    defer allocator.free(base);
    try std.Io.Dir.cwd().createDirPath(io, base);
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();

    // 1. Ninguna excepción caduca: cada abierta existe y no es privilegiada.
    for (T12_OPEN_TOOLS) |entry| {
        try std.testing.expect(entry.motivo.len > 0);
        var advertised = false;
        for (capability_tools) |tool| advertised = advertised or std.mem.eql(u8, tool, entry.name);
        if (!advertised or isPrivilegedTool(entry.name)) {
            std.debug.print("T12 A1: la excepción {s} no se anuncia o ya es privilegiada\n", .{entry.name});
            return error.TestUnexpectedResult;
        }
    }
    // 2. Todo lo demás que se anuncia exige credencial y, sin ella, no llega
    //    al manejador.
    var req_id: i64 = 1;
    for (capability_tools) |tool| {
        if (t12OpenMotivo(tool) != null) continue;
        if (!isPrivilegedTool(tool)) {
            std.debug.print("T12 A1: {s} se anuncia sin clase (ni lectura justificada ni privilegiada)\n", .{tool});
            return error.TestUnexpectedResult;
        }
        const req = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{{}}}}}}", .{ req_id, tool });
        defer allocator.free(req);
        req_id += 1;
        const resp = (try processRequest(allocator, req, &ctx)).?;
        defer allocator.free(resp);
        if (std.mem.indexOf(u8, resp, "autenticacion requerida") == null or std.mem.indexOf(u8, resp, "isError\":true") == null) {
            std.debug.print("T12 A1: {s} respondió sin credencial: {s}\n", .{ tool, resp });
            return error.TestUnexpectedResult;
        }
    }

    // 3. Con credencial, las que ven la pantalla, ejecutan o escriben con git
    //    solo dejan la tarjeta: nada se captura, nada corre.
    ctx.authed = true;
    const shots_before = try t12ScreenshotFiles(io);
    const HumanCase = struct { name: []const u8, request: []const u8, expect: []const u8 };
    const human = [_]HumanCase{
        .{ .name = "screenshot", .request = "{\"jsonrpc\":\"2.0\",\"id\":900,\"method\":\"tools/call\",\"params\":{\"name\":\"screenshot\",\"arguments\":{}}}", .expect = "\\\"status\\\":\\\"pending\\\"" },
        .{ .name = "capture_screenshot", .request = "{\"jsonrpc\":\"2.0\",\"id\":901,\"method\":\"tools/call\",\"params\":{\"name\":\"capture_screenshot\",\"arguments\":{}}}", .expect = "\\\"status\\\":\\\"pending\\\"" },
        .{ .name = "shell_run", .request = "{\"jsonrpc\":\"2.0\",\"id\":902,\"method\":\"tools/call\",\"params\":{\"name\":\"shell_run\",\"arguments\":{\"exe\":\"touch\",\"args\":[\"T12-never-created\"]}}}", .expect = "PermissionRequired" },
        .{ .name = "run_detached", .request = "{\"jsonrpc\":\"2.0\",\"id\":903,\"method\":\"tools/call\",\"params\":{\"name\":\"run_detached\",\"arguments\":{\"exe\":\"python\",\"args\":[\"T12-never-run.py\"]}}}", .expect = "PermissionRequired" },
        .{ .name = "git_add", .request = "{\"jsonrpc\":\"2.0\",\"id\":904,\"method\":\"tools/call\",\"params\":{\"name\":\"git_add\",\"arguments\":{\"paths\":[\"T12.txt\"]}}}", .expect = "PermissionRequired" },
        .{ .name = "git_commit", .request = "{\"jsonrpc\":\"2.0\",\"id\":905,\"method\":\"tools/call\",\"params\":{\"name\":\"git_commit\",\"arguments\":{\"message\":\"t12\"}}}", .expect = "PermissionRequired" },
        .{ .name = "spaces_prune", .request = "{\"jsonrpc\":\"2.0\",\"id\":906,\"method\":\"tools/call\",\"params\":{\"name\":\"spaces_prune\",\"arguments\":{\"project_id\":\"t12\"}}}", .expect = "approval_id" },
    };
    for (human) |case| {
        try std.testing.expect(isPrivilegedTool(case.name));
        const resp = (try processRequest(allocator, case.request, &ctx)).?;
        defer allocator.free(resp);
        if (std.mem.indexOf(u8, resp, case.expect) == null) {
            std.debug.print("T12 A1: {s} con credencial no se quedó en la aprobación humana: {s}\n", .{ case.name, resp });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expectEqual(shots_before, try t12ScreenshotFiles(io));
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, "T12-never-created", .{}));
    const marker = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace" ++ std.fs.path.sep_str ++ "T12-never-created", .{dir});
    defer allocator.free(marker);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, marker, .{}));
    // Las dos capturas quedaron como tarjetas pendientes, no como imágenes.
    var pending: [*:0]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_approval_pending_json(ctx.core_handle.?, &pending));
    defer core.c_api.da_string_free(pending);
    var captures: usize = 0;
    var rest: []const u8 = std.mem.span(pending);
    while (std.mem.indexOf(u8, rest, core.c_api.SCREEN_CAPTURE_PREFIX)) |at| {
        captures += 1;
        rest = rest[at + core.c_api.SCREEN_CAPTURE_PREFIX.len ..];
    }
    try std.testing.expect(captures >= 2);
}

test "C-13: post-auth shell_run sin command rechaza con -32602 (validacion real, no veto)" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();
    ctx.authed = true;

    const resp = try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":71,"method":"tools/call","params":{"name":"shell_run","arguments":{}}}
    , &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "-32602") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "autenticacion requerida") == null);
}

test "E5.23 MCP attachment discovery authorization and forged PNG rejection" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    const list = try processRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}", &ctx);
    defer if (list) |r| a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, list.?, "order_attachments") != null);
    try std.testing.expect(std.mem.indexOf(u8, list.?, "attachments") != null);
    const request = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"order_submit\",\"arguments\":{\"order_text\":\"red button\",\"attachments\":[{\"name\":\"fake.png\",\"data_base64\":\"bm90LWFuLWltYWdl\"}]}}}";
    const denied = try processRequest(a, request, &ctx);
    defer if (denied) |r| a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, denied.?, "autenticacion requerida") != null);
    ctx.authed = true;
    const invalid = try processRequest(a, request, &ctx);
    defer if (invalid) |r| a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, invalid.?, "UnsupportedImage") != null);
    const listed = try processRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"order_attachments\",\"arguments\":{\"order_id\":1}}}", &ctx);
    defer if (listed) |r| a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, listed.?, "[]") != null);
}

test "E5.24 MCP explicit vision probe authorization and unavailable model" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    const req = "{\"jsonrpc\":\"2.0\",\"id\":24,\"method\":\"tools/call\",\"params\":{\"name\":\"vision_probe\",\"arguments\":{\"provider\":\"synthetic-no-provider\",\"model\":\"synthetic\"}}}";
    const denied = try processRequest(a, req, &ctx);
    defer if (denied) |r| a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, denied.?, "autenticacion requerida") != null);
    ctx.authed = true;
    const reply = try processRequest(a, req, &ctx);
    defer if (reply) |r| a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, reply.?, "not_probed") != null);
    const invalid = try processRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":25,\"method\":\"tools/call\",\"params\":{\"name\":\"vision_probe\",\"arguments\":{}}}", &ctx);
    defer if (invalid) |r| a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, invalid.?, "missing provider") != null);
}

test "E5.29 MCP SSRF private opt-in is discoverable typed and persisted" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true;
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"webhook_add\",\"arguments\":{\"url\":\"http://127.0.0.1/hook\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"webhook_add\",\"arguments\":{\"url\":\"http://127.0.0.1/hook\",\"allow_private\":\"true\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"webhook_add\",\"arguments\":{\"url\":\"http://127.0.0.1/hook\",\"allow_private\":true}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"webhooks_list\",\"arguments\":{}}}",
    }, 0..) |request, i| {
        const response = (try processRequest(a, request, &ctx)) orelse return error.MissingResponse;
        defer a.free(response);
        switch (i) {
            0 => {
                try std.testing.expect(std.mem.indexOf(u8, response, "allow_private") != null);
                try std.testing.expect(std.mem.indexOf(u8, response, "Advertencia") != null);
            },
            1 => try std.testing.expect(std.mem.indexOf(u8, response, "PrivateDestination") != null),
            2 => try std.testing.expect(std.mem.indexOf(u8, response, "-32602") != null),
            // H7: por MCP allow_private=true lo rechaza el nucleo
            // (el opt-in de destinos privados exige la cabina).
            3 => try std.testing.expect(std.mem.indexOf(u8, response, "cabina") != null),
            // H7: el receptor privado no se persiste.
            4 => try std.testing.expect(std.mem.indexOf(u8, response, "allow_private\\\":true") == null),
            else => return error.UnexpectedCase,
        }
    }
}

test "CK-SEG-012 H7 MCP tools only harden external limits paths mounts and webhooks" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true;
    // T7 (paridad sin gobierno): limites y rutas de agentes externos ya no se
    // tocan por MCP, ni para endurecer: todo va a la cabina.
    const limits = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"external_limits_set\",\"arguments\":{\"json\":\"{\\\"order_timeout_ms\\\":999999999}\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"external_limits_set\",\"arguments\":{\"json\":\"{\\\"order_timeout_ms\\\":60000}\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"external_limits_set\",\"arguments\":{\"json\":\"{\\\"order_timeout_ms\\\":0}\"}}}",
    };
    for (limits, 0..) |request, i| {
        const response = (try processRequest(a, request, &ctx)) orelse return error.MissingResponse;
        defer a.free(response);
        switch (i) {
            0, 1, 2 => try std.testing.expect(std.mem.indexOf(u8, response, "UI humana") != null),
            else => return error.UnexpectedCase,
        }
    }
    // external_paths_set: ni registrar ni vaciar por MCP; la lectura sigue abierta.
    const paths = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"external_paths_set\",\"arguments\":{\"json\":\"{\\\"codex\\\":\\\"C:/Other/codex.exe\\\"}\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"external_paths_set\",\"arguments\":{\"json\":\"{}\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"external_paths_get\"}}",
    };
    for (paths, 0..) |request, i| {
        const response = (try processRequest(a, request, &ctx)) orelse return error.MissingResponse;
        defer a.free(response);
        switch (i) {
            0, 1 => try std.testing.expect(std.mem.indexOf(u8, response, "UI humana") != null),
            2 => try std.testing.expect(std.mem.indexOf(u8, response, "{}") != null),
            else => return error.UnexpectedCase,
        }
    }
    // mount_add: sin raiz ya registrada por la cabina se rechaza con mensaje de cabina.
    const mount = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"mount_add\",\"arguments\":{\"path\":\"C:/DevAgents-wt/otra-raiz\"}}}";
    const mount_response = (try processRequest(a, mount, &ctx)) orelse return error.MissingResponse;
    defer a.free(mount_response);
    try std.testing.expect(std.mem.indexOf(u8, mount_response, "cabina") != null);
    // webhook_add: opt-in privado se rechaza con mensaje de cabina; un receptor
    // publico ordinario sigue permitido y queda en la lista.
    const hooks = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":8,\"method\":\"tools/call\",\"params\":{\"name\":\"webhook_add\",\"arguments\":{\"url\":\"https://example.test/hook\",\"allow_private\":true}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":9,\"method\":\"tools/call\",\"params\":{\"name\":\"webhook_add\",\"arguments\":{\"url\":\"https://example.test/hook\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":10,\"method\":\"tools/call\",\"params\":{\"name\":\"webhooks_list\",\"arguments\":{}}}",
    };
    for (hooks, 0..) |request, i| {
        const response = (try processRequest(a, request, &ctx)) orelse return error.MissingResponse;
        defer a.free(response);
        switch (i) {
            0 => {
                try std.testing.expect(std.mem.indexOf(u8, response, "cabina") != null);
                try std.testing.expect(std.mem.indexOf(u8, response, "ok\\\":true") == null);
            },
            1 => try std.testing.expect(std.mem.indexOf(u8, response, "ok\\\":true") != null),
            2 => try std.testing.expect(std.mem.indexOf(u8, response, "example.test") != null),
            else => return error.UnexpectedCase,
        }
    }
}

test "E5.29 MCP webhook discovery authorization configuration test deletion and errors" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    const list = try processRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\"}", &ctx);
    defer if (list) |r| a.free(r);
    for ([_][]const u8{ "webhooks_list", "webhook_add", "webhook_test", "webhook_delete" }) |tool| try std.testing.expect(std.mem.indexOf(u8, list.?, tool) != null);
    const add = "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"webhook_add\",\"arguments\":{\"url\":\"https://example.test/hook\",\"secret\":\"fixture\"}}}";
    const denied = try processRequest(a, add, &ctx);
    defer if (denied) |r| a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, denied.?, "autenticacion requerida") != null);
    ctx.authed = true;
    const added = try processRequest(a, add, &ctx);
    defer if (added) |r| a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, added.?, "isError\":false") != null);
    const listed = try processRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"webhooks_list\",\"arguments\":{}}}", &ctx);
    defer if (listed) |r| a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, listed.?, "fixture") == null);
    try std.testing.expect(std.mem.indexOf(u8, listed.?, "has_secret") != null);
    for ([_][]const u8{ "webhook_test", "webhook_delete" }) |tool| {
        const request = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{{\"name\":\"{s}\",\"arguments\":{{\"id\":1}}}}}}", .{tool});
        defer a.free(request);
        const response = try processRequest(a, request, &ctx);
        defer if (response) |r| a.free(r);
        try std.testing.expect(std.mem.indexOf(u8, response.?, "isError\":false") != null);
    }
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"webhook_test\",\"arguments\":{\"id\":-1}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"webhook_add\",\"arguments\":{\"url\":\"https://example.test\",\"secret\":42}}}",
    }) |request| {
        const response = try processRequest(a, request, &ctx);
        defer if (response) |r| a.free(r);
        try std.testing.expect(std.mem.indexOf(u8, response.?, "-32602") != null);
    }
    const missing = try processRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/call\",\"params\":{\"name\":\"webhook_delete\",\"arguments\":{\"id\":1}}}", &ctx);
    defer if (missing) |r| a.free(r);
    try std.testing.expect(std.mem.indexOf(u8, missing.?, "isError\":true") != null);
}

test "ORDENES R2 MCP paid budget: el cupo solo se cambia en la cabina y la lectura sigue abierta" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true;
    // T7 (paridad sin gobierno): ni subir ni bajar el cupo por MCP.
    for ([_][]const u8{ "{}", "{\"authorized\":0,\"explicit\":true}", "{\"authorized\":201,\"explicit\":true}" }) |args| {
        const request = try std.fmt.allocPrint(a, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"paid_budget_set\",\"arguments\":{s}}}}}", .{args});
        defer a.free(request);
        const result = (try processRequest(a, request, &ctx)).?;
        defer a.free(result);
        try std.testing.expect(std.mem.indexOf(u8, result, "UI humana") != null);
    }
    const read = (try processRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"paid_budget_get\",\"arguments\":{}}}", &ctx)).?;
    defer a.free(read);
    try std.testing.expect(std.mem.indexOf(u8, read, "\\\"spent\\\":0") != null);
}

test "SEC2 R6 H4 H8 paid_budget_set and ui_action require the MCP credential" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = false;
    // T7: paid_budget_set ya no existe por MCP (cabina); sin credencial tampoco.
    const budget = (try processRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"paid_budget_set\",\"arguments\":{\"authorized\":201,\"explicit\":true}}}", &ctx)).?;
    defer a.free(budget);
    try std.testing.expect(std.mem.indexOf(u8, budget, "UI humana") != null);
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"ui_action\",\"arguments\":{\"action\":\"notify\",\"args\":{\"text\":\"Aprueba el comando pendiente\"}}}}",
    }) |request| {
        const response = (try processRequest(a, request, &ctx)).?;
        defer a.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "autenticacion requerida") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "isError\":true") != null);
    }
    // Sin credencial el cupo no se movio; la lectura sigue abierta.
    const read = (try processRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"paid_budget_get\",\"arguments\":{}}}", &ctx)).?;
    defer a.free(read);
    try std.testing.expect(std.mem.indexOf(u8, read, "autenticacion requerida") == null);
    try std.testing.expect(std.mem.indexOf(u8, read, "\\\"remaining\\\":201") == null);
}

test "SEC2 R6 H1 MCP client cannot approve its own shell_run card through remote_start" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true;
    const handle = ctx.core_handle.?;
    // 1. shell_run crea una tarjeta exacta (el comando NO corre).
    const run = (try processRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"shell_run\",\"arguments\":{\"exe\":\"powershell\",\"args\":[\"-NoProfile\",\"-NonInteractive\",\"-Command\",\"Write-Output sec2-r6\"]}}}", &ctx)).?;
    defer a.free(run);
    try std.testing.expect(std.mem.indexOf(u8, run, "PermissionRequired") != null);
    var pending: [*:0]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_approval_pending_json(handle, &pending));
    defer core.c_api.da_string_free(pending);
    var parsed = try std.json.parseFromSlice(std.json.Value, a, std.mem.span(pending), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.array.items.len >= 1);
    const approval_id = parsed.value.array.items[0].object.get("id").?.integer;
    // 2. e5-harden punto 8: remote_start ya no abre el listener ni entrega el
    // token a un cliente MCP; la cabina es quien lo inicia.
    const started = (try processRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"remote_start\",\"arguments\":{}}}", &ctx)).?;
    defer a.free(started);
    try std.testing.expect(ctx.remote_session == null);
    try std.testing.expect(std.mem.indexOf(u8, started, "isError\":true") != null);
    // 3. Defensa en profundidad: aunque hubiera un listener sobre este handle,
    // POST /api/approvals/{id} {"approved":true} es exactamente lo que el
    // servidor HTTP reenviaria a da_remote_request_json, y debe dar 403.
    const path = try std.fmt.allocPrint(a, "/api/approvals/{d}", .{approval_id});
    defer a.free(path);
    for ([_]struct { method: []const u8, path: []const u8, body: []const u8 }{
        .{ .method = "POST", .path = path, .body = "{\"approved\":true}" },
        .{ .method = "POST", .path = path, .body = "{\"approved\":false}" },
        .{ .method = "POST", .path = "/api/orders/1/approve", .body = "{}" },
        .{ .method = "POST", .path = "/api/orders/1/cancel", .body = "{}" },
        .{ .method = "POST", .path = "/api/orders/1/workspace/restore_permissions", .body = "{\"explicit\":true}" },
    }) |request| {
        const json = try std.json.Stringify.valueAlloc(a, .{ .method = request.method, .path = request.path, .body = request.body }, .{});
        defer a.free(json);
        const z = try a.dupeZ(u8, json);
        defer a.free(z);
        var output: ?[*:0]u8 = null;
        try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_remote_request_json(handle, z, &output));
        defer core.c_api.da_string_free(output.?);
        const reply = try std.json.parseFromSlice(struct { status: u16, body: []const u8 }, a, std.mem.span(output.?), .{});
        defer reply.deinit();
        try std.testing.expectEqual(@as(u16, 403), reply.value.status);
    }
    // La tarjeta sigue sin resolver y el nucleo MCP tampoco la resuelve por C-ABI.
    try std.testing.expect(core.c_api.da_approval_resolve(handle, approval_id, 1) != 0);
    try std.testing.expect(core.c_api.da_approval_resolve_scoped(handle, approval_id, 1, 0) != 0);
    var still: [*:0]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_approval_pending_json(handle, &still));
    defer core.c_api.da_string_free(still);
    try std.testing.expect(std.mem.indexOf(u8, std.mem.span(still), "sec2-r6") != null);
}

test "PRICING MCP tool contract declares v2 arrays and suggestion policy" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    const response = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":91,"method":"tools/list","params":{}}
    , &ctx)).?;
    defer allocator.free(response);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    for (parsed.value.object.get("result").?.object.get("tools").?.array.items) |tool| {
        if (!std.mem.eql(u8, tool.object.get("name").?.string, "pricing_revalidate")) continue;
        const description = tool.object.get("description").?.string;
        for ([_][]const u8{ "schema=pricing_revalidate.v2", "changes como array", "suggestions como array", "Pago→gratis solo se sugiere", "isError=true" }) |expected| {
            try std.testing.expect(std.mem.indexOf(u8, description, expected) != null);
        }
        return;
    }
    return error.PricingToolMissing;
}

// ---------------------------------------------------------------------------
// — batería server-side in-process de // sobre
// `processRequest` (y `drainOverlongLine` para). Hermética: `:memory:`,
// sin red ni procesos. Re-añadida tras quedar fuera del archivo en el cierre
// de E3.38 (bitácora la documentación interna:2073).
//
// Cobertura ya existente que NO se duplica:
//   * tools/mcp_server.zig:3728 "MCP-AUTH: tools privilegiadas rechazan sin
//     sesion autenticada" — veto de auth pre-dispatch.
//   * tools/mcp_server.zig:3767 "MCP-AUTH: authenticate con token correcto..."
//     y :3808 "initialize con params.token..." — el token correcto autentica.
//   * tools/mcp_server.zig:3512 "health_probe_all rejects negative and c_int
// overflow before dispatch" — guard c_int de health_probe_all.
// El resto de sitios (idOf/intOf, orderIdToHandle, usage_summary/web_search/
// mcp_connect, arguments no-objeto, drenado de línea) quedan aquí.
// ---------------------------------------------------------------------------

test "CK-SEG-014: E-70 token ajeno y casi-acierto no autentican" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    try std.testing.expect(!ctx.authed);
    const real = ctx.expected_token.?;
    try std.testing.expect(real.len >= 16);

    // Token "ajeno": 32 hex válidos que NO son los de esta instancia (el token
    // de otra instancia es indistinguible de uno inventado — E3.38 punto 9).
    var foreign_buf: [64]u8 = undefined;
    @memcpy(foreign_buf[0..real.len], real);
    foreign_buf[0] = if (foreign_buf[0] == '0') '1' else '0';
    const foreign = foreign_buf[0..real.len];

    // Casi-acierto: el token propio con el último carácter cambiado.
    var near_buf: [64]u8 = undefined;
    @memcpy(near_buf[0..real.len], real);
    near_buf[real.len - 1] = if (near_buf[real.len - 1] == '0') '1' else '0';
    const near = near_buf[0..real.len];

    for ([_][]const u8{ foreign, near }) |candidate| {
        const request = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{{\"name\":\"authenticate\",\"arguments\":{{\"token\":\"{s}\"}}}}}}", .{candidate});
        defer allocator.free(request);
        const resp = try processRequest(allocator, request, &ctx);
        try std.testing.expect(resp != null);
        defer if (resp) |r| allocator.free(r);
        try std.testing.expect(std.mem.indexOf(u8, resp.?, "token invalido") != null);
        try std.testing.expect(!ctx.authed);
    }

    // Control positivo: el token propio SÍ autentica (descarta el falso verde).
    const ok_request = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{{\"name\":\"authenticate\",\"arguments\":{{\"token\":\"{s}\"}}}}}}", .{real});
    defer allocator.free(ok_request);
    const ok = try processRequest(allocator, ok_request, &ctx);
    try std.testing.expect(ok != null);
    defer if (ok) |r| allocator.free(r);
    try std.testing.expect(ctx.authed);
}

test "CK-SEG-014: E-70 token fuera de sitio no autentica ni se filtra" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    try std.testing.expect(!ctx.authed);
    const real = ctx.expected_token.?;

    // 1) token top-level (fuera de params).
    const top = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"2024-11-05\"}},\"token\":\"{s}\"}}", .{real});
    defer allocator.free(top);
    const r1 = try processRequest(allocator, top, &ctx);
    try std.testing.expect(r1 != null);
    defer if (r1) |r| allocator.free(r);
    try std.testing.expect(!ctx.authed);

    // 2) token anidado en params.capabilities (no en params.token).
    const nested = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{{\"token\":\"{s}\"}}}}}}", .{real});
    defer allocator.free(nested);
    const r2 = try processRequest(allocator, nested, &ctx);
    try std.testing.expect(r2 != null);
    defer if (r2) |r| allocator.free(r);
    try std.testing.expect(!ctx.authed);

    // 3) token en los `arguments` de OTRA tool (health, tool abierta).
    const other = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{{\"name\":\"health\",\"arguments\":{{\"token\":\"{s}\"}}}}}}", .{real});
    defer allocator.free(other);
    const r3 = try processRequest(allocator, other, &ctx);
    try std.testing.expect(r3 != null);
    defer if (r3) |r| allocator.free(r);
    try std.testing.expect(!ctx.authed);

    // El token jamás viaja en las respuestas de esos sitios equivocados.
    try std.testing.expect(std.mem.indexOf(u8, r1.?, real) == null);
    try std.testing.expect(std.mem.indexOf(u8, r3.?, real) == null);

    // Control positivo: en params.token SÍ autentica.
    const correct = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"initialize\",\"params\":{{\"protocolVersion\":\"2024-11-05\",\"token\":\"{s}\"}}}}", .{real});
    defer allocator.free(correct);
    const r4 = try processRequest(allocator, correct, &ctx);
    try std.testing.expect(r4 != null);
    defer if (r4) |r| allocator.free(r);
    try std.testing.expect(ctx.authed);
}

test "CK-SEG-014: E-71 id float fuera de rango no tumba el proceso" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();

    // `"id":1e30`, `1e999`/`-1e999` (=±inf) y `-1e30` no son representables en
    // i64; `idOf` los reduce a 0 (guard de rango) en vez de paniquear en
    // `@intFromFloat` y matar el servidor con UNA línea JSON.
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1e30,\"method\":\"initialize\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":1e999,\"method\":\"initialize\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":-1e999,\"method\":\"initialize\",\"params\":{}}",
        "{\"jsonrpc\":\"2.0\",\"id\":-1e30,\"method\":\"initialize\",\"params\":{}}",
    }) |request| {
        const resp = try processRequest(allocator, request, &ctx);
        try std.testing.expect(resp != null);
        defer if (resp) |r| allocator.free(r);
        try std.testing.expect(std.mem.indexOf(u8, resp.?, "\"id\":0") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.?, LATEST_PROTOCOL_VERSION) != null);
    }
}

test "CK-SEG-014: E-71 order_id no positivo responde error sin panic" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true;

    // Autenticada también session_messages. `orderIdToHandle(id<=0)` → null → la C-API
    // devuelve `invalid_arg`; antes del guard, el `@intCast(i64→usize)` de un
    // id negativo paniqueaba y tumbaba el servidor.
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"order_status\",\"arguments\":{\"order_id\":-1}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"get_plan\",\"arguments\":{\"order_id\":-1}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"order_events\",\"arguments\":{\"order_id\":-9999999999}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"session_messages\",\"arguments\":{\"order_id\":0}}}",
    }) |request| {
        const resp = try processRequest(allocator, request, &ctx);
        try std.testing.expect(resp != null);
        defer if (resp) |r| allocator.free(r);
        try std.testing.expect(std.mem.indexOf(u8, resp.?, "isError\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.?, "autenticacion requerida") == null);
    }
}

test "CK-SEG-014: E-71 order_id float/inf o tipo erroneo responde -32602" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true;

    // `intOf` devuelve null para floats fuera de i64 y para tipos no numéricos;
    // las tools responden -32602 en vez de paniquear o tragarse el argumento.
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"order_status\",\"arguments\":{\"order_id\":1e30}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"order_status\",\"arguments\":{\"order_id\":1e999}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"order_events\",\"arguments\":{\"order_id\":-1e999}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"get_plan\",\"arguments\":{\"order_id\":\"x\"}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"order_status\",\"arguments\":{\"order_id\":true}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"session_messages\",\"arguments\":{\"order_id\":[1]}}}",
    }) |request| {
        const resp = try processRequest(allocator, request, &ctx);
        try std.testing.expect(resp != null);
        defer if (resp) |r| allocator.free(r);
        try std.testing.expect(std.mem.indexOf(u8, resp.?, "-32602") != null);
    }
}

test "CK-SEG-014: E-71 overflow c_int y arguments no-objeto rechazan -32602" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true;

    // Valores enteros > maxInt(c_int) (caben en i64, no en c_int): guard antes
    // del @intCast. usage_summary y web_search son abiertas (mcp_connect salio
    // del MCP en T7: es de la cabina).
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"usage_summary\",\"arguments\":{\"order_id\":2147483648}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"web_search\",\"arguments\":{\"query\":\"x\",\"max_results\":2147483648}}}",
    }) |request| {
        const resp = try processRequest(allocator, request, &ctx);
        try std.testing.expect(resp != null);
        defer if (resp) |r| allocator.free(r);
        try std.testing.expect(std.mem.indexOf(u8, resp.?, "-32602") != null);
    }

    // `arguments` no-objeto (string/número/array) era tragado como {} en
    // silencio; ahora es -32602 explícito, no un resultado de args vacíos.
    for ([_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"health\",\"arguments\":\"oops\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":5,\"method\":\"tools/call\",\"params\":{\"name\":\"health\",\"arguments\":5}}",
        "{\"jsonrpc\":\"2.0\",\"id\":6,\"method\":\"tools/call\",\"params\":{\"name\":\"health\",\"arguments\":[1,2]}}",
    }) |request| {
        const resp = try processRequest(allocator, request, &ctx);
        try std.testing.expect(resp != null);
        defer if (resp) |r| allocator.free(r);
        try std.testing.expect(std.mem.indexOf(u8, resp.?, "-32602") != null);
        try std.testing.expect(std.mem.indexOf(u8, resp.?, "arguments must be an object") != null);
    }
}

test "CK-SEG-014: E-72 linea mayor que el buffer se drena y la sesion resincroniza" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    // Una línea de 64 KiB (mucho mayor que el buffer del lector) seguida de una
    // petición válida en el mismo stream: el lector desborda en la primera
    // (StreamTooLong) y, tras el drenado, devuelve la segunda lista para
    // procesar. Sin el drenado, el siguiente takeDelimiter vuelve a desbordar.
    const valid_line = "{\"jsonrpc\":\"2.0\",\"id\":7,\"method\":\"tools/list\",\"params\":{}}";
    const long_line = try allocator.alloc(u8, 64 * 1024);
    defer allocator.free(long_line);
    @memset(long_line, 'A');
    {
        const file = try tmp.dir.createFile(io, "stream.txt", .{});
        try file.writeStreamingAll(io, long_line);
        try file.writeStreamingAll(io, "\n" ++ valid_line ++ "\n");
        file.close(io);
    }

    var in = try tmp.dir.openFile(io, "stream.txt", .{});
    defer in.close(io);
    var read_buf: [1024]u8 = undefined;
    var reader = in.readerStreaming(io, &read_buf);

    try std.testing.expectError(error.StreamTooLong, reader.interface.takeDelimiter('\n'));
    try drainOverlongLine(&reader.interface);

    // El drenado deja el '\n' que cierra la línea larga (streamDelimiterEnding
    // NO lo consume), así que la primera lectura posterior es la línea vacía.
    // El main loop real la ignora (tools/mcp_server.zig:469
    // `if (trimmed.len == 0) continue;`): no responde nada por ella. El test
    // reproduce ese bucle en vez de asumir que el drenado consume el '\n'.
    var next: []const u8 = "";
    var empties: usize = 0;
    while (next.len == 0) {
        next = (try reader.interface.takeDelimiter('\n')) orelse return error.MissingResyncedLine;
        if (next.len == 0) {
            empties += 1;
            if (empties > 4) return error.ResyncStuckOnEmptyLines;
        }
    }
    try std.testing.expectEqualStrings(valid_line, next);

    // La línea resincronizada es procesable por el servidor real.
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    const resp = try processRequest(allocator, next, &ctx);
    try std.testing.expect(resp != null);
    defer if (resp) |r| allocator.free(r);
    try std.testing.expect(std.mem.indexOf(u8, resp.?, "\"tools\"") != null);
}

test "CK-COMP-004: MCP handshake declares the shared build and protocol identity" {
    const allocator = std.testing.allocator;
    const response = try buildInitializeResp(allocator, 42, LATEST_PROTOCOL_VERSION);
    defer allocator.free(response);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const info = parsed.value.object.get("result").?.object.get("serverInfo").?.object;
    try std.testing.expectEqualStrings(std.mem.span(core.c_api.da_build_identity_v1()), info.get("version").?.string);
}

// ---------------------------------------------------------------------------
//: paridad MCP de core.space.create / core.space.archive /
// core.spaces.prune (shell/host/bridge.cpp:3265-3328). Las tres escriben
// (worktrees + filas en runtime.db) => privilegiadas, como el resto de mutaciones.
// ---------------------------------------------------------------------------

test "CK-MCP-001: tools/list anuncia los tres tools de spaces con su esquema" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    const listing = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":1,"method":"tools/list","params":{}}
    , &ctx)).?;
    defer allocator.free(listing);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, listing, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("result").?.object.get("tools").?.array.items;
    var seen_create = false;
    var seen_archive = false;
    var seen_prune = false;
    for (tools) |tool| {
        const tname = tool.object.get("name").?.string;
        const is_create = std.mem.eql(u8, tname, "space_create");
        const is_archive = std.mem.eql(u8, tname, "space_archive");
        const is_prune = std.mem.eql(u8, tname, "spaces_prune");
        if (!is_create and !is_archive and !is_prune) continue;
        seen_create = seen_create or is_create;
        seen_archive = seen_archive or is_archive;
        seen_prune = seen_prune or is_prune;
        // Escriben estado: marcadas privilegiadas para el cliente.
        try std.testing.expect(tool.object.get("x-devagents-privileged").?.bool);
        const schema = tool.object.get("inputSchema").?.object;
        // Esquema estricto: lo que no este declarado se rechaza en despacho.
        try std.testing.expect(!schema.get("additionalProperties").?.bool);
        const properties = schema.get("properties").?.object;
        const required = schema.get("required").?.array.items;
        if (is_create) {
            try std.testing.expect(properties.contains("project_id"));
            try std.testing.expect(properties.contains("name"));
            try std.testing.expect(properties.contains("kind"));
            var name_required = false;
            for (required) |field| {
                if (std.mem.eql(u8, field.string, "name")) name_required = true;
            }
            try std.testing.expect(name_required);
        } else if (is_archive) {
            try std.testing.expect(properties.contains("space_id"));
            var id_required = false;
            for (required) |field| {
                if (std.mem.eql(u8, field.string, "space_id")) id_required = true;
            }
            try std.testing.expect(id_required);
        } else {
            try std.testing.expect(properties.contains("project_id"));
        }
    }
    try std.testing.expect(seen_create and seen_archive and seen_prune);
    try std.testing.expect(isPrivilegedTool("space_create"));
    try std.testing.expect(isPrivilegedTool("space_archive"));
    try std.testing.expect(isPrivilegedTool("spaces_prune"));
}

test "CK-MCP-001: ciclo real create/archive/prune sobre un workspace temporal" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);
    // La raiz la elige quien LANZA el servidor (aqui, el test) via
    // DEVAGENTS_WORKSPACE_ROOT: ServerCtx.init la aplica ANTES de marcar la
    // superficie MCP (tools/mcp_server.zig:550) y es la unica via para una
    // raiz nueva (set_workspace_root solo puede estrechar la vigente).
    const dir_z = try allocator.dupeZ(u8, dir);
    defer allocator.free(dir_z);
    var previous: [4096]u8 = undefined;
    const previous_len = GetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", &previous, previous.len);
    defer {
        if (previous_len > 0 and previous_len < previous.len) {
            previous[previous_len] = 0;
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", @ptrCast(&previous[0]));
        } else {
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", null);
        }
    }
    try std.testing.expect(SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", dir_z.ptr) != 0);
    const base = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{dir});
    defer allocator.free(base);
    try std.Io.Dir.cwd().createDirPath(io, base);
    var ctx = try ServerCtx.init(allocator, io, ":memory:");
    defer ctx.deinit();
    ctx.authed = true;

    const created = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"space_create","arguments":{"project_id":"ck-mcp-001","name":"ck-mcp-001-space","kind":"order"}}}
    , &ctx)).?;
    defer allocator.free(created);
    var created_outer = try std.json.parseFromSlice(std.json.Value, allocator, created, .{});
    defer created_outer.deinit();
    const card = created_outer.value.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
    if (created_outer.value.object.get("result").?.object.get("isError").?.bool) {
        std.debug.print("CK-MCP-001 space_create: {s}\n", .{card});
        return error.TestUnexpectedResult;
    }
    var card_json = try std.json.parseFromSlice(std.json.Value, allocator, card, .{});
    defer card_json.deinit();
    const space_id = card_json.value.object.get("id").?.integer;
    try std.testing.expect(space_id > 0);
    const expected_path = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ ".devagents" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "ck-mcp-001-space", .{base});
    defer allocator.free(expected_path);
    try std.testing.expectEqualStrings(expected_path, card_json.value.object.get("worktreePath").?.string);
    try std.testing.expectEqualStrings("devagents/ck-mcp-001-space", card_json.value.object.get("branch").?.string);

    const archive_req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{{"name":"space_archive","arguments":{{"space_id":{d}}}}}}}
    , .{space_id});
    defer allocator.free(archive_req);
    const archived = (try processRequest(allocator, archive_req, &ctx)).?;
    defer allocator.free(archived);
    // r2 (P1): la llamada MCP de archivar NO archiva — exige aprobación humana
    // (el cliente MCP no puede concederla) y responde con error claro.
    var archived_outer = try std.json.parseFromSlice(std.json.Value, allocator, archived, .{});
    defer archived_outer.deinit();
    const archived_result = archived_outer.value.object.get("result").?.object;
    try std.testing.expect(archived_result.get("isError").?.bool);
    const archived_text = archived_result.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, archived_text, "aprobacion humana requerida") != null);

    // El gesto MCP no tocó el motor: la ficha del space sigue activa
    // (archivedAt null) y la llamada de lista del puente lo confirma.
    var list_out: [*:0]u8 = undefined;
    const list_rc = core.c_api.da_spaces_list_json(ctx.core_handle.?, "ck-mcp-001", &list_out);
    try std.testing.expectEqual(@as(c_int, 0), list_rc);
    defer core.c_api.da_string_free(list_out);
    var list_json = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.span(list_out), .{});
    defer list_json.deinit();
    try std.testing.expectEqual(@as(usize, 1), list_json.value.array.items.len);
    const listed_card = list_json.value.array.items[0].object;
    try std.testing.expect(listed_card.get("archivedAt").? == .null);
    try std.testing.expectEqualStrings("devagents/ck-mcp-001-space", listed_card.get("branch").?.string);

    // r2 (P2): ausente = default del puente. Un create con solo el nombre
    // crea en el proyecto "default" con kind "order".
    const with_defaults = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"space_create","arguments":{"name":"ck-mcp-001-def"}}}
    , &ctx)).?;
    defer allocator.free(with_defaults);
    var with_defaults_outer = try std.json.parseFromSlice(std.json.Value, allocator, with_defaults, .{});
    defer with_defaults_outer.deinit();
    const def_card_json = try std.json.parseFromSlice(std.json.Value, allocator, with_defaults_outer.value.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string, .{});
    defer def_card_json.deinit();
    try std.testing.expectEqualStrings("default", def_card_json.value.object.get("projectId").?.string);
    try std.testing.expectEqualStrings("order", def_card_json.value.object.get("kind").?.string);
    const def_space_id = def_card_json.value.object.get("id").?.integer;
    try std.testing.expect(def_space_id > 0);

    // Preparar una fila archivada: con solo fichas activas una poda sin permiso
    // también devolvería cero y el test no detectaría la pérdida de datos.
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_space_archive(ctx.core_handle.?, space_id));
    const pruned = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"spaces_prune","arguments":{"project_id":"ck-mcp-001"}}}
    , &ctx)).?;
    defer allocator.free(pruned);
    var pruned_outer = try std.json.parseFromSlice(std.json.Value, allocator, pruned, .{});
    defer pruned_outer.deinit();
    try std.testing.expect(pruned_outer.value.object.get("result").?.object.get("isError").?.bool);
    const pruned_text = pruned_outer.value.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, pruned_text, "aprobacion humana requerida") != null);
    // La ficha del proyecto default permanece activa; la archivada del otro
    // proyecto debe seguir existiendo para la poda directa posterior.
    var still_out: [*:0]u8 = undefined;
    const still_rc = core.c_api.da_spaces_list_json(ctx.core_handle.?, null, &still_out);
    try std.testing.expectEqual(@as(c_int, 0), still_rc);
    defer core.c_api.da_string_free(still_out);
    var still_json = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.span(still_out), .{});
    defer still_json.deinit();
    try std.testing.expectEqual(@as(usize, 1), still_json.value.array.items.len);
    for (still_json.value.array.items) |space_v| {
        try std.testing.expect(space_v.object.get("archivedAt").? == .null);
    }

    // C ABI directo como fixture de prueba, no como prueba de aprobación UI.
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_space_archive(ctx.core_handle.?, def_space_id));
    var pruned_count: u32 = 0;
    const proj_z = try allocator.dupeZ(u8, "ck-mcp-001");
    defer allocator.free(proj_z);
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_spaces_prune(ctx.core_handle.?, proj_z, &pruned_count));
    try std.testing.expectEqual(@as(u32, 1), pruned_count);
    const prune_default = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"spaces_prune","arguments":{}}}
    , &ctx)).?;
    defer allocator.free(prune_default);
    try std.testing.expect(std.mem.indexOf(u8, prune_default, "aprobacion humana requerida") != null);
    // Sin project_id tampoco debe borrar la fila archivada de "default".
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_spaces_prune(ctx.core_handle.?, null, &pruned_count));
    try std.testing.expectEqual(@as(u32, 1), pruned_count);
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_spaces_prune(ctx.core_handle.?, null, &pruned_count));
    try std.testing.expectEqual(@as(u32, 0), pruned_count);
}

test "CK-MCP-001: rechazos — auth, argumento desconocido, kind/nombre/space_id invalidos" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    // Sin sesion: veto de auth ANTES de llegar al motor.
    const denied = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"space_create","arguments":{"name":"x"}}}
    , &ctx)).?;
    defer allocator.free(denied);
    try std.testing.expect(std.mem.indexOf(u8, denied, "autenticacion requerida") != null);
    ctx.authed = true;
    // Argumento desconocido: -32602 antes de despachar.
    const unknown = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"spaces_prune","arguments":{"project_id":"p","prune_all":true}}}
    , &ctx)).?;
    defer allocator.free(unknown);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "-32602") != null);
    try std.testing.expect(std.mem.indexOf(u8, unknown, "argumento desconocido") != null);
    // kind fuera del contrato del motor ("order"/"main-checkout"). F0.7: el
    // enum publicado ya lo rechaza el validador genérico (-32602), antes del motor.
    const bad_kind = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"space_create","arguments":{"name":"x","kind":"fork"}}}
    , &ctx)).?;
    defer allocator.free(bad_kind);
    try std.testing.expect(std.mem.indexOf(u8, bad_kind, "-32602") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_kind, "arguments.kind: valor fuera de enum") != null);
    // Nombre con escape de ruta: lo rechaza validateSpaceName del motor.
    const bad_name = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"space_create","arguments":{"name":"..\\escape"}}}
    , &ctx)).?;
    defer allocator.free(bad_name);
    try std.testing.expect(std.mem.indexOf(u8, bad_name, "isError\":true") != null);
    // space_id 0 equivale a ausente para el puente: -32602.
    const bad_id = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":24,"method":"tools/call","params":{"name":"space_archive","arguments":{"space_id":0}}}
    , &ctx)).?;
    defer allocator.free(bad_id);
    try std.testing.expect(std.mem.indexOf(u8, bad_id, "-32602") != null);
    // Falta name: -32602.
    const missing = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":25,"method":"tools/call","params":{"name":"space_create","arguments":{}}}
    , &ctx)).?;
    defer allocator.free(missing);
    try std.testing.expect(std.mem.indexOf(u8, missing, "-32602") != null);
    // r2 (P2): argumento PRESENTE con tipo incorrecto se rechaza; nunca se
    // silencia a su default. project_id de space_create no es un string.
    const bad_type_proj = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":26,"method":"tools/call","params":{"name":"space_create","arguments":{"project_id":7,"name":"x"}}}
    , &ctx)).?;
    defer allocator.free(bad_type_proj);
    try std.testing.expect(std.mem.indexOf(u8, bad_type_proj, "-32602") != null);
    // F0.7: el diagnóstico es ahora el del validador genérico (misma ruta y tipo).
    try std.testing.expect(std.mem.indexOf(u8, bad_type_proj, "arguments.project_id: se esperaba string") != null);
    // kind presente y no-string igualmente.
    const bad_type_kind = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":27,"method":"tools/call","params":{"name":"space_create","arguments":{"name":"x","kind":5}}}
    , &ctx)).?;
    defer allocator.free(bad_type_kind);
    try std.testing.expect(std.mem.indexOf(u8, bad_type_kind, "-32602") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_type_kind, "arguments.kind: se esperaba string") != null);
    // project_id de spaces_prune presente y no-string también se rechaza; el
    // veto de aprobación humana solo aplica si el argumento es válido.
    const bad_type_prune = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":28,"method":"tools/call","params":{"name":"spaces_prune","arguments":{"project_id":true}}}
    , &ctx)).?;
    defer allocator.free(bad_type_prune);
    try std.testing.expect(std.mem.indexOf(u8, bad_type_prune, "-32602") != null);
    try std.testing.expect(std.mem.indexOf(u8, bad_type_prune, "arguments.project_id: se esperaba string") != null);
    // Alguno válido de prune con project_id ausente: sin error de contrato,
    // la gobernanza de aprobación humana responde (nada tocado).
    const prune_default = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":29,"method":"tools/call","params":{"name":"spaces_prune","arguments":{}}}
    , &ctx)).?;
    defer allocator.free(prune_default);
    try std.testing.expect(std.mem.indexOf(u8, prune_default, "aprobacion humana requerida") != null);
}

fn ckMcp001RejectOptionalTypes(tool: []const u8, field: []const u8) !void {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true;
    for ([_][]const u8{ "null", "true", "7", "1.5", "[]", "{}" }) |bad_type| {
        // El nombre inválido impide efectos de disco incluso al neutralizar
        // la corrección para el rojo: debe ganar el error de TIPO del MCP.
        const name_arg = if (std.mem.eql(u8, tool, "space_create")) ",\"name\":\"..invalid\"" else "";
        const request = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":30,"method":"tools/call","params":{{"name":"{s}","arguments":{{"{s}":{s}{s}}}}}}}
        , .{ tool, field, bad_type, name_arg });
        defer allocator.free(request);
        const response = (try processRequest(allocator, request, &ctx)).?;
        defer allocator.free(response);
        var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer parsed.deinit();
        const failure = parsed.value.object.get("error") orelse {
            std.debug.print("{s}.{s}={s}: {s}\n", .{ tool, field, bad_type, response });
            return error.TestUnexpectedResult;
        };
        try std.testing.expectEqual(@as(i64, -32602), failure.object.get("code").?.integer);
        try std.testing.expect(std.mem.indexOf(u8, failure.object.get("message").?.string, field) != null);
    }
}

test "CK-MCP-001 r2 P2: space_create rechaza project_id presente no string" {
    try ckMcp001RejectOptionalTypes("space_create", "project_id");
}

test "CK-MCP-001 r2 P2: space_create rechaza kind presente no string" {
    try ckMcp001RejectOptionalTypes("space_create", "kind");
}

test "CK-MCP-001 r2 P2: spaces_prune rechaza project_id presente no string" {
    try ckMcp001RejectOptionalTypes("spaces_prune", "project_id");
}

fn ckMcp001RequiresHumanApproval(request: []const u8) !void {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true;
    const response = (try processRequest(allocator, request, &ctx)).?;
    defer allocator.free(response);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    try std.testing.expect(result.get("isError").?.bool);
    const message = result.get("content").?.array.items[0].object.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, message, "aprobacion humana requerida") != null);
}

test "CK-MCP-001 r2 P1: sesion autenticada no aprueba archive" {
    try ckMcp001RequiresHumanApproval(
        \\{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"space_archive","arguments":{"space_id":1}}}
    );
}

test "CK-MCP-001 r2 P1: sesion autenticada no aprueba prune explicito ni default" {
    try ckMcp001RequiresHumanApproval(
        \\{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"spaces_prune","arguments":{"project_id":"ck-mcp-001"}}}
    );
    try ckMcp001RequiresHumanApproval(
        \\{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"spaces_prune","arguments":{}}}
    );
}

test "CK-MCP-001 r2: archive valida contrato antes del veto humano" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true;
    for ([_][]const u8{
        "{}",                 "{\"space_id\":0}",     "{\"space_id\":-1}",                  "{\"space_id\":1.5}",
        "{\"space_id\":1.0}", "{\"space_id\":\"1\"}", "{\"space_id\":true}",                "{\"space_id\":null}",
        "{\"space_id\":[]}",  "{\"space_id\":{}}",    "{\"space_id\":1,\"approved\":true}",
    }) |arguments| {
        const request = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":43,"method":"tools/call","params":{{"name":"space_archive","arguments":{s}}}}}
        , .{arguments});
        defer allocator.free(request);
        const response = (try processRequest(allocator, request, &ctx)).?;
        defer allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "-32602") != null);
    }
}

// ---------------------------------------------------------------------------
// r3 (auditoría el segundo auditor): ruta de aprobación humana REAL para
// space_archive/spaces_prune. La tabla approvals de runtime.db compartida es
// fuente de verdad entre procesos (E5.05/E5.09; c_api.zig:10539 la declara
// autoritativa para shell_command). La resuelve un núcleo SIN superficie MCP
// con da_approval_resolve — exactamente como la cabina (bridge.cpp:2631
// core.approvals.resolve). El servidor MCP registra la solicitud y solo
// ejecuta al reenvío con approval_id cuando el humano la concedió.
// ---------------------------------------------------------------------------

/// Verifica la fila de una solicitud de aprobación de spaces en la BD de
/// archivo compartida (mismo archivo que la cabina abre y resuelve). Devuelve
/// estado de la fila o null si no existe con el prefijo de spaces.
fn ckMcp001R3SpacesApproval(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    approval_id: i64,
) !?struct { resolved: bool, approved: bool } {
    var conn = try core.db.Connection.open(allocator, db_path);
    defer conn.close();
    const stmt = try conn.prepare("SELECT resolved, approved FROM approvals WHERE id = ? AND command_prefix = 'spaces_mcp'");
    defer conn.finalize(stmt);
    try core.db.bindInt(stmt, 1, approval_id);
    if (core.db.c.sqlite3_step(stmt) != core.db.c.SQLITE_ROW) return null;
    const resolved = core.db.c.sqlite3_column_int64(stmt, 0) != 0;
    const approved = core.db.c.sqlite3_column_int64(stmt, 1) != 0;
    return .{ .resolved = resolved, .approved = approved };
}

/// Extrae el texto de content[0] de una tools/call MCP.
fn ckMcp001R3ContentText(
    allocator: std.mem.Allocator,
    response: []const u8,
) !struct { text: []const u8, is_error: bool } {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
    defer parsed.deinit();
    const result = parsed.value.object.get("result").?.object;
    const is_error = result.get("isError").?.bool;
    const text = result.get("content").?.array.items[0].object.get("text").?.string;
    return .{ .text = try allocator.dupe(u8, text), .is_error = is_error };
}

test "CK-MCP-001 r3: fase 1 registra solicitud sin efecto; granted ejecuta; rejected no" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);
    const db_path = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "ck-mcp-001-r3-full.db", .{dir});
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);

    const dir_z = try allocator.dupeZ(u8, dir);
    defer allocator.free(dir_z);
    var previous: [4096]u8 = undefined;
    const previous_len = GetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", &previous, previous.len);
    defer {
        if (previous_len > 0 and previous_len < previous.len) {
            previous[previous_len] = 0;
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", @ptrCast(&previous[0]));
        } else {
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", null);
        }
    }
    try std.testing.expect(SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", dir_z.ptr) != 0);
    const base = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{dir});
    defer allocator.free(base);
    try std.Io.Dir.cwd().createDirPath(io, base);

    var ctx = try ServerCtx.init(allocator, io, db_path_z);
    defer ctx.deinit();
    ctx.authed = true;

    // Space real sobre el workspace temporal (mismos pasos del ciclo r2).
    const created = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":50,"method":"tools/call","params":{"name":"space_create","arguments":{"project_id":"ck-mcp-001","name":"ck-mcp-001-r3","kind":"order"}}}
    , &ctx)).?;
    defer allocator.free(created);
    const created_txt = try ckMcp001R3ContentText(allocator, created);
    defer allocator.free(created_txt.text);
    if (created_txt.is_error) {
        std.debug.print("CK-MCP-001 r3 space_create: {s}\n", .{created_txt.text});
        return error.TestUnexpectedResult;
    }
    var create_json = try std.json.parseFromSlice(std.json.Value, allocator, created_txt.text, .{});
    defer create_json.deinit();
    const space_id = create_json.value.object.get("id").?.integer;
    try std.testing.expect(space_id > 0);

    // Fase 1: sin approval_id → isError, approval_id > 0, NADA archivado.
    const phase1 = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":51,"method":"tools/call","params":{"name":"space_archive","arguments":{"space_id":999999}}}
    , &ctx)).?;
    defer allocator.free(phase1);
    const phase1_txt = try ckMcp001R3ContentText(allocator, phase1);
    defer allocator.free(phase1_txt.text);
    try std.testing.expect(phase1_txt.is_error);
    try std.testing.expect(std.mem.indexOf(u8, phase1_txt.text, "aprobacion humana requerida") != null);
    var phase1_json = try std.json.parseFromSlice(std.json.Value, allocator, phase1_txt.text, .{});
    defer phase1_json.deinit();
    const requested_id = phase1_json.value.object.get("approval_id").?.integer;
    {
        const card = try ckMcp001R3SpacesApproval(allocator, db_path, requested_id);
        try std.testing.expect(card != null);
        try std.testing.expect(!card.?.resolved);
    }
    // El gesto MCP no tocó el motor: la ficha del space sigue activa.
    {
        var list_out: [*:0]u8 = undefined;
        try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_spaces_list_json(ctx.core_handle.?, "ck-mcp-001", &list_out));
        defer core.c_api.da_string_free(list_out);
        var list_json = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.span(list_out), .{});
        defer list_json.deinit();
        try std.testing.expectEqual(@as(usize, 1), list_json.value.array.items.len);
        try std.testing.expect(list_json.value.array.items[0].object.get("archivedAt").? == .null);
    }
    // approvals_list muestra la solicitud pendiente al humano.
    {
        const listing = (try processRequest(allocator,
            \\{"jsonrpc":"2.0","id":52,"method":"tools/call","params":{"name":"approvals_list","arguments":{}}}
        , &ctx)).?;
        defer allocator.free(listing);
        try std.testing.expect(std.mem.indexOf(u8, listing, "spaces_mcp") != null);
        try std.testing.expect(std.mem.indexOf(u8, listing, "archivar el space") != null);
    }
    // RESOLUCIÓN HUMANA CONCEDIDA desde un núcleo sin superficie MCP
    // (la cabina lo hace por core.approvals.resolve → da_approval_resolve).
    {
        var cabin: ?*anyopaque = null;
        try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_core_init(&cabin, db_path_z));
        defer _ = core.c_api.da_core_shutdown(cabin);
        try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_approval_resolve(cabin, requested_id, 1));
    }
    // Fase 2 con la solicitud concedida: EJECUTA contra el motor. El espacio
    // pedido no existe (999999): lo decide el MOTOR; aquí solo se comprueba
    // que la solicitud quedó resuelta-concedida y que el servidor reenvió la
    // llamada (observación r3: da_space_archive sobre un id inexistente
    // devuelve 0, y por eso este caso en concreto no produce isError).
    {
        const r = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":53,"method":"tools/call","params":{{"name":"space_archive","arguments":{{"space_id":999999,"approval_id":{d}}}}}}}
        , .{requested_id});
        defer allocator.free(r);
        const response = (try processRequest(allocator, r, &ctx)).?;
        defer allocator.free(response);
        // La solicitud se ejecutó: quedó resuelta-concedida (el resultado del
        // motor depende de él, no de la verificación local).
        const card = try ckMcp001R3SpacesApproval(allocator, db_path, requested_id);
        try std.testing.expect(card != null);
        try std.testing.expect(card.?.resolved and card.?.approved);
    }
    // Fase 2 real con espacios: solicita, concede y archiva la ficha real.
    {
        const req_b = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":54,"method":"tools/call","params":{{"name":"space_archive","arguments":{{"space_id":{d}}}}}}}
        , .{space_id});
        defer allocator.free(req_b);
        const phase1b = (try processRequest(allocator, req_b, &ctx)).?;
        defer allocator.free(phase1b);
        const txt = try ckMcp001R3ContentText(allocator, phase1b);
        defer allocator.free(txt.text);
        var pj = try std.json.parseFromSlice(std.json.Value, allocator, txt.text, .{});
        defer pj.deinit();
        const granted = pj.value.object.get("approval_id").?.integer;
        var cabin: ?*anyopaque = null;
        try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_core_init(&cabin, db_path_z));
        defer _ = core.c_api.da_core_shutdown(cabin);
        try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_approval_resolve(cabin, granted, 1));
        const r = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":55,"method":"tools/call","params":{{"name":"space_archive","arguments":{{"space_id":{d},"approval_id":{d}}}}}}}
        , .{ space_id, granted });
        defer allocator.free(r);
        const response = (try processRequest(allocator, r, &ctx)).?;
        defer allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "isError\":true") == null);
        try std.testing.expect(std.mem.indexOf(u8, response, "\\\"archived\\\":true") != null);
        // El efecto es real y visible en la ficha del space.
        var list_out2: [*:0]u8 = undefined;
        try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_spaces_list_json(ctx.core_handle.?, "ck-mcp-001", &list_out2));
        defer core.c_api.da_string_free(list_out2);
        var list_json2 = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.span(list_out2), .{});
        defer list_json2.deinit();
        for (list_json2.value.array.items) |space_v| {
            const sid = space_v.object.get("id").?.integer;
            if (sid == space_id) try std.testing.expect(space_v.object.get("archivedAt").? != .null);
        }
    }
}

test "CK-MCP-001 r3: fase 2 rechazada no toca nada y concedida ejecuta (podas)" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);
    const db_path = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "ck-mcp-001-r3-prune.db", .{dir});
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    // da_spaces_prune necesita la raíz del workspace disponible
    // (SpaceRootUnavailable si falta): la redirige al workspace temporal como
    // el ciclo real r2 y se la aplica en ServerCtx.init.
    const dir_z = try allocator.dupeZ(u8, dir);
    defer allocator.free(dir_z);
    var previous: [4096]u8 = undefined;
    const previous_len = GetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", &previous, previous.len);
    defer {
        if (previous_len > 0 and previous_len < previous.len) {
            previous[previous_len] = 0;
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", @ptrCast(&previous[0]));
        } else {
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", null);
        }
    }
    try std.testing.expect(SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", dir_z.ptr) != 0);
    const base = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{dir});
    defer allocator.free(base);
    try std.Io.Dir.cwd().createDirPath(io, base);
    var ctx = try ServerCtx.init(allocator, io, db_path_z);
    defer ctx.deinit();
    ctx.authed = true;

    // Fase 1: solicita poda de un proyecto sin filas aún.
    const phase1 = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":60,"method":"tools/call","params":{"name":"spaces_prune","arguments":{"project_id":"ck-mcp-001-r3"}}}
    , &ctx)).?;
    defer allocator.free(phase1);
    const phase1_txt = try ckMcp001R3ContentText(allocator, phase1);
    defer allocator.free(phase1_txt.text);
    try std.testing.expect(phase1_txt.is_error);
    try std.testing.expect(std.mem.indexOf(u8, phase1_txt.text, "aprobacion humana requerida") != null);
    var phase1_json = try std.json.parseFromSlice(std.json.Value, allocator, phase1_txt.text, .{});
    defer phase1_json.deinit();
    const phase1_id = phase1_json.value.object.get("approval_id").?.integer;
    try std.testing.expect(phase1_id > 0);
    // La fila pendiente existe en la BD compartida.
    {
        const card = try ckMcp001R3SpacesApproval(allocator, db_path, phase1_id);
        try std.testing.expect(card != null);
        try std.testing.expect(!card.?.resolved);
    }
    // Fase 2 con la solicitud pendiente: sigue sin tocar el motor.
    {
        const r = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":61,"method":"tools/call","params":{{"name":"spaces_prune","arguments":{{"project_id":"ck-mcp-001-r3","approval_id":{d}}}}}}}
        , .{phase1_id});
        defer allocator.free(r);
        const response = (try processRequest(allocator, r, &ctx)).?;
        defer allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "isError\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "aprobacion humana requerida") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "\"pruned\"") == null);
    }
    // RESOLUCIÓN HUMANA DENEGADA desde un núcleo sin superficie MCP
    // (la cabina lo hace por core.approvals.resolve → da_approval_resolve).
    {
        var cabin: ?*anyopaque = null;
        try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_core_init(&cabin, db_path_z));
        defer _ = core.c_api.da_core_shutdown(cabin);
        try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_approval_resolve(cabin, phase1_id, 0));
    }
    {
        const card = try ckMcp001R3SpacesApproval(allocator, db_path, phase1_id);
        try std.testing.expect(card != null);
        try std.testing.expect(card.?.resolved);
        try std.testing.expect(!card.?.approved);
    }
    // Fase 2 tras la negativa: error claro, nada podado (fila igual viva).
    {
        const r = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":62,"method":"tools/call","params":{{"name":"spaces_prune","arguments":{{"project_id":"ck-mcp-001-r3","approval_id":{d}}}}}}}
        , .{phase1_id});
        defer allocator.free(r);
        const response = (try processRequest(allocator, r, &ctx)).?;
        defer allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "isError\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "aprobacion humana rechazada") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "\"pruned\"") == null);
    }
    // Nueva solicitud (idempotencia distinta: la denegada ya está resuelta) y
    // RESOLUCIÓN HUMANA CONCEDIDA → ahora sí ejecuta con {"pruned":N}.
    var conceded_id: i64 = 0;
    {
        const phase1b = (try processRequest(allocator,
            \\{"jsonrpc":"2.0","id":63,"method":"tools/call","params":{"name":"spaces_prune","arguments":{"project_id":"ck-mcp-001-r3"}}}
        , &ctx)).?;
        defer allocator.free(phase1b);
        const txt = try ckMcp001R3ContentText(allocator, phase1b);
        defer allocator.free(txt.text);
        var pj = try std.json.parseFromSlice(std.json.Value, allocator, txt.text, .{});
        defer pj.deinit();
        conceded_id = pj.value.object.get("approval_id").?.integer;
        try std.testing.expect(conceded_id != phase1_id);
        var cabin: ?*anyopaque = null;
        try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_core_init(&cabin, db_path_z));
        defer _ = core.c_api.da_core_shutdown(cabin);
        try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_approval_resolve(cabin, conceded_id, 1));
    }
    {
        const r = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":64,"method":"tools/call","params":{{"name":"spaces_prune","arguments":{{"project_id":"ck-mcp-001-r3","approval_id":{d}}}}}}}
        , .{conceded_id});
        defer allocator.free(r);
        const response = (try processRequest(allocator, r, &ctx)).?;
        defer allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "isError\":true") == null);
        var tj = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer tj.deinit();
        const text = tj.value.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
        var payload = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
        defer payload.deinit();
        try std.testing.expect(payload.value.object.get("pruned").?.integer >= 0);
        // La fila quedó resuelta-concedida y desaparece de los pendientes.
        const card = try ckMcp001R3SpacesApproval(allocator, db_path, conceded_id);
        try std.testing.expect(card != null);
        try std.testing.expect(card.?.resolved and card.?.approved);
    }
}

test "CK-MCP-001 r3: approval_id ajeno a la acción exacta no valida nada" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true;
    // Solicitud para el proyecto "alpha".
    const phase1 = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":70,"method":"tools/call","params":{"name":"spaces_prune","arguments":{"project_id":"alpha"}}}
    , &ctx)).?;
    defer allocator.free(phase1);
    const txt = try ckMcp001R3ContentText(allocator, phase1);
    defer allocator.free(txt.text);
    var pj = try std.json.parseFromSlice(std.json.Value, allocator, txt.text, .{});
    defer pj.deinit();
    const aid = pj.value.object.get("approval_id").?.integer;
    // Reenvío con OTRO proyecto: la verificación exacta lo rechaza.
    const r = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":71,"method":"tools/call","params":{{"name":"spaces_prune","arguments":{{"project_id":"beta","approval_id":{d}}}}}}}
    , .{aid});
    defer allocator.free(r);
    const response = (try processRequest(allocator, r, &ctx)).?;
    defer allocator.free(response);
    try std.testing.expect(std.mem.indexOf(u8, response, "isError\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "no corresponde") != null);
    try std.testing.expect(std.mem.indexOf(u8, response, "\"pruned\"") == null);
    // approval_id presente con tipo incorrecto: -32602 estricto.
    const r2 = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":72,"method":"tools/call","params":{{"name":"spaces_prune","arguments":{{"project_id":"beta","approval_id":"{d}"}}}}}}
    , .{aid});
    defer allocator.free(r2);
    const response2 = (try processRequest(allocator, r2, &ctx)).?;
    defer allocator.free(response2);
    try std.testing.expect(std.mem.indexOf(u8, response2, "-32602") != null);
    // approval_id de un id inexistente: error claro, sin ejecutar.
    const response3 = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":73,"method":"tools/call","params":{"name":"spaces_prune","arguments":{"project_id":"beta","approval_id":999999}}}
    , &ctx)).?;
    defer allocator.free(response3);
    try std.testing.expect(std.mem.indexOf(u8, response3, "isError\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, response3, "no existe") != null);
    try std.testing.expect(std.mem.indexOf(u8, response3, "\"pruned\"") == null);
}

// ---------------------------------------------------------------------------
// r4 (auditoría el segundo auditor, lote G):
//  - P1: la bandeja de la cabina (da_approval_pending_json) debe mostrar las
//    solicitudes spaces_mcp, y la decisión humana debe llegar por esa misma
//    ruta (da_approval_resolve, igual que core.approvals.resolve del puente).
//  - P2: la aprobación es de un solo uso y spaces_prune queda acotado al
//    conjunto de spaces archivados que el humano vio al concederla.
// ---------------------------------------------------------------------------

fn ckMcp001R4CreateSpace(
    ctx: *ServerCtx,
    allocator: std.mem.Allocator,
    project_id: []const u8,
    name: []const u8,
) !i64 {
    const request = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":80,"method":"tools/call","params":{{"name":"space_create","arguments":{{"project_id":"{s}","name":"{s}"}}}}}}
    , .{ project_id, name });
    defer allocator.free(request);
    const response = (try processRequest(allocator, request, ctx)).?;
    defer allocator.free(response);
    const txt = try ckMcp001R3ContentText(allocator, response);
    defer allocator.free(txt.text);
    try std.testing.expect(!txt.is_error);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, txt.text, .{});
    defer parsed.deinit();
    return parsed.value.object.get("id").?.integer;
}

fn ckMcp001R4RequestApproval(
    ctx: *ServerCtx,
    allocator: std.mem.Allocator,
    request: []const u8,
) !i64 {
    const response = (try processRequest(allocator, request, ctx)).?;
    defer allocator.free(response);
    const txt = try ckMcp001R3ContentText(allocator, response);
    defer allocator.free(txt.text);
    try std.testing.expect(txt.is_error);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, txt.text, .{});
    defer parsed.deinit();
    return parsed.value.object.get("approval_id").?.integer;
}

/// ¿La bandeja que consume la cabina (da_approval_pending_json) incluye esta
/// solicitud con el prefijo spaces_mcp? Es el canal real del Monitor.
fn ckMcp001R4PendingContains(
    allocator: std.mem.Allocator,
    cabin: ?*anyopaque,
    approval_id: i64,
) !bool {
    var out: [*:0]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_approval_pending_json(cabin, &out));
    defer core.c_api.da_string_free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.span(out), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    for (parsed.value.array.items) |row| {
        if (row.object.get("id").?.integer == approval_id) {
            try std.testing.expectEqualStrings("spaces_mcp", row.object.get("command_prefix").?.string);
            return true;
        }
    }
    return false;
}

fn ckMcp001R4SpaceCount(
    allocator: std.mem.Allocator,
    db_path: []const u8,
    project_id: []const u8,
) !i64 {
    var conn = try core.db.Connection.open(allocator, db_path);
    defer conn.close();
    const stmt = try conn.prepare("SELECT COUNT(*) FROM spaces WHERE project_id = ?");
    defer conn.finalize(stmt);
    try core.db.bindText(stmt, 1, project_id);
    if (core.db.c.sqlite3_step(stmt) != core.db.c.SQLITE_ROW) return -1;
    return core.db.c.sqlite3_column_int64(stmt, 0);
}

fn ckMcp001R4ListActiveCount(
    allocator: std.mem.Allocator,
    handle: ?*anyopaque,
    project_id: []const u8,
) !usize {
    const project_z = try allocator.dupeZ(u8, project_id);
    defer allocator.free(project_z);
    var out: [*:0]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_spaces_list_json(handle, project_z, &out));
    defer core.c_api.da_string_free(out);
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, std.mem.span(out), .{});
    defer parsed.deinit();
    return parsed.value.array.items.len;
}

test "CK-MCP-001 r4 P1: spaces_mcp aparece en la bandeja de la cabina y se resuelve por esa ruta" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);
    const db_path = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "ck-mcp-001-r4-p1.db", .{dir});
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    const dir_z = try allocator.dupeZ(u8, dir);
    defer allocator.free(dir_z);
    var previous: [4096]u8 = undefined;
    const previous_len = GetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", &previous, previous.len);
    defer {
        if (previous_len > 0 and previous_len < previous.len) {
            previous[previous_len] = 0;
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", @ptrCast(&previous[0]));
        } else {
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", null);
        }
    }
    try std.testing.expect(SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", dir_z.ptr) != 0);
    const base = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{dir});
    defer allocator.free(base);
    try std.Io.Dir.cwd().createDirPath(io, base);

    var ctx = try ServerCtx.init(allocator, io, db_path_z);
    defer ctx.deinit();
    ctx.authed = true;

    const project = "ck-mcp-001-r4-p1";
    const s1 = try ckMcp001R4CreateSpace(&ctx, allocator, project, "r4p1-a");
    const s2 = try ckMcp001R4CreateSpace(&ctx, allocator, project, "r4p1-b");

    // Solicitud 1 (archivar s1). Sin aprobación: pendiente, nada ejecutado.
    const req1 = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":81,"method":"tools/call","params":{{"name":"space_archive","arguments":{{"space_id":{d}}}}}}}
    , .{s1});
    defer allocator.free(req1);
    const aid1 = try ckMcp001R4RequestApproval(&ctx, allocator, req1);

    var cabin: ?*anyopaque = null;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_core_init(&cabin, db_path_z));
    defer _ = core.c_api.da_core_shutdown(cabin);

    // (a) La lista que consume la cabina la muestra.
    try std.testing.expect(try ckMcp001R4PendingContains(allocator, cabin, aid1));
    // (b) El humano la concede por esa ruta (core.approvals.resolve).
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_approval_resolve(cabin, aid1, 1));
    try std.testing.expect(!(try ckMcp001R4PendingContains(allocator, cabin, aid1)));

    // Fase 2 con la concesión: archiva s1 de verdad.
    {
        const r = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":82,"method":"tools/call","params":{{"name":"space_archive","arguments":{{"space_id":{d},"approval_id":{d}}}}}}}
        , .{ s1, aid1 });
        defer allocator.free(r);
        const response = (try processRequest(allocator, r, &ctx)).?;
        defer allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "isError\":true") == null);
        try std.testing.expect(std.mem.indexOf(u8, response, "\\\"archived\\\":true") != null);
    }
    try std.testing.expectEqual(@as(usize, 1), try ckMcp001R4ListActiveCount(allocator, ctx.core_handle, project));

    // Solicitud 2 (archivar s2): el humano la RECHAZA por la misma ruta.
    const req2 = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":83,"method":"tools/call","params":{{"name":"space_archive","arguments":{{"space_id":{d}}}}}}}
    , .{s2});
    defer allocator.free(req2);
    const aid2 = try ckMcp001R4RequestApproval(&ctx, allocator, req2);
    try std.testing.expect(try ckMcp001R4PendingContains(allocator, cabin, aid2));
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_approval_resolve(cabin, aid2, 0));
    try std.testing.expect(!(try ckMcp001R4PendingContains(allocator, cabin, aid2)));
    {
        const r = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":84,"method":"tools/call","params":{{"name":"space_archive","arguments":{{"space_id":{d},"approval_id":{d}}}}}}}
        , .{ s2, aid2 });
        defer allocator.free(r);
        const response = (try processRequest(allocator, r, &ctx)).?;
        defer allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "isError\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "rechazada") != null);
    }
    // s2 sigue activo: el rechazo no tocó el motor.
    try std.testing.expectEqual(@as(usize, 1), try ckMcp001R4ListActiveCount(allocator, ctx.core_handle, project));
}

test "CK-MCP-001 r4 P2: approval_id de spaces es de un solo uso" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);
    const db_path = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "ck-mcp-001-r4-uso.db", .{dir});
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    const dir_z = try allocator.dupeZ(u8, dir);
    defer allocator.free(dir_z);
    var previous: [4096]u8 = undefined;
    const previous_len = GetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", &previous, previous.len);
    defer {
        if (previous_len > 0 and previous_len < previous.len) {
            previous[previous_len] = 0;
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", @ptrCast(&previous[0]));
        } else {
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", null);
        }
    }
    try std.testing.expect(SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", dir_z.ptr) != 0);
    const base = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{dir});
    defer allocator.free(base);
    try std.Io.Dir.cwd().createDirPath(io, base);

    var ctx = try ServerCtx.init(allocator, io, db_path_z);
    defer ctx.deinit();
    ctx.authed = true;

    const project = "ck-mcp-001-r4-uso";
    const s1 = try ckMcp001R4CreateSpace(&ctx, allocator, project, "r4uso-a");
    const req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":85,"method":"tools/call","params":{{"name":"space_archive","arguments":{{"space_id":{d}}}}}}}
    , .{s1});
    defer allocator.free(req);
    const aid = try ckMcp001R4RequestApproval(&ctx, allocator, req);

    var cabin: ?*anyopaque = null;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_core_init(&cabin, db_path_z));
    defer _ = core.c_api.da_core_shutdown(cabin);
    try std.testing.expect(try ckMcp001R4PendingContains(allocator, cabin, aid));
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_approval_resolve(cabin, aid, 1));

    // Primer uso: ejecuta.
    {
        const r = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":86,"method":"tools/call","params":{{"name":"space_archive","arguments":{{"space_id":{d},"approval_id":{d}}}}}}}
        , .{ s1, aid });
        defer allocator.free(r);
        const response = (try processRequest(allocator, r, &ctx)).?;
        defer allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "isError\":true") == null);
        try std.testing.expect(std.mem.indexOf(u8, response, "\\\"archived\\\":true") != null);
    }
    // La fila quedó consumida (resolved = 2), no reutilizable.
    {
        const card = try ckMcp001R3SpacesApproval(allocator, db_path, aid);
        try std.testing.expect(card != null);
        var conn = try core.db.Connection.open(allocator, db_path);
        defer conn.close();
        const stmt = try conn.prepare("SELECT resolved FROM approvals WHERE id = ?");
        defer conn.finalize(stmt);
        try core.db.bindInt(stmt, 1, aid);
        try std.testing.expectEqual(core.db.c.SQLITE_ROW, core.db.c.sqlite3_step(stmt));
        try std.testing.expectEqual(@as(i64, 2), core.db.c.sqlite3_column_int64(stmt, 0));
    }

    // Segundo uso del MISMO approval_id: error claro y cero efecto.
    {
        // Antes de reutilizar se crea otro space activo: si el reenvío
        // ejecutase, la respuesta no sería de error.
        const s2 = try ckMcp001R4CreateSpace(&ctx, allocator, project, "r4uso-b");
        const r = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":87,"method":"tools/call","params":{{"name":"space_archive","arguments":{{"space_id":{d},"approval_id":{d}}}}}}}
        , .{ s2, aid });
        defer allocator.free(r);
        const response = (try processRequest(allocator, r, &ctx)).?;
        defer allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "isError\":true") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "consumida") != null);
        try std.testing.expect(std.mem.indexOf(u8, response, "archived") == null);
        // s2 sigue activo: no hubo efecto.
        try std.testing.expectEqual(@as(usize, 1), try ckMcp001R4ListActiveCount(allocator, ctx.core_handle, project));
    }
}

test "CK-MCP-001 r4 P2: spaces_prune acotado a los spaces vistos al aprobar" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);
    const db_path = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "ck-mcp-001-r4-poda.db", .{dir});
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    const dir_z = try allocator.dupeZ(u8, dir);
    defer allocator.free(dir_z);
    var previous: [4096]u8 = undefined;
    const previous_len = GetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", &previous, previous.len);
    defer {
        if (previous_len > 0 and previous_len < previous.len) {
            previous[previous_len] = 0;
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", @ptrCast(&previous[0]));
        } else {
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", null);
        }
    }
    try std.testing.expect(SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", dir_z.ptr) != 0);
    const base = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{dir});
    defer allocator.free(base);
    try std.Io.Dir.cwd().createDirPath(io, base);

    var ctx = try ServerCtx.init(allocator, io, db_path_z);
    defer ctx.deinit();
    ctx.authed = true;

    var cabin: ?*anyopaque = null;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_core_init(&cabin, db_path_z));
    defer _ = core.c_api.da_core_shutdown(cabin);

    // Proyecto A: dos archivados vistos por el humano; un tercero aparece
    // DESPUÉS de la concesión. r5: se podan SOLO los dos aprobados; el
    // tercero (fuera del snapshot) sigue intacto.
    const proj_a = "ck-mcp-001-r4-poda-a";
    const a1 = try ckMcp001R4CreateSpace(&ctx, allocator, proj_a, "r4poda-a1");
    const a2 = try ckMcp001R4CreateSpace(&ctx, allocator, proj_a, "r4poda-a2");
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_space_archive(ctx.core_handle.?, a1));
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_space_archive(ctx.core_handle.?, a2));
    const req_a = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":88,"method":"tools/call","params":{{"name":"spaces_prune","arguments":{{"project_id":"{s}"}}}}}}
    , .{proj_a});
    defer allocator.free(req_a);
    const aid_a = try ckMcp001R4RequestApproval(&ctx, allocator, req_a);
    try std.testing.expect(try ckMcp001R4PendingContains(allocator, cabin, aid_a));
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_approval_resolve(cabin, aid_a, 1));
    // Archivado posterior (no estaba en el conjunto mostrado).
    const a3 = try ckMcp001R4CreateSpace(&ctx, allocator, proj_a, "r4poda-a3");
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_space_archive(ctx.core_handle.?, a3));
    try std.testing.expectEqual(@as(i64, 3), try ckMcp001R4SpaceCount(allocator, db_path, proj_a));
    {
        const r = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":89,"method":"tools/call","params":{{"name":"spaces_prune","arguments":{{"project_id":"{s}","approval_id":{d}}}}}}}
        , .{ proj_a, aid_a });
        defer allocator.free(r);
        const response = (try processRequest(allocator, r, &ctx)).?;
        defer allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "isError\":true") == null);
        var tj = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer tj.deinit();
        const text = tj.value.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
        var payload = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
        defer payload.deinit();
        try std.testing.expectEqual(@as(i64, 2), payload.value.object.get("pruned").?.integer);
    }
    // Solo a1/a2 podados: a3 (archivado despues) sigue en la tabla.
    try std.testing.expectEqual(@as(i64, 1), try ckMcp001R4SpaceCount(allocator, db_path, proj_a));
    {
        var conn = try core.db.Connection.open(allocator, db_path);
        defer conn.close();
        const stmt = try conn.prepare("SELECT id FROM spaces WHERE project_id = ?");
        defer conn.finalize(stmt);
        try core.db.bindText(stmt, 1, proj_a);
        try std.testing.expectEqual(core.db.c.SQLITE_ROW, core.db.c.sqlite3_step(stmt));
        try std.testing.expectEqual(a3, core.db.c.sqlite3_column_int64(stmt, 0));
    }

    // Proyecto B: sin cambios posteriores, la poda aprobada se ejecuta.
    const proj_b = "ck-mcp-001-r4-poda-b";
    const b1 = try ckMcp001R4CreateSpace(&ctx, allocator, proj_b, "r4poda-b1");
    const b2 = try ckMcp001R4CreateSpace(&ctx, allocator, proj_b, "r4poda-b2");
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_space_archive(ctx.core_handle.?, b1));
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_space_archive(ctx.core_handle.?, b2));
    const req_b = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":90,"method":"tools/call","params":{{"name":"spaces_prune","arguments":{{"project_id":"{s}"}}}}}}
    , .{proj_b});
    defer allocator.free(req_b);
    const aid_b = try ckMcp001R4RequestApproval(&ctx, allocator, req_b);
    try std.testing.expect(try ckMcp001R4PendingContains(allocator, cabin, aid_b));
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_approval_resolve(cabin, aid_b, 1));
    {
        const r = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":91,"method":"tools/call","params":{{"name":"spaces_prune","arguments":{{"project_id":"{s}","approval_id":{d}}}}}}}
        , .{ proj_b, aid_b });
        defer allocator.free(r);
        const response = (try processRequest(allocator, r, &ctx)).?;
        defer allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "isError\":true") == null);
        var tj = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer tj.deinit();
        const text = tj.value.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
        var payload = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
        defer payload.deinit();
        try std.testing.expectEqual(@as(i64, 2), payload.value.object.get("pruned").?.integer);
    }
    try std.testing.expectEqual(@as(i64, 0), try ckMcp001R4SpaceCount(allocator, db_path, proj_b));
}

// ---------------------------------------------------------------------------
// r5 (auditoria el segundo auditor, lote H): la poda debe recorrer SOLO los ids
// del snapshot aprobado. Archivar otro space antes (o durante) la poda no
// puede borrarlo: el motor ya no decide por el conjunto ACTUAL.
// ---------------------------------------------------------------------------

test "CK-MCP-001 r5: la poda toca solo los ids aprobados aunque se archive otro despues" {
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);
    const db_path = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "ck-mcp-001-r5-poda.db", .{dir});
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    const dir_z = try allocator.dupeZ(u8, dir);
    defer allocator.free(dir_z);
    var previous: [4096]u8 = undefined;
    const previous_len = GetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", &previous, previous.len);
    defer {
        if (previous_len > 0 and previous_len < previous.len) {
            previous[previous_len] = 0;
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", @ptrCast(&previous[0]));
        } else {
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", null);
        }
    }
    try std.testing.expect(SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", dir_z.ptr) != 0);
    const base = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{dir});
    defer allocator.free(base);
    try std.Io.Dir.cwd().createDirPath(io, base);

    var ctx = try ServerCtx.init(allocator, io, db_path_z);
    defer ctx.deinit();
    ctx.authed = true;

    var cabin: ?*anyopaque = null;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_core_init(&cabin, db_path_z));
    defer _ = core.c_api.da_core_shutdown(cabin);

    const project = "ck-mcp-001-r5-poda";
    const a = try ckMcp001R4CreateSpace(&ctx, allocator, project, "r5poda-a");
    const b = try ckMcp001R4CreateSpace(&ctx, allocator, project, "r5poda-b");
    const c = try ckMcp001R4CreateSpace(&ctx, allocator, project, "r5poda-c");
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_space_archive(ctx.core_handle.?, a));

    // Snapshot aprobado: {A}. B se archiva DESPUES de la aprobacion, antes de
    // la fase 2 (lo que en r4 respondia "stale" y no podaba nada).
    const req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":92,"method":"tools/call","params":{{"name":"spaces_prune","arguments":{{"project_id":"{s}"}}}}}}
    , .{project});
    defer allocator.free(req);
    const aid = try ckMcp001R4RequestApproval(&ctx, allocator, req);
    try std.testing.expect(try ckMcp001R4PendingContains(allocator, cabin, aid));
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_approval_resolve(cabin, aid, 1));
    // B y C se archivan DESPUES de la aprobacion, antes de la fase 2. No
    // estaban en el snapshot, asi que el motor no puede tocarlos aunque en el
    // momento de podar esten archivados. (r6: ya no hay gancho dentro de la
    // poda; la garantia la da la lista cerrada de ids que recibe el motor.)
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_space_archive(ctx.core_handle.?, b));
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_space_archive(ctx.core_handle.?, c));

    {
        const r = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":93,"method":"tools/call","params":{{"name":"spaces_prune","arguments":{{"project_id":"{s}","approval_id":{d}}}}}}}
        , .{ project, aid });
        defer allocator.free(r);
        const response = (try processRequest(allocator, r, &ctx)).?;
        defer allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "isError\":true") == null);
        var tj = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer tj.deinit();
        const text = tj.value.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
        var payload = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
        defer payload.deinit();
        try std.testing.expectEqual(@as(i64, 1), payload.value.object.get("pruned").?.integer);
    }

    // A (aprobado) se podo; B y C (fuera del snapshot) siguen en la tabla.
    try std.testing.expectEqual(@as(i64, 2), try ckMcp001R4SpaceCount(allocator, db_path, project));
    {
        var conn = try core.db.Connection.open(allocator, db_path);
        defer conn.close();
        const stmt = try conn.prepare("SELECT id FROM spaces WHERE project_id = ? ORDER BY id ASC");
        defer conn.finalize(stmt);
        try core.db.bindText(stmt, 1, project);
        const keep = [_]i64{ b, c };
        var i: usize = 0;
        while (core.db.c.sqlite3_step(stmt) == core.db.c.SQLITE_ROW) : (i += 1) {
            try std.testing.expect(i < keep.len);
            try std.testing.expectEqual(keep[i], core.db.c.sqlite3_column_int64(stmt, 0));
        }
        try std.testing.expectEqual(keep.len, i);
    }
}

test "CK-MCP-001 r6: la poda aprobada retira worktree y rama del space" {
    // r6 (auditoria el segundo auditor, lote I): antes la fase 2 borraba la fila
    // con un DELETE directo y el worktree/rama quedaban en disco. Ahora llama
    // a da_spaces_prune_ids, que hace la limpieza por space del motor.
    const allocator = std.testing.allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", allocator);
    defer allocator.free(dir);
    const db_path = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "ck-mcp-001-r6-poda.db", .{dir});
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);
    const dir_z = try allocator.dupeZ(u8, dir);
    defer allocator.free(dir_z);
    var previous: [4096]u8 = undefined;
    const previous_len = GetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", &previous, previous.len);
    defer {
        if (previous_len > 0 and previous_len < previous.len) {
            previous[previous_len] = 0;
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", @ptrCast(&previous[0]));
        } else {
            _ = SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", null);
        }
    }
    try std.testing.expect(SetEnvironmentVariableA("DEVAGENTS_WORKSPACE_ROOT", dir_z.ptr) != 0);

    // Repo git real: el space tendra worktree y rama de verdad.
    var init = try core.headless_adapter.defaultCapture(allocator, &.{ "git", "init", dir }, null);
    defer init.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), init.exit_code);
    var commit = try core.headless_adapter.defaultCapture(allocator, &.{
        "git",                  "-c",                 "user.name=CK-MCP-001",
        "-c",                   "user.email=ck@test", "-c",
        "commit.gpgsign=false", "commit",             "--allow-empty",
        "-m",                   "fixture",
    }, dir);
    defer commit.deinit(allocator);
    try std.testing.expectEqual(@as(u32, 0), commit.exit_code);

    const base = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{dir});
    defer allocator.free(base);
    var ctx = try ServerCtx.init(allocator, io, db_path_z);
    defer ctx.deinit();
    ctx.authed = true;

    var cabin: ?*anyopaque = null;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_core_init(&cabin, db_path_z));
    defer _ = core.c_api.da_core_shutdown(cabin);

    const project = "ck-mcp-001-r6-poda";
    const space_id = try ckMcp001R4CreateSpace(&ctx, allocator, project, "r6poda-a");
    const space_path = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ ".devagents" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "r6poda-a", .{base});
    defer allocator.free(space_path);
    try std.Io.Dir.cwd().access(io, space_path, .{});

    // Se marca archivado sin archiveSpace para que el worktree siga en disco:
    // es el estado que el DELETE directo anterior dejaba intacto.
    {
        var conn = try core.db.Connection.open(allocator, db_path);
        defer conn.close();
        const stmt = try conn.prepare("UPDATE spaces SET archived_at = 1 WHERE id = ?");
        defer conn.finalize(stmt);
        try core.db.bindInt(stmt, 1, space_id);
        try std.testing.expectEqual(core.db.c.SQLITE_DONE, core.db.c.sqlite3_step(stmt));
    }

    const req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":94,"method":"tools/call","params":{{"name":"spaces_prune","arguments":{{"project_id":"{s}"}}}}}}
    , .{project});
    defer allocator.free(req);
    const aid = try ckMcp001R4RequestApproval(&ctx, allocator, req);
    try std.testing.expect(try ckMcp001R4PendingContains(allocator, cabin, aid));
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_approval_resolve(cabin, aid, 1));

    {
        const r = try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":95,"method":"tools/call","params":{{"name":"spaces_prune","arguments":{{"project_id":"{s}","approval_id":{d}}}}}}}
        , .{ project, aid });
        defer allocator.free(r);
        const response = (try processRequest(allocator, r, &ctx)).?;
        defer allocator.free(response);
        try std.testing.expect(std.mem.indexOf(u8, response, "isError\":true") == null);
        var tj = try std.json.parseFromSlice(std.json.Value, allocator, response, .{});
        defer tj.deinit();
        const text = tj.value.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
        var payload = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
        defer payload.deinit();
        try std.testing.expectEqual(@as(i64, 1), payload.value.object.get("pruned").?.integer);
    }

    // Worktree retirado del disco y rama borrada: lo que el DELETE directo no
    // hacia.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, space_path, .{}));
    var branches = try core.headless_adapter.defaultCapture(allocator, &.{ "git", "branch", "--list", "devagents/r6poda-a" }, dir);
    defer branches.deinit(allocator);
    try std.testing.expectEqualStrings("", branches.stdout);
    try std.testing.expectEqual(@as(i64, 0), try ckMcp001R4SpaceCount(allocator, db_path, project));
}

// author is deliberately absent from the client schema.
const ORDER_PROGRESS_FIELDS = [_]SchemaField{
    .{ .name = "action", .typ = "string", .req = true, .desc = "get/set", .enum_vals = &.{ "get", "set" } },
    .{ .name = "order_id", .typ = "integer", .req = true, .desc = "ID positivo de la orden" },
    .{ .name = "expected_seq", .typ = "integer", .req = false, .desc = "Obligatorio para set; seq leido (0 sin reporte)" },
    .{ .name = "state", .typ = "string", .req = false, .desc = "Obligatorio para set", .enum_vals = &.{ "todo", "in_progress", "in_review", "done" } },
    .{ .name = "note", .typ = "string", .req = false, .desc = "Obligatorio para set; hasta 2048 bytes UTF-8" },
};

fn progressMcpCall(allocator: std.mem.Allocator, ctx: *ServerCtx, arguments: []const u8) ![]u8 {
    const request = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{{"name":"order_progress","arguments":{s}}}}}
    , .{arguments});
    defer allocator.free(request);
    return (try processRequest(allocator, request, ctx)) orelse error.MissingResponse;
}

test "CK-COMP-015 MCP set requires expected_seq and rejects author spoofing and malformed types" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true;
    for ([_][]const u8{
        "{\"action\":\"set\",\"order_id\":1,\"state\":\"todo\",\"note\":\"\"}",
        "{\"action\":\"set\",\"order_id\":1,\"expected_seq\":0,\"state\":\"todo\",\"note\":\"\",\"author\":\"human\"}",
        "{\"action\":\"set\",\"order_id\":1,\"expected_seq\":0.5,\"state\":\"todo\",\"note\":\"\"}",
        "{\"action\":\"set\",\"order_id\":1,\"expected_seq\":\"0\",\"state\":\"todo\",\"note\":\"\"}",
        "{\"action\":\"set\",\"order_id\":1,\"expected_seq\":-1,\"state\":\"todo\",\"note\":\"\"}",
        "{\"action\":\"get\",\"order_id\":1.5}",
        "{\"action\":\"get\",\"order_id\":-1}",
        "{\"action\":\"get\",\"order_id\":1,\"note\":\"ignored?\"}",
        "{\"action\":\"other\",\"order_id\":1}",
    }) |args| {
        const response = try progressMcpCall(a, &ctx, args);
        defer a.free(response);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, response, .{});
        defer parsed.deinit();
        try std.testing.expectEqual(@as(i64, -32602), parsed.value.object.get("error").?.object.get("code").?.integer);
    }
    ctx.authed = false;
    const denied = try progressMcpCall(a, &ctx, "{\"action\":\"set\",\"order_id\":1,\"expected_seq\":0,\"state\":\"todo\",\"note\":\"\"}");
    defer a.free(denied);
    try std.testing.expect(std.mem.indexOf(u8, denied, "autenticacion requerida") != null);
    const get = try progressMcpCall(a, &ctx, "{\"action\":\"get\",\"order_id\":1}");
    defer a.free(get);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, get, .{});
    defer parsed.deinit();
    try std.testing.expect(!parsed.value.object.get("result").?.object.get("isError").?.bool);
}

test "CK-COMP-015 MCP roundtrip uses agent and rejects stale reports without mutation" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    ctx.authed = true;
    var order: ?*anyopaque = null;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_order_submit(ctx.core_handle, "crear avance", "ck-comp015", null, &order));
    const oid: i64 = @intCast(@intFromPtr(order.?));
    const args = try std.fmt.allocPrint(a,
        \\{{"action":"set","order_id":{d},"expected_seq":0,"state":"in_progress","note":"agente á"}}
    , .{oid});
    defer a.free(args);
    {
        const response = try progressMcpCall(a, &ctx, args);
        defer a.free(response);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, response, .{});
        defer parsed.deinit();
        try std.testing.expect(!parsed.value.object.get("result").?.object.get("isError").?.bool);
        const payload = try std.json.parseFromSlice(std.json.Value, a, parsed.value.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string, .{});
        defer payload.deinit();
        try std.testing.expectEqual(@as(i64, 1), payload.value.object.get("seq").?.integer);
    }
    {
        const response = try progressMcpCall(a, &ctx, args);
        defer a.free(response);
        const parsed = try std.json.parseFromSlice(std.json.Value, a, response, .{});
        defer parsed.deinit();
        const result = parsed.value.object.get("result").?.object;
        try std.testing.expect(result.get("isError").?.bool);
        const payload = try std.json.parseFromSlice(std.json.Value, a, result.get("content").?.array.items[0].object.get("text").?.string, .{});
        defer payload.deinit();
        try std.testing.expectEqualStrings("StaleProgress", payload.value.object.get("error").?.string);
        try std.testing.expectEqual(@as(i64, 1), payload.value.object.get("seq").?.integer);
    }
    const get_args = try std.fmt.allocPrint(a, "{{\"action\":\"get\",\"order_id\":{d}}}", .{oid});
    defer a.free(get_args);
    const response = try progressMcpCall(a, &ctx, get_args);
    defer a.free(response);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, response, .{});
    defer parsed.deinit();
    const payload = try std.json.parseFromSlice(std.json.Value, a, parsed.value.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string, .{});
    defer payload.deinit();
    try std.testing.expectEqualStrings("agent", payload.value.object.get("author").?.string);
    try std.testing.expectEqualStrings("agente á", payload.value.object.get("note").?.string);
    try std.testing.expectEqualStrings("in_progress", payload.value.object.get("state").?.string);
    try std.testing.expectEqual(@as(i64, 1), payload.value.object.get("seq").?.integer);
}

test "CK-COMP-015 MCP discovery lists order_progress once with strict schema and no author" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    const response = (try processRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}", &ctx)).?;
    defer a.free(response);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, response, .{});
    defer parsed.deinit();
    const tools = parsed.value.object.get("result").?.object.get("tools").?.array.items;
    try std.testing.expectEqual(@as(usize, 121), tools.len);
    var count: usize = 0;
    for (tools) |tool| {
        if (!std.mem.eql(u8, tool.object.get("name").?.string, "order_progress")) continue;
        count += 1;
        const schema = tool.object.get("inputSchema").?.object;
        try std.testing.expect(!schema.get("additionalProperties").?.bool);
        try std.testing.expect(schema.get("properties").?.object.get("author") == null);
        try std.testing.expect(schema.get("properties").?.object.get("expected_seq") != null);
    }
    try std.testing.expectEqual(@as(usize, 1), count);
    try std.testing.expectEqual(tools.len, capability_tools.len);
}

test "CK-PRV-004 MCP discovers selection preferences and protects writes" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    const listed = (try processRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/list\",\"params\":{}}", &ctx)).?;
    defer a.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "models_selection_v1") != null);
    try std.testing.expect(std.mem.indexOf(u8, listed, "models_preferences_set_v1") != null);
    try std.testing.expect(isPrivilegedTool("models_preferences_set_v1"));
    try std.testing.expect(!isPrivilegedTool("models_selection_v1"));
    const denied = (try processRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"models_preferences_set_v1\",\"arguments\":{}}}", &ctx)).?;
    defer a.free(denied);
    try std.testing.expect(std.mem.indexOf(u8, denied, "autenticacion requerida") != null);
}

test "CK-PRV-004 MCP preference read write roundtrip and invalid arguments" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(a, threaded.io(), ":memory:");
    defer ctx.deinit();
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_model_register(ctx.core_handle, "Cohere", "command-fixture", 1000, 1));
    ctx.authed = true;
    const request = "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"tools/call\",\"params\":{\"name\":\"models_preferences_set_v1\",\"arguments\":{\"json\":\"{\\\"provider\\\":\\\"Cohere\\\",\\\"model\\\":\\\"command-fixture\\\",\\\"show_in_selectors\\\":false,\\\"allow_automatic\\\":true}\"}}}";
    const saved = (try processRequest(a, request, &ctx)).?;
    defer a.free(saved);
    try std.testing.expect(std.mem.indexOf(u8, saved, "isError\":true") == null);
    const listed = (try processRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"models_selection_v1\",\"arguments\":{}}}", &ctx)).?;
    defer a.free(listed);
    try std.testing.expect(std.mem.indexOf(u8, listed, "show_in_selectors\\\":false") != null);
    const invalid = (try processRequest(a, "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"models_preferences_set_v1\",\"arguments\":{}}}", &ctx)).?;
    defer a.free(invalid);
    try std.testing.expect(std.mem.indexOf(u8, invalid, "-32602") != null);
}

test "CK-PLT-007: MCP con BEATS_DATA_DIR abre la base en la carpeta indicada y capabilities la informa" {
    const allocator = std.testing.allocator;
    var prev_beats: [4096:0]u8 = undefined;
    var prev_alias: [4096:0]u8 = undefined;
    const beats_len = GetEnvironmentVariableA("BEATS_DATA_DIR", &prev_beats, prev_beats.len);
    const alias_len = GetEnvironmentVariableA("DEVAGENTS_DATA_DIR", &prev_alias, prev_alias.len);
    defer {
        _ = SetEnvironmentVariableA("BEATS_DATA_DIR", if (beats_len > 0 and beats_len < prev_beats.len) prev_beats[0..beats_len :0].ptr else null);
        _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", if (alias_len > 0 and alias_len < prev_alias.len) prev_alias[0..alias_len :0].ptr else null);
    }
    _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", null);

    // Carpeta temporal bajo .zig-cache (el codigo de prueba fija el override,
    // nunca los comandos del encargo).
    const io = std.testing.io;
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(io, ".", allocator);
    defer allocator.free(cwd);
    const dir_plain = try std.fs.path.join(allocator, &.{ cwd, ".zig-cache", "CK-PLT-007-mcp" });
    defer allocator.free(dir_plain);
    const dir = try allocator.dupeZ(u8, dir_plain);
    defer allocator.free(dir);
    try std.Io.Dir.cwd().createDirPath(io, dir);
    defer std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    _ = SetEnvironmentVariableA("BEATS_DATA_DIR", dir.ptr);

    // La misma resolucion unica que hace main en.
    const resolved = try core.paths.resolveDataDir(allocator, null);
    defer allocator.free(resolved.dir);
    try std.testing.expectEqual(core.paths.DataDirSource.env_beats, resolved.source);

    const db_path = try std.fs.path.join(allocator, &.{ resolved.dir, "runtime.db" });
    defer allocator.free(db_path);
    const db_path_z = try allocator.dupeZ(u8, db_path);
    defer allocator.free(db_path_z);

    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    var ctx = try ServerCtx.init(allocator, threaded.io(), db_path_z);
    defer ctx.deinit();
    // Sin fijar ctx.data_dir: capabilities debe resolver la carpeta REAL por
    // su cuenta, nunca devolver «(cwd default)».

    const resp = (try processRequest(allocator,
        \\{"jsonrpc":"2.0","id":77,"method":"tools/call","params":{"name":"capabilities","arguments":{}}}
    , &ctx)) orelse return error.SolucionSinRespuesta;
    defer allocator.free(resp);

    var outer = try std.json.parseFromSlice(std.json.Value, allocator, resp, .{});
    defer outer.deinit();
    const text = outer.value.object.get("result").?.object.get("content").?.array.items[0].object.get("text").?.string;
    var inner = try std.json.parseFromSlice(std.json.Value, allocator, text, .{});
    defer inner.deinit();
    const obj = inner.value.object;
    // La carpeta REAL abierta, nunca "(cwd default)".
    try std.testing.expectEqualStrings(resolved.dir, obj.get("dataDir").?.string);
    try std.testing.expect((std.Io.Dir.cwd().statFile(io, db_path, .{}) catch null) != null);
}
