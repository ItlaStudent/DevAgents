//! core/src/tui/host.zig — (E1): backend de PRODUCCIÓN de la sesión.
//!
//! Conecta el estado/render puros con el producto real: versión y proyecto del
//! directorio actual, rama git (leyendo HEAD, sin lanzar procesos), gobernanza
//! y catálogo con el MISMO código que `devagents governance` / `models list`
//! (model_router.Router y model_catalog.ModelCatalog sobre catalog.db), y la
//! orden escrita reenviada al flujo existente `devagents order` lanzando el
//! propio ejecutable como hijo con stdout/stderr capturados.
//!
//! E2 usa `order --tui-session`: el hijo conserva el plan mientras espera
//! aprobación por su stdin privado. Ctrl+C termina únicamente ese hijo.

const std = @import("std");
const builtin = @import("builtin");
const model_catalog = @import("../model_catalog.zig");
const model_router = @import("../model_router.zig");
const paths = @import("../paths.zig");
const db = @import("../db.zig");
const windows_argv = @import("../windows_argv.zig");
const state = @import("state.zig");
const console = @import("console.zig");
const interaction = @import("interaction.zig");

const windows = std.os.windows;

// ── Externs propios (estilo del proyecto) ───────────────────────────────
extern "kernel32" fn GetCurrentDirectoryA(nBufferLength: u32, lpBuffer: [*]u8) callconv(.winapi) u32;
const GetEnvironmentVariableA = @import("../platform.zig").env;
extern "kernel32" fn GetModuleFileNameW(hModule: ?*anyopaque, lpFilename: [*]u16, nSize: u32) callconv(.winapi) u32;
extern "kernel32" fn CreatePipe(hReadPipe: *windows.HANDLE, hWritePipe: *windows.HANDLE, lpPipeAttributes: ?*anyopaque, nSize: u32) callconv(.winapi) c_int;
extern "kernel32" fn SetHandleInformation(hObject: windows.HANDLE, dwMask: u32, dwFlags: u32) callconv(.winapi) c_int;
extern "kernel32" fn CreateProcessW(lpApplicationName: ?[*:0]const u16, lpCommandLine: [*:0]u16, lpProcessAttributes: ?*anyopaque, lpThreadAttributes: ?*anyopaque, bInheritHandles: c_int, dwCreationFlags: u32, lpEnvironment: ?*anyopaque, lpCurrentDirectory: ?[*:0]const u16, lpStartupInfo: *windows.STARTUPINFOW, lpProcessInformation: *PROCESS_INFORMATION) callconv(.winapi) c_int;
extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.winapi) c_int;
extern "kernel32" fn ReadFile(hFile: windows.HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn WriteFile(hFile: windows.HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn PeekNamedPipe(hNamedPipe: windows.HANDLE, lpBuffer: ?*anyopaque, nBufferSize: u32, lpBytesRead: ?*u32, lpTotalBytesAvail: ?*u32, lpBytesLeftThisMessage: ?*u32) callconv(.winapi) c_int;
extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn GetExitCodeProcess(hProcess: windows.HANDLE, lpExitCode: *u32) callconv(.winapi) c_int;
extern "kernel32" fn TerminateProcess(hProcess: windows.HANDLE, uExitCode: u32) callconv(.winapi) c_int;
const Sleep = @import("../platform.zig").sleep;

const PROCESS_INFORMATION = extern struct {
    hProcess: windows.HANDLE,
    hThread: windows.HANDLE,
    dwProcessId: u32,
    dwThreadId: u32,
};

const SECURITY_ATTRIBUTES = extern struct {
    nLength: u32,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: c_int,
};

const HANDLE_FLAG_INHERIT: u32 = 0x00000001;
const STARTF_USESTDHANDLES: u32 = 0x00000100;
const CREATE_NO_WINDOW: u32 = 0x08000000;
const WAIT_OBJECT_0: u32 = 0x00000000;

/// Salida e interacción de una orden en curso: `emit` recibe lo que escribe el
/// hijo; `pump` se llama entre lecturas y devuelve true si hay que cancelar;
/// `progress` recibe los avisos de avance por tarea (E3).
pub const OrderSink = struct {
    ctx: ?*anyopaque = null,
    emit: *const fn (?*anyopaque, []const u8) void,
    pump: *const fn (?*anyopaque) bool,
    request: *const fn (?*anyopaque, interaction.Request) []const u8 = denyRequest,
    progress: *const fn (?*anyopaque, []const u8) void = ignoreProgress,
};

fn denyRequest(_: ?*anyopaque, _: interaction.Request) []const u8 {
    return interaction.CANCEL;
}

fn ignoreProgress(_: ?*anyopaque, _: []const u8) void {}

pub const Host = struct {
    allocator: std.mem.Allocator,
    project_root: []u8,
    project_name: []u8,
    branch: []u8,
    governance: []u8,
    no_color: bool,

    pub fn init(allocator: std.mem.Allocator) !Host {
        const root = try currentDir(allocator);
        errdefer allocator.free(root);
        const name = try lastPathComponent(allocator, root);
        errdefer allocator.free(name);
        const branch = readGitBranch(allocator, root) catch try allocator.dupe(u8, "sin git");
        errdefer allocator.free(branch);
        const gov = governanceCode(allocator) catch try allocator.dupe(u8, "hybrid");
        errdefer allocator.free(gov);
        return .{
            .allocator = allocator,
            .project_root = root,
            .project_name = name,
            .branch = branch,
            .governance = gov,
            .no_color = noColorRequested(),
        };
    }

    pub fn deinit(self: *Host) void {
        self.allocator.free(self.project_root);
        self.allocator.free(self.project_name);
        self.allocator.free(self.branch);
        self.allocator.free(self.governance);
        self.* = undefined;
    }

    pub fn config(self: *Host, allocator: std.mem.Allocator) !state.Config {
        _ = allocator;
        return .{
            .project_root = self.project_root,
            .project_name = self.project_name,
            .branch = self.branch,
            .model = "auto (router)",
            .governance = state.govLabel(self.governance),
            .no_color = self.no_color,
        };
    }
};

/// Sondeo NO_COLOR: variable presente y no vacía.
pub fn noColorRequested() bool {
    if (builtin.os.tag != .windows) return false;
    var buf: [16]u8 = undefined;
    const n = GetEnvironmentVariableA("NO_COLOR", &buf, buf.len);
    return n > 0;
}

fn currentDir(allocator: std.mem.Allocator) ![]u8 {
    if (builtin.os.tag != .windows) return allocator.dupe(u8, ".");
    var buf: [4096]u8 = undefined;
    const n = GetCurrentDirectoryA(buf.len, &buf);
    if (n == 0 or n >= buf.len) return error.CurrentDirUnavailable;
    return allocator.dupe(u8, buf[0..n]);
}

/// Último componente de una ruta (proyecto que muestra la bienvenida).
pub fn lastPathComponent(allocator: std.mem.Allocator, path_in: []const u8) ![]u8 {
    const path = std.mem.trimEnd(u8, path_in, "\\/");
    if (path.len == 0) return allocator.dupe(u8, path_in);
    var start: usize = 0;
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        if (path[i] == '\\' or path[i] == '/') start = i + 1;
    }
    if (path[start..].len == 2 and path[start + 1] == ':') return allocator.dupe(u8, path_in);
    return allocator.dupe(u8, path[start..]);
}

/// Contenido de un HEAD de git → nombre de rama, o hash corto si está
/// separado (detached), o "sin git" si no hay nada útil. Función pura.
pub fn parseHeadContent(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const t = std.mem.trim(u8, content, " \r\n\t");
    const prefix = "ref: refs/heads/";
    if (std.mem.startsWith(u8, t, prefix)) {
        const branch = std.mem.trim(u8, t[prefix.len..], " \r\n\t");
        if (branch.len > 0) return allocator.dupe(u8, branch);
    }
    var hex: usize = 0;
    while (hex < t.len and hex < 7 and std.ascii.isHex(t[hex])) hex += 1;
    if (hex == 7) return allocator.dupe(u8, t[0..7]);
    return allocator.dupe(u8, "sin git");
}

/// Rama del repositorio en `root` leyendo `.git/HEAD` (soporta la forma de
/// worktree, donde `.git` es un fichero «gitdir: …»). Nunca falla: devuelve
/// "sin git" si no se puede determinar.
pub fn readGitBranch(allocator: std.mem.Allocator, root: []const u8) ![]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    const git_path = try std.fs.path.join(allocator, &.{ root, ".git" });
    defer allocator.free(git_path);
    const st = std.Io.Dir.cwd().statFile(io, git_path, .{}) catch return allocator.dupe(u8, "sin git");

    var head_path: []u8 = undefined;
    if (st.kind == .directory) {
        head_path = try std.fs.path.join(allocator, &.{ git_path, "HEAD" });
    } else {
        const dir_content = std.Io.Dir.cwd().readFileAlloc(io, git_path, allocator, .limited(8192)) catch return allocator.dupe(u8, "sin git");
        defer allocator.free(dir_content);
        const trimmed = std.mem.trim(u8, dir_content, " \r\n\t");
        const prefix = "gitdir:";
        if (!std.mem.startsWith(u8, trimmed, prefix)) return allocator.dupe(u8, "sin git");
        const rel = std.mem.trim(u8, trimmed[prefix.len..], " \r\n\t");
        if (rel.len == 0) return allocator.dupe(u8, "sin git");
        const resolved = std.fs.path.resolve(allocator, &.{ root, rel }) catch return allocator.dupe(u8, "sin git");
        defer allocator.free(resolved);
        head_path = try std.fs.path.join(allocator, &.{ resolved, "HEAD" });
    }
    defer allocator.free(head_path);
    const content = std.Io.Dir.cwd().readFileAlloc(io, head_path, allocator, .limited(8192)) catch return allocator.dupe(u8, "sin git");
    defer allocator.free(content);
    return parseHeadContent(allocator, content);
}

