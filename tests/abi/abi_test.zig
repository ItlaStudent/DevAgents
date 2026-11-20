const std = @import("std");
const c = @cImport({
    @cInclude("da_plugin.h");
});

test "ABI version string is non-empty" {
    const v = c.da_version_string();
    const s = std.mem.span(v);
    try std.testing.expect(s.len > 0);
}

test "ABI plugin info returns OK" {
    var info: c.da_plugin_info_t = undefined;
    const rc = c.da_plugin_get_info(&info);
    try std.testing.expectEqual(@as(c_uint, c.DA_OK), rc);
    try std.testing.expectEqual(@as(c_uint, c.DA_ABI_VERSION), info.abi_version);
    try std.testing.expect(info.name != null);
}

test "ABI plugin info rejects null" {
    const rc = c.da_plugin_get_info(null);
    try std.testing.expectEqual(@as(c_uint, c.DA_ERR_INVALID), rc);
}
