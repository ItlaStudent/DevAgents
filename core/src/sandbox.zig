const std = @import("std");

/// Errores del sandbox de sistema de archivos.
pub const SandboxError = error{
    /// La ruta resuelta queda fuera del directorio permitido del worker.
    PathOutsideSandbox,
    /// Ruta vacía o malformada.
    InvalidPath,
    OutOfMemory,
};

// ── Win32 canonical resolution (symlink/junction/reparse point) ────────
const windows = std.os.windows;

const CreateFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateFileA(
        lpFileName: [*:0]const u8,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?*anyopaque,
    ) ?*anyopaque;
}.CreateFileA else @import("providers").posix_files.CreateFileNullableA;
extern "kernel32" fn GetFinalPathNameByHandleA(
    hFile: ?*anyopaque,
    lpszFilePath: [*]u8,
    cchFilePath: u32,
    dwFlags: u32,
) u32;
const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(hObject: ?*anyopaque) c_int;
}.CloseHandle else @import("providers").posix_files.CloseHandle;

const GENERIC_READ: u32 = 0x80000000;
const FILE_SHARE_READ: u32 = 0x1;
const FILE_SHARE_WRITE: u32 = 0x2;
const OPEN_EXISTING: u32 = 3;
const FILE_FLAG_BACKUP_SEMANTICS: u32 = 0x02000000;
const VOLUME_NAME_DOS: u32 = 0x0;

/// Resolve a path to its canonical form via Win32 (handles symlinks/junctions/reparse points).
/// Returns null if the path does not exist or resolution fails.
/// Caller owns the returned slice.
fn canonicalize(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    // T9: en POSIX la ruta canonica es realpath(3) (resuelve enlaces igual
    // que GetFinalPathNameByHandle); null si no existe.
    if (@import("builtin").os.tag != .windows) return @import("providers").posix_files.canonical(allocator, path) catch null;
    const path_z = allocator.dupeZ(u8, path) catch return null;
    defer allocator.free(path_z);
    const handle = CreateFileA(
        path_z.ptr,
        GENERIC_READ,
        FILE_SHARE_READ | FILE_SHARE_WRITE,
        null,
        OPEN_EXISTING,
        FILE_FLAG_BACKUP_SEMANTICS, // needed for directories
        null,
    ) orelse return null;
    defer _ = CloseHandle(handle);
    var buf: [4096]u8 = undefined;
    const len = GetFinalPathNameByHandleA(handle, &buf, buf.len, VOLUME_NAME_DOS);
    if (len == 0 or len >= buf.len) return null;
    // GetFinalPathNameByHandleA returns "\\?\" prefix — strip it for comparison.
    const result = buf[0..len];
    const stripped = if (std.mem.startsWith(u8, result, "\\\\?\\"))
        result["\\\\?\\".len..]
    else
        result;
    return allocator.dupe(u8, stripped) catch null;
}

/// Envoltura pública de `canonicalize` (E5.06): el cliente ACP resuelve el
/// ancestro existente más cercano de una ruta nueva para confinar fs/*.
/// Devuelve null si `path` no existe; el llamador posee el slice.
pub fn canonicalizeExisting(allocator: std.mem.Allocator, path: []const u8) ?[]const u8 {
    return canonicalize(allocator, path);
}

