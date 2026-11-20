const std = @import("std");
const builtin = @import("builtin");
const http = std.http;
const Io = std.Io;
/// D1 tramo 2: el Io con plazo real bajo la capa TLS (netRead vigilada).
/// Reexportado porque live_worker lo apaga para el test H5 (sin esta vía,
/// el test mediría la interacción de dos cortes en vez de uno).
pub const deadline_io = @import("deadline_io.zig");

/// Errores del cliente HTTP.
pub const HttpError = error{
    RequestFailed,
    ResponseFailed,
    SseParseFailed,
    ResponseTooLarge,
    HttpRedirectCrossOrigin,
    RedirectBlocked,
    RequestAlreadySent,
} || TransportError || std.http.Client.RequestError || std.http.Client.FetchError;

pub const TransportError = error{ InsecureCredentialTransport, UnsupportedScheme, InvalidFormat, UriMissingHost };
pub const SECURITY_MESSAGE = "Por seguridad, los envios requieren HTTPS; http:// solo se admite en loopback 127.0.0.0/8, [::1] o localhost exacto (sin DNS), salvo trafico publico explicito sin cuerpo, parametros ni cabeceras adicionales";
pub const REDIRECT_MESSAGE = "Redireccion bloqueada: una peticion privada o autenticada no puede seguir redirects";

/// Una sola política para configuración y envío; nunca resolver DNS para decidir
/// si un nombre que parece local puede recibir una clave en texto plano.
pub fn validateCredentialUrl(url: []const u8) TransportError!void {
    try validateCredentialUri(std.Uri.parse(url) catch return error.InvalidFormat);
}

fn validateCredentialUri(uri: std.Uri) TransportError!void {
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http") and !std.ascii.eqlIgnoreCase(uri.scheme, "https")) return error.UnsupportedScheme;
    const component = uri.host orelse return error.UriMissingHost;
    const host = switch (component) {
        .raw => |h| h,
        .percent_encoded => |h| h,
    };
    if (host.len == 0 or uri.user != null or uri.password != null) return error.InvalidFormat;
    // Evita discrepancias entre el parser de URI y el resolver de red.
    for (host) |c| if (c <= 32 or c == 127 or c == '%' or c == '\\') return error.InvalidFormat;
    if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return;
    if (std.ascii.eqlIgnoreCase(host, "localhost")) return;
    if (host[0] == '[' and host[host.len - 1] == ']') {
        const ip = std.Io.net.Ip6Address.parse(host[1 .. host.len - 1], 0) catch return error.InsecureCredentialTransport;
        if (std.mem.eql(u8, &ip.bytes, &std.Io.net.Ip6Address.loopback(0).bytes)) return;
    } else {
        const ip = std.Io.net.Ip4Address.parse(host, 0) catch return error.InsecureCredentialTransport;
        if (ip.bytes[0] == 127) return;
    }
    return error.InsecureCredentialTransport;
}

fn connectionUri(uri: std.Uri) std.Uri {
    // HTTPS necesita conservar el nombre para SNI y verificar el certificado.
    if (!std.ascii.eqlIgnoreCase(uri.scheme, "http")) return uri;
    var result = uri;
    if (uri.host) |component| {
        const host = switch (component) {
            .raw, .percent_encoded => |h| h,
        };
        // Solo el nombre exacto, sin punto final ni sufijos; nunca resolver DNS.
        if (std.ascii.eqlIgnoreCase(host, "localhost")) result.host = .{ .raw = "127.0.0.1" };
    }
    return result;
}

fn carriesCredentials(options: http.Client.RequestOptions) bool {
    // Cualquier valor adicional puede contener secretos, sin importar su nombre.
    if (options.extra_headers.len != 0 or options.privileged_headers.len != 0) return true;
    inline for (std.meta.fields(http.Client.Request.Headers)) |field| {
        if (@field(options.headers, field.name) == .override) return true;
    }
    return false;
}

fn sameOrigin(a: std.Uri, b: std.Uri) bool {
    if (b.user != null or b.password != null) return false;
    const a_host = a.host orelse return false;
    const b_host = b.host orelse return false;
    const a_name = switch (a_host) {
        .raw, .percent_encoded => |name| name,
    };
    const b_name = switch (b_host) {
        .raw, .percent_encoded => |name| name,
    };
    return std.ascii.eqlIgnoreCase(a.scheme, b.scheme) and
        std.ascii.eqlIgnoreCase(a_name, b_name) and
        (a.port orelse if (std.ascii.eqlIgnoreCase(a.scheme, "https")) @as(u16, 443) else @as(u16, 80)) ==
            (b.port orelse if (std.ascii.eqlIgnoreCase(b.scheme, "https")) @as(u16, 443) else @as(u16, 80));
}

/// Peticion diferida: no conecta ni expone un writer antes de comprobar el envio.
pub const Request = struct {
    owner: *HttpClient,
    uri: std.Uri,
    method: http.Method,
    options: http.Client.RequestOptions,
    headers: http.Client.Request.Headers,
    extra_headers: []const http.Header,
    privileged_headers: []const http.Header,
    transfer_encoding: http.Client.Request.TransferEncoding = .none,
    public_traffic: bool = false,
    inner: ?http.Client.Request = null,
    connection: ?*http.Client.Connection = null,

    fn validateForSend(self: *Request, has_body: bool) HttpError!void {
        var options = self.options;
        options.headers = self.headers;
        options.extra_headers = self.extra_headers;
        options.privileged_headers = self.privileged_headers;
        const has_query = if (self.uri.query) |query| switch (query) {
            .raw, .percent_encoded => |q| q.len != 0,
        } else false;
        self.public_traffic = self.public_traffic and !has_body and self.transfer_encoding == .none and !has_query and !carriesCredentials(options);
        // Siempre decidir con la URL, cabeceras y cuerpo FINALES, antes de conectar.
        validateCredentialUri(self.uri) catch |err| {
            if (err != error.InsecureCredentialTransport or !self.public_traffic) return err;
        };
        if (options.connection != null) return error.InvalidFormat;
    }

    fn prepare(self: *Request, has_body: bool) HttpError!*http.Client.Request {
        if (self.inner != null) return error.RequestAlreadySent;
        try self.validateForSend(has_body);
        var options = self.options;
        options.headers = self.headers;
        options.extra_headers = self.extra_headers;
        options.privileged_headers = self.privileged_headers;
        // La std nunca sigue redirects: receiveHead los rechaza explicitamente.
        options.redirect_behavior = .unhandled;
        self.inner = try self.owner.client.request(self.method, connectionUri(self.uri), options);
        const req = &self.inner.?;
        req.transfer_encoding = self.transfer_encoding;
        self.connection = req.connection;
        self.owner.applySocketTimeouts(req);
        return req;
    }

    pub fn sendBodiless(self: *Request) HttpError!void {
        const req = try self.prepare(false);
        try req.sendBodiless();
    }

    pub fn sendBodyUnflushed(self: *Request, buffer: []u8) HttpError!http.BodyWriter {
        const req = try self.prepare(true);
        return req.sendBodyUnflushed(buffer);
    }

    pub fn receiveHead(self: *Request, buffer: []u8) HttpError!http.Client.Response {
        const req = if (self.inner) |*r| r else return error.RequestFailed;
        const response = try req.receiveHead(buffer);
        if (response.head.status.class() == .redirect and !self.public_traffic) {
            self.owner.last_failure.capture(@intFromEnum(response.head.status), REDIRECT_MESSAGE, null);
            return error.RedirectBlocked;
        }
        return response;
    }

    pub fn deinit(self: *Request) void {
        if (self.inner) |*req| req.deinit();
        self.inner = null;
        self.connection = null;
    }
};

