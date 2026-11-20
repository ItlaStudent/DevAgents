//! E5.04 / (D-C4): preparación del worktree tras `git worktree add`.
//!
//! Lee `<raíz>/.devagents/worktree.json`, copia a la worktree los archivos
//! declarados en `copy` (solo los que existen en la raíz principal y faltan
//! en la worktree) y ejecuta el script de `setup` a través del ejecutor
//! gobernado con cwd = worktree.
//!
//! Contrato (PROMPT-E5 §B1):
//!   · JSON estricto: una clave desconocida es error con su mensaje.
//!   · copy: solo archivos regulares, sin enlaces ni uniones, sin salir de la
//!     raíz, ≤1 MiB por archivo, ≤50 entradas; a la evidencia van nombre y
//!     sha256, nunca el contenido.
//!   · setup.windows: .cmd/.bat por `cmd.exe /d /c`, .ps1 por
//!     `powershell.exe -NoProfile -NonInteractive -File`. setup.posix: `.sh`
//!     por `/bin/sh`. La política de ejecución no se toca: si impide el
//!     script, el fallo es honesto.
//!   · `timeout_s`: por defecto 600, máximo 3600.
//!   · aprobación por (proyecto, sha256 del script); si el hash cambia se
//!     vuelve a pedir. La concesión vive en `worktree_script_approvals` y la
//!     petición pendiente en `approvals` con command_prefix "worktree_script".
//!   · eventos: worktree_prepare_started, worktree_prepared,
//!     worktree_setup_failed (con código y cola de salida acotada) y, cuando
//!     no hay archivo, worktree_setup_suggested con comandos inferidos de los
//!     lockfiles — sin ejecutar nada.
//!   · cualquier fallo de preparación aborta createSpace con la causa real:
//!     no hay degradado silencioso.

const std = @import("std");
const builtin = @import("builtin");
const db = @import("db.zig");
const executor = @import("executor.zig");
const sandbox = @import("sandbox.zig");
const confined_fs = @import("confined_fs.zig");
const health = @import("health.zig");

const windows = std.os.windows;

const CreateFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateFileA(
        lpFileName: [*:0]const u8,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?windows.HANDLE,
    ) callconv(.c) windows.HANDLE;
}.CreateFileA else @import("providers").posix_files.CreateFileA;
const ReadFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn ReadFile(hFile: windows.HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque) callconv(.c) c_int;
}.ReadFile else @import("providers").posix_files.ReadFile;
const WriteFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn WriteFile(hFile: windows.HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque) callconv(.c) c_int;
}.WriteFile else @import("providers").posix_files.WriteFile;
const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.c) c_int;
}.CloseHandle else @import("providers").posix_files.CloseHandle;
const GetFileAttributesA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileAttributesA(lpFileName: [*:0]const u8) callconv(.winapi) u32;
}.GetFileAttributesA else @import("providers").posix_files.GetFileAttributesA;
const GetFileSizeEx = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileSizeEx(hFile: windows.HANDLE, lpFileSize: *i64) callconv(.c) c_int;
}.GetFileSizeEx else @import("providers").posix_files.GetFileSizeEx;
extern "kernel32" fn GetFileInformationByHandleEx(windows.HANDLE, c_int, *anyopaque, u32) callconv(.winapi) c_int;
const CreateDirectoryA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateDirectoryA(lpPathName: [*:0]const u8, lpSecurityAttributes: ?*anyopaque) callconv(.c) c_int;
}.CreateDirectoryA else @import("providers").posix_files.CreateDirectoryA;
const GetEnvironmentVariableA = @import("platform.zig").env;
const GetTempPathA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetTempPathA(nBufferLength: u32, lpBuffer: [*]u8) callconv(.c) u32;
}.GetTempPathA else @import("platform.zig").tempPath;
const GetTickCount64 = @import("platform.zig").ticks;
extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: u32) callconv(.c) u32;
extern "kernel32" fn GetExitCodeProcess(hProcess: windows.HANDLE, lpExitCode: *u32) callconv(.c) c_int;
extern "kernel32" fn CreateProcessA(
    lpApplicationName: ?[*:0]const u8,
    lpCommandLine: [*:0]u8,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: c_int,
    dwCreationDisposition: u32,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u8,
    lpStartupInfo: *STARTUPINFOA_T,
    lpProcessInformation: *PROCESS_INFORMATION_T,
) callconv(.c) c_int;

