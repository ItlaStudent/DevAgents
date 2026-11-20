//! core/src/workspace.zig — Persistencia REAL de los programas generados.
//!
//! Cierra el hallazgo "¿dónde se guardan los programas?": antes los artefactos del worker
//! se validaban contra el contrato y el sandbox y luego se DESCARTABAN (result.deinit).
//! Ahora la salida de cada tarea de `programacion` se escribe a disco en un workspace
//! propio y SEGURO POR DEFECTO:  devagents-workspace/orden-<id>/<archivo>.
//!
//! Política de seguridad (alineada con el Sandbox léxico y T-F7-07): este módulo SOLO
//! escribe dentro del workspace gobernado elegido explícitamente por el usuario (o
//! relativo al cwd por defecto). El nombre que propone el modelo se reduce a su BASENAME, de
//! modo que ningún `..` ni ruta absoluta pueda escapar del workspace.
//!
//! I/O con el nuevo std.Io del fork (Io.Threaded -> Io.Dir.cwd().createDirPath/writeFile),
//! mismo idioma que tool_discovery.zig y http/client.zig. Best-effort: el llamador decide
//! qué hacer ante un error de FS; la validación de contrato ya ocurrió aguas arriba.

const std = @import("std");
const worker_backend = @import("worker_backend.zig");
const planner = @import("planner.zig");
const model_router = @import("model_router.zig");
const windows = std.os.windows;
const sync = @import("sync.zig");
const hooks = @import("hooks.zig");
const drift_edit = @import("drift_edit.zig");
const confined_fs = @import("confined_fs.zig");
const prose_artifact = @import("prose_artifact.zig");
const best_of_n = @import("best_of_n.zig");

fn mot018PersistReconstruction(index: usize) !void {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    setOrderRootOverride(root);
    defer setOrderRootOverride(null);
    // Reconstruction: debug suppresses delta bodies. The two bad values and
    // filenames are measured; the JSON layout and prose below are fixtures.
    const fixtures = [_][]const u8{
        \\[{"field":"filename","content":"riesgos_claves_api.txt"},{"field":"source","content":"documentacion"},{"field":"text","content":"Guardar claves de API en texto plano permite que cualquier persona con acceso al archivo las copie y utilice. Una filtracion puede causar cargos inesperados y acceso a datos privados. Evita incluirlas en repositorios, restringe permisos y usa un gestor de secretos. Si una clave se expone, revocala y revisa los registros de uso."}]
        ,
        \\[{"field":"filename","content":"api-key-risks.txt"},{"field":"source","content":"docs/api-key-risks.txt"},{"field":"text","content":"Guardar claves de API en texto plano permite que cualquier persona con acceso al archivo las copie y utilice. Una filtracion puede causar cargos inesperados y acceso a datos privados. Evita incluirlas en repositorios, restringe permisos y usa un gestor de secretos. Si una clave se expone, revocala y revisa los registros de uso."}]
        ,
    };
    for (fixtures[index..][0..1], index..) |raw, i| {
        var artifacts = try worker_backend.parseArtifacts(a, raw);
        defer {
            for (artifacts.items) |art| art.deinit(a);
            artifacts.deinit(a);
        }
        const task = planner.PlannedTask{
            .id = "t1",
            .task_type = .documentar,
            .department = "documentacion",
            .description = "Documenta brevemente en un texto los riesgos de guardar claves de API en texto plano",
            .contract_fields = &.{},
            .depends_on = &.{},
        };
        const paths = (try persistTaskFiles(a, @intCast(859 + i), task, artifacts.items)) orelse return error.TestUnexpectedResult;
        defer {
            for (paths) |p| a.free(p);
            a.free(paths);
        }
        try std.testing.expectEqual(@as(usize, 1), paths.len);
        const body = try std.Io.Dir.cwd().readFileAlloc(io, paths[0], a, .limited(4096));
        defer a.free(body);
        try std.testing.expectEqualStrings(artifacts.items[2].content, body);
    }
}

test "MOT018 reconstructed 859 persists prose instead of task metadata" {
    try mot018PersistReconstruction(0);
}

test "MOT018 reconstructed 860 persists prose instead of path metadata" {
    try mot018PersistReconstruction(1);
}

test "MOT018 named prose metadata resolves the actual body and rejects missing bodies" {
    const a = std.testing.allocator;
    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .documentar,
        .department = "documentacion",
        .description = "Documenta los riesgos de guardar claves de API en texto plano",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    const good = "Las claves de API en texto plano pueden filtrarse en repositorios y copias de seguridad. Usa un gestor de secretos, limita los permisos y revoca las claves expuestas.";
    const artifacts = [_]worker_backend.Artifact{
        .{ .path = "risks.txt", .content = "docs/risks.txt" },
        .{ .path = "text", .content = good },
    };
    var names = std.ArrayList(u8).empty;
    defer names.deinit(a);
    const files = (try planOutFiles(a, task, &artifacts, &names, false)) orelse return error.TestUnexpectedResult;
    defer a.free(files);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("risks.txt", files[0].name);
    try std.testing.expectEqualStrings(good, files[0].body);
    try std.testing.expectError(error.InvalidArtifact, planOutFiles(a, task, artifacts[0..1], &names, false));
    const only_metadata = [_]worker_backend.Artifact{
        .{ .path = "filename", .content = "risks.txt" },
        .{ .path = "source", .content = "documentacion" },
    };
    try std.testing.expectError(error.InvalidArtifact, planOutFiles(a, task, &only_metadata, &names, false));
    const mixed_files = [_]worker_backend.Artifact{
        artifacts[0], .{ .path = "other.txt", .content = good },
    };
    try std.testing.expectError(error.InvalidArtifact, planOutFiles(a, task, &mixed_files, &names, false));
}

/// Raíz del workspace gobernado, por defecto relativa al cwd del proceso.
/// Puede cambiarse en runtime via setWorkspaceRoot() (P2: persistencia de archivos).
pub const WORKSPACE_ROOT = "devagents-workspace";
var workspace_root: []const u8 = WORKSPACE_ROOT;
var workspace_root_owned: ?[]const u8 = null;
// P01-T3: Mutex para proteger workspace_root contra accesos concurrentes
// (setWorkspaceRoot desde la GUI + persistTask desde hilos de ola).
var workspace_mutex: sync.Mutex = .init();

// B3-SPACE-PER-ORDER (F5): raíz por orden, thread-local. El hilo de dispatch la
// fija al worktree del space ligado a la orden (orders.space_id) mientras
// ejecuta y la limpia al terminar — cada orden escribe aislada en su rama y el
// resto de hilos (UI, poller, otras órdenes) siguen viendo la raíz global. El
// override YA es una ruta absoluta real, así que salta la reancla por CWD de
// effectiveRoot.
threadlocal var order_root_buf: [4096]u8 = undefined;
threadlocal var order_root_len: usize = 0;

/// Fija (o limpia con null) la raíz efectiva SOLO para el hilo llamador.
pub fn setOrderRootOverride(path: ?[]const u8) void {
    if (path) |p| {
        const n = @min(p.len, order_root_buf.len);
        @memcpy(order_root_buf[0..n], p);
        order_root_len = n;
    } else {
        order_root_len = 0;
    }
}

/// Lee el override de ESTE hilo copiándolo a `buf` (null si no hay).
/// Sirve para propagarlo a hilos worker: el override es thread-local y los
/// hilos de una ola nacen sin él (hallazgo orden #457: los artefactos caían en
/// la raíz global en vez del worktree del space).
pub fn getOrderRootOverride(buf: *[4096]u8) ?[]const u8 {
    if (order_root_len == 0) return null;
    const n = @min(order_root_len, buf.len);
    @memcpy(buf[0..n], order_root_buf[0..n]);
    return buf[0..n];
}

pub fn setWorkspaceRoot(path: []const u8) void {
    setWorkspaceRootChecked(path) catch |e| {
        // Los consumidores C-ABI usan la variante checked y muestran last_error.
        // Un fallo interno conserva la raíz anterior, nunca elige otra en silencio.
        std.log.err("workspace root rejected: {s}", .{@errorName(e)});
    };
}

/// Valida antes de reemplazar la raíz. Rechaza reanclajes relativos, rutas
/// demasiado largas y OOM; la C-ABI propaga la causa al puente y al MCP.
pub fn setWorkspaceRootChecked(path: []const u8) !void {
    if (path.len == 0 or path.len > 4000 or std.mem.indexOfScalar(u8, path, 0) != null) return error.InvalidWorkspaceRoot;
    var zbuf: [4096:0]u8 = undefined;
    const z = try std.fmt.bufPrintZ(&zbuf, "{s}", .{path});
    var abs_buf: [4096:0]u8 = undefined;
    const absolute = if (std.fs.path.isAbsolute(path)) path else blk: {
        const n = GetFullPathNameA(z, abs_buf.len, &abs_buf, null);
        if (n == 0 or n > 4000) return error.InvalidWorkspaceRoot;
        var cwd_buf: [4096]u8 = undefined;
        const cn = GetCurrentDirectoryA(cwd_buf.len, &cwd_buf);
        if (cn == 0 or cn >= cwd_buf.len) return error.InvalidWorkspaceRoot;
        if (!pathIsWithin(abs_buf[0..n], cwd_buf[0..cn])) return error.WorkspaceReanchorDenied;
        break :blk abs_buf[0..n];
    };
    const a = std.heap.page_allocator;
    const owned = try confined_fs.strictNewPath(a, absolute);
    errdefer a.free(owned);
    // La selección y su segmento S2 pueden no existir aún; todo ancestro
    // existente debe conservar identidad léxica y no ser reparse point.
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(owned), WORKSPACE_ROOT)) {
        const effective = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ owned, WORKSPACE_ROOT });
        defer a.free(effective);
        const checked = try confined_fs.strictNewPath(a, effective);
        defer a.free(checked);
    }
    workspace_mutex.lock();
    defer workspace_mutex.unlock();
    if (workspace_root_owned) |old| {
        std.heap.page_allocator.free(old);
    }
    workspace_root_owned = owned;
    workspace_root = owned;
}

/// `path`, resuelto a absoluta (relativas contra el cwd del proceso), queda
/// dentro de `root`. Sirve a los clientes no humanos (MCP), que solo pueden
/// estrechar la raíz, nunca redirigirla. Falla cerrado ante rutas inválidas.
pub fn resolvesInside(path: []const u8, root: []const u8) bool {
    if (path.len == 0 or root.len == 0 or path.len > 4000 or root.len > 4000) return false;
    if (std.mem.indexOfScalar(u8, path, 0) != null or std.mem.indexOfScalar(u8, root, 0) != null) return false;
    var pz: [4096:0]u8 = undefined;
    var rz: [4096:0]u8 = undefined;
    const pzs = std.fmt.bufPrintZ(&pz, "{s}", .{path}) catch return false;
    const rzs = std.fmt.bufPrintZ(&rz, "{s}", .{root}) catch return false;
    var pabs: [4096:0]u8 = undefined;
    var rabs: [4096:0]u8 = undefined;
    const pn = GetFullPathNameA(pzs, pabs.len, &pabs, null);
    const rn = GetFullPathNameA(rzs, rabs.len, &rabs, null);
    if (pn == 0 or pn > 4000 or rn == 0 or rn > 4000) return false;
    return pathIsWithin(pabs[0..pn], rabs[0..rn]);
}

/// SEC2 R6/H6: raiz EFECTIVA que resultaria de seleccionar `selection` (misma
/// regla S2 que `effectiveRoot`: absoluta y siempre terminada en
/// `devagents-workspace`), sin tener en cuenta el espacio de una orden.
/// null si la seleccion es invalida. El slice vive en `buf`.
pub fn effectiveRootOfSelection(selection: []const u8, buf: *[4096]u8) ?[]const u8 {
    if (selection.len == 0 or selection.len > 4000 or std.mem.indexOfScalar(u8, selection, 0) != null) return null;
    var zbuf: [4096:0]u8 = undefined;
    const z = std.fmt.bufPrintZ(&zbuf, "{s}", .{selection}) catch return null;
    var abs_buf: [4096:0]u8 = undefined;
    const n = GetFullPathNameA(z, abs_buf.len, &abs_buf, null);
    if (n == 0 or n > 4000) return null;
    const absolute = abs_buf[0..n];
    if (std.ascii.eqlIgnoreCase(std.fs.path.basename(absolute), WORKSPACE_ROOT)) {
        @memcpy(buf[0..n], absolute);
        return buf[0..n];
    }
    return std.fmt.bufPrint(buf, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ absolute, WORKSPACE_ROOT }) catch null;
}

/// SEC2 R6/H6: `requested` solo ESTRECHA el espacio si su raiz efectiva queda
/// dentro de la raiz efectiva de la seleccion vigente. Comparar contra la
/// seleccion (sin el segmento S2) dejaba mover la raiz a una carpeta hermana:
/// `C:\p\otra` esta dentro de `C:\p`, pero su efectiva `C:\p\otra\devagents-workspace`
/// no esta dentro de `C:\p\devagents-workspace`. Falla cerrado.
pub fn narrowsEffectiveRoot(requested: []const u8) bool {
    var sel_buf: [4096]u8 = undefined;
    var cur_buf: [4096]u8 = undefined;
    var req_buf: [4096]u8 = undefined;
    const current = effectiveRootOfSelection(getWorkspaceRoot(&sel_buf), &cur_buf) orelse return false;
    const wanted = effectiveRootOfSelection(requested, &req_buf) orelse return false;
    return pathIsWithin(wanted, current);
}

/// Copia la selección bajo el mutex. El slice pertenece al llamador y un
/// setter concurrente no puede liberarlo ni cambiarlo.
pub fn getWorkspaceRoot(buf: *[4096]u8) []const u8 {
    workspace_mutex.lock();
    defer workspace_mutex.unlock();
    const n = workspace_root.len;
    @memcpy(buf[0..n], workspace_root);
    return buf[0..n];
}

/// la carpeta del proyecto tal como la eligió el usuario, SIN el
/// segmento S2 (`devagents-workspace`). La usa el modo Directo, que trabaja
/// como cualquier IDE: edita el proyecto mismo, con la misma gobernanza. Si
/// la selección no es una ruta absoluta (valor por defecto relativo al cwd de
/// la app) o ya es el segmento, devuelve null y el llamador usa
/// `effectiveRoot`: nunca se edita la carpeta de la aplicación por omisión.
pub fn selectedProjectRoot(buf: *[4096]u8) ?[]const u8 {
    var sel_buf: [4096]u8 = undefined;
    const sel = getWorkspaceRoot(&sel_buf);
    if (sel.len < 3 or sel.len > buf.len) return null;
    if (!std.fs.path.isAbsolute(sel)) return null;
    if (std.ascii.eqlIgnoreCase(std.fs.path.basename(sel), WORKSPACE_ROOT)) return null;
    @memcpy(buf[0..sel.len], sel);
    return buf[0..sel.len];
}

/// QA-B 2b (14-nov): raíz de lo que el usuario hace a mano sobre su proyecto
/// (tools fs_*/git_* y shell_run del MCP, terminal gobernada de la C-ABI):
/// la carpeta del proyecto elegida, como el modo Directo, y si no hay una
/// elegida, la raíz efectiva. Dentro de un hilo de orden manda su space.
pub fn projectOrEffectiveRoot(buf: *[4096]u8) []const u8 {
    if (order_root_len == 0) {
        if (selectedProjectRoot(buf)) |root| return root;
    }
    return effectiveRoot(buf);
}

/// D3-FIX: Resuelve la raíz efectiva del workspace de forma CENTRALIZADA.
/// La selección absoluta se respeta independientemente del cwd de la app.
/// S2 añade devagents-workspace al proyecto; D3 mantiene una sola raíz para
/// persistencia y sandbox. Las selecciones relativas que escaparían al cwd
/// se rechazan en setWorkspaceRootChecked con causa visible. Retorna un slice (buf)
/// que es válido mientras el llamador no vuelva a llamar effectiveRoot.
/// Todos los consumidores (persistTask, governedExecute, governedExecuteRaw,
/// resumeExecutionApproval) DEBEN usar esta función para garantizar que
/// sandbox.init(root) contenga el exec-dir donde persistTask escribió.
pub fn effectiveRoot(buf: *[4096]u8) []const u8 {
    // B3: si el hilo corre dentro de un space de orden, esa es la raíz.
    if (order_root_len > 0) {
        const n = @min(order_root_len, buf.len);
        @memcpy(buf[0..n], order_root_buf[0..n]);
        return buf[0..n];
    }
    var selected_buf: [4096]u8 = undefined;
    const ws_root = getWorkspaceRoot(&selected_buf);

    // Resolver ws_root a ruta ABSOLUTA via GetFullPathNameA.
    var ws_root_buf: [4096:0]u8 = undefined;
    const ws_root_z = std.fmt.bufPrintZ(&ws_root_buf, "{s}", .{ws_root}) catch {
        @memcpy(buf[0..ws_root.len], ws_root);
        return buf[0..ws_root.len];
    };
    var abs_buf: [4096:0]u8 = undefined;
    const abs_len = GetFullPathNameA(ws_root_z, @intCast(abs_buf.len), @as([*:0]u8, @ptrCast(&abs_buf[0])), null);
    const ws_abs_raw: []const u8 = if (abs_len > 0 and abs_len < abs_buf.len) blk: {
        abs_buf[abs_len] = 0;
        break :blk abs_buf[0..abs_len];
    } else ws_root;

    // La selección validada ya es absoluta; sólo el valor inicial por defecto
    // es relativo al cwd. No existe una segunda ruta de reanclaje silencioso.
    // S2: SIEMPRE bajo el segmento `devagents-workspace` del proyecto elegido.
    //
    // Medido en la orden #215, lanzada desde la cabina: los cuatro archivos
    // acabaron en la RAÍZ del repositorio (`<proyecto>\orden-215\`), mezclados
    // con el código fuente. La causa es que `core.workspace.set` —la carpeta que
    // el usuario elige con el diálogo— sustituye la raíz ENTERA, segmento
    // incluido, y una carpeta elegida sí cae dentro del CWD, así que llegaba
    // hasta aquí y se usaba tal cual.
    //
    // Elegir la carpeta dice DÓNDE trabaja el agente, no que pueda dejar sus
    // artefactos sueltos encima del proyecto. La cabecera de este módulo ya lo
    // promete —«un espacio propio y SEGURO POR DEFECTO»—; esto es cumplirlo.
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(ws_abs_raw), WORKSPACE_ROOT)) {
        const s = std.fmt.bufPrint(buf, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ ws_abs_raw, WORKSPACE_ROOT }) catch {
            const n = @min(ws_abs_raw.len, buf.len);
            @memcpy(buf[0..n], ws_abs_raw[0..n]);
            return buf[0..n];
        };
        return s;
    }

    const n = @min(ws_abs_raw.len, buf.len);
    @memcpy(buf[0..n], ws_abs_raw[0..n]);
    return buf[0..n];
}

/// A new default workspace has not received persistTask yet. Create only its
/// single S2 segment under an existing validated project, retaining the parent.
/// Missing explicit spaces/projects remain errors; never choose another root.
pub fn ensureExternalRoot(a: std.mem.Allocator, io: std.Io, path: []const u8) !void {
    _ = io;
    const policy = @import("external_cli_policy.zig");
    var existing = confined_fs.Root.init(a, path) catch |e| switch (e) {
        error.FileNotFound => {
            if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(path), WORKSPACE_ROOT)) return e;
            const parent = std.fs.path.dirname(path) orelse return e;
            var lock = try confined_fs.Root.init(a, parent);
            defer lock.deinit();
            policy.createPrivateDirectory(a, path) catch |create_error| switch (create_error) {
                error.PathAlreadyExists => {},
                else => return create_error,
            };
            var created = try confined_fs.Root.init(a, path);
            defer created.deinit();
            try policy.checkAcl(created.dir().handle);
            return;
        },
        else => return e,
    };
    defer existing.deinit();
    if (std.ascii.eqlIgnoreCase(std.fs.path.basename(path), WORKSPACE_ROOT)) try policy.checkAcl(existing.dir().handle);
}

// FS por API Win32 DIRECTA (no std.Io.Threaded). El executor threaded de std.Io provoca
// un access violation cuando el core (DLL) corre dentro del proceso MSVC/Qt de la GUI
// (en el binario Zig del CLI funciona, pero no debemos depender de ello). Las syscalls
// directas son portables entre hosts y no levantan executor. Mismo estilo que
// bus/named_pipe.zig y plugin_loader.zig.
// Retornos BOOL declarados como c_int para poder comparar con 0 (el BOOL del fork es un
// tipo envuelto no comparable con literales). 0 = fallo.
const CreateDirectoryA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateDirectoryA(lpPathName: [*:0]const u8, lpSecurityAttributes: ?*anyopaque) c_int;
}.CreateDirectoryA else @import("providers").posix_files.CreateDirectoryA;
const CreateFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateFileA(
        lpFileName: [*:0]const u8,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?windows.HANDLE,
    ) windows.HANDLE;
}.CreateFileA else @import("providers").posix_files.CreateFileA;
const WriteFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn WriteFile(hFile: windows.HANDLE, lpBuffer: [*]const u8, n: u32, written: *u32, ov: ?*anyopaque) c_int;
}.WriteFile else @import("providers").posix_files.WriteFile;
const ReadFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn ReadFile(hFile: windows.HANDLE, lpBuffer: [*]u8, n: u32, read: *u32, ov: ?*anyopaque) c_int;
}.ReadFile else @import("providers").posix_files.ReadFile;
const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) c_int;
}.CloseHandle else @import("providers").posix_files.CloseHandle;
const DeleteFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn DeleteFileA(lpFileName: [*:0]const u8) c_int;
}.DeleteFileA else @import("providers").posix_files.DeleteFileA;
const RemoveDirectoryA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn RemoveDirectoryA(lpPathName: [*:0]const u8) c_int;
}.RemoveDirectoryA else @import("providers").posix_files.RemoveDirectoryA;
const GetTickCount64 = @import("platform.zig").ticks;
const GetTempPathA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetTempPathA(nBufferLength: u32, lpBuffer: [*]u8) u32;
}.GetTempPathA else @import("platform.zig").tempPath;
const GetFullPathNameA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFullPathNameA(lpFileName: [*:0]const u8, nBufferLength: u32, lpBuffer: [*:0]u8, lpFilePart: ?*?[*:0]u8) callconv(.winapi) u32;
}.GetFullPathNameA else @import("providers").posix_files.GetFullPathNameA;
const GetCurrentDirectoryA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetCurrentDirectoryA(nBufferLength: u32, lpBuffer: [*]u8) callconv(.winapi) u32;
}.GetCurrentDirectoryA else @import("platform.zig").cwd;
extern "kernel32" fn GetFinalPathNameByHandleA(
    hFile: windows.HANDLE,
    lpszFilePath: [*]u8,
    cchFilePath: u32,
    dwFlags: u32,
) u32;
extern "kernel32" fn DeviceIoControl(
    hDevice: windows.HANDLE,
    dwIoControlCode: u32,
    lpInBuffer: ?*const anyopaque,
    nInBufferSize: u32,
    lpOutBuffer: ?*anyopaque,
    nOutBufferSize: u32,
    lpBytesReturned: ?*u32,
    lpOverlapped: ?*anyopaque,
) c_int;

