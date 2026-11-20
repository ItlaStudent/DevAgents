const std = @import("std");
const windows = std.os.windows;
const db = @import("db.zig");

extern "kernel32" fn LoadLibraryA(lpLibFileName: [*:0]const u8) ?windows.HMODULE;
extern "kernel32" fn SetThreadErrorMode(dwNewMode: u32, lpOldMode: ?*u32) c_int;
extern "kernel32" fn GetThreadErrorMode() u32;

/// Sin diálogos del sistema al cargar: un archivo que no es una imagen PE válida
/// (plugin corrupto o un .txt) hacía que Windows mostrara «Imagen incorrecta»
/// (0xc000012f) y bloqueara el hilo hasta que alguien pulsara Aceptar.
/// `SetThreadErrorMode` afecta solo a este hilo y se restaura al salir.
const SEM_FAILCRITICALERRORS: u32 = 0x0001;
const SEM_NOOPENFILEERRORBOX: u32 = 0x8000;
fn loadLibraryNoDialog(path: [*:0]const u8) ?windows.HMODULE {
    // T9: en POSIX el plugin es una biblioteca compartida (dlopen, RTLD_NOW).
    if (@import("builtin").os.tag != .windows) return @ptrCast(std.c.dlopen(path, .{ .NOW = true }));
    var old_mode: u32 = 0;
    // Sin supresión garantizada no se carga: un archivo dañado abriría el
    // diálogo modal. Se devuelve null y el llamador lo trata como carga fallida.
    if (SetThreadErrorMode(GetThreadErrorMode() | SEM_FAILCRITICALERRORS | SEM_NOOPENFILEERRORBOX, &old_mode) == 0) return null;
    defer if (SetThreadErrorMode(old_mode, null) == 0) {
        // Restaurar no debería fallar; si falla, el hilo se queda con la
        // supresión puesta (sin diálogos), que es el lado seguro. Se registra.
        std.log.warn("plugin_loader: no se pudo restaurar el modo de error del hilo", .{});
    };
    return LoadLibraryA(path);
}
fn FreeLibrary(h: windows.HMODULE) windows.BOOL {
    if (@import("builtin").os.tag != .windows) return if (std.c.dlclose(@ptrCast(h)) == 0) .TRUE else .FALSE;
    return struct {
        extern "kernel32" fn FreeLibrary(hLibModule: windows.HMODULE) windows.BOOL;
    }.FreeLibrary(h);
}
fn GetProcAddress(h: windows.HMODULE, name: [*:0]const u8) ?windows.FARPROC {
    if (@import("builtin").os.tag != .windows) return @ptrCast(std.c.dlsym(@ptrCast(h), name));
    return struct {
        extern "kernel32" fn GetProcAddress(hModule: windows.HMODULE, lpProcName: [*:0]const u8) ?windows.FARPROC;
    }.GetProcAddress(h, name);
}
const CreateFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateFileA(lpFileName: [*:0]const u8, dwDesiredAccess: u32, dwShareMode: u32, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: u32, dwFlagsAndAttributes: u32, hTemplateFile: ?windows.HANDLE) windows.HANDLE;
}.CreateFileA else @import("providers").posix_files.CreateFileA;
const ReadFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn ReadFile(hFile: windows.HANDLE, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque) c_int;
}.ReadFile else @import("providers").posix_files.ReadFile;
const WriteFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn WriteFile(hFile: windows.HANDLE, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque) c_int;
}.WriteFile else @import("providers").posix_files.WriteFile;
const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) c_int;
}.CloseHandle else @import("providers").posix_files.CloseHandle;
const GetFileSize = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileSize(hFile: windows.HANDLE, lpFileSizeHigh: ?*u32) u32;
}.GetFileSize else @import("providers").posix_files.GetFileSize;
const DeleteFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn DeleteFileA(lpFileName: [*:0]const u8) c_int;
}.DeleteFileA else @import("providers").posix_files.DeleteFileA;

pub const PluginError = error{
    OutOfMemory,
    ManifestNotFound,
    ManifestInvalid,
    DllNotFound,
    SymbolNotFound,
    AbiVersionMismatch,
    LoadFailed,
    /// DLL loading is disabled by default; caller must explicitly trust the plugin.
    PluginLoadDisabled,
    /// Manifest declares no capabilities — suspicious / useless.
    EmptyCapabilities,
    /// DLL SHA-256 does not match the expected hash (or no hash provided).
    PluginUntrusted,
    /// DLL file could not be read for hashing.
    DllReadFailed,
    /// Expected hash string is not valid hex / wrong length.
    InvalidHashFormat,
};

