const std = @import("std");
const model_catalog = @import("model_catalog.zig");
const model_router = @import("model_router.zig");
const providers = @import("providers");
const credentials = @import("credentials.zig");
const db = @import("db.zig");
const health = @import("health.zig");
const planner = @import("planner.zig");
const superagent = @import("superagent.zig");
const live_worker = @import("live_worker.zig");
const live_planner = @import("llm_planner.zig");
const direct_mode = @import("direct_mode.zig");
const mounts = @import("mounts.zig");
const webhooks = @import("webhooks.zig");
const cli_driver = @import("cli_driver.zig");
const paths = @import("paths.zig");
const pixel_registry = @import("pixel_registry.zig");
const engram_memory = @import("engram_memory.zig");
const workspace = @import("workspace.zig");
const order_trace = @import("order_trace.zig");
const debug_dump = @import("debug_dump.zig");
// el catálogo externo que la cabina ya carga antes de despachar.
const external_registry = @import("external_registry.zig");
const external_agents = @import("external_agents.zig");
// M8: el prefijo reservado de `project_id` para ordenes internas.
const session_store = @import("session_store.zig");
// ROSTER-PRUEBAS: acotar la cadena a los modelos gratuitos de verdad.
const model_roster = @import("model_roster.zig");
const spend_budget = @import("spend_budget.zig");
// D4/el bus del motor, para que `devagents server` sirva algo de verdad.
const engine_process = @import("engine_process.zig");
// el gate ejecuta lo que entrega, con la misma gobernanza que el motor.
const executor = @import("executor.zig");
// r2: punto unico de salida que restaura la pagina de consola.
const console_cp = @import("console_cp.zig");
const tui_interaction = @import("tui/interaction.zig");

const windows = std.os.windows;

const FindFirstFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindFirstFileA(lpFileName: [*:0]const u8, lpFindFileData: *WIN32_FIND_DATAA) windows.HANDLE;
}.FindFirstFileA else @import("providers").posix_files.FindFirstFileA;
const FindNextFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindNextFileA(hFindFile: windows.HANDLE, lpFindFileData: *WIN32_FIND_DATAA) c_int;
}.FindNextFileA else @import("providers").posix_files.FindNextFileA;
const FindClose = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindClose(hFindFile: windows.HANDLE) c_int;
}.FindClose else @import("providers").posix_files.FindClose;
const CopyFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CopyFileA(lpExistingFileName: [*:0]const u8, lpNewFileName: [*:0]const u8, bFailIfExists: c_int) c_int;
}.CopyFileA else @import("providers").posix_files.CopyFileA;
const CreateFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateFileA(lpFileName: [*:0]const u8, dwDesiredAccess: u32, dwShareMode: u32, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: u32, dwFlagsAndAttributes: u32, hTemplateFile: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
}.CreateFileA else @import("providers").posix_files.CreateFileA;
const WriteFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn WriteFile(hFile: windows.HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) c_int;
}.WriteFile else @import("providers").posix_files.WriteFile;
const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) c_int;
}.CloseHandle else @import("providers").posix_files.CloseHandle;
const GetCurrentDirectoryA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetCurrentDirectoryA(nBufferLength: u32, lpBuffer: [*]u8) callconv(.winapi) u32;
}.GetCurrentDirectoryA else @import("platform.zig").cwd;
const GetFullPathNameA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFullPathNameA(lpFileName: [*:0]const u8, nBufferLength: u32, lpBuffer: [*:0]u8, lpFilePart: ?*?[*:0]u8) callconv(.winapi) u32;
}.GetFullPathNameA else @import("providers").posix_files.GetFullPathNameA;
const Sleep = @import("platform.zig").sleep;

// la prueba de lanzamiento fija y restaura las dos variables de
// carpeta de datos dentro de su propio codigo (nunca en los comandos).
const GetEnvironmentVariableA = @import("platform.zig").env;
const SetEnvironmentVariableA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn SetEnvironmentVariableA(lpName: [*:0]const u8, lpValue: ?[*:0]const u8) callconv(.winapi) c_int;
}.SetEnvironmentVariableA else @import("providers").posix_files.SetEnvironmentVariableA;
const CreateDirectoryA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateDirectoryA(lpPathName: [*:0]const u8, lpSecurityAttributes: ?*anyopaque) c_int;
}.CreateDirectoryA else @import("providers").posix_files.CreateDirectoryA;
// (r3, C4): la prueba de lanzamiento comprueba con GetFileAttributesA
// que la CLI lanzada CREO su base dentro de la carpeta aislada.
const GetFileAttributesA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileAttributesA(lpFileName: [*:0]const u8) callconv(.winapi) u32;
}.GetFileAttributesA else @import("providers").posix_files.GetFileAttributesA;

const FILETIME = extern struct { dwLowDateTime: u32, dwHighDateTime: u32 };
const WIN32_FIND_DATAA = extern struct {
    dwFileAttributes: u32,
    ftCreationTime: FILETIME,
    ftLastAccessTime: FILETIME,
    ftLastWriteTime: FILETIME,
    nFileSizeHigh: u32,
    nFileSizeLow: u32,
    dwReserved0: u32,
    dwReserved1: u32,
    cFileName: [260]u8,
    cAlternateFileName: [14]u8,
};
const INVALID_HANDLE_VALUE: windows.HANDLE = @ptrFromInt(~@as(usize, 0));
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;
const GENERIC_WRITE: u32 = 0x40000000;
const CREATE_ALWAYS: u32 = 2;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;

