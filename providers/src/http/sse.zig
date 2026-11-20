const std = @import("std");

/// Errores de parsing SSE.
pub const SseError = error{
    InvalidEvent,
    OutOfMemory,
    LineTooLong,
    EventTooLarge,
    StreamTooLarge,
};

/// Límites por defecto para prevenir agotamiento de memoria.
pub const MAX_LINE_LEN: usize = 64 * 1024; // 64 KB por línea
pub const MAX_EVENT_BYTES: usize = 1024 * 1024; // 1 MB por evento
pub const MAX_STREAM_BYTES: usize = 16 * 1024 * 1024; // 16 MB total del stream

/// Un evento SSE (Server-Sent Events).
pub const SseEvent = struct {
    allocator: std.mem.Allocator,
    event: []const u8,
    data: []const u8,
    id: ?[]const u8,

    pub fn deinit(self: *SseEvent) void {
        self.allocator.free(self.event);
        self.allocator.free(self.data);
        if (self.id) |id| self.allocator.free(id);
    }
};

/// Parser de streaming SSE.
/// Lee líneas de un reader y emite eventos.
pub const SseStream = struct {
    allocator: std.mem.Allocator,
    reader: *std.Io.Reader,
    buffer: []u8,
    buffer_len: usize,
    max_line_len: usize,
    max_event_bytes: usize,
    max_stream_bytes: usize,
    stream_total: usize,

    pub const INIT_BUFFER_SIZE = 4096;

    pub fn init(allocator: std.mem.Allocator, reader: *std.Io.Reader) !SseStream {
        const buffer = try allocator.alloc(u8, INIT_BUFFER_SIZE);
        return .{
            .allocator = allocator,
            .reader = reader,
            .buffer = buffer,
            .buffer_len = 0,
            .max_line_len = MAX_LINE_LEN,
            .max_event_bytes = MAX_EVENT_BYTES,
            .max_stream_bytes = MAX_STREAM_BYTES,
            .stream_total = 0,
        };
    }

    pub fn deinit(self: *SseStream) void {
        self.allocator.free(self.buffer);
    }

    /// Lee el siguiente evento SSE del stream.
    /// Retorna null si el stream terminó.
    pub fn nextEvent(self: *SseStream) SseError!?SseEvent {
        var event_type: ?[]const u8 = null;
        var data_lines = std.ArrayList(u8).empty;
        defer data_lines.deinit(self.allocator);
        var id_copy: ?[]const u8 = null;
        errdefer if (id_copy) |i| self.allocator.free(i);
        errdefer if (event_type) |e| self.allocator.free(e);
        var event_total: usize = 0;

        while (true) {
            const line = self.readLine() catch |err| switch (err) {
                error.ReadFailed => return null,
                error.OutOfMemory => return error.OutOfMemory,
                error.LineTooLong => return error.LineTooLong,
                error.StreamTooLarge => return error.StreamTooLarge,
                else => return null,
            } orelse return null;
            defer self.allocator.free(line);

            event_total += line.len;
            if (event_total > self.max_event_bytes) return error.EventTooLarge;

            if (line.len == 0) {
                // Empty line = end of event
                if (data_lines.items.len > 0) {
                    const data = try data_lines.toOwnedSlice(self.allocator);
                    const et = event_type orelse "message";
                    const event_copy = try self.allocator.dupe(u8, et);
                    errdefer self.allocator.free(event_copy);
                    if (event_type) |e| self.allocator.free(e);
                    return .{
                        .allocator = self.allocator,
                        .event = event_copy,
                        .data = data,
                        .id = id_copy,
                    };
                }
                // Otherwise continue reading (heartbeats/empty events)
                continue;
            }

            if (std.mem.startsWith(u8, line, "data:")) {
                const value = std.mem.trimStart(u8, line["data:".len..], " ");
                if (data_lines.items.len > 0) {
                    try data_lines.append(self.allocator, '\n');
                }
                try data_lines.appendSlice(self.allocator, value);
            } else if (std.mem.startsWith(u8, line, "event:")) {
                const value = std.mem.trimStart(u8, line["event:".len..], " ");
                if (event_type) |e| self.allocator.free(e);
                event_type = try self.allocator.dupe(u8, value);
            } else if (std.mem.startsWith(u8, line, "id:")) {
                const value = std.mem.trimStart(u8, line["id:".len..], " ");
                if (id_copy) |i| self.allocator.free(i);
                id_copy = try self.allocator.dupe(u8, value);
            } else if (std.mem.startsWith(u8, line, ":")) {
                // Comment/heartbeat, ignore
            }
        }
    }

    fn readLine(self: *SseStream) (error{ ReadFailed, OutOfMemory, LineTooLong, StreamTooLarge } || std.Io.Reader.Error)!?[]u8 {
        // takeDelimiter handles internal buffering: it reads chunks internally
        // and returns the next line including the '\n' delimiter, or null on EOF.
        // This correctly handles multi-line chunks without losing data.
        const maybe = self.reader.takeDelimiter('\n') catch |err| switch (err) {
            error.ReadFailed => return error.ReadFailed,
            error.StreamTooLong => return error.LineTooLong,
            else => |e| return e,
        };
        const raw = maybe orelse return null; // EOF
        self.stream_total += raw.len;
        if (self.stream_total > self.max_stream_bytes) return error.StreamTooLarge;
        // Strip trailing \n and \r
        var line = raw;
        if (line.len > 0 and line[line.len - 1] == '\n') line = line[0 .. line.len - 1];
        if (line.len > 0 and line[line.len - 1] == '\r') line = line[0 .. line.len - 1];
        if (line.len > self.max_line_len) return error.LineTooLong;
        return self.allocator.dupe(u8, line) catch return error.OutOfMemory;
    }
};

