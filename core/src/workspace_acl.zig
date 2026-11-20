const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;
const confined = @import("confined_fs.zig");
const is_windows = builtin.os.tag == .windows;
// T9: fuera de Windows no hay DACL. El equivalente que se captura y restaura
// es el modo (permisos rwx) y el propietario de la raiz retenida; la identidad
// es dispositivo+inodo. Ver `posix` al final del archivo.

extern fn da_workspace_permissions_capture([*:0]const u16, *?*anyopaque) u32;
extern fn da_workspace_permissions_free(?*anyopaque) void;
extern fn da_workspace_permissions_restore(?*anyopaque) u32;
extern fn da_workspace_permissions_rewritten(?*anyopaque) c_int;
extern fn da_workspace_permissions_identity(?*anyopaque, [*]u8, u32) u32;
extern fn da_workspace_permissions_handle(?*anyopaque) windows.HANDLE;
extern fn da_workspace_identity([*:0]const u16, [*]u8, u32) u32;
extern fn da_workspace_test_path_sddl([*:0]const u16, *?[*:0]u8) u32;
extern fn da_workspace_permissions_sddl(?*anyopaque, *?[*:0]u8) u32;
extern fn da_workspace_restore_private([*:0]const u16) u32;
extern fn da_workspace_writers([*:0]const u16, [*]u8, u32) u32;
extern fn da_workspace_permissions_test_set(?*anyopaque, [*:0]const u16) u32;
extern fn da_workspace_writers_test_sddl([*:0]const u16, [*]u8, u32) u32;
extern "kernel32" fn LocalFree(*anyopaque) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn GetLastError() callconv(.winapi) u32;
extern "kernel32" fn SetLastError(u32) callconv(.winapi) void;

pub fn lastError() u32 {
    if (!is_windows) return @intCast(std.c._errno().*);
    return GetLastError();
}

/// Código nativo (DA_WORKSPACE_TREE_HAS_LINKS): el árbol contiene enlaces
/// (junction, symlink o vínculo físico). Solo se restauró la raíz.
pub const tree_links_code: u32 = 0xE0DA0001;

/// Las raíces con el nombre del espacio gobernado deben seguir siendo privadas.
pub fn isGoverned(path: []const u8) bool {
    return std.ascii.eqlIgnoreCase(std.fs.path.basenameWindows(path), @import("workspace.zig").WORKSPACE_ROOT);
}

fn widePath(a: std.mem.Allocator, path: []const u8) ![:0]u16 {
    if (path.len == 0 or std.mem.indexOfScalar(u8, path, 0) != null) {
        SetLastError(123);
        return error.InvalidPath;
    }
    const extended = if (std.mem.startsWith(u8, path, "\\\\"))
        try std.fmt.allocPrint(a, "\\\\?\\UNC\\{s}", .{path[2..]})
    else
        try std.fmt.allocPrint(a, "\\\\?\\{s}", .{path});
    defer a.free(extended);
    return std.unicode.utf8ToUtf16LeAllocZ(a, extended);
}

fn retainRoot(a: std.mem.Allocator, path: []const u8, code: *u32) !confined.Root {
    code.* = 0;
    if (!is_windows) {
        var root = confined.Root.initDiagnostic(a, path, code) catch |err| {
            if (code.* == 0 and err != error.OutOfMemory) code.* = 13;
            return err;
        };
        root.windows_error = null;
        return root;
    }
    if (!std.fs.path.isAbsoluteWindows(path) or std.mem.indexOfScalar(u8, path, 0) != null) {
        code.* = 123;
        SetLastError(code.*);
        return error.InvalidPath;
    }
    var root = confined.Root.initDiagnostic(a, path, code) catch |err| {
        if (code.* == 0 and err != error.OutOfMemory) code.* = if (err == error.SandboxDenied) 4393 else 13;
        SetLastError(code.*);
        return err;
    };
    // Capture's diagnostic pointer belongs to the caller, not this retained root.
    root.windows_error = null;
    return root;
}