const STARTUPINFOA_T = extern struct {
    cb: u32 = @sizeOf(STARTUPINFOA_T),
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

const PROCESS_INFORMATION_T = extern struct {
    hProcess: windows.HANDLE,
    hThread: windows.HANDLE,
    dwProcessId: u32,
    dwThreadId: u32,
};

const INVALID_HANDLE_VALUE_T: windows.HANDLE = @ptrFromInt(~@as(usize, 0));
const INVALID_FILE_ATTRIBUTES_T: u32 = 0xFFFFFFFF;
const GENERIC_READ_T: u32 = 0x80000000;
const GENERIC_WRITE_T: u32 = 0x40000000;
const FILE_SHARE_READ_T: u32 = 0x00000001;
const FILE_SHARE_WRITE_T: u32 = 0x00000002;
const OPEN_EXISTING_T: u32 = 3;
const CREATE_NEW_T: u32 = 1;
const CREATE_ALWAYS_T: u32 = 2;
const FILE_ATTRIBUTE_NORMAL_T: u32 = 0x80;
const FILE_ATTRIBUTE_DIRECTORY_T: u32 = 0x10;
const FILE_ATTRIBUTE_REPARSE_POINT_T: u32 = 0x400;
const CREATE_NO_WINDOW_T: u32 = 0x08000000;

pub const MAX_COPY_FILE_BYTES: u64 = 1024 * 1024;
pub const MAX_COPY_FILES: usize = 50;
const MAX_CONFIG_BYTES: i64 = 64 * 1024;
pub const DEFAULT_TIMEOUT_S: u32 = 600;
pub const MAX_TIMEOUT_S: u32 = 3600;
const SETUP_OUTPUT_CAP: usize = 256 * 1024;
const EVENT_TAIL_BYTES: usize = 2048;
const MAX_REL_LEN: usize = 4000;

/// command_prefix de la fila pendiente en `approvals`: la cabina la lista con
/// las demás y `da_approval_resolve` la convierte en concesión por hash.
pub const APPROVAL_PREFIX: []const u8 = "worktree_script";

pub const PrepError = error{
    InvalidConfig,
    CopyPathEscape,
    CopyNotRegular,
    CopyTooLarge,
    CopyTooMany,
    CopyFailed,
    SetupScriptInvalid,
    SetupPendingApproval,
    SetupFailed,
    OutOfMemory,
};

/// `e` proviene de la fase de preparación (no del alta del space en sí): el
/// llamador la trata como fallo de la orden, no como "seguir en la raíz".
pub fn isPrepError(e: anyerror) bool {
    return switch (e) {
        error.InvalidConfig,
        error.CopyPathEscape,
        error.CopyNotRegular,
        error.CopyTooLarge,
        error.CopyTooMany,
        error.CopyFailed,
        error.SetupScriptInvalid,
        error.SetupPendingApproval,
        error.SetupFailed,
        error.OutOfMemory,
        => true,
        else => false,
    };
}

/// Diagnóstico legible del fallo de preparación. `prepare` lo rellena antes
/// de devolver error: es la causa real que llega al evento y a last_error.
pub const Diag = struct {
    buf: [512]u8 = [_]u8{0} ** 512,
    len: usize = 0,
    pending_script_buf: [512]u8 = [_]u8{0} ** 512,
    pending_script_len: usize = 0,
    pending_sha256: [64]u8 = [_]u8{'0'} ** 64,
    has_pending: bool = false,

    pub fn msg(self: *const Diag) []const u8 {
        return self.buf[0..self.len];
    }
    pub fn pendingScript(self: *const Diag) []const u8 {
        return self.pending_script_buf[0..self.pending_script_len];
    }
    pub fn pendingSha256(self: *const Diag) []const u8 {
        return self.pending_sha256[0..];
    }
    fn setf(self: *Diag, comptime fmt: []const u8, args: anytype) void {
        const s = std.fmt.bufPrint(&self.buf, fmt, args) catch return;
        self.len = s.len;
    }
    fn setPending(self: *Diag, script: []const u8, sha: *const [64]u8) void {
        const n = @min(script.len, self.pending_script_buf.len);
        @memcpy(self.pending_script_buf[0..n], script[0..n]);
        self.pending_script_len = n;
        self.pending_sha256 = sha.*;
        self.has_pending = true;
    }
};

/// Evidencia de una copia: nombre y hash. El contenido NUNCA sale de aquí.
pub const CopyRecord = struct {
    filename: []const u8,
    sha256_hex: [64]u8,
};

/// Sumidero de evidencia de copia (c_api lo adapta al audit_queue → ledger).
pub const AuditCopyFn = *const fn (ctx: ?*anyopaque, rec: CopyRecord) void;

/// Lanzador del script de setup. Producción: `runVerifierPinned` con el
/// intérprete fijado por ruta absoluta elegida por el motor. Tests: fake.
pub const SetupRunFn = *const fn (
    allocator: std.mem.Allocator,
    exe_abs: []const u8,
    args: []const []const u8,
    cwd: []const u8,
    timeout_ms: u32,
    max_output_bytes: usize,
) executor.ExecutorError!executor.RunResult;

pub const Options = struct {
    project_id: []const u8,
    /// Raíz principal del proyecto (donde vive .devagents/worktree.json).
    base_dir: []const u8,
    /// Raíz del worktree/space recién creado (cwd del setup y destino de copy).
    worktree_dir: []const u8,
    space_name: []const u8 = "",
    order_id: i64 = 0,
    is_non_git: bool = false,
    run_fn: ?SetupRunFn = null,
    audit_fn: ?AuditCopyFn = null,
    audit_ctx: ?*anyopaque = null,
    diag: ?*Diag = null,
};

const Config = struct {
    copy: [][]u8,
    setup_windows: ?[]u8,
    setup_posix: ?[]u8,
    timeout_s: u32,
    parsed: std.json.Parsed(std.json.Value),
    allocator: std.mem.Allocator,

    fn deinit(self: *Config) void {
        for (self.copy) |c| self.allocator.free(c);
        self.allocator.free(self.copy);
        if (self.setup_windows) |s| self.allocator.free(s);
        if (self.setup_posix) |s| self.allocator.free(s);
        self.parsed.deinit();
    }
};

const CopyStats = struct {
    copied: u32 = 0,
    skipped_existing: u32 = 0,
    skipped_missing: u32 = 0,
};

// ── Eventos ─────────────────────────────────────────────────────────────

fn emitEvent(conn: db.Connection, order_id: i64, kind: []const u8, payload: []const u8) void {
    const stmt = conn.prepare(
        "INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (?, 'spaces', ?, ?, ?)",
    ) catch return;
    defer conn.finalize(stmt);
    db.bindInt(stmt, 1, health.nowMillis(conn)) catch return;
    db.bindText(stmt, 2, kind) catch return;
    db.bindText(stmt, 3, payload) catch return;
    db.bindInt(stmt, 4, order_id) catch return;
    _ = db.c.sqlite3_step(stmt);
}

fn emitStarted(conn: db.Connection, aa: std.mem.Allocator, o: Options) void {
    var out: std.Io.Writer.Allocating = .init(aa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    js.beginObject() catch return;
    js.objectField("project") catch return;
    js.write(o.project_id) catch return;
    js.objectField("space") catch return;
    js.write(o.space_name) catch return;
    js.objectField("worktree") catch return;
    js.write(o.worktree_dir) catch return;
    js.objectField("is_non_git") catch return;
    js.write(o.is_non_git) catch return;
    js.endObject() catch return;
    emitEvent(conn, o.order_id, "worktree_prepare_started", out.written());
}

fn emitPrepared(conn: db.Connection, aa: std.mem.Allocator, o: Options, stats: CopyStats, setup_state: []const u8) void {
    var out: std.Io.Writer.Allocating = .init(aa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    js.beginObject() catch return;
    js.objectField("project") catch return;
    js.write(o.project_id) catch return;
    js.objectField("space") catch return;
    js.write(o.space_name) catch return;
    js.objectField("copied") catch return;
    js.write(stats.copied) catch return;
    js.objectField("skipped_existing") catch return;
    js.write(stats.skipped_existing) catch return;
    js.objectField("skipped_missing") catch return;
    js.write(stats.skipped_missing) catch return;
    js.objectField("setup") catch return;
    js.write(setup_state) catch return;
    js.endObject() catch return;
    emitEvent(conn, o.order_id, "worktree_prepared", out.written());
}

const FailInfo = struct {
    cause: []const u8,
    detail: []const u8 = "",
    script: ?[]const u8 = null,
    exit_code: ?i32 = null,
    timed_out: bool = false,
    tail: []const u8 = "",
};

fn emitSetupFailed(conn: db.Connection, aa: std.mem.Allocator, o: Options, info: FailInfo) void {
    var out: std.Io.Writer.Allocating = .init(aa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    js.beginObject() catch return;
    js.objectField("project") catch return;
    js.write(o.project_id) catch return;
    js.objectField("space") catch return;
    js.write(o.space_name) catch return;
    js.objectField("cause") catch return;
    js.write(info.cause) catch return;
    if (info.detail.len > 0) {
        js.objectField("detail") catch return;
        js.write(info.detail) catch return;
    }
    if (info.script) |s| {
        js.objectField("script") catch return;
        js.write(s) catch return;
    }
    if (info.exit_code) |c| {
        js.objectField("exit_code") catch return;
        js.write(c) catch return;
    }
    if (info.timed_out) {
        js.objectField("timed_out") catch return;
        js.write(true) catch return;
    }
    if (info.tail.len > 0) {
        js.objectField("output_tail") catch return;
        js.write(info.tail) catch return;
    }
    js.endObject() catch return;
    emitEvent(conn, o.order_id, "worktree_setup_failed", out.written());
}

fn emitSuggested(conn: db.Connection, aa: std.mem.Allocator, o: Options, detected: []const []const u8, commands: []const []const u8) void {
    var out: std.Io.Writer.Allocating = .init(aa);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    js.beginObject() catch return;
    js.objectField("project") catch return;
    js.write(o.project_id) catch return;
    js.objectField("space") catch return;
    js.write(o.space_name) catch return;
    js.objectField("detected") catch return;
    js.beginArray() catch return;
    for (detected) |d| js.write(d) catch return;
    js.endArray() catch return;
    js.objectField("commands") catch return;
    js.beginArray() catch return;
    for (commands) |c| js.write(c) catch return;
    js.endArray() catch return;
    js.endObject() catch return;
    emitEvent(conn, o.order_id, "worktree_setup_suggested", out.written());
}

// ── Rutas ───────────────────────────────────────────────────────────────

/// Valida una ruta RELATIVA y la reescribe en `out` con separador '\\'.
/// Rechaza: vacía, absoluta (`X:`, `\`, `/`), componentes `..` y NUL.
/// Devuelve null si no es una relativa limpia.
fn normalizeRel(rel: []const u8, out: *[4096]u8) ?[]const u8 {
    if (rel.len == 0 or rel.len > MAX_REL_LEN) return null;
    if (rel[0] == '\\' or rel[0] == '/') return null;
    if (rel.len >= 2 and rel[1] == ':') return null;
    if (std.mem.indexOfScalar(u8, rel, 0) != null) return null;

    var w: usize = 0;
    var i: usize = 0;
    var first = true;
    while (i <= rel.len) {
        var j = i;
        while (j < rel.len and rel[j] != '\\' and rel[j] != '/') j += 1;
        const comp = rel[i..j];
        if (comp.len > 0) {
            if (std.mem.eql(u8, comp, "..")) return null;
            if (!std.mem.eql(u8, comp, ".")) {
                if (!first) {
                    out[w] = '\\';
                    w += 1;
                }
                @memcpy(out[w..][0..comp.len], comp);
                w += comp.len;
                first = false;
            }
        }
        i = j + 1;
    }
    if (w == 0) return null;
    return out[0..w];
}

/// Recorre los componentes de `rel` (normalizada, separador '\\') bajo `root`
/// y devuelve true si alguno EXISTE y es un punto de reanálisis (enlace
/// simbólico o unión). `include_last=false` recorre solo los padres — para
/// el destino, que aún no existe. Un componente inexistente corta el paseo:
/// nada más profundo puede existir.
fn chainHasReparse(root: []const u8, rel: []const u8, include_last: bool) bool {
    var buf: [4096:0]u8 = undefined;
    if (root.len + 1 + rel.len >= buf.len) return true; // fail-closed
    @memcpy(buf[0..root.len], root);
    var w = root.len;
    var i: usize = 0;
    while (i < rel.len) {
        var j = i;
        while (j < rel.len and rel[j] != '\\') j += 1;
        const is_last = (j == rel.len);
        if (!is_last or include_last) {
            buf[w] = '\\';
            w += 1;
            @memcpy(buf[w..][0 .. j - i], rel[i..j]);
            w += j - i;
            buf[w] = 0;
            const a = GetFileAttributesA(@ptrCast(&buf[0]));
            if (a == INVALID_FILE_ATTRIBUTES_T) return false;
            if (a & FILE_ATTRIBUTE_REPARSE_POINT_T != 0) return true;
        }
        i = j + 1;
    }
    return false;
}

/// Atributos Win32 de `root\rel`, o null si no existe (o la ruta no cabe).
fn attrsOfRel(root: []const u8, rel: []const u8, buf: *[4096:0]u8) ?u32 {
    if (root.len + 1 + rel.len >= buf.len) return null;
    @memcpy(buf[0..root.len], root);
    buf[root.len] = '\\';
    @memcpy(buf[root.len + 1 ..][0..rel.len], rel);
    buf[root.len + 1 + rel.len] = 0;
    const a = GetFileAttributesA(@ptrCast(&buf[0]));
    if (a == INVALID_FILE_ATTRIBUTES_T) return null;
    return a;
}

fn joinAbs(allocator: std.mem.Allocator, root: []const u8, rel: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ root, rel });
}

/// Crea todos los directorios padre de `abs` (que apunta a un archivo).
fn makeParents(abs: []const u8) bool {
    var buf: [4096:0]u8 = undefined;
    if (abs.len >= buf.len) return false;
    @memcpy(buf[0..abs.len], abs);
    var i: usize = 0;
    while (i < abs.len) : (i += 1) {
        const c = abs[i];
        if ((c == '\\' or c == '/') and i > 0) {
            buf[i] = 0;
            _ = CreateDirectoryA(@ptrCast(&buf[0]), null);
            buf[i] = c;
        }
    }
    return true;
}

// ── Config ──────────────────────────────────────────────────────────────

fn dupeRel(allocator: std.mem.Allocator, raw: []const u8, field: []const u8, diag: *Diag) PrepError![]u8 {
    var nb: [4096]u8 = undefined;
    const rel = normalizeRel(raw, &nb) orelse {
        diag.setf("'{s}': la ruta no es relativa limpia: {s}", .{ field, raw });
        return error.InvalidConfig;
    };
    return allocator.dupe(u8, rel) catch return error.OutOfMemory;
}

/// Lee y valida `<base>\.devagents\worktree.json`. null = no hay archivo.
/// Cualquier clave desconocida o tipo erróneo es error con su mensaje.
fn loadConfig(allocator: std.mem.Allocator, base_dir: []const u8, diag: *Diag) PrepError!?Config {
    const path = std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ ".devagents" ++ std.fs.path.sep_str ++ "worktree.json", .{base_dir}) catch return error.OutOfMemory;
    defer allocator.free(path);
    const path_z = allocator.dupeZ(u8, path) catch return error.OutOfMemory;
    defer allocator.free(path_z);

    if (GetFileAttributesA(path_z.ptr) == INVALID_FILE_ATTRIBUTES_T) return null;

    const h = CreateFileA(path_z.ptr, GENERIC_READ_T, FILE_SHARE_READ_T, null, OPEN_EXISTING_T, FILE_ATTRIBUTE_NORMAL_T, null);
    if (h == INVALID_HANDLE_VALUE_T) {
        diag.setf("no se pudo abrir {s}", .{path});
        return error.InvalidConfig;
    }
    defer _ = CloseHandle(h);
    var size: i64 = 0;
    if (GetFileSizeEx(h, &size) == 0 or size <= 0 or size > MAX_CONFIG_BYTES) {
        diag.setf("worktree.json vacío o demasiado grande ({d} bytes)", .{size});
        return error.InvalidConfig;
    }
    const text = allocator.alloc(u8, @intCast(size)) catch return error.OutOfMemory;
    defer allocator.free(text);
    var n: u32 = 0;
    if (ReadFile(h, text.ptr, @intCast(text.len), &n, null) == 0 or n != text.len) {
        diag.setf("no se pudo leer {s}", .{path});
        return error.InvalidConfig;
    }

    var parsed = std.json.parseFromSlice(std.json.Value, allocator, text, .{ .allocate = .alloc_always }) catch {
        diag.setf("worktree.json no es JSON válido", .{});
        return error.InvalidConfig;
    };
    errdefer parsed.deinit();
    if (parsed.value != .object) {
        diag.setf("worktree.json debe ser un objeto JSON", .{});
        return error.InvalidConfig;
    }

    var copy_list = std.ArrayList([]u8).empty;
    errdefer {
        for (copy_list.items) |c| allocator.free(c);
        copy_list.deinit(allocator);
    }
    var setup_windows: ?[]u8 = null;
    errdefer if (setup_windows) |s| allocator.free(s);
    var setup_posix: ?[]u8 = null;
    errdefer if (setup_posix) |s| allocator.free(s);
    var timeout_s: u32 = DEFAULT_TIMEOUT_S;

    var it = parsed.value.object.iterator();
    while (it.next()) |kv| {
        const key = kv.key_ptr.*;
        const val = kv.value_ptr.*;
        if (std.mem.eql(u8, key, "copy")) {
            if (val != .array) {
                diag.setf("'copy' debe ser un array de rutas", .{});
                return error.InvalidConfig;
            }
            if (val.array.items.len > MAX_COPY_FILES) {
                diag.setf("'copy' supera el máximo de {d} archivos", .{MAX_COPY_FILES});
                return error.CopyTooMany;
            }
            for (val.array.items) |item| {
                if (item != .string) {
                    diag.setf("'copy' solo admite rutas de texto", .{});
                    return error.InvalidConfig;
                }
                const owned = try dupeRel(allocator, item.string, "copy", diag);
                copy_list.append(allocator, owned) catch {
                    allocator.free(owned);
                    return error.OutOfMemory;
                };
            }
        } else if (std.mem.eql(u8, key, "setup")) {
            if (val != .object) {
                diag.setf("'setup' debe ser un objeto", .{});
                return error.InvalidConfig;
            }
            var sit = val.object.iterator();
            while (sit.next()) |skv| {
                const skey = skv.key_ptr.*;
                const sval = skv.value_ptr.*;
                if (!std.mem.eql(u8, skey, "windows") and !std.mem.eql(u8, skey, "posix")) {
                    diag.setf("clave desconocida en 'setup': \"{s}\"", .{skey});
                    return error.InvalidConfig;
                }
                if (sval != .string) {
                    diag.setf("'setup.{s}' debe ser una ruta de texto", .{skey});
                    return error.InvalidConfig;
                }
                const owned = try dupeRel(allocator, sval.string, skey, diag);
                if (std.mem.eql(u8, skey, "windows")) {
                    if (setup_windows) |old| allocator.free(old);
                    setup_windows = owned;
                } else {
                    if (setup_posix) |old| allocator.free(old);
                    setup_posix = owned;
                }
            }
        } else if (std.mem.eql(u8, key, "timeout_s")) {
            if (val != .integer or val.integer < 1 or val.integer > MAX_TIMEOUT_S) {
                diag.setf("'timeout_s' debe ser un entero entre 1 y {d}", .{MAX_TIMEOUT_S});
                return error.InvalidConfig;
            }
            timeout_s = @intCast(val.integer);
        } else {
            diag.setf("clave desconocida en worktree.json: \"{s}\"", .{key});
            return error.InvalidConfig;
        }
    }

    return Config{
        .copy = copy_list.toOwnedSlice(allocator) catch return error.OutOfMemory,
        .setup_windows = setup_windows,
        .setup_posix = setup_posix,
        .timeout_s = timeout_s,
        .parsed = parsed,
        .allocator = allocator,
    };
}

// ── Copia ───────────────────────────────────────────────────────────────

const CopyOutcome = enum { copied, skipped_existing, skipped_missing };

fn copyError(e: anyerror, rel: []const u8, diag: *Diag) PrepError {
    diag.setf("no se pudo copiar '{s}': {s}", .{ rel, @errorName(e) });
    return switch (e) {
        error.OutOfMemory => error.OutOfMemory,
        error.SandboxDenied, error.RootChanged => error.CopyPathEscape,
        error.HardLinkDenied => error.CopyNotRegular,
        else => error.CopyFailed,
    };
}

/// Copia UN archivo de la raíz principal al worktree aplicando todas las
/// guardias: relativa limpia, contenida en ambas raíces, regular (ni enlace,
/// ni unión, ni directorio), ≤1 MiB, y destino inexistente (CREATE_NEW, sin
/// sobrescritura ni carrera). Devuelve el resultado o el error de guardia.
fn copyOne(
    allocator: std.mem.Allocator,
    source_root: *const confined_fs.Root,
    destination_root: *const confined_fs.Root,
    o: Options,
    rel: []const u8,
    diag: *Diag,
) PrepError!CopyOutcome {
    const source_relative = source_root.relativePath(rel) catch |e| return copyError(e, rel, diag);
    defer allocator.free(source_relative);
    const destination_relative = destination_root.relativePath(rel) catch |e| return copyError(e, rel, diag);
    defer allocator.free(destination_relative);
    const source = source_root.open(source_relative) catch |e| {
        if (e == error.FileNotFound) return .skipped_missing;
        return copyError(e, rel, diag);
    };
    defer @import("platform.zig").closeHandle(source.handle);
    const is_directory = if (@import("builtin").os.tag == .windows) blk: {
        const AttributeTag = extern struct { attributes: u32, tag: u32 };
        var attrs: AttributeTag = undefined;
        if (GetFileInformationByHandleEx(source.handle, 9, &attrs, @sizeOf(AttributeTag)) == 0) return error.CopyFailed;
        break :blk attrs.attributes & FILE_ATTRIBUTE_DIRECTORY_T != 0;
    } else !((@import("platform.zig").fdInfo(source.handle) catch return error.CopyFailed).regular);
    if (is_directory) {
        diag.setf("'{s}' no es un archivo regular", .{rel});
        return error.CopyNotRegular;
    }
    // Mantiene el contrato de omitir destinos existentes antes de leer datos;
    // la creación exclusiva posterior sigue resolviendo carreras de creación.
    if (destination_root.openMetadata(destination_relative)) |existing| {
        @import("platform.zig").closeHandle(existing.handle);
        return .skipped_existing;
    } else |e| {
        if (e != error.FileNotFound) return copyError(e, rel, diag);
    }

    var size: i64 = 0;
    const size_ok = if (@import("builtin").os.tag == .windows) GetFileSizeEx(source.handle, &size) != 0 else blk: {
        const info = @import("platform.zig").fdInfo(source.handle) catch break :blk false;
        size = @intCast(info.size);
        break :blk true;
    };
    if (!size_ok or size < 0) {
        diag.setf("no se pudo medir '{s}'", .{rel});
        return error.CopyFailed;
    }
    if (size > @as(i64, @intCast(MAX_COPY_FILE_BYTES))) {
        diag.setf("'{s}' supera el máximo de {d} bytes", .{ rel, MAX_COPY_FILE_BYTES });
        return error.CopyTooLarge;
    }
    const content = allocator.alloc(u8, @intCast(size)) catch return error.OutOfMemory;
    defer allocator.free(content);
    var total: usize = 0;
    while (total < content.len) {
        var n: u32 = 0;
        const read_ok = if (@import("builtin").os.tag == .windows)
            ReadFile(source.handle, content.ptr + total, @intCast(content.len - total), &n, null) != 0
        else if (@import("platform.zig").fdRead(source.handle, content[total..])) |got| blk: {
            n = @intCast(got);
            break :blk true;
        } else |_| false;
        if (!read_ok or n == 0) {
            diag.setf("no se pudo leer completo '{s}'", .{rel});
            return error.CopyFailed;
        }
        total += n;
    }

    // Los padres permanecen abiertos; CREATE_NEW nunca reemplaza un destino
    // aparecido entre la lectura y la creación. La escritura usa ese handle.
    var destination = destination_root.openMutation(destination_relative, .exclusive) catch |e| {
        if (e == error.PathAlreadyExists) return .skipped_existing;
        return copyError(e, rel, diag);
    };
    defer destination.deinit();
    destination.writeAll(content) catch |e| return copyError(e, rel, diag);

    // Evidencia: nombre + sha256, jamás el contenido.
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    sha.update(content[0..total]);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    sha.final(&digest);
    const hex = std.fmt.bytesToHex(digest, .lower);
    if (o.audit_fn) |f| f(o.audit_ctx, .{ .filename = rel, .sha256_hex = hex });

    return .copied;
}

fn copyPhase(allocator: std.mem.Allocator, conn: db.Connection, o: Options, cfg: *const Config, diag: *Diag) PrepError!CopyStats {
    var stats: CopyStats = .{};
    if (cfg.copy.len == 0) return stats;

    var source_root = confined_fs.Root.init(allocator, o.base_dir) catch |e| return copyError(e, o.base_dir, diag);
    defer source_root.deinit();
    var destination_root = confined_fs.Root.initMutation(allocator, o.worktree_dir) catch |e| return copyError(e, o.worktree_dir, diag);
    defer destination_root.deinit();

    for (cfg.copy) |rel| {
        const outcome = copyOne(allocator, &source_root, &destination_root, o, rel, diag) catch |e| {
            emitSetupFailed(conn, allocator, o, .{
                .cause = @errorName(e),
                .detail = diag.msg(),
                .script = rel,
            });
            return e;
        };
        switch (outcome) {
            .copied => stats.copied += 1,
            .skipped_existing => stats.skipped_existing += 1,
            .skipped_missing => stats.skipped_missing += 1,
        }
    }
    return stats;
}

// ── Setup ───────────────────────────────────────────────────────────────

fn sha256File(allocator: std.mem.Allocator, abs: []const u8, out: *[64]u8) bool {
    const path_z = allocator.dupeZ(u8, abs) catch return false;
    defer allocator.free(path_z);
    const h = CreateFileA(path_z.ptr, GENERIC_READ_T, FILE_SHARE_READ_T, null, OPEN_EXISTING_T, FILE_ATTRIBUTE_NORMAL_T, null);
    if (h == INVALID_HANDLE_VALUE_T) return false;
    defer _ = CloseHandle(h);
    var size: i64 = 0;
    if (GetFileSizeEx(h, &size) == 0 or size < 0 or size > MAX_COPY_FILE_BYTES) return false;
    const content = allocator.alloc(u8, @intCast(size)) catch return false;
    defer allocator.free(content);
    if (content.len > 0) {
        var n: u32 = 0;
        if (ReadFile(h, content.ptr, @intCast(content.len), &n, null) == 0 or n != content.len) return false;
    }
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    sha.update(content);
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    sha.final(&digest);
    out.* = std.fmt.bytesToHex(digest, .lower);
    return true;
}

fn lowerExtOf(rel: []const u8, buf: *[16]u8) []const u8 {
    var start: usize = 0;
    for (rel, 0..) |c, i| {
        if (c == '\\' or c == '/') start = i + 1;
    }
    const base = rel[start..];
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "";
    const ext = base[dot..];
    if (ext.len > buf.len) return "";
    for (ext, 0..) |c, i| buf[i] = std.ascii.toLower(c);
    return buf[0..ext.len];
}

/// Ruta absoluta al intérprete elegido por el MOTOR bajo %SystemRoot% — no se
/// resuelve por PATH (un cmd.exe plantado en el proyecto no puede suplantarlo).
fn pinnedInterpreter(allocator: std.mem.Allocator, comptime kind: enum { cmd, powershell }) PrepError![]u8 {
    var root_buf: [1024]u8 = undefined;
    const n = GetEnvironmentVariableA("SystemRoot", &root_buf, root_buf.len);
    if (n == 0 or n >= root_buf.len) return error.SetupScriptInvalid;
    const leaf = switch (kind) {
        .cmd => "System32\\cmd.exe",
        .powershell => "System32\\WindowsPowerShell\\v1.0\\powershell.exe",
    };
    const abs = std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ root_buf[0..n], leaf }) catch return error.OutOfMemory;
    errdefer allocator.free(abs);
    const abs_z = allocator.dupeZ(u8, abs) catch return error.OutOfMemory;
    defer allocator.free(abs_z);
    if (GetFileAttributesA(abs_z.ptr) == INVALID_FILE_ATTRIBUTES_T) return error.SetupScriptInvalid;
    return abs;
}

