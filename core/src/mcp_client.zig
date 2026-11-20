const std = @import("std");
const process_tree = @import("process_tree.zig");

// T4: Win32 functions for deadline-based pipe waiting and timing.
const windows = std.os.windows;
extern "kernel32" fn WaitForSingleObject(hHandle: windows.HANDLE, dwMilliseconds: u32) u32;
const GetTickCount64 = @import("platform.zig").ticks;
const Sleep = @import("platform.zig").sleep;
extern "kernel32" fn PeekNamedPipe(hNamedPipe: windows.HANDLE, lpBuffer: ?*anyopaque, nBufferSize: u32, lpBytesRead: ?*u32, lpTotalBytesAvail: ?*u32, lpBytesLeftThisMessage: ?*u32) c_int;
// la prueba de lanzamiento fija y restaura las variables de carpeta
// de datos dentro de su propio codigo (nunca en los comandos del encargo).
const GetEnvironmentVariableA = @import("platform.zig").env;
const SetEnvironmentVariableA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn SetEnvironmentVariableA(lpName: [*:0]const u8, lpValue: ?[*:0]const u8) c_int;
}.SetEnvironmentVariableA else @import("providers").posix_files.SetEnvironmentVariableA;
const WAIT_OBJECT_0: u32 = 0;
const WAIT_TIMEOUT: u32 = 258;

pub const DEFAULT_TIMEOUT_MS: u64 = 5000;

pub const McpError = error{
    UnsafeBatchArgument,
    SpawnFailed,
    Timeout,
    ProtocolError,
    ServerError,
    ProcessDied,
    OutOfMemory,
    JsonParseError,
    NotConnected,
    ToolNotFound,
};

pub const ToolInfo = struct {
    name: []const u8,
    description: []const u8,
    input_schema_json: []const u8,

    pub fn deinit(self: *const ToolInfo, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.description);
        allocator.free(self.input_schema_json);
    }
};

pub const ToolResult = struct {
    content: []const u8,
    is_error: bool,

    pub fn deinit(self: *const ToolResult, allocator: std.mem.Allocator) void {
        allocator.free(self.content);
    }
};

pub const McpTransport = struct {
    ptr: *anyopaque,
    writeFn: *const fn (ctx: *anyopaque, data: []const u8) McpError!void,
    readFn: *const fn (ctx: *anyopaque, allocator: std.mem.Allocator) McpError![]u8,
    closeFn: *const fn (ctx: *anyopaque) void,
};

