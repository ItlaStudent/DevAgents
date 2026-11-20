const std = @import("std");
const sync = @import("sync.zig");

/// Estado de un agente en el runtime.
pub const AgentState = enum {
    idle,
    busy,
    waiting_approval,
    failed,
    terminated,
};

/// Un mensaje en el buzón de un agente.
pub const Message = struct {
    msg_type: []const u8,
    sender_id: []const u8,
    payload: []const u8,
    timestamp_ms: i64,

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        allocator.free(self.msg_type);
        allocator.free(self.sender_id);
        allocator.free(self.payload);
    }
};

/// Buzón de mensajes de un agente (cola FIFO con límite).
pub const Mailbox = struct {
    allocator: std.mem.Allocator,
    messages: std.ArrayList(Message),
    max_capacity: usize,
    mutex: sync.Mutex,

    pub fn init(allocator: std.mem.Allocator, max_capacity: usize) Mailbox {
        return .{
            .allocator = allocator,
            .messages = std.ArrayList(Message).empty,
            .max_capacity = max_capacity,
            .mutex = sync.Mutex.init(),
        };
    }

    pub fn deinit(self: *Mailbox) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        for (self.messages.items) |*msg| {
            msg.deinit(self.allocator);
        }
        self.messages.deinit(self.allocator);
    }

    /// Intenta encolar un mensaje. Retorna error si el buzón está lleno.
    pub fn push(self: *Mailbox, msg: Message) error{MailboxFull}!void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.messages.items.len >= self.max_capacity) {
            return error.MailboxFull;
        }
        self.messages.append(self.allocator, msg) catch return error.MailboxFull;
    }

    /// Extrae el primer mensaje (FIFO). Retorna null si está vacío.
    pub fn pop(self: *Mailbox) ?Message {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.messages.items.len == 0) {
            return null;
        }
        return self.messages.orderedRemove(0);
    }

    pub fn len(self: *Mailbox) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.messages.items.len;
    }
};

/// Un agente en el runtime de DevAgents.
pub const Agent = struct {
    allocator: std.mem.Allocator,
    id: []const u8,
    role: []const u8,
    state: AgentState,
    mailbox: Mailbox,
    parent_id: ?[]const u8,
    children: std.ArrayList(*Agent),

    pub fn create(allocator: std.mem.Allocator, id: []const u8, role: []const u8, parent_id: ?[]const u8) !*Agent {
        const self = try allocator.create(Agent);
        errdefer allocator.destroy(self);

        const id_copy = try allocator.dupe(u8, id);
        errdefer allocator.free(id_copy);

        const role_copy = try allocator.dupe(u8, role);
        errdefer allocator.free(role_copy);

        const parent_copy = if (parent_id) |p| try allocator.dupe(u8, p) else null;
        errdefer if (parent_copy) |p| allocator.free(p);

        self.* = .{
            .allocator = allocator,
            .id = id_copy,
            .role = role_copy,
            .state = .idle,
            .mailbox = Mailbox.init(allocator, 1024),
            .parent_id = parent_copy,
            .children = std.ArrayList(*Agent).empty,
        };
        return self;
    }

    pub fn destroy(self: *Agent) void {
        self.mailbox.deinit();
        for (self.children.items) |child| {
            child.destroy();
        }
        self.children.deinit(self.allocator);
        if (self.parent_id) |p| self.allocator.free(p);
        self.allocator.free(self.role);
        self.allocator.free(self.id);
        self.allocator.destroy(self);
    }

    pub fn addChild(self: *Agent, child: *Agent) !void {
        try self.children.append(self.allocator, child);
    }

    pub fn removeChild(self: *Agent, child: *Agent) void {
        for (self.children.items, 0..) |c, i| {
            if (c == child) {
                _ = self.children.orderedRemove(i);
                return;
            }
        }
    }

    pub fn send(self: *Agent, msg: Message) error{MailboxFull}!void {
        try self.mailbox.push(msg);
        if (self.state == .idle) {
            self.state = .busy;
        }
    }

    pub fn recv(self: *Agent) ?Message {
        return self.mailbox.pop();
    }

    pub fn getState(self: *Agent) AgentState {
        return self.state;
    }

    pub fn setState(self: *Agent, new_state: AgentState) void {
        self.state = new_state;
    }

    pub fn childCount(self: *Agent) usize {
        return self.children.items.len;
    }
};