fn openCatalog(allocator: std.mem.Allocator) !db.Connection {
    const cat_path = try paths.catalogDb(allocator);
    defer allocator.free(cat_path);
    return db.Connection.open(allocator, cat_path);
}

/// Código canónico de gobernanza con el MISMO Router que usa la CLI.
pub fn governanceCode(allocator: std.mem.Allocator) ![]u8 {
    var cat = openCatalog(allocator) catch return allocator.dupe(u8, "hybrid");
    defer cat.close();
    var router = model_router.Router.init(allocator, cat, null, 1);
    defer router.deinitHealthCache();
    return allocator.dupe(u8, router.getGovernanceMode().toText());
}

/// Cambia la gobernanza por el MISMO camino que `devagents governance`.
pub fn setGovernanceWith(allocator: std.mem.Allocator, code: []const u8) !void {
    var cat = try openCatalog(allocator);
    defer cat.close();
    var router = model_router.Router.init(allocator, cat, null, 1);
    defer router.deinitHealthCache();
    try router.setGovernanceMode(model_router.GovernanceMode.parse(code));
}

/// Catálogo como `devagents models list` (texto de ModelCatalog.listModels).
pub fn modelsList(allocator: std.mem.Allocator) ![]u8 {
    const cat_path = try paths.catalogDb(allocator);
    defer allocator.free(cat_path);
    var catalog = try model_catalog.ModelCatalog.init(allocator, cat_path);
    defer catalog.deinit();
    const text = try catalog.listModels(allocator);
    defer allocator.free(text);
    return allocator.dupe(u8, text);
}

