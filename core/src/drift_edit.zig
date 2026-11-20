//! core/src/drift_edit.zig — H7: edición que tolera que el archivo se haya movido.
//!
//! El problema, tal como estaba: DevAgents solo sabe escribir archivos ENTEROS.
//! Pedirle «cambia el color del botón» obliga al modelo a reemitir el archivo
//! completo, y ahí es donde se pierden cosas — un `<script>` que no vuelve a
//! salir, una función que desaparece, un fichero de 300 líneas que vuelve con
//! 240. La orden acaba `done` y el usuario descubre el destrozo al abrirlo.
//!
//! Lo que falta es poder decir «sustituye ESTE trozo por ESTE otro». Y lo que
//! hace que eso sea difícil de verdad —la «deriva»— es que el trozo que el
//! modelo cree recordar casi nunca coincide byte a byte con el que hay en
//! disco: sobra o falta sangría, la línea de al lado cambió, hay un espacio al
//! final. Un reemplazo exacto falla en cuanto el archivo se mueve un poco.
//!
//! Aquí se busca el ancla en tres pasadas, de la más estricta a la más
//! tolerante, y se PARA en la primera que dé un resultado inequívoco:
//!
//!   1. Coincidencia exacta.
//!   2. Coincidencia por líneas ignorando la sangría y el espacio final.
//!   3. Coincidencia aproximada: la ventana de líneas que más se parece,
//!      siempre que se parezca lo bastante y que ninguna otra se le acerque.
//!
//! La regla que gobierna las tres es la misma y no se negocia: **si hay más de
//! un sitio posible, no se edita nada**. Una edición en el sitio equivocado es
//! peor que una edición que no ocurre, porque la primera se descubre tarde.

const std = @import("std");

/// Marcadores del bloque de edición. Son los que los modelos producen con más
/// fiabilidad, y se eligen en castellano porque el resto de la conversación con
/// el modelo va en castellano.
pub const OPEN_MARKER = "<<<<<<< BUSCAR";
pub const MID_MARKER = "=======";
pub const CLOSE_MARKER = ">>>>>>> REEMPLAZAR";

/// Cuánto se puede parecer «poco» una ventana y aun así aceptarse en la tercera
/// pasada. 0.75 = tres de cada cuatro líneas del ancla tienen que coincidir.
///
/// No es un número de catálogo: por debajo de 0.7 empiezan a colar bloques
/// parecidos pero distintos (dos manejadores de evento con la misma forma), y
/// por encima de 0.85 la pasada aproximada deja de servir para nada porque ya
/// la habría cogido la segunda.
pub const MIN_SIMILARITY: f64 = 0.75;

/// Cuánto tiene que ganar la mejor ventana a la segunda para considerarla
/// inequívoca. Sin este margen, dos bloques casi iguales producían una edición
/// al azar — que es exactamente el fallo que este módulo existe para no tener.
pub const MIN_MARGIN: f64 = 0.10;

pub const Block = struct {
    anchor: []const u8,
    replacement: []const u8,
};

pub const EditError = error{
    /// El ancla no aparece en el archivo ni siquiera de forma aproximada.
    AnchorNotFound,
    /// El ancla encaja en varios sitios y ninguno destaca: no se toca nada.
    AnchorAmbiguous,
    /// El texto trae marcadores pero mal formados (falta el `=======` o el cierre).
    MalformedBlock,
    OutOfMemory,
};

/// ¿Este texto es una edición por bloques, o es un archivo entero?
pub fn looksLikeEdit(text: []const u8) bool {
    return std.mem.indexOf(u8, text, OPEN_MARKER) != null and
        std.mem.indexOf(u8, text, CLOSE_MARKER) != null;
}

