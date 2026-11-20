const std = @import("std");
const db = @import("db.zig");
const health = @import("health.zig");
const executor = @import("executor.zig");
const worktree_prepare = @import("worktree_prepare.zig");
const headless_adapter = @import("headless_adapter.zig");
const sandbox = @import("sandbox.zig");
const workspace = @import("workspace.zig");
const confined_fs = @import("confined_fs.zig");

const windows = std.os.windows;

const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) callconv(.c) c_int;
}.CloseHandle else @import("providers").posix_files.CloseHandle;
extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: u32) callconv(.c) u32;
extern "kernel32" fn GetExitCodeProcess(hProcess: windows.HANDLE, lpExitCode: *u32) callconv(.c) c_int;

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

/// Sin esta bandera `git worktree add` abre una consola visible por llamada —
/// el motor es un proceso de fondo y jamás debe robar el foco al usuario.
const CREATE_NO_WINDOW: u32 = 0x08000000;

pub const SpaceKind = enum {
    order,
    main_checkout,

    pub fn toString(self: SpaceKind) []const u8 {
        return switch (self) {
            .order => "order",
            .main_checkout => "main-checkout",
        };
    }

    pub fn parse(str: []const u8) !SpaceKind {
        if (std.mem.eql(u8, str, "order")) return .order;
        if (std.mem.eql(u8, str, "main-checkout")) return .main_checkout;
        return error.InvalidKind;
    }
};

pub const SpaceInfo = struct {
    id: i64,
    project_id: []const u8,
    kind: SpaceKind,
    name: []const u8,
    worktree_path: []const u8,
    branch: []const u8,
    created_at: i64,
    archived_at: ?i64 = null,
    is_non_git_degraded: bool = false,

    pub fn deinit(self: *SpaceInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.project_id);
        allocator.free(self.name);
        allocator.free(self.worktree_path);
        allocator.free(self.branch);
    }
};

/// Lanza un comando y devuelve su código de salida.
///
/// Los argumentos se escapan con `executor.appendArg`, que aplica las reglas de
/// comillas de Windows. Antes se unían con un espacio y nada más, y eso rompía
/// en cuanto una ruta llevaba un espacio — que es el caso de casi cualquier
/// proyecto bajo `C:\Workspace\Proyecto - Nombre\`: `git worktree add` recibía
/// la ruta partida en varios argumentos y contestaba con su mensaje de uso.
/// Como el código de salida se descartaba, el space se registraba igualmente
/// apuntando a un directorio que nunca llegó a existir.
///
/// el stderr del hijo se REDIRIGE a NUL. Este helper existe para el modo
/// degradado — llamar a git donde NO hay repo es el caso normal, no el error —
/// y `git rev-parse` respondía con ocho «fatal: not a git repository» por
/// corrida de suite, heredando el stderr del runner. El runner de Zig adjudica
/// ese stderr al test que esté corriendo, y era la segunda fuente de ruido que
/// hacía fallar la suite al azar.
fn runCmdWin32(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) u32 {
    if (@import("builtin").os.tag != .windows) return runCmdPosix(allocator, argv, cwd);
    var cmd_line = std.ArrayList(u8).empty;
    defer cmd_line.deinit(allocator);
    // `-c core.fsmonitor=false`: con fsmonitor activo en el repo, cada orden
    // git dentro de un worktree deja un `fsmonitor--daemon` huérfano vivo para
    // siempre (medido: ~45 acumulados, uno por espacio de orden) y su handle
    // abierto bloquea `worktree remove` en Windows.
    const fs_off = argv.len > 0 and std.mem.eql(u8, argv[0], "git");

    for (argv, 0..) |arg, i| {
        if (i > 0) cmd_line.append(allocator, ' ') catch return 1;
        executor.appendArg(&cmd_line, allocator, arg) catch return 1;
        if (i == 0 and fs_off)
            cmd_line.appendSlice(allocator, " -c core.fsmonitor=false") catch return 1;
    }

    const cmd_line_z = allocator.dupeZ(u8, cmd_line.items) catch return 1;
    defer allocator.free(cmd_line_z);

    const cwd_z = if (cwd) |c| allocator.dupeZ(u8, c) catch null else null;
    defer if (cwd_z) |c| allocator.free(c);

    var si: STARTUPINFOA = .{ .cb = @sizeOf(STARTUPINFOA) };
    // STARTF_USESTDHANDLES + handles a NUL: el hijo no hereda la consola del
    // proceso de tests. hStdOutput también: `git worktree add` imprime su
    // progreso por ahí y aquí no se lee nada de ninguna de las dos.
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdInput = nulHandle();
    si.hStdOutput = nulHandle();
    si.hStdError = nulHandle();
    var pi: PROCESS_INFORMATION = undefined;

    const ok = CreateProcessA(
        null,
        cmd_line_z.ptr,
        null,
        null, // bInheritHandles: los handles a NUL no se crean heredables
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

const STARTF_USESTDHANDLES: u32 = 0x00000100;

// Constantes Win32 con sufijo _T (mismo patrón que executor.zig) para no
// colisionar con las que la std exporta con otros nombres.
const GENERIC_READ_T: u32 = 0x80000000;
const GENERIC_WRITE_T: u32 = 0x40000000;
const FILE_SHARE_READ_T: u32 = 0x00000001;
const FILE_SHARE_WRITE_T: u32 = 0x00000002;
const OPEN_EXISTING_T: u32 = 3;

/// Handle de lectura/escritura al dispositivo NUL, no heredable. Se abre cada
/// llamada (y se cierra con el proceso, que es corto) en vez de cachearlo en
/// estado global: un handle huérfano en un test que corre en paralelo es
/// exactamente la familia de fallos que este archivo ya cazó una vez.
fn nulHandle() windows.HANDLE {
    // NUL es un dispositivo: CreateFileA es la vía directa de Win32 y no pasa
    // por el Io de la std. Sin FILE_FLAG... el handle NO es heredable, que es
    // justo lo que se quiere con bInheritHandles=0.
    const h = CreateFileA(
        "NUL",
        GENERIC_READ_T | GENERIC_WRITE_T,
        FILE_SHARE_READ_T | FILE_SHARE_WRITE_T,
        null,
        OPEN_EXISTING_T,
        0,
        null,
    );
    return h;
}

const CreateFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateFileA(
        lpFileName: [*:0]const u8,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?*anyopaque,
    ) callconv(.c) windows.HANDLE;
}.CreateFileA else @import("providers").posix_files.CreateFileA;

/// Crea un nuevo space en la base de datos y prepara su directorio/worktree.
/// B3: true si `dir` está dentro de un repositorio git real (`git rev-parse`).
/// Es la misma comprobación que hace createSpace antes de intentar el
/// worktree — expuesta para que el dispatcher decida si una orden merece space.
pub fn isGitRepo(allocator: std.mem.Allocator, dir: []const u8) bool {
    const repo = repoForSpace(allocator, dir) catch return false;
    if (repo) |r| {
        allocator.free(r);
        return true;
    }
    return false;
}

// S2: <proyecto>/devagents-workspace usa el repo del proyecto ELEGIDO.
// Una subcarpeta elegida dentro de un repo no autoriza modificar el repo padre.
fn repoForSpace(a: std.mem.Allocator, base: []const u8) !?[]const u8 {
    const checked_base = try canonicalNewPath(a, base);
    defer a.free(checked_base);
    const selected = if (std.ascii.eqlIgnoreCase(std.fs.path.basename(base), workspace.WORKSPACE_ROOT))
        std.fs.path.dirname(base) orelse base
    else
        base;
    const canonical_selected = confined_fs.strictRoot(a, selected) catch |e| switch (e) {
        error.FileNotFound => return error.SpaceRootUnavailable,
        else => return e,
    };
    defer a.free(canonical_selected);
    // El segmento S2 puede no existir todavía: git se consulta desde la
    // carpeta elegida, sin tener que crear directorios para una sonda.
    const canonical_base = confined_fs.strictRoot(a, base) catch |e| switch (e) {
        error.FileNotFound => null,
        else => return e,
    };
    defer if (canonical_base) |p| a.free(p);
    var cap = try headless_adapter.defaultCapture(a, &.{ "git", "rev-parse", "--show-toplevel" }, if (canonical_base != null) base else selected);
    defer cap.deinit(a);
    if (cap.exit_code != 0) return null;
    const top = std.mem.trim(u8, cap.stdout, " \t\r\n");
    const canonical_top = sandbox.canonicalizeExisting(a, top) orelse return error.SpaceRootUnavailable;
    errdefer a.free(canonical_top);
    if (canonical_base) |p| {
        if (std.ascii.eqlIgnoreCase(canonical_top, p)) return canonical_top;
    }
    if (!std.ascii.eqlIgnoreCase(canonical_top, canonical_selected)) return error.ForeignRepository;
    return canonical_top;
}

/// (a), 10-nov: lo que DevAgents deja en el proyecto del usuario ya
/// no dice «devagents». Los spaces nuevos viven en `.devagents\spaces\<nombre>`
/// con la rama `devagents/<nombre>`; los creados antes (`.beats\spaces` y
/// `beats/<nombre>`) siguen siendo válidos para listar, archivar y podar.
pub const INTERNAL_DIR = ".devagents";
pub const LEGACY_INTERNAL_DIR = ".beats";
pub const BRANCH_PREFIX = "devagents/";
pub const LEGACY_BRANCH_PREFIX = "beats/";
/// T9 fase B: separador del sistema (`\\` en Windows, `/` en POSIX).
const SEP = std.fs.path.sep_str;
const SPACES_SUBDIR = INTERNAL_DIR ++ SEP ++ "spaces";
const LEGACY_SPACES_SUBDIR = LEGACY_INTERNAL_DIR ++ SEP ++ "spaces";

/// Carpeta del proyecto a la que pertenece el worktree de un space
/// (`<base>\.devagents\spaces\<nombre>`, o el heredado `.beats`). Null si la
/// ruta no tiene esa forma. Solo recorta texto: quien la use para escribir la
/// valida después (archiveSpace → validateStoredSpace).
pub fn baseOfWorktree(worktree_path: []const u8) ?[]const u8 {
    const name_at = std.mem.lastIndexOfAny(u8, worktree_path, "\\/") orelse return null;
    if (name_at + 1 >= worktree_path.len) return null;
    const parent = worktree_path[0..name_at];
    for ([_][]const u8{ SPACES_SUBDIR, LEGACY_SPACES_SUBDIR }) |sub| {
        if (parent.len <= sub.len + 1 or !std.ascii.endsWithIgnoreCase(parent, sub)) continue;
        const sep = parent[parent.len - sub.len - 1];
        if (sep == '\\' or sep == '/') return parent[0 .. parent.len - sub.len - 1];
    }
    return null;
}
/// La carpeta de spaces se ignora a sí misma: sin esto los worktrees
/// aparecían como «sin seguimiento» en el `git status` del usuario.
const SPACES_GITIGNORE = "# Creado por DevAgents: worktrees de las ordenes, no forman parte del proyecto.\n*\n";

// Un componente ASCII compartido por el directorio y la rama devagents/<name>.
// Sin puntos, controles, ADS, separadores, dispositivos DOS ni flags de git.
fn validateSpaceName(name: []const u8) !void {
    if (name.len == 0 or name.len > 64 or !std.ascii.isAlphanumeric(name[0])) return error.InvalidSpaceName;
    for (name) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return error.InvalidSpaceName;
    }
    for ([_][]const u8{ "CON", "PRN", "AUX", "NUL" }) |reserved| {
        if (std.ascii.eqlIgnoreCase(name, reserved)) return error.InvalidSpaceName;
    }
    if (name.len == 4 and name[3] >= '1' and name[3] <= '9' and
        (std.ascii.eqlIgnoreCase(name[0..3], "COM") or std.ascii.eqlIgnoreCase(name[0..3], "LPT"))) return error.InvalidSpaceName;
}

