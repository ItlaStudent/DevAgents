const std = @import("std");
const mcp_client = @import("mcp_client.zig");
const sandbox = @import("sandbox.zig");
const confined_fs = @import("confined_fs.zig");

// E5.06 / cliente ACP (Agent Client Protocol) v1 sobre stdio.
// Especificación verificada: schema v1.9.1, protocolVersion=1
// (evidencia E5.06-acp-schema-v1.9.1.json + E5.06-acp-meta-v1.9.1.json).
//
// Métodos implementados (lado cliente):
//   initialize · session/new · session/prompt · session/cancel
// Métodos servidor que el cliente responde al agente:
//   session/request_permission · fs/read_text_file · fs/write_text_file
// Notificación consumida: session/update (mapeada a eventos DevAgents).
// NO implementados a propósito: terminal/* (capability terminal:false — un
// comando del agente nunca corre fuera del ejecutor gobernado), authenticate
// (nunca se inyectan credenciales a un proceso externo) y el resto de métodos
// opcionales (session/load, session/set_mode, elicitation/*): el agente los
// anuncia por capability y nosotros no los llamamos.

const windows = std.os.windows;
const GetTickCount64 = @import("platform.zig").ticks;
const GetTempPathA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetTempPathA(nBufferLength: u32, lpBuffer: [*]u8) u32;
}.GetTempPathA else @import("platform.zig").tempPath;
const Sleep = @import("platform.zig").sleep;
const GetFileAttributesA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileAttributesA(lpFileName: [*:0]const u8) u32;
}.GetFileAttributesA else @import("providers").posix_files.GetFileAttributesA;
const DeleteFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn DeleteFileA(lpFileName: [*:0]const u8) c_int;
}.DeleteFileA else @import("providers").posix_files.DeleteFileA;
const RemoveDirectoryA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn RemoveDirectoryA(lpPathName: [*:0]const u8) c_int;
}.RemoveDirectoryA else @import("providers").posix_files.RemoveDirectoryA;
const CreateFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateFileA(lpFileName: [*:0]const u8, dwDesiredAccess: u32, dwShareMode: u32, lpSecurityAttributes: ?*anyopaque, dwCreationDisposition: u32, dwFlagsAndAttributes: u32, hTemplateFile: ?windows.HANDLE) ?*anyopaque;
}.CreateFileA else @import("providers").posix_files.CreateFileNullableA;
const GetFileSizeEx = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetFileSizeEx(hFile: ?*anyopaque, lpFileSize: *i64) c_int;
}.GetFileSizeEx else @import("providers").posix_files.GetFileSizeEx;
const ReadFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn ReadFile(hFile: ?*anyopaque, lpBuffer: [*]u8, nNumberOfBytesToRead: u32, lpNumberOfBytesRead: *u32, lpOverlapped: ?*anyopaque) c_int;
}.ReadFile else @import("providers").posix_files.ReadFile;
const WriteFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn WriteFile(hFile: ?*anyopaque, lpBuffer: [*]const u8, nNumberOfBytesToWrite: u32, lpNumberOfBytesWritten: *u32, lpOverlapped: ?*anyopaque) c_int;
}.WriteFile else @import("providers").posix_files.WriteFile;
const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(hObject: ?*anyopaque) c_int;
}.CloseHandle else @import("providers").posix_files.CloseHandle;
const CreateDirectoryA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateDirectoryA(lpPathName: [*:0]const u8, lpSecurityAttributes: ?*anyopaque) c_int;
}.CreateDirectoryA else @import("providers").posix_files.CreateDirectoryA;

const GENERIC_READ_T: u32 = 0x80000000;
const GENERIC_WRITE_T: u32 = 0x40000000;
const FILE_SHARE_READ_T: u32 = 0x1;
const FILE_SHARE_READ_WRITE_T: u32 = 0x3;
const OPEN_EXISTING_T: u32 = 3;
const CREATE_ALWAYS_T: u32 = 2;
const FILE_ATTRIBUTE_NORMAL_T: u32 = 0x80;

/// Cap de lectura fs/read_text_file: más allá, el agente recibe error honesto
/// en vez de un contenido truncado en silencio.
const MAX_FS_READ_BYTES: u64 = 4 * 1024 * 1024;
/// Cap de escritura fs/write_text_file.
const MAX_FS_WRITE_BYTES: usize = 4 * 1024 * 1024;
const MAX_FS_PATH_BYTES: usize = 4096;

pub const PROTOCOL_VERSION: u16 = 1;
pub const CLIENT_NAME = "devagents";
pub const CLIENT_TITLE = "DevAgents";
/// la versión que el cliente ACP anuncia es la del producto.
pub const CLIENT_VERSION = @import("root.zig").VERSION;

pub const AcpError = error{
    UnsafeBatchArgument,
    SpawnFailed,
    Timeout,
    ProtocolError,
    ServerError,
    ProcessDied,
    OutOfMemory,
    JsonParseError,
    Cancelled,
    UnsupportedVersion,
    NotConnected,
    FsDenied,
    FsError,
};

fn transportErr(e: mcp_client.McpError) AcpError {
    return switch (e) {
        error.UnsafeBatchArgument => error.UnsafeBatchArgument,
        error.Timeout => error.Timeout,
        error.OutOfMemory => error.OutOfMemory,
        error.JsonParseError => error.JsonParseError,
        error.NotConnected => error.NotConnected,
        error.ProcessDied => error.ProcessDied,
        error.SpawnFailed => error.SpawnFailed,
        else => error.ProtocolError,
    };
}

/// Clasificación de session/update hacia los eventos DevAgents de la orden.
pub const UpdateKind = enum {
    content, // agent_message_chunk
    reasoning, // agent_thought_chunk
    user_echo, // user_message_chunk
    tool, // tool_call / tool_call_update
    plan, // plan
    usage, // usage_update
    commands, // available_commands_update
    mode, // current_mode_update
    session_info, // session_info_update
    config, // config_option_update
    other, // variante desconocida o de extensión
};

/// Evento entregado al sink. TODOS los campos son prestados: válidos solo
/// durante el callback; quien los retenga los copia.
pub const SessionEvent = struct {
    kind: UpdateKind,
    /// `sessionUpdate` literal del agente (snake_case del spec).
    variant: []const u8,
    session_id: []const u8,
    /// Objeto `update` completo tal cual llegó.
    update: std.json.Value,
    /// Texto del primer content block de tipo text (chunks), si lo hay.
    text: ?[]const u8 = null,
};

pub const UpdateSink = struct {
    ctx: ?*anyopaque = null,
    func: ?*const fn (ctx: ?*anyopaque, ev: *const SessionEvent) void = null,
};

/// Decisión ante session/request_permission. E5.08 ata esta seam a la bandeja
/// de aprobaciones; sin handler la respuesta es "cancelled" (fail-closed:
/// ningún agente externo se auto-aprueba).
pub const PermissionOutcome = union(enum) {
    selected: []const u8, // optionId elegido de la lista ofrecida
    cancelled,
};

pub const PermissionFn = *const fn (
    ctx: ?*anyopaque,
    session_id: []const u8,
    tool_call_json: []const u8,
    options_json: []const u8,
) anyerror!PermissionOutcome;

pub const StopReason = enum { end_turn, max_tokens, max_turn_requests, refusal, cancelled };

pub const PromptResult = struct {
    stop_reason: StopReason,
};

/// Info del agente capturada en initialize — base del descubrimiento de
/// agentes externos en runtime (E5.08). Cadenas owned por el cliente.
pub const AgentInfo = struct {
    protocol_version: u16 = 0,
    name: []u8 = &.{},
    title: []u8 = &.{},
    version: []u8 = &.{},
    auth_methods: usize = 0,
    load_session: bool = false,
    prompt_image: bool = false,
    prompt_audio: bool = false,
    prompt_embedded_context: bool = false,

    fn deinit(self: *AgentInfo, allocator: std.mem.Allocator) void {
        if (self.name.len > 0) allocator.free(self.name);
        if (self.title.len > 0) allocator.free(self.title);
        if (self.version.len > 0) allocator.free(self.version);
    }
};

