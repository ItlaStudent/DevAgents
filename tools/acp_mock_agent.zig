const std = @import("std");

const windows = std.os.windows;
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

const winTicks = struct {
    extern "kernel32" fn GetTickCount64() u64;
}.GetTickCount64;
fn GetTickCount64() u64 {
    if (@import("builtin").os.tag == .windows) return winTicks();
    var t: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &t) != 0) @panic("fixture clock failed");
    return @as(u64, @intCast(t.sec)) * 1000 + @as(u64, @intCast(t.nsec)) / 1_000_000;
}
extern "kernel32" fn PeekNamedPipe(hNamedPipe: windows.HANDLE, lpBuffer: ?*anyopaque, nBufferSize: u32, lpBytesRead: ?*u32, lpTotalBytesAvail: ?*u32, lpBytesLeftThisMessage: ?*u32) c_int;

/// Agente ACP mock versionado (E5.06): ejecutable independiente que habla
/// Agent Client Protocol v1 (JSON-RPC 2.0 line-delimited) por stdio.
/// Determinista, sin red ni credenciales — los tests del cliente ACP lo
/// lanzan como proceso real (`zig-out/bin/acp-mock-agent.exe`).
///
/// Ciclo de protocolo: initialize → session/new → session/prompt → turno
/// según `--scenario=<s>` → respuesta con stopReason → más prompts (loop).
/// EOF en stdin termina el agente.
///
/// Escenarios:
///   normal       → turno completo: agent_thought_chunk, tool_call,
///                  fs/write_text_file (petición AL CLIENTE, espera su
///                  respuesta), tool_call_update, plan, agent_message_chunk,
///                  stopReason=end_turn. Escribe `saludo.txt` en el cwd de
///                  la sesión vía la capability fs del cliente.
///   perm-inside  → session/request_permission por una escritura DENTRO del
///                  cwd; con outcome selected+allow-once pide fs/write_text_file.
///   perm-outside → igual pero con ruta FUERA del cwd: el cliente confinado
///                  debe devolver error fs y el tool_call queda failed.
///   malformed    → responde al prompt con una línea que no es JSON.
///   hang         → nunca responde al prompt: el deadline del cliente manda.
///   cancel       → chunk + espera activa de session/cancel: al recibirla
///                  responde al prompt con stopReason=cancelled.
const Scenario = enum { normal, perm_inside, perm_outside, malformed, hang, cancel };

const SESSION_ID = "acp-mock-sess-1";

