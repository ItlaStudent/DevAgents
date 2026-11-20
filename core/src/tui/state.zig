//! core/src/tui/state.zig — (E1): estado de la sesión interactiva.
//!
//! (a) del encargo: aquí vive TODO el estado (entrada editable, historial,
//! transcripción, panel, selección de menú) y sus transiciones. No toca la
//! consola ni imprime: recibe `keys.Key` y devuelve un `Outcome` que el bucle
//! de session.zig ejecuta contra los puertos (gobernanza, catálogo, orden).
//!
//! La versión que se muestra es la constante única del producto:
//! core/src/root.zig VERSION.

const std = @import("std");
const keys = @import("keys.zig");
const progress = @import("progress.zig");

test "CK-VER1-002: slash plan y shift tab reutilizan la aprobacion de la CLI" {
    var st = try State.init(std.testing.allocator, .{
        .project_root = "C:\\fixture",
        .project_name = "fixture",
        .branch = "main",
        .model = "auto",
        .governance = "Híbrido",
    });
    defer st.deinit();
    st.auto_approve = true;
    try st.insertSlice("/plan");
    var result = try st.submit();
    defer result.deinit(std.testing.allocator);
    try std.testing.expect(!st.auto_approve);
    _ = try st.apply(.{ .shift_tab = {} });
    try std.testing.expect(st.auto_approve);
}

pub const VERSION = @import("../root.zig").VERSION;

pub const Command = struct {
    name: []const u8,
    desc: []const u8,
};

/// Comandos con «/» de E1. En español, en minúscula (ESPECIFICACION §«Sistema común»).
pub const COMMANDS = [_]Command{
    .{ .name = "/ayuda", .desc = "Ver comandos y atajos" },
    .{ .name = "/modelo", .desc = "Elegir modelo" },
    .{ .name = "/plan", .desc = "Esperar mi aprobación del plan" },
    .{ .name = "/gobernanza", .desc = "Cambiar gobernanza" },
    .{ .name = "/salir", .desc = "Cerrar la sesión" },
};

/// Gobiernos admitidos, con la etiqueta de pantalla que fija la referencia.
/// `code` es el texto canónico que guarda `settings.governance_mode` y que
/// entiende model_router.GovernanceMode (core/src/model_router.zig:211-232).
pub const GovOption = struct {
    code: []const u8,
    label: []const u8,
    desc: []const u8,
};

pub const GOV_OPTIONS = [_]GovOption{
    .{ .code = "free_tier_first", .label = "Solo gratis", .desc = "solo modelos gratuitos" },
    .{ .code = "hybrid", .label = "Híbrido", .desc = "pago al planificar/auditar, gratis en el resto" },
    .{ .code = "paid_tier_first", .label = "Prioriza pago", .desc = "prioriza los de pago" },
    .{ .code = "local_only", .label = "Solo local", .desc = "solo modelos locales (Ollama), sin nube ni claves" },
};

/// Etiqueta de pantalla del gobierno `code` (canónico o alias corto).
pub fn govLabel(code: []const u8) []const u8 {
    const canon = govCanonical(code);
    for (GOV_OPTIONS) |o| {
        if (std.mem.eql(u8, o.code, canon)) return o.label;
    }
    return "Híbrido";
}

/// Alias aceptados en la sesión, los mismos que documenta `devagents governance`:
/// free, paid, local y hybrid, además del nombre canónico.
pub fn govCanonical(code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "paid_tier_first") or std.mem.eql(u8, code, "paid")) return "paid_tier_first";
    if (std.mem.eql(u8, code, "free_tier_first") or std.mem.eql(u8, code, "free")) return "free_tier_first";
    if (std.mem.eql(u8, code, "local_only") or std.mem.eql(u8, code, "local") or std.mem.eql(u8, code, "solo_local")) return "local_only";
    if (std.mem.eql(u8, code, "hybrid")) return "hybrid";
    return "";
}

pub fn govAliasKnown(code: []const u8) bool {
    return govCanonical(code).len > 0;
}

