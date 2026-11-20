//! tools/sqlite_carga.zig — DS-TANDA2 (2026-10-16): estudio de límites de SQLite.
//!
//! Prueba de carga de solo lectura sobre el producto: NO cambia nada del motor.
//! Simula el patrón real de runtime.db con la MISMA configuración que abre
//! `core/src/db.zig` (Connection.open, líneas 48-70):
//!   motor  = journal_mode=WAL + synchronous=NORMAL + busy_timeout=5000
//!   crudo  = journal_mode=DELETE + synchronous=FULL + busy_timeout=0
//!            (configuración previa a BUG-1, 2026-08-12; sirve de control)
//!
//! N hilos escritores insertan eventos de órdenes (`content_delta`) y 2 lectores
//! listan sesiones (la consulta exacta de `session_store.listSessions`) y leen
//! eventos por orden (`c_api.zig`). Cada hilo abre SU PROPIA conexión, como el
//! motor (hilo principal + hilo de despacho + poller + webhook + MCP/CLI).
//!
//! Uso: devagents-sqlite-carga [--dur <ms>] [--out <txt>] [--dir <carpeta>]

const std = @import("std");
const core = @import("core");
const c = core.db.c;

const NS_PER_S: i64 = 1_000_000_000;
const READERS: usize = 2;
const LAT_CAP: usize = 300_000;
const TS = core.db.SQLITE_TRANSIENT;

extern "kernel32" fn Sleep(dwMilliseconds: u32) void;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn QueryPerformanceCounter(lp: *i64) callconv(.winapi) i32;
extern "kernel32" fn QueryPerformanceFrequency(lp: *i64) callconv(.winapi) i32;

var qpc_freq: i64 = 0;

fn nowMs() i64 {
    return @intCast(GetTickCount64());
}

fn qpcNow() i64 {
    var v: i64 = 0;
    _ = QueryPerformanceCounter(&v);
    return v;
}

fn nsSince(t0: i64) u64 {
    if (qpc_freq <= 0) return 0;
    const d = qpcNow() - t0;
    if (d <= 0) return 0;
    return @intCast(@divTrunc(d * NS_PER_S, qpc_freq));
}

const Mode = enum { motor, crudo };

fn modeName(m: Mode) []const u8 {
    return switch (m) {
        .motor => "motor(WAL/sync=NORMAL/busy=5000)",
        .crudo => "crudo(DELETE/sync=FULL/busy=0)",
    };
}

/// Abre una conexión aplicando la configuración del modo. Es copia literal de
/// los PRAGMA de db.zig:48-70 (motor) y del estado previo a BUG-1 (crudo).
fn openConfigured(path_z: [:0]const u8, mode: Mode) !*c.sqlite3 {
    var dbh: ?*c.sqlite3 = null;
    if (c.sqlite3_open(path_z, &dbh) != c.SQLITE_OK) return error.OpenFailed;
    const h = dbh.?;
    switch (mode) {
        .motor => {
            _ = c.sqlite3_exec(h, "PRAGMA busy_timeout = 5000", null, null, null);
            _ = c.sqlite3_exec(h, "PRAGMA journal_mode = WAL", null, null, null);
            _ = c.sqlite3_exec(h, "PRAGMA synchronous = NORMAL", null, null, null);
        },
        .crudo => {
            _ = c.sqlite3_exec(h, "PRAGMA busy_timeout = 0", null, null, null);
            _ = c.sqlite3_exec(h, "PRAGMA journal_mode = DELETE", null, null, null);
            _ = c.sqlite3_exec(h, "PRAGMA synchronous = FULL", null, null, null);
        },
    }
    return h;
}

/// Crea el esquema real con el MISMO migrador que el motor y siembra N órdenes.
/// El journal se deja WAL (lo fija Connection.open) y, para el modo crudo, se
/// convierte a DELETE antes de que abran los hilos.
fn bootstrap(aa: std.mem.Allocator, path: []const u8, mode: Mode, n_orders: i64) !void {
    var conn = try core.db.Connection.open(aa, path);
    defer conn.close();
    var mig = core.db.Migrator.init(aa);
    try mig.migrate(conn, &core.db.runtime_schema);

    var i: i64 = 1;
    while (i <= n_orders) : (i += 1) {
        const o = try std.fmt.allocPrint(aa, "INSERT INTO orders (id, project_id, user_prompt, status, created_at, title) " ++
            "VALUES ({d}, 'carga', 'orden de carga {d}', 'done', {d}, 'Carga {d}')", .{ i, i, 1000 + i, i });
        try conn.exec(o);
        const p = try std.fmt.allocPrint(aa, "INSERT INTO plans (id, order_id, understanding, approved, created_at) " ++
            "VALUES ({d}, {d}, 'entendimiento sintetico de carga {d}', 0, 1000)", .{ i, i, i });
        try conn.exec(p);
        const e = try std.fmt.allocPrint(aa, "INSERT INTO events (ts, source, kind, payload_json, order_id) " ++
            "VALUES ({d}, 'carga', 'content_delta', '{{\"content\":\"seed\"}}', {d})", .{ 1000 + i, i });
        try conn.exec(e);
    }
    if (mode == .crudo) conn.exec("PRAGMA journal_mode = DELETE") catch {};
}

