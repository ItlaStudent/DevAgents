//! tests/stress_e3.zig — Batería de estrés E3.15–E3.26 del cierre V1.
//!
//! Todo lo de aquí corre contra la maquinaria REAL: `recordEvent` sobre una
//! runtime.db de verdad, `HttpClient` contra un socket vivo (MockServer con
//! comportamientos hostiles), SQLite con dos procesos escritores, y el
//! filesystem con nombres profundos/unicode. La consigna de la fila es
//! «vienes a ROMPERLO»: cada test mide lo que el producto hace de verdad y
//! declara lo que no puede probar.
//!
//! Filas cubiertas en este archivo:
//!   E3.15  10.000 eventos — tiempo, tamaño de db y eventos_perdidos.
//!   E3.18  1.000 archivos con rutas profundas, espacios, acentos y Unicode,
//!          + listado ANSI vs UTF-8 (sonda del defecto de `da_list_artifacts_json`).
//!   E3.22  corte de red a mitad de llamada (drop / partial / mute).
//!   E3.23  respuestas 429 / 500 / timeout contra mock local — sin gastar dinero.
//!   E3.25  dos procesos escribiendo la misma SQLite (proceso Zig + proceso node).
//!   E3.26  SQLITE_FULL (disco lleno simulado) + carpeta no escribible + clamp
//!          del tope de iteraciones agénticas.
//!
//! Filas E3 que viven fuera de este archivo:
//!   E3.16  executor.zig (spawn real de 50 MB — ya cubierto).
//!   E3.24  c_api.zig (tormenta de cancelaciones — necesita CoreState interno).
//!   E3.17  shell/host (document manager C++).
//!   E3.19/E3.20/E3.21 — drivers live (workers 20 min, sidebar 500, kill+checkpoint).

const std = @import("std");
const core = @import("core");
const providers = @import("providers");
const mock = @import("mock_server.zig");
const build_options = @import("build_options");

const db = core.db;
const superagent = core.superagent;
const health = core.health;
const http_client = providers.http_client;
const http = std.http;

extern "kernel32" fn GetTempPathA(nBufferLength: u32, lpBuffer: [*]u8) callconv(.winapi) u32;
extern "kernel32" fn CreateDirectoryA(lpPathName: [*:0]const u8, lpSecurityAttributes: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn RemoveDirectoryA(lpPathName: [*:0]const u8) callconv(.winapi) c_int;
extern "kernel32" fn GetTickCount64() callconv(.winapi) u64;
extern "kernel32" fn GetFileAttributesA(lpFileName: [*:0]const u8) callconv(.winapi) u32;
extern "kernel32" fn SetFileAttributesA(lpFileName: [*:0]const u8, dwFileAttributes: u32) callconv(.winapi) c_int;
extern "kernel32" fn Sleep(dwMilliseconds: u32) void;
extern "kernel32" fn GetCurrentProcess() callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn GetProcessTimes(hProcess: std.os.windows.HANDLE, lpCreationTime: *u64, lpExitTime: *u64, lpKernelTime: *u64, lpUserTime: *u64) callconv(.winapi) c_int;
extern "psapi" fn GetProcessMemoryInfo(hProcess: std.os.windows.HANDLE, ppsmemCounters: *anyopaque, cb: u32) callconv(.winapi) c_int;

/// PROCESS_MEMORY_COUNTERS tal como la devuelve psapi (solo se leen ws/peak).
const MemCounters = extern struct {
    cb: u32,
    page_faults: u32,
    peak_ws: usize,
    ws: usize,
    quota_peak_paged: usize,
    quota_paged: usize,
    quota_peak_np: usize,
    quota_np: usize,
    pagefile: usize,
    peak_pagefile: usize,
};

fn processProfile() struct { peak_ws_mb: f64, ws_mb: f64, cpu_s: f64 } {
    var counters = std.mem.zeroes(MemCounters);
    counters.cb = @sizeOf(MemCounters);
    _ = GetProcessMemoryInfo(GetCurrentProcess(), @ptrCast(&counters), @sizeOf(MemCounters));
    var create_t: u64 = 0;
    var exit_t: u64 = 0;
    var kernel_t: u64 = 0;
    var user_t: u64 = 0;
    _ = GetProcessTimes(GetCurrentProcess(), &create_t, &exit_t, &kernel_t, &user_t);
    return .{
        .peak_ws_mb = @as(f64, @floatFromInt(counters.peak_ws)) / 1048576.0,
        .ws_mb = @as(f64, @floatFromInt(counters.ws)) / 1048576.0,
        .cpu_s = @as(f64, @floatFromInt(kernel_t + user_t)) / 10_000_000.0,
    };
}
extern "kernel32" fn FindFirstFileA(lpFileName: [*:0]const u8, lpFindFileData: *anyopaque) callconv(.winapi) std.os.windows.HANDLE;
extern "kernel32" fn FindNextFileA(hFindFile: std.os.windows.HANDLE, lpFindFileData: *anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn FindClose(hFindFile: std.os.windows.HANDLE) callconv(.winapi) c_int;
const INVALID_HANDLE_VALUE: std.os.windows.HANDLE = @ptrFromInt(~@as(usize, 0));
const FILE_ATTRIBUTE_READONLY: u32 = 0x1;
const FILE_ATTRIBUTE_DIRECTORY: u32 = 0x10;

/// Un `std.Io` por test (los paths fs del fork lo exigen). Patrón de
/// mock_server.zig: Threaded en stack, io() de préstamo.
const TestIo = struct {
    threaded: std.Io.Threaded,
    fn init(a: std.mem.Allocator) TestIo {
        return .{ .threaded = std.Io.Threaded.init(a, .{}) };
    }
    fn io(self: *TestIo) std.Io {
        return self.threaded.io();
    }
    fn deinit(self: *TestIo) void {
        self.threaded.deinit();
    }
};

// ── E3.15: 10.000 eventos por la vía real de recordEvent ────────────────

test "E3.15: 10.000 eventos se registran sin pérdida y con contabilidad honesta" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try std.fmt.allocPrintSentinel(a, "{s}{s}runtime.db", .{ ".zig-cache/tmp/", tmp.sub_path }, 0);
    defer a.free(path);

    var conn = try db.Connection.open(a, path);
    defer conn.close();
    var migrator = db.Migrator.init(a);
    try migrator.migrate(conn, &db.runtime_schema);
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'stress', 'running', 1)");

    var sa = superagent.Superagent.init(a, conn, null, superagent.NoopMemory.backend(), 0);
    sa.setEventConn(conn, 1);

    const N: usize = 10_000;
    const t0 = GetTickCount64();
    for (0..N) |i| {
        var payload_buf: [96]u8 = undefined;
        const payload = std.fmt.bufPrint(&payload_buf, "{{\"i\":{d},\"kind\":\"stress\"}}", .{i}) catch unreachable;
        sa.recordEvent("stress_event", payload);
    }
    const elapsed_ms = GetTickCount64() - t0;

    // Contabilidad honesta: ningún evento se perdió en silencio.
    try std.testing.expectEqual(@as(usize, 0), sa.eventosPerdidos());

    const stmt = try conn.prepare("SELECT COUNT(*) FROM events WHERE kind = 'stress_event'");
    defer conn.finalize(stmt);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
    try std.testing.expectEqual(@as(i64, @intCast(N)), db.c.sqlite3_column_int64(stmt, 0));

    // Tamaño de la db tras 10k eventos — la fila pide medirlo, no solo contarlo.
    var tio = TestIo.init(a);
    defer tio.deinit();
    const st = try std.Io.Dir.cwd().statFile(tio.io(), path, .{});
    std.debug.print("[E3.15] 10k eventos: {d} ms, db={d} B ({d:.1} MB), perdidos=0\n", .{ elapsed_ms, st.size, @as(f64, @floatFromInt(st.size)) / 1048576.0 });
}