/// CLI de DevAgents.
pub const Cli = struct {
    /// Punto de entrada del CLI.
    ///
    /// antes, cualquier error previsible (proveedor desconocido,
    /// 401/429, red caída, falta de clave…) subía hasta `main` y el runtime de
    /// Zig imprimía `error: X` con la TRAZA DE PILA completa — ruido inservible
    /// para el usuario, que solo quería saber qué hizo mal. Ahora los errores
    /// previsibles se informan con un mensaje claro en español y salen con
    /// código distinto de 0 SIN traza. Los inesperados se re-propagan para
    /// conservar la traza, que ahí sí es diagnóstico útil.
    ///
    /// NO es un `catch` genérico que oculte todo: la lista de errores
    /// "esperados" es explícita y está en `reporteErrorEsperado`.
    pub fn run(allocator: std.mem.Allocator, args: [][]const u8) !void {
        dispatch(allocator, args) catch |e| {
            if (reporteErrorEsperado(e)) |r| {
                if (r.mensaje) |m| std.debug.print("{s}\n", .{m});
                console_cp.exit(r.code);
            }
            return e;
        };
    }

    /// Reporte de un error previsible: código de salida distinto de 0 y, cuando
    /// el punto de origen no lo imprimió ya, el mensaje accionable.
    pub const ReporteError = struct {
        code: u8,
        mensaje: ?[]const u8 = null,
    };

    /// Clasifica `e` como error previsible de usuario/proveedor. Devuelve null
    /// si el error es realmente inesperado y debe conservar su traza de pila.
    ///
    /// Es una lista blanca explícita, no un `catch` comodín: lo que no está
    /// aquí conserva el diagnóstico completo de Zig.
    pub fn reporteErrorEsperado(e: anyerror) ?ReporteError {
        return switch (e) {
            // Fallos de la propia CLI: el punto de origen ya imprimió su
            // mensaje contextual (proveedor y modelo), así que no se repite.
            error.UnknownProvider => .{ .code = 2 },
            error.NoActiveKey => .{ .code = 1 },
            error.CredentialsUnavailable => .{ .code = 1 },
            error.HttpClientInitFailed => .{ .code = 1 },
            error.ConnectorInitFailed => .{ .code = 1 },
            error.BudgetDenied => .{ .code = 1 },
            error.ClarifyRoundsExhausted => .{ .code = 1 },
            error.UnknownModel => .{ .code = 2 },
            // Fallos de proveedor o red: mensaje accionable común.
            error.RateLimited => .{ .code = 1, .mensaje = "El proveedor ha limitado el uso (HTTP 429). Espera un momento o prueba con otro modelo o proveedor." },
            error.AuthFailed => .{ .code = 1, .mensaje = "La clave del proveedor no es válida o no cubre este modelo (HTTP 401/403). Revisa la credencial configurada." },
            error.QuotaExceeded => .{ .code = 1, .mensaje = "Se agotó la cuota del proveedor (HTTP 402). Revísala o cambia de proveedor." },
            error.ModelNotFound => .{ .code = 1, .mensaje = "El proveedor no reconoce ese modelo (HTTP 404). Comprueba el identificador del modelo." },
            error.Timeout => .{ .code = 1, .mensaje = "La solicitud al proveedor agotó el tiempo de espera. Comprueba tu conexión e inténtalo de nuevo." },
            error.RequestFailed, error.ResponseFailed => .{ .code = 1, .mensaje = "No se pudo completar la petición de red al proveedor. Comprueba tu conexión." },
            error.RedirectBlocked => .{ .code = 1, .mensaje = "El proveedor intentó redirigir la petición a otro destino y se bloqueó por seguridad." },
            error.ProviderError => .{ .code = 1, .mensaje = "El proveedor devolvió un error al atender la solicitud." },
            error.SseParseFailed => .{ .code = 1, .mensaje = "La respuesta del proveedor no se pudo interpretar." },
            error.EmptyResponse => .{ .code = 1, .mensaje = "El proveedor respondió sin contenido." },
            error.TruncatedResponse => .{ .code = 1, .mensaje = "La respuesta del proveedor llegó truncada." },
            error.IncompleteStream => .{ .code = 1, .mensaje = "La respuesta del proveedor quedó incompleta." },
            else => null,
        };
    }

    fn dispatch(allocator: std.mem.Allocator, args: [][]const u8) !void {
        if (args.len < 2) {
            // E1: sin argumentos y con consola real (stdin Y stdout)
            // se abre la sesión interactiva; en cualquier otro caso
            // (tubería, archivo, CI) se conserva este mismo `--help`.
            return @import("tui/session.zig").runNoArgs(allocator, @import("tui/console.zig").probeSystem(), printHelp);
        }

        // Modo driver CLI-JSON universal (BACKLOG-IDE-REMOTE Fase 1).
        const is_driver = std.mem.eql(u8, args[1], "driver");
        var has_json = false;
        for (args) |a| {
            if (std.mem.eql(u8, a, "--json")) {
                has_json = true;
                break;
            }
        }
        if (is_driver or has_json) {
            var driver_args: std.ArrayList([]const u8) = .empty;
            defer driver_args.deinit(allocator);
            // Saltar el nombre del programa y el subcomando "driver" literal.
            var i: usize = 1;
            while (i < args.len) : (i += 1) {
                if (is_driver and i == 1) continue;
                if (std.mem.eql(u8, args[i], "--json")) continue;
                try driver_args.append(allocator, args[i]);
            }
            return cli_driver.CliDriver.run(allocator, driver_args.items);
        }

        const command = args[1];
        if (std.mem.eql(u8, command, "--version")) {
            if (@import("builtin").os.tag == .windows) {
                const native = struct {
                    extern "c" fn da_print_installed_versions() void;
                };
                native.da_print_installed_versions();
            } else {
                std.debug.print("DevAgents: {s}\n", .{@import("version.zig").identity});
            }
            // (C3): --version informa la carpeta de datos REAL que
            // abre esta CLI y de donde viene, en vez de dejarla en la sombra.
            // Un override invalido sale como fallo cerrado con mensaje claro.
            if (dataDirStatusLine(allocator)) |line| {
                defer allocator.free(line);
                std.debug.print("{s}\n", .{line});
            } else |err| {
                std.debug.print("Carpeta de datos: NO RESUELTA ({s}); BEATS_DATA_DIR/DEVAGENTS_DATA_DIR debe ser una ruta absoluta y existente\n", .{@errorName(err)});
            }
            return;
        }
        if (std.mem.eql(u8, command, "remote")) return @import("remote_server.zig").run(allocator, args[2..]);
        if (std.mem.eql(u8, command, "--supervised") or std.mem.eql(u8, command, "server")) {
            // — esto era un `while (true) Sleep(1000)`.
            //
            // Un «modo demonio del núcleo supervisado» que no supervisaba ni
            // atendía nada: quemaba un hilo durmiendo, no aparecía en la ayuda
            // y no había forma de notar que no hacía nada porque tampoco
            // imprimía. Encontrado el 2026-08-15 recorriendo el CLI como
            // usuario.
            //
            // Ahora sirve lo que D4 dejó listo: el bus de tuberías con nombre
            // que atiende `da_status`. Es el mismo `serve` que usa
            // `devagents-engine.exe`, no una copia — un demonio de mentira ya
            // costó este comando una vez.
            var pipe: []const u8 = "devagents-engine-cli";
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--pipe") and i + 1 < args.len) {
                    pipe = args[i + 1];
                    i += 1;
                }
            }
            std.debug.print("Motor escuchando en \\\\.\\pipe\\{s} (Ctrl+C para parar).\n", .{pipe});
            engine_process.serve(allocator, pipe) catch |e| {
                std.debug.print("El bus del motor se cerro: {s}\n", .{@errorName(e)});
                return e;
            };
            return;
        } else if (std.mem.eql(u8, command, "models")) {
            if (args.len < 3) {
                usoInvalido("Uso: devagents models list|discover|roster", .{});
            }
            const sub = args[2];
            if (std.mem.eql(u8, sub, "list")) {
                try cmdModelsList(allocator);
            } else if (std.mem.eql(u8, sub, "discover")) {
                try cmdModelsDiscover(allocator);
            } else if (std.mem.eql(u8, sub, "roster")) {
                try cmdModelsRoster(allocator);
            } else {
                usoInvalido("Subcomando de models desconocido: {s}\nUso: devagents models list|discover|roster", .{sub});
            }
        } else if (std.mem.eql(u8, command, "chat")) {
            var model: ?[]const u8 = null;
            var provider_name: []const u8 = "OpenCode";
            var prompt: []const u8 = "Hello from DevAgents.";
            var prompt_owned: ?[]const u8 = null;
            defer if (prompt_owned) |owned| allocator.free(owned);
            var debug = false;
            var read_stdin = false;
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--model") and i + 1 < args.len) {
                    model = args[i + 1];
                    i += 1;
                } else if (std.mem.eql(u8, args[i], "--provider") and i + 1 < args.len) {
                    provider_name = args[i + 1];
                    i += 1;
                } else if (std.mem.eql(u8, args[i], "--prompt") and i + 1 < args.len) {
                    prompt = args[i + 1];
                    i += 1;
                } else if (std.mem.eql(u8, args[i], "--debug")) {
                    debug = true;
                } else if (std.mem.eql(u8, args[i], "--stdin")) {
                    read_stdin = true;
                }
            }
            if (read_stdin) {
                prompt_owned = try readStdinAll(allocator);
                prompt = std.mem.trim(u8, prompt_owned.?, " \t\r\n");
            }
            if (model) |m| {
                try cmdChat(allocator, m, provider_name, prompt, debug);
            } else {
                usoInvalido("Uso: devagents chat --model <id_modelo> [--provider <nombre>] [--prompt <texto>|--stdin] [--debug]", .{});
            }
        } else if (std.mem.eql(u8, command, "governance")) {
            try cmdGovernance(allocator, if (args.len >= 3) args[2] else null);
        } else if (std.mem.eql(u8, command, "usage")) {
            try cmdUsage(allocator);
        } else if (std.mem.eql(u8, command, "doctor")) {
            // Tanda 4 (F0.5): comprobación antes de la primera orden. Salida 1
            // si falta algo, para que un guion de instalación pueda pararse.
            var report = try @import("doctor.zig").runLocal(allocator);
            defer report.deinit();
            const text = try @import("doctor.zig").renderText(allocator, report);
            defer allocator.free(text);
            std.debug.print("{s}", .{text});
            if (!report.ready) console_cp.exit(1);
        } else if (std.mem.eql(u8, command, "selftest")) {
            var solo: ?[]const u8 = null;
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--caso") and i + 1 < args.len) {
                    solo = args[i + 1];
                    i += 1;
                }
            }
            try cmdSelfTest(allocator, solo);
        } else if (std.mem.eql(u8, command, "route")) {
            if (args.len >= 3 and std.mem.eql(u8, args[2], "--demo")) {
                try cmdRouteDemo(allocator);
            } else if (args.len >= 3 and std.mem.eql(u8, args[2], "--chain")) {
                try cmdRouteChain(allocator);
            } else {
                usoInvalido("Uso: devagents route --demo | --chain", .{});
            }
        } else if (std.mem.eql(u8, command, "agents") or std.mem.eql(u8, command, "specialists")) {
            // PIXEL-DEVTEAM-05: listar el registro unificado.
            if (args.len >= 3 and !std.mem.eql(u8, args[2], "list")) {
                usoInvalido("Uso: devagents agents [list]", .{});
                return;
            }
            try cmdAgentsList(allocator);
        } else if (std.mem.eql(u8, command, "mount")) {
            if (args.len < 3) {
                usoInvalido("Uso: devagents mount add|remove|list <ruta>", .{});
                return;
            }
            const sub = args[2];
            if (std.mem.eql(u8, sub, "add")) {
                if (args.len < 4) {
                    usoInvalido("Uso: devagents mount add <ruta>", .{});
                    return;
                }
                try cmdMountAdd(allocator, args[3]);
            } else if (std.mem.eql(u8, sub, "remove")) {
                if (args.len < 4) {
                    usoInvalido("Uso: devagents mount remove <ruta>", .{});
                    return;
                }
                try cmdMountRemove(allocator, args[3]);
            } else if (std.mem.eql(u8, sub, "list")) {
                try cmdMountList(allocator);
            } else {
                usoInvalido("Subcomando de mount desconocido: {s}\nUso: devagents mount add|remove|list <ruta>", .{sub});
            }
        } else if (std.mem.eql(u8, command, "webhook")) {
            if (args.len < 3) {
                usoInvalido("Uso: devagents webhook add|remove|list [--url <url>] [--event <evento>]", .{});
                return;
            }
            const sub = args[2];
            if (std.mem.eql(u8, sub, "add")) {
                try cmdWebhookAdd(allocator, args[3..]);
            } else if (std.mem.eql(u8, sub, "remove")) {
                if (args.len < 4) {
                    usoInvalido("Uso: devagents webhook remove <id>", .{});
                    return;
                }
                try cmdWebhookRemove(allocator, args[3]);
            } else if (std.mem.eql(u8, sub, "list")) {
                try cmdWebhookList(allocator);
            } else {
                usoInvalido("Subcomando de webhook desconocido: {s}\nUso: devagents webhook add|remove|list [--url <url>] [--event <evento>]", .{sub});
            }
        } else if (std.mem.eql(u8, command, "order")) {
            // pedir ayuda no puede lanzar una orden real. Antes
            // `devagents order --help` tomaba «--help» como texto de la orden y
            // la mandaba al planificador.
            if (orderHelpRequested(args)) {
                printOrderUsage();
                return;
            }
            if (args.len < 3) {
                usoInvalido("Uso: devagents order \"<texto de la orden>\" [--text <texto>|--stdin] [--answer <id>=<valor>] [--yes] [--sudo] [--provider P --model M]", .{});
                return;
            }
            var order_text: []const u8 = "";
            var order_text_owned: ?[]const u8 = null;
            defer if (order_text_owned) |owned| allocator.free(owned);
            var approve = false;
            var tui_session = false;
            var lang_answer: ?[]const u8 = null;
            var forced_provider: ?[]const u8 = null;
            var forced_model: ?[]const u8 = null;
            var read_stdin = false;
            // M7: vive y muere con esta invocacion. No se guarda en ningun sitio.
            var sudo = false;
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--yes")) {
                    approve = true;
                } else if (std.mem.eql(u8, args[i], "--tui-session")) {
                    tui_session = true;
                } else if (std.mem.eql(u8, args[i], "--sudo")) {
                    sudo = true;
                } else if (std.mem.eql(u8, args[i], "--stdin")) {
                    read_stdin = true;
                } else if (std.mem.eql(u8, args[i], "--text") and i + 1 < args.len) {
                    order_text = args[i + 1];
                    i += 1;
                } else if (std.mem.eql(u8, args[i], "--answer") and i + 1 < args.len) {
                    const pair = args[i + 1];
                    if (std.mem.indexOfScalar(u8, pair, '=')) |eq| lang_answer = pair[eq + 1 ..];
                    i += 1;
                } else if (std.mem.eql(u8, args[i], "--provider") and i + 1 < args.len) {
                    forced_provider = args[i + 1];
                    i += 1;
                } else if (std.mem.eql(u8, args[i], "--model") and i + 1 < args.len) {
                    forced_model = args[i + 1];
                    i += 1;
                } else if (i == 2 and order_text.len == 0) {
                    order_text = args[i];
                }
            }
            if (read_stdin) {
                order_text_owned = try readStdinAll(allocator);
                order_text = std.mem.trim(u8, order_text_owned.?, " \t\r\n");
            }
            if (order_text.len == 0) {
                usoInvalido("Uso: devagents order \"<texto>\" [--text <texto>|--stdin] [--yes]", .{});
                return;
            }
            const resumen = try cmdOrder(allocator, order_text, lang_answer, approve, forced_provider, forced_model, sudo, tui_session);
            // una orden que termina `failed` no puede salir con 0;
            // done y pendiente de aprobación siguen saliendo con 0.
            if (orderExitCode(resumen) != 0) console_cp.exit(1);
        } else if (std.mem.eql(u8, command, "design")) {
            var order_text: []const u8 = "";
            var order_text_owned: ?[]const u8 = null;
            defer if (order_text_owned) |owned| allocator.free(owned);
            var forced_provider: ?[]const u8 = null;
            var forced_model: ?[]const u8 = null;
            var read_stdin = false;
            var project_dir: ?[]const u8 = null;
            var i: usize = 2;
            while (i < args.len) : (i += 1) {
                if (std.mem.eql(u8, args[i], "--stdin")) {
                    read_stdin = true;
                } else if (std.mem.eql(u8, args[i], "--project-dir") and i + 1 < args.len) {
                    project_dir = args[i + 1];
                    i += 1;
                } else if (std.mem.eql(u8, args[i], "--provider") and i + 1 < args.len) {
                    forced_provider = args[i + 1];
                    i += 1;
                } else if (std.mem.eql(u8, args[i], "--model") and i + 1 < args.len) {
                    forced_model = args[i + 1];
                    i += 1;
                } else if (std.mem.eql(u8, args[i], "--text") and i + 1 < args.len) {
                    order_text = args[i + 1];
                    i += 1;
                } else if (i == 2 and order_text.len == 0) {
                    order_text = args[i];
                }
            }
            if (read_stdin) {
                order_text_owned = try readStdinAll(allocator);
                order_text = std.mem.trim(u8, order_text_owned.?, " \t\r\n");
            }
            if (order_text.len == 0) {
                usoInvalido("Uso: devagents design [--text <texto>|--stdin] [--project-dir <dir>] [--provider P --model M]", .{});
                return;
            }
            try cmdDesign(allocator, order_text, project_dir, forced_provider, forced_model);
        } else if (std.mem.eql(u8, command, "debug")) {
            // devagents debug last | debug <id_orden> | debug --on | debug --off | debug --status
            if (args.len >= 3 and std.mem.eql(u8, args[2], "--on")) {
                debug_dump.setEnabled(true);
                std.debug.print("Depuración global: ENCENDIDA.\n", .{});
            } else if (args.len >= 3 and std.mem.eql(u8, args[2], "--off")) {
                debug_dump.setEnabled(false);
                std.debug.print("Depuración global: APAGADA.\n", .{});
            } else if (args.len >= 3 and std.mem.eql(u8, args[2], "--status")) {
                std.debug.print("Depuración global: {s}.\n", .{if (debug_dump.isEnabled()) "ENCENDIDA" else "APAGADA"});
            } else {
                var order_id: ?i64 = null;
                // B4: `--full` puede ir en cualquier posición; el resto de
                // argumentos después del número/last se ignoran igual que
                // siempre (todo va por posición hoy).
                var full: bool = false;
                var i: usize = 2;
                while (i < args.len) : (i += 1) {
                    if (std.mem.eql(u8, args[i], "--full")) {
                        full = true;
                    } else if (order_id == null and !std.mem.eql(u8, args[i], "last")) {
                        order_id = std.fmt.parseInt(i64, args[i], 10) catch {
                            usoInvalido("Uso: devagents debug last [--full] | <id_orden> [--full] | --on | --off | --status", .{});
                            return;
                        };
                    }
                }
                try cmdDebug(allocator, order_id, full);
            }
        } else if (std.mem.eql(u8, command, "health")) {
            // health [summary|list] [--json] | health probe --provider P --model M
            // `--json` puede ir en cualquier posicion, porque nadie recuerda
            // si va antes o despues del subcomando.
            const sub = if (args.len >= 3 and !std.mem.eql(u8, args[2], "--json")) args[2] else "summary";
            if (std.mem.eql(u8, sub, "probe")) {
                var prov: []const u8 = "OpenCode";
                var mdl: ?[]const u8 = null;
                var pr: []const u8 = "Responde solo: OK";
                var i: usize = 3;
                while (i < args.len) : (i += 1) {
                    if (std.mem.eql(u8, args[i], "--provider") and i + 1 < args.len) {
                        prov = args[i + 1];
                        i += 1;
                    } else if (std.mem.eql(u8, args[i], "--model") and i + 1 < args.len) {
                        mdl = args[i + 1];
                        i += 1;
                    } else if (std.mem.eql(u8, args[i], "--prompt") and i + 1 < args.len) {
                        pr = args[i + 1];
                        i += 1;
                    }
                }
                if (mdl) |m| {
                    try cmdChat(allocator, m, prov, pr, false); // registra salud de forma pasiva
                } else {
                    usoInvalido("Uso: devagents health probe --provider <nombre> --model <id> [--prompt <texto>]", .{});
                }
            } else if (std.mem.eql(u8, sub, "list")) {
                try cmdHealth(allocator, true);
            } else {
                try cmdHealth(allocator, false);
            }
        } else if (std.mem.eql(u8, command, "--help") or
            std.mem.eql(u8, command, "-h") or
            std.mem.eql(u8, command, "help") or
            std.mem.eql(u8, command, "/?"))
        {
            // Pedir ayuda no es equivocarse. Antes `devagents --help` imprimia
            // "Unknown command: --help" y DESPUES la ayuda: un reproche por
            // escribir la forma que usa cualquier otra CLI del mundo.
            try printHelp();
        } else {
            // — el CLI no sabia fallar.
            //
            // Medido el 2026-08-15 recorriendolo como usuario: `devagents
            // noexiste`, `devagents mount` sin argumentos y `devagents debug
            // <orden-que-no-existe)` terminaban los tres en 0. Cualquier script
            // o CI que envuelva esta herramienta no puede enterarse de nada:
            // «funciono» y «te equivocaste de comando» valen lo mismo.
            //
            // Es la misma familia de (el gate de aceptacion que tampoco
            // podia tumbar a nadie). Un comando que no existe es error de uso:
            // codigo 2, que es la convencion.
            std.debug.print("Comando desconocido: {s}\n\n", .{command});
            try printHelp();
            console_cp.exit(2);
        }
    }

    /// error de USO (argumentos mal). Imprime y termina con codigo 2.
    ///
    /// Se centraliza para que no vuelva a haber catorce `Uso:` sueltos
    /// terminando en 0 cada uno por su cuenta.
    fn usoInvalido(comptime fmt: []const u8, args: anytype) noreturn {
        std.debug.print(fmt, args);
        std.debug.print("\n", .{});
        console_cp.exit(2);
    }

    /// QA-A H6: un fallo de la orden pedida (no de uso). Imprime y sale con 1.
    fn falla(comptime fmt: []const u8, args: anytype) noreturn {
        std.debug.print(fmt, args);
        std.debug.print("\n", .{});
        console_cp.exit(1);
    }

    const Base = enum { runtime, catalog };

    /// QA-A H1/H6: abre y migra una base de la carpeta de datos.
    /// Si no puede, dice cuál, dónde y por qué (la migración y el mensaje de
    /// SQLite, no solo «No se pudo migrar») y sale con 1. Antes, cada comando
    /// lo hacía por su cuenta, sin causa y saliendo con 0.
    fn abrirBase(allocator: std.mem.Allocator, base: Base) db.Connection {
        const nombre = switch (base) {
            .runtime => "runtime.db",
            .catalog => "catalog.db",
        };
        const path = (switch (base) {
            .runtime => paths.runtimeDb(allocator),
            .catalog => paths.catalogDb(allocator),
        }) catch |e| falla("No se pudo resolver la ruta de {s}: {s}. DEVAGENTS_DATA_DIR debe ser una ruta absoluta y existente.", .{ nombre, @errorName(e) });
        defer allocator.free(path);
        var conn = db.Connection.open(allocator, path) catch |e|
            falla("No se pudo abrir {s} ({s}): {s}. Comprueba que la carpeta existe y se puede escribir.", .{ nombre, path, @errorName(e) });
        const schema: []const []const u8 = switch (base) {
            .runtime => &db.runtime_schema,
            .catalog => &db.catalog_schema,
        };
        db.Migrator.init(allocator).migrate(conn, schema) catch {
            const causa = db.migrateFailureText();
            conn.close();
            falla("No se pudo migrar {s} ({s}): {s}", .{ nombre, path, causa });
        };
        return conn;
    }

    /// `devagents debug last|<id_orden>`: vuelca la traza cruda de una orden.
    /// Lección de la orden 148: la instrumentación existía en runtime.db y solo
    /// llegaba a ella una consulta SQL a mano; esto la hace accesible en un
    /// comando, igual dentro de la pestaña TERMINAL que desde la línea de órdenes.
    /// B4: por defecto se oculta el ruido de streaming (`content_delta`) y se
    /// anuncia cuántos se suprimieron; `full=true` (--full) los vuelve.
    fn cmdDebug(allocator: std.mem.Allocator, order_id: ?i64, full: bool) !void {
        var runtime = abrirBase(allocator, .runtime);
        defer runtime.close();
        var trace = order_trace.loadTrace(allocator, runtime, order_id) catch |e| {
            // pedir la traza de una orden que no existe es un fallo, no un
            // exito silencioso. Codigo 1 (no 2: el uso era correcto, lo que
            // falla es que el dato no esta). QA-A H12: en palabras, no `NoOrdersYet`.
            switch (e) {
                error.NoOrdersYet => falla("Todavía no hay ninguna orden en esta carpeta de datos: lanza una con `devagents order \"...\"`.", .{}),
                error.OrderNotFound => falla("No existe la orden #{d} en esta carpeta de datos.", .{order_id orelse 0}),
                else => falla("No se pudo leer la traza de la orden: {s}", .{@errorName(e)}),
            }
        };
        defer trace.deinit();
        const txt = order_trace.formatTraceOpt(allocator, &trace, full) catch |e|
            falla("No se pudo formatear la traza: {s}", .{@errorName(e)});
        defer allocator.free(txt);
        std.debug.print("{s}", .{txt});
    }

    /// Imprime la salud de modelos desde runtime.db: resumen por proveedor (default)
    /// o detalle por modelo (list_mode). JSON en stdout.
    fn cmdHealth(allocator: std.mem.Allocator, list_mode: bool) !void {
        var runtime = abrirBase(allocator, .runtime);
        defer runtime.close();
        // — `devagents health` era ilegible Y no se podia consumir.
        //
        // Medido el 2026-08-15 conduciendo el CLI como usuario: escupia 9 KB de
        // JSON de 108 modelos en UNA linea, y ademas por **stderr**, no por
        // stdout. O sea: una persona no puede leerlo, y `devagents health >
        // salud.json` daba un archivo VACIO. Encima la ayuda prometia «% por
        // proveedor», que no aparecia por ningun lado. Tres defectos en un
        // comando que, a la vista del resultado, no habia usado nadie.
        //
        // Ahora: tabla por defecto (el % que promete la ayuda), y `--json`
        // para maquinas, por stdout de verdad.
        try printHealthTable(allocator, runtime, list_mode);
    }

    /// La vista humana de la salud: un porcentaje de acierto por fila.
    ///
    /// `list_mode` da una fila por MODELO; sin el, una fila por PROVEEDOR, que
    /// es lo que la ayuda ha prometido siempre y nunca existio.
    fn printHealthTable(allocator: std.mem.Allocator, runtime: db.Connection, list_mode: bool) !void {
        const sql = if (list_mode)
            \\SELECT model_id, SUM(ok_count), SUM(err_count), SUM(timeout_count), MAX(last_err_kind)
            \\FROM model_health GROUP BY model_id ORDER BY SUM(ok_count) DESC, model_id
        else
            \\SELECT substr(model_id, 1, instr(model_id, '/') - 1), SUM(ok_count), SUM(err_count), SUM(timeout_count), ''
            \\FROM model_health WHERE instr(model_id, '/') > 0
            \\GROUP BY substr(model_id, 1, instr(model_id, '/') - 1) ORDER BY SUM(ok_count) DESC
        ;
        const stmt = runtime.prepare(sql) catch |e|
            falla("Error al consultar la salud de modelos: {s}", .{@errorName(e)});
        defer runtime.finalize(stmt);

        const cabecera = if (list_mode) "MODELO" else "PROVEEDOR";
        std.debug.print("{s: <46} {s: >5} {s: >5} {s: >5} {s: >7}  ULTIMO ERROR\n", .{ cabecera, "OK", "ERR", "T/O", "% OK" });
        std.debug.print("{s}\n", .{"-" ** 84});

        var filas: usize = 0;
        while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            const id_ptr = db.c.sqlite3_column_text(stmt, 0);
            if (id_ptr == null) continue;
            const id = std.mem.span(id_ptr);
            const ok = db.c.sqlite3_column_int64(stmt, 1);
            const errs = db.c.sqlite3_column_int64(stmt, 2);
            const tos = db.c.sqlite3_column_int64(stmt, 3);
            const kind_ptr = db.c.sqlite3_column_text(stmt, 4);
            const kind = if (kind_ptr != null) std.mem.span(kind_ptr) else "";
            const total = ok + errs + tos;
            // R15: sin intentos NO hay porcentaje. Un 0,0 % ahi seria un numero
            // inventado — «nunca se probo» y «fallo siempre» no son lo mismo.
            if (total == 0) {
                std.debug.print("{s: <46} {d: >5} {d: >5} {d: >5} {s: >7}  {s}\n", .{ id, sinSigno(ok), sinSigno(errs), sinSigno(tos), "-", kind });
            } else {
                const pct = @as(f64, @floatFromInt(ok)) * 100.0 / @as(f64, @floatFromInt(total));
                std.debug.print("{s: <46} {d: >5} {d: >5} {d: >5} {d: >6.1}%  {s}\n", .{ id, sinSigno(ok), sinSigno(errs), sinSigno(tos), pct, kind });
            }
            filas += 1;
        }
        if (filas == 0) {
            std.debug.print("\nSin registros de salud todavia. Se llenan solos al despachar ordenes,\n", .{});
            std.debug.print("o a mano con: devagents health probe --provider <p> --model <m>\n", .{});
            return;
        }
        _ = allocator;
        std.debug.print("\n{d} fila(s). Para la salida en JSON: devagents health --json\n", .{filas});
    }

    /// — en este Zig, `{d:>6}` sobre un entero CON SIGNO imprime el signo:
    /// un total de 60 llamadas salia como «+60», que se lee como un incremento.
    /// Medido el 2026-08-15 recorriendo `devagents usage` y la tabla nueva de
    /// salud. Los conteos no son deltas: se muestran sin signo.
    ///
    /// El clamp a 0 no es decorativo: `@intCast` de un negativo entra en
    /// comportamiento indefinido, y una suma corrupta en la base no debe
    /// tumbar un listado.
    fn sinSigno(v: i64) u64 {
        return if (v < 0) 0 else @intCast(v);
    }

    /// Punto de reentrada para la sesión interactiva cae aquí
    /// cuando no hay consola real (mismo texto exacto de siempre).
    pub fn printHelp() !void {
        const lang_raw = std.c.getenv("DEVAGENTS_LANG");
        const lang = if (lang_raw) |p| std.mem.span(p) else "";
        if (std.ascii.eqlIgnoreCase(lang, "en")) {
            std.debug.print("{s}", .{HELP_TEXT_EN});
        } else {
            std.debug.print("{s}", .{HELP_TEXT});
        }
    }

    /// (T7): subcomandos que `dispatch` atiende. La prueba
    /// «la ayuda lista todos los subcomandos» exige que cada uno salga en
    /// HELP_TEXT como `devagents <nombre>`.
    pub const HELP_COMMANDS = [_][]const u8{ "--version", "models", "chat", "route", "agents", "specialists", "mount", "webhook", "health", "debug", "order", "governance", "doctor", "selftest", "design", "usage", "server", "remote", "driver", "help" };

    pub const HELP_TEXT =
        \\DevAgents CLI
        \\
        \\Comandos:
        \\  devagents --version             Versión de cada componente y carpeta de datos que abre
        \\  devagents help | --help | -h    Esta ayuda
        \\  devagents models list           Lista los modelos disponibles
        \\  devagents models discover       Descubre en vivo los modelos de cada proveedor con clave
        \\  devagents models roster         Plantilla de modelos por rol
        \\  devagents chat --model <id> [--provider <nombre>] [--prompt <texto>|--stdin]
        \\                                  Chat con un modelo, con respuesta en tiempo real.
        \\                                  --provider es NECESARIO cuando el mismo
        \\                                  identificador existe en varios proveedores.
        \\  devagents route --demo|--chain  Demostración de selección de modelos o de la cadena de respaldo
        \\  devagents agents [list]         Lista los especialistas disponibles
        \\  devagents specialists           Igual que `agents`
        \\  devagents mount add|remove|list <ruta>  Gestiona las carpetas vinculadas
        \\  devagents webhook add --url <url> [--event <ev>] | remove <id> | list
        \\                                  Webhooks entrantes (remove recibe el identificador)
        \\  devagents health [list] [--json]  Salud de modelos: % de acierto por proveedor
        \\                                  (o por modelo con `list`). --json escribe en la salida estándar
        \\  devagents health probe --provider <p> --model <m>  Prueba y registra salud
        \\  devagents debug last [--full]   Vuelco crudo de la última orden (sin fragmentos de la respuesta en tiempo real)
        \\  devagents debug <id_orden> [--full]  Vuelco crudo de la orden indicada (sin fragmentos de respuesta)
        \\  devagents debug --on|--off      Interruptor global de depuración (desactivada por defecto)
        \\  devagents debug --status        Estado del interruptor global
        \\  devagents order "<texto>"       Superagente: orden → plan (+ --yes despacha)
        \\                                  --sudo eleva permisos SOLO en esa orden
        \\  devagents governance [free|paid|hybrid]  Modo de gobernanza (sin argumento: lo muestra)
        \\  devagents doctor [--json]       Antes de la primera orden: datos, disco, WebView2, git,
        \\                                  CLI de terceros con su sesión, claves y Ollama (sin gastar cupo)
        \\  devagents selftest [--caso <nombre>]  Pruebas de aceptación con órdenes verificadas en disco
        \\                                  nombres: web-1archivo | web-multiarchivo | python | prosa
        \\  devagents design [--stdin] [--project-dir <dir>]  Planifica y ejecuta una orden en la carpeta indicada
        \\  devagents usage                 Consumo por modelo (llamadas y tokens, desde runtime.db)
        \\  devagents server [--pipe <n>]   Motor como proceso aparte: atiende da_status por el bus (D4)
        \\  devagents remote serve --data-dir <dir> [--port <n>] [--origin <url>]  Interfaz web móvil accesible solo desde este equipo
        \\  devagents driver <comando> | <comando> --json  Modo CLI-JSON para IDEs y guiones
        \\
        \\Por MCP: devagents-mcp.exe (stdio) para Claude Code, Codex, Cursor u otra IDE.
        \\
    ;

    /// HELP_TEXT en inglés: se usa cuando DEVAGENTS_LANG=en (o --lang en una
    /// sesión interactiva futura). La ayuda es la primera superficie del CLI;
    /// los mensajes de runtime siguen en español (i18n completa del CLI es
    /// trabajo aparte, ficha pendiente).
    pub const HELP_TEXT_EN =
        \\DevAgents CLI
        \\
        \\Commands:
        \\  devagents --version             Version of each component and the data folder it opens
        \\  devagents help | --help | -h    This help
        \\  devagents models list           List available models
        \\  devagents models discover       Discover live models of each provider with a key
        \\  devagents models roster         Model template per role
        \\  devagents chat --model <id> [--provider <name>] [--prompt <text>|--stdin]
        \\                                  Chat with a model, streaming responses.
        \\                                  --provider is REQUIRED when the same
        \\                                  identifier exists in several providers.
        \\  devagents route --demo|--chain  Model selection demo or fallback chain
        \\  devagents agents [list]         List available specialists
        \\  devagents specialists           Same as `agents`
        \\  devagents mount add|remove|list <path>  Manage linked folders
        \\  devagents webhook add --url <url> [--event <ev>] | remove <id> | list
        \\                                  Incoming webhooks (remove takes the identifier)
        \\  devagents health [list] [--json]  Model health: success rate per provider
        \\                                  (or per model with `list`). --json writes to stdout
        \\  devagents health probe --provider <p> --model <m>  Probe and record health
        \\  devagents debug last [--full]   Raw dump of the last order (no real-time response fragments)
        \\  devagents debug <order_id> [--full]  Raw dump of the given order (no response fragments)
        \\  devagents debug --on|--off      Global debug switch (off by default)
        \\  devagents debug --status        Global switch status
        \\  devagents order "<text>"        Superagent: order → plan (+ --yes dispatches)
        \\                                  --sudo raises permissions ONLY for that order
        \\  devagents governance [free|paid|hybrid]  Governance mode (no argument: shows it)
        \\  devagents doctor [--json]       Before the first order: data, disk, WebView2, git,
        \\                                  third-party CLIs with their session, keys and Ollama (no quota spent)
        \\  devagents selftest [--caso <name>]  Acceptance tests with orders verified on disk
        \\                                  names: web-1archivo | web-multiarchivo | python | prosa
        \\  devagents design [--stdin] [--project-dir <dir>]  Plans and runs an order in the given folder
        \\  devagents usage                 Usage per model (calls and tokens, from runtime.db)
        \\  devagents server [--pipe <n>]   Engine as a separate process: serves da_status over the bus (D4)
        \\  devagents remote serve --data-dir <dir> [--port <n>] [--origin <url>]  Mobile web UI reachable only from this machine
        \\  devagents driver <command> | <command> --json  CLI-JSON mode for IDEs and scripts
        \\
        \\Via MCP: devagents-mcp.exe (stdio) for Claude Code, Codex, Cursor or any IDE.
        \\
    ;

    fn readStdinAll(allocator: std.mem.Allocator) ![]const u8 {
        var threaded = std.Io.Threaded.init(allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const in = std.Io.File.stdin();
        var in_buf: [32768]u8 = undefined;
        var reader = in.readerStreaming(io, &in_buf);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(allocator);
        while (true) {
            const maybe = reader.interface.takeDelimiter('\n') catch break;
            const line = maybe orelse break;
            try out.appendSlice(allocator, line);
            try out.append(allocator, '\n');
        }
        return try out.toOwnedSlice(allocator);
    }

    /// Superagente (spec 009): orden por CLI → entendimiento → clarificación o plan.
    /// Persiste en runtime.db. Usa catalog.db para asignar modelos si está poblado;
    /// si no, el plan se genera igual con las tareas sin modelo asignado (no adivina).
    /// Lo que una orden deja detrás, para quien necesite comprobarlo en vez de
    /// leerlo. `cmdOrder` lo ignora y el gate de aceptación lo contrasta con el
    /// disco.
    const OrderRunSummary = struct {
        order_id: i64 = 0,
        dispatched: bool = false,
        completed: usize = 0,
        failed: usize = 0,
        integrated: usize = 0,
        rejected: usize = 0,
        /// terminal `failed` del despacho (no confundir con tareas
        /// sueltas fallidas: una orden con aprobaciones pendientes no es failed).
        order_failed: bool = false,
        pending_approvals: usize = 0,
    };

    fn cmdOrder(allocator: std.mem.Allocator, order_text: []const u8, lang_answer: ?[]const u8, approve: bool, forced_provider: ?[]const u8, forced_model: ?[]const u8, sudo: bool, tui_session: bool) !OrderRunSummary {
        return try runOrder(allocator, order_text, lang_answer, approve, forced_provider, forced_model, false, sudo, "cli", tui_session);
    }

    fn printOrderUsage() void {
        std.debug.print("Uso: devagents order \"<texto de la orden>\" [--text <texto>|--stdin] [--answer <id>=<valor>] [--yes] [--sudo] [--provider P --model M]\n", .{});
    }

    /// `--help`/`-h` tras el subcomando piden ayuda, no una orden.
    /// Solo cuenta en posición de FLAG: el valor de `--text`/`--answer`/
    /// `--provider`/`--model` es texto de la orden aunque sea «-h»
    /// (`--text -h` es la orden «-h», no la ayuda).
    fn orderHelpRequested(args: []const []const u8) bool {
        var i: usize = 2;
        while (i < args.len) : (i += 1) {
            if (std.mem.eql(u8, args[i], "--help") or std.mem.eql(u8, args[i], "-h")) return true;
            if (orderFlagConValor(args[i]) and i + 1 < args.len) i += 1;
        }
        return false;
    }

    /// Los flags de `devagents order` que se llevan el siguiente argumento
    /// como valor (misma lista que el parser de `dispatch` más arriba).
    fn orderFlagConValor(arg: []const u8) bool {
        return std.mem.eql(u8, arg, "--text") or
            std.mem.eql(u8, arg, "--answer") or
            std.mem.eql(u8, arg, "--provider") or
            std.mem.eql(u8, arg, "--model");
    }

    /// código de salida de `devagents order`. Una orden con
    /// aprobaciones pendientes no es `failed`: sigue esperando al usuario.
    fn orderExitCode(resumen: OrderRunSummary) u8 {
        if (resumen.pending_approvals > 0) return 0;
        return if (resumen.order_failed) 1 else 0;
    }

    /// el setting `external_agent_limits`, igual que la cabina
    /// (c_api.zig). Un valor corrupto degrada a los defaults, nunca rompe.
    fn loadOrderExternalLimits(allocator: std.mem.Allocator, catalog: db.Connection) external_agents.Limits {
        const limits = external_agents.Limits{};
        const text = external_registry.readSetting(allocator, catalog, "external_agent_limits") catch return limits;
        defer allocator.free(text);
        return external_agents.Limits.fromJson(limits, allocator, text) catch limits;
    }

    /// catálogo externo cacheado (o refresco), como la cabina:
    /// caché con la hora de catalog.db y, si no hay, refresco; después las
    /// opciones que la cabina añade antes de despachar.
    fn loadOrderExternalCatalog(allocator: std.mem.Allocator, catalog: db.Connection, now: i64) ![]u8 {
        if (try external_registry.cached(allocator, catalog, now)) |cached_text| {
            defer allocator.free(cached_text);
            return external_registry.withOptions(allocator, catalog, cached_text);
        }
        const raw = try external_registry.refresh(allocator, catalog, null, null);
        defer allocator.free(raw);
        return external_registry.withOptions(allocator, catalog, raw);
    }

    /// r2: cablea el catálogo externo y los topes a un Superagent
    /// recién inicializado. Un único punto de cableado para que la resolución
    /// de modelo de cada tarea vea el mismo catálogo que la cabina.
    /// T7 (e): una orden lanzada desde la CLI lleva las mismas
    /// reglas del proyecto que desde la cabina (catalog.db del usuario).
    fn wireExternalCatalog(sa: *superagent.Superagent, catalog_json: ?[]const u8, limits: external_agents.Limits) void {
        sa.external_catalog_json = if (catalog_json) |json| json else null;
        sa.external_limits = limits;
    }

    /// carga y cableado comunes a order, design y driver.
    /// El caller conserva el JSON hasta terminar con sa y lo libera con sa.allocator.
    pub fn loadAndWireExternalCatalog(sa: *superagent.Superagent, catalog: ?db.Connection, quiet: bool) ?[]u8 {
        sa.rules_catalog = catalog;
        var catalog_json: ?[]u8 = null;
        var limits = external_agents.Limits{};
        if (catalog) |cat| {
            limits = loadOrderExternalLimits(sa.allocator, cat);
            catalog_json = loadOrderExternalCatalog(sa.allocator, cat, health.nowSeconds(cat)) catch |e| blk: {
                if (!quiet) std.debug.print("catálogo de agentes externos no disponible: {s}\n", .{@errorName(e)});
                break :blk null;
            };
        }
        wireExternalCatalog(sa, catalog_json, limits);
        return catalog_json;
    }

    fn addSessionAnswer(allocator: std.mem.Allocator, answers: *std.ArrayList(planner.ClarificationAnswer), id: []const u8, text: []const u8) !void {
        const copy = try allocator.dupe(u8, text);
        errdefer allocator.free(copy);
        for (answers.items) |*a| {
            if (std.mem.eql(u8, a.question_id, id)) {
                allocator.free(a.answer);
                a.answer = copy;
                return;
            }
        }
        const id_copy = try allocator.dupe(u8, id);
        errdefer allocator.free(id_copy);
        try answers.append(allocator, .{ .question_id = id_copy, .answer = copy });
    }

    /// QA-B H7: la consola dice qué CLI planificó por suscripción (y si rotó
    /// de cuenta); la cabina lo pinta con el evento `planner_cli_v1`.
    fn printSubscriptionPlanner(sub: *const direct_mode.SubscriptionPlanning, planned: bool) void {
        const who = sub.label() orelse return;
        // Si falló, el «Entendimiento» ya dice qué CLI respondió y por qué.
        if (planned) std.debug.print("Planificó {s} con tu suscripción: no hay clave de API ni modelo local.\n", .{who});
        const notes = std.mem.trim(u8, sub.rotationNotes(), " \r\n");
        if (notes.len > 0) std.debug.print("{s}\n", .{notes});
    }

    /// El cuerpo de `devagents order`. `quiet` lo usa el gate de aceptación, que
    /// corre decenas de órdenes y necesita el resultado, no el relato.
    fn runOrder(
        allocator: std.mem.Allocator,
        order_text: []const u8,
        lang_answer: ?[]const u8,
        approve: bool,
        forced_provider: ?[]const u8,
        forced_model: ?[]const u8,
        quiet: bool,
        /// M7: eleva los permisos SOLO para esta orden (ver `--sudo`).
        sudo: bool,
        /// M8: `"cli"` para lo que pide el usuario; el prefijo reservado
        /// (`session_store.INTERNAL_PROJECT_PREFIX`) para lo que lanza la
        /// maquinaria y no debe aparecer en su historial.
        project_id: []const u8,
        tui_session: bool,
    ) !OrderRunSummary {
        var resumen = OrderRunSummary{};
        const db_path = try paths.runtimeDb(allocator);
        defer allocator.free(db_path);
        const cat_path = try paths.catalogDb(allocator);
        defer allocator.free(cat_path);
        var runtime = db.Connection.open(allocator, db_path) catch {
            if (!quiet) std.debug.print("No se pudo abrir runtime.db.\n", .{});
            // r2: un corte ANTES de despachar no es un éxito:
            // la orden sale con código 1 (antes devolvía resumen vacío → 0).
            resumen.order_failed = true;
            return resumen;
        };
        defer runtime.close();
        const migrator = db.Migrator.init(allocator);
        // QA-A H1/H6: la causa de verdad (qué migración y por qué) y código 1,
        // no la traza de pila de un `try`.
        migrator.migrate(runtime, &db.runtime_schema) catch {
            if (!quiet) std.debug.print("No se pudo migrar runtime.db ({s}): {s}\n", .{ db_path, db.migrateFailureText() });
            resumen.order_failed = true;
            return resumen;
        };

        // Epoch desde SQLite: el nuevo std.Io del fork no expone reloj de pared
        // sin enhebrar `io`; la BD ya está abierta y es la fuente natural.
        const now = nowSeconds(runtime);

        // Router opcional: solo si catalog.db tiene modelos disponibles.
        // QA-A H6: con una carpeta nueva catalog.db se abría SIN migrar y la
        // orden avisaba «Reglas del proyecto ilegibles (PrepareFailed)» y
        // «catálogo de agentes externos no disponible: PrepareFailed».
        var catalog: ?db.Connection = db.Connection.open(allocator, cat_path) catch |e| blk: {
            if (!quiet) std.debug.print("catalog.db no se pudo abrir ({s}); la orden sigue sin catálogo de modelos.\n", .{@errorName(e)});
            break :blk null;
        };
        defer if (catalog) |*c| c.close();
        if (catalog) |cat| {
            migrator.migrate(cat, &db.catalog_schema) catch {
                if (!quiet) std.debug.print("No se pudo migrar catalog.db ({s}): {s}\n", .{ cat_path, db.migrateFailureText() });
                resumen.order_failed = true;
                return resumen;
            };
        }
        var router_storage: model_router.Router = undefined;
        var router_ptr: ?*model_router.Router = null;
        // Ver el comentario de la misma fuga en c_api.zig.
        defer if (router_ptr) |r| r.deinitHealthCache();
        if (catalog) |cat| {
            if (catalogHasModels(cat)) {
                router_storage = model_router.Router.init(allocator, cat, null, now);
                router_storage.setHealthConn(runtime); // HEALTH-03: sesga por salud (runtime.db)
                router_ptr = &router_storage;
            }
        }

        // Planificador VIVO (LLM real con clave en catalog.db). QA-B H7: sin
        // clave de API ni modelo local planifica la CLI con suscripción (como
        // Directo); si no hay ninguna, el plan falla diciendo por qué.
        var lp = live_planner.LlmPlanner.init(allocator, cat_path);
        lp.forced_provider = forced_provider;
        lp.forced_model = forced_model;
        var sub_planning = direct_mode.SubscriptionPlanning.init(allocator);
        defer sub_planning.deinit();
        const pb = lp.backend();
        defer pb.deinit();

        var mem_bundle = engram_memory.initFromEnv(allocator, runtime);
        defer mem_bundle.deinit();

        var sa = superagent.Superagent.init(allocator, runtime, router_ptr, mem_bundle.backend(), now);
        const external_catalog = loadAndWireExternalCatalog(&sa, catalog, quiet);
        defer if (external_catalog) |text| allocator.free(text);
        sub_planning.external.catalog_json = external_catalog;
        sub_planning.external.catalog_conn = catalog;
        sub_planning.external.event_conn = runtime;
        lp.subscription = sub_planning.subscriptionPlanner();
        // mismo campo de orden que la cabina. La TUI entrega
        // la aprobación por el protocolo existente; --yes ya es autorización.
        sa.wait_for_plan_approval = tui_session or !approve;
        sa.setForcedModel(forced_provider, forced_model);

        // M7: sudo POR CASO. Eleva los permisos de ESTA orden y de ninguna mas.
        //
        // El modo de permisos era global: para dejar pasar un comando habia que
        // cambiarlo en Configuracion y —lo importante— acordarse de volver a
        // bajarlo. Nadie se acuerda. Un permiso que hay que revocar a mano deja
        // de ser un permiso y pasa a ser el estado por defecto.
        //
        // Aqui vive y muere con la invocacion: no se persiste en ningun sitio,
        // asi que la siguiente orden vuelve a `normal` sola. La DENYLIST sigue
        // mandando por encima (ver `executor.checkPrefix`): `--sudo` salta la
        // pregunta, no las prohibiciones.
        if (sudo) {
            sa.permission_config.mode = .bypass;
            if (!quiet) std.debug.print("SUDO: permisos elevados para ESTA orden (la denylist sigue vigente).\n", .{});
        }

        var answers: std.ArrayList(planner.ClarificationAnswer) = .empty;
        defer {
            for (answers.items) |a| {
                allocator.free(a.question_id);
                allocator.free(a.answer);
            }
            answers.deinit(allocator);
        }
        if (lang_answer) |la| {
            try addSessionAnswer(allocator, &answers, "target-language", la);
        }

        var outcome = sa.processOrder(project_id, order_text, answers.items, pb, null, null) catch |e| {
            if (!quiet) std.debug.print("No se pudo procesar la orden: {s}\n", .{@errorName(e)});
            // r2: orden no procesada = orden fallida, no vacía.
            resumen.order_failed = true;
            return resumen;
        };
        defer outcome.deinit();
        resumen.order_id = outcome.order_id;
        if (!quiet) printSubscriptionPlanner(&sub_planning, outcome.plan.kind != .failed);

        var clarification_rounds: usize = 0;
        while (outcome.plan.needsClarification()) {
            if (!quiet) std.debug.print("Entendimiento: {s}\n\n", .{outcome.plan.understanding});
            if (!quiet) std.debug.print("Se requiere clarificación (responde con --answer <id>=<valor>):\n", .{});
            if (tui_session and clarification_rounds == 8) {
                std.debug.print("No se pudo resolver la aclaración tras 8 rondas. Edita la orden.\n", .{});
                return error.ClarifyRoundsExhausted;
            }
            for (outcome.plan.questions) |q| {
                if (!quiet) std.debug.print("  [{s}] {s}\n", .{ q.id, q.text });
                for (q.options) |opt| std.debug.print("      - {s}\n", .{opt});
                if (tui_session) {
                    std.debug.print("{s}\n", .{tui_interaction.ANSWER});
                    const reply = try tui_interaction.readReply(allocator);
                    defer allocator.free(reply);
                    if (!std.mem.startsWith(u8, reply, "answer ") or std.mem.trim(u8, reply[7..], " \t").len == 0)
                        return resumen;
                    try addSessionAnswer(allocator, &answers, q.id, reply[7..]);
                }
            }
            if (!tui_session) return resumen;
            clarification_rounds += 1;
            // Libera cada resultado, manteniendo válido el defer también si falla el siguiente.
            const next = try sa.processOrder(project_id, order_text, answers.items, pb, null, null);
            outcome.deinit();
            outcome = next;
            resumen.order_id = outcome.order_id;
        }

        if (!quiet) std.debug.print("Entendimiento: {s}\n\n", .{outcome.plan.understanding});

        // Modo charla: el superagente entendió la intención como conversación (saludo,
        // pregunta, feedback) y no generó tareas. El "Entendimiento" YA es la respuesta;
        // no hay plan que mostrar ni que aprobar.
        if (outcome.plan.tasks.len == 0) {
            // QA-A H6: «No pude planificar: …» (sin clave, proveedores caídos,
            // cupo de pago agotado) es un plan FALLIDO, no una charla: el
            // Entendimiento ya dijo la causa; la orden sale con código 1.
            if (outcome.plan.kind == .failed) resumen.order_failed = true;
            return resumen;
        }

        if (!quiet) {
            if (tui_session) std.debug.print("PLAN PROPUESTO (orden #{d}):\n", .{outcome.order_id}) else std.debug.print("Plan (orden #{d}):\n", .{outcome.order_id});
        }
        for (outcome.plan.tasks, 1..) |pt, task_number| {
            const asg = findAssignmentByTask(outcome.assignments, pt.id);
            if (tui_session and !quiet) std.debug.print("{d}. ", .{task_number});
            if (!quiet) std.debug.print("  [{s}] {s} ({s}) → {s}/{s}\n", .{
                pt.id,                                          pt.description,                              pt.task_type.toText(),
                if (asg) |a| a.provider_name else "sin-modelo", if (asg) |a| a.model_name else "sin-modelo",
            });
            if (tui_session and !quiet) {
                for (pt.owns) |file| std.debug.print("     Archivo: {s}\n", .{file});
                if (pt.deliverable) |file| std.debug.print("     Entregable: {s}\n", .{file});
            }
        }

        if (tui_session) {
            std.debug.print("{s}\n", .{tui_interaction.APPROVE});
            const reply = try tui_interaction.readReply(allocator);
            defer allocator.free(reply);
            if (!tui_interaction.approved(reply)) return resumen;
        } else if (!approve) {
            if (!quiet) std.debug.print("\nUsa --yes para aprobar y despachar el plan.\n", .{});
            return resumen;
        }
        // / P-EXEC-6: `--yes` ES la autorización del plan, igual que
        // `da_order_approve` en la cabina (c_api.zig, `sup.plan_approved = true`).
        // Sin esta línea el CLI divergía del otro camino: cada `python`/`node`
        // que el motor lanzaba sobre el artefacto caía en `.ask`, generaba una
        // aprobación de ejecución y dejaba la orden en `awaiting_approval` con
        // TODAS sus tareas `completed` y los archivos ya en disco. Medido el
        // 2026-08-15 sobre runtime.db: 54 órdenes atascadas así (#334, #335,
        // #331, #327...). La denylist sigue mandando: `checkPrefix` la comprueba
        // aparte y esa sí genera aprobación.
        sa.plan_approved = true;

        // TRAZA-CLI: engancha la conexión de eventos, igual que hace la cabina en
        // `da_order_approve` (c_api.zig). Sin esto el CLI despachaba CIEGO: cero
        // eventos, cero deltas y cero volcados de depuración (`maybeDumpCallTrace`
        // se corta con `order_id <= 0`), así que `devagents debug <id>` de una
        // orden lanzada por CLI mostraba un único `order_failed` sin causa.
        //
        // Ese agujero es el que obligaba a inspeccionar TODO desde la cabina: los
        // dos caminos ejecutan el mismo superagente, pero solo uno dejaba rastro.
        sa.setEventConn(runtime, outcome.order_id);

        // Ejecución VIVA: con clave en catalog.db despacha a un LLM real; si no, al mock.
        var live_opt = live_worker.LiveLlm.init(allocator, cat_path);
        // Registro PASIVO de salud (HEALTH-03): cada intento del fallback vivo marca
        // model_health en runtime.db, igual que el despacho de la GUI (da_order_approve).
        if (live_opt) |*l| {
            l.setHealthConn(runtime);
            l.setEventConn(runtime, outcome.order_id);
            l.reorderByHealth();
        }
        defer if (live_opt) |*l| l.deinit();
        if (live_opt) |*l| {
            var sbuf: [256]u8 = undefined;
            if (!quiet) std.debug.print("\nDespachando a workers con LLM VIVO (fallback free-first): {s}\n", .{l.summary(&sbuf)});
        } else {
            if (!quiet) std.debug.print("\nSin clave configurada en catalog.db → despacho con MockWorker.\n", .{});
        }
        var dr = (if (live_opt) |*l|
            sa.approveAndDispatch(&outcome, live_worker.LiveLlm.llmFn, l, cat_path)
        else
            sa.approveAndDispatch(&outcome, null, null, null)) catch |e| {
            if (!quiet) std.debug.print("Fallo al despachar: {s}\n", .{@errorName(e)});
            // r2: despacho fallido también cierra con order_failed.
            resumen.order_failed = true;
            return resumen;
        };
        defer dr.deinit(allocator);
        for (dr.outputs) |so| {
            if (!quiet) std.debug.print("\n[worker:{s} / {s}]\n{s}\n", .{ so.worker_id, so.stream, so.text });
        }
        if (!quiet) std.debug.print("\n{s}", .{dr.report});
        if (dr.pending_approvals.len > 0) {
            if (!quiet) std.debug.print("\nAprobaciones pendientes: {d}\n", .{dr.pending_approvals.len});
            // (2ª mitad): lo que queda pendiente tras `plan_approved` es
            // denylist — y hay que poder resolverlo. La cabina ya escribía la
            // fila (c_api.zig `insertApprovalToDb`); el CLI no, así que la orden
            // quedaba en `awaiting_approval` sin nada que aprobar por ninguna de
            // las dos vías. Best-effort: si la escritura falla se avisa, pero no
            // se tumba el despacho, que ya terminó.
            const now_ms = health.nowMillis(runtime);
            for (dr.pending_approvals) |req| {
                _ = superagent.persistApprovalRequest(runtime, req, outcome.order_id, now_ms) catch |e| {
                    if (!quiet) std.debug.print("  aviso: no se pudo registrar la aprobación de {s}: {s}\n", .{ req.task_id, @errorName(e) });
                    continue;
                };
            }
        }
        // E3: la sesión TUI recibe la traza del despacho como avisos de avance
        // (`\x1eDA2:task` / `\x1eDA2:file`). El despacho ya terminó: el flujo
        // actual no tiene canal vivo DURANTE la ejecución (v. informe E3).
        if (tui_session and !quiet) emitTuiProgress(allocator, runtime, outcome.order_id);
        resumen.dispatched = true;
        resumen.completed = dr.completed_count;
        resumen.failed = dr.failed_count;
        resumen.order_failed = dr.order_failed;
        resumen.pending_approvals = dr.pending_approvals.len;
        return resumen;
    }

    /// Vuelca la traza recién escrita como avisos de avance para la sesión TUI.
    /// Por tarea emite un cierre (`task <id> ok|failed <inicio> <fin> <modelo>`)
    /// con el inicio tomado del `task_started` del mismo task_id, y por archivo
    /// escrito (`file <id> <ruta>`). Solo lectura de la BD y de stdout/stderr.
    fn emitTuiProgress(allocator: std.mem.Allocator, runtime: db.Connection, order_id: i64) void {
        var trace = order_trace.loadTrace(allocator, runtime, order_id) catch return;
        defer trace.deinit();
        var starts = std.StringHashMap(i64).init(allocator);
        defer {
            var it = starts.keyIterator();
            while (it.next()) |k| allocator.free(k.*);
            starts.deinit();
        }
        for (trace.events.items) |ev| {
            if (ev.task_id.len == 0) continue;
            if (std.mem.eql(u8, ev.kind, "task_started")) {
                const key = allocator.dupe(u8, ev.task_id) catch continue;
                if (starts.fetchRemove(ev.task_id)) |kv| allocator.free(kv.key);
                starts.put(key, ev.ts) catch allocator.free(key);
                continue;
            }
            const done = std.mem.eql(u8, ev.kind, "task_done");
            const failed = std.mem.eql(u8, ev.kind, "task_failed");
            if (done or failed) {
                const start = starts.get(ev.task_id) orelse ev.ts;
                var idbuf: [512]u8 = undefined;
                var modelbuf: [512]u8 = undefined;
                std.debug.print("{s} {s} {s} {d} {d} {s}\n", .{
                    tui_interaction.TASK,
                    cleanProtocolText(&idbuf, ev.task_id),
                    if (done) "ok" else "failed",
                    start,
                    ev.ts,
                    cleanProtocolText(&modelbuf, if (ev.model_used.len > 0) ev.model_used else "-"),
                });
                continue;
            }
            if (std.mem.eql(u8, ev.kind, "file_written")) {
                var idbuf: [512]u8 = undefined;
                var pathbuf: [1024]u8 = undefined;
                std.debug.print("{s} {s} {s}\n", .{
                    tui_interaction.FILE,
                    cleanProtocolText(&idbuf, ev.task_id),
                    cleanProtocolText(&pathbuf, ev.file_path),
                });
            }
        }
    }

    /// Sustituye CR/LF por espacios (el protocolo es de líneas completas). Si
    /// no cabe en el búfer se trunca: mejor una ruta corta que un protocolo roto.
    fn cleanProtocolText(buf: []u8, s: []const u8) []const u8 {
        const n = @min(s.len, buf.len);
        for (s[0..n], 0..) |c, i| buf[i] = if (c == '\n' or c == '\r') ' ' else c;
        return buf[0..n];
    }

    // ── Gate de aceptación (`devagents selftest`) ─────────────────────────
    //
    // Por qué existe, dicho sin rodeos: la suite tiene ~780 pruebas en verde y
    // NINGUNA cazó los fallos de esta semana. Un `index.html` correcto rechazado
    // por un campo `filename`; el CLI despachando sin dejar traza; los artefactos
    // cayendo en la raíz del repositorio; `empty` tapando respuestas que sí
    // llegaron. Todos vivían en las costuras —planificador ↔ contrato ↔ disco↔
    // interfaz—, y las pruebas unitarias no miran costuras: miran piezas.
    //
    // Lo que hace este gate es lo único que las habría cazado: lanza órdenes de
    // verdad y **comprueba el disco**, no el informe. Si el motor dice «1
    // completada» y no hay archivo, es FALLO. Si el archivo existe pero está
    // vacío o le faltan los que él mismo enlaza, es FALLO.
    //
    // Es lento a propósito (habla con proveedores reales). Es el precio de que
    // «funciona» signifique algo.

    pub const CasoGate = struct {
        nombre: []const u8,
        orden: []const u8,
        /// Extensiones aceptables del entregable principal.
        exts: []const []const u8,
        /// Bytes mínimos para no dar por bueno un archivo simbólico.
        min_bytes: u64,
        /// Fragmentos que deben aparecer en alguno de los archivos.
        debe_contener: []const []const u8,
        /// Archivos mínimos esperados en la carpeta de la orden.
        min_archivos: usize = 1,
    };

    /// Los cuatro moldes que han roto algo alguna vez. No son ejemplos bonitos:
    /// cada uno reproduce una regresión concreta ya vivida.
    const CASOS_GATE = [_]CasoGate{
        .{
            // Orden #213: entrega correcta rechazada por el contrato.
            .nombre = "web-1archivo",
            .orden = "Crea index.html con un contador que suba y baje al pulsar dos botones",
            .exts = &.{".html"},
            .min_bytes = 400,
            .debe_contener = &.{ "<button", "</html>" },
        },
        .{
            // Orden #184: un index.html que enlazaba dos archivos inexistentes.
            .nombre = "web-multiarchivo",
            .orden = "Crea una web de lista de tareas con TRES archivos separados: index.html, styles.css y script.js",
            .exts = &.{".html"},
            .min_bytes = 300,
            .debe_contener = &.{"<body"},
            .min_archivos = 2,
        },
        .{
            // Orden #183: tres archivos concatenados dentro de un solo `.js`.
            .nombre = "python",
            .orden = "Escribe un script de Python que imprima los primeros 20 numeros primos",
            .exts = &.{".py"},
            .min_bytes = 80,
            .debe_contener = &.{"print"},
        },
        .{
            // S9: una tarea de prosa no debe salir con extensión de código.
            // Orden #284: el gate la dio por BUENA entregando un CHANGELOG de 111
            // bytes y un ROADMAP de 134 —el acta de que el documento existe, no
            // el documento—. Era el UNICO caso sin asercion de contenido y con
            // un umbral que cualquier linea suelta superaba.
            .nombre = "prosa",
            .orden = "Documenta brevemente en un texto los riesgos de guardar claves de API en texto plano",
            .exts = &.{ ".md", ".txt" },
            .min_bytes = 500,
            .debe_contener = &.{ "API", "texto plano" },
        },
    };

    const ResultadoGate = struct {
        caso: []const u8,
        order_id: i64,
        paso: bool,
        motivo: []const u8, // prestado o estático; no se libera
        archivos: usize,
        bytes: u64,
        /// el motivo de ejecución puede necesitar formato (nombre del
        /// archivo, exit code). Se escribe AQUÍ, en un buffer por instancia que
        /// vive con la fila, para que `motivo` siga siendo prestado sin fuga.
        motivo_buf: [256]u8 = undefined,
    };

    fn extensionAceptable(nombre: []const u8, exts: []const []const u8) bool {
        const ext = std.fs.path.extension(nombre);
        for (exts) |e| {
            if (std.ascii.eqlIgnoreCase(ext, e)) return true;
        }
        return false;
    }

    fn cmdSelfTest(allocator: std.mem.Allocator, solo_caso: ?[]const u8) !void {
        std.debug.print("=== Gate de aceptacion — ordenes REALES, verificadas en DISCO ===\n\n", .{});
        if (model_roster.fromEnv()) |spec| {
            std.debug.print("Roster en vigor: {s}\n", .{spec});
        }
        std.debug.print("CASO | ORDEN | ARCHIVOS | BYTES | VEREDICTO\n", .{});
        std.debug.print("-----|-------|----------|-------|----------\n", .{});

        var pasaron: usize = 0;
        var corridos: usize = 0;
        var fallos = std.ArrayList(ResultadoGate).empty;
        defer fallos.deinit(allocator);

        for (CASOS_GATE) |caso| {
            if (solo_caso) |sc| {
                if (!std.mem.eql(u8, sc, caso.nombre)) continue;
            }
            corridos += 1;
            var res = ResultadoGate{
                .caso = caso.nombre,
                .order_id = 0,
                .paso = false,
                .motivo = "",
                .archivos = 0,
                .bytes = 0,
            };

            const resumen = runOrder(allocator, caso.orden, null, true, null, null, true, false, session_store.SELFTEST_PROJECT, false) catch |e| {
                res.motivo = @errorName(e);
                fallos.append(allocator, res) catch {};
                std.debug.print("{s} | - | 0 | 0 | FALLO ({s})\n", .{ caso.nombre, res.motivo });
                continue;
            };
            res.order_id = resumen.order_id;

            // LO QUE IMPORTA: el disco, no el informe. Aqui es donde una orden
            // que se declara completada sin entregar nada se cae.
            const archivos = workspace.listOrderFiles(allocator, resumen.order_id) catch &[_]workspace.OrderFile{};
            defer {
                for (archivos) |f| f.deinit(allocator);
                allocator.free(archivos);
            }
            res.archivos = archivos.len;
            for (archivos) |f| res.bytes += f.size;

            if (archivos.len < caso.min_archivos) {
                res.motivo = if (archivos.len == 0) "sin archivos en disco" else "menos archivos de los pedidos";
            } else {
                var hay_principal = false;
                for (archivos) |f| {
                    if (esInformeDeAuditoria(allocator, resumen.order_id, f.name)) continue;
                    if (extensionAceptable(f.name, caso.exts) and f.size >= caso.min_bytes) {
                        hay_principal = true;
                        break;
                    }
                }
                if (!hay_principal) {
                    res.motivo = "ningun ENTREGABLE con la extension esperada y tamaño minimo (el informe del auditor no cuenta)";
                } else {
                    res.motivo = try comprobarContenido(allocator, resumen.order_id, archivos, caso);
                    if (res.motivo.len == 0) {
                        // disco y contenido bien, ahora EJECUTAR. Un gate
                        // que mira el disco pero no corre nada dio PASA durante
                        // tres órdenes con la entrega rota.
                        res.motivo = ejecutarEntregable(allocator, resumen.order_id, archivos, caso, &res.motivo_buf);
                    }
                    res.paso = res.motivo.len == 0;
                }
            }

            if (res.paso) pasaron += 1 else fallos.append(allocator, res) catch {};
            std.debug.print("{s} | #{d} | {d} | {d} | {s}\n", .{
                caso.nombre,
                res.order_id,
                res.archivos,
                res.bytes,
                if (res.paso) "PASA" else "FALLO",
            });
            if (!res.paso and res.motivo.len > 0) {
                std.debug.print("     └─ {s}\n", .{res.motivo});
            }
        }

        std.debug.print("\n{d} de {d} casos PASAN.\n", .{ pasaron, corridos });

        // R14: un filtro que casa CERO elementos es FALLO, nunca aprobado.
        // Medido el 2026-08-15: `selftest --caso 3` imprimia «0 de 0 casos
        // PASAN» y salia con codigo 0 — el gate de aceptacion del proyecto
        // daba verde sin haber ejecutado nada. `--caso` toma el NOMBRE del
        // caso, no un numero; la ayuda decia `<n>` e invitaba al error.
        if (corridos == 0) {
            std.debug.print("\nFALLO: el filtro --caso no caso con ningun caso. Nombres validos:\n", .{});
            for (CASOS_GATE) |c| std.debug.print("  {s}\n", .{c.nombre});
            console_cp.exit(1);
        }

        if (pasaron < corridos) {
            std.debug.print("\nPara ver por que fallo cada uno:\n", .{});
            for (fallos.items) |f| {
                if (f.order_id > 0) std.debug.print("  devagents debug {d}\n", .{f.order_id});
            }
            // El gate no podia tumbar a nadie: terminaba en 0 aunque fallaran
            // los cuatro casos. Un gate que no falla no es un gate — y el hook
            // de pre-commit y cualquier CI comprueban el codigo de salida.
            console_cp.exit(1);
        }
    }

    /// Abre los archivos entregados y comprueba los fragmentos exigidos.
    ///
    /// Contar archivos y mirar su tamaño no basta: la orden #183 entregó un
    /// `.js` de 2.605 bytes que eran tres archivos concatenados, y por tamaño y
    /// extensión habría pasado el gate. Hay que abrir y mirar dentro.
    ///
    /// Devuelve "" si todo esta bien, o el motivo del fallo.
    /// ¿Este archivo es el informe del auditor, y no el entregable?
    ///
    /// El auditor escribe su veredicto en un artefacto propio que empieza por
    /// `AUDIT_REPORT` (ver `quality_pipeline`). Contarlo como entregable es el
    /// agujero que dejó pasar la orden #284: basta con que el auditor escriba
    /// largo y mencione el tema para que el gate dé por entregado un documento
    /// que nunca se escribió. Un informe de auditoría es la PRUEBA sobre el
    /// entregable; nunca el entregable.
    fn esInformeDeAuditoria(allocator: std.mem.Allocator, order_id: i64, name: []const u8) bool {
        const cuerpo = (workspace.readOrderFile(allocator, order_id, name) catch null) orelse return false;
        defer allocator.free(cuerpo);
        // El marcador va al principio del informe; 64 bytes de margen
        // absorben cualquier salto de linea o espacio que meta el modelo.
        const cabeza = cuerpo[0..@min(cuerpo.len, 64)];
        // Dos grafias, porque los modelos usan las dos: `AUDIT_REPORT`
        // (la del pipeline) y `AUDIT REPORT` con espacio. La orden #298
        // entrego un index.html que empezaba por "AUDIT REPORT: Task List
        // Application / Status: FAIL" — el informe del auditor ESCRITO
        // ENCIMA del entregable.
        return std.mem.indexOf(u8, cabeza, "AUDIT_REPORT") != null or
            std.mem.indexOf(u8, cabeza, "AUDIT REPORT") != null;
    }

    fn comprobarContenido(allocator: std.mem.Allocator, order_id: i64, archivos: []const workspace.OrderFile, caso: CasoGate) ![]const u8 {
        if (caso.debe_contener.len == 0) return "";
        for (caso.debe_contener) |frag| {
            var encontrado = false;
            for (archivos) |f| {
                if (esInformeDeAuditoria(allocator, order_id, f.name)) continue;
                const cuerpo = (workspace.readOrderFile(allocator, order_id, f.name) catch null) orelse continue;
                defer allocator.free(cuerpo);
                if (std.mem.indexOf(u8, cuerpo, frag) != null) {
                    encontrado = true;
                    break;
                }
            }
            if (!encontrado) return "el entregable no contiene lo esperado";
        }
        return "";
    }

    /// — el gate EJECUTA lo que entrega.
    ///
    /// Contar archivos, medir bytes y buscar fragmentes dio `PASA` mientras la
    /// orden decía `failed`: el caso `web-multiarchivo` no podía cerrar en
    /// verde por diseño y nadie lo vio tres órdenes seguidas, porque el
    /// instrumento miraba el disco y no el comportamiento.
    ///
    /// Qué se ejecuta, por tipo de entregable principal:
    ///   · `.py`  → `python <f>` y exigir exit 0.
    ///   · `.js`  → `node <f>` SOLO si no es un script de navegador (mismo
    /// criterio `isBrowserScript` del motor, ejecutar un JS
    ///              de navegador con node no prueba nada y tumba la orden).
    ///   · `.html`→ los archivos que referencia tienen que existir en la
    ///              carpeta de la orden (el hueco de la #184: un index.html
    ///              que enlazaba styles.css y script.js inexistentes).
    ///   · `.md`/`.txt` → nada que ejecutar; no es un fallo ni un SKIP mudo:
    ///              se devuelve "no ejecutable" y el motivo queda en el log.
    ///
    /// Devuelve "" si el entregable ejecuta bien (o es prosa), o escribe el
    /// motivo del fallo en `buf` y lo devuelve. Un gate que no puede ejecutar
    /// lo que dice ejecutar lo DECLARA, no lo disimula (R14).
    pub fn ejecutarEntregable(allocator: std.mem.Allocator, order_id: i64, archivos: []const workspace.OrderFile, caso: CasoGate, buf: []u8) []const u8 {
        // El entregable principal: primera pieza con la extensión esperada del
        // caso, sin contar el informe del auditor (mismo criterio que arriba).
        var principal: ?workspace.OrderFile = null;
        for (archivos) |f| {
            if (esInformeDeAuditoria(allocator, order_id, f.name)) continue;
            if (extensionAceptable(f.name, caso.exts) and f.size >= caso.min_bytes) {
                principal = f;
                break;
            }
        }
        const p = principal orelse return "sin entregable principal";

        const ext = std.fs.path.extension(p.name);

        // HTML: comprobar que cada archivo local que referencia existe en la
        // carpeta de la orden (el hueco de la #184: un index.html que enlazaba
        // styles.css y script.js inexistentes).
        if (std.ascii.eqlIgnoreCase(ext, ".html")) {
            const cuerpo = (workspace.readOrderFile(allocator, order_id, p.name) catch null) orelse return "no se pudo leer el HTML";
            defer allocator.free(cuerpo);
            return verificarReferenciasHtml(cuerpo, archivos, buf);
        }

        // Prosa: no ejecutable por diseño del caso.
        if (std.ascii.eqlIgnoreCase(ext, ".md") or std.ascii.eqlIgnoreCase(ext, ".txt")) {
            return ""; // no ejecutable: no es fallo. El caso de prosa valida contenido, no ejecución.
        }

        // Python y JS de servidor: ejecutar de verdad, con la MISMA gobernanza
        // que el motor (allowlist + sandbox + ruta absoluta del PATH). El cwd
        // es la carpeta de la orden, que ya está dentro del workspace.
        if (std.ascii.eqlIgnoreCase(ext, ".py") or std.ascii.eqlIgnoreCase(ext, ".js")) {
            if (std.ascii.eqlIgnoreCase(ext, ".js")) {
                const cuerpo = (workspace.readOrderFile(allocator, order_id, p.name) catch null) orelse return "no se pudo leer el JS";
                defer allocator.free(cuerpo);
                if (esBrowserScript(cuerpo)) {
                    // Mismo veredicto que el motor: declararlo, no
                    // ejecutarlo con el intérprete equivocado.
                    return ""; // no ejecutable con node: no es fallo del entregable
                }
            }

            var er_buf: [4096]u8 = undefined;
            const ws_abs = workspace.effectiveRoot(&er_buf);
            const dir = std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "orden-{d}", .{ ws_abs, order_id }) catch return "OOM dir orden";
            defer allocator.free(dir);
            const full = std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ dir, p.name }) catch return "OOM ruta";
            defer allocator.free(full);

            const exe = if (std.ascii.eqlIgnoreCase(ext, ".py")) "python" else "node";
            const policy = executor.Policy{
                .origin = .local,
                .timeout_ms = 30_000,
                .workspace_root = ws_abs,
            };
            const res = executor.runGoverned(allocator, policy, exe, &.{full}, dir, null, null, null) catch |e| {
                return std.fmt.bufPrint(buf, "no se pudo lanzar {s}: {s}", .{ exe, @errorName(e) }) catch "no se pudo lanzar";
            };
            defer {
                allocator.free(res.stdout);
                allocator.free(res.stderr);
            }
            if (res.exit_code != 0) {
                return std.fmt.bufPrint(buf, "{s} salio con exit {d}", .{ exe, res.exit_code }) catch "ejecucion fallida";
            }
            return "";
        }

        return ""; // extensión sin regla de ejecución en el gate: el contenido ya se validó
    }

    /// los `src="..."` / `href="..."` LOCALES de un HTML tienen que
    /// apuntar a archivos entregados en la misma carpeta. Es exactamente el
    /// hueco de la orden #184: el HTML enlazaba styles.css y script.js que
    /// nadie escribió, y el gate los dio por buenos porque el index.html
    /// tenía bytes y fragmentos.
    fn verificarReferenciasHtml(cuerpo: []const u8, archivos: []const workspace.OrderFile, buf: []u8) []const u8 {
        var i: usize = 0;
        while (i < cuerpo.len) {
            // Buscar la siguiente referencia src=/href= (gracias al case
            // insensible del tag no distinguimos mayúsculas: los modelos
            // escriben las dos).
            const pos = std.mem.indexOfAnyPos(u8, cuerpo, i, "sh") orelse break;
            const es_src = std.mem.startsWith(u8, cuerpo[pos..], "src=");
            const es_href = std.mem.startsWith(u8, cuerpo[pos..], "href=");
            if (!es_src and !es_href) {
                i = pos + 1;
                continue;
            }
            const clave_len: usize = if (es_src) 4 else 5;
            const valor_inicio = pos + clave_len;
            if (valor_inicio >= cuerpo.len) break;
            const comilla = cuerpo[valor_inicio];
            if (comilla != '"' and comilla != '\'') {
                i = pos + 1;
                continue;
            }
            const cierre = std.mem.indexOfScalarPos(u8, cuerpo, valor_inicio + 1, comilla) orelse {
                i = pos + 1;
                continue;
            };
            const destino = cuerpo[valor_inicio + 1 .. cierre];
            i = cierre + 1;

            // Solo referencias RELATIVAS locales: http(s)://, data:, # y
            // rutas absolutas no son entregables del gate.
            if (destino.len == 0) continue;
            if (std.mem.startsWith(u8, destino, "http://") or std.mem.startsWith(u8, destino, "https://")) continue;
            if (std.mem.startsWith(u8, destino, "//") or std.mem.startsWith(u8, destino, "#")) continue;
            if (std.mem.startsWith(u8, destino, "data:")) continue;
            if (destino[0] == '/' or destino[0] == '\\') continue;
            // Quita el query/hash del nombre de archivo si lo lleva.
            var nombre = destino;
            if (std.mem.indexOfScalar(u8, nombre, '?')) |q| nombre = nombre[0..q];
            if (std.mem.indexOfScalar(u8, nombre, '#')) |h| nombre = nombre[0..h];
            if (nombre.len == 0) continue;

            var existe = false;
            for (archivos) |f| {
                if (std.ascii.eqlIgnoreCase(f.name, nombre)) {
                    existe = true;
                    break;
                }
            }
            if (!existe) {
                return std.fmt.bufPrint(buf, "el HTML referencia '{s}' y no fue entregado", .{nombre}) catch "referencia sin entregar";
            }
        }
        return "";
    }

    /// (mismo criterio que superagent.isBrowserScript, replicado aquí
    /// porque cli.zig no puede importar superagent sin ciclo): un JS con
    /// `document.` o `window.` es de navegador y no se ejecuta con node.
    fn esBrowserScript(cuerpo: []const u8) bool {
        if (std.mem.indexOf(u8, cuerpo, "document.") != null) return true;
        if (std.mem.indexOf(u8, cuerpo, "window.") != null) return true;
        return false;
    }

    /// Modo de gobernanza desde el CLI. Existe porque no habia forma de
    /// cambiarlo sin abrir la cabina, y el gate de aceptacion necesita correr
    /// los cuatro modos para responder si free/paid/hibrido funcionan de
    /// verdad o solo estan declarados.
    ///
    /// Es el MISMO ajuste que lee el router (`settings.governance_mode` de
    /// catalog.db), no una copia: cambiarlo aqui cambia el comportamiento de la
    /// cabina, y al reves.
    /// H6 — lo que la cache del proveedor ha ahorrado, medido.
    ///
    /// `prompt_tokens` no distingue un acierto de un fallo de cache: el
    /// proveedor cuenta los mismos tokens y cobra menos. La cifra que hay que
    /// mirar es `cached_tokens` sobre `prompt_tokens`, y por modelo, porque
    /// cada familia cachea con reglas distintas (Anthropic exige declarar el
    /// corte; Gemini y los OpenAI-compatible lo hacen solos si el prefijo no
    /// cambia).
    fn cmdUsage(allocator: std.mem.Allocator) !void {
        // QA-A H6: antes abría sin migrar; con una carpeta nueva decía «No se
        // pudo leer usage_records.» y salía con 0.
        var rt = abrirBase(allocator, .runtime);
        defer rt.close();

        const stmt = rt.prepare(
            "SELECT provider, model, COUNT(*), SUM(prompt_tokens), SUM(cached_tokens), SUM(completion_tokens) " ++
                "FROM usage_records GROUP BY provider, model ORDER BY SUM(prompt_tokens) DESC",
        ) catch |e| falla("No se pudo leer usage_records: {s}", .{@errorName(e)});
        defer rt.finalize(stmt);

        std.debug.print("\nConsumo por modelo (runtime.db)\n", .{});
        std.debug.print("{s:<12} {s:<34} {s:>6} {s:>9} {s:>9} {s:>8} {s:>9}\n", .{ "PROVEEDOR", "MODELO", "LLAM.", "PROMPT", "CACHE", "% CACHE", "SALIDA" });

        var total_prompt: i64 = 0;
        var total_cached: i64 = 0;
        var filas: usize = 0;
        while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            filas += 1;
            const provider = if (db.c.sqlite3_column_text(stmt, 0)) |t| std.mem.span(t) else "";
            const model = if (db.c.sqlite3_column_text(stmt, 1)) |t| std.mem.span(t) else "";
            const calls = db.c.sqlite3_column_int64(stmt, 2);
            const prompt = db.c.sqlite3_column_int64(stmt, 3);
            const cached = db.c.sqlite3_column_int64(stmt, 4);
            const out = db.c.sqlite3_column_int64(stmt, 5);
            total_prompt += prompt;
            total_cached += cached;
            const pct: f64 = if (prompt > 0) @as(f64, @floatFromInt(cached)) * 100.0 / @as(f64, @floatFromInt(prompt)) else 0.0;
            std.debug.print("{s:<12} {s:<34} {d:>6} {d:>9} {d:>9} {d:>7.1}% {d:>9}\n", .{ provider, model, sinSigno(calls), sinSigno(prompt), sinSigno(cached), pct, sinSigno(out) });
        }

        if (filas == 0) {
            std.debug.print("  (sin registros de consumo todavia)\n", .{});
            return;
        }
        const pct_total: f64 = if (total_prompt > 0) @as(f64, @floatFromInt(total_cached)) * 100.0 / @as(f64, @floatFromInt(total_prompt)) else 0.0;
        std.debug.print("\nTOTAL prompt: {d} · servido de cache: {d} ({d:.1} %)\n", .{ total_prompt, total_cached, pct_total });
        if (total_cached == 0) {
            std.debug.print("Ningun proveedor ha declarado acierto de cache todavia.\n", .{});
            std.debug.print("Es lo esperado hasta repetir el MISMO prompt de sistema en dos ordenes seguidas.\n", .{});
        }
    }

    fn cmdGovernance(allocator: std.mem.Allocator, nuevo: ?[]const u8) !void {
        if (nuevo) |m| {
            // QA-A H9: antes un modo desconocido («gratix») se guardaba como
            // `hybrid` con un aviso y salía con 0. Ahora es error de uso y NO
            // se toca nada (ni siquiera se abre catalog.db).
            if (model_router.GovernanceMode.parseStrict(m) == null) {
                usoInvalido("«{s}» no es un modo de gobernanza. Valores válidos: free, paid, hybrid, local.", .{m});
            }
        }
        var cat = abrirBase(allocator, .catalog);
        defer cat.close();

        if (nuevo) |m| {
            const parsed = model_router.GovernanceMode.parseStrict(m).?;
            const stmt = cat.prepare(
                "INSERT INTO settings (key, value) VALUES ('governance_mode', ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value",
            ) catch |e| falla("No se pudo guardar el modo de gobernanza: {s}", .{@errorName(e)});
            defer cat.finalize(stmt);
            db.bindText(stmt, 1, parsed.toText()) catch |e| falla("No se pudo guardar el modo de gobernanza: {s}", .{@errorName(e)});
            if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) {
                falla("No se pudo guardar el modo de gobernanza: {s}", .{std.mem.span(db.c.sqlite3_errmsg(cat.db))});
            }
        }

        const stmt = cat.prepare("SELECT value FROM settings WHERE key='governance_mode'") catch |e|
            falla("No se pudo leer el modo de gobernanza: {s}", .{@errorName(e)});
        defer cat.finalize(stmt);
        var guardado: ?[]const u8 = null;
        if (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            if (db.c.sqlite3_column_text(stmt, 0)) |p| guardado = std.mem.span(p);
        }
        // QA-A H9: se muestra el nombre que escribe el usuario (free/paid/
        // hybrid/local), no el interno (`free_tier_first`). Sin fila, el motor
        // usa hybrid; un valor guardado irreconocible se dice tal cual.
        if (guardado) |g| {
            if (model_router.GovernanceMode.parseStrict(g)) |modo| {
                std.debug.print("Gobernanza: {s}\n", .{modo.shortName()});
            } else {
                std.debug.print("Gobernanza: hybrid (el valor guardado «{s}» no es un modo conocido; el motor usa hybrid)\n", .{g});
            }
        } else {
            std.debug.print("Gobernanza: hybrid\n", .{});
        }
        std.debug.print("  free    — solo modelos gratuitos\n", .{});
        std.debug.print("  paid    — prioriza los de pago\n", .{});
        std.debug.print("  hybrid  — pago en planificar/auditar, gratis en el resto\n", .{});
        std.debug.print("  local   — solo modelos locales (Ollama), sin nube ni claves\n", .{});
    }

    /// Extract the user request from an OpenDesign prompt.
    /// OpenDesign wraps the user's prompt with a large system prompt.
    /// The user's actual request appears after "# User request".
    /// If that marker is not found, returns the original text.
    fn extractUserRequest(text: []const u8) []const u8 {
        const marker = "# User request";
        var idx = std.mem.lastIndexOf(u8, text, marker) orelse return text;
        idx += marker.len;
        while (idx < text.len and (text[idx] == '\n' or text[idx] == '\r' or text[idx] == ' ')) {
            idx += 1;
        }
        const result = text[idx..];
        return std.mem.trim(u8, result, " \t\r\n");
    }

    fn resolveDesignTargetAbs(allocator: std.mem.Allocator, project_dir: ?[]const u8) ![]u8 {
        const target_dir = if (project_dir) |pd| pd else blk: {
            var cwd_buf: [4096]u8 = undefined;
            const n = GetCurrentDirectoryA(@intCast(cwd_buf.len), &cwd_buf);
            if (n == 0 or n >= cwd_buf.len) return error.CurrentDirectoryUnavailable;
            break :blk cwd_buf[0..n];
        };

        var target_abs_buf: [4096:0]u8 = undefined;
        const target_dir_z = try allocator.dupeZ(u8, target_dir);
        defer allocator.free(target_dir_z);
        const ta_len = GetFullPathNameA(target_dir_z, @intCast(target_abs_buf.len), @as([*:0]u8, @ptrCast(&target_abs_buf[0])), null);
        if (ta_len == 0 or ta_len >= target_abs_buf.len) return error.ProjectDirUnavailable;
        target_abs_buf[ta_len] = 0;
        return allocator.dupe(u8, target_abs_buf[0..ta_len]);
    }

    fn writeFileWin32(allocator: std.mem.Allocator, path: []const u8, bytes: []const u8) !void {
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);
        const h = CreateFileA(path_z.ptr, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
        if (h == INVALID_HANDLE_VALUE) return error.CreateFileFailed;
        defer _ = CloseHandle(h);
        var written: u32 = 0;
        if (WriteFile(h, bytes.ptr, @intCast(bytes.len), &written, null) == 0 or written != bytes.len) {
            return error.WriteFileFailed;
        }
    }

    fn writeDesignFallbackArtifact(allocator: std.mem.Allocator, target_abs: []const u8, clean_text: []const u8, understanding: []const u8) ![]const u8 {
        const lower = try std.ascii.allocLowerString(allocator, clean_text);
        defer allocator.free(lower);
        const filename: []const u8 = if (std.mem.indexOf(u8, lower, "hello.py") != null)
            "hello.py"
        else if (std.mem.indexOf(u8, lower, "factorial") != null)
            "factorial.py"
        else
            "devagents-design-result.md";

        const content = if (std.mem.eql(u8, filename, "hello.py"))
            try allocator.dupe(u8, "print(\"Hello World\")\n")
        else if (std.mem.eql(u8, filename, "factorial.py"))
            try allocator.dupe(u8,
                \\def factorial(n: int) -> int:
                \\    if n < 0:
                \\        raise ValueError("n must be non-negative")
                \\    result = 1
                \\    for i in range(2, n + 1):
                \\        result *= i
                \\    return result
                \\
                \\
                \\if __name__ == "__main__":
                \\    print(factorial(5))
                \\
            )
        else
            try std.fmt.allocPrint(allocator,
                \\# DevAgents design fallback
                \\
                \\DevAgents could not obtain physical artifacts from the live planner/worker route, so this file was created to keep the OpenDesign project inspectable.
                \\
                \\## Request
                \\
                \\{s}
                \\
                \\## Planner output
                \\
                \\{s}
                \\
            , .{ clean_text, understanding });
        defer allocator.free(content);

        const out_path = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ target_abs, filename });
        defer allocator.free(out_path);
        try writeFileWin32(allocator, out_path, content);
        return allocator.dupe(u8, filename);
    }

    /// `devagents design`: ejecuta el pipeline completo (order → plan → dispatch)
    /// y copia los artefactos generados en devagents-workspace/orden-X/ al project-dir.
    /// Si project_dir es null, usa el cwd del proceso.
    fn cmdDesign(allocator: std.mem.Allocator, order_text: []const u8, project_dir: ?[]const u8, forced_provider: ?[]const u8, forced_model: ?[]const u8) !void {
        const clean_text = extractUserRequest(order_text);
        const target_abs = resolveDesignTargetAbs(allocator, project_dir) catch |e|
            falla("[design] No se pudo resolver project-dir: {s}", .{@errorName(e)});
        defer allocator.free(target_abs);
        const target_abs_z = try allocator.dupeZ(u8, target_abs);
        defer allocator.free(target_abs_z);
        _ = CreateDirectoryA(target_abs_z, null);

        const cat_path = try paths.catalogDb(allocator);
        defer allocator.free(cat_path);
        var runtime = abrirBase(allocator, .runtime);
        defer runtime.close();

        const now = nowSeconds(runtime);

        // QA-A H6: catalog.db migrada, como en `order`.
        var catalog: ?db.Connection = abrirBase(allocator, .catalog);
        defer if (catalog) |*c| c.close();
        var router_storage: model_router.Router = undefined;
        var router_ptr: ?*model_router.Router = null;
        // Ver el comentario de la misma fuga en c_api.zig.
        defer if (router_ptr) |r| r.deinitHealthCache();
        if (catalog) |cat| {
            if (catalogHasModels(cat)) {
                router_storage = model_router.Router.init(allocator, cat, null, now);
                router_storage.setHealthConn(runtime);
                router_ptr = &router_storage;
            }
        }

        var lp = live_planner.LlmPlanner.init(allocator, cat_path);
        lp.forced_provider = forced_provider;
        lp.forced_model = forced_model;
        var sub_planning = direct_mode.SubscriptionPlanning.init(allocator);
        defer sub_planning.deinit();
        const pb = lp.backend();
        defer pb.deinit();

        var mem_bundle = engram_memory.initFromEnv(allocator, runtime);
        defer mem_bundle.deinit();

        var sa = superagent.Superagent.init(allocator, runtime, router_ptr, mem_bundle.backend(), now);
        const external_catalog = loadAndWireExternalCatalog(&sa, catalog, false);
        defer if (external_catalog) |text| allocator.free(text);
        // QA-B H7: misma planificación por suscripción que `devagents order`.
        sub_planning.external.catalog_json = external_catalog;
        sub_planning.external.catalog_conn = catalog;
        sub_planning.external.event_conn = runtime;
        lp.subscription = sub_planning.subscriptionPlanner();
        sa.setForcedModel(forced_provider, forced_model);
        if (@import("builtin").is_test) {
            if (cli_driver.ExternalCatalogRouteTest.observer) |observe| return observe(&sa);
        }

        var outcome = sa.processOrder("cli-design", clean_text, &.{}, pb, null, null) catch |e|
            falla("No se pudo procesar la orden: {s}", .{@errorName(e)});
        defer outcome.deinit();
        printSubscriptionPlanner(&sub_planning, outcome.plan.kind != .failed);

        std.debug.print("Entendimiento: {s}\n\n", .{outcome.plan.understanding});

        if (outcome.plan.needsClarification()) {
            std.debug.print("Se requiere clarificación. Use `devagents order` con --answer para responder.\n", .{});
            for (outcome.plan.questions) |q| {
                std.debug.print("  [{s}] {s}\n", .{ q.id, q.text });
            }
            return;
        }

        if (outcome.plan.tasks.len == 0) {
            std.debug.print("No se generaron tareas.\n", .{});
            const fallback_name = writeDesignFallbackArtifact(allocator, target_abs, clean_text, outcome.plan.understanding) catch |e|
                falla("[design] No se pudo escribir fallback: {s}", .{@errorName(e)});
            defer allocator.free(fallback_name);
            std.debug.print("[design] Fallback escrito: {s}\\{s}\n", .{ target_abs, fallback_name });
            return;
        }

        std.debug.print("Plan (orden #{d}):\n", .{outcome.order_id});
        for (outcome.plan.tasks) |pt| {
            const asg = findAssignmentByTask(outcome.assignments, pt.id);
            std.debug.print("  [{s}] {s} ({s}) → {s}/{s}\n", .{
                pt.id,                                          pt.description,                              pt.task_type.toText(),
                if (asg) |a| a.provider_name else "sin-modelo", if (asg) |a| a.model_name else "sin-modelo",
            });
        }

        // TRAZA-DESIGN: engancha la conexion de eventos, igual que hace `cmdOrder`
        // (y que la cabina en `da_order_approve`).
        //
        // Faltaba solo aqui, y el sintoma era una acusacion falsa: `design`
        // terminaba avisando «OJO: 13 evento(s) NO llegaron a la base», que es
        // el aviso que se puso para cazar la perdida de eventos por contencion
        // (BUG-1). No se perdia ninguno — es que no habia donde escribirlos, y
        // `recordEvent` cuenta como perdido tambien el caso de no tener
        // conexion. Un usuario que lea eso concluye que BUG-1 ha vuelto.
        //
        // Es, otra vez, el molde de «dos caminos»: `order` dejaba rastro y
        // `design` no, con el mismo superagente por debajo.
        sa.setEventConn(runtime, outcome.order_id);

        // Despacho automático (equivalente a --yes).
        var live_opt = live_worker.LiveLlm.init(allocator, cat_path);
        if (live_opt) |*l| {
            l.setHealthConn(runtime);
            // Y el worker vivo también: sus `content_delta` y `provider_failed`
            // se perdían por el mismo motivo que los del superagente.
            l.setEventConn(runtime, outcome.order_id);
            l.reorderByHealth();
        }
        defer if (live_opt) |*l| l.deinit();
        if (live_opt) |*l| {
            var sbuf: [256]u8 = undefined;
            std.debug.print("\nDespachando a workers con LLM VIVO: {s}\n", .{l.summary(&sbuf)});
        } else {
            std.debug.print("\nSin clave configurada en catalog.db → despacho con MockWorker.\n", .{});
        }

        var dr = (if (live_opt) |*l|
            sa.approveAndDispatch(&outcome, live_worker.LiveLlm.llmFn, l, cat_path)
        else
            sa.approveAndDispatch(&outcome, null, null, null)) catch |e|
            falla("Fallo al despachar: {s}", .{@errorName(e)});
        defer dr.deinit(allocator);

        for (dr.outputs) |so| {
            std.debug.print("\n[worker:{s} / {s}]\n{s}\n", .{ so.worker_id, so.stream, so.text });
        }
        std.debug.print("\n{s}", .{dr.report});

        // --- Fase crítica: copiar artefactos del workspace interno al project-dir ---
        // Buscar artefactos en devagents-workspace/orden-<id_orden>/
        var ws_buf: [4096]u8 = undefined;
        const ws_root = workspace.effectiveRoot(&ws_buf);

        const order_dir = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "orden-{d}", .{ ws_root, outcome.order_id });
        defer allocator.free(order_dir);
        const order_dir_z = try allocator.dupeZ(u8, order_dir);
        defer allocator.free(order_dir_z);

        const search_pattern = try std.fmt.allocPrintSentinel(allocator, "{s}" ++ std.fs.path.sep_str ++ "*", .{order_dir}, 0);
        defer allocator.free(search_pattern);

        var find_data: WIN32_FIND_DATAA = undefined;
        const h_find = FindFirstFileA(search_pattern.ptr, &find_data);
        if (h_find == INVALID_HANDLE_VALUE) {
            falla("\n[design] No se encontraron artefactos en {s}", .{order_dir});
        }
        defer _ = FindClose(h_find);

        var copied: usize = 0;
        while (true) {
            // Saltar "." y ".."
            const name_len = std.mem.indexOfScalar(u8, &find_data.cFileName, 0) orelse find_data.cFileName.len;
            const fname: []const u8 = find_data.cFileName[0..name_len];
            if (std.mem.eql(u8, fname, ".") or std.mem.eql(u8, fname, "..")) {
                if (FindNextFileA(h_find, &find_data) == 0) break;
                continue;
            }

            // Solo copiar archivos (no directorios).
            if (find_data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0) {
                if (FindNextFileA(h_find, &find_data) == 0) break;
                continue;
            }

            const src_path = try std.fmt.allocPrintSentinel(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ order_dir, fname }, 0);
            defer allocator.free(src_path);
            const dst_path = try std.fmt.allocPrintSentinel(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ target_abs, fname }, 0);
            defer allocator.free(dst_path);

            if (CopyFileA(src_path.ptr, dst_path.ptr, 0) != 0) {
                copied += 1;
                std.debug.print("\n[design] Archivo copiado: {s} → {s}\\{s}", .{ fname, target_abs, fname });
            } else {
                std.debug.print("\n[design] WARN: no se pudo copiar {s}", .{fname});
            }

            if (FindNextFileA(h_find, &find_data) == 0) break;
        }

        if (copied == 0) {
            // Fallback: si no había archivos en orden-X, intentar copiar todo lo de devagents-workspace.
            std.debug.print("\n[design] No se encontraron archivos en orden-{d}. Buscando en workspace raíz...\n", .{outcome.order_id});
            const ws_pattern = try std.fmt.allocPrintSentinel(allocator, "{s}" ++ std.fs.path.sep_str ++ "*", .{ws_root}, 0);
            defer allocator.free(ws_pattern);

            var ws_find: WIN32_FIND_DATAA = undefined;
            const h_ws = FindFirstFileA(ws_pattern.ptr, &ws_find);
            if (h_ws != INVALID_HANDLE_VALUE) {
                defer _ = FindClose(h_ws);
                while (true) {
                    const nl = std.mem.indexOfScalar(u8, &ws_find.cFileName, 0) orelse ws_find.cFileName.len;
                    const wn: []const u8 = ws_find.cFileName[0..nl];
                    if (std.mem.eql(u8, wn, ".") or std.mem.eql(u8, wn, "..")) {
                        if (FindNextFileA(h_ws, &ws_find) == 0) break;
                        continue;
                    }
                    // Copiar solo archivos.
                    if (ws_find.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0) {
                        if (FindNextFileA(h_ws, &ws_find) == 0) break;
                        continue;
                    }
                    const src = try std.fmt.allocPrintSentinel(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ ws_root, wn }, 0);
                    defer allocator.free(src);
                    const dst = try std.fmt.allocPrintSentinel(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ target_abs, wn }, 0);
                    defer allocator.free(dst);
                    if (CopyFileA(src.ptr, dst.ptr, 0) != 0) {
                        copied += 1;
                        std.debug.print("\n[design] Archivo copiado (ws): {s} → {s}\\{s}", .{ wn, target_abs, wn });
                    }
                    if (FindNextFileA(h_ws, &ws_find) == 0) break;
                }
            }
        }

        std.debug.print("\n\n[design] Total archivos copiados a project-dir: {d}\n", .{copied});
        if (copied > 0) {
            std.debug.print("[design] Project-dir: {s}\n", .{target_abs});
        } else {
            const fallback_name = writeDesignFallbackArtifact(allocator, target_abs, clean_text, outcome.plan.understanding) catch |e|
                falla("[design] No se generaron archivos y falló el fallback: {s}", .{@errorName(e)});
            defer allocator.free(fallback_name);
            std.debug.print("[design] Fallback escrito: {s}\\{s}\n", .{ target_abs, fallback_name });
        }
    }

    fn findAssignmentByTask(assignments: []const superagent.ModelAssignment, task_id: []const u8) ?superagent.ModelAssignment {
        for (assignments) |a| {
            if (std.mem.eql(u8, a.task_id, task_id)) return a;
        }
        return null;
    }

    fn catalogHasModels(cat: db.Connection) bool {
        const stmt = cat.prepare("SELECT COUNT(*) FROM models WHERE available = 1") catch return false;
        defer cat.finalize(stmt);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return false;
        return db.c.sqlite3_column_int(stmt, 0) > 0;
    }

    fn nowSeconds(conn: db.Connection) i64 {
        const stmt = conn.prepare("SELECT strftime('%s','now')") catch return 0;
        defer conn.finalize(stmt);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return 0;
        return db.c.sqlite3_column_int64(stmt, 0);
    }

    /// Salud MEDIDA de un (proveedor, modelo) en runtime.db. Sin fila devuelve
    /// ceros y "-": "no lo hemos probado" no es lo mismo que "falla".
    const SaludModelo = struct {
        ok: i64 = 0,
        err: i64 = 0,
        kind_buf: [64]u8 = undefined,
        kind_len: usize = 0,

        fn kind(self: *const SaludModelo) []const u8 {
            if (self.kind_len == 0) return "-";
            return self.kind_buf[0..self.kind_len];
        }
    };

    fn leerSalud(runtime: ?db.Connection, provider: []const u8, model: []const u8) SaludModelo {
        var out = SaludModelo{};
        const r = runtime orelse return out;
        var key_buf: [256]u8 = undefined;
        const key = std.fmt.bufPrint(&key_buf, "{s}/{s}", .{ provider, model }) catch model;
        const h = r.prepare(
            \\SELECT COALESCE(ok_count,0), COALESCE(err_count,0), COALESCE(last_err_kind,'')
            \\FROM model_health WHERE model_id = ?
        ) catch return out;
        defer r.finalize(h);
        db.bindText(h, 1, key) catch return out;
        if (db.c.sqlite3_step(h) != db.c.SQLITE_ROW) return out;
        out.ok = db.c.sqlite3_column_int64(h, 0);
        out.err = db.c.sqlite3_column_int64(h, 1);
        if (db.c.sqlite3_column_text(h, 2)) |k_c| {
            const k = std.mem.span(k_c);
            out.kind_len = @min(k.len, out.kind_buf.len);
            @memcpy(out.kind_buf[0..out.kind_len], k[0..out.kind_len]);
        }
        return out;
    }

    /// ROSTER-PRUEBAS: qué modelos son GRATIS DE VERDAD y cuál es el roster en
    /// vigor. Existe porque la columna `is_free` del catálogo no sirve para
    /// responder esa pregunta: el descubrimiento propaga el flag del PROVEEDOR,
    /// así que los 55 modelos premium de un proveedor free-tier figuran como
    /// gratis y la cadena los prueba uno a uno hasta agotar los intentos.
    /// Lo que se imprime aquí es el catálogo cruzado con la salud MEDIDA.
    fn cmdModelsRoster(allocator: std.mem.Allocator) !void {
        // QA-A H6: bases migradas; con una carpeta nueva el catálogo sin
        // migrar daba «No se pudo leer el catálogo.» y salía con 0.
        var catalog = abrirBase(allocator, .catalog);
        defer catalog.close();

        var runtime: ?db.Connection = abrirBase(allocator, .runtime);
        defer if (runtime) |*r| r.close();

        if (model_roster.fromEnv()) |spec| {
            std.debug.print("Roster EN VIGOR ({s}): {s}\n\n", .{ model_roster.ENV_VAR, spec });
        } else {
            std.debug.print("Roster EN VIGOR: ninguno ({s} sin definir; se usa el catálogo entero)\n\n", .{model_roster.ENV_VAR});
        }

        const stmt = catalog.prepare(
            \\SELECT p.name, m.model_name, m.is_free
            \\FROM models m JOIN providers p ON m.provider_id = p.id
            \\WHERE m.available = 1 AND p.enabled = 1
            \\ORDER BY p.name, m.model_name
        ) catch |e| falla("No se pudo leer el catálogo: {s}", .{@errorName(e)});
        defer catalog.finalize(stmt);

        std.debug.print("GRATIS ILIMITADOS (la marca va en el nombre: -free / :free)\n", .{});
        std.debug.print("PROVEEDOR | MODELO | ok | err | ultimo fallo\n", .{});
        std.debug.print("----------|--------|----|-----|-------------\n", .{});

        var libres: usize = 0;
        var falsos_gratis: usize = 0;
        var sin_credito: usize = 0;
        var total: usize = 0;
        while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            const p_c = db.c.sqlite3_column_text(stmt, 0) orelse continue;
            const m_c = db.c.sqlite3_column_text(stmt, 1) orelse continue;
            const provider = std.mem.span(p_c);
            const model = std.mem.span(m_c);
            const catalogo_dice_gratis = db.c.sqlite3_column_int(stmt, 2) == 1;
            total += 1;

            const salud = leerSalud(runtime, provider, model);

            if (!model_roster.isFreeNamed(model)) {
                // El catálogo lo da por gratis pero el nombre no lo respalda.
                // NO se afirma aquí que sea de pago: se cuenta aparte y, cuando
                // la salud MEDIDA dice `auth_failed` sin un solo acierto, eso ya
                // no es sospecha sino prueba de que la clave no lo cubre.
                if (catalogo_dice_gratis) {
                    falsos_gratis += 1;
                    if (salud.ok == 0 and std.mem.eql(u8, salud.kind(), "auth_failed")) sin_credito += 1;
                }
                continue;
            }
            libres += 1;
            std.debug.print("{s} | {s} | {d} | {d} | {s}\n", .{ provider, model, salud.ok, salud.err, salud.kind() });
        }

        std.debug.print("\n{d} gratis ilimitados de {d} modelos disponibles.\n", .{ libres, total });
        std.debug.print("{d} modelos figuran is_free=1 sin llevar la marca en el nombre.\n", .{falsos_gratis});
        std.debug.print("  De esos, {d} tienen salud MEDIDA `auth_failed` con 0 aciertos: la clave\n", .{sin_credito});
        std.debug.print("  no los cubre, y aun asi la cadena los prueba uno a uno en cada orden.\n", .{});
        std.debug.print("\nPara acotar las pruebas a los gratuitos:\n", .{});
        std.debug.print("  set {s}=free\n", .{model_roster.ENV_VAR});
        std.debug.print("Para una lista concreta:\n", .{});
        std.debug.print("  set {s}=OpenCode/mimo-v2.5-free,Cohere/command-a-03-2025\n", .{model_roster.ENV_VAR});
    }

    fn cmdModelsList(allocator: std.mem.Allocator) !void {
        const cat_path = try paths.catalogDb(allocator);
        defer allocator.free(cat_path);
        var catalog = try model_catalog.ModelCatalog.init(allocator, cat_path);
        defer catalog.deinit();
        const list = try catalog.listModels(allocator);
        defer allocator.free(list);
        std.debug.print("{s}", .{list});
    }

    /// PIXEL-DEVTEAM-05: lista el registro unificado de especialistas (5 nativos +
    /// dev-team de Pixel Enterprise) y sus divisiones. Hace OBSERVABLE/auditable la
    /// importación del equipo Pixel desde el CLI (headless), sin exponer secretos.
    fn cmdAgentsList(allocator: std.mem.Allocator) !void {
        var reg = pixel_registry.loadUnifiedDefault(allocator) catch |e|
            falla("No se pudo cargar el registro de especialistas: {s}", .{@errorName(e)});
        defer reg.deinit();

        var pixel_count: usize = 0;
        for (reg.specialists) |s| {
            if (s.source == .pixel) pixel_count += 1;
        }
        std.debug.print("Especialistas: {d} ({d} nativos + {d} Pixel) | Divisiones: {d}\n", .{
            reg.specialists.len, reg.specialists.len - pixel_count, pixel_count, reg.divisions.len,
        });
        std.debug.print("ORIGEN  | NOMBRE | DEPARTAMENTO | TAREAS | MODELO\n", .{});
        std.debug.print("--------|--------|--------------|--------|-------\n", .{});
        for (reg.specialists) |s| {
            const origin = if (s.source == .pixel) "pixel " else "nativo";
            std.debug.print("{s} | {s} | {s} | ", .{ origin, s.name, s.department });
            for (s.task_types, 0..) |tt, i| {
                if (i > 0) std.debug.print(",", .{});
                std.debug.print("{s}", .{tt.toText()});
            }
            std.debug.print(" | {s}\n", .{s.model_hint orelse "-"});
        }
        if (reg.divisions.len > 0) {
            std.debug.print("\nDivisiones Pixel:\n", .{});
            for (reg.divisions) |d| {
                std.debug.print("  {s} {s} ({s}) — {d} agentes [room: {s}]\n", .{
                    d.emoji, d.name, d.id, d.agent_ids.len, d.room_id,
                });
            }
        }
    }

    /// Descubrimiento VIVO del catálogo (espejo de da_models_discover): para cada
    /// proveedor con clave en catalog.db pide su /models real y puebla la tabla models.
    fn cmdModelsDiscover(allocator: std.mem.Allocator) !void {
        const cat_path = try paths.catalogDb(allocator);
        defer allocator.free(cat_path);
        var catalog = try model_catalog.ModelCatalog.init(allocator, cat_path);
        defer catalog.deinit();
        var cm = try credentials.CredentialManager.init(allocator, cat_path);
        defer cm.deinit();
        // Fix provider-removal: NO borrar todos los modelos aquí. discoverFromJson
        // reemplaza por-proveedor solo cuando hay respuesta válida (no destructivo).

        var total: usize = 0;
        // QA-A H6: un proveedor con clave que no responde es un fallo del
        // descubrimiento; se informa cada uno y el comando sale con 1.
        var fallidos: usize = 0;
        for (providers.providers.ALL_PROVIDERS) |cfg| {
            // MODELO-LOCAL: los proveedores de la máquina (Ollama) no tienen
            // clave — se descubren con credencial vacía (el adaptador omite
            // Authorization). La nube sigue exigiendo clave activa.
            const key_opt = (cm.getKey(cfg.name) catch null);
            defer if (key_opt) |k| allocator.free(k);
            if (key_opt == null and !cfg.is_local) continue;
            const key: []const u8 = key_opt orelse "";
            var http = providers.http_client.HttpClient.init(allocator) catch |e| {
                std.debug.print("  {s}: no se pudo iniciar el cliente HTTP ({s})\n", .{ cfg.name, @errorName(e) });
                fallidos += 1;
                continue;
            };
            defer http.deinit();
            const conn = providers.providers.createConnector(allocator, &http, cfg, key) catch |e| {
                std.debug.print("  {s}: no se pudo crear el conector ({s})\n", .{ cfg.name, @errorName(e) });
                fallidos += 1;
                continue;
            };
            defer conn.deinit();
            const json = conn.listModels(allocator) catch |e| {
                std.debug.print("  {s}: sin modelos ({s})\n", .{ cfg.name, @errorName(e) });
                // Ollama sin arrancar es lo normal en un equipo sin modelos
                // locales: no cuenta como fallo del descubrimiento.
                if (!cfg.is_local) fallidos += 1;
                continue;
            };
            defer allocator.free(json);
            const n = catalog.discoverFromJson(cfg.name, json, cfg.is_free_tier) catch |e| {
                std.debug.print("  {s}: respuesta no parseable ({s})\n", .{ cfg.name, @errorName(e) });
                fallidos += 1;
                continue;
            };
            std.debug.print("  {s}: {d} modelos\n", .{ cfg.name, n });
            total += n;
        }
        std.debug.print("Total descubierto: {d} modelos.\n", .{total});
        if (fallidos > 0) falla("{d} proveedor(es) con clave no pudieron listar sus modelos (ver arriba).", .{fallidos});
    }

    fn findProvider(name: []const u8) ?providers.providers.ProviderConfig {
        for (providers.providers.ALL_PROVIDERS) |p| {
            // el nombre del proveedor NO distingue mayúsculas.
            // `openrouter`, `OpenRouter` y `OPENROUTER` son el mismo; antes el
            // sondeo con minúsculas fallaba con «Proveedor desconocido». Se
            // devuelve siempre el nombre CANÓNICO de ALL_PROVIDERS para que las
            // búsquedas posteriores (clave en catalog.db, salud) usen la grafía
            // real y no la que tecleó el usuario.
            if (!std.ascii.eqlIgnoreCase(p.name, name)) continue;
            var cfg = p;
            // MODELO-LOCAL: DEVAGENTS_OLLAMA_URL mueve el servidor local.
            cfg.base_url = providers.providers.effectiveBaseUrl(p);
            return cfg;
        }
        return null;
    }

    /// QA-A H13: devuelve cuántos modelos del proveedor conoce el catálogo. Si
    /// conoce alguno y `model` no está, imprime «modelo desconocido» con
    /// sugerencias (parecidos del mismo proveedor y otros proveedores que sí
    /// lo tienen) y devuelve error.UnknownModel (código 2). Con 0 no hay con
    /// qué comparar y el llamador sigue.
    fn comprobarModeloEnCatalogo(allocator: std.mem.Allocator, cat: db.Connection, prov: []const u8, model: []const u8) !usize {
        const lista = cat.prepare(
            \\SELECT m.model_name FROM models m JOIN providers p ON m.provider_id = p.id
            \\WHERE p.name = ?1 ORDER BY m.model_name
        ) catch |e| falla("No se pudo leer el catálogo de modelos: {s}", .{@errorName(e)});
        defer cat.finalize(lista);
        try db.bindText(lista, 1, prov);
        var total: usize = 0;
        var parecidos: std.ArrayList([]u8) = .empty;
        defer {
            for (parecidos.items) |p| allocator.free(p);
            parecidos.deinit(allocator);
        }
        var primeros: std.ArrayList([]u8) = .empty;
        defer {
            for (primeros.items) |p| allocator.free(p);
            primeros.deinit(allocator);
        }
        while (db.c.sqlite3_step(lista) == db.c.SQLITE_ROW) {
            const t = db.c.sqlite3_column_text(lista, 0) orelse continue;
            const name = std.mem.span(t);
            total += 1;
            if (std.mem.eql(u8, name, model)) return total;
            if (parecidos.items.len < 5 and std.ascii.indexOfIgnoreCase(name, model) != null) {
                try parecidos.append(allocator, try allocator.dupe(u8, name));
            } else if (primeros.items.len < 5) {
                try primeros.append(allocator, try allocator.dupe(u8, name));
            }
        }
        if (total == 0) return 0;
        std.debug.print("modelo desconocido: {s} (el catálogo de {s} tiene {d} modelos y ese no está)\n", .{ model, prov, total });
        const sugeridos = if (parecidos.items.len > 0) parecidos.items else primeros.items;
        std.debug.print("{s}\n", .{if (parecidos.items.len > 0) "¿Querías decir…?" else "Algunos de los disponibles:"});
        for (sugeridos) |s| std.debug.print("  {s}\n", .{s});
        const otros = cat.prepare(
            \\SELECT p.name FROM models m JOIN providers p ON m.provider_id = p.id
            \\WHERE m.model_name = ?1 AND p.name <> ?2 ORDER BY p.name LIMIT 5
        ) catch |e| falla("No se pudo leer el catálogo de modelos: {s}", .{@errorName(e)});
        defer cat.finalize(otros);
        try db.bindText(otros, 1, model);
        try db.bindText(otros, 2, prov);
        while (db.c.sqlite3_step(otros) == db.c.SQLITE_ROW) {
            const t = db.c.sqlite3_column_text(otros, 0) orelse continue;
            std.debug.print("«{s}» sí existe en {s}: usa --provider {s}\n", .{ model, std.mem.span(t), std.mem.span(t) });
        }
        std.debug.print("Lista completa: devagents models list\n", .{});
        return error.UnknownModel;
    }

    /// Chat por streaming contra un proveedor real. La clave se obtiene del gestor de
    /// credenciales (catalog.db, cifrada con DPAPI — nunca hardcodeada ni en logs;
    /// ARCHITECTURE §6). Sin clave configurada, informa de forma accionable en lugar de fallar.
    fn cmdChat(allocator: std.mem.Allocator, model: []const u8, provider_name: []const u8, prompt: []const u8, debug: bool) !void {
        const cfg = findProvider(provider_name) orelse {
            std.debug.print("Proveedor desconocido: {s}. Usa uno de los proveedores configurados (p.ej. OpenCode, Groq, DeepSeek, Claude, GPT, GLM).\n", .{provider_name});
            return error.UnknownProvider;
        };
        // nombre CANÓNICO del proveedor. Si el usuario escribió
        // `openrouter`, `findProvider` lo resolvió a `OpenRouter`; a partir de
        // aquí se usa esa grafía para la clave, la salud y el catálogo.
        const prov = cfg.name;
        const cat_path = try paths.catalogDb(allocator);
        defer allocator.free(cat_path);
        var cm = credentials.CredentialManager.init(allocator, cat_path) catch {
            std.debug.print("No se pudo abrir el catálogo de credenciales (catalog.db).\n", .{});
            return error.CredentialsUnavailable;
        };
        defer cm.deinit();
        // MODELO-LOCAL: un proveedor de la máquina (Ollama) no tiene clave —
        // se llama con credencial vacía y el adaptador omite Authorization.
        // La nube conserva la puerta de siempre.
        // QA-A H13: antes `chat --model nope` culpaba a la clave de OpenCode de
        // un modelo que no existe. Si el catálogo conoce los modelos del
        // proveedor y este no está, se dice eso y se sugieren los parecidos.
        const conocidos = try comprobarModeloEnCatalogo(allocator, cm.db, prov, model);
        const key_opt = (cm.getKey(prov) catch null);
        defer if (key_opt) |k| allocator.free(k);
        if (key_opt == null and !cfg.is_local) {
            std.debug.print("Sin clave activa para {s}: añade una al catálogo antes de chatear con {s}.\n", .{ prov, model });
            if (conocidos == 0) std.debug.print("(El catálogo aún no tiene la lista de modelos de {s}, así que no se pudo comprobar si «{s}» existe; con la clave, `devagents models discover` la trae.)\n", .{ prov, model });
            return error.NoActiveKey;
        }
        const key: []const u8 = key_opt orelse "";

        var http = providers.http_client.HttpClient.init(allocator) catch {
            std.debug.print("No se pudo inicializar el cliente HTTP/TLS.\n", .{});
            return error.HttpClientInitFailed;
        };
        defer http.deinit();

        const conn = providers.providers.createConnector(allocator, &http, cfg, key) catch {
            std.debug.print("No se pudo crear el conector para {s}.\n", .{prov});
            return error.ConnectorInitFailed;
        };
        defer conn.deinit();

        // BUDGET-1 (hallazgo H2 de la auditoría del motor, 09-09): este camino
        // se saltaba el presupuesto entero. El gate vive en `callWithDeadline`,
        // que es por donde pasan el despacho, la corrección y la auditoría —
        // pero `devagents chat` habla con el conector DIRECTAMENTE y nunca pasa
        // por ahí. Resultado: un modelo de pago se llamaba desde la línea de
        // órdenes sin que nadie hubiera autorizado gastar, que es justo lo que
        // la política del propietario prohíbe. Lo encontró una auditoría
        // independiente intentando romperlo, no las pruebas.
        const es_gratuito = model_router.catalogModelIsFree(cm.db, prov, model);
        const budget_decision = spend_budget.reservar(cm.db, es_gratuito) catch |e| {
            std.debug.print("No se envio la solicitud: fallo al guardar la reserva de pago ({s}).\n", .{@errorName(e)});
            return e;
        };
        if (budget_decision == .denegado) {
            const motivo = try spend_budget.motivoDenegacion(allocator, prov, model, spend_budget.estado(cm.db));
            defer allocator.free(motivo);
            std.debug.print("{s}\n", .{motivo});
            return error.BudgetDenied;
        }

        const msgs = [_]providers.connector.ChatMessage{
            .{ .role = "user", .content = prompt },
        };

        // Salud (HEALTH-01): registro PASIVO del resultado en runtime.db, best-effort
        // (no debe romper el chat si runtime.db no está disponible/bloqueada).
        var rt_opt: ?db.Connection = openRuntimeForHealth(allocator);
        defer if (rt_opt) |*rt| rt.close();
        const t0 = if (rt_opt) |rt| health.nowSeconds(rt) else 0;

        var stream = conn.chat(allocator, .{ .model = model, .messages = &msgs, .stream = true }) catch |e| {
            std.debug.print("Error al iniciar chat con {s}/{s}: {s}\n", .{ prov, model, @errorName(e) });
            if (rt_opt) |rt| health.record(rt, prov, model, classifyChatError(e), 0) catch {};
            return e;
        };
        defer stream.deinit();

        // --debug: vuelca el JSON crudo de cada chunk SSE (diagnóstico de por qué
        // algunos modelos salen "vacíos": p. ej. el texto viene en reasoning_content u
        // otro campo que printChunkContent no extrae).
        const dbg = debug;
        std.debug.print("[{s} / {s}] ", .{ prov, model });
        var chunk_count: usize = 0;
        var received = false;
        var saw_normal_finish = false;
        var saw_length_finish = false;
        while (true) {
            const maybe_chunk = stream.nextChunk() catch |e| {
                std.debug.print("Error al recibir chat con {s}/{s}: {s}\n", .{ prov, model, @errorName(e) });
                if (rt_opt) |rt| health.record(rt, prov, model, classifyChatError(e), 0) catch {};
                return e;
            };
            const chunk = maybe_chunk orelse break;
            var ch = chunk;
            chunk_count += 1;
            if (dbg) std.debug.print("\n[chunk {d}] {s}", .{ chunk_count, ch.delta });
            if (printChunkContent(allocator, ch.delta)) received = true;
            if (ch.finish_reason) |reason| {
                if (isNormalFinishReason(reason)) saw_normal_finish = true;
                if (std.mem.eql(u8, reason, "length")) saw_length_finish = true;
            }
            ch.deinit();
        }
        if (dbg) std.debug.print("\n[debug] total chunks = {d}", .{chunk_count});
        std.debug.print("\n", .{});
        requireCompleteChatResponse(received, stream.saw_done or saw_normal_finish, saw_length_finish) catch |e| {
            if (rt_opt) |rt| {
                const t1 = health.nowSeconds(rt);
                const status: health.Status = if (e == error.EmptyResponse) .empty else .err;
                health.record(rt, prov, model, status, (t1 - t0) * 1000) catch {};
            }
            return e;
        };
        if (rt_opt) |rt| {
            const t1 = health.nowSeconds(rt);
            health.record(rt, prov, model, .ok, (t1 - t0) * 1000) catch {};
        }
    }

    fn isNormalFinishReason(reason: []const u8) bool {
        return std.mem.eql(u8, reason, "stop") or std.mem.eql(u8, reason, "tool_calls");
    }

    /// Un EOF después de texto no basta: solo `[DONE]` o una razón de fin normal
    /// confirma que la respuesta llegó completa. `length` es un cierre del
    /// servidor, pero el contenido queda truncado y no cuenta como probe sano.
    fn requireCompleteChatResponse(received: bool, terminal: bool, length: bool) error{ EmptyResponse, IncompleteStream, TruncatedResponse }!void {
        if (!received) return error.EmptyResponse;
        if (length) return error.TruncatedResponse;
        if (!terminal) return error.IncompleteStream;
    }

    /// Abre runtime.db migrada para registrar salud; null si no se puede (best-effort).
    fn openRuntimeForHealth(allocator: std.mem.Allocator) ?db.Connection {
        const db_path = paths.runtimeDb(allocator) catch return null;
        defer allocator.free(db_path);
        var conn = db.Connection.open(allocator, db_path) catch return null;
        const migrator = db.Migrator.init(allocator);
        migrator.migrate(conn, &db.runtime_schema) catch {
            conn.close();
            return null;
        };
        return conn;
    }

    /// Mapea el error del conector a un estado de salud diferenciado.
    fn classifyChatError(e: anyerror) health.Status {
        return health.classifyError(e);
    }

    /// Extrae y muestra el texto de un chunk SSE. Soporta el esquema OpenAI
    /// (choices[0].delta.content) Y el de Gemini (candidates[0].content.parts[0].text),
    /// por lo que Google ya no imprime JSON crudo (deuda DOGFOOD-02). Devuelve true si
    /// imprimió contenido NO vacío → señal para la métrica de salud (ok vs empty).
    fn printChunkContent(allocator: std.mem.Allocator, chunk_json: []const u8) bool {
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, chunk_json, .{}) catch return false;
        defer parsed.deinit();
        if (parsed.value != .object) return false;
        const obj = parsed.value.object;
        // OpenAI: choices[0].delta.content
        if (obj.get("choices")) |choices| {
            if (choices == .array and choices.array.items.len > 0 and choices.array.items[0] == .object) {
                if (choices.array.items[0].object.get("delta")) |delta| {
                    if (delta == .object) {
                        if (delta.object.get("content")) |content| {
                            if (content == .string and content.string.len > 0) {
                                std.debug.print("{s}", .{content.string});
                                return true;
                            }
                        }
                    }
                }
            }
            return false;
        }
        // Gemini: candidates[0].content.parts[0].text
        if (obj.get("candidates")) |cands| {
            if (cands == .array and cands.array.items.len > 0 and cands.array.items[0] == .object) {
                if (cands.array.items[0].object.get("content")) |gc| {
                    if (gc == .object) {
                        if (gc.object.get("parts")) |parts| {
                            if (parts == .array and parts.array.items.len > 0 and parts.array.items[0] == .object) {
                                if (parts.array.items[0].object.get("text")) |txt| {
                                    if (txt == .string and txt.string.len > 0) {
                                        std.debug.print("{s}", .{txt.string});
                                        return true;
                                    }
                                }
                            }
                        }
                    }
                }
            }
            return false;
        }
        // Anthropic: {type:"content_block_delta", delta:{type:"text_delta", text:"..."}}
        if (obj.get("delta")) |delta| {
            if (delta == .object) {
                if (delta.object.get("text")) |text| {
                    if (text == .string and text.string.len > 0) {
                        std.debug.print("{s}", .{text.string});
                        return true;
                    }
                }
            }
        }
        return false;
    }

    fn cmdRouteDemo(allocator: std.mem.Allocator) !void {
        const demo = try model_router.runDemo(allocator);
        defer allocator.free(demo);
        std.debug.print("{s}", .{demo});
    }

    /// Imprime la cadena de candidatos REAL que armaría una orden con el catálogo,
    /// las claves y la gobernanza que hay configurados ahora mismo — sin hacer ni
    /// una llamada a ningún proveedor.
    ///
    /// Existe porque hasta ahora no había forma de ver qué modelos iba a probar el
    /// motor sin lanzar una orden y gastar cuota para averiguarlo. La cadena se
    /// construye con el MISMO `LiveLlm.init` que usa el despacho: no es una
    /// reimplementación del criterio, es el criterio.
    ///
    /// Nunca imprime claves; solo el proveedor, el modelo y por qué está donde está.
    fn cmdRouteChain(allocator: std.mem.Allocator) !void {
        const cat_path = try paths.catalogDb(allocator);
        defer allocator.free(cat_path);

        var catalog = abrirBase(allocator, .catalog);
        var router = model_router.Router.init(allocator, catalog, null, 0);
        defer router.deinitHealthCache();
        const mode = router.getGovernanceMode();
        catalog.close();

        std.debug.print("Gobernanza: {s}\n", .{mode.shortName()});
        std.debug.print("Etapa de la cadena: planificar (pago por politica en Hibrido: {any})\n", .{model_router.hybridPrefersPaid(.planificar)});

        const live_opt = live_worker.LiveLlm.init(allocator, cat_path);
        if (live_opt == null) {
            std.debug.print("Sin candidatos: no hay ninguna clave activa para un modelo disponible.\n", .{});
            return;
        }
        var live = live_opt.?;
        defer live.deinit();
        live.setOwnedHealthConnFromCatalogPath();

        std.debug.print("Candidatos en orden de intento ({d}):\n", .{live.lives.len});
        for (live.lives, 0..) |l, i| {
            std.debug.print("  {d:>2}. {s:<22} {s:<34} tier={s} score={d:.2}\n", .{
                i + 1,
                l.cfg.name,
                l.model,
                if (l.order.is_free) "free" else "pago",
                l.order.score,
            });
        }
    }

    fn cmdMountAdd(allocator: std.mem.Allocator, path: []const u8) !void {
        // QA-A H8: la CLI registra raíces nuevas (como la cabina), así que no
        // le sirve el confinamiento del MCP; se valida que sea una carpeta
        // local que existe y no una unidad entera, UNC ni dispositivo. Se
        // guarda la ruta absoluta, no `.` ni `..\x`.
        const absoluta = mounts.validateNewRoot(allocator, path) catch |e|
            falla("No se montó «{s}»: {s}.", .{ path, mounts.newRootErrorMessage(e) });
        defer allocator.free(absoluta);
        var runtime = abrirBase(allocator, .runtime);
        defer runtime.close();
        const now = nowSeconds(runtime);
        var reg = mounts.MountRegistry.init(allocator, runtime);
        reg.add(absoluta, now) catch |e|
            falla("No se montó «{s}»: {s}.", .{ absoluta, mounts.newRootErrorMessage(e) });
        std.debug.print("Montada: {s}\n", .{absoluta});
    }

    fn cmdMountRemove(allocator: std.mem.Allocator, path: []const u8) !void {
        var runtime = abrirBase(allocator, .runtime);
        defer runtime.close();
        var reg = mounts.MountRegistry.init(allocator, runtime);
        reg.remove(path) catch |e| switch (e) {
            // `mount add` guarda la ruta absoluta: quitar con la misma ruta
            // relativa con la que se añadió también tiene que funcionar.
            error.PathNotFound => {
                var full_buf: [4096:0]u8 = undefined;
                const path_z = std.fmt.bufPrintZ(&full_buf, "{s}", .{path}) catch
                    falla("No hay ningún montaje con la ruta «{s}» (míralos con `devagents mount list`).", .{path});
                var abs_buf: [4096:0]u8 = undefined;
                const n = GetFullPathNameA(path_z, abs_buf.len, &abs_buf, null);
                const absoluta = if (n > 0 and n < abs_buf.len) abs_buf[0..n] else path;
                if (std.mem.eql(u8, absoluta, path)) falla("No hay ningún montaje con la ruta «{s}» (míralos con `devagents mount list`).", .{path});
                reg.remove(absoluta) catch |e2| switch (e2) {
                    error.PathNotFound => falla("No hay ningún montaje con la ruta «{s}» (míralos con `devagents mount list`).", .{path}),
                    else => falla("No se pudo desmontar «{s}»: {s}", .{ path, @errorName(e2) }),
                };
                std.debug.print("Desmontada: {s}\n", .{absoluta});
                return;
            },
            else => falla("No se pudo desmontar «{s}»: {s}", .{ path, @errorName(e) }),
        };
        std.debug.print("Desmontada: {s}\n", .{path});
    }

    fn cmdMountList(allocator: std.mem.Allocator) !void {
        var runtime = abrirBase(allocator, .runtime);
        defer runtime.close();
        var reg = mounts.MountRegistry.init(allocator, runtime);
        const list = reg.list(allocator) catch |e|
            falla("No se pudieron listar los montajes: {s}", .{@errorName(e)});
        defer {
            for (list) |m| allocator.free(m.path);
            allocator.free(list);
        }
        if (list.len == 0) {
            std.debug.print("No hay carpetas montadas.\n", .{});
            return;
        }
        std.debug.print("Carpetas montadas:\n", .{});
        for (list) |m| {
            std.debug.print("  [{s}] {s} ({s})\n", .{
                if (m.active) "x" else " ",
                m.path,
                if (m.active) "activa" else "inactiva",
            });
        }
    }

    fn cmdWebhookAdd(allocator: std.mem.Allocator, flag_args: []const []const u8) !void {
        var url: ?[]const u8 = null;
        var event: []const u8 = "task.completed";
        var i: usize = 0;
        while (i < flag_args.len) : (i += 1) {
            if (std.mem.eql(u8, flag_args[i], "--url") and i + 1 < flag_args.len) {
                url = flag_args[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, flag_args[i], "--event") and i + 1 < flag_args.len) {
                event = flag_args[i + 1];
                i += 1;
            }
        }
        if (url == null) {
            usoInvalido("Uso: devagents webhook add --url <url> [--event <evento>]", .{});
        }
        var runtime = abrirBase(allocator, .runtime);
        defer runtime.close();
        var reg = webhooks.WebhookRegistry.init(allocator, runtime);
        // QA-A H6/H12: un webhook rechazado sale con 1 y dice por qué en
        // palabras (antes «Error al registrar webhook: PrivateDestination», 0).
        reg.add(.out, url.?, event, null) catch |e|
            falla("No se registró el webhook: {s}.", .{webhooks.errorMessage(e)});
        std.debug.print("Webhook registrado: {s} -> {s}\n", .{ event, url.? });
    }

    fn cmdWebhookRemove(allocator: std.mem.Allocator, id_str: []const u8) !void {
        const id = std.fmt.parseInt(i64, id_str, 10) catch
            usoInvalido("«{s}» no es un número de webhook.\nUso: devagents webhook remove <id>", .{id_str});
        var runtime = abrirBase(allocator, .runtime);
        defer runtime.close();
        var reg = webhooks.WebhookRegistry.init(allocator, runtime);
        reg.remove(id) catch |e| switch (e) {
            error.NotFound, error.InvalidConfig => falla("No existe el webhook #{d} (míralos con `devagents webhook list`).", .{id}),
            else => falla("No se pudo eliminar el webhook #{d}: {s}.", .{ id, webhooks.errorMessage(e) }),
        };
        std.debug.print("Webhook #{d} eliminado.\n", .{id});
    }

    fn cmdWebhookList(allocator: std.mem.Allocator) !void {
        var runtime = abrirBase(allocator, .runtime);
        defer runtime.close();
        var reg = webhooks.WebhookRegistry.init(allocator, runtime);
        const list = reg.list(allocator) catch |e|
            falla("No se pudieron listar los webhooks: {s}.", .{webhooks.errorMessage(e)});
        defer {
            for (list) |w| {
                allocator.free(w.url);
                allocator.free(w.event);
                if (w.secret_encrypted) |s| allocator.free(s);
            }
            allocator.free(list);
        }
        if (list.len == 0) {
            std.debug.print("No hay webhooks registrados.\n", .{});
            return;
        }
        std.debug.print("Webhooks registrados:\n", .{});
        for (list) |w| {
            std.debug.print("  [{d}] {s} -> {s} ({s})\n", .{
                w.id,
                @tagName(w.direction),
                w.url,
                w.event,
            });
        }
    }
};

