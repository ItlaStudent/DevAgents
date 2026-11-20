//! E5.23: input validation and immutable, bounded image attachments.
const std = @import("std");
const db = @import("db.zig");

pub const MAX_BYTES = 5 * 1024 * 1024;
pub const MAX_COUNT = 4;
pub const MAX_BASE64_BYTES = ((MAX_BYTES + 2) / 3) * 4;
pub const MAX_REQUEST_BYTES = MAX_COUNT * (MAX_BASE64_BYTES + 1024) + 64 * 1024;

pub const ImageInfo = struct { mime_type: []const u8, extension: []const u8, width: u32, height: u32 };
pub const Item = struct { name: []u8, bytes: []u8, info: ImageInfo, sha256: [64]u8 };
pub const Batch = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(Item) = .empty,

    pub fn deinit(self: *Batch) void {
        for (self.items.items) |item| {
            self.allocator.free(item.name);
            self.allocator.free(item.bytes);
        }
        self.items.deinit(self.allocator);
        self.* = undefined;
    }
};

fn be32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .big);
}
fn le32(bytes: []const u8) u32 {
    return std.mem.readInt(u32, bytes[0..4], .little);
}
fn le24(bytes: []const u8) u32 {
    return @as(u32, bytes[0]) | (@as(u32, bytes[1]) << 8) | (@as(u32, bytes[2]) << 16);
}
fn dimensions(mime: []const u8, ext: []const u8, width: u32, height: u32) !ImageInfo {
    if (width == 0 or height == 0 or width > 8192 or height > 8192 or @as(u64, width) * height > 32 * 1024 * 1024)
        return error.InvalidImageDimensions;
    return .{ .mime_type = mime, .extension = ext, .width = width, .height = height };
}

/// The filename and declared MIME never authorize content. Dimensions are read
/// from the bounded container, including chunk/segment lengths and terminators.
pub fn validate(bytes: []const u8) !ImageInfo {
    if (bytes.len == 0 or bytes.len > MAX_BYTES) return error.AttachmentTooLarge;
    if (std.mem.startsWith(u8, bytes, "\x89PNG\r\n\x1a\n")) {
        if (bytes.len < 45 or be32(bytes[8..]) != 13 or !std.mem.eql(u8, bytes[12..16], "IHDR")) return error.InvalidImage;
        const info = try dimensions("image/png", "png", be32(bytes[16..]), be32(bytes[20..]));
        if (bytes[26] != 0 or bytes[27] != 0 or bytes[28] > 1) return error.InvalidImage;
        const depth = bytes[24];
        const valid_depth = switch (bytes[25]) {
            0 => depth == 1 or depth == 2 or depth == 4 or depth == 8 or depth == 16,
            2, 4, 6 => depth == 8 or depth == 16,
            3 => depth == 1 or depth == 2 or depth == 4 or depth == 8,
            else => false,
        };
        if (!valid_depth) return error.InvalidImage;
        var offset: usize = 8;
        var has_data = false;
        while (offset + 12 <= bytes.len) {
            const length: usize = be32(bytes[offset..]);
            if (length > bytes.len - offset - 12) return error.InvalidImage;
            const chunk = bytes[offset + 4 .. offset + 8 + length];
            if (std.hash.Crc32.hash(chunk) != be32(bytes[offset + 8 + length ..])) return error.InvalidImage;
            if (std.mem.eql(u8, chunk[0..4], "IHDR") and offset != 8) return error.InvalidImage;
            if (std.mem.eql(u8, chunk[0..4], "IDAT") and length > 0) has_data = true;
            offset += 12 + length;
            if (std.mem.eql(u8, chunk[0..4], "IEND")) {
                if (length != 0 or !has_data or offset != bytes.len) return error.InvalidImage;
                return info;
            }
        }
        return error.InvalidImage;
    }
    if (bytes.len >= 4 and std.mem.startsWith(u8, bytes, "\xff\xd8")) {
        if (!std.mem.eql(u8, bytes[bytes.len - 2 ..], "\xff\xd9")) return error.InvalidImage;
        var offset: usize = 2;
        var info: ?ImageInfo = null;
        while (offset + 4 <= bytes.len) {
            if (bytes[offset] != 0xff) return error.InvalidImage;
            while (offset < bytes.len and bytes[offset] == 0xff) : (offset += 1) {}
            if (offset >= bytes.len) return error.InvalidImage;
            const marker = bytes[offset];
            offset += 1;
            if (marker == 0 or marker == 0xd8 or marker == 0xd9) return error.InvalidImage;
            if (marker == 1 or (marker >= 0xd0 and marker <= 0xd7)) continue;
            if (offset + 2 > bytes.len) return error.InvalidImage;
            const length = std.mem.readInt(u16, bytes[offset..][0..2], .big);
            if (length < 2 or length > bytes.len - offset) return error.InvalidImage;
            const is_sof = marker >= 0xc0 and marker <= 0xcf and marker != 0xc4 and marker != 0xc8 and marker != 0xcc;
            if (is_sof) {
                if (length < 8 or bytes[offset + 7] == 0 or length != 8 + @as(u16, bytes[offset + 7]) * 3) return error.InvalidImage;
                info = try dimensions("image/jpeg", "jpg", std.mem.readInt(u16, bytes[offset + 5 ..][0..2], .big), std.mem.readInt(u16, bytes[offset + 3 ..][0..2], .big));
            }
            if (marker == 0xda) return info orelse error.InvalidImage;
            offset += length;
        }
        return error.InvalidImage;
    }
    if (bytes.len >= 20 and std.mem.eql(u8, bytes[0..4], "RIFF") and std.mem.eql(u8, bytes[8..12], "WEBP")) {
        if (@as(u64, le32(bytes[4..])) + 8 != bytes.len) return error.InvalidImage;
        var offset: usize = 12;
        var info: ?ImageInfo = null;
        var has_frame = false;
        while (offset + 8 <= bytes.len) {
            const kind = bytes[offset .. offset + 4];
            const length: usize = le32(bytes[offset + 4 ..]);
            if (length > bytes.len - offset - 8) return error.InvalidImage;
            const data = bytes[offset + 8 .. offset + 8 + length];
            if (std.mem.eql(u8, kind, "VP8X")) {
                if (length != 10 or data[1] != 0 or data[2] != 0 or data[3] != 0) return error.InvalidImage;
                info = try dimensions("image/webp", "webp", le24(data[4..]) + 1, le24(data[7..]) + 1);
            } else if (std.mem.eql(u8, kind, "VP8L")) {
                if (length < 5 or data[0] != 0x2f or (data[4] >> 5) != 0) return error.InvalidImage;
                const bits = le32(data[1..]);
                const frame = try dimensions("image/webp", "webp", (bits & 0x3fff) + 1, ((bits >> 14) & 0x3fff) + 1);
                if (info) |canvas| if (canvas.width != frame.width or canvas.height != frame.height) return error.InvalidImage;
                if (info == null) info = frame;
                has_frame = true;
            } else if (std.mem.eql(u8, kind, "VP8 ")) {
                if (length < 10 or data[0] & 1 != 0 or !std.mem.eql(u8, data[3..6], "\x9d\x01\x2a")) return error.InvalidImage;
                const frame = try dimensions("image/webp", "webp", std.mem.readInt(u16, data[6..8], .little) & 0x3fff, std.mem.readInt(u16, data[8..10], .little) & 0x3fff);
                if (info) |canvas| if (canvas.width != frame.width or canvas.height != frame.height) return error.InvalidImage;
                if (info == null) info = frame;
                has_frame = true;
            } else if (std.mem.eql(u8, kind, "ANMF")) {
                // Animated containers are excluded: validate the actual frame,
                // never trust a declared canvas without a decodable image.
                return error.InvalidImage;
            }
            offset += 8 + length + (length & 1);
        }
        if (offset != bytes.len or !has_frame) return error.InvalidImage;
        return info orelse error.InvalidImage;
    }
    return error.UnsupportedImage;
}

