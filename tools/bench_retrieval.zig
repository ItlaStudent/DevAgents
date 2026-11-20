//! tools/bench_retrieval.zig — E5.16: medición de recuperación.
//!
//! Mide recall@5 y MRR de cuatro métodos sobre las 30 consultas cuya verdad
//! está commiteada en E516-VERDAD-CONSULTAS.json ANTES de medir:
//!   - grep literal: ocurrencias literales (case-insensitive) de cada término
//!     de la consulta por archivo; ranking por nº de términos distintos que
//!     aparecen y luego por total de ocurrencias. Es `git grep -ilF` por
//!     término con conteo — sin modelo IR, la vara más baja honesta.
//!   - bm25: repo_search.search en modo léxico (el motor real).
//!   - repo-map: repo_map.rankedPaths (pagerank sembrado por la consulta).
//!   - híbrida: repo_search.search modo hybrid = RRF(BM25, coseno) sobre el
//!     índice vectorial persistente del repo (si está vacío y hay embedder
//!     configurado se indexa una pasada honesta; si no se puede, el JSON de
//!     semantic_status lo dice y la métrica marca el motivo — nunca se
//!     disfraza BM25 de híbrido).
//!
//! Además (--plan, por defecto activo): las 5 órdenes `plan_orders` se pasan
//! por el LlmPlanner REAL dos veces — con y sin `repo_map_text` — y se anota
//! si el plan nombra el archivo esperado (owns/descripción/entendimiento) y
//! si el plan lo produjo el LLM o el mock local (evento planner_fallback).
//!
//! Uso: devagents-bench-retrieval.exe [--truth <json>] [--catalog <db>]
//!      [--runtime <db>] [--no-plan] [--out <txt>]
//! Defaults: truth del repo, catálogo/runtime de %TEMP%\beats-e515-data si
//! existen (evidencia E5.15) si no %LOCALAPPDATA%\DevAgents.

const std = @import("std");
const core = @import("core");

extern "kernel32" fn GetTickCount64() u64;
extern "kernel32" fn GetEnvironmentVariableA(name: [*:0]const u8, buf: [*]u8, size: u32) u32;

fn nowMs() i64 {
    return @intCast(GetTickCount64());
}

fn envVar(allocator: std.mem.Allocator, name: [*:0]const u8) ?[]const u8 {
    var buf: [4096]u8 = undefined;
    const n = GetEnvironmentVariableA(name, &buf, buf.len);
    if (n == 0 or n >= buf.len) return null;
    return allocator.dupe(u8, buf[0..n]) catch null;
}

const GrepFile = struct { path: []const u8, content: []const u8 };

const RepoCtx = struct {
    id: []const u8,
    root: []const u8,
    grep_files: []GrepFile = &.{},
    map: ?*core.repo_map.RepoMap = null,
    vi: ?core.repo_search.VectorIndex = null,
    index_note: []const u8 = "",
};

const Method = enum { grep, bm25, repomap, hybrid };

const Score = struct {
    hits: usize = 0,
    rr: f64 = 0,
    n: usize = 0,

    fn add(self: *Score, rank: ?usize) void {
        self.n += 1;
        if (rank) |r| {
            if (r <= 5) self.hits += 1;
            self.rr += 1.0 / @as(f64, @floatFromInt(r));
        }
    }
    fn recall(self: *const Score) f64 {
        return if (self.n == 0) 0 else @as(f64, @floatFromInt(self.hits)) / @as(f64, @floatFromInt(self.n));
    }
    fn mrr(self: *const Score) f64 {
        return if (self.n == 0) 0 else self.rr / @as(f64, @floatFromInt(self.n));
    }
};

fn normPath(arena: std.mem.Allocator, p: []const u8) []const u8 {
    var out = arena.alloc(u8, p.len) catch return p;
    for (p, 0..) |c, i| out[i] = if (c == '\\') '/' else std.ascii.toLower(c);
    return out;
}

