const std = @import("std");
const core = @import("core");

/// GATE F6 (T-F6-05): demuestra recuerdo de hallazgos entre sesiones
/// SIN red, con mock de memoria que persiste en estado estático.
///
/// Sesión 1: guarda hallazgos en la memoria mock.
/// Sesión 2: conexión NUEVA con el mismo estado, llama mem_context
///           y demuestra que los hallazgos de la sesión 1 son recordados.
///
/// Determinista y reproducible sin red.
pub fn main() !void {
    const allocator = std.heap.page_allocator;

    std.debug.print("=== GATE F6: Memoria compartida (recuerdo entre sesiones) ===\n\n", .{});

    var mem_state = MemState{
        .findings = std.ArrayList(MemFinding).empty,
    };
    defer {
        for (mem_state.findings.items) |f| {
            allocator.free(f.content);
            allocator.free(f.type);
        }
        mem_state.findings.deinit(allocator);
    }

    // ── Sesión 1: guardar hallazgos ────────────────────────────────
    std.debug.print("[Sesión 1] Guardando hallazgos en la memoria...\n", .{});
    {
        const transport = try createMockTransport(allocator, &mem_state);
        const client = try core.mcp_client.McpClient.init(allocator, transport, 5000);
        var em = core.engram_memory.EngramMemory.init(allocator, client, try allocator.dupe(u8, "gate-f6"));
        defer em.deinit();
        const bk = em.backend();

        bk.saveFinding("Se encontró un bug de fuga de memoria en src/main.c");
        bk.saveFinding("Se decidió usar RAII para gestionar recursos");
        bk.saveSessionSummary("Sesión 1 completada con 2 hallazgos", "gate-f6");

        std.debug.print("  ✓ 2 hallazgos guardados\n  ✓ Resumen de sesión guardado\n\n", .{});
    }

    // ── Sesión 2: recordar hallazgos ───────────────────────────────
    std.debug.print("[Sesión 2] Nueva conexión, cargando contexto...\n", .{});
    {
        const transport = try createMockTransport(allocator, &mem_state);
        const client = try core.mcp_client.McpClient.init(allocator, transport, 5000);
        var em = core.engram_memory.EngramMemory.init(allocator, client, try allocator.dupe(u8, "gate-f6"));
        defer em.deinit();
        const bk = em.backend();

        const ctx_raw = bk.loadContext(allocator, "gate-f6");
        defer if (ctx_raw) |c| allocator.free(c);

        try expect(ctx_raw != null, "loadContext devolvió contexto (no null)");
        try expect(std.mem.indexOf(u8, ctx_raw.?, "fuga de memoria") != null, "El contexto contiene 'fuga de memoria' de la sesión 1");
        try expect(std.mem.indexOf(u8, ctx_raw.?, "RAII") != null, "El contexto contiene 'RAII' de la sesión 1");

        std.debug.print("  ✓ Contexto recuperado con memoria de sesión 1\n\n", .{});
    }

    // ── MemoryBundle: factory con path=null → LocalMemory persistente (ENGRAM-WIRE-07) ─
    std.debug.print("[MemoryBundle] Factory con path=null usa LocalMemory (runtime.db)...\n", .{});
    {
        var conn = try core.db.Connection.open(allocator, ":memory:");
        defer conn.close();
        var migrator = core.db.Migrator.init(allocator);
        try migrator.migrate(conn, &core.db.runtime_schema);

        var mb = try core.engram_memory.MemoryBundle.init(allocator, null, "test", conn);
        defer mb.deinit();
        const bk = mb.backend();

        bk.saveFinding("hallazgo-f6-local");
        bk.saveSessionSummary("summary", "test");
        const ctx = bk.loadContext(allocator, "test");
        defer if (ctx) |c| allocator.free(c);
        try expect(ctx != null, "LocalMemory.loadContext devuelve contexto (no null) tras guardar");
        try expect(std.mem.indexOf(u8, ctx.?, "hallazgo-f6-local") != null, "El contexto contiene el hallazgo guardado en LocalMemory");
        std.debug.print("  ✓ MemoryBundle con LocalMemory persiste y recupera\n\n", .{});
    }

    std.debug.print("=== GATE F6: Recuerdo entre sesiones verificado ===\n", .{});
}

fn expect(ok: bool, msg: []const u8) !void {
    if (!ok) {
        std.debug.print("  ✖ FALLO: {s}\n", .{msg});
        return error.VerificationFailed;
    }
    std.debug.print("  ✓ {s}\n", .{msg});
}

// ── Estado compartido ─────────────────────────────────────────────

const MemFinding = struct {
    content: []const u8,
    type: []const u8,
};

const MemState = struct {
    findings: std.ArrayList(MemFinding),
};

// ── Transporte mock con estado compartido ─────────────────────────

const MockCtx = struct {
    allocator: std.mem.Allocator,
    state: *MemState,
    stdin_writes: std.ArrayList([]const u8),
    init_done: bool,
};

fn createMockTransport(allocator: std.mem.Allocator, state: *MemState) !core.mcp_client.McpTransport {
    const ctx = try allocator.create(MockCtx);
    ctx.* = .{
        .allocator = allocator,
        .state = state,
        .stdin_writes = std.ArrayList([]const u8).empty,
        .init_done = false,
    };
    return .{
        .ptr = ctx,
        .writeFn = mockWrite,
        .readFn = mockRead,
        .closeFn = mockClose,
    };
}

