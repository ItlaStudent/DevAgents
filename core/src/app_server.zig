//! T6 (13-nov-2026,): servidores de desarrollo del proyecto para
//! app_server_start / app_server_stop / app_server_logs.
//!
//! - La configuración sale de `.devagents/launch.json` o `.claude/launch.json`
//!   del espacio de la orden (lectura confinada, nunca fuera de la carpeta).
//! - El proceso lo lanza `executor.runGoverned`, el mismo ejecutor gobernado
//!   que `run_command` (lista de programas, carpeta dentro del espacio, job
//!   object que mata el árbol entero), en un hilo propio y con la señal de
//!   cancelación de este registro: parar = cancelar ese ejecutor.
//! - La salida queda en un registro acotado (LOG_CAPACITY bytes por servidor);
//!   lo más antiguo se descarta y se cuenta.
//! - El registro vive en el `browser_service.Service` de la orden: al terminar
//!   la orden (`cancelOrder`) o al liberarse el servicio se paran todos.
const std = @import("std");
const executor = @import("executor.zig");
const confined_fs = @import("confined_fs.zig");
const sync = @import("sync.zig");

pub const MAX_SERVERS = 4;
pub const LOG_CAPACITY = 256 * 1024;
pub const CONFIG_FILES = [_][]const u8{ ".devagents/launch.json", ".claude/launch.json" };
const CONFIG_MAX_BYTES = 64 * 1024;
const MAX_RUNTIME_ARGS = 64;

pub const Stream = enum { stdout, stderr };

pub const Config = struct {
    arena: std.heap.ArenaAllocator,
    name: []const u8,
    exe: []const u8,
    args: []const []const u8,
    /// Ruta absoluta (raíz del espacio o `cwd` de la configuración resuelta
    /// contra ella); el ejecutor comprueba que sigue dentro del espacio.
    cwd: []const u8,
    /// Raíz del espacio (copia propia: el hilo del servidor la usa como
    /// raíz del sandbox después de que vuelva quien lo arrancó).
    root: []const u8,
    port: u16,

    pub fn forCommand(a: std.mem.Allocator, root: []const u8, exe: []const u8, args: []const []const u8, cwd: []const u8) !Config {
        var arena = std.heap.ArenaAllocator.init(a);
        errdefer arena.deinit();
        const owned = arena.allocator();
        const argv = try owned.alloc([]const u8, args.len);
        for (args, argv) |arg, *destination| destination.* = try owned.dupe(u8, arg);
        const config: Config = .{
            .arena = undefined,
            .name = "",
            .exe = try owned.dupe(u8, exe),
            .args = argv,
            .cwd = try owned.dupe(u8, cwd),
            .root = try owned.dupe(u8, root),
            .port = 0,
        };
        var result = config;
        result.arena = arena;
        return result;
    }

    pub fn deinit(self: *Config) void {
        self.arena.deinit();
    }
};

pub const ConfigError = error{ ConfigNotFound, InvalidConfig, OutOfMemory };

/// Busca la configuración `name` en los launch.json del espacio. Un archivo
/// ausente se salta; uno ilegible o mal formado es InvalidConfig (nunca se
/// adivina un comando).
pub fn loadConfig(a: std.mem.Allocator, workspace_root: []const u8, name: []const u8) ConfigError!Config {
    var root = confined_fs.Root.init(a, workspace_root) catch return error.ConfigNotFound;
    defer root.deinit();
    for (CONFIG_FILES) |relative| {
        const body = root.readFileAlloc(a, relative, CONFIG_MAX_BYTES) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.FileNotFound => continue,
            else => return error.InvalidConfig,
        };
        defer a.free(body);
        if (try parseConfig(a, body, workspace_root, name)) |config| return config;
    }
    return error.ConfigNotFound;
}

fn parseConfig(a: std.mem.Allocator, body: []const u8, workspace_root: []const u8, name: []const u8) ConfigError!?Config {
    var arena = std.heap.ArenaAllocator.init(a);
    errdefer arena.deinit();
    const aa = arena.allocator();
    const root = std.json.parseFromSliceLeaky(std.json.Value, aa, body, .{}) catch return error.InvalidConfig;
    if (root != .object) return error.InvalidConfig;
    const list = root.object.get("configurations") orelse return error.InvalidConfig;
    if (list != .array) return error.InvalidConfig;
    for (list.array.items) |item| {
        if (item != .object) return error.InvalidConfig;
        const item_name = item.object.get("name") orelse continue;
        if (item_name != .string or !std.mem.eql(u8, item_name.string, name)) continue;
        const exe = item.object.get("runtimeExecutable") orelse return error.InvalidConfig;
        if (exe != .string or exe.string.len == 0 or exe.string.len > 260) return error.InvalidConfig;
        var args: std.ArrayList([]const u8) = .empty;
        if (item.object.get("runtimeArgs")) |raw| {
            if (raw != .array or raw.array.items.len > MAX_RUNTIME_ARGS) return error.InvalidConfig;
            for (raw.array.items) |arg| {
                if (arg != .string or arg.string.len > 4096) return error.InvalidConfig;
                try args.append(aa, arg.string);
            }
        }
        const port = item.object.get("port") orelse return error.InvalidConfig;
        if (port != .integer or port.integer < 1024 or port.integer > 65535) return error.InvalidConfig;
        const cwd = if (item.object.get("cwd")) |raw| blk: {
            if (raw != .string or raw.string.len == 0 or raw.string.len > 1024 or std.fs.path.isAbsolute(raw.string)) return error.InvalidConfig;
            break :blk try std.fs.path.resolve(aa, &.{ workspace_root, raw.string });
        } else try aa.dupe(u8, workspace_root);
        return .{
            .arena = arena,
            .name = try aa.dupe(u8, name),
            .exe = exe.string,
            .args = args.items,
            .cwd = cwd,
            .root = try aa.dupe(u8, workspace_root),
            .port = @intCast(port.integer),
        };
    }
    arena.deinit();
    return null;
}