// ── Puertos concretos para session.Ports (mismo `ctx` del Host) ─────────

pub fn portConfig(ctx: ?*anyopaque, allocator: std.mem.Allocator) anyerror!state.Config {
    const h: *Host = @ptrCast(@alignCast(ctx.?));
    return h.config(allocator);
}

pub fn portGetGovernance(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    return governanceCode(allocator);
}

pub fn portSetGovernance(_: ?*anyopaque, allocator: std.mem.Allocator, code: []const u8) anyerror!void {
    return setGovernanceWith(allocator, code);
}

pub fn portListModels(_: ?*anyopaque, allocator: std.mem.Allocator) anyerror![]u8 {
    return modelsList(allocator);
}

pub fn portRunOrder(_: ?*anyopaque, allocator: std.mem.Allocator, text: []const u8, sink: OrderSink) anyerror!u32 {
    return runOrder(allocator, text, sink);
}

/// Puerto de lectura para las instantáneas y el diff del espacio (E3): lee
/// relativo al directorio de la sesión y devuelve null si no se puede (no
/// existía, era binario gigante…). Sin este puerto los bloques listan rutas.
pub fn portReadFile(_: ?*anyopaque, allocator: std.mem.Allocator, path: []const u8) anyerror!?[]u8 {
    const io = std.Io.Threaded.global_single_threaded.io();
    return std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(256 * 1024)) catch null;
}