/// Owns the root handle and the original Win32 descriptor. READ/WRITE sharing
/// permits CLI edits; omitting DELETE sharing prevents root replacement.
pub const Snapshot = struct {
    retained: ?*anyopaque = null,
    retained_root: ?confined.Root = null,
    last_error: u32 = 0,
    /// T9 (POSIX): modo y propietario capturados de la raiz retenida.
    posix_mode: u32 = 0,
    posix_uid: u32 = 0,
    posix_rewritten: bool = false,

    pub fn init(a: std.mem.Allocator, path: []const u8) !Snapshot {
        var code: u32 = 0;
        return initDiagnostic(a, path, &code);
    }

    /// init cannot return a Snapshot on error, so its Win32 code is also
    /// available explicitly to the caller's diagnostic/event storage.
    pub fn initDiagnostic(a: std.mem.Allocator, path: []const u8, code: *u32) !Snapshot {
        code.* = 0;
        if (!is_windows) {
            var root = retainRoot(a, path, code) catch |err| {
                return if (err == error.OutOfMemory) err else error.WorkspacePermissionsCaptureFailed;
            };
            errdefer root.deinit();
            const meta = posix.stat(root.dir().handle) catch {
                code.* = @intCast(std.c._errno().*);
                return error.WorkspacePermissionsCaptureFailed;
            };
            return .{ .retained_root = root, .posix_mode = meta.mode & 0o7777, .posix_uid = meta.uid };
        }
        defer if (code.* != 0) SetLastError(code.*);
        var root = retainRoot(a, path, code) catch |err| {
            return if (err == error.OutOfMemory) err else error.WorkspacePermissionsCaptureFailed;
        };
        errdefer root.deinit();
        const wide = try widePath(a, root.canonical);
        defer a.free(wide);
        var result: Snapshot = .{ .retained_root = root };
        code.* = da_workspace_permissions_capture(wide.ptr, &result.retained);
        if (code.* != 0) {
            SetLastError(code.*);
            return error.WorkspacePermissionsCaptureFailed;
        }
        return result;
    }

    pub fn deinit(self: *Snapshot) void {
        if (is_windows) da_workspace_permissions_free(self.retained);
        self.retained = null;
        if (self.retained_root) |*root| root.deinit();
        self.retained_root = null;
    }

    /// El descriptor vivo difería del capturado y hubo que reescribirlo. Falso
    /// cuando propietario, DACL y control ya coincidían (no se propaga nada).
    pub fn rewritten(self: *const Snapshot) bool {
        if (!is_windows) return self.posix_rewritten;
        return da_workspace_permissions_rewritten(self.retained) != 0;
    }

    /// El handle retenido de la raíz, para compuertas ACL sin reabrir la ruta.
    pub fn handle(self: *const Snapshot) std.posix.fd_t {
        if (!is_windows) return self.retained_root.?.dir().handle;
        return da_workspace_permissions_handle(self.retained);
    }

    /// Identidad estable del directorio retenido (volumen + FileId, hex).
    pub fn identity(self: *const Snapshot, a: std.mem.Allocator) ![]u8 {
        if (!is_windows) return posix.identityText(a, self.handle());
        var buffer: [64]u8 = undefined;
        const code = da_workspace_permissions_identity(self.retained, &buffer, buffer.len);
        if (code != 0) {
            SetLastError(code);
            return error.WorkspacePermissionsInspectFailed;
        }
        return a.dupe(u8, std.mem.sliceTo(&buffer, 0));
    }

    /// Compuerta del espacio gobernado sobre el handle YA retenido (no sobre la
    /// ruta): un espacio contaminado entre la comprobación previa y la captura,
    /// o tras restaurar, falla aquí con CliWritableByOthers.
    pub fn checkGoverned(self: *const Snapshot, path: []const u8) !void {
        if (!isGoverned(path)) return;
        try @import("external_cli_policy.zig").checkAcl(self.handle());
    }

    /// Solo pruebas: sustituye el descriptor VIVO de la raíz retenida (con
    /// propagación a los hijos), p. ej. para simular a un CLI que añade ACE.
    pub fn setDescriptorForTest(self: *Snapshot, a: std.mem.Allocator, sddl_text: []const u8) !void {
        if (!builtin.is_test) @compileError("test helper is unavailable in production");
        if (!is_windows) return error.WorkspacePermissionsUnavailableOnLinux;
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, sddl_text);
        defer a.free(wide);
        const code = da_workspace_permissions_test_set(self.retained, wide.ptr);
        if (code != 0) {
            SetLastError(code);
            return error.WorkspacePermissionsRestoreFailed;
        }
    }

    /// Solo pruebas: añade a la raíz una ACE heredable (OI)(CI) de escritura
    /// para «Todos», como la que deja el sandbox de Codex.
    pub fn widenForTest(self: *Snapshot, a: std.mem.Allocator) !void {
        if (!is_windows) {
            // Lo que haria un CLI que abre la carpeta a todos: escritura de otros.
            if (std.c.fchmod(self.handle(), @intCast(self.posix_mode | 0o002)) != 0) return error.WorkspacePermissionsRestoreFailed;
            return;
        }
        const current = try self.sddl(a);
        defer a.free(current);
        const widened = try std.fmt.allocPrint(a, "{s}(A;OICI;FW;;;WD)", .{current});
        defer a.free(widened);
        try self.setDescriptorForTest(a, widened);
    }

    pub fn restore(self: *Snapshot) !void {
        if (!is_windows) {
            const meta = posix.stat(self.handle()) catch {
                self.last_error = @intCast(std.c._errno().*);
                return error.WorkspacePermissionsRestoreFailed;
            };
            // Sin privilegios no se puede devolver un propietario cambiado.
            if (meta.uid != self.posix_uid) {
                self.last_error = 1;
                return error.WorkspacePermissionsRestoreFailed;
            }
            if (meta.mode & 0o7777 == self.posix_mode) return;
            if (std.c.fchmod(self.handle(), @intCast(self.posix_mode)) != 0) {
                self.last_error = @intCast(std.c._errno().*);
                return error.WorkspacePermissionsRestoreFailed;
            }
            self.posix_rewritten = true;
            return;
        }
        self.last_error = da_workspace_permissions_restore(self.retained);
        if (self.last_error == tree_links_code) return error.WorkspaceTreeHasLinks;
        if (self.last_error != 0) {
            SetLastError(self.last_error);
            return error.WorkspacePermissionsRestoreFailed;
        }
    }

    /// Current owner/DACL SDDL on the retained object, for exact comparisons.
    pub fn sddl(self: *Snapshot, a: std.mem.Allocator) ![]u8 {
        if (!is_windows) {
            const meta = posix.stat(self.handle()) catch return error.WorkspacePermissionsCaptureFailed;
            return std.fmt.allocPrint(a, "uid={d};mode={o:0>4}", .{ meta.uid, meta.mode & 0o7777 });
        }
        var output: ?[*:0]u8 = null;
        self.last_error = da_workspace_permissions_sddl(self.retained, &output);
        if (self.last_error != 0) {
            SetLastError(self.last_error);
            return error.WorkspacePermissionsCaptureFailed;
        }
        const value = output orelse return error.WorkspacePermissionsCaptureFailed;
        defer _ = LocalFree(value);
        return a.dupe(u8, std.mem.span(value));
    }
};

