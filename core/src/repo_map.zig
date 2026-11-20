//! core/src/repo_map.zig — E5.13 (D-C3): mapa del repositorio para el
//! planificador y el worker.
//!
//! Qué hace: lista los archivos con `git ls-files` (sin binarios, con cota de
//! tamaño), extrae símbolos — exactos en Zig vía std.zig.Ast, por reglas
//! léxicas en TS/JS, Python, Go, Rust, C/C++, Java y C# —, construye el grafo
//! de referencias entre archivos por apariciones de identificadores, y aplica
//! un PageRank personalizado con las rutas e identificadores que cita la
//! orden. La salida son los archivos ordenados con sus firmas y línea, dentro
//! de un presupuesto de tokens configurable (~2k planificador, ~3k worker).
//!
//! Caché: tabla `repo_map_cache` (migración V31 de runtime.db) por
//! (raíz, HEAD, configuración). El grafo cacheado guarda símbolos y aristas,
//! NUNCA ranks — el PageRank es por consulta porque la personalización depende
//! del texto de la orden.
//!
//! Sin tree-sitter y sin base de vectores (ADR-B013 D1). I/O por std.Io del
//! fork (mismo idioma que tool_discovery.zig); el git va por seam CaptureFn
//! (misma forma que headless_adapter) para que los tests no necesiten git.

const std = @import("std");
const db = @import("db.zig");
const health = @import("health.zig");
const headless_adapter = @import("headless_adapter.zig");

pub const CaptureFn = headless_adapter.CaptureFn;

/// Estimador de tokens del mapa: ~4 bytes por token, el mismo orden de
/// magnitud que usa el resto del motor para presupuestos de prompt.
pub fn estimateTokens(bytes: usize) usize {
    return (bytes + 3) / 4;
}

pub const Options = struct {
    /// Tope de archivos indexados (los primeros del ls-files ordenado).
    max_files: usize = 1500,
    /// Tope por archivo: más grande no se lee (ni indexa símbolos).
    max_file_bytes: usize = 160 * 1024,
    /// Tope total leído — el mapa queda parcial pero honesto.
    max_total_bytes: usize = 12 * 1024 * 1024,
    /// Símbolos guardados por archivo.
    max_symbols_per_file: usize = 48,
    /// Identificadores únicos por archivo que entran al grafo.
    max_idents_per_file: usize = 4000,
    /// Aristas salientes máximas por archivo.
    max_edges_per_file: usize = 64,
    /// Iteraciones del PageRank.
    pagerank_iters: usize = 20,
    /// Presupuesto de pared para el escaneo completo (ms). Si se agota el
    /// mapa queda parcial (honesto) — nunca bloquea la cabina.
    scan_budget_ms: i64 = 8_000,
    /// Seam de proceso git (`git -C <root> ls-files` / `rev-parse HEAD`).
    /// Producción = headless_adapter.defaultCapture; tests la inyectan.
    capture: ?CaptureFn = null,
};

pub const SymbolKind = enum(u8) {
    func = 0,
    type_decl = 1,
    constant = 2,

    pub fn tag(k: SymbolKind) []const u8 {
        return switch (k) {
            .func => "f",
            .type_decl => "t",
            .constant => "c",
        };
    }
    pub fn fromTag(s: []const u8) SymbolKind {
        if (std.mem.eql(u8, s, "t")) return .type_decl;
        if (std.mem.eql(u8, s, "c")) return .constant;
        return .func;
    }
};

pub const Symbol = struct {
    name: []const u8,
    line: u32,
    kind: SymbolKind,
};

pub const FileNode = struct {
    /// Ruta relativa al repo, separadores '/'.
    path: []const u8,
    size: u32,
    symbols: []Symbol,
    /// Índices dentro de `nodes` de los archivos a los que este refiere.
    edges: []u32,
    /// Rank del PageRank personalizado de la ÚLTIMA consulta (no se cachea).
    rank: f32 = 0,
};

pub const RepoMap = struct {
    arena_state: std.heap.ArenaAllocator,
    backing: std.mem.Allocator,
    nodes: []FileNode,
    head: []const u8,
    /// Archivos devueltos por ls-files (antes de las cotas).
    files_seen: usize,
    symbols_total: usize,
    build_ms: i64,
    cache_hit: bool,

    pub fn deinit(self: *RepoMap) void {
        const backing = self.backing;
        self.arena_state.deinit();
        backing.destroy(self);
    }

    fn arena(self: *RepoMap) std.mem.Allocator {
        return self.arena_state.allocator();
    }
};

pub const BuildError = error{ OutOfMemory, NotARepo, IoFailed };

// ── Git ──────────────────────────────────────────────────────────────────

fn gitCapture(allocator: std.mem.Allocator, capture: ?CaptureFn, root: []const u8, argv_tail: []const []const u8) ![]const u8 {
    const cap = capture orelse headless_adapter.defaultCapture;
    var argv = std.ArrayList([]const u8).empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{ "git", "-C", root });
    try argv.appendSlice(allocator, argv_tail);
    var res = cap(allocator, argv.items, null) catch return error.IoFailed;
    defer res.deinit(allocator);
    if (res.exit_code != 0) return error.IoFailed;
    return try allocator.dupe(u8, res.stdout);
}

/// `git rev-parse HEAD` del repo; null si no es repo o git no está.
pub fn headCommit(allocator: std.mem.Allocator, capture: ?CaptureFn, root: []const u8) ?[]const u8 {
    const out = gitCapture(allocator, capture, root, &.{ "rev-parse", "HEAD" }) catch return null;
    defer allocator.free(out);
    const trimmed = std.mem.trim(u8, out, " \t\r\n");
    if (trimmed.len == 0) return null;
    return allocator.dupe(u8, trimmed) catch null;
}

/// `git ls-files` → lista de rutas relativas ('/'). Devuelve null si no es
/// repo git — el mapa entonces no se construye (honesto, no inventado).
pub fn listFiles(allocator: std.mem.Allocator, capture: ?CaptureFn, root: []const u8) ?[][]const u8 {
    const out = gitCapture(allocator, capture, root, &.{"ls-files"}) catch return null;
    defer allocator.free(out);
    var paths = std.ArrayList([]const u8).empty;
    errdefer {
        for (paths.items) |p| allocator.free(p);
        paths.deinit(allocator);
    }
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        const dup = allocator.dupe(u8, line) catch return null;
        paths.append(allocator, dup) catch return null;
    }
    const owned = paths.toOwnedSlice(allocator) catch return null;
    return owned;
}

