//! E5.14 — `repo_search`: busqueda lexica BM25 rankeada sobre el repositorio.
//!
//! Contrato honesto: esto es ranking BM25 (term-frequency + document-
//! frequency) con boost de ruta y de nombre de simbolo — NO es busqueda
//! semantica (esa capa opcional es E5.15 y se reporta aparte). Enumera los
//! archivos por `git ls-files` (mismo helper que repo_map), parte cada
//! archivo en chunks (span de simbolo + ventana de lineas solapada),
//! tokeniza con pliegue camelCase/snake_case y rankea BM25 (k1=1.2,
//! b=0.75). El scoring se reparte en hilos sobre un contador atomico; la
//! seleccion top-N es determinista (desempate por indice de chunk).

const std = @import("std");
const repo_map = @import("repo_map.zig");
const gh = @import("providers").github;
const embeddings = @import("providers").embeddings;

pub const CaptureFn = repo_map.CaptureFn;
pub const SearchError = repo_map.BuildError;

/// E5.15: seam del embedder — devuelve un vector f32 por texto, en el mismo
/// orden. La implementacion cloud vive en c_api (providers.embeddings +
/// settings del catalogo); los tests inyectan vectores sinteticos.
pub const EmbedFn = *const fn (ctx: ?*anyopaque, allocator: std.mem.Allocator, texts: []const []const u8) anyerror![][]f32;

pub const Options = struct {
    max_files: usize = 1500,
    max_file_bytes: usize = 160 * 1024,
    max_total_bytes: usize = 12 * 1024 * 1024,
    max_results: usize = 20,
    threads: usize = 4,
    chunk_lines: u32 = 40,
    chunk_stride: u32 = 24,
    symbol_span_cap: u32 = 80,
    path_boost: f32 = 1.5,
    symbol_boost: f32 = 2.0,
    scan_budget_ms: i64 = 8_000,
    /// E5.15: rerank semantico sobre el pool BM25 top-`rerank_pool`. Solo
    /// actua si ademas hay `embed_fn` cableada — si no, el resultado sale
    /// con semantic_status="no_embedder" (fallback lexico honesto).
    semantic_rerank: bool = false,
    embed_fn: ?EmbedFn = null,
    embed_ctx: ?*anyopaque = null,
    rerank_pool: usize = 120,
    embed_max_chars: usize = 1200,
    /// E5.15: indice vectorial persistente (repo_embeddings, V32) cargado por
    /// el llamador para el modo hibrido. Con el indice presente la consulta
    /// hibrida funde por RRF el ranking BM25 con el ranking por coseno sobre
    /// TODOS los trozos indexados — puede subir un match que BM25 no vio. Sin
    /// indice (o vacio) se sigue con el rerank del pool live; `index.state`
    /// en la salida JSON lo declara (nunca se finge indice).
    vector_index: ?*const VectorIndex = null,
    /// E5.15: modo `semantic` — ranking PURAMENTE vectorial: el coseno ES el
    /// score y BM25 no participa. Solo compiten los trozos con vector
    /// (indice persistente) o del pool live; un coseno <= 0 no devuelve
    /// nada — el modo no inventa matches lexicos disfrazados de semanticos.
    /// Distinto de `hybrid` (RRF de los dos rankings) y exige semantic_rerank.
    semantic_only: bool = false,
    /// Nota de proveniencia impuesta por el llamador (p.ej. "disabled" o
    /// "no_key") cuando pide semantico sin poder cablear el embedder.
    semantic_note: ?[]const u8 = null,
    capture: ?CaptureFn = null,
};

pub const Match = struct {
    /// Ruta relativa al repo, separadores '/'.
    path: []const u8,
    /// Linea 1-based del snippet ganador dentro del chunk.
    line: u32,
    snippet: []const u8,
    score: f32,
    /// E5.15: procedencia del match — "bm25" (solo lexico), "vector" (solo
    /// semantico: BM25 le dio 0 pero el coseno lo trajo) o "bm25+vector".
    /// En modo lexico puro todo es "bm25". MCP lo expone por resultado.
    source: []const u8 = "bm25",
};

/// E5.15: indice vectorial cargado en memoria para una consulta. Lo construye
/// repo_embed.loadIndex desde repo_embeddings: clave = sha256 hex del texto
/// del trozo (la misma funcion que el indexador — si el trozo cambia, su
/// hash cambia y queda fuera del lado vectorial, honesto).
pub const VectorIndex = struct {
    map: std.StringHashMap([]f32),
    chunks_indexed: usize = 0,
    files_indexed: usize = 0,
    model: []const u8 = "",
    updated_at: i64 = 0,
};

/// Estado del indice vectorial tal como lo reporta la salida JSON/cabina.
pub const IndexInfo = struct {
    /// "ready" si hay vectores, "empty" si la tabla esta vacia para el repo.
    state: []const u8,
    chunks_indexed: usize,
    files_indexed: usize,
    model: []const u8,
    updated_at: i64,
};

pub const SearchResult = struct {
    arena_state: std.heap.ArenaAllocator,
    backing: std.mem.Allocator,
    matches: []Match,
    /// Archivos devueltos por ls-files.
    files_seen: usize,
    /// Archivos realmente indexados (post-cotas).
    files_scanned: usize,
    chunks_total: usize,
    elapsed_ms: i64,
    /// true si una cota corto el indice (resultado parcial honesto).
    truncated: bool,
    /// E5.15: "bm25" (lexico), "hybrid" (RRF de BM25 + coseno) o "semantic"
    /// (ranking puramente vectorial). Es contrato: el consumidor sabe
    /// EXACTAMENTE que rankeo.
    query_mode: []const u8 = "bm25",
    /// E5.15: null si no se pidio semantico; "ok" si el rerank corrio; si
    /// no, la razon honesta ("no_embedder", "disabled", "no_key",
    /// "index_empty", errorName del embedder…).
    semantic_status: ?[]const u8 = null,
    /// E5.15: estado del indice vectorial cuando el llamador lo cargo
    /// (modo hibrido); null = no se consulto indice.
    index: ?IndexInfo = null,

    pub fn deinit(self: *SearchResult) void {
        const backing = self.backing;
        self.arena_state.deinit();
        backing.destroy(self);
    }
};

// ── Tokenizacion con pliegue camelCase/snake ─────────────────────────────