pub const CapabilityKind = enum(u32) {
    provider = 1,
    tool = 2,
    skill = 3,
    mcp = 4,
};

pub const Capability = struct {
    kind: CapabilityKind,
    name: []const u8,
    description: []const u8,
};

pub const PluginManifest = struct {
    name: []const u8,
    version: []const u8,
    abi_version: u32,
    dll_name: []const u8,
    capabilities: []Capability,

    pub fn deinit(self: *const PluginManifest, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.version);
        allocator.free(self.dll_name);
        for (self.capabilities) |c| {
            allocator.free(c.name);
            allocator.free(c.description);
        }
        if (self.capabilities.len > 0) {
            allocator.free(self.capabilities);
        }
    }
};

pub const LoadedPlugin = struct {
    allocator: std.mem.Allocator,
    handle: ?windows.HMODULE,
    manifest: PluginManifest,

    pub fn deinit(self: *LoadedPlugin) void {
        if (self.handle) |h| {
            _ = FreeLibrary(h);
            self.handle = null;
        }
        self.manifest.deinit(self.allocator);
    }

    pub fn symbol(self: *const LoadedPlugin, name: [:0]const u8) ?windows.FARPROC {
        const h = self.handle orelse return null;
        return GetProcAddress(h, name);
    }
};

pub const EXPECTED_ABI_VERSION: u32 = 1;