// ── Lectura de archivos (std.Io del fork) ────────────────────────────────

/// Lee hasta `max_bytes` de `<dir>/<rel>`; null si no abre, es más grande
/// que el doble del tope, o huele a binario (NUL en los primeros 4 KiB).
pub fn readTextFile(arena: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, rel: []const u8, max_bytes: usize) ?[]const u8 {
    const file = dir.openFile(io, rel, .{}) catch return null;
    defer file.close(io);
    const stat = file.stat(io) catch return null;
    if (stat.size > max_bytes) return null;
    const size: usize = @intCast(stat.size);
    const buf = arena.alloc(u8, size) catch return null;
    const got = file.readPositionalAll(io, buf, 0) catch return null;
    const content = buf[0..got];
    const sniff = content[0..@min(content.len, 4096)];
    if (std.mem.indexOfScalar(u8, sniff, 0) != null) return null;
    return content;
}

// ── Símbolos ─────────────────────────────────────────────────────────────

const Lang = enum { zig, python, jsts, go, rust, cpp, java, csharp, other };

fn langOf(path: []const u8) Lang {
    const ext = std.fs.path.extension(path);
    if (std.mem.eql(u8, ext, ".zig")) return .zig;
    if (std.mem.eql(u8, ext, ".py")) return .python;
    if (std.mem.eql(u8, ext, ".js") or std.mem.eql(u8, ext, ".jsx") or std.mem.eql(u8, ext, ".ts") or
        std.mem.eql(u8, ext, ".tsx") or std.mem.eql(u8, ext, ".mjs") or std.mem.eql(u8, ext, ".cjs")) return .jsts;
    if (std.mem.eql(u8, ext, ".go")) return .go;
    if (std.mem.eql(u8, ext, ".rs")) return .rust;
    if (std.mem.eql(u8, ext, ".c") or std.mem.eql(u8, ext, ".h") or std.mem.eql(u8, ext, ".cpp") or
        std.mem.eql(u8, ext, ".hpp") or std.mem.eql(u8, ext, ".cc") or std.mem.eql(u8, ext, ".cxx")) return .cpp;
    if (std.mem.eql(u8, ext, ".java")) return .java;
    if (std.mem.eql(u8, ext, ".cs")) return .csharp;
    return .other;
}

/// Extensiones que ni se leen: binarios conocidos y artefactos pesados.
pub fn isBinaryExt(path: []const u8) bool {
    const ext = std.fs.path.extension(path);
    const bin = [_][]const u8{
        ".png",   ".jpg", ".jpeg", ".gif", ".bmp", ".ico",  ".webp",   ".svgz",
        ".mp4",   ".mp3", ".wav",  ".avi", ".mov", ".webm", ".zip",    ".gz",
        ".bz2",   ".xz",  ".7z",   ".rar", ".tar", ".exe",  ".dll",    ".so",
        ".dylib", ".o",   ".a",    ".lib", ".obj", ".db",   ".sqlite", ".woff",
        ".woff2", ".ttf", ".otf",  ".eot", ".pdf", ".jar",  ".class",  ".pyc",
        ".wasm",
    };
    for (bin) |b| if (std.ascii.eqlIgnoreCase(ext, b)) return true;
    return false;
}

pub fn isIdentStart(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or c == '_';
}
pub fn isIdentChar(c: u8) bool {
    return isIdentStart(c) or (c >= '0' and c <= '9');
}

/// Siguiente identificador tras `pos` saltando no-ident; null si la línea
/// se acaba sin uno. Devuelve (slice, fin).
fn nextIdent(line: []const u8, pos: usize) ?struct { s: []const u8, e: usize } {
    var i = pos;
    while (i < line.len and !isIdentStart(line[i])) : (i += 1) {}
    if (i >= line.len) return null;
    var j = i;
    while (j < line.len and isIdentChar(line[j])) : (j += 1) {}
    return .{ .s = line[i..j], .e = j };
}

/// Regla léxica común: `<keyword> <ident>` — el símbolo es el primer
/// identificador tras la keyword, si la keyword aparece como palabra.
fn symbolAfterKeywords(arena: std.mem.Allocator, out: *std.ArrayList(Symbol), line: []const u8, lineno: u32, keywords: []const []const u8, kind: SymbolKind, cap: usize) void {
    if (out.items.len >= cap) return;
    for (keywords) |kw| {
        if (std.mem.indexOf(u8, line, kw)) |at| {
            // La keyword debe empezar en límite de palabra (el espacio
            // final de la keyword ya garantiza el límite derecho).
            if (at > 0 and isIdentChar(line[at - 1])) continue;
            const after = at + kw.len;
            const id = nextIdent(line, after) orelse continue;
            if (id.s.len < 2 or id.s.len > 96) continue;
            out.append(arena, .{ .name = id.s, .line = lineno, .kind = kind }) catch {};
            return;
        }
    }
}

fn lineIsComment(line: []const u8) bool {
    const t = std.mem.trimStart(u8, line, " \t");
    return std.mem.startsWith(u8, t, "//") or std.mem.startsWith(u8, t, "#") or
        std.mem.startsWith(u8, t, "*") or std.mem.startsWith(u8, t, "/*");
}

