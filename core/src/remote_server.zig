//! E5.30: HTTP restricted to the engine process and IPv4 loopback.
const std = @import("std");
const api = @import("c_api.zig");
const sync = @import("sync.zig");
const windows = std.os.windows;
const builtin = @import("builtin");
const platform = @import("platform.zig");
const reading: i16 = if (builtin.os.tag == .windows) 0x100 else 1;
const write_event: i16 = if (builtin.os.tag == .windows) 0x10 else 4;
const SOCKET = if (builtin.os.tag == .windows) usize else c_int;
const invalid_socket: SOCKET = if (builtin.os.tag == .windows) ~@as(usize, 0) else -1;
const Address = if (builtin.os.tag == .macos) extern struct { len: u8 = 16, family: u8 = 2, port: u16, ip: u32 = 0x0100007f, padding: [8]u8 = @splat(0) } else extern struct { family: u16 = 2, port: u16, ip: u32 = 0x0100007f, padding: [8]u8 = @splat(0) };
const Poll = extern struct { fd: SOCKET, events: i16 = reading, revents: i16 = 0 };
const WsaData = extern struct { version: u16, high_version: u16, max_sockets: u16, max_udp: u16, vendor: ?*u8, description: [257]u8, status: [129]u8 };
const Win = struct {
    extern "ws2_32" fn WSAStartup(u16, *WsaData) callconv(.winapi) i32;
    extern "ws2_32" fn WSACleanup() callconv(.winapi) i32;
    extern "ws2_32" fn socket(i32, i32, i32) callconv(.winapi) SOCKET;
    extern "ws2_32" fn bind(SOCKET, *const Address, i32) callconv(.winapi) i32;
    extern "ws2_32" fn listen(SOCKET, i32) callconv(.winapi) i32;
    extern "ws2_32" fn accept(SOCKET, ?*Address, ?*i32) callconv(.winapi) SOCKET;
    extern "ws2_32" fn getsockname(SOCKET, *Address, *i32) callconv(.winapi) i32;
    extern "ws2_32" fn htons(u16) callconv(.winapi) u16;
    extern "ws2_32" fn closesocket(SOCKET) callconv(.winapi) i32;
    extern "ws2_32" fn recv(SOCKET, [*]u8, i32, i32) callconv(.winapi) i32;
    extern "ws2_32" fn send(SOCKET, [*]const u8, i32, i32) callconv(.winapi) i32;
    extern "ws2_32" fn ioctlsocket(SOCKET, u32, *u32) callconv(.winapi) i32;
    extern "ws2_32" fn WSAPoll([*]Poll, u32, i32) callconv(.winapi) i32;
};
const WSAStartup = if (builtin.os.tag == .windows) Win.WSAStartup else Posix.WSAStartup;
const WSACleanup = if (builtin.os.tag == .windows) Win.WSACleanup else Posix.WSACleanup;
const socket = if (builtin.os.tag == .windows) Win.socket else Posix.socket;
const bind = if (builtin.os.tag == .windows) Win.bind else Posix.bind;
const listen = if (builtin.os.tag == .windows) Win.listen else Posix.listen;
const accept = if (builtin.os.tag == .windows) Win.accept else Posix.accept;
const getsockname = if (builtin.os.tag == .windows) Win.getsockname else Posix.getsockname;
const htons = if (builtin.os.tag == .windows) Win.htons else Posix.htons;
const closesocket = if (builtin.os.tag == .windows) Win.closesocket else Posix.closesocket;
const recv = if (builtin.os.tag == .windows) Win.recv else Posix.recv;
const send = if (builtin.os.tag == .windows) Win.send else Posix.send;
const ioctlsocket = if (builtin.os.tag == .windows) Win.ioctlsocket else Posix.ioctlsocket;
const WSAPoll = if (builtin.os.tag == .windows) Win.WSAPoll else Posix.WSAPoll;
const GetTickCount64 = platform.ticks;
const GetStdHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn GetStdHandle(u32) callconv(.winapi) windows.HANDLE;
}.GetStdHandle else @import("providers").posix_files.GetStdHandle;
const WriteFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn WriteFile(windows.HANDLE, [*]const u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
}.WriteFile else @import("providers").posix_files.WriteFile;
const ReadFile = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn ReadFile(windows.HANDLE, [*]u8, u32, *u32, ?*anyopaque) callconv(.winapi) i32;
}.ReadFile else @import("providers").posix_files.ReadFile;
const CreateFileA = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CreateFileA([*:0]const u8, u32, u32, ?*anyopaque, u32, u32, ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
}.CreateFileA else @import("providers").posix_files.CreateFileA;
const CloseHandle = if (@import("builtin").os.tag == .windows) struct {
    extern "kernel32" fn CloseHandle(windows.HANDLE) callconv(.winapi) i32;
}.CloseHandle else @import("providers").posix_files.CloseHandle;
extern "kernel32" fn CreateEventW(?*anyopaque, i32, i32, ?[*:0]const u16) callconv(.winapi) ?windows.HANDLE;
extern "kernel32" fn WaitForSingleObject(windows.HANDLE, u32) callconv(.winapi) u32;
extern "kernel32" fn GetOverlappedResult(windows.HANDLE, *anyopaque, *u32, i32) callconv(.winapi) i32;
extern "kernel32" fn CancelIoEx(windows.HANDLE, *anyopaque) callconv(.winapi) i32;
const BCryptGenRandom = if (builtin.os.tag == .windows) struct {
    extern "bcrypt" fn BCryptGenRandom(?*anyopaque, [*]u8, u32, u32) callconv(.winapi) i32;
}.BCryptGenRandom else platform.random;

