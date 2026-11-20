const std = @import("std");
const mcp_client = @import("mcp_client.zig");
const sync = @import("sync.zig");

pub const OdMcpError = error{
    NotConnected,
    AlreadyConnected,
    SpawnFailed,
    ProtocolError,
    OutOfMemory,
};

/// Estado de la conexión MCP a open-design-bridge.
/// Thread-safe: todas las mutaciones protegidas por mutex.
pub const OdMcpState = struct {
    allocator: std.mem.Allocator,
    mutex: sync.Mutex,
    connected: bool,
    client: ?mcp_client.McpClient,
    transport: ?mcp_client.McpTransport,
    // Configuración persistente (copias propias).
    argv: []const []const u8,
    cwd: ?[]const u8,

    pub fn init(allocator: std.mem.Allocator) OdMcpState {
        return .{
            .allocator = allocator,
            .mutex = sync.Mutex.init(),
            .connected = false,
            .client = null,
            .transport = null,
            .argv = &.{},
            .cwd = null,
        };
    }

    pub fn deinit(self: *OdMcpState) void {
        self.disconnect();
        self.freeArgv();
        if (self.cwd) |c| self.allocator.free(c);
        self.cwd = null;
    }

    fn freeArgv(self: *OdMcpState) void {
        for (self.argv) |a| self.allocator.free(a);
        self.allocator.free(self.argv);
        self.argv = &.{};
    }

    /// Conecta al servidor MCP de od-bridge.
    /// `argv`: comando y args (ej. {"python","-m","od_bridge.mcp_server"}).
    /// `cwd`: directorio de trabajo opcional (null = cwd del proceso).
    /// `timeout_ms`: timeout por request en milisegundos (0 = usar DEFAULT_TIMEOUT_MS).
    /// `auth_token`: MCP-AUTH — token a presentar en `initialize` para servidores
    /// con frontera de autenticación (el propio devagents-mcp la exige para las
    /// tools privilegiadas). null = sin token (solo tools abiertas).
    /// el transporte posee su propio runtime io (StdioTransport.owned_io)
    /// — la conexión vive más que esta llamada, así que un io prestado del
    /// caller quedaba colgado al destruirse (wedge de todo el bridge).
    pub fn connect(self: *OdMcpState, argv: []const []const u8, cwd: ?[]const u8, timeout_ms: u64, auth_token: ?[]const u8) OdMcpError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.connected) return error.AlreadyConnected;

        self.freeArgv();
        var argv_copy = std.ArrayList([]const u8).empty;
        errdefer {
            for (argv_copy.items) |a| self.allocator.free(a);
            argv_copy.deinit(self.allocator);
        }
        for (argv) |a| {
            try argv_copy.append(self.allocator, try self.allocator.dupe(u8, a));
        }
        self.argv = try argv_copy.toOwnedSlice(self.allocator);

        if (self.cwd) |c| self.allocator.free(c);
        self.cwd = if (cwd) |c| try self.allocator.dupe(u8, c) else null;

        const effective_timeout = if (timeout_ms == 0) mcp_client.DEFAULT_TIMEOUT_MS else timeout_ms;
        const transport = mcp_client.StdioTransport.connectInCwd(self.allocator, self.argv, self.cwd, effective_timeout, auth_token) catch return error.SpawnFailed;
        const client = mcp_client.McpClient.initWithToken(self.allocator, transport, effective_timeout, auth_token) catch {
            transport.closeFn(transport.ptr);
            return error.ProtocolError;
        };

        self.transport = transport;
        self.client = client;
        self.connected = true;
    }

    pub fn disconnect(self: *OdMcpState) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.connected) return;
        if (self.client) |*c| c.deinit();
        self.client = null;
        self.transport = null;
        self.connected = false;
    }

    /// Devuelve un slice JSON con las tools del servidor MCP.
    /// El llamador libera el slice con `allocator.free`.
    pub fn listToolsJson(self: *OdMcpState, allocator: std.mem.Allocator) OdMcpError![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.connected or self.client == null) return error.NotConnected;

        const tools = self.client.?.listTools() catch return error.ProtocolError;
        defer {
            for (tools) |*t| t.deinit(allocator);
            allocator.free(tools);
        }

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        js.beginArray() catch return error.OutOfMemory;
        for (tools) |t| {
            js.beginObject() catch return error.OutOfMemory;
            js.objectField("name") catch return error.OutOfMemory;
            js.write(t.name) catch return error.OutOfMemory;
            js.objectField("description") catch return error.OutOfMemory;
            js.write(t.description) catch return error.OutOfMemory;
            js.objectField("input_schema") catch return error.OutOfMemory;
            // t.input_schema_json ya es JSON string; lo re-serializamos como string cruda
            // para mantener la estructura sin doble-escape.
            js.write(t.input_schema_json) catch return error.OutOfMemory;
            js.endObject() catch return error.OutOfMemory;
        }
        js.endArray() catch return error.OutOfMemory;
        return allocator.dupe(u8, out.written()) catch return error.OutOfMemory;
    }

    /// Llama una tool del servidor MCP.
    /// `name`: nombre de la tool.
    /// `args_json`: objeto JSON con los argumentos (ej. {"project_id":"x"}).
    /// Devuelve el resultado como string JSON {"content":"...","is_error":bool}.
    /// El llamador libera el slice.
    pub fn callToolJson(self: *OdMcpState, allocator: std.mem.Allocator, name: []const u8, args_json: []const u8) OdMcpError![]const u8 {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (!self.connected or self.client == null) return error.NotConnected;

        const result = self.client.?.callTool(name, args_json) catch return error.ProtocolError;
        defer result.deinit(allocator);

        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        js.beginObject() catch return error.OutOfMemory;
        js.objectField("content") catch return error.OutOfMemory;
        js.write(result.content) catch return error.OutOfMemory;
        js.objectField("is_error") catch return error.OutOfMemory;
        js.write(result.is_error) catch return error.OutOfMemory;
        js.endObject() catch return error.OutOfMemory;
        return allocator.dupe(u8, out.written()) catch return error.OutOfMemory;
    }

    /// Para tests deterministas: conecta con un transporte mock ya creado.
    pub fn connectMock(self: *OdMcpState, transport: mcp_client.McpTransport) OdMcpError!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.connected) return error.AlreadyConnected;
        const client = mcp_client.McpClient.init(self.allocator, transport, mcp_client.DEFAULT_TIMEOUT_MS) catch {
            transport.closeFn(transport.ptr);
            return error.ProtocolError;
        };
        self.transport = transport;
        self.client = client;
        self.connected = true;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "od_mcp: not connected yields error" {
    const allocator = std.testing.allocator;
    var state = OdMcpState.init(allocator);
    defer state.deinit();

    const r = state.listToolsJson(allocator);
    try std.testing.expectError(error.NotConnected, r);
}