/// Atajos que abre «?» con la entrada vacía (criterio 4).
pub const SHORTCUTS_LINES = [_][]const u8{
    "?            atajos (con la entrada vacía)",
    "ctrl+c       salir de la sesión en reposo; cancela la orden en curso",
    "shift+tab    modo de permisos",
    "enter        enviar la orden escrita",
    "/            lista de comandos filtrable",
    "← →          mover el cursor; inicio/fin a los extremos",
    "↑ ↓          enfocar bloques de tareas (entrada vacía); si no, historial",
    "ctrl+o       plegar o desplegar el bloque de tarea enfocado",
    "retroceso    borra el carácter anterior; suprimir, el siguiente",
};

/// Ayuda de «/ayuda»: atajos + comandos (criterio 4).
pub const HELP_LINES = SHORTCUTS_LINES ++ [_][]const u8{
    "",
    "Comandos:",
    "/ayuda       Ver comandos y atajos",
    "/modelo      Elegir modelo",
    "/plan        Esperar mi aprobación del plan (Shift+Tab alterna)",
    "/gobernanza  Cambiar gobernanza (Solo gratis, Híbrido, Prioriza pago, Solo local)",
    "/salir       Cerrar la sesión",
};

pub const LineKind = enum { command, info, output, ok, err, notice };

pub const Line = struct {
    kind: LineKind,
    text: []u8,
};

pub const PanelKind = enum { none, help, shortcuts, governance, models, approval, clarification, permission };

pub const Panel = struct {
    kind: PanelKind = .none,
    title: []const u8 = "",
    lines: std.ArrayList([]u8) = .empty,

    fn deinit(self: *Panel, allocator: std.mem.Allocator) void {
        self.clear(allocator);
        self.lines.deinit(allocator);
    }

    pub fn clear(self: *Panel, allocator: std.mem.Allocator) void {
        for (self.lines.items) |l| allocator.free(l);
        self.lines.clearRetainingCapacity();
        self.kind = .none;
        self.title = "";
    }
};

pub const Config = struct {
    project_root: []const u8,
    project_name: []const u8,
    branch: []const u8,
    model: []const u8,
    governance: []const u8,
    no_color: bool = false,
};

pub const Outcome = struct {
    pub const Kind = enum { none, exit, order, governance_set, models_show };
    kind: Kind = .none,
    /// Texto propio cuando kind = .order | .governance_set. El bucle lo libera.
    text: []u8 = &.{},

    pub fn deinit(self: *Outcome, allocator: std.mem.Allocator) void {
        if (self.text.len > 0) allocator.free(self.text);
        self.text = &.{};
    }
};

const TRANSCRIPT_MAX = 400;
const HISTORY_MAX = 100;
const PANEL_MAX_LINES = 200;

