//! D1 tramo 2 — el plazo de socket, bajo la capa TLS del cliente real.
//!
//! ## Qué problema cierra este archivo
//!
//! El tramo 1 (`poll_socket.zig`) demostró con sockets crudos que una lectura
//! con `WSAPoll` y plazo propio devuelve el hilo SIEMPRE. Pero el cliente HTTP
//! real (`HttpClient`) usa `std.Io.Threaded`, cuya lectura de AFD no tiene
//! punto de plazo — y las dos vías documentadas que quedaban (`CancelIoEx`
//! sobre AFD, `SO_RCVTIMEO` sobre AFD) están medidas y muertas: la primera
//! despierta el `recv` pero `netReadWindows` tiene un `.CANCELLED =>
//! unreachable` que convierte el rescate en pánico; la segunda devuelve
//! NOT_SUPPORTED (la emula la capa de usuario de ws2_32, no afd.sys).
//!
//! ## Cómo funciona (y por qué un threadlocal)
//!
//! Un `Io` de envoltorio cuya vtable es la del `Threaded` con DOS entradas
//! sustituidas: `netRead` y `netConnectIp`. El `userdata` SIGUE SIENDO el
//! `*Threaded` — las 110 funciones restantes (alloc, fs, TLS, locks) reciben
//! exactamente lo que esperan, que es lo que hace invisible al envoltorio.
//!
//! El plazo no puede viajar en el userdata (ya ocupado), así que viaja en un
//! `threadlocal` que el `HttpClient` fija al crear cada Request y retira al
//! terminarlo (`applySocketTimeouts` ya se llama por cada Request). Las
//! lecturas de esa Request — TLS incluido, SSE incluido — corren en el mismo
//! hilo que la creó, que es exactamente el hilo que lee la variable.
//!
//! Al vencer, un vigilante hace `shutdown(both)` del socket: el único
//! mecanismo que H5 midió válido para despertar un `recv` AFD bloqueado (a
//! diferencia de `CancelIoEx`, que despierta con `CANCELLED` y hace saltar el
//! `unreachable` de la std). La lectura vuelve con el error del RST y el
//! trampolín lo clasifica como `error.Timeout`: la semántica POSIX de
//! `SO_RCVTIMEO` — la operación venció, no falló la red.
//!
//! ## Qué NO es
//!
//! No es cancelación fina: al vencer, el socket muere y el pool recoge la
//! conexión; la siguiente va por conexión nueva. El `connect` TCP sigue sin
//! plazo propio (el `Threaded` de este Zig pánica con «TODO implement
//! netConnectIpWindows with timeout» si se le pide): contra un endpoint muerto
//! falla solo por ETIMEDOUT del kernel (~21 s), como siempre.

const std = @import("std");
const builtin = @import("builtin");
const Io = std.Io;

extern "kernel32" fn CreateEventW(lpEventAttributes: ?*anyopaque, bManualReset: c_int, bInitialState: c_int, lpName: ?[*:0]const u16) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn CloseHandle(hObject: ?*anyopaque) callconv(.winapi) c_int;
extern "kernel32" fn WaitForSingleObject(hHandle: ?*anyopaque, dwMilliseconds: u32) callconv(.winapi) u32;
extern "kernel32" fn SetEvent(hEvent: *anyopaque) callconv(.winapi) c_int;
const Sleep = @import("../platform.zig").sleep;
const GetTickCount64 = @import("../platform.zig").ticks;

/// El plazo de las operaciones de red de ESTE hilo, en ms. Lo fija
/// `HttpClient` alrededor de cada Request (ver `client.zig`). 0 = sin plazo.
pub threadlocal var current_deadline_ms: u32 = 0;
/// Absolute call deadline installed by the worker on the actual HTTP thread.
/// Unlike a per-read timeout, heartbeats cannot renew this budget.
pub threadlocal var current_deadline_at_ms: u64 = 0;

/// Vtable única del envoltorio: la del Threaded con netRead/netConnectIp
/// sustituidas. Se inicializa UNA vez (todas las instancias comparten la
/// misma: el userdata es siempre el `*Threaded` de turno).
var wrapped_vtable: Io.VTable = undefined;
var wrapped_vtable_ready = false;

