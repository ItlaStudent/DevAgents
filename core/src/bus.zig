const std = @import("std");
const sync = @import("sync.zig");
const protocol = @import("bus/protocol.zig");

pub const Message = protocol.Message;
pub const MessageHeader = protocol.MessageHeader;
pub const MsgType = protocol.MsgType;
pub const PROTOCOL_MAGIC = protocol.PROTOCOL_MAGIC;
pub const PROTOCOL_VERSION = protocol.PROTOCOL_VERSION;

pub const named_pipe = @import("bus/named_pipe.zig");

/// Bus de mensajes in-process para agentes en el mismo proceso.
/// Para IPC inter-proceso, se extenderá con pipes con nombre (Windows)
/// o domain sockets (Linux/macOS) en fases posteriores.
pub const InProcessBus = struct {
    allocator: std.mem.Allocator,
    queues: std.StringHashMap(std.ArrayList(Message)),
    mutex: sync.Mutex,

    pub fn init(allocator: std.mem.Allocator) InProcessBus {
        return .{
            .allocator = allocator,
            .queues = std.StringHashMap(std.ArrayList(Message)).init(allocator),
            .mutex = sync.Mutex.init(),
        };
    }

    pub fn deinit(self: *InProcessBus) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.queues.iterator();
        while (it.next()) |entry| {
            for (entry.value_ptr.items) |*msg| {
                msg.deinit();
            }
            entry.value_ptr.deinit(self.allocator);
            self.allocator.free(entry.key_ptr.*);
        }
        self.queues.deinit();
    }

    /// Enviar un mensaje a un agente por su ID.
    pub fn send(self: *InProcessBus, agent_id: []const u8, msg: Message) !void {
        self.mutex.lock();
        defer self.mutex.unlock();
        const gop = try self.queues.getOrPut(agent_id);
        if (gop.found_existing) {
            try gop.value_ptr.append(self.allocator, msg);
        } else {
            gop.key_ptr.* = try self.allocator.dupe(u8, agent_id);
            var list = std.ArrayList(Message).empty;
            try list.append(self.allocator, msg);
            gop.value_ptr.* = list;
        }
    }

    /// Recibir un mensaje de un agente (no bloqueante).
    pub fn recv(self: *InProcessBus, agent_id: []const u8) ?Message {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queues.getPtr(agent_id)) |queue| {
            if (queue.items.len > 0) {
                return queue.orderedRemove(0);
            }
        }
        return null;
    }

    /// Contar mensajes pendientes para un agente.
    pub fn pending(self: *InProcessBus, agent_id: []const u8) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.queues.getPtr(agent_id)) |queue| {
            return queue.items.len;
        }
        return 0;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "in-process bus send and recv" {
    const allocator = std.testing.allocator;
    var bus = InProcessBus.init(allocator);
    defer bus.deinit();

    const msg = try Message.create(allocator, .task_assign, "do work");
    // bus owns the message after send
    try bus.send("agent-1", msg);
    try std.testing.expectEqual(@as(usize, 1), bus.pending("agent-1"));

    var received = bus.recv("agent-1");
    try std.testing.expect(received != null);
    try std.testing.expectEqualStrings("do work", received.?.payload);
    try std.testing.expectEqual(@as(usize, 0), bus.pending("agent-1"));
    received.?.deinit();
}

test "in-process bus empty recv" {
    const allocator = std.testing.allocator;
    var bus = InProcessBus.init(allocator);
    defer bus.deinit();

    const received = bus.recv("agent-2");
    try std.testing.expect(received == null);
}

test "in-process bus multiple agents" {
    const allocator = std.testing.allocator;
    var bus = InProcessBus.init(allocator);
    defer bus.deinit();

    const msg1 = try Message.create(allocator, .task_assign, "task1");
    try bus.send("a", msg1);
    const msg2 = try Message.create(allocator, .task_assign, "task2");
    try bus.send("b", msg2);

    try std.testing.expectEqual(@as(usize, 1), bus.pending("a"));
    try std.testing.expectEqual(@as(usize, 1), bus.pending("b"));

    var r1 = bus.recv("a");
    try std.testing.expectEqualStrings("task1", r1.?.payload);
    r1.?.deinit();

    var r2 = bus.recv("b");
    try std.testing.expectEqualStrings("task2", r2.?.payload);
    r2.?.deinit();
}