const GENERIC_WRITE: u32 = 0x40000000;
const GENERIC_READ: u32 = 0x80000000;
const OPEN_EXISTING: u32 = 3;
const FILE_SHARE_READ: u32 = 0x00000001;
const FILE_SHARE_WRITE: u32 = 0x00000002;
const CREATE_ALWAYS: u32 = 2;
const FILE_ATTRIBUTE_NORMAL: u32 = 0x80;
const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
const FILE_FLAG_OPEN_REPARSE_POINT: u32 = 0x00200000;
const FSCTL_SET_REPARSE_POINT: u32 = 0x000900A4;
const IO_REPARSE_TAG_MOUNT_POINT: u32 = 0xA0000003;
const VOLUME_NAME_DOS: u32 = 0x0;
const INVALID_HANDLE_VALUE: windows.HANDLE = @ptrFromInt(~@as(usize, 0));

/// Resuelve una ruta EXISTENTE a su forma canónica vía Win32 (atraviesa
/// junctions, symlinks y reparse points). Devuelve null si no existe o la
/// resolución falla. El llamador libera el slice. Misma técnica que
/// `sandbox.canonicalize` — aquí la necesita la contención de escritura.
fn canonicalizeExisting(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    const path_z = allocator.dupeZ(u8, path) catch return null;
    defer allocator.free(path_z);
    const h = CreateFileA(path_z.ptr, GENERIC_READ, FILE_SHARE_READ | FILE_SHARE_WRITE, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, null);
    if (h == INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(h);
    var buf: [4096]u8 = undefined;
    const len = GetFinalPathNameByHandleA(h, &buf, buf.len, VOLUME_NAME_DOS);
    if (len == 0 or len >= buf.len) return null;
    const res = buf[0..len];
    const stripped = if (std.mem.startsWith(u8, res, "\\\\?\\")) res["\\\\?\\".len..] else res;
    return allocator.dupe(u8, stripped) catch null;
}

/// True si la ruta absoluta `child` está dentro (o es igual a) `parent`. Comparación
/// case-insensitive con normalización de separadores (rutas Windows). Se usa para no
/// re-anclar cuando el workspace_root ya es el cwd o una subcarpeta legítima suya.
fn pathIsWithin(child: []const u8, parent: []const u8) bool {
    if (parent.len == 0 or child.len < parent.len) return false;
    var i: usize = 0;
    while (i < parent.len) : (i += 1) {
        const a = std.ascii.toLower(if (child[i] == '/') '\\' else child[i]);
        const b = std.ascii.toLower(if (parent[i] == '/') '\\' else parent[i]);
        if (a != b) return false;
    }
    // Igual (mismo largo) o límite en separador (evita que C:\foo matchee C:\foobar).
    return child.len == parent.len or child[parent.len] == '\\' or child[parent.len] == '/';
}

/// M1: un archivo listo para escribirse. `name` ya viene saneado (sin separadores) y
/// con extensión; `body` apunta al contenido original (no se copia).
pub const OutFile = struct { name: []const u8, body: []const u8 };

/// Escribe el programa producido por UNA tarea en <workspace_root>/orden-<id>/.
/// Devuelve la ruta (ABSOLUTA, dup'd con `allocator`) del archivo PRINCIPAL, o null si la
/// tarea no produjo nada persistible. Los archivos adicionales que la tarea haya generado
/// se escriben igualmente en disco, pero sus rutas se descartan: para recogerlas hay que
/// llamar a `persistTaskFiles`, que es lo que hace el superagente.
pub fn persistTask(
    allocator: std.mem.Allocator,
    order_id: i64,
    task: planner.PlannedTask,
    artifacts: []const worker_backend.Artifact,
) !?[]const u8 {
    const paths = (try persistTaskFiles(allocator, order_id, task, artifacts)) orelse return null;
    defer allocator.free(paths);
    for (paths[1..]) |extra| allocator.free(extra);
    return paths[0];
}

/// M1 — LA ENTREGA ES MULTI-ARCHIVO. Medido el 2026-08-11 en las órdenes #183 y #184:
/// se pide «una calculadora en HTML+CSS+JS», el modelo entrega los tres archivos, y esto
/// escribía UNO solo. El resultado era un `index.html` enlazando un `styles.css` y un
/// `script.js` que no existían — con la orden marcada `done` y la auto-auditoría en verde.
///
/// Se reconocen dos formas de entrega multi-archivo, en este orden:
///   1. Varios artefactos del contrato cuyo NOMBRE DE CAMPO ya es un nombre de archivo
///      (`{"field":"index.html"}`, `{"field":"styles.css"}`). El extractor ya los sabía
///      leer; era esto lo que los tiraba.
///   2. Un único campo `source` con los archivos separados por un comentario suelto con
///      el nombre (`<!-- index.html -->`, `/* styles.css */`, `// script.js`), que es lo
///      que hacen los modelos cuando el contrato solo les ofrece un campo.
///
/// Devuelve las rutas ABSOLUTAS escritas (la primera es la principal), todas dup'd con
/// `allocator`, o null si no había nada persistible. Nunca escribe fuera del workspace.
/// D1: workspace_root se resuelve a ruta absoluta via GetFullPathNameA; el sandbox
/// rechaza escrituras cuya ruta resuelta cae fuera del workspace.
pub fn persistTaskFiles(
    allocator: std.mem.Allocator,
    order_id: i64,
    task: planner.PlannedTask,
    artifacts: []const worker_backend.Artifact,
) !?[][]const u8 {
    var fallback_name_buf = std.ArrayList(u8).empty;
    defer fallback_name_buf.deinit(allocator);
    const planned = (try planOutFiles(allocator, task, artifacts, &fallback_name_buf, false)) orelse return null;
    defer allocator.free(planned);
    const out_files = planned;

    // D3-FIX: Usar effectiveRoot (lógica centralizada) para resolver la raíz efectiva.
    // Esto garantiza que persistTask, governedExecute, governedExecuteRaw y
    // resumeExecutionApproval usen TODOS la misma raíz → sandbox.init(root) siempre
    // contiene el exec-dir donde se escribe el artefacto.
    var er_buf: [4096]u8 = undefined;
    const ws_abs: []const u8 = effectiveRoot(&er_buf);

    var root = confined_fs.createRoot(allocator, ws_abs) catch |e| return workspaceMutationError(e);
    defer root.deinit();
    // D2 (11-nov, defecto en vivo: madre 46, hijas 47 y 48) y E-GOV.4 de la
    // rama e5-gov. Dentro de un espacio con git la orden trabaja en SU copia
    // del proyecto: lo que pide la tarea (`docs/dos.txt`) se escribe en esa
    // ruta de la raíz del espacio, la misma que leen el auditor (sus
    // herramientas tienen la raíz del espacio), sus citas, el modo agéntico y
    // los agentes externos (E5.09), y la que se integra (git del espacio en
    // delegation/best_of_n). Antes caía en `<espacio>\orden-48\dos.txt` y el
    // auditor la rechazó con razón. El informe de una tarea `auditar` NO es un
    // archivo del proyecto: sigue en `orden-<id>\` como evidencia, donde
    // delegation.destinationFiles lo aparta y nunca se integra. Fuera de un
    // espacio con git (raíz global o espacio degradado sin git) no cambia nada.
    const at_space_root = task.task_type != .auditar and order_root_len > 0 and isGitSpaceRoot(root.canonical);
    const order_rel = try std.fmt.allocPrint(allocator, "orden-{d}", .{order_id});
    defer allocator.free(order_rel);
    if (!at_space_root) root.createDirPath(order_rel) catch |e| return workspaceMutationError(e);
    const order_dir = if (at_space_root)
        try allocator.dupe(u8, root.canonical)
    else
        try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ root.canonical, order_rel });
    defer allocator.free(order_dir);
    var written_paths = std.ArrayList([]const u8).empty;
    errdefer {
        for (written_paths.items) |p| allocator.free(p);
        written_paths.deinit(allocator);
    }
    for (out_files) |f| {
        // El modelo a veces devuelve el nombre del artefacto con
        // la carpeta de la orden delante (`orden-896/prv012-auto.txt`) porque
        // ve el worktree como su cwd. Al anteponer order_dir quedaba
        // `…/spaces/orden-896/orden-896/…`. Se quita ese primer componente
        // cuando es exactamente `orden-<id>` de ESTA orden.
        const stripped = try stripOrderDirPrefix(allocator, f.name, order_rel);
        defer if (stripped.ptr != f.name.ptr) allocator.free(stripped);
        const p = try writeOneFileInRoot(allocator, &root, order_dir, stripped, f.body);
        try written_paths.append(allocator, p);
    }
    if (written_paths.items.len == 0) return null;
    return try written_paths.toOwnedSlice(allocator);
}

fn workspaceMutationError(e: anyerror) anyerror {
    return if (e == error.SandboxDenied or e == error.HardLinkDenied) error.WriteOutsideWorkspace else e;
}

/// Si `name` empieza por el componente `order_rel`
/// (`orden-<id>` de esta orden) seguido de separador, devuelve el resto
/// duplicado con `allocator`; si no, devuelve `name` tal cual (slice
/// prestado, no liberar).
fn stripOrderDirPrefix(allocator: std.mem.Allocator, name: []const u8, order_rel: []const u8) ![]const u8 {
    if (!std.mem.startsWith(u8, name, order_rel)) return name;
    const rest = name[order_rel.len..];
    if (rest.len == 0) return name;
    // `orden-<id>/rest`: el componente exacto.
    if (rest[0] == '/' or rest[0] == '\\') {
        if (rest.len == 1) return name;
        return try allocator.dupe(u8, rest[1..]);
    }
    // Auditoría B-1: los espacios reales llevan sufijo (`orden-48-d2`,
    // `orden-1-2`); `orden-<id>-<sufijo>/rest` se recorta igual, hasta el
    // primer separador.
    if (rest[0] == '-') {
        const sep = std.mem.indexOfAny(u8, rest, "/\\") orelse return name;
        if (sep <= 1) return name;
        return try allocator.dupe(u8, rest[sep + 1 ..]);
    }
    return name;
}

/// D2: `path` es la raíz de un espacio de orden (`…\.devagents\spaces\<n>` o
/// el heredado `…\.beats\spaces\<n>`) con git (`.git`, archivo de worktree o
/// carpeta). Un espacio degradado sin git no cuenta: allí la salida solo se
/// encuentra paseando `orden-<id>\`.
pub fn isGitSpaceRoot(path: []const u8) bool {
    const trimmed = std.mem.trimEnd(u8, path, "\\/");
    const parent = std.fs.path.dirname(trimmed) orelse return false;
    if (!std.ascii.eqlIgnoreCase(std.fs.path.basename(parent), "spaces")) return false;
    const internal = std.fs.path.dirname(parent) orelse return false;
    const internal_name = std.fs.path.basename(internal);
    if (!std.ascii.eqlIgnoreCase(internal_name, ".devagents") and !std.ascii.eqlIgnoreCase(internal_name, ".beats")) return false;
    var git_buf: [4096]u8 = undefined;
    const git = std.fmt.bufPrintZ(&git_buf, "{s}" ++ std.fs.path.sep_str ++ ".git", .{trimmed}) catch return false;
    return GetFileAttributesA(git.ptr) != INVALID_FILE_ATTRIBUTES;
}

/// D2: carpeta donde `persistTaskFiles` deja lo que produce una tarea que no
/// es de auditoría: la raíz del espacio con git de la orden, o
/// `<raíz efectiva>\orden-<id>` en los demás casos. Owned por `allocator`.
pub fn producerOutputDir(allocator: std.mem.Allocator, order_id: i64) ![]u8 {
    var er_buf: [4096]u8 = undefined;
    const ws_abs = effectiveRoot(&er_buf);
    if (order_root_len > 0 and isGitSpaceRoot(ws_abs)) return allocator.dupe(u8, std.mem.trimEnd(u8, ws_abs, "\\/"));
    return std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "orden-{d}", .{ std.mem.trimEnd(u8, ws_abs, "\\/"), order_id });
}

/// D2: nombre con el que se enseña un archivo entregado (evento
/// `file_written`, contexto del auditor): su ruta relativa a la carpeta de la
/// orden — `docs\dos.txt`, no `dos.txt` ni `orden-48\dos.txt`. Devuelve un
/// trozo de `path`; si no cuelga de la raíz efectiva ni de un `orden-<n>`,
/// el último componente, como antes.
pub fn displayName(path: []const u8) []const u8 {
    var er_buf: [4096]u8 = undefined;
    const root = std.mem.trimEnd(u8, effectiveRoot(&er_buf), "\\/");
    var rel: []const u8 = path;
    if (root.len > 0 and path.len > root.len + 1 and pathIsWithin(path, root)) rel = path[root.len + 1 ..];
    // Lo que queda tras el último componente `orden-<dígitos>`.
    var start: usize = 0;
    var i: usize = 0;
    while (i < rel.len) {
        const comp_start = i;
        while (i < rel.len and rel[i] != '\\' and rel[i] != '/') : (i += 1) {}
        const comp = rel[comp_start..i];
        if (i < rel.len and std.mem.startsWith(u8, comp, "orden-") and comp.len > "orden-".len) {
            const digits = comp["orden-".len..];
            const all_digits = for (digits) |c| {
                if (!std.ascii.isDigit(c)) break false;
            } else true;
            if (all_digits) start = i + 1;
        }
        if (i < rel.len) i += 1;
    }
    const shown = rel[start..];
    if (rel.ptr == path.ptr and start == 0) return std.fs.path.basename(path);
    return shown;
}

/// D2: ruta relativa pedida por el modelo (`docs/dos.txt`), sin salir de la
/// carpeta de la orden. Null si no es una ruta relativa sana de 2 a 8
/// componentes: absoluta, UNC, letra de unidad, `..`, `.`, componentes vacíos
/// o nombres que `isSaneName` rechaza (dispositivos Win32, control, cierres
/// en punto o espacio). Quien recibe null cae al `basename` de siempre.
fn safeRelativePath(p: []const u8) ?[]const u8 {
    const t = std.mem.trim(u8, p, " \t\r\n");
    if (t.len == 0 or t.len > 240) return null;
    if (t[0] == '/' or t[0] == '\\') return null;
    var parts = std.mem.splitAny(u8, t, "/\\");
    var count: usize = 0;
    while (parts.next()) |part| {
        count += 1;
        if (count > 8) return null;
        if (std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return null;
        if (!isSaneName(part)) return null;
    }
    if (count < 2) return null;
    return t;
}

/// Nombre que se escribe para un artefacto: la ruta relativa pedida si es
/// sana (D2) o, si no, el último componente sin `..` (E3.36).
fn outputName(p: []const u8) []const u8 {
    return safeRelativePath(p) orelse basename(p);
}

const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
const GetFileAttributesA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileAttributesA(lpFileName: [*:0]const u8) callconv(.winapi) u32;
}.GetFileAttributesA else @import("providers").posix_files.GetFileAttributesA;

test "D2: en un espacio con git la salida va a su ruta pedida en la raiz y el informe del auditor queda en orden-<id>" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    for ([_][]const u8{ ".devagents", ".beats" }) |internal| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const rel_space = try std.fmt.allocPrint(a, "{s}/spaces/orden-46-d1", .{internal});
        defer a.free(rel_space);
        try tmp.dir.createDirPath(io, rel_space);
        // Un worktree de git deja un ARCHIVO `.git` en su raíz.
        const git_file = try std.fmt.allocPrint(a, "{s}/.git", .{rel_space});
        defer a.free(git_file);
        try tmp.dir.writeFile(io, .{ .sub_path = git_file, .data = "gitdir: ../../../.git/worktrees/orden-46-d1\n" });
        const root = try tmp.dir.realPathFileAlloc(io, rel_space, a);
        defer a.free(root);
        try std.testing.expect(isGitSpaceRoot(root));
        setOrderRootOverride(root);
        defer setOrderRootOverride(null);

        const task = planner.PlannedTask{ .id = "t1", .task_type = .programar, .department = "programacion", .description = "Crea el archivo docs/uno.txt con una linea que diga UNO.", .contract_fields = &.{}, .depends_on = &.{} };
        const artifacts = [_]worker_backend.Artifact{.{ .path = "docs/uno.txt", .content = "UNO\n" }};
        const paths = (try persistTaskFiles(a, 47, task, &artifacts)).?;
        defer {
            for (paths) |path| a.free(path);
            a.free(paths);
        }
        const expected = try std.fs.path.join(a, &.{ root, "docs", "uno.txt" });
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, paths[0]);
        try std.testing.expectEqualStrings("docs" ++ std.fs.path.sep_str ++ "uno.txt", displayName(paths[0]));
        const produced = try producerOutputDir(a, 47);
        defer a.free(produced);
        try std.testing.expectEqualStrings(std.mem.trimEnd(u8, root, std.fs.path.sep_str ++ "/"), produced);
        const rel_file = try std.fmt.allocPrint(a, "{s}/docs/uno.txt", .{rel_space});
        defer a.free(rel_file);
        const data = try tmp.dir.readFileAlloc(io, rel_file, a, .limited(128));
        defer a.free(data);
        try std.testing.expectEqualStrings("UNO\n", data);
        // Ni `orden-47\uno.txt` ni `orden-47\docs\uno.txt`.
        const nested = try std.fmt.allocPrint(a, "{s}/orden-47/docs/uno.txt", .{rel_space});
        defer a.free(nested);
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, nested, .{}));
        const flat = try std.fmt.allocPrint(a, "{s}/orden-47/uno.txt", .{rel_space});
        defer a.free(flat);
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, flat, .{}));

        // El informe de la tarea de auditoría es evidencia: va a `orden-47\`.
        const audit = planner.PlannedTask{ .id = "t2", .task_type = .auditar, .department = "auditoria", .description = "Audita lo que produjo t1 frente a su instruccion.", .contract_fields = &.{}, .depends_on = &.{} };
        const report = [_]worker_backend.Artifact{.{ .path = "t2.txt", .content = "PASS: docs/uno.txt:1 `UNO` contiene exactamente lo pedido por la instruccion de la tarea t1.\n" }};
        const report_paths = (try persistTaskFiles(a, 47, audit, &report)).?;
        defer {
            for (report_paths) |path| a.free(path);
            a.free(report_paths);
        }
        const order_dir = try std.fs.path.join(a, &.{ root, "orden-47" });
        defer a.free(order_dir);
        try std.testing.expect(pathIsWithin(report_paths[0], order_dir));
        try std.testing.expect(std.mem.startsWith(u8, displayName(report_paths[0]), "t2."));
    }
}

test "D2: en un espacio degradado (sin git) la salida sigue en orden-<id> con su subcarpeta" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    for ([_][]const u8{ ".devagents", ".beats" }) |internal| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const rel_space = try std.fmt.allocPrint(a, "{s}/spaces/orden-9", .{internal});
        defer a.free(rel_space);
        try tmp.dir.createDirPath(io, rel_space);
        const root = try tmp.dir.realPathFileAlloc(io, rel_space, a);
        defer a.free(root);
        try std.testing.expect(!isGitSpaceRoot(root));
        setOrderRootOverride(root);
        defer setOrderRootOverride(null);
        const task = planner.PlannedTask{ .id = "t1", .task_type = .programar, .department = "programacion", .description = "edita flag.go", .contract_fields = &.{}, .depends_on = &.{} };
        const artifacts = [_]worker_backend.Artifact{.{ .path = "pkg/flag.go", .content = "package pflag\n" }};
        const paths = (try persistTaskFiles(a, 9, task, &artifacts)).?;
        defer {
            for (paths) |path| a.free(path);
            a.free(paths);
        }
        const expected = try std.fs.path.join(a, &.{ root, "orden-9", "pkg", "flag.go" });
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, paths[0]);
        try std.testing.expectEqualStrings("pkg" ++ std.fs.path.sep_str ++ "flag.go", displayName(paths[0]));
        const at_root = try std.fmt.allocPrint(a, "{s}/pkg/flag.go", .{rel_space});
        defer a.free(at_root);
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, at_root, .{}));
        // listOrderFiles ve la subcarpeta con su ruta relativa.
        const files = try listOrderFiles(a, 9);
        defer {
            for (files) |f| f.deinit(a);
            a.free(files);
        }
        try std.testing.expectEqual(@as(usize, 1), files.len);
        try std.testing.expectEqualStrings("pkg/flag.go", files[0].name);
    }
}

test "CK-MOT-028: un artefacto llamado orden-<id>/x no duplica la carpeta de la orden" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const task = planner.PlannedTask{ .id = "t1", .task_type = .programar, .department = "programacion", .description = "Crea el archivo uno.txt con una linea que diga UNO.", .contract_fields = &.{}, .depends_on = &.{} };

    // Espacio con git: la raíz ya es `…/spaces/orden-48-d2`; el modelo
    // devolvió el nombre del artefacto con la carpeta de la orden delante.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const rel_space = ".devagents/spaces/orden-48-d2";
        try tmp.dir.createDirPath(io, rel_space);
        const git_file = try std.fmt.allocPrint(a, "{s}/.git", .{rel_space});
        defer a.free(git_file);
        try tmp.dir.writeFile(io, .{ .sub_path = git_file, .data = "gitdir: ../../../.git/worktrees/orden-48-d2\n" });
        const root = try tmp.dir.realPathFileAlloc(io, rel_space, a);
        defer a.free(root);
        try std.testing.expect(isGitSpaceRoot(root));
        setOrderRootOverride(root);
        defer setOrderRootOverride(null);

        const artifacts = [_]worker_backend.Artifact{
            .{ .path = "orden-48/uno.txt", .content = "UNO\n" },
            // Auditoría B-1: el espacio real es `orden-48-d2`; el modelo puede
            // devolver el nombre completo del directorio como prefijo.
            .{ .path = "orden-48-d2/doble.txt", .content = "DOS\n" },
        };
        const paths = (try persistTaskFiles(a, 48, task, &artifacts)).?;
        defer {
            for (paths) |path| a.free(path);
            a.free(paths);
        }
        try std.testing.expectEqual(2, paths.len);
        const expected = try std.fs.path.join(a, &.{ root, "uno.txt" });
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, paths[0]);
        const expected2 = try std.fs.path.join(a, &.{ root, "doble.txt" });
        defer a.free(expected2);
        try std.testing.expectEqualStrings(expected2, paths[1]);
        const nested = try std.fmt.allocPrint(a, "{s}/orden-48/orden-48/uno.txt", .{root});
        defer a.free(nested);
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, nested, .{}));
        const nested2 = try std.fmt.allocPrint(a, "{s}/orden-48-d2/orden-48-d2/doble.txt", .{root});
        defer a.free(nested2);
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, nested2, .{}));
    }

    // Espacio degradado (sin git): la salida cae en `orden-<id>`; el mismo
    // nombre tampoco puede anidar otra vez esa carpeta.
    {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const rel_space = ".devagents/spaces/orden-49-d3";
        try tmp.dir.createDirPath(io, rel_space);
        const root = try tmp.dir.realPathFileAlloc(io, rel_space, a);
        defer a.free(root);
        try std.testing.expect(!isGitSpaceRoot(root));
        setOrderRootOverride(root);
        defer setOrderRootOverride(null);

        const artifacts = [_]worker_backend.Artifact{.{ .path = "orden-49/dos.txt", .content = "DOS\n" }};
        const paths = (try persistTaskFiles(a, 49, task, &artifacts)).?;
        defer {
            for (paths) |path| a.free(path);
            a.free(paths);
        }
        const expected = try std.fs.path.join(a, &.{ root, "orden-49", "dos.txt" });
        defer a.free(expected);
        try std.testing.expectEqualStrings(expected, paths[0]);
        const nested = try std.fmt.allocPrint(a, "{s}/orden-49/orden-49/dos.txt", .{root});
        defer a.free(nested);
        try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, nested, .{}));
    }
}