fn governedRun(
    allocator: std.mem.Allocator,
    exe_abs: []const u8,
    args: []const []const u8,
    cwd: []const u8,
    timeout_ms: u32,
    max_output_bytes: usize,
) executor.ExecutorError!executor.RunResult {
    return executor.runVerifierPinned(allocator, .{
        .workspace_root = cwd,
        .timeout_ms = timeout_ms,
        .max_output_bytes = max_output_bytes,
        .origin = .local,
    }, exe_abs, args, cwd);
}

/// ¿Concedido ya el (proyecto, sha256) del script?
pub fn isScriptApproved(conn: db.Connection, project_id: []const u8, sha256_hex: []const u8) bool {
    const stmt = conn.prepare(
        "SELECT 1 FROM worktree_script_approvals WHERE project_id = ? AND script_sha256 = ?",
    ) catch return false;
    defer conn.finalize(stmt);
    db.bindText(stmt, 1, project_id) catch return false;
    db.bindText(stmt, 2, sha256_hex) catch return false;
    return db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW;
}

/// Concesión persistida: la escribe `da_approval_resolve` cuando el usuario
/// aprueba la fila pendiente (o el test, para simular la aprobación).
pub fn approveScript(conn: db.Connection, project_id: []const u8, sha256_hex: []const u8, script_path: []const u8) !void {
    const stmt = try conn.prepare(
        "INSERT OR REPLACE INTO worktree_script_approvals (project_id, script_sha256, script_path, approved_at) VALUES (?, ?, ?, ?)",
    );
    defer conn.finalize(stmt);
    try db.bindText(stmt, 1, project_id);
    try db.bindText(stmt, 2, sha256_hex);
    try db.bindText(stmt, 3, script_path);
    try db.bindInt(stmt, 4, health.nowSeconds(conn));
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.ExecFailed;
}