pub const JsonResponse = struct {
    status: http.Status,
    body: []u8,
    /// USUARIO-NUEVO A6 (10-nov): cabeceras de reintento de una respuesta no
    /// exitosa (Retry-After, X-RateLimit-*). Se leen ANTES del cuerpo: leerlo
    /// puede reutilizar el búfer donde viven las cabeceras.
    rate: @import("../external_error.zig").RateHints = .{},
};

/// A6: indicaciones de reintento de las cabeceras de una respuesta.
pub fn rateHintsOf(head: http.Client.Response.Head) @import("../external_error.zig").RateHints {
    var hints: @import("../external_error.zig").RateHints = .{};
    var it = head.iterateHeaders();
    while (it.next()) |h| hints.note(h.name, h.value);
    return hints;
}

/// Default maximum response body size: 16 MB.
/// Prevents unbounded memory allocation from malicious or buggy servers.
pub const DEFAULT_MAX_RESPONSE_BYTES: usize = 16 * 1024 * 1024;

/// P10: plazo de socket para ENVIAR (SO_SNDTIMEO) y para RECIBIR (SO_RCVTIMEO).
///
/// Medido en vivo (2026-08-07): un Ctrl+Enter de autocompletado se quedó 85
/// segundos sin resolver, porque el socket no tenía ningún plazo y cada llamada
/// había que envolverla en un hilo con vigilante — y cuando el vigilante vencía,
/// el hilo se abandonaba a media petición. Ese abandono era la causa de fondo del
/// crash de `HttpClient.deinit` (assert de connection pool en uso) que se
/// documenta ahí: el hilo huérfano seguía ejecutando su `defer http.deinit()`
/// con la petición viva.
///
/// Con plazos en el propio socket, la lectura/escritura BLOQUEANTE devuelve en
/// tiempo finito y el "watchdog" pierde su única razón de existir: el socket se
/// autocorta. 60s por intento es lo que tarda en degradar un proveedor que
/// cuelga y se va al siguiente de la cadena, sin castigar latencias legítimas
/// (una respuesta SSE larga entrega deltas cada pocos segundos, así que el
/// RCVTIMEO reinicia en cada recv; una única respuesta puede tardar más que el
/// plazo sin tocarlo).
pub const DEFAULT_SOCKET_RECV_TIMEOUT_SECONDS: u32 = 60;
pub const DEFAULT_SOCKET_SEND_TIMEOUT_SECONDS: u32 = 60;

/// H5 — el plazo que de verdad interrumpe la operación.
///
/// Hasta aquí, «plazo» significaba: lanzar un hilo, mirar el reloj desde fuera
/// y, al vencer, DEJAR DE MIRAR. El hilo seguía bloqueado dentro de `recv`
/// hasta que el servidor tuviera a bien contestar —o para siempre—, y de ahí
/// salió toda la familia de fallos de esta base de código: el `0xC0000005` del
/// planificador (H1), la contención sobre `runtime.db` (BUG-1), el handle de
/// hilo filtrado a propósito en `callWithDeadline`, y el `assert` del pool de
/// conexiones que documenta `HttpClient.deinit`. Todos son el mismo defecto
/// visto desde sitios distintos: nadie cancelaba nada.
///
/// El motivo de que no se cancelara está medido y escrito en
/// `setWindowsSocketTimeout`: en Windows, este Zig usa sockets AFD crudos y
/// SO_RCVTIMEO no llega al kernel. Pero cortar el socket por debajo SÍ se
/// puede, y eso hace que el `recv` bloqueado devuelva error en vez de esperar:
/// el hilo se desenrolla por su camino normal —liberando su cliente HTTP, su
/// conexión y su memoria— y quien puso el plazo puede hacerle `join` en vez de
/// abandonarlo.
///
/// MEDIDO AL IMPLEMENTARLO (2026-08-14): la primera versión usaba `CancelIoEx`
/// sobre el handle AFD. Funciona —el `recv` bloqueado vuelve al instante— pero
/// `std.Io.Threaded.netReadWindows` tiene un `.CANCELLED => unreachable`, así
/// que lo que se ganaba en desbloqueo se perdía en pánico. La propia `std`
/// documenta cuál es la vía buena, en el error `SocketNotListening` de
/// `accept`: «shutdown was called (possibly while this call was blocking).
/// This allows shutdown to be used as a concurrent cancellation mechanism».
/// Eso es lo que se usa aquí.
///
/// El buzón es de quien pone el plazo, no del cliente HTTP: tiene que
/// sobrevivir al hilo que lo usa. Por eso `HttpClient` solo guarda un puntero.
pub const CancelSink = struct {
    /// `std.atomic.Mutex` de este Zig solo trae `tryLock`/`unlock`; el
    /// `lock()` con espera activa lo pone `lockSpin`, igual que hace
    /// `core/src/sync.zig` (que no se puede importar desde aquí: otro módulo).
    mutex: std.atomic.Mutex = .unlocked,
    /// Socket de la petición en curso, o null entre peticiones.
    handle: ?std.Io.net.Socket.Handle = null,
    /// El `Io` que gobierna ese socket: `shutdown` pasa por su vtable, no por
    /// una llamada al sistema a pelo.
    io: ?Io = null,
    /// Se pone una vez y no se quita: si la cancelación llega entre dos
    /// peticiones, la siguiente en registrarse se corta nada más nacer en vez
    /// de colarse por la rendija.
    cancelled: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// La llama el hilo que hace HTTP, con el socket recién creado.
    pub fn publish(self: *CancelSink, handle: std.Io.net.Socket.Handle, io: Io) void {
        lockSpin(&self.mutex);
        defer self.mutex.unlock();
        self.handle = handle;
        self.io = io;
        if (self.cancelled.load(.acquire)) shutdownHandle(handle, io);
    }

    /// La llama el hilo que hace HTTP al soltar el socket.
    pub fn clear(self: *CancelSink) void {
        lockSpin(&self.mutex);
        defer self.mutex.unlock();
        self.handle = null;
        self.io = null;
    }

    /// La llama el propietario del plazo cuando vence. Devuelve true si había una
    /// operación viva a la que cortarle el paso.
    pub fn cancel(self: *CancelSink) bool {
        self.cancelled.store(true, .release);
        lockSpin(&self.mutex);
        defer self.mutex.unlock();
        const h = self.handle orelse return false;
        const io = self.io orelse return false;
        shutdownHandle(h, io);
        return true;
    }

    pub fn isCancelled(self: *const CancelSink) bool {
        return self.cancelled.load(.acquire);
    }

    pub fn hasHandle(self: *CancelSink) bool {
        lockSpin(&self.mutex);
        defer self.mutex.unlock();
        return self.handle != null;
    }
};

fn lockSpin(m: *std.atomic.Mutex) void {
    while (!m.tryLock()) std.atomic.spinLoopHint();
}

/// Cierra las dos direcciones del socket. Best-effort por definición: si la
/// operación ya había terminado no hay nada que cortar, y eso no es un error.
///
/// No se CIERRA el socket: eso sería una carrera con el hilo que todavía lo
/// tiene en la mano. `shutdown` lo deja inservible sin liberar el descriptor.
fn shutdownHandle(handle: std.Io.net.Socket.Handle, io: Io) void {
    io.vtable.netShutdown(io.userdata, handle, .both) catch {};
}