// ── Sondeo del puerto en 127.0.0.1 ────────────────────────────────────────
// Conexión NO bloqueante + WSAPoll con tope: `connect` con plazo de la
// biblioteca estándar hace @panic en Windows, y un bind de prueba podría
// quitarle el puerto al propio servidor.
const SOCKET = usize;
const INVALID_SOCKET = ~@as(usize, 0);
const SockAddr = extern struct { family: u16 = 2, port: u16, ip: u32 = 0x0100007f, padding: [8]u8 = @splat(0) };
/// sockaddr_in6: familia, puerto, flowinfo, 16 bytes de dirección, scope.
const SockAddr6 = extern struct { family: u16 = 23, port: u16, flowinfo: u32 = 0, addr: [16]u8, scope_id: u32 = 0 };
const PollFd = extern struct { fd: SOCKET, events: i16, revents: i16 = 0 };
const WsaData = extern struct { version: u16, high_version: u16, max_sockets: u16, max_udp: u16, vendor: ?*u8, description: [257]u8, status: [129]u8 };
extern "ws2_32" fn WSAStartup(u16, *WsaData) callconv(.winapi) i32;
extern "ws2_32" fn WSACleanup() callconv(.winapi) i32;
extern "ws2_32" fn socket(i32, i32, i32) callconv(.winapi) SOCKET;
extern "ws2_32" fn connect(SOCKET, *const SockAddr, i32) callconv(.winapi) i32;
extern "ws2_32" fn ioctlsocket(SOCKET, u32, *u32) callconv(.winapi) i32;
extern "ws2_32" fn WSAPoll([*]PollFd, u32, i32) callconv(.winapi) i32;
extern "ws2_32" fn getsockopt(SOCKET, i32, i32, [*]u8, *i32) callconv(.winapi) i32;
extern "ws2_32" fn htons(u16) callconv(.winapi) u16;
extern "ws2_32" fn closesocket(SOCKET) callconv(.winapi) i32;
extern "ws2_32" fn bind(SOCKET, *const SockAddr, i32) callconv(.winapi) i32;
extern "ws2_32" fn listen(SOCKET, i32) callconv(.winapi) i32;
extern "ws2_32" fn getsockname(SOCKET, *anyopaque, *i32) callconv(.winapi) i32;
extern "kernel32" fn GetCurrentProcessId() callconv(.winapi) u32;
extern "iphlpapi" fn GetExtendedTcpTable(table: ?*anyopaque, size: *u32, order: i32, family: u32, class: u32, reserved: u32) callconv(.winapi) u32;
extern "kernel32" fn CreateToolhelp32Snapshot(flags: u32, pid: u32) callconv(.winapi) ?*anyopaque;
extern "kernel32" fn Process32FirstW(snapshot: ?*anyopaque, entry: *ProcessEntry32W) callconv(.winapi) i32;
extern "kernel32" fn Process32NextW(snapshot: ?*anyopaque, entry: *ProcessEntry32W) callconv(.winapi) i32;
extern "kernel32" fn CloseHandle(handle: ?*anyopaque) callconv(.winapi) i32;
const ProcessEntry32W = extern struct {
    size: u32 = @sizeOf(ProcessEntry32W),
    usage: u32 = 0,
    pid: u32 = 0,
    heap_id: usize = 0,
    module_id: u32 = 0,
    threads: u32 = 0,
    parent: u32 = 0,
    priority: i32 = 0,
    flags: u32 = 0,
    exe: [260]u16 = @splat(0),
};
const MibTcpRowOwnerPid = extern struct { state: u32, local_addr: u32, local_port: u32, remote_addr: u32, remote_port: u32, owning_pid: u32 };
/// MIB_TCP6ROW_OWNER_PID: la dirección ocupa 16 bytes y el puerto local queda
/// en el offset 20 (en orden de red en los dos bytes bajos, como en IPv4).
const MibTcp6RowOwnerPid = extern struct { local_addr: [16]u8, local_scope: u32, local_port: u32, remote_addr: [16]u8, remote_scope: u32, remote_port: u32, state: u32, owning_pid: u32 };
const GetTickCount64 = @import("platform.zig").ticks;
const Sleep = @import("platform.zig").sleep;