// ── Tests ──────────────────────────────────────────────────────────────

test "sse parse simple data event" {
    const allocator = std.testing.allocator;
    var reader: std.Io.Reader = .fixed("data: hello world\n\n");
    var stream = try SseStream.init(allocator, &reader);
    defer stream.deinit();
    var event = (try stream.nextEvent()) orelse return error.TestFailed;
    defer event.deinit();
    try std.testing.expectEqualStrings("message", event.event);
    try std.testing.expectEqualStrings("hello world", event.data);
    try std.testing.expect(event.id == null);
}

test "sse parse custom event type" {
    const allocator = std.testing.allocator;
    var reader: std.Io.Reader = .fixed("event: update\ndata: new data\n\n");
    var stream = try SseStream.init(allocator, &reader);
    defer stream.deinit();
    var event = (try stream.nextEvent()) orelse return error.TestFailed;
    defer event.deinit();
    try std.testing.expectEqualStrings("update", event.event);
    try std.testing.expectEqualStrings("new data", event.data);
}

test "sse parse event with id" {
    const allocator = std.testing.allocator;
    var reader: std.Io.Reader = .fixed("id: 42\ndata: hello\n\n");
    var stream = try SseStream.init(allocator, &reader);
    defer stream.deinit();
    var event = (try stream.nextEvent()) orelse return error.TestFailed;
    defer event.deinit();
    try std.testing.expectEqualStrings("message", event.event);
    try std.testing.expectEqualStrings("hello", event.data);
    try std.testing.expect(event.id != null);
    if (event.id) |id| try std.testing.expectEqualStrings("42", id);
}

test "sse parse multiple events" {
    const allocator = std.testing.allocator;
    var reader: std.Io.Reader = .fixed("data: first\n\n" ++ "data: second\n\n" ++ "data: third\n\n");
    var stream = try SseStream.init(allocator, &reader);
    defer stream.deinit();
    {
        var event = (try stream.nextEvent()) orelse return error.TestFailed;
        defer event.deinit();
        try std.testing.expectEqualStrings("first", event.data);
    }
    {
        var event = (try stream.nextEvent()) orelse return error.TestFailed;
        defer event.deinit();
        try std.testing.expectEqualStrings("second", event.data);
    }
    {
        var event = (try stream.nextEvent()) orelse return error.TestFailed;
        defer event.deinit();
        try std.testing.expectEqualStrings("third", event.data);
    }
    try std.testing.expect((try stream.nextEvent()) == null);
}

test "sse parse ignores comments" {
    const allocator = std.testing.allocator;
    var reader: std.Io.Reader = .fixed(": heartbeat comment\ndata: real\n\n");
    var stream = try SseStream.init(allocator, &reader);
    defer stream.deinit();
    var event = (try stream.nextEvent()) orelse return error.TestFailed;
    defer event.deinit();
    try std.testing.expectEqualStrings("real", event.data);
}

test "sse parse multiline data" {
    const allocator = std.testing.allocator;
    var reader: std.Io.Reader = .fixed("data: line1\ndata: line2\ndata: line3\n\n");
    var stream = try SseStream.init(allocator, &reader);
    defer stream.deinit();
    var event = (try stream.nextEvent()) orelse return error.TestFailed;
    defer event.deinit();
    try std.testing.expectEqualStrings("line1\nline2\nline3", event.data);
}