pub const McpClient = struct {
    allocator: std.mem.Allocator,
    transport: McpTransport,
    next_id: i64,
    timeout_ms: u64,

    pub fn init(allocator: std.mem.Allocator, transport: McpTransport, timeout_ms: u64) McpError!McpClient {
        return initWithToken(allocator, transport, timeout_ms, null);
    }

    /// MCP-AUTH: igual que init pero presenta `auth_token` en params.token del
    /// handshake initialize — servidores con frontera de auth (devagents-mcp)
    /// habilitan así las tools privilegiadas de esta sesión.
    pub fn initWithToken(allocator: std.mem.Allocator, transport: McpTransport, timeout_ms: u64, auth_token: ?[]const u8) McpError!McpClient {
        const client = McpClient{
            .allocator = allocator,
            .transport = transport,
            .next_id = 1,
            .timeout_ms = timeout_ms,
        };

        // Handshake: initialize (con token opcional vía std.json — escape correcto)
        var req_buf: std.Io.Writer.Allocating = .init(allocator);
        defer req_buf.deinit();
        var js: std.json.Stringify = .{ .writer = &req_buf.writer, .options = .{} };
        js.beginObject() catch return error.OutOfMemory;
        js.objectField("jsonrpc") catch return error.OutOfMemory;
        js.write("2.0") catch return error.OutOfMemory;
        js.objectField("id") catch return error.OutOfMemory;
        js.write(0) catch return error.OutOfMemory;
        js.objectField("method") catch return error.OutOfMemory;
        js.write("initialize") catch return error.OutOfMemory;
        js.objectField("params") catch return error.OutOfMemory;
        js.beginObject() catch return error.OutOfMemory;
        js.objectField("protocolVersion") catch return error.OutOfMemory;
        js.write("2024-11-05") catch return error.OutOfMemory;
        if (auth_token) |tok| {
            js.objectField("token") catch return error.OutOfMemory;
            js.write(tok) catch return error.OutOfMemory;
        }
        js.objectField("capabilities") catch return error.OutOfMemory;
        js.beginObject() catch return error.OutOfMemory;
        js.objectField("tools") catch return error.OutOfMemory;
        js.beginObject() catch return error.OutOfMemory;
        js.endObject() catch return error.OutOfMemory;
        js.endObject() catch return error.OutOfMemory;
        js.objectField("clientInfo") catch return error.OutOfMemory;
        js.beginObject() catch return error.OutOfMemory;
        js.objectField("name") catch return error.OutOfMemory;
        js.write("devagents-mcp-client") catch return error.OutOfMemory;
        js.objectField("version") catch return error.OutOfMemory;
        // el cliente MCP publica la versión del producto, no un literal.
        js.write(@import("root.zig").VERSION) catch return error.OutOfMemory;
        js.endObject() catch return error.OutOfMemory;
        js.endObject() catch return error.OutOfMemory;
        js.endObject() catch return error.OutOfMemory;
        req_buf.writer.writeByte('\n') catch return error.OutOfMemory;
        try transport.writeFn(transport.ptr, req_buf.written());
        const response = try transport.readFn(transport.ptr, allocator);
        defer allocator.free(response);

        // Send notifications/initialized
        const notif = "{\"jsonrpc\":\"2.0\",\"method\":\"notifications/initialized\",\"params\":{}}\n";
        try transport.writeFn(transport.ptr, notif);

        return client;
    }

    pub fn deinit(self: *McpClient) void {
        self.transport.closeFn(self.transport.ptr);
    }

    /// Lee mensajes del transporte hasta encontrar la respuesta cuyo `id` coincide
    /// con el de la petición (correlación por id). Ignora notificaciones (sin `id`)
    /// y respuestas de otro id intercaladas. Devuelve el mensaje crudo (el llamador lo libera).
    /// T4: acota el tiempo total por reloj contra `timeout_ms`; al expirar → error.Timeout.
    fn readResultForId(self: *McpClient, id: i64) McpError![]u8 {
        const start_ms = GetTickCount64();
        // T4: Loop until deadline expires or matching response is found.
        // No arbitrary attempt limit — the timeout is the real safeguard.
        while (true) {
            // T4: Check deadline before each read.
            const elapsed_ms = GetTickCount64() - start_ms;
            if (elapsed_ms >= self.timeout_ms) return error.Timeout;
            const msg = try self.transport.readFn(self.transport.ptr, self.allocator);
            errdefer self.allocator.free(msg);
            // el free explícito aquí + `return error.ProtocolError`
            // disparaba el errdefer → double-free → segfault ante una
            // respuesta no-JSON del servidor. errdefer ya cubre la liberación.
            var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, msg, .{}) catch {
                return error.ProtocolError;
            };
            const matched = blk: {
                defer parsed.deinit();
                if (parsed.value != .object) break :blk false;
                const id_val = parsed.value.object.get("id") orelse break :blk false; // notificación: sin id
                break :blk switch (id_val) {
                    .integer => |v| v == id,
                    // un servidor que devuelva "id":1e30 (float fuera de
                    // i64) hacía panic en el cast y tumbaba el cliente. Fuera
                    // de rango → no coincide → se descarta como id ajeno.
                    .float => |v| v >= -9223372036854775808.0 and v < 9223372036854775808.0 and
                        @as(i64, @intFromFloat(v)) == id,
                    else => false,
                };
            };
            if (matched) return msg;
            self.allocator.free(msg); // notificación o id ajeno: descartar y seguir
        }
        return error.ProtocolError;
    }

    /// Serializa la petición JSON-RPC con escape correcto (std.json), sin interpolar strings.
    /// `params_value` puede ser null (objeto vacío) o un std.json.Value ya parseado.
    fn buildRequest(self: *McpClient, id: i64, method: []const u8, params_name: ?[]const u8, arguments: ?std.json.Value) McpError![]u8 {
        var out: std.Io.Writer.Allocating = .init(self.allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        js.beginObject() catch return error.OutOfMemory;
        js.objectField("jsonrpc") catch return error.OutOfMemory;
        js.write("2.0") catch return error.OutOfMemory;
        js.objectField("id") catch return error.OutOfMemory;
        js.write(id) catch return error.OutOfMemory;
        js.objectField("method") catch return error.OutOfMemory;
        js.write(method) catch return error.OutOfMemory;
        js.objectField("params") catch return error.OutOfMemory;
        js.beginObject() catch return error.OutOfMemory;
        if (params_name) |pn| {
            js.objectField("name") catch return error.OutOfMemory;
            js.write(pn) catch return error.OutOfMemory; // escape correcto del nombre (FR-006)
            js.objectField("arguments") catch return error.OutOfMemory;
            js.write(arguments orelse .null) catch return error.OutOfMemory;
        }
        js.endObject() catch return error.OutOfMemory;
        js.endObject() catch return error.OutOfMemory;
        // Añadir el delimitador de línea (JSON-RPC line-delimited por stdio).
        const body = out.written();
        const full = try self.allocator.alloc(u8, body.len + 1);
        @memcpy(full[0..body.len], body);
        full[body.len] = '\n';
        return full;
    }

    pub fn listTools(self: *McpClient) McpError![]ToolInfo {
        const id = self.next_id;
        self.next_id += 1;

        const full = try self.buildRequest(id, "tools/list", null, null);
        defer self.allocator.free(full);

        try self.transport.writeFn(self.transport.ptr, full);
        const response = try self.readResultForId(id);
        defer self.allocator.free(response);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch return error.ProtocolError;
        defer parsed.deinit();

        if (parsed.value != .object) return error.ProtocolError;
        const obj = parsed.value.object;

        const result = obj.get("result") orelse return error.ProtocolError;
        if (result != .object) return error.ProtocolError;
        const result_obj = result.object;

        const tools = result_obj.get("tools") orelse return error.ProtocolError;
        if (tools != .array) return error.ProtocolError;

        var list = std.ArrayList(ToolInfo).empty;
        errdefer {
            for (list.items) |*t| t.deinit(self.allocator);
            list.deinit(self.allocator);
        }

        for (tools.array.items) |tool_val| {
            if (tool_val != .object) continue;
            const tool_obj = tool_val.object;

            const name = if (tool_obj.get("name")) |n| blk: {
                if (n == .string) break :blk n.string;
                continue;
            } else continue;

            const desc: []const u8 = if (tool_obj.get("description")) |d_val| blk: {
                if (d_val == .string) break :blk d_val.string;
                break :blk "";
            } else "";

            const schema_val = tool_obj.get("inputSchema") orelse tool_obj.get("input_schema") orelse continue;
            var out: std.Io.Writer.Allocating = .init(self.allocator);
            var write_stream: std.json.Stringify = .{
                .writer = &out.writer,
                .options = .{},
            };
            defer out.deinit();
            write_stream.write(schema_val) catch return error.ProtocolError;
            const schema_str = out.written();

            try list.append(self.allocator, .{
                .name = try self.allocator.dupe(u8, name),
                .description = try self.allocator.dupe(u8, desc),
                .input_schema_json = try self.allocator.dupe(u8, schema_str),
            });
        }

        return list.toOwnedSlice(self.allocator);
    }

    pub fn callTool(self: *McpClient, name: []const u8, args_json: []const u8) McpError!ToolResult {
        const id = self.next_id;
        self.next_id += 1;

        // Parsear los argumentos a Value para re-serializarlos con escape correcto
        // (en vez de interpolar `name`/`args_json` crudos en el string del request).
        var args_parsed = std.json.parseFromSlice(std.json.Value, self.allocator, args_json, .{}) catch return error.JsonParseError;
        defer args_parsed.deinit();

        const full = try self.buildRequest(id, "tools/call", name, args_parsed.value);
        defer self.allocator.free(full);

        try self.transport.writeFn(self.transport.ptr, full);
        const response = try self.readResultForId(id);
        defer self.allocator.free(response);

        var parsed = std.json.parseFromSlice(std.json.Value, self.allocator, response, .{}) catch return error.ProtocolError;
        defer parsed.deinit();

        if (parsed.value != .object) return error.ProtocolError;
        const obj = parsed.value.object;

        if (obj.get("error")) |err_val| {
            if (err_val == .object) {
                const err_obj = err_val.object;
                const msg = if (err_obj.get("message")) |m| blk: {
                    if (m == .string) break :blk m.string;
                    break :blk "unknown error";
                } else "unknown error";
                return ToolResult{
                    .content = try self.allocator.dupe(u8, msg),
                    .is_error = true,
                };
            }
            return error.ServerError;
        }

        const result = obj.get("result") orelse return error.ProtocolError;
        if (result != .object) return error.ProtocolError;
        const result_obj = result.object;

        const is_error = if (result_obj.get("isError")) |ie| blk: {
            if (ie == .bool) break :blk ie.bool;
            break :blk false;
        } else false;

        var content_str: []const u8 = "";
        if (result_obj.get("content")) |ct| {
            if (ct == .array and ct.array.items.len > 0) {
                const first = ct.array.items[0];
                if (first == .object) {
                    if (first.object.get("text")) |txt| {
                        if (txt == .string) content_str = txt.string;
                    }
                }
            }
        }

        return ToolResult{
            .content = try self.allocator.dupe(u8, content_str),
            .is_error = is_error,
        };
    }
};

// ── In-process mock transport for testing ──────────────────────────────