pub const AcpClient = struct {
    allocator: std.mem.Allocator,
    transport: mcp_client.McpTransport,
    next_id: i64,
    /// Deadline por espera de respuesta fuera del turno (initialize, session/new).
    timeout_ms: u64,
    /// Raíz de confinamiento de fs/* = cwd de session/new (el worktree).
    fs_root: ?[]u8 = null,
    session_id: ?[]u8 = null,
    agent_info: AgentInfo = .{},
    initialized: bool = false,
    /// Sink de notificaciones session/update → eventos DevAgents.
    update_sink: UpdateSink = .{},
    /// Seam de gobernanza para session/request_permission (E5.08).
    permission_fn: ?PermissionFn = null,
    permission_ctx: ?*anyopaque = null,
    /// Token de la orden (patrón is_cancelled de governed_tool_executor).
    is_cancelled_fn: ?*const fn (?*anyopaque) bool = null,
    cancelled_ctx: ?*anyopaque = null,
    cancelled_local: bool = false,
    cancel_sent: bool = false,
    /// Último error devuelto por el agente (owned, se sustituye en cada error).
    last_error: ?[]u8 = null,

    /// Cliente sobre un transporte ya construido (tests inyectan scripted).
    pub fn init(allocator: std.mem.Allocator, transport: mcp_client.McpTransport, timeout_ms: u64) AcpClient {
        return .{ .allocator = allocator, .transport = transport, .next_id = 1, .timeout_ms = timeout_ms };
    }

    /// Lanza el agente ACP como hijo por stdio (patrón StdioTransport:
    /// env heredado sin credenciales inyectadas, create_no_window, kill al
    /// cerrar). `cwd` es el directorio del proceso (normalmente el worktree).
    /// El timeout del transporte queda capado a 500 ms: es solo el tick de
    /// espera del pump — los deadlines reales los ponen cada llamada
    /// (initialize/session_new con timeout_ms; prompt con su propio plazo).
    pub fn connect(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, timeout_ms: u64) AcpError!AcpClient {
        const tick = @min(timeout_ms, 500);
        const tr = mcp_client.StdioTransport.connectInCwd(allocator, argv, cwd, tick, null) catch |e| return transportErr(e);
        return init(allocator, tr, timeout_ms);
    }

    pub fn deinit(self: *AcpClient) void {
        if (self.fs_root) |r| self.allocator.free(r);
        if (self.session_id) |s| self.allocator.free(s);
        if (self.last_error) |e| self.allocator.free(e);
        self.agent_info.deinit(self.allocator);
        self.transport.closeFn(self.transport.ptr);
    }

    fn isCancelled(self: *const AcpClient) bool {
        if (self.cancelled_local) return true;
        if (self.is_cancelled_fn) |f| return f(self.cancelled_ctx);
        return false;
    }

    // ── Peticiones cliente → agente ─────────────────────────────────────

    fn jsonAlloc(self: *AcpClient, comptime fmt: []const u8, args: anytype) AcpError![]u8 {
        return std.fmt.allocPrint(self.allocator, fmt, args) catch return error.OutOfMemory;
    }

    /// Serializa un std.json.Value (o string cruda) a JSON con escape correcto.
    fn stringifyValue(self: *AcpClient, v: anytype) AcpError![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        js.write(v) catch return error.OutOfMemory;
        return self.allocator.dupe(u8, out.written()) catch return error.OutOfMemory;
    }

    fn writeLine(self: *AcpClient, bytes: []const u8) AcpError!void {
        self.transport.writeFn(self.transport.ptr, bytes) catch |e| return transportErr(e);
    }

    /// initialize: protocolVersion=1, clientCapabilities fs r/w y terminal:false.
    /// La capability `terminal` queda apagada a propósito: ningún comando del
    /// agente corre fuera del ejecutor gobernado (E5.08 podrá reevaluarla).
    pub fn initialize(self: *AcpClient) AcpError!void {
        const id = self.next_id;
        self.next_id += 1;
        const req = try self.jsonAlloc(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"initialize\",\"params\":{{\"protocolVersion\":{d},\"clientCapabilities\":{{\"fs\":{{\"readTextFile\":true,\"writeTextFile\":true}},\"terminal\":false}},\"clientInfo\":{{\"name\":\"{s}\",\"title\":\"{s}\",\"version\":\"{s}\"}}}}}}\n",
            .{ id, PROTOCOL_VERSION, CLIENT_NAME, CLIENT_TITLE, CLIENT_VERSION },
        );
        defer self.allocator.free(req);
        try self.writeLine(req);

        const resp = try self.pump(id, self.timeout_ms);
        defer self.allocator.free(resp);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return error.ProtocolError;
        defer parsed.deinit();
        const result = try self.resultOrServerError(parsed.value);
        if (result != .object) return error.ProtocolError;
        const robj = result.object;

        const pv = robj.get("protocolVersion") orelse return error.ProtocolError;
        const pv_num: u16 = switch (pv) {
            .integer => |v| if (v >= 0 and v <= 65535) @intCast(v) else return error.ProtocolError,
            else => return error.ProtocolError,
        };
        if (pv_num != PROTOCOL_VERSION) return error.UnsupportedVersion;

        self.agent_info.protocol_version = pv_num;
        if (robj.get("agentInfo")) |ai| {
            if (ai == .object) {
                if (ai.object.get("name")) |n| if (n == .string) {
                    self.agent_info.name = try self.allocator.dupe(u8, n.string);
                };
                if (ai.object.get("title")) |t| if (t == .string) {
                    self.agent_info.title = try self.allocator.dupe(u8, t.string);
                };
                if (ai.object.get("version")) |v| if (v == .string) {
                    self.agent_info.version = try self.allocator.dupe(u8, v.string);
                };
            }
        }
        if (robj.get("authMethods")) |am| {
            if (am == .array) self.agent_info.auth_methods = am.array.items.len;
        }
        if (robj.get("agentCapabilities")) |caps| {
            if (caps == .object) {
                if (caps.object.get("loadSession")) |ls| {
                    if (ls == .bool) self.agent_info.load_session = ls.bool;
                }
                if (caps.object.get("promptCapabilities")) |pc| {
                    if (pc == .object) {
                        if (pc.object.get("image")) |v| if (v == .bool) {
                            self.agent_info.prompt_image = v.bool;
                        };
                        if (pc.object.get("audio")) |v| if (v == .bool) {
                            self.agent_info.prompt_audio = v.bool;
                        };
                        if (pc.object.get("embeddedContext")) |v| if (v == .bool) {
                            self.agent_info.prompt_embedded_context = v.bool;
                        };
                    }
                }
            }
        }
        self.initialized = true;
    }

    /// session/new con cwd = worktree. Guarda el session_id y fija fs_root.
    pub fn sessionNew(self: *AcpClient, cwd: []const u8) AcpError![]const u8 {
        if (!self.initialized) return error.NotConnected;
        const id = self.next_id;
        self.next_id += 1;
        const cwd_json = try self.stringifyValue(cwd);
        defer self.allocator.free(cwd_json);
        const req = try self.jsonAlloc(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session/new\",\"params\":{{\"cwd\":{s},\"mcpServers\":[]}}}}\n",
            .{ id, cwd_json },
        );
        defer self.allocator.free(req);
        try self.writeLine(req);

        const resp = try self.pump(id, self.timeout_ms);
        defer self.allocator.free(resp);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return error.ProtocolError;
        defer parsed.deinit();
        const result = try self.resultOrServerError(parsed.value);
        if (result != .object) return error.ProtocolError;
        const sid = result.object.get("sessionId") orelse return error.ProtocolError;
        if (sid != .string or sid.string.len == 0) return error.ProtocolError;

        if (self.session_id) |old| self.allocator.free(old);
        self.session_id = try self.allocator.dupe(u8, sid.string);
        if (self.fs_root) |old| self.allocator.free(old);
        self.fs_root = try self.allocator.dupe(u8, cwd);
        return self.session_id.?;
    }

    /// session/prompt con un único bloque de texto. `deadline_ms` es el plazo
    /// TOTAL del turno (E5.08 lo ata al límite de la orden, defecto 15 min).
    /// Durante la espera se sirven fs/* y session/request_permission del agente
    /// y se despachan las notificaciones session/update al sink.
    pub fn prompt(self: *AcpClient, session_id: []const u8, text: []const u8, deadline_ms: u64) AcpError!PromptResult {
        if (!self.initialized) return error.NotConnected;
        const id = self.next_id;
        self.next_id += 1;
        const sid_json = try self.stringifyValue(session_id);
        defer self.allocator.free(sid_json);
        const text_json = try self.stringifyValue(text);
        defer self.allocator.free(text_json);
        const req = try self.jsonAlloc(
            "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"session/prompt\",\"params\":{{\"sessionId\":{s},\"prompt\":[{{\"type\":\"text\",\"text\":{s}}}]}}}}\n",
            .{ id, sid_json, text_json },
        );
        defer self.allocator.free(req);
        try self.writeLine(req);

        const resp = try self.pump(id, deadline_ms);
        defer self.allocator.free(resp);
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, resp, .{}) catch return error.ProtocolError;
        defer parsed.deinit();
        const result = try self.resultOrServerError(parsed.value);
        if (result != .object) return error.ProtocolError;
        const sr = result.object.get("stopReason") orelse return error.ProtocolError;
        if (sr != .string) return error.ProtocolError;
        const reason = stopReasonFromText(sr.string) orelse return error.ProtocolError;
        return .{ .stop_reason = reason };
    }

    /// Cancelación con token de la orden: marca local + notificación
    /// session/cancel al agente (una sola vez). El agente debe responder al
    /// prompt pendiente con stopReason "cancelled"; si no lo hace, el deadline
    /// del turno vence y deinit mata el proceso (transport.close → child.kill).
    pub fn cancel(self: *AcpClient) void {
        self.cancelled_local = true;
        self.sendCancelOnce() catch {};
    }

    fn sendCancelOnce(self: *AcpClient) AcpError!void {
        if (self.cancel_sent) return;
        const sid = self.session_id orelse return;
        const sid_json = try self.stringifyValue(sid);
        defer self.allocator.free(sid_json);
        const notif = try self.jsonAlloc(
            "{{\"jsonrpc\":\"2.0\",\"method\":\"session/cancel\",\"params\":{{\"sessionId\":{s}}}}}\n",
            .{sid_json},
        );
        defer self.allocator.free(notif);
        self.cancel_sent = true;
        try self.writeLine(notif);
    }

    // ── Bomba de mensajes ────────────────────────────────────────────────

    /// Lee mensajes hasta la respuesta de `want_id`. Sirve las peticiones
    /// agente→cliente (fs/*, permisos) y despacha las notificaciones. El
    /// Timeout del transporte es un tick: el deadline real lo pone el llamador.
    fn pump(self: *AcpClient, want_id: i64, deadline_ms: u64) AcpError![]u8 {
        const start = GetTickCount64();
        while (true) {
            if (self.isCancelled()) self.sendCancelOnce() catch {};
            if (GetTickCount64() - start >= deadline_ms) return error.Timeout;
            const msg = self.transport.readFn(self.transport.ptr, self.allocator) catch |e| {
                const ae = transportErr(e);
                if (ae == error.Timeout) continue;
                return ae;
            };
            defer self.allocator.free(msg);

            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, msg, .{}) catch
                return error.ProtocolError;
            defer parsed.deinit();
            if (parsed.value != .object) return error.ProtocolError;
            const obj = parsed.value.object;
            const method_v = obj.get("method");
            const id_v = obj.get("id");

            if (method_v) |m| {
                if (m != .string) return error.ProtocolError;
                if (id_v) |iv| {
                    // Petición agente → cliente: hay que responderla.
                    try self.handleAgentRequest(iv, m.string, obj.get("params"));
                } else {
                    try self.handleNotification(m.string, obj.get("params"));
                }
                continue;
            }
            if (id_v) |iv| {
                if (idMatches(iv, want_id)) return try self.allocator.dupe(u8, msg);
                continue; // respuesta de id ajeno: descartar
            }
            // JSON válido sin method ni id: no es un mensaje JSON-RPC útil.
            return error.ProtocolError;
        }
    }

    fn idMatches(v: std.json.Value, want: i64) bool {
        return switch (v) {
            .integer => |i| i == want,
            // float fuera de i64 no se castea (panic) — no coincide.
            .float => |f| f >= -9223372036854775808.0 and f < 9223372036854775808.0 and
                @as(i64, @intFromFloat(f)) == want,
            else => false,
        };
    }

    /// Extrae `result` o convierte el objeto error del agente en ServerError
    /// con su mensaje en `last_error`.
    fn resultOrServerError(self: *AcpClient, root: std.json.Value) AcpError!std.json.Value {
        if (root != .object) return error.ProtocolError;
        const obj = root.object;
        if (obj.get("error")) |ev| {
            if (ev == .object) {
                const msg = if (ev.object.get("message")) |m| blk: {
                    if (m == .string) break :blk m.string;
                    break :blk "acp error";
                } else "acp error";
                const owned = self.allocator.dupe(u8, msg) catch return error.OutOfMemory;
                if (self.last_error) |old| self.allocator.free(old);
                self.last_error = owned;
            }
            return error.ServerError;
        }
        return obj.get("result") orelse error.ProtocolError;
    }

    // ── Peticiones agente → cliente ──────────────────────────────────────

    fn handleAgentRequest(self: *AcpClient, id_v: std.json.Value, method: []const u8, params: ?std.json.Value) AcpError!void {
        if (std.mem.eql(u8, method, "fs/read_text_file")) {
            const content = self.fsReadTextFile(params) catch |e| {
                return self.respondError(id_v, -32000, @errorName(e));
            };
            defer self.allocator.free(content);
            const content_json = try self.stringifyValue(content);
            defer self.allocator.free(content_json);
            return self.respondRaw(id_v, try self.jsonAlloc("{{\"content\":{s}}}", .{content_json}));
        }
        if (std.mem.eql(u8, method, "fs/write_text_file")) {
            self.fsWriteTextFile(params) catch |e| {
                return self.respondError(id_v, -32000, @errorName(e));
            };
            return self.respondRaw(id_v, try self.allocator.dupe(u8, "{}"));
        }
        if (std.mem.eql(u8, method, "session/request_permission")) {
            const outcome_json = self.resolvePermission(params) catch |e| {
                return self.respondError(id_v, -32000, @errorName(e));
            };
            defer self.allocator.free(outcome_json);
            return self.respondRaw(id_v, try self.jsonAlloc("{{\"outcome\":{s}}}", .{outcome_json}));
        }
        // terminal/*, elicitation/*, $/cancel_request con id y desconocidos:
        // capabilities no anunciadas → method not found.
        return self.respondError(id_v, -32601, "method not found");
    }

    fn respondRaw(self: *AcpClient, id_v: std.json.Value, result_json: []u8) AcpError!void {
        defer self.allocator.free(result_json);
        const id_json = try self.stringifyValue(id_v);
        defer self.allocator.free(id_json);
        const line = try self.jsonAlloc("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"result\":{s}}}\n", .{ id_json, result_json });
        defer self.allocator.free(line);
        try self.writeLine(line);
    }

    fn respondError(self: *AcpClient, id_v: std.json.Value, code: i64, message: []const u8) AcpError!void {
        const id_json = try self.stringifyValue(id_v);
        defer self.allocator.free(id_json);
        const msg_json = try self.stringifyValue(message);
        defer self.allocator.free(msg_json);
        const line = try self.jsonAlloc("{{\"jsonrpc\":\"2.0\",\"id\":{s},\"error\":{{\"code\":{d},\"message\":{s}}}}}\n", .{ id_json, code, msg_json });
        defer self.allocator.free(line);
        try self.writeLine(line);
    }

    // ── session/request_permission → seam de gobernanza ──────────────────

    fn resolvePermission(self: *AcpClient, params: ?std.json.Value) AcpError![]u8 {
        // Cancelada la orden: toda petición pendiente responde "cancelled".
        if (self.isCancelled()) return self.allocator.dupe(u8, "{\"outcome\":\"cancelled\"}");
        const p = params orelse return error.ProtocolError;
        if (p != .object) return error.ProtocolError;
        const tool_call = p.object.get("toolCall") orelse return error.ProtocolError;
        const options = p.object.get("options") orelse return error.ProtocolError;
        if (options != .array) return error.ProtocolError;

        const tc_json = try self.stringifyValue(tool_call);
        defer self.allocator.free(tc_json);
        const opts_json = try self.stringifyValue(options);
        defer self.allocator.free(opts_json);

        const decision: PermissionOutcome = if (self.permission_fn) |f|
            f(self.permission_ctx, self.session_id orelse "", tc_json, opts_json) catch .cancelled
        else
            .cancelled;

        switch (decision) {
            .cancelled => return self.allocator.dupe(u8, "{\"outcome\":\"cancelled\"}"),
            .selected => |opt| {
                // La opción elegida tiene que ser una de las ofrecidas.
                if (!optionOffered(options.array.items, opt)) return self.allocator.dupe(u8, "{\"outcome\":\"cancelled\"}");
                const opt_json = try self.stringifyValue(opt);
                defer self.allocator.free(opt_json);
                return self.jsonAlloc("{{\"outcome\":\"selected\",\"optionId\":{s}}}", .{opt_json});
            },
        }
    }

    fn optionOffered(items: []const std.json.Value, option_id: []const u8) bool {
        for (items) |it| {
            if (it != .object) continue;
            if (it.object.get("optionId")) |v| {
                if (v == .string and std.mem.eql(u8, v.string, option_id)) return true;
            }
        }
        return false;
    }

    // ── fs/* confinado al worktree ───────────────────────────────────────

    /// Resuelve `path` (ACP exige absoluta) a ruta confinada en fs_root.
    /// must_exist=true (lectura): checkWrite ya hace la fase canónica si la
    /// ruta existe; además exigimos que exista. must_exist=false (escritura):
    /// el ancestro existente más cercano se resuelve en canónico y debe quedar
    /// dentro del root canónico — cierra el escape por junction hacia un
    /// archivo nuevo (clase el checkWrite léxico solo no lo ve).
    fn resolveFsPath(self: *AcpClient, path: []const u8, must_exist: bool) AcpError![]u8 {
        const allocator = self.allocator;
        const root = self.fs_root orelse return error.FsDenied;
        if (path.len == 0 or path.len > MAX_FS_PATH_BYTES) return error.FsDenied;
        if (!isAbsolutePath(path)) return error.FsDenied;

        var sb = sandbox.Sandbox.init(allocator, root) catch return error.FsDenied;
        defer sb.deinit();
        sb.checkWrite(path) catch return error.FsDenied;
        const root_canon = sb.root_canonical orelse return error.FsDenied;

        const candidate = std.fs.path.resolve(allocator, &.{path}) catch return error.OutOfMemory;
        errdefer allocator.free(candidate);

        if (sandbox.canonicalizeExisting(allocator, candidate)) |canon| {
            defer allocator.free(canon);
            if (!canonInside(root_canon, canon)) return error.FsDenied;
            return candidate;
        }
        if (must_exist) return error.FsError; // lectura de lo inexistente

        // Archivo nuevo: el ancestro existente más cercano manda.
        var anc: []const u8 = candidate;
        while (std.fs.path.dirname(anc)) |parent| {
            if (parent.len >= anc.len) break;
            anc = parent;
            if (sandbox.canonicalizeExisting(allocator, anc)) |canon_p| {
                defer allocator.free(canon_p);
                if (!canonInside(root_canon, canon_p)) return error.FsDenied;
                return candidate;
            }
        }
        return error.FsDenied; // ni el root existe
    }

    fn fsReadTextFile(self: *AcpClient, params: ?std.json.Value) AcpError![]u8 {
        const p = params orelse return error.ProtocolError;
        if (p != .object) return error.ProtocolError;
        const obj = p.object;
        const path_v = obj.get("path") orelse return error.ProtocolError;
        if (path_v != .string) return error.ProtocolError;
        var line_start: u64 = 1;
        if (obj.get("line")) |v| {
            if (v == .integer and v.integer > 0) line_start = @intCast(v.integer);
        }
        var line_limit: u64 = std.math.maxInt(u64);
        if (obj.get("limit")) |v| {
            if (v == .integer and v.integer > 0) line_limit = @intCast(v.integer);
        }

        const full = try self.resolveFsPath(path_v.string, true);
        defer self.allocator.free(full);
        const raw = try readFileCapped(self.allocator, full, MAX_FS_READ_BYTES);
        defer self.allocator.free(raw);

        // Selección por líneas (1-based) sobre el contenido leído.
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var it = std.mem.splitScalar(u8, raw, '\n');
        var n: u64 = 0;
        var emitted: u64 = 0;
        while (it.next()) |ln| {
            n += 1;
            if (n < line_start) continue;
            if (emitted >= line_limit) break;
            if (emitted > 0) out.writer.writeByte('\n') catch return error.OutOfMemory;
            var l = ln;
            if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
            out.writer.writeAll(l) catch return error.OutOfMemory;
            emitted += 1;
        }
        return self.allocator.dupe(u8, out.written()) catch return error.OutOfMemory;
    }

    fn fsWriteTextFile(self: *AcpClient, params: ?std.json.Value) AcpError!void {
        const p = params orelse return error.ProtocolError;
        if (p != .object) return error.ProtocolError;
        const obj = p.object;
        const path_v = obj.get("path") orelse return error.ProtocolError;
        const content_v = obj.get("content") orelse return error.ProtocolError;
        if (path_v != .string or content_v != .string) return error.ProtocolError;
        if (content_v.string.len > MAX_FS_WRITE_BYTES) return error.FsError;

        const root_path = self.fs_root orelse return error.FsDenied;
        const path = path_v.string;
        if (path.len == 0 or path.len > MAX_FS_PATH_BYTES or !isAbsolutePath(path)) return error.FsDenied;
        var root = confined_fs.Root.initMutation(self.allocator, root_path) catch |e| return mutationError(e);
        defer root.deinit();
        const relative = root.relativePath(path) catch |e| return mutationError(e);
        defer self.allocator.free(relative);
        root.writeFile(relative, content_v.string) catch |e| return mutationError(e);
    }

    fn mutationError(e: anyerror) AcpError {
        return switch (e) {
            error.OutOfMemory => error.OutOfMemory,
            error.SandboxDenied, error.HardLinkDenied, error.RootChanged => error.FsDenied,
            else => error.FsError,
        };
    }

    // ── session/update → eventos DevAgents ───────────────────────────────

    fn handleNotification(self: *AcpClient, method: []const u8, params: ?std.json.Value) AcpError!void {
        if (!std.mem.eql(u8, method, "session/update")) return; // el resto: ignoradas
        const p = params orelse return;
        if (p != .object) return;
        const obj = p.object;
        const sid_v = obj.get("sessionId") orelse return;
        const update = obj.get("update") orelse return;
        if (update != .object) return;
        const variant_v = update.object.get("sessionUpdate") orelse return;
        if (variant_v != .string) return;
        const variant = variant_v.string;

        var ev = SessionEvent{
            .kind = kindFromVariant(variant),
            .variant = variant,
            .session_id = if (sid_v == .string) sid_v.string else "",
            .update = update,
        };
        // Texto del primer content block de texto en *_chunk.
        if (update.object.get("content")) |c| {
            if (c == .object) {
                const t = c.object.get("type");
                const txt = c.object.get("text");
                if (t != null and t.? == .string and std.mem.eql(u8, t.?.string, "text") and
                    txt != null and txt.? == .string)
                {
                    ev.text = txt.?.string;
                }
            }
        }
        if (self.update_sink.func) |f| f(self.update_sink.ctx, &ev);
    }

    fn kindFromVariant(variant: []const u8) UpdateKind {
        const map = .{
            .{ "agent_message_chunk", UpdateKind.content },
            .{ "agent_thought_chunk", UpdateKind.reasoning },
            .{ "user_message_chunk", UpdateKind.user_echo },
            .{ "tool_call", UpdateKind.tool },
            .{ "tool_call_update", UpdateKind.tool },
            .{ "plan", UpdateKind.plan },
            .{ "usage_update", UpdateKind.usage },
            .{ "available_commands_update", UpdateKind.commands },
            .{ "current_mode_update", UpdateKind.mode },
            .{ "session_info_update", UpdateKind.session_info },
            .{ "config_option_update", UpdateKind.config },
        };
        inline for (map) |kv| {
            if (std.mem.eql(u8, variant, kv[0])) return kv[1];
        }
        return .other;
    }

    fn stopReasonFromText(s: []const u8) ?StopReason {
        const map = .{
            .{ "end_turn", StopReason.end_turn },
            .{ "max_tokens", StopReason.max_tokens },
            .{ "max_turn_requests", StopReason.max_turn_requests },
            .{ "refusal", StopReason.refusal },
            .{ "cancelled", StopReason.cancelled },
        };
        inline for (map) |kv| {
            if (std.mem.eql(u8, s, kv[0])) return kv[1];
        }
        return null;
    }
};