/// Kept for direct callers; production batches retain one root for all files.
fn writeOneFile(
    allocator: std.mem.Allocator,
    order_dir: []const u8,
    ws_abs: []const u8,
    name: []const u8,
    content: []const u8,
) ![]const u8 {
    var root = confined_fs.Root.initMutation(allocator, ws_abs) catch |e| return workspaceMutationError(e);
    defer root.deinit();
    return writeOneFileInRoot(allocator, &root, order_dir, name, content);
}

fn writeOneFileInRoot(
    allocator: std.mem.Allocator,
    root: *const confined_fs.Root,
    order_dir: []const u8,
    name: []const u8,
    content: []const u8,
) ![]const u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ order_dir, name });
    errdefer allocator.free(path);
    // D2: `name` puede traer subcarpetas con '/' (docs/dos.txt); la ruta
    // registrada usa el separador del sistema, como la escrita en disco
    // (T9 fase B: en Linux, '/').
    if (std.fs.path.sep == '\\') std.mem.replaceScalar(u8, path, '/', '\\') else std.mem.replaceScalar(u8, path, '\\', '/');
    const relative = root.relativePath(path) catch |e| return workspaceMutationError(e);
    defer allocator.free(relative);
    try hooks.check(allocator, .pre_edit, path, "", root.canonical);
    {
        const editing = drift_edit.looksLikeEdit(content);
        var file = root.openMutation(relative, if (editing) .existing else .open_or_create) catch |e| {
            if (editing and e == error.FileNotFound) return error.EditWithoutTarget;
            return workspaceMutationError(e);
        };
        defer file.deinit();
        if (editing) {
            const previous = try file.readAlloc(allocator, MAX_LECTURA);
            defer allocator.free(previous);
            const blocks = try drift_edit.parseBlocks(allocator, content);
            defer allocator.free(blocks);
            const edited = try drift_edit.apply(allocator, previous, blocks);
            defer allocator.free(edited);
            try writeFileRaw(allocator, &file, edited);
        } else {
            try writeFileRaw(allocator, &file, content);
        }
    }
    // Formatters may replace the file: release its mutation handle first.
    _ = hooks.run(allocator, .post_edit, path, "", root.canonical);
    return path;
}

fn writeFileRaw(allocator: std.mem.Allocator, file: *confined_fs.Mutation, content: []const u8) !void {
    const data = try unescapeIfDoubleEscaped(allocator, content);
    defer allocator.free(data);
    try file.writeAll(data);
}

fn unescapeIfDoubleEscaped(allocator: std.mem.Allocator, content: []const u8) ![]u8 {
    const has_real_nl = std.mem.indexOfScalar(u8, content, '\n') != null;
    const has_escaped_nl = std.mem.indexOf(u8, content, "\\n") != null;
    if (has_real_nl or !has_escaped_nl) return allocator.dupe(u8, content);

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var i: usize = 0;
    while (i < content.len) : (i += 1) {
        if (content[i] == '\\' and i + 1 < content.len) {
            const n = content[i + 1];
            switch (n) {
                'n' => {
                    try out.append(allocator, '\n');
                    i += 1;
                    continue;
                },
                'r' => {
                    try out.append(allocator, '\r');
                    i += 1;
                    continue;
                },
                't' => {
                    try out.append(allocator, '\t');
                    i += 1;
                    continue;
                },
                '"' => {
                    try out.append(allocator, '"');
                    i += 1;
                    continue;
                },
                '\\' => {
                    try out.append(allocator, '\\');
                    i += 1;
                    continue;
                },
                else => {},
            }
        }
        try out.append(allocator, content[i]);
    }
    return out.toOwnedSlice(allocator);
}

/// Busca el artefacto cuyo campo (`path`) coincide exactamente con `name`.
fn findArtifact(artifacts: []const worker_backend.Artifact, name: []const u8) ?worker_backend.Artifact {
    for (artifacts) |a| {
        if (std.mem.eql(u8, a.path, name)) return a;
    }
    return null;
}

/// Resuelve el nombre base seguro del archivo: el BASENAME del campo "filename" si vino y
/// es sano; si no, el id de la tarea. Nunca devuelve algo con separadores ni vacío, de
/// modo que la escritura no pueda escapar del workspace.
fn resolveBasename(task: planner.PlannedTask, artifacts: []const worker_backend.Artifact) []const u8 {
    if (findArtifact(artifacts, "filename")) |fn_art| {
        // D2: `{"filename":"docs/dos.txt"}` conserva su subcarpeta.
        if (safeRelativePath(fn_art.content)) |rel| return rel;
        const b = basename(fn_art.content);
        if (b.len > 0 and isSaneName(b)) return b;
    }
    if (extractRequestedBasename(task.description)) |requested| return requested;
    return task.id;
}

/// Recupera un nombre de archivo explícito de la orden cuando el modelo entrega
/// solo el campo genérico `source`. Acepta únicamente un token basename con una
/// extensión de código conocida; nunca interpreta rutas ni permite escapar del
/// workspace.
fn extractRequestedBasename(description: []const u8) ?[]const u8 {
    var it = std.mem.tokenizeAny(u8, description, " \t\r\n\"'`()[]{}<>,;:");
    while (it.next()) |raw| {
        const candidate = std.mem.trim(u8, raw, ".!?");
        if (!isSaneName(candidate)) continue;
        const ext = std.fs.path.extension(candidate);
        const known = std.ascii.eqlIgnoreCase(ext, ".py") or
            std.ascii.eqlIgnoreCase(ext, ".js") or
            std.ascii.eqlIgnoreCase(ext, ".ts") or
            std.ascii.eqlIgnoreCase(ext, ".zig") or
            std.ascii.eqlIgnoreCase(ext, ".c") or
            std.ascii.eqlIgnoreCase(ext, ".cpp") or
            std.ascii.eqlIgnoreCase(ext, ".rs") or
            std.ascii.eqlIgnoreCase(ext, ".go") or
            std.ascii.eqlIgnoreCase(ext, ".java") or
            std.ascii.eqlIgnoreCase(ext, ".html") or
            std.ascii.eqlIgnoreCase(ext, ".css");
        if (known) return candidate;
    }
    return null;
}

/// Último componente de una ruta (descarta cualquier prefijo con `/` o `\`), sin `..`.
fn basename(p: []const u8) []const u8 {
    var last: usize = 0;
    var i: usize = 0;
    while (i < p.len) : (i += 1) {
        if (p[i] == '/' or p[i] == '\\') last = i + 1;
    }
    const b = std.mem.trim(u8, p[last..], " \t\r\n");
    if (std.mem.eql(u8, b, "..") or std.mem.eql(u8, b, ".")) return "";
    return b;
}

/// Un nombre es "sano" si solo trae caracteres de archivo razonables (sin control chars
/// ni separadores que ya quitamos). Defensa en profundidad sobre `basename`.
fn isSaneName(b: []const u8) bool {
    if (b.len == 0 or b.len > 128) return false;
    // Win32 recorta espacios y puntos de cierre en silencio: la ruta
    // registrada dejaría de coincidir con el archivo real escrito.
    if (b[b.len - 1] == ' ' or b[b.len - 1] == '.') return false;
    for (b) |c| {
        if (c < 0x20) return false;
        if (c == '/' or c == '\\' or c == ':') return false;
    }
    // Nombres de dispositivo Win32: `CreateFileA("NUL.py")` abre el
    // DISPOSITIVO NUL, no crea el archivo — la escritura se descarta y el
    // artefacto «guardado» no existe en disco (falso éxito medido en E3.36:
    // Set-Content "éxito", Test-Path falso, Get-ChildItem lo ve por `\\?\`).
    const stem = if (std.mem.indexOfScalar(u8, b, '.')) |d| b[0..d] else b;
    const devices = [_][]const u8{ "CON", "PRN", "AUX", "NUL", "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9", "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9" };
    for (devices) |d| {
        if (std.ascii.eqlIgnoreCase(stem, d)) return false;
    }
    return true;
}

/// M1: decide QUÉ archivos componen la entrega de una tarea, sin tocar el disco.
/// Es la MISMA lista que escribe `persistTaskFiles` y la que revisa `missingCompanionFile`:
/// si las dos se calcularan por separado, la comprobación de coherencia acabaría mirando
/// algo distinto de lo que se escribe, que es como se cuelan los falsos verdes.
///
/// `fallback_buf` lo aporta el llamador porque el nombre por defecto (id de tarea +
/// extensión inferida) se construye aquí y algún `OutFile` puede apuntar a él: tiene que
/// seguir vivo mientras se use el resultado. El llamador libera el slice devuelto; los
/// `name`/`body` apuntan a `artifacts` o a `fallback_buf`, no se copian.
/// BUG-4: cambia la extension de un nombre por la que corresponde a la prosa.
/// `index.html` de una tarea `auditar` pasa a `index.md`, que ya no pisa el
/// entregable de la tarea que SI programaba. El nombre se acumula en
/// `fallback_buf` porque `OutFile.name` es un slice prestado que debe seguir
/// vivo mientras dure la escritura.
fn renombrarComoProsa(
    allocator: std.mem.Allocator,
    fallback_buf: *std.ArrayList(u8),
    nombre: []const u8,
    contenido: []const u8,
) ![]const u8 {
    const ext = std.fs.path.extension(nombre);
    const nueva = proseExtension(contenido);
    if (std.ascii.eqlIgnoreCase(ext, nueva)) return nombre;
    const raiz = nombre[0 .. nombre.len - ext.len];
    const inicio = fallback_buf.items.len;
    try fallback_buf.appendSlice(allocator, raiz);
    try fallback_buf.appendSlice(allocator, nueva);
    return fallback_buf.items[inicio..];
}

/// `es_auditoria` distingue una auditoria INDEPENDIENTE (la orden
/// entera pide auditar: su informe ES la entrega de prosa y se mide contra la
/// descripcion real de la tarea) del informe INTERNO de auditoria de una orden
/// de codigo (evidencia de producto: la descripcion no mide su contenido). Con
/// `false` el comportamiento es identico al de siempre.
pub fn planOutFiles(
    allocator: std.mem.Allocator,
    task: planner.PlannedTask,
    artifacts: []const worker_backend.Artifact,
    fallback_buf: *std.ArrayList(u8),
    es_auditoria: bool,
) !?[]OutFile {
    var out_files = std.ArrayList(OutFile).empty;
    errdefer out_files.deinit(allocator);

    // Todo nombre/cuerpo que sale de aquí puede vivir como slice DENTRO de
    // `fallback_buf` (nombres de prosa renombrados, el nombre de respaldo, los
    // literales desenrollados de P0.2a). Si un append posterior reallocala el
    // buffer, esos slices quedan colgando — UB silencioso. Se reserva de una
    // vez el máximo posible ANTES de tomar el primer slice: cada nombre mide
    // como mucho path+extensión y cada literal como mucho el cuerpo del
    // artefacto que lo contiene.
    var buf_bound: usize = task.description.len + 64;
    for (artifacts) |a| {
        buf_bound += a.path.len + a.content.len + 64;
    }
    try fallback_buf.ensureUnusedCapacity(allocator, buf_bound);

    // Forma 1: el contrato ya trajo los archivos como campos con nombre
    // (`{"field":"index.html"}`). Va PRIMERO y sin mirar el cuerpo, porque estos
    // artefactos pueden ser cortos y la búsqueda de cuerpo de abajo los descartaría
    // por tamaño antes de llegar aquí.
    const es_prosa = isProseTask(task.task_type);
    var prose_filename: ?[]const u8 = null;
    for (artifacts) |a| {
        // D2 (11-nov): el campo `docs/dos.txt` se escribía como `dos.txt`.
        // Una ruta relativa sana conserva su subcarpeta; lo hostil (.., absoluta,
        // UNC, unidad) sigue reducido a basename (E3.36).
        const nm = outputName(a.path);
        if (nm.len == 0 or !isSaneName(basename(nm)) or !hasKnownCodeExtension(basename(nm))) continue;
        if (std.mem.trim(u8, a.content, " \t\r\n").len == 0) continue;
        if (es_prosa and prose_artifact.invalidReason(nm, a.content, if (task.task_type == .auditar and !es_auditoria) "" else task.description) != null) {
            // A named field can itself contain transport metadata. Keep its
            // name, but resolve the body from the actual document below.
            if (prose_filename != null) return error.InvalidArtifact;
            prose_filename = nm;
            continue;
        }
        // BUG-4 (2026-08-12): una tarea de PROSA no escribe sobre un archivo
        // de codigo, se llame como se llame su campo.
        //
        // Lo cazo el gate: en la orden #241 la tarea `auditar` devolvio su
        // informe con el campo llamado `index.html` —el archivo que estaba
        // auditando— y lo escribio ENCIMA del entregable. Las dos tareas
        // acabaron con el mismo `artifact_path` y el usuario se quedo con un
        // «index.html» que empezaba por «AUDIT: ... Veredicto: FAIL».
        //
        // S9 no lo cubria: solo actuaba al INFERIR la extension por contenido,
        // y aqui el nombre venia dado por el modelo (Forma 1).
        const nombre = if (es_prosa)
            try renombrarComoProsa(allocator, fallback_buf, nm, a.content)
        else
            nm;
        try out_files.append(allocator, .{ .name = nombre, .body = a.content });
    }
    if (prose_filename != null and out_files.items.len > 0) return error.InvalidArtifact;

    if (out_files.items.len == 0) {
        // DOC-01: nombres de campo reconocidos como "cuerpo", para que también se
        // materialicen artefactos de documentación (README, markdown) y de texto.
        const base = prose_filename orelse resolveBasename(task, artifacts);
        const body = findBodyArtifact(task, artifacts, base, es_auditoria) orelse
            blk: {
                for (artifacts) |a| {
                    if (a.content.len > 50 and !std.mem.eql(u8, a.path, "filename") and
                        (!es_prosa or usableProseBody(task, base, a, es_auditoria))) break :blk a;
                }
                // una auditoria independiente entrega prosa; sin cuerpo
                // valido es un entregable invalido como cualquier otra prosa. Solo
                // el informe interno de una orden de codigo (auditar sin es_auditoria)
                // queda fuera de la regla.
                if (es_prosa and (task.task_type != .auditar or es_auditoria) and artifacts.len > 0) return error.InvalidArtifact;
                out_files.deinit(allocator);
                return null;
            };

        const es_prosa_2 = isProseTask(task.task_type);
        const base_ext = std.fs.path.extension(base);

        // BUG-4, SEGUNDA VUELTA (orden #298, 2026-08-14). La Forma 1 renombra
        // la prosa SIEMPRE; esta rama solo miraba `isProseTask` cuando el nombre
        // venia SIN extension. Con extension pegada se respetaba tal cual, y hay
        // DOS maneras de que llegue una de codigo a una tarea `auditar`:
        //
        //   1. El modelo devuelve `{"filename":"index.html"}`.
        //   2. `extractRequestedBasename` la saca de la DESCRIPCION de la tarea,
        //      y la descripcion de una auditoria nombra justo el archivo que
        //      audita. `.html` esta en su lista de extensiones aceptadas.
        //
        // Resultado medido: la tarea 337 (`auditar`) escribio su informe sobre el
        // `index.html` de la tarea 334 (`programar`) — mismo `artifact_path` en la
        // base — y el usuario recibio una pagina web que empezaba por
        // "AUDIT REPORT: ... Status: FAIL".
        //
        // En una tarea de prosa la extension la decide el CONTENIDO, punto. Venga
        // el nombre como venga.
        const raiz = if (es_prosa_2 and base_ext.len > 0)
            base[0 .. base.len - base_ext.len]
        else
            base;
        const ext = if (es_prosa_2)
            proseExtension(body.content)
        else if (base_ext.len > 0)
            ""
        else
            guessExtensionFromContent(body.content) orelse guessExtension(task.description);
        fallback_buf.clearRetainingCapacity();
        try fallback_buf.appendSlice(allocator, raiz);
        try fallback_buf.appendSlice(allocator, ext);
        const fallback_name = fallback_buf.items;

        // Forma 2: un solo campo con los archivos separados por comentarios con el nombre.
        // La misma razon que arriba: una tarea de prosa entrega UN documento.
        // Si su informe cita el archivo auditado con un marcador de nombre
        // (`<!-- index.html -->`), trocearlo lo RECREA con el texto de la
        // auditoria dentro. Trocear es util para el que programa, no para el
        // que audita.
        const split = if (es_prosa_2)
            null
        else
            try splitEmbeddedFiles(allocator, body.content, fallback_name);
        defer if (split) |s| allocator.free(s);
        if (split) |chunks| {
            try out_files.appendSlice(allocator, chunks);
        }

        // Ni una cosa ni la otra: el comportamiento de siempre, un archivo.
        if (out_files.items.len == 0) {
            try out_files.append(allocator, .{ .name = fallback_name, .body = body.content });
        }
    }

    // P0.2a (S22): la regla del prompt no basta con este modelo. Medido en vivo
    // el 2026-09-16: con la instrucción literal del propietario ya en el prompt, la
    // orden #510 (Cohere command-r-plus) entregó `print("HOLA")` como cuerpo de
    // hola.txt, y la #508 un `with open(...) f.write('HOLA')`. Si el archivo de
    // salida es de texto y TODO el cuerpo es una única sentencia generadora,
    // el entregable real es el literal que lleva dentro: se desenrolla aquí.
    //
    // Dos fases a propósito: los literales se decodifican al FINAL de
    // `fallback_buf` anotando OFFSETS —un append puede reallocalar y un slice
    // tomado antes quedaría colgando—; los punteros se materializan solo cuando
    // ya no queda ningún append pendiente.
    if (!taskAsksForCode(task.description)) {
        const LitRange = struct { file: usize, start: usize, len: usize };
        var lits = std.ArrayList(LitRange).empty;
        defer lits.deinit(allocator);
        for (out_files.items, 0..) |*f, i| {
            if (!isTextDeliverable(f.name)) continue;
            const start = fallback_buf.items.len;
            if (try unwrapGeneratorToLiteral(allocator, fallback_buf, f.body)) |lit| {
                try lits.append(allocator, .{ .file = i, .start = start, .len = lit.len });
            }
        }
        for (lits.items) |l| {
            out_files.items[l.file].body = fallback_buf.items[l.start..][0..l.len];
        }
    }

    return try out_files.toOwnedSlice(allocator);
}

fn usableProseBody(task: planner.PlannedTask, name: []const u8, art: worker_backend.Artifact, es_auditoria: bool) bool {
    if (prose_artifact.isMetadataField(art.path)) return false;
    // en una auditoria independiente la descripcion real mide el
    // cuerpo; solo el informe interno de una orden de codigo la vacia.
    const description = if (task.task_type == .auditar and !es_auditoria) "" else task.description;
    return prose_artifact.invalidReason(name, art.content, description) == null;
}

fn findBodyArtifact(task: planner.PlannedTask, artifacts: []const worker_backend.Artifact, name: []const u8, es_auditoria: bool) ?worker_backend.Artifact {
    for ([_][]const u8{ "source", "code", "content", "response", "answer", "result", "summary", "readme", "documentation", "markdown", "document", "doc", "text" }) |field| {
        for (artifacts) |art| {
            if (!std.mem.eql(u8, art.path, field)) continue;
            if (isProseTask(task.task_type) and !usableProseBody(task, name, art, es_auditoria)) continue;
            return art;
        }
    }
    return null;
}

/// P0.2a: nombre de archivo de entregable de TEXTO. Es la misma lista que el
/// prompt nombra al modelo (.txt/.md/.log/.csv o sin extensión).
fn isTextDeliverable(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    if (ext.len == 0) return std.mem.indexOfScalar(u8, name, '.') == null;
    const exts = [_][]const u8{ ".txt", ".md", ".log", ".csv" };
    for (exts) |e| {
        if (std.ascii.eqlIgnoreCase(ext, e)) return true;
    }
    return false;
}

/// P0.2a: la regla del prompt tiene una excepción explícita del propietario: si la
/// tarea pide código, un script o un programa DENTRO del archivo, el cuerpo
/// puede ser código legítimo y no se toca.
fn taskAsksForCode(description: []const u8) bool {
    const needles = [_][]const u8{
        "código",
        "codigo",
        "script",
        "programa",
        "programa que",
        "imprima",
        "imprime",
        "imprimir",
        "print",
        "ejecute",
        "ejecutar",
        "ejecutable",
        "compile",
    };
    for (needles) |n| {
        if (std.ascii.indexOfIgnoreCase(description, n) != null) return true;
    }
    return false;
}

/// P0.2a: si `body` es UNA sentencia cuyo único efecto es emitir un literal —
/// `print("X")`, `console.log('X')`, `echo X`, `with open(...) f.write('X')` —
/// devuelve el literal decodificado (los escapes se materializan en `sink`, que
/// el llamador mantiene vivo junto al resto de nombres/cuerpos derivados).
/// Null si el cuerpo no es exactamente eso: ante la duda se respeta lo que
/// escribió el modelo.
fn unwrapGeneratorToLiteral(
    allocator: std.mem.Allocator,
    sink: *std.ArrayList(u8),
    body: []const u8,
) !?[]const u8 {
    const s = std.mem.trim(u8, body, " \t\r\n");
    if (s.len == 0 or s.len > 8192) return null;

    // Forma A: una sola línea «echo TEXTO» / «puts TEXTO» sin paréntesis.
    if (std.mem.indexOfScalar(u8, s, '\n') == null) {
        inline for (.{ "echo ", "puts " }) |p| {
            if (std.mem.startsWith(u8, s, p)) {
                const arg = std.mem.trim(u8, s[p.len..], " \t");
                if (arg.len > 0) {
                    if (try decodeLiteralArg(allocator, sink, arg)) |r| return r;
                }
            }
        }
    }

    // Forma B: una llamada generadora que ocupa TODO el cuerpo.
    if (try callLiteral(allocator, sink, s)) |r| return r;

    // Forma C: python «open + write» en varias líneas (orden #508).
    if (try openWriteLiteral(allocator, sink, s)) |r| return r;

    return null;
}

/// Hoja conocida de una llamada generadora: print, println, printf, puts,
/// echo, log/info/warn/error (console.*), Print/Println (fmt.*), WriteLine,
/// write (f.write/process.stdout.write).
fn isGeneratorCallee(callee: []const u8) bool {
    if (callee.len == 0) return false;
    for (callee) |ch| {
        const ok = std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '!';
        if (!ok) return false;
    }
    var leaf = callee;
    if (std.mem.lastIndexOfScalar(u8, callee, '.')) |dot| leaf = callee[dot + 1 ..];
    leaf = std.mem.trimEnd(u8, leaf, "!");
    const leaves = [_][]const u8{
        "print",   "println", "printf",    "puts",  "echo",
        "log",     "info",    "warn",      "error", "Print",
        "Println", "Printf",  "WriteLine", "write", "Write",
    };
    for (leaves) |l| {
        if (std.mem.eql(u8, leaf, l)) return true;
    }
    return false;
}

