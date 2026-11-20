const std = @import("std");
const db = @import("db.zig");
const dpapi = @import("dpapi.zig");
const executor = @import("executor.zig");
const health = @import("health.zig");
const Sleep = @import("platform.zig").sleep;
extern "kernel32" fn GetSystemDirectoryW(buffer: [*]u16, size: u32) callconv(.winapi) u32;
const GetTickCount64 = @import("platform.zig").ticks;
const BCryptGenRandom = if (@import("builtin").os.tag == .windows) struct {
    extern "bcrypt" fn BCryptGenRandom(?*anyopaque, [*]u8, u32, u32) callconv(.winapi) i32;
}.BCryptGenRandom else @import("platform.zig").random;

test "E5.29 SSRF default rejects private literal configuration" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
    try std.testing.expectError(error.PrivateDestination, addConfig(a, conn, "{\"url\":\"http://127.0.0.1/hook\"}"));
}

test "E5.29 SSRF address ranges authority ambiguity and explicit opt-in" {
    for ([_][]const u8{ "0.0.0.0", "10.0.0.1", "100.64.0.1", "127.1.2.3", "169.254.169.254", "169.254.0.1", "172.16.0.1", "172.31.255.255", "192.168.1.1", "224.0.0.1", "255.255.255.255", "::", "::1", "fc00::1", "fd00:ec2::254", "fe80::1", "ff02::1", "::ffff:127.0.0.1", "::ffff:169.254.169.254", "64:ff9b::a00:1", "2002:7f00:1::", "2001::1" }) |text| {
        const ip = try std.Io.net.IpAddress.parse(text, 80);
        try std.testing.expect(privateAddress(ip));
        var buffer: [256]u8 = undefined;
        const url = if (ip == .ip6) try std.fmt.bufPrint(&buffer, "http://[{s}]/hook", .{text}) else try std.fmt.bufPrint(&buffer, "http://{s}/hook", .{text});
        try std.testing.expectError(error.PrivateDestination, validateDestinationUrl(url, false));
        try validateDestinationUrl(url, true);
    }
    for ([_][]const u8{ "8.8.8.8", "172.15.255.255", "172.32.0.1", "2606:4700:4700::1111", "::ffff:8.8.8.8" }) |text| try std.testing.expect(!privateAddress(try std.Io.net.IpAddress.parse(text, 80)));
    for ([_][]const u8{ "http://%31%32%37.0.0.1/", "http://[fe80::1%25eth0]/", "http://[::10.0.0.1]/", "http://example.test\\@127.0.0.1/", "http://example.test:0/", "http://[bad]/" }) |url| try std.testing.expectError(error.InvalidConfig, validateDestinationUrl(url, true));
}

test "E5.29 SSRF checks all DNS answers at send time with bounded failure" {
    const Mock = struct {
        fn mixed(_: std.Io, host: []const u8, port: u16) !ResolvedAddresses {
            try std.testing.expectEqualStrings("public-looking.example", host);
            var r: ResolvedAddresses = .{};
            r.items[0] = try std.Io.net.IpAddress.parse("8.8.8.8", port);
            r.items[1] = try std.Io.net.IpAddress.parse("169.254.169.254", port);
            r.len = 2;
            return r;
        }
        fn public(_: std.Io, _: []const u8, port: u16) !ResolvedAddresses {
            var r: ResolvedAddresses = .{};
            r.items[0] = try std.Io.net.IpAddress.parse("8.8.8.8", port);
            r.len = 1;
            return r;
        }
        fn empty(_: std.Io, _: []const u8, _: u16) !ResolvedAddresses {
            return .{};
        }
        fn failed(_: std.Io, _: []const u8, _: u16) !ResolvedAddresses {
            return error.UnknownHostName;
        }
        fn wrongPort(io: std.Io, host: []const u8, _: u16) !ResolvedAddresses {
            return public(io, host, 1);
        }
        fn stalled(io: std.Io, _: []const u8, _: u16) !ResolvedAddresses {
            try std.Io.sleep(io, .fromSeconds(30), .awake);
            return .{};
        }
    };
    const a = std.testing.allocator;
    const url = "https://public-looking.example/hook";
    try std.testing.expectError(error.PrivateDestination, resolveDestination(a, url, false, Mock.mixed));
    const allowed = try resolveDestination(a, url, true, Mock.mixed);
    try std.testing.expectEqual(@as(u16, 443), allowed.getPort());
    _ = try resolveDestination(a, url, false, Mock.public);
    // The same hostname changing to a private address is rejected on the next send.
    try std.testing.expectError(error.PrivateDestination, resolveDestination(a, url, false, Mock.mixed));
    try std.testing.expectError(error.NoAddressReturned, resolveDestination(a, url, false, Mock.empty));
    try std.testing.expectError(error.UnknownHostName, resolveDestination(a, url, false, Mock.failed));
    try std.testing.expectError(error.InvalidConfig, resolveDestination(a, url, true, Mock.wrongPort));
    const started = GetTickCount64();
    try std.testing.expectError(error.Timeout, resolveDestination(a, url, false, Mock.stalled));
    try std.testing.expect(GetTickCount64() - started < 6_500);
}

test "E5.29 SSRF real resolver rejects localhost and opt-in permits it" {
    const a = std.testing.allocator;
    try std.testing.expectError(error.PrivateDestination, resolveDestination(a, "http://localhost/hook", false, lookupAddresses));
    const ip = try resolveDestination(a, "http://localhost:12345/hook", true, lookupAddresses);
    try std.testing.expect(privateAddress(ip));
    try std.testing.expectEqual(@as(u16, 12345), ip.getPort());
}

test "E5.29 SSRF migration preserves legacy rows with public-only policy" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    const migrator = db.Migrator.init(a);
    try migrator.migrate(conn, db.runtime_schema[0..44]);
    try std.testing.expectEqual(@as(i32, 44), try conn.getUserVersion());
    try std.testing.expectError(error.PrepareFailed, conn.prepare("SELECT allow_private FROM webhooks"));
    try conn.exec("INSERT INTO webhooks(direction,url,event,secret_encrypted) VALUES('out','http://127.0.0.1/hook','*','')");
    try migrator.migrate(conn, &db.runtime_schema);
    try migrator.migrate(conn, &db.runtime_schema);
    try std.testing.expectEqual(@as(i32, @intCast(db.runtime_schema.len)), try conn.getUserVersion());
    const json = try listJson(a, conn);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"allow_private\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "127.0.0.1/hook") != null);
    try std.testing.expectError(error.ExecFailed, conn.exec("UPDATE webhooks SET allow_private=2"));
    _ = try addConfig(a, conn, "{\"url\":\"http://127.0.0.1/hook\",\"allow_private\":true}");
    try queueTest(conn, 2);
    const Mock = struct {
        fn send(_: std.mem.Allocator, item: Delivery, _: []const u8, _: ?[]const u8) !void {
            try std.testing.expect(item.allow_private);
        }
    };
    try std.testing.expect(try processOne(a, conn, Mock.send));
    try std.testing.expectError(error.InvalidConfig, addConfig(a, conn, "{\"url\":\"http://127.0.0.1/\",\"allow_private\":\"true\"}"));
}

test "E5.29 SSRF socket pinned to checked numeric IP and redirects disabled" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var args: std.ArrayList([]const u8) = .empty;
    try appendDestinationArgs(a, &args, try std.Io.net.IpAddress.parse("8.8.8.8", 443));
    try std.testing.expectEqual(@as(usize, 5), args.items.len);
    for ([_][]const u8{ "--no-location", "--max-redirs", "0", "--connect-to", "::8.8.8.8:443" }, args.items) |expected, actual| try std.testing.expectEqualStrings(expected, actual);
    const ip6 = try connectionTarget(a, try std.Io.net.IpAddress.parse("2606:4700:4700::1111", 443));
    try std.testing.expectEqualStrings("::[2606:4700:4700:0:0:0:0:1111]:443", ip6);
}

pub const WebhookDirection = enum { in, out };

pub const Webhook = struct {
    id: i64,
    direction: WebhookDirection,
    url: []const u8,
    event: []const u8,
    secret_encrypted: ?[]const u8,
    active: bool,
    allow_private: bool = false,
};

