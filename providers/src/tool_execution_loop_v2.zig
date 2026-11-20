const std = @import("std");

pub const ToolExecutorFn = *const fn (?*anyopaque, []const u8, []const u8) anyerror![]const u8;