/// `s` = «callee("literal")» opcionalmente terminado en `;`, nada más.
fn callLiteral(
    allocator: std.mem.Allocator,
    sink: *std.ArrayList(u8),
    s: []const u8,
) !?[]const u8 {
    const paren = std.mem.indexOfScalar(u8, s, '(') orelse return null;
    if (!isGeneratorCallee(std.mem.trim(u8, s[0..paren], " \t"))) return null;
    var rest = std.mem.trimStart(u8, s[paren + 1 ..], " \t");
    if (rest.len == 0 or (rest[0] != '"' and rest[0] != '\'')) return null;
    const lit_end = closingQuote(rest) orelse return null;
    // Tras la literal solo se acepta `)`, `;` y blancos hasta el final:
    // un segundo argumento o más código invalidan la forma.
    var tail = std.mem.trim(u8, rest[lit_end + 1 ..], " \t");
    if (tail.len == 0 or tail[0] != ')') return null;
    tail = std.mem.trim(u8, tail[1..], " \t");
    if (tail.len > 0 and tail[0] == ';') tail = std.mem.trim(u8, tail[1..], " \t");
    if (tail.len != 0) return null;
    return try decodeQuotedBody(allocator, sink, rest[1..lit_end]);
}

/// Posición de la comilla de cierre de una cadena que empieza en s[0].
fn closingQuote(s: []const u8) ?usize {
    const q = s[0];
    var i: usize = 1;
    while (i < s.len) : (i += 1) {
        if (s[i] == '\\') {
            i += 1;
            continue;
        }
        if (s[i] == q) return i;
    }
    return null;
}

/// «with open('f','w') as f: f.write('X')» o «f = open(...); f.write('X');
/// f.close()»: la última línea no vacía es el write y todas las demás son
/// plomería de apertura/cierre. Cualquier otra línea descarta la forma.
fn openWriteLiteral(
    allocator: std.mem.Allocator,
    sink: *std.ArrayList(u8),
    s: []const u8,
) !?[]const u8 {
    var saw_open = false;
    var write_line: ?[]const u8 = null;
    var it = std.mem.splitScalar(u8, s, '\n');
    while (it.next()) |line_raw| {
        const line = std.mem.trim(u8, line_raw, " \t\r");
        if (line.len == 0) continue;
        if (std.mem.indexOf(u8, line, "open(") != null) saw_open = true;
        if (std.mem.indexOf(u8, line, ".write(") != null or
            std.mem.indexOf(u8, line, ".writeline(") != null)
        {
            if (write_line != null) return null; // dos writes: no es el patrón
            write_line = line;
            continue;
        }
        if (saw_open and std.mem.indexOf(u8, line, "open(") != null) continue;
        if (std.mem.indexOf(u8, line, ".close()") != null) continue;
        if (std.mem.indexOf(u8, line, "import ") != null) continue;
        return null;
    }
    if (!saw_open) return null;
    const wl = write_line orelse return null;
    const wpos = std.mem.indexOf(u8, wl, ".write") orelse return null;
    const paren = std.mem.indexOfScalarPos(u8, wl, wpos, '(') orelse return null;
    var rest = std.mem.trimStart(u8, wl[paren + 1 ..], " \t");
    if (rest.len == 0 or (rest[0] != '"' and rest[0] != '\'')) return null;
    const lit_end = closingQuote(rest) orelse return null;
    var tail = std.mem.trim(u8, rest[lit_end + 1 ..], " \t");
    if (tail.len == 0 or tail[0] != ')') return null;
    tail = std.mem.trim(u8, tail[1..], " \t");
    if (tail.len > 0 and tail[0] == ';') tail = std.mem.trim(u8, tail[1..], " \t");
    if (tail.len != 0) return null;
    return try decodeQuotedBody(allocator, sink, rest[1..lit_end]);
}

/// Argumento de `echo`/`puts`: literal entre comillas o texto desnudo.
fn decodeLiteralArg(
    allocator: std.mem.Allocator,
    sink: *std.ArrayList(u8),
    arg: []const u8,
) !?[]const u8 {
    if (arg[0] == '"' or arg[0] == '\'') {
        const lit_end = closingQuote(arg) orelse return null;
        if (std.mem.trim(u8, arg[lit_end + 1 ..], " \t;").len != 0) return null;
        return try decodeQuotedBody(allocator, sink, arg[1..lit_end]);
    }
    // Texto desnudo: se rechaza si trae más sintaxis de llamada encima.
    if (std.mem.indexOfScalar(u8, arg, '(') != null) return null;
    const inicio = sink.items.len;
    try sink.appendSlice(allocator, arg);
    return sink.items[inicio..];
}

/// Decodifica el interior de una cadena con escapes comunes. Escape no
/// reconocido → null: mejor dejar el archivo como lo escribió el modelo que
/// adivinar.
fn decodeQuotedBody(
    allocator: std.mem.Allocator,
    sink: *std.ArrayList(u8),
    raw: []const u8,
) !?[]const u8 {
    const inicio = sink.items.len;
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] != '\\') {
            try sink.append(allocator, raw[i]);
            continue;
        }
        i += 1;
        if (i >= raw.len) return null;
        const ch: u8 = switch (raw[i]) {
            'n' => '\n',
            'r' => '\r',
            't' => '\t',
            '\\' => '\\',
            '"' => '"',
            '\'' => '\'',
            '0' => 0,
            else => return null,
        };
        try sink.append(allocator, ch);
    }
    return sink.items[inicio..];
}

/// M4 — UN ENTREGABLE QUE PROMETE ARCHIVOS QUE NO ENTREGA NO ESTÁ BIEN.
///
/// Medido el 2026-08-11 (órdenes #184 y #186): el modelo devuelve un `index.html` con
/// `<link rel="stylesheet" href="styles.css">` y `<script src="script.js">`, no entrega
/// ninguno de los dos, y DevAgents cierra la orden en `done` con la auto-auditoría en
/// verde. El usuario abre una calculadora sin estilos donde no funciona ni un botón.
///
/// Devuelve el nombre de la PRIMERA dependencia local declarada que la entrega no
/// incluye, o null si todo cuadra. El slice apunta al contenido del artefacto, así que
/// vive lo que viva `artifacts`.
///
/// Solo se miran hojas de estilo y scripts, a propósito: son las dos referencias cuya
/// ausencia deja la página inservible. Una `<img>` rota se ve fea pero la página sigue
/// funcionando, y tumbar una tarea entera por un favicon que falta sería peor que el mal
/// que se quiere evitar. Se ignoran también las URLs absolutas, los `data:` y los `#`.
pub fn missingCompanionFile(
    allocator: std.mem.Allocator,
    task: planner.PlannedTask,
    artifacts: []const worker_backend.Artifact,
) !?[]const u8 {
    return missingCompanionFileInOrder(allocator, task, artifacts, &.{});
}

/// M4, ahora mirando la ORDEN entera y no solo la tarea.
///
/// El fallo lo cazo el gate de aceptacion en la orden #218: el plan repartio la
/// web en TRES tareas —index.html, styles.css, script.js— y M4 tumbo la primera
/// por enlazar dos archivos que ella no entregaba... y que sus hermanas SI
/// entregaban. Resultado: `styles.css` y `script.js` en disco y ningun punto de
/// entrada. Una comprobacion pensada para evitar entregas rotas estaba
/// produciendo justo eso.
///
/// `hermanos` son los nombres de archivo que el resto del plan va a producir.
/// Un enlace satisfecho por un hermano es coherente: la entrega es la ORDEN, no
/// la tarea. Lo que se sigue rechazando es lo que no entrega NADIE.
pub fn missingCompanionFileInOrder(
    allocator: std.mem.Allocator,
    task: planner.PlannedTask,
    artifacts: []const worker_backend.Artifact,
    hermanos: []const []const u8,
) !?[]const u8 {
    var fallback_buf = std.ArrayList(u8).empty;
    defer fallback_buf.deinit(allocator);
    const files = (try planOutFiles(allocator, task, artifacts, &fallback_buf, false)) orelse return null;
    defer allocator.free(files);

    for (files) |f| {
        const ext = std.fs.path.extension(f.name);
        if (!std.ascii.eqlIgnoreCase(ext, ".html") and !std.ascii.eqlIgnoreCase(ext, ".htm")) continue;
        var it = LocalRefIterator{ .html = f.body };
        while (it.next()) |ref| {
            var found = false;
            for (files) |g| {
                if (std.ascii.eqlIgnoreCase(basename(g.name), ref)) {
                    found = true;
                    break;
                }
            }
            if (!found) {
                for (hermanos) |h| {
                    if (std.ascii.eqlIgnoreCase(basename(h), ref)) {
                        found = true;
                        break;
                    }
                }
            }
            if (!found) return ref;
        }
    }
    return null;
}

/// Los nombres de archivo que las OTRAS tareas del plan van a producir.
///
/// Se leen de su descripcion, que es donde el planificador los escribe («Crear
/// el archivo styles.css con estilos...»). No es adivinar: es leer el plan que
/// el propio motor genero. Un nombre solo cuenta si tiene extension conocida,
/// asi que una descripcion en prosa no aporta falsos positivos.
///
/// El llamador libera el slice; los nombres son slices PRESTADOS del plan.
/// Con Qué se parte la descripción de una tarea para buscar nombres de archivo.
/// (2026-09-01, orden #406): el planificador escribe las descripciones en
/// markdown con ACENTOS GRAVES («Crear el archivo `styles.css` con...»), y el
/// separador no los quita. La palabra llegaba como `` `styles.css` `` — recorta
/// de `trim` no los tocaba, `hasKnownCodeExtension` no casaba `.css` con el
/// backtick pegado, la hermana jamás se registraba y t1 (index.html) era
/// rechazada por enlazar un archivo que su hermana SÍ entregaba: la orden
/// multiarchivo terminaba 2/3 en frío. La defensa de profundidad correcta no
/// era confiar en que `isSaneName` rechazara el ruido (los backticks le
/// parecen sanos), sino limpiarlos aquí junto a comillas y puntuación.
const SEPARADORES_DESCRIPCION = " \t\r\n,;:()[]{}";
const LIMPIEZA_PALABRA = " \t\r\n.,;:`\"'";

/// Anade `nombre` a la lista si es un nombre de archivo de codigo sano y no
/// esta ya (comparacion sin mayusculas). Se aplica `basename` primero: un
/// `owns` declarado como `src/app.js` respalda un `<script src="app.js">`.
fn appendNombreArchivo(
    out: *std.ArrayList([]const u8),
    allocator: std.mem.Allocator,
    nombre: []const u8,
) !void {
    const limpia = std.mem.trim(u8, basename(nombre), LIMPIEZA_PALABRA);
    if (limpia.len == 0 or !hasKnownCodeExtension(limpia)) return;
    if (!isSaneName(limpia)) return;
    for (out.items) |ya| {
        if (std.ascii.eqlIgnoreCase(ya, limpia)) return;
    }
    try out.append(allocator, limpia);
}

pub fn siblingDeliverables(
    allocator: std.mem.Allocator,
    tasks: []const planner.PlannedTask,
    excluir_id: []const u8,
) ![][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    errdefer out.deinit(allocator);
    for (tasks) |t| {
        if (std.mem.eql(u8, t.id, excluir_id)) continue;
        // B1: `owns` es la fuente AUTORITATIVA - el planificador declara ahi los
        // archivos que produce la tarea. La orden #456 demostro el agujero:
        // descripciones en prosa sin nombre literal ("Crear el archivo CSS para
        // el estilo de la pagina") dejaban ciegas a las hermanas y t1 caia por
        // enlazar un archivo que el plan si entregaba. La descripcion queda como
        // respaldo para planes sin owns declarado.
        for (t.owns) |o| try appendNombreArchivo(&out, allocator, o);
        for (t.contract_fields) |f| {
            if (!std.ascii.eqlIgnoreCase(f.name, "filename")) continue;
            if (f.value) |v| try appendNombreArchivo(&out, allocator, v);
        }
        var it = std.mem.splitAny(u8, t.description, SEPARADORES_DESCRIPCION);
        while (it.next()) |palabra| try appendNombreArchivo(&out, allocator, palabra);
    }
    return out.toOwnedSlice(allocator);
}

/// M4: recorre las etiquetas de un HTML y devuelve, una a una, las rutas LOCALES que
/// declara en `<link rel="stylesheet" href="...">` y `<script src="...">`.
const LocalRefIterator = struct {
    html: []const u8,
    pos: usize = 0,

    fn next(self: *LocalRefIterator) ?[]const u8 {
        while (self.pos < self.html.len) {
            const lt = std.mem.indexOfScalarPos(u8, self.html, self.pos, '<') orelse return null;
            const gt = std.mem.indexOfScalarPos(u8, self.html, lt, '>') orelse return null;
            const tag = self.html[lt..gt];
            self.pos = gt + 1;
            const is_link = std.ascii.startsWithIgnoreCase(tag, "<link") and
                std.ascii.indexOfIgnoreCase(tag, "stylesheet") != null;
            const is_script = std.ascii.startsWithIgnoreCase(tag, "<script");
            if (!is_link and !is_script) continue;
            const val = attributeValue(tag, if (is_link) "href" else "src") orelse continue;
            if (!isLocalRelativeRef(val)) continue;
            return basename(val);
        }
        return null;
    }
};

/// Valor de un atributo dentro de una etiqueta HTML (`href="x"` / `src='x'`).
fn attributeValue(tag: []const u8, name: []const u8) ?[]const u8 {
    var search: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(tag, search, name)) |at| {
        search = at + name.len;
        // El atributo tiene que empezar en un límite: si no, `src` casaría dentro
        // de `data-src` y `href` dentro de cualquier palabra que lo contenga.
        if (at > 0 and (std.ascii.isAlphanumeric(tag[at - 1]) or tag[at - 1] == '-')) continue;
        var i = search;
        while (i < tag.len and (tag[i] == ' ' or tag[i] == '\t')) : (i += 1) {}
        if (i >= tag.len or tag[i] != '=') continue;
        i += 1;
        while (i < tag.len and (tag[i] == ' ' or tag[i] == '\t')) : (i += 1) {}
        if (i >= tag.len) return null;
        const quote = tag[i];
        if (quote != '"' and quote != '\'') continue;
        i += 1;
        const end = std.mem.indexOfScalarPos(u8, tag, i, quote) orelse return null;
        return tag[i..end];
    }
    return null;
}

/// True si la referencia apunta a un archivo del propio entregable (no a la red).
fn isLocalRelativeRef(v: []const u8) bool {
    const t = std.mem.trim(u8, v, " \t\r\n");
    if (t.len == 0) return false;
    if (t[0] == '#' or t[0] == '/') return false;
    if (std.mem.indexOf(u8, t, "://") != null) return false;
    if (std.ascii.startsWithIgnoreCase(t, "data:") or
        std.ascii.startsWithIgnoreCase(t, "mailto:") or
        std.ascii.startsWithIgnoreCase(t, "javascript:")) return false;
    // Sin extensión no es un archivo que podamos exigir.
    return hasKnownCodeExtension(basename(t));
}

/// S9: tareas cuyo entregable es PROSA, no código. Levantado por Gemini el 2026-08-11:
/// una tarea de auditoría entregó su informe («AUDIT: t1.py Verdict: PASS…») en un
/// archivo llamado `t3.py`, porque la extensión se deducía de la descripción de la tarea
/// —que mencionaba Python— y nadie miraba que lo entregado no era código. Un informe con
/// extensión `.py` es exactamente la clase de entregable incoherente que M4 persigue.
fn isProseTask(task_type: anytype) bool {
    return switch (task_type) {
        .auditar, .documentar, .investigar, .resumir => true,
        else => false,
    };
}

/// S9: extensión para un entregable en prosa. Markdown si trae marcas de markdown,
/// texto plano si no. Nunca una extensión de código.
fn proseExtension(content: []const u8) []const u8 {
    const t = std.mem.trim(u8, content, " \t\r\n");
    if (t.len == 0) return ".txt";
    if (t[0] == '#') return ".md";
    if (std.mem.indexOf(u8, content, "\n## ") != null or
        std.mem.indexOf(u8, content, "\n# ") != null or
        std.mem.indexOf(u8, content, "```") != null or
        std.mem.indexOf(u8, content, "\n- ") != null) return ".md";
    return ".txt";
}

/// M1: extensiones que damos por «de archivo» al reconocer un nombre suelto. Es la guarda
/// que impide que un comentario cualquiera (`// TODO: revisar esto`) se lea como el nombre
/// de un archivo y parta la entrega en dos.
/// ¿Este texto es un NOMBRE DE ARCHIVO reconocible? Público porque el validador
/// de contratos del superagente necesita la misma noción: un campo `filename`
/// obligatorio queda satisfecho si algún artefacto ya se llama como un archivo.
pub fn hasKnownCodeExtension(name: []const u8) bool {
    const ext = std.fs.path.extension(name);
    if (ext.len < 2) return false;
    const known = [_][]const u8{
        ".py",  ".js",   ".mjs",  ".cjs", ".ts",   ".tsx",  ".jsx", ".html", ".htm",
        ".css", ".scss", ".json", ".zig", ".c",    ".h",    ".cpp", ".hpp",  ".cc",
        ".rs",  ".go",   ".java", ".cs",  ".rb",   ".php",  ".sh",  ".bat",  ".ps1",
        ".sql", ".md",   ".txt",  ".yml", ".yaml", ".toml", ".xml", ".svg",
    };
    for (known) |k| {
        if (std.ascii.eqlIgnoreCase(ext, k)) return true;
    }
    return false;
}

/// M1: si la línea ENTERA es un comentario que solo contiene un nombre de archivo,
/// devuelve ese nombre. Es la forma en que los modelos separan varios archivos cuando el
/// contrato solo les ofrece un campo: `<!-- index.html -->`, `/* styles.css */`,
/// `// script.js`, `# main.py`, `=== app.zig ===`. Cualquier otra cosa devuelve null.
fn markerFilename(line_raw: []const u8) ?[]const u8 {
    const line = std.mem.trim(u8, line_raw, " \t\r");
    if (line.len == 0) return null;
    const Pair = struct { open: []const u8, close: []const u8 };
    // El orden importa: `/*` antes que `//`, y los delimitados antes que los de línea.
    const pairs = [_]Pair{
        .{ .open = "<!--", .close = "-->" },
        .{ .open = "/*", .close = "*/" },
        .{ .open = "===", .close = "===" },
        .{ .open = "---", .close = "---" },
        .{ .open = "//", .close = "" },
        .{ .open = "#", .close = "" },
    };
    var inner: ?[]const u8 = null;
    for (pairs) |p| {
        if (!std.mem.startsWith(u8, line, p.open)) continue;
        var rest = line[p.open.len..];
        if (p.close.len > 0) {
            if (rest.len < p.close.len or !std.mem.endsWith(u8, rest, p.close)) continue;
            rest = rest[0 .. rest.len - p.close.len];
        }
        inner = std.mem.trim(u8, rest, " \t=-*/");
        break;
    }
    const candidate = inner orelse return null;
    const name = basename(candidate);
    if (name.len == 0 or !isSaneName(name) or !hasKnownCodeExtension(name)) return null;
    return name;
}

/// M1: parte un contenido único en los archivos que lleva dentro, usando los marcadores
/// de `markerFilename`. Devuelve null cuando no hay nada que partir; el llamador libera
/// SOLO el slice (los `name`/`body` apuntan al contenido original, no se copian).
///
/// Dos reglas, deliberadamente conservadoras, porque partir de más es peor que no partir:
///   - Con DOS marcadores o más se parte de verdad: eso ya no es un comentario suelto.
///   - Con UNO solo se parte únicamente si es la primera línea no vacía; entonces su
///     único efecto es dar nombre al archivo (orden #184: el modelo abrió con
///     `<!-- index.html -->` y el archivo acabó llamándose `t1.js`).
/// Un `# config.json` perdido a mitad de un script de Python no cumple ninguna de las dos
/// y se ignora, que es justo lo que debe pasar.
fn splitEmbeddedFiles(
    allocator: std.mem.Allocator,
    content: []const u8,
    fallback_name: []const u8,
) !?[]OutFile {
    const Mark = struct { name: []const u8, line_start: usize, body_start: usize };
    var marks = std.ArrayList(Mark).empty;
    defer marks.deinit(allocator);

    var pos: usize = 0;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |line| {
        const line_start = pos;
        pos = @min(pos + line.len + 1, content.len);
        const name = markerFilename(line) orelse continue;
        try marks.append(allocator, .{ .name = name, .line_start = line_start, .body_start = pos });
    }
    if (marks.items.len == 0) return null;

    if (marks.items.len == 1) {
        // Solo vale si el marcador ABRE el contenido; si no, es un comentario cualquiera.
        const head = std.mem.trim(u8, content[0..marks.items[0].line_start], " \t\r\n");
        if (head.len != 0) return null;
    }

    var out = std.ArrayList(OutFile).empty;
    errdefer out.deinit(allocator);

    // Lo que haya ANTES del primer marcador no se tira nunca: si trae algo, se guarda
    // aparte con el nombre de siempre. Perder contenido silenciosamente es el fallo que
    // este código viene a arreglar, no uno que pueda permitirse reintroducir.
    const preamble = content[0..marks.items[0].line_start];
    if (std.mem.trim(u8, preamble, " \t\r\n").len > 0) {
        try out.append(allocator, .{ .name = fallback_name, .body = preamble });
    }

    for (marks.items, 0..) |m, i| {
        const end = if (i + 1 < marks.items.len) marks.items[i + 1].line_start else content.len;
        const body = content[@min(m.body_start, end)..end];
        if (std.mem.trim(u8, body, " \t\r\n").len == 0) continue;
        try out.append(allocator, .{ .name = m.name, .body = body });
    }
    if (out.items.len == 0) {
        out.deinit(allocator);
        return null;
    }
    return try out.toOwnedSlice(allocator);
}

/// FIX-7 / EXT-01: detecta la extensión por el CONTENIDO del artefacto (más fiable que la
/// descripción). Devuelve null si no reconoce el lenguaje. El orden importa: marcadores
/// distintivos y específicos antes que genéricos; markdown al final (un comentario `#` de
/// Python no debe confundirse con un encabezado markdown).
fn guessExtensionFromContent(content: []const u8) ?[]const u8 {
    const has = struct {
        fn f(h: []const u8, n: []const u8) bool {
            return std.mem.indexOf(u8, h, n) != null;
        }
    }.f;
    // S1 — HTML y CSS van PRIMERO, antes que JavaScript. Medido el 2026-08-11 en la orden
    // #183: una página web completa se guardó como `t1.js` porque la primera regla que
    // casaba era la de JavaScript, por el `function ` del `<script>` incrustado. Una web
    // con JS dentro es una web; un JS nunca empieza por `<!DOCTYPE html>`.
    const trimmed_head = std.mem.trimStart(u8, content, " \t\r\n");
    if (std.ascii.startsWithIgnoreCase(trimmed_head, "<!doctype html") or
        std.ascii.startsWithIgnoreCase(trimmed_head, "<html") or
        has(content, "</html>") or has(content, "</body>") or has(content, "</div>")) return ".html";
    if (has(content, "@media ") or has(content, "!important") or
        (has(content, "{") and (has(content, "margin:") or has(content, "padding:") or
            has(content, "font-family:") or has(content, "background-color:")))) return ".css";
    // Zig
    if (has(content, "@import(") or has(content, "pub fn ") or has(content, "const std =")) return ".zig";
    // C++ (antes que C)
    if (has(content, "std::") or has(content, "#include <iostream>") or has(content, "using namespace ")) return ".cpp";
    // C
    if (has(content, "#include <") or has(content, "int main(")) return ".c";
    // Rust
    if (has(content, "fn main()") or has(content, "println!") or has(content, "let mut ")) return ".rs";
    // Go
    if (has(content, "package main") or has(content, "func main()") or has(content, "fmt.")) return ".go";
    // Python (marcadores distintivos; evita decidir solo por "import")
    if (has(content, "def ") or has(content, "unittest") or has(content, "print(") or has(content, "if __name__") or has(content, "self.")) return ".py";
    // JavaScript / TypeScript
    if (has(content, "function ") or has(content, "console.log") or has(content, "=>") or has(content, "require(") or has(content, "module.exports")) return ".js";
    // Markdown / documentación (al final)
    if (std.mem.startsWith(u8, std.mem.trim(u8, content, " \t\r\n"), "#") or has(content, "```")) return ".md";
    return null;
}