test "od_mcp: mock connect lists tools" {
    const allocator = std.testing.allocator;
    const transport = try mcp_client.createMockTransport(allocator);
    var state = OdMcpState.init(allocator);
    defer state.deinit();

    try state.connectMock(transport);

    const json = try state.listToolsJson(allocator);
    defer allocator.free(json);

    try std.testing.expect(std.mem.indexOf(u8, json, "echo") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "add") != null);
}

test "od_mcp: mock callTool returns result" {
    const allocator = std.testing.allocator;
    const transport = try mcp_client.createMockTransport(allocator);
    var state = OdMcpState.init(allocator);
    defer state.deinit();

    try state.connectMock(transport);

    const result = try state.callToolJson(allocator, "echo", "{\"message\":\"hello\"}");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "hello") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"is_error\":false") != null);
}

test "od_mcp: disconnect clears state" {
    const allocator = std.testing.allocator;
    const transport = try mcp_client.createMockTransport(allocator);
    var state = OdMcpState.init(allocator);
    defer state.deinit();

    try state.connectMock(transport);
    state.disconnect();

    try std.testing.expectError(error.NotConnected, state.listToolsJson(allocator));
}

test "od_mcp: stores cwd for bridge launch" {
    const allocator = std.testing.allocator;
    var state = OdMcpState.init(allocator);
    defer state.deinit();

    const transport = try mcp_client.createMockTransport(allocator);
    state.cwd = try allocator.dupe(u8, "C:\\bridge");
    try state.connectMock(transport);

    try std.testing.expect(state.cwd != null);
    try std.testing.expectEqualStrings("C:\\bridge", state.cwd.?);
}