// ── tests del gate que EJECUTA lo que entrega ─────────────────────
//
// La reversión de estos tests es el estado anterior al arreglo: un entregable
// roto pasaba el gate porque nadie lo ejecutaba (vivió escondido tres
// órdenes así). Con comprobarContenido solo, el .py con SyntaxError de abajo
// daba PASA.

/// Crea una carpeta de orden de prueba dentro del workspace efectivo y escribe
/// en ella los archivos indicados. Devuelve el id de orden usado.
fn sembrarOrdenDePrueba(allocator: std.mem.Allocator, order_id: i64, archivos: []const struct { nombre: []const u8, cuerpo: []const u8 }) !void {
    var er_buf: [4096]u8 = undefined;
    const ws_abs = workspace.effectiveRoot(&er_buf);
    // La raíz del workspace no se puede dar por hecha: la crean otras pruebas,
    // y con el orden aleatorio de la suite el 22-09 estas cuatro corrieron
    // antes y cayeron en CreateFileA sin haber tocado el gate.
    const ws_z = try allocator.dupeZ(u8, ws_abs);
    defer allocator.free(ws_z);
    _ = CreateDirectoryA(ws_z.ptr, null);
    const dir = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "orden-{d}", .{ ws_abs, order_id });
    defer allocator.free(dir);
    const dir_z = try allocator.dupeZ(u8, dir);
    defer allocator.free(dir_z);
    _ = CreateDirectoryA(dir_z.ptr, null);
    for (archivos) |a| {
        const ruta = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ dir, a.nombre });
        defer allocator.free(ruta);
        const ruta_z = try allocator.dupeZ(u8, ruta);
        defer allocator.free(ruta_z);
        const h = CreateFileA(ruta_z.ptr, GENERIC_WRITE, 0, null, CREATE_ALWAYS, FILE_ATTRIBUTE_NORMAL, null);
        if (h == INVALID_HANDLE_VALUE) return error.NoSePudoEscribir;
        defer _ = CloseHandle(h);
        var escritos: u32 = 0;
        if (WriteFile(h, a.cuerpo.ptr, @intCast(a.cuerpo.len), &escritos, null) == 0) return error.NoSePudoEscribir;
    }
}

