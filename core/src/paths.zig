//! core/src/paths.zig — Resolución canónica de rutas de base de datos.
//!
//! FIRE-04: GUI y CLI deben compartir exactamente UNA ruta de runtime.db/catalog.db,
//! anclada a la raíz del proyecto (directorio que contiene build.zig), independientemente
//! del CWD. Este módulo deriva esa ruta canónica usando API Win32 directa (mismo estilo
//! que workspace.zig, c_api.zig, cli_driver.zig) para evitar incompatibilidades del fork.

const std = @import("std");
const is_windows = @import("builtin").os.tag == .windows;

const GetEnvironmentVariableW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetEnvironmentVariableW(
        lpName: [*:0]const u16,
        lpBuffer: [*]u16,
        nSize: u32,
    ) callconv(.winapi) u32;
}.GetEnvironmentVariableW else @import("providers").posix_files.GetEnvironmentVariableW;
const CreateDirectoryA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateDirectoryA(
        lpPathName: [*:0]const u8,
        lpSecurityAttributes: ?*anyopaque,
    ) callconv(.winapi) c_int;
}.CreateDirectoryA else @import("providers").posix_files.CreateDirectoryA;

/// Resuelve `filename` (p. ej. "runtime.db") dentro de la carpeta de datos
/// ÚNICA del producto (resolveDataDir: argumento explícito > BEATS_DATA_DIR >
/// alias > carpeta por defecto por API de carpetas conocidas), protegida con
/// DACL solo-usuario. Sin fallback relativo al cwd: si la
/// resolución falla, el error se propaga (fallo cerrado).
///
/// La memoria devuelta pertenece al caller; liberar con allocator.free.
pub fn canonicalDbPath(allocator: std.mem.Allocator, filename: [:0]const u8) ![:0]const u8 {
    // UNA sola resolucion de carpeta de datos (resolveDataDir).
    // Un override invalido de BEATS_DATA_DIR/DEVAGENTS_DATA_DIR es fallo
    // cerrado: nunca se cae a una base relativa ni a la real del propietario.
    // Auditoria r3 (P1): si falla la API de carpetas conocidas el error se
    // PROPAGA (DefaultDataDirUnavailable); la antigua resolucion heredada —
    // variable LOCALAPPDATA, busqueda de build.zig y ruta relativa al cwd
    // (paths.zig viejo 61-114) — se ELIMINO: ningun camino del nucleo, la CLI
    // ni el MCP puede abrir una base relativa ni sin la proteccion DACL de
    //. Si alguna prueba hiciera falta la ruta heredada, solo
    // cabe como argumento explícito (resolveDataDir(explicit)).
    // El calculo NO crea ni protege nada; aqui se sigue creando y protegiendo
    // con DACL solo-usuario igual que antes.
    const resolved = try resolveDataDir(allocator, null);
    defer allocator.free(resolved.dir);
    @import("private_data.zig").ensureDirectory(allocator, resolved.dir) catch {
        return error.PrivateDataDirectoryFailed;
    };
    const joined = try std.fs.path.join(allocator, &.{ resolved.dir, filename });
    defer allocator.free(joined);
    return try allocator.dupeZ(u8, joined);
}

/// Helpers concretos para las bases de datos del proyecto.
pub fn runtimeDb(allocator: std.mem.Allocator) ![:0]const u8 {
    return try canonicalDbPath(allocator, "runtime.db");
}
pub fn catalogDb(allocator: std.mem.Allocator) ![:0]const u8 {
    return try canonicalDbPath(allocator, "catalog.db");
}
/// Directorio de plugins: `%LOCALAPPDATA%\DevAgents-Angel\plugins`, creado si falta.
///
/// Cada plugin vive en su propia subcarpeta con un `plugin.json` y su DLL al
/// lado. Se apoya en `canonicalDbPath` para resolver la raíz, que es la misma
/// que usan catalog.db y runtime.db: si los plugins se buscaran en otro sitio,
/// el CLI y la cabina verían inventarios distintos, que es exactamente el fallo
/// (FIRE-04) que este módulo existe para impedir.
pub fn pluginsDir(allocator: std.mem.Allocator) ![:0]const u8 {
    const dir = try canonicalDbPath(allocator, "plugins");
    if (is_windows) {
        _ = CreateDirectoryA(dir.ptr, null);
    } else {
        @import("private_data.zig").ensureDirectory(allocator, dir) catch {
            allocator.free(dir);
            return error.PrivateDataDirectoryFailed;
        };
    }
    return dir;
}

