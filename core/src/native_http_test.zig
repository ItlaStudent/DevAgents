const std = @import("std");
const bridge = @import("connector_v2_bridge.zig");
const governed = @import("governed_tool_executor.zig");
const providers = @import("providers");

const allocator = std.testing.allocator;

const tools = [_]providers.connector_v2.ToolDefinition{.{
    .name = "run_command",
    .description = "Run a governed local command",
    .parameters_json = "{\"type\":\"object\",\"properties\":{\"exe\":{\"type\":\"string\"},\"args\":{\"type\":\"array\",\"items\":{\"type\":\"string\"}},\"cwd\":{\"type\":\"string\"}},\"required\":[\"exe\"]}",
}};

const GetEnvironmentVariableA = @import("platform.zig").env;
fn fixtureUrl() ![]u8 {
    var buffer: [512]u8 = undefined;
    const len = GetEnvironmentVariableA("DEVAGENTS_NATIVE_TEST_URL", &buffer, buffer.len);
    if (len == 0) return error.MissingFixtureUrl;
    if (len >= buffer.len or !std.mem.startsWith(u8, buffer[0..len], "http://127.0.0.1:")) return error.InvalidFixtureUrl;
    return allocator.dupe(u8, buffer[0..len]);
}

test "native HTTP bridge executes governed tool and submits its actual result for OpenAI Anthropic and Gemini" {
    const Human = struct {
        fn approve(ctx: ?*anyopaque, exe: []const u8, args: []const []const u8, cwd: []const u8) !bool {
            const count: *usize = @ptrCast(@alignCast(ctx.?));
            // La fixture propone código en línea: el plan no sustituye esta decisión.
            try std.testing.expectEqualStrings("python", exe);
            try std.testing.expectEqual(@as(usize, 2), args.len);
            try std.testing.expectEqualStrings("-c", args[0]);
            try std.testing.expectEqualStrings("print('native-proof')", args[1]);
            try std.testing.expectEqualStrings(".", cwd);
            count.* += 1;
            return true;
        }
    };
    const base_url = try fixtureUrl();
    defer allocator.free(base_url);

    for ([_]providers.connector_v2.WireProtocol{ .openai_compatible, .anthropic_v1, .gemini_v1beta }) |protocol| {
        var http = try providers.http_client.HttpClient.init(allocator);
        defer http.deinit();

        var attempt = providers.transport_v2.HttpAttemptCtx{
            .allocator = allocator,
            .http = &http,
            .base_url = base_url,
            .api_key = "fake-native-key",
            .model_id = "native-fixture",
            .protocol = protocol,
        };
        defer attempt.deinit();

        var approval_count: usize = 0;
        var tool = governed.GovernedToolExecutor{
            .policy = .{ .workspace_root = "." },
            .permission_config = .{ .mode = .bypass },
            .plan_approved = true,
            .approve_command_fn = Human.approve,
            .approve_command_ctx = &approval_count,
            .allocator = allocator,
        };
        defer if (tool.response) |response| allocator.free(response);

        const outcome = try bridge.callWithTools(allocator, .{
            .protocol = protocol,
            .model = "native-fixture",
            .system_prompt = "Return only the fixture result.",
            .user_prompt = "Use run_command once, then verify the result.",
            .tools = &tools,
            .max_rounds = 2,
            .set_request_fn = providers.transport_v2.HttpAttemptCtx.setRequest,
            .attempt_fn = providers.transport_v2.attemptFn,
            .attempt_ctx = &attempt,
            .tool_executor_fn = governed.GovernedToolExecutor.execute,
            .tool_executor_ctx = &tool,
        });
        switch (outcome) {
            .completed => |response| {
                defer response.deinit(allocator);
                try std.testing.expectEqualStrings("verified", response.content);
                try std.testing.expectEqual(@as(usize, 1), approval_count);
                const actual = try std.json.parseFromSlice(struct {
                    exit_code: u32,
                    stdout: []const u8,
                    stderr: []const u8,
                    timed_out: bool,
                }, allocator, tool.response orelse return error.MissingToolResult, .{});
                defer actual.deinit();
                try std.testing.expectEqual(@as(u32, 0), actual.value.exit_code);
                try std.testing.expect(std.mem.eql(u8, actual.value.stdout, "native-proof\n") or
                    std.mem.eql(u8, actual.value.stdout, "native-proof\r\n"));
                try std.testing.expectEqualStrings("", actual.value.stderr);
                try std.testing.expect(!actual.value.timed_out);
                std.debug.print("native protocol {s}: HTTP -> Python -> actual stdout -> verified\n", .{@tagName(protocol)});
            },
            .exhausted => |reason| {
                defer allocator.free(reason);
                std.debug.print("native protocol {s} failed: {s}\n", .{ @tagName(protocol), reason });
                try std.testing.expect(false);
            },
            .awaiting_paid_approval, .cancelled => try std.testing.expect(false),
        }
    }
}
