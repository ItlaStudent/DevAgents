//! core/src/executor.zig — Ejecución REAL de procesos gobernada por política.
//!
//! MVP de EXEC-01: default-deny. Solo ejecuta binarios en un allowlist explícito
//! dentro de un cwd confinado al workspace. Cualquier escape, red o gasto requiere
//! aprobación (T-F7-07) y NO se ejecuta.
//!
//! El spawn usa API Win32 directa para evitar el mismo access violation que
//! `std.Io.Threaded` provocó en el host Qt/MSVC.

const std = @import("std");
const builtin = @import("builtin");
const sandbox = @import("sandbox.zig");
const workspace = @import("workspace.zig");
const hooks = @import("hooks.zig");
const command_policy = @import("command_policy.zig");
const command_environment = @import("command_environment.zig");

// Los tests del propio archivo se referen a sí mismos como `executor`.
const executor = @This();

/// Ejecutables permitidos por el allowlist. Solo se compara el NOMBRE BASE
/// (sin ruta, sin extensión .exe). Cualquier otro ejecutable rechaza la política.
pub const ALLOWLIST = &[_][]const u8{
    "python",     "py",    "node", "zig",   "gcc",   "clang", "clang++", "g++",
    "powershell", "pwsh",
    // P-EXEC-2: raw shell commands — governed by checkPrefix denylist + PermissionMode.
     "git",  "rm",    "ls",    "cat",   "echo",    "find",
    "grep",       "sed",   "awk",  "sort",  "wc",    "head",  "tail",    "diff",
    "touch",      "mv",    "cp",   "mkdir", "rmdir", "which", "where",   "npm",
    "npx",        "cargo", "go",   "make",  "cmake", "ninja", "dotnet",  "ruby",
    "perl",       "bash",  "sh",
};

/// UI-ACTION: allowlist de acciones cosméticas que una orden, un worker con
/// tools o un cliente MCP pueden pedirle a la cabina. Es la ÚNICA lista: la
/// tarea determinística `ui` (superagent), la tool `ui_action`
/// (governed_tool_executor) y `da_ui_action_request` (c_api) validan contra ella.
/// Cosméticas y reversibles únicamente — permisos/gobernanza/claves/workspace
/// NUNCA van por aquí (tienen sus exports gobernados con aprobación).
// E5.21: "open_window" abre una ventana secundaria nativa con una vista
// aislada (editor/terminal/conversacion/monitor). El host valida los
// argumentos con ParseOpenWindow; la cabina revalida la accion en
// ui_actions.ts antes de tocar el puente.
pub const UI_ACTIONS = &[_][]const u8{ "set_theme", "open_view", "focus_session", "notify", "open_window" };

pub fn uiActionAllowed(action: []const u8) bool {
    for (UI_ACTIONS) |a| {
        if (std.mem.eql(u8, action, a)) return true;
    }
    return false;
}

/// La línea efectiva que va al proceso (exe + argv renderizado). Es lo que el
/// usuario debe VER en la card del comando y lo que correlaciona los eventos
/// `shell_command` running→delta→done: emitir solo el exe escondía el script
/// real (`powershell -Command "<script>"` se mostraba como "powershell").
/// Reglas de presentación: un arg con espacios/comillas se envuelve en
/// comillas con `\"` escapado — CreateProcess recibe el argv real, esto solo
/// compone el texto visible/auditable.
/// H13: tope de bytes visibles por segmento (ejecutable o argumento)
/// en el texto de la tarjeta de aprobación. Si el segmento renderizado lo
/// excede, la tarjeta muestra el principio Y el final (mitad del tope libre
/// cada uno) con la marca `[truncado] N bytes omitidos en medio`: esconder el
/// final dejaría un sufijo peligroso sin revisar, y negar la tarjeta rompería
/// el flujo para rutas largas legítimas.
const approval_arg_max_bytes: usize = 2048;
/// Reserva para la marca de truncado (incluye el contador en dígitos).
const approval_truncation_marker_reserve: usize = 64;

/// H13: true para los caracteres bidi con fuerza de dirección
/// (U+202A-202E, U+2066-2069) y para las marcas LRM/RLM (U+200E/200F), que
/// pueden invertir visualmente el orden de lectura de un comando y hacer que
/// lo que el aprobador ve no sea lo que el proceso ejecuta.
fn isBidiControl(cp: u21) bool {
    return (cp >= 0x202A and cp <= 0x202E) or
        (cp >= 0x2066 and cp <= 0x2069) or
        cp == 0x200E or cp == 0x200F;
}

/// H13 r4/r5: puntos de código que ocultan o reordenan el texto
/// visible sin cambiar el comando: además de los bidi, ALM (U+061C), el CGJ
/// (U+034F), el rango completo de inhibidores por defecto U+2060-U+206F (que
/// incluye los inherit/symmetric U+206A-U+206F), las marcas de ancho cero
/// (ZWSP/ZWNJ/ZWJ, BOM), los separadores de línea y párrafo (U+2028/2029) y el
/// soft hyphen. También cubre los rellenos Hangul/Khmer, selectores de
/// variación, controles musicales, shorthand y tags suplementarios.
fn hidesVisibleText(cp: u21) bool {
    return isBidiControl(cp) or
        cp == 0x061C or
        cp == 0x034F or
        cp == 0x00AD or
        (cp >= 0x115F and cp <= 0x1160) or
        (cp >= 0x17B4 and cp <= 0x17B5) or
        (cp >= 0x180B and cp <= 0x180F) or
        cp == 0x200B or cp == 0x200C or cp == 0x200D or
        (cp >= 0x2060 and cp <= 0x206F) or
        cp == 0x2028 or cp == 0x2029 or
        cp == 0x3164 or
        (cp >= 0xFE00 and cp <= 0xFE0F) or
        cp == 0xFEFF or cp == 0xFFA0 or
        (cp >= 0xFFF0 and cp <= 0xFFF8) or
        (cp >= 0x1BCA0 and cp <= 0x1BCA3) or
        (cp >= 0x1D173 and cp <= 0x1D17A) or
        (cp >= 0xE0000 and cp <= 0xE0FFF);
}

/// Longitud de la secuencia UTF-8 que empieza en `s[i]`; 1 para bytes sueltos.
fn utf8SequenceLen(s: []const u8, i: usize) usize {
    return std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
}

/// Token escapado del punto de código que empieza en `raw[i]` (uno solo, válido
/// o no), escrito en `buf` (≥16 bytes: el token más largo posible es
/// `\u{10FFFF}`, 10 bytes). Avanza `i` más allá del punto.
/// R5 (el segundo auditor lote AH, P1-c): sin asignaciones por punto de código — la tarjeta
/// se renderiza bajo un FailingAllocator en la reanudación con OOM y cada
/// asignación extra empuja el spawn más allá del índice de fallo que la prueba
/// SEC2 de reanudación recorre.
fn escapeCodePointInto(raw: []const u8, i: *usize, buf: *[16]u8) usize {
    var step: usize = utf8SequenceLen(raw, i.*);
    var invalid = false;
    var cp: u21 = 0;
    if (i.* + step <= raw.len) {
        if (std.unicode.utf8Decode(raw[i.* .. i.* + step])) |decoded| {
            cp = decoded;
        } else |_| {
            invalid = true;
            step = 1;
        }
    } else {
        invalid = true;
        step = 1;
    }
    const written: usize = if (invalid) blk: {
        const s = "\\u{FFFD}";
        @memcpy(buf[0..s.len], s);
        break :blk s.len;
    } else if (cp == '\n') blk: {
        buf[0] = '\\';
        buf[1] = 'n';
        break :blk 2;
    } else if (cp == '\r') blk: {
        buf[0] = '\\';
        buf[1] = 'r';
        break :blk 2;
    } else if (cp == '\\') blk: {
        buf[0] = '\\';
        buf[1] = '\\';
        break :blk 2;
    } else if (cp < 0x20 or (cp >= 0x7F and cp <= 0x9F) or hidesVisibleText(cp)) blk: {
        const s = std.fmt.bufPrint(buf, "\\u{{{X:0>4}}}", .{cp}) catch unreachable;
        break :blk s.len;
    } else blk: {
        var enc: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &enc) catch {
            const s = "\\u{FFFD}";
            @memcpy(buf[0..s.len], s);
            break :blk s.len;
        };
        @memcpy(buf[0..n], enc[0..n]);
        break :blk n;
    };
    i.* += step;
    return written;
}

/// Token escapado de UN punto de código ya delimitado (una entrada de
/// `decodePreviousCodePoint`), en `buf` de 16 bytes.
fn escapeCodePointToken(slice: []const u8, buf: *[16]u8) usize {
    var i: usize = 0;
    return escapeCodePointInto(slice, &i, buf);
}

/// Punto de código que termina en `end` (índice exclusivo), leyendo hacia
/// atrás. `start` es su primer byte y `len` su longitud (1 si la secuencia es
/// inválida o un byte suelto).
fn decodePreviousCodePoint(s: []const u8, end: usize) struct { start: usize, cp: u21, len: usize } {
    if (end == 0) return .{ .start = 0, .cp = 0, .len = 0 };
    var i = end - 1;
    while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;
    const lead_len: usize = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
    if (i + lead_len == end) {
        if (std.unicode.utf8Decode(s[i..end])) |cp| {
            return .{ .start = i, .cp = cp, .len = end - i };
        } else |_| {}
    }
    return .{ .start = end - 1, .cp = 0xFFFD, .len = 1 };
}

/// H13 r4/r5: texto visible de UN segmento (ejecutable o argumento)
/// escrito en `buf` (≥ approval_arg_max_bytes + 128, siempre buffer de pila
/// del caller). Escapa saltos, controles, bidi, ancho cero y barras inversas;
/// si el texto escapa excede el tope, entrega principio y final con la marca
/// de bytes omitidos en medio. R5 (el segundo auditor lote AH, P1-c): CERO asignaciones por
/// segmento ni por punto de código — la tarjeta se renderiza bajo un
/// FailingAllocator en la reanudación con OOM (SEC2 approval resume) y cada
/// asignación intermedia empujaba el spawn más allá del índice de fallo que
/// esa prueba recorre. Devuelve el subescrito escrito de `buf`.
fn renderSegmentBuf(buf: []u8, raw: []const u8) []const u8 {
    // Intento completo: escribe mientras quepa dentro del tope por segmento.
    var len: usize = 0;
    var i: usize = 0;
    var truncated = false;
    while (i < raw.len) {
        var tok: [16]u8 = undefined;
        const n = escapeCodePointInto(raw, &i, &tok);
        if (len + n > approval_arg_max_bytes) {
            truncated = true;
            break;
        }
        @memcpy(buf[len..][0..n], tok[0..n]);
        len += n;
    }
    // El token que no cabe ya avanzó i, incluso si era el último de raw.
    if (!truncated) return buf[0..len];

    // Truncado con cabeza y cola: mitad del tope libre para cada extremo, y la
    // marca reservada en el medio. Se corta siempre en frontera de punto de
    // código; los bytes que quedan en medio se cuentan y se dicen. La cola se
    // compone hacia atrás desde el final de `buf` y luego se pega al marker.
    const edge = (approval_arg_max_bytes - approval_truncation_marker_reserve) / 2;
    var head_len: usize = 0;
    var head_end: usize = 0;
    i = 0;
    while (i < raw.len) {
        var tok: [16]u8 = undefined;
        const n = escapeCodePointInto(raw, &i, &tok);
        if (head_len + n > edge) break;
        head_len += n;
        head_end = i;
    }
    var pos = buf.len;
    var tail_len: usize = 0;
    var j = raw.len;
    while (j > head_end) {
        const prev = decodePreviousCodePoint(raw, j);
        if (prev.len == 0) break;
        var tok: [16]u8 = undefined;
        const n = escapeCodePointToken(raw[prev.start .. prev.start + prev.len], &tok);
        if (tail_len + n > edge) break;
        pos -= n;
        @memcpy(buf[pos..][0..n], tok[0..n]);
        tail_len += n;
        j = prev.start;
    }
    const omitted = j - head_end;
    var mbuf: [approval_truncation_marker_reserve]u8 = undefined;
    const marker = std.fmt.bufPrint(&mbuf, "[truncado] {d} bytes omitidos en medio", .{omitted}) catch "[truncado]";
    @memcpy(buf[head_len..][0..marker.len], marker);
    std.mem.copyForwards(u8, buf[head_len + marker.len ..][0..tail_len], buf[pos..][0..tail_len]);
    return buf[0 .. head_len + marker.len + tail_len];
}

pub fn renderCommandLine(allocator: std.mem.Allocator, exe: []const u8, args: []const []const u8) ![]u8 {
    // Segment storage SIEMPRE en pila; la unica asignacion de esta funcion es
    // la linea final (P1-c: el camino de reanudacion OOM debe llegar al spawn
    // con el minimo de asignaciones posible).
    var seg_storage: [approval_arg_max_bytes + 128]u8 = undefined;
    // Pasada 1: longitud total (mismo entrada => mismo texto; sin asignar).
    var total: usize = 0;
    total += renderSegmentBuf(&seg_storage, exe).len;
    for (args) |a| {
        const rendered = renderSegmentBuf(&seg_storage, a);
        total += 1 + rendered.len;
        // Entrecomillado: comillas delimitadoras + cada comilla interna doblada.
        if (std.mem.indexOfAny(u8, rendered, " \t\"") != null) {
            total += 2 + std.mem.count(u8, rendered, "\"");
        }
    }
    const out = try allocator.alloc(u8, total);
    errdefer allocator.free(out);
    var w = std.Io.Writer.fixed(out);
    {
        // Pasada 2: se re-renderiza y se escribe en la unica asignacion.
        const exe_text = renderSegmentBuf(&seg_storage, exe);
        try w.writeAll(exe_text);
        for (args) |a| {
            try w.writeByte(' ');
            const rendered = renderSegmentBuf(&seg_storage, a);
            const needs_quote = std.mem.indexOfAny(u8, rendered, " \t\"") != null;
            if (!needs_quote) {
                try w.writeAll(rendered);
            } else {
                try w.writeByte('"');
                // H13: dentro de comillas solo se escapa la comilla por
                // ser el propio delimitador; las barras de los escapes (\n, \r,
                // \u{XXXX}) se muestran tal cual para que el aprobador vea el
                // separador y el carácter visible, no un artefacto de quoting.
                for (rendered) |c| {
                    if (c == '"') try w.writeByte('\\');
                    try w.writeByte(c);
                }
                try w.writeByte('"');
            }
        }
    }
    return out;
}

test "CK-SEG-012 H13 approval command line escapes CR LF and bidi and truncates long arguments" {
    const allocator = std.testing.allocator;
    var long: [3000]u8 = undefined;
    @memset(long[0..], 'a');
    long[2047] = 0xC3;
    long[2048] = 0xB1; // "ñ" a caballo del tope de 2048 bytes
    const line = try renderCommandLine(allocator, "tool", &.{
        "safe\nrm -rf /",
        "otra\rlinea",
        "\u{202E}evil\u{2066}dir\u{200F}",
        long[0..],
    });
    defer allocator.free(line);
    try std.testing.expect(std.mem.indexOfScalar(u8, line, '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, line, '\r') == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "safe\\nrm -rf /") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "otra\\rlinea") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\u{202E}") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\u{2066}") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\u{200F}") == null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\\u{202E}") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\\u{2066}") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "\\u{200F}") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "[truncado]"));
    try std.testing.expect(line.len < 4096);
    try std.testing.expect(std.unicode.utf8ValidateSlice(line));
}

// H13 r4: el texto visible tiene que corresponder al comando que se
// ejecuta. Nada de saltos, controles C0/C1, bidi, ALM, marcas de ancho cero ni
// NUL en crudo; el ejecutable pasa por el mismo saneado que los argumentos; y
// el truncado enseña el principio Y el final con los bytes omitidos contados,
// para que un sufijo peligroso tras un argumento largo siga siendo aprobable
// a la vista.
test "CK-SEG-012 H13 r4 approval card shows head and tail, sanitizes the executable and never emits controls" {
    const allocator = std.testing.allocator;

    // 1) Sufijo peligroso después de un argumento largo: la cola queda visible.
    var filler: [3000]u8 = undefined;
    @memset(filler[0..], 'a');
    const suffix = " && rm -rf C:\\Windows";
    const payload = try std.fmt.allocPrint(allocator, "{s}{s}", .{ filler[0..], suffix });
    defer allocator.free(payload);
    const line = try renderCommandLine(allocator, "tool", &.{payload});
    defer allocator.free(line);
    try std.testing.expect(std.mem.startsWith(u8, line, "tool "));
    // Cabeza (primeros bytes del argumento) y cola (sufijo peligroso) visibles.
    // R5: la barra inversa literal se dobla en la tarjeta (`\` -> `\\`) para no
    // confundirla con el prefijo de un escape; el sufijo se ve con `C:\\Windows`.
    try std.testing.expect(std.mem.indexOf(u8, line, filler[0..64]) != null);
    try std.testing.expect(std.mem.indexOf(u8, line, " && rm -rf C:\\\\Windows") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, line, "[truncado]"));
    try std.testing.expect(std.mem.indexOf(u8, line, "bytes omitidos") != null);
    try std.testing.expect(line.len <= approval_arg_max_bytes + 128);

    // 2) La ruta del ejecutable entra por el mismo saneado.
    const evil_exe = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "evil\npw\u{202E}n.exe", .{filler[0..]});
    defer allocator.free(evil_exe);
    const exe_line = try renderCommandLine(allocator, evil_exe, &.{"x"});
    defer allocator.free(exe_line);
    try std.testing.expect(std.mem.indexOfScalar(u8, exe_line, '\n') == null);
    try std.testing.expect(std.mem.indexOfScalar(u8, exe_line, 0) == null);
    try std.testing.expect(std.mem.indexOf(u8, exe_line, "\\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, exe_line, "\\u{202E}") != null);
    try std.testing.expect(std.mem.indexOf(u8, exe_line, "n.exe") != null);
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, exe_line, "[truncado]"));

    // 3) ALM, ancho cero, NUL y bidi se escapan; el texto se puede leer entero.
    const mixed = try std.fmt.allocPrint(allocator, "seg\u{061C}ment\u{200B}end\u{0}tail\u{202E}fin\u{2028}x", .{});
    defer allocator.free(mixed);
    const mixed_line = try renderCommandLine(allocator, "tool", &.{mixed});
    defer allocator.free(mixed_line);
    try std.testing.expectEqualStrings("tool seg\\u{061C}ment\\u{200B}end\\u{0000}tail\\u{202E}fin\\u{2028}x", mixed_line);

    // 4) Unicode ordinario se conserva como UTF-8 (no se convierte en un byte).
    const unicode_line = try renderCommandLine(allocator, "tool", &.{"ñĀ漢 ñ"});
    defer allocator.free(unicode_line);
    try std.testing.expect(std.mem.indexOf(u8, unicode_line, "ñĀ漢 ñ") != null);

    // 5) Ninguna línea visible lleva bytes de control ni texto inválido.
    for ([_][]const u8{ line, exe_line, mixed_line, unicode_line }) |visible| {
        for (visible) |byte| {
            try std.testing.expect(byte >= 0x20);
            try std.testing.expect(byte != 0x7F);
        }
        try std.testing.expect(std.unicode.utf8ValidateSlice(visible));
    }
}

// H13 r5 (auditoría el segundo auditor lote AH, P1-b): el texto de la tarjeta es
// inyectivo sobre el argv. La barra inversa literal se escapa (`\` -> `\\`)
// para que un argumento que contiene `\n` o `\u{202E}` de forma textual no se
// vea igual que un salto o un bidi escapados; y la lista de controles que
// ocultan texto cubre también U+206A-U+206F (inhibidores por defecto).
test "CK-SEG-012 H13 r5 escaped backslash and remaining default-ignorables keep the card text injective" {
    const allocator = std.testing.allocator;
    // Pares argv distintos cuyo texto visible sería idéntico sin doblar la barra.
    const real_nl = try renderCommandLine(allocator, "tool", &.{"a\nb"});
    defer allocator.free(real_nl);
    const literal_nl = try renderCommandLine(allocator, "tool", &.{"a\\nb"});
    defer allocator.free(literal_nl);
    try std.testing.expect(!std.mem.eql(u8, real_nl, literal_nl));
    try std.testing.expectEqualStrings("tool a\\nb", real_nl);
    try std.testing.expectEqualStrings("tool a\\\\nb", literal_nl);

    const real_rlo = try renderCommandLine(allocator, "tool", &.{"a\u{202E}b"});
    defer allocator.free(real_rlo);
    const literal_rlo = try renderCommandLine(allocator, "tool", &.{"a\\u{202E}b"});
    defer allocator.free(literal_rlo);
    try std.testing.expect(!std.mem.eql(u8, real_rlo, literal_rlo));
    try std.testing.expectEqualStrings("tool a\\u{202E}b", real_rlo);
    try std.testing.expectEqualStrings("tool a\\\\u{202E}b", literal_rlo);

    // U+206A-U+206F salen escapados, nunca como texto crudo invisible.
    const ignorable = try renderCommandLine(allocator, "tool", &.{"x\u{206A}\u{206F}y"});
    defer allocator.free(ignorable);
    try std.testing.expect(std.mem.indexOf(u8, ignorable, "\u{206A}") == null);
    try std.testing.expect(std.mem.indexOf(u8, ignorable, "\u{206F}") == null);
    try std.testing.expectEqualStrings("tool x\\u{206A}\\u{206F}y", ignorable);
}