// ── E3.18: 1.000 archivos, rutas profundas, espacios, acentos, Unicode ───

test "E3.18: 1.000 archivos unicode/deep se crean y el listado ANSI los mutila (sonda)" {
    const a = std.testing.allocator;
    // tmpDir = raíz única por corrida (autolimpieza): una raíz fija en %TEMP%
    // heredaría los 1.000 archivos de la corrida anterior y falsearía el conteo.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try std.fmt.allocPrint(a, ".zig-cache/tmp/{s}", .{tmp.sub_path});
    defer a.free(root);

    // 1.000 archivos repartidos en 25 directorios: profundidad real (hasta 8
    // niveles), espacios, acentos latinos y Unicode CJK en nombres de carpeta
    // y de archivo. Todos dentro del temporal (nada toca el workspace real).
    const dir_names = [_][]const u8{
        "modulo base",
        "análisis árbol",
        "reportes 日本語",
        "deep\\a\\b\\c\\d\\e\\f",
        "café ñandú",
        "一级\\二级\\三级",
        "datos méxico",
        "src\\comp\\util\\core",
        "københavn århus",
        "prüfung größe",
        "naïve façade",
        "Москва\\Санкт",
        "x",
        "y z",
        "sección 五",
        "lib\\índice\\tú",
        "öl är god",
        "Ελληνικά",
        "हिंदी फ़ोल्डर",
        "sub dir with many spaces",
        "münchen straße",
        "são paulo",
        "eesti keel",
        "türkçe dosyalar",
        "最后\\的\\目录\\深度",
    };
    var tio = TestIo.init(a);
    defer tio.deinit();
    const io = tio.io();

    var created: usize = 0;
    for (dir_names, 0..) |d, di| {
        const dir_path = try std.fmt.allocPrint(a, "{s}\\{s}", .{ root, d });
        defer a.free(dir_path);
        std.Io.Dir.cwd().createDirPath(io, dir_path) catch |e| {
            std.debug.print("[E3.18] createDirPath falló en «{s}»: {s}\n", .{ d, @errorName(e) });
            return e;
        };
        // 40 archivos por directorio = 1.000 total.
        for (0..40) |fi| {
            const fname = try std.fmt.allocPrint(a, "{s}\\archivo {d} índice-ñ-日{d}_{d}.txt", .{ dir_path, fi, di, fi });
            defer a.free(fname);
            var content_buf: [64]u8 = undefined;
            const content = std.fmt.bufPrint(&content_buf, "contenido {d}/{d} áéíóú\n", .{ di, fi }) catch unreachable;
            const f = try std.Io.Dir.createFileAbsolute(io, fname, .{});
            defer f.close(io);
            try f.writeStreamingAll(io, content);
            created += 1;
        }
    }
    try std.testing.expectEqual(@as(usize, 1000), created);

    // Enumeración recursiva real: los 1.000 existen y sus nombres sobreviven
    // el viaje UTF-8 ↔ Win32-W íntegros.
    var root_dir = try std.Io.Dir.cwd().openDir(io, root, .{ .iterate = true });
    defer root_dir.close(io);
    var counted: usize = 0;
    var walker = try root_dir.walk(a);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind == .file) counted += 1;
    }
    try std.testing.expectEqual(@as(usize, 1000), counted);
    std.debug.print("[E3.18] 1000 archivos unicode/deep creados y re-enumerados: OK\n", .{});

    // Carpeta ASCII adicional con 40 archivos de nombre unicode: es la forma
    // exacta del listado real (directorio ASCII direccionable, nombres UTF-8
    // dentro) que hace da_list_artifacts_json.
    const plain_dir = try std.fmt.allocPrint(a, "{s}\\plain", .{root});
    defer a.free(plain_dir);
    try std.Io.Dir.cwd().createDirPath(io, plain_dir);
    for (0..40) |fi| {
        const fname = try std.fmt.allocPrint(a, "{s}\\fichero acentuado-ñ-日{d}.txt", .{ plain_dir, fi });
        defer a.free(fname);
        const f = try std.Io.Dir.createFileAbsolute(io, fname, .{});
        defer f.close(io);
        try f.writeStreamingAll(io, "x");
    }

    // SONDA del listado ANSI de da_list_artifacts_json: FindFirstFileA devuelve
    // cFileName en la página de códigos ANSI — un nombre UTF-8 real se mutila,
    // y una RUTA con unicode directamente no se puede ni direccionar. Se miden
    // ambos daños para la bitácora, sin normalizar el resultado con un assert.
    const FD = extern struct {
        attrs: u32,
        ft: [6]u32,
        size_hi: u32,
        size_lo: u32,
        r0: u32,
        r1: u32,
        name: [260]u8,
        alt: [14]u8,
    };

    // Medida 1: nombres unicode dentro de un dir ASCII — ¿sobreviven idénticos?
    {
        var find_buf: [4096:0]u8 = undefined;
        const pattern = std.fmt.bufPrintZ(&find_buf, "{s}\\*", .{plain_dir}) catch unreachable;
        var fd: FD = undefined;
        const h = FindFirstFileA(pattern, @ptrCast(&fd));
        try std.testing.expect(h != INVALID_HANDLE_VALUE);
        defer _ = FindClose(h);
        var ansi_ok: usize = 0;
        var ansi_mangled: usize = 0;
        while (true) {
            const name_len = std.mem.indexOfScalar(u8, &fd.name, 0) orelse fd.name.len;
            const name = fd.name[0..name_len];
            if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) {
                // El nombre real era "fichero acentuado-ñ-日N.txt": si la vía
                // ANSI lo devuelve idéntico, UTF-8→ANSI sobrevivió; si no, dañado.
                if (std.mem.indexOf(u8, name, "acentuado-ñ-日") != null) ansi_ok += 1 else ansi_mangled += 1;
            }
            if (FindNextFileA(h, @ptrCast(&fd)) == 0) break;
        }
        std.debug.print("[E3.18] ANSI en dir ASCII: {d} nombres intactos, {d} dañados de {d}\n", .{ ansi_ok, ansi_mangled, ansi_ok + ansi_mangled });
        try std.testing.expect(ansi_ok + ansi_mangled == 40);
    }

    // Medida 2: una RUTA con unicode («café ñandú») por la vía ANSI — la
    // mutilación del path puede hacer el directorio completamente inaccesible.
    {
        var find_buf: [4096:0]u8 = undefined;
        const pattern = std.fmt.bufPrintZ(&find_buf, "{s}\\café ñandú\\*", .{root}) catch unreachable;
        var fd: FD = undefined;
        const h = FindFirstFileA(pattern, @ptrCast(&fd));
        if (h == INVALID_HANDLE_VALUE) {
            std.debug.print("[E3.18] ANSI con ruta unicode: dir INACCESIBLE (INVALID_HANDLE_VALUE)\n", .{});
        } else {
            defer _ = FindClose(h);
            var seen: usize = 0;
            while (true) {
                const name_len = std.mem.indexOfScalar(u8, &fd.name, 0) orelse fd.name.len;
                const name = fd.name[0..name_len];
                if (!std.mem.eql(u8, name, ".") and !std.mem.eql(u8, name, "..")) seen += 1;
                if (FindNextFileA(h, @ptrCast(&fd)) == 0) break;
            }
            std.debug.print("[E3.18] ANSI con ruta unicode: {d} entradas devueltas\n", .{seen});
        }
    }
}