pub const State = struct {
    allocator: std.mem.Allocator,

    input: std.ArrayList(u8) = .empty,
    cursor: usize = 0,
    history: std.ArrayList([]u8) = .empty,
    hist_pos: ?usize = null,
    draft: []u8 = &.{},
    transcript: std.ArrayList(Line) = .empty,
    panel: Panel = .{},
    menu_sel: usize = 0,
    busy: bool = false,
    auto_approve: bool = false,
    order_active: bool = false,
    order_text: std.ArrayList(u8) = .empty,
    approval_sel: usize = 0,
    permission_sel: usize = 0,
    transcript_scroll: usize = 0,
    /// E3: bloques de avance por tarea de la ejecución en curso o pasada.
    progress: progress.Progress,

    /// Campos de la barra de estado / bienvenida. Propiedad del estado.
    project_root: []u8,
    project_name: []u8,
    branch: []u8,
    model: []u8,
    governance: []u8,
    no_color: bool,

    /// Búfer interno para `filtered()`: evita reservar en el render.
    filtered_buf: [COMMANDS.len]Command = undefined,

    pub fn init(allocator: std.mem.Allocator, cfg: Config) !State {
        var st = State{
            .allocator = allocator,
            .project_root = try allocator.dupe(u8, cfg.project_root),
            .project_name = try allocator.dupe(u8, cfg.project_name),
            .branch = try allocator.dupe(u8, cfg.branch),
            .model = try allocator.dupe(u8, cfg.model),
            .governance = try allocator.dupe(u8, cfg.governance),
            .no_color = cfg.no_color,
            .progress = progress.Progress.init(allocator),
        };
        errdefer st.deinit();
        try st.appendLine(.notice, "Sesión nueva. Escribe una orden o / para comandos.");
        return st;
    }

    pub fn deinit(self: *State) void {
        self.order_text.deinit(self.allocator);
        self.progress.deinit();
        self.input.deinit(self.allocator);
        for (self.history.items) |h| self.allocator.free(h);
        self.history.deinit(self.allocator);
        for (self.transcript.items) |l| self.allocator.free(l.text);
        self.transcript.deinit(self.allocator);
        self.panel.deinit(self.allocator);
        if (self.draft.len > 0) self.allocator.free(self.draft);
        self.allocator.free(self.project_root);
        self.allocator.free(self.project_name);
        self.allocator.free(self.branch);
        self.allocator.free(self.model);
        self.allocator.free(self.governance);
        self.* = undefined;
    }

    pub fn inputText(self: *const State) []const u8 {
        return self.input.items;
    }

    pub fn setBusy(self: *State, busy: bool) void {
        self.busy = busy;
    }

    pub fn setGovernanceLabel(self: *State, code: []const u8) !void {
        const label = govLabel(code);
        const copy = try self.allocator.dupe(u8, label);
        self.allocator.free(self.governance);
        self.governance = copy;
    }

    pub fn appendLine(self: *State, kind: LineKind, text: []const u8) !void {
        const t = std.mem.trimEnd(u8, text, " \t\r");
        const copy = try self.allocator.dupe(u8, t);
        errdefer self.allocator.free(copy);
        try self.transcript.append(self.allocator, .{ .kind = kind, .text = copy });
        while (self.transcript.items.len > TRANSCRIPT_MAX) {
            const first = self.transcript.orderedRemove(0);
            self.allocator.free(first.text);
        }
    }

    /// Añade un bloque de texto línea a línea (salida de una orden, catálogo…).
    pub fn appendText(self: *State, kind: LineKind, text: []const u8) !void {
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            const l = std.mem.trimEnd(u8, raw, "\r");
            if (l.len == 0) continue;
            try self.appendLine(kind, l);
        }
    }

    pub fn openPanelText(self: *State, kind: PanelKind, title: []const u8, text: []const u8) !void {
        self.panel.clear(self.allocator);
        self.panel.kind = kind;
        self.panel.title = title;
        var it = std.mem.splitScalar(u8, text, '\n');
        while (it.next()) |raw| {
            if (self.panel.lines.items.len >= PANEL_MAX_LINES) break;
            const l = std.mem.trimEnd(u8, raw, "\r");
            if (l.len == 0 and self.panel.lines.items.len == 0) continue;
            try self.panel.lines.append(self.allocator, try self.allocator.dupe(u8, l));
        }
    }

    pub fn openPanelLines(self: *State, kind: PanelKind, title: []const u8, lines: []const []const u8) !void {
        self.panel.clear(self.allocator);
        self.panel.kind = kind;
        self.panel.title = title;
        for (lines) |l| {
            if (self.panel.lines.items.len >= PANEL_MAX_LINES) break;
            try self.panel.lines.append(self.allocator, try self.allocator.dupe(u8, l));
        }
    }

    pub fn closePanel(self: *State) void {
        self.panel.clear(self.allocator);
    }

    /// ¿Se muestra la lista filtrable de comandos bajo la entrada?
    pub fn menuOpen(self: *const State) bool {
        if (self.panel.kind != .none) return false;
        if (self.busy) return false;
        return self.input.items.len > 0 and self.input.items[0] == '/';
    }

    /// Comandos que empiezan por lo escrito (filtro incremental).
    pub fn filtered(self: *State) []Command {
        const q = self.input.items;
        var n: usize = 0;
        for (COMMANDS) |c| {
            if (std.mem.startsWith(u8, c.name, q)) {
                self.filtered_buf[n] = c;
                n += 1;
            }
        }
        return self.filtered_buf[0..n];
    }

    pub fn selectedCommand(self: *State) ?Command {
        const cmds = self.filtered();
        if (cmds.len == 0) return null;
        return cmds[@min(self.menu_sel, cmds.len - 1)];
    }

    // ── Edición UTF-8 ────────────────────────────────────────────────────

    fn prevBoundary(s: []const u8, i: usize) usize {
        if (i == 0) return 0;
        var j = i - 1;
        while (j > 0 and (s[j] & 0xC0) == 0x80) j -= 1;
        return j;
    }

    fn nextBoundary(s: []const u8, i: usize) usize {
        if (i >= s.len) return s.len;
        var j = i + 1;
        while (j < s.len and (s[j] & 0xC0) == 0x80) j += 1;
        return j;
    }

    pub fn clearInput(self: *State) void {
        self.input.clearRetainingCapacity();
        self.cursor = 0;
        self.menu_sel = 0;
        self.hist_pos = null;
    }

    pub fn insertSlice(self: *State, s: []const u8) !void {
        try self.input.insertSlice(self.allocator, self.cursor, s);
        self.cursor += s.len;
        self.menu_sel = 0;
        self.hist_pos = null;
    }

    pub fn insertCodepoint(self: *State, cp: u21) !void {
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return;
        try self.insertSlice(buf[0..n]);
    }

    pub fn backspace(self: *State) void {
        const s = self.input.items;
        if (self.cursor == 0) return;
        const prev = prevBoundary(s, self.cursor);
        std.mem.copyForwards(u8, s[prev .. s.len - (self.cursor - prev)], s[self.cursor..]);
        self.input.shrinkRetainingCapacity(s.len - (self.cursor - prev));
        self.cursor = prev;
        self.menu_sel = 0;
        self.hist_pos = null;
    }

    pub fn deleteForward(self: *State) void {
        const s = self.input.items;
        if (self.cursor >= s.len) return;
        const next = nextBoundary(s, self.cursor);
        std.mem.copyForwards(u8, s[self.cursor .. s.len - (next - self.cursor)], s[next..]);
        self.input.shrinkRetainingCapacity(s.len - (next - self.cursor));
        self.menu_sel = 0;
        self.hist_pos = null;
    }

    pub fn moveLeft(self: *State) void {
        self.cursor = prevBoundary(self.input.items, self.cursor);
    }

    pub fn moveRight(self: *State) void {
        self.cursor = nextBoundary(self.input.items, self.cursor);
    }

    pub fn moveHome(self: *State) void {
        self.cursor = 0;
    }

    pub fn moveEnd(self: *State) void {
        self.cursor = self.input.items.len;
    }

    // ── Historial ────────────────────────────────────────────────────────

    fn pushHistory(self: *State, text: []const u8) !void {
        if (text.len == 0) return;
        if (self.history.items.len > 0) {
            const last = self.history.items[self.history.items.len - 1];
            if (std.mem.eql(u8, last, text)) return;
        }
        try self.history.append(self.allocator, try self.allocator.dupe(u8, text));
        while (self.history.items.len > HISTORY_MAX) {
            const first = self.history.orderedRemove(0);
            self.allocator.free(first);
        }
    }

    pub fn historyPrev(self: *State) void {
        if (self.history.items.len == 0) return;
        if (self.hist_pos == null) {
            if (self.draft.len > 0) self.allocator.free(self.draft);
            self.draft = self.allocator.dupe(u8, self.input.items) catch &.{};
            self.hist_pos = self.history.items.len - 1;
        } else if (self.hist_pos.? > 0) {
            self.hist_pos = self.hist_pos.? - 1;
        } else {
            return;
        }
        self.setInputFromHistory();
    }

    pub fn historyNext(self: *State) void {
        const pos = self.hist_pos orelse return;
        if (pos + 1 < self.history.items.len) {
            self.hist_pos = pos + 1;
            self.setInputFromHistory();
        } else {
            self.hist_pos = null;
            self.input.clearRetainingCapacity();
            if (self.draft.len > 0) self.input.appendSlice(self.allocator, self.draft) catch {};
            self.cursor = self.input.items.len;
        }
    }

    fn setInputFromHistory(self: *State) void {
        const pos = self.hist_pos orelse return;
        self.input.clearRetainingCapacity();
        self.input.appendSlice(self.allocator, self.history.items[pos]) catch {};
        self.cursor = self.input.items.len;
    }

    // ── Menú de comandos ─────────────────────────────────────────────────

    pub fn menuUp(self: *State) void {
        const n = self.filtered().len;
        if (n == 0) return;
        if (self.menu_sel == 0) self.menu_sel = n - 1 else self.menu_sel -= 1;
    }

    pub fn menuDown(self: *State) void {
        const n = self.filtered().len;
        if (n == 0) return;
        self.menu_sel = (self.menu_sel + 1) % n;
    }

    pub fn menuComplete(self: *State) void {
        const cmd = self.selectedCommand() orelse return;
        self.input.clearRetainingCapacity();
        self.input.appendSlice(self.allocator, cmd.name) catch {};
        self.cursor = self.input.items.len;
        self.menu_sel = 0;
    }

    // ── Envío y comandos ─────────────────────────────────────────────────

    /// Enter: envía. Si el menú está abierto, ejecuta el comando resaltado.
    pub fn submit(self: *State) !Outcome {
        if (self.busy) return .{};
        if (self.panel.kind != .none) {
            self.closePanel();
            return .{};
        }
        var text: []const u8 = self.input.items;
        if (self.menuOpen()) {
            if (self.selectedCommand()) |cmd| text = cmd.name;
        }
        if (text.len == 0) return .{};
        if (text[0] == '/') return try self.execCommand(text);
        try self.pushHistory(text);
        const copy = try self.allocator.dupe(u8, text);
        try self.appendLine(.command, text);
        self.clearInput();
        return .{ .kind = .order, .text = copy };
    }

    fn execCommand(self: *State, raw: []const u8) !Outcome {
        var it = std.mem.tokenizeAny(u8, raw, " \t");
        const name = it.next() orelse raw;
        const rest = std.mem.trim(u8, raw[name.len..], " \t");
        self.clearInput();

        if (std.mem.eql(u8, name, "/ayuda")) {
            try self.openPanelLines(.help, "Ayuda", &HELP_LINES);
            return .{};
        }
        if (std.mem.eql(u8, name, "/modelo")) {
            // El bucle llama al puerto del catálogo (mismo código que
            // `devagents models list`) y rellena el panel.
            return .{ .kind = .models_show };
        }
        if (std.mem.eql(u8, name, "/plan")) {
            self.auto_approve = false;
            try self.appendLine(.notice, "Esperar mi aprobación del plan: revisa el plan y elige 1/2/3. Shift+Tab alterna.");
            return .{};
        }
        if (std.mem.eql(u8, name, "/gobernanza")) {
            if (rest.len == 0) {
                try self.openGovernancePanel();
                return .{};
            }
            return .{ .kind = .governance_set, .text = try self.allocator.dupe(u8, rest) };
        }
        if (std.mem.eql(u8, name, "/salir")) {
            return .{ .kind = .exit };
        }
        try self.appendLine(.err, raw);
        try self.appendLine(.notice, "Comando desconocido. Escribe /ayuda para ver los comandos.");
        return .{};
    }

    pub fn openGovernancePanel(self: *State) !void {
        self.panel.clear(self.allocator);
        self.panel.kind = .governance;
        self.panel.title = "Gobernanza";
        const actual = self.governance;
        try self.panel.lines.append(self.allocator, try std.fmt.allocPrint(self.allocator, "Gobernanza actual: {s}", .{actual}));
        for (GOV_OPTIONS, 0..) |o, i| {
            try self.panel.lines.append(self.allocator, try std.fmt.allocPrint(self.allocator, "{d}  {s: <14}{s}", .{ i + 1, o.label, o.desc }));
        }
        try self.panel.lines.append(self.allocator, try self.allocator.dupe(u8, "Pulsa 1-4 para cambiar; esc para cerrar."));
    }

    // ── Aplicar teclas ───────────────────────────────────────────────────

    pub fn apply(self: *State, key: keys.Key) !Outcome {
        switch (key) {
            .ctrl_c => return .{ .kind = .exit },
            .resize, .other => return .{},
            .page_up => {
                self.transcript_scroll +|= 10;
                return .{};
            },
            .page_down => {
                self.transcript_scroll -|= 10;
                return .{};
            },
            .enter => return try self.submit(),
            .escape => {
                if (self.panel.kind != .none) {
                    self.closePanel();
                } else if (self.input.items.len > 0) {
                    self.clearInput();
                }
                return .{};
            },
            .char => |cp| return try self.applyChar(cp),
            .backspace => {
                if (self.panel.kind != .none or self.busy) return .{};
                self.backspace();
                return .{};
            },
            .delete => {
                if (self.panel.kind != .none or self.busy) return .{};
                self.deleteForward();
                return .{};
            },
            .left => {
                if (self.panel.kind != .none) return .{};
                self.moveLeft();
                return .{};
            },
            .right => {
                if (self.panel.kind != .none) return .{};
                self.moveRight();
                return .{};
            },
            .home => {
                if (self.panel.kind != .none) return .{};
                self.moveHome();
                return .{};
            },
            .end => {
                if (self.panel.kind != .none) return .{};
                self.moveEnd();
                return .{};
            },
            .up => {
                if (self.menuOpen()) {
                    self.menuUp();
                } else if (self.panel.kind == .none and self.input.items.len == 0 and self.progress.hasBlocks()) {
                    self.progress.focusPrev();
                } else if (self.panel.kind == .none and !self.busy) self.historyPrev();
                return .{};
            },
            .down => {
                if (self.menuOpen()) {
                    self.menuDown();
                } else if (self.panel.kind == .none and self.input.items.len == 0 and self.progress.hasBlocks()) {
                    self.progress.focusNext();
                } else if (self.panel.kind == .none and !self.busy) self.historyNext();
                return .{};
            },
            .toggle_blocks => {
                if (self.panel.kind == .none) self.progress.toggleFocusedFold();
                return .{};
            },
            .tab => {
                if (self.menuOpen()) self.menuComplete();
                return .{};
            },
            .shift_tab => {
                if (!self.busy) {
                    try self.toggleApproval();
                }
                return .{};
            },
        }
    }

    pub fn toggleApproval(self: *State) !void {
        self.auto_approve = !self.auto_approve;
        try self.appendLine(.notice, if (self.auto_approve)
            "Aprobar automáticamente: equivale a --yes para el plan; las aclaraciones se responden."
        else
            "Pedir siempre: ninguna tarea se ejecuta sin aprobar el plan.");
    }

    fn applyChar(self: *State, cp: u21) !Outcome {
        if (self.panel.kind == .governance) {
            if (cp >= '1' and cp <= '4') {
                const opt = GOV_OPTIONS[cp - '1'];
                self.closePanel();
                return .{ .kind = .governance_set, .text = try self.allocator.dupe(u8, opt.code) };
            }
            return .{};
        }
        if (self.panel.kind != .none or self.busy) return .{};
        // «?» con la entrada vacía abre los atajos; con texto se escribe.
        if (cp == '?' and self.input.items.len == 0) {
            try self.openPanelLines(.shortcuts, "Atajos", &SHORTCUTS_LINES);
            return .{};
        }
        try self.insertCodepoint(cp);
        return .{};
    }
};