/// Extrae los bloques de un texto. El resultado apunta DENTRO de `text`: no
/// copia nada, así que `text` tiene que seguir vivo mientras se usen.
pub fn parseBlocks(allocator: std.mem.Allocator, text: []const u8) EditError![]Block {
    var out = std.ArrayList(Block).empty;
    errdefer out.deinit(allocator);

    var cursor: usize = 0;
    while (std.mem.indexOfPos(u8, text, cursor, OPEN_MARKER)) |open_at| {
        const anchor_start = lineAfter(text, open_at + OPEN_MARKER.len);
        const mid_at = findMarkerLine(text, anchor_start, MID_MARKER) orelse return error.MalformedBlock;
        const repl_start = lineAfter(text, mid_at + MID_MARKER.len);
        const close_at = std.mem.indexOfPos(u8, text, repl_start, CLOSE_MARKER) orelse return error.MalformedBlock;

        try out.append(allocator, .{
            .anchor = trimTrailingNewline(text[anchor_start..mid_at]),
            .replacement = trimTrailingNewline(text[repl_start..close_at]),
        });
        cursor = close_at + CLOSE_MARKER.len;
    }
    if (out.items.len == 0) return error.MalformedBlock;
    return out.toOwnedSlice(allocator);
}

/// Aplica todos los bloques en orden. O salen todos, o no sale ninguno: si uno
/// falla se devuelve el error y el contenido original queda intacto, porque
/// dejar un archivo a medio editar es la peor de las tres opciones.
pub fn apply(allocator: std.mem.Allocator, content: []const u8, blocks: []const Block) EditError![]u8 {
    var actual = try allocator.dupe(u8, content);
    errdefer allocator.free(actual);

    for (blocks) |block| {
        const span = try locate(allocator, actual, block.anchor);
        const nuevo = try std.mem.concat(allocator, u8, &.{
            actual[0..span.start],
            block.replacement,
            actual[span.end..],
        });
        allocator.free(actual);
        actual = nuevo;
    }
    return actual;
}

const Span = struct { start: usize, end: usize };

/// Si lo que rodea a la coincidencia hasta el borde de la linea es solo
/// espacio, se sustituye la LINEA ENTERA.
///
/// Sin esto, un ancla `const x = 1;` sobre una linea `    const x = 1;   `
/// dejaba intactos los cuatro espacios de delante; y como el reemplazo que
/// manda el modelo trae su propia sangria, el resultado salia con la sangria
/// duplicada. Cuando el ancla es un trozo DENTRO de una linea con mas codigo
/// (cambiar `rojo` por `azul` en `color: rojo;`) no se extiende nada, que es
/// lo correcto para una edicion parcial.
fn expandToWholeLines(content: []const u8, span: Span) Span {
    var start = span.start;
    while (start > 0 and content[start - 1] != '\n') {
        const c = content[start - 1];
        if (c != ' ' and c != '\t' and c != '\r') return span;
        start -= 1;
    }
    var end = span.end;
    while (end < content.len and content[end] != '\n') {
        const c = content[end];
        if (c != ' ' and c != '\t' and c != '\r') return span;
        end += 1;
    }
    return .{ .start = start, .end = end };
}

/// Las tres pasadas, de estricta a tolerante.
fn locate(allocator: std.mem.Allocator, content: []const u8, anchor: []const u8) EditError!Span {
    if (anchor.len == 0) return error.AnchorNotFound;

    // ── 1. Exacta ────────────────────────────────────────────────────────
    if (std.mem.indexOf(u8, content, anchor)) |at| {
        if (std.mem.indexOfPos(u8, content, at + 1, anchor) != null) return error.AnchorAmbiguous;
        return expandToWholeLines(content, .{ .start = at, .end = at + anchor.len });
    }

    // Para las dos siguientes hace falta ver el archivo y el ancla como listas
    // de líneas, no como cadenas.
    const anchor_lines = try splitLines(allocator, anchor);
    defer allocator.free(anchor_lines);
    const content_lines = try splitLines(allocator, content);
    defer allocator.free(content_lines);
    if (anchor_lines.len == 0 or content_lines.len < anchor_lines.len) return error.AnchorNotFound;

    // ── 2. Por líneas, ignorando sangría y espacio final ─────────────────
    var found: ?usize = null;
    var i: usize = 0;
    while (i + anchor_lines.len <= content_lines.len) : (i += 1) {
        if (windowMatchesTrimmed(content, content_lines[i..][0..anchor_lines.len], anchor, anchor_lines)) {
            if (found != null) return error.AnchorAmbiguous;
            found = i;
        }
    }
    if (found) |at| return spanOfWindow(content_lines[at..][0..anchor_lines.len]);

    // ── 3. Aproximada ────────────────────────────────────────────────────
    var best: f64 = 0;
    var best_at: ?usize = null;
    var second: f64 = 0;
    i = 0;
    while (i + anchor_lines.len <= content_lines.len) : (i += 1) {
        const score = windowSimilarity(content, content_lines[i..][0..anchor_lines.len], anchor, anchor_lines);
        if (score > best) {
            second = best;
            best = score;
            best_at = i;
        } else if (score > second) {
            second = score;
        }
    }
    if (best < MIN_SIMILARITY) return error.AnchorNotFound;
    if (best - second < MIN_MARGIN) return error.AnchorAmbiguous;
    return spanOfWindow(content_lines[best_at.?..][0..anchor_lines.len]);
}