/// El Io envuelto para un Threaded. El userdata ES el *Threaded: todas las
/// funciones delegadas del resto de la vtable funcionan sin enterarse.
pub fn wrapIo(t: *Io.Threaded) Io {
    const base = t.io();
    if (!wrapped_vtable_ready) {
        // Clonación en dos entradas. Todo lo demás apunta a la MISMA función
        // que el Threaded original: cero comportamiento nuevo fuera de red.
        wrapped_vtable = base.vtable.*;
        wrapped_vtable.netRead = netReadWithDeadline;
        wrapped_vtable.netConnectIp = netConnectIpPassthrough;
        wrapped_vtable_ready = true;
    }
    return .{ .userdata = base.userdata, .vtable = &wrapped_vtable };
}

const WatchdogCtx = struct {
    base: Io,
    handle: Io.net.Socket.Handle,
    deadline_ms: u32,
    cancel_ev: *anyopaque,
};

/// netRead con plazo REAL: ioctl AFD.RECEIVE con evento propio.
///
/// No usa la espera APC de la std (`Threaded.deviceIoControl`) a propósito:
/// esa vía, al recibir un `NtCancelIoFileEx`, cae en el `.CANCELLED =>
/// unreachable` de `netReadWindows` y mata el proceso — medido en H5. Aquí el
/// ioctl se lanza con un EVENTO y se espera con `WaitForSingleObject(ev,
/// plazo)`: el plazo es NATIVO del kernel, sin hilo vigilante. Si vence, se
/// cancela con `NtCancelIoFileEx` y el CANCELLED que llega en el
/// IO_STATUS_BLOCK lo clasifica ESTE código como `error.Timeout` — la
/// semántica POSIX de SO_RCVTIMEO, que ni afd.sys ni el `unreachable` de la
/// std permitían tener.
///
/// El precio: replicar ~40 líneas de la maquinaria AFD de la std (iovecs,
/// RECV_INFO, interpretación del iosb) en lugar de delegar la lectura. Es el
/// camino que el propio H5 dejó señalado: «el plazo real en Windows debe
/// vivirse en la capa Io, fuera del socket» — esta ES la capa Io, con el
/// manejo de CANCELLED corregido.
const afd = std.os.windows.AFD;
const IO_STATUS_BLOCK = std.os.windows.IO_STATUS_BLOCK;

extern "ntdll" fn NtDeviceIoControlFile(
    FileHandle: std.os.windows.HANDLE,
    Event: ?std.os.windows.HANDLE,
    ApcRoutine: ?*align(2) const anyopaque,
    ApcContext: ?*anyopaque,
    IoStatusBlock: *IO_STATUS_BLOCK,
    IoControlCode: std.os.windows.CTL_CODE,
    InputBuffer: ?*const anyopaque,
    InputBufferLength: std.os.windows.ULONG,
    OutputBuffer: ?std.os.windows.PVOID,
    OutputBufferLength: std.os.windows.ULONG,
) callconv(.winapi) std.os.windows.NTSTATUS;
extern "ntdll" fn NtCancelIoFileEx(
    FileHandle: std.os.windows.HANDLE,
    IoRequestToCancel: *const IO_STATUS_BLOCK,
    IoStatusBlock: *IO_STATUS_BLOCK,
) callconv(.winapi) std.os.windows.NTSTATUS;

