//! core/src/tui/render.zig — (E1): renderizador PURO de la sesión.
//!
//! (b) del encargo: recibe el estado (a) y devuelve el texto exacto de un
//! fotograma para un ancho×alto dados, con color verdadero opcional (NO_COLOR).
//! No imprime, no lee consola y no conoce Windows: la prueba fija el aspecto a
//! 120×40 contra la referencia cli-01.

const std = @import("std");
const state = @import("state.zig");
const progress = @import("progress.zig");

pub const Color = struct { r: u8, g: u8, b: u8 };

/// Paleta exacta de la ESPECIFICACION-REFERENCIAS §«Sistema común».
pub const TEXT = Color{ .r = 0xE4, .g = 0xE0, .b = 0xDA };
pub const SECONDARY = Color{ .r = 0x9A, .g = 0x95, .b = 0x8E };
pub const ACCENT = Color{ .r = 0xD9, .g = 0xD3, .b = 0xC7 };
pub const OK = Color{ .r = 0x79, .g = 0x99, .b = 0x6A };
pub const WARN = Color{ .r = 0xC8, .g = 0x92, .b = 0x46 };
pub const ERR = Color{ .r = 0xC4, .g = 0x55, .b = 0x3D };
pub const INFO = Color{ .r = 0x63, .g = 0x89, .b = 0xA6 };

pub const Frame = struct {
    buf: []u8,

    pub fn deinit(self: *Frame, allocator: std.mem.Allocator) void {
        allocator.free(self.buf);
        self.* = undefined;
    }
};

pub const Cursor = struct {
    /// Posición 1-based para ESC[fila;columnaH; 0 = desconocida.
    row: usize = 0,
    col: usize = 0,
};

pub const Result = struct {
    frame: Frame,
    cursor: Cursor,
};

/// Ancho exterior de la caja de bienvenida: deja sitio a la línea más larga
/// de consejos (59 columnas) manteniendo el aire de cli-01.
const WELCOME_W: usize = 64;
const WELCOME_H: usize = 14;

const GLYPH_LINES = [_][]const u8{
    "   ●   ",
    "  ╱ ╲  ",
    " ●───● ",
};

const TITLE = "DevAgents v" ++ state.VERSION;
const PLACEHOLDER = "Pide una orden o escribe / para comandos";
const SHORTCUTS_ROW = "? atajos · ctrl+c salir · shift+tab modo de permisos";
const METADATA_LABEL_W = 12;
const MENU_NAME_W = 14;
const TIP1 = "  /ayuda  comandos y atajos    /modelo  elegir modelo";
const TIP2 = "  /gobernanza  cambiar gobierno  @archivo  adjuntar archivo";

/// Número de code points (columnas para texto latino de ancho simple).
pub fn cpLen(s: []const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += @min(l, s.len - i);
        n += 1;
    }
    return n;
}

/// Primeros `k` code points (corte en frontera UTF-8).
fn headCodepoints(s: []const u8, k: usize) []const u8 {
    var i: usize = 0;
    var n: usize = 0;
    while (i < s.len and n < k) {
        const l = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        i += @min(l, s.len - i);
        n += 1;
    }
    return s[0..i];
}

/// Últimos `k` code points de `s` (para el desplazamiento horizontal).
fn tailCodepoints(s: []const u8, k: usize) []const u8 {
    var i = s.len;
    var n: usize = 0;
    while (i > 0 and n < k) {
        i -= 1;
        while (i > 0 and (s[i] & 0xC0) == 0x80) i -= 1;
        n += 1;
    }
    return s[i..];
}

const Writer = std.ArrayList(u8);

fn put(w: *Writer, allocator: std.mem.Allocator, s: []const u8) !void {
    try w.appendSlice(allocator, s);
}

fn putFmt(w: *Writer, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const s = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(s);
    try w.appendSlice(allocator, s);
}

fn sgr(w: *Writer, allocator: std.mem.Allocator, color: bool, c: Color) !void {
    if (!color) return;
    try putFmt(w, allocator, "\x1b[38;2;{d};{d};{d}m", .{ c.r, c.g, c.b });
}

fn reset(w: *Writer, allocator: std.mem.Allocator, color: bool) !void {
    if (!color) return;
    try w.appendSlice(allocator, "\x1b[0m");
}

fn putStyled(
    w: *Writer,
    allocator: std.mem.Allocator,
    color: bool,
    c: Color,
    s: []const u8,
) !void {
    try sgr(w, allocator, color, c);
    try put(w, allocator, s);
    try reset(w, allocator, color);
}

fn putRepeat(w: *Writer, allocator: std.mem.Allocator, s: []const u8, n: usize) !void {
    var i: usize = 0;
    while (i < n) : (i += 1) try put(w, allocator, s);
}

fn putSpaces(w: *Writer, allocator: std.mem.Allocator, n: usize) !void {
    try putRepeat(w, allocator, " ", n);
}

/// Fila con borde «│ … │» y relleno hasta `inner` columnas visibles.
/// `used` es el ancho visible de `content` (que puede llevar SGR).
fn putBoxRow(
    w: *Writer,
    allocator: std.mem.Allocator,
    color: bool,
    inner: usize,
    content: []const u8,
    used: usize,
) !void {
    try sgr(w, allocator, color, SECONDARY);
    try put(w, allocator, "│");
    try reset(w, allocator, color);
    try put(w, allocator, content);
    if (used < inner) try putSpaces(w, allocator, inner - used);
    try sgr(w, allocator, color, SECONDARY);
    try put(w, allocator, "│");
    try reset(w, allocator, color);
}