pub fn ledgerDb(allocator: std.mem.Allocator) ![:0]const u8 {
    return try canonicalDbPath(allocator, "ledger.db");
}

// ---------------------------------------------------------------------------
// una sola forma de resolver la carpeta de datos.
// ---------------------------------------------------------------------------

/// Fuente de la carpeta de datos resuelta.
pub const DataDirSource = enum {
    /// Argumento explícito (p. ej. `--data-dir` del MCP / `--db`).
    explicit_arg,
    /// Variable BEATS_DATA_DIR (ruta absoluta y existente; si no: fallo cerrado).
    env_beats,
    /// Alias de compatibilidad: DEVAGENTS_DATA_DIR (mismo tratamiento que env_beats).
    env_alias,
    /// Carpeta por defecto vía API de carpetas conocidas (igual que el host).
    default_known_folders,
};

pub const ResolvedDataDir = struct {
    dir: []u8,
    source: DataDirSource,
};

pub const ResolveDataDirError = error{
    /// Override por entorno inútil (relativo, inexistente o no carpeta):
    /// fallo cerrado, nunca se cae a una base relativa ni a la real.
    DataDirOverrideInvalid,
    /// La API de carpetas conocidas no devolvió LOCAL_APPDATA.
    DefaultDataDirUnavailable,
    OutOfMemory,
};

/// (r3, costura de prueba): simula el fallo de SHGetFolderPathW
/// (API de carpetas conocidas) para probar que resolveDataDir y TODOS sus
/// consumidores (canonicalDbPath, CLI, MCP) PROPAGAN el error en vez de caer
/// a la resolución heredada. Solo la activan los tests de este módulo; el
/// producto nunca la enciende.
var pl007_force_default_unavailable: bool = false;

