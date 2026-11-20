//! D1 (H5) — banco aislado: una lectura de socket CON PLAZO que devuelve el hilo.
//!
//! ## Qué problema es este
//!
//! Cuando un proveedor acepta la conexión y luego calla, el hilo se queda dentro
//! de `recv` y no hay forma de sacarlo. De ahí sale una familia entera de
//! fallos ya documentados: hilos huérfanos, contención sobre `runtime.db`, el
//! handle de hilo que `callWithDeadline` filtra a propósito, y el assert del
//! pool de conexiones de `HttpClient.deinit`.
//!
//! ## Lo que YA está medido y no hay que volver a medir (2026-08-14/15)
//!
//! - `CancelIoEx` sobre el handle AFD despierta el `recv`… y hace saltar el
//!   `.CANCELLED => unreachable` de `std.Io.Threaded.netReadWindows`. Se gana el
//!   desbloqueo y se pierde el proceso.
//! - `shutdown` retorna en 0 ms y **no** despierta una lectura ya pendiente. El
//!   test `H5-MEDIDO` de `core/src/live_worker.zig` fija ese hecho: 60 s después
//!   el hilo seguía dentro.
//! - `Future.cancel` no tiene punto de cancelación en `netRead` de Windows.
//!
//! La conclusión de todo eso es una sola: **el problema no es cómo cancelar una
//! lectura bloqueada, sino no bloquearse.** Un socket en modo no bloqueante con
//! `WSAPoll` y plazo propio nunca entra en un estado del que haya que sacarlo.
//!
//! ## Qué es este archivo y qué NO es
//!
//! Es el **banco aislado** que pedía el primer paso de D1: sockets crudos de
//! Winsock, sin pasar por `std.Io`, contra un servidor que acepta y calla. Sirve
//! para responder una pregunta con número: *¿devuelve el hilo, y en cuánto?*
//!
//! **No toca el cliente HTTP real.** Eso es deliberado y está en el encargo: no
//! se toca `client.zig` hasta que el banco funcione. Lo que hay aquí es la
//! pieza; cablearla es el tramo siguiente.

const std = @import("std");
const builtin = @import("builtin");
const windows = std.os.windows;

pub const SOCKET = usize;
pub const INVALID_SOCKET: SOCKET = ~@as(usize, 0);
const SOCKET_ERROR: i32 = -1;
const AF_INET: i32 = 2;
const SOCK_STREAM: i32 = 1;
const IPPROTO_TCP: i32 = 6;
const FIONBIO: u32 = 0x8004667E;
const WSAEWOULDBLOCK: i32 = 10035;
const POLLRDNORM: i16 = 0x0100;
const POLLWRNORM: i16 = 0x0010;
const POLLERR: i16 = 0x0001;
const POLLHUP: i16 = 0x0002;
const POLLNVAL: i16 = 0x0004;

const sockaddr_in = extern struct {
    sin_family: u16,
    sin_port: u16,
    sin_addr: u32,
    sin_zero: [8]u8 = [_]u8{0} ** 8,
};

const WSAPOLLFD = extern struct {
    fd: SOCKET,
    events: i16,
    revents: i16,
};

const WSADATA = extern struct {
    wVersion: u16,
    wHighVersion: u16,
    iMaxSockets: u16,
    iMaxUdpDg: u16,
    lpVendorInfo: ?*u8,
    szDescription: [257]u8,
    szSystemStatus: [129]u8,
};