fn digest(bytes: []const u8) [64]u8 {
    var hash: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(bytes, &hash, .{});
    var result: [64]u8 = undefined;
    const alphabet = "0123456789abcdef";
    for (hash, 0..) |byte, i| {
        result[i * 2] = alphabet[byte >> 4];
        result[i * 2 + 1] = alphabet[byte & 15];
    }
    return result;
}

/// Accepts the additive order_submit array [{name,data_base64}]. All inputs
/// are decoded and validated before an order or file is created.
pub fn decodeInputs(allocator: std.mem.Allocator, value: ?std.json.Value) !Batch {
    var batch = Batch{ .allocator = allocator };
    errdefer batch.deinit();
    const input = value orelse return batch;
    if (input != .array) return error.InvalidAttachments;
    if (input.array.items.len > MAX_COUNT) return error.TooManyAttachments;
    for (input.array.items) |item| {
        if (item != .object) return error.InvalidAttachments;
        var keys = item.object.iterator();
        while (keys.next()) |key| {
            if (!std.mem.eql(u8, key.key_ptr.*, "name") and !std.mem.eql(u8, key.key_ptr.*, "data_base64")) return error.InvalidAttachments;
        }
        const name = item.object.get("name") orelse return error.InvalidAttachments;
        const encoded = item.object.get("data_base64") orelse return error.InvalidAttachments;
        if (name != .string or encoded != .string or name.string.len == 0 or name.string.len > 255 or !std.unicode.utf8ValidateSlice(name.string)) return error.InvalidAttachments;
        for (name.string) |ch| if (ch < 32 or ch == 127 or ch == '/' or ch == '\\') return error.InvalidAttachments;
        if (encoded.string.len > MAX_BASE64_BYTES) return error.AttachmentTooLarge;
        const size = std.base64.standard.Decoder.calcSizeForSlice(encoded.string) catch return error.InvalidAttachmentBase64;
        if (size == 0 or size > MAX_BYTES) return error.AttachmentTooLarge;
        const bytes = try allocator.alloc(u8, size);
        errdefer allocator.free(bytes);
        std.base64.standard.Decoder.decode(bytes, encoded.string) catch return error.InvalidAttachmentBase64;
        const info = try validate(bytes);
        const owned_name = try allocator.dupe(u8, name.string);
        errdefer allocator.free(owned_name);
        try batch.items.append(allocator, .{ .name = owned_name, .bytes = bytes, .info = info, .sha256 = digest(bytes) });
    }
    return batch;
}

fn openStorage(io: std.Io, data_dir: []const u8, order_id: i64, create: bool) !std.Io.Dir {
    if (order_id <= 0) return error.InvalidOrderId;
    const root = try std.Io.Dir.cwd().openDir(io, data_dir, .{ .follow_symlinks = false });
    defer root.close(io);
    if ((try root.stat(io)).kind != .directory) return error.AttachmentPathEscape;
    if (create) try root.createDirPath(io, "attachments");
    const attachments = try root.openDir(io, "attachments", .{ .follow_symlinks = false });
    defer attachments.close(io);
    if ((try attachments.stat(io)).kind != .directory) return error.AttachmentPathEscape;
    var number: [24]u8 = undefined;
    const order = try std.fmt.bufPrint(&number, "{d}", .{order_id});
    if (create) try attachments.createDirPath(io, order);
    const dir = try attachments.openDir(io, order, .{ .follow_symlinks = false });
    errdefer dir.close(io);
    if ((try dir.stat(io)).kind != .directory) return error.AttachmentPathEscape;
    return dir;
}

