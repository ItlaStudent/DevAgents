const std = @import("std");
const db = @import("db.zig");
const workspace = @import("workspace.zig");

/// Depuración de órdenes desde la traza persistida (lección de la orden 148):
/// la instrumentación que cazó la causa raíz de `empty` vivía entera en
/// runtime.db (`orders` + `events`), y solo llegaba a ella una consulta SQL
/// escrita a mano. Este módulo la hace ciudadana de primera clase del CLI:
/// `devagents debug last` (o `devagents debug <order_id>`) imprime el vuelco
/// bruto sin depender de que la interfaz decida qué contar.
///
/// Es SOLO LECTURA: ni migra la BD, ni escribe eventos, ni toca claves.
pub const OrderTrace = struct {
    order_id: i64,
    status: []const u8,
    user_prompt: []const u8,
    created_at: i64,
    events: std.ArrayList(TraceEvent) = .empty,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *OrderTrace) void {
        self.allocator.free(self.status);
        self.allocator.free(self.user_prompt);
        for (self.events.items) |*ev| ev.deinit(self.allocator);
        self.events.deinit(self.allocator);
    }
};

/// Un evento ya reducido a los campos que importan para el diagnóstico. Las
/// cadenas son copias propias (o ""); `deinit` libera las que se llenaron.
/// Los opcionales nulos no se imprimen si no vinieron en el payload.
pub const TraceEvent = struct {
    ts: i64,
    source: []const u8,
    kind: []const u8,
    task_id: []const u8,
    provider: []const u8,
    model: []const u8,
    key_label: []const u8,
    status: []const u8,
    error_name: []const u8,
    cause: []const u8,
    model_used: []const u8,
    file_path: []const u8,
    sample: []const u8,
    total_len: ?i64,
    closed: ?bool,
    exit_code: ?i64,

    fn deinit(self: *TraceEvent, allocator: std.mem.Allocator) void {
        inline for (ALL_SLOTS) |f| {
            const s: []const u8 = @field(self, f);
            if (s.len > 0) allocator.free(s);
        }
    }

    fn dup(allocator: std.mem.Allocator, slice: []const u8) []const u8 {
        if (slice.len == 0) return "";
        return allocator.dupe(u8, slice) catch "";
    }
};

/// TODOS los campos de texto: sirven de lista de `deinit`, porque `source` y
/// `kind` también son copias propias (vienen de la fila, no del payload).
const ALL_SLOTS = .{
    "source",     "kind",  "task_id",    "provider",  "model",  "key_label", "status",
    "error_name", "cause", "model_used", "file_path", "sample",
};

/// Los campos de texto que se copian del payload (nombre de campo STRUCT ==
/// nombre de campo JSON). `source`/`kind` no están aquí: vienen de la fila.
const STRING_SLOTS = .{
    "task_id", "provider",   "model",     "key_label", "status", "error_name",
    "cause",   "model_used", "file_path", "sample",
};