/// ¿Hay algo aceptando conexiones en 127.0.0.1:port? Espera como mucho
/// `wait_ms`; ante cualquier fallo de Winsock responde false.
pub fn listening(port: u16, wait_ms: i32) bool {
    if (@import("builtin").os.tag != .windows) return listeningPosix(port, wait_ms);
    var wsa: WsaData = undefined;
    if (WSAStartup(0x202, &wsa) != 0) return false;
    defer _ = WSACleanup();
    const s = socket(2, 1, 6);
    if (s == INVALID_SOCKET) return false;
    defer _ = closesocket(s);
    var nonblocking: u32 = 1;
    // FIONBIO
    if (ioctlsocket(s, 0x8004667E, &nonblocking) != 0) return false;
    const address: SockAddr = .{ .port = htons(port) };
    _ = connect(s, &address, @sizeOf(SockAddr));
    // POLLWRNORM: la conexión terminó (bien o mal); SO_ERROR dice cuál.
    var fds = [_]PollFd{.{ .fd = s, .events = 0x0010 }};
    if (WSAPoll(&fds, 1, wait_ms) != 1) return false;
    var failure: i32 = -1;
    var size: i32 = @sizeOf(i32);
    if (getsockopt(s, 0xffff, 0x1007, @ptrCast(&failure), &size) != 0) return false;
    return failure == 0 and fds[0].revents & 0x0010 != 0;
}

/// T9: el mismo sondeo con sockets POSIX (connect no bloqueante + poll +
/// SO_ERROR); ante cualquier fallo responde false.
fn listeningPosix(port: u16, wait_ms: i32) bool {
    const c = std.c;
    const s = c.socket(c.AF.INET, c.SOCK.STREAM | c.SOCK.CLOEXEC | c.SOCK.NONBLOCK, 0);
    if (s < 0) return false;
    defer _ = c.close(s);
    const address: SockAddr = .{ .port = std.mem.nativeToBig(u16, port) };
    _ = c.connect(s, @ptrCast(&address), @sizeOf(SockAddr));
    var fds = [_]c.pollfd{.{ .fd = s, .events = c.POLL.OUT, .revents = 0 }};
    if (c.poll(&fds, 1, wait_ms) != 1) return false;
    var failure: c_int = -1;
    var size: c.socklen_t = @sizeOf(c_int);
    if (c.getsockopt(s, c.SOL.SOCKET, c.SO.ERROR, @ptrCast(&failure), &size) != 0) return false;
    return failure == 0 and fds[0].revents & c.POLL.OUT != 0;
}

// ── Quién escucha en el puerto (T12 L2) ───────────────────────────────────

/// PIDs que escuchan por TCP/IPv4 e IPv6 en `port` (en 127.0.0.1, 0.0.0.0,
/// ::1, :: u otra dirección local). null si ninguna de las dos tablas del
/// sistema se pudo leer.
fn listenerPids(a: std.mem.Allocator, port: u16) !?[]u32 {
    if (@import("builtin").os.tag != .windows) return null;
    var pids: std.ArrayList(u32) = .empty;
    errdefer pids.deinit(a);
    // T12B B-5 (auditor 3): un servidor solo IPv6 no aparecía en la tabla
    // IPv4 y quedaba en `ready_unverified`; se consultan las dos.
    const v4 = try collectTcpPids(a, MibTcpRowOwnerPid, 2, port, &pids); // AF_INET
    const v6 = try collectTcpPids(a, MibTcp6RowOwnerPid, 23, port, &pids); // AF_INET6
    if (!v4 and !v6) return null;
    return try pids.toOwnedSlice(a);
}

/// Añade a `pids` los PIDs de las filas LISTENER de la tabla TCP de `family`
/// (TCP_TABLE_OWNER_PID_LISTENER = 3). true si la tabla se pudo leer.
fn collectTcpPids(a: std.mem.Allocator, comptime Row: type, family: u32, port: u16, pids: *std.ArrayList(u32)) !bool {
    var size: u32 = 0;
    // ERROR_INSUFFICIENT_BUFFER = 122: el tamaño lo fija la primera llamada.
    var attempt: usize = 0;
    while (attempt < 4) : (attempt += 1) {
        const buf = try a.alignedAlloc(u8, .of(u32), @max(size, 4));
        defer a.free(buf);
        const rc = GetExtendedTcpTable(buf.ptr, &size, 0, family, 3, 0);
        if (rc == 122) continue;
        if (rc != 0) return false;
        const count = std.mem.bytesToValue(u32, buf[0..4]);
        const rows_bytes = buf[4..];
        if (rows_bytes.len < @as(usize, count) * @sizeOf(Row)) return false;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const row = std.mem.bytesToValue(Row, rows_bytes[i * @sizeOf(Row) ..][0..@sizeOf(Row)]);
            const row_port = std.mem.bigToNative(u16, @truncate(row.local_port));
            if (row_port != port) continue;
            if (std.mem.indexOfScalar(u32, pids.items, row.owning_pid) == null) try pids.append(a, row.owning_pid);
        }
        return true;
    }
    return false;
}

/// ¿`pid` es `root` o desciende de él? (cadena de padres de una foto de
/// procesos). null si la foto no se pudo tomar.
fn descendsFrom(a: std.mem.Allocator, pid: u32, root: u32) !?bool {
    if (pid == root) return true;
    if (@import("builtin").os.tag != .windows) return null;
    const snap = CreateToolhelp32Snapshot(0x2, 0); // TH32CS_SNAPPROCESS
    if (snap == null or @intFromPtr(snap) == std.math.maxInt(usize)) return null;
    defer _ = CloseHandle(snap);
    const Link = struct { pid: u32, parent: u32 };
    var parents: std.ArrayList(Link) = .empty;
    defer parents.deinit(a);
    var entry: ProcessEntry32W = .{};
    if (Process32FirstW(snap, &entry) == 0) return null;
    while (true) {
        try parents.append(a, .{ .pid = entry.pid, .parent = entry.parent });
        entry = .{};
        if (Process32NextW(snap, &entry) == 0) break;
    }
    var current = pid;
    var steps: usize = 0;
    while (steps < 64) : (steps += 1) {
        const parent = for (parents.items) |p| {
            if (p.pid == current) break p.parent;
        } else return false;
        if (parent == root) return true;
        if (parent == 0 or parent == current) return false;
        current = parent;
    }
    return false;
}

