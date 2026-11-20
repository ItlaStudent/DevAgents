//! D4 (E1) — primer tramo del motor FUERA del proceso de la cabina.
//!
//! Hoy el motor es una DLL cargada EN el host: un `abort()` en Zig se lleva la
//! ventana entera. El objetivo de D4 no es «tener un bus» —el bus ya existía,
//! `core/src/bus/`— sino que **un cierre inesperado del motor deje de ser un
//! cierre de la aplicación**.
//!
//! Estado del tramo: `da_status` —y solo `da_status`— se atiende por un proceso
//! HIJO a través del bus de tuberías con nombre. El resto de las ~60 exportadas
//! de la frontera C-ABI sigue por DLL, como estaba. Es deliberado: pasarlas
//! todas de golpe es inviable, y este tramo es el que permite comprobar la
//! promesa entera con una sola función.
//!
//! Lo que había antes de este archivo: `da_status` existía ÚNICAMENTE dentro de
//! un test de `named_pipe.zig` en el que el servidor y el cliente eran el mismo
//! proceso y el servidor se respondía a sí mismo con un literal. No había hijo,
//! no había nada que matar y no había nada que reconectar.
//!
//! El criterio de aceptación es literal: **se mata el hijo y el llamador sigue
//! vivo y vuelve a tener respuesta.** Eso es `Supervisor.status()` devolviendo
//! datos otra vez después de un `TerminateProcess`.

const std = @import("std");
const windows = std.os.windows;
const protocol = @import("bus/protocol.zig");
const named_pipe = @import("bus/named_pipe.zig");

extern "kernel32" fn CreateProcessA(
    lpApplicationName: ?[*:0]const u8,
    lpCommandLine: [*:0]u8,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: c_int,
    dwCreationFlags: u32,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u8,
    lpStartupInfo: *STARTUPINFOA,
    lpProcessInformation: *PROCESS_INFORMATION,
) c_int;
extern "kernel32" fn TerminateProcess(hProcess: windows.HANDLE, uExitCode: u32) c_int;
extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: u32) u32;
extern "kernel32" fn GetExitCodeProcess(hProcess: windows.HANDLE, lpExitCode: *u32) c_int;
const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) c_int;
}.CloseHandle else @import("providers").posix_files.CloseHandle;
const Sleep = @import("platform.zig").sleep;
extern "kernel32" fn GetModuleFileNameA(hModule: ?windows.HANDLE, lpFilename: [*]u8, nSize: u32) u32;

const STARTUPINFOA = extern struct {
    cb: u32 = @sizeOf(STARTUPINFOA),
    lpReserved: ?[*:0]u8 = null,
    lpDesktop: ?[*:0]u8 = null,
    lpTitle: ?[*:0]u8 = null,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32 = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*u8 = null,
    hStdInput: ?windows.HANDLE = null,
    hStdOutput: ?windows.HANDLE = null,
    hStdError: ?windows.HANDLE = null,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: windows.HANDLE,
    hThread: windows.HANDLE,
    dwProcessId: u32,
    dwThreadId: u32,
};

const CREATE_NO_WINDOW: u32 = 0x08000000;
const STILL_ACTIVE: u32 = 259;

/// Lo que responde el motor a `da_status`. Se deja como estructura y no como
/// texto suelto para que el día que se migre otra exportada no haya que
/// adivinar el formato desde dos sitios.
pub const Status = struct {
    online: bool,
    /// PID del hijo que respondió. Es la prueba de que la respuesta viene de
    /// OTRO proceso: si el reinicio funciona, este número cambia.
    pid: u32,
    version: []const u8,
};

/// Nombre de la tubería para un identificador de sesión dado.
pub fn pipeNameFor(allocator: std.mem.Allocator, session: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "devagents-engine-{s}", .{session});
}