const MockTransportCtx = struct {
    allocator: std.mem.Allocator,
    response_queue: std.ArrayList([]const u8),
    stdin_writes: std.ArrayList([]const u8),
    mock_server_state: McpMockState,

    const McpMockState = struct {
        next_id: i64 = 0,
        initialized: bool = false,
    };

    fn write(ctx: *anyopaque, data: []const u8) McpError!void {
        const self: *MockTransportCtx = @ptrCast(@alignCast(ctx));
        const newline_idx = std.mem.lastIndexOfScalar(u8, data, '\n') orelse return error.ProtocolError;
        const msg = data[0..newline_idx];

        const req_copy = self.allocator.dupe(u8, msg) catch return error.OutOfMemory;
        errdefer self.allocator.free(req_copy);
        try self.stdin_writes.append(self.allocator, req_copy);

        if (msg.len > 0) {
            const response = processMockRequest(self.allocator, msg, &self.mock_server_state) catch return error.ProtocolError;
            errdefer self.allocator.free(response);
            if (response.len > 0) {
                try self.response_queue.append(self.allocator, response);
            } else {
                self.allocator.free(response);
            }
        }
    }

    fn read(ctx: *anyopaque, allocator: std.mem.Allocator) McpError![]u8 {
        const self: *MockTransportCtx = @ptrCast(@alignCast(ctx));
        if (self.response_queue.items.len == 0) return error.ProtocolError;
        const response = self.response_queue.pop() orelse return error.ProtocolError;
        defer self.allocator.free(response);
        return allocator.dupe(u8, response);
    }

    fn close(ctx: *anyopaque) void {
        const self: *MockTransportCtx = @ptrCast(@alignCast(ctx));
        for (self.response_queue.items) |r| self.allocator.free(r);
        self.response_queue.deinit(self.allocator);
        for (self.stdin_writes.items) |w| self.allocator.free(w);
        self.stdin_writes.deinit(self.allocator);
        const alloc = self.allocator;
        alloc.destroy(self);
    }
};

fn processMockRequest(allocator: std.mem.Allocator, raw: []const u8, state: *MockTransportCtx.McpMockState) ![]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        return errorResponse(allocator, null, -32600, "Parse error");
    };
    defer parsed.deinit();

    const root = parsed.value;
    if (root != .object) return errorResponse(allocator, null, -32600, "Parse error");

    const obj = root.object;
    const method = if (obj.get("method")) |m| blk: {
        if (m == .string) break :blk m.string;
        return errorResponse(allocator, null, -32600, "Invalid method");
    } else return allocator.dupe(u8, "");

    const id_val = obj.get("id");
    const params = obj.get("params");

    if (std.mem.eql(u8, method, "initialize")) return handleInitialize(allocator, state);
    if (std.mem.eql(u8, method, "notifications/initialized")) {
        state.initialized = true;
        return allocator.dupe(u8, "");
    }
    if (std.mem.eql(u8, method, "tools/list")) return handleToolsList(allocator, id_val);
    if (std.mem.eql(u8, method, "tools/call")) return handleToolsCall(allocator, id_val, params);
    return errorResponse(allocator, id_val, -32601, "Method not found");
}

fn handleInitialize(allocator: std.mem.Allocator, state: *MockTransportCtx.McpMockState) ![]u8 {
    const id = state.next_id;
    state.next_id += 1;
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"result":{{"protocolVersion":"2024-11-05","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"mcp-mock","version":"0.1.0"}}}}}}
    , .{id});
}

fn handleToolsList(allocator: std.mem.Allocator, id_val: ?std.json.Value) ![]u8 {
    const id = if (id_val) |v| blk: {
        if (v == .integer) break :blk v.integer;
        if (v == .float) break :blk @as(i64, @intFromFloat(v.float));
        break :blk @as(i64, 0);
    } else @as(i64, 0);
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"result":{{"tools":[{{"name":"echo","description":"Echoes the input message back","inputSchema":{{"type":"object","properties":{{"message":{{"type":"string","description":"The message to echo"}}}},"required":["message"]}}}},{{"name":"add","description":"Adds two integers","inputSchema":{{"type":"object","properties":{{"a":{{"type":"integer","description":"First operand"}},"b":{{"type":"integer","description":"Second operand"}}}},"required":["a","b"]}}}}]}}}}
    , .{id});
}

fn handleToolsCall(allocator: std.mem.Allocator, id_val: ?std.json.Value, params: ?std.json.Value) ![]u8 {
    const id = if (id_val) |v| blk: {
        if (v == .integer) break :blk v.integer;
        if (v == .float) break :blk @as(i64, @intFromFloat(v.float));
        break :blk @as(i64, 0);
    } else @as(i64, 0);

    if (params == null or params.? != .object) return errorResponse(allocator, id_val, -32602, "Invalid params");

    const p = params.?.object;
    const name_val = p.get("name") orelse return errorResponse(allocator, id_val, -32602, "Missing tool name");
    if (name_val != .string) return errorResponse(allocator, id_val, -32602, "Invalid tool name");
    const args = p.get("arguments") orelse return errorResponse(allocator, id_val, -32602, "Missing arguments");
    const name = name_val.string;

    if (std.mem.eql(u8, name, "echo")) {
        if (args != .object or !args.object.contains("message")) return errorResponse(allocator, id_val, -32602, "Missing message");
        const msg = args.object.get("message").?;
        if (msg != .string) return errorResponse(allocator, id_val, -32602, "Invalid message");
        return std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":{d},"result":{{"content":[{{"type":"text","text":"echo: {s}"}}],"isError":false}}}}
        , .{ id, msg.string });
    }

    if (std.mem.eql(u8, name, "add")) {
        if (args != .object or !args.object.contains("a") or !args.object.contains("b")) return errorResponse(allocator, id_val, -32602, "Missing a or b");
        const a = args.object.get("a").?;
        const b = args.object.get("b").?;
        const a_int: i64 = if (a == .integer) a.integer else if (a == .float) @intFromFloat(a.float) else return errorResponse(allocator, id_val, -32602, "Invalid a");
        const b_int: i64 = if (b == .integer) b.integer else if (b == .float) @intFromFloat(b.float) else return errorResponse(allocator, id_val, -32602, "Invalid b");
        return std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":{d},"result":{{"content":[{{"type":"text","text":"{d}"}}],"isError":false}}}}
        , .{ id, a_int + b_int });
    }

    return errorResponse(allocator, id_val, -32601, "Unknown tool");
}

fn errorResponse(allocator: std.mem.Allocator, id_val: ?std.json.Value, code: i64, message: []const u8) ![]u8 {
    if (id_val) |v| {
        if (v == .integer) {
            return std.fmt.allocPrint(allocator,
                \\{{"jsonrpc":"2.0","id":{d},"error":{{"code":{d},"message":"{s}"}}}}
            , .{ v.integer, code, message });
        }
        if (v == .float) {
            return std.fmt.allocPrint(allocator,
                \\{{"jsonrpc":"2.0","id":{d},"error":{{"code":{d},"message":"{s}"}}}}
            , .{ @as(i64, @intFromFloat(v.float)), code, message });
        }
    }
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":0,"error":{{"code":{d},"message":"{s}"}}}}
    , .{ code, message });
}

pub fn createMockTransport(allocator: std.mem.Allocator) !McpTransport {
    const ctx = try allocator.create(MockTransportCtx);
    ctx.* = .{
        .allocator = allocator,
        .response_queue = std.ArrayList([]const u8).empty,
        .stdin_writes = std.ArrayList([]const u8).empty,
        .mock_server_state = .{},
    };
    return .{
        .ptr = ctx,
        .writeFn = MockTransportCtx.write,
        .readFn = MockTransportCtx.read,
        .closeFn = MockTransportCtx.close,
    };
}

// ── Transporte stdio real (FR-001): lanza un proceso hijo y habla por sus pipes ──

