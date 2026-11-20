//! E5.33: truthful, injectable containment selection; no provider or owner data.
const std = @import("std");
const builtin = @import("builtin");

pub const Mode = enum { windows_job, linux_cgroup_v2, posix_partial, disabled };
pub const Facts = struct {
    os: std.Target.Os.Tag,
    cgroup2: bool = false,
    delegated: bool = false,
    controllers: bool = false,
    tree_kill: bool = false,
};
pub const Status = struct { mode: Mode, enabled: bool, partial: bool, reason: []const u8 };

pub fn decide(f: Facts) Status {
    if (f.os == .windows) return .{ .mode = .windows_job, .enabled = true, .partial = false, .reason = "Windows Job Object" };
    if (f.os != .linux) return .{ .mode = .disabled, .enabled = false, .partial = false, .reason = "Ejecucion gobernada desactivada hasta verificar contencion en macOS" };
    if (f.cgroup2 and f.delegated and f.controllers and f.tree_kill)
        return .{ .mode = .linux_cgroup_v2, .enabled = true, .partial = false, .reason = "cgroup v2 delegado: memoria y pids agregados, cgroup.kill y vigilante de vida del motor" };
    return .{ .mode = .posix_partial, .enabled = true, .partial = true, .reason = "Contencion parcial: sin delegacion cgroup v2 utilizable; grupo de procesos y setrlimit por proceso (datos y CPU), sin tope de procesos ni limites agregados ni garantia contra setsid" };
}

extern fn beats_containment_probe() c_int;

pub fn current() Status {
    if (builtin.os.tag != .linux) return decide(.{ .os = builtin.os.tag });
    const ready = beats_containment_probe() == 1;
    return decide(.{ .os = .linux, .cgroup2 = ready, .delegated = ready, .controllers = ready, .tree_kill = ready });
}

pub fn json(a: std.mem.Allocator) ![]u8 {
    return std.json.Stringify.valueAlloc(a, current(), .{});
}

test "B10 containment decision requires all delegation guards and disables macOS" {
    const full: Facts = .{ .os = .linux, .cgroup2 = true, .delegated = true, .controllers = true, .tree_kill = true };
    try std.testing.expectEqual(Mode.linux_cgroup_v2, decide(full).mode);
    inline for (.{ "cgroup2", "delegated", "controllers", "tree_kill" }) |field| {
        var broken = full;
        @field(broken, field) = false;
        const s = decide(broken);
        try std.testing.expectEqual(Mode.posix_partial, s.mode);
        try std.testing.expect(s.enabled and s.partial);
    }
    try std.testing.expect(!decide(.{ .os = .macos }).enabled);
    try std.testing.expectEqual(Mode.windows_job, decide(.{ .os = .windows }).mode);
}

test "B10 containment current status and JSON are truthful" {
    const a = std.testing.allocator;
    const text = try json(a);
    defer a.free(text);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, text, .{});
    defer parsed.deinit();
    try std.testing.expectEqualStrings(@tagName(current().mode), parsed.value.object.get("mode").?.string);
    try std.testing.expectEqual(current().enabled, parsed.value.object.get("enabled").?.bool);
}
