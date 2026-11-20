//! Presupuesto duro de llamadas de pago (BUDGET-1).
//!
//! ## Qué problema resuelve
//!
//! `governance_mode = free_tier_first` ya impide una llamada de pago cuando está
//! puesto. Pero la política del propietario —«no hay presupuesto de pago autorizado»—
//! dependía de que ese ajuste estuviera en el modo correcto: en `hybrid`, un
//! modelo de pago se llamaba sin que nadie hubiera autorizado gastar. El informe
//! de consolidación lo dejó escrito como pendiente: «presupuesto monetario duro
//! pendiente».
//!
//! Aquí el criterio es al revés y no depende del modo: **una llamada a un modelo
//! que no está clasificado como gratuito necesita autorización explícita**. Sin
//! autorización, se rechaza ANTES de enviar nada, en cualquier rol (coordinador,
//! ejecutor, auditor, corrector) y en cualquier reintento.
//!
//! ## Por qué se cuentan llamadas y no dólares
//!
//! El catálogo NO persiste el precio por token de cada modelo: `discoverFromJson`
//! usa el precio sólo para deducir `is_free` y lo descarta. Sin esa columna, un
//! «presupuesto en dólares» sería un número inventado, y un número inventado en
//! una pantalla de gasto es peor que no tener presupuesto.
//!
//! Así que lo autorizado se cuenta en LLAMADAS DE PAGO, que es lo que el motor
//! sí puede contar con exactitud, y se llama por su nombre en el evento y en la
//! interfaz. Cuando el catálogo guarde precios, este módulo es donde se añade el
//! cargo real; el gate —comprobar antes de enviar— ya no habrá que moverlo.
//!
//! Valor por defecto: CERO. Un motor recién instalado no gasta dinero de nadie
//! sin que alguien lo diga primero.

const std = @import("std");
const db = @import("db.zig");

/// Clave del ajuste con las llamadas de pago autorizadas para la instalación.
pub const KEY_AUTHORIZED = "paid_calls_authorized";

/// Clave del contador de llamadas de pago ya consumidas.
pub const KEY_SPENT = "paid_calls_spent";

pub const Decision = enum {
    /// El modelo es gratuito: no consume autorización.
    gratuito,
    /// Es de pago y queda autorización. La llamada puede salir.
    autorizado,
    /// Es de pago y NO hay autorización disponible. No se envía nada.
    denegado,
};

pub const Estado = struct {
    autorizadas: u64,
    consumidas: u64,

    pub fn restantes(self: Estado) u64 {
        return if (self.consumidas >= self.autorizadas) 0 else self.autorizadas - self.consumidas;
    }
};

fn leerEntero(conn: db.Connection, key: []const u8) u64 {
    const stmt = conn.prepare("SELECT value FROM settings WHERE key=?") catch return 0;
    defer conn.finalize(stmt);
    db.bindText(stmt, 1, key) catch return 0;
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return 0;
    const ptr = db.c.sqlite3_column_text(stmt, 0) orelse return 0;
    const text = ptr[0..std.mem.len(ptr)];
    return std.fmt.parseInt(u64, std.mem.trim(u8, text, " \t\r\n"), 10) catch 0;
}

fn escribirEntero(conn: db.Connection, key: []const u8, value: u64) !void {
    if (value > std.math.maxInt(i64)) return error.BudgetValueOutOfRange;
    var buf: [24]u8 = undefined;
    const text = try std.fmt.bufPrint(&buf, "{d}", .{value});
    const stmt = try conn.prepare("INSERT INTO settings(key, value) VALUES(?, ?) ON CONFLICT(key) DO UPDATE SET value=excluded.value");
    defer conn.finalize(stmt);
    try db.bindText(stmt, 1, key);
    try db.bindText(stmt, 2, text);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.BudgetStorageFailed;
}

/// Estado actual del presupuesto. Ausente en `settings` = cero autorizado.
pub fn estado(conn: db.Connection) Estado {
    return .{
        .autorizadas = leerEntero(conn, KEY_AUTHORIZED),
        .consumidas = leerEntero(conn, KEY_SPENT),
    };
}