test "E-42: el gate RECHAZA un python con SyntaxError que antes pasaba" {
    // El caso del encargo, letra por letra: un entregable roto tiene que
    // tumbar el gate. Este .py tiene bytes de sobra (min_bytes=80), la palabra
    // `print` (debe_contener) y extensión correcta — con el gate viejo daba
    // PASA; ejecutándolo, python muere con SyntaxError y el gate da FALLO.
    const allocator = std.testing.allocator;
    const order_id: i64 = 990001;
    const cuerpo_roto = "# este script tiene print y bytes de sobra para el minimo del gate\nprint(\"hola\"\n_syntax_error_aqui_ ((\n# relleno para superar min_bytes ochenta: el gate viejo lo daba por bueno porque contaba bytes y buscaba la palabra print sin ejecutar nada\n";
    try sembrarOrdenDePrueba(allocator, order_id, &.{.{ .nombre = "t1.py", .cuerpo = cuerpo_roto }});

    const archivos = try workspace.listOrderFiles(allocator, order_id);
    defer {
        for (archivos) |f| f.deinit(allocator);
        allocator.free(archivos);
    }
    try std.testing.expect(archivos.len > 0);

    const caso = Cli.CasoGate{
        .nombre = "python-test",
        .orden = "",
        .exts = &.{".py"},
        .min_bytes = 80,
        .debe_contener = &.{"print"},
    };

    var buf: [256]u8 = undefined;
    const motivo = Cli.ejecutarEntregable(allocator, order_id, archivos, caso, &buf);
    if (motivo.len == 0) return error.ElRotoPasoElGate;
    // El motivo del fallo queda asertado: contiene exit (la ejecución de
    // verdad devolvió != 0) o el bloqueo de lanzamiento. El print de
    // diagnóstico que estuvo aquí en la sesión se retiró: un std.debug.print
    // en un test que pasa ensucia el stderr compartido del binario.
    try std.testing.expect(std.mem.indexOf(u8, motivo, "exit") != null or std.mem.indexOf(u8, motivo, "no se pudo lanzar") != null);
}