/// Una línea, como posiciones dentro del texto original (para poder devolver
/// desplazamientos reales y no copias).
const Line = struct { start: usize, end: usize };

fn splitLines(allocator: std.mem.Allocator, text: []const u8) error{OutOfMemory}![]Line {
    var out = std.ArrayList(Line).empty;
    errdefer out.deinit(allocator);
    var start: usize = 0;
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] == '\n') {
            try out.append(allocator, .{ .start = start, .end = i });
            start = i + 1;
        }
    }
    if (start <= text.len) try out.append(allocator, .{ .start = start, .end = text.len });
    return out.toOwnedSlice(allocator);
}

fn spanOfWindow(win: []const Line) Span {
    return .{ .start = win[0].start, .end = win[win.len - 1].end };
}

/// `\r` incluido: un archivo con finales de línea de Windows editado con un
/// ancla escrita por un modelo (que casi siempre usa `\n`) no debe fallar por
/// eso solo.
fn trimLine(text: []const u8, line: Line) []const u8 {
    return std.mem.trim(u8, text[line.start..line.end], " \t\r");
}

fn windowMatchesTrimmed(content: []const u8, win: []const Line, anchor: []const u8, anchor_lines: []const Line) bool {
    for (win, anchor_lines) |cl, al| {
        if (!std.mem.eql(u8, trimLine(content, cl), trimLine(anchor, al))) return false;
    }
    return true;
}

fn windowSimilarity(content: []const u8, win: []const Line, anchor: []const u8, anchor_lines: []const Line) f64 {
    var iguales: usize = 0;
    for (win, anchor_lines) |cl, al| {
        if (std.mem.eql(u8, trimLine(content, cl), trimLine(anchor, al))) iguales += 1;
    }
    return @as(f64, @floatFromInt(iguales)) / @as(f64, @floatFromInt(anchor_lines.len));
}

fn lineAfter(text: []const u8, from: usize) usize {
    var i = from;
    while (i < text.len and text[i] != '\n') : (i += 1) {}
    return if (i < text.len) i + 1 else text.len;
}

/// Busca el marcador COMO LÍNEA COMPLETA. `=======` puede aparecer dentro del
/// código (un separador en un comentario, por ejemplo); solo cuenta si ocupa su
/// propia línea, que es como lo escriben los modelos.
fn findMarkerLine(text: []const u8, from: usize, marker: []const u8) ?usize {
    var cursor = from;
    while (std.mem.indexOfPos(u8, text, cursor, marker)) |at| {
        const empieza_linea = at == 0 or text[at - 1] == '\n';
        const fin = at + marker.len;
        const acaba_linea = fin >= text.len or text[fin] == '\n' or text[fin] == '\r';
        if (empieza_linea and acaba_linea) return at;
        cursor = at + marker.len;
    }
    return null;
}

fn trimTrailingNewline(text: []const u8) []const u8 {
    var out = text;
    while (out.len > 0 and (out[out.len - 1] == '\n' or out[out.len - 1] == '\r')) out = out[0 .. out.len - 1];
    return out;
}

// ── Tests ──────────────────────────────────────────────────────────────

const t = std.testing;