fn readStored(allocator: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, filename: []const u8) ![]u8 {
    var file = try dir.openFile(io, filename, .{ .follow_symlinks = false, .allow_directory = false, .resolve_beneath = true });
    defer file.close(io);
    if ((try file.stat(io)).kind != .file) return error.AttachmentPathEscape;
    // Zig 0.16 opens Windows no-follow handles asynchronously, but returns the
    // synchronous flag. Match the actual handle mode before NtReadFile uses it.
    if (@import("builtin").os.tag == .windows) file.flags.nonblocking = true;
    var reader = file.reader(io, &.{});
    return reader.interface.allocRemaining(allocator, .limited(MAX_BYTES)) catch |err| switch (err) {
        error.ReadFailed => return reader.err orelse error.AttachmentReadFailed,
        else => return err,
    };
}

/// Database rows become visible together after every immutable file has been
/// materialized. Failure rolls back rows and removes only files created here.
pub fn store(allocator: std.mem.Allocator, io: std.Io, conn: db.Connection, data_dir: []const u8, order_id: i64, batch: *const Batch) !void {
    if (order_id <= 0) return error.InvalidOrderId;
    if (batch.items.items.len > MAX_COUNT) return error.TooManyAttachments;
    if (batch.items.items.len == 0) return;
    // Do not trust callers that construct Batch directly instead of decodeInputs.
    for (batch.items.items) |item| {
        if (item.name.len == 0 or item.name.len > 255 or !std.unicode.utf8ValidateSlice(item.name)) return error.InvalidAttachments;
        for (item.name) |ch| if (ch < 32 or ch == 127 or ch == '/' or ch == '\\') return error.InvalidAttachments;
        const info = try validate(item.bytes);
        if (!std.mem.eql(u8, &digest(item.bytes), &item.sha256) or !std.mem.eql(u8, info.extension, item.info.extension) or info.width != item.info.width or info.height != item.info.height or !std.mem.eql(u8, info.mime_type, item.info.mime_type)) return error.InvalidAttachments;
    }
    const dir = try openStorage(io, data_dir, order_id, true);
    defer dir.close(io);
    var created: [MAX_COUNT][80]u8 = undefined;
    var created_lengths: [MAX_COUNT]usize = undefined;
    var created_count: usize = 0;
    var committed = false;
    defer if (!committed) {
        for (0..created_count) |i| dir.deleteFile(io, created[i][0..created_lengths[i]]) catch |err| {
            std.log.err("attachment rollback file removal: {s}", .{@errorName(err)});
        };
    };
    try conn.exec("BEGIN IMMEDIATE");
    defer if (!committed) conn.exec("ROLLBACK") catch |err| {
        std.log.err("attachment transaction rollback: {s}", .{@errorName(err)});
    };
    const order_stmt = try conn.prepare("SELECT id FROM orders WHERE id=?");
    defer conn.finalize(order_stmt);
    try db.bindInt(order_stmt, 1, order_id);
    if (db.c.sqlite3_step(order_stmt) != db.c.SQLITE_ROW) return error.OrderNotFound;
    const count_stmt = try conn.prepare("SELECT COUNT(*) FROM order_attachments WHERE order_id=?");
    defer conn.finalize(count_stmt);
    try db.bindInt(count_stmt, 1, order_id);
    if (db.c.sqlite3_step(count_stmt) != db.c.SQLITE_ROW) return error.StepFailed;
    var count = db.c.sqlite3_column_int(count_stmt, 0);
    const insert = try conn.prepare("INSERT INTO order_attachments(order_id,sha256,name,mime_type,extension,size_bytes,width,height,relative_path) VALUES(?,?,?,?,?,?,?,?,?)");
    defer conn.finalize(insert);
    for (batch.items.items) |item| {
        const exists = try conn.prepare("SELECT 1 FROM order_attachments WHERE order_id=? AND sha256=?");
        defer conn.finalize(exists);
        try db.bindInt(exists, 1, order_id);
        try db.bindText(exists, 2, &item.sha256);
        const rc = db.c.sqlite3_step(exists);
        if (rc == db.c.SQLITE_ROW) continue;
        if (rc != db.c.SQLITE_DONE) return error.StepFailed;
        if (count >= MAX_COUNT) return error.TooManyAttachments;
        var file_buf: [80]u8 = undefined;
        const filename = try std.fmt.bufPrint(&file_buf, "{s}.{s}", .{ item.sha256, item.info.extension });
        var atomic = try dir.createFileAtomic(io, filename, .{});
        defer atomic.deinit(io);
        try atomic.file.writeStreamingAll(io, item.bytes);
        try atomic.file.sync(io);
        atomic.link(io) catch |err| switch (err) {
            error.PathAlreadyExists => {
                const previous = try readStored(allocator, io, dir, filename);
                defer allocator.free(previous);
                if (!std.mem.eql(u8, previous, item.bytes)) return error.AttachmentIntegrityFailed;
                try insertItem(conn, insert, order_id, item, filename);
                count += 1;
                continue;
            },
            else => return err,
        };
        @memcpy(created[created_count][0..filename.len], filename);
        created_lengths[created_count] = filename.len;
        created_count += 1;
        try insertItem(conn, insert, order_id, item, filename);
        count += 1;
    }
    try conn.exec("COMMIT");
    committed = true;
}