test "E-42: el gate ACEPTA un python que ejecuta limpio" {
    const allocator = std.testing.allocator;
    const order_id: i64 = 990002;
    const cuerpo_bueno = "# imprime los primeros 20 numeros primos\nprint(2)\nprint(3)\nprint(5)\nprint(7)\nprint(11)\nprint(13)\nprint(17)\nprint(19)\nprint(23)\nprint(29)\nprint(31)\nprint(37)\nprint(41)\n";
    try sembrarOrdenDePrueba(allocator, order_id, &.{.{ .nombre = "t1.py", .cuerpo = cuerpo_bueno }});

    const archivos = try workspace.listOrderFiles(allocator, order_id);
    defer {
        for (archivos) |f| f.deinit(allocator);
        allocator.free(archivos);
    }
    try std.testing.expect(archivos.len > 0);

    const caso = Cli.CasoGate{
        .nombre = "python-test",
        .orden = "",
        .exts = &.{".py"},
        .min_bytes = 80,
        .debe_contener = &.{"print"},
    };

    var buf: [256]u8 = undefined;
    const motivo = Cli.ejecutarEntregable(allocator, order_id, archivos, caso, &buf);
    if (motivo.len > 0) {
        std.debug.print("\n[E-42] motivo inesperado: {s}\n", .{motivo});
        return error.PruebaEjecucionFallo;
    }
}