pub const PluginLoader = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PluginLoader {
        return .{ .allocator = allocator };
    }

    pub fn parseManifest(self: *const PluginLoader, json_text: []const u8) PluginError!PluginManifest {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_text, .{}) catch {
            return error.ManifestInvalid;
        };
        defer parsed.deinit();

        if (parsed.value != .object) return error.ManifestInvalid;
        const obj = parsed.value.object;

        const name = if (obj.get("name")) |v| blk: {
            if (v == .string) break :blk v.string;
            return error.ManifestInvalid;
        } else return error.ManifestInvalid;

        const version = if (obj.get("version")) |v| blk: {
            if (v == .string) break :blk v.string;
            return error.ManifestInvalid;
        } else return error.ManifestInvalid;

        const abi_version: u32 = if (obj.get("abi_version")) |v| blk: {
            if (v == .integer) break :blk @intCast(v.integer);
            return error.ManifestInvalid;
        } else return error.ManifestInvalid;

        const dll_name = if (obj.get("dll")) |v| blk: {
            if (v == .string) break :blk v.string;
            return error.ManifestInvalid;
        } else return error.ManifestInvalid;

        var capabilities: std.ArrayList(Capability) = .empty;
        if (obj.get("capabilities")) |caps_v| {
            if (caps_v == .array) {
                for (caps_v.array.items) |cap| {
                    if (cap != .object) continue;
                    const co = cap.object;
                    const kind_str = if (co.get("kind")) |kv| blk: {
                        if (kv == .string) break :blk kv.string;
                        continue;
                    } else continue;
                    const cap_name = if (co.get("name")) |cv| blk: {
                        if (cv == .string) break :blk cv.string;
                        continue;
                    } else continue;
                    const description = if (co.get("description")) |dv| blk: {
                        if (dv == .string) break :blk dv.string;
                        continue;
                    } else continue;

                    const kind = if (std.mem.eql(u8, kind_str, "provider"))
                        CapabilityKind.provider
                    else if (std.mem.eql(u8, kind_str, "tool"))
                        CapabilityKind.tool
                    else if (std.mem.eql(u8, kind_str, "skill"))
                        CapabilityKind.skill
                    else if (std.mem.eql(u8, kind_str, "mcp"))
                        CapabilityKind.mcp
                    else
                        continue;

                    try capabilities.append(self.allocator, .{
                        .kind = kind,
                        .name = try self.allocator.dupe(u8, cap_name),
                        .description = try self.allocator.dupe(u8, description),
                    });
                }
            }
        }

        return .{
            .name = try self.allocator.dupe(u8, name),
            .version = try self.allocator.dupe(u8, version),
            .abi_version = abi_version,
            .dll_name = try self.allocator.dupe(u8, dll_name),
            .capabilities = try capabilities.toOwnedSlice(self.allocator),
        };
    }

    /// Load a plugin DLL. By default (trusted=false) this refuses to load
    /// any DLL — the caller MUST explicitly opt in with loadTrusted().
    /// This prevents silent arbitrary code execution from untrusted manifests.
    pub fn load(_: *const PluginLoader, _: []const u8, _: []const u8) PluginError!LoadedPlugin {
        return error.PluginLoadDisabled;
    }

    /// Load a plugin DLL with explicit trust. The caller must provide the
    /// expected SHA-256 hash of the DLL file. The hash is verified BEFORE
    /// `LoadLibraryA` — if it doesn't match (or is null), the DLL is NOT loaded
    /// and `error.PluginUntrusted` is returned (default-deny).
    /// Validates: SHA-256 hash, ABI version, non-empty capabilities, required export symbols.
    pub fn loadTrusted(self: *const PluginLoader, dll_path: []const u8, manifest_json: []const u8, expected_sha256: ?[]const u8) PluginError!LoadedPlugin {
        const manifest = try self.parseManifest(manifest_json);

        if (manifest.abi_version != EXPECTED_ABI_VERSION) {
            manifest.deinit(self.allocator);
            return error.AbiVersionMismatch;
        }

        if (manifest.capabilities.len == 0) {
            manifest.deinit(self.allocator);
            return error.EmptyCapabilities;
        }

        // T2: Verify SHA-256 of the DLL BEFORE LoadLibraryA (default-deny).
        const expected = expected_sha256 orelse {
            manifest.deinit(self.allocator);
            return error.PluginUntrusted;
        };
        const file_hash = self.computeFileSha256(dll_path) catch |e| {
            manifest.deinit(self.allocator);
            return switch (e) {
                error.DllNotFound => error.DllNotFound,
                error.DllReadFailed => error.DllReadFailed,
                else => error.DllReadFailed,
            };
        };
        if (!constantTimeEqlHex(&file_hash, expected)) {
            manifest.deinit(self.allocator);
            return error.PluginUntrusted;
        }

        const dll_path_z = self.allocator.dupeZ(u8, dll_path) catch {
            manifest.deinit(self.allocator);
            return error.OutOfMemory;
        };
        defer self.allocator.free(dll_path_z);

        const handle = loadLibraryNoDialog(dll_path_z.ptr);
        if (handle == null) {
            manifest.deinit(self.allocator);
            return error.DllNotFound;
        }
        const h = handle.?;

        const info_fn = GetProcAddress(h, "da_plugin_get_info");
        if (info_fn == null) {
            _ = FreeLibrary(h);
            manifest.deinit(self.allocator);
            return error.SymbolNotFound;
        }

        const version_fn = GetProcAddress(h, "da_version_string");
        if (version_fn == null) {
            _ = FreeLibrary(h);
            manifest.deinit(self.allocator);
            return error.SymbolNotFound;
        }

        return .{
            .allocator = self.allocator,
            .handle = h,
            .manifest = manifest,
        };
    }

    /// P01-T1: Carga un plugin verificando el hash contra el pin en catalog.db
    /// (tabla plugin_trust). Fail-closed: si no hay pin para el nombre del plugin,
    /// o si el hash no coincide, rechaza con PluginUntrusted. El hash esperado
    /// NO se deriva del propio DLL — viene del catálogo pinneado en instalación.
    pub fn loadTrustedFromCatalog(
        self: *const PluginLoader,
        dll_path: []const u8,
        manifest_json: []const u8,
        catalog: db.Connection,
    ) PluginError!LoadedPlugin {
        const manifest = try self.parseManifest(manifest_json);

        if (manifest.abi_version != EXPECTED_ABI_VERSION) {
            manifest.deinit(self.allocator);
            return error.AbiVersionMismatch;
        }

        if (manifest.capabilities.len == 0) {
            manifest.deinit(self.allocator);
            return error.EmptyCapabilities;
        }

        // Lookup pinned hash from catalog.db plugin_trust table.
        const pinned = self.lookupPinnedHash(catalog, manifest.name) catch {
            manifest.deinit(self.allocator);
            return error.PluginUntrusted;
        };
        if (pinned == null) {
            manifest.deinit(self.allocator);
            return error.PluginUntrusted;
        }
        defer std.heap.page_allocator.free(pinned.?);

        const file_hash = self.computeFileSha256(dll_path) catch |e| {
            manifest.deinit(self.allocator);
            return switch (e) {
                error.DllNotFound => error.DllNotFound,
                error.DllReadFailed => error.DllReadFailed,
                else => error.DllReadFailed,
            };
        };
        if (!constantTimeEqlHex(&file_hash, pinned.?)) {
            manifest.deinit(self.allocator);
            return error.PluginUntrusted;
        }

        const dll_path_z = self.allocator.dupeZ(u8, dll_path) catch {
            manifest.deinit(self.allocator);
            return error.OutOfMemory;
        };
        defer self.allocator.free(dll_path_z);

        const handle = loadLibraryNoDialog(dll_path_z.ptr);
        if (handle == null) {
            manifest.deinit(self.allocator);
            return error.DllNotFound;
        }
        const h = handle.?;

        const info_fn = GetProcAddress(h, "da_plugin_get_info");
        if (info_fn == null) {
            _ = FreeLibrary(h);
            manifest.deinit(self.allocator);
            return error.SymbolNotFound;
        }

        const version_fn = GetProcAddress(h, "da_version_string");
        if (version_fn == null) {
            _ = FreeLibrary(h);
            manifest.deinit(self.allocator);
            return error.SymbolNotFound;
        }

        return .{
            .allocator = self.allocator,
            .handle = h,
            .manifest = manifest,
        };
    }

    /// P01-T1: Pinnea el hash SHA-256 de un plugin en catalog.db (tabla plugin_trust).
    /// Se llama al instalar/registrar un plugin. Usa INSERT OR REPLACE para que
    /// re-pinnear (actualizar) un plugin sea seguro.
    pub fn pinPluginHash(
        self: *const PluginLoader,
        catalog: db.Connection,
        plugin_name: []const u8,
        dll_path: []const u8,
    ) PluginError!void {
        const file_hash = self.computeFileSha256(dll_path) catch |e| {
            return switch (e) {
                error.DllNotFound => error.DllNotFound,
                error.DllReadFailed => error.DllReadFailed,
                else => error.DllReadFailed,
            };
        };

        const stmt = catalog.prepare(
            "INSERT OR REPLACE INTO plugin_trust (name, sha256, pinned_at) VALUES (?, ?, ?)",
        ) catch return error.PluginUntrusted;
        defer catalog.finalize(stmt);
        db.bindText(stmt, 1, plugin_name) catch return error.PluginUntrusted;
        db.bindText(stmt, 2, &file_hash) catch return error.PluginUntrusted;
        // Zig 0.16 no expone std.time.timestamp — usar SQLite.
        const ts_stmt = catalog.prepare("SELECT CAST(strftime('%s','now') AS INTEGER)") catch return error.PluginUntrusted;
        defer catalog.finalize(ts_stmt);
        if (db.c.sqlite3_step(ts_stmt) != db.c.SQLITE_ROW) return error.PluginUntrusted;
        const ts = db.c.sqlite3_column_int64(ts_stmt, 0);
        db.bindInt(stmt, 3, ts) catch return error.PluginUntrusted;
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.PluginUntrusted;
    }

    fn lookupPinnedHash(self: *const PluginLoader, catalog: db.Connection, plugin_name: []const u8) !?[]const u8 {
        _ = self;
        const stmt = catalog.prepare("SELECT sha256 FROM plugin_trust WHERE name=?") catch return error.PluginUntrusted;
        defer catalog.finalize(stmt);
        db.bindText(stmt, 1, plugin_name) catch return error.PluginUntrusted;
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return null;
        const hash_ptr = db.c.sqlite3_column_text(stmt, 0) orelse return null;
        const hash_slice = hash_ptr[0..std.mem.len(hash_ptr)];
        // Dupe: SQLite's internal buffer is freed on finalize, so we must copy.
        const owned = std.heap.page_allocator.dupe(u8, hash_slice) catch return error.PluginUntrusted;
        return owned;
    }
    /// Uses Win32 API directly (fork-safe, no Io dependency).
    pub fn computeFileSha256(self: *const PluginLoader, dll_path: []const u8) PluginError![64]u8 {
        const GENERIC_READ: u32 = 0x80000000;
        const FILE_SHARE_READ: u32 = 0x00000001;
        const OPEN_EXISTING: u32 = 3;
        const INVALID_HANDLE_VALUE: windows.HANDLE = @ptrFromInt(~@as(usize, 0));

        const path_z = self.allocator.dupeZ(u8, dll_path) catch return error.OutOfMemory;
        defer self.allocator.free(path_z);

        const h = CreateFileA(path_z.ptr, GENERIC_READ, FILE_SHARE_READ, null, OPEN_EXISTING, 0, null);
        if (h == INVALID_HANDLE_VALUE) return error.DllNotFound;
        defer _ = CloseHandle(h);

        const size = GetFileSize(h, null);
        if (size == 0xFFFFFFFF) return error.DllReadFailed;

        const buf = self.allocator.alloc(u8, size) catch return error.OutOfMemory;
        defer self.allocator.free(buf);

        var read_bytes: u32 = 0;
        if (ReadFile(h, buf.ptr, size, &read_bytes, null) == 0 or read_bytes != size) return error.DllReadFailed;

        var sha = std.crypto.hash.sha2.Sha256.init(.{});
        sha.update(buf);
        var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
        sha.final(&digest);
        return std.fmt.bytesToHex(digest, .lower);
    }
};