/// resolución ÚNICA de la carpeta de datos. Orden documentado:
///   1. `explicit` — argumento explícito (se usa tal cual; la creación y la
///      protección DACL quedan en la apertura, igual que antes).
/// 2. BEATS_DATA_DIR — solo si es ruta absoluta existente; si no (relativa,
///      inexistente, no carpeta, no-UTF16 convertible o de 4096 o más
///      unidades), fallo cerrado (error.DataDirOverrideInvalid). Se lee con la
///      variante W (GetEnvironmentVariableW) y se valida con
///      GetFileAttributesW: igual que el host, sobrevive a rutas no-ASCII.
/// 3. DEVAGENTS_DATA_DIR — alias de BEATS_DATA_DIR (compatibilidad MCP);
///      mismas reglas que 2.
///   4. Por defecto: SHGetFolderPathW(CSIDL_LOCAL_APPDATA) + «\DevAgents»,
///      la misma carpeta que resuelve la cabina (no la variable LOCALAPPDATA).
/// El cálculo NO crea ni protege nada: eso ocurre en la apertura (da_core_init
/// → ensureDirectory) y en el host (private_data_directory).
pub fn resolveDataDir(allocator: std.mem.Allocator, explicit: ?[]const u8) ResolveDataDirError!ResolvedDataDir {
    if (explicit) |dir| {
        if (dir.len > 0) {
            return .{ .dir = try allocator.dupe(u8, dir), .source = .explicit_arg };
        }
    }
    if (!is_windows) return resolvePosixDataDir(allocator);
    const env_names = [_]struct { name: [:0]const u16, source: DataDirSource }{
        .{ .name = std.unicode.utf8ToUtf16LeStringLiteral("BEATS_DATA_DIR"), .source = .env_beats },
        .{ .name = std.unicode.utf8ToUtf16LeStringLiteral("DEVAGENTS_DATA_DIR"), .source = .env_alias },
    };
    for (env_names) |entry| {
        // P3: variante W (GetEnvironmentVariableW) igual que el host, para que
        // rutas con caracteres no-ASCII sobrevivan a la página ANSI y lleguen
        // como UTF-8; el valor se valida con GetFileAttributesW.
        var env_buf: [4096]u16 = undefined;
        const env_len = GetEnvironmentVariableW(entry.name.ptr, &env_buf, @intCast(env_buf.len));
        // P2-a: un valor de 4096 o más unidades no se ignora en silencio: es
        // fallo cerrado (error.DataDirOverrideInvalid), como el host.
        if (env_len >= env_buf.len) return error.DataDirOverrideInvalid;
        if (env_len > 0) {
            const value = std.unicode.utf16LeToUtf8Alloc(allocator, env_buf[0..env_len]) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                else => return error.DataDirOverrideInvalid,
            };
            defer allocator.free(value);
            validateOverride(allocator, value) catch return error.DataDirOverrideInvalid;
            return .{ .dir = try allocator.dupe(u8, value), .source = entry.source };
        }
    }
    // Default: la misma carpeta que usa la cabina, vía API de carpetas
    // conocidas (no la variable LOCALAPPDATA).
    if (pl007_force_default_unavailable) return error.DefaultDataDirUnavailable;
    var wide: [260]u16 = undefined;
    const hr = SHGetFolderPathW(null, csidl_local_appdata, null, 0, &wide);
    if (hr < 0) return error.DefaultDataDirUnavailable;
    const known_len = std.mem.indexOfScalar(u16, &wide, 0) orelse return error.DefaultDataDirUnavailable;
    const known = std.unicode.utf16LeToUtf8Alloc(allocator, wide[0..known_len]) catch return error.DefaultDataDirUnavailable;
    defer allocator.free(known);
    const dir = std.fs.path.join(allocator, &.{ known, "DevAgents-Angel" }) catch return error.OutOfMemory;
    defer allocator.free(dir);
    return .{ .dir = try allocator.dupe(u8, dir), .source = .default_known_folders };
}

const GetFileAttributesW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileAttributesW(lpFileName: [*:0]const u16) callconv(.winapi) u32;
}.GetFileAttributesW else @import("providers").posix_files.GetFileAttributesW;
const GetFileAttributesA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileAttributesA(lpFileName: [*:0]const u8) callconv(.winapi) u32;
}.GetFileAttributesA else @import("providers").posix_files.GetFileAttributesA;
const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFFFFFF;
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;

/// un override del entorno vale solo como ruta absoluta CON unidad
/// y existente (misma regla que el host, shell/host/core_client.cpp:39-47);
/// lo relativo, lo inexistente o un archivo (no carpeta) es fallo cerrado.
/// P3: la existencia se comprueba con GetFileAttributesW (UTF-16, igual que el
/// host), para que una carpeta no-ASCII no muera en la página ANSI.
fn validateOverride(allocator: std.mem.Allocator, path: []const u8) ResolveDataDirError!void {
    if (path.len < 3 or path[1] != ':' or (path[2] != '\\' and path[2] != '/'))
        return error.DataDirOverrideInvalid;
    if (!((path[0] >= 'A' and path[0] <= 'Z') or (path[0] >= 'a' and path[0] <= 'z')))
        return error.DataDirOverrideInvalid;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(allocator, path) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidUtf8 => return error.DataDirOverrideInvalid,
    };
    defer allocator.free(wide);
    const attrs = GetFileAttributesW(wide.ptr);
    if (attrs == INVALID_FILE_ATTRIBUTES or (attrs & FILE_ATTRIBUTE_DIRECTORY) == 0)
        return error.DataDirOverrideInvalid;
}