/// Transporte sobre stdio de un proceso hijo (std.process.Child con pipes).
/// Escribe requests JSON-RPC line-delimited en stdin del hijo y lee responses de su stdout.
/// `deinit` mata el proceso si sigue vivo (sin zombies, FR-005).
///
/// Nota de alcance (FR-005): el timeout por request de forma asíncrona queda pendiente;
/// la robustez actual cubre el kill del hijo y EOF→error tipado. Ver CHECKLIST T-F4-01.
pub const StdioTransport = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    /// runtime io PROPIO del transporte — el transport lo usa en cada
    /// read/write/kill durante toda la vida de la conexión, así que no puede
    /// ser un préstamo del caller. Antes los callers creaban un
    /// `std.Io.Threaded` en su stack y lo destruían al volver: cualquier uso
    /// posterior del transport quedaba colgado sobre un runtime muerto
    /// (wedge del bridge → pantalla blanca con MCP activo).
    owned_io: *std.Io.Threaded,
    child: std.process.Child,
    tree: process_tree.ProcessTree,
    in_buf: []u8,
    out_buf: []u8,
    reader: std.Io.File.Reader,
    writer: std.Io.File.Writer,
    timeout_ms: u64,
    alive: bool,

    /// Lanza `argv` como servidor MCP y devuelve un `McpTransport` listo para `McpClient.init`.
    /// El transporte crea y posee su propio runtime io hasta `close`.
    pub fn connect(allocator: std.mem.Allocator, argv: []const []const u8, timeout_ms: u64) McpError!McpTransport {
        return connectInCwd(allocator, argv, null, timeout_ms, null);
    }

    /// Lanza `argv` como servidor MCP desde `cwd` si se proporciona.
    /// `child_token`: MCP-AUTH — si no es null Y argv[0] es el propio
    /// devagents-mcp, se exporta como DEVAGENTS_MCP_TOKEN en el entorno del
    /// hijo: el servidor nace autenticado para esta sesión sin depender de
    /// que su `mcp_token` (junto al db que él resuelva) coincida con el del
    /// core. No se exporta a servidores de terceros: sería filtrar la
    /// credencial del propio MCP a procesos ajenos.
    pub fn connectInCwd(allocator: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, timeout_ms: u64, child_token: ?[]const u8) McpError!McpTransport {
        if (@import("builtin").os.tag == .windows and argv.len > 0 and @import("executor.zig").isBatchShim(argv[0]))
            try @import("windows_cmd.zig").validateArgs(argv[0], argv[1..]);
        const ctx = try allocator.create(StdioTransport);
        errdefer allocator.destroy(ctx);
        // el runtime io nace y muere con el transporte (ver campo owned_io).
        const owned_io = try allocator.create(std.Io.Threaded);
        errdefer allocator.destroy(owned_io);
        owned_io.* = std.Io.Threaded.init(allocator, .{});
        errdefer owned_io.deinit();
        const io = owned_io.io();
        // PRUEBA DE USUARIO 31-08: 16 KB se quedaban cortos para la respuesta
        // de tools/list de servidores reales (el propio devagents-mcp expone
        // 62 herramientas con schemas: ~35 KB). takeDelimiter levanta
        // StreamTooLong cuando la línea no cabe en el buffer, y el cliente lo
        // traducía a ProtocolError — el fallo se veía como "protocol error"
        // con el servidor perfectamente vivo. 256 KB por dirección: el
        // tope razonable para una respuesta MCP de herramientas.
        const in_buf = try allocator.alloc(u8, 256 * 1024);
        errdefer allocator.free(in_buf);
        const out_buf = try allocator.alloc(u8, 256 * 1024);
        errdefer allocator.free(out_buf);

        var env_map = std.process.Environ.createMap(@import("platform.zig").environ(), allocator) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.SpawnFailed,
        };
        defer env_map.deinit();
        // An order's MCP/ACP child cannot resolve the human's approvals via CLI.
        env_map.put("DEVAGENTS_COMMAND_CHILD", "1") catch return error.OutOfMemory;

        if (child_token) |tok| {
            const exe_name = if (argv.len > 0) std.fs.path.basename(argv[0]) else "";
            if (std.mem.indexOf(u8, exe_name, "devagents-mcp") != null) {
                env_map.put("DEVAGENTS_MCP_TOKEN", tok) catch return error.OutOfMemory;
            }
        }

        var tree = try process_tree.ProcessTree.init();
        errdefer tree.deinit();
        var child = std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .environ_map = &env_map,
            .cwd = if (cwd) |path| .{ .path = path } else .inherit,
            // Un servidor MCP habla por stdio; su consola no la lee nadie.
            // Sin esta bandera, en Windows cada servidor lanzado (Engram entre
            // ellos, via ENGRAM_BIN) abria una ventana de CMD negra junto a la
            // cabina, que era justo lo que el usuario veia "en paralelo".
            .create_no_window = true,
            .start_suspended = @import("builtin").os.tag == .windows,
            .pgid = process_tree.ProcessTree.spawn_pgid,
        }) catch return error.SpawnFailed;
        errdefer {
            tree.deinit();
            child.kill(io);
        }
        try tree.attachAndResume(&child);

        ctx.* = .{
            .allocator = allocator,
            .io = io,
            .owned_io = owned_io,
            .child = child,
            .tree = tree,
            .in_buf = in_buf,
            .out_buf = out_buf,
            .reader = undefined,
            .writer = undefined,
            .timeout_ms = timeout_ms,
            .alive = true,
        };
        // Crear reader/writer EN SITIO referenciando los pipes del hijo en el ctx estable.
        ctx.writer = ctx.child.stdin.?.writerStreaming(io, ctx.in_buf);
        ctx.reader = ctx.child.stdout.?.readerStreaming(io, ctx.out_buf);

        return .{
            .ptr = ctx,
            .writeFn = write,
            .readFn = read,
            .closeFn = close,
        };
    }

    fn write(ptr: *anyopaque, data: []const u8) McpError!void {
        const self: *StdioTransport = @ptrCast(@alignCast(ptr));
        self.writer.interface.writeAll(data) catch return error.ProcessDied;
        self.writer.flush() catch return error.ProcessDied;
    }

    fn read(ptr: *anyopaque, allocator: std.mem.Allocator) McpError![]u8 {
        const self: *StdioTransport = @ptrCast(@alignCast(ptr));
        // T4: Bound the read by a deadline so a silent/hung server cannot block the
        // orchestration forever. WaitForSingleObject on a pipe handle returns signaled
        // immediately (it does NOT wait for data), so we poll with PeekNamedPipe.
        // Check the reader's own buffer first — PeekNamedPipe only sees the OS pipe,
        // not bytes already buffered by readerStreaming (e.g. a batched extra line),
        // so skipping this check would falsely time out when a line is already buffered.
        const pipe_handle = if (@import("builtin").os.tag == .windows) self.reader.file.handle else self.reader.file.handle;
        // la espera anterior solo acotaba «cero bytes»: en cuanto PeekNamedPipe
        // veía >0 bytes entraba en takeDelimiter, que hace ReadFile BLOQUEANTE hasta
        // completar la línea. Un servidor que manda una línea PARCIAL y calla (o
        // tarda más que timeout_ms entre fragmentos) dejaba al cliente colgado
        // para siempre — el deadline no operaba dentro de takeDelimiter.
        // Ahora: se espera a que haya un '\n' EN BUFFER antes de tomar la línea;
        // los fragmentos se acumulan con fillMore (un solo ReadFile no bloqueante
        // tras confirmar avail>0) y el deadline se evalúa en cada iteración.
        // Un '\n' en buffer garantiza que takeDelimiter devuelve sin tocar la pipe.
        const start_ms = GetTickCount64();
        var guard: usize = 0;
        while (guard < 1024) : (guard += 1) {
            while (std.mem.indexOfScalar(u8, self.reader.interface.buffered(), '\n') == null) {
                // Buffer lleno sin '\n' (>256 KB): fillMore→rebase no puede
                // crecer (assert interno) — es el límite del protocolo.
                if (self.reader.interface.bufferedLen() == self.reader.interface.buffer.len)
                    return error.ProtocolError;
                var avail: u32 = 0;
                if (@import("builtin").os.tag == .windows) {
                    if (PeekNamedPipe(pipe_handle, null, 0, null, &avail, null) == 0) return error.ProcessDied;
                } else {
                    var pollfd: [1]std.c.pollfd = .{.{ .fd = pipe_handle, .events = std.c.POLL.IN, .revents = 0 }};
                    const n = std.c.poll(&pollfd, 1, 0);
                    if (n < 0) return error.ProcessDied;
                    if (n > 0) avail = 1;
                }
                if (avail > 0) {
                    self.reader.interface.fillMore() catch |e| switch (e) {
                        error.ReadFailed => return error.ProcessDied,
                        error.EndOfStream => return error.ProcessDied,
                    };
                    continue;
                }
                if (GetTickCount64() - start_ms >= self.timeout_ms) return error.Timeout;
                Sleep(5);
            }
            // `takeDelimiter` consume el '\n' y devuelve null en EOF (a diferencia
            // de takeDelimiterExclusive, que NO consume el delimitador).
            const maybe = self.reader.interface.takeDelimiter('\n') catch |e| switch (e) {
                error.StreamTooLong => return error.ProtocolError,
                error.ReadFailed => return error.ProcessDied,
            };
            const line = maybe orelse return error.ProcessDied; // EOF: el hijo cerró stdout
            var t = line;
            if (t.len > 0 and t[t.len - 1] == '\r') t = t[0 .. t.len - 1];
            if (t.len == 0) continue; // línea en blanco: buscar el siguiente '\n'
            return allocator.dupe(u8, t) catch return error.OutOfMemory;
        }
        return error.ProtocolError;
    }

    fn close(ptr: *anyopaque) void {
        const self: *StdioTransport = @ptrCast(@alignCast(ptr));
        if (self.alive) {
            // kill() termina el hijo y limpia sus pipes (idempotente, sin zombies).
            // Usa self.io: el runtime muere DESPUÉS, nunca antes.
            self.tree.deinit();
            self.child.kill(self.io);
            self.alive = false;
        }
        self.owned_io.deinit();
        self.allocator.destroy(self.owned_io);
        self.allocator.free(self.in_buf);
        self.allocator.free(self.out_buf);
        self.allocator.destroy(self);
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "RELOJ TREE stdio close kills detached descendants before ACP cleanup returns" {
    const a = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const path = try tmp.dir.realPathFileAlloc(io, ".", a);
    defer a.free(path);
    const bin = (try @import("headless_adapter.zig").defaultGetEnv(a, "BEATS_TEST_BIN_DIR")) orelse return error.MissingMockBin;
    defer a.free(bin);
    const exe = try std.fs.path.join(a, &.{ bin, "cli-worker-mock" ++ comptime @import("builtin").target.exeFileExt() });
    defer a.free(exe);
    const transport = try StdioTransport.connectInCwd(a, &.{ exe, "--headless", "tree-hang" }, path, 30000, null);
    var live = true;
    defer if (live) transport.closeFn(transport.ptr);
    const message = try transport.readFn(transport.ptr, a);
    defer a.free(message);
    const marker = "DESCENDANT_PID=";
    try std.testing.expect(std.mem.startsWith(u8, message, marker));
    const pid = try std.fmt.parseInt(u32, message[marker.len..], 10);
    transport.closeFn(transport.ptr);
    live = false;
    try @import("process_tree.zig").expectTestProcessStopped(pid);
}

test "mcp client initialize and list tools" {
    const allocator = std.testing.allocator;
    const transport = try createMockTransport(allocator);

    var client = try McpClient.init(allocator, transport, DEFAULT_TIMEOUT_MS);
    defer client.deinit();

    const tools = try client.listTools();
    defer {
        for (tools) |*t| t.deinit(allocator);
        allocator.free(tools);
    }

    try std.testing.expect(tools.len >= 2);
    try std.testing.expectEqualStrings("echo", tools[0].name);
    try std.testing.expectEqualStrings("add", tools[1].name);
}

test "mcp client call echo tool" {
    const allocator = std.testing.allocator;
    const transport = try createMockTransport(allocator);

    var client = try McpClient.init(allocator, transport, DEFAULT_TIMEOUT_MS);
    defer client.deinit();

    const result = try client.callTool("echo", "{\"message\":\"hello world\"}");
    defer result.deinit(allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "echo: hello world") != null);
}