/// Constant-time comparison of a [64]u8 hex digest with a []const u8 expected hash.
/// Returns false if lengths differ. Prevents timing attacks on hash comparison.
fn constantTimeEqlHex(actual: *const [64]u8, expected: []const u8) bool {
    if (expected.len != 64) return false;
    var result: u8 = 0;
    for (actual, expected) |a, b| {
        result |= a ^ b;
    }
    return result == 0;
}

test "parse valid manifest" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "example-provider",
        \\  "version": "1.0.0",
        \\  "abi_version": 1,
        \\  "dll": "example_provider.dll",
        \\  "capabilities": [
        \\    {"kind": "provider", "name": "ExampleProv", "description": "Example LLM provider"}
        \\  ]
        \\}
    ;
    var loader = PluginLoader.init(allocator);
    const manifest = try loader.parseManifest(json);
    defer manifest.deinit(allocator);

    try std.testing.expectEqualStrings("example-provider", manifest.name);
    try std.testing.expectEqualStrings("1.0.0", manifest.version);
    try std.testing.expectEqual(@as(u32, 1), manifest.abi_version);
    try std.testing.expectEqual(@as(usize, 1), manifest.capabilities.len);
    try std.testing.expectEqual(CapabilityKind.provider, manifest.capabilities[0].kind);
    try std.testing.expectEqualStrings("ExampleProv", manifest.capabilities[0].name);
}

