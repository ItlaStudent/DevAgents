//! Suite-wide barrier: external agents may execute only test doubles.
const std = @import("std");
const platform = @import("platform.zig");

fn env(a: std.mem.Allocator, name: [:0]const u8) !?[]u8 {
    var buf: [32768]u8 = undefined;
    const n = platform.env(name, &buf, buf.len);
    if (n == 0) return null;
    if (n >= buf.len) return error.TestCliEnvironmentTooLarge;
    return try a.dupe(u8, buf[0..n]);
}

pub fn enabled() bool {
    var buf: [8]u8 = undefined;
    return platform.env("DEVAGENTS_TEST_REAL_CLI_FORBIDDEN", &buf, buf.len) != 0;
}

pub fn check(a: std.mem.Allocator, path: []const u8) !void {
    if (!enabled()) return;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const resolved = std.Io.Dir.cwd().realPathFileAlloc(io, path, a) catch return error.TestRealCliForbidden;
    defer a.free(resolved);
    for ([_][:0]const u8{ "BEATS_TEST_BIN_DIR", "DEVAGENTS_TEST_FIXTURE_DIR", "DEVAGENTS_TEST_PROFILE_DIR" }) |key| {
        const value = try env(a, key) orelse continue;
        defer a.free(value);
        const root = std.Io.Dir.cwd().realPathFileAlloc(io, value, a) catch continue;
        defer a.free(root);
        if (under(resolved, root)) return;
    }
    return error.TestRealCliForbidden;
}

fn under(path: []const u8, root: []const u8) bool {
    if (path.len <= root.len) return false;
    const equal = if (@import("builtin").os.tag == .windows) std.ascii.eqlIgnoreCase(path[0..root.len], root) else std.mem.eql(u8, path[0..root.len], root);
    return equal and (path[root.len] == '/' or path[root.len] == '\\');
}

pub fn checkArgv(a: std.mem.Allocator, argv: []const []const u8) !void {
    if (!enabled()) return;
    if (argv.len == 0) return error.TestRealCliForbidden;
    const base = std.fs.path.basename(argv[0]);
    // Interpreter binaries are infrastructure; the CLI script is the double.
    if (std.ascii.eqlIgnoreCase(base, "cmd.exe")) {
        if (argv.len < 4 or !std.ascii.eqlIgnoreCase(argv[1], "/d")) return error.TestRealCliForbidden;
        const c: usize = if (std.ascii.eqlIgnoreCase(argv[2], "/s")) 3 else 2;
        if (argv.len <= c + 1 or !std.ascii.eqlIgnoreCase(argv[c], "/c")) return error.TestRealCliForbidden;
        return check(a, argv[c + 1]);
    }
    if (argv.len >= 2 and (std.ascii.eqlIgnoreCase(base, "node.exe") or std.mem.eql(u8, base, "node")) and !std.mem.startsWith(u8, argv[1], "-"))
        return check(a, argv[1]);
    try check(a, argv[0]);
}