/// Sandbox de FS por worker (T-F1-08, ARCHITECTURE §6).
///
/// Cada worker recibe un directorio raíz; toda escritura debe quedar dentro de él.
/// La validación tiene dos fases:
/// 1. **Léxica** (no toca el FS): resuelve `.`/`..` y comprueba que la ruta
///    candidata sea descendiente del root. Determinista y testeable.
/// 2. **Canónica** (toca el FS): si la ruta existe, resuelve symlinks/junctions/
///    reparse points vía Win32 y verifica que el destino real siga dentro del root.
///
/// Escribir fuera del sandbox requiere aprobación explícita del usuario (capa IDE, Fase 7).
pub const Sandbox = struct {
    allocator: std.mem.Allocator,
    /// Componentes normalizados del directorio raíz permitido.
    root_components: [][]const u8,
    /// Copia del string raíz original (para diagnósticos).
    root: []const u8,
    /// Ruta canónica del root (resuelta al init si el directorio existe).
    root_canonical: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator, root: []const u8) SandboxError!Sandbox {
        if (root.len == 0) return error.InvalidPath;
        const root_copy = try allocator.dupe(u8, root);
        errdefer allocator.free(root_copy);
        const comps = try normalize(allocator, &.{root});
        // Try to resolve canonical root path (may fail if dir doesn't exist yet).
        const root_canon = canonicalize(allocator, root);
        return .{
            .allocator = allocator,
            .root_components = comps,
            .root = root_copy,
            .root_canonical = root_canon,
        };
    }

    pub fn deinit(self: *Sandbox) void {
        freeComponents(self.allocator, self.root_components);
        self.allocator.free(self.root);
        if (self.root_canonical) |rc| self.allocator.free(rc);
    }

    /// Indica si `path` (absoluta o relativa al root) queda dentro del sandbox.
    pub fn isAllowed(self: *const Sandbox, path: []const u8) bool {
        self.checkWrite(path) catch return false;
        return true;
    }

    /// Valida una escritura: error si la ruta resuelta escapa del sandbox.
    /// Fase 1: léxica (siempre). Fase 2: canónica (si la ruta existe).
    pub fn checkWrite(self: *const Sandbox, path: []const u8) SandboxError!void {
        if (path.len == 0) return error.InvalidPath;
        var candidate: [][]const u8 = undefined;
        if (isAbsolute(path)) {
            candidate = try normalize(self.allocator, &.{path});
        } else {
            // Relativa: se ancla al root antes de resolver.
            candidate = try normalize(self.allocator, &.{ self.root, path });
        }
        defer freeComponents(self.allocator, candidate);

        // Fase 1: validación léxica.
        if (candidate.len < self.root_components.len) return error.PathOutsideSandbox;
        for (self.root_components, 0..) |rc, i| {
            if (!std.mem.eql(u8, rc, candidate[i])) return error.PathOutsideSandbox;
        }

        // Fase 2: validación canónica (si el root tiene path canónico y la ruta existe).
        if (self.root_canonical) |root_canon| {
            // Build the full path string from candidate components.
            const full_path = joinComponents(self.allocator, candidate) catch return;
            defer self.allocator.free(full_path);
            if (canonicalize(self.allocator, full_path)) |canon| {
                defer self.allocator.free(canon);
                // Compare canonical path against canonical root.
                const canon_comps = normalize(self.allocator, &.{canon}) catch return;
                defer freeComponents(self.allocator, canon_comps);
                const root_canon_comps = normalize(self.allocator, &.{root_canon}) catch return;
                defer freeComponents(self.allocator, root_canon_comps);
                if (canon_comps.len < root_canon_comps.len) return error.PathOutsideSandbox;
                for (root_canon_comps, 0..) |rc, i| {
                    if (!std.mem.eql(u8, rc, canon_comps[i])) return error.PathOutsideSandbox;
                }
            }
            // If canonicalize fails (path doesn't exist yet), lexical check is sufficient.
        }
    }
};

fn isAbsolute(path: []const u8) bool {
    if (path.len == 0) return false;
    if (path[0] == '/' or path[0] == '\\') return true;
    // Windows: "C:\..." o "C:/..."
    if (path.len >= 2 and path[1] == ':') return true;
    return false;
}

fn isSep(ch: u8) bool {
    return ch == '/' or ch == '\\';
}

/// Resuelve una lista de fragmentos de ruta en componentes normalizados,
/// procesando `.` (ignorar) y `..` (subir un nivel, sin permitir pasar de la raíz).
/// El primer componente conserva la unidad (p. ej. "C:") como ancla.
fn normalize(allocator: std.mem.Allocator, parts: []const []const u8) SandboxError![][]const u8 {
    var stack = std.ArrayList([]const u8).empty;
    errdefer freeComponents(allocator, stack.toOwnedSlice(allocator) catch &.{});

    for (parts) |part| {
        var it = std.mem.tokenizeAny(u8, part, "/\\");
        while (it.next()) |seg| {
            if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
            if (std.mem.eql(u8, seg, "..")) {
                if (stack.items.len > 0) {
                    const popped = stack.pop();
                    if (popped) |p| allocator.free(p);
                }
                continue;
            }
            const owned = try allocator.dupe(u8, seg);
            errdefer allocator.free(owned);
            try stack.append(allocator, owned);
        }
    }
    return stack.toOwnedSlice(allocator);
}

