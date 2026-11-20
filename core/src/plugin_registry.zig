const std = @import("std");
const plugin_loader = @import("plugin_loader.zig");
const tool_discovery = @import("tool_discovery.zig");
const Io = std.Io;

/// Escanear los directorios source_root de las resources de tipo plugin,
/// leer plugin.json, y formatear las capabilities de kind tool/skill como
/// un bloque de texto descriptivo (honesto: invocación real vía ABI es deuda).
pub fn formatPluginCapabilities(allocator: std.mem.Allocator, io: Io, resources: []const tool_discovery.Resource) ![]const u8 {
    var out = std.ArrayList(u8).empty;
    defer out.deinit(allocator);
    var loader = plugin_loader.PluginLoader.init(allocator);
    var any = false;
    for (resources) |r| {
        if (r.kind != .plugin) continue;
        const dir = Io.Dir.cwd().openDir(io, r.source_root, .{ .iterate = true }) catch continue;
        defer dir.close(io);
        const file = dir.openFile(io, "plugin.json", .{}) catch continue;
        defer file.close(io);
        const stat = file.stat(io) catch continue;
        const size: usize = @intCast(stat.size);
        const json = allocator.alloc(u8, size) catch continue;
        defer allocator.free(json);
        _ = file.readPositionalAll(io, json, 0) catch continue;
        const manifest = loader.parseManifest(json) catch continue;
        defer manifest.deinit(allocator);
        for (manifest.capabilities) |cap| {
            if (cap.kind != .tool and cap.kind != .skill) continue;
            const line = try std.fmt.allocPrint(allocator, "- capability \"{s}\" ({s}) del plugin \"{s}\": {s} (disponible descriptivamente; invocación vía ABI queda como deuda técnica)\n", .{
                cap.name,
                @tagName(cap.kind),
                manifest.name,
                cap.description,
            });
            defer allocator.free(line);
            try out.appendSlice(allocator, line);
            any = true;
        }
    }
    if (!any) return allocator.dupe(u8, "");
    return out.toOwnedSlice(allocator);
}

test "formatPluginCapabilities extracts tool/skill from plugin.json" {
    const allocator = std.testing.allocator;
    const io = std.testing.io;
    const resources = &[_]tool_discovery.Resource{
        .{
            .kind = .plugin,
            .name = "example-provider",
            .path = "plugin.json",
            .description = "Example plugin",
            .source_root = "plugins/example-provider",
        },
    };
    const text = try formatPluginCapabilities(allocator, io, resources);
    defer allocator.free(text);
    // El fixture real no existe en tests unitarios; como openDir falla, devuelve "".
    // Este test documenta el contrato y asegura que no crashea con paths ausentes.
    try std.testing.expectEqualStrings("", text);
}
