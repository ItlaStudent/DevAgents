const std = @import("std");

const DA_VERSION_MAJOR = 0;
const DA_VERSION_MINOR = 1;
const DA_VERSION_PATCH = 0;
const DA_ABI_VERSION = 1;

const DA_OK: i32 = 0;
const DA_ERR_INVALID: i32 = 1;
const DA_ERR_OOM: i32 = 2;

const DA_CAP_PROVIDER: u32 = 1;

const DaCapability = extern struct {
    kind: u32,
    name: [*:0]const u8,
    description: [*:0]const u8,
};

const DaPluginInfo = extern struct {
    size: usize,
    abi_version: u32,
    name: [*:0]const u8,
    version: [*:0]const u8,
    capability_count: usize,
    capabilities: [*]const DaCapability,
};

export fn da_version_string() [*:0]const u8 {
    return "0.1.0";
}

var caps = [1]DaCapability{
    .{
        .kind = DA_CAP_PROVIDER,
        .name = "ExampleProv",
        .description = "Example LLM provider with mock base URL",
    },
};

export fn da_plugin_get_info(out_info: *DaPluginInfo) i32 {
    if (@intFromPtr(out_info) == 0) return DA_ERR_INVALID;
    out_info.size = @sizeOf(DaPluginInfo);
    out_info.abi_version = DA_ABI_VERSION;
    out_info.name = "example-provider";
    out_info.version = "1.0.0";
    out_info.capability_count = caps.len;
    out_info.capabilities = &caps;
    return DA_OK;
}