const testing = std.testing;

test "CK-MOT-027: edición de la entrada con UTF-8 (acentos, flechas, retroceso)" {
    var st = try State.init(testing.allocator, .{
        .project_root = "C:\\proyectos\\calculadora",
        .project_name = "calculadora",
        .branch = "main",
        .model = "auto (router)",
        .governance = "Solo gratis",
    });
    defer st.deinit();

    // «café»: la é es un code point de dos bytes.
    try st.insertCodepoint('c');
    try st.insertCodepoint('a');
    try st.insertCodepoint('f');
    try st.insertCodepoint(0xE9);
    try testing.expectEqualStrings("café", st.inputText());
    try testing.expectEqual(@as(usize, 5), st.cursor);

    // Flecha izquierda mueve por code points, no por bytes.
    st.moveLeft();
    try testing.expectEqual(@as(usize, 3), st.cursor);
    st.moveRight();
    try testing.expectEqual(@as(usize, 5), st.cursor);

    // Retroceso borra la é entera (dos bytes) desde el final.
    st.backspace();
    try testing.expectEqualStrings("caf", st.inputText());
    try testing.expectEqual(@as(usize, 3), st.cursor);

    // Inicio + suprimir borra la primera letra.
    st.moveHome();
    st.deleteForward();
    try testing.expectEqualStrings("af", st.inputText());
    try testing.expectEqual(@as(usize, 0), st.cursor);

    // Fin e inserción en medio.
    st.moveEnd();
    st.insertCodepoint(0xF1) catch unreachable; // ñ
    try testing.expectEqualStrings("afñ", st.inputText());
    st.moveHome();
    st.moveRight();
    try st.insertSlice("X");
    try testing.expectEqualStrings("aXfñ", st.inputText());

    // Retroceso en el límite izquierdo no rompe nada.
    _ = try st.apply(.{ .backspace = {} });
    _ = try st.apply(.{ .backspace = {} });
    _ = try st.apply(.{ .backspace = {} });
    _ = try st.apply(.{ .home = {} });
    _ = try st.apply(.{ .backspace = {} });
    try testing.expectEqualStrings("fñ", st.inputText());
}

