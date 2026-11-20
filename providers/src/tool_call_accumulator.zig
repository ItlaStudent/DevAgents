const std = @import("std");

pub const ToolCallAccumulator = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ToolCallAccumulator {
        return .{ .allocator = allocator };
    }
};

test "tool call accumulator init" {
    const allocator = std.testing.allocator;
    const acc = ToolCallAccumulator.init(allocator);
    _ = acc;
}
