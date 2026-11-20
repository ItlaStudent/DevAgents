//! Batch tiene una segunda gramática: nunca usar appendArg como escape de cmd.
const std = @import("std");

pub const Error = error{ OutOfMemory, UnsafeBatchArgument };

extern "kernel32" fn GetSystemDirectoryW([*]u16, u32) callconv(.winapi) u32;

/// El directorio del SO, no PATH/COMSPEC/SystemRoot (entorno manipulable).
pub fn systemCmdExe(a: std.mem.Allocator) error{ OutOfMemory, ExeNotResolved }![:0]u8 {
    // T9: no hay cmd.exe fuera de Windows: nada se lanza por el.
    if (@import("builtin").os.tag != .windows) return error.ExeNotResolved;
    var directory: [32768]u16 = undefined;
    const n = GetSystemDirectoryW(&directory, directory.len);
    if (n == 0 or n >= directory.len) return error.ExeNotResolved;
    const utf8 = std.unicode.utf16LeToUtf8Alloc(a, directory[0..n]) catch |err| return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        else => error.ExeNotResolved,
    };
    defer a.free(utf8);
    return std.fmt.allocPrintSentinel(a, "{s}" ++ std.fs.path.sep_str ++ "cmd.exe", .{utf8}, 0);
}

pub fn validateArg(arg: []const u8) error{UnsafeBatchArgument}!void {
    for (arg) |c| if (c < 32 or c == '%' or c == '!' or c == '"') return error.UnsafeBatchArgument;
    // CRT exige duplicar los backslashes antes del cierre, pero un batch que
    // consume %~1 observaría esa duplicación literalmente. Sin conocer el
    // consumidor no hay una representación que conserve ambos contratos.
    if (arg.len > 0 and arg[arg.len - 1] == '\\') return error.UnsafeBatchArgument;
}

/// También antes de std.process.spawn: Zig 0.16 tiene el escape batch de Rust,
/// pero el contrato de rechazo de expansión ambigua sigue siendo el mismo.
pub fn validateArgs(shim: []const u8, args: []const []const u8) error{UnsafeBatchArgument}!void {
    if (shim.len == 0 or shim[shim.len - 1] == '\\') return error.UnsafeBatchArgument;
    try validateArg(shim);
    for (args) |arg| try validateArg(arg);
}

/// Subconjunto que conserva argv incluso en un shim que reenvía %*.
/// /v:off desactiva delayed expansion; un batch puede reactivarla o hacer CALL,
/// por eso !, %, comillas y controles ambiguos se rechazan, sin sustituciones.
/// Caret-quoting de cmd (comillas incluidas), separado del quoting Windows.
/// Los carets se consumen en el parse del shell y el batch recibe el dato
/// entrecomillado intacto. Las rutas fijadas usan comillas normales aparte.
pub fn appendBatchArg(out: *std.ArrayList(u8), a: std.mem.Allocator, arg: []const u8) Error!void {
    try validateArg(arg);
    try out.appendSlice(a, "^\"");
    for (arg) |c| {
        if (std.mem.indexOfScalar(u8, "&|^<>()", c) != null) try out.append(a, '^');
        try out.append(a, c);
    }
    try out.appendSlice(a, "^\"");
}

fn appendPinnedPath(out: *std.ArrayList(u8), a: std.mem.Allocator, path: []const u8) Error!void {
    try validateArg(path);
    try out.append(a, '"');
    try out.appendSlice(a, path);
    try out.append(a, '"');
}

pub fn buildCommandLine(a: std.mem.Allocator, cmd: []const u8, shim: []const u8, args: []const []const u8) Error![:0]u8 {
    try validateArgs(shim, args);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(a);
    try appendPinnedPath(&out, a, cmd);
    try out.appendSlice(a, " /d /e:on /v:off /s /c \"");
    // Nombre de archivo: no usar duplicación CRT de slash al final.
    try appendPinnedPath(&out, a, shim);
    for (args) |arg| {
        try out.append(a, ' ');
        try appendBatchArg(&out, a, arg);
    }
    try out.append(a, '"');
    return a.dupeZ(u8, out.items);
}

test "SEC2 batch rejects expansion quotes and multiline before spawn" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "%VAR%", "%%", "!name!", "x\ny", "x\ry", "x\x00y", "\" & echo injected", "\"%VAR%\"", "text\"%PATH% & injected", "trail\\", "C:\\folder\\" }) |arg| {
        try std.testing.expectError(error.UnsafeBatchArgument, buildCommandLine(a, "C:\\Windows\\System32\\cmd.exe", "C:\\shim.cmd", &.{arg}));
    }
}

test "SEC2 cmd.exe se fija desde el directorio del sistema operativo" {
    const a = std.testing.allocator;
    const cmd = try systemCmdExe(a);
    defer a.free(cmd);
    try std.testing.expect(std.fs.path.isAbsoluteWindows(cmd));
    try std.testing.expect(std.ascii.endsWithIgnoreCase(cmd, "\\cmd.exe"));
}

test "SEC2 batch quote metacharacters and empty argv separately" {
    const a = std.testing.allocator;
    const line = try buildCommandLine(a, "C:\\Windows\\System32\\cmd.exe", "C:\\a & (b)\\shim.cmd", &.{ "a & | ^ < > ( )", "" });
    defer a.free(line);
    try std.testing.expectEqualStrings("\"C:\\Windows\\System32\\cmd.exe\" /d /e:on /v:off /s /c \"\"C:\\a & (b)\\shim.cmd\" ^\"a ^& ^| ^^ ^< ^> ^( ^)^\" ^\"^\"\"", line);
}