test "H7: un bloque bien formado se parte en ancla y reemplazo" {
    const texto =
        "<<<<<<< BUSCAR\n" ++
        "  const color = 'rojo';\n" ++
        "=======\n" ++
        "  const color = 'azul';\n" ++
        ">>>>>>> REEMPLAZAR\n";
    const blocks = try parseBlocks(t.allocator, texto);
    defer t.allocator.free(blocks);
    try t.expectEqual(@as(usize, 1), blocks.len);
    try t.expectEqualStrings("  const color = 'rojo';", blocks[0].anchor);
    try t.expectEqualStrings("  const color = 'azul';", blocks[0].replacement);
}

test "H7: coincidencia exacta" {
    const contenido = "linea uno\nconst color = 'rojo';\nlinea tres\n";
    const blocks = [_]Block{.{ .anchor = "const color = 'rojo';", .replacement = "const color = 'azul';" }};
    const out = try apply(t.allocator, contenido, &blocks);
    defer t.allocator.free(out);
    try t.expectEqualStrings("linea uno\nconst color = 'azul';\nlinea tres\n", out);
}

test "H7: LA DERIVA — el ancla lleva otra sangria y encaja igual" {
    // Es el caso real: el modelo recuerda el bloque sin los cuatro espacios que
    // tiene en el archivo. Un reemplazo exacto fallaria aqui.
    const contenido =
        "function pintar() {\n" ++
        "    const color = 'rojo';\n" ++
        "    aplicar(color);\n" ++
        "}\n";
    const blocks = [_]Block{.{
        .anchor = "const color = 'rojo';\naplicar(color);",
        .replacement = "    const color = 'azul';\n    aplicar(color);",
    }};
    const out = try apply(t.allocator, contenido, &blocks);
    defer t.allocator.free(out);
    try t.expectEqualStrings(
        "function pintar() {\n" ++
            "    const color = 'azul';\n" ++
            "    aplicar(color);\n" ++
            "}\n",
        out,
    );
}

test "H7: la deriva tambien cubre el espacio sobrante al final de linea" {
    const contenido = "a\n  const x = 1;   \nb\n";
    const blocks = [_]Block{.{ .anchor = "const x = 1;", .replacement = "  const x = 2;" }};
    const out = try apply(t.allocator, contenido, &blocks);
    defer t.allocator.free(out);
    try t.expectEqualStrings("a\n  const x = 2;\nb\n", out);
}

test "H7: una linea CAMBIADA dentro del ancla no impide reconocerla" {
    // Cuatro lineas de ancla, una de ellas distinta: 75 % de parecido, justo el
    // minimo. El bloque se reconoce igual porque no hay otro que se le acerque.
    const contenido =
        "inicio\n" ++
        "uno\n" ++
        "dos-CAMBIADO\n" ++
        "tres\n" ++
        "cuatro\n" ++
        "final\n";
    const blocks = [_]Block{.{
        .anchor = "uno\ndos\ntres\ncuatro",
        .replacement = "REEMPLAZADO",
    }};
    const out = try apply(t.allocator, contenido, &blocks);
    defer t.allocator.free(out);
    try t.expectEqualStrings("inicio\nREEMPLAZADO\nfinal\n", out);
}

test "H7: un ancla que aparece DOS veces no edita nada" {
    // La regla que no se negocia. Editar el sitio equivocado se descubre tarde;
    // no editar se descubre en el acto.
    const contenido = "x();\nfoo();\ny();\nfoo();\nz();\n";
    const blocks = [_]Block{.{ .anchor = "foo();", .replacement = "bar();" }};
    try t.expectError(error.AnchorAmbiguous, apply(t.allocator, contenido, &blocks));
}

test "H7: dos bloques casi identicos son AMBIGUOS, no una apuesta" {
    // Cuatro lineas de ancla; las dos ventanas del archivo aciertan tres de
    // cuatro. Empatan POR ENCIMA del umbral, y un empate no se resuelve
    // eligiendo: se resuelve no tocando nada.
    const contenido =
        "boton1.onclick = function () {\n" ++
        "  hacer(1);\n" ++
        "  pintar();\n" ++
        "};\n" ++
        "boton2.onclick = function () {\n" ++
        "  hacer(1);\n" ++
        "  pintar();\n" ++
        "};\n";
    const blocks = [_]Block{.{
        .anchor = "botonX.onclick = function () {\n  hacer(1);\n  pintar();\n};",
        .replacement = "nada",
    }};
    try t.expectError(error.AnchorAmbiguous, apply(t.allocator, contenido, &blocks));
}