/// Extensión por lenguaje detectado en la descripción (solo si el filename no traía una).
/// Heurística de cortesía; ante la duda, `.txt`.
fn guessExtension(description: []const u8) []const u8 {
    const Map = struct { kw: []const u8, ext: []const u8 };
    const table = [_]Map{
        .{ .kw = "python", .ext = ".py" },
        .{ .kw = "javascript", .ext = ".js" },
        .{ .kw = "typescript", .ext = ".ts" },
        .{ .kw = "rust", .ext = ".rs" },
        .{ .kw = "golang", .ext = ".go" },
        .{ .kw = "c++", .ext = ".cpp" },
        .{ .kw = "cpp", .ext = ".cpp" },
        .{ .kw = "c#", .ext = ".cs" },
        .{ .kw = "csharp", .ext = ".cs" },
        .{ .kw = "java", .ext = ".java" },
        .{ .kw = "kotlin", .ext = ".kt" },
        .{ .kw = "swift", .ext = ".swift" },
        .{ .kw = "ruby", .ext = ".rb" },
        .{ .kw = "php", .ext = ".php" },
        .{ .kw = "bash", .ext = ".sh" },
        .{ .kw = "shell", .ext = ".sh" },
        .{ .kw = "html", .ext = ".html" },
        .{ .kw = "zig", .ext = ".zig" },
        .{ .kw = "código c ", .ext = ".c" },
        .{ .kw = "programa en c ", .ext = ".c" },
        .{ .kw = "script en c ", .ext = ".c" },
    };
    var buf: [256]u8 = undefined;
    const n = @min(description.len, buf.len);
    for (description[0..n], 0..) |c, i| buf[i] = std.ascii.toLower(c);
    const low = buf[0..n];
    for (table) |m| {
        if (std.mem.indexOf(u8, low, m.kw) != null) return m.ext;
    }
    return ".txt";
}

// ── Tests ──────────────────────────────────────────────────────────────

test "basename descarta prefijos de ruta y rechaza .." {
    try std.testing.expectEqualStrings("calc.py", basename("C:\\Workspace\\x\\Desktop\\calc.py"));
    try std.testing.expectEqualStrings("calc.py", basename("a/b/calc.py"));
    try std.testing.expectEqualStrings("", basename("a/b/.."));
    try std.testing.expectEqualStrings("sum.js", basename("sum.js"));
}

test "isSaneName rechaza separadores y control chars" {
    try std.testing.expect(isSaneName("calc.py"));
    try std.testing.expect(!isSaneName("a/b.py"));
    try std.testing.expect(!isSaneName("c:evil"));
    try std.testing.expect(!isSaneName(""));
}

test "E2E-RESULT: resolveBasename preserva el filename pedido aunque el artefacto sea source" {
    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "Crea un script llamado e4_sol_test.py que imprima OK",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    const artifacts = [_]worker_backend.Artifact{.{ .path = "source", .content = "print('OK')" }};
    try std.testing.expectEqualStrings("e4_sol_test.py", resolveBasename(task, &artifacts));
}

test "guessExtension detecta lenguaje en la descripcion" {
    try std.testing.expectEqualStrings(".py", guessExtension("Crea un script en Python que sume"));
    try std.testing.expectEqualStrings(".js", guessExtension("una funcion JavaScript"));
    try std.testing.expectEqualStrings(".txt", guessExtension("algo sin lenguaje claro"));
}

test "unescapeIfDoubleEscaped decodifica solo cuando hay doble-escape" {
    const a = std.testing.allocator;
    // Doble-escapado: una línea física con \n y \" literales → se decodifica.
    const esc = try unescapeIfDoubleEscaped(a, "print(\\\"hi\\\")\\nprint(1)");
    defer a.free(esc);
    try std.testing.expectEqualStrings("print(\"hi\")\nprint(1)", esc);

    // Código con saltos reales: NO se toca (un \n dentro de una cadena Python se respeta).
    const ok = try unescapeIfDoubleEscaped(a, "x = 'a\\nb'\nprint(x)");
    defer a.free(ok);
    try std.testing.expectEqualStrings("x = 'a\\nb'\nprint(x)", ok);
}

test "resolveBasename usa filename si es sano, si no el task id" {
    const arts_with_name = [_]worker_backend.Artifact{
        .{ .path = "source", .content = "x" },
        .{ .path = "filename", .content = "../../escape.py" },
    };
    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "py",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    // filename trae ".." → basename lo reduce a "escape.py" (sano), se usa ese.
    try std.testing.expectEqualStrings("escape.py", resolveBasename(task, &arts_with_name));

    const arts_bad = [_]worker_backend.Artifact{.{ .path = "source", .content = "x" }};
    try std.testing.expectEqualStrings("t1", resolveBasename(task, &arts_bad));
}

test "DOC-01: persistTask materializa artefacto bajo campo 'readme'" {
    const allocator = std.testing.allocator;
    const arts = [_]worker_backend.Artifact{
        .{ .path = "readme", .content = "# Mi Modulo\nUso: ...\n" },
        .{ .path = "filename", .content = "README.md" },
    };
    const task = planner.PlannedTask{ .id = "t3", .task_type = .documentar, .department = "documentacion", .description = "doc", .contract_fields = &.{}, .depends_on = &.{} };
    const saved = (try persistTask(allocator, 99777, task, &arts)) orelse return error.TestUnexpectedResult;
    defer allocator.free(saved);
    {
        const saved_z = try allocator.dupeZ(u8, saved);
        defer allocator.free(saved_z);
        _ = DeleteFileA(saved_z);
    }
    try std.testing.expect(std.mem.indexOf(u8, saved, "README.md") != null);
}

test "EXT-01: persistTask infiere .py por contenido cuando no hay filename" {
    const allocator = std.testing.allocator;
    // Test Python REAL pero SIN campo "filename" y con descripción que NO dice "python".
    const arts = [_]worker_backend.Artifact{
        .{ .path = "source", .content = "import unittest\nfrom textutils import slugify\n\nclass T(unittest.TestCase):\n    def test_x(self):\n        self.assertTrue(True)\n" },
    };
    const task = planner.PlannedTask{ .id = "t2", .task_type = .testear, .department = "testing", .description = "pruebas unitarias que importen del modulo", .contract_fields = &.{}, .depends_on = &.{} };
    const saved = (try persistTask(allocator, 99888, task, &arts)) orelse return error.TestUnexpectedResult;
    defer allocator.free(saved);
    {
        const z = try allocator.dupeZ(u8, saved);
        defer allocator.free(z);
        _ = DeleteFileA(z.ptr);
    }
    try std.testing.expect(std.mem.endsWith(u8, saved, ".py")); // extensión inferida por contenido, no .txt
}

test "P1-ARTIFACTS: persistTask writes to orden-N directory visible to list_artifacts" {
    const allocator = std.testing.allocator;
    const arts = [_]worker_backend.Artifact{
        .{ .path = "source", .content = "print('MCP OK')\n" },
        .{ .path = "filename", .content = "mcp_smoke.py" },
    };
    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "create file",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    const saved = (try persistTask(allocator, 99901, task, &arts)) orelse return error.TestUnexpectedResult;
    defer allocator.free(saved);

    // Verify path follows the expected pattern: devagents-workspace\orden-99901\mcp_smoke.py
    try std.testing.expect(std.mem.indexOf(u8, saved, "orden-99901") != null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "mcp_smoke.py") != null);

    // Cleanup
    {
        const z = try allocator.dupeZ(u8, saved);
        defer allocator.free(z);
        _ = DeleteFileA(z.ptr);
    }
}

test "E5.20 E-129 ronda2: selección junction elegida o S2 conserva raíz previa" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, junctions o cmd.exe); omitida en Linux");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "outside");
    try tmp.dir.createDirPath(io, "project");
    const parent = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(parent);
    const outside = try tmp.dir.realPathFileAlloc(io, "outside", a);
    defer a.free(outside);
    const selected = try tmp.dir.realPathFileAlloc(io, "project", a);
    defer a.free(selected);
    const alias = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "alias", .{parent});
    defer a.free(alias);
    try createJunction(a, alias, outside);
    defer tmp.dir.deleteDir(io, "alias") catch |e| std.debug.print("workspace junction cleanup: {s}\n", .{@errorName(e)});
    const direct_s2 = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{parent});
    defer a.free(direct_s2);
    try createJunction(a, direct_s2, outside);
    defer tmp.dir.deleteDir(io, "devagents-workspace") catch |e| std.debug.print("workspace direct S2 cleanup: {s}\n", .{@errorName(e)});
    const s2 = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{selected});
    defer a.free(s2);
    try createJunction(a, s2, outside);
    defer tmp.dir.deleteDir(io, "project/devagents-workspace") catch |e| std.debug.print("workspace S2 cleanup: {s}\n", .{@errorName(e)});
    try setWorkspaceRootChecked(outside);
    defer setWorkspaceRoot(WORKSPACE_ROOT);
    var before_buf: [4096]u8 = undefined;
    const before = getWorkspaceRoot(&before_buf);
    try std.testing.expectError(error.SandboxDenied, setWorkspaceRootChecked(alias));
    try std.testing.expectError(error.SandboxDenied, setWorkspaceRootChecked(selected));
    try std.testing.expectError(error.SandboxDenied, setWorkspaceRootChecked(direct_s2));
    var after_buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(before, getWorkspaceRoot(&after_buf));
}

test "E5.20 E-129 ronda2: selección copiada sobrevive setter concurrente" {
    try setWorkspaceRootChecked((if (@import("builtin").os.tag == .windows) "C:\\beats-fixture-reader" else "/beats-fixture-reader"));
    defer setWorkspaceRoot(WORKSPACE_ROOT);
    var buf: [4096]u8 = undefined;
    const root = getWorkspaceRoot(&buf);
    // No desreferenciar memoria ajena: la versión vieja falla aquí sin UAF.
    try std.testing.expect(@intFromPtr(root.ptr) >= @intFromPtr(&buf) and
        @intFromPtr(root.ptr) + root.len <= @intFromPtr(&buf) + buf.len);
    const Setter = struct {
        fn run() void {
            for (0..128) |_| setWorkspaceRoot((if (@import("builtin").os.tag == .windows) "C:\\beats-fixture-writer" else "/beats-fixture-writer"));
        }
    };
    const writer = try std.Thread.spawn(.{}, Setter.run, .{});
    writer.join();
    try std.testing.expectEqualStrings((if (@import("builtin").os.tag == .windows) "C:\\beats-fixture-reader" else "/beats-fixture-reader"), root);
}

test "E5.20 E-129: raíz inválida o relativa ajena se rechaza sin cambiar selección" {
    setWorkspaceRoot(WORKSPACE_ROOT);
    defer setWorkspaceRoot(WORKSPACE_ROOT);
    var before_buf: [4096]u8 = undefined;
    const before = effectiveRoot(&before_buf);
    try std.testing.expectError(error.InvalidWorkspaceRoot, setWorkspaceRootChecked(""));
    try std.testing.expectError(error.WorkspaceReanchorDenied, setWorkspaceRootChecked(".."));
    const long = [_]u8{'x'} ** 4001;
    try std.testing.expectError(error.InvalidWorkspaceRoot, setWorkspaceRootChecked(&long));
    var after_buf: [4096]u8 = undefined;
    try std.testing.expectEqualStrings(before, effectiveRoot(&after_buf));
}

test "D1-FIX2: pathIsWithin — dentro, igual, fuera y límite de separador" {
    try std.testing.expect(pathIsWithin("C:\\ws\\orden-1", "C:\\ws"));
    try std.testing.expect(pathIsWithin("C:\\ws", "C:\\ws")); // igual
    try std.testing.expect(pathIsWithin("c:/WS/sub", "C:\\ws")); // case + separador mixto
    try std.testing.expect(!pathIsWithin("C:\\Workspace\\Usuario\\Desktop\\Proyectos", "C:\\ws\\devagents-workspace"));
    try std.testing.expect(!pathIsWithin("C:\\wsbar", "C:\\ws")); // límite: no matchea prefijo parcial
    try std.testing.expect(!pathIsWithin("C:\\w", "C:\\ws")); // child más corto
}

test "S2: una carpeta elegida por el usuario NO recibe los artefactos a pelo" {
    // Orden #215, lanzada desde la cabina: los cuatro archivos acabaron en la
    // RAÍZ del repositorio, junto al código fuente. `core.workspace.set` —el
    // diálogo de "elige carpeta de trabajo"— sustituía la raíz entera, segmento
    // `devagents-workspace` incluido, y una carpeta elegida sí cae dentro del
    // cwd, asi que se usaba tal cual.
    const allocator = std.testing.allocator;
    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = GetCurrentDirectoryA(@intCast(cwd_buf.len), &cwd_buf);
    if (cwd_len == 0 or cwd_len >= cwd_buf.len) return error.SkipZigTest;
    const cwd_str = cwd_buf[0..cwd_len];

    // El usuario elige el propio proyecto: dentro del cwd, sin segmento propio.
    setWorkspaceRoot(cwd_str);
    defer setWorkspaceRoot(WORKSPACE_ROOT);

    const arts = [_]worker_backend.Artifact{
        .{ .path = "index.html", .content = "<!DOCTYPE html><html><body>hola</body></html>\n" },
    };
    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "una web",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    const saved = (try persistTask(allocator, 99903, task, &arts)) orelse return error.TestUnexpectedResult;
    defer allocator.free(saved);
    defer {
        const z = allocator.dupeZ(u8, saved) catch null;
        if (z) |zz| {
            _ = DeleteFileA(zz.ptr);
            allocator.free(zz);
        }
    }

    const marker = WORKSPACE_ROOT ++ std.fs.path.sep_str ++ "orden-99903";
    try std.testing.expect(std.mem.indexOf(u8, saved, marker) != null);
}

test "SEC2 R6 H6: estrechar se compara con la raiz efectiva, no con la seleccionada" {
    defer setWorkspaceRoot(WORKSPACE_ROOT);
    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = GetCurrentDirectoryA(@intCast(cwd_buf.len), &cwd_buf);
    if (cwd_len == 0 or cwd_len >= cwd_buf.len) return error.SkipZigTest;
    // Seleccion `<cwd>`: la efectiva es `<cwd>\devagents-workspace`.
    setWorkspaceRoot(cwd_buf[0..cwd_len]);
    var sub: [4200]u8 = undefined;
    // Hermana de la efectiva: dentro de la seleccion, FUERA de la efectiva.
    const sibling = try std.fmt.bufPrint(&sub, "{s}" ++ std.fs.path.sep_str ++ "otra", .{cwd_buf[0..cwd_len]});
    try std.testing.expect(!narrowsEffectiveRoot(sibling));
    // Subcarpeta de la efectiva (y la propia efectiva): se admite.
    var sub2: [4200]u8 = undefined;
    const inside = try std.fmt.bufPrint(&sub2, "{s}" ++ std.fs.path.sep_str ++ "{s}" ++ std.fs.path.sep_str ++ "estrecha", .{ cwd_buf[0..cwd_len], WORKSPACE_ROOT });
    try std.testing.expect(narrowsEffectiveRoot(inside));
    var sub3: [4200]u8 = undefined;
    const same = try std.fmt.bufPrint(&sub3, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ cwd_buf[0..cwd_len], WORKSPACE_ROOT });
    try std.testing.expect(narrowsEffectiveRoot(same));
    try std.testing.expect(!narrowsEffectiveRoot(""));
    try std.testing.expect(!narrowsEffectiveRoot(".."));
}

test "S2: una raíz que YA es devagents-workspace no se duplica" {
    var buf: [4096]u8 = undefined;
    setWorkspaceRoot(WORKSPACE_ROOT);
    defer setWorkspaceRoot(WORKSPACE_ROOT);
    const root = effectiveRoot(&buf);
    // Termina en el segmento, y solo una vez.
    try std.testing.expect(std.mem.endsWith(u8, root, WORKSPACE_ROOT));
    const doble = WORKSPACE_ROOT ++ "\\" ++ WORKSPACE_ROOT;
    try std.testing.expect(std.mem.indexOf(u8, root, doble) == null);
}

test "E5.20 E-129: carpeta absoluta elegida fuera del cwd conserva S2 y sandbox" {
    const allocator = std.testing.allocator;
    // El cwd de la cabina instalada es la aplicación, no el proyecto elegido.
    // El test anterior sólo exigía el segmento S2: también pasaba reanclando
    // al proyecto equivocado. Usamos un proyecto temporal ajeno al cwd.
    var temp_buf: [4096]u8 = undefined;
    const temp_len = GetTempPathA(temp_buf.len, &temp_buf);
    if (temp_len == 0 or temp_len >= temp_buf.len) return error.TestUnexpectedResult;
    const project = try std.fmt.allocPrint(allocator, "{s}beats-e520-root-{d}", .{ temp_buf[0..temp_len], GetTickCount64() });
    defer allocator.free(project);
    const project_z = try allocator.dupeZ(u8, project);
    defer allocator.free(project_z);
    try std.testing.expect(CreateDirectoryA(project_z, null) != 0);
    defer _ = RemoveDirectoryA(project_z);
    setWorkspaceRoot(project);
    defer setWorkspaceRoot(WORKSPACE_ROOT); // restaurar default para otros tests
    var root_buf: [4096]u8 = undefined;
    const root = effectiveRoot(&root_buf);
    const expected = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ project, WORKSPACE_ROOT });
    defer allocator.free(expected);
    if (!std.mem.eql(u8, expected, root)) std.debug.print("E5.20 selected={s} effective={s}\n", .{ project, root });
    try std.testing.expectEqualStrings(expected, root);
    const arts = [_]worker_backend.Artifact{
        .{ .path = "source", .content = "print('reanchor')\n" },
        .{ .path = "filename", .content = "reanchor.py" },
    };
    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "create file",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    const saved = (try persistTask(allocator, 99902, task, &arts)) orelse return error.TestUnexpectedResult;
    defer allocator.free(saved);
    // Mantener las aserciones S2 originales y exigir además el proyecto elegido:
    // el aislamiento es <selección>\devagents-workspace\orden-99902, no el cwd.
    try std.testing.expect(pathIsWithin(saved, expected));
    var sb = try @import("sandbox.zig").Sandbox.init(allocator, root);
    defer sb.deinit();
    try std.testing.expect(sb.isAllowed(saved));
    try std.testing.expect(!sb.isAllowed(project));
    try std.testing.expect(std.mem.indexOf(u8, saved, "orden-99902") != null);
    const marker = WORKSPACE_ROOT ++ std.fs.path.sep_str ++ "orden-99902";
    try std.testing.expect(std.mem.indexOf(u8, saved, marker) != null);
    {
        const z = try allocator.dupeZ(u8, saved);
        defer allocator.free(z);
        _ = DeleteFileA(z.ptr);
    }
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    try std.Io.Dir.cwd().deleteTree(threaded.io(), expected);
}

// ── M1 / S1: entrega multi-archivo y extensiones web ───────────────────

