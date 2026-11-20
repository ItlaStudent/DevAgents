//! T7 (e) · «Reglas del proyecto».
//!
//! Lo que el anuncio promete: «por defecto sigue normas de clean code, pero
//! puedes cambiarlas por tus propias reglas de programación o de seguridad».
//! Antes solo los departamentos de Orquestado y Colmena llevaban reglas
//! compiladas y Directo (el modo por defecto) ninguna.
//!
//! - Por defecto: `agent_def.CLEAN_CODE_RULES` (una sola fuente).
//! - Reglas propias por proyecto: se guardan en el motor (catalog.db, tabla
//!   `settings`, clave `project_rules:<carpeta del proyecto>`), no en la página.
//! - Un único bloque `[REGLAS DEL PROYECTO]` llega al prompt de Directo, de
//!   cada tarea de Orquestado y Colmena (también las de `delegate_tasks`, que
//!   despacha el mismo superagente) y al encargo de las CLIs externas.
//! - las reglas del repositorio / las reglas del repositorio del proyecto mandan sobre estas reglas cuando
//! chocan, como hace Codex con las reglas del repositorio: a los modelos por API se les pasa
//!   su contenido detrás de las reglas y marcado como prioritario; las CLIs
//!   los leen ellas mismas (o se los repite `external_context.projectPrompt`).
//!
//! Cada orden/sesión conserva su contexto de reglas; no hay estado global.

const std = @import("std");
const db = @import("db.zig");
const agent_def = @import("agent_def.zig");
const confined_fs = @import("confined_fs.zig");

pub const DEFAULT_RULES = agent_def.CLEAN_CODE_RULES;
pub const HEADER = "[REGLAS DEL PROYECTO]";
pub const PRECEDENCE_NOTE = "Si el proyecto trae AGENTS.md o CLAUDE.md, sus instrucciones mandan sobre estas reglas cuando choquen (igual que Codex con AGENTS.md).";
/// Tope de las reglas propias: caben unas páginas de normas sin inflar cada prompt.
pub const MAX_RULES_BYTES: usize = 16 * 1024;
/// Tope de cada las reglas del repositorio / las reglas del repositorio que se pasa a los modelos por API.
pub const MAX_PROJECT_DOC_BYTES: usize = 32 * 1024;
pub const PROJECT_DOCS = [_][]const u8{ "AGENTS.md", "CLAUDE.md" };
const SETTINGS_PREFIX = "project_rules:";

pub const Error = error{ RulesTooLarge, InvalidRules, InvalidProjectRoot } || db.DbError || std.mem.Allocator.Error;

pub const Context = struct {
    root: ?[]const u8 = null,
    custom: ?[]const u8 = null,
    owned: bool = false,

    pub fn deinit(self: Context, a: std.mem.Allocator) void {
        if (self.owned) if (self.custom) |text| a.free(text);
    }

    pub fn currentRules(self: Context, a: std.mem.Allocator) error{OutOfMemory}![]u8 {
        return a.dupe(u8, self.custom orelse DEFAULT_RULES);
    }

    pub fn isCustom(self: Context) bool {
        return self.custom != null;
    }

    /// Bloque para los modelos por API (Directo, Orquestado, Colmena, delegación):
    /// las reglas, cómo se combinan y, detrás, las reglas del repositorio / las reglas del repositorio del proyecto
    /// marcados como prioritarios. `root` null usa la carpeta cargada.
    pub fn blockForApi(self: Context, a: std.mem.Allocator, root: ?[]const u8) error{OutOfMemory}![]u8 {
        const rules = try self.currentRules(a);
        defer a.free(rules);
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(a);
        try out.appendSlice(a, "\n");
        try out.appendSlice(a, HEADER);
        try out.appendSlice(a, "\n");
        try out.appendSlice(a, rules);
        try out.appendSlice(a, "\n");
        try out.appendSlice(a, PRECEDENCE_NOTE);
        try out.appendSlice(a, "\n");
        if (root orelse self.root) |dir| try appendProjectDocs(a, &out, dir);
        return out.toOwnedSlice(a);
    }

    /// Bloque para el encargo de una CLI externa: las reglas y la precedencia. La
    /// CLI lee el las reglas del repositorio / las reglas del repositorio del proyecto con su propio mecanismo.
    pub fn blockForCli(self: Context, a: std.mem.Allocator) error{OutOfMemory}![]u8 {
        const rules = try self.currentRules(a);
        defer a.free(rules);
        return std.fmt.allocPrint(a, "\n\n{s}\n{s}\n{s}\n", .{ HEADER, rules, PRECEDENCE_NOTE });
    }

    /// El encargo para una CLI con el bloque añadido una sola vez (un encargo de
    /// Orquestado ya lo trae dentro del rol de la tarea).
    pub fn withCliBlock(self: Context, a: std.mem.Allocator, prompt: []const u8) error{OutOfMemory}![]u8 {
        if (std.mem.indexOf(u8, prompt, HEADER) != null) return a.dupe(u8, prompt);
        const block = try self.blockForCli(a);
        defer a.free(block);
        return std.mem.concat(a, u8, &.{ prompt, block });
    }
};