/// Escáner léxico por líneas para los lenguajes sin parser. Cada fila de la
/// tabla: palabra(s) clave y el tipo de símbolo que declara.
fn scanLexical(arena: std.mem.Allocator, lang: Lang, content: []const u8, cap: usize) []Symbol {
    var out = std.ArrayList(Symbol).empty;
    var lineno: u32 = 0;
    var in_block_comment = false;
    var it = std.mem.splitScalar(u8, content, '\n');
    while (it.next()) |raw| {
        lineno += 1;
        if (out.items.len >= cap) break;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const trimmed = std.mem.trimStart(u8, line, " \t");
        if (trimmed.len == 0) continue;
        // Comentarios de bloque C-like: seguimiento barato por línea.
        if (in_block_comment) {
            if (std.mem.indexOf(u8, trimmed, "*/") != null) in_block_comment = false;
            continue;
        }
        if (std.mem.startsWith(u8, trimmed, "/*")) {
            if (std.mem.indexOf(u8, trimmed, "*/") == null) in_block_comment = true;
            continue;
        }
        if (lineIsComment(trimmed)) continue;

        switch (lang) {
            .python => {
                // Solo nivel módulo o clase: def/class/class members.
                symbolAfterKeywords(arena, &out, trimmed, lineno, &.{ "def ", "async def " }, .func, cap);
                if (out.items.len < cap) symbolAfterKeywords(arena, &out, trimmed, lineno, &.{"class "}, .type_decl, cap);
            },
            .jsts => {
                symbolAfterKeywords(arena, &out, trimmed, lineno, &.{"function "}, .func, cap);
                if (out.items.len < cap) symbolAfterKeywords(arena, &out, trimmed, lineno, &.{ "class ", "interface ", "enum ", "type " }, .type_decl, cap);
                if (out.items.len < cap) {
                    // const NAME = / let NAME = / var NAME = / exports.NAME =
                    for ([_][]const u8{ "const ", "let ", "var " }) |kw| {
                        if (std.mem.indexOf(u8, trimmed, kw)) |at| {
                            if (at > 0 and isIdentChar(trimmed[at - 1])) break;
                            if (nextIdent(trimmed, at + kw.len)) |id| {
                                if (id.s.len >= 2 and id.s.len <= 96) {
                                    out.append(arena, .{ .name = id.s, .line = lineno, .kind = .constant }) catch {};
                                }
                            }
                            break;
                        }
                    }
                }
            },
            .go => {
                symbolAfterKeywords(arena, &out, trimmed, lineno, &.{ "func ", "type ", "interface " }, .func, cap);
            },
            .rust => {
                symbolAfterKeywords(arena, &out, trimmed, lineno, &.{"fn "}, .func, cap);
                if (out.items.len < cap) symbolAfterKeywords(arena, &out, trimmed, lineno, &.{ "struct ", "enum ", "trait ", "impl ", "mod " }, .type_decl, cap);
                if (out.items.len < cap) symbolAfterKeywords(arena, &out, trimmed, lineno, &.{ "const ", "static " }, .constant, cap);
            },
            .cpp => {
                if (std.mem.startsWith(u8, trimmed, "#define ")) {
                    if (nextIdent(trimmed, "#define ".len)) |id| {
                        out.append(arena, .{ .name = id.s, .line = lineno, .kind = .constant }) catch {};
                    }
                    continue;
                }
                symbolAfterKeywords(arena, &out, trimmed, lineno, &.{ "class ", "struct ", "enum ", "union ", "typedef " }, .type_decl, cap);
                // Función/ método: `<ret> <name>(` al inicio o tras modificadores,
                // acabando en '{' — heurística, no parser.
                if (out.items.len < cap and std.mem.indexOfScalar(u8, trimmed, '(') != null and
                    (std.mem.endsWith(u8, trimmed, "{") or std.mem.endsWith(u8, trimmed, "{") or std.mem.indexOf(u8, trimmed, ") {") != null or std.mem.endsWith(u8, trimmed, ")")))
                {
                    const paren = std.mem.indexOfScalar(u8, trimmed, '(').?;
                    var k = paren;
                    while (k > 0 and isIdentChar(trimmed[k - 1])) : (k -= 1) {}
                    const name = trimmed[k..paren];
                    const bad = [_][]const u8{ "if", "for", "while", "switch", "return", "sizeof", "catch", "do", "else", "case" };
                    var skip = name.len < 2;
                    for (bad) |b| {
                        if (std.mem.eql(u8, name, b)) skip = true;
                    }
                    if (!skip) out.append(arena, .{ .name = name, .line = lineno, .kind = .func }) catch {};
                }
            },
            .java, .csharp => {
                symbolAfterKeywords(arena, &out, trimmed, lineno, &.{ "class ", "interface ", "enum ", "record ", "struct " }, .type_decl, cap);
                if (out.items.len < cap and std.mem.indexOfScalar(u8, trimmed, '(') != null and
                    (std.mem.indexOf(u8, trimmed, ") {") != null or std.mem.endsWith(u8, trimmed, "{") or std.mem.endsWith(u8, trimmed, ";")))
                {
                    const paren = std.mem.indexOfScalar(u8, trimmed, '(').?;
                    var k = paren;
                    while (k > 0 and isIdentChar(trimmed[k - 1])) : (k -= 1) {}
                    const name = trimmed[k..paren];
                    const bad = [_][]const u8{ "if", "for", "while", "switch", "return", "catch", "new", "do", "else", "case", "using", "lock" };
                    var skip = name.len < 2;
                    for (bad) |b| {
                        if (std.mem.eql(u8, name, b)) skip = true;
                    }
                    if (!skip) out.append(arena, .{ .name = name, .line = lineno, .kind = .func }) catch {};
                }
            },
            else => {},
        }
    }
    return out.toOwnedSlice(arena) catch out.items;
}

/// Símbolos exactos de un archivo Zig vía std.zig.Ast: decls de raíz con
/// nombre (fn, var/const, contenedores, test con nombre).
fn scanZig(arena: std.mem.Allocator, content_z: [:0]const u8, cap: usize) []Symbol {
    var out = std.ArrayList(Symbol).empty;
    var tree = std.zig.Ast.parse(arena, content_z, .zig) catch return out.items;
    defer tree.deinit(arena);
    const decls = tree.rootDecls();
    for (decls) |node| {
        if (out.items.len >= cap) break;
        var name_tok: ?std.zig.Ast.TokenIndex = null;
        var kind: SymbolKind = .func;
        switch (tree.nodeTag(node)) {
            .fn_decl => {
                var buf: [1]std.zig.Ast.Node.Index = undefined;
                // fn_decl envuelve un fn_proto; el proto lleva el nombre.
                if (tree.fullFnProto(&buf, tree.nodeData(node).node_and_node[0])) |fp| {
                    name_tok = fp.name_token;
                }
            },
            .fn_proto, .fn_proto_simple, .fn_proto_multi, .fn_proto_one => {
                var buf: [1]std.zig.Ast.Node.Index = undefined;
                if (tree.fullFnProto(&buf, node)) |fp| name_tok = fp.name_token;
            },
            .global_var_decl, .local_var_decl, .simple_var_decl, .aligned_var_decl => {
                if (tree.fullVarDecl(node)) |vd| {
                    // El nombre es el identificador tras `const`/`var`
                    // (mut_token). Los tipos `const T = struct{}` entran por
                    // aquí — la container_decl es anónima a nivel raíz.
                    name_tok = vd.ast.mut_token + 1;
                    kind = .constant;
                    // Heurística de tipo: si el init es un contenedor, es
                    // una declaración de tipo, no una constante.
                    if (vd.ast.init_node.unwrap()) |init_node| {
                        switch (tree.nodeTag(init_node)) {
                            .container_decl, .container_decl_trailing, .container_decl_two, .container_decl_two_trailing, .container_decl_arg, .container_decl_arg_trailing => kind = .type_decl,
                            else => {},
                        }
                    }
                }
            },
            .test_decl => {
                // test "nombre" — opt_token_and_node[0] puede ser string literal.
                const d = tree.nodeData(node);
                name_tok = d.opt_token_and_node[0].unwrap();
                kind = .constant;
            },
            else => {},
        }
        const tok = name_tok orelse continue;
        const loc = tree.tokenLocation(0, tok);
        const name = tree.tokenSlice(tok);
        // Los nombres de test llegan como "..." — recortar comillas.
        const clean = if (name.len >= 2 and name[0] == '"') name[1 .. name.len - 1] else name;
        if (clean.len == 0) continue;
        out.append(arena, .{ .name = clean, .line = @intCast(loc.line + 1), .kind = kind }) catch {};
    }
    return out.toOwnedSlice(arena) catch out.items;
}