pub const Owner = enum { ours, foreign, unknown };

/// T12 L2: ¿quien escucha en el puerto es el proceso lanzado (o un hijo
/// suyo)? `unknown` sin PID del lanzamiento (spawn simulado) o sin poder leer
/// la tabla de puertos o los procesos (en Linux todavía no se comprueba).
pub fn portOwner(a: std.mem.Allocator, port: u16, root_pid: u32) Owner {
    if (root_pid == 0) return .unknown;
    const pids = (listenerPids(a, port) catch return .unknown) orelse return .unknown;
    defer a.free(pids);
    if (pids.len == 0) return .unknown;
    for (pids) |pid| {
        const ours = (descendsFrom(a, pid, root_pid) catch return .unknown) orelse return .unknown;
        if (!ours) return .foreign;
    }
    return .ours;
}

// ── Servidor y registro ───────────────────────────────────────────────────

const Chunk = struct { start: u64, stream: Stream, bytes: []u8 };

pub const State = enum { running, exited, stopped, failed };

pub const Server = struct {
    allocator: std.mem.Allocator,
    id: [32]u8,
    generation: u64,
    config: Config,
    spawn_fn: ?executor.SpawnFn,
    origin: executor.Origin,
    thread: ?std.Thread = null,
    stop_requested: std.atomic.Value(bool) = .init(false),
    /// Llamadas que lo están usando (`Registry.done` lo devuelve). Un hueco
    /// no se recicla mientras alguien lo usa.
    users: std.atomic.Value(u32) = .init(0),
    finished: std.atomic.Value(bool) = .init(false),
    mutex: sync.Mutex = .init(),
    /// Serializa el join del hilo: dos paradas a la vez no pueden hacer
    /// `join` dos veces sobre el mismo `std.Thread`.
    join_mutex: sync.Mutex = .init(),
    chunks: std.ArrayList(Chunk) = .empty,
    kept: usize = 0,
    total: u64 = 0,
    dropped: u64 = 0,
    state: State = .running,
    exit_code: ?i32 = null,
    failure: ?[]const u8 = null,
    /// T12 L2: PID del proceso lanzado (0 hasta que el ejecutor lo avisa, o si
    /// el spawn es simulado).
    root_pid: std.atomic.Value(u32) = .init(0),
    /// T12 L2: bloque de entorno del hijo con HOST=127.0.0.1 y PORT=<puerto>.
    environment: ?std.process.Environ.WindowsBlock = null,

    fn spawned(ctx: ?*anyopaque, pid: u32) void {
        const self: *Server = @ptrCast(@alignCast(ctx.?));
        self.root_pid.store(pid, .release);
    }

    fn cancelled(ctx: ?*anyopaque) bool {
        const self: *Server = @ptrCast(@alignCast(ctx.?));
        return self.stop_requested.load(.acquire);
    }

    fn sink(ctx: ?*anyopaque, bytes: []const u8, stream: executor.StreamKind) void {
        const self: *Server = @ptrCast(@alignCast(ctx.?));
        self.append(if (stream == .stderr) .stderr else .stdout, bytes);
    }

    /// Añade salida al registro acotado. Sin memoria se cuenta como perdida
    /// (nunca se finge completa).
    pub fn append(self: *Server, stream: Stream, bytes: []const u8) void {
        if (bytes.len == 0) return;
        self.mutex.lock();
        defer self.mutex.unlock();
        const keep = bytes[bytes.len -| LOG_CAPACITY..];
        const lost = bytes.len - keep.len;
        self.dropped += lost;
        self.total += lost;
        const copy = self.allocator.dupe(u8, keep) catch {
            self.dropped += keep.len;
            self.total += keep.len;
            return;
        };
        self.chunks.append(self.allocator, .{ .start = self.total, .stream = stream, .bytes = copy }) catch {
            self.allocator.free(copy);
            self.dropped += keep.len;
            self.total += keep.len;
            return;
        };
        self.total += keep.len;
        self.kept += keep.len;
        while (self.kept > LOG_CAPACITY) {
            const oldest = self.chunks.orderedRemove(0);
            self.kept -= oldest.bytes.len;
            self.dropped += oldest.bytes.len;
            self.allocator.free(oldest.bytes);
        }
    }

    fn run(self: *Server) void {
        const result = executor.runGoverned(self.allocator, .{
            .workspace_root = self.config.root,
            .origin = self.origin,
            .timeout_ms = std.math.maxInt(u32),
            .max_output_bytes = 64 * 1024,
            .is_cancelled_fn = cancelled,
            .cancelled_ctx = self,
            .environment = if (self.environment) |block| block.slice else null,
            .on_spawn_fn = spawned,
            .on_spawn_ctx = self,
        }, self.config.exe, self.config.args, self.config.cwd, self.spawn_fn, sink, self);
        self.mutex.lock();
        if (result) |done| {
            self.exit_code = done.exit_code;
            self.state = if (done.cancelled) .stopped else .exited;
            if (done.timed_out) self.failure = "Timeout";
            done.deinit(self.allocator);
        } else |err| {
            self.state = .failed;
            self.failure = @errorName(err);
        }
        self.mutex.unlock();
        self.finished.store(true, .release);
    }

    pub fn snapshot(self: *Server) struct { state: State, exit_code: ?i32, failure: ?[]const u8 } {
        self.mutex.lock();
        defer self.mutex.unlock();
        return .{ .state = self.state, .exit_code = self.exit_code, .failure = self.failure };
    }

    /// Pide la parada y espera a que el ejecutor cierre el árbol de procesos.
    /// Idempotente: quien llega segundo no repite el `join`.
    fn stopAndJoin(self: *Server) void {
        self.stop_requested.store(true, .release);
        self.joinThread();
    }

    fn joinThread(self: *Server) void {
        self.join_mutex.lock();
        defer self.join_mutex.unlock();
        if (self.thread) |thread| {
            thread.join();
            self.thread = null;
        }
    }

    fn destroy(self: *Server) void {
        self.stopAndJoin();
        if (self.environment) |block| block.deinit(self.allocator);
        for (self.chunks.items) |chunk| self.allocator.free(chunk.bytes);
        self.chunks.deinit(self.allocator);
        self.config.deinit();
        self.allocator.destroy(self);
    }

    /// Lectura de `stream` desde `cursor` (posición en la salida total, la
    /// de `next_cursor`), hasta `limit` bytes y sin partir un carácter UTF-8.
    pub fn read(self: *Server, a: std.mem.Allocator, cursor: u64, stream: ?Stream, limit: usize) !Read {
        self.mutex.lock();
        defer self.mutex.unlock();
        var text: std.ArrayList(u8) = .empty;
        errdefer text.deinit(a);
        var position = cursor;
        const oldest = if (self.chunks.items.len > 0) self.chunks.items[0].start else self.total;
        const skipped = if (cursor < oldest) oldest - cursor else 0;
        if (position < oldest) position = oldest;
        var more = false;
        for (self.chunks.items) |chunk| {
            const end = chunk.start + chunk.bytes.len;
            if (end <= position) continue;
            if (stream != null and stream.? != chunk.stream) {
                position = end;
                continue;
            }
            const from: usize = @intCast(position - chunk.start);
            var piece = chunk.bytes[from..];
            const room = limit - text.items.len;
            if (piece.len > room) {
                var cut = room;
                while (cut > 0 and cut < piece.len and piece[cut] & 0xC0 == 0x80) cut -= 1;
                piece = piece[0..cut];
                more = true;
            }
            try text.appendSlice(a, piece);
            position += piece.len;
            if (more) break;
        }
        const state = self.state;
        return .{
            .text = try text.toOwnedSlice(a),
            .next_cursor = position,
            .skipped = skipped,
            .more = more,
            .dropped = self.dropped,
            .state = state,
            .exit_code = self.exit_code,
        };
    }
};