fn netReadWithDeadline(userdata: ?*anyopaque, socket_handle: Io.net.Socket.Handle, data: [][]u8) Io.net.Stream.Reader.Error!usize {
    const t: *Io.Threaded = @ptrCast(@alignCast(userdata.?));
    const base = t.io();
    var deadline = current_deadline_ms;
    if (current_deadline_at_ms != 0 and builtin.os.tag == .windows) {
        const remaining = current_deadline_at_ms -| GetTickCount64();
        if (remaining == 0) return error.Timeout;
        const bounded: u32 = @intCast(@min(remaining, std.math.maxInt(u32) - 1));
        deadline = if (deadline == 0) bounded else @min(deadline, bounded);
    }
    if (deadline == 0 or builtin.os.tag != .windows) {
        return base.vtable.netRead(base.userdata, socket_handle, data);
    }

    // Iovecs y RECV_INFO con el mismo formato exacto que la std (ver
    // Threaded.netReadWindows): si algo diverge, el kernel devuelve un
    // NTSTATUS que clasificamos abajo.
    var iovecs: [8]afd.WSABUF(.@"var") = undefined;
    var len: std.os.windows.ULONG = 0;
    for (data) |buf| {
        if (iovecs.len - len == 0) break;
        iovecs[len] = .{ .len = @intCast(buf.len), .buf = buf.ptr };
        len += 1;
    }
    if (len == 0) return 0;

    var recv_info = afd.RECV_INFO{
        .BufferArray = &iovecs,
        .BufferCount = len,
        .AfdFlags = .{ .NO_FAST_IO = true, .OVERLAPPED = true },
        .TdiFlags = .{ .NORMAL = true },
    };
    var iosb: IO_STATUS_BLOCK = undefined;
    const ev = CreateEventW(null, 0, 0, null) orelse
        return base.vtable.netRead(base.userdata, socket_handle, data);
    defer _ = CloseHandle(ev);

    const status: std.os.windows.NTSTATUS = NtDeviceIoControlFile(
        socket_handle,
        ev, // evento (no APC): WaitForSingleObject puede esperar CON PLAZO
        null,
        null,
        &iosb,
        std.os.windows.IOCTL.AFD.RECEIVE,
        &recv_info,
        @sizeOf(afd.RECV_INFO),
        null,
        0,
    );

    // PENDING = la lectura quedó en vuelo; TODO lo demás completó YA en el iosb.
    if (status != .PENDING) {
        return classifyAfd(status, iosb);
    }

    // El plazo NATIVO del kernel. WAIT_TIMEOUT (258) = venció: cancelar y
    // esperar a que el kernel firme la cancelación en el iosb. El kernel
    // firma CANCELLED en el request — pero la firma es asincrónica respecto
    // al retorno de NtCancelIoFileEx, de ahí la segunda espera.
    var cancelled = false;
    var wait = WaitForSingleObject(ev, deadline);
    if (wait != 0) {
        cancelled = true;
        _ = NtCancelIoFileEx(socket_handle, &iosb, &iosb);
        wait = WaitForSingleObject(ev, 10_000);
        if (wait != 0) {
            // El kernel no firmó la cancelación en 10 s: no debería ocurrir,
            // pero colgarse aquí sería un hilo perdido. Se devuelve Timeout:
            // el socket queda en estado indefinido y el pool lo recogerá.
            return error.Timeout;
        }
    }

    // Tras una cancelación, TODO lo que diga el iosb es la cancelación: la
    // lectura venció. (Visto en vivo: el kernel puede firmar SUCCESS con
    // Information=0 en la carrera de la cancelación — un cero que ahí NO
    // significa EOF sino «no hay lectura».)
    if (cancelled) return error.Timeout;

    return classifyAfd(iosb.u.Status, iosb);
}

/// Clasifica el NTSTATUS final de una lectura AFD con el MISMO mapeo que
/// `netReadWindows`, salvo en lo que aquí importa: CANCELLED es un TIMEOUT,
/// no un `unreachable`.
fn classifyAfd(status: std.os.windows.NTSTATUS, iosb: IO_STATUS_BLOCK) Io.net.Stream.Reader.Error!usize {
    switch (status) {
        .SUCCESS => return @intCast(iosb.Information),
        .INSUFFICIENT_RESOURCES => return error.SystemResources,
        .CANCELLED => return error.Timeout,
        else => {
            // Mapeo de red idéntico al de netReadWindows de la std, sin la
            // traza de unexpectedStatus (que ensuciaría el stderr del host).
            const w = std.os.windows;
            const code = @intFromEnum(status);
            if (code == @intFromEnum(w.NTSTATUS.CONNECTION_RESET) or
                code == @intFromEnum(w.NTSTATUS.CONNECTION_ABORTED) or
                code == @intFromEnum(w.NTSTATUS.GRACEFUL_DISCONNECT))
            {
                return error.ConnectionResetByPeer;
            }
            return error.Unexpected;
        },
    }
}

/// netConnect pasa por el Threaded tal cual (el plazo de connect no existe en
/// este fork: la vtable original pánica si se le pide timeout). Trampolín
/// explícito para que la sustitución quede documentada en la vtable.
fn netConnectIpPassthrough(
    userdata: ?*anyopaque,
    address: *const Io.net.IpAddress,
    options: Io.net.IpAddress.ConnectOptions,
) Io.net.IpAddress.ConnectError!Io.net.Socket {
    const t: *Io.Threaded = @ptrCast(@alignCast(userdata.?));
    const base = t.io();
    return base.vtable.netConnectIp(base.userdata, address, options);
}

// ── Tests ──────────────────────────────────────────────────────────────

