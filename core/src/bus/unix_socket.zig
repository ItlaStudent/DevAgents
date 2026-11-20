//! Local IPC with the existing framed protocol; no TCP listener.
const std = @import("std");
const protocol = @import("protocol.zig");
const a = std.heap.page_allocator;
extern "c" fn lstat(path: [*:0]const u8, stat: *std.c.Stat) c_int;

fn endpoint(name: []const u8) ![:0]u8 {
    if (name.len == 0 or name.len > 256 or std.mem.indexOfScalar(u8, name, 0) != null) return error.InvalidPipeName;
    const root = try std.fmt.allocPrintSentinel(a, "/tmp/devagents-{d}", .{std.c.getuid()}, 0);
    defer a.free(root);
    if (std.c.mkdir(root, 0o700) != 0 and std.c._errno().* != @intFromEnum(std.posix.E.EXIST)) return error.CreatePipeFailed;
    const stat = @import("providers").posix_stat.get(std.c.AT.FDCWD, root) catch return error.UnsafeSocketDirectory;
    if (stat.uid != std.c.getuid() or stat.mode & 0o777 != 0o700 or stat.mode & std.c.S.IFMT != std.c.S.IFDIR) return error.UnsafeSocketDirectory;
    const hash = std.hash.Wyhash.hash(0, name);
    return std.fmt.allocPrintSentinel(a, "{s}/{x}.sock", .{ root, hash }, 0);
}

fn readExact(io: std.Io, stream: std.Io.net.Stream, buffer: []u8) !void {
    var offset: usize = 0;
    while (offset < buffer.len) {
        var slices = [_][]u8{buffer[offset..]};
        const n = try io.vtable.netRead(io.userdata, stream.socket.handle, &slices);
        if (n == 0) return error.ConnectionClosed;
        offset += n;
    }
}

fn receive(io: std.Io, stream: std.Io.net.Stream, allocator: std.mem.Allocator) !protocol.Message {
    var raw: [@sizeOf(protocol.MessageHeader)]u8 = undefined;
    try readExact(io, stream, &raw);
    const header = std.mem.bytesToValue(protocol.MessageHeader, &raw);
    try header.validate();
    const payload = try allocator.alloc(u8, header.payload_len);
    errdefer allocator.free(payload);
    try readExact(io, stream, payload);
    var computed = header;
    computed.computeChecksum(payload);
    if (computed.checksum != header.checksum) return error.InvalidChecksum;
    return .{ .allocator = allocator, .header = header, .payload = payload };
}

fn send(io: std.Io, stream: std.Io.net.Stream, msg: *const protocol.Message) !void {
    const raw = try msg.serialize(a);
    defer a.free(raw);
    var buffer: [4096]u8 = undefined;
    var writer = stream.writer(io, &buffer);
    try writer.interface.writeAll(raw);
    try writer.interface.flush();
}

pub const NamedPipeServer = struct {
    threaded: *std.Io.Threaded,
    path: [:0]u8,
    server: std.Io.net.Server,
    stream: ?std.Io.net.Stream = null,

    pub fn init(name: []const u8) !NamedPipeServer {
        const path = try endpoint(name);
        errdefer a.free(path);
        const threaded = try a.create(std.Io.Threaded);
        errdefer a.destroy(threaded);
        threaded.* = .init(a, .{});
        errdefer threaded.deinit();
        const address = try std.Io.net.UnixAddress.init(path);
        var server = try address.listen(threaded.io(), .{});
        errdefer server.deinit(threaded.io());
        if (std.c.chmod(path, 0o600) != 0) return error.UnsafeSocketPermissions;
        return .{ .threaded = threaded, .path = path, .server = server };
    }
    pub fn deinit(self: *NamedPipeServer) void {
        if (self.stream) |s| s.close(self.threaded.io());
        self.server.deinit(self.threaded.io());
        if (std.c.unlink(self.path) != 0) std.log.err("Unix IPC cleanup failed", .{});
        self.threaded.deinit();
        a.destroy(self.threaded);
        a.free(self.path);
    }
    pub fn waitForConnection(self: *NamedPipeServer) !void {
        if (self.stream != null) return error.AlreadyConnected;
        self.stream = try self.server.accept(self.threaded.io());
    }
    pub fn disconnect(self: *NamedPipeServer) !void {
        const stream = self.stream orelse return error.ConnectionClosed;
        stream.close(self.threaded.io());
        self.stream = null;
    }
    pub fn sendMessage(self: *NamedPipeServer, msg: *const protocol.Message) !void {
        try send(self.threaded.io(), self.stream orelse return error.ConnectionClosed, msg);
    }
    pub fn receiveMessage(self: *NamedPipeServer, allocator: std.mem.Allocator) !protocol.Message {
        return receive(self.threaded.io(), self.stream orelse return error.ConnectionClosed, allocator);
    }
};

pub const NamedPipeClient = struct {
    threaded: *std.Io.Threaded,
    stream: std.Io.net.Stream,
    pub fn init(name: []const u8) !NamedPipeClient {
        const path = try endpoint(name);
        defer a.free(path);
        const t = try a.create(std.Io.Threaded);
        errdefer a.destroy(t);
        t.* = .init(a, .{});
        errdefer t.deinit();
        const address = try std.Io.net.UnixAddress.init(path);
        return .{ .threaded = t, .stream = try address.connect(t.io()) };
    }
    pub fn deinit(self: *NamedPipeClient) void {
        self.stream.close(self.threaded.io());
        self.threaded.deinit();
        a.destroy(self.threaded);
    }
    pub fn sendMessage(self: *NamedPipeClient, msg: *const protocol.Message) !void {
        try send(self.threaded.io(), self.stream, msg);
    }
    pub fn receiveMessage(self: *NamedPipeClient, allocator: std.mem.Allocator) !protocol.Message {
        return receive(self.threaded.io(), self.stream, allocator);
    }
};

test "B10 Unix IPC rejects empty and oversized names" {
    if (@import("builtin").os.tag == .windows) return @import("../platform.zig").skip("T9: socket Unix (bus POSIX); en Windows el bus usa tuberias con nombre");
    try std.testing.expectError(error.InvalidPipeName, endpoint(""));
    try std.testing.expectError(error.InvalidPipeName, endpoint(&@as([257]u8, @splat('x'))));
}