/// Explicit user action. Uses the same descriptor constructor as the default
/// workspace's private-directory creation; it never removes child explicit ACEs.
pub fn restorePrivate(a: std.mem.Allocator, path: []const u8) !void {
    if (!is_windows) {
        var code: u32 = 0;
        var root = retainRoot(a, path, &code) catch |err| return if (err == error.OutOfMemory) err else error.WorkspacePermissionsRestoreFailed;
        defer root.deinit();
        const meta = posix.stat(root.dir().handle) catch return error.WorkspacePermissionsRestoreFailed;
        if (meta.uid != std.c.getuid()) return error.WorkspacePermissionsRestoreFailed;
        if (std.c.fchmod(root.dir().handle, 0o700) != 0) return error.WorkspacePermissionsRestoreFailed;
        return;
    }
    var diagnostic: u32 = 0;
    defer if (diagnostic != 0) SetLastError(diagnostic);
    var root = retainRoot(a, path, &diagnostic) catch |err| return if (err == error.OutOfMemory) err else error.WorkspacePermissionsRestoreFailed;
    defer root.deinit();
    const wide = try widePath(a, root.canonical);
    defer a.free(wide);
    const code = da_workspace_restore_private(wide.ptr);
    if (code == tree_links_code) return error.WorkspaceTreeHasLinks;
    if (code != 0) {
        diagnostic = code;
        SetLastError(code);
        return error.WorkspacePermissionsRestoreFailed;
    }
}

/// Raíz canónica y su identidad (volumen + FileId) tal como existen ahora.
pub const RootIdentity = struct {
    canonical: []u8,
    id: []u8,

    pub fn deinit(self: *RootIdentity, a: std.mem.Allocator) void {
        a.free(self.canonical);
        a.free(self.id);
    }
};

pub fn identity(a: std.mem.Allocator, path: []const u8) !RootIdentity {
    if (!is_windows) {
        var code: u32 = 0;
        var root = retainRoot(a, path, &code) catch |err| return if (err == error.OutOfMemory) err else error.WorkspacePermissionsInspectFailed;
        defer root.deinit();
        const id = try posix.identityText(a, root.dir().handle);
        errdefer a.free(id);
        return .{ .canonical = try a.dupe(u8, root.canonical), .id = id };
    }
    var diagnostic: u32 = 0;
    defer if (diagnostic != 0) SetLastError(diagnostic);
    var root = retainRoot(a, path, &diagnostic) catch |err| return if (err == error.OutOfMemory) err else error.WorkspacePermissionsInspectFailed;
    defer root.deinit();
    const wide = try widePath(a, root.canonical);
    defer a.free(wide);
    var buffer: [64]u8 = undefined;
    const code = da_workspace_identity(wide.ptr, &buffer, buffer.len);
    if (code != 0) {
        diagnostic = code;
        return error.WorkspacePermissionsInspectFailed;
    }
    const canonical = try a.dupe(u8, root.canonical);
    errdefer a.free(canonical);
    return .{ .canonical = canonical, .id = try a.dupe(u8, std.mem.sliceTo(&buffer, 0)) };
}

/// Human-readable effective writers, one principal per line. Denied grants
/// and INHERIT_ONLY ACEs do not count; unmapped SIDs never appear as raw IDs.
pub fn writers(a: std.mem.Allocator, path: []const u8) ![]u8 {
    if (!is_windows) {
        var code: u32 = 0;
        var root = retainRoot(a, path, &code) catch |err| return if (err == error.OutOfMemory) err else error.WorkspacePermissionsInspectFailed;
        defer root.deinit();
        const meta = posix.stat(root.dir().handle) catch return error.WorkspacePermissionsInspectFailed;
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        if (meta.mode & 0o020 != 0) try out.appendSlice(a, "grupo propietario (escritura de grupo)\n");
        if (meta.mode & 0o002 != 0) try out.appendSlice(a, "otros usuarios (escritura de otros)\n");
        return out.toOwnedSlice(a);
    }
    var diagnostic: u32 = 0;
    defer if (diagnostic != 0) SetLastError(diagnostic);
    var root = retainRoot(a, path, &diagnostic) catch |err| return if (err == error.OutOfMemory) err else error.WorkspacePermissionsInspectFailed;
    defer root.deinit();
    const wide = try widePath(a, root.canonical);
    defer a.free(wide);
    var capacity: usize = 4096;
    while (capacity <= 1024 * 1024) : (capacity *= 2) {
        const buffer = try a.alloc(u8, capacity);
        defer a.free(buffer);
        const code = da_workspace_writers(wide.ptr, buffer.ptr, @intCast(buffer.len));
        if (code == 122) continue;
        if (code != 0) {
            diagnostic = code;
            SetLastError(code);
            return error.WorkspacePermissionsInspectFailed;
        }
        const len = std.mem.indexOfScalar(u8, buffer, 0) orelse return error.WorkspacePermissionsInspectFailed;
        return a.dupe(u8, buffer[0..len]);
    }
    diagnostic = 122;
    return error.WorkspacePermissionsInspectFailed;
}

