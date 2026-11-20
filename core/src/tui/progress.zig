//! core/src/tui/progress.zig — (E3): bloques de avance por tarea.
//!
//! Estado y análisis PUROS de la ejecución de una orden aprobada: qué tareas
//! hay, en qué estado van, con qué modelo, cuánto tardaron y qué archivos
//! escribieron (con su diff +N −M). No imprime ni lee nada: las líneas del
//! plan salen de la salida de `devagents order --tui-session`, los informes
//! por tarea llegan por el protocolo privado (interaction.zig) que el hijo
//! emite al terminar el despacho, y los contenidos de archivo los inyecta el
//! bucle de sesión por su puerto `read_file` (aquí se guardan y comparan).
//!
//! El flujo actual no tiene canal vivo DURANTE la ejecución: el hijo solo
//! puede informar cuando el despacho ya terminó (superagent.zig:3451, cuando
//! el CLI principal ya está bloqueado en approveAndDispatch). Por eso los
//! bloques se pintan con la traza completa al volver, no en tiempo real; ver
//! el informe E3 (criterio 1).

const std = @import("std");
const interaction = @import("interaction.zig");

pub const TaskState = enum { pending, running, done, failed };

/// Etiqueta de pantalla del estado de una tarea (referencia cli-03).
pub fn estadoText(s: TaskState) []const u8 {
    return switch (s) {
        .pending => "pendiente",
        .running => "en curso",
        .done => "hecha",
        .failed => "falló",
    };
}

pub const DiffKind = enum { eq, add, del };