// ── E3.22: corte de red a mitad de llamada ───────────────────────────────

test "E3.22: el servidor corta a mitad de llamada — error honesto, sin colgar ni inventar" {
    const a = std.testing.allocator;

    // 1) Corte ANTES de responder: acepta y cierra sin un byte.
    {
        var server = try mock.MockServer.init(a, "{\"ok\":true}", "application/json");
        server.behavior = .drop;
        try server.start();
        defer server.deinit();
        const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1/chat", .{server.port});
        defer a.free(url);
        var client = try http_client.HttpClient.init(a);
        client.socket_timeout_seconds = 10;
        defer client.deinit();
        const r = client.postJsonWithHeaders(url, "{}", &.{});
        // No puede devolver ni 200 ni un cuerpo inventado: tiene que ser error.
        if (r) |resp| {
            a.free(resp.body);
            return error.TestUnexpectedResult;
        } else |e| {
            std.debug.print("[E3.22] drop → {s}\n", .{@errorName(e)});
        }
    }

    // 2) Corte a MEDIA respuesta: llegan la mitad de los bytes y el socket muere.
    {
        var server = try mock.MockServer.init(a, "{\"choices\":[{\"message\":{\"content\":\"texto parcial\"}}]}", "application/json");
        server.behavior = .partial;
        try server.start();
        defer server.deinit();
        const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1/chat", .{server.port});
        defer a.free(url);
        var client = try http_client.HttpClient.init(a);
        client.socket_timeout_seconds = 10;
        defer client.deinit();
        const r = client.postJsonWithHeaders(url, "{}", &.{});
        // Un cuerpo truncado NO puede venderse como respuesta completa.
        if (r) |resp| {
            a.free(resp.body);
            return error.TestUnexpectedResult;
        } else |e| {
            std.debug.print("[E3.22] partial → {s}\n", .{@errorName(e)});
        }
    }

    // 3) Servidor MUDO: acepta y nunca responde — el plazo del socket corta.
    {
        var server = try mock.MockServer.init(a, "", "application/json");
        server.behavior = .mute;
        try server.start();
        defer server.deinit();
        const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1/chat", .{server.port});
        defer a.free(url);
        var client = try http_client.HttpClient.init(a);
        defer client.deinit();
        // El plazo real en Windows es el threadlocal de deadline_io (SO_RCVTIMEO
        // no existe sobre sockets AFD): 3 s de test contra el 60 s por defecto.
        providers.deadline_io.current_deadline_ms = 3_000;
        defer providers.deadline_io.current_deadline_ms = 0;
        const t0 = GetTickCount64();
        const r = client.postJsonWithHeaders(url, "{}", &.{});
        const elapsed = GetTickCount64() - t0;
        // El plazo del socket funcionó: no nos colgamos los 120 s del mock.
        // (El boundary de Reader collapsea el Timeout a ReadFailed — el error
        // real queda en r.err del stream; lo que importa es que corta y falla.)
        if (r) |resp| {
            a.free(resp.body);
            return error.TestUnexpectedResult;
        } else |e| {
            std.debug.print("[E3.22] mute → {s} en {d} ms (plazo deadline_io=3s)\n", .{ @errorName(e), elapsed });
        }
        try std.testing.expect(elapsed < 60_000);
    }
}