fn isIdentStart(c: u8) bool {
    return std.ascii.isAlphabetic(c) or c == '_' or c >= 0x80;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

fn isLower(c: u8) bool {
    return c >= 'a' and c <= 'z';
}

fn isUpper(c: u8) bool {
    return c >= 'A' and c <= 'Z';
}

fn isDigit(c: u8) bool {
    return c >= '0' and c <= '9';
}

/// Un identificador crudo se pliega a: el token completo en minusculas +
/// cada sub-token por fronteras `_` y camelCase (`buildOrLoad` →
/// buildorload, build, or, load; `HTTPServer` → httpserver, http, server).
fn emitFolded(arena: std.mem.Allocator, out: *std.ArrayList([]const u8), raw: []const u8) void {
    if (raw.len < 2 or raw.len > 96) return;
    const low = std.ascii.allocLowerString(arena, raw) catch return;
    out.append(arena, low) catch return;
    var start: usize = 0;
    var i: usize = 1;
    while (i < raw.len) : (i += 1) {
        const prev = raw[i - 1];
        const cur = raw[i];
        const nxt: u8 = if (i + 1 < raw.len) raw[i + 1] else 0;
        const boundary = cur == '_' or prev == '_' or
            (isDigit(cur) != isDigit(prev)) or
            (isLower(prev) and isUpper(cur)) or
            (isUpper(prev) and isUpper(cur) and isLower(nxt));
        if (!boundary) continue;
        const piece = raw[start..i];
        start = if (cur == '_') i + 1 else i;
        if (piece.len >= 2 and std.mem.indexOfScalar(u8, piece, '_') == null) {
            const p = std.ascii.allocLowerString(arena, piece) catch continue;
            out.append(arena, p) catch return;
        }
    }
    if (start > 0 and start < raw.len) {
        const piece = raw[start..];
        if (piece.len >= 2 and std.mem.indexOfScalar(u8, piece, '_') == null) {
            const p = std.ascii.allocLowerString(arena, piece) catch return;
            out.append(arena, p) catch return;
        }
    }
}

/// Tokeniza texto libre a terminos plegados (con repeticiones — el tf las
/// quiere). Acotado por `cap` tokens.
fn tokenize(arena: std.mem.Allocator, text: []const u8, cap: usize) [][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var i: usize = 0;
    while (i < text.len and out.items.len < cap) {
        const c = text[i];
        if (!isIdentStart(c)) {
            i += 1;
            continue;
        }
        var j = i + 1;
        while (j < text.len and isIdentChar(text[j])) : (j += 1) {}
        emitFolded(arena, &out, text[i..j]);
        i = j;
    }
    return out.toOwnedSlice(arena) catch out.items;
}

/// Terminos de consulta: plegados, unicos, len>=2.
pub fn queryTerms(arena: std.mem.Allocator, query: []const u8) [][]const u8 {
    var out = std.ArrayList([]const u8).empty;
    var seen = std.StringHashMap(void).init(arena);
    for (tokenize(arena, query, 256)) |t| {
        if (t.len < 2 or seen.contains(t)) continue;
        seen.put(t, {}) catch continue;
        out.append(arena, t) catch break;
    }
    return out.toOwnedSlice(arena) catch out.items;
}

// ── Chunks ───────────────────────────────────────────────────────────────

pub const Chunk = struct {
    file_idx: u32,
    start_line: u32, // 1-based
    text: []const u8,
    /// Nombre de simbolo si el chunk es un span de simbolo (boost E5.14).
    sym: ?[]const u8,
    tokens: [][]const u8,
};

/// sha256 hex del texto del trozo — identidad del chunk en el indice vectorial
/// (repo_embeddings.chunk_hash). El indexador (repo_embed) y la consulta
/// hibrida deben producir la MISMA clave o los vectores no se encuentran.
pub fn chunkHashHex(text: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(text, &digest, .{});
    var hex: [64]u8 = undefined;
    const chars = "0123456789abcdef";
    for (digest, 0..) |b, i| {
        hex[i * 2] = chars[b >> 4];
        hex[i * 2 + 1] = chars[b & 15];
    }
    return hex;
}

/// Offset de byte donde empieza cada linea: offs[l-1] es el inicio de la
/// linea l (1-based). Incluye centinela con el largo del contenido.
fn lineOffsets(arena: std.mem.Allocator, content: []const u8) []usize {
    var offs = std.ArrayList(usize).empty;
    offs.append(arena, 0) catch return &.{};
    for (content, 0..) |c, i| {
        if (c == '\n') offs.append(arena, i + 1) catch break;
    }
    if (offs.items.len == 0 or offs.items[offs.items.len - 1] != content.len)
        offs.append(arena, content.len) catch {};
    return offs.toOwnedSlice(arena) catch offs.items;
}

fn chunkText(content: []const u8, offs: []const usize, start_line: u32, end_line: u32) []const u8 {
    if (start_line == 0 or end_line <= start_line) return "";
    const si: usize = @intCast(start_line - 1);
    const ei: usize = @intCast(end_line - 1);
    if (si >= offs.len) return "";
    const from = offs[si];
    const to = if (ei < offs.len) offs[ei] else content.len;
    if (to <= from) return "";
    return content[from..to];
}

/// Chunks de un archivo: un span por simbolo (hasta el siguiente simbolo o
/// `symbol_span_cap` lineas) + ventanas solapadas de `chunk_lines` cada
/// `chunk_stride`. Ambas vistas conviven: la ventana cubre lo que ningun
/// simbolo declaro y el span da hits de simbolo con linea precisa.
fn chunkFile(
    arena: std.mem.Allocator,
    out: *std.ArrayList(Chunk),
    file_idx: u32,
    path: []const u8,
    content: []const u8,
    opts: Options,
    token_cap: usize,
) void {
    const offs = lineOffsets(arena, content);
    const nlines: u32 = @intCast(@max(1, offs.len - 1));
    var starts = std.AutoHashMap(u32, void).init(arena);
    const syms = repo_map.extractSymbols(arena, path, content, 64);
    const sorted = arena.dupe(repo_map.Symbol, syms) catch syms;
    std.mem.sort(repo_map.Symbol, sorted, {}, struct {
        fn lt(_: void, a: repo_map.Symbol, b: repo_map.Symbol) bool {
            return a.line < b.line;
        }
    }.lt);
    for (sorted, 0..) |s, i| {
        if (s.line == 0 or s.line > nlines) continue;
        const next_line: u32 = if (i + 1 < sorted.len) sorted[i + 1].line else nlines + 1;
        const end = @min(@min(next_line, s.line + opts.symbol_span_cap), nlines + 1);
        if (starts.contains(s.line)) continue;
        starts.put(s.line, {}) catch {};
        const text = chunkText(content, offs, s.line, end);
        if (text.len == 0) continue;
        out.append(arena, .{
            .file_idx = file_idx,
            .start_line = s.line,
            .text = text,
            .sym = s.name,
            .tokens = tokenize(arena, text, token_cap),
        }) catch return;
    }
    var start: u32 = 1;
    while (start <= nlines) : (start += opts.chunk_stride) {
        if (starts.contains(start)) continue;
        starts.put(start, {}) catch {};
        const end = @min(start + opts.chunk_lines, nlines + 1);
        const text = chunkText(content, offs, start, end);
        if (text.len == 0) continue;
        out.append(arena, .{
            .file_idx = file_idx,
            .start_line = start,
            .text = text,
            .sym = null,
            .tokens = tokenize(arena, text, token_cap),
        }) catch return;
    }
}

// ── BM25 ─────────────────────────────────────────────────────────────────

const K1: f32 = 1.2;
const B: f32 = 0.75;
const BATCH: usize = 256;

const ScoreCtx = struct {
    chunks: []const Chunk,
    qterms: []const []const u8,
    idf: []const f32,
    avgdl: f32,
    /// Tokens plegados del path de cada archivo (set por archivo).
    path_sets: []const std.StringHashMap(void),
    scores: []f32,
    next: std.atomic.Value(usize),
    opts: Options,

    fn scoreOne(ctx: *const ScoreCtx, c: *const Chunk) f32 {
        var s: f32 = 0;
        const dl: f32 = @floatFromInt(c.tokens.len);
        const norm = K1 * (1 - B + B * dl / @max(ctx.avgdl, 1));
        for (ctx.qterms, 0..) |t, ti| {
            var tf: f32 = 0;
            for (c.tokens) |tok| {
                if (std.mem.eql(u8, tok, t)) tf += 1;
            }
            if (tf > 0) s += ctx.idf[ti] * (tf * (K1 + 1)) / (tf + norm);
            if (ctx.path_sets[c.file_idx].contains(t)) s += ctx.opts.path_boost * ctx.idf[ti];
            if (c.sym) |sn| {
                // El nombre del simbolo tambien se pliega: `buildOrLoad`
                // suma si la consulta dice `build`, `load` o `buildorload`.
                var buf: [2048]u8 = undefined;
                var fba = std.heap.FixedBufferAllocator.init(&buf);
                for (tokenize(fba.allocator(), sn, 32)) |st| {
                    if (std.mem.eql(u8, st, t)) {
                        s += ctx.opts.symbol_boost * ctx.idf[ti];
                        break;
                    }
                }
            }
        }
        return s;
    }

    fn worker(ctx: *ScoreCtx) void {
        while (true) {
            const start = ctx.next.fetchAdd(BATCH, .monotonic);
            if (start >= ctx.chunks.len) return;
            const end = @min(start + BATCH, ctx.chunks.len);
            for (ctx.chunks[start..end], start..) |*c, i| {
                ctx.scores[i] = scoreOne(ctx, c);
            }
        }
    }
};

// ── Entrada publica ──────────────────────────────────────────────────────

const GetTickCount64 = @import("platform.zig").ticks;

fn nowMs() i64 {
    return @intCast(GetTickCount64());
}

/// Corpus escaneado del worktree: archivos aceptados (post-cotas) con sus
/// trozos y sets de tokens de ruta. Lo comparten `search` (BM25) y
/// `repo_embed.indexRepo` (indexado vectorial) — mismo troceado, mismas
/// cotas, mismo hash por trozo = misma identidad de chunk en ambos lados.
pub const Corpus = struct {
    /// files[i] = ruta relativa del archivo aceptado i; coincide con
    /// chunk.file_idx (NO con la lista cruda de ls-files: los archivos
    /// saltados por cotas/binario no aparecen aquí).
    files: []const []const u8,
    chunks: []Chunk,
    /// path_sets[i] = tokens plegados de la ruta del archivo i.
    path_sets: []std.StringHashMap(void),
    files_seen: usize = 0,
    files_scanned: usize = 0,
    truncated: bool = false,
};

/// Enumera (`git ls-files`) y trocea el worktree con las cotas de `opts`.
/// `error.NotARepo` si `root` no es un repo git.
pub fn collectCorpus(
    arena: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    opts: Options,
) SearchError!Corpus {
    const started = nowMs();
    var corpus = Corpus{ .files = &.{}, .chunks = &.{}, .path_sets = &.{} };
    const raw_files = repo_map.listFiles(arena, opts.capture, root) orelse return error.NotARepo;
    corpus.files_seen = raw_files.len;

    const root_dir = std.Io.Dir.cwd().openDir(io, root, .{}) catch return error.IoFailed;
    defer root_dir.close(io);

    var chunks = std.ArrayList(Chunk).empty;
    var files_acc = std.ArrayList([]const u8).empty;
    var path_sets = std.ArrayList(std.StringHashMap(void)).empty;
    var total_bytes: usize = 0;
    const token_cap: usize = 4096;

    for (raw_files) |rel_raw| {
        if (files_acc.items.len >= opts.max_files) {
            corpus.truncated = true;
            break;
        }
        if (nowMs() - started > opts.scan_budget_ms) {
            corpus.truncated = true;
            break;
        }
        const rel = std.mem.trim(u8, rel_raw, " \t\r");
        if (rel.len == 0 or repo_map.isBinaryExt(rel)) continue;
        const content = repo_map.readTextFile(arena, io, root_dir, rel, opts.max_file_bytes) orelse continue;
        if (total_bytes + content.len > opts.max_total_bytes) {
            corpus.truncated = true;
            break;
        }
        total_bytes += content.len;
        const file_idx: u32 = @intCast(files_acc.items.len);
        var set = std.StringHashMap(void).init(arena);
        for (tokenize(arena, rel, 128)) |t| set.put(t, {}) catch {};
        files_acc.append(arena, rel) catch return error.OutOfMemory;
        path_sets.append(arena, set) catch return error.OutOfMemory;
        chunkFile(arena, &chunks, file_idx, rel, content, opts, token_cap);
        corpus.files_scanned += 1;
    }
    corpus.files = files_acc.items;
    corpus.chunks = chunks.items;
    corpus.path_sets = path_sets.items;
    return corpus;
}

/// Indexa el worktree `root` (git ls-files, mismas cotas y exclusiones de
/// repo_map) y devuelve los top-`max_results` chunks rankeados por BM25.
/// `query` vacia o sin terminos >=2 chars devuelve 0 matches — no es error.
/// `error.NotARepo` si `root` no es un repo git (honesto: sin indice no hay
/// ranking que inventar).
pub fn search(
    backing: std.mem.Allocator,
    io: std.Io,
    root: []const u8,
    query: []const u8,
    opts: Options,
) SearchError!*SearchResult {
    const started = nowMs();
    const res = try backing.create(SearchResult);
    errdefer backing.destroy(res);
    res.* = .{
        .arena_state = std.heap.ArenaAllocator.init(backing),
        .backing = backing,
        .matches = &.{},
        .files_seen = 0,
        .files_scanned = 0,
        .chunks_total = 0,
        .elapsed_ms = 0,
        .truncated = false,
        .query_mode = "bm25",
        .semantic_status = null,
        .index = null,
    };
    errdefer res.arena_state.deinit();
    const arena = res.arena_state.allocator();

    const corpus = try collectCorpus(arena, io, root, opts);
    res.files_seen = corpus.files_seen;
    res.files_scanned = corpus.files_scanned;
    res.truncated = corpus.truncated;
    const chunks = corpus.chunks;
    res.chunks_total = chunks.len;

    var df = std.StringHashMap(u32).init(arena);
    var dl_total: usize = 0;
    for (chunks) |*c| {
        dl_total += c.tokens.len;
        // df por termino: cuenta el chunk una vez por termino unico.
        var seen = std.StringHashMap(void).init(arena);
        for (c.tokens) |t| {
            if (seen.contains(t)) continue;
            seen.put(t, {}) catch break;
            const g = df.getOrPut(t) catch break;
            if (!g.found_existing) g.value_ptr.* = 0;
            g.value_ptr.* += 1;
        }
    }

    const qterms = queryTerms(arena, query);
    const n_docs: f32 = @floatFromInt(@max(chunks.len, 1));
    const idf = arena.alloc(f32, qterms.len) catch return error.OutOfMemory;
    for (qterms, 0..) |t, i| {
        const d: f32 = @floatFromInt(df.get(t) orelse 0);
        idf[i] = @log(1 + (n_docs - d + 0.5) / (d + 0.5));
    }

    var matches = std.ArrayList(Match).empty;
    if (qterms.len > 0 and chunks.len > 0) {
        var ctx = ScoreCtx{
            .chunks = chunks,
            .qterms = qterms,
            .idf = idf,
            .avgdl = @as(f32, @floatFromInt(dl_total)) / n_docs,
            .path_sets = corpus.path_sets,
            .scores = arena.alloc(f32, chunks.len) catch return error.OutOfMemory,
            .next = std.atomic.Value(usize).init(0),
            .opts = opts,
        };
        const nthreads = @max(1, @min(opts.threads, 16));
        if (nthreads <= 1 or chunks.len <= BATCH) {
            ScoreCtx.worker(&ctx);
        } else {
            var ts: [16]std.Thread = undefined;
            var spawned: usize = 0;
            while (spawned < nthreads) : (spawned += 1) {
                ts[spawned] = std.Thread.spawn(.{}, ScoreCtx.worker, .{&ctx}) catch break;
            }
            if (spawned == 0) ScoreCtx.worker(&ctx);
            for (ts[0..spawned]) |t| t.join();
        }

        // Seleccion top-N determinista: score desc, desempate por indice.
        const order = arena.alloc(u32, chunks.len) catch return error.OutOfMemory;
        for (order, 0..) |*o, i| o.* = @intCast(i);
        std.mem.sort(u32, order, ctx.scores, struct {
            fn lt(scores: []f32, a: u32, b: u32) bool {
                if (scores[a] != scores[b]) return scores[a] > scores[b];
                return a < b;
            }
        }.lt);

        // ── E5.15: capa semantica — fusion RRF de BM25 y coseno ──────
        // Dos rutas de vectores, mismo fusionador:
        //   · indice persistente (repo_embeddings via opts.vector_index):
        //     el lado vectorial cubre TODOS los trozos indexados — un match
        //     con BM25=0 sube solo por su coseno (procedencia "vector").
        //     Coste: UNA llamada al embedder (solo la consulta).
        //   · pool live (sin indice cargado o vacio): embeddings al vuelo
        //     del top-`rerank_pool` BM25 — reordena pero no descubre.
        //     Coste: 1 llamada (query + pool, peticion por lotes).
        // Sin embedder -> semantic_status con la razon honesta y resultado
        // puramente lexico.
        var fused: ?[]f32 = null;
        var in_vec: ?[]const bool = null;
        if (opts.semantic_rerank) {
            res.semantic_status = opts.semantic_note;
            if (opts.vector_index) |vi| {
                res.index = .{
                    .state = if (vi.chunks_indexed > 0) "ready" else "empty",
                    .chunks_indexed = vi.chunks_indexed,
                    .files_indexed = vi.files_indexed,
                    .model = vi.model,
                    .updated_at = vi.updated_at,
                };
            }
            if (opts.embed_fn) |ef| {
                var vec_order: ?[]u32 = null;
                const iv = arena.alloc(bool, chunks.len) catch return error.OutOfMemory;
                @memset(iv, false);
                // Coseno por trozo (0 en los que no participan del lado
                // vectorial): lo consume el modo `semantic` puro.
                const vscores = arena.alloc(f32, chunks.len) catch return error.OutOfMemory;
                @memset(vscores, 0);
                if (res.index != null and res.index.?.chunks_indexed > 0) {
                    const qin = [_][]const u8{query};
                    if (ef(opts.embed_ctx, arena, &qin)) |qvs| {
                        if (qvs.len == 1 and qvs[0].len > 0) {
                            vec_order = indexVectorOrder(arena, chunks, qvs[0], &opts.vector_index.?.map, iv, vscores);
                        } else {
                            res.semantic_status = "bad_vectors";
                        }
                    } else |e| {
                        res.semantic_status = arena.dupe(u8, @errorName(e)) catch "embed_error";
                    }
                } else {
                    const pool_n = @min(opts.rerank_pool, order.len);
                    const texts = arena.alloc([]const u8, 1 + pool_n) catch return error.OutOfMemory;
                    texts[0] = query;
                    for (order[0..pool_n], 1..) |ci, k| {
                        const t = chunks[ci].text;
                        texts[k] = t[0..@min(t.len, opts.embed_max_chars)];
                    }
                    if (ef(opts.embed_ctx, arena, texts)) |vecs| {
                        if (vecs.len == texts.len and vecs[0].len > 0) {
                            vec_order = poolVectorOrder(arena, order[0..pool_n], vecs, iv, vscores);
                        } else {
                            res.semantic_status = "bad_vectors";
                        }
                    } else |e| {
                        res.semantic_status = arena.dupe(u8, @errorName(e)) catch "embed_error";
                    }
                }
                if (vec_order) |vo| {
                    const ByScore = struct {
                        scores: []f32,
                        fn lt(self: @This(), a: u32, b: u32) bool {
                            if (self.scores[a] != self.scores[b]) return self.scores[a] > self.scores[b];
                            return a < b;
                        }
                    };
                    if (opts.semantic_only) {
                        // Ranking puramente vectorial: el coseno es el score;
                        // los trozos sin vector (0) caen al fondo y el filtro
                        // score<=0 los excluye de la salida.
                        fused = vscores;
                        std.mem.sort(u32, order, ByScore{ .scores = vscores }, ByScore.lt);
                        res.query_mode = "semantic";
                    } else {
                        const fs = try rrfFuse(arena, order, vo, chunks.len);
                        fused = fs;
                        std.mem.sort(u32, order, ByScore{ .scores = fs }, ByScore.lt);
                        res.query_mode = "hybrid";
                    }
                    in_vec = iv;
                    res.semantic_status = "ok";
                }
            } else if (res.semantic_status == null) {
                res.semantic_status = "no_embedder";
            }
        }

        var accepted = std.ArrayList(struct { f: u32, l: u32 }).empty;
        for (order) |ci| {
            if (matches.items.len >= opts.max_results) break;
            const score = if (fused) |fs| fs[ci] else ctx.scores[ci];
            if (score <= 0) break;
            const c = chunks[ci];
            var dup = false;
            for (accepted.items) |ac| {
                const near = if (ac.l > c.start_line)
                    ac.l - c.start_line < 4
                else
                    c.start_line - ac.l < 4;
                if (ac.f == c.file_idx and near) {
                    dup = true;
                    break;
                }
            }
            if (dup) continue;
            accepted.append(arena, .{ .f = c.file_idx, .l = c.start_line }) catch break;
            const snip = bestLine(arena, &c, qterms);
            const source: []const u8 = if (in_vec != null and in_vec.?[ci])
                (if (ctx.scores[ci] > 0) "bm25+vector" else "vector")
            else
                "bm25";
            matches.append(arena, .{
                .path = corpus.files[c.file_idx],
                .line = snip.line,
                .snippet = snip.text,
                .score = score,
                .source = source,
            }) catch break;
        }
    }
    res.matches = matches.toOwnedSlice(arena) catch return error.OutOfMemory;
    res.elapsed_ms = nowMs() - started;
    return res;
}

/// Ranking por coseno del pool BM25 rerankeado al vuelo. `vecs[0]` es la
/// consulta y `vecs[k]` el trozo `pool[k-1]` — orden de peticion, no de
/// `data`. Devuelve los indices de chunk del pool ordenados por coseno
/// descendente y marca `in_vec` (pertenecen al lado vectorial).
fn poolVectorOrder(
    arena: std.mem.Allocator,
    pool: []const u32,
    vecs: []const []f32,
    in_vec: []bool,
    out_cos: []f32,
) []u32 {
    const n = pool.len;
    const pos = arena.alloc(u32, n) catch return &.{};
    const cos = arena.alloc(f32, n) catch return &.{};
    for (pool, 0..) |ci, k| {
        cos[k] = embeddings.cosine(vecs[0], vecs[k + 1]);
        pos[k] = @intCast(k);
        in_vec[ci] = true;
        out_cos[ci] = cos[k];
    }
    // Ordena posiciones de pool por coseno desc; desempate por posicion
    // (determinista, mismo criterio que la seleccion BM25 por indice).
    std.mem.sort(u32, pos, cos, struct {
        fn lt(scores: []f32, a: u32, b: u32) bool {
            if (scores[a] != scores[b]) return scores[a] > scores[b];
            return a < b;
        }
    }.lt);
    const order = arena.alloc(u32, n) catch return &.{};
    for (pos, 0..) |p, i| order[i] = pool[p];
    return order;
}

/// Ranking por coseno sobre los trozos con vector persistido en el indice.
/// Marca `in_vec` para la procedencia; devuelve indices de chunk ordenados
/// por coseno descendente (desempate determinista por indice de chunk).
fn indexVectorOrder(
    arena: std.mem.Allocator,
    chunks: []const Chunk,
    qv: []const f32,
    map: *const std.StringHashMap([]f32),
    in_vec: []bool,
    out_cos: []f32,
) []u32 {
    var cands = std.ArrayList(u32).empty;
    for (chunks, 0..) |*c, i| {
        const h = chunkHashHex(c.text);
        if (map.get(h[0..])) |v| {
            in_vec[i] = true;
            out_cos[i] = embeddings.cosine(qv, v);
            cands.append(arena, @intCast(i)) catch break;
        }
    }
    const items = cands.items;
    const ByScore = struct {
        scores: []f32,
        fn lt(self: @This(), a: u32, b: u32) bool {
            if (self.scores[a] != self.scores[b]) return self.scores[a] > self.scores[b];
            return a < b;
        }
    };
    std.mem.sort(u32, items, ByScore{ .scores = out_cos }, ByScore.lt);
    return items;
}

/// Reciprocal Rank Fusion: fused(ci) = 1/(k+rank_bm25(ci)) + 1/(k+rank_vec(ci))
/// con k=60 (constante clasica). Los trozos fuera del ranking vectorial solo
/// aportan su termino BM25; un match puramente semantico (BM25=0) sube por su
/// rank vectorial igualmente — eso es lo que descubre el modo hibrido.
const RRF_K: f32 = 60;
fn rrfFuse(
    arena: std.mem.Allocator,
    bm25_order: []const u32,
    vec_order: []const u32,
    n_chunks: usize,
) ![]f32 {
    const fused = try arena.alloc(f32, n_chunks);
    @memset(fused, 0);
    for (bm25_order, 0..) |ci, rank|
        fused[ci] += 1.0 / (RRF_K + @as(f32, @floatFromInt(rank)));
    for (vec_order, 0..) |ci, rank|
        fused[ci] += 1.0 / (RRF_K + @as(f32, @floatFromInt(rank)));
    return fused;
}

const Snip = struct { line: u32, text: []const u8 };

/// Dentro del chunk ganador, la linea con mas hits de terminos de consulta
/// (tokenizacion plegada). Si ninguna suma, la primera linea no vacia.
fn bestLine(arena: std.mem.Allocator, c: *const Chunk, qterms: []const []const u8) Snip {
    var best_score: u32 = 0;
    var best_idx: u32 = 0;
    var first_nonempty: ?u32 = null;
    var it = std.mem.splitScalar(u8, c.text, '\n');
    var li: u32 = 0;
    while (it.next()) |raw| : (li += 1) {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (line.len == 0) continue;
        if (first_nonempty == null) first_nonempty = li;
        var score: u32 = 0;
        for (tokenize(arena, line, 256)) |t| {
            for (qterms) |q| {
                if (std.mem.eql(u8, t, q)) {
                    score += 1;
                    break;
                }
            }
        }
        if (score > best_score) {
            best_score = score;
            best_idx = li;
        }
    }
    const pick = if (best_score > 0) best_idx else (first_nonempty orelse 0);
    var it2 = std.mem.splitScalar(u8, c.text, '\n');
    var k: u32 = 0;
    while (it2.next()) |raw| : (k += 1) {
        if (k == pick) {
            const line = std.mem.trim(u8, raw, " \t\r");
            return .{ .line = c.start_line + pick, .text = line[0..@min(line.len, 200)] };
        }
    }
    return .{ .line = c.start_line, .text = "" };
}

/// Serializa matches a JSON: {query_mode:"bm25"|"hybrid", semantic_status?,
/// index?, truncated, elapsed_ms, files_scanned, chunks_total,
/// matches:[{path,line,snippet,score,source}]}.
/// `query_mode`/`source`/`index` son parte del contrato honesto: el
/// consumidor sabe que ranking corrio, de donde salio cada resultado y en
/// que estado esta el indice vectorial persistente.
pub fn writeJson(w: *std.Io.Writer, res: *const SearchResult) !void {
    var js: std.json.Stringify = .{ .writer = w, .options = .{} };
    try js.beginObject();
    try js.objectField("query_mode");
    try js.write(res.query_mode);
    if (res.semantic_status) |st| {
        try js.objectField("semantic_status");
        try js.write(st);
    }
    if (res.index) |ix| {
        try js.objectField("index");
        try js.beginObject();
        try js.objectField("state");
        try js.write(ix.state);
        try js.objectField("chunks_indexed");
        try js.write(ix.chunks_indexed);
        try js.objectField("files_indexed");
        try js.write(ix.files_indexed);
        try js.objectField("model");
        try js.write(ix.model);
        try js.objectField("updated_at");
        try js.write(ix.updated_at);
        try js.endObject();
    }
    try js.objectField("truncated");
    try js.write(res.truncated);
    try js.objectField("elapsed_ms");
    try js.write(res.elapsed_ms);
    try js.objectField("files_seen");
    try js.write(res.files_seen);
    try js.objectField("files_scanned");
    try js.write(res.files_scanned);
    try js.objectField("chunks_total");
    try js.write(res.chunks_total);
    try js.objectField("matches");
    try js.beginArray();
    for (res.matches) |m| {
        try js.beginObject();
        try js.objectField("path");
        try js.write(m.path);
        try js.objectField("line");
        try js.write(m.line);
        try js.objectField("snippet");
        try js.write(m.snippet);
        try js.objectField("score");
        try js.write(m.score);
        try js.objectField("source");
        try js.write(m.source);
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
}

pub fn toJson(allocator: std.mem.Allocator, res: *const SearchResult) ![]u8 {
    var out = std.Io.Writer.Allocating.init(allocator);
    defer out.deinit();
    try writeJson(&out.writer, res);
    return allocator.dupe(u8, out.written());
}

// ── Tests ────────────────────────────────────────────────────────────────

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

test "E5.14 tokenizacion: pliegue camelCase, snake_case y digitos" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    const a = arena_state.allocator();
    const toks = tokenize(a, "buildOrLoad HTTPServer max_retry 42x", 64);
    var set = std.StringHashMap(void).init(a);
    for (toks) |t| try set.put(t, {});
    for ([_][]const u8{ "buildorload", "build", "load", "httpserver", "http", "server", "max", "retry" }) |want| {
        try std.testing.expect(set.contains(want));
    }
}

test "E5.14 ranking BM25: el archivo con el termino gana al incidental" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    try writeFile(&tmp, "engine.zig", "pub fn runEngine() void {\n    // engine loop principal\n    tickPhysics();\n    tickPhysics();\n}\n");
    try writeFile(&tmp, "readme.md", "# doc\nmenciona tickPhysics una vez de pasada\n");
    try writeFile(&tmp, "otro.zig", "pub fn nada() void {}\n");
    scripted_ls = "engine.zig\nreadme.md\notro.zig\n";
    scripted_rev = "abc\n";
    var buf: [4096]u8 = undefined;
    const res = try search(a, std.testing.io, tmpRootPath(&tmp, &buf), "tickPhysics", testOpts());
    defer res.deinit();
    try std.testing.expect(res.matches.len >= 1);
    try std.testing.expectEqualStrings("engine.zig", res.matches[0].path);
    try std.testing.expect(res.matches[0].score > 0);
    try std.testing.expect(!res.truncated);
}