/// Cliente HTTP/TLS nativo con soporte SSE.
pub const HttpClient = struct {
    last_failure: @import("../external_error.zig").Diagnostic = .{},

    allocator: std.mem.Allocator,
    threaded: *Io.Threaded,
    client: http.Client,
    pending_auth: ?[]const u8,
    max_response_bytes: usize,
    /// P10: plazo de socket por operación (segundos). Se aplica como SO_RCVTIMEO
    /// y SO_SNDTIMEO en cada Request; 0 = sin plazo (compatibilidad / tests que
    /// no quieren que la red se corte).
    socket_timeout_seconds: u32 = DEFAULT_SOCKET_RECV_TIMEOUT_SECONDS,
    /// H5: buzón de cancelación de quien puso el plazo. Prestado, nunca propio
    /// — tiene que sobrevivir a este cliente (ver `CancelSink`).
    cancel_sink: ?*CancelSink = null,
    pub fn captureFailure(self: *HttpClient, response: *http.Client.Response, secret: ?[]const u8) void {
        const limit = self.max_response_bytes;
        self.max_response_bytes = 4096;
        defer self.max_response_bytes = limit;
        // A6: las cabeceras antes del cuerpo (ver JsonResponse.rate).
        const status: u16 = @intFromEnum(response.head.status);
        const headers = rateHintsOf(response.head);
        const body = self.readBody(response) catch {
            self.last_failure.capture(status, "cuerpo ausente, ilegible o mayor de 4096 bytes", null);
            self.last_failure.rate.merge(headers);
            return;
        };
        defer self.allocator.free(body);
        self.last_failure.capture(status, body, secret);
        self.last_failure.rate.merge(headers);
    }
    pub fn init(allocator: std.mem.Allocator) !HttpClient {
        return initWithTls(allocator, true);
    }

    /// Plain HTTP is restricted to loopback and does not need the OS CA store.
    /// HTTPS keeps the same certificate verification as init().
    pub fn initForUrl(allocator: std.mem.Allocator, url: []const u8) !HttpClient {
        const uri = try std.Uri.parse(url);
        try validateCredentialUri(uri);
        if (std.ascii.eqlIgnoreCase(uri.scheme, "http")) return initWithTls(allocator, false);
        if (std.ascii.eqlIgnoreCase(uri.scheme, "https")) return initWithTls(allocator, true);
        return error.UnsupportedScheme;
    }

    /// Punto único de creación: ninguna petición sigue redirects por defecto.
    pub fn request(self: *HttpClient, method: http.Method, uri: std.Uri, options: http.Client.RequestOptions) HttpError!Request {
        return self.requestWithPolicy(method, uri, options, .{});
    }

    // Solo get(), sin cabeceras ni autenticación, solicita redirects públicos.
    // Se devuelven sin seguir: el llamador verifica el origen antes de conectar.
    fn requestWithPolicy(self: *HttpClient, method: http.Method, uri: std.Uri, options: http.Client.RequestOptions, policy: struct { public_redirects: bool = false }) HttpError!Request {
        return .{ .owner = self, .uri = uri, .method = method, .options = options, .headers = options.headers, .extra_headers = options.extra_headers, .privileged_headers = options.privileged_headers, .public_traffic = policy.public_redirects };
    }

    fn initWithTls(allocator: std.mem.Allocator, tls: bool) !HttpClient {
        var threaded = try allocator.create(Io.Threaded);
        errdefer allocator.destroy(threaded);
        threaded.* = Io.Threaded.init(allocator, .{});
        errdefer threaded.deinit();
        const io = threaded.io();

        // D1 tramo 2: el plazo vive bajo la capa TLS. El Io que se entrega al
        // http.Client es el ENVOLTORIO con netRead vigilada: cualquier
        // lectura (TLS incluido) se corta sola al vencer el plazo. El
        // userdata sigue siendo el *Threaded (las 110 funciones restantes
        // delegadas no notan nada) y el plazo viaja en el threadlocal de
        // deadline_io, que se fija por hilo abajo.
        var client = http.Client{
            .allocator = allocator,
            .io = deadline_io.wrapIo(threaded),
        };
        // Initialize CA bundle for TLS
        var bundle: std.crypto.Certificate.Bundle = .empty;
        errdefer bundle.deinit(allocator);
        const now = Io.Clock.real.now(io);
        if (tls) bundle.rescan(allocator, io, now) catch |err| switch (err) {
            error.Canceled => return error.RequestFailed,
            else => return error.RequestFailed,
        };
        client.now = now;
        client.ca_bundle = bundle;
        // D1 tramo 2: el plazo de ESTE hilo. Cada HttpClient vive y muere en
        // un solo hilo (el huérfano de H5 es este mismo cliente en su propio
        // hilo), así que init/deinit son el par natural de colocación/retiro
        // del threadlocal. Los tests que ponen socket_timeout_seconds = 0
        // ANTES de llamar a nada retiran el plazo en su propio hilo.
        deadline_io.current_deadline_ms = DEFAULT_SOCKET_RECV_TIMEOUT_SECONDS * 1000;
        return .{
            .allocator = allocator,
            .threaded = threaded,
            .client = client,
            .pending_auth = null,
            .max_response_bytes = DEFAULT_MAX_RESPONSE_BYTES,
        };
    }

    /// H5: ¿este cliente pertenece a una llamada cuyo plazo ya venció?
    ///
    /// Un hilo abandonado no puede abortar la lectura en la que está metido
    /// (medido: ver `CancelSink`), pero sí puede dejar de empezar la
    /// siguiente. Sin esto, una cadena con continuaciones seguía hablando con
    /// el proveedor minutos después de que a nadie le importara la respuesta.
    pub fn cancelledByDeadline(self: *const HttpClient) bool {
        const sink = self.cancel_sink orelse return false;
        return sink.isCancelled();
    }

    /// P10: si el plazo se ha puesto a 0, no hay socket que configurar.
    fn socketTimeoutSeconds(self: *const HttpClient) ?u32 {
        return if (self.socket_timeout_seconds == 0) null else self.socket_timeout_seconds;
    }

    /// P10: aplica SO_RCVTIMEO y SO_SNDTIMEO al socket de una Request recién
    /// creada. `client.request` ya conectó (o reutilizó del pool), así que el
    /// handle está vivo aquí. Best-effort: si el socket no se puede configurar
    /// no se aborta la llamada — al menos se intentó tener plazos reales, y el
    /// fallo quedará como timeout de nivel superior si llega a darse.
    pub fn applySocketTimeouts(self: *HttpClient, req: *http.Client.Request) void {
        const conn = req.connection orelse return;
        const handle = conn.stream_writer.stream.socket.handle;
        // H5: el socket queda registrado ANTES de cualquier otra cosa. Si el
        // plazo vence a mitad de la petición, quien lo puso sabe a qué handle
        // cortarle la E/S; y si ya había vencido, `publish` lo corta al nacer.
        if (self.cancel_sink) |sink| sink.publish(handle, self.client.io);
        const seconds = self.socketTimeoutSeconds() orelse return;
        if (builtin.os.tag == .windows) {
            // P10-MEDICIÓN (2026-08-07): en Windows este Zig usa sockets AFD
            // crudos (NtCreateFile, sin Winsock) y esas dos opciones NO son
            // aplicables: SO_RCVTIMEO/SO_SNDTIMEO las emula la capa de
            // usuario de ws2_32, no el kernel AFD. Verificado en vivo con un
            // servidor local que nunca responde: el ioctl IOCTL.AFD.SOCKOPT
            // devuelve NOT_SUPPORTED para optname 4102/4101 (mientras que
            // REUSE_UNICASTPORT sí se acepta), y ws2_32.setsockopt falla con
            // WSANOTINITIALISED (10093) porque el proceso jamás invocó
            // WSAStartup. Se intenta igual (best-effort) por si el llamador
            // corre sobre un socket que sí pase por Winsock, y porque en
            // plataformas POSIX estas opciones SÍ existen y son lo que hace
            // falta. El plazo real en Windows se resuelve en el nivel de
            // `Io` (operaciones con timeout), fuera de este archivo.
            setWindowsSocketTimeout(handle, windowsSockOpt(.rcv), seconds);
            setWindowsSocketTimeout(handle, windowsSockOpt(.snd), seconds);
        } else {
            // UNIX: el socket manda en tiempo finito tanto para enviar como
            // para recibir. Best-effort: si no se puede configurar, el fallo
            // lo cogerá el nivel superior.
            setPosixSocketTimeout(handle, std.posix.SO.RCVTIMEO, seconds);
            setPosixSocketTimeout(handle, std.posix.SO.SNDTIMEO, seconds);
        }
    }

    /// Libera el cliente TAMBIÉN si quedaban peticiones en vuelo.
    ///
    /// Esto es lo que mataba a DevAgents al pulsar «Sondear ahora», y llevaba
    /// desde el 2026-08-05 sin diagnosticar porque el mensaje de pánico no
    /// llegaba a ninguna parte. La pila, una vez visible:
    ///
    ///     std/http/Client.zig:1310  assert(connection_pool.used.first == null)
    ///       <- providers/src/http/client.zig  self.client.deinit()
    ///       <- core/src/live_worker.zig:1574  defer http.deinit()
    ///       <- callTimedDirectV2 <- callTimedThread   (un HILO)
    ///
    /// `Client.deinit` exige como PRECONDICIÓN que no queden conexiones en uso.
    /// Cuando el vigilante de `callTimedThread` vence, el propietario se desentiende
    /// del hilo trabajador y ese huérfano ejecuta su `defer http.deinit()` con
    /// una petición todavía viva: la precondición se viola, el assert llama a
    /// `unreachable`, y eso en Windows es un `abort()` = ExitProcess(3). Como
    /// el motor vive DENTRO del proceso de la cabina, se llevaba la ventana.
    ///
    /// La corrección no es silenciar nada: `ConnectionPool.deinit` YA recorre y
    /// destruye las dos listas, la de libres y **la de usadas**. El assert de
    /// arriba es una comprobación de contrato, no algo que el pool necesite. Se
    /// hace aquí exactamente lo mismo que `Client.deinit` —pool, bundle de CA e
    /// invalidar— sin la precondición que no podemos garantizar desde un hilo
    /// que puede ser abandonado.
    ///
    /// La causa de fondo (que existan hilos abandonados a media petición) es el
    /// cliente sin plazos; se ataca en `fetch`/`stream` con SO_RCVTIMEO.
    pub fn deinit(self: *HttpClient) void {
        // H5: el buzón deja de apuntar a sockets que este cliente está a punto
        // de destruir. Sin esto, una cancelación tardía trabajaría sobre un
        // handle ya cerrado (y potencialmente reutilizado por otra cosa).
        if (self.cancel_sink) |sink| sink.clear();
        if (self.pending_auth) |auth| self.allocator.free(auth);

        const io = self.client.io;
        self.client.connection_pool.deinit(io);
        self.client.ca_bundle.deinit(self.client.allocator);
        self.client = undefined;

        // D1 tramo 2: el threadlocal del plazo se retira con el cliente.
        deadline_io.current_deadline_ms = 0;

        self.threaded.deinit();
        self.allocator.destroy(self.threaded);
    }

    /// Lee el cuerpo completo de una respuesta, DESCOMPRIMIENDO si viene gzip/deflate
    /// (std.http.Client anuncia accept-encoding: gzip por defecto y NO descomprime con
    /// el reader plano; hay que usar readerDecompressing con un buffer de ventana).
    /// Lee hasta `max_response_bytes` del reader, retornando error.ResponseTooLarge si se excede.
    fn readLimited(self: *HttpClient, reader: *std.Io.Reader) HttpError![]u8 {
        var body = std.ArrayList(u8).empty;
        errdefer body.deinit(self.allocator);
        var chunk: [4096]u8 = undefined;
        var total: usize = 0;
        while (true) {
            const n = reader.readSliceShort(&chunk) catch |err| switch (err) {
                error.ReadFailed => return error.ResponseFailed,
                else => |e| return e,
            };
            if (n == 0) break;
            total += n;
            if (total > self.max_response_bytes) {
                return error.ResponseTooLarge;
            }
            body.appendSlice(self.allocator, chunk[0..n]) catch return error.OutOfMemory;
        }
        return body.toOwnedSlice(self.allocator) catch return error.OutOfMemory;
    }

    pub fn readBody(self: *HttpClient, response: *http.Client.Response) HttpError![]u8 {
        var transfer_buffer: [64]u8 = undefined;
        var decompress: http.Decompress = undefined;
        const decompress_buffer: []u8 = switch (response.head.content_encoding) {
            .identity => &.{},
            .gzip, .deflate => try self.allocator.alloc(u8, std.compress.flate.max_window_len),
            else => return error.ResponseFailed,
        };
        defer if (decompress_buffer.len > 0) self.allocator.free(decompress_buffer);
        const reader = response.readerDecompressing(&transfer_buffer, &decompress, decompress_buffer);
        return self.readLimited(reader);
    }

    /// GET privado por defecto, incluso sin cabeceras.
    pub fn get(self: *HttpClient, url: []const u8) HttpError![]u8 {
        return self.getAuth(url, null);
    }

    /// Marca publica explicita: sin cuerpo ni parametros; redirects al mismo origen.
    pub fn getPublic(self: *HttpClient, url: []const u8) HttpError![]u8 {
        const origin = try std.Uri.parse(url);
        var uri = origin;
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        for (0..4) |hop| {
            uri = next_hop: {
                var req = try self.requestWithPolicy(.GET, uri, .{}, .{ .public_redirects = true });
                defer req.deinit();
                try req.sendBodiless();
                var response = try req.receiveHead(&.{});
                if (response.head.status.class() != .redirect) return self.readBody(&response);
                if (hop == 3) return error.TooManyHttpRedirects;
                const location = response.head.location orelse return error.HttpRedirectLocationMissing;
                var buffer = try arena.allocator().alloc(u8, 8192);
                if (location.len > buffer.len) return error.HttpRedirectLocationOversize;
                @memcpy(buffer[0..location.len], location);
                const next = uri.resolveInPlace(location.len, &buffer) catch return error.HttpRedirectLocationInvalid;
                if (!sameOrigin(origin, next)) return error.HttpRedirectCrossOrigin;
                break :next_hop next;
            };
        }
        return error.TooManyHttpRedirects;
    }

    /// 10-nov (`web_fetch` del agente): GET público que SÍ sigue redirects a
    /// otro origen (http→https, dominio→www…), pero cada salto pasa antes por
    /// `allow` (el llamador bloquea ahí la red local). Sin cabeceras, cuerpo
    /// ni credenciales. `final_url` recibe la URL servida (memoria del
    /// llamador vía `self.allocator`).
    pub fn getPublicFollow(self: *HttpClient, url: []const u8, allow: *const fn (std.Uri) bool, final_url: *?[]u8) HttpError![]u8 {
        var status: u16 = 0;
        return self.getPublicFollowStatus(url, allow, final_url, &status);
    }

    /// Tanda 5 (actualizador): lo mismo que `getPublicFollow`, y además
    /// `status` recibe el código HTTP de la respuesta final (un 404 de un
    /// asset no es un instalador, aunque traiga cuerpo).
    pub fn getPublicFollowStatus(self: *HttpClient, url: []const u8, allow: *const fn (std.Uri) bool, final_url: *?[]u8, status: *u16) HttpError![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        var uri = try std.Uri.parse(url);
        for (0..6) |hop| {
            if (uri.user != null or uri.password != null or !allow(uri)) return error.HttpRedirectCrossOrigin;
            uri = next_hop: {
                var req = try self.requestWithPolicy(.GET, uri, .{}, .{ .public_redirects = true });
                defer req.deinit();
                try req.sendBodiless();
                var response = try req.receiveHead(&.{});
                if (response.head.status.class() != .redirect) {
                    final_url.* = std.fmt.allocPrint(self.allocator, "{f}", .{uri}) catch null;
                    status.* = @intFromEnum(response.head.status);
                    return self.readBody(&response);
                }
                if (hop == 5) return error.TooManyHttpRedirects;
                const location = response.head.location orelse return error.HttpRedirectLocationMissing;
                var buffer = try arena.allocator().alloc(u8, 8192);
                if (location.len > buffer.len) return error.HttpRedirectLocationOversize;
                @memcpy(buffer[0..location.len], location);
                break :next_hop uri.resolveInPlace(location.len, &buffer) catch return error.HttpRedirectLocationInvalid;
            };
        }
        return error.TooManyHttpRedirects;
    }

    /// GET autenticado (Authorization: Bearer <key>) — para endpoints como /models que
    /// exigen la clave (la mayoría de proveedores; NVIDIA lo permite público). El header
    /// vive durante toda la petición (que se completa antes de retornar).
    pub fn getAuth(self: *HttpClient, url: []const u8, api_key: ?[]const u8) HttpError![]u8 {
        const uri = try std.Uri.parse(url);
        var headers_buffer: [1]http.Header = undefined;
        var headers_len: usize = 0;
        var auth_buf: ?[]const u8 = null;
        defer if (auth_buf) |a| self.allocator.free(a);
        if (api_key) |key| {
            auth_buf = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{key});
            headers_buffer[headers_len] = .{ .name = "authorization", .value = auth_buf.? };
            headers_len += 1;
        }
        var req = try self.request(.GET, uri, .{ .extra_headers = headers_buffer[0..headers_len] });
        defer req.deinit();
        try req.sendBodiless();
        var redirect_buffer: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);
        return self.readBody(&response);
    }

    /// Realiza una petición POST con body JSON y devuelve la respuesta.
    pub fn postJson(self: *HttpClient, url: []const u8, body_json: []const u8, api_key: ?[]const u8) HttpError![]u8 {
        if (self.pending_auth) |auth| self.allocator.free(auth);
        self.pending_auth = null;
        const uri = try std.Uri.parse(url);
        var headers_buffer: [4]http.Header = undefined;
        var headers_len: usize = 0;
        headers_buffer[headers_len] = .{ .name = "content-type", .value = "application/json" };
        headers_len += 1;
        if (api_key) |key| {
            self.pending_auth = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{key});
            headers_buffer[headers_len] = .{ .name = "authorization", .value = self.pending_auth.? };
            headers_len += 1;
        }
        var req = try self.request(.POST, uri, .{
            .extra_headers = headers_buffer[0..headers_len],
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = body_json.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body_json);
        try body_writer.end();
        try req.connection.?.flush();
        var redirect_buffer: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);
        const reader = response.reader(&.{});
        return self.readLimited(reader);
    }

    /// POST JSON con headers explícitos. Los valores de los headers deben vivir
    /// hasta que la petición termine; el body devuelto pertenece al caller.
    pub fn postJsonWithHeaders(self: *HttpClient, url: []const u8, body_json: []const u8, headers: []const http.Header) HttpError!JsonResponse {
        const uri = try std.Uri.parse(url);
        var req = try self.request(.POST, uri, .{
            .extra_headers = headers,
            .redirect_behavior = .not_allowed,
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = body_json.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body_json);
        try body_writer.end();
        try req.connection.?.flush();
        var redirect_buffer: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);
        const status = response.head.status;
        const rate = if (status.class() != .success) rateHintsOf(response.head) else @import("../external_error.zig").RateHints{};
        const body = try self.readBody(&response);
        return .{ .status = status, .body = body, .rate = rate };
    }

    /// POST con body form-urlencoded (Content-Type: application/x-www-form-urlencoded)
    /// y User-Agent de navegador. Usado para endpoints como lite.duckduckgo.com/lite/
    /// que requieren POST en vez de GET con query string.
    pub fn postForm(self: *HttpClient, url: []const u8, form_body: []const u8) HttpError![]u8 {
        const uri = try std.Uri.parse(url);
        var headers_buffer: [2]http.Header = undefined;
        headers_buffer[0] = .{ .name = "content-type", .value = "application/x-www-form-urlencoded" };
        headers_buffer[1] = .{ .name = "user-agent", .value = "Mozilla/5.0 (Windows NT 10.0; Win64; x64)" };
        var req = try self.request(.POST, uri, .{
            .extra_headers = headers_buffer[0..2],
        });
        defer req.deinit();
        req.transfer_encoding = .{ .content_length = form_body.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(form_body);
        try body_writer.end();
        try req.connection.?.flush();
        var redirect_buffer: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);
        return self.readBody(&response);
    }

    /// GET con un header custom (ej: X-Subscription-Token para Brave Search).
    /// El header_value vive durante la petición (caller lo gestiona).
    pub fn getWithHeader(self: *HttpClient, url: []const u8, header_name: []const u8, header_value: []const u8) HttpError![]u8 {
        const uri = try std.Uri.parse(url);
        var headers_buffer: [1]http.Header = undefined;
        headers_buffer[0] = .{ .name = header_name, .value = header_value };
        var req = try self.request(.GET, uri, .{ .extra_headers = headers_buffer[0..1] });
        defer req.deinit();
        try req.sendBodiless();
        var redirect_buffer: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);
        return self.readBody(&response);
    }

    /// Like `postSse` but sends TWO custom headers (e.g. `x-api-key` + `anthropic-version`
    /// for Anthropic) instead of `Authorization: Bearer`. Both header values are copied
    /// into `pending_auth` (concatenated) so they live for the duration of the request.
    pub fn postSseWithDualHeaders(self: *HttpClient, url: []const u8, body_json: []const u8, h1_name: []const u8, h1_value: []const u8, h2_name: []const u8, h2_value: []const u8) HttpError!*Request {
        if (self.pending_auth) |auth| self.allocator.free(auth);
        self.pending_auth = null;
        const uri = try std.Uri.parse(url);
        var headers_buffer: [5]http.Header = undefined;
        var headers_len: usize = 0;
        headers_buffer[headers_len] = .{ .name = "content-type", .value = "application/json" };
        headers_len += 1;
        headers_buffer[headers_len] = .{ .name = "accept", .value = "text/event-stream" };
        headers_len += 1;
        self.pending_auth = try std.fmt.allocPrint(self.allocator, "{s}", .{h1_value});
        headers_buffer[headers_len] = .{ .name = h1_name, .value = self.pending_auth.? };
        headers_len += 1;
        headers_buffer[headers_len] = .{ .name = h2_name, .value = h2_value };
        headers_len += 1;
        const req = try self.allocator.create(Request);
        errdefer self.allocator.destroy(req);
        req.* = try self.request(.POST, uri, .{
            .extra_headers = headers_buffer[0..headers_len],
        });
        errdefer req.deinit();
        req.transfer_encoding = .{ .content_length = body_json.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body_json);
        try body_writer.end();
        try req.connection.?.flush();
        return req;
    }

    /// GET with TWO custom headers (e.g. `x-api-key` + `anthropic-version` for Anthropic).
    pub fn getWithDualHeaders(self: *HttpClient, url: []const u8, h1_name: []const u8, h1_value: []const u8, h2_name: []const u8, h2_value: []const u8) HttpError![]u8 {
        const uri = try std.Uri.parse(url);
        var headers_buffer: [2]http.Header = undefined;
        headers_buffer[0] = .{ .name = h1_name, .value = h1_value };
        headers_buffer[1] = .{ .name = h2_name, .value = h2_value };
        var req = try self.request(.GET, uri, .{ .extra_headers = headers_buffer[0..2] });
        defer req.deinit();
        try req.sendBodiless();
        var redirect_buffer: [8192]u8 = undefined;
        var response = try req.receiveHead(&redirect_buffer);
        return self.readBody(&response);
    }

    /// Like `postSse` but sends a custom header (e.g. `x-goog-api-key` for Gemini)
    /// instead of `Authorization: Bearer`. The header value is copied into
    /// `pending_auth` so it lives for the duration of the request.
    pub fn postSseWithCustomHeader(self: *HttpClient, url: []const u8, body_json: []const u8, header_name: []const u8, header_value: []const u8) HttpError!*Request {
        if (self.pending_auth) |auth| self.allocator.free(auth);
        self.pending_auth = null;
        const uri = try std.Uri.parse(url);
        var headers_buffer: [4]http.Header = undefined;
        var headers_len: usize = 0;
        headers_buffer[headers_len] = .{ .name = "content-type", .value = "application/json" };
        headers_len += 1;
        headers_buffer[headers_len] = .{ .name = "accept", .value = "text/event-stream" };
        headers_len += 1;
        self.pending_auth = try self.allocator.dupe(u8, header_value);
        headers_buffer[headers_len] = .{ .name = header_name, .value = self.pending_auth.? };
        headers_len += 1;
        const req = try self.allocator.create(Request);
        errdefer self.allocator.destroy(req);
        req.* = try self.request(.POST, uri, .{
            .extra_headers = headers_buffer[0..headers_len],
        });
        errdefer req.deinit();
        req.transfer_encoding = .{ .content_length = body_json.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body_json);
        try body_writer.end();
        try req.connection.?.flush();
        return req;
    }

    /// Inicia una petición POST streaming (SSE).
    /// Devuelve un Request listo para recibir la respuesta.
    pub fn postSse(self: *HttpClient, url: []const u8, body_json: []const u8, api_key: ?[]const u8) HttpError!*Request {
        if (self.pending_auth) |auth| self.allocator.free(auth);
        self.pending_auth = null;
        const uri = try std.Uri.parse(url);
        var headers_buffer: [4]http.Header = undefined;
        var headers_len: usize = 0;
        headers_buffer[headers_len] = .{ .name = "content-type", .value = "application/json" };
        headers_len += 1;
        headers_buffer[headers_len] = .{ .name = "accept", .value = "text/event-stream" };
        headers_len += 1;
        if (api_key) |key| {
            self.pending_auth = try std.fmt.allocPrint(self.allocator, "Bearer {s}", .{key});
            headers_buffer[headers_len] = .{ .name = "authorization", .value = self.pending_auth.? };
            headers_len += 1;
        }
        const req = try self.allocator.create(Request);
        errdefer self.allocator.destroy(req);
        req.* = try self.request(.POST, uri, .{
            .extra_headers = headers_buffer[0..headers_len],
        });
        errdefer req.deinit();
        req.transfer_encoding = .{ .content_length = body_json.len };
        var body_writer = try req.sendBodyUnflushed(&.{});
        try body_writer.writer.writeAll(body_json);
        try body_writer.end();
        try req.connection.?.flush();
        return req;
    }
};