pub const max_body = 8192;
const max_header = 8192;
const max_response = 1024 * 1024;
pub const Request = struct { method: []const u8, path: []const u8, body: []const u8 };
pub const Response = struct { status: u16, body: []const u8 };

pub fn checkBind(address: []const u8) !void {
    if (!std.mem.eql(u8, address, "127.0.0.1")) return error.LoopbackRequired;
}

fn checkOrigin(origin: []const u8) !void {
    if (origin.len > 256 or std.mem.indexOfAny(u8, origin, "\r\n\t ,;=\\%@?#") != null) return error.InvalidOrigin;
    const uri = std.Uri.parse(origin) catch return error.InvalidOrigin;
    if (uri.user != null or uri.password != null or uri.query != null or uri.fragment != null or uri.path.percent_encoded.len != 0) return error.InvalidOrigin;
    const host = (uri.host orelse return error.InvalidOrigin).percent_encoded;
    if (host.len == 0 or (uri.port != null and uri.port.? == 0)) return error.InvalidOrigin;
    const loopback = std.ascii.eqlIgnoreCase(host, "localhost") or std.mem.eql(u8, host, "127.0.0.1") or std.mem.eql(u8, host, "[::1]");
    if (!std.mem.eql(u8, uri.scheme, "https") and !(loopback and std.mem.eql(u8, uri.scheme, "http"))) return error.InvalidOrigin;
}