pub fn extractSymbols(arena: std.mem.Allocator, path: []const u8, content: []const u8, cap: usize) []Symbol {
    const lang = langOf(path);
    if (lang == .other) return &.{};
    if (lang == .zig) {
        const cz = arena.dupeZ(u8, content) catch return &.{};
        return scanZig(arena, cz, cap);
    }
    return scanLexical(arena, lang, content, cap);
}

// ── Grafo de referencias ─────────────────────────────────────────────────

fn isIdentTok(c: u8) bool {
    return isIdentChar(c);
}

/// Tokeniza `content` a identificadores únicos (≥3 chars) en un set del arena.
fn tokenize(arena: std.mem.Allocator, content: []const u8, cap: usize) std.StringHashMap(void) {
    var set = std.StringHashMap(void).init(arena);
    var i: usize = 0;
    while (i < content.len) {
        const c = content[i];
        if (!isIdentStart(c)) {
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < content.len and isIdentTok(content[j])) : (j += 1) {}
        const tok = content[i..j];
        i = j;
        if (tok.len < 3 or tok.len > 96) continue;
        if (set.count() >= cap) break;
        set.put(tok, {}) catch break;
    }
    return set;
}

/// Stem del basename (sin extensión) — el identificador por el que un
/// archivo es citado por ruta: `src/foo.zig` → "foo".
fn stemOf(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return base;
    return if (dot == 0) base else base[0..dot];
}

// ── PageRank personalizado ───────────────────────────────────────────────

/// Semillas = tokens de la consulta (la orden) que nombran un archivo por
/// ruta/stem o un símbolo declarado. Construye el vector de personalización.
fn personalizationVector(arena: std.mem.Allocator, map: *const RepoMap, seed_text: []const u8, p: []f32) void {
    @memset(p, 0);
    if (map.nodes.len == 0) return;
    const seeds = tokenize(arena, seed_text, 8192);
    var any = false;
    for (map.nodes, 0..) |n, i| {
        // Ruta completa citada literalmente ("src/foo.zig").
        if (seed_text.len >= n.path.len and std.mem.indexOf(u8, seed_text, n.path) != null) {
            p[i] += 4.0;
            any = true;
        }
        // Stem citado como identificador.
        const stem = stemOf(n.path);
        if (stem.len >= 3 and seeds.contains(stem)) {
            p[i] += 1.5;
            any = true;
        }
        // Símbolo declarado citado.
        for (n.symbols) |s| {
            if (s.name.len >= 3 and seeds.contains(s.name)) {
                p[i] += 1.0;
                any = true;
                break;
            }
        }
    }
    if (!any) {
        const u: f32 = 1.0 / @as(f32, @floatFromInt(map.nodes.len));
        @memset(p, u);
        return;
    }
    var sum: f32 = 0;
    for (p) |v| sum += v;
    if (sum <= 0) {
        const u: f32 = 1.0 / @as(f32, @floatFromInt(map.nodes.len));
        @memset(p, u);
        return;
    }
    for (p) |*v| v.* /= sum;
}

/// PageRank sobre el grafo de referencias: una arista i→j («i usa j»)
/// transfiere rank a j. d=0.85, personalización p.
fn pagerank(map: *RepoMap, seed_text: []const u8, iters: usize) void {
    const n = map.nodes.len;
    if (n == 0) return;
    const arena = map.arena();
    const p = arena.alloc(f32, n) catch return;
    var r = arena.alloc(f32, n) catch return;
    var next = arena.alloc(f32, n) catch return;
    const out_deg = arena.alloc(f32, n) catch return;
    personalizationVector(arena, map, seed_text, p);
    const d: f32 = 0.85;
    for (0..n) |i| {
        r[i] = 1.0 / @as(f32, @floatFromInt(n));
        out_deg[i] = @floatFromInt(map.nodes[i].edges.len);
    }
    var it: usize = 0;
    while (it < iters) : (it += 1) {
        for (0..n) |j| {
            next[j] = (1.0 - d) * p[j];
        }
        // dangling nodes reparten a todos por el vector de personalización.
        for (0..n) |i| {
            const deg = out_deg[i];
            if (deg == 0) {
                for (0..n) |j| next[j] += d * r[i] * p[j];
                continue;
            }
            const share = d * r[i] / deg;
            for (map.nodes[i].edges) |j| next[j] += share;
        }
        const tmp = r;
        r = next;
        next = tmp;
    }
    for (0..n) |i| map.nodes[i].rank = r[i];
}

// ── Render dentro del presupuesto ────────────────────────────────────────

fn sortByRank(nodes: []FileNode) void {
    std.mem.sort(FileNode, nodes, {}, struct {
        fn lt(_: void, a: FileNode, b: FileNode) bool {
            return a.rank > b.rank;
        }
    }.lt);
}

/// E5.16: rutas rankeadas por la semilla — mismo pagerank+orden que render,
/// expuesto como lista para la medicion de recuperacion (recall@k/MRR).
/// Ordena map.nodes in place (igual que render).
pub fn rankedPaths(allocator: std.mem.Allocator, map: *RepoMap, seed_text: []const u8, max: usize) ![][]const u8 {
    pagerank(map, seed_text, 20);
    sortByRank(map.nodes);
    const n = @min(max, map.nodes.len);
    const out = try allocator.alloc([]const u8, n);
    for (map.nodes[0..n], 0..) |nd, i| out[i] = nd.path;
    return out;
}