/// Autoriza N llamadas de pago. `0` revoca la autorización.
pub fn autorizar(conn: db.Connection, llamadas: u64) !void {
    try escribirEntero(conn, KEY_AUTHORIZED, llamadas);
}

/// Reinicia el contador de consumo. Se usa al empezar un presupuesto nuevo, no
/// para tapar lo ya gastado: el evento de cada consumo queda en la traza.
pub fn reiniciarConsumo(conn: db.Connection) !void {
    try escribirEntero(conn, KEY_SPENT, 0);
}

/// Lectura orientativa para preflight. NO autoriza un envío; usar reservar.
///
/// `es_gratuito` lo decide quien llama con la clasificación efectiva por modelo
/// (`model_router.catalogModelIsFree`), no con el flag heredado del proveedor:
/// ese flag marcaba gratis los 55 modelos premium de OpenCode.
pub fn decidir(conn: db.Connection, es_gratuito: bool) Decision {
    if (es_gratuito) return .gratuito;
    const st = estado(conn);
    return if (st.restantes() > 0) .autorizado else .denegado;
}

/// Reserva ANTES del envío con un único DML condicional. RETURNING pertenece
/// a esta sentencia (sqlite3_changes sería vulnerable a otro usuario del mismo
/// handle). El segundo step comprueba la finalización/commit antes de autorizar.
/// El UPSERT cubre el contador aún ausente, sin una inicialización separada.
pub fn reservar(conn: db.Connection, es_gratuito: bool) !Decision {
    if (es_gratuito) return .gratuito;
    const stmt = conn.prepare(
        "INSERT INTO settings(key,value) SELECT 'paid_calls_spent', '1' " ++
            "WHERE COALESCE((SELECT CAST(value AS INTEGER) FROM settings WHERE key='paid_calls_authorized'),0) > 0 " ++
            "ON CONFLICT(key) DO UPDATE SET value=CAST(settings.value AS INTEGER)+1 " ++
            "WHERE CAST(settings.value AS INTEGER) >= 0 AND CAST(settings.value AS INTEGER) < " ++
            "(SELECT CAST(value AS INTEGER) FROM settings WHERE key='paid_calls_authorized') RETURNING value",
    ) catch return error.BudgetStorageFailed;
    defer conn.finalize(stmt);
    const rc = db.c.sqlite3_step(stmt);
    if (rc == db.c.SQLITE_DONE) return .denegado;
    if (rc != db.c.SQLITE_ROW) return error.BudgetStorageFailed;
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.BudgetStorageFailed;
    return .autorizado;
}

/// Solo cuando el llamador sabe que no inició ningún despacho (spawn fallido).
/// Un error de transporte no acredita ausencia de envío y no devuelve cupo.
pub fn devolverSinEnvio(conn: db.Connection) !void {
    const stmt = try conn.prepare("UPDATE settings SET value=CAST(value AS INTEGER)-1 WHERE key='paid_calls_spent' AND CAST(value AS INTEGER)>0 RETURNING value");
    defer conn.finalize(stmt);
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_ROW) return error.BudgetStorageFailed;
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.BudgetStorageFailed;
}

/// Texto del rechazo, para el evento y para el usuario. Dice qué falta y quién
/// puede darlo, en vez de «bloqueado» a secas.
pub fn motivoDenegacion(allocator: std.mem.Allocator, provider: []const u8, model: []const u8, st: Estado) ![]u8 {
    return std.fmt.allocPrint(
        allocator,
        "cupo agotado: {d} de {d} llamadas de pago autorizadas usadas ({s}/{s}). No se envio la solicitud. Autoriza mas llamadas en Configuracion > Gobernanza o cambia a gratis/suscripcion.",
        .{ st.consumidas, st.autorizadas, provider, model },
    );
}

// ── Pruebas ────────────────────────────────────────────────────────────