test "CK-SEG-012 H13 r6 final token crossing the display cap retains the tail and truncation marker" {
    const allocator = std.testing.allocator;
    var raw: [approval_arg_max_bytes + 1]u8 = undefined;
    @memset(&raw, 'a');
    raw[raw.len - 1] = '!';
    const line = try renderCommandLine(allocator, "tool", &.{&raw});
    defer allocator.free(line);
    try std.testing.expect(std.mem.indexOf(u8, line, "[truncado]") != null);
    try std.testing.expect(std.mem.indexOf(u8, line, "bytes omitidos en medio") != null);
    try std.testing.expect(std.mem.endsWith(u8, line, "!\""));

    // The final escaped token can also cross the cap by more than one byte.
    raw[raw.len - 1] = '\n';
    const escaped = try renderCommandLine(allocator, "tool", &.{raw[1..]});
    defer allocator.free(escaped);
    try std.testing.expect(std.mem.indexOf(u8, escaped, "[truncado]") != null);
    try std.testing.expect(std.mem.endsWith(u8, escaped, "\\n\""));
}

test "CK-SEG-012 H13 r6 default-ignorable ranges are visible including supplementary code points" {
    const allocator = std.testing.allocator;
    const hidden = [_]u21{
        0x00AD,  0x034F,  0x061C,  0x115F,  0x1160,  0x17B4,  0x17B5,
        0x180B,  0x180F,  0x200B,  0x200F,  0x202A,  0x202E,  0x2060,
        0x206A,  0x206B,  0x206C,  0x206D,  0x206E,  0x206F,  0x3164,
        0xFE00,  0xFE0F,  0xFEFF,  0xFFA0,  0xFFF0,  0xFFF8,  0x1BCA0,
        0x1BCA3, 0x1D173, 0x1D17A, 0xE0000, 0xE007F, 0xE0100, 0xE01EF,
        0xE0FFF,
    };
    for (hidden) |cp| {
        var encoded: [4]u8 = undefined;
        const n = try std.unicode.utf8Encode(cp, &encoded);
        const line = try renderCommandLine(allocator, "tool", &.{encoded[0..n]});
        defer allocator.free(line);
        var expected_buf: [32]u8 = undefined;
        const expected = try std.fmt.bufPrint(&expected_buf, "tool \\u{{{X:0>4}}}", .{cp});
        try std.testing.expectEqualStrings(expected, line);
    }
}

pub const Origin = enum {
    /// Origen local y de confianza: el usuario opera directamente la IDE/CLI.
    local,
    /// Origen no confiable (p. ej. orden recibida vía IDE-REMOTE): nunca se
    /// auto-ejecuta; siempre requiere aprobación humana (T-F7-07).
    untrusted,
    /// Orden iniciada por un cliente MCP. El token autentica al cliente, no
    /// concede autoridad humana: confirm_plan/dispatch_async por MCP no valen
    /// como aprobación del plan para ejecutar. Solo las consultas de versión
    /// son automáticas; cualquier otro comando exige tarjeta de la cabina.
    mcp,

    /// El plan, un modo permisivo o una allowlist no eximen este origen.
    pub fn requiresHumanApproval(self: Origin) bool {
        return self == .mcp;
    }
};

/// Modos de autonomía estilo Devin (P2):
/// - normal: read-only auto; writes/shell/exec piden permiso.
/// - accept_edits: edits en workspace auto; shell/exec piden.
/// - bypass: todo se auto-aprueba (denylist sigue ganando).
/// - autonomous: shell+exec+red auto; NO hay aislamiento de SO (lote 5).
/// El código inline de intérpretes conserva aprobación explícita por comando.
pub const PermissionMode = enum {
    normal,
    accept_edits,
    bypass,
    autonomous,
};

pub const PermissionDecision = enum {
    auto,
    ask,
};

pub const PermissionConfig = struct {
    mode: PermissionMode = .normal,
    allow_prefixes: []const []const u8 = &.{},
    deny_prefixes: []const []const u8 = &.{},
    session_allow: []const []const u8 = &.{},
};

/// P-EXEC-6: devuelve true si el comando está en la denylist.
pub fn isDenylisted(exe: []const u8, config: PermissionConfig) bool {
    return command_policy.isDenied(exe, &.{}, config.deny_prefixes);
}

/// Decide si un comando se auto-aprueba o pide permiso, basado en:
/// 1. denylist → SIEMPRE ask (gana sobre todo, incluido bypass).
/// 2. allowlist o session_allow → auto.
/// 3. modo: normal/accept_edits → ask; bypass/autonomous → auto.
pub fn checkPrefix(
    exe: []const u8,
    config: PermissionConfig,
) PermissionDecision {
    if (isDenylisted(exe, config)) return .ask;
    for (config.allow_prefixes) |a| {
        if (command_policy.sameCommand(exe, a)) return .auto;
    }
    for (config.session_allow) |a| {
        if (command_policy.sameCommand(exe, a)) return .auto;
    }

    return switch (config.mode) {
        .normal, .accept_edits => .ask,
        .bypass, .autonomous => .auto,
    };
}

pub const Policy = struct {
    workspace_root: []const u8 = workspace.WORKSPACE_ROOT,
    timeout_ms: u32 = 10_000,
    max_output_bytes: usize = 256 * 1024,
    /// `true` indica que la acción implica red o gasto: requiere aprobación.
    requires_approval: bool = false,
    /// Origen de la orden. `.untrusted` fuerza aprobación antes de cualquier spawn.
    origin: Origin = .local,
    /// H2 — lo que el programa leerá por su entrada estándar.
    ///
    /// Hasta aquí el hijo recibía `INVALID_HANDLE_VALUE` como stdin: no una
    /// entrada vacía, sino NINGUNA entrada. Cualquier programa que llamara a
    /// `input()` moría con `EOFError` antes de imprimir nada, y como el agente
    /// escribe programas de consola constantemente, eso convertía en «fallo»
    /// cualquier ejercicio que pidiera datos al usuario.
    ///
    /// Vacío ya no significa lo mismo que ausente: con una tubería real y
    /// cerrada, `input()` recibe EOF —que el programa puede manejar— en vez de
    /// tropezar con un handle inválido.
    stdin_data: []const u8 = "",
    /// Optional double-NUL UTF-16 block; startup injection is filtered even
    /// here. null takes a filtered snapshot of the parent, never inheritance.
    environment: ?[:0]const u16 = null,
    /// cancelación cooperativa de la ORDEN — el mismo token que ya
    /// usa el despacho (DispatchRegistry + live_worker.CancellationToken), con
    /// el patrón `is_cancelled_fn` del resto del motor. El bucle de espera la
    /// consulta y, si está marcada, termina el hijo y su árbol como en un
    /// timeout, sin esperar al vencimiento. null = ejecución no cancelable.
    is_cancelled_fn: ?*const fn (?*anyopaque) bool = null,
    cancelled_ctx: ?*anyopaque = null,
    /// T12 L2: se llama con el PID del hijo en cuanto queda dentro de su job
    /// y se reanuda (spawn real de Windows; los spawns simulados no lo dan).
    /// app_server lo usa para comprobar que quien escucha en el puerto es su
    /// proceso o un descendiente.
    on_spawn_fn: ?*const fn (?*anyopaque, u32) void = null,
    on_spawn_ctx: ?*anyopaque = null,
};

pub const RunResult = struct {
    /// T9: contencion real con la que corrio el hijo. En Linux sin cgroup v2
    /// delegado es `posix_partial` (grupo de procesos + setrlimit) y se dice.
    containment_mode: @import("containment.zig").Mode = .windows_job,
    exit_code: i32,
    stdout: []const u8,
    stderr: []const u8,
    /// EXEC-SHOW: el proceso no terminó dentro del timeout (p.ej. reloj/servidor
    /// continuo) y fue terminado, PERO la salida capturada hasta ese punto se
    /// conserva y devuelve (en vez de descartarse). El llamador la muestra igual.
    timed_out: bool = false,
    /// la ORDEN se canceló mientras el hijo corría y se le terminó
    /// (y con él a su árbol, vía job KILL_ON_JOB_CLOSE) sin esperar al timeout.
    /// `exit_code` queda en 130 y la salida capturada se conserva igual.
    cancelled: bool = false,
    /// Bytes REALES leídos del pipe antes del cap de `max_output_bytes`. Cuando
    /// exceden `stdout.len`/`stderr.len`, la salida devuelta está truncada: el
    /// llamador DEBE decirlo (E3.16 — antes un comando de 50 MB reportaba
    /// "exit=0" con 256 KB y nadie sabía que faltaban 49,75 MB).
    /// 0 = no medido (spawn de test que no lo rellena).
    stdout_total_bytes: usize = 0,
    stderr_total_bytes: usize = 0,

    pub fn stdoutTruncated(self: RunResult) bool {
        return self.stdout_total_bytes > self.stdout.len;
    }

    pub fn stderrTruncated(self: RunResult) bool {
        return self.stderr_total_bytes > self.stderr.len;
    }

    pub fn deinit(self: RunResult, allocator: std.mem.Allocator) void {
        allocator.free(self.stdout);
        allocator.free(self.stderr);
    }
};

/// Resultado de un lanzamiento detached (proceso independiente, sin captura de salida).
/// Se usa para programas autocontenidos/GUI (p. ej. reloj tkinter) que deben correr
/// como apps independientes sin bloquear el chat.
pub const DetachedResult = struct {
    pid: u32,
};

/// Identifica si un trozo de streaming viene de stdout o stderr.
/// ConPTY fusiona ambos en un solo flujo VT; en la práctica casi todo llega
/// como stdout. El sink puede usar esto para colorear/rutar en la UI.
pub const StreamKind = enum { stdout, stderr };

/// Sink de streaming: llamado por cada trozo leído del pipe ConPTY.
/// Permite que el superagente emita `worker_output` por trozo en tiempo real
/// (streaming en vivo) en vez de un lote al final.
pub const StreamSink = *const fn (
    ctx: ?*anyopaque,
    chunk: []const u8,
    stream: StreamKind,
) void;

pub const ExecutorError = hooks.GateError || command_environment.Error || error{
    OutOfMemory,
    InvalidPath,
    /// T9: sistema sin contencion verificada (no Windows ni Linux): no se ejecuta.
    ExecutionDisabled,
    PathOutsideSandbox,
    ExeNotAllowed,
    /// El nombre está en el allowlist pero NO se pudo fijar a una ruta absoluta de
    /// confianza (no se halló en el PATH, o la resolución no devolvió ruta absoluta).
    /// Fail-closed: sin binario fijado, NO se ejecuta (default-deny).
    ExeNotResolved,
    NetworkOrSpendRequiresApproval,
    UntrustedOriginRequiresApproval,
    SpawnFailed,
    Timeout,
    ProcessDied,
    /// Un hook `pre_command` devolvió un código distinto de cero. Es un veto
    /// del usuario, no un fallo del motor: se informa tal cual.
    BlockedByHook,
    InvalidArgument,
    UnsafeBatchArgument,
    UntrustedBatchChain,
};

/// Función de spawn inyectable para tests. En producción se usa `spawnWin32`.
/// `sink`/`sink_ctx` permiten streaming en vivo: cada trozo leído del pipe
/// ConPTY se pasa al sink además de acumularse para RunResult.
pub const SpawnFn = *const fn (
    allocator: std.mem.Allocator,
    exe: []const u8,
    args: []const []const u8,
    cwd: []const u8,
    timeout_ms: u32,
    max_output_bytes: usize,
    sink: ?StreamSink,
    sink_ctx: ?*anyopaque,
    /// H2: lo que el proceso hijo leera por su entrada estandar. Vacio no es
    /// lo mismo que ausente: vacio significa «hay entrada y se acaba
    /// inmediatamente» (EOF limpio), y es lo que un programa interactivo
    /// necesita para no morirse en el primer `input()`.
    stdin_data: []const u8,
) ExecutorError!RunResult;

/// Ejecuta `exe args` en `cwd` SIEMPRE que pase la política default-deny:
///   1. `exe` está en ALLOWLIST (nombre base, sin separadores).
///   2. `cwd` queda dentro de `policy.workspace_root` (reutiliza sandbox.zig).
///   3. La acción no implica red/gasto (`requires_approval == false`).
/// Luego ejecuta con `timeout_ms` y cap de salida `max_output_bytes`.
/// Si falla la política, devuelve error y NO ejecuta nada.
///
/// SEGURIDAD: el allowlist valida el NOMBRE; el binario real lo FIJA `spawnWin32`
/// resolviendo el nombre a una ruta absoluta del PATH (nunca del cwd/workspace) y
/// pasándola como `lpApplicationName`. Así un `python.exe` plantado en el workspace
/// (donde el agente escribe artefactos) no puede suplantar al intérprete real.
pub fn runGoverned(
    allocator: std.mem.Allocator,
    policy: Policy,
    exe: []const u8,
    args: []const []const u8,
    cwd: []const u8,
    spawn_fn: ?SpawnFn,
    sink: ?StreamSink,
    sink_ctx: ?*anyopaque,
) ExecutorError!RunResult {
    if (exe.len == 0 or cwd.len == 0) return error.InvalidPath;
    if (policy.origin == .untrusted) return error.UntrustedOriginRequiresApproval;
    if (policy.requires_approval) return error.NetworkOrSpendRequiresApproval;

    // Validar exe: solo nombre base, sin separadores ni '..'.
    if (hasPathSeparator(exe) or std.mem.eql(u8, basename(exe), "..")) return error.ExeNotAllowed;
    const base = stripExe(basename(exe));
    if (!isAllowlisted(base)) return error.ExeNotAllowed;

    // Validar cwd: debe estar dentro del workspace/sandbox.
    var sb = try sandbox.Sandbox.init(allocator, policy.workspace_root);
    defer sb.deinit();
    if (!sb.isAllowed(cwd)) return error.PathOutsideSandbox;

    // Hook previo. Se coloca DESPUES de la política (allowlist y sandbox) para
    // que un hook no pueda ser el motivo por el que algo prohibido llegue a
    // ejecutarse, y ANTES del spawn para que pueda impedirlo.
    try hooks.check(allocator, .pre_command, "", exe, cwd);

    const launch_args = try command_policy.launchArgs(allocator, exe, args, .{ .allocator = allocator, .workspace_root = policy.workspace_root, .cwd = cwd });
    defer allocator.free(launch_args);
    var result = if (spawn_fn) |spawn|
        try spawn(allocator, exe, args, cwd, policy.timeout_ms, policy.max_output_bytes, sink, sink_ctx, policy.stdin_data)
    else
        // el spawn REAL pasa el token de cancelación de la orden;
        // el mock de tests conserva su firma y no se toca.
        try spawnWin32CancellableWith(allocator, exe, launch_args, cwd, policy.timeout_ms, policy.max_output_bytes, sink, sink_ctx, policy.stdin_data, policy.is_cancelled_fn, policy.cancelled_ctx, policy.environment, .{ .notify_pid_fn = policy.on_spawn_fn, .notify_pid_ctx = policy.on_spawn_ctx });
    // Spawns que no miden totales (mocks de tests) declaran su len como total;
    // si excede el cap, stdoutTruncated() lo detecta tras takeCapped.
    if (result.stdout_total_bytes == 0) result.stdout_total_bytes = result.stdout.len;
    if (result.stderr_total_bytes == 0) result.stderr_total_bytes = result.stderr.len;
    result.stdout = try takeCapped(allocator, result.stdout, policy.max_output_bytes);
    result.stderr = try takeCapped(allocator, result.stderr, policy.max_output_bytes);
    result.stdout = try normalizaSalida(allocator, result.stdout);
    result.stderr = try normalizaSalida(allocator, result.stderr);

    _ = hooks.run(allocator, .post_command, "", exe, cwd);
    return result;
}

/// Ejecuta un binario VERIFICADOR del propio motor, fijado por ruta absoluta.
///
/// El allowlist de `runGoverned` gobierna lo que el AGENTE puede lanzar: nombres
/// de intérprete resueltos por PATH. El gate de navegador no es eso — es una
/// comprobación del motor, con un binario que el motor elige (el Edge instalado,
/// bajo Program Files, fuera del PATH) y una página que el motor genera. Meter
/// `msedge` en el allowlist le daría al modelo un navegador para lanzar con los
/// argumentos que quisiera; esta puerta no lo hace.
///
/// Sigue siendo default-deny en lo que importa: la ruta debe ser ABSOLUTA y
/// existir (nada de resolución por cwd), el `cwd` debe caer dentro del workspace
/// y el origen no puede ser `.untrusted`. El proceso hereda el mismo job object,
/// límite de memoria, timeout y cap de salida que cualquier otro hijo.
pub fn runVerifierPinned(
    allocator: std.mem.Allocator,
    policy: Policy,
    exe_abs: []const u8,
    args: []const []const u8,
    cwd: []const u8,
) ExecutorError!RunResult {
    if (exe_abs.len == 0 or cwd.len == 0) return error.InvalidPath;
    if (policy.origin == .untrusted) return error.UntrustedOriginRequiresApproval;
    if (!(if (builtin.os.tag == .windows) isAbsoluteWin(exe_abs) else std.fs.path.isAbsolutePosix(exe_abs))) return error.ExeNotResolved;
    if (std.mem.indexOf(u8, exe_abs, "..") != null) return error.ExeNotResolved;

    const exe_z = allocator.dupeZ(u8, exe_abs) catch return error.OutOfMemory;
    defer allocator.free(exe_z);
    if (GetFileAttributesA(exe_z.ptr) == INVALID_FILE_ATTRIBUTES) return error.ExeNotResolved;

    var sb = try sandbox.Sandbox.init(allocator, policy.workspace_root);
    defer sb.deinit();
    if (!sb.isAllowed(cwd)) return error.PathOutsideSandbox;

    const launch_args = try command_policy.launchArgs(allocator, exe_abs, args, .{ .allocator = allocator, .workspace_root = policy.workspace_root, .cwd = cwd });
    defer allocator.free(launch_args);
    var result = try spawnWin32Pinned(
        allocator,
        exe_z,
        launch_args,
        cwd,
        policy.timeout_ms,
        policy.max_output_bytes,
        null,
        null,
        policy.stdin_data,
        JobLimits.browser,
        policy.environment,
        policy.is_cancelled_fn,
        policy.cancelled_ctx,
    );
    result.stdout = try takeCapped(allocator, result.stdout, policy.max_output_bytes);
    result.stderr = try takeCapped(allocator, result.stderr, policy.max_output_bytes);
    result.stdout = try normalizaSalida(allocator, result.stdout);
    result.stderr = try normalizaSalida(allocator, result.stderr);
    return result;
}

/// Lanza `exe args` en `cwd` como proceso INDEPENDIENTE (detached), sin capturar
/// salida ni esperar a que termine. Valida la misma política default-deny que
/// `runGoverned` (allowlist + sandbox + origin). Devuelve el PID del proceso hijo.
/// Uso típico: programas GUI/autocontenidos (tkinter, etc.) que abren su propia
/// ventana y corren indefinidamente.
pub fn runDetached(
    allocator: std.mem.Allocator,
    policy: Policy,
    exe: []const u8,
    args: []const []const u8,
    cwd: []const u8,
) ExecutorError!DetachedResult {
    if (exe.len == 0 or cwd.len == 0) return error.InvalidPath;
    if (policy.origin == .untrusted) return error.UntrustedOriginRequiresApproval;
    if (policy.requires_approval) return error.NetworkOrSpendRequiresApproval;

    if (hasPathSeparator(exe) or std.mem.eql(u8, basename(exe), "..")) return error.ExeNotAllowed;
    const base = stripExe(basename(exe));
    if (!isAllowlisted(base)) return error.ExeNotAllowed;

    var sb = try sandbox.Sandbox.init(allocator, policy.workspace_root);
    defer sb.deinit();
    if (!sb.isAllowed(cwd)) return error.PathOutsideSandbox;

    const launch_args = try command_policy.launchArgs(allocator, exe, args, .{ .allocator = allocator, .workspace_root = policy.workspace_root, .cwd = cwd });
    defer allocator.free(launch_args);
    return spawnDetached(allocator, exe, launch_args, cwd);
}