// ── Utilidades de ruta y archivo (Win32, patrón worktree_prepare) ───────

fn isAbsolutePath(path: []const u8) bool {
    if (path.len < 2) return false;
    if (path[0] == '/' or path[0] == '\\') return true;
    return path[1] == ':';
}

/// ¿`canon` es el propio `root_canon` o un descendiente? Componente a
/// componente, insensible a mayúsculas (Windows) y a '/'/'\\'.
fn canonInside(root_canon: []const u8, canon: []const u8) bool {
    var ri = std.mem.tokenizeAny(u8, root_canon, "/\\");
    var ci = std.mem.tokenizeAny(u8, canon, "/\\");
    while (ri.next()) |rc| {
        const cc = ci.next() orelse return false;
        if (!std.ascii.eqlIgnoreCase(rc, cc)) return false;
    }
    // El root consumió todos sus componentes: canon cuelga de él.
    return true;
}

fn readFileCapped(allocator: std.mem.Allocator, abs: []const u8, cap: u64) AcpError![]u8 {
    const abs_z = allocator.dupeZ(u8, abs) catch return error.OutOfMemory;
    defer allocator.free(abs_z);
    const h = CreateFileA(abs_z.ptr, GENERIC_READ_T, FILE_SHARE_READ_WRITE_T, null, OPEN_EXISTING_T, FILE_ATTRIBUTE_NORMAL_T, null);
    if (h == null) return error.FsError;
    defer _ = CloseHandle(h);
    var size: i64 = 0;
    if (GetFileSizeEx(h, &size) == 0 or size < 0) return error.FsError;
    if (@as(u64, @intCast(size)) > cap) return error.FsError; // honesto: demasiado grande
    const buf = allocator.alloc(u8, @intCast(size)) catch return error.OutOfMemory;
    errdefer allocator.free(buf);
    var n: u32 = 0;
    if (buf.len > 0 and (ReadFile(h, buf.ptr, @intCast(buf.len), &n, null) == 0 or n != buf.len)) return error.FsError;
    return buf;
}

