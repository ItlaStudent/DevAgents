const std = @import("std");

pub const ProviderExecutorV2 = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ProviderExecutorV2 {
        return .{ .allocator = allocator };
    }
};

test "provider executor v2 init" {
    const allocator = std.testing.allocator;
    const pe = ProviderExecutorV2.init(allocator);
    _ = pe;
}