/// Deja la petición pendiente en `approvals`: la cabina la muestra y al
/// resolverla `da_approval_resolve` llama a `grantFromApprovalJson`.
fn insertPendingScriptApproval(
    conn: db.Connection,
    allocator: std.mem.Allocator,
    o: Options,
    script_rel: []const u8,
    sha: *const [64]u8,
) void {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    js.beginObject() catch return;
    js.objectField("project_id") catch return;
    js.write(o.project_id) catch return;
    js.objectField("script_sha256") catch return;
    js.write(sha[0..]) catch return;
    js.objectField("script") catch return;
    js.write(script_rel) catch return;
    js.endObject() catch return;

    const desc = std.fmt.allocPrint(allocator, "worktree setup {s} (sha256 {s})", .{ script_rel, sha[0..12] }) catch return;
    defer allocator.free(desc);

    const stmt = conn.prepare(
        "INSERT INTO approvals (task_id, description, approved, resolved, created_at, command_prefix, exe, args_json, order_id) VALUES (?, ?, 0, 0, ?, ?, NULL, ?, ?)",
    ) catch return;
    defer conn.finalize(stmt);
    db.bindText(stmt, 1, "worktree_setup") catch return;
    db.bindText(stmt, 2, desc) catch return;
    db.bindInt(stmt, 3, health.nowMillis(conn)) catch return;
    db.bindText(stmt, 4, APPROVAL_PREFIX) catch return;
    db.bindText(stmt, 5, out.written()) catch return;
    db.bindInt(stmt, 6, o.order_id) catch return;
    _ = db.c.sqlite3_step(stmt);
}

/// Convierte la aprobación resuelta en concesión por hash. La llama
/// `da_approval_resolve` cuando la fila tiene command_prefix "worktree_script".
pub fn grantFromApprovalJson(conn: db.Connection, allocator: std.mem.Allocator, args_json: []const u8) !void {
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, args_json, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return error.InvalidJson;
    const o = parsed.value.object;
    const pid = o.get("project_id") orelse return error.InvalidJson;
    const sha = o.get("script_sha256") orelse return error.InvalidJson;
    const script = o.get("script") orelse return error.InvalidJson;
    if (pid != .string or sha != .string or script != .string) return error.InvalidJson;
    try approveScript(conn, pid.string, sha.string, script.string);
}

/// Cola de salida acotada para el evento de fallo: últimos EVENT_TAIL_BYTES,
/// alineada a una frontera UTF-8 para no partir un carácter por la mitad.
fn boundedTail(bytes: []const u8) []const u8 {
    if (bytes.len <= EVENT_TAIL_BYTES) return bytes;
    var start = bytes.len - EVENT_TAIL_BYTES;
    while (start < bytes.len and (bytes[start] & 0xC0) == 0x80) start += 1;
    return bytes[start..];
}

fn setupPhase(allocator: std.mem.Allocator, conn: db.Connection, o: Options, cfg: *const Config, diag: *Diag) PrepError![]const u8 {
    const script_rel = if (builtin.os.tag == .windows) cfg.setup_windows else cfg.setup_posix;
    const rel = script_rel orelse return "none";

    // El script debe existir DENTRO del worktree como archivo regular.
    var sb = sandbox.Sandbox.init(allocator, o.worktree_dir) catch {
        diag.setf("no se pudo montar el sandbox del worktree", .{});
        return error.SetupScriptInvalid;
    };
    defer sb.deinit();
    sb.checkWrite(rel) catch {
        diag.setf("el script '{s}' se sale del worktree", .{rel});
        return error.SetupScriptInvalid;
    };
    var abuf: [4096:0]u8 = undefined;
    const attrs = attrsOfRel(o.worktree_dir, rel, &abuf) orelse {
        diag.setf("el script '{s}' no existe en el worktree", .{rel});
        return error.SetupScriptInvalid;
    };
    if (attrs & FILE_ATTRIBUTE_DIRECTORY_T != 0 or attrs & FILE_ATTRIBUTE_REPARSE_POINT_T != 0 or chainHasReparse(o.worktree_dir, rel, true)) {
        diag.setf("el script '{s}' no es un archivo regular", .{rel});
        return error.SetupScriptInvalid;
    }

    // Intérprete por extensión, fijado por el motor.
    var ext_buf: [16]u8 = undefined;
    const ext = lowerExtOf(rel, &ext_buf);
    const script_abs = joinAbs(allocator, o.worktree_dir, rel) catch return error.OutOfMemory;
    defer allocator.free(script_abs);

    var exe_abs: []u8 = undefined;
    var args_buf: [4][]const u8 = undefined;
    var argc: usize = 0;
    if (builtin.os.tag == .windows) {
        if (std.mem.eql(u8, ext, ".cmd") or std.mem.eql(u8, ext, ".bat")) {
            exe_abs = try pinnedInterpreter(allocator, .cmd);
            args_buf[0] = "/d";
            args_buf[1] = "/c";
            args_buf[2] = script_abs;
            argc = 3;
        } else if (std.mem.eql(u8, ext, ".ps1")) {
            exe_abs = try pinnedInterpreter(allocator, .powershell);
            args_buf[0] = "-NoProfile";
            args_buf[1] = "-NonInteractive";
            args_buf[2] = "-File";
            args_buf[3] = script_abs;
            argc = 4;
        } else {
            diag.setf("extensión de setup no soportada en Windows: '{s}'", .{ext});
            return error.SetupScriptInvalid;
        }
    } else {
        if (std.mem.eql(u8, ext, ".sh")) {
            exe_abs = allocator.dupe(u8, "/bin/sh") catch return error.OutOfMemory;
            args_buf[0] = script_abs;
            argc = 1;
        } else {
            diag.setf("extensión de setup no soportada en POSIX: '{s}'", .{ext});
            return error.SetupScriptInvalid;
        }
    }
    defer allocator.free(exe_abs);

    // Aprobación por (proyecto, sha256 del script). Hash distinto → nueva
    // petición: la concesión queda ligada a los bytes aprobados, no a la ruta.
    var sha: [64]u8 = undefined;
    if (!sha256File(allocator, script_abs, &sha)) {
        diag.setf("no se pudo hashear el script '{s}'", .{rel});
        return error.SetupScriptInvalid;
    }
    if (!isScriptApproved(conn, o.project_id, sha[0..])) {
        diag.setPending(rel, &sha);
        diag.setf("setup '{s}' pendiente de aprobación para este proyecto", .{rel});
        insertPendingScriptApproval(conn, allocator, o, rel, &sha);
        emitSetupFailed(conn, allocator, o, .{
            .cause = "pending_approval",
            .detail = diag.msg(),
            .script = rel,
        });
        return error.SetupPendingApproval;
    }

    const run = o.run_fn orelse governedRun;
    const timeout_ms: u32 = cfg.timeout_s * 1000;
    const result = run(allocator, exe_abs, args_buf[0..argc], o.worktree_dir, timeout_ms, SETUP_OUTPUT_CAP) catch |e| {
        diag.setf("el ejecutor rechazó el setup '{s}': {s}", .{ rel, @errorName(e) });
        emitSetupFailed(conn, allocator, o, .{
            .cause = "executor_rejected",
            .detail = diag.msg(),
            .script = rel,
        });
        return error.SetupFailed;
    };
    defer result.deinit(allocator);

    if (result.exit_code != 0 or result.timed_out) {
        const tail_src = if (result.stderr.len > 0) result.stderr else result.stdout;
        diag.setf("setup '{s}' terminó con código {d}", .{ rel, result.exit_code });
        emitSetupFailed(conn, allocator, o, .{
            .cause = "setup_failed",
            .detail = diag.msg(),
            .script = rel,
            .exit_code = result.exit_code,
            .timed_out = result.timed_out,
            .tail = boundedTail(tail_src),
        });
        return error.SetupFailed;
    }
    return "ran";
}