fn appendProjectDocs(a: std.mem.Allocator, out: *std.ArrayList(u8), dir: []const u8) error{OutOfMemory}!void {
    var root = confined_fs.Root.init(a, dir) catch |e| {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        // Carpeta ilegible o inexistente (proyecto aún sin crear): sin
        // documentos que añadir, las reglas siguen valiendo.
        return;
    };
    defer root.deinit();
    for (PROJECT_DOCS) |name| {
        const text = root.readFileAlloc(a, name, MAX_PROJECT_DOC_BYTES) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => continue,
            else => {
                const note = try std.fmt.allocPrint(a, "\n(No se pudo leer {s} del proyecto: {s}.)\n", .{ name, @errorName(e) });
                defer a.free(note);
                try out.appendSlice(a, note);
                continue;
            },
        };
        defer a.free(text);
        const section = try std.fmt.allocPrint(a, "\n[INSTRUCCIONES DEL PROYECTO · {s} · mandan sobre las reglas anteriores]\n{s}\n", .{ name, std.mem.trim(u8, text, " \t\r\n") });
        defer a.free(section);
        try out.appendSlice(a, section);
    }
}

// ── Persistencia en el motor (catalog.db · settings) ────────────────────

/// Clave por proyecto: la carpeta en minúsculas y con `\` (Windows no
/// distingue mayúsculas, y `/` o una barra final no cambian de proyecto).
fn settingsKey(a: std.mem.Allocator, root: []const u8) Error![]u8 {
    const trimmed = std.mem.trimEnd(u8, root, "\\/");
    if (trimmed.len == 0 or trimmed.len > 4000) return error.InvalidProjectRoot;
    const key = try a.alloc(u8, SETTINGS_PREFIX.len + trimmed.len);
    @memcpy(key[0..SETTINGS_PREFIX.len], SETTINGS_PREFIX);
    for (trimmed, 0..) |c, i| key[SETTINGS_PREFIX.len + i] = if (c == '/') '\\' else std.ascii.toLower(c);
    return key;
}

/// Reglas propias guardadas para `root`; null = no hay (se usan las de DevAgents).
pub fn load(a: std.mem.Allocator, conn: db.Connection, root: []const u8) Error!?[]u8 {
    const key = try settingsKey(a, root);
    defer a.free(key);
    const stmt = try conn.prepare("SELECT value FROM settings WHERE key = ?");
    defer conn.finalize(stmt);
    try db.bindText(stmt, 1, key);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return null;
    const ptr = db.c.sqlite3_column_text(stmt, 0) orelse return null;
    const len: usize = @intCast(db.c.sqlite3_column_bytes(stmt, 0));
    return try a.dupe(u8, ptr[0..len]);
}

/// Guarda reglas propias para `root`; null o texto vacío vuelve al defecto.
pub fn save(conn: db.Connection, a: std.mem.Allocator, root: []const u8, rules: ?[]const u8) Error!void {
    const key = try settingsKey(a, root);
    defer a.free(key);
    const text = std.mem.trim(u8, rules orelse "", " \t\r\n");
    if (text.len > MAX_RULES_BYTES) return error.RulesTooLarge;
    if (!std.unicode.utf8ValidateSlice(text) or std.mem.indexOfScalar(u8, text, 0) != null) return error.InvalidRules;
    if (text.len == 0) {
        const del = try conn.prepare("DELETE FROM settings WHERE key = ?");
        defer conn.finalize(del);
        try db.bindText(del, 1, key);
        if (db.c.sqlite3_step(del) != db.c.SQLITE_DONE) return error.StepFailed;
        return;
    }
    const stmt = try conn.prepare(
        \\INSERT INTO settings (key, value) VALUES (?, ?)
        \\ON CONFLICT(key) DO UPDATE SET value=excluded.value
    );
    defer conn.finalize(stmt);
    try db.bindText(stmt, 1, key);
    try db.bindText(stmt, 2, text);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
}