fn writeFileAbs(allocator: std.mem.Allocator, abs: []const u8, data: []const u8) AcpError!void {
    // Padres primero (el ancestro ya está validado canónicamente).
    var buf: [4096:0]u8 = undefined;
    if (abs.len >= buf.len) return error.FsDenied;
    @memcpy(buf[0..abs.len], abs);
    var i: usize = 0;
    while (i < abs.len) : (i += 1) {
        const c = abs[i];
        if ((c == '\\' or c == '/') and i > 0) {
            buf[i] = 0;
            _ = CreateDirectoryA(@ptrCast(&buf[0]), null);
            buf[i] = c;
        }
    }
    const abs_z = allocator.dupeZ(u8, abs) catch return error.OutOfMemory;
    defer allocator.free(abs_z);
    const h = CreateFileA(abs_z.ptr, GENERIC_WRITE_T, 0, null, CREATE_ALWAYS_T, FILE_ATTRIBUTE_NORMAL_T, null);
    if (h == null) return error.FsError;
    defer _ = CloseHandle(h);
    var n: u32 = 0;
    if (data.len > 0 and (WriteFile(h, data.ptr, @intCast(data.len), &n, null) == 0 or n != data.len)) return error.FsError;
}

// ── Fixtures Win32 (los tests de fs trabajan con rutas absolutas reales) ──