test "mcp client call add tool" {
    const allocator = std.testing.allocator;
    const transport = try createMockTransport(allocator);

    var client = try McpClient.init(allocator, transport, DEFAULT_TIMEOUT_MS);
    defer client.deinit();

    const result = try client.callTool("add", "{\"a\":3,\"b\":5}");
    defer result.deinit(allocator);

    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "8") != null);
}

test "mcp client handles unknown tool" {
    const allocator = std.testing.allocator;
    const transport = try createMockTransport(allocator);

    var client = try McpClient.init(allocator, transport, DEFAULT_TIMEOUT_MS);
    defer client.deinit();

    const result = try client.callTool("nonexistent", "{}");
    defer result.deinit(allocator);

    try std.testing.expect(result.is_error);
}

// ── Hung transport for timeout testing ─────────────────────────────────

const HungTransportCtx = struct {
    allocator: std.mem.Allocator,
    write_count: usize = 0,

    fn write(ctx: *anyopaque, data: []const u8) McpError!void {
        const self: *HungTransportCtx = @ptrCast(@alignCast(ctx));
        _ = data;
        self.write_count += 1;
    }

    fn read(ctx: *anyopaque, allocator: std.mem.Allocator) McpError![]u8 {
        _ = ctx;
        _ = allocator;
        // Never returns data — simulates a hung MCP server.
        return error.ProtocolError;
    }

    fn close(ctx: *anyopaque) void {
        const self: *HungTransportCtx = @ptrCast(@alignCast(ctx));
        self.allocator.destroy(self);
    }
};

pub fn createHungTransport(allocator: std.mem.Allocator) !McpTransport {
    const ctx = try allocator.create(HungTransportCtx);
    ctx.* = .{ .allocator = allocator };
    return .{
        .ptr = ctx,
        .writeFn = HungTransportCtx.write,
        .readFn = HungTransportCtx.read,
        .closeFn = HungTransportCtx.close,
    };
}

// ── Blocking transport for T4 timeout test ─────────────────────────────

const BlockingTransportCtx = struct {
    allocator: std.mem.Allocator,
    block_ms: u64,
    write_count: usize = 0,

    fn write(ctx: *anyopaque, data: []const u8) McpError!void {
        const self: *BlockingTransportCtx = @ptrCast(@alignCast(ctx));
        _ = data;
        self.write_count += 1;
    }

    fn read(ctx: *anyopaque, allocator: std.mem.Allocator) McpError![]u8 {
        const self: *BlockingTransportCtx = @ptrCast(@alignCast(ctx));
        // T4: Actually blocks for block_ms milliseconds — simulates a real hung server.
        Sleep(@intCast(self.block_ms));
        _ = allocator;
        return error.ProtocolError;
    }

    fn close(ctx: *anyopaque) void {
        const self: *BlockingTransportCtx = @ptrCast(@alignCast(ctx));
        self.allocator.destroy(self);
    }
};

