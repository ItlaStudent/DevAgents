const std = @import("std");

const windows = std.os.windows;

extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.c) c_int;
extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: u32) callconv(.c) u32;
extern "kernel32" fn GetExitCodeProcess(hProcess: windows.HANDLE, lpExitCode: *u32) callconv(.c) c_int;

extern "kernel32" fn CreatePipe(
    hReadPipe: *windows.HANDLE,
    hWritePipe: *windows.HANDLE,
    lpPipeAttributes: ?*anyopaque,
    nSize: u32,
) callconv(.c) c_int;
extern "kernel32" fn ReadFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: u32,
    lpNumberOfBytesRead: ?*u32,
    lpOverlapped: ?*anyopaque,
) callconv(.c) c_int;
extern "kernel32" fn SetHandleInformation(hObject: windows.HANDLE, dwMask: u32, dwFlags: u32) callconv(.c) c_int;
extern "kernel32" fn GetSystemTimeAsFileTime(lpSystemTimeAsFileTime: *u64) callconv(.c) void;

/// Unix epoch en ms. Zig 0.16 (fork) no expone std.time.timestamp —
/// FILETIME son intervalos de 100ns desde 1601; restamos el offset a 1970.
/// pub: los tests de ship_flow miden con ella el "falla en segundos" de.
pub fn nowMs() i64 {
    if (@import("builtin").os.tag != .windows) {
        var ft: u64 = 0;
        @import("platform.zig").filetime(&ft);
        return @intCast((ft -| 116444736000000000) / 10_000);
    }
    var ft: u64 = 0;
    GetSystemTimeAsFileTime(&ft);
    const unix_100ns = ft -| 116444736000000000;
    return @intCast(unix_100ns / 10000);
}

const SECURITY_ATTRIBUTES = extern struct {
    nLength: u32,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: c_int,
};
const STARTF_USESTDHANDLES: u32 = 0x00000100;
const HANDLE_FLAG_INHERIT: u32 = 0x00000001;
/// Sin CREATE_NO_WINDOW cada llamada a git/gh abre una consola visible en el
/// escritorio del usuario — con el GitHubPoller sondeo en segundo plano eso es
/// una lluvia de ventanas cmd que impide usar la máquina (reportado en S22).
const CREATE_NO_WINDOW: u32 = 0x08000000;

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
    lpReserved2: ?*anyopaque = null,
    hStdInput: windows.HANDLE = windows.INVALID_HANDLE_VALUE,
    hStdOutput: windows.HANDLE = windows.INVALID_HANDLE_VALUE,
    hStdError: windows.HANDLE = windows.INVALID_HANDLE_VALUE,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: windows.HANDLE,
    hThread: windows.HANDLE,
    dwProcessId: u32,
    dwThreadId: u32,
};

extern "kernel32" fn CreateProcessA(
    lpApplicationName: ?[*:0]const u8,
    lpCommandLine: [*:0]u8,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: c_int,
    dwCreationDisposition: u32,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u8,
    lpStartupInfo: *STARTUPINFOA,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.c) c_int;

extern "kernel32" fn CreateProcessW(
    ?[*:0]const u16,
    [*:0]u16,
    ?*anyopaque,
    ?*anyopaque,
    c_int,
    u32,
    ?*anyopaque,
    ?[*:0]const u16,
    *windows.STARTUPINFOW,
    *PROCESS_INFORMATION,
) callconv(.c) c_int;

pub const PullRequestState = enum {
    none,
    ahead,
    open,
    ci_running,
    mergeable,
    merged,
    failed,

    pub fn toString(self: PullRequestState) []const u8 {
        return switch (self) {
            .none => "none",
            .ahead => "ahead",
            .open => "open",
            .ci_running => "ci_running",
            .mergeable => "mergeable",
            .merged => "merged",
            .failed => "failed",
        };
    }

    pub fn parse(str: []const u8) !PullRequestState {
        if (std.mem.eql(u8, str, "none")) return .none;
        if (std.mem.eql(u8, str, "ahead")) return .ahead;
        if (std.mem.eql(u8, str, "open")) return .open;
        if (std.mem.eql(u8, str, "ci_running")) return .ci_running;
        if (std.mem.eql(u8, str, "mergeable")) return .mergeable;
        if (std.mem.eql(u8, str, "merged")) return .merged;
        if (std.mem.eql(u8, str, "failed")) return .failed;
        return error.InvalidState;
    }
};

pub const PullRequestInfo = struct {
    id: i64 = 0,
    order_id: i64,
    provider: []const u8,
    repo: []const u8,
    number: i64,
    state: PullRequestState,
    url: []const u8,
    last_polled_at: i64,

    pub fn deinit(self: *PullRequestInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.provider);
        allocator.free(self.repo);
        allocator.free(self.url);
    }
};