pub const WebhookError = db.DbError || error{
    OutOfMemory,
    DispatchFailed,
    EncryptFailed,
    InvalidConfig,
    NotFound,
    DecryptFailed,
    SpawnFailed,
    PrivateDestination,
};

pub const SendFn = *const fn (url: []const u8, body: []const u8) WebhookError!void;

/// QA-A H12: qué pasó y qué hacer, en una frase, para la CLI y la C-ABI.
pub fn errorMessage(e: anyerror) []const u8 {
    return switch (e) {
        error.PrivateDestination => "el destino es una dirección privada o local (localhost, 127.x, 10.x, 172.16-31.x, 192.168.x, 169.254.x, ::1…); los avisos solo salen a direcciones públicas",
        error.InvalidConfig => "configuración no válida: la URL tiene que ser http o https, con servidor y sin usuario, consulta ni fragmento, y el evento uno de los admitidos",
        error.NotFound => "no existe ningún webhook con ese número (míralos con `devagents webhook list`)",
        error.EncryptFailed => "no se pudo cifrar el secreto con DPAPI",
        error.OutOfMemory => "memoria insuficiente",
        else => "no se pudo leer o guardar en runtime.db",
    };
}

pub const WebhookRegistry = struct {
    allocator: std.mem.Allocator,
    conn: db.Connection,

    pub fn init(allocator: std.mem.Allocator, conn: db.Connection) WebhookRegistry {
        return .{ .allocator = allocator, .conn = conn };
    }

    /// Add a webhook with a **plaintext** secret. The secret is encrypted via
    /// DPAPI before being stored in the database. This is the preferred API.
    /// Pass `null` for no secret.
    pub fn add(self: *WebhookRegistry, direction: WebhookDirection, url: []const u8, event: []const u8, secret_plaintext: ?[]const u8) WebhookError!void {
        return self.addWithPolicy(direction, url, event, secret_plaintext, false);
    }

    fn addWithPolicy(self: *WebhookRegistry, direction: WebhookDirection, url: []const u8, event: []const u8, secret_plaintext: ?[]const u8, allow_private: bool) WebhookError!void {
        try validateDestinationUrl(url, allow_private);
        if (event.len == 0 or event.len > 128) return error.InvalidConfig;
        if (secret_plaintext) |s| if (s.len == 0 or s.len > 1024) return error.InvalidConfig;
        const dir_str: []const u8 = if (direction == .in) "in" else "out";
        const stmt = try self.conn.prepare("INSERT INTO webhooks (direction, url, event, secret_encrypted, allow_private) VALUES (?1, ?2, ?3, ?4, ?5)");
        defer self.conn.finalize(stmt);
        try db.bindText(stmt, 1, dir_str);
        try db.bindText(stmt, 2, url);
        try db.bindText(stmt, 3, event);
        try db.bindInt(stmt, 5, @intFromBool(allow_private));
        if (secret_plaintext) |s| {
            // Encrypt plaintext secret via DPAPI before storing.
            const ciphertext = dpapi.encrypt(self.allocator, s) catch return error.EncryptFailed;
            defer self.allocator.free(ciphertext);
            // Store as blob (binary ciphertext), not text.
            if (db.c.sqlite3_bind_blob(stmt, 4, ciphertext.ptr, @intCast(ciphertext.len), db.SQLITE_TRANSIENT) != db.c.SQLITE_OK) return error.EncryptFailed;
        } else {
            try db.bindText(stmt, 4, "");
        }
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
    }

    /// Add a webhook with an **already-encrypted** secret blob.
    /// This is for backward compatibility / migration paths where the caller
    /// has already encrypted the secret via DPAPI. Prefer `add()` for new code.
    pub fn addEncrypted(self: *WebhookRegistry, direction: WebhookDirection, url: []const u8, event: []const u8, secret_encrypted_blob: ?[]const u8) WebhookError!void {
        try validateDestinationUrl(url, false);
        if (event.len == 0 or event.len > 128) return error.InvalidConfig;
        const dir_str: []const u8 = if (direction == .in) "in" else "out";
        const stmt = try self.conn.prepare("INSERT INTO webhooks (direction, url, event, secret_encrypted) VALUES (?1, ?2, ?3, ?4)");
        defer self.conn.finalize(stmt);
        try db.bindText(stmt, 1, dir_str);
        try db.bindText(stmt, 2, url);
        try db.bindText(stmt, 3, event);
        if (secret_encrypted_blob) |s| {
            if (db.c.sqlite3_bind_blob(stmt, 4, s.ptr, @intCast(s.len), db.SQLITE_TRANSIENT) != db.c.SQLITE_OK) return error.EncryptFailed;
        } else {
            try db.bindText(stmt, 4, "");
        }
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
    }

    pub fn remove(self: *WebhookRegistry, id: i64) WebhookError!void {
        if (id <= 0) return error.InvalidConfig;
        try self.conn.exec("BEGIN IMMEDIATE");
        var committed = false;
        defer if (!committed) self.conn.exec("ROLLBACK") catch |e| std.log.err("webhook delete rollback: {s}", .{@errorName(e)});
        const stmt = try self.conn.prepare("DELETE FROM webhooks WHERE id = ?1");
        defer self.conn.finalize(stmt);
        try db.bindInt(stmt, 1, id);
        if (db.c.sqlite3_step(stmt) != db.c.SQLITE_DONE) return error.StepFailed;
        if (self.conn.changes() == 0) return error.NotFound;
        const pending = try self.conn.prepare("DELETE FROM webhook_outbox WHERE webhook_id=?1");
        defer self.conn.finalize(pending);
        try db.bindInt(pending, 1, id);
        if (db.c.sqlite3_step(pending) != db.c.SQLITE_DONE) return error.StepFailed;
        try self.conn.exec("COMMIT");
        committed = true;
    }

    pub fn list(self: *WebhookRegistry, allocator: std.mem.Allocator) WebhookError![]Webhook {
        const stmt = try self.conn.prepare("SELECT id, direction, url, event, secret_encrypted, active, allow_private FROM webhooks ORDER BY id");
        defer self.conn.finalize(stmt);
        var webhooks: std.ArrayList(Webhook) = .empty;
        while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            const id = db.c.sqlite3_column_int64(stmt, 0);
            const dir_ptr = db.c.sqlite3_column_text(stmt, 1);
            const dir_len: usize = @intCast(db.c.sqlite3_column_bytes(stmt, 1));
            const url_ptr = db.c.sqlite3_column_text(stmt, 2);
            const url_len: usize = @intCast(db.c.sqlite3_column_bytes(stmt, 2));
            const evt_ptr = db.c.sqlite3_column_text(stmt, 3);
            const evt_len: usize = @intCast(db.c.sqlite3_column_bytes(stmt, 3));
            const secret_ptr = db.c.sqlite3_column_blob(stmt, 4);
            const secret_len: usize = @intCast(db.c.sqlite3_column_bytes(stmt, 4));
            const active_int = db.c.sqlite3_column_int(stmt, 5);

            const direction: WebhookDirection = if (dir_len == 2 and dir_ptr[0] == 'i' and dir_ptr[1] == 'n') .in else .out;

            const url_dup = allocator.alloc(u8, url_len) catch return error.OutOfMemory;
            @memcpy(url_dup, url_ptr[0..url_len]);

            const evt_dup = allocator.alloc(u8, evt_len) catch return error.OutOfMemory;
            @memcpy(evt_dup, evt_ptr[0..evt_len]);

            const secret = if (secret_len > 0 and secret_ptr != null) blk: {
                const s = allocator.alloc(u8, secret_len) catch return error.OutOfMemory;
                const blob_ptr: [*]const u8 = @ptrCast(secret_ptr.?);
                @memcpy(s, blob_ptr[0..secret_len]);
                break :blk s;
            } else null;

            try webhooks.append(allocator, .{
                .id = id,
                .direction = direction,
                .url = url_dup,
                .event = evt_dup,
                .secret_encrypted = secret,
                .active = active_int != 0,
                .allow_private = db.c.sqlite3_column_int(stmt, 6) != 0,
            });
        }
        return webhooks.toOwnedSlice(allocator);
    }

    pub fn dispatchForEvent(self: *WebhookRegistry, send: SendFn, event: []const u8, payload_json: []const u8) WebhookError!void {
        const stmt = try self.conn.prepare("SELECT url, event FROM webhooks WHERE direction = 'out' AND event = ?1 AND active = 1");
        defer self.conn.finalize(stmt);
        try db.bindText(stmt, 1, event);

        while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            const url_ptr = db.c.sqlite3_column_text(stmt, 0);
            const url_len: usize = @intCast(db.c.sqlite3_column_bytes(stmt, 0));
            const url = self.allocator.alloc(u8, url_len) catch return error.OutOfMemory;
            defer self.allocator.free(url);
            @memcpy(url, url_ptr[0..url_len]);

            try send(url, payload_json);
        }
    }
};