// ── Sugerencias (sin archivo de configuración) ──────────────────────────

const Suggestion = struct {
    lockfile: []const u8,
    command: []const u8,
};

const SUGGESTION_TABLE = [_]Suggestion{
    .{ .lockfile = "package-lock.json", .command = "npm ci" },
    .{ .lockfile = "npm-shrinkwrap.json", .command = "npm ci" },
    .{ .lockfile = "yarn.lock", .command = "yarn install --frozen-lockfile" },
    .{ .lockfile = "pnpm-lock.yaml", .command = "pnpm install --frozen-lockfile" },
    .{ .lockfile = "bun.lock", .command = "bun install" },
    .{ .lockfile = "bun.lockb", .command = "bun install" },
    .{ .lockfile = "Cargo.lock", .command = "cargo fetch" },
    .{ .lockfile = "go.sum", .command = "go mod download" },
    .{ .lockfile = "requirements.txt", .command = "pip install -r requirements.txt" },
    .{ .lockfile = "poetry.lock", .command = "poetry install" },
    .{ .lockfile = "uv.lock", .command = "uv sync" },
    .{ .lockfile = "Pipfile.lock", .command = "pipenv install" },
    .{ .lockfile = "composer.lock", .command = "composer install" },
    .{ .lockfile = "Gemfile.lock", .command = "bundle install" },
};

fn detectSuggestions(allocator: std.mem.Allocator, base_dir: []const u8, detected: *std.ArrayList([]const u8), commands: *std.ArrayList([]const u8)) void {
    var abuf: [4096:0]u8 = undefined;
    for (&SUGGESTION_TABLE) |s| {
        if (attrsOfRel(base_dir, s.lockfile, &abuf) != null) {
            detected.append(allocator, s.lockfile) catch return;
            commands.append(allocator, s.command) catch return;
        }
    }
}

// ── Orquestación ────────────────────────────────────────────────────────

/// Punto único de E5.04: lo llama `spaces.createSpace` tras crear el
/// directorio/worktree. Devuelve error (isPrepError) cuando la preparación
/// falla — el space NO se registra y la orden cae con la causa real.
pub fn prepare(allocator: std.mem.Allocator, conn: db.Connection, o: Options) PrepError!void {
    var local_diag: Diag = .{};
    const diag = o.diag orelse &local_diag;

    emitStarted(conn, allocator, o);

    const maybe_cfg = loadConfig(allocator, o.base_dir, diag) catch |e| {
        emitSetupFailed(conn, allocator, o, .{
            .cause = "invalid_config",
            .detail = diag.msg(),
        });
        return e;
    };
    var cfg = maybe_cfg orelse {
        // Sin archivo: solo sugerencias por lockfiles. NADA se ejecuta.
        var detected = std.ArrayList([]const u8).empty;
        defer detected.deinit(allocator);
        var commands = std.ArrayList([]const u8).empty;
        defer commands.deinit(allocator);
        detectSuggestions(allocator, o.base_dir, &detected, &commands);
        emitSuggested(conn, allocator, o, detected.items, commands.items);
        return;
    };
    defer cfg.deinit();

    const stats = try copyPhase(allocator, conn, o, &cfg, diag);
    const setup_state = try setupPhase(allocator, conn, o, &cfg, diag);
    emitPrepared(conn, allocator, o, stats, setup_state);
}

// ── Estado para la cabina (E5.05) ───────────────────────────────────────

/// Estado de `.devagents/worktree.json` del proyecto: si existe, si es
/// válido, el detalle del error cuando no lo es, el resumen de la
/// configuración (copias, scripts, timeout) y — cuando no hay archivo — las
/// sugerencias por lockfiles. Todo lo que devuelve es propiedad del
/// allocator del llamador; `deinit` lo libera.
pub const ConfigStatus = struct {
    exists: bool = false,
    valid: bool = false,
    detail: []u8 = &.{},
    copy: [][]const u8 = &.{},
    setup_windows: ?[]u8 = null,
    setup_posix: ?[]u8 = null,
    timeout_s: u32 = DEFAULT_TIMEOUT_S,
    lockfiles: [][]const u8 = &.{},
    commands: [][]const u8 = &.{},
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ConfigStatus) void {
        const a = self.allocator;
        if (self.detail.len > 0) a.free(self.detail);
        freeList(a, self.copy);
        if (self.setup_windows) |s| a.free(s);
        if (self.setup_posix) |s| a.free(s);
        freeList(a, self.lockfiles);
        freeList(a, self.commands);
    }
};

fn freeList(a: std.mem.Allocator, list: [][]const u8) void {
    for (list) |s| a.free(@constCast(s));
    if (list.len > 0) a.free(list);
}

fn dupeList(a: std.mem.Allocator, items: []const []const u8) [][]const u8 {
    if (items.len == 0) return &.{};
    const out = a.alloc([]const u8, items.len) catch return &.{};
    for (items, 0..) |s, i| {
        out[i] = a.dupe(u8, s) catch {
            for (out[0..i]) |prev| a.free(@constCast(prev));
            a.free(out);
            return &.{};
        };
    }
    return out;
}

/// Inspección sin ejecutar nada: lo usa `da_worktree_config_json` para la
/// tarjeta de estado del SpacesPanel.
pub fn inspectConfig(allocator: std.mem.Allocator, base_dir: []const u8) ConfigStatus {
    var st: ConfigStatus = .{ .allocator = allocator };
    var diag: Diag = .{};
    const maybe_cfg = loadConfig(allocator, base_dir, &diag) catch |e| {
        // El archivo está pero no es válido (o no se pudo leer/interpretar).
        st.exists = true;
        st.detail = if (diag.len > 0)
            allocator.dupe(u8, diag.msg()) catch &.{}
        else
            allocator.dupe(u8, @errorName(e)) catch &.{};
        return st;
    };
    var cfg = maybe_cfg orelse {
        var detected = std.ArrayList([]const u8).empty;
        defer detected.deinit(allocator);
        var commands = std.ArrayList([]const u8).empty;
        defer commands.deinit(allocator);
        detectSuggestions(allocator, base_dir, &detected, &commands);
        st.lockfiles = dupeList(allocator, detected.items);
        st.commands = dupeList(allocator, commands.items);
        return st;
    };
    defer cfg.deinit();
    st.exists = true;
    st.valid = true;
    st.copy = dupeList(allocator, cfg.copy);
    if (cfg.setup_windows) |s| st.setup_windows = allocator.dupe(u8, s) catch null;
    if (cfg.setup_posix) |s| st.setup_posix = allocator.dupe(u8, s) catch null;
    st.timeout_s = cfg.timeout_s;
    return st;
}

// ── Tests ───────────────────────────────────────────────────────────────

fn mkDirAbs(path: []const u8) void {
    var buf: [4096:0]u8 = undefined;
    if (path.len >= buf.len) return;
    @memcpy(buf[0..path.len], path);
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        const c = path[i];
        if ((c == '\\' or c == '/') and i > 0) {
            buf[i] = 0;
            _ = CreateDirectoryA(@ptrCast(&buf[0]), null);
            buf[i] = c;
        }
    }
    buf[path.len] = 0;
    _ = CreateDirectoryA(@ptrCast(&buf[0]), null);
}

fn joinAbsT(a: std.mem.Allocator, root: []const u8, rel: []const u8) ![]u8 {
    return std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ root, rel });
}

fn writeAbsFile(a: std.mem.Allocator, root: []const u8, rel: []const u8, data: []const u8) !void {
    const abs = try joinAbsT(a, root, rel);
    defer a.free(abs);
    if (!makeParents(abs)) return error.PathTooLong;
    const abs_z = try a.dupeZ(u8, abs);
    defer a.free(abs_z);
    const h = CreateFileA(abs_z.ptr, GENERIC_WRITE_T, 0, null, CREATE_ALWAYS_T, FILE_ATTRIBUTE_NORMAL_T, null);
    if (h == INVALID_HANDLE_VALUE_T) return error.WriteFailed;
    defer _ = CloseHandle(h);
    var n: u32 = 0;
    if (data.len > 0 and (WriteFile(h, data.ptr, @intCast(data.len), &n, null) == 0 or n != data.len)) return error.WriteFailed;
}

fn readAbsFile(a: std.mem.Allocator, abs: []const u8) ![]u8 {
    const abs_z = try a.dupeZ(u8, abs);
    defer a.free(abs_z);
    const h = CreateFileA(abs_z.ptr, GENERIC_READ_T, FILE_SHARE_READ_T, null, OPEN_EXISTING_T, FILE_ATTRIBUTE_NORMAL_T, null);
    if (h == INVALID_HANDLE_VALUE_T) return error.NotFound;
    defer _ = CloseHandle(h);
    var size: i64 = 0;
    if (GetFileSizeEx(h, &size) == 0 or size < 0) return error.ReadFailed;
    const buf = try a.alloc(u8, @intCast(size));
    errdefer a.free(buf);
    var n: u32 = 0;
    if (buf.len > 0 and (ReadFile(h, buf.ptr, @intCast(buf.len), &n, null) == 0 or n != buf.len)) return error.ReadFailed;
    return buf;
}