pub const Read = struct {
    text: []u8,
    next_cursor: u64,
    skipped: u64,
    more: bool,
    dropped: u64,
    state: State,
    exit_code: ?i32,
};

pub fn waitLaunch(server: *Server, cancelled: ?*const fn (?*anyopaque) bool, ctx: ?*anyopaque) error{ Cancelled, Timeout }!void {
    const started = GetTickCount64();
    while (true) {
        if (cancelled) |check| if (check(ctx)) return error.Cancelled;
        if (server.root_pid.load(.acquire) != 0 or server.finished.load(.acquire)) return;
        if (GetTickCount64() -| started >= 10000) return error.Timeout;
        Sleep(10);
    }
}

pub const StartError = error{ ServerLimit, PortInUse, SpawnFailed, OutOfMemory };

pub const Registry = struct {
    allocator: std.mem.Allocator,
    mutex: sync.Mutex = .init(),
    servers: [MAX_SERVERS]?*Server = @splat(null),
    next_generation: u64 = 1,
    closed: bool = false,

    /// Arranca `config` (pasa a ser del registro, también si falla). El
    /// llamador ya aplicó la política y la aprobación de run_command.
    pub fn start(self: *Registry, config: Config, origin: executor.Origin, spawn_fn: ?executor.SpawnFn) StartError!*Server {
        var owned = config;
        if (owned.port != 0 and listening(owned.port, 200)) {
            owned.deinit();
            return error.PortInUse;
        }
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.closed) {
            owned.deinit();
            return error.SpawnFailed;
        }
        const slot = self.freeSlotLocked() orelse {
            owned.deinit();
            return error.ServerLimit;
        };
        const server = self.allocator.create(Server) catch |err| {
            owned.deinit();
            return err;
        };
        var id: [16]u8 = undefined;
        std.Io.Threaded.global_single_threaded.io().randomSecure(&id) catch {
            self.allocator.destroy(server);
            owned.deinit();
            return error.SpawnFailed;
        };
        // T12 L2: el servidor recibe dónde escuchar (HOST/PORT), como en las
        // IDE de frontera; el resto del entorno es el del motor, filtrado por
        // el ejecutor.
        const environment = if (owned.port == 0) null else serverEnvironment(self.allocator, owned.port) catch {
            self.allocator.destroy(server);
            owned.deinit();
            return error.SpawnFailed;
        };
        server.* = .{
            .allocator = self.allocator,
            .id = std.fmt.bytesToHex(id, .lower),
            .generation = self.next_generation,
            .config = owned,
            .spawn_fn = spawn_fn,
            .origin = origin,
            .environment = environment,
        };
        server.thread = std.Thread.spawn(.{}, Server.run, .{server}) catch {
            if (server.environment) |block| block.deinit(self.allocator);
            server.config.deinit();
            self.allocator.destroy(server);
            return error.SpawnFailed;
        };
        self.next_generation += 1;
        server.users.store(1, .release);
        slot.* = server;
        return server;
    }

    /// Hueco libre, o el de un servidor ya terminado (el más antiguo).
    fn freeSlotLocked(self: *Registry) ?*?*Server {
        for (&self.servers) |*slot| if (slot.* == null) return slot;
        var oldest: ?*?*Server = null;
        for (&self.servers) |*slot| {
            const server = slot.*.?;
            if (!server.finished.load(.acquire) or server.users.load(.acquire) > 0) continue;
            if (oldest == null or server.generation < oldest.?.*.?.generation) oldest = slot;
        }
        if (oldest) |slot| {
            slot.*.?.destroy();
            slot.* = null;
        }
        return oldest;
    }

    pub fn find(self: *Registry, id: []const u8) ?*Server {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.servers) |slot| if (slot) |server| {
            if (std.mem.eql(u8, &server.id, id)) {
                _ = server.users.fetchAdd(1, .acq_rel);
                return server;
            }
        };
        return null;
    }

    /// Devuelve un servidor obtenido con start, find o stop.
    pub fn done(_: *Registry, server: *Server) void {
        _ = server.users.fetchSub(1, .acq_rel);
    }

    /// Para el servidor `id` de la generación `generation`. Sus registros se
    /// conservan para app_server_logs hasta que otro arranque necesite el hueco.
    /// Auditoría B-2: el `join` va FUERA del mutex del registro; un hijo que
    /// ignore la cancelación ya no congela find/start/stop del resto. El
    /// usuario se toma antes de soltar el mutex (protege el servidor del
    /// reciclaje de huecos y de `deinit` mientras se espera).
    pub fn stop(self: *Registry, id: []const u8, generation: u64) error{ServerNotFound}!*Server {
        self.mutex.lock();
        var found: ?*Server = null;
        for (self.servers) |slot| if (slot) |server| {
            if (!std.mem.eql(u8, &server.id, id)) continue;
            if (server.generation != generation) {
                self.mutex.unlock();
                return error.ServerNotFound;
            }
            _ = server.users.fetchAdd(1, .acq_rel);
            found = server;
            break;
        };
        self.mutex.unlock();
        const server = found orelse return error.ServerNotFound;
        server.stopAndJoin();
        return server;
    }

    /// Fin de la orden: para todos y no admite más arranques. Marca la
    /// parada bajo el mutex y hace los `join` fuera: un servidor colgado no
    /// bloquea al registro (auditoría B-2).
    pub fn stopAll(self: *Registry) void {
        var list: [MAX_SERVERS]*Server = undefined;
        var n: usize = 0;
        self.mutex.lock();
        for (self.servers) |slot| {
            const server = slot orelse continue;
            server.stop_requested.store(true, .release);
            _ = server.users.fetchAdd(1, .acq_rel);
            list[n] = server;
            n += 1;
        }
        self.mutex.unlock();
        for (list[0..n]) |server| server.joinThread();
        self.mutex.lock();
        defer self.mutex.unlock();
        for (list[0..n]) |server| _ = server.users.fetchSub(1, .acq_rel);
    }

    pub fn deinit(self: *Registry) void {
        self.mutex.lock();
        self.closed = true;
        self.mutex.unlock();
        // Espera a que los usuarios suelten los servidores ANTES de destruir:
        // `done` no toma el mutex, así que el drene puede hacerse sin él. Un
        // join colgado de stopAll no debe liberar un Server que aún se usa.
        while (true) {
            var busy = false;
            self.mutex.lock();
            for (self.servers) |slot| {
                const server = slot orelse continue;
                if (server.users.load(.acquire) != 0) {
                    busy = true;
                    break;
                }
            }
            self.mutex.unlock();
            if (!busy) break;
            Sleep(10);
        }
        var list: [MAX_SERVERS]*Server = undefined;
        var n: usize = 0;
        self.mutex.lock();
        for (&self.servers) |*slot| {
            const server = slot.* orelse continue;
            // Un `find` puede haber tomado el servidor entre el drenaje y
            // esta toma del mutex: si tiene usuarios se conserva (fuga
            // acotada al apagar el servicio) antes que usarlo liberado.
            if (server.users.load(.acquire) != 0) continue;
            list[n] = server;
            n += 1;
            slot.* = null;
        }
        self.mutex.unlock();
        for (list[0..n]) |server| server.destroy();
    }

    pub fn running(self: *Registry) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        var count: usize = 0;
        for (self.servers) |slot| if (slot) |server| {
            if (!server.finished.load(.acquire)) count += 1;
        };
        return count;
    }
};