/// El lado HIJO: sirve la tubería hasta que el cliente se va o lo matan.
///
/// Vive aquí, y no en el `main` del ejecutable, para que el mismo código que
/// corre en producción sea el que corre en el test — un servidor de prueba
/// distinto del real no prueba el real.
pub fn serve(allocator: std.mem.Allocator, pipe_name: []const u8) !void {
    var server = try named_pipe.NamedPipeServer.init(pipe_name);
    defer server.deinit();

    while (true) {
        server.waitForConnection() catch return;

        // Una conexión atiende mensajes hasta que el cliente cierra la tubería.
        while (true) {
            var msg = server.receiveMessage(allocator) catch break;
            defer msg.deinit();

            switch (@as(protocol.MsgType, @enumFromInt(msg.header.msg_type))) {
                .ping => {
                    var pong = protocol.Message.create(allocator, .pong, "pong") catch break;
                    defer pong.deinit();
                    server.sendMessage(&pong) catch break;
                },
                .status_request => {
                    // La respuesta lleva el PID REAL de este proceso. Es lo que
                    // convierte el test de aceptación en una comprobación y no
                    // en una declaración: si tras matar al hijo el PID que
                    // vuelve es otro, hubo un proceso nuevo de verdad.
                    const payload = std.fmt.allocPrint(
                        allocator,
                        "{{\"status\":\"online\",\"pid\":{d},\"version\":\"{s}\"}}",
                        .{ processId(), @import("root.zig").VERSION },
                    ) catch break;
                    defer allocator.free(payload);
                    var resp = protocol.Message.create(allocator, .status_response, payload) catch break;
                    defer resp.deinit();
                    server.sendMessage(&resp) catch break;
                },
                else => {
                    // Un mensaje que este tramo no atiende NO se traga en
                    // silencio: el cliente tiene que poder distinguir «no
                    // implementado» de «el motor se murió».
                    var resp = protocol.Message.create(allocator, .log_event, "{\"error\":\"unsupported_in_stage_1\"}") catch break;
                    defer resp.deinit();
                    server.sendMessage(&resp) catch break;
                },
            }
        }

        server.disconnect() catch {};
    }
}