const csidl_local_appdata: c_int = 0x001c;

extern "shell32" fn SHGetFolderPathW(
    hwnd: ?std.os.windows.HANDLE,
    csidl: c_int,
    token: ?std.os.windows.HANDLE,
    flags: u32,
    path: [*]u16,
) i32;

const GetFullPathNameA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFullPathNameA(
        lpFileName: [*:0]const u8,
        nBufferLength: u32,
        lpBuffer: [*:0]u8,
        lpFilePart: ?*?[*:0]u8,
    ) callconv(.winapi) u32;
}.GetFullPathNameA else @import("providers").posix_files.GetFullPathNameA;

/// helper de pruebas — crea (si falta) una carpeta de datos
/// absoluta bajo `<cwd>\.zig-cache` y devuelve su ruta terminada en nulo.
fn pl007TempDataDir(allocator: std.mem.Allocator, tag: []const u8) ![:0]u8 {
    var cwd_buf: [4096]u8 = undefined;
    const n = GetFullPathNameA(".", @intCast(cwd_buf.len), @ptrCast(&cwd_buf[0]), null);
    if (n == 0 or n >= cwd_buf.len) return error.DataDirOverrideInvalid;
    const cache = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ ".zig-cache", .{cwd_buf[0..n]});
    defer allocator.free(cache);
    const cache_z = try allocator.dupeZ(u8, cache);
    defer allocator.free(cache_z);
    _ = CreateDirectoryA(cache_z.ptr, null);
    const rel = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ ".zig-cache" ++ std.fs.path.sep_str ++ "CK-PLT-007-{s}", .{ cwd_buf[0..n], tag });
    defer allocator.free(rel);
    const rel_z = try allocator.dupeZ(u8, rel);
    errdefer allocator.free(rel_z);
    _ = CreateDirectoryA(rel_z.ptr, null);
    if (GetFileAttributesA(rel_z.ptr) == INVALID_FILE_ATTRIBUTES) {
        allocator.free(rel_z);
        return error.DataDirOverrideInvalid;
    }
    return rel_z;
}

fn pl007RestoreEnv(beats_prev: ?[:0]const u8, alias_prev: ?[:0]const u8) void {
    _ = SetEnvironmentVariableA("BEATS_DATA_DIR", if (beats_prev) |p| p.ptr else null);
    _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", if (alias_prev) |p| p.ptr else null);
}

fn pl007PrevEnv(name: [*:0]const u8, buf: *[4096:0]u8) ?[:0]const u8 {
    const n = GetEnvironmentVariableA(name, buf, buf.len);
    if (n == 0 or n >= buf.len) return null;
    return buf[0..n :0];
}

const SetEnvironmentVariableA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn SetEnvironmentVariableA(
        lpName: [*:0]const u8,
        lpValue: ?[*:0]const u8,
    ) callconv(.winapi) c_int;
}.SetEnvironmentVariableA else @import("providers").posix_files.SetEnvironmentVariableA;

const GetEnvironmentVariableA = @import("platform.zig").env;

