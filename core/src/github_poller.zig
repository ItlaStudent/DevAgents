const std = @import("std");
const db = @import("db.zig");
const health = @import("health.zig");
const sync = @import("sync.zig");
const providers = @import("providers");
const gh_mod = providers.github;
const gitea_mod = providers.gitea;
const ship_flow = @import("ship_flow.zig");

pub const PollerStatus = struct {
    active_prs: usize = 0,
    is_running: bool = false,
    interval_ms: u64 = 30000,
    race_prevented_count: u32 = 0,
};

pub const GitHubPoller = struct {
    allocator: std.mem.Allocator,
    conn: db.Connection,
    gh: gh_mod.GitHubConnector,
    /// T4-GITEA: conector REST para filas provider='gitea' (el remote del
    /// proyecto ES Gitea — la mayoría de los PRs reales pasarán por aquí).
    gitea: gitea_mod.GiteaConnector,
    status: PollerStatus = .{},
    mutex: sync.Mutex = sync.Mutex.init(),

    pub fn init(allocator: std.mem.Allocator, conn: db.Connection, token: ?[]const u8) GitHubPoller {
        return .{
            .allocator = allocator,
            .conn = conn,
            .gh = gh_mod.GitHubConnector.init(allocator, token),
            .gitea = gitea_mod.GiteaConnector.init(allocator),
        };
    }

    pub fn deinit(self: *GitHubPoller) void {
        self.gh.deinit();
        self.gitea.deinit();
    }

    /// Estado por REST y credencial propia de cada host; `gh` sólo cuando se
    /// selecciona explícitamente la ruta alternativa. Sin
    /// credencial devuelve null y la fila se deja como está — nunca un estado
    /// fingido para rellenar el ciclo.
    fn stateForRow(self: *GitHubPoller, provider: []const u8, repo: []const u8, pr_num: i64, url: []const u8) ?gh_mod.PullRequestState {
        if (self.gh.rest_enabled) {
            const kind = std.meta.stringToEnum(gh_mod.Forge, provider) orelse {
                self.gh.setLastError("", "unknown forge provider");
                return null;
            };
            const web_base = ship_flow.webBaseFromPrUrl(url) orelse {
                self.gh.setLastError("", "invalid PR URL");
                return null;
            };
            const host = web_base[std.mem.indexOf(u8, web_base, "://").? + 3 ..];
            const detected = gitea_mod.detectForgeConfigured(host, self.gh.forge_hosts);
            if (detected != kind) {
                self.gh.setLastError("", "forge provider does not match PR host");
                return null;
            }
            // Fresh auth for every row: a Gitea token cannot reach another host.
            var transport = gitea_mod.GiteaConnector.init(self.allocator);
            defer transport.deinit();
            transport.http = self.gitea.http;
            transport.http_fn = self.gitea.http_fn;
            transport.http_ctx = self.gitea.http_ctx;
            transport.auth_header = ship_flow.resolveForgeAuth(&self.gh, self.allocator, kind, host) catch |e| {
                self.gh.setLastError(@errorName(e), "forge credential unavailable");
                return null;
            };
            if (transport.auth_header == null) {
                self.gh.setLastError("", "forge credential unavailable");
                return null;
            }
            var forge = providers.forge_rest.ForgeConnector{ .transport = &transport, .kind = kind, .web_base = web_base, .slug = repo };
            return forge.pullRequestState(pr_num) catch |e| {
                self.gh.setLastError(transport.last_error.items, @errorName(e));
                return null;
            };
        }
        if (!std.mem.eql(u8, provider, "gitea")) {
            return self.gh.getPullRequestState(repo, pr_num) catch null;
        }
        const web_base = ship_flow.webBaseFromPrUrl(url) orelse return null;
        // Legacy selection still requires fresh credentials for each row.
        const host = web_base[std.mem.indexOf(u8, web_base, "://").? + 3 ..];
        var transport = gitea_mod.GiteaConnector.init(self.allocator);
        defer transport.deinit();
        transport.http = self.gitea.http;
        transport.http_fn = self.gitea.http_fn;
        transport.http_ctx = self.gitea.http_ctx;
        transport.auth_header = ship_flow.resolveGiteaAuth(&self.gh, self.allocator, host) catch |e| {
            self.gh.setLastError(@errorName(e), "forge credential unavailable");
            return null;
        };
        if (transport.auth_header == null) {
            self.gh.setLastError("", "forge credential unavailable");
            return null;
        }
        return transport.pullRequestState(web_base, repo, pr_num) catch |e| {
            self.gh.setLastError(transport.last_error.items, @errorName(e));
            return null;
        };
    }

    /// Realiza una iteración de sondeo sobre todas las PRs abiertas.
    /// Invariante F5-T6 (el auditor v0.14): NUNCA sobreescribe un merge manual o en vuelo.
    pub fn pollOnce(self: *GitHubPoller) !u32 {
        self.mutex.lock();
        defer self.mutex.unlock();

        const sql =
            \\SELECT id, order_id, provider, repo, number, state, url
            \\FROM pull_requests
            \\WHERE state NOT IN ('merged', 'failed')
        ;
        const stmt = try self.conn.prepare(sql);
        defer self.conn.finalize(stmt);

        var polled_count: u32 = 0;

        while (db.c.sqlite3_step(stmt) == db.c.SQLITE_ROW) {
            const pr_id = db.c.sqlite3_column_int64(stmt, 0);
            const p_provider = db.c.sqlite3_column_text(stmt, 2);
            const provider = if (p_provider) |p| std.mem.span(p) else "github";
            const repo = std.mem.span(db.c.sqlite3_column_text(stmt, 3));
            const pr_num = db.c.sqlite3_column_int64(stmt, 4);
            const current_state_str = std.mem.span(db.c.sqlite3_column_text(stmt, 5));
            const u = db.c.sqlite3_column_text(stmt, 6);
            const pr_url = if (u) |x| std.mem.span(x) else "";

            const current_state = gh_mod.PullRequestState.parse(current_state_str) catch .open;

            // Verificación previa de condición de carrera
            if (current_state == .merged) {
                self.status.race_prevented_count += 1;
                continue;
            }

            const new_state = self.stateForRow(provider, repo, pr_num, pr_url) orelse current_state;

            // Si el estado remoto no ha cambiado o hay conflicto con merge local en vuelo, ignorar
            if (new_state != current_state) {
                const now = health.nowSeconds(self.conn);
                // CAS sobre el estado leído: la llamada remota puede tardar y en
                // ese hueco un merge local (ship_flow.mergePr) escribe 'merged'.
                // Sin la condición, el sondeo pisaría ese merge ya completado.
                const update_sql = "UPDATE pull_requests SET state = ?, last_polled_at = ? WHERE id = ? AND state = ?";
                const update_stmt = try self.conn.prepare(update_sql);
                defer self.conn.finalize(update_stmt);

                try db.bindText(update_stmt, 1, new_state.toString());
                try db.bindInt(update_stmt, 2, now);
                try db.bindInt(update_stmt, 3, pr_id);
                try db.bindText(update_stmt, 4, current_state_str);

                _ = db.c.sqlite3_step(update_stmt);
                if (self.conn.changes() == 0) {
                    // Otra escritura ganó durante la vuelta remota: no se pisó.
                    self.status.race_prevented_count += 1;
                }
            }

            polled_count += 1;
        }

        // Intervalo adaptativo: 5s si hay CI corriendo, 30s si está reposando
        self.status.active_prs = polled_count;
        self.status.interval_ms = if (polled_count > 0) 5000 else 30000;

        return polled_count;
    }
};