fn abrirMemoria() !db.Connection {
    var conn = try db.Connection.open(std.testing.allocator, ":memory:");
    errdefer conn.close();
    const stmt = try conn.prepare("CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT)");
    defer conn.finalize(stmt);
    _ = db.c.sqlite3_step(stmt);
    return conn;
}

test "BUDGET-1: por defecto NO hay presupuesto y una llamada de pago se rechaza" {
    var conn = try abrirMemoria();
    defer conn.close();
    try std.testing.expectEqual(Decision.denegado, decidir(conn, false));
    // Un modelo gratuito no necesita autorización de nadie.
    try std.testing.expectEqual(Decision.gratuito, decidir(conn, true));
    const st = estado(conn);
    try std.testing.expectEqual(@as(u64, 0), st.autorizadas);
    try std.testing.expectEqual(@as(u64, 0), st.restantes());
}

test "BUDGET-1: lo autorizado se consume llamada a llamada y el gate se cierra solo" {
    var conn = try abrirMemoria();
    defer conn.close();
    try autorizar(conn, 2);
    try std.testing.expectEqual(Decision.autorizado, decidir(conn, false));
    try std.testing.expectEqual(Decision.autorizado, try reservar(conn, false));
    try std.testing.expectEqual(@as(u64, 1), estado(conn).restantes());
    try std.testing.expectEqual(Decision.autorizado, decidir(conn, false));
    try std.testing.expectEqual(Decision.autorizado, try reservar(conn, false));
    // El reintento posterior ya no sale: el gate va antes de CADA llamada.
    try std.testing.expectEqual(Decision.denegado, decidir(conn, false));
    try std.testing.expectEqual(@as(u64, 0), estado(conn).restantes());
}

test "BUDGET-1: revocar la autorizacion cierra el gate aunque quedaran llamadas" {
    var conn = try abrirMemoria();
    defer conn.close();
    try autorizar(conn, 5);
    try std.testing.expectEqual(Decision.autorizado, decidir(conn, false));
    try autorizar(conn, 0);
    try std.testing.expectEqual(Decision.denegado, decidir(conn, false));
    // Lo gratuito sigue pasando: revocar el gasto no apaga el motor.
    try std.testing.expectEqual(Decision.gratuito, decidir(conn, true));
}

test "BUDGET-1: el consumo sobrevive a reabrir el estado y solo se reinicia a peticion" {
    var conn = try abrirMemoria();
    defer conn.close();
    try autorizar(conn, 3);
    _ = try reservar(conn, false);
    _ = try reservar(conn, false);
    try std.testing.expectEqual(@as(u64, 2), estado(conn).consumidas);
    try reiniciarConsumo(conn);
    try std.testing.expectEqual(@as(u64, 0), estado(conn).consumidas);
    try std.testing.expectEqual(@as(u64, 3), estado(conn).restantes());
}

test "BUDGET-1: el rechazo nombra el modelo y lo que falta" {
    const allocator = std.testing.allocator;
    const texto = try motivoDenegacion(allocator, "OpenCode", "gpt-5.5-pro", .{ .autorizadas = 0, .consumidas = 0 });
    defer allocator.free(texto);
    try std.testing.expect(std.mem.indexOf(u8, texto, "OpenCode/gpt-5.5-pro") != null);
    try std.testing.expect(std.mem.indexOf(u8, texto, "No se envio la solicitud") != null);
}

test "ORDENES R2 exhausted reason includes exact 200 of 200 and remaining" {
    const a = std.testing.allocator;
    const reason = try motivoDenegacion(a, "OpenCode", "gpt-6-luna", .{ .autorizadas = 200, .consumidas = 200 });
    defer a.free(reason);
    try std.testing.expect(std.mem.indexOf(u8, reason, "cupo agotado: 200 de 200 llamadas de pago autorizadas usadas") != null);
}