/// Trunca `s` a `cap` bytes sin exceder el límite. Si ya cabe, devuelve el mismo
/// slice (el llamador sigue siendo responsable de liberarlo).
// ── la salida de un comando llega a la cabina como texto ──────────
//
// Por tuberías, cmd.exe y PowerShell escriben en la página OEM de la consola
// (850 en un Windows en español), no en UTF-8. Esos bytes llegaban tal cual a
// los eventos, y el escritor JSON de Zig serializa una cadena que no es UTF-8
// como una LISTA DE NÚMEROS: el error «El término 'x' no se reconoce…» de
// PowerShell quedaba en runtime.db como [109,111,99,107,…] y la cabina no
// tenía texto que enseñar. Visto el 22-09 reproduciendo.
//
// La misma conversión que hace el host para la terminal por tuberías:
// solo cuando los bytes NO son UTF-8 válido; lo que ya es UTF-8 no se toca.

extern "kernel32" fn MultiByteToWideChar(CodePage: u32, dwFlags: u32, lpMultiByteStr: [*]const u8, cbMultiByte: c_int, lpWideCharStr: ?[*]u16, cchWideChar: c_int) callconv(.winapi) c_int;
extern "kernel32" fn WideCharToMultiByte(CodePage: u32, dwFlags: u32, lpWideCharStr: [*]const u16, cchWideChar: c_int, lpMultiByteStr: ?[*]u8, cbMultiByte: c_int, lpDefaultChar: ?*const u8, lpUsedDefaultChar: ?*c_int) callconv(.winapi) c_int;
extern "kernel32" fn GetOEMCP() callconv(.winapi) u32;
const CP_OEMCP: u32 = 1;
const CP_UTF8: u32 = 65001;

/// Convierte bytes de la página OEM a UTF-8. Devuelve memoria nueva.
pub fn oemAUtf8(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
    // T9: fuera de Windows no hay pagina OEM; la salida que no es UTF-8 se
    // muestra con U+FFFD en vez de llegar como lista de numeros.
    if (builtin.os.tag != .windows) return replaceInvalidUtf8(allocator, bytes);
    if (bytes.len == 0) return allocator.dupe(u8, "");
    if (bytes.len > std.math.maxInt(c_int)) return error.OutOfMemory;
    const n_in: c_int = @intCast(bytes.len);
    const n_w = MultiByteToWideChar(CP_OEMCP, 0, bytes.ptr, n_in, null, 0);
    if (n_w <= 0) return error.InvalidEncoding;
    const wide = try allocator.alloc(u16, @intCast(n_w));
    defer allocator.free(wide);
    _ = MultiByteToWideChar(CP_OEMCP, 0, bytes.ptr, n_in, wide.ptr, n_w);
    const n_u = WideCharToMultiByte(CP_UTF8, 0, wide.ptr, n_w, null, 0, null, null);
    if (n_u <= 0) return error.InvalidEncoding;
    const out = try allocator.alloc(u8, @intCast(n_u));
    _ = WideCharToMultiByte(CP_UTF8, 0, wide.ptr, n_w, out.ptr, n_u, null, null);
    return out;
}

/// Si `s` (propiedad del llamador) no es UTF-8, la sustituye por su
/// conversión desde la página OEM y libera la original.
fn normalizaSalida(allocator: std.mem.Allocator, s: []const u8) ![]const u8 {
    if (std.unicode.utf8ValidateSlice(s)) return s;
    const u = oemAUtf8(allocator, s) catch return s;
    allocator.free(s);
    return u;
}

/// ¿El trozo es UTF-8 válido salvo una secuencia multibyte cortada al final?
/// Es lo normal al leer una tubería por bloques: el resto llega en el
/// siguiente trozo, y convertirlo como OEM lo estropearía.
fn utf8ConColaCortada(slice: []const u8) bool {
    var i: usize = slice.len;
    var atras: usize = 0;
    while (i > 0 and atras < 3) {
        i -= 1;
        atras += 1;
        const c = slice[i];
        if (c & 0xC0 == 0x80) continue; // byte de continuación
        if (c < 0x80) return false; // ASCII: no hay secuencia abierta
        const largo: usize = if (c & 0xE0 == 0xC0) 2 else if (c & 0xF0 == 0xE0) 3 else if (c & 0xF8 == 0xF0) 4 else return false;
        return slice.len - i < largo and std.unicode.utf8ValidateSlice(slice[0..i]);
    }
    return false;
}

fn takeCapped(allocator: std.mem.Allocator, s: []const u8, cap: usize) ![]const u8 {
    if (s.len <= cap) return s;
    const dup = try allocator.dupe(u8, s[0..cap]);
    allocator.free(s);
    return dup;
}

fn hasPathSeparator(s: []const u8) bool {
    for (s) |c| if (c == '/' or c == '\\' or c == ':') return true;
    return false;
}

pub fn basename(s: []const u8) []const u8 {
    var last: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '/' or s[i] == '\\') last = i + 1;
    }
    return s[last..];
}

pub fn stripExe(s: []const u8) []const u8 {
    for ([_][]const u8{ ".exe", ".cmd", ".bat", ".com" }) |ext| {
        if (std.ascii.endsWithIgnoreCase(s, ext)) return s[0 .. s.len - ext.len];
    }
    return s;
}

pub fn isAllowlisted(name: []const u8) bool {
    for (ALLOWLIST) |a| if (std.ascii.eqlIgnoreCase(a, name)) return true;
    return false;
}

// ── Win32 spawn directo ────────────────────────────────────────────────

const windows = std.os.windows;
const Sleep = @import("platform.zig").sleep;

extern "kernel32" fn CreateProcessW(
    lpApplicationName: ?[*:0]const u16,
    lpCommandLine: [*:0]u16,
    lpProcessAttributes: ?*anyopaque,
    lpThreadAttributes: ?*anyopaque,
    bInheritHandles: c_int,
    dwCreationFlags: u32,
    lpEnvironment: ?*anyopaque,
    lpCurrentDirectory: ?[*:0]const u16,
    lpStartupInfo: *windows.STARTUPINFOW,
    lpProcessInformation: *PROCESS_INFORMATION,
) callconv(.winapi) c_int;

extern "kernel32" fn CreatePipe(hReadPipe: *windows.HANDLE, hWritePipe: *windows.HANDLE, lpPipeAttributes: ?*SECURITY_ATTRIBUTES, nSize: u32) c_int;
extern "kernel32" fn SetNamedPipeHandleState(hNamedPipe: windows.HANDLE, lpMode: ?*u32, lpMaxCollectionCount: ?*u32, lpCollectDataTimeout: ?*u32) c_int;
const PIPE_NOWAIT: u32 = 0x00000001;
extern "kernel32" fn SetHandleInformation(hObject: windows.HANDLE, dwMask: u32, dwFlags: u32) c_int;
const ReadFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn ReadFile(hFile: windows.HANDLE, lpBuffer: [*]u8, n: u32, read: *u32, ov: ?*anyopaque) c_int;
}.ReadFile else @import("providers").posix_files.ReadFile;
const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(hObject: windows.HANDLE) c_int;
}.CloseHandle else @import("providers").posix_files.CloseHandle;
extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: u32) u32;
extern "kernel32" fn GetExitCodeProcess(hProcess: windows.HANDLE, lpExitCode: *u32) c_int;
extern "kernel32" fn TerminateProcess(hProcess: windows.HANDLE, uExitCode: u32) c_int;
extern "kernel32" fn PeekNamedPipe(hNamedPipe: windows.HANDLE, lpBuffer: ?*anyopaque, nBufferSize: u32, lpBytesRead: ?*u32, lpTotalBytesAvail: ?*u32, lpBytesLeftThisMessage: ?*u32) c_int;
const GetTickCount64 = @import("platform.zig").ticks;
const CreateDirectoryA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateDirectoryA(lpPathName: [*:0]const u8, lpSecurityAttributes: ?*anyopaque) callconv(.winapi) c_int;
}.CreateDirectoryA else @import("providers").posix_files.CreateDirectoryA;
const RemoveDirectoryA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn RemoveDirectoryA(lpPathName: [*:0]const u8) callconv(.winapi) c_int;
}.RemoveDirectoryA else @import("providers").posix_files.RemoveDirectoryA;
const GetTempPathA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetTempPathA(nBufferLength: u32, lpBuffer: [*]u8) callconv(.winapi) u32;
}.GetTempPathA else @import("platform.zig").tempPath;
extern "kernel32" fn CreateJobObjectA(lpJobAttributes: ?*SECURITY_ATTRIBUTES, lpName: ?[*:0]const u8) windows.HANDLE;
extern "kernel32" fn SetInformationJobObject(hJob: windows.HANDLE, JobObjectInfoClass: c_int, lpJobObjectInfo: *anyopaque, cbJobObjectInfoLength: u32) c_int;
extern "kernel32" fn AssignProcessToJobObject(hJob: windows.HANDLE, hProcess: windows.HANDLE) c_int;
extern "kernel32" fn ResumeThread(hThread: windows.HANDLE) u32;
extern "kernel32" fn SearchPathA(lpPath: ?[*:0]const u8, lpFileName: [*:0]const u8, lpExtension: ?[*:0]const u8, nBufferLength: u32, lpBuffer: [*]u8, lpFilePart: ?*?[*:0]u8) u32;
const GetEnvironmentVariableA = @import("platform.zig").env;
const GetFileAttributesA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileAttributesA(lpFileName: [*:0]const u8) callconv(.winapi) u32;
}.GetFileAttributesA else @import("providers").posix_files.GetFileAttributesA;
const INVALID_FILE_ATTRIBUTES: u32 = 0xFFFF_FFFF;
const SetEnvironmentVariableA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn SetEnvironmentVariableA(lpName: [*:0]const u8, lpValue: ?[*:0]const u8) c_int;
}.SetEnvironmentVariableA else @import("providers").posix_files.SetEnvironmentVariableA;
extern "kernel32" fn SetSearchPathMode(Flags: u32) c_int;

// ── ConPTY (Windows 10 1809+) ──────────────────────────────────────────
// CreatePseudoConsole permite ejecutar el hijo bajo una pseudo-consola:
// isatty()=true ⇒ Python/C/Node pasan a line-buffering automáticamente,
// la salida fluye en vivo SIN depender de -u ni flush explícito.

const COORD = extern struct {
    X: i16,
    Y: i16,
};

/// Handle to pseudo console (opaque pointer).
const HPCON = ?*anyopaque;

extern "kernel32" fn CreatePseudoConsole(
    size: u32, // COORD empaquetado (X en 16 bits bajos, Y en altos) — ABI-seguro
    hInput: windows.HANDLE,
    hOutput: windows.HANDLE,
    dwFlags: u32,
    phPC: *HPCON,
) i32; // HRESULT: S_OK = 0

extern "kernel32" fn ClosePseudoConsole(hPC: HPCON) void;

extern "kernel32" fn InitializeProcThreadAttributeList(
    lpAttributeList: ?*anyopaque,
    dwAttributeCount: u32,
    dwFlags: u32,
    lpSize: *usize,
) c_int;

extern "kernel32" fn UpdateProcThreadAttribute(
    lpAttributeList: *anyopaque,
    dwFlags: u32,
    Attribute: usize,
    lpValue: *anyopaque,
    cbSize: usize,
    lpPreviousValue: ?*anyopaque,
    lpReturnSize: ?*usize,
) c_int;

extern "kernel32" fn DeleteProcThreadAttributeList(lpAttributeList: *anyopaque) void;

const STARTUPINFOA = extern struct {
    cb: u32,
    lpReserved: ?[*:0]u8 = null,
    lpDesktop: ?[*:0]u8 = null,
    lpTitle: ?[*:0]u8 = null,
    dwX: u32 = 0,
    dwY: u32 = 0,
    dwXSize: u32 = 0,
    dwYSize: u32 = 0,
    dwXCountChars: u32 = 0,
    dwYCountChars: u32 = 0,
    dwFillAttribute: u32 = 0,
    dwFlags: u32 = 0,
    wShowWindow: u16 = 0,
    cbReserved2: u16 = 0,
    lpReserved2: ?*anyopaque = null,
    hStdInput: windows.HANDLE = windows.INVALID_HANDLE_VALUE,
    hStdOutput: windows.HANDLE = windows.INVALID_HANDLE_VALUE,
    hStdError: windows.HANDLE = windows.INVALID_HANDLE_VALUE,
};

const PROCESS_INFORMATION = extern struct {
    hProcess: windows.HANDLE,
    hThread: windows.HANDLE,
    dwProcessId: u32,
    dwThreadId: u32,
};

/// STARTUPINFOEXA — versión extendida de STARTUPINFOA para pasar la lista
/// de atributos de hilo (que contiene el handle de ConPTY).
const STARTUPINFOEXA = extern struct {
    StartupInfo: STARTUPINFOA,
    lpAttributeList: ?*anyopaque = null,
};

const SECURITY_ATTRIBUTES = extern struct {
    nLength: u32,
    lpSecurityDescriptor: ?*anyopaque,
    bInheritHandle: c_int,
};

const HANDLE_FLAG_INHERIT: u32 = 0x00000001;
const STARTF_USESTDHANDLES: u32 = 0x00000100;
const CREATE_NO_WINDOW: u32 = 0x08000000;
const CREATE_SUSPENDED: u32 = 0x00000004;
/// Proceso detached: el hijo no hereda la consola del padre. Para GUI apps.
const DETACHED_PROCESS: u32 = 0x00000008;
/// Crea el proceso en un nuevo grupo (permite Ctrl+Break isolation).
const CREATE_NEW_PROCESS_GROUP: u32 = 0x00000200;
/// Indica a CreateProcess que lpStartupInfo apunta a STARTUPINFOEX (no STARTUPINFO).
const EXTENDED_STARTUPINFO_PRESENT: u32 = 0x00080000;
/// Atributo de hilo para asociar el proceso a una pseudo-consola (ConPTY).
const PROC_THREAD_ATTRIBUTE_PSEUDOCONSOLE: usize = 0x00020016;
const WAIT_OBJECT_0: u32 = 0;
const WAIT_TIMEOUT: u32 = 0x00000102;
const INVALID_HANDLE_VALUE: windows.HANDLE = @ptrFromInt(~@as(usize, 0));

const JobObjectExtendedLimitInformation: c_int = 9;
const JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE: u32 = 0x00002000;
const JOB_OBJECT_LIMIT_ACTIVE_PROCESS: u32 = 0x00000008;
const JOB_OBJECT_LIMIT_JOB_MEMORY: u32 = 0x00000200;
const JOB_OBJECT_LIMIT_PROCESS_MEMORY: u32 = 0x00000100;

// SafeProcessSearchMode: saca el directorio actual del orden de búsqueda por defecto
// (defensa en profundidad; nuestra resolución ya pasa un lpPath explícito sin cwd).
const BASE_SEARCH_PATH_ENABLE_SAFE_SEARCHMODE: u32 = 0x00000001;
const BASE_SEARCH_PATH_PERMANENT: u32 = 0x00008000;

const LARGE_INTEGER = extern struct {
    LowPart: u32,
    HighPart: i32,
};

const JOBOBJECT_BASIC_LIMIT_INFORMATION = extern struct {
    PerProcessUserTimeLimit: LARGE_INTEGER = .{ .LowPart = 0, .HighPart = 0 },
    PerJobUserTimeLimit: LARGE_INTEGER = .{ .LowPart = 0, .HighPart = 0 },
    LimitFlags: u32 = 0,
    MinimumWorkingSetSize: usize = 0,
    MaximumWorkingSetSize: usize = 0,
    ActiveProcessLimit: u32 = 0,
    Affinity: usize = 0,
    PriorityClass: u32 = 0,
    SchedulingClass: u32 = 0,
};

const JOBOBJECT_EXTENDED_LIMIT_INFORMATION = extern struct {
    BasicLimitInformation: JOBOBJECT_BASIC_LIMIT_INFORMATION = .{},
    IoInfo: IO_COUNTERS = .{},
    ProcessMemoryLimit: usize = 0,
    JobMemoryLimit: usize = 0,
    PeakProcessMemoryUsed: usize = 0,
    PeakJobMemoryUsed: usize = 0,
};

const IO_COUNTERS = extern struct {
    ReadOperationCount: u64 = 0,
    WriteOperationCount: u64 = 0,
    OtherOperationCount: u64 = 0,
    ReadTransferCount: u64 = 0,
    WriteTransferCount: u64 = 0,
    OtherTransferCount: u64 = 0,
};

/// Lee una variable de entorno como slice null-terminado (owned). Error si está ausente.
fn getEnvAlloc(allocator: std.mem.Allocator, name: [:0]const u8) ![:0]u8 {
    // Sonda de tamaño: con nSize=0 devuelve los bytes requeridos INCLUYENDO el null.
    const needed = GetEnvironmentVariableA(name.ptr, null, 0);
    if (needed == 0) return error.EnvNotFound;
    const buf = try allocator.allocSentinel(u8, needed - 1, 0);
    errdefer allocator.free(buf);
    const got = GetEnvironmentVariableA(name.ptr, buf.ptr, needed);
    if (got == 0 or got >= needed) return error.EnvNotFound;
    return buf;
}

/// `true` si `p` es una ruta ABSOLUTA de Windows: unidad "X:\..." o UNC "\\host\...".
pub fn isAbsoluteWin(p: []const u8) bool {
    if (p.len >= 2 and p[1] == ':') return true;
    if (p.len >= 2 and (p[0] == '\\' or p[0] == '/') and (p[1] == '\\' or p[1] == '/')) return true;
    return false;
}

/// Resuelve `base` (nombre allowlistado, SIN extensión) a una RUTA ABSOLUTA verificada,
/// buscando ÚNICAMENTE en el PATH del proceso. Pasar el PATH explícito como `lpPath` a
/// SearchPathA evita que el SO añada el directorio actual (cwd/workspace) a la búsqueda:
/// ahí estaba el bypass —un `python.exe` plantado en el workspace donde el agente escribe
/// artefactos ganaba al intérprete real—. La ruta resuelta se pasa como `lpApplicationName`
/// a CreateProcessW (binario FIJADO), de modo que el SO ya no resuelve por `lpCommandLine`.
/// Fail-closed: si no se puede fijar una ruta absoluta, devuelve `ExeNotResolved` y NO se
/// ejecuta nada (default-deny). El llamador libera el slice devuelto.
fn resolveAllowedExe(allocator: std.mem.Allocator, base: []const u8) ExecutorError![:0]u8 {
    return resolveAllowedExeExt(allocator, base, ".exe");
}

/// Igual que `resolveAllowedExe` pero con la extensión a buscar explícita.
/// En un Node stock de Windows `npm`/`npx` existen SOLO como `npm.cmd` — sin
/// la extensión alternativa esos nombres del allowlist no resolvían nunca.
/// E5.08: pública — el registro de agentes externos resuelve los shims npm
/// (`codex.cmd`, `gemini.cmd`, `opencode.cmd`) por el mismo criterio.
pub fn resolveAllowedExeExt(allocator: std.mem.Allocator, base: []const u8, ext: [:0]const u8) ExecutorError![:0]u8 {
    if (builtin.os.tag != .windows) {
        // Sin extensiones en POSIX: solo la primera pasada (.exe) busca.
        if (!std.mem.eql(u8, ext, ".exe")) return error.ExeNotResolved;
        return resolvePosixExe(allocator, base);
    }
    // Defensa en profundidad: saca el cwd del orden de búsqueda por defecto del proceso.
    _ = SetSearchPathMode(BASE_SEARCH_PATH_ENABLE_SAFE_SEARCHMODE | BASE_SEARCH_PATH_PERMANENT);

    const name_z = allocator.dupeZ(u8, base) catch return error.OutOfMemory;
    defer allocator.free(name_z);

    // PATH del proceso. EXPLÍCITO ⇒ SearchPathA NO incluye el directorio actual.
    const path_env = getEnvAlloc(allocator, "PATH") catch return error.ExeNotResolved;
    defer allocator.free(path_env);

    var buf: [32768]u8 = undefined;
    const n = SearchPathA(path_env.ptr, name_z.ptr, ext.ptr, buf.len, &buf, null);
    if (n == 0 or n >= buf.len) return error.ExeNotResolved;
    const resolved = buf[0..n];

    // SearchPathA con lpPath explícito devuelve una ruta absoluta; lo exigimos como
    // invariante de seguridad: jamás pasar a CreateProcessW algo relativo (resoluble vía cwd).
    if (!isAbsoluteWin(resolved)) return error.ExeNotResolved;

    return allocator.dupeZ(u8, resolved) catch return error.OutOfMemory;
}