test "S1: una pagina web con JS dentro es .html, no .js" {
    // Orden #183 (2026-08-11): esto se guardaba como `t1.js` porque la regla de
    // JavaScript casaba con el `function` del <script> incrustado.
    const web =
        \\<!DOCTYPE html>
        \\<html lang="es"><head><title>x</title></head>
        \\<body><div id="a"></div>
        \\<script>function go(){ console.log("hi"); }</script>
        \\</body></html>
    ;
    try std.testing.expectEqualStrings(".html", guessExtensionFromContent(web).?);

    const css =
        \\body { font-family: Arial, sans-serif; background-color: #111; }
        \\@media (max-width: 600px) { body { padding: 0; } }
    ;
    try std.testing.expectEqualStrings(".css", guessExtensionFromContent(css).?);

    // Y un JavaScript de verdad sigue siendo .js.
    try std.testing.expectEqualStrings(".js", guessExtensionFromContent("function sum(a,b){ return a+b; }\nmodule.exports = sum;").?);
}

test "M1: markerFilename reconoce el nombre y rechaza el ruido" {
    try std.testing.expectEqualStrings("index.html", markerFilename("<!-- index.html -->").?);
    try std.testing.expectEqualStrings("styles.css", markerFilename("/* styles.css */").?);
    try std.testing.expectEqualStrings("script.js", markerFilename("// script.js").?);
    try std.testing.expectEqualStrings("main.py", markerFilename("# main.py").?);
    try std.testing.expectEqualStrings("app.zig", markerFilename("=== app.zig ===").?);
    try std.testing.expectEqualStrings("a.js", markerFilename("  <!--  src/a.js  -->  ").?);

    // Sin extensión conocida, con separadores, o texto normal: no es un marcador.
    try std.testing.expect(markerFilename("// TODO: revisar esto") == null);
    try std.testing.expect(markerFilename("# Calculadora") == null);
    try std.testing.expect(markerFilename("const x = 1;") == null);
    try std.testing.expect(markerFilename("") == null);
    try std.testing.expect(markerFilename("<!-- ../../escape.py -->").?.len == "escape.py".len);
}

test "M1: splitEmbeddedFiles parte los tres archivos de una web" {
    const a = std.testing.allocator;
    const content =
        \\<!-- index.html -->
        \\<!DOCTYPE html>
        \\<html></html>
        \\
        \\<!-- styles.css -->
        \\body { margin: 0; }
        \\
        \\<!-- script.js -->
        \\console.log("ok");
    ;
    const files = (try splitEmbeddedFiles(a, content, "t1.txt")) orelse return error.TestUnexpectedResult;
    defer a.free(files);
    try std.testing.expectEqual(@as(usize, 3), files.len);
    try std.testing.expectEqualStrings("index.html", files[0].name);
    try std.testing.expectEqualStrings("styles.css", files[1].name);
    try std.testing.expectEqualStrings("script.js", files[2].name);
    try std.testing.expect(std.mem.indexOf(u8, files[0].body, "<!DOCTYPE html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, files[1].body, "margin: 0") != null);
    try std.testing.expect(std.mem.indexOf(u8, files[2].body, "console.log") != null);
    // El marcador no se cuela dentro del cuerpo del archivo anterior.
    try std.testing.expect(std.mem.indexOf(u8, files[0].body, "styles.css") == null);
}

test "M1: un marcador suelto a mitad de archivo NO parte nada" {
    const a = std.testing.allocator;
    // Un script de Python que menciona un .json en un comentario: es UN archivo.
    const content =
        \\import json
        \\
        \\# config.json
        \\with open("config.json") as f:
        \\    pass
    ;
    try std.testing.expect((try splitEmbeddedFiles(a, content, "t1.py")) == null);
}

test "M1: un unico marcador al principio solo da nombre al archivo" {
    const a = std.testing.allocator;
    // Orden #184: el modelo abrió con el nombre y el archivo acabó llamándose `t1.js`.
    const content =
        \\<!-- index.html -->
        \\<!DOCTYPE html>
        \\<html></html>
    ;
    const files = (try splitEmbeddedFiles(a, content, "t1.js")) orelse return error.TestUnexpectedResult;
    defer a.free(files);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("index.html", files[0].name);
    try std.testing.expect(std.mem.indexOf(u8, files[0].body, "<!DOCTYPE html>") != null);
}

test "M1: el texto anterior al primer marcador no se pierde" {
    const a = std.testing.allocator;
    const content =
        \\Aqui tienes los archivos:
        \\<!-- index.html -->
        \\<html></html>
        \\<!-- app.js -->
        \\var x = 1;
    ;
    const files = (try splitEmbeddedFiles(a, content, "t9.txt")) orelse return error.TestUnexpectedResult;
    defer a.free(files);
    try std.testing.expectEqual(@as(usize, 3), files.len);
    try std.testing.expectEqualStrings("t9.txt", files[0].name);
    try std.testing.expect(std.mem.indexOf(u8, files[0].body, "Aqui tienes") != null);
}

test "M1: persistTaskFiles escribe los tres archivos de la orden #183" {
    const allocator = std.testing.allocator;
    const content =
        \\<!-- index.html -->
        \\<!DOCTYPE html>
        \\<html><head><link rel="stylesheet" href="styles.css"></head>
        \\<body><script src="script.js"></script></body></html>
        \\
        \\<!-- styles.css -->
        \\body { margin: 0; background-color: #111; }
        \\
        \\<!-- script.js -->
        \\function go(){ console.log("ok"); }
    ;
    const arts = [_]worker_backend.Artifact{.{ .path = "source", .content = content }};
    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "una pagina web con dos trenes",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    const paths = (try persistTaskFiles(allocator, 99903, task, &arts)) orelse return error.TestUnexpectedResult;
    defer {
        for (paths) |p| {
            const z = allocator.dupeZ(u8, p) catch continue;
            _ = DeleteFileA(z.ptr);
            allocator.free(z);
            allocator.free(p);
        }
        allocator.free(paths);
    }
    try std.testing.expectEqual(@as(usize, 3), paths.len);
    try std.testing.expect(std.mem.endsWith(u8, paths[0], "index.html"));
    try std.testing.expect(std.mem.endsWith(u8, paths[1], "styles.css"));
    try std.testing.expect(std.mem.endsWith(u8, paths[2], "script.js"));
}

test "M1: varios campos con nombre de archivo se escriben todos" {
    const allocator = std.testing.allocator;
    const arts = [_]worker_backend.Artifact{
        .{ .path = "main.c", .content = "int main(){return 0;}\n" },
        .{ .path = "test.c", .content = "#include <assert.h>\n" },
    };
    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "programa en c ",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    const paths = (try persistTaskFiles(allocator, 99904, task, &arts)) orelse return error.TestUnexpectedResult;
    defer {
        for (paths) |p| {
            const z = allocator.dupeZ(u8, p) catch continue;
            _ = DeleteFileA(z.ptr);
            allocator.free(z);
            allocator.free(p);
        }
        allocator.free(paths);
    }
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expect(std.mem.endsWith(u8, paths[0], "main.c"));
    try std.testing.expect(std.mem.endsWith(u8, paths[1], "test.c"));
}

// ── M4: coherencia del entregable ──────────────────────────────────────

fn m4TestTask() planner.PlannedTask {
    return .{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "una calculadora web",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
}

test "M4: attributeValue lee el atributo y no casa dentro de otra palabra" {
    try std.testing.expectEqualStrings("styles.css", attributeValue("<link rel=\"stylesheet\" href=\"styles.css\">", "href").?);
    try std.testing.expectEqualStrings("app.js", attributeValue("<script src='app.js'>", "src").?);
    try std.testing.expectEqualStrings("a.js", attributeValue("<script  src = \"a.js\" >", "src").?);
    // `src` dentro de `data-src` no cuenta como el atributo `src`.
    try std.testing.expect(attributeValue("<script data-src=\"x.js\">", "src") == null);
    try std.testing.expect(attributeValue("<script>", "src") == null);
}

test "M4: isLocalRelativeRef distingue archivo propio de URL externa" {
    try std.testing.expect(isLocalRelativeRef("styles.css"));
    try std.testing.expect(isLocalRelativeRef("./js/app.js"));
    try std.testing.expect(!isLocalRelativeRef("https://cdn.tld/a.css"));
    try std.testing.expect(!isLocalRelativeRef("//cdn.tld/a.css"));
    try std.testing.expect(!isLocalRelativeRef("/absoluta/a.css"));
    try std.testing.expect(!isLocalRelativeRef("data:text/css,body{}"));
    try std.testing.expect(!isLocalRelativeRef("#seccion"));
    try std.testing.expect(!isLocalRelativeRef(""));
}

test "M4: un HTML que promete styles.css sin entregarlo se delata" {
    const a = std.testing.allocator;
    // Es literalmente la entrega de la orden #184.
    const html = "<!DOCTYPE html>\n<html><head>\n<link rel=\"stylesheet\" href=\"styles.css\">\n</head>\n<body><div class=\"calculator\"></div>\n<script src=\"script.js\"></script>\n</body></html>\n";
    const arts = [_]worker_backend.Artifact{.{ .path = "source", .content = html }};
    const missing = (try missingCompanionFile(a, m4TestTask(), &arts)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("styles.css", missing);
}

test "M4: si los tres archivos vienen, no falta nada" {
    const a = std.testing.allocator;
    const html = "<!DOCTYPE html>\n<html><head>\n<link rel=\"stylesheet\" href=\"styles.css\">\n</head>\n<body>\n<script src=\"script.js\"></script>\n</body></html>\n";
    const arts = [_]worker_backend.Artifact{
        .{ .path = "index.html", .content = html },
        .{ .path = "styles.css", .content = "body { margin: 0; }\n" },
        .{ .path = "script.js", .content = "console.log('ok');\n" },
    };
    try std.testing.expect((try missingCompanionFile(a, m4TestTask(), &arts)) == null);
}

test "M4: un HTML autocontenido no promete nada y pasa" {
    const a = std.testing.allocator;
    const html = "<!DOCTYPE html>\n<html><head><style>body{margin:0}</style></head>\n<body><script>console.log(1);</script></body></html>\n";
    const arts = [_]worker_backend.Artifact{.{ .path = "source", .content = html }};
    try std.testing.expect((try missingCompanionFile(a, m4TestTask(), &arts)) == null);
}

test "M4: una CDN externa o una imagen que falta NO tumban la tarea" {
    const a = std.testing.allocator;
    // CSS por CDN, favicon ausente e imagen ausente: la pagina sigue siendo usable.
    const html = "<!DOCTYPE html>\n<html><head>\n<link rel=\"stylesheet\" href=\"https://cdn.tld/bootstrap.css\">\n<link rel=\"icon\" href=\"favicon.ico\">\n</head>\n<body><img src=\"logo.png\">\n<script>var x=1;</script>\n</body></html>\n";
    const arts = [_]worker_backend.Artifact{.{ .path = "source", .content = html }};
    try std.testing.expect((try missingCompanionFile(a, m4TestTask(), &arts)) == null);
}

test "M4: el troceado por marcadores tambien queda cubierto" {
    const a = std.testing.allocator;
    // Un solo campo con dos archivos dentro: el HTML pide script.js y SÍ viene.
    const content = "<!-- index.html -->\n<html><body><script src=\"script.js\"></script></body></html>\n<!-- script.js -->\nconsole.log('ok');\n";
    const arts = [_]worker_backend.Artifact{.{ .path = "source", .content = content }};
    try std.testing.expect((try missingCompanionFile(a, m4TestTask(), &arts)) == null);

    // Y si el segundo archivo no viene, se detecta.
    const solo = "<!-- index.html -->\n<html><body><script src=\"script.js\"></script></body></html>\n";
    const arts2 = [_]worker_backend.Artifact{.{ .path = "source", .content = solo }};
    const missing = (try missingCompanionFile(a, m4TestTask(), &arts2)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("script.js", missing);
}

// ── S9: un informe en prosa no es codigo ───────────────────────────────

test "S9: auditar y documentar son tareas de prosa; programar y testear no" {
    try std.testing.expect(isProseTask(model_router.TaskType.auditar));
    try std.testing.expect(isProseTask(model_router.TaskType.documentar));
    try std.testing.expect(isProseTask(model_router.TaskType.investigar));
    try std.testing.expect(isProseTask(model_router.TaskType.resumir));
    try std.testing.expect(!isProseTask(model_router.TaskType.programar));
    try std.testing.expect(!isProseTask(model_router.TaskType.testear));
    try std.testing.expect(!isProseTask(model_router.TaskType.ejecutar));
}

test "S9: proseExtension elige markdown o texto, nunca codigo" {
    try std.testing.expectEqualStrings(".md", proseExtension("# Informe\nTodo bien.\n"));
    try std.testing.expectEqualStrings(".md", proseExtension("Resumen\n\n## Detalle\nx\n"));
    try std.testing.expectEqualStrings(".md", proseExtension("Notas\n- primero\n- segundo\n"));
    try std.testing.expectEqualStrings(".txt", proseExtension("AUDIT: t1.py Verdict: PASS. Todo correcto.\n"));
    try std.testing.expectEqualStrings(".txt", proseExtension(""));
}

test "S9: el informe de auditoria ya no se guarda como .py" {
    const allocator = std.testing.allocator;
    // Es literalmente lo que levanto Gemini el 2026-08-11: la descripcion mencionaba
    // Python, asi que la extension salia `.py` sobre un informe en prosa.
    const arts = [_]worker_backend.Artifact{
        .{ .path = "verdict", .content = "AUDIT: t1.py Verdict: PASS. El script suma dos numeros y los imprime correctamente. No se detectan defectos.\n" },
    };
    const task = planner.PlannedTask{
        .id = "t3",
        .task_type = .auditar,
        .department = "auditoria",
        .description = "Auditar el script de Python que suma dos numeros",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    const saved = (try persistTask(allocator, 99905, task, &arts)) orelse return error.TestUnexpectedResult;
    defer allocator.free(saved);
    {
        const z = try allocator.dupeZ(u8, saved);
        defer allocator.free(z);
        _ = DeleteFileA(z.ptr);
    }
    try std.testing.expect(std.mem.endsWith(u8, saved, ".txt"));
    try std.testing.expect(!std.mem.endsWith(u8, saved, ".py"));
}

test "S9: una tarea de programar en Python sigue dando .py" {
    const allocator = std.testing.allocator;
    const arts = [_]worker_backend.Artifact{
        .{ .path = "source", .content = "def sumar(a, b):\n    return a + b\n\nprint(sumar(2, 3))\n" },
    };
    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "Escribe un script en Python que sume dos numeros",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    const saved = (try persistTask(allocator, 99906, task, &arts)) orelse return error.TestUnexpectedResult;
    defer allocator.free(saved);
    {
        const z = try allocator.dupeZ(u8, saved);
        defer allocator.free(z);
        _ = DeleteFileA(z.ptr);
    }
    try std.testing.expect(std.mem.endsWith(u8, saved, ".py"));
}

// ── La verdad de una orden esta en el disco ────────────────────────────

const FindFirstFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindFirstFileA(lpFileName: [*:0]const u8, lpFindFileData: *WIN32_FIND_DATAA) windows.HANDLE;
}.FindFirstFileA else @import("providers").posix_files.FindFirstFileA;
const FindNextFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindNextFileA(hFindFile: windows.HANDLE, lpFindFileData: *WIN32_FIND_DATAA) c_int;
}.FindNextFileA else @import("providers").posix_files.FindNextFileA;
const FindClose = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn FindClose(hFindFile: windows.HANDLE) c_int;
}.FindClose else @import("providers").posix_files.FindClose;

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
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;

/// Un archivo realmente presente en la carpeta de una orden.
pub const OrderFile = struct {
    name: []const u8,
    size: u64,

    pub fn deinit(self: OrderFile, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
    }
};

/// Lista los archivos que EXISTEN en `<workspace>/orden-<id>/`.
///
/// Existe para poder contrastar lo que el motor CUENTA con lo que el motor HIZO.
/// Las ordenes #201 y #202 del 2026-08-11 cerraron en `done` sin un solo evento
/// `file_written` y con un `index.html` de 234 bytes perfectamente escrito en disco:
/// quien inspeccionaba la traza concluia «no entrego nada» y se equivocaba. El disco
/// no opina; si hay archivo, hay archivo.
///
/// El llamador libera cada `OrderFile` y el slice.
pub fn listOrderFiles(allocator: std.mem.Allocator, order_id: i64) ![]OrderFile {
    var er_buf: [4096]u8 = undefined;
    const ws_abs = effectiveRoot(&er_buf);
    // D2: la orden corre en su espacio con git y escribe en la raíz de ese
    // espacio (persistTaskFiles): su salida es lo que cambió en él.
    if (order_root_len > 0 and isGitSpaceRoot(ws_abs)) return listSpaceOrderFiles(allocator, ws_abs, order_id);
    {
        const dir = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "orden-{d}", .{ ws_abs, order_id });
        defer allocator.free(dir);
        const found = try listOrderFilesIn(allocator, dir);
        if (found.len > 0) return found;
        allocator.free(found);
    }

    // Segunda ubicación posible: el directorio de trabajo a secas. Cuando la cabina
    // tiene fijado el proyecto abierto como workspace, los artefactos acaban en
    // `<proyecto>\orden-N\` y NO bajo `devagents-workspace\`. La orden #201 del
    // 2026-08-11 tenía ahí su `index.html` mientras el contraste informaba
    // «(ninguno)» por mirar solo la primera. Mirar las dos cuesta un FindFirstFile.
    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = GetCurrentDirectoryA(@intCast(cwd_buf.len), &cwd_buf);
    if (cwd_len > 0 and cwd_len < cwd_buf.len) {
        const dir2 = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "orden-{d}", .{ cwd_buf[0..cwd_len], order_id });
        defer allocator.free(dir2);
        const found2 = try listOrderFilesIn(allocator, dir2);
        if (found2.len > 0) return found2;
        allocator.free(found2);
    }

    // Tercera ubicacion (B3): si la orden corrio dentro de su space, los
    // artefactos estan en <root>\.devagents\spaces\orden-<id>\orden-<id>
    // (o en `.beats\spaces`, el nombre de antes del 10-nov). El nombre del
    // space es deterministico, asi que bastan dos busquedas mas — sin
    // arrastrar la DB hasta aqui.
    // D2: con git, la salida está en la raíz del espacio (lo que cambió en él).
    for ([_][]const u8{ ".devagents", ".beats" }) |internal| {
        const space = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "orden-{d}", .{ ws_abs, internal, order_id });
        defer allocator.free(space);
        if (isGitSpaceRoot(space)) {
            const found_space = try listSpaceOrderFiles(allocator, space, order_id);
            if (found_space.len > 0) return found_space;
            allocator.free(found_space);
        }
    }
    const dir3 = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ ".devagents" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "orden-{d}" ++ std.fs.path.sep_str ++ "orden-{d}", .{ ws_abs, order_id, order_id });
    defer allocator.free(dir3);
    const found3 = try listOrderFilesIn(allocator, dir3);
    if (found3.len > 0) return found3;
    allocator.free(found3);
    const dir4 = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ ".beats" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "orden-{d}" ++ std.fs.path.sep_str ++ "orden-{d}", .{ ws_abs, order_id, order_id });
    defer allocator.free(dir4);
    return listOrderFilesIn(allocator, dir4);
}

/// D2: archivos de una orden que trabajó en el espacio con git `space`:
/// lo que git ve cambiado o nuevo en él, unido al paseo de `orden-<id>\`
/// (best_of_n.changedFiles, el mismo conjunto que integra la delegación).
/// Los de `orden-<id>\` (informes de auditoría) se nombran sin ese prefijo,
/// como antes. Sin git utilizable queda el paseo de `orden-<id>\`.
fn listSpaceOrderFiles(allocator: std.mem.Allocator, space: []const u8, order_id: i64) ![]OrderFile {
    var prefix_buf: [64]u8 = undefined;
    const prefix = try std.fmt.bufPrint(&prefix_buf, "orden-{d}", .{order_id});
    const sets = best_of_n.changedFiles(allocator, space, prefix) orelse {
        const legacy = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ space, prefix });
        defer allocator.free(legacy);
        return listOrderFilesIn(allocator, legacy);
    };
    defer best_of_n.freeChangedSets(allocator, sets);
    var out = std.ArrayList(OrderFile).empty;
    errdefer {
        for (out.items) |f| f.deinit(allocator);
        out.deinit(allocator);
    }
    for (sets.copy) |raw| {
        const rel = try allocator.dupe(u8, raw);
        defer allocator.free(rel);
        std.mem.replaceScalar(u8, rel, '\\', '/');
        const shown = if (rel.len > prefix.len + 1 and std.mem.startsWith(u8, rel, prefix) and rel[prefix.len] == '/') rel[prefix.len + 1 ..] else rel;
        const abs = try std.fmt.allocPrintSentinel(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ space, rel }, 0);
        defer allocator.free(abs);
        std.mem.replaceScalar(u8, abs, '/', '\\');
        var data: WIN32_FIND_DATAA = undefined;
        const h = FindFirstFileA(abs.ptr, &data);
        // Borrado o ilegible entre el diff y aquí: no es un archivo presente.
        if (h == INVALID_HANDLE_VALUE) continue;
        _ = FindClose(h);
        if (data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0) continue;
        const owned = try allocator.dupe(u8, shown);
        errdefer allocator.free(owned);
        const size = (@as(u64, data.nFileSizeHigh) << 32) | @as(u64, data.nFileSizeLow);
        try out.append(allocator, .{ .name = owned, .size = size });
    }
    return out.toOwnedSlice(allocator);
}

/// Lee el CONTENIDO de un archivo entregado por una orden.
///
/// El gate de aceptación lo necesita porque contar archivos y mirar su tamaño no
/// basta: la orden #183 entregó un `.js` de 2.605 bytes que resultó ser tres
/// archivos concatenados, y por tamaño y extensión habría pasado. Hay que abrir
/// y mirar dentro. Busca en las DOS ubicaciones posibles, igual que
/// `listOrderFiles`, y por el mismo motivo.
///
/// El llamador libera lo devuelto. Devuelve null si no existe.
pub fn readOrderFile(allocator: std.mem.Allocator, order_id: i64, name: []const u8) !?[]u8 {
    var er_buf: [4096]u8 = undefined;
    const ws_abs = effectiveRoot(&er_buf);
    // D2: `name` es la ruta relativa que da listOrderFiles; nunca sale de la
    // carpeta en la que se busca.
    if (name.len == 0 or std.fs.path.isAbsolute(name) or std.mem.indexOfScalar(u8, name, ':') != null) return null;
    {
        var parts = std.mem.splitAny(u8, name, "/\\");
        while (parts.next()) |part| if (std.mem.eql(u8, part, "..")) return null;
    }
    if (order_root_len > 0 and isGitSpaceRoot(ws_abs)) {
        const p0 = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ ws_abs, name });
        defer allocator.free(p0);
        if (try readWholeFile(allocator, p0)) |body| return body;
    }
    for ([_][]const u8{ ".devagents", ".beats" }) |internal| {
        const space = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "orden-{d}", .{ ws_abs, internal, order_id });
        defer allocator.free(space);
        if (!isGitSpaceRoot(space)) continue;
        const ps = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ space, name });
        defer allocator.free(ps);
        if (try readWholeFile(allocator, ps)) |body| return body;
    }
    {
        const p1 = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "orden-{d}" ++ std.fs.path.sep_str ++ "{s}", .{ ws_abs, order_id, name });
        defer allocator.free(p1);
        if (try readWholeFile(allocator, p1)) |body| return body;
    }
    var cwd_buf: [4096]u8 = undefined;
    const cwd_len = GetCurrentDirectoryA(@intCast(cwd_buf.len), &cwd_buf);
    if (cwd_len > 0 and cwd_len < cwd_buf.len) {
        const p2 = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "orden-{d}" ++ std.fs.path.sep_str ++ "{s}", .{ cwd_buf[0..cwd_len], order_id, name });
        defer allocator.free(p2);
        if (try readWholeFile(allocator, p2)) |body| return body;
    }
    // Tercera ubicacion (B3): el space de la orden — mismo convenio que
    // listOrderFiles (`.devagents` y, para lo de antes del 10-nov, `.beats`).
    const p3 = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ ".devagents" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "orden-{d}" ++ std.fs.path.sep_str ++ "orden-{d}" ++ std.fs.path.sep_str ++ "{s}", .{ ws_abs, order_id, order_id, name });
    defer allocator.free(p3);
    if (try readWholeFile(allocator, p3)) |body| return body;
    const p4 = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ ".beats" ++ std.fs.path.sep_str ++ "spaces" ++ std.fs.path.sep_str ++ "orden-{d}" ++ std.fs.path.sep_str ++ "orden-{d}" ++ std.fs.path.sep_str ++ "{s}", .{ ws_abs, order_id, order_id, name });
    defer allocator.free(p4);
    return readWholeFile(allocator, p4);
}

/// Tope de lectura. Un entregable de codigo por encima de 4 MB no es un
/// entregable, es otra cosa; y el gate solo necesita mirar dentro.
const MAX_LECTURA: usize = 4 << 20;

fn readWholeFile(allocator: std.mem.Allocator, path: []const u8) !?[]u8 {
    const path_z = try allocator.dupeZ(u8, path);
    defer allocator.free(path_z);
    const h = CreateFileA(path_z.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    if (h == INVALID_HANDLE_VALUE) return null;
    defer _ = CloseHandle(h);
    var buf = try allocator.alloc(u8, MAX_LECTURA);
    errdefer allocator.free(buf);
    var leidos: u32 = 0;
    if (ReadFile(h, buf.ptr, @intCast(buf.len), &leidos, null) == 0) {
        allocator.free(buf);
        return null;
    }
    return allocator.realloc(buf, leidos) catch buf[0..leidos];
}

/// Como `listOrderFiles` pero sobre una carpeta EXPLÍCITA.
///
/// Hace falta porque la carpeta de una orden no siempre está donde el proceso que
/// pregunta cree: la cabina fija el workspace al proyecto abierto y escribe en
/// `<proyecto>\orden-N\`, mientras que el CLI, lanzado desde otro sitio, calcula
/// `<cwd>\devagents-workspace\orden-N\`. Suponer una de las dos hacía que la
/// reconciliación informara «(ninguno)» sobre órdenes con archivos perfectamente
/// escritos — el mismo error que ese contraste existe para evitar.
pub fn listOrderFilesIn(allocator: std.mem.Allocator, dir_abs: []const u8) ![]OrderFile {
    var out = std.ArrayList(OrderFile).empty;
    errdefer {
        for (out.items) |f| f.deinit(allocator);
        out.deinit(allocator);
    }
    try listOrderFilesLevel(allocator, dir_abs, "", 0, &out);
    return out.toOwnedSlice(allocator);
}

/// D2: la salida de una tarea puede traer subcarpetas (`docs/dos.txt`); se
/// listan con su ruta relativa y '/'. Los puntos de reanálisis (junctions,
/// symlinks) no se recorren: lo que cuelga de ellos no está en la carpeta.
const ORDER_FILES_MAX_DEPTH: usize = 8;

fn listOrderFilesLevel(allocator: std.mem.Allocator, dir_abs: []const u8, rel_dir: []const u8, depth: usize, out: *std.ArrayList(OrderFile)) !void {
    const pattern = try std.fmt.allocPrintSentinel(allocator, "{s}" ++ std.fs.path.sep_str ++ "*", .{dir_abs}, 0);
    defer allocator.free(pattern);
    var data: WIN32_FIND_DATAA = undefined;
    const h = FindFirstFileA(pattern.ptr, &data);
    if (h == INVALID_HANDLE_VALUE) return;
    defer _ = FindClose(h);

    while (true) {
        const zlen = std.mem.indexOfScalar(u8, &data.cFileName, 0) orelse data.cFileName.len;
        const name = data.cFileName[0..zlen];
        const is_dir = data.dwFileAttributes & FILE_ATTRIBUTE_DIRECTORY != 0;
        const is_reparse = data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT_FLAG != 0;
        if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
            const rel = if (rel_dir.len == 0) try allocator.dupe(u8, name) else try std.fmt.allocPrint(allocator, "{s}/{s}", .{ rel_dir, name });
            defer allocator.free(rel);
            if (is_dir) {
                if (!is_reparse and depth + 1 < ORDER_FILES_MAX_DEPTH) {
                    const sub = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ dir_abs, name });
                    defer allocator.free(sub);
                    try listOrderFilesLevel(allocator, sub, rel, depth + 1, out);
                }
            } else {
                const owned = try allocator.dupe(u8, rel);
                errdefer allocator.free(owned);
                const size = (@as(u64, data.nFileSizeHigh) << 32) | @as(u64, data.nFileSizeLow);
                try out.append(allocator, .{ .name = owned, .size = size });
            }
        }
        if (FindNextFileA(h, &data) == 0) break;
    }
}