const WriterCtx = struct {
    path_z: [:0]const u8,
    mode: Mode,
    n_orders: i64,
    seed: u64,
    stop: *std.atomic.Value(bool),
    writes_ok: *std.atomic.Value(u64),
    busy_seen: *std.atomic.Value(u64),
    lost: *std.atomic.Value(u64),
    lat: []u64,
    lat_len: usize = 0,

    fn run(self: *WriterCtx) void {
        const h = openConfigured(self.path_z, self.mode) catch return;
        defer _ = c.sqlite3_close(h);
        var stmt: ?*c.sqlite3_stmt = null;
        const sql = "INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (?, ?, ?, ?, ?)";
        if (c.sqlite3_prepare_v2(h, sql, sql.len, &stmt, null) != c.SQLITE_OK) return;
        defer _ = c.sqlite3_finalize(stmt);
        const s = stmt.?;

        const payload = "{\"content\":\"delta de carga sintetica para medir el limite de escritura\"}";
        var idx: u64 = self.seed;
        while (!self.stop.load(.acquire)) {
            const oid: i64 = @intCast((idx % @as(u64, @intCast(self.n_orders))) + 1);
            _ = c.sqlite3_reset(s);
            _ = c.sqlite3_clear_bindings(s);
            _ = c.sqlite3_bind_int64(s, 1, nowMs());
            _ = c.sqlite3_bind_text(s, 2, "carga", 5, TS);
            _ = c.sqlite3_bind_text(s, 3, "content_delta", 13, TS);
            _ = c.sqlite3_bind_text(s, 4, payload, payload.len, TS);
            _ = c.sqlite3_bind_int64(s, 5, oid);

            const t0 = qpcNow();
            var tries: usize = 0;
            while (true) {
                const rc = c.sqlite3_step(s);
                if (rc == c.SQLITE_DONE) {
                    if (self.lat_len < self.lat.len) {
                        self.lat[self.lat_len] = nsSince(t0);
                        self.lat_len += 1;
                    }
                    _ = self.writes_ok.fetchAdd(1, .monotonic);
                    break;
                }
                if ((rc == c.SQLITE_BUSY or rc == c.SQLITE_LOCKED) and tries < 3) {
                    _ = self.busy_seen.fetchAdd(1, .monotonic);
                    tries += 1;
                    _ = c.sqlite3_reset(s);
                    continue;
                }
                _ = self.lost.fetchAdd(1, .monotonic);
                break;
            }
            idx +%= 1;
        }
    }
};

const list_sessions_sql =
    "SELECT o.id, TRIM(REPLACE(REPLACE(SUBSTR(COALESCE(o.title, (SELECT p.understanding FROM plans p " ++
    "WHERE p.order_id = o.id AND TRIM(COALESCE(p.understanding,'')) <> '' AND p.understanding NOT LIKE " ++
    "'No pude planificar%' ORDER BY p.id DESC LIMIT 1), o.user_prompt), 1, 80), CHAR(10), ' '), CHAR(13), ' ')) " ++
    "AS title, o.status, o.created_at, COALESCE(o.conversation_id,'') AS conv FROM orders o " ++
    "WHERE substr(o.project_id, 1, 2) <> '__' ORDER BY created_at DESC";
const events_by_order_sql =
    "SELECT id, ts, source, kind, payload_json FROM events WHERE order_id = ? ORDER BY ts ASC, id ASC LIMIT ? OFFSET ?";

