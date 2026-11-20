//! E5.15 (A-a) — índice vectorial persistente del repositorio.
//!
//! Qué guarda: un vector float32 (BLOB little-endian) por trozo de código en
//! `repo_embeddings` (V32), claveado por (repo_root, path, chunk_hash, model).
//! El `chunk_hash` es el sha256 hex del TEXTO del trozo — mismo texto, mismo
//! vector, sea cual sea la ruta. El troceado es el de `repo_search.collectCorpus`
//! (span de símbolo + ventana solapada): indexador y consulta híbrida generan
//! los mismos chunks, así el hash almacenado y el calculado en consulta
//! coinciden byte a byte.
//!
//! Incremental: solo se re-embeben los trozos cuyo (path, hash) no existe ya
//! para el modelo; los trozos sin cambios reutilizan su vector (coste cero);
//! y las filas que ya no corresponden a ningún trozo vivo se borran — el
//! índice no engorda con historia.
//!
//! Lotes: los embeddings viajan en peticiones por lotes (`batch_size`), con
//! deduplicación por hash dentro y entre lotes — dos rutas con el mismo trozo
//! comparten una sola llamada de red. El presupuesto (spend_budget) y el
//! reintento ante 429 (retry_planner) viven en la `embed_fn` inyectada por el
//! llamador (c_api), no aquí: este módulo solo ve la costura.
//!
//! Degradación honesta: si el embedder falla a mitad del índice, lo ya
//! persistido se queda y `IndexStats.error_note` declara el fallo — el índice
//! parcial es útil y la consulta híbrida lo usa sin fingir cobertura total.

const std = @import("std");
const db = @import("db.zig");
const health = @import("health.zig");
const repo_search = @import("repo_search.zig");

pub const EmbedError = repo_search.SearchError || error{DbFailed};

pub const IndexOpts = struct {
    /// Textos por petición HTTP. Cohere admite 96; 64 queda holgado para todos.
    batch_size: usize = 64,
    /// Truncado por texto — igual que en la consulta.
    embed_max_chars: usize = 1200,
    /// Cotas del escaneo compartidas con repo_search.
    scan: repo_search.Options = .{},
    /// epoch seconds; null = reloj real (tests lo fijan).
    now_ts: ?i64 = null,
};

pub const IndexStats = struct {
    model: []const u8 = "",
    files_seen: usize = 0,
    files_scanned: usize = 0,
    chunks_total: usize = 0,
    /// Trozos embebidos en ESTA pasada (filas nuevas o re-embebidas).
    embedded: usize = 0,
    /// Trozos que ya tenían vector almacenado (hash intacto — coste 0).
    reused: usize = 0,
    /// Filas obsoletas borradas (trozos que ya no existen en el corpus vivo).
    removed: usize = 0,
    /// Trozos descartados como no-embebibles (todo espacios/UTF-8 roto sin
    /// señal tras sanear): no se envían ni se fingen indexados — el próximo
    /// escaneo los vuelve a descartar sin tocar la red.
    skipped: usize = 0,
    /// Lotes HTTP enviados al embedder.
    batches: usize = 0,
    dim: usize = 0,
    elapsed_ms: i64 = 0,
    truncated: bool = false,
    /// Si el embedder falló a mitad: nombre del error; el índice queda parcial
    /// y la consulta lo declara vía cobertura, nunca como "completo".
    error_note: ?[]const u8 = null,
};

const PendingChunk = struct {
    path: []const u8,
    /// sha256 hex del texto ORIGINAL del trozo — la consulta hashea el texto
    /// crudo igual, asi que la clave no depende del saneo del wire.
    hash: []const u8,
    /// Texto crudo del trozo (el saneo UTF-8 ocurre en el wire dentro de
    /// embedTexts); null cuando el trozo no tiene señal embebible y se
    /// descarta con honestidad (skipped).
    text: ?[]const u8,
};