test "E5.14 boost de ruta: el termino en el path sube el archivo" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    try writeFile(&tmp, "src/billing.zig", "pub fn charge() void {\n    pay();\n    // billing interno\n}\n");
    try writeFile(&tmp, "src/util.zig", "pub fn pay() void {}\n// billing helper\n");
    scripted_ls = "src/billing.zig\nsrc/util.zig\n";
    scripted_rev = "abc\n";
    var buf: [4096]u8 = undefined;
    const res = try search(a, std.testing.io, tmpRootPath(&tmp, &buf), "billing", testOpts());
    defer res.deinit();
    try std.testing.expect(res.matches.len >= 1);
    try std.testing.expectEqualStrings("src/billing.zig", res.matches[0].path);
}

test "E5.14 boost de simbolo: la consulta por nombre de funcion cae en su span" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    try writeFile(&tmp, "a.zig", "pub fn renderHud() void {\n    draw();\n}\n");
    try writeFile(&tmp, "b.zig", "// renderHud renderHud renderHud\npub fn other() void {}\n");
    scripted_ls = "a.zig\nb.zig\n";
    scripted_rev = "abc\n";
    var buf: [4096]u8 = undefined;
    const res = try search(a, std.testing.io, tmpRootPath(&tmp, &buf), "renderHud", testOpts());
    defer res.deinit();
    try std.testing.expect(res.matches.len >= 1);
    try std.testing.expectEqualStrings("a.zig", res.matches[0].path);
    try std.testing.expectEqual(@as(u32, 1), res.matches[0].line);
}