/// A fresh startup hands the plaintext to the caller once; the server retains only its hash.
pub const Server = struct {
    allocator: std.mem.Allocator,
    fd: SOCKET,
    port: u16,
    token_hash: [32]u8,
    origin: ?[]const u8,
    core_handle: ?*anyopaque,
    request_lock: ?*sync.Mutex = null,
    parent_pipe: ?[]const u8,
    rate_epoch: u64 = 0,
    rate_count: u16 = 0,
    stopping: std.atomic.Value(bool) = .init(false),

    pub fn init(allocator: std.mem.Allocator, address: []const u8, port: u16, origin: ?[]const u8, handle: ?*anyopaque, parent_pipe: ?[]const u8, token: *[64]u8) !Server {
        try checkBind(address);
        if (origin) |o| try checkOrigin(o);
        var wsa: WsaData = undefined;
        if (WSAStartup(0x202, &wsa) != 0) return error.Winsock;
        errdefer _ = WSACleanup();
        const fd = socket(2, 1, 6);
        if (fd == invalid_socket) return error.Winsock;
        errdefer _ = closesocket(fd);
        // The bind address is a constant, never derived from CLI/user input.
        const address_bin: Address = .{ .port = htons(port) };
        if (bind(fd, &address_bin, @sizeOf(Address)) != 0) return error.BindFailed;
        if (listen(fd, 16) != 0) return error.ListenFailed;
        var bound: Address = undefined;
        var length: i32 = @sizeOf(Address);
        if (getsockname(fd, &bound, &length) != 0) return error.Winsock;
        var random: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &random);
        if (BCryptGenRandom(null, &random, random.len, 2) != 0) return error.RandomFailed;
        token.* = std.fmt.bytesToHex(random, .lower);
        var hash: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(token, &hash, .{});
        return .{ .allocator = allocator, .fd = fd, .port = htons(bound.port), .token_hash = hash, .origin = origin, .core_handle = handle, .parent_pipe = parent_pipe };
    }

    pub fn deinit(self: *Server) void {
        _ = closesocket(self.fd);
        _ = WSACleanup();
        std.crypto.secureZero(u8, &self.token_hash);
    }

    pub fn requestStop(self: *Server) void {
        self.stopping.store(true, .release);
    }

    pub fn persistHash(self: *Server, path: []const u8) !void {
        var threaded: std.Io.Threaded = .init(self.allocator, .{});
        defer threaded.deinit();
        const io = threaded.io();
        const file = try std.Io.Dir.cwd().createFile(io, path, .{});
        defer file.close(io);
        const hash_hex = std.fmt.bytesToHex(self.token_hash, .lower);
        try file.writeStreamingAll(io, &hash_hex);
    }

    fn ownOrigin(self: *Server, buffer: []u8) ![]const u8 {
        return std.fmt.bufPrint(buffer, "http://127.0.0.1:{d}", .{self.port});
    }

    fn originAllowed(self: *Server, value: []const u8) bool {
        var buffer: [64]u8 = undefined;
        const own = self.ownOrigin(&buffer) catch return false;
        return originEqual(value, own) or (self.origin != null and originEqual(value, self.origin.?));
    }

    pub fn guard(self: *Server, header: []const u8, now: u64) u16 {
        const authorization = headerValue(header, "Authorization") orelse return 401;
        if (!std.mem.startsWith(u8, authorization, "Bearer ")) return 401;
        const presented = authorization[7..];
        if (presented.len != 64) return 401;
        var hash: [32]u8 = undefined;
        defer std.crypto.secureZero(u8, &hash);
        std.crypto.hash.sha2.Sha256.hash(presented, &hash, .{});
        if (!std.crypto.timing_safe.eql([32]u8, hash, self.token_hash)) return 401;
        if (headerValue(header, "Cookie") != null) return 403;
        if (headerValue(header, "Origin")) |origin| if (!self.originAllowed(origin)) return 403;
        if (now -| self.rate_epoch >= 60_000) {
            self.rate_epoch = now;
            self.rate_count = 0;
        }
        if (self.rate_count >= 120) return 429;
        self.rate_count += 1;
        return 200;
    }

    fn hostStatus(self: *Server, header: []const u8) u16 {
        const host = headerValue(header, "Host") orelse return 400;
        // headerValue returns an empty value for duplicates; neither case is a host.
        if (host.len == 0) return 400;
        var buffer: [80]u8 = undefined;
        const self_host = std.fmt.bufPrint(&buffer, "127.0.0.1:{d}", .{self.port}) catch return 500;
        if (authorityEqual(host, self_host, 80)) return 200;
        if (self.origin) |origin| {
            const tunneled_host = origin[std.mem.indexOf(u8, origin, "://").? + 3 ..];
            if (authorityEqual(host, tunneled_host, if (std.mem.startsWith(u8, origin, "https://")) 443 else 80)) return 200;
        }
        return 403;
    }

    pub fn serve(self: *Server) !void {
        while (!self.stopping.load(.acquire)) {
            var ready: Poll = .{ .fd = self.fd };
            const polled = WSAPoll(@ptrCast(&ready), 1, 100);
            if (polled < 0) return error.Winsock;
            if (polled == 0) continue;
            if (ready.revents & reading == 0) return error.AcceptFailed;
            const client = accept(self.fd, null, null);
            if (client == invalid_socket) return error.AcceptFailed;
            defer _ = closesocket(client);
            self.connection(client) catch |failure| {
                // No input, token or request payload is ever written to logs.
                std.debug.print("remote connection: {s}\n", .{@errorName(failure)});
            };
        }
    }

    fn connection(self: *Server, client: SOCKET) !void {
        var nonblocking: u32 = 1;
        if (ioctlsocket(client, 0x8004667e, &nonblocking) != 0) return error.Winsock;
        const started = GetTickCount64();
        var bytes: [max_header + max_body]u8 = undefined;
        defer std.crypto.secureZero(u8, &bytes);
        var used: usize = 0;
        var header_end: usize = 0;
        while (header_end == 0) {
            if (used >= max_header) return self.reply(client, 431, "{\"error\":\"cabeceras demasiado grandes\"}", "application/json", started);
            used += try readSocket(client, bytes[used..max_header], started);
            if (std.mem.indexOf(u8, bytes[0..used], "\r\n\r\n")) |end| header_end = end + 4;
        }
        const header = bytes[0..header_end];
        var lines = std.mem.splitSequence(u8, header, "\r\n");
        const first = lines.next() orelse return error.InvalidRequest;
        var words = std.mem.splitScalar(u8, first, ' ');
        const method = words.next() orelse return error.InvalidRequest;
        const path = words.next() orelse return error.InvalidRequest;
        if (!std.mem.eql(u8, words.next() orelse "", "HTTP/1.1") or words.next() != null) return error.InvalidRequest;
        const host_status = self.hostStatus(header);
        if (host_status != 200) return self.reply(client, host_status, "{\"error\":\"Host ausente, ambiguo o no permitido\"}", "application/json", started);
        if (std.mem.eql(u8, method, "GET") and std.mem.eql(u8, path, "/")) return self.reply(client, 200, @embedFile("remote.html"), "text/html; charset=utf-8", started);
        if (std.mem.eql(u8, path, "/favicon.ico")) return self.reply(client, 200, "", "image/x-icon", started);
        const guard_status = self.guard(header, started);
        if (guard_status != 200) return self.reply(client, guard_status, "{\"error\":\"acceso rechazado\"}", "application/json", started);
        if (headerValue(header, "Transfer-Encoding") != null) return self.reply(client, 400, "{\"error\":\"transferencia no admitida\"}", "application/json", started);
        const body_len = std.fmt.parseInt(usize, headerValue(header, "Content-Length") orelse "0", 10) catch return self.reply(client, 400, "{\"error\":\"longitud invalida\"}", "application/json", started);
        if (body_len > max_body) return self.reply(client, 413, "{\"error\":\"cuerpo demasiado grande\"}", "application/json", started);
        if (std.mem.eql(u8, method, "POST") and !std.mem.eql(u8, headerValue(header, "Content-Type") orelse "", "application/json")) return self.reply(client, 415, "{\"error\":\"solo JSON\"}", "application/json", started);
        while (used < header_end + body_len) used += try readSocket(client, bytes[used .. header_end + body_len], started);
        const request: Request = .{ .method = method, .path = path, .body = bytes[header_end .. header_end + body_len] };
        const request_json = try std.json.Stringify.valueAlloc(self.allocator, request, .{});
        defer self.allocator.free(request_json);
        const result = if (self.parent_pipe) |pipe| try broker(self.allocator, pipe, request_json, started) else blk: {
            if (self.request_lock) |mutex| mutex.lock();
            defer if (self.request_lock) |mutex| mutex.unlock();
            const z = try self.allocator.dupeZ(u8, request_json);
            defer self.allocator.free(z);
            var output: ?[*:0]u8 = null;
            if (api.da_remote_request_json(self.core_handle, z, &output) != 0) return self.reply(client, 500, "{\"error\":\"error del motor\"}", "application/json", started);
            const c = output orelse return error.InvalidResponse;
            defer api.da_string_free(c);
            break :blk try self.allocator.dupe(u8, std.mem.span(c));
        };
        defer self.allocator.free(result);
        const parsed = try std.json.parseFromSlice(Response, self.allocator, result, .{});
        defer parsed.deinit();
        if (parsed.value.body.len > max_response) return error.ResponseTooLarge;
        try self.reply(client, parsed.value.status, parsed.value.body, "application/json", started);
    }

    fn reply(self: *Server, client: SOCKET, status: u16, body: []const u8, content_type: []const u8, started: u64) !void {
        _ = self;
        var buffer: [1024]u8 = undefined;
        const header = try std.fmt.bufPrint(&buffer, "HTTP/1.1 {d} Response\r\nContent-Type: {s}\r\nContent-Length: {d}\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\nReferrer-Policy: no-referrer\r\nContent-Security-Policy: default-src 'self'; script-src 'unsafe-inline'; style-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n\r\n", .{ status, content_type, body.len });
        try writeSocket(client, header, started);
        try writeSocket(client, body, started);
    }
};