fn pathRank(paths: []const []const u8, expect_norm: []const u8) ?usize {
    for (paths, 0..) |p, i| {
        var buf: [4096]u8 = undefined;
        if (p.len > buf.len) continue;
        for (p, 0..) |c, j| buf[j] = if (c == '\\') '/' else std.ascii.toLower(c);
        const pn = buf[0..p.len];
        if (std.mem.eql(u8, pn, expect_norm)) return i + 1;
        // Sufijo: expect puede ser relativo corto (p.ej. "src/x.py") y el
        // ranking devolver rutas con el mismo nombre normalizado.
        if (pn.len > expect_norm.len and
            std.mem.endsWith(u8, pn, expect_norm) and pn[pn.len - expect_norm.len - 1] == '/')
            return i + 1;
    }
    return null;
}

/// Ranking grep literal por términos: file que contiene más términos
/// distintos (literal, case-insensitive) gana; desempata por ocurrencias.
fn grepRank(arena: std.mem.Allocator, files: []const GrepFile, query: []const u8, top: usize) ![][]const u8 {
    // Términos CRUDOS (no el folding del motor): es lo que un desarrollador
    // teclea en `git grep -iF` — palabras literales separadas por espacio.
    var terms = std.ArrayList([]const u8).empty;
    var it = std.mem.tokenizeAny(u8, query, " \t.,;:()[]{}\"'");
    while (it.next()) |t| {
        if (t.len < 2) continue;
        const lt = try arena.alloc(u8, t.len);
        try terms.append(arena, std.ascii.lowerString(lt, t));
    }
    const Scored = struct { path: []const u8, distinct: usize, occ: usize };
    var scored = std.ArrayList(Scored).empty;
    for (files) |f| {
        const dst = try arena.alloc(u8, f.content.len);
        const lc = std.ascii.lowerString(dst, f.content);
        var distinct: usize = 0;
        var occ: usize = 0;
        for (terms.items) |t| {
            var n: usize = 0;
            var pos: usize = 0;
            while (pos + t.len <= lc.len) {
                if (std.mem.indexOfPos(u8, lc, pos, t)) |found| {
                    n += 1;
                    pos = found + t.len;
                } else break;
            }
            if (n > 0) distinct += 1;
            occ += n;
        }
        if (distinct > 0) try scored.append(arena, .{ .path = f.path, .distinct = distinct, .occ = occ });
    }
    std.mem.sort(Scored, scored.items, {}, struct {
        fn lt(_: void, a: Scored, b: Scored) bool {
            if (a.distinct != b.distinct) return a.distinct > b.distinct;
            if (a.occ != b.occ) return a.occ > b.occ;
            return std.mem.lessThan(u8, a.path, b.path);
        }
    }.lt);
    const n = @min(top, scored.items.len);
    var out = try arena.alloc([]const u8, n);
    for (scored.items[0..n], 0..) |s, i| out[i] = s.path;
    return out;
}

/// Rutas únicas de los matches de una búsqueda repo_search (dedup por path).
fn searchPaths(arena: std.mem.Allocator, res: *core.repo_search.SearchResult, top: usize) ![][]const u8 {
    var seen = std.StringHashMap(void).init(arena);
    var out = std.ArrayList([]const u8).empty;
    for (res.matches) |m| {
        const np = normPath(arena, m.path);
        if (seen.contains(np)) continue;
        try seen.put(np, {});
        try out.append(arena, m.path);
        if (out.items.len >= top) break;
    }
    return out.items;
}

fn say(w: *std.Io.Writer, comptime fmt: []const u8, a: anytype) void {
    w.print(fmt, a) catch {};
    std.debug.print(fmt, a);
}