fn putBoxEdge(
    w: *Writer,
    allocator: std.mem.Allocator,
    color: bool,
    left: u21,
    right: u21,
    inner: usize,
) !void {
    var tmp: [4]u8 = undefined;
    try sgr(w, allocator, color, SECONDARY);
    const ln = std.unicode.utf8Encode(left, &tmp) catch return error.InvalidUtf8;
    try put(w, allocator, tmp[0..ln]);
    try putRepeat(w, allocator, "─", inner);
    const rn = std.unicode.utf8Encode(right, &tmp) catch return error.InvalidUtf8;
    try put(w, allocator, tmp[0..rn]);
    try reset(w, allocator, color);
}

fn centeredPad(total: usize, len: usize) usize {
    if (len >= total) return 0;
    return (total - len) / 2;
}

fn putMetaRow(
    w: *Writer,
    allocator: std.mem.Allocator,
    color: bool,
    inner: usize,
    label: []const u8,
    value: []const u8,
) !void {
    const value_shown = if (2 + METADATA_LABEL_W + cpLen(value) > inner)
        headCodepoints(value, inner -| (2 + METADATA_LABEL_W))
    else
        value;
    var line: Writer = .empty;
    defer line.deinit(allocator);
    try put(&line, allocator, "  ");
    try putStyled(&line, allocator, color, SECONDARY, label);
    try putSpaces(&line, allocator, METADATA_LABEL_W -| cpLen(label));
    try putStyled(&line, allocator, color, TEXT, value_shown);
    const used = 2 + METADATA_LABEL_W + cpLen(value_shown);
    try putBoxRow(w, allocator, color, inner, line.items, used);
}

/// Consejo con los comandos («/…») y «@archivo» en acento y el resto en
/// secundario, respetando los espacios originales de alineación.
fn putTipRow(
    w: *Writer,
    allocator: std.mem.Allocator,
    color: bool,
    inner: usize,
    s_in: []const u8,
) !void {
    const s = if (cpLen(s_in) > inner) headCodepoints(s_in, inner) else s_in;
    var line: Writer = .empty;
    defer line.deinit(allocator);
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '/' or s[i] == '@') {
            var j = i;
            while (j < s.len and s[j] != ' ') j += 1;
            try putStyled(&line, allocator, color, ACCENT, s[i..j]);
            i = j;
        } else {
            var j = i;
            while (j < s.len and s[j] != ' ' and s[j] != '/' and s[j] != '@') j += 1;
            if (j == i) j += 1;
            try putStyled(&line, allocator, color, SECONDARY, s[i..j]);
            i = j;
        }
    }
    try putBoxRow(w, allocator, color, inner, line.items, cpLen(s));
}

const Seg = struct {
    text: []const u8,
    kind: state.LineKind,
    prefix: []const u8,
};

/// Vuelca la transcripción alineada por abajo, con estilo por tipo de línea.
fn putTranscript(
    w: *Writer,
    allocator: std.mem.Allocator,
    color: bool,
    st: *state.State,
    trans_top: usize,
    trans_bottom: usize,
    cols: usize,
) !void {
    if (trans_bottom <= trans_top) return;
    const region = trans_bottom - trans_top;
    const wrap_w = cols -| 2;

    var segs: std.ArrayList(Seg) = .empty;
    defer segs.deinit(allocator);
    for (st.transcript.items) |line| {
        const prefix: []const u8 = if (line.kind == .command) "› " else "";
        if (line.text.len == 0) {
            try segs.append(allocator, .{ .text = "", .kind = line.kind, .prefix = prefix });
            continue;
        }
        var start: usize = 0;
        var first = true;
        while (start < line.text.len) {
            var j = start;
            var col: usize = if (first) cpLen(prefix) else 2;
            while (j < line.text.len and col < wrap_w) {
                const l = std.unicode.utf8ByteSequenceLength(line.text[j]) catch 1;
                j += @min(l, line.text.len - j);
                col += 1;
            }
            try segs.append(allocator, .{
                .text = line.text[start..j],
                .kind = line.kind,
                .prefix = if (first) prefix else "  ",
            });
            first = false;
            start = j;
        }
    }

    st.transcript_scroll = @min(st.transcript_scroll, segs.items.len -| region);
    const end = segs.items.len - st.transcript_scroll;
    const shown = @min(end, region);
    const blank = region - shown;
    var i: usize = 0;
    while (i < blank) : (i += 1) try put(w, allocator, "\n");
    for (segs.items[end - shown .. end]) |seg| {
        const c = switch (seg.kind) {
            .command => ACCENT,
            .info, .output => TEXT,
            .ok => OK,
            .err => ERR,
            .notice => SECONDARY,
        };
        if (seg.prefix.len > 0) try putStyled(w, allocator, color, c, seg.prefix);
        try putStyled(w, allocator, color, c, seg.text);
        try put(w, allocator, "\n");
    }
}