/// Carga la traza de la orden `order_id` (o de la última existente si `null`).
/// `conn` debe apuntar a runtime.db migrada; no se escribe nada.
pub fn loadTrace(allocator: std.mem.Allocator, conn: db.Connection, order_id: ?i64) !OrderTrace {
    var trace: OrderTrace = .{
        .order_id = 0,
        .status = "",
        .user_prompt = "",
        .created_at = 0,
        .allocator = allocator,
    };
    errdefer trace.deinit();

    // "La última" por id DESC: el id es monotónico y es lo que muestra la UI.
    const order_stmt = if (order_id) |oid| blk: {
        const st = conn.prepare("SELECT id, user_prompt, status, created_at FROM orders WHERE id = ?") catch return error.TraceDbUnavailable;
        db.bindInt(st, 1, oid) catch {
            conn.finalize(st);
            return error.TraceBindFailed;
        };
        break :blk st;
    } else blk: {
        break :blk conn.prepare("SELECT id, user_prompt, status, created_at FROM orders ORDER BY id DESC LIMIT 1") catch return error.TraceDbUnavailable;
    };
    defer conn.finalize(order_stmt);

    if (db.c.sqlite3_step(order_stmt) != db.c.SQLITE_ROW) {
        return if (order_id) |_| error.OrderNotFound else error.NoOrdersYet;
    }
    trace.order_id = db.c.sqlite3_column_int64(order_stmt, 0);
    trace.user_prompt = TraceEvent.dup(allocator, textCol(order_stmt, 1));
    trace.status = TraceEvent.dup(allocator, textCol(order_stmt, 2));
    trace.created_at = db.c.sqlite3_column_int64(order_stmt, 3);

    // Eventos en orden de tiempo ESTABLE: ts y, para empatar milisegundos, id.
    const ev_stmt = conn.prepare("SELECT ts, source, kind, payload_json FROM events WHERE order_id = ? ORDER BY ts, id") catch return error.TraceDbUnavailable;
    defer conn.finalize(ev_stmt);
    db.bindInt(ev_stmt, 1, trace.order_id) catch return error.TraceBindFailed;

    while (db.c.sqlite3_step(ev_stmt) == db.c.SQLITE_ROW) {
        const payload = textCol(ev_stmt, 3);
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, payload, .{}) catch continue;
        defer parsed.deinit();

        var ev: TraceEvent = .{
            .ts = db.c.sqlite3_column_int64(ev_stmt, 0),
            .source = TraceEvent.dup(allocator, textCol(ev_stmt, 1)),
            .kind = TraceEvent.dup(allocator, textCol(ev_stmt, 2)),
            .task_id = "",
            .provider = "",
            .model = "",
            .key_label = "",
            .status = "",
            .error_name = "",
            .cause = "",
            .model_used = "",
            .file_path = "",
            .sample = "",
            .total_len = null,
            .closed = null,
            .exit_code = null,
        };
        // El evento se transfiere a `trace.events` al final del cuerpo; si el
        // append falla, liberarlo aquí. No hay errdefer en el cuerpo porque el
        // único retorno con error del bucle es precisamente ese append.
        if (parsed.value == .object) {
            const obj = parsed.value.object;
            inline for (STRING_SLOTS) |f| {
                if (obj.get(f)) |v| {
                    if (v == .string and v.string.len > 0) {
                        @field(ev, f) = TraceEvent.dup(allocator, v.string);
                    }
                }
            }
            if (obj.get("total_len")) |v| {
                if (v == .integer) ev.total_len = v.integer;
            }
            if (obj.get("closed")) |v| {
                if (v == .bool) ev.closed = v.bool;
            }
            if (obj.get("exit_code")) |v| {
                if (v == .integer) ev.exit_code = v.integer;
            }
        }

        trace.events.append(allocator, ev) catch {
            ev.deinit(allocator);
            return error.TraceOutOfMemory;
        };
    }

    return trace;
}

fn textCol(stmt: *db.c.sqlite3_stmt, col: c_int) []const u8 {
    const ptr = db.c.sqlite3_column_text(stmt, col) orelse return "";
    const len = db.c.sqlite3_column_bytes(stmt, col);
    return ptr[0..@intCast(len)];
}

/// Convierte la traza a texto plano legible. Es la misma función que imprime
/// el CLI, así que se prueba aquí con trazas fabricadas: es la unidad que no
/// debe romperse.
pub fn formatTrace(allocator: std.mem.Allocator, trace: *const OrderTrace) ![]u8 {
    return formatTraceOuter(allocator, trace, true);
}