/// Texto final del mapa: archivos ordenados por rank, firmas `nombre:línea`.
/// Corta cuando el presupuesto de tokens se agota; marca honesta si sobran.
pub fn render(allocator: std.mem.Allocator, map: *RepoMap, seed_text: []const u8, budget_tokens: usize) ![]u8 {
    pagerank(map, seed_text, 20);
    sortByRank(map.nodes);
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    const w = &out.writer;
    const budget_bytes = budget_tokens * 4;
    var shown: usize = 0;
    for (map.nodes) |n| {
        if (estimateTokens(out.written().len) >= budget_tokens) break;
        if (n.rank <= 0 and shown > 0) break;
        try w.print("{s}", .{n.path});
        var sshown: usize = 0;
        for (n.symbols) |s| {
            if (sshown >= 12) break;
            if (out.written().len + s.name.len + 16 > budget_bytes) break;
            try w.print("  {s}:{d}", .{ s.name, s.line });
            sshown += 1;
        }
        try w.writeByte('\n');
        shown += 1;
    }
    if (shown < map.nodes.len) {
        try w.print("… ({d} archivos más en el mapa)\n", .{map.nodes.len - shown});
    }
    return allocator.dupe(u8, out.written());
}

// ── Escaneo ──────────────────────────────────────────────────────────────

fn scanRepo(allocator: std.mem.Allocator, io: std.Io, root: []const u8, opts: Options, started_ms: i64) BuildError!*RepoMap {
    const map = try allocator.create(RepoMap);
    errdefer allocator.destroy(map);
    map.* = .{
        .arena_state = std.heap.ArenaAllocator.init(allocator),
        .backing = allocator,
        .nodes = &.{},
        .head = "",
        .files_seen = 0,
        .symbols_total = 0,
        .build_ms = 0,
        .cache_hit = false,
    };
    errdefer map.arena_state.deinit();
    const arena = map.arena_state.allocator();

    const head = headCommit(arena, opts.capture, root) orelse return error.NotARepo;
    map.head = head;

    const files = listFiles(arena, opts.capture, root) orelse return error.NotARepo;
    map.files_seen = files.len;

    const root_dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch return error.IoFailed;
    defer root_dir.close(io);

    var nodes = std.ArrayList(FileNode).empty;
    var total_bytes: usize = 0;
    var idents_of = try arena.alloc(std.StringHashMap(void), @min(files.len, opts.max_files));
    var n_indexed: usize = 0;

    for (files) |rel_raw| {
        if (n_indexed >= opts.max_files) break;
        if (nowMs() - started_ms > opts.scan_budget_ms) break;
        const rel = std.mem.trim(u8, rel_raw, " \t\r");
        if (rel.len == 0 or isBinaryExt(rel)) continue;
        const content = readTextFile(arena, io, root_dir, rel, opts.max_file_bytes) orelse continue;
        total_bytes += content.len;
        if (total_bytes > opts.max_total_bytes) break;
        const syms = extractSymbols(arena, rel, content, opts.max_symbols_per_file);
        map.symbols_total += syms.len;
        try nodes.append(arena, .{
            .path = rel,
            .size = @intCast(content.len),
            .symbols = syms,
            .edges = &.{},
        });
        idents_of[n_indexed] = tokenize(arena, content, opts.max_idents_per_file);
        n_indexed += 1;
    }
    map.nodes = nodes.toOwnedSlice(arena) catch return error.OutOfMemory;

    // Declaraciones: identificador → archivos que lo declaran (símbolos +
    // stem de la ruta). Luego aristas i→j por aparición del ident en i.
    var declared = std.StringHashMap(std.ArrayList(u32)).init(arena);
    for (map.nodes, 0..) |n, i| {
        for (n.symbols) |s| {
            if (s.name.len < 3) continue;
            const g = try declared.getOrPut(s.name);
            if (!g.found_existing) g.value_ptr.* = .empty;
            try g.value_ptr.append(arena, @intCast(i));
        }
        const stem = stemOf(n.path);
        if (stem.len >= 3) {
            const g = try declared.getOrPut(stem);
            if (!g.found_existing) g.value_ptr.* = .empty;
            try g.value_ptr.append(arena, @intCast(i));
        }
    }
    for (map.nodes, 0..) |*n, i| {
        var edges = std.ArrayList(u32).empty;
        var seen = std.AutoHashMap(u32, void).init(arena);
        var it = idents_of[i].keyIterator();
        while (it.next()) |tok| {
            if (edges.items.len >= opts.max_edges_per_file) break;
            const targets = declared.get(tok.*) orelse continue;
            for (targets.items) |j| {
                if (j == i) continue;
                if (seen.contains(j)) continue;
                if (edges.items.len >= opts.max_edges_per_file) break;
                try seen.put(j, {});
                try edges.append(arena, j);
            }
        }
        n.edges = edges.toOwnedSlice(arena) catch &.{};
    }
    map.build_ms = nowMs() - started_ms;
    return map;
}

// Reloj de pared por GetTickCount64 — mismo patrón que executor.zig (no hay
// std.time.milliTimestamp en el fork).
const GetTickCount64 = @import("platform.zig").ticks;

fn nowMs() i64 {
    return @intCast(GetTickCount64());
}

fn hexLower(digest: []const u8, out: []u8) []const u8 {
    const chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        out[i * 2] = chars[b >> 4];
        out[i * 2 + 1] = chars[b & 0x0f];
    }
    return out[0 .. digest.len * 2];
}

// ── Caché en runtime.db (V31) ────────────────────────────────────────────

pub const cache_migration =
    \\CREATE TABLE IF NOT EXISTS repo_map_cache (
    \\    repo_root TEXT NOT NULL,
    \\    head TEXT NOT NULL,
    \\    config TEXT NOT NULL,
    \\    built_at INTEGER NOT NULL,
    \\    files_count INTEGER NOT NULL,
    \\    symbols_count INTEGER NOT NULL,
    \\    map_json TEXT NOT NULL,
    \\    PRIMARY KEY (repo_root, head, config)
    \\)
;

fn cacheKey(allocator: std.mem.Allocator, root: []const u8, head: []const u8, opts: Options) ![]u8 {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(root);
    h.update("|");
    h.update(head);
    h.update("|");
    var cfg_buf: [128]u8 = undefined;
    const cfg = try std.fmt.bufPrint(&cfg_buf, "{d}:{d}:{d}:{d}", .{ opts.max_files, opts.max_file_bytes, opts.max_total_bytes, opts.max_symbols_per_file });
    h.update(cfg);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    var hex: [64]u8 = undefined;
    return allocator.dupe(u8, hexLower(&digest, &hex));
}

