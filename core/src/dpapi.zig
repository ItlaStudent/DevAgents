const std = @import("std");
const windows = std.os.windows;

/// DATA_BLOB para DPAPI.
pub const DATA_BLOB = extern struct {
    cbData: windows.DWORD,
    pbData: ?[*]windows.BYTE,
};

/// Flags para CryptProtectData.
pub const CRYPTPROTECT_UI_FORBIDDEN: windows.DWORD = 0x1;
pub const CRYPTPROTECT_LOCAL_MACHINE: windows.DWORD = 0x4;

pub extern "crypt32" fn CryptProtectData(
    pDataIn: *const DATA_BLOB,
    szDataDescr: ?windows.LPCWSTR,
    pOptionalEntropy: ?*const DATA_BLOB,
    pvReserved: ?*anyopaque,
    pPromptStruct: ?*anyopaque,
    dwFlags: windows.DWORD,
    pDataOut: *DATA_BLOB,
) callconv(.winapi) windows.BOOL;

pub extern "crypt32" fn CryptUnprotectData(
    pDataIn: *const DATA_BLOB,
    ppszDataDescr: ?*windows.LPWSTR,
    pOptionalEntropy: ?*const DATA_BLOB,
    pvReserved: ?*anyopaque,
    pPromptStruct: ?*anyopaque,
    dwFlags: windows.DWORD,
    pDataOut: *DATA_BLOB,
) callconv(.winapi) windows.BOOL;

pub extern "kernel32" fn LocalFree(hMem: ?*anyopaque) callconv(.winapi) ?*anyopaque;

pub const DpapiError = error{
    EncryptFailed,
    DecryptFailed,
    OutOfMemory,
};

/// Cifra datos con DPAPI (ámbito de usuario).
pub fn encrypt(allocator: std.mem.Allocator, plaintext: []const u8) DpapiError![]const u8 {
    if (@import("builtin").os.tag != .windows) {
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(plaintext, &hash, .{});
        const label = std.fmt.bytesToHex(hash, .lower);
        return @import("posix_keys.zig").store(allocator, "_secrets", &label, plaintext) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.EncryptFailed;
    }
    var input: DATA_BLOB = .{
        .cbData = @intCast(plaintext.len),
        .pbData = @ptrCast(@constCast(plaintext.ptr)),
    };
    var output: DATA_BLOB = .{ .cbData = 0, .pbData = null };
    const result = CryptProtectData(&input, null, null, null, null, CRYPTPROTECT_UI_FORBIDDEN, &output);
    if (result == .FALSE) return error.EncryptFailed;
    defer _ = LocalFree(output.pbData);
    const ciphertext = try allocator.alloc(u8, output.cbData);
    @memcpy(ciphertext, output.pbData.?[0..output.cbData]);
    return ciphertext;
}

/// Descifra datos con DPAPI.
pub fn decrypt(allocator: std.mem.Allocator, ciphertext: []const u8) DpapiError![]const u8 {
    if (@import("builtin").os.tag != .windows) {
        return @import("posix_keys.zig").resolve(allocator, ciphertext) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.DecryptFailed;
    }
    var input: DATA_BLOB = .{
        .cbData = @intCast(ciphertext.len),
        .pbData = @ptrCast(@constCast(ciphertext.ptr)),
    };
    var output: DATA_BLOB = .{ .cbData = 0, .pbData = null };
    const result = CryptUnprotectData(&input, null, null, null, null, CRYPTPROTECT_UI_FORBIDDEN, &output);
    if (result == .FALSE) return error.DecryptFailed;
    defer _ = LocalFree(output.pbData);
    const plaintext = try allocator.alloc(u8, output.cbData);
    @memcpy(plaintext, output.pbData.?[0..output.cbData]);
    return plaintext;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "dpapi encrypt decrypt roundtrip" {
    const allocator = std.testing.allocator;
    const plaintext = "super-secret-api-key-12345";
    const ciphertext = try encrypt(allocator, plaintext);
    defer allocator.free(ciphertext);
    try std.testing.expect(ciphertext.len > 0);
    try std.testing.expect(!std.mem.eql(u8, plaintext, ciphertext));
    const decrypted = try decrypt(allocator, ciphertext);
    defer allocator.free(decrypted);
    try std.testing.expectEqualStrings(plaintext, decrypted);
}

test "E3.37 dpapi: un blob que no es de este usuario/maquina falla honesto" {
    const allocator = std.testing.allocator;
    // El ciphertext DPAPI está ligado al par usuario+máquina (master key del
    // logon; sin CRYPTPROTECT_LOCAL_MACHINE ni entropía extra). Una DB copiada
    // a otra máquina — o un blob de otro usuario — produce CryptUnprotectData
    // FALSE → DecryptFailed, nunca plaintext parcial ni crash. Con bytes
    // arbitrarios el camino de error es el mismo que el del blob ajeno.
    try std.testing.expectError(error.DecryptFailed, decrypt(allocator, "no-es-un-blob-dpapi"));
    try std.testing.expectError(error.DecryptFailed, decrypt(allocator, ""));
    const garbage = [_]u8{ 0xDE, 0xAD, 0xBE, 0xEF, 1, 2, 3, 4, 5, 6, 7, 8 };
    try std.testing.expectError(error.DecryptFailed, decrypt(allocator, &garbage));
}