fn mockWrite(ptr: *anyopaque, data: []const u8) core.mcp_client.McpError!void {
    const ctx: *MockCtx = @ptrCast(@alignCast(ptr));
    // Saltar writes de init/notifications — no generan respuesta que nos interese.
    if (std.mem.indexOf(u8, data, "initialize") != null) return;
    if (std.mem.indexOf(u8, data, "notifications/initialized") != null) return;
    try ctx.stdin_writes.append(ctx.allocator, try ctx.allocator.dupe(u8, data));
}

fn mockRead(ptr: *anyopaque, allocator: std.mem.Allocator) core.mcp_client.McpError![]u8 {
    const ctx: *MockCtx = @ptrCast(@alignCast(ptr));

    if (!ctx.init_done) {
        ctx.init_done = true;
        return allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{\"protocolVersion\":\"2024-11-05\",\"capabilities\":{\"tools\":{}},\"serverInfo\":{\"name\":\"mock-memory\",\"version\":\"0.1.0\"}}}");
    }

    const req = if (ctx.stdin_writes.items.len > 0) blk: {
        const d = ctx.allocator.dupe(u8, ctx.stdin_writes.items[0]) catch "";
        break :blk d;
    } else "";
    defer if (req.len > 0) allocator.free(req);

    for (ctx.stdin_writes.items) |w| ctx.allocator.free(w);
    ctx.stdin_writes.deinit(ctx.allocator);
    ctx.stdin_writes = std.ArrayList([]const u8).empty;

    if (std.mem.indexOf(u8, req, "tools/list") != null) {
        return allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"tools\":[]}}");
    }
    if (std.mem.indexOf(u8, req, "tools/call") != null) {
        const rid = extractId(req) orelse @as(i64, 2);
        if (std.mem.indexOf(u8, req, "mem_save") != null) {
            const content = extractField(req, "content") orelse "unknown";
            const ftype = extractField(req, "type") orelse "discovery";
            try ctx.state.findings.append(ctx.allocator, .{
                .content = try ctx.allocator.dupe(u8, content),
                .type = try ctx.allocator.dupe(u8, ftype),
            });
            return responseOk(allocator, rid, "ok");
        }
        if (std.mem.indexOf(u8, req, "mem_context") != null) {
            const content = buildContextJson(allocator, ctx.state) catch {
                return responseError(allocator, rid, "error building context");
            };
            defer allocator.free(content);
            var esc: std.Io.Writer.Allocating = .init(allocator);
            defer esc.deinit();
            var ejs: std.json.Stringify = .{ .writer = &esc.writer, .options = .{} };
            ejs.write(content) catch return error.ServerError;
            return responseOk(allocator, rid, esc.written());
        }
        return responseOk(allocator, rid, "ok");
    }

    return allocator.dupe(u8, "{\"jsonrpc\":\"2.0\",\"id\":0,\"result\":{}}");
}

fn mockClose(ptr: *anyopaque) void {
    const ctx: *MockCtx = @ptrCast(@alignCast(ptr));
    for (ctx.stdin_writes.items) |w| ctx.allocator.free(w);
    ctx.stdin_writes.deinit(ctx.allocator);
    ctx.allocator.destroy(ctx);
}

/// Construye el JSON de contexto con los hallazgos almacenados (escape correcto).
fn buildContextJson(allocator: std.mem.Allocator, state: *MemState) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try js.beginObject();
    try js.objectField("recalled");
    try js.write(true);
    try js.objectField("total_findings");
    try js.write(@as(i64, @intCast(state.findings.items.len)));
    try js.objectField("items");
    try js.beginArray();
    for (state.findings.items) |f| {
        try js.beginObject();
        try js.objectField("content");
        try js.write(f.content);
        try js.objectField("type");
        try js.write(f.type);
        try js.endObject();
    }
    try js.endArray();
    try js.endObject();
    return allocator.dupe(u8, out.written());
}

/// Construye una respuesta JSON-RPC de éxito con content[0].text.
fn responseOk(allocator: std.mem.Allocator, id: i64, text: []const u8) core.mcp_client.McpError![]u8 {
    var esc: std.Io.Writer.Allocating = .init(allocator);
    defer esc.deinit();
    var ejs: std.json.Stringify = .{ .writer = &esc.writer, .options = .{} };
    ejs.write(text) catch return error.ServerError;
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"result":{{"content":[{{"type":"text","text":{s}}}],"isError":false}}}}
    , .{ id, esc.written() }) catch return error.OutOfMemory;
}

/// Construye una respuesta JSON-RPC de error.
fn responseError(allocator: std.mem.Allocator, id: i64, msg: []const u8) core.mcp_client.McpError![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"result":{{"content":[{{"type":"text","text":"{s}"}}],"isError":true}}}}
    , .{ id, msg }) catch return error.OutOfMemory;
}

/// Extrae el campo `id` (integer) de un JSON request.
fn extractId(raw: []const u8) ?i64 {
    const prefix = "\"id\":";
    const start = std.mem.indexOf(u8, raw, prefix) orelse return null;
    const val_start = start + prefix.len;
    const end = val_start + 1;
    if (val_start >= raw.len) return null;
    return std.fmt.parseInt(i64, raw[val_start..end], 10) catch null;
}

/// Extrae el valor de un campo string JSON escapado.
fn extractField(raw: []const u8, field: []const u8) ?[]const u8 {
    const prefix = std.fmt.allocPrint(std.heap.page_allocator, "\"{s}\":\"", .{field}) catch return null;
    defer std.heap.page_allocator.free(prefix);
    const start = std.mem.indexOf(u8, raw, prefix) orelse return null;
    const val_start = start + prefix.len;
    var end = val_start;
    while (end < raw.len and raw[end] != '"') {
        if (raw[end] == '\\') end += 2 else end += 1;
    }
    if (end >= raw.len) return null;
    return raw[val_start..end];
}