test "parse invalid manifest returns error" {
    const allocator = std.testing.allocator;
    var loader = PluginLoader.init(allocator);
    try std.testing.expectError(error.ManifestInvalid, loader.parseManifest("not json"));
    try std.testing.expectError(error.ManifestInvalid, loader.parseManifest("{}"));
}

test "abi version mismatch" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "test",
        \\  "version": "1.0.0",
        \\  "abi_version": 999,
        \\  "dll": "test.dll",
        \\  "capabilities": []
        \\}
    ;
    var loader = PluginLoader.init(allocator);
    // load() is disabled by default; loadTrusted() checks ABI first.
    const result = loader.loadTrusted("nonexistent.dll", json, null);
    // Should fail on abi_version mismatch before trying to load the DLL
    try std.testing.expectError(error.AbiVersionMismatch, result);
}

test "load disabled by default" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "test",
        \\  "version": "1.0.0",
        \\  "abi_version": 1,
        \\  "dll": "test.dll",
        \\  "capabilities": [
        \\    {"kind": "provider", "name": "TestProv", "description": "Test"}
        \\  ]
        \\}
    ;
    var loader = PluginLoader.init(allocator);
    // load() must refuse — only loadTrusted() may load DLLs.
    try std.testing.expectError(error.PluginLoadDisabled, loader.load("nonexistent.dll", json));
}

test "loadTrusted rejects empty capabilities" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "empty",
        \\  "version": "1.0.0",
        \\  "abi_version": 1,
        \\  "dll": "empty.dll",
        \\  "capabilities": []
        \\}
    ;
    var loader = PluginLoader.init(allocator);
    try std.testing.expectError(error.EmptyCapabilities, loader.loadTrusted("nonexistent.dll", json, null));
}

test "missing required fields returns error" {
    const allocator = std.testing.allocator;
    var loader = PluginLoader.init(allocator);
    try std.testing.expectError(error.ManifestInvalid, loader.parseManifest(
        \\{"name": "test"}
    ));
}