fn usage() noreturn {
    std.debug.print(
        "uso: devagents-bench-retrieval [--truth <json>] [--catalog <db>] " ++
            "[--runtime <db>] [--no-plan] [--out <txt>]\n",
        .{},
    );
    std.process.exit(2);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const aa = arena_state.allocator();

    var threaded = std.Io.Threaded.init(aa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    // ── Args ────────────────────────────────────────────────────────────
    var truth_path: []const u8 = "";
    var catalog_path: []const u8 = "";
    var runtime_path: []const u8 = "";
    var out_path: ?[]const u8 = null;
    var do_plan = true;
    {
        var args = try std.process.Args.Iterator.initAllocator(init.args, aa);
        defer args.deinit();
        _ = args.skip();
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--truth")) {
                truth_path = aa.dupe(u8, args.next() orelse usage()) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, a, "--catalog")) {
                catalog_path = aa.dupe(u8, args.next() orelse usage()) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, a, "--runtime")) {
                runtime_path = aa.dupe(u8, args.next() orelse usage()) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, a, "--out")) {
                out_path = aa.dupe(u8, args.next() orelse usage()) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, a, "--no-plan")) {
                do_plan = false;
            } else usage();
        }
    }
    const temp_dir = envVar(aa, "TEMP") orelse "C:/Temp";
    if (catalog_path.len == 0) {
        const cand = try std.fmt.allocPrint(aa, "{s}\\beats-e515-data\\catalog.db", .{temp_dir});
        if (std.Io.Dir.cwd().openFile(io, cand, .{})) |f| {
            f.close(io);
            catalog_path = cand;
        } else |_| {
            const local = envVar(aa, "LOCALAPPDATA") orelse "C:/Temp";
            catalog_path = try std.fmt.allocPrint(aa, "{s}\\DevAgents-Angel\\catalog.db", .{local});
        }
    }
    if (runtime_path.len == 0) {
        const cand = try std.fmt.allocPrint(aa, "{s}\\beats-e515-data\\runtime.db", .{temp_dir});
        if (std.Io.Dir.cwd().openFile(io, cand, .{})) |f| {
            f.close(io);
            runtime_path = cand;
        } else |_| {
            const local = envVar(aa, "LOCALAPPDATA") orelse "C:/Temp";
            runtime_path = try std.fmt.allocPrint(aa, "{s}\\DevAgents-Angel\\runtime.db", .{local});
        }
    }

    var out_buf: std.Io.Writer.Allocating = .init(aa);
    const w = &out_buf.writer;

    say(w, "=== E5.16 bench_retrieval ===\ncatalog={s}\nruntime={s}\ntruth={s}\n\n", .{ catalog_path, runtime_path, truth_path });

    // ── Verdad commiteada ───────────────────────────────────────────────
    const truth_text = blk: {
        var f = std.Io.Dir.cwd().openFile(io, truth_path, .{}) catch |e| {
            say(w, "ERROR abriendo truth: {s}\n", .{@errorName(e)});
            return e;
        };
        defer f.close(io);
        const st = f.stat(io) catch return error.IoFailed;
        const buf = try aa.alloc(u8, @intCast(st.size));
        const got = f.readPositionalAll(io, buf, 0) catch return error.IoFailed;
        break :blk buf[0..got];
    };
    var pj = try std.json.parseFromSlice(std.json.Value, aa, truth_text, .{});
    defer pj.deinit();
    const truth = pj.value.object;

    // ── Conexiones ──────────────────────────────────────────────────────
    var catalog_db = try core.db.Connection.open(aa, catalog_path);
    defer catalog_db.close();
    var runtime_db = try core.db.Connection.open(aa, runtime_path);
    defer runtime_db.close();

    // ── Embedder (capa semántica real, si está configurada) ─────────────
    var embed_ctx: ?*core.embedder_ctx.EmbedderCtx = null;
    var embed_note: []const u8 = "ok";
    {
        var ec: *core.embedder_ctx.EmbedderCtx = undefined;
        if (core.embedder_ctx.resolve(catalog_db, catalog_path, aa, &ec)) |note| {
            embed_note = note;
        } else {
            embed_ctx = ec;
        }
    }
    say(w, "embedder: {s}{s}\n\n", .{ embed_note, if (embed_ctx) |e| try std.fmt.allocPrint(aa, " ({s}/{s})", .{ e.provider, e.model }) else "" });

    // ── Contexto por repo ───────────────────────────────────────────────
    var repos = std.StringHashMap(RepoCtx).init(aa);
    {
        const repos_obj = truth.get("repos").?.object;
        var rit = repos_obj.iterator();
        while (rit.next()) |e| {
            const rid = e.key_ptr.*;
            const root_raw = e.value_ptr.object.get("root").?.string;
            var root: []const u8 = root_raw;
            if (std.mem.indexOf(u8, root_raw, "%TEMP%") != null) {
                root = try std.fmt.allocPrint(aa, "{s}{s}", .{ temp_dir, root_raw[std.mem.indexOf(u8, root_raw, "%TEMP%").? + "%TEMP%".len ..] });
            } else if (std.mem.eql(u8, root_raw, ".")) {
                root = std.Io.Dir.cwd().realPathFileAlloc(io, ".", aa) catch root_raw;
            }
            try repos.put(rid, .{ .id = rid, .root = root });
        }
    }

    // Precarga por repo: corpus grep, repo-map, índice vectorial.
    {
        var rit = repos.iterator();
        while (rit.next()) |e| {
            const rc = e.value_ptr;
            const t0 = nowMs();
            // Corpus para grep literal (mismas exclusiones que el motor).
            const raw_files = core.repo_map.listFiles(aa, null, rc.root) orelse {
                say(w, "repo {s}: no es git o no accesible — se omite (root={s})\n", .{ rc.id, rc.root });
                continue;
            };
            const root_dir = std.Io.Dir.cwd().openDir(io, rc.root, .{}) catch continue;
            defer root_dir.close(io);
            var gfiles = std.ArrayList(GrepFile).empty;
            var total: usize = 0;
            for (raw_files) |rel| {
                const rel2 = std.mem.trim(u8, rel, " \t\r");
                if (rel2.len == 0 or core.repo_map.isBinaryExt(rel2)) continue;
                if (gfiles.items.len >= 1500 or total > 12 * 1024 * 1024) break;
                const c = core.repo_map.readTextFile(aa, io, root_dir, rel2, 160 * 1024) orelse continue;
                total += c.len;
                try gfiles.append(aa, .{ .path = rel2, .content = c });
            }
            rc.grep_files = gfiles.items;

            // repo-map (con caché del runtime).
            rc.map = core.repo_map.buildOrLoad(aa, io, rc.root, .{}, runtime_db) catch null;

            // Índice vectorial: cargar; si vacío y hay embedder, una pasada
            // incremental honesta (cota del rate-limit incluida).
            if (embed_ctx) |ec| {
                var vi = try core.repo_embed.loadIndex(aa, runtime_db, rc.root, ec.model);
                if (vi.map.count() == 0) {
                    const stats = core.repo_embed.indexRepo(
                        aa,
                        io,
                        runtime_db,
                        rc.root,
                        ec.model,
                        core.embedder_ctx.cloudEmbed,
                        ec,
                        .{},
                    ) catch |err| blk: {
                        rc.index_note = @errorName(err);
                        break :blk core.repo_embed.IndexStats{};
                    };
                    if (stats.error_note) |en| rc.index_note = en;
                    vi = try core.repo_embed.loadIndex(aa, runtime_db, rc.root, ec.model);
                }
                rc.vi = vi;
            } else {
                rc.index_note = embed_note;
            }
            say(w, "repo {s}: files={d} map={s} vi={s} ({d}t) en {d}ms\n", .{
                rc.id,                                  rc.grep_files.len,
                if (rc.map != null) "ok" else "null",   if (rc.vi != null) "ok" else "none",
                if (rc.vi) |v| v.chunks_indexed else 0, nowMs() - t0,
            });
        }
    }

    // ── Medición de las 30 consultas ────────────────────────────────────
    var per_repo = std.StringHashMap([4]Score).init(aa);
    var totals: [4]Score = .{ .{}, .{}, .{}, .{} };
    say(w, "\n--- detalle por consulta ---\n", .{});
    {
        const qs = truth.get("queries").?.array.items;
        for (qs) |qv| {
            const o = qv.object;
            const qid = o.get("id").?.integer;
            const rid = o.get("repo").?.string;
            const q = o.get("q").?.string;
            const expect = o.get("expect").?.object.get("path").?.string;
            const expect_norm = normPath(aa, expect);
            const rc = repos.getPtr(rid) orelse continue;

            var ranks: [4]?usize = .{ null, null, null, null };
            var hybrid_note: []const u8 = "";

            // grep
            const gp = try grepRank(aa, rc.grep_files, q, 8);
            ranks[@intFromEnum(Method.grep)] = pathRank(gp, expect_norm);
            // bm25
            if (core.repo_search.search(aa, io, rc.root, q, .{ .max_results = 8 })) |res| {
                defer res.deinit();
                ranks[@intFromEnum(Method.bm25)] = pathRank(try searchPaths(aa, res, 8), expect_norm);
            } else |_| {}
            // repo-map
            if (rc.map) |m| {
                if (core.repo_map.rankedPaths(aa, m, q, 8)) |mp| {
                    ranks[@intFromEnum(Method.repomap)] = pathRank(mp, expect_norm);
                } else |_| {}
            }
            // híbrida
            if (embed_ctx) |ec| {
                var opts: core.repo_search.Options = .{
                    .max_results = 8,
                    .semantic_rerank = true,
                    .embed_fn = core.embedder_ctx.cloudEmbed,
                    .embed_ctx = ec,
                };
                if (rc.vi) |*vi| opts.vector_index = vi;
                if (core.repo_search.search(aa, io, rc.root, q, opts)) |res| {
                    defer res.deinit();
                    hybrid_note = res.semantic_status orelse "ok";
                    ranks[@intFromEnum(Method.hybrid)] = pathRank(try searchPaths(aa, res, 8), expect_norm);
                } else |err| {
                    hybrid_note = @errorName(err);
                }
            } else {
                hybrid_note = embed_note;
            }

            var scores = per_repo.get(rid) orelse [4]Score{ .{}, .{}, .{}, .{} };
            for (0..4) |k| {
                scores[k].add(ranks[k]);
                totals[k].add(ranks[k]);
            }
            per_repo.put(rid, scores) catch {};
            say(w, "#{d} [{s}] {s} => expect={s} | grep={?d} bm25={?d} map={?d} hyb={?d}{s}\n", .{
                qid,      rid,      q,        expect,
                ranks[0], ranks[1], ranks[2], ranks[3],
                if (hybrid_note.len > 0 and !std.mem.eql(u8, hybrid_note, "ok"))
                    try std.fmt.allocPrint(aa, " (semantic_status={s})", .{hybrid_note})
                else
                    "",
            });
        }
    }

    // ── Tabla resumen ───────────────────────────────────────────────────
    const names = [4][]const u8{ "grep", "bm25", "repo-map", "híbrida" };
    say(w, "\n=== TABLA recall@5 / MRR ===\n", .{});
    say(w, "{s:10} | {s:>12} | {s:>12} | {s:>12} | {s:>12}\n", .{ "repo", names[0], names[1], names[2], names[3] });
    {
        var rit = per_repo.iterator();
        while (rit.next()) |e| {
            say(w, "{s:10} |", .{e.key_ptr.*});
            for (0..4) |k| {
                const s = e.value_ptr[k];
                say(w, " {d}/{d} {d:.2} |", .{ s.hits, s.n, s.mrr() });
            }
            say(w, "\n", .{});
        }
    }
    say(w, "{s:10} |", .{"TOTAL"});
    for (0..4) |k| {
        say(w, " {d}/{d} r={d:.3} mrr={d:.3} |", .{ totals[k].hits, totals[k].n, totals[k].recall(), totals[k].mrr() });
    }
    say(w, "\n", .{});

    // ── Efecto en el plan (5 órdenes, LlmPlanner real, con/sin mapa) ──────
    if (do_plan) blk: {
        const po_v = truth.get("plan_orders") orelse break :blk;
        say(w, "\n=== EFECTO EN EL PLAN (LlmPlanner real, con/sin repo-map) ===\n", .{});
        say(w, "{s:4} | {s:28} | {s:6} | {s:22} | {s:6} | {s:22}\n", .{ "id", "archivo esperado", "con mapa", "prov/modelo", "sin mapa", "prov/modelo" });
        var hit_con: usize = 0;
        var hit_sin: usize = 0;
        var n_orders: usize = 0;
        var mock_count: usize = 0;
        for (po_v.array.items, 0..) |ov, i| {
            const o = ov.object;
            const oid = o.get("id").?.string;
            const order = o.get("order").?.string;
            const expect = o.get("expect").?.object.get("path").?.string;
            const rc = repos.get(o.get("repo").?.string) orelse continue;
            const base = std.fs.path.basename(expect);
            var exp_buf: [256]u8 = undefined;
            for (base, 0..) |c, j| exp_buf[j] = std.ascii.toLower(c);
            const expect_base = exp_buf[0..base.len];

            var named: [2]bool = .{ false, false };
            var prov: [2][]const u8 = .{ "-", "-" };
            var idx: usize = 0;
            for ([2]bool{ true, false }) |with_map| {
                const event_id: i64 = 990000 + @as(i64, @intCast(i * 2 + idx));
                var lp = core.llm_planner.LlmPlanner.init(aa, catalog_path);
                lp.event_conn = runtime_db;
                lp.event_order_id = event_id;
                if (with_map) {
                    if (core.repo_map.renderForPrompt(aa, io, rc.root, order, 2000, .{}, runtime_db)) |rm| {
                        lp.repo_map_text = rm.text;
                    }
                }
                const backend = lp.backend();
                const t_call = nowMs();
                if (backend.plan(aa, order, &.{}, null)) |plan| {
                    var p = plan;
                    defer p.deinit();
                    // ¿nombra el archivo esperado? (owns + description + understanding)
                    for (p.tasks) |t| {
                        for (t.owns) |own| {
                            if (containsLower(own, expect_base)) named[idx] = true;
                        }
                        if (containsLower(t.description, expect_base)) named[idx] = true;
                    }
                    if (containsLower(p.understanding, expect_base)) named[idx] = true;
                    if (p.needsClarification()) prov[idx] = "clarify";
                } else |_| {
                    prov[idx] = "error";
                }
                // ¿LLM real o fallback local? Evento planner_fallback del ctx.
                if (prov[idx][0] == '-') {
                    prov[idx] = "llm";
                    const es = runtime_db.prepare("SELECT payload_json FROM events WHERE kind='planner_fallback' AND order_id=?") catch null;
                    if (es) |s| {
                        defer runtime_db.finalize(s);
                        core.db.bindInt(s, 1, event_id) catch {};
                        if (core.db.c.sqlite3_step(s) == core.db.c.SQLITE_ROW) {
                            prov[idx] = "mock";
                            mock_count += 1;
                        }
                    }
                    // Atribución: último (provider,model) con last_ok_at en
                    // model_health — la cadena marca salud por intento.
                    if (std.mem.eql(u8, prov[idx], "llm")) {
                        const hs = runtime_db.prepare("SELECT model_id FROM model_health WHERE last_ok_at IS NOT NULL ORDER BY last_ok_at DESC LIMIT 1") catch null;
                        if (hs) |s| {
                            defer runtime_db.finalize(s);
                            if (core.db.c.sqlite3_step(s) == core.db.c.SQLITE_ROW) {
                                const txt = core.db.c.sqlite3_column_text(s, 0);
                                if (txt != null) {
                                    const m = std.mem.span(@as([*:0]const u8, @ptrCast(txt)));
                                    prov[idx] = std.fmt.allocPrint(aa, "llm:{s}", .{m}) catch "llm";
                                }
                            }
                        }
                    }
                }
                say(w, "  [{s} {s}] {d} ms\n", .{ oid, if (with_map) "con-mapa" else "sin-mapa", nowMs() - t_call });
                idx += 1;
            }
            n_orders += 1;
            if (named[0]) hit_con += 1;
            if (named[1]) hit_sin += 1;
            say(w, "{s:4} | {s:28} | {s:6} | {s:22} | {s:6} | {s:22}\n", .{
                oid,     base,
                if (named[0]) "sí" else "no",
                prov[0],
                if (named[1]) "sí" else "no",
                prov[1],
            });
        }
        say(w, "archivo esperado nombrado: con-mapa {d}/{d} · sin-mapa {d}/{d} · fallback-mock={d}\n", .{ hit_con, n_orders, hit_sin, n_orders, mock_count });
    }

    // ── Volcado a archivo ───────────────────────────────────────────────
    if (out_path) |op| {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = op, .data = out_buf.written() }) catch |e| {
            say(w, "ERROR escribiendo out: {s}\n", .{@errorName(e)});
            return e;
        };
        say(w, "\nescrito: {s}\n", .{op});
    }
}

fn containsLower(haystack: []const u8, needle_lower: []const u8) bool {
    if (needle_lower.len == 0 or haystack.len < needle_lower.len) return false;
    var buf: [64]u8 = undefined;
    var i: usize = 0;
    while (i + needle_lower.len <= haystack.len) : (i += 1) {
        const n = @min(needle_lower.len, buf.len);
        for (haystack[i .. i + n], 0..) |c, j| buf[j] = std.ascii.toLower(c);
        if (std.mem.eql(u8, buf[0..n], needle_lower)) return true;
    }
    return false;
}