pub const DiffLine = struct {
    kind: DiffKind,
    text: []u8,

    fn deinit(self: *DiffLine, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

/// Un archivo escrito por una tarea. `has_counts` exige una referencia real
/// (instantánea previa o archivo nuevo declarado en el plan): sin ella solo se
/// lista la ruta, que es lo que pide el criterio 3.
pub const FileChange = struct {
    path: []u8,
    added: usize = 0,
    removed: usize = 0,
    has_counts: bool = false,
    has_diff: bool = false,
    cropped: bool = false,
    lines: std.ArrayList(DiffLine) = .empty,

    fn deinit(self: *FileChange, allocator: std.mem.Allocator) void {
        allocator.free(self.path);
        for (self.lines.items) |*l| l.deinit(allocator);
        self.lines.deinit(allocator);
    }
};

pub const TaskBlock = struct {
    id: []u8,
    title: []u8,
    model: []u8,
    state: TaskState = .pending,
    start_ms: i64 = 0,
    end_ms: i64 = 0,
    folded: bool = false,
    files: std.ArrayList(FileChange) = .empty,

    fn deinit(self: *TaskBlock, allocator: std.mem.Allocator) void {
        allocator.free(self.id);
        allocator.free(self.title);
        allocator.free(self.model);
        for (self.files.items) |*f| f.deinit(allocator);
        self.files.deinit(allocator);
    }
};

const MAX_FILES_PER_BLOCK = 32;
const MAX_DIFF_STORE = 200;
const MAX_DIFF_INPUT_LINES = 800;
const MAX_DIFF_CELLS = 400_000;

pub const Progress = struct {
    allocator: std.mem.Allocator,
    blocks: std.ArrayList(TaskBlock) = .empty,
    /// Contenido previo por ruta; la clave presente con valor null significa
    /// «se intentó leer y no existía» (archivo nuevo).
    snapshots: std.StringHashMap(?[]u8),
    focus: usize = 0,

    pub fn init(allocator: std.mem.Allocator) Progress {
        return .{
            .allocator = allocator,
            .snapshots = std.StringHashMap(?[]u8).init(allocator),
        };
    }

    pub fn deinit(self: *Progress) void {
        for (self.blocks.items) |*b| b.deinit(self.allocator);
        self.blocks.deinit(self.allocator);
        var it = self.snapshots.iterator();
        while (it.next()) |kv| {
            self.allocator.free(kv.key_ptr.*);
            if (kv.value_ptr.*) |content| self.allocator.free(content);
        }
        self.snapshots.deinit();
    }

    pub fn hasBlocks(self: *const Progress) bool {
        return self.blocks.items.len > 0;
    }

    pub fn blockById(self: *Progress, id: []const u8) ?*TaskBlock {
        for (self.blocks.items) |*b| {
            if (std.mem.eql(u8, b.id, id)) return b;
        }
        return null;
    }

    /// Bloque existente o nuevo (pendiente, con el id por título provisional).
    fn ensureBlock(self: *Progress, id: []const u8) !*TaskBlock {
        if (self.blockById(id)) |b| return b;
        var b = TaskBlock{
            .id = try self.allocator.dupe(u8, id),
            .title = try self.allocator.dupe(u8, id),
            .model = try self.allocator.dupe(u8, ""),
        };
        errdefer b.deinit(self.allocator);
        try self.blocks.append(self.allocator, b);
        self.focus = self.blocks.items.len - 1;
        return &self.blocks.items[self.blocks.items.len - 1];
    }

    fn setText(self: *Progress, slot: *[]u8, text: []const u8) !void {
        const copy = try self.allocator.dupe(u8, text);
        self.allocator.free(slot.*);
        slot.* = copy;
    }

    /// Alta o actualización de una tarea del plan (título y modelo planificado).
    pub fn applyPlanTask(self: *Progress, id: []const u8, title: []const u8, model: []const u8) !void {
        var b = try self.ensureBlock(id);
        if (title.len > 0) try self.setText(&b.title, title);
        if (model.len > 0) try self.setText(&b.model, model);
    }

    /// Línea de la salida del plan: tarea (`[id] desc (tipo) → prov/modelo`)
    /// o archivo (`Archivo:`/`Entregable:`). Devuelve true si la reconoció.
    pub fn feedPlanLine(self: *Progress, line: []const u8) !bool {
        if (parsePlanTaskLine(line)) |pt| {
            try self.applyPlanTask(pt.id, pt.title, pt.model);
            return true;
        }
        if (parsePlanFilePath(line)) |path| {
            try self.notePlanFile(path);
            return true;
        }
        return false;
    }

    /// Adjunta un archivo declarado en el plan al último bloque conocido.
    pub fn notePlanFile(self: *Progress, path: []const u8) !void {
        if (self.blocks.items.len == 0) return;
        const b = &self.blocks.items[self.blocks.items.len - 1];
        for (b.files.items) |f| {
            if (std.mem.eql(u8, f.path, path)) return;
        }
        if (b.files.items.len >= MAX_FILES_PER_BLOCK) return;
        try b.files.append(self.allocator, .{ .path = try self.allocator.dupe(u8, path) });
    }

    /// Guarda el contenido previo de `path` (o null si no existía). Toma
    /// posesión de `content`; el bucle de sesión lo obtiene de su puerto.
    pub fn setSnapshot(self: *Progress, path: []const u8, content: ?[]u8) !void {
        if (self.snapshots.fetchRemove(path)) |kv| {
            self.allocator.free(kv.key);
            if (kv.value) |v| self.allocator.free(v);
        }
        const key = try self.allocator.dupe(u8, path);
        errdefer self.allocator.free(key);
        try self.snapshots.put(key, content);
    }

    /// Informe de tarea del protocolo: `task <id> ok|failed <start> <end> <modelo> <desc>`.
    pub fn applyTaskReport(self: *Progress, line: []const u8) !bool {
        const rep = parseTaskReport(line) orelse return false;
        var b = try self.ensureBlock(rep.id);
        if (rep.description.len > 0 and (std.mem.eql(u8, b.title, rep.id) or b.title.len == 0)) {
            try self.setText(&b.title, rep.description);
        }
        b.state = if (rep.ok) .done else .failed;
        b.start_ms = rep.start_ms;
        b.end_ms = rep.end_ms;
        if (rep.model.len > 0 and !std.mem.eql(u8, rep.model, "-")) try self.setText(&b.model, rep.model);
        // Criterio 2: al terminar, el bloque se pliega a una línea.
        b.folded = true;
        return true;
    }

    /// Informe de archivo del protocolo: `file <id> <ruta...>`. `after` es el
    /// contenido actual (null si no se pudo leer); el diff sale de la
    /// instantánea previa cuando la hay. Si el plan ya declaró el archivo, se
    /// completa esa misma entrada (no se duplica).
    pub fn applyFileReport(self: *Progress, line: []const u8, after: ?[]const u8) !bool {
        const rep = parseFileReport(line) orelse return false;
        var b = try self.ensureBlock(rep.id);
        for (b.files.items) |*f| {
            if (std.mem.eql(u8, f.path, rep.path)) {
                try self.fillFileChange(f, rep.path, after);
                return true;
            }
        }
        if (b.files.items.len >= MAX_FILES_PER_BLOCK) return true;
        var fc = FileChange{ .path = try self.allocator.dupe(u8, rep.path) };
        errdefer fc.deinit(self.allocator);
        try self.fillFileChange(&fc, rep.path, after);
        try b.files.append(self.allocator, fc);
        return true;
    }

    /// Calcula recuentos y diff de `fc` desde la instantánea de `path`
    /// (idempotente: borra el cálculo anterior antes de rehacerlo).
    fn fillFileChange(self: *Progress, fc: *FileChange, path: []const u8, after: ?[]const u8) !void {
        for (fc.lines.items) |*l| l.deinit(self.allocator);
        fc.lines.clearRetainingCapacity();
        fc.added = 0;
        fc.removed = 0;
        fc.has_counts = false;
        fc.has_diff = false;
        fc.cropped = false;
        if (after) |content_after| {
            if (self.snapshots.get(path)) |before_opt| {
                if (before_opt) |content_before| {
                    try computeDiff(self.allocator, content_before, content_after, fc);
                } else {
                    try storeAdded(self.allocator, content_after, fc);
                }
            }
        }
    }

    pub fn focusPrev(self: *Progress) void {
        if (self.blocks.items.len == 0) return;
        if (self.focus == 0) self.focus = self.blocks.items.len - 1 else self.focus -= 1;
    }

    pub fn focusNext(self: *Progress) void {
        if (self.blocks.items.len == 0) return;
        self.focus = (self.focus + 1) % self.blocks.items.len;
    }

    /// ctrl+o: pliega o despliega el bloque enfocado.
    pub fn toggleFocusedFold(self: *Progress) void {
        if (self.blocks.items.len == 0) return;
        const b = &self.blocks.items[@min(self.focus, self.blocks.items.len - 1)];
        b.folded = !b.folded;
    }
};

// ── Análisis de líneas ──────────────────────────────────────────────────

pub const PlanTask = struct { id: []const u8, title: []const u8, model: []const u8 };

fn idCharsOk(id: []const u8) bool {
    if (id.len == 0 or id.len > 64) return false;
    for (id) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    }
    return true;
}

/// `  [t1] Crear calculadora (programar) → opencode/deepseek-free`
pub fn parsePlanTaskLine(line: []const u8) ?PlanTask {
    const s = std.mem.trimStart(u8, line, " \t");
    if (s.len == 0 or s[0] != '[') return null;
    const close = std.mem.indexOfScalar(u8, s, ']') orelse return null;
    const id = s[1..close];
    if (!idCharsOk(id)) return null;
    var rest = std.mem.trimStart(u8, s[close + 1 ..], " \t");
    if (rest.len == 0) return null;
    var model: []const u8 = "";
    if (std.mem.indexOf(u8, rest, " → ")) |arrow| {
        model = std.mem.trim(u8, rest[arrow + 4 ..], " \t");
        rest = std.mem.trimEnd(u8, rest[0..arrow], " \t");
    }
    var title = rest;
    if (rest.len > 1 and rest[rest.len - 1] == ')') {
        if (std.mem.lastIndexOf(u8, rest, " (")) |paren| {
            title = std.mem.trimEnd(u8, rest[0..paren], " \t");
        }
    }
    if (title.len == 0) title = id;
    return .{ .id = id, .title = title, .model = model };
}

/// `     Archivo: calculadora/index.html` o `Entregable: …`.
pub fn parsePlanFilePath(line: []const u8) ?[]const u8 {
    const s = std.mem.trimStart(u8, line, " \t");
    const prefixes = [_][]const u8{ "Archivo:", "Entregable:" };
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, s, p)) {
            const path = std.mem.trim(u8, s[p.len..], " \t");
            if (path.len > 0) return path;
        }
    }
    return null;
}

