const std = @import("std");
const connector = @import("../connector.zig");

/// https://developers.openai.com/api/docs/guides/images-vision (Chat Completions).
pub fn writeImagePart(js: *std.json.Stringify, image: connector.ImagePart) !void {
    try image.validate();
    try js.beginObject();
    try js.objectField("type");
    try js.write("image_url");
    try js.objectField("image_url");
    try js.beginObject();
    try js.objectField("url");
    try js.beginWriteRaw();
    try js.writer.print("\"data:{s};base64,{s}\"", .{ image.mime_type, image.base64 });
    js.endWriteRaw();
    try js.endObject();
    try js.endObject();
}

pub const OpenAIV2Parser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) OpenAIV2Parser {
        return .{ .allocator = allocator };
    }

    pub fn parseChunk(self: OpenAIV2Parser, chunk: []const u8) !?[]const u8 {
        _ = self;
        if (chunk.len == 0) return null;
        return chunk;
    }
};

test "openai v2 parser" {
    const allocator = std.testing.allocator;
    const parser = OpenAIV2Parser.init(allocator);
    const result = try parser.parseChunk("data: {\"choices\":[]}");
    try std.testing.expect(result != null);
}

test "E5.24 openai image part wire contract and validation writer errors" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try writeImagePart(&js, .{ .mime_type = "image/png", .base64 = "YWJj" });
    var parsed = try std.json.parseFromSlice(std.json.Value, a, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.contains("image_url"));
    try std.testing.expect(std.mem.indexOf(u8, out.written(), "YWJj") != null);
    var invalid: std.Io.Writer.Allocating = .init(a);
    defer invalid.deinit();
    var invalid_js: std.json.Stringify = .{ .writer = &invalid.writer, .options = .{} };
    try std.testing.expectError(error.InvalidImagePart, writeImagePart(&invalid_js, .{ .mime_type = "text/plain", .base64 = "YWJj" }));
    var bytes: [1]u8 = undefined;
    var fixed = std.Io.Writer.fixed(&bytes);
    var short_js: std.json.Stringify = .{ .writer = &fixed, .options = .{} };
    try std.testing.expectError(error.WriteFailed, writeImagePart(&short_js, .{ .mime_type = "image/png", .base64 = "YWJj" }));
}