test "github poller once execution and race condition prevention" {
    const allocator = std.testing.allocator;

    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();

    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);

    // Insert dummy PR
    try conn.exec("INSERT INTO pull_requests (id, order_id, provider, repo, number, state, url, last_polled_at) VALUES (1, 1, 'github', 'devagents/app', 42, 'open', 'https://github.com/devagents/beats/pull/42', 100)");

    var poller = GitHubPoller.init(allocator, conn, null);
    defer poller.deinit();
    poller.gh.rest_enabled = false;
    poller.gh.capture_fn = fakePollerCapture;

    const polled = try poller.pollOnce();
    try std.testing.expectEqual(@as(u32, 1), polled);
    try std.testing.expectEqual(@as(usize, 1), poller.status.active_prs);
}

var poller_rest_status: u16 = 200;
var poller_rest_body: []const u8 = "";

fn fakeRestPoller(
    allocator: std.mem.Allocator,
    method: []const u8,
    url: []const u8,
    auth: ?[]const u8,
    body: ?[]const u8,
    ctx: ?*anyopaque,
) anyerror!gitea_mod.RestResponse {
    _ = method;
    _ = url;
    _ = auth;
    _ = body;
    _ = ctx;
    return .{ .status = poller_rest_status, .body = try allocator.dupe(u8, poller_rest_body) };
}