/// Panel abierto (? gobernanza…): título y líneas justo encima de la entrada.
fn putPanel(w: *Writer, allocator: std.mem.Allocator, color: bool, st: *state.State, cols: usize) !void {
    if (st.panel.kind == .none) return;
    if (st.panel.kind == .approval) {
        try putStyled(w, allocator, color, ACCENT, " APROBACIÓN DEL PLAN\n");
        const options = [_][]const u8{ "1  Aprobar y ejecutar", "2  Editar la orden", "3  Descartar" };
        for (options, 0..) |option, i| {
            const selected = st.approval_sel == i;
            try put(w, allocator, if (selected) " > " else "   ");
            if (color and selected) try put(w, allocator, "\x1b[48;2;217;211;199m\x1b[38;2;10;10;10m");
            try put(w, allocator, option);
            try reset(w, allocator, color);
            try put(w, allocator, "\n");
        }
        try putStyled(w, allocator, color, SECONDARY, " 1/2/3 · flechas/tab + enter · esc cancela · PgUp/PgDn ver plan\n");
        return;
    }
    if (st.panel.kind == .permission) {
        // Criterio 4: mismo patrón que la referencia cli-03, en aviso (WARN).
        try put(w, allocator, " ");
        try putStyled(w, allocator, color, WARN, "PERMISO PENDIENTE");
        if (st.panel.title.len > 0) {
            try put(w, allocator, " · ");
            const room = cols -| 22;
            const desc = if (cpLen(st.panel.title) > room) headCodepoints(st.panel.title, room) else st.panel.title;
            try putStyled(w, allocator, color, TEXT, desc);
        }
        try put(w, allocator, "\n");
        const options = [_][]const u8{ "1  Permitir una vez", "2  Siempre en esta sesión", "3  Denegar" };
        for (options, 0..) |option, i| {
            const selected = st.permission_sel == i;
            try put(w, allocator, if (selected) " > " else "   ");
            if (color and selected) try put(w, allocator, "\x1b[48;2;217;211;199m\x1b[38;2;10;10;10m");
            try put(w, allocator, option);
            try reset(w, allocator, color);
            try put(w, allocator, "\n");
        }
        try putStyled(w, allocator, color, SECONDARY, " 1/2/3 · flechas/tab + enter · esc deniega\n");
        return;
    }
    switch (st.panel.kind) {
        .help => try putStyled(w, allocator, color, ACCENT, " Ayuda"),
        .shortcuts => try putStyled(w, allocator, color, ACCENT, " Atajos"),
        else => {
            try put(w, allocator, " ");
            try putStyled(w, allocator, color, ACCENT, st.panel.title);
        },
    }
    try put(w, allocator, "\n");
    for (st.panel.lines.items, 0..) |l, idx| {
        const last = idx + 1 == st.panel.lines.items.len;
        const c = if (last and st.panel.kind == .governance) SECONDARY else TEXT;
        try put(w, allocator, " ");
        try putStyled(w, allocator, color, c, l);
        try put(w, allocator, "\n");
    }
}

// ── E3: bloques de avance por tarea ────────────────────────────────────

fn taskGlyph(s: progress.TaskState) []const u8 {
    return switch (s) {
        .pending => "○",
        .running => "●",
        .done => "✓",
        .failed => "✗",
    };
}

fn taskColor(s: progress.TaskState) Color {
    return switch (s) {
        .pending => SECONDARY,
        .running => ACCENT,
        .done => OK,
        .failed => ERR,
    };
}

/// Filas que necesita el bloque: cabecera + contenido si está desplegado.
fn blockRowsNeeded(b: *const progress.TaskBlock) usize {
    var n: usize = 1;
    if (b.folded) return n;
    for (b.files.items) |*fc| {
        n += 1;
        if (fc.has_diff) n += fc.lines.items.len + @as(usize, if (fc.cropped) 1 else 0);
    }
    return n;
}

fn executionRowsNeeded(st: *state.State) usize {
    var n: usize = 1; // rótulo «EJECUCIÓN DE LA ORDEN»
    for (st.progress.blocks.items) |*b| n += blockRowsNeeded(b);
    return n;
}

fn putTaskHeader(
    w: *Writer,
    allocator: std.mem.Allocator,
    color: bool,
    b: *const progress.TaskBlock,
    focused: bool,
    cols: usize,
) !void {
    var plain: Writer = .empty;
    defer plain.deinit(allocator);
    try put(&plain, allocator, taskGlyph(b.state));
    try put(&plain, allocator, " ");
    try put(&plain, allocator, b.title);
    try put(&plain, allocator, " · ");
    try put(&plain, allocator, progress.estadoText(b.state));
    if (b.model.len > 0) {
        try put(&plain, allocator, " · ");
        try put(&plain, allocator, b.model);
    }
    if (b.end_ms > 0) {
        var dur: [16]u8 = undefined;
        const time = progress.fmtDuration(&dur, b.end_ms - b.start_ms);
        if (time.len > 0) {
            try put(&plain, allocator, " · ");
            try put(&plain, allocator, time);
        }
    }
    const room = cols -| 4;
    const shown = if (cpLen(plain.items) > room) headCodepoints(plain.items, room) else plain.items;
    try putStyled(w, allocator, color, if (focused) ACCENT else SECONDARY, if (focused) "> " else "  ");
    try putStyled(w, allocator, color, SECONDARY, if (b.folded) "▸ " else "▾ ");
    const glyph_len = headCodepoints(shown, 1).len;
    try putStyled(w, allocator, color, taskColor(b.state), shown[0..glyph_len]);
    var rest = shown[glyph_len..];
    if (rest.len > 0 and rest[0] == ' ') {
        try put(w, allocator, " ");
        rest = rest[1..];
    }
    try putStyled(w, allocator, color, if (focused) ACCENT else TEXT, rest);
    try put(w, allocator, "\n");
}