const ReaderCtx = struct {
    path_z: [:0]const u8,
    mode: Mode,
    n_orders: i64,
    stop: *std.atomic.Value(bool),
    read_iters: *std.atomic.Value(u64),
    read_rows: *std.atomic.Value(u64),

    fn run(self: *ReaderCtx) void {
        const h = openConfigured(self.path_z, self.mode) catch return;
        defer _ = c.sqlite3_close(h);
        var ls: ?*c.sqlite3_stmt = null;
        var ev: ?*c.sqlite3_stmt = null;
        if (c.sqlite3_prepare_v2(h, list_sessions_sql, list_sessions_sql.len, &ls, null) != c.SQLITE_OK) return;
        defer _ = c.sqlite3_finalize(ls);
        if (c.sqlite3_prepare_v2(h, events_by_order_sql, events_by_order_sql.len, &ev, null) != c.SQLITE_OK) return;
        defer _ = c.sqlite3_finalize(ev);

        var spin: i64 = 0;
        while (!self.stop.load(.acquire)) {
            _ = c.sqlite3_reset(ls);
            var rows: u64 = 0;
            while (c.sqlite3_step(ls) == c.SQLITE_ROW) rows += 1;

            const oid: i64 = @mod(spin, self.n_orders) + 1;
            _ = c.sqlite3_reset(ev);
            _ = c.sqlite3_clear_bindings(ev);
            _ = c.sqlite3_bind_int64(ev, 1, oid);
            _ = c.sqlite3_bind_int(ev, 2, 200);
            _ = c.sqlite3_bind_int(ev, 3, 0);
            while (c.sqlite3_step(ev) == c.SQLITE_ROW) rows += 1;

            _ = self.read_rows.fetchAdd(rows, .monotonic);
            _ = self.read_iters.fetchAdd(1, .monotonic);
            spin += 1;
        }
    }
};

const Result = struct {
    mode: Mode,
    n: usize,
    dur_ms: u64,
    writes_ok: u64,
    busy_seen: u64,
    lost: u64,
    read_iters: u64,
    read_rows: u64,
    p50_us: f64,
    p99_us: f64,
    lat_samples: usize,
    db_bytes: i64,
};

fn lessU64(_: void, a: u64, b: u64) bool {
    return a < b;
}

fn sortU64(xs: []u64) void {
    std.mem.sort(u64, xs, {}, lessU64);
}

fn pct(sorted: []const u64, p: f64) f64 {
    if (sorted.len == 0) return 0;
    const idx_f = p * @as(f64, @floatFromInt(sorted.len - 1));
    const idx: usize = @intFromFloat(idx_f);
    return @as(f64, @floatFromInt(sorted[idx])) / 1000.0;
}

fn dbBytes(aa: std.mem.Allocator, path_z: [:0]const u8) i64 {
    var h: ?*c.sqlite3 = null;
    if (c.sqlite3_open(path_z, &h) != c.SQLITE_OK) return 0;
    defer _ = c.sqlite3_close(h);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(h.?, "SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size()", -1, &stmt, null) != c.SQLITE_OK) return 0;
    defer _ = c.sqlite3_finalize(stmt);
    if (c.sqlite3_step(stmt.?) != c.SQLITE_ROW) return 0;
    _ = aa;
    return c.sqlite3_column_int64(stmt.?, 0);
}

fn cleanup(io: std.Io, base: []const u8) void {
    const dir = std.Io.Dir.cwd();
    dir.deleteFile(io, base) catch {};
    const wal = std.fmt.allocPrint(std.heap.page_allocator, "{s}-wal", .{base}) catch return;
    defer std.heap.page_allocator.free(wal);
    dir.deleteFile(io, wal) catch {};
    const shm = std.fmt.allocPrint(std.heap.page_allocator, "{s}-shm", .{base}) catch return;
    defer std.heap.page_allocator.free(shm);
    dir.deleteFile(io, shm) catch {};
    const jrn = std.fmt.allocPrint(std.heap.page_allocator, "{s}-journal", .{base}) catch return;
    defer std.heap.page_allocator.free(jrn);
    dir.deleteFile(io, jrn) catch {};
}

fn dumpPlan(w: *std.Io.Writer, h: *c.sqlite3, label: []const u8, sql: []const u8) void {
    const esql = std.fmt.allocPrint(std.heap.page_allocator, "EXPLAIN QUERY PLAN {s}", .{sql}) catch return;
    defer std.heap.page_allocator.free(esql);
    var stmt: ?*c.sqlite3_stmt = null;
    if (c.sqlite3_prepare_v2(h, esql.ptr, @intCast(esql.len), &stmt, null) != c.SQLITE_OK) return;
    defer _ = c.sqlite3_finalize(stmt);
    say(w, "  plan[{s}]:\n", .{label});
    while (c.sqlite3_step(stmt.?) == c.SQLITE_ROW) {
        const p = c.sqlite3_column_text(stmt.?, 3);
        const n = c.sqlite3_column_bytes(stmt.?, 3);
        if (p != null) say(w, "    - {s}\n", .{p[0..@intCast(n)]});
    }
}