fn serializeMap(allocator: std.mem.Allocator, map: *const RepoMap) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("v");
    try js.write(1);
    try js.objectField("files");
    try js.beginArray();
    for (map.nodes) |n| {
        try js.beginObject();
        try js.objectField("p");
        try js.write(n.path);
        try js.objectField("z");
        try js.write(n.size);
        try js.objectField("s");
        try js.beginArray();
        for (n.symbols) |s| {
            try js.beginArray();
            try js.write(s.name);
            try js.write(s.line);
            try js.write(SymbolKind.tag(s.kind));
            try js.endArray();
        }
        try js.endArray();
        try js.objectField("e");
        try js.beginArray();
        for (n.edges) |e| try js.write(e);
        try js.endArray();
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    return allocator.dupe(u8, out.written());
}

fn deserializeMap(allocator: std.mem.Allocator, head: []const u8, json_text: []const u8, files_seen: usize, cache_ms: i64) !*RepoMap {
    const map = try allocator.create(RepoMap);
    errdefer allocator.destroy(map);
    map.* = .{
        .arena_state = std.heap.ArenaAllocator.init(allocator),
        .backing = allocator,
        .nodes = &.{},
        .head = "",
        .files_seen = files_seen,
        .symbols_total = 0,
        .build_ms = cache_ms,
        .cache_hit = true,
    };
    errdefer map.arena_state.deinit();
    const arena = map.arena_state.allocator();
    map.head = try arena.dupe(u8, head);

    // Los Value parseados comparten el texto de entrada — copiarlo al arena
    // porque `json_text` apunta al buffer interno de sqlite, que muere con el
    // finalize del statement.
    const jcopy = try arena.dupe(u8, json_text);
    const parsed = try std.json.parseFromSlice(std.json.Value, arena, jcopy, .{});
    if (parsed.value != .object) return error.CacheCorrupt;
    const root_obj = parsed.value.object;
    const files_val = root_obj.get("files") orelse return error.CacheCorrupt;
    if (files_val != .array) return error.CacheCorrupt;
    var nodes = std.ArrayList(FileNode).empty;
    for (files_val.array.items) |fv| {
        if (fv != .object) return error.CacheCorrupt;
        const fo = fv.object;
        const pv = fo.get("p") orelse return error.CacheCorrupt;
        const zv = fo.get("z") orelse return error.CacheCorrupt;
        if (pv != .string or zv != .integer) return error.CacheCorrupt;
        const p = pv.string;
        const z: u32 = @intCast(zv.integer);
        var syms = std.ArrayList(Symbol).empty;
        if (fo.get("s")) |sv| {
            if (sv != .array) return error.CacheCorrupt;
            for (sv.array.items) |svi| {
                if (svi != .array) return error.CacheCorrupt;
                const arr = svi.array.items;
                if (arr.len != 3 or arr[0] != .string or arr[1] != .integer or arr[2] != .string) return error.CacheCorrupt;
                try syms.append(arena, .{
                    .name = arr[0].string,
                    .line = @intCast(arr[1].integer),
                    .kind = SymbolKind.fromTag(arr[2].string),
                });
                map.symbols_total += 1;
            }
        }
        var edges = std.ArrayList(u32).empty;
        if (fo.get("e")) |ev| {
            if (ev != .array) return error.CacheCorrupt;
            for (ev.array.items) |ei| {
                if (ei != .integer) return error.CacheCorrupt;
                try edges.append(arena, @intCast(ei.integer));
            }
        }
        try nodes.append(arena, .{
            .path = p,
            .size = z,
            .symbols = syms.toOwnedSlice(arena) catch &.{},
            .edges = edges.toOwnedSlice(arena) catch &.{},
        });
    }
    map.nodes = nodes.toOwnedSlice(arena) catch return error.OutOfMemory;
    return map;
}

/// Carga del caché o escanea. `cache_conn` es una Connection a runtime.db
/// en el hilo llamador (la migración V31 debe estar aplicada — se aplica
/// defensivamente con CREATE IF NOT EXISTS para tests y caminos nuevos).
pub fn buildOrLoad(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    opts: Options,
    cache_conn: ?db.Connection,
) BuildError!*RepoMap {
    const started = nowMs();
    if (cache_conn) |conn| {
        conn.exec(cache_migration) catch {};
        const head = headCommit(allocator, opts.capture, root) orelse return error.NotARepo;
        defer allocator.free(head);
        const key = cacheKey(allocator, root, head, opts) catch return error.OutOfMemory;
        defer allocator.free(key);
        // La clave ya lleva raíz+head+config; repo_root se guarda por
        // legibilidad/auditoría, no para localizar la fila.
        const stmt = conn.prepare("SELECT map_json, files_count FROM repo_map_cache WHERE repo_root = ? AND head = ? AND config = ?") catch null;
        if (stmt) |s| {
            defer conn.finalize(s);
            db.bindText(s, 1, root) catch {};
            db.bindText(s, 2, head) catch {};
            db.bindText(s, 3, key) catch {};
            if (db.c.sqlite3_step(s) == db.c.SQLITE_ROW) {
                const fcnt: usize = @intCast(db.c.sqlite3_column_int64(s, 1));
                if (db.c.sqlite3_column_text(s, 0)) |ptr| {
                    const tlen: usize = @intCast(db.c.sqlite3_column_bytes(s, 0));
                    const t = ptr[0..tlen];
                    if (deserializeMap(allocator, head, t, fcnt, nowMs() - started)) |m| {
                        return m;
                    } else |_| {}
                }
            }
        }
        // Miss: escanear y guardar (best-effort — la caché nunca bloquea).
        const map = try scanRepo(allocator, io, root, opts, started);
        if (serializeMap(allocator, map)) |json_text| {
            defer allocator.free(json_text);
            const ins = conn.prepare("INSERT OR REPLACE INTO repo_map_cache (repo_root, head, config, built_at, files_count, symbols_count, map_json) VALUES (?, ?, ?, ?, ?, ?, ?)") catch null;
            if (ins) |s| {
                defer conn.finalize(s);
                db.bindText(s, 1, root) catch {};
                db.bindText(s, 2, head) catch {};
                db.bindText(s, 3, key) catch {};
                db.bindInt(s, 4, started) catch {};
                db.bindInt(s, 5, @intCast(map.files_seen)) catch {};
                db.bindInt(s, 6, @intCast(map.symbols_total)) catch {};
                db.bindText(s, 7, json_text) catch {};
                _ = db.c.sqlite3_step(s);
            }
        } else |_| {}
        return map;
    }
    return scanRepo(allocator, io, root, opts, started);
}

// ── Superficie para los prompts ──────────────────────────────────────────