// Antes de crear una ruta inexistente se valida el ancestro existente más
// cercano. strictRoot rechaza cada reparse point y todo cambio canónico de
// identidad; el resto son únicamente componentes léxicos aún inexistentes.
fn canonicalNewPath(a: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!std.fs.path.isAbsolute(path)) return error.SpaceRootUnavailable;
    return confined_fs.strictNewPath(a, path);
}

// La creación retiene la cadena sin WRITE/DELETE sharing hasta terminar Git.
fn lockSpaceParents(a: std.mem.Allocator, base: []const u8) !confined_fs.Root {
    const parent = try std.fmt.allocPrint(a, "{s}" ++ SEP ++ SPACES_SUBDIR, .{base});
    defer a.free(parent);
    var root = try confined_fs.createRoot(a, parent);
    errdefer root.deinit();
    ensureSpacesIgnored(a, &root);
    return root;
}

/// Escribe el `.gitignore` de la carpeta de spaces si falta. Es cortesía con el
/// `git status` del usuario: si no se puede escribir, la creación sigue.
fn ensureSpacesIgnored(a: std.mem.Allocator, root: *const confined_fs.Root) void {
    const existing = root.readFileAlloc(a, ".gitignore", 4096) catch |e| switch (e) {
        error.FileNotFound => {
            root.writeFile(".gitignore", SPACES_GITIGNORE) catch {};
            return;
        },
        else => return,
    };
    a.free(existing);
}

fn verifyCreatedSpace(a: std.mem.Allocator, base: []const u8, path: []const u8) !confined_fs.Root {
    var root = try confined_fs.Root.init(a, path);
    errdefer root.deinit();
    // Root.init comprobó atributos y ruta final del MISMO handle del worktree.
    const contained = try checkedSpacePath(a, base, root.canonical);
    defer a.free(contained);
    return root;
}

fn removeRejectedWorktree(a: std.mem.Allocator, repo: []const u8, path: []const u8, branch: []const u8) !void {
    var remove = try headless_adapter.defaultCapture(a, &.{ "git", "-c", "core.fsmonitor=false", "worktree", "remove", "--force", path }, repo);
    defer remove.deinit(a);
    if (remove.exit_code != 0) return error.WorktreeCleanupFailed;
    // Sólo se llama después de worktree add -b EXIT=0: esta llamada creó la rama.
    var drop = try headless_adapter.defaultCapture(a, &.{ "git", "branch", "-D", branch }, repo);
    defer drop.deinit(a);
    if (drop.exit_code != 0) return error.WorktreeCleanupFailed;
}

fn checkedSpacePath(a: std.mem.Allocator, base: []const u8, path: []const u8) ![]u8 {
    const canonical_base = try canonicalNewPath(a, base);
    defer a.free(canonical_base);
    const canonical_path = try canonicalNewPath(a, path);
    errdefer a.free(canonical_path);
    // Compara también el separador: C:\base-extra nunca pertenece a C:\base.
    if (canonical_path.len <= canonical_base.len or
        !@import("platform.zig").pathEqual(canonical_path[0..canonical_base.len], canonical_base) or
        canonical_path[canonical_base.len] != std.fs.path.sep) return error.SpacePathOutsideBase;
    return canonical_path;
}

fn validateStoredSpace(a: std.mem.Allocator, base: []const u8, name: []const u8, path: []const u8, branch: []const u8) !void {
    try validateSpaceName(name);
    const checked = try checkedSpacePath(a, base, path);
    defer a.free(checked);
    // Ruta y rama van en pareja: la de hoy o la heredada de DevAgents, nunca mezcladas.
    const legacy = std.mem.startsWith(u8, branch, LEGACY_BRANCH_PREFIX);
    const expected_path = try std.fmt.allocPrint(a, "{s}" ++ SEP ++ "{s}" ++ SEP ++ "{s}", .{ base, if (legacy) LEGACY_SPACES_SUBDIR else SPACES_SUBDIR, name });
    defer a.free(expected_path);
    const expected = try canonicalNewPath(a, expected_path);
    defer a.free(expected);
    if (!std.ascii.eqlIgnoreCase(checked, expected)) return error.SpacePathOutsideBase;
    const expected_branch = try std.fmt.allocPrint(a, "{s}{s}", .{ if (legacy) LEGACY_BRANCH_PREFIX else BRANCH_PREFIX, name });
    defer a.free(expected_branch);
    if (!std.mem.eql(u8, branch, expected_branch)) return error.InvalidSpaceBranch;
}

fn spaceDiag(diag: ?*worktree_prepare.Diag, comptime fmt: []const u8, args: anytype) void {
    if (diag) |d| {
        const s = std.fmt.bufPrint(&d.buf, fmt, args) catch {
            d.len = d.buf.len;
            return;
        };
        d.len = s.len;
    }
}

/// Opciones de preparación E5.04 (D-C4/): `.devagents/worktree.json`
/// se lee SIEMPRE que exista — también para spaces manuales (order_id = 0).
pub const CreateOptions = struct {
    /// Orden propietaria del space (0 = space manual de da_space_create).
    order_id: i64 = 0,
    /// Diagnóstico del fallo de preparación — la causa real para last_error.
    diag: ?*worktree_prepare.Diag = null,
    /// Seams de test: lanzador del setup y sumidero de evidencia de copia.
    run_fn: ?worktree_prepare.SetupRunFn = null,
    audit_fn: ?worktree_prepare.AuditCopyFn = null,
    audit_ctx: ?*anyopaque = null,
    /// Costura determinista de carrera; se ejecuta justo antes de Git.
    before_git_fn: ?*const fn (std.mem.Allocator, []const u8, ?*anyopaque) anyerror!void = null,
    before_git_ctx: ?*anyopaque = null,
    /// Costura de rechazo/carrera tras Git, antes de validar el handle final.
    after_git_fn: ?*const fn (std.mem.Allocator, []const u8, ?*anyopaque) anyerror!void = null,
    after_git_ctx: ?*anyopaque = null,
};

pub fn createSpace(
    allocator: std.mem.Allocator,
    conn: db.Connection,
    project_id: []const u8,
    name: []const u8,
    kind: SpaceKind,
    base_dir: []const u8,
    opts: CreateOptions,
) !SpaceInfo {
    validateSpaceName(name) catch |e| {
        spaceDiag(opts.diag, "nombre de espacio inseguro: {s}", .{@errorName(e)});
        return e;
    };
    const now = health.nowSeconds(conn);
    const repo = repoForSpace(allocator, base_dir) catch |e| {
        spaceDiag(opts.diag, "space: {s}; no se permiten junctions ni un repositorio por encima de la carpeta elegida", .{@errorName(e)});
        return e;
    };
    defer if (repo) |r| allocator.free(r);
    // Los padres permanecen protegidos durante la selección y creación.
    var path_lock = lockSpaceParents(allocator, base_dir) catch |e| {
        spaceDiag(opts.diag, "ruta de espacio rechazada antes de crear: {s}; no se permiten reparse points/junctions ni escapes", .{@errorName(e)});
        return e;
    };
    defer path_lock.deinit();
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const selected = for (1..21) |i| {
        const candidate = if (i == 1) try allocator.dupe(u8, name) else try std.fmt.allocPrint(allocator, "{s}-{d}", .{ name, i });
        defer allocator.free(candidate);
        validateSpaceName(candidate) catch |e| {
            spaceDiag(opts.diag, "nombre de espacio inseguro: {s}", .{@errorName(e)});
            return e;
        };
        const branch = try std.fmt.allocPrint(allocator, BRANCH_PREFIX ++ "{s}", .{candidate});
        defer allocator.free(branch);
        const path = try std.fmt.allocPrint(allocator, "{s}" ++ SEP ++ SPACES_SUBDIR ++ SEP ++ "{s}", .{ base_dir, candidate });
        defer allocator.free(path);
        if (repo) |r| {
            const ref = try std.fmt.allocPrint(allocator, "refs/heads/{s}", .{branch});
            defer allocator.free(ref);
            var cap = headless_adapter.defaultCapture(allocator, &.{ "git", "rev-parse", "--verify", "--quiet", ref }, r) catch |e| {
                spaceDiag(opts.diag, "git rev-parse: {s}", .{@errorName(e)});
                return error.WorktreeCreateFailed;
            };
            defer cap.deinit(allocator);
            if (cap.exit_code == 0) continue;
            if (cap.exit_code != 1) {
                spaceDiag(opts.diag, "git rev-parse exit={d}: {s}", .{ cap.exit_code, std.mem.trim(u8, cap.stderr, " \r\n") });
                return error.WorktreeCreateFailed;
            }
        }
        if (std.Io.Dir.cwd().access(threaded.io(), path, .{})) |_| {
            continue;
        } else |e| switch (e) {
            error.FileNotFound => {},
            else => return e,
        }
        break try allocator.dupe(u8, candidate);
    } else {
        spaceDiag(opts.diag, "no hay nombre libre entre las 20 opciones para {s}", .{name});
        return error.WorktreeCreateFailed;
    };
    defer allocator.free(selected);
    const branch_name = try std.fmt.allocPrint(allocator, BRANCH_PREFIX ++ "{s}", .{selected});
    defer allocator.free(branch_name);
    const space_dir = try std.fmt.allocPrint(allocator, "{s}" ++ SEP ++ SPACES_SUBDIR ++ SEP ++ "{s}", .{ base_dir, selected });
    errdefer allocator.free(space_dir);
    const checked = checkedSpacePath(allocator, base_dir, space_dir) catch |e| {
        spaceDiag(opts.diag, "ruta de espacio rechazada antes de crear: {s}; no se permiten reparse points/junctions ni escapes", .{@errorName(e)});
        return e;
    };
    defer allocator.free(checked);

    var is_non_git: bool = false;

    if (opts.before_git_fn) |hook| {
        hook(allocator, base_dir, opts.before_git_ctx) catch |e| {
            spaceDiag(opts.diag, "creación de espacio interrumpida antes de Git: {s}", .{@errorName(e)});
            return e;
        };
    }
    if (repo) |r| {
        var cap = headless_adapter.defaultCapture(allocator, &.{ "git", "-c", "core.fsmonitor=false", "worktree", "add", "-b", branch_name, space_dir }, r) catch |e| {
            spaceDiag(opts.diag, "git worktree add: {s}", .{@errorName(e)});
            return error.WorktreeCreateFailed;
        };
        defer cap.deinit(allocator);
        if (cap.exit_code != 0) {
            spaceDiag(opts.diag, "git worktree add exit={d} branch={s}: {s}", .{ cap.exit_code, branch_name, std.mem.trim(u8, cap.stderr, " \r\n") });
            return error.WorktreeCreateFailed;
        }
    } else {
        // Sólo la ausencia real de repo permite aislamiento por directorio.
        is_non_git = true;
        path_lock.createDirPath(selected) catch |e| {
            spaceDiag(opts.diag, "no se pudo crear el directorio del espacio: {s}", .{@errorName(e)});
            return e;
        };
    }

    const verification: anyerror!confined_fs.Root = blk: {
        if (opts.after_git_fn) |hook| hook(allocator, space_dir, opts.after_git_ctx) catch |e| break :blk e;
        break :blk verifyCreatedSpace(allocator, base_dir, space_dir);
    };
    var worktree_lock: ?confined_fs.Root = verification catch |e| {
        if (repo) |r| {
            removeRejectedWorktree(allocator, r, space_dir, branch_name) catch |cleanup| {
                spaceDiag(opts.diag, "worktree rechazado por {s}; retirada falló: {s}", .{ @errorName(e), @errorName(cleanup) });
                return cleanup;
            };
        }
        spaceDiag(opts.diag, "worktree rechazado tras crear: {s}; ruta final por handle fuera de S2 o reparse point", .{@errorName(e)});
        return e;
    };
    defer if (worktree_lock) |*lock| lock.deinit();

    // E5.04/ (D-C4): preparación del worktree — `.devagents/worktree.json`
    // manda copias + setup gobernado. Un fallo NO degrada: el space no se
    // registra y la orden cae con la causa real (isPrepError lo distingue).
    // Si git creó el worktree se retira best-effort para no dejar basura que
    // bloquee el próximo `worktree add`; la rama devagents/<name> queda viva.
    worktree_prepare.prepare(allocator, conn, .{
        .project_id = project_id,
        .base_dir = base_dir,
        .worktree_dir = space_dir,
        .space_name = selected,
        .order_id = opts.order_id,
        .is_non_git = is_non_git,
        .run_fn = opts.run_fn,
        .audit_fn = opts.audit_fn,
        .audit_ctx = opts.audit_ctx,
        .diag = opts.diag,
    }) catch |e| {
        // Git necesita borrar el worktree: soltar sólo su handle, no los padres.
        if (worktree_lock) |*lock| lock.deinit();
        worktree_lock = null;
        if (!is_non_git)
            _ = runCmdWin32(allocator, &.{ "git", "worktree", "remove", "--force", space_dir }, base_dir);
        return e;
    };

    // Insertar registro en DB
    const sql =
        \\INSERT INTO spaces (project_id, kind, name, worktree_path, branch, created_at)
        \\VALUES (?, ?, ?, ?, ?, ?)
    ;
    const stmt = try conn.prepare(sql);
    defer conn.finalize(stmt);

    try db.bindText(stmt, 1, project_id);
    try db.bindText(stmt, 2, kind.toString());
    try db.bindText(stmt, 3, selected);
    try db.bindText(stmt, 4, space_dir);
    try db.bindText(stmt, 5, branch_name);
    try db.bindInt(stmt, 6, now);

    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
    const new_id = db.c.sqlite3_last_insert_rowid(conn.db);

    return SpaceInfo{
        .id = new_id,
        .project_id = try allocator.dupe(u8, project_id),
        .kind = kind,
        .name = try allocator.dupe(u8, selected),
        .worktree_path = space_dir,
        .branch = try allocator.dupe(u8, branch_name),
        .created_at = now,
        .is_non_git_degraded = is_non_git,
    };
}