fn authorityEqual(left: []const u8, right: []const u8, default_port: u16) bool {
    const Authority = struct {
        host: []const u8,
        port: u16,
        fn parse(text: []const u8, fallback: u16) ?@This() {
            if (text.len == 0 or std.mem.indexOfAny(u8, text, "/\\@?# \t\r\n") != null) return null;
            const end = if (text[0] == '[') (std.mem.indexOfScalar(u8, text, ']') orelse return null) + 1 else (std.mem.indexOfScalar(u8, text, ':') orelse text.len);
            if (end == 0) return null;
            const port = if (end == text.len) fallback else blk: {
                if (text[end] != ':') return null;
                break :blk std.fmt.parseInt(u16, text[end + 1 ..], 10) catch return null;
            };
            if (port == 0) return null;
            return .{ .host = text[0..end], .port = port };
        }
    };
    const l = Authority.parse(left, default_port) orelse return false;
    const r = Authority.parse(right, default_port) orelse return false;
    return std.ascii.eqlIgnoreCase(l.host, r.host) and l.port == r.port;
}

fn originEqual(left: []const u8, right: []const u8) bool {
    checkOrigin(left) catch return false;
    checkOrigin(right) catch return false;
    const l = std.mem.indexOf(u8, left, "://") orelse return false;
    const r = std.mem.indexOf(u8, right, "://") orelse return false;
    if (!std.ascii.eqlIgnoreCase(left[0..l], right[0..r])) return false;
    return authorityEqual(left[l + 3 ..], right[r + 3 ..], if (std.ascii.eqlIgnoreCase(left[0..l], "https")) 443 else 80);
}

test "VG1 B4: Host folds case and default ports on both sides" {
    var server: Server = .{ .allocator = std.testing.allocator, .fd = invalid_socket, .port = 12345, .token_hash = @splat(0), .origin = "https://PHONE.example:443", .core_handle = null, .parent_pipe = null };
    try std.testing.expect(server.originAllowed("https://phone.EXAMPLE"));
    try std.testing.expect(!server.originAllowed("http://phone.example"));
    try std.testing.expectEqual(@as(u16, 200), server.hostStatus("GET / HTTP/1.1\r\nHost: phone.EXAMPLE\r\n"));
    server.origin = "https://phone.example";
    try std.testing.expectEqual(@as(u16, 200), server.hostStatus("GET / HTTP/1.1\r\nHost: PHONE.example:443\r\n"));
    try std.testing.expectEqual(@as(u16, 403), server.hostStatus("GET / HTTP/1.1\r\nHost: phone.example:444\r\n"));
    server.origin = "http://LOCALHOST:80";
    try std.testing.expectEqual(@as(u16, 200), server.hostStatus("GET / HTTP/1.1\r\nHost: localhost\r\n"));
    server.origin = "http://localhost";
    try std.testing.expectEqual(@as(u16, 200), server.hostStatus("GET / HTTP/1.1\r\nHost: LOCALHOST:80\r\n"));
    try std.testing.expectEqual(@as(u16, 403), server.hostStatus("GET / HTTP/1.1\r\nHost: localhost.evil:80\r\n"));
}

fn headerValue(header: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    _ = lines.next();
    var result: ?[]const u8 = null;
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(line[0..colon], name)) {
            // Ambiguous duplicates fail closed instead of choosing first/last.
            if (result != null) return "";
            result = std.mem.trim(u8, line[colon + 1 ..], " \t");
        }
    }
    return result;
}