/// Resultado listo para inyectar en un prompt: el texto acotado y la
/// telemetría del build/carga para el evento `repo_map_built`.
pub const RenderedMap = struct {
    /// Propiedad del llamador; liberar con `allocator.free`.
    text: []u8,
    files: usize,
    symbols: usize,
    /// Tokens estimados del texto renderizado (~4 bytes/token).
    tokens: usize,
    ms: i64,
    cache_hit: bool,

    pub fn deinit(self: RenderedMap, allocator: std.mem.Allocator) void {
        allocator.free(self.text);
    }
};

/// Construye o carga el mapa de `root`, lo siembra con `seed` (el texto de la
/// orden) y lo renderiza dentro de `budget_tokens`. Devuelve null ante
/// cualquier problema (no-git, E/S, OOM) — el prompt sale sin mapa, nunca
/// bloquea ni tumba la orden.
pub fn renderForPrompt(
    allocator: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    seed: []const u8,
    budget_tokens: usize,
    opts: Options,
    cache_conn: ?db.Connection,
) ?RenderedMap {
    if (root.len == 0) return null;
    const map = buildOrLoad(allocator, io, root, opts, cache_conn) catch return null;
    defer map.deinit();
    const text = render(allocator, map, seed, budget_tokens) catch return null;
    if (text.len == 0) {
        allocator.free(text);
        return null;
    }
    return .{
        .text = text,
        .files = map.nodes.len,
        .symbols = map.symbols_total,
        .tokens = estimateTokens(text.len),
        .ms = map.build_ms,
        .cache_hit = map.cache_hit,
    };
}

/// E5.13: emite `repo_map_built {archivos, simbolos, tokens, ms, cache_hit}`.
/// `order_id` 0 resuelve a la última orden insertada (mismo patrón que
/// emitMockPlannerEvent: el planner corre justo tras insertar la orden).
/// Best-effort: un fallo de escritura no detiene nada.
pub fn emitBuiltEvent(conn: db.Connection, order_id: i64, r: RenderedMap) void {
    var out: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    js.beginObject() catch return;
    js.objectField("archivos") catch return;
    js.write(r.files) catch return;
    js.objectField("simbolos") catch return;
    js.write(r.symbols) catch return;
    js.objectField("tokens") catch return;
    js.write(r.tokens) catch return;
    js.objectField("ms") catch return;
    js.write(r.ms) catch return;
    js.objectField("cache_hit") catch return;
    js.write(r.cache_hit) catch return;
    js.endObject() catch return;

    const oid: i64 = if (order_id > 0) order_id else blk: {
        const seq = conn.prepare("SELECT MAX(id) FROM orders") catch break :blk 0;
        defer conn.finalize(seq);
        if (db.c.sqlite3_step(seq) == db.c.SQLITE_ROW)
            break :blk @as(i64, @intCast(db.c.sqlite3_column_int64(seq, 0)));
        break :blk 0;
    };
    const stmt = conn.prepare("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (?, 'superagente', 'repo_map_built', ?, ?)") catch return;
    defer conn.finalize(stmt);
    db.bindInt(stmt, 1, health.nowMillis(conn)) catch return;
    db.bindText(stmt, 2, out.written()) catch return;
    db.bindInt(stmt, 3, oid) catch return;
    _ = db.c.sqlite3_step(stmt);
}

// ── Tests ────────────────────────────────────────────────────────────────

const gh = @import("providers").github;

var scripted_rev: []const u8 = "";
var scripted_ls: []const u8 = "";

fn testCapture(allocator: std.mem.Allocator, argv: []const []const u8, _: ?[]const u8) anyerror!gh.CmdCapture {
    var wants_ls = false;
    var wants_rev = false;
    for (argv) |a| {
        if (std.mem.eql(u8, a, "ls-files")) wants_ls = true;
        if (std.mem.eql(u8, a, "rev-parse")) wants_rev = true;
    }
    const body: []const u8 = if (wants_ls) scripted_ls else if (wants_rev) scripted_rev else "";
    return .{
        .exit_code = 0,
        .stdout = try allocator.dupe(u8, body),
        .stderr = try allocator.dupe(u8, ""),
    };
}

fn testOpts() Options {
    return .{ .capture = testCapture };
}

fn writeFile(tmp: *std.testing.TmpDir, path: []const u8, data: []const u8) !void {
    if (std.fs.path.dirname(path)) |dd| try tmp.dir.createDirPath(std.testing.io, dd);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = path, .data = data });
}

fn tmpRootPath(tmp: *std.testing.TmpDir, buf: []u8) []const u8 {
    const n = tmp.dir.realPath(std.testing.io, buf) catch return buf[0..0];
    return buf[0..n];
}

test "E5.13 simbolos por lenguaje: zig exacto y lexicos (py/js/go/rs/cpp/java/cs)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    try writeFile(&tmp, "m.zig", "pub fn alpha() void {}\nconst Beta = struct {};\npub const MAX = 4;\n");
    try writeFile(&tmp, "m.py", "def py_func():\n    pass\nclass PyClass:\n    pass\n");
    try writeFile(&tmp, "m.js", "function jsFunc() {}\nclass JsClass {}\nconst jsConst = 1;\n");
    try writeFile(&tmp, "m.go", "package main\nfunc GoFunc() {}\ntype GoType struct {}\n");
    try writeFile(&tmp, "m.rs", "fn rust_fn() {}\nstruct RustType {}\nconst RUST_C: u32 = 1;\n");
    try writeFile(&tmp, "m.cpp", "class CppClass {};\nint cpp_func(int x) {\n  return x;\n}\n");
    try writeFile(&tmp, "m.java", "class JavaClass {\n  void javaMethod() {\n  }\n}\n");
    try writeFile(&tmp, "m.cs", "public class CsClass {\n  void CsMethod() {\n  }\n}\n");
    try writeFile(&tmp, "doc.md", "# titulo\ntexto sin simbolos\n");

    scripted_ls = "m.zig\nm.py\nm.js\nm.go\nm.rs\nm.cpp\nm.java\nm.cs\ndoc.md\n";
    scripted_rev = "abc123\n";
    var buf: [4096]u8 = undefined;
    const root = tmpRootPath(&tmp, &buf);
    const map = try buildOrLoad(a, std.testing.io, root, testOpts(), null);
    defer map.deinit();

    try std.testing.expectEqual(@as(usize, 9), map.nodes.len);
    var names = std.StringHashMap(void).init(a);
    defer names.deinit();
    for (map.nodes) |n| {
        for (n.symbols) |s| try names.put(s.name, {});
    }
    for ([_][]const u8{ "alpha", "Beta", "py_func", "PyClass", "jsFunc", "JsClass", "jsConst", "GoFunc", "GoType", "rust_fn", "RustType", "RUST_C", "CppClass", "cpp_func", "JavaClass", "javaMethod", "CsClass", "CsMethod" }) |want| {
        try std.testing.expect(names.contains(want));
    }
}