extern "ws2_32" fn WSAStartup(wVersionRequested: u16, lpWSAData: *WSADATA) callconv(.winapi) i32;
extern "ws2_32" fn socket(af: i32, type_: i32, protocol: i32) callconv(.winapi) SOCKET;
extern "ws2_32" fn connect(s: SOCKET, name: *const sockaddr_in, namelen: i32) callconv(.winapi) i32;
extern "ws2_32" fn recv(s: SOCKET, buf: [*]u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn send(s: SOCKET, buf: [*]const u8, len: i32, flags: i32) callconv(.winapi) i32;
extern "ws2_32" fn closesocket(s: SOCKET) callconv(.winapi) i32;
extern "ws2_32" fn ioctlsocket(s: SOCKET, cmd: u32, argp: *u32) callconv(.winapi) i32;
extern "ws2_32" fn WSAPoll(fdArray: [*]WSAPOLLFD, fds: u32, timeout: i32) callconv(.winapi) i32;
extern "ws2_32" fn WSAGetLastError() callconv(.winapi) i32;
extern "ws2_32" fn htons(hostshort: u16) callconv(.winapi) u16;
const GetTickCount64 = @import("../platform.zig").ticks;
const Sleep = @import("../platform.zig").sleep;

var wsa_iniciado = std.atomic.Value(bool).init(false);

/// Winsock exige `WSAStartup` una vez por proceso. Idempotente y sin candado:
/// llamarlo dos veces solo incrementa un contador interno del SO.
pub fn asegurarWinsock() void {
    if (wsa_iniciado.load(.acquire)) return;
    var data: WSADATA = undefined;
    _ = WSAStartup(0x0202, &data);
    wsa_iniciado.store(true, .release);
}

pub const ErrorPlazo = error{
    /// El plazo venció sin que llegara un solo byte. **Y el hilo volvió.**
    /// Ese «y el hilo volvió» es todo el punto de D1.
    Vencido,
    Conexion,
    Cerrado,
    Winsock,
};

/// Resultado de una lectura con plazo, con el tiempo REAL que costó.
///
/// El milisegundo medido no es adorno: sin él, «devolvió» y «devolvió a tiempo»
/// son indistinguibles, y la afirmación entera de D1 se queda sin comprobar.
pub const Lectura = struct {
    bytes: usize,
    ms: u64,
};

/// Socket TCP en modo NO BLOQUEANTE con plazo propio.
///
/// La diferencia con lo que hay hoy en `client.zig` no es de grado: aquí no hay
/// ninguna llamada bloqueante de la que haya que sacar a nadie. `WSAPoll` es el
/// único punto de espera, y lleva su propio plazo.
pub const SocketConPlazo = struct {
    s: SOCKET,

    pub fn conectar(ip_a: u8, ip_b: u8, ip_c: u8, ip_d: u8, puerto: u16) ErrorPlazo!SocketConPlazo {
        asegurarWinsock();
        const s = socket(AF_INET, SOCK_STREAM, IPPROTO_TCP);
        if (s == INVALID_SOCKET) return error.Winsock;
        errdefer _ = closesocket(s);

        const addr = sockaddr_in{
            .sin_family = @intCast(AF_INET),
            .sin_port = htons(puerto),
            // La dirección va en orden de red: a.b.c.d se empaqueta como
            // d<<24|c<<16|b<<8|a, que es lo que espera `sin_addr` en Windows.
            .sin_addr = (@as(u32, ip_d) << 24) | (@as(u32, ip_c) << 16) | (@as(u32, ip_b) << 8) | @as(u32, ip_a),
        };
        if (connect(s, &addr, @sizeOf(sockaddr_in)) == SOCKET_ERROR) return error.Conexion;

        // El modo no bloqueante se pone DESPUÉS de conectar: así el `connect`
        // sigue siendo simple y solo la lectura —que es la que cuelga— cambia
        // de régimen. Es lo mínimo que hace falta para responder la pregunta
        // de D1, y el banco tiene que aislar la variable, no cambiarlo todo.
        var modo: u32 = 1;
        if (ioctlsocket(s, FIONBIO, &modo) == SOCKET_ERROR) return error.Winsock;

        return .{ .s = s };
    }

    pub fn cerrar(self: *SocketConPlazo) void {
        if (self.s != INVALID_SOCKET) {
            _ = closesocket(self.s);
            self.s = INVALID_SOCKET;
        }
    }

    pub fn enviar(self: *SocketConPlazo, datos: []const u8) ErrorPlazo!usize {
        const n = send(self.s, datos.ptr, @intCast(datos.len), 0);
        if (n == SOCKET_ERROR) return error.Winsock;
        return @intCast(n);
    }

    /// Lee con plazo. Devuelve SIEMPRE en `plazo_ms` como mucho.
    ///
    /// `cancelado` permite cortar antes de que venza el plazo sin tocar el
    /// socket desde otro hilo: se consulta entre vueltas. Cancelar así no tiene
    /// nada que sacar de ningún sitio, que es justo lo que hacía imposible
    /// `CancelIoEx`.
    pub fn leerConPlazo(
        self: *SocketConPlazo,
        buf: []u8,
        plazo_ms: u32,
        cancelado: ?*const std.atomic.Value(bool),
    ) ErrorPlazo!Lectura {
        const t0 = GetTickCount64();
        // Se sondea a trozos para poder mirar la bandera de cancelación. 50 ms
        // es corto para reaccionar y largo para no convertir la espera en una
        // espera activa.
        const TROZO_MS: i32 = 50;

        while (true) {
            if (cancelado) |c| {
                if (c.load(.acquire)) return error.Vencido;
            }
            const transcurrido = GetTickCount64() - t0;
            if (transcurrido >= plazo_ms) return error.Vencido;

            const restante: i32 = @intCast(@min(@as(u64, plazo_ms) - transcurrido, @as(u64, @intCast(TROZO_MS))));
            var fds = [_]WSAPOLLFD{.{ .fd = self.s, .events = POLLRDNORM, .revents = 0 }};
            const r = WSAPoll(&fds, 1, restante);
            if (r == SOCKET_ERROR) return error.Winsock;
            if (r == 0) continue; // nada todavía; se vuelve a mirar el reloj

            if ((fds[0].revents & (POLLERR | POLLNVAL)) != 0) return error.Winsock;
            if ((fds[0].revents & POLLRDNORM) == 0 and (fds[0].revents & POLLHUP) != 0) return error.Cerrado;

            const n = recv(self.s, buf.ptr, @intCast(buf.len), 0);
            if (n == SOCKET_ERROR) {
                if (WSAGetLastError() == WSAEWOULDBLOCK) continue;
                return error.Winsock;
            }
            if (n == 0) return error.Cerrado;
            return .{ .bytes = @intCast(n), .ms = GetTickCount64() - t0 };
        }
    }
};

// ── Banco de pruebas ───────────────────────────────────────────────────

const CtxSordo = struct {
    puerto: u16 = 0,
    listo: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    parar: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Si es true, el servidor contesta algo al conectarse en vez de callar.
    hablador: bool = false,
    io: std.Io,
};

/// El mismo `servidorSordo` que `live_worker.zig`: acepta y no contesta jamás.
/// Se replica aquí a propósito — el banco tiene que ser autónomo, y hacer que
/// `providers` dependa de `core` para un test invertiría la dirección de las
/// capas.
fn servidorSordo(ctx: *CtxSordo) void {
    // Puerto efímero: los rangos fijos chocan con las reservas dinámicas de
    // Windows (Hyper-V/WSL) en máquinas compartidas y runners de CI.
    var addr = std.Io.net.IpAddress.parse("127.0.0.1", 0) catch return;
    var server = std.Io.net.IpAddress.listen(&addr, ctx.io, .{}) catch return;
    defer server.deinit(ctx.io);
    ctx.puerto = server.socket.address.getPort();
    ctx.listo.store(true, .release);

    var stream = server.accept(ctx.io) catch return;
    if (ctx.hablador) {
        var w = stream.writer(ctx.io, &.{});
        _ = w.interface.write("HOLA") catch {};
        w.interface.flush() catch {};
    }
    while (!ctx.parar.load(.acquire)) Sleep(10);
    stream.close(ctx.io);
}

fn arrancarSordo(hablador: bool, io: std.Io) !?struct { ctx: *CtxSordo, hilo: std.Thread } {
    const ctx = try std.testing.allocator.create(CtxSordo);
    ctx.* = .{ .io = io, .hablador = hablador };
    const hilo = try std.Thread.spawn(.{}, servidorSordo, .{ctx});
    var espera: usize = 0;
    while (!ctx.listo.load(.acquire) and espera < 400) : (espera += 1) Sleep(5);
    if (!ctx.listo.load(.acquire) or ctx.puerto == 0) {
        ctx.parar.store(true, .release);
        hilo.join();
        std.testing.allocator.destroy(ctx);
        return null;
    }
    return .{ .ctx = ctx, .hilo = hilo };
}

test "D1: contra un servidor que acepta y calla, la lectura DEVUELVE el hilo" {
    // La pregunta de D1, con número. Hoy, en el cliente real, esto se queda
    // dentro de `recv` para siempre: el test `H5-MEDIDO` de live_worker.zig lo
    // fija tras 60 s de espera. Aquí el plazo es de 400 ms y el hilo vuelve.
    if (builtin.os.tag != .windows) return @import("../platform.zig").skip("T9: el sondeo de socket usa Winsock (WSAPoll); omitida en Linux");

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const arranque = (try arrancarSordo(false, threaded.io())) orelse return error.SkipZigTest;
    const ctx = arranque.ctx;
    defer {
        ctx.parar.store(true, .release);
        arranque.hilo.join();
        std.testing.allocator.destroy(ctx);
    }

    var s = try SocketConPlazo.conectar(127, 0, 0, 1, ctx.puerto);
    defer s.cerrar();

    var buf: [256]u8 = undefined;
    const t0 = GetTickCount64();
    const r = s.leerConPlazo(&buf, 400, null);
    const ms = GetTickCount64() - t0;

    // 1. Volvió, y volvió con el error correcto: plazo vencido, no otra cosa.
    // Comprobar los tiempos con aserciones evita avisos «failed command» que
    // el runner emite si una prueba correcta escribe en stderr.
    try std.testing.expectError(error.Vencido, r);
    // 2. Y volvió A TIEMPO. Sin esta comprobación, «devolvió» podría significar
    //    «devolvió media hora después», que es exactamente el fallo original.
    try std.testing.expect(ms >= 350);
    try std.testing.expect(ms < 3000);
}

test "D1: el plazo no se come los datos que SI llegan" {
    // La otra mitad, y la que evita el arreglo tramposo: un plazo que corta
    // siempre «cumple» el test de arriba y rompe el producto. Contra un
    // servidor que sí contesta, la lectura tiene que traer los bytes.
    if (builtin.os.tag != .windows) return @import("../platform.zig").skip("T9: el sondeo de socket usa Winsock (WSAPoll); omitida en Linux");

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const arranque = (try arrancarSordo(true, threaded.io())) orelse return error.SkipZigTest;
    const ctx = arranque.ctx;
    defer {
        ctx.parar.store(true, .release);
        arranque.hilo.join();
        std.testing.allocator.destroy(ctx);
    }

    var s = try SocketConPlazo.conectar(127, 0, 0, 1, ctx.puerto);
    defer s.cerrar();

    var buf: [256]u8 = undefined;
    const lectura = try s.leerConPlazo(&buf, 3000, null);
    try std.testing.expect(lectura.bytes >= 4);
    try std.testing.expectEqualStrings("HOLA", buf[0..4]);
    // Y llegó MUCHO antes del plazo: no es que el plazo venciera con datos.
    try std.testing.expect(lectura.ms < 2000);
}

test "D1: se puede cancelar desde otro hilo sin tocar el socket" {
    // Lo que `CancelIoEx` no podía hacer sin llevarse el proceso por delante:
    // cortar una lectura en curso desde fuera. Aquí no hay nada bloqueado que
    // desbloquear — solo una bandera que se mira entre sondeos.
    if (builtin.os.tag != .windows) return @import("../platform.zig").skip("T9: el sondeo de socket usa Winsock (WSAPoll); omitida en Linux");

    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const arranque = (try arrancarSordo(false, threaded.io())) orelse return error.SkipZigTest;
    const ctx = arranque.ctx;
    defer {
        ctx.parar.store(true, .release);
        arranque.hilo.join();
        std.testing.allocator.destroy(ctx);
    }

    var s = try SocketConPlazo.conectar(127, 0, 0, 1, ctx.puerto);
    defer s.cerrar();

    var cancelado = std.atomic.Value(bool).init(false);

    const Cortador = struct {
        fn run(bandera: *std.atomic.Value(bool)) void {
            Sleep(150);
            bandera.store(true, .release);
        }
    };
    const cortador = try std.Thread.spawn(.{}, Cortador.run, .{&cancelado});
    defer cortador.join();

    var buf: [256]u8 = undefined;
    const t0 = GetTickCount64();
    // Plazo largo a propósito: si vuelve pronto es por la cancelación, no
    // porque el plazo venciera.
    const r = s.leerConPlazo(&buf, 30_000, &cancelado);
    const ms = GetTickCount64() - t0;

    try std.testing.expectError(error.Vencido, r);
    try std.testing.expect(ms < 3000);
}