/// Lista los spaces activos de un proyecto desde la base de datos.
pub fn listSpaces(
    allocator: std.mem.Allocator,
    conn: db.Connection,
    project_id: []const u8,
) ![]SpaceInfo {
    const sql =
        \\SELECT id, project_id, kind, name, worktree_path, branch, created_at, archived_at
        \\FROM spaces
        \\WHERE project_id = ? AND archived_at IS NULL
        \\ORDER BY id ASC
    ;
    const stmt = try conn.prepare(sql);
    defer conn.finalize(stmt);

    try db.bindText(stmt, 1, project_id);

    var list = std.ArrayList(SpaceInfo).empty;
    errdefer {
        for (list.items) |*item| item.deinit(allocator);
        list.deinit(allocator);
    }

    while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
        const id = db.c.sqlite3_column_int64(stmt, 0);
        const p_id = std.mem.span(db.c.sqlite3_column_text(stmt, 1));
        const kind_str = std.mem.span(db.c.sqlite3_column_text(stmt, 2));
        const name = std.mem.span(db.c.sqlite3_column_text(stmt, 3));
        const wt_path = std.mem.span(db.c.sqlite3_column_text(stmt, 4));
        const branch = std.mem.span(db.c.sqlite3_column_text(stmt, 5));
        const created_at = db.c.sqlite3_column_int64(stmt, 6);
        const archived_at: ?i64 = if (db.c.sqlite3_column_type(stmt, 7) == db.c.SQLITE_NULL) null else db.c.sqlite3_column_int64(stmt, 7);

        const kind = SpaceKind.parse(kind_str) catch .order;

        try list.append(allocator, SpaceInfo{
            .id = id,
            .project_id = try allocator.dupe(u8, p_id),
            .kind = kind,
            .name = try allocator.dupe(u8, name),
            .worktree_path = try allocator.dupe(u8, wt_path),
            .branch = try allocator.dupe(u8, branch),
            .created_at = created_at,
            .archived_at = archived_at,
        });
    }

    return list.toOwnedSlice(allocator);
}

/// Archiva un space marcándolo en la BD y limpiando su worktree/directorio.
pub fn archiveSpace(
    allocator: std.mem.Allocator,
    conn: db.Connection,
    space_id: i64,
    base_dir: []const u8,
) !void {
    const now = health.nowSeconds(conn);
    const repo = try repoForSpace(allocator, base_dir);
    defer if (repo) |r| allocator.free(r);

    // Obtener ruta del worktree
    const select_sql = "SELECT worktree_path, branch, name FROM spaces WHERE id = ?";
    const select_stmt = try conn.prepare(select_sql);
    defer conn.finalize(select_stmt);
    try db.bindInt(select_stmt, 1, space_id);

    const selected_step = db.c.sqlite3_step(select_stmt);
    if (selected_step != db.c.SQLITE_ROW and selected_step != db.c.SQLITE_DONE) return error.StepFailed;
    if (selected_step == db.c.SQLITE_ROW) {
        const wt_path = std.mem.span(db.c.sqlite3_column_text(select_stmt, 0));
        const branch = std.mem.span(db.c.sqlite3_column_text(select_stmt, 1));
        const name = std.mem.span(db.c.sqlite3_column_text(select_stmt, 2));
        try validateStoredSpace(allocator, base_dir, name, wt_path, branch);

        // Remover git worktree
        if (repo) |r| {
            if (runCmdWin32(allocator, &.{ "git", "worktree", "remove", "--force", wt_path }, r) != 0)
                return error.WorktreeRemoveFailed;
        }
    }

    // Actualizar archived_at
    const sql = "UPDATE spaces SET archived_at = ? WHERE id = ?";
    const stmt = try conn.prepare(sql);
    defer conn.finalize(stmt);
    try db.bindInt(stmt, 1, now);
    try db.bindInt(stmt, 2, space_id);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
}

/// (tanda 1; decisión del propietario del 12-nov): una subtarea
/// integrada no deja su rama en el repositorio del usuario, como las ramas de
/// los subagentes de las otras IDE. Se llama DESPUÉS de `archiveSpace` y solo
/// para lo integrado: se usa `-D` porque su trabajo ya está en la madre aunque
/// la rama tenga commits propios. Una subtarea no integrada conserva su rama.
pub fn deleteSpaceBranch(
    allocator: std.mem.Allocator,
    conn: db.Connection,
    space_id: i64,
    base_dir: []const u8,
) !void {
    const repo = try repoForSpace(allocator, base_dir) orelse return;
    defer allocator.free(repo);
    const stmt = try conn.prepare("SELECT worktree_path, branch, name FROM spaces WHERE id = ?");
    defer conn.finalize(stmt);
    try db.bindInt(stmt, 1, space_id);
    const step = db.c.sqlite3_step(stmt);
    if (step == db.c.SQLITE_DONE) return error.SpaceNotFound;
    if (step != db.c.SQLITE_ROW) return error.StepFailed;
    const wt_path = std.mem.span(db.c.sqlite3_column_text(stmt, 0));
    const branch = std.mem.span(db.c.sqlite3_column_text(stmt, 1));
    const name = std.mem.span(db.c.sqlite3_column_text(stmt, 2));
    try validateStoredSpace(allocator, base_dir, name, wt_path, branch);
    if (runCmdWin32(allocator, &.{ "git", "branch", "-D", branch }, repo) != 0)
        return error.BranchDeleteFailed;
}

/// Limpieza en disco de UN space podado: retira el worktree si sigue (la
/// archivacion normal ya lo hizo; una fila archivada por otra via puede
/// conservarlo), poda la metadata huerfana y borra la rama no fusionada.
/// No toca la fila: la poda normal primero valida todos y despues escribe.
fn pruneSpaceFiles(
    allocator: std.mem.Allocator,
    repo: ?[]const u8,
    worktree_path: []const u8,
    branch: []const u8,
) !void {
    if (repo) |r| {
        // Best-effort: si el worktree ya no existe, git sale con error y no
        // hay nada que retirar. `worktree prune` limpia la metadata.
        _ = runCmdWin32(allocator, &.{ "git", "worktree", "remove", "--force", worktree_path }, r);
        if (runCmdWin32(allocator, &.{ "git", "worktree", "prune" }, r) != 0)
            return error.WorktreePruneFailed;
        // Se usa `-d`, NO `-D`: git se niega a borrar una rama con commits sin
        // fusionar, y esa negativa es la que queremos. Podar limpia lo que
        // sobra; no debe llevarse por delante trabajo no integrado. Si git
        // rechaza el borrado, la rama simplemente se queda.
        _ = runCmdWin32(allocator, &.{ "git", "branch", "-d", branch }, r);
    }
}

/// Borra la fila del space. Devuelve false si ya no existia (otro proceso la
/// podo antes): el llamador no debe contarla.
///
/// `orders.space_id` referencia `spaces(id)` sin `ON DELETE` y la
/// conexion no activa `PRAGMA foreign_keys`, asi que borrar solo la fila dejaba
/// a las ordenes apuntando a un espacio inexistente. Aqui, en la MISMA
/// transaccion del DELETE, se anulan esas referencias (`UPDATE ... SET space_id
/// = NULL`): la orden y su historial se conservan y solo pierden el vinculo con
/// el espacio podado. No se activa el PRAGMA global (romperia otras partes):
/// el desvinculo explicito es la unica correccion.
///
/// `best_of_n_candidates.space_id` es otra referencia logica sin
/// `REFERENCES`. La candidata es historial del ranking y se conserva; solo se
/// anula su vinculo con el espacio en la misma transaccion.
fn deleteSpaceRow(conn: db.Connection, id: i64) !bool {
    try conn.exec("BEGIN IMMEDIATE");
    var tx_open = true;
    // r2: si el ROLLBACK falla no se oculta. El error original
    // sigue siendo el que devuelve la funcion; esto solo deja rastro.
    errdefer if (tx_open) conn.exec("ROLLBACK") catch |rollback_err| std.log.err(
        "spaces: rollback del borrado del space {d} fallido: {s}",
        .{ id, @errorName(rollback_err) },
    );

    const upd_sql = "UPDATE orders SET space_id = NULL WHERE space_id = ?";
    const upd_stmt = try conn.prepare(upd_sql);
    defer conn.finalize(upd_stmt);
    try db.bindInt(upd_stmt, 1, id);
    if (db.c.sqlite3_step(upd_stmt) != db.c.SQLITE_DONE) return error.StepFailed;

    const upd_cand_sql = "UPDATE best_of_n_candidates SET space_id = NULL WHERE space_id = ?";
    const upd_cand_stmt = try conn.prepare(upd_cand_sql);
    defer conn.finalize(upd_cand_stmt);
    try db.bindInt(upd_cand_stmt, 1, id);
    if (db.c.sqlite3_step(upd_cand_stmt) != db.c.SQLITE_DONE) return error.StepFailed;

    const del_sql = "DELETE FROM spaces WHERE id = ?";
    const del_stmt = try conn.prepare(del_sql);
    defer conn.finalize(del_stmt);
    try db.bindInt(del_stmt, 1, id);
    if (db.c.sqlite3_step(del_stmt) != db.c.SQLITE_DONE) return error.StepFailed;
    const deleted = conn.changes() > 0;

    try conn.exec("COMMIT");
    tx_open = false;
    return deleted;
}