fn putFileRow(
    w: *Writer,
    allocator: std.mem.Allocator,
    color: bool,
    fc: *const progress.FileChange,
    cols: usize,
) !void {
    var counts: [48]u8 = undefined;
    var counts_text: []const u8 = "";
    if (fc.has_counts) {
        counts_text = std.fmt.bufPrint(&counts, " +{d} −{d}", .{ fc.added, fc.removed }) catch "";
    }
    const room = (cols -| 4) -| cpLen(counts_text);
    const path = headCodepoints(fc.path, room);
    try put(w, allocator, "    ");
    try putStyled(w, allocator, color, TEXT, path);
    if (counts_text.len > 0) {
        try put(w, allocator, " ");
        var it = std.mem.tokenizeScalar(u8, counts_text, ' ');
        if (it.next()) |add| try putStyled(w, allocator, color, OK, add);
        if (it.next()) |del| {
            try put(w, allocator, " ");
            try putStyled(w, allocator, color, ERR, del);
        }
    }
    try put(w, allocator, "\n");
}

fn putDiffRow(
    w: *Writer,
    allocator: std.mem.Allocator,
    color: bool,
    dl: *const progress.DiffLine,
    cols: usize,
) !void {
    const sign: []const u8 = switch (dl.kind) {
        .add => "+ ",
        .del => "− ",
        .eq => "  ",
    };
    const c: Color = switch (dl.kind) {
        .add => OK,
        .del => ERR,
        .eq => SECONDARY,
    };
    const room = (cols -| 6) -| 2;
    const text = headCodepoints(dl.text, room);
    try put(w, allocator, "      ");
    try putStyled(w, allocator, color, c, sign);
    try putStyled(w, allocator, color, c, text);
    try put(w, allocator, "\n");
}

/// Rótulo « EJECUCIÓN DE LA ORDEN» y los bloques, con los recortes que pida
/// el espacio reservado. Devuelve las filas dibujadas (== max_rows o el total).
fn putExecution(
    w: *Writer,
    allocator: std.mem.Allocator,
    color: bool,
    st: *state.State,
    cols: usize,
    max_rows: usize,
) !usize {
    if (max_rows == 0) return 0;
    var used: usize = 0;
    try putStyled(w, allocator, color, ACCENT, " EJECUCIÓN DE LA ORDEN");
    try put(w, allocator, "\n");
    used += 1;
    var out_of_rows = false;
    for (st.progress.blocks.items, 0..) |*b, idx| {
        if (used >= max_rows) {
            out_of_rows = true;
            break;
        }
        try putTaskHeader(w, allocator, color, b, idx == st.progress.focus, cols);
        used += 1;
        if (b.folded) continue;
        for (b.files.items) |*fc| {
            if (used >= max_rows) {
                out_of_rows = true;
                break;
            }
            try putFileRow(w, allocator, color, fc, cols);
            used += 1;
            if (!fc.has_diff) continue;
            for (fc.lines.items) |*dl| {
                if (used >= max_rows) {
                    out_of_rows = true;
                    break;
                }
                try putDiffRow(w, allocator, color, dl, cols);
                used += 1;
            }
            if (fc.cropped and used < max_rows) {
                try putStyled(w, allocator, color, SECONDARY, "      …\n");
                used += 1;
            }
            if (out_of_rows) break;
        }
        if (out_of_rows) break;
    }
    if (out_of_rows and used < max_rows) {
        try putStyled(w, allocator, color, SECONDARY, "  …\n");
        used += 1;
    }
    return used;
}

