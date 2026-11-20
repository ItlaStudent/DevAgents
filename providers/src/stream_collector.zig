const std = @import("std");

pub const StreamCollector = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) StreamCollector {
        return .{ .allocator = allocator };
    }
};

test "stream collector init" {
    const allocator = std.testing.allocator;
    const sc = StreamCollector.init(allocator);
    _ = sc;
}
