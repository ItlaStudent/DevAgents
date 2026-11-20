const std = @import("std");

pub const HealthStatus = enum {
    ok,
    empty,
    auth_failed,
    quota,
    rate_limited,
    not_found,
    err,
};
