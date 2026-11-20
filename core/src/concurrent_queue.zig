const std = @import("std");
const sync = @import("sync.zig");

pub fn ConcurrentQueue(comptime T: type) type {
    return struct {
        const Self = @This();

        allocator: std.mem.Allocator,
        buf: std.ArrayList(T),
        mutex: sync.Mutex,

        pub fn init(allocator: std.mem.Allocator) Self {
            return .{
                .allocator = allocator,
                .buf = std.ArrayList(T).empty,
                .mutex = sync.Mutex.init(),
            };
        }

        pub fn deinit(self: *Self) void {
            self.buf.deinit(self.allocator);
        }

        pub fn push(self: *Self, item: T) !void {
            self.mutex.lock();
            defer self.mutex.unlock();
            try self.buf.append(self.allocator, item);
        }

        pub fn pop(self: *Self) ?T {
            self.mutex.lock();
            defer self.mutex.unlock();
            if (self.buf.items.len == 0) return null;
            return self.buf.orderedRemove(0);
        }

        pub fn len(self: *Self) usize {
            self.mutex.lock();
            defer self.mutex.unlock();
            return self.buf.items.len;
        }
    };
}

test "concurrent queue push and pop" {
    const allocator = std.testing.allocator;
    var queue = ConcurrentQueue(u32).init(allocator);
    defer queue.deinit();

    try queue.push(42);
    try queue.push(17);
    try std.testing.expectEqual(@as(usize, 2), queue.len());

    try std.testing.expectEqual(@as(u32, 42), queue.pop().?);
    try std.testing.expectEqual(@as(u32, 17), queue.pop().?);
    try std.testing.expect(queue.pop() == null);
    try std.testing.expectEqual(@as(usize, 0), queue.len());
}

test "concurrent queue empty pop" {
    const allocator = std.testing.allocator;
    var queue = ConcurrentQueue(u32).init(allocator);
    defer queue.deinit();
    try std.testing.expect(queue.pop() == null);
}