test "E5.14 cotas y formato: max_results, snippet con linea, consulta vacia" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    var ls = std.ArrayList(u8).empty;
    defer ls.deinit(a);
    var i: usize = 0;
    while (i < 30) : (i += 1) {
        var nb: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&nb, "f{d}.zig", .{i}) catch unreachable;
        try writeFile(&tmp, name, "pub fn hit() void {\n    needle();\n}\n");
        var lb: [16]u8 = undefined;
        try ls.appendSlice(a, std.fmt.bufPrint(&lb, "f{d}.zig\n", .{i}) catch unreachable);
    }
    scripted_ls = ls.items;
    scripted_rev = "abc\n";
    var buf: [4096]u8 = undefined;
    var opts = testOpts();
    opts.max_results = 5;
    const res = try search(a, std.testing.io, tmpRootPath(&tmp, &buf), "needle", opts);
    defer res.deinit();
    try std.testing.expectEqual(@as(usize, 5), res.matches.len);
    for (res.matches) |m| {
        try std.testing.expect(m.line >= 1);
        try std.testing.expect(m.snippet.len > 0 and m.snippet.len <= 200);
    }
    const res2 = try search(a, std.testing.io, tmpRootPath(&tmp, &buf), "", testOpts());
    defer res2.deinit();
    try std.testing.expectEqual(@as(usize, 0), res2.matches.len);
}