/// Igual que `formatTrace` pero, salvo con `full=true`, SUPRIME los
/// `content_delta` (ruido de streaming) y deja una línea de recuento en su
/// lugar (B4). Medido en la orden 148: 164 de 476 líneas eran `content_delta`;
/// el comando existe para que los campos útiles (`total_len`, `closed`, la
/// muestra) sean alcanzables de un vistazo, y no después de scrollear la
/// corriente. `--full` los devuelve para quien quiera la traza íntegra.
/// Entrada del CLI: la traza MAS el contraste con el disco.
///
/// El contraste vive aqui y no en `formatTraceOuter` a proposito. `formatTrace` esta
/// documentado como «la unidad que no debe romperse», y lo es porque es PURO: recibe
/// una traza y devuelve texto. En cuanto le metí dentro una lectura del sistema de
/// archivos dejo de serlo, y un test que usaba la orden 200 empezo a fallar por una
/// carpeta `orden-200` que otra prueba habia dejado en disco. La funcion pura se queda
/// pura; quien mira el disco es el comando.
pub fn formatTraceOpt(allocator: std.mem.Allocator, trace: *const OrderTrace, full: bool) ![]u8 {
    const body = try formatTraceOuter(allocator, trace, full);
    const output = blk: {
        var con_disco = std.ArrayList(u8).empty;
        errdefer con_disco.deinit(allocator);
        con_disco.appendSlice(allocator, body) catch {
            break :blk body;
        };
        allocator.free(body);
        // Lo ultimo que se lee es lo que mas se recuerda, y esto es lo que impide
        // concluir «no entrego nada» sobre una orden que si entrego.
        appendDiskReconciliation(&con_disco, allocator, trace) catch {};
        break :blk try con_disco.toOwnedSlice(allocator);
    };
    // Sin full, añadir el recuento de deltas suprimidos en la cabecera, donde
    // no se puede perder entre la corriente.
    if (!full) {
        const suprimidos = countKind(trace, "content_delta");
        if (suprimidos > 0) {
            const linea = std.fmt.allocPrint(allocator, "\n{d} content_delta suprimidos (usa --full)\n", .{suprimidos}) catch "";
            defer if (linea.len > 0) allocator.free(linea);
            var encabezado = std.ArrayList(u8).empty;
            defer encabezado.deinit(allocator);
            try encabezado.appendSlice(allocator, output);
            try encabezado.appendSlice(allocator, linea);
            allocator.free(output);
            return encabezado.toOwnedSlice(allocator);
        }
    }
    return output;
}

fn countKind(trace: *const OrderTrace, kind: []const u8) usize {
    var n: usize = 0;
    for (trace.events.items) |ev| {
        if (std.mem.eql(u8, ev.kind, kind)) n += 1;
    }
    return n;
}

fn formatTraceOuter(allocator: std.mem.Allocator, trace: *const OrderTrace, full: bool) ![]u8 {
    var out = std.ArrayList(u8).empty;
    errdefer out.deinit(allocator);

    try out.appendSlice(allocator, "== Orden ");
    try appendInt(&out, allocator, trace.order_id);
    try out.appendSlice(allocator, " ==\n");
    try out.appendSlice(allocator, "estado: ");
    try out.appendSlice(allocator, trace.status);
    try out.appendSlice(allocator, "\nprompt: ");
    try out.appendSlice(allocator, trace.user_prompt);
    try out.appendSlice(allocator, "\ncreada: ");
    try appendInt(&out, allocator, trace.created_at);
    try out.appendSlice(allocator, "\neventos: ");
    try appendInt(&out, allocator, trace.events.items.len);
    try out.appendSlice(allocator, "\n");

    const base_ms = trace.created_at * 1000;
    for (trace.events.items) |ev| {
        // B4: la corriente de streaming se salta por defecto (una línea de
        // recuento ya anuncia cuántos se ocultaron). Todo lo demás se imprime.
        if (!full and std.mem.eql(u8, ev.kind, "content_delta")) continue;
        const rel_ms = ev.ts - base_ms;
        try out.appendSlice(allocator, "\n[");
        try out.appendSlice(allocator, ev.kind);
        try out.appendSlice(allocator, "] ");
        try out.appendSlice(allocator, ev.source);
        if (rel_ms != 0) {
            try out.appendSlice(allocator, " +");
            try appendInt(&out, allocator, rel_ms);
            try out.appendSlice(allocator, "ms");
        }
        try out.appendSlice(allocator, "\n");

        try field(&out, allocator, "task_id", ev.task_id);
        try field(&out, allocator, "provider", ev.provider);
        try field(&out, allocator, "model", ev.model);
        try field(&out, allocator, "key_label", ev.key_label);
        try field(&out, allocator, "status", ev.status);
        try field(&out, allocator, "error_name", ev.error_name);
        try field(&out, allocator, "cause", ev.cause);
        try field(&out, allocator, "model_used", ev.model_used);
        try field(&out, allocator, "file_path", ev.file_path);
        if (ev.total_len) |tl| {
            try out.appendSlice(allocator, "  total_len: ");
            try appendInt(&out, allocator, tl);
            try out.appendSlice(allocator, "\n");
        }
        if (ev.closed) |cl| {
            try out.appendSlice(allocator, "  closed: ");
            if (cl) try out.appendSlice(allocator, "true") else try out.appendSlice(allocator, "false");
            try out.appendSlice(allocator, "\n");
        }
        if (ev.exit_code) |ec| {
            try out.appendSlice(allocator, "  exit_code: ");
            try appendInt(&out, allocator, ec);
            try out.appendSlice(allocator, "\n");
        }
        // La muestra íntegra, SIN recortar aquí: si el propio depurador la
        // volviera a cortar, la orden 148 se repetiría dentro del diagnóstico.
        if (ev.sample.len > 0) {
            try out.appendSlice(allocator, "  sample (");
            try appendInt(&out, allocator, ev.sample.len);
            try out.appendSlice(allocator, " bytes):\n");
            try out.appendSlice(allocator, ev.sample);
            try out.appendSlice(allocator, "\n");
        }
    }

    return out.toOwnedSlice(allocator);
}