pub fn main(init: std.process.Init.Minimal) !void {
    const allocator = std.heap.page_allocator;
    var threaded = std.Io.Threaded.init(allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var scenario: Scenario = .normal;
    var args_iter = try std.process.Args.Iterator.initAllocator(init.args, allocator);
    defer args_iter.deinit();
    _ = args_iter.skip(); // argv[0]
    while (args_iter.next()) |arg| {
        if (std.mem.startsWith(u8, arg, "--scenario=")) {
            const s = arg["--scenario=".len..];
            inline for (@typeInfo(Scenario).@"enum".fields) |f| {
                const tag = @field(Scenario, f.name);
                if (std.mem.eql(u8, s, @tagName(tag))) scenario = tag;
            }
            if (std.mem.eql(u8, s, "perm-inside")) scenario = .perm_inside;
            if (std.mem.eql(u8, s, "perm-outside")) scenario = .perm_outside;
        }
    }

    const in = std.Io.File.stdin();
    const out = std.Io.File.stdout();
    var in_buf: [65536]u8 = undefined;
    var out_buf: [65536]u8 = undefined;
    var reader = in.readerStreaming(io, &in_buf);
    var writer = out.writerStreaming(io, &out_buf);

    var agent_next_id: i64 = 1000; // ids agente→cliente en rango distinto
    var cwd: ?[]u8 = null;
    defer if (cwd) |c| allocator.free(c);

    while (true) {
        const maybe = reader.interface.takeDelimiter('\n') catch break;
        const line = maybe orelse break; // EOF: el cliente cerró stdin
        var t = line;
        if (t.len > 0 and t[t.len - 1] == '\r') t = t[0 .. t.len - 1];
        if (t.len == 0) continue;

        var parsed = std.json.parseFromSlice(std.json.Value, allocator, t, .{}) catch {
            sendLine(&writer, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32700,\"message\":\"parse error\"}}");
            continue;
        };
        defer parsed.deinit();
        if (parsed.value != .object) {
            sendLine(&writer, "{\"jsonrpc\":\"2.0\",\"id\":null,\"error\":{\"code\":-32600,\"message\":\"invalid request\"}}");
            continue;
        }
        const obj = parsed.value.object;
        const method = blk: {
            const m = obj.get("method") orelse break :blk null;
            if (m != .string) break :blk null;
            break :blk m.string;
        };
        const id_v = obj.get("id");

        if (method == null) continue; // respuesta suelta del cliente: descartar
        const m = method.?;

        if (std.mem.eql(u8, m, "initialize")) {
            const id = idNum(id_v);
            const resp = try std.fmt.allocPrint(allocator,
                \\{{"jsonrpc":"2.0","id":{d},"result":{{"protocolVersion":1,"agentCapabilities":{{"loadSession":false,"promptCapabilities":{{"image":false,"audio":false,"embeddedContext":false}}}},"agentInfo":{{"name":"acp-mock-agent","title":"ACP Mock Agent","version":"0.1.0"}},"authMethods":[]}}}}
            , .{id});
            defer allocator.free(resp);
            sendLine(&writer, resp);
            continue;
        }
        if (std.mem.eql(u8, m, "session/new")) {
            if (obj.get("params")) |p| {
                if (p == .object) {
                    if (p.object.get("cwd")) |cv| {
                        if (cv == .string) {
                            if (cwd) |old| allocator.free(old);
                            cwd = try allocator.dupe(u8, cv.string);
                        }
                    }
                }
            }
            const id = idNum(id_v);
            const resp = try std.fmt.allocPrint(allocator,
                \\{{"jsonrpc":"2.0","id":{d},"result":{{"sessionId":"{s}"}}}}
            , .{ id, SESSION_ID });
            defer allocator.free(resp);
            sendLine(&writer, resp);
            continue;
        }
        if (std.mem.eql(u8, m, "session/prompt")) {
            const prompt_id = idNum(id_v);
            runTurn(allocator, &reader, &writer, scenario, prompt_id, cwd, &agent_next_id);
            continue;
        }
        if (std.mem.eql(u8, m, "session/cancel")) continue; // notificación fuera de turno
        // Método desconocido con id → -32601.
        if (id_v) |iv| {
            const id = idNum(iv);
            const resp = try std.fmt.allocPrint(allocator,
                \\{{"jsonrpc":"2.0","id":{d},"error":{{"code":-32601,"message":"method not found"}}}}
            , .{id});
            defer allocator.free(resp);
            sendLine(&writer, resp);
        }
    }
}

fn idNum(v: ?std.json.Value) i64 {
    const val = v orelse return 0;
    return switch (val) {
        .integer => |i| i,
        .float => |f| if (f >= -9223372036854775808.0 and f < 9223372036854775808.0) @intFromFloat(f) else 0,
        else => 0,
    };
}

fn sendLine(writer: anytype, line: []const u8) void {
    writer.interface.writeAll(line) catch return;
    writer.interface.writeByte('\n') catch return;
    writer.flush() catch return;
}

/// Lee una línea de stdin con deadline. `null` si vence el plazo o EOF.
/// El buffer del reader se consulta antes que PeekNamedPipe (bytes ya
/// bufferizados no son visibles para la API).
fn pollLine(reader: anytype, deadline_ms: u64) ?[]const u8 {
    const start = GetTickCount64();
    while (GetTickCount64() - start < deadline_ms) {
        if (std.mem.indexOfScalar(u8, reader.interface.buffered(), '\n') != null) {
            const maybe = reader.interface.takeDelimiter('\n') catch return null;
            return maybe;
        }
        var avail: u32 = 0;
        if (@import("builtin").os.tag == .windows) {
            if (PeekNamedPipe(reader.file.handle, null, 0, null, &avail, null) == 0) return null;
        } else {
            var fds = [_]std.c.pollfd{.{ .fd = reader.file.handle, .events = std.c.POLL.IN, .revents = 0 }};
            const n = std.c.poll(&fds, 1, 0);
            if (n < 0) return null;
            if (n > 0) avail = 1;
        }
        if (avail > 0) {
            reader.interface.fillMore() catch return null;
            continue;
        }
        Sleep(2);
    }
    return null;
}

const WaitResult = union(enum) {
    response: std.json.Parsed(std.json.Value),
    cancelled,
    timeout,
};

/// Espera la respuesta del cliente a una petición del agente (`want_id`).
/// `.cancelled` si llegó session/cancel (el turno se aborta); `.timeout` si
/// vence el plazo. Otras líneas se descartan.
fn waitClientResponse(allocator: std.mem.Allocator, reader: anytype, want_id: i64, deadline_ms: u64) WaitResult {
    const start = GetTickCount64();
    while (GetTickCount64() - start < deadline_ms) {
        const remaining = deadline_ms - (GetTickCount64() - start);
        const line = pollLine(reader, remaining) orelse return .timeout;
        var t = line;
        if (t.len > 0 and t[t.len - 1] == '\r') t = t[0 .. t.len - 1];
        if (t.len == 0) continue;
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, t, .{}) catch continue;
        if (parsed.value != .object) {
            parsed.deinit();
            continue;
        }
        const obj = parsed.value.object;
        if (obj.get("method")) |m| {
            if (m == .string and std.mem.eql(u8, m.string, "session/cancel")) {
                parsed.deinit();
                return .cancelled;
            }
            parsed.deinit();
            continue; // notificación ajena
        }
        if (obj.get("id")) |iv| {
            if (idNum(iv) == want_id) return .{ .response = parsed };
        }
        parsed.deinit();
    }
    return .timeout;
}