fn waitSocket(fd: SOCKET, event: i16, started: u64) !void {
    while (true) {
        const elapsed = GetTickCount64() - started;
        if (elapsed >= 5000) return error.Timeout;
        var poll: Poll = .{ .fd = fd, .events = event };
        const n = WSAPoll(@ptrCast(&poll), 1, @intCast(5000 - elapsed));
        if (n < 0) return error.Winsock;
        if (n > 0) {
            if (poll.revents & event == 0) return error.ConnectionClosed;
            return;
        }
    }
}
fn readSocket(fd: SOCKET, bytes: []u8, started: u64) !usize {
    try waitSocket(fd, reading, started);
    const n = recv(fd, bytes.ptr, @intCast(bytes.len), 0);
    if (n <= 0) return error.ConnectionClosed;
    return @intCast(n);
}
fn writeSocket(fd: SOCKET, bytes: []const u8, started: u64) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        try waitSocket(fd, write_event, started);
        const n = send(fd, bytes.ptr + offset, @intCast(bytes.len - offset), 0);
        if (n <= 0) return error.ConnectionClosed;
        offset += @intCast(n);
    }
}

fn broker(allocator: std.mem.Allocator, pipe: []const u8, request: []const u8, started: u64) ![]const u8 {
    if (builtin.os.tag != .windows) return error.ParentPipeWindowsOnly;
    if (!std.mem.startsWith(u8, pipe, "\\\\.\\pipe\\beats-remote-")) return error.InvalidPipe;
    const z = try allocator.dupeZ(u8, pipe);
    defer allocator.free(z);
    const handle = CreateFileA(z, 0xc0000000, 0, null, 3, 0x40000000, null);
    if (handle == @as(windows.HANDLE, @ptrFromInt(~@as(usize, 0)))) return error.BrokerUnavailable;
    defer _ = CloseHandle(handle);
    const line = try std.fmt.allocPrint(allocator, "{s}\n", .{request});
    defer allocator.free(line);
    if (try pipeTransfer(handle, @constCast(line), true, started) != line.len) return error.BrokerWrite;
    var output: std.ArrayList(u8) = .empty;
    errdefer output.deinit(allocator);
    var bytes: [4096]u8 = undefined;
    while (output.items.len <= max_response) {
        const count = try pipeTransfer(handle, &bytes, false, started);
        if (count == 0) return error.BrokerRead;
        if (std.mem.indexOfScalar(u8, bytes[0..count], '\n')) |end| {
            try output.appendSlice(allocator, bytes[0..end]);
            var ack = [_]u8{'\n'};
            if (try pipeTransfer(handle, &ack, true, started) != 1) return error.BrokerWrite;
            return output.toOwnedSlice(allocator);
        }
        try output.appendSlice(allocator, bytes[0..count]);
    }
    return error.ResponseTooLarge;
}

fn pipeTransfer(handle: windows.HANDLE, buffer: []u8, writing: bool, started: u64) !usize {
    const event = CreateEventW(null, 1, 0, null) orelse return error.BrokerEvent;
    defer _ = CloseHandle(event);
    const Overlapped = extern struct { internal: usize = 0, internal_high: usize = 0, offset: u32 = 0, offset_high: u32 = 0, event: windows.HANDLE };
    var overlapped: Overlapped = .{ .event = event };
    var count: u32 = 0;
    const result = if (writing) WriteFile(handle, buffer.ptr, @intCast(buffer.len), &count, &overlapped) else ReadFile(handle, buffer.ptr, @intCast(buffer.len), &count, &overlapped);
    if (result != 0) return count;
    if (windows.GetLastError() != .IO_PENDING) return error.BrokerIo;
    const elapsed = GetTickCount64() - started;
    const remaining: u32 = @intCast(5000 -| @min(elapsed, 5000));
    if (WaitForSingleObject(event, remaining) != 0) {
        _ = CancelIoEx(handle, &overlapped);
        // The OVERLAPPED and buffer remain alive until cancellation completes.
        _ = GetOverlappedResult(handle, &overlapped, &count, 1);
        return error.Timeout;
    }
    if (GetOverlappedResult(handle, &overlapped, &count, 0) == 0) return error.BrokerIo;
    return count;
}