/// Instantánea propiedad de una orden/sesión; raíz prestada por su llamador.
pub fn loadContext(a: std.mem.Allocator, conn: ?db.Connection, root: []const u8) Error!Context {
    return .{ .root = root, .custom = if (conn) |c| try load(a, c, root) else null, .owned = true };
}

/// JSON para la cabina: reglas vigentes, si son propias, las de DevAgents y
/// qué documentos del proyecto mandan sobre ellas.
pub fn describeJson(a: std.mem.Allocator, conn: db.Connection, root: []const u8) ![]u8 {
    const self = try loadContext(a, conn, root);
    defer self.deinit(a);
    const rules = try self.currentRules(a);
    defer a.free(rules);
    var docs: std.ArrayList([]const u8) = .empty;
    defer docs.deinit(a);
    var dir = confined_fs.Root.init(a, root) catch |e| blk: {
        if (e == error.OutOfMemory) return error.OutOfMemory;
        break :blk null;
    };
    defer if (dir) |*d| d.deinit();
    if (dir) |*d| {
        for (PROJECT_DOCS) |name| {
            const text = d.readFileAlloc(a, name, MAX_PROJECT_DOC_BYTES) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.FileNotFound => continue,
                // Existe pero no se puede leer (o es demasiado grande): se
                // anuncia igual; el prompt dirá por qué no llegó su texto.
                else => {
                    try docs.append(a, name);
                    continue;
                },
            };
            a.free(text);
            try docs.append(a, name);
        }
    }
    return std.json.Stringify.valueAlloc(a, .{
        .projectRoot = root,
        .custom = self.isCustom(),
        .rules = rules,
        .defaultRules = DEFAULT_RULES,
        .projectDocs = docs.items,
        .precedence = PRECEDENCE_NOTE,
        .maxBytes = MAX_RULES_BYTES,
    }, .{});
}

// ── Pruebas ─────────────────────────────────────────────────────────────

test "VG1 B8: two simultaneous project sessions keep rules and documents isolated" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var one = std.testing.tmpDir(.{});
    defer one.cleanup();
    var two = std.testing.tmpDir(.{});
    defer two.cleanup();
    const root1 = try one.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root1);
    const root2 = try two.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root2);
    try one.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "DOC-ONE" });
    try two.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "DOC-TWO" });
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try conn.exec("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
    try save(conn, a, root1, "RULE-ONE");
    try save(conn, a, root2, "RULE-TWO");
    const first = try loadContext(a, conn, root1);
    defer first.deinit(a);
    const second = try loadContext(a, conn, root2);
    defer second.deinit(a);
    const Probe = struct {
        context: Context,
        rule: []const u8,
        doc: []const u8,
        other: []const u8,
        failure: ?anyerror = null,
        fn run(self: *@This()) void {
            self.check() catch |e| {
                self.failure = e;
            };
        }
        fn check(self: *@This()) !void {
            for (0..20) |_| {
                const api = try self.context.blockForApi(std.heap.page_allocator, null);
                defer std.heap.page_allocator.free(api);
                const cli = try self.context.withCliBlock(std.heap.page_allocator, "task");
                defer std.heap.page_allocator.free(cli);
                try std.testing.expect(std.mem.indexOf(u8, api, self.rule).? < std.mem.indexOf(u8, api, self.doc).?);
                try std.testing.expect(std.mem.indexOf(u8, api, self.other) == null);
                try std.testing.expect(std.mem.indexOf(u8, cli, self.rule) != null);
                try std.testing.expect(std.mem.indexOf(u8, cli, self.other) == null);
            }
        }
    };
    var p1: Probe = .{ .context = first, .rule = "RULE-ONE", .doc = "DOC-ONE", .other = "RULE-TWO" };
    var p2: Probe = .{ .context = second, .rule = "RULE-TWO", .doc = "DOC-TWO", .other = "RULE-ONE" };
    const t1 = try std.Thread.spawn(.{}, Probe.run, .{&p1});
    const t2 = std.Thread.spawn(.{}, Probe.run, .{&p2}) catch |e| {
        t1.join();
        return e;
    };
    t1.join();
    t2.join();
    if (p1.failure) |e| return e;
    if (p2.failure) |e| return e;
}