/// ¿El trozo tiene señal embebible? Vacio, todo-espacios o todo-bytes-rotos
/// → no: no aporta semantica y en el endpoint real un input asi puede tirar
/// el LOTE entero (400 observado contra Cohere). Se cuenta en `skipped`.
fn isEmbeddableText(text: []const u8) bool {
    var i: usize = 0;
    var signal = false;
    while (i < text.len) {
        const n = std.unicode.utf8ByteSequenceLength(text[i]) catch {
            i += 1;
            continue;
        };
        if (i + n <= text.len and std.unicode.utf8ValidateSlice(text[i..][0..n])) {
            const b = text[i];
            if (!(b == ' ' or b == '\t' or b == '\r' or b == '\n')) signal = true;
            i += n;
        } else i += 1;
    }
    return signal;
}

// Relojes: el fork no expone std.time.* — época vía SQLite
// (health.nowSeconds) y cronómetro monotónico via kernel32, mismo patrón
// que repo_map/repo_search.
const GetTickCount64 = @import("platform.zig").ticks;

fn nowMs() i64 {
    return @intCast(GetTickCount64());
}

/// Construye/actualiza el índice vectorial del repo en `conn`
/// (runtime.db — tabla V32). Devuelve las cuentas reales de la pasada.
pub fn indexRepo(
    allocator: std.mem.Allocator,
    io: std.Io,
    conn: db.Connection,
    root: []const u8,
    model: []const u8,
    embed_fn: repo_search.EmbedFn,
    embed_ctx: ?*anyopaque,
    opts: IndexOpts,
) EmbedError!IndexStats {
    const started = nowMs();
    var stats = IndexStats{ .model = model };

    var arena_state = std.heap.ArenaAllocator.init(allocator);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const corpus = try repo_search.collectCorpus(arena, io, root, opts.scan);
    stats.files_seen = corpus.files_seen;
    stats.files_scanned = corpus.files_scanned;
    stats.chunks_total = corpus.chunks.len;
    stats.truncated = corpus.truncated;

    // Set de claves vivas (path\0hash) del corpus actual — sirve para saber
    // qué falta y para el GC de filas obsoletas.
    var current = std.StringHashMap(void).init(arena);
    var pending = std.ArrayList(PendingChunk).empty;
    for (corpus.chunks) |*c| {
        const path = corpus.files[c.file_idx];
        const h = repo_search.chunkHashHex(c.text);
        const htxt = try arena.dupe(u8, h[0..]);
        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ path, htxt });
        try current.put(key, {});
        const embeddable = isEmbeddableText(c.text[0..@min(c.text.len, opts.embed_max_chars)]);
        if (!embeddable) stats.skipped += 1;
        try pending.append(arena, .{ .path = path, .hash = htxt, .text = if (embeddable) c.text else null });
    }

    // Filas existentes para (repo, model): lo ya indexado se reutiliza; lo que
    // no está en `current` al final es historia y se borra.
    const Stale = struct { path: []const u8, hash: []const u8 };
    var existing = std.StringHashMap(void).init(arena);
    var stale_candidates = std.ArrayList(Stale).empty;
    {
        const sel = conn.prepare(
            "SELECT path, chunk_hash FROM repo_embeddings WHERE repo_root=? AND model=?",
        ) catch return error.DbFailed;
        defer conn.finalize(sel);
        db.bindText(sel, 1, root) catch return error.DbFailed;
        db.bindText(sel, 2, model) catch return error.DbFailed;
        while (db.c.sqlite3_step(sel) == db.c.SQLITE_ROW) {
            const pptr = db.c.sqlite3_column_text(sel, 0);
            const hptr = db.c.sqlite3_column_text(sel, 1);
            if (pptr == null or hptr == null) continue;
            const p = try arena.dupe(u8, pptr[0..std.mem.len(pptr)]);
            const h = try arena.dupe(u8, hptr[0..std.mem.len(hptr)]);
            const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ p, h });
            try existing.put(key, {});
            try stale_candidates.append(arena, .{ .path = p, .hash = h });
        }
        // En una pasada puramente incremental (todo reutilizado) nunca se
        // llama al embedder — el dim informado es el del índice existente,
        // no 0.
        if (stats.dim == 0) {
            const ds = conn.prepare(
                "SELECT dim FROM repo_embeddings WHERE repo_root=? AND model=? LIMIT 1",
            ) catch return error.DbFailed;
            defer conn.finalize(ds);
            db.bindText(ds, 1, root) catch return error.DbFailed;
            db.bindText(ds, 2, model) catch return error.DbFailed;
            if (db.c.sqlite3_step(ds) == db.c.SQLITE_ROW)
                stats.dim = @intCast(@max(0, db.c.sqlite3_column_int64(ds, 0)));
        }
    }

    // pending := trozos vivos sin fila almacenada.
    var to_embed = std.ArrayList(PendingChunk).empty;
    for (pending.items) |p| {
        if (p.text == null) continue; // no-embebible: descartado ya
        const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ p.path, p.hash });
        if (existing.contains(key)) {
            stats.reused += 1;
        } else {
            try to_embed.append(arena, p);
        }
    }

    // Embeddemos por lotes con deduplicación por hash: el mismo trozo bajo
    // dos rutas consume una sola posición de lote (y de cuota).
    const ts = opts.now_ts orelse health.nowSeconds(conn);
    var vecs_by_hash = std.StringHashMap([]f32).init(arena);
    var i: usize = 0;
    while (i < to_embed.items.len) {
        const batch = to_embed.items[i..@min(i + opts.batch_size, to_embed.items.len)];
        i += batch.len;
        var uniq_texts = std.ArrayList([]const u8).empty;
        var uniq_hashes = std.ArrayList([]const u8).empty;
        var seen = std.StringHashMap(void).init(arena);
        for (batch) |p| {
            if (seen.contains(p.hash)) continue;
            try seen.put(p.hash, {});
            try uniq_texts.append(arena, p.text.?);
            try uniq_hashes.append(arena, p.hash);
        }
        const vecs = embed_fn(embed_ctx, arena, uniq_texts.items) catch |e| {
            // @errorName es cadena estatica de compilacion: sobrevive al
            // arena — nada que dupe aqui (un dupe moriria con el arena y el
            // llamador leeria memoria colgada).
            stats.error_note = @errorName(e);
            break;
        };
        if (vecs.len != uniq_texts.items.len or (vecs.len > 0 and vecs[0].len == 0)) {
            stats.error_note = "bad_vectors";
            break;
        }
        stats.batches += 1;
        stats.dim = vecs[0].len;
        for (uniq_hashes.items, 0..) |h, k| try vecs_by_hash.put(h, vecs[k]);

        const ins = conn.prepare(
            "INSERT OR REPLACE INTO repo_embeddings (repo_root, path, chunk_hash, model, dim, vec, embedded_at) VALUES (?,?,?,?,?,?,?)",
        ) catch return error.DbFailed;
        defer conn.finalize(ins);
        for (batch) |p| {
            const v = vecs_by_hash.get(p.hash) orelse continue;
            const bytes = std.mem.sliceAsBytes(v);
            var col: c_int = 1;
            db.bindText(ins, col, root) catch return error.DbFailed;
            col += 1;
            db.bindText(ins, col, p.path) catch return error.DbFailed;
            col += 1;
            db.bindText(ins, col, p.hash) catch return error.DbFailed;
            col += 1;
            db.bindText(ins, col, model) catch return error.DbFailed;
            col += 1;
            db.bindInt(ins, col, @intCast(v.len)) catch return error.DbFailed;
            col += 1;
            db.bindBlob(ins, col, bytes) catch return error.DbFailed;
            col += 1;
            db.bindInt(ins, col, ts) catch return error.DbFailed;
            if (db.c.sqlite3_step(ins) != db.c.SQLITE_DONE) return error.DbFailed;
            _ = db.c.sqlite3_reset(ins);
            stats.embedded += 1;
        }
    }

    // GC: filas de (repo, model) cuyo (path,hash) ya no existe en el corpus.
    {
        const del = conn.prepare(
            "DELETE FROM repo_embeddings WHERE repo_root=? AND model=? AND path=? AND chunk_hash=?",
        ) catch return error.DbFailed;
        defer conn.finalize(del);
        for (stale_candidates.items) |s| {
            const key = try std.fmt.allocPrint(arena, "{s}\x00{s}", .{ s.path, s.hash });
            if (current.contains(key)) continue;
            var col: c_int = 1;
            db.bindText(del, col, root) catch return error.DbFailed;
            col += 1;
            db.bindText(del, col, model) catch return error.DbFailed;
            col += 1;
            db.bindText(del, col, s.path) catch return error.DbFailed;
            col += 1;
            db.bindText(del, col, s.hash) catch return error.DbFailed;
            if (db.c.sqlite3_step(del) != db.c.SQLITE_DONE) return error.DbFailed;
            _ = db.c.sqlite3_reset(del);
            stats.removed += 1;
        }
    }

    stats.elapsed_ms = nowMs() - started;
    return stats;
}