/// T12 L2: entorno del servidor: el del motor más HOST=127.0.0.1 y
/// PORT=<puerto> (null fuera de Windows: allí el ejecutor ya toma el suyo).
fn serverEnvironment(a: std.mem.Allocator, port: u16) !?std.process.Environ.WindowsBlock {
    if (@import("builtin").os.tag != .windows) return null;
    var map = try @import("platform.zig").environ().createMap(a);
    defer map.deinit();
    var buf: [8]u8 = undefined;
    try map.put("HOST", "127.0.0.1");
    try map.put("PORT", try std.fmt.bufPrint(&buf, "{d}", .{port}));
    return try map.createWindowsBlock(a, .{});
}

/// Espera a que el servidor acepte conexiones en su puerto, termine o venza
/// el plazo. `cancelled` es la cancelación de la orden. T12 L2: no basta con
/// que algo escuche en el puerto; tiene que ser el proceso lanzado o un
/// descendiente (`foreign` = otro proceso lo ocupó). Si no se puede saber
/// (spawn simulado, Linux), `ready_unverified`: listo, dicho como no comprobado.
pub const Ready = enum { ready, ready_unverified, foreign, exited, timeout, cancelled };
pub fn waitReady(server: *Server, timeout_ms: u32, cancelled: ?*const fn (?*anyopaque) bool, cancelled_ctx: ?*anyopaque) Ready {
    const started = GetTickCount64();
    while (true) {
        if (server.finished.load(.acquire)) return .exited;
        if (cancelled) |check| if (check(cancelled_ctx)) return .cancelled;
        if (listening(server.config.port, 100)) {
            const root = server.root_pid.load(.acquire);
            switch (portOwner(server.allocator, server.config.port, root)) {
                .ours => return .ready,
                .foreign => return .foreign,
                .unknown => if (root == 0 and server.spawn_fn == null) {
                    // El ejecutor real aún no avisó del PID: se espera.
                } else return .ready_unverified,
            }
        }
        if (GetTickCount64() -| started >= timeout_ms) return .timeout;
        Sleep(100);
    }
}