fn runCmdWin32(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) u32 {
    if (@import("builtin").os.tag != .windows) {
        var result = runCmdCaptureWin32Input(allocator, argv, cwd, null, if (isGitArgv(argv)) GIT_GUARD_ENV else null) catch return 1;
        defer result.deinit(allocator);
        return result.exit_code;
    }
    var cmd_line = std.ArrayList(u8).empty;
    defer cmd_line.deinit(allocator);
    const fs_off = argv.len > 0 and std.mem.eql(u8, argv[0], "git");

    for (argv, 0..) |arg, i| {
        if (i > 0) cmd_line.append(allocator, ' ') catch return 1;
        cmd_line.appendSlice(allocator, arg) catch return 1;
        if (i == 0 and fs_off)
            cmd_line.appendSlice(allocator, " -c core.fsmonitor=false") catch return 1;
    }

    const cmd_line_z = allocator.dupeZ(u8, cmd_line.items) catch return 1;
    defer allocator.free(cmd_line_z);

    const cwd_z = if (cwd) |c| allocator.dupeZ(u8, c) catch null else null;
    defer if (cwd_z) |c| allocator.free(c);

    var si: STARTUPINFOA = .{ .cb = @sizeOf(STARTUPINFOA) };
    var pi: PROCESS_INFORMATION = undefined;

    const ok = CreateProcessA(
        null,
        cmd_line_z.ptr,
        null,
        null,
        0,
        CREATE_NO_WINDOW,
        null,
        if (cwd_z) |c| c.ptr else null,
        &si,
        &pi,
    );

    if (ok == 0) return 1;
    defer {
        _ = CloseHandle(pi.hThread);
        _ = CloseHandle(pi.hProcess);
    }

    _ = WaitForSingleObject(pi.hProcess, 0xFFFFFFFF);
    var exit_code: u32 = 0;
    _ = GetExitCodeProcess(pi.hProcess, &exit_code);

    return exit_code;
}