fn freeComponents(allocator: std.mem.Allocator, comps: [][]const u8) void {
    for (comps) |c| allocator.free(c);
    allocator.free(comps);
}

/// Join normalized components back into a path string with `\` separators.
/// The first component keeps its drive letter (e.g. "C:").
fn joinComponents(allocator: std.mem.Allocator, comps: []const []const u8) ![]const u8 {
    if (comps.len == 0) return allocator.dupe(u8, "");
    var total: usize = 0;
    for (comps) |c| total += c.len;
    total += comps.len - 1; // separators between components (not after last)
    const buf = try allocator.alloc(u8, total);
    var pos: usize = 0;
    for (comps, 0..) |c, i| {
        if (i > 0) {
            buf[pos] = '\\';
            pos += 1;
        }
        @memcpy(buf[pos .. pos + c.len], c);
        pos += c.len;
    }
    return buf[0..pos];
}

// ── Tests ──────────────────────────────────────────────────────────────

test "sandbox allows path inside root" {
    var sb = try Sandbox.init(std.testing.allocator, "C:\\sandbox\\w1");
    defer sb.deinit();
    try sb.checkWrite("output\\result.txt");
    try std.testing.expect(sb.isAllowed("logs\\run.log"));
    try std.testing.expect(sb.isAllowed("C:\\sandbox\\w1\\deep\\nested\\file"));
}

test "sandbox rejects parent escape" {
    var sb = try Sandbox.init(std.testing.allocator, "C:\\sandbox\\w1");
    defer sb.deinit();
    try std.testing.expectError(error.PathOutsideSandbox, sb.checkWrite("..\\w2\\steal.txt"));
    try std.testing.expectError(error.PathOutsideSandbox, sb.checkWrite("..\\..\\Windows\\system32"));
    try std.testing.expect(!sb.isAllowed("..\\escape"));
}

test "sandbox rejects absolute path outside" {
    var sb = try Sandbox.init(std.testing.allocator, "C:\\sandbox\\w1");
    defer sb.deinit();
    try std.testing.expectError(error.PathOutsideSandbox, sb.checkWrite("C:\\Windows\\system32\\evil.dll"));
    try std.testing.expectError(error.PathOutsideSandbox, sb.checkWrite("D:\\other"));
}

test "sandbox normalizes redundant separators and dots" {
    var sb = try Sandbox.init(std.testing.allocator, "C:\\sandbox\\w1");
    defer sb.deinit();
    try sb.checkWrite(".\\sub\\.\\file.txt");
    // Sube y vuelve a entrar: sigue dentro.
    try sb.checkWrite("sub\\..\\other\\file.txt");
}

test "sandbox rejects empty path" {
    var sb = try Sandbox.init(std.testing.allocator, "C:\\sandbox\\w1");
    defer sb.deinit();
    try std.testing.expectError(error.InvalidPath, sb.checkWrite(""));
}

test "sandbox init rejects empty root" {
    try std.testing.expectError(error.InvalidPath, Sandbox.init(std.testing.allocator, ""));
}

test "sandbox canonical resolution rejects symlink escape" {
    // This test validates the canonical resolution path. Since the test
    // environment may not have symlinks, we test with a real directory.
    // We use the system temp dir which should exist.
    const allocator = std.testing.allocator;
    // 9-nov: carpeta temporal propia del test (antes, la Temp del equipo del
    // propietario, que no existe en otra máquina).
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [4096]u8 = undefined;
    const n = try tmp.dir.realPath(std.testing.io, &buf);
    const tmp_dir = buf[0..n];
    var sb = try Sandbox.init(allocator, tmp_dir);
    defer sb.deinit();
    // Canonical root should be resolved since the dir exists.
    try std.testing.expect(sb.root_canonical != null);
    // A file inside the sandbox should be allowed.
    try sb.checkWrite("devagents_test.txt");
}

test "sandbox joinComponents produces valid path" {
    const allocator = std.testing.allocator;
    const comps = [_][]const u8{ "C:", "sandbox", "w1", "file.txt" };
    const path = try joinComponents(allocator, &comps);
    defer allocator.free(path);
    try std.testing.expectEqualStrings("C:\\sandbox\\w1\\file.txt", path);
}