/// cmd.exe del directorio del SO: nunca PATH, COMSPEC ni SystemRoot mutable.
pub fn pinnedCmdExe(allocator: std.mem.Allocator) ExecutorError![:0]u8 {
    return @import("windows_cmd.zig").systemCmdExe(allocator);
}

pub fn isBatchShim(path: []const u8) bool {
    return std.ascii.endsWithIgnoreCase(path, ".cmd") or std.ascii.endsWithIgnoreCase(path, ".bat");
}

fn pinnedCommandLine(allocator: std.mem.Allocator, application: []const u8, exe_abs: []const u8, args: []const []const u8) ExecutorError![:0]u8 {
    if (isBatchShim(exe_abs)) return @import("windows_cmd.zig").buildCommandLine(allocator, application, exe_abs, args);
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    try appendArg(&out, allocator, exe_abs);
    for (args) |arg| {
        try out.append(allocator, ' ');
        try appendArg(&out, allocator, arg);
    }
    return allocator.dupeZ(u8, out.items);
}

/// Mantener este resultado vivo hasta que termine el proceso: fija shim,
/// node y JS por handles y comprueba la misma cadena de confianza del CLI.
pub const BatchLaunch = @import("shim_launch.zig").Launch;
pub fn prepareBatchLaunch(a: std.mem.Allocator, path: []const u8) !BatchLaunch {
    return @import("shim_launch.zig").prepare(a, path, resolveNodeForShim);
}
fn resolveNodeForShim(a: std.mem.Allocator, name: []const u8) error{ OutOfMemory, ExeNotResolved }![:0]u8 {
    return resolveAllowedExe(a, name) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.ExeNotResolved;
}

fn resolveLaunchExe(allocator: std.mem.Allocator, exe: []const u8) ExecutorError![:0]u8 {
    const base = stripExe(basename(exe));
    // Mismo orden para captura/detached; resolver un shim NO concede confianza.
    for ([_][:0]const u8{ ".exe", ".cmd", ".bat" }) |ext| {
        const resolved = resolveAllowedExeExt(allocator, base, ext) catch |e| {
            if (e == error.ExeNotResolved) continue;
            return e;
        };
        return resolved;
    }
    return error.ExeNotResolved;
}

fn spawnWin32(
    allocator: std.mem.Allocator,
    exe: []const u8,
    args: []const []const u8,
    cwd: []const u8,
    timeout_ms: u32,
    max_output_bytes: usize,
    sink: ?StreamSink,
    sink_ctx: ?*anyopaque,
    stdin_data: []const u8,
) ExecutorError!RunResult {
    return spawnWin32Cancellable(allocator, exe, args, cwd, timeout_ms, max_output_bytes, sink, sink_ctx, stdin_data, null, null);
}

/// Resultado de una cancelación de ORDEN sin hijo lanzado (o tras matarlo):
/// mismo cierre que el bucle de espera — exit 130, marcado `cancelled`, sin
/// salida.
fn cancelledRunResult(allocator: std.mem.Allocator) ExecutorError!RunResult {
    return .{
        .exit_code = 130, // convención POSIX: 128 + SIGINT(2)
        .stdout = try allocator.dupe(u8, ""),
        .stderr = try allocator.dupe(u8, ""),
        .cancelled = true,
    };
}

/// Igual que `spawnWin32` pero con el token de cancelación de la ORDEN: el
/// bucle de espera comprueba `is_cancelled_fn` y, en cuanto devuelve true,
/// termina el hijo y su árbol con el mismo cierre que el timeout — pero
/// marcado `cancelled` y sin esperar al vencimiento.
fn spawnWin32Cancellable(
    allocator: std.mem.Allocator,
    exe: []const u8,
    args: []const []const u8,
    cwd: []const u8,
    timeout_ms: u32,
    max_output_bytes: usize,
    sink: ?StreamSink,
    sink_ctx: ?*anyopaque,
    stdin_data: []const u8,
    is_cancelled_fn: ?*const fn (?*anyopaque) bool,
    cancelled_ctx: ?*anyopaque,
) ExecutorError!RunResult {
    return spawnWin32CancellableWith(allocator, exe, args, cwd, timeout_ms, max_output_bytes, sink, sink_ctx, stdin_data, is_cancelled_fn, cancelled_ctx, null, .{});
}

/// T12 L2: como `spawnWin32Cancellable`, con el entorno de `Policy.environment`
/// (filtrado igual por `command_environment.build`) y el aviso del PID.
fn spawnWin32CancellableWith(
    allocator: std.mem.Allocator,
    exe: []const u8,
    args: []const []const u8,
    cwd: []const u8,
    timeout_ms: u32,
    max_output_bytes: usize,
    sink: ?StreamSink,
    sink_ctx: ?*anyopaque,
    stdin_data: []const u8,
    is_cancelled_fn: ?*const fn (?*anyopaque) bool,
    cancelled_ctx: ?*anyopaque,
    environment: ?[:0]const u16,
    limits: JobLimits,
) ExecutorError!RunResult {
    // si la ORDEN ya está cancelada en el momento del lanzamiento,
    // no se intenta siquiera resolver el binario ni construir la línea de
    // comandos — «no arranca» incluye no tocar el PATH ni el registro. La
    // comprobación se repite justo antes de CreateProcess (spawnWin32Pinned)
    // para cubrir la carrera hasta el arranque real.
    if (is_cancelled_fn != null and is_cancelled_fn.?(cancelled_ctx)) {
        return cancelledRunResult(allocator);
    }
    // Fijar el binario a una ruta absoluta de confianza ANTES de construir la línea de
    // comandos. Si no se puede resolver en el PATH, fail-closed (no se ejecuta nada).
    const exe_abs = try resolveLaunchExe(allocator, exe);
    defer allocator.free(exe_abs);

    if (isBatchShim(exe_abs)) {
        var launch = prepareBatchLaunch(allocator, exe_abs) catch |e| return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            else => error.UntrustedBatchChain,
        };
        defer launch.deinit(allocator);
        const all_args = try allocator.alloc([]const u8, launch.prefix.len + args.len);
        defer allocator.free(all_args);
        @memcpy(all_args[0..launch.prefix.len], launch.prefix);
        @memcpy(all_args[launch.prefix.len..], args);
        return spawnWin32Pinned(allocator, launch.exe, all_args, cwd, timeout_ms, max_output_bytes, sink, sink_ctx, stdin_data, limits, environment, is_cancelled_fn, cancelled_ctx);
    }
    return spawnWin32Pinned(allocator, exe_abs, args, cwd, timeout_ms, max_output_bytes, sink, sink_ctx, stdin_data, limits, environment, is_cancelled_fn, cancelled_ctx);
}

/// Igual que `spawnWin32` pero recibiendo el binario YA FIJADO a una ruta absoluta.
///
/// Existe porque no todo binario que el motor necesita ejecutar es un intérprete
/// del allowlist resoluble por PATH. El gate de navegador (`browser_gate.zig`)
/// lanza el Edge instalado, cuya ruta canónica está bajo Program Files y NO está
/// en el PATH. Antes de esta separación la única forma de lanzarlo habría sido
/// duplicar las ~200 líneas de Win32 de abajo, y dos copias del spawn con job
/// object, pipes y timeout es exactamente cómo se acaba con una que sí contiene
/// el proceso hijo y otra que no.
///
/// `exe_abs` DEBE ser absoluto y verificado por el llamador: aquí ya no se
/// consulta el allowlist ni el PATH.
fn spawnWin32Pinned(
    allocator: std.mem.Allocator,
    exe_abs: [:0]const u8,
    args: []const []const u8,
    cwd: []const u8,
    timeout_ms: u32,
    max_output_bytes: usize,
    sink: ?StreamSink,
    sink_ctx: ?*anyopaque,
    stdin_data: []const u8,
    limits: JobLimits,
    environment: ?[:0]const u16,
    is_cancelled_fn: ?*const fn (?*anyopaque) bool,
    cancelled_ctx: ?*anyopaque,
) ExecutorError!RunResult {
    if (builtin.os.tag != .windows) {
        if (builtin.os.tag != .linux) return error.ExecutionDisabled;
        if (is_cancelled_fn != null and is_cancelled_fn.?(cancelled_ctx)) return cancelledRunResult(allocator);
        return spawnLinux(allocator, exe_abs, args, cwd, timeout_ms, max_output_bytes, sink, sink_ctx, stdin_data, limits, environment, is_cancelled_fn, cancelled_ctx, false);
    }
    const env_block = try command_environment.build(allocator, environment);
    defer allocator.free(env_block);
    const batch = isBatchShim(exe_abs);
    const application = if (batch) try pinnedCmdExe(allocator) else try allocator.dupeZ(u8, exe_abs);
    defer allocator.free(application);
    const cmd_line = try pinnedCommandLine(allocator, application, exe_abs, args);
    defer allocator.free(cmd_line);
    // W en TODOS los caminos: no perder Unicode ni depender de la página ANSI.
    const exe_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, application) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.InvalidPath;
    defer allocator.free(exe_w);
    const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, cmd_line) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.InvalidPath;
    defer allocator.free(cmd_w);
    const cwd_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, cwd) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.InvalidPath;
    defer allocator.free(cwd_w);

    // Job Object: contiene el árbol de procesos y garantiza limpieza al cerrar.
    // EXEC#2 (Nemotron): FAIL-CLOSED — si no se puede crear/configurar el job, NO se
    // ejecuta sin gobernanza (antes corría sin límites ni kill-on-close). Política
    // default-deny: sin contención, no hay ejecución.
    const h_job = createJobObject(limits) orelse return error.SpawnFailed;

    // última comprobación justo antes de crear los pipes y el
    // proceso — la cancelación pudo marcarse durante el trabajo previo. Si la
    // ORDEN ya está cancelada, no se arranca nada.
    if (is_cancelled_fn != null and is_cancelled_fn.?(cancelled_ctx)) {
        _ = CloseHandle(h_job);
        return cancelledRunResult(allocator);
    }

    // Captura por pipes (stdout + stderr) con streaming en vivo via `sink`. Para que la
    // salida no quede atrapada en buffer de bloque, se fuerza PYTHONUNBUFFERED=1 en el
    // entorno (cubre Python; Node escribe a pipe de forma sincrona). ConPTY (general, para
    // cualquier lenguaje) quedo como mejora futura: su scaffolding sigue declarado arriba
    // pero sin usar (ver PROMPT-CIERRE §2). El attach hijo->pty no se logro en este entorno.
    var sa: SECURITY_ATTRIBUTES = .{
        .nLength = @sizeOf(SECURITY_ATTRIBUTES),
        .lpSecurityDescriptor = null,
        .bInheritHandle = 1,
    };
    var h_stdout_r: windows.HANDLE = INVALID_HANDLE_VALUE;
    var h_stdout_w: windows.HANDLE = INVALID_HANDLE_VALUE;
    var h_stderr_r: windows.HANDLE = INVALID_HANDLE_VALUE;
    var h_stderr_w: windows.HANDLE = INVALID_HANDLE_VALUE;
    if (CreatePipe(&h_stdout_r, &h_stdout_w, &sa, 0) == 0) {
        _ = CloseHandle(h_job);
        return error.SpawnFailed;
    }
    if (CreatePipe(&h_stderr_r, &h_stderr_w, &sa, 0) == 0) {
        _ = CloseHandle(h_stdout_r);
        _ = CloseHandle(h_stdout_w);
        _ = CloseHandle(h_job);
        return error.SpawnFailed;
    }
    // Solo el extremo de ESCRITURA se hereda; los de lectura NO (evita fuga de handle).
    _ = SetHandleInformation(h_stdout_r, HANDLE_FLAG_INHERIT, 0);
    _ = SetHandleInformation(h_stderr_r, HANDLE_FLAG_INHERIT, 0);

    // H2 — entrada estandar de verdad.
    //
    // Antes aqui iba `INVALID_HANDLE_VALUE`, que no es «entrada vacia» sino
    // «no hay entrada»: el primer `input()` de cualquier programa moria con
    // EOFError sin llegar a imprimir nada. Ahora hay una tuberia real: se
    // escribe `stdin_data` (aunque sea vacio) y se CIERRA el extremo de
    // escritura, con lo que el hijo ve un EOF limpio y puede manejarlo.
    //
    // Fail-open a proposito: si la tuberia no se puede crear se sigue con el
    // handle invalido de siempre. Quedarse sin ejecutar por no poder dar
    // stdin seria peor que ejecutar como antes.
    var h_stdin_r: windows.HANDLE = INVALID_HANDLE_VALUE;
    var h_stdin_w: windows.HANDLE = INVALID_HANDLE_VALUE;
    if (CreatePipe(&h_stdin_r, &h_stdin_w, &sa, 0) != 0) {
        // Del lado del hijo se hereda la LECTURA; la escritura es nuestra.
        _ = SetHandleInformation(h_stdin_w, HANDLE_FLAG_INHERIT, 0);
    } else {
        h_stdin_r = INVALID_HANDLE_VALUE;
        h_stdin_w = INVALID_HANDLE_VALUE;
    }

    var si = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    si.dwFlags = STARTF_USESTDHANDLES;
    si.hStdOutput = h_stdout_w;
    si.hStdError = h_stderr_w;
    si.hStdInput = h_stdin_r;
    var pi: PROCESS_INFORMATION = undefined;
    const flags = CREATE_NO_WINDOW | CREATE_SUSPENDED | @as(u32, 0x400);
    const env_ptr: *anyopaque = @ptrCast(env_block.ptr);
    const ok = CreateProcessW(exe_w.ptr, cmd_w.ptr, null, null, 1, flags, env_ptr, cwd_w.ptr, &si, &pi);
    _ = CloseHandle(h_stdout_w);
    _ = CloseHandle(h_stderr_w);
    // H2: el extremo de lectura ya lo tiene el hijo; en este proceso sobra.
    if (h_stdin_r != INVALID_HANDLE_VALUE) _ = CloseHandle(h_stdin_r);
    if (ok == 0) {
        if (h_stdin_w != INVALID_HANDLE_VALUE) _ = CloseHandle(h_stdin_w);
        _ = CloseHandle(h_stdout_r);
        _ = CloseHandle(h_stderr_r);
        _ = CloseHandle(h_job);
        return error.SpawnFailed;
    }

    // Asignar al job ANTES de reanudar. Si falla, terminar el proceso suspendido
    // (fail-closed: no se reanuda un proceso que no quedó contenido en el job).
    if (AssignProcessToJobObject(h_job, pi.hProcess) == 0) {
        _ = TerminateProcess(pi.hProcess, 1);
        _ = CloseHandle(pi.hThread);
        _ = CloseHandle(pi.hProcess);
        if (h_stdin_w != INVALID_HANDLE_VALUE) _ = CloseHandle(h_stdin_w);
        _ = CloseHandle(h_stdout_r);
        _ = CloseHandle(h_stderr_r);
        _ = CloseHandle(h_job);
        return error.SpawnFailed;
    }
    _ = ResumeThread(pi.hThread);
    _ = CloseHandle(pi.hThread);
    if (limits.notify_pid_fn) |notify| notify(limits.notify_pid_ctx, pi.dwProcessId);

    // H2: alimentar la entrada y cerrarla. El cierre es lo que produce el EOF;
    // sin el, un programa que lee hasta fin de fichero se quedaria esperando
    // para siempre y solo lo salvaria el timeout.
    //
    // Va DESPUES de reanudar el hilo a proposito: el proceso nace suspendido, y
    // una entrada mas grande que el buffer de la tuberia (4 KB) bloquearia el
    // WriteFile esperando a un lector que aun no corre. Interbloqueo perfecto.
    if (h_stdin_w != INVALID_HANDLE_VALUE) {
        if (stdin_data.len > 0) {
            var escrito: u32 = 0;
            var restante = stdin_data;
            while (restante.len > 0) {
                if (WriteFile(h_stdin_w, restante.ptr, @intCast(restante.len), &escrito, null) == 0) break;
                if (escrito == 0) break;
                restante = restante[escrito..];
            }
        }
        _ = CloseHandle(h_stdin_w);
    }

    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);
    var err = std.ArrayList(u8).empty;
    errdefer err.deinit(allocator);
    var out_total: usize = 0;
    var err_total: usize = 0;

    const start = GetTickCount64();
    var done = false;
    while (!done) {
        // E5.55: a short wait lets blocked pipe writers resume promptly.
        // A 100 ms wait between empty-pipe reads throttled Codex's 601 KB
        // catalog until the discovery deadline expired. Timeout remains bounded.
        const rc = WaitForSingleObject(pi.hProcess, 1);
        if (rc == WAIT_OBJECT_0) {
            done = true;
        } else if (GetTickCount64() - start > timeout_ms) {
            // EXEC-SHOW: el proceso no terminó dentro del timeout (reloj/servidor continuo).
            // Se termina pero se CONSERVA la salida capturada y se marca timed_out, para que
            // el usuario vea lo que el programa imprimió en pantalla.
            _ = TerminateProcess(pi.hProcess, 1);
            _ = WaitForSingleObject(pi.hProcess, 500); // esperar fin real antes de cerrar
            drainPipe(allocator, h_stdout_r, &out, max_output_bytes, &out_total, sink, sink_ctx, .stdout) catch {};
            drainPipe(allocator, h_stderr_r, &err, max_output_bytes, &err_total, sink, sink_ctx, .stderr) catch {};
            _ = CloseHandle(pi.hProcess);
            _ = CloseHandle(h_stdout_r);
            _ = CloseHandle(h_stderr_r);
            _ = CloseHandle(h_job);
            return RunResult{
                .exit_code = 124, // convención POSIX para timeout
                .stdout = try out.toOwnedSlice(allocator),
                .stderr = try err.toOwnedSlice(allocator),
                .timed_out = true,
                .stdout_total_bytes = out_total,
                .stderr_total_bytes = err_total,
            };
        } else if (is_cancelled_fn != null and is_cancelled_fn.?(cancelled_ctx)) {
            // la ORDEN se canceló mientras el hijo corría. Mismo
            // cierre que el timeout (TerminateProcess + cierre del job con
            // KILL_ON_JOB_CLOSE, que mata también al árbol), pero marcado
            // `cancelled` y sin esperar al vencimiento — es justo el hallazgo
            // bloqueante de la auditoría r4: el comando aprobado corría hasta
            // su timeout aunque el humano cancelara la orden.
            _ = TerminateProcess(pi.hProcess, 1);
            _ = WaitForSingleObject(pi.hProcess, 500);
            drainPipe(allocator, h_stdout_r, &out, max_output_bytes, &out_total, sink, sink_ctx, .stdout) catch {};
            drainPipe(allocator, h_stderr_r, &err, max_output_bytes, &err_total, sink, sink_ctx, .stderr) catch {};
            _ = CloseHandle(pi.hProcess);
            _ = CloseHandle(h_stdout_r);
            _ = CloseHandle(h_stderr_r);
            _ = CloseHandle(h_job);
            return RunResult{
                .exit_code = 130, // convención POSIX: 128 + SIGINT(2)
                .stdout = try out.toOwnedSlice(allocator),
                .stderr = try err.toOwnedSlice(allocator),
                .cancelled = true,
                .stdout_total_bytes = out_total,
                .stderr_total_bytes = err_total,
            };
        }
        try drainPipe(allocator, h_stdout_r, &out, max_output_bytes, &out_total, sink, sink_ctx, .stdout);
        try drainPipe(allocator, h_stderr_r, &err, max_output_bytes, &err_total, sink, sink_ctx, .stderr);
    }
    // Lectura final tras terminar.
    try drainPipe(allocator, h_stdout_r, &out, max_output_bytes, &out_total, sink, sink_ctx, .stdout);
    try drainPipe(allocator, h_stderr_r, &err, max_output_bytes, &err_total, sink, sink_ctx, .stderr);

    var exit_code: u32 = 0;
    _ = GetExitCodeProcess(pi.hProcess, &exit_code);
    _ = CloseHandle(pi.hProcess);
    _ = CloseHandle(h_stdout_r);
    _ = CloseHandle(h_stderr_r);
    _ = CloseHandle(h_job);
    return RunResult{
        .exit_code = normalizeExitCode(exit_code),
        .stdout = try out.toOwnedSlice(allocator),
        .stderr = try err.toOwnedSlice(allocator),
        .stdout_total_bytes = out_total,
        .stderr_total_bytes = err_total,
    };
}

