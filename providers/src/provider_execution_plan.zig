const std = @import("std");

pub const ProviderExecutionPlan = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ProviderExecutionPlan {
        return .{ .allocator = allocator };
    }
};

test "provider execution plan init" {
    const allocator = std.testing.allocator;
    const plan = ProviderExecutionPlan.init(allocator);
    _ = plan;
}