test "gitea poller: fila provider=gitea se sondea por REST y no toca gh" {
    const allocator = std.testing.allocator;
    var conn = try db.Connection.open(allocator, ":memory:");
    defer conn.close();
    const migrator = db.Migrator.init(allocator);
    try migrator.migrate(conn, &db.runtime_schema);
    try conn.exec("INSERT INTO pull_requests (id, order_id, provider, repo, number, state, url, last_polled_at) VALUES (1, 1, 'gitea', 'Astra/DevAgents-Beats', 42, 'open', 'https://git.4stra.dev/Astra/DevAgents-Beats/pulls/42', 100)");

    var poller = GitHubPoller.init(allocator, conn, null);
    defer poller.deinit();
    poller.gh.rest_enabled = false;
    poller.gitea.http_fn = fakeRestPoller;
    var fixture = PollFixture{};
    poller.gh.forge_auth_fn = PollFixture.auth;
    poller.gh.forge_auth_ctx = &fixture;
    try conn.exec("UPDATE pull_requests SET url='https://gitea.example/Astra/DevAgents-Beats/pulls/42'");
    poller_rest_status = 200;
    poller_rest_body = "{\"state\":\"closed\",\"merged\":true}";

    const polled = try poller.pollOnce();
    try std.testing.expectEqual(@as(u32, 1), polled);

    const stmt = try conn.prepare("SELECT state FROM pull_requests WHERE id = 1");
    defer conn.finalize(stmt);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
    try std.testing.expectEqualStrings("merged", std.mem.span(db.c.sqlite3_column_text(stmt, 0)));
}

fn fakePollerCapture(a: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8) !gh_mod.CmdCapture {
    _ = argv;
    _ = cwd;
    return .{ .exit_code = 0, .stdout = try a.dupe(u8, "{\"state\":\"OPEN\",\"statusCheckRollup\":[]}"), .stderr = try a.dupe(u8, "") };
}

const PollFixture = struct {
    auth_calls: usize = 0,
    rest_calls: usize = 0,
    fn auth(a: std.mem.Allocator, kind: gh_mod.Forge, host: []const u8, ctx: ?*anyopaque) !?[]u8 {
        const f: *PollFixture = @ptrCast(@alignCast(ctx.?));
        f.auth_calls += 1;
        const marker = switch (kind) {
            .github => blk: {
                try std.testing.expectEqualStrings("github.com", host);
                break :blk "Bearer fx-gh";
            },
            .gitlab => blk: {
                try std.testing.expectEqualStrings("gitlab.com", host);
                break :blk "Bearer fx-gl";
            },
            .gitea => blk: {
                try std.testing.expectEqualStrings("gitea.example", host);
                break :blk "Bearer fx-gitea";
            },
        };
        return try a.dupe(u8, marker);
    }
    fn rest(a: std.mem.Allocator, method: []const u8, url: []const u8, auth_header: ?[]const u8, body: ?[]const u8, ctx: ?*anyopaque) !gitea_mod.RestResponse {
        _ = body;
        const f: *PollFixture = @ptrCast(@alignCast(ctx.?));
        f.rest_calls += 1;
        try std.testing.expectEqualStrings("GET", method);
        const is_lab = std.mem.indexOf(u8, url, "/api/v4/") != null;
        const expected = if (is_lab) "Bearer fx-gl" else if (std.mem.indexOf(u8, url, "api.github.com") != null) "Bearer fx-gh" else "Bearer fx-gitea";
        try std.testing.expectEqualStrings(expected, auth_header.?);
        return .{ .status = 200, .body = try a.dupe(u8, if (is_lab) "{\"state\":\"merged\"}" else "{\"state\":\"closed\",\"merged\":true}") };
    }
};