pub fn run(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 1 or !std.mem.eql(u8, args[0], "serve")) return error.InvalidArguments;
    var port: u16 = 0;
    var origin: ?[]const u8 = null;
    var address: []const u8 = "127.0.0.1";
    var data_dir: ?[]const u8 = null;
    var pipe: ?[]const u8 = null;
    var hash_file: ?[]const u8 = null;
    var i: usize = 1;
    while (i < args.len) : (i += 2) {
        if (i + 1 >= args.len) return error.InvalidArguments;
        const key = args[i];
        const value = args[i + 1];
        if (std.mem.eql(u8, key, "--port")) port = try std.fmt.parseInt(u16, value, 10) else if (std.mem.eql(u8, key, "--origin")) origin = value else if (std.mem.eql(u8, key, "--bind")) address = value else if (std.mem.eql(u8, key, "--data-dir")) data_dir = value else if (std.mem.eql(u8, key, "--parent-pipe")) pipe = value else if (std.mem.eql(u8, key, "--hash-file")) hash_file = value else return error.InvalidArguments;
    }
    try checkBind(address);
    if ((data_dir == null) == (pipe == null)) return error.ExactlyOneEngineSourceRequired;
    if (pipe) |value| if (!std.mem.startsWith(u8, value, "\\\\.\\pipe\\beats-remote-")) return error.InvalidPipe;
    if (pipe != null and builtin.os.tag != .windows) return error.ParentPipeWindowsOnly;
    var handle: ?*anyopaque = null;
    if (data_dir) |dir| {
        const path = try std.fs.path.join(allocator, &.{ dir, "runtime.db" });
        defer allocator.free(path);
        const z = try allocator.dupeZ(u8, path);
        defer allocator.free(z);
        if (api.da_core_init(&handle, z) != 0) return error.CoreInitFailed;
    }
    defer if (handle != null) {
        _ = api.da_core_shutdown(handle);
    };
    var token: [64]u8 = undefined;
    defer std.crypto.secureZero(u8, &token);
    var server = try Server.init(allocator, address, port, origin, handle, pipe, &token);
    defer server.deinit();
    const default_hash_path = if (data_dir) |dir| try std.fs.path.join(allocator, &.{ dir, "remote_token.sha256" }) else null;
    defer if (default_hash_path) |path| allocator.free(path);
    if (hash_file orelse default_hash_path) |path| {
        try server.persistHash(path);
    }
    var buffer: [256]u8 = undefined;
    defer std.crypto.secureZero(u8, &buffer);
    const startup = try std.fmt.bufPrint(&buffer, "{{\"url\":\"http://127.0.0.1:{d}\",\"token\":\"{s}\"}}\n", .{ server.port, token });
    if (builtin.os.tag == .windows) {
        var written: u32 = 0;
        const stdout = GetStdHandle(@bitCast(@as(i32, -11)));
        if (WriteFile(stdout, startup.ptr, @intCast(startup.len), &written, null) == 0 or written != startup.len) return error.StartupWrite;
    } else {
        var offset: usize = 0;
        while (offset < startup.len) {
            const count = std.c.write(1, startup.ptr + offset, startup.len - offset);
            if (count < 0 and std.c._errno().* == @intFromEnum(std.posix.E.INTR)) continue;
            if (count <= 0) return error.StartupWrite;
            offset += @intCast(count);
        }
    }
    std.crypto.secureZero(u8, &token);
    std.crypto.secureZero(u8, &buffer);
    try server.serve();
}

test "E5.30 guard rejects network bind" {
    try checkBind("127.0.0.1");
    for ([_][]const u8{ "0.0.0.0", "192.168.1.1", "::1", "localhost" }) |address| try std.testing.expectError(error.LoopbackRequired, checkBind(address));
}
test "E5.30 server fresh token hash bound loopback and stoppable" {
    var token: [64]u8 = undefined;
    try std.testing.expectError(error.InvalidOrigin, Server.init(std.testing.allocator, "127.0.0.1", 0, "https://invalid.example/path", null, null, &token));
    var server = try Server.init(std.testing.allocator, "127.0.0.1", 0, null, null, null, &token);
    defer server.deinit();
    defer @memset(&token, 0);
    try std.testing.expect(server.port != 0);
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&token, &hash, .{});
    try std.testing.expectEqualSlices(u8, &hash, &server.token_hash);
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var path_buffer: [4096]u8 = undefined;
    const root_len = try tmp.dir.realPath(std.testing.io, &path_buffer);
    const hash_path = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..root_len], "token.sha256" });
    defer std.testing.allocator.free(hash_path);
    try server.persistHash(hash_path);
    const saved = try tmp.dir.readFileAlloc(std.testing.io, "token.sha256", std.testing.allocator, .limited(65));
    defer std.testing.allocator.free(saved);
    const expected = std.fmt.bytesToHex(hash, .lower);
    try std.testing.expect(std.mem.eql(u8, &expected, saved));
    try std.testing.expect(!std.mem.eql(u8, &token, saved));
    const missing = try std.fs.path.join(std.testing.allocator, &.{ path_buffer[0..root_len], "missing", "token.sha256" });
    defer std.testing.allocator.free(missing);
    try std.testing.expectError(error.FileNotFound, server.persistHash(missing));
    var address: Address = undefined;
    var len: i32 = @sizeOf(Address);
    try std.testing.expectEqual(@as(i32, 0), getsockname(server.fd, &address, &len));
    try std.testing.expectEqual(@as(u32, 0x0100007f), address.ip);
    try std.testing.expectError(error.BindFailed, Server.init(std.testing.allocator, "127.0.0.1", server.port, null, null, null, &token));
    const thread = try std.Thread.spawn(.{}, Server.serve, .{&server});
    server.requestStop();
    thread.join();
}
test "E5.30 guard auth origin cookie rate" {
    var token: [64]u8 = @splat('a');
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&token, &hash, .{});
    var server: Server = .{ .allocator = std.testing.allocator, .fd = invalid_socket, .port = 12345, .token_hash = hash, .origin = "https://phone.example", .core_handle = null, .parent_pipe = null };
    const auth = try std.fmt.allocPrint(std.testing.allocator, "GET / HTTP/1.1\r\nAuthorization: {s}{s}\r\n", .{ "Bearer ", token });
    defer std.testing.allocator.free(auth);
    try std.testing.expectEqual(@as(u16, 401), server.guard("GET / HTTP/1.1\r\n", 1));
    try std.testing.expectEqual(@as(u16, 401), server.guard("GET / HTTP/1.1\r\nAuthorization: Bearer bad\r\n", 1));
    const wrong = try std.fmt.allocPrint(std.testing.allocator, "GET / HTTP/1.1\r\nAuthorization: {s}{s}\r\n", .{ "Bearer ", [_]u8{'b'} ** 64 });
    defer std.testing.allocator.free(wrong);
    try std.testing.expectEqual(@as(u16, 401), server.guard(wrong, 1));
    try std.testing.expectEqual(@as(u16, 200), server.guard(auth, 1));
    for ([_][]const u8{ "Origin: https://evil.example\r\n", "Origin: null\r\n", "Cookie: session=x\r\n" }) |extra| {
        const header = try std.fmt.allocPrint(std.testing.allocator, "{s}{s}", .{ auth, extra });
        defer std.testing.allocator.free(header);
        try std.testing.expectEqual(@as(u16, 403), server.guard(header, 2));
    }
    const allowed = try std.fmt.allocPrint(std.testing.allocator, "{s}Origin: https://phone.example\r\n", .{auth});
    defer std.testing.allocator.free(allowed);
    try std.testing.expectEqual(@as(u16, 200), server.guard(allowed, 2));
    server.rate_count = 120;
    try std.testing.expectEqual(@as(u16, 429), server.guard(auth, 2));
    try std.testing.expectEqual(@as(u16, 200), server.guard(auth, 60001));
}
test "E5.30 header duplicates fail closed and CLI rejects invalid source" {
    try std.testing.expectEqualStrings("", headerValue("GET / HTTP/1.1\r\nAuthorization: x\r\nAuthorization: y\r\n", "authorization").?);
    try std.testing.expectError(error.InvalidArguments, run(std.testing.allocator, &.{"invalid"}));
    try std.testing.expectError(error.ExactlyOneEngineSourceRequired, run(std.testing.allocator, &.{"serve"}));
    try std.testing.expectError(error.InvalidArguments, run(std.testing.allocator, &.{ "serve", "--port" }));
    try std.testing.expectError(error.LoopbackRequired, run(std.testing.allocator, &.{ "serve", "--bind", "0.0.0.0" }));
    try std.testing.expectError(error.InvalidPipe, run(std.testing.allocator, &.{ "serve", "--parent-pipe", "bad" }));
}

