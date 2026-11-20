const std = @import("std");

/// Wrapper sobre std.atomic.Mutex que provee lock() con spinloop.
/// En Zig 0.16.0, std.atomic.Mutex solo tiene tryLock/unlock.
pub const Mutex = struct {
    inner: std.atomic.Mutex,

    pub fn init() Mutex {
        return .{ .inner = .unlocked };
    }

    pub fn lock(self: *Mutex) void {
        while (!self.inner.tryLock()) {
            std.atomic.spinLoopHint();
        }
    }

    pub fn unlock(self: *Mutex) void {
        self.inner.unlock();
    }

    pub fn tryLock(self: *Mutex) bool {
        return self.inner.tryLock();
    }
};