var acp_tmp_counter: u32 = 0;

fn mkAcpTmpRoot(a: std.mem.Allocator) ![]u8 {
    var sys_buf: [1024]u8 = undefined;
    const len = GetTempPathA(1024, &sys_buf);
    const sys_temp = if (len > 0 and len < 1024) sys_buf[0..len] else "C:\\Windows\\Temp\\";
    acp_tmp_counter += 1;
    const root = try std.fmt.allocPrint(a, "{s}beats-acp-{d}-{d}", .{ sys_temp, GetTickCount64(), acp_tmp_counter });
    if (!mkDirAbs(root)) return error.FsError;
    return root;
}

fn mkDirAbs(path: []const u8) bool {
    var buf: [4096:0]u8 = undefined;
    if (path.len >= buf.len) return false;
    @memcpy(buf[0..path.len], path);
    var i: usize = 0;
    while (i < path.len) : (i += 1) {
        const c = path[i];
        if ((c == '\\' or c == '/') and i > 0) {
            buf[i] = 0;
            _ = CreateDirectoryA(@ptrCast(&buf[0]), null);
            buf[i] = c;
        }
    }
    buf[path.len] = 0;
    _ = CreateDirectoryA(@ptrCast(&buf[0]), null);
    return true;
}

fn fileExistsAbs(abs: []const u8) bool {
    const z = std.heap.page_allocator.dupeZ(u8, abs) catch return false;
    defer std.heap.page_allocator.free(z);
    return GetFileAttributesA(z.ptr) != 0xFFFFFFFF;
}

fn deleteFileAbs(abs: []const u8) void {
    const z = std.heap.page_allocator.dupeZ(u8, abs) catch return;
    defer std.heap.page_allocator.free(z);
    _ = DeleteFileA(z.ptr);
}

fn removeDirAbs(abs: []const u8) void {
    const z = std.heap.page_allocator.dupeZ(u8, abs) catch return;
    defer std.heap.page_allocator.free(z);
    _ = RemoveDirectoryA(z.ptr);
}

// ── Tests ──────────────────────────────────────────────────────────────
// Transporte scriptado: las líneas que el "agente" emite se precargan; las
// escrituras del cliente (requests y respuestas a peticiones del agente) se
// graban para aserción. Las peticiones agente→cliente se contestan por el
// propio cliente durante el pump — el script solo tiene que ofrecerlas en
// orden antes de la respuesta final.

const ScriptCtx = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList([]const u8),
    written: std.ArrayList([]const u8),
    /// Cuántas líneas de respuesta quedan; cuando se agotan, cada read hace
    /// Sleep corto + error.Timeout (agente vivo pero mudo).
    hang_on_empty: bool = false,

    fn write(ctx: *anyopaque, data: []const u8) mcp_client.McpError!void {
        const self: *ScriptCtx = @ptrCast(@alignCast(ctx));
        const copy = self.allocator.dupe(u8, data) catch return error.OutOfMemory;
        self.written.append(self.allocator, copy) catch {
            self.allocator.free(copy);
            return error.OutOfMemory;
        };
    }

    fn read(ctx: *anyopaque, allocator: std.mem.Allocator) mcp_client.McpError![]u8 {
        const self: *ScriptCtx = @ptrCast(@alignCast(ctx));
        if (self.lines.items.len == 0) {
            if (self.hang_on_empty) {
                Sleep(5);
                return error.Timeout; // el pump decide si seguir o vencer
            }
            return error.ProtocolError;
        }
        const line = self.lines.orderedRemove(0);
        defer self.allocator.free(line);
        return allocator.dupe(u8, line) catch return error.OutOfMemory;
    }

    fn close(ctx: *anyopaque) void {
        const self: *ScriptCtx = @ptrCast(@alignCast(ctx));
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
        for (self.written.items) |w| self.allocator.free(w);
        self.written.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

const ScriptTransport = struct {
    transport: mcp_client.McpTransport,
    ctx: *ScriptCtx,
};

fn scripted(allocator: std.mem.Allocator, lines: []const []const u8) !ScriptTransport {
    const ctx = try allocator.create(ScriptCtx);
    ctx.* = .{ .allocator = allocator, .lines = .empty, .written = .empty };
    for (lines) |l| try ctx.lines.append(allocator, try allocator.dupe(u8, l));
    return .{
        .transport = .{ .ptr = ctx, .writeFn = ScriptCtx.write, .readFn = ScriptCtx.read, .closeFn = ScriptCtx.close },
        .ctx = ctx,
    };
}

fn writtenJoined(ctx: *ScriptCtx, allocator: std.mem.Allocator) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    for (ctx.written.items) |w| out.writer.writeAll(w) catch return error.OutOfMemory;
    return allocator.dupe(u8, out.written());
}

// Sink de prueba: colecciona kinds y textos.
const SinkCollector = struct {
    kinds: std.ArrayList(UpdateKind) = .empty,
    texts: std.ArrayList([]const u8) = .empty,
    allocator: std.mem.Allocator,

    fn onEvent(ctx: ?*anyopaque, ev: *const SessionEvent) void {
        const self: *SinkCollector = @ptrCast(@alignCast(ctx.?));
        self.kinds.append(self.allocator, ev.kind) catch {};
        if (ev.text) |t| {
            const copy = self.allocator.dupe(u8, t) catch return;
            self.texts.append(self.allocator, copy) catch {
                self.allocator.free(copy);
            };
        }
    }

    fn deinit(self: *SinkCollector) void {
        self.kinds.deinit(self.allocator);
        for (self.texts.items) |t| self.allocator.free(t);
        self.texts.deinit(self.allocator);
    }
};

const INIT_RESP = "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":1,\"agentCapabilities\":{\"loadSession\":false,\"promptCapabilities\":{\"image\":true,\"audio\":false,\"embeddedContext\":true}},\"agentInfo\":{\"name\":\"acp-mock\",\"title\":\"ACP Mock\",\"version\":\"0.1.0\"},\"authMethods\":[]}}";
const NEW_RESP = "{\"jsonrpc\":\"2.0\",\"id\":2,\"result\":{\"sessionId\":\"sess-1\"}}";

