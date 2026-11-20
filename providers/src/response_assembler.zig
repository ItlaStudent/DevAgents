const std = @import("std");

pub const ResponseAssembler = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) ResponseAssembler {
        return .{ .allocator = allocator };
    }
};

test "response assembler init" {
    const allocator = std.testing.allocator;
    const ra = ResponseAssembler.init(allocator);
    _ = ra;
}