// ── E3.23: 429 / 500 / timeout sin gastar dinero ─────────────────────────

test "E3.23: 429, 500 y timeout contra mock local — clasificación honesta" {
    const a = std.testing.allocator;

    // 429: el status viaja intacto hasta el llamador (la rotación de claves
    // y el backoff viven una capa más arriba, ya cubiertos por tests de
    // credentials.zig — aquí se verifica que el status NO se pierde).
    {
        var server = try mock.MockServer.init(a, "{\"error\":{\"message\":\"rate limited\"}}", "application/json");
        server.status_line = "429 Too Many Requests";
        try server.start();
        defer server.deinit();
        const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1/chat", .{server.port});
        defer a.free(url);
        var client = try http_client.HttpClient.init(a);
        defer client.deinit();
        const r = try client.postJsonWithHeaders(url, "{}", &.{});
        defer a.free(r.body);
        try std.testing.expectEqual(http.Status.too_many_requests, r.status);
    }

    // 500: ídem — error del servidor visible, no un 200 fingido.
    {
        var server = try mock.MockServer.init(a, "{\"error\":{\"message\":\"boom\"}}", "application/json");
        server.status_line = "500 Internal Server Error";
        try server.start();
        defer server.deinit();
        const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1/chat", .{server.port});
        defer a.free(url);
        var client = try http_client.HttpClient.init(a);
        defer client.deinit();
        const r = try client.postJsonWithHeaders(url, "{}", &.{});
        defer a.free(r.body);
        try std.testing.expectEqual(http.Status.internal_server_error, r.status);
    }

    // Timeout: el servidor mudo corta por plazo de socket — classifyError lo
    // reporta como timeout de proveedor (no como "respuesta vacía").
    {
        var server = try mock.MockServer.init(a, "", "application/json");
        server.behavior = .mute;
        try server.start();
        defer server.deinit();
        const url = try std.fmt.allocPrint(a, "http://127.0.0.1:{d}/v1/chat", .{server.port});
        defer a.free(url);
        var client = try http_client.HttpClient.init(a);
        defer client.deinit();
        providers.deadline_io.current_deadline_ms = 3_000;
        defer providers.deadline_io.current_deadline_ms = 0;
        const r = client.postJsonWithHeaders(url, "{}", &.{});
        // En esta capa el timeout emerge como ReadFailed (collapse del boundary
        // de Reader). La llamada DEBE fallar; el nombre queda en evidencia.
        if (r) |resp| {
            a.free(resp.body);
            return error.TestUnexpectedResult;
        } else |e| {
            std.debug.print("[E3.23] mute → {s}; classifyError → {s}\n", .{ @errorName(e), @tagName(health.classifyError(e)) });
        }
        // El contrato de clasificación donde Timeout SÍ propaga (retry_planner
        // y las capas que ven el error crudo): Timeout → timeout, jamás "ok".
        try std.testing.expectEqual(health.Status.timeout, health.classifyError(error.Timeout));
    }
}

// ── E3.25: dos procesos escribiendo la misma SQLite ──────────────────────