test "acp initialize anuncia fs r/w y terminal apagado" {
    const allocator = std.testing.allocator;
    const st = try scripted(allocator, &.{INIT_RESP});
    var client = AcpClient.init(allocator, st.transport, 2000);
    defer client.deinit();
    try client.initialize();

    const w = try writtenJoined(st.ctx, allocator);
    defer allocator.free(w);
    try std.testing.expect(std.mem.indexOf(u8, w, "\"method\":\"initialize\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "\"protocolVersion\":1") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "\"readTextFile\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "\"writeTextFile\":true") != null);
    // NUNCA terminal:true — la ejecución queda con el ejecutor gobernado.
    try std.testing.expect(std.mem.indexOf(u8, w, "\"terminal\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "\"terminal\":true") == null);

    try std.testing.expectEqual(@as(u16, 1), client.agent_info.protocol_version);
    try std.testing.expectEqualStrings("acp-mock", client.agent_info.name);
    try std.testing.expect(client.agent_info.prompt_image);
    try std.testing.expect(!client.agent_info.prompt_audio);
    try std.testing.expect(client.agent_info.prompt_embedded_context);
}

test "acp initialize rechaza una versión de protocolo que no sea 1" {
    const allocator = std.testing.allocator;
    const st = try scripted(allocator, &.{"{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"protocolVersion\":2}}"});
    var client = AcpClient.init(allocator, st.transport, 2000);
    defer client.deinit();
    try std.testing.expectError(error.UnsupportedVersion, client.initialize());
}

test "acp session/new manda el worktree como cwd y sin mcpServers" {
    const allocator = std.testing.allocator;
    const st = try scripted(allocator, &.{ INIT_RESP, NEW_RESP });
    var client = AcpClient.init(allocator, st.transport, 2000);
    defer client.deinit();
    try client.initialize();
    const sid = try client.sessionNew("C:\\repo\\worktree");
    try std.testing.expectEqualStrings("sess-1", sid);
    try std.testing.expectEqualStrings("C:\\repo\\worktree", client.fs_root.?);

    const w = try writtenJoined(st.ctx, allocator);
    defer allocator.free(w);
    try std.testing.expect(std.mem.indexOf(u8, w, "\"method\":\"session/new\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "\"cwd\":\"C:\\\\repo\\\\worktree\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "\"mcpServers\":[]") != null);
}

test "acp prompt mapea session/update a eventos DevAgents" {
    const allocator = std.testing.allocator;
    const st = try scripted(allocator, &.{
        INIT_RESP,
        NEW_RESP,
        "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"sess-1\",\"update\":{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"pensando\"}}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"sess-1\",\"update\":{\"sessionUpdate\":\"tool_call\",\"toolCallId\":\"c1\",\"title\":\"Editar\",\"kind\":\"edit\",\"status\":\"in_progress\"}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"sess-1\",\"update\":{\"sessionUpdate\":\"plan\",\"entries\":[{\"content\":\"paso\",\"priority\":\"high\",\"status\":\"pending\"}]}}}",
        "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"sess-1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"hola\"}}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"stopReason\":\"end_turn\"}}",
    });
    var client = AcpClient.init(allocator, st.transport, 2000);
    defer client.deinit();
    try client.initialize();
    const sid = try client.sessionNew("C:\\repo\\wt");
    var sink_ctx = SinkCollector{ .allocator = allocator };
    defer sink_ctx.deinit();
    client.update_sink = .{ .ctx = &sink_ctx, .func = SinkCollector.onEvent };

    const res = try client.prompt(sid, "edita", 5000);
    try std.testing.expectEqual(StopReason.end_turn, res.stop_reason);

    try std.testing.expectEqual(@as(usize, 4), sink_ctx.kinds.items.len);
    try std.testing.expectEqual(UpdateKind.reasoning, sink_ctx.kinds.items[0]);
    try std.testing.expectEqual(UpdateKind.tool, sink_ctx.kinds.items[1]);
    try std.testing.expectEqual(UpdateKind.plan, sink_ctx.kinds.items[2]);
    try std.testing.expectEqual(UpdateKind.content, sink_ctx.kinds.items[3]);
    try std.testing.expectEqualStrings("pensando", sink_ctx.texts.items[0]);
    try std.testing.expectEqualStrings("hola", sink_ctx.texts.items[1]);
}

test "acp fs/read_text_file lee confinado y fs/write fuera queda rechazado" {
    const allocator = std.testing.allocator;
    const root = try mkAcpTmpRoot(allocator);
    defer allocator.free(root);
    defer removeDirAbs(root);
    const inside = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "leer.txt", .{root});
    defer allocator.free(inside);
    try writeFileAbs(allocator, inside, "uno\ndos\ntres\n");
    defer deleteFileAbs(inside);
    // Escapar: ruta absoluta fuera del root (el directorio padre de %TEMP%).
    const fuera_abs = try std.fs.path.resolve(allocator, &.{ root, "..", "fuera_acp.txt" });
    defer allocator.free(fuera_abs);
    deleteFileAbs(fuera_abs);

    const req_read = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":100,\"method\":\"fs/read_text_file\",\"params\":{{\"sessionId\":\"sess-1\",\"path\":{f},\"line\":2,\"limit\":1}}}}", .{std.json.fmt(inside, .{})});
    defer allocator.free(req_read);
    const req_write_out = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":101,\"method\":\"fs/write_text_file\",\"params\":{{\"sessionId\":\"sess-1\",\"path\":{f},\"content\":\"x\"}}}}", .{std.json.fmt(fuera_abs, .{})});
    defer allocator.free(req_write_out);

    const st = try scripted(allocator, &.{
        INIT_RESP,
        NEW_RESP,
        req_read,
        req_write_out,
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"stopReason\":\"end_turn\"}}",
    });
    var client = AcpClient.init(allocator, st.transport, 2000);
    defer client.deinit();
    try client.initialize();
    const sid = try client.sessionNew(root);
    const res = try client.prompt(sid, "lee", 5000);
    try std.testing.expectEqual(StopReason.end_turn, res.stop_reason);

    const w = try writtenJoined(st.ctx, allocator);
    defer allocator.free(w);
    // La lectura devolvió la línea 2 ("dos").
    try std.testing.expect(std.mem.indexOf(u8, w, "\"id\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "\"result\":{\"content\":\"dos\"}") != null);
    // La escritura fuera del worktree: error JSON-RPC, no result.
    const eidx = std.mem.indexOf(u8, w, "\"id\":101").?;
    try std.testing.expect(std.mem.indexOf(u8, w[eidx..], "\"error\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, w[eidx..], "FsDenied") != null);
    // Y el archivo jamás se creó.
    try std.testing.expect(!fileExistsAbs(fuera_abs));
}

test "acp fs/write_text_file dentro del worktree escribe" {
    const allocator = std.testing.allocator;
    const root = try mkAcpTmpRoot(allocator);
    defer allocator.free(root);
    defer removeDirAbs(root);
    const subdir = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "sub", .{root});
    defer allocator.free(subdir);
    defer removeDirAbs(subdir);
    const dst = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "sub" ++ std.fs.path.sep_str ++ "nuevo.txt", .{root});
    defer allocator.free(dst);
    defer deleteFileAbs(dst);

    const req = try std.fmt.allocPrint(allocator, "{{\"jsonrpc\":\"2.0\",\"id\":100,\"method\":\"fs/write_text_file\",\"params\":{{\"sessionId\":\"sess-1\",\"path\":{f},\"content\":\"hola acp\"}}}}", .{std.json.fmt(dst, .{})});
    defer allocator.free(req);

    const st = try scripted(allocator, &.{
        INIT_RESP,
        NEW_RESP,
        req,
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"stopReason\":\"end_turn\"}}",
    });
    var client = AcpClient.init(allocator, st.transport, 2000);
    defer client.deinit();
    try client.initialize();
    const sid = try client.sessionNew(root);
    _ = try client.prompt(sid, "escribe", 5000);

    const content = try readFileCapped(allocator, dst, 1024);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("hola acp", content);
}

fn testConfinedWrite(client: *AcpClient, path: []const u8, content: []const u8) !void {
    const json = try std.fmt.allocPrint(client.allocator, "{{\"path\":{f},\"content\":{f}}}", .{ std.json.fmt(path, .{}), std.json.fmt(content, .{}) });
    defer client.allocator.free(json);
    var parsed = try std.json.parseFromSlice(std.json.Value, client.allocator, json, .{});
    defer parsed.deinit();
    try client.fsWriteTextFile(parsed.value);
}