/// El lado PADRE: arranca el hijo, habla con él y lo levanta si se cae.
pub const Supervisor = struct {
    allocator: std.mem.Allocator,
    exe_path: []const u8,
    pipe_name: []const u8,
    proc: ?PROCESS_INFORMATION = null,
    client: ?named_pipe.NamedPipeClient = null,
    /// Cuántas veces se ha levantado el hijo tras caerse. Lo consume el test de
    /// aceptación y sirve de telemetría barata.
    restarts: usize = 0,

    pub fn init(allocator: std.mem.Allocator, exe_path: []const u8, pipe_name: []const u8) !Supervisor {
        return .{
            .allocator = allocator,
            .exe_path = try allocator.dupe(u8, exe_path),
            .pipe_name = try allocator.dupe(u8, pipe_name),
        };
    }

    pub fn deinit(self: *Supervisor) void {
        self.closeClient();
        self.killChild();
        self.allocator.free(self.exe_path);
        self.allocator.free(self.pipe_name);
    }

    fn closeClient(self: *Supervisor) void {
        if (self.client) |*c| c.deinit();
        self.client = null;
    }

    fn killChild(self: *Supervisor) void {
        if (self.proc) |p| {
            _ = TerminateProcess(p.hProcess, 0);
            _ = WaitForSingleObject(p.hProcess, 2000);
            _ = CloseHandle(p.hThread);
            _ = CloseHandle(p.hProcess);
        }
        self.proc = null;
    }

    /// PID del hijo vivo, o null si no hay ninguno.
    pub fn childPid(self: *const Supervisor) ?u32 {
        const p = self.proc orelse return null;
        return p.dwProcessId;
    }

    /// ¿Sigue vivo el hijo? Se pregunta al SO, no a una bandera nuestra.
    pub fn childAlive(self: *const Supervisor) bool {
        const p = self.proc orelse return false;
        var code: u32 = 0;
        if (GetExitCodeProcess(p.hProcess, &code) == 0) return false;
        return code == STILL_ACTIVE;
    }

    fn spawn(self: *Supervisor) !void {
        const cmd = try std.fmt.allocPrintSentinel(self.allocator, "\"{s}\" --engine-pipe {s}", .{ self.exe_path, self.pipe_name }, 0);
        defer self.allocator.free(cmd);
        const exe_z = try self.allocator.dupeZ(u8, self.exe_path);
        defer self.allocator.free(exe_z);

        var si: STARTUPINFOA = .{};
        var pi: PROCESS_INFORMATION = undefined;
        // El binario va FIJADO en lpApplicationName: que el SO no resuelva por
        // la línea de comandos es la misma invariante de seguridad que ya
        // aplica `executor.zig`.
        if (CreateProcessA(exe_z.ptr, cmd.ptr, null, null, 0, CREATE_NO_WINDOW, null, null, &si, &pi) == 0) {
            return error.SpawnFailed;
        }
        self.proc = pi;
    }

    /// Conecta al hijo, esperando a que cree la tubería.
    ///
    /// El hijo tarda unos milisegundos en llamar a `CreateNamedPipe`; intentar
    /// conectar antes da `FileNotFound`. Se reintenta con plazo en vez de
    /// dormir una cantidad fija: un `Sleep(500)` a ojo es lento cuando va bien
    /// y falla cuando la máquina va cargada.
    fn connectWithDeadline(self: *Supervisor, deadline_ms: u32) !void {
        var esperado: u32 = 0;
        while (esperado < deadline_ms) : (esperado += 20) {
            if (named_pipe.NamedPipeClient.init(self.pipe_name)) |c| {
                self.client = c;
                return;
            } else |_| {
                if (!self.childAlive()) return error.ChildDied;
                Sleep(20);
            }
        }
        return error.ConnectTimeout;
    }

    /// Arranca el hijo y deja la conexión lista. Idempotente.
    pub fn start(self: *Supervisor) !void {
        if (self.client != null and self.childAlive()) return;
        self.closeClient();
        self.killChild();
        try self.spawn();
        errdefer self.killChild();
        try self.connectWithDeadline(3000);
    }

    /// `da_status` por el bus. Si el hijo se murió, lo levanta y reintenta UNA
    /// vez: es una reconexión, no un bucle de reintentos: si el motor está roto
    /// de verdad, quien llama tiene que enterarse, no quedarse esperando.
    pub fn status(self: *Supervisor) !Status {
        if (self.statusOnce()) |s| return s else |_| {}

        // Segundo intento: reconectar (levantando el hijo si hace falta).
        self.closeClient();
        if (!self.childAlive()) {
            self.killChild();
            try self.spawn();
            self.restarts += 1;
        }
        try self.connectWithDeadline(3000);
        return self.statusOnce();
    }

    fn statusOnce(self: *Supervisor) !Status {
        const c = &(self.client orelse return error.NotConnected);
        var req = try protocol.Message.create(self.allocator, .status_request, "{\"query\":\"da_status\"}");
        defer req.deinit();
        try c.sendMessage(&req);

        var resp = try c.receiveMessage(self.allocator);
        defer resp.deinit();
        if (resp.header.msg_type != @intFromEnum(protocol.MsgType.status_response)) return error.UnexpectedMessage;

        return .{
            .online = std.mem.indexOf(u8, resp.payload, "\"status\":\"online\"") != null,
            .pid = parseUintField(resp.payload, "\"pid\":") orelse 0,
            .version = "",
        };
    }
};