fn setTestDescriptor(a: std.mem.Allocator, snapshot: *Snapshot, descriptor: []const u8) !void {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, descriptor);
    defer a.free(wide);
    try std.testing.expectEqual(@as(u32, 0), da_workspace_permissions_test_set(snapshot.retained, wide.ptr));
}

test "RELOJ SNAP workspace ACL snapshot restores original SDDL after foreign writes" {
    if (!is_windows) return @import("platform.zig").skip("T9: DACL/SDDL y enlaces de Windows; el modo POSIX tiene su prueba T9");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "space", .default_dir);
    const path = try tmp.dir.realPathFileAlloc(io, "space", a);
    defer a.free(path);
    try restorePrivate(a, path);
    var snapshot = try Snapshot.init(a, path);
    defer snapshot.deinit();
    const original = try snapshot.sddl(a);
    defer a.free(original);
    const dacl = std.mem.indexOf(u8, original, "D:") orelse return error.TestUnexpectedResult;
    const changed = try std.fmt.allocPrint(a, "{s}D:P(A;OICI;FA;;;WD){s}", .{ original[0..dacl], original[dacl + 3 ..] });
    defer a.free(changed);
    try setTestDescriptor(a, &snapshot, changed);
    const foreign = try snapshot.sddl(a);
    defer a.free(foreign);
    try std.testing.expect(!std.mem.eql(u8, original, foreign));
    const before_writers = try writers(a, path);
    defer a.free(before_writers);
    try std.testing.expect(std.mem.indexOf(u8, before_writers, "S-1-") == null);
    try snapshot.restore();
    const restored = try snapshot.sddl(a);
    defer a.free(restored);
    try std.testing.expectEqualStrings(original, restored);
    try std.testing.expectEqual(@as(u32, 0), snapshot.last_error);
    // All retained resources released, including the missing-delete-share handle.
    snapshot.deinit();
    try tmp.dir.deleteTree(io, "space");
}

test "T2d-D4: una carpeta que hereda permisos (D:AI) se restaura tras las ACE que añade Codex" {
    if (!is_windows) return @import("platform.zig").skip("T9: DACL/SDDL y enlaces de Windows; el modo POSIX tiene su prueba T9");
    // Carpeta corriente de usuario: DACL heredada, sin restorePrivate. Antes
    // del arreglo la raíz volvía como «D:» sin AI y restore() daba 1338.
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // El temporal de la suite (mkdtemp de Python 3.12+) es una DACL protegida
    // sin AI; se monta aquí un padre auto-heredable como un perfil de usuario.
    try tmp.dir.createDir(io, "parent", .default_dir);
    const parent_path = try tmp.dir.realPathFileAlloc(io, "parent", a);
    defer a.free(parent_path);
    {
        var parent = try Snapshot.init(a, parent_path);
        defer parent.deinit();
        const current = try parent.sddl(a);
        defer a.free(current);
        const owner_end = std.mem.indexOf(u8, current, "D:") orelse return error.TestUnexpectedResult;
        const owner_sid = current[2..owner_end];
        const parent_sddl = try std.fmt.allocPrint(a, "O:{s}D:PAI(A;OICI;FA;;;SY)(A;OICI;FA;;;BA)(A;OICI;FA;;;{s})", .{ owner_sid, owner_sid });
        defer a.free(parent_sddl);
        try setTestDescriptor(a, &parent, parent_sddl);
    }
    try tmp.dir.createDir(io, "parent/space", .default_dir);
    const path = try tmp.dir.realPathFileAlloc(io, "parent/space", a);
    defer a.free(path);
    var snapshot = try Snapshot.init(a, path);
    defer snapshot.deinit();
    const original = try snapshot.sddl(a);
    defer a.free(original);
    const dacl = std.mem.indexOf(u8, original, "D:AI") orelse {
        std.debug.print("T2d-D4: la carpeta hija no heredó con AI: {s}\n", .{original});
        return error.TestUnexpectedResult;
    };
    // Como el sandbox de Codex: ACE explícitas heredables delante de las heredadas.
    const changed = try std.fmt.allocPrint(a, "{s}D:AI(A;OICI;0x1301bf;;;WD){s}", .{ original[0..dacl], original[dacl + 4 ..] });
    defer a.free(changed);
    try setTestDescriptor(a, &snapshot, changed);
    const foreign = try snapshot.sddl(a);
    defer a.free(foreign);
    try std.testing.expect(!std.mem.eql(u8, original, foreign));
    try snapshot.restore();
    const restored = try snapshot.sddl(a);
    defer a.free(restored);
    try std.testing.expectEqualStrings(original, restored);
    try std.testing.expectEqual(@as(u32, 0), snapshot.last_error);
}