/// Evidencia directa del plan de consulta de las rutas calientes de lectura.
fn explainPlans(io: std.Io, aa: std.mem.Allocator, w: *std.Io.Writer, dir: []const u8) !void {
    const base = try std.fmt.allocPrint(aa, "{s}/carga_plan.db", .{dir});
    cleanup(io, base);
    const pz = try aa.dupeZ(u8, base);
    try bootstrap(aa, base, .motor, 300);
    var h: ?*c.sqlite3 = null;
    if (c.sqlite3_open(pz, &h) != c.SQLITE_OK) return;
    defer {
        _ = c.sqlite3_close(h);
        cleanup(io, base);
    }
    say(w, "planes de consulta (EXPLAIN QUERY PLAN):\n", .{});
    dumpPlan(w, h.?, "listSessions(session_store.zig:168)", list_sessions_sql);
    dumpPlan(w, h.?, "eventsByOrder(c_api.zig:6911)", events_by_order_sql);
    say(w, "\n", .{});
}

fn runScenario(
    io: std.Io,
    aa: std.mem.Allocator,
    w: *std.Io.Writer,
    dir: []const u8,
    mode: Mode,
    n: usize,
    dur_ms: u64,
    n_orders: i64,
) !Result {
    const base = try std.fmt.allocPrint(aa, "{s}/carga_{s}_{d}.db", .{ dir, @tagName(mode), n });
    cleanup(io, base);
    const path_z = try aa.dupeZ(u8, base);

    try bootstrap(aa, base, mode, n_orders);

    var stop = std.atomic.Value(bool).init(false);
    var writes_ok = std.atomic.Value(u64).init(0);
    var busy_seen = std.atomic.Value(u64).init(0);
    var lost = std.atomic.Value(u64).init(0);
    var read_iters = std.atomic.Value(u64).init(0);
    var read_rows = std.atomic.Value(u64).init(0);

    const wctxs = try aa.alloc(WriterCtx, n);
    const wthreads = try aa.alloc(std.Thread, n);
    var wi: usize = 0;
    while (wi < n) : (wi += 1) {
        const lat = try std.heap.page_allocator.alloc(u64, LAT_CAP);
        wctxs[wi] = .{
            .path_z = path_z,
            .mode = mode,
            .n_orders = n_orders,
            .seed = @intCast(wi * 7919 + 1),
            .stop = &stop,
            .writes_ok = &writes_ok,
            .busy_seen = &busy_seen,
            .lost = &lost,
            .lat = lat,
        };
        wthreads[wi] = try std.Thread.spawn(.{}, WriterCtx.run, .{&wctxs[wi]});
    }

    var rctxs: [READERS]ReaderCtx = undefined;
    var rthreads: [READERS]std.Thread = undefined;
    var ri: usize = 0;
    while (ri < READERS) : (ri += 1) {
        rctxs[ri] = .{
            .path_z = path_z,
            .mode = mode,
            .n_orders = n_orders,
            .stop = &stop,
            .read_iters = &read_iters,
            .read_rows = &read_rows,
        };
        rthreads[ri] = try std.Thread.spawn(.{}, ReaderCtx.run, .{&rctxs[ri]});
    }

    const t0 = GetTickCount64();
    while (GetTickCount64() - t0 < dur_ms) Sleep(2);
    const actual = GetTickCount64() - t0;
    stop.store(true, .release);

    for (wthreads) |t| t.join();
    for (rthreads) |t| t.join();

    var all = std.ArrayList(u64).empty;
    var total_samples: usize = 0;
    for (wctxs) |*ctx| {
        total_samples += ctx.lat_len;
        try all.appendSlice(aa, ctx.lat[0..ctx.lat_len]);
        std.heap.page_allocator.free(ctx.lat);
    }
    sortU64(all.items);

    const size = dbBytes(aa, path_z);
    cleanup(io, base);

    const res = Result{
        .mode = mode,
        .n = n,
        .dur_ms = actual,
        .writes_ok = writes_ok.load(.acquire),
        .busy_seen = busy_seen.load(.acquire),
        .lost = lost.load(.acquire),
        .read_iters = read_iters.load(.acquire),
        .read_rows = read_rows.load(.acquire),
        .p50_us = pct(all.items, 0.50),
        .p99_us = pct(all.items, 0.99),
        .lat_samples = total_samples,
        .db_bytes = size,
    };
    report(w, res);
    return res;
}