/// Renderiza un fotograma completo. El resultado no lleva '\n' final: la
/// consola limpia, coloca el cursor y convierte los '\n' en '\r\n'.
pub fn frame(
    allocator: std.mem.Allocator,
    st: *state.State,
    cols_in: usize,
    rows_in: usize,
    color: bool,
) !Result {
    const cols = @max(cols_in, 20);
    const rows = @max(rows_in, 8);

    var w: Writer = .empty;
    errdefer w.deinit(allocator);

    var cursor = Cursor{};

    const show_welcome = !st.order_active and rows >= 24 and cols >= 30;
    const box_outer = @min(WELCOME_W, cols -| 2);
    const box_inner = box_outer - 2;

    const input_top = rows - 5;
    const input_mid = rows - 4;

    const menu_lines: usize = if (st.menuOpen()) st.filtered().len else 0;
    const panel_lines: usize = if (st.panel.kind == .approval or st.panel.kind == .permission) 5 else if (st.panel.kind != .none) 1 + st.panel.lines.items.len else 0;
    const trans_bottom = input_top -| (menu_lines + panel_lines);

    // E3: los bloques de avance se reservan filas ARRIBA de la transcripción,
    // nunca a costa de dejarla sin sitio (se degradan si la ventana es chica).
    const trans_floor: usize = if (show_welcome) WELCOME_H else if (st.order_active) 7 else 0;
    var blocks_rows: usize = 0;
    if (st.order_active and st.progress.hasBlocks()) {
        const avail = trans_bottom -| trans_floor;
        if (avail > 7) blocks_rows = @min(avail - 5, executionRowsNeeded(st));
    }
    const trans_top = trans_floor + blocks_rows;

    // ── Bienvenida ─────────────────────────────────────────────────────
    if (show_welcome) {
        try putBoxEdge(&w, allocator, color, '┌', '┐', box_inner);
        try put(&w, allocator, "\n");

        try putBoxRow(&w, allocator, color, box_inner, "", 0);
        try put(&w, allocator, "\n");

        for (GLYPH_LINES) |g| {
            var line: Writer = .empty;
            defer line.deinit(allocator);
            const pad = centeredPad(box_inner, cpLen(g));
            try putSpaces(&line, allocator, pad);
            try putStyled(&line, allocator, color, ACCENT, g);
            try putBoxRow(&w, allocator, color, box_inner, line.items, pad + cpLen(g));
            try put(&w, allocator, "\n");
        }

        {
            var line: Writer = .empty;
            defer line.deinit(allocator);
            const pad = centeredPad(box_inner, cpLen(TITLE));
            try putSpaces(&line, allocator, pad);
            try putStyled(&line, allocator, color, ACCENT, TITLE);
            try putBoxRow(&w, allocator, color, box_inner, line.items, pad + cpLen(TITLE));
            try put(&w, allocator, "\n");
        }

        try putBoxRow(&w, allocator, color, box_inner, "", 0);
        try put(&w, allocator, "\n");

        try putMetaRow(&w, allocator, color, box_inner, "Proyecto", st.project_name);
        try put(&w, allocator, "\n");
        try putMetaRow(&w, allocator, color, box_inner, "Gobernanza", st.governance);
        try put(&w, allocator, "\n");
        try putMetaRow(&w, allocator, color, box_inner, "Modelo", st.model);
        try put(&w, allocator, "\n");

        try putBoxRow(&w, allocator, color, box_inner, "", 0);
        try put(&w, allocator, "\n");

        try putTipRow(&w, allocator, color, box_inner, TIP1);
        try put(&w, allocator, "\n");
        try putTipRow(&w, allocator, color, box_inner, TIP2);
        try put(&w, allocator, "\n");

        try putBoxEdge(&w, allocator, color, '└', '┘', box_inner);
        try put(&w, allocator, "\n");
    }

    if (st.order_active) {
        try putStyled(&w, allocator, color, ACCENT, "   ●   DevAgents v" ++ state.VERSION ++ "\n");
        var meta: Writer = .empty;
        defer meta.deinit(allocator);
        try putFmt(&meta, allocator, " ●───● {s} · {s} · {s} · {s}", .{ st.project_name, st.branch, st.governance, st.model });
        try put(&w, allocator, headCodepoints(meta.items, cols));
        try put(&w, allocator, "\n\n");
        const inner = cols - 2;
        try putBoxEdge(&w, allocator, color, '┌', '┐', inner);
        try put(&w, allocator, "\n");
        try putBoxRow(&w, allocator, color, inner, " ORDEN", 6);
        try put(&w, allocator, "\n");
        const order = headCodepoints(st.order_text.items, inner);
        try putBoxRow(&w, allocator, color, inner, order, cpLen(order));
        try put(&w, allocator, "\n");
        try putBoxEdge(&w, allocator, color, '└', '┘', inner);
        try put(&w, allocator, "\n");
    }

    // ── Bloques de avance (E3) ─────────────────────────────────────────
    if (blocks_rows > 0) {
        _ = try putExecution(&w, allocator, color, st, cols, blocks_rows);
    }

    // ── Transcripción ──────────────────────────────────────────────────
    try putTranscript(&w, allocator, color, st, trans_top, trans_bottom, cols);

    // ── Menú o panel, pegados a la entrada ─────────────────────────────
    if (st.menuOpen()) {
        const cmds = st.filtered();
        for (cmds, 0..) |cmd, i| {
            const sel = i == @min(st.menu_sel, cmds.len - 1);
            try put(&w, allocator, "   ");
            try sgr(&w, allocator, color, if (sel) ACCENT else SECONDARY);
            try put(&w, allocator, if (sel) "▸ " else "  ");
            try put(&w, allocator, cmd.name);
            try putSpaces(&w, allocator, MENU_NAME_W -| cmd.name.len);
            try reset(&w, allocator, color);
            try putStyled(&w, allocator, color, SECONDARY, cmd.desc);
            try put(&w, allocator, "\n");
        }
    } else if (st.panel.kind != .none) {
        try putPanel(&w, allocator, color, st, cols);
    }

    // ── Caja de entrada ────────────────────────────────────────────────
    {
        const inner = cols - 2;
        try putBoxEdge(&w, allocator, color, '┌', '┐', inner);
        try put(&w, allocator, "\n");

        try sgr(&w, allocator, color, SECONDARY);
        try put(&w, allocator, "│");
        try reset(&w, allocator, color);
        var col: usize = 1;
        try sgr(&w, allocator, color, ACCENT);
        try put(&w, allocator, " > ");
        try reset(&w, allocator, color);
        col += 3;

        const input = st.inputText();
        const fits = cpLen(input) <= inner -| 5;
        if (fits) {
            try putStyled(&w, allocator, color, TEXT, input[0..st.cursor]);
            col += cpLen(input[0..st.cursor]);
            try sgr(&w, allocator, color, ACCENT);
            try put(&w, allocator, "▏");
            try reset(&w, allocator, color);
            cursor = .{ .row = input_mid + 1, .col = col + 1 };
            col += 1;
            try putStyled(&w, allocator, color, TEXT, input[st.cursor..]);
            col += cpLen(input[st.cursor..]);
            if (input.len == 0) {
                try put(&w, allocator, " ");
                col += 1;
                try putStyled(&w, allocator, color, SECONDARY, PLACEHOLDER);
                col += cpLen(PLACEHOLDER);
            }
        } else {
            const wide = inner -| 6;
            try putStyled(&w, allocator, color, TEXT, "…");
            col += 1;
            const tail = tailCodepoints(input, wide);
            try putStyled(&w, allocator, color, TEXT, tail);
            col += cpLen(tail);
            try sgr(&w, allocator, color, ACCENT);
            try put(&w, allocator, "▏");
            try reset(&w, allocator, color);
            cursor = .{ .row = input_mid + 1, .col = col + 1 };
            col += 1;
        }
        if (col < inner) try putSpaces(&w, allocator, inner - col);
        try sgr(&w, allocator, color, SECONDARY);
        try put(&w, allocator, " │");
        try reset(&w, allocator, color);
        try put(&w, allocator, "\n");

        try putBoxEdge(&w, allocator, color, '└', '┘', inner);
        try put(&w, allocator, "\n");
    }

    // ── Atajos ─────────────────────────────────────────────────────────
    try putSpaces(&w, allocator, centeredPad(cols, cpLen(SHORTCUTS_ROW)));
    try putStyled(&w, allocator, color, SECONDARY, SHORTCUTS_ROW);
    try put(&w, allocator, "\n");

    // ── Barra de estado ────────────────────────────────────────────────
    {
        var line: Writer = .empty;
        defer line.deinit(allocator);
        try putFmt(&line, allocator, " {s} · {s} · {s} · {s} · contexto 0 % · coste $0,00", .{
            st.project_name,
            st.branch,
            st.model,
            if (st.auto_approve) @as([]const u8, "Aprobar automáticamente (--yes)") else "Pedir siempre",
        });
        const text = if (cpLen(line.items) > cols) headCodepoints(line.items, cols) else line.items;
        try putStyled(&w, allocator, color, SECONDARY, text);
    }

    return .{
        .frame = .{ .buf = try w.toOwnedSlice(allocator) },
        .cursor = cursor,
    };
}