test "add and list webhooks" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    var reg = WebhookRegistry.init(allocator, conn);
    try reg.add(.out, "https://example.com/hook", "task.completed", null);
    const hooks = try reg.list(allocator);
    defer {
        for (hooks) |h| {
            allocator.free(h.url);
            allocator.free(h.event);
            if (h.secret_encrypted) |s| allocator.free(s);
        }
        allocator.free(hooks);
    }
    try std.testing.expectEqual(@as(usize, 1), hooks.len);
    try std.testing.expectEqual(WebhookDirection.out, hooks[0].direction);
    try std.testing.expectEqualStrings("https://example.com/hook", hooks[0].url);
}

test "remove webhook" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    var reg = WebhookRegistry.init(allocator, conn);
    try reg.add(.out, "https://x.com/hook", "task.completed", null);
    try reg.remove(1);
    const hooks = try reg.list(allocator);
    defer {
        for (hooks) |h| {
            allocator.free(h.url);
            allocator.free(h.event);
            if (h.secret_encrypted) |s| allocator.free(s);
        }
        allocator.free(hooks);
    }
    try std.testing.expectEqual(@as(usize, 0), hooks.len);
}

test "dispatch captures POST with mock send" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    var reg = WebhookRegistry.init(allocator, conn);
    try reg.add(.out, "https://example.com/ci", "task.completed", null);

    const sendFn = struct {
        fn dispatch(url: []const u8, body: []const u8) WebhookError!void {
            _ = url;
            _ = body;
        }
    }.dispatch;

    try reg.dispatchForEvent(sendFn, "task.completed", "{\"task\":\"done\"}");
}

test "dispatch only for matching event" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    var migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    var reg = WebhookRegistry.init(allocator, conn);
    try reg.add(.out, "https://example.com/ci", "task.completed", null);

    const sendFn = struct {
        fn dispatch(url: []const u8, body: []const u8) WebhookError!void {
            _ = url;
            _ = body;
            return error.DispatchFailed; // should never be called — event doesn't match
        }
    }.dispatch;

    try reg.dispatchForEvent(sendFn, "task.failed", "{}");
}

fn validateUrl(url: []const u8) WebhookError!void {
    if (url.len == 0 or url.len > 2048 or std.mem.indexOfAny(u8, url, "\r\n\t ") != null) return error.InvalidConfig;
    const uri = std.Uri.parse(url) catch return error.InvalidConfig;
    if ((!std.mem.eql(u8, uri.scheme, "https") and !std.mem.eql(u8, uri.scheme, "http")) or uri.host == null or uri.user != null or uri.password != null or uri.query != null or uri.fragment != null) return error.InvalidConfig;
    _ = try destinationHost(uri);
    if (uri.port == 0) return error.InvalidConfig;
}

fn destinationHost(uri: std.Uri) WebhookError![]const u8 {
    const component = uri.host orelse return error.InvalidConfig;
    var host = switch (component) {
        .raw => |s| s,
        .percent_encoded => |s| s,
    };
    // Do not allow curl and the resolver to interpret different authorities.
    if (std.mem.indexOfAny(u8, host, "%\\") != null) return error.InvalidConfig;
    if (std.mem.startsWith(u8, host, "[")) {
        if (!std.mem.endsWith(u8, host, "]")) return error.InvalidConfig;
        host = host[1 .. host.len - 1];
        _ = std.Io.net.IpAddress.parseIp6(host, 0) catch return error.InvalidConfig;
    } else {
        std.Io.net.HostName.validate(host) catch return error.InvalidConfig;
    }
    return host;
}

fn privateIp4(b: [4]u8) bool {
    return b[0] == 0 or b[0] == 10 or b[0] == 127 or b[0] >= 224 or
        (b[0] == 100 and b[1] >= 64 and b[1] <= 127) or
        (b[0] == 169 and b[1] == 254) or
        (b[0] == 172 and b[1] >= 16 and b[1] <= 31) or
        (b[0] == 192 and (b[1] == 168 or (b[1] == 0 and b[2] == 0))) or
        (b[0] == 198 and (b[1] == 18 or b[1] == 19));
}

fn privateAddress(ip: std.Io.net.IpAddress) bool {
    return switch (ip) {
        .ip4 => |v| privateIp4(v.bytes),
        .ip6 => |v| blk: {
            const b = v.bytes;
            if (std.mem.eql(u8, b[0..12], &[_]u8{ 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0xff, 0xff })) break :blk privateIp4(b[12..16].*);
            // Unspecified, loopback, ULA, link-local, multicast and translation
            // prefixes are outside global unicast. Teredo/6to4 can tunnel IPv4.
            break :blk (b[0] & 0xe0) != 0x20 or
                (b[0] == 0x20 and b[1] == 0x01 and b[2] == 0 and b[3] == 0) or
                (b[0] == 0x20 and b[1] == 0x02);
        },
    };
}

fn validateDestinationUrl(url: []const u8, allow_private: bool) WebhookError!void {
    try validateUrl(url);
    const host = try destinationHost(std.Uri.parse(url) catch return error.InvalidConfig);
    if (std.Io.net.IpAddress.parse(host, 0)) |ip| {
        if (!allow_private and privateAddress(ip)) return error.PrivateDestination;
    } else |_| {
        // Names are checked against their resolved addresses immediately before
        // delivery, including records changed after registration.
    }
}

const ResolvedAddresses = struct { items: [128]std.Io.net.IpAddress = undefined, len: usize = 0 };

fn lookupAddresses(io: std.Io, host: []const u8, port: u16) !ResolvedAddresses {
    var buffer: [128]std.Io.net.HostName.LookupResult = undefined;
    var queue: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&buffer);
    try (try std.Io.net.HostName.init(host)).lookup(io, &queue, .{ .port = port });
    var result: ResolvedAddresses = .{};
    while (queue.getOne(io)) |entry| {
        if (entry == .address) {
            if (result.len == result.items.len) return error.TooManyAddresses;
            result.items[result.len] = entry.address;
            result.len += 1;
        }
    } else |err| switch (err) {
        error.Closed => {},
        else => return err,
    }
    return result;
}

fn resolveDestination(a: std.mem.Allocator, url: []const u8, allow_private: bool, comptime resolver: anytype) !std.Io.net.IpAddress {
    try validateDestinationUrl(url, allow_private);
    const uri = try std.Uri.parse(url);
    const host = try destinationHost(uri);
    const port = uri.port orelse (if (std.mem.eql(u8, uri.scheme, "https")) @as(u16, 443) else @as(u16, 80));
    if (std.Io.net.IpAddress.parse(host, port)) |ip| return ip else |_| {}
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = threaded.io();
    const Outcome = union(enum) { resolved: @typeInfo(@TypeOf(resolver)).@"fn".return_type.?, timeout: std.Io.Cancelable!void };
    var results: [2]Outcome = undefined;
    var select: std.Io.Select(Outcome) = .init(io, &results);
    defer select.cancelDiscard();
    try select.concurrent(.resolved, resolver, .{ io, host, port });
    try select.concurrent(.timeout, std.Io.sleep, .{ io, std.Io.Duration.fromMilliseconds(5_000), .awake });
    const addresses = switch (try select.await()) {
        .resolved => |r| try r,
        .timeout => return error.Timeout,
    };
    if (addresses.len == 0) return error.NoAddressReturned;
    if (addresses.len > addresses.items.len) return error.TooManyAddresses;
    for (addresses.items[0..addresses.len]) |ip| {
        if (!allow_private and privateAddress(ip)) return error.PrivateDestination;
        if (ip.getPort() != port) return error.InvalidConfig;
    }
    // curl connects to this numeric address only: a second DNS answer cannot
    // rebind the socket. Host and TLS verification still use the original URL.
    return addresses.items[0];
}