fn selfExePath(allocator: std.mem.Allocator) ![]u8 {
    var buf: [4096]u16 = undefined;
    const n = GetModuleFileNameW(null, &buf, buf.len);
    if (n == 0 or n >= buf.len) return error.SelfExeUnavailable;
    return std.unicode.utf16LeToUtf8Alloc(allocator, buf[0..n]);
}

/// Línea de comandos del hijo: `<propio exe> order "<texto>"` con el quoting
/// de argv de Windows ya probado del proyecto. Función pura.
pub fn orderCommandLine(allocator: std.mem.Allocator, exe: []const u8, order_text: []const u8) ![]u8 {
    var cmd: std.ArrayList(u8) = .empty;
    errdefer cmd.deinit(allocator);
    try windows_argv.appendArg(&cmd, allocator, exe);
    try cmd.appendSlice(allocator, " order ");
    try windows_argv.appendArg(&cmd, allocator, order_text);
    return cmd.toOwnedSlice(allocator);
}

/// Decodificador acotado: reconoce controles solo como líneas completas.
/// Se conserva por tubo para que un control partido entre lecturas no se pierda.
pub const OutputDecoder = struct {
    pending: [64]u8 = undefined,
    len: usize = 0,
    passthrough: bool = false,

    pub fn feed(self: *OutputDecoder, bytes: []const u8, sink: OrderSink, writer: anytype) !void {
        for (bytes) |b| {
            if (b == '\n') {
                if (!self.passthrough) {
                    const line = std.mem.trimEnd(u8, self.pending[0..self.len], "\r");
                    if (interaction.requestOf(line)) |req| {
                        try writer.write(sink.request(sink.ctx, req));
                        try writer.write("\n");
                    } else if (interaction.isProgressLine(line)) {
                        // E3: aviso de avance (task/file): ni texto ni respuesta.
                        sink.progress(sink.ctx, line);
                    } else {
                        sink.emit(sink.ctx, self.pending[0..self.len]);
                        sink.emit(sink.ctx, "\n");
                    }
                } else sink.emit(sink.ctx, "\n");
                self.len = 0;
                self.passthrough = false;
            } else if (self.passthrough) {
                sink.emit(sink.ctx, &.{b});
            } else if (self.len == self.pending.len) {
                sink.emit(sink.ctx, self.pending[0..self.len]);
                sink.emit(sink.ctx, &.{b});
                self.len = 0;
                self.passthrough = true;
            } else {
                self.pending[self.len] = b;
                self.len += 1;
            }
        }
    }

    pub fn finish(self: *OutputDecoder, sink: OrderSink) void {
        if (self.len > 0) sink.emit(sink.ctx, self.pending[0..self.len]);
        self.len = 0;
    }
};

const PipeWriter = struct {
    handle: windows.HANDLE,
    fn write(self: @This(), text: []const u8) !void {
        var offset: usize = 0;
        while (offset < text.len) {
            var n: u32 = 0;
            if (WriteFile(self.handle, text[offset..].ptr, @intCast(text.len - offset), &n, null) == 0 or n == 0)
                return error.SessionWriteFailed;
            offset += n;
        }
    }
};