/// Runtime que gestiona el registro de agentes.
pub const AgentRuntime = struct {
    allocator: std.mem.Allocator,
    agents: std.StringHashMap(*Agent),
    mutex: sync.Mutex,

    pub fn init(allocator: std.mem.Allocator) AgentRuntime {
        return .{
            .allocator = allocator,
            .agents = std.StringHashMap(*Agent).init(allocator),
            .mutex = sync.Mutex.init(),
        };
    }

    pub fn deinit(self: *AgentRuntime) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        var it = self.agents.valueIterator();
        while (it.next()) |agent_ptr| {
            agent_ptr.*.destroy();
        }
        self.agents.deinit();
    }

    /// Crea un agente y lo registra en el runtime. Retorna error si el ID ya existe.
    pub fn createAgent(self: *AgentRuntime, id: []const u8, role: []const u8, parent_id: ?[]const u8) !*Agent {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.agents.contains(id)) {
            return error.IdExists;
        }
        const agent = try Agent.create(self.allocator, id, role, parent_id);
        errdefer agent.destroy();
        try self.agents.put(id, agent);
        return agent;
    }

    /// Busca un agente por ID. Retorna null si no existe.
    pub fn getAgent(self: *AgentRuntime, id: []const u8) ?*Agent {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.agents.get(id);
    }

    /// Destruye un agente y lo elimina del registro.
    pub fn destroyAgent(self: *AgentRuntime, id: []const u8) void {
        self.mutex.lock();
        defer self.mutex.unlock();
        if (self.agents.fetchRemove(id)) |kv| {
            kv.value.destroy();
        }
    }

    pub fn count(self: *AgentRuntime) usize {
        self.mutex.lock();
        defer self.mutex.unlock();
        return self.agents.count();
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "agent lifecycle" {
    const allocator = std.testing.allocator;
    const agent = try Agent.create(allocator, "agent-1", "programmer", null);
    defer agent.destroy();

    try std.testing.expectEqualStrings("agent-1", agent.id);
    try std.testing.expectEqualStrings("programmer", agent.role);
    try std.testing.expectEqual(AgentState.idle, agent.state);
    try std.testing.expectEqual(@as(usize, 0), agent.mailbox.len());
}

test "agent send and recv" {
    const allocator = std.testing.allocator;
    const a = try Agent.create(allocator, "agent-2", "tester", null);
    defer a.destroy();

    const msg = Message{
        .msg_type = try allocator.dupe(u8, "task"),
        .sender_id = try allocator.dupe(u8, "supervisor"),
        .payload = try allocator.dupe(u8, "do something"),
        .timestamp_ms = 0,
    };
    // Leaked on failure, but test allocator catches leaks
    try a.send(msg);
    try std.testing.expectEqual(AgentState.busy, a.state);

    var received = a.recv();
    try std.testing.expect(received != null);
    try std.testing.expectEqualStrings("task", received.?.msg_type);
    try std.testing.expectEqualStrings("do something", received.?.payload);
    received.?.deinit(allocator);
}

test "mailbox full rejects message" {
    const allocator = std.testing.allocator;
    var mailbox = Mailbox.init(allocator, 2);
    defer mailbox.deinit();

    const msg = Message{
        .msg_type = try allocator.dupe(u8, "x"),
        .sender_id = try allocator.dupe(u8, "s"),
        .payload = try allocator.dupe(u8, "p"),
        .timestamp_ms = 0,
    };
    try mailbox.push(msg);
    const msg2 = Message{
        .msg_type = try allocator.dupe(u8, "x"),
        .sender_id = try allocator.dupe(u8, "s"),
        .payload = try allocator.dupe(u8, "p"),
        .timestamp_ms = 0,
    };
    try mailbox.push(msg2);
    const msg3 = Message{
        .msg_type = try allocator.dupe(u8, "x"),
        .sender_id = try allocator.dupe(u8, "s"),
        .payload = try allocator.dupe(u8, "p"),
        .timestamp_ms = 0,
    };
    const result = mailbox.push(msg3);
    try std.testing.expectError(error.MailboxFull, result);
    var msg3_mut = msg3;
    msg3_mut.deinit(allocator);
}

test "agent hierarchy" {
    const allocator = std.testing.allocator;
    const root = try Agent.create(allocator, "root", "superagent", null);
    defer root.destroy();

    const child = try Agent.create(allocator, "child", "programmer", "root");
    // child will be destroyed by root.destroy()
    try root.addChild(child);
    try std.testing.expectEqual(@as(usize, 1), root.childCount());
}

test "runtime create and destroy agent" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator);
    defer runtime.deinit();

    const a = try runtime.createAgent("a1", "tester", null);
    try std.testing.expectEqual(@as(usize, 1), runtime.count());
    try std.testing.expectEqualStrings("a1", a.id);

    runtime.destroyAgent("a1");
    try std.testing.expectEqual(@as(usize, 0), runtime.count());
}

test "runtime rejects duplicate id" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator);
    defer runtime.deinit();

    _ = try runtime.createAgent("dup", "tester", null);
    const result = runtime.createAgent("dup", "tester", null);
    try std.testing.expectError(error.IdExists, result);
}

test "runtime get agent" {
    const allocator = std.testing.allocator;
    var runtime = AgentRuntime.init(allocator);
    defer runtime.deinit();

    _ = try runtime.createAgent("g1", "tester", null);
    const found = runtime.getAgent("g1");
    try std.testing.expect(found != null);
    try std.testing.expectEqualStrings("g1", found.?.id);

    const not_found = runtime.getAgent("missing");
    try std.testing.expect(not_found == null);
}