pub const TaskReport = struct {
    id: []const u8,
    ok: bool,
    start_ms: i64,
    end_ms: i64,
    model: []const u8,
    description: []const u8,
};

pub fn parseTaskReport(line: []const u8) ?TaskReport {
    if (!std.mem.startsWith(u8, line, interaction.TASK)) return null;
    if (line.len <= interaction.TASK.len or line[interaction.TASK.len] != ' ') return null;
    var it = std.mem.tokenizeScalar(u8, line[interaction.TASK.len + 1 ..], ' ');
    const id = it.next() orelse return null;
    if (!idCharsOk(id)) return null;
    const status = it.next() orelse return null;
    const start_s = it.next() orelse return null;
    const end_s = it.next() orelse return null;
    const model = it.next() orelse return null;
    const start_ms = std.fmt.parseInt(i64, start_s, 10) catch return null;
    const end_ms = std.fmt.parseInt(i64, end_s, 10) catch return null;
    const ok = std.mem.eql(u8, status, "ok");
    if (!ok and !std.mem.eql(u8, status, "failed")) return null;
    return .{
        .id = id,
        .ok = ok,
        .start_ms = start_ms,
        .end_ms = end_ms,
        .model = model,
        .description = std.mem.trim(u8, it.rest(), " \t"),
    };
}

