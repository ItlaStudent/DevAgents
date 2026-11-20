pub const NamedPipeServer = switch (@import("builtin").os.tag) {
    .windows => WindowsNamedPipeServer,
    else => @import("unix_socket.zig").NamedPipeServer,
};
pub const NamedPipeClient = switch (@import("builtin").os.tag) {
    .windows => WindowsNamedPipeClient,
    else => @import("unix_socket.zig").NamedPipeClient,
};
const std = @import("std");
const protocol = @import("protocol.zig");
const Message = protocol.Message;
const MessageHeader = protocol.MessageHeader;

extern "kernel32" fn CreateNamedPipeA(
    lpName: [*:0]const u8,
    dwOpenMode: u32,
    dwPipeMode: u32,
    nMaxInstances: u32,
    nOutBufferSize: u32,
    nInBufferSize: u32,
    nDefaultTimeOut: u32,
    lpSecurityAttributes: ?*anyopaque,
) std.os.windows.HANDLE;

extern "kernel32" fn ConnectNamedPipe(
    hNamedPipe: std.os.windows.HANDLE,
    lpOverlapped: ?*anyopaque,
) std.os.windows.BOOL;

extern "kernel32" fn DisconnectNamedPipe(
    hNamedPipe: std.os.windows.HANDLE,
) std.os.windows.BOOL;

extern "kernel32" fn CreateFileA(
    lpFileName: [*:0]const u8,
    dwDesiredAccess: u32,
    dwShareMode: u32,
    lpSecurityAttributes: ?*anyopaque,
    dwCreationDisposition: u32,
    dwFlagsAndAttributes: u32,
    hTemplateFile: ?std.os.windows.HANDLE,
) std.os.windows.HANDLE;

extern "kernel32" fn ReadFile(
    hFile: std.os.windows.HANDLE,
    lpBuffer: [*]u8,
    nNumberOfBytesToRead: u32,
    lpNumberOfBytesRead: *u32,
    lpOverlapped: ?*anyopaque,
) std.os.windows.BOOL;

extern "kernel32" fn WriteFile(
    hFile: std.os.windows.HANDLE,
    lpBuffer: [*]const u8,
    nNumberOfBytesToWrite: u32,
    lpNumberOfBytesWritten: *u32,
    lpOverlapped: ?*anyopaque,
) std.os.windows.BOOL;

extern "kernel32" fn CloseHandle(
    hObject: std.os.windows.HANDLE,
) std.os.windows.BOOL;

const PIPE_ACCESS_DUPLEX: u32 = 0x00000003;
const PIPE_TYPE_BYTE: u32 = 0x00000000;
const PIPE_READMODE_BYTE: u32 = 0x00000000;
const PIPE_WAIT: u32 = 0x00000000;
const PIPE_UNLIMITED_INSTANCES: u32 = 255;
const PIPE_DEFAULT_TIMEOUT: u32 = 5000;
const BUFFER_SIZE: u32 = 4096;

const GENERIC_READ: u32 = 0x80000000;
const GENERIC_WRITE: u32 = 0x40000000;
const FILE_SHARE_READ: u32 = 0x00000001;
const FILE_SHARE_WRITE: u32 = 0x00000002;
const OPEN_EXISTING: u32 = 3;
const FILE_FLAG_OVERLAPPED: u32 = 0x40000000;
const INVALID_HANDLE_VALUE: std.os.windows.HANDLE = @ptrFromInt(~@as(usize, 0));

const PipeError = error{
    CreatePipeFailed,
    ConnectPipeFailed,
    DisconnectPipeFailed,
    OpenPipeFailed,
    ReadFailed,
    WriteFailed,
    ConnectionClosed,
    BufferTooSmall,
};