fn connectionTarget(a: std.mem.Allocator, ip: std.Io.net.IpAddress) ![]u8 {
    return switch (ip) {
        .ip4 => |v| std.fmt.allocPrint(a, "::{d}.{d}.{d}.{d}:{d}", .{ v.bytes[0], v.bytes[1], v.bytes[2], v.bytes[3], v.port }),
        .ip6 => |v| std.fmt.allocPrint(a, "::[{x}:{x}:{x}:{x}:{x}:{x}:{x}:{x}]:{d}", .{
            std.mem.readInt(u16, v.bytes[0..2], .big),  std.mem.readInt(u16, v.bytes[2..4], .big),   std.mem.readInt(u16, v.bytes[4..6], .big),   std.mem.readInt(u16, v.bytes[6..8], .big),
            std.mem.readInt(u16, v.bytes[8..10], .big), std.mem.readInt(u16, v.bytes[10..12], .big), std.mem.readInt(u16, v.bytes[12..14], .big), std.mem.readInt(u16, v.bytes[14..16], .big),
            v.port,
        }),
    };
}

fn appendDestinationArgs(a: std.mem.Allocator, args: *std.ArrayList([]const u8), ip: std.Io.net.IpAddress) !void {
    const target = try connectionTarget(a, ip);
    try args.appendSlice(a, &.{ "--no-location", "--max-redirs", "0", "--connect-to", target });
}

pub fn addConfig(a: std.mem.Allocator, conn: db.Connection, config_json: []const u8) !i64 {
    if (config_json.len > 4096) return error.InvalidConfig;
    const Config = struct { url: []const u8, event: []const u8 = "*", secret: ?[]const u8 = null, format: []const u8 = "json", allow_private: bool = false };
    const parsed = std.json.parseFromSlice(Config, a, config_json, .{}) catch return error.InvalidConfig;
    defer parsed.deinit();
    const config = parsed.value;
    if (!std.mem.eql(u8, config.format, "json") and !std.mem.eql(u8, config.format, "ntfy")) return error.InvalidConfig;
    const events = [_][]const u8{ "*", "awaiting_approval", "done", "failed", "audit_unavailable", "budget_blocked" };
    var recognized = false;
    for (events) |event| if (std.mem.eql(u8, config.event, event)) {
        recognized = true;
        break;
    };
    if (!recognized) return error.InvalidConfig;
    try conn.exec("BEGIN IMMEDIATE");
    var committed = false;
    defer if (!committed) conn.exec("ROLLBACK") catch |e| std.log.err("webhook rollback: {s}", .{@errorName(e)});
    var reg = WebhookRegistry.init(a, conn);
    try reg.addWithPolicy(.out, config.url, config.event, config.secret, config.allow_private);
    const id = db.c.sqlite3_last_insert_rowid(conn.db);
    const s = try conn.prepare("UPDATE webhooks SET format=?1 WHERE id=?2");
    defer conn.finalize(s);
    try db.bindText(s, 1, config.format);
    try db.bindInt(s, 2, id);
    if (db.c.sqlite3_step(s) != db.c.SQLITE_DONE) return error.StepFailed;
    try conn.exec("COMMIT");
    committed = true;
    return id;
}

fn textColumn(s: *db.c.sqlite3_stmt, col: c_int) []const u8 {
    const p = db.c.sqlite3_column_text(s, col) orelse return "";
    return p[0..@intCast(db.c.sqlite3_column_bytes(s, col))];
}

pub fn listJson(a: std.mem.Allocator, conn: db.Connection) ![]u8 {
    const Item = struct { id: i64, url: []const u8, event: []const u8, format: []const u8, active: bool, has_secret: bool, allow_private: bool };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var items: std.ArrayList(Item) = .empty;
    const s = try conn.prepare("SELECT id,url,event,format,active,length(secret_encrypted)>0,allow_private FROM webhooks WHERE direction='out' ORDER BY id");
    defer conn.finalize(s);
    while (true) {
        const rc = db.c.sqlite3_step(s);
        if (rc == db.c.SQLITE_DONE) break;
        if (rc != db.c.SQLITE_ROW) return error.StepFailed;
        try items.append(aa, .{ .id = db.c.sqlite3_column_int64(s, 0), .url = try aa.dupe(u8, textColumn(s, 1)), .event = try aa.dupe(u8, textColumn(s, 2)), .format = try aa.dupe(u8, textColumn(s, 3)), .active = db.c.sqlite3_column_int(s, 4) != 0, .has_secret = db.c.sqlite3_column_int(s, 5) != 0, .allow_private = db.c.sqlite3_column_int(s, 6) != 0 });
    }
    return std.json.Stringify.valueAlloc(a, items.items, .{});
}

pub fn notificationsJson(a: std.mem.Allocator, conn: db.Connection, after_id: i64) ![]u8 {
    if (after_id < -1) return error.InvalidConfig;
    try purgeNotifications(conn, try retentionRows(a));
    const Item = struct { id: i64, order_id: i64, state: []const u8 };
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    var items: std.ArrayList(Item) = .empty;
    var cursor: i64 = @max(0, after_id);
    const query = if (after_id == -1) "SELECT COALESCE(MAX(id),0),0,'' FROM order_notifications" else "SELECT id,order_id,state FROM order_notifications WHERE id>?1 ORDER BY id LIMIT 128";
    const s = try conn.prepare(query);
    defer conn.finalize(s);
    if (after_id >= 0) try db.bindInt(s, 1, after_id);
    while (true) {
        const rc = db.c.sqlite3_step(s);
        if (rc == db.c.SQLITE_DONE) break;
        if (rc != db.c.SQLITE_ROW) return error.StepFailed;
        cursor = db.c.sqlite3_column_int64(s, 0);
        if (after_id != -1) try items.append(aa, .{ .id = cursor, .order_id = db.c.sqlite3_column_int64(s, 1), .state = try aa.dupe(u8, textColumn(s, 2)) });
    }
    return std.json.Stringify.valueAlloc(a, .{ .cursor = cursor, .items = items.items }, .{});
}

pub fn queueTest(conn: db.Connection, id: i64) !void {
    if (id <= 0) return error.InvalidConfig;
    const s = try conn.prepare("INSERT INTO webhook_outbox(webhook_id,event) SELECT id,'webhook_test' FROM webhooks WHERE id=?1 AND direction='out' AND active=1");
    defer conn.finalize(s);
    try db.bindInt(s, 1, id);
    if (db.c.sqlite3_step(s) != db.c.SQLITE_DONE) return error.StepFailed;
    if (conn.changes() == 0) return error.NotFound;
}

const Delivery = struct {
    id: i64,
    webhook_id: i64,
    order_id: i64,
    event: []const u8,
    url: []const u8,
    format: []const u8,
    secret_encrypted: []const u8,
    attempts: i64,
    allow_private: bool = false,
    timestamp: []const u8,
    delivery_id: []const u8,
};