fn existsAbs(abs: []const u8) bool {
    var buf: [4096:0]u8 = undefined;
    if (abs.len >= buf.len) return false;
    @memcpy(buf[0..abs.len], abs);
    buf[abs.len] = 0;
    return GetFileAttributesA(@ptrCast(&buf[0])) != INVALID_FILE_ATTRIBUTES_T;
}

fn runCmdTest(a: std.mem.Allocator, cmdline: []const u8) u32 {
    const cmd_z = a.dupeZ(u8, cmdline) catch return 1;
    defer a.free(cmd_z);
    var si: STARTUPINFOA_T = .{ .cb = @sizeOf(STARTUPINFOA_T) };
    var pi: PROCESS_INFORMATION_T = undefined;
    const ok = CreateProcessA(null, cmd_z.ptr, null, null, 0, CREATE_NO_WINDOW_T, null, null, &si, &pi);
    if (ok == 0) return 1;
    defer {
        _ = CloseHandle(pi.hThread);
        _ = CloseHandle(pi.hProcess);
    }
    _ = WaitForSingleObject(pi.hProcess, 15_000);
    var rc: u32 = 1;
    _ = GetExitCodeProcess(pi.hProcess, &rc);
    return rc;
}

/// mklink /J: unión de directorios sin privilegio de symlink. Devuelve false
/// si el sistema no la creó — el test que la usa no debe fingir el resultado.
fn mkJunction(a: std.mem.Allocator, link: []const u8, target: []const u8) bool {
    if (@import("builtin").os.tag != .windows) {
        @import("workspace.zig").createJunction(a, link, target) catch return false;
        return true;
    }
    const cmd = std.fmt.allocPrint(a, "cmd /c mklink /J \"{s}\" \"{s}\" >NUL 2>&1", .{ link, target }) catch return false;
    defer a.free(cmd);
    const rc = runCmdTest(a, cmd);
    return rc == 0 and existsAbs(link);
}

fn testConn(allocator: std.mem.Allocator) !db.Connection {
    var conn = try db.Connection.open(allocator, ":memory:");
    errdefer conn.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);
    return conn;
}

fn countEvents(conn: db.Connection, kind: []const u8) i64 {
    const stmt = conn.prepare("SELECT COUNT(*) FROM events WHERE kind = ?") catch return -1;
    defer conn.finalize(stmt);
    db.bindText(stmt, 1, kind) catch return -1;
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return -1;
    return db.c.sqlite3_column_int64(stmt, 0);
}

fn lastEventPayload(conn: db.Connection, allocator: std.mem.Allocator, kind: []const u8) ?[]u8 {
    const stmt = conn.prepare("SELECT payload_json FROM events WHERE kind = ? ORDER BY rowid DESC LIMIT 1") catch return null;
    defer conn.finalize(stmt);
    db.bindText(stmt, 1, kind) catch return null;
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return null;
    const s = std.mem.span(db.c.sqlite3_column_text(stmt, 0));
    return allocator.dupe(u8, s) catch null;
}

fn pendingApprovals(conn: db.Connection) i64 {
    const stmt = conn.prepare("SELECT COUNT(*) FROM approvals WHERE resolved = 0") catch return -1;
    defer conn.finalize(stmt);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return -1;
    return db.c.sqlite3_column_int64(stmt, 0);
}

fn baseOptions(base: []const u8, wt: []const u8, diag: *Diag) Options {
    return .{
        .project_id = "proj-test",
        .base_dir = base,
        .worktree_dir = wt,
        .space_name = "orden-0001",
        .order_id = 42,
        .diag = diag,
    };
}

var fake_audit_count: usize = 0;
var fake_audit_last_name: [512]u8 = undefined;
var fake_audit_last_name_len: usize = 0;
var fake_audit_last_sha: [64]u8 = undefined;

fn fakeAudit(ctx: ?*anyopaque, rec: CopyRecord) void {
    _ = ctx;
    fake_audit_count += 1;
    // El slice `filename` muere con la Config — el sink real lo duplica al
    // persistir; el fake hace lo mismo para poder verificarlo después.
    const n = @min(rec.filename.len, fake_audit_last_name.len);
    @memcpy(fake_audit_last_name[0..n], rec.filename[0..n]);
    fake_audit_last_name_len = n;
    fake_audit_last_sha = rec.sha256_hex;
}

const FakeRun = struct {
    calls: usize = 0,
    exe: [1024]u8 = undefined,
    exe_len: usize = 0,
    args_flat: [2048]u8 = undefined,
    args_len: usize = 0,
    cwd: [1024]u8 = undefined,
    cwd_len: usize = 0,
    timeout_ms: u32 = 0,
    exit_code: i32 = 0,
    timed_out: bool = false,
    stderr_text: []const u8 = "",
    spawn_error: ?executor.ExecutorError = null,
};

var fake_run: FakeRun = .{};

fn fakeRun(
    allocator: std.mem.Allocator,
    exe_abs: []const u8,
    args: []const []const u8,
    cwd: []const u8,
    timeout_ms: u32,
    max_output_bytes: usize,
) executor.ExecutorError!executor.RunResult {
    _ = max_output_bytes;
    fake_run.calls += 1;
    @memcpy(fake_run.exe[0..exe_abs.len], exe_abs);
    fake_run.exe_len = exe_abs.len;
    var w: usize = 0;
    for (args) |a| {
        if (w > 0) {
            fake_run.args_flat[w] = ' ';
            w += 1;
        }
        @memcpy(fake_run.args_flat[w..][0..a.len], a);
        w += a.len;
    }
    fake_run.args_len = w;
    @memcpy(fake_run.cwd[0..cwd.len], cwd);
    fake_run.cwd_len = cwd.len;
    fake_run.timeout_ms = timeout_ms;
    if (fake_run.spawn_error) |e| return e;
    return .{
        .exit_code = fake_run.exit_code,
        .stdout = try allocator.dupe(u8, "ok\n"),
        .stderr = try allocator.dupe(u8, fake_run.stderr_text),
        .timed_out = fake_run.timed_out,
    };
}

fn resetFakes() void {
    fake_run = .{};
    fake_audit_count = 0;
}

test "E5.04 config: parsea copia, setup y timeout" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    try writeAbsFile(a, root, ".devagents\\worktree.json", "{\"copy\":[\".env\",\"config/a.txt\"],\"setup\":{\"windows\":\"tools\\\\setup.cmd\",\"posix\":\"tools/setup.sh\"},\"timeout_s\":120}");
    var diag: Diag = .{};
    var cfg = (try loadConfig(a, root, &diag)).?;
    defer cfg.deinit();
    try std.testing.expectEqual(@as(usize, 2), cfg.copy.len);
    try std.testing.expectEqualStrings("config\\a.txt", cfg.copy[1]);
    try std.testing.expectEqualStrings("tools\\setup.cmd", cfg.setup_windows.?);
    try std.testing.expectEqualStrings("tools\\setup.sh", cfg.setup_posix.?);
    try std.testing.expectEqual(@as(u32, 120), cfg.timeout_s);
}

test "E5.04 config: archivo ausente devuelve null (no es error)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var diag: Diag = .{};
    const cfg = try loadConfig(a, root, &diag);
    try std.testing.expect(cfg == null);
}

test "E5.04 config: clave desconocida es error con su mensaje" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    try writeAbsFile(a, root, ".devagents\\worktree.json", "{\"copy\":[],\"install\":\"npm ci\"}");
    var diag: Diag = .{};
    try std.testing.expectError(error.InvalidConfig, loadConfig(a, root, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.msg(), "install") != null);
}

test "E5.04 config: JSON malformado es error" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    try writeAbsFile(a, root, ".devagents\\worktree.json", "{\"copy\":[\"a.txt\",");
    var diag: Diag = .{};
    try std.testing.expectError(error.InvalidConfig, loadConfig(a, root, &diag));
}

test "E5.04 config: tipos erróneos, setup desconocido y timeout fuera de rango" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var diag: Diag = .{};

    try writeAbsFile(a, root, ".devagents\\worktree.json", "{\"copy\":\"a.txt\"}");
    try std.testing.expectError(error.InvalidConfig, loadConfig(a, root, &diag));

    try writeAbsFile(a, root, ".devagents\\worktree.json", "{\"setup\":{\"linux\":\"x.sh\"}}");
    try std.testing.expectError(error.InvalidConfig, loadConfig(a, root, &diag));
    try std.testing.expect(std.mem.indexOf(u8, diag.msg(), "linux") != null);

    try writeAbsFile(a, root, ".devagents\\worktree.json", "{\"timeout_s\":3601}");
    try std.testing.expectError(error.InvalidConfig, loadConfig(a, root, &diag));

    try writeAbsFile(a, root, ".devagents\\worktree.json", "{\"timeout_s\":3600}");
    var cfg = (try loadConfig(a, root, &diag)).?;
    defer cfg.deinit();
    try std.testing.expectEqual(@as(u32, 3600), cfg.timeout_s);
}

test "E5.04 config: timeout por defecto es 600" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    try writeAbsFile(a, root, ".devagents\\worktree.json", "{\"copy\":[]}");
    var diag: Diag = .{};
    var cfg = (try loadConfig(a, root, &diag)).?;
    defer cfg.deinit();
    try std.testing.expectEqual(DEFAULT_TIMEOUT_S, cfg.timeout_s);
}

test "E5.04 config: ruta absoluta y '..' en copy/setup se rechazan" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    var diag: Diag = .{};

    try writeAbsFile(a, root, ".devagents\\worktree.json", "{\"copy\":[\"..\\\\secrets.txt\"]}");
    try std.testing.expectError(error.InvalidConfig, loadConfig(a, root, &diag));

    try writeAbsFile(a, root, ".devagents\\worktree.json", "{\"copy\":[\"C:\\\\Windows\\\\x.ini\"]}");
    try std.testing.expectError(error.InvalidConfig, loadConfig(a, root, &diag));

    try writeAbsFile(a, root, ".devagents\\worktree.json", "{\"setup\":{\"windows\":\"..\\\\setup.cmd\"}}");
    try std.testing.expectError(error.InvalidConfig, loadConfig(a, root, &diag));
}