const testing = std.testing;

test "CK-MOT-027 E2: orden plan y aprobacion visibles con seleccion y sin color" {
    const a = testing.allocator;
    var st = try testState();
    defer st.deinit();
    st.order_active = true;
    try st.order_text.appendSlice(a, "Crea una calculadora");
    try st.appendText(.output, "ENTENDIMIENTO: crear calculadora\nPLAN PROPUESTO\n1. Programación → fabricante/modelo\nArchivo: calculadora/index.html\n2. Testing\n3. Auditoría");
    st.panel.kind = .approval;
    st.approval_sel = 1;
    var plain = try frame(a, &st, 120, 40, false);
    defer plain.frame.deinit(a);
    try testing.expect(std.mem.indexOf(u8, plain.frame.buf, " ORDEN") != null);
    try testing.expect(std.mem.indexOf(u8, plain.frame.buf, "Crea una calculadora") != null);
    try testing.expect(std.mem.indexOf(u8, plain.frame.buf, "PLAN PROPUESTO") != null);
    try testing.expect(std.mem.indexOf(u8, plain.frame.buf, "calculadora/index.html") != null);
    try testing.expect(std.mem.indexOf(u8, plain.frame.buf, "> 2  Editar la orden") != null);
    try testing.expect(std.mem.indexOfScalar(u8, plain.frame.buf, 0x1b) == null);
    var colored = try frame(a, &st, 120, 40, true);
    defer colored.frame.deinit(a);
    try testing.expect(std.mem.indexOf(u8, colored.frame.buf, "\x1b[48;2;217;211;199m\x1b[38;2;10;10;10m2  Editar") != null);
    var lines = std.mem.splitScalar(u8, plain.frame.buf, '\n');
    var count: usize = 0;
    while (lines.next()) |_| count += 1;
    try testing.expectEqual(@as(usize, 40), count);
}

test "CK-MOT-027 E2: PgUp y PgDn permiten revisar planes que exceden la pantalla" {
    const a = testing.allocator;
    var st = try testState();
    defer st.deinit();
    st.order_active = true;
    st.panel.kind = .approval;
    try st.appendLine(.output, "PRIMERA TAREA");
    for (0..35) |_| try st.appendLine(.output, "Tarea intermedia");
    try st.appendLine(.output, "ULTIMA TAREA");
    _ = try st.apply(.page_up);
    _ = try st.apply(.page_up);
    var top = try frame(a, &st, 120, 40, false);
    defer top.frame.deinit(a);
    try testing.expect(std.mem.indexOf(u8, top.frame.buf, "PRIMERA TAREA") != null);
    _ = try st.apply(.page_down);
    _ = try st.apply(.page_down);
    var bottom = try frame(a, &st, 120, 40, false);
    defer bottom.frame.deinit(a);
    try testing.expect(std.mem.indexOf(u8, bottom.frame.buf, "ULTIMA TAREA") != null);
}