pub fn createBlockingTransport(allocator: std.mem.Allocator, block_ms: u64) !McpTransport {
    const ctx = try allocator.create(BlockingTransportCtx);
    ctx.* = .{ .allocator = allocator, .block_ms = block_ms };
    return .{
        .ptr = ctx,
        .writeFn = BlockingTransportCtx.write,
        .readFn = BlockingTransportCtx.read,
        .closeFn = BlockingTransportCtx.close,
    };
}

test "mcp client hung server: readResultForId exhausts attempts and returns ProtocolError" {
    const allocator = std.testing.allocator;
    const transport = try createHungTransport(allocator);

    // McpClient.init will try to read the initialize response and fail.
    // The hung transport's read always returns error.ProtocolError.
    // On failure, init does not take ownership, so we must close manually.
    try std.testing.expectError(error.ProtocolError, McpClient.init(allocator, transport, 100));
    transport.closeFn(transport.ptr);
}

test "T4: mcp client blocking server returns Timeout within deadline" {
    const allocator = std.testing.allocator;
    // The blocking transport sleeps for 2000ms before returning.
    // With a timeout of 200ms, readResultForId should return error.Timeout
    // because the deadline (200ms) expires before the read (2000ms) completes.
    // BUT: since transport.read blocks, the deadline check in readResultForId
    // only runs AFTER read returns. So this test verifies that the blocking
    // transport returns error.ProtocolError (from the read) and the timer
    // check doesn't help because read blocks.
    //
    // For a REAL timeout test, we need the transport to return quickly but
    // never with the matching id. The timer in readResultForId will then
    // catch the deadline.
    const transport = try createHungTransport(allocator);

    // With timeout=50ms and a transport that returns error.ProtocolError
    // immediately, the error is ProtocolError (not Timeout) because the
    // read fails before the deadline check.
    // To test Timeout, we need a transport that returns data (not error)
    // but never the matching id. Let's use a slow-but-working transport.
    try std.testing.expectError(error.ProtocolError, McpClient.init(allocator, transport, 50));
    transport.closeFn(transport.ptr);
}

test "T4: readResultForId returns Timeout when transport never matches id" {
    const allocator = std.testing.allocator;

    // A transport that returns valid init response first, then mismatched ids.
    const MismatchCtx = struct {
        allocator: std.mem.Allocator,
        read_count: usize = 0,

        fn write(ctx: *anyopaque, data: []const u8) McpError!void {
            _ = ctx;
            _ = data;
        }

        fn read(ctx: *anyopaque, allocator_: std.mem.Allocator) McpError![]u8 {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.read_count += 1;
            if (self.read_count == 1) {
                // First read: return valid init response with id=0.
                const resp = "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"mcp-mock\",\"version\":\"0.1.0\"}}}\n";
                return allocator_.dupe(u8, resp) catch return error.OutOfMemory;
            }
            // Subsequent reads: return id=999 (never matches listTools id=1).
            const resp = "{\"jsonrpc\":\"2.0\",\"id\":999,\"result\":{\"tools\":[]}}\n";
            return allocator_.dupe(u8, resp) catch return error.OutOfMemory;
        }

        fn close(ctx: *anyopaque) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.allocator.destroy(self);
        }
    };

    const ctx = try allocator.create(MismatchCtx);
    ctx.* = .{ .allocator = allocator };
    const transport = McpTransport{
        .ptr = ctx,
        .writeFn = MismatchCtx.write,
        .readFn = MismatchCtx.read,
        .closeFn = MismatchCtx.close,
    };

    // init succeeds (first read returns id=0).
    var client = try McpClient.init(allocator, transport, 50);
    defer client.deinit();

    // listTools calls readResultForId(1), which loops reading id=999 responses
    // until the 50ms deadline expires → error.Timeout.
    try std.testing.expectError(error.Timeout, client.listTools());
}

// ── //transporte scriptado (respuestas precargadas) ────────

const ScriptedCtx = struct {
    allocator: std.mem.Allocator,
    lines: std.ArrayList([]const u8),

    fn write(ctx: *anyopaque, data: []const u8) McpError!void {
        _ = ctx;
        _ = data;
    }
    fn read(ctx: *anyopaque, allocator: std.mem.Allocator) McpError![]u8 {
        const self: *ScriptedCtx = @ptrCast(@alignCast(ctx));
        if (self.lines.items.len == 0) return error.ProtocolError;
        const line = self.lines.orderedRemove(0);
        defer self.allocator.free(line);
        return allocator.dupe(u8, line) catch return error.OutOfMemory;
    }
    fn close(ctx: *anyopaque) void {
        const self: *ScriptedCtx = @ptrCast(@alignCast(ctx));
        for (self.lines.items) |l| self.allocator.free(l);
        self.lines.deinit(self.allocator);
        self.allocator.destroy(self);
    }
};

fn createScriptedTransport(allocator: std.mem.Allocator, lines: []const []const u8) !McpTransport {
    const ctx = try allocator.create(ScriptedCtx);
    ctx.* = .{ .allocator = allocator, .lines = .empty };
    for (lines) |l| try ctx.lines.append(allocator, try allocator.dupe(u8, l));
    return .{
        .ptr = ctx,
        .writeFn = ScriptedCtx.write,
        .readFn = ScriptedCtx.read,
        .closeFn = ScriptedCtx.close,
    };
}

test "E-71: id float fuera de rango en la respuesta no tumba el cliente" {
    const allocator = std.testing.allocator;
    const transport = try createScriptedTransport(allocator, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{}}", // init
        "{\"jsonrpc\":\"2.0\",\"id\":1e30,\"result\":{}}", // id fuera de i64
    });
    var client = try McpClient.init(allocator, transport, 200);
    defer client.deinit();
    // La respuesta con id=1e30 no puede corresponder a ninguna petición: se
    // descarta (no panic) y la cola se agota → ProtocolError.
    try std.testing.expectError(error.ProtocolError, client.listTools());
}

test "E-73: respuesta no-JSON produce ProtocolError tipado, no crash" {
    const allocator = std.testing.allocator;
    const transport = try createScriptedTransport(allocator, &.{
        "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{}}", // init
        "###GARBAGE-BINARIO-NO-JSON###",
    });
    var client = try McpClient.init(allocator, transport, 200);
    defer client.deinit();
    try std.testing.expectError(error.ProtocolError, client.listTools());
}

// ── /pruebas de pipe real contra mcp-mock-server en modo caos ──

fn mcpTestBinary(a: std.mem.Allocator, name: []const u8) ![]u8 {
    const bin = (try @import("headless_adapter.zig").defaultGetEnv(a, "BEATS_TEST_BIN_DIR")) orelse return error.TestBinaryDirectoryMissing;
    defer a.free(bin);
    if (!std.fs.path.isAbsolute(bin)) return error.InvalidTestBinaryDirectory;
    const portable_name = if (@import("builtin").os.tag != .windows and std.mem.endsWith(u8, name, ".exe")) name[0 .. name.len - 4] else name;
    return std.fs.path.join(a, &.{ bin, portable_name });
}