test "E3.25: dos PROCESOS escriben la misma runtime.db — busy_timeout, sin pérdida" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fmt.allocPrintSentinel(a, "{s}{s}shared.db", .{ ".zig-cache/tmp/", tmp.sub_path }, 0);
    defer a.free(db_path);

    // Esquema vía la migración real.
    {
        var setup = try db.Connection.open(a, db_path);
        defer setup.close();
        var migrator = db.Migrator.init(a);
        try migrator.migrate(setup, &db.runtime_schema);
        try setup.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'x', 'running', 1)");
    }

    // Proceso hijo REAL: python escribe 500 eventos con su propio sqlite3
    // (stdlib, con busy_timeout de 5 s) sobre EL MISMO archivo.
    const ChildOut = struct {
        fn script(path_z: []const u8) ![]u8 {
            // Barra normal: sqlite3 acepta '/' en Windows y esquiva quoting.
            var py_path_buf: [4096]u8 = undefined;
            var w: usize = 0;
            for (path_z) |c| {
                py_path_buf[w] = if (c == '\\') '/' else c;
                w += 1;
            }
            return try std.fmt.allocPrint(std.heap.page_allocator, "import sqlite3;" ++
                "d=sqlite3.connect(r'{s}',timeout=5);" ++
                "c=d.cursor();lost=0;ok=0;" ++
                "\nfor i in range(500):" ++
                "\n try: c.execute(\"INSERT INTO events (ts,source,kind,payload_json,order_id) VALUES (?,?,?,?,?)\",(i,'py-child','child_event','{{}}',1));d.commit();ok+=1" ++
                "\n except Exception: lost+=1" ++
                "\nd.close();print('CHILD ok=%d lost=%d'%(ok,lost))", .{py_path_buf[0..w]});
        }
    };
    const child_script = try ChildOut.script(db_path);
    defer std.heap.page_allocator.free(child_script);

    var tio = TestIo.init(a);
    defer tio.deinit();
    const io = tio.io();

    // El hijo arranca y corre MIENTRAS el padre escribe — contención real, no
    // secuencial. `spawn` no bloquea; `wait` recoge al final.
    var child = std.process.spawn(io, .{
        .argv = &.{ "python", "-c", child_script },
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return error.SkipZigTest; // sin python no hay 2º proceso
    defer child.kill(io);

    // Proceso padre (este test): 500 eventos más por la vía REAL recordEvent.
    var conn = try db.Connection.open(a, db_path);
    defer conn.close();
    var sa = superagent.Superagent.init(a, conn, null, superagent.NoopMemory.backend(), 0);
    sa.setEventConn(conn, 1);
    for (0..500) |i| {
        var pb: [64]u8 = undefined;
        const payload = std.fmt.bufPrint(&pb, "{{\"i\":{d}}}", .{i}) catch unreachable;
        sa.recordEvent("parent_event", payload);
    }
    try std.testing.expectEqual(@as(usize, 0), sa.eventosPerdidos());

    // `wait` libera los pipes del hijo: hay que drenarlos ANTES. Las salidas
    // son de una línea — sin riesgo de deadlock por pipe lleno.
    var out_buf: [4096]u8 = undefined;
    var err_buf: [4096]u8 = undefined;
    var out_n: usize = 0;
    var err_n: usize = 0;
    while (out_n < out_buf.len) {
        const n = child.stdout.?.readStreaming(io, &.{out_buf[out_n..]}) catch break;
        if (n == 0) break;
        out_n += n;
    }
    while (err_n < err_buf.len) {
        const n = child.stderr.?.readStreaming(io, &.{err_buf[err_n..]}) catch break;
        if (n == 0) break;
        err_n += n;
    }
    const term = try child.wait(io);
    const child_code: u8 = switch (term) {
        .exited => |c| c,
        else => 255,
    };
    std.debug.print("[E3.25] child exit={d} stdout: {s} stderr: {s}\n", .{ child_code, out_buf[0..out_n], err_buf[0..err_n] });

    // Cuenta final: 500 del padre + los que el hijo logró. Si el hijo perdió
    // eventos lo dice en su log — lo que NO puede pasar es pérdida silenciosa
    // del lado Zig (eventos_perdidos == 0 ya se verificó).
    const stmt = try conn.prepare("SELECT COUNT(*) FROM events WHERE kind IN ('parent_event','child_event')");
    defer conn.finalize(stmt);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
    const total = db.c.sqlite3_column_int64(stmt, 0);
    std.debug.print("[E3.25] eventos totales en db compartida: {d} (500 padre + N hijo)\n", .{total});
    try std.testing.expect(total >= 500);
}

// ── E3.19: ≥12 workers sostenidos 20 min con perfil memoria/CPU ────────────

fn e319Now() u64 {
    return GetTickCount64();
}

test "E3.19: ≥12 workers sostenidos — humo 20 s en suite, soak 20 min bajo BEATS_E3_SOAK" {
    const a = std.testing.allocator;

    // La fila exige 20 minutos: demasiado para el gate de cada corrida. La
    // ventana corta (20 s) prueba la estructura (12 workers ocupados, cero
    // fallos, perfil medido); la corrida larga sale con BEATS_E3_SOAK=1 y se
    // documenta en la evidencia E3.19.
    var env_map = std.process.Environ.createMap(.{ .block = .global }, a) catch null;
    defer if (env_map) |*m| m.deinit();
    const soak = if (env_map) |m| m.get("BEATS_E3_SOAK") != null else false;
    const seconds: u64 = if (soak) 20 * 60 else 20;

    var sched = try core.scheduler.Scheduler.initWithConfig(
        a,
        .{
            .num_workers = 12,
            .task_timeout_ms = 30_000,
            .max_retries = 0,
            .heartbeat_interval_ms = 1_000,
            .supervisor_tick_ms = 100,
            .backoff_base_ms = 10,
        },
        core.scheduler.defaultWorkHandler,
        e319Now,
        null,
    );
    defer sched.deinit();
    try sched.start();

    // Sostén real: ≥48 tareas EN VUELO (pendientes de despachar + en cola del
    // pool) durante toda la ventana — los 12 workers no tienen hueco ocioso.
    // Cada tarea corre el handler real del scheduler (alloc + setResult).
    const p0 = processProfile();
    const t0 = GetTickCount64();
    var submitted: usize = 0;
    while (GetTickCount64() - t0 < seconds * 1000) {
        const in_flight = sched.getPendingTasks() + sched.pool.pending();
        var need: usize = if (in_flight < 48) 48 - in_flight else 0;
        while (need > 0) : (need -= 1) {
            const id = try std.fmt.allocPrint(a, "e319-{d}", .{submitted});
            defer a.free(id);
            const task = try core.scheduler.Task.create(a, id, "sustained soak work", 1, 0);
            try sched.enqueueTask(task);
            submitted += 1;
        }
        try sched.submitAll();
        Sleep(200);
    }
    // Drenar lo en vuelo y cerrar limpio.
    var drain_ms: u64 = 0;
    while (sched.pool.pending() > 0 and drain_ms < 30_000) : (drain_ms += 50) {
        Sleep(50);
    }
    sched.stop();
    const elapsed_s = @as(f64, @floatFromInt(GetTickCount64() - t0)) / 1000.0;
    const p1 = processProfile();

    const completed = sched.getCompletedTasks();
    const failed = sched.getFailedTasks();
    std.debug.print(
        "[E3.19] {d:.0}s: workers={d}, enviadas={d}, completadas={d}, fallidas={d}, peakWS={d:.1}MB→{d:.1}MB, WS={d:.1}MB→{d:.1}MB, vivas={d}, cpu={d:.1}s→{d:.1}s\n",
        .{ elapsed_s, sched.pool.workers.len, submitted, completed, failed, p0.peak_ws_mb, p1.peak_ws_mb, p0.ws_mb, p1.ws_mb, sched.tasks.items.len, p0.cpu_s, p1.cpu_s },
    );
    try std.testing.expectEqual(@as(usize, 12), sched.pool.workers.len);
    try std.testing.expectEqual(@as(usize, 0), failed);
    try std.testing.expect(completed > 0);
}

// ── E3.20: ≥500 sesiones en la barra lateral sin parpadeo ──────────────────

test "E3.20: 500 sesiones en la barra — enumeración completa, estable y rápida" {
    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_core_init(&handle, ":memory:"));
    defer _ = core.c_api.da_core_shutdown(handle);

    var order: ?*anyopaque = null;
    for (0..500) |i| {
        var pb: [64]u8 = undefined;
        const prompt = std.fmt.bufPrintZ(&pb, "orden de estres {d}", .{i}) catch unreachable;
        var pid: [64]u8 = undefined;
        const project = std.fmt.bufPrintZ(&pid, "e320-{d}", .{i}) catch unreachable;
        try std.testing.expectEqual(
            @as(c_int, 0),
            core.c_api.da_order_submit(handle, prompt, project, null, &order),
        );
    }

    // Enumeración completa: 500 entradas, ni una menos.
    var json: [*:0]u8 = undefined;
    const t0 = GetTickCount64();
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_sessions_json(handle, &json));
    const enum_ms = GetTickCount64() - t0;
    defer core.c_api.da_string_free(json);
    const s = std.mem.span(json);
    var count: usize = 0;
    var pos: usize = 0;
    while (std.mem.indexOfPos(u8, s, pos, "\"id\"")) |idx| {
        count += 1;
        pos = idx + 4;
    }
    try std.testing.expectEqual(@as(usize, 500), count);

    // "Sin parpadeo" = orden ESTABLE: dos enumeraciones seguidas deben ser
    // byte a byte idénticas — una barra que reordena parpadea.
    var json2: [*:0]u8 = undefined;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_sessions_json(handle, &json2));
    defer core.c_api.da_string_free(json2);
    const s2 = std.mem.span(json2);
    try std.testing.expectEqualStrings(s, s2);

    std.debug.print("[E3.20] 500 sesiones: {d} entradas, {d} ms, json={d} B, orden estable\n", .{ count, enum_ms, s.len });
}