/// Carga el índice vectorial de (repo, model) en memoria para la consulta
/// híbrida: mapa hash-hex-del-trozo → vector. El deserializado respeta la
/// dimensión almacenada; una fila con bytes no múltiplo de 4 se ignora
/// (corrupción no puede fabricar ranking).
pub fn loadIndex(
    allocator: std.mem.Allocator,
    conn: db.Connection,
    root: []const u8,
    model: []const u8,
) !repo_search.VectorIndex {
    var vi = repo_search.VectorIndex{ .map = std.StringHashMap([]f32).init(allocator) };
    const sel = conn.prepare(
        "SELECT chunk_hash, dim, vec, embedded_at FROM repo_embeddings WHERE repo_root=? AND model=?",
    ) catch return vi;
    defer conn.finalize(sel);
    db.bindText(sel, 1, root) catch return vi;
    db.bindText(sel, 2, model) catch return vi;
    while (db.c.sqlite3_step(sel) == db.c.SQLITE_ROW) {
        const hptr = db.c.sqlite3_column_text(sel, 0);
        const dim: usize = @intCast(@max(0, db.c.sqlite3_column_int64(sel, 1)));
        const blob_ptr = db.c.sqlite3_column_blob(sel, 2);
        const blob_len: usize = @intCast(@max(0, db.c.sqlite3_column_bytes(sel, 2)));
        const at: i64 = db.c.sqlite3_column_int64(sel, 3);
        if (hptr == null or blob_ptr == null) continue;
        // Cota anti-corrupcion: una dim de i64 casi-maximo desbordaria el
        // dim*4 antes de comparar con blob_len. Dims reales <= 4096.
        if (dim == 0 or dim > 1 << 16 or blob_len != dim * @sizeOf(f32)) continue;
        const htxt = try allocator.dupe(u8, hptr[0..std.mem.len(hptr)]);
        if (vi.map.contains(htxt)) {
            allocator.free(htxt);
            continue;
        }
        const v = try allocator.alloc(f32, dim);
        const src: [*]const u8 = @ptrCast(blob_ptr);
        @memcpy(std.mem.sliceAsBytes(v), src[0..blob_len]);
        try vi.map.put(htxt, v);
        vi.chunks_indexed += 1;
        vi.updated_at = @max(vi.updated_at, at);
    }
    // files_indexed por SQL — sin mapa en memoria que fugar.
    const pc = conn.prepare(
        "SELECT COUNT(DISTINCT path) FROM repo_embeddings WHERE repo_root=? AND model=?",
    ) catch return vi;
    defer conn.finalize(pc);
    db.bindText(pc, 1, root) catch return vi;
    db.bindText(pc, 2, model) catch return vi;
    if (db.c.sqlite3_step(pc) == db.c.SQLITE_ROW)
        vi.files_indexed = @intCast(@max(0, db.c.sqlite3_column_int64(pc, 0)));
    vi.model = model;
    return vi;
}