test "E5.04 copy: copia lo que falta y omite existente/ausente" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const base = try joinAbsT(a, root, "base");
    defer a.free(base);
    const wtree = try joinAbsT(a, root, "wt");
    defer a.free(wtree);

    try writeAbsFile(a, base, ".env", "SECRET=1");
    try writeAbsFile(a, base, "sub\\a.txt", "AAA");
    try writeAbsFile(a, wtree, "sub\\a.txt", "YA");
    try writeAbsFile(a, base, ".devagents\\worktree.json", "{\"copy\":[\".env\",\"sub\\\\a.txt\",\"missing.txt\"]}");

    var conn = try testConn(a);
    defer conn.close();
    resetFakes();
    var diag: Diag = .{};
    var o = baseOptions(base, wtree, &diag);
    o.audit_fn = fakeAudit;
    try prepare(a, conn, o);

    // .env se copió; sub\a.txt ya existía → no se tocó; missing.txt → skip.
    const copied = try joinAbsT(a, wtree, ".env");
    defer a.free(copied);
    try std.testing.expect(existsAbs(copied));
    const prev = try joinAbsT(a, wtree, "sub\\a.txt");
    defer a.free(prev);
    const prev_data = try readAbsFile(a, prev);
    defer a.free(prev_data);
    try std.testing.expectEqualStrings("YA", prev_data);
    try std.testing.expectEqual(@as(usize, 1), fake_audit_count);
    try std.testing.expectEqualStrings(".env", fake_audit_last_name[0..fake_audit_last_name_len]);
    try std.testing.expectEqual(@as(i64, 1), countEvents(conn, "worktree_prepare_started"));
    try std.testing.expectEqual(@as(i64, 1), countEvents(conn, "worktree_prepared"));
    try std.testing.expectEqual(@as(i64, 0), countEvents(conn, "worktree_setup_failed"));
}

test "E5.04 copy: una unión en la cadena de origen se rechaza" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const base = try joinAbsT(a, root, "base");
    defer a.free(base);
    const wtree = try joinAbsT(a, root, "wt");
    defer a.free(wtree);
    mkDirAbs(wtree);

    const outside = try joinAbsT(a, root, "outside");
    defer a.free(outside);
    try writeAbsFile(a, outside, "secret.txt", "X");
    const link = try joinAbsT(a, base, "linkdir");
    defer a.free(link);
    mkDirAbs(base);
    try std.testing.expect(mkJunction(a, link, outside));

    try writeAbsFile(a, base, ".devagents\\worktree.json", "{\"copy\":[\"linkdir\\\\secret.txt\"]}");
    var conn = try testConn(a);
    defer conn.close();
    resetFakes();
    var diag: Diag = .{};
    const o = baseOptions(base, wtree, &diag);
    // La apertura confinada rechaza la unión antes de leer el origen.
    try std.testing.expectError(error.CopyPathEscape, prepare(a, conn, o));
    try std.testing.expectEqual(@as(i64, 1), countEvents(conn, "worktree_setup_failed"));
    try std.testing.expectEqual(@as(i64, 0), countEvents(conn, "worktree_prepared"));
    const dst = try joinAbsT(a, wtree, "linkdir\\secret.txt");
    defer a.free(dst);
    try std.testing.expect(!existsAbs(dst));
}

test "E5.04 copy: directorio y archivo >1 MiB se rechazan; >50 entradas también" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const base = try joinAbsT(a, root, "base");
    defer a.free(base);
    const wtree = try joinAbsT(a, root, "wt");
    defer a.free(wtree);
    mkDirAbs(wtree);

    // Directorio → CopyNotRegular.
    const srcdir = try joinAbsT(a, base, "srcdir");
    defer a.free(srcdir);
    mkDirAbs(srcdir);
    try writeAbsFile(a, base, ".devagents\\worktree.json", "{\"copy\":[\"srcdir\"]}");
    var conn = try testConn(a);
    defer conn.close();
    var diag: Diag = .{};
    const o = baseOptions(base, wtree, &diag);
    try std.testing.expectError(error.CopyNotRegular, prepare(a, conn, o));

    // >1 MiB → CopyTooLarge.
    const big = try a.alloc(u8, MAX_COPY_FILE_BYTES + 1);
    defer a.free(big);
    @memset(big, 'x');
    try writeAbsFile(a, base, "big.bin", big);
    try writeAbsFile(a, base, ".devagents\\worktree.json", "{\"copy\":[\"big.bin\"]}");
    try std.testing.expectError(error.CopyTooLarge, prepare(a, conn, o));

    // >50 entradas → CopyTooMany (en el parser).
    var cfg_buf = std.ArrayList(u8).empty;
    defer cfg_buf.deinit(a);
    try cfg_buf.appendSlice(a, "{\"copy\":[");
    var i: usize = 0;
    while (i < 51) : (i += 1) {
        if (i > 0) try cfg_buf.append(a, ',');
        const e = std.fmt.allocPrint(a, "\"f{d}.txt\"", .{i}) catch unreachable;
        defer a.free(e);
        try cfg_buf.appendSlice(a, e);
    }
    try cfg_buf.appendSlice(a, "]}");
    try writeAbsFile(a, base, ".devagents\\worktree.json", cfg_buf.items);
    try std.testing.expectError(error.CopyTooMany, prepare(a, conn, o));
}

test "SEC-FS worktree copy denies destination junction and source hard link" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const Api = struct {
        extern "kernel32" fn CreateHardLinkW([*:0]const u16, [*:0]const u16, ?*anyopaque) callconv(.winapi) c_int;
    };
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const base = try joinAbsT(a, root, "base");
    defer a.free(base);
    const wt = try joinAbsT(a, root, "wt");
    defer a.free(wt);
    const outside = try joinAbsT(a, root, "outside");
    defer a.free(outside);
    mkDirAbs(wt);
    try writeAbsFile(a, base, "sub\\new.txt", "inside");
    try writeAbsFile(a, outside, "marker.txt", "untouched");
    const junction = try joinAbsT(a, wt, "sub");
    defer a.free(junction);
    try std.testing.expect(mkJunction(a, junction, outside));
    var source_root = try confined_fs.Root.init(a, base);
    defer source_root.deinit();
    var destination_root = try confined_fs.Root.initMutation(a, wt);
    defer destination_root.deinit();
    var diag: Diag = .{};
    const o = baseOptions(base, wt, &diag);
    try std.testing.expectError(error.CopyPathEscape, copyOne(a, &source_root, &destination_root, o, "sub\\new.txt", &diag));
    const escaped = try joinAbsT(a, outside, "new.txt");
    defer a.free(escaped);
    try std.testing.expect(!existsAbs(escaped));

    const link = try joinAbsT(a, base, "link.txt");
    defer a.free(link);
    const marker = try joinAbsT(a, outside, "marker.txt");
    defer a.free(marker);
    const link_w = try std.unicode.utf8ToUtf16LeAllocZ(a, link);
    defer a.free(link_w);
    const marker_w = try std.unicode.utf8ToUtf16LeAllocZ(a, marker);
    defer a.free(marker_w);
    try std.testing.expect(Api.CreateHardLinkW(link_w, marker_w, null) != 0);
    try std.testing.expectError(error.CopyNotRegular, copyOne(a, &source_root, &destination_root, o, "link.txt", &diag));
    const copied = try joinAbsT(a, wt, "link.txt");
    defer a.free(copied);
    try std.testing.expect(!existsAbs(copied));
    const data = try readAbsFile(a, marker);
    defer a.free(data);
    try std.testing.expectEqualStrings("untouched", data);
    try std.testing.expectEqual(error.OutOfMemory, copyError(error.OutOfMemory, "file.txt", &diag));
}

test "SEC-FS worktree exclusive copy creates parents and preserves existing bytes" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const base = try joinAbsT(a, root, "base");
    defer a.free(base);
    const wt = try joinAbsT(a, root, "wt");
    defer a.free(wt);
    mkDirAbs(wt);
    try writeAbsFile(a, base, "nested\\new.txt", "first");
    var source_root = try confined_fs.Root.init(a, base);
    defer source_root.deinit();
    var destination_root = try confined_fs.Root.initMutation(a, wt);
    defer destination_root.deinit();
    var diag: Diag = .{};
    const o = baseOptions(base, wt, &diag);
    try std.testing.expectEqual(CopyOutcome.copied, try copyOne(a, &source_root, &destination_root, o, "nested\\new.txt", &diag));
    try writeAbsFile(a, base, "nested\\new.txt", "second");
    try std.testing.expectEqual(CopyOutcome.skipped_existing, try copyOne(a, &source_root, &destination_root, o, "nested\\new.txt", &diag));
    try std.testing.expectEqual(CopyOutcome.skipped_missing, try copyOne(a, &source_root, &destination_root, o, "absent.txt", &diag));
    const target = try joinAbsT(a, wt, "nested\\new.txt");
    defer a.free(target);
    const data = try readAbsFile(a, target);
    defer a.free(data);
    try std.testing.expectEqualStrings("first", data);
    const aliases: []const []const u8 = if (@import("builtin").os.tag == .windows) &.{ "nested\\..\\new.txt", "new.txt:stream", "NUL.txt" } else &.{ "nested/../new.txt", "../new.txt", "nested//new.txt" };
    for (aliases) |invalid| {
        try std.testing.expectError(error.CopyPathEscape, copyOne(a, &source_root, &destination_root, o, invalid, &diag));
    }
}

test "E5.04 copy: evidencia al sink lleva nombre y sha256, nunca contenido" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const base = try joinAbsT(a, root, "base");
    defer a.free(base);
    const wtree = try joinAbsT(a, root, "wt");
    defer a.free(wtree);
    mkDirAbs(wtree);

    try writeAbsFile(a, base, "ev.txt", "CONTENIDO-SECRETO");
    try writeAbsFile(a, base, ".devagents\\worktree.json", "{\"copy\":[\"ev.txt\"]}");
    var conn = try testConn(a);
    defer conn.close();
    resetFakes();
    var diag: Diag = .{};
    var o = baseOptions(base, wtree, &diag);
    o.audit_fn = fakeAudit;
    try prepare(a, conn, o);

    try std.testing.expectEqual(@as(usize, 1), fake_audit_count);
    try std.testing.expectEqualStrings("ev.txt", fake_audit_last_name[0..fake_audit_last_name_len]);
    var sha = std.crypto.hash.sha2.Sha256.init(.{});
    sha.update("CONTENIDO-SECRETO");
    var d: [32]u8 = undefined;
    sha.final(&d);
    const hex = std.fmt.bytesToHex(d, .lower);
    try std.testing.expectEqualStrings(&hex, &fake_audit_last_sha);
}

