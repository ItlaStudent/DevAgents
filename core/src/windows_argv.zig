//! Quoting de argv de Windows. No interpreta ni escapa sintaxis de shell.
const std = @import("std");

/// Reglas de argv de Windows (backslashes antes de comillas o del cierre).
/// Compartido por executor, spaces y hooks para no divergir al fijar argv.
pub fn appendArg(buf: *std.ArrayList(u8), allocator: std.mem.Allocator, arg: []const u8) !void {
    if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidArgument;
    const needs_quote = arg.len == 0 or for (arg) |c| {
        if (c == ' ' or c == '\t' or c == '"' or c == '\r' or c == '\n') break true;
    } else false;
    if (!needs_quote) {
        try buf.appendSlice(allocator, arg);
        return;
    }
    try buf.append(allocator, '"');
    var i: usize = 0;
    while (i < arg.len) : (i += 1) {
        var backslashes: usize = 0;
        while (i < arg.len and arg[i] == '\\') {
            backslashes += 1;
            i += 1;
        }
        if (i == arg.len) {
            try buf.appendNTimes(allocator, '\\', backslashes * 2);
            break;
        }
        if (arg[i] == '"') {
            try buf.appendNTimes(allocator, '\\', backslashes * 2 + 1);
            try buf.append(allocator, '"');
        } else {
            try buf.appendNTimes(allocator, '\\', backslashes);
            try buf.append(allocator, arg[i]);
        }
    }
    try buf.append(allocator, '"');
}

pub fn freeParsed(allocator: std.mem.Allocator, args: [][]u8) void {
    for (args) |arg| allocator.free(arg);
    allocator.free(args);
}

/// Migra una línea heredada a argv UNA VEZ, antes de sustituir datos externos.
/// No es un parser cmd: %, !, ^, &, etc. se conservan como texto literal.
/// Comillas sin cierre se rechazan en vez de cambiar silenciosamente el contrato.
pub fn parseLegacy(allocator: std.mem.Allocator, line: []const u8) ![][]u8 {
    if (std.mem.indexOfScalar(u8, line, 0) != null) return error.InvalidArgument;
    var args = std.ArrayList([]u8).empty;
    errdefer {
        for (args.items) |arg| allocator.free(arg);
        args.deinit(allocator);
    }
    var i: usize = 0;
    while (i < line.len) {
        while (i < line.len and (line[i] == ' ' or line[i] == '\t')) : (i += 1) {}
        if (i == line.len) break;
        var arg = std.ArrayList(u8).empty;
        defer arg.deinit(allocator);
        var quoted = false;
        while (i < line.len) {
            if (!quoted and (line[i] == ' ' or line[i] == '\t')) break;
            var backslashes: usize = 0;
            while (i < line.len and line[i] == '\\') : (i += 1) backslashes += 1;
            if (i < line.len and line[i] == '"') {
                try arg.appendNTimes(allocator, '\\', backslashes / 2);
                if (backslashes % 2 == 1) {
                    try arg.append(allocator, '"');
                    i += 1;
                } else if (quoted and i + 1 < line.len and line[i + 1] == '"') {
                    try arg.append(allocator, '"');
                    i += 2;
                } else {
                    quoted = !quoted;
                    i += 1;
                }
            } else {
                try arg.appendNTimes(allocator, '\\', backslashes);
                if (i == line.len) break;
                if (!quoted and (line[i] == ' ' or line[i] == '\t')) break;
                try arg.append(allocator, line[i]);
                i += 1;
            }
        }
        if (quoted) return error.UnterminatedQuote;
        const owned = try arg.toOwnedSlice(allocator);
        args.append(allocator, owned) catch |err| {
            allocator.free(owned);
            return err;
        };
    }
    return args.toOwnedSlice(allocator);
}

test "SEC2 windows argv quoting preserva vacio y texto hostil al migrar" {
    const allocator = std.testing.allocator;
    const cases: []const []const u8 = &.{ "", "normal", "C:\\ruta con espacios\\", "a\"b", "& | ^ % ! < > ( ) \"\r\n中文", "a\\\"b" };
    var line = std.ArrayList(u8).empty;
    defer line.deinit(allocator);
    for (cases, 0..) |arg, index| {
        if (index != 0) try line.append(allocator, ' ');
        try appendArg(&line, allocator, arg);
    }
    const parsed = try parseLegacy(allocator, line.items);
    defer freeParsed(allocator, parsed);
    try std.testing.expectEqual(cases.len, parsed.len);
    for (cases, parsed) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
}

test "SEC2 windows argv rechaza NUL y comillas heredadas sin cierre" {
    var buf = std.ArrayList(u8).empty;
    defer buf.deinit(std.testing.allocator);
    try std.testing.expectError(error.InvalidArgument, appendArg(&buf, std.testing.allocator, "x\x00y"));
    try std.testing.expectError(error.InvalidArgument, parseLegacy(std.testing.allocator, "x\x00y"));
    try std.testing.expectError(error.UnterminatedQuote, parseLegacy(std.testing.allocator, "tool \"sin cierre"));
}
