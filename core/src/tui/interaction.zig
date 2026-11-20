//! E2/E3: protocolo privado entre la sesión y `order --tui-session`.
//! El hijo conserva su plan mientras espera en stdin; EOF nunca aprueba.
//! E3 añade los avisos de avance (`task`/`file`, sin respuesta) y la petición
//! de permiso (`perm`, con respuesta 1/2/3) — la UI queda preparada aunque el
//! flujo actual no tenga canal interactivo DURANTE la ejecución.
const std = @import("std");

pub const Request = union(enum) {
    approve,
    answer,
    /// Confirmación durante la ejecución: descripción de lo que se va a hacer.
    perm: []const u8,
};
pub const APPROVE = "\x1eDA2:approve";
pub const ANSWER = "\x1eDA2:answer";
pub const PERM = "\x1eDA2:perm:";
pub const TASK = "\x1eDA2:task";
pub const FILE = "\x1eDA2:file";
pub const CANCEL = "3";

pub fn requestOf(line: []const u8) ?Request {
    if (std.mem.eql(u8, line, APPROVE)) return .approve;
    if (std.mem.eql(u8, line, ANSWER)) return .answer;
    if (std.mem.startsWith(u8, line, PERM)) {
        const desc = std.mem.trim(u8, line[PERM.len..], " \t");
        if (desc.len > 0) return .{ .perm = desc };
    }
    return null;
}

/// Aviso de avance (una sola dirección): no espera respuesta.
pub fn isProgressLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, TASK) or std.mem.startsWith(u8, line, FILE);
}

/// Lector inyectable: no anticipa bytes de la siguiente respuesta.
pub fn readReplyFrom(allocator: std.mem.Allocator, reader: anytype) ![]u8 {
    var result: std.ArrayList(u8) = .empty;
    errdefer result.deinit(allocator);
    while (true) {
        const byte = try reader.readByte();
        if (byte == null) return error.SessionClosed;
        if (byte.? == '\n') break;
        if (byte.? == '\r') continue;
        if (result.items.len >= 16384) return error.ReplyTooLong;
        try result.append(allocator, byte.?);
    }
    return result.toOwnedSlice(allocator);
}

pub fn readReply(allocator: std.mem.Allocator) ![]u8 {
    const Input = struct {
        fn readByte(_: @This()) !?u8 {
            var b: [1]u8 = undefined;
            const io = std.Io.Threaded.global_single_threaded.io();
            const n = try std.Io.File.stdin().readStreaming(io, &.{&b});
            return if (n == 0) null else b[0];
        }
    };
    return readReplyFrom(allocator, Input{});
}

pub fn approved(reply: []const u8) bool {
    return std.mem.eql(u8, reply, "1");
}

test "CK-MOT-027 E2: protocolo rechaza EOF respuestas invalidas y lee una linea" {
    const Fake = struct {
        text: []const u8,
        pos: usize = 0,
        fn readByte(self: *@This()) !?u8 {
            if (self.pos == self.text.len) return null;
            defer self.pos += 1;
            return self.text[self.pos];
        }
    };
    const a = std.testing.allocator;
    var fake = Fake{ .text = "1\r\n3\n" };
    const first = try readReplyFrom(a, &fake);
    defer a.free(first);
    try std.testing.expect(approved(first));
    const second = try readReplyFrom(a, &fake);
    defer a.free(second);
    try std.testing.expect(!approved(second));
    try std.testing.expectError(error.SessionClosed, readReplyFrom(a, &fake));
    try std.testing.expect(!approved(""));
    try std.testing.expect(!approved("yes"));
    try std.testing.expect(requestOf(APPROVE).? == .approve);
    try std.testing.expect(requestOf(ANSWER).? == .answer);
    try std.testing.expectEqual(null, requestOf("modelo: aprobar"));
    // E3: permiso con descripción y avisos de una sola dirección.
    const perm = requestOf(PERM ++ "Ejecutar npm test").?;
    try std.testing.expectEqualStrings("Ejecutar npm test", perm.perm);
    try std.testing.expectEqual(null, requestOf(PERM));
    try std.testing.expect(isProgressLine(TASK ++ " t1 ok 1 2 m d"));
    try std.testing.expect(isProgressLine(FILE ++ " t1 a.txt"));
    try std.testing.expect(!isProgressLine("normal"));
}