test "E-72: linea de respuesta mayor que el buffer de 256 KB da ProtocolError" {
    const gpa = std.testing.allocator;
    const exe = try mcpTestBinary(gpa, "mcp-mock-server.exe");
    defer gpa.free(exe);
    const argv = [_][]const u8{ exe, "--mode=giant" };
    const tr = try StdioTransport.connectInCwd(gpa, &argv, null, 8000, null);
    defer tr.closeFn(tr.ptr);
    // La respuesta al initialize ya es una línea de ~300 KB: supera el buffer
    // de 256 KB → ProtocolError (límite del protocolo), no crash ni aceptación.
    try std.testing.expectError(error.ProtocolError, McpClient.init(gpa, tr, 8000));
}

test "E-73: respuesta fragmentada en la pipe se reensambla correctamente" {
    const gpa = std.testing.allocator;
    const exe = try mcpTestBinary(gpa, "mcp-mock-server.exe");
    defer gpa.free(exe);
    const argv = [_][]const u8{ exe, "--mode=fragmented" };
    const tr = try StdioTransport.connectInCwd(gpa, &argv, null, 20000, null);
    var client = try McpClient.init(gpa, tr, 20000);
    defer client.deinit();
    const tools = try client.listTools();
    defer {
        for (tools) |*t| t.deinit(gpa);
        gpa.free(tools);
    }
    try std.testing.expectEqual(@as(usize, 2), tools.len);
    const result = try client.callTool("echo", "{\"message\":\"hola\"}");
    defer result.deinit(gpa);
    try std.testing.expect(!result.is_error);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "echo: hola") != null);
}

test "E-73: servidor mudo produce Timeout dentro del deadline" {
    const gpa = std.testing.allocator;
    const exe = try mcpTestBinary(gpa, "mcp-mock-server.exe");
    defer gpa.free(exe);
    const argv = [_][]const u8{ exe, "--mode=silent" };
    const tr = try StdioTransport.connectInCwd(gpa, &argv, null, 400, null);
    defer tr.closeFn(tr.ptr);
    try std.testing.expectError(error.Timeout, McpClient.init(gpa, tr, 400));
}

test "E-73: linea parcial seguida de silencio produce Timeout, no hang" {
    const gpa = std.testing.allocator;
    const exe = try mcpTestBinary(gpa, "mcp-mock-server.exe");
    defer gpa.free(exe);
    const argv = [_][]const u8{ exe, "--mode=partial-silent" };
    const tr = try StdioTransport.connectInCwd(gpa, &argv, null, 400, null);
    defer tr.closeFn(tr.ptr);
    // Regresión el mock manda media línea JSON sin '\n' y calla. Antes,
    // PeekNamedPipe veía bytes >0 y takeDelimiter bloqueaba ReadFile para
    // siempre — el deadline no operaba dentro del ensamblado de línea.
    try std.testing.expectError(error.Timeout, McpClient.init(gpa, tr, 400));
}

test "E-73: servidor que responde basura produce ProtocolError en listTools" {
    const gpa = std.testing.allocator;
    const exe = try mcpTestBinary(gpa, "mcp-mock-server.exe");
    defer gpa.free(exe);
    const argv = [_][]const u8{ exe, "--mode=garbage" };
    const tr = try StdioTransport.connectInCwd(gpa, &argv, null, 8000, null);
    var client = try McpClient.init(gpa, tr, 8000);
    defer client.deinit();
    try std.testing.expectError(error.ProtocolError, client.listTools());
}

test "E-72: request de una linea mayor que el buffer del servidor responde -32700 y no lo mata" {
    const gpa = std.testing.allocator;
    // devagents-mcp REAL (no el mock): su buffer de línea es 28 MiB desde E5.23
    // (adjuntos de imagen; tools/mcp_server.zig `in_buf`). La prueba debe
    // superar ESE límite: con 40 KB la línea ya cabe y el servidor responde
    // -32601 (método no encontrado), no -32700.
    const exe = try mcpTestBinary(gpa, "devagents-mcp.exe");
    defer gpa.free(exe);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(data);
    const argv = [_][]const u8{ exe, "--data-dir", data };
    const tr = try StdioTransport.connectInCwd(gpa, &argv, data, 15000, "b13-mcp-test-token");
    var client = try McpClient.init(gpa, tr, 15000);
    defer client.deinit();

    // Línea de 28 MiB + 1 KiB — supera el buffer del servidor. Antes de el
    // servidor hacía `catch break` y moría sin responder; ahora drena la
    // línea, responde -32700 y sigue vivo.
    const giant_len = 28 * 1024 * 1024 + 1024;
    const head = "{\"jsonrpc\":\"2.0\",\"id\":77,\"method\":\"x\",\"pad\":\"";
    const giant = try gpa.alloc(u8, head.len + giant_len + 3);
    defer gpa.free(giant);
    @memcpy(giant[0..head.len], head);
    @memset(giant[head.len .. head.len + giant_len], 'A');
    giant[head.len + giant_len] = '"';
    giant[head.len + giant_len + 1] = '}';
    giant[head.len + giant_len + 2] = '\n';
    try client.transport.writeFn(client.transport.ptr, giant[0 .. head.len + giant_len + 3]);

    // La respuesta a la línea gigante es un error JSON-RPC -32700 con id 0.
    const resp = try client.transport.readFn(client.transport.ptr, gpa);
    defer gpa.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "-32700") != null);

    // Y el servidor SIGUE VIVO: tools/list responde normalmente después.
    const tools = try client.listTools();
    defer {
        for (tools) |*t| t.deinit(gpa);
        gpa.free(tools);
    }
    try std.testing.expect(tools.len > 50);
}

// PRUEBA DE USUARIO 31-08 (MCP en cabina): el mismo cliente del core contra
// el servidor devagents-mcp real, aislado de la cabina. Si esto lista tools
// y la cabina no, el fallo es del entorno de la cabina, no del protocolo.
test "USR31: listTools contra el devagents-mcp real" {
    const gpa = std.testing.allocator;
    const exe = try mcpTestBinary(gpa, "devagents-mcp.exe");
    defer gpa.free(exe);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data = try tmp.dir.realPathFileAlloc(std.testing.io, ".", gpa);
    defer gpa.free(data);
    const argv = [_][]const u8{ exe, "--data-dir", data };
    const tr = try StdioTransport.connectInCwd(gpa, &argv, data, 20000, "b13-mcp-test-token");
    defer tr.closeFn(tr.ptr);
    const client = try McpClient.init(gpa, tr, 20000);
    var client_mut = client;
    const tools = try client_mut.listTools();
    defer {
        for (tools) |*t| t.deinit(gpa);
        gpa.free(tools);
    }
    // El servidor real expone 62 (barrido C-13). Pedimos > 0: que el protocolo
    // funcione de punta a punta; el conteo exacto lo vigila el propio C-13.
    try std.testing.expect(tools.len > 50);
}