pub const FileReport = struct { id: []const u8, path: []const u8 };

pub fn parseFileReport(line: []const u8) ?FileReport {
    if (!std.mem.startsWith(u8, line, interaction.FILE)) return null;
    if (line.len <= interaction.FILE.len or line[interaction.FILE.len] != ' ') return null;
    const body = line[interaction.FILE.len + 1 ..];
    const sp = std.mem.indexOfScalar(u8, body, ' ') orelse return null;
    const id = body[0..sp];
    if (!idCharsOk(id)) return null;
    const path = std.mem.trim(u8, body[sp + 1 ..], " \t");
    if (path.len == 0) return null;
    return .{ .id = id, .path = path };
}

/// Duración de tarea como en la referencia: «3,4 s» o «02:14».
pub fn fmtDuration(buf: []u8, ms: i64) []const u8 {
    const clamped = @max(ms, 0);
    if (clamped < 60_000) {
        const tenths = @divTrunc(clamped * 10 + 50, 1000);
        return std.fmt.bufPrint(buf, "{d},{d} s", .{ @divTrunc(tenths, 10), @rem(tenths, 10) }) catch buf[0..0];
    }
    const total_s = @divTrunc(clamped, 1000);
    return std.fmt.bufPrint(buf, "{d:0>2}:{d:0>2}", .{ @divTrunc(total_s, 60), @rem(total_s, 60) }) catch buf[0..0];
}

// ── Diff por líneas (LCS con topes) ─────────────────────────────────────

const Op = struct { kind: DiffKind, text: []const u8 };

fn appendDiffLine(allocator: std.mem.Allocator, fc: *FileChange, kind: DiffKind, text: []const u8) !void {
    try fc.lines.append(allocator, .{ .kind = kind, .text = try allocator.dupe(u8, text) });
}

fn storeAdded(allocator: std.mem.Allocator, after: []const u8, fc: *FileChange) !void {
    var added: usize = 0;
    var stored: usize = 0;
    var it = std.mem.splitScalar(u8, after, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (l.len == 0) continue;
        added += 1;
        if (stored < MAX_DIFF_STORE) {
            try appendDiffLine(allocator, fc, .add, l);
            stored += 1;
        }
    }
    fc.added = added;
    fc.removed = 0;
    fc.has_counts = added > 0;
    fc.has_diff = stored > 0;
    fc.cropped = added > stored;
}

fn computeDiff(allocator: std.mem.Allocator, before: []const u8, after: []const u8, fc: *FileChange) !void {
    var before_lines: std.ArrayList([]const u8) = .empty;
    defer before_lines.deinit(allocator);
    var after_lines: std.ArrayList([]const u8) = .empty;
    defer after_lines.deinit(allocator);
    var it = std.mem.splitScalar(u8, before, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (l.len == 0) continue;
        try before_lines.append(allocator, l);
    }
    it = std.mem.splitScalar(u8, after, '\n');
    while (it.next()) |raw| {
        const l = std.mem.trimEnd(u8, raw, "\r");
        if (l.len == 0) continue;
        try after_lines.append(allocator, l);
    }
    const n = before_lines.items.len;
    const m = after_lines.items.len;
    if (n > MAX_DIFF_INPUT_LINES or m > MAX_DIFF_INPUT_LINES or (n + 1) * (m + 1) > MAX_DIFF_CELLS) return;

    const dp = try allocator.alloc(u32, (n + 1) * (m + 1));
    defer allocator.free(dp);
    const stride = m + 1;
    for (0..n + 1) |i| dp[i * stride] = 0;
    for (0..m + 1) |j| dp[j] = 0;
    for (1..n + 1) |i| {
        for (1..m + 1) |j| {
            dp[i * stride + j] = if (std.mem.eql(u8, before_lines.items[i - 1], after_lines.items[j - 1]))
                dp[(i - 1) * stride + (j - 1)] + 1
            else
                @max(dp[(i - 1) * stride + j], dp[i * stride + (j - 1)]);
        }
    }

    var ops: std.ArrayList(Op) = .empty;
    defer ops.deinit(allocator);
    var i = n;
    var j = m;
    var added: usize = 0;
    var removed: usize = 0;
    while (i > 0 or j > 0) {
        if (i > 0 and j > 0 and std.mem.eql(u8, before_lines.items[i - 1], after_lines.items[j - 1])) {
            try ops.append(allocator, .{ .kind = .eq, .text = before_lines.items[i - 1] });
            i -= 1;
            j -= 1;
        } else if (j > 0 and (i == 0 or dp[i * stride + (j - 1)] >= dp[(i - 1) * stride + j])) {
            added += 1;
            try ops.append(allocator, .{ .kind = .add, .text = after_lines.items[j - 1] });
            j -= 1;
        } else {
            removed += 1;
            try ops.append(allocator, .{ .kind = .del, .text = before_lines.items[i - 1] });
            i -= 1;
        }
    }

    fc.added = added;
    fc.removed = removed;
    fc.has_counts = added + removed > 0;
    fc.has_diff = ops.items.len > 0 and fc.has_counts;
    fc.cropped = ops.items.len > MAX_DIFF_STORE;
    const start = if (ops.items.len > MAX_DIFF_STORE) ops.items.len - MAX_DIFF_STORE else 0;
    var k = ops.items.len;
    while (k > start) {
        k -= 1;
        try appendDiffLine(allocator, fc, ops.items[k].kind, ops.items[k].text);
    }
}