test "SEC-FS ACP mutation rejects aliases and truncates the validated file" {
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const root = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(root);
    const st = try scripted(a, &.{});
    var client = AcpClient.init(a, st.transport, 2000);
    defer client.deinit();
    client.fs_root = try a.dupe(u8, root);
    const path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "sub" ++ std.fs.path.sep_str ++ "file.txt", .{root});
    defer a.free(path);
    try testConfinedWrite(&client, path, "long original content");
    try testConfinedWrite(&client, path, "ok");
    const data = try readFileCapped(a, path, 1024);
    defer a.free(data);
    try std.testing.expectEqualStrings("ok", data);
    const aliases: []const []const u8 = if (@import("builtin").os.tag == .windows) &.{ "sub\\..\\file.txt", "file.txt:stream", "NUL.txt", "file.txt.", "..\\outside.txt" } else &.{ "sub/../file.txt", "../outside.txt", "sub//file.txt", "sub/./file.txt", "file\x00.txt" };
    for (aliases) |rel| {
        const invalid = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ root, rel });
        defer a.free(invalid);
        try std.testing.expectError(error.FsDenied, testConfinedWrite(&client, invalid, "denied"));
    }
    try std.testing.expectEqual(error.OutOfMemory, AcpClient.mutationError(error.OutOfMemory));
}

test "SEC-FS ACP mutation denies hard links without changing outside bytes" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: la prueba usa API de Windows (procesos, ACL, enlaces, atributos o registro); omitida en Linux");
    const Api = struct {
        extern "kernel32" fn CreateHardLinkW([*:0]const u16, [*:0]const u16, ?*anyopaque) callconv(.winapi) c_int;
    };
    const a = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const temp = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(temp);
    const root = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "root", .{temp});
    defer a.free(root);
    try std.testing.expect(mkDirAbs(root));
    const outside = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "outside.txt", .{temp});
    defer a.free(outside);
    try writeFileAbs(a, outside, "untouched");
    const link = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "link.txt", .{root});
    defer a.free(link);
    const outside_w = try std.unicode.utf8ToUtf16LeAllocZ(a, outside);
    defer a.free(outside_w);
    const link_w = try std.unicode.utf8ToUtf16LeAllocZ(a, link);
    defer a.free(link_w);
    try std.testing.expect(Api.CreateHardLinkW(link_w, outside_w, null) != 0);
    const st = try scripted(a, &.{});
    var client = AcpClient.init(a, st.transport, 2000);
    defer client.deinit();
    client.fs_root = try a.dupe(u8, root);
    try std.testing.expectError(error.FsDenied, testConfinedWrite(&client, link, "changed"));
    const data = try readFileCapped(a, outside, 1024);
    defer a.free(data);
    try std.testing.expectEqualStrings("untouched", data);
}

const PermProbe = struct {
    allow: bool,
    seen_path: ?[]u8 = null,
    allocator: std.mem.Allocator,

    fn decide(ctx: ?*anyopaque, session_id: []const u8, tool_call_json: []const u8, options_json: []const u8) anyerror!PermissionOutcome {
        const self: *PermProbe = @ptrCast(@alignCast(ctx.?));
        _ = session_id;
        _ = options_json;
        // extrae locations[0].path si existe
        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, tool_call_json, .{}) catch return .cancelled;
        defer parsed.deinit();
        if (parsed.value == .object) {
            if (parsed.value.object.get("locations")) |loc| {
                if (loc == .array and loc.array.items.len > 0 and loc.array.items[0] == .object) {
                    if (loc.array.items[0].object.get("path")) |p| {
                        if (p == .string) self.seen_path = self.allocator.dupe(u8, p.string) catch null;
                    }
                }
            }
        }
        return if (self.allow) .{ .selected = "allow-once" } else .{ .selected = "reject-once" };
    }
};

test "acp session/request_permission pasa por la seam y responde la opción" {
    const allocator = std.testing.allocator;
    const req = "{\"jsonrpc\":\"2.0\",\"id\":100,\"method\":\"session/request_permission\",\"params\":{\"sessionId\":\"sess-1\",\"toolCall\":{\"toolCallId\":\"c1\",\"title\":\"Editar\",\"kind\":\"edit\"},\"options\":[{\"optionId\":\"allow-once\",\"name\":\"Permitir\",\"kind\":\"allow_once\"},{\"optionId\":\"reject-once\",\"name\":\"Rechazar\",\"kind\":\"reject_once\"}]}}";
    const st = try scripted(allocator, &.{
        INIT_RESP,
        NEW_RESP,
        req,
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"stopReason\":\"end_turn\"}}",
    });
    var client = AcpClient.init(allocator, st.transport, 2000);
    defer client.deinit();
    try client.initialize();
    const sid = try client.sessionNew("C:\\repo\\wt");
    var probe = PermProbe{ .allow = true, .allocator = allocator };
    client.permission_fn = PermProbe.decide;
    client.permission_ctx = &probe;

    _ = try client.prompt(sid, "p", 5000);
    const w = try writtenJoined(st.ctx, allocator);
    defer allocator.free(w);
    try std.testing.expect(std.mem.indexOf(u8, w, "\"id\":100") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "\"outcome\":\"selected\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "\"optionId\":\"allow-once\"") != null);
}

test "acp permiso sin gobernanza cableada responde cancelled (fail-closed)" {
    const allocator = std.testing.allocator;
    const req = "{\"jsonrpc\":\"2.0\",\"id\":100,\"method\":\"session/request_permission\",\"params\":{\"sessionId\":\"sess-1\",\"toolCall\":{\"toolCallId\":\"c1\"},\"options\":[{\"optionId\":\"allow-once\",\"kind\":\"allow_once\"}]}}";
    const st = try scripted(allocator, &.{
        INIT_RESP,
        NEW_RESP,
        req,
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"stopReason\":\"end_turn\"}}",
    });
    var client = AcpClient.init(allocator, st.transport, 2000);
    defer client.deinit();
    try client.initialize();
    const sid = try client.sessionNew("C:\\repo\\wt");
    _ = try client.prompt(sid, "p", 5000);
    const w = try writtenJoined(st.ctx, allocator);
    defer allocator.free(w);
    try std.testing.expect(std.mem.indexOf(u8, w, "\"outcome\":\"cancelled\"") != null);
}

test "acp una opción no ofrecida se convierte en cancelled" {
    const allocator = std.testing.allocator;
    const req = "{\"jsonrpc\":\"2.0\",\"id\":100,\"method\":\"session/request_permission\",\"params\":{\"sessionId\":\"sess-1\",\"toolCall\":{\"toolCallId\":\"c1\"},\"options\":[{\"optionId\":\"reject-once\",\"kind\":\"reject_once\"}]}}";
    const st = try scripted(allocator, &.{
        INIT_RESP,
        NEW_RESP,
        req,
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"stopReason\":\"end_turn\"}}",
    });
    var client = AcpClient.init(allocator, st.transport, 2000);
    defer client.deinit();
    try client.initialize();
    const sid = try client.sessionNew("C:\\repo\\wt");
    var probe = PermProbe{ .allow = true, .allocator = allocator }; // intenta "allow-once", no ofrecida
    client.permission_fn = PermProbe.decide;
    client.permission_ctx = &probe;
    _ = try client.prompt(sid, "p", 5000);
    const w = try writtenJoined(st.ctx, allocator);
    defer allocator.free(w);
    try std.testing.expect(std.mem.indexOf(u8, w, "\"outcome\":\"cancelled\"") != null);
}

test "acp línea malformada del agente es ProtocolError, no crash" {
    const allocator = std.testing.allocator;
    const st = try scripted(allocator, &.{
        INIT_RESP,
        NEW_RESP,
        "###MALFORMED-NO-JSON###",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"stopReason\":\"end_turn\"}}",
    });
    var client = AcpClient.init(allocator, st.transport, 2000);
    defer client.deinit();
    try client.initialize();
    const sid = try client.sessionNew("C:\\repo\\wt");
    try std.testing.expectError(error.ProtocolError, client.prompt(sid, "p", 5000));
}

test "acp cancel envía session/cancel y el stopReason cancelled se propaga" {
    const allocator = std.testing.allocator;
    const st = try scripted(allocator, &.{
        INIT_RESP,
        NEW_RESP,
        "{\"jsonrpc\":\"2.0\",\"method\":\"session/update\",\"params\":{\"sessionId\":\"sess-1\",\"update\":{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"trabajando\"}}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"result\":{\"stopReason\":\"cancelled\"}}",
    });
    var client = AcpClient.init(allocator, st.transport, 2000);
    defer client.deinit();
    try client.initialize();
    const sid = try client.sessionNew("C:\\repo\\wt");

    // Sink que activa la cancelación al recibir el primer chunk.
    const SinkCtx = struct {
        client: *AcpClient,
        fn onEvent(ctx: ?*anyopaque, ev: *const SessionEvent) void {
            _ = ev;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.client.cancel();
        }
    };
    var sink = SinkCtx{ .client = &client };
    client.update_sink = .{ .ctx = &sink, .func = SinkCtx.onEvent };

    const res = try client.prompt(sid, "p", 5000);
    try std.testing.expectEqual(StopReason.cancelled, res.stop_reason);
    const w = try writtenJoined(st.ctx, allocator);
    defer allocator.free(w);
    try std.testing.expect(std.mem.indexOf(u8, w, "\"method\":\"session/cancel\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, w, "\"sessionId\":\"sess-1\"") != null);
}