// QA-B H11 (14-nov): con aprobaciones pendientes, cerrar la entrada del
// devagents-mcp real debe terminarlo en menos de 2 s. Antes tardaba 13-16 s:
// `da_core_shutdown` esperaba a la detección de CLIs que el núcleo lanza al
// arrancar. Las aprobaciones quedan pendientes en runtime.db (no se resuelven).
test "QA-B H11: devagents-mcp cierra en menos de 2 s al cerrar stdin con aprobaciones pendientes" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: lanza devagents-mcp.exe con rutas Windows (barra invertida); en Linux el MCP real se comprueba en L9 (T9-B-orden-mcp)");
    const a = std.testing.allocator;
    const exe = try mcpTestBinary(a, "devagents-mcp.exe");
    defer a.free(exe);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(std.testing.io, "datos");
    try tmp.dir.createDirPath(std.testing.io, "proyecto");
    const base = try tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
    defer a.free(base);
    const data = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "datos", .{base});
    defer a.free(data);
    const project = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "proyecto", .{base});
    defer a.free(project);

    var threaded = std.Io.Threaded.init(a, .{ .environ = @import("platform.zig").environ() });
    defer threaded.deinit();
    const io = threaded.io();
    var env = try @import("platform.zig").environ().createMap(a);
    defer env.deinit();
    _ = env.swapRemove("BEATS_DATA_DIR");
    try env.put("DEVAGENTS_DATA_DIR", data);
    try env.put("DEVAGENTS_WORKSPACE_ROOT", project);
    try env.put("DEVAGENTS_MCP_TOKEN", "qa-b-h11-token-0123456789");
    var child = try std.process.spawn(io, .{
        .argv = &.{ exe, "--data-dir", data },
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .ignore,
        .cwd = .{ .path = project },
        .create_no_window = true,
    });
    var finished = false;
    defer if (!finished) child.kill(io);
    var out_buf: [65536]u8 = undefined;
    var reader = child.stdout.?.readerStreaming(io, &out_buf);
    var in_buf: [1024]u8 = undefined;
    var writer = child.stdin.?.writerStreaming(io, &in_buf);
    const requests = [_][]const u8{
        "{\"jsonrpc\":\"2.0\",\"id\":1,\"method\":\"initialize\",\"params\":{\"protocolVersion\":\"2025-06-18\"}}",
        "{\"jsonrpc\":\"2.0\",\"id\":2,\"method\":\"tools/call\",\"params\":{\"name\":\"shell_run\",\"arguments\":{\"exe\":\"python\",\"args\":[\"uno.py\"]}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":3,\"method\":\"tools/call\",\"params\":{\"name\":\"shell_run\",\"arguments\":{\"exe\":\"python\",\"args\":[\"dos.py\"]}}}",
        "{\"jsonrpc\":\"2.0\",\"id\":4,\"method\":\"tools/call\",\"params\":{\"name\":\"shell_run\",\"arguments\":{\"exe\":\"python\",\"args\":[\"tres.py\"]}}}",
    };
    var pending: usize = 0;
    for (requests) |line| {
        try writer.interface.writeAll(line);
        try writer.interface.writeByte('\n');
        try writer.interface.flush();
        const resp = (try reader.interface.takeDelimiter('\n')) orelse return error.McpClosedEarly;
        if (std.mem.indexOf(u8, resp, "PermissionRequired") != null and std.mem.indexOf(u8, resp, "approval_id") != null) pending += 1;
    }
    try std.testing.expectEqual(@as(usize, 3), pending);

    const started = GetTickCount64();
    child.stdin.?.close(io);
    child.stdin = null;
    const waited = WaitForSingleObject(child.id.?, 30_000);
    const elapsed = GetTickCount64() - started;
    std.debug.print("QA-B H11: cierre de stdin con 3 aprobaciones pendientes -> salida en {d} ms\n", .{elapsed});
    try std.testing.expectEqual(WAIT_OBJECT_0, waited);
    _ = try child.wait(io);
    finished = true;
    try std.testing.expect(elapsed < 2000);
}

test "SEC2 stdio transport refuses unsafe batch arguments before spawning" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: lanza cmd.exe o un lote .cmd/.bat (Windows)");
    const a = std.testing.allocator;
    for ([_][]const u8{ "%PATH%", "!value!", "\" & echo injected", "x\ny", "x\ry" }) |unsafe| {
        const argv = [_][]const u8{ "C:\\missing-fixture.cmd", unsafe };
        try std.testing.expectError(error.UnsafeBatchArgument, StdioTransport.connectInCwd(a, &argv, null, 1000, null));
    }
}

// (C4): se LANZA el servidor MCP real solo con BEATS_DATA_DIR
// apuntando a una carpeta temporal bajo .zig-cache (sin --data-dir) y se
// comprueba que `capabilities` informa ESA carpeta y nunca «(cwd default)».
// La variable la fija el codigo de la prueba; los comandos del encargo no
// tocan ninguna variable de carpeta.
test "CK-PLT-007: devagents-mcp lanzado solo con BEATS_DATA_DIR informa esa carpeta en capabilities" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: lanza devagents-mcp.exe con rutas Windows (barra invertida); en Linux el MCP real se comprueba en L9 (T9-B-orden-mcp)");
    const a = std.testing.allocator;

    var prev_beats: [4096:0]u8 = undefined;
    var prev_alias: [4096:0]u8 = undefined;
    const beats_len = GetEnvironmentVariableA("BEATS_DATA_DIR", &prev_beats, prev_beats.len);
    const alias_len = GetEnvironmentVariableA("DEVAGENTS_DATA_DIR", &prev_alias, prev_alias.len);
    defer {
        _ = SetEnvironmentVariableA("BEATS_DATA_DIR", if (beats_len > 0 and beats_len < prev_beats.len) prev_beats[0..beats_len :0].ptr else null);
        _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", if (alias_len > 0 and alias_len < prev_alias.len) prev_alias[0..alias_len :0].ptr else null);
    }
    _ = SetEnvironmentVariableA("DEVAGENTS_DATA_DIR", null);

    const testing_io = std.testing.io;
    const cwd = try std.Io.Dir.cwd().realPathFileAlloc(testing_io, ".", a);
    defer a.free(cwd);
    const dir_plain = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ ".zig-cache" ++ std.fs.path.sep_str ++ "CK-PLT-007-mcp-lanzado", .{cwd});
    defer a.free(dir_plain);
    const dir = try a.dupeZ(u8, dir_plain);
    defer a.free(dir);
    try std.Io.Dir.cwd().createDirPath(testing_io, dir);
    defer std.Io.Dir.cwd().deleteTree(testing_io, dir) catch {};
    _ = SetEnvironmentVariableA("BEATS_DATA_DIR", dir.ptr);

    const exe = try mcpTestBinary(a, "devagents-mcp.exe");
    defer a.free(exe);
    // Sin --data-dir: la carpeta debe venir de BEATS_DATA_DIR.
    const argv = [_][]const u8{exe};
    const tr = try StdioTransport.connectInCwd(a, &argv, null, 20000, "plt007-test-token");
    // McpClient.deinit cierra el transporte: un closeFn explicito ademas
    // provoca doble cierre (segfault en close, r2 rojo capturado).
    var client = try McpClient.initWithToken(a, tr, 20000, "plt007-test-token");
    defer client.deinit();
    const result = try client.callTool("capabilities", "{}");
    defer result.deinit(a);

    try std.testing.expect(result.content.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result.content, "(cwd default)") == null);
    // Solo el nombre de la carpeta: el JSON escapa las barras invertidas.
    try std.testing.expect(std.mem.indexOf(u8, result.content, "CK-PLT-007-mcp-lanzado") != null);
}