const testing = std.testing;

test "CK-MOT-027 E3: avance por tareas con estados modelo y tiempos" {
    const a = testing.allocator;
    var pr = Progress.init(a);
    defer pr.deinit();

    // Plan real de `order --tui-session`: las líneas las vuelca el hijo.
    try testing.expect(try pr.feedPlanLine("PLAN PROPUESTO (orden #42):") == false);
    try testing.expect(try pr.feedPlanLine("  [t1] Crear calculadora (programar) → opencode/deepseek-free"));
    try testing.expect(try pr.feedPlanLine("     Archivo: calculadora/index.html"));
    try testing.expect(try pr.feedPlanLine("  [t2] Probar suma (testing) → sin-modelo"));
    try testing.expect(try pr.feedPlanLine("     Entregable: calculadora/pruebas.txt"));
    try testing.expectEqual(@as(usize, 2), pr.blocks.items.len);
    const b1 = pr.blocks.items[0];
    try testing.expectEqualStrings("t1", b1.id);
    try testing.expectEqualStrings("Crear calculadora", b1.title);
    try testing.expectEqualStrings("opencode/deepseek-free", b1.model);
    try testing.expectEqual(TaskState.pending, b1.state);
    try testing.expectEqual(@as(usize, 1), b1.files.items.len);
    try testing.expectEqualStrings("calculadora/index.html", b1.files.items[0].path);
    try testing.expectEqual(@as(usize, 1), pr.blocks.items[1].files.items.len);

    // Protocolo del hijo tras el despacho: ok con modelo y tiempo, fallo.
    try testing.expect(try pr.applyTaskReport(interaction.TASK ++ " t1 ok 1000 4400 opencode/deepseek-free Crear calculadora"));
    try testing.expect(try pr.applyTaskReport(interaction.TASK ++ " t2 failed 1000 2500 - Probar suma"));
    try testing.expectEqual(TaskState.done, pr.blocks.items[0].state);
    try testing.expectEqualStrings("opencode/deepseek-free", pr.blocks.items[0].model);
    try testing.expectEqual(@as(i64, 1000), pr.blocks.items[0].start_ms);
    try testing.expectEqual(@as(i64, 4400), pr.blocks.items[0].end_ms);
    try testing.expect(pr.blocks.items[0].folded);
    try testing.expectEqual(TaskState.failed, pr.blocks.items[1].state);
    try testing.expect(pr.blocks.items[1].folded);
    // El modelo planificado no se pisa con «-».
    try testing.expectEqualStrings("sin-modelo", pr.blocks.items[1].model);

    var buf: [16]u8 = undefined;
    try testing.expectEqualStrings("3,4 s", fmtDuration(&buf, 3400));
    try testing.expectEqualStrings("0,8 s", fmtDuration(&buf, 800));
    try testing.expectEqualStrings("02:14", fmtDuration(&buf, 134_000));

    // Plegado manual: ctrl+o sobre el bloque enfocado.
    pr.focus = 0;
    pr.toggleFocusedFold();
    try testing.expect(!pr.blocks.items[0].folded);
    pr.focusNext();
    try testing.expectEqual(@as(usize, 1), pr.focus);
    pr.focusNext();
    try testing.expectEqual(@as(usize, 0), pr.focus);
}