fn field(out: *std.ArrayList(u8), allocator: std.mem.Allocator, name: []const u8, value: []const u8) !void {
    if (value.len == 0) return;
    try out.appendSlice(allocator, "  ");
    try out.appendSlice(allocator, name);
    try out.appendSlice(allocator, ": ");
    try out.appendSlice(allocator, value);
    try out.appendSlice(allocator, "\n");
}

fn appendInt(out: *std.ArrayList(u8), allocator: std.mem.Allocator, n: anytype) !void {
    var buf: [32]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return error.Overflow;
    try out.appendSlice(allocator, s);
}

// ── Contraste con el DISCO ─────────────────────────────────────────────

/// Anexa a la traza lo que hay REALMENTE en `orden-<id>/`, y senala las
/// discrepancias con lo que los eventos dicen.
///
/// Nace de un fallo concreto: las ordenes #201 y #202 del 2026-08-11 cerraron en
/// `done` sin un solo evento `file_written`, con un `index.html` de 234 bytes
/// perfectamente escrito en disco. Quien inspecciono la traza —una IA auditora, y
/// tambien yo— concluyo «no entrego nada», y las dos veces era falso. La traza es
/// lo que el motor CUENTA; el disco es lo que el motor HIZO. Cuando no coinciden,
/// el que manda es el disco, y el desajuste es en si mismo un defecto que hay que
/// ver sin tener que ir a mirar la carpeta a mano.
///
/// Nunca falla: si no se puede leer la carpeta, se dice y se sigue. Un comando de
/// diagnostico que revienta es peor que uno incompleto.
fn appendDiskReconciliation(
    out: *std.ArrayList(u8),
    allocator: std.mem.Allocator,
    trace: *const OrderTrace,
) !void {
    // La carpeta no se adivina: si algún evento dice dónde escribió, ESA es la
    // carpeta. Solo cuando no hay ninguno se cae al workspace calculado, que es
    // lo que el CLI puede deducir por su cuenta.
    var dir_de_evento: ?[]const u8 = null;
    for (trace.events.items) |ev| {
        if (!std.mem.eql(u8, ev.kind, "file_written")) continue;
        if (ev.file_path.len == 0) continue;
        dir_de_evento = std.fs.path.dirname(ev.file_path);
        if (dir_de_evento != null) break;
    }

    const files = (if (dir_de_evento) |d|
        workspace.listOrderFilesIn(allocator, d)
    else
        workspace.listOrderFiles(allocator, trace.order_id)) catch {
        try out.appendSlice(allocator, "\n== Archivos en disco ==\n  (no se pudo leer la carpeta de la orden)\n");
        return;
    };
    defer {
        for (files) |f| f.deinit(allocator);
        allocator.free(files);
    }

    // Rutas anunciadas por los eventos `file_written`, reducidas a su basename.
    var anunciados = std.ArrayList([]const u8).empty;
    defer anunciados.deinit(allocator);
    for (trace.events.items) |ev| {
        if (!std.mem.eql(u8, ev.kind, "file_written")) continue;
        if (ev.file_path.len == 0) continue;
        try anunciados.append(allocator, std.fs.path.basename(ev.file_path));
    }

    if (files.len == 0 and anunciados.items.len == 0) return;

    try out.appendSlice(allocator, "\n== Archivos en disco (orden-");
    try appendInt(out, allocator, trace.order_id);
    try out.appendSlice(allocator, ") ==\n");

    if (files.len == 0) {
        try out.appendSlice(allocator, "  (ninguno)\n");
    }
    for (files) |f| {
        try out.appendSlice(allocator, "  ");
        try out.appendSlice(allocator, f.name);
        try out.appendSlice(allocator, " (");
        try appendInt(out, allocator, f.size);
        try out.appendSlice(allocator, " B)");
        var anunciado = false;
        for (anunciados.items) |a| {
            if (std.ascii.eqlIgnoreCase(a, f.name)) {
                anunciado = true;
                break;
            }
        }
        if (!anunciado) {
            try out.appendSlice(allocator, "   <-- ESCRITO PERO NO ANUNCIADO (sin evento file_written)");
        }
        try out.appendSlice(allocator, "\n");
    }

    // Al reves: un evento que promete un archivo que no esta.
    for (anunciados.items) |a| {
        var existe = false;
        for (files) |f| {
            if (std.ascii.eqlIgnoreCase(a, f.name)) {
                existe = true;
                break;
            }
        }
        if (!existe) {
            try out.appendSlice(allocator, "  ");
            try out.appendSlice(allocator, a);
            try out.appendSlice(allocator, "   <-- ANUNCIADO PERO NO ESTA EN DISCO\n");
        }
    }

    // Y el desajuste que mas confunde a quien inspecciona: la orden dice que no
    // termino, pero el trabajo esta hecho.
    const terminal_malo = std.mem.eql(u8, trace.status, "failed") or
        std.mem.eql(u8, trace.status, "cancelled");
    if (terminal_malo and files.len > 0) {
        try out.appendSlice(allocator, "\n  OJO: la orden figura '");
        try out.appendSlice(allocator, trace.status);
        try out.appendSlice(allocator, "' y sin embargo hay ");
        try appendInt(out, allocator, files.len);
        try out.appendSlice(allocator, " archivo(s) en disco. Antes de darla por perdida, abrelos.\n");
    }
}