test "CK-PLT-007: BEATS_DATA_DIR absoluta y existente gana sobre el valor por defecto" {
    if (!is_windows) return @import("platform.zig").skip("T9: API y rutas de Windows (SetEnvironmentVariableA, unidades); la resolucion POSIX tiene su prueba T9");
    const a = std.testing.allocator;
    var prev_beats: [4096:0]u8 = undefined;
    var prev_alias: [4096:0]u8 = undefined;
    defer pl007RestoreEnv(pl007PrevEnv("BEATS_DATA_DIR", &prev_beats), pl007PrevEnv("DEVAGENTS_DATA_DIR", &prev_alias));

    _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", null);
    _ = SetEnvironmentVariableA("BEATS_DATA_DIR", "ruta relativa sin sentido");
    try std.testing.expectError(error.DataDirOverrideInvalid, resolveDataDir(a, null));

    const dir = try pl007TempDataDir(a, "devagents");
    defer a.free(dir);
    _ = SetEnvironmentVariableA("BEATS_DATA_DIR", dir.ptr);

    const resolved = try resolveDataDir(a, null);
    defer a.free(resolved.dir);
    try std.testing.expectEqual(DataDirSource.env_beats, resolved.source);
    try std.testing.expectEqualStrings(dir, resolved.dir);

    const db = try runtimeDb(a);
    defer a.free(db);
    try std.testing.expect(std.mem.startsWith(u8, db, dir));
    try std.testing.expect(std.mem.endsWith(u8, db, "\\runtime.db"));

    // P3: pluginsDir vive en la MISMA carpeta resuelta (no en una propia) y
    // queda creada — la misma raíz que la cabina.
    const plugins = try pluginsDir(a);
    defer a.free(plugins);
    try std.testing.expect(std.mem.startsWith(u8, plugins, dir));
    try std.testing.expect(std.mem.endsWith(u8, plugins, "\\plugins"));
    try std.testing.expect(GetFileAttributesA(plugins.ptr) != INVALID_FILE_ATTRIBUTES);
}

test "CK-PLT-007: override absoluto inexistente falla cerrado, sin caer a base relativa ni a la real" {
    if (!is_windows) return @import("platform.zig").skip("T9: API y rutas de Windows (SetEnvironmentVariableA, unidades); la resolucion POSIX tiene su prueba T9");
    const a = std.testing.allocator;
    var prev_beats: [4096:0]u8 = undefined;
    var prev_alias: [4096:0]u8 = undefined;
    defer pl007RestoreEnv(pl007PrevEnv("BEATS_DATA_DIR", &prev_beats), pl007PrevEnv("DEVAGENTS_DATA_DIR", &prev_alias));

    _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", null);
    _ = SetEnvironmentVariableA("BEATS_DATA_DIR", "C:\\.zig-cache-no-existe\\CK-PLT-007\\ausente");
    try std.testing.expectError(error.DataDirOverrideInvalid, resolveDataDir(a, null));
    try std.testing.expectError(error.DataDirOverrideInvalid, runtimeDb(a));
}

test "CK-PLT-007: DEVAGENTS_DATA_DIR funciona como alias cuando BEATS_DATA_DIR no está" {
    if (!is_windows) return @import("platform.zig").skip("T9: API y rutas de Windows (SetEnvironmentVariableA, unidades); la resolucion POSIX tiene su prueba T9");
    const a = std.testing.allocator;
    var prev_beats: [4096:0]u8 = undefined;
    var prev_alias: [4096:0]u8 = undefined;
    defer pl007RestoreEnv(pl007PrevEnv("BEATS_DATA_DIR", &prev_beats), pl007PrevEnv("DEVAGENTS_DATA_DIR", &prev_alias));

    _ = SetEnvironmentVariableA("BEATS_DATA_DIR", null);
    const dir = try pl007TempDataDir(a, "alias");
    defer a.free(dir);
    _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", dir.ptr);

    const resolved = try resolveDataDir(a, null);
    defer a.free(resolved.dir);
    try std.testing.expectEqual(DataDirSource.env_alias, resolved.source);
    try std.testing.expectEqualStrings(dir, resolved.dir);
}