/// Poda los spaces ya archivados de un proyecto: borra su fila y limpia los
/// worktrees que git haya dejado colgando. Devuelve cuántos se podaron.
///
/// Dos correcciones sobre la versión anterior, ambas de fondo:
///
///  1. **No podaba.** Llamaba a `archiveSpace` sobre filas que YA estaban
///     archivadas, de modo que volvía a lanzar `git worktree remove` sobre una
///     ruta ya retirada y a re-sellar `archived_at`. La fila no se borraba
///     nunca, así que dos pasadas seguidas devolvían el mismo número y el
///     usuario no tenía forma de vaciar la lista.
///  2. **Escribía con una lectura abierta.** Recorría el `SELECT` y, dentro
///     del bucle, preparaba y ejecutaba más sentencias sobre la MISMA conexión.
///     Es el patrón que `CRASH-SONDEO-SALUD.md` señala como sospechoso número
///     uno del `abort()` del sondeo. Ahora los ids se vuelcan primero, la
///     sentencia se finaliza, y solo después se escribe.
pub fn pruneSpaces(
    allocator: std.mem.Allocator,
    conn: db.Connection,
    project_id: []const u8,
    base_dir: []const u8,
) !u32 {
    const repo = try repoForSpace(allocator, base_dir);
    defer if (repo) |r| allocator.free(r);
    const Row = struct { id: i64, branch: []u8, worktree_path: []u8 };
    var rows = std.ArrayList(Row).empty;
    defer {
        for (rows.items) |row| {
            allocator.free(row.branch);
            allocator.free(row.worktree_path);
        }
        rows.deinit(allocator);
    }

    {
        const sql =
            \\SELECT id, branch, name, worktree_path FROM spaces
            \\WHERE project_id = ? AND archived_at IS NOT NULL
        ;
        const stmt = try conn.prepare(sql);
        defer conn.finalize(stmt);
        try db.bindText(stmt, 1, project_id);

        while (true) {
            const step = db.c.sqlite3_step(stmt);
            if (step == db.c.SQLITE_DONE) break;
            if (step != db.c.SQLITE_ROW) return error.StepFailed;
            const id = db.c.sqlite3_column_int64(stmt, 0);
            const b = std.mem.span(db.c.sqlite3_column_text(stmt, 1));
            const name = std.mem.span(db.c.sqlite3_column_text(stmt, 2));
            const path = std.mem.span(db.c.sqlite3_column_text(stmt, 3));
            try validateStoredSpace(allocator, base_dir, name, path, b);
            const branch_copy = try allocator.dupe(u8, b);
            const path_copy = allocator.dupe(u8, path) catch |e| {
                allocator.free(branch_copy);
                return e;
            };
            rows.append(allocator, .{ .id = id, .branch = branch_copy, .worktree_path = path_copy }) catch |e| {
                allocator.free(branch_copy);
                allocator.free(path_copy);
                return e;
            };
        }
    }

    // Misma limpieza por space que la poda normal hacia en bloque: worktree,
    // metadata y rama. Se hace despues de validar TODAS las filas, como antes.
    for (rows.items) |row| try pruneSpaceFiles(allocator, repo, row.worktree_path, row.branch);

    var count: u32 = 0;
    for (rows.items) |row| {
        if (try deleteSpaceRow(conn, row.id)) count += 1;
    }

    return count;
}

/// r6 (auditoria el segundo auditor, lote I): poda ACOTADA por ids aprobados.
/// Para cada id comprueba que sigue archivado y es del proyecto; despues hace
/// EXACTAMENTE la limpieza por space de `pruneSpaces` (worktree + rama) y
/// borra su fila. Un id inexistente, activo o de otro proyecto se omite: los
/// spaces que no estaban en la aprobacion nunca se tocan. Devuelve cuantos se
/// podaron de verdad.
pub fn pruneSpacesByIds(
    allocator: std.mem.Allocator,
    conn: db.Connection,
    project_id: []const u8,
    ids: []const i64,
    base_dir: []const u8,
) !u32 {
    const repo = try repoForSpace(allocator, base_dir);
    defer if (repo) |r| allocator.free(r);
    const Row = struct { id: i64, branch: []u8, worktree_path: []u8 };
    var rows = std.ArrayList(Row).empty;
    defer {
        for (rows.items) |row| {
            allocator.free(row.branch);
            allocator.free(row.worktree_path);
        }
        rows.deinit(allocator);
    }

    // Se valida y se vuelca primero, como la poda normal: una ruta o rama
    // alterada aborta antes de escribir nada.
    for (ids) |id| {
        {
            const sql =
                \\SELECT branch, name, worktree_path FROM spaces
                \\WHERE id = ? AND project_id = ? AND archived_at IS NOT NULL
            ;
            const stmt = try conn.prepare(sql);
            defer conn.finalize(stmt);
            try db.bindInt(stmt, 1, id);
            try db.bindText(stmt, 2, project_id);
            const step = db.c.sqlite3_step(stmt);
            if (step == db.c.SQLITE_DONE) continue;
            if (step != db.c.SQLITE_ROW) return error.StepFailed;
            const b = std.mem.span(db.c.sqlite3_column_text(stmt, 0));
            const name = std.mem.span(db.c.sqlite3_column_text(stmt, 1));
            const path = std.mem.span(db.c.sqlite3_column_text(stmt, 2));
            try validateStoredSpace(allocator, base_dir, name, path, b);
            const branch_copy = try allocator.dupe(u8, b);
            const path_copy = allocator.dupe(u8, path) catch |e| {
                allocator.free(branch_copy);
                return e;
            };
            rows.append(allocator, .{ .id = id, .branch = branch_copy, .worktree_path = path_copy }) catch |e| {
                allocator.free(branch_copy);
                allocator.free(path_copy);
                return e;
            };
        }
    }

    for (rows.items) |row| try pruneSpaceFiles(allocator, repo, row.worktree_path, row.branch);

    var count: u32 = 0;
    for (rows.items) |row| {
        if (try deleteSpaceRow(conn, row.id)) count += 1;
    }

    return count;
}

test "SEC-FS spaces parents stay locked during confined directory creation" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: el bloqueo de carpetas por handle abierto es de Windows; en POSIX un directorio abierto se puede renombrar y el confinamiento se apoya en openat por descriptor");
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const temp = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(temp);
    const base = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "base", .{temp});
    defer a.free(base);
    var lock = try lockSpaceParents(a, base);
    defer lock.deinit();
    try lock.createDirPath("order-1");
    const created = try lock.open("order-1");
    created.close(std.testing.io);
    try std.testing.expectError(error.SandboxDenied, lock.createDirPath("..\\outside"));
    const moved = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "moved", .{temp});
    defer a.free(moved);
    if (std.Io.Dir.cwd().rename(lock.canonical, std.Io.Dir.cwd(), moved, std.testing.io)) |_| {
        return error.SpaceParentLockBypassed;
    } else |e| {
        try std.testing.expect(e == error.AccessDenied or e == error.FileBusy);
    }
}

test "spaces creation, listing, archive and prune" {
    const allocator = std.testing.allocator;

    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();

    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_dir);

    var space1 = try createSpace(allocator, conn, "proj-1", "orden-0001", .order, tmp_dir, .{});
    defer space1.deinit(allocator);

    try std.testing.expectEqualStrings("proj-1", space1.project_id);
    try std.testing.expectEqualStrings("orden-0001", space1.name);
    try std.testing.expectEqual(SpaceKind.order, space1.kind);

    const list = try listSpaces(allocator, conn, "proj-1");
    defer {
        for (list) |*item| item.deinit(allocator);
        allocator.free(list);
    }

    try std.testing.expectEqual(@as(usize, 1), list.len);
    try std.testing.expectEqualStrings("orden-0001", list[0].name);

    try archiveSpace(allocator, conn, space1.id, tmp_dir);

    const list_after = try listSpaces(allocator, conn, "proj-1");
    defer allocator.free(list_after);
    try std.testing.expectEqual(@as(usize, 0), list_after.len);
}

test "spaces: una ruta base CON ESPACIOS no rompe el comando de git" {
    // Encontrado conduciendo la aplicacion, no leyendo codigo.
    //
    // `runCmdWin32` unia los argumentos con un espacio y SIN comillas. La ruta
    // de este mismo proyecto es `C:\...\Proyecto - DevAgents`, asi que
    // `git worktree add -b <rama> <ruta con espacios>` le llegaba a git partido
    // en varios argumentos y contestaba con su mensaje de uso. Como el codigo de
    // salida se descartaba, la fila se insertaba igual y el space aparecia en la
    // interfaz apuntando a un directorio que no existia.
    //
    // Lo que se comprueba aqui es el escapado, que es la causa raiz: la linea de
    // comandos tiene que llevar la ruta ENTRE COMILLAS y como UN solo argumento.
    const allocator = std.testing.allocator;

    var cmd = std.ArrayList(u8).empty;
    defer cmd.deinit(allocator);

    const argv = [_][]const u8{
        "git",
        "worktree",
        "add",
        "-b",
        "beats/prueba",
        "C:\\Workspace\\Usuario\\Proyecto - DevAgents\\.beats\\spaces\\prueba",
    };
    for (argv, 0..) |arg, i| {
        if (i > 0) try cmd.append(allocator, ' ');
        try executor.appendArg(&cmd, allocator, arg);
    }

    const line = cmd.items;
    // La ruta con espacios va entrecomillada.
    try std.testing.expect(std.mem.indexOf(u8, line, "\"C:\\Workspace\\Usuario\\Proyecto - DevAgents\\.beats\\spaces\\prueba\"") != null);
    // Y los argumentos sin espacios NO se entrecomillan de mas.
    try std.testing.expect(std.mem.startsWith(u8, line, "git worktree add -b beats/prueba "));
}

const GetTempPathA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetTempPathA(size: u32, buffer: [*]u8) callconv(.winapi) u32;
}.GetTempPathA else @import("platform.zig").tempPath;
const GetTickCount64 = @import("platform.zig").ticks;

