const std = @import("std");

/// Magic number del protocolo DevAgents IPC: 0xDA7A6000
pub const PROTOCOL_MAGIC: u32 = 0xDA7A6000;

/// Versión actual del protocolo.
pub const PROTOCOL_VERSION: u16 = 1;

/// Tipos de mensaje soportados.
pub const MsgType = enum(u16) {
    task_assign = 1,
    task_result = 2,
    heartbeat = 3,
    log_event = 4,
    state_change = 5,
    contract_proposal = 6,
    contract_accept = 7,
    audit_request = 8,
    ping = 9,
    pong = 10,
    status_request = 11,
    status_response = 12,
    _, // allow future extensions
};

/// Header fijo de 16 bytes para todo mensaje del bus.
pub const MessageHeader = extern struct {
    magic: u32,
    version: u16,
    msg_type: u16,
    payload_len: u32,
    checksum: u32,

    pub fn init(msg_type: MsgType, payload_len: u32) MessageHeader {
        return .{
            .magic = PROTOCOL_MAGIC,
            .version = PROTOCOL_VERSION,
            .msg_type = @intFromEnum(msg_type),
            .payload_len = payload_len,
            .checksum = 0, // computed later
        };
    }

    pub fn computeChecksum(self: *MessageHeader, payload: []const u8) void {
        self.checksum = crc32(payload);
    }

    pub fn validate(self: MessageHeader) error{ InvalidMagic, VersionMismatch, InvalidChecksum }!void {
        if (self.magic != PROTOCOL_MAGIC) return error.InvalidMagic;
        if (self.version != PROTOCOL_VERSION) return error.VersionMismatch;
        // checksum validated separately with payload
    }
};

/// Mensaje completo: header + payload.
pub const Message = struct {
    allocator: std.mem.Allocator,
    header: MessageHeader,
    payload: []const u8,

    pub fn create(allocator: std.mem.Allocator, msg_type: MsgType, payload: []const u8) !Message {
        var header = MessageHeader.init(msg_type, @intCast(payload.len));
        header.computeChecksum(payload);
        const payload_copy = try allocator.dupe(u8, payload);
        return .{
            .allocator = allocator,
            .header = header,
            .payload = payload_copy,
        };
    }

    pub fn deinit(self: *Message) void {
        self.allocator.free(self.payload);
    }

    /// Serializa el mensaje completo en un buffer recién asignado.
    pub fn serialize(self: Message, allocator: std.mem.Allocator) ![]u8 {
        const total_len = @sizeOf(MessageHeader) + self.payload.len;
        const buf = try allocator.alloc(u8, total_len);
        @memcpy(buf[0..@sizeOf(MessageHeader)], std.mem.asBytes(&self.header));
        @memcpy(buf[@sizeOf(MessageHeader)..], self.payload);
        return buf;
    }

    /// Deserializa desde un buffer. El payload se copia al allocator.
    pub fn deserialize(allocator: std.mem.Allocator, buf: []const u8) !Message {
        if (buf.len < @sizeOf(MessageHeader)) return error.BufferTooSmall;
        const header = std.mem.bytesToValue(MessageHeader, buf[0..@sizeOf(MessageHeader)]);
        try header.validate();
        if (buf.len < @sizeOf(MessageHeader) + header.payload_len) return error.BufferTooSmall;
        const payload = try allocator.dupe(u8, buf[@sizeOf(MessageHeader)..][0..header.payload_len]);
        errdefer allocator.free(payload);
        // Validate checksum
        var header_mut = header;
        header_mut.computeChecksum(payload);
        if (header_mut.checksum != header.checksum) return error.InvalidChecksum;
        return .{
            .allocator = allocator,
            .header = header,
            .payload = payload,
        };
    }
};

/// CRC32 simple (tabla precalculada omitida para brevedad; usar lookup estático).
fn crc32(data: []const u8) u32 {
    const CRC32_TABLE: [256]u32 = comptime blk: {
        @setEvalBranchQuota(3000);
        var table: [256]u32 = undefined;
        for (&table, 0..) |*entry, i| {
            var c: u32 = @intCast(i);
            var j: usize = 0;
            while (j < 8) : (j += 1) {
                if (c & 1 != 0) {
                    c = 0xEDB88320 ^ (c >> 1);
                } else {
                    c = c >> 1;
                }
            }
            entry.* = c;
        }
        break :blk table;
    };
    var hash: u32 = 0xFFFFFFFF;
    for (data) |byte| {
        hash = CRC32_TABLE[(hash ^ byte) & 0xFF] ^ (hash >> 8);
    }
    return hash ^ 0xFFFFFFFF;
}

// ── Tests ──────────────────────────────────────────────────────────────

test "header init and validate" {
    var header = MessageHeader.init(.task_assign, 42);
    header.computeChecksum("hello");
    try header.validate();
    try std.testing.expectEqual(PROTOCOL_MAGIC, header.magic);
    try std.testing.expectEqual(PROTOCOL_VERSION, header.version);
    try std.testing.expectEqual(@intFromEnum(MsgType.task_assign), header.msg_type);
    try std.testing.expectEqual(@as(u32, 42), header.payload_len);
}

test "header invalid magic" {
    var header = MessageHeader.init(.task_assign, 0);
    header.magic = 0xDEADBEEF;
    const result = header.validate();
    try std.testing.expectError(error.InvalidMagic, result);
}

test "header version mismatch" {
    var header = MessageHeader.init(.task_assign, 0);
    header.version = 999;
    const result = header.validate();
    try std.testing.expectError(error.VersionMismatch, result);
}

test "message serialize deserialize" {
    const allocator = std.testing.allocator;
    var msg = try Message.create(allocator, .task_assign, "hello world");
    defer msg.deinit();

    const buf = try msg.serialize(allocator);
    defer allocator.free(buf);

    try std.testing.expectEqual(@as(usize, @sizeOf(MessageHeader) + 11), buf.len);

    var decoded = try Message.deserialize(allocator, buf);
    defer decoded.deinit();
    try std.testing.expectEqualStrings("hello world", decoded.payload);
    try std.testing.expectEqual(@intFromEnum(MsgType.task_assign), decoded.header.msg_type);
}

test "message detects corrupted payload" {
    const allocator = std.testing.allocator;
    var msg = try Message.create(allocator, .task_result, "data");
    defer msg.deinit();

    const buf = try msg.serialize(allocator);
    defer allocator.free(buf);

    // Corrupt the payload
    buf[@sizeOf(MessageHeader) + 1] = 0xFF;
    const result = Message.deserialize(allocator, buf);
    try std.testing.expectError(error.InvalidChecksum, result);
}

test "message rejects buffer too small" {
    const allocator = std.testing.allocator;
    const result = Message.deserialize(allocator, "tiny");
    try std.testing.expectError(error.BufferTooSmall, result);
}