test "T12 L2: un servidor que no es el lanzado escuchando en el puerto no se da por listo; el lanzado recibe HOST y PORT" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T12 L2: la tabla de puertos con PID es de Windows (GetExtendedTcpTable); en Linux aún no se comprueba");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(root);
    var port: u16 = @intCast(43000 + GetTickCount64() % 2000);
    while (listening(port, 50)) port += 1;

    // 1) El lanzado escucha donde le dicen HOST y PORT: listo y comprobado.
    {
        var arena = std.heap.ArenaAllocator.init(a);
        const args = try arena.allocator().dupe([]const u8, &.{ "-e", "require('http').createServer((q,r)=>r.end('ok')).listen(+process.env.PORT, process.env.HOST)" });
        // Todo lo del arena antes de copiarlo a la configuración.
        const cwd = try arena.allocator().dupe(u8, root);
        const space = try arena.allocator().dupe(u8, root);
        var registry: Registry = .{ .allocator = a };
        defer registry.deinit();
        const server = try registry.start(.{ .arena = arena, .name = "web", .exe = "node", .args = args, .cwd = cwd, .root = space, .port = port }, .local, null);
        defer registry.done(server);
        try std.testing.expectEqual(Ready.ready, waitReady(server, 20_000, null, null));
        try std.testing.expect(server.root_pid.load(.acquire) != 0);
        registry.stopAll();
        try std.testing.expect(!listening(port, 300));
    }
    // 2) El lanzado no escucha (tarda); OTRO proceso (aquí, la propia prueba)
    //    ocupa el puerto: no se da por listo, se dice que es ajeno.
    {
        var arena = std.heap.ArenaAllocator.init(a);
        const args = try arena.allocator().dupe([]const u8, &.{ "-e", "setTimeout(()=>{}, 30000)" });
        // Todo lo del arena antes de copiarlo a la configuración.
        const cwd = try arena.allocator().dupe(u8, root);
        const space = try arena.allocator().dupe(u8, root);
        var registry: Registry = .{ .allocator = a };
        defer registry.deinit();
        const server = try registry.start(.{ .arena = arena, .name = "lento", .exe = "node", .args = args, .cwd = cwd, .root = space, .port = port }, .local, null);
        defer registry.done(server);
        var wsa: WsaData = undefined;
        try std.testing.expectEqual(@as(i32, 0), WSAStartup(0x202, &wsa));
        defer _ = WSACleanup();
        const s = socket(2, 1, 6);
        try std.testing.expect(s != INVALID_SOCKET);
        defer _ = closesocket(s);
        const address: SockAddr = .{ .port = htons(port) };
        try std.testing.expectEqual(@as(i32, 0), bind(s, &address, @sizeOf(SockAddr)));
        try std.testing.expectEqual(@as(i32, 0), listen(s, 4));
        try std.testing.expectEqual(Ready.foreign, waitReady(server, 20_000, null, null));
        try std.testing.expectEqual(Owner.foreign, portOwner(a, port, server.root_pid.load(.acquire)));
        registry.stopAll();
    }
}