test "E5.14 paralelismo determinista: mismo ranking con 1 y 8 hilos" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    var ls = std.ArrayList(u8).empty;
    defer ls.deinit(a);
    var i: usize = 0;
    while (i < 12) : (i += 1) {
        var nb: [64]u8 = undefined;
        const name = std.fmt.bufPrint(&nb, "m{d}.zig", .{i}) catch unreachable;
        var cb = std.ArrayList(u8).empty;
        defer cb.deinit(a);
        var hb: [64]u8 = undefined;
        try cb.appendSlice(a, std.fmt.bufPrint(&hb, "pub fn f{d}() void {{\n", .{i}) catch unreachable);
        var k: usize = 0;
        while (k < 40) : (k += 1) {
            var fb2: [80]u8 = undefined;
            try cb.appendSlice(a, std.fmt.bufPrint(&fb2, "    // filler line {d} modulo {d}\n", .{ k, i }) catch unreachable);
            if (i == 3 and k == 10) try cb.appendSlice(a, "    needleCall();\n");
        }
        try cb.appendSlice(a, "}\n");
        try writeFile(&tmp, name, cb.items);
        var lb2: [16]u8 = undefined;
        try ls.appendSlice(a, std.fmt.bufPrint(&lb2, "m{d}.zig\n", .{i}) catch unreachable);
    }
    scripted_ls = ls.items;
    scripted_rev = "abc\n";
    var buf: [4096]u8 = undefined;
    var o1 = testOpts();
    o1.threads = 1;
    o1.max_results = 8;
    const r1 = try search(a, std.testing.io, tmpRootPath(&tmp, &buf), "needleCall filler", o1);
    defer r1.deinit();
    var o8 = testOpts();
    o8.threads = 8;
    o8.max_results = 8;
    const r8 = try search(a, std.testing.io, tmpRootPath(&tmp, &buf), "needleCall filler", o8);
    defer r8.deinit();
    try std.testing.expectEqual(r1.matches.len, r8.matches.len);
    for (r1.matches, r8.matches) |m1, m8| {
        try std.testing.expectEqualStrings(m1.path, m8.path);
        try std.testing.expectEqual(m1.line, m8.line);
        try std.testing.expectApproxEqAbs(m1.score, m8.score, 0.0001);
    }
    try std.testing.expectEqualStrings("m3.zig", r1.matches[0].path);
}