test "CK-MOT-027: historial con flechas arriba/abajo" {
    var st = try State.init(testing.allocator, .{
        .project_root = "C:\\p",
        .project_name = "p",
        .branch = "sin git",
        .model = "auto (router)",
        .governance = "Híbrido",
    });
    defer st.deinit();

    try st.insertSlice("primera");
    var out = try st.submit();
    out.deinit(testing.allocator);
    try st.insertSlice("segunda");
    out = try st.submit();
    out.deinit(testing.allocator);

    try st.insertSlice("borrador");
    _ = try st.apply(.{ .up = {} });
    try testing.expectEqualStrings("segunda", st.inputText());
    _ = try st.apply(.{ .up = {} });
    try testing.expectEqualStrings("primera", st.inputText());
    _ = try st.apply(.{ .down = {} });
    try testing.expectEqualStrings("segunda", st.inputText());
    _ = try st.apply(.{ .down = {} });
    try testing.expectEqualStrings("borrador", st.inputText());

    // El envío repetido no duplica la última entrada.
    st.clearInput();
    try st.insertSlice("segunda");
    out = try st.submit();
    out.deinit(testing.allocator);
    _ = try st.apply(.{ .up = {} });
    _ = try st.apply(.{ .up = {} });
    try testing.expectEqualStrings("primera", st.inputText());
}