test "CK-MOT-027 E3: diff +N -M desde instantanea, archivo nuevo y sin datos" {
    const a = testing.allocator;
    var pr = Progress.init(a);
    defer pr.deinit();

    try pr.applyPlanTask("t1", "Web", "");
    try testing.expect(try pr.applyTaskReport(interaction.TASK ++ " t1 ok 0 1000 cohere/x"));

    // Modificado: la instantánea previa existe.
    try pr.notePlanFile("index.html");
    try pr.setSnapshot("index.html", try a.dupe(u8, "<h1>Hola</h1>\n<b>x</b>\n"));
    try testing.expect(try pr.applyFileReport(interaction.FILE ++ " t1 index.html", "<h1>Hola!</h1>\n<b>x</b>\n"));
    const fc1 = &pr.blocks.items[0].files.items[0];
    try testing.expect(fc1.has_counts);
    try testing.expectEqual(@as(usize, 1), fc1.added);
    try testing.expectEqual(@as(usize, 1), fc1.removed);
    try testing.expect(fc1.has_diff);
    try testing.expectEqual(DiffKind.del, fc1.lines.items[0].kind);
    try testing.expectEqualStrings("<h1>Hola</h1>", fc1.lines.items[0].text);
    try testing.expectEqual(DiffKind.add, fc1.lines.items[1].kind);
    try testing.expectEqualStrings("<h1>Hola!</h1>", fc1.lines.items[1].text);

    // Archivo nuevo: se intentó leer y no existía.
    try pr.setSnapshot("nuevo.txt", null);
    try testing.expect(try pr.applyFileReport(interaction.FILE ++ " t1 nuevo.txt", "uno\ndos\n"));
    const fc2 = &pr.blocks.items[0].files.items[1];
    try testing.expect(fc2.has_counts);
    try testing.expectEqual(@as(usize, 2), fc2.added);
    try testing.expectEqual(@as(usize, 0), fc2.removed);

    // Sin instantánea: solo la lista (criterio 3).
    try testing.expect(try pr.applyFileReport(interaction.FILE ++ " t1 notas.md", "hola\n"));
    const fc3 = &pr.blocks.items[0].files.items[2];
    try testing.expect(!fc3.has_counts);
    try testing.expect(!fc3.has_diff);

    // Igual: sin cambios, sin recuentos.
    try pr.setSnapshot("igual.txt", try a.dupe(u8, "misma\n"));
    try testing.expect(try pr.applyFileReport(interaction.FILE ++ " t1 igual.txt", "misma\n"));
    const fc4 = &pr.blocks.items[0].files.items[3];
    try testing.expect(!fc4.has_counts);
}

test "CK-MOT-027 E3: las lineas del protocolo se aceptan solo completas" {
    try testing.expect(parseTaskReport(interaction.TASK) == null);
    try testing.expect(parseTaskReport(interaction.TASK ++ " t1") == null);
    try testing.expect(parseTaskReport(interaction.TASK ++ " t1 ok 1 2") == null);
    try testing.expect(parseTaskReport(interaction.TASK ++ " t1 ok a 2 m") == null);
    try testing.expect(parseTaskReport(interaction.TASK ++ " t1 quizas 1 2 m") == null);
    try testing.expect(parseTaskReport("texto normal") == null);
    try testing.expect(parseFileReport(interaction.FILE) == null);
    try testing.expect(parseFileReport(interaction.FILE ++ " t1") == null);
    try testing.expect(parseFileReport(interaction.FILE ++ " [mal] ruta") == null);
    const fr = parseFileReport(interaction.FILE ++ " t1 carpeta archivo con espacios.txt").?;
    try testing.expectEqualStrings("t1", fr.id);
    try testing.expectEqualStrings("carpeta archivo con espacios.txt", fr.path);

    try testing.expect(parsePlanTaskLine("1. Programación → x/y") == null);
    try testing.expect(parsePlanTaskLine("  [t1]") == null);
    try testing.expect(parsePlanFilePath("Archivo:") == null);
    try testing.expectEqualStrings("a/b.html", parsePlanFilePath("     Archivo: a/b.html").?);
}