test "CK-PLT-007: sin override se calcula la carpeta por defecto (solo ruta, sin abrir nada)" {
    if (!is_windows) return @import("platform.zig").skip("T9: API y rutas de Windows (SetEnvironmentVariableA, unidades); la resolucion POSIX tiene su prueba T9");
    const a = std.testing.allocator;
    var prev_beats: [4096:0]u8 = undefined;
    var prev_alias: [4096:0]u8 = undefined;
    defer pl007RestoreEnv(pl007PrevEnv("BEATS_DATA_DIR", &prev_beats), pl007PrevEnv("DEVAGENTS_DATA_DIR", &prev_alias));

    _ = SetEnvironmentVariableA("BEATS_DATA_DIR", null);
    _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", null);

    const resolved = try resolveDataDir(a, null);
    defer a.free(resolved.dir);
    try std.testing.expectEqual(DataDirSource.default_known_folders, resolved.source);
    try std.testing.expect(std.fs.path.isAbsolute(resolved.dir));
    try std.testing.expect(std.mem.endsWith(u8, resolved.dir, "DevAgents-Angel"));
}

test "CK-PLT-007: BEATS_DATA_DIR demasiado largo (5000) falla cerrado, sin ignorarse" {
    if (!is_windows) return @import("platform.zig").skip("T9: API y rutas de Windows (SetEnvironmentVariableA, unidades); la resolucion POSIX tiene su prueba T9");
    const a = std.testing.allocator;
    var prev_beats: [4096:0]u8 = undefined;
    var prev_alias: [4096:0]u8 = undefined;
    defer pl007RestoreEnv(pl007PrevEnv("BEATS_DATA_DIR", &prev_beats), pl007PrevEnv("DEVAGENTS_DATA_DIR", &prev_alias));

    _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", null);
    const long5k = try a.allocSentinel(u8, 5000, 0);
    defer a.free(long5k);
    @memset(long5k[0..5000], 'x');
    _ = SetEnvironmentVariableA("BEATS_DATA_DIR", long5k.ptr);

    // P2-a: un valor del entorno de 4096 o más caracteres NO se ignora: es
    // fallo cerrado (error.DataDirOverrideInvalid), como el host.
    try std.testing.expectError(error.DataDirOverrideInvalid, resolveDataDir(a, null));
    try std.testing.expectError(error.DataDirOverrideInvalid, runtimeDb(a));
    try std.testing.expectError(error.DataDirOverrideInvalid, catalogDb(a));
}

extern "kernel32" fn SetEnvironmentVariableW(
    lpName: [*:0]const u16,
    lpValue: ?[*:0]const u16,
) callconv(.winapi) c_int;

const CreateDirectoryW = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateDirectoryW(
        lpPathName: [*:0]const u16,
        lpSecurityAttributes: ?*anyopaque,
    ) callconv(.winapi) c_int;
}.CreateDirectoryW else @import("providers").posix_files.CreateDirectoryW;

test "CK-PLT-007: BEATS_DATA_DIR con ruta no-ASCII (variante W) se resuelve como UTF-8, igual que el host" {
    if (!is_windows) return @import("platform.zig").skip("T9: API y rutas de Windows (SetEnvironmentVariableA, unidades); la resolucion POSIX tiene su prueba T9");
    const a = std.testing.allocator;
    var prev_beats: [4096:0]u8 = undefined;
    var prev_alias: [4096:0]u8 = undefined;
    defer pl007RestoreEnv(pl007PrevEnv("BEATS_DATA_DIR", &prev_beats), pl007PrevEnv("DEVAGENTS_DATA_DIR", &prev_alias));

    _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", null);
    var cwd_buf: [4096]u8 = undefined;
    const n = GetFullPathNameA(".", @intCast(cwd_buf.len), @ptrCast(&cwd_buf[0]), null);
    try std.testing.expect(n > 0 and n < cwd_buf.len);
    const rel8 = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".zig-cache" ++ std.fs.path.sep_str ++ "CK-PLT-007-nó-eñ", .{cwd_buf[0..n]});
    defer a.free(rel8);
    const rel8z = try a.dupeZ(u8, rel8);
    defer a.free(rel8z);
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, rel8z);
    defer a.free(wide);
    _ = CreateDirectoryW(wide.ptr, null);
    try std.testing.expect(GetFileAttributesW(wide.ptr) != INVALID_FILE_ATTRIBUTES);
    _ = SetEnvironmentVariableW(std.unicode.utf8ToUtf16LeStringLiteral("BEATS_DATA_DIR").ptr, wide.ptr);

    // P3: el núcleo lee y valida el override con la variante W
    // (GetEnvironmentVariableW/GetFileAttributesW), igual que el host, y
    // devuelve UTF-8: una carpeta con Ó/É/Ñ no se pierde por la página de
    // códigos ANSI.
    const resolved = try resolveDataDir(a, null);
    defer a.free(resolved.dir);
    try std.testing.expectEqual(DataDirSource.env_beats, resolved.source);
    try std.testing.expectEqualStrings(rel8z, resolved.dir);
}