test "T12B B-5: un servidor solo IPv6 en el puerto cuenta como propio" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T12B B-5: la tabla de puertos con PID es de Windows (GetExtendedTcpTable); en POSIX no se comprueba");
    const a = std.testing.allocator;
    var wsa: WsaData = undefined;
    try std.testing.expectEqual(@as(i32, 0), WSAStartup(0x202, &wsa));
    defer _ = WSACleanup();
    const s = socket(23, 1, 6); // AF_INET6, SOCK_STREAM, IPPROTO_TCP
    try std.testing.expect(s != INVALID_SOCKET);
    defer _ = closesocket(s);
    // ::1 con puerto 0: el sistema elige uno; no se sale a la red.
    var addr: SockAddr6 = .{ .port = 0, .addr = @splat(0) };
    addr.addr[15] = 1;
    try std.testing.expectEqual(@as(i32, 0), bind(s, @ptrCast(&addr), @sizeOf(SockAddr6)));
    try std.testing.expectEqual(@as(i32, 0), listen(s, 1));
    var bound: SockAddr6 = undefined;
    var len: i32 = @sizeOf(SockAddr6);
    try std.testing.expectEqual(@as(i32, 0), getsockname(s, @ptrCast(&bound), &len));
    const port = std.mem.bigToNative(u16, bound.port);
    try std.testing.expect(port != 0);
    // Antes de B-5 la tabla IPv4 no veía este socket: `unknown`. Ahora el PID
    // de la fila IPv6 es el nuestro y el puerto es `ours`.
    try std.testing.expectEqual(Owner.ours, portOwner(a, port, GetCurrentProcessId()));
}

test "T6 launch.json configuration is parsed strictly and never guessed" {
    const a = std.testing.allocator;
    const body =
        \\{"version":"0.0.1","configurations":[{"name":"web","runtimeExecutable":"node","runtimeArgs":["server.js","--port","5173"],"port":5173,"cwd":"web"},{"name":"bad","runtimeExecutable":"node","port":80}]}
    ;
    var config = (try parseConfig(a, body, (if (@import("builtin").os.tag == .windows) "C:\\fixture" else "/fixture"), "web")).?;
    defer config.deinit();
    try std.testing.expectEqualStrings("node", config.exe);
    try std.testing.expectEqual(@as(usize, 3), config.args.len);
    try std.testing.expectEqual(@as(u16, 5173), config.port);
    try std.testing.expectEqualStrings((if (@import("builtin").os.tag == .windows) "C:\\fixture\\web" else "/fixture/web"), config.cwd);
    try std.testing.expect((try parseConfig(a, body, (if (@import("builtin").os.tag == .windows) "C:\\fixture" else "/fixture"), "otra")) == null);
    try std.testing.expectError(error.InvalidConfig, parseConfig(a, body, (if (@import("builtin").os.tag == .windows) "C:\\fixture" else "/fixture"), "bad"));
    try std.testing.expectError(error.InvalidConfig, parseConfig(a, if (@import("builtin").os.tag == .windows) "{\"configurations\":[{\"name\":\"x\",\"runtimeExecutable\":\"node\",\"port\":5000,\"cwd\":\"C:\\\\otra\"}]}" else "{\"configurations\":[{\"name\":\"x\",\"runtimeExecutable\":\"node\",\"port\":5000,\"cwd\":\"/outside\"}]}", (if (@import("builtin").os.tag == .windows) "C:\\fixture" else "/fixture"), "x"));
    try std.testing.expectError(error.InvalidConfig, parseConfig(a, "[]", (if (@import("builtin").os.tag == .windows) "C:\\fixture" else "/fixture"), "x"));
}

test "T6 server log ring is bounded, keeps streams apart and never splits UTF-8" {
    const a = std.testing.allocator;
    var server: Server = .{
        .allocator = a,
        .id = @splat('0'),
        .generation = 1,
        .config = .{ .arena = std.heap.ArenaAllocator.init(a), .name = "x", .exe = "node", .args = &.{}, .cwd = "C:\\fixture", .root = "C:\\fixture", .port = 5000 },
        .spawn_fn = null,
        .origin = .local,
    };
    defer {
        for (server.chunks.items) |chunk| a.free(chunk.bytes);
        server.chunks.deinit(a);
        server.config.deinit();
    }
    server.append(.stdout, "listo en 5000\n");
    server.append(.stderr, "aviso\n");
    server.append(.stdout, "petición ñ\n");
    const out = try server.read(a, 0, .stdout, 1024);
    defer a.free(out.text);
    try std.testing.expectEqualStrings("listo en 5000\npetición ñ\n", out.text);
    const err = try server.read(a, 0, .stderr, 1024);
    defer a.free(err.text);
    try std.testing.expectEqualStrings("aviso\n", err.text);
    // Cursor: lo leído no se repite.
    const again = try server.read(a, out.next_cursor, null, 1024);
    defer a.free(again.text);
    try std.testing.expectEqualStrings("", again.text);
    // Corte en mitad de «ñ» (2 bytes): se queda antes.
    const cut = try server.read(a, 20, .stdout, 7);
    defer a.free(cut.text);
    try std.testing.expectEqualStrings("petici", cut.text);
    try std.testing.expect(cut.more);
    // Acotado: lo antiguo se descarta y se cuenta.
    const big = try a.alloc(u8, LOG_CAPACITY);
    defer a.free(big);
    @memset(big, 'x');
    server.append(.stdout, big);
    try std.testing.expect(server.kept <= LOG_CAPACITY);
    const tail = try server.read(a, 0, null, 16);
    defer a.free(tail.text);
    try std.testing.expect(tail.skipped > 0);
    try std.testing.expect(tail.dropped > 0);
}
