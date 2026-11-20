const std = @import("std");
const tool_discovery = @import("tool_discovery.zig");

pub const PixelError = error{
    OutOfMemory,
    ParseError,
    HttpError,
    WriteFailed,
};

pub const PixelAgent = struct {
    id: []const u8,
    name: []const u8,
    role: []const u8,
    model: []const u8,
    room: []const u8,
    capabilities: [][]const u8,
    status: []const u8,
};

pub const PixelDivision = struct {
    id: []const u8,
    name: []const u8,
    description: []const u8,
    agent_count: i64,
    room_id: []const u8,
};

pub const JobResult = struct {
    id: []const u8,
    status: []const u8,
    result_json: ?[]const u8,
};

pub const SendFn = *const fn (url: []const u8, method: []const u8, body: []const u8) PixelError![]u8;

pub const PixelAdapter = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) PixelAdapter {
        return .{ .allocator = allocator };
    }

    pub fn parseDivisions(self: *const PixelAdapter, json_text: []const u8) PixelError![]PixelDivision {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_text, .{}) catch {
            return error.ParseError;
        };
        defer parsed.deinit();

        if (parsed.value != .array) return error.ParseError;

        var divisions: std.ArrayList(PixelDivision) = .empty;
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const id = if (obj.get("id")) |v| blk: {
                if (v == .string) break :blk v.string;
                continue;
            } else continue;
            const name = if (obj.get("name")) |v| blk: {
                if (v == .string) break :blk v.string;
                continue;
            } else continue;
            const description = if (obj.get("description")) |v| blk: {
                if (v == .string) break :blk v.string;
                continue;
            } else continue;
            const agent_count = if (obj.get("agentCount")) |v| blk: {
                if (v == .integer) break :blk v.integer;
                continue;
            } else continue;
            const room_id = if (obj.get("roomId")) |v| blk: {
                if (v == .string) break :blk v.string;
                continue;
            } else continue;

            try divisions.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, id),
                .name = try self.allocator.dupe(u8, name),
                .description = try self.allocator.dupe(u8, description),
                .agent_count = agent_count,
                .room_id = try self.allocator.dupe(u8, room_id),
            });
        }
        return divisions.toOwnedSlice(self.allocator);
    }

    pub fn parseAgents(self: *const PixelAdapter, json_text: []const u8) PixelError![]PixelAgent {
        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, json_text, .{}) catch {
            return error.ParseError;
        };
        defer parsed.deinit();

        if (parsed.value != .array) return error.ParseError;

        var agents: std.ArrayList(PixelAgent) = .empty;
        for (parsed.value.array.items) |item| {
            if (item != .object) continue;
            const obj = item.object;
            const id = if (obj.get("id")) |v| blk: {
                if (v == .string) break :blk v.string;
                continue;
            } else continue;
            const name = if (obj.get("name")) |v| blk: {
                if (v == .string) break :blk v.string;
                continue;
            } else continue;
            const role = if (obj.get("role")) |v| blk: {
                if (v == .string) break :blk v.string;
                continue;
            } else continue;
            const model = if (obj.get("model")) |v| blk: {
                if (v == .string) break :blk v.string;
                continue;
            } else continue;
            const room = if (obj.get("room")) |v| blk: {
                if (v == .string) break :blk v.string;
                continue;
            } else continue;
            const status = if (obj.get("status")) |v| blk: {
                if (v == .string) break :blk v.string;
                continue;
            } else continue;

            var caps: std.ArrayList([]const u8) = .empty;
            if (obj.get("capabilities")) |caps_v| {
                if (caps_v == .array) {
                    for (caps_v.array.items) |c| {
                        if (c == .string) {
                            const dup = try self.allocator.dupe(u8, c.string);
                            try caps.append(self.allocator, dup);
                        }
                    }
                }
            }

            try agents.append(self.allocator, .{
                .id = try self.allocator.dupe(u8, id),
                .name = try self.allocator.dupe(u8, name),
                .role = try self.allocator.dupe(u8, role),
                .model = try self.allocator.dupe(u8, model),
                .room = try self.allocator.dupe(u8, room),
                .capabilities = try caps.toOwnedSlice(self.allocator),
                .status = try self.allocator.dupe(u8, status),
            });
        }
        return try agents.toOwnedSlice(self.allocator);
    }

    pub fn agentsToResources(self: *const PixelAdapter, agents: []const PixelAgent) ![]tool_discovery.Resource {
        var resources: std.ArrayList(tool_discovery.Resource) = .empty;
        for (agents) |a| {
            const name = try std.fmt.allocPrint(self.allocator, "pixel:{s}", .{a.id});
            const desc = try std.fmt.allocPrint(self.allocator, "Pixel agent: {s} ({s}) — {s} via {s}", .{ a.name, a.role, a.room, a.model });
            const path = try std.fmt.allocPrint(self.allocator, "pixel://agents/{s}", .{a.id});
            const source = try self.allocator.dupe(u8, "pixel://");
            try resources.append(self.allocator, .{
                .kind = .agent,
                .name = name,
                .path = path,
                .description = desc,
                .source_root = source,
            });
        }
        return resources.toOwnedSlice(self.allocator);
    }

    pub fn divisionsToResources(self: *const PixelAdapter, divisions: []const PixelDivision) ![]tool_discovery.Resource {
        var resources: std.ArrayList(tool_discovery.Resource) = .empty;
        for (divisions) |d| {
            const name = try std.fmt.allocPrint(self.allocator, "pixel:div/{s}", .{d.id});
            const desc = try std.fmt.allocPrint(self.allocator, "Pixel division: {s} ({d} agents) — {s}", .{ d.name, d.agent_count, d.description });
            const path = try std.fmt.allocPrint(self.allocator, "pixel://divisions/{s}", .{d.id});
            const source = try self.allocator.dupe(u8, "pixel://");
            try resources.append(self.allocator, .{
                .kind = .agent,
                .name = name,
                .path = path,
                .description = desc,
                .source_root = source,
            });
        }
        return resources.toOwnedSlice(self.allocator);
    }

    pub fn delegateJob(send: SendFn, base_url: []const u8, agent_id: []const u8, prompt: []const u8, allocator: std.mem.Allocator) PixelError!JobResult {
        var out: std.Io.Writer.Allocating = .init(allocator);
        defer out.deinit();
        var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
        try js.write(.{
            .prompt = prompt,
            .mode = "execute",
            .targetAgentId = agent_id,
        });
        const body = allocator.dupe(u8, out.written()) catch return error.OutOfMemory;
        defer allocator.free(body);

        const url = try std.fmt.allocPrint(allocator, "{s}/api/jobs", .{base_url});
        defer allocator.free(url);

        const response = try send(url, "POST", body);
        defer allocator.free(response);

        const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
            return error.ParseError;
        };
        defer parsed.deinit();

        if (parsed.value != .object) return error.ParseError;
        const obj = parsed.value.object;
        const id = if (obj.get("id")) |v| blk: {
            if (v == .string) break :blk v.string;
            return error.ParseError;
        } else return error.ParseError;
        const status = if (obj.get("status")) |v| blk: {
            if (v == .string) break :blk v.string;
            return error.ParseError;
        } else return error.ParseError;

        return .{
            .id = try allocator.dupe(u8, id),
            .status = try allocator.dupe(u8, status),
            .result_json = null,
        };
    }
};