const FILE_ATTRIBUTE_REPARSE_POINT_FLAG: u32 = 0x400;

test "listOrderFiles ve lo que persistTaskFiles escribio" {
    const allocator = std.testing.allocator;
    const content = "<!-- index.html -->\n<html><head><link rel=\"stylesheet\" href=\"a.css\"></head></html>\n<!-- a.css -->\nbody { margin: 0; }\n";
    const arts = [_]worker_backend.Artifact{.{ .path = "source", .content = content }};
    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "una web",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    const paths = (try persistTaskFiles(allocator, 99907, task, &arts)) orelse return error.TestUnexpectedResult;
    defer {
        for (paths) |p| {
            const z = allocator.dupeZ(u8, p) catch continue;
            _ = DeleteFileA(z.ptr);
            allocator.free(z);
            allocator.free(p);
        }
        allocator.free(paths);
    }

    const files = try listOrderFiles(allocator, 99907);
    defer {
        for (files) |f| f.deinit(allocator);
        allocator.free(files);
    }
    try std.testing.expectEqual(@as(usize, 2), files.len);
    var vio_html = false;
    var vio_css = false;
    for (files) |f| {
        if (std.mem.eql(u8, f.name, "index.html")) vio_html = true;
        if (std.mem.eql(u8, f.name, "a.css")) vio_css = true;
        try std.testing.expect(f.size > 0);
    }
    try std.testing.expect(vio_html);
    try std.testing.expect(vio_css);
}

test "listOrderFiles de una orden que no existe devuelve vacio, no error" {
    const allocator = std.testing.allocator;
    const files = try listOrderFiles(allocator, 99908123);
    defer allocator.free(files);
    try std.testing.expectEqual(@as(usize, 0), files.len);
}

/// Solo para tests de otros modulos: borrar un artefacto que el test acaba de crear.
/// El `DeleteFileA` de este archivo es privado y no tiene por que dejar de serlo.
pub fn deleteFileForTest(path_z: [*:0]const u8) c_int {
    return DeleteFileA(path_z);
}

test "M4-ORDEN: un enlace que entrega una tarea HERMANA es coherente (orden #218)" {
    const a = std.testing.allocator;
    // El index.html enlaza styles.css y script.js, que este mismo entregable no
    // trae. Aislado es incoherente; dentro de un plan que los reparte en tres
    // tareas, no lo es — y tumbarlo dejaba la web sin punto de entrada.
    const arts = [_]worker_backend.Artifact{
        .{ .path = "index.html", .content = "<html><head><link rel=\"stylesheet\" href=\"styles.css\"></head><body><script src=\"script.js\"></script></body></html>" },
    };
    const hermanos = [_][]const u8{ "styles.css", "script.js" };
    try std.testing.expect((try missingCompanionFileInOrder(a, m4TestTask(), &arts, &hermanos)) == null);
    // Sin hermanos que lo respalden, sigue siendo incoherente.
    const solo = (try missingCompanionFileInOrder(a, m4TestTask(), &arts, &.{})) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("styles.css", solo);
}