/// Reinterpreta el patrón de bits u32→i32 para exit codes de Windows.
/// Evita panic de @intCast cuando un NTSTATUS ≥ 0x80000000 (p. ej. access
/// violation 0xC0000005 = 3221225477 no cabe en i32 por intCast).
fn normalizeExitCode(raw: u32) i32 {
    return @bitCast(raw);
}

/// Cuánto espacio se le concede al árbol de procesos de un hijo.
///
/// Los valores por defecto son los de un artefacto del agente: un script, un
/// binario pequeño, un intérprete. Un NAVEGADOR no cabe ahí —Chromium arranca
/// un proceso por pestaña, uno de GPU, uno de red y varios de utilidad, y el
/// renderizador solo ya pasa de 256 MB—, así que el gate de navegador pide su
/// propio tamaño.
///
/// Medido el 2026-09-08: con los límites por defecto, Edge terminaba con
/// `exit 0` y CERO bytes por los dos canales. No fallaba la comprobación: la
/// mataba el job antes de que llegara a comprobar nada, y el gate se saltaba
/// solo diciendo «el navegador no publicó resultado». Un límite que convierte
/// una comprobación en un salto silencioso es peor que no tenerla.
pub const JobLimits = struct {
    active_processes: u32 = 16,
    process_memory: usize = 256 * 1024 * 1024,
    job_memory: usize = 512 * 1024 * 1024,
    /// T12 L2: aviso del PID del hijo ya contenido en el job (no es un
    /// límite; viaja con ellos para no cambiar la firma de cada spawn).
    notify_pid_fn: ?*const fn (?*anyopaque, u32) void = null,
    notify_pid_ctx: ?*anyopaque = null,

    /// Sitio para un navegador headless completo. Sigue habiendo tope y sigue
    /// muriendo con el job: lo que cambia es el tamaño, no la contención.
    pub const browser: JobLimits = .{
        .active_processes = 64,
        .process_memory = 1536 * 1024 * 1024,
        .job_memory = 3072 * 1024 * 1024,
    };
};

fn createJobObject(limits: JobLimits) ?windows.HANDLE {
    const h_job = CreateJobObjectA(null, null);
    if (@intFromPtr(h_job) == 0) return null;

    var li: JOBOBJECT_EXTENDED_LIMIT_INFORMATION = .{};
    li.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE |
        JOB_OBJECT_LIMIT_ACTIVE_PROCESS |
        JOB_OBJECT_LIMIT_JOB_MEMORY |
        JOB_OBJECT_LIMIT_PROCESS_MEMORY;
    li.BasicLimitInformation.ActiveProcessLimit = limits.active_processes;
    // EXEC#1 (Nemotron): límite POR PROCESO además del total del job, para que un
    // solo hijo no agote el presupuesto del job antes de que el cap por-proceso lo frene.
    li.ProcessMemoryLimit = limits.process_memory;
    li.JobMemoryLimit = limits.job_memory;

    if (SetInformationJobObject(h_job, JobObjectExtendedLimitInformation, &li, @sizeOf(JOBOBJECT_EXTENDED_LIMIT_INFORMATION)) == 0) {
        _ = CloseHandle(h_job);
        return null;
    }
    return h_job;
}

/// Escapa un argumento para la línea de comandos de CreateProcessA.
/// Público porque `spaces.zig` construye su propia línea de comandos para git y
/// necesita EXACTAMENTE estas reglas. Tenía las suyas —unir con espacios y sin
/// comillas— y eso rompía en cuanto la ruta del proyecto llevaba un espacio:
/// `git worktree add` recibía la ruta partida en varios argumentos y fallaba.
/// Duplicar el escapado de Windows es cómo se acaba con dos versiones que
/// divergen; esta es la única.
pub const appendArg = @import("windows_argv.zig").appendArg;

/// Spawnea un proceso DETACHED (independiente, sin pipes, sin Job Object, sin wait).
/// El proceso hijo corre como app independiente con su propia ventana/consola.
/// Devuelve el PID del proceso hijo. El llamador no debe esperar ni matar el proceso
/// (es responsabilidad del usuario cerrar la app cuando termine).
fn spawnDetached(
    allocator: std.mem.Allocator,
    exe: []const u8,
    args: []const []const u8,
    cwd: []const u8,
) ExecutorError!DetachedResult {
    const exe_abs = try resolveLaunchExe(allocator, exe);
    defer allocator.free(exe_abs);
    if (builtin.os.tag != .windows) return detachedPosix(allocator, exe_abs, args, cwd);

    // Detached debe usar la MISMA cadena y quoting que el camino con captura.
    // El allocator del llamador puede morir antes que la app: la cadena vive
    // en page_allocator y un observador la libera cuando termina el hijo.
    var launch: ?BatchLaunch = if (isBatchShim(exe_abs)) prepareBatchLaunch(std.heap.page_allocator, exe_abs) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.UntrustedBatchChain else null;
    defer if (launch) |*l| l.deinit(std.heap.page_allocator);
    const prefix: []const []const u8 = if (launch) |l| l.prefix else &.{};
    const all_args = try allocator.alloc([]const u8, prefix.len + args.len);
    defer allocator.free(all_args);
    @memcpy(all_args[0..prefix.len], prefix);
    @memcpy(all_args[prefix.len..], args);
    var lifetime: ?*DetachedShimLifetime = null;
    var observer: ?std.Thread = null;
    if (launch) |l| {
        const retained = try std.heap.page_allocator.create(DetachedShimLifetime);
        retained.* = .{ .launch = l };
        observer = std.Thread.spawn(.{}, DetachedShimLifetime.wait, .{retained}) catch {
            std.heap.page_allocator.destroy(retained);
            return error.SpawnFailed;
        };
        lifetime = retained;
        launch = null; // El observador posee cadena y handle, sin tocar la arena.
    }
    // Reservar el observador ANTES del hijo: si falla memoria/thread no hay
    // app viva que terminar ni una cadena que liberar prematuramente.
    const pi = createDetachedPinned(allocator, if (lifetime) |l| l.launch.exe else exe_abs, all_args, cwd) catch |e| {
        if (lifetime) |l| {
            l.start(null);
            observer.?.join();
        }
        return e;
    };
    defer _ = CloseHandle(pi.hThread);
    if (lifetime) |l| {
        l.start(pi.hProcess);
        observer.?.detach();
    } else _ = CloseHandle(pi.hProcess);
    return .{ .pid = pi.dwProcessId };
}

const DetachedShimLifetime = struct {
    process: ?windows.HANDLE = null,
    launch: BatchLaunch,
    ready: std.atomic.Value(bool) = .init(false),

    fn start(self: *@This(), process: ?windows.HANDLE) void {
        // Publicación única: acquire en el observador protege process/launch.
        self.process = process;
        self.ready.store(true, .release);
    }

    fn wait(self: *@This()) void {
        while (!self.ready.load(.acquire)) Sleep(1);
        const process = self.process;
        if (process) |handle| {
            if (WaitForSingleObject(handle, 0xffffffff) != 0) {
                // Sin certificar la salida no liberar la cadena. Este fallo
                // excepcional retiene recursos hasta cerrar el motor.
                std.log.err("detached shim: espera fallida; cadena retenida hasta cierre del motor", .{});
                return;
            }
            _ = CloseHandle(handle);
        }
        self.launch.deinit(std.heap.page_allocator);
        std.heap.page_allocator.destroy(self);
    }
};

fn createDetachedPinned(allocator: std.mem.Allocator, exe_abs: [:0]const u8, args: []const []const u8, cwd: []const u8) ExecutorError!PROCESS_INFORMATION {
    const env_block = try command_environment.build(allocator, null);
    defer allocator.free(env_block);
    const application = if (isBatchShim(exe_abs)) try pinnedCmdExe(allocator) else try allocator.dupeZ(u8, exe_abs);
    defer allocator.free(application);
    const cmd_line = try pinnedCommandLine(allocator, application, exe_abs, args);
    defer allocator.free(cmd_line);
    const exe_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, application) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.InvalidPath;
    defer allocator.free(exe_w);
    const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, cmd_line) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.InvalidPath;
    defer allocator.free(cmd_w);
    const cwd_w = std.unicode.utf8ToUtf16LeAllocZ(allocator, cwd) catch |e| return if (e == error.OutOfMemory) error.OutOfMemory else error.InvalidPath;
    defer allocator.free(cwd_w);

    var si = std.mem.zeroes(windows.STARTUPINFOW);
    si.cb = @sizeOf(windows.STARTUPINFOW);
    var pi: PROCESS_INFORMATION = undefined;

    // DETACHED_PROCESS: no hereda consola del padre (GUI apps abren su propia ventana).
    // CREATE_NEW_PROCESS_GROUP: aislamiento de Ctrl+C/Ctrl+Break.
    // Sin CREATE_NO_WINDOW: las apps GUI muestran su ventana normalmente.
    const flags = DETACHED_PROCESS | CREATE_NEW_PROCESS_GROUP | @as(u32, 0x400);
    const ok = CreateProcessW(
        exe_w.ptr,
        cmd_w.ptr,
        null,
        null,
        0, // bInheritHandles = FALSE
        flags,
        @ptrCast(env_block.ptr),
        cwd_w.ptr,
        &si,
        &pi,
    );
    if (ok == 0) return error.SpawnFailed;

    return pi;
}

/// Lee lo disponible del pipe, lo acumula en `buf` (para RunResult) y lo envia al `sink`
/// por cada trozo (streaming en vivo), etiquetado por `stream` (stdout/stderr).
///
/// Drena EN BUCLE hasta vaciar el pipe o gastar `max_per_call` bytes: antes leía
/// un solo trozo de 4 KB por llamada y el bucle de espera dormía 100 ms entre
/// llamadas — ~40 KB/s ⇒ un comando de 50 MB (E3.16) tardaba ~20 minutos.
/// El tope por llamada impide que un hijo que escribe sin parar muera de hambre
/// al chequeo de timeout del bucle exterior (vuelve cada 1 MB como máximo).
fn drainPipe(
    allocator: std.mem.Allocator,
    h: windows.HANDLE,
    buf: *std.ArrayList(u8),
    cap: usize,
    total: *usize,
    sink: ?StreamSink,
    sink_ctx: ?*anyopaque,
    stream: StreamKind,
) !void {
    if (h == INVALID_HANDLE_VALUE) return;
    const max_per_call: usize = 1024 * 1024;
    var spent: usize = 0;
    var tmp: [4096]u8 = undefined;
    while (spent < max_per_call) {
        var avail: u32 = 0;
        if (PeekNamedPipe(h, null, 0, null, &avail, null) == 0 or avail == 0) return;
        const to_read: u32 = @intCast(@min(@as(usize, avail), tmp.len, max_per_call - spent));
        var read: u32 = 0;
        if (ReadFile(h, &tmp, to_read, &read, null) == 0) return;
        if (read == 0) return;
        const slice = tmp[0..read];
        spent += read;
        total.* += read;
        if (buf.items.len < cap) {
            const room = cap - buf.items.len;
            try buf.appendSlice(allocator, slice[0..@min(slice.len, room)]);
        }
        if (sink) |s| {
            // el trozo en vivo también llega como texto.
            if (std.unicode.utf8ValidateSlice(slice) or utf8ConColaCortada(slice)) {
                s(sink_ctx, slice, stream);
            } else if (oemAUtf8(allocator, slice)) |u| {
                defer allocator.free(u);
                s(sink_ctx, u, stream);
            } else |_| s(sink_ctx, slice, stream);
        }
    }
}

// ── Helpers Win32 SOLO para tests (plantar/leer/borrar binarios) ────────

const CreateFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateFileA(
        lpFileName: [*:0]const u8,
        dwDesiredAccess: u32,
        dwShareMode: u32,
        lpSecurityAttributes: ?*anyopaque,
        dwCreationDisposition: u32,
        dwFlagsAndAttributes: u32,
        hTemplateFile: ?windows.HANDLE,
    ) windows.HANDLE;
}.CreateFileA else @import("providers").posix_files.CreateFileA;
const WriteFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn WriteFile(hFile: windows.HANDLE, lpBuffer: [*]const u8, n: u32, written: *u32, ov: ?*anyopaque) c_int;
}.WriteFile else @import("providers").posix_files.WriteFile;
const DeleteFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn DeleteFileA(lpFileName: [*:0]const u8) c_int;
}.DeleteFileA else @import("providers").posix_files.DeleteFileA;

const GENERIC_READ_T: u32 = 0x80000000;
const GENERIC_WRITE_T: u32 = 0x40000000;
const FILE_SHARE_READ_T: u32 = 0x00000001;
const CREATE_NEW_T: u32 = 1;
const OPEN_EXISTING_T: u32 = 3;
const FILE_ATTRIBUTE_NORMAL_T: u32 = 0x80;

// ── Tests adversariales ────────────────────────────────────────────────

// EXEC-01 (dogfood w3): el binario debe quedar FIJADO a una ruta absoluta del PATH,
// nunca resolverse desde el cwd. Reproducción del bypass: plantar un `cmd.exe` impostor
// en el directorio actual (vector real de CreateProcess: "current directory of the parent
// process") y comprobar que `resolveAllowedExe` devuelve el cmd REAL del PATH, jamás el
// plantado. Se usa "cmd" porque está garantizado en el PATH (C:\Windows\System32 siempre
// está en PATH en cualquier Windows); la propiedad de seguridad es idéntica para
// "python"/"node"/"zig"/etc. (Antes se usaba "zig" asumiendo que estaba en PATH por el
// build, pero eso no vale cuando zig se invoca por ruta absoluta sin estar en PATH.)
test "resolveAllowedExe fija la ruta del PATH, ignora un binario plantado en el cwd" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: lanza cmd.exe o un lote .cmd/.bat (Windows)");
    const a = std.testing.allocator;
    const marker = "PLANTED_EVIL_BINARY_NOT_AN_INTERPRETER";

    // Plantar cwd\cmd.exe SOLO si no existe ya (CREATE_NEW falla si existe ⇒ no
    // clobbering de un cmd.exe legítimo que estuviera en el cwd).
    const planted_h = CreateFileA("cmd.exe", GENERIC_WRITE_T, FILE_SHARE_READ_T, null, CREATE_NEW_T, FILE_ATTRIBUTE_NORMAL_T, null);
    const we_planted = planted_h != INVALID_HANDLE_VALUE;
    if (we_planted) {
        var written: u32 = 0;
        _ = WriteFile(planted_h, marker, marker.len, &written, null);
        _ = CloseHandle(planted_h);
    }
    defer if (we_planted) {
        _ = DeleteFileA("cmd.exe");
    };

    // Debe resolver al cmd REAL del PATH (absoluto), no al plantado.
    const resolved = try resolveAllowedExe(a, "cmd");
    defer a.free(resolved);

    try std.testing.expect(isAbsoluteWin(resolved));
    try std.testing.expect(std.ascii.endsWithIgnoreCase(resolved, "cmd.exe"));

    // Prueba definitiva: leer el binario resuelto y verificar que NO es el impostor.
    // El cmd real es un PE (empieza por "MZ"); el plantado empieza por el marcador.
    const resolved_z = try a.dupeZ(u8, resolved);
    defer a.free(resolved_z);
    const h = CreateFileA(resolved_z.ptr, GENERIC_READ_T, FILE_SHARE_READ_T, null, OPEN_EXISTING_T, FILE_ATTRIBUTE_NORMAL_T, null);
    try std.testing.expect(h != INVALID_HANDLE_VALUE);
    defer _ = CloseHandle(h);
    var head: [64]u8 = undefined;
    var read: u32 = 0;
    _ = ReadFile(h, &head, head.len, &read, null);
    try std.testing.expect(read > 0);
    try std.testing.expect(!std.mem.startsWith(u8, head[0..read], marker));
}

test "resolveAllowedExe es fail-closed si el nombre no está en el PATH" {
    const a = std.testing.allocator;
    // Nombre inventado (no es un intérprete real ni está en el PATH) ⇒ no se puede fijar.
    try std.testing.expectError(error.ExeNotResolved, resolveAllowedExe(a, "devagents-no-such-binary-xyz"));
}

/// E5.05: monta un shim `.cmd` propio en un dir temporal y lo añade al PATH
/// solo durante el test (se restaura siempre, incluso si la prueba falla).
const CmdShimFixture = struct {
    dir: []u8,
    shim: []u8,
    old_path: [:0]u8,

    fn install(a: std.mem.Allocator, name: []const u8) !CmdShimFixture {
        var tmp_buf: [4096]u8 = undefined;
        const tn = GetTempPathA(tmp_buf.len, &tmp_buf);
        if (tn == 0 or tn >= tmp_buf.len) return error.TempPathFailed;
        const dir = try std.fmt.allocPrint(a, "{s}e5shim{d}", .{ tmp_buf[0..tn], GetTickCount64() });
        errdefer a.free(dir);
        const dir_z = try a.dupeZ(u8, dir);
        defer a.free(dir_z);
        if (CreateDirectoryA(dir_z, null) == 0) return error.MkdirFailed;

        const shim = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "{s}.cmd", .{ dir, name });
        errdefer a.free(shim);
        const shim_z = try a.dupeZ(u8, shim);
        defer a.free(shim_z);
        const hf = CreateFileA(shim_z.ptr, GENERIC_WRITE_T, FILE_SHARE_READ_T, null, CREATE_NEW_T, FILE_ATTRIBUTE_NORMAL_T, null);
        if (hf == INVALID_HANDLE_VALUE) return error.ShimWriteFailed;
        const body = "@echo off\r\n@echo SHIM_OK:%~1\r\n";
        var written: u32 = 0;
        _ = WriteFile(hf, body.ptr, body.len, &written, null);
        _ = CloseHandle(hf);

        const old_path = try getEnvAlloc(a, "PATH");
        errdefer a.free(old_path);
        const new_path = try std.fmt.allocPrintSentinel(a, "{s};{s}", .{ dir, old_path }, 0);
        defer a.free(new_path);
        if (SetEnvironmentVariableA("PATH", new_path.ptr) == 0) return error.PathSetFailed;
        return .{ .dir = dir, .shim = shim, .old_path = old_path };
    }

    fn uninstall(fx: *CmdShimFixture, a: std.mem.Allocator) void {
        _ = SetEnvironmentVariableA("PATH", fx.old_path.ptr);
        const dir_z = a.dupeZ(u8, fx.dir) catch null;
        const shim_z = a.dupeZ(u8, fx.shim) catch null;
        if (shim_z) |s| _ = DeleteFileA(s.ptr);
        if (dir_z) |d| _ = RemoveDirectoryA(d.ptr);
        if (shim_z) |s| a.free(s);
        if (dir_z) |d| a.free(d);
        a.free(fx.shim);
        a.free(fx.dir);
        a.free(fx.old_path);
    }
};

test "E5.05: shim .cmd resuelto sin cadena de confianza se rechaza antes de ejecutar" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: lanza cmd.exe o un lote .cmd/.bat (Windows)");
    const a = std.testing.allocator;
    var fx = try CmdShimFixture.install(a, "e5shim");
    defer fx.uninstall(a);

    // La resolución fija la ruta absoluta del shim .cmd.
    const resolved = try resolveAllowedExeExt(a, "e5shim", ".cmd");
    defer a.free(resolved);
    try std.testing.expect(isAbsoluteWin(resolved));
    try std.testing.expect(std.ascii.endsWithIgnoreCase(resolved, "e5shim.cmd"));

    // Resolver en PATH no concede confianza: el fixture temporal no pertenece
    // a una instalación autorizada. El gate conserva su error explícito y el
    // spawn lo presenta como rechazo de la cadena, sin invocar cmd.exe.
    try std.testing.expectError(error.UntrustedCliRoot, prepareBatchLaunch(a, resolved));
    try std.testing.expectError(error.UntrustedBatchChain, spawnWin32(a, "e5shim", &.{"node-ok"}, fx.dir, 30000, 8192, null, null, ""));
}

test "E5.05: shim .cmd inexistente sigue siendo fail-closed" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.ExeNotResolved, resolveAllowedExeExt(a, "devagents-no-such-shim-xyz", ".cmd"));
}

test "rejects exe outside allowlist" {
    const policy = executor.Policy{};
    const result = executor.runGoverned(std.testing.allocator, policy, "cmd.exe", &.{}, "devagents-workspace\\orden-1", null, null, null);
    try std.testing.expectError(error.ExeNotAllowed, result);
}

test "rejects cwd escaping workspace" {
    const policy = executor.Policy{};
    try std.testing.expectError(error.PathOutsideSandbox, executor.runGoverned(std.testing.allocator, policy, "zig", &.{"--version"}, "..\\Windows", null, null, null));
    try std.testing.expectError(error.PathOutsideSandbox, executor.runGoverned(std.testing.allocator, policy, "zig", &.{"--version"}, "C:\\Windows", null, null, null));
}