fn promptResp(allocator: std.mem.Allocator, prompt_id: i64, stop: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"result":{{"stopReason":"{s}"}}}}
    , .{ prompt_id, stop });
}

fn updateNotif(allocator: std.mem.Allocator, update_json: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","method":"session/update","params":{{"sessionId":"{s}","update":{s}}}}}
    , .{ SESSION_ID, update_json });
}

fn finishPrompt(allocator: std.mem.Allocator, writer: anytype, prompt_id: i64, stop: []const u8) void {
    const resp = promptResp(allocator, prompt_id, stop) catch return;
    defer allocator.free(resp);
    sendLine(writer, resp);
}

fn runTurn(
    allocator: std.mem.Allocator,
    reader: anytype,
    writer: anytype,
    scenario: Scenario,
    prompt_id: i64,
    cwd: ?[]const u8,
    agent_next_id: *i64,
) void {
    switch (scenario) {
        .malformed => {
            sendLine(writer, "###ACP-NO-ES-JSON###");
            finishPrompt(allocator, writer, prompt_id, "end_turn");
        },
        .hang => {
            // Mudo para siempre: el deadline del cliente y su kill deciden.
            while (true) Sleep(60000);
        },
        .cancel => {
            if (updateNotif(allocator, "{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"trabajando\"}}") catch null) |u| {
                defer allocator.free(u);
                sendLine(writer, u);
            }
            var cancelled = false;
            if (pollLine(reader, 8000)) |l| {
                var t = l;
                if (t.len > 0 and t[t.len - 1] == '\r') t = t[0 .. t.len - 1];
                var parsed = std.json.parseFromSlice(std.json.Value, allocator, t, .{}) catch {
                    finishPrompt(allocator, writer, prompt_id, "end_turn");
                    return;
                };
                defer parsed.deinit();
                if (parsed.value == .object) {
                    if (parsed.value.object.get("method")) |mv| {
                        if (mv == .string and std.mem.eql(u8, mv.string, "session/cancel")) cancelled = true;
                    }
                }
            }
            finishPrompt(allocator, writer, prompt_id, if (cancelled) "cancelled" else "end_turn");
        },
        .normal => {
            const dir = cwd orelse "C:\\Windows\\Temp";
            const target = std.fmt.allocPrint(allocator, "{s}{c}saludo.txt", .{ dir, std.fs.path.sep }) catch return;
            defer allocator.free(target);
            turnWithWrite(allocator, reader, writer, prompt_id, target, false, agent_next_id);
        },
        .perm_inside => {
            const dir = cwd orelse "C:\\Windows\\Temp";
            const target = std.fmt.allocPrint(allocator, "{s}{c}dentro.txt", .{ dir, std.fs.path.sep }) catch return;
            defer allocator.free(target);
            turnWithWrite(allocator, reader, writer, prompt_id, target, true, agent_next_id);
        },
        .perm_outside => {
            const dir = cwd orelse "C:\\Windows\\Temp";
            const parent = std.fs.path.dirname(dir) orelse "C:\\";
            const target = std.fmt.allocPrint(allocator, "{s}{c}fuera_acp.txt", .{ parent, std.fs.path.sep }) catch return;
            defer allocator.free(target);
            turnWithWrite(allocator, reader, writer, prompt_id, target, true, agent_next_id);
        },
    }
}