test "E5.20 E-128: repo elegido con S2, colisión preservada y repo envolvente rechazado" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var buffer: [4096]u8 = undefined;
    const n = GetTempPathA(buffer.len, &buffer);
    if (n == 0 or n >= buffer.len) return error.TestUnexpectedResult;
    const parent = try std.fmt.allocPrint(a, "{s}beats-e520-spaces-{d}", .{ buffer[0..n], GetTickCount64() });
    defer a.free(parent);
    try std.Io.Dir.cwd().createDirPath(io, parent);
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch |e| std.debug.print("spaces cleanup: {s}\n", .{@errorName(e)});
    var init = try headless_adapter.defaultCapture(a, &.{ "git", "init", parent }, null);
    defer init.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), init.exit_code);
    var commit = try headless_adapter.defaultCapture(a, &.{ "git", "-c", "user.name=E520", "-c", "user.email=e520@test", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "fixture" }, parent);
    defer commit.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), commit.exit_code);
    const base = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{parent});
    defer a.free(base);
    // El segmento S2 aún no existe: el dispatcher debe detectar el repo elegido.
    try std.testing.expect(isGitRepo(a, base));
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
    var diag: worktree_prepare.Diag = .{};
    var sp = try createSpace(a, conn, "e520", "orden-1", .order, base, .{ .diag = &diag });
    defer sp.deinit(a);
    try std.testing.expect(!sp.is_non_git_degraded);
    try std.testing.expect(try headless_adapter.gitRootMatches(a, headless_adapter.defaultCapture, sp.worktree_path));
    var before = try headless_adapter.defaultCapture(a, &.{ "git", "rev-parse", "devagents/orden-1" }, parent);
    defer before.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), before.exit_code);
    var second = try createSpace(a, conn, "e520", "orden-1", .order, base, .{ .diag = &diag });
    defer second.deinit(a);
    try std.testing.expectEqualStrings("orden-1-2", second.name);
    try std.testing.expectEqualStrings("devagents/orden-1-2", second.branch);
    try std.testing.expect(std.mem.endsWith(u8, second.worktree_path, "orden-1-2"));
    var after = try headless_adapter.defaultCapture(a, &.{ "git", "rev-parse", "devagents/orden-1" }, parent);
    defer after.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), after.exit_code);
    try std.testing.expectEqualStrings(before.stdout, after.stdout);
    try std.Io.Dir.cwd().access(io, sp.worktree_path, .{});
    const spaces = try listSpaces(a, conn, "e520");
    defer {
        for (spaces) |*item| item.deinit(a);
        a.free(spaces);
    }
    try std.testing.expectEqual(@as(usize, 2), spaces.len);
    try std.testing.expectEqualStrings(second.name, spaces[1].name);
    try std.testing.expectEqualStrings(second.branch, spaces[1].branch);
    try std.testing.expectEqualStrings(second.worktree_path, spaces[1].worktree_path);
    const nested = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "nested" ++ std.fs.path.sep_str ++ "devagents-workspace", .{parent});
    defer a.free(nested);
    try std.Io.Dir.cwd().createDirPath(io, nested);
    try std.testing.expect(!isGitRepo(a, nested));
    diag = .{};
    try std.testing.expectError(error.ForeignRepository, createSpace(a, conn, "e520", "orden-foreign", .order, nested, .{ .diag = &diag }));
    try std.testing.expect(std.mem.indexOf(u8, diag.msg(), "ForeignRepository") != null);
    var branches = try headless_adapter.defaultCapture(a, &.{ "git", "branch", "--list", "devagents/orden-foreign" }, parent);
    defer branches.deinit(a);
    try std.testing.expectEqualStrings("", branches.stdout);
}

test "CK-PUB-011: la rama de un espacio integrado se borra tras archivarlo y la de otro se queda" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var buffer: [4096]u8 = undefined;
    const n = GetTempPathA(buffer.len, &buffer);
    if (n == 0 or n >= buffer.len) return error.TestUnexpectedResult;
    const parent = try std.fmt.allocPrint(a, "{s}devagents-pub011-rama-{d}", .{ buffer[0..n], GetTickCount64() });
    defer a.free(parent);
    try std.Io.Dir.cwd().createDirPath(io, parent);
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch |e| std.debug.print("spaces cleanup: {s}\n", .{@errorName(e)});
    var init = try headless_adapter.defaultCapture(a, &.{ "git", "init", parent }, null);
    defer init.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), init.exit_code);
    var commit = try headless_adapter.defaultCapture(a, &.{ "git", "-c", "user.name=T1", "-c", "user.email=t1@test", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "fixture" }, parent);
    defer commit.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), commit.exit_code);
    const base = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{parent});
    defer a.free(base);
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
    var integrada = try createSpace(a, conn, "pub011", "orden-5-d1", .order, base, .{});
    defer integrada.deinit(a);
    var conservada = try createSpace(a, conn, "pub011", "orden-5-d2", .order, base, .{});
    defer conservada.deinit(a);
    // La hija hizo un commit propio en su rama: `-d` se negaría a borrarla.
    var own = try headless_adapter.defaultCapture(a, &.{ "git", "-c", "user.name=T1", "-c", "user.email=t1@test", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "trabajo de la hija" }, integrada.worktree_path);
    defer own.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), own.exit_code);

    try archiveSpace(a, conn, integrada.id, base);
    try deleteSpaceBranch(a, conn, integrada.id, base);

    var gone = try headless_adapter.defaultCapture(a, &.{ "git", "branch", "--list", integrada.branch }, parent);
    defer gone.deinit(a);
    try std.testing.expectEqualStrings("", gone.stdout);
    var kept = try headless_adapter.defaultCapture(a, &.{ "git", "rev-parse", "--verify", "--quiet", conservada.branch }, parent);
    defer kept.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), kept.exit_code);
}

test "CK-MOT-037: rama existente sin directorio elige sufijo" {
    try testMot037(.branch);
}

test "CK-MOT-037: veinte opciones ocupadas producen error visible" {
    try testMot037(.full);
}

test "CK-MOT-037: directorio existente sin rama elige sufijo" {
    try testMot037(.directory);
}

fn testMot037(mode: enum { branch, full, directory }) !void {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var buffer: [4096]u8 = undefined;
    const n = GetTempPathA(buffer.len, &buffer);
    if (n == 0 or n >= buffer.len) return error.TestUnexpectedResult;
    const parent = try std.fmt.allocPrint(a, "{s}beats-mot037-{d}", .{ buffer[0..n], GetTickCount64() });
    defer a.free(parent);
    try std.Io.Dir.cwd().createDirPath(io, parent);
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch |e| std.debug.print("spaces cleanup: {s}\n", .{@errorName(e)});
    var init = try headless_adapter.defaultCapture(a, &.{ "git", "init", parent }, null);
    defer init.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), init.exit_code);
    var commit = try headless_adapter.defaultCapture(a, &.{ "git", "-c", "user.name=E520", "-c", "user.email=e520@test", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "fixture" }, parent);
    defer commit.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), commit.exit_code);
    for (1..(if (mode == .full) @as(usize, 21) else if (mode == .branch) 2 else 1)) |i| {
        const branch = if (i == 1) try a.dupe(u8, "devagents/orden-5") else try std.fmt.allocPrint(a, "devagents/orden-5-{d}", .{i});
        defer a.free(branch);
        var result = try headless_adapter.defaultCapture(a, &.{ "git", "branch", branch }, parent);
        defer result.deinit(a);
        try std.testing.expectEqual(@as(u32, 0), result.exit_code);
    }
    const base = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{parent});
    defer a.free(base);
    if (mode == .directory) {
        const occupied = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".devagents" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "orden-5", .{base});
        defer a.free(occupied);
        try std.Io.Dir.cwd().createDirPath(io, occupied);
    }
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
    var diag: worktree_prepare.Diag = .{};
    if (mode == .full) {
        try std.testing.expectError(error.WorktreeCreateFailed, createSpace(a, conn, "mot037", "orden-5", .order, base, .{ .diag = &diag }));
        try std.testing.expect(std.mem.indexOf(u8, diag.msg(), "20") != null);
    } else {
        var sp = try createSpace(a, conn, "mot037", "orden-5", .order, base, .{ .diag = &diag });
        defer sp.deinit(a);
        try std.testing.expectEqualStrings("orden-5-2", sp.name);
        try std.testing.expectEqualStrings("devagents/orden-5-2", sp.branch);
        try std.testing.expect(std.mem.endsWith(u8, sp.worktree_path, "orden-5-2"));
    }
}

test "spaces: prune borra las filas archivadas y no las cuenta dos veces" {
    // La version anterior de pruneSpaces llamaba a archiveSpace sobre filas ya
    // archivadas en vez de borrarlas: la fila sobrevivia y una segunda pasada
    // devolvia el MISMO numero. Este test falla con aquel comportamiento.
    const allocator = std.testing.allocator;

    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();

    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_dir);

    var s1 = try createSpace(allocator, conn, "proj-prune", "orden-0001", .order, tmp_dir, .{});
    defer s1.deinit(allocator);
    var s2 = try createSpace(allocator, conn, "proj-prune", "orden-0002", .order, tmp_dir, .{});
    defer s2.deinit(allocator);

    // Un space activo NO se poda: solo se van los archivados.
    try archiveSpace(allocator, conn, s1.id, tmp_dir);

    const pruned = try pruneSpaces(allocator, conn, "proj-prune", tmp_dir);
    try std.testing.expectEqual(@as(u32, 1), pruned);

    // El activo sigue en pie.
    const still = try listSpaces(allocator, conn, "proj-prune");
    defer {
        for (still) |*item| item.deinit(allocator);
        allocator.free(still);
    }
    try std.testing.expectEqual(@as(usize, 1), still.len);
    try std.testing.expectEqualStrings("orden-0002", still[0].name);

    // Segunda pasada: ya no queda nada archivado que podar. Este es el aserto
    // que cazaba el fallo.
    const pruned_again = try pruneSpaces(allocator, conn, "proj-prune", tmp_dir);
    try std.testing.expectEqual(@as(u32, 0), pruned_again);
}

test "E5.20 E-128 ronda2: nombres inseguros no crean rutas ni filas" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var buffer: [4096]u8 = undefined;
    const n = GetTempPathA(buffer.len, &buffer);
    if (n == 0 or n >= buffer.len) return error.TestUnexpectedResult;
    const parent = try std.fmt.allocPrint(a, "{s}beats-e128-names-{d}", .{ buffer[0..n], GetTickCount64() });
    defer a.free(parent);
    try std.Io.Dir.cwd().createDirPath(io, parent);
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch |e| std.debug.print("spaces cleanup: {s}\n", .{@errorName(e)});
    const base = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "selected" ++ std.fs.path.sep_str ++ "devagents-workspace", .{parent});
    defer a.free(base);
    try std.Io.Dir.cwd().createDirPath(io, base);
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
    var diag: worktree_prepare.Diag = .{};
    for ([_][]const u8{ "bad/name", "..\\escaped", "", ".", "..", "a:b", "CON", "con", "PRN", "AUX", "NUL", "COM1", "COM9", "LPT1", "LPT9", "a b", "a.lock", "a@b", "-option", "bad\x00name", "ñ", "a" ** 65 }) |name| {
        if (createSpace(a, conn, "e128", name, .order, base, .{ .diag = &diag })) |value| {
            var unexpected = value;
            unexpected.deinit(a);
            return error.TestUnexpectedResult;
        } else |e| try std.testing.expectEqual(error.InvalidSpaceName, e);
        try std.testing.expect(std.mem.indexOf(u8, diag.msg(), "nombre") != null);
    }
    const before = try listSpaces(a, conn, "e128");
    defer a.free(before);
    try std.testing.expectEqual(@as(usize, 0), before.len);
    const data_dir = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".devagents", .{base});
    defer a.free(data_dir);
    try std.testing.expect(sandbox.canonicalizeExisting(a, data_dir) == null);
    for ([_][]const u8{ "orden-2", "Main_checkout", "COM0", "a" ** 64 }) |name| {
        var sp = try createSpace(a, conn, "e128", name, .order, base, .{});
        defer sp.deinit(a);
        try std.testing.expect(sp.is_non_git_degraded);
    }
}