test "E-42: el gate RECHAZA un HTML que referencia archivos no entregados (#184)" {
    const allocator = std.testing.allocator;
    const order_id: i64 = 990003;
    const html = "<html><head><link rel=\"stylesheet\" href=\"styles.css\"></head><body><button onclick=\"cargar()\">x</button><script src=\"script.js\"></script></body></html><!-- bytes de relleno para pasar el minimo del caso: este comentario existe para que el archivo supere los trescientos bytes que exige el gate de aceptacion del proyecto, porque el min_bytes del caso web es trescientos -->";
    try sembrarOrdenDePrueba(allocator, order_id, &.{.{ .nombre = "index.html", .cuerpo = html }});

    const archivos = try workspace.listOrderFiles(allocator, order_id);
    defer {
        for (archivos) |f| f.deinit(allocator);
        allocator.free(archivos);
    }
    try std.testing.expect(archivos.len > 0);

    const caso = Cli.CasoGate{
        .nombre = "web-test",
        .orden = "",
        .exts = &.{".html"},
        .min_bytes = 300,
        .debe_contener = &.{"<button"},
    };

    var buf: [256]u8 = undefined;
    const motivo = Cli.ejecutarEntregable(allocator, order_id, archivos, caso, &buf);
    try std.testing.expect(motivo.len > 0);
    // El motivo nombra el archivo que falta.
    try std.testing.expect(std.mem.indexOf(u8, motivo, "styles.css") != null or std.mem.indexOf(u8, motivo, "script.js") != null);
}

test "E-42: un JS de navegador NO se ejecuta con node (mismo criterio que E-50)" {
    const allocator = std.testing.allocator;
    const order_id: i64 = 990004;
    const js = "// script de navegador: document y window, no corre con node\ndocument.getElementById('x').onclick = () => window.alert('hola');";
    try sembrarOrdenDePrueba(allocator, order_id, &.{.{ .nombre = "script.js", .cuerpo = js }});

    const archivos = try workspace.listOrderFiles(allocator, order_id);
    defer {
        for (archivos) |f| f.deinit(allocator);
        allocator.free(archivos);
    }

    const caso = Cli.CasoGate{
        .nombre = "js-test",
        .orden = "",
        .exts = &.{".js"},
        .min_bytes = 80,
        .debe_contener = &.{},
    };

    var buf: [256]u8 = undefined;
    // No es fallo: se declara no ejecutable, igual que hace el motor.
    const motivo = Cli.ejecutarEntregable(allocator, order_id, archivos, caso, &buf);
    try std.testing.expectEqualStrings("", motivo);
}

test "CLI-CHAT: un stream terminado sin contenido falla y queda clasificado empty" {
    try std.testing.expectError(error.EmptyResponse, Cli.requireCompleteChatResponse(false, true, false));
}

test "CLI-CHAT: contenido visible requiere DONE o un finish normal" {
    try Cli.requireCompleteChatResponse(true, true, false);
    // Simula contenido seguido de EOF de transporte sin `finish_reason` ni
    // `[DONE]`: antes el CLI lo aceptaba y marcaba salud ok.
    try std.testing.expectError(error.IncompleteStream, Cli.requireCompleteChatResponse(true, false, false));
    try std.testing.expectError(error.TruncatedResponse, Cli.requireCompleteChatResponse(true, true, true));
    // Los errores de `nextChunk`, por ejemplo SseParseFailed, pasan por
    // classifyChatError en cmdChat y no se silencian como un EOF.
    try std.testing.expectEqual(health.Status.err, Cli.classifyChatError(error.SseParseFailed));
}

test "CLI-ERRORES: un fallo de uso del chat se propaga hasta el despachador" {
    // No toca catálogo ni red: comprueba que el despachador no convierte un
    // error de cmdChat en retorno exitoso. Se prueba `dispatch` (no `run`)
    // porque `run` ahora convierte los errores previsibles en un mensaje y
    // salida con código, sin dejar que suban como error.
    var args = [_][]const u8{ "devagents", "chat", "--provider", "__fixture_unknown_provider__", "--model", "fixture", "--prompt", "ignored" };
    try std.testing.expectError(error.UnknownProvider, Cli.dispatch(std.testing.allocator, args[0..]));
}

test "CLI-ERRORES: el nombre del proveedor no distingue mayúsculas (CK-MOT-019)" {
    // Defecto original: `health probe --provider openrouter` (minúsculas) no
    // encontraba "OpenRouter" y mataba el CLI con traza de pila. El nombre
    // del proveedor debe resolverse sin distinguir mayúsculas.
    const exacto = Cli.findProvider("OpenRouter") orelse return error.OpenRouterNoEncontrado;
    const minusculas = Cli.findProvider("openrouter") orelse return error.OpenRouterNoEncontrado;
    const mayusculas = Cli.findProvider("OPENROUTER") orelse return error.OpenRouterNoEncontrado;
    try std.testing.expectEqualStrings("OpenRouter", exacto.name);
    try std.testing.expectEqualStrings("OpenRouter", minusculas.name);
    try std.testing.expectEqualStrings("OpenRouter", mayusculas.name);
    // Un nombre que no existe sigue siendo desconocido.
    try std.testing.expect(Cli.findProvider("proveedor-que-no-existe") == null);
}

test "CLI-ERRORES: los fallos previsibles no muestran traza y salen con código != 0" {
    // Cada error esperable (proveedor desconocido, 401/402/429/404, red caída,
    // falta de clave, respuesta incompleta…) debe tener un reporte con código
    // distinto de 0. Si lleva mensaje, este NO puede contener ni `error:` ni
    // rutas de fuente `.zig:`, que es exactamente la traza que se quería evitar.
    const esperados = [_]anyerror{
        error.UnknownProvider,      error.NoActiveKey,         error.CredentialsUnavailable,
        error.HttpClientInitFailed, error.ConnectorInitFailed, error.BudgetDenied,
        error.RateLimited,          error.AuthFailed,          error.QuotaExceeded,
        error.ModelNotFound,        error.Timeout,             error.RequestFailed,
        error.ResponseFailed,       error.RedirectBlocked,     error.ProviderError,
        error.SseParseFailed,       error.EmptyResponse,       error.TruncatedResponse,
        error.IncompleteStream,
    };
    for (esperados) |e| {
        const r = Cli.reporteErrorEsperado(e) orelse return error.DeberiaSerErrorPrevisible;
        try std.testing.expect(r.code != 0);
        if (r.mensaje) |m| {
            try std.testing.expect(std.mem.indexOf(u8, m, "error:") == null);
            try std.testing.expect(std.mem.indexOf(u8, m, ".zig:") == null);
        }
    }
    // Un error realmente inesperado conserva su traza (reporte null → se
    // re-propaga, y `main` imprime el diagnóstico completo de Zig).
    try std.testing.expect(Cli.reporteErrorEsperado(error.ErrorRealmenteInesperado) == null);
    try std.testing.expect(Cli.reporteErrorEsperado(error.OutOfMemory) == null);
}

test "CLI-ERRORES: los fallos de proveedor traen mensaje accionable en español" {
    // El ejemplo medido en la máquina del propietario: 429 en el probe de OpenRouter.
    const r429 = Cli.reporteErrorEsperado(error.RateLimited) orelse return error.RateLimitedDeberiaSerPrevisible;
    const m429 = r429.mensaje orelse return error.RateLimitedDeberiaTraerMensaje;
    try std.testing.expect(std.mem.indexOf(u8, m429, "429") != null);
    // Clave inválida y red caída también deben traer su mensaje.
    const r401 = Cli.reporteErrorEsperado(error.AuthFailed) orelse return error.AuthFailedDeberiaSerPrevisible;
    try std.testing.expect(r401.mensaje != null);
    try std.testing.expect(std.mem.indexOf(u8, r401.mensaje.?, "clave") != null);
    const rRed = Cli.reporteErrorEsperado(error.RequestFailed) orelse return error.RequestFailedDeberiaSerPrevisible;
    try std.testing.expect(std.mem.indexOf(u8, rRed.mensaje.?, "conexi") != null);
}

/// una linea con la carpeta de datos REAL que abre esta CLI y su
/// fuente, para que `--version` la informe en vez de dejarla en la sombra.
pub fn dataDirStatusLine(allocator: std.mem.Allocator) ![]u8 {
    const resolved = try paths.resolveDataDir(allocator, null);
    defer allocator.free(resolved.dir);
    const fuente: []const u8 = switch (resolved.source) {
        .explicit_arg => "argumento explicito",
        .env_beats => "BEATS_DATA_DIR",
        .env_alias => "DEVAGENTS_DATA_DIR (alias)",
        .default_known_folders => "carpeta por defecto (API de carpetas conocidas)",
    };
    return std.fmt.allocPrint(allocator, "Carpeta de datos: {s} (fuente: {s})", .{ resolved.dir, fuente });
}

test "CK-MOT-033: el catálogo externo cacheado autoriza un pin free en la CLI" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.catalog_schema);

    const payload = "[{\"provider\":\"agent:opencode\",\"cli\":\"opencode\",\"exe\":\"C:/fixture/opencode.exe\",\"version\":\"1.18.25\",\"session\":\"api_key\",\"models\":[{\"slug\":\"opencode/x-free\",\"zero_cost\":true}]}]";
    const ins = try conn.prepare("INSERT INTO external_agent_cache(id,payload_json,detected_at) VALUES(1,?,?)");
    defer conn.finalize(ins);
    try db.bindText(ins, 1, payload);
    try db.bindInt(ins, 2, 1000);
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(ins));

    const catalog_json = try Cli.loadOrderExternalCatalog(a, conn, 1001);
    defer a.free(catalog_json);

    const status = try @import("model_selection.zig").externalEligibility(a, catalog_json, "agent:opencode", "opencode/x-free");
    try std.testing.expect(status.free);
}

test "CK-MOT-033: la CLI aplica el setting external_agent_limits del catálogo" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.catalog_schema);

    const ins = try conn.prepare("INSERT INTO settings(key,value) VALUES('external_agent_limits',?)");
    defer conn.finalize(ins);
    try db.bindText(ins, 1, "{\"task_timeout_ms\":1234,\"task_max_turns\":7,\"order_timeout_ms\":4321,\"order_max_turns\":9}");
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(ins));

    const limits = Cli.loadOrderExternalLimits(a, conn);
    try std.testing.expectEqual(@as(u64, 1234), limits.task_timeout_ms);
    try std.testing.expectEqual(@as(u32, 7), limits.task_max_turns);
    try std.testing.expectEqual(@as(u64, 4321), limits.order_timeout_ms);
    try std.testing.expectEqual(@as(u32, 9), limits.order_max_turns);
}

test "CK-MOT-033: order sale con 1 si la orden queda failed y con 0 si queda done o pendiente" {
    const failed = Cli.OrderRunSummary{ .dispatched = true, .failed = 1, .order_failed = true };
    const done = Cli.OrderRunSummary{ .dispatched = true, .completed = 1 };
    const pending = Cli.OrderRunSummary{ .dispatched = true, .failed = 1, .order_failed = true, .pending_approvals = 1 };
    try std.testing.expectEqual(@as(u8, 1), Cli.orderExitCode(failed));
    try std.testing.expectEqual(@as(u8, 0), Cli.orderExitCode(done));
    try std.testing.expectEqual(@as(u8, 0), Cli.orderExitCode(pending));
}

test "CK-MOT-033: order --help y -h piden ayuda sin lanzar la orden" {
    const largo = [_][]const u8{ "devagents-core.exe", "order", "--help" };
    const corto = [_][]const u8{ "devagents-core.exe", "order", "-h" };
    const real = [_][]const u8{ "devagents-core.exe", "order", "crea un archivo" };
    try std.testing.expect(Cli.orderHelpRequested(&largo));
    try std.testing.expect(Cli.orderHelpRequested(&corto));
    try std.testing.expect(!Cli.orderHelpRequested(&real));
}

// r2: `-h` como VALOR de --text/--answer/--provider/--model es la
// orden, no la ayuda (el parser los consume como valor).
test "CK-MOT-033 r2: -h como valor de --text/--answer no lanza la ayuda" {
    const texto_h = [_][]const u8{ "devagents-core.exe", "order", "--text", "-h" };
    const respuesta_h = [_][]const u8{ "devagents-core.exe", "order", "--answer", "-h" };
    const provider_h = [_][]const u8{ "devagents-core.exe", "order", "--provider", "-h", "--model", "x" };
    const bandera = [_][]const u8{ "devagents-core.exe", "order", "crea x", "--help" };
    const corto = [_][]const u8{ "devagents-core.exe", "order", "-h" };
    try std.testing.expect(!Cli.orderHelpRequested(&texto_h));
    try std.testing.expect(!Cli.orderHelpRequested(&respuesta_h));
    try std.testing.expect(!Cli.orderHelpRequested(&provider_h));
    try std.testing.expect(Cli.orderHelpRequested(&bandera));
    try std.testing.expect(Cli.orderHelpRequested(&corto));
}