/// Evento durable `repo_embed_indexed` con las cuentas reales de la pasada —
/// la aceptación pide que el indexado quede como hecho trazable, no como
/// print. Mismo patrón que repo_map.emitBuiltEvent (order_id = última orden
/// cuando la llamada no viene de una).
pub fn emitIndexedEvent(conn: db.Connection, order_id: i64, repo: []const u8, stats: *const IndexStats) void {
    var out: std.Io.Writer.Allocating = .init(std.heap.c_allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    js.beginObject() catch return;
    js.objectField("repo") catch return;
    js.write(repo) catch return;
    js.objectField("model") catch return;
    js.write(stats.model) catch return;
    js.objectField("files_scanned") catch return;
    js.write(stats.files_scanned) catch return;
    js.objectField("chunks_total") catch return;
    js.write(stats.chunks_total) catch return;
    js.objectField("embedded") catch return;
    js.write(stats.embedded) catch return;
    js.objectField("reused") catch return;
    js.write(stats.reused) catch return;
    js.objectField("removed") catch return;
    js.write(stats.removed) catch return;
    js.objectField("skipped") catch return;
    js.write(stats.skipped) catch return;
    js.objectField("batches") catch return;
    js.write(stats.batches) catch return;
    js.objectField("dim") catch return;
    js.write(stats.dim) catch return;
    js.objectField("ms") catch return;
    js.write(stats.elapsed_ms) catch return;
    if (stats.error_note) |n| {
        js.objectField("error") catch return;
        js.write(n) catch return;
    }
    js.endObject() catch return;

    const oid: i64 = if (order_id > 0) order_id else blk: {
        const seq = conn.prepare("SELECT MAX(id) FROM orders") catch break :blk 0;
        defer conn.finalize(seq);
        if (db.c.sqlite3_step(seq) == db.c.SQLITE_ROW)
            break :blk @as(i64, @intCast(db.c.sqlite3_column_int64(seq, 0)));
        break :blk 0;
    };
    const stmt = conn.prepare("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (?, 'superagente', 'repo_embed_indexed', ?, ?)") catch return;
    defer conn.finalize(stmt);
    db.bindInt(stmt, 1, health.nowMillis(conn)) catch return;
    db.bindText(stmt, 2, out.written()) catch return;
    db.bindInt(stmt, 3, oid) catch return;
    _ = db.c.sqlite3_step(stmt);
}

/// Estado del índice para (repo, model): lo que la cabina muestra.
/// model vacío = cualquier modelo (último por embedded_at). El nombre del
/// modelo devuelto está DUPEADO en `allocator` — el texto del statement no
/// sobrevive al finalize (una slice directa llegaba corrupta al JSON).
pub fn indexStatus(
    allocator: std.mem.Allocator,
    conn: db.Connection,
    root: []const u8,
    model: []const u8,
) repo_search.IndexInfo {
    var info = repo_search.IndexInfo{
        .state = "empty",
        .chunks_indexed = 0,
        .files_indexed = 0,
        .model = model,
        .updated_at = 0,
    };
    const with_model = model.len > 0;
    const sql: []const u8 = if (with_model)
        "SELECT COUNT(*), COUNT(DISTINCT path), MAX(embedded_at) FROM repo_embeddings WHERE repo_root=? AND model=?"
    else
        "SELECT COUNT(*), COUNT(DISTINCT path), MAX(embedded_at), model FROM repo_embeddings WHERE repo_root=? GROUP BY model ORDER BY MAX(embedded_at) DESC LIMIT 1";
    const sel = conn.prepare(sql) catch return info;
    defer conn.finalize(sel);
    db.bindText(sel, 1, root) catch return info;
    if (with_model) db.bindText(sel, 2, model) catch return info;
    if (db.c.sqlite3_step(sel) == db.c.SQLITE_ROW) {
        info.chunks_indexed = @intCast(@max(0, db.c.sqlite3_column_int64(sel, 0)));
        info.files_indexed = @intCast(@max(0, db.c.sqlite3_column_int64(sel, 1)));
        const at = db.c.sqlite3_column_int64(sel, 2);
        info.updated_at = at;
        if (!with_model) {
            const mptr = db.c.sqlite3_column_text(sel, 3);
            if (mptr != null)
                info.model = allocator.dupe(u8, mptr[0..std.mem.len(mptr)]) catch model;
        }
        info.state = if (info.chunks_indexed > 0) "ready" else "empty";
    }
    return info;
}

// ── Tests ────────────────────────────────────────────────────────────────

const gh = @import("providers").github;

var test_ls: []const u8 = "";

fn testCapture(allocator: std.mem.Allocator, argv: []const []const u8, _: ?[]const u8) anyerror!gh.CmdCapture {
    var wants_ls = false;
    for (argv) |a| {
        if (std.mem.eql(u8, a, "ls-files")) wants_ls = true;
    }
    return .{
        .exit_code = 0,
        .stdout = try allocator.dupe(u8, if (wants_ls) test_ls else ""),
        .stderr = try allocator.dupe(u8, ""),
    };
}

fn tmpRoot(tmp: *std.testing.TmpDir, buf: []u8) []const u8 {
    const n = tmp.dir.realPath(std.testing.io, buf) catch return buf[0..0];
    return buf[0..n];
}

fn openRuntimeMem(a: std.mem.Allocator) !db.Connection {
    const conn = try db.Connection.open(a, ":memory:");
    const mig = db.Migrator.init(a);
    try mig.migrate(conn, &db.runtime_schema);
    return conn;
}

const FakeEmbed = struct {
    calls: usize = 0,
    texts_total: usize = 0,
    fail_after: usize = 999,

    fn call(raw: ?*anyopaque, allocator: std.mem.Allocator, texts: []const []const u8) anyerror![][]f32 {
        const self: *FakeEmbed = @ptrCast(@alignCast(raw.?));
        self.calls += 1;
        self.texts_total += texts.len;
        if (self.calls > self.fail_after) return error.RateLimited;
        const vecs = try allocator.alloc([]f32, texts.len);
        for (texts, 0..) |t, i| {
            const v = try allocator.alloc(f32, 3);
            v[0] = if (std.mem.indexOf(u8, t, "warm") != null) 1 else 0;
            v[1] = if (std.mem.indexOf(u8, t, "cold") != null) 1 else 0;
            v[2] = @floatFromInt(t.len % 7);
            vecs[i] = v;
        }
        return vecs;
    }
};

fn testIndexOpts() IndexOpts {
    var o = IndexOpts{};
    o.scan.capture = testCapture;
    o.now_ts = 1000;
    return o;
}

test "E5.15 V32: migracion crea repo_embeddings y es idempotente" {
    var conn = try openRuntimeMem(std.testing.allocator);
    defer conn.close();
    const v = try conn.getUserVersion();
    try std.testing.expectEqual(@as(i32, db.runtime_schema.len), v);
    // Reabrir sobre el mismo estado no rompe (idempotente).
    try conn.exec("SELECT COUNT(*) FROM repo_embeddings");
}

test "E5.15 indexRepo incremental: solo se re-embeben los trozos que cambian" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "x.zig", .data = "pub fn fx() void {\n    warm();\n}\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "y.zig", .data = "pub fn fy() void {\n    cold();\n}\n" });
    test_ls = "x.zig\ny.zig\n";
    var buf: [4096]u8 = undefined;
    const root = tmpRoot(&tmp, &buf);

    var conn = try openRuntimeMem(a);
    defer conn.close();
    var fe = FakeEmbed{};

    const s1 = try indexRepo(a, std.testing.io, conn, root, "m1", FakeEmbed.call, @ptrCast(&fe), testIndexOpts());
    try std.testing.expect(s1.embedded > 0);
    try std.testing.expectEqual(@as(usize, 0), s1.reused);
    try std.testing.expectEqual(@as(usize, 3), s1.dim);
    const total_chunks = s1.chunks_total;
    const embedded_first = s1.embedded;

    // Segunda pasada sin cambios: cero embeddings, todo reutilizado.
    const s2 = try indexRepo(a, std.testing.io, conn, root, "m1", FakeEmbed.call, @ptrCast(&fe), testIndexOpts());
    try std.testing.expectEqual(@as(usize, 0), s2.embedded);
    try std.testing.expectEqual(total_chunks, s2.reused);

    // Cambia un archivo: solo sus trozos nuevos se re-embeben.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "y.zig", .data = "pub fn fy() void {\n    cold();\n    cold();\n}\n// extra\n" });
    const s3 = try indexRepo(a, std.testing.io, conn, root, "m1", FakeEmbed.call, @ptrCast(&fe), testIndexOpts());
    try std.testing.expect(s3.embedded > 0);
    try std.testing.expect(s3.embedded < embedded_first);
    try std.testing.expect(s3.removed > 0); // hashes viejos de y.zig borrados
    try std.testing.expect(s3.reused > 0); // x.zig intacto, sin re-embed
}

