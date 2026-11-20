const std = @import("std");

const winSleep = struct {
    extern "kernel32" fn Sleep(dwMilliseconds: u32) void;
}.Sleep;
fn Sleep(ms: u32) void {
    if (@import("builtin").os.tag == .windows) return winSleep(ms);
    var duration: std.c.timespec = .{ .sec = @intCast(ms / 1000), .nsec = @intCast((ms % 1000) * 1_000_000) };
    while (std.c.nanosleep(&duration, &duration) != 0) {
        if (std.c._errno().* != @intFromEnum(std.posix.E.INTR)) @panic("fixture nanosleep failed");
    }
}

/// Servidor MCP mock versionado (FR-004 de spec 011): ejecutable independiente, sin red,
/// que habla JSON-RPC 2.0 line-delimited por stdio. Expone 2 herramientas (echo, add).
/// Usado por el verificador de transporte stdio (`zig build mcp-stdio`).
///
/// Protocolo: lee una línea (un mensaje JSON) de stdin, responde una línea por stdout.
/// `notifications/initialized` no produce respuesta. EOF en stdin termina el servidor.
///
/// /`--mode=<m>` activa respuestas adversas para probar mcp_client:
///   giant          → una línea JSON válida de ~300 KB por respuesta (límite 256 KB).
///   fragmented     → la respuesta normal escrita en trozos de 64 bytes con pausa.
///   garbage        → bytes que no son JSON, un '\n' por respuesta.
///   partial-silent → media línea JSON sin '\n' y luego silencio total.
///   silent         → nunca responde (lee y descarta).
const Mode = enum { normal, giant, fragmented, garbage, partial_silent, silent };

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var mode: Mode = .normal;
    var args_iter = try std.process.Args.Iterator.initAllocator(init.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.skip(); // argv[0]
    while (args_iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--mode=")) {
            const m = arg["--mode=".len..];
            inline for (@typeInfo(Mode).@"enum".fields) |f| {
                const tag = @field(Mode, f.name);
                if (std.mem.eql(u8, m, @tagName(tag))) mode = tag;
            }
            // partial-silent tiene guion en argv; el tag lleva '_'
            if (std.mem.eql(u8, m, "partial-silent")) mode = .partial_silent;
        }
    }

    const in = std.Io.File.stdin();
    const out = std.Io.File.stdout();
    var in_buf: [16384]u8 = undefined;
    var out_buf: [16384]u8 = undefined;
    var reader = in.readerStreaming(io, &in_buf);
    var writer = out.writerStreaming(io, &out_buf);

    var next_id: i64 = 0;
    while (true) {
        // `takeDelimiter` consume el '\n' (takeDelimiterExclusive lo dejaría y haría bucle).
        const maybe = reader.interface.takeDelimiter('\n') catch break;
        const line = maybe orelse break; // EOF en stdin: fin del servidor
        var trimmed = line;
        if (trimmed.len > 0 and trimmed[trimmed.len - 1] == '\r') trimmed = trimmed[0 .. trimmed.len - 1];
        if (trimmed.len == 0) continue;

        switch (mode) {
            .silent => continue, // lee y descarta: nunca responde
            .partial_silent => {
                // Media línea JSON sin '\n': el cliente debe agotar su deadline,
                // no quedarse colgado en un ReadFile eterno.
                writer.interface.writeAll("{\"jsonrpc\":\"2.0\",\"id\":1,\"result\":{\"proto") catch return;
                writer.flush() catch return;
                continue;
            },
            .garbage => {
                writer.interface.writeAll("###ESTO-NO-ES-JSON###") catch return;
                writer.interface.writeByte('\n') catch return;
                writer.flush() catch return;
                continue;
            },
            .giant => {
                // Una sola línea >256 KB: el cliente debe dar ProtocolError,
                // no aceptarla ni morir.
                const id = idOfRequest(trimmed);
                try writeGiantLine(allocator, &writer, id);
                continue;
            },
            .fragmented, .normal => {},
        }

        const resp = handle(allocator, trimmed, &next_id) catch {
            const err = "{\"jsonrpc\":\"2.0\",\"id\":0,\"error\":{\"code\":-32603,\"message\":\"internal\"}}";
            writer.interface.writeAll(err) catch return;
            writer.interface.writeByte('\n') catch return;
            writer.flush() catch return;
            continue;
        };
        defer if (resp) |r| allocator.free(r);
        if (resp) |r| {
            if (mode == .fragmented) {
                // la misma respuesta, entregada en trozos de 64 bytes con
                // pausa — el cliente debe reensamblarla igual que si llegara de una vez.
                var off: usize = 0;
                while (off < r.len) {
                    const n = @min(64, r.len - off);
                    writer.interface.writeAll(r[off .. off + n]) catch return;
                    writer.flush() catch return;
                    off += n;
                    Sleep(2);
                }
                writer.interface.writeByte('\n') catch return;
                writer.flush() catch return;
            } else {
                writer.interface.writeAll(r) catch return;
                writer.interface.writeByte('\n') catch return;
                writer.flush() catch return;
            }
        }
    }
}

/// Extrae el `id` de una request JSON sin parsing completo (para correlacionar la respuesta).
fn idOfRequest(raw: []const u8) i64 {
    var parsed = std.json.parseFromSlice(std.json.Value, std.heap.page_allocator, raw, .{}) catch return 0;
    defer parsed.deinit();
    if (parsed.value != .object) return 0;
    const v = parsed.value.object.get("id") orelse return 0;
    return switch (v) {
        .integer => |i| i,
        else => 0,
    };
}