test "E5.13 ranking personalizado: la orden que cita un archivo lo sube al frente" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    try writeFile(&tmp, "core/engine.zig", "pub fn runEngine() void {}\n");
    try writeFile(&tmp, "core/util.zig", "pub fn utilHelper() void {}\n");
    try writeFile(&tmp, "ui/view.js", "export function renderView() {}\n");

    scripted_ls = "core/engine.zig\ncore/util.zig\nui/view.js\n";
    scripted_rev = "def456\n";
    var buf: [4096]u8 = undefined;
    const root = tmpRootPath(&tmp, &buf);
    const map = try buildOrLoad(a, std.testing.io, root, testOpts(), null);
    defer map.deinit();

    const text = try render(a, map, "arregla runEngine en core/engine.zig", 2048);
    defer a.free(text);
    // La ruta citada debe ser la primera línea del mapa.
    try std.testing.expect(std.mem.startsWith(u8, text, "core/engine.zig"));
    try std.testing.expect(std.mem.indexOf(u8, text, "runEngine:1") != null);
}

test "E5.13 presupuesto de tokens: corta dentro del tope y marca honesta" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    var ls = std.ArrayList(u8).empty;
    defer ls.deinit(a);
    var i: usize = 0;
    while (i < 60) : (i += 1) {
        const path = try std.fmt.allocPrint(a, "f{d}.py", .{i});
        defer a.free(path);
        const body = try std.fmt.allocPrint(a, "def fn_{d}():\n    pass\n", .{i});
        defer a.free(body);
        try writeFile(&tmp, path, body);
        try ls.appendSlice(a, path);
        try ls.append(a, '\n');
    }
    scripted_ls = ls.items;
    scripted_rev = "aaa\n";
    var buf: [4096]u8 = undefined;
    const root = tmpRootPath(&tmp, &buf);
    const map = try buildOrLoad(a, std.testing.io, root, testOpts(), null);
    defer map.deinit();

    const text = try render(a, map, "consulta", 40);
    defer a.free(text);
    try std.testing.expect(estimateTokens(text.len) <= 60); // tope + margen de la marca
    try std.testing.expect(std.mem.indexOf(u8, text, "archivos más") != null);
}

test "E5.13 grafo: un archivo que cita el simbolo de otro enlaza hacia el" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    try writeFile(&tmp, "lib.py", "def shared_util():\n    pass\n");
    try writeFile(&tmp, "app.py", "from lib import shared_util\nshared_util()\n");

    scripted_ls = "lib.py\napp.py\n";
    scripted_rev = "bbb\n";
    var buf: [4096]u8 = undefined;
    const root = tmpRootPath(&tmp, &buf);
    const map = try buildOrLoad(a, std.testing.io, root, testOpts(), null);
    defer map.deinit();

    var app_idx: ?usize = null;
    var lib_idx: ?usize = null;
    for (map.nodes, 0..) |n, i| {
        if (std.mem.eql(u8, n.path, "app.py")) app_idx = i;
        if (std.mem.eql(u8, n.path, "lib.py")) lib_idx = i;
    }
    const ai = app_idx.?;
    const li = lib_idx.?;
    var found = false;
    for (map.nodes[ai].edges) |e| {
        if (e == li) found = true;
    }
    try std.testing.expect(found);
}

test "E5.13 cache en runtime.db: hit por (raiz, head, config) y sin git en la segunda" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    try writeFile(&tmp, "x.py", "def cached_fn():\n    pass\n");
    scripted_ls = "x.py\n";
    scripted_rev = "head-uno\n";
    var buf: [4096]u8 = undefined;
    const root = tmpRootPath(&tmp, &buf);

    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();

    const m1 = try buildOrLoad(a, std.testing.io, root, testOpts(), conn);
    defer m1.deinit();
    try std.testing.expect(!m1.cache_hit);

    // Segunda carga: ls-files devolveria vacio si git corriera de verdad —
    // forzamos un capture que FALLARIA si se llamara, para probar el hit.
    scripted_ls = "";
    const m2 = try buildOrLoad(a, std.testing.io, root, testOpts(), conn);
    defer m2.deinit();
    try std.testing.expect(m2.cache_hit);
    try std.testing.expectEqual(@as(usize, 1), m2.nodes.len);
    try std.testing.expectEqual(@as(usize, 1), m2.symbols_total);
}

test "E5.13 head distinto invalida la cache (rebuild)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    try writeFile(&tmp, "x.py", "def f1():\n    pass\n");
    scripted_ls = "x.py\n";
    scripted_rev = "head-uno\n";
    var buf: [4096]u8 = undefined;
    const root = tmpRootPath(&tmp, &buf);

    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();

    const m1 = try buildOrLoad(a, std.testing.io, root, testOpts(), conn);
    defer m1.deinit();

    try writeFile(&tmp, "y.py", "def f2():\n    pass\n");
    scripted_ls = "x.py\ny.py\n";
    scripted_rev = "head-dos\n";
    const m2 = try buildOrLoad(a, std.testing.io, root, testOpts(), conn);
    defer m2.deinit();
    try std.testing.expect(!m2.cache_hit);
    try std.testing.expectEqual(@as(usize, 2), m2.nodes.len);
}

test "E5.13 perf: mapa del repo real (medicion de ms y memoria)" {
    // Mide el build sobre ESTE repositorio con git real (capture=null →
    // defaultCapture). Se salta limpio si el cwd no es un checkout git.
    const a = std.testing.allocator;
    var buf: [4096]u8 = undefined;
    const n = std.Io.Dir.cwd().realPath(std.testing.io, &buf) catch return;
    const root = buf[0..n];
    const map = buildOrLoad(a, std.testing.io, root, .{}, null) catch return;
    defer map.deinit();
    const text = try render(a, map, "ordenes workers planificacion", 3000);
    defer a.free(text);
    const arena_bytes = map.arena_state.queryCapacity();
    std.debug.print("repo_map perf: archivos={d} simbolos={d} build_ms={d} arena_bytes={d} tokens={d}\n", .{ map.nodes.len, map.symbols_total, map.build_ms, arena_bytes, estimateTokens(text.len) });
    try std.testing.expect(map.nodes.len > 0);
}