test "sse parse empty event" {
    const allocator = std.testing.allocator;
    var reader: std.Io.Reader = .fixed("\n");
    var stream = try SseStream.init(allocator, &reader);
    defer stream.deinit();
    try std.testing.expect((try stream.nextEvent()) == null);
}

test "sse parse trailing whitespace in data" {
    const allocator = std.testing.allocator;
    var reader: std.Io.Reader = .fixed("data:   hello   \n\n");
    var stream = try SseStream.init(allocator, &reader);
    defer stream.deinit();
    var event = (try stream.nextEvent()) orelse return error.TestFailed;
    defer event.deinit();
    try std.testing.expectEqualStrings("hello   ", event.data);
}

test "sse parse crlf line endings" {
    const allocator = std.testing.allocator;
    var reader: std.Io.Reader = .fixed("data: hello\r\n\r\n");
    var stream = try SseStream.init(allocator, &reader);
    defer stream.deinit();
    var event = (try stream.nextEvent()) orelse return error.TestFailed;
    defer event.deinit();
    try std.testing.expectEqualStrings("hello", event.data);
}

test "sse parse event with id update" {
    const allocator = std.testing.allocator;
    var reader: std.Io.Reader = .fixed("id: 1\ndata: first\n\n" ++ "id: 2\ndata: second\n\n");
    var stream = try SseStream.init(allocator, &reader);
    defer stream.deinit();
    {
        var event = (try stream.nextEvent()) orelse return error.TestFailed;
        defer event.deinit();
        if (event.id) |id| try std.testing.expectEqualStrings("1", id);
    }
    {
        var event = (try stream.nextEvent()) orelse return error.TestFailed;
        defer event.deinit();
        if (event.id) |id| try std.testing.expectEqualStrings("2", id);
    }
}

test "sse rejects oversized event" {
    const allocator = std.testing.allocator;
    // Build an event with data exceeding max_event_bytes (set to 64 for test).
    const big_data = "X" ** 200;
    var reader: std.Io.Reader = .fixed(big_data);
    var stream = try SseStream.init(allocator, &reader);
    defer stream.deinit();
    stream.max_event_bytes = 64;
    // This is a single line without newline → readLine returns it at EOF,
    // then nextEvent checks event_total > max_event_bytes.
    const result = stream.nextEvent();
    // Should either return null (no data: prefix) or error.EventTooLarge.
    // Since the data has no "data:" prefix, it's ignored as unknown line,
    // and nextEvent returns null at EOF. Let's test with proper SSE format.
    _ = result catch {};

    // Proper test: data line with oversized payload.
    var reader2: std.Io.Reader = .fixed("data: " ++ "X" ** 200 ++ "\n\n");
    var stream2 = try SseStream.init(allocator, &reader2);
    defer stream2.deinit();
    stream2.max_event_bytes = 64;
    try std.testing.expectError(error.EventTooLarge, stream2.nextEvent());
}

test "sse line without newline returns at EOF" {
    const allocator = std.testing.allocator;
    // Data without trailing newline — should still be parsed at EOF.
    var reader: std.Io.Reader = .fixed("data: no-newline-at-end");
    var stream = try SseStream.init(allocator, &reader);
    defer stream.deinit();
    // nextEvent reads the line at EOF, but there's no empty line to delimit
    // the event, so it returns null (no complete event).
    // This is correct SSE behavior: an event is only complete after a blank line.
    const result = try stream.nextEvent();
    try std.testing.expect(result == null);
}

test "sse rejects malicious oversized stream" {
    const allocator = std.testing.allocator;
    // Create a stream that exceeds max_stream_bytes.
    // Each event is small but there are many of them.
    var stream_data: [4096]u8 = undefined;
    // Fill with "data: x\n\n" repeated (9 bytes per event).
    const event_pattern = "data: x\n\n";
    var i: usize = 0;
    while (i + event_pattern.len <= stream_data.len) : (i += event_pattern.len) {
        @memcpy(stream_data[i..][0..event_pattern.len], event_pattern);
    }
    var reader: std.Io.Reader = .fixed(stream_data[0..i]);
    var stream = try SseStream.init(allocator, &reader);
    defer stream.deinit();
    stream.max_stream_bytes = 50; // tiny limit
    // Read events until we hit StreamTooLarge.
    var hit_error = false;
    while (true) {
        const ev = stream.nextEvent() catch |err| switch (err) {
            error.StreamTooLarge => {
                hit_error = true;
                break;
            },
            else => break,
        };
        if (ev) |ev_val| {
            var e = ev_val;
            e.deinit();
        } else break;
    }
    try std.testing.expect(hit_error);
}