test "CK-MOT-027 E3: bloques plegables con diff y recuentos a 120 y a 60 columnas" {
    const interaction = @import("interaction.zig");
    const a = testing.allocator;
    var st = try testState();
    defer st.deinit();
    st.order_active = true;
    try st.order_text.appendSlice(a, "Crea una calculadora");
    _ = try st.progress.feedPlanLine("  [t1] Escribe la web (programar) → opencode/deepseek-free");
    _ = try st.progress.feedPlanLine("     Archivo: calculadora/index.html");
    _ = try st.progress.feedPlanLine("  [t2] Prueba la suma (testing) → sin-modelo");
    _ = try st.progress.applyTaskReport(interaction.TASK ++ " t1 ok 1000 4400 opencode/deepseek-free Escribe la web");
    _ = try st.progress.applyTaskReport(interaction.TASK ++ " t2 failed 1000 2500 - Prueba la suma");
    try st.progress.setSnapshot("calculadora/index.html", try a.dupe(u8, "<h1>Hola</h1>\n"));
    _ = try st.progress.applyFileReport(interaction.FILE ++ " t1 calculadora/index.html", "<h1>Hola!</h1>\n");

    // Plegado por defecto: cabecera con estado, modelo y tiempo; sin diff.
    var folded = try frame(a, &st, 120, 40, false);
    defer folded.frame.deinit(a);
    try testing.expect(std.mem.indexOf(u8, folded.frame.buf, " EJECUCIÓN DE LA ORDEN") != null);
    try testing.expect(std.mem.indexOf(u8, folded.frame.buf, "✓ Escribe la web · hecha · opencode/deepseek-free · 3,4 s") != null);
    try testing.expect(std.mem.indexOf(u8, folded.frame.buf, "✗ Prueba la suma · falló") != null);
    try testing.expect(std.mem.indexOf(u8, folded.frame.buf, "<h1>Hola!</h1>") == null);

    // ctrl+o sobre el primer bloque: se despliega con archivo y diff.
    st.progress.focus = 0;
    _ = try st.apply(.toggle_blocks);
    var open = try frame(a, &st, 120, 40, false);
    defer open.frame.deinit(a);
    try testing.expect(std.mem.indexOf(u8, open.frame.buf, "▾ ✓ Escribe la web · hecha") != null);
    try testing.expect(std.mem.indexOf(u8, open.frame.buf, "calculadora/index.html") != null);
    try testing.expect(std.mem.indexOf(u8, open.frame.buf, " +1") != null);
    try testing.expect(std.mem.indexOf(u8, open.frame.buf, " −1") != null);
    try testing.expect(std.mem.indexOf(u8, open.frame.buf, "+ <h1>Hola!</h1>") != null);
    try testing.expect(std.mem.indexOf(u8, open.frame.buf, "− <h1>Hola</h1>") != null);
    // Verde del tema para +, rojo para − (el signo abre su propio tramo SGR).
    var colored_open = try frame(a, &st, 120, 40, true);
    defer colored_open.frame.deinit(a);
    try testing.expect(std.mem.indexOf(u8, colored_open.frame.buf, "\x1b[38;2;121;153;106m+ ") != null);
    try testing.expect(std.mem.indexOf(u8, colored_open.frame.buf, "\x1b[38;2;196;85;61m− ") != null);

    // NO_COLOR: mismos signos, ni un escape.
    var plain = try frame(a, &st, 120, 40, false);
    defer plain.frame.deinit(a);
    try testing.expect(std.mem.indexOfScalar(u8, plain.frame.buf, 0x1b) == null);
    try testing.expect(std.mem.indexOf(u8, plain.frame.buf, "− <h1>Hola</h1>") != null);

    // 60 columnas: nada desborda y el marco sigue completo.
    var narrow = try frame(a, &st, 60, 30, false);
    defer narrow.frame.deinit(a);
    var lines: [64][]const u8 = undefined;
    const n = splitLines(narrow.frame.buf, &lines);
    try testing.expectEqual(@as(usize, 30), n);
    for (lines[0..n]) |l| try testing.expect(cpLen(l) <= 60);
    try testing.expect(std.mem.indexOf(u8, narrow.frame.buf, "Escribe la web") != null);
}

test "CK-MOT-027 E3: el panel de permiso pendiente ofrece las tres opciones" {
    const a = testing.allocator;
    var st = try testState();
    defer st.deinit();
    st.order_active = true;
    st.panel.kind = .permission;
    st.panel.title = "Ejecutar npm test";
    st.permission_sel = 1;
    var plain = try frame(a, &st, 120, 40, false);
    defer plain.frame.deinit(a);
    try testing.expect(std.mem.indexOf(u8, plain.frame.buf, "PERMISO PENDIENTE") != null);
    try testing.expect(std.mem.indexOf(u8, plain.frame.buf, "Ejecutar npm test") != null);
    try testing.expect(std.mem.indexOf(u8, plain.frame.buf, "Permitir una vez") != null);
    try testing.expect(std.mem.indexOf(u8, plain.frame.buf, "Siempre en esta sesión") != null);
    try testing.expect(std.mem.indexOf(u8, plain.frame.buf, "> 2  Siempre en esta sesión") != null);
    try testing.expect(std.mem.indexOf(u8, plain.frame.buf, "3  Denegar") != null);
    var colored = try frame(a, &st, 120, 40, true);
    defer colored.frame.deinit(a);
    try testing.expect(std.mem.indexOf(u8, colored.frame.buf, "\x1b[38;2;200;146;70mPERMISO PENDIENTE") != null);
    var lines: [64][]const u8 = undefined;
    const n = splitLines(plain.frame.buf, &lines);
    try testing.expectEqual(@as(usize, 40), n);
}

fn testState() !state.State {
    return state.State.init(testing.allocator, .{
        .project_root = "C:\\proyectos\\calculadora",
        .project_name = "calculadora",
        .branch = "main",
        .model = "auto (router)",
        .governance = "Solo gratis",
    });
}

fn splitLines(buf: []const u8, out: *[64][]const u8) usize {
    var it = std.mem.splitScalar(u8, buf, '\n');
    var n: usize = 0;
    while (it.next()) |l| : (n += 1) out[n] = l;
    return n;
}