/// Turno que escribe `target` vía fs/write_text_file del cliente.
/// Si `ask_permission`, antes pide session/request_permission.
fn turnWithWrite(
    allocator: std.mem.Allocator,
    reader: anytype,
    writer: anytype,
    prompt_id: i64,
    target: []const u8,
    ask_permission: bool,
    agent_next_id: *i64,
) void {
    const tool_id = "call-write-1";
    const path_json = jsonEscapePath(allocator, target) catch return;
    defer allocator.free(path_json);

    // 1. agent_thought_chunk
    if (updateNotif(allocator, "{\"sessionUpdate\":\"agent_thought_chunk\",\"content\":{\"type\":\"text\",\"text\":\"decidiendo el archivo\"}}") catch null) |u| {
        defer allocator.free(u);
        sendLine(writer, u);
    }

    // 2. tool_call in_progress (con la ruta en locations para la bandeja)
    const tc_upd = std.fmt.allocPrint(allocator,
        \\{{"sessionUpdate":"tool_call","toolCallId":"{s}","title":"Escribir archivo","kind":"edit","status":"in_progress","locations":[{{"path":"{s}"}}]}}
    , .{ tool_id, path_json }) catch return;
    defer allocator.free(tc_upd);
    if (updateNotif(allocator, tc_upd) catch null) |u| {
        defer allocator.free(u);
        sendLine(writer, u);
    }

    // 3. Permiso (si el escenario lo pide).
    var granted = !ask_permission;
    if (ask_permission) {
        const perm_id = agent_next_id.*;
        agent_next_id.* += 1;
        const perm = std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":{d},"method":"session/request_permission","params":{{"sessionId":"{s}","toolCall":{{"toolCallId":"{s}","title":"Escribir archivo","kind":"edit","locations":[{{"path":"{s}"}}]}},"options":[{{"optionId":"allow-once","name":"Permitir una vez","kind":"allow_once"}},{{"optionId":"reject-once","name":"Rechazar","kind":"reject_once"}}]}}}}
        , .{ perm_id, SESSION_ID, tool_id, path_json }) catch return;
        defer allocator.free(perm);
        sendLine(writer, perm);
        switch (waitClientResponse(allocator, reader, perm_id, 8000)) {
            .cancelled => {
                toolCallUpdate(allocator, writer, tool_id, "cancelled");
                return finishPrompt(allocator, writer, prompt_id, "cancelled");
            },
            .timeout => {
                toolCallUpdate(allocator, writer, tool_id, "failed");
                return finishPrompt(allocator, writer, prompt_id, "end_turn");
            },
            .response => |*resp| {
                defer resp.deinit();
                if (resp.value == .object) {
                    if (resp.value.object.get("result")) |r| {
                        if (r == .object) {
                            if (r.object.get("outcome")) |o| {
                                if (o == .object) {
                                    const oc = o.object.get("outcome");
                                    const oid = o.object.get("optionId");
                                    if (oc != null and oc.? == .string and
                                        std.mem.eql(u8, oc.?.string, "selected") and
                                        oid != null and oid.? == .string and
                                        std.mem.eql(u8, oid.?.string, "allow-once"))
                                    {
                                        granted = true;
                                    }
                                }
                            }
                        }
                    }
                }
            },
        }
    }

    // 4. Escritura vía fs del cliente (solo si hay permiso o no se pedía).
    if (granted) {
        const fs_id = agent_next_id.*;
        agent_next_id.* += 1;
        const req = std.fmt.allocPrint(allocator,
            \\{{"jsonrpc":"2.0","id":{d},"method":"fs/write_text_file","params":{{"sessionId":"{s}","path":"{s}","content":"HOLA ACP\n"}}}}
        , .{ fs_id, SESSION_ID, path_json }) catch return;
        defer allocator.free(req);
        sendLine(writer, req);
        switch (waitClientResponse(allocator, reader, fs_id, 8000)) {
            .cancelled => {
                toolCallUpdate(allocator, writer, tool_id, "cancelled");
                return finishPrompt(allocator, writer, prompt_id, "cancelled");
            },
            .timeout => toolCallUpdate(allocator, writer, tool_id, "failed"),
            .response => |*resp| {
                defer resp.deinit();
                const ok = resp.value == .object and resp.value.object.get("result") != null;
                toolCallUpdate(allocator, writer, tool_id, if (ok) "completed" else "failed");
            },
        }
    } else {
        toolCallUpdate(allocator, writer, tool_id, "failed");
    }

    // 5. plan + mensaje final.
    if (updateNotif(allocator, "{\"sessionUpdate\":\"plan\",\"entries\":[{\"content\":\"Escribir archivo\",\"priority\":\"high\",\"status\":\"completed\"}]}") catch null) |u| {
        defer allocator.free(u);
        sendLine(writer, u);
    }
    if (updateNotif(allocator, "{\"sessionUpdate\":\"agent_message_chunk\",\"content\":{\"type\":\"text\",\"text\":\"listo\"}}") catch null) |u| {
        defer allocator.free(u);
        sendLine(writer, u);
    }
    finishPrompt(allocator, writer, prompt_id, "end_turn");
}

fn toolCallUpdate(allocator: std.mem.Allocator, writer: anytype, tool_id: []const u8, status: []const u8) void {
    const upd = std.fmt.allocPrint(allocator,
        \\{{"sessionUpdate":"tool_call_update","toolCallId":"{s}","status":"{s}"}}
    , .{ tool_id, status }) catch return;
    defer allocator.free(upd);
    if (updateNotif(allocator, upd) catch null) |u| {
        defer allocator.free(u);
        sendLine(writer, u);
    }
}

/// '\\' → '\\\\' para incrustar una ruta Windows en un literal JSON.
fn jsonEscapePath(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    errdefer out.deinit();
    for (path) |c| {
        if (c == '\\') try out.writer.writeAll("\\\\") else try out.writer.writeByte(c);
    }
    return allocator.dupe(u8, out.written());
}