test "acp timeout del turno cuando el agente no responde" {
    const allocator = std.testing.allocator;
    const st = try scripted(allocator, &.{ INIT_RESP, NEW_RESP });
    st.ctx.hang_on_empty = true;
    var client = AcpClient.init(allocator, st.transport, 300);
    defer client.deinit();
    try client.initialize();
    const sid = try client.sessionNew("C:\\repo\\wt");
    try std.testing.expectError(error.Timeout, client.prompt(sid, "p", 300));
}

// ── E5.06: pruebas de pipe real contra acp-mock-agent.exe ───────────────
// El exe se construye con `zig build` (mismo paso que mcp-mock-server).
// Patrón argv con nombre pelado + cwd = zig-out\bin.

fn connectMock(allocator: std.mem.Allocator, scenario: []const u8) !AcpClient {
    const arg = try std.fmt.allocPrint(allocator, "--scenario={s}", .{scenario});
    defer allocator.free(arg);
    const argv = [_][]const u8{ "acp-mock-agent.exe", arg };
    const bin = (try @import("headless_adapter.zig").defaultGetEnv(allocator, "BEATS_TEST_BIN_DIR")) orelse return error.MissingTestBinDir;
    defer allocator.free(bin);
    return AcpClient.connect(allocator, &argv, bin, 15000);
}

test "E5.06 agente real: turno completo escribe dentro del worktree" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: el agente ACP de prueba se lanza con rutas Windows (barra invertida) y acp-mock-agent.exe; omitida en Linux");
    const allocator = std.testing.allocator;
    const root = try mkAcpTmpRoot(allocator);
    defer allocator.free(root);
    defer removeDirAbs(root);
    const dst = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "saludo.txt", .{root});
    defer allocator.free(dst);
    defer deleteFileAbs(dst);

    var client = try connectMock(allocator, "normal");
    defer client.deinit();
    try client.initialize();
    try std.testing.expectEqualStrings("acp-mock-agent", client.agent_info.name);
    try std.testing.expectEqual(@as(usize, 0), client.agent_info.auth_methods);

    const sid = try client.sessionNew(root);
    try std.testing.expectEqualStrings("acp-mock-sess-1", sid);
    var sink = SinkCollector{ .allocator = allocator };
    defer sink.deinit();
    client.update_sink = .{ .ctx = &sink, .func = SinkCollector.onEvent };

    const res = try client.prompt(sid, "escribe el saludo", 15000);
    try std.testing.expectEqual(StopReason.end_turn, res.stop_reason);

    // El archivo llegó al worktree por la capability fs del cliente.
    const content = try readFileCapped(allocator, dst, 1024);
    defer allocator.free(content);
    try std.testing.expectEqualStrings("HOLA ACP\n", content);

    // Eventos mapeados: reasoning + tool_call + tool_call_update + plan + content.
    var saw_reasoning = false;
    var saw_tool = false;
    var saw_plan = false;
    var saw_content = false;
    for (sink.kinds.items) |k| switch (k) {
        .reasoning => saw_reasoning = true,
        .tool => saw_tool = true,
        .plan => saw_plan = true,
        .content => saw_content = true,
        else => {},
    };
    try std.testing.expect(saw_reasoning and saw_tool and saw_plan and saw_content);
}

const PermAllowAll = struct {
    fn allow(ctx: ?*anyopaque, session_id: []const u8, tool_call_json: []const u8, options_json: []const u8) anyerror!PermissionOutcome {
        _ = ctx;
        _ = session_id;
        _ = tool_call_json;
        _ = options_json;
        return .{ .selected = "allow-once" };
    }
    fn reject(ctx: ?*anyopaque, session_id: []const u8, tool_call_json: []const u8, options_json: []const u8) anyerror!PermissionOutcome {
        _ = ctx;
        _ = session_id;
        _ = tool_call_json;
        _ = options_json;
        return .{ .selected = "reject-once" };
    }
};

test "E5.06 agente real: permiso dentro + allow escribe el archivo" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: el agente ACP de prueba se lanza con rutas Windows (barra invertida) y acp-mock-agent.exe; omitida en Linux");
    const allocator = std.testing.allocator;
    const root = try mkAcpTmpRoot(allocator);
    defer allocator.free(root);
    defer removeDirAbs(root);
    const dst = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "dentro.txt", .{root});
    defer allocator.free(dst);
    defer deleteFileAbs(dst);

    var client = try connectMock(allocator, "perm-inside");
    defer client.deinit();
    try client.initialize();
    const sid = try client.sessionNew(root);
    client.permission_fn = PermAllowAll.allow;
    const res = try client.prompt(sid, "p", 15000);
    try std.testing.expectEqual(StopReason.end_turn, res.stop_reason);
    try std.testing.expect(fileExistsAbs(dst));
}

test "E5.06 agente real: permiso concedido pero ruta fuera queda confinada" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: el agente ACP de prueba se lanza con rutas Windows (barra invertida) y acp-mock-agent.exe; omitida en Linux");
    const allocator = std.testing.allocator;
    const root = try mkAcpTmpRoot(allocator);
    defer allocator.free(root);
    defer removeDirAbs(root);
    const parent = std.fs.path.dirname(root).?;
    const fuera = try std.fmt.allocPrint(allocator, "{s}" ++ std.fs.path.sep_str ++ "fuera_acp.txt", .{parent});
    defer allocator.free(fuera);
    deleteFileAbs(fuera);
    defer deleteFileAbs(fuera);

    var client = try connectMock(allocator, "perm-outside");
    defer client.deinit();
    try client.initialize();
    const sid = try client.sessionNew(root);
    // Aunque la seam diga "allow-once", la escritura fuera del worktree se niega.
    client.permission_fn = PermAllowAll.allow;
    const res = try client.prompt(sid, "p", 15000);
    try std.testing.expectEqual(StopReason.end_turn, res.stop_reason);
    try std.testing.expect(!fileExistsAbs(fuera));
}

test "E5.06 agente real: línea malformada produce ProtocolError y deinit mata" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: el agente ACP de prueba se lanza con rutas Windows (barra invertida) y acp-mock-agent.exe; omitida en Linux");
    const allocator = std.testing.allocator;
    const root = try mkAcpTmpRoot(allocator);
    defer allocator.free(root);
    defer removeDirAbs(root);

    var client = try connectMock(allocator, "malformed");
    defer client.deinit();
    try client.initialize();
    const sid = try client.sessionNew(root);
    try std.testing.expectError(error.ProtocolError, client.prompt(sid, "p", 8000));
}

test "E5.06 agente real: agente mudo vence el deadline del turno" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: el agente ACP de prueba se lanza con rutas Windows (barra invertida) y acp-mock-agent.exe; omitida en Linux");
    const allocator = std.testing.allocator;
    const root = try mkAcpTmpRoot(allocator);
    defer allocator.free(root);
    defer removeDirAbs(root);

    var client = try connectMock(allocator, "hang");
    defer client.deinit();
    try client.initialize();
    const sid = try client.sessionNew(root);
    const t0 = GetTickCount64();
    try std.testing.expectError(error.Timeout, client.prompt(sid, "p", 900));
    // El deadline realmente corta (no cuelga ni "pasa de largo").
    try std.testing.expect(GetTickCount64() - t0 < 8000);
}

test "E5.06 agente real: cancelación de la orden → stopReason cancelled" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: el agente ACP de prueba se lanza con rutas Windows (barra invertida) y acp-mock-agent.exe; omitida en Linux");
    const allocator = std.testing.allocator;
    const root = try mkAcpTmpRoot(allocator);
    defer allocator.free(root);
    defer removeDirAbs(root);

    var client = try connectMock(allocator, "cancel");
    defer client.deinit();
    try client.initialize();
    const sid = try client.sessionNew(root);
    // Cancela la orden al primer evento del agente.
    const SinkCtx = struct {
        client: *AcpClient,
        fn onEvent(ctx: ?*anyopaque, ev: *const SessionEvent) void {
            _ = ev;
            const self: *@This() = @ptrCast(@alignCast(ctx.?));
            self.client.cancel();
        }
    };
    var sink = SinkCtx{ .client = &client };
    client.update_sink = .{ .ctx = &sink, .func = SinkCtx.onEvent };

    const res = try client.prompt(sid, "p", 15000);
    try std.testing.expectEqual(StopReason.cancelled, res.stop_reason);
}