fn drain(h: windows.HANDLE, sink: OrderSink, decoder: *OutputDecoder, writer: PipeWriter) !void {
    if (builtin.os.tag != .windows) return;
    var chunk: [8192]u8 = undefined;
    while (true) {
        var avail: u32 = 0;
        if (PeekNamedPipe(h, null, 0, null, &avail, null) == 0 or avail == 0) return;
        var read: u32 = 0;
        const want: u32 = @intCast(@min(avail, chunk.len));
        if (ReadFile(h, &chunk, want, &read, null) == 0 or read == 0) return;
        try decoder.feed(chunk[0..read], sink, writer);
    }
}

/// Ejecuta `devagents order "<texto>"` como hijo con stdout/stderr capturados.
/// La cancelación llega por `sink.pump` (Ctrl+C): se mata el hijo y se devuelve
/// 130. Devuelve el código de salida real del hijo.
pub fn runOrder(allocator: std.mem.Allocator, text: []const u8, sink: OrderSink) !u32 {
    if (builtin.os.tag != .windows) return error.UnsupportedPlatform;
    const exe = try selfExePath(allocator);
    defer allocator.free(exe);
    const base_cmd = try orderCommandLine(allocator, exe, text);
    defer allocator.free(base_cmd);
    const cmd_line = try std.fmt.allocPrint(allocator, "{s} --tui-session", .{base_cmd});
    defer allocator.free(cmd_line);
    const cmd_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, cmd_line);
    defer allocator.free(cmd_w);
    if (cmd_w.len >= 32767) return error.CommandLineTooLong;

    var sa = SECURITY_ATTRIBUTES{ .nLength = @sizeOf(SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = 1 };
    var out_r: windows.HANDLE = undefined;
    var out_w: windows.HANDLE = undefined;
    var err_r: windows.HANDLE = undefined;
    var err_w: windows.HANDLE = undefined;
    var in_r: windows.HANDLE = undefined;
    var in_w: windows.HANDLE = undefined;
    if (CreatePipe(&out_r, &out_w, @ptrCast(&sa), 0) == 0) return error.PipeFailed;
    if (CreatePipe(&err_r, &err_w, @ptrCast(&sa), 0) == 0) {
        _ = CloseHandle(out_r);
        _ = CloseHandle(out_w);
        return error.PipeFailed;
    }
    // stdin privado: solo la sesión escribe aprobaciones y aclaraciones.
    if (CreatePipe(&in_r, &in_w, @ptrCast(&sa), 0) == 0) {
        _ = CloseHandle(out_r);
        _ = CloseHandle(out_w);
        _ = CloseHandle(err_r);
        _ = CloseHandle(err_w);
        return error.PipeFailed;
    }
    _ = SetHandleInformation(out_r, HANDLE_FLAG_INHERIT, 0);
    _ = SetHandleInformation(err_r, HANDLE_FLAG_INHERIT, 0);
    _ = SetHandleInformation(in_w, HANDLE_FLAG_INHERIT, 0);

    var si: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = in_r;
    si.hStdOutput = out_w;
    si.hStdError = err_w;

    var pi: PROCESS_INFORMATION = undefined;
    const ok = CreateProcessW(null, cmd_w.ptr, null, null, 1, CREATE_NO_WINDOW, null, null, &si, &pi);
    _ = CloseHandle(out_w);
    _ = CloseHandle(err_w);
    _ = CloseHandle(in_r);
    if (ok == 0) {
        _ = CloseHandle(in_w);
        _ = CloseHandle(out_r);
        _ = CloseHandle(err_r);
        return error.SpawnFailed;
    }
    defer {
        _ = CloseHandle(pi.hThread);
        _ = CloseHandle(pi.hProcess);
        _ = CloseHandle(out_r);
        _ = CloseHandle(err_r);
        _ = CloseHandle(in_w);
    }
    errdefer _ = TerminateProcess(pi.hProcess, 130);

    var cancelled = false;
    var out_decoder = OutputDecoder{};
    var err_decoder = OutputDecoder{};
    const writer = PipeWriter{ .handle = in_w };
    while (true) {
        if (sink.pump(sink.ctx)) {
            cancelled = true;
            _ = TerminateProcess(pi.hProcess, 130);
        }
        try drain(out_r, sink, &out_decoder, writer);
        try drain(err_r, sink, &err_decoder, writer);
        var code: u32 = 0;
        if (GetExitCodeProcess(pi.hProcess, &code) == 0 or code != 259) break; // 259 = STILL_ACTIVE
        Sleep(15);
    }
    try drain(out_r, sink, &out_decoder, writer);
    try drain(err_r, sink, &err_decoder, writer);
    out_decoder.finish(sink);
    err_decoder.finish(sink);
    if (WaitForSingleObject(pi.hProcess, 5000) != WAIT_OBJECT_0) {
        _ = TerminateProcess(pi.hProcess, 130);
        cancelled = true;
    }
    var code: u32 = 1;
    _ = GetExitCodeProcess(pi.hProcess, &code);
    if (cancelled) return 130;
    return code;
}