test "E5.14 no-repo devuelve NotARepo (honesto, sin indice inventado)" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const fail_cap = struct {
        fn f(allocator: std.mem.Allocator, _: []const []const u8, _: ?[]const u8) anyerror!gh.CmdCapture {
            return .{ .exit_code = 128, .stdout = try allocator.dupe(u8, ""), .stderr = try allocator.dupe(u8, "not a git repo") };
        }
    }.f;
    var opts = testOpts();
    opts.capture = fail_cap;
    var buf: [4096]u8 = undefined;
    try std.testing.expectError(error.NotARepo, search(std.testing.allocator, std.testing.io, tmpRootPath(&tmp, &buf), "x", opts));
}

test "E5.14 JSON: query_mode bm25 y campos de contrato" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    try writeFile(&tmp, "x.zig", "pub fn alpha() void {\n    needle();\n}\n");
    scripted_ls = "x.zig\n";
    scripted_rev = "abc\n";
    var buf: [4096]u8 = undefined;
    const res = try search(a, std.testing.io, tmpRootPath(&tmp, &buf), "needle", testOpts());
    defer res.deinit();
    const j = try toJson(a, res);
    defer a.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"query_mode\":\"bm25\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"path\":\"x.zig\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"line\":2") != null);
}

// ── Tests E5.15: rerank semantico con seam, fallback honesto ─────────────