test "CK-PLT-007: fallo de la API de carpetas conocidas se propaga, sin caer a la resolución heredada" {
    if (!is_windows) return @import("platform.zig").skip("T9: API y rutas de Windows (SetEnvironmentVariableA, unidades); la resolucion POSIX tiene su prueba T9");
    const a = std.testing.allocator;
    var prev_beats: [4096:0]u8 = undefined;
    var prev_alias: [4096:0]u8 = undefined;
    defer pl007RestoreEnv(pl007PrevEnv("BEATS_DATA_DIR", &prev_beats), pl007PrevEnv("DEVAGENTS_DATA_DIR", &prev_alias));

    _ = SetEnvironmentVariableA("BEATS_DATA_DIR", null);
    _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", null);
    pl007_force_default_unavailable = true;
    defer pl007_force_default_unavailable = false;

    // Si la API de carpetas conocidas falla, el error se PROPAGA: ni
    // resolveDataDir ni ningún consumidor (CLI, MCP, núcleo) puede abrir una
    // base relativa al cwd ni la heredada sin la protección de.
    try std.testing.expectError(error.DefaultDataDirUnavailable, resolveDataDir(a, null));
    try std.testing.expectError(error.DefaultDataDirUnavailable, canonicalDbPath(a, "runtime.db"));
    try std.testing.expectError(error.DefaultDataDirUnavailable, runtimeDb(a));
    try std.testing.expectError(error.DefaultDataDirUnavailable, catalogDb(a));
    try std.testing.expectError(error.DefaultDataDirUnavailable, ledgerDb(a));
    try std.testing.expectError(error.DefaultDataDirUnavailable, pluginsDir(a));
}

// ---------------------------------------------------------------------------
// T9 (, motor): la misma resolucion fuera de Windows.
// BEATS_DATA_DIR > DEVAGENTS_DATA_DIR (ruta absoluta y carpeta existente; si
//   no, fallo cerrado) > $XDG_DATA_HOME/devagents > $HOME/.local/share/devagents.
// La creacion y la proteccion (0700, propietario) siguen en la apertura.
// ---------------------------------------------------------------------------
fn resolvePosixDataDir(allocator: std.mem.Allocator) ResolveDataDirError!ResolvedDataDir {
    const env_names = [_]struct { name: [:0]const u8, source: DataDirSource }{
        .{ .name = "BEATS_DATA_DIR", .source = .env_beats },
        .{ .name = "DEVAGENTS_DATA_DIR", .source = .env_alias },
    };
    for (env_names) |entry| {
        const raw = std.c.getenv(entry.name) orelse continue;
        const value = std.mem.span(raw);
        if (value.len == 0) continue;
        if (value.len >= 4096) return error.DataDirOverrideInvalid;
        try validatePosixOverride(allocator, value);
        return .{ .dir = try allocator.dupe(u8, value), .source = entry.source };
    }
    if (pl007_force_default_unavailable) return error.DefaultDataDirUnavailable;
    const dir = if (std.c.getenv("XDG_DATA_HOME")) |xdg| blk: {
        const base = std.mem.span(xdg);
        // La especificacion XDG manda ignorar un valor relativo.
        if (std.fs.path.isAbsolutePosix(base)) break :blk try std.fs.path.join(allocator, &.{ base, "devagents" });
        break :blk null;
    } else null;
    if (dir) |d| return .{ .dir = d, .source = .default_known_folders };
    const home = std.mem.span(std.c.getenv("HOME") orelse return error.DefaultDataDirUnavailable);
    if (!std.fs.path.isAbsolutePosix(home)) return error.DefaultDataDirUnavailable;
    return .{ .dir = try std.fs.path.join(allocator, &.{ home, ".local", "share", "devagents" }), .source = .default_known_folders };
}