test "rejects network or spend actions" {
    var policy = executor.Policy{};
    policy.requires_approval = true;
    try std.testing.expectError(error.NetworkOrSpendRequiresApproval, executor.runGoverned(std.testing.allocator, policy, "python", &.{"script.py"}, "devagents-workspace\\orden-1", null, null, null));
}

test "untrusted origin requires approval before any spawn" {
    var spawn_called: bool = false;
    const Mock = struct {
        var called: *bool = undefined;
        fn spawn(a: std.mem.Allocator, exe: []const u8, args: []const []const u8, cwd: []const u8, timeout_ms: u32, cap: usize, sink: ?executor.StreamSink, sink_ctx: ?*anyopaque, _: []const u8) !executor.RunResult {
            _ = a;
            _ = exe;
            _ = args;
            _ = cwd;
            _ = timeout_ms;
            _ = cap;
            _ = sink;
            _ = sink_ctx;
            called.* = true;
            return error.SpawnFailed;
        }
    };
    Mock.called = &spawn_called;

    const policy = executor.Policy{ .origin = .untrusted };
    try std.testing.expectError(error.UntrustedOriginRequiresApproval, executor.runGoverned(
        std.testing.allocator,
        policy,
        "zig",
        &.{"--version"},
        "devagents-workspace\\orden-1",
        Mock.spawn,
        null,
        null,
    ));
    try std.testing.expect(!spawn_called);
}

test "local origin continues through allowlisted exe and sandboxed cwd" {
    const Mock = struct {
        fn spawn(a: std.mem.Allocator, exe: []const u8, args: []const []const u8, cwd: []const u8, timeout_ms: u32, cap: usize, sink: ?executor.StreamSink, sink_ctx: ?*anyopaque, _: []const u8) !executor.RunResult {
            _ = exe;
            _ = args;
            _ = cwd;
            _ = timeout_ms;
            _ = cap;
            _ = sink;
            _ = sink_ctx;
            return .{
                .exit_code = 0,
                .stdout = try a.dupe(u8, "local-ok"),
                .stderr = try a.dupe(u8, ""),
            };
        }
    };
    const result = try executor.runGoverned(std.testing.allocator, executor.Policy{ .origin = .local }, "zig", &.{"--version"}, "devagents-workspace\\orden-1", Mock.spawn, null, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expectEqualStrings("local-ok", result.stdout);
}

test "happy path captures exit code and stdout" {
    const Mock = struct {
        fn spawn(a: std.mem.Allocator, exe: []const u8, args: []const []const u8, cwd: []const u8, timeout_ms: u32, cap: usize, sink: ?executor.StreamSink, sink_ctx: ?*anyopaque, _: []const u8) !executor.RunResult {
            _ = exe;
            _ = args;
            _ = cwd;
            _ = timeout_ms;
            _ = cap;
            _ = sink;
            _ = sink_ctx;
            return .{
                .exit_code = 0,
                .stdout = try a.dupe(u8, "hello"),
                .stderr = try a.dupe(u8, ""),
            };
        }
    };
    const result = try executor.runGoverned(std.testing.allocator, executor.Policy{}, "zig", &.{"--version"}, "devagents-workspace\\orden-1", Mock.spawn, null, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expectEqualStrings("hello", result.stdout);
}

test "timeout kills process" {
    const Slow = struct {
        fn spawn(a: std.mem.Allocator, exe: []const u8, args: []const []const u8, cwd: []const u8, timeout_ms: u32, cap: usize, sink: ?executor.StreamSink, sink_ctx: ?*anyopaque, _: []const u8) !executor.RunResult {
            _ = exe;
            _ = args;
            _ = cwd;
            _ = cap;
            _ = sink;
            _ = sink_ctx;
            if (timeout_ms < 20000) return error.Timeout;
            return .{
                .exit_code = 0,
                .stdout = try a.dupe(u8, ""),
                .stderr = try a.dupe(u8, ""),
            };
        }
    };
    try std.testing.expectError(error.Timeout, executor.runGoverned(std.testing.allocator, executor.Policy{ .timeout_ms = 100 }, "zig", &.{}, "devagents-workspace\\orden-1", Slow.spawn, null, null));
}

test "output cap truncates stdout" {
    const Big = struct {
        fn spawn(a: std.mem.Allocator, exe: []const u8, args: []const []const u8, cwd: []const u8, timeout_ms: u32, cap: usize, sink: ?executor.StreamSink, sink_ctx: ?*anyopaque, _: []const u8) !executor.RunResult {
            _ = exe;
            _ = args;
            _ = cwd;
            _ = timeout_ms;
            _ = sink;
            _ = sink_ctx;
            const big = try a.alloc(u8, cap + 100);
            @memset(big, 'x');
            return .{
                .exit_code = 0,
                .stdout = big,
                .stderr = try a.dupe(u8, ""),
            };
        }
    };
    const result = try executor.runGoverned(std.testing.allocator, executor.Policy{ .max_output_bytes = 16 }, "zig", &.{}, "devagents-workspace\\orden-1", Big.spawn, null, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 16), result.stdout.len);
    // E3.16: el truncado es visible — total real + flag, nunca silencioso.
    try std.testing.expect(result.stdoutTruncated());
    try std.testing.expectEqual(@as(usize, 116), result.stdout_total_bytes);
    try std.testing.expect(!result.stderrTruncated());
}

// E3.16: un spawn que YA midió los bytes reales del pipe (drainPipe) informa
// el total aunque devuelva el buffer capado; el flag sigue saliendo.
test "output cap respeta totales medidos por el spawn" {
    const Measured = struct {
        fn spawn(a: std.mem.Allocator, exe: []const u8, args: []const []const u8, cwd: []const u8, timeout_ms: u32, cap: usize, sink: ?executor.StreamSink, sink_ctx: ?*anyopaque, _: []const u8) !executor.RunResult {
            _ = exe;
            _ = args;
            _ = cwd;
            _ = timeout_ms;
            _ = sink;
            _ = sink_ctx;
            const capped = try a.alloc(u8, cap);
            @memset(capped, 'y');
            return .{
                .exit_code = 0,
                .stdout = capped,
                .stderr = try a.dupe(u8, ""),
                // El hijo realmente escribió 1 MB; el buffer solo guarda el cap.
                .stdout_total_bytes = 1024 * 1024,
            };
        }
    };
    const result = try executor.runGoverned(std.testing.allocator, executor.Policy{ .max_output_bytes = 64 }, "zig", &.{}, "devagents-workspace\\orden-1", Measured.spawn, null, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 64), result.stdout.len);
    try std.testing.expectEqual(@as(usize, 1024 * 1024), result.stdout_total_bytes);
    try std.testing.expect(result.stdoutTruncated());
}

// E3.16: salida dentro del cap no se marca como truncada.
test "output under cap is not truncated" {
    const Small = struct {
        fn spawn(a: std.mem.Allocator, exe: []const u8, args: []const []const u8, cwd: []const u8, timeout_ms: u32, cap: usize, sink: ?executor.StreamSink, sink_ctx: ?*anyopaque, _: []const u8) !executor.RunResult {
            _ = exe;
            _ = args;
            _ = cwd;
            _ = timeout_ms;
            _ = cap;
            _ = sink;
            _ = sink_ctx;
            return .{
                .exit_code = 0,
                .stdout = try a.dupe(u8, "ok"),
                .stderr = try a.dupe(u8, ""),
            };
        }
    };
    const result = try executor.runGoverned(std.testing.allocator, executor.Policy{ .max_output_bytes = 64 }, "zig", &.{}, "devagents-workspace\\orden-1", Small.spawn, null, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", result.stdout);
    try std.testing.expectEqual(@as(usize, 2), result.stdout_total_bytes);
    try std.testing.expect(!result.stdoutTruncated());
}

// E3.16 — la fila pide ≥50 MB de stdout y UNA línea de ≥10 MB sin newlines,
// contra el spawn REAL (no mock): el pipe debe drenarse entero, el buffer se
// capa, el total real se mide y el truncado se declara. Antes del drenado en
// bucle esto tardaba ~20 minutos (~40 KB/s); ahora deben ser segundos.
test "E3.16: 50 MB stdout real se drena, se capa y el truncado se declara" {
    const a = std.testing.allocator;
    var tmp_buf: [4096]u8 = undefined;
    const tmp_len = GetTempPathA(@intCast(tmp_buf.len), &tmp_buf);
    if (tmp_len == 0 or tmp_len >= tmp_buf.len) return error.SkipZigTest;
    const ws = try std.fmt.allocPrint(a, "{s}beats-e316-ws", .{tmp_buf[0..tmp_len]});
    defer a.free(ws);
    const ws_z = try a.dupeZ(u8, ws);
    defer a.free(ws_z);
    _ = CreateDirectoryA(ws_z, null);
    defer _ = RemoveDirectoryA(ws_z);

    // Una línea de 10 MiB sin newline + 40 MiB más = 50 MiB + '\n'.
    const script = "process.stdout.write('x'.repeat(10*1024*1024)+'\\n'+'y'.repeat(40*1024*1024))";
    const args = [_][]const u8{ "-e", script };

    const Sink = struct {
        var bytes: usize = 0;
        fn sink(_: ?*anyopaque, chunk: []const u8, _: executor.StreamKind) void {
            bytes += chunk.len;
        }
    };
    Sink.bytes = 0;

    const started = GetTickCount64();
    const r = executor.runGoverned(a, .{ .workspace_root = ws, .timeout_ms = 120_000 }, "node", &args, ws, null, Sink.sink, null) catch |e| {
        // Sin node en PATH no hay producto que estresar: no es un fallo del
        // motor. QA-A H3: se dice por stderr; si está y no arranca, rojo.
        return omitirSiFalta(e, "node");
    };
    defer r.deinit(a);
    const elapsed_ms = GetTickCount64() - started;

    const expected: usize = 10 * 1024 * 1024 + 1 + 40 * 1024 * 1024;
    if (r.exit_code != 0) std.debug.print("[E3.16] child exit={d} stdout_total={d} stderr={s}\n", .{ r.exit_code, r.stdout_total_bytes, r.stderr });
    try std.testing.expectEqual(@as(i32, 0), r.exit_code);
    try std.testing.expectEqual(expected, r.stdout_total_bytes);
    try std.testing.expect(r.stdoutTruncated());
    try std.testing.expectEqual(@as(usize, 256 * 1024), r.stdout.len);
    // El stream en vivo llevó TODOS los bytes (no solo el cap).
    try std.testing.expectEqual(expected, Sink.bytes);
    // Con drenado por demanda (~40 KB/s) serían ~21 min; acotado a <60 s.
    try std.testing.expect(elapsed_ms < 60_000);
    std.debug.print("[E3.16] 50 MB stdout: total={d} B, buffer={d} B, elapsed={d} ms\n", .{ r.stdout_total_bytes, r.stdout.len, elapsed_ms });
}

test "E5.55 capture drains the complete 601042-byte CLI catalog" {
    const a = std.testing.allocator;
    var tmp_buf: [4096]u8 = undefined;
    const n = GetTempPathA(tmp_buf.len, &tmp_buf);
    if (n == 0 or n >= tmp_buf.len) return error.TempPathFailed;
    const dir = try std.fmt.allocPrint(a, "{s}beats-e555-output-{d}", .{ tmp_buf[0..n], GetTickCount64() });
    defer a.free(dir);
    const dir_z = try a.dupeZ(u8, dir);
    defer a.free(dir_z);
    if (CreateDirectoryA(dir_z.ptr, null) == 0) return error.MkdirFailed;
    defer _ = RemoveDirectoryA(dir_z.ptr);
    const node = try resolveAllowedExeExt(a, "node", ".exe");
    defer a.free(node);
    // Assert complete bounded capture independently of host scheduling load.
    // The generous TEST deadline does not change the 8 s discovery deadline.
    const script = "const fs=require('fs');let left=601042;function send(){const n=Math.min(4096,left);fs.writeSync(1,Buffer.alloc(n,120));left-=n;if(left>0)setImmediate(send);}send();";
    const started = GetTickCount64();
    const r = try runVerifierPinned(a, .{ .workspace_root = dir, .timeout_ms = 30000, .max_output_bytes = 601042 }, node, &.{ "-e", script }, dir);
    defer r.deinit(a);
    const elapsed = GetTickCount64() - started;
    std.debug.print("[E5.55 capture] exe={s} timed_out={any} exit={d} stdout={d} total={d} elapsed_ms={d}\n", .{ node, r.timed_out, r.exit_code, r.stdout.len, r.stdout_total_bytes, elapsed });
    try std.testing.expect(!r.timed_out);
    try std.testing.expectEqual(@as(i32, 0), r.exit_code);
    try std.testing.expectEqual(@as(usize, 601042), r.stdout_total_bytes);
    try std.testing.expectEqual(@as(usize, 601042), r.stdout.len);
    try std.testing.expectEqual(@as(usize, 0), r.stderr.len);
    try std.testing.expect(!r.stdoutTruncated());
    for (r.stdout) |c| try std.testing.expectEqual(@as(u8, 'x'), c);
}

// (r5): hallazgo bloqueante de la auditoría r4 — la ejecución
// reanudada de un comando aprobado corría hasta su timeout aunque la ORDEN se
// cancelara. Aquí se prueba el mecanismo de base: el bucle de espera mata al
// hijo (y a su árbol) en plazo corto al ver la cancelación, sin esperar.
test "CK-CAB-019 executor: la cancelación de la orden mata al hijo en plazo corto" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: perfil y ExecutionPolicy de PowerShell (Windows)");
    const a = std.testing.allocator;
    var tmp_buf: [4096]u8 = undefined;
    const n = GetTempPathA(tmp_buf.len, &tmp_buf);
    if (n == 0 or n >= tmp_buf.len) return error.TempPathFailed;
    const dir = try std.fmt.allocPrint(a, "{s}beats-cab019-cancel-{d}", .{ tmp_buf[0..n], GetTickCount64() });
    defer a.free(dir);
    const dir_z = try a.dupeZ(u8, dir);
    defer a.free(dir_z);
    if (CreateDirectoryA(dir_z.ptr, null) == 0) return error.MkdirFailed;
    defer _ = RemoveDirectoryA(dir_z.ptr);

    const Flag = struct {
        var cancelled = std.atomic.Value(bool).init(false);
        var marker: [*:0]const u8 = undefined;
        fn check(_: ?*anyopaque) bool {
            return cancelled.load(.acquire);
        }
        fn cancelWhenChildRuns() void {
            // No cancelar a ciegas: se espera a que el hijo haya arrancado de
            // verdad y escrito su marca (margen amplio para el arranque de
            // powershell) y solo entonces se marca — así se mata EN VUELO, que
            // es el caso del hallazgo (no una cancelación antes de lanzar).
            var waited: u64 = 0;
            while (waited < 8000) : (waited += 50) {
                if (GetFileAttributesA(marker) != INVALID_FILE_ATTRIBUTES) break;
                Sleep(50);
            }
            cancelled.store(true, .release);
        }
    };
    Flag.cancelled = std.atomic.Value(bool).init(false);
    const mark = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "cab019-start.txt", .{dir});
    defer a.free(mark);
    const mark_z = try a.dupeZ(u8, mark);
    defer a.free(mark_z);
    Flag.marker = mark_z.ptr;

    // El hijo escribe su marca y duerme 8 s: sin cancelación el test tardaría
    // ~8 s; con el timeout, 30 s. Con el arreglo, < 5 s.
    const script = "Set-Content -Path cab019-start.txt -Value run; Start-Sleep -Seconds 8";
    const canceller = try std.Thread.spawn(.{}, Flag.cancelWhenChildRuns, .{});
    defer canceller.join();
    const started = GetTickCount64();
    const r = try runGoverned(a, .{
        .workspace_root = dir,
        .timeout_ms = 30_000,
        .is_cancelled_fn = Flag.check,
    }, "powershell", &.{ "-NoProfile", "-Command", script }, dir, null, null, null);
    defer r.deinit(a);
    const elapsed = GetTickCount64() - started;
    std.debug.print("[CK-CAB-019 executor] elapsed_ms={d} exit={d} cancelled={any} timed_out={any}\n", .{ elapsed, r.exit_code, r.cancelled, r.timed_out });

    try std.testing.expect(r.cancelled);
    try std.testing.expect(!r.timed_out);
    try std.testing.expectEqual(@as(i32, 130), r.exit_code);
    try std.testing.expect(elapsed >= 100); // hubo ejecución real en vuelo
    try std.testing.expect(elapsed < 5000); // ni los 8 s del hijo ni el timeout de 30 s se cumplieron
}

// r5: «cancelada justo antes de lanzar, no arranca» — la
// comprobación ocurre ANTES de crear el proceso. Se usa un binario fijado por
// ruta que NO es ejecutable: si el spawn se intentara, CreateProcess fallaría
// con error.SpawnFailed; con la orden ya cancelada, se retorna un resultado
// cancelado sin intentarlo (sin la comprobación previa este test falla).
test "CK-CAB-019 executor: cancelada justo antes de lanzar, ni se crea el proceso" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "falso-binario.txt", .data = "no es un ejecutable" });
    const exe_abs = try tmp.dir.realPathFileAlloc(std.testing.io, "falso-binario.txt", a);
    defer a.free(exe_abs);
    const cwd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(cwd);

    const Flag = struct {
        fn check(_: ?*anyopaque) bool {
            return true;
        }
    };
    const r = try runVerifierPinned(a, .{
        .workspace_root = cwd,
        .timeout_ms = 30_000,
        .is_cancelled_fn = Flag.check,
    }, exe_abs, &.{}, cwd);
    defer r.deinit(a);
    try std.testing.expect(r.cancelled);
    try std.testing.expect(!r.timed_out);
    try std.testing.expectEqual(@as(i32, 130), r.exit_code);
    try std.testing.expectEqual(@as(usize, 0), r.stdout.len);
}

// FIX 1 regresión: exit codes NTSTATUS grandes no deben paniquear.
test "normalizeExitCode reinterprets u32→i32 without panic" {
    try std.testing.expectEqual(@as(i32, 0), normalizeExitCode(0));
    try std.testing.expectEqual(@as(i32, 1), normalizeExitCode(1));
    try std.testing.expectEqual(@as(i32, 0x7FFFFFFF), normalizeExitCode(0x7FFFFFFF));
    // NTSTATUS / access violation típico de crash en Windows.
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0xC0000005))), normalizeExitCode(0xC0000005));
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0x80000000))), normalizeExitCode(0x80000000));
    try std.testing.expectEqual(@as(i32, -1), normalizeExitCode(0xFFFFFFFF));
}

test "RunResult with large exit code via mock spawn" {
    const Crash = struct {
        fn spawn(a: std.mem.Allocator, exe: []const u8, args: []const []const u8, cwd: []const u8, timeout_ms: u32, cap: usize, sink: ?executor.StreamSink, sink_ctx: ?*anyopaque, _: []const u8) !executor.RunResult {
            _ = exe;
            _ = args;
            _ = cwd;
            _ = timeout_ms;
            _ = cap;
            _ = sink;
            _ = sink_ctx;
            return .{
                .exit_code = normalizeExitCode(0xC0000005),
                .stdout = try a.dupe(u8, ""),
                .stderr = try a.dupe(u8, "access violation"),
            };
        }
    };
    const result = try executor.runGoverned(std.testing.allocator, executor.Policy{}, "zig", &.{"--version"}, "devagents-workspace\\orden-1", Crash.spawn, null, null);
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(i32, @bitCast(@as(u32, 0xC0000005))), result.exit_code);
    try std.testing.expectEqualStrings("access violation", result.stderr);
}

// ── Tests de streaming (H-06, Etapa 2) ─────────────────────────────────