// ── Helperes de plazo de socket (P10) ───────────────────────────────────
//
// Estos tres van al MISMO nivel que el struct a propósito: son funciones libres
// que reciben el handle, no métodos. El struct no guarda estado de configuración
// de socket porque el pool de std.http reutiliza conexiones: el plazo se aplica a
// CADA Request en el momento en que se crea (applySocketTimeouts), que es cuando
// `req.connection` no es nulo. Aplicarlo en init no serviría — no hay socket aún.

/// P10: SO_RCVTIMEO/SO_SNDTIMEO tal como los define ws2_32 (4102/4101).
pub const WindowsSockOpt = enum(u32) { rcv = 4102, snd = 4101 };

test "P10: los plazos por defecto son los documentados (WS2: 4102/4101)" {
    try std.testing.expectEqual(@as(u32, 4102), @intFromEnum(WindowsSockOpt.rcv));
    try std.testing.expectEqual(@as(u32, 4101), @intFromEnum(WindowsSockOpt.snd));
    try std.testing.expect(DEFAULT_SOCKET_RECV_TIMEOUT_SECONDS > 0);
    try std.testing.expect(DEFAULT_SOCKET_SEND_TIMEOUT_SECONDS > 0);
}

fn windowsSockOpt(kind: WindowsSockOpt) u32 {
    return @intFromEnum(kind);
}

