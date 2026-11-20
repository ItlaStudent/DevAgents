const std = @import("std");

pub const DiscoveryV2 = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) DiscoveryV2 {
        return .{ .allocator = allocator };
    }
};

test "discovery v2 init" {
    const allocator = std.testing.allocator;
    const d = DiscoveryV2.init(allocator);
    _ = d;
}