test "manifest parses all capability kinds" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "multi-cap",
        \\  "version": "1.0.0",
        \\  "abi_version": 1,
        \\  "dll": "multi.dll",
        \\  "capabilities": [
        \\    {"kind": "provider", "name": "Prov1", "description": "prov desc"},
        \\    {"kind": "tool", "name": "Tool1", "description": "tool desc"},
        \\    {"kind": "skill", "name": "Skill1", "description": "skill desc"},
        \\    {"kind": "mcp", "name": "Mcp1", "description": "mcp desc"}
        \\  ]
        \\}
    ;
    var loader = PluginLoader.init(allocator);
    const manifest = try loader.parseManifest(json);
    defer manifest.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 4), manifest.capabilities.len);
    try std.testing.expectEqual(CapabilityKind.provider, manifest.capabilities[0].kind);
    try std.testing.expectEqual(CapabilityKind.tool, manifest.capabilities[1].kind);
    try std.testing.expectEqual(CapabilityKind.skill, manifest.capabilities[2].kind);
    try std.testing.expectEqual(CapabilityKind.mcp, manifest.capabilities[3].kind);
}

test "T2: constantTimeEqlHex matches identical hashes" {
    const hash: [64]u8 = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789".*;
    try std.testing.expect(constantTimeEqlHex(&hash, "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789"));
}

test "T2: constantTimeEqlHex rejects different hashes" {
    const hash: [64]u8 = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789".*;
    try std.testing.expect(!constantTimeEqlHex(&hash, "1111111123456789abcdef0123456789abcdef0123456789abcdef0123456789"));
}

test "T2: constantTimeEqlHex rejects wrong length" {
    const hash: [64]u8 = "abcdef0123456789abcdef0123456789abcdef0123456789abcdef0123456789".*;
    try std.testing.expect(!constantTimeEqlHex(&hash, "short"));
}

test "T2: loadTrusted with null hash returns PluginUntrusted" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "test",
        \\  "version": "1.0.0",
        \\  "abi_version": 1,
        \\  "dll": "test.dll",
        \\  "capabilities": [
        \\    {"kind": "provider", "name": "TestProv", "description": "Test"}
        \\  ]
        \\}
    ;
    var loader = PluginLoader.init(allocator);
    // Null hash → default-deny, DLL is NOT loaded.
    try std.testing.expectError(error.PluginUntrusted, loader.loadTrusted("nonexistent.dll", json, null));
}

test "T2: loadTrusted with wrong hash returns PluginUntrusted" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "test",
        \\  "version": "1.0.0",
        \\  "abi_version": 1,
        \\  "dll": "test.dll",
        \\  "capabilities": [
        \\    {"kind": "provider", "name": "TestProv", "description": "Test"}
        \\  ]
        \\}
    ;
    var loader = PluginLoader.init(allocator);

    // Create a temp file via Win32 to test hash mismatch path.
    const tmp_name = "test_t2_wrong_hash.txt";
    const tmp_content = "not a dll, just test content for hashing";
    const GENERIC_WRITE: u32 = 0x40000000;
    const CREATE_ALWAYS: u32 = 2;
    const INVALID_HANDLE_VALUE: windows.HANDLE = @ptrFromInt(~@as(usize, 0));
    {
        const h = CreateFileA(tmp_name, GENERIC_WRITE, 0, null, CREATE_ALWAYS, 0, null);
        if (h == INVALID_HANDLE_VALUE) return;
        defer _ = CloseHandle(h);
        var written: u32 = 0;
        _ = WriteFile(h, tmp_content.ptr, @intCast(tmp_content.len), &written, null);
    }
    defer _ = DeleteFileA(tmp_name);

    // Use a deliberately wrong hash (all 'a's).
    const wrong_hash = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";

    // loadTrusted with wrong hash → PluginUntrusted (file exists, hash doesn't match).
    try std.testing.expectError(error.PluginUntrusted, loader.loadTrusted(tmp_name, json, wrong_hash));
}

