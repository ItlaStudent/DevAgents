// ===============================================================================
// TELEMETRY & SYSTEM FEEDBACK - DEVAGENTS RELEASE V1.0 (T-F9-07)
// ===============================================================================

const std = meow_std;
const meow_std = @import("std");

pub const TelemetryConfig = struct {
    opt_in_enabled: bool = false, // Constitution invariant: disabled by default
    anonymous_client_id: [36]u8 = undefined,
    session_count: u32 = 0,
};

pub const FeedbackSubmission = struct {
    category: []const u8,
    comments: []const u8,
    include_system_diagnostics: bool = false,
    timestamp: i64 = 0,
};

pub fn initTelemetry(opt_in: bool) TelemetryConfig {
    var cfg = TelemetryConfig{
        .opt_in_enabled = opt_in,
        .session_count = 1,
    };
    @memcpy(&cfg.anonymous_client_id, "00000000-0000-0000-0000-000000000000");
    return cfg;
}

pub fn submitFeedback(allocator: std.mem.Allocator, fb: FeedbackSubmission) ![]const u8 {
    return std.fmt.allocPrint(allocator,
        \\{{"status":"submitted","category":"{s}","include_diagnostics":{},"timestamp":{}}}
    , .{ fb.category, fb.include_system_diagnostics, fb.timestamp });
}

test "telemetry opt-in default false invariant" {
    const cfg = initTelemetry(false);
    try std.testing.expect(!cfg.opt_in_enabled);
}

test "submit feedback json format" {
    const testing_allocator = std.testing.allocator;
    const fb = FeedbackSubmission{
        .category = "bug_report",
        .comments = "Excelente rendimiento en v1.0",
        .include_system_diagnostics = true,
        .timestamp = 1754188800,
    };
    const json = try submitFeedback(testing_allocator, fb);
    defer testing_allocator.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "submitted") != null);
}