pub const WindowsNamedPipeServer = struct {
    pipe_name: []const u8,
    handle: std.os.windows.HANDLE,

    pub fn init(pipe_name: []const u8) !WindowsNamedPipeServer {
        const name_fmt = try std.fmt.allocPrint(std.heap.page_allocator, "\\\\.\\pipe\\{s}", .{pipe_name});
        defer std.heap.page_allocator.free(name_fmt);
        const name_nt = try std.heap.page_allocator.dupeZ(u8, name_fmt);
        defer std.heap.page_allocator.free(name_nt);

        const handle = CreateNamedPipeA(
            name_nt,
            PIPE_ACCESS_DUPLEX,
            PIPE_TYPE_BYTE | PIPE_READMODE_BYTE | PIPE_WAIT,
            PIPE_UNLIMITED_INSTANCES,
            BUFFER_SIZE,
            BUFFER_SIZE,
            PIPE_DEFAULT_TIMEOUT,
            null,
        );
        if (handle == INVALID_HANDLE_VALUE) return error.CreatePipeFailed;

        return .{
            .pipe_name = try std.heap.page_allocator.dupe(u8, pipe_name),
            .handle = handle,
        };
    }

    pub fn deinit(self: *WindowsNamedPipeServer) void {
        _ = CloseHandle(self.handle);
        std.heap.page_allocator.free(self.pipe_name);
    }

    pub fn waitForConnection(self: *WindowsNamedPipeServer) !void {
        const result = ConnectNamedPipe(self.handle, null);
        if (result == .FALSE) {
            const err = std.os.windows.GetLastError();
            if (err != .PIPE_CONNECTED) return error.ConnectPipeFailed;
        }
    }

    pub fn disconnect(self: *WindowsNamedPipeServer) !void {
        const result = DisconnectNamedPipe(self.handle);
        if (result == .FALSE) return error.DisconnectPipeFailed;
    }

    pub fn sendMessage(self: *WindowsNamedPipeServer, msg: *const Message) !void {
        const buf = try msg.serialize(std.heap.page_allocator);
        defer std.heap.page_allocator.free(buf);

        var written: u32 = 0;
        const result = WriteFile(self.handle, buf.ptr, @intCast(buf.len), &written, null);
        if (result == .FALSE) return error.WriteFailed;
    }

    pub fn receiveMessage(self: *WindowsNamedPipeServer, allocator: std.mem.Allocator) !Message {
        var header_buf: [@sizeOf(MessageHeader)]u8 = undefined;
        var bytes_read: u32 = 0;

        const result = ReadFile(self.handle, &header_buf, @sizeOf(MessageHeader), &bytes_read, null);
        if (result == .FALSE) {
            const err = std.os.windows.GetLastError();
            if (err == .BROKEN_PIPE or err == .PIPE_NOT_CONNECTED) {
                return error.ConnectionClosed;
            }
            return error.ReadFailed;
        }
        if (bytes_read < @sizeOf(MessageHeader)) return error.ConnectionClosed;

        const header = std.mem.bytesToValue(MessageHeader, &header_buf);
        try header.validate();

        const payload = try allocator.alloc(u8, header.payload_len);
        var payload_read: u32 = 0;
        var offset: u32 = 0;
        while (offset < header.payload_len) {
            const result2 = ReadFile(
                self.handle,
                payload.ptr + offset,
                header.payload_len - offset,
                &payload_read,
                null,
            );
            if (result2 == .FALSE) {
                allocator.free(payload);
                return error.ReadFailed;
            }
            offset += payload_read;
        }

        var header_mut = header;
        header_mut.computeChecksum(payload);
        if (header_mut.checksum != header.checksum) {
            allocator.free(payload);
            return error.InvalidChecksum;
        }

        return .{
            .allocator = allocator,
            .header = header,
            .payload = payload,
        };
    }
};

pub const WindowsNamedPipeClient = struct {
    pipe_name: []const u8,
    handle: std.os.windows.HANDLE,

    pub fn init(pipe_name: []const u8) !WindowsNamedPipeClient {
        const name_fmt = try std.fmt.allocPrint(std.heap.page_allocator, "\\\\.\\pipe\\{s}", .{pipe_name});
        defer std.heap.page_allocator.free(name_fmt);
        const name_nt = try std.heap.page_allocator.dupeZ(u8, name_fmt);
        defer std.heap.page_allocator.free(name_nt);

        const handle = CreateFileA(
            name_nt,
            GENERIC_READ | GENERIC_WRITE,
            FILE_SHARE_READ | FILE_SHARE_WRITE,
            null,
            OPEN_EXISTING,
            0,
            null,
        );
        if (handle == INVALID_HANDLE_VALUE) return error.OpenPipeFailed;

        return .{
            .pipe_name = try std.heap.page_allocator.dupe(u8, pipe_name),
            .handle = handle,
        };
    }

    pub fn deinit(self: *WindowsNamedPipeClient) void {
        _ = CloseHandle(self.handle);
        std.heap.page_allocator.free(self.pipe_name);
    }

    pub fn sendMessage(self: *WindowsNamedPipeClient, msg: *const Message) !void {
        const buf = try msg.serialize(std.heap.page_allocator);
        defer std.heap.page_allocator.free(buf);

        var written: u32 = 0;
        const result = WriteFile(self.handle, buf.ptr, @intCast(buf.len), &written, null);
        if (result == .FALSE) return error.WriteFailed;
    }

    pub fn receiveMessage(self: *WindowsNamedPipeClient, allocator: std.mem.Allocator) !Message {
        var header_buf: [@sizeOf(MessageHeader)]u8 = undefined;
        var bytes_read: u32 = 0;

        const result = ReadFile(self.handle, &header_buf, @sizeOf(MessageHeader), &bytes_read, null);
        if (result == .FALSE) return error.ReadFailed;
        if (bytes_read < @sizeOf(MessageHeader)) return error.ConnectionClosed;

        const header = std.mem.bytesToValue(MessageHeader, &header_buf);
        try header.validate();

        const payload = try allocator.alloc(u8, header.payload_len);
        var payload_read: u32 = 0;
        var offset: u32 = 0;
        while (offset < header.payload_len) {
            const result2 = ReadFile(
                self.handle,
                payload.ptr + offset,
                header.payload_len - offset,
                &payload_read,
                null,
            );
            if (result2 == .FALSE) {
                allocator.free(payload);
                return error.ReadFailed;
            }
            offset += payload_read;
        }

        var header_mut = header;
        header_mut.computeChecksum(payload);
        if (header_mut.checksum != header.checksum) {
            allocator.free(payload);
            return error.InvalidChecksum;
        }

        return .{
            .allocator = allocator,
            .header = header,
            .payload = payload,
        };
    }
};