test "E5.04 setup: pendiente la primera vez; concedido corre con cmd fijado" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: lanza cmd.exe o un lote .cmd/.bat (Windows)");
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const base = try joinAbsT(a, root, "base");
    defer a.free(base);
    const wtree = try joinAbsT(a, root, "wt");
    defer a.free(wtree);

    try writeAbsFile(a, wtree, "setup.cmd", "@echo hi");
    try writeAbsFile(a, base, ".devagents\\worktree.json", "{\"setup\":{\"windows\":\"setup.cmd\"}}");

    var conn = try testConn(a);
    defer conn.close();
    resetFakes();
    var diag: Diag = .{};
    var o = baseOptions(base, wtree, &diag);
    o.run_fn = fakeRun;

    // Primera vez: sin concesión → fallo honesto + fila pendiente + NO corrió.
    try std.testing.expectError(error.SetupPendingApproval, prepare(a, conn, o));
    try std.testing.expectEqual(@as(usize, 0), fake_run.calls);
    try std.testing.expectEqual(@as(i64, 1), pendingApprovals(conn));
    try std.testing.expectEqual(@as(i64, 1), countEvents(conn, "worktree_setup_failed"));
    try std.testing.expect(diag.has_pending);

    // Concesión por el hash pendiente → corre el intérprete fijado.
    try approveScript(conn, "proj-test", diag.pendingSha256(), diag.pendingScript());
    try prepare(a, conn, o);
    try std.testing.expectEqual(@as(usize, 1), fake_run.calls);
    const exe = fake_run.exe[0..fake_run.exe_len];
    try std.testing.expect(std.mem.endsWith(u8, exe, "\\System32\\cmd.exe"));
    const flat = fake_run.args_flat[0..fake_run.args_len];
    try std.testing.expect(std.mem.indexOf(u8, flat, "/d /c ") != null);
    try std.testing.expectEqualStrings(wtree, fake_run.cwd[0..fake_run.cwd_len]);
    try std.testing.expectEqual(DEFAULT_TIMEOUT_S * 1000, fake_run.timeout_ms);
    try std.testing.expectEqual(@as(i64, 1), countEvents(conn, "worktree_prepared"));
}

test "E5.04 setup: cambiar el hash vuelve a pedir aprobación" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: lanza cmd.exe o un lote .cmd/.bat (Windows)");
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const base = try joinAbsT(a, root, "base");
    defer a.free(base);
    const wtree = try joinAbsT(a, root, "wt");
    defer a.free(wtree);

    try writeAbsFile(a, wtree, "setup.cmd", "@echo v1");
    try writeAbsFile(a, base, ".devagents\\worktree.json", "{\"setup\":{\"windows\":\"setup.cmd\"}}");
    var conn = try testConn(a);
    defer conn.close();
    resetFakes();
    var diag: Diag = .{};
    var o = baseOptions(base, wtree, &diag);
    o.run_fn = fakeRun;

    try std.testing.expectError(error.SetupPendingApproval, prepare(a, conn, o));
    try approveScript(conn, "proj-test", diag.pendingSha256(), diag.pendingScript());

    // El script cambia → el hash ya no está concedido → nueva petición.
    try writeAbsFile(a, wtree, "setup.cmd", "@echo v2-MODIFICADO");
    try std.testing.expectError(error.SetupPendingApproval, prepare(a, conn, o));
    try std.testing.expectEqual(@as(usize, 0), fake_run.calls);
    try std.testing.expectEqual(@as(i64, 2), pendingApprovals(conn));
}

test "E5.04 setup: exit != 0 y timeout fallan con código y cola acotada" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: lanza cmd.exe o un lote .cmd/.bat (Windows)");
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const base = try joinAbsT(a, root, "base");
    defer a.free(base);
    const wtree = try joinAbsT(a, root, "wt");
    defer a.free(wtree);

    try writeAbsFile(a, wtree, "setup.cmd", "@echo x");
    try writeAbsFile(a, base, ".devagents\\worktree.json", "{\"setup\":{\"windows\":\"setup.cmd\",\"posix\":\"setup.sh\"}}");
    var conn = try testConn(a);
    defer conn.close();
    resetFakes();
    fake_run.exit_code = 7;
    fake_run.timed_out = true;
    fake_run.stderr_text = "fallo-del-script";
    var diag: Diag = .{};
    var o = baseOptions(base, wtree, &diag);
    o.run_fn = fakeRun;

    // Pre-concedo el hash real del script para llegar a la ejecución.
    var sha: [64]u8 = undefined;
    const script_abs = try joinAbsT(a, wtree, "setup.cmd");
    defer a.free(script_abs);
    try std.testing.expect(sha256File(a, script_abs, &sha));
    try approveScript(conn, "proj-test", sha[0..], "setup.cmd");

    try std.testing.expectError(error.SetupFailed, prepare(a, conn, o));
    const payload = lastEventPayload(conn, a, "worktree_setup_failed").?;
    defer a.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"exit_code\":7") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "\"timed_out\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "fallo-del-script") != null);
    try std.testing.expectEqual(@as(i64, 0), countEvents(conn, "worktree_prepared"));
}

test "E5.04 setup: rechazo del ejecutor (política) es fallo honesto" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: lanza cmd.exe o un lote .cmd/.bat (Windows)");
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const base = try joinAbsT(a, root, "base");
    defer a.free(base);
    const wtree = try joinAbsT(a, root, "wt");
    defer a.free(wtree);

    try writeAbsFile(a, wtree, "setup.ps1", "Write-Host x");
    try writeAbsFile(a, base, ".devagents\\worktree.json", "{\"setup\":{\"windows\":\"setup.ps1\"}}");
    var conn = try testConn(a);
    defer conn.close();
    resetFakes();
    var diag: Diag = .{};
    var o = baseOptions(base, wtree, &diag);
    o.run_fn = fakeRun;

    try std.testing.expectError(error.SetupPendingApproval, prepare(a, conn, o));
    try approveScript(conn, "proj-test", diag.pendingSha256(), diag.pendingScript());
    fake_run.spawn_error = error.PathOutsideSandbox;
    try std.testing.expectError(error.SetupFailed, prepare(a, conn, o));
    const payload = lastEventPayload(conn, a, "worktree_setup_failed").?;
    defer a.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "executor_rejected") != null);
}

test "E5.04 sin archivo: worktree_setup_suggested por lockfiles, sin ejecutar" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const base = try joinAbsT(a, root, "base");
    defer a.free(base);
    const wtree = try joinAbsT(a, root, "wt");
    defer a.free(wtree);

    try writeAbsFile(a, base, "package-lock.json", "{}");
    try writeAbsFile(a, base, "Cargo.lock", "");
    var conn = try testConn(a);
    defer conn.close();
    resetFakes();
    var diag: Diag = .{};
    var o = baseOptions(base, wtree, &diag);
    o.run_fn = fakeRun;
    try prepare(a, conn, o);

    try std.testing.expectEqual(@as(usize, 0), fake_run.calls);
    try std.testing.expectEqual(@as(i64, 1), countEvents(conn, "worktree_setup_suggested"));
    try std.testing.expectEqual(@as(i64, 0), countEvents(conn, "worktree_prepared"));
    const payload = lastEventPayload(conn, a, "worktree_setup_suggested").?;
    defer a.free(payload);
    try std.testing.expect(std.mem.indexOf(u8, payload, "npm ci") != null);
    try std.testing.expect(std.mem.indexOf(u8, payload, "cargo fetch") != null);
}

test "E5.04 setup: timeout_s configura el límite del ejecutor" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: lanza cmd.exe o un lote .cmd/.bat (Windows)");
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const base = try joinAbsT(a, root, "base");
    defer a.free(base);
    const wtree = try joinAbsT(a, root, "wt");
    defer a.free(wtree);

    try writeAbsFile(a, wtree, "setup.cmd", "@echo x");
    try writeAbsFile(a, base, ".devagents\\worktree.json", "{\"setup\":{\"windows\":\"setup.cmd\"},\"timeout_s\":30}");
    var conn = try testConn(a);
    defer conn.close();
    resetFakes();
    var diag: Diag = .{};
    var o = baseOptions(base, wtree, &diag);
    o.run_fn = fakeRun;

    try std.testing.expectError(error.SetupPendingApproval, prepare(a, conn, o));
    try approveScript(conn, "proj-test", diag.pendingSha256(), diag.pendingScript());
    try prepare(a, conn, o);
    try std.testing.expectEqual(@as(u32, 30_000), fake_run.timeout_ms);
}

test "E5.05 inspectConfig: válido resume copias/setup/timeout; inválido da el detalle" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const base = try joinAbsT(a, root, "base");
    defer a.free(base);

    // Válido.
    try writeAbsFile(a, base, ".devagents\\worktree.json", "{\"copy\":[\".env\",\"conf\\\\a.json\"],\"setup\":{\"windows\":\"setup.cmd\",\"posix\":\"setup.sh\"},\"timeout_s\":45}");
    var st = inspectConfig(a, base);
    defer st.deinit();
    try std.testing.expect(st.exists and st.valid);
    try std.testing.expectEqual(@as(usize, 2), st.copy.len);
    try std.testing.expectEqualStrings(".env", st.copy[0]);
    try std.testing.expectEqualStrings("setup.cmd", st.setup_windows.?);
    try std.testing.expectEqualStrings("setup.sh", st.setup_posix.?);
    try std.testing.expectEqual(@as(u32, 45), st.timeout_s);
    try std.testing.expectEqual(@as(usize, 0), st.lockfiles.len);

    // Inválido: clave desconocida → exists sin valid, con el detalle.
    try writeAbsFile(a, base, ".devagents\\worktree.json", "{\"copy\":[],\"nope\":1}");
    var st2 = inspectConfig(a, base);
    defer st2.deinit();
    try std.testing.expect(st2.exists and !st2.valid);
    try std.testing.expect(std.mem.indexOf(u8, st2.detail, "nope") != null);
}

test "E5.05 inspectConfig: sin archivo devuelve las sugerencias por lockfiles" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const base = try joinAbsT(a, root, "base");
    defer a.free(base);
    mkDirAbs(base);

    try writeAbsFile(a, base, "package-lock.json", "{}");
    var st = inspectConfig(a, base);
    defer st.deinit();
    try std.testing.expect(!st.exists and !st.valid);
    try std.testing.expectEqual(@as(usize, 1), st.lockfiles.len);
    try std.testing.expectEqualStrings("package-lock.json", st.lockfiles[0]);
    try std.testing.expectEqualStrings("npm ci", st.commands[0]);
}