// r2: wireExternalCatalog es el único punto de cableado del
// catálogo externo y los topes al Superagent (antes eran dos asignaciones
// sueltas en runOrder y las rutas design/TUI se quedaban sin cablear).
test "CK-MOT-033 r2: wireExternalCatalog cablea catálogo y topes al Superagent" {
    const a = std.testing.allocator;
    var runtime = try db.Connection.open(a, ":memory:");
    defer runtime.close();
    try db.Migrator.init(a).migrate(runtime, &db.runtime_schema);

    var mem_bundle = engram_memory.initFromEnv(a, runtime);
    defer mem_bundle.deinit();
    var sa = superagent.Superagent.init(a, runtime, null, mem_bundle.backend(), 1000);
    sa.setForcedModel("agent:opencode", "opencode/x-free");

    const payload = "[{\"provider\":\"agent:opencode\",\"cli\":\"opencode\",\"exe\":\"C:/fixture/opencode.exe\",\"version\":\"1.18.25\",\"session\":\"api_key\",\"models\":[{\"slug\":\"opencode/x-free\",\"zero_cost\":true}]}]";
    const limits = external_agents.Limits{ .task_timeout_ms = 1234, .task_max_turns = 7 };
    Cli.wireExternalCatalog(&sa, payload, limits);

    try std.testing.expect(sa.external_catalog_json != null);
    try std.testing.expectEqual(@as(u64, 1234), sa.external_limits.task_timeout_ms);
    try std.testing.expectEqual(@as(u32, 7), sa.external_limits.task_max_turns);

    // La misma cuenta que isModelFree (privado) hace dentro del Superagent,
    // leyendo POR EL CAMPO CABLEADO: el pin agent:opencode queda free.
    const status = try @import("model_selection.zig").externalEligibility(a, sa.external_catalog_json.?, "agent:opencode", "opencode/x-free");
    try std.testing.expect(status.free);
}

// r2: sin caché, loadOrderExternalCatalog toma la rama de
// refresco (detección real) y el resultado queda guardado para la siguiente
// orden. Sin red ni CLIs la respuesta es "[]", pero la rama y la escritura
// tienen que existir.
test "CK-MOT-033 r2: sin caché el catálogo externo se refresca y queda guardado" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba fija el entorno con SetEnvironmentVariableA y usa rutas Windows (barra invertida, devagents-core.exe); en Linux la CLI real se comprueba en L9 (T9-B-orden-mcp)");
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.catalog_schema);

    // r3: PATH aislado a una carpeta vacía. Antes esta prueba hacía
    // detección real de CLIs de la máquina y dependía de lo instalado.
    var prev_path: [32768]u8 = undefined;
    const prev_path_len = GetEnvironmentVariableA("PATH", &prev_path, prev_path.len);
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(cwd);
    const path_dir_plain = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".zig-cache" ++ std.fs.path.sep_str ++ "CK-MOT-033-r3-path", .{cwd});
    defer a.free(path_dir_plain);
    const path_dir = try a.dupeZ(u8, path_dir_plain);
    defer a.free(path_dir);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, path_dir);
    defer std.Io.Dir.cwd().deleteTree(std.testing.io, path_dir) catch {};
    defer _ = SetEnvironmentVariableA("PATH", if (prev_path_len > 0 and prev_path_len < prev_path.len) prev_path[0..prev_path_len :0].ptr else null);
    _ = SetEnvironmentVariableA("PATH", path_dir.ptr);

    const catalog_json = try Cli.loadOrderExternalCatalog(a, conn, health.nowSeconds(conn));
    defer a.free(catalog_json);
    try std.testing.expect(catalog_json.len > 0);
    try std.testing.expectEqual(@as(u8, '['), catalog_json[0]);
    const again = try external_registry.cached(a, conn, health.nowSeconds(conn));
    try std.testing.expect(again != null);
    if (again) |text| a.free(text);
}

// r2: external_agent_paths corrupto hace fallar el refresco y el
// error tiene que propagarse (runOrder lo captura UNA vez y sigue sin
// catálogo; la degradación vive allí, no aquí dentro).
test "CK-MOT-033 r2: catálogo externo corrupto propaga el error para degradar una sola vez" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.catalog_schema);

    // El schema siembra external_agent_paths='{}': hay que UPDATEar, no INSERTar.
    const upd = try conn.prepare("UPDATE settings SET value='[1]' WHERE key='external_agent_paths'");
    defer conn.finalize(upd);
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(upd));

    try std.testing.expectError(error.InvalidExternalAgentPaths, Cli.loadOrderExternalCatalog(a, conn, 1001));
}

// r2: external_agent_limits corrupto degrada a los defaults de
// Limits{} (nunca rompe la orden).
test "CK-MOT-033 r2: external_agent_limits corrupto degrada a los defaults" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.catalog_schema);

    const ins = try conn.prepare("INSERT INTO settings(key,value) VALUES('external_agent_limits','basura')");
    defer conn.finalize(ins);
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(ins));

    const limits = Cli.loadOrderExternalLimits(a, conn);
    const defaults = external_agents.Limits{};
    try std.testing.expectEqual(defaults.task_timeout_ms, limits.task_timeout_ms);
    try std.testing.expectEqual(defaults.task_max_turns, limits.task_max_turns);
    try std.testing.expectEqual(defaults.order_timeout_ms, limits.order_timeout_ms);
    try std.testing.expectEqual(defaults.order_max_turns, limits.order_max_turns);
}

/// r2: carpeta de datos TEMPORAL para las pruebas que llaman a
/// `Cli.runOrder` en el propio proceso (sin lanzar el binario). Fija
/// BEATS_DATA_DIR, retira el alias DEVAGENTS_DATA_DIR y restaura ambas al
/// salir; el árbol temporal se borra en deinit.
const DatosAislados = struct {
    dir: [:0]u8,
    dir_plain: []u8,
    prev_beats: [4096:0]u8,
    prev_alias: [4096:0]u8,
    beats_len: u32,
    alias_len: u32,

    fn init(a: std.mem.Allocator, tag: []const u8) !DatosAislados {
        var self: DatosAislados = undefined;
        self.beats_len = GetEnvironmentVariableA("BEATS_DATA_DIR", &self.prev_beats, self.prev_beats.len);
        self.alias_len = GetEnvironmentVariableA("DEVAGENTS_DATA_DIR", &self.prev_alias, self.prev_alias.len);
        // r3: si init falla DESPUÉS de tocar el entorno, deinit no
        // llega a registrarse. El errdefer devuelve el entorno a su estado
        // original aunque la carpeta temporal no llegue a crearse.
        errdefer {
            _ = SetEnvironmentVariableA("BEATS_DATA_DIR", if (self.beats_len > 0 and self.beats_len < self.prev_beats.len) self.prev_beats[0..self.beats_len :0].ptr else null);
            _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", if (self.alias_len > 0 and self.alias_len < self.prev_alias.len) self.prev_alias[0..self.alias_len :0].ptr else null);
        }
        _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", null);
        const testing_io = std.testing.io;
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(testing_io, ".", a);
        defer a.free(cwd);
        self.dir_plain = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".zig-cache" ++ std.fs.path.sep_str ++ "{s}", .{ cwd, tag });
        errdefer a.free(self.dir_plain);
        self.dir = try a.dupeZ(u8, self.dir_plain);
        errdefer a.free(self.dir);
        try std.Io.Dir.cwd().createDirPath(testing_io, self.dir);
        _ = SetEnvironmentVariableA("BEATS_DATA_DIR", self.dir.ptr);
        return self;
    }

    fn deinit(self: *DatosAislados, a: std.mem.Allocator) void {
        _ = SetEnvironmentVariableA("BEATS_DATA_DIR", if (self.beats_len > 0 and self.beats_len < self.prev_beats.len) self.prev_beats[0..self.beats_len :0].ptr else null);
        _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", if (self.alias_len > 0 and self.alias_len < self.prev_alias.len) self.prev_alias[0..self.alias_len :0].ptr else null);
        std.Io.Dir.cwd().deleteTree(std.testing.io, self.dir) catch {};
        a.free(self.dir);
        a.free(self.dir_plain);
    }

    fn runtimeDbPath(self: *const DatosAislados, a: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "runtime.db", .{self.dir_plain});
    }

    fn catalogDbPath(self: *const DatosAislados, a: std.mem.Allocator) ![]u8 {
        return std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "catalog.db", .{self.dir_plain});
    }

    /// catalog.db precreado y con el catálogo externo cacheado, para que la
    /// orden NO dependa de la detección real de CLIs de la máquina.
    fn seedCatalogoCacheado(self: *const DatosAislados, a: std.mem.Allocator) !void {
        const cat_path = try self.catalogDbPath(a);
        defer a.free(cat_path);
        var cat = try db.Connection.open(a, cat_path);
        defer cat.close();
        try db.Migrator.init(a).migrate(cat, &db.catalog_schema);
        const payload = "[{\"provider\":\"agent:opencode\",\"cli\":\"opencode\",\"exe\":\"C:/fixture/opencode.exe\",\"version\":\"1.18.25\",\"session\":\"api_key\",\"models\":[{\"slug\":\"opencode/x-free\",\"zero_cost\":true}]}]";
        const ins = try cat.prepare("INSERT INTO external_agent_cache(id,payload_json,detected_at) VALUES(1,?,?)");
        defer cat.finalize(ins);
        try db.bindText(ins, 1, payload);
        try db.bindInt(ins, 2, health.nowSeconds(cat));
        try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(ins));
    }

    /// r3: catálogo con el pin `agent:opencode/opencode/x-free`
    /// declarado gratuito, modo de coste Free y una fila en `models` para que
    /// el router exista y `lookupModelId` devuelva un id cuando la asignación
    /// sale `assigned`. Así una prueba que pase por `runOrder` puede distinguir
    /// «asignada» (cableado) de «no catalogada como gratuita» (sin cablear).
    fn seedCatalogoPinFree(self: *const DatosAislados, a: std.mem.Allocator) !void {
        try self.seedCatalogoCacheado(a);
        const cat_path = try self.catalogDbPath(a);
        defer a.free(cat_path);
        var cat = try db.Connection.open(a, cat_path);
        defer cat.close();
        try cat.exec("UPDATE settings SET value='free_tier_first' WHERE key='governance_mode'");
        try cat.exec("INSERT INTO providers(id,name,base_url,api_style) VALUES(1,'agent:opencode','local','cli')");
        try cat.exec("INSERT INTO models(id,provider_id,model_name,is_free,available) VALUES(1,1,'opencode/x-free',1,1)");
    }
};

/// r2: texto que MockPlanner resuelve sin clarificación (plan con
/// tareas), para que las pruebas lleguen al punto que les interesa.
const orden_prueba_r2 = "construye una calculadora CLI en C con tests";

/// r3: una orden de ejecución pura produce un plan determinista con
/// una tarea `.ejecutar` SIN pasar por el LLM. Eso permite probar el cableado
/// del catálogo a través de `runOrder` aunque haya un pin `agent:*` fijado (el
/// planificador LLM no degrada a MockPlanner cuando hay pin).
const orden_ejecutar_r3 = "ejecuta echo hola";

const Mot035Probe = struct {
    var calls: usize = 0;

    fn observe(sa: *superagent.Superagent) !void {
        calls += 1;
        try std.testing.expect(sa.external_catalog_json != null);
        const eligibility = try @import("model_selection.zig").externalEligibility(
            std.testing.allocator,
            sa.external_catalog_json.?,
            "agent:opencode",
            "opencode/x-free",
        );
        try std.testing.expect(eligibility.free);
        try std.testing.expectEqual(@as(u64, 1234), sa.external_limits.task_timeout_ms);
        try std.testing.expectEqual(@as(u32, 7), sa.external_limits.task_max_turns);
        try std.testing.expectEqual(@as(u64, 4321), sa.external_limits.order_timeout_ms);
        try std.testing.expectEqual(@as(u32, 9), sa.external_limits.order_max_turns);
    }

    fn seed(datos: *const DatosAislados, a: std.mem.Allocator) !void {
        try datos.seedCatalogoPinFree(a);
        const cat_path = try datos.catalogDbPath(a);
        defer a.free(cat_path);
        var cat = try db.Connection.open(a, cat_path);
        defer cat.close();
        try cat.exec(
            \\INSERT INTO settings(key,value) VALUES('external_agent_limits',
            \\'{"task_timeout_ms":1234,"task_max_turns":7,"order_timeout_ms":4321,"order_max_turns":9}')
        );
    }
};

test "CK-MOT-035: design carga catalogo y limites en su Superagent real" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba fija el entorno con SetEnvironmentVariableA y usa rutas Windows (barra invertida, devagents-core.exe); en Linux la CLI real se comprueba en L9 (T9-B-orden-mcp)");
    const a = std.testing.allocator;
    var datos = try DatosAislados.init(a, "CK-MOT-035-design");
    defer datos.deinit(a);
    try Mot035Probe.seed(&datos, a);
    Mot035Probe.calls = 0;
    cli_driver.ExternalCatalogRouteTest.observer = Mot035Probe.observe;
    defer cli_driver.ExternalCatalogRouteTest.observer = null;

    try Cli.cmdDesign(a, orden_ejecutar_r3, datos.dir_plain, "agent:opencode", "opencode/x-free");
    try std.testing.expectEqual(@as(usize, 1), Mot035Probe.calls);
}

test "CK-MOT-035: driver order carga catalogo y limites en su Superagent real" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba fija el entorno con SetEnvironmentVariableA y usa rutas Windows (barra invertida, devagents-core.exe); en Linux la CLI real se comprueba en L9 (T9-B-orden-mcp)");
    const a = std.testing.allocator;
    var datos = try DatosAislados.init(a, "CK-MOT-035-order");
    defer datos.deinit(a);
    try Mot035Probe.seed(&datos, a);
    const runtime_path = try datos.runtimeDbPath(a);
    defer a.free(runtime_path);
    Mot035Probe.calls = 0;
    cli_driver.ExternalCatalogRouteTest.observer = Mot035Probe.observe;
    defer cli_driver.ExternalCatalogRouteTest.observer = null;

    try cli_driver.ExternalCatalogRouteTest.order(a, runtime_path, orden_ejecutar_r3, .untrusted);
    try std.testing.expectEqual(@as(usize, 1), Mot035Probe.calls);
}

test "CK-MOT-035: driver approve carga catalogo y limites en su Superagent real" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba fija el entorno con SetEnvironmentVariableA y usa rutas Windows (barra invertida, devagents-core.exe); en Linux la CLI real se comprueba en L9 (T9-B-orden-mcp)");
    const a = std.testing.allocator;
    var datos = try DatosAislados.init(a, "CK-MOT-035-approve");
    defer datos.deinit(a);
    try Mot035Probe.seed(&datos, a);
    const runtime_path = try datos.runtimeDbPath(a);
    defer a.free(runtime_path);
    const catalog_path = try datos.catalogDbPath(a);
    defer a.free(catalog_path);
    var approval_id: i64 = 0;
    {
        var runtime = try db.Connection.open(a, runtime_path);
        defer runtime.close();
        try db.Migrator.init(a).migrate(runtime, &db.runtime_schema);
        var mp = planner.MockPlanner.init(a);
        const pb = mp.backend();
        defer pb.deinit();
        var sa = superagent.Superagent.init(a, runtime, null, superagent.NoopMemory.backend(), 1);
        sa.order_origin = .untrusted;
        var outcome = try sa.processOrder("driver", orden_prueba_r2, &.{}, pb, null, null);
        defer outcome.deinit();
        const approval = try runtime.prepare("INSERT INTO approvals(task_id,description,approved,resolved,created_at) VALUES(?,'CK-MOT-035',0,0,1)");
        defer runtime.finalize(approval);
        const task_id = try std.fmt.allocPrint(a, "order-{d}", .{outcome.order_id});
        defer a.free(task_id);
        try db.bindText(approval, 1, task_id);
        try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(approval));
        approval_id = db.c.sqlite3_last_insert_rowid(runtime.db);
    }
    Mot035Probe.calls = 0;
    cli_driver.ExternalCatalogRouteTest.observer = Mot035Probe.observe;
    defer cli_driver.ExternalCatalogRouteTest.observer = null;

    try cli_driver.ExternalCatalogRouteTest.approve(a, runtime_path, catalog_path, approval_id, true);
    try std.testing.expectEqual(@as(usize, 1), Mot035Probe.calls);
}

// r2: camino 1 — runtime.db no se puede abrir: otro HANDLE con
// share READ lo mantiene abierto, así el reparador DACL (solo controla
// derechos) pasa pero sqlite3_open recibe sharing violation (CantOpen). Antes
// el catch devolvía resumen vacío y `order` salía con 0.
test "CK-MOT-033 r2: runtime.db inabrible sale con order_failed y código 1" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba fija el entorno con SetEnvironmentVariableA y usa rutas Windows (barra invertida, devagents-core.exe); en Linux la CLI real se comprueba en L9 (T9-B-orden-mcp)");
    const a = std.testing.allocator;
    var datos = try DatosAislados.init(a, "CK-MOT-033-r2-a");
    defer datos.deinit(a);

    const rt_path = try datos.runtimeDbPath(a);
    defer a.free(rt_path);
    const rt_z = try a.dupeZ(u8, rt_path);
    defer a.free(rt_z);
    {
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, rt_path, .{});
        file.close(std.testing.io);
    }
    // share=0: SQLite no puede abrirlo ni siquiera en el reintento RO que
    // hace winOpen, y el reparador DACL (derechos de control) no debe chocar.
    const bloqueo = CreateFileA(rt_z, 0x80000000, 0x0, null, 3, 0x80, null);
    try std.testing.expect(bloqueo != windows.INVALID_HANDLE_VALUE);
    defer _ = CloseHandle(bloqueo);

    const resumen = try Cli.runOrder(a, orden_prueba_r2, null, true, null, null, true, false, "cli", false);
    try std.testing.expect(resumen.order_failed);
    try std.testing.expectEqual(@as(u8, 1), Cli.orderExitCode(resumen));
}

// r2: camino 2 — processOrder falla (un trigger aborta el INSERT
// de la orden). El catch imprimía y devolvía resumen vacío → código 0.
test "CK-MOT-033 r2: processOrder fallido sale con order_failed y código 1" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba fija el entorno con SetEnvironmentVariableA y usa rutas Windows (barra invertida, devagents-core.exe); en Linux la CLI real se comprueba en L9 (T9-B-orden-mcp)");
    const a = std.testing.allocator;
    var datos = try DatosAislados.init(a, "CK-MOT-033-r2-b");
    defer datos.deinit(a);
    try datos.seedCatalogoCacheado(a);

    const rt_path = try datos.runtimeDbPath(a);
    defer a.free(rt_path);
    {
        var rt = try db.Connection.open(a, rt_path);
        defer rt.close();
        try db.Migrator.init(a).migrate(rt, &db.runtime_schema);
        try rt.exec("CREATE TRIGGER mot033_r2_sin_insertar BEFORE INSERT ON orders BEGIN SELECT RAISE(ABORT,'CK-MOT-033'); END;");
    }

    const resumen = try Cli.runOrder(a, orden_prueba_r2, null, true, null, null, true, false, "cli", false);
    try std.testing.expect(resumen.order_failed);
    try std.testing.expectEqual(@as(u8, 1), Cli.orderExitCode(resumen));
}

// r2: camino 3 — el DESPACHO falla (un trigger aborta el UPDATE
// de aprobación del plan, que approveAndDispatch ejecuta antes de nada).
test "CK-MOT-033 r2: despacho fallido sale con order_failed y código 1" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba fija el entorno con SetEnvironmentVariableA y usa rutas Windows (barra invertida, devagents-core.exe); en Linux la CLI real se comprueba en L9 (T9-B-orden-mcp)");
    const a = std.testing.allocator;
    var datos = try DatosAislados.init(a, "CK-MOT-033-r2-c");
    defer datos.deinit(a);
    try datos.seedCatalogoCacheado(a);

    const rt_path = try datos.runtimeDbPath(a);
    defer a.free(rt_path);
    {
        var rt = try db.Connection.open(a, rt_path);
        defer rt.close();
        try db.Migrator.init(a).migrate(rt, &db.runtime_schema);
        try rt.exec("CREATE TRIGGER mot033_r2_no_aprobar BEFORE UPDATE OF approved ON plans BEGIN SELECT RAISE(ABORT,'CK-MOT-033'); END;");
    }

    const resumen = try Cli.runOrder(a, orden_prueba_r2, null, true, null, null, true, false, "cli", false);
    try std.testing.expect(resumen.order_failed);
    try std.testing.expectEqual(@as(u8, 1), Cli.orderExitCode(resumen));
}

// r3: la prueba anterior llamaba a wireExternalCatalog directamente;
// si se borraba la LLAMADA dentro de runOrder seguía en verde. Esta pasa por
// `runOrder` de verdad: con el catálogo cacheado, el modo Free y el pin
// agent:opencode/opencode/x-free, la asignación solo puede quedar `assigned`
// si runOrder cableó el catálogo. `assigned_model_id` se persiste en runtime.db.
test "CK-MOT-033 r3: runOrder cablea el catálogo y el pin free deja de rechazarse" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba fija el entorno con SetEnvironmentVariableA y usa rutas Windows (barra invertida, devagents-core.exe); en Linux la CLI real se comprueba en L9 (T9-B-orden-mcp)");
    const a = std.testing.allocator;
    var datos = try DatosAislados.init(a, "CK-MOT-033-r3-a");
    defer datos.deinit(a);
    try datos.seedCatalogoPinFree(a);

    // approve=false: planifica y se detiene antes de despachar. No hay red.
    const resumen = try Cli.runOrder(a, orden_ejecutar_r3, null, false, "agent:opencode", "opencode/x-free", true, false, "cli", false);
    try std.testing.expect(resumen.order_id > 0);
    try std.testing.expect(!resumen.order_failed);

    const rt_path = try datos.runtimeDbPath(a);
    defer a.free(rt_path);
    var rt = try db.Connection.open(a, rt_path);
    defer rt.close();
    // Sin el cableado, el pin cae en «Free: ... no catalogado como gratuito»
    // y `assignAndPersist` guarda assigned_model_id = NULL en TODAS las tareas.
    const stmt = try rt.prepare("SELECT COUNT(*) FROM tasks WHERE assigned_model_id IS NOT NULL");
    defer rt.finalize(stmt);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
    try std.testing.expect(db.c.sqlite3_column_int(stmt, 0) > 0);
}

// r3: con `external_agent_paths` corrupto y sin caché, el aviso de
// «catálogo no disponible» tiene que salir UNA sola vez. Se lanza la CLI real
// con la carpeta de datos aislada y se cuenta la línea en stderr.
test "CK-MOT-033 r3: catálogo externo corrupto avisa una sola vez por stderr" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba fija el entorno con SetEnvironmentVariableA y usa rutas Windows (barra invertida, devagents-core.exe); en Linux la CLI real se comprueba en L9 (T9-B-orden-mcp)");
    const a = std.testing.allocator;
    var datos = try DatosAislados.init(a, "CK-MOT-033-r3-b");
    defer datos.deinit(a);

    const cat_path = try datos.catalogDbPath(a);
    defer a.free(cat_path);
    {
        var cat = try db.Connection.open(a, cat_path);
        defer cat.close();
        try db.Migrator.init(a).migrate(cat, &db.catalog_schema);
        // Sin fila en external_agent_cache: loadOrderExternalCatalog va a refresh.
        try cat.exec("UPDATE settings SET value='[1]' WHERE key='external_agent_paths'");
    }

    const bin = (try @import("headless_adapter.zig").defaultGetEnv(a, "BEATS_TEST_BIN_DIR")) orelse return error.MissingMockBin;
    defer a.free(bin);
    const exe = try std.fs.path.join(a, &.{ bin, "devagents-core" ++ comptime @import("builtin").target.exeFileExt() });
    defer a.free(exe);

    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();

    // Sin --yes: planifica y se detiene pidiendo aprobación. Basta para cargar
    // el catálogo antes de despachar.
    var child = try std.process.spawn(io, .{
        .argv = &.{ exe, "order", orden_prueba_r2 },
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    });
    var out_buf: [8192]u8 = undefined;
    var err_buf: [8192]u8 = undefined;
    var out_reader = child.stdout.?.readerStreaming(io, &out_buf);
    var err_reader = child.stderr.?.readerStreaming(io, &err_buf);
    var stdout_text: [32768]u8 = undefined;
    var stderr_text: [32768]u8 = undefined;
    const stdout_len = try readAllLines(&out_reader, &stdout_text);
    const stderr_len = try readAllLines(&err_reader, &stderr_text);
    const term = try child.wait(io);
    try std.testing.expectEqual(@as(u32, 0), term.exited);
    _ = stdout_len;

    const err_text = stderr_text[0..stderr_len];
    const needle = "catálogo de agentes externos no disponible";
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, err_text, pos, needle)) |p| {
        count += 1;
        pos = p + needle.len;
    }
    try std.testing.expectEqual(@as(usize, 1), count);
}

// r3: un despacho que termina `failed` SIN devolver error también
// tiene que salir con código 1 (resumen.order_failed = dr.order_failed). El
// trigger adjunta una imagen a la orden: todas las tareas quedan needs_vision
// y el despacho mock las falla con «ningún modelo con visión medida», sin
// excepción y sin red.
test "CK-MOT-033 r3: despacho terminal-failed sin error sale con order_failed y código 1" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba fija el entorno con SetEnvironmentVariableA y usa rutas Windows (barra invertida, devagents-core.exe); en Linux la CLI real se comprueba en L9 (T9-B-orden-mcp)");
    const a = std.testing.allocator;
    var datos = try DatosAislados.init(a, "CK-MOT-033-r3-c");
    defer datos.deinit(a);

    const rt_path = try datos.runtimeDbPath(a);
    defer a.free(rt_path);
    // r3: el disparador crea un adjunto visual para que TODAS las
    // tareas pidan visión. `loadOrderImageParts` exige el archivo real en
    // disco, así que se precrea un PNG 1x1 válido (el fixture de
    // order_attachments) con el sha256 que declara el adjunto.
    const png_fixture = [_]u8{
        137, 80,  78,  71, 13, 10,  26,  10, 0,   0,   0,   13,  73,  72, 68,  82, 0, 0,
        0,   1,   0,   0,  0,  1,   8,   2,  0,   0,   0,   144, 119, 83, 222, 0,  0, 0,
        12,  73,  68,  65, 84, 120, 156, 99, 248, 207, 192, 0,   0,   3,  1,   1,  0, 201,
        254, 146, 239, 0,  0,  0,   0,   73, 69,  78,  68,  174, 66,  96, 130,
    };
    const png_sha = "b1ff9c8ea3a780bad09b346c423d2d0e46815926879b18e841d928376a946640";
    var oid: i64 = 1;
    while (oid <= 8) : (oid += 1) {
        const dir = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "attachments" ++ std.fs.path.sep_str ++ "{d}", .{ datos.dir_plain, oid });
        defer a.free(dir);
        try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
        const file_path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "{s}.png", .{ dir, png_sha });
        defer a.free(file_path);
        const file = try std.Io.Dir.cwd().createFile(std.testing.io, file_path, .{});
        defer file.close(std.testing.io);
        try file.writeStreamingAll(std.testing.io, &png_fixture);
    }
    {
        var rt = try db.Connection.open(a, rt_path);
        defer rt.close();
        try db.Migrator.init(a).migrate(rt, &db.runtime_schema);
        try rt.exec(
            "CREATE TRIGGER mot033_r3_adjunto AFTER INSERT ON orders BEGIN " ++
                "INSERT INTO order_attachments(order_id,sha256,name,mime_type,extension,size_bytes,width,height,relative_path) " ++
                "VALUES(NEW.id,'b1ff9c8ea3a780bad09b346c423d2d0e46815926879b18e841d928376a946640','x.png','image/png','png',69,1,1,'attachments/1/x.png'); END;",
        );
    }

    const resumen = try Cli.runOrder(a, orden_prueba_r2, null, true, null, null, true, false, "cli", false);
    try std.testing.expect(resumen.dispatched);
    try std.testing.expect(resumen.failed > 0);
    try std.testing.expectEqual(@as(usize, 0), resumen.pending_approvals);
    try std.testing.expect(resumen.order_failed);
    try std.testing.expectEqual(@as(u8, 1), Cli.orderExitCode(resumen));
}