/// Aplica un SO_RCVTIMEO/SO_SNDTIMEO en un socket de Windows. Best-effort:
/// devolver un error aquí NO puede tumbar una llamada que de otra forma
/// funcionaría.
///
/// P10-MEDICIÓN (2026-08-07): en este Zig con Io, los sockets de Windows son
/// AFD crudos (NtCreateFile, sin Winsock), y SO_RCVTIMEO/SO_SNDTIMEO los emula
/// la capa de usuario de ws2_32, no el kernel. Verificado en vivo contra un
/// servidor local que acepta y nunca responde:
///   - IOCTL.AFD.SOCKOPT con optname 4102/4101 -> NOT_SUPPORTED (afd.sys no
///     reconoce la opción; REUSE_UNICASTPORT sí se acepta, así el mecanismo
///     en sí funciona).
///   - ws2_32.setsockopt sobre el mismo handle -> WSANOTINITIALISED (10093):
///     el proceso jamás llama WSAStartup, el handle no es un SOCKET conocido.
/// Por eso aquí se intenta por las dos vías y se ignora el resultado: en esta
/// plataforma el plazo REAL debe darse en el nivel de `Io` (cancelar la
/// operación pendiente), no en el socket. En POSIX las opciones sí existen y
/// este código es exactamente lo que hace falta.
fn setWindowsSocketTimeout(handle: std.posix.fd_t, optname: u32, seconds: u32) void {
    const windows = std.os.windows;
    var tv = windows.ws2_32.timeval{ .sec = @bitCast(seconds), .usec = 0 };
    var info = windows.AFD.SOCKOPT_INFO{
        .mode = .set,
        .level = windows.ws2_32.SOL.SOCKET,
        .optname = optname,
        .optval = &tv,
        .optlen = @sizeOf(windows.ws2_32.timeval),
    };
    var iosb: windows.IO_STATUS_BLOCK = undefined;
    _ = windows.ntdll.NtDeviceIoControlFile(
        handle,
        null, // event
        null, // apc routine
        null, // apc context
        &iosb,
        windows.IOCTL.AFD.SOCKOPT,
        &info,
        @sizeOf(windows.AFD.SOCKOPT_INFO),
        null, // output
        0,
    );
}