test "RELOJ SNAP workspace ACL capture and restore errors retain Win32 code" {
    if (!is_windows) return @import("platform.zig").skip("T9: DACL/SDDL y enlaces de Windows; el modo POSIX tiene su prueba T9");
    const a = std.testing.allocator;
    var code: u32 = 0;
    try std.testing.expectError(error.WorkspacePermissionsCaptureFailed, Snapshot.initDiagnostic(a, "", &code));
    try std.testing.expectEqual(@as(u32, 123), code);
    try std.testing.expectError(error.WorkspacePermissionsCaptureFailed, Snapshot.init(a, "invalid\x00path"));
    var closed: Snapshot = .{};
    closed.deinit();
    try std.testing.expectError(error.WorkspacePermissionsRestoreFailed, closed.restore());
    try std.testing.expectEqual(@as(u32, 6), closed.last_error);
    try std.testing.expectError(error.WorkspacePermissionsCaptureFailed, closed.sddl(a));
    try std.testing.expectEqual(@as(u32, 6), closed.last_error);
    try std.testing.expectError(error.WorkspacePermissionsRestoreFailed, restorePrivate(a, ""));
    try std.testing.expectError(error.WorkspacePermissionsInspectFailed, writers(a, ""));
    for ([_][]const u8{ ".", "space", "C:space", "C:\\invalid\x00path" }) |path| {
        try std.testing.expectError(error.WorkspacePermissionsCaptureFailed, Snapshot.init(a, path));
        try std.testing.expectError(error.WorkspacePermissionsRestoreFailed, restorePrivate(a, path));
        try std.testing.expectError(error.WorkspacePermissionsInspectFailed, writers(a, path));
    }
}

test "RELOJ SNAP explicit private repair reuses creation descriptor and preserves child explicit ACL" {
    if (!is_windows) return @import("platform.zig").skip("T9: DACL/SDDL y enlaces de Windows; el modo POSIX tiene su prueba T9");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const created = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "created", .{base});
    defer a.free(created);
    try @import("external_cli_policy.zig").createPrivateDirectory(a, created);
    var original = try Snapshot.init(a, created);
    defer original.deinit();
    const expected = try original.sddl(a);
    defer a.free(expected);
    try tmp.dir.createDir(io, "repaired", .default_dir);
    const repaired = try tmp.dir.realPathFileAlloc(io, "repaired", a);
    defer a.free(repaired);
    try restorePrivate(a, repaired);
    var root = try Snapshot.init(a, repaired);
    defer root.deinit();
    const actual = try root.sddl(a);
    defer a.free(actual);
    try std.testing.expectEqualStrings(expected, actual);
    try tmp.dir.createDirPath(io, "repaired/child");
    const child_path = try tmp.dir.realPathFileAlloc(io, "repaired/child", a);
    defer a.free(child_path);
    var child = try Snapshot.init(a, child_path);
    defer child.deinit();
    const child_before = try child.sddl(a);
    defer a.free(child_before);
    const dacl = std.mem.indexOf(u8, child_before, "D:") orelse return error.TestUnexpectedResult;
    const sid = "S-1-5-21-123-456-789-2147483646";
    // Child inherited flags follow D:; splice at its first ACE to keep SDDL valid.
    const first_ace = std.mem.indexOfScalar(u8, child_before[dacl..], '(') orelse return error.TestUnexpectedResult;
    const child_mutation = try std.fmt.allocPrint(a, "{s}(A;;FR;;;{s}){s}", .{ child_before[0 .. dacl + first_ace], sid, child_before[dacl + first_ace ..] });
    defer a.free(child_mutation);
    try setTestDescriptor(a, &child, child_mutation);
    const widened = try std.fmt.allocPrint(a, "{s}(A;OICI;FW;;;WD)", .{actual});
    defer a.free(widened);
    try setTestDescriptor(a, &root, widened);
    try restorePrivate(a, repaired);
    const child_after = try child.sddl(a);
    defer a.free(child_after);
    try std.testing.expect(std.mem.indexOf(u8, child_after, sid) != null);
    try std.testing.expect(std.mem.indexOf(u8, child_after, ";;;WD)") == null);
    const root_after = try root.sddl(a);
    defer a.free(root_after);
    try std.testing.expectEqualStrings(expected, root_after);
}