test "E5.15 indexRepo: embedder roto deja indice parcial honesto" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "x.zig", .data = "pub fn fx() void {\n    warm();\n}\n" });
    test_ls = "x.zig\n";
    var buf: [4096]u8 = undefined;
    const root = tmpRoot(&tmp, &buf);
    var conn = try openRuntimeMem(a);
    defer conn.close();

    var fe = FakeEmbed{ .fail_after = 0 };
    const s = try indexRepo(a, std.testing.io, conn, root, "m1", FakeEmbed.call, @ptrCast(&fe), testIndexOpts());
    try std.testing.expectEqualStrings("RateLimited", s.error_note.?);
    try std.testing.expectEqual(@as(usize, 0), s.embedded);
    // La consulta de estado declara el indice vacio — nada que fingir.
    const st = indexStatus(a, conn, root, "m1");
    try std.testing.expectEqualStrings("empty", st.state);
}

test "E5.15 loadIndex: BLOB float32 vuelve como vector y la consulta lo encuentra" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "x.zig", .data = "pub fn fx() void {\n    warm();\n}\n" });
    test_ls = "x.zig\n";
    var buf: [4096]u8 = undefined;
    const root = tmpRoot(&tmp, &buf);
    var conn = try openRuntimeMem(a);
    defer conn.close();

    var fe = FakeEmbed{};
    _ = try indexRepo(a, std.testing.io, conn, root, "m1", FakeEmbed.call, @ptrCast(&fe), testIndexOpts());
    var vi = try loadIndex(a, conn, root, "m1");
    defer {
        var it = vi.map.iterator();
        while (it.next()) |e| {
            a.free(e.key_ptr.*);
            a.free(e.value_ptr.*);
        }
        vi.map.deinit();
    }
    try std.testing.expect(vi.chunks_indexed > 0);
    try std.testing.expectEqual(@as(usize, 1), vi.files_indexed);
    try std.testing.expectEqual(@as(i64, 1000), vi.updated_at);

    const st = indexStatus(a, conn, root, "m1");
    try std.testing.expectEqualStrings("ready", st.state);
    try std.testing.expectEqual(vi.chunks_indexed, st.chunks_indexed);
}

