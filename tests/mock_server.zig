const std = @import("std");
const Io = std.Io;

extern "kernel32" fn Sleep(dwMilliseconds: u32) void;

/// Servidor HTTP mock mínimo para tests.
pub const MockServer = struct {
    allocator: std.mem.Allocator,
    threaded: *Io.Threaded,
    server: Io.net.Server,
    port: u16,
    thread: ?std.Thread,
    should_stop: bool,
    response_body: []const u8,
    content_type: []const u8,
    /// Línea de estado HTTP (sin el prefijo "HTTP/1.1 "). Default "200 OK" para
    /// no romper a ningún llamador existente; los tests de clasificación de
    /// errores HTTP la sobreescriben (p. ej. "429 Too Many Requests") DESPUÉS
    /// de `init` y ANTES de `start`.
    status_line: []const u8 = "200 OK",
    /// E3.22/E3.23: comportamiento por conexión. `.respond` = respuesta normal;
    /// `.drop` = acepta y CIERRA sin responder (corte de red a mitad de llamada);
    /// `.partial` = envía la mitad de la respuesta y corta (respuesta truncada);
    /// `.mute` = acepta y nunca responde (timeout del cliente).
    behavior: enum { respond, drop, partial, mute } = .respond,

    pub fn init(allocator: std.mem.Allocator, response_body: []const u8, content_type: []const u8) !MockServer {
        var threaded = try allocator.create(Io.Threaded);
        errdefer allocator.destroy(threaded);
        threaded.* = Io.Threaded.init(allocator, .{});
        const io = threaded.io();
        // Listen on any available port
        var address = Io.net.IpAddress.parseLiteral("127.0.0.1:0") catch unreachable;
        var srv = try Io.net.IpAddress.listen(&address, io, .{ .mode = .stream, .protocol = .tcp });
        // Get the actual port assigned
        const actual_port = srv.socket.address.getPort();
        return .{
            .allocator = allocator,
            .threaded = threaded,
            .server = srv,
            .port = actual_port,
            .thread = null,
            .should_stop = false,
            .response_body = response_body,
            .content_type = content_type,
        };
    }

    pub fn deinit(self: *MockServer) void {
        self.should_stop = true;
        // Connect to the server to unblock accept
        if (self.port > 0) {
            const io = self.threaded.io();
            var address = Io.net.IpAddress.parseLiteral("127.0.0.1:0") catch unreachable;
            address.setPort(self.port);
            if (address.connect(io, .{ .mode = .stream })) |stream| {
                stream.close(io);
            } else |_| {}
        }
        if (self.thread) |t| t.join();
        const io = self.threaded.io();
        self.server.deinit(io);
        self.threaded.deinit();
        self.allocator.destroy(self.threaded);
    }

    pub fn start(self: *MockServer) !void {
        self.thread = try std.Thread.spawn(.{}, runServer, .{self});
    }

    fn runServer(self: *MockServer) void {
        const io = self.threaded.io();
        while (!self.should_stop) {
            var stream = self.server.accept(io) catch |err| switch (err) {
                error.Canceled => break,
                error.SocketNotListening => break,
                else => continue,
            };
            if (self.should_stop) {
                stream.close(io);
                break;
            }
            defer stream.close(io);
            switch (self.behavior) {
                .drop => continue, // corte inmediato: el defer cierra sin responder
                .mute => {
                    // Acepta y espera: el cliente debe cortar por SU plazo, no el nuestro.
                    var wait: usize = 0;
                    while (!self.should_stop and wait < 120_000) : (wait += 10) {
                        Sleep(10);
                    }
                    continue;
                },
                else => {},
            }
            // Send response
            var req_buf: [1024]u8 = undefined;
            const response = std.fmt.allocPrint(self.allocator, "HTTP/1.1 {s}\r\n" ++
                "Connection: close\r\n" ++
                "Content-Type: {s}\r\n" ++
                "Content-Length: {d}\r\n" ++
                "\r\n" ++
                "{s}", .{ self.status_line, self.content_type, self.response_body.len, self.response_body }) catch continue;
            defer self.allocator.free(response);
            var writer = stream.writer(io, &req_buf);
            if (self.behavior == .partial) {
                // Solo la mitad de los bytes: el cuerpo queda cortado a mitad y el
                // socket se cierra — respuesta truncada real, no un status raro.
                const half = response.len / 2;
                writer.interface.writeAll(response[0..half]) catch {};
                writer.interface.flush() catch {};
                continue;
            }
            writer.interface.writeAll(response) catch {};
            writer.interface.flush() catch {};

            // Drain socket until client closes (prevents RST)
            var discard_buf: [4096]u8 = undefined;
            var reader_drain = stream.reader(io, &discard_buf);
            while (true) {
                const n = reader_drain.interface.readSliceShort(&discard_buf) catch 0;
                if (n == 0) break;
            }
        }
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "mock server starts and responds" {
    const allocator = std.testing.allocator;
    var server = try MockServer.init(allocator, "hello", "text/plain");
    defer server.deinit();
    try server.start();
    // Port is non-zero if server started successfully
    try std.testing.expect(server.port > 0);
}