test "streaming sink recibe N trozos en orden y RunResult queda intacto" {
    const SinkCtx = struct {
        chunks: std.ArrayList([]const u8),
        allocator: std.mem.Allocator,

        fn sink(ctx: ?*anyopaque, chunk: []const u8, stream: executor.StreamKind) void {
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            const dup = self.allocator.dupe(u8, chunk) catch return;
            self.chunks.append(self.allocator, dup) catch {
                self.allocator.free(dup);
                return;
            };
            _ = stream;
        }
    };

    const Mock = struct {
        fn spawn(a: std.mem.Allocator, exe: []const u8, args: []const []const u8, cwd: []const u8, timeout_ms: u32, cap: usize, sink: ?executor.StreamSink, sink_ctx: ?*anyopaque, _: []const u8) !executor.RunResult {
            _ = exe;
            _ = args;
            _ = cwd;
            _ = timeout_ms;
            _ = cap;
            // Simular 3 trozos de streaming como ConPTY haría con line-buffering.
            if (sink) |s| {
                s(sink_ctx, "tick 1\n", .stdout);
                s(sink_ctx, "tick 2\n", .stdout);
                s(sink_ctx, "tick 3\n", .stdout);
            }
            return .{
                .exit_code = 0,
                .stdout = try a.dupe(u8, "tick 1\ntick 2\ntick 3\n"),
                .stderr = try a.dupe(u8, ""),
            };
        }
    };

    var sc = SinkCtx{ .chunks = .empty, .allocator = std.testing.allocator };
    defer {
        for (sc.chunks.items) |c| std.testing.allocator.free(c);
        sc.chunks.deinit(std.testing.allocator);
    }

    const result = try executor.runGoverned(
        std.testing.allocator,
        executor.Policy{},
        "zig",
        &.{"--version"},
        "devagents-workspace\\orden-1",
        Mock.spawn,
        SinkCtx.sink,
        &sc,
    );
    defer result.deinit(std.testing.allocator);

    // RunResult intacto: stdout acumulado completo.
    try std.testing.expectEqualStrings("tick 1\ntick 2\ntick 3\n", result.stdout);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);

    // Sink recibió 3 trozos en orden.
    try std.testing.expectEqual(@as(usize, 3), sc.chunks.items.len);
    try std.testing.expectEqualStrings("tick 1\n", sc.chunks.items[0]);
    try std.testing.expectEqualStrings("tick 2\n", sc.chunks.items[1]);
    try std.testing.expectEqualStrings("tick 3\n", sc.chunks.items[2]);
}

test "streaming sink null no causa error (compatibilidad hacia atrás)" {
    const Mock = struct {
        fn spawn(a: std.mem.Allocator, exe: []const u8, args: []const []const u8, cwd: []const u8, timeout_ms: u32, cap: usize, sink: ?executor.StreamSink, sink_ctx: ?*anyopaque, _: []const u8) !executor.RunResult {
            _ = exe;
            _ = args;
            _ = cwd;
            _ = timeout_ms;
            _ = cap;
            _ = sink;
            _ = sink_ctx;
            return .{
                .exit_code = 0,
                .stdout = try a.dupe(u8, "ok"),
                .stderr = try a.dupe(u8, ""),
            };
        }
    };

    const result = try executor.runGoverned(
        std.testing.allocator,
        executor.Policy{},
        "zig",
        &.{"--version"},
        "devagents-workspace\\orden-1",
        Mock.spawn,
        null,
        null,
    );
    defer result.deinit(std.testing.allocator);
    try std.testing.expectEqualStrings("ok", result.stdout);
}

// (tests de stripVtEscapes eliminados: el camino pipe-plano no envuelve la salida en VT)

/// Solo para el test de D1: preguntarle a Windows si un PID sigue vivo. Un
/// handle valido es la unica prueba de que el proceso sobrevivio al retorno.
extern "kernel32" fn OpenProcess(dwDesiredAccess: u32, bInheritHandle: c_int, dwProcessId: u32) windows.HANDLE;

/// QA-A H3: las pruebas reales del ejecutor convertían ExeNotResolved Y
/// SpawnFailed en SkipZigTest, así que la suite no veía un ejecutor que no
/// sabe lanzar nada (H2: cwd inexistente → SpawnFailed en todo proyecto
/// nuevo, en verde). Solo se omite si la herramienta NO está en el PATH, y se
/// dice por stderr; si está y no se pudo lanzar, es un rojo con el motivo.
fn omitirSiFalta(e: anyerror, herramienta: []const u8) anyerror {
    if (e == error.ExeNotResolved) {
        std.debug.print("OMITIDA: {s} no está en el PATH ({s}); esta prueba no puede medir nada sin él\n", .{ herramienta, @errorName(e) });
        return error.SkipZigTest;
    }
    std.debug.print("FALLO: {s} está en el PATH pero no se pudo lanzar: {s}\n", .{ herramienta, @errorName(e) });
    return e;
}

/// QA-A H3: carpeta propia bajo el TEMP del sistema para las pruebas reales.
/// Si no se puede crear es un fallo del entorno de la prueba, no un «omitir».
fn carpetaDePrueba(allocator: std.mem.Allocator, prefijo: []const u8) ![:0]u8 {
    var sys_buf: [1024]u8 = undefined;
    const len = GetTempPathA(1024, &sys_buf);
    if (len == 0 or len >= 1024) return error.TempPathUnavailable;
    const cwd = try std.fmt.allocPrintSentinel(allocator, "{s}{s}-{d}", .{ sys_buf[0..len], prefijo, GetTickCount64() }, 0);
    errdefer allocator.free(cwd);
    if (CreateDirectoryA(cwd.ptr, null) == 0) {
        std.debug.print("FALLO: no se pudo crear la carpeta de prueba {s}\n", .{cwd});
        return error.TestDirUnavailable;
    }
    return cwd;
}

/// QA-A H3: un `exit_code != 0` de un programa que sí arrancó es un rojo con
/// su stderr, no un «omitir».
fn exigirExito(r: RunResult, herramienta: []const u8) !void {
    if (r.exit_code == 0) return;
    std.debug.print("FALLO: {s} salió con {d}; stderr: {s}\n", .{ herramienta, r.exit_code, r.stderr });
    return error.TestUnexpectedResult;
}

test "QA-A H3: el ejecutor lanza de verdad un programa del sistema (where.exe)" {
    // Centinela sin omisión posible: where.exe viene con Windows. Si esto no
    // arranca, el ejecutor no sabe lanzar nada y la suite tiene que ponerse
    // en rojo, no quedarse en verde con las demás pruebas «omitidas».
    if (builtin.os.tag != .windows) return @import("platform.zig").skip("T9: centinela con where.exe de Windows; en Linux lo cubre el lanzamiento real de executor POSIX");
    const allocator = std.testing.allocator;
    const cwd = try carpetaDePrueba(allocator, "beats-qa-a-h3");
    defer allocator.free(cwd);
    defer _ = RemoveDirectoryA(cwd.ptr);
    const r = try runGoverned(allocator, .{ .workspace_root = cwd, .timeout_ms = 15_000 }, "where", &.{"cmd"}, cwd, null, null, null);
    defer r.deinit(allocator);
    try exigirExito(r, "where");
    try std.testing.expect(std.ascii.indexOfIgnoreCase(r.stdout, "cmd.exe") != null);
}

test "QA-A H2: lanzar en una carpeta de trabajo que no existe falla con SpawnFailed (y la C-ABI lo traduce)" {
    if (builtin.os.tag != .windows) return @import("platform.zig").skip("T9: la carpeta de prueba y la ruta inexistente se arman con GetTempPathA/CreateDirectoryA y separador Windows; omitida en Linux");
    const allocator = std.testing.allocator;
    const root = try carpetaDePrueba(allocator, "beats-qa-a-h2");
    defer allocator.free(root);
    defer _ = RemoveDirectoryA(root.ptr);
    const missing = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "no-existe", .{root});
    defer allocator.free(missing);
    try std.testing.expectError(error.SpawnFailed, runGoverned(allocator, .{ .workspace_root = root, .timeout_ms = 15_000 }, "where", &.{"cmd"}, missing, null, null, null));
}

test "D1: un proceso lanzado con runDetached SIGUE VIVO tras retornar" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    // Prueba de la decision D1 (2026-08-06).
    //
    // `runGoverned` mete a todo hijo en un job con KILL_ON_JOB_CLOSE y cierra
    // ese job al volver, asi que Windows mata el arbol entero; y ademas hay un
    // TerminateProcess al agotarse timeout_ms. Por eso "ejecutalo en pantalla
    // sin que se cierre" era imposible por esa via.
    //
    // `runDetached` es el otro camino, el que ya usa superagent.zig cuando
    // detecta un programa de ventana: sin job y sin espera. Sin este test, que
    // el proceso sobreviva es una afirmacion del comentario, no del codigo.
    const allocator = std.testing.allocator;

    const dr = executor.runDetached(
        allocator,
        executor.Policy{ .workspace_root = "." },
        "python",
        &.{ "-c", "import time; time.sleep(6)" },
        ".",
    ) catch |e| {
        // Sin python en el PATH no hay nada que medir. Se OMITE en vez de pasar
        // en falso: un test que aprueba sin haber medido nada es peor que no
        // tenerlo (R14). QA-A H3: pero solo si falta; si no arranca, rojo.
        return omitirSiFalta(e, "python");
    };

    try std.testing.expect(dr.pid != 0);

    // OpenProcess sobre un PID muerto devuelve un handle nulo.
    const PROCESS_QUERY_LIMITED_INFORMATION: u32 = 0x1000;
    const PROCESS_TERMINATE: u32 = 0x0001;
    const h = OpenProcess(PROCESS_QUERY_LIMITED_INFORMATION | PROCESS_TERMINATE, 0, dr.pid);
    const vivo = @intFromPtr(h) != 0;
    if (vivo) {
        // Se limpia lo que este test dejo vivo: un test que deja procesos
        // sueltos acaba siendo el motivo por el que otro falla.
        _ = TerminateProcess(h, 0);
        _ = CloseHandle(h);
    }
    try std.testing.expect(vivo);
}

test "H2: el hijo recibe una entrada estandar REAL y la lee entera" {
    // Antes, `si.hStdInput = INVALID_HANDLE_VALUE`: no habia entrada, y el
    // primer `input()` moria con EOFError sin llegar a imprimir nada. Aqui se
    // comprueba contra un proceso de VERDAD que lo que pone `Policy.stdin_data`
    // llega al otro lado, y que el cierre de la tuberia produce el EOF que
    // permite a `read()` terminar.
    if (builtin.os.tag != .windows) return @import("platform.zig").skip("T9: la carpeta de prueba se crea con GetTempPathA/CreateDirectoryA (Win32); omitida en Linux");
    const allocator = std.testing.allocator;

    // Una carpeta propia bajo el TEMP del sistema: el sandbox exige que el cwd
    // este dentro de `workspace_root`, y ambos son la misma ruta absoluta aqui.
    const cwd = try carpetaDePrueba(allocator, "beats-h2");
    defer allocator.free(cwd);
    defer _ = RemoveDirectoryA(cwd.ptr);

    const r = runGoverned(
        allocator,
        .{ .workspace_root = cwd, .timeout_ms = 15_000, .stdin_data = "hola-desde-stdin" },
        "python",
        &.{ "-c", "import sys; sys.stdout.write('ECO:' + sys.stdin.read())" },
        cwd,
        null,
        null,
        null,
    ) catch |e| {
        // Sin Python en el PATH este test no puede decir nada, y aprobar sin
        // haber probado seria peor que saltarselo. QA-A H3: solo si falta.
        return omitirSiFalta(e, "python");
    };
    defer r.deinit(allocator);

    try exigirExito(r, "python");
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "ECO:hola-desde-stdin") != null);
}

test "H2: sin datos, la entrada existe igual y se cierra en el acto (EOF limpio)" {
    // El matiz que hace la diferencia: `stdin_data` vacio NO es lo mismo que no
    // tener entrada. Un `sys.stdin.read()` sobre una tuberia cerrada devuelve
    // cadena vacia; sobre un handle invalido, revienta.
    if (builtin.os.tag != .windows) return @import("platform.zig").skip("T9: la carpeta de prueba se crea con GetTempPathA/CreateDirectoryA (Win32); omitida en Linux");
    const allocator = std.testing.allocator;

    // Una carpeta propia bajo el TEMP del sistema: el sandbox exige que el cwd
    // este dentro de `workspace_root`, y ambos son la misma ruta absoluta aqui.
    const cwd = try carpetaDePrueba(allocator, "beats-h2");
    defer allocator.free(cwd);
    defer _ = RemoveDirectoryA(cwd.ptr);

    const r = runGoverned(
        allocator,
        .{ .workspace_root = cwd, .timeout_ms = 15_000 },
        "python",
        &.{ "-c", "import sys; d = sys.stdin.read(); sys.stdout.write('VACIO' if d == '' else 'ALGO')" },
        cwd,
        null,
        null,
        null,
    ) catch |e| return omitirSiFalta(e, "python");
    defer r.deinit(allocator);

    try exigirExito(r, "python");
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "VACIO") != null);
    try std.testing.expect(r.stderr.len == 0);
}

test "H2: entrada grande (mayor que buffer de tuberia de 4KB) no se interbloquea" {
    if (builtin.os.tag != .windows) return @import("platform.zig").skip("T9: comprueba el bufer de 4 KB de la tuberia anonima de Windows con carpeta Win32; omitida en Linux");
    const allocator = std.testing.allocator;

    const cwd = try carpetaDePrueba(allocator, "beats-h2-large");
    defer allocator.free(cwd);
    defer _ = RemoveDirectoryA(cwd.ptr);

    // 16 KB de datos (supera con creces el búfer de 4 KB de Windows anonymous pipe)
    const large_payload = try allocator.alloc(u8, 16 * 1024);
    defer allocator.free(large_payload);
    @memset(large_payload, 'A');

    const r = runGoverned(
        allocator,
        .{ .workspace_root = cwd, .timeout_ms = 15_000, .stdin_data = large_payload },
        "python",
        &.{ "-c", "import sys; data = sys.stdin.read(); sys.stdout.write(f'LEN:{len(data)}')" },
        cwd,
        null,
        null,
        null,
    ) catch |e| return omitirSiFalta(e, "python");
    defer r.deinit(allocator);

    try exigirExito(r, "python");
    try std.testing.expect(std.mem.indexOf(u8, r.stdout, "LEN:16384") != null);
}

test "E-123: la salida OEM de cmd o PowerShell llega como UTF-8; la que ya es UTF-8 no se toca" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const a = std.testing.allocator;
    // «término» en la página 850/437: la é es 0x82.
    const oem = "El t\x82rmino 'x' no se reconoce";
    const u = try oemAUtf8(a, oem);
    defer a.free(u);
    try std.testing.expect(std.unicode.utf8ValidateSlice(u));
    const cp = GetOEMCP();
    if (cp == 850 or cp == 437) try std.testing.expectEqualStrings("El término 'x' no se reconoce", u);

    // Por runGoverned: un stderr en OEM sale convertido, el stdout UTF-8 intacto.
    const Oem = struct {
        fn spawn(al: std.mem.Allocator, _: []const u8, _: []const []const u8, _: []const u8, _: u32, _: usize, _: ?executor.StreamSink, _: ?*anyopaque, _: []const u8) !executor.RunResult {
            return .{
                .exit_code = 1,
                .stdout = try al.dupe(u8, "acción ya en UTF-8"),
                .stderr = try al.dupe(u8, "El t\x82rmino 'x' no se reconoce"),
            };
        }
    };
    const r = try executor.runGoverned(a, executor.Policy{}, "zig", &.{"--version"}, "devagents-workspace\\orden-1", Oem.spawn, null, null);
    defer r.deinit(a);
    try std.testing.expectEqualStrings("acción ya en UTF-8", r.stdout);
    try std.testing.expect(std.unicode.utf8ValidateSlice(r.stderr));
    if (cp == 850 or cp == 437) try std.testing.expectEqualStrings("El término 'x' no se reconoce", r.stderr);
}

test "E-123: un UTF-8 cortado al final del trozo no se confunde con OEM" {
    const entero = "acci\xc3\xb3n";
    try std.testing.expect(utf8ConColaCortada(entero[0 .. entero.len - 2]));
    try std.testing.expect(!utf8ConColaCortada("t\x82rmino"));
    try std.testing.expect(!utf8ConColaCortada("ascii puro"));
}

test "SEC2 batch real preserves argv and never executes a second command" {
    if (builtin.os.tag != .windows) return @import("platform.zig").skip("T9: la inyeccion por lotes .cmd (cmd.exe, %~dp0, ^) es de Windows; omitida en Linux");
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "ruta & (hostil)");
    const cwd = try tmp.dir.realPathFileAlloc(io, "ruta & (hostil)", a);
    defer a.free(cwd);
    var dir = try tmp.dir.openDir(io, "ruta & (hostil)", .{});
    defer dir.close(io);
    const python = try resolveAllowedExe(a, "python");
    defer a.free(python);
    const fixture = try std.fmt.allocPrint(a, "@echo off\r\n\"{s}\" \"%~dp0argv.py\" %*\r\n", .{python});
    defer a.free(fixture);
    try dir.writeFile(io, .{ .sub_path = "argv.cmd", .data = fixture });
    try dir.writeFile(io, .{ .sub_path = "argv.py", .data = "import json,sys,pathlib\ns=json.dumps(sys.argv[1:],ensure_ascii=True)\npathlib.Path('argv.json').write_text(s,encoding='utf-8')\nprint(s)\n" });
    const shim = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "argv.cmd", .{cwd});
    defer a.free(shim);
    const argv = &[_][]const u8{ "a & | ^ < > ( )", "ok & echo PWN > injected.txt", "C:\\ruta & (x)\\中文", "", "final^", "^", "^^", "space final ^" };
    const result = try runVerifierPinned(a, .{ .workspace_root = cwd }, shim, argv, cwd);
    defer result.deinit(a);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    const parsed = try std.json.parseFromSlice([][]const u8, a, std.mem.trim(u8, result.stdout, "\r\n "), .{});
    defer parsed.deinit();
    try std.testing.expectEqual(argv.len, parsed.value.len);
    for (argv, parsed.value) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    try std.testing.expectError(error.FileNotFound, dir.access(io, "injected.txt", .{}));
    try dir.deleteFile(io, "argv.json");
    const shim_z = try a.dupeZ(u8, shim);
    defer a.free(shim_z);
    const detached = try createDetachedPinned(a, shim_z, argv, cwd);
    defer _ = CloseHandle(detached.hThread);
    defer {
        _ = TerminateProcess(detached.hProcess, 1);
        _ = WaitForSingleObject(detached.hProcess, 5000);
        _ = CloseHandle(detached.hProcess);
    }
    try std.testing.expectEqual(@as(u32, 0), WaitForSingleObject(detached.hProcess, 15000));
    const recorded = try dir.readFileAlloc(io, "argv.json", a, .limited(8192));
    defer a.free(recorded);
    const detached_argv = try std.json.parseFromSlice([][]const u8, a, recorded, .{});
    defer detached_argv.deinit();
    try std.testing.expectEqual(argv.len, detached_argv.value.len);
    for (argv, detached_argv.value) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    for ([_][]const u8{ "%VAR% & echo PWN > injected.txt", "%%", "!x!", "\" & echo PWN > injected.txt", "\"%VAR%\"", "text\"%PATH% & injected", "a\nb", "trail\\", "C:\\folder\\" }) |arg| {
        try std.testing.expectError(error.UnsafeBatchArgument, runVerifierPinned(a, .{ .workspace_root = cwd }, shim, &.{arg}, cwd));
        try std.testing.expectError(error.UnsafeBatchArgument, createDetachedPinned(a, shim_z, &.{arg}, cwd));
    }
    try std.testing.expectError(error.FileNotFound, dir.access(io, "injected.txt", .{}));
}

test "SEC2 pre hook failure exposes its cause before command spawn" {
    defer hooks.reset();
    try hooks.applyJson(std.testing.allocator,
        \\{"enabled":true,"preCommand":{"exe":"sec2-hook-does-not-exist","argv":[]}}
    );
    try std.testing.expectError(error.HookExecutableNotResolved, runGoverned(std.testing.allocator, .{ .workspace_root = "." }, "zig", &.{"version"}, ".", null, null, null));
}

const StartupEnv = struct {
    name: [:0]const u8,
    old: ?[:0]u8,
    fn set(a: std.mem.Allocator, name: [:0]const u8, value: []const u8) !StartupEnv {
        const old = getEnvAlloc(a, name) catch |err| switch (err) {
            error.EnvNotFound => null,
            else => return err,
        };
        errdefer if (old) |v| a.free(v);
        const z = try a.dupeZ(u8, value);
        defer a.free(z);
        if (SetEnvironmentVariableA(name.ptr, z.ptr) == 0) return error.EnvSetFailed;
        return .{ .name = name, .old = old };
    }
    fn restore(self: StartupEnv, a: std.mem.Allocator) void {
        std.debug.assert(SetEnvironmentVariableA(self.name.ptr, if (self.old) |v| v.ptr else null) != 0);
        if (self.old) |v| a.free(v);
    }
};