fn insertItem(conn: db.Connection, stmt: *db.c.sqlite3_stmt, order_id: i64, item: Item, filename: []const u8) !void {
    if (db.c.sqlite3_reset(stmt) != db.c.SQLITE_OK) return error.StepFailed;
    try db.bindInt(stmt, 1, order_id);
    try db.bindText(stmt, 2, &item.sha256);
    try db.bindText(stmt, 3, item.name);
    try db.bindText(stmt, 4, item.info.mime_type);
    try db.bindText(stmt, 5, item.info.extension);
    try db.bindInt(stmt, 6, @intCast(item.bytes.len));
    try db.bindInt(stmt, 7, item.info.width);
    try db.bindInt(stmt, 8, item.info.height);
    var path: [120]u8 = undefined;
    try db.bindText(stmt, 9, try std.fmt.bufPrint(&path, "attachments/{d}/{s}", .{ order_id, filename }));
    if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
    _ = conn;
}

const Listed = struct { name: []const u8, sha256: []const u8, mime_type: []const u8, size_bytes: i64, width: i64, height: i64, relative_path: []const u8 };
pub fn hasImages(conn: db.Connection, order_id: i64) !bool {
    if (order_id <= 0) return error.InvalidOrderId;
    const stmt = try conn.prepare("SELECT 1 FROM order_attachments WHERE order_id=? LIMIT 1");
    defer conn.finalize(stmt);
    try db.bindInt(stmt, 1, order_id);
    return switch (db.c.sqlite3_step(stmt)) {
        db.c.SQLITE_ROW => true,
        db.c.SQLITE_DONE => false,
        else => error.StepFailed,
    };
}
fn column(stmt: *db.c.sqlite3_stmt, index: c_int) ![]const u8 {
    const ptr = db.c.sqlite3_column_text(stmt, index) orelse return error.InvalidAttachmentRecord;
    return ptr[0..@intCast(db.c.sqlite3_column_bytes(stmt, index))];
}
pub fn listJson(allocator: std.mem.Allocator, conn: db.Connection, order_id: i64) ![]u8 {
    if (order_id <= 0) return error.InvalidOrderId;
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var items: std.ArrayList(Listed) = .empty;
    const stmt = try conn.prepare("SELECT name,sha256,mime_type,size_bytes,width,height,relative_path FROM order_attachments WHERE order_id=? ORDER BY rowid");
    defer conn.finalize(stmt);
    try db.bindInt(stmt, 1, order_id);
    while (true) {
        const rc = db.c.sqlite3_step(stmt);
        if (rc == db.c.SQLITE_DONE) break;
        if (rc != db.c.SQLITE_ROW) return error.StepFailed;
        if (items.items.len >= MAX_COUNT) return error.TooManyAttachments;
        try items.append(a, .{
            .name = try a.dupe(u8, try column(stmt, 0)),
            .sha256 = try a.dupe(u8, try column(stmt, 1)),
            .mime_type = try a.dupe(u8, try column(stmt, 2)),
            .size_bytes = db.c.sqlite3_column_int64(stmt, 3),
            .width = db.c.sqlite3_column_int64(stmt, 4),
            .height = db.c.sqlite3_column_int64(stmt, 5),
            .relative_path = try a.dupe(u8, try column(stmt, 6)),
        });
    }
    return std.json.Stringify.valueAlloc(allocator, items.items, .{});
}

pub const LoadedImage = struct { bytes: []u8, mime_type: []const u8 };
pub const LoadedImages = struct {
    allocator: std.mem.Allocator,
    items: std.ArrayList(LoadedImage) = .empty,
    pub fn deinit(self: *LoadedImages) void {
        for (self.items.items) |image| self.allocator.free(image.bytes);
        self.items.deinit(self.allocator);
        self.* = undefined;
    }
};
pub fn loadImages(allocator: std.mem.Allocator, io: std.Io, conn: db.Connection, data_dir: []const u8, order_id: i64) !LoadedImages {
    if (order_id <= 0) return error.InvalidOrderId;
    var result = LoadedImages{ .allocator = allocator };
    errdefer result.deinit();
    const stmt = try conn.prepare("SELECT sha256,extension FROM order_attachments WHERE order_id=? ORDER BY rowid");
    defer conn.finalize(stmt);
    try db.bindInt(stmt, 1, order_id);
    var dir: ?std.Io.Dir = null;
    defer if (dir) |d| d.close(io);
    while (true) {
        const rc = db.c.sqlite3_step(stmt);
        if (rc == db.c.SQLITE_DONE) break;
        if (rc != db.c.SQLITE_ROW) return error.StepFailed;
        if (result.items.items.len >= MAX_COUNT) return error.TooManyAttachments;
        const hash = try column(stmt, 0);
        const ext = try column(stmt, 1);
        if (hash.len != 64 or !(std.mem.eql(u8, ext, "png") or std.mem.eql(u8, ext, "jpg") or std.mem.eql(u8, ext, "webp"))) return error.InvalidAttachmentRecord;
        for (hash) |ch| if (!std.ascii.isDigit(ch) and !(ch >= 'a' and ch <= 'f')) return error.InvalidAttachmentRecord;
        if (dir == null) dir = try openStorage(io, data_dir, order_id, false);
        var filename: [80]u8 = undefined;
        const bytes = try readStored(allocator, io, dir.?, try std.fmt.bufPrint(&filename, "{s}.{s}", .{ hash, ext }));
        errdefer allocator.free(bytes);
        if (!std.mem.eql(u8, &digest(bytes), hash)) return error.AttachmentIntegrityFailed;
        const info = try validate(bytes);
        if (!std.mem.eql(u8, info.extension, ext)) return error.AttachmentIntegrityFailed;
        try result.items.append(allocator, .{ .bytes = bytes, .mime_type = info.mime_type });
    }
    return result;
}