pub const CmdCapture = struct {
    exit_code: u32,
    stdout: []u8,
    stderr: []u8,

    pub fn deinit(self: *CmdCapture, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Como runCmdWin32 pero capturando stdout/stderr del hijo por tubos.
/// Necesario para leer la salida real de `gh` — sin esto el conector no puede
/// saber ni el número ni la URL del PR y acabaría inventándolos.
pub fn runCmdCaptureWin32(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !CmdCapture {
    return runCmdCaptureWin32Input(allocator, argv, cwd, null, null);
}

extern "kernel32" fn WriteFile(
    hFile: windows.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: u32,
    lpNumberOfBytesWritten: ?*u32,
    lpOverlapped: ?*anyopaque,
) callconv(.c) c_int;
extern "kernel32" fn GetEnvironmentStringsA() callconv(.c) ?[*:0]u8;
extern "kernel32" fn FreeEnvironmentStringsA(penv: [*:0]u8) callconv(.c) c_int;

/// "K=V" de extra_env sustituye a la entrada del padre con la misma clave
/// (Windows compara sin mayusculas). Si no, un GIT_TERMINAL_PROMPT=1 heredado
/// coexistiria con el =0 y la guardia dependeria del orden del bloque.
fn envKeyOverridden(entry: []const u8, kv: []const u8) bool {
    const eq_e = std.mem.indexOfScalar(u8, entry, '=') orelse return false;
    const eq_k = std.mem.indexOfScalar(u8, kv, '=') orelse return false;
    return std.ascii.eqlIgnoreCase(entry[0..eq_e], kv[0..eq_k]);
}

/// Bloque de entorno ANSI (doble NUL final) = entorno heredado + extra_env
/// ("K=V" por entrada, con prioridad sobre el padre). Devuelve null si no hay
/// extra_env (el hijo hereda).
fn buildEnvBlock(allocator: std.mem.Allocator, extra_env: ?[]const []const u8) !?[]u8 {
    const extra = extra_env orelse return null;
    if (extra.len == 0) return null;
    const parent = GetEnvironmentStringsA() orelse return error.Oom;
    defer _ = FreeEnvironmentStringsA(parent);
    // El bloque padre termina en "\0\0": copiar entrada a entrada, saltando
    // las que extra_env redefine (su valor es el que manda).
    var block = std.ArrayList(u8).empty;
    errdefer block.deinit(allocator);
    var pos: usize = 0;
    while (parent[pos] != 0) {
        var end = pos;
        while (parent[end] != 0) : (end += 1) {}
        const entry = parent[pos..end];
        var skip = false;
        for (extra) |kv| {
            if (envKeyOverridden(entry, kv)) {
                skip = true;
                break;
            }
        }
        if (!skip) {
            try block.appendSlice(allocator, entry);
            try block.append(allocator, 0);
        }
        pos = end + 1;
    }
    for (extra) |kv| {
        try block.appendSlice(allocator, kv);
        try block.append(allocator, 0);
    }
    try block.append(allocator, 0);
    return try block.toOwnedSlice(allocator);
}

/// Variante con stdin y entorno extra: `git credential fill` lee la consulta
/// por stdin y GIT_TERMINAL_PROMPT=0/GCM_INTERACTIVE=never impiden que el
/// helper abra un diálogo — sin credencial guardada falla rápido y honesto.
pub fn runCmdCaptureWin32Input(
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    input: ?[]const u8,
    extra_env: ?[]const []const u8,
) !CmdCapture {
    // T9: en POSIX argv va directo (sin linea de comandos que citar), en su
    // propio grupo de procesos y con plazo; git con fsmonitor apagado.
    if (@import("builtin").os.tag != .windows) {
        if (argv.len == 0) return error.SpawnFailed;
        const fs_off = std.mem.eql(u8, argv[0], "git");
        const full = try allocator.alloc([]const u8, argv.len + @as(usize, if (fs_off) 2 else 0));
        defer allocator.free(full);
        full[0] = argv[0];
        var i: usize = 1;
        if (fs_off) {
            full[1] = "-c";
            full[2] = "core.fsmonitor=false";
            i = 3;
        }
        @memcpy(full[i..], argv[1..]);
        const result = try @import("posix_process.zig").run(allocator, full, cwd, input, extra_env, 120_000, 16 * 1024 * 1024);
        if (result.timed_out) {
            allocator.free(result.stdout);
            allocator.free(result.stderr);
            return error.Timeout;
        }
        return .{ .stdout = result.stdout, .stderr = result.stderr, .exit_code = result.exit_code };
    }
    var cmd_line = std.ArrayList(u8).empty;
    defer cmd_line.deinit(allocator);
    // Igual que en runCmdWin32: git dentro de worktrees de orden no debe dejar
    // demonios fsmonitor huérfanos ni consolas visibles.
    const fs_off = argv.len > 0 and std.mem.eql(u8, argv[0], "git");

    for (argv, 0..) |arg, i| {
        if (i > 0) cmd_line.append(allocator, ' ') catch return error.Oom;
        // Argumentos con espacios van entre comillas (título/body del PR).
        if (std.mem.indexOfScalar(u8, arg, ' ') != null) {
            cmd_line.append(allocator, '"') catch return error.Oom;
            cmd_line.appendSlice(allocator, arg) catch return error.Oom;
            cmd_line.append(allocator, '"') catch return error.Oom;
        } else {
            cmd_line.appendSlice(allocator, arg) catch return error.Oom;
        }
        if (i == 0 and fs_off)
            cmd_line.appendSlice(allocator, " -c core.fsmonitor=false") catch return error.Oom;
    }
    // argv/cwd are UTF-8; CreateProcessA interprets them in the system ACP.
    // Convert at this boundary so Unicode paths address the actual object.
    const cmd_line_z = try std.unicode.utf8ToUtf16LeAllocZ(allocator, cmd_line.items);
    defer allocator.free(cmd_line_z);
    const cwd_z = if (cwd) |c| try std.unicode.utf8ToUtf16LeAllocZ(allocator, c) else null;
    defer if (cwd_z) |c| allocator.free(c);

    const env_block = try buildEnvBlock(allocator, extra_env);
    defer if (env_block) |b| allocator.free(b);

    var sa = SECURITY_ATTRIBUTES{ .nLength = @sizeOf(SECURITY_ATTRIBUTES), .lpSecurityDescriptor = null, .bInheritHandle = 1 };
    var out_r: windows.HANDLE = undefined;
    var out_w: windows.HANDLE = undefined;
    var err_r: windows.HANDLE = undefined;
    var err_w: windows.HANDLE = undefined;
    if (CreatePipe(&out_r, &out_w, @ptrCast(&sa), 0) == 0) return error.PipeFailed;
    if (CreatePipe(&err_r, &err_w, @ptrCast(&sa), 0) == 0) {
        _ = CloseHandle(out_r);
        _ = CloseHandle(out_w);
        return error.PipeFailed;
    }
    // El lado de lectura NO se hereda (si no, el tubo nunca da EOF).
    _ = SetHandleInformation(out_r, HANDLE_FLAG_INHERIT, 0);
    _ = SetHandleInformation(err_r, HANDLE_FLAG_INHERIT, 0);

    // stdin opcional: in_r lo lee el hijo (heredable), in_w lo escribe el
    // padre (NO heredable — si no, el hijo nunca ve EOF).
    var in_r: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    var in_w: windows.HANDLE = windows.INVALID_HANDLE_VALUE;
    if (input != null) {
        if (CreatePipe(&in_r, &in_w, @ptrCast(&sa), 0) == 0) {
            _ = CloseHandle(out_r);
            _ = CloseHandle(err_r);
            return error.PipeFailed;
        }
        _ = SetHandleInformation(in_w, HANDLE_FLAG_INHERIT, 0);
    }

    var si: windows.STARTUPINFOW = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = in_r;
    si.hStdOutput = out_w;
    si.hStdError = err_w;

    var pi: PROCESS_INFORMATION = undefined;
    // buildEnvBlock retains its ANSI contract (no CREATE_UNICODE_ENVIRONMENT).
    const ok = CreateProcessW(null, cmd_line_z.ptr, null, null, 1, CREATE_NO_WINDOW, if (env_block) |b| b.ptr else null, if (cwd_z) |c| c.ptr else null, &si, &pi);
    _ = CloseHandle(out_w);
    _ = CloseHandle(err_w);
    if (in_r != windows.INVALID_HANDLE_VALUE) _ = CloseHandle(in_r);
    if (ok == 0) {
        _ = CloseHandle(out_r);
        _ = CloseHandle(err_r);
        if (in_w != windows.INVALID_HANDLE_VALUE) _ = CloseHandle(in_w);
        return error.SpawnFailed;
    }
    defer {
        _ = CloseHandle(pi.hThread);
        _ = CloseHandle(pi.hProcess);
        _ = CloseHandle(out_r);
        _ = CloseHandle(err_r);
    }

    // La consulta entera cabe en el buffer del tubo (protocolo credential:
    // pocas líneas) — escribir antes de leer no puede deadlockear.
    if (input) |data| {
        var written: u32 = 0;
        _ = WriteFile(in_w, data.ptr, @intCast(data.len), &written, null);
        _ = CloseHandle(in_w);
    }

    var stdout_buf = std.ArrayList(u8).empty;
    defer stdout_buf.deinit(allocator);
    var stderr_buf = std.ArrayList(u8).empty;
    defer stderr_buf.deinit(allocator);

    // Lectura secuencial: suficiente para `gh` (salida acotada, el buffer del
    // tubo la contiene hasta que el proceso sale y cierra sus extremos).
    var chunk: [8192]u8 = undefined;
    while (true) {
        var n: u32 = 0;
        if (ReadFile(out_r, &chunk, chunk.len, &n, null) != 0 and n > 0) {
            stdout_buf.appendSlice(allocator, chunk[0..n]) catch return error.Oom;
        } else break;
    }
    while (true) {
        var n: u32 = 0;
        if (ReadFile(err_r, &chunk, chunk.len, &n, null) != 0 and n > 0) {
            stderr_buf.appendSlice(allocator, chunk[0..n]) catch return error.Oom;
        } else break;
    }
    _ = WaitForSingleObject(pi.hProcess, 0xFFFFFFFF);
    var exit_code: u32 = 1;
    _ = GetExitCodeProcess(pi.hProcess, &exit_code);

    return .{
        .exit_code = exit_code,
        .stdout = stdout_buf.toOwnedSlice(allocator) catch return error.Oom,
        .stderr = stderr_buf.toOwnedSlice(allocator) catch return error.Oom,
    };
}

/// B3: firma del runner de comandos con salida capturada. Produccion lo deja
/// null (runCmdCaptureWin32 real); los tests lo fijan para guionar `gh`/`git`
/// sin red ni repo remoto — la orquestacion se prueba entera y el limite gh
/// sigue siendo honesto.
pub const CaptureFn = *const fn (allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) anyerror!CmdCapture;

/// seam completo — el fake ve stdin y env ademas de argv, asi un test
/// puede EXIGIR la guardia anti-prompt en push/fetch/clone. Si esta fijada,
/// tiene prioridad sobre capture_fn para todas las capturas.
pub const CaptureFullFn = *const fn (
    allocator: std.mem.Allocator,
    argv: []const []const u8,
    cwd: ?[]const u8,
    input: ?[]const u8,
    extra_env: ?[]const []const u8,
) anyerror!CmdCapture;

/// variables que hacen toda llamada `git` no interactiva. Sin
/// credencial guardada, git y GCM fallan rapido y honesto en vez de colgar un
/// dialogo invisible que deja el push esperando para siempre; con credencial,
/// el helper la devuelve sin tocar el escritorio del usuario.
pub const GIT_GUARD_ENV = &[_][]const u8{ "GIT_TERMINAL_PROMPT=0", "GCM_INTERACTIVE=never" };

pub const Forge = enum { github, gitlab, gitea };
pub const HostForgeConfig = struct { host: []const u8, forge: Forge };
/// Returns an owned Authorization header; the caller releases it. No logging.
pub const ForgeAuthFn = *const fn (std.mem.Allocator, Forge, []const u8, ?*anyopaque) anyerror!?[]u8;

fn isGitArgv(argv: []const []const u8) bool {
    return argv.len > 0 and (std.mem.eql(u8, argv[0], "git") or std.mem.eql(u8, argv[0], "git.exe"));
}

/// `git clone` interpreta `--upload-pack=...`, `ext::cmd` y rutas locales como
/// ejecucion. Solo se admite https:// o la forma scp `usuario@host:ruta`, sin
/// espacios, controles ni guion inicial.
pub fn isCloneUrlAllowed(url: []const u8) bool {
    if (url.len == 0 or url.len > 2048 or url[0] == '-') return false;
    for (url) |c| if (c <= 0x20 or c == 0x7f) return false;
    if (std.ascii.startsWithIgnoreCase(url, "https://")) return url.len > "https://".len and url["https://".len] != '-';
    if (std.mem.indexOf(u8, url, "::") != null or std.mem.indexOf(u8, url, "://") != null) return false;
    const at = std.mem.indexOfScalar(u8, url, '@') orelse return false;
    const colon = std.mem.indexOfScalarPos(u8, url, at, ':') orelse return false;
    return at > 0 and colon > at + 1 and colon + 1 < url.len and url[at + 1] != '-';
}

pub const GitHubConnector = struct {
    allocator: std.mem.Allocator,
    token: ?[]const u8 = null,
    /// Último diagnóstico de gh (stderr o causa). Solo lectura de error.
    last_error: std.ArrayList(u8) = .empty,
    capture_fn: ?CaptureFn = null,
    capture_full_fn: ?CaptureFullFn = null,
    /// REST is the default; false explicitly selects the optional gh path.
    rest_enabled: bool = true,
    forge_hosts: []const HostForgeConfig = &.{},
    forge_auth_fn: ?ForgeAuthFn = null,
    forge_auth_ctx: ?*anyopaque = null,

    pub fn init(allocator: std.mem.Allocator, token: ?[]const u8) GitHubConnector {
        return .{
            .allocator = allocator,
            .token = if (token) |t| allocator.dupe(u8, t) catch null else null,
        };
    }

    pub fn deinit(self: *GitHubConnector) void {
        if (self.token) |t| self.allocator.free(t);
        self.last_error.deinit(self.allocator);
    }

    /// Punto unico por el que salen TODOS los subprocesos del ship flow
    /// (tambien `git`: la misma inyeccion sirve para guionar las dos piezas).
    /// todo `git` sale con GIT_GUARD_ENV — push/fetch/remote show/clone
    /// tocan la red y pueden pedir credencial; en los comandos locales las
    /// variables son inocuas, asi que la guardia va en el camino comun.
    pub fn capture(self: *GitHubConnector, argv: []const []const u8, cwd: ?[]const u8) !CmdCapture {
        const env: ?[]const []const u8 = if (isGitArgv(argv)) GIT_GUARD_ENV else null;
        if (self.capture_full_fn) |f| return f(self.allocator, argv, cwd, null, env);
        if (self.capture_fn) |f| return f(self.allocator, argv, cwd);
        return runCmdCaptureWin32Input(self.allocator, argv, cwd, null, env);
    }

    /// capture con stdin y variables de entorno extra — `git credential fill`
    /// (T4-GITEA): el test lo guiona por capture_fn igual que el resto (el
    /// stdin no afecta al guion); producción usa el runner real con la tubería
    /// de entrada y el env construido.
    pub fn captureInput(self: *GitHubConnector, argv: []const []const u8, cwd: ?[]const u8, input: []const u8, extra_env: []const []const u8) !CmdCapture {
        if (self.capture_full_fn) |f| return f(self.allocator, argv, cwd, input, extra_env);
        if (self.capture_fn) |f| return f(self.allocator, argv, cwd);
        return runCmdCaptureWin32Input(self.allocator, argv, cwd, input, extra_env);
    }

    /// Exec de la CLI `gh` para operaciones rápidas si está instalado.
    pub fn execGh(self: *GitHubConnector, args: []const []const u8) !u32 {
        var argv = std.ArrayList([]const u8).empty;
        defer argv.deinit(self.allocator);

        try argv.append(self.allocator, "gh");
        for (args) |arg| try argv.append(self.allocator, arg);

        return runCmdWin32(self.allocator, argv.items, null);
    }

    /// Clona un repositorio sin checkout local previo (el auditor v0.12).
    /// va por `capture` como el resto del git del modulo — lleva la guardia
    /// anti-prompt, la seam lo ve y el stderr real queda en last_error.
    pub fn cloneRepo(self: *GitHubConnector, repo_url: []const u8, target_dir: []const u8) !void {
        if (!isCloneUrlAllowed(repo_url) or target_dir.len == 0 or target_dir[0] == '-') return error.CloneUrlNotAllowed;
        var cap = try self.capture(&[_][]const u8{ "git", "clone", "--", repo_url, target_dir }, null);
        defer cap.deinit(self.allocator);
        if (cap.exit_code != 0) {
            self.setLastError(cap.stderr, "git clone failed");
            return error.GitCloneFailed;
        }
    }

    pub fn setLastError(self: *GitHubConnector, stderr: []const u8, fallback: []const u8) void {
        self.last_error.clearRetainingCapacity();
        var msg = std.mem.trim(u8, if (std.mem.trim(u8, stderr, " \t\r\n").len > 0) stderr else fallback, " \t\r\n");
        // Git/gh diagnostic prefixes are not response headers. Remove only
        // these fixed labels; their entire value still passes the censor.
        for ([_][]const u8{ "fatal: ", "error: ", "GraphQL: " }) |prefix| {
            if (std.mem.startsWith(u8, msg, prefix)) {
                msg = msg[prefix.len..];
                break;
            }
        }
        var buffer: [200]u8 = undefined;
        self.last_error.appendSlice(self.allocator, @import("external_error.zig").excerpt(&buffer, msg, self.token)) catch |e| {
            std.log.err("forge diagnostic unavailable: {s}", .{@errorName(e)});
        };
    }

    /// Extrae la URL de PR que `gh pr create` imprime en stdout (última línea
    /// `https://github.com/…/pull/N`). Null si no aparece — el caller falla
    /// honesto en vez de inventar la URL.
    fn parsePrUrlFromCreate(stdout: []const u8) ?[]const u8 {
        var it = std.mem.splitScalar(u8, stdout, '\n');
        var last_url: ?[]const u8 = null;
        while (it.next()) |line| {
            const t = std.mem.trim(u8, line, " \t\r");
            if (std.mem.indexOf(u8, t, "/pull/") != null and std.mem.startsWith(u8, t, "http")) {
                last_url = t;
            }
        }
        return last_url;
    }

    /// `gh pr view <ref> --json number,state,url,statusCheckRollup` parseado.
    /// `ref` puede ser la URL del PR (autocontenida) o un número con `--repo`.
    /// Cualquier fallo (gh ausente, sin auth, PR inexistente) es error, nunca
    /// un estado inventado.
    fn ghViewPr(self: *GitHubConnector, repo: []const u8, ref_str: []const u8) !struct { number: i64, url: []u8, state: PullRequestState } {
        const is_url = std.mem.startsWith(u8, ref_str, "http");
        const argv = if (is_url)
            &[_][]const u8{ "gh", "pr", "view", ref_str, "--json", "number,state,url,statusCheckRollup" }
        else
            &[_][]const u8{ "gh", "pr", "view", ref_str, "--repo", repo, "--json", "number,state,url,statusCheckRollup" };
        var cap = self.capture(argv, null) catch |e| {
            self.setLastError("", @errorName(e));
            return error.GhUnavailable;
        };
        defer cap.deinit(self.allocator);
        if (cap.exit_code != 0) {
            self.setLastError(cap.stderr, "gh pr view failed");
            return error.GhFailed;
        }

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, cap.stdout, .{}) catch {
            self.setLastError(cap.stdout, "gh pr view: JSON ilegible");
            return error.GhParseFailed;
        };
        defer parsed.deinit();
        const o = parsed.value.object;

        const number = if (o.get("number")) |v| switch (v) {
            .integer => |n| n,
            else => return error.GhParseFailed,
        } else return error.GhParseFailed;
        const url = if (o.get("url")) |v| switch (v) {
            .string => |s| try self.allocator.dupe(u8, s),
            else => return error.GhParseFailed,
        } else return error.GhParseFailed;
        errdefer self.allocator.free(url);

        var state: PullRequestState = .open;
        if (o.get("state")) |v| {
            if (v == .string) {
                if (std.mem.eql(u8, v.string, "MERGED")) {
                    state = .merged;
                } else if (std.mem.eql(u8, v.string, "CLOSED")) {
                    state = .failed;
                } else state = .open;
            }
        }
        // Checks de CI: cualquier check fallido/pendiente se refleja honesto.
        if (state == .open) {
            if (o.get("statusCheckRollup")) |v| {
                if (v == .array) {
                    var any_pending = false;
                    var any_fail = false;
                    for (v.array.items) |item| {
                        if (item != .object) continue;
                        const st_v = item.object.get("conclusion") orelse item.object.get("status") orelse continue;
                        if (st_v != .string) continue;
                        if (std.mem.eql(u8, st_v.string, "FAILURE") or std.mem.eql(u8, st_v.string, "TIMED_OUT") or std.mem.eql(u8, st_v.string, "CANCELLED")) {
                            any_fail = true;
                        } else if (!std.mem.eql(u8, st_v.string, "SUCCESS") and !std.mem.eql(u8, st_v.string, "NEUTRAL") and !std.mem.eql(u8, st_v.string, "SKIPPED") and !std.mem.eql(u8, st_v.string, "COMPLETED")) {
                            any_pending = true;
                        }
                    }
                    if (any_fail) state = .failed else if (any_pending) state = .ci_running;
                }
            }
        }
        return .{ .number = number, .url = url, .state = state };
    }

    /// Crea un PR real con `gh pr create` y devuelve sus datos VERDADEROS
    /// (número, URL, estado) leídos con `gh pr view`. Si gh no está, no hay
    /// auth, no es un repo git o el PR no se crea, esto es un error — nunca
    /// un PullRequestInfo fabricado.
    pub fn createPullRequest(
        self: *GitHubConnector,
        repo: []const u8,
        title: []const u8,
        body: []const u8,
        head_branch: []const u8,
        base_branch: []const u8,
        cwd: ?[]const u8,
    ) !PullRequestInfo {
        var cap = self.capture(&[_][]const u8{
            "gh",        "pr",        "create",
            "--repo",    repo,        "--title",
            title,       "--body",    body,
            "--head",    head_branch, "--base",
            base_branch,
        }, cwd) catch |e| {
            self.setLastError("", @errorName(e));
            return error.GhUnavailable;
        };
        defer cap.deinit(self.allocator);
        if (cap.exit_code != 0) {
            self.setLastError(cap.stderr, "gh pr create failed");
            return error.GhCreateFailed;
        }
        // gh imprime la URL del PR en stdout; `gh pr view <url>` es la
        // confirmación autoritativa (número y estado reales, no asumidos).
        const pr_url = parsePrUrlFromCreate(cap.stdout) orelse {
            self.setLastError(cap.stdout, "gh pr create: salida sin URL de PR");
            return error.GhParseFailed;
        };
        const viewed = try self.ghViewPr(repo, pr_url);
        return PullRequestInfo{
            .order_id = 0,
            .provider = try self.allocator.dupe(u8, "github"),
            .repo = try self.allocator.dupe(u8, repo),
            .number = viewed.number,
            .state = viewed.state,
            .url = viewed.url,
            .last_polled_at = nowMs(),
        };
    }

    /// Estado real del PR vía `gh pr view --json state,statusCheckRollup`.
    /// Error si gh falla — jamás un `.open` fingido.
    pub fn getPullRequestState(self: *GitHubConnector, repo: []const u8, number: i64) !PullRequestState {
        const num_str = try std.fmt.allocPrint(self.allocator, "{d}", .{number});
        defer self.allocator.free(num_str);
        const viewed = try self.ghViewPr(repo, num_str);
        defer self.allocator.free(viewed.url);
        return viewed.state;
    }

    /// Ejecuta el merge del PR con salida capturada: un `gh pr merge` que
    /// falla (sin permisos, checks pendientes, PR cerrado) deja su stderr real
    /// en `last_error` en vez de un exit code mudo.
    pub fn mergePullRequest(self: *GitHubConnector, repo: []const u8, number: i64, cwd: ?[]const u8) !void {
        const num_str = try std.fmt.allocPrint(self.allocator, "{d}", .{number});
        defer self.allocator.free(num_str);

        var cap = self.capture(&[_][]const u8{ "gh", "pr", "merge", num_str, "--repo", repo, "--auto", "--merge" }, cwd) catch |e| {
            self.setLastError("", @errorName(e));
            return error.GhUnavailable;
        };
        defer cap.deinit(self.allocator);
        if (cap.exit_code != 0) {
            self.setLastError(cap.stderr, "gh pr merge failed");
            return error.GhMergeFailed;
        }
    }

    /// `gh repo view --json nameWithOwner,defaultBranchRef` dentro del
    /// worktree: slug y rama base REALES del remoto. Cualquier fallo (gh
    /// ausente, sin auth, sin remote) es error — nunca un slug inventado.
    pub const RepoInfo = struct {
        slug: []u8,
        base: []u8,

        pub fn deinit(self: *RepoInfo, allocator: std.mem.Allocator) void {
            allocator.free(self.slug);
            allocator.free(self.base);
        }
    };

    pub fn detectRepo(self: *GitHubConnector, cwd: ?[]const u8) !RepoInfo {
        var cap = self.capture(&[_][]const u8{ "gh", "repo", "view", "--json", "nameWithOwner,defaultBranchRef" }, cwd) catch |e| {
            self.setLastError("", @errorName(e));
            return error.GhUnavailable;
        };
        defer cap.deinit(self.allocator);
        if (cap.exit_code != 0) {
            self.setLastError(cap.stderr, "gh repo view failed");
            return error.GhFailed;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, cap.stdout, .{}) catch {
            self.setLastError(cap.stdout, "gh repo view: JSON ilegible");
            return error.GhParseFailed;
        };
        defer parsed.deinit();
        const o = parsed.value.object;
        const slug = if (o.get("nameWithOwner")) |v| switch (v) {
            .string => |t| try self.allocator.dupe(u8, t),
            else => return error.GhParseFailed,
        } else return error.GhParseFailed;
        errdefer self.allocator.free(slug);
        var base: []u8 = try self.allocator.dupe(u8, "main");
        errdefer self.allocator.free(base);
        if (o.get("defaultBranchRef")) |v| {
            if (v == .object) {
                if (v.object.get("name")) |n| {
                    if (n == .string and n.string.len > 0) {
                        self.allocator.free(base);
                        base = try self.allocator.dupe(u8, n.string);
                    }
                }
            }
        }
        return .{ .slug = slug, .base = base };
    }

    /// `gh pr list --repo <r> --head <b> --state open --json number,url,state
    /// --limit 1`: el PR ABIERTO que ya exista para esa rama, o null. Es la
    /// mitad de "adoptar el PR que el propio agente abrio" (matriz B2): si ya
    /// hay uno, ship lo toma en vez de crear un duplicado.
    pub const ListedPr = struct {
        number: i64,
        url: []u8,
        state: PullRequestState,

        pub fn deinit(self: *ListedPr, allocator: std.mem.Allocator) void {
            allocator.free(self.url);
        }
    };

    pub fn listOpenPrForBranch(self: *GitHubConnector, repo: []const u8, head_branch: []const u8, cwd: ?[]const u8) !?ListedPr {
        var cap = self.capture(&[_][]const u8{
            "gh",        "pr",               "list",
            "--repo",    repo,               "--head",
            head_branch, "--state",          "open",
            "--json",    "number,url,state", "--limit",
            "1",
        }, cwd) catch |e| {
            self.setLastError("", @errorName(e));
            return error.GhUnavailable;
        };
        defer cap.deinit(self.allocator);
        if (cap.exit_code != 0) {
            self.setLastError(cap.stderr, "gh pr list failed");
            return error.GhFailed;
        }
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, cap.stdout, .{}) catch {
            self.setLastError(cap.stdout, "gh pr list: JSON ilegible");
            return error.GhParseFailed;
        };
        defer parsed.deinit();
        if (parsed.value != .array or parsed.value.array.items.len == 0) return null;
        const o = parsed.value.array.items[0].object;
        const number = if (o.get("number")) |v| switch (v) {
            .integer => |n| n,
            else => return error.GhParseFailed,
        } else return error.GhParseFailed;
        const url = if (o.get("url")) |v| switch (v) {
            .string => |t| try self.allocator.dupe(u8, t),
            else => return error.GhParseFailed,
        } else return error.GhParseFailed;
        errdefer self.allocator.free(url);
        var state: PullRequestState = .open;
        if (o.get("state")) |v| {
            if (v == .string) {
                if (std.mem.eql(u8, v.string, "MERGED")) {
                    state = .merged;
                } else if (std.mem.eql(u8, v.string, "CLOSED")) {
                    state = .failed;
                }
            }
        }
        return .{ .number = number, .url = url, .state = state };
    }
};

test "github connector initialization and struct handling" {
    const allocator = std.testing.allocator;

    var gh = GitHubConnector.init(allocator, "dummy_token");
    defer gh.deinit();

    try std.testing.expect(gh.token != null);
    try std.testing.expectEqualStrings("dummy_token", gh.token.?);
}

test "github: parsePrUrlFromCreate extrae la URL real y rechaza salidas sin PR" {
    // Forma real de `gh pr create`: la última línea es la URL del PR.
    const ok_out =
        \\Branch 'feat-x' pushed to origin
        \\https://github.com/acme/widgets/pull/42
        \\
    ;
    try std.testing.expectEqualStrings("https://github.com/acme/widgets/pull/42", GitHubConnector.parsePrUrlFromCreate(ok_out).?);

    // Salida sin URL -> null (nunca se fabrica /pull/1).
    try std.testing.expect(GitHubConnector.parsePrUrlFromCreate("everything up-to-date") == null);
    try std.testing.expect(GitHubConnector.parsePrUrlFromCreate("") == null);
}

/// H19 (15-nov): las pruebas de gh van guionadas por `capture_fn`. Antes
/// lanzaban el `gh` real del PATH contra GitHub; un proceso suyo retuvo la
/// carpeta temporal de la suite (rojo intermitente) y salían a la red.
const GhScript = struct {
    fn absent(_: std.mem.Allocator, argv: []const []const u8, _: ?[]const u8) anyerror!CmdCapture {
        std.debug.assert(std.mem.eql(u8, argv[0], "gh"));
        return error.FileNotFound;
    }
    fn fails(allocator: std.mem.Allocator, argv: []const []const u8, _: ?[]const u8) anyerror!CmdCapture {
        std.debug.assert(std.mem.eql(u8, argv[0], "gh"));
        return .{ .exit_code = 1, .stdout = try allocator.dupe(u8, ""), .stderr = try allocator.dupe(u8, "GraphQL: Could not resolve to a Repository") };
    }
    fn noUrl(allocator: std.mem.Allocator, argv: []const []const u8, _: ?[]const u8) anyerror!CmdCapture {
        std.debug.assert(std.mem.eql(u8, argv[0], "gh"));
        return .{ .exit_code = 0, .stdout = try allocator.dupe(u8, "Creating pull request...\n"), .stderr = try allocator.dupe(u8, "") };
    }
};

test "github: createPullRequest falla honesto cuando gh no existe o no hay repo" {
    const allocator = std.testing.allocator;
    // El contrato que importa: NUNCA devuelve un PullRequestInfo fabricado,
    // y cada fallo tiene su error y su diagnóstico.
    const cases = [_]struct { f: CaptureFn, want: anyerror }{
        .{ .f = GhScript.absent, .want = error.GhUnavailable },
        .{ .f = GhScript.fails, .want = error.GhCreateFailed },
        .{ .f = GhScript.noUrl, .want = error.GhParseFailed },
    };
    for (cases) |c| {
        var gh = GitHubConnector.init(allocator, null);
        defer gh.deinit();
        gh.capture_fn = c.f;
        const res = gh.createPullRequest("no-existe/repo-inexistente-xyz", "t", "b", "head", "base", null);
        if (res) |info| {
            var i = info;
            i.deinit(allocator);
            return error.TestUnexpectedResult;
        } else |e| {
            try std.testing.expectEqual(c.want, e);
            try std.testing.expect(gh.last_error.items.len > 0);
        }
    }
}

test "github: getPullRequestState nunca devuelve .open sin leer gh" {
    const allocator = std.testing.allocator;
    // PR inexistente en repo inexistente -> error, no un estado inventado.
    const cases = [_]struct { f: CaptureFn, want: anyerror }{
        .{ .f = GhScript.absent, .want = error.GhUnavailable },
        .{ .f = GhScript.fails, .want = error.GhFailed },
        .{ .f = GhScript.noUrl, .want = error.GhParseFailed },
    };
    for (cases) |c| {
        var gh = GitHubConnector.init(allocator, null);
        defer gh.deinit();
        gh.capture_fn = c.f;
        try std.testing.expectError(c.want, gh.getPullRequestState("no-existe/repo-inexistente-xyz", 999999));
    }
}

test "github E5.26 external error censors CLI output and known short token" {
    var gh = GitHubConnector.init(std.testing.allocator, "fx-s7");
    defer gh.deinit();
    for ([_][]const u8{ "echo fx-s7", "password=fx-p9", "Authorization: fx-a2" }) |raw| {
        gh.setLastError(raw, "failed");
        try std.testing.expectEqualStrings("[texto externo] [REDACTADO]", gh.last_error.items);
    }
    gh.setLastError("", "git failed");
    try std.testing.expectEqualStrings("[texto externo] git failed", gh.last_error.items);
    gh.setLastError("fatal: Authentication failed", "failed");
    try std.testing.expectEqualStrings("[texto externo] Authentication failed", gh.last_error.items);
    gh.setLastError("GraphQL: password=fx-p9", "failed");
    try std.testing.expectEqualStrings("[texto externo] [REDACTADO]", gh.last_error.items);
}

test "SEC2 clone URL allowlist rejects options, transports and local paths" {
    for ([_][]const u8{ "--upload-pack=calc", "-c", "ext::sh -c calc", "file:///C:/repo", "C:\\repo", "ssh://-oProxyCommand=x/y", "https://", "https://ok example", "git@-host:x", "", "http://insecure/x.git" }) |url| {
        try std.testing.expect(!isCloneUrlAllowed(url));
    }
    for ([_][]const u8{ "https://github.com/owner/repo.git", "HTTPS://github.com/o/r", "git@github.com:owner/repo.git" }) |url| {
        try std.testing.expect(isCloneUrlAllowed(url));
    }
    var gh = GitHubConnector.init(std.testing.allocator, null);
    defer gh.deinit();
    try std.testing.expectError(error.CloneUrlNotAllowed, gh.cloneRepo("--upload-pack=calc", "target"));
    try std.testing.expectError(error.CloneUrlNotAllowed, gh.cloneRepo("https://github.com/o/r", "-evil"));
}