fn insertEvent(conn: db.Connection, ts: i64, kind: []const u8, payload: []const u8, order_id: i64) !void {
    const stmt = try conn.prepare("INSERT INTO events (ts, source, kind, payload_json, order_id) VALUES (?, 'live_worker', ?, ?, ?)");
    defer conn.finalize(stmt);
    try db.bindInt(stmt, 1, ts);
    try db.bindText(stmt, 2, kind);
    try db.bindText(stmt, 3, payload);
    try db.bindInt(stmt, 4, order_id);
    _ = db.c.sqlite3_step(stmt);
}

test "trace: imprime la traza completa de la orden 148 (el caso real)" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (148, 'p', 'crea una calculadora', 'failed', 1000)");

    // Payload que replica el inciso real de la orden 148: el modelo contestó un
    // objeto suelto, total_len=6788, closed=true, y la muestra es completa.
    const sample = "{\"field\":\"source\",\"content\":\"import tkinter\\nprint('hola')\"}";
    var payload_w: std.Io.Writer.Allocating = .init(allocator);
    defer payload_w.deinit();
    {
        var js: std.json.Stringify = .{ .writer = &payload_w.writer, .options = .{} };
        try js.beginObject();
        try js.objectField("task_id");
        try js.write("t1");
        try js.objectField("provider");
        try js.write("Cohere");
        try js.objectField("model");
        try js.write("north-mini-code-1-0");
        try js.objectField("status");
        try js.write("empty");
        try js.objectField("key_label");
        try js.write("COHERE_01");
        try js.objectField("error_name");
        try js.write("ParseFailed");
        try js.objectField("sample");
        try js.write(sample);
        try js.objectField("total_len");
        try js.write(@as(i64, 6788));
        try js.objectField("closed");
        try js.write(true);
        try js.endObject();
    }
    try insertEvent(conn, 1500, "task_provider_failed", payload_w.written(), 148);
    try insertEvent(conn, 1600, "order_failed", "{\"cause\":\"execution_failed\"}", 148);

    var trace = try loadTrace(allocator, conn, 148);
    defer trace.deinit();

    try std.testing.expectEqual(@as(i64, 148), trace.order_id);
    try std.testing.expectEqualStrings("failed", trace.status);
    try std.testing.expectEqual(@as(usize, 2), trace.events.items.len);

    const txt = try formatTrace(allocator, &trace);
    defer allocator.free(txt);
    try std.testing.expect(std.mem.indexOf(u8, txt, "== Orden 148 ==") != null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "provider: Cohere") != null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "model: north-mini-code-1-0") != null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "key_label: COHERE_01") != null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "total_len: 6788") != null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "closed: true") != null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "error_name: ParseFailed") != null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "cause: execution_failed") != null);
    // La muestra aparece íntegra, incluido el final (el recorte de 600 era el bug).
    try std.testing.expect(std.mem.indexOf(u8, txt, sample) != null);
    try std.testing.expect(std.mem.lastIndexOf(u8, txt, "print('hola')") != null);
}