/// Escribe una respuesta JSON válida de ~300 KB en UNA línea: el cliente debe
/// rechazarla por el límite de su buffer de 256 KB.
fn writeGiantLine(allocator: std.mem.Allocator, writer: anytype, id: i64) !void {
    const filler_len = 300 * 1024;
    const filler = try allocator.alloc(u8, filler_len);
    defer allocator.free(filler);
    @memset(filler, 'A');
    const head = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"result":{{"content":[{{"type":"text","text":"
    , .{id});
    defer allocator.free(head);
    try writer.interface.writeAll(head);
    try writer.interface.writeAll(filler);
    try writer.interface.writeAll("\"}],\"isError\":false}}\n");
    try writer.flush();
}

/// Procesa un mensaje JSON-RPC. Devuelve la respuesta (a liberar) o null si no procede.
fn handle(allocator: std.mem.Allocator, raw: []const u8, next_id: *i64) !?[]u8 {
    var parsed = std.json.parseFromSlice(std.json.Value, allocator, raw, .{}) catch {
        return try errorResp(allocator, 0, -32700, "parse error");
    };
    defer parsed.deinit();
    if (parsed.value != .object) return try errorResp(allocator, 0, -32600, "invalid request");
    const obj = parsed.value.object;

    const method = blk: {
        const m = obj.get("method") orelse return try errorResp(allocator, 0, -32600, "missing method");
        if (m != .string) return try errorResp(allocator, 0, -32600, "invalid method");
        break :blk m.string;
    };
    const id = idOf(obj.get("id"));

    if (std.mem.eql(u8, method, "initialize")) {
        const rid = next_id.*;
        next_id.* += 1;
        return try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":{d},"result":{{"protocolVersion":"2024-11-05","capabilities":{{"tools":{{}}}},"serverInfo":{{"name":"mcp-mock-server","version":"0.1.0"}}}}}}
        , .{rid});
    }
    if (std.mem.eql(u8, method, "notifications/initialized")) return null; // sin respuesta
    if (std.mem.eql(u8, method, "tools/list")) {
        return try std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":{d},"result":{{"tools":[{{"name":"echo","description":"Echoes the input message back","inputSchema":{{"type":"object","properties":{{"message":{{"type":"string"}}}},"required":["message"]}}}},{{"name":"add","description":"Adds two integers","inputSchema":{{"type":"object","properties":{{"a":{{"type":"integer"}},"b":{{"type":"integer"}}}},"required":["a","b"]}}}}]}}}}
        , .{id});
    }
    if (std.mem.eql(u8, method, "tools/call")) {
        const params = obj.get("params") orelse return try errorResp(allocator, id, -32602, "missing params");
        if (params != .object) return try errorResp(allocator, id, -32602, "invalid params");
        const name_v = params.object.get("name") orelse return try errorResp(allocator, id, -32602, "missing name");
        if (name_v != .string) return try errorResp(allocator, id, -32602, "invalid name");
        const args = params.object.get("arguments") orelse std.json.Value{ .null = {} };

        if (std.mem.eql(u8, name_v.string, "echo")) {
            const msg = if (args == .object) (args.object.get("message") orelse std.json.Value{ .null = {} }) else std.json.Value{ .null = {} };
            if (msg != .string) return try errorResp(allocator, id, -32602, "missing message");
            // Re-serializa el texto con escape correcto.
            var out: std.Io.Writer.Allocating = .init(allocator);
            defer out.deinit();
            var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
            const echoed = try std.fmt.allocPrint(allocator, "echo: {s}", .{msg.string});
            defer allocator.free(echoed);
            try js.write(echoed);
            return try std.fmt.allocPrint(allocator,
                \\{{"jsonrpc":"2.0","id":{d},"result":{{"content":[{{"type":"text","text":{s}}}],"isError":false}}}}
            , .{ id, out.written() });
        }
        if (std.mem.eql(u8, name_v.string, "add")) {
            const a = if (args == .object) intOf(args.object.get("a")) else null;
            const b = if (args == .object) intOf(args.object.get("b")) else null;
            if (a == null or b == null) return try errorResp(allocator, id, -32602, "missing a or b");
            // `+%` wrapping: operandos i64 extremos no pueden tumbar el mock.
            return try std.fmt.allocPrint(allocator,
                \\{{"jsonrpc":"2.0","id":{d},"result":{{"content":[{{"type":"text","text":"{d}"}}],"isError":false}}}}
            , .{ id, a.? +% b.? });
        }
        return try errorResp(allocator, id, -32601, "unknown tool");
    }
    return try errorResp(allocator, id, -32601, "method not found");
}

// (lado mock): un float fuera de i64 hacía panic en el cast — el helper
// de tests tampoco debe morir ante input fuzzed.
const F64_I64_BOUND: f64 = 9223372036854775808.0; // 2^63

fn floatFitsI64(f: f64) bool {
    return f >= -F64_I64_BOUND and f < F64_I64_BOUND;
}

fn idOf(v: ?std.json.Value) i64 {
    const val = v orelse return 0;
    return switch (val) {
        .integer => |i| i,
        .float => |f| if (floatFitsI64(f)) @intFromFloat(f) else 0,
        else => 0,
    };
}

fn intOf(v: ?std.json.Value) ?i64 {
    const val = v orelse return null;
    return switch (val) {
        .integer => |i| i,
        .float => |f| if (floatFitsI64(f)) @intFromFloat(f) else null,
        else => null,
    };
}

fn errorResp(allocator: std.mem.Allocator, id: i64, code: i64, message: []const u8) !?[]u8 {
    return try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"error":{{"code":{d},"message":"{s}"}}}}
    , .{ id, code, message });
}