const testing = std.testing;

test "CK-MOT-027: el nombre del proyecto sale del último tramo de la ruta" {
    const a = testing.allocator;
    const n1 = try lastPathComponent(a, "C:\\proyectos\\calculadora");
    defer a.free(n1);
    try testing.expectEqualStrings("calculadora", n1);

    const n2 = try lastPathComponent(a, "C:\\proyectos\\calculadora\\");
    defer a.free(n2);
    try testing.expectEqualStrings("calculadora", n2);

    const n3 = try lastPathComponent(a, "C:\\");
    defer a.free(n3);
    try testing.expectEqualStrings("C:\\", n3);
}

test "CK-MOT-027: la rama se lee del HEAD (normal, worktree y separado)" {
    const a = testing.allocator;

    const normal = try parseHeadContent(a, "ref: refs/heads/main\n");
    defer a.free(normal);
    try testing.expectEqualStrings("main", normal);

    const worktree = try parseHeadContent(a, "ref: refs/heads/ds-mot027\r\n");
    defer a.free(worktree);
    try testing.expectEqualStrings("ds-mot027", worktree);

    const detached = try parseHeadContent(a, "33c41d1d2f5b7c9a\n");
    defer a.free(detached);
    try testing.expectEqualStrings("33c41d1", detached);

    const none = try parseHeadContent(a, "contenido raro");
    defer a.free(none);
    try testing.expectEqualStrings("sin git", none);
}

test "CK-MOT-027: la línea de la orden cita el ejecutable propio y el texto" {
    const a = testing.allocator;
    const line = try orderCommandLine(a, "C:\\ruta con espacios\\devagents-core.exe", "Crea una calculadora");
    defer a.free(line);
    try testing.expectEqualStrings(
        "\"C:\\ruta con espacios\\devagents-core.exe\" order \"Crea una calculadora\"",
        line,
    );

    const simple = try orderCommandLine(a, "devagents-core.exe", "hola");
    defer a.free(simple);
    try testing.expectEqualStrings("devagents-core.exe order hola", simple);
}

const ProtocolFake = struct {
    output: std.ArrayList(u8) = .empty,
    replies: std.ArrayList(u8) = .empty,
    progress: std.ArrayList([]const u8) = .empty,
    requests: usize = 0,
    fail_write: bool = false,

    fn sink(self: *@This()) OrderSink {
        return .{ .ctx = self, .emit = emit, .pump = pump, .request = request, .progress = progressFn };
    }
    fn emit(ctx: ?*anyopaque, bytes: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.output.appendSlice(testing.allocator, bytes) catch @panic("OOM");
    }
    fn pump(_: ?*anyopaque) bool {
        return false;
    }
    fn request(ctx: ?*anyopaque, req: interaction.Request) []const u8 {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        self.requests += 1;
        return switch (req) {
            .approve => "1",
            .answer => "answer Zig",
            .perm => interaction.CANCEL,
        };
    }
    fn progressFn(ctx: ?*anyopaque, line: []const u8) void {
        const self: *@This() = @ptrCast(@alignCast(ctx.?));
        const copy = testing.allocator.dupe(u8, line) catch @panic("OOM");
        self.progress.append(testing.allocator, copy) catch @panic("OOM");
    }
    fn write(self: *@This(), bytes: []const u8) !void {
        if (self.fail_write) return error.FakeWriteFailed;
        try self.replies.appendSlice(testing.allocator, bytes);
    }
    fn deinit(self: *@This()) void {
        self.output.deinit(testing.allocator);
        self.replies.deinit(testing.allocator);
        for (self.progress.items) |p| testing.allocator.free(p);
        self.progress.deinit(testing.allocator);
    }
};