/// Embedder sintetico: la consulta (texts[0]) y los chunks con
/// "semanticTarget" reciben (1,0); el resto (0,1). Con weight=1 el rerank
/// gana quien tenga el token objetivo aunque su BM25 sea menor.
fn fakeEmbed(_: ?*anyopaque, allocator: std.mem.Allocator, texts: []const []const u8) anyerror![][]f32 {
    const vecs = try allocator.alloc([]f32, texts.len);
    for (texts, 0..) |t, i| {
        const v = try allocator.alloc(f32, 2);
        const hit = i == 0 or std.mem.indexOf(u8, t, "semanticTarget") != null;
        v[0] = if (hit) 1 else 0;
        v[1] = if (hit) 0 else 1;
        vecs[i] = v;
    }
    return vecs;
}

fn failEmbed(_: ?*anyopaque, _: std.mem.Allocator, _: []const []const u8) anyerror![][]f32 {
    return error.HttpFailed;
}

test "E5.15 hibrido con indice: RRF sube un match puramente vectorial" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    // a.zig gana el BM25 (needle x4). b.zig NO contiene 'needle': su unica
    // via a la cabeza es el vector — con RRF un match con BM25=0 sube solo
    // por su rank de coseno (procedencia "vector").
    const a_content = "pub fn fa() void {\n    needle(); needle(); needle(); needle();\n}\n";
    const b_content = "pub fn fb() void {\n    semanticTarget();\n}\n";
    try writeFile(&tmp, "a.zig", a_content);
    try writeFile(&tmp, "b.zig", b_content);
    scripted_ls = "a.zig\nb.zig\n";
    scripted_rev = "abc\n";
    var buf: [4096]u8 = undefined;
    const root = tmpRootPath(&tmp, &buf);

    var bm = testOpts();
    bm.max_results = 4;
    const r_bm = try search(a, std.testing.io, root, "needle", bm);
    defer r_bm.deinit();
    try std.testing.expectEqualStrings("a.zig", r_bm.matches[0].path);
    try std.testing.expectEqualStrings("bm25", r_bm.query_mode);
    try std.testing.expectEqualStrings("bm25", r_bm.matches[0].source);

    // Indice persistente: solo el chunk de b.zig tiene vector (hash de su
    // texto; a.zig no esta indexado). fakeEmbed devuelve (1,0) para la
    // consulta → coseno 1 con b.
    var map = std.StringHashMap([]f32).init(a);
    defer {
        var it = map.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        map.deinit();
    }
    const bvec = try a.alloc(f32, 2);
    bvec[0] = 1;
    bvec[1] = 0;
    const bh = chunkHashHex(b_content);
    try map.put(try a.dupe(u8, bh[0..]), bvec);
    var vi = VectorIndex{
        .map = map,
        .chunks_indexed = 1,
        .files_indexed = 1,
        .model = "test-embed",
        .updated_at = 100,
    };

    var hy = testOpts();
    hy.max_results = 4;
    hy.semantic_rerank = true;
    hy.embed_fn = fakeEmbed;
    hy.vector_index = &vi;
    const r_hy = try search(a, std.testing.io, root, "needle", hy);
    defer r_hy.deinit();
    try std.testing.expectEqualStrings("hybrid", r_hy.query_mode);
    try std.testing.expectEqualStrings("ok", r_hy.semantic_status.?);
    // b.zig lidera por vector puro: BM25 le dio 0, el coseno lo trajo.
    try std.testing.expectEqualStrings("b.zig", r_hy.matches[0].path);
    try std.testing.expectEqualStrings("vector", r_hy.matches[0].source);
    // a.zig queda detras pero procede del lado BM25 solamente.
    try std.testing.expectEqualStrings("a.zig", r_hy.matches[1].path);
    try std.testing.expectEqualStrings("bm25", r_hy.matches[1].source);
    // El estado del indice viaja en el resultado para la cabina/MCP.
    try std.testing.expect(r_hy.index != null);
    try std.testing.expectEqualStrings("ready", r_hy.index.?.state);
    try std.testing.expectEqual(@as(usize, 1), r_hy.index.?.chunks_indexed);
    const j = try toJson(a, r_hy);
    defer a.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"source\":\"vector\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"state\":\"ready\"") != null);
}