test "E5.15 indexRepo: UTF-8 roto se sanea y el trozo sin señal se descarta" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // bad.zig: byte 0xFF invalido dentro de codigo real — se sanea a '?'
    // y el trozo se embebe (hay señal). void.zig: solo bytes rotos/espacios,
    // nada embebible → skipped, no consume llamada ni fila.
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "bad.zig", .data = "pub fn fx() void {\n    warm(); // \xff\xfe\n}\n" });
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "void.zig", .data = "   \t\n\n   \n" });
    test_ls = "bad.zig\nvoid.zig\n";
    var buf: [4096]u8 = undefined;
    const root = tmpRoot(&tmp, &buf);

    var conn = try openRuntimeMem(a);
    defer conn.close();
    var fe = FakeEmbed{};
    const s = try indexRepo(a, std.testing.io, conn, root, "m1", FakeEmbed.call, @ptrCast(&fe), testIndexOpts());
    try std.testing.expect(s.embedded >= 1);
    try std.testing.expect(s.skipped >= 1);
    // El archivo vacio no tiene fila: no se finge indexado.
    const st = indexStatus(a, conn, root, "m1");
    try std.testing.expectEqual(@as(usize, 1), st.files_indexed);
    // Segunda pasada: el saneo es estable → todo reutilizado, nada re-embebido.
    const s2 = try indexRepo(a, std.testing.io, conn, root, "m1", FakeEmbed.call, @ptrCast(&fe), testIndexOpts());
    try std.testing.expectEqual(@as(usize, 0), s2.embedded);
    try std.testing.expect(s2.skipped >= 1);
}