test "HARD9. origin requires HTTPS outside loopback" {
    for ([_][]const u8{ "https://phone.example", "https://phone.example:443", "http://127.0.0.1:49180", "http://localhost:49180", "http://[::1]:49180" }) |origin| try checkOrigin(origin);
    for ([_][]const u8{ "http://phone.example", "http://127.0.0.1.evil.example", "https://", "https://phone.example/", "https://phone.example/path", "https://user@phone.example", "https://phone.example?query", "https://phone.example#fragment", "https://phone.example:0", "https://phone.example\r\nHost: evil", "ftp://127.0.0.1" }) |origin| try std.testing.expectError(error.InvalidOrigin, checkOrigin(origin));
    var token: [64]u8 = @splat(0);
    defer std.crypto.secureZero(u8, &token);
    try std.testing.expectError(error.InvalidOrigin, Server.init(std.testing.allocator, "127.0.0.1", 0, "http://phone.example", null, null, &token));
}

test "HARD9. Host empty duplicate missing and tunnel scope" {
    var server: Server = .{ .allocator = std.testing.allocator, .fd = invalid_socket, .port = 12345, .token_hash = @splat(0), .origin = null, .core_handle = null, .parent_pipe = null };
    for ([_][]const u8{ "GET / HTTP/1.1\r\n\r\n", "GET / HTTP/1.1\r\nHost:\r\n\r\n", "GET / HTTP/1.1\r\nHost: \t\r\n\r\n", "GET / HTTP/1.1\r\nHost: 127.0.0.1:12345\r\nHost: 127.0.0.1:12345\r\n\r\n", "GET / HTTP/1.1\r\nHost: 127.0.0.1:12345\r\nhost: evil.example\r\n\r\n" }) |header| try std.testing.expectEqual(@as(u16, 400), server.hostStatus(header));
    try std.testing.expectEqual(@as(u16, 200), server.hostStatus("GET / HTTP/1.1\r\nHost: 127.0.0.1:12345\r\n\r\n"));
    try std.testing.expectEqual(@as(u16, 403), server.hostStatus("GET / HTTP/1.1\r\nHost: phone.example\r\n\r\n"));
    server.origin = "https://phone.example";
    try std.testing.expectEqual(@as(u16, 200), server.hostStatus("GET / HTTP/1.1\r\nHost: phone.example\r\n\r\n"));
    try std.testing.expectEqual(@as(u16, 400), server.hostStatus("GET / HTTP/1.1\r\nHost:\r\n\r\n"));
    try std.testing.expectEqual(@as(u16, 403), server.hostStatus("GET / HTTP/1.1\r\nHost: evil.example\r\n\r\n"));
}