test "RELOJ SNAP workspace ACL rejects root and ancestor junction before mutation" {
    if (!is_windows) return @import("platform.zig").skip("T9: DACL/SDDL y enlaces de Windows; el modo POSIX tiene su prueba T9");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "outside/child");
    const parent = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(parent);
    const outside = try tmp.dir.realPathFileAlloc(io, "outside", a);
    defer a.free(outside);
    try restorePrivate(a, outside);
    var retained = try Snapshot.init(a, outside);
    defer retained.deinit();
    const before = try retained.sddl(a);
    defer a.free(before);
    const link = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "alias", .{parent});
    defer a.free(link);
    var mk = try @import("providers").github.runCmdCaptureWin32(a, &.{ "cmd.exe", "/d", "/c", "mklink", "/J", link, outside }, null);
    defer mk.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), mk.exit_code);
    defer tmp.dir.deleteDir(io, "alias") catch |err| std.debug.print("workspace ACL junction cleanup: {s}\n", .{@errorName(err)});
    const ancestor = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "child", .{link});
    defer a.free(ancestor);
    for ([_][]const u8{ link, ancestor }) |path| {
        try std.testing.expectError(error.WorkspacePermissionsCaptureFailed, Snapshot.init(a, path));
        try std.testing.expectError(error.WorkspacePermissionsRestoreFailed, restorePrivate(a, path));
        try std.testing.expectError(error.WorkspacePermissionsInspectFailed, writers(a, path));
    }
    const after = try retained.sddl(a);
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
}

test "RELOJ SNAP workspace writers classify synthetic SID only when effectively writable" {
    if (!is_windows) return @import("platform.zig").skip("T9: DACL/SDDL y enlaces de Windows; el modo POSIX tiene su prueba T9");
    const a = std.testing.allocator;
    const sid = "S-1-5-21-123-456-789-2147483646";
    const cases = [_]struct { sddl: []const u8, writer: bool }{
        .{ .sddl = "O:SYD:(A;;FA;;;SY)(A;;FA;;;" ++ sid ++ ")", .writer = true },
        .{ .sddl = "O:SYD:(A;;FA;;;SY)(D;;0x30156;;;" ++ sid ++ ")(A;;0x1301ff;;;" ++ sid ++ ")", .writer = false },
        .{ .sddl = "O:SYD:(A;;FA;;;SY)(A;IO;FA;;;" ++ sid ++ ")", .writer = false },
        .{ .sddl = "O:SYD:(A;;FA;;;SY)(D;;0x2;;;" ++ sid ++ ")(A;;FA;;;" ++ sid ++ ")", .writer = true },
    };
    for (cases) |case| {
        const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, case.sddl);
        defer a.free(wide);
        var buffer: [4096]u8 = undefined;
        try std.testing.expectEqual(@as(u32, 0), da_workspace_writers_test_sddl(wide.ptr, &buffer, buffer.len));
        const value = std.mem.sliceTo(&buffer, 0);
        try std.testing.expectEqual(case.writer, std.mem.indexOf(u8, value, "SID sintético sin cuenta") != null);
        try std.testing.expect(std.mem.indexOf(u8, value, "S-1-") == null);
    }
    var tiny: [1]u8 = undefined;
    try std.testing.expectEqual(@as(u32, 122), da_workspace_writers_test_sddl(std.unicode.utf8ToUtf16LeStringLiteral("O:SYD:(A;;FA;;;SY)"), &tiny, tiny.len));
    try std.testing.expect(da_workspace_writers_test_sddl(std.unicode.utf8ToUtf16LeStringLiteral("invalid"), &tiny, tiny.len) != 0);
}

fn pathSddl(a: std.mem.Allocator, path: []const u8) ![]u8 {
    const wide = try std.unicode.utf8ToUtf16LeAllocZ(a, path);
    defer a.free(wide);
    var output: ?[*:0]u8 = null;
    try std.testing.expectEqual(@as(u32, 0), da_workspace_test_path_sddl(wide.ptr, &output));
    defer _ = LocalFree(output.?);
    return a.dupe(u8, std.mem.span(output.?));
}

extern "kernel32" fn CreateSymbolicLinkW([*:0]const u16, [*:0]const u16, u32) callconv(.winapi) u8;

/// false: este equipo no permite crear ese tipo de enlace (privilegio).
/// El symlink de directorio se pide con ALLOW_UNPRIVILEGED_CREATE (modo
/// desarrollador): si Windows lo rechaza, queda un SKIP visible, no «probado».
fn makeLink(a: std.mem.Allocator, kind: []const u8, link: []const u8, target: []const u8) !bool {
    if (std.mem.eql(u8, kind, "/D")) {
        const wide_link = try std.unicode.utf8ToUtf16LeAllocZ(a, link);
        defer a.free(wide_link);
        const wide_target = try std.unicode.utf8ToUtf16LeAllocZ(a, target);
        defer a.free(wide_target);
        // SYMBOLIC_LINK_FLAG_DIRECTORY | SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE
        if (CreateSymbolicLinkW(wide_link.ptr, wide_target.ptr, 0x1 | 0x2) == 0) {
            std.debug.print("SYMLINK_UNPRIVILEGED_CREATE_ERROR={d}\n", .{GetLastError()});
            return false;
        }
        return true;
    }
    var result = try @import("providers").github.runCmdCaptureWin32(a, &.{ "cmd.exe", "/d", "/c", "mklink", kind, link, target }, null);
    defer result.deinit(a);
    return result.exit_code == 0;
}