test "E5.20 E-128 ronda2: junction S2 elegida y destino se rechazan antes de crear" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: crea junctions con cmd.exe mklink /J (Windows); en Linux los enlaces los rechaza confined_posix y lo prueba su propia prueba");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var buffer: [4096]u8 = undefined;
    const n = GetTempPathA(buffer.len, &buffer);
    if (n == 0 or n >= buffer.len) return error.TestUnexpectedResult;
    const parent = try std.fmt.allocPrint(a, "{s}beats-e128-junction-{d}", .{ buffer[0..n], GetTickCount64() });
    defer a.free(parent);
    try std.Io.Dir.cwd().createDirPath(io, parent);
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch |e| std.debug.print("spaces cleanup: {s}\n", .{@errorName(e)});
    const target = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "target", .{parent});
    defer a.free(target);
    try std.Io.Dir.cwd().createDirPath(io, target);
    var init = try headless_adapter.defaultCapture(a, &.{ "git", "init", target }, null);
    defer init.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), init.exit_code);
    var commit = try headless_adapter.defaultCapture(a, &.{ "git", "-c", "user.name=E128", "-c", "user.email=e128@test", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "fixture" }, target);
    defer commit.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), commit.exit_code);
    const selected = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "selected", .{parent});
    defer a.free(selected);
    try std.Io.Dir.cwd().createDirPath(io, selected);
    const base = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{selected});
    defer a.free(base);
    var junction = try headless_adapter.defaultCapture(a, &.{ "cmd.exe", "/d", "/c", "mklink", "/J", base, target }, null);
    defer junction.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), junction.exit_code);
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
    var diag: worktree_prepare.Diag = .{};
    try std.testing.expectError(error.SandboxDenied, checkedSpacePath(a, selected, base));
    try std.testing.expectError(error.SandboxDenied, createSpace(a, conn, "e128", "orden-s2", .order, base, .{ .diag = &diag }));
    try std.testing.expect(std.mem.indexOf(u8, diag.msg(), "SandboxDenied") != null);
    try std.testing.expect(!isGitRepo(a, base));
    try std.testing.expectError(error.SandboxDenied, archiveSpace(a, conn, 1, base));
    try std.testing.expectError(error.SandboxDenied, pruneSpaces(a, conn, "e128", base));
    var branches = try headless_adapter.defaultCapture(a, &.{ "git", "branch", "--list", "devagents/orden-s2" }, target);
    defer branches.deinit(a);
    try std.testing.expectEqualStrings("", branches.stdout);
    const alias = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "alias", .{parent});
    defer a.free(alias);
    var chosen_junction = try headless_adapter.defaultCapture(a, &.{ "cmd.exe", "/d", "/c", "mklink", "/J", alias, target }, null);
    defer chosen_junction.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), chosen_junction.exit_code);
    const alias_base = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{alias});
    defer a.free(alias_base);
    try std.testing.expectError(error.SandboxDenied, createSpace(a, conn, "e128", "orden-chosen", .order, alias_base, .{}));
    const clean = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "clean", .{parent});
    defer a.free(clean);
    try std.Io.Dir.cwd().createDirPath(io, clean);
    const linked_beats = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".devagents", .{clean});
    defer a.free(linked_beats);
    var beats_junction = try headless_adapter.defaultCapture(a, &.{ "cmd.exe", "/d", "/c", "mklink", "/J", linked_beats, target }, null);
    defer beats_junction.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), beats_junction.exit_code);
    try std.testing.expectError(error.SandboxDenied, createSpace(a, conn, "e128", "orden-final", .order, clean, .{}));
    const escaped = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "orden-final", .{target});
    defer a.free(escaped);
    try std.testing.expect(sandbox.canonicalizeExisting(a, escaped) == null);
}

test "FASE0-B2: baseOfWorktree devuelve la carpeta del proyecto de un space nuevo o heredado, y nada más" {
    try std.testing.expectEqualStrings((if (@import("builtin").os.tag == .windows) "C:\\p\\mi proyecto" else "/p/mi proyecto"), baseOfWorktree((if (@import("builtin").os.tag == .windows) "C:\\p\\mi proyecto\\.devagents\\spaces\\orden-3-d1" else "/p/mi proyecto/.devagents/spaces/orden-3-d1")).?);
    try std.testing.expectEqualStrings((if (@import("builtin").os.tag == .windows) "C:\\p" else "/p"), baseOfWorktree((if (@import("builtin").os.tag == .windows) "C:\\p\\.beats\\spaces\\orden-7" else "/p/.beats/spaces/orden-7")).?);
    try std.testing.expect(baseOfWorktree((if (@import("builtin").os.tag == .windows) "C:\\p\\spaces\\orden-7" else "/p/spaces/orden-7")) == null);
    try std.testing.expect(baseOfWorktree((if (@import("builtin").os.tag == .windows) "C:\\p\\x.devagents\\spaces\\orden-7" else "/p/x.devagents/spaces/orden-7")) == null);
    try std.testing.expect(baseOfWorktree((if (@import("builtin").os.tag == .windows) "C:\\p\\.devagents\\spaces\\" else "/p/.devagents/spaces/")) == null);
    try std.testing.expect(baseOfWorktree(".devagents" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "orden-7") == null);
    try std.testing.expect(baseOfWorktree("orden-7") == null);
}

test "CK-PUB-015: spaces nuevos en.devagents con rama devagents/, heredados de .beats siguen validos y no se mezclan" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var buffer: [4096]u8 = undefined;
    const n = GetTempPathA(buffer.len, &buffer);
    if (n == 0 or n >= buffer.len) return error.TestUnexpectedResult;
    const parent = try std.fmt.allocPrint(a, "{s}da-pub015-{d}", .{ buffer[0..n], GetTickCount64() });
    defer a.free(parent);
    try std.Io.Dir.cwd().createDirPath(io, parent);
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch |e| std.debug.print("spaces cleanup: {s}\n", .{@errorName(e)});
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);

    // Carpeta sin git: el space degradado ya no crea nada llamado «devagents».
    var sp = try createSpace(a, conn, "pub015", "orden-1", .order, parent, .{});
    defer sp.deinit(a);
    try std.testing.expectEqualStrings("devagents/orden-1", sp.branch);
    try std.testing.expect(std.mem.indexOf(u8, sp.worktree_path, std.fs.path.sep_str ++ ".devagents" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "orden-1") != null);
    const old_dir = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".beats", .{parent});
    defer a.free(old_dir);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, old_dir, .{}));
    // La carpeta de spaces se ignora a sí misma en el git del usuario.
    const ignore_path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".devagents" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ ".gitignore", .{parent});
    defer a.free(ignore_path);
    const ignore = try std.Io.Dir.cwd().readFileAlloc(io, ignore_path, a, .limited(4096));
    defer a.free(ignore);
    try std.testing.expect(std.mem.indexOf(u8, ignore, "\n*\n") != null);

    // Convivencia: los guardados con el nombre de DevAgents siguen siendo válidos…
    const legacy = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".beats" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "orden-7", .{parent});
    defer a.free(legacy);
    try validateStoredSpace(a, parent, "orden-7", legacy, "beats/orden-7");
    const current = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".devagents" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "orden-7", .{parent});
    defer a.free(current);
    try validateStoredSpace(a, parent, "orden-7", current, "devagents/orden-7");
    // …pero ruta y rama no se mezclan.
    try std.testing.expectError(error.SpacePathOutsideBase, validateStoredSpace(a, parent, "orden-7", legacy, "devagents/orden-7"));
    try std.testing.expectError(error.SpacePathOutsideBase, validateStoredSpace(a, parent, "orden-7", current, "beats/orden-7"));
}

test "FASE0-P2: proyecto nuevo no crea .beats ni ramas beats/; el space heredado se lista y se abre" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var buffer: [4096]u8 = undefined;
    const n = GetTempPathA(buffer.len, &buffer);
    if (n == 0 or n >= buffer.len) return error.TestUnexpectedResult;
    const parent = try std.fmt.allocPrint(a, "{s}da-p2-{d}", .{ buffer[0..n], GetTickCount64() });
    defer a.free(parent);
    try std.Io.Dir.cwd().createDirPath(io, parent);
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch |e| std.debug.print("p2 cleanup: {s}\n", .{@errorName(e)});

    // Proyecto NUEVO de verdad: repositorio git con un commit.
    const project = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "proyecto", .{parent});
    defer a.free(project);
    try std.Io.Dir.cwd().createDirPath(io, project);
    var init = try headless_adapter.defaultCapture(a, &.{ "git", "init", project }, null);
    defer init.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), init.exit_code);
    var commit = try headless_adapter.defaultCapture(a, &.{ "git", "-c", "user.name=P2", "-c", "user.email=p2@test", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "p2 fixture" }, project);
    defer commit.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), commit.exit_code);

    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);

    var sp = try createSpace(a, conn, "p2", "orden-1", .order, project, .{});
    defer sp.deinit(a);
    try std.testing.expectEqualStrings("devagents/orden-1", sp.branch);
    try std.testing.expect(std.mem.indexOf(u8, sp.worktree_path, std.fs.path.sep_str ++ ".devagents" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "orden-1") != null);

    // En el proyecto del usuario no aparece nada llamado «devagents»…
    const no_beats = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".beats", .{project});
    defer a.free(no_beats);
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, no_beats, .{}));
    var branches = try headless_adapter.defaultCapture(a, &.{ "git", "branch", "--list", "beats/*" }, project);
    defer branches.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), branches.exit_code);
    try std.testing.expectEqualStrings("", std.mem.trim(u8, branches.stdout, " \r\n"));
    var dev_branch = try headless_adapter.defaultCapture(a, &.{ "git", "branch", "--list", "devagents/orden-1" }, project);
    defer dev_branch.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), dev_branch.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, dev_branch.stdout, "devagents/orden-1") != null);

    // Convivencia: un space creado antes del 10-nov (`.beats`, `beats/…`)
    // se sigue listando y abriendo.
    const legacy = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".beats" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "orden-7", .{project});
    defer a.free(legacy);
    try std.Io.Dir.cwd().createDirPath(io, legacy);
    {
        const ins = try conn.prepare("INSERT INTO spaces (project_id, kind, name, worktree_path, branch, created_at) VALUES (?, 'order', 'orden-7', ?, 'beats/orden-7', 1)");
        defer conn.finalize(ins);
        try db.bindText(ins, 1, "p2");
        try db.bindText(ins, 2, legacy);
        try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(ins));
    }
    const listed = try listSpaces(a, conn, "p2");
    defer {
        for (listed) |*item| item.deinit(a);
        a.free(listed);
    }
    var found_legacy = false;
    for (listed) |item| {
        if (std.mem.eql(u8, item.name, "orden-7")) {
            found_legacy = true;
            try std.testing.expectEqualStrings("beats/orden-7", item.branch);
            try validateStoredSpace(a, project, item.name, item.worktree_path, item.branch);
            try std.Io.Dir.cwd().access(io, item.worktree_path, .{});
        }
    }
    try std.testing.expect(found_legacy);
}