test "trace: la muestra larga se imprime completa, sin volver a recortarla" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (200, 'p', 'p', 'failed', 1000)");

    // 3000 letras repetidas: el depurador debe volcar TODO, no los primeros 600.
    var long = std.ArrayList(u8).empty;
    defer long.deinit(allocator);
    var i: usize = 0;
    while (i < 3000) : (i += 1) {
        try long.append(allocator, 'x');
    }
    var payload_w: std.Io.Writer.Allocating = .init(allocator);
    defer payload_w.deinit();
    {
        var js: std.json.Stringify = .{ .writer = &payload_w.writer, .options = .{} };
        try js.beginObject();
        try js.objectField("sample");
        try js.write(long.items);
        try js.objectField("total_len");
        try js.write(@as(i64, 3000));
        try js.endObject();
    }
    try insertEvent(conn, 1500, "task_provider_failed", payload_w.written(), 200);

    var trace = try loadTrace(allocator, conn, 200);
    defer trace.deinit();
    const txt = try formatTrace(allocator, &trace);
    defer allocator.free(txt);
    // "sample (3000 bytes)" certifica que el formateador recibió el tamaño real.
    try std.testing.expect(std.mem.indexOf(u8, txt, "sample (3000 bytes)") != null);
    var count: usize = 0;
    for (txt) |c| {
        if (c == 'x') count += 1;
    }
    try std.testing.expectEqual(@as(usize, 3000), count);
}

test "B4: la traza por defecto omite content_delta y anuncia cuantos suprimio" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (300, 'p', 'p', 'failed', 1000)");

    // Orden 148 medida: 476 lineas, 164 de ellas content_delta. Aqui se replica
    // la forma: 3 deltas de streaming + 1 evento util en medio.
    try insertEvent(conn, 1500, "content_delta", "{\"content\":\"\"}", 300);
    try insertEvent(conn, 1501, "provider_failed", "{\"provider\":\"X\",\"total_len\":0,\"status\":\"empty\"}", 300);
    try insertEvent(conn, 1502, "content_delta", "{\"content\":\"texto\"}", 300);
    try insertEvent(conn, 1503, "content_delta", "{\"content\":\"mas\"}", 300);
    try insertEvent(conn, 1504, "order_failed", "{\"cause\":\"all_tasks_failed\"}", 300);

    var trace = try loadTrace(allocator, conn, 300);
    defer trace.deinit();

    const without_full = try formatTraceOpt(allocator, &trace, false);
    defer allocator.free(without_full);
    try std.testing.expect(std.mem.indexOf(u8, without_full, "3 content_delta suprimidos (usa --full)") != null);
    // Los deltas en si NO aparecen.
    try std.testing.expect(std.mem.indexOf(u8, without_full, "[content_delta]") == null);
    // Lo util sigue visible.
    try std.testing.expect(std.mem.indexOf(u8, without_full, "[provider_failed]") != null);
    try std.testing.expect(std.mem.indexOf(u8, without_full, "[order_failed]") != null);
    try std.testing.expect(std.mem.indexOf(u8, without_full, "cause: all_tasks_failed") != null);

    const with_full = try formatTraceOpt(allocator, &trace, true);
    defer allocator.free(with_full);
    try std.testing.expect(std.mem.indexOf(u8, with_full, "[content_delta]") != null);
    // Con --full no hay linea de suprimidos.
    try std.testing.expect(std.mem.indexOf(u8, with_full, "content_delta suprimidos") == null);
}

test "B4: sin deltas no hay linea de suprimidos" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);
    try conn.exec("INSERT INTO orders (id, project_id, user_prompt, status, created_at) VALUES (301, 'p', 'p', 'done', 1000)");
    try insertEvent(conn, 1500, "order_done", "{\"completed\":1}", 301);

    var trace = try loadTrace(allocator, conn, 301);
    defer trace.deinit();
    const txt = try formatTraceOpt(allocator, &trace, false);
    defer allocator.free(txt);
    try std.testing.expect(std.mem.indexOf(u8, txt, "content_delta suprimidos") == null);
    try std.testing.expect(std.mem.indexOf(u8, txt, "[order_done]") != null);
}