test "CK-MOT-027: «/» abre la lista filtrable y enter ejecuta lo resaltado" {
    var st = try State.init(testing.allocator, .{
        .project_root = "C:\\p",
        .project_name = "p",
        .branch = "sin git",
        .model = "auto (router)",
        .governance = "Híbrido",
    });
    defer st.deinit();

    try testing.expect(!st.menuOpen());
    try st.insertCodepoint('/');
    try testing.expect(st.menuOpen());
    try testing.expectEqual(@as(usize, 5), st.filtered().len);

    try st.insertSlice("go");
    try testing.expectEqual(@as(usize, 1), st.filtered().len);
    try testing.expectEqualStrings("/gobernanza", st.filtered()[0].name);

    // Enter con el menú abierto ejecuta el comando filtrado.
    var out = try st.apply(.{ .enter = {} });
    try testing.expectEqual(Outcome.Kind.none, out.kind);
    out.deinit(testing.allocator);
    try testing.expectEqual(PanelKind.governance, st.panel.kind);

    // Dentro del panel, «4» cambia a Solo local (outcome lo aplica el bucle).
    out = try st.apply(.{ .char = '4' });
    try testing.expectEqual(Outcome.Kind.governance_set, out.kind);
    try testing.expectEqualStrings("local_only", out.text);
    out.deinit(testing.allocator);
    try testing.expectEqual(PanelKind.none, st.panel.kind);

    // Filtro que no casa con nada: lista vacía, sin fallo.
    st.clearInput();
    try st.insertSlice("/zzz");
    try testing.expectEqual(@as(usize, 0), st.filtered().len);

    // Comando desconocido: aviso, sin salir.
    out = try st.apply(.{ .enter = {} });
    try testing.expectEqual(Outcome.Kind.none, out.kind);
    out.deinit(testing.allocator);
    try testing.expect(st.transcript.items.len >= 3);

    // Tab completa el comando resaltado.
    st.clearInput();
    try st.insertSlice("/mod");
    _ = try st.apply(.{ .tab = {} });
    try testing.expectEqualStrings("/modelo", st.inputText());
}