test "E5.20 E-128 ronda2: archivo y poda rechazan rutas y ramas alteradas" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var buffer: [4096]u8 = undefined;
    const n = GetTempPathA(buffer.len, &buffer);
    if (n == 0 or n >= buffer.len) return error.TestUnexpectedResult;
    const parent = try std.fmt.allocPrint(a, "{s}beats-e128-archive-{d}", .{ buffer[0..n], GetTickCount64() });
    defer a.free(parent);
    try std.Io.Dir.cwd().createDirPath(io, parent);
    defer std.Io.Dir.cwd().deleteTree(io, parent) catch |e| std.debug.print("spaces cleanup: {s}\n", .{@errorName(e)});
    const base = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "base", .{parent});
    defer a.free(base);
    try std.Io.Dir.cwd().createDirPath(io, base);
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
    try std.testing.expectError(error.SpacePathOutsideBase, checkedSpacePath(a, base, parent));
    const sibling = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".beats" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "orden-other", .{base});
    defer a.free(sibling);
    try std.testing.expectError(error.SpacePathOutsideBase, validateStoredSpace(a, base, "orden-1", sibling, "beats/orden-1"));
    var sp = try createSpace(a, conn, "e128", "orden-1", .order, base, .{});
    defer sp.deinit(a);
    const alter = try conn.prepare("UPDATE spaces SET worktree_path = ? WHERE id = ?");
    defer conn.finalize(alter);
    try db.bindText(alter, 1, parent);
    try db.bindInt(alter, 2, sp.id);
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(alter));
    try std.testing.expectError(error.SpacePathOutsideBase, archiveSpace(a, conn, sp.id, base));
    const query = try conn.prepare("SELECT archived_at FROM spaces WHERE id = ?");
    defer conn.finalize(query);
    try db.bindInt(query, 1, sp.id);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(query));
    try std.testing.expectEqual(db.c.SQLITE_NULL, db.c.sqlite3_column_type(query, 0));
    const alter_archived = try conn.prepare("UPDATE spaces SET archived_at = 1, branch = 'main' WHERE id = ?");
    defer conn.finalize(alter_archived);
    try db.bindInt(alter_archived, 1, sp.id);
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(alter_archived));
    try std.testing.expectError(error.SpacePathOutsideBase, pruneSpaces(a, conn, "e128", base));
    const restore_path = try conn.prepare("UPDATE spaces SET worktree_path = ? WHERE id = ?");
    defer conn.finalize(restore_path);
    try db.bindText(restore_path, 1, sp.worktree_path);
    try db.bindInt(restore_path, 2, sp.id);
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(restore_path));
    try std.testing.expectError(error.InvalidSpaceBranch, pruneSpaces(a, conn, "e128", base));
    const count = try conn.prepare("SELECT COUNT(*) FROM spaces WHERE id = ?");
    defer conn.finalize(count);
    try db.bindInt(count, 1, sp.id);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(count));
    try std.testing.expectEqual(@as(i64, 1), db.c.sqlite3_column_int64(count, 0));
}

test "E5.20 E-128 ronda3: carrera de junction antes de Git falla sin escape" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: crea junctions con cmd.exe mklink /J (Windows); en Linux los enlaces los rechaza confined_posix y lo prueba su propia prueba");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "outside-target/spaces");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    const outside = try tmp.dir.realPathFileAlloc(io, "outside-target", a);
    defer a.free(outside);
    const base = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{project});
    defer a.free(base);
    var init = try headless_adapter.defaultCapture(a, &.{ "git", "init", project }, null);
    defer init.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), init.exit_code);
    var commit = try headless_adapter.defaultCapture(a, &.{ "git", "-c", "user.name=E128", "-c", "user.email=e128@test", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "race fixture" }, project);
    defer commit.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), commit.exit_code);
    const Race = struct {
        target: []const u8,
        attempted: bool = false,
        escaped: bool = false,
        fn attempt(alloc: std.mem.Allocator, root: []const u8, context: ?*anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.attempted = true;
            var t = std.Io.Threaded.init(alloc, .{});
            defer t.deinit();
            const data_dir = try std.fmt.allocPrint(alloc, "{s}" ++ std.fs.path.sep_str ++ ".devagents", .{root});
            defer alloc.free(data_dir);
            const moved = try std.fmt.allocPrint(alloc, "{s}" ++ std.fs.path.sep_str ++ ".devagents-old", .{root});
            defer alloc.free(moved);
            std.Io.Dir.cwd().rename(data_dir, std.Io.Dir.cwd(), moved, t.io()) catch |e| switch (e) {
                error.FileNotFound => try std.Io.Dir.cwd().createDirPath(t.io(), root),
                else => return e,
            };
            var link = try headless_adapter.defaultCapture(alloc, &.{ "cmd.exe", "/d", "/c", "mklink", "/J", data_dir, self.target }, null);
            defer link.deinit(alloc);
            if (link.exit_code != 0) return error.JunctionCreateFailed;
            self.escaped = true;
            std.debug.print("RACE_JUNCTION_INSTALLED=true\n", .{});
        }
    };
    var race = Race{ .target = outside };
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
    var diag: worktree_prepare.Diag = .{};
    const result = createSpace(a, conn, "e128-race", "race-test", .order, base, .{ .diag = &diag, .before_git_fn = Race.attempt, .before_git_ctx = &race });
    if (result) |value| {
        var unexpected = value;
        defer unexpected.deinit(a);
        const escaped = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "race-test", .{outside});
        defer a.free(escaped);
        const exists = sandbox.canonicalizeExisting(a, escaped);
        defer if (exists) |path| a.free(path);
        std.debug.print("RACE_ESCAPE_REPRODUCED={any}\n", .{exists != null});
        var remove = try headless_adapter.defaultCapture(a, &.{ "git", "worktree", "remove", "--force", unexpected.worktree_path }, project);
        defer remove.deinit(a);
        try std.testing.expectEqual(@as(u32, 0), remove.exit_code);
        return error.TestUnexpectedResult;
    } else |e| {
        try std.testing.expect(e == error.AccessDenied or e == error.FileBusy);
    }
    try std.testing.expect(race.attempted);
    try std.testing.expect(!race.escaped);
    try std.testing.expect(std.mem.indexOf(u8, diag.msg(), "antes de Git") != null);
    const list = try listSpaces(a, conn, "e128-race");
    defer a.free(list);
    try std.testing.expectEqual(@as(usize, 0), list.len);
    var branches = try headless_adapter.defaultCapture(a, &.{ "git", "branch", "--list", "devagents/race-test" }, project);
    defer branches.deinit(a);
    try std.testing.expectEqualStrings("", branches.stdout);
}

test "E5.20 E-128 ronda3: rechazo final por handle retira worktree y sólo su rama" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "project");
    try tmp.dir.createDirPath(io, "outside");
    const project = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(project);
    const outside = try tmp.dir.realPathFileAlloc(io, "outside", a);
    defer a.free(outside);
    if (verifyCreatedSpace(a, project, outside)) |value| {
        var unexpected = value;
        unexpected.deinit();
        return error.TestUnexpectedResult;
    } else |e| try std.testing.expectEqual(error.SpacePathOutsideBase, e);
    var oom = std.testing.FailingAllocator.init(a, .{ .fail_index = 0 });
    try std.testing.expectError(error.OutOfMemory, verifyCreatedSpace(oom.allocator(), project, outside));
    var init = try headless_adapter.defaultCapture(a, &.{ "git", "init", project }, null);
    defer init.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), init.exit_code);
    var commit = try headless_adapter.defaultCapture(a, &.{ "git", "-c", "user.name=E128", "-c", "user.email=e128@test", "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", "cleanup fixture" }, project);
    defer commit.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), commit.exit_code);
    var keep = try headless_adapter.defaultCapture(a, &.{ "git", "branch", "devagents/preexisting" }, project);
    defer keep.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), keep.exit_code);
    const base = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{project});
    defer a.free(base);
    const Reject = struct {
        called: bool = false,
        fn run(_: std.mem.Allocator, _: []const u8, context: ?*anyopaque) !void {
            const self: *@This() = @ptrCast(@alignCast(context.?));
            self.called = true;
            return error.SpacePathOutsideBase;
        }
    };
    var reject = Reject{};
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
    var diag: worktree_prepare.Diag = .{};
    try std.testing.expectError(error.SpacePathOutsideBase, createSpace(a, conn, "cleanup", "rejected", .order, base, .{ .diag = &diag, .after_git_fn = Reject.run, .after_git_ctx = &reject }));
    try std.testing.expect(reject.called);
    try std.testing.expect(std.mem.indexOf(u8, diag.msg(), "SpacePathOutsideBase") != null);
    const rejected = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".devagents" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "rejected", .{base});
    defer a.free(rejected);
    try std.testing.expect(sandbox.canonicalizeExisting(a, rejected) == null);
    var branches = try headless_adapter.defaultCapture(a, &.{ "git", "branch", "--list", "devagents/rejected", "devagents/preexisting" }, project);
    defer branches.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, branches.stdout, "devagents/rejected") == null);
    try std.testing.expect(std.mem.indexOf(u8, branches.stdout, "devagents/preexisting") != null);
    const list = try listSpaces(a, conn, "cleanup");
    defer a.free(list);
    try std.testing.expectEqual(@as(usize, 0), list.len);
}

test "CK-MCP-001 r6 motor: poda por ids retira worktree y rama y no toca otro archivado" {
    // r6 (auditoria el segundo auditor, lote I): la poda aprobada por MCP no
    // puede ser un DELETE a secas. La funcion por ids hace la misma limpieza
    // que la poda normal por space (worktree + rama + fila) y solo toca los
    // ids recibidos, comprobando que sigan archivados y del proyecto.
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const project = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(project);

    var init = try headless_adapter.defaultCapture(a, &.{ "git", "init", project }, null);
    defer init.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), init.exit_code);
    var commit = try headless_adapter.defaultCapture(a, &.{
        "git",                  "-c",                 "user.name=CK-MCP-001",
        "-c",                   "user.email=ck@test", "-c",
        "commit.gpgsign=false", "commit",             "--allow-empty",
        "-m",                   "fixture",
    }, project);
    defer commit.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), commit.exit_code);

    const base = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{project});
    defer a.free(base);
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);

    var podar = try createSpace(a, conn, "ck-mcp-001-r6", "r6-podar", .order, base, .{});
    defer podar.deinit(a);
    var queda = try createSpace(a, conn, "ck-mcp-001-r6", "r6-queda", .order, base, .{});
    defer queda.deinit(a);

    // Los dos worktrees existen de verdad antes de podar.
    try std.Io.Dir.cwd().access(io, podar.worktree_path, .{});
    try std.Io.Dir.cwd().access(io, queda.worktree_path, .{});

    // Se marcan archivados SIN archiveSpace para reproducir filas archivadas
    // por otra via: el worktree sigue en disco y la poda por ids debe
    // retirarlo igual que la poda normal (que ahora comparte la misma
    // limpieza por space).
    {
        const stmt = try conn.prepare("UPDATE spaces SET archived_at = 1 WHERE id = ?");
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, podar.id);
        try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(stmt));
    }
    {
        const stmt = try conn.prepare("UPDATE spaces SET archived_at = 1 WHERE id = ?");
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, queda.id);
        try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(stmt));
    }

    const ids = [_]i64{podar.id};
    const pruned = try pruneSpacesByIds(a, conn, "ck-mcp-001-r6", &ids, base);
    try std.testing.expectEqual(@as(u32, 1), pruned);

    // El space aprobado dejo de existir en disco y su rama se borro.
    try std.testing.expectError(error.FileNotFound, std.Io.Dir.cwd().access(io, podar.worktree_path, .{}));
    var podar_branch = try headless_adapter.defaultCapture(a, &.{ "git", "branch", "--list", "devagents/r6-podar" }, project);
    defer podar_branch.deinit(a);
    try std.testing.expectEqualStrings("", podar_branch.stdout);

    // El archivado NO incluido sigue intacto: fila, worktree y rama.
    try std.Io.Dir.cwd().access(io, queda.worktree_path, .{});
    var queda_branch = try headless_adapter.defaultCapture(a, &.{ "git", "branch", "--list", "devagents/r6-queda" }, project);
    defer queda_branch.deinit(a);
    try std.testing.expect(std.mem.indexOf(u8, queda_branch.stdout, "devagents/r6-queda") != null);

    {
        const count_stmt = try conn.prepare("SELECT id FROM spaces WHERE project_id = ? ORDER BY id ASC");
        defer conn.finalize(count_stmt);
        try db.bindText(count_stmt, 1, "ck-mcp-001-r6");
        try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(count_stmt));
        try std.testing.expectEqual(queda.id, db.c.sqlite3_column_int64(count_stmt, 0));
        try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(count_stmt));
    }
}