const png_fixture = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAIAAACQd1PeAAAADElEQVR4nGP4z8AAAAMBAQDJ/pLvAAAAAElFTkSuQmCC";

fn fixtureBatch(a: std.mem.Allocator) !Batch {
    const source = "[{\"name\":\"capture.png\",\"data_base64\":\"" ++ png_fixture ++ "\"}]";
    const parsed = try std.json.parseFromSlice(std.json.Value, a, source, .{});
    defer parsed.deinit();
    return decodeInputs(a, parsed.value);
}
fn testDb() !db.Connection {
    var conn = try db.Connection.open(std.testing.allocator, ":memory:");
    errdefer conn.close();
    try db.Migrator.init(std.testing.allocator).migrate(conn, &db.runtime_schema);
    try conn.exec("INSERT INTO orders(id,project_id,user_prompt,status,created_at) VALUES(1,'fixture','image','pending',1)");
    return conn;
}

test "E5.23 engine rejects forged png despite filename and UI acceptance" {
    const a = std.testing.allocator;
    const parsed = try std.json.parseFromSlice(std.json.Value, a, "[{\"name\":\"looks-valid.png\",\"data_base64\":\"bm90IGFuIGltYWdl\"}]", .{});
    defer parsed.deinit();
    try std.testing.expectError(error.UnsupportedImage, decodeInputs(a, parsed.value));
    try std.testing.expectError(error.UnsupportedImage, validate("plain text.png"));
    try std.testing.expectError(error.InvalidImage, validate("\x89PNG\r\n\x1a\ntruncated"));
    try std.testing.expectError(error.AttachmentTooLarge, validate(""));
}

test "E5.23 PNG validation reads dimensions and rejects CRC, oversized and zero dimensions" {
    const a = std.testing.allocator;
    var batch = try fixtureBatch(a);
    defer batch.deinit();
    try std.testing.expectEqual(@as(u32, 1), batch.items.items[0].info.width);
    try std.testing.expectEqualStrings("image/png", batch.items.items[0].info.mime_type);
    const image = batch.items.items[0].bytes;
    image[16] = 1;
    try std.testing.expectError(error.InvalidImageDimensions, validate(image));
    image[16] = 0;
    image[19] = 0;
    try std.testing.expectError(error.InvalidImageDimensions, validate(image));
    image[19] = 1;
    image[image.len - 1] ^= 1;
    try std.testing.expectError(error.InvalidImage, validate(image));
    const oversized = try a.alloc(u8, MAX_BYTES + 1);
    defer a.free(oversized);
    try std.testing.expectError(error.AttachmentTooLarge, validate(oversized));
    try std.testing.expectError(error.InvalidImageDimensions, dimensions("image/png", "png", 8192, 8192));
}

test "E5.23 JPEG and WebP container dimensions with truncation guards" {
    const jpeg = "\xff\xd8\xff\xc0\x00\x0b\x08\x00\x01\x00\x02\x01\x01\x11\x00\xff\xda\x00\x08\x01\x01\x00\x00\x3f\x00\x00\xff\xd9";
    const j = try validate(jpeg);
    try std.testing.expectEqual(@as(u32, 2), j.width);
    try std.testing.expectEqualStrings("image/jpeg", j.mime_type);
    try std.testing.expectError(error.InvalidImage, validate(jpeg[0 .. jpeg.len - 2]));
    const webp = "RIFF\x12\x00\x00\x00WEBPVP8L\x05\x00\x00\x00\x2f\x00\x00\x00\x00\x00";
    const w = try validate(webp);
    try std.testing.expectEqual(@as(u32, 1), w.height);
    try std.testing.expectEqualStrings("image/webp", w.mime_type);
    try std.testing.expectError(error.InvalidImage, validate(webp[0 .. webp.len - 1]));
    try std.testing.expectError(error.InvalidImage, validate("RIFF\x0c\x00\x00\x00WEBPVP8L\xff\xff\xff\xff"));
}

test "E5.23 base64 array validation limits count name shape and invalid encoding" {
    const a = std.testing.allocator;
    var empty = try decodeInputs(a, null);
    defer empty.deinit();
    try std.testing.expectEqual(@as(usize, 0), empty.items.items.len);
    const bad = [_]struct { json: []const u8, err: anyerror }{
        .{ .json = "{}", .err = error.InvalidAttachments },
        .{ .json = "[{}, {}, {}, {}, {}]", .err = error.TooManyAttachments },
        .{ .json = "[0]", .err = error.InvalidAttachments },
        .{ .json = "[{\"name\":\"x\"}]", .err = error.InvalidAttachments },
        .{ .json = "[{\"name\":\"x\",\"data_base64\":\"?!!!\"}]", .err = error.InvalidAttachmentBase64 },
        .{ .json = "[{\"name\":\"../x.png\",\"data_base64\":\"YQ==\"}]", .err = error.InvalidAttachments },
        .{ .json = "[{\"name\":\"x\",\"data_base64\":\"YQ==\",\"extra\":true}]", .err = error.InvalidAttachments },
    };
    for (bad) |case| {
        const parsed = try std.json.parseFromSlice(std.json.Value, a, case.json, .{});
        defer parsed.deinit();
        try std.testing.expectError(case.err, decodeInputs(a, parsed.value));
    }
}