/// Aplica un SO_RCVTIMEO/SO_SNDTIMEO en un socket POSIX.
fn setPosixSocketTimeout(handle: std.posix.fd_t, optname: u32, seconds: u32) void {
    var tv: std.posix.timeval = .{ .sec = seconds, .usec = 0 };
    std.posix.setsockopt(
        handle,
        std.posix.SOL.SOCKET,
        optname,
        std.mem.asBytes(&tv),
    ) catch {};
}

// ── Tests ──────────────────────────────────────────────────────────────

test "http client init and deinit" {
    const allocator = std.testing.allocator;
    var client = try HttpClient.init(allocator);
    defer client.deinit();
    try std.testing.expectEqual(DEFAULT_MAX_RESPONSE_BYTES, client.max_response_bytes);
}

test "SEC-RED initForUrl rechaza HTTP remoto antes de conectar" {
    const result = HttpClient.initForUrl(std.testing.allocator, "http://example.invalid/v1");
    if (result) |value| {
        var client = value;
        client.deinit();
        return error.TestUnexpectedResult;
    } else |err| try std.testing.expectEqualStrings("InsecureCredentialTransport", @errorName(err));
}

test "SEC-RED envio final rechaza secretos en cuerpo query y cabecera tardia" {
    var buffer: [512]u8 = undefined;
    const len = GetEnvironmentVariableA("BEATS_SEC_RED_URL", &buffer, buffer.len);
    if (len == 0 or len >= buffer.len) return error.MissingSecurityFixture;
    var client = try HttpClient.initForUrl(std.testing.allocator, buffer[0..len]);
    defer client.deinit();
    for (0..3) |kind| {
        var req = try client.request(if (kind == 0) .POST else .GET, try std.Uri.parse(buffer[0..len]), .{});
        defer req.deinit();
        req.uri = try std.Uri.parse(if (kind == 1) "http://192.0.2.1/?token=fixture-key" else "http://192.0.2.1/");
        if (kind == 0) {
            req.transfer_encoding = .{ .content_length = "fixture-key".len };
            try std.testing.expectError(error.InsecureCredentialTransport, req.sendBodyUnflushed(&.{}));
        } else {
            if (kind == 2) req.extra_headers = &.{.{ .name = "x-late", .value = "fixture-key" }};
            try std.testing.expectError(error.InsecureCredentialTransport, req.sendBodiless());
        }
    }
}