test "E5.26 poller REST all forges resolves credentials per host and rejects host mismatch" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    var poller = GitHubPoller.init(a, conn, null);
    defer poller.deinit();
    var fixture = PollFixture{};
    poller.gh.forge_auth_fn = PollFixture.auth;
    poller.gh.forge_auth_ctx = &fixture;
    poller.gitea.http_fn = PollFixture.rest;
    poller.gitea.http_ctx = &fixture;
    // Deliberately stale token: REST must resolve a fresh host-bound credential.
    poller.gitea.auth_header = try a.dupe(u8, "token stale-for-another-host");
    try std.testing.expectEqual(gh_mod.PullRequestState.merged, poller.stateForRow("github", "team/repo", 8, "https://github.com/team/repo/pull/8").?);
    try std.testing.expectEqual(gh_mod.PullRequestState.merged, poller.stateForRow("gitlab", "team/repo", 8, "https://gitlab.com/team/repo/-/merge_requests/8").?);
    try std.testing.expectEqual(gh_mod.PullRequestState.merged, poller.stateForRow("gitea", "team/repo", 8, "https://gitea.example/team/repo/pulls/8").?);
    try std.testing.expectEqual(@as(usize, 3), fixture.auth_calls);
    try std.testing.expectEqual(@as(usize, 3), fixture.rest_calls);
    try std.testing.expect(poller.stateForRow("gitlab", "team/repo", 8, "https://github.com/team/repo/pull/8") == null);
    try std.testing.expectEqual(@as(usize, 3), fixture.auth_calls);
    try std.testing.expectEqual(@as(usize, 3), fixture.rest_calls);
    try std.testing.expect(poller.stateForRow("github", "team/repo", 8, "https://user:secret@github.com/team/repo/pull/8") == null);
    try std.testing.expectEqual(@as(usize, 3), fixture.rest_calls);
}

// Real loopback receivers: each port is a different credential authority.
const AuthReceiver = struct {
    io: std.Io,
    server: std.Io.net.Server,
    thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    received: [8][64]u8 = undefined,
    lengths: [8]usize = .{0} ** 8,
    count: usize = 0,
    failure: ?anyerror = null,
    status: u16 = 200,
    body: []const u8 = "{\"state\":\"closed\",\"merged\":true}",

    fn serve(self: *AuthReceiver) !void {
        while (true) {
            var stream = try self.server.accept(self.io);
            defer stream.close(self.io);
            if (self.stop.load(.acquire)) return;
            var input: [4096]u8 = undefined;
            var reader = stream.reader(self.io, &input);
            if (self.count == self.received.len) return error.TooManyRequests;
            while (true) {
                const line = (try reader.interface.takeDelimiter('\n')) orelse return error.EndOfStream;
                if (std.mem.eql(u8, line, "\r")) break;
                const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
                if (std.ascii.eqlIgnoreCase(line[0..colon], "authorization")) {
                    const value = std.mem.trim(u8, line[colon + 1 ..], " \r");
                    if (value.len > self.received[0].len) return error.HeaderTooLong;
                    @memcpy(self.received[self.count][0..value.len], value);
                    self.lengths[self.count] = value.len;
                }
            }
            self.count += 1;
            const body = self.body;
            var output: [512]u8 = undefined;
            var writer = stream.writer(self.io, &output);
            try writer.interface.print("HTTP/1.1 {d} Fixture\r\nConnection: close\r\nContent-Length: {d}\r\n\r\n{s}", .{ self.status, body.len, body });
            try writer.interface.flush();
        }
    }

    fn run(self: *AuthReceiver) void {
        self.serve() catch |e| {
            self.failure = e;
        };
    }

    fn finish(self: *AuthReceiver) void {
        self.stop.store(true, .release);
        if (self.thread) |thread| {
            if (self.server.socket.address.connect(self.io, .{ .mode = .stream })) |wake| {
                wake.close(self.io);
            } else |e| {
                self.server.deinit(self.io);
                thread.join();
                self.thread = null;
                self.failure = e;
                return;
            }
            thread.join();
            self.thread = null;
        }
        self.server.deinit(self.io);
    }
};

const HostAuthFixture = struct {
    hosts: [3][]const u8,
    calls: usize = 0,
    fail: bool = false,

    fn auth(a: std.mem.Allocator, kind: gh_mod.Forge, host: []const u8, ctx: ?*anyopaque) !?[]u8 {
        const self: *HostAuthFixture = @ptrCast(@alignCast(ctx.?));
        try std.testing.expectEqual(gh_mod.Forge.gitea, kind);
        self.calls += 1;
        if (self.fail) return error.FixtureCredentialFailure;
        if (std.mem.eql(u8, host, self.hosts[0])) return try a.dupe(u8, "token fx-a");
        if (std.mem.eql(u8, host, self.hosts[1])) return try a.dupe(u8, "token fx-b");
        try std.testing.expectEqualStrings(self.hosts[2], host);
        return null;
    }

    fn noCredential(a: std.mem.Allocator, argv: []const []const u8, cwd: ?[]const u8, input: ?[]const u8, env: ?[]const []const u8) !gh_mod.CmdCapture {
        _ = cwd;
        _ = input;
        try std.testing.expectEqualStrings("credential", argv[1]);
        try std.testing.expectEqualStrings("fill", argv[2]);
        try std.testing.expectEqualSlices([]const u8, gh_mod.GIT_GUARD_ENV, env.?);
        return .{ .exit_code = 1, .stdout = try a.dupe(u8, ""), .stderr = try a.dupe(u8, "fixture: no credential") };
    }
};

