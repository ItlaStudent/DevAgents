const shared = @import("providers").platform;
pub const ticks = shared.ticks;
pub const sleep = shared.sleep;
pub const env = shared.env;
pub const cwd = shared.cwd;
pub const files = @import("providers").posix_files;
pub const environ = shared.environ;
pub const random = shared.random;
pub const filetime = shared.filetime;

pub const tempPath = shared.tempPath;

pub fn pathEqual(a: []const u8, b: []const u8) bool {
    return if (@import("builtin").os.tag == .windows) @import("std").ascii.eqlIgnoreCase(a, b) else @import("std").mem.eql(u8, a, b);
}
test "B10 path comparison respects platform case semantics" {
    try @import("std").testing.expect(pathEqual("same", "same"));
    try @import("std").testing.expectEqual(@import("builtin").os.tag == .windows, pathEqual("A", "a"));
}

/// T9 (L7): una prueba que solo vale en un sistema se omite en el otro diciendo
/// por que. Uso: `if (builtin.os.tag != .windows) return platform.skip("...");`
/// (el `if` con condicion conocida en compilacion evita analizar el resto).
/// Devuelve `error.PlatformNotApplicable`, no `SkipZigTest`: el runner del
/// proyecto (tools/quiet_test_runner.zig, R14) sigue fallando la puerta ante un
/// SkipZigTest sin motivo y cuenta esta como omitida, con el motivo impreso.
pub fn skip(comptime reason: []const u8) error{PlatformNotApplicable} {
    @import("std").debug.print("SKIPPED_REASON=" ++ reason ++ "\n", .{});
    return error.PlatformNotApplicable;
}

/// T9: cierra el handle de un `std.Io.File` abierto por confined_fs (HANDLE en
/// Windows, descriptor en POSIX) sin pasar por la API de cada sistema.
pub fn closeHandle(h: @import("std").posix.fd_t) void {
    if (@import("builtin").os.tag == .windows) {
        _ = struct {
            extern "kernel32" fn CloseHandle(@import("std").os.windows.HANDLE) callconv(.winapi) c_int;
        }.CloseHandle(h);
    } else _ = @import("std").c.close(h);
}

/// T9: metadatos y lectura sobre el descriptor de un `std.Io.File` en POSIX
/// (en Windows los llamadores siguen con GetFileInformationByHandleEx/ReadFile).
pub const FdInfo = struct { directory: bool, regular: bool, size: u64 };
pub fn fdInfo(h: @import("std").posix.fd_t) !FdInfo {
    if (@import("builtin").os.tag == .windows) @compileError("fdInfo es solo POSIX");
    const std = @import("std");
    const meta = @import("providers").posix_stat.get(h, null) catch return error.StatFailed;
    const kind = meta.mode & std.c.S.IFMT;
    return .{ .directory = kind == std.c.S.IFDIR, .regular = kind == std.c.S.IFREG, .size = @intCast(@max(meta.size, 0)) };
}
pub fn fdRead(h: @import("std").posix.fd_t, buf: []u8) !usize {
    if (@import("builtin").os.tag == .windows) @compileError("fdRead es solo POSIX");
    const std = @import("std");
    while (true) {
        const n = std.c.read(h, buf.ptr, buf.len);
        if (n < 0 and std.c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
        if (n < 0) return error.ReadFailed;
        return @intCast(n);
    }
}