test "E5.23 stored immutable image lists loads and detects corruption without owner data" {
    const a = std.testing.allocator;
    var conn = try testDb();
    defer conn.close();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rootbuf: [4096]u8 = undefined;
    const rootlen = try tmp.dir.realPath(std.testing.io, &rootbuf);
    const root = rootbuf[0..rootlen];
    var batch = try fixtureBatch(a);
    defer batch.deinit();
    try std.testing.expect(!try hasImages(conn, 1));
    try store(a, std.testing.io, conn, root, 1, &batch);
    try store(a, std.testing.io, conn, root, 1, &batch);
    try std.testing.expect(try hasImages(conn, 1));
    const json = try listJson(a, conn, 1);
    defer a.free(json);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, json, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 1), parsed.value.array.items.len);
    const relative = parsed.value.array.items[0].object.get("relative_path").?.string;
    try std.testing.expect(std.mem.startsWith(u8, relative, "attachments/1/"));
    var loaded = try loadImages(a, std.testing.io, conn, root, 1);
    defer loaded.deinit();
    try std.testing.expectEqualSlices(u8, batch.items.items[0].bytes, loaded.items.items[0].bytes);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = relative, .data = "corrupt" });
    try std.testing.expectError(error.AttachmentIntegrityFailed, loadImages(a, std.testing.io, conn, root, 1));
    try std.testing.expectError(error.OrderNotFound, store(a, std.testing.io, conn, root, 404, &batch));
    try std.testing.expectError(error.InvalidOrderId, hasImages(conn, 0));
    try std.testing.expectError(error.InvalidOrderId, store(a, std.testing.io, conn, root, 0, &batch));
    try std.testing.expectError(error.InvalidOrderId, listJson(a, conn, 0));
    try std.testing.expectError(error.InvalidOrderId, loadImages(a, std.testing.io, conn, root, 0));
    var none = try loadImages(a, std.testing.io, conn, root, 404);
    defer none.deinit();
    try std.testing.expectEqual(@as(usize, 0), none.items.items.len);
}

test "E5.23 failed attachment insert rolls back database and new file" {
    const a = std.testing.allocator;
    var conn = try testDb();
    defer conn.close();
    try conn.exec("CREATE TRIGGER force_attachment_failure BEFORE INSERT ON order_attachments BEGIN SELECT RAISE(ABORT,'fixture'); END");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rootbuf: [4096]u8 = undefined;
    const rootlen = try tmp.dir.realPath(std.testing.io, &rootbuf);
    var batch = try fixtureBatch(a);
    defer batch.deinit();
    try std.testing.expectError(error.StepFailed, store(a, std.testing.io, conn, rootbuf[0..rootlen], 1, &batch));
    try std.testing.expect(!try hasImages(conn, 1));
    var filename: [128]u8 = undefined;
    const relative = try std.fmt.bufPrint(&filename, "attachments/1/{s}.png", .{batch.items.items[0].sha256});
    try std.testing.expectError(error.FileNotFound, tmp.dir.readFileAlloc(std.testing.io, relative, a, .limited(MAX_BYTES)));
}

test "E5.23 repeated submissions cannot exceed four immutable images" {
    const a = std.testing.allocator;
    var conn = try testDb();
    defer conn.close();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rootbuf: [4096]u8 = undefined;
    const rootlen = try tmp.dir.realPath(std.testing.io, &rootbuf);
    for (0..5) |i| {
        var batch = try fixtureBatch(a);
        defer batch.deinit();
        const item = &batch.items.items[0];
        const original = item.bytes;
        // A harmless tEXt chunk makes five distinct valid PNG files.
        const bytes = try a.alloc(u8, original.len + 16);
        @memcpy(bytes[0 .. original.len - 12], original[0 .. original.len - 12]);
        const offset = original.len - 12;
        std.mem.writeInt(u32, bytes[offset..][0..4], 4, .big);
        @memcpy(bytes[offset + 4 .. offset + 8], "tEXt");
        @memcpy(bytes[offset + 8 .. offset + 12], &[4]u8{ 'k', 0, 'v', @as(u8, @intCast('0' + i)) });
        std.mem.writeInt(u32, bytes[offset + 12 ..][0..4], std.hash.Crc32.hash(bytes[offset + 4 .. offset + 12]), .big);
        @memcpy(bytes[offset + 16 ..], original[original.len - 12 ..]);
        a.free(original);
        item.bytes = bytes;
        item.sha256 = digest(bytes);
        if (i < 4) {
            try store(a, std.testing.io, conn, rootbuf[0..rootlen], 1, &batch);
        } else {
            try std.testing.expectError(error.TooManyAttachments, store(a, std.testing.io, conn, rootbuf[0..rootlen], 1, &batch));
        }
    }
    var loaded = try loadImages(a, std.testing.io, conn, rootbuf[0..rootlen], 1);
    defer loaded.deinit();
    try std.testing.expectEqual(@as(usize, 4), loaded.items.items.len);
}