fn claim(a: std.mem.Allocator, conn: db.Connection, now: i64) !?Delivery {
    try conn.exec("BEGIN IMMEDIATE");
    var committed = false;
    defer if (!committed) conn.exec("ROLLBACK") catch |e| std.log.err("webhook claim rollback: {s}", .{@errorName(e)});
    const expired = try conn.prepare("UPDATE webhook_outbox SET state='failed',last_error='Interrupted' WHERE state='sending' AND attempts>=3 AND next_at<=?1");
    defer conn.finalize(expired);
    try db.bindInt(expired, 1, now);
    if (db.c.sqlite3_step(expired) != db.c.SQLITE_DONE) return error.StepFailed;
    const s = try conn.prepare("SELECT o.id,o.webhook_id,o.order_id,o.event,w.url,w.format,w.secret_encrypted,o.attempts,w.allow_private FROM webhook_outbox o JOIN webhooks w ON w.id=o.webhook_id WHERE w.direction='out' AND w.active=1 AND o.attempts<3 AND o.state IN ('pending','sending') AND o.next_at<=?1 ORDER BY o.id LIMIT 1");
    defer conn.finalize(s);
    try db.bindInt(s, 1, now);
    const rc = db.c.sqlite3_step(s);
    if (rc == db.c.SQLITE_DONE) {
        try conn.exec("COMMIT");
        committed = true;
        return null;
    }
    if (rc != db.c.SQLITE_ROW) return error.StepFailed;
    const secret_ptr = db.c.sqlite3_column_blob(s, 6);
    const secret_len: usize = @intCast(db.c.sqlite3_column_bytes(s, 6));
    const secret: []const u8 = if (secret_ptr) |p| @as([*]const u8, @ptrCast(p))[0..secret_len] else "";
    var random: [16]u8 = undefined;
    if (BCryptGenRandom(null, &random, random.len, 2) != 0) return error.RandomFailed;
    defer std.crypto.secureZero(u8, &random);
    const delivery_id = std.fmt.bytesToHex(random, .lower);
    const item = Delivery{ .id = db.c.sqlite3_column_int64(s, 0), .webhook_id = db.c.sqlite3_column_int64(s, 1), .order_id = db.c.sqlite3_column_int64(s, 2), .event = try a.dupe(u8, textColumn(s, 3)), .url = try a.dupe(u8, textColumn(s, 4)), .format = try a.dupe(u8, textColumn(s, 5)), .secret_encrypted = try a.dupe(u8, secret), .attempts = db.c.sqlite3_column_int64(s, 7) + 1, .allow_private = db.c.sqlite3_column_int(s, 8) != 0, .timestamp = try std.fmt.allocPrint(a, "{d}", .{@divTrunc(now, 1000)}), .delivery_id = try a.dupe(u8, &delivery_id) };
    const update = try conn.prepare("UPDATE webhook_outbox SET state='sending', attempts=attempts+1,next_at=?1 WHERE id=?2");
    defer conn.finalize(update);
    try db.bindInt(update, 1, now + 10_000);
    try db.bindInt(update, 2, item.id);
    if (db.c.sqlite3_step(update) != db.c.SQLITE_DONE) return error.StepFailed;
    try conn.exec("COMMIT");
    committed = true;
    return item;
}

fn signature(timestamp: []const u8, delivery_id: []const u8, body: []const u8, secret: []const u8) [64]u8 {
    var mac: [32]u8 = undefined;
    defer std.crypto.secureZero(u8, &mac);
    var hmac = std.crypto.auth.hmac.sha2.HmacSha256.init(secret);
    defer std.crypto.secureZero(u8, std.mem.asBytes(&hmac));
    hmac.update(timestamp);
    hmac.update(".");
    hmac.update(delivery_id);
    hmac.update(".");
    hmac.update(body);
    hmac.final(&mac);
    return std.fmt.bytesToHex(mac, .lower);
}

const DeliverySend = *const fn (a: std.mem.Allocator, item: Delivery, body: []const u8, signature_hex: ?[]const u8) anyerror!void;

fn appendPayloadArgs(a: std.mem.Allocator, args: *std.ArrayList([]const u8)) !void {
    // Sensitive headers and the exact body are consumed from stdin, never argv.
    try args.appendSlice(a, &.{ "--config", "-" });
}

fn appendCurlValue(a: std.mem.Allocator, config: *std.ArrayList(u8), value: []const u8) !void {
    try config.append(a, '"');
    for (value) |char| switch (char) {
        '\\' => try config.appendSlice(a, "\\\\"),
        '"' => try config.appendSlice(a, "\\\""),
        '\n' => try config.appendSlice(a, "\\n"),
        '\r' => try config.appendSlice(a, "\\r"),
        '\t' => try config.appendSlice(a, "\\t"),
        '\x0b' => try config.appendSlice(a, "\\v"),
        0...8, 12, 14...31, 127 => return error.InvalidConfig,
        else => try config.append(a, char),
    };
    try config.appendSlice(a, "\"\n");
}

fn curlRequestConfig(a: std.mem.Allocator, item: Delivery, body: []const u8, signature_hex: ?[]const u8) ![]u8 {
    var config: std.ArrayList(u8) = .empty;
    errdefer {
        std.crypto.secureZero(u8, config.items);
        config.deinit(a);
    }
    try appendCurlHeader(a, &config, "X-DevAgents-Timestamp", item.timestamp);
    try appendCurlHeader(a, &config, "X-DevAgents-Delivery", item.delivery_id);
    if (signature_hex) |sig| {
        const header = try std.fmt.allocPrint(a, "X-DevAgents-Signature: sha256={s}", .{sig});
        defer {
            std.crypto.secureZero(u8, header);
            a.free(header);
        }
        try config.appendSlice(a, "header = ");
        try appendCurlValue(a, &config, header);
    }
    try config.appendSlice(a, "data-binary = ");
    try appendCurlValue(a, &config, body);
    return config.toOwnedSlice(a);
}

fn appendCurlHeader(a: std.mem.Allocator, config: *std.ArrayList(u8), name: []const u8, value: []const u8) !void {
    const header = try std.fmt.allocPrint(a, "{s}: {s}", .{ name, value });
    defer a.free(header);
    try config.appendSlice(a, "header = ");
    try appendCurlValue(a, config, header);
}

const CurlRequest = struct { args: []const []const u8, stdin_data: []u8 };

fn curlRequest(a: std.mem.Allocator, item: Delivery, body: []const u8, signature_hex: ?[]const u8, seconds: []const u8, ip: std.Io.net.IpAddress) !CurlRequest {
    var args: std.ArrayList([]const u8) = .empty;
    defer args.deinit(a);
    try args.appendSlice(a, &.{ "--disable", "--globoff", "--silent", "--show-error", "--fail", "--max-time", seconds, "--connect-timeout", seconds, "--noproxy", "*", "--proto", "=http,https", "--write-out", "%{http_code}", "--output", "NUL", "--request", "POST", "--header", if (std.mem.eql(u8, item.format, "ntfy")) "Content-Type: text/plain; charset=utf-8" else "Content-Type: application/json" });
    try appendPayloadArgs(a, &args);
    try appendDestinationArgs(a, &args, ip);
    if (std.mem.eql(u8, item.format, "ntfy")) {
        const title = try std.fmt.allocPrint(a, "Title: DevAgents - orden {d}", .{item.order_id});
        const urgent = std.mem.eql(u8, item.event, "failed") or std.mem.eql(u8, item.event, "budget_blocked") or std.mem.eql(u8, item.event, "audit_unavailable");
        try args.appendSlice(a, &.{ "--header", title, "--header", if (urgent) "Priority: 4" else "Priority: 3", "--header", if (urgent) "Tags: warning" else "Tags: clipboard" });
    }
    try args.appendSlice(a, &.{ "--url", item.url });
    const config = try curlRequestConfig(a, item, body, signature_hex);
    errdefer {
        std.crypto.secureZero(u8, config);
        a.free(config);
    }
    return .{ .args = try args.toOwnedSlice(a), .stdin_data = config };
}

fn deliverNative(a: std.mem.Allocator, item: Delivery, body: []const u8, signature_hex: ?[]const u8) !void {
    const started = GetTickCount64();
    const ip = try resolveDestination(a, item.url, item.allow_private, lookupAddresses);
    const elapsed_ms = GetTickCount64() - started;
    if (elapsed_ms >= 5_000) return error.Timeout;
    const remaining_ms: u32 = @intCast(5_000 - elapsed_ms);
    const seconds = try std.fmt.allocPrint(a, "{d}.{d:0>3}", .{ remaining_ms / 1000, remaining_ms % 1000 });
    // T9: en Linux el curl fijado es el del sistema (/usr/bin/curl); igual
    // que System32 en Windows, nunca el que aparezca en el PATH.
    const dir = if (@import("builtin").os.tag == .windows) blk: {
        var system_dir: [512]u16 = undefined;
        const n = GetSystemDirectoryW(&system_dir, system_dir.len);
        if (n == 0 or n >= system_dir.len) return error.SpawnFailed;
        break :blk try std.unicode.utf16LeToUtf8Alloc(a, system_dir[0..n]);
    } else try a.dupe(u8, "/usr/bin");
    const curl = try std.fs.path.join(a, &.{ dir, if (@import("builtin").os.tag == .windows) "curl.exe" else "curl" });
    const request = try curlRequest(a, item, body, signature_hex, seconds, ip);
    defer {
        std.crypto.secureZero(u8, request.stdin_data);
        a.free(request.stdin_data);
        a.free(request.args);
    }
    const result = try executor.runVerifierPinned(a, .{ .workspace_root = dir, .timeout_ms = remaining_ms, .max_output_bytes = 4096, .stdin_data = request.stdin_data }, curl, request.args, dir);
    if (result.timed_out) return error.Timeout;
    if (result.exit_code == 28) return error.Timeout;
    if (result.exit_code != 0) return error.DispatchFailed;
    const status = std.fmt.parseInt(u16, std.mem.trim(u8, result.stdout, "\r\n "), 10) catch return error.InvalidResponse;
    if (status >= 300 and status < 400) return error.RedirectRejected;
    if (status < 200 or status >= 300) return error.DispatchFailed;
}