test "named pipe protocol message roundtrip" {
    const allocator = std.testing.allocator;
    var msg = try Message.create(allocator, .task_assign, "hello pipe");
    defer msg.deinit();

    const buf = try msg.serialize(allocator);
    defer allocator.free(buf);

    var decoded = try Message.deserialize(allocator, buf);
    defer decoded.deinit();

    try std.testing.expectEqualStrings("hello pipe", decoded.payload);
    try std.testing.expectEqual(@intFromEnum(protocol.MsgType.task_assign), decoded.header.msg_type);
}

test "named pipe server client roundtrip" {
    const allocator = std.testing.allocator;

    var server = try NamedPipeServer.init("test-devagents");
    defer server.deinit();

    var client = try NamedPipeClient.init("test-devagents");
    defer client.deinit();
    try server.waitForConnection();

    var msg = try Message.create(allocator, .heartbeat, "ping");
    defer msg.deinit();

    try client.sendMessage(&msg);
    var received = try server.receiveMessage(allocator);
    defer received.deinit();

    try std.testing.expectEqualStrings("ping", received.payload);
    try std.testing.expectEqual(@intFromEnum(protocol.MsgType.heartbeat), received.header.msg_type);

    try server.disconnect();
}

test "D4: named pipe da_status and ping pong roundtrip" {
    const allocator = std.testing.allocator;

    var server = try NamedPipeServer.init("test-devagents-status");
    defer server.deinit();

    var client = try NamedPipeClient.init("test-devagents-status");
    defer client.deinit();
    try server.waitForConnection();

    // Ping -> Pong
    {
        var ping_msg = try Message.create(allocator, .ping, "ping");
        defer ping_msg.deinit();
        try client.sendMessage(&ping_msg);

        var server_rcv = try server.receiveMessage(allocator);
        defer server_rcv.deinit();
        try std.testing.expectEqual(@intFromEnum(protocol.MsgType.ping), server_rcv.header.msg_type);

        var pong_msg = try Message.create(allocator, .pong, "pong");
        defer pong_msg.deinit();
        try server.sendMessage(&pong_msg);

        var client_rcv = try client.receiveMessage(allocator);
        defer client_rcv.deinit();
        try std.testing.expectEqual(@intFromEnum(protocol.MsgType.pong), client_rcv.header.msg_type);
        try std.testing.expectEqualStrings("pong", client_rcv.payload);
    }

    // Status Request -> Status Response (da_status)
    {
        var req = try Message.create(allocator, .status_request, "{\"query\":\"da_status\"}");
        defer req.deinit();
        try client.sendMessage(&req);

        var server_req = try server.receiveMessage(allocator);
        defer server_req.deinit();
        try std.testing.expectEqual(@intFromEnum(protocol.MsgType.status_request), server_req.header.msg_type);

        var resp = try Message.create(allocator, .status_response, "{\"status\":\"online\",\"active_tasks\":0,\"version\":\"v4.0.0\"}");
        defer resp.deinit();
        try server.sendMessage(&resp);

        var client_resp = try client.receiveMessage(allocator);
        defer client_resp.deinit();
        try std.testing.expectEqual(@intFromEnum(protocol.MsgType.status_response), client_resp.header.msg_type);
        try std.testing.expect(std.mem.indexOf(u8, client_resp.payload, "\"status\":\"online\"") != null);
    }

    try server.disconnect();
}