// Privilege-free NTFS mount-point fixture for the directory guard.
fn attachmentTestJunction(allocator: std.mem.Allocator, link_dir: []const u8, target: []const u8) !void {
    const io = std.testing.io;
    if (@import("builtin").os.tag != .windows) {
        return std.Io.Dir.cwd().symLink(io, target, link_dir, .{ .is_directory = true });
    }
    const windows = std.os.windows;
    const win = struct {
        extern "kernel32" fn CreateFileW(path: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, creation: u32, flags: u32, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
        extern "kernel32" fn DeviceIoControl(handle: windows.HANDLE, code: u32, input: ?*const anyopaque, input_len: u32, output: ?*anyopaque, output_len: u32, returned: ?*u32, overlapped: ?*anyopaque) callconv(.winapi) c_int;
    };
    try std.Io.Dir.cwd().createDir(io, link_dir, .default_dir);
    errdefer std.Io.Dir.cwd().deleteDir(io, link_dir) catch |err| {
        std.log.err("attachment junction fixture rollback: {s}", .{@errorName(err)});
    };
    const link_w = try std.unicode.utf8ToUtf16LeAllocZ(allocator, link_dir);
    defer allocator.free(link_w);
    const handle = win.CreateFileW(link_w.ptr, 0x40000000, 0, null, 3, 0x02000000 | 0x00200000, null);
    if (handle == windows.INVALID_HANDLE_VALUE) return error.JunctionOpenFailed;
    defer windows.CloseHandle(handle);
    const substitute = try std.fmt.allocPrint(allocator, "\\??\\{s}", .{target});
    defer allocator.free(substitute);
    const sub_w = try std.unicode.utf8ToUtf16LeAlloc(allocator, substitute);
    defer allocator.free(sub_w);
    const print_w = try std.unicode.utf8ToUtf16LeAlloc(allocator, target);
    defer allocator.free(print_w);
    const sub_len: u16 = @intCast(sub_w.len * 2);
    const print_len: u16 = @intCast(print_w.len * 2);
    const data_len: u16 = 8 + sub_len + 2 + print_len + 2;
    const buffer = try allocator.alloc(u8, 8 + data_len);
    defer allocator.free(buffer);
    @memset(buffer, 0);
    std.mem.writeInt(u32, buffer[0..4], 0xA0000003, .little);
    std.mem.writeInt(u16, buffer[4..6], data_len, .little);
    std.mem.writeInt(u16, buffer[10..12], sub_len, .little);
    std.mem.writeInt(u16, buffer[12..14], sub_len + 2, .little);
    std.mem.writeInt(u16, buffer[14..16], print_len, .little);
    var pos: usize = 16;
    for (sub_w) |unit| {
        std.mem.writeInt(u16, buffer[pos..][0..2], unit, .little);
        pos += 2;
    }
    pos += 2;
    for (print_w) |unit| {
        std.mem.writeInt(u16, buffer[pos..][0..2], unit, .little);
        pos += 2;
    }
    var returned: u32 = 0;
    if (win.DeviceIoControl(handle, 0x000900A4, buffer.ptr, @intCast(buffer.len), null, 0, &returned, null) == 0) return error.JunctionIoctlFailed;
}

test "E5.23 attachment junction never supplies external image bytes" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: reparse points y junctions de Windows; en Linux los enlaces simbolicos los rechaza confined_posix");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var conn = try testDb();
    defer conn.close();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDir(io, "data", .default_dir);
    try tmp.dir.createDir(io, "outside", .default_dir);
    var rootbuf: [4096]u8 = undefined;
    const rootlen = try tmp.dir.realPath(io, &rootbuf);
    const root = rootbuf[0..rootlen];
    const data_dir = try std.fs.path.join(a, &.{ root, "data" });
    defer a.free(data_dir);
    const outside = try std.fs.path.join(a, &.{ root, "outside" });
    defer a.free(outside);
    const link_dir = try std.fs.path.join(a, &.{ data_dir, "attachments", "1" });
    defer a.free(link_dir);
    var batch = try fixtureBatch(a);
    defer batch.deinit();
    try store(a, io, conn, data_dir, 1, &batch);
    const item = batch.items.items[0];
    var filenamebuf: [128]u8 = undefined;
    const filename = try std.fmt.bufPrint(&filenamebuf, "{s}.png", .{item.sha256});
    const external_file = try std.fs.path.join(a, &.{ "outside", filename });
    defer a.free(external_file);
    try tmp.dir.writeFile(io, .{ .sub_path = external_file, .data = item.bytes });
    const stored_file = try std.fs.path.join(a, &.{ "data", "attachments", "1", filename });
    defer a.free(stored_file);
    try tmp.dir.deleteFile(io, stored_file);
    try tmp.dir.deleteDir(io, "data/attachments/1");
    try attachmentTestJunction(a, link_dir, outside);
    defer tmp.dir.deleteDir(io, "data/attachments/1") catch |err| {
        std.log.err("attachment junction fixture cleanup: {s}", .{@errorName(err)});
    };

    // Prove the fixture really redirects to a valid, hash-matching PNG before
    // demanding that both public operations reject the reparse point.
    const followed = try tmp.dir.readFileAlloc(io, stored_file, a, .limited(MAX_BYTES));
    defer a.free(followed);
    try std.testing.expectEqualSlices(u8, item.bytes, followed);
    try std.testing.expectError(error.AttachmentPathEscape, loadImages(a, io, conn, data_dir, 1));
    // createDirPath rejects an existing reparse point before the no-follow
    // open; loading reaches the directory-kind guard instead.
    try std.testing.expectError(error.NotDir, store(a, io, conn, data_dir, 1, &batch));
    if (readStored(a, io, tmp.dir, "data/attachments/1")) |bytes| {
        a.free(bytes);
        return error.TestUnexpectedResult;
    } else |err| {
        try std.testing.expect(err == error.AttachmentPathEscape or err == error.SymLinkLoop or err == error.IsDir);
    }
}