test "RELOJ SNAP restore never crosses a junction symlink or hard link out of the workspace" {
    if (!is_windows) return @import("platform.zig").skip("T9: DACL/SDDL y enlaces de Windows; el modo POSIX tiene su prueba T9");
    const a = std.testing.allocator;
    const io = std.testing.io;
    for ([_][]const u8{ "/J", "/D", "/H" }) |kind| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.createDirPath(io, "outside/dir");
        try tmp.dir.writeFile(io, .{ .sub_path = "outside/dir/inner.txt", .data = "inner" });
        try tmp.dir.writeFile(io, .{ .sub_path = "outside/file.txt", .data = "file" });
        try tmp.dir.createDir(io, "space", .default_dir);
        const base = try tmp.dir.realPathFileAlloc(io, ".", a);
        defer a.free(base);
        const space = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "space", .{base});
        defer a.free(space);
        try restorePrivate(a, space);
        var snapshot = try Snapshot.init(a, space);
        defer snapshot.deinit();
        const original = try snapshot.sddl(a);
        defer a.free(original);
        // Un escritor ajeno añade su ACE heredable ANTES de que exista el enlace.
        try snapshot.widenForTest(a);
        const link = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "link", .{space});
        defer a.free(link);
        const target = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "outside" ++ std.fs.path.sep_str ++ "{s}", .{ base, if (std.mem.eql(u8, kind, "/H")) "file.txt" else "dir" });
        defer a.free(target);
        if (!try makeLink(a, kind, link, target)) {
            std.debug.print("SKIP RELOJ SNAP links {s}: NO VERIFICADO, este equipo no permite crear ese enlace (ver error previo)\n", .{kind});
            continue;
        }
        defer {
            if (std.mem.eql(u8, kind, "/H")) {
                tmp.dir.deleteFile(io, "space/link") catch {};
            } else {
                tmp.dir.deleteDir(io, "space/link") catch {};
            }
        }
        const external = [_][]const u8{ "outside", "outside\\dir", "outside\\dir\\inner.txt", "outside\\file.txt" };
        var before = std.ArrayList([]u8).empty;
        defer {
            for (before.items) |value| a.free(value);
            before.deinit(a);
        }
        for (external) |relative| {
            const path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ base, relative });
            defer a.free(path);
            try before.append(a, try pathSddl(a, path));
        }
        // Con un enlace en el árbol solo se restaura la raíz y se avisa.
        try std.testing.expectError(error.WorkspaceTreeHasLinks, snapshot.restore());
        try std.testing.expectEqual(tree_links_code, snapshot.last_error);
        const restored = try snapshot.sddl(a);
        defer a.free(restored);
        try std.testing.expectEqualStrings(original, restored);
        // La reparación privada aplica la misma regla.
        try std.testing.expectError(error.WorkspaceTreeHasLinks, restorePrivate(a, space));
        for (external, 0..) |relative, i| {
            const path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ base, relative });
            defer a.free(path);
            const after = try pathSddl(a, path);
            defer a.free(after);
            try std.testing.expectEqualStrings(before.items[i], after);
        }
    }
}

test "RELOJ SNAP a failed tree scan still restores the root and returns the native code" {
    if (!is_windows) return @import("platform.zig").skip("T9: DACL/SDDL y enlaces de Windows; el modo POSIX tiene su prueba T9");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "space/locked");
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const space = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "space", .{base});
    defer a.free(space);
    const locked = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "locked", .{space});
    defer a.free(locked);
    try restorePrivate(a, space);
    var snapshot = try Snapshot.init(a, space);
    defer snapshot.deinit();
    const original = try snapshot.sddl(a);
    defer a.free(original);
    try snapshot.widenForTest(a);
    // Un subdirectorio que no se puede listar: el escaneo falla con ACCESS_DENIED.
    var deny = try @import("providers").github.runCmdCaptureWin32(a, &.{ "icacls.exe", locked, "/deny", "*S-1-1-0:(RD)" }, null);
    defer deny.deinit(a);
    try std.testing.expectEqual(@as(u32, 0), deny.exit_code);
    defer {
        if (@import("providers").github.runCmdCaptureWin32(a, &.{ "icacls.exe", locked, "/remove:d", "*S-1-1-0" }, null)) |value| {
            var done = value;
            done.deinit(a);
        } else |_| {}
    }
    // La raíz vuelve a su descriptor (sin propagar) y el fallo trae el código nativo.
    try std.testing.expectError(error.WorkspacePermissionsRestoreFailed, snapshot.restore());
    try std.testing.expectEqual(@as(u32, 5), snapshot.last_error);
    const restored = try snapshot.sddl(a);
    defer a.free(restored);
    try std.testing.expectEqualStrings(original, restored);
    // La reparación privada aplica lo mismo: raíz restaurada y código visible.
    try std.testing.expectError(error.WorkspacePermissionsRestoreFailed, restorePrivate(a, space));
    try std.testing.expectEqual(@as(u32, 5), lastError());
    const private = try snapshot.sddl(a);
    defer a.free(private);
    try std.testing.expectEqualStrings(original, private);
}