test "E5.26 legacy Gitea poller isolates host credentials A B and B A over loopback" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = providers.http_client.deadline_io.wrapIo(&threaded);
    var receivers: [3]AuthReceiver = undefined;
    var initialized: usize = 0;
    defer for (receivers[0..initialized]) |*r| r.finish();
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    for (&receivers) |*r| {
        r.* = .{ .io = io, .server = try address.listen(io, .{}) };
        initialized += 1;
        r.thread = try std.Thread.spawn(.{}, AuthReceiver.run, .{r});
    }
    var hosts: [3][]const u8 = undefined;
    var host_count: usize = 0;
    defer for (hosts[0..host_count]) |host| a.free(host);
    for (&hosts, &receivers) |*host, *r| {
        host.* = try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{r.server.socket.address.getPort()});
        host_count += 1;
    }
    var fixture = HostAuthFixture{ .hosts = hosts };
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    var poller = GitHubPoller.init(a, conn, null);
    defer poller.deinit();
    poller.gh.rest_enabled = false;
    poller.gh.forge_auth_fn = HostAuthFixture.auth;
    poller.gh.forge_auth_ctx = &fixture;
    poller.gh.capture_full_fn = HostAuthFixture.noCredential;
    // No TLS is involved; retain the real HTTP implementation without ROOT access.
    const ht = try a.create(std.Io.Threaded);
    ht.* = std.Io.Threaded.init(a, .{});
    var http = providers.http_client.HttpClient{
        .allocator = a,
        .threaded = ht,
        .client = .{ .allocator = a, .io = providers.http_client.deadline_io.wrapIo(ht) },
        .pending_auth = null,
        .max_response_bytes = 4096,
    };
    defer http.deinit();
    poller.gitea.http = &http;
    // Prove the uncredentialed receiver is live and records absent auth.
    const empty_url = try std.fmt.allocPrint(a, "http://{s}/team/repo/pulls/8", .{hosts[2]});
    defer a.free(empty_url);
    var response = try poller.gitea.rest("GET", empty_url, null);
    defer response.deinit(a);
    try std.testing.expectEqual(@as(u16, 200), response.status);
    for ([_]usize{ 0, 1, 2, 1, 0, 2 }) |index| {
        const url = try std.fmt.allocPrint(a, "http://{s}/team/repo/pulls/8", .{hosts[index]});
        defer a.free(url);
        const state = poller.stateForRow("gitea", "team/repo", 8, url);
        try std.testing.expectEqual(if (index == 2) @as(?gh_mod.PullRequestState, null) else .merged, state);
    }
    fixture.fail = true;
    try std.testing.expectEqual(@as(?gh_mod.PullRequestState, null), poller.stateForRow("gitea", "team/repo", 8, empty_url));
    for (&receivers) |*r| r.finish();
    initialized = 0;
    for (&receivers, 0..) |*r, index| {
        if (r.failure) |e| return e;
        try std.testing.expectEqual(@as(usize, if (index == 2) 1 else 2), r.count);
        for (0..r.count) |n| try std.testing.expectEqualStrings(if (index == 0) "token fx-a" else if (index == 1) "token fx-b" else "", r.received[n][0..r.lengths[n]]);
        std.debug.print("HOST_AUTH_RECEIVER host={s} requests={d} credential_match=true\n", .{ hosts[index], r.count });
    }
    try std.testing.expectEqual(@as(usize, 7), fixture.calls);
    try std.testing.expect(poller.gitea.auth_header == null);
}