test "SEC-RED HTTP publico requiere marca explicita sin cuerpo query ni secretos" {
    var client = try HttpClient.initForUrl(std.testing.allocator, "http://127.0.0.1:1");
    defer client.deinit();
    const remote = try std.Uri.parse("http://192.0.2.1/");
    var private = try client.request(.GET, remote, .{});
    defer private.deinit();
    try std.testing.expectError(error.InsecureCredentialTransport, private.sendBodiless());
    try std.testing.expectError(error.InsecureCredentialTransport, client.get("http://192.0.2.1/?key=fixture-key"));
    try std.testing.expectError(error.InsecureCredentialTransport, client.postJson("http://192.0.2.1/", "fixture-key", null));
    var public = try client.requestWithPolicy(.GET, remote, .{}, .{ .public_redirects = true });
    defer public.deinit();
    // Comprobar la excepcion sin conectar a ningun destino remoto real.
    try public.validateForSend(false);
    for (0..5) |kind| {
        var req = try client.requestWithPolicy(if (kind == 0) .POST else .GET, remote, .{}, .{ .public_redirects = true });
        defer req.deinit();
        switch (kind) {
            0 => req.transfer_encoding = .{ .content_length = 0 },
            1 => req.uri = try std.Uri.parse("http://192.0.2.1/?key=fixture-key"),
            2 => req.extra_headers = &.{.{ .name = "x-late", .value = "fixture-key" }},
            3 => req.privileged_headers = &.{.{ .name = "x-late", .value = "fixture-key" }},
            else => req.headers.authorization = .{ .override = "fixture-key" },
        }
        if (kind == 0) {
            try std.testing.expectError(error.InsecureCredentialTransport, req.sendBodyUnflushed(&.{}));
        } else try std.testing.expectError(error.InsecureCredentialTransport, req.sendBodiless());
        try std.testing.expect(req.inner == null);
    }
}

test "SEC-RED connectionUri conserva localhost HTTPS para SNI y certificado" {
    for ([_][]const u8{ "https://localhost:8443/v1", "HTTPS://LOCALHOST/v1" }) |url| {
        const uri = try std.Uri.parse(url);
        const connected = connectionUri(uri);
        try std.testing.expectEqualDeep(uri.host, connected.host);
        try std.testing.expectEqualStrings(uri.scheme, connected.scheme);
        try std.testing.expectEqual(uri.port, connected.port);
    }
    for ([_][]const u8{ "http://localhost:11434/v1", "HTTP://LOCALHOST/v1" }) |url| {
        const connected = connectionUri(try std.Uri.parse(url));
        try std.testing.expectEqualStrings("127.0.0.1", connected.host.?.raw);
    }
}