test "T7 reglas: por defecto las de codigo limpio de agent_def y una sola fuente" {
    const a = std.testing.allocator;
    const ctx: Context = .{};
    const rules = try ctx.currentRules(a);
    defer a.free(rules);
    try std.testing.expectEqualStrings(agent_def.CLEAN_CODE_RULES, rules);
    const block = try ctx.blockForApi(a, null);
    defer a.free(block);
    try std.testing.expect(std.mem.indexOf(u8, block, HEADER) != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "RAII") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, PRECEDENCE_NOTE) != null);
}

test "T7 reglas: guardadas por proyecto en el motor, propias sustituyen a las de defecto" {
    const a = std.testing.allocator;
    var ctx: Context = .{};
    defer ctx.deinit(a);
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try conn.exec("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
    try std.testing.expect((try load(a, conn, "C:\\Proyecto")) == null);
    try save(conn, a, "C:\\Proyecto\\", "Usa tabuladores.\nNunca uses eval.");
    // Misma carpeta con otra grafía: mismo proyecto.
    const back = (try load(a, conn, "c:/proyecto")).?;
    defer a.free(back);
    try std.testing.expectEqualStrings("Usa tabuladores.\nNunca uses eval.", back);
    try std.testing.expect((try load(a, conn, "C:\\Otro")) == null);
    ctx.deinit(a);
    ctx = try loadContext(a, conn, "C:\\Proyecto");
    try std.testing.expect(ctx.isCustom());
    const block = try ctx.blockForCli(a);
    defer a.free(block);
    try std.testing.expect(std.mem.indexOf(u8, block, "Nunca uses eval.") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "RAII") == null);
    // Vacío = volver a las de DevAgents.
    try save(conn, a, "C:\\Proyecto", "  ");
    ctx.deinit(a);
    ctx = try loadContext(a, conn, "C:\\Proyecto");
    try std.testing.expect(!ctx.isCustom());
    var too_big: [MAX_RULES_BYTES + 1]u8 = undefined;
    @memset(&too_big, 'x');
    try std.testing.expectError(error.RulesTooLarge, save(conn, a, "C:\\Proyecto", &too_big));
}

test "T7 reglas: las reglas del repositorio y las reglas del repositorio del proyecto llegan detras y mandan" {
    const a = std.testing.allocator;
    var ctx: Context = .{};
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const dir = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(dir);
    try tmp.dir.writeFile(io, .{ .sub_path = "AGENTS.md", .data = "Indenta con 2 espacios." });
    ctx = .{ .root = dir, .custom = "Indenta con 4 espacios." };
    const block = try ctx.blockForApi(a, null);
    defer a.free(block);
    const rules_at = std.mem.indexOf(u8, block, "Indenta con 4 espacios.").?;
    const doc_at = std.mem.indexOf(u8, block, "Indenta con 2 espacios.").?;
    try std.testing.expect(rules_at < doc_at);
    try std.testing.expect(std.mem.indexOf(u8, block, "AGENTS.md · mandan sobre las reglas anteriores") != null);
    try std.testing.expect(std.mem.indexOf(u8, block, "CLAUDE.md · mandan") == null);
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try conn.exec("CREATE TABLE settings (key TEXT PRIMARY KEY, value TEXT NOT NULL)");
    try save(conn, a, dir, ctx.custom);
    const described = try describeJson(a, conn, dir);
    defer a.free(described);
    try std.testing.expect(std.mem.indexOf(u8, described, "\"projectDocs\":[\"AGENTS.md\"]") != null);
    try std.testing.expect(std.mem.indexOf(u8, described, "\"custom\":true") != null);
}

test "T7 reglas: el encargo a una CLI lleva el bloque una sola vez" {
    const a = std.testing.allocator;
    const ctx: Context = .{};
    const once = try ctx.withCliBlock(a, "Crea hola.py");
    defer a.free(once);
    try std.testing.expect(std.mem.startsWith(u8, once, "Crea hola.py"));
    try std.testing.expectEqual(@as(usize, 1), std.mem.count(u8, once, HEADER));
    const twice = try ctx.withCliBlock(a, once);
    defer a.free(twice);
    try std.testing.expectEqualStrings(once, twice);
}