pub fn processOne(a: std.mem.Allocator, conn: db.Connection, send: ?DeliverySend) !bool {
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const aa = arena.allocator();
    try purgeNotifications(conn, try retentionRows(aa));
    const item = (try claim(aa, conn, try deliveryNowMillis(conn))) orelse return false;
    const ntfy = std.mem.eql(u8, item.format, "ntfy");
    const body = if (ntfy) try std.fmt.allocPrint(aa, "Orden {d}: {s}", .{ item.order_id, item.event }) else try std.json.Stringify.valueAlloc(aa, .{ .version = @as(u8, 1), .order_id = item.order_id, .event = item.event }, .{});
    var sig: ?[64]u8 = null;
    defer if (sig) |*s| std.crypto.secureZero(u8, s);
    var failure: ?[]const u8 = null;
    if (item.secret_encrypted.len > 0) {
        if (dpapi.decrypt(aa, item.secret_encrypted)) |secret| {
            defer std.crypto.secureZero(u8, @constCast(secret));
            sig = signature(item.timestamp, item.delivery_id, body, secret);
        } else |e| failure = @errorName(e);
    }
    if (failure == null) (send orelse deliverNative)(aa, item, body, if (sig) |*s| s else null) catch |e| {
        failure = @errorName(e);
    };
    try finishAttempt(conn, item.id, item.attempts, failure);
    return true;
}

fn deliveryNowMillis(conn: db.Connection) !i64 {
    const s = try conn.prepare("SELECT CAST(strftime('%s','now') AS INTEGER) * 1000");
    defer conn.finalize(s);
    if (db.c.sqlite3_step(s) != db.c.SQLITE_ROW) return error.StepFailed;
    return validDeliveryClock(db.c.sqlite3_column_int64(s, 0));
}

fn validDeliveryClock(now: i64) !i64 {
    if (now <= 0) return error.ClockUnavailable;
    return now;
}

fn parseRetention(value: []const u8) !i64 {
    const keep = std.fmt.parseInt(i64, value, 10) catch return error.InvalidRetention;
    if (keep < 128 or keep > 100_000) return error.InvalidRetention;
    return keep;
}

fn retentionRows(a: std.mem.Allocator) !i64 {
    const value = (try @import("headless_adapter.zig").defaultGetEnv(a, "DEVAGENTS_NOTIFICATION_RETENTION_ROWS")) orelse return 4096;
    defer a.free(value);
    // Ausente o vacía: el valor por defecto, como dice docs/WEBHOOK-VERIFICACION.md.
    if (std.mem.trim(u8, value, " \t").len == 0) return 4096;
    return parseRetention(value);
}

fn purgeNotifications(conn: db.Connection, keep: i64) !void {
    if (keep < 128 or keep > 100_000) return error.InvalidRetention;
    // Work stays queued. Preserve the newest IDs, so the notification cursor
    // never reuses an identity even though the legacy table is not AUTOINCREMENT.
    for ([_][]const u8{
        "DELETE FROM webhook_outbox WHERE id IN (SELECT id FROM webhook_outbox WHERE state IN ('sent','failed') AND id<=(SELECT COALESCE(MAX(id),0)-?1 FROM webhook_outbox) ORDER BY id LIMIT 128)",
        "DELETE FROM order_notifications WHERE id IN (SELECT id FROM order_notifications WHERE id<=(SELECT COALESCE(MAX(id),0)-?1 FROM order_notifications) ORDER BY id LIMIT 128)",
    }) |sql| {
        const s = try conn.prepare(sql);
        defer conn.finalize(s);
        try db.bindInt(s, 1, keep);
        if (db.c.sqlite3_step(s) != db.c.SQLITE_DONE) return error.StepFailed;
    }
}

fn finishAttempt(conn: db.Connection, id: i64, attempts: i64, failure: ?[]const u8) !void {
    const s = try conn.prepare("UPDATE webhook_outbox SET state=?1,last_error=?2,next_at=?3 WHERE id=?4 AND state='sending' AND attempts=?5");
    defer conn.finalize(s);
    try db.bindText(s, 1, if (failure == null) "sent" else if (attempts >= 3) "failed" else "pending");
    // Only internal error names are persisted; never response bodies or URLs.
    try db.bindText(s, 2, failure orelse "");
    try db.bindInt(s, 3, health.nowMillis(conn) + 1_000);
    try db.bindInt(s, 4, id);
    try db.bindInt(s, 5, attempts);
    if (db.c.sqlite3_step(s) != db.c.SQLITE_DONE) return error.StepFailed;
}

pub const Dispatcher = struct {
    allocator: std.mem.Allocator,
    path: []const u8,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    thread: ?std.Thread = null,

    pub fn start(a: std.mem.Allocator, path: []const u8) !*Dispatcher {
        if (std.mem.eql(u8, path, ":memory:")) return error.InvalidConfig;
        const self = try a.create(Dispatcher);
        errdefer a.destroy(self);
        self.* = .{ .allocator = a, .path = try a.dupe(u8, path) };
        errdefer a.free(self.path);
        self.thread = try std.Thread.spawn(.{}, run, .{self});
        return self;
    }

    pub fn deinit(self: *Dispatcher) void {
        self.stop.store(true, .release);
        if (self.thread) |t| t.join();
        const a = self.allocator;
        a.free(self.path);
        a.destroy(self);
    }

    fn run(self: *Dispatcher) void {
        var conn = db.Connection.open(self.allocator, self.path) catch |e| {
            std.log.err("webhook worker open: {s}", .{@errorName(e)});
            return;
        };
        defer conn.close();
        while (!self.stop.load(.acquire)) {
            _ = processOne(self.allocator, conn, null) catch |e| std.log.err("webhook worker: {s}", .{@errorName(e)});
            Sleep(100);
        }
    }
};

test "E5.29 webhook config validates URL format bounds and encrypted redacted listing" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
    const id = try addConfig(a, conn, "{\"url\":\"https://ntfy.sh/topic\",\"format\":\"ntfy\",\"secret\":\"fixture\"}");
    try std.testing.expect(id > 0);
    const json = try listJson(a, conn);
    defer a.free(json);
    try std.testing.expect(std.mem.indexOf(u8, json, "fixture") == null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"has_secret\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, json, "\"format\":\"ntfy\"") != null);
    for ([_][]const u8{ "ftp://example.test/a", "http://user:pass@example.test/a", "http://example.test/a?q=secret", "http://example.test/a#secret", "http://example.test/\r\nX: a", "" }) |url| try std.testing.expectError(error.InvalidConfig, validateUrl(url));
    for ([_][]const u8{ "{}", "{\"url\":\"https://example.test\",\"extra\":true}", "{\"url\":\"https://example.test\",\"format\":\"unknown\"}", "{\"url\":\"https://example.test\",\"secret\":\"\"}", "{\"url\":\"https://example.test\",\"event\":\"\"}", "{\"url\":\"https://example.test\",\"event\":\"unknown\"}" }) |config| try std.testing.expectError(error.InvalidConfig, addConfig(a, conn, config));
    try std.testing.expectError(error.InvalidConfig, queueTest(conn, 0));
    try std.testing.expectError(error.NotFound, queueTest(conn, 99));
    var reg = WebhookRegistry.init(a, conn);
    try std.testing.expectError(error.NotFound, reg.remove(99));
    try std.testing.expectError(error.InvalidConfig, reg.remove(-1));
    try conn.exec("DROP TABLE webhooks");
    try std.testing.expectError(error.PrepareFailed, listJson(a, conn));
    try std.testing.expectError(error.PrepareFailed, reg.add(.out, "https://example.test", "done", null));
}