test "T2: loadTrusted with correct hash proceeds past hash check" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "test",
        \\  "version": "1.0.0",
        \\  "abi_version": 1,
        \\  "dll": "test.dll",
        \\  "capabilities": [
        \\    {"kind": "provider", "name": "TestProv", "description": "Test"}
        \\  ]
        \\}
    ;
    var loader = PluginLoader.init(allocator);

    // Create a temp file via Win32.
    const tmp_name = "test_t2_correct_hash.txt";
    const tmp_content = "not a dll, just test content for correct hash test";
    const GENERIC_WRITE: u32 = 0x40000000;
    const CREATE_ALWAYS: u32 = 2;
    const INVALID_HANDLE_VALUE: windows.HANDLE = @ptrFromInt(~@as(usize, 0));
    {
        const h = CreateFileA(tmp_name, GENERIC_WRITE, 0, null, CREATE_ALWAYS, 0, null);
        if (h == INVALID_HANDLE_VALUE) return;
        defer _ = CloseHandle(h);
        var written: u32 = 0;
        _ = WriteFile(h, tmp_content.ptr, @intCast(tmp_content.len), &written, null);
    }
    defer _ = DeleteFileA(tmp_name);

    // Compute the real hash.
    const real_hash = loader.computeFileSha256(tmp_name) catch return;

    // loadTrusted with correct hash → passes hash check, then fails on LoadLibraryA
    // (since the file is not a real DLL) → DllNotFound or LoadFailed.
    const result = loader.loadTrusted(tmp_name, json, &real_hash) catch |e| {
        // Expected: LoadLibraryA fails because the file is not a valid DLL.
        try std.testing.expect(e == error.DllNotFound or e == error.LoadFailed);
        return;
    };
    // If it somehow succeeded, clean up.
    var plugin = result;
    plugin.deinit();
    try std.testing.expect(false); // Should not reach here — file is not a DLL.
}

test "plugin_loader: cargar un archivo que no es PE no deja el modo de error del hilo cambiado" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const before = GetThreadErrorMode();
    const tmp_name = "test_no_dialog_not_pe.txt";
    const GENERIC_WRITE: u32 = 0x40000000;
    const CREATE_ALWAYS: u32 = 2;
    const INVALID_HANDLE_VALUE: windows.HANDLE = @ptrFromInt(~@as(usize, 0));
    {
        const h = CreateFileA(tmp_name, GENERIC_WRITE, 0, null, CREATE_ALWAYS, 0, null);
        try std.testing.expect(h != INVALID_HANDLE_VALUE);
        defer _ = CloseHandle(h);
        const content = "not a dll";
        var written: u32 = 0;
        _ = WriteFile(h, content.ptr, content.len, &written, null);
    }
    defer _ = DeleteFileA(tmp_name);
    // Sin la supresión, Windows abriría el diálogo modal «Imagen incorrecta».
    try std.testing.expect(loadLibraryNoDialog(tmp_name) == null);
    try std.testing.expectEqual(before, GetThreadErrorMode());
}

test "plugin_loader: una DLL valida carga igual con la supresion y restaura el modo" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const before = GetThreadErrorMode();
    const h = loadLibraryNoDialog("kernel32.dll");
    try std.testing.expect(h != null);
    _ = FreeLibrary(h.?);
    try std.testing.expectEqual(before, GetThreadErrorMode());
}

test "P01-T1: loadTrustedFromCatalog rejects when no pin exists (fail-closed)" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "test-plugin",
        \\  "version": "1.0.0",
        \\  "abi_version": 1,
        \\  "dll": "test.dll",
        \\  "capabilities": [
        \\    {"kind": "provider", "name": "TestProv", "description": "Test"}
        \\  ]
        \\}
    ;
    var loader = PluginLoader.init(allocator);
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.catalog_schema);

    // No pin in plugin_trust → fail-closed.
    try std.testing.expectError(error.PluginUntrusted, loader.loadTrustedFromCatalog("nonexistent.dll", json, conn));
}

test "P01-T1: loadTrustedFromCatalog rejects when pin does not match (DLL altered)" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "test-plugin",
        \\  "version": "1.0.0",
        \\  "abi_version": 1,
        \\  "dll": "test.dll",
        \\  "capabilities": [
        \\    {"kind": "provider", "name": "TestProv", "description": "Test"}
        \\  ]
        \\}
    ;
    var loader = PluginLoader.init(allocator);
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.catalog_schema);

    // Insert a wrong pin.
    const wrong_hash = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const ins = try conn.prepare("INSERT INTO plugin_trust (name, sha256, pinned_at) VALUES ('test-plugin', ?, 0)");
    defer conn.finalize(ins);
    try db.bindText(ins, 1, wrong_hash);
    if (db.c.sqlite3_step(ins) != db.c.SQLITE_DONE) return error.ExecFailed;

    // Create a temp file to hash (so computeFileSha256 succeeds, but hash won't match).
    const tmp_name = "test_p01_t1_altered.txt";
    const tmp_content = "altered content";
    const GENERIC_WRITE: u32 = 0x40000000;
    const CREATE_ALWAYS: u32 = 2;
    const INVALID_HANDLE_VALUE: windows.HANDLE = @ptrFromInt(~@as(usize, 0));
    {
        const h = CreateFileA(tmp_name, GENERIC_WRITE, 0, null, CREATE_ALWAYS, 0, null);
        if (h == INVALID_HANDLE_VALUE) return;
        defer _ = CloseHandle(h);
        var written: u32 = 0;
        _ = WriteFile(h, tmp_content.ptr, @intCast(tmp_content.len), &written, null);
    }
    defer _ = DeleteFileA(tmp_name);

    try std.testing.expectError(error.PluginUntrusted, loader.loadTrustedFromCatalog(tmp_name, json, conn));
}