test "trace: numero de orden inexistente da OrderNotFound y vacio da noorders" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    try std.testing.expectError(error.OrderNotFound, loadTrace(allocator, conn, 999));
    try std.testing.expectError(error.NoOrdersYet, loadTrace(allocator, conn, null));
}

// ── El contraste con el disco (ordenes #201 y #202) ────────────────────

const workspace_test_planner = @import("planner.zig");
const workspace_test_worker = @import("worker_backend.zig");

/// Deja un archivo real en la carpeta de una orden y devuelve su ruta.
fn seedOrderFile(allocator: std.mem.Allocator, order_id: i64, body: []const u8) ![]const u8 {
    const arts = [_]workspace_test_worker.Artifact{.{ .path = "index.html", .content = body }};
    const task = workspace_test_planner.PlannedTask{
        .id = "t1",
        .task_type = .programar,
        .department = "programacion",
        .description = "una web",
        .contract_fields = &.{},
        .depends_on = &.{},
    };
    const paths = (try workspace.persistTaskFiles(allocator, order_id, task, &arts)) orelse return error.NoFile;
    defer allocator.free(paths);
    for (paths[1..]) |extra| allocator.free(extra);
    return paths[0];
}

fn borrarArchivo(allocator: std.mem.Allocator, path: []const u8) void {
    const z = allocator.dupeZ(u8, path) catch return;
    defer allocator.free(z);
    _ = workspace.deleteFileForTest(z.ptr);
}

test "TRAZA-DISCO: un archivo escrito SIN evento se delata" {
    const allocator = std.testing.allocator;
    const saved = try seedOrderFile(allocator, 99910, "<!DOCTYPE html><html><body>hola</body></html>\n");
    defer allocator.free(saved);
    defer borrarArchivo(allocator, saved);

    // Traza de la orden #201: `done`, y ningun evento file_written.
    var trace = OrderTrace{
        .order_id = 99910,
        .status = try allocator.dupe(u8, "done"),
        .user_prompt = try allocator.dupe(u8, "crea una web"),
        .created_at = 0,
        .allocator = allocator,
    };
    defer trace.deinit();

    const salida = try formatTraceOpt(allocator, &trace, true);
    defer allocator.free(salida);

    try std.testing.expect(std.mem.indexOf(u8, salida, "index.html") != null);
    try std.testing.expect(std.mem.indexOf(u8, salida, "ESCRITO PERO NO ANUNCIADO") != null);
}

test "TRAZA-DISCO: una orden fallida CON archivos avisa de que no se den por perdidos" {
    const allocator = std.testing.allocator;
    const saved = try seedOrderFile(allocator, 99911, "<!DOCTYPE html><html><body>hola</body></html>\n");
    defer allocator.free(saved);
    defer borrarArchivo(allocator, saved);

    var trace = OrderTrace{
        .order_id = 99911,
        .status = try allocator.dupe(u8, "failed"),
        .user_prompt = try allocator.dupe(u8, "crea una web"),
        .created_at = 0,
        .allocator = allocator,
    };
    defer trace.deinit();

    const salida = try formatTraceOpt(allocator, &trace, true);
    defer allocator.free(salida);

    try std.testing.expect(std.mem.indexOf(u8, salida, "OJO: la orden figura 'failed'") != null);
    try std.testing.expect(std.mem.indexOf(u8, salida, "archivo(s) en disco") != null);
}

test "TRAZA-DISCO: una orden sin archivos ni eventos no anade ruido" {
    const allocator = std.testing.allocator;
    var trace = OrderTrace{
        .order_id = 99912345,
        .status = try allocator.dupe(u8, "done"),
        .user_prompt = try allocator.dupe(u8, "hola"),
        .created_at = 0,
        .allocator = allocator,
    };
    defer trace.deinit();

    const salida = try formatTraceOpt(allocator, &trace, true);
    defer allocator.free(salida);
    try std.testing.expect(std.mem.indexOf(u8, salida, "Archivos en disco") == null);
}