test "ORDENES R3 concurrent last paid slot authorizes exactly one sender" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var root_buf: [std.fs.max_path_bytes]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &root_buf);
    const root = root_buf[0..root_len];
    const path = try std.fs.path.join(a, &.{ root, "budget.db" });
    defer a.free(path);
    var conn = try db.Connection.open(a, path);
    defer conn.close();
    try conn.exec("CREATE TABLE settings(key TEXT PRIMARY KEY, value TEXT)");
    try autorizar(conn, 1);
    const Race = struct {
        const Self = @This();
        conn: db.Connection,
        start: *std.atomic.Value(bool),
        sent: *std.atomic.Value(u32),
        errors: *std.atomic.Value(u32),
        fn run(self: *Self) void {
            while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
            const decision = reservar(self.conn, false) catch {
                _ = self.errors.fetchAdd(1, .monotonic);
                return;
            };
            if (decision == .autorizado) {
                _ = self.sent.fetchAdd(1, .monotonic);
            }
        }
    };
    var start = std.atomic.Value(bool).init(false);
    var sent = std.atomic.Value(u32).init(0);
    var errors = std.atomic.Value(u32).init(0);
    var calls: [16]Race = undefined;
    var threads: [16]std.Thread = undefined;
    var opened: usize = 0;
    var spawned: usize = 0;
    defer {
        start.store(true, .release);
        for (threads[0..spawned]) |thread| thread.join();
        for (calls[0..opened]) |*call| call.conn.close();
    }
    for (&calls) |*call| {
        call.* = .{ .conn = try db.Connection.open(std.heap.page_allocator, path), .start = &start, .sent = &sent, .errors = &errors };
        opened += 1;
    }
    for (&calls) |*call| {
        threads[spawned] = try std.Thread.spawn(.{}, Race.run, .{call});
        spawned += 1;
    }
    start.store(true, .release);
    for (threads[0..spawned]) |thread| thread.join();
    spawned = 0;
    std.debug.print("PAID_RACE calls=16 sends={d} errors={d} spent={d}\n", .{ sent.load(.acquire), errors.load(.acquire), estado(conn).consumidas });
    try std.testing.expectEqual(@as(u32, 0), errors.load(.acquire));
    try std.testing.expectEqual(@as(u32, 1), sent.load(.acquire));
    try std.testing.expectEqual(@as(u64, 1), estado(conn).consumidas);
}

test "ORDENES R3 reservation write failures authorize zero sends and refund only before dispatch" {
    var conn = try abrirMemoria();
    defer conn.close();
    try autorizar(conn, 1);
    try conn.exec("PRAGMA query_only=ON");
    try std.testing.expectError(error.BudgetStorageFailed, reservar(conn, false));
    try std.testing.expectError(error.BudgetStorageFailed, autorizar(conn, 2));
    try std.testing.expectError(error.BudgetStorageFailed, reiniciarConsumo(conn));
    try std.testing.expectEqual(Decision.gratuito, try reservar(conn, true));
    try conn.exec("PRAGMA query_only=OFF");
    try std.testing.expectEqual(Decision.autorizado, try reservar(conn, false));
    try std.testing.expectEqual(Decision.denegado, try reservar(conn, false));
    try conn.exec("PRAGMA query_only=ON");
    try std.testing.expectError(error.BudgetStorageFailed, devolverSinEnvio(conn));
    try conn.exec("PRAGMA query_only=OFF");
    try devolverSinEnvio(conn);
    try std.testing.expectEqual(@as(u64, 0), estado(conn).consumidas);
    try std.testing.expectError(error.BudgetStorageFailed, devolverSinEnvio(conn));
    try std.testing.expectError(error.BudgetValueOutOfRange, autorizar(conn, std.math.maxInt(u64)));
    try conn.exec("DROP TABLE settings");
    try std.testing.expectError(error.BudgetStorageFailed, reservar(conn, false));
    try std.testing.expectError(error.PrepareFailed, autorizar(conn, 1));
    try std.testing.expectError(error.PrepareFailed, reiniciarConsumo(conn));
    try std.testing.expectError(error.PrepareFailed, devolverSinEnvio(conn));
}