test "E5.29 migration transitions notifications outbox and HMAC signing preserve state authority" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    const migrator = db.Migrator.init(a);
    try migrator.migrate(conn, db.runtime_schema[0..43]);
    try std.testing.expectEqual(@as(i32, 43), try conn.getUserVersion());
    try std.testing.expectError(error.PrepareFailed, conn.prepare("SELECT id FROM webhook_outbox"));
    try conn.exec("INSERT INTO webhooks(direction,url,event) VALUES('out','https://example.test','*')");
    try migrator.migrate(conn, &db.runtime_schema);
    try std.testing.expectEqual(@as(i32, @intCast(db.runtime_schema.len)), try conn.getUserVersion());
    try conn.exec("INSERT INTO orders(id,project_id,user_prompt,status,created_at) VALUES(1,'fixture','secret prompt','running',1)");
    try conn.exec("UPDATE orders SET status='awaiting_approval' WHERE id=1");
    try conn.exec("UPDATE orders SET status='awaiting_approval' WHERE id=1");
    try std.testing.expect(try conn.tryCommitTerminal(1, "done", "order_done", "fixture", "{}", 2));
    try std.testing.expect(!try conn.tryCommitTerminal(1, "failed", "order_failed", "fixture", "{}", 3));
    try conn.exec("INSERT INTO orders(id,project_id,user_prompt,status,created_at) VALUES(2,'fixture','fixture','running',1),(3,'fixture','fixture','running',1)");
    try std.testing.expect(try conn.tryCommitTerminal(2, "failed", "order_failed", "fixture", "{}", 2));
    try std.testing.expect(try conn.tryCommitTerminal(3, "audit_unavailable", "order_audit_unavailable_v1", "fixture", "{}", 2));
    try conn.exec("INSERT INTO events(ts,source,kind,payload_json,order_id) VALUES(3,'fixture','budget_blocked_v1','{}',3)");
    const notices = try notificationsJson(a, conn, 0);
    defer a.free(notices);
    const parsed = try std.json.parseFromSlice(std.json.Value, a, notices, .{});
    defer parsed.deinit();
    try std.testing.expectEqual(@as(usize, 5), parsed.value.object.get("items").?.array.items.len);
    try std.testing.expect(std.mem.indexOf(u8, notices, "secret prompt") == null);
    const initialized = try notificationsJson(a, conn, -1);
    defer a.free(initialized);
    try std.testing.expect(std.mem.indexOf(u8, initialized, "\"items\":[]") != null);
    try std.testing.expectError(error.InvalidConfig, notificationsJson(a, conn, -2));
    const Mock = struct {
        fn send(_: std.mem.Allocator, item: Delivery, body: []const u8, sig: ?[]const u8) !void {
            try std.testing.expect(item.order_id > 0);
            try std.testing.expect(std.mem.indexOf(u8, body, "secret prompt") == null);
            try std.testing.expect(sig == null);
        }
    };
    var count: usize = 0;
    while (try processOne(a, conn, Mock.send)) count += 1;
    try std.testing.expectEqual(@as(usize, 5), count);
    const sent = try conn.prepare("SELECT COUNT(*) FROM webhook_outbox WHERE state='sent'");
    defer conn.finalize(sent);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(sent));
    try std.testing.expectEqual(@as(i64, 5), db.c.sqlite3_column_int64(sent, 0));
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(sent));
    const mac = signature("1728000000", "abcdef0123456789", "body", "fixture");
    try std.testing.expectEqualStrings("ca83884838ccd28f4e8ef4b195fa4d15e71552fb1597b4fb3a88a3b11baeef8d", &mac);
    try conn.exec("DROP TABLE order_notifications");
    try std.testing.expectError(error.PrepareFailed, notificationsJson(a, conn, 0));
}

test "E5.29 wildcard filtering signing ntfy retry cap and decryption failures" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
    const id = try addConfig(a, conn, "{\"url\":\"https://ntfy.sh/topic\",\"format\":\"ntfy\",\"secret\":\"fixture\"}");
    var reg = WebhookRegistry.init(a, conn);
    try reg.add(.in, "https://example.test", "*", null);
    try reg.add(.out, "https://example.test", "failed", null);
    try conn.exec("UPDATE webhooks SET active=0 WHERE id=3");
    try conn.exec("INSERT INTO orders(id,project_id,user_prompt,status,created_at) VALUES(1,'fixture','fixture','running',1)");
    try conn.exec("UPDATE orders SET status='awaiting_approval' WHERE id=1");
    const Mock = struct {
        fn send(_: std.mem.Allocator, item: Delivery, body: []const u8, sig: ?[]const u8) !void {
            try std.testing.expectEqualStrings("ntfy", item.format);
            try std.testing.expectEqualStrings("Orden 1: awaiting_approval", body);
            const expected = signature(item.timestamp, item.delivery_id, body, "fixture");
            try std.testing.expectEqualStrings(&expected, sig orelse return error.MissingSignature);
            return error.DispatchFailed;
        }
        fn forbidden(_: std.mem.Allocator, _: Delivery, _: []const u8, _: ?[]const u8) !void {
            return error.ShouldNeverSend;
        }
    };
    for (0..3) |_| {
        try conn.exec("UPDATE webhook_outbox SET next_at=0");
        try std.testing.expect(try processOne(a, conn, Mock.send));
    }
    try conn.exec("UPDATE webhook_outbox SET next_at=0");
    try std.testing.expect(!try processOne(a, conn, Mock.send));
    const s = try conn.prepare("SELECT attempts,state,last_error FROM webhook_outbox");
    defer conn.finalize(s);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(s));
    try std.testing.expectEqual(@as(i64, 3), db.c.sqlite3_column_int64(s, 0));
    try std.testing.expectEqualStrings("failed", textColumn(s, 1));
    try std.testing.expectEqualStrings("DispatchFailed", textColumn(s, 2));
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(s));
    try queueTest(conn, id);
    try conn.exec("UPDATE webhooks SET secret_encrypted='invalid encrypted fixture' WHERE id=1");
    try std.testing.expect(try processOne(a, conn, Mock.forbidden));
    const fail = try conn.prepare("SELECT last_error FROM webhook_outbox WHERE event='webhook_test'");
    defer conn.finalize(fail);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(fail));
    try std.testing.expectEqualStrings("DecryptFailed", textColumn(fail, 0));
    try std.testing.expectError(error.InvalidConfig, Dispatcher.start(a, ":memory:"));
}

test "E5.29 leases suppress simultaneous claims and recover exhausted sender crash" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
    const id = try addConfig(a, conn, "{\"url\":\"https://example.test\"}");
    try queueTest(conn, id);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    try std.testing.expect((try claim(arena.allocator(), conn, 100)) != null);
    try std.testing.expect((try claim(arena.allocator(), conn, 101)) == null);
    try conn.exec("UPDATE webhook_outbox SET attempts=3,next_at=100");
    try std.testing.expect((try claim(arena.allocator(), conn, 200)) == null);
    const s = try conn.prepare("SELECT state,last_error FROM webhook_outbox");
    defer conn.finalize(s);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(s));
    try std.testing.expectEqualStrings("failed", textColumn(s, 0));
    try std.testing.expectEqualStrings("Interrupted", textColumn(s, 1));
}

test "E5.29 deleting hook discards pending jobs and never reuses delivery identity" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
    const first = try addConfig(a, conn, "{\"url\":\"https://old.example.test\"}");
    try queueTest(conn, first);
    try queueTest(conn, first);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const old_claim = (try claim(arena.allocator(), conn, 100)).?;
    var registry = WebhookRegistry.init(a, conn);
    try registry.remove(first);
    const replacement = try addConfig(a, conn, "{\"url\":\"https://new.example.test\"}");
    try std.testing.expect((try claim(arena.allocator(), conn, 101)) == null);
    try queueTest(conn, replacement);
    const new_claim = (try claim(arena.allocator(), conn, 200)).?;
    try std.testing.expect(new_claim.id != old_claim.id);
    try std.testing.expectEqualStrings("https://new.example.test", new_claim.url);
}