test "P01-T1: loadTrustedFromCatalog passes hash check with correct pin" {
    const allocator = std.testing.allocator;
    const json =
        \\{
        \\  "name": "test-plugin",
        \\  "version": "1.0.0",
        \\  "abi_version": 1,
        \\  "dll": "test.dll",
        \\  "capabilities": [
        \\    {"kind": "provider", "name": "TestProv", "description": "Test"}
        \\  ]
        \\}
    ;
    var loader = PluginLoader.init(allocator);
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.catalog_schema);

    // Create a temp file and compute its real hash.
    const tmp_name = "test_p01_t1_correct.txt";
    const tmp_content = "correct content for pin test";
    const GENERIC_WRITE: u32 = 0x40000000;
    const CREATE_ALWAYS: u32 = 2;
    const INVALID_HANDLE_VALUE: windows.HANDLE = @ptrFromInt(~@as(usize, 0));
    {
        const h = CreateFileA(tmp_name, GENERIC_WRITE, 0, null, CREATE_ALWAYS, 0, null);
        if (h == INVALID_HANDLE_VALUE) return;
        defer _ = CloseHandle(h);
        var written: u32 = 0;
        _ = WriteFile(h, tmp_content.ptr, @intCast(tmp_content.len), &written, null);
    }
    defer _ = DeleteFileA(tmp_name);

    const real_hash = loader.computeFileSha256(tmp_name) catch return;

    // Pin the correct hash.
    const ins = try conn.prepare("INSERT INTO plugin_trust (name, sha256, pinned_at) VALUES ('test-plugin', ?, 0)");
    defer conn.finalize(ins);
    try db.bindText(ins, 1, &real_hash);
    if (db.c.sqlite3_step(ins) != db.c.SQLITE_DONE) return error.ExecFailed;

    // loadTrustedFromCatalog with correct pin → passes hash, fails on LoadLibraryA (not a DLL).
    const result = loader.loadTrustedFromCatalog(tmp_name, json, conn) catch |e| {
        try std.testing.expect(e == error.DllNotFound or e == error.LoadFailed);
        return;
    };
    var plugin = result;
    plugin.deinit();
    try std.testing.expect(false);
}

test "P01-T1: pinPluginHash inserts row in plugin_trust" {
    const allocator = std.testing.allocator;
    var loader = PluginLoader.init(allocator);
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.catalog_schema);

    // Create a temp file to pin.
    const tmp_name = "test_p01_t1_pin.txt";
    const tmp_content = "content to pin";
    const GENERIC_WRITE: u32 = 0x40000000;
    const CREATE_ALWAYS: u32 = 2;
    const INVALID_HANDLE_VALUE: windows.HANDLE = @ptrFromInt(~@as(usize, 0));
    {
        const h = CreateFileA(tmp_name, GENERIC_WRITE, 0, null, CREATE_ALWAYS, 0, null);
        if (h == INVALID_HANDLE_VALUE) return;
        defer _ = CloseHandle(h);
        var written: u32 = 0;
        _ = WriteFile(h, tmp_content.ptr, @intCast(tmp_content.len), &written, null);
    }
    defer _ = DeleteFileA(tmp_name);

    try loader.pinPluginHash(conn, "my-plugin", tmp_name);

    // Verify the pin exists.
    const stmt = try conn.prepare("SELECT sha256 FROM plugin_trust WHERE name='my-plugin'");
    defer conn.finalize(stmt);
    try std.testing.expect(db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW);
    const hash_ptr = db.c.sqlite3_column_text(stmt, 0);
    try std.testing.expect(hash_ptr != null);
}