test "parse divisions fixture" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"id":"eng","name":"Engineering","description":"Dev","agentCount":5,"roomId":"war-room"}]
    ;
    var adapter = PixelAdapter.init(allocator);
    const divisions = try adapter.parseDivisions(json);
    defer {
        for (divisions) |d| {
            allocator.free(d.id);
            allocator.free(d.name);
            allocator.free(d.description);
            allocator.free(d.room_id);
        }
        allocator.free(divisions);
    }
    try std.testing.expectEqual(@as(usize, 1), divisions.len);
    try std.testing.expectEqualStrings("eng", divisions[0].id);
    try std.testing.expectEqualStrings("Engineering", divisions[0].name);
    try std.testing.expectEqual(@as(i64, 5), divisions[0].agent_count);
}

test "parse agents fixture" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"id":"atlas","name":"Atlas","role":"Orchestrator","model":"m1","room":"dispatch","capabilities":["planning"],"status":"active"}]
    ;
    var adapter = PixelAdapter.init(allocator);
    const agents = try adapter.parseAgents(json);
    defer {
        for (agents) |a| {
            allocator.free(a.id);
            allocator.free(a.name);
            allocator.free(a.role);
            allocator.free(a.model);
            allocator.free(a.room);
            for (a.capabilities) |c| allocator.free(c);
            allocator.free(a.capabilities);
            allocator.free(a.status);
        }
        allocator.free(agents);
    }
    try std.testing.expectEqual(@as(usize, 1), agents.len);
    try std.testing.expectEqualStrings("atlas", agents[0].id);
    try std.testing.expectEqualStrings("Orchestrator", agents[0].role);
    try std.testing.expect(agents[0].capabilities.len >= 1);
}

test "agents to resources" {
    const allocator = std.testing.allocator;
    const json =
        \\[{"id":"rook","name":"Rook","role":"Runner","model":"m1","room":"ops","capabilities":["execution"],"status":"active"}]
    ;
    var adapter = PixelAdapter.init(allocator);
    const agents = try adapter.parseAgents(json);
    defer {
        for (agents) |a| {
            allocator.free(a.id);
            allocator.free(a.name);
            allocator.free(a.role);
            allocator.free(a.model);
            allocator.free(a.room);
            for (a.capabilities) |c| allocator.free(c);
            allocator.free(a.capabilities);
            allocator.free(a.status);
        }
        allocator.free(agents);
    }
    const resources = try adapter.agentsToResources(agents);
    defer {
        for (resources) |r| r.deinit(allocator);
        allocator.free(resources);
    }
    try std.testing.expectEqual(@as(usize, 1), resources.len);
    try std.testing.expectEqualStrings("pixel:rook", resources[0].name);
    try std.testing.expectEqual(tool_discovery.ResourceKind.agent, resources[0].kind);
}

test "malformed json returns error" {
    const allocator = std.testing.allocator;
    var adapter = PixelAdapter.init(allocator);
    try std.testing.expectError(error.ParseError, adapter.parseDivisions("not json"));
    try std.testing.expectError(error.ParseError, adapter.parseAgents("{bad"));
}

test "delegate job with mock send" {
    const allocator = std.testing.allocator;
    const mockSend = struct {
        fn send(url: []const u8, method: []const u8, body: []const u8) PixelError![]u8 {
            _ = url;
            _ = method;
            _ = body;
            return std.testing.allocator.dupe(u8, "{\"id\":\"job-99\",\"status\":\"queued\"}");
        }
    }.send;

    const result = try PixelAdapter.delegateJob(mockSend, "http://localhost:4317", "rook", "test prompt", allocator);
    defer {
        allocator.free(result.id);
        allocator.free(result.status);
    }
    try std.testing.expectEqualStrings("job-99", result.id);
    try std.testing.expectEqualStrings("queued", result.status);
}