fn report(w: *std.Io.Writer, r: Result) void {
    const secs = @as(f64, @floatFromInt(r.dur_ms)) / 1000.0;
    const wps = @as(f64, @floatFromInt(r.writes_ok)) / secs;
    const rps = @as(f64, @floatFromInt(r.read_iters)) / secs;
    say(w, "{s:34} | N={d:2} | {d:6.0} esc/s | p50={d:7.1}us p99={d:8.1}us | BUSY={d} perdidas={d} | lect/s={d:6.0} filas={d} | {d:.1} MB | {d} muestras\n", .{
        modeName(r.mode),                                        r.n,           wps, r.p50_us, r.p99_us, r.busy_seen, r.lost, rps, r.read_rows,
        @as(f64, @floatFromInt(r.db_bytes)) / (1024.0 * 1024.0), r.lat_samples,
    });
}

fn say(w: *std.Io.Writer, comptime fmt: []const u8, a: anytype) void {
    w.print(fmt, a) catch {};
    std.debug.print(fmt, a);
}

fn usage() noreturn {
    std.debug.print("uso: devagents-sqlite-carga [--dur <ms>] [--out <txt>] [--dir <carpeta>]\n", .{});
    std.process.exit(2);
}

pub fn main(init: std.process.Init.Minimal) !void {
    var arena_state = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena_state.deinit();
    const aa = arena_state.allocator();

    var threaded = std.Io.Threaded.init(aa, .{});
    defer threaded.deinit();
    const io = threaded.io();

    _ = QueryPerformanceFrequency(&qpc_freq);

    var dur_ms: u64 = 10_000;
    var dir: []const u8 = "zig-out/test-evidence/sqlite-carga";
    var out_path: ?[]const u8 = null;
    {
        var args = try std.process.Args.Iterator.initAllocator(init.args, aa);
        defer args.deinit();
        _ = args.skip();
        while (args.next()) |a| {
            if (std.mem.eql(u8, a, "--dur")) {
                dur_ms = std.fmt.parseInt(u64, args.next() orelse usage(), 10) catch usage();
            } else if (std.mem.eql(u8, a, "--out")) {
                out_path = aa.dupe(u8, args.next() orelse usage()) catch return error.OutOfMemory;
            } else if (std.mem.eql(u8, a, "--dir")) {
                dir = aa.dupe(u8, args.next() orelse usage()) catch return error.OutOfMemory;
            } else usage();
        }
    }

    std.Io.Dir.cwd().createDirPath(io, dir) catch {};

    var out_buf: std.Io.Writer.Allocating = .init(aa);
    const w = &out_buf.writer;

    say(w, "=== DS-TANDA2 · carga SQLite (runtime.db) ===\n", .{});
    say(w, "dir={s} dur={d}ms lectores={d} cap_muestras={d}\n", .{ dir, dur_ms, READERS, LAT_CAP });
    say(w, "qpc_freq={d} Hz\n\n", .{qpc_freq});

    try explainPlans(io, aa, w, dir);

    const ns = [_]usize{ 1, 4, 8, 16 };
    const n_orders: i64 = 300;
    say(w, "{s:34} | {s:5} | {s:11} | {s:24} | {s:22} | {s:13} | {s:8} | {s}\n", .{
        "configuracion", "N", "escrituras/s", "latencia p50/p99", "BUSY/perdidas", "lecturas/s", "filas", "tamano",
    });
    say(w, "{s:-<34}-+-{s:-<5}-+-{s:-<11}-+-{s:-<24}-+-{s:-<22}-+-{s:-<13}-+-{s:-<8}-+-{s:-<8}\n", .{ "", "", "", "", "", "", "", "" });

    for ([_]Mode{ .motor, .crudo }) |mode| {
        for (ns) |n| {
            _ = try runScenario(io, aa, w, dir, mode, n, dur_ms, n_orders);
        }
    }

    say(w, "\nfin.\n", .{});

    if (out_path) |op| {
        std.Io.Dir.cwd().writeFile(io, .{ .sub_path = op, .data = out_buf.written() }) catch |e| {
            say(w, "ERROR escribiendo out: {s}\n", .{@errorName(e)});
            return e;
        };
        say(w, "escrito: {s}\n", .{op});
    }
}