test "SEC2 startup Python actual child ignores environment and user site, clock imports survive" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(cwd);
    try tmp.dir.createDirPath(io, "injection");
    try tmp.dir.writeFile(io, .{ .sub_path = "injection/sitecustomize.py", .data = "from pathlib import Path\nPath('site-marker').write_text('injected')\n" });
    // usercustomize/.pth en el user-site fingido por PYTHONUSERBASE: -E/-s y el
    // filtro de entorno deben dejarlos sin cargar (marcadores user-* ausentes).
    try tmp.dir.writeFile(io, .{ .sub_path = "injection/usercustomize.py", .data = "from pathlib import Path\nPath('user-marker').write_text('injected')\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "injection/evil.pth", .data = "import pathlib; pathlib.Path('pth-marker').write_text('injected')\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "startup.py", .data = "from pathlib import Path\nPath('startup-marker').write_text('injected')\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "local_clock.py", .data = "value=42\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "analog_clock.py", .data = "import sys,site,tkinter,local_clock\nfrom pathlib import Path\nassert sys.flags.ignore_environment and sys.flags.no_user_site\nassert site.ENABLE_USER_SITE is False\nassert local_clock.value == 42\nPath('clock-marker').write_text('ok')\nprint('CLOCK_OK')\n" });
    const injection = try std.fs.path.join(a, &.{ cwd, "injection" });
    defer a.free(injection);
    const startup = try std.fs.path.join(a, &.{ cwd, "startup.py" });
    defer a.free(startup);
    const path_env = try StartupEnv.set(a, "PYTHONPATH", injection);
    defer path_env.restore(a);
    const startup_env = try StartupEnv.set(a, "PYTHONSTARTUP", startup);
    defer startup_env.restore(a);
    const inspect_env = try StartupEnv.set(a, "PYTHONINSPECT", "1");
    defer inspect_env.restore(a);
    const userbase_env = try StartupEnv.set(a, "PYTHONUSERBASE", injection);
    defer userbase_env.restore(a);
    const result = try runGoverned(a, .{ .workspace_root = cwd }, "python", &.{"analog_clock.py"}, cwd, null, null, null);
    defer result.deinit(a);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "CLOCK_OK") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "site-marker", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "startup-marker", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "user-marker", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "pth-marker", .{}));
    try tmp.dir.deleteFile(io, "clock-marker");
    const detached = try runDetached(a, .{ .workspace_root = cwd }, "python", &.{"analog_clock.py"}, cwd);
    const child = OpenProcess(0x101001, 0, detached.pid);
    if (@intFromPtr(child) != 0) {
        defer _ = CloseHandle(child);
        defer {
            _ = TerminateProcess(child, 1);
            _ = WaitForSingleObject(child, 5000);
        }
        try std.testing.expectEqual(@as(u32, 0), WaitForSingleObject(child, 15000));
        var code: u32 = 1;
        try std.testing.expect(GetExitCodeProcess(child, &code) != 0);
        try std.testing.expectEqual(@as(u32, 0), code);
    }
    try tmp.dir.access(io, "clock-marker", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "site-marker", .{}));
    const approved = try runGoverned(a, .{ .workspace_root = cwd }, "python", &.{ "-c", "import os; assert not any(k in os.environ for k in ('PYTHONPATH','PYTHONSTARTUP','PYTHONINSPECT','PYTHONUSERBASE')); print('APPROVED_ENV_OK')" }, cwd, null, null, null);
    defer approved.deinit(a);
    try std.testing.expectEqual(@as(i32, 0), approved.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, approved.stdout, "APPROVED_ENV_OK") != null);
    try tmp.dir.deleteFile(io, "clock-marker");
    defer hooks.reset();
    try hooks.applyJson(a, "{\"enabled\":true,\"preCommand\":{\"exe\":\"python\",\"argv\":[\"analog_clock.py\"]}}");
    try hooks.check(a, .pre_command, "", "python", cwd);
    try tmp.dir.access(io, "clock-marker", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "site-marker", .{}));
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "startup-marker", .{}));
    std.debug.print("PYTHON_STARTUP: capture/detached/hooks=ok; -E/-s/local imports/tkinter=ok; approved environment=clean; injection markers=absent\n", .{});
}

test "CK-SEG-020 actual command child receives approval guard" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: lanza cmd.exe o un lote .cmd/.bat (Windows)");
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(cwd);
    const result = try spawnWin32Cancellable(a, "cmd.exe", &.{ "/d", "/c", "set DEVAGENTS_COMMAND_CHILD" }, cwd, 10000, 4096, null, null, "", null, null);
    defer result.deinit(a);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "DEVAGENTS_COMMAND_CHILD=1") != null);
}

test "SEC2 startup Node actual capture and detached never preload environment marker" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(cwd);
    const node = try resolveAllowedExe(a, "node");
    defer a.free(node);
    try tmp.dir.writeFile(io, .{ .sub_path = "marker.cjs", .data = "require('fs').writeFileSync('node-injection-marker','bad');\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "main.js", .data = "require('fs').writeFileSync('node-main-marker','ok'); console.log('NODE_OK');\n" });
    const marker = try std.fs.path.join(a, &.{ cwd, "marker.cjs" });
    defer a.free(marker);
    const options = try std.fmt.allocPrint(a, "--require \"{s}\"", .{marker});
    defer a.free(options);
    const env = try StartupEnv.set(a, "NODE_OPTIONS", options);
    defer env.restore(a);
    const result = try runVerifierPinned(a, .{ .workspace_root = cwd }, node, &.{"main.js"}, cwd);
    defer result.deinit(a);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "NODE_OK") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "node-injection-marker", .{}));
    try tmp.dir.deleteFile(io, "node-main-marker");
    const child = try createDetachedPinned(a, node, &.{"main.js"}, cwd);
    defer _ = CloseHandle(child.hThread);
    defer _ = CloseHandle(child.hProcess);
    defer {
        _ = TerminateProcess(child.hProcess, 1);
        _ = WaitForSingleObject(child.hProcess, 5000);
    }
    try std.testing.expectEqual(@as(u32, 0), WaitForSingleObject(child.hProcess, 15000));
    try tmp.dir.access(io, "node-main-marker", .{});
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "node-injection-marker", .{}));
    std.debug.print("NODE_STARTUP: capture/detached=ok; NODE_OPTIONS --require marker=absent\n", .{});
}

test "SEC2 startup PowerShell actual profile marker and restrictive ExecutionPolicy" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: perfil y ExecutionPolicy de PowerShell (Windows)");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const cwd = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(cwd);
    const installed = try resolveAllowedExe(a, "pwsh");
    defer a.free(installed);
    try tmp.dir.createDirPath(io, "pwsh");
    var runtime = try std.Io.Dir.openDirAbsolute(io, std.fs.path.dirname(installed).?, .{ .iterate = true });
    defer runtime.close(io);
    var copy = try tmp.dir.openDir(io, "pwsh", .{});
    defer copy.close(io);
    var it = runtime.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or std.ascii.endsWithIgnoreCase(entry.name, ".ps1")) continue;
        try runtime.copyFile(entry.name, copy, entry.name, io, .{});
    }
    try copy.writeFile(io, .{ .sub_path = "profile.ps1", .data = "[IO.File]::WriteAllText($env:SEC2_PROFILE_MARKER, 'profile ran')\n" });
    const pwsh = try tmp.dir.realPathFileAlloc(io, "pwsh/pwsh.exe", a);
    defer a.free(pwsh);
    const marker = try std.fs.path.join(a, &.{ cwd, "profile-marker" });
    defer a.free(marker);
    const env = try StartupEnv.set(a, "SEC2_PROFILE_MARKER", marker);
    defer env.restore(a);
    try tmp.dir.writeFile(io, .{ .sub_path = "main.ps1", .data = "[Console]::WriteLine('PS_OK')\n" });
    // Control positivo: el mismo runtime y perfil realmente crean el marcador.
    const positive = try runVerifierPinned(a, .{ .workspace_root = cwd }, pwsh, &.{ "-NonInteractive", "-File", "main.ps1" }, cwd);
    defer positive.deinit(a);
    try std.testing.expectEqual(@as(i32, 0), positive.exit_code);
    try tmp.dir.access(io, "profile-marker", .{});
    try tmp.dir.deleteFile(io, "profile-marker");
    const args = &[_][]const u8{ "-NoProfile", "-NonInteractive", "-File", "main.ps1" };
    try std.testing.expectEqual(command_policy.Decision.exempt, command_policy.decide("pwsh", args, &.{}, .{ .allocator = a, .workspace_root = cwd, .cwd = cwd }));
    const result = try runVerifierPinned(a, .{ .workspace_root = cwd }, pwsh, args, cwd);
    defer result.deinit(a);
    try std.testing.expectEqual(@as(i32, 0), result.exit_code);
    try std.testing.expect(std.mem.indexOf(u8, result.stdout, "PS_OK") != null);
    try std.testing.expectError(error.FileNotFound, tmp.dir.access(io, "profile-marker", .{}));
    const restricted = try runGoverned(a, .{ .workspace_root = cwd }, "powershell", &.{ "-NoProfile", "-NonInteractive", "-ExecutionPolicy", "Restricted", "-File", "main.ps1" }, cwd, null, null, null);
    defer restricted.deinit(a);
    std.debug.print("POWERSHELL_STARTUP: profile positive=created; -NoProfile marker=absent; restricted exit={d}\n{s}\n", .{ restricted.exit_code, restricted.stderr });
    try std.testing.expect(restricted.exit_code != 0);
    try std.testing.expect(std.mem.indexOf(u8, restricted.stderr, "SecurityError") != null);
    try std.testing.expect(std.mem.indexOf(u8, restricted.stderr, "UnauthorizedAccess") != null);
}

// ── T9 (, motor): ejecucion gobernada en Linux ─────────────────
//
// Mismo contrato que spawnWin32Pinned: binario fijado por ruta absoluta, cwd,
// entorno filtrado por command_environment (sin LD_PRELOAD, NODE_OPTIONS...),
// tope de salida, timeout y cancelacion de la orden. La contencion la hace
// governed_posix.c: cgroup v2 delegado si existe (memoria, pids, cgroup.kill)
// o `posix_partial` (grupo de procesos + setrlimit) diciendolo en el resultado.

const LinuxLimits = extern struct { process_memory: u64, job_memory: u64, pids: u32, timeout_ms: u32 };
const LinuxResult = extern struct { code: c_int, timed_out: c_int, cancelled: c_int, mode: c_int };
extern fn beats_governed_run(
    argv: [*:null]const ?[*:0]const u8,
    envp: [*:null]const ?[*:0]const u8,
    cwd: [*:0]const u8,
    limits: *const LinuxLimits,
    input: [*]const u8,
    len: usize,
    output: *const fn (?*anyopaque, [*]const u8, usize, c_int) callconv(.c) c_int,
    out_ctx: ?*anyopaque,
    cancel: *const fn (?*anyopaque) callconv(.c) c_int,
    cancel_ctx: ?*anyopaque,
    force_partial: c_int,
    result: *LinuxResult,
) c_int;

const LinuxCapture = struct {
    allocator: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    err: std.ArrayList(u8) = .empty,
    totals: [2]usize = .{ 0, 0 },
    cap: usize,
    sink: ?StreamSink,
    sink_ctx: ?*anyopaque,
    cancel_fn: ?*const fn (?*anyopaque) bool,
    cancel_ctx: ?*anyopaque,
    failed: bool = false,

    fn chunk(ctx: ?*anyopaque, bytes: [*]const u8, len: usize, kind: c_int) callconv(.c) c_int {
        const self: *LinuxCapture = @ptrCast(@alignCast(ctx.?));
        const index: usize = if (kind == 0) 0 else 1;
        self.totals[index] +|= len;
        const list = if (kind == 0) &self.out else &self.err;
        const data = bytes[0..len];
        list.appendSlice(self.allocator, data[0..@min(len, self.cap - @min(self.cap, list.items.len))]) catch {
            self.failed = true;
            return -1;
        };
        if (self.sink) |sink| sink(self.sink_ctx, data, if (kind == 0) .stdout else .stderr);
        return 0;
    }

    fn cancelled(ctx: ?*anyopaque) callconv(.c) c_int {
        const self: *LinuxCapture = @ptrCast(@alignCast(ctx.?));
        return if (self.cancel_fn) |check| @intFromBool(check(self.cancel_ctx)) else 0;
    }
};

fn spawnLinux(
    a: std.mem.Allocator,
    exe: [:0]const u8,
    args: []const []const u8,
    cwd: []const u8,
    timeout: u32,
    cap: usize,
    sink: ?StreamSink,
    sink_ctx: ?*anyopaque,
    input: []const u8,
    limits: JobLimits,
    environment: ?[:0]const u16,
    is_cancelled_fn: ?*const fn (?*anyopaque) bool,
    cancelled_ctx: ?*anyopaque,
    force_partial: bool,
) ExecutorError!RunResult {
    if (!std.fs.path.isAbsolutePosix(exe)) return error.ExeNotResolved;
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    const argv = arena.allocSentinel(?[*:0]const u8, args.len + 1, null) catch return error.OutOfMemory;
    argv[0] = exe.ptr;
    for (args, 1..) |arg, index| {
        if (std.mem.indexOfScalar(u8, arg, 0) != null) return error.InvalidPath;
        argv[index] = (arena.dupeZ(u8, arg) catch return error.OutOfMemory).ptr;
    }
    if (std.mem.indexOfScalar(u8, cwd, 0) != null) return error.InvalidPath;
    const cwd_z = arena.dupeZ(u8, cwd) catch return error.OutOfMemory;
    const env_block = try command_environment.build(arena, environment);
    const envp = try command_environment.toEnvp(arena, env_block);
    var capture: LinuxCapture = .{ .allocator = a, .cap = cap, .sink = sink, .sink_ctx = sink_ctx, .cancel_fn = is_cancelled_fn, .cancel_ctx = cancelled_ctx };
    defer capture.out.deinit(a);
    defer capture.err.deinit(a);
    const native_limits: LinuxLimits = .{
        .process_memory = limits.process_memory,
        .job_memory = limits.job_memory,
        .pids = limits.active_processes,
        .timeout_ms = if (timeout == 0) 1 else timeout,
    };
    var native: LinuxResult = undefined;
    const rc = beats_governed_run(argv.ptr, envp.ptr, cwd_z.ptr, &native_limits, input.ptr, input.len, LinuxCapture.chunk, &capture, LinuxCapture.cancelled, &capture, @intFromBool(force_partial), &native);
    if (capture.failed) return error.OutOfMemory;
    if (rc != 0) return error.SpawnFailed;
    const out = capture.out.toOwnedSlice(a) catch return error.OutOfMemory;
    errdefer a.free(out);
    const err = capture.err.toOwnedSlice(a) catch return error.OutOfMemory;
    return .{
        .exit_code = if (native.cancelled != 0) 130 else native.code,
        .stdout = out,
        .stderr = err,
        .timed_out = native.timed_out != 0,
        .cancelled = native.cancelled != 0,
        .containment_mode = if (native.mode == 1) .linux_cgroup_v2 else .posix_partial,
        .stdout_total_bytes = capture.totals[0],
        .stderr_total_bytes = capture.totals[1],
    };
}

/// Busca `base` en los directorios ABSOLUTOS del PATH (nunca el cwd) y exige
/// un archivo regular ejecutable. `python` cae a `python3` si no existe.
fn resolvePosixExe(a: std.mem.Allocator, base: []const u8) ExecutorError![:0]u8 {
    if (base.len == 0 or std.mem.indexOfAny(u8, base, "/\\\x00") != null) return error.ExeNotResolved;
    const raw = std.c.getenv("PATH") orelse return error.ExeNotResolved;
    var paths = std.mem.splitScalar(u8, std.mem.span(raw), ':');
    while (paths.next()) |dir| {
        if (!std.fs.path.isAbsolutePosix(dir)) continue;
        const candidate = std.fs.path.joinZ(a, &.{ dir, base }) catch return error.OutOfMemory;
        const meta = @import("providers").posix_stat.get(std.c.AT.FDCWD, candidate) catch {
            a.free(candidate);
            continue;
        };
        // posix_stat con ruta no sigue el enlace final: se acepta el enlace si
        // su destino es ejecutable (p. ej. /usr/bin/python3 -> python3.12).
        if ((meta.mode & std.c.S.IFMT == std.c.S.IFREG or meta.mode & std.c.S.IFMT == std.c.S.IFLNK) and std.c.access(candidate, std.c.X_OK) == 0) return candidate;
        a.free(candidate);
    }
    if (std.mem.eql(u8, base, "python")) return resolvePosixExe(a, "python3");
    return error.ExeNotResolved;
}

const PosixDetached = struct { threaded: std.Io.Threaded, child: std.process.Child };

/// App independiente (sin captura): mismo binario fijado y entorno filtrado;
/// un hilo la recoge al terminar para que no quede zombi.
fn detachedPosix(a: std.mem.Allocator, exe_abs: [:0]const u8, args: []const []const u8, cwd: []const u8) ExecutorError!DetachedResult {
    if (builtin.os.tag != .linux) return error.ExecutionDisabled;
    const page = std.heap.page_allocator;
    const ctx = page.create(PosixDetached) catch return error.OutOfMemory;
    errdefer page.destroy(ctx);
    ctx.threaded = .init(page, .{});
    errdefer ctx.threaded.deinit();
    const argv = a.alloc([]const u8, args.len + 1) catch return error.OutOfMemory;
    defer a.free(argv);
    argv[0] = exe_abs;
    @memcpy(argv[1..], args);
    var arena_state = std.heap.ArenaAllocator.init(a);
    defer arena_state.deinit();
    const block = try command_environment.build(arena_state.allocator(), null);
    var env_map = std.process.Environ.Map.init(arena_state.allocator());
    const envp = try command_environment.toEnvp(arena_state.allocator(), block);
    for (envp) |entry| {
        const text = std.mem.span(entry.?);
        const eq = std.mem.indexOfScalar(u8, text, '=') orelse continue;
        env_map.put(text[0..eq], text[eq + 1 ..]) catch return error.OutOfMemory;
    }
    ctx.child = std.process.spawn(ctx.threaded.io(), .{
        .argv = argv,
        .cwd = .{ .path = cwd },
        .environ_map = &env_map,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
        .pgid = 0,
    }) catch return error.SpawnFailed;
    errdefer ctx.child.kill(ctx.threaded.io());
    const pid: u32 = @intCast(ctx.child.id.?);
    const thread = std.Thread.spawn(.{}, waitDetachedPosix, .{ctx}) catch return error.SpawnFailed;
    thread.detach();
    return .{ .pid = pid };
}

fn waitDetachedPosix(ctx: *PosixDetached) void {
    _ = ctx.child.wait(ctx.threaded.io()) catch |e| {
        std.log.err("POSIX detached wait: {s}", .{@errorName(e)});
        ctx.child.kill(ctx.threaded.io());
    };
    ctx.threaded.deinit();
    std.heap.page_allocator.destroy(ctx);
}

fn replaceInvalidUtf8(a: std.mem.Allocator, bytes: []const u8) ![]u8 {
    if (std.unicode.utf8ValidateSlice(bytes)) return a.dupe(u8, bytes);
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(a);
    var i: usize = 0;
    while (i < bytes.len) {
        const len = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
            try out.appendSlice(a, "\u{FFFD}");
            i += 1;
            continue;
        };
        if (i + len <= bytes.len and std.unicode.utf8ValidateSlice(bytes[i .. i + len])) {
            try out.appendSlice(a, bytes[i .. i + len]);
            i += len;
        } else {
            try out.appendSlice(a, "\u{FFFD}");
            i += 1;
        }
    }
    return out.toOwnedSlice(a);
}

test "T9 POSIX executor: fixed path, filtered environment, timeout and partial containment" {
    if (builtin.os.tag != .linux) return @import("platform.zig").skip("T9: ejecucion gobernada POSIX (governed_posix.c); Windows la cubren las pruebas del job object");
    const a = std.testing.allocator;
    const sh = try resolvePosixExe(a, "sh");
    defer a.free(sh);
    try std.testing.expect(std.fs.path.isAbsolutePosix(sh));
    const ok = try spawnLinux(a, sh, &.{ "-c", "printf T9_OK; printf err >&2; test -z \"$LD_PRELOAD\" && printf :$DEVAGENTS_COMMAND_CHILD" }, "/tmp", 10_000, 4096, null, null, "", .{}, null, null, null, true);
    defer ok.deinit(a);
    try std.testing.expectEqual(@as(i32, 0), ok.exit_code);
    try std.testing.expectEqualStrings("T9_OK:1", ok.stdout);
    try std.testing.expectEqualStrings("err", ok.stderr);
    try std.testing.expectEqual(@import("containment.zig").Mode.posix_partial, ok.containment_mode);
    const slow = try spawnLinux(a, sh, &.{ "-c", "sleep 30" }, "/tmp", 200, 4096, null, null, "", .{}, null, null, null, true);
    defer slow.deinit(a);
    try std.testing.expect(slow.timed_out);
    const fixed = try oemAUtf8(a, "ok\xff");
    defer a.free(fixed);
    try std.testing.expectEqualStrings("ok\u{FFFD}", fixed);
}