test "CK-MOT-031: podar un space deja las ordenes con space_id NULL sin romper la integridad" {
    // La poda (normal y por ids) borraba la fila de spaces sin tocar orders.
    // Como la conexion no activa PRAGMA foreign_keys, la referencia
    // orders.space_id -> spaces(id) quedaba colgando: la orden seguia
    // apuntando a un espacio inexistente. Ahora el borrado anula esas
    // referencias en la MISMA transaccion, conserva la orden (su historial)
    // y `PRAGMA foreign_key_check` no devuelve filas.
    const allocator = std.testing.allocator;

    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    try db.Migrator.init(allocator).migrate(conn, &db.runtime_schema);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_dir);

    // --- Poda normal ---
    var normal = try createSpace(allocator, conn, "ck-mot-031-normal", "mot031-normal", .order, tmp_dir, .{});
    defer normal.deinit(allocator);
    try archiveSpace(allocator, conn, normal.id, tmp_dir);
    {
        const stmt = try conn.prepare("INSERT INTO orders (id, project_id, user_prompt, status, created_at, space_id) VALUES (?, ?, 'ck-mot-031', 'done', 1, ?)");
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, 3101);
        try db.bindText(stmt, 2, "ck-mot-031-normal");
        try db.bindInt(stmt, 3, normal.id);
        try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(stmt));
    }

    const pruned = try pruneSpaces(allocator, conn, "ck-mot-031-normal", tmp_dir);
    try std.testing.expectEqual(@as(u32, 1), pruned);

    {
        const stmt = try conn.prepare("SELECT space_id FROM orders WHERE id = ?");
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, 3101);
        try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
        try std.testing.expectEqual(db.c.SQLITE_NULL, db.c.sqlite3_column_type(stmt, 0));
    }
    {
        const stmt = try conn.prepare("PRAGMA foreign_key_check");
        defer conn.finalize(stmt);
        try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(stmt));
    }

    // --- Poda por ids ---
    var by_ids = try createSpace(allocator, conn, "ck-mot-031-ids", "mot031-ids", .order, tmp_dir, .{});
    defer by_ids.deinit(allocator);
    try archiveSpace(allocator, conn, by_ids.id, tmp_dir);
    {
        const stmt = try conn.prepare("INSERT INTO orders (id, project_id, user_prompt, status, created_at, space_id) VALUES (?, ?, 'ck-mot-031', 'done', 1, ?)");
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, 3102);
        try db.bindText(stmt, 2, "ck-mot-031-ids");
        try db.bindInt(stmt, 3, by_ids.id);
        try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(stmt));
    }

    const ids = [_]i64{by_ids.id};
    const pruned_ids = try pruneSpacesByIds(allocator, conn, "ck-mot-031-ids", &ids, tmp_dir);
    try std.testing.expectEqual(@as(u32, 1), pruned_ids);

    {
        const stmt = try conn.prepare("SELECT space_id FROM orders WHERE id = ?");
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, 3102);
        try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
        try std.testing.expectEqual(db.c.SQLITE_NULL, db.c.sqlite3_column_type(stmt, 0));
    }
    {
        const stmt = try conn.prepare("PRAGMA foreign_key_check");
        defer conn.finalize(stmt);
        try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(stmt));
    }
}

test "CK-MOT-031 r2: el fallo al borrar la fila revierte el desvinculo y cierra la transaccion" {
    // Si una sentencia de deleteSpaceRow falla DESPUES del UPDATE, el
    // rollback debe dejar la orden con su space_id original y el espacio
    // intacto, y la conexion debe quedar fuera de la transaccion (nada de
    // BEGIN abierto que rompa la siguiente escritura). El error del DELETE se
    // fuerza con un trigger de prueba.
    const allocator = std.testing.allocator;

    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    try db.Migrator.init(allocator).migrate(conn, &db.runtime_schema);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_dir);

    var space = try createSpace(allocator, conn, "ck-mot-031-r2", "mot031-r2", .order, tmp_dir, .{});
    defer space.deinit(allocator);
    try archiveSpace(allocator, conn, space.id, tmp_dir);

    {
        const stmt = try conn.prepare("INSERT INTO orders (id, project_id, user_prompt, status, created_at, space_id) VALUES (?, ?, 'ck-mot-031-r2', 'done', 1, ?)");
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, 3201);
        try db.bindText(stmt, 2, "ck-mot-031-r2");
        try db.bindInt(stmt, 3, space.id);
        try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(stmt));
    }
    // la candidata best-of-n tambien se desvincula en la misma
    // transaccion; este fallo fuerza su rollback.
    {
        const stmt = try conn.prepare(
            "INSERT INTO best_of_n_candidates (id, parent_order_id, member_idx, provider, model, status, created_at, space_id) VALUES (?, ?, 0, 'deepseek', 'v4.1', 'done', 1, ?)",
        );
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, 4201);
        try db.bindInt(stmt, 2, 3201);
        try db.bindInt(stmt, 3, space.id);
        try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(stmt));
    }

    try conn.exec(
        "CREATE TRIGGER ck_mot_031_block BEFORE DELETE ON spaces BEGIN SELECT RAISE(ABORT, 'ck-mot-031'); END",
    );

    try std.testing.expectError(error.StepFailed, pruneSpaces(allocator, conn, "ck-mot-031-r2", tmp_dir));

    // El rollback revirtio el UPDATE: la orden conserva su vinculo.
    {
        const stmt = try conn.prepare("SELECT space_id FROM orders WHERE id = ?");
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, 3201);
        try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
        try std.testing.expectEqual(space.id, db.c.sqlite3_column_int64(stmt, 0));
    }
    // El rollback tambien revierte el desvinculo de la candidata best-of-n.
    {
        const stmt = try conn.prepare("SELECT space_id FROM best_of_n_candidates WHERE id = ?");
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, 4201);
        try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
        try std.testing.expectEqual(space.id, db.c.sqlite3_column_int64(stmt, 0));
    }
    // El espacio sigue existiendo.
    {
        const stmt = try conn.prepare("SELECT COUNT(*) FROM spaces WHERE id = ?");
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, space.id);
        try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
        try std.testing.expectEqual(@as(i64, 1), db.c.sqlite3_column_int64(stmt, 0));
    }
    // La conexion quedo en autocommit y admite otra transaccion.
    try std.testing.expect(db.c.sqlite3_get_autocommit(conn.db) != 0);
    try conn.exec("BEGIN IMMEDIATE");
    try conn.exec("ROLLBACK");
}

test "CK-MOT-032: podar un space desvincula las candidatas best-of-n sin retirarlas" {
    // `best_of_n_candidates.space_id` (db.zig:964-971) es otra referencia
    // logica a spaces(id) sin REFERENCES. La poda (normal y por ids) conserva
    // la candidata —es historial del ranking— pero anula su vinculo con el
    // espacio en la MISMA transaccion del DELETE, igual que orders en
    //.
    const allocator = std.testing.allocator;

    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    try db.Migrator.init(allocator).migrate(conn, &db.runtime_schema);

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const tmp_dir = try tmp.dir.realPathFileAlloc(std.testing.io, ".", allocator);
    defer allocator.free(tmp_dir);

    // --- Poda normal ---
    var normal = try createSpace(allocator, conn, "ck-mot-032-normal", "mot032-normal", .order, tmp_dir, .{});
    defer normal.deinit(allocator);
    try archiveSpace(allocator, conn, normal.id, tmp_dir);
    {
        const stmt = try conn.prepare("INSERT INTO orders (id, project_id, user_prompt, status, created_at, space_id) VALUES (?, ?, 'ck-mot-032', 'done', 1, ?)");
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, 3301);
        try db.bindText(stmt, 2, "ck-mot-032-normal");
        try db.bindInt(stmt, 3, normal.id);
        try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(stmt));
    }
    {
        const stmt = try conn.prepare(
            "INSERT INTO best_of_n_candidates (id, parent_order_id, member_idx, provider, model, status, created_at, space_id) VALUES (?, ?, 0, 'deepseek', 'v4.1', 'done', 1, ?)",
        );
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, 4301);
        try db.bindInt(stmt, 2, 3301);
        try db.bindInt(stmt, 3, normal.id);
        try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(stmt));
    }

    const pruned = try pruneSpaces(allocator, conn, "ck-mot-032-normal", tmp_dir);
    try std.testing.expectEqual(@as(u32, 1), pruned);

    {
        const stmt = try conn.prepare("SELECT space_id, member_idx FROM best_of_n_candidates WHERE id = ?");
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, 4301);
        try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
        try std.testing.expectEqual(db.c.SQLITE_NULL, db.c.sqlite3_column_type(stmt, 0));
        // La candidata sigue viva con su identidad de ranking.
        try std.testing.expectEqual(@as(i64, 0), db.c.sqlite3_column_int64(stmt, 1));
    }

    // --- Poda por ids ---
    var by_ids = try createSpace(allocator, conn, "ck-mot-032-ids", "mot032-ids", .order, tmp_dir, .{});
    defer by_ids.deinit(allocator);
    try archiveSpace(allocator, conn, by_ids.id, tmp_dir);
    {
        const stmt = try conn.prepare("INSERT INTO orders (id, project_id, user_prompt, status, created_at, space_id) VALUES (?, ?, 'ck-mot-032', 'done', 1, ?)");
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, 3302);
        try db.bindText(stmt, 2, "ck-mot-032-ids");
        try db.bindInt(stmt, 3, by_ids.id);
        try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(stmt));
    }
    {
        const stmt = try conn.prepare(
            "INSERT INTO best_of_n_candidates (id, parent_order_id, member_idx, provider, model, status, created_at, space_id) VALUES (?, ?, 1, 'deepseek', 'v4.1', 'done', 1, ?)",
        );
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, 4302);
        try db.bindInt(stmt, 2, 3302);
        try db.bindInt(stmt, 3, by_ids.id);
        try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(stmt));
    }

    const ids = [_]i64{by_ids.id};
    const pruned_ids = try pruneSpacesByIds(allocator, conn, "ck-mot-032-ids", &ids, tmp_dir);
    try std.testing.expectEqual(@as(u32, 1), pruned_ids);

    {
        const stmt = try conn.prepare("SELECT space_id, member_idx FROM best_of_n_candidates WHERE id = ?");
        defer conn.finalize(stmt);
        try db.bindInt(stmt, 1, 4302);
        try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
        try std.testing.expectEqual(db.c.SQLITE_NULL, db.c.sqlite3_column_type(stmt, 0));
        try std.testing.expectEqual(@as(i64, 1), db.c.sqlite3_column_int64(stmt, 1));
    }

    // Tras las dos podas no queda ninguna referencia colgante en la tabla.
    {
        const stmt = try conn.prepare(
            "SELECT count(*) FROM best_of_n_candidates c WHERE c.space_id IS NOT NULL AND NOT EXISTS (SELECT 1 FROM spaces s WHERE s.id = c.space_id)",
        );
        defer conn.finalize(stmt);
        try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
        try std.testing.expectEqual(@as(i64, 0), db.c.sqlite3_column_int64(stmt, 0));
    }
}

/// T9: misma llamada en POSIX (argv directo, sin shell; git con fsmonitor
/// apagado), en su propio grupo de procesos y con salida descartada.
fn runCmdPosix(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) u32 {
    if (argv.len == 0) return 1;
    const fs_off = std.mem.eql(u8, argv[0], "git");
    const full = allocator.alloc([]const u8, argv.len + @as(usize, if (fs_off) 2 else 0)) catch return 1;
    defer allocator.free(full);
    full[0] = argv[0];
    var i: usize = 1;
    if (fs_off) {
        full[1] = "-c";
        full[2] = "core.fsmonitor=false";
        i = 3;
    }
    @memcpy(full[i..], argv[1..]);
    const result = @import("providers").posix_process.run(allocator, full, cwd, null, null, 600_000, 64 * 1024) catch return 1;
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (result.timed_out) return 1;
    return result.exit_code;
}