const Posix = struct {
    fn WSAStartup(_: u16, _: *WsaData) i32 {
        return 0;
    }
    fn WSACleanup() i32 {
        return 0;
    }
    fn socket(domain: i32, kind: i32, protocol: i32) SOCKET {
        const fd = std.c.socket(@intCast(domain), @intCast(kind), @intCast(protocol));
        if (fd < 0) return invalid_socket;
        if (std.c.fcntl(fd, std.c.F.SETFD, @as(c_int, 1)) < 0) {
            _ = std.c.close(fd);
            return invalid_socket;
        }
        if (builtin.os.tag == .macos) {
            const enabled: c_int = 1;
            if (std.c.setsockopt(fd, std.c.SOL.SOCKET, std.c.SO.NOSIGPIPE, @ptrCast(&enabled), @sizeOf(c_int)) != 0) {
                _ = std.c.close(fd);
                return invalid_socket;
            }
        }
        return fd;
    }
    fn bind(fd: SOCKET, address: *const Address, length: i32) i32 {
        return std.c.bind(fd, @ptrCast(address), @intCast(length));
    }
    fn listen(fd: SOCKET, backlog: i32) i32 {
        return std.c.listen(fd, @intCast(backlog));
    }
    fn accept(fd: SOCKET, _: ?*Address, _: ?*i32) SOCKET {
        const child = std.c.accept(fd, null, null);
        if (child < 0) return invalid_socket;
        if (std.c.fcntl(child, std.c.F.SETFD, @as(c_int, 1)) < 0) {
            _ = std.c.close(child);
            return invalid_socket;
        }
        return child;
    }
    fn getsockname(fd: SOCKET, address: *Address, length: *i32) i32 {
        var size: std.c.socklen_t = @intCast(length.*);
        const result = std.c.getsockname(fd, @ptrCast(address), &size);
        length.* = @intCast(size);
        return result;
    }
    fn htons(port: u16) u16 {
        return std.mem.nativeToBig(u16, port);
    }
    fn closesocket(fd: SOCKET) i32 {
        return std.c.close(fd);
    }
    fn recv(fd: SOCKET, bytes: [*]u8, length: i32, flags: i32) i32 {
        return @intCast(std.c.recv(fd, bytes, @intCast(length), @intCast(flags)));
    }
    fn send(fd: SOCKET, bytes: [*]const u8, length: i32, flags: i32) i32 {
        return @intCast(std.c.send(fd, bytes, @intCast(length), @as(u32, @intCast(flags)) | (if (builtin.os.tag == .linux) std.c.MSG.NOSIGNAL else 0)));
    }
    fn ioctlsocket(fd: SOCKET, _: u32, nonblocking: *u32) i32 {
        if (nonblocking.* != 1) return -1;
        const flags = std.c.fcntl(fd, std.c.F.GETFL);
        if (flags < 0) return -1;
        return std.c.fcntl(fd, std.c.F.SETFL, flags | @as(c_int, @intCast(@as(u32, @bitCast(std.c.O{ .NONBLOCK = true })))));
    }
    fn WSAPoll(fds: [*]Poll, count: u32, timeout: i32) i32 {
        return std.c.poll(@ptrCast(fds), count, timeout);
    }
};

test "B10 POSIX remote HTTP loopback enforces host auth origin and body limits" {
    if (builtin.os.tag == .windows) {
        try std.testing.expectError(error.LoopbackRequired, checkBind("0.0.0.0"));
        return;
    }
    const a = std.testing.allocator;
    var token: [64]u8 = undefined;
    var server = try Server.init(a, "127.0.0.1", 0, null, null, null, &token);
    defer server.deinit();
    defer @memset(&token, 0);
    const thread = try std.Thread.spawn(.{}, Server.serve, .{&server});
    defer {
        server.requestStop();
        thread.join();
    }
    const cases = [_]struct { path: []const u8, headers: []const u8, status: []const u8 }{
        .{ .path = "/", .headers = "", .status = "HTTP/1.1 200" },
        .{ .path = "/api/orders", .headers = "", .status = "HTTP/1.1 401" },
        .{ .path = "/api/orders", .headers = "Authorization: Bearer bad\r\n", .status = "HTTP/1.1 401" },
        .{ .path = "/api/orders", .headers = "Origin: https://evil.example\r\n", .status = "HTTP/1.1 403" },
        .{ .path = "/api/orders", .headers = "Content-Length: 8193\r\n", .status = "HTTP/1.1 413" },
    };
    for (cases, 0..) |case, index| {
        const fd = Posix.socket(2, 1, 6);
        if (fd == invalid_socket) return error.ConnectFailed;
        defer _ = Posix.closesocket(fd);
        const address: Address = .{ .port = Posix.htons(server.port) };
        if (std.c.connect(fd, @ptrCast(&address), @sizeOf(Address)) != 0) return error.ConnectFailed;
        var nonblocking: u32 = 1;
        if (Posix.ioctlsocket(fd, 0, &nonblocking) != 0) return error.ConnectFailed;
        const auth = if (index >= 3) try std.fmt.allocPrint(a, "Authorization: Bearer {s}\r\n", .{token}) else try a.dupe(u8, "");
        defer a.free(auth);
        const request = try std.fmt.allocPrint(a, "GET {s} HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\n{s}{s}\r\n", .{ case.path, server.port, auth, case.headers });
        defer a.free(request);
        const started = platform.ticks();
        try writeSocket(fd, request, started);
        var response: [4096]u8 = undefined;
        const count = try readSocket(fd, &response, started);
        try std.testing.expect(std.mem.startsWith(u8, response[0..count], case.status));
        try std.testing.expect(platform.ticks() - started < 5000);
    }
    try std.testing.expectError(error.ParentPipeWindowsOnly, run(a, &.{ "serve", "--parent-pipe", "\\\\.\\pipe\\beats-remote-fixture" }));
}