test "H7: un ancla que no se parece LO BASTANTE tampoco se coloca" {
    // Dos de tres lineas (0,67) queda por debajo del umbral: ni se edita, ni se
    // reporta como ambiguo — sencillamente no esta.
    const contenido = "boton1.onclick = function () {\n  hacer(1);\n};\n";
    const blocks = [_]Block{.{
        .anchor = "botonX.onclick = function () {\n  hacer(99);\n};",
        .replacement = "nada",
    }};
    try t.expectError(error.AnchorNotFound, apply(t.allocator, contenido, &blocks));
}

test "H7: un ancla que no se parece a nada NO se coloca a la fuerza" {
    const contenido = "alfa\nbeta\ngamma\n";
    const blocks = [_]Block{.{ .anchor = "uno\ndos\ntres", .replacement = "x" }};
    try t.expectError(error.AnchorNotFound, apply(t.allocator, contenido, &blocks));
}

test "H7: varios bloques se aplican en orden sobre el mismo archivo" {
    const contenido = "titulo\ncolor: rojo;\nborde: 1px;\nfin\n";
    const blocks = [_]Block{
        .{ .anchor = "color: rojo;", .replacement = "color: azul;" },
        .{ .anchor = "borde: 1px;", .replacement = "borde: 2px;" },
    };
    const out = try apply(t.allocator, contenido, &blocks);
    defer t.allocator.free(out);
    try t.expectEqualStrings("titulo\ncolor: azul;\nborde: 2px;\nfin\n", out);
}

test "H7: si un bloque falla, el archivo NO queda a medias" {
    const contenido = "color: rojo;\nborde: 1px;\n";
    const blocks = [_]Block{
        .{ .anchor = "color: rojo;", .replacement = "color: azul;" },
        .{ .anchor = "esto-no-existe-en-ningun-sitio", .replacement = "x" },
    };
    try t.expectError(error.AnchorNotFound, apply(t.allocator, contenido, &blocks));
}

test "H7: un archivo entero NO se confunde con una edicion" {
    try t.expect(!looksLikeEdit("<!DOCTYPE html>\n<html></html>\n"));
    try t.expect(looksLikeEdit("<<<<<<< BUSCAR\na\n=======\nb\n>>>>>>> REEMPLAZAR\n"));
}

test "H7: marcadores a medias son un bloque MAL FORMADO, no medio bloque" {
    const texto = "<<<<<<< BUSCAR\nhola\n>>>>>>> REEMPLAZAR\n";
    try t.expectError(error.MalformedBlock, parseBlocks(t.allocator, texto));
}

test "H7: un `=======` DENTRO del codigo no parte el bloque por la mitad" {
    // Un separador de comentario es texto normal; solo cuenta como marcador si
    // ocupa su propia linea entera.
    const texto =
        "<<<<<<< BUSCAR\n" ++
        "// ======= seccion =======\n" ++
        "const a = 1;\n" ++
        "=======\n" ++
        "// ======= seccion =======\n" ++
        "const a = 2;\n" ++
        ">>>>>>> REEMPLAZAR\n";
    const blocks = try parseBlocks(t.allocator, texto);
    defer t.allocator.free(blocks);
    try t.expectEqual(@as(usize, 1), blocks.len);
    try t.expectEqualStrings("// ======= seccion =======\nconst a = 1;", blocks[0].anchor);
    try t.expectEqualStrings("// ======= seccion =======\nconst a = 2;", blocks[0].replacement);
}

test "H7: finales de linea de Windows no rompen la coincidencia" {
    const contenido = "uno\r\nconst x = 1;\r\ntres\r\n";
    const blocks = [_]Block{.{ .anchor = "const x = 1;", .replacement = "const x = 2;" }};
    const out = try apply(t.allocator, contenido, &blocks);
    defer t.allocator.free(out);
    try t.expect(std.mem.indexOf(u8, out, "const x = 2;") != null);
}
