//! cmd-shim de npm se resuelve como datos, nunca se interpreta como shell.
const std = @import("std");
const trust = @import("external_cli_policy.zig");
pub const ResolveNode = *const fn (std.mem.Allocator, []const u8) error{ OutOfMemory, ExeNotResolved }![:0]u8;

pub const Launch = struct {
    exe: [:0]u8,
    prefix: [][]const u8,
    shim: ?trust.VerifiedBinary = null,
    node: ?trust.VerifiedBinary = null,
    script: ?trust.VerifiedBinary = null,

    pub fn deinit(self: *Launch, a: std.mem.Allocator) void {
        if (self.script) |*v| v.deinit();
        if (self.node) |*v| v.deinit();
        if (self.shim) |*v| v.deinit();
        for (self.prefix) |s| a.free(s);
        a.free(self.prefix);
        a.free(self.exe);
    }
};

const npm_before =
    "@ECHO off\nGOTO start\n:find_dp0\nSET dp0=%~dp0\nEXIT /b\n:start\nSETLOCAL\nCALL :find_dp0\n\n" ++
    "IF EXIST \"%dp0%\\node.exe\" (\n  SET \"_prog=%dp0%\\node.exe\"\n) ELSE (\n  SET \"_prog=node\"\n  SET PATHEXT=%PATHEXT:;.JS;=;%\n)\n\n" ++
    "endLocal & goto #_undefined_# 2>NUL || title %COMSPEC% & \"%_prog%\"  \"%dp0%\\";
const npm_after = "\" %*\n";

/// Reconocer la plantilla ENTERA evita confundir un batch arbitrario con npm
/// sólo porque contiene una referencia a .js. No se ejecuta ni se evalúa SET.
pub fn npmScript(a: std.mem.Allocator, bytes: []const u8) !?[]u8 {
    var normalized = std.ArrayList(u8).empty;
    defer normalized.deinit(a);
    for (bytes, 0..) |c, i| {
        if (c == '\r' and i + 1 < bytes.len and bytes[i + 1] == '\n') continue;
        try normalized.append(a, c);
    }
    const text = normalized.items;
    if (!std.mem.startsWith(u8, text, npm_before) or !std.mem.endsWith(u8, text, npm_after)) return null;
    if (text.len < npm_before.len + npm_after.len) return null;
    const path = text[npm_before.len .. text.len - npm_after.len];
    if (!std.mem.startsWith(u8, path, "node_modules\\") or !std.ascii.endsWithIgnoreCase(path, ".js")) return null;
    for (path) |c| if (c < 32 or std.mem.indexOfScalar(u8, ":\"&|<>^%!*?", c) != null) return null;
    var parts = std.mem.splitScalar(u8, path, '\\');
    while (parts.next()) |part| if (part.len == 0 or std.mem.eql(u8, part, "..") or std.mem.eql(u8, part, ".")) return null;
    return try a.dupe(u8, path);
}

pub fn prepare(a: std.mem.Allocator, path: []const u8, resolve: ResolveNode) !Launch {
    if (@import("builtin").os.tag != .windows) {
        // Mismo conjunto de errores que en Windows para los llamadores.
        const unavailable: error{ OutOfMemory, ExternalCliUnavailableOnLinux } = error.ExternalCliUnavailableOnLinux;
        return unavailable;
    }
    var shim = try trust.verify(a, path);
    errdefer shim.deinit();
    if (!std.ascii.endsWithIgnoreCase(path, ".cmd") and !std.ascii.endsWithIgnoreCase(path, ".bat")) {
        const exe = try a.dupeZ(u8, shim.path);
        errdefer a.free(exe);
        return .{ .exe = exe, .prefix = try a.alloc([]const u8, 0), .shim = shim };
    }
    const content = try trust.readVerified(a, &shim);
    defer if (content) |bytes| a.free(bytes);
    const relative = if (content) |bytes| try npmScript(a, bytes) else null;
    if (relative == null) {
        const exe = try a.dupeZ(u8, shim.path);
        errdefer a.free(exe);
        return .{ .exe = exe, .prefix = try a.alloc([]const u8, 0), .shim = shim };
    }
    defer a.free(relative.?);
    const dir = std.fs.path.dirnameWindows(shim.path) orelse return error.InvalidBatchShim;
    const js_path = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "{s}", .{ dir, relative.? });
    defer a.free(js_path);
    var script = try trust.verifyScript(a, js_path);
    errdefer script.deinit();
    const nearby = try std.fmt.allocPrint(a, "{s}" ++ std.fs.path.sep_str ++ "node.exe", .{dir});
    defer a.free(nearby);
    // npm prefiere node.exe junto al shim; si está presente pero no es fiable,
    // no sustituirlo silenciosamente por otro node del PATH.
    const api = struct {
        extern "kernel32" fn GetFileAttributesW([*:0]const u16) callconv(.winapi) u32;
    };
    const nearby_w = try std.unicode.utf8ToUtf16LeAllocZ(a, nearby);
    defer a.free(nearby_w);
    const node_path = if (api.GetFileAttributesW(nearby_w) != 0xffffffff) try a.dupeZ(u8, nearby) else try resolve(a, "node");
    defer a.free(node_path);
    // T2d-D3: el `node` del PATH puede ser el enlace de nvm-windows.
    var node = try trust.verifyFollowingLink(a, node_path);
    errdefer node.deinit();
    const exe = try a.dupeZ(u8, node.path);
    errdefer a.free(exe);
    const prefix = try a.alloc([]const u8, 1);
    errdefer a.free(prefix);
    prefix[0] = try a.dupe(u8, script.path);
    return .{ .exe = exe, .prefix = prefix, .shim = shim, .node = node, .script = script };
}

test "SEC2 npm resolver recognizes full template and rejects injected shim" {
    const a = std.testing.allocator;
    const fixture = npm_before ++ "node_modules\\@google\\gemini-cli\\bundle\\gemini.js" ++ npm_after;
    const script = (try npmScript(a, fixture)).?;
    defer a.free(script);
    try std.testing.expectEqualStrings("node_modules\\@google\\gemini-cli\\bundle\\gemini.js", script);
    try std.testing.expect((try npmScript(a, fixture ++ "echo injected\n")) == null);
    try std.testing.expect((try npmScript(a, npm_before ++ "node_modules\\..\\evil.js" ++ npm_after)) == null);
    try std.testing.expect((try npmScript(a, "@echo off\nnode x.js %*\n")) == null);
}