test "SEC-RED tabla de URL HTTPS y loopback real" {
    const accepted = [_][]const u8{
        "https://example.com/v1",      "HTTPS://example.com/v1",
        "http://127.0.0.1/v1",         "http://127.23.45.67:8000/v1",
        "http://127.255.255.255/v1",   "http://[::1]:8000/v1",
        "http://[0:0:0:0:0:0:0:1]/v1", "http://localhost:11434/v1",
        "http://LOCALHOST/v1",
    };
    for (accepted) |url| try validateCredentialUrl(url);
    const rejected = [_][]const u8{
        "http://example.com/v1",        "http://192.168.1.1/v1",
        "http://0.0.0.0/v1",            "http://128.0.0.1/v1",
        "http://127.0.0.1.nip.io/v1",   "http://localhost.evil.com/v1",
        "http://[::ffff:127.0.0.1]/v1", "http://[::ffff:192.168.1.1]/v1",
        "http://[::]/v1",               "http://127.1/v1",
        "http://2130706433/v1",         "http://0x7f000001/v1",
        "http://127.000.0.1/v1",        "http://localhost./v1",
        "http://localhost@evil.com/v1", "http://localhost%2eevil.com/v1",
        "http://%31%32%37.0.0.1/v1",    "file:///fixture",
        "http:///v1",                   "not a URL",
    };
    for (rejected) |url| {
        if (validateCredentialUrl(url)) |_| {
            std.debug.print("URL insegura aceptada: {s}\n", .{url});
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "SEC-RED peticion autentica vuelve a validar aunque init no recibiera URL" {
    var client = try HttpClient.initForUrl(std.testing.allocator, "http://127.0.0.1:1");
    defer client.deinit();
    try std.testing.expectError(error.InsecureCredentialTransport, client.getAuth("http://example.invalid", "fixture-key"));
    try std.testing.expectError(error.InsecureCredentialTransport, client.postJsonWithHeaders("http://example.invalid", "{}", &.{.{ .name = "X-New-Secret", .value = "fixture-key" }}));
    var req = try client.request(.GET, try std.Uri.parse("http://example.invalid"), .{ .headers = .{ .authorization = .{ .override = "fixture-key" } } });
    defer req.deinit();
    try std.testing.expectError(error.InsecureCredentialTransport, req.sendBodiless());
    try std.testing.expectError(error.InsecureCredentialTransport, client.getWithDualHeaders("http://localhost.:1", "x-title", "fixture-key", "anthropic-version", "fixture-key"));
}

test "SEC-RED origen completo compara esquema host y puerto efectivo" {
    const origin = try std.Uri.parse("https://example.com/path");
    try std.testing.expect(sameOrigin(origin, try std.Uri.parse("HTTPS://EXAMPLE.COM:443/other")));
    for ([_][]const u8{ "http://example.com/", "https://other.example/", "https://example.com:444/", "https://user@example.com/", "https://example.com.evil/" }) |url| {
        try std.testing.expect(!sameOrigin(origin, try std.Uri.parse(url)));
    }
}

test "SEC-RED todos los metodos crean peticiones por el punto protegido" {
    // Evita que un método nuevo vuelva al transporte sin aplicar la política.
    const source = @embedFile("client.zig");
    const direct = ".client." ++ "request(";
    const first = std.mem.indexOf(u8, source, direct) orelse return error.TestUnexpectedResult;
    try std.testing.expect(std.mem.indexOf(u8, source[first + direct.len ..], direct) == null);
    try std.testing.expect(std.mem.indexOf(u8, source, ".client." ++ "fetch(") == null);
}

const GetEnvironmentVariableA = @import("../platform.zig").env;

test "SEC-RED GET y POST con credenciales no siguen redirecciones a otro puerto" {
    var buffer: [512]u8 = undefined;
    const len = GetEnvironmentVariableA("BEATS_SEC_RED_URL", &buffer, buffer.len);
    if (len == 0 or len >= buffer.len) return error.MissingSecurityFixture;
    const url = buffer[0..len];
    var client = try HttpClient.initForUrl(std.testing.allocator, url);
    defer client.deinit();
    try std.testing.expectError(error.RedirectBlocked, client.getAuth(url, "fixture-key"));
    try std.testing.expectError(error.RedirectBlocked, client.postJson(url, "{}", "fixture-key"));
    for ([_][]const u8{ "X-Api-Key", "api-key", "x-goog-api-key", "X-Subscription-Token", "Private-Token", "Cookie", "x-custom-credential", "x-title", "anthropic-version", "x-unknown-header" }) |name| {
        try std.testing.expectError(error.RedirectBlocked, client.getWithHeader(url, name, "fixture-key"));
        try std.testing.expectError(error.RedirectBlocked, client.postJsonWithHeaders(url, "{}", &.{.{ .name = name, .value = "fixture-key" }}));
    }
    try std.testing.expectError(error.RedirectBlocked, client.getWithDualHeaders(url, "x-api-key", "fixture-key", "anthropic-version", "2023-06-01"));
    for ([_][]const u8{ "x-title", "anthropic-version", "x-unknown-header" }) |name| {
        try std.testing.expectError(error.RedirectBlocked, client.getWithDualHeaders(url, name, "fixture-key", "anthropic-version", "2023-06-01"));
        try std.testing.expectError(error.RedirectBlocked, client.getWithDualHeaders(url, "x-title", "metadata", name, "fixture-key"));
        for (0..2) |kind| {
            const req = if (kind == 0) try client.postSseWithCustomHeader(url, "{}", name, "fixture-key") else try client.postSseWithDualHeaders(url, "{}", "x-title", "metadata", name, "fixture-key");
            defer client.allocator.destroy(req);
            defer req.deinit();
            try std.testing.expectError(error.RedirectBlocked, req.receiveHead(&.{}));
        }
    }
    // El opt-out de std.http no puede habilitar redirects sin política pública.
    var default_req = try client.request(.GET, try std.Uri.parse(url), .{ .redirect_behavior = .unhandled });
    defer default_req.deinit();
    try default_req.sendBodiless();
    try std.testing.expectError(error.RedirectBlocked, default_req.receiveHead(&.{}));
    var built_in_req = try client.request(.GET, try std.Uri.parse(url), .{ .headers = .{ .user_agent = .{ .override = "fixture-key" } } });
    defer built_in_req.deinit();
    try built_in_req.sendBodiless();
    try std.testing.expectError(error.RedirectBlocked, built_in_req.receiveHead(&.{}));
    var privileged_req = try client.request(.GET, try std.Uri.parse(url), .{ .privileged_headers = &.{.{ .name = "x-title", .value = "fixture-key" }} });
    defer privileged_req.deinit();
    try privileged_req.sendBodiless();
    try std.testing.expectError(error.RedirectBlocked, privileged_req.receiveHead(&.{}));
    for (0..3) |kind| {
        const req = switch (kind) {
            0 => try client.postSse(url, "{}", "fixture-key"),
            1 => try client.postSseWithCustomHeader(url, "{}", "x-goog-api-key", "fixture-key"),
            else => try client.postSseWithDualHeaders(url, "{}", "x-api-key", "fixture-key", "anthropic-version", "2023-06-01"),
        };
        defer client.allocator.destroy(req);
        defer req.deinit();
        var redirect: [8192]u8 = undefined;
        try std.testing.expectError(error.RedirectBlocked, req.receiveHead(&redirect));
    }
    // Ni el GET público puede cambiar de origen (el puerto forma parte de él).
    const public_url = try std.fmt.allocPrint(client.allocator, "{s}/public", .{url});
    defer client.allocator.free(public_url);
    try std.testing.expectError(error.HttpRedirectCrossOrigin, client.getPublic(public_url));
    const same_origin_url = try std.fmt.allocPrint(client.allocator, "{s}/same-origin", .{url});
    defer client.allocator.free(same_origin_url);
    const body = try client.getPublic(same_origin_url);
    defer client.allocator.free(body);
    try std.testing.expectEqualStrings("{}", body);
    for ([_][]const u8{ "localhost", "LOCALHOST" }) |host| {
        const local_url = try std.fmt.allocPrint(client.allocator, "http://{s}:{d}/same-origin-sink", .{ host, (try std.Uri.parse(url)).port.? });
        defer client.allocator.free(local_url);
        var local_req = try client.request(.GET, try std.Uri.parse(local_url), .{});
        defer local_req.deinit();
        try local_req.sendBodiless();
        try std.testing.expectEqualStrings("127.0.0.1", local_req.inner.?.uri.host.?.raw);
        var local_response = try local_req.receiveHead(&.{});
        const local_body = try client.readBody(&local_response);
        defer client.allocator.free(local_body);
        try std.testing.expectEqualStrings("{}", local_body);
    }
}

test "LOCAL-JSON SEC-RED HTTP init does not require certificates and rejects unsupported schemes" {
    var client = try HttpClient.initForUrl(std.testing.allocator, "http://127.0.0.1:1");
    defer client.deinit();
    try std.testing.expectEqual(@as(usize, 0), client.client.ca_bundle.bytes.items.len);
    try std.testing.expectError(error.UnsupportedScheme, HttpClient.initForUrl(std.testing.allocator, "file:///fixture"));
    try std.testing.expectError(error.UnsupportedScheme, validateCredentialUrl("file:///fixture"));
    try std.testing.expectError(error.UriMissingHost, HttpClient.initForUrl(std.testing.allocator, "http:/fixture"));
    try std.testing.expectError(error.UriMissingHost, HttpClient.initForUrl(std.testing.allocator, "https:/fixture"));
    try std.testing.expectError(error.InvalidFormat, HttpClient.initForUrl(std.testing.allocator, "not a URL"));
}

test "http client readLimited caps at max_response_bytes" {
    const allocator = std.testing.allocator;
    var client = try HttpClient.init(allocator);
    defer client.deinit();
    client.max_response_bytes = 32; // tiny limit for test
    // Simulate a 1 KB response body (far exceeds 32 bytes).
    const big_data = "A" ** 1024;
    var reader: std.Io.Reader = .fixed(big_data);
    const result = client.readLimited(&reader);
    try std.testing.expectError(error.ResponseTooLarge, result);
}

test "http client readLimited succeeds within limit" {
    const allocator = std.testing.allocator;
    var client = try HttpClient.init(allocator);
    defer client.deinit();
    client.max_response_bytes = 64;
    const small_data = "Hello, world!";
    var reader: std.Io.Reader = .fixed(small_data);
    const body = try client.readLimited(&reader);
    defer allocator.free(body);
    try std.testing.expectEqualStrings(small_data, body);
}