test "E5.29 stale sender completion cannot overwrite a reclaimed attempt" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
    const hook = try addConfig(a, conn, "{\"url\":\"https://example.test\"}");
    try queueTest(conn, hook);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const first = (try claim(arena.allocator(), conn, 100)).?;
    const second = (try claim(arena.allocator(), conn, 20_000)).?;
    try std.testing.expectEqual(first.id, second.id);
    try std.testing.expectEqual(@as(i64, 2), second.attempts);
    try finishAttempt(conn, first.id, first.attempts, null);
    try std.testing.expectEqual(@as(i64, 0), conn.changes());
    try finishAttempt(conn, second.id, second.attempts, null);
    try std.testing.expectEqual(@as(i64, 1), conn.changes());
}

test "HARD6. signature binds timestamp delivery and exact body" {
    const mac = signature("1728000000", "abcdef0123456789", "body", "fixture");
    try std.testing.expectEqualStrings("ca83884838ccd28f4e8ef4b195fa4d15e71552fb1597b4fb3a88a3b11baeef8d", &mac);
    for ([_][3][]const u8{
        .{ "1728000001", "abcdef0123456789", "body" },
        .{ "1728000000", "abcdef0123456780", "body" },
        .{ "1728000000", "abcdef0123456789", "body\n" },
    }) |changed| {
        const other = signature(changed[0], changed[1], changed[2], "fixture");
        try std.testing.expect(!std.mem.eql(u8, &mac, &other));
    }
}

test "HARD6. curl configuration carries signature only on stdin" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const item = Delivery{ .id = 1, .webhook_id = 1, .order_id = 1, .event = "done", .url = "https://example.test/hook", .format = "json", .secret_encrypted = "", .attempts = 1, .timestamp = "1728000000", .delivery_id = "abcdef0123456789" };
    const config = try curlRequestConfig(a, item, "{\"event\":\"done\"}\n", "sigtest");
    try std.testing.expect(std.mem.indexOf(u8, config, "header = \"X-DevAgents-Timestamp: 1728000000\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "header = \"X-DevAgents-Delivery: abcdef0123456789\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "header = \"X-DevAgents-Signature: sha256=sigtest\"\n") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "data-binary = \"{\\\"event\\\":\\\"done\\\"}\\n\"\n") != null);
    var args: std.ArrayList([]const u8) = .empty;
    try appendPayloadArgs(a, &args);
    try std.testing.expectEqual(@as(usize, 2), args.items.len);
    try std.testing.expectEqualStrings("--config", args.items[0]);
    try std.testing.expectEqualStrings("-", args.items[1]);
    for (args.items) |arg| try std.testing.expect(std.mem.indexOf(u8, arg, "sigtest") == null);
    const request = try curlRequest(a, item, "{\"event\":\"done\"}\n", "sigtest", "5.000", try std.Io.net.IpAddress.parse("8.8.8.8", 443));
    try std.testing.expectEqualStrings(config, request.stdin_data);
    for (request.args) |arg| {
        try std.testing.expect(std.mem.indexOf(u8, arg, "sigtest") == null);
        try std.testing.expect(std.mem.indexOf(u8, arg, "X-DevAgents-Signature") == null);
    }
    const unsigned = try curlRequestConfig(a, item, "ntfy\\body\r\t\x0b", null);
    try std.testing.expect(std.mem.indexOf(u8, unsigned, "Signature") == null);
    try std.testing.expect(std.mem.indexOf(u8, unsigned, "ntfy\\\\body\\r\\t\\v") != null);
    try std.testing.expectError(error.InvalidConfig, curlRequestConfig(a, item, "body\x00", null));
}

test "HARD6. claims use fresh timestamp and random delivery identity" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
    const hook = try addConfig(a, conn, "{\"url\":\"https://example.test\"}");
    try queueTest(conn, hook);
    var arena = std.heap.ArenaAllocator.init(a);
    defer arena.deinit();
    const first = (try claim(arena.allocator(), conn, 1_728_000_000_000)).?;
    const second = (try claim(arena.allocator(), conn, 1_728_000_010_000)).?;
    try std.testing.expectEqualStrings("1728000000", first.timestamp);
    try std.testing.expectEqualStrings("1728000010", second.timestamp);
    try std.testing.expectEqual(@as(usize, 32), first.delivery_id.len);
    try std.testing.expectEqual(@as(usize, 32), second.delivery_id.len);
    try std.testing.expect(!std.mem.eql(u8, first.delivery_id, second.delivery_id));
}

test "HARD6. clock failure cannot produce a fabricated delivery timestamp" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try std.testing.expect(try deliveryNowMillis(conn) > 0);
    try std.testing.expectEqual(@as(i64, 1728), try validDeliveryClock(1728));
    try std.testing.expectError(error.ClockUnavailable, validDeliveryClock(0));
    try std.testing.expectError(error.ClockUnavailable, validDeliveryClock(-1));
    try std.testing.expectError(error.PrepareFailed, deliveryNowMillis(.{ .allocator = a, .db = null }));
}

test "HARD10. retention validates bounds and purges bounded batches preserving queued work" {
    const a = std.testing.allocator;
    for ([_][]const u8{ "", "127", "100001", "-1", "1.2", "text" }) |value| try std.testing.expectError(error.InvalidRetention, parseRetention(value));
    try std.testing.expectEqual(@as(i64, 128), try parseRetention("128"));
    try std.testing.expectEqual(@as(i64, 100_000), try parseRetention("100000"));
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
    try conn.exec("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<400) INSERT INTO order_notifications(id,order_id,state) SELECT x,1,'done' FROM n");
    try conn.exec("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<400) INSERT INTO webhook_outbox(id,webhook_id,event,state,next_at) SELECT x,1,'done',CASE WHEN x=1 THEN 'pending' WHEN x=2 THEN 'sending' ELSE 'sent' END,0 FROM n");
    try purgeNotifications(conn, 128);
    const first = try conn.prepare("SELECT (SELECT COUNT(*) FROM order_notifications),(SELECT COUNT(*) FROM webhook_outbox),(SELECT COUNT(*) FROM webhook_outbox WHERE id IN (1,2))");
    defer conn.finalize(first);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(first));
    try std.testing.expectEqual(@as(i64, 272), db.c.sqlite3_column_int64(first, 0));
    try std.testing.expectEqual(@as(i64, 272), db.c.sqlite3_column_int64(first, 1));
    try std.testing.expectEqual(@as(i64, 2), db.c.sqlite3_column_int64(first, 2));
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(first));
    try purgeNotifications(conn, 128);
    try purgeNotifications(conn, 128);
    const final = try conn.prepare("SELECT (SELECT COUNT(*) FROM order_notifications),(SELECT COUNT(*) FROM webhook_outbox),(SELECT MIN(id) FROM order_notifications)");
    defer conn.finalize(final);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(final));
    try std.testing.expectEqual(@as(i64, 128), db.c.sqlite3_column_int64(final, 0));
    try std.testing.expectEqual(@as(i64, 130), db.c.sqlite3_column_int64(final, 1));
    try std.testing.expectEqual(@as(i64, 273), db.c.sqlite3_column_int64(final, 2));
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(final));
    try std.testing.expectError(error.InvalidRetention, purgeNotifications(conn, 0));
    try conn.exec("DROP TABLE webhook_outbox");
    try std.testing.expectError(error.PrepareFailed, purgeNotifications(conn, 128));
}

test "HARD10. purge is wired into dispatcher and notification polling" {
    const a = std.testing.allocator;
    const keep = try retentionRows(a);
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    try db.Migrator.init(a).migrate(conn, &db.runtime_schema);
    const fill = try conn.prepare("WITH RECURSIVE n(x) AS (SELECT 1 UNION ALL SELECT x+1 FROM n WHERE x<?1) INSERT INTO order_notifications(id,order_id,state) SELECT x,1,'done' FROM n");
    defer conn.finalize(fill);
    try db.bindInt(fill, 1, keep + 204);
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(fill));
    try std.testing.expect(!try processOne(a, conn, null));
    const count = try conn.prepare("SELECT COUNT(*) FROM order_notifications");
    defer conn.finalize(count);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(count));
    try std.testing.expectEqual(keep + 76, db.c.sqlite3_column_int64(count, 0));
    try std.testing.expectEqual(db.c.SQLITE_DONE, db.c.sqlite3_step(count));
    try std.testing.expectEqual(db.c.SQLITE_OK, db.c.sqlite3_reset(count));
    const polled = try notificationsJson(a, conn, -1);
    defer a.free(polled);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(count));
    try std.testing.expectEqual(keep, db.c.sqlite3_column_int64(count, 0));
}
