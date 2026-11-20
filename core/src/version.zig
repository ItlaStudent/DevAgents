//! build identity shared with the native host and packaged WebUI.
const build = @import("build_version");
pub const identity: [:0]const u8 = build.identity ++ "";
pub const abi_protocol: u32 = 1;
pub const webui_protocol: u32 = 1;

test "CK-COMP-004: C ABI publishes the build identity without initialization" {
    const std = @import("std");
    try std.testing.expectEqualStrings(identity, std.mem.span(@import("c_api.zig").da_build_identity_v1()));
    try std.testing.expect(std.mem.indexOf(u8, identity, "/abi1.bus1.ui1") != null);
    try std.testing.expectEqual(@as(u16, 1), @import("bus/protocol.zig").PROTOCOL_VERSION);
}