test "E5.15 pool live: rerank del top-BM25 sin indice sigue funcionando" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    // Tres archivos con needle; b.zig es el match semantico. Con el pool
    // completo cubierto por vectores, RRF ordena por ambos rankings —
    // verificamos que el modo sigue siendo hybrid con status ok y que el
    // match semantico conserva procedencia bm25+vector (presente en ambos).
    try writeFile(&tmp, "a.zig", "pub fn fa() void {\n    needle(); needle(); needle(); needle();\n}\n");
    try writeFile(&tmp, "b.zig", "pub fn fb() void {\n    needle(); // semanticTarget aqui\n}\n");
    scripted_ls = "a.zig\nb.zig\n";
    scripted_rev = "abc\n";
    var buf: [4096]u8 = undefined;
    var hy = testOpts();
    hy.max_results = 4;
    hy.semantic_rerank = true;
    hy.embed_fn = fakeEmbed;
    const r_hy = try search(a, std.testing.io, tmpRootPath(&tmp, &buf), "needle", hy);
    defer r_hy.deinit();
    try std.testing.expectEqualStrings("hybrid", r_hy.query_mode);
    try std.testing.expectEqualStrings("ok", r_hy.semantic_status.?);
    try std.testing.expect(r_hy.index == null);
    // Ambos archivos aparecen y con procedencia doble (BM25>0 + en el pool
    // vectorial): el pool live reordena pero no descubre matches nuevos.
    var saw_a = false;
    var saw_b = false;
    for (r_hy.matches) |m| {
        if (std.mem.eql(u8, m.path, "a.zig")) saw_a = true;
        if (std.mem.eql(u8, m.path, "b.zig")) saw_b = true;
        try std.testing.expectEqualStrings("bm25+vector", m.source);
    }
    try std.testing.expect(saw_a and saw_b);
}

test "E5.15 fallback honesto: sin embedder reporta no_embedder y orden BM25" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    try writeFile(&tmp, "x.zig", "pub fn fx() void {\n    needle();\n}\n");
    scripted_ls = "x.zig\n";
    scripted_rev = "abc\n";
    var buf: [4096]u8 = undefined;
    var opts = testOpts();
    opts.semantic_rerank = true;
    const res = try search(a, std.testing.io, tmpRootPath(&tmp, &buf), "needle", opts);
    defer res.deinit();
    try std.testing.expectEqualStrings("bm25", res.query_mode);
    try std.testing.expectEqualStrings("no_embedder", res.semantic_status.?);
    try std.testing.expect(res.matches.len >= 1);
}

test "E5.15 fallback honesto: embedder roto degrada a BM25 con la razon" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    try writeFile(&tmp, "x.zig", "pub fn fx() void {\n    needle();\n}\n");
    scripted_ls = "x.zig\n";
    scripted_rev = "abc\n";
    var buf: [4096]u8 = undefined;
    var opts = testOpts();
    opts.semantic_rerank = true;
    opts.embed_fn = failEmbed;
    const res = try search(a, std.testing.io, tmpRootPath(&tmp, &buf), "needle", opts);
    defer res.deinit();
    try std.testing.expectEqualStrings("bm25", res.query_mode);
    try std.testing.expectEqualStrings("HttpFailed", res.semantic_status.?);
    try std.testing.expect(res.matches.len >= 1);
    const j = try toJson(a, res);
    defer a.free(j);
    try std.testing.expect(std.mem.indexOf(u8, j, "\"semantic_status\":\"HttpFailed\"") != null);
}

test "E5.15 modo semantic: ranking puramente vectorial, el coseno es el score" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const a = std.testing.allocator;
    // a.zig domina el BM25 (needle x4) pero NO esta indexado → en semantic
    // no puede salir: sin vector no hay candidato, por bueno que sea lexical.
    const a_content = "pub fn fa() void {\n    needle(); needle(); needle(); needle();\n}\n";
    const b_content = "pub fn fb() void {\n    semanticTarget();\n}\n";
    try writeFile(&tmp, "a.zig", a_content);
    try writeFile(&tmp, "b.zig", b_content);
    scripted_ls = "a.zig\nb.zig\n";
    scripted_rev = "abc\n";
    var buf: [4096]u8 = undefined;
    const root = tmpRootPath(&tmp, &buf);

    var map = std.StringHashMap([]f32).init(a);
    defer {
        var it = map.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        map.deinit();
    }
    const bvec = try a.alloc(f32, 2);
    bvec[0] = 1;
    bvec[1] = 0;
    const bh = chunkHashHex(b_content);
    try map.put(try a.dupe(u8, bh[0..]), bvec);
    var vi = VectorIndex{
        .map = map,
        .chunks_indexed = 1,
        .files_indexed = 1,
        .model = "test-embed",
        .updated_at = 100,
    };

    var so = testOpts();
    so.max_results = 4;
    so.semantic_rerank = true;
    so.semantic_only = true;
    so.embed_fn = fakeEmbed;
    so.vector_index = &vi;
    const r = try search(a, std.testing.io, root, "needle", so);
    defer r.deinit();
    try std.testing.expectEqualStrings("semantic", r.query_mode);
    try std.testing.expectEqualStrings("ok", r.semantic_status.?);
    // Solo b.zig: coseno 1 con la consulta; a.zig no tiene vector → excluido.
    try std.testing.expectEqual(@as(usize, 1), r.matches.len);
    try std.testing.expectEqualStrings("b.zig", r.matches[0].path);
    try std.testing.expectEqualStrings("vector", r.matches[0].source);
    try std.testing.expectApproxEqAbs(@as(f32, 1.0), r.matches[0].score, 0.0001);
}
