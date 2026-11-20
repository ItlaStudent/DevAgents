const std = @import("std");

pub const RetryPlanner = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RetryPlanner {
        return .{ .allocator = allocator };
    }
};

test "retry planner init" {
    const allocator = std.testing.allocator;
    const rp = RetryPlanner.init(allocator);
    _ = rp;
}