test "CK-MOT-027: «?» con la entrada vacía abre atajos; con texto se escribe" {
    var st = try State.init(testing.allocator, .{
        .project_root = "C:\\p",
        .project_name = "p",
        .branch = "sin git",
        .model = "auto (router)",
        .governance = "Híbrido",
    });
    defer st.deinit();

    _ = try st.apply(.{ .char = '?' });
    try testing.expectEqual(PanelKind.shortcuts, st.panel.kind);
    _ = try st.apply(.{ .escape = {} });
    try testing.expectEqual(PanelKind.none, st.panel.kind);

    try st.insertSlice("a");
    _ = try st.apply(.{ .char = '?' });
    try testing.expectEqualStrings("a?", st.inputText());
    try testing.expectEqual(PanelKind.none, st.panel.kind);
}

test "CK-MOT-027: /ayuda y /salir" {
    var st = try State.init(testing.allocator, .{
        .project_root = "C:\\p",
        .project_name = "p",
        .branch = "sin git",
        .model = "auto (router)",
        .governance = "Híbrido",
    });
    defer st.deinit();

    try st.insertSlice("/ayuda");
    var out = try st.apply(.{ .enter = {} });
    defer out.deinit(testing.allocator);
    try testing.expectEqual(Outcome.Kind.none, out.kind);
    try testing.expectEqual(PanelKind.help, st.panel.kind);
    try testing.expect(st.panel.lines.items.len >= 12);

    _ = try st.apply(.{ .escape = {} });
    try st.insertSlice("/salir");
    out = try st.apply(.{ .enter = {} });
    try testing.expectEqual(Outcome.Kind.exit, out.kind);
}