test "RELOJ SNAP capture needs only READ_CONTROL and a change reports the missing write right at restore time" {
    if (!is_windows) return @import("platform.zig").skip("T9: DACL/SDDL y enlaces de Windows; el modo POSIX tiene su prueba T9");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "space", .default_dir);
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const space = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "space", .{base});
    defer a.free(space);
    try restorePrivate(a, space);
    // Capturada cuando aún había derechos: su descriptor diferirá del vivo.
    var full = try Snapshot.init(a, space);
    defer full.deinit();
    const original = try full.sddl(a);
    defer a.free(original);
    // El propietario pierde WRITE_DAC y WRITE_OWNER (OWNER RIGHTS solo lee/borra).
    const dacl = std.mem.indexOf(u8, original, "D:") orelse return error.TestUnexpectedResult;
    const limited = try std.fmt.allocPrint(a, "{s}D:P(A;OICI;0x1300a9;;;OW)(A;OICI;FA;;;SY)", .{original[0..dacl]});
    defer a.free(limited);
    try full.setDescriptorForTest(a, limited);
    // Sin cambios, la captura y el restore con solo READ_CONTROL funcionan.
    var read_only = try Snapshot.init(a, space);
    defer read_only.deinit();
    try read_only.restore();
    try std.testing.expect(!read_only.rewritten());
    // Con cambios y sin derechos de escritura: error visible, en ese momento.
    try std.testing.expectError(error.WorkspacePermissionsRestoreFailed, full.restore());
    try std.testing.expect(full.last_error != 0);
    std.debug.print("RELOJ SNAP restore without write rights: win32={d}\n", .{full.last_error});
}

test "RELOJ SNAP restore leaves the tree alone when owner DACL and control already match" {
    if (!is_windows) return @import("platform.zig").skip("T9: DACL/SDDL y enlaces de Windows; el modo POSIX tiene su prueba T9");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "space", .default_dir);
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const space = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "space", .{base});
    defer a.free(space);
    try restorePrivate(a, space);
    var snapshot = try Snapshot.init(a, space);
    defer snapshot.deinit();
    try snapshot.restore();
    try std.testing.expect(!snapshot.rewritten());
    try snapshot.widenForTest(a);
    try snapshot.restore();
    try std.testing.expect(snapshot.rewritten());
    try snapshot.restore();
    try std.testing.expect(!snapshot.rewritten());
}

test "RELOJ SNAP governed gate runs on the retained handle and root identity is stable" {
    if (!is_windows) return @import("platform.zig").skip("T9: DACL/SDDL y enlaces de Windows; el modo POSIX tiene su prueba T9");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const base = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(base);
    const governed = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "devagents-workspace", .{base});
    defer a.free(governed);
    try @import("external_cli_policy.zig").createPrivateDirectory(a, governed);
    var snapshot = try Snapshot.init(a, governed);
    defer snapshot.deinit();
    try snapshot.checkGoverned(governed);
    const first = try snapshot.identity(a);
    defer a.free(first);
    var second = try identity(a, governed);
    defer second.deinit(a);
    try std.testing.expectEqualStrings(first, second.id);
    try std.testing.expect(std.ascii.eqlIgnoreCase(second.canonical, governed));
    // Contaminada tras la comprobación previa: la compuerta sobre el handle lo ve.
    try snapshot.widenForTest(a);
    try std.testing.expectError(error.CliWritableByOthers, snapshot.checkGoverned(governed));
    // Una carpeta de usuario cualquiera no pasa por la compuerta del espacio.
    try snapshot.checkGoverned("C:\\proyecto-de-usuario");
    // Otra carpeta tiene otra identidad.
    try tmp.dir.createDir(io, "otra", .default_dir);
    const otra = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "otra", .{base});
    defer a.free(otra);
    var distinct = try identity(a, otra);
    defer distinct.deinit(a);
    try std.testing.expect(!std.mem.eql(u8, distinct.id, first));
    try std.testing.expectError(error.WorkspacePermissionsInspectFailed, identity(a, "C:\\no-existe-reloj-identidad"));
}

const posix = struct {
    fn stat(fd: std.posix.fd_t) !@import("providers").posix_stat.Metadata {
        return @import("providers").posix_stat.get(fd, null);
    }
    fn identityText(a: std.mem.Allocator, fd: std.posix.fd_t) ![]u8 {
        const meta = stat(fd) catch return error.WorkspacePermissionsInspectFailed;
        return std.fmt.allocPrint(a, "{x:0>16}-{x:0>16}", .{ meta.dev, meta.ino });
    }
};

test "T9 POSIX workspace permissions: snapshot, widen, restore and identity" {
    if (is_windows) return @import("platform.zig").skip("T9: modo POSIX; la DACL de Windows la cubren las pruebas RELOJ SNAP");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "espacio");
    const path = try tmp.dir.realPathFileAlloc(io, "espacio", a);
    defer a.free(path);
    try restorePrivate(a, path);
    var snap = try Snapshot.init(a, path);
    defer snap.deinit();
    const before = try snap.sddl(a);
    defer a.free(before);
    try std.testing.expect(std.mem.endsWith(u8, before, "mode=0700"));
    try snap.widenForTest(a);
    const open_writers = try writers(a, path);
    defer a.free(open_writers);
    try std.testing.expect(std.mem.indexOf(u8, open_writers, "otros") != null);
    try snap.restore();
    try std.testing.expect(snap.rewritten());
    const after = try snap.sddl(a);
    defer a.free(after);
    try std.testing.expectEqualStrings(before, after);
    var id = try identity(a, path);
    defer id.deinit(a);
    const snap_id = try snap.identity(a);
    defer a.free(snap_id);
    try std.testing.expectEqualStrings(id.id, snap_id);
}