test "CK-MOT-027 E2: tubos fragmentados conservan UTF-8 y preguntas sin mostrar controles" {
    var fake = ProtocolFake{};
    defer fake.deinit();
    var decoder = OutputDecoder{};
    const text = "Entendimiento: programación\r\n" ++ interaction.ANSWER ++ "\r\n1. Archivo: index.html\n" ++ interaction.APPROVE ++ "\ncola";
    for (text) |b| try decoder.feed(&.{b}, fake.sink(), &fake);
    decoder.finish(fake.sink());
    try testing.expectEqualStrings("Entendimiento: programación\r\n1. Archivo: index.html\ncola", fake.output.items);
    try testing.expectEqualStrings("answer Zig\n1\n", fake.replies.items);
    try testing.expectEqual(@as(usize, 2), fake.requests);
}

test "CK-MOT-027 E2: lineas largas y controles incompletos no se pierden ni autorizan" {
    var fake = ProtocolFake{};
    defer fake.deinit();
    var decoder = OutputDecoder{};
    const text = "x" ** 200 ++ interaction.APPROVE ++ "\n" ++ interaction.APPROVE;
    try decoder.feed(text, fake.sink(), &fake);
    decoder.finish(fake.sink());
    try testing.expectEqualStrings(text, fake.output.items);
    try testing.expectEqual(@as(usize, 0), fake.requests);
    try testing.expectEqualStrings("", fake.replies.items);
    try testing.expectEqualStrings(interaction.CANCEL, denyRequest(null, .approve));
}

test "CK-MOT-027 E2: error escribiendo respuesta se propaga" {
    var fake = ProtocolFake{ .fail_write = true };
    defer fake.deinit();
    var decoder = OutputDecoder{};
    try testing.expectError(error.FakeWriteFailed, decoder.feed(interaction.APPROVE ++ "\n", fake.sink(), &fake));
}

test "CK-MOT-027 E3: los avisos de avance y la peticion de permiso van por su canal" {
    var fake = ProtocolFake{};
    defer fake.deinit();
    var decoder = OutputDecoder{};
    const text = "linea normal\n" ++
        interaction.TASK ++ " t1 ok 1000 4400 opencode/deepseek-free Escribe la web\n" ++
        interaction.FILE ++ " t1 calculadora/index.html\n" ++
        interaction.PERM ++ "Ejecutar npm test\n" ++
        interaction.TASK ++ " t2 failed 0 0 -";
    for (text) |b| try decoder.feed(&.{b}, fake.sink(), &fake);
    decoder.finish(fake.sink());
    // El texto normal sí llega; los controles NUNCA a la transcripción salvo
    // el resto incompleto de `finish()` (sin \n no es control completo).
    try testing.expectEqualStrings("linea normal\n" ++ interaction.TASK ++ " t2 failed 0 0 -", fake.output.items);
    try testing.expectEqual(@as(usize, 2), fake.progress.items.len);
    try testing.expectEqualStrings(interaction.TASK ++ " t1 ok 1000 4400 opencode/deepseek-free Escribe la web", fake.progress.items[0]);
    try testing.expectEqualStrings(interaction.FILE ++ " t1 calculadora/index.html", fake.progress.items[1]);
    // La petición de permiso se responde por el mismo canal (respuesta del doble).
    try testing.expectEqualStrings(interaction.CANCEL ++ "\n", fake.replies.items);
    try testing.expectEqual(@as(usize, 1), fake.requests);
}