test "CK-MOT-027: una orden escrita se envía y queda en el historial" {
    var st = try State.init(testing.allocator, .{
        .project_root = "C:\\p",
        .project_name = "p",
        .branch = "sin git",
        .model = "auto (router)",
        .governance = "Híbrido",
    });
    defer st.deinit();

    try st.insertSlice("Crea una calculadora");
    var out = try st.apply(.{ .enter = {} });
    defer out.deinit(testing.allocator);
    try testing.expectEqual(Outcome.Kind.order, out.kind);
    try testing.expectEqualStrings("Crea una calculadora", out.text);
    try testing.expectEqual(@as(usize, 0), st.input.items.len);
    try testing.expectEqual(@as(usize, 1), st.history.items.len);
}

test "CK-MOT-027 E3: ctrl+o pliega y las flechas enfocan bloques con la entrada vacía" {
    var st = try State.init(testing.allocator, .{
        .project_root = "C:\\p",
        .project_name = "p",
        .branch = "sin git",
        .model = "auto (router)",
        .governance = "Híbrido",
    });
    defer st.deinit();

    _ = try st.progress.feedPlanLine("  [t1] Crear web (programar) → prov/modelo");
    _ = try st.progress.feedPlanLine("  [t2] Probar web (testing) → prov/modelo");
    try testing.expect(st.progress.hasBlocks());
    try testing.expectEqual(@as(usize, 1), st.progress.focus);

    // ↑/↓ con la entrada vacía enfocan bloques, no el historial.
    _ = try st.apply(.{ .up = {} });
    try testing.expectEqual(@as(usize, 0), st.progress.focus);
    _ = try st.apply(.{ .down = {} });
    try testing.expectEqual(@as(usize, 1), st.progress.focus);

    // ctrl+o alterna el plegado del bloque enfocado y lo recuerda.
    st.progress.blocks.items[1].folded = true;
    _ = try st.apply(.toggle_blocks);
    try testing.expect(!st.progress.blocks.items[1].folded);
    _ = try st.apply(.toggle_blocks);
    try testing.expect(st.progress.blocks.items[1].folded);

    // Con texto en la entrada, las flechas vuelven al historial.
    try st.insertSlice("x");
    _ = try st.apply(.{ .up = {} });
    try testing.expectEqual(@as(usize, 1), st.progress.focus);
}
