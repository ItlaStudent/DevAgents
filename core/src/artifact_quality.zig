//! / E-GOV.1: calidad de artefactos con procedencia del motor.
//!
//! El gate determinista no debe confundir una omisión heredada (ya presente
//! antes de la tarea) con una omisión nueva. El motor captura las huellas de
//! las líneas-marcador en la línea base del espacio y las propaga al artefacto;
//! aquí se comparan por línea y por multiplicidad. Una huella repetida más
//! veces que en la base, o una huella ausente de la base, sigue siendo un fallo.
const std = @import("std");

pub const LineHash = [32]u8;

const markers = [_][]const u8{
    "TODO:",
    "TODO ",
    "simulación del",
    "simulacion del",
    "omitida por",
    "omitido por",
    "omitted for",
    "would be implemented",
    "se implementaría",
    "se implementaria",
    "pseudocódigo",
    "pseudocodigo",
    "placeholder implementation",
};

fn placeholderLine(line: []const u8) bool {
    for (markers) |marker| if (std.ascii.indexOfIgnoreCase(line, marker) != null) return true;
    return false;
}

/// Huellas de líneas de implementación incompleta de todo el contenido.
/// La multiplicidad importa: copiar un marcador heredado a un stub nuevo falla.
pub fn placeholderLines(a: std.mem.Allocator, content: []const u8) ![]LineHash {
    var hashes: std.ArrayList(LineHash) = .empty;
    errdefer hashes.deinit(a);
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!placeholderLine(trimmed)) continue;
        var hash: LineHash = undefined;
        std.crypto.hash.sha2.Sha256.hash(trimmed, &hash, .{});
        try hashes.append(a, hash);
    }
    return hashes.toOwnedSlice(a);
}

/// Una base nula es un artefacto nuevo/sin probar y conserva el gate estricto.
/// La deuda idéntica heredada no prueba que la edición pedida esté incompleta.
pub fn invalidReason(path: []const u8, content: []const u8, inherited: ?[]const LineHash) ?[]const u8 {
    if (content.len == 0) return "se esperaba contenido; se encontró un archivo vacío";
    if (std.mem.eql(u8, content, "python")) return "se esperaba código; se encontró sólo el literal python";
    var lines = std.mem.splitScalar(u8, content, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r");
        if (!placeholderLine(trimmed)) continue;
        const baseline = inherited orelse return trimmed;
        var hash: LineHash = undefined;
        std.crypto.hash.sha2.Sha256.hash(trimmed, &hash, .{});
        var available: usize = 0;
        for (baseline) |old| if (std.mem.eql(u8, &old, &hash)) {
            available += 1;
        };
        var observed: usize = 0;
        const upto = lines.index orelse content.len;
        var preceding = std.mem.splitScalar(u8, content[0..upto], '\n');
        while (preceding.next()) |prior| {
            if (std.mem.eql(u8, std.mem.trim(u8, prior, " \t\r"), trimmed)) observed += 1;
        }
        if (observed > available) return trimmed;
    }
    const ext = std.fs.path.extension(path);
    const free_text = ext.len == 0 or
        std.ascii.eqlIgnoreCase(ext, ".txt") or
        std.ascii.eqlIgnoreCase(ext, ".md") or
        std.ascii.eqlIgnoreCase(ext, ".markdown") or
        std.ascii.eqlIgnoreCase(ext, ".text") or
        std.ascii.eqlIgnoreCase(ext, ".log") or
        std.ascii.eqlIgnoreCase(ext, ".csv");
    if (content.len < 10 and !free_text and std.mem.indexOfAny(u8, content, "=(){}[];.:,+-*/%#\"'0123456789<>!&|") == null) return "se esperaba código estructurado; se encontró texto corto sin tokens de código";
    return null;
}

fn exercisePlaceholderAllocations(a: std.mem.Allocator) !void {
    const lines = try placeholderLines(a, "TODO: inherited\n" ** 40);
    defer a.free(lines);
    try std.testing.expectEqual(@as(usize, 40), lines.len);
}

test "E-GOV.1: huellas heredadas no eximen marcadores nuevos duplicados ni codigo vacio" {
    const a = std.testing.allocator;
    try std.testing.checkAllAllocationFailures(a, exercisePlaceholderAllocations, .{});
    const old = try placeholderLines(a, "# TODO: inherited type annotation\r\ndef old(): pass\n");
    defer a.free(old);
    try std.testing.expect(invalidReason("lib.py", "# TODO: inherited type annotation\ndef new(): return 1\n", old) == null);
    try std.testing.expect(invalidReason("lib.py", "# TODO: implement new method\ndef new(): pass\n", old) != null);
    try std.testing.expect(invalidReason("lib.py", "# TODO: inherited type annotation\n# TODO: inherited type annotation\n", old) != null);
    try std.testing.expect(invalidReason("lib.py", "# TODO: inherited type annotation\n", null) != null);
    try std.testing.expect(invalidReason("lib.py", "", old) != null);
    try std.testing.expect(invalidReason("lib.py", "python", old) != null);
    try std.testing.expect(invalidReason("lib.py", "basura", old) != null);
    try std.testing.expect(invalidReason("out.txt", "UNO", null) == null);
    const empty = try placeholderLines(a, "func complete() {}\n");
    defer a.free(empty);
    try std.testing.expectEqual(@as(usize, 0), empty.len);
}