test "M4-ORDEN: un enlace que NADIE entrega se sigue rechazando" {
    const a = std.testing.allocator;
    const arts = [_]worker_backend.Artifact{
        .{ .path = "index.html", .content = "<html><head><link rel=\"stylesheet\" href=\"olvidado.css\"></head><body></body></html>" },
    };
    const hermanos = [_][]const u8{ "styles.css", "script.js" };
    const falta = (try missingCompanionFileInOrder(a, m4TestTask(), &arts, &hermanos)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("olvidado.css", falta);
}

test "SIBLINGS: los nombres salen de la descripcion del plan, y solo los que son archivos" {
    const a = std.testing.allocator;
    const tareas = [_]planner.PlannedTask{
        .{ .id = "t1", .task_type = .programar, .department = "programacion", .description = "Crear el archivo index.html con la estructura", .contract_fields = &.{}, .depends_on = &.{} },
        .{ .id = "t2", .task_type = .programar, .department = "programacion", .description = "Crear el archivo styles.css con estilos modernos y responsive", .contract_fields = &.{}, .depends_on = &.{} },
        .{ .id = "t3", .task_type = .programar, .department = "programacion", .description = "Crear el archivo script.js con la logica de la lista", .contract_fields = &.{}, .depends_on = &.{} },
    };
    const h = try siblingDeliverables(a, &tareas, "t1");
    defer a.free(h);
    // La propia tarea se excluye: su index.html no puede respaldarse a si mismo.
    try std.testing.expectEqual(@as(usize, 2), h.len);
    try std.testing.expectEqualStrings("styles.css", h[0]);
    try std.testing.expectEqualStrings("script.js", h[1]);
}

test "SIBLINGS: una descripcion en prosa no aporta nombres inventados" {
    const a = std.testing.allocator;
    const tareas = [_]planner.PlannedTask{
        .{ .id = "t1", .task_type = .auditar, .department = "auditoria", .description = "Auditar el manejo de errores y documentar los riesgos encontrados", .contract_fields = &.{}, .depends_on = &.{} },
    };
    const h = try siblingDeliverables(a, &tareas, "otro");
    defer a.free(h);
    try std.testing.expectEqual(@as(usize, 0), h.len);
}

test "E-57: los acentos graves del markdown del planificador no ciegan a las hermanas (orden #406)" {
    const a = std.testing.allocator;
    // Descripciones TAL CUAL las escribió el planificador LLM en la #406:
    // markdown con backticks. El separador no los quitaba, la palabra llegaba
    // como "`styles.css`", la extensión no casaba y t1 era rechazada por
    // enlazar un archivo que t2 SÍ entregaba — multiarchivo 2/3 en frío.
    const tareas = [_]planner.PlannedTask{
        .{ .id = "t1", .task_type = .programar, .department = "programacion", .description = "Crear el archivo `index.html` para la calculadora web, incluyendo referencias a `styles.css` y `script.js`.", .contract_fields = &.{}, .depends_on = &.{} },
        .{ .id = "t2", .task_type = .programar, .department = "programacion", .description = "Crear el archivo `styles.css` con los estilos para la calculadora web, incluyendo el diseño general, la pantalla y los botones.", .contract_fields = &.{}, .depends_on = &.{} },
        .{ .id = "t3", .task_type = .programar, .department = "programacion", .description = "Crear el archivo `script.js` con la lógica JavaScript para la calculadora web, incluyendo el manejo de entradas de dígitos, operaciones, punto decimal y reseteo.", .contract_fields = &.{}, .depends_on = &.{} },
    };
    const h = try siblingDeliverables(a, &tareas, "t1");
    defer a.free(h);
    try std.testing.expectEqual(@as(usize, 2), h.len);
    try std.testing.expectEqualStrings("styles.css", h[0]);
    try std.testing.expectEqualStrings("script.js", h[1]);

    // Y con las hermanas registradas, el index.html de t1 es COHERENTE:
    // antes este test no existía y el rechazo solo se veía en producción.
    const arts = [_]worker_backend.Artifact{
        .{ .path = "index.html", .content = "<html><head><link rel=\"stylesheet\" href=\"styles.css\"></head><body><script src=\"script.js\"></script></body></html>" },
    };
    try std.testing.expect((try missingCompanionFileInOrder(a, m4TestTask(), &arts, h)) == null);
}

test "E-57: comillas dobles y simples también se limpian" {
    const a = std.testing.allocator;
    const tareas = [_]planner.PlannedTask{
        .{ .id = "t2", .task_type = .programar, .department = "programacion", .description = "Escribir \"styles.css\" con los estilos y 'script.js' con la lógica.", .contract_fields = &.{}, .depends_on = &.{} },
    };
    const h = try siblingDeliverables(a, &tareas, "t1");
    defer a.free(h);
    try std.testing.expectEqual(@as(usize, 2), h.len);
    try std.testing.expectEqualStrings("styles.css", h[0]);
    try std.testing.expectEqualStrings("script.js", h[1]);
}

test "E-57: un enlace a un archivo que NADIE menciona en el plan sigue incoherente" {
    const a = std.testing.allocator;
    // El fix de limpieza no puede abrir la puerta falsos verdes: un ref que
    // ninguna hermana declara (con o sin backticks) se sigue rechazando.
    const arts = [_]worker_backend.Artifact{
        .{ .path = "index.html", .content = "<html><head><link rel=\"stylesheet\" href=\"fantasma.css\"></head><body></body></html>" },
    };
    const tareas = [_]planner.PlannedTask{
        .{ .id = "t2", .task_type = .programar, .department = "programacion", .description = "Crear el archivo `styles.css` con los estilos.", .contract_fields = &.{}, .depends_on = &.{} },
    };
    const h = try siblingDeliverables(a, &tareas, "t1");
    defer a.free(h);
    const falta = (try missingCompanionFileInOrder(a, m4TestTask(), &arts, h)) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings("fantasma.css", falta);
}

test "ORDEN-456: owns declarado respalda el enlace aunque la descripcion no nombre el archivo" {
    const a = std.testing.allocator;
    // Orden real #456 (2026-09-15): el planificador escribio descripciones en
    // prosa SIN el nombre literal ("Crear el archivo CSS para el estilo de la
    // pagina") y declaro los archivos solo en `owns`. Antes del fix,
    // siblingDeliverables solo leia la prosa: t1 caia por artifact_incoherent
    // al enlazar styles.css, t2/t3 arrastraban dependency_failed, y la orden
    // solo cerro tras un ciclo de correccion completo.
    var owns_css = [_][]const u8{"styles.css"};
    var owns_js = [_][]const u8{"app.js"};
    var deps_t2 = [_][]const u8{"t1"};
    var deps_t3 = [_][]const u8{"t2"};
    const tareas = [_]planner.PlannedTask{
        .{ .id = "t1", .task_type = .programar, .department = "programacion", .description = "Crear la pagina web de lista de tareas en HTML, CSS y JavaScript.", .contract_fields = &.{}, .depends_on = &.{} },
        .{ .id = "t2", .task_type = .programar, .department = "programacion", .description = "Crear el archivo CSS para el estilo de la pagina.", .contract_fields = &.{}, .depends_on = &deps_t2, .owns = &owns_css },
        .{ .id = "t3", .task_type = .programar, .department = "programacion", .description = "Crear el archivo JavaScript para la funcionalidad de la pagina.", .contract_fields = &.{}, .depends_on = &deps_t3, .owns = &owns_js },
    };
    const h = try siblingDeliverables(a, &tareas, "t1");
    defer a.free(h);
    try std.testing.expectEqual(@as(usize, 2), h.len);
    try std.testing.expectEqualStrings("styles.css", h[0]);
    try std.testing.expectEqualStrings("app.js", h[1]);

    // Y con las hermanas declaradas, el index.html de t1 es COHERENTE.
    const arts = [_]worker_backend.Artifact{
        .{ .path = "index.html", .content = "<html><head><link rel=\"stylesheet\" href=\"styles.css\"></head><body><script src=\"app.js\"></script></body></html>" },
    };
    try std.testing.expect((try missingCompanionFileInOrder(a, m4TestTask(), &arts, h)) == null);
}

test "ORDEN-456: contract_fields filename tambien declara al hermano" {
    const a = std.testing.allocator;
    var cf = [_]planner.ContractField{.{ .name = "filename", .field_type = .string, .required = true, .value = "styles.css" }};
    const tareas = [_]planner.PlannedTask{
        .{ .id = "t2", .task_type = .programar, .department = "programacion", .description = "Escribir los estilos de la pagina.", .contract_fields = &cf, .depends_on = &.{} },
    };
    const h = try siblingDeliverables(a, &tareas, "t1");
    defer a.free(h);
    try std.testing.expectEqual(@as(usize, 1), h.len);
    try std.testing.expectEqualStrings("styles.css", h[0]);
}

test "BUG-4: una tarea de auditoria NO sobrescribe el index.html que audita" {
    const a = std.testing.allocator;
    // Orden #241 exacta: el auditor devolvio su informe con el campo llamado
    // `index.html` —el archivo que estaba auditando— y lo escribio ENCIMA del
    // entregable. Las dos tareas acabaron con el mismo artifact_path.
    const arts = [_]worker_backend.Artifact{
        .{ .path = "index.html", .content = "AUDIT: index.html - Veredicto: FAIL. Hallazgos: 1. Falta de semantica ARIA..." },
    };
    const tarea = planner.PlannedTask{
        .id = "t2",
        .task_type = .auditar,
        .department = "auditoria",
        .description = "Auditar el index.html generado",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    const files = (try planOutFiles(a, tarea, &arts, &buf, false)) orelse return error.TestUnexpectedResult;
    defer a.free(files);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    // Ya no es .html: no puede pisar el entregable de la tarea que programaba.
    try std.testing.expect(!std.mem.endsWith(u8, files[0].name, ".html"));
    try std.testing.expectEqualStrings("index.txt", files[0].name);
}

test "BUG-4: una tarea que SI programa conserva su index.html" {
    const a = std.testing.allocator;
    const arts = [_]worker_backend.Artifact{
        .{ .path = "index.html", .content = "<!DOCTYPE html><html><body><button>+</button></body></html>" },
    };
    const tarea = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "Crear index.html",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    const files = (try planOutFiles(a, tarea, &arts, &buf, false)) orelse return error.TestUnexpectedResult;
    defer a.free(files);
    try std.testing.expectEqualStrings("index.html", files[0].name);
}

test "BUG-4: un informe en markdown conserva su .md" {
    const a = std.testing.allocator;
    const arts = [_]worker_backend.Artifact{
        .{ .path = "informe.md", .content = "# Informe\n\nHallazgos del analisis." },
    };
    const tarea = planner.PlannedTask{
        .id = "t3",
        .task_type = .documentar,
        .department = "documentacion",
        .description = "Documentar",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    const files = (try planOutFiles(a, tarea, &arts, &buf, false)) orelse return error.TestUnexpectedResult;
    defer a.free(files);
    try std.testing.expectEqualStrings("informe.md", files[0].name);
}

// ── H7: la edición llega hasta el disco ───────────────────────────────────

fn h7TempDir(a: std.mem.Allocator) ![]u8 {
    var sys_buf: [1024]u8 = undefined;
    const len = GetTempPathA(1024, &sys_buf);
    const sys_temp = if (len > 0 and len < 1024) sys_buf[0..len] else "C:\\Windows\\Temp\\";
    const dir = try std.fmt.allocPrint(a, "{s}beats-h7-{d}", .{ sys_temp, GetTickCount64() });
    const dir_z = try a.dupeZ(u8, dir);
    defer a.free(dir_z);
    if (CreateDirectoryA(dir_z.ptr, null) == 0) {
        a.free(dir);
        return error.SkipZigTest;
    }
    return dir;
}

test "H7 EN DISCO: una edicion modifica el archivo existente y NO lo reescribe entero" {
    const a = std.testing.allocator;
    const dir = h7TempDir(a) catch return error.SkipZigTest;
    defer {
        const dz = a.dupeZ(u8, dir) catch null;
        if (dz) |z| {
            _ = RemoveDirectoryA(z.ptr);
            a.free(z);
        }
        a.free(dir);
    }

    // Un archivo con MAS de lo que la edicion menciona: es justo lo que se
    // perdia cuando el modelo tenia que reemitirlo entero.
    const original =
        "<!DOCTYPE html>\n" ++
        "<html>\n" ++
        "  <body>\n" ++
        "    <button id=\"b\" style=\"color: rojo\">Pulsa</button>\n" ++
        "    <script src=\"script.js\"></script>\n" ++
        "  </body>\n" ++
        "</html>\n";
    const p1 = try writeOneFile(a, dir, dir, "index.html", original);
    defer a.free(p1);

    const edicion =
        "<<<<<<< BUSCAR\n" ++
        "<button id=\"b\" style=\"color: rojo\">Pulsa</button>\n" ++
        "=======\n" ++
        "    <button id=\"b\" style=\"color: azul\">Pulsa</button>\n" ++
        ">>>>>>> REEMPLAZAR\n";
    const p2 = try writeOneFile(a, dir, dir, "index.html", edicion);
    defer a.free(p2);

    const final = (try readWholeFile(a, p2)) orelse return error.TestUnexpectedResult;
    defer a.free(final);

    // El cambio se aplico...
    try std.testing.expect(std.mem.indexOf(u8, final, "color: azul") != null);
    try std.testing.expect(std.mem.indexOf(u8, final, "color: rojo") == null);
    // ...y todo lo demas sigue ahi, que es el punto entero de H7.
    try std.testing.expect(std.mem.indexOf(u8, final, "<!DOCTYPE html>") != null);
    try std.testing.expect(std.mem.indexOf(u8, final, "script.js") != null);
    try std.testing.expect(std.mem.indexOf(u8, final, "</html>") != null);
    // Y no queda ni rastro de los marcadores dentro del archivo.
    try std.testing.expect(std.mem.indexOf(u8, final, "BUSCAR") == null);

    const idx_z = try a.dupeZ(u8, p1);
    defer a.free(idx_z);
    _ = DeleteFileA(idx_z.ptr);
}

test "H7 EN DISCO: una edicion cuyo ancla no existe NO escribe basura" {
    const a = std.testing.allocator;
    const dir = h7TempDir(a) catch return error.SkipZigTest;
    defer {
        const dz = a.dupeZ(u8, dir) catch null;
        if (dz) |z| {
            _ = RemoveDirectoryA(z.ptr);
            a.free(z);
        }
        a.free(dir);
    }

    const original = "linea uno\nlinea dos\n";
    const p1 = try writeOneFile(a, dir, dir, "cosa.txt", original);
    defer a.free(p1);

    const edicion =
        "<<<<<<< BUSCAR\n" ++
        "esto no aparece por ningun lado del fichero\n" ++
        "=======\n" ++
        "reemplazo\n" ++
        ">>>>>>> REEMPLAZAR\n";
    try std.testing.expectError(error.AnchorNotFound, writeOneFile(a, dir, dir, "cosa.txt", edicion));

    // Lo importante: el archivo quedo INTACTO. Antes, un bloque de edicion se
    // habria escrito tal cual, marcadores incluidos.
    const final = (try readWholeFile(a, p1)) orelse return error.TestUnexpectedResult;
    defer a.free(final);
    try std.testing.expectEqualStrings(original, final);

    const f_z = try a.dupeZ(u8, p1);
    defer a.free(f_z);
    _ = DeleteFileA(f_z.ptr);
}

test "H7 EN DISCO: un archivo NUEVO sigue escribiendose entero" {
    // La regresion que hay que no tener: el 99 % de las entregas son archivos
    // completos y tienen que seguir funcionando igual.
    const a = std.testing.allocator;
    const dir = h7TempDir(a) catch return error.SkipZigTest;
    defer {
        const dz = a.dupeZ(u8, dir) catch null;
        if (dz) |z| {
            _ = RemoveDirectoryA(z.ptr);
            a.free(z);
        }
        a.free(dir);
    }

    const p = try writeOneFile(a, dir, dir, "nuevo.js", "console.log('hola');\n");
    defer a.free(p);
    const leido = (try readWholeFile(a, p)) orelse return error.TestUnexpectedResult;
    defer a.free(leido);
    try std.testing.expectEqualStrings("console.log('hola');\n", leido);

    const f_z = try a.dupeZ(u8, p);
    defer a.free(f_z);
    _ = DeleteFileA(f_z.ptr);
}

test "BUG-4 (2a vuelta): el campo filename NO cuela un .html en una auditoria" {
    const a = std.testing.allocator;
    // Orden #298: la Forma 1 no ve este caso porque el campo se llama `filename`,
    // no `index.html`. La Forma 2 respetaba la extension que viniera pegada al
    // nombre y solo consultaba `isProseTask` cuando NO habia extension.
    const arts = [_]worker_backend.Artifact{
        .{ .path = "filename", .content = "index.html" },
        .{ .path = "content", .content = "AUDIT REPORT: Task List Application. Status: FAIL. Se detectaron deficiencias criticas de mantenimiento." },
    };
    const tarea = planner.PlannedTask{
        .id = "t4",
        .task_type = .auditar,
        .department = "auditoria",
        .description = "Auditar la implementacion",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    const files = (try planOutFiles(a, tarea, &arts, &buf, false)) orelse return error.TestUnexpectedResult;
    defer a.free(files);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expect(!std.mem.endsWith(u8, files[0].name, ".html"));
    try std.testing.expectEqualStrings("index.txt", files[0].name);
}

test "BUG-4 (2a vuelta): el nombre sacado de la DESCRIPCION tampoco cuela" {
    const a = std.testing.allocator;
    // La otra puerta: `extractRequestedBasename` saca `index.html` de la propia
    // descripcion de la tarea, y la descripcion de una auditoria nombra
    // exactamente el archivo que audita. `.html` esta en su lista de aceptadas.
    const arts = [_]worker_backend.Artifact{
        .{ .path = "content", .content = "AUDIT REPORT: se revisa index.html y se concluye Status FAIL por falta de semantica." },
    };
    const tarea = planner.PlannedTask{
        .id = "t5",
        .task_type = .auditar,
        .department = "auditoria",
        .description = "Auditar el index.html generado por la tarea anterior",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    const files = (try planOutFiles(a, tarea, &arts, &buf, false)) orelse return error.TestUnexpectedResult;
    defer a.free(files);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expect(!std.mem.endsWith(u8, files[0].name, ".html"));
    try std.testing.expectEqualStrings("index.txt", files[0].name);
}

test "BUG-4 (2a vuelta): programar con filename SIGUE conservando su extension" {
    const a = std.testing.allocator;
    // La contraparte: el arreglo no debe tocar a quien SI programa.
    const arts = [_]worker_backend.Artifact{
        .{ .path = "filename", .content = "index.html" },
        .{ .path = "content", .content = "<!DOCTYPE html><html><body><button>+</button></body></html>" },
    };
    const tarea = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "Crear index.html con un contador",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    const files = (try planOutFiles(a, tarea, &arts, &buf, false)) orelse return error.TestUnexpectedResult;
    defer a.free(files);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("index.html", files[0].name);
}

test "ORDER-ROOT-WORKERS: el override TLS no se hereda solo; propagarlo con getOrderRootOverride lo instala en el hilo worker" {
    // Reproduce el defecto de la orden #457: el dispatch fija el override en su
    // hilo (worktree del space) pero los hilos worker nacen sin el y persistTask
    // escribia en la raiz global. El fix captura el override en el FanoutContext
    // y runTaskInWave lo reinstala en el TLS del worker.
    const Worker = struct {
        fn run(override_path: []const u8, seen: *?[]const u8) void {
            // Sin propagacion: el hilo worker NO ve el override del dispatch.
            var probe: [4096]u8 = undefined;
            if (getOrderRootOverride(&probe) != null) {
                seen.* = "leaked";
                return;
            }
            // Con propagacion (lo que hace runTaskInWave): instalar y leer.
            setOrderRootOverride(override_path);
            defer setOrderRootOverride(null);
            var buf: [4096]u8 = undefined;
            seen.* = std.testing.allocator.dupe(u8, effectiveRoot(&buf)) catch null;
        }
    };

    const wt = "C:/tmp/fake-worktree-orden-457";
    setOrderRootOverride(wt);
    defer setOrderRootOverride(null);

    var seen: ?[]const u8 = null;
    const t = try std.Thread.spawn(.{}, Worker.run, .{ wt, &seen });
    t.join();

    const s = seen orelse return error.TestUnexpectedResult;
    defer std.testing.allocator.free(s);
    try std.testing.expectEqualStrings(wt, s);

    // Y el hilo de dispatch conserva el suyo intacto tras el join.
    var check: [4096]u8 = undefined;
    const still = getOrderRootOverride(&check) orelse return error.TestUnexpectedResult;
    try std.testing.expectEqualStrings(wt, still);
}

test "P0.2a: print(\"HOLA\") en .txt se desenrolla al literal (orden #510)" {
    const a = std.testing.allocator;
    const arts = [_]worker_backend.Artifact{
        .{ .path = "source", .content = "print(\"HOLA\")" },
        .{ .path = "filename", .content = "hola.txt" },
        .{ .path = "expects", .content = "[]" },
    };
    const tarea = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "Crear el archivo hola.txt con el contenido HOLA",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    const files = (try planOutFiles(a, tarea, &arts, &buf, false)) orelse return error.TestUnexpectedResult;
    defer a.free(files);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("hola.txt", files[0].name);
    try std.testing.expectEqualStrings("HOLA", files[0].body);
}

test "P0.2a: with open+write multilinea en .txt se desenrolla (orden #508)" {
    const a = std.testing.allocator;
    const arts = [_]worker_backend.Artifact{
        .{ .path = "source", .content = "with open('hola.txt', 'w', encoding='utf-8') as f:\n    f.write('HOLA')" },
        .{ .path = "filename", .content = "hola.txt" },
    };
    const tarea = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "Crear el archivo hola.txt con el texto HOLA",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    const files = (try planOutFiles(a, tarea, &arts, &buf, false)) orelse return error.TestUnexpectedResult;
    defer a.free(files);
    try std.testing.expectEqual(@as(usize, 1), files.len);
    try std.testing.expectEqualStrings("HOLA", files[0].body);
}

test "P0.2a: no se toca cuando la tarea pide codigo dentro del archivo" {
    const a = std.testing.allocator;
    const arts = [_]worker_backend.Artifact{
        .{ .path = "source", .content = "print(\"HOLA\")" },
        .{ .path = "filename", .content = "hola.txt" },
    };
    const tarea = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "Crear hola.txt con un script que imprima HOLA",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    const files = (try planOutFiles(a, tarea, &arts, &buf, false)) orelse return error.TestUnexpectedResult;
    defer a.free(files);
    try std.testing.expectEqualStrings("print(\"HOLA\")", files[0].body);
}

test "P0.2a: un .py con print() no es entregable de texto y no se toca" {
    const a = std.testing.allocator;
    const arts = [_]worker_backend.Artifact{
        .{ .path = "source", .content = "print(\"HOLA\")" },
        .{ .path = "filename", .content = "hola.py" },
    };
    const tarea = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "Crear hola.py que imprima HOLA",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(a);
    const files = (try planOutFiles(a, tarea, &arts, &buf, false)) orelse return error.TestUnexpectedResult;
    defer a.free(files);
    try std.testing.expectEqualStrings("print(\"HOLA\")", files[0].body);
}

// ── E3.36 · Escritura fuera del workspace y aislamiento entre órdenes ─────
//
// El encargo pide probar `..`, rutas absolutas, UNC, symlinks/junctions,
// nombres de dispositivo (CON/NUL/PRN), rutas largas, el propio dir de datos
// y la colisión entre órdenes. La línea de defensa real es doble: el nombre
// se reduce a basename+sano ANTES de componer la ruta, y la escritura valida
// la ubicación canónica del dir de orden (la comprobación solo léxica
// dejaba pasar junctions).

// D2 (11-nov): la subcarpeta pedida ya no se aplana (`sub\dir\deep.txt` se
// escribía como `deep.txt` y el auditor rechazó la hija 48 con razón); lo
// hostil sigue reducido a basename y nunca sale de la carpeta de la orden.
test "E3.36: nombres hostiles (.., absoluta, UNC, unidad) se reducen a basename local; la subcarpeta sana se conserva" {
    const allocator = std.testing.allocator;
    const arts = [_]worker_backend.Artifact{
        .{ .path = "..\\..\\escape.txt", .content = "x\n" },
        .{ .path = "C:\\Windows\\evil.txt", .content = "y\n" },
        .{ .path = "\\\\host\\share\\unc.txt", .content = "z\n" },
        .{ .path = "sub\\dir\\deep.txt", .content = "w\n" },
        .{ .path = "docs/./punto.txt", .content = "p\n" },
        .{ .path = "docs/../sube.txt", .content = "s\n" },
        .{ .path = "/raiz.txt", .content = "r\n" },
        .{ .path = "C:rel.txt", .content = "u\n" },
        .{ .path = "docs/NUL/dev.txt", .content = "d\n" },
    };
    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "p",
        .description = "x",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    var fb = std.ArrayList(u8).empty;
    defer fb.deinit(allocator);
    const planned = (try planOutFiles(allocator, task, &arts, &fb, false)) orelse return error.TestUnexpectedResult;
    defer allocator.free(planned);
    try std.testing.expectEqual(@as(usize, 8), planned.len);
    try std.testing.expectEqualStrings("escape.txt", planned[0].name);
    try std.testing.expectEqualStrings("evil.txt", planned[1].name);
    try std.testing.expectEqualStrings("unc.txt", planned[2].name);
    try std.testing.expectEqualStrings("sub\\dir\\deep.txt", planned[3].name);
    try std.testing.expectEqualStrings("punto.txt", planned[4].name);
    try std.testing.expectEqualStrings("sube.txt", planned[5].name);
    try std.testing.expectEqualStrings("raiz.txt", planned[6].name);
    // `C:rel.txt` (relativa a la unidad) y `docs/NUL/dev.txt` (dispositivo
    // en la ruta): ni ruta relativa sana ni basename sano.
    try std.testing.expectEqualStrings("dev.txt", planned[7].name);
}

test "D2: el campo filename con subcarpeta la conserva y la escritura no sale de la orden" {
    const allocator = std.testing.allocator;
    const task = planner.PlannedTask{ .id = "t1", .task_type = .programar, .department = "p", .description = "Crea el archivo docs/dos.txt con una linea que diga DOS.", .contract_fields = &.{}, .depends_on = &.{} };
    var fb = std.ArrayList(u8).empty;
    defer fb.deinit(allocator);
    const arts = [_]worker_backend.Artifact{
        .{ .path = "filename", .content = "docs/dos.txt" },
        .{ .path = "source", .content = "DOS" },
    };
    const planned = (try planOutFiles(allocator, task, &arts, &fb, false)) orelse return error.TestUnexpectedResult;
    defer allocator.free(planned);
    try std.testing.expectEqual(@as(usize, 1), planned.len);
    try std.testing.expectEqualStrings("docs/dos.txt", planned[0].name);
    try std.testing.expect(safeRelativePath("a/b/c/d/e/f/g/h/i.txt") == null);
    try std.testing.expect(safeRelativePath("docs//x.txt") == null);
    try std.testing.expect(safeRelativePath("docs/x.txt.") == null);
    try std.testing.expect(safeRelativePath("x.txt") == null);
}

test "E3.36: nombres de dispositivo Win32 y cierres inválidos se rechazan" {
    // CreateFileA("NUL.py") abre el dispositivo: la escritura se descarta y
    // el artefacto «guardado» no existe (medido: Set-Content OK, Test-Path
    // falso). El stem antes del primer punto es lo que casa.
    try std.testing.expect(!isSaneName("NUL.py"));
    try std.testing.expect(!isSaneName("NUL"));
    try std.testing.expect(!isSaneName("CON.txt"));
    try std.testing.expect(!isSaneName("PRN.md"));
    try std.testing.expect(!isSaneName("aux"));
    try std.testing.expect(!isSaneName("com9.txt"));
    try std.testing.expect(!isSaneName("LPT1.c"));
    // Cierre con espacio/punto: Win32 lo recorta → la ruta registrada
    // dejaría de coincidir con el archivo real.
    try std.testing.expect(!isSaneName("archivo."));
    try std.testing.expect(!isSaneName("archivo "));
    // Nombres parecidos pero legítimos siguen pasando.
    try std.testing.expect(isSaneName("nulo.py"));
    try std.testing.expect(isSaneName("console.txt"));
    try std.testing.expect(isSaneName("auxiliar.md"));
    try std.testing.expect(isSaneName(".oculto"));
}

/// Crea un junction NTFS (`link_dir` → `target`) con FSCTL_SET_REPARSE_POINT:
/// equivalente a `mklink /J` pero sin subproceso y sin SeCreateSymbolicLink
/// (los mount points sobre dirs no lo requieren). Solo para tests.
pub fn createJunction(allocator: std.mem.Allocator, link_dir: []const u8, target: []const u8) !void {
    // T9: en POSIX el equivalente de prueba de una junction es un enlace
    // simbolico de carpeta (mismo escape que la confinacion debe impedir).
    if (@import("builtin").os.tag != .windows) {
        const link_z = try allocator.dupeZ(u8, link_dir);
        defer allocator.free(link_z);
        const target_z = try allocator.dupeZ(u8, target);
        defer allocator.free(target_z);
        if (std.c.symlink(target_z, link_z) != 0) return error.JunctionDirFailed;
        return;
    }
    const link_z = try allocator.dupeZ(u8, link_dir);
    defer allocator.free(link_z);
    if (CreateDirectoryA(link_z, null) == 0) return error.JunctionDirFailed;
    const h = CreateFileA(link_z.ptr, GENERIC_WRITE, 0, null, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS | FILE_FLAG_OPEN_REPARSE_POINT, null);
    if (h == INVALID_HANDLE_VALUE) return error.JunctionOpenFailed;
    defer _ = CloseHandle(h);
    // REPARSE_DATA_BUFFER (mount point): substitute = \??\<target> y print =
    // <target>, ambos en UTF-16LE y NUL-terminados en el buffer; las longitudes
    // registradas EXCLUYEN el NUL final.
    const sub8 = try std.fmt.allocPrint(allocator, "\\??\\{s}", .{target});
    defer allocator.free(sub8);
    const sub_w = try std.unicode.utf8ToUtf16LeAlloc(allocator, sub8);
    defer allocator.free(sub_w);
    const prn_w = try std.unicode.utf8ToUtf16LeAlloc(allocator, target);
    defer allocator.free(prn_w);
    const sub_len: u16 = @intCast(sub_w.len * 2);
    const prn_len: u16 = @intCast(prn_w.len * 2);
    const data_len: u16 = 8 + sub_len + 2 + prn_len + 2;
    const buf = try allocator.alloc(u8, 8 + data_len);
    defer allocator.free(buf);
    std.mem.writeInt(u32, buf[0..4], IO_REPARSE_TAG_MOUNT_POINT, .little);
    std.mem.writeInt(u16, buf[4..6], data_len, .little);
    std.mem.writeInt(u16, buf[6..8], 0, .little);
    std.mem.writeInt(u16, buf[8..10], 0, .little);
    std.mem.writeInt(u16, buf[10..12], sub_len, .little);
    std.mem.writeInt(u16, buf[12..14], sub_len + 2, .little);
    std.mem.writeInt(u16, buf[14..16], prn_len, .little);
    var pos: usize = 16;
    for (sub_w) |w| {
        std.mem.writeInt(u16, buf[pos..][0..2], w, .little);
        pos += 2;
    }
    pos += 2;
    for (prn_w) |w| {
        std.mem.writeInt(u16, buf[pos..][0..2], w, .little);
        pos += 2;
    }
    var ret: u32 = 0;
    if (DeviceIoControl(h, FSCTL_SET_REPARSE_POINT, buf.ptr, @intCast(buf.len), null, 0, &ret, null) == 0) return error.JunctionIoctlFailed;
}

test "E3.36: un junction en el dir de orden NO deja escapar la escritura (E-65)" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, junctions o cmd.exe); omitida en Linux");
    const allocator = std.testing.allocator;
    // Reproduce el escape medido: `orden-<id>` plantado como junction hacia
    // un dir FUERA del workspace. Antes el chequeo léxico pasaba y el
    // archivo caía en el destino del junction; ahora la validación canónica
    // rechaza la escritura.
    var tmp_buf: [4096]u8 = undefined;
    const tmp_len = GetTempPathA(@intCast(tmp_buf.len), &tmp_buf);
    if (tmp_len == 0 or tmp_len >= tmp_buf.len) return error.SkipZigTest;
    const tmp = tmp_buf[0..tmp_len];
    const ws_root = try std.fmt.allocPrint(allocator, "{s}beats-e336-ws", .{tmp});
    defer allocator.free(ws_root);
    const outside = try std.fmt.allocPrint(allocator, "{s}beats-e336-outside", .{tmp});
    defer allocator.free(outside);
    const junction = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "orden-4242", .{ws_root});
    defer allocator.free(junction);
    const ws_z = try allocator.dupeZ(u8, ws_root);
    defer allocator.free(ws_z);
    const out_z = try allocator.dupeZ(u8, outside);
    defer allocator.free(out_z);
    const jn_z = try allocator.dupeZ(u8, junction);
    defer allocator.free(jn_z);
    _ = CreateDirectoryA(ws_z, null);
    _ = CreateDirectoryA(out_z, null);
    defer _ = RemoveDirectoryA(ws_z);
    defer _ = RemoveDirectoryA(out_z);
    defer _ = RemoveDirectoryA(jn_z); // borra el junction, no el destino

    // Plantar el junction real vía FSCTL_SET_REPARSE_POINT — sin subproceso
    // (un `cmd /c` dentro de `zig build test` colgaba la batería) ni el
    // privilegio de symlink (los junctions sobre dirs no lo exigen).
    createJunction(allocator, junction, outside) catch return error.SkipZigTest;

    // El override TLS dirige la escritura a la raíz trampa.
    setOrderRootOverride(ws_root);
    defer setOrderRootOverride(null);

    const arts = [_]worker_backend.Artifact{
        .{ .path = "trap.txt", .content = "ESCAPADO\n" },
    };
    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "p",
        .description = "x",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    const res = persistTaskFiles(allocator, 4242, task, &arts);
    try std.testing.expectError(error.WriteOutsideWorkspace, res);

    // Y el destino del junction quedó intacto — nada cruzó el límite.
    const probe = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "trap.txt", .{outside});
    defer allocator.free(probe);
    const probe_z = try allocator.dupeZ(u8, probe);
    defer allocator.free(probe_z);
    const h = CreateFileA(probe_z.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    try std.testing.expect(h == INVALID_HANDLE_VALUE);
}

test "E3.36: filename NUL.py no escribe el dispositivo ni finge el archivo" {
    const allocator = std.testing.allocator;
    // Con el saneo de dispositivo, `filename:NUL.py` cae al nombre de
    // respaldo y el archivo REAL existe en disco (antes: CreateFileA abría
    // el dispositivo, la escritura se descartaba y nada persistía).
    var tmp_buf: [4096]u8 = undefined;
    const tmp_len = GetTempPathA(@intCast(tmp_buf.len), &tmp_buf);
    if (tmp_len == 0 or tmp_len >= tmp_buf.len) return error.SkipZigTest;
    const ws_root = try std.fmt.allocPrint(allocator, "{s}beats-e336-devws", .{tmp_buf[0..tmp_len]});
    defer allocator.free(ws_root);
    const ws_z = try allocator.dupeZ(u8, ws_root);
    defer allocator.free(ws_z);
    _ = CreateDirectoryA(ws_z, null);
    defer _ = RemoveDirectoryA(ws_z);

    setOrderRootOverride(ws_root);
    defer setOrderRootOverride(null);

    const arts = [_]worker_backend.Artifact{
        .{ .path = "filename", .content = "NUL.py" },
        .{ .path = "source", .content = "print('hola')\n" },
    };
    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "p",
        .description = "crea un script python",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    const paths = (try persistTaskFiles(allocator, 4343, task, &arts)) orelse return error.TestUnexpectedResult;
    defer {
        for (paths) |p| allocator.free(p);
        allocator.free(paths);
    }
    try std.testing.expect(paths.len >= 1);
    const saved = paths[0];
    // El archivo no se llamó NUL.py: cayó al nombre sano de respaldo.
    try std.testing.expect(std.mem.indexOf(u8, saved, "NUL.py") == null);
    try std.testing.expect(std.mem.indexOf(u8, saved, "orden-4343") != null);
    // Y existe de verdad en disco (legible por Win32).
    const saved_z = try allocator.dupeZ(u8, saved);
    defer allocator.free(saved_z);
    const h = CreateFileA(saved_z.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, FILE_ATTRIBUTE_NORMAL, null);
    try std.testing.expect(h != INVALID_HANDLE_VALUE);
    _ = CloseHandle(h);
    // Limpieza: archivo + dir de orden.
    _ = DeleteFileA(saved_z.ptr);
    const od = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "orden-4343", .{ws_root});
    defer allocator.free(od);
    const od_z = try allocator.dupeZ(u8, od);
    defer allocator.free(od_z);
    _ = RemoveDirectoryA(od_z);
}

test "E3.36: dos ordenes con el mismo nombre de archivo no colisionan" {
    const allocator = std.testing.allocator;
    var tmp_buf: [4096]u8 = undefined;
    const tmp_len = GetTempPathA(@intCast(tmp_buf.len), &tmp_buf);
    if (tmp_len == 0 or tmp_len >= tmp_buf.len) return error.SkipZigTest;
    const ws_root = try std.fmt.allocPrint(allocator, "{s}beats-e336-isows", .{tmp_buf[0..tmp_len]});
    defer allocator.free(ws_root);
    const ws_z = try allocator.dupeZ(u8, ws_root);
    defer allocator.free(ws_z);
    _ = CreateDirectoryA(ws_z, null);
    defer _ = RemoveDirectoryA(ws_z);

    setOrderRootOverride(ws_root);
    defer setOrderRootOverride(null);

    const arts = [_]worker_backend.Artifact{
        .{ .path = "mismo.txt", .content = "cuerpo\n" },
    };
    const task = planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "p",
        .description = "x",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    const p1 = (try persistTaskFiles(allocator, 5101, task, &arts)) orelse return error.TestUnexpectedResult;
    defer {
        for (p1) |p| allocator.free(p);
        allocator.free(p1);
    }
    const p2 = (try persistTaskFiles(allocator, 5102, task, &arts)) orelse return error.TestUnexpectedResult;
    defer {
        for (p2) |p| allocator.free(p);
        allocator.free(p2);
    }
    // Cada orden materializa en su propio dir: mismo nombre, rutas distintas.
    try std.testing.expect(std.mem.indexOf(u8, p1[0], "orden-5101") != null);
    try std.testing.expect(std.mem.indexOf(u8, p2[0], "orden-5102") != null);
    try std.testing.expect(!std.mem.eql(u8, p1[0], p2[0]));
    // Limpieza.
    for ([_][]const u8{ p1[0], p2[0] }) |p| {
        const z = try allocator.dupeZ(u8, p);
        defer allocator.free(z);
        _ = DeleteFileA(z.ptr);
    }
    for ([_][]const u8{ "orden-5101", "orden-5102" }) |d| {
        const od2 = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ ws_root, d });
        defer allocator.free(od2);
        const od2_z = try allocator.dupeZ(u8, od2);
        defer allocator.free(od2_z);
        _ = RemoveDirectoryA(od2_z);
    }
}

test "E5.20 E-129 ronda3: mayúsculas Windows conservan el segmento S2 elegido" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, junctions o cmd.exe); omitida en Linux");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "selected/DEVAGENTS-WORKSPACE");
    const selected = try tmp.dir.realPathFileAlloc(io, "selected/DEVAGENTS-WORKSPACE", a);
    defer a.free(selected);
    try tmp.dir.createDirPath(io, "outside");
    const outside = try tmp.dir.realPathFileAlloc(io, "outside", a);
    defer a.free(outside);
    const nested = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{selected});
    defer a.free(nested);
    try createJunction(a, nested, outside);
    defer tmp.dir.deleteDir(io, "selected/DEVAGENTS-WORKSPACE/devagents-workspace") catch |e| std.debug.print("workspace nested cleanup: {s}\n", .{@errorName(e)});
    defer setWorkspaceRoot(WORKSPACE_ROOT);
    // Windows identifica este basename sin distinguir mayúsculas. Ya es S2:
    // ni validar ni usar un hijo adicional, aunque ese hijo sea una junction.
    const trailing = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "", .{selected});
    defer a.free(trailing);
    for ([_][]const u8{ selected, trailing }) |path| {
        try setWorkspaceRootChecked(path);
        var buf: [4096]u8 = undefined;
        try std.testing.expectEqualStrings(selected, effectiveRoot(&buf));
    }
}

test "SEC-FS workspace confined edit preserves untouched bytes and rejects junction parents" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, junctions o cmd.exe); omitida en Linux");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "root/order");
    try tmp.dir.createDirPath(io, "outside");
    const root = try tmp.dir.realPathFileAlloc(io, "root", a);
    defer a.free(root);
    const order = try tmp.dir.realPathFileAlloc(io, "root/order", a);
    defer a.free(order);
    const outside = try tmp.dir.realPathFileAlloc(io, "outside", a);
    defer a.free(outside);
    const original = "prefix\nold\nsuffix\n";
    const saved = try writeOneFile(a, order, root, "edit.txt", original);
    defer a.free(saved);
    const edited = try writeOneFile(a, order, root, "edit.txt", "<<<<<<< BUSCAR\nold\n=======\nnew\n>>>>>>> REEMPLAZAR\n");
    defer a.free(edited);
    const actual = try tmp.dir.readFileAlloc(io, "root/order/edit.txt", a, .limited(4096));
    defer a.free(actual);
    try std.testing.expectEqualStrings("prefix\nnew\nsuffix\n", actual);
    const link = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "alias", .{root});
    defer a.free(link);
    try createJunction(a, link, outside);
    defer tmp.dir.deleteDir(io, "root/alias") catch |e| std.debug.print("SEC-FS junction cleanup: {s}\n", .{@errorName(e)});
    try std.testing.expectError(error.WriteOutsideWorkspace, writeOneFile(a, link, root, "escape.txt", "blocked"));
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "outside/escape.txt", .{}));
    try std.testing.expectError(error.WriteOutsideWorkspace, writeOneFile(a, order, root, "..\\..\\outside\\escape.txt", "blocked"));
}