/// Extrae un entero sin signo detrás de `key` en un JSON plano.
///
/// No se usa `std.json` a propósito: la respuesta es un objeto de tres campos
/// generado por nosotros dos archivos más arriba, y meter el parser completo
/// aquí obligaría a gestionar su arena en la ruta de estado, que es la que
/// tiene que seguir viva cuando todo lo demás se cae.
fn parseUintField(payload: []const u8, key: []const u8) ?u32 {
    const at = std.mem.indexOf(u8, payload, key) orelse return null;
    var i = at + key.len;
    while (i < payload.len and (payload[i] == ' ' or payload[i] == '"')) i += 1;
    const start = i;
    while (i < payload.len and payload[i] >= '0' and payload[i] <= '9') i += 1;
    if (i == start) return null;
    return std.fmt.parseInt(u32, payload[start..i], 10) catch null;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "D4: parseUintField saca el pid y no se inventa uno" {
    try std.testing.expectEqual(@as(?u32, 4242), parseUintField("{\"status\":\"online\",\"pid\":4242,\"v\":\"x\"}", "\"pid\":"));
    try std.testing.expectEqual(@as(?u32, null), parseUintField("{\"status\":\"online\"}", "\"pid\":"));
    // Un campo presente pero sin dígitos es ausencia, no cero: devolver 0 aquí
    // sería inventarse un PID (R15: un número de relleno es un número inventado).
    try std.testing.expectEqual(@as(?u32, null), parseUintField("{\"pid\":}", "\"pid\":"));
}

/// Ruta comprobada del motor de pruebas. El prefijo temporal puede diferir
/// del cwd aislado de la suite; no debe omitirse D4 por buscar en el repo.
fn engineExePath(allocator: std.mem.Allocator) !?[]const u8 {
    const bin = try @import("headless_adapter.zig").defaultGetEnv(allocator, "BEATS_TEST_BIN_DIR");
    defer if (bin) |p| allocator.free(p);
    const candidato = if (bin) |p| try std.fs.path.join(allocator, &.{ p, "devagents-engine" ++ comptime @import("builtin").target.exeFileExt() }) else try allocator.dupe(u8, "zig-out\\bin\\devagents-engine.exe");
    errdefer allocator.free(candidato);
    const z = try allocator.dupeZ(u8, candidato);
    defer allocator.free(z);
    const h = CreateFileAforTest(z.ptr);
    if (h == INVALID_HANDLE_VALUE_T) {
        allocator.free(candidato);
        return null;
    }
    _ = CloseHandle(h);
    return candidato;
}

const CreateFileA = switch (@import("builtin").os.tag) {
    .windows => struct {
        extern "kernel32" fn CreateFileA(lpFileName: [*:0]const u8, dwDesiredAccess: u32, dwShareMode: u32, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: u32, dwFlagsAndAttributes: u32, hTemplateFile: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
    }.CreateFileA,
    else => @import("providers").posix_files.CreateFileA,
};
const INVALID_HANDLE_VALUE_T: windows.HANDLE = @ptrFromInt(std.math.maxInt(usize));
fn CreateFileAforTest(p: [*:0]const u8) windows.HANDLE {
    return CreateFileA(p, 0x80000000, 0x00000001 | 0x00000002, null, 3, 0, null);
}

test "D4: matar el proceso del motor NO se lleva al llamador, que reconecta" {
    if (@import("builtin").os.tag != .windows) {
        // The Windows host Supervisor has no POSIX caller. Exercise the same
        // engine and framed IPC with a real child, kill, and fresh reconnect.
        return posixEngineRestartTest();
    }
    // El criterio de aceptación de D4, literal: «matar el proceso hijo y que la
    // cabina siga viva y reconecte».
    //
    // Lo que se comprueba, en este orden:
    //   1. `da_status` responde desde OTRO proceso (el PID no es el nuestro).
    //   2. Se mata ese proceso de verdad (TerminateProcess), no se simula.
    //   3. El llamador sigue vivo — si no, este test no llegaría a la línea 4.
    //   4. `da_status` vuelve a responder, y con un PID DISTINTO: hubo proceso
    //      nuevo, no una respuesta cacheada.
    const allocator = std.testing.allocator;

    const exe = (try engineExePath(allocator)) orelse {
        std.debug.print("\n[D4] FAIL: falta devagents-engine.exe en el prefijo de instalación de esta suite\n", .{});
        return error.TestEngineMissing;
    };
    defer allocator.free(exe);

    const pipe = try pipeNameFor(allocator, "test-d4-acept");
    defer allocator.free(pipe);

    var sup = try Supervisor.init(allocator, exe, pipe);
    defer sup.deinit();
    try sup.start();

    // 1. Responde, y desde otro proceso.
    const antes = try sup.status();
    try std.testing.expect(antes.online);
    try std.testing.expect(antes.pid != 0);
    try std.testing.expect(antes.pid != processId());
    try std.testing.expectEqual(sup.childPid().?, antes.pid);

    // 2. Se mata el motor. Esto es lo que hoy se lleva la ventana entera.
    const pid_muerto = antes.pid;
    sup.killChild();
    try std.testing.expect(!sup.childAlive());

    // 3 y 4. El llamador sigue en pie y vuelve a tener respuesta, de un proceso
    // nuevo. `restarts` sube: la reconexión ocurrió, no se dio por buena.
    const despues = try sup.status();
    try std.testing.expect(despues.online);
    try std.testing.expect(despues.pid != 0);
    try std.testing.expect(despues.pid != pid_muerto);
    try std.testing.expectEqual(@as(usize, 1), sup.restarts);
}

fn posixEngineRestartTest() !void {
    const a = std.testing.allocator;
    const bin = (try @import("headless_adapter.zig").defaultGetEnv(a, "BEATS_TEST_BIN_DIR")) orelse return error.TestEngineMissing;
    defer a.free(bin);
    const exe = try std.fs.path.join(a, &.{ bin, "devagents-engine" });
    defer a.free(exe);
    var t: std.Io.Threaded = .init(a, .{ .environ = @import("platform.zig").environ() });
    defer t.deinit();
    const io = t.io();
    var previous_pid: u32 = 0;
    for (0..2) |attempt| {
        const pipe = try std.fmt.allocPrint(a, "b10-engine-{d}-{d}", .{ std.c.getpid(), attempt });
        defer a.free(pipe);
        const socket = try std.fmt.allocPrintSentinel(a, "/tmp/devagents-{d}/{x}.sock", .{ std.c.getuid(), std.hash.Wyhash.hash(0, pipe) }, 0);
        defer a.free(socket);
        // Only this process's unique endpoint is removed after its child dies.
        defer if (std.c.unlink(socket) != 0 and std.c._errno().* != @intFromEnum(std.posix.E.NOENT)) {
            std.debug.panic("B10 engine fixture unlink failed: {d}", .{std.c._errno().*});
        };
        var child = try std.process.spawn(io, .{ .argv = &.{ exe, "--engine-pipe", pipe }, .stdin = .ignore, .stdout = .ignore });
        defer child.kill(io);
        const pid: u32 = @intCast(child.id.?);
        try std.testing.expect(pid != processId() and pid != previous_pid);
        previous_pid = pid;
        const start = @import("platform.zig").ticks();
        var client = while (@import("platform.zig").ticks() - start < 3000) {
            if (named_pipe.NamedPipeClient.init(pipe)) |c| break c else |_| Sleep(10);
        } else return error.ConnectTimeout;
        defer client.deinit();
        var request = try protocol.Message.create(a, .status_request, "{\"query\":\"da_status\"}");
        defer request.deinit();
        try client.sendMessage(&request);
        var response = try client.receiveMessage(a);
        defer response.deinit();
        try std.testing.expectEqual(@intFromEnum(protocol.MsgType.status_response), response.header.msg_type);
        try std.testing.expectEqual(@as(?u32, pid), parseUintField(response.payload, "\"pid\":"));
        try std.testing.expect(std.mem.indexOf(u8, response.payload, "\"status\":\"online\"") != null);
        child.kill(io);
        try std.testing.expect(std.c.kill(@intCast(pid), if (@import("builtin").os.tag == .linux) @enumFromInt(0) else 0) != 0);
        try std.testing.expectEqual(@intFromEnum(std.posix.E.SRCH), std.c._errno().*);
    }
}

test "D4: pipeNameFor no colisiona entre sesiones" {
    const allocator = std.testing.allocator;
    const a = try pipeNameFor(allocator, "sesion-a");
    defer allocator.free(a);
    const b = try pipeNameFor(allocator, "sesion-b");
    defer allocator.free(b);
    try std.testing.expect(!std.mem.eql(u8, a, b));
}

fn processId() u32 {
    return switch (@import("builtin").os.tag) {
        .windows => windows.GetCurrentProcessId(),
        else => @intCast(std.c.getpid()),
    };
}