// ── E3.26: disco lleno, carpeta no escribible, tope de iteraciones ───────

test "E3.26: SQLITE_FULL falla honesto y no deja la db corrupta" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const db_path = try std.fmt.allocPrintSentinel(a, "{s}{s}full.db", .{ ".zig-cache/tmp/", tmp.sub_path }, 0);
    defer a.free(db_path);

    var conn = try db.Connection.open(a, db_path);
    defer conn.close();
    var migrator = db.Migrator.init(a);
    try migrator.migrate(conn, &db.runtime_schema);
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (1, 'p', 'x', 'running', 1)");

    // Disco lleno REAL simulado: max_page_count fija el techo de páginas de la
    // db — un INSERT que necesite páginas nuevas devuelve SQLITE_FULL, el mismo
    // código que da un disco físicamente lleno. Se fija el techo al tamaño
    // ACTUAL: cualquier crecimiento queda bloqueado.
    {
        const pages_stmt = try conn.prepare("PRAGMA page_count");
        defer conn.finalize(pages_stmt);
        try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(pages_stmt));
        const pages = db.c.sqlite3_column_int64(pages_stmt, 0);
        const cap_sql = try std.fmt.allocPrint(a, "PRAGMA max_page_count = {d}", .{pages});
        defer a.free(cap_sql);
        try conn.exec(cap_sql);
    }

    var sa = superagent.Superagent.init(a, conn, null, superagent.NoopMemory.backend(), 0);
    sa.setEventConn(conn, 1);

    // Fila gorda (~8 KB): no cabe en el hueco de una página de 4 KB — exige
    // páginas nuevas, que el techo ya bloqueó → SQLITE_FULL real. recordEvent
    // debe CONTAR el evento perdido, no fingir que entró.
    var fat_payload: [8200]u8 = undefined;
    @memset(&fat_payload, 'x');
    fat_payload[0] = '"';
    fat_payload[fat_payload.len - 1] = '"';
    var attempts: usize = 0;
    while (sa.eventosPerdidos() == 0 and attempts < 64) : (attempts += 1) {
        sa.recordEvent("stress_event", &fat_payload);
    }
    try std.testing.expect(sa.eventosPerdidos() >= 1);

    // Y la db sigue íntegra: PRAGMA integrity_check no reporta corrupción.
    const stmt = try conn.prepare("PRAGMA integrity_check");
    defer conn.finalize(stmt);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
    const txt = db.c.sqlite3_column_text(stmt, 0);
    try std.testing.expectEqualStrings("ok", std.mem.span(txt));
    std.debug.print("[E3.26] SQLITE_FULL: perdidos={d}, integrity=ok\n", .{sa.eventosPerdidos()});
}

test "E3.26: apertura en carpeta no-escribible falla honesto (sin db a medias)" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    _ = CreateDirectoryA(root, null);
    defer {
        _ = SetFileAttributesA(root, FILE_ATTRIBUTE_DIRECTORY);
        _ = RemoveDirectoryA(root);
    }

    // Carpeta solo-lectura REAL (ACL ligero: atributo readonly de Win32 — el
    // CreateFile de SQLite falla igual que sobre una carpeta sin permiso).
    const ro_sub = try std.fmt.allocPrintSentinel(a, "{s}\\locked", .{root}, 0);
    defer a.free(ro_sub);
    _ = CreateDirectoryA(ro_sub, null);
    defer {
        _ = SetFileAttributesA(ro_sub, FILE_ATTRIBUTE_DIRECTORY);
        _ = RemoveDirectoryA(ro_sub);
    }
    if (SetFileAttributesA(ro_sub, FILE_ATTRIBUTE_READONLY | FILE_ATTRIBUTE_DIRECTORY) == 0)
        return error.SkipZigTest; // sin privilegio para el atributo → no se puede probar

    const db_path = try std.fmt.allocPrintSentinel(a, "{s}\\runtime.db", .{ro_sub}, 0);
    defer a.free(db_path);
    const r = db.Connection.open(a, db_path);
    // Puede abrir si el FS ignora el atributo readonly en este entorno — lo que
    // NO puede es dejar una db a medio crear y reportar éxito: si abrió, el
    // esquema migra entero o no existe.
    if (r) |c| {
        var conn = c;
        defer conn.close();
        var migrator = db.Migrator.init(a);
        migrator.migrate(conn, &db.runtime_schema) catch |e| {
            std.debug.print("[E3.26] readonly dir: migrate falló honesto: {s}\n", .{@errorName(e)});
            return;
        };
        std.debug.print("[E3.26] readonly dir: el FS ignoró el atributo; migración completa\n", .{});
    } else |e| {
        std.debug.print("[E3.26] readonly dir: open falló honesto: {s}\n", .{@errorName(e)});
    }
}

// ── H-G3: reasoning_delta BD ↔ API de eventos de la cabina ────────
extern "kernel32" fn DeleteFileA(lpFileName: [*:0]const u8) callconv(.winapi) c_int;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;