fn validatePosixOverride(allocator: std.mem.Allocator, path: []const u8) ResolveDataDirError!void {
    if (!std.fs.path.isAbsolutePosix(path) or std.mem.indexOfScalar(u8, path, 0) != null) return error.DataDirOverrideInvalid;
    const z = try allocator.dupeZ(u8, path);
    defer allocator.free(z);
    const meta = @import("providers").posix_stat.get(std.c.AT.FDCWD, z) catch return error.DataDirOverrideInvalid;
    if (meta.mode & std.c.S.IFMT != std.c.S.IFDIR) return error.DataDirOverrideInvalid;
}

test "T9 POSIX: resolucion de la carpeta de datos (override, fallo cerrado y XDG)" {
    if (is_windows) return @import("platform.zig").skip("T9: resolucion POSIX; Windows la cubren las pruebas CK-PLT-007");
    const a = std.testing.allocator;
    const io = std.testing.io;
    const saved = struct {
        fn get(name: [:0]const u8) ?[:0]u8 {
            const raw = std.c.getenv(name) orelse return null;
            return std.testing.allocator.dupeZ(u8, std.mem.span(raw)) catch null;
        }
        fn put(name: [:0]const u8, value: ?[:0]u8) void {
            if (value) |v| {
                _ = setenv(name, v, 1);
                std.testing.allocator.free(v);
            } else _ = unsetenv(name);
        }
        extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
        extern "c" fn unsetenv(name: [*:0]const u8) c_int;
    };
    const legacy = saved.get("BEATS_DATA_DIR");
    const alias = saved.get("DEVAGENTS_DATA_DIR");
    const xdg = saved.get("XDG_DATA_HOME");
    defer {
        saved.put("BEATS_DATA_DIR", legacy);
        saved.put("DEVAGENTS_DATA_DIR", alias);
        saved.put("XDG_DATA_HOME", xdg);
    }
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const base_z = try a.dupeZ(u8, base);
    defer a.free(base_z);

    _ = saved.unsetenv("BEATS_DATA_DIR");
    _ = saved.setenv("DEVAGENTS_DATA_DIR", "relativa", 1);
    try std.testing.expectError(error.DataDirOverrideInvalid, resolveDataDir(a, null));
    _ = saved.setenv("DEVAGENTS_DATA_DIR", "/no/existe/t9-devagents", 1);
    try std.testing.expectError(error.DataDirOverrideInvalid, runtimeDb(a));
    _ = saved.setenv("DEVAGENTS_DATA_DIR", base_z, 1);
    {
        const r = try resolveDataDir(a, null);
        defer a.free(r.dir);
        try std.testing.expectEqual(DataDirSource.env_alias, r.source);
        try std.testing.expectEqualStrings(base, r.dir);
        const db = try runtimeDb(a);
        defer a.free(db);
        try std.testing.expect(std.mem.startsWith(u8, db, base) and std.mem.endsWith(u8, db, "/runtime.db"));
    }
    _ = saved.unsetenv("DEVAGENTS_DATA_DIR");
    _ = saved.setenv("XDG_DATA_HOME", base_z, 1);
    {
        const r = try resolveDataDir(a, null);
        defer a.free(r.dir);
        try std.testing.expectEqual(DataDirSource.default_known_folders, r.source);
        try std.testing.expect(std.mem.endsWith(u8, r.dir, "/devagents"));
    }
}