test "E5.23 file symlink or file reparse handle never supplies image bytes" {
    if (@import("builtin").os.tag != .windows) return @import("platform.zig").skip("T9: reparse points y junctions de Windows; en Linux los enlaces simbolicos los rechaza confined_posix");
    const a = std.testing.allocator;
    const io = std.testing.io;
    var conn = try testDb();
    defer conn.close();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var rootbuf: [4096]u8 = undefined;
    const rootlen = try tmp.dir.realPath(io, &rootbuf);
    const root = rootbuf[0..rootlen];
    var batch = try fixtureBatch(a);
    defer batch.deinit();
    try store(a, io, conn, root, 1, &batch);
    const item = batch.items.items[0];
    const relative = try std.fmt.allocPrint(a, "attachments/1/{s}.png", .{item.sha256});
    defer a.free(relative);
    try tmp.dir.writeFile(io, .{ .sub_path = "external.png", .data = item.bytes });
    try tmp.dir.deleteFile(io, relative);
    const link = try std.fs.path.join(a, &.{ root, relative });
    defer a.free(link);
    const target = try std.fs.path.join(a, &.{ root, "external.png" });
    defer a.free(target);
    if (@import("builtin").os.tag == .windows) {
        const windows = std.os.windows;
        const win = struct {
            extern "kernel32" fn CreateSymbolicLinkW(link_path: [*:0]const u16, target_path: [*:0]const u16, flags: u32) callconv(.winapi) u8;
            extern "kernel32" fn CreateFileW(path: [*:0]const u16, access: u32, share: u32, security: ?*anyopaque, creation: u32, flags: u32, template: ?windows.HANDLE) callconv(.winapi) windows.HANDLE;
            extern "kernel32" fn DeviceIoControl(handle: windows.HANDLE, code: u32, input: ?*const anyopaque, input_len: u32, output: ?*anyopaque, output_len: u32, returned: ?*u32, overlapped: ?*anyopaque) callconv(.winapi) c_int;
            extern "kernel32" fn GetFileInformationByHandleEx(handle: windows.HANDLE, class: c_int, info: *anyopaque, size: u32) callconv(.winapi) c_int;
        };
        const link_w = try std.unicode.utf8ToUtf16LeAllocZ(a, link);
        defer a.free(link_w);
        const target_w = try std.unicode.utf8ToUtf16LeAllocZ(a, target);
        defer a.free(target_w);
        // SYMBOLIC_LINK_FLAG_ALLOW_UNPRIVILEGED_CREATE, file (no DIRECTORY bit).
        if (win.CreateSymbolicLinkW(link_w.ptr, target_w.ptr, 0x2) == 0) {
            const code = windows.GetLastError();
            if (code != .PRIVILEGE_NOT_HELD) return error.FileSymlinkFixtureFailed;
            // Developer Mode disabled: use a real file with a non-Microsoft
            // GUID reparse point. Setting this tag needs no symlink privilege.
            const handle = win.CreateFileW(link_w.ptr, 0x40000000, 0, null, 1, 0x00200000, null);
            if (handle == windows.INVALID_HANDLE_VALUE) return error.FileReparseFixtureOpenFailed;
            defer windows.CloseHandle(handle);
            var buffer: [24]u8 = @splat(0);
            std.mem.writeInt(u32, buffer[0..4], 0x00000042, .little);
            @memcpy(buffer[8..24], &[_]u8{ 0x79, 0xd1, 0x1a, 0x8c, 0x6e, 0x3b, 0x40, 0x4f, 0x91, 0x21, 0x3f, 0x17, 0x25, 0x9a, 0xb7, 0x01 });
            var returned: u32 = 0;
            if (win.DeviceIoControl(handle, 0x000900A4, &buffer, buffer.len, null, 0, &returned, null) == 0) return error.FileReparseFixtureIoctlFailed;
            std.debug.print("E5.23 FILE_SYMLINK_LIMIT=ERROR_PRIVILEGE_NOT_HELD; Developer Mode unavailable; real GUID file reparse fallback\n", .{});
        } else {
            const followed = try tmp.dir.readFileAlloc(io, relative, a, .limited(MAX_BYTES));
            defer a.free(followed);
            try std.testing.expectEqualSlices(u8, item.bytes, followed);
            std.debug.print("E5.23 FILE_SYMLINK_CREATED=ALLOW_UNPRIVILEGED_CREATE\n", .{});
        }
        const file = try tmp.dir.openFile(io, relative, .{ .follow_symlinks = false });
        defer file.close(io);
        var info: extern struct { attributes: u32, tag: u32 } = undefined;
        if (win.GetFileInformationByHandleEx(file.handle, 9, &info, @sizeOf(@TypeOf(info))) == 0) return error.FileReparseFixtureQueryFailed;
        try std.testing.expect(info.attributes & 0x400 != 0); // FILE_ATTRIBUTE_REPARSE_POINT
        try std.testing.expect((try file.stat(io)).kind != .file);
        std.debug.print("E5.23 FILE_REPARSE_ATTRIBUTE_FROM_HANDLE=1\n", .{});
    } else {
        try std.Io.Dir.cwd().symLink(io, target, link, .{});
    }
    try std.testing.expectError(error.AttachmentPathEscape, readStored(a, io, tmp.dir, relative));
    try std.testing.expectError(error.AttachmentPathEscape, loadImages(a, io, conn, root, 1));
    // The outside image is unchanged regardless of fixture strategy.
    const external = try tmp.dir.readFileAlloc(io, "external.png", a, .limited(MAX_BYTES));
    defer a.free(external);
    try std.testing.expectEqualSlices(u8, item.bytes, external);
}
