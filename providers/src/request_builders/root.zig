const std = @import("std");

pub const RequestBuilders = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) RequestBuilders {
        return .{ .allocator = allocator };
    }
};

test "request builders init" {
    const allocator = std.testing.allocator;
    const rb = RequestBuilders.init(allocator);
    _ = rb;
}