test "CK-PLT-007: --version informa la carpeta de datos resuelta" {
    const a = std.testing.allocator;
    const line = try dataDirStatusLine(a);
    defer a.free(line);
    try std.testing.expect(std.mem.startsWith(u8, line, "Carpeta de datos: "));
    // Nunca un placeholder: o resuelve la carpeta real o dice el fallo cerrado.
    try std.testing.expect(std.mem.indexOf(u8, line, "(cwd default)") == null);
}

// (C4): se LANZA el binario real de la CLI con BEATS_DATA_DIR
// apuntando a una carpeta temporal bajo .zig-cache y se comprueba que informa
// ESA carpeta (y no ninguna otra). La variable la fija el codigo de prueba.
test "CK-PLT-007: devagents-core --version lanzado con BEATS_DATA_DIR informa la carpeta temporal" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba fija el entorno con SetEnvironmentVariableA y usa rutas Windows (barra invertida, devagents-core.exe); en Linux la CLI real se comprueba en L9 (T9-B-orden-mcp)");
    const a = std.testing.allocator;

    var prev_beats: [4096:0]u8 = undefined;
    var prev_alias: [4096:0]u8 = undefined;
    const beats_len = GetEnvironmentVariableA("BEATS_DATA_DIR", &prev_beats, prev_beats.len);
    const alias_len = GetEnvironmentVariableA("DEVAGENTS_DATA_DIR", &prev_alias, prev_alias.len);
    defer {
        _ = SetEnvironmentVariableA("BEATS_DATA_DIR", if (beats_len > 0 and beats_len < prev_beats.len) prev_beats[0..beats_len :0].ptr else null);
        _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", if (alias_len > 0 and alias_len < prev_alias.len) prev_alias[0..alias_len :0].ptr else null);
    }
    _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", null);

    const testing_io = std.testing.io;
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(testing_io, ".", a);
    defer a.free(cwd);
    const dir_plain = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".zig-cache" ++ std.fs.path.sep_str ++ "CK-PLT-007-cli", .{cwd});
    defer a.free(dir_plain);
    const dir = try a.dupeZ(u8, dir_plain);
    defer a.free(dir);
    try std.Io.Dir.cwd().createDirPath(testing_io, dir);
    defer std.Io.Dir.cwd().deleteTree(testing_io, dir) catch {};
    _ = SetEnvironmentVariableA("BEATS_DATA_DIR", dir.ptr);

    const bin = (try @import("headless_adapter.zig").defaultGetEnv(a, "BEATS_TEST_BIN_DIR")) orelse return error.MissingMockBin;
    defer a.free(bin);
    const exe = try std.fs.path.join(a, &.{ bin, "devagents-core" ++ comptime @import("builtin").target.exeFileExt() });
    defer a.free(exe);

    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();

    var child = try std.process.spawn(io, .{
        .argv = &.{ exe, "--version" },
        .stdout = .pipe,
        // La CLI imprime sus mensajes por stderr (std.debug.print): hay que
        // drenar ambos pipes para que el hijo no se bloquea.
        .stderr = .pipe,
        .create_no_window = true,
    });
    var out_buf: [8192]u8 = undefined;
    var err_buf: [8192]u8 = undefined;
    var out_reader = child.stdout.?.readerStreaming(io, &out_buf);
    var err_reader = child.stderr.?.readerStreaming(io, &err_buf);
    var stdout_text: [16384]u8 = undefined;
    var stderr_text: [16384]u8 = undefined;
    const stdout_len = try readAllLines(&out_reader, &stdout_text);
    const stderr_len = try readAllLines(&err_reader, &stderr_text);
    _ = try child.wait(io);

    const salida = stdout_text[0..stdout_len];
    const mensajes = stderr_text[0..stderr_len];
    try std.testing.expect(salida.len + mensajes.len > 0);
    // Sin «(cwd default)» ni rutas de otra carpeta: la temporal fijada por la prueba.
    try std.testing.expect(std.mem.indexOf(u8, mensajes, "(cwd default)") == null);
    try std.testing.expect(std.mem.indexOf(u8, mensajes, "Carpeta de datos: ") != null);
    try std.testing.expect(std.mem.indexOf(u8, mensajes, dir) != null);
}

// (C4, r3): se LANZA la CLI de verdad con BEATS_DATA_DIR aislado
// (la variable la fija este codigo de prueba, nunca el comando) y se comprueba
// que ABRE su base AHI: `models list` crea catalog.db dentro de la carpeta
// aislada y no deja ninguna base relativa al cwd de la suite.
test "CK-PLT-007: la CLI lanzada abre su base en el BEATS_DATA_DIR aislado" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba fija el entorno con SetEnvironmentVariableA y usa rutas Windows (barra invertida, devagents-core.exe); en Linux la CLI real se comprueba en L9 (T9-B-orden-mcp)");
    const a = std.testing.allocator;

    var prev_beats: [4096:0]u8 = undefined;
    var prev_alias: [4096:0]u8 = undefined;
    const beats_len = GetEnvironmentVariableA("BEATS_DATA_DIR", &prev_beats, prev_beats.len);
    const alias_len = GetEnvironmentVariableA("DEVAGENTS_DATA_DIR", &prev_alias, prev_alias.len);
    defer {
        _ = SetEnvironmentVariableA("BEATS_DATA_DIR", if (beats_len > 0 and beats_len < prev_beats.len) prev_beats[0..beats_len :0].ptr else null);
        _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", if (alias_len > 0 and alias_len < prev_alias.len) prev_alias[0..alias_len :0].ptr else null);
    }
    _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", null);

    const testing_io = std.testing.io;
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(testing_io, ".", a);
    defer a.free(cwd);
    const dir_plain = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".zig-cache" ++ std.fs.path.sep_str ++ "CK-PLT-007-cli-base", .{cwd});
    defer a.free(dir_plain);
    const dir = try a.dupeZ(u8, dir_plain);
    defer a.free(dir);
    try std.Io.Dir.cwd().createDirPath(testing_io, dir);
    defer std.Io.Dir.cwd().deleteTree(testing_io, dir) catch {};
    _ = SetEnvironmentVariableA("BEATS_DATA_DIR", dir.ptr);

    // Antes del lanzamiento: si el cwd de la suite no tenia catalog.db,
    // tampoco debe aparecer tras (la base NO se abre relativa al cwd).
    const cwd_cat = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "catalog.db", .{cwd});
    defer a.free(cwd_cat);
    const cwd_cat_z = try a.dupeZ(u8, cwd_cat);
    defer a.free(cwd_cat_z);
    const cwd_tenia_db = GetFileAttributesA(cwd_cat_z) != 0xFFFFFFFF;

    const bin = (try @import("headless_adapter.zig").defaultGetEnv(a, "BEATS_TEST_BIN_DIR")) orelse return error.MissingMockBin;
    defer a.free(bin);
    const exe = try std.fs.path.join(a, &.{ bin, "devagents-core" ++ comptime @import("builtin").target.exeFileExt() });
    defer a.free(exe);

    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();

    var child = try std.process.spawn(io, .{
        .argv = &.{ exe, "models", "list" },
        .stdout = .pipe,
        // La CLI imprime sus mensajes por stderr: hay que drenar ambos pipes
        // para que el hijo no se bloquea.
        .stderr = .pipe,
        .create_no_window = true,
    });
    var out_buf: [8192]u8 = undefined;
    var err_buf: [8192]u8 = undefined;
    var out_reader = child.stdout.?.readerStreaming(io, &out_buf);
    var err_reader = child.stderr.?.readerStreaming(io, &err_buf);
    var stdout_text: [16384]u8 = undefined;
    var stderr_text: [16384]u8 = undefined;
    const stdout_len = try readAllLines(&out_reader, &stdout_text);
    const stderr_len = try readAllLines(&err_reader, &stderr_text);
    _ = try child.wait(io);

    try std.testing.expect(stdout_len + stderr_len > 0);

    // La base abierta por la CLI lanzada esta DENTRO de la carpeta aislada
    // (catalog.db creado ahi), no relativa al cwd ni en otra carpeta.
    const cat_plain = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "catalog.db", .{dir});
    defer a.free(cat_plain);
    const cat_z = try a.dupeZ(u8, cat_plain);
    defer a.free(cat_z);
    const attrs = GetFileAttributesA(cat_z);
    try std.testing.expect(attrs != 0xFFFFFFFF);
    try std.testing.expect((attrs & 0x10) == 0);
    if (!cwd_tenia_db) {
        try std.testing.expect(GetFileAttributesA(cwd_cat_z) == 0xFFFFFFFF);
    }
}

// `order --help` se lanza como usuario real: debe imprimir el uso,
// salir con 0 y NO crear una orden (ni siquiera abrir runtime.db).
test "CK-MOT-033: order --help imprime el uso, sale con 0 y no crea la orden" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba fija el entorno con SetEnvironmentVariableA y usa rutas Windows (barra invertida, devagents-core.exe); en Linux la CLI real se comprueba en L9 (T9-B-orden-mcp)");
    const a = std.testing.allocator;

    var prev_beats: [4096:0]u8 = undefined;
    var prev_alias: [4096:0]u8 = undefined;
    const beats_len = GetEnvironmentVariableA("BEATS_DATA_DIR", &prev_beats, prev_beats.len);
    const alias_len = GetEnvironmentVariableA("DEVAGENTS_DATA_DIR", &prev_alias, prev_alias.len);
    defer {
        _ = SetEnvironmentVariableA("BEATS_DATA_DIR", if (beats_len > 0 and beats_len < prev_beats.len) prev_beats[0..beats_len :0].ptr else null);
        _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", if (alias_len > 0 and alias_len < prev_alias.len) prev_alias[0..alias_len :0].ptr else null);
    }
    _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", null);

    const testing_io = std.testing.io;
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(testing_io, ".", a);
    defer a.free(cwd);
    const dir_plain = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".zig-cache" ++ std.fs.path.sep_str ++ "CK-MOT-033-order-help", .{cwd});
    defer a.free(dir_plain);
    const dir = try a.dupeZ(u8, dir_plain);
    defer a.free(dir);
    try std.Io.Dir.cwd().createDirPath(testing_io, dir);
    defer std.Io.Dir.cwd().deleteTree(testing_io, dir) catch {};
    _ = SetEnvironmentVariableA("BEATS_DATA_DIR", dir.ptr);

    const bin = (try @import("headless_adapter.zig").defaultGetEnv(a, "BEATS_TEST_BIN_DIR")) orelse return error.MissingMockBin;
    defer a.free(bin);
    const exe = try std.fs.path.join(a, &.{ bin, "devagents-core" ++ comptime @import("builtin").target.exeFileExt() });
    defer a.free(exe);

    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();

    var child = try std.process.spawn(io, .{
        .argv = &.{ exe, "order", "--help" },
        .stdout = .pipe,
        .stderr = .pipe,
        .create_no_window = true,
    });
    var out_buf: [8192]u8 = undefined;
    var err_buf: [8192]u8 = undefined;
    var out_reader = child.stdout.?.readerStreaming(io, &out_buf);
    var err_reader = child.stderr.?.readerStreaming(io, &err_buf);
    var stdout_text: [16384]u8 = undefined;
    var stderr_text: [16384]u8 = undefined;
    const stdout_len = try readAllLines(&out_reader, &stdout_text);
    const stderr_len = try readAllLines(&err_reader, &stderr_text);
    const term = try child.wait(io);

    try std.testing.expectEqual(@as(u32, 0), term.exited);
    const salida = std.mem.concat(a, u8, &.{ stdout_text[0..stdout_len], stderr_text[0..stderr_len] }) catch return error.OutOfMemory;
    defer a.free(salida);
    try std.testing.expect(std.mem.indexOf(u8, salida, "Uso: devagents order") != null);

    const rt_plain = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "runtime.db", .{dir});
    defer a.free(rt_plain);
    const rt_z = try a.dupeZ(u8, rt_plain);
    defer a.free(rt_z);
    try std.testing.expect(GetFileAttributesA(rt_z) == 0xFFFFFFFF);
}

// ── QA-A (14-nov): la CLI lanzada de verdad sale con código distinto de 0 en
// todo fallo (H6), valida `mount add` (H8), rechaza modos de gobernanza
// desconocidos sin tocar nada (H9) y aguanta un primer arranque concurrente
// (H1). DEVAGENTS_DATA_DIR la fija este código de prueba sobre una carpeta
// nueva bajo.zig-cache; BEATS_DATA_DIR se quita y ambas se restauran.

const QaACli = struct {
    exe: []u8,
    dir: [:0]u8,
    prev_beats: [4096:0]u8 = undefined,
    prev_alias: [4096:0]u8 = undefined,
    beats_len: u32 = 0,
    alias_len: u32 = 0,

    fn init(a: std.mem.Allocator, tag: []const u8) !QaACli {
        const bin = (try @import("headless_adapter.zig").defaultGetEnv(a, "BEATS_TEST_BIN_DIR")) orelse return error.MissingMockBin;
        defer a.free(bin);
        const exe = try std.fs.path.join(a, &.{ bin, "devagents-core" ++ comptime @import("builtin").target.exeFileExt() });
        errdefer a.free(exe);
        const cwd = try std.Io.Dir.cwd().realPathFileAlloc(std.testing.io, ".", a);
        defer a.free(cwd);
        const dir = try std.fmt.allocPrintSentinel(a, "{s}" ++ std.fs.path.sep_str ++ ".zig-cache" ++ std.fs.path.sep_str ++ "{s}-{d}", .{ cwd, tag, GetTickCount64Cli() }, 0);
        errdefer a.free(dir);
        try std.Io.Dir.cwd().createDirPath(std.testing.io, dir);
        var self = QaACli{ .exe = exe, .dir = dir };
        self.beats_len = GetEnvironmentVariableA("BEATS_DATA_DIR", &self.prev_beats, self.prev_beats.len);
        self.alias_len = GetEnvironmentVariableA("DEVAGENTS_DATA_DIR", &self.prev_alias, self.prev_alias.len);
        _ = SetEnvironmentVariableA("BEATS_DATA_DIR", null);
        _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", dir.ptr);
        return self;
    }

    fn deinit(self: *QaACli, a: std.mem.Allocator) void {
        _ = SetEnvironmentVariableA("BEATS_DATA_DIR", if (self.beats_len > 0 and self.beats_len < self.prev_beats.len) self.prev_beats[0..self.beats_len :0].ptr else null);
        _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", if (self.alias_len > 0 and self.alias_len < self.prev_alias.len) self.prev_alias[0..self.alias_len :0].ptr else null);
        std.Io.Dir.cwd().deleteTree(std.testing.io, self.dir) catch |e| std.debug.print("QA-A limpieza de {s}: {s}\n", .{ self.dir, @errorName(e) });
        a.free(self.dir);
        a.free(self.exe);
    }

    const Salida = struct { code: u32, text: []const u8 };

    /// Lanza la CLI y devuelve su código y stdout+stderr (en `buf`).
    fn run(self: *const QaACli, a: std.mem.Allocator, args: []const []const u8, buf: []u8) !Salida {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(a);
        try argv.append(a, self.exe);
        try argv.appendSlice(a, args);
        var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
        defer threaded.deinit();
        const io = threaded.io();
        var child = try std.process.spawn(io, .{ .argv = argv.items, .stdout = .pipe, .stderr = .pipe, .create_no_window = true });
        var out_buf: [8192]u8 = undefined;
        var err_buf: [8192]u8 = undefined;
        var out_reader = child.stdout.?.readerStreaming(io, &out_buf);
        var err_reader = child.stderr.?.readerStreaming(io, &err_buf);
        const half = buf.len / 2;
        const out_len = try readAllLines(&out_reader, buf[0..half]);
        const err_len = try readAllLines(&err_reader, buf[half..]);
        const term = try child.wait(io);
        std.mem.copyForwards(u8, buf[out_len .. out_len + err_len], buf[half .. half + err_len]);
        const code: u32 = switch (term) {
            .exited => |c| c,
            else => 255,
        };
        return .{ .code = code, .text = buf[0 .. out_len + err_len] };
    }

    fn expectCode(self: *const QaACli, a: std.mem.Allocator, args: []const []const u8, code: u32, needle: ?[]const u8) !void {
        var buf: [32768]u8 = undefined;
        const s = try self.run(a, args, &buf);
        const ok = s.code == code and (needle == null or std.mem.indexOf(u8, s.text, needle.?) != null);
        if (!ok) {
            std.debug.print("QA-A: `devagents", .{});
            for (args) |x| std.debug.print(" {s}", .{x});
            std.debug.print("` salió con {d} (se esperaba {d}{s}{s}):\n{s}\n", .{ s.code, code, if (needle != null) " y el texto «" else "", needle orelse "", s.text });
            return error.TestUnexpectedResult;
        }
    }
};

const GetTickCount64 = @import("platform.zig").ticks;
fn GetTickCount64Cli() u64 {
    return GetTickCount64();
}

test "QA-A H1: ocho CLI a la vez sobre una carpeta de datos nueva salen todas con 0" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba fija el entorno con SetEnvironmentVariableA y usa rutas Windows (barra invertida, devagents-core.exe); en Linux la CLI real se comprueba en L9 (T9-B-orden-mcp)");
    const a = std.testing.allocator;
    var cli = try QaACli.init(a, "QA-A-H1");
    defer cli.deinit(a);
    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();
    var children: [8]std.process.Child = undefined;
    for (&children) |*ch| {
        ch.* = try std.process.spawn(io, .{ .argv = &.{ cli.exe, "mount", "list" }, .stdout = .pipe, .stderr = .pipe, .create_no_window = true });
    }
    var fallos: usize = 0;
    for (&children, 0..) |*ch, i| {
        var out_buf: [4096]u8 = undefined;
        var err_buf: [4096]u8 = undefined;
        var out_reader = ch.stdout.?.readerStreaming(io, &out_buf);
        var err_reader = ch.stderr.?.readerStreaming(io, &err_buf);
        var text: [8192]u8 = undefined;
        _ = try readAllLines(&out_reader, text[0..4096]);
        const err_len = try readAllLines(&err_reader, text[4096..]);
        const term = try ch.wait(io);
        const code: u32 = switch (term) {
            .exited => |c| c,
            else => 255,
        };
        // Antes salían con 0 aun fallando: también cuenta el mensaje.
        if (code != 0 or std.mem.indexOf(u8, text[4096 .. 4096 + err_len], "No se pudo") != null) {
            fallos += 1;
            std.debug.print("QA-A H1: proceso {d} salió con {d}: {s}\n", .{ i, code, text[4096 .. 4096 + err_len] });
        }
    }
    try std.testing.expectEqual(@as(usize, 0), fallos);
    // Y la base queda usable: la siguiente orden funciona.
    try cli.expectCode(a, &.{ "mount", "list" }, 0, "No hay carpetas montadas.");
}

test "QA-A H6/H8/H9: la CLI lanzada sale con código distinto de 0 en cada fallo" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba fija el entorno con SetEnvironmentVariableA y usa rutas Windows (barra invertida, devagents-core.exe); en Linux la CLI real se comprueba en L9 (T9-B-orden-mcp)");
    const a = std.testing.allocator;
    var cli = try QaACli.init(a, "QA-A-H6");
    defer cli.deinit(a);

    const no_existe = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "no-existe", .{cli.dir});
    defer a.free(no_existe);
    const existe = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "carpeta-montable", .{cli.dir});
    defer a.free(existe);
    try std.Io.Dir.cwd().createDirPath(std.testing.io, existe);

    // H8: mismas reglas que una raíz nueva de verdad.
    try cli.expectCode(a, &.{ "mount", "add", no_existe }, 1, "no existe");
    try cli.expectCode(a, &.{ "mount", "add", "C:/" }, 1, "raíz de una unidad");
    try cli.expectCode(a, &.{ "mount", "add", "\\\\servidor\\recurso" }, 1, "UNC");
    try cli.expectCode(a, &.{ "mount", "add", "\\\\.\\NUL" }, 1, "dispositivo");
    try cli.expectCode(a, &.{ "mount", "add", existe }, 0, "Montada:");
    try cli.expectCode(a, &.{ "mount", "add", existe }, 1, "ya estaba montada");
    try cli.expectCode(a, &.{ "mount", "list" }, 0, existe);
    {
        // Ninguna ruta rechazada llegó al registro.
        var buf: [32768]u8 = undefined;
        const s = try cli.run(a, &.{ "mount", "list" }, &buf);
        try std.testing.expect(std.mem.indexOf(u8, s.text, "no-existe") == null);
        try std.testing.expect(std.mem.indexOf(u8, s.text, "servidor") == null);
        try std.testing.expect(std.mem.indexOf(u8, s.text, "NUL") == null);
    }

    // H6: cada fallo, con 1 (o 2 si es de uso), y en palabras (H12).
    try cli.expectCode(a, &.{ "mount", "remove", no_existe }, 1, "No hay ningún montaje");
    try cli.expectCode(a, &.{ "mount", "remove", existe }, 0, "Desmontada:");
    try cli.expectCode(a, &.{ "webhook", "add", "--url", "http://127.0.0.1:9/x" }, 1, "dirección privada o local");
    try cli.expectCode(a, &.{ "webhook", "remove", "999" }, 1, "No existe el webhook #999");
    try cli.expectCode(a, &.{ "webhook", "remove", "abc" }, 2, "no es un número");
    try cli.expectCode(a, &.{ "mount", "bogus" }, 2, null);
    try cli.expectCode(a, &.{ "webhook", "bogus" }, 2, null);
    try cli.expectCode(a, &.{ "models", "bogus" }, 2, null);
    try cli.expectCode(a, &.{"models"}, 2, null);
    try cli.expectCode(a, &.{ "debug", "last" }, 1, "Todavía no hay ninguna orden");
    try cli.expectCode(a, &.{"usage"}, 0, "sin registros de consumo");

    // H9: un modo desconocido es error de uso y NO cambia nada.
    try cli.expectCode(a, &.{ "governance", "free" }, 0, "Gobernanza: free\n");
    try cli.expectCode(a, &.{ "governance", "gratix" }, 2, "free, paid, hybrid, local");
    try cli.expectCode(a, &.{"governance"}, 0, "Gobernanza: free\n");
    try cli.expectCode(a, &.{ "governance", "local" }, 0, "Gobernanza: local\n");
}

test "QA-A H13: chat con un modelo que el catálogo no conoce dice «modelo desconocido» (código 2)" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba fija el entorno con SetEnvironmentVariableA y usa rutas Windows (barra invertida, devagents-core.exe); en Linux la CLI real se comprueba en L9 (T9-B-orden-mcp)");
    const a = std.testing.allocator;
    var cli = try QaACli.init(a, "QA-A-H13");
    defer cli.deinit(a);
    {
        const cat_path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "catalog.db", .{cli.dir});
        defer a.free(cat_path);
        var cat = try db.Connection.open(a, cat_path);
        defer cat.close();
        try db.Migrator.init(a).migrate(cat, &db.catalog_schema);
        try cat.exec("INSERT OR IGNORE INTO providers(name,base_url,api_style) VALUES('OpenCode','https://example.invalid','openai')");
        try cat.exec("INSERT OR IGNORE INTO providers(name,base_url,api_style) VALUES('Groq','https://example.invalid','openai')");
        try cat.exec("INSERT INTO models(provider_id,model_name) SELECT id,'mimo-v2.5-free' FROM providers WHERE name='OpenCode'");
        try cat.exec("INSERT INTO models(provider_id,model_name) SELECT id,'nope-pero-parecido' FROM providers WHERE name='OpenCode'");
        try cat.exec("INSERT INTO models(provider_id,model_name) SELECT id,'solo-en-groq' FROM providers WHERE name='Groq'");
    }
    // Antes: «Sin clave activa para OpenCode» (culpaba a la clave).
    try cli.expectCode(a, &.{ "chat", "--model", "nope", "--prompt", "hola" }, 2, "modelo desconocido: nope");
    try cli.expectCode(a, &.{ "chat", "--model", "nope", "--prompt", "hola" }, 2, "nope-pero-parecido");
    try cli.expectCode(a, &.{ "chat", "--model", "solo-en-groq", "--prompt", "hola" }, 2, "--provider Groq");
    // Un modelo que sí existe sigue al paso siguiente (sin clave → 1, como antes).
    try cli.expectCode(a, &.{ "chat", "--model", "mimo-v2.5-free", "--prompt", "hola" }, 1, "Sin clave activa para OpenCode");
}

/// drena un pipe de hijo hasta EOF copiando las lineas al buffer
/// dado. Devuelve los bytes escritos.
fn readAllLines(reader: anytype, dest: []u8) !usize {
    var len: usize = 0;
    while (true) {
        const maybe = reader.interface.takeDelimiter('\n') catch break;
        const line = maybe orelse break;
        if (len + line.len + 1 <= dest.len) {
            @memcpy(dest[len .. len + line.len], line);
            len += line.len;
            dest[len] = '\n';
            len += 1;
        }
    }
    return len;
}

test "CK-MCP-005 (T7): la ayuda lista todos los subcomandos que atiende la CLI" {
    for (Cli.HELP_COMMANDS) |command| {
        var buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&buf, "devagents {s}", .{command});
        if (std.mem.indexOf(u8, Cli.HELP_TEXT, needle) == null) {
            std.debug.print("falta en la ayuda: {s}\n", .{needle});
            return error.TestUnexpectedResult;
        }
    }
    // Cada `command, "<x>"` que despacha este archivo esta en HELP_COMMANDS
    // (salvo los alias de ayuda y el modo supervisado heredado de `server`).
    const source = @embedFile("cli.zig");
    const marker = "eql(u8, command, \"";
    var rest: []const u8 = source;
    var seen: usize = 0;
    while (std.mem.indexOf(u8, rest, marker)) |at| {
        const start = at + marker.len;
        const end = start + (std.mem.indexOfScalar(u8, rest[start..], '"') orelse break);
        const name = rest[start..end];
        rest = rest[end..];
        seen += 1;
        const alias = for ([_][]const u8{ "-h", "--help", "/?", "--supervised" }) |a| {
            if (std.mem.eql(u8, a, name)) break true;
        } else false;
        if (alias) continue;
        const listed = for (Cli.HELP_COMMANDS) |c| {
            if (std.mem.eql(u8, c, name)) break true;
        } else false;
        if (!listed) {
            std.debug.print("subcomando fuera de la ayuda: {s}\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(seen >= 15);
}

test "VG2: ayuda pública de la CLI en español" {
    try std.testing.expect(std.mem.indexOf(u8, Cli.HELP_TEXT, "Comandos:") != null);
    for ([_][]const u8{ "List available models", "Run model router", "Manage linked folders", "dev-team Pixel" }) |old| {
        try std.testing.expect(std.mem.indexOf(u8, Cli.HELP_TEXT, old) == null);
    }
}