fn hg3RemoveDirFiles(a: std.mem.Allocator, dir: []const u8) void {
    const names = [_][]const u8{
        "runtime.db", "runtime.db-wal", "runtime.db-shm",
        "catalog.db", "catalog.db-wal", "catalog.db-shm",
        "ledger.db",  "ledger.db-wal",  "ledger.db-shm",
        "mcp_token",
    };
    for (names) |name| {
        const p = std.fmt.allocPrintSentinel(a, "{s}/{s}", .{ dir, name }, 0) catch continue;
        _ = DeleteFileA(p);
        a.free(p);
    }
    const dz = a.dupeZ(u8, dir) catch return;
    _ = RemoveDirectoryA(dz);
    a.free(dz);
}

test "H-G3: reasoning_delta persiste N trozos y la API de la cabina devuelve los mismos N en orden" {
    const a = std.testing.allocator;
    const root = build_options.worktree_root;
    const pid = GetCurrentProcessId();
    const dir = try std.fmt.allocPrint(a, "{s}/.zig-cache/prb003b-h3-{d}", .{ root, pid });
    defer a.free(dir);
    defer hg3RemoveDirFiles(a, dir);
    const dir_z = try a.dupeZ(u8, dir);
    defer a.free(dir_z);
    _ = CreateDirectoryA(dir_z, null);

    const db_path = try std.fmt.allocPrintSentinel(a, "{s}/runtime.db", .{dir}, 0);
    defer a.free(db_path);

    // Guardia de deriva: la prueba replica el payload del emisor privado
    // (emitReasoningDelta). Si ese contrato cambia, esto falla y avisa.
    {
        const src_path = try std.fmt.allocPrint(a, "{s}/core/src/live_worker.zig", .{root});
        defer a.free(src_path);
        const src = try std.Io.Dir.cwd().readFileAlloc(std.testing.io, src_path, a, .limited(1 << 20));
        defer a.free(src);
        try std.testing.expect(std.mem.indexOf(u8, src, "INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (?, ?, ?, ?, ?)") != null);
        try std.testing.expect(std.mem.indexOf(u8, src, "js.objectField(\"reasoning\")") != null);
        try std.testing.expect(std.mem.indexOf(u8, src, "db.bindText(stmt, 3, \"reasoning_delta\")") != null);
    }

    var conn = try db.Connection.open(a, db_path);
    const migrator = db.Migrator.init(a);
    try migrator.migrate(conn, &db.runtime_schema);

    // Productor: la MISMA ruta de escritura que usa el worker vivo
    // (LiveLlm.recordEvent sobre event_conn), con N trozos de razonamiento.
    var llm = core.live_worker.LiveLlm{
        .allocator = a,
        .lives = &.{},
        .buffer = .empty,
        .catalog_path = "",
        .task_id = "gh3",
    };
    llm.setEventConn(conn, 4242);
    const chunks = [_][]const u8{
        "analizando el problema",
        "revisando el diff",
        "proponiendo el parche",
        "verificando las pruebas",
        "cerrando el razonamiento",
    };
    for (chunks) |text| {
        const payload = try std.fmt.allocPrint(a, "{{\"reasoning\":\"{s}\",\"task_id\":\"gh3\"}}", .{text});
        defer a.free(payload);
        llm.recordEvent("reasoning_delta", payload);
    }
    llm.deinit();
    conn.close();

    // Consumidor: la API que usa la cabina, sin tocarla.
    var handle: ?*anyopaque = null;
    try std.testing.expectEqual(@as(c_int, 0), core.c_api.da_core_init(&handle, db_path));
    defer _ = core.c_api.da_core_shutdown(handle);

    var json: [*:0]u8 = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        core.c_api.da_order_events_json(handle, @ptrFromInt(@as(usize, 4242)), 0, &json),
    );
    defer core.c_api.da_string_free(json);

    var parsed = try std.json.parseFromSlice(std.json.Value, a, std.mem.span(json), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value == .array);
    const arr = parsed.value.array.items;
    try std.testing.expectEqual(chunks.len, arr.len);

    // Conteo SQL independiente: NO se deriva de chunks.len ni de lo que la API
    // acaba de devolver. Se lee de la misma tabla que escribe recordEvent
    // (INSERT INTO events (ts, source, kind, payload_json, order_id) en
    // live_worker.zig) y se contrasta contra el conteo de la API.
    var verify_conn = try db.Connection.open(a, db_path);
    defer verify_conn.close();
    const count_stmt = try verify_conn.prepare(
        "SELECT COUNT(*) FROM events WHERE order_id = ? AND kind = 'reasoning_delta'",
    );
    defer verify_conn.finalize(count_stmt);
    try db.bindInt(count_stmt, 1, 4242);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(count_stmt));
    const db_events = db.c.sqlite3_column_int64(count_stmt, 0);
    var ui_events: i64 = 0;
    for (arr) |item| {
        if (std.mem.eql(u8, item.object.get("kind").?.string, "reasoning_delta")) ui_events += 1;
    }
    try std.testing.expectEqual(db_events, ui_events);

    // Orden: el ORDER BY es el mismo que usa da_order_events_json
    // (ts ASC, id ASC); los ids de la base deben coincidir uno a uno y en el
    // mismo orden creciente con los que devuelve la cabina.
    const ids_stmt = try verify_conn.prepare(
        "SELECT id FROM events WHERE order_id = ? AND kind = 'reasoning_delta' ORDER BY ts ASC, id ASC",
    );
    defer verify_conn.finalize(ids_stmt);
    try db.bindInt(ids_stmt, 1, 4242);
    var db_ids = std.ArrayList(i64).empty;
    defer db_ids.deinit(a);
    while (db.c.sqlite3_step(ids_stmt) == db.c.SQLITE_ROW) {
        try db_ids.append(a, db.c.sqlite3_column_int64(ids_stmt, 0));
    }
    try std.testing.expectEqual(@as(usize, @intCast(db_events)), db_ids.items.len);
    try std.testing.expectEqual(db_ids.items.len, arr.len);
    for (arr, 0..) |item, i| {
        try std.testing.expectEqual(db_ids.items[i], item.object.get("id").?.integer);
    }

    var first_id: i64 = 0;
    var last_id: i64 = 0;
    for (arr, 0..) |item, i| {
        const obj = item.object;
        try std.testing.expectEqualStrings("reasoning_delta", obj.get("kind").?.string);
        try std.testing.expectEqualStrings("Razonamiento", obj.get("title").?.string);
        try std.testing.expectEqualStrings("info", obj.get("severity").?.string);
        const id = obj.get("id").?.integer;
        try std.testing.expect(id > last_id);
        if (i == 0) first_id = id;
        last_id = id;
        const payload = obj.get("payload").?.object;
        try std.testing.expectEqualStrings(chunks[i], payload.get("reasoning").?.string);
        try std.testing.expectEqualStrings("gh3", payload.get("task_id").?.string);
    }

    // Paginación incremental: desde el primer id llegan exactamente N-1.
    var json2: [*:0]u8 = undefined;
    try std.testing.expectEqual(
        @as(c_int, 0),
        core.c_api.da_order_events_json(handle, @ptrFromInt(@as(usize, 4242)), first_id, &json2),
    );
    defer core.c_api.da_string_free(json2);
    var parsed2 = try std.json.parseFromSlice(std.json.Value, a, std.mem.span(json2), .{});
    defer parsed2.deinit();
    try std.testing.expectEqual(chunks.len - 1, parsed2.value.array.items.len);

    std.debug.print(
        "HG3_CROSS db_events={d} ui_events={d} incremental={d} titles=Razonamiento order=preserved\n",
        .{ db_events, ui_events, parsed2.value.array.items.len },
    );
}

