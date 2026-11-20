const std = @import("std");
const connector = @import("../connector.zig");

/// https://ai.google.dev/api/generate-content (Part.inlineData, Blob).
pub fn writeImagePart(js: *std.json.Stringify, image: connector.ImagePart) !void {
    try image.validate();
    try js.beginObject();
    try js.objectField("inlineData");
    try js.beginObject();
    try js.objectField("mimeType");
    try js.write(image.mime_type);
    try js.objectField("data");
    try js.write(image.base64);
    try js.endObject();
    try js.endObject();
}

pub const GeminiV2Parser = struct {
    allocator: std.mem.Allocator,

    pub fn init(allocator: std.mem.Allocator) GeminiV2Parser {
        return .{ .allocator = allocator };
    }

    pub fn parseChunk(self: GeminiV2Parser, chunk: []const u8) !?[]const u8 {
        _ = self;
        if (chunk.len == 0) return null;
        return chunk;
    }
};

test "gemini v2 parser" {
    const allocator = std.testing.allocator;
    const parser = GeminiV2Parser.init(allocator);
    const result = try parser.parseChunk("data: {\"candidates\":[]}");
    try std.testing.expect(result != null);
}

test "E5.24 gemini image part wire contract and validation writer errors" {
    const a = std.testing.allocator;
    var out: std.Io.Writer.Allocating = .init(a);
    defer out.deinit();
    var js: std.json.Stringify = .{ .writer = &out.writer, .options = .{} };
    try writeImagePart(&js, .{ .mime_type = "image/png", .base64 = "YWJj" });
    var parsed = try std.json.parseFromSlice(std.json.Value, a, out.written(), .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.contains("inlineData"));
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