test "deadline absolute call budget bounds reads even with silence timeout disabled" {
    if (builtin.os.tag != .windows) return @import("../platform.zig").skip("T9: el envoltorio de plazo actua sobre AFD de Windows (NtDeviceIoControlFile, NtCancelIoFileEx); omitida en Linux");
    var threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const base = threaded.io();
    const wrapped = wrapIo(&threaded);
    var address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(base, .{});
    defer server.deinit(base);
    var addr = try Io.net.IpAddress.parse("127.0.0.1", server.socket.address.getPort());
    const socket = try wrapped.vtable.netConnectIp(wrapped.userdata, &addr, .{ .mode = .stream, .protocol = .tcp });
    defer socket.close(wrapped);
    const peer = try server.accept(base);
    defer peer.close(base);
    current_deadline_ms = 0;
    current_deadline_at_ms = GetTickCount64() + 100;
    defer current_deadline_at_ms = 0;
    var buf: [1]u8 = undefined;
    var vect = [_][]u8{&buf};
    const started = GetTickCount64();
    try std.testing.expectError(error.Timeout, wrapped.vtable.netRead(wrapped.userdata, socket.handle, &vect));
    const elapsed = GetTickCount64() - started;
    try std.testing.expect(elapsed >= 70 and elapsed < 2000);
    // A second read has no fresh allowance: the absolute call budget expired.
    const again = GetTickCount64();
    try std.testing.expectError(error.Timeout, wrapped.vtable.netRead(wrapped.userdata, socket.handle, &vect));
    try std.testing.expect(GetTickCount64() - again < 100);
}

test "D1-T2: la vtable del envoltorio delega TODO menos netRead" {
    var threaded = Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    const base = threaded.io();

    const wrapped = wrapIo(&threaded);

    // netRead/netConnect sustituidas; el resto, la MISMA dirección de función
    // que el Threaded original (clonación, no reimplementación).
    try std.testing.expect(wrapped.vtable.netRead == &netReadWithDeadline);
    try std.testing.expect(wrapped.vtable.netConnectIp == &netConnectIpPassthrough);
    try std.testing.expect(wrapped.vtable.netSend == base.vtable.netSend);
    try std.testing.expect(wrapped.vtable.netShutdown == base.vtable.netShutdown);
    try std.testing.expect(wrapped.vtable.crashHandler == base.vtable.crashHandler);
    // Y el userdata es el *Threaded: las funciones delegadas reciben lo suyo.
    try std.testing.expectEqual(base.userdata, wrapped.userdata);
}

test "D1-T2: contra el servidor sordo, el ENVOLTORIO devuelve el hilo con el plazo" {
    if (builtin.os.tag != .windows) return @import("../platform.zig").skip("T9: el envoltorio de plazo actua sobre AFD de Windows (NtDeviceIoControlFile, NtCancelIoFileEx); omitida en Linux");

    const allocator = std.testing.allocator;
    var threaded = Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const base = threaded.io();
    const wrapped = wrapIo(&threaded);

    // Servidor sordo: acepta y no contesta jamás (mismo molde que
    // poll_socket.zig, replicado para no cruzar capas en un test).
    var address = try Io.net.IpAddress.parse("127.0.0.1", 0);
    var server = try address.listen(base, .{});
    defer server.deinit(base);
    // El plazo de ESTE hilo (el threadlocal que fija el cliente por Request).
    current_deadline_ms = 400;
    defer current_deadline_ms = 0;

    // Conectar y leer por el Io envuelto: la lectura debe volver sola.
    var addr = try Io.net.IpAddress.parse("127.0.0.1", server.socket.address.getPort());
    const options: Io.net.IpAddress.ConnectOptions = .{ .mode = .stream, .protocol = .tcp };
    const socket = try wrapped.vtable.netConnectIp(wrapped.userdata, &addr, options);
    defer socket.close(wrapped);
    // El kernel encola connect aunque nadie haya llamado accept todavía.
    // Conservar el peer aquí evita un hilo servidor bloqueado en accept cuando
    // falle cualquier operación anterior. Todos los sockets tienen defer.
    const peer = try server.accept(base);
    defer peer.close(base);

    var buf: [64]u8 = undefined;
    var vect: [1][]u8 = .{&buf};
    const t0 = GetTickCount64();
    const r = wrapped.vtable.netRead(wrapped.userdata, socket.handle, &vect);
    const ms = GetTickCount64() - t0;

    // Volvió (no se colgó) con TIMEOUT: la cancelación nativa del kernel
    // (NtCancelIoFileEx) despertó la lectura y el trampolín la clasificó.
    try std.testing.expectError(error.Timeout, r);
    // Y volvió EN el plazo: techo holgado para CI lento, pero un techo claro:
    // SIN el plazo esta lectura no vuelve NUNCA (H5 lo midió: 60 s dentro).
    try std.testing.expect(ms < 5000);
    try std.testing.expect(ms >= 300);
}