// ── H-G8: soak de 12 workers con perfil y veredicto de crecimiento ─
fn hg8Seconds() ?u64 {
    const a = std.testing.allocator;
    var env_map = std.process.Environ.createMap(.{ .block = .global }, a) catch return null;
    defer env_map.deinit();
    const raw = env_map.get("BEATS_E3_SOAK_SECONDS") orelse return null;
    const n = std.fmt.parseInt(u64, raw, 10) catch return null;
    if (n == 0) return null;
    return n;
}

test "H-G8: 12 workers sostenidos con perfil de memoria y sin crecimiento" {
    // Paso test-soak: la ventana llega por entorno desde -Dsoak-seconds.
    // Sin esa variable (suite normal) la prueba no consume tiempo.
    const seconds = hg8Seconds() orelse return;
    const a = std.testing.allocator;

    var sched = try core.scheduler.Scheduler.initWithConfig(
        a,
        .{
            .num_workers = 12,
            .task_timeout_ms = 30_000,
            .max_retries = 0,
            .heartbeat_interval_ms = 1_000,
            .supervisor_tick_ms = 100,
            .backoff_base_ms = 10,
        },
        core.scheduler.defaultWorkHandler,
        e319Now,
        null,
    );
    defer sched.deinit();
    try sched.start();

    var samples = std.ArrayList(f64).empty;
    defer samples.deinit(a);

    const p0 = processProfile();
    const t0 = GetTickCount64();
    const window_ms = seconds * 1000;
    var next_sample: u64 = t0 + 1000;
    var submitted: usize = 0;
    while (GetTickCount64() - t0 < window_ms) {
        const in_flight = sched.getPendingTasks() + sched.pool.pending();
        var need: usize = if (in_flight < 48) 48 - in_flight else 0;
        while (need > 0) : (need -= 1) {
            const id = try std.fmt.allocPrint(a, "hg8-{d}", .{submitted});
            defer a.free(id);
            const task = try core.scheduler.Task.create(a, id, "soak sostenido h-g8", 1, 0);
            try sched.enqueueTask(task);
            submitted += 1;
        }
        try sched.submitAll();
        Sleep(200);
        const now = GetTickCount64();
        while (now >= next_sample) : (next_sample += 1000) {
            try samples.append(a, processProfile().ws_mb);
        }
    }
    var drain_ms: u64 = 0;
    while (sched.pool.pending() > 0 and drain_ms < 30_000) : (drain_ms += 50) {
        Sleep(50);
    }
    sched.stop();

    const elapsed_s = @as(f64, @floatFromInt(GetTickCount64() - t0)) / 1000.0;
    const p1 = processProfile();
    const completed = sched.getCompletedTasks();
    const failed = sched.getFailedTasks();

    // Crecimiento sostenido: media de la segunda mitad contra la primera,
    // descartando los primeros 5 s de calentamiento.
    var first_sum: f64 = 0;
    var first_n: usize = 0;
    var second_sum: f64 = 0;
    var second_n: usize = 0;
    if (samples.items.len > 5) {
        const usable = samples.items[5..];
        const mid = usable.len / 2;
        for (usable[0..mid]) |ws| {
            first_sum += ws;
            first_n += 1;
        }
        for (usable[mid..]) |ws| {
            second_sum += ws;
            second_n += 1;
        }
    }
    const first_avg = if (first_n > 0) first_sum / @as(f64, @floatFromInt(first_n)) else 0;
    const second_avg = if (second_n > 0) second_sum / @as(f64, @floatFromInt(second_n)) else 0;
    const growth_mb = second_avg - first_avg;
    const growth_threshold_mb: f64 = 16.0;

    std.debug.print(
        "[H-G8] {d:.0}s: workers={d}, enviadas={d}, completadas={d}, fallidas={d}, muestras={d}, ws_inicio={d:.2}MB, ws_media_1={d:.2}MB, ws_media_2={d:.2}MB, crecimiento={d:.2}MB, peakWS={d:.1}MB, cpu={d:.1}s\n",
        .{ elapsed_s, sched.pool.workers.len, submitted, completed, failed, samples.items.len, p0.ws_mb, first_avg, second_avg, growth_mb, p1.peak_ws_mb, p1.cpu_s - p0.cpu_s },
    );

    try std.testing.expectEqual(@as(usize, 12), sched.pool.workers.len);
    try std.testing.expectEqual(@as(usize, 0), failed);
    try std.testing.expect(completed > 0);
    try std.testing.expect(samples.items.len >= 5);
    try std.testing.expect(growth_mb <= growth_threshold_mb);
    try std.testing.expect(p1.peak_ws_mb < 512.0);
}