test "E5.26 external error loopback poller never propagates HTTP credentials" {
    const a = std.testing.allocator;
    var threaded = std.Io.Threaded.init(a, .{});
    defer threaded.deinit();
    const io = providers.http_client.deadline_io.wrapIo(&threaded);
    var address = try std.Io.net.IpAddress.parse("127.0.0.1", 0);
    var receiver = AuthReceiver{ .io = io, .server = try address.listen(io, .{}), .status = 422, .body = "{\"message\":\"denied\",\"token\":\"fx-s7\"}" };
    defer receiver.finish();
    receiver.thread = try std.Thread.spawn(.{}, AuthReceiver.run, .{&receiver});
    const host = try std.fmt.allocPrint(a, "127.0.0.1:{d}", .{receiver.server.socket.address.getPort()});
    defer a.free(host);
    const url = try std.fmt.allocPrint(a, "http://{s}/team/repo/pulls/8", .{host});
    defer a.free(url);
    var fixture = HostAuthFixture{ .hosts = .{ host, host, host } };
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    var poller = GitHubPoller.init(a, conn, null);
    defer poller.deinit();
    poller.gh.forge_auth_fn = HostAuthFixture.auth;
    poller.gh.forge_auth_ctx = &fixture;
    const ht = try a.create(std.Io.Threaded);
    ht.* = std.Io.Threaded.init(a, .{});
    var http = providers.http_client.HttpClient{ .allocator = a, .threaded = ht, .client = .{ .allocator = a, .io = providers.http_client.deadline_io.wrapIo(ht) }, .pending_auth = null, .max_response_bytes = 4096 };
    defer http.deinit();
    poller.gitea.http = &http;
    for ([_]bool{ false, true }) |rest| {
        poller.gh.rest_enabled = rest;
        try std.testing.expect(poller.stateForRow("gitea", "team/repo", 8, url) == null);
        try std.testing.expect(std.mem.indexOf(u8, poller.gh.last_error.items, "fx-s7") == null);
        try std.testing.expect(std.mem.indexOf(u8, poller.gh.last_error.items, "422") != null);
        try std.testing.expect(std.mem.indexOf(u8, poller.gh.last_error.items, "texto externo") != null);
        try std.testing.expect(poller.gh.last_error.items.len <= 200);
    }
    // The response and its headers are released before publishing diagnostics.
    std.debug.print("HTTP_LOOPBACK_ERROR=422; LEGACY_AND_REST=true; SHORT_SECRET_ABSENT=true\n", .{});
}

// ── H-G5: sondeo que no pisa un merge en vuelo ni bloquea a la UI ──
const Sleep = @import("platform.zig").sleep;
const GetTickCount64 = @import("platform.zig").ticks;

const MergeInFlightFixture = struct {
    conn: *db.Connection,
    raced: bool = false,

    fn rest(
        a: std.mem.Allocator,
        method: []const u8,
        url: []const u8,
        auth_header: ?[]const u8,
        body: ?[]const u8,
        ctx: ?*anyopaque,
    ) !gitea_mod.RestResponse {
        _ = method;
        _ = url;
        _ = auth_header;
        _ = body;
        const self: *MergeInFlightFixture = @ptrCast(@alignCast(ctx.?));
        // El merge local termina mientras la vuelta remota está en curso.
        try self.conn.exec("UPDATE pull_requests SET state = 'merged' WHERE id = 1");
        self.raced = true;
        return .{ .status = 200, .body = try a.dupe(u8, "{\"state\":\"open\",\"merged\":false}") };
    }
};

test "H-G5 poller no pisa un merge en vuelo (CAS sobre el estado leído)" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    const migrator = db.Migrator.init(a);
    try migrator.migrate(conn, &db.runtime_schema);
    try conn.exec("INSERT INTO pull_requests (id, order_id, provider, repo, number, state, url, last_polled_at) VALUES (1, 1, 'gitea', 'team/repo', 7, 'mergeable', 'https://gitea.example/team/repo/pulls/7', 100)");

    var poller = GitHubPoller.init(a, conn, null);
    defer poller.deinit();
    poller.gh.rest_enabled = false;
    var auth_fixture = PollFixture{};
    poller.gh.forge_auth_fn = PollFixture.auth;
    poller.gh.forge_auth_ctx = &auth_fixture;
    var merge_fixture = MergeInFlightFixture{ .conn = &conn };
    poller.gitea.http_fn = MergeInFlightFixture.rest;
    poller.gitea.http_ctx = &merge_fixture;

    const polled = try poller.pollOnce();
    try std.testing.expectEqual(@as(u32, 1), polled);
    try std.testing.expect(merge_fixture.raced);
    try std.testing.expectEqual(@as(u32, 1), poller.status.race_prevented_count);

    const stmt = try conn.prepare("SELECT state FROM pull_requests WHERE id = 1");
    defer conn.finalize(stmt);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
    try std.testing.expectEqualStrings("merged", std.mem.span(db.c.sqlite3_column_text(stmt, 0)));
    std.debug.print("HG5_RACE state=merged race_prevented={d}\n", .{poller.status.race_prevented_count});
}

