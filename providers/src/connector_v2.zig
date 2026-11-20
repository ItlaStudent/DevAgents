const std = @import("std");

pub const WireProtocol = enum {
    openai_compatible,
    anthropic_v1,
    anthropic,
    gemini_v1beta,
    gemini,
};

pub const ToolDefinition = struct {
    name: []const u8 = "",
    description: []const u8 = "",
    parameters_json: []const u8 = "",
};

pub const ErrorKind = enum {
    auth,
    quota,
    rate_limited,
    model_not_found,
    provider_error,
    parse_error,
    timeout,
    network,
    invalid_request,
    cancelled,
    other,
};