test "CK-MOT-027: bienvenida a 120×40 sin color, líneas literales de cli-01" {
    var st = try testState();
    defer st.deinit();

    var res = try frame(testing.allocator, &st, 120, 40, false);
    defer res.frame.deinit(testing.allocator);

    var lines: [64][]const u8 = undefined;
    const n = splitLines(res.frame.buf, &lines);
    try testing.expectEqual(@as(usize, 40), n);
    for (lines[0..n]) |l| try testing.expect(cpLen(l) <= 120);

    // Caja de bienvenida de 64×14, borde y glifo de la firma.
    try testing.expectEqualStrings("┌" ++ ("─" ** 62) ++ "┐", lines[0]);
    try testing.expectEqualStrings("│" ++ (" " ** 27) ++ "   ●   " ++ (" " ** 28) ++ "│", lines[2]);
    try testing.expectEqual(@as(usize, lines[0].len), lines[13].len);
    try testing.expect(std.mem.startsWith(u8, lines[13], "└"));

    // Título, proyecto, gobernanza y modelo.
    try testing.expectEqualStrings("DevAgents v" ++ state.VERSION, std.mem.trim(u8, lines[5][3 .. lines[5].len - 3], " "));
    try testing.expectEqualStrings("│  Proyecto    calculadora" ++ (" " ** 37) ++ "│", lines[7]);
    try testing.expectEqualStrings("│  Gobernanza  Solo gratis" ++ (" " ** 37) ++ "│", lines[8]);
    try testing.expectEqualStrings("│  Modelo      auto (router)" ++ (" " ** 35) ++ "│", lines[9]);

    // Consejos de la referencia.
    try testing.expect(std.mem.indexOf(u8, lines[11], "/ayuda") != null);
    try testing.expect(std.mem.indexOf(u8, lines[11], "/modelo") != null);
    try testing.expect(std.mem.indexOf(u8, lines[12], "/gobernanza") != null);
    try testing.expect(std.mem.indexOf(u8, lines[12], "@archivo") != null);

    // Caja de entrada con marcador y carátula, atajos y estado.
    try testing.expect(std.mem.startsWith(u8, lines[35], "┌"));
    try testing.expectEqualStrings(
        "│ > ▏ Pide una orden o escribe / para comandos" ++ (" " ** 72) ++ " │",
        lines[36],
    );
    try testing.expect(std.mem.startsWith(u8, lines[37], "└"));
    try testing.expectEqualStrings(
        "? atajos · ctrl+c salir · shift+tab modo de permisos",
        std.mem.trim(u8, lines[38], " "),
    );
    try testing.expectEqualStrings(
        "calculadora · main · auto (router) · Pedir siempre · contexto 0 % · coste $0,00",
        std.mem.trim(u8, lines[39], " "),
    );

    // Sin color: ni un escape ANSI. Cursor tras « > » (fila 37, columna 5).
    try testing.expect(std.mem.indexOfScalar(u8, res.frame.buf, 0x1B) == null);
    try testing.expectEqual(@as(usize, 37), res.cursor.row);
    try testing.expectEqual(@as(usize, 5), res.cursor.col);
}

test "CK-MOT-027: con color los mismos textos llevan SGR de la paleta" {
    var st = try testState();
    defer st.deinit();

    var res = try frame(testing.allocator, &st, 120, 40, true);
    defer res.frame.deinit(testing.allocator);

    try testing.expect(std.mem.indexOf(u8, res.frame.buf, "\x1b[38;2;217;211;199m") != null); // acento
    try testing.expect(std.mem.indexOf(u8, res.frame.buf, "\x1b[38;2;154;149;142m") != null); // secundario
    try testing.expect(std.mem.indexOf(u8, res.frame.buf, "\x1b[38;2;228;224;218m") != null); // texto
}

test "CK-MOT-027: la transcripción más reciente queda pegada a la entrada" {
    var st = try testState();
    defer st.deinit();

    try st.appendLine(.notice, "primera");
    try st.appendLine(.ok, "segunda");
    try st.appendText(.output, "tercera\ncuarta");

    var res = try frame(testing.allocator, &st, 120, 40, false);
    defer res.frame.deinit(testing.allocator);

    var lines: [64][]const u8 = undefined;
    const n = splitLines(res.frame.buf, &lines);
    try testing.expectEqual(@as(usize, 40), n);

    try testing.expectEqualStrings("cuarta", lines[34]);
    try testing.expectEqualStrings("tercera", lines[33]);
    try testing.expectEqualStrings("segunda", lines[32]);
    try testing.expectEqualStrings("primera", lines[31]);
    try testing.expectEqualStrings("Sesión nueva. Escribe una orden o / para comandos.", lines[30]);
}

test "CK-MOT-027: menú filtrable y panel de gobernanza encima de la entrada" {
    var st = try testState();
    defer st.deinit();

    try st.insertCodepoint('/');
    try st.insertSlice("go");

    var res = try frame(testing.allocator, &st, 120, 40, false);
    defer res.frame.deinit(testing.allocator);

    var lines: [64][]const u8 = undefined;
    const n = splitLines(res.frame.buf, &lines);
    try testing.expectEqual(@as(usize, 40), n);

    try testing.expect(std.mem.indexOf(u8, lines[34], "▸ /gobernanza") != null);
    try testing.expect(std.mem.indexOf(u8, lines[36], "/go") != null);

    // Enter ejecuta el resaltado → panel con las cuatro opciones de referencia.
    var out = try st.apply(.{ .enter = {} });
    out.deinit(testing.allocator);
    var res2 = try frame(testing.allocator, &st, 120, 40, false);
    defer res2.frame.deinit(testing.allocator);
    try testing.expect(std.mem.indexOf(u8, res2.frame.buf, "Gobernanza actual: Solo gratis") != null);
    try testing.expect(std.mem.indexOf(u8, res2.frame.buf, "Solo gratis") != null);
    try testing.expect(std.mem.indexOf(u8, res2.frame.buf, "Híbrido") != null);
    try testing.expect(std.mem.indexOf(u8, res2.frame.buf, "Prioriza pago") != null);
    try testing.expect(std.mem.indexOf(u8, res2.frame.buf, "Solo local") != null);
    try testing.expect(std.mem.indexOf(u8, res2.frame.buf, "1-4 para cambiar") != null);
}