const SlowClientFixture = struct {
    started: std.atomic.Value(bool) = .init(false),
    finished: std.atomic.Value(bool) = .init(false),
    sleep_ms: u32 = 3000,

    fn rest(
        a: std.mem.Allocator,
        method: []const u8,
        url: []const u8,
        auth_header: ?[]const u8,
        body: ?[]const u8,
        ctx: ?*anyopaque,
    ) !gitea_mod.RestResponse {
        _ = method;
        _ = url;
        _ = auth_header;
        _ = body;
        const self: *SlowClientFixture = @ptrCast(@alignCast(ctx.?));
        self.started.store(true, .release);
        Sleep(self.sleep_ms);
        self.finished.store(true, .release);
        return .{ .status = 200, .body = try a.dupe(u8, "{\"state\":\"closed\",\"merged\":true}") };
    }
};

fn pollInBackground(p: *GitHubPoller, out: *?anyerror) void {
    if (p.pollOnce()) |_| {
        out.* = null;
    } else |e| {
        out.* = e;
    }
}

test "H-G5 poller con cliente lento no retiene lecturas de la UI" {
    const a = std.testing.allocator;
    var conn = try db.Connection.open(a, ":memory:");
    defer conn.close();
    const migrator = db.Migrator.init(a);
    try migrator.migrate(conn, &db.runtime_schema);
    try conn.exec("INSERT INTO pull_requests (id, order_id, provider, repo, number, state, url, last_polled_at) VALUES (1, 1, 'gitea', 'team/repo', 7, 'open', 'https://gitea.example/team/repo/pulls/7', 100)");

    var poller = GitHubPoller.init(a, conn, null);
    defer poller.deinit();
    poller.gh.rest_enabled = false;
    var auth_fixture = PollFixture{};
    poller.gh.forge_auth_fn = PollFixture.auth;
    poller.gh.forge_auth_ctx = &auth_fixture;
    var slow = SlowClientFixture{};
    poller.gitea.http_fn = SlowClientFixture.rest;
    poller.gitea.http_ctx = &slow;

    var poll_error: ?anyerror = null;
    const t0 = GetTickCount64();
    const thread = try std.Thread.spawn(.{}, pollInBackground, .{ &poller, &poll_error });
    const spawn_ms = GetTickCount64() - t0;
    // El llamador recupera el control de inmediato; la vuelta sigue en su hilo.
    try std.testing.expect(spawn_ms < 750);

    var waited_ms: u64 = 0;
    while (!slow.started.load(.acquire) and waited_ms < 1500) : (waited_ms += 10) Sleep(10);
    try std.testing.expect(slow.started.load(.acquire));
    try std.testing.expect(!slow.finished.load(.acquire));

    const read_ms = blk: {
        const r0 = GetTickCount64();
        const count_stmt = try conn.prepare("SELECT COUNT(*) FROM pull_requests");
        defer conn.finalize(count_stmt);
        try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(count_stmt));
        break :blk GetTickCount64() - r0;
    };
    // La lectura de la UI (misma conexión, WAL/serialized) no espera a la red.
    try std.testing.expect(read_ms < 1000);

    thread.join();
    const total_ms = GetTickCount64() - t0;
    try std.testing.expect(poll_error == null);
    try std.testing.expect(slow.finished.load(.acquire));
    try std.testing.expect(total_ms >= 2500);

    const stmt = try conn.prepare("SELECT state FROM pull_requests WHERE id = 1");
    defer conn.finalize(stmt);
    try std.testing.expectEqual(db.c.SQLITE_ROW, db.c.sqlite3_step(stmt));
    try std.testing.expectEqualStrings("merged", std.mem.span(db.c.sqlite3_column_text(stmt, 0)));
    std.debug.print("HG5_NONBLOCK spawn_ms={d} ui_read_ms={d} poll_ms={d} state=merged\n", .{ spawn_ms, read_ms, total_ms });
}
